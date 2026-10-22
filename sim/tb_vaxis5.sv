// Equivalence bench for virtual_axis5.sv (the five virtual axes as one
// time-shared engine) against five virtual_axis.sv instances whose ticks are
// the same tick delayed 0, 1, 2, 3 and 4 clocks: the one difference
// virtual_axis5.sv states. position (5 axes) and phase (axes 0-1) are
// compared on every clock.
//
// Stimulus (own xorshift generator, so a seed gives the same run anywhere):
//   - ticks 5-64 clocks apart (a quarter of them exactly 5);
//   - per axis, D-pad states (none, left, right, both) and slow / fast held
//     for 1-3,000 ticks, changing 0-7 clocks after a tick, so changes land
//     in and around the five update slots;
//   - analog random walks at three rates, with jumps; one axis
//     (seed mod 5) has a constant analog value (a controller without a
//     stick);
//   - resets of 1-20 clocks at random times, and on a tick or 1-5 clocks
//     after one.
//
//   +seed=N +cycles=N   (defaults 1 and 10^7)
// Prints "VAXIS5 seed ... mismatches N", the first 10 mismatches and, per
// axis, coverage counted on the reference's registers. It ends with $finish
// whatever the result: sim/run_vaxis5.sh reads the line, runs the seeds and
// the planted fault, and gives the verdict.
//
// SPDX-License-Identifier: MIT

`default_nettype none

module tb_vaxis5;
	logic clk = 1'b0;
	always #5 clk = ~clk;

	longint unsigned rs = 64'h9E37_79B9_7F4A_7C15;
	function automatic int unsigned rnd();
		rs ^= rs << 13;
		rs ^= rs >> 7;
		rs ^= rs << 17;
		return rs[47:16];
	endfunction
	function automatic int unsigned urange(int unsigned lo, int unsigned hi);
		return lo + rnd() % (hi - lo + 1);
	endfunction

	int unsigned seed = 1;
	longint      cycles = 64'd10_000_000;
	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("cycles=%d", cycles));
		rs = 64'h9E37_79B9_7F4A_7C15 ^ (64'(seed) * 64'h0000_0100_0000_01B3);
		repeat (20) void'(rnd());
	end

	// ---- stimulus registers (driven on the rising edge, as flops) ----
	logic       reset = 1'b0, tick = 1'b0;
	logic [4:0] neg = 5'd0, pos = 5'd0, slow = 5'd0, fast = 5'd0;
	logic [7:0] an [5] = '{8'd128, 8'd128, 8'd128, 8'd128, 8'd128};

	// The reference's ticks: the tick delayed k clocks.
	logic [4:1] tdl = 4'd0;
	always @(posedge clk) tdl <= {tdl[3:1], tick};
	wire  [4:0] tk = {tdl, tick};

	// ---- the reference: five virtual_axis.sv ----
	wire [7:0]  rpos [5];
	wire [15:0] rph  [5];
	genvar g;
	for (g = 0; g < 5; g++) begin : r
		virtual_axis u (
			.clk(clk), .reset(reset), .tick(tk[g]),
			.neg(neg[g]), .pos(pos[g]), .slow(slow[g]), .fast(fast[g]),
			.analog(an[g]), .position(rpos[g]), .phase(rph[g])
		);
	end

	// ---- the design: virtual_axis5.sv ----
	wire [39:0] dpos;
	wire [31:0] dph;
	virtual_axis5 dut (
		.clk(clk), .reset(reset), .tick(tick),
		.neg(neg), .pos(pos), .slow(slow), .fast(fast),
		.analog({an[4], an[3], an[2], an[1], an[0]}),
		.position(dpos), .phase(dph)
	);

	// ---- stimulus ----
	int        tick_wait = 10;
	int        dp_left [5], sp_left [5];      // ticks left in the D-pad / speed hold
	int        dp_chg [5], sp_chg [5];        // clocks to a pending change (-1: none)
	int        an_rate [5], an_rate_left [5]; // walk rate: 1 every 2^n clocks
	int        const_axis;
	int        rst_left = 0, rst_after_tick = -1, rst_len = 0;
	longint    cyc = 0;

	function automatic int hold_len();
		int unsigned c = rnd() % 10;
		return (c < 5) ? int'(urange(1, 30)) : (c < 8) ? int'(urange(31, 300)) : int'(urange(301, 3000));
	endfunction

	initial begin
		#1;
		const_axis = seed % 5;
		for (int k = 0; k < 5; k++) begin
			dp_left[k] = hold_len(); sp_left[k] = hold_len();
			dp_chg[k] = -1; sp_chg[k] = -1;
			an_rate[k] = 0; an_rate_left[k] = 1000;
			an[k] = (k == const_axis) ? 8'(rnd()) : 8'd128;
		end
	end

	always @(posedge clk) begin
		cyc <= cyc + 1;
		// Ticks.
		if (tick_wait <= 1) begin
			tick <= 1'b1;
			tick_wait = (rnd() % 4 == 0) ? 5 : int'(urange(5, 64));
		end else begin
			tick <= 1'b0;
			tick_wait--;
		end
		// Holds count down on the tick; a change then comes 0-7 clocks later.
		for (int k = 0; k < 5; k++) begin
			if (tick) begin
				dp_left[k]--;
				sp_left[k]--;
				if (dp_left[k] <= 0 && dp_chg[k] < 0) dp_chg[k] = int'(rnd() % 8);
				if (sp_left[k] <= 0 && sp_chg[k] < 0) sp_chg[k] = int'(rnd() % 8);
			end
			if (dp_chg[k] == 0) begin
				automatic int unsigned m = rnd() % 8;   // none 3/8, left 2/8, right 2/8, both 1/8
				neg[k] <= (m == 3 || m == 4 || m == 7);
				pos[k] <= (m == 5 || m == 6 || m == 7);
				dp_left[k] = hold_len();
			end
			if (dp_chg[k] >= 0) dp_chg[k]--;
			if (sp_chg[k] == 0) begin
				automatic int unsigned m = rnd() % 6;   // none 1/2, slow 1/6, fast 1/6, both 1/6
				slow[k] <= (m == 3 || m == 5);
				fast[k] <= (m == 4 || m == 5);
				sp_left[k] = hold_len();
			end
			if (sp_chg[k] >= 0) sp_chg[k]--;
			// Analog: a walk at 1 step per clock, per 16 or per 1024 clocks
			// (rate redrawn now and then), with jumps.
			if (k != const_axis) begin
				an_rate_left[k]--;
				if (an_rate_left[k] <= 0) begin
					an_rate[k] = (rnd() % 3 == 0) ? 0 : (rnd() % 2 == 0) ? 4 : 10;
					an_rate_left[k] = int'(urange(1000, 200000));
				end
				if (rnd() % 60000 == 0)
					an[k] <= 8'(rnd());
				else if ((rnd() & ((1 << an_rate[k]) - 1)) == 0) begin
					automatic int v = int'(an[k]) + int'(rnd() % 9) - 4;
					an[k] <= (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : 8'(v);
				end
			end
		end
		// Resets: at random times, or on a tick / 1-5 clocks after one.
		if (rst_left > 0) begin
			reset <= 1'b1;
			rst_left--;
		end else begin
			reset <= 1'b0;
			if (rst_after_tick >= 0) begin
				// armed: count from the tick
				if (rst_after_tick == 0) begin
					rst_left = rst_len - 1;
					reset <= 1'b1;
					rst_after_tick = -1;
				end else if (rst_after_tick < 99) rst_after_tick--;
			end else if (rnd() % 100000 == 0) begin
				rst_len = (rnd() % 2) ? 1 : int'(urange(1, 20));
				if (rnd() % 2) begin
					rst_left = rst_len - 1;
					reset <= 1'b1;
				end else
					rst_after_tick = 99;   // wait for the next tick
			end
		end
		// Arming: the clock before a tick rises, place the reset at offset
		// 0-5 from it (0: the reset and the tick on the same clock).
		if (rst_after_tick == 99 && tick_wait == 1) rst_after_tick = int'(rnd() % 6);
		if (cyc + 1 >= cycles) finish_run();
	end

	// ---- compare on every clock (between edges) ----
	longint mism = 0;
	longint mism_pos [5], mism_ph [2];
	initial for (int k = 0; k < 5; k++) begin mism_pos[k] = 0; if (k < 2) mism_ph[k] = 0; end
	always @(negedge clk) begin
		for (int k = 0; k < 5; k++) begin
			if (dpos[8*k +: 8] !== rpos[k]) begin
				mism++; mism_pos[k]++;
				if (mism <= 10) $display("MISMATCH cycle %0d axis %0d position %0d, reference %0d", cyc, k, dpos[8*k +: 8], rpos[k]);
			end
			if (k < 2 && dph[16*k +: 16] !== rph[k]) begin
				mism++; mism_ph[k]++;
				if (mism <= 10) $display("MISMATCH cycle %0d axis %0d phase %04x, reference %04x", cyc, k, dph[16*k +: 16], rph[k]);
			end
		end
	end

	// ---- coverage, from the reference's own registers ----
	longint n_tick = 0, n_reset = 0, n_rst_tick = 0, n_rst_slot = 0;
	longint c_held [5], c_follow [5], c_turn [5], c_aon_rise [5], c_top [5], c_bot [5], c_rst_upd [5], c_chg_slot [5];
	initial for (int k = 0; k < 5; k++) begin
		c_held[k] = 0; c_follow[k] = 0; c_turn[k] = 0; c_aon_rise[k] = 0;
		c_top[k] = 0; c_bot[k] = 0; c_rst_upd[k] = 0; c_chg_slot[k] = 0;
	end
	logic [4:0] neg_d = 0, pos_d = 0;
	logic       reset_d = 0;
	for (g = 0; g < 5; g++) begin : cov
		logic aon_d = 1'b0;
		always @(posedge clk) begin
			aon_d <= r[g].u.analog_on;
			if (r[g].u.analog_on && !aon_d) c_aon_rise[g]++;
			if (tk[g] && reset) c_rst_upd[g]++;
			if (tk[g] && !reset) begin
				if (neg[g] ^ pos[g]) c_held[g]++;
				else if (r[g].u.analog_on) begin
					c_follow[g]++;
					if (an[g] > 8'd152 || an[g] < 8'd104) c_turn[g]++;
				end
				// a D-pad change on the clock before this axis's slot, inside
				// the five-clock window after the tick
				if (g > 0 && (neg[g] != neg_d[g] || pos[g] != pos_d[g])) c_chg_slot[g]++;
			end
			if (r[g].u.pos16 == 16'hFFFF) c_top[g]++;
			if (r[g].u.pos16 == 16'h0000) c_bot[g]++;
		end
	end
	always @(posedge clk) begin
		neg_d <= neg; pos_d <= pos; reset_d <= reset;
		if (tick) n_tick++;
		if (reset && !reset_d) begin
			n_reset++;
			if (tick) n_rst_tick++;
			else if (tdl != 4'd0) n_rst_slot++;
		end
	end

	task automatic finish_run();
		$display("VAXIS5 seed %0d cycles %0d ticks %0d resets %0d (on a tick %0d, 1-4 clocks after one %0d) mismatches %0d",
			seed, cycles, n_tick, n_reset, n_rst_tick, n_rst_slot, mism);
		for (int k = 0; k < 5; k++) begin
			automatic string tag = (k == const_axis) ? " (constant analog)" : "";
			$display("VAXIS5 axis %0d%s: held updates %0d, stick-follow updates %0d (turning %0d), analog_on rises %0d, clocks at 255 %0d / at 0 %0d, updates under reset %0d, D-pad changes into the slot %0d, mismatches position %0d phase %0d",
				k, tag, c_held[k], c_follow[k], c_turn[k], c_aon_rise[k],
				c_top[k], c_bot[k], c_rst_upd[k], c_chg_slot[k], mism_pos[k], (k < 2) ? mism_ph[k] : 0);
		end
		$finish;
	endtask
endmodule
