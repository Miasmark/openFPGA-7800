//------------------------------------------------------------------------------
// tb_fe_seq: unit bench of daria_fe_seq (docs/daria_fe/design.md 2.1, 12.3).
//
// Several fe_phase_gen streams (each preset of phase_gen.svh, its own seed),
// each with its own daria_fe_seq and an independent reference:
//   k, c, ph2  against edge counts kept by the bench (edges since the last
//              pclk1 / commit, saturating; the last pulse seen), every clock
//              and at power-up;
//   rel_ok     never in a pclk1 clock, always from the pclk0 clock to the
//              next pclk1, never inside phase 1 (pauses included);
//   ph1_open   exactly the clocks after the pclk1 clock and before the pclk0
//              clock (the pclk1 clock is still phase 2); commit = access & a_in[12];
//   ev_short   at each commit, exactly when C < E0+6;
//   release    a model 6507 whose busy (the bench's stall, beside the
//              generator's own) rises at random write commits and falls only on
//              the DUT's rel_ok never commits a held address twice: each new
//              (loaded) cycle gets an id, its held repeats keep it, and a
//              second commit of an id is a failure.
// A last stream (MUT = 1) lets its busy fall at any edge: it must show double
// commits, which proves the release check can see them.
// Plusargs: +seq_clocks=N (default 3,000,000 per stream), +seq_seed=N.
// Passes iff every check is 0 and every feature was seen; $fatal otherwise.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_seq_unit #(
	parameter int    SEED_OFS = 0,
	parameter string MODE     = "mix",
	parameter bit    MUT      = 1'b0,
	parameter int    PH1_4    = -1          // -1: the preset's; 0: no phase 1 of 4 (legal streams, L-5)
) (
	input  wire clk,
	input  wire run,
	input  int  seed
);
	// ---- the stream ------------------------------------------------------------------
	logic        bb;                         // the bench's busy (the stall it drives)
	wire         pclk1, pclk0, mapper_phi2, access, pause, load, stall_eff, ibusy, held;
	wire  [12:0] a_in;
	wire         rw;
	wire   [7:0] d_in;
	wire   [5:0] len1, len2;
	fe_phase_gen #(.SEED(1), .SEED_OFS(SEED_OFS), .MODE(MODE), .USE_PLUSARGS(1'b0)) pg (
		.clk_sys(clk), .run(run), .stall(bb), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1, .pclk0, .mapper_phi2, .access, .a_in, .rw, .d_in, .pause, .load,
		.stall_eff, .ibusy, .held, .len1, .len2);

	// ---- the DUT ----------------------------------------------------------------------
	wire [7:0] k;
	wire [3:0] c;
	wire       ph2, commit, ph1_open, rel_ok, ev_short;
	daria_fe_seq dut (
		.clk_sys(clk), .pclk1, .pclk0, .access, .a12(a_in[12]),
		.k, .c, .ph2, .commit, .ph1_open, .rel_ok, .ev_short);

	// ---- the bench's random stream (xorshift32, its own) --------------------------------
	logic [31:0] rs;
	function automatic int unsigned rnd(input int unsigned n);
		rs = rs ^ (rs << 13);
		rs = rs ^ (rs >> 17);
		rs = rs ^ (rs << 5);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	initial begin
		bb = 1'b0;
		rs = 32'hC0FF_EE11 ^ (32'(SEED_OFS + 1) * 32'h9E37_79B9);
		#1 rs = rs ^ 32'(seed);
		if (PH1_4 >= 0) pg.k_ph1_4 = PH1_4;     // after the generator's preset; read per cycle
		if (rs == 0) rs = 32'd1;
	end

	// ---- the reference -----------------------------------------------------------------------
	int  e0n = 7;                            // edges since the last E0 (saturates at 7)
	int  cn  = 3;                            // edges since the last C (saturates at 3)
	bit  seen0 = 1'b0;                       // the last pulse was pclk0
	int  bb_left;
	int  cyc_id = 0;
	bit  cyc_done = 1'b0;                    // this id has committed
	// counts
	longint clocks, n_e0, n_commit, n_short, n_held_cyc, n_held_commit, n_bb, n_bb_fall;
	longint e_k, e_c, e_ph2, e_rel, e_open, e_commit, e_short, e_double, e_pwr;
	longint seen_l1 [0:31];
	longint seen_l2 [0:31];
	longint n_pause1, n_pause2;
	bit     pz_prev = 1'b0;

	initial begin
		clocks = 0; n_e0 = 0; n_commit = 0; n_short = 0; n_held_cyc = 0; n_held_commit = 0;
		n_bb = 0; n_bb_fall = 0; e_k = 0; e_c = 0; e_ph2 = 0; e_rel = 0; e_open = 0;
		e_commit = 0; e_short = 0; e_double = 0; e_pwr = 0; n_pause1 = 0; n_pause2 = 0;
		for (int i = 0; i < 32; i++) begin seen_l1[i] = 0; seen_l2[i] = 0; end
		#0.1;
		if (k !== 8'h80 || c !== 4'h8 || ph2 !== 1'b0) e_pwr++;   // power-up values (2.1)
	end

	// every clock, pre-edge
	always @(posedge clk) begin
		if (run) begin
			clocks++;
			// combinational outputs in this clock
			if (commit !== (access & a_in[12])) e_commit++;
			if (pclk1) begin
				if (rel_ok !== 1'b0) e_rel++;
			end else if (pclk0) begin
				if (rel_ok !== 1'b1) e_rel++;
			end else if (rel_ok !== seen0) e_rel++;
			if (ph1_open !== (!seen0 && !pclk0)) e_open++;      // the pclk1 clock is still phase 2
			// registered outputs in this clock against the counts
			if (k !== (8'h01 << e0n)) e_k++;
			if (c !== (4'h1 << cn)) e_c++;
			if (ph2 !== seen0) e_ph2++;
			if (commit) begin
				n_commit++;
				if (ev_short !== (e0n < 5)) e_short++;            // C = E0 + e0n + 1 < E0+6
				if (e0n < 5) n_short++;
				if (held) n_held_commit++;
				if (cyc_done) e_double++;
				cyc_done = 1'b1;
			end else if (ev_short !== 1'b0) e_short++;
			if (pause && !pz_prev) begin
				if (seen0) n_pause2++; else n_pause1++;
			end
			pz_prev = pause;
			// the counts after this edge
			if (pclk1) begin
				e0n = 0;
				n_e0++;
				seen0 = 1'b0;
				if (load) begin
					cyc_id++;
					cyc_done = 1'b0;
				end else n_held_cyc++;
				seen_l2[len2 & 31]++;
			end else if (e0n < 7) e0n++;
			if (pclk0) begin
				seen0 = 1'b1;
				seen_l1[len1 & 31]++;
			end
			if (commit) cn = 0;
			else if (cn < 3) cn++;
			// the busy: up at a random write commit (a CALLFN or a service), down only on
			// rel_ok (MUT: anywhere). At a read commit it would make the next held repeat's
			// pclk0 the first of the stall, shown by top.sv's rule whatever the release.
			if (!bb) begin
				if (commit && !rw && rnd(1000) < 300) begin
					bb <= 1'b1;
					bb_left = 1 + int'(rnd(6));
					n_bb++;
				end
			end else begin
				if (pclk1 && bb_left != 0) bb_left--;
				if (bb_left == 0 && (MUT ? (rnd(3) == 0) : (rel_ok && rnd(2) == 0))) begin
					bb <= 1'b0;
					n_bb_fall++;
				end
			end
		end
	end

	function automatic longint errors();
		return e_k + e_c + e_ph2 + e_rel + e_open + e_commit + e_short + e_pwr + (MUT ? 0 : e_double);
	endfunction
endmodule

module tb_fe_seq;
	logic clk = 1'b0;
	always #5 clk = ~clk;
	logic run = 1'b0;
	int   seed = 1;
	longint nclk = 3000000;

	tb_fe_seq_unit #(.SEED_OFS(11), .MODE("mix"))     u_mix  (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(23), .MODE("all"))     u_all  (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(37), .MODE("short"))   u_sh   (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(41), .MODE("stretch")) u_str  (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(53), .MODE("pause"))   u_pz   (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(67), .MODE("held"))    u_held (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(71), .MODE("nominal")) u_nom  (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(79), .MODE("all"), .PH1_4(0)) u_leg (.clk, .run, .seed);
	tb_fe_seq_unit #(.SEED_OFS(97), .MODE("held"), .MUT(1'b1)) u_mut (.clk, .run, .seed);

	task automatic report(input string name, input longint cl, ne0, nco, nsh, nhc, nhcm, nbb, nbbf,
	                      ek, ec, eph2, erel, eopen, ecom, esh, edbl, epwr, np1, np2);
		$display("tb_fe_seq %-8s %0d clocks, %0d cycles, %0d commits (%0d short), %0d held cycles (%0d commits in them), busy %0d/%0d; pauses %0d/%0d; errors k %0d c %0d ph2 %0d rel_ok %0d ph1_open %0d commit %0d ev_short %0d double %0d power-up %0d",
			name, cl, ne0, nco, nsh, nhc, nhcm, nbb, nbbf, np1, np2, ek, ec, eph2, erel, eopen, ecom, esh, edbl, epwr);
	endtask

	`define SEQ_REPORT(u, n) report(n, u.clocks, u.n_e0, u.n_commit, u.n_short, u.n_held_cyc, u.n_held_commit, \
		u.n_bb, u.n_bb_fall, u.e_k, u.e_c, u.e_ph2, u.e_rel, u.e_open, u.e_commit, u.e_short, u.e_double, \
		u.e_pwr, u.n_pause1, u.n_pause2)

	initial begin
		longint bad, feat;
		void'($value$plusargs("seq_clocks=%d", nclk));
		void'($value$plusargs("seq_seed=%d", seed));
		#20 run = 1'b1;
		repeat (nclk) @(posedge clk);
		run = 1'b0;
		@(posedge clk);
		`SEQ_REPORT(u_mix, "mix");
		`SEQ_REPORT(u_all, "all");
		`SEQ_REPORT(u_sh, "short");
		`SEQ_REPORT(u_str, "stretch");
		`SEQ_REPORT(u_pz, "pause");
		`SEQ_REPORT(u_held, "held");
		`SEQ_REPORT(u_nom, "nominal");
		`SEQ_REPORT(u_leg, "legal");
		`SEQ_REPORT(u_mut, "MUTANT");
		// phase-length coverage over the streams (L1 2, 4, 6, stretched; L2 6, 10, stretched)
		begin
			longint l1 [0:31], l2 [0:31];
			for (int i = 0; i < 32; i++) begin
				l1[i] = u_mix.seen_l1[i] + u_all.seen_l1[i] + u_sh.seen_l1[i] + u_str.seen_l1[i] + u_pz.seen_l1[i] + u_held.seen_l1[i];
				l2[i] = u_mix.seen_l2[i] + u_all.seen_l2[i] + u_sh.seen_l2[i] + u_str.seen_l2[i] + u_pz.seen_l2[i] + u_held.seen_l2[i];
			end
			$display("tb_fe_seq phase 1 lengths: 2:%0d 4:%0d 6:%0d 7-12:%0d; phase 2 lengths: 6:%0d 10:%0d 7-12:%0d",
				l1[2], l1[4], l1[6], l1[7] + l1[8] + l1[9] + l1[10] + l1[11] + l1[12],
				l2[6], l2[10], l2[7] + l2[8] + l2[9] + l2[11] + l2[12]);
			feat = (l1[2] > 100 && l1[4] > 100 && l1[6] > 100 && l1[7] + l1[12] > 50 && l2[10] > 100 && l2[12] > 20) ? 1 : 0;
			if (u_leg.seen_l1[4] != 0) begin $display("tb_fe_seq: the legal stream made a phase 1 of 4"); feat = 0; end
		end
		bad = u_mix.errors() + u_all.errors() + u_sh.errors() + u_str.errors() + u_pz.errors() + u_held.errors()
		    + u_nom.errors() + u_leg.errors() + u_mut.errors();
		if (u_held.n_held_cyc < 1000 || u_mut.n_held_commit == 0 || u_sh.n_short < 1000 || u_pz.n_pause1 < 100 || u_pz.n_pause2 < 100) feat = 0;
		if (u_mut.e_double == 0) begin
			$display("tb_fe_seq: the mutant (busy falling anywhere) made no double commit: the release check is blind");
			bad++;
		end
		if (bad != 0 || feat == 0) $fatal(1, "tb_fe_seq: FAIL (%0d errors, features %0d)", bad, feat);
		$display("tb_fe_seq: PASS");
		$finish;
	end
endmodule

`default_nettype wire
