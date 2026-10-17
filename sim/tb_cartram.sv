//------------------------------------------------------------------------------
// tb_cartram: tb_load with the 2600 cartridge-RAM monitor (+cartram) and the
// directed s19 run (+inject). DARIA step 7 (docs/daria_step7/plan.md 3.6,
// 1.2 row 6); the design is docs/DARIA_CORE.md, "Fix B", section 4.
// cartram2600_test.py builds the test images and runs the matrix.
//
// +cartram watches every 2600 cartridge-RAM access in the whole core:
//   - every CPU read of cart RAM (cart2600 answering from cr_do at pclk0):
//     the byte the CPU latches against the SRAM model's; that sram_ctrl
//     handed a cartridge read to c_rdata since E0 (the clk_sys edge where
//     pclk1 loads the 6507's address); the clk_sdram edge of that hand-over
//     counted from E0 (s0 = E0), as a histogram; the margin to the latch;
//   - every 2600 write strobe at the mapper boundary (top.sv cartram_*26):
//     against the cartridge writes sram_ctrl issues, and a shadow of the
//     bytes written, compared with the SRAM model at the end;
//   - the strobe's rise after E0, and any address, direction or data change
//     while it is held.
// At the end it prints the CARTRAM lines cartram2600_test.py checks.
//
// +inject places another client's SRAM access at a chosen clk_sdram edge of
// the 6507 cycle: a BIOS download write (sram_ctrl's dl client, bench-forced
// on its dl_wr input, which is idle in these runs), so that dl_v is set at
// s(d-1) and the access starts at s(d) if the SRAM is free and no cartridge
// or Flicker Blend access is waiting. +inject=D places it at s(D) of every
// cycle (2 <= D <= 47); +inject=sweep moves it one edge further each time,
// over all 48 edges of the cycle. The CARTRAM inject lines give, per phase
// of the injected access relative to the cycle's E0, the reads and their
// latest hand-over. With Fix B an access starting at s8 makes the
// cartridge read wait until s13, so its byte lands at s19, the limit of the
// c_rdata multicycle (DARIA_CORE.md, Fix B 2).
//
// Issued cartridge accesses are counted by sram_ctrl's request port with Fix
// B (SIM_FIXB: the 2600 port t_* or the 7800/BIOS port c_*, followed through
// its pending register cp), and by the image type before it (every cartridge
// access of a 2600 image), never by tia_en at issue time: a console reset
// clears tia_en on the edge where a 2600 strobe is registered, and Fix B
// issues that access after it (the CARTRAM ports line).
//
// The first CPU read of cart RAM after each release of the console reset
// (the wrapper's reset register) is also counted on its own (the CARTRAM
// post-reset line): another client's access can then still be in flight, so
// that read may land one bucket later than the build's normal one (s15 before
// Fix B, s19 with it); cartram2600_test.py allows that bucket for it alone.
//
// +rsmode=rd|wr|ar: console resets at a chosen edge of a cart-RAM cycle (Fix
// B's review finding; docs/daria_step7/plan.md P2). Reset i rises K clk_sys
// after E1 of a 6507 cycle that the mapper decodes as cart RAM (rd: a RAM
// read; wr: a RAM write; ar: a Supercharger RAM write, predicted at E0),
// K = +rsk0 (default 0), or (+rsk0 + i) mod 24 with +rssweep, so every
// clk_sys of the cycle and the next. +rssrc=rst raises reset_in for 200 us
// (the Pocket's Reset; a PLL retune enters the same reset register),
// +rssrc=load loads the same image again through the bridge (cart_download).
// +rsn=N resets (24), from +rsstart=MS (20). Per reset a line "RST i K=k:
// ..." gives the strobe the mapper showed at E1, whether sram_ctrl issued
// that access (and at which clk_sdram edge from E0, with the byte for a
// write), the cart-RAM accesses issued from E0 for 48 clk_sys, the BIOS-region
// reads, the bus just before E6 and the P2 coincidences; then "RST summary".
// With RAM at A15 = 1 ($Fxxx, cartram2600_test.py's hi_ images) the reset
// register's rise at E1 clears tia_en and bios_en_b on the edge where t_*_q
// registers the strobe: the one place a 7800/BIOS request and a 2600 request
// meet, where m_new must yield (the nohold mutant drops the 2600 access).
// The P2 assertion (tb_load, SIM_FIXB) stops such a run; tb_load's +p2count
// counts the coincidences instead (for a tree that has the fault).
//
// +midswap=MS (SIM_FIXB): the first 2600 read strobe after MS ms that is
// registered (t_rd_q) and still held gets its address forced to another
// byte (t_addr ^ 4) for two clk_sys; sram_ctrl must issue an access for the
// new key (its address compare; the nocmp mutant does not). "MIDSWAP
// verdict:" and the run ends.
//
// +forcecoinc=c_rd|m_new (SIM_FIXB): from 10 ms, on every 64th clk_sdram cycle
// in 2600 mode where t_new is high (at most 200 times), c_rd: sram_ctrl's 7800
// strobe input is forced high for that cycle, a 7800 request beside the 2600
// one: m_new must yield (P2 holds by construction, the 2600 access is served;
// the nohold mutant fires the P2 assertion); m_new: the m_new net itself is
// forced high in that cycle, so the P2 assertion must fire on any build (it
// is live). "FORCECOINC" lines.
//
// The taps (sram_ctrl's take, go_cl, go_we, go_word, go_lane, go_data,
// done_v, done_cl, dl_wr, m_new, t_new, cp_v, c_rd, t_rd_q, t_addr, t_addr_q;
// top.sv's cartram_*26, pclk0/pclk1, tia_en, cs_cart, RW, DB; cart2600's
// is_bad_game, sel_*, cartram_data, mapper_AR) are read-only, except the
// forces of +inject, +midswap and +forcecoinc and the resets and loads of
// +rsmode.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_cartram;
	tb_load tb ();

	localparam real TSD = 17.46;   // clk_sdram period
	`define CR_M tb.dut.main
	`define CR_C tb.dut.main.cart2600
	`define CR_S tb.dut.sram

	bit  on = 1'b0;
	initial on = $test$plusargs("cartram");

	real t_e0 = 0, t_done = -1e9;
	int  rd_n = 0, rd_bad = 0, rd_stale = 0, rd_late_sdc = 0;
	int  lat_hist [0:40];
	int  lat_min = 99, lat_max = -1, mar_min = 99;
	int  p1p2_min = 99, p1p2_max = -1;
	int  wr_strobes = 0, wr_issued = 0, rd_issued = 0, fb_issued = 0, other_issued = 0;
	int  mid_changes = 0, wr_data_changes = 0, rise_min = 99, rise_max = -1;
	int  shown = 0;
	byte shadow [int];
	logic s_on_q = 0, s_wr_q = 0; logic [17:0] s_a_q = 0; logic [7:0] s_d_q = 0;
	int  sys_since_e0 = 0;

	initial for (int i = 0; i <= 40; i++) lat_hist[i] = 0;

	initial if (on)
`ifdef SIM_FIXB
		$display("CARTRAM sram_ctrl: Fix B (the 2600 request registered on clk_sys, t_new)");
`else
		$display("CARTRAM sram_ctrl: the merged request (before Fix B)");
`endif

	// clk_sdram side: accesses started and read results handed over. A
	// cartridge access issued is counted by its request port with Fix B (the
	// port of the request in force, cq: m_new the 7800/BIOS port, t_new the
	// 2600 port, else the pending cp, whose port is followed as sram_ctrl loads
	// it), and before Fix B by the image type: every cartridge access of a
	// 2600 image is the 2600 port's.
	int  rd_m = 0, wr_m = 0;         // the 7800/BIOS port's cart RAM accesses (word below $10000)
	int  bios_m = 0;                 // accesses in the BIOS region (word $10000 and up), either port
	bit  cp_t = 1'b0;                // the pending access cp came from the 2600 port
	always @(posedge tb.clk_sdram) if (on) begin
		automatic bit from_t;
`ifdef SIM_FIXB
		from_t = `CR_S.m_new ? 1'b0 : `CR_S.t_new ? 1'b1 : cp_t;
		if (`CR_S.take && `CR_S.go_cl == 3'd0) cp_t <= 1'b0;
		else if (`CR_S.m_new || `CR_S.t_new) cp_t <= !`CR_S.m_new;
`else
		from_t = tb.dut.tia_mode;
`endif
		if (`CR_S.take) begin
			if (`CR_S.go_cl == 3'd0) begin
				if (`CR_S.go_word >= 17'h10000) bios_m++;	// the BIOS region (no 2600 access is there)
				else if (from_t) begin if (`CR_S.go_we) wr_issued++; else rd_issued++; end
				else begin if (`CR_S.go_we) wr_m++; else rd_m++; end
			end else if (`CR_S.go_cl == 3'd1) fb_issued++;
			else other_issued++;
		end
		if (`CR_S.done_v && `CR_S.done_cl == 3'd0) t_done = $realtime;
	end

	// The first CPU read of cart RAM after each release of the console reset
	// (the wrapper's reset register): counted on its own, with its bucket.
	bit  pr_armed = 1'b1;            // power-up counts as a release
	logic con_rst_q = 1'b1;
	int  pr_n = 0;
	int  pr_hist [0:40];
	initial for (int i = 0; i <= 40; i++) pr_hist[i] = 0;
	always @(posedge tb.clk_sys) begin
		if (con_rst_q && !tb.dut.reset) pr_armed = 1'b1;
		con_rst_q = tb.dut.reset;
	end

	wire tia = `CR_M.tia_en;
	wire cpu_reads_ram = tia && `CR_M.RW && `CR_M.cs_cart && !`CR_C.is_bad_game &&
		`CR_C.sel_ram_sel && `CR_C.sel_ram_rw && |`CR_C.sel_out_en &&
		!`CR_C.sel_flags_out[0] && !`CR_C.sel_flags_out[1];

	// ---- +inject: phase of the latest injected access, per read
	int  inj_mode = -1;            // -1 off, 0..47 fixed, 48 sweep
	int  inj_d = 2, inj_n = 0;
	real t_inj = -1e9, inj_target = -1e9, inj_last_target = -1e9;
	bit  inj_set = 1'b0;
	int  ph_reads [0:47], ph_max [0:47], ph_min [0:47];
	initial begin
		string m;
		for (int i = 0; i < 48; i++) begin ph_reads[i] = 0; ph_max[i] = -1; ph_min[i] = 99; end
		if ($value$plusargs("inject=%s", m)) begin
			if (m == "sweep") begin inj_mode = 48; inj_d = 0; end
			else begin
				inj_mode = m.atoi();
				inj_d = inj_mode;
				if (inj_mode < 2 || inj_mode > 47) $fatal(1, "+inject=%s: sweep, or 2..47", m);
			end
		end
	end
	// Between edges (on the falling edge of clk_sdram) so nothing races E0:
	// k is the clk_sdram rising edge just past, counted from E0.
	always @(negedge tb.clk_sdram) if (on && inj_mode >= 0 && tia) begin
		automatic int k = $rtoi(($realtime - t_e0) / TSD);
		automatic int set_k = (inj_d + 46) % 48;          // s(d-2)
		automatic real target = inj_d >= 2 ? t_e0 : t_e0 + 48 * TSD;
		if (inj_set) begin
			release `CR_S.dl_wr;
			inj_set = 1'b0;
			t_inj = $realtime + TSD / 2;                   // the access may start at the next edge
			inj_last_target = inj_target;
			inj_n++;
			if (inj_mode == 48) inj_d = (inj_d + 1) % 48;
		end else if (k == set_k && target > inj_last_target + TSD) begin
			force `CR_S.dl_wr = 1'b1;
			inj_set = 1'b1;
			inj_target = target;
		end
	end

	always @(posedge tb.clk_sys) if (on) begin
		automatic logic s_on = tia && (`CR_M.cartram_rd26 || `CR_M.cartram_wr26);
		sys_since_e0 = sys_since_e0 + 1;
		if (`CR_M.pclk1) begin t_e0 = $realtime; sys_since_e0 = 0; end
		// The CPU's latch edge
		if (`CR_M.pclk0 && tia) begin
			automatic int p = $rtoi(($realtime - t_e0) / 69.84 + 0.5);
			if (p < p1p2_min) p1p2_min = p; if (p > p1p2_max) p1p2_max = p;
		end
		if (`CR_M.pclk0 && cpu_reads_ram) begin
			automatic logic [17:0] a = `CR_M.cartram_addr26;
			automatic logic [15:0] w = tb.sram_chip.mem[a[16:1]];
			automatic logic [7:0] exp = a[0] ? w[15:8] : w[7:0];
			automatic logic [7:0] got = `CR_C.cartram_data;
			automatic int lat = $rtoi((t_done - t_e0) / TSD + 0.5);
			automatic int mar = $rtoi(($realtime - t_done) / TSD + 0.5);
			rd_n++;
			if (t_done < t_e0) begin
				rd_stale++;
				if (shown < 10) begin shown++;
					$display("CARTRAM %0d us: read $%05x latched with no access since E0", int'($realtime / 1000), a); end
			end else begin
				if (lat < lat_min) lat_min = lat; if (lat > lat_max) lat_max = lat;
				if (mar < mar_min) mar_min = mar;
				if (lat >= 0 && lat <= 40) lat_hist[lat]++;
				if (lat > 19) rd_late_sdc++;
				if (pr_armed) begin
					pr_n++;
					if (lat >= 0 && lat <= 40) pr_hist[lat]++;
				end
				if (inj_mode >= 0 && t_inj >= t_e0) begin
					automatic int d = $rtoi((t_inj - t_e0) / TSD + 0.5);
					if (d >= 0 && d < 48) begin
						ph_reads[d]++;
						if (lat > ph_max[d]) ph_max[d] = lat;
						if (lat < ph_min[d]) ph_min[d] = lat;
					end
				end
			end
			pr_armed = 1'b0;
			if (got !== exp) begin
				rd_bad++;
				if (shown < 10) begin shown++;
					$display("CARTRAM %0d us: read $%05x got %02x, SRAM holds %02x", int'($realtime / 1000), a, got, exp); end
			end
		end
		// The mapper-side strobe
		if (s_on && !s_on_q) begin
			if (sys_since_e0 < rise_min) rise_min = sys_since_e0;
			if (sys_since_e0 > rise_max) rise_max = sys_since_e0;
		end
		if (s_on && s_on_q && (`CR_M.cartram_addr26 != s_a_q || `CR_M.cartram_wr26 != s_wr_q)) mid_changes++;
		if (tia && `CR_M.cartram_wr26) begin
			if (!(s_on_q && s_wr_q && `CR_M.cartram_addr26 == s_a_q)) begin
				wr_strobes++;
				shadow[int'(`CR_M.cartram_addr26)] = `CR_M.cartram_wrdata26;
			end else if (`CR_M.cartram_wrdata26 != s_d_q) wr_data_changes++;
		end
		s_on_q <= s_on; s_wr_q <= `CR_M.cartram_wr26; s_a_q <= `CR_M.cartram_addr26; s_d_q <= `CR_M.cartram_wrdata26;
	end

	// ---- +rsmode: console resets at a chosen edge of a cart-RAM cycle (see the header) -----
	`define CR_AR tb.dut.main.cart2600.mapper_AR
	wire rs_ar_wr_next = `CR_AR.a_in[12] && `CR_AR.ram_we && `CR_AR.we_cycle[4] && !`CR_AR.rom_bank && `CR_AR.a_in != 13'h1FF8;
	string rs_mode = "", rs_src = "rst", rs_cart = "";
	int  rs_n = 24, rs_start = 20, rs_k0 = 0, rs_bios = 0, rs_done = 0, rs_coinc_win = 0;
	int  rs_iss_n = 0, rs_lost_n = 0, rs_none = 0, rs_bad_d = 0, rs_max_rd = -1, rs_max_wr = -1, rs_resets_coinc = 0;
	bit  rs_sweep = 0, rs_win = 0, rs_got = 0, rs_on = 0, rs_wr = 0;
	real rs_e0 = 0, rs_t_iss = 0;
	logic [17:0] rs_a = 0;
	logic [7:0] rs_d = 0, rs_got_d = 0, rs_e6 = 0;
	logic [7:0] rs_img [$];

	always @(posedge tb.clk_sdram) if (rs_win && `CR_S.take && `CR_S.go_cl == 3'd0) begin
		automatic logic [7:0] b = `CR_S.go_data[7:0];
		if (`CR_S.go_word < 17'h10000) begin
			rs_cart = {rs_cart, $sformatf(" %s%05x", `CR_S.go_we ? "w" : "r", {`CR_S.go_word, `CR_S.go_lane})};
			if (`CR_S.go_we) rs_cart = {rs_cart, $sformatf("=%02x", b)};
			if (rs_on && !rs_got && `CR_S.go_word == {1'b0, rs_a[16:1]} && `CR_S.go_lane == rs_a[0] && `CR_S.go_we == rs_wr) begin
				rs_got = 1; rs_t_iss = $realtime; rs_got_d = b;
			end
		end else rs_bios++;
	end
`ifdef SIM_FIXB
	// The P2 coincidences inside a reset's window: tb_load's assertion stops the
	// run on the first, unless +p2count (tb_load) counts them instead.
	always @(posedge tb.clk_sdram) if (rs_win && `CR_S.m_new && `CR_S.t_new) rs_coinc_win++;
`endif

	initial if ($value$plusargs("rsmode=%s", rs_mode)) begin
		string img_path;
		if (rs_mode != "rd" && rs_mode != "wr" && rs_mode != "ar") $fatal(1, "+rsmode=%s: rd, wr or ar", rs_mode);
		void'($value$plusargs("rssrc=%s", rs_src));
		if (rs_src != "rst" && rs_src != "load") $fatal(1, "+rssrc=%s: rst or load", rs_src);
		void'($value$plusargs("rsn=%d", rs_n));
		void'($value$plusargs("rsstart=%d", rs_start));
		void'($value$plusargs("rsk0=%d", rs_k0));
		rs_sweep = $test$plusargs("rssweep");
		if (rs_src == "load") begin
			int f, c;
			void'($value$plusargs("image=%s", img_path));
			f = $fopen(img_path, "rb");
			if (f == 0) $fatal(1, "+rssrc=load: cannot open %s", img_path);
			while ((c = $fgetc(f)) != -1) rs_img.push_back(c[7:0]);
			$fclose(f);
			while (rs_img.size() % 4) rs_img.push_back(8'hFF);
		end
		$display("RST armed: %0d resets from %0d ms, mode %s, source %s, K %s%0d", rs_n, rs_start, rs_mode, rs_src,
			rs_sweep ? "swept from " : "fixed at ", rs_k0);
		repeat (longint'(14318) * rs_start) @(posedge tb.clk_sys);
		for (int i = 0; i < rs_n; i++) begin
			automatic int k = rs_sweep ? (rs_k0 + i) % 24 : rs_k0;
			// E0 of a cycle of the chosen kind
			forever begin
				do @(posedge tb.clk_sys); while (!`CR_M.pclk1);
				#1 if (`CR_M.tia_en && `CR_M.RW && (rs_mode == "ar" ? rs_ar_wr_next :
					`CR_C.sel_ram_sel && (rs_mode == "wr" ? !`CR_C.sel_ram_rw : `CR_C.sel_ram_rw))) break;
			end
			rs_e0 = $realtime - 1.0;
			rs_cart = ""; rs_bios = 0; rs_got = 0; rs_on = 0; rs_coinc_win = 0; rs_win = 1;
			fork
				begin   // E1: the mapper's strobe
					@(posedge tb.clk_sys); #1;
					rs_a = `CR_M.cartram_addr26; rs_wr = `CR_M.cartram_wr26; rs_d = `CR_M.cartram_wrdata26;
					rs_on = `CR_M.tia_en && (`CR_M.cartram_rd26 || `CR_M.cartram_wr26);
				end
				begin   // just before E6
					repeat (5) @(posedge tb.clk_sys); #(4 * TSD - 1.0);
					rs_e6 = `CR_M.DB;
				end
			join_none
			repeat (k) @(posedge tb.clk_sys);
			#1 if (rs_src == "load") tb.cart_download = 1'b1; else tb.reset_in = 1'b1;
			repeat (48 - k) @(posedge tb.clk_sys);
			rs_win = 0;
			begin
				automatic int lat = rs_got ? $rtoi((rs_t_iss - rs_e0) / TSD + 0.5) : -1;
				if (!rs_on) rs_none++;
				else if (rs_got) begin
					rs_iss_n++;
					if (rs_wr && lat > rs_max_wr) rs_max_wr = lat;
					if (!rs_wr && lat > rs_max_rd) rs_max_rd = lat;
					if (rs_wr && rs_got_d != rs_d) rs_bad_d++;
				end else rs_lost_n++;
				if (rs_coinc_win) rs_resets_coinc++;
				$display("RST %0d K=%0d: strobe %s; %s; cart%s; bios reads %0d; bus before E6 %02x; P2 coincidences %0d",
					i, k,
					!rs_on ? "none" : rs_wr ? $sformatf("write $%05x data %02x", rs_a, rs_d) : $sformatf("read $%05x", rs_a),
					!rs_on ? "-" : !rs_got ? "NOT issued" : rs_wr ? $sformatf("issued at s%0d data %02x", lat, rs_got_d)
						: $sformatf("issued at s%0d", lat),
					rs_cart == "" ? " none" : rs_cart, rs_bios, rs_e6, rs_coinc_win);
			end
			if (rs_src == "load") begin
				// tb_load's own load: one 32-bit bridge write every 80 clk_74a
				tb.run74 = 1'b1;
				repeat (100) @(posedge tb.clk_74a);
				for (int j = 0; j < rs_img.size(); j += 4) begin
					@(posedge tb.clk_74a);
					tb.bridge_addr = j;
					tb.bridge_wr_data = {rs_img[j], rs_img[j+1], rs_img[j+2], rs_img[j+3]};
					tb.bridge_wr = 1'b1;
					@(posedge tb.clk_74a);
					tb.bridge_wr = 1'b0;
					repeat (78) @(posedge tb.clk_74a);
				end
				repeat (2000) @(posedge tb.clk_74a);
				tb.cart_download = 1'b0;
			end else begin
				repeat (14318 / 5) @(posedge tb.clk_sys);
				tb.reset_in = 1'b0;
			end
			rs_done++;
			repeat (longint'(14318) * 3) @(posedge tb.clk_sys);
		end
		$display("RST summary: %0d of %0d resets, mode %s, source %s, K %s%0d: triggering access issued %0d, NOT issued %0d, no strobe at E1 %0d, written byte wrong %0d; latest issue edge from E0: read s%0d, write s%0d; resets with a P2 coincidence %0d",
			rs_done, rs_n, rs_mode, rs_src, rs_sweep ? "swept from " : "fixed at ", rs_k0, rs_iss_n, rs_lost_n, rs_none, rs_bad_d,
			rs_max_rd, rs_max_wr, rs_resets_coinc);
		$finish;
	end
	final if (rs_mode != "" && rs_done < rs_n)
		$display("RST INCOMPLETE: %0d of %0d resets done when the run ended", rs_done, rs_n);

`ifdef SIM_FIXB
	// ---- +midswap=MS: an address change inside a held, registered 2600 read strobe ----------
	int ms_at = -1, ms_armed = 0, ms_done = 0, ms_new_acc = 0, ms_old_acc = 0;
	logic [16:0] ms_a_old, ms_a_new;
	initial if ($value$plusargs("midswap=%d", ms_at)) begin
		repeat (longint'(14318) * ms_at) @(posedge tb.clk_sys);
		// a held, registered read strobe whose next clk_sys keeps it held
		do @(posedge tb.clk_sys); while (!(`CR_S.t_rd_q && `CR_S.t_rd && `CR_S.t_addr == `CR_S.t_addr_q));
		ms_a_old = `CR_S.t_addr;
		ms_a_new = `CR_S.t_addr ^ 17'h4;
		force `CR_S.t_addr = ms_a_new;
		ms_armed = 1;
		repeat (2) @(posedge tb.clk_sys);
		release `CR_S.t_addr;
		repeat (2) @(posedge tb.clk_sys);
		ms_done = 1;
		$display("MIDSWAP at %0.3f us: address $%05x -> $%05x inside a held read strobe; cart accesses for the new key %0d, for the old key %0d",
			$realtime / 1000.0, ms_a_old, ms_a_new, ms_new_acc, ms_old_acc);
		$display("MIDSWAP verdict: %s", ms_new_acc > 0 ? "new key served (compare present)" : "new key NOT served (no compare)");
		$finish;
	end
	always @(posedge tb.clk_sdram) if (ms_armed && !ms_done && `CR_S.take && `CR_S.go_cl == 3'd0 && !`CR_S.go_we) begin
		if (`CR_S.go_word == {1'b0, ms_a_new[16:1]} && `CR_S.go_lane == ms_a_new[0]) ms_new_acc++;
		if (`CR_S.go_word == {1'b0, ms_a_old[16:1]} && `CR_S.go_lane == ms_a_old[0]) ms_old_acc++;
	end

	// ---- +forcecoinc=c_rd|m_new: a 7800 request in the cycle of a new 2600 one ---------------
	string fc_mode = "";
	int  fc_n = 0, fc_seen = 0, fc_m_new = 0, fc_m_new_2600 = 0;
	bit  fc_held = 1'b0;
	initial if ($value$plusargs("forcecoinc=%s", fc_mode))
		if (fc_mode != "c_rd" && fc_mode != "m_new") $fatal(1, "+forcecoinc=%s: c_rd or m_new", fc_mode);
	// set on the falling edge before the rising edge at which t_new is high, released on the next
	always @(negedge tb.clk_sdram) if (fc_mode != "") begin
		if (fc_held) begin
			if (fc_mode == "c_rd") release `CR_S.c_rd; else release `CR_S.m_new;
			fc_held = 1'b0;
		end else if (tia && `CR_S.t_new && !`CR_S.c_rd && !`CR_S.c_rd_q && $realtime > 10e6 && fc_n < 200) begin
			fc_seen++;
			if (fc_seen % 64 == 1) begin
				if (fc_mode == "c_rd") force `CR_S.c_rd = 1'b1; else force `CR_S.m_new = 1'b1;
				fc_held = 1'b1;
				fc_n++;
				if (fc_n <= 3) $display("FORCECOINC %0d at %0.3f us: %s forced for the clk_sdram cycle where t_new is high", fc_n,
					$realtime / 1000.0, fc_mode);
			end
		end
	end
	always @(posedge tb.clk_sdram) if (fc_mode != "" && `CR_S.m_new) begin
		fc_m_new++;
		if (tia) fc_m_new_2600++;
	end
	final if (fc_mode != "")
		$display("FORCECOINC: %0d forced (%s) in 2600 mode; m_new %0d (in 2600 mode %0d)", fc_n, fc_mode, fc_m_new, fc_m_new_2600);
`endif

	final if (on) begin
		automatic int sh_bad = 0, sh_n = 0;
		foreach (shadow[k]) begin
			automatic logic [15:0] w = tb.sram_chip.mem[k[16:1]];
			sh_n++;
			if ((k[0] ? w[15:8] : w[7:0]) !== shadow[k]) begin
				sh_bad++;
				if (sh_bad <= 5) $display("CARTRAM shadow $%05x: wrote %02x, SRAM holds %02x", k, shadow[k], k[0] ? w[15:8] : w[7:0]);
			end
		end
		$display("CARTRAM phases: pclk1->pclk0 %0d..%0d clk_sys; strobe rises %0d..%0d clk_sys after E0",
			p1p2_min, p1p2_max, rise_min, rise_max);
		$display("CARTRAM reads: %0d CPU reads of cart RAM, %0d wrong byte, %0d without a fresh access, c_rdata at E0+%0d..%0d clk_sdram, min margin to the latch %0d clk_sdram, %0d past E0+19 (SDC window)",
			rd_n, rd_bad, rd_stale, lat_min, lat_max, mar_min, rd_late_sdc);
		$write("CARTRAM latency histogram (clk_sdram from E0: count):");
		for (int i = 0; i <= 40; i++) if (lat_hist[i]) $write(" %0d:%0d", i, lat_hist[i]);
		$display("");
		$display("CARTRAM writes: %0d strobes at the mappers, %0d cart writes issued, %0d bytes in the shadow, %0d differ from the SRAM; %0d data changes inside a strobe",
			wr_strobes, wr_issued, sh_n, sh_bad, wr_data_changes);
		$display("CARTRAM traffic: cart reads issued %0d, Flicker Blend %0d, other %0d; address or direction changes inside a held strobe %0d",
			rd_issued, fb_issued, other_issued, mid_changes);
`ifdef SIM_FIXB
		$display("CARTRAM ports: the 2600 port's accesses issued: reads %0d, writes %0d; the 7800/BIOS port's: reads %0d, writes %0d of cart RAM; %0d in the BIOS region (by request port)",
			rd_issued, wr_issued, rd_m, wr_m, bios_m);
`else
		$display("CARTRAM ports: the 2600 image's accesses issued: reads %0d, writes %0d; others: reads %0d, writes %0d of cart RAM; %0d in the BIOS region (by image type: no request ports before Fix B)",
			rd_issued, wr_issued, rd_m, wr_m, bios_m);
`endif
		$write("CARTRAM post-reset reads: %0d (the first CPU read of cart RAM after each console reset release), histogram:", pr_n);
		for (int i = 0; i <= 40; i++) if (pr_hist[i]) $write(" %0d:%0d", i, pr_hist[i]);
		$display("");
		if (inj_mode >= 0) begin
			automatic int wmax = -1, wd = -1;
			$display("CARTRAM inject: %0d accesses placed (%0s)", inj_n, inj_mode == 48 ? "sweep over s0..s47" : $sformatf("at s%0d", inj_mode));
			for (int d = 0; d < 48; d++) if (ph_reads[d]) begin
				$display("CARTRAM inject phase s%0d: %0d reads, c_rdata at E0+%0d..%0d", d, ph_reads[d], ph_min[d], ph_max[d]);
				if (ph_max[d] > wmax) begin wmax = ph_max[d]; wd = d; end
			end
			$display("CARTRAM inject worst: c_rdata at E0+%0d with the access at s%0d", wmax, wd);
		end
	end
endmodule
