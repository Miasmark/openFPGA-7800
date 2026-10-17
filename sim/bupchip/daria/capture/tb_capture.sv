//------------------------------------------------------------------------------
// DARIA's image capture (docs/DARIA_CORE.md, "Image capture"): bup_capture on
// clk_sys, the message register and toggle across to clk_arm, bup_asset_wr,
// psram.sv (src/fpga/pocket_utils/, unmodified) on psram_model.sv
// (sim/bupchip/s4/), the image window as an array written through
// bup_asset_wr's win_* port, and ROM port B as an array written through
// rom_we while fw_loaded is low. No CPU, no cache.
//
// A plan file (run_capture.sh writes it, and the files it names) lists the
// downloads, one per line:
//
//   KIND N IS_A78 BLK_OFF BLK_LEN NEXT LATE PACE RISE LABEL PATH
//
//   KIND     0 the cartridge slot, 1 the firmware slot (bupchip.bin)
//   N        the file's bytes
//   IS_A78, BLK_OFF, BLK_LEN   the generator's model of the file: an A78
//            (bytes 1-5 "ATARI") and its ARSC block, or an image
//   NEXT     what follows: 0 a pause, then the check; 1 the next cartridge
//            download, its load_start in the clock after this load_end (no
//            check: the next START drops this one's head, tail and END);
//            2 the firmware download on the next line, its flag rising in
//            the clock the cartridge's falls, its first byte as early as
//            the loader allows (checked after it); 3 the same with the
//            firmware flag rising one clock before the cartridge's falls
//   LATE     the cartridge's last LATE bytes come after its flag fell
//            (inside the capture's window)
//   PACE     0 one byte every 2.5 clk_sys (data_loader.sv's fastest), 1 that
//            plus a random 0-80 ns, 2 a random 3-20 clk_sys per byte
//   RISE     1: the cartridge's byte 0 in the clock of load_start
//
// Bytes carry their slot (bridge address bits 27:25), as bupchip_pocket.sv
// hands them over: a cartridge byte after its flag fell is still the
// cartridge's.
//
// Clocks: clk_sys 14.318182 MHz (VCO 687.27 MHz / 48). clk_arm:
//   +clk=a38    38.181818 MHz (VCO / 18, DARIA's), rising edges with clk_sys's
//               every 3 clk_sys (the default)
//   +clk=x2     28.636364 MHz, 2 x clk_sys, edge aligned (the BupChip's today)
//   +clk=async  half period +arm_ps (default 13,100 ps: 38.17 MHz) plus a
//               random 0..+armjit ps per half period, from a random phase
// psram.sv's CLOCK_SPEED is `PSRAM_MHZ (run_capture.sh builds 28.636364 and
// 50.0).
//
// Checks after each download (and its firmware partner, NEXT 2 or 3):
//   A78     asset_size = BLK_LEN, asset_ready = BLK_LEN >= 4, img_ready low;
//           the block in the PSRAM from offset 0; exactly ceil(BLK_LEN / 2)
//           PSRAM writes enabling BLK_LEN byte lanes, and no window write,
//           since its START; the window still holding the last image checked
//   image   img_size = min(N, 512 KiB), img_ready = N >= 8, asset_ready
//           low; the file's first M = min(N, 512 KiB) bytes in the PSRAM and
//           its first W = min(N, 128 KiB) in the window; exactly ceil(M / 2)
//           PSRAM writes enabling M byte lanes and ceil(W / 2) window writes
//           enabling W
//   firmware fw_loaded = min(N, 16,384) >= 8, the ROM words equal the file
//           zero-padded, exactly ceil(min(N, 16,384) / 4) ROM writes since
//           the last check (none without a firmware download)
// Always: one clock after END is handled, every PSRAM write since START has
// ended at the chip (img_ready and asset_ready rise only after the last
// write); win_we high exactly with the PSRAM write of an image's WRITE
// below 128 KiB while img_ready is low, with the halfword on both halves and
// the WRITE's byte lanes in the half address bit 0 picks; seq_err, lost,
// overrun and the capture's simulation-only seq_sim and start_sim stay 0;
// no halfword or word completes while the one before still waits (lost_s),
// no message leaves less than 5 clk_sys after the last (lost_x); no PSRAM
// timing violation.
//
// +lockstep (A78 and firmware downloads only): bup_capture_ref and
// bup_asset_wr_ref, the BupChip's versions before DARIA (run_capture.sh
// takes them from git), run beside the new ones on the same inputs and the
// same psram_busy; every clk_sys clock the capture's message, toggle,
// seq_err, lost and windows must match bit for bit, and every clk_arm clock
// every receiver output (asset_ready, asset_size, fw_loaded, the ROM port,
// every psram.sv input, rd_ack, overrun, fw_start), whether or not its
// enable is high; img_ready and win_we must stay low.
//
// The log prints "check LABEL: ok" or "check LABEL: BAD ..." per check; the
// last line, "result: ...", is for run_capture.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
`ifndef PSRAM_MHZ
`define PSRAM_MHZ 28.636364
`endif

module tb_capture;
	localparam int IMG_MAX = 512 * 1024, WIN_MAX = 128 * 1024;

	// ---- clocks ---------------------------------------------------------------------------------------
	longint sys_half = 34920, arm_half = 13095, arm_ps = 13100, armjit = 0;	// 1,455 ps x 24 and x 9
	string  clkmode = "a38";
	logic   clk_sys = 0, clk_arm = 0;
	initial begin
		void'($value$plusargs("clk=%s", clkmode));
		void'($value$plusargs("arm_ps=%d", arm_ps));
		void'($value$plusargs("armjit=%d", armjit));
		if (clkmode == "x2") arm_half = 17460;
		#1;
		if (clkmode == "async") begin
			fork
				forever begin #(sys_half); clk_sys = ~clk_sys; end
				begin
					#($urandom_range(int'(2 * arm_ps)));
					forever begin
						#(arm_ps + (armjit > 0 ? $urandom_range(int'(armjit)) : 0));
						clk_arm = ~clk_arm;
					end
				end
			join_none
		end else begin
			// rising edges together at the start, then every 3 clk_sys (a38) or
			// every clk_sys (x2)
			clk_sys = 1;
			clk_arm = 1;
			fork
				forever begin #(sys_half); clk_sys = ~clk_sys; end
				forever begin #(arm_half); clk_arm = ~clk_arm; end
			join_none
		end
	end

	// ---- the path ------------------------------------------------------------------------------------
	logic        cart_dl = 0, cart_dl_q = 0, fw_dl = 0, ld_wr = 0, ld_fw = 0;
	logic [24:0] ld_addr = 0;
	logic  [7:0] ld_data = 0;
	always @(posedge clk_sys) cart_dl_q <= cart_dl;
	wire load_start = cart_dl && !cart_dl_q, load_end = !cart_dl && cart_dl_q;
	wire load_valid = ld_wr && !ld_fw, fw_valid = ld_wr && ld_fw;	// by the byte's own slot

	wire  [2:0] msg_type;
	wire [43:0] msg_pl;
	wire        msg_tog, seq_err, lost, cart_win, fw_win;
	bup_capture cap (
		.clk(clk_sys), .load_start, .load_addr(ld_addr), .load_valid, .load_data(ld_data), .load_end,
		.fw_download(fw_dl), .fw_valid, .msg_type, .msg_pl, .msg_tog, .seq_err, .lost, .cart_win, .fw_win);

	wire        asset_ready, fw_loaded, img_ready, rom_we, overrun, win_we, rd_ack, fw_start;
	wire [23:0] asset_size;
	wire [19:0] img_size;
	wire [11:0] rom_wa;
	wire [31:0] rom_wd, win_wd;
	wire [14:0] win_wa;
	wire  [3:0] win_be;
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	bup_asset_wr wr (
		.clk(clk_arm), .msg_type, .msg_pl, .msg_tog,
		.asset_ready, .asset_size, .fw_loaded, .img_ready, .img_size,
		.rom_we, .rom_wa, .rom_wd, .win_we, .win_wa, .win_wd, .win_be,
		.rd_req(1'b0), .rd_addr(22'd0), .rd_ack,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun, .fw_start);

	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(`PSRAM_MHZ)) ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	function automatic logic [8:0] psram_byte(input int b);	// {written, byte}
		logic [15:0] h;
		logic  [1:0] w;
		h = chip.bd_read(0, b >> 1);
		w = chip.bd_written(0, b >> 1);
		return {b[0] ? w[1] : w[0], b[0] ? h[15:8] : h[7:0]};
	endfunction

	// ---- the BupChip's versions, for +lockstep ------------------------------------------------------
	wire  [2:0] r_type;
	wire [43:0] r_pl;
	wire        r_tog, r_seq_err, r_lost, r_cart_win, r_fw_win;
	bup_capture_ref cref (
		.clk(clk_sys), .load_start, .load_addr(ld_addr), .load_valid, .load_data(ld_data), .load_end,
		.fw_download(fw_dl), .fw_valid, .msg_type(r_type), .msg_pl(r_pl), .msg_tog(r_tog),
		.seq_err(r_seq_err), .lost(r_lost), .cart_win(r_cart_win), .fw_win(r_fw_win));
	wire        r_asset_ready, r_fw_loaded, r_rom_we, r_overrun, r_rd_ack, r_fw_start;
	wire [23:0] r_asset_size;
	wire [11:0] r_rom_wa;
	wire [31:0] r_rom_wd;
	wire        r_bank, r_we, r_hi, r_lo, r_re;
	wire [21:0] r_addr;
	wire [15:0] r_din;
	bup_asset_wr_ref wref (
		.clk(clk_arm), .msg_type(r_type), .msg_pl(r_pl), .msg_tog(r_tog),
		.asset_ready(r_asset_ready), .asset_size(r_asset_size), .fw_loaded(r_fw_loaded),
		.rom_we(r_rom_we), .rom_wa(r_rom_wa), .rom_wd(r_rom_wd),
		.rd_req(1'b0), .rd_addr(22'd0), .rd_ack(r_rd_ack),
		.psram_bank_sel(r_bank), .psram_addr(r_addr), .psram_write_en(r_we), .psram_data_in(r_din),
		.psram_write_high_byte(r_hi), .psram_write_low_byte(r_lo), .psram_read_en(r_re),
		.psram_busy(p_busy), .overrun(r_overrun), .fw_start(r_fw_start));

	bit     lockstep = 0;
	longint ls_sys = 0, ls_arm = 0, ls_diff = 0;
	always @(posedge clk_sys) if (lockstep) begin
		ls_sys++;
		if ({msg_type, msg_pl, msg_tog, seq_err, lost, cart_win, fw_win} !== {r_type, r_pl, r_tog, r_seq_err, r_lost, r_cart_win, r_fw_win}) begin
			ls_diff++;
			if (ls_diff <= 5) $display("%0t: lockstep: capture %0d %011x %0d, BupChip's %0d %011x %0d", $time, msg_type, msg_pl, msg_tog, r_type, r_pl, r_tog);
		end
	end
	always @(posedge clk_arm) if (lockstep) begin
		ls_arm++;
		if ({asset_ready, asset_size, fw_loaded, rom_we, rom_wa, rom_wd, p_bank, p_addr, p_we, p_din, p_hi, p_lo, p_re, rd_ack, overrun, fw_start}
				!== {r_asset_ready, r_asset_size, r_fw_loaded, r_rom_we, r_rom_wa, r_rom_wd, r_bank, r_addr, r_we, r_din, r_hi, r_lo, r_re, r_rd_ack, r_overrun, r_fw_start}
				|| img_ready || win_we) begin
			ls_diff++;
			if (ls_diff <= 5) $display("%0t: lockstep: receiver ready %0d size %0d fw %0d rom %0d psram %0d@%06x, BupChip's ready %0d size %0d fw %0d rom %0d psram %0d@%06x; img_ready %0d win_we %0d",
				$time, asset_ready, asset_size, fw_loaded, rom_we, p_we, p_addr,
				r_asset_ready, r_asset_size, r_fw_loaded, r_rom_we, r_we, r_addr, img_ready, win_we);
		end
	end

	// ---- what the window, ROM port B and the PSRAM saw (clk_arm) --------------------------------------
	logic [31:0] win [0:32767];
	logic [31:0] rom [0:4095];
	initial for (int i = 0; i < 32768; i++) win[i] = 32'hDEAD0000 | i;
	initial for (int i = 0; i < 4096; i++) rom[i] = 32'hBEEF0000 | i;
	longint n_pwr = 0, n_winwr = 0, n_romwr = 0, dl_pwr = 0, dl_win = 0, chip_wr0 = 0;
	longint dl_pbytes = 0, dl_wbytes = 0;	// byte lanes written since START
	longint n_win_bad = 0, n_end_bad = 0, n_end = 0;
	longint lat_min = 1000000000, lat_max = 0;	// ps from the toggle to win_we
	longint t_tog = 0;
	logic   end_d = 0;
	always @(posedge clk_sys) if (cap.queued) t_tog <= $time;	// the toggle flips on this edge
	always @(posedge clk_arm) begin
		if (win_we) begin
			for (int k = 0; k < 4; k++) if (win_be[k]) win[win_wa][8 * k +: 8] = win_wd[8 * k +: 8];
			n_winwr++;
			dl_win++;
			dl_wbytes += win_be[0] + win_be[1] + win_be[2] + win_be[3];
			if ($time - t_tog < lat_min) lat_min = $time - t_tog;
			if ($time - t_tog > lat_max) lat_max = $time - t_tog;
			// only an image's WRITE, below 128 KiB, while img_ready is low, with
			// the PSRAM write
			if (img_ready || !p_we || !wr.m_pl[40] || wr.m_pl[37:32] != 6'd0 || win_wd[31:16] != win_wd[15:0]
					|| win_be != (wr.m_pl[16] ? {wr.m_pl[39:38], 2'b00} : {2'b00, wr.m_pl[39:38]})) begin
				n_win_bad++;
				if (n_win_bad <= 5) $display("%0t: window write with img_ready %0d p_we %0d pl %011x be %b", $time, img_ready, p_we, wr.m_pl, win_be);
			end
		end
		if (p_we && wr.m_pl[40] && wr.m_pl[37:32] == 6'd0 && !img_ready && !win_we) begin
			n_win_bad++;
			if (n_win_bad <= 5) $display("%0t: image WRITE below 128 KiB without a window write", $time);
		end
		if (rom_we && !fw_loaded) begin
			rom[rom_wa] = rom_wd;
			n_romwr++;
		end
		if (p_we) begin n_pwr++; dl_pwr++; dl_pbytes += p_hi + p_lo; end
		if (wr.done && wr.m_type == 3'd1) begin	// START: the download's counts from here
			dl_pwr = 0;
			dl_win = 0;
			dl_pbytes = 0;
			dl_wbytes = 0;
			chip_wr0 = chip.n_wr;
		end
		// END was handled in the clock before: every write has ended at the chip
		if (end_d) begin
			n_end++;
			if (longint'(chip.n_wr) - chip_wr0 != dl_pwr) begin
				n_end_bad++;
				$display("%0t: END handled with %0d of %0d PSRAM writes ended", $time, longint'(chip.n_wr) - chip_wr0, dl_pwr);
			end
		end
		end_d <= wr.done && wr.m_type == 3'd3;
	end

	// A halfword or word completing while the one before still waits (the
	// capture's lost), and a message leaving less than 5 clk_sys after the
	// last.
	logic   tog_q = 0;
	int     since = 100;
	longint n_lost_s = 0, n_lost_x = 0, n_msg = 0;
	always @(posedge clk_sys) begin
		if ((cap.a_pair && cap.p_write && !cap.send_write) ||
		    (cap.f_word && cap.p_fwword && !cap.send_fwword && !cap.fw_rise)) begin
			n_lost_s++;
			if (n_lost_s <= 5) $display("%0t: a %0s completed while the last still waited", $time, cap.a_pair ? "halfword" : "word");
		end
		tog_q <= cap.msg_tog;
		since <= cap.msg_tog != tog_q ? 1 : since + 1;
		if (cap.msg_tog != tog_q) n_msg++;
		if (cap.msg_tog != tog_q && since < 5) begin
			n_lost_x++;
			if (n_lost_x <= 5) $display("%0t: message type %0d only %0d clk_sys after the last", $time, cap.msg_type, since);
		end
	end

	// ---- the loader (clk_sys) ------------------------------------------------------------------------
	logic [7:0] img [0:1048575];
	logic [7:0] fwb [0:32767];
	real        bp = 0.0, jit = 0.0, t_next = 0.0;	// ps per byte, random extra, the last byte's time

	function automatic real sys_per();
		return real'(2 * sys_half);
	endfunction

	// Bytes k0..k1-1 of the cartridge (fw = 0) or firmware file, byte k on the
	// first clk_sys edge at or after t_next + bp (+ jitter), one clock each.
	task automatic send_bytes(input bit fw, input int k0, input int k1);
		real p;
		p = sys_per();
		if (t_next < $realtime - p) t_next = $realtime - p;	// never two bytes closer than 2 clocks
		for (int k = k0; k < k1; k++) begin
			t_next += bp + (jit > 0.0 ? real'($urandom_range(1000)) * jit / 1000.0 : 0.0);
			while ($realtime < t_next - p) @(posedge clk_sys);
			ld_wr <= 1;
			ld_fw <= fw;
			ld_addr <= 25'(k);
			ld_data <= fw ? fwb[k] : img[k];
			@(posedge clk_sys);
			ld_wr <= 0;
			ld_data <= 8'($urandom);
		end
	endtask

	// One cartridge download. b2b_in: the previous one ended in the clock
	// before. rise: byte 0 in the clock of load_start.
	task automatic do_cart(input int n, input int next, input int late, input bit b2b_in, input bit rise);
		// drive just after a clk_sys edge (a check ends on a clk_arm edge, which
		// a38 shares with clk_sys every 3 clocks); b2b_in is there already
		if (!b2b_in) @(posedge clk_sys);
		cart_dl <= 1;
		if (rise && n > 0) begin
			ld_wr <= 1;
			ld_fw <= 0;
			ld_addr <= 25'd0;
			ld_data <= img[0];
			@(posedge clk_sys);
			ld_wr <= 0;
			t_next = $realtime;
			send_bytes(0, 1, n - late);
		end else begin
			if (!b2b_in) repeat (2 + $urandom_range(20)) @(posedge clk_sys);
			@(posedge clk_sys);
			t_next = $realtime;
			send_bytes(0, 0, n - late);
		end
		repeat (1 + $urandom_range(3)) @(posedge clk_sys);
		if (next == 3) begin
			fw_dl <= 1;
			@(posedge clk_sys);
		end
		cart_dl <= 0;
		if (next == 2) fw_dl <= 1;
		if (late > 0) begin
			@(posedge clk_sys);
			send_bytes(0, n - late, n);
		end
		if (next == 1) @(posedge clk_sys);	// the next load_start in the clock after load_end
	endtask

	// One firmware download. chained: its flag is already up (NEXT 2 or 3).
	task automatic do_fw(input int n, input bit chained);
		if (!chained) begin
			fw_dl <= 1;
			repeat (2 + $urandom_range(20)) @(posedge clk_sys);
			@(posedge clk_sys);
			t_next = $realtime;
		end
		send_bytes(1, 0, n);
		repeat (1 + $urandom_range(3)) @(posedge clk_sys);
		fw_dl <= 0;
	endtask

	// ---- expectations and checks ---------------------------------------------------------------------
	bit         c_seen = 0, c_a78 = 0, f_seen = 0, f_new = 0;
	int         c_n = 0, c_boff = 0, c_blen = 0, f_n = 0, f_m = 0;
	logic [7:0] win_ref [0:WIN_MAX - 1];	// the last image checked, its first 128 KiB
	int         win_n = 0;
	longint     romwr0 = 0, n_checks = 0, n_bad = 0;

	task automatic check(input string label);
		int bad, m, w;
		string why;
		bad = 0;
		why = "";
		n_checks++;
		if (c_seen && c_a78) begin
			if (int'(asset_size) != c_blen || asset_ready != (c_blen >= 4) || img_ready) begin
				why = {why, $sformatf(" asset_size %0d asset_ready %0d img_ready %0d (expected %0d %0d 0);", asset_size, asset_ready, img_ready, c_blen, c_blen >= 4)};
				bad++;
			end
			for (int i = 0; i < c_blen; i++) begin
				logic [8:0] v;
				v = psram_byte(i);
				if (!v[8] || v[7:0] !== img[c_boff + i]) begin
					if (bad < 5) why = {why, $sformatf(" PSRAM byte %0d %s%02x, block %02x;", i, v[8] ? "" : "unwritten ", v[7:0], img[c_boff + i])};
					bad++;
				end
			end
			if (dl_pwr != (c_blen + 1) / 2 || dl_pbytes != c_blen || dl_win != 0) begin
				why = {why, $sformatf(" %0d PSRAM writes of %0d bytes, %0d window writes (expected %0d of %0d, 0);", dl_pwr, dl_pbytes, dl_win, (c_blen + 1) / 2, c_blen)};
				bad++;
			end
		end else if (c_seen) begin
			m = c_n < IMG_MAX ? c_n : IMG_MAX;
			w = c_n < WIN_MAX ? c_n : WIN_MAX;
			if (int'(img_size) != m || img_ready != (c_n >= 8) || asset_ready) begin
				why = {why, $sformatf(" img_size %0d img_ready %0d asset_ready %0d (expected %0d %0d 0);", img_size, img_ready, asset_ready, m, c_n >= 8)};
				bad++;
			end
			for (int i = 0; i < m; i++) begin
				logic [8:0] v;
				v = psram_byte(i);
				if (!v[8] || v[7:0] !== img[i]) begin
					if (bad < 5) why = {why, $sformatf(" PSRAM byte %0d %s%02x, file %02x;", i, v[8] ? "" : "unwritten ", v[7:0], img[i])};
					bad++;
				end
			end
			for (int i = 0; i < w; i++) begin
				logic [7:0] v;
				v = win[i >> 2][8 * (i & 3) +: 8];
				if (v !== img[i]) begin
					if (bad < 5) why = {why, $sformatf(" window byte %0d %02x, file %02x;", i, v, img[i])};
					bad++;
				end
			end
			if (dl_pwr != (m + 1) / 2 || dl_pbytes != m || dl_win != (w + 1) / 2 || dl_wbytes != w) begin
				why = {why, $sformatf(" %0d PSRAM writes of %0d bytes, %0d window writes of %0d bytes (expected %0d of %0d, %0d of %0d);",
					dl_pwr, dl_pbytes, dl_win, dl_wbytes, (m + 1) / 2, m, (w + 1) / 2, w)};
				bad++;
			end
		end
		// the window keeps the last image checked through A78 downloads
		if (c_seen && c_a78)
			for (int i = 0; i < win_n; i++)
				if (win[i >> 2][8 * (i & 3) +: 8] !== win_ref[i]) begin
					if (bad < 5) why = {why, $sformatf(" window byte %0d changed by an A78;", i)};
					bad++;
				end
		if (f_seen) begin
			m = f_n > 16384 ? 16384 : f_n;
			if (fw_loaded != (m >= 8)) begin
				why = {why, $sformatf(" fw_loaded %0d for %0d bytes;", fw_loaded, f_n)};
				bad++;
			end
			for (int k = 0; k < (m + 3) / 4; k++) begin
				logic [31:0] e;
				e = 0;
				for (int j = 0; j < 4; j++) if (4 * k + j < m) e[8 * j +: 8] = fwb[4 * k + j];
				if (rom[k] !== e) begin
					if (bad < 5) why = {why, $sformatf(" ROM word %0d %08x, file %08x;", k, rom[k], e)};
					bad++;
				end
			end
		end
		// the ROM writes since the last check: the firmware download's, if
		// there was one
		if (n_romwr - romwr0 != (f_new ? (f_m + 3) / 4 : 0)) begin
			why = {why, $sformatf(" %0d ROM writes, expected %0d;", n_romwr - romwr0, f_new ? (f_m + 3) / 4 : 0)};
			bad++;
		end
		romwr0 = n_romwr;
		f_new = 0;
		if (seq_err || lost || overrun || cap.seq_sim || cap.start_sim || n_lost_s || n_lost_x || chip.n_viol
				|| n_win_bad || n_end_bad) begin
			why = {why, $sformatf(" seq_err %0d lost %0d overrun %0d seq_sim %0d start_sim %0d lost_s %0d lost_x %0d viol %0d win_bad %0d end_bad %0d;",
				seq_err, lost, overrun, cap.seq_sim, cap.start_sim, n_lost_s, n_lost_x, chip.n_viol, n_win_bad, n_end_bad)};
			bad++;
		end
		if (bad == 0 && c_seen && !c_a78) begin
			win_n = c_n < WIN_MAX ? c_n : WIN_MAX;
			for (int i = 0; i < win_n; i++) win_ref[i] = img[i];
		end
		if (bad) begin
			n_bad++;
			$display("check %s: BAD%s", label, why);
		end else
			$display("check %s: ok", label);
	endtask

	// ---- the plan ------------------------------------------------------------------------------------
	initial begin
		string  plan, label, path;
		int     fd, r, kind, n, a78, boff, blen, next, late, pace, rise, prev_next, ffd, got;
		longint n_rise = 0;
		if ($value$plusargs("seed=%d", r)) void'($urandom(r));
		lockstep = $test$plusargs("lockstep");
		if (!$value$plusargs("plan=%s", plan)) $fatal(1, "+plan=FILE");
		fd = $fopen(plan, "r");
		if (fd == 0) $fatal(1, "cannot open %s", plan);
		$display("capture bench: clk_arm %s, psram.sv CLOCK_SPEED %f, plan %s%s", clkmode, `PSRAM_MHZ, plan, lockstep ? ", lockstep" : "");
		repeat (20) @(posedge clk_sys);
		prev_next = 0;
		forever begin
			r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %s %s\n", kind, n, a78, boff, blen, next, late, pace, rise, label, path);
			if (r != 11) break;
			// the loader's pace
			bp = 2.5 * sys_per();
			jit = 0.0;
			if (pace == 1) jit = real'($urandom_range(80)) * 1000.0;
			if (pace == 2) bp = real'($urandom_range(3, 20)) * sys_per();
			ffd = $fopen(path, "rb");
			if (ffd == 0) $fatal(1, "cannot open %s", path);
			if (kind == 0) begin
				got = n > 0 ? $fread(img, ffd) : 0;
				$fclose(ffd);
				if (got != n) $fatal(1, "%s: read %0d bytes, the plan says %0d", path, got, n);
				c_seen = 1;
				c_a78 = a78 != 0;
				c_n = n;
				c_boff = boff;
				c_blen = blen;
				if (!c_a78) win_n = 0;	// this image rewrites the window
				if (rise && n > 0) n_rise++;
				do_cart(n, next, late, prev_next == 1, rise != 0);
			end else begin
				got = n > 0 ? $fread(fwb, ffd) : 0;
				$fclose(ffd);
				if (got != n) $fatal(1, "%s: read %0d bytes, the plan says %0d", path, got, n);
				f_seen = 1;
				f_new = 1;
				f_n = n;
				f_m = n > 16384 ? 16384 : n;
				do_fw(n, prev_next == 2 || prev_next == 3);
			end
			prev_next = next;
			if (next == 0) begin
				// END and FWEND leave 64 clk_sys (4.5 us) after the flag falls,
				// behind the head and tail: 9-12 us is plenty
				#(9000000 + $urandom_range(3000000));
				@(posedge clk_arm);
				check(label);
			end
		end
		$fclose(fd);
		#2000000;
		$display("capture bench: %0d checks, %0d bad; %0d messages, %0d PSRAM writes, %0d window writes, %0d ROM writes; toggle to win_we %s; %0d ENDs, %0d before their writes ended",
			n_checks, n_bad, n_msg, n_pwr, n_winwr, n_romwr, n_winwr ? $sformatf("%0d-%0d ps", lat_min, lat_max) : "none", n_end, n_end_bad);
		$display("  seq_err %0d, lost %0d, overrun %0d, seq_sim %0d, start_sim %0d, lost_s %0d, lost_x %0d, window write faults %0d; %0d cartridges with byte 0 in the clock of load_start",
			seq_err, lost, overrun, cap.seq_sim, cap.start_sim, n_lost_s, n_lost_x, n_win_bad, n_rise);
		if (lockstep) $display("  lockstep with the BupChip's capture and receiver: %0d clk_sys and %0d clk_arm clocks, %0d differences", ls_sys, ls_arm, ls_diff);
		chip.report();
		$display("result: checks=%0d bad=%0d seq=%0d lost=%0d overrun=%0d order=%0d start=%0d lost_s=%0d lost_x=%0d win=%0d endw=%0d viol=%0d ls=%0d lsdiff=%0d",
			n_checks, n_bad, seq_err, lost, overrun, cap.seq_sim, cap.start_sim, n_lost_s, n_lost_x, n_win_bad, n_end_bad, chip.n_viol,
			lockstep ? ls_sys + ls_arm : 0, ls_diff);
		$finish;
	end
endmodule
