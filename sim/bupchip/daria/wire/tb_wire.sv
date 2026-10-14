//------------------------------------------------------------------------------
// tb_wire: tb_load with checks of the DARIA wiring in the whole core
// (docs/daria_step7/plan.md 3.3 items 4 and 5, 7.2 row I1, 7.3): the real
// loader, atari7800_pocket.sv with top.sv's and cart2600.sv's hooks, the
// BupChip and the PSRAM model, on the clk_arm lattice of tb_load (F5).
// run_wire.sh builds it, runs the scenarios and judges them (wire_check.py).
//
// It prints, in both builds (with and without POCKET_DARIA):
//   WIRE release N at clk_sys T (MS ms)   each release of the console reset
//                     (atari7800_pocket.sv's reset register; T counts clk_sys
//                     edges from time 0, the edge that first sees it low), so
//                     that the two builds' release edges can be compared (P6)
// and in the DARIA build:
//   WIRE f6 start / end    each F6 of daria_fe (u_copy.f6_q), with what
//                     started it: the capture's cartridge window closing (and
//                     how many clk_sys after its fall: 1 when cart_win reaches
//                     daria_fe unchanged), or a reset rise; at its end a hash
//                     of the cart RAM it wrote (and of state RAM words $00-$1F,
//                     which it clears), and whether it equals the first F6's
//   WIRE pll_busy ...      the synchronised pll_busy (pll_busy_s[1]) rising and
//                     falling (+retune), in both builds
//   WIRE reset_in ...      the bench's reset_in rising (+resetat, +wire_resetat)
//   WIRE pll_region ...    with +wire_pll: each retune of the region switch
//                     in the loop (below) and its end
//   WIRE is_pal ...        with +wire_pll: the core's is_pal_o changing (the
//                     first 40)
//   WIRE summary k=v ...   at the end: the counts below
// Summary keys (both builds), with +wire_pll:
//   retunes, b2b            retunes of the region switch, and those that
//                           started at most 4 clk_74a after the last one ended
//   pal_chg, is_pal         is_pal_o changes (clk_sys samples) and its value
//                           at the end
// Summary keys (DARIA build):
//   f6, f6_win, f6_rst      F6 runs, started by the window or by a reset rise
//   f6_win_dt               the last window-started F6's delay from cart_win's
//                           fall (clk_sys; -1 when none)
//   f6_rst_low              clk_sys with F6 running and the console reset low
//                           (the 6507 released before F6 ends)
//   f6_busy                 clk_sys with F6 running and pll_busy_s[1] high
//   f6_noib                 clk_sys with F6 running and init_busy low
//   f6_live                 clk_sys with daria_fe's a_f6_live (F6 outside
//                           rst_quiet; must be 0)
//   f6_ram_diff             F6 ends whose cart RAM or state RAM hash differs
//                           from the first F6's
//   wr_crb, wr_stb          daria_fe's cart RAM and state RAM writes that
//                           reach the RAMs (bupchip's port B write enables,
//                           after atari7800_pocket.sv's daria_we_ok)
//   wr_busy                 of those, while pll_busy_s[1] is high (P20; the
//                           first 40 also as WIRE write lines)
//   wr_stop                 clk_run edges (+retune, +wire_retune: the PLL's
//                           outputs stopping or restarting) with either RAM's
//                           port B write enable high
//   wr_drop                 daria_fe's write enables that did not reach the
//                           RAMs (daria_we_ok low: a service running on into
//                           a retune); the first 40 as WIRE drop lines
//   wr_after_load2          RAM writes after a +image2 load started
//   hold_rise               rises of daria_hold (init_busy for an ARM scheme)
//   prof_clk                clk_sys with daria_profile high (the BupChip in
//                           its 2600 profile; P5: 0 for an A78)
//   calls, calls_arm        call_tog flips at daria_fe's output and at the
//                           BupChip's input
//   rets, rets_fe           ret_tog flips at the BupChip's output and at
//                           daria_fe's input
//   ret_max_us              the longest call, from call_tog's flip to
//                           ret_tog's (us)
//   open_old                calls still open at the end that were posted more
//                           than 2 ms before it
//   abandoned, orphans      open calls dropped when daria_fe's cart_reset rose
//                           (a console reset, the end of a retune), and
//                           returns with no open call
//   smp_req, smp_ack        sample requests and answers (toggle flips)
//   halts, unlocks, locked  the BupChip CPU's halts, the guard's unlocks
//                           (P22's dbg_unlock) and dbg_locked at the end
//   psram_viol, psram_cs    the PSRAM model's violations, psram's CLOCK_SPEED
//   misses                  the asset cache's demand fills (st_miss)
//   rt_rst_low              clk_sys from pll_busy_s[1]'s rise to the end of
//                           the first F6 after it (or to pll_busy_s[1]'s fall
//                           for a non-ARM image) with the console reset low
//   rt_f6, rt_f6_early      F6 runs starting after pll_busy_s[1] rose, and
//                           those that started before it fell
//   rs_f6, rs_f6_rst_low    F6 runs after a +resetat reset_in rise, and clk_sys
//                           from that rise to the first such F6's end with the
//                           console reset low
//   calls_rs, calls_rt      calls posted after that reset_in rise, and after
//                           pll_busy_s[1]'s last fall (-1: none happened)
//   marker, errors, marker_rs  RIOT $FF (finished test bodies of fe_dir's
//                           images) and $FE (failed self-checks) at the end,
//                           and $FF when reset_in rose
// +wire_pll closes the loop of the PAL/NTSC switch: core_top.v's pll_region
// (core/pll_region.v itself) takes the core's is_pal_o and a model of the
// Pocket's is_downloading, and its busy is the core's pll_busy; a model of
// the PLL and its reconfiguration controller stops and restarts the clocks
// ("the region switch in the loop", below). +wire_resetat=MS raises reset_in
// for +wire_reset_clk=N clk_sys (default 49, the menu's Reset: 255 clk_74a)
// MS ms after the first release; +wire_reset_on_pal=K raises it as the core's
// region changes (below).
// With +wire_pll, also (DARIA build):
//   f6_pend                 clk_sys with F6 running while pll_region is busy
//                           or could start a retune (the core's is_pal_o
//                           differs from the region the PLL is set to: it
//                           starts one as soon as its loading input is low);
//                           -1 without +wire_pll
//   rgn_bad                 clk_sys where daria_rgn (the region of the PLL's
//                           last completed retune, P20) or the timer's
//                           region input it drives (daria_mmio's pal, through
//                           bupchip's daria_pal port) differs from the region
//                           pll_region has set the PLL to, outside a retune
//                           (pll_region busy or pll_busy_s[1] high on this
//                           clock or the last) and the clock daria_rgn takes
//                           region_pll on; -1 without +wire_pll
// +wire_seq=MODE (with +wire_pll) models is_downloading across a whole load
// sequence, as core_top.v makes it, and runs one of the scripts of the D
// review's finding 3 (a retune that waits for a load sequence's end; below).
// With +wire_pcm=FILE it also writes every frame the BupChip's peripheral
// takes (a push to 0x18's FIFO, 0x10, in the Souper profile) as s16le
// stereo, and prints "WIRE song start N" at the first command it takes, for
// sim/bupchip/s1/pcm_check.py.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_wire;
	tb_load tb ();

	// clk_sys edges before this one, from time 0: every block reads the same
	// value at an edge
	longint t_sys = 0;
	always @(posedge tb.clk_sys) t_sys <= t_sys + 1;
	function automatic real ms();
		real r;
		r = $realtime;
		return r / 1.0e6;
	endfunction
	// the time in ns as a real (through a real variable, as tb_load's now_ns,
	// so that the picoseconds survive)
	function automatic real t_ns();
		real r;
		r = $realtime;
		return r;
	endfunction

	// ---- console reset releases (both builds) ---------------------------------------
	logic rst_d = 1'b1;
	int   rel_n = 0;
	// (from clk_sys 4: the reset register has no power-up value, so it reads
	// 0 for the first clock and 1 from the next, which is no release)
	always @(posedge tb.clk_sys) begin
		if (rst_d && !tb.dut.reset && t_sys >= 4) begin
			rel_n++;
			$display("WIRE release %0d at clk_sys %0d (%0.3f ms)", rel_n, t_sys, ms());
		end
		rst_d <= tb.dut.reset;
	end

	// ---- pll_busy (+retune) ------------------------------------------------------------
	logic busy_c = 1'b0;
	always @(posedge tb.clk_sys) begin
		if (!busy_c && tb.dut.pll_busy_s[1])
			$display("WIRE pll_busy rises at clk_sys %0d (%0.3f ms)", t_sys, ms());
		if (busy_c && !tb.dut.pll_busy_s[1])
			$display("WIRE pll_busy falls at clk_sys %0d (%0.3f ms)", t_sys, ms());
		busy_c <= tb.dut.pll_busy_s[1];
	end

	// ---- reset_in and +image2 ---------------------------------------------------------
	logic rin_d = 1'b1, dl_d = 1'b0;
	int   dl_n = 0;
	longint t_rin = -1, t_load2 = -1;
	always @(posedge tb.clk_sys) begin
		if (!rin_d && tb.reset_in) begin
			t_rin = t_sys;
			$display("WIRE reset_in rises at clk_sys %0d (%0.3f ms)", t_sys, ms());
		end
		rin_d <= tb.reset_in;
		if (!dl_d && tb.cart_download) begin
			dl_n++;
			if (dl_n == 2) t_load2 = t_sys;
		end
		dl_d <= tb.cart_download;
	end

	// ---- the PLL's outputs stopped and restarted ---------------------------------------
	// As tb_load's +retune: stopped between edges on their common lattice, for
	// US us rounded up to whole common periods, so each restarts on its
	// lattice; pll_locked low while they are stopped and for 1 us after.
	task automatic pll_stop_restart(input int us);
		longint lcm, now_ps, t_ps, w_ps;
		lcm = 69840;
`ifdef POCKET_DARIA
		lcm = tb.arm_div == 19 ? 1326960 : 209520;
`endif
		now_ps = longint'(t_ns() * 1000.0);
		t_ps = (now_ps / lcm + 1) * lcm + 1;
		while (t_ps % 8730 == 0
`ifdef POCKET_DARIA
			|| (t_ps - tb.arm_ofs) % (tb.arm_div == 19 ? 27645 : 13095) == 0
			|| (tb.arm_div == 19 && (t_ps - tb.arm_ofs) % 27645 == 13823)
`endif
			) t_ps++;
		w_ps = (longint'(us) * 1000000 + lcm - 1) / lcm * lcm;
		#((t_ps - now_ps) * 0.001);
		tb.clk_run = 1'b0;
		tb.pll_locked_tb = 1'b0;
		#(w_ps * 0.001);
		tb.clk_run = 1'b1;
		#1000.0;
		tb.pll_locked_tb = 1'b1;
	endtask

	// ---- +wire_pll: the region switch in the loop ----------------------------------------
	// pll_region (core_top.v's instance) on clk_74a. is_pal: the core's
	// is_pal_o (tb_load's region setting is Auto). loading: is_downloading,
	// which on the Pocket rises at a slot's requestwrite and falls at
	// allcomplete; core_top.v's cart_download follows it through four
	// clk_sys registers (dl_s, cart_download), so it falls 4 clk_sys (21
	// clk_74a) after is_downloading. Here it rises with any of the bench's
	// download flags, and for a cartridge (the last slot) it falls 2,058
	// clk_74a after the last bridge write, 21 before the bench drops
	// cart_download (2,079 after it). pll_locked: through three clk_74a
	// flops, as core_top.v's synch_3. The controller: waitrequest for 3
	// clk_74a after each write (sim/tb_pll_region.sv's model); the start
	// (register 2) stops the PLL's outputs for +wire_pll_us=N us (default
	// 20), and waitrequest stays high until it locks again.
	bit   pll_on = 1'b0;
	int   pll_us = 20;
	initial begin
		pll_on = $test$plusargs("wire_pll");
		void'($value$plusargs("wire_pll_us=%d", pll_us));
	end
	logic [2:0] pr_lk_s = 3'b111;
	logic pr_waitreq = 1'b0;
	wire  pr_busy, pr_cfg_write;
	wire  [5:0] pr_cfg_addr;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [31:0] pr_cfg_data;
	/* verilator lint_on UNUSEDSIGNAL */
	logic dl_cart = 1'b0, dl_cd_d = 1'b0, dl_wr = 1'b0;
	int   dl_n74 = 0;
	bit   seq_ld = 1'b0;      // +wire_seq: is_downloading across a load sequence (below)
	wire  pr_loading = seq_ld | dl_cart | tb.bios_download | tb.hscfw_download | tb.arfw_download | tb.bupfw_download;
	always @(posedge tb.clk_74a) begin
		pr_lk_s <= {pr_lk_s[1:0], tb.pll_locked_tb};
		if (tb.cart_download && !dl_cd_d) begin
			dl_cart <= 1'b1; dl_wr <= 1'b0; dl_n74 <= 0;
		end else begin
			if (tb.bridge_wr) begin dl_n74 <= 0; dl_wr <= 1'b1; end
			else dl_n74 <= dl_n74 + 1;
			if (!tb.cart_download || (dl_wr && dl_n74 >= 2057)) dl_cart <= 1'b0;
		end
		dl_cd_d <= tb.cart_download;
	end
	pll_region u_pr (
		.clk (tb.clk_74a), .is_pal (tb.is_pal), .loading (pr_loading), .pll_locked (pr_lk_s[2]),
		.busy (pr_busy), .cfg_waitrequest (pr_waitreq), .cfg_write (pr_cfg_write),
		.cfg_address (pr_cfg_addr), .cfg_writedata (pr_cfg_data));
	int   pr_hold = 0;
	bit   pr_relock = 1'b0;
	event pr_go;
	int   retunes = 0, b2b = 0, pal_chg = 0;
	int   pr_low74 = 1000;
	logic pr_busy_d = 1'b0, pal_d = 1'b0;
	always @(posedge tb.clk_74a) if (pll_on) begin
		if (pr_hold > 0) begin
			pr_hold--;
			if (pr_hold == 0 && !pr_relock) pr_waitreq <= 1'b0;
		end
		if (pr_cfg_write) begin
			pr_waitreq <= 1'b1;
			pr_hold = 3;
			if (pr_cfg_addr == 6'd2) begin
				pr_relock = 1'b1;
				-> pr_go;
			end
		end
		if (pr_busy && !pr_busy_d) begin
			retunes++;
			if (pr_low74 <= 4) b2b++;
			$display("WIRE pll_region retune %0d to %0s at clk_sys %0d (%0.6f ms), %0d clk_74a after the last ended",
				retunes, u_pr.target ? "PAL" : "NTSC", t_sys, ms(), pr_low74);
		end
		if (!pr_busy && pr_busy_d)
			$display("WIRE pll_region done at clk_sys %0d (%0.6f ms): the PLL is %0s", t_sys, ms(), u_pr.pll_pal ? "PAL" : "NTSC");
		pr_low74 <= pr_busy ? 0 : (pr_low74 < 1000 ? pr_low74 + 1 : pr_low74);
		pr_busy_d <= pr_busy;
	end
	always @(pr_busy) if (pll_on) tb.pll_busy_tb = pr_busy;
	initial forever begin
		@(pr_go);
		pll_stop_restart(pll_us);
		pr_relock = 1'b0;
		pr_waitreq = 1'b0;
	end
	always @(posedge tb.clk_sys) if (pll_on) begin
		if (t_sys > 4 && tb.is_pal != pal_d) begin
			pal_chg++;
			if (pal_chg <= 40) $display("WIRE is_pal %0d at clk_sys %0d (%0.3f ms)", tb.is_pal, t_sys, ms());
		end
		pal_d <= tb.is_pal;
	end

	// ---- +wire_resetat: a console reset as short as the menu's ------------------------
	initial begin
		automatic int at = 0, n = 49;
		if ($value$plusargs("wire_resetat=%d", at)) begin
			void'($value$plusargs("wire_reset_clk=%d", n));
			wait (tb.reset_in == 1'b0);
			for (int i = 0; i < at; i++) repeat (14318) @(posedge tb.clk_sys);
			@(negedge tb.clk_sys);
			tb.reset_in = 1'b1;
			repeat (n) @(negedge tb.clk_sys);
			tb.reset_in = 1'b0;
			$display("WIRE reset_in held for %0d clk_sys, low again at %0.3f ms", n, ms());
		end
	end

`ifdef POCKET_DARIA
	`define W_FE tb.dut.u_fe
	`define W_CP tb.dut.u_fe.u_copy
	`define W_BC tb.dut.bupchip

	int  calls = 0, calls_arm = 0, rets = 0, rets_fe = 0, smp_req = 0, smp_ack = 0;

	// ---- F6 ------------------------------------------------------------------------------
	localparam logic [63:0] FNV_OFFSET = 64'hcbf29ce484222325;
	localparam logic [63:0] FNV_PRIME  = 64'h00000100000001b3;
	function automatic logic [63:0] fnv32(input logic [63:0] h, input logic [31:0] w);
		for (int i = 0; i < 4; i++) h = (h ^ {56'd0, w[i*8 +: 8]}) * FNV_PRIME;
		return h;
	endfunction
	function automatic logic [63:0] ram_hash(input bit r32);
		logic [63:0] h = FNV_OFFSET;
		for (int i = 0; i < (r32 ? 8192 : 2048); i++) h = fnv32(h, `W_BC.mem.cart_ram.mem_q[i]);
		for (int i = 0; i < 32; i++) h = fnv32(h, `W_BC.mem.state_ram.mem_q[i]);
		return h;
	endfunction

	logic   f6_d = 1'b0, cw_d = 1'b0, crst_d = 1'b0, busy_d = 1'b0;
	int     f6_n = 0, f6_win = 0, f6_rst = 0, f6_rst_low = 0, f6_busy = 0, f6_noib = 0, f6_live = 0, f6_ram_diff = 0;
	longint f6_win_dt = -1, t_cw_fall = -1, t_crst_rise = -1, t_busy_rise = -1, t_busy_fall = -1;
	logic [63:0] f6_h0 = '0;
	int     rt_f6 = 0, rt_f6_early = 0, rt_rst_low = 0, rs_f6 = 0, rs_f6_rst_low = 0, f6_pend = 0, rgn_bad = 0;
	bit     rt_win = 1'b0, rs_win = 1'b0;
	int     marker_rs = -1, calls_rs0 = -1, calls_rt0 = -1;
	logic   rin_f6 = 1'b1;
	always @(posedge tb.clk_sys) begin
		automatic bit cw = `W_BC.capture.cart_win;
		automatic bit crst = `W_FE.cart_reset;
		automatic bit busy = tb.dut.pll_busy_s[1];
		if (cw_d && !cw) t_cw_fall = t_sys;
		if (!crst_d && crst) t_crst_rise = t_sys;
		if (!busy_d && busy) begin
			t_busy_rise = t_sys; rt_win = 1'b1;
		end
		if (busy_d && !busy) begin
			t_busy_fall = t_sys;
			calls_rt0 = calls;
		end
		if (tb.reset_in && !rin_f6) begin
			rs_win = 1'b1;
			marker_rs = int'(tb.dut.main.riot_inst.riot_ram.mem_q[127]);
			calls_rs0 = calls;
		end
		if (`W_CP.f6_q && !f6_d) begin
			automatic bit by_win = t_cw_fall >= 0 && t_sys - t_cw_fall <= 4;
			f6_n++;
			if (by_win) begin f6_win++; f6_win_dt = t_sys - t_cw_fall; end
			else f6_rst++;
			if (t_busy_rise >= 0) begin
				rt_f6++;
				if (busy || t_busy_fall < t_busy_rise) rt_f6_early++;
			end
			if (rs_win) rs_f6++;
			$display("WIRE f6 start %0d at clk_sys %0d (%0.3f ms): %0s, %0s, cart_reset rose %0d clk_sys before",
				f6_n, t_sys, ms(), by_win ? $sformatf("window close +%0d", t_sys - t_cw_fall) : "not the window",
				`W_CP.f6_dpc ? "DPC+" : (`W_CP.f6_r32 ? "CDF 32 KB" : "CDF 8 KB"),
				t_crst_rise >= 0 ? t_sys - t_crst_rise : -1);
		end
		if (!`W_CP.f6_q && f6_d) begin
			automatic logic [63:0] h = ram_hash(`W_CP.f6_r32 && !`W_CP.f6_dpc);
			if (f6_n == 1) f6_h0 = h;
			else if (h != f6_h0) f6_ram_diff++;
			$display("WIRE f6 end %0d at clk_sys %0d (%0.3f ms): RAM hash %016x%0s", f6_n, t_sys, ms(), h,
				f6_n == 1 ? "" : (h == f6_h0 ? ", equal to F6 1's" : ", DIFFERENT from F6 1's"));
			if (rt_win) rt_win = 1'b0;     // the retune window ends with its F6
			if (rs_win) rs_win = 1'b0;
		end
		if (`W_CP.f6_q) begin
			if (!tb.dut.reset) f6_rst_low++;
			if (busy) f6_busy++;
			if (!`W_FE.init_busy) f6_noib++;
		end
		if (`W_CP.a_f6_live) f6_live++;
		// +wire_pll: F6 running while pll_region is busy, or would start a
		// retune as soon as its loading input is low
		if (`W_CP.f6_q && pll_on && (u_pr.busy || tb.is_pal != u_pr.pll_pal)) f6_pend++;
		// +wire_pll: daria_rgn, and daria_mmio's pal at the end of its wiring
		// (the wrapper's .daria_pal, bupchip's .pal), against the region the
		// PLL is set to (rgn_bad)
		if (pll_on && t_sys > 4 && !u_pr.busy && !busy && !busy_d && tb.dut.daria_rt_cnt != 4'd15 &&
				(tb.dut.daria_rgn != u_pr.pll_pal || `W_BC.mmio.pal != u_pr.pll_pal)) rgn_bad++;
		// the console reset from pll_busy_s[1]'s rise (+1: the register follows it)
		// to the end of the F6 after it; a non-ARM image has none: to the fall
		if (rt_win && t_sys > t_busy_rise + 1 && !tb.dut.reset) rt_rst_low++;
		if (rt_win && !tb.dut.daria_arm && t_busy_fall > t_busy_rise) rt_win = 1'b0;
		if (rs_win && t_sys > t_rin + 1 && !tb.dut.reset) rs_f6_rst_low++;
		f6_d <= `W_CP.f6_q;
		rin_f6 <= tb.reset_in;
		cw_d <= cw;
		crst_d <= crst;
		busy_d <= busy;
	end

	// ---- daria_fe's RAM writes, daria_hold ------------------------------------------------
	int  wr_crb = 0, wr_stb = 0, wr_busy = 0, wr_stop = 0, wr_drop = 0, wr_after_load2 = 0, hold_rise = 0;
	longint prof_clk = 0;
	logic hold_d = 1'b0;
	always @(posedge tb.clk_sys) begin
		automatic bit cwe = `W_BC.daria_crb_we, swe = `W_BC.daria_stb_we;
		if (cwe) wr_crb++;
		if (swe) wr_stb++;
		if ((cwe || swe) && tb.dut.pll_busy_s[1]) begin
			wr_busy++;
			if (wr_busy <= 40)
				$display("WIRE write while pll_busy at clk_sys %0d (%0.6f ms): %0s word %0d, F6 %0d, copy engine %0d, pll_locked %0d",
					t_sys, ms(), cwe ? "cart RAM" : "state RAM", cwe ? `W_FE.crb_addr : 13'(`W_FE.stb_addr),
					`W_CP.f6_q, `W_CP.run, tb.pll_locked_tb);
		end
		if ((`W_FE.crb_we && !cwe) || (`W_FE.stb_we && !swe)) begin
			wr_drop++;
			if (wr_drop <= 40)
				$display("WIRE drop at clk_sys %0d (%0.6f ms): %0s word %0d, F6 %0d, copy engine %0d, pll_busy_s[1] %0d",
					t_sys, ms(), `W_FE.crb_we ? "cart RAM" : "state RAM", `W_FE.crb_we ? `W_FE.crb_addr : 13'(`W_FE.stb_addr),
					`W_CP.f6_q, `W_CP.run, tb.dut.pll_busy_s[1]);
		end
		if ((cwe || swe) && t_load2 >= 0) wr_after_load2++;
		if (tb.dut.daria_hold && !hold_d) hold_rise++;
		hold_d <= tb.dut.daria_hold;
		if (tb.dut.daria_profile) prof_clk++;
	end
	// the write enables as the PLL's outputs stop and restart
	always @(tb.clk_run) begin
		#0.001;
		if (`W_BC.daria_crb_we || `W_BC.daria_stb_we) begin
			wr_stop++;
			$display("WIRE write enable high as the clocks %0s (%0.6f ms)", tb.clk_run ? "restart" : "stop", ms());
		end
	end

	// ---- calls, returns, samples --------------------------------------------------------
	// A call open when daria_fe's cart_reset rises is abandoned (a console
	// reset or the end of a retune resets both sides); a return with no open
	// call is an orphan.
	logic ct_d = 1'b0, cta_d = 1'b0, rt_d = 1'b0, rtf_d = 1'b0, sq_d = 1'b0, sa_d = 1'b0, on_s = 1'b0, on_a = 1'b0;
	logic cr_d = 1'b0;
	real call_t [$];
	real ret_max = 0.0;
	int  abandoned = 0, orphans = 0;
	always @(posedge tb.clk_sys) begin
		on_s <= 1'b1;
		if (on_s && `W_FE.call_tog != ct_d) begin calls++; call_t.push_back($realtime); end
		if (on_s && `W_FE.smp_req != sq_d) smp_req++;
		if (`W_FE.cart_reset && !cr_d && call_t.size() > 0) begin
			abandoned += call_t.size();
			$display("WIRE %0d open call(s) abandoned at a cart_reset rise (%0.3f ms)", call_t.size(), ms());
			call_t.delete();
		end
		ct_d <= `W_FE.call_tog;
		sq_d <= `W_FE.smp_req;
		cr_d <= `W_FE.cart_reset;
	end
	always @(posedge tb.clk_arm) begin
		on_a <= 1'b1;
		if (on_a && `W_BC.daria_call_tog != cta_d) calls_arm++;
		if (on_a && `W_BC.daria_ret_tog != rt_d) begin
			rets++;
			if (call_t.size() > 0) begin
				automatic real d = $realtime - call_t.pop_front();
				if (d > ret_max) ret_max = d;
			end else orphans++;
		end
		if (on_a && `W_FE.ret_tog != rtf_d) rets_fe++;
		if (on_a && `W_BC.daria_smp_ack != sa_d) smp_ack++;
		cta_d <= `W_BC.daria_call_tog;
		rt_d <= `W_BC.daria_ret_tog;
		rtf_d <= `W_FE.ret_tog;
		sa_d <= `W_BC.daria_smp_ack;
	end

	// ---- +wire_retune=svc|call|twice: a retune that lands in a service or a call,
	// or two retunes back to back ------------------------------------------------------
	// The sequence of tb_load's +retune (pll_region's: pll_busy, 258 clk_74a,
	// the PLL's outputs stopped between edges on their lattice for 20 us,
	// pll_locked 1 us after they restart, pll_busy 258 clk_74a after that),
	// started +wire_retune_dly=D clk_sys (default 2) after the K-th
	// (+wire_retune_k, default 3) start of a copy-engine service (u_copy.run
	// rising: svc) or call (call_tog flipping: call) from
	// +wire_retune_after=MS ms (default 60) after reset_in falls. twice: MS
	// ms after reset_in falls, two of them, with pll_busy low for one clk_74a
	// between, as pll_region makes it when the region changed during the first
	// (it starts again on the next clk_74a); +wire_retune_catch=1 (default)
	// puts a clk_sys rising edge inside that clk_74a, so pll_busy_s sees one
	// clk_sys low, 0 puts it between two. Not with tb_load's own +retune, nor
	// with +wire_pll.
	longint sys_rise_ps = -1;
	always @(posedge tb.clk_sys) sys_rise_ps = longint'(t_ns() * 1000.0);
	initial begin
		automatic string what;
		automatic int k = 3, dly = 2, after = 60, gap_catch = 1;
		if ($value$plusargs("wire_retune=%s", what)) begin
			void'($value$plusargs("wire_retune_k=%d", k));
			void'($value$plusargs("wire_retune_dly=%d", dly));
			void'($value$plusargs("wire_retune_after=%d", after));
			void'($value$plusargs("wire_retune_catch=%d", gap_catch));
			if (what != "svc" && what != "call" && what != "twice")
				$fatal(1, "+wire_retune=%0s: svc, call or twice", what);
			wait (tb.reset_in == 1'b0);
			for (int i = 0; i < after; i++) repeat (14318) @(posedge tb.clk_sys);
			if (what != "twice")
				for (int i = 0; i < k; i++)
					if (what == "svc") @(posedge `W_CP.run);
					else @(`W_FE.call_tog);
			repeat (dly) @(posedge tb.clk_sys);
			$display("WIRE retune at %0.3f ms: %0d clk_sys after %0s %0d (u_copy.run %0d, open calls %0d)",
				ms(), dly, what, k, `W_CP.run, call_t.size());
			tb.pll_busy_tb = 1'b1;
			#(258 * 13.468);
			pll_stop_restart(20);
			#(258 * 13.468);
			if (what == "twice") begin
				// the clk_74a edge where busy falls for one clk_74a: d ps to
				// the next clk_sys rising edge (the clocks run on a lattice)
				automatic longint now_ps, ph, d;
				automatic bit found = 1'b0;
				while (!found) begin
					@(posedge tb.clk_74a);
					now_ps = longint'(t_ns() * 1000.0);
					ph = (now_ps - sys_rise_ps) % 69840;
					d = ph == 0 ? 0 : 69840 - ph;
					found = gap_catch != 0 ? (d > 1000 && d < 12400) : (d > 14500);
				end
				tb.pll_busy_tb = 1'b0;
				@(posedge tb.clk_74a);
				tb.pll_busy_tb = 1'b1;
				$display("WIRE retune twice: pll_busy low for one clk_74a at %0.6f ms, a clk_sys rising edge %0.3f ns after it fell (%0s)",
					ms(), d / 1000.0, gap_catch != 0 ? "inside" : "after it");
				#(258 * 13.468);
				pll_stop_restart(20);
				#(258 * 13.468);
			end
			tb.pll_busy_tb = 1'b0;
		end
	end

	// ---- +wire_reset_on_pal=K: a console reset as region_pll changes ---------------------
	// With +wire_pll: on the K-th clk_sys at which atari7800_pocket.sv's region_pll
	// is about to change (not held, region_select differs), reset_in rises at
	// that clock's falling edge, so the console reset rises on the edge where
	// region_pll changes, about 2 clk_sys before pll_busy_s[1] shows the retune
	// that the change starts; held for +wire_reset_clk=N clk_sys (default 49).
	initial begin
		automatic int k = 0, n = 49, seen = 0;
		if ($value$plusargs("wire_reset_on_pal=%d", k)) begin
			void'($value$plusargs("wire_reset_clk=%d", n));
			while (seen < k) begin
				@(posedge tb.clk_sys);
				if (!tb.dut.region_pll_hold && tb.dut.region_select != tb.dut.region_pll) seen++;
			end
			@(negedge tb.clk_sys);
			tb.reset_in = 1'b1;
			$display("WIRE reset_in rises as region_pll changes to %0d (%0.6f ms)", tb.dut.region_select, ms());
			repeat (n) @(negedge tb.clk_sys);
			tb.reset_in = 1'b0;
		end
	end

	// ---- +wire_seq=MODE: a retune that waits for a load sequence's end (finding 3) ------
	// The Pocket's is_downloading (core_top.v) rises at a slot's requestwrite
	// and falls at allcomplete, after the last slot of a load sequence;
	// pll_region starts no retune while it is high. The slot model above lets
	// it fall at the end of each slot. Here (with +wire_pll) seq_ld holds it
	// high across a sequence that the script starts, with the console running
	// wherever no slot holds it in reset (a save slot, hsc.sav or savekey.sav,
	// raises no download flag in the core), and drops it at the script's
	// allcomplete. Each script asks for a region change while the sequence
	// runs, so pll_region waits for allcomplete, and lands allcomplete where,
	// without the fix of finding 3, it starts that retune inside an F6:
	//   menu  the Region setting to PAL (the sequence starts +wire_seq_at=MS
	//         after the first F6's console release, default 3), then the
	//         menu's Reset (reset_in for +wire_reset_clk=N clk_sys, default
	//         49) +wire_seq_hold=US later (default 1000), then allcomplete
	//         +wire_seq_ac=US after reset_in rose (default 30): the reset's F6
	//         would run then (the review's scratch tap);
	//   auto  (+image2, an ARM image after a PAL A78, Region on Auto) the
	//         second cartridge is the sequence's first slot; when its console
	//         is released, Auto asks for NTSC; then the menu's Reset and
	//         allcomplete as in menu, from that release;
	//   tia   (a PAL ARM image on Auto) the sequence starts +wire_seq_at=MS
	//         after the first F6's release (default 500); the TIA's PAL
	//         decision asks for PAL; then the menu's Reset and allcomplete as
	//         in menu, from that decision;
	//   load  the Region setting to PAL as in menu; the +image2 cartridge (an
	//         ARM image) is the sequence's last slot: allcomplete with the
	//         slot model's end (21 clk_74a before cart_download falls), so its
	//         window-close F6 starts a few clk_sys after allcomplete;
	//   slot  the Region setting to PAL as in menu; +wire_seq_hold=US later a
	//         reset-causing slot (the Supercharger BIOS slot, 0x107, at bridge
	//         address 0x06000000), the sequence's last, of +wire_seq_words=N
	//         words of $FF (default 64, about 0.1 ms with its gaps):
	//         allcomplete 2,058 clk_74a after its last write, with its flag's
	//         fall (as the slot model has it for the bench's firmware slots).
	// Two scripts aim at the parts of the fix that freeze region_pll (the fix
	// round's review: each freeze removed alone passed the five above):
	//   rfirst the sequence starts as in menu, then the menu's Reset with no
	//         retune pending, and the Region setting to PAL
	//         +wire_seq_hold_clk=N clk_sys after reset_in rose (at a falling
	//         edge, default 1): region_pll would take it on the clock after
	//         the console reset rose, before tia_en falls, where only the
	//         freeze in an ARM image's console reset holds it; allcomplete
	//         +wire_seq_ac=US after reset_in rose, inside the reset's F6.
	//         The line "the Region setting to PAL ... (reset first)" gives
	//         region_pll's holds at that clock;
	//   back  the Region setting to PAL as in menu, so a retune is pending
	//         with the console running; allcomplete +wire_seq_hold=US later
	//         (default 1000); as pll_region starts the retune (its busy
	//         rising), the Region setting back to Auto (NTSC for an NTSC
	//         image) at the next clk_sys falling edge, before pll_busy_s[1]
	//         rises, where only the freeze while a retune is pending holds
	//         region_pll (the line "the Region setting back to Auto ..." gives
	//         its holds there). Unfrozen, daria_rgn would take NTSC from a
	//         retune to PAL, and pll_region would start a second retune as
	//         the first ends; frozen, the second comes after the first's F6.
	// The "WIRE seq" lines give pll_region's own view (is_pal_o, the region
	// the PLL is set to, busy, loading) at each step.
	task automatic seq_state(input string what);
		$display("WIRE seq %0s at %0.6f ms: is_pal_o %0d, the PLL %0s, pll_region busy %0d, loading %0d, console reset %0d, F6 %0d",
			what, ms(), tb.is_pal, u_pr.pll_pal ? "PAL" : "NTSC", u_pr.busy,
			seq_ld | dl_cart | tb.bios_download | tb.hscfw_download | tb.arfw_download | tb.bupfw_download,
			tb.dut.reset, `W_CP.f6_q);
	endtask
	initial begin
		automatic string mode;
		automatic int at = -1, hold_us = 1000, ac_us = 30, rclk = 49, words = 64, hold_clk = 1;
		if ($value$plusargs("wire_seq=%s", mode)) begin
			if (!$test$plusargs("wire_pll")) $fatal(1, "+wire_seq needs +wire_pll");
			if (mode != "menu" && mode != "auto" && mode != "tia" && mode != "load" && mode != "slot" &&
					mode != "rfirst" && mode != "back")
				$fatal(1, "+wire_seq=%0s: menu, auto, tia, load, slot, rfirst or back", mode);
			void'($value$plusargs("wire_seq_at=%d", at));
			if (at < 0) at = mode == "tia" ? 500 : 3;
			void'($value$plusargs("wire_seq_hold=%d", hold_us));
			void'($value$plusargs("wire_seq_hold_clk=%d", hold_clk));
			void'($value$plusargs("wire_seq_ac=%d", ac_us));
			void'($value$plusargs("wire_reset_clk=%d", rclk));
			void'($value$plusargs("wire_seq_words=%d", words));
			wait (tb.reset_in == 1'b0);
			if (mode == "auto") begin
				@(posedge tb.cart_download);
				seq_ld = 1'b1;
				seq_state("starts with a cartridge slot");
				@(negedge `W_CP.f6_q);
				wait (tb.dut.reset == 1'b0);
				seq_state("console released");
			end else begin
				@(negedge `W_CP.f6_q);
				wait (tb.dut.reset == 1'b0);
				for (int i = 0; i < at; i++) repeat (14318) @(posedge tb.clk_sys);
				seq_ld = 1'b1;
				seq_state("starts (a save slot)");
				if (mode == "tia") begin
					@(posedge tb.is_pal);
					seq_state("the TIA's PAL decision");
				end else if (mode == "rfirst") begin
					repeat (10) @(negedge tb.clk_sys);
					seq_state("reset_in rises first (the menu's Reset)");
					tb.reset_in = 1'b1;
					fork
						begin repeat (rclk) @(negedge tb.clk_sys); tb.reset_in = 1'b0; end
						begin
							repeat (hold_clk) @(negedge tb.clk_sys);
							// what region_pll's register sees on the next rising edge
							tb.region_tb = 2'd2;
							$display("WIRE seq the Region setting to PAL at %0.6f ms (reset first, %0d clk_sys after reset_in): region_pll_hold %0d, ARM console reset %0d, retune pending %0d, pll_busy_s %0d, F6 %0d",
								ms(), hold_clk, tb.dut.region_pll_hold, tb.dut.daria_reset & tb.dut.daria_arm,
								tb.dut.daria_rt_pend, tb.dut.pll_busy_s[1], `W_CP.f6_q);
						end
						begin #(ac_us * 1000.0); seq_ld = 1'b0; seq_state("allcomplete"); end
					join
				end else begin
					repeat (10) @(posedge tb.clk_sys);
					tb.region_tb = 2'd2;
					$display("WIRE seq the Region setting to PAL at %0.6f ms", ms());
				end
			end
			if (mode == "rfirst") begin
				// (all done above)
			end else if (mode == "back") begin
				#(hold_us * 1000.0);
				@(negedge tb.clk_sys);
				seq_state("allcomplete comes, the console running");
				seq_ld = 1'b0;
				@(posedge pr_busy);
				@(negedge tb.clk_sys);
				// what region_pll's register sees on the next rising edge
				tb.region_tb = 2'd0;
				$display("WIRE seq the Region setting back to Auto at %0.6f ms, pll_region retuning: pll_region busy %0d to %0s, pll_busy_s %0d, region_pll_hold %0d, ARM console reset %0d, retune pending %0d",
					ms(), u_pr.busy, u_pr.target ? "PAL" : "NTSC", tb.dut.pll_busy_s[1], tb.dut.region_pll_hold,
					tb.dut.daria_reset & tb.dut.daria_arm, tb.dut.daria_rt_pend);
			end else if (mode == "load") begin
				@(posedge tb.cart_download);
				seq_state("cartridge slot starts");
				@(negedge dl_cart);
				seq_ld = 1'b0;
				seq_state("allcomplete, the cartridge slot the last");
			end else if (mode == "slot") begin
				#(hold_us * 1000.0);
				@(posedge tb.clk_74a);
				seq_state("reset-causing slot starts");
				tb.arfw_download = 1'b1;
				repeat (100) @(posedge tb.clk_74a);
				for (int i = 0; i < words; i++) begin
					@(posedge tb.clk_74a);
					tb.bridge_addr = 32'h06000000 + 4 * i;
					tb.bridge_wr_data = 32'hFFFFFFFF;
					tb.bridge_wr = 1'b1;
					@(posedge tb.clk_74a);
					tb.bridge_wr = 1'b0;
					repeat (78) @(posedge tb.clk_74a);
				end
				repeat (2058) @(posedge tb.clk_74a);
				seq_ld = 1'b0;
				tb.arfw_download = 1'b0;
				seq_state("allcomplete, the slot the last");
			end else begin
				#(hold_us * 1000.0);
				@(negedge tb.clk_sys);
				seq_state("reset_in rises (the menu's Reset)");
				tb.reset_in = 1'b1;
				fork
					begin repeat (rclk) @(negedge tb.clk_sys); tb.reset_in = 1'b0; end
					begin #(ac_us * 1000.0); seq_ld = 1'b0; seq_state("allcomplete"); end
				join
			end
		end
	end

	// ---- the BupChip ----------------------------------------------------------------------
	int  halts = 0, unlocks = 0, misses = 0;
	logic halt_d = 1'b0;
	always @(posedge tb.clk_arm) begin
		if (`W_BC.halted && !halt_d) halts++;
		halt_d <= `W_BC.halted;
		if (`W_BC.st_miss) misses++;
	end
	always @(posedge tb.clk_sys) if (`W_FE.dbg_unlock) unlocks++;

	// ---- +wire_pcm: the Souper profile's pushed frames ----------------------------------------
	int  pcm_fd = 0;
	longint pcm_n = 0;
	bit  song_seen = 1'b0;
	string pcm_path;
	initial if ($value$plusargs("wire_pcm=%s", pcm_path)) begin
		pcm_fd = $fopen(pcm_path, "wb");
		if (pcm_fd == 0) $fatal(1, "cannot open %s", pcm_path);
	end
	always @(posedge tb.clk_arm) if (pcm_fd != 0) begin
		if (`W_BC.per_sel && `W_BC.reg_write && `W_BC.reg_addr == 8'h10) begin
			$fwrite(pcm_fd, "%c%c%c%c", `W_BC.reg_wdata[7:0], `W_BC.reg_wdata[15:8],
				`W_BC.reg_wdata[23:16], `W_BC.reg_wdata[31:24]);
			pcm_n++;
		end
		if (`W_BC.per.cmd_pop && !song_seen) begin
			song_seen = 1'b1;
			$display("WIRE song start %0d (%0.3f ms)", pcm_n, ms());
		end
	end

	final begin
		automatic int open_old = 0;
		automatic string w;
		foreach (call_t[i]) if ($realtime - call_t[i] > 2.0e6) open_old++;
		if (pcm_fd != 0) $fclose(pcm_fd);
		w = $sformatf("WIRE summary build=daria releases=%0d f6=%0d f6_win=%0d f6_rst=%0d f6_win_dt=%0d",
			rel_n, f6_n, f6_win, f6_rst, f6_win_dt);
		w = {w, $sformatf(" f6_rst_low=%0d f6_busy=%0d f6_noib=%0d f6_live=%0d f6_ram_diff=%0d",
			f6_rst_low, f6_busy, f6_noib, f6_live, f6_ram_diff)};
		w = {w, $sformatf(" wr_crb=%0d wr_stb=%0d wr_busy=%0d wr_stop=%0d wr_drop=%0d wr_after_load2=%0d hold_rise=%0d prof_clk=%0d",
			wr_crb, wr_stb, wr_busy, wr_stop, wr_drop, wr_after_load2, hold_rise, prof_clk)};
		w = {w, $sformatf(" calls=%0d calls_arm=%0d rets=%0d rets_fe=%0d ret_max_us=%0d open_old=%0d abandoned=%0d orphans=%0d",
			calls, calls_arm, rets, rets_fe, int'(ret_max / 1000.0), open_old, abandoned, orphans)};
		w = {w, $sformatf(" smp_req=%0d smp_ack=%0d", smp_req, smp_ack)};
		w = {w, $sformatf(" halts=%0d unlocks=%0d locked=%0d psram_viol=%0d psram_cs=%0.6f misses=%0d",
			halts, unlocks, `W_FE.dbg_locked, tb.cram0_chip.n_viol, tb.dut.bup_psram.CLOCK_SPEED, misses)};
		w = {w, $sformatf(" rt_rst_low=%0d rt_f6=%0d rt_f6_early=%0d rs_f6=%0d rs_f6_rst_low=%0d",
			rt_rst_low, rt_f6, rt_f6_early, rs_f6, rs_f6_rst_low)};
		w = {w, $sformatf(" f6_pend=%0d rgn_bad=%0d", pll_on ? f6_pend : -1, pll_on ? rgn_bad : -1)};
		w = {w, $sformatf(" calls_rs=%0d calls_rt=%0d marker=%0d errors=%0d marker_rs=%0d",
			calls_rs0 < 0 ? -1 : calls - calls_rs0, calls_rt0 < 0 ? -1 : calls - calls_rt0,
			tb.dut.main.riot_inst.riot_ram.mem_q[127], tb.dut.main.riot_inst.riot_ram.mem_q[126], marker_rs)};
		w = {w, $sformatf(" retunes=%0d b2b=%0d pal_chg=%0d is_pal=%0d", retunes, b2b, pal_chg, tb.is_pal)};
		$display("%s", w);
	end
`else
	final $display("WIRE summary build=plain releases=%0d retunes=%0d b2b=%0d pal_chg=%0d is_pal=%0d",
		rel_n, retunes, b2b, pal_chg, tb.is_pal);
`endif
endmodule
