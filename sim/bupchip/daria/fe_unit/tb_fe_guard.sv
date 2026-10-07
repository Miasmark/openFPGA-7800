//------------------------------------------------------------------------------
// tb_fe_guard: daria_fe_guard's unit bench (docs/daria_fe/design.md 8,
// 12.3; lane D, docs/daria_fe/lanes/D_arb_guard.md).
//
// Every lane is one daria_fe_guard with its own clk_arm, all on one clk_sys.
// The clocks come from the Pocket's VCO lattice: one VCO step is 1455 ps
// (687.27 MHz), clk_sys = 48 steps (69,840 ps), DARIA's clk_arm = 18 steps
// (26,190 ps). The constrained pd_tog -> pd_rx path (8.2: [1, 6] ns) is
// modelled per launch: every rising clk_arm edge reaches the DUT's clk_arm
// pin d ps after its lattice time, d drawn for that edge in [1000, 6000]
// (each bound 10% of the time). Since clk_arm feeds only pd_tog, that is
// exactly a launch-to-capture delay of d on that toggle. No arrival ever
// coincides with a clk_sys edge (a 1 ps nudge), so the simulator has no
// race to resolve.
//
// Lanes (+edges clk_sys edges each, default 10^6):
//   d18_o0/6/12  /18 with clk_arm's lattice offset 0, 6, 12 VCO steps (0,
//                8730, 17460 ps: the shared edge on each of the three
//                clk_sys edges of the 144-step frame; BEN 6.3's d_ofs)
//   d18_mvA/B    /18 with phase moves (PLL relock): every 2,000-22,000
//                clocks clk_arm stops for 0-5 clk_sys periods (none in a
//                quarter of the moves) and resumes on a random one of the
//                three offsets (the same one in a third of them)
//   d18_stop     /18 with long stops: every 2,000-22,000 clocks clk_arm
//                stops for 20-400 clk_sys periods, then resumes on a random
//                offset (the unlock rule: nothing to lock on without clk_arm)
//   d19_*        /19 (the fallback, 19 steps = 27,645 ps) at five offsets
//   x5_*         clk_arm = 5 x clk_sys (mode A's upstream clk_arm), two offsets
//   x1           clk_arm = clk_sys (coincident)
//   d18_bad      negative control: /18 with d in [1, 10] ns (outside 8.2's
//                bound), where the lattice check must see errors
//   x5_amb/x1_amb  information only: 5x / 1x with a clk_arm edge 3 ns before
//                every clk_sys edge, so each edge's count is decided by that
//                launch's random delay (mode A has no such delays; reported)
//
// Checks, every clock of every lane:
//   ps    pd_same == the parity of the toggles that arrived between the last
//         two clk_sys edges (the receiver pair, independently of the lattice)
//   fly   ph, good and locked against an independent restatement of 8.1's
//         flywheel: ph = (clocks since the last mismatch) mod 3, good =
//         min(that - 1, 12), locked iff that >= 14 (13 matches); phb_next
//         == that locked & that ph == 0 (from the flywheel, not pd_same)
//   gd    guard_on == locked & (call_win | !cpu_ready) with random call_win
//         and cpu_ready; ev_unlock == locked now and not in the next clock
// and in the /18 lanes, in every settled clock (no move within reach of
// its toggles' window):
//   lat   pd_same == "the edge before this clock is shared" by the edge
//         arithmetic ((T - a0) % 26190 == 0; 8.4's det_bad)
//   phb   phb_next only in such a clock (the edge that ends it is phase B:
//         (T - a0) % 26190 == 17460, 17.46 ns after the last clk_arm edge),
//         and, once locked after the last move, in every such clock
//   lock  the first lock within 24 clocks of the run's start, and of every
//         resume after a move; no unlock in a settled regime once locked
//   dead  while clk_arm is stopped: unlocked from the fourth clock after its
//         last toggle's arrival until it resumes (8.3: unlock on the first
//         mismatch, and no lock without the toggle pattern)
// and in the /19, 5x and 1x lanes: never locked and guard_on never high
// (8.3, D4: unlocked, guard_on = 0; the longest run of consistent edges is
// reported).
//
// +seed=N (default 1), +edges=N (default 1000000), +verbose=1; +restate=0
// fails only on the physical checks (lat, phb, lock, never locked), counting
// the restatement checks (ps, fly, gd, evu) without failing on them (used by
// tb_fe_arb_mut.sh to show which mutants the acceptance checks alone catch).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ps/1ps
`default_nettype none

module tb_fe_guard_lane #(
	parameter string NAME  = "lane",
	parameter int    KIND  = 0,          // 0 /18 (lattice checked), 1 never locks, 2 negative control,
	                                     // 3 information only (locks counted, not failed)
	parameter int    PER   = 26190,      // clk_arm period, ps
	parameter int    OFS   = 0,          // clk_arm lattice offset from clk_sys's, ps
	parameter bit    MOVES = 1'b0,       // phase moves (PLL relock)
	parameter int    DMAX  = 6000,       // largest per-launch delay, ps
	parameter int    GMIN  = 0,          // a move's stop of clk_arm: GMIN .. GMAX clk_sys periods
	parameter int    GMAX  = 5,          //   (GMIN 0: none in a quarter of the moves)
	parameter int    IDX   = 0           // seed offset
) (
	input wire clk_sys
);
	localparam longint SYS0 = 2_000_000;     // clk_sys's first rising edge
	localparam longint TS   = 69840;         // clk_sys period
	localparam int     PB   = 17460;         // phase B: 12 VCO steps after a clk_arm edge

	logic clk_arm   = 1'b0;
	logic call_win  = 1'b0;
	logic cpu_ready = 1'b1;
	wire  locked, phb_next, guard_on;

	daria_fe_guard u_guard (
		.clk_sys   (clk_sys),
		.clk_arm   (clk_arm),
		.call_win  (call_win),
		.cpu_ready (cpu_ready),
		.locked    (locked),
		.phb_next  (phb_next),
		.guard_on  (guard_on)
	);

	// ---- random (xorshift32; one stream per lane) -------------------------------------
	int unsigned rs = 1;
	function automatic int unsigned rnd();
		rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
		return rs;
	endfunction

	// ---- clk_arm: lattice edges, each delayed by its own path delay -------------------
	longint arr     = 0;                     // rising clk_arm edges so far (= pd_tog toggles)
	longint a0_cur, a0_old;                  // lattice origin of the current / previous regime
	longint t_res   = 0,  t_stop  = -1;      // latest move: its first new / last old lattice edge
	longint t_res_p = 0,  t_stop_p = -1;     // the one before
	int     nmove   = 0;
	int     verbose = 0;
	int     restate = 1;                     // 0: the restatement checks (ps, fly, gd, evu) are counted, not failed
	int     dmin_seen = 1 << 30, dmax_seen = 0;

	initial begin : gen
		longint tn, tnext, next_move;
		int unsigned seed;
		int d, g;
		seed = 1;
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("verbose=%d", verbose));
		void'($value$plusargs("restate=%d", restate));
		rs = seed * 32'h9E37_79B9 + IDX * 32'h85EB_CA6B + 32'h1234_5677;
		if (rs == 0) rs = 1;
		repeat (8) void'(rnd());
		a0_cur = SYS0 + OFS;
		a0_old = a0_cur;
		tn     = a0_cur - 20 * longint'(PER);        // >= 0: SYS0 > 20 periods of the slowest clk_arm
		t_res  = tn;
		next_move = SYS0 + (100 + rnd() % 2000) * TS;
		forever begin
			// this edge's path delay
			case (rnd() % 10)
				0:       d = 1000;
				1:       d = DMAX;
				default: d = 1000 + int'(rnd() % (DMAX - 1000 + 1));
			endcase
			if (((tn + d - SYS0) % TS) == 0) d = (d < DMAX) ? d + 1 : d - 1;   // never on an edge
			if (d < dmin_seen) dmin_seen = d;
			if (d > dmax_seen) dmax_seen = d;
			if (tn + d <= $time) $fatal(1, "%s: clk_arm edge in the past", NAME);
			#(tn + d - $time);
			clk_arm = 1'b1;
			arr     = arr + 1;
			#(PER / 2 - 2500);
			clk_arm = 1'b0;
			tnext = tn + PER;
			if (MOVES && tnext >= next_move) begin
				// clk_arm stops for g ps and resumes on one of the three /18 offsets
				g = (rnd() % 4 == 0 && GMIN == 0) ? 0 :                   // 0: a pure phase jump (or none)
				    GMIN * int'(TS) + int'(rnd() % ((GMAX - GMIN) * TS + 1));
				t_stop_p = t_stop;  t_res_p = t_res;  a0_old = a0_cur;
				t_stop   = tn;
				a0_cur   = SYS0 + (rnd() % 3) * 8730 + (rnd() % 4) * longint'(PER);
				tnext    = tn + PER / 2 + 7000 + g;          // no earlier than this (no overlapping pulses)
				tnext    = a0_cur + ((tnext - a0_cur + PER - 1) / PER) * PER;
				t_res    = tnext;
				nmove++;
				next_move = tnext + (2000 + rnd() % 20000) * TS;
				if (verbose) $display("%s: move %0d at %0t: stop %0d, resume %0d (gap %0d ps), offset %0d", NAME,
					nmove, $time, t_stop, t_res, g, (a0_cur - SYS0) % PER);
			end
			tn = tnext;
		end
	end

	// ---- random guard requests (registered: change only at clk_sys edges) -----------
	always @(posedge clk_sys) begin
		if (rnd() % 16 == 0) call_win  <= !call_win;
		if (rnd() % 64 == 0) cpu_ready <= !cpu_ready;
	end

	// ---- the checker -------------------------------------------------------------------
	longint n  = 0;                           // index of this edge (E_n at SYS0 + n*TS)
	longint c1 = 0, c2 = 0;                   // arrivals before E_{n-1}, before E_{n-2}
	longint lm = -1;                          // reference: the last mismatching clock
	bit     lk_p = 1'b0, evu_p = 1'b0;        // the previous clock's locked, ev_unlock
	// counts
	longint e_ps = 0, e_fly = 0, e_gd = 0, e_evu = 0;     // every lane
	longint e_lat = 0, e_phb = 0, e_lock = 0, e_unl = 0;  // /18 lanes, settled clocks
	longint n_settled = 0, n_phb = 0, n_shared = 0, n_lockedcl = 0, n_unlock = 0;
	longint n_locked_never = 0;               // never-lock lanes: clocks with locked
	longint e_gnever = 0;                     // never-lock lanes: clocks with guard_on
	longint n_dead = 0, e_dead = 0;           // clocks checked while clk_arm is stopped; locked there
	int     maxrun = 0;                       // longest run of consistent clocks
	int     first_lock = -1;                  // clocks from E_0 to the first locked clock
	int     relock_max = 0, relock_n = 0;     // clocks from a resume to a correct lock
	int     stale_max = 0;                    // locked clocks inside a move's transient
	bit     want_lock = 1'b1;                 // waiting for a (re)lock
	longint lock_from = 0;                    // the clock index the wait started at
	int     stale_cur = 0;
	longint seen_move = 0;
	longint g_ev = 0;                         // guard_on clocks (coverage)
	longint e_first = -1;                     // first error clock

	// A move's transient is [last old lattice edge, resume + 6 clocks]: a clock
	// is settled iff the launches that decide its pd_same, with the lattice
	// edge before them, lie outside every transient.
	function automatic bit hits(longint lo, longint hi, longint xs, longint xr);
		if (xs < 0) return 1'b0;
		return (lo <= xr + 6 * TS) && (hi >= xs);
	endfunction
	function automatic longint pmod(longint x, longint m);
		return ((x % m) + m) % m;
	endfunction

	task automatic err(input string what, input longint i);
		if (e_first < 0) e_first = i;
		if (verbose || (e_ps + e_fly + e_gd + e_evu + e_lat + e_phb + e_lock + e_unl) < 10)
			$display("%s: ERROR %s in clock %0d (t %0t): pd_same %0d ph %0d good %0d locked %0d phb_next %0d",
				NAME, what, i, $time, u_guard.pd_same, u_guard.ph, u_guard.good, locked, phb_next);
	endtask

	always @(posedge clk_sys) begin : chk
		longint T, Ti, i, a0;
		bit ps_ref, ps, sh, settled, mism, lk;
		int run, ph_r, good_r;
		T = $time;
		if (n >= 1) begin
			i  = n - 1;                       // the clock (E_{n-1}, E_n), whose values are visible here
			Ti = T - TS;                      // E_{n-1}
			ps = u_guard.pd_same;
			lk = locked;
			// ps: the receiver pair against the arrivals
			ps_ref = ((c1 - c2) % 2) == 0;
			if (ps != ps_ref) begin e_ps++; if (restate) err("pd_same vs arrivals", i); end
			// fly: the flywheel against its restatement
			run    = int'(i - lm);
			ph_r   = run % 3;
			good_r = (run - 1 > 12) ? 12 : run - 1;
			if (u_guard.ph != 2'(ph_r) || u_guard.good != 4'(good_r) || lk != (run >= 14)) begin
				e_fly++; if (restate) err($sformatf("flywheel (ref ph %0d good %0d locked %0d)", ph_r, good_r, run >= 14), i);
			end
			// phb_next comes from the flywheel register (8.1), never from the receiver
			if (phb_next != ((run >= 14) && ph_r == 0)) begin e_fly++; if (restate) err("phb_next != locked & ph == 0", i); end
			mism = ps != (ph_r == 0);
			if (lm >= 0 && run > maxrun) maxrun = run;   // after the first mismatch (power-up's anchor is arbitrary)
			if (mism) lm = i;
			// gd: guard_on and ev_unlock
			if (guard_on != (lk & (call_win | !cpu_ready))) begin e_gd++; if (restate) err("guard_on", i); end
			if (guard_on) g_ev++;
			if (i >= 1 && evu_p != (lk_p & !lk)) begin e_evu++; if (restate) err("ev_unlock", i); end
			if (lk_p & !lk) n_unlock++;
			if (lk) n_lockedcl++;
			// the /18 lattice
			if (KIND == 0 || KIND == 2) begin
				a0 = (Ti >= t_res) ? a0_cur : a0_old;
				settled = (i >= 1) && !hits(Ti - TS - PER - 11000, Ti, t_stop, t_res) &&
				          !hits(Ti - TS - PER - 11000, Ti, t_stop_p, t_res_p);
				sh = pmod(Ti - a0, PER) == 0;
				// dead: clk_arm stopped since t_stop (its last arrival <= t_stop + DMAX); from the
				// fourth clock on pd_same is 1 in every clock, so the flywheel must have unlocked
				if (MOVES && t_stop >= 0 && Ti > t_stop + DMAX + 4 * TS && Ti < t_res) begin
					n_dead++;
					if (lk) begin e_dead++; if (KIND == 0) err("locked while clk_arm is stopped", i); end
				end
				if (nmove != seen_move) begin             // a move: wait for the relock
					seen_move = nmove;  want_lock = 1'b1;  lock_from = -1;  stale_cur = 0;
				end
				if (want_lock && lock_from < 0 && Ti >= t_res) lock_from = i;
				if (!settled) begin
					// a stale lock: locked on the new lattice with phb_next at the wrong edge
					if (lk && Ti >= t_res && phb_next != sh) begin
						stale_cur++; if (stale_cur > stale_max) stale_max = stale_cur;
					end
				end else begin
					n_settled++;
					if (sh) n_shared++;
					if (ps != sh) begin e_lat++; if (KIND == 0) err("pd_same vs edge arithmetic", i); end
					if (phb_next) begin
						n_phb++;
						if (!sh || pmod(T - a0, PER) != PB) begin
							e_phb++; if (KIND == 0) err("phb_next not before phase B", i);
						end
					end
				end
				if (want_lock && lock_from >= 0) begin
					// edges from the start (clock 0) or from the resume to a correct lock
					if (settled && lk && phb_next == sh) begin
						want_lock = 1'b0;
						if (nmove == 0) first_lock = int'(i - lock_from + 1);
						else begin
							relock_n++;
							if (int'(i - lock_from + 1) > relock_max) relock_max = int'(i - lock_from + 1);
						end
						if (i - lock_from + 1 > 24) begin e_lock++; if (KIND == 0) err("lock later than 24 clocks", i); end
					end else if (i - lock_from + 1 > 24) begin
						e_lock++; if (KIND == 0) err("no lock within 24 clocks", i);
						want_lock = 1'b0;
					end
				end else if (!want_lock && settled) begin
					if (!lk) begin e_unl++; if (KIND == 0) err("unlock in a settled regime", i); end
					else if (phb_next != sh) begin e_phb++; if (KIND == 0) err("phb_next missing at phase B", i); end
				end
			end else begin
				if (lk) begin n_locked_never++; if (KIND == 1) err("locked", i); end
				if (guard_on) begin e_gnever++; if (KIND == 1) err("guard_on while never locked", i); end
			end
			lk_p  = lk;
			evu_p = u_guard.ev_unlock;
		end
		c2 = c1;
		c1 = arr;
		n  = n + 1;
	end

	// errors that fail the run (the negative control is judged by the top)
	function automatic longint errors();
		longint e;
		e = restate ? e_ps + e_fly + e_gd + e_evu : 0;
		// clk_arm ran at its rate: about TS / PER toggles per clk_sys edge
		if (arr * PER < (n - 1) * TS - 40 * longint'(PER) * TS) begin
			$display("%s: clk_arm too slow (%0d toggles in %0d clocks)", NAME, arr, n - 1); e++;
		end
		if (KIND >= 2) return e;
		return e + e_lat + e_phb + e_lock + e_unl + e_dead + n_locked_never + e_gnever;
	endfunction

	task automatic report();
		$display("%-8s clocks %0d  toggles %0d  delay %0d..%0d ps  ps %0d fly %0d gd %0d evu %0d | settled %0d shared %0d phb %0d lat %0d phbE %0d | lock@%0d moves %0d relocks %0d max %0d stale %0d unlockE %0d lockE %0d dead %0d deadE %0d | unlocks %0d locked %0d guard_on %0d longest %0d%s",
			NAME, n - 1, arr, dmin_seen, dmax_seen, e_ps, e_fly, e_gd, e_evu, n_settled, n_shared, n_phb, e_lat, e_phb,
			first_lock, nmove, relock_n, relock_max, stale_max, e_unl, e_lock, n_dead, e_dead, n_unlock, n_lockedcl, g_ev, maxrun,
			(KIND == 1) ? $sformatf("  NEVER-LOCK violations %0d (guard_on %0d)", n_locked_never, e_gnever) :
			(KIND == 3) ? $sformatf("  (information: locked clocks %0d)", n_locked_never) : "");
	endtask
endmodule

module tb_fe_guard;
	localparam longint SYS0 = 2_000_000;
	localparam longint TS   = 69840;
	logic   clk_sys = 1'b0;
	longint edges   = 1_000_000;
	longint nedge   = 0;

	initial begin
		#(SYS0);
		forever begin clk_sys = 1'b1; #(TS / 2); clk_sys = 1'b0; #(TS / 2); end
	end

	//                    name       kind  period  offset  moves dmax   idx
	tb_fe_guard_lane #(.NAME("d18_o0"),  .KIND(0), .PER(26190), .OFS(0),     .MOVES(0), .DMAX(6000),  .IDX(0))  l0  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d18_o6"),  .KIND(0), .PER(26190), .OFS(8730),  .MOVES(0), .DMAX(6000),  .IDX(1))  l1  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d18_o12"), .KIND(0), .PER(26190), .OFS(17460), .MOVES(0), .DMAX(6000),  .IDX(2))  l2  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d18_mvA"), .KIND(0), .PER(26190), .OFS(0),     .MOVES(1), .DMAX(6000),  .IDX(3))  l3  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d18_mvB"), .KIND(0), .PER(26190), .OFS(8730),  .MOVES(1), .DMAX(6000),  .IDX(4))  l4  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d19_o0"),  .KIND(1), .PER(27645), .OFS(0),     .MOVES(0), .DMAX(6000),  .IDX(5))  l5  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d19_o4"),  .KIND(1), .PER(27645), .OFS(5820),  .MOVES(0), .DMAX(6000),  .IDX(6))  l6  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d19_o8"),  .KIND(1), .PER(27645), .OFS(11640), .MOVES(0), .DMAX(6000),  .IDX(7))  l7  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d19_o12"), .KIND(1), .PER(27645), .OFS(17460), .MOVES(0), .DMAX(6000),  .IDX(8))  l8  (.clk_sys);
	tb_fe_guard_lane #(.NAME("d19_o16"), .KIND(1), .PER(27645), .OFS(23280), .MOVES(0), .DMAX(6000),  .IDX(9))  l9  (.clk_sys);
	tb_fe_guard_lane #(.NAME("x5_o0"),   .KIND(1), .PER(13968), .OFS(0),     .MOVES(0), .DMAX(6000),  .IDX(10)) l10 (.clk_sys);
	tb_fe_guard_lane #(.NAME("x5_o3"),   .KIND(1), .PER(13968), .OFS(3000),  .MOVES(0), .DMAX(6000),  .IDX(11)) l11 (.clk_sys);
	tb_fe_guard_lane #(.NAME("x1"),      .KIND(1), .PER(69840), .OFS(0),     .MOVES(0), .DMAX(6000),  .IDX(12)) l12 (.clk_sys);
	tb_fe_guard_lane #(.NAME("d18_bad"), .KIND(2), .PER(26190), .OFS(0),     .MOVES(0), .DMAX(10000), .IDX(13)) l13 (.clk_sys);
	// information: 5x and 1x with a toggle 3 ns before every clk_sys edge, inside the
	// [1, 6] ns window, so the per-launch delay decides each edge's count (see the report)
	tb_fe_guard_lane #(.NAME("x5_amb"),  .KIND(3), .PER(13968), .OFS(10968), .MOVES(0), .DMAX(6000),  .IDX(14)) l14 (.clk_sys);
	tb_fe_guard_lane #(.NAME("x1_amb"),  .KIND(3), .PER(69840), .OFS(66840), .MOVES(0), .DMAX(6000),  .IDX(15)) l15 (.clk_sys);
	// /18 with long stops of clk_arm (20-400 clk_sys) between the moves: the unlock rule
	tb_fe_guard_lane #(.NAME("d18_stop"), .KIND(0), .PER(26190), .OFS(0),    .MOVES(1), .DMAX(6000),  .IDX(16),
	                   .GMIN(20), .GMAX(400)) l16 (.clk_sys);

	always @(posedge clk_sys) nedge <= nedge + 1;

	initial begin
		longint e;
		void'($value$plusargs("edges=%d", edges));
		wait (nedge == edges + 1);
		#1;
		l0.report();  l1.report();  l2.report();  l3.report();  l4.report();
		l5.report();  l6.report();  l7.report();  l8.report();  l9.report();
		l10.report(); l11.report(); l12.report(); l13.report(); l14.report(); l15.report();
		l16.report();
		e = l0.errors() + l1.errors() + l2.errors() + l3.errors() + l4.errors() + l5.errors() + l6.errors()
		  + l7.errors() + l8.errors() + l9.errors() + l10.errors() + l11.errors() + l12.errors() + l13.errors()
		  + l14.errors() + l15.errors() + l16.errors();
		// coverage: the /18 lanes locked, phase B seen, moves and relocks happened, the guard was on
		if (l0.first_lock < 0 || l1.first_lock < 0 || l2.first_lock < 0) begin
			$display("tb_fe_guard: a /18 lane never locked"); e++;
		end
		if (l3.relock_n < 10 || l4.relock_n < 10 || l16.relock_n < 10) begin
			$display("tb_fe_guard: too few relocks (%0d, %0d, %0d)", l3.relock_n, l4.relock_n, l16.relock_n); e++;
		end
		if (edges >= 1_000_000 && l16.n_dead < 1000) begin
			$display("tb_fe_guard: too few clocks with clk_arm stopped (%0d)", l16.n_dead); e++;
		end
		if (l0.g_ev == 0 || l0.n_phb == 0) begin $display("tb_fe_guard: no guard_on / phb_next seen"); e++; end
		// the negative control must see lattice errors (the check is not blind)
		if (l13.e_lat == 0) begin $display("tb_fe_guard: negative control d18_bad saw no lattice error"); e++; end
		if (e != 0) $fatal(1, "tb_fe_guard: FAIL (%0d errors)", e);
		$display("tb_fe_guard: PASS (%0d clk_sys edges per lane, 17 lanes)", edges);
		$finish;
	end
endmodule

`default_nettype wire
