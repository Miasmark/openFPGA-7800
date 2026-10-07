//------------------------------------------------------------------------------
// tb_fe_arb: daria_fe_arb's unit bench (docs/daria_fe/design.md 3, 12.3;
// lane D, docs/daria_fe/lanes/D_arb_guard.md).
//
// daria_fe_arb drives daria_mem's cart RAM port B, state RAM port B and
// front-end ROM port A (WIN_KB 32; POISON=1 builds the poisoned model).
// Every requester is a bench process with the protocol of design 1.5: its
// request, address, data, write enable and byte enables come from registers
// (NBA at the clock edge) and stay put while it waits; the grant comes back
// combinationally in the same clock.
//
//   R  core fixed (cr_fix: reads with cr_fix_use in k[1..3], byte writes at
//      commits, noise elsewhere; one-clock requests, never retried), P32
//      and pointer write (retry until granted), audio (ISSUE until
//      aud_take, then one CAPTURE clock, then a gap), copy engine and F6
//      (cp_req; retry), with random addresses biased to a few words
//   S  core (cs_req, one clock), call port (cl_req, retry), F6 clear (cz)
//   A  lookahead (look_req, one clock), audio sample (retry), copy/F6 source
//   control: fe_phase_gen (+pg_mode, default all) gives pclk1/pclk0/access/
//      a_in; the bench's own copy of design 2.1 gives k, commit, ev_short.
//      sel_up random in runs; f6_act in rare bursts; a bench flywheel gives
//      locked/phb_next (period 3) in long locked and unlocked stretches, and
//      guard_on = locked & a random window; op.c.cdsw/cdsp, p32_q, rdP,
//      wb_v random; ev_guard_sup = guard_on & (cr_fix | cr_p32) (u_core's
//      formula).
//
// Checks, every clock (design 12.3 items 1-5; counters in the summary):
//   own   own_r/own_s/own_a one-hot or 0, and equal to the reference owner:
//         the highest-priority eligible requester of 3.1-3.3 (an independent
//         restatement: F6 > core fixed > audio > P32 > pointer write > copy
//         on R, with the guard's and F6's eligibility; cz > core > call on
//         S; F6 source > lookahead > audio sample > copy source on A)
//   port  crb_*/stb_*/fea_addr are the owner's address, write enable, byte
//         enables and data (be/data checked on writes); no owner: address
//         0, no write, be 0, data 0 (parked)
//   gnt   every grant output equals "this requester owns the port"
//   aud   aud_take == upstream's rule: aud_issue & !sel_up & !fix_eff &
//         !f6_act & (!guard_on | phb_next)
//   yld   no P32, pointer or copy grant in a clock where the audio has
//         upstream's grant edge (aud_issue & !sel_up)
//   grd   while guard_on: no R write but F6's; no core fixed or P32 owner
//         (suppressed and parked); every non-F6 R access (the audio's) in a
//         phb_next clock, i.e. registered on the phase-B edge
//   use   crb_use == "the previous clock granted a consumed read" (core fixed
//         with cr_fix_use, P32, audio), and in every crb_use clock crb_q is
//         the word the bench's shadow holds at that read's address
//   mem   every S read and A read returns the shadow's word / the image's
//   asr   ev_grant_steal, a_collide, a_wb_late, a_p32_late, a_guard_core,
//         a_guard_wr, a_owner against the bench's restatement of 3.6
//         (per-cycle bookkeeping from k[0]); the random stimulus makes each
//         fire, so each formula is exercised both ways
// At the end every owner, every contention pair, every guard effect and
// every assertion must have been seen a minimum number of times.
//
// +cycles=N clocks (default 2000000), +seed=N, +verbose=1; fe_phase_gen's
// +pg_* plusargs.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_arb;
	import daria_fe_pkg::*;

	logic clk = 1'b0;
	always #34.92 clk = !clk;

	longint cycles  = 2_000_000;
	int     verbose = 0;
	int unsigned seed = 1;
	int unsigned rs = 1;
	function automatic int unsigned rnd();
		rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
		return rs;
	endfunction
	function automatic bit pm(input int permille);   // true with probability permille/1000
		return (rnd() % 1000) < permille;
	endfunction

	// ======================================================================================
	// the phases and the bench's copy of daria_fe_seq (design 2.1)
	// ======================================================================================
	wire        pclk1, pclk0, access, rw;
	wire [12:0] a_in;
	logic       run = 1'b0;
	fe_phase_gen #(.SEED(7), .MODE("all")) pg (
		.clk_sys(clk), .run(run), .stall(1'b0), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(pclk1), .pclk0(pclk0), .mapper_phi2(), .access(access),
		.a_in(a_in), .rw(rw), .d_in(), .pause(), .load(), .stall_eff(), .ibusy(), .held(),
		.len1(), .len2());
	logic [7:0] k = 8'h80;
	always_ff @(posedge clk) k <= pclk1 ? 8'h01 : (k[7] ? k : {k[6:0], 1'b0});
	wire commit   = access & a_in[12];
	wire ev_short = commit & !(k[5] | k[6] | k[7]);

	// ======================================================================================
	// requesters (registered)
	// ======================================================================================
	logic        cr_fix = 0, cr_fix_we = 0, cr_fix_use = 0;
	logic [12:0] cr_fix_a = 0;
	logic  [3:0] cr_fix_be = 0;
	logic [31:0] cr_fix_wd = 0;
	logic        cr_p32 = 0;
	logic [12:0] cr_p32_a = 0;
	logic        cr_wb = 0;
	logic [12:0] cr_wb_a = 0;
	logic [31:0] cr_wb_wd = 0;
	logic        cs_req = 0, cs_we = 0;
	logic  [7:0] cs_a = 0;
	logic  [3:0] cs_be = 0;
	logic [31:0] cs_wd = 0;
	logic        look_req = 0;
	logic [12:0] look_a = 0;
	logic        aud_issue = 0;
	logic [14:0] aud_addr = 0;
	logic  [3:0] aud_gap = 0;
	logic        aud_cap = 0;
	logic        aud_a_req = 0;
	logic [12:0] aud_a_a = 0;
	logic        cl_req = 0, cl_we = 0;
	logic  [7:0] cl_a = 0;
	logic [31:0] cl_wd = 0;
	logic        cp_req = 0, cp_we = 0;
	logic [12:0] cp_a = 0;
	logic  [3:0] cp_be = 0;
	logic [31:0] cp_wd = 0;
	logic        cz_req = 0;
	logic  [7:0] cz_a = 0;
	logic        ca_req = 0;
	logic [12:0] ca_a = 0;
	logic        sel_up = 0;
	logic        f6_act = 0;
	int          f6_len = 0;
	logic        lk_b = 0, gw = 0;            // the guard's lock and window
	logic  [1:0] ph_b = 0;
	wire         phb_next = lk_b & (ph_b == 2'd0);
	wire         guard_on = lk_b & gw;
	dec_t        op = '0;
	logic        p32_q = 0, rdP = 0, wb_v = 0;
	wire         ev_guard_sup = guard_on & (cr_fix | cr_p32);   // u_core's formula

	// the DUT's outputs
	wire [12:0] fea_addr, crb_addr;
	wire        crb_we, stb_we;
	wire  [3:0] crb_be, stb_be;
	wire [31:0] crb_wd, stb_wd;
	wire  [7:0] stb_addr;
	wire        aud_take, p32_gnt, wb_gnt, cp_gnt, cl_gnt, look_gnt, aud_a_gnt, ca_gnt, crb_use;

	daria_fe_arb dut (
		.clk_sys(clk),
		.cr_fix, .cr_fix_a, .cr_fix_we, .cr_fix_be, .cr_fix_wd, .cr_fix_use,
		.cr_p32, .cr_p32_a, .cr_wb, .cr_wb_a, .cr_wb_wd,
		.cs_req, .cs_a, .cs_we, .cs_be, .cs_wd,
		.look_req, .look_a,
		.aud_issue, .aud_addr, .aud_a_req, .aud_a_a,
		.cl_req, .cl_a, .cl_we, .cl_wd,
		.cp_req, .cp_a, .cp_we, .cp_be, .cp_wd, .cz_req, .cz_a, .ca_req, .ca_a,
		.sel_up, .guard_on, .phb_next, .f6_act,
		.ev_short, .k, .commit, .op, .p32_q, .rdP, .wb_v, .ev_guard_sup,
		.fea_addr, .crb_addr, .crb_we, .crb_be, .crb_wd, .stb_addr, .stb_we, .stb_be, .stb_wd,
		.aud_take, .p32_gnt, .wb_gnt, .cp_gnt, .cl_gnt, .look_gnt, .aud_a_gnt, .ca_gnt, .crb_use);

	// ======================================================================================
	// the memories
	// ======================================================================================
	wire [31:0] fea_q, crb_q, stb_q;
	logic       cap_we = 0;
	logic [14:0] cap_addr = 0;
	logic  [7:0] cap_data = 0;
	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(1'b0), .clk_sys(clk),
		.rom_addr(15'd0), .win_qa(), .d_addr(32'd0), .win_qb(), .ram_we(1'b0), .ram_be(4'd0),
		.ram_wdata(32'd0), .ram_q(),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(8'd0), .sta_we(1'b0), .sta_wd(32'd0), .sta_q(),
		.cap_we, .cap_addr, .cap_data,
		.fea_addr, .fea_q, .feb_addr(13'd0), .feb_q(),
		.crb_addr, .crb_we, .crb_be, .crb_wd, .crb_q,
		.stb_addr, .stb_we, .stb_be, .stb_wd, .stb_q);
	logic [31:0] sh_r [0:8191];               // the bench's shadow of cart RAM
	logic [31:0] sh_s [0:255];                // ... of the state RAM
	logic [31:0] img  [0:8191];               // the front-end ROM image
	initial begin
		for (int i = 0; i < 8192; i++) sh_r[i] = 32'd0;
		for (int i = 0; i < 256; i++)  sh_s[i] = 32'd0;
	end

	// random addresses: a few hot words (collisions of interest) or anywhere
	function automatic logic [12:0] ra13();
		return pm(500) ? 13'(rnd() % 8) : 13'(rnd());
	endfunction
	function automatic logic [7:0] ra8();
		return pm(500) ? 8'(rnd() % 8) : 8'(rnd());
	endfunction
	function automatic logic [3:0] rbe();
		logic [3:0] b;
		case (rnd() % 4)
			0:       b = 4'hF;
			1:       b = 4'b0001 << (rnd() % 4);
			default: b = 4'(rnd());
		endcase
		return b;
	endfunction

	// ======================================================================================
	// the stimulus (all at the edge, as registers)
	// ======================================================================================
	bit loading = 1'b1;
	always @(posedge clk) begin : stim
		bit kfix, fwe;
		if (!loading) begin
			// core fixed: reads in k[1..3] (consumed), byte writes at commits (DSWRITE,
			// PUSH/WRITE), noise anywhere
			kfix = (k[1] | k[2] | k[3]) ? pm(400) : (commit ? pm(300) : pm(30));
			fwe  = commit ? pm(700) : pm(100);
			cr_fix     <= kfix;
			cr_fix_we  <= fwe;
			cr_fix_a   <= ra13();
			cr_fix_be  <= rbe();
			cr_fix_wd  <= rnd();
			cr_fix_use <= !fwe & pm(950);      // u_core: a consumed read (never a write)
			// P32 read and pointer write: hold until granted
			if (cr_p32) begin if (p32_gnt) cr_p32 <= 1'b0; end
			else if ((k[1] | k[2]) ? pm(150) : pm(10)) begin cr_p32 <= 1'b1; cr_p32_a <= ra13(); end
			if (cr_wb) begin if (wb_gnt) cr_wb <= 1'b0; end
			else if (pm(60)) begin cr_wb <= 1'b1; cr_wb_a <= ra13(); cr_wb_wd <= rnd(); end
			// audio: ISSUE until taken, one CAPTURE clock, a gap
			if (aud_issue) begin
				if (aud_take) begin aud_issue <= 1'b0; aud_cap <= 1'b1; aud_gap <= 4'(rnd() % 4); end
			end else if (aud_cap) begin
				aud_cap <= 1'b0;
				if (aud_gap == 0) begin aud_issue <= 1'b1; aud_addr <= {ra13(), 2'(rnd())}; end
			end else if (aud_gap != 0) aud_gap <= aud_gap - 4'd1;
			else if (pm(300)) begin aud_issue <= 1'b1; aud_addr <= {ra13(), 2'(rnd())}; end
			// copy engine / F6 on R: hold until granted
			if (cp_req) begin if (cp_gnt) cp_req <= 1'b0; end
			else if (f6_act ? pm(700) : pm(60)) begin
				cp_req <= 1'b1; cp_we <= pm(900); cp_a <= ra13(); cp_be <= rbe(); cp_wd <= rnd();
			end
			// S: core one clock; call port until granted; F6 clear
			cs_req <= pm(200);
			cs_we  <= pm(300);
			cs_a   <= ra8();
			cs_be  <= rbe();
			cs_wd  <= rnd();
			if (cl_req) begin if (cl_gnt) cl_req <= 1'b0; end
			else if (pm(150)) begin cl_req <= 1'b1; cl_we <= pm(500); cl_a <= ra8(); cl_wd <= rnd(); end
			cz_req <= f6_act ? pm(500) : pm(5);
			cz_a   <= ra8();
			// A: lookahead one clock (mostly k[0]); audio sample and copy source until granted
			look_req <= k[0] ? pm(700) : pm(50);
			look_a   <= ra13();
			if (aud_a_req) begin if (aud_a_gnt) aud_a_req <= 1'b0; end
			else if (pm(100)) begin aud_a_req <= 1'b1; aud_a_a <= ra13(); end
			if (ca_req) begin if (ca_gnt) ca_req <= 1'b0; end
			else if (f6_act ? pm(600) : pm(80)) begin ca_req <= 1'b1; ca_a <= ra13(); end
			// control
			if (pm(100)) sel_up <= !sel_up;
			if (f6_act) begin
				if (f6_len == 0) f6_act <= 1'b0; else f6_len <= f6_len - 1;
			end else if ((rnd() % 2000) == 0) begin f6_act <= 1'b1; f6_len <= 20 + int'(rnd() % 100); end
			ph_b <= (ph_b == 2'd2) ? 2'd0 : ph_b + 2'd1;
			if (lk_b ? pm(1) : pm(2)) lk_b <= !lk_b;
			if (pm(30)) gw <= !gw;
			op.c.cdsw <= pm(200);
			op.c.cdsp <= pm(100);
			p32_q     <= pm(300);
			rdP       <= pm(300);
			wb_v      <= pm(50);
		end
	end

	// ======================================================================================
	// the reference (design 3.1-3.3, 3.6) and the checks
	// ======================================================================================
	longint n = 0;
	longint errs = 0;
	// counters (coverage and results)
	longint c_own_r [6], c_own_s [3], c_own_a [4];
	longint c_none_r = 0, c_none_s = 0, c_none_a = 0;
	longint c_fix_aud = 0, c_aud_p32 = 0, c_p32_wb = 0, c_wb_cp = 0, c_f6_any = 0, c_fix_p32 = 0;
	longint c_s_cz_cs = 0, c_s_cs_cl = 0, c_a_look_aud = 0, c_a_aud_ca = 0, c_a_f6_look = 0;
	longint c_aud_edge = 0, c_yield_wait = 0;
	longint c_g_on = 0, c_g_phb = 0, c_g_aud_phb = 0, c_g_aud_wait = 0, c_g_sup = 0, c_g_wr_wait = 0, c_g_f6wr = 0;
	longint c_use = 0, c_rd_chk = 0, c_s_chk = 0, c_a_chk = 0;
	longint c_steal = 0, c_collide = 0, c_wb_late = 0, c_p32_late = 0, c_guard_core = 0, c_guard_wr = 0;
	longint c_short = 0, c_commit = 0;
	longint e_own = 0, e_port = 0, e_gnt = 0, e_aud = 0, e_yld = 0, e_grd = 0, e_use = 0, e_mem = 0, e_asr = 0;
	// per-cycle bookkeeping (from k[0]) for the assertions
	bit cyc_short = 0, cyc_sup = 0, cyc_commit = 0;
	// the previous clock's read, for crb_use and the q checks
	bit         use_exp = 0;
	bit         r_rd = 0, s_rd = 0, a_rd = 0;
	logic [12:0] r_rd_a = 0, a_rd_a = 0;
	logic  [7:0] s_rd_a = 0;

	task automatic bad(inout longint cnt, input string what);
		cnt++;
		errs++;
		if (verbose || errs <= 20)
			$display("ERROR clock %0d: %s (k %b guard %0d phb %0d f6 %0d sel_up %0d)", n, what, k, guard_on, phb_next,
				f6_act, sel_up);
	endtask

	always @(posedge clk) begin : chk
		int   ro, so, ao;                     // reference owners (-1: none)
		logic [5:0] er;
		logic [2:0] es;
		logic [3:0] ea;
		bit   fixe, aude, p32e, wbe, cpe, f6e;
		logic [12:0] xa;
		bit   xwe;
		logic [3:0] xbe;
		logic [31:0] xwd;
		bit   fix_eff_r, take_r, steal_r, sh_c, sup_c, cm_c, gcore_r, gwr_r;
		if (!loading) begin
			n++;
			// ---- R: the highest-priority eligible requester ------------------------------
			f6e  = cp_req & f6_act;
			fixe = cr_fix & !guard_on & !f6_act;
			aude = aud_issue & !sel_up & !f6_act & (!guard_on | phb_next);
			p32e = cr_p32 & !guard_on & !f6_act;
			wbe  = cr_wb & !guard_on & !f6_act;
			cpe  = cp_req & !guard_on & !f6_act;
			ro = f6e ? OR_F6 : fixe ? OR_FIX : aude ? OR_AUD : p32e ? OR_P32 : wbe ? OR_WB : cpe ? OR_COPY : -1;
			er = (ro < 0) ? 6'd0 : 6'(1 << ro);
			if (!$onehot0(dut.own_r)) bad(e_own, $sformatf("own_r %b not one-hot", dut.own_r));
			if (dut.own_r !== er) bad(e_own, $sformatf("own_r %b, expected %b", dut.own_r, er));
			if (ro < 0) c_none_r++; else c_own_r[ro]++;
			// the port: the owner's access, or parked
			xa = 13'd0; xwe = 1'b0; xbe = 4'd0; xwd = 32'd0;
			case (ro)
				OR_F6, OR_COPY: begin xa = cp_a; xwe = cp_we; xbe = cp_be; xwd = cp_wd; end
				OR_FIX:  begin xa = cr_fix_a; xwe = cr_fix_we; xbe = cr_fix_be; xwd = cr_fix_wd; end
				OR_AUD:  xa = aud_addr[14:2];
				OR_P32:  xa = cr_p32_a;
				OR_WB:   begin xa = cr_wb_a; xwe = 1'b1; xbe = 4'hF; xwd = cr_wb_wd; end
				default: ;
			endcase
			if (crb_addr !== xa || crb_we !== xwe || (((xwe || ro < 0)) && (crb_be !== xbe || crb_wd !== xwd)))
				bad(e_port, $sformatf("R port %h/%0d/%h/%h, expected %h/%0d/%h/%h (owner %0d)", crb_addr, crb_we,
					crb_be, crb_wd, xa, xwe, xbe, xwd, ro));
			// the grants
			if (aud_take !== (ro == OR_AUD) || p32_gnt !== (ro == OR_P32) || wb_gnt !== (ro == OR_WB) ||
			    cp_gnt !== (ro == OR_F6 || ro == OR_COPY))
				bad(e_gnt, $sformatf("R grants aud %0d p32 %0d wb %0d cp %0d (owner %0d)", aud_take, p32_gnt,
					wb_gnt, cp_gnt, ro));
			// aud_take is upstream's grant rule with !fix_eff (3.1, F3)
			fix_eff_r = cr_fix & !guard_on & !f6_act;
			take_r    = aud_issue & !sel_up & !fix_eff_r & !f6_act & (!guard_on | phb_next);
			if (aud_take !== take_r) bad(e_aud, "aud_take != upstream's rule");
			// yields never take an audio edge (3.4 (b))
			if (aud_issue & !sel_up) begin
				c_aud_edge++;
				if (p32_gnt | wb_gnt | (cp_gnt & !f6_act)) bad(e_yld, "a yielding user took an audio edge");
				if (cr_p32 | cr_wb | (cp_req & !f6_act)) c_yield_wait++;
			end
			// contention coverage
			if (cr_fix & aud_issue & !sel_up & !guard_on & !f6_act) c_fix_aud++;
			if (cr_fix & cr_p32 & !guard_on & !f6_act) c_fix_p32++;
			if (aud_issue & !sel_up & cr_p32 & !guard_on & !f6_act) c_aud_p32++;
			if (cr_p32 & cr_wb & !guard_on & !f6_act) c_p32_wb++;
			if (cr_wb & cp_req & !guard_on & !f6_act) c_wb_cp++;
			if (f6_act & cp_req & (cr_fix | aud_issue | cr_p32 | cr_wb)) c_f6_any++;
			// the guard (3.5)
			if (guard_on) begin
				c_g_on++;
				if (phb_next) c_g_phb++;
				if (crb_we && ro != OR_F6) bad(e_grd, "a non-F6 R write under the guard");
				if (ro == OR_FIX || ro == OR_P32) bad(e_grd, "a suppressed core request owns R");
				if (ro >= 0 && ro != OR_F6 && !(ro == OR_AUD && phb_next)) bad(e_grd, "an R access off phase B");
				if (ro == OR_AUD) c_g_aud_phb++;
				if (aud_issue & !sel_up & !f6_act & !phb_next) c_g_aud_wait++;
				if ((cr_fix | cr_p32) & !f6_act) begin
					c_g_sup++;
					if (ro < 0 && (crb_addr !== 13'd0 || crb_we !== 1'b0)) bad(e_grd, "suppressed request not parked");
				end
				if ((cr_wb | (cp_req & cp_we & !f6_act) | (cr_fix & cr_fix_we)) & !f6_act) c_g_wr_wait++;
				if (ro == OR_F6 && crb_we) c_g_f6wr++;
			end
			// crb_use: the clock after a granted consumed read, and its q
			if (crb_use !== use_exp) bad(e_use, $sformatf("crb_use %0d, expected %0d", crb_use, use_exp));
			if (use_exp) begin
				c_use++;
				if (crb_q !== sh_r[r_rd_a]) bad(e_mem, $sformatf("consumed R read of %h: %h, shadow %h", r_rd_a, crb_q, sh_r[r_rd_a]));
			end
			if (r_rd) begin
				c_rd_chk++;
				if (crb_q !== sh_r[r_rd_a]) bad(e_mem, $sformatf("R read of %h: %h, shadow %h", r_rd_a, crb_q, sh_r[r_rd_a]));
			end
			use_exp = (ro == OR_FIX && cr_fix_use) || ro == OR_P32 || ro == OR_AUD;
			r_rd    = (ro >= 0) && !xwe;
			r_rd_a  = xa;
			if (xwe) for (int b = 0; b < 4; b++) if (xbe[b]) sh_r[xa][8*b +: 8] = xwd[8*b +: 8];

			// ---- S ---------------------------------------------------------------------------
			so = cz_req ? OS_CZ : cs_req ? OS_CORE : cl_req ? OS_CALL : -1;
			es = (so < 0) ? 3'd0 : 3'(1 << so);
			if (!$onehot0(dut.own_s) || dut.own_s !== es) bad(e_own, $sformatf("own_s %b, expected %b", dut.own_s, es));
			if (so < 0) c_none_s++; else c_own_s[so]++;
			if (cz_req & cs_req) c_s_cz_cs++;
			if (cs_req & cl_req & !cz_req) c_s_cs_cl++;
			xa = 13'd0; xwe = 1'b0; xbe = 4'd0; xwd = 32'd0;
			case (so)
				OS_CZ:   begin xa = 13'(cz_a); xwe = 1'b1; xbe = 4'hF; xwd = 32'd0; end
				OS_CORE: begin xa = 13'(cs_a); xwe = cs_we; xbe = cs_be; xwd = cs_wd; end
				OS_CALL: begin xa = 13'(cl_a); xwe = cl_we; xbe = 4'hF; xwd = cl_wd; end
				default: ;
			endcase
			if (stb_addr !== xa[7:0] || stb_we !== xwe || ((xwe || so < 0) && (stb_be !== xbe || stb_wd !== xwd)))
				bad(e_port, $sformatf("S port %h/%0d/%h/%h, expected %h/%0d/%h/%h (owner %0d)", stb_addr, stb_we,
					stb_be, stb_wd, xa[7:0], xwe, xbe, xwd, so));
			if (cl_gnt !== (so == OS_CALL)) bad(e_gnt, "cl_gnt");
			if (s_rd) begin
				c_s_chk++;
				if (stb_q !== sh_s[s_rd_a]) bad(e_mem, $sformatf("S read of %h: %h, shadow %h", s_rd_a, stb_q, sh_s[s_rd_a]));
			end
			s_rd   = (so >= 0) && !xwe;
			s_rd_a = xa[7:0];
			if (xwe) for (int b = 0; b < 4; b++) if (xbe[b]) sh_s[xa[7:0]][8*b +: 8] = xwd[8*b +: 8];

			// ---- A ---------------------------------------------------------------------------
			ao = (ca_req & f6_act) ? OA_F6 : (look_req & !f6_act) ? OA_LOOK : (aud_a_req & !f6_act) ? OA_AUD :
			     (ca_req & !f6_act) ? OA_COPY : -1;
			ea = (ao < 0) ? 4'd0 : 4'(1 << ao);
			if (!$onehot0(dut.own_a) || dut.own_a !== ea) bad(e_own, $sformatf("own_a %b, expected %b", dut.own_a, ea));
			if (ao < 0) c_none_a++; else c_own_a[ao]++;
			if (look_req & aud_a_req & !f6_act) c_a_look_aud++;
			if (aud_a_req & ca_req & !f6_act & !look_req) c_a_aud_ca++;
			if (f6_act & ca_req & look_req) c_a_f6_look++;
			case (ao)
				OA_F6, OA_COPY: xa = ca_a;
				OA_LOOK: xa = look_a;
				OA_AUD:  xa = aud_a_a;
				default: xa = 13'd0;
			endcase
			if (fea_addr !== xa) bad(e_port, $sformatf("fea_addr %h, expected %h (owner %0d)", fea_addr, xa, ao));
			if (look_gnt !== (ao == OA_LOOK) || aud_a_gnt !== (ao == OA_AUD) || ca_gnt !== (ao == OA_F6 || ao == OA_COPY))
				bad(e_gnt, "A grants");
			if (a_rd) begin
				c_a_chk++;
				if (fea_q !== img[a_rd_a]) bad(e_mem, $sformatf("A read of %h: %h, image %h", a_rd_a, fea_q, img[a_rd_a]));
			end
			a_rd   = 1'b1;                    // port A reads every clock (parked: word 0)
			a_rd_a = xa;

			// ---- the assertions (3.6) ----------------------------------------------------------
			if (commit) c_commit++;
			if (ev_short) c_short++;
			steal_r = aud_issue & !sel_up & (ro == OR_FIX);
			sh_c  = ev_short     | (cyc_short  & !k[0]);
			sup_c = ev_guard_sup | (cyc_sup    & !k[0]);
			cm_c  = commit       | (cyc_commit & !k[0]);
			gcore_r = (commit & sup_c) | (ev_guard_sup & cyc_commit & !k[0]);
			gwr_r   = guard_on & ((cr_fix & cr_fix_we) | cr_wb | (cp_req & cp_we & !f6_act));
			if (dut.ev_grant_steal !== steal_r) bad(e_asr, "ev_grant_steal");
			if (dut.a_collide !== (steal_r & !sh_c)) bad(e_asr, "a_collide");
			if (dut.a_wb_late !== (wb_v & k[1])) bad(e_asr, "a_wb_late");
			if (dut.a_p32_late !== (k[3] & (op.c.cdsw | op.c.cdsp) & !(p32_q | rdP) & !guard_on)) bad(e_asr, "a_p32_late");
			if (dut.a_guard_core !== gcore_r) bad(e_asr, "a_guard_core");
			if (dut.a_guard_wr !== gwr_r) bad(e_asr, "a_guard_wr");
			if (dut.a_owner !== 1'b0) bad(e_asr, "a_owner");
			if (steal_r) c_steal++;
			if (dut.a_collide) c_collide++;
			if (dut.a_wb_late) c_wb_late++;
			if (dut.a_p32_late) c_p32_late++;
			if (dut.a_guard_core) c_guard_core++;
			if (dut.a_guard_wr) c_guard_wr++;
			cyc_short = sh_c; cyc_sup = sup_c; cyc_commit = cm_c;
		end
	end

	// ======================================================================================
	// run
	// ======================================================================================
	function automatic bit need(input longint v, input longint m, input string what);
		if (v < m) begin $display("COVERAGE: %s = %0d < %0d", what, v, m); return 1'b1; end
		return 1'b0;
	endfunction

	initial begin
		int miss;
		void'($value$plusargs("cycles=%d", cycles));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("verbose=%d", verbose));
		rs = seed * 32'h9E37_79B9 + 32'h7F4A_7C15;
		if (rs == 0) rs = 1;
		foreach (c_own_r[i]) c_own_r[i] = 0;
		foreach (c_own_s[i]) c_own_s[i] = 0;
		foreach (c_own_a[i]) c_own_a[i] = 0;
		// load the front-end ROM through the capture port (port A, cap_we)
		for (int i = 0; i < 8192; i++) img[i] = rnd();
		@(negedge clk);
		for (int i = 0; i < 32768; i++) begin
			cap_we = 1'b1; cap_addr = 15'(i); cap_data = img[i >> 2][8 * (i % 4) +: 8];
			@(negedge clk);
		end
		cap_we = 1'b0;
		@(negedge clk);
		run = 1'b1;
		@(posedge clk);
		loading = 1'b0;
		wait (n >= cycles);
		@(negedge clk);
		$display("tb_fe_arb: %0d clocks, seed %0d, %0d commits (%0d short)", n, seed, c_commit, c_short);
		$display("  R owners: F6 %0d fixed %0d audio %0d P32 %0d pointer %0d copy %0d none %0d",
			c_own_r[0], c_own_r[1], c_own_r[2], c_own_r[3], c_own_r[4], c_own_r[5], c_none_r);
		$display("  S owners: clear %0d core %0d call %0d none %0d; A owners: F6 %0d look %0d audio %0d copy %0d none %0d",
			c_own_s[0], c_own_s[1], c_own_s[2], c_none_s, c_own_a[0], c_own_a[1], c_own_a[2], c_own_a[3], c_none_a);
		$display("  contention: fix/aud %0d fix/p32 %0d aud/p32 %0d p32/wb %0d wb/copy %0d F6/any %0d; S cz/core %0d core/call %0d; A look/aud %0d aud/copy %0d F6/look %0d",
			c_fix_aud, c_fix_p32, c_aud_p32, c_p32_wb, c_wb_cp, c_f6_any, c_s_cz_cs, c_s_cs_cl, c_a_look_aud, c_a_aud_ca, c_a_f6_look);
		$display("  audio edges %0d (a yielding user waiting in %0d); guard on %0d (phb %0d): audio on phase B %0d, audio waiting %0d, suppressed %0d, writes waiting %0d, F6 writes %0d",
			c_aud_edge, c_yield_wait, c_g_on, c_g_phb, c_g_aud_phb, c_g_aud_wait, c_g_sup, c_g_wr_wait, c_g_f6wr);
		$display("  reads checked: R %0d (consumed %0d), S %0d, A %0d", c_rd_chk, c_use, c_s_chk, c_a_chk);
		$display("  assertions (formula checked every clock): steal %0d collide %0d wb_late %0d p32_late %0d guard_core %0d guard_wr %0d",
			c_steal, c_collide, c_wb_late, c_p32_late, c_guard_core, c_guard_wr);
		$display("  errors: own %0d port %0d gnt %0d aud %0d yld %0d grd %0d use %0d mem %0d asr %0d",
			e_own, e_port, e_gnt, e_aud, e_yld, e_grd, e_use, e_mem, e_asr);
		miss = 0;
		if (cycles >= 1_000_000) begin
			for (int i = 0; i < 6; i++) miss += need(c_own_r[i], 1000, $sformatf("R owner %0d", i));
			for (int i = 0; i < 3; i++) miss += need(c_own_s[i], 1000, $sformatf("S owner %0d", i));
			for (int i = 0; i < 4; i++) miss += need(c_own_a[i], 1000, $sformatf("A owner %0d", i));
			miss += need(c_fix_aud, 1000, "fix/aud") + need(c_fix_p32, 1000, "fix/p32") + need(c_aud_p32, 1000, "aud/p32");
			miss += need(c_p32_wb, 1000, "p32/wb") + need(c_wb_cp, 1000, "wb/copy") + need(c_f6_any, 100, "F6/any");
			miss += need(c_s_cz_cs, 100, "S cz/core") + need(c_s_cs_cl, 1000, "S core/call");
			miss += need(c_a_look_aud, 1000, "A look/aud") + need(c_a_aud_ca, 1000, "A aud/copy") + need(c_a_f6_look, 100, "A F6/look");
			miss += need(c_yield_wait, 1000, "yield waiting at an audio edge");
			miss += need(c_g_aud_phb, 1000, "guard: audio on phase B") + need(c_g_aud_wait, 1000, "guard: audio waiting");
			miss += need(c_g_sup, 1000, "guard: suppressed") + need(c_g_wr_wait, 1000, "guard: write waiting");
			miss += need(c_g_f6wr, 10, "guard: F6 write");
			miss += need(c_use, 10000, "consumed reads") + need(c_s_chk, 10000, "S reads");
			if (pg.k_ph1_2 + pg.k_ph1_4 > 0) miss += need(c_short, 1000, "short cycles");   // the preset makes them
			miss += need(c_steal, 1000, "steal") + need(c_collide, 100, "collide") + need(c_wb_late, 100, "wb_late");
			miss += need(c_p32_late, 100, "p32_late") + need(c_guard_core, 100, "guard_core") + need(c_guard_wr, 100, "guard_wr");
		end
		if (errs != 0 || miss != 0) $fatal(1, "tb_fe_arb: FAIL (%0d errors, %0d coverage holes)", errs, miss);
		$display("tb_fe_arb: PASS");
		$finish;
	end
endmodule

`default_nettype wire
