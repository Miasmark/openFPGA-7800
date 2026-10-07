//------------------------------------------------------------------------------
// DARIA front end: the shared-edge phase detector and the guard
// (docs/daria_fe/design.md 8, D4). One clk_arm toggle (pd_tog) into one
// constrained clk_sys receiver (pd_rx); a flywheel (ph) that locks after 12
// consistent edges; phb_next marks the clock whose edge is phase B; guard_on
// = locked & (call_win | !cpu_ready). No reset: power-up initialised. The
// SDC lines of 8.2 name daria_fe_guard:u_guard|pd_tog and |pd_rx.
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.4/1.7 (declared
// here so that the tap names exist). Lane D fills the body.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_guard (
	input  wire  clk_sys,
	input  wire  clk_arm,          // feeds only pd_tog
	input  wire  call_win,         // from u_call
	input  wire  cpu_ready,
	output logic locked,           // reg-derived
	output logic phb_next,         // reg-derived: lk & (ph == 0)
	output logic guard_on          // comb: locked & (call_win | !cpu_ready)
);
	// ---- bench taps (design 1.4, 1.7, 8.1; frozen names) ---------------------------
	logic       pd_tog;            // the only clk_arm flop in daria_fe
	logic       pd_rx;             // its one constrained receiver
	logic       pd_rx1;
	logic       pd_same;
	logic [1:0] ph;
	logic [3:0] good;
	logic       ev_unlock;

	assign pd_tog    = 1'b0;       // stub
	assign pd_rx     = 1'b0;       // stub
	assign pd_rx1    = 1'b0;       // stub
	assign pd_same   = 1'b0;       // stub
	assign ph        = 2'd0;       // stub
	assign good      = 4'd0;       // stub
	assign ev_unlock = 1'b0;       // stub

	assign locked    = 1'b0;       // stub
	assign phb_next  = 1'b0;       // stub
	assign guard_on  = 1'b0;       // stub
endmodule

`default_nettype wire
