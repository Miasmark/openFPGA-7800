//------------------------------------------------------------------------------
// DARIA front end: the cycle sequencer (docs/daria_fe/design.md 2.1).
// k is the phase-1 clock count from E0, c the count from the commit C, ph2
// D3's in_phase2; commit, ph1_open, rel_ok and ev_short are combinational.
// No reset: power-up initialised (1.5 rule 7).
//
//   k[j]   high in (E0+j, E0+j+1) for j < 7; k[7] from E0+7 to the next E0.
//          E0 is the edge at which pclk1 is sampled high.
//   c[j]   high in (C+j, C+j+1) for j < 3; c[3] from C+3 on. C is the edge
//          at which commit (access & a_in[12]) is sampled high.
//   ph2    set at the pclk0 edge, cleared at the pclk1 edge.
//   rel_ok (ph2 | pclk0) & !pclk1: a busy may fall at E0+6 ... E0+11 of any
//          phase lengths, never at an E0 (the held-address double commit,
//          GL 7.5, DI 1.2), and also during a pause in phase 2 (CR 16).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_seq (
	input  wire        clk_sys,
	input  wire        pclk1,      // phi1_ce: E0 is the edge at which it is sampled high
	input  wire        pclk0,      // phi2_ce
	input  wire        access,     // mapper_phi2 && arm_driver_run
	input  wire        a12,        // a_in[12]
	output logic [7:0] k,          // reg: k[j] in (E0+j, E0+j+1), j < 7; k[7] saturates
	output logic [3:0] c,          // reg: c[j] in (C+j, C+j+1), j < 3; c[3] saturates
	output logic       ph2,        // reg: set at pclk0, cleared at pclk1
	output logic       commit,     // comb: access & a12
	output logic       ph1_open,   // comb: !ph2 & !pclk0
	output logic       rel_ok,     // comb: (ph2 | pclk0) & !pclk1
	output logic       ev_short    // comb: commit & !(k[5] | k[6] | k[7])
);
	// The power-up values are the repository's idiom (docs/DEVELOPING.md,
	// "Power-up values"): internal registers, the ports driven by assigns.
	/* verilator lint_off PROCASSINIT */
	logic [7:0] k_r   = 8'h80;
	logic [3:0] c_r   = 4'h8;
	logic       ph2_r = 1'b0;
	/* verilator lint_on PROCASSINIT */

	always_ff @(posedge clk_sys) begin
		k_r   <= pclk1  ? 8'h01 : (k_r[7] ? k_r : {k_r[6:0], 1'b0});   // k[0] in (E0, E0+1); saturates
		c_r   <= commit ? 4'h1  : (c_r[3] ? c_r : {c_r[2:0], 1'b0});   // c[0] in (C, C+1);   saturates
		ph2_r <= pclk1  ? 1'b0  : (pclk0 ? 1'b1 : ph2_r);              // D3's in_phase2
	end

	assign k        = k_r;
	assign c        = c_r;
	assign ph2      = ph2_r;
	assign commit   = access & a12;                        // a cartridge commit (DPC §14.1)
	assign ph1_open = !ph2_r & !pclk0;                     // this edge is before the latch edge
	assign rel_ok   = (ph2_r | pclk0) & !pclk1;            // a busy may fall here: E0+6 ... E0+11
	assign ev_short = commit & !(k_r[5] | k_r[6] | k_r[7]); // a commit before E0+6 (counted, never gating)
endmodule

`default_nettype wire
