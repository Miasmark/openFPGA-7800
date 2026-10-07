//------------------------------------------------------------------------------
// DARIA front end: the shared-edge phase detector and the guard
// (docs/daria_fe/design.md 8, D4). One clk_arm toggle (pd_tog) into one
// constrained clk_sys receiver (pd_rx); a flywheel (ph) that locks after 12
// consistent edges; phb_next marks the clock whose edge is phase B; guard_on
// = locked & (call_win | !cpu_ready). No reset: power-up initialised. The
// SDC lines of 8.2 name daria_fe_guard:u_guard|pd_tog and |pd_rx.
//
// How it works (8.1). On the Pocket clk_sys = VCO/48 and clk_arm = VCO/18,
// so a 144-VCO frame holds clk_sys edges at 0 (shared with a clk_arm edge),
// 48 and 96, and clk_arm edges every 18. With the pd_tog -> pd_rx path held
// in [1, 6] ns by the SDC pair, the shared edge catches two toggles (those
// launched at -36 and -18; the one launched on it arrives after it) and the
// other two edges three each. So pd_rx keeps its value exactly at the shared
// edge: pd_same = (pd_rx == pd_rx1) is 1 exactly in the clock after it. The
// flywheel ph counts 0, 1, 2 with ph = 0 predicted in that clock; a
// mismatch re-anchors it (ph = 1 next) and unlocks; 12 consecutive matches
// after the first (good = 12) lock it at the 13th. phb_next = locked &
// ph == 0 comes from the flywheel register, never from the receiver: an
// address presented in that clock registers on the next edge, phase B
// (17.46 ns after the last clk_arm edge, 8.73 ns before the next). At
// /19 or with clk_arm = 5x or 1x clk_sys the pattern has no period 3 long
// enough, so it never locks and guard_on stays 0 (8.3).
//
// D10: each flywheel register has one load enable and a two-input data mux.
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
	// Power-up values are the repository's idiom (docs/DEVELOPING.md,
	// "Power-up values"); the block has no reset (design 1.5 rule 7).
	/* verilator lint_off PROCASSINIT */
	(* altera_attribute = "-name PRESERVE_REGISTER ON" *)
	logic       pd_tog = 1'b0;     // the only clk_arm flop in daria_fe
	(* altera_attribute = "-name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION OFF" *)
	logic       pd_rx  = 1'b0;     // its one constrained receiver (8.2)
	logic       pd_rx1 = 1'b0;
	logic [1:0] ph     = 2'd1;     // flywheel: 0 in the clock after a shared edge
	logic [3:0] good   = 4'd0;     // consecutive matches, saturating at 12
	logic       lk     = 1'b0;
	/* verilator lint_on PROCASSINIT */
	logic       pd_same;           // in (E, E+1): pd_rx did not change at E, so E was shared
	/* verilator lint_off UNUSEDSIGNAL */
	logic       ev_unlock;         // pulse: the clock whose edge drops locked (read only by the bench)
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- the detector ------------------------------------------------------------------
	always_ff @(posedge clk_arm) pd_tog <= ~pd_tog;

	assign pd_same = pd_rx == pd_rx1;
	wire   mism    = pd_same != (ph == 2'd0);     // the prediction failed in this clock

	always_ff @(posedge clk_sys) begin
		pd_rx  <= pd_tog;
		pd_rx1 <= pd_rx;
		// mismatch: re-anchor and unlock; else advance and count
		ph <= mism ? 2'd1 : ((ph == 2'd2) ? 2'd0 : ph + 2'd1);
		if (mism | (good != 4'd12)) good <= mism ? 4'd0 : good + 4'd1;
		if (mism | (good == 4'd12)) lk   <= !mism;
	end

	assign ev_unlock = lk & mism;

	// ---- outputs ----------------------------------------------------------------------
	assign locked   = lk;
	assign phb_next = lk & (ph == 2'd0);          // from the flywheel register, not the receiver
	assign guard_on = lk & (call_win | !cpu_ready);
endmodule

`default_nettype wire
