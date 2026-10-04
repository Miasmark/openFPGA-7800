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
	// Both clocks step from one rounded half period, so clk_sys is exactly
	// 4 x clk_sdram as the PLL makes it. T_SYS / 8 and T_SYS / 2 round to
	// different picoseconds (8.730 vs 34.921 ns); the clocks then drifted,
	// and now and then the clk_sys register missed one of the loader's
	// four-clk_sdram strobes and dropped a cartridge byte.
	localparam real T_HALF_SDRAM = 8.730;
	always #(T_HALF_SDRAM) clk_sdram = ~clk_sdram;
	always #(4 * T_HALF_SDRAM) clk_sys = ~clk_sys;
	always #6.734 clk_74a = ~clk_74a;
`ifdef POCKET_BUPCHIP
	// clk_arm, the BupChip's: exactly 2 x clk_sys, edge aligned, as the PLL
	// makes it (counter[3]).
	logic clk_arm = 1'b1;
	always #(2 * T_HALF_SDRAM) clk_arm = ~clk_arm;
`endif

	logic reset_in = 1'b1;
	logic [8:0] hsc_addr = 0; logic hsc_wr = 0; logic hsc_rd = 0;
	logic [1:0] sk_setting = 2'd2; logic [12:0] sk_addr = 0; logic sk_wr = 0, sk_rd = 0;
	logic [31:0] sk_din = 0; wire [31:0] sk_dout; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic cart_download = 1'b0;
	logic hscfw_download = 1'b0, arfw_download = 1'b0, bupfw_download = 1'b0;
	logic pokey_irq_on = 1'b0;
	logic overscan_on = 1'b0;
	logic clear_rnd = 1'b0; logic [4:0] bs_ovr = 5'd0;   // +clearrnd, +bs=N
	initial begin
		clear_rnd = $test$plusargs("clearrnd");
		void'($value$plusargs("bs=%d", bs_ovr));
	end
	initial overscan_on = $test$plusargs("overscan");
	logic blend_on = 1'b0;                                // +blend: 2600 Flicker Blend
	initial blend_on = $test$plusargs("blend");
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
	logic [2:0] ioctl_hi_r = 0;	// POCKET_BUPCHIP: bits 27:25, which slot's address
	always @(posedge clk_sys) begin
		ioctl_wr_r <= ioctl_wr; ioctl_addr_r <= ioctl_addr[24:0]; ioctl_dout_r <= ioctl_dout;
		ioctl_hi_r <= ioctl_addr[27:25];
	end

	// ---------------- system ----------------
	wire [7:0] R, G, B;
	wire HSync, VSync, HBlank, VBlank, ce_pix, tia_mode, is_pal;
	wire [15:0] AUDIO_L, AUDIO_R, SDRAM_DQ;

	// The Pocket's SRAM (POCKET_SRAM builds use it; otherwise it stays idle)
	wire [16:0] SRAM_A; wire [15:0] SRAM_DQ;
	wire SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;
	sram_model sram_chip (.a(SRAM_A), .dq(SRAM_DQ), .oe_n(SRAM_OE_N), .we_n(SRAM_WE_N),
		.ub_n(SRAM_UB_N), .lb_n(SRAM_LB_N));

`ifdef POCKET_BUPCHIP
	// PSRAM cram0 (the BupChip's assets): bupchip/s4/psram_model.sv, which
	// checks every access against the datasheet's timing.
	wire [21:16] cram0_a; wire [15:0] cram0_dq;
	wire cram0_wait, cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n;
	wire cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n;
	psram_model cram0_chip (.cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait),
		.cram_clk(cram0_clk), .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre),
		.cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n), .cram_oe_n(cram0_oe_n),
		.cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n));
`endif

	atari7800_pocket dut (
`ifdef POCKET_BUPCHIP
		.clk_arm(clk_arm), .bupfw_download(bupfw_download), .ioctl_wr_any(ioctl_wr_r), .ioctl_hi(ioctl_hi_r),
		.cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
		.cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n),
		.cram0_ce1_n(cram0_ce1_n), .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
		.cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
`endif
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(1'b1), .pll_busy(1'b0), .reset_in(reset_in),
		.cart_download(cart_download), .bios_download(1'b0),
		.hscfw_download(hscfw_download), .arfw_download(arfw_download),
		.ioctl_wr(ioctl_wr_r & (cart_download | hscfw_download | arfw_download | bupfw_download)), .ioctl_addr(ioctl_addr_r), .ioctl_dout(ioctl_dout_r),
		.region_setting(2'd0), .palette_temp(2'd0), .hsc_setting(hsc_setting), .show_overscan(overscan_on),
		.hide_border(1'b0), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(blend_on), .pokey_irq(pokey_irq_on), .pause_core(1'b0),
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
		.SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_CLK(), .SDRAM_CKE(),
		.SRAM_A(SRAM_A), .SRAM_DQ(SRAM_DQ), .SRAM_OE_N(SRAM_OE_N), .SRAM_WE_N(SRAM_WE_N),
		.SRAM_UB_N(SRAM_UB_N), .SRAM_LB_N(SRAM_LB_N)
	);

	// ---------------- frame capture (+dump=N: write N frames as PPM) --------
	int dump_frames = 0, dumped = 0, fx = 0, fy = 0, line_px = 0, dump_at = 0, fire_at = 0, fire_at2 = 0, reset_at = 0;
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
	string ar_dump;
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
	// The bus over the last 64 clk, dumped at the first two wrong arrivals.
	typedef struct packed { logic p1, p0, rw, cs, halt_n; logic [15:0] a; logic [7:0] d; logic [15:0] awr; } bus_t;
	bus_t sh_ring [64]; int sh_ri = 0, sh_dumps = 0;
	always @(posedge clk_sys) begin
		sh_ring[sh_ri] <= '{dut.main.cart.pclk1, dut.main.cart.pclk0, dut.main.cart.rw, dut.main.cart.pokey_cs,
			dut.main.cart.halt_n, dut.main.cart.address_in, dut.main.cart.din, dut.main.cart.shadow_pokey.u_pokey.addr_wr};
		sh_ri <= (sh_ri + 1) % 64;
	end
	task automatic dump_ring();
		if (sh_dumps >= 2) return;
		sh_dumps++;
		$display("BUS dump, oldest first: clk p1 p0 rw cs halt_n addr  data  shadow_strobes");
		for (int k = 0; k < 64; k++) begin
			automatic bus_t e = sh_ring[(sh_ri + k) % 64];
			$display("BUS %3d  %b  %b  %b  %b  %b    %04x  %02x    %04x", k - 63, e.p1, e.p0, e.rw, e.cs, e.halt_n, e.a, e.d, e.awr);
		end
	endtask

	// ---------------- shadow POKEY write check ----------------
	// Every CPU write to the POKEY (pokey_cs and a write at phase 2) must
	// show up inside the shadow as that register's write strobe, carrying the
	// written byte. Reports writes that never arrive, arrive wrong, or arrive
	// unasked, with the phase 1 -> phase 2 spacing of the CPU cycle.
	`define SHP dut.main.cart.shadow_pokey.u_pokey
	longint sh_clk = 0, sh_last_p1 = 0, sh_ok = 0, sh_bad = 0, sh_lost = 0, sh_extra = 0;
	logic [15:0] sh_wr_d = 0;
	logic        sh_pend = 0; logic [3:0] sh_reg; logic [7:0] sh_val; longint sh_at = 0, sh_sp = 0;
	int sh_shown = 0;
	always @(posedge clk_sys) begin
		sh_clk <= sh_clk + 1;
		if (dut.main.cart.pclk1) sh_last_p1 <= sh_clk;
		sh_wr_d <= `SHP.addr_wr;
		// a strobe rising in the shadow
		// (the adapter's own SKCTL writes around reset are expected)
		for (int i = 0; i < 16; i++) if (`SHP.addr_wr[i] && !sh_wr_d[i] && !dut.main.cart.shadow_pokey.boot_wr) begin
			if (sh_pend && i == sh_reg && `SHP.write_data == sh_val) begin sh_ok++; sh_pend = 0; end
			else begin
				if (sh_pend) begin sh_bad++; dump_ring(); if (sh_shown < 30) begin sh_shown++;
					$display("SHADOW %0d ms: CPU wrote %x <- %02x (p1->p2 %0d clk), shadow strobed %x <- %02x",
						$time / 1000000, sh_reg, sh_val, sh_sp, i, `SHP.write_data); end
					sh_pend = 0; end
				else begin sh_extra++; if (sh_shown < 30) begin sh_shown++;
					$display("SHADOW %0d ms: unasked strobe %x <- %02x", $time / 1000000, i, `SHP.write_data); end end
			end
		end
		// a CPU write cycle to the POKEY, at its phase 2
		if (dut.main.cart.pclk0 && dut.main.cart.pokey_cs && !dut.main.cart.rw) begin
			if (sh_pend) begin sh_lost++; if (sh_shown < 30) begin sh_shown++;
				$display("SHADOW %0d ms: write %x <- %02x never reached the shadow (p1->p2 %0d clk)",
					$time / 1000000, sh_reg, sh_val, sh_sp); end end
			sh_pend = 1; sh_reg = dut.main.cart.address_in[3:0]; sh_val = dut.main.cart.din;
			sh_at = sh_clk; sh_sp = sh_clk - sh_last_p1;
		end
		if (sh_pend && sh_clk - sh_at > 48) begin
			sh_lost++; if (sh_shown < 30) begin sh_shown++;
			$display("SHADOW %0d ms: write %x <- %02x never reached the shadow (p1->p2 %0d clk)",
				$time / 1000000, sh_reg, sh_val, sh_sp); end
			sh_pend = 0;
		end
	end
	final $display("SHADOW writes: %0d arrived, %0d arrived wrong, %0d lost, %0d unasked", sh_ok, sh_bad, sh_lost, sh_extra);


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

	// ---------------- Supercharger probe (+arprobe) ----------------
	// Tape starts and ends (mapper_AR's playback, with the image it plays),
	// and 2600 writes to COLUBK and AUDF0 that change the value (ar_test.py's
	// loads each set their own).
	logic ar_probe = 1'b0, old_play = 1'b0, old_tiawr = 1'b0;
	logic [7:0] last_colubk = 8'hxx, last_audf0 = 8'hxx, tia_d = 0;
	logic [5:0] tia_a = 0;
	initial ar_probe = $test$plusargs("arprobe");
	always @(posedge clk_sys) if (ar_probe && dut.tia_mode) begin
		old_play <= dut.main.cart2600.mapper_AR.playback;
		if (dut.main.cart2600.mapper_AR.playback != old_play)
			$display("AR %0d ms: tape %0s, image %0d", $time / 1000000,
				old_play ? "stops" : "starts", dut.main.cart2600.mapper_AR.tape_num);
		// Logged at the end of the write cycle, when the data is settled.
		old_tiawr <= !dut.RW && !dut.bios_addr[12] && !dut.bios_addr[7];
		tia_a <= dut.bios_addr[5:0]; tia_d <= dut.main.write_DB;
		if (old_tiawr && !(!dut.RW && !dut.bios_addr[12] && !dut.bios_addr[7])) begin
			if (tia_a == 6'h09 && tia_d !== last_colubk) begin
				last_colubk <= tia_d;
				$display("AR %0d ms: COLUBK = $%02x", $time / 1000000, tia_d);
			end
			if (tia_a == 6'h17 && tia_d !== last_audf0) begin
				last_audf0 <= tia_d;
				$display("AR %0d ms: AUDF0 = %0d", $time / 1000000, tia_d);
			end
		end
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

	// ---------------- joystick script (+joyscript=FILE) ----------------
	// Drives joy0 from reset on. Each line "MS HEX" sets joy0 to HEX from MS
	// ms after reset (atari7800_pocket.sv's bits: 0 right, 1 left, 2 down,
	// 3 up, 9 A, 10 B); "MS dump" writes the next whole frame as
	// frame_NNN.ppm (numbered from 0 in script order). # starts a comment.
	longint t_run = 0;
	initial begin
		automatic string jpath, line, word;
		automatic int jf, ms, at = 0;
		wait (reset_in == 1'b0);
		t_run = $time;
		if ($value$plusargs("joyscript=%s", jpath)) begin
			jf = $fopen(jpath, "r");
			if (jf == 0) begin $display("cannot open %s", jpath); $finish; end
			capture = 1;                     // fb always holds the last whole frame
			while ($fgets(line, jf) > 0) begin
				if ($sscanf(line, "%d %s", ms, word) != 2 || word.substr(0, 0) == "#") continue;
				for (; at < ms; at++) repeat (14318) @(posedge clk_sys);
				if (word == "dump") dump_frames = dumped + 1;
				else joy0 = 16'(word.atohex());
			end
			$fclose(jf);
		end
	end

`ifdef POCKET_BUPCHIP
	// ---------------- BupChip (POCKET_BUPCHIP; +bupfw, +bupms) ----------------
	// Every frame the firmware pushes, and every frame returned to clk_sys, go
	// to +bupout=PREFIX (PREFIX.pcm, PREFIX.out.pcm: 48 kHz stereo s16le, as
	// sim/bupchip/s4 writes them), with the song's start in each (the frames
	// pushed when the firmware takes the command) for pcm_check.py. Underflows
	// (a pop with no frame), overflows (a push into a full FIFO) and the lowest
	// FIFO level once the song has started are counted here, from the
	// peripheral's own signals.
	string  bup_out;
	int     bup_fd = 0, bup_ofd = 0, bup_minlev = 1 << 30, bup_ms = 0, bup_dump_at = 0;
	longint bup_pushes = 0, bup_pops = 0, bup_song = -1, bup_outs = 0, bup_out_song = -1;
	longint bup_under = 0, bup_over = 0, bup_out_nz = 0, bup_mix_nz = 0;
	bit     bup_mark = 0;
	always @(posedge clk_arm) begin
		if (dut.bupchip.reg_sel && dut.bupchip.reg_write && dut.bupchip.reg_addr == 8'h10) begin
			bup_pushes++;
			if (bup_fd != 0) $fwrite(bup_fd, "%c%c%c%c", dut.bupchip.reg_wdata[7:0], dut.bupchip.reg_wdata[15:8],
				dut.bupchip.reg_wdata[23:16], dut.bupchip.reg_wdata[31:24]);
		end
		if (dut.bupchip.per.cmd_pop && bup_song < 0) bup_song = bup_pushes;
		if (dut.bupchip.per.pcm_push && dut.bupchip.per.pcm_full) bup_over++;
		if (dut.bupchip.pcm_pop) begin
			if (!dut.bupchip.pcm_available) bup_under++;
			if (bup_pops == bup_song) bup_mark = 1;    // this tick plays the song's first frame
			bup_pops++;
		end
		if (bup_song >= 0 && dut.bupchip.pcm_enabled && int'(dut.bupchip.per.pcm_level) < bup_minlev)
			bup_minlev = int'(dut.bupchip.per.pcm_level);
	end
	always @(posedge clk_sys) begin
		if (dut.bupchip.frame_cap) begin
			if (bup_mark && bup_out_song < 0) bup_out_song = bup_outs;
			bup_mark = 0;
			bup_outs++;
			if (dut.bupchip.frame_arm != 32'd0) bup_out_nz++;
			if (bup_ofd != 0) $fwrite(bup_ofd, "%c%c%c%c", dut.bupchip.frame_arm[7:0], dut.bupchip.frame_arm[15:8],
				dut.bupchip.frame_arm[23:16], dut.bupchip.frame_arm[31:24]);
		end
		// What reaches top.sv's mixer (0 is $8000 there)
		if (dut.main.bupchip_mix_l != 16'h8000 && dut.main.bupchip_mix_l != 16'h0000) bup_mix_nz++;
	end
	initial if ($value$plusargs("bupout=%s", bup_out)) begin
		bup_fd = $fopen({bup_out, ".pcm"}, "wb");
		bup_ofd = $fopen({bup_out, ".out.pcm"}, "wb");
	end
	// +bupcmdlog: each command as the cartridge sends it ($8007 pair, at
	// clk_sys) and as the firmware takes it (a read of 0x04), with the frames
	// pushed so far, in ms since reset.
	bit bup_cmdlog = 0;
	initial bup_cmdlog = $test$plusargs("bupcmdlog");
	always @(posedge clk_sys) if (bup_cmdlog && dut.bup_cmd_valid)
		$display("BUPCMD sent  $%02x at %0.1f ms", dut.bup_cmd_data, real'($time - t_run) / 1.0e6);
	always @(posedge clk_arm) if (bup_cmdlog && dut.bupchip.per.cmd_pop)
		$display("BUPCMD taken $%02x at %0.1f ms, pushed %0d", dut.bupchip.per.reg_rdata[7:0],
			real'($time - t_run) / 1.0e6, bup_pushes);
`endif

	logic [7:0] image [$];
	int image_n = 0;
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

`ifdef POCKET_BUPCHIP
	// +bupfw=FILE: the BupChip firmware (bupchip.bin) through its data slot
	// (0x109, bridge address 0x0A000000), before the cartridge, or after it
	// with +bupfwlast, which is the Pocket's order (data.json's). Its ROM
	// must then hold the file, word w = bytes 4w..4w+3 little-endian,
	// zero-padded.
	task automatic load_bupfw();
		int n;
		if ($value$plusargs("bupfw=%s", fw_path)) begin
			fw_img.delete();
			fd = $fopen(fw_path, "rb");
			if (fd == 0) begin $display("cannot open %s", fw_path); $finish; end
			c = $fgetc(fd);
			while (c != -1) begin fw_img.push_back(c[7:0]); c = $fgetc(fd); end
			$fclose(fd);
			n = fw_img.size();
			while (fw_img.size() % 4) fw_img.push_back(8'h00);
			bupfw_download = 1'b1;
			repeat (100) @(posedge clk_74a);
			for (int i = 0; i < fw_img.size(); i += 4) begin
				@(posedge clk_74a);
				bridge_addr = 32'h0A000000 + i;
				bridge_wr_data = {fw_img[i], fw_img[i+1], fw_img[i+2], fw_img[i+3]};
				bridge_wr = 1'b1;
				@(posedge clk_74a);
				bridge_wr = 1'b0;
				repeat (78) @(posedge clk_74a);
			end
			repeat (2000) @(posedge clk_74a);
			bupfw_download = 1'b0;
			repeat (100) @(posedge clk_sys);
			mismatches = 0;
			for (int w = 0; w < 4096; w++) begin
				automatic logic [31:0] e = 4 * w < fw_img.size() ?
					{fw_img[4*w+3], fw_img[4*w+2], fw_img[4*w+1], fw_img[4*w]} : 32'd0;
				if (dut.bupchip.rom.mem_q[w] !== e) mismatches++;
			end
			$display("BUPCHIP firmware slot: %0d byte file, %0d of 4096 ROM words differ from it, fw_loaded=%0d",
				n, mismatches, dut.bupchip.fw_loaded);
		end
	endtask
`endif

	initial begin
		if (!$value$plusargs("image=%s", path)) path = "load_test.a78";
		if (!$value$plusargs("audf=%d", audf)) audf = 7;
		fd = $fopen(path, "rb");
		if (fd == 0) begin $display("cannot open %s", path); $finish; end
		while ((c = $fgetc(fd)) != -1) image.push_back(c[7:0]);
		$fclose(fd);
		image_n = image.size();
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
				// The APF sends a word about every 75 clk_74a (see data_loader.sv);
				// the SRAM SaveKey (POCKET_SRAM) relies on that spacing.
				repeat (73) @(posedge clk_74a);
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
`ifdef POCKET_BUPCHIP
		if (!$test$plusargs("bupfwlast")) load_bupfw();
`endif
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
`ifdef POCKET_BUPCHIP
		if ($test$plusargs("bupfwlast")) begin
			repeat (100) @(posedge clk_74a);
			load_bupfw();
		end
`endif

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
				if (dut.sdram.mem[i - 128] !== image[i]) begin
					if (mismatches < 4) $display("  payload byte %0d: SDRAM %02x, image %02x", i - 128, dut.sdram.mem[i - 128], image[i]);
					mismatches++;
				end
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
`ifdef POCKET_BUPCHIP
		// +bupms=MS: run MS ms with the BupChip watched, then report. The
		// ARSC block (from 128 + the header's ROM size) must be in the PSRAM
		// model. +bupdumpat=MS +dump=N: N frames from MS into the run.
		if ($value$plusargs("bupms=%d", bup_ms)) begin
			automatic longint decl = {image[49], image[50], image[51], image[52]};
			automatic int arsc_bad = 0, arsc_n = 0;
			if ($value$plusargs("bupdumpat=%d", bup_dump_at)) fork
				begin
					repeat (longint'(14318) * bup_dump_at) @(posedge clk_sys);
					void'($value$plusargs("dump=%d", dump_frames));
					capture = 1;
				end
			join_none
			if (dut.cart_is_7800 && decl > 0)
				for (longint b = 128 + decl; b < image_n; b++) begin
					automatic logic [15:0] h = cram0_chip.bd_read(0, int'((b - 128 - decl) >> 1));
					arsc_n++;
					if (((b - 128 - decl) & 1 ? h[15:8] : h[7:0]) !== image[b]) arsc_bad++;
				end
			for (int ms_i = 0; ms_i < bup_ms; ms_i++) repeat (14318) @(posedge clk_sys);
			if (bup_fd != 0) begin $fclose(bup_fd); $fclose(bup_ofd); end
			$display("BUPCHIP ARSC: %0d bytes in the PSRAM, %0d differ from the file; asset_size %0d, asset_ready %0d",
				arsc_n, arsc_bad, dut.bupchip.asset_size, dut.bupchip.asset_ready);
			$display("BUPCHIP song start: pushed %0d, output %0d", bup_song, bup_out_song);
			$display("BUPCHIP result: fw_loaded=%0d asset_ready=%0d cpu_run=%0d halted=%0d halt_code=%0d halt_pc=%08x fault=%02x muted=%0d pushed=%0d pops=%0d under=%0d over=%0d minlev=%0d out=%0d out_nz=%0d mix_nz=%0d arsc_bad=%0d psram_viol=%0d",
				dut.bupchip.fw_loaded, dut.bupchip.asset_ready, dut.bupchip.cpu_run, dut.bupchip.halted,
				dut.bupchip.halt_code, dut.bupchip.halt_pc, dut.bupchip.fault_code, dut.bupchip.muted,
				bup_pushes, bup_pops, bup_under, bup_over, bup_minlev == (1 << 30) ? -1 : bup_minlev,
				bup_outs, bup_out_nz, bup_mix_nz, arsc_bad, cram0_chip.n_viol);
`ifdef BUP_DEBUG
			$display("BUPCHIP status word %08x (cpu_run fw asset halted / code / cmd_ovf pcm_ovf pcm_unf muted / fault / cap_err / lowest %0d)",
				dut.bup_dbg_status, dut.bup_dbg_status[10:0]);
`endif
			$finish;
		end
`endif
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
			// +resetat=MS: a 10 ms reset (the Pocket's Reset) MS into the run.
			if ($value$plusargs("resetat=%d", reset_at)) fork
				begin
					repeat (longint'(14318) * reset_at) @(posedge clk_sys);
					reset_in = 1'b1;
					$display("RESET at %0d ms", $time / 1000000);
					repeat (longint'(14318) * 10) @(posedge clk_sys);
					reset_in = 1'b0;
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
			for (int ms_i = 0; ms_i < wav_ms; ms_i++) repeat (14318) @(posedge clk_sys);   // by ms: a long run's cycle count overflows repeat
			recording = 0;
			$fclose(wav_raw); $fclose(wav_filt);
			$display("WAV recorded %0d ms", wav_ms);
			// +ardump=FILE: the Supercharger's 6 KiB RAM (banks 0-2) as the
			// SRAM holds it, for ar_test.py check.
			if ($value$plusargs("ardump=%s", ar_dump)) begin
				automatic int fd_d = $fopen(ar_dump, "wb");
				for (int i = 0; i < 6144; i++)
					$fwrite(fd_d, "%c", i[0] ? sram_chip.mem[i >> 1][15:8] : sram_chip.mem[i >> 1][7:0]);
				$fclose(fd_d);
			end
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
				repeat (70) @(posedge clk_74a);    // APF pacing, as for writes
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
				repeat (70) @(posedge clk_74a);
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
