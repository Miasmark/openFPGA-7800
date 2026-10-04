//------------------------------------------------------------------------------
// Stress stand-in for psram.sv's user ports (src/fpga/pocket_utils/psram.sv,
// agg23, MIT), for the step 4 stress benches (sim/bupchip/s4/stress/): the
// same handshake as psram.sv, but every access takes a random number of
// clocks in [lmin, lmax] instead of exactly 5, so the clients cannot lean on
// one latency. psram.sv itself is the L = 5 case.
//
//   A request (write_en wins over read_en) is taken on an edge where busy is
//   low. With L clocks, busy is high for the next L - 1 clocks and low again
//   from the edge that completes the access, when a write lands and a read's
//   data_out is registered with a one-clock read_avail. L = 1 completes on
//   the accepting edge, busy never rising, so reads can run back to back.
//
// Contents: halfword a is {pat(epoch, 2a + 1), pat(epoch, 2a)} until it is
// written. The bench changes `epoch` to model new contents (a reload); the
// data of a read is taken when it completes. Die 1 (bank_sel) is an error.
//
//   +plmin=N +plmax=N   latency range (parameters LMIN, LMAX; default 5, 5)
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module psram_var #(
	parameter int LMIN = 5,
	parameter int LMAX = 5
) (
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
	int lmin = LMIN, lmax = LMAX;
	int epoch = 0;
	int n_rd = 0, n_wr = 0, n_bank1 = 0;
	int lat_hist [0:63];
	logic [15:0] wmem [int];
	logic  [1:0] wbe [int];

	initial begin
		void'($value$plusargs("plmin=%d", lmin));
		void'($value$plusargs("plmax=%d", lmax));
		if (lmin < 1 || lmax < lmin || lmax > 63) $fatal(1, "psram_var: bad latency range %0d..%0d", lmin, lmax);
		for (int i = 0; i < 64; i++) lat_hist[i] = 0;
	end

	function automatic logic [7:0] pat(input int ep, input int b);
		logic [31:0] x;
		x = (b ^ (ep * 32'h5BD1E995)) * 32'h9E3779B1;
		return x[23:16] ^ x[7:0] ^ 8'(b >> 8) ^ 8'(ep * 77);
	endfunction

	function automatic logic [15:0] value(input int a);
		logic [15:0] v;
		v = {pat(epoch, 2 * a + 1), pat(epoch, 2 * a)};
		if (wbe.exists(a)) begin
			if (wbe[a][1]) v[15:8] = wmem[a][15:8];
			if (wbe[a][0]) v[7:0] = wmem[a][7:0];
		end
		return v;
	endfunction

	int          cnt = 0;
	logic        rd = 1'b0;
	logic [21:0] a = 22'd0;
	logic [15:0] d = 16'd0;
	logic  [1:0] be = 2'b00;

	task automatic finish();
		if (rd) begin
			read_avail <= 1'b1;
			data_out <= value(int'(a));
			n_rd++;
		end else begin
			if (be != 2'b00) begin
				if (!wbe.exists(int'(a))) begin wbe[int'(a)] = 2'b00; wmem[int'(a)] = 16'd0; end
				if (be[1]) wmem[int'(a)][15:8] = d[15:8];
				if (be[0]) wmem[int'(a)][7:0] = d[7:0];
				wbe[int'(a)] = wbe[int'(a)] | be;
			end
			n_wr++;
		end
	endtask

	always @(posedge clk) begin
		read_avail <= 1'b0;
		if (cnt > 0) begin
			cnt <= cnt - 1;
			if (cnt == 1) begin
				busy <= 1'b0;
				finish();
			end
		end else if (write_en || read_en) begin
			int l;
			l = lmin + $urandom_range(lmax - lmin);
			lat_hist[l]++;
			if (bank_sel) n_bank1++;
			rd = !write_en;
			a = addr;
			d = data_in;
			be = {write_high_byte, write_low_byte};
			if (l == 1) finish();
			else begin
				cnt <= l - 1;
				busy <= 1'b1;
			end
		end
	end
endmodule
