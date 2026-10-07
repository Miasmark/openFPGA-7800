//------------------------------------------------------------------------------
// DARIA front end (docs/daria_fe/design.md; the frozen interfaces are
// docs/daria_fe/interfaces.md): the 6507 side of DPC+ and of the CDF family
// (CDF0, CDF1, CDFJ, CDFJ+), with its audio engine, its RAM image (F6), the
// DPC+ copy/fill engine, its half of the call port and the shared-edge
// guard. BUS and ELF stay bad-game screens (D2).
//
// This file is the top: the ports of design 1.2, the scheme decode, the one
// front-end reset rst_fe (F2), fe_oe, and the instances of 1.1 wired as 1.4
// gives their ports. Everything is clk_sys except u_guard's one clk_arm flop.
// The memories are daria_mem's (front-end ROM ports A and B, cart RAM port
// B, state RAM port B); this module only drives their addresses and data.
//
//   u_seq    k, c, ph2, commit, ph1_open, rel_ok, ev_short       (2.1)
//   u_core   op latch, W, fe_do, scheme state, commit actions,  (2.2-2.6)
//            pointer buffer, P32, service latch; holds u_dec
//   u_audio  tick, counters, frequencies, ring, replica, sample  (5)
//   u_call   post / flip / wait / read / apply / release         (6)
//   u_copy   load tracking, F6, init_busy, copy/fill, dma_busy   (7)
//   u_arb    owners and muxes of A, R, S; grants; crb_use        (3)
//   u_guard  phase detector, flywheel, guard_on                  (8)
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe (
	input  wire          clk_sys,         // 14.318 MHz
	input  wire          clk_arm,         // feeds only u_guard.pd_tog
	input  wire          cart_reset,      // effective_reset
	input  wire          pause,           // pause_core
	input  wire   [12:0] a_in,            // {AB[12] & bios_en_b, AB[11:0]}
	input  wire    [7:0] d_in,            // write_DB (the CPU's DOR)
	input  wire          rw,              // RW
	input  wire          pclk1,           // phi1_ce
	input  wire          pclk0,           // phi2_ce
	input  wire          access,          // mapper_phi2 && arm_driver_run
	input  wire    [5:0] scheme,          // force_bs with the override: 21 DPC+, 23 CDF
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire    [2:0] revision,        // mapper_revision: [0] stable_fractional, [1:0] CDF version; [2] is BUS's
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire          cdf_ldx,         // detect2600
	input  wire          cdf_ldy,
	input  wire          fetch_off_en,
	input  wire    [7:0] fetch_off,
	input  wire   [31:0] cdfj_entry,
	input  wire   [31:0] cdfj_stack,
	input  wire   [15:0] audio_size_addr,
	input  wire   [31:0] rom_size,        // cart_size
	input  wire          ram32,           // mapper_ram_size == 32768
	input  wire          load_start,      // one-clock pulses (mapper_load_*)
	input  wire          load_end,
	input  wire          cart_win,        // bup_capture.cart_win; its fall is c_close
	input  wire          cpu_ready,       // daria_ready (mode A: see design 1.2)
	input  wire          ret_tog,         // clk_arm domain
	output logic         call_tog,        // reg
	output logic         smp_req,         // reg: digital-sample request toggle
	output logic  [18:0] smp_addr,        // reg: image byte offset
	input  wire          smp_ack,         // answer toggle, wrapper's domain
	input  wire    [7:0] smp_data,
	output logic   [7:0] fe_do,           // reg: direct_do for BANKDPCP and BANKCDF
	output logic         fe_oe,           // comb: a_in[12]
	output logic         arm_call_busy,   // reg: the stall terms (top.sv:306-307)
	output logic         arm_dma_busy,    // reg
	output logic         init_busy,       // reg: into atari7800_pocket's reset OR
	output logic  [12:0] fea_addr,        // FE ROM port A word address
	input  wire   [31:0] fea_q,
	output logic  [12:0] feb_addr,        // FE ROM port B: the mirror
	input  wire   [31:0] feb_q,
	output logic  [12:0] crb_addr,        // cart RAM port B
	output logic         crb_we,
	output logic   [3:0] crb_be,
	output logic  [31:0] crb_wd,
	input  wire   [31:0] crb_q,
	output logic   [7:0] stb_addr,        // state RAM port B
	output logic         stb_we,
	output logic   [3:0] stb_be,
	output logic  [31:0] stb_wd,
	input  wire   [31:0] stb_q,
	input  wire          hk_en,           // bench merge hook; tied 0 in synthesis
	input  wire          hk_stb,          // bench: upstream's call_done
	input  wire  [191:0] hk_ret           // bench: {f2, f1, f0, c2, c1, c0}
);
	// ---- scheme decode, rst_fe (F2), fe_oe --------------------------------------------
	wire       is_dpc = scheme == daria_fe_pkg::SCHEME_DPCP;
	wire       is_cdf = scheme == daria_fe_pkg::SCHEME_CDF;
	wire       jplus  = is_cdf & (revision[1:0] == 2'd3);    // CDFJ+
	wire       jrev   = is_cdf & revision[1];                // CDFJ, CDFJ+ (revision >= 2)
	wire [1:0] fam    = {is_cdf, is_dpc | is_cdf};           // 1 DPC+, 3 CDF, 0 otherwise (live)
	// The power-up value is the repository's idiom (docs/DEVELOPING.md,
	// "Power-up values"); scheme_q = 0 makes rst_fe high in the first clock.
	/* verilator lint_off PROCASSINIT */
	logic [5:0] scheme_q = 6'd0;
	/* verilator lint_on PROCASSINIT */
	always_ff @(posedge clk_sys) scheme_q <= scheme;
	wire       rst_fe = cart_reset | !(is_dpc | is_cdf) | (scheme != scheme_q);
	assign fe_oe = a_in[12];

	// ---- u_seq outputs ----------------------------------------------------------------
	logic [7:0] k;
	logic [3:0] c;
	/* verilator lint_off UNUSEDSIGNAL */
	logic       ph2;                  // tap only (design 1.7): read by the bench, not here
	/* verilator lint_on UNUSEDSIGNAL */
	logic       commit, ph1_open, rel_ok, ev_short;

	// ---- u_core outputs ---------------------------------------------------------------
	logic        sel_up;
	logic        cr_fix, cr_fix_we, cr_fix_use;
	logic [12:0] cr_fix_a;
	logic  [3:0] cr_fix_be;
	logic [31:0] cr_fix_wd;
	logic        cr_p32, cr_wb;
	logic [12:0] cr_p32_a, cr_wb_a;
	logic [31:0] cr_wb_wd;
	logic        cs_req, cs_we;
	logic  [7:0] cs_a;
	logic  [3:0] cs_be;
	logic [31:0] cs_wd;
	logic        look_req;
	logic [12:0] look_a;
	logic  [6:0] wave0, wave1, wave2;
	logic        note_stb;
	logic  [1:0] note_v;
	logic  [7:0] note_val;
	logic        cdf_dig;
	logic        callfn;
	logic        svc_pend, svc_hold, svc_fill;
	logic [16:0] svc_src;
	logic [12:0] svc_dst;
	logic  [7:0] svc_rem, svc_val;
	logic        dma_set;
	daria_fe_pkg::dec_t op;
	logic        p32_q, rdP, wb_v, ev_guard_sup;

	// ---- u_audio outputs --------------------------------------------------------------
	logic        aud_issue;
	logic [14:0] aud_addr;
	logic        aud_a_req;
	logic [12:0] aud_a_a;
	logic  [7:0] amp_nx;
	logic [31:0] ring0;

	// ---- u_call outputs ---------------------------------------------------------------
	logic        cl_req, cl_we;
	logic  [7:0] cl_a;
	logic [31:0] cl_wd;
	logic        cp_cap, cp_rot, cp_shin, cp_cmp, cp_apply, mwin;
	logic        call_win;

	// ---- u_copy outputs ---------------------------------------------------------------
	logic        svc_take, f6_act;
	/* verilator lint_off UNUSEDSIGNAL */
	logic        rst_quiet;           // tap only
	/* verilator lint_on UNUSEDSIGNAL */
	logic        cp_req, cp_we;
	logic [12:0] cp_a;
	logic  [3:0] cp_be;
	logic [31:0] cp_wd;
	logic        cz_req;
	logic  [7:0] cz_a;
	logic        ca_req;
	logic [12:0] ca_a;

	// ---- u_arb outputs ----------------------------------------------------------------
	logic aud_take, p32_gnt, wb_gnt, cp_gnt, cl_gnt, look_gnt, aud_a_gnt, ca_gnt;
	/* verilator lint_off UNUSEDSIGNAL */
	logic crb_use;                    // tap only: the bench's read side (BEN 6.4)
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- u_guard outputs --------------------------------------------------------------
	/* verilator lint_off UNUSEDSIGNAL */
	logic locked;                     // tap only
	/* verilator lint_on UNUSEDSIGNAL */
	logic phb_next, guard_on;


	daria_fe_seq u_seq (
		.clk_sys  (clk_sys),
		.pclk1    (pclk1),
		.pclk0    (pclk0),
		.access   (access),
		.a12      (a_in[12]),
		.k        (k),
		.c        (c),
		.ph2      (ph2),
		.commit   (commit),
		.ph1_open (ph1_open),
		.rel_ok   (rel_ok),
		.ev_short (ev_short)
	);

	daria_fe_core u_core (
		.clk_sys      (clk_sys),
		.rst_fe       (rst_fe),
		.is_dpc       (is_dpc),
		.is_cdf       (is_cdf),
		.jplus        (jplus),
		.jrev         (jrev),
		.rev          (revision[1:0]),
		.sf           (revision[0]),
		.ldx          (cdf_ldx),
		.ldy          (cdf_ldy),
		.foff_en      (fetch_off_en),
		.foff         (fetch_off),
		.a_in         (a_in),
		.d_in         (d_in),
		.rw           (rw),
		.access       (access),
		.pclk1        (pclk1),
		.k            (k),
		.c            (c),
		.commit       (commit),
		.ph1_open     (ph1_open),
		.ev_short     (ev_short),
		.fea_q        (fea_q),
		.feb_q        (feb_q),
		.crb_q        (crb_q),
		.stb_q        (stb_q),
		.aud_take     (aud_take),
		.look_gnt     (look_gnt),
		.p32_gnt      (p32_gnt),
		.wb_gnt       (wb_gnt),
		.guard_on     (guard_on),
		.amp_nx       (amp_nx),
		.svc_take     (svc_take),
		.init_busy    (init_busy),
		.dma_busy     (arm_dma_busy),
		.call_busy    (arm_call_busy),
		.fe_do        (fe_do),
		.sel_up       (sel_up),
		.feb_addr     (feb_addr),
		.cr_fix       (cr_fix),
		.cr_fix_a     (cr_fix_a),
		.cr_fix_we    (cr_fix_we),
		.cr_fix_be    (cr_fix_be),
		.cr_fix_wd    (cr_fix_wd),
		.cr_fix_use   (cr_fix_use),
		.cr_p32       (cr_p32),
		.cr_p32_a     (cr_p32_a),
		.cr_wb        (cr_wb),
		.cr_wb_a      (cr_wb_a),
		.cr_wb_wd     (cr_wb_wd),
		.cs_req       (cs_req),
		.cs_a         (cs_a),
		.cs_we        (cs_we),
		.cs_be        (cs_be),
		.cs_wd        (cs_wd),
		.look_req     (look_req),
		.look_a       (look_a),
		.wave0        (wave0),
		.wave1        (wave1),
		.wave2        (wave2),
		.note_stb     (note_stb),
		.note_v       (note_v),
		.note_val     (note_val),
		.cdf_dig      (cdf_dig),
		.callfn       (callfn),
		.svc_pend     (svc_pend),
		.svc_hold     (svc_hold),
		.svc_fill     (svc_fill),
		.svc_src      (svc_src),
		.svc_dst      (svc_dst),
		.svc_rem      (svc_rem),
		.svc_val      (svc_val),
		.dma_set      (dma_set),
		.op           (op),
		.p32_q        (p32_q),
		.rdP          (rdP),
		.wb_v         (wb_v),
		.ev_guard_sup (ev_guard_sup)
	);

	daria_fe_audio u_audio (
		.clk_sys    (clk_sys),
		.cart_reset (cart_reset),
		.pause      (pause),
		.fam        (fam),
		.rev        (revision[1:0]),
		.rom_size   (rom_size),
		.ram32      (ram32),
		.asz        (audio_size_addr),
		.cdf_dig    (cdf_dig),
		.wave0      (wave0),
		.wave1      (wave1),
		.wave2      (wave2),
		.note_stb   (note_stb),
		.note_v     (note_v),
		.note_val   (note_val),
		.cp_cap     (cp_cap),
		.cp_rot     (cp_rot),
		.cp_shin    (cp_shin),
		.cp_cmp     (cp_cmp),
		.cp_apply   (cp_apply),
		.mwin       (mwin),
		.hk_en      (hk_en),
		.hk_stb     (hk_stb),
		.hk_ret     (hk_ret),
		.aud_issue  (aud_issue),
		.aud_addr   (aud_addr),
		.aud_take   (aud_take),
		.crb_q      (crb_q),
		.stb_q      (stb_q),
		.aud_a_req  (aud_a_req),
		.aud_a_a    (aud_a_a),
		.aud_a_gnt  (aud_a_gnt),
		.fea_q      (fea_q),
		.smp_req    (smp_req),
		.smp_addr   (smp_addr),
		.smp_ack    (smp_ack),
		.smp_data   (smp_data),
		.amp_nx     (amp_nx),
		.ring0      (ring0)
	);

	daria_fe_call u_call (
		.clk_sys       (clk_sys),
		.cart_reset    (cart_reset),
		.is_dpc        (is_dpc),
		.is_cdf        (is_cdf),
		.jplus         (jplus),
		.cdfj_entry    (cdfj_entry),
		.cdfj_stack    (cdfj_stack),
		.callfn        (callfn),
		.cpu_ready     (cpu_ready),
		.ret_tog       (ret_tog),
		.rel_ok        (rel_ok),
		.ring0         (ring0),
		.hk_en         (hk_en),
		.hk_stb        (hk_stb),
		.cl_req        (cl_req),
		.cl_a          (cl_a),
		.cl_we         (cl_we),
		.cl_wd         (cl_wd),
		.cl_gnt        (cl_gnt),
		.cp_cap        (cp_cap),
		.cp_rot        (cp_rot),
		.cp_shin       (cp_shin),
		.cp_cmp        (cp_cmp),
		.cp_apply      (cp_apply),
		.mwin          (mwin),
		.call_tog      (call_tog),
		.arm_call_busy (arm_call_busy),
		.call_win      (call_win)
	);

	daria_fe_copy u_copy (
		.clk_sys      (clk_sys),
		.cart_reset   (cart_reset),
		.load_start   (load_start),
		.load_end     (load_end),
		.cart_win     (cart_win),
		.is_dpc       (is_dpc),
		.is_cdf       (is_cdf),
		.ram32        (ram32),
		.rel_ok       (rel_ok),
		.guard_on     (guard_on),
		.svc_pend     (svc_pend),
		.svc_hold     (svc_hold),
		.svc_fill     (svc_fill),
		.svc_src      (svc_src),
		.svc_dst      (svc_dst),
		.svc_rem      (svc_rem),
		.svc_val      (svc_val),
		.dma_set      (dma_set),
		.svc_take     (svc_take),
		.init_busy    (init_busy),
		.arm_dma_busy (arm_dma_busy),
		.f6_act       (f6_act),
		.rst_quiet    (rst_quiet),
		.cp_req       (cp_req),
		.cp_a         (cp_a),
		.cp_we        (cp_we),
		.cp_be        (cp_be),
		.cp_wd        (cp_wd),
		.cp_gnt       (cp_gnt),
		.cz_req       (cz_req),
		.cz_a         (cz_a),
		.ca_req       (ca_req),
		.ca_a         (ca_a),
		.ca_gnt       (ca_gnt),
		.fea_q        (fea_q)
	);

	daria_fe_arb u_arb (
		.clk_sys      (clk_sys),
		.cr_fix       (cr_fix),
		.cr_fix_a     (cr_fix_a),
		.cr_fix_we    (cr_fix_we),
		.cr_fix_be    (cr_fix_be),
		.cr_fix_wd    (cr_fix_wd),
		.cr_fix_use   (cr_fix_use),
		.cr_p32       (cr_p32),
		.cr_p32_a     (cr_p32_a),
		.cr_wb        (cr_wb),
		.cr_wb_a      (cr_wb_a),
		.cr_wb_wd     (cr_wb_wd),
		.cs_req       (cs_req),
		.cs_a         (cs_a),
		.cs_we        (cs_we),
		.cs_be        (cs_be),
		.cs_wd        (cs_wd),
		.look_req     (look_req),
		.look_a       (look_a),
		.aud_issue    (aud_issue),
		.aud_addr     (aud_addr),
		.aud_a_req    (aud_a_req),
		.aud_a_a      (aud_a_a),
		.cl_req       (cl_req),
		.cl_a         (cl_a),
		.cl_we        (cl_we),
		.cl_wd        (cl_wd),
		.cp_req       (cp_req),
		.cp_a         (cp_a),
		.cp_we        (cp_we),
		.cp_be        (cp_be),
		.cp_wd        (cp_wd),
		.cz_req       (cz_req),
		.cz_a         (cz_a),
		.ca_req       (ca_req),
		.ca_a         (ca_a),
		.sel_up       (sel_up),
		.guard_on     (guard_on),
		.phb_next     (phb_next),
		.f6_act       (f6_act),
		.ev_short     (ev_short),
		.k            (k),
		.commit       (commit),
		.op           (op),
		.p32_q        (p32_q),
		.rdP          (rdP),
		.wb_v         (wb_v),
		.ev_guard_sup (ev_guard_sup),
		.fea_addr     (fea_addr),
		.crb_addr     (crb_addr),
		.crb_we       (crb_we),
		.crb_be       (crb_be),
		.crb_wd       (crb_wd),
		.stb_addr     (stb_addr),
		.stb_we       (stb_we),
		.stb_be       (stb_be),
		.stb_wd       (stb_wd),
		.aud_take     (aud_take),
		.p32_gnt      (p32_gnt),
		.wb_gnt       (wb_gnt),
		.cp_gnt       (cp_gnt),
		.cl_gnt       (cl_gnt),
		.look_gnt     (look_gnt),
		.aud_a_gnt    (aud_a_gnt),
		.ca_gnt       (ca_gnt),
		.crb_use      (crb_use)
	);

	daria_fe_guard u_guard (
		.clk_sys   (clk_sys),
		.clk_arm   (clk_arm),
		.call_win  (call_win),
		.cpu_ready (cpu_ready),
		.locked    (locked),
		.phb_next  (phb_next),
		.guard_on  (guard_on)
	);
endmodule

`default_nettype wire
