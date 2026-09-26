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
		.region_setting(2'd0), .palette_temp(2'd0), .hsc_setting(2'd0), .show_overscan(1'b0),
		.hide_border(1'b0), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(1'b0), .pause_core(1'b0),
		.joy0(16'd0), .joy1(16'd0),
		.R(R), .G(G), .B(B), .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
		.ce_pix(ce_pix), .tia_mode_o(tia_mode), .is_pal_o(is_pal),
		.AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R),
		.clk_74a(clk_74a), .hsc_bridge_addr(hsc_addr), .hsc_bridge_wr(hsc_wr), .hsc_bridge_din(hsc_din),
		.hsc_bridge_dout(hsc_dout), .hsc_active(),
		.SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(), .SDRAM_DQMH(),
		.SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_CLK(), .SDRAM_CKE()
	);

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
	string path;

	initial begin
		if (!$value$plusargs("image=%s", path)) path = "load_test.a78";
		if (!$value$plusargs("audf=%d", audf)) audf = 7;
		fd = $fopen(path, "rb");
		if (fd == 0) begin $display("cannot open %s", path); $finish; end
		while ((c = $fgetc(fd)) != -1) image.push_back(c[7:0]);
		$fclose(fd);
		while (image.size() % 4) image.push_back(8'hFF);

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

		// High score save, bridge side: a word written through the 32 bit port
		// must land as four bytes in address order and read back whole.
		@(posedge clk_74a); hsc_addr = 9'd5; hsc_din = 32'h11223344; hsc_wr = 1'b1;
		@(posedge clk_74a); hsc_wr = 1'b0;
		repeat (2) @(posedge clk_74a);
		$display("HSC word 5 = %08x, bytes 20..23 = %02x %02x %02x %02x (expect 11223344 / 11 22 33 44)",
			hsc_dout, dut.hsc_ram.lane[0].ram.mem[5], dut.hsc_ram.lane[1].ram.mem[5],
			dut.hsc_ram.lane[2].ram.mem[5], dut.hsc_ram.lane[3].ram.mem[5]);

		reset_in = 1'b0;
		repeat (14318181 / 10) @(posedge clk_sys);
		counting = 1;
		repeat (14318181 / 5) @(posedge clk_sys);
		counting = 0;
		measured = rises * 5.0;
		ideal = 3579545.0 / 114.0 / (audf + 1) / 2.0;
		$display("TONE from loaded cart AUDF0=%0d: measured %.1f Hz, TIA reference %.1f Hz, ratio %.3f",
			audf, measured, ideal, measured / ideal);
		$finish;
	end
endmodule
