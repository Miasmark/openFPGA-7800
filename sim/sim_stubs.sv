// Behavioural stand-ins for the two Intel primitives the design instantiates
// directly, so the whole core can run under Verilator.
`timescale 1ns/1ps

module altddio_out #(
	parameter extend_oe_disable = "OFF",
	parameter intended_device_family = "Cyclone V",
	parameter invert_output = "OFF",
	parameter lpm_hint = "UNUSED",
	parameter lpm_type = "altddio_out",
	parameter oe_reg = "UNREGISTERED",
	parameter power_up_high = "OFF",
	parameter width = 1
) (
	input  wire [width-1:0] datain_h,
	input  wire [width-1:0] datain_l,
	input  wire outclock,
	output wire [width-1:0] dataout,
	input  wire aclr, aset, oe, outclocken, sclr, sset
);
	assign dataout = outclock ? datain_h : datain_l;
endmodule

module altsyncram #(
	parameter operation_mode = "BIDIR_DUAL_PORT",
	parameter width_a = 8, widthad_a = 11, numwords_a = 2048,
	parameter width_b = 8, widthad_b = 11, numwords_b = 2048,
	parameter outdata_reg_a = "UNREGISTERED", outdata_reg_b = "UNREGISTERED",
	parameter address_reg_b = "CLOCK1", indata_reg_b = "CLOCK1",
	parameter wrcontrol_wraddress_reg_b = "CLOCK1",
	parameter clock_enable_input_a = "BYPASS", clock_enable_input_b = "BYPASS",
	parameter clock_enable_output_a = "BYPASS", clock_enable_output_b = "BYPASS",
	parameter power_up_uninitialized = "FALSE",
	parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_type = "altsyncram"
) (
	input  wire clock0, clock1,
	input  wire [widthad_a-1:0] address_a,
	input  wire [widthad_b-1:0] address_b,
	input  wire [width_a-1:0] data_a,
	input  wire [width_b-1:0] data_b,
	input  wire wren_a, wren_b,
	output reg  [width_a-1:0] q_a,
	output reg  [width_b-1:0] q_b,
	input  wire aclr0, aclr1, addressstall_a, addressstall_b,
	input  wire byteena_a, byteena_b,
	input  wire clocken0, clocken1, clocken2, clocken3, rden_a, rden_b,
	output wire eccstatus
);
	reg [width_a-1:0] mem [0:numwords_a-1];
	initial for (int i = 0; i < numwords_a; i++) mem[i] = '0;
	always @(posedge clock0) begin
		if (wren_a) mem[address_a] <= data_a;
		q_a <= wren_a ? data_a : mem[address_a];
	end
	always @(posedge clock1) begin
		if (wren_b) mem[address_b] <= data_b;
		q_b <= wren_b ? data_b : mem[address_b];
	end
	assign eccstatus = 1'b0;
endmodule

// Stand-in for the Sorgelig SDRAM controller at its channel interface: its
// tristate data bus is not something Verilator models, so the SDRAM chip and
// controller are replaced by a byte array with the same handshake - a write
// or read starts on the rising edge of ch0_wr / ch0_rd, busy is held for the
// controller's seven cycle access, and read data is ready when busy drops.
module sdram (
	inout  wire [15:0] SDRAM_DQ,
	output wire [12:0] SDRAM_A,
	output wire        SDRAM_DQML, SDRAM_DQMH,
	output wire  [1:0] SDRAM_BA,
	output wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
	output wire        SDRAM_CLK, SDRAM_CKE,
	input  wire        init, clk,
	input  wire [24:0] ch0_addr,
	input  wire        ch0_rd, ch0_wr,
	input  wire  [7:0] ch0_din,
	output reg   [7:0] ch0_dout,
	output reg         ch0_busy
);
	assign SDRAM_A = '0; assign SDRAM_BA = '0;
	assign {SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS} = '1;
	assign SDRAM_CLK = clk; assign SDRAM_CKE = 1'b1;

	reg [7:0] mem [0:(1<<20)-1];
	initial begin
		for (int i = 0; i < (1<<20); i++) mem[i] = 8'hFF;
		ch0_busy = 1'b0;
		ch0_dout = 8'hFF;
	end
	reg old_rd = 0, old_wr = 0;
	reg [2:0] cnt = 0;
	// Requests are edges, remembered while busy exactly as the real
	// controller (rtl/sdram.sv) does: old_* only follows a request once it
	// is accepted, so a strobe that rises during a cycle and is still high
	// when the cycle ends is taken then, not dropped.
	always @(posedge clk) begin
		old_rd <= old_rd & ch0_rd;
		old_wr <= old_wr & ch0_wr;
		if (cnt == 0 && ((~old_wr & ch0_wr) | (~old_rd & ch0_rd))) begin
			old_rd <= ch0_rd;
			old_wr <= ch0_wr;
		end
		if (cnt != 0) begin
			cnt <= cnt - 1'b1;
			if (cnt == 1) ch0_busy <= 1'b0;
		end else if (~old_wr & ch0_wr) begin
			mem[ch0_addr[19:0]] <= ch0_din;
			ch0_dout <= ch0_din;
			ch0_busy <= 1'b1;
			cnt <= 3'd7;
		end else if (~old_rd & ch0_rd) begin
			ch0_dout <= mem[ch0_addr[19:0]];
			ch0_busy <= 1'b1;
			cnt <= 3'd7;
		end
	end
endmodule

// Dual clock FIFO used by the APF data loader (show-ahead off).
module dcfifo #(
	parameter clocks_are_synchronized = "FALSE",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_numwords = 4,
	parameter lpm_showahead = "OFF",
	parameter lpm_type = "dcfifo",
	parameter lpm_width = 8,
	parameter lpm_widthu = 2,
	parameter overflow_checking = "OFF",
	parameter rdsync_delaypipe = 5,
	parameter underflow_checking = "OFF",
	parameter use_eab = "OFF",
	parameter wrsync_delaypipe = 5
) (
	input  wire [lpm_width-1:0] data,
	input  wire rdclk, rdreq, wrclk, wrreq,
	output reg  [lpm_width-1:0] q,
	output wire rdempty
);
	logic [lpm_width-1:0] fifo [$];
	always @(posedge wrclk) if (wrreq) fifo.push_back(data);
	always @(posedge rdclk) if (rdreq && fifo.size() > 0) q <= fifo.pop_front();
	assign rdempty = fifo.size() == 0;
endmodule

// The Pocket's AS6C2016-55 SRAM (128K x 16), as the controller sees it:
// reads answer while OE is low and WE high, writes land as WE rises. Access
// time is not modelled; sram_ctrl samples five clk_sdram (87 ns) after it
// sets the address. Power-up contents are pseudo-random, as on hardware.
module sram_model (
	input  wire [16:0] a,
	inout  wire [15:0] dq,
	input  wire        oe_n, we_n, ub_n, lb_n
);
	reg [15:0] mem [0:131071];
	integer seed = 7800;
	initial for (int i = 0; i < 131072; i++) mem[i] = 16'($random(seed));
	assign dq = (!oe_n && we_n) ? mem[a] : 16'hZZZZ;
	always @(posedge we_n) begin
		if (!lb_n) mem[a][7:0] <= dq[7:0];
		if (!ub_n) mem[a][15:8] <= dq[15:8];
	end
endmodule
