//------------------------------------------------------------------------------
// DARIA front end: the owners and muxes of the four memory ports
// (docs/daria_fe/design.md 3): front-end ROM port A, cart RAM port B (R)
// and state RAM port B (S), by fixed priority with one-hot AND-OR muxes; the
// grants; crb_use; the collision and guard assertions (3.6). Port B of the
// front-end ROM (the mirror) passes from u_core straight to the top.
// Combinational except crb_use and the assertion pulses.
//
// One owner per port per clock. The owner's address, write enable, byte
// enables and data are presented in the clock and register at the edge
// that ends it (1.5); a port with no owner is parked at address 0 with no
// write (we = 0, be = 0, data 0). Every grant below is the highest-priority
// eligible request, so the owner vectors own_r/own_s/own_a are one-hot or 0
// by construction (bit = priority, daria_fe_pkg::OR_/OS_/OA_*).
//
//   R (3.1)  0 F6         cp_req & f6_act
//            1 core fixed fix_eff  = cr_fix & !guard_on & !f6_act
//            2 audio      aud_take = upstream's grant (!sel_up) & !fix_eff
//                                    & !f6_act & (!guard_on | phb_next)
//            3 P32 read   p32_gnt, 4 pointer write wb_gnt, 5 copy engine
//                         cp_gnt: each behind every request above it,
//                         never under guard_on or f6_act
//   S (3.2)  0 F6 clear cz_req (we 1, be F, data 0); 1 core cs_req (always
//            granted unless cz_req); 2 call port cl_gnt
//   A (3.3)  0 F6 source ca_req & f6_act; 1 CDF lookahead look_gnt;
//            2 audio sample aud_a_gnt; 3 DPC+ copy source ca_gnt
//
// The guard (3.5, D4). While guard_on the core's fixed R requests and the
// P32 read are suppressed (their owner term is 0, so the port parks), no
// non-F6 write is granted (the pointer buffer and the copy engine wait),
// and the audio is granted only in a phb_next clock: every R access but
// F6's registers on the phase-B edge. S and A are unaffected.
//
// crb_use (reg) is high in the clock whose crb_q is consumed: the clock
// after a granted consumed read (the core's fixed read with cr_fix_use, the
// P32 read, an audio read).
//
// Assertions (3.6; one-clock pulses the bench counts; nothing in daria_fe
// reads them, so synthesis removes them). A "cycle" runs from a k[0] clock
// (the first clock after E0) to the clock before the next one; the
// per-cycle flags below restart in k[0]:
//   ev_grant_steal  aud_issue & !sel_up & fix_eff: the audio loses an
//                   upstream grant edge to the core's fixed use
//   a_collide       a steal with no ev_short so far in its cycle (3.4 (a):
//                   a steal is legal only after an early commit)
//   a_wb_late       wb_v & k[1]: the pointer buffer still full at the next
//                   cycle's first read
//   a_p32_late      k[3] & op.(cdsw | cdsp) & !(p32_q | rdP) & !guard_on
//   a_guard_core    a commit in a cycle that also has an ev_guard_sup (a
//                   commit with or after a suppression, or a suppression
//                   after the commit)
//   a_guard_wr      guard_on & a non-F6 R write request (core fixed write,
//                   pointer write, copy-engine write)
//   a_owner         two owners on one port (impossible by construction;
//                   design 3.6's "one owner per port", simulation)
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
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire  [14:0] aud_addr,     // byte address: [14:2] is the word
	/* verilator lint_on UNUSEDSIGNAL */
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
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire   [7:0] k,            // u_seq (k[0], k[1], k[3] are read)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire         commit,       // u_seq
	/* verilator lint_off UNUSEDSIGNAL */
	input  daria_fe_pkg::dec_t op,    // u_core (op.c.cdsw, op.c.cdsp are read)
	/* verilator lint_on UNUSEDSIGNAL */
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
	// the owner bit of each user (daria_fe_pkg::OR_/OS_/OA_*; local copies,
	// as Quartus 21.1 rejects a package-scoped name in a select on an
	// assign's left-hand side)
	localparam int B_OR_F6   = daria_fe_pkg::OR_F6;
	localparam int B_OR_FIX  = daria_fe_pkg::OR_FIX;
	localparam int B_OR_AUD  = daria_fe_pkg::OR_AUD;
	localparam int B_OR_P32  = daria_fe_pkg::OR_P32;
	localparam int B_OR_WB   = daria_fe_pkg::OR_WB;
	localparam int B_OR_COPY = daria_fe_pkg::OR_COPY;
	localparam int B_OS_CZ   = daria_fe_pkg::OS_CZ;
	localparam int B_OS_CORE = daria_fe_pkg::OS_CORE;
	localparam int B_OS_CALL = daria_fe_pkg::OS_CALL;
	localparam int B_OA_F6   = daria_fe_pkg::OA_F6;
	localparam int B_OA_LOOK = daria_fe_pkg::OA_LOOK;
	localparam int B_OA_AUD  = daria_fe_pkg::OA_AUD;
	localparam int B_OA_COPY = daria_fe_pkg::OA_COPY;

	// ---- bench taps (design 1.7; frozen names; daria_fe_pkg::OR_/OS_/OA_*) ------
	logic  [5:0] own_r;               // one-hot or 0
	logic  [2:0] own_s;
	logic  [3:0] own_a;
	logic        ev_grant_steal;
	/* verilator lint_off UNUSEDSIGNAL */   // read only by the bench
	logic        a_collide;
	logic        a_wb_late;
	logic        a_p32_late;
	logic        a_guard_core;
	logic        a_guard_wr;
	logic        a_owner;             // added tap: two owners on one port (3.6, simulation)
	/* verilator lint_on UNUSEDSIGNAL */

	// ==================================================================================
	// R: cart RAM port B (3.1)
	// ==================================================================================
	wire r_quiet = !guard_on & !f6_act;                      // no guard, no F6
	wire fix_eff = cr_fix & r_quiet;                         // core fixed (suppressed under the guard)
	assign aud_take = aud_issue & !sel_up & !fix_eff & !f6_act & (!guard_on | phb_next);
	wire y_free  = r_quiet & !fix_eff & !aud_take;           // a yielding user may take the port
	assign p32_gnt  = cr_p32 & y_free;
	assign wb_gnt   = cr_wb  & y_free & !cr_p32;
	wire cpy_gnt = cp_req & y_free & !cr_p32 & !cr_wb;       // the copy engine without F6
	wire f6_gnt  = cp_req & f6_act;                          // F6 (priority 0)
	assign cp_gnt   = f6_gnt | cpy_gnt;

	assign own_r[B_OR_F6]   = f6_gnt;
	assign own_r[B_OR_FIX]  = fix_eff;
	assign own_r[B_OR_AUD]  = aud_take;
	assign own_r[B_OR_P32]  = p32_gnt;
	assign own_r[B_OR_WB]   = wb_gnt;
	assign own_r[B_OR_COPY] = cpy_gnt;

	// one-hot AND-OR muxes; no owner: address 0, no write
	assign crb_addr = ({13{cp_gnt}}   & cp_a)
	                | ({13{fix_eff}}  & cr_fix_a)
	                | ({13{aud_take}} & aud_addr[14:2])
	                | ({13{p32_gnt}}  & cr_p32_a)
	                | ({13{wb_gnt}}   & cr_wb_a);
	assign crb_we   = (cp_gnt & cp_we) | (fix_eff & cr_fix_we) | wb_gnt;
	assign crb_be   = ({4{cp_gnt}}  & cp_be)
	                | ({4{fix_eff}} & cr_fix_be)
	                | ({4{wb_gnt}}  & 4'hF);
	assign crb_wd   = ({32{cp_gnt}}  & cp_wd)
	                | ({32{fix_eff}} & cr_fix_wd)
	                | ({32{wb_gnt}}  & cr_wb_wd);

	// crb_use: the q of a consumed read is valid in the clock after its grant
	/* verilator lint_off PROCASSINIT */
	logic use_q = 1'b0;
	/* verilator lint_on PROCASSINIT */
	always_ff @(posedge clk_sys) use_q <= (fix_eff & cr_fix_use) | p32_gnt | aud_take;
	assign crb_use = use_q;

	// ==================================================================================
	// S: state RAM port B (3.2)
	// ==================================================================================
	wire cs_gnt = cs_req & !cz_req;                          // implicitly granted
	assign cl_gnt = cl_req & !cz_req & !cs_req;

	assign own_s[B_OS_CZ]   = cz_req;
	assign own_s[B_OS_CORE] = cs_gnt;
	assign own_s[B_OS_CALL] = cl_gnt;

	assign stb_addr = ({8{cz_req}} & cz_a) | ({8{cs_gnt}} & cs_a) | ({8{cl_gnt}} & cl_a);
	assign stb_we   = cz_req | (cs_gnt & cs_we) | (cl_gnt & cl_we);
	assign stb_be   = ({4{cz_req}} & 4'hF) | ({4{cs_gnt}} & cs_be) | ({4{cl_gnt}} & 4'hF);
	assign stb_wd   = ({32{cs_gnt}} & cs_wd) | ({32{cl_gnt}} & cl_wd);   // F6 clear: data 0

	// ==================================================================================
	// A: front-end ROM port A (3.3; the capture's cap_we override is in daria_mem)
	// ==================================================================================
	assign look_gnt  = look_req & !f6_act;
	assign aud_a_gnt = aud_a_req & !f6_act & !look_req;
	assign ca_gnt    = ca_req & (f6_act | (!look_req & !aud_a_req));

	assign own_a[B_OA_F6]   = ca_req & f6_act;
	assign own_a[B_OA_LOOK] = look_gnt;
	assign own_a[B_OA_AUD]  = aud_a_gnt;
	assign own_a[B_OA_COPY] = ca_gnt & !f6_act;

	assign fea_addr = ({13{look_gnt}} & look_a) | ({13{aud_a_gnt}} & aud_a_a) | ({13{ca_gnt}} & ca_a);

	// ==================================================================================
	// assertions (3.6)
	// ==================================================================================
	/* verilator lint_off PROCASSINIT */
	logic sh_q  = 1'b0;               // ev_short seen in this cycle (before this clock)
	logic sup_q = 1'b0;               // ev_guard_sup seen in this cycle
	logic cm_q  = 1'b0;               // a commit seen in this cycle
	/* verilator lint_on PROCASSINIT */
	wire  sh_c  = ev_short     | (sh_q  & !k[0]);            // ... up to and including this clock
	wire  sup_c = ev_guard_sup | (sup_q & !k[0]);
	wire  cm_c  = commit       | (cm_q  & !k[0]);
	always_ff @(posedge clk_sys) begin
		sh_q  <= sh_c;
		sup_q <= sup_c;
		cm_q  <= cm_c;
	end

	assign ev_grant_steal = aud_issue & !sel_up & fix_eff;
	assign a_collide      = ev_grant_steal & !sh_c;
	assign a_wb_late      = wb_v & k[1];
	assign a_p32_late     = k[3] & (op.c.cdsw | op.c.cdsp) & !(p32_q | rdP) & !guard_on;
	assign a_guard_core   = (commit & sup_c) | (ev_guard_sup & cm_q & !k[0]);
	assign a_guard_wr     = guard_on & ((cr_fix & cr_fix_we) | cr_wb | (cp_req & cp_we & !f6_act));
	assign a_owner        = (|(own_r & (own_r - 6'd1))) | (|(own_s & (own_s - 3'd1)))
	                      | (|(own_a & (own_a - 4'd1)));
endmodule

`default_nettype wire
