// Clocks per access of agg23's psram.sv for a given CLOCK_SPEED setting, the
// fact check behind docs/BUPCHIP_CORE.md, "Controller": its state numbers
// come from CLOCK_SPEED, so it is right only where they come out distinct.
// Nothing answers on cram_dq; only clocks are counted.
//
//   tb_psram.CLOCK_SPEED  the controller's parameter, MHz
//   tb_psram.CLK_MHZ      the clock it actually runs on (only scales the ns)
//
// Phase 1 holds read_en from clock 5 to 200 and counts read_avail pulses;
// phase 2 holds write_en from clock 250 to 450 and counts completed writes
// (busy falling). The last line, "result: ...", is for run_psram.sh.
//
// From the design study (see ../README.md).
//
// SPDX-License-Identifier: MIT
`timescale 1ps/1ps
module tb_psram;
	parameter real CLOCK_SPEED = 28.636364;
	parameter real CLK_MHZ = 28.636364;
	localparam real HALF_PS = 500000.0 / CLK_MHZ;

	reg clk = 0;
	always #(HALF_PS) clk = ~clk;
	reg rd = 0, wr = 0;
	wire [15:0] dq, dout;
	wire avail, busy;
	wire [21:16] a;
	wire cclk, adv, cre, ce0, ce1, oe, we, ub, lb;

	psram #(.CLOCK_SPEED(CLOCK_SPEED)) p (.clk(clk), .bank_sel(1'b0), .addr(22'h12345),
		.write_en(wr), .data_in(16'hBEEF), .write_high_byte(1'b1), .write_low_byte(1'b1),
		.read_en(rd), .read_avail(avail), .data_out(dout), .busy(busy),
		.cram_a(a), .cram_dq(dq), .cram_wait(1'b0), .cram_clk(cclk), .cram_adv_n(adv),
		.cram_cre(cre), .cram_ce0_n(ce0), .cram_ce1_n(ce1), .cram_oe_n(oe), .cram_we_n(we),
		.cram_ub_n(ub), .cram_lb_n(lb));

	integer c = 0, nr = 0, r_first = -1, r_last = -1, nw = 0, w_first = -1, w_last = -1;
	reg busy_d = 0;
	always @(posedge clk) begin
		c <= c + 1;
		rd <= c >= 5 && c < 200;
		wr <= c >= 250 && c < 450;
		busy_d <= busy;
		if (avail) begin nr = nr + 1; if (r_first < 0) r_first = c; r_last = c; end
		if (c >= 250 && busy_d && !busy) begin nw = nw + 1; if (w_first < 0) w_first = c; w_last = c; end
	end

	initial begin
		real rpc, wpc;
		integer distinct;
		repeat (500) @(posedge clk);
		rpc = nr > 1 ? (r_last - r_first) * 1.0 / (nr - 1) : 0;
		wpc = nw > 1 ? (w_last - w_first) * 1.0 / (nw - 1) : 0;
		distinct = p.STATE_WRITE_ADV_END < p.STATE_WRITE_ADDR_LATCH_END &&
			p.STATE_WRITE_ADDR_LATCH_END < p.STATE_WRITE_DATA_START &&
			p.STATE_WRITE_DATA_START < p.STATE_WRITE_DATA_END &&
			p.STATE_READ_ADV_END < p.STATE_READ_ADDR_LATCH_END &&
			p.STATE_READ_ADDR_LATCH_END < p.STATE_READ_DATA_ENABLE &&
			p.STATE_READ_DATA_ENABLE < p.STATE_READ_DATA_RECEIVED;
		$display("CLOCK_SPEED %.6f on a %.3f MHz clock: write states %0d %0d %0d %0d, read states %0d %0d %0d %0d (%0s)",
			CLOCK_SPEED, CLK_MHZ, p.STATE_WRITE_ADV_END, p.STATE_WRITE_ADDR_LATCH_END,
			p.STATE_WRITE_DATA_START, p.STATE_WRITE_DATA_END, p.STATE_READ_ADV_END,
			p.STATE_READ_ADDR_LATCH_END, p.STATE_READ_DATA_ENABLE, p.STATE_READ_DATA_RECEIVED,
			distinct ? "distinct" : "NOT distinct");
		$display("  reads: %0d in 195 clocks, %.2f clocks each (%.0f ns); writes: %0d in 200 clocks, %.2f clocks each (%.0f ns)",
			nr, rpc, rpc * 1000.0 / CLK_MHZ, nw, wpc, wpc * 1000.0 / CLK_MHZ);
		$display("result: reads=%0d read_clocks=%.2f writes=%0d write_clocks=%.2f distinct=%0d", nr, rpc, nw, wpc, distinct);
		$finish;
	end
endmodule
