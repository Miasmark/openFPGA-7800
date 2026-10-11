//------------------------------------------------------------------------------
// A clk_arm word seen on clk_sys through a snapshot (BUP_DEBUG; open item 11,
// docs/DARIA_CORE.md 7.1 row 9; docs/daria_step7/plan.md P15)
//
// With DARIA clk_arm is VCO/18, no longer 2 x clk_sys (pll_core.v), so a
// clk_sys register can no longer sample a clk_arm word directly: the bits
// would arrive at different times within the SDC's 20 ns bound, and a word
// could be torn, half old and half new. This takes a copy instead:
//
//   clk_sys  every PERIOD clocks, if the last request has been answered,
//            flips req
//   clk_arm  req through two flops (rq_s0, rq_s1); when rq_s1 differs from
//            ack, copies d_arm into hold and sets ack to rq_s1, in the same
//            clock
//   clk_sys  ack through two flops (ak_s0, ak_s1); when a request is
//            outstanding (req != seen) and ak_s1 equals req, loads hold into
//            q_sys and sets seen to req
//
// hold changes only in the clk_arm clock that flips ack, and clk_sys reads it
// at the earliest two clk_sys edges after ack has crossed, so it has been
// still for more than one clk_sys (69.8 ns) against the 20 ns bound
// (core/daria_constraints.sdc). It then stays still until the next request,
// PERIOD clk_sys later. q_sys is always a word d_arm held, at most PERIOD +
// about 6 clk_sys old (1,024 clk_sys: 72 us).
//
// The first flop of each direction (rq_s0, ak_s0) is a scalar of its own with
// SYNCHRONIZER_IDENTIFICATION FORCED, and samples one register with no logic
// in between. No reset: power-up values, all 0, start the handshake idle.
// From any other power-up state it settles within the first few clk_sys, and
// a word loaded then may be the power-up value of hold; every later word is
// one d_arm held (sim/bupchip/dbgsnap/tb_dbg_snap.sv).
//
// Ports: clk_sys, clk_arm, d_arm[N-1:0] (clk_arm), q_sys[N-1:0] (clk_sys).
// Instantiated under BUP_DEBUG and POCKET_DARIA (bupchip_pocket.sv).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_dbg_snap #(
	parameter int N = 1,
	parameter int PERIOD = 1024              // clk_sys clocks between requests, at least 2
) (
	input  wire          clk_sys,
	input  wire          clk_arm,
	input  wire  [N-1:0] d_arm,              // clk_arm
	output logic [N-1:0] q_sys               // clk_sys
);
	localparam int CW = PERIOD > 2 ? $clog2(PERIOD) : 1;

	// Power-up values (an initializer on an output port declaration is ignored
	// by Quartus; docs/DEVELOPING.md, "Power-up values").
	initial q_sys = '0;

	/* verilator lint_off PROCASSINIT */
	// ---- clk_sys: the request ------------------------------------------------------------
	logic [CW-1:0] cnt = '0;
	logic          req = 1'b0;               // flips to ask for a copy
	logic          seen = 1'b0;              // the request last answered
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic          ak_s0 = 1'b0;
	logic          ak_s1 = 1'b0;

	// ---- clk_arm: the copy ----------------------------------------------------------------
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic          rq_s0 = 1'b0;
	logic          rq_s1 = 1'b0;
	logic          ack = 1'b0;               // the request last copied
	logic  [N-1:0] hold = '0;                // held from one copy to the next
	/* verilator lint_on PROCASSINIT */

	always_ff @(posedge clk_arm) begin
		rq_s0 <= req;
		rq_s1 <= rq_s0;
		if (rq_s1 != ack) begin
			hold <= d_arm;
			ack <= rq_s1;
		end
	end

	wire waiting = req != seen;
	wire take    = waiting && ak_s1 == req;

	always_ff @(posedge clk_sys) begin
		ak_s0 <= ack;
		ak_s1 <= ak_s0;
		cnt <= cnt == CW'(PERIOD - 1) ? '0 : cnt + 1'd1;
		if (take) begin
			q_sys <= hold;
			seen <= req;
		end
		if (!waiting && cnt == CW'(PERIOD - 1))
			req <= ~req;
	end
endmodule

`default_nettype wire
