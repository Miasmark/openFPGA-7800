//------------------------------------------------------------------------------
// DARIA front end: the cycle sequencer (docs/daria_fe/design.md 2.1).
// k is the phase-1 clock count from E0, c the count from the commit C, ph2
// D3's in_phase2; commit, ph1_open, rel_ok and ev_short are combinational.
// No reset: power-up initialised (1.5 rule 7).
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off. Lane A fills the body.
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
	assign k        = 8'h00;       // stub
	assign c        = 4'h0;        // stub
	assign ph2      = 1'b0;        // stub
	assign commit   = 1'b0;        // stub
	assign ph1_open = 1'b0;        // stub
	assign rel_ok   = 1'b0;        // stub
	assign ev_short = 1'b0;        // stub
endmodule

`default_nettype wire
