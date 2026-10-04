//------------------------------------------------------------------------------
// Stress of the download path of step 4 (docs/BUPCHIP_CORE.md, "Firmware
// load", "Capture"): bup_capture on clk_sys, the message register and toggle
// across to clk_arm, bup_asset_wr, and psram.sv on psram_model.sv (or
// -DPSRAM_VAR: psram_var.sv). No CPU: a random stream of downloads, each
// checked once its messages have drained.
//
//   cartridge  a 128-byte A78 header declaring R bytes of ROM, the R bytes,
//              then an ARSC block of B bytes: B from 0 to 70,000, with every
//              small size, odd lengths and blocks ending on a 16-byte line
//              boundary; R = 0 (no block captured), odd R (the block starts on
//              an odd file offset), and headers that declare more ROM than
//              the file has (no block)
//   firmware   N bytes, 0 to 17,000 (bytes past 16 KiB are dropped)
//   loader     one byte per 2.5 clk_sys (data_loader.sv's 10 clk_sdram), or
//              that plus random extra, or slower; downloads back to back (the
//              next one's start in the clock after the end: a cartridge then
//              a cartridge, a firmware then either) or apart
//
// Clocks: clk_sys 14.318 MHz (+pal: x 0.99088); clk_arm 2 x clk_sys edge
// aligned (default), 1.5 x (+ratio=15), or asynchronous (+async: half period
// +arm_ps=PS, default 23,525 = 21.25 MHz, with a random start phase and
// +armjit=PS random extra per half period), which the design's toggles are
// meant to survive.
//
// A reader stands in for the asset cache: from two clk_arm clocks after
// asset_ready and fw_loaded are both high (when the cache would be running)
// until two clocks after either falls, it issues random halfword reads of
// [0, asset_size), the tail and the first halfword first, and checks each
// against the block that was published; a read in flight when it stops is
// dropped, as the cache does.
//
// After each download that is not followed straight away by another:
// asset_size = B (0 without a block), asset_ready = B >= 4, every block byte
// in the PSRAM, exactly ceil(B / 2) PSRAM writes; or for firmware fw_loaded =
// min(N, 16,384) >= 8, the ROM words (as ROM port B would take them: rom_we
// while fw_loaded is low) equal the file zero-padded, exactly
// ceil(min(N, 16,384) / 4) ROM writes. Always: seq_err, lost, the
// simulation-only byte order check and overrun stay 0.
//
// Every halfword or word that completes while the one before still waits
// to leave (what bup_capture flags as lost: the loader too fast) is counted
// as "same", and every message that leaves less than 5 clk_sys after the one
// before as "cross" (the receiver's spacing; bup_capture queues every
// message, so this must stay 0 whatever the downloads do).
//
//   +n=N downloads (default 300)  +seed=S  +maxblock=B (70,000)
//   +fast   one byte every 2 clk_sys: a halfword every 4 clocks, which must
//           raise lost (the check of the detector)
//   +b2bfw  a cartridge followed straight by the next download may be
//           followed by a firmware download (otherwise only by a cartridge):
//           its FWWRITEs can then leave too soon after the cartridge's END
//   +xstream  every such pair is a cartridge then a firmware download whose
//           first byte comes as early as the loader allows: the case directed
//   +fwrise half the firmware downloads present their first byte in the
//           clock fw_download rises
//   +fwfall half the firmware downloads present their last byte in the
//           clock fw_download falls (fw_valid high with fw_download low)
//   +samefw with +xstream: the firmware download's flag rises in the same
//           clock the cartridge's falls, as on the Pocket when
//           download_slot switches from 0x100 to 0x109 (core_top.v)
//   +overlapfw with +xstream: the firmware flag rises one clock before the
//           cartridge's falls (the two synchronisers resolving differently)
// The last line, "result: ...", is for run_capstress.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_capstress;
	// ---- clocks ---------------------------------------------------------------------------------------
	longint arm_half = 17460, u15 = 11640, sys_half_async = 34920, arm_ps = 23525, armjit = 0;
	int     ratio = 2;
	bit     async_ = 0, pal = 0;
	logic   clk_arm = 0, clk_sys = 0;
	initial begin
		void'($value$plusargs("ratio=%d", ratio));
		async_ = $test$plusargs("async");
		pal = $test$plusargs("pal");
		void'($value$plusargs("arm_ps=%d", arm_ps));
		void'($value$plusargs("armjit=%d", armjit));
		if (pal) begin arm_half = 17621; u15 = 11747; sys_half_async = 35242; end
		#1;
		if (async_) begin
			fork
				forever begin #(sys_half_async); clk_sys = ~clk_sys; end
				begin
					#($urandom_range(int'(2 * arm_ps)));
					forever begin
						#(arm_ps + (armjit > 0 ? $urandom_range(int'(armjit)) : 0));
						clk_arm = ~clk_arm;
					end
				end
			join_none
		end else if (ratio == 15) begin
			forever begin                      // as tb_s4.sv: rising edges together every 12 u15
				#(2 * u15); clk_arm = 1; clk_sys = 1;
				#(2 * u15); clk_arm = 0;
				#(u15);     clk_sys = 0;
				#(u15);     clk_arm = 1;
				#(2 * u15); clk_arm = 0; clk_sys = 1;
				#(2 * u15); clk_arm = 1;
				#(u15);     clk_sys = 0;
				#(u15);     clk_arm = 0;
			end
		end else begin
			forever begin
				#(arm_half); clk_arm = 1; clk_sys = 1;
				#(arm_half); clk_arm = 0;
				#(arm_half); clk_arm = 1;
				#(arm_half); clk_arm = 0; clk_sys = 0;
			end
		end
	end

	// ---- the path ------------------------------------------------------------------------------------
	logic        cart_dl = 0, cart_dl_q = 0, fw_dl = 0, ld_wr = 0;
	logic        fwv_extra = 0;	// +fwfall: fw_valid in the clock fw_download falls
	logic [24:0] ld_addr = 0;
	logic  [7:0] ld_data = 0;
	always @(posedge clk_sys) cart_dl_q <= cart_dl;

	wire  [2:0] msg_type;
	wire [43:0] msg_pl;
	wire        msg_tog, seq_err, lost;
	bup_capture cap (
		.clk(clk_sys),
		.load_start(cart_dl && !cart_dl_q), .load_addr(ld_addr), .load_valid(ld_wr && cart_dl),
		.load_data(ld_data), .load_end(!cart_dl && cart_dl_q),
		.fw_download(fw_dl), .fw_valid((ld_wr && fw_dl) || fwv_extra),
		.msg_type, .msg_pl, .msg_tog, .seq_err, .lost);

	wire        asset_ready, fw_loaded, rom_we, overrun;
	wire [23:0] asset_size;
	wire [11:0] rom_wa;
	wire [31:0] rom_wd;
	logic       rd_req = 0;
	logic [21:0] rd_addr = 0;
	wire        rd_ack;
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	bup_asset_wr wr (
		.clk(clk_arm), .msg_type, .msg_pl, .msg_tog,
		.asset_ready, .asset_size, .fw_loaded, .rom_we, .rom_wa, .rom_wd,
		.rd_req, .rd_addr, .rd_ack,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun);

`ifdef PSRAM_VAR
	psram_var ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy));
	function automatic logic [8:0] psram_byte(input int b);	// {written, byte}
		logic [15:0] h;
		h = ps.value(b >> 1);
		return {ps.wbe.exists(b >> 1) ? (b[0] ? ps.wbe[b >> 1][1] : ps.wbe[b >> 1][0]) : 1'b0, b[0] ? h[15:8] : h[7:0]};
	endfunction
`else
	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(28.636364)) ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	function automatic logic [8:0] psram_byte(input int b);
		logic [15:0] h;
		logic  [1:0] w;
		h = chip.bd_read(0, b >> 1);
		w = chip.bd_written(0, b >> 1);
		return {b[0] ? w[1] : w[0], b[0] ? h[15:8] : h[7:0]};
	endfunction
`endif

	// ---- what ROM port B and the PSRAM saw (clk_arm) ---------------------------------------------------
	logic [31:0] rom [0:4095];
	longint      n_romwr = 0, n_pwr = 0, n_rd = 0, rd_bad = 0, rd_drop = 0;
	initial for (int i = 0; i < 4096; i++) rom[i] = 32'hDEAD0000 | i;

	// the block published by the last END (the reader's reference)
	logic [7:0] pub [0:131071];
	int         pub_n = 0;
	logic       ready_q = 0;
	logic [2:0] run_d = 0;                      // asset_ready & fw_loaded, delayed: the cache's run
	logic       rd_fl = 0, rd_first = 0;
	int         rd_left = 0, rd_cnt = 0, rd_q_addr = 0, rd_seq = 0;
	logic [7:0] blk [0:131071];                 // the current cartridge's block
	int         blk_n = 0;
	// The last four cartridges' blocks, by download number: the END the
	// receiver handles belongs to the cartridge of the last START it handled,
	// which may be one download behind the loader.
	logic [7:0] ring [0:3][0:131071];
	int         ring_n [0:3];
	int         n_start = 0, n_cart_started = 0;

	always @(posedge clk_arm) begin
		if (rom_we && !fw_loaded) begin
			rom[rom_wa] = rom_wd;
			n_romwr++;
		end
		if (p_we) n_pwr++;
		// the block is published when asset_ready rises (END handled)
		if (wr.done && wr.m_type == 3'd1) n_start++;
		if (asset_ready && !ready_q) begin
			int r;
			r = (n_start - 1) % 4;
			pub_n = int'(asset_size) < ring_n[r] ? int'(asset_size) : ring_n[r];
			if (int'(asset_size) != ring_n[r]) begin
				$display("%0t: END of download %0d published %0d bytes, its block has %0d", $time, n_start, asset_size, ring_n[r]);
				rd_bad++;
			end
			for (int i = 0; i < pub_n; i++) pub[i] = ring[r][i];
			rd_seq = 0;
		end
		ready_q = asset_ready;
		run_d <= {run_d[1:0], asset_ready && fw_loaded};
		// the reader
		if (rd_fl && p_avail) begin
			rd_fl = 0;
			if (run_d[2]) begin
				logic [15:0] e;
				e[7:0] = 2 * rd_q_addr < pub_n ? pub[2 * rd_q_addr] : 8'hxx;
				e[15:8] = 2 * rd_q_addr + 1 < pub_n ? pub[2 * rd_q_addr + 1] : 8'hxx;
				n_rd++;
				if (p_dout[7:0] !== e[7:0] || (2 * rd_q_addr + 1 < pub_n && p_dout[15:8] !== e[15:8])) begin
					if (rd_bad < 5) $display("%0t: read of halfword %0d gave %04x, published %04x", $time, rd_q_addr, p_dout, e);
					rd_bad++;
				end
			end else rd_drop++;
		end
		if (rd_ack) begin
			rd_fl = 1;
			rd_q_addr = int'(rd_addr);
			rd_req <= 0;
		end else if (!rd_fl && run_d[2] && pub_n >= 4 && $urandom_range(3) == 0) begin
			int h;
			h = rd_seq == 0 ? (pub_n - 1) / 2 : rd_seq == 1 ? 0 : $urandom_range((pub_n - 1) / 2);
			rd_seq++;
			rd_req <= 1;
			rd_addr <= 22'(h);
		end
		if (!run_d[2] && !rd_ack) rd_req <= 0;
	end

	// A halfword or word completing while the one before still waits (bup_
	// capture's lost), and a message leaving less than 5 clk_sys after the
	// last (the toggle seen changing too soon).
	logic tog_q = 0;
	int   since = 100;
	always @(posedge clk_sys) begin
		if ((cap.a_pair && cap.p_write && !cap.send_write) ||
		    (cap.f_word && cap.p_fwword && !cap.send_fwword && !cap.fw_rise)) begin
			n_lost_s++;
			if (n_lostmsg < 5)
				$display("%0t: a %0s completed while the last still waited", $time, cap.a_pair ? "halfword" : "word");
			n_lostmsg++;
		end
		tog_q <= cap.msg_tog;
		since <= cap.msg_tog != tog_q ? 1 : since + 1;
		if (cap.msg_tog != tog_q && since < 5) begin
			n_lost_x++;
			if (n_lostmsg < 5)
				$display("%0t: message type %0d only %0d clk_sys after the last", $time, cap.msg_type, since);
			n_lostmsg++;
		end
	end
	longint n_lost_x = 0, n_lost_s = 0;
	int n_lostmsg = 0;

	// ---- the loader (clk_sys) ------------------------------------------------------------------------
	logic [7:0] img [0:200000];
	int         img_n = 0;
	logic [7:0] fwf [0:20000];
	int         fw_n = 0;
	real        bp, jit;                         // ps per byte, random extra
	bit         fast = 0;

	function automatic longint sys_per();
		return async_ ? 2 * sys_half_async : ratio == 15 ? 6 * u15 : 4 * arm_half;
	endfunction

	task automatic loader_send(input bit fw, input int n, input int k0 = 0);
		real t, p;
		@(posedge clk_sys);
		t = $realtime;
		for (int k = k0; k < n; k++) begin
			t += bp + (jit > 0.0 ? real'($urandom_range(1000)) * jit / 1000.0 : 0.0);
			p = real'(sys_per());
			while ($realtime < t - p) @(posedge clk_sys);
			ld_wr <= 1;
			ld_addr <= 25'(k);
			ld_data <= fw ? fwf[k] : img[k];
			@(posedge clk_sys);
			ld_wr <= 0;
		end
	endtask

	// ---- the downloads ---------------------------------------------------------------------------------
	int     ndl = 300, maxblock = 70000, seed = 1;
	bit     b2bfw = 0, prev_b2b = 0, prev_fw = 0, xstream = 0, fwrise = 0, fwfall = 0, samefw = 0, overlapfw = 0;
	longint n_fwrise = 0, n_fwfall = 0;
	longint n_checks = 0, n_bad = 0, n_cart = 0, n_fw = 0, n_b2b = 0, n_noblock = 0;
	longint pwr0 = 0, romwr0 = 0;

	function automatic int pick_block();
		int r;
		r = $urandom_range(99);
		if (r < 30) return $urandom_range(49);
		if (r < 45) return 16 * $urandom_range(1, 64) + $urandom_range(2) - 1;  // around a line boundary
		if (r < 85) return $urandom_range(3000);
		return $urandom_range(maxblock);
	endfunction

	// Both the cartridge's and the firmware's state, against the latest of
	// each; the write counts against the downloads since the last check (a
	// cartridge followed straight by the next may lose its tail WRITE with its
	// END: the next START withdraws it anyway).
	longint pw_min = 0, pw_max = 0, rw_min = 0, rw_max = 0;
	task automatic check();
		int bad, b, m;
		bad = 0;
		n_checks++;
		b = blk_n;
		if (int'(asset_size) != b || asset_ready != (b >= 4)) begin
			$display("check %0d: asset_size %0d asset_ready %0d, expected %0d %0d", n_checks, asset_size, asset_ready, b, b >= 4);
			bad++;
		end
		for (int i = 0; i < b; i++) begin
			logic [8:0] v;
			v = psram_byte(i);
			if (!v[8] || v[7:0] !== blk[i]) begin
				if (bad < 5) $display("check %0d: PSRAM byte %0d %s%02x, block %02x", n_checks, i, v[8] ? "" : "unwritten ", v[7:0], blk[i]);
				bad++;
			end
		end
		if (n_pwr - pwr0 < pw_min || n_pwr - pwr0 > pw_max) begin
			$display("check %0d: %0d PSRAM writes, expected %0d..%0d", n_checks, n_pwr - pwr0, pw_min, pw_max);
			bad++;
		end
		m = fw_n > 16384 ? 16384 : fw_n;
		if (fw_seen && fw_loaded != (m >= 8)) begin
			$display("check %0d: fw_loaded %0d for %0d bytes", n_checks, fw_loaded, fw_n);
			bad++;
		end
		for (int w = 0; w < (m + 3) / 4; w++) begin
			logic [31:0] e;
			e = 0;
			for (int k = 0; k < 4; k++) if (4 * w + k < m) e[8 * k +: 8] = fwf[4 * w + k];
			if (rom[w] !== e) begin
				if (bad < 5) $display("check %0d: ROM word %0d %08x, file %08x", n_checks, w, rom[w], e);
				bad++;
			end
		end
		if (n_romwr - romwr0 < rw_min || n_romwr - romwr0 > rw_max) begin
			$display("check %0d: %0d ROM writes, expected %0d..%0d", n_checks, n_romwr - romwr0, rw_min, rw_max);
			bad++;
		end
		pwr0 = n_pwr; romwr0 = n_romwr; pw_min = 0; pw_max = 0; rw_min = 0; rw_max = 0;
		if (bad) n_bad++;
	endtask
	bit fw_seen = 0;

	initial begin
		void'($value$plusargs("n=%d", ndl));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("maxblock=%d", maxblock));
		fast = $test$plusargs("fast");
		b2bfw = $test$plusargs("b2bfw");
		xstream = $test$plusargs("xstream");
		fwrise = $test$plusargs("fwrise");
		fwfall = $test$plusargs("fwfall");
		samefw = $test$plusargs("samefw");
		overlapfw = $test$plusargs("overlapfw");
		if (xstream) b2bfw = 1;
		void'($urandom(seed));
		repeat (20) @(posedge clk_sys);
		for (int k = 0; k < ndl; k++) begin
			bit fw, b2b;
			int r, R, Rdecl, B, n, mode, gap;
			fw = $urandom_range(99) < 30;
			if (prev_b2b && !prev_fw && !b2bfw) fw = 0;   // a cartridge then firmware: +b2bfw only
			if (prev_b2b && !prev_fw && xstream) fw = 1;
			// another download straight after (a firmware download only outside +xstream)
			b2b = $urandom_range(99) < (!fw && xstream ? 60 : 15) && !(fw && xstream);
			// loader speed
			mode = $urandom_range(9);
			bp = 2.5 * real'(sys_per());
			jit = 0.0;
			if (mode >= 6 && mode < 9) jit = real'($urandom_range(80)) * 1000.0;
			if (mode == 9) bp = real'($urandom_range(3, 20)) * real'(sys_per());
			if (fast) begin bp = 2.0 * real'(sys_per()); jit = 0.0; end
			if (fw) begin
				r = $urandom_range(99);
				n = r < 20 ? $urandom_range(12) : r < 30 ? 16384 + $urandom_range(2) - 1 : r < 35 ? 17000 : $urandom_range(9000);
				for (int i = 0; i < n; i++) fwf[i] = 8'($urandom);
				fw_n = n;
				fw_seen = 1;
				rw_max += ((n > 16384 ? 16384 : n) + 3) / 4;
				// followed straight by another firmware download, its tail word goes with its FWEND
				rw_min += b2b ? (n > 16384 ? 16384 : n) / 4 : ((n > 16384 ? 16384 : n) + 3) / 4;
				n_fw++;
				fw_dl <= 1;
				if (fwrise && n > 0 && $urandom_range(1) == 0) begin
					// byte 0 in the clock fw_download rises
					n_fwrise++;
					ld_wr <= 1;
					ld_addr <= 25'd0;
					ld_data <= fwf[0];
					@(posedge clk_sys);
					ld_wr <= 0;
					loader_send(1, n, 1);
				end else begin
					repeat (prev_b2b && xstream ? 1 : 2 + $urandom_range(20)) @(posedge clk_sys);
					if (fwfall && n > 1 && n <= 16384 && $urandom_range(1) == 0) begin
						// the last byte in the clock fw_download falls
						n_fwfall++;
						loader_send(1, n - 1);
						repeat (3) @(posedge clk_sys);
						ld_wr <= 1;
						ld_addr <= 25'(n - 1);
						ld_data <= fwf[n - 1];
						fw_dl <= 0;
						fwv_extra <= 1;
						@(posedge clk_sys);
						ld_wr <= 0;
						fwv_extra <= 0;
					end else
						loader_send(1, n);
				end
				repeat (1 + $urandom_range(3)) @(posedge clk_sys);
				fw_dl <= 0;
			end else begin
				r = $urandom_range(99);
				R = r < 10 ? 0 : r < 25 ? 1 + 2 * $urandom_range(300) : r < 35 ? 4096 : $urandom_range(600);
				B = pick_block();
				Rdecl = R;
				if ($urandom_range(99) < 5) Rdecl = R + B + 1 + $urandom_range(100);   // the block is past the end
				img_n = 128 + R + B;
				for (int i = 0; i < img_n; i++) img[i] = 8'($urandom);
				img[49] = 8'(Rdecl >> 24); img[50] = 8'(Rdecl >> 16); img[51] = 8'(Rdecl >> 8); img[52] = 8'(Rdecl);
				blk_n = (Rdecl == 0 || Rdecl != R) ? 0 : B;
				for (int i = 0; i < blk_n; i++) blk[i] = img[128 + R + i];
				for (int i = 0; i < blk_n; i++) ring[n_cart_started % 4][i] = blk[i];
				ring_n[n_cart_started % 4] = blk_n;
				n_cart_started++;
				if (blk_n == 0) n_noblock++;
				pw_min += b2b ? blk_n / 2 : (blk_n + 1) / 2;
				pw_max += (blk_n + 1) / 2;
				n_cart++;
				cart_dl <= 1;
				repeat (2 + $urandom_range(20)) @(posedge clk_sys);
				loader_send(0, img_n);
				repeat (1 + $urandom_range(3)) @(posedge clk_sys);
				// +samefw / +overlapfw: the firmware slot's flag rises in the
				// same clk_sys edge the cartridge's falls (core_top's
				// download_slot switching 0x100 -> 0x109 with is_downloading
				// held), or one edge earlier (the two synchronisers resolving
				// differently).
				if (b2b && xstream && overlapfw && k + 1 < ndl) begin
					fw_dl <= 1;
					@(posedge clk_sys);
				end
				cart_dl <= 0;
				if (b2b && xstream && (samefw || overlapfw) && k + 1 < ndl) fw_dl <= 1;
			end
			prev_b2b = b2b;
			prev_fw = fw;
			if (b2b && k + 1 < ndl) begin
				// the next cartridge's load_start in the clock after load_end
				n_b2b++;
				if (!(xstream && (samefw || overlapfw))) @(posedge clk_sys);
				continue;
			end
			// 9-12 us for the messages to drain: END and FWEND leave 64 clk_sys
			// (4.5 us) after the flag falls (bup_capture.sv's windows)
			gap = 9000000 + $urandom_range(3000000);
			#(gap);
			@(posedge clk_sys);
			check();
		end
		#5000000;
		$display("capture stress, clk_arm %s%s: %0d downloads (%0d cartridges, %0d of them without a block, %0d followed straight by the next; %0d firmware), %0d checked, %0d wrong",
			async_ ? "asynchronous" : ratio == 15 ? "1.5 x clk_sys" : "2 x clk_sys", pal ? ", PAL" : "",
			ndl, n_cart, n_noblock, n_b2b, n_fw, n_checks, n_bad);
		$display("  %0d PSRAM writes, %0d ROM writes; reader: %0d reads checked, %0d wrong, %0d dropped at a hold; %0d firmware downloads with byte 0 in the clock fw_download rose; %0d with the last byte in the clock it fell",
			n_pwr, n_romwr, n_rd, rd_bad, rd_drop, n_fwrise, n_fwfall);
		$display("  seq_err %0d, byte order %0d, lost %0d (messages too close: %0d within a download stream, %0d across streams), overrun %0d",
			seq_err, cap.seq_sim, lost, n_lost_s, n_lost_x, overrun);
`ifndef PSRAM_VAR
		chip.report();
		$display("result: checks=%0d bad=%0d rdbad=%0d nrd=%0d seq=%0d order=%0d lost=%0d lost_s=%0d lost_x=%0d overrun=%0d viol=%0d",
			n_checks, n_bad, rd_bad, n_rd, seq_err, cap.seq_sim, lost, n_lost_s, n_lost_x, overrun, chip.n_viol);
`else
		$display("result: checks=%0d bad=%0d rdbad=%0d nrd=%0d seq=%0d order=%0d lost=%0d lost_s=%0d lost_x=%0d overrun=%0d viol=0",
			n_checks, n_bad, rd_bad, n_rd, seq_err, cap.seq_sim, lost, n_lost_s, n_lost_x, overrun);
`endif
		$finish;
	end
endmodule
