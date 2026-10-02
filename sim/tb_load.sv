// Load path test: an A78 image goes through the APF data loader, exactly as
// core_top.v wires it (clk_sdram, 10 cycle spacing, 4 cycle strobe), into
// atari7800_pocket, then the core runs it. The image's program starts a TIA
// tone, so hearing the right tone proves the header was parsed, the 128 byte
// header was stripped, the payload landed at the right place and the cart
// mapping is right. The built-in cartridge image plays nothing, so a wrong
// load cannot pass by accident.
`timescale 1ns/1ps

module tb_load;
	localparam real T_SYS = 69.8413;
	logic clk_sdram = 1'b1, clk_sys = 1'b1, clk_74a = 1'b0;
	always #(T_SYS / 8.0) clk_sdram = ~clk_sdram;
	always #(T_SYS / 2.0) clk_sys = ~clk_sys;
	always #6.734 clk_74a = ~clk_74a;

	logic reset_in = 1'b1;
	logic [8:0] hsc_addr = 0; logic hsc_wr = 0; logic hsc_rd = 0;
	logic [1:0] sk_setting = 2'd2; logic [12:0] sk_addr = 0; logic sk_wr = 0, sk_rd = 0;
	logic [31:0] sk_din = 0; wire [31:0] sk_dout; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic cart_download = 1'b0;
	logic hscfw_download = 1'b0, arfw_download = 1'b0;
	logic pokey_irq_on = 1'b0;
	logic overscan_on = 1'b0;
	logic clear_rnd = 1'b0; logic [4:0] bs_ovr = 5'd0;   // +clearrnd, +bs=N
	initial begin
		clear_rnd = $test$plusargs("clearrnd");
		void'($value$plusargs("bs=%d", bs_ovr));
	end
	initial overscan_on = $test$plusargs("overscan");
	initial pokey_irq_on = $test$plusargs("pokeyirq");
	logic [15:0] joy0 = 16'd0, joy1 = 16'd0, joy2 = 16'd0, joy3 = 16'd0;
	logic [15:0] ana0 = 16'h8080;
	logic [2:0] port1_in = 3'd0, port2_in = 3'd0;   // +port1=N, +port2=N
	logic [1:0] turbo = 2'd0;                         // +turbo=N
	initial begin
		void'($value$plusargs("turbo=%d", turbo));
		void'($value$plusargs("port1=%d", port1_in));
		void'($value$plusargs("port2=%d", port2_in));
	end
	logic [1:0] hsc_setting = 2'd0;

	// ---------------- APF bridge + loader ----------------
	logic        bridge_wr = 1'b0;
	logic [31:0] bridge_addr = 0, bridge_wr_data = 0;
	wire         ioctl_wr;
	wire  [27:0] ioctl_addr;
	wire   [7:0] ioctl_dout;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(4'h0), .ADDRESS_SIZE(28),
		.WRITE_MEM_CLOCK_DELAY(10), .WRITE_MEM_EN_CYCLE_LENGTH(4), .OUTPUT_WORD_SIZE(1)
	) loader (
		.clk_74a(clk_74a), .clk_memory(clk_sdram),
		.bridge_wr(bridge_wr), .bridge_endian_little(1'b0),
		.bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
		.write_en(ioctl_wr), .write_addr(ioctl_addr), .write_data(ioctl_dout)
	);

	// core_top registers the loader's output on clk_sys
	logic ioctl_wr_r = 0; logic [24:0] ioctl_addr_r = 0; logic [7:0] ioctl_dout_r = 0;
	always @(posedge clk_sys) begin
		ioctl_wr_r <= ioctl_wr; ioctl_addr_r <= ioctl_addr[24:0]; ioctl_dout_r <= ioctl_dout;
	end

	// ---------------- system ----------------
	wire [7:0] R, G, B;
	wire HSync, VSync, HBlank, VBlank, ce_pix, tia_mode, is_pal;
	wire [15:0] AUDIO_L, AUDIO_R, SDRAM_DQ;

	atari7800_pocket dut (
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(1'b1), .pll_busy(1'b0), .reset_in(reset_in),
		.cart_download(cart_download), .bios_download(1'b0),
		.hscfw_download(hscfw_download), .arfw_download(arfw_download),
		.ioctl_wr(ioctl_wr_r & (cart_download | hscfw_download | arfw_download)), .ioctl_addr(ioctl_addr_r), .ioctl_dout(ioctl_dout_r),
		.region_setting(2'd0), .palette_temp(2'd0), .hsc_setting(hsc_setting), .show_overscan(overscan_on),
		.hide_border(1'b0), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(1'b0), .pokey_irq(pokey_irq_on), .pause_core(1'b0),
		.clear_random(clear_rnd), .decomb(1'b0), .bs_override(bs_ovr),
		.joy0(joy0), .joy1(joy1), .joy2(joy2), .joy3(joy3),
		.analog0(ana0), .analog1(16'h8080), .analog2(16'h8080), .analog3(16'h8080),
		.port1_input(port1_in), .port2_input(port2_in),
		.analog0r(16'h8080), .analog1r(16'h8080), .turbo(turbo),
		.R(R), .G(G), .B(B), .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
		.ce_pix(ce_pix), .tia_mode_o(tia_mode), .is_pal_o(is_pal), .video_pal_o(),
		.AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R),
		.clk_74a(clk_74a), .hsc_bridge_addr(hsc_addr), .hsc_bridge_wr(hsc_wr), .hsc_bridge_rd(hsc_rd), .hsc_bridge_din(hsc_din),
		.hsc_bridge_dout(hsc_dout), .hsc_active(),
		.savekey_setting(sk_setting), .sk_bridge_addr(sk_addr), .sk_bridge_wr(sk_wr), .sk_bridge_rd(sk_rd),
		.sk_bridge_din(sk_din), .sk_bridge_dout(sk_dout),
		.SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(), .SDRAM_DQMH(),
		.SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_CLK(), .SDRAM_CKE()
	);

	// ---------------- frame capture (+dump=N: write N frames as PPM) --------
	int dump_frames = 0, dumped = 0, fx = 0, fy = 0, line_px = 0, dump_at = 0, fire_at = 0, fire_at2 = 0;
	logic capture = 0, old_vs2 = 0, old_hb2 = 1;
	logic [23:0] fb [0:299][0:399];
	always @(posedge clk_sys) begin
		old_vs2 <= VSync;
		old_hb2 <= HBlank;
		if (capture) begin
			if (ce_pix && !HBlank && !VBlank) begin
				if (fy < 300 && line_px < 400) fb[fy][line_px] <= {R, G, B};
				line_px <= line_px + 1;
			end
			if (!old_hb2 && HBlank && line_px != 0) begin
				fx <= line_px;
				fy <= fy + 1;
				line_px <= 0;
			end
		end
		if (!old_vs2 && VSync) begin
			if (capture && fy > 0 && dumped < dump_frames) begin
				automatic int f = $fopen($sformatf("frame_%03d.ppm", dumped), "wb");
				$fwrite(f, "P6\n%0d %0d\n255\n", fx, fy);
				for (int y = 0; y < fy; y++)
					for (int x = 0; x < fx; x++)
						$fwrite(f, "%c%c%c", fb[y][x][23:16], fb[y][x][15:8], fb[y][x][7:0]);
				$fclose(f);
				dumped <= dumped + 1;
			end
			fy <= 0;
			line_px <= 0;
		end
	end

	// ---------------- audio capture (+wav=ms: record raw and filtered) ------
	wire [15:0] filt_l, filt_r;
	audio_filter afilt (.clk(clk_sys), .in_l(AUDIO_L), .in_r(AUDIO_R), .out_l(filt_l), .out_r(filt_r));
	int wav_raw, wav_filt, wav_ms = 0;
	logic recording = 0;
	int rec_div = 0;
	always @(posedge clk_sys) if (recording) begin
		rec_div <= rec_div == 297 ? 0 : rec_div + 1;       // ~48.05 kHz
		if (rec_div == 0) begin
			$fwrite(wav_raw, "%c%c", AUDIO_L[7:0], AUDIO_L[15:8]);
			$fwrite(wav_filt, "%c%c", filt_l[7:0], filt_l[15:8]);
		end
	end

`ifdef POKEY_SHADOW
	// ---------------- POKEY shadow (run_pokey_shadow.sh) ----------------
	// The AUD node of the Watson POKEY the core plays and of upstream's new
	// POKEY shadowing it, sampled together at the WAV rate.
	int pk_w = 0, pk_n = 0;
	always @(posedge clk_sys) if (recording && rec_div == 0) begin
		if (pk_w == 0) begin pk_w = $fopen("pokey_watson.pcm", "wb"); pk_n = $fopen("pokey_new.pcm", "wb"); end
		$fwrite(pk_w, "%c%c", dut.main.cart.pokey_aud[7:0], dut.main.cart.pokey_aud[15:8]);
		$fwrite(pk_n, "%c%c", dut.main.cart.shadow_aud[7:0], dut.main.cart.shadow_aud[15:8]);
	end
`endif

	// ---------------- bus probe for dli_pokey_test ----------------
	// NMI count (DLIs), and writes to $41 (the test cart's main loop counter)
	// and $4000 (POKEY AUDF1, the siren sweep).
	longint nmis = 0, main_writes = 0, audf_writes = 0;
	logic old_nmi = 1'b1, old_wr41 = 1'b0, old_wr4k = 1'b0;
	always @(posedge clk_sys) if (recording) begin
		old_nmi <= dut.main.NMI_n;
		if (old_nmi && !dut.main.NMI_n) nmis <= nmis + 1;
		old_wr41 <= !dut.RW && dut.bios_addr == 16'h0041;
		if (!old_wr41 && !dut.RW && dut.bios_addr == 16'h0041) main_writes <= main_writes + 1;
		old_wr4k <= !dut.RW && dut.bios_addr == 16'h4000;
		if (!old_wr4k && !dut.RW && dut.bios_addr == 16'h4000) audf_writes <= audf_writes + 1;
	end

	// ---------------- save device probe ----------------
	// Which save devices a cart actually talks to: CPU accesses to the HSC
	// RAM ($1000-$17FF) and ROM ($3000-$3FFF) while the HSC is enabled, SCL
	// edges on port 2 and bytes the SaveKey EEPROM writes.
	longint hsc_ram_wr = 0, hsc_ram_rd = 0, hsc_rom_rd = 0, scl_edges = 0, sk_bytes = 0;
	logic [15:0] old_a = 0; logic old_scl = 1'b1, old_skwr = 1'b0;
	always @(posedge clk_sys) begin
		old_a <= dut.bios_addr;
		if (dut.hsc_en && dut.bios_addr != old_a) begin
			if (dut.bios_addr[15:11] == 5'd2) begin
				if (!dut.RW) hsc_ram_wr <= hsc_ram_wr + 1; else hsc_ram_rd <= hsc_ram_rd + 1;
			end
			if (dut.bios_addr[15:12] == 4'd3) hsc_rom_rd <= hsc_rom_rd + 1;
		end
		old_scl <= dut.PAout[3];
		if (dut.use_sk && old_scl != dut.PAout[3]) scl_edges <= scl_edges + 1;
		old_skwr <= dut.sk_ram_wr;
		if (dut.sk_ram_wr && !old_skwr) sk_bytes <= sk_bytes + 1;
	end

	// ---------------- I2C trace (+i2ctrace) ----------------
	// Decodes port 2's SaveKey bus as the lines really are: open drain, so
	// SDA is low when either the console or the EEPROM pulls it low.
	logic i2c_on = 0, i2c_scl_d = 1, i2c_sda_d = 1, i2c_in = 0;
	int   i2c_bits = 0, i2c_lines = 0; logic [8:0] i2c_sh = 0; string i2c_txt = "";
	wire  i2c_scl = dut.PAout[3];
	wire  i2c_sda = dut.PAout[2] & dut.sk_sda;
	longint i2c_raw_from = 0, i2c_raw_to = 0;
	initial begin
		void'($value$plusargs("i2craw_from=%d", i2c_raw_from));
		void'($value$plusargs("i2craw_to=%d", i2c_raw_to));
	end
	always @(posedge clk_sys) if (i2c_on && dut.use_sk && $time/1000000 >= i2c_raw_from && $time/1000000 < i2c_raw_to
		&& (i2c_scl != i2c_scl_d || i2c_sda != i2c_sda_d || dut.PAout[2] != old_pa2 || dut.sk_sda != old_sksda))
		$display("RAW %0d us: SCL %b SDA line %b (console %b, eeprom %b)", $time/1000000, i2c_scl, i2c_sda, dut.PAout[2], dut.sk_sda);
	logic old_pa2 = 1, old_sksda = 1;
	always @(posedge clk_sys) begin old_pa2 <= dut.PAout[2]; old_sksda <= dut.sk_sda; end
	always @(posedge clk_sys) if (i2c_on && dut.use_sk) begin
		i2c_scl_d <= i2c_scl; i2c_sda_d <= i2c_sda;
		if (i2c_scl && i2c_scl_d && i2c_sda_d && !i2c_sda) begin          // START
			if (i2c_txt != "" && i2c_lines < 400) begin $display("I2C %0s", i2c_txt); i2c_lines++; end
			i2c_txt = $sformatf("[%0d us] S", $time / 1000000); i2c_bits = 0; i2c_in = 1;
		end else if (i2c_scl && i2c_scl_d && !i2c_sda_d && i2c_sda) begin // STOP
			i2c_txt = {i2c_txt, " P"};
			if (i2c_lines < 400) begin $display("I2C %0s", i2c_txt); i2c_lines++; end
			i2c_txt = ""; i2c_in = 0;
		end else if (i2c_in && i2c_scl && !i2c_scl_d) begin               // bit
			i2c_sh = {i2c_sh[7:0], i2c_sda}; i2c_bits++;
			if (i2c_bits == 9) begin
				i2c_txt = {i2c_txt, $sformatf(" %02x%0s", i2c_sh[8:1], i2c_sh[0] ? "n" : "a")};
				i2c_bits = 0;
			end
		end
	end

	// ---------------- POKEY write log (+pokeylog) ----------------
	// Every CPU write to the POKEY at $4000 (mirrored through $7FFF), as
	// "ms register value", in pokey_writes.txt.
	int pk_fd = 0; logic [15:0] pk_old_a = 0; logic pk_old_w = 0;
	always @(posedge clk_sys) if (recording && pk_fd != 0) begin
		pk_old_a <= dut.bios_addr; pk_old_w <= !dut.RW;
		if (!dut.RW && dut.bios_addr[15:14] == 2'b01 && (dut.bios_addr != pk_old_a || !pk_old_w))
			begin $fdisplay(pk_fd, "%0d %x %02x", $time / 1000000, dut.bios_addr[3:0], dut.din); $fflush(pk_fd); end
	end

	// ---------------- SDRAM refresh coverage (+refreshstat) ----------------
	// The MiSTer sdram.sv never refreshes on a timer. A read of the same
	// 16 bit word as the previous request becomes an AUTO REFRESH (one row
	// from the chip's counter); any other read or write activates row
	// addr[13:1]. Per 64 ms: refresh commands issued, and rows (of 8192)
	// that were neither activated in the window nor could be covered.
	longint rf_last_t [8192];
	logic [23:0] rf_last_w = '1; logic rf_old_rd = 0;
	int rf_refresh = 0, rf_win = 0; longint rf_win_start = 0;
	initial for (int i = 0; i < 8192; i++) rf_last_t[i] = 0;
	always @(posedge clk_sdram) if (recording && $test$plusargs("refreshstat")) begin
		rf_old_rd <= dut.sdram.ch0_rd;
		if (dut.sdram.ch0_rd && !rf_old_rd) begin
			if (dut.sdram.ch0_addr[24:1] == rf_last_w) rf_refresh++;
			else rf_last_t[dut.sdram.ch0_addr[13:1]] = $time;
			rf_last_w <= dut.sdram.ch0_addr[24:1];
		end
		if ($time - rf_win_start >= 64000000) begin
			automatic int stale = 0;
			for (int i = 0; i < 8192; i++) if ($time - rf_last_t[i] > 64000000) stale++;
			if (rf_win < 400) $display("REFRESH window %0d (%0d ms): %0d auto refreshes, %0d rows not activated in 64 ms",
				rf_win, $time / 1000000, rf_refresh, stale);
			rf_win++; rf_refresh = 0; rf_win_start = $time;
		end
	end

	// ---------------- controller test probe (+inputtest) ----------------
	// input_test.py writes what it read to $90-$98 each frame, $98 last.
	logic [7:0] inres [0:8];
	logic [15:0] in_old_a = 0; logic in_old_w = 0;
	int in_frames = 0;
	always @(posedge clk_sys) begin
		in_old_a <= dut.bios_addr; in_old_w <= !dut.RW;
		if (!dut.RW && dut.bios_addr >= 16'h0090 && dut.bios_addr <= 16'h0098
			&& (dut.bios_addr != in_old_a || !in_old_w)) begin
			inres[dut.bios_addr - 16'h0090] <= dut.din;
			if (dut.bios_addr == 16'h0098) in_frames <= in_frames + 1;
		end
	end
	task automatic run_ms(int ms);
		repeat (longint'(14318) * ms) @(posedge clk_sys);
	endtask
	task automatic show(string what);
		$display("INPUT %-34s paddles %3d %3d %3d %3d  gun line %3d  SWCHA %08b  INPT4 %b INPT5 %b  (frame %0d)",
			what, inres[0], inres[1], inres[2], inres[3], inres[4], inres[5], inres[6][7], inres[7][7], in_frames);
	endtask
	// Driving: log each change of port 1's gray code while turning.
	logic [1:0] drv_last = 2'b11; string drv_seq = "";
	always @(posedge clk_sys) if (in_frames > 0 && inres[5][5:4] != drv_last) begin
		drv_last <= inres[5][5:4];
		if (drv_seq.len() < 60) drv_seq = {drv_seq, $sformatf("%0d", inres[5][5:4])};
	end

	// Turbo: count INPT4 changes (read live once a frame) while counting is on.
	logic fire_count_on = 0, fire_last = 1; int fire_changes = 0;
	always @(posedge clk_sys) if (fire_count_on && inres[6][7] != fire_last) begin
		fire_last <= inres[6][7]; fire_changes <= fire_changes + 1;
	end

	// ---------------- paddle trace (+padtrace, with wav) ----------------
	// Every 100 ms: paddle 0's timer calibration, the virtual knob, and the
	// last value the cart stored at +padvar=ADDR (Demons to Diamonds: $CD).
	int pad_var = 0; logic [7:0] pad_val = 0; int pad_reads = 0; logic old_pr = 0;
	initial void'($value$plusargs("padvar=%h", pad_var));
	always @(posedge clk_sys) begin
		if (!dut.RW && dut.bios_addr == pad_var[15:0] && pad_var != 0) pad_val <= dut.din;
		old_pr <= dut.i_read[0];
		if (dut.i_read[0] && !old_pr) pad_reads <= pad_reads + 1;
	end
	initial if ($test$plusargs("padtrace")) begin
		wait (recording);
		forever begin
			repeat (longint'(14318) * 100) @(posedge clk_sys);
			$display("PAD %5d ms: knob %3d  lowest %0d highest %0d difference %0d read_count %0d charged %b  reads/100ms %0d  cart var %0d",
				$time / 1000000, dut.vx_pos[0], dut.paddle[0].pt.lowest, dut.paddle[0].pt.highest,
				dut.paddle[0].pt.difference, dut.paddle[0].pt.read_count, dut.pad_wire[0], pad_reads, pad_val);
			pad_reads = 0;
		end
	end

	longint rises = 0;
	logic [15:0] old_aud = 0;
	logic counting = 0;
	always @(posedge clk_sys) begin
		old_aud <= AUDIO_L;
		if (counting && AUDIO_L > old_aud && old_aud == 16'd0)
			rises <= rises + 1;
	end

	logic [7:0] image [$];
	int fd, c, audf, mismatches;
	real measured, ideal;
	string path, save_path, sk_path, fw_path, image2_path;
	logic [7:0] fw_img [$];
	// What a firmware ROM should hold: the HSC keeps the last 4 KiB of its
	// payload (after an A78 header, if any), the Supercharger the first 2 KiB.
	function automatic logic [7:0] fw_expect(int slot, int i);
		int start, len;
		start = (fw_img.size() > 5 && fw_img[1] == "A" && fw_img[2] == "T" && fw_img[3] == "A"
			&& fw_img[4] == "R" && fw_img[5] == "I") ? 128 : 0;
		len = fw_img.size() - start;
		if (slot == 1) return i < fw_img.size() ? fw_img[i] : 8'h00;
		if (len >= 4096) return fw_img[start + len - 4096 + i];
		return i < len ? fw_img[start + i] : 8'h00;
	endfunction
	logic [7:0] sk_img [0:32767];
	bit have_sk = 0;
	int sk_diffs;
	logic [7:0] save_img [0:2047];
	bit have_save = 0;
	int save_diffs;

	initial begin
		if (!$value$plusargs("image=%s", path)) path = "load_test.a78";
		if (!$value$plusargs("audf=%d", audf)) audf = 7;
		fd = $fopen(path, "rb");
		if (fd == 0) begin $display("cannot open %s", path); $finish; end
		while ((c = $fgetc(fd)) != -1) image.push_back(c[7:0]);
		$fclose(fd);
		while (image.size() % 4) image.push_back(8'hFF);

		if ($test$plusargs("hsc_on")) hsc_setting = 2'd1;
		if ($test$plusargs("hsc_off")) hsc_setting = 2'd2;
		if ($test$plusargs("sk_on")) sk_setting = 2'd1;
		if ($test$plusargs("sk_auto")) sk_setting = 2'd0;
		// +sksave=FILE: write a 32 KiB SaveKey image through its save slot port.
		if ($value$plusargs("sksave=%s", sk_path)) begin
			fd = $fopen(sk_path, "rb");
			for (int i = 0; i < 32768; i++) begin c = $fgetc(fd); sk_img[i] = c[7:0]; end
			$fclose(fd);
			for (int i = 0; i < 8192; i++) begin
				@(posedge clk_74a);
				sk_addr = i[12:0];
				sk_din = {sk_img[4*i], sk_img[4*i+1], sk_img[4*i+2], sk_img[4*i+3]};
				sk_wr = 1'b1;
				@(posedge clk_74a);
				sk_wr = 1'b0;
			end
			have_sk = 1;
		end
		// +save=FILE: write a 2 KiB save through the save slot's bridge port
		// while the core is held in reset, as the Pocket does on a load.
		if ($value$plusargs("save=%s", save_path)) begin
			fd = $fopen(save_path, "rb");
			for (int i = 0; i < 2048; i++) begin c = $fgetc(fd); save_img[i] = c[7:0]; end
			$fclose(fd);
			for (int i = 0; i < 512; i++) begin
				@(posedge clk_74a);
				hsc_addr = i[8:0];
				hsc_din = {save_img[4*i], save_img[4*i+1], save_img[4*i+2], save_img[4*i+3]};
				hsc_wr = 1'b1;
				@(posedge clk_74a);
				hsc_wr = 1'b0;
				repeat (20) @(posedge clk_74a);
			end
			have_save = 1;
		end
		// +hscfw=FILE / +arfw=FILE: load the HSC firmware / Supercharger BIOS
		// through their data slots first, as the Pocket does at core start.
		for (int slot = 0; slot < 2; slot++)
			if ($value$plusargs(slot == 0 ? "hscfw=%s" : "arfw=%s", fw_path)) begin
				fw_img.delete();
				fd = $fopen(fw_path, "rb");
				c = $fgetc(fd);
				while (c != -1) begin fw_img.push_back(c[7:0]); c = $fgetc(fd); end
				$fclose(fd);
				while (fw_img.size() % 4) fw_img.push_back(8'h00);
				if (slot == 0) hscfw_download = 1'b1; else arfw_download = 1'b1;
				repeat (100) @(posedge clk_74a);
				for (int i = 0; i < fw_img.size(); i += 4) begin
					@(posedge clk_74a);
					bridge_addr = i;
					bridge_wr_data = {fw_img[i], fw_img[i+1], fw_img[i+2], fw_img[i+3]};
					bridge_wr = 1'b1;
					@(posedge clk_74a);
					bridge_wr = 1'b0;
					repeat (78) @(posedge clk_74a);
				end
				repeat (2000) @(posedge clk_74a);
				hscfw_download = 1'b0; arfw_download = 1'b0;
				repeat (100) @(posedge clk_sys);
				mismatches = 0;
				for (int i = 0; i < (slot == 0 ? 4096 : 2048); i++)
					if ((slot == 0 ? dut.main.cart.hsc_rom.u_ram.mem_q[i]
					               : dut.main.cart2600.mapper_AR.ar_rom.u_ram.mem_q[i[10:0]])
					    !== fw_expect(slot, i)) mismatches++;
				$display("FIRMWARE %0s: %0d byte file, %0d ROM bytes differ from it, hscfw_loaded=%0d",
					slot == 0 ? "HSC" : "Supercharger", fw_img.size(), mismatches, dut.hscfw_loaded);
			end
		repeat (100) @(posedge clk_74a);
		cart_download = 1'b1;
		repeat (100) @(posedge clk_74a);
		// One 32 bit bridge write every 80 clk_74a, big endian, as APF does.
		for (int i = 0; i < image.size(); i += 4) begin
			@(posedge clk_74a);
			bridge_addr = i;
			bridge_wr_data = {image[i], image[i+1], image[i+2], image[i+3]};
			bridge_wr = 1'b1;
			@(posedge clk_74a);
			bridge_wr = 1'b0;
			repeat (78) @(posedge clk_74a);
		end
		repeat (2000) @(posedge clk_74a);
		cart_download = 1'b0;
		repeat (100) @(posedge clk_sys);

		$display("HSC_EN %0d (setting %0d, firmware loaded %0d)", dut.hsc_en, hsc_setting, dut.hscfw_loaded);
		begin
			automatic int nz = 0;
			for (int i = 0; i < 2048; i++) if (dut.main.ram0.u_ram.mem_q[i] != 8'h00) nz++;
			$display("OPTIONS RAM0 bytes non-zero after load: %0d of 2048; 2600 mapper %0d (override %0d)",
				nz, dut.main.cart2600.mapper, bs_ovr);
		end
		// The payload (image minus its 128 byte header) must sit at SDRAM 0.
		mismatches = 0;
		if (dut.cart_is_7800) begin
			for (int i = 128; i < image.size(); i++)
				if (dut.sdram.mem[i - 128] !== image[i]) mismatches++;
		end else begin
			for (int i = 0; i < image.size(); i++)
				if (dut.sdram.mem[i] !== image[i]) mismatches++;
		end
		$display("LOAD %0d bytes, header %s, cart_is_7800=%0d, cart_size=%0d, tia_mode=%0d, payload mismatches=%0d",
			image.size(), dut.cart_header, dut.cart_is_7800, dut.cart_size, dut.tia_mode, mismatches);

		if (!have_save) begin
		// High score save, bridge side: a word written through the 32 bit port
		// must land as four bytes in address order and read back whole.
		@(posedge clk_74a); hsc_addr = 9'd5; hsc_din = 32'h11223344; hsc_wr = 1'b1;
		@(posedge clk_74a); hsc_wr = 1'b0;
		// APF read of word 5, then one more transaction to collect it
		repeat (4) @(posedge clk_74a); hsc_rd = 1'b1; @(posedge clk_74a); hsc_rd = 1'b0;
		@(posedge clk_74a); hsc_addr = 9'd6;
		repeat (4) @(posedge clk_74a);
		$display("HSC word 5 = %08x, bytes 20..23 = %02x %02x %02x %02x (expect 11223344 / 11 22 33 44)",
			hsc_dout, dut.hsc_ram.lane[0].ram.mem[5], dut.hsc_ram.lane[1].ram.mem[5],
			dut.hsc_ram.lane[2].ram.mem[5], dut.hsc_ram.lane[3].ram.mem[5]);

		end
		reset_in = 1'b0;
		if ($test$plusargs("inputtest")) begin
			// joy bits: 0 R, 1 L, 2 D, 3 U, 9 A, 10 B, 11 X (slow), 12 Y (fast)
			$display("INPUT port types: A %0d, B %0d, gun on port %0d", dut.porta_type, dut.portb_type, dut.gun_port + 1);
			run_ms(300);                          show("at rest");
			joy0[0] = 1; run_ms(150); joy0[0] = 0; run_ms(60); show("P1 right 150 ms");
			joy0[0] = 1; run_ms(1000); joy0[0] = 0; run_ms(60); show("P1 right 1 s (end stop)");
			joy0[1] = 1; run_ms(400); joy0[1] = 0; run_ms(60); show("P1 left 400 ms");
			joy0[1] = 1; joy0[11] = 1; run_ms(400); joy0 = 0; run_ms(60); show("P1 left 400 ms slow (X)");
			joy0[1] = 1; joy0[12] = 1; run_ms(400); joy0 = 0; run_ms(60); show("P1 left 400 ms fast (Y)");
			joy1[1] = 1; run_ms(300); joy1 = 0; run_ms(60); show("P2 left 300 ms");
			joy2[0] = 1; joy3[1] = 1; run_ms(300); joy2 = 0; joy3 = 0; run_ms(60); show("P3 right, P4 left 300 ms");
			joy0[9] = 1; joy1[10] = 1; run_ms(60); show("P1 A, P2 B held");
			joy0 = 0; joy1 = 0; run_ms(60); show("released");
			joy0[11] = 1; joy0[12] = 1; run_ms(60); show("P1 X, Y held");
			// Opposites: B (down) then X (up) on top, then all four, in the
			// order A, Y, B, X: the newest of each pair should win.
			joy0 = 0; joy0[10] = 1; run_ms(30); joy0[11] = 1; run_ms(60); show("P1 B then X held");
			joy0 = 0; joy0[9] = 1; run_ms(20); joy0[12] = 1; run_ms(20); joy0[10] = 1; run_ms(20);
			joy0[11] = 1; run_ms(60); show("P1 A, Y, B, X held (newest: Y, X)");
			joy0[11] = 0; run_ms(60); show("  ...X released (B again)");
			joy0 = 0; run_ms(30);
			// Turbo: X repeats fire 1 (A's) while held.
			joy0[11] = 1;
			fire_last = inres[6][7]; fire_changes = 0; fire_count_on = 1;
			run_ms(500);
			fire_count_on = 0; joy0 = 0; run_ms(60);
			$display("INPUT X held 500 ms (turbo %0d): fire 1 changed %0d times", turbo, fire_changes);
			// Analog stick on controller 1: push it right, then leave it.
			ana0[7:0] = 8'd224; run_ms(200); show("P1 stick right (x=224)");
			ana0[7:0] = 8'd128; run_ms(200); show("P1 stick centred");
			$display("INPUT driving gray sequence so far: %0s", drv_seq);
			drv_seq = "";
			joy0[1] = 1; run_ms(300); joy0 = 0; run_ms(60);
			$display("INPUT driving gray sequence turning left: %0s", drv_seq);
			// Light gun: move the crosshair down, then fire.
			joy0[2] = 1; run_ms(300); joy0 = 0; run_ms(60); show("gun down 300 ms");
			joy0[3] = 1; run_ms(1500); joy0 = 0; run_ms(60); show("gun up 1.5 s (top: off screen)");
			joy0[9] = 1; run_ms(60); show("trigger (A) held");
			joy0 = 0; run_ms(60);
			$finish;
		end
		if ($value$plusargs("wav=%d", wav_ms)) begin
			// Raw 16 bit little endian mono, 48052 Hz; wrapped as WAV afterwards.
			wav_raw = $fopen("audio_raw.pcm", "wb");
			wav_filt = $fopen("audio_filt.pcm", "wb");
			// +fire: press fire 1 at 300 ms for 100 ms (menus that wait for it)
			// +fireat=MS / +fireat2=MS: press fire at MS for 150 ms (with wav);
			// two presses for games with a title screen and then a menu.
			if ($value$plusargs("fireat2=%d", fire_at2)) fork
				begin
					repeat (longint'(14318) * fire_at2) @(posedge clk_sys);
					joy0[4] = 1'b1;
					repeat (longint'(14318) * 150) @(posedge clk_sys);
					joy0[4] = 1'b0;
				end
			join_none
			if ($value$plusargs("fireat=%d", fire_at)) fork
				begin
					repeat (longint'(14318) * fire_at) @(posedge clk_sys);
					joy0[4] = 1'b1;
					repeat (longint'(14318) * 150) @(posedge clk_sys);
					joy0[4] = 1'b0;
				end
			join_none
			// +holdright=MS: hold the D-pad right for 1 s from MS, then left.
			if ($value$plusargs("holdright=%d", fire_at)) fork
				begin
					repeat (longint'(14318) * fire_at) @(posedge clk_sys);
					joy0[0] = 1'b1;
					repeat (longint'(14318) * 1000) @(posedge clk_sys);
					joy0[0] = 1'b0; joy0[1] = 1'b1;
					repeat (longint'(14318) * 600) @(posedge clk_sys);
					joy0[1] = 1'b0;
				end
			join_none
			if ($test$plusargs("fire")) fork
				begin
					repeat (longint'(14318) * 300) @(posedge clk_sys);
					joy0[4] = 1'b1;
					repeat (longint'(14318) * 100) @(posedge clk_sys);
					joy0[4] = 1'b0;
				end
			join_none
			// +image2=FILE +image2at=MS: load a second cart MS into the run,
			// as picking another game on the Pocket does (no reset_in).
			if ($value$plusargs("image2=%s", image2_path)) fork
				begin
					automatic logic [7:0] img2 [$];
					automatic int f2, c2;
					automatic int at = 0;
					void'($value$plusargs("image2at=%d", at));
					f2 = $fopen(image2_path, "rb");
					while ((c2 = $fgetc(f2)) != -1) img2.push_back(c2[7:0]);
					$fclose(f2);
					while (img2.size() % 4) img2.push_back(8'hFF);
					repeat (longint'(14318) * at) @(posedge clk_sys);
					@(posedge clk_74a); cart_download = 1'b1;
					repeat (100) @(posedge clk_74a);
					for (int i = 0; i < img2.size(); i += 4) begin
						@(posedge clk_74a);
						bridge_addr = i;
						bridge_wr_data = {img2[i], img2[i+1], img2[i+2], img2[i+3]};
						bridge_wr = 1'b1;
						@(posedge clk_74a);
						bridge_wr = 1'b0;
						repeat (78) @(posedge clk_74a);
					end
					repeat (2000) @(posedge clk_74a);
					cart_download = 1'b0;
					$display("IMAGE2 %s loaded at %0d ms: %0d bytes, tia_mode=%0d, mapper %0d",
						image2_path, $time / 1000000, img2.size(), dut.tia_mode, dut.main.cart2600.mapper);
				end
			join_none
			recording = 1;
			i2c_on = $test$plusargs("i2ctrace");
			if ($test$plusargs("pokeylog")) pk_fd = $fopen("pokey_writes.txt", "w");
			// +dumpat=MS +dump=N: capture N frames starting MS into the recording
			if ($value$plusargs("dumpat=%d", dump_at)) fork
				begin
					repeat (longint'(14318) * dump_at) @(posedge clk_sys);
					void'($value$plusargs("dump=%d", dump_frames));
					capture = 1;
				end
			join_none
			repeat (longint'(14318) * wav_ms) @(posedge clk_sys);
			recording = 0;
			$fclose(wav_raw); $fclose(wav_filt);
			$display("WAV recorded %0d ms", wav_ms);
			$display("PROBE NMIs %0d, main-loop writes to $41 %0d, POKEY AUDF1 writes %0d",
				nmis, main_writes, audf_writes);
			$display("DEVICES hsc_en %0d use_sk %0d; HSC RAM writes %0d reads %0d, HSC ROM reads %0d; SaveKey SCL edges %0d, EEPROM bytes written %0d",
				dut.hsc_en, dut.use_sk, hsc_ram_wr, hsc_ram_rd, hsc_rom_rd, scl_edges, sk_bytes);
			$finish;
		end
		repeat (14318181 / 10) @(posedge clk_sys);
		counting = 1;
		if ($value$plusargs("dump=%d", dump_frames)) capture = 1;
		repeat (14318181 / 5) @(posedge clk_sys);
		counting = 0;
		measured = rises * 5.0;
		ideal = 3579545.0 / 114.0 / (audf + 1) / 2.0;
		$display("TONE from loaded cart AUDF0=%0d: measured %.1f Hz, TIA reference %.1f Hz, ratio %.3f",
			audf, measured, ideal, measured / ideal);
		if (have_save) begin
			// Read it back the way the Pocket saves it. APF read transaction:
			// the address is set, the data is sampled four clk_74a later, then
			// bridge_rd pulses. The word sampled in transaction k belongs to
			// the address of transaction k-1, so saving 512 words takes 513
			// transactions (the last address wraps to word 0).
			save_diffs = 0;
			for (int t = 0; t <= 512; t++) begin
				logic [31:0] got;
				@(posedge clk_74a); hsc_addr = t[8:0];
				repeat (4) @(posedge clk_74a);
				got = hsc_dout;
				hsc_rd = 1'b1; @(posedge clk_74a); hsc_rd = 1'b0;
				repeat (2) @(posedge clk_74a);
				if (t > 0)
					for (int k = 0; k < 4; k++)
						if (got[31 - 8*k -: 8] !== save_img[4*(t-1) + k]) begin
							if (save_diffs < 8)
								$display("  HSC byte %03x ($%04x): saved %02x, read back %02x", 4*(t-1) + k,
									16'h1000 + 4*(t-1) + k, save_img[4*(t-1) + k], got[31 - 8*k -: 8]);
							save_diffs++;
						end
			end
			$display("SAVE after load, reset and 300 ms of running: %0d of 2048 bytes differ from the save file", save_diffs);
		end
		if (have_sk) begin
			// Same APF read protocol as the HSC: 8193 transactions for 8192 words.
			sk_diffs = 0;
			for (int t = 0; t <= 8192; t++) begin
				logic [31:0] got;
				@(posedge clk_74a); sk_addr = t[12:0];
				repeat (4) @(posedge clk_74a);
				got = sk_dout;
				sk_rd = 1'b1; @(posedge clk_74a); sk_rd = 1'b0;
				if (t > 0)
					for (int k = 0; k < 4; k++)
						if (got[31 - 8*k -: 8] !== sk_img[4*(t-1) + k]) begin
							if (sk_diffs < 8)
								$display("  SaveKey byte %04x: saved %02x, read back %02x", 4*(t-1) + k,
									sk_img[4*(t-1) + k], got[31 - 8*k -: 8]);
							sk_diffs++;
						end
			end
			$display("SAVEKEY save after load, reset and running: %0d of 32768 bytes differ from the save file", sk_diffs);
		end
		if ($test$plusargs("skcheck")) begin
			// What the test cart wrote over I2C must be in the RAM that gets
			// saved: EEPROM $1234..$123B, read through the save slot port.
			logic [7:0] exp [8] = '{8'hA5, 8'h5A, 8'h01, 8'h02, 8'h80, 8'h7F, 8'hFF, 8'h00};
			logic [7:0] got8 [8];
			for (int t = 0; t < 3; t++) begin      // words $48D, $48E, then collect
				logic [31:0] got;
				@(posedge clk_74a); sk_addr = 13'h48D + t;
				repeat (4) @(posedge clk_74a);
				got = sk_dout;
				sk_rd = 1'b1; @(posedge clk_74a); sk_rd = 1'b0;
				if (t > 0) for (int k = 0; k < 4; k++) got8[4*(t-1) + k] = got[31 - 8*k -: 8];
			end
			sk_diffs = 0;
			for (int k = 0; k < 8; k++) if (got8[k] !== exp[k]) sk_diffs++;
			$display("SAVEKEY EEPROM $1234..$123B in the save RAM: %02x %02x %02x %02x %02x %02x %02x %02x (%0s)",
				got8[0], got8[1], got8[2], got8[3], got8[4], got8[5], got8[6], got8[7],
				sk_diffs == 0 ? "matches what the cart wrote" : "MISMATCH");
		end
		$finish;
	end
endmodule
