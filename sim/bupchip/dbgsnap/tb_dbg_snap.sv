//------------------------------------------------------------------------------
// bup_dbg_snap.sv (src/fpga/core/bupchip/): a clk_arm word on clk_sys through
// a snapshot (open item 11; docs/daria_step7/plan.md P15, 3.5 gate 3).
//
// Clocks, one VCO of 1,455 ps (687.27 MHz; clk_sdram's half period is 6 of
// them): clk_sys = VCO/48 (69,840 ps); clk_arm = VCO/18 (26,190 ps, half
// period 13,095 ps), or with +div=19 VCO/19 (27,645 ps: high 13,823, low
// 13,822). clk_arm's first rising edge is +phase ps after clk_sys's:
//   +phase=0, 8730, 17460   the ÷18 lattice's three phases: rising edges
//                           shared every 3 clk_sys, on each of the three
//                           clk_sys edges of that frame in turn
//   +phase=-1 (default)     a random phase in [0, one clk_arm)
//
// d_arm is a clk_arm counter's word: at clk_arm edge k it starts to change
// to value(k), a mix of k whose bits each flip with probability 1/2. The
// change reaches each bit at its own time in the clock (one of 16 slots from
// 1 ps after the edge to about 300 ps before the next, drawn again for every
// bit and edge), as a clk_arm register's outputs reach a far flop through
// different routes. A clk_arm flop always takes a whole word; a clk_sys flop
// that samples d_arm raw takes a mix of two words whenever its edge falls
// inside the change.
//
// Checked, for every word q_sys takes (q_sys changes, and dut.take is high,
// on the same clk_sys edges; each must imply the other):
//   - the word is one value(k) of the last few thousand (else "torn");
//   - k is not older than the last word's (else "order");
//   - value(k) was on d_arm at most 6 clk_sys before the edge (else
//     "stale");
//   - dut.hold has not changed for at least one clk_sys before the edge
//     that takes it (the SDC bounds the bus at 20 ns; this is one
//     destination clock, as the other DARIA benches check);
//   - the take comes at the third clk_sys edge after dut.ack changed or
//     later, and dut.ack changes at the third clk_arm edge after dut.req or
//     later: two synchroniser flops each way;
//   - the rate (once past power-up, from the second request on): dut.req
//     flips exactly every PERIOD clk_sys edges, each take comes 3 to 6
//     clk_sys edges after the flip it answers (the round trip), and so
//     consecutive takes are PERIOD +- 3 clk_sys edges apart (else "rate").
// The run must reach +snaps words, one every PERIOD clk_sys.
//
// +rand_init: at time 1 ps every DUT register gets a random value (Power-Up
// Don't Care, or a lost initializer). Words taken in the first 8 clk_sys
// edges are counted as powerup_loads and not checked; every later one is.
// Built with --x-initial unique and run with +verilator+rand+reset+2, the
// bench's own registers start random too.
//
//   +div=18|19  +phase=PS  +seed=S  +snaps=K (300)  +rand_init
// The last line, "result: ...", is for run_dbgsnap.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
`default_nettype none

module tb_dbg_snap;
	parameter int N = 79;
	parameter int PERIOD = 1024;

	localparam longint VCO = 1455;
	localparam longint T_SYS = 48 * VCO;               // 69,840 ps
	localparam longint T0 = 50_000;                    // clk_sys's first rising edge
	localparam int W = (PERIOD + 16) * 3 + 64;         // words kept for the lookup
	localparam int SLOTS = 16;

	int     div = 18;
	longint phase = -1;
	int     seed = 1;
	int     snaps = 300;
	bit     rand_init = 1'b0;
	longint t_arm = 18 * VCO, h_arm = 9 * VCO, l_arm = 9 * VCO, a0 = T0;

	logic         clk_sys = 1'b0, clk_arm = 1'b0;
	logic [N-1:0] d_arm;
	wire  [N-1:0] q_sys;

	bup_dbg_snap #(.N(N), .PERIOD(PERIOD)) dut (.clk_sys, .clk_arm, .d_arm, .q_sys);

	// ---- errors -------------------------------------------------------------------------
	longint errors = 0, n_torn = 0, n_order = 0, n_stale = 0, n_gap = 0, n_lat = 0, n_pair = 0, n_rate = 0;
	task automatic fail(input string s);
		errors++;
		if (errors <= 20) $display("ERROR %0t ps: %s", $time, s);
	endtask

	// ---- the counter's words --------------------------------------------------------------------
	function automatic logic [63:0] mix64(input logic [63:0] x);
		logic [63:0] z;
		z = x + 64'h9E37_79B9_7F4A_7C15;
		z = (z ^ (z >> 30)) * 64'hBF58_476D_1CE4_E5B9;
		z = (z ^ (z >> 27)) * 64'h94D0_49BB_1331_11EB;
		return z ^ (z >> 31);
	endfunction
	function automatic logic [N-1:0] value(input longint k);
		logic [191:0] v;
		v = {mix64(64'(k) ^ 64'hA5A5_5A5A_0F0F_F0F0), mix64(64'(k) ^ 64'h1234_5678_9ABC_DEF0), mix64(64'(k))};
		return v[N-1:0];
	endfunction

	logic [N-1:0] words [W];
	longint       t_word [W];                          // when word k started to change in
	longint       k_now = 0;                           // the newest word
	initial begin
		d_arm = value(0);
		words[0] = value(0);
		t_word[0] = 0;
	end

	function automatic int urand(input int lo, input int hi);
		return lo + int'($urandom_range(32'(hi - lo)));
	endfunction

	// Each clk_arm edge starts the next word; every bit lands in its own slot.
	always @(posedge clk_arm) begin : drive
		logic [N-1:0] nv;
		logic [N-1:0] m [SLOTS];
		longint dt;
		k_now = k_now + 1;
		nv = value(k_now);
		words[int'(k_now % W)] = nv;
		t_word[int'(k_now % W)] = $time;
		for (int s = 0; s < SLOTS; s++) m[s] = '0;
		for (int i = 0; i < N; i++) m[urand(0, SLOTS - 1)][i] = 1'b1;
		dt = (t_arm - 300) / (SLOTS - 1);              // the last slot lands about 300 ps before the next edge
		for (int s = 0; s < SLOTS; s++) begin
			#(s == 0 ? 1 : dt);
			d_arm = (d_arm & ~m[s]) | (nv & m[s]);
		end
	end

	// ---- clocks ------------------------------------------------------------------------------
	initial begin
		void'($value$plusargs("div=%d", div));
		void'($value$plusargs("phase=%d", phase));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("snaps=%d", snaps));
		rand_init = $test$plusargs("rand_init");
		void'($urandom(seed));
		if (div == 19) begin
			t_arm = 19 * VCO;
			h_arm = 13823;
			l_arm = 13822;
		end else if (div != 18) begin
			$display("ERROR: +div must be 18 or 19");
			$finish;
		end
		if (phase < 0) phase = longint'($urandom_range(32'(t_arm - 1)));
		a0 = T0 + phase;
		$display("tb_dbg_snap: N=%0d PERIOD=%0d div=%0d phase=%0d ps seed=%0d snaps=%0d rand_init=%0d",
			N, PERIOD, div, phase, seed, snaps, rand_init);
	end
	initial begin
		#(T0);
		forever begin
			clk_sys = 1'b1;
			#(T_SYS / 2);
			clk_sys = 1'b0;
			#(T_SYS / 2);
		end
	end
	initial begin
		#(T0);
		#(phase);
		forever begin
			clk_arm = 1'b1;
			#(h_arm);
			clk_arm = 1'b0;
			#(l_arm);
		end
	end

	// ---- power-up values -------------------------------------------------------------------------
	initial begin
		#1;
		if (rand_init) begin
			for (int i = 0; i < $bits(dut.cnt); i++) dut.cnt[i] = 1'($urandom);
			dut.req   = 1'($urandom);
			dut.seen  = 1'($urandom);
			dut.ak_s0 = 1'($urandom);
			dut.ak_s1 = 1'($urandom);
			dut.rq_s0 = 1'($urandom);
			dut.rq_s1 = 1'($urandom);
			dut.ack   = 1'($urandom);
			for (int i = 0; i < N; i++) begin
				dut.hold[i]  = 1'($urandom);
				dut.q_sys[i] = 1'($urandom);
			end
			$display("rand_init: cnt=%0d req=%0d seen=%0d ak=%0d%0d rq=%0d%0d ack=%0d",
				dut.cnt, dut.req, dut.seen, dut.ak_s1, dut.ak_s0, dut.rq_s1, dut.rq_s0, dut.ack);
		end
	end

	// ---- edge counts, for the synchroniser latencies ---------------------------------------------------
	function automatic longint sys_edges(input longint t);    // clk_sys rising edges at or before t
		return t < T0 ? 0 : (t - T0) / T_SYS + 1;
	endfunction
	function automatic longint arm_edges(input longint t);
		return t < a0 ? 0 : (t - a0) / t_arm + 1;
	endfunction

	// ---- taps: when hold, ack and req last changed ----------------------------------------------------
	logic [N-1:0] hold_q;
	logic         ack_q, req_q;
	longint       t_hold = 0, t_ack = -1, t_req = -1;
	initial begin
		#2;
		hold_q = dut.hold;
		ack_q = dut.ack;
		req_q = dut.req;
	end
	always @(posedge clk_arm) begin
		#2;
		if (dut.hold !== hold_q) begin
			hold_q = dut.hold;
			t_hold = $time - 2;
		end
		if (dut.ack !== ack_q) begin
			ack_q = dut.ack;
			if ($time > T0 + 8 * T_SYS && t_req >= 0) begin
				// the capture's edge is the third clk_arm edge after req changed, or later
				if (arm_edges($time - 2) - arm_edges(t_req) < 3) begin
					n_lat++;
					fail($sformatf("ack changed %0d clk_arm edges after req", arm_edges($time - 2) - arm_edges(t_req)));
				end
			end
			t_ack = $time - 2;
		end
	end
	// The rate: req's flips, PERIOD clk_sys edges apart once past power-up
	// (the first flip after it may come early, from a random cnt).
	longint n_flips = 0, flip_gap_min = 64'h7FFF_FFFF_FFFF_FFFF, flip_gap_max = 0;
	always @(posedge clk_sys) begin
		#2;
		if (dut.req !== req_q) begin
			req_q = dut.req;
			if ($time - 2 >= T0 + 8 * T_SYS) begin
				n_flips++;
				if (n_flips >= 2) begin
					longint g;
					g = sys_edges($time - 2) - sys_edges(t_req);
					if (g < flip_gap_min) flip_gap_min = g;
					if (g > flip_gap_max) flip_gap_max = g;
					if (g != PERIOD) begin
						n_rate++;
						fail($sformatf("req flipped %0d clk_sys edges after the last flip (PERIOD %0d)", g, PERIOD));
					end
				end
			end
			t_req = $time - 2;
		end
	end

	// ---- the words q_sys takes ---------------------------------------------------------------------------------
	logic [N-1:0] q_prev;
	longint       k_last = -1, n_snaps = 0, n_takes = 0, n_powerup = 0;
	longint       n_post = 0, te_prev = 0, rt_min = 1000, rt_max = 0, tg_min = 64'h7FFF_FFFF_FFFF_FFFF, tg_max = 0;
	longint       gap_min = 64'h7FFF_FFFF_FFFF_FFFF, age_max = 0, lat_sys_min = 1000;
	initial begin
		#2;
		q_prev = q_sys;
	end
	always @(posedge clk_sys) begin : watch
		logic   took, changed, found;
		longint te, k, age, n;
		te = $time;
		took = dut.take === 1'b1;
		#1;
		changed = q_sys !== q_prev;
		q_prev = q_sys;
		if (took) n_takes++;
		if (te < T0 + 8 * T_SYS) begin
			if (took || changed) n_powerup++;
		end else begin
			if (took != changed) begin
				n_pair++;
				if (changed) fail("q_sys changed while take was 0");
				else fail("q_sys did not change while take was 1");
			end
			if (changed) begin
				n_snaps++;
				// which word: the newest match in the window
				found = 1'b0;
				k = 0;
				for (longint j = k_now; j >= 0 && j > k_now - W; j--)
					if (words[int'(j % W)] === q_sys) begin
						found = 1'b1;
						k = j;
						break;
					end
				if (!found) begin
					n_torn++;
					fail($sformatf("torn word: q_sys=%h is none of the last %0d words", q_sys, W));
				end else begin
					if (k < k_last) begin
						n_order++;
						fail($sformatf("word %0d after word %0d", k, k_last));
					end
					k_last = k;
					// how long since the word stopped being current (0: it still is)
					age = k == k_now ? 0 : te - t_word[int'((k + 1) % W)];
					if (age > age_max) age_max = age;
					if (age > 6 * T_SYS) begin
						n_stale++;
						fail($sformatf("stale word %0d: replaced %0d ps before", k, age));
					end
				end
			end
			if (took) begin
				if (te - t_hold < gap_min) gap_min = te - t_hold;
				if (te - t_hold < T_SYS) begin
					n_gap++;
					fail($sformatf("hold changed %0d ps before clk_sys took it", te - t_hold));
				end
				if (t_ack >= 0) begin
					n = sys_edges(te) - sys_edges(t_ack);
					if (n < lat_sys_min) lat_sys_min = n;
					if (n < 3) begin
						n_lat++;
						fail($sformatf("take %0d clk_sys edges after ack changed", n));
					end
				end
				// the rate, from the second take past power-up on (the first
				// may answer a request left by the power-up state)
				n_post++;
				if (n_post >= 2) begin
					n = sys_edges(te) - sys_edges(t_req);      // the round trip of this take's request
					if (n < rt_min) rt_min = n;
					if (n > rt_max) rt_max = n;
					if (n < 3 || n > 6) begin
						n_rate++;
						fail($sformatf("take %0d clk_sys edges after its request (3 to 6)", n));
					end
				end
				if (n_post >= 3) begin
					n = sys_edges(te) - sys_edges(te_prev);
					if (n < tg_min) tg_min = n;
					if (n > tg_max) tg_max = n;
					if (n < PERIOD - 3 || n > PERIOD + 3) begin
						n_rate++;
						fail($sformatf("takes %0d clk_sys edges apart (PERIOD %0d)", n, PERIOD));
					end
				end
				te_prev = te;
			end
		end
		if (n_snaps >= snaps) finish_run();
	end

	task automatic finish_run();
		if (n_post < 4 || n_flips < 3) fail($sformatf("too few takes (%0d) or request flips (%0d) past power-up to check the rate", n_post, n_flips));
		$display("result: errors=%0d snaps=%0d takes=%0d torn=%0d order=%0d stale=%0d gap=%0d lat=%0d pair=%0d rate=%0d gap_min_ps=%0d age_max_ps=%0d lat_sys_min=%0d round_trip=%0d..%0d take_gap=%0d..%0d flip_gap=%0d..%0d powerup_loads=%0d words=%0d div=%0d phase=%0d seed=%0d period=%0d n=%0d",
			errors, n_snaps, n_takes, n_torn, n_order, n_stale, n_gap, n_lat, n_pair, n_rate, gap_min, age_max, lat_sys_min,
			rt_min, rt_max, tg_min, tg_max, flip_gap_min, flip_gap_max, n_powerup, k_now, div, phase, seed, PERIOD, N);
		$finish;
	endtask

	// A handshake that stops: the run ends at twice its expected length.
	initial begin
		#(T0 + 8 * T_SYS + 2 * longint'(snaps + 2) * PERIOD * T_SYS);
		fail($sformatf("only %0d words in %0d ps", n_snaps, $time));
		finish_run();
	end
endmodule

`default_nettype wire
