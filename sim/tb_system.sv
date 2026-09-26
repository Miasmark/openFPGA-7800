// Whole-core simulation of the Pocket wrapper (atari7800_pocket) at the
// Pocket's clock plan: clk_sys 14.318181 MHz and clk_sdram at exactly 4x.
//
// No cartridge is loaded, so the core runs its built-in cartridge image from
// rtl/mem0.hex. run_sim.sh replaces that image with tone_test.hex, a few
// lines of 6502 that start a TIA pure tone (AUDC0=4) at a chosen AUDF0 and
// then idle. The bench reports:
//   - the tone's frequency, measured at the core's audio output, against the
//     TIA's documented rate (31.4 kHz / (AUDF+1) / 2): the "octave" check;
//   - the video geometry (active pixels per line, active lines per frame,
//     frame rate) that the Pocket scaler settings in video.json rely on.
`timescale 1ns/1ps

module tb_system;
	// 14.318181 MHz -> 69.841 ns period. clk_sdram at a quarter of that.
	localparam real T_SYS = 69.8413;
	logic clk_sdram = 1'b1;
	logic clk_sys = 1'b1;
	always #(T_SYS / 8.0) clk_sdram = ~clk_sdram;
	always #(T_SYS / 2.0) clk_sys = ~clk_sys;

	logic reset_in = 1'b1;
	logic [8:0] hsc_addr = 0; logic hsc_wr = 0; logic hsc_rd = 0; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic hide_border = 1'b0;
	logic clk_74a = 1'b0;
	always #6.734 clk_74a = ~clk_74a;

	wire [7:0] R, G, B;
	wire HSync, VSync, HBlank, VBlank, ce_pix, tia_mode, is_pal;
	wire [15:0] AUDIO_L, AUDIO_R;
	wire [15:0] SDRAM_DQ;

	atari7800_pocket dut (
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(1'b1), .reset_in(reset_in),
		.cart_download(1'b0), .bios_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_dout(8'd0),
		.region_setting(2'd1), .palette_temp(2'd0), .hsc_setting(2'd2), .show_overscan(1'b0),
		.hide_border(hide_border), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(1'b0), .pokey_irq(1'b0), .pause_core(1'b0),
		.joy0(16'd0), .joy1(16'd0),
		.R(R), .G(G), .B(B), .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
		.ce_pix(ce_pix), .tia_mode_o(tia_mode), .is_pal_o(is_pal),
		.AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R),
		.clk_74a(clk_74a), .hsc_bridge_addr(hsc_addr), .hsc_bridge_wr(hsc_wr), .hsc_bridge_rd(hsc_rd), .hsc_bridge_din(hsc_din),
		.hsc_bridge_dout(hsc_dout), .hsc_active(),
		.SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(), .SDRAM_DQMH(),
		.SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_CLK(), .SDRAM_CKE()
	);

	// ---------------- video geometry ----------------
	int px_in_line, max_px, lines_active, frames, line_started;
	int frame_lines_active [$];
	int frame_px [$];
	longint sys_cycles = 0, last_vs_cycle = 0;
	longint frame_len [$];
	logic old_vs = 0, old_hb = 1;

	always @(posedge clk_sys) begin
		sys_cycles <= sys_cycles + 1;
		old_vs <= VSync;
		old_hb <= HBlank;
		if (ce_pix && !HBlank && !VBlank) begin
			px_in_line <= px_in_line + 1;
			line_started <= 1;
		end
		if (!old_hb && HBlank) begin
			if (line_started) begin
				lines_active <= lines_active + 1;
				if (px_in_line > max_px) max_px <= px_in_line;
			end
			px_in_line <= 0;
			line_started <= 0;
		end
		if (!old_vs && VSync) begin
			frame_lines_active.push_back(lines_active);
			frame_px.push_back(max_px);
			frame_len.push_back(sys_cycles - last_vs_cycle);
			last_vs_cycle <= sys_cycles;
			lines_active <= 0;
			max_px <= 0;
		end
	end

	// ---------------- audio ----------------
	longint rises = 0;
	logic [15:0] old_aud = 0;
	logic counting = 0;
	always @(posedge clk_sys) begin
		old_aud <= AUDIO_L;
		if (counting && AUDIO_L > old_aud && old_aud == 16'd0)
			rises <= rises + 1;
	end

	int audf;
	real measured, ideal;
	initial begin
		if (!$value$plusargs("audf=%d", audf)) audf = 0;
		if ($test$plusargs("hide_border")) hide_border = 1'b1;
		// 2600 mode: what the wrapper latches after loading a headerless image.
		if ($test$plusargs("mode2600")) force dut.tia_mode = 1'b1;
		repeat (200) @(posedge clk_sys);
		reset_in = 1'b0;
		// Let the program run and a few frames go by.
		repeat (14318181 / 10) @(posedge clk_sys);    // 100 ms
		counting = 1;
		repeat (14318181 / 5) @(posedge clk_sys);     // 200 ms window
		counting = 0;
		measured = rises * 5.0;
		ideal = 3579545.0 / 114.0 / (audf + 1) / 2.0;
		$display("TONE AUDC0=4 AUDF0=%0d: measured %.1f Hz, TIA reference %.1f Hz, ratio %.3f",
			audf, measured, ideal, measured / ideal);
		for (int i = 1; i < frame_len.size(); i++)
			if (i >= frame_len.size() - 3)
				$display("FRAME %0d: %0d clk_sys (%.3f Hz), active lines %0d, active pixels/line %0d",
					i, frame_len[i], 14318181.0 / frame_len[i], frame_lines_active[i], frame_px[i]);
		$finish;
	end
endmodule
