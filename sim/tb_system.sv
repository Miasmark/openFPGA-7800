// Whole-core simulation of the Pocket wrapper (atari7800_pocket) at the
// Pocket's clock plan: clk_sys 14.318181 MHz, clk_sdram at exactly 4x and,
// with POCKET_BUPCHIP, clk_arm at exactly 2x (with POCKET_DARIA on the PLL's
// VCO/18 lattice, as tb_load.sv), with a model of the PSRAM
// (cram0) the BupChip keeps its assets in. Nothing loads a BupChip firmware
// here, so the BupChip stays held and silent.
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
	// Both clocks step from one rounded half period, so clk_sys is exactly
	// 4 x clk_sdram as the PLL makes it. T_SYS / 8 and T_SYS / 2 round to
	// different picoseconds (8.730 vs 34.921 ns); the clocks then drifted,
	// and now and then the clk_sys register missed one of the loader's
	// four-clk_sdram strobes and dropped a cartridge byte.
	localparam real T_HALF_SDRAM = 8.730;
	// clk_run is 0 while +retune has the PLL's outputs stopped ("PLL retune"
	// below). A stopped clock keeps its level and skips its edges; the times
	// of its edges do not move, so it restarts on its lattice.
	logic clk_run = 1'b1;
	always #(T_HALF_SDRAM) if (clk_run) clk_sdram = ~clk_sdram;
	always #(4 * T_HALF_SDRAM) if (clk_run) clk_sys = ~clk_sys;
`ifdef POCKET_BUPCHIP
	logic clk_arm = 1'b1;
`ifdef POCKET_DARIA
	// clk_arm on the PLL's lattice (docs/daria_step7/plan.md, F5). The VCO
	// is 48 x clk_sys (687.27 MHz, 1.455 ns): clk_sdram is VCO/12 and
	// clk_arm VCO/18 (38.18 MHz), half period 13.095 ns = 1.5 x
	// T_HALF_SDRAM, PLL phase 0 (pll_core.v): a clk_arm rising edge meets a
	// clk_sys rising edge every 3 clk_sys (8 clk_arm). +arm_div=19 selects
	// the fallback, VCO/19 (36.17 MHz): rising edges every 19 VCO periods
	// (27.645 ns), the falling edge 9.5 VCO periods after (the counter's odd
	// duty correction), which the bench's 1 ps step gives as 13.823 ns high,
	// 13.822 ns low. +arm_ofs=PS starts the lattice PS ps late (the phase
	// runs). The check below stops the run if an edge leaves its lattice.
	int arm_div = 18, arm_ofs = 0;
	bit arm_init = 1'b0, arm_ph = 1'b0;
	always begin
		if (!arm_init) begin
			arm_init = 1'b1;
			void'($value$plusargs("arm_div=%d", arm_div));
			void'($value$plusargs("arm_ofs=%d", arm_ofs));
			if (arm_div != 18 && arm_div != 19) $fatal(1, "+arm_div=%0d: 18 or 19", arm_div);
			$display("CLK_ARM VCO/%0d, phase offset %0d ps", arm_div, arm_ofs);
			if (arm_ofs > 0) #(arm_ofs * 0.001);
		end
		#(arm_div == 19 ? (arm_ph ? 13.822 : 13.823) : 1.5 * T_HALF_SDRAM);
		arm_ph = ~arm_ph;
		if (clk_run) clk_arm = ~clk_arm;
	end
	// (a real-to-integer cast rounds; the initial value is no edge)
	always @(clk_arm) if ($realtime > 0) begin
		automatic longint t = longint'($realtime * 1000.0) - arm_ofs;
		automatic longint p = arm_div == 19 ? 27645 : 26190;
		if (t % p != (clk_arm ? 0 : (arm_div == 19 ? 13823 : 13095)))
			$fatal(1, "clk_arm %0s edge at %0d ps is off its VCO/%0d lattice", clk_arm ? "rising" : "falling", t, arm_div);
	end
`else
	// clk_arm, the BupChip's: exactly 2 x clk_sys, edge aligned, as the PLL
	// makes it (counter[3]).
	always #(2 * T_HALF_SDRAM) if (clk_run) clk_arm = ~clk_arm;
`endif
`endif

	// pll_locked and pll_busy as the DUT sees them: 1 and 0, except during a
	// +retune ("PLL retune" below).
	logic pll_locked_tb = 1'b1, pll_busy_tb = 1'b0;

	logic reset_in = 1'b1;
	logic [8:0] hsc_addr = 0; logic hsc_wr = 0; logic hsc_rd = 0;
	logic [1:0] sk_setting = 2'd2; logic [12:0] sk_addr = 0; logic sk_wr = 0, sk_rd = 0;
	logic [31:0] sk_din = 0; wire [31:0] sk_dout; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic hide_border = 1'b0;
	logic [1:0] region = 2'd1;   // NTSC; +pal for PAL
	logic overscan = 1'b0;       // +overscan
	logic clk_74a = 1'b0;
	always #6.734 clk_74a = ~clk_74a;

	wire [7:0] R, G, B;
	wire HSync, VSync, HBlank, VBlank, ce_pix, tia_mode, is_pal, video_pal;
	wire [15:0] AUDIO_L, AUDIO_R;
	wire [15:0] SDRAM_DQ;

	// The Pocket's SRAM (POCKET_SRAM builds use it; otherwise it stays idle)
	wire [16:0] SRAM_A; wire [15:0] SRAM_DQ;
	wire SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;
	sram_model sram_chip (.a(SRAM_A), .dq(SRAM_DQ), .oe_n(SRAM_OE_N), .we_n(SRAM_WE_N),
		.ub_n(SRAM_UB_N), .lb_n(SRAM_LB_N));

`ifdef POCKET_BUPCHIP
	// PSRAM cram0 (the BupChip's assets): bupchip/s4/psram_model.sv
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
		.clk_arm(clk_arm), .bupfw_download(1'b0), .ioctl_wr_any(1'b0), .ioctl_hi(3'd0),
		.cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
		.cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n),
		.cram0_ce1_n(cram0_ce1_n), .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
		.cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
`endif
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(pll_locked_tb), .pll_busy(pll_busy_tb), .reset_in(reset_in),
		.cart_download(1'b0), .bios_download(1'b0), .hscfw_download(1'b0), .arfw_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_dout(8'd0),
		.region_setting(region), .palette_temp(2'd0), .hsc_setting(2'd2), .show_overscan(overscan),
		.hide_border(hide_border), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(1'b1), .flicker_blend(1'b0), .pokey_irq(1'b0), .pause_core(1'b0),
		.clear_random(1'b0), .decomb(1'b0), .bs_override(5'd0),
		.joy0(16'd0), .joy1(16'd0), .joy2(16'd0), .joy3(16'd0),
		.analog0(16'h8080), .analog1(16'h8080), .analog2(16'h8080), .analog3(16'h8080),
		.port1_input(3'd0), .port2_input(3'd0),
		.analog0r(16'h8080), .analog1r(16'h8080), .turbo(2'd0),
		.R(R), .G(G), .B(B), .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
		.ce_pix(ce_pix), .tia_mode_o(tia_mode), .is_pal_o(is_pal), .video_pal_o(video_pal),
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

	// ---------------- PLL retune (+retune=MS) ----------------
	// pll_region (core/pll_region.v) retuning pll_core for a PAL/NTSC change,
	// MS ms after reset_in falls: pll_busy rises; 256 clk_74a later the two
	// register writes start the reconfiguration and the PLL's outputs
	// (clk_sys, clk_sdram, clk_arm) stop; they restart +retune_us=N us later
	// (default 20), rounded up to whole periods of all three, so each
	// restarts on its lattice; pll_locked, low while they are stopped, rises
	// 1 us after they restart, and pll_busy falls 256 clk_74a after that.
	// The frequencies do not change: the region itself is not modelled.
	initial begin
		int rt_ms, rt_us;
		longint lcm, now_ps, t_ps, w_ps;
		real t_busy, t_stop;
		if ($value$plusargs("retune=%d", rt_ms)) begin
			rt_us = 20;
			void'($value$plusargs("retune_us=%d", rt_us));
			wait (reset_in == 1'b0);
			#(rt_ms * 1.0e6);
			pll_busy_tb = 1'b1;
			t_busy = $realtime;
			#(258 * 13.468);
			// the clocks' common period: clk_sys is 48 VCO periods, clk_sdram 12,
			// clk_arm 24 (2 x clk_sys), 18 or 19
			lcm = 69840;
`ifdef POCKET_BUPCHIP
`ifdef POCKET_DARIA
			lcm = arm_div == 19 ? 1326960 : 209520;
`endif
`endif
			now_ps = longint'($realtime * 1000.0);
			t_ps = (now_ps / lcm + 1) * lcm + 1;
			// stop and restart between edges, never on one
			while (t_ps % 8730 == 0
`ifdef POCKET_BUPCHIP
`ifdef POCKET_DARIA
				|| (t_ps - arm_ofs) % (arm_div == 19 ? 27645 : 13095) == 0
				|| (arm_div == 19 && (t_ps - arm_ofs) % 27645 == 13823)
`endif
`endif
				) t_ps++;
			w_ps = (longint'(rt_us) * 1000000 + lcm - 1) / lcm * lcm;
			#((t_ps - now_ps) * 0.001);
			if (longint'($realtime * 1000.0) != t_ps)
				$fatal(1, "+retune: the stop landed at %0d ps, not %0d", longint'($realtime * 1000.0), t_ps);
			clk_run = 1'b0;
			pll_locked_tb = 1'b0;
			t_stop = $realtime;
			#(w_ps * 0.001);
			clk_run = 1'b1;
			#1000.0;
			pll_locked_tb = 1'b1;
			#(258 * 13.468);
			pll_busy_tb = 1'b0;
			$display("RETUNE pll_busy at %0.3f ms; clocks stopped at %0.3f ms for %0.3f us; pll_locked low until %0.3f ms; pll_busy low at %0.3f ms",
				t_busy / 1.0e6, t_stop / 1.0e6, w_ps / 1.0e6, (t_stop + w_ps * 0.001 + 1000.0) / 1.0e6, $realtime / 1.0e6);
		end
	end

	// ---------------- P2 assertion (Fix B) ----------------
	// docs/daria_step7/plan.md P2: with Fix B, sram_ctrl's 7800/BIOS request
	// (m_new) and its 2600 request (t_new) are mode-exclusive and never
	// meet in one clk_sdram cycle. run_sim.sh defines SIM_FIXB when
	// sram_ctrl.sv has t_new; the RTL itself carries no bench code.
`ifdef SIM_FIXB
	initial $display("P2 armed: sram_ctrl m_new and t_new checked on every clk_sdram");
	always @(posedge clk_sdram)
		if (dut.sram.m_new && dut.sram.t_new)
			$fatal(1, "P2: sram_ctrl m_new and t_new in the same clk_sdram cycle at %0.3f us", $realtime / 1000.0);
`endif

	// ---------------- frame fingerprint (+fp=FILE) ----------------
	// One line per rising edge of the core's VSync output (MARIA's in 7800
	// mode, the TIA's in 2600 mode), for comparing two builds frame by frame
	// (sim/check/frame_gate.py --strict). Columns, as tb_daria's fp.csv
	// (bupchip/daria/tb_daria.sv, "Frame fingerprint") plus cpu:
	//   frame    1, 2, ...: frame 1 starts at the first rising edge of the
	//            run; its line is written at the edge that ends it
	//   len_sys  clk_sys from the edge that starts the frame to the one that
	//            ends it (the clock that sees an edge belongs to the new frame)
	//   riot     FNV-1a 64 of the RIOT's 128 RAM bytes, address 0 first, read
	//            at the edge that ends the frame
	//   video    FNV-1a 64 of R, G, B on every clk_sys with ce_pix and
	//            neither blank
	//   audio    FNV-1a 64 of {AUDIO_L, AUDIO_R}, low byte first, on every
	//            clk_sys where it differs from the last value folded (that
	//            value carries across frames and starts at 0)
	//   cpu      FNV-1a 64 of the 6502's address (low byte first), R/W and
	//            data at every phase-2 enable (core_phi2_en): data_in on a
	//            read, data_out on a write
	localparam logic [63:0] FNV_OFFSET = 64'hcbf29ce484222325;
	localparam logic [63:0] FNV_PRIME  = 64'h00000100000001b3;
	function automatic logic [63:0] fnv(input logic [63:0] h, input logic [7:0] b);
		return (h ^ {56'd0, b}) * FNV_PRIME;
	endfunction
	`define FP_CPU dut.main.cpu_inst.cpu
	int          fp_fd = 0, fp_frame = 0;
	longint      fp_now = 0, fp_tvs = 0;
	logic        fp_vs = 1'b0;
	logic [63:0] fp_video = FNV_OFFSET, fp_audio = FNV_OFFSET, fp_cpu = FNV_OFFSET;
	logic [31:0] fp_last = 32'd0;
	string       fp_path;
	initial if ($value$plusargs("fp=%s", fp_path)) begin
		fp_fd = $fopen(fp_path, "w");
		if (fp_fd == 0) $fatal(1, "cannot open %s", fp_path);
		$fwrite(fp_fd, "frame,len_sys,riot,video,audio,cpu\n");
	end
	always @(posedge clk_sys) if (fp_fd != 0) begin
		fp_now++;
		fp_vs <= VSync;
		if (VSync && !fp_vs) begin
			automatic logic [63:0] h = FNV_OFFSET;
			for (int i = 0; i < 128; i++) h = fnv(h, dut.main.riot_inst.riot_ram.mem_q[i]);
			if (fp_frame > 0) begin
				$fwrite(fp_fd, "%0d,%0d,%016x,%016x,%016x,%016x\n", fp_frame, fp_now - fp_tvs, h,
					fp_video, fp_audio, fp_cpu);
				$fflush(fp_fd);
			end
			fp_video = FNV_OFFSET;
			fp_audio = FNV_OFFSET;
			fp_cpu = FNV_OFFSET;
			fp_frame++;
			fp_tvs = fp_now;
		end
		if (ce_pix && !HBlank && !VBlank) fp_video = fnv(fnv(fnv(fp_video, R), G), B);
		if ({AUDIO_L, AUDIO_R} != fp_last) begin
			fp_last = {AUDIO_L, AUDIO_R};
			for (int i = 0; i < 4; i++) fp_audio = fnv(fp_audio, fp_last[i*8 +: 8]);
		end
		if (`FP_CPU.core_phi2_en)
			fp_cpu = fnv(fnv(fnv(fnv(fp_cpu, `FP_CPU.addr_out[7:0]), `FP_CPU.addr_out[15:8]),
				{7'd0, `FP_CPU.rw_n}), `FP_CPU.rw_n ? `FP_CPU.data_in : `FP_CPU.data_out);
	end
	final if (fp_fd != 0) $fclose(fp_fd);

`ifdef POCKET_DARIA
	// ---------------- P18: psram.sv's CLOCK_SPEED ----------------
	// 50.0 under POCKET_DARIA (docs/daria_step7/plan.md P18). No PSRAM model
	// run tells it from 28.636364 at 38.18 MHz, so the parameter is checked.
	initial begin
		$display("P18 bup_psram CLOCK_SPEED %0.6f", dut.bup_psram.CLOCK_SPEED);
		if (dut.bup_psram.CLOCK_SPEED != 50.0)
			$fatal(1, "P18: bup_psram CLOCK_SPEED is %0.6f, not 50.0, in the POCKET_DARIA build", dut.bup_psram.CLOCK_SPEED);
	end
`endif

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
		if ($test$plusargs("pal")) region = 2'd2;
		if ($test$plusargs("overscan")) overscan = 1'b1;
		// 2600 mode: what the wrapper latches after loading a headerless image.
		if ($test$plusargs("mode2600")) force dut.tia_mode = 1'b1;
		repeat (200) @(posedge clk_sys);
		reset_in = 1'b0;
		// Let the program run and a few frames go by.
		repeat (14318181 / 10) @(posedge clk_sys);    // 100 ms
		// +long: 1.2 s more, past the TIA's 2600 region detection (48 frames)
		if ($test$plusargs("long")) repeat (14318181 / 10 * 12) @(posedge clk_sys);
		counting = 1;
		repeat (14318181 / 5) @(posedge clk_sys);     // 200 ms window
		counting = 0;
		measured = rises * 5.0;
		ideal = 3579545.0 / 114.0 / (audf + 1) / 2.0;
		$display("TONE AUDC0=4 AUDF0=%0d: measured %.1f Hz, TIA reference %.1f Hz, ratio %.3f",
			audf, measured, ideal, measured / ideal);
		for (int i = 1; i < frame_len.size(); i++)
			if (i >= frame_len.size() - 3)
				$display("FRAME %0d: %0d clk_sys (%.3f Hz), active lines %0d, active pixels/line %0d, video PAL %0d",
					i, frame_len[i], 14318181.0 / frame_len[i], frame_lines_active[i], frame_px[i], video_pal);
		$finish;
	end
endmodule
