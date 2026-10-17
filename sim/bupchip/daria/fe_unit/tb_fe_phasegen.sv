//------------------------------------------------------------------------------
// tb_fe_phasegen: the self-test of phase_gen.svh (docs/daria_fe/design.md
// 12.1, 12.3). Four generators run side by side for +clocks (default
// 400,000) clk_sys, each watched by pg_check, which states every property
// independently of the generator's code:
//   g0  mode all, internal busy, driver_run 1
//   g1  g0's twin (same seed and knobs): every output equal on every clock
//   g2  EXT_BUS from a counter, the bench's own stall (falling only on
//       rel_ok), driver_run 0 (so phase 2 of 4 occurs, and access never)
//   g3  g0's knobs with another seed: the streams must differ
// pg_check: pclk1/pclk0 alternate, one clock each, never during a pause;
// phase lengths (pause excluded) in the legal sets and equal to len1/len2;
// the bus changes only at E0; the held rule (RDY low in p0 and a read
// before: same address, rw 1; never after a write); the hidden-phase rule
// (in one stall the first pclk0 is shown, every later one hidden);
// access only with driver_run; ibusy rises only at a write commit and falls
// only on rel_ok. At the end every feature must have been seen.
// Plusargs: +clocks=N, +pg_seed=N (and the other +pg_* knobs).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module pg_check #(
	parameter string NAME        = "g",
	parameter int    MAX_STR     = 6,
	parameter bit    ALLOW_PH2_4 = 1'b0
) (
	input wire        clk_sys,
	input wire        driver_run,
	input wire        pclk1,
	input wire        pclk0,
	input wire        mapper_phi2,
	input wire        access,
	input wire [12:0] a_in,
	input wire        rw,
	input wire  [7:0] d_in,
	input wire        pause,
	input wire        stall_eff,
	input wire        ibusy,
	input wire        held,
	input wire  [5:0] len1,
	input wire  [5:0] len2
);
	int errors = 0;
	// coverage
	int n_cyc = 0, n_l1_2 = 0, n_l1_4 = 0, n_l1_6 = 0, n_l1_str = 0;
	int n_l2_6 = 0, n_l2_10 = 0, n_l2_str = 0, n_l2_4 = 0;
	int n_pause1 = 0, n_pause2 = 0, n_held = 0, n_hidden = 0, n_shown_stall = 0;
	int n_busy = 0, n_access = 0, n_write_commit = 0;

	task automatic bad(input string what);
		errors++;
		if (errors <= 10) $display("%s: FAIL at %0t: %s", NAME, $time, what);
	endtask

	logic        started = 1'b0, last_was1 = 1'b0;
	int          run_len = 0;           // clocks not paused since the last pulse
	int          paused = 0;            // paused clocks since the last pulse
	logic [12:0] pa;
	logic        prw, ppclk1, pstall, pheld_rule;
	logic  [7:0] pd;
	logic        seen = 1'b0;           // a pclk0 was shown in this stall
	logic        ph2m = 1'b0;
	logic        pibusy = 1'b0, pacc_wr = 1'b0, prel = 1'b0;
	logic  [5:0] l1q = '0;

	always @(posedge clk_sys) begin
		// ---- pulses: one clock, alternating, never in a pause -------------------
		if (pclk1 && pclk0) bad("pclk1 and pclk0 together");
		if (pause && (pclk1 || pclk0)) bad("a pulse during a pause");
		if (pclk1 || pclk0) begin
			if (started) begin
				if (pclk1 && last_was1) bad("two pclk1 without a pclk0");
				if (pclk0 && !last_was1) bad("two pclk0 without a pclk1");
				if (pclk0) begin                   // the end of phase 1
					if (run_len != l1q) bad($sformatf("phase 1 %0d clocks, len1 %0d", run_len, l1q));
					if (!(run_len == 2 || run_len == 4 || (run_len >= 6 && run_len <= 6 + MAX_STR)))
						bad($sformatf("phase 1 of %0d", run_len));
					if (run_len == 2) n_l1_2++; else if (run_len == 4) n_l1_4++;
					else if (run_len == 6) n_l1_6++; else n_l1_str++;
					if (paused != 0) n_pause1++;
				end else begin                     // the end of phase 2
					if (run_len != len2) bad($sformatf("phase 2 %0d clocks, len2 %0d", run_len, len2));
					if (!(run_len == 6 || run_len == 10 || (run_len >= 7 && run_len <= 6 + MAX_STR)
							|| (ALLOW_PH2_4 && run_len == 4)))
						bad($sformatf("phase 2 of %0d", run_len));
					if (run_len == 4 && driver_run) bad("phase 2 of 4 with driver_run");
					if (run_len == 6) n_l2_6++; else if (run_len == 10) n_l2_10++;
					else if (run_len == 4) n_l2_4++; else n_l2_str++;
					if (paused != 0) n_pause2++;
				end
			end else if (pclk0) bad("the first pulse is pclk0");
			started   <= 1'b1;
			last_was1 <= pclk1;
			run_len   <= 1;
			paused    <= 0;
			if (pclk1) begin l1q <= len1; n_cyc++; end
		end else if (pause) paused <= paused + 1;
		else run_len <= run_len + 1;

		// ---- the bus changes only at E0; the held rule --------------------------
		if (ppclk1) begin
			if (pheld_rule) begin
				if (!held) bad("RDY low after a read, the cycle is not held");
				if (a_in != pa || !rw) bad("a held cycle does not re-present the address with rw 1");
				n_held++;
			end else if (held) bad("held without RDY low after a read");
		end else if (started && (a_in != pa || rw != prw || d_in != pd)) bad("the bus changed outside E0");
		pa <= a_in; prw <= rw; pd <= d_in; ppclk1 <= pclk1;
		pheld_rule <= pclk1 && stall_eff && rw;

		// ---- the hidden-phase rule (top.sv:316-327) -----------------------------
		if (pclk0) begin
			if (!stall_eff) begin
				if (!mapper_phi2) bad("pclk0 hidden without a stall");
			end else if (!seen) begin
				if (!mapper_phi2) bad("the first pclk0 of a stall hidden");
				n_shown_stall++;
			end else begin
				if (mapper_phi2) bad("a later pclk0 of a stall shown");
				n_hidden++;
			end
		end else if (mapper_phi2) bad("mapper_phi2 without pclk0");
		if (!stall_eff) seen <= 1'b0;
		else if (pclk0) seen <= 1'b1;
		if (access != (mapper_phi2 && driver_run)) bad("access != mapper_phi2 && driver_run");
		if (access) n_access++;
		if (access && a_in[12] && !rw) n_write_commit++;

		// ---- ibusy: rises at a write commit, falls on rel_ok --------------------
		if (ibusy && !pibusy) begin
			if (!pacc_wr) bad("ibusy rose without a write commit");
			n_busy++;
		end
		if (!ibusy && pibusy && !prel) bad("ibusy fell outside rel_ok");
		pibusy  <= ibusy;
		pacc_wr <= access && a_in[12] && !rw;
		prel    <= (ph2m | pclk0) & !pclk1;
		ph2m    <= pclk1 ? 1'b0 : (pclk0 ? 1'b1 : ph2m);
	end
endmodule

module tb_fe_phasegen;
	logic clk_sys = 1'b0;
	always #34.92 clk_sys = ~clk_sys;          // 14.318 MHz
	int clocks = 400_000;
	int seed = 1;

	// ---- g0, g1 (twin), g3 (another seed): internal busy, driver_run 1 ------------
	wire        p1_0, p0_0, m2_0, ac_0, rw_0, pz_0, ld_0, se_0, ib_0, hd_0;
	wire [12:0] a_0;
	wire  [7:0] d_0;
	wire  [5:0] l1_0, l2_0;
	fe_phase_gen #(.SEED(1), .MODE("all")) g0 (
		.clk_sys(clk_sys), .run(1'b1), .stall(1'b0), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(p1_0), .pclk0(p0_0), .mapper_phi2(m2_0), .access(ac_0), .a_in(a_0), .rw(rw_0),
		.d_in(d_0), .pause(pz_0), .load(ld_0), .stall_eff(se_0), .ibusy(ib_0), .held(hd_0),
		.len1(l1_0), .len2(l2_0));
	pg_check #(.NAME("g0")) c0 (
		.clk_sys(clk_sys), .driver_run(1'b1), .pclk1(p1_0), .pclk0(p0_0), .mapper_phi2(m2_0),
		.access(ac_0), .a_in(a_0), .rw(rw_0), .d_in(d_0), .pause(pz_0), .stall_eff(se_0),
		.ibusy(ib_0), .held(hd_0), .len1(l1_0), .len2(l2_0));

	wire        p1_1, p0_1, m2_1, ac_1, rw_1, pz_1, ld_1, se_1, ib_1, hd_1;
	wire [12:0] a_1;
	wire  [7:0] d_1;
	wire  [5:0] l1_1, l2_1;
	fe_phase_gen #(.SEED(1), .MODE("all")) g1 (
		.clk_sys(clk_sys), .run(1'b1), .stall(1'b0), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(p1_1), .pclk0(p0_1), .mapper_phi2(m2_1), .access(ac_1), .a_in(a_1), .rw(rw_1),
		.d_in(d_1), .pause(pz_1), .load(ld_1), .stall_eff(se_1), .ibusy(ib_1), .held(hd_1),
		.len1(l1_1), .len2(l2_1));

	wire        p1_3, p0_3, m2_3, ac_3, rw_3, pz_3, ld_3, se_3, ib_3, hd_3;
	wire [12:0] a_3;
	wire  [7:0] d_3;
	wire  [5:0] l1_3, l2_3;
	fe_phase_gen #(.SEED(1), .SEED_OFS(77), .MODE("all")) g3 (
		.clk_sys(clk_sys), .run(1'b1), .stall(1'b0), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(p1_3), .pclk0(p0_3), .mapper_phi2(m2_3), .access(ac_3), .a_in(a_3), .rw(rw_3),
		.d_in(d_3), .pause(pz_3), .load(ld_3), .stall_eff(se_3), .ibusy(ib_3), .held(hd_3),
		.len1(l1_3), .len2(l2_3));
	pg_check #(.NAME("g3")) c3 (
		.clk_sys(clk_sys), .driver_run(1'b1), .pclk1(p1_3), .pclk0(p0_3), .mapper_phi2(m2_3),
		.access(ac_3), .a_in(a_3), .rw(rw_3), .d_in(d_3), .pause(pz_3), .stall_eff(se_3),
		.ibusy(ib_3), .held(hd_3), .len1(l1_3), .len2(l2_3));

	// ---- g2: EXT_BUS from a counter, the bench's stall, driver_run 0 --------------
	wire        p1_2, p0_2, m2_2, ac_2, rw_2, pz_2, ld_2, se_2, ib_2, hd_2;
	wire [12:0] a_2;
	wire  [7:0] d_2;
	wire  [5:0] l1_2, l2_2;
	logic [20:0] nx = 21'd0;                  // the bench's bus stream: {a, rw, d} = the count
	logic        stall2 = 1'b0;
	logic        ph2b = 1'b0;
	logic [31:0] brs = 32'h1234_5678;
	fe_phase_gen #(.SEED(5), .MODE("all"), .EXT_BUS(1'b1)) g2 (
		.clk_sys(clk_sys), .run(1'b1), .stall(stall2), .driver_run(1'b0),
		.ext_a(nx[20:8]), .ext_rw(nx[0]), .ext_d(nx[7:0]),
		.pclk1(p1_2), .pclk0(p0_2), .mapper_phi2(m2_2), .access(ac_2), .a_in(a_2), .rw(rw_2),
		.d_in(d_2), .pause(pz_2), .load(ld_2), .stall_eff(se_2), .ibusy(ib_2), .held(hd_2),
		.len1(l1_2), .len2(l2_2));
	pg_check #(.NAME("g2"), .ALLOW_PH2_4(1'b1)) c2 (
		.clk_sys(clk_sys), .driver_run(1'b0), .pclk1(p1_2), .pclk0(p0_2), .mapper_phi2(m2_2),
		.access(ac_2), .a_in(a_2), .rw(rw_2), .d_in(d_2), .pause(pz_2), .stall_eff(se_2),
		.ibusy(ib_2), .held(hd_2), .len1(l1_2), .len2(l2_2));

	int ext_bad = 0, ext_loads = 0;
	logic [20:0] want = 21'd0;                // the value the next new cycle must carry
	logic        pl2 = 1'b0;
	always @(posedge clk_sys) begin
		// the bench's stall: rises anywhere, falls only on rel_ok
		brs = brs ^ (brs << 13); brs = brs ^ (brs >> 17); brs = brs ^ (brs << 5);
		if (!stall2) begin
			if (brs[9:0] < 10'd3) stall2 <= 1'b1;
		end else if (((ph2b | p0_2) & !p1_2) && brs[15:10] < 6'd4) stall2 <= 1'b0;
		ph2b <= p1_2 ? 1'b0 : (p0_2 ? 1'b1 : ph2b);
		// EXT_BUS: each new cycle carries the next count, in order, once
		if (ld_2) nx <= nx + 21'd1;
		pl2 <= ld_2;
		if (pl2) begin
			if ({a_2, d_2} != want || rw_2 != want[0]) begin
				ext_bad++;
				if (ext_bad <= 5) $display("g2: FAIL at %0t: ext bus %h/%b, want %h", $time, {a_2, d_2}, rw_2, want);
			end
			want <= want + 21'd1;
			ext_loads++;
		end
	end

	// ---- twins and seeds ----------------------------------------------------------
	int twin_bad = 0, seed_diff = 0;
	always @(posedge clk_sys) begin
		if ({p1_0, p0_0, m2_0, ac_0, a_0, rw_0, d_0, pz_0, ld_0, se_0, ib_0, hd_0, l1_0, l2_0} !=
		    {p1_1, p0_1, m2_1, ac_1, a_1, rw_1, d_1, pz_1, ld_1, se_1, ib_1, hd_1, l1_1, l2_1}) twin_bad++;
		if ({p1_0, p0_0, a_0, d_0, pz_0} != {p1_3, p0_3, a_3, d_3, pz_3}) seed_diff++;
	end

	task automatic need(input string what, input int n, input int min, inout int fails);
		$display("  %-28s %0d", what, n);
		if (n < min) begin
			$display("  FAIL: %s seen %0d times, want >= %0d", what, n, min);
			fails++;
		end
	endtask

	initial begin
		int fails;
		void'($value$plusargs("clocks=%d", clocks));
		repeat (clocks) @(posedge clk_sys);
		#1;
		fails = c0.errors + c2.errors + c3.errors + ext_bad;
		$display("tb_fe_phasegen: %0d clocks; errors g0 %0d, g2 %0d, g3 %0d, ext %0d; twin differs %0d clocks; g3 differs from g0 in %0d",
			clocks, c0.errors, c2.errors, c3.errors, ext_bad, twin_bad, seed_diff);
		if (twin_bad != 0) begin $display("  FAIL: g1 is not g0's twin"); fails++; end
		if (seed_diff == 0) begin $display("  FAIL: another seed gives the same stream"); fails++; end
		$display("g0 coverage (%0d cycles):", c0.n_cyc);
		need("phase 1 of 2", c0.n_l1_2, 50, fails);
		need("phase 1 of 4", c0.n_l1_4, 50, fails);
		need("phase 1 of 6", c0.n_l1_6, 50, fails);
		need("phase 1 stretched", c0.n_l1_str, 50, fails);
		need("phase 2 of 6", c0.n_l2_6, 50, fails);
		need("phase 2 of 10", c0.n_l2_10, 50, fails);
		need("phase 2 stretched", c0.n_l2_str, 50, fails);
		need("pause in phase 1", c0.n_pause1, 20, fails);
		need("pause in phase 2", c0.n_pause2, 20, fails);
		need("internal busy", c0.n_busy, 20, fails);
		need("held cycles", c0.n_held, 50, fails);
		need("first pclk0 of a stall", c0.n_shown_stall, 20, fails);
		need("hidden pclk0", c0.n_hidden, 50, fails);
		need("write commits", c0.n_write_commit, 50, fails);
		$display("g2 coverage (%0d cycles, ext bus):", c2.n_cyc);
		need("phase 2 of 4 (driver_run 0)", c2.n_l2_4, 50, fails);
		need("held cycles (bench stall)", c2.n_held, 50, fails);
		need("hidden pclk0 (bench stall)", c2.n_hidden, 50, fails);
		need("ext loads", ext_loads, 1000, fails);
		if (c2.n_access != 0) begin $display("  FAIL: access with driver_run 0"); fails++; end
		if (fails != 0) $fatal(1, "tb_fe_phasegen: FAIL (%0d)", fails);
		$display("tb_fe_phasegen: PASS");
		$finish;
	end
endmodule

`default_nettype wire
