//------------------------------------------------------------------------------
// Stand-in for psram.sv plus a PSRAM chip, for tb_s4.sv built with
// -DPSRAM_STANDIN: psram.sv's user ports (src/fpga/pocket_utils/psram.sv,
// agg23, MIT) with its cycle timing at CLOCK_SPEED = 28.636364, and a plain
// 4M x 16 array behind them. Simulation only; the real controller and
// psram_model.sv are the default.
//
// Timing, as psram.sv's state machine gives it (docs/BUPCHIP_CORE.md,
// "Controller"): a request is taken on an edge where busy is low (write_en
// wins over read_en); busy is high for the next 4 clocks and low again on
// the 5th edge, when a write lands in the array and a read's data_out is
// registered with a one-clock read_avail. So one halfword every 5 clocks.
//
// Unwritten halfwords read as a pattern of their address, so a read of a
// halfword nobody wrote is not silently zero.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module psram_standin (
	input  wire        clk,
	input  wire        bank_sel,
	input  wire [21:0] addr,
	input  wire        write_en,
	input  wire [15:0] data_in,
	input  wire        write_high_byte,
	input  wire        write_low_byte,
	input  wire        read_en,
	output reg         read_avail = 1'b0,
	output reg  [15:0] data_out = 16'd0,
	output reg         busy = 1'b0
);
	logic [15:0] mem [0:(1 << 22) - 1];
	initial
		for (int i = 0; i < (1 << 22); i++)
			mem[i] = 16'(i * 40503) ^ 16'hA5C3;

	int          state = 0;     // 0 idle; 1-4 write; 20-23 read (psram.sv's numbers)
	logic [21:0] a;
	logic [15:0] d;
	logic  [1:0] be;
	int          n_rd = 0, n_wr = 0;

	always @(posedge clk) begin
		if (state != 0) state <= state + 1;
		busy <= state != 0;
		case (state)
			0: begin
				read_avail <= 1'b0;
				if (write_en) begin
					state <= 1;
					busy <= 1'b1;
					a <= addr;
					d <= data_in;
					be <= {write_high_byte, write_low_byte};
				end else if (read_en) begin
					state <= 20;
					busy <= 1'b1;
					a <= addr;
				end
			end
			4: begin
				state <= 0;
				busy <= 1'b0;
				if (be[1]) mem[a][15:8] <= d[15:8];
				if (be[0]) mem[a][7:0] <= d[7:0];
				n_wr <= n_wr + 1;
			end
			23: begin
				state <= 0;
				busy <= 1'b0;
				read_avail <= 1'b1;
				data_out <= mem[a];
				n_rd <= n_rd + 1;
			end
			default: ;
		endcase
	end
endmodule
