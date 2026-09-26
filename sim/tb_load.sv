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
	logic [8:0] hsc_addr = 0; logic hsc_wr = 0; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic cart_download = 1'b0;
	logic [15:0] joy0 = 16'd0;
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

	// ---------------- system ----------------
	wire [7:0] R, G, B;
	wire HSync, VSync, HBlank, VBlank, ce_pix, tia_mode, is_pal;
	wire [15:0] AUDIO_L, AUDIO_R, SDRAM_DQ;

	atari7800_pocket dut (
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(1'b1), .reset_in(reset_in),
		.cart_download(cart_download), .bios_download(1'b0),
		.ioctl_wr(ioctl_wr & cart_download), .ioctl_addr(ioctl_addr[24:0]), .ioctl_dout(ioctl_dout),
		.region_setting(2'd0), .palette_temp(2'd0), .hsc_setting(hsc_setting), .show_overscan(1'b0),
		.hide_border(1'b0), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(1'b0), .pokey_irq(1'b0), .pause_core(1'b0),
		.joy0(joy0), .joy1(16'd0),
		.R(R), .G(G), .B(B), .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
		.ce_pix(ce_pix), .tia_mode_o(tia_mode), .is_pal_o(is_pal),
		.AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R),
		.clk_74a(clk_74a), .hsc_bridge_addr(hsc_addr), .hsc_bridge_wr(hsc_wr), .hsc_bridge_din(hsc_din),
		.hsc_bridge_dout(hsc_dout), .hsc_active(),
		.SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(), .SDRAM_DQMH(),
		.SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_CLK(), .SDRAM_CKE()
	);

	// ---------------- frame capture (+dump=N: write N frames as PPM) --------
	int dump_frames = 0, dumped = 0, fx = 0, fy = 0, line_px = 0;
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
	string path, save_path;
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
		repeat (2) @(posedge clk_74a);
		$display("HSC word 5 = %08x, bytes 20..23 = %02x %02x %02x %02x (expect 11223344 / 11 22 33 44)",
			hsc_dout, dut.hsc_ram.lane[0].ram.mem[5], dut.hsc_ram.lane[1].ram.mem[5],
			dut.hsc_ram.lane[2].ram.mem[5], dut.hsc_ram.lane[3].ram.mem[5]);

		end
		reset_in = 1'b0;
		if ($value$plusargs("wav=%d", wav_ms)) begin
			// Raw 16 bit little endian mono, 48052 Hz; wrapped as WAV afterwards.
			wav_raw = $fopen("audio_raw.pcm", "wb");
			wav_filt = $fopen("audio_filt.pcm", "wb");
			// +fire: press fire 1 at 300 ms for 100 ms (menus that wait for it)
			if ($test$plusargs("fire")) fork
				begin
					repeat (longint'(14318) * 300) @(posedge clk_sys);
					joy0[4] = 1'b1;
					repeat (longint'(14318) * 100) @(posedge clk_sys);
					joy0[4] = 1'b0;
				end
			join_none
			recording = 1;
			repeat (longint'(14318) * wav_ms) @(posedge clk_sys);
			recording = 0;
			$fclose(wav_raw); $fclose(wav_filt);
			$display("WAV recorded %0d ms", wav_ms);
			$display("PROBE NMIs %0d, main-loop writes to $41 %0d, POKEY AUDF1 writes %0d",
				nmis, main_writes, audf_writes);
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
			// Read it back the way the Pocket saves it: through the bridge port.
			save_diffs = 0;
			for (int w = 0; w < 512; w++) begin
				@(posedge clk_74a); hsc_addr = w[8:0];
				repeat (3) @(posedge clk_74a);
				for (int k = 0; k < 4; k++)
					if (hsc_dout[31 - 8*k -: 8] !== save_img[4*w + k]) begin
						if (save_diffs < 8)
							$display("  HSC byte %03x ($%04x): saved %02x, now %02x", 4*w + k,
								16'h1000 + 4*w + k, save_img[4*w + k], hsc_dout[31 - 8*k -: 8]);
						save_diffs++;
					end
			end
			$display("SAVE after load, reset and 300 ms of running: %0d of 2048 bytes differ from the save file", save_diffs);
		end
		$finish;
	end
endmodule
