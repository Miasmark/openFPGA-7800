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
//                     of the cart RAM it wrote (and of the state RAM's 32 call
//                     words), and whether it equals the first F6's
//   WIRE pll_busy ...      the synchronised pll_busy (pll_busy_s[1]) rising and
//                     falling (+retune), in both builds
//   WIRE reset_in ...      the bench's reset_in rising (+resetat)
//   WIRE summary k=v ...   at the end: the counts below
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
//   wr_crb, wr_stb          daria_fe's cart RAM and state RAM writes (port B)
//   wr_busy                 of those, while pll_busy (raw or pll_busy_s[1]) is
//                           high (the first 40 also as WIRE write lines)
//   wr_after_load2          of those, after a +image2 load started
//   hold_rise               rises of daria_hold (init_busy for an ARM scheme)
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
	int     rt_f6 = 0, rt_f6_early = 0, rt_rst_low = 0, rs_f6 = 0, rs_f6_rst_low = 0;
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
	int  wr_crb = 0, wr_stb = 0, wr_busy = 0, wr_after_load2 = 0, hold_rise = 0;
	logic hold_d = 1'b0;
	always @(posedge tb.clk_sys) begin
		if (`W_FE.crb_we) wr_crb++;
		if (`W_FE.stb_we) wr_stb++;
		if ((`W_FE.crb_we || `W_FE.stb_we) && (tb.dut.pll_busy_s[1] || tb.pll_busy_tb)) begin
			wr_busy++;
			if (wr_busy <= 40)
				$display("WIRE write while pll_busy at clk_sys %0d (%0.6f ms): %0s word %0d, F6 %0d, copy engine %0d, pll_busy_s[1] %0d, pll_locked %0d",
					t_sys, ms(), `W_FE.crb_we ? "cart RAM" : "state RAM", `W_FE.crb_we ? `W_FE.crb_addr : 13'(`W_FE.stb_addr),
					`W_CP.f6_q, `W_CP.run, tb.dut.pll_busy_s[1], tb.pll_locked_tb);
		end
		if ((`W_FE.crb_we || `W_FE.stb_we) && t_load2 >= 0) wr_after_load2++;
		if (tb.dut.daria_hold && !hold_d) hold_rise++;
		hold_d <= tb.dut.daria_hold;
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

	// ---- +wire_retune=svc|call: a retune that lands in a service or a call ---------------
	// The sequence of tb_load's +retune (pll_region's: pll_busy, 258 clk_74a,
	// the PLL's outputs stopped between edges on their lattice for 20 us,
	// pll_locked 1 us after they restart, pll_busy 258 clk_74a after that),
	// started +wire_retune_dly=D clk_sys (default 2) after the K-th
	// (+wire_retune_k, default 3) start of a copy-engine service (u_copy.run
	// rising: svc) or call (call_tog flipping: call) from
	// +wire_retune_after=MS ms (default 60) after reset_in falls. Not with
	// tb_load's own +retune.
	initial begin
		automatic string what;
		automatic int k = 3, dly = 2, after = 60;
		automatic longint lcm, now_ps, t_ps, w_ps;
		if ($value$plusargs("wire_retune=%s", what)) begin
			void'($value$plusargs("wire_retune_k=%d", k));
			void'($value$plusargs("wire_retune_dly=%d", dly));
			void'($value$plusargs("wire_retune_after=%d", after));
			if (what != "svc" && what != "call") $fatal(1, "+wire_retune=%0s: svc or call", what);
			wait (tb.reset_in == 1'b0);
			for (int i = 0; i < after; i++) repeat (14318) @(posedge tb.clk_sys);
			for (int i = 0; i < k; i++)
				if (what == "svc") @(posedge `W_CP.run);
				else @(`W_FE.call_tog);
			repeat (dly) @(posedge tb.clk_sys);
			$display("WIRE retune at %0.3f ms: %0d clk_sys after %0s %0d (u_copy.run %0d, open calls %0d)",
				ms(), dly, what, k, `W_CP.run, call_t.size());
			tb.pll_busy_tb = 1'b1;
			#(258 * 13.468);
			lcm = tb.arm_div == 19 ? 1326960 : 209520;
			now_ps = longint'(t_ns() * 1000.0);
			t_ps = (now_ps / lcm + 1) * lcm + 1;
			while (t_ps % 8730 == 0 || (t_ps - tb.arm_ofs) % (tb.arm_div == 19 ? 27645 : 13095) == 0
				|| (tb.arm_div == 19 && (t_ps - tb.arm_ofs) % 27645 == 13823)) t_ps++;
			w_ps = (longint'(20) * 1000000 + lcm - 1) / lcm * lcm;
			#((t_ps - now_ps) * 0.001);
			tb.clk_run = 1'b0;
			tb.pll_locked_tb = 1'b0;
			#(w_ps * 0.001);
			tb.clk_run = 1'b1;
			#1000.0;
			tb.pll_locked_tb = 1'b1;
			#(258 * 13.468);
			tb.pll_busy_tb = 1'b0;
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
		w = {w, $sformatf(" wr_crb=%0d wr_stb=%0d wr_busy=%0d wr_after_load2=%0d hold_rise=%0d",
			wr_crb, wr_stb, wr_busy, wr_after_load2, hold_rise)};
		w = {w, $sformatf(" calls=%0d calls_arm=%0d rets=%0d rets_fe=%0d ret_max_us=%0d open_old=%0d abandoned=%0d orphans=%0d",
			calls, calls_arm, rets, rets_fe, int'(ret_max / 1000.0), open_old, abandoned, orphans)};
		w = {w, $sformatf(" smp_req=%0d smp_ack=%0d", smp_req, smp_ack)};
		w = {w, $sformatf(" halts=%0d unlocks=%0d locked=%0d psram_viol=%0d psram_cs=%0.6f misses=%0d",
			halts, unlocks, `W_FE.dbg_locked, tb.cram0_chip.n_viol, tb.dut.bup_psram.CLOCK_SPEED, misses)};
		w = {w, $sformatf(" rt_rst_low=%0d rt_f6=%0d rt_f6_early=%0d rs_f6=%0d rs_f6_rst_low=%0d",
			rt_rst_low, rt_f6, rt_f6_early, rs_f6, rs_f6_rst_low)};
		w = {w, $sformatf(" calls_rs=%0d calls_rt=%0d marker=%0d errors=%0d marker_rs=%0d",
			calls_rs0 < 0 ? -1 : calls - calls_rs0, calls_rt0 < 0 ? -1 : calls - calls_rt0,
			tb.dut.main.riot_inst.riot_ram.mem_q[127], tb.dut.main.riot_inst.riot_ram.mem_q[126], marker_rs)};
		$display("%s", w);
	end
`else
	final $display("WIRE summary build=plain releases=%0d", rel_n);
`endif
endmodule
