// tb_region: the wrapper's region logic (region_unit, cut out of
// atari7800_pocket.sv by sim/region_unit.py) with core/pll_region.v, in the
// load sequences of RTL-1 and RTL-2 (docs/IMPROVEMENTS.md, "After 2.2.1").
// sim/run_region.sh builds it for the DARIA and the plain build and for
// planted variants, and judges the lines it prints.
//
// Modelled, as the wrapper and core_top.v have them: is_downloading
// (requestwrite to allcomplete, clk_74a) and cart_download, 4 clk_sys
// behind it (core_top.v's dl_s and register); one loader byte every 2
// clk_sys from the 3rd clk_sys of cart_download, ioctl_addr holding the last
// byte's address after it; cart_is_7800 a clock after byte 5 of an A78
// (bytes 1-5 "ATARI"), cleared by byte 1 of a 2600 image; cart_region[0]
// from byte 57 of an A78, cleared at a 2600 image's end; tia_mode cleared by
// cart_download and set at a 2600 image's end; the console reset (the
// download, the clock after it, pll_busy_s) and tia_en (tia_mode, the
// console out of reset); tia_pal_seen (cleared by cart_download, set while
// a PAL 2600 game runs); Auto's region_select. Not modelled: clk_sys
// stopping in a retune (it runs throughout here) and ARM images
// (daria_arm 0, daria_reset 0). The reconfiguration port's model is
// tb_pll_region.sv's (waitrequest after each write, lock lost and regained
// after the start).
//
// Scenarios (each trial starts with the PLL in a known region, nothing
// pending, and ends once the PLL, region_pll and daria_rgn agree for 3,000
// clk_74a with no retune):
//   A  RTL-2. NTSC, a 2600 game running, Region NTSC. The Region setting
//      goes to PAL, a retune starts, and 40 clk_74a later a 70-byte 2600
//      image's load sequence starts, its allcomplete D clk_74a after its
//      requestwrite, D = 760 to 2,400: across the retune's end. Want 1
//      retune in every trial.
//   B  RTL-1. PAL, a PAL 2600 game running on Auto (as tb_wire's
//      pal2600_a78). Then an A78 of 384 bytes, its allcomplete E = 0-40
//      clk_74a after its last byte. "pal": byte 57 says PAL, want 0
//      retunes; "ntsc": byte 57 says NTSC, want 1, to NTSC.
//   C  The last clk_sys of an A78's download. NTSC, an NTSC A78 of 384
//      bytes loading, Region NTSC. At byte 200 the setting goes to PAL (a
//      retune pending), and F clk_74a after allcomplete back to NTSC, F =
//      -8 to +40: across allcomplete and the clocks where cart_download
//      outlives is_downloading. Want 2 retunes (to PAL at the load's end,
//      back after it) and daria_rgn exact in every trial.
// Per trial: retunes (pll_region's busy rises), b2b (a retune starting
// within 8 clk_74a of the last one's end), rgn_bad (DARIA only: clk_sys
// cycles where daria_rgn is not the PLL's region, pll_region's pll_pal,
// outside the retune and its first clk_sys after it).
// Output: one "REGION <scenario> trials <n> retunes <count>:<trials> ...
// rgn_bad <n> b2b <n>" line per scenario, "REGION done".
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_region;
	logic clk_74a = 0; always #6.734 clk_74a = ~clk_74a;
	logic clk_sys = 0; always #34.9205 clk_sys = ~clk_sys;

	// ---- pll_region and the reconfiguration port --------------------------------------------------
	logic locked = 1, waitreq = 0, is_downloading = 0;
	wire  busy, cfg_write; wire [5:0] cfg_address; wire [31:0] cfg_writedata;
	wire  is_pal;
	pll_region pr (.clk(clk_74a), .is_pal, .loading(is_downloading), .pll_locked(locked), .busy,
		.cfg_waitrequest(waitreq), .cfg_write, .cfg_address, .cfg_writedata);
	int wr_hold = 0, relock = 0;
	always @(posedge clk_74a) begin
		if (wr_hold) begin wr_hold--; if (wr_hold == 0 && relock == 0) waitreq <= 0; end
		if (relock) begin
			relock--;
			if (relock == 900) locked <= 0;
			if (relock == 0) begin locked <= 1; waitreq <= 0; end
		end
		if (cfg_write) begin
			waitreq <= 1; wr_hold = 3;
			if (cfg_address == 6'd2) relock = 1000;
		end
	end

	// ---- the loader and the wrapper's inputs ------------------------------------------------------
	logic [2:0]  dl_s = 0;
	logic        cart_download = 0, cd_d = 0;
	logic [24:0] ioctl_addr = 25'd4095;
	int          nbytes = 70, byte_n = 0, pace = 0;
	logic        img_a78 = 0, img_pal = 0;     // the image being loaded: A78 or 2600, and its byte 57
	logic        cart_is_7800 = 0, hdr_ok = 0, cart_region0 = 0, tia_mode = 1, tia_en = 1;
	logic        reset = 0, tia_pal_seen = 0, game_pal = 0;
	logic [1:0]  setting = 2'd1;               // Region: 0 Auto, 1 NTSC, 2 PAL
	wire         region_select = (setting == 2'd0) ? (tia_en ? tia_pal_seen : cart_region0) : (setting == 2'd2);
	wire         rgn; wire [3:0] rt_cnt;
	region_unit u (.clk_sys, .pll_busy(busy), .cart_download, .cart_is_7800, .ioctl_addr, .region_select,
		.tia_mode, .tia_en, .daria_reset(1'b0), .daria_arm(1'b0), .is_pal_o(is_pal), .rgn_o(rgn), .rt_cnt_o(rt_cnt));

	always @(posedge clk_sys) begin
		dl_s <= {dl_s[1:0], is_downloading};
		cart_download <= dl_s[2];
		cd_d <= cart_download;
		if (cart_download) begin
			pace <= pace + 1;
			if (pace >= 2 && pace[0] == 1'b0 && byte_n < nbytes) begin
				ioctl_addr <= 25'(byte_n);
				byte_n <= byte_n + 1;
			end
			// the wrapper's header case runs on every clk_sys of cart_download, on ioctl_addr
			if (ioctl_addr == 25'd1 && !img_a78) hdr_ok <= 1'b0;
			if (ioctl_addr == 25'd5 && img_a78) hdr_ok <= 1'b1;
			if (ioctl_addr == 25'd57) cart_region0 <= img_a78 ? img_pal : 1'b0;
			tia_mode <= 1'b0;
			tia_pal_seen <= 1'b0;
		end else begin
			pace <= 0; byte_n <= 0;
			if (cd_d) begin
				tia_mode <= ~cart_is_7800;
				if (!cart_is_7800) cart_region0 <= 1'b0;
			end
			if (tia_en && game_pal) tia_pal_seen <= 1'b1;
		end
		cart_is_7800 <= hdr_ok;
		reset <= cart_download | cd_d | u.pll_busy_s[1];
		tia_en <= tia_mode & ~reset;
	end

	// ---- counters ----------------------------------------------------------------------------------
	int retunes = 0, b2b = 0, rgn_bad = 0, since_fall = 1000000;
	logic busy_d = 0;
`ifdef POCKET_DARIA
	localparam bit DARIA = 1;
`else
	localparam bit DARIA = 0;
`endif
	always @(posedge clk_74a) begin
		busy_d <= busy;
		if (busy && !busy_d) begin
			retunes++;
			if (since_fall < 8) b2b++;
		end
		if (!busy && busy_d) since_fall = 0; else if (since_fall < 1000000) since_fall++;
	end
	always @(posedge clk_sys)
		if (DARIA && !u.pll_busy_s[1] && rt_cnt != 4'd15 && rgn != pr.pll_pal) rgn_bad++;

	// ---- helpers -----------------------------------------------------------------------------------
	task automatic ticks(int n); repeat (n) @(posedge clk_74a); endtask
	task automatic quiet();      // the PLL, region_pll and daria_rgn agree, no retune, for 3,000 clk_74a
		int q = 0;
		while (q < 3000) begin
			@(posedge clk_74a);
			if (!busy && !is_downloading && is_pal == pr.pll_pal && rgn == pr.pll_pal) q++; else q = 0;
		end
	endtask
	task automatic load(bit a78, bit pal, int n, int ac_after_last);   // a load sequence; returns after allcomplete
		img_a78 = a78; img_pal = pal; nbytes = n;
		is_downloading = 1;
		wait (byte_n == n);
		ticks(ac_after_last);
		is_downloading = 0;
	endtask

	// one line per scenario: retunes histogram, the totals
	task automatic report(string name, int hist[int], int n, int bad, int bb);
		string s = "";
		foreach (hist[k]) s = {s, $sformatf(" %0d:%0d", k, hist[k])};
		$display("REGION %s trials %0d retunes%s rgn_bad %0d b2b %0d", name, n, s, bad, bb);
	endtask

	int hist[int];
	int n, r0, g0, b0, bad, bb;
	initial begin
		ticks(3000);
		// a 2600 game running, NTSC
		load(0, 0, 70, 20); quiet();

		// ---- A: RTL-2 ----------------------------------------------------------------------------
		hist.delete(); n = 0; bad = 0; bb = 0;
		for (int d = 760; d <= 2400; d++) begin
			r0 = retunes; g0 = rgn_bad; b0 = b2b;
			setting = 2'd2;
			ticks(40);
			img_a78 = 0; img_pal = 0; nbytes = 70;
			is_downloading = 1; ticks(d); is_downloading = 0;
			quiet();
			hist[retunes - r0]++; n++; bad += rgn_bad - g0; bb += b2b - b0;
			setting = 2'd1; quiet();
		end
		report("A", hist, n, bad, bb);

		// ---- B: RTL-1 ----------------------------------------------------------------------------
		for (int pal = 1; pal >= 0; pal--) begin
			hist.delete(); n = 0; bad = 0; bb = 0;
			for (int e = 0; e <= 40; e += 4) begin
				// PAL, a PAL 2600 game on Auto
				setting = 2'd2; quiet();
				game_pal = 1; load(0, 0, 70, 20); quiet();
				setting = 2'd0; ticks(200); quiet();
				r0 = retunes; g0 = rgn_bad; b0 = b2b;
				load(1, pal, 384, e); quiet();
				hist[retunes - r0]++; n++; bad += rgn_bad - g0; bb += b2b - b0;
				game_pal = 0; setting = 2'd1; quiet();
			end
			report(pal ? "B pal" : "B ntsc", hist, n, bad, bb);
		end

		// ---- C: the last clk_sys of an A78's download -----------------------------------------------
		hist.delete(); n = 0; bad = 0; bb = 0;
		for (int f = -8; f <= 40; f++) begin
			setting = 2'd1; load(0, 0, 70, 20); quiet();
			r0 = retunes; g0 = rgn_bad; b0 = b2b;
			img_a78 = 1; img_pal = 0; nbytes = 384;
			is_downloading = 1;
			wait (byte_n == 200); setting = 2'd2;
			wait (byte_n == 384);
			if (f < 0) begin ticks(10 + f); setting = 2'd1; ticks(-f); is_downloading = 0; end
			else begin ticks(10); is_downloading = 0; ticks(f); setting = 2'd1; end
			quiet();
			hist[retunes - r0]++; n++; bad += rgn_bad - g0; bb += b2b - b0;
		end
		report("C", hist, n, bad, bb);
		$display("REGION done");
		$finish;
	end
	initial begin #2s; $display("REGION timeout"); $finish; end
endmodule
