//------------------------------------------------------------------------------
// DARIA front end: the owners and muxes of the four memory ports
// (docs/daria_fe/design.md 3): front-end ROM port A, cart RAM port B (R)
// and state RAM port B (S), by fixed priority with one-hot AND-OR muxes; the
// grants; crb_use; the collision and guard assertions (3.6). Port B of the
// front-end ROM (the mirror) passes from u_core straight to the top.
// Combinational except crb_use and the assertion pulses.
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.7 (declared here
// so that the tap names exist). Lane D fills the body.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_arb (
	input  wire         clk_sys,
	// u_core, R fixed
	input  wire         cr_fix,
	input  wire  [12:0] cr_fix_a,
	input  wire         cr_fix_we,
	input  wire   [3:0] cr_fix_be,
	input  wire  [31:0] cr_fix_wd,
	input  wire         cr_fix_use,
	// u_core, R yield
	input  wire         cr_p32,
	input  wire  [12:0] cr_p32_a,
	input  wire         cr_wb,
	input  wire  [12:0] cr_wb_a,
	input  wire  [31:0] cr_wb_wd,
	// u_core, S
	input  wire         cs_req,
	input  wire   [7:0] cs_a,
	input  wire         cs_we,
	input  wire   [3:0] cs_be,
	input  wire  [31:0] cs_wd,
	// u_core, A
	input  wire         look_req,
	input  wire  [12:0] look_a,
	// u_audio, R and A
	input  wire         aud_issue,
	input  wire  [14:0] aud_addr,     // byte address: [14:2] is the word
	input  wire         aud_a_req,
	input  wire  [12:0] aud_a_a,
	// u_call, S (be = F)
	input  wire         cl_req,
	input  wire   [7:0] cl_a,
	input  wire         cl_we,
	input  wire  [31:0] cl_wd,
	// u_copy, R, S (F6 clear: we = 1, be = F, data 0) and A
	input  wire         cp_req,
	input  wire  [12:0] cp_a,
	input  wire         cp_we,
	input  wire   [3:0] cp_be,
	input  wire  [31:0] cp_wd,
	input  wire         cz_req,
	input  wire   [7:0] cz_a,
	input  wire         ca_req,
	input  wire  [12:0] ca_a,
	// control
	input  wire         sel_up,       // u_core: the replica of sel_ram_sel
	input  wire         guard_on,     // u_guard
	input  wire         phb_next,     // u_guard
	input  wire         f6_act,       // u_copy
	// for the assertions (3.6; step 0, S0-9: k[7:0], op, p32_q, rdP, wb_v, ev_guard_sup)
	input  wire         ev_short,     // u_seq
	input  wire   [7:0] k,            // u_seq
	input  wire         commit,       // u_seq
	input  daria_fe_pkg::dec_t op,    // u_core
	input  wire         p32_q,        // u_core
	input  wire         rdP,          // u_core
	input  wire         wb_v,         // u_core
	input  wire         ev_guard_sup, // u_core
	// the ports (feb_addr passes from u_core to the top)
	output logic [12:0] fea_addr,
	output logic [12:0] crb_addr,
	output logic        crb_we,
	output logic  [3:0] crb_be,
	output logic [31:0] crb_wd,
	output logic  [7:0] stb_addr,
	output logic        stb_we,
	output logic  [3:0] stb_be,
	output logic [31:0] stb_wd,
	// grants (comb)
	output logic        aud_take,
	output logic        p32_gnt,
	output logic        wb_gnt,
	output logic        cp_gnt,
	output logic        cl_gnt,
	output logic        look_gnt,
	output logic        aud_a_gnt,
	output logic        ca_gnt,
	output logic        crb_use       // reg: this clock's crb_q is consumed
);
	// ---- bench taps (design 1.7; frozen names; daria_fe_pkg::OR_/OS_/OA_*) ------
	logic  [5:0] own_r;               // one-hot or 0
	logic  [2:0] own_s;
	logic  [3:0] own_a;
	logic        ev_grant_steal;
	logic        a_collide;
	logic        a_wb_late;
	logic        a_p32_late;
	logic        a_guard_core;
	logic        a_guard_wr;

	assign own_r          = 6'd0;     // stub
	assign own_s          = 3'd0;     // stub
	assign own_a          = 4'd0;     // stub
	assign ev_grant_steal = 1'b0;     // stub
	assign a_collide      = 1'b0;     // stub
	assign a_wb_late      = 1'b0;     // stub
	assign a_p32_late     = 1'b0;     // stub
	assign a_guard_core   = 1'b0;     // stub
	assign a_guard_wr     = 1'b0;     // stub

	assign fea_addr       = 13'd0;    // stub
	assign crb_addr       = 13'd0;    // stub
	assign crb_we         = 1'b0;     // stub
	assign crb_be         = 4'h0;     // stub
	assign crb_wd         = 32'd0;    // stub
	assign stb_addr       = 8'h00;    // stub
	assign stb_we         = 1'b0;     // stub
	assign stb_be         = 4'h0;     // stub
	assign stb_wd         = 32'd0;    // stub
	assign aud_take       = 1'b0;     // stub
	assign p32_gnt        = 1'b0;     // stub
	assign wb_gnt         = 1'b0;     // stub
	assign cp_gnt         = 1'b0;     // stub
	assign cl_gnt         = 1'b0;     // stub
	assign look_gnt       = 1'b0;     // stub
	assign aud_a_gnt      = 1'b0;     // stub
	assign ca_gnt         = 1'b0;     // stub
	assign crb_use        = 1'b0;     // stub
endmodule

`default_nettype wire
