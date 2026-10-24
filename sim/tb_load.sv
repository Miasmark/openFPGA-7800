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
	// clk_run is 0 while +retune has the PLL's outputs stopped ("PLL retune"
	// below), run74 is 0 while +stop74 has clk_74a stopped. A stopped clock
	// keeps its level and skips its edges; the times of its edges do not
	// move, so it restarts on its lattice.
	// The time in ns as a real. Verilator 5.040 turns $realtime into whole
	// ns inside an integer cast (longint'($realtime * 1000.0) loses the ps);
	// through a real variable it keeps them.
	function automatic real now_ns();
		real r;
		r = $realtime;
		return r;
	endfunction
	logic clk_run = 1'b1, run74 = 1'b1;
	always #(T_HALF_SDRAM) if (clk_run) clk_sdram = ~clk_sdram;
	always #(4 * T_HALF_SDRAM) if (clk_run) clk_sys = ~clk_sys;
	always #6.734 if (run74) clk_74a = ~clk_74a;
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
	// (the initial value is no edge)
	always @(clk_arm) if ($realtime > 0) begin
		automatic longint t = longint'(now_ns() * 1000.0) - arm_ofs;
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
	logic [1:0] sk_setting = 2'd2; logic [1:0] vox_setting = 2'd2; logic [12:0] sk_addr = 0; logic sk_wr = 0, sk_rd = 0;
	logic [31:0] sk_din = 0; wire [31:0] sk_dout; logic [31:0] hsc_din = 0; wire [31:0] hsc_dout;
	logic [5:0] fa2_addr = 0; logic fa2_wr = 0, fa2_rd = 0; logic [31:0] fa2_din = 0; wire [31:0] fa2_dout;
	logic cart_download = 1'b0;
	logic hscfw_download = 1'b0, arfw_download = 1'b0, bupfw_download = 1'b0;
	// +bios=FILE: a 7800 BIOS through its data slot, before the cartridge
	// (+bioslast: after it). +skipbios=0 turns Skip BIOS off (default 1).
	// +nocart: no cartridge download, so with +bios the BIOS boots alone.
	logic bios_download = 1'b0, skip_bios = 1'b1, nocart = 1'b0;
	initial begin
		void'($value$plusargs("skipbios=%d", skip_bios));
		nocart = $test$plusargs("nocart");
	end
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
	// +region=N: region_setting (0 auto, 1 NTSC, 2 PAL; default 0). A wrapper
	// bench (tb_frames) may also set region_tb before the load ends.
	logic [1:0] region_tb = 2'd0;
	initial void'($value$plusargs("region=%d", region_tb));
	// ext_end: a wrapper bench (tb_frames) that ends the run itself sets this
	// before the load ends; the flow below then stops at the reset release,
	// running none of its own cases.
	bit ext_end = 1'b0;

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
		.clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(pll_locked_tb), .pll_busy(pll_busy_tb), .reset_in(reset_in),
		.cart_download(cart_download), .bios_download(bios_download),
		.hscfw_download(hscfw_download), .arfw_download(arfw_download),
		.ioctl_wr(ioctl_wr_r & (cart_download | bios_download | hscfw_download | arfw_download | bupfw_download)), .ioctl_addr(ioctl_addr_r), .ioctl_dout(ioctl_dout_r),
		.region_setting(region_tb), .palette_temp(2'd0), .hsc_setting(hsc_setting), .show_overscan(overscan_on),
		.hide_border(1'b0), .stereo_tia(1'b0), .swap_joysticks(1'b0), .diff_left_b(1'b1),
		.diff_right_b(1'b1), .skip_bios(skip_bios), .flicker_blend(blend_on), .pokey_irq(pokey_irq_on), .pause_core(1'b0),
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
		.savekey_setting(sk_setting), .atarivox_setting(vox_setting), .sk_bridge_addr(sk_addr), .sk_bridge_wr(sk_wr), .sk_bridge_rd(sk_rd),
		.sk_bridge_din(sk_din), .sk_bridge_dout(sk_dout),
		.fa2_bridge_addr(fa2_addr), .fa2_bridge_wr(fa2_wr), .fa2_bridge_rd(fa2_rd), .fa2_bridge_din(fa2_din),
		.fa2_bridge_dout(fa2_dout),
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
			now_ps = longint'(now_ns() * 1000.0);
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
			if (longint'(now_ns() * 1000.0) != t_ps)
				$fatal(1, "+retune: the stop landed at %0d ps, not %0d", longint'(now_ns() * 1000.0), t_ps);
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

	// ---------------- +stop74 ----------------
	// clk_74a feeds the APF loader, the save-slot ports (HSC and SaveKey RAM
	// port B, sram_ctrl's bridge) and the BupChip's 48 kHz tick
	// (bupchip_pocket's bup_tick48k). +stop74 stops it after the last load,
	// for speed, and runs it again for a +image2 load and for the save-slot
	// reads at the end. Refused with +bupms, which needs the 48 kHz tick.
	bit stop74 = 1'b0;
	initial stop74 = $test$plusargs("stop74");

	// ---------------- P2 assertion (Fix B) ----------------
	// docs/daria_step7/plan.md P2: with Fix B, sram_ctrl's 7800/BIOS request
	// (m_new) and its 2600 request (t_new) are mode-exclusive and never
	// meet in one clk_sdram cycle. run_sim.sh defines SIM_FIXB when
	// sram_ctrl.sv has t_new; the RTL itself carries no bench code.
// +p2count counts the coincidences instead of stopping, for a diagnosis on
// a tree that has the fault (tb_cartram's +rsmode reproduction); a run with
// it is no gate run (no "P2 armed" line).
`ifdef SIM_FIXB
	bit p2_count = 1'b0;
	int p2_n = 0;
	initial begin
		p2_count = $test$plusargs("p2count");
		if (p2_count) $display("P2 counting (+p2count): sram_ctrl m_new and t_new counted on every clk_sdram, not stopped");
		else $display("P2 armed: sram_ctrl m_new and t_new checked on every clk_sdram");
	end
	always @(posedge clk_sdram)
		if (dut.sram.m_new && dut.sram.t_new) begin
			if (!p2_count) $fatal(1, "P2: sram_ctrl m_new and t_new in the same clk_sdram cycle at %0.3f us", $realtime / 1000.0);
			p2_n++;
			if (p2_n <= 10) $display("P2 COINCIDENCE (+p2count) at %0.3f us: m_new and t_new in one clk_sdram cycle", $realtime / 1000.0);
		end
	final if (p2_count) $display("P2 counted: %0d clk_sdram cycles with m_new and t_new together", p2_n);
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
	// and three columns that place the frame in absolute time, so that a
	// whole run shifted by some clocks (every column above restarts with the
	// console's reset) does not compare equal:
	//   t_sys    clk_sys counted from time 0 at the edge that ends the frame
	//   rst_n    how many times the wrapper's console reset (the register
	//            reset in atari7800_pocket.sv, which P6's daria_hold joins)
	//            has been released so far, counted from time 0
	//   rst_sys  clk_sys counted from time 0 at the last of those releases:
	//            the clock whose edge first sees reset low (plan P6: the
	//            DARIA and the plain build release on the same edge)
	// When the run ends, one more line: the frame still in progress, from the
	// last VSync edge (or from time 0 when there was none: numbered 1), with
	// its clocks so far and the same columns. A run that never raises VSync
	// (cartram2600_test.py's images never write VSYNC) then still has one
	// line to compare, and the clocks after the last edge are covered too.
	localparam logic [63:0] FNV_OFFSET = 64'hcbf29ce484222325;
	localparam logic [63:0] FNV_PRIME  = 64'h00000100000001b3;
	function automatic logic [63:0] fnv(input logic [63:0] h, input logic [7:0] b);
		return (h ^ {56'd0, b}) * FNV_PRIME;
	endfunction
	`define FP_CPU dut.main.cpu_inst.cpu
	int          fp_fd = 0, fp_frame = 0;
	longint      fp_now = 0, fp_tvs = 0;
	logic        fp_vs = 1'b0, fp_rs = 1'b1;
	longint      fp_rst_n = 0, fp_rst_t = 0;
	logic [63:0] fp_video = FNV_OFFSET, fp_audio = FNV_OFFSET, fp_cpu = FNV_OFFSET;
	logic [31:0] fp_last = 32'd0;
	string       fp_path;
	initial if ($value$plusargs("fp=%s", fp_path)) begin
		fp_fd = $fopen(fp_path, "w");
		if (fp_fd == 0) $fatal(1, "cannot open %s", fp_path);
		$fwrite(fp_fd, "frame,len_sys,riot,video,audio,cpu,t_sys,rst_n,rst_sys\n");
	end
	always @(posedge clk_sys) if (fp_fd != 0) begin
		fp_now++;
		fp_vs <= VSync;
		if (fp_rs && !dut.reset) begin
			fp_rst_n++;
			fp_rst_t = fp_now;
		end
		fp_rs = dut.reset;
		if (VSync && !fp_vs) begin
			automatic logic [63:0] h = FNV_OFFSET;
			for (int i = 0; i < 128; i++) h = fnv(h, dut.main.riot_inst.riot_ram.mem_q[i]);
			if (fp_frame > 0) begin
				$fwrite(fp_fd, "%0d,%0d,%016x,%016x,%016x,%016x,%0d,%0d,%0d\n", fp_frame, fp_now - fp_tvs, h,
					fp_video, fp_audio, fp_cpu, fp_now, fp_rst_n, fp_rst_t);
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
	final if (fp_fd != 0) begin
		automatic logic [63:0] h = FNV_OFFSET;
		for (int i = 0; i < 128; i++) h = fnv(h, dut.main.riot_inst.riot_ram.mem_q[i]);
		$fwrite(fp_fd, "%0d,%0d,%016x,%016x,%016x,%016x,%0d,%0d,%0d\n", fp_frame > 0 ? fp_frame : 1, fp_now - fp_tvs, h,
			fp_video, fp_audio, fp_cpu, fp_now, fp_rst_n, fp_rst_t);
		$fclose(fp_fd);
	end

`ifdef POCKET_DARIA
	// ---------------- P18: psram.sv's CLOCK_SPEED ----------------
	// 50.0 under POCKET_DARIA (docs/daria_step7/plan.md P18). No PSRAM model
	// run told it from 28.636364 at 38.18 MHz (VCO/18, DARIA's clock, and at
	// VCO/19, 36.17 MHz, its clock from 2026-10-12 until the L1W+L3 CPU), so
	// the parameter is checked.
	initial begin
		$display("P18 bup_psram CLOCK_SPEED %0.6f", dut.bup_psram.CLOCK_SPEED);
		if (dut.bup_psram.CLOCK_SPEED != 50.0)
			$fatal(1, "P18: bup_psram CLOCK_SPEED is %0.6f, not 50.0, in the POCKET_DARIA build", dut.bup_psram.CLOCK_SPEED);
	end

	// ---------------- DARIA (+daria=MS) ----------------
	// run_sim.sh's DARIA section: a synthetic ARM image (fe_dir/mkimg.py)
	// runs MS ms after reset_in falls, then one line: the image's RIOT
	// markers (fe_dir's convention: $FF counts finished test bodies, $FE its
	// own failed checks), the calls daria_fe posted (call_tog flips), the
	// returns it saw (ret_tog flips), the PSRAM model's violations, the
	// BupChip CPU's halt, and the guard's lock and unlocks (P22's ports).
	// The taps need daria_fe in the wrapper as dut.u_fe: run_sim.sh defines
	// SIM_DARIA_FE when atari7800_pocket.sv instantiates it.
	int     daria_ms = 0;
	longint dr_calls = 0, dr_rets = 0, dr_unlocks = 0;
`ifdef SIM_DARIA_FE
	logic dr_ct = 1'b0, dr_rt = 1'b0, dr_on = 1'b0, dr_on_a = 1'b0;
	always @(posedge clk_sys) begin
		dr_on <= 1'b1;
		dr_ct <= dut.u_fe.call_tog;
		if (dr_on && dut.u_fe.call_tog != dr_ct) dr_calls++;
		if (dr_on && dut.u_fe.dbg_unlock) dr_unlocks++;
	end
	always @(posedge clk_arm) begin
		dr_on_a <= 1'b1;
		dr_rt <= dut.u_fe.ret_tog;
		if (dr_on_a && dut.u_fe.ret_tog != dr_rt) dr_rets++;
	end
`endif
`ifdef BUP_DEBUG
`ifdef SIM_DARIA_FE
	// ---------------- the DARIA status overlay (BUP_DEBUG builds) ----------------
	// daria_dbg_status's counts and copy of the RIOT's timer (dut.u_dstat),
	// and bup_status_osd.sv's DARIA rows (its header has the layout):
	//   ovl_b_calls the calls posted since the console's last reset (call_tog
	//               flips counted while daria_reset is low, cleared while it
	//               is high: u_dstat's own epoch, so a reset after a call, a
	//               hard reset, a menu or slot load, a +retune, compares as
	//               well as the first; dr_calls, from power-up, stays the
	//               DARIA result's and its meta check's)
	//   ovl_b_unl   dbg_unlock pulses since power-up, as u_dstat counts them,
	//               read on the net u_dstat is wired to (daria_dbg_unlock)
	//   ovl_lk_bad  clk_sys on which u_dstat's guard bit is not daria_dbg_locked
	//               of the clock before (u_dstat registers it once); ovl_lk_n
	//               the clk_sys with that net high
	//   ovl_rows_bad frames that drew any of rows 6-8 while the status word's
	//               halt bit (bup_status_osd's st[28]) was 0 at the frame's
	//               end (rows 6-8 only while halted); not judged under the
	//               pattern, which forces the halt
	//   ovl_rt_bad  clk_sys on which the copy (timer, prescaler, incr,
	//               rollover) differs from the RIOT's own (M6532.sv), while
	//               the DARIA profile runs and the console is out of reset;
	//               ovl_rt_n the clk_sys compared
	//   ovl_px_bad  cells read back from the picture that differ from the
	//               layout: on each frame, the centre pixel of every cell (the
	//               line through the row's centre) must be the row's colour
	//               where the bit is 1, grey where it is 0 and black where the
	//               cell is not drawn, the bit taken by this bench's own map
	//               from the source: DARIA's counts from u_dstat's registers
	//               (ovl_src_q: one clk_sys later, as the overlay registers
	//               its dstat input), so a miswired dstat port is a
	//               difference; the status word, halt PC and load flags from
	//               the overlay's registers; under +ovl_pattern_at, the
	//               forced pattern itself. ovl_px_n counts the cells read
	//   ovl_last    the rows read back from the last whole frame (lit = 1),
	//               ovl_last_rows the rows drawn in it
	// What was checked must be enough, or the verdict is FAIL: a run that
	// reads no cell checks nothing (run_sim.sh's DARIA section gives each
	// image its own requirement):
	//   +ovl_rows=HEX  rows each of whose 12 cells must have been read at
	//                  least once (default 3F: rows 0-5, a frame's six; 1FF
	//                  with the halt rows; 0 waives it, and the line says so)
	//   +ovl_cells=N   at least N cells read in all (default 1; 0 waives it)
	//   +ovl_timer=1   the timer path exercised: the RIOT's timer written and
	//                  read, and late calls above 0 and below the calls (an
	//                  image that writes its timer before some calls and lets
	//                  it run out, and not before others: frame_cdfj)
	//   +ovl_late=N    with +ovl_timer=1: exactly N late calls, not merely
	//                  some (frame_cdfj's .meta gives N for its run length)
	//   +ovl_resets=N  the console's reset released at least N times (a run
	//                  with +retune: the second epoch is the one compared)
	//   +ovl_guard=N   (with +ovl_guard_at=MS, default 100) MS ms after the
	//                  reset release, the net daria_dbg_locked is forced high
	//                  for 20 ms and daria_dbg_unlock pulsed N times, one
	//                  clk_sys each, 64 apart, on the falling edge: u_dstat
	//                  must count them as this bench does, so the guard and
	//                  unlock terms compare nonzero values at any divider (the
	//                  guard never locks at VCO/19). Verilator makes the net
	//                  and daria_fe's ports one variable, so dr_unlocks (the
	//                  DARIA result's unlocks) counts the pulses too, and
	//                  run_sim.sh expects exactly N there; the guard's own
	//                  register (daria_fe_guard's lk, which guard_on and
	//                  phb_next read) is not forced
	// and the RIOT copy compared on at least one clk_sys. Undrawn cells (row 0
	// columns 2 and 7-11, row 6 columns 0-3) are read as black, so a row
	// counts as complete when all 12 have been read.
	//   +ovl_pattern_at=MS  MS ms after the reset release, at a frame's end,
	//                  the overlay's inputs (daria_dstat, the status word,
	//                  halt PC and load flags) are forced to a pattern that
	//                  lights every row and colour, nine rows (halted); two
	//                  whole frames later to its complement (the halt bit
	//                  kept), so every drawn cell is lit in one of the two.
	//                  Each must read back as forced: the last whole frame of
	//                  each phase, all nine rows. The counts compared below
	//                  are u_dstat's, which the forces do not reach.
	// tb_frames, on a game, also compares the counts with its own (calls,
	// late calls, unlocks, the guard) at every frame's end.
	int unsigned ovl_rt_bad = 0, ovl_px_bad = 0, ovl_px_n = 0, ovl_frames = 0, ovl_rt_n = 0;
	int unsigned ovl_tw_n = 0, ovl_tr_n = 0;
	logic [11:0] ovl_cur [0:8], ovl_last [0:8], ovl_seen [0:8];
	logic  [8:0] ovl_cur_rows = '0, ovl_last_rows = '0;
	logic        ovl_vb_q = 1'b1;
	int unsigned ovl_need_cells = 1;
	logic  [8:0] ovl_need_rows = 9'h03F;
	bit          ovl_need_timer = 1'b0;
	int          ovl_need_late = -1, ovl_need_resets = 0;
	int unsigned ovl_guard_n = 0, ovl_guard_ms = 100;
	initial begin
		for (int i = 0; i < 9; i++) begin ovl_cur[i] = '0; ovl_last[i] = '0; ovl_seen[i] = '0; end
		void'($value$plusargs("ovl_rows=%h", ovl_need_rows));
		void'($value$plusargs("ovl_cells=%d", ovl_need_cells));
		ovl_need_timer = $test$plusargs("ovl_timer=1");
		void'($value$plusargs("ovl_late=%d", ovl_need_late));
		void'($value$plusargs("ovl_resets=%d", ovl_need_resets));
		void'($value$plusargs("ovl_guard=%d", ovl_guard_n));
		void'($value$plusargs("ovl_guard_at=%d", ovl_guard_ms));
	end
	// the bench's counts, in u_dstat's epochs (above)
	longint      ovl_b_calls = 0, ovl_b_unl = 0;
	int unsigned ovl_lk_bad = 0, ovl_lk_n = 0, ovl_rel_n = 0, ovl_rows_bad = 0;
	logic        ovl_ct = 1'b0, ovl_lk_q = 1'b0, ovl_ul_q = 1'b0, ovl_rst_q = 1'b1;
	always @(posedge clk_sys) begin
		ovl_ct <= dut.u_fe.call_tog;
		if (dut.daria_reset) ovl_b_calls = 0;
		else if (dr_on && dut.u_fe.call_tog != ovl_ct) ovl_b_calls++;
		if (ovl_rst_q && !dut.daria_reset) ovl_rel_n++;
		ovl_rst_q <= dut.daria_reset;
		if (dut.u_dstat.locked !== ovl_lk_q) begin
			if (ovl_lk_bad < 5)
				$display("OVERLAY guard bit %0d at %0.3f ms, daria_dbg_locked was %0d", dut.u_dstat.locked, now_ns() / 1.0e6, ovl_lk_q);
			ovl_lk_bad++;
		end
		ovl_lk_q = dut.daria_dbg_locked;
		if (ovl_lk_q) ovl_lk_n++;
		if (ovl_ul_q) ovl_b_unl++;
		ovl_ul_q = dut.daria_dbg_unlock;
	end
	// the source of DARIA's counts, as the overlay's ds register holds them
	logic [48:0] ovl_src_q = '0;
	always @(posedge clk_sys) ovl_src_q <= {dut.u_dstat.locked, dut.u_dstat.late, dut.u_dstat.unl, dut.u_dstat.calls};

	// the forced pattern (+ovl_pattern_at): phase 1, then its complement
	// with the halt bit (status 28) kept, so rows 6-8 stay drawn
	localparam logic [48:0]  OVL_P1_DS = {1'b1, 12'hA5C, 12'h3A5, 24'h5AC3A5};
	localparam logic [31:0]  OVL_P1_ST = 32'h9A05_C000;    // running, halted, halt code A, fault code 5C
	localparam logic [31:0]  OVL_P1_PC = 32'hA5C3_96F0;
	localparam logic [110:0] OVL_P1_LD = {3'b101, 108'd0}; // seq_err, overrun
	localparam logic [48:0]  OVL_P2_DS = ~OVL_P1_DS;
	localparam logic [31:0]  OVL_P2_ST = 32'h150A_3000;    // halted, halt code 5, fault code A3
	localparam logic [31:0]  OVL_P2_PC = ~OVL_P1_PC;
	localparam logic [110:0] OVL_P2_LD = {3'b010, 108'd0}; // lost
	int unsigned ovl_pat_ms = 0, ovl_t_sys = 0, ovl_pat_f0 = 0;
	int          ovl_pat = 0;                              // 0 off, 1 or 2 the phase forced
	bit          ovl_pat_ok1 = 1'b0, ovl_pat_done1 = 1'b0;
	initial void'($value$plusargs("ovl_pattern_at=%d", ovl_pat_ms));

	// +ovl_guard=N: the forced guard (above), on the falling edge of clk_sys
	// so every register samples each pulse on exactly one rising edge
	initial begin
		@(posedge clk_sys);                                // the plusargs are read
		if (ovl_guard_n > 0) begin
			wait (ovl_t_sys >= ovl_guard_ms * 14318);
			@(negedge clk_sys);
			force dut.daria_dbg_locked = 1'b1;
			$display("OVERLAY guard forced at %0.3f ms: daria_dbg_locked high, %0d unlock pulses", now_ns() / 1.0e6, ovl_guard_n);
			for (int i = 0; i < ovl_guard_n; i++) begin
				repeat (64) @(negedge clk_sys);
				force dut.daria_dbg_unlock = 1'b1;
				@(negedge clk_sys);
				release dut.daria_dbg_unlock;
			end
			wait (ovl_t_sys >= (ovl_guard_ms + 20) * 14318);
			@(negedge clk_sys);
			release dut.daria_dbg_locked;
			$display("OVERLAY guard released at %0.3f ms", now_ns() / 1.0e6);
		end
	end

	// the layout, cell by cell (bup_status_osd.sv's header): whether the
	// cell is drawn, its bit, and its lit colour, from the given inputs
	task automatic ovl_cell(input int r, input int c, input logic [48:0] ds, input logic [31:0] st, input logic [31:0] pc,
		input logic [110:0] ld, output bit shown, output bit b, output logic [23:0] rgb);
		shown = 1'b1; b = 1'b0; rgb = 24'h40A0FF;
		case (r)
			0: begin
				case (c)
					0: b = st[31];                      // CPU running
					1: b = ds[48];                      // guard locked
					3: b = st[28];                      // halted
					4: b = ld[110];                     // capture seq_err
					5: b = ld[109];                     // capture lost
					6: b = ld[108];                     // receiver overrun
					default: shown = 1'b0;
				endcase
				rgb = c < 2 ? 24'h00E000 : 24'hFF2020;
			end
			1: begin b = c < 4 ? st[27 - c] : st[19 - (c - 4)]; rgb = c < 4 ? 24'hFFE000 : 24'hFF8000; end
			2: begin b = ds[47 - c]; rgb = 24'hFF2020; end   // late calls
			3: begin b = ds[35 - c]; rgb = 24'hFF40FF; end   // unlocks
			4: b = ds[23 - c];                               // calls 23:12
			5: b = ds[11 - c];                               // calls 11:0
			6: begin if (c < 4) shown = 1'b0; else b = pc[31 - (c - 4)]; rgb = 24'hFFFFFF; end
			7: begin b = pc[23 - c]; rgb = 24'hFFFFFF; end
			default: begin b = pc[11 - c]; rgb = 24'hFFFFFF; end
		endcase
	endtask

	// a pattern phase's nine rows as they must read back (lit = 1)
	function automatic bit ovl_pat_match(input int ph);
		bit shown, b;
		logic [23:0] rgb;
		for (int r = 0; r < 9; r++)
			for (int c = 0; c < 12; c++) begin
				if (ph == 1) ovl_cell(r, c, OVL_P1_DS, OVL_P1_ST, OVL_P1_PC, OVL_P1_LD, shown, b, rgb);
				else ovl_cell(r, c, OVL_P2_DS, OVL_P2_ST, OVL_P2_PC, OVL_P2_LD, shown, b, rgb);
				if (ovl_last[r][11 - c] != (shown && b)) return 1'b0;
			end
		return ovl_last_rows == 9'h1FF;
	endfunction

	task automatic ovl_force(input int ph);
		if (ph == 1) begin
			force dut.daria_dstat = OVL_P1_DS;
			force dut.bup_dbg_status = OVL_P1_ST;
			force dut.bup_dbg_halt_pc = OVL_P1_PC;
			force dut.bup_dbg_load = OVL_P1_LD;
		end else begin
			force dut.daria_dstat = OVL_P2_DS;
			force dut.bup_dbg_status = OVL_P2_ST;
			force dut.bup_dbg_halt_pc = OVL_P2_PC;
			force dut.bup_dbg_load = OVL_P2_LD;
		end
		ovl_pat = ph;
		ovl_pat_f0 = ovl_frames;
		$display("OVERLAY pattern %0d forced at %0.3f ms (overlay frame %0d)", ph, now_ns() / 1.0e6, ovl_frames);
	endtask

	always @(posedge clk_sys) begin
		// the RIOT's timer and its copy
		if (dut.daria_profile && !dut.daria_reset) begin
			ovl_rt_n++;
			if (dut.u_dstat.t_timer !== dut.main.riot_inst.timer || dut.u_dstat.t_pre !== dut.main.riot_inst.prescaler ||
				dut.u_dstat.t_incr !== dut.main.riot_inst.incr || dut.u_dstat.t_roll !== dut.main.riot_inst.rollover) begin
				if (ovl_rt_bad < 5)
					$display("OVERLAY RIOT copy differs at %0.3f ms: timer %02x/%02x, prescaler %0d/%0d, incr %0d/%0d, rollover %0d/%0d (copy/RIOT)",
						now_ns() / 1.0e6, dut.u_dstat.t_timer, dut.main.riot_inst.timer, dut.u_dstat.t_pre, dut.main.riot_inst.prescaler,
						dut.u_dstat.t_incr, dut.main.riot_inst.incr, dut.u_dstat.t_roll, dut.main.riot_inst.rollover);
				ovl_rt_bad++;
			end
			// the RIOT's own timer accesses (its chip select, RAM select and A2)
			if (dut.main.riot_inst.ce && dut.main.riot_inst.CS1 && !dut.main.riot_inst.CS2_n && dut.main.riot_inst.RS_n &&
				dut.main.riot_inst.addr[2]) begin
				if (!dut.main.riot_inst.RW_n && dut.main.riot_inst.addr[4]) ovl_tw_n++;
				if (dut.main.riot_inst.RW_n) ovl_tr_n++;
			end
		end
		// the picture: one pixel per cell, at its centre
		if (dut.bup_osd.dar && dut.bup_osd.ce_pix && dut.bup_osd.in_osd &&
			dut.bup_osd.xc[2:0] == 3'd3 && dut.bup_osd.yc[2:0] == 3'd3) begin
			int r, c;
			bit shown, b;
			logic [23:0] rgb, px, want;
			r = int'(dut.bup_osd.row);
			c = int'(dut.bup_osd.col);
			px = {dut.bup_osd.r_out, dut.bup_osd.g_out, dut.bup_osd.b_out};
			case (ovl_pat)
				1: ovl_cell(r, c, OVL_P1_DS, OVL_P1_ST, OVL_P1_PC, OVL_P1_LD, shown, b, rgb);
				2: ovl_cell(r, c, OVL_P2_DS, OVL_P2_ST, OVL_P2_PC, OVL_P2_LD, shown, b, rgb);
				default: ovl_cell(r, c, ovl_src_q, dut.bup_osd.st, dut.bup_osd.hpc, dut.bup_osd.ld, shown, b, rgb);
			endcase
			want = !shown ? 24'h000000 : b ? rgb : (c[2] ? 24'h585858 : 24'h303030);
			ovl_px_n++;
			if (px !== want) begin
				if (ovl_px_bad < 5)
					$display("OVERLAY cell row %0d column %0d at %0.3f ms: pixel %06x, the layout says %06x", r, c, now_ns() / 1.0e6, px, want);
				ovl_px_bad++;
			end
			if (r < 9 && c < 12) begin
				ovl_cur[r][11 - c] = !(px == 24'h000000 || px == 24'h303030 || px == 24'h585858);
				ovl_cur_rows[r] = 1'b1;
				ovl_seen[r][11 - c] = 1'b1;
			end
		end
		// a frame ends: keep what it showed
		ovl_vb_q <= dut.bup_osd.vblank;
		if (dut.bup_osd.vblank && !ovl_vb_q) begin
			// rows 6-8 only while halted (not judged under the forced pattern)
			if (ovl_pat == 0 && ovl_cur_rows[8:6] != '0 && !dut.bup_osd.st[28]) begin
				if (ovl_rows_bad < 5)
					$display("OVERLAY rows %09b drawn at %0.3f ms, not halted: rows 6-8 only while halted", ovl_cur_rows, now_ns() / 1.0e6);
				ovl_rows_bad++;
			end
			if (ovl_cur_rows != '0) begin
				ovl_last = ovl_cur;
				ovl_last_rows = ovl_cur_rows;
				ovl_cur_rows = '0;
				ovl_frames++;
			end
			// the pattern's phases, each switched at a frame's end
			if (ovl_pat_ms > 0 && ovl_pat == 0 && !ovl_pat_done1 && ovl_t_sys >= ovl_pat_ms * 14318)
				ovl_force(1);
			else if (ovl_pat == 1 && ovl_frames >= ovl_pat_f0 + 2) begin
				ovl_pat_ok1 = ovl_pat_match(1);
				ovl_pat_done1 = 1'b1;
				$display("OVERLAY pattern 1 read back from overlay frame %0d: %0s", ovl_frames, ovl_pat_ok1 ? "as forced" : "NOT as forced");
				ovl_force(2);
			end
		end
		if (!reset_in) ovl_t_sys++;
	end

	// the coverage rules above: 1 when what was checked is enough
	function automatic logic [8:0] ovl_rows_done();
		logic [8:0] m;
		for (int i = 0; i < 9; i++) m[i] = ovl_seen[i] == 12'hFFF;
		return m;
	endfunction
	function automatic bit ovl_cover_ok();
		if ((ovl_rows_done() & ovl_need_rows) != ovl_need_rows) return 1'b0;
		if (ovl_rel_n < ovl_need_resets) return 1'b0;
		if (ovl_guard_n > 0 && (ovl_b_unl < ovl_guard_n || ovl_lk_n == 0)) return 1'b0;
		return ovl_px_n >= ovl_need_cells && ovl_rt_n > 0;
	endfunction
	function automatic bit ovl_timer_ok();
		if (!ovl_need_timer) return 1'b1;
		if (ovl_tw_n == 0 || ovl_tr_n == 0) return 1'b0;
		if (ovl_need_late >= 0) return int'(dut.u_dstat.late) == ovl_need_late;
		return dut.u_dstat.late > 0 && 24'(dut.u_dstat.late) < dut.u_dstat.calls;
	endfunction
	// the pattern's verdict: both phases read back as forced (when asked for)
	function automatic bit ovl_pat_ok();
		return ovl_pat_ms == 0 || (ovl_pat_ok1 && ovl_pat == 2 && ovl_frames >= ovl_pat_f0 + 2 && ovl_pat_match(2));
	endfunction
	function automatic string ovl_checked();
		string t;
		t = $sformatf("checked: %0d cells (rows complete %09b, required %09b, at least %0d cells), RIOT copy on %0d clk_sys, timer writes %0d, reads %0d",
			ovl_px_n, ovl_rows_done(), ovl_need_rows, ovl_need_cells, ovl_rt_n, ovl_tw_n, ovl_tr_n);
		if (ovl_need_timer && ovl_need_late >= 0) t = {t, $sformatf(" (required, with exactly %0d late calls)", ovl_need_late)};
		else if (ovl_need_timer) t = {t, " (required, with late calls above 0 and below the calls)"};
		t = {t, $sformatf(", reset releases %0d", ovl_rel_n)};
		if (ovl_need_resets > 0) t = {t, $sformatf(" (required at least %0d)", ovl_need_resets)};
		if (ovl_guard_n > 0)
			t = {t, $sformatf(", guard forced: %0d unlock pulses counted, locked on %0d clk_sys (required at least %0d pulses)",
				ovl_b_unl, ovl_lk_n, ovl_guard_n)};
		return t;
	endfunction

	// what the last whole frame showed, as numbers
	function automatic string ovl_shown();
		string t;
		if (ovl_frames == 0) return "the picture showed no DARIA rows";
		// each value only where its rows were drawn in that frame: a short
		// frame (a test image's) may end before the lower rows
		t = $sformatf("the picture (frame %0d of the overlay, rows %09b drawn, row 0 on the right):", ovl_frames, ovl_last_rows);
		if (ovl_last_rows[0])
			t = {t, $sformatf(" running %0d, guard %0s, halted %0d,", ovl_last[0][11], ovl_last[0][10] ? "locked" : "unlocked", ovl_last[0][8])};
		if (ovl_last_rows[1]) t = {t, $sformatf(" halt code %0d, fault code %0d,", ovl_last[1][11:8], ovl_last[1][7:0])};
		if (ovl_last_rows[2]) t = {t, $sformatf(" late calls %0d,", ovl_last[2])};
		if (ovl_last_rows[3]) t = {t, $sformatf(" unlocks %0d,", ovl_last[3])};
		if (ovl_last_rows[5:4] == 2'b11) t = {t, $sformatf(" calls %0d,", {ovl_last[4], ovl_last[5]})};
		if (ovl_last_rows[8:6] == 3'b111) t = {t, $sformatf(" halt PC %02x%03x%03x,", ovl_last[6][7:0], ovl_last[7], ovl_last[8])};
		return t.substr(0, t.len() - 2);
	endfunction
`endif
`endif

	task automatic daria_report();
		$display("DARIA result: marker %0d, self-check errors %0d, calls %0d, returns %0d, psram_viol %0d, halted %0d, guard %0s, unlocks %0d",
			dut.main.riot_inst.riot_ram.mem_q[127], dut.main.riot_inst.riot_ram.mem_q[126], dr_calls, dr_rets,
			cram0_chip.n_viol, dut.bupchip.halted,
`ifdef SIM_DARIA_FE
			dut.u_fe.dbg_locked ? "locked" : "unlocked",
`else
			"absent (atari7800_pocket.sv has no daria_fe u_fe)",
`endif
			dr_unlocks);
`ifdef BUP_DEBUG
`ifdef SIM_DARIA_FE
		// The overlay's own line: its counts against this bench's, the RIOT
		// copy, the cells read back, what was checked against what this run
		// requires (+ovl_rows, +ovl_cells, +ovl_timer), the pattern's phases
		// (+ovl_pattern_at), what the picture showed in the last whole frame,
		// and the verdict: PASS, or FAIL with the terms that failed.
		begin
			string why, pat, res;
			why = "";
			if (dut.u_dstat.calls != 24'(ovl_b_calls)) why = {why, " calls"};
			if (dut.u_dstat.unl != 12'(ovl_b_unl > 4095 ? 4095 : ovl_b_unl)) why = {why, " unlocks"};
			if (ovl_lk_bad != 0 || dut.u_dstat.locked !== dut.daria_dbg_locked) why = {why, " guard"};
			if (ovl_rt_bad != 0) why = {why, " riot-copy"};
			if (ovl_px_bad != 0) why = {why, " cells"};
			if (ovl_rows_bad != 0) why = {why, " rows"};
			if (!ovl_cover_ok()) why = {why, " coverage"};
			if (!ovl_timer_ok()) why = {why, " timer"};
			if (!ovl_pat_ok()) why = {why, " pattern"};
			if (ovl_pat_ms == 0) pat = "not forced";
			else if (ovl_pat_ok()) pat = "read back as forced (both phases, nine rows)";
			else pat = "NOT read back as forced";
			if (why == "") res = "PASS";
			else res = {"FAIL (", why.substr(1, why.len() - 1), ")"};
			$display("DARIA overlay: calls %0d (bench %0d since the last reset, %0d since power-up), late calls %0d, unlocks %0d (bench %0d), guard %0s (differs on %0d clk_sys); RIOT copy differs on %0d clk_sys; %0d of %0d cells read back differ from the layout; %0d frames drew rows 6-8 while not halted; %0s; pattern %0s; %0s; %0s",
				dut.u_dstat.calls, ovl_b_calls, dr_calls, dut.u_dstat.late, dut.u_dstat.unl, ovl_b_unl, dut.u_dstat.locked ? "locked" : "unlocked",
				ovl_lk_bad, ovl_rt_bad, ovl_px_bad, ovl_px_n, ovl_rows_bad, ovl_checked(), pat, ovl_shown(), res);
		end
`endif
`endif
	endtask
`endif

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

	// ---------------- CPU probe (+cpuprobe) ----------------
	// MARIA register writes (the first 300, and every CTRL write), and at 1,
	// 3 and 5 s 96 consecutive bus addresses (repeats dropped): where a game
	// that shows nothing is spending its time.
	logic cp_on = 1'b0, cp_old_w = 1'b0;
	int   cp_mw = 0, cp_win = 0, cp_rnd = 0;
	logic cp_rnd_prev = 1'b0;
	logic [7:0] cp_rnd_db = 8'd0;
	logic [15:0] cp_last = 16'hFFFF;
	initial cp_on = $test$plusargs("cpuprobe");
	always @(posedge clk_sys) if (cp_on && !reset_in) begin
		automatic longint ms = longint'($realtime / 1.0e6);
		cp_old_w <= !dut.RW && dut.main.cs_maria;
		if (!cp_old_w && !dut.RW && dut.main.cs_maria && (cp_mw < 300 || dut.bios_addr[5:0] == 6'h3C)) begin
			$display("MARIA %0d ms: $%04x = $%02x", ms, dut.bios_addr, dut.main.write_DB);
			cp_mw <= cp_mw + 1;
		end
		if ((ms == 1000 || ms == 3000 || ms == 5000) && cp_win == 0) cp_win <= 96;
		if (cp_win > 0 && dut.bios_addr != cp_last) begin
			$display("PC %0d ms: $%04x %s", ms, dut.bios_addr, dut.RW ? "r" : "w");
			cp_last <= dut.bios_addr;
			cp_win <= (cp_win == 1) ? -1 : cp_win - 1;
		end
		if (cp_win < 0 && ms != 1000 && ms != 3000 && ms != 5000) cp_win <= 0;
		// POKEY RANDOM at $450 + $A: the value on the bus as each read ends
		cp_rnd_prev <= (dut.RW && dut.bios_addr == 16'h045A);
		cp_rnd_db   <= dut.main.read_DB;
		if (cp_rnd_prev && !(dut.RW && dut.bios_addr == 16'h045A) && cp_rnd < 40) begin
			$display("RANDOM %0d ms: $%02x", ms, cp_rnd_db);
			cp_rnd <= cp_rnd + 1;
		end
	end

	// ---------------- POKEY reads (+pokeyrd=MS) ----------------
	// sim/pokey_read_test.py's cartridge reads POKEY's RANDOM 40 times, then
	// IRQST idle, with timer 1's interrupt fired and with it cleared again,
	// and stores what the CPU got in RAM at $2210-$2237 and $2240-$2242;
	// $2200 = $A5 once it is done. +pokeyrd=MS runs MS ms after the reset
	// and prints that RAM; run_sim.sh's POKEY read section and
	// sim/check/run_sim_check.py judge it (2.2.2's read fix, READ_WHOLE_CYCLE
	// in Pokey/pokey_adapter.sv: without it every read is $FF).
	int pr_ms = 0;
	function automatic logic [7:0] pr_ram(int a);   // RAM0, $2000-$27FF
		return dut.main.ram0.u_ram.mem_q[a - 'h2000];
	endfunction
	task automatic pokeyrd_report();
		string s = "";
		int nff = 0, nd = 0;
		bit seen [256];
		for (int i = 0; i < 40; i++) begin
			automatic logic [7:0] v = pr_ram('h2210 + i);
			s = {s, $sformatf(" %02x", v)};
			if (v == 8'hFF) nff++;
			if (!seen[v]) begin seen[v] = 1'b1; nd++; end
		end
		$display("POKEYRD marker $%02x after %0d ms", pr_ram('h2200), pr_ms);
		$display("POKEYRD RANDOM 40 reads, %0d of them $FF, %0d distinct:%s", nff, nd, s);
		$display("POKEYRD IRQST idle $%02x, timer 1 fired $%02x, IRQEN cleared $%02x",
			pr_ram('h2240), pr_ram('h2241), pr_ram('h2242));
	endtask

	// ---------------- boot probe ----------------
	// At each release of the core's reset (top.sv's effective_reset): the
	// BIOS switch as the core got it (use_bios, and top.sv's bypass_bios,
	// tia_mode and cart_present). Then the 6502's reset vector, read at
	// $FFFC/$FFFD, and its first opcode fetch, each with where the bytes came
	// from: the BIOS ROM (top.sv's bios_sel) or the cartridge slot. Then, 50
	// ms after the release (or at the next reset), the CPU's reads from the
	// BIOS ROM so far, and tia_en. run_sim.sh's BIOS tests check these lines.
	`define BOOT_CPU dut.main.cpu_inst.cpu
	int boot_n = 0;
	logic boot_rst_d = 1'b1, boot_on = 1'b0, boot_fetched = 1'b0;
	logic [1:0] boot_vec_seen = 2'b00, boot_vec_bios = 2'b00;
	logic [15:0] boot_vec = 16'h0000;
	longint boot_t0 = 0, boot_bios_rd = 0;
	function automatic string boot_src(logic [1:0] from_bios);
		return from_bios == 2'b11 ? "the BIOS ROM" : from_bios == 2'b00 ? "the cartridge slot" : "both";
	endfunction
	always @(posedge clk_sys) begin
		boot_rst_d <= dut.main.effective_reset;
		if (boot_on && (dut.main.effective_reset || $time - boot_t0 >= 50000000)) begin
			$display("BOOT %0d after %0d ms: %0d CPU reads from the BIOS ROM, tia_en %0d",
				boot_n, ($time - boot_t0) / 1000000, boot_bios_rd, dut.main.tia_en);
			boot_on = 1'b0;
		end
		if (boot_rst_d && !dut.main.effective_reset) begin
			boot_n++;
			boot_on = 1'b1; boot_fetched = 1'b0; boot_vec_seen = 2'b00; boot_vec_bios = 2'b00;
			boot_bios_rd = 0; boot_t0 = $time;
			$display("BOOT %0d at %0d ms: use_bios %0d, bypass_bios %0d, tia_mode %0d, cart_present %0d",
				boot_n, $time / 1000000, dut.use_bios, dut.main.bypass_bios, dut.main.tia_mode, dut.main.cart_present);
		end
		// A read cycle of the CPU's own, at the edge where it takes the byte
		if (boot_on && `BOOT_CPU.core_phi2_en && `BOOT_CPU.rw_n) begin
			if (dut.main.bios_sel) boot_bios_rd++;
			for (int k = 0; k < 2; k++)
				if (`BOOT_CPU.addr_out == 16'hFFFC + 16'(k) && !boot_vec_seen[k]) begin
					boot_vec_seen[k] = 1'b1;
					boot_vec_bios[k] = dut.main.bios_sel;
					if (k == 0) boot_vec[7:0] = `BOOT_CPU.data_in; else boot_vec[15:8] = `BOOT_CPU.data_in;
				end
			// The first SYNC after the vector: the reset sequence raises SYNC
			// once before it, on its first cycle.
			if (`BOOT_CPU.sync && boot_vec_seen == 2'b11 && !boot_fetched) begin
				boot_fetched = 1'b1;
				$display("BOOT %0d vector: $%04x from %0s, first opcode fetch at $%04x from %0s", boot_n, boot_vec,
					boot_src(boot_vec_bios), `BOOT_CPU.addr_out, boot_src({2{dut.main.bios_sel}}));
			end
		end
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

	// ---------------- AtariVox probe (+voxlog) ----------------
	// The AtariVox's serial line: port 2's UP pin (RIOT port A bit 0), which
	// the game pulls low through the DDR. 8N1, not inverted. The AtariVox
	// drivers send a bit every 62 CPU cycles (about 19,250 baud; 744
	// clk_sys in 2600 mode), so this samples mid-bit at that rate and logs
	// each byte with its time.
	logic vox_on = 1'b0, vox_old = 1'b1;
	int   vox_cnt = 0, vox_bit = -1;
	logic [7:0] vox_sh = 0;
	initial vox_on = $test$plusargs("voxlog");
	always @(posedge clk_sys) if (vox_on) begin
		vox_old <= dut.main.PAout[0];
		if (vox_bit < 0) begin
			if (vox_old && !dut.main.PAout[0]) begin   // start bit
				vox_bit <= 0; vox_cnt <= 744 + 372;
			end
		end else if (vox_cnt > 1)
			vox_cnt <= vox_cnt - 1;
		else begin
			vox_cnt <= 744;
			if (vox_bit < 8) begin
				vox_sh <= {dut.main.PAout[0], vox_sh[7:1]};
				vox_bit <= vox_bit + 1;
			end else begin
				$display("VOX %0d.%03d ms: %3d $%02x%s", $time / 1000000, ($time / 1000) % 1000,
					vox_sh, vox_sh, dut.main.PAout[0] ? "" : " (no stop bit)");
				vox_bit <= -1;
			end
		end
	end

`ifdef POCKET_ATARIVOX
	// ---------------- AtariVox voice (+voxpcm) ----------------
	// Every sample the AtariVox engine puts out (16,384 Hz, s16le) to
	// vox.pcm; tools/atarivox/sjhw.py's write_wav scale is x8.
	integer voxpcm_fd = 0;
	initial if ($test$plusargs("voxpcm")) voxpcm_fd = $fopen("vox.pcm", "wb");
	always @(posedge clk_sys)
		if (voxpcm_fd != 0 && dut.atarivox.engine.sample_strobe)
			$fwrite(voxpcm_fd, "%c%c", dut.atarivox.sample[7:0], dut.atarivox.sample[15:8]);
`endif

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

	// The cart's tone is counted on the console's own mix, before the
	// AtariVox voice. With POCKET_ATARIVOX the voice runs whenever the SaveKey
	// does and the AtariVox Voice setting is not Off (tb default Normal), and
	// AUDIO_L then carries it on a +32,768 bias (atari7800_pocket.sv, vox_add),
	// so it never returns to 0 and the SaveKey runs' tone read 0 Hz. With the
	// voice off, vox_add is 0 and core_audio_l is AUDIO_L.
`ifdef POCKET_ATARIVOX
	wire [15:0] tone_aud = dut.core_audio_l;
`else
	wire [15:0] tone_aud = AUDIO_L;
`endif
	longint rises = 0;
	logic [15:0] old_aud = 0;
	logic counting = 0;
	always @(posedge clk_sys) begin
		old_aud <= tone_aud;
		if (counting && tone_aud > old_aud && old_aud == 16'd0)
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
	// The FA2 flash's save slot (fa2.sav, 256 bytes, bridge words 0-63):
	// +fa2save, +fa2expect and +fa2prog (below). The counters follow
	// mapper_fa2's copies: a flash load that reached byte $FF, a save's
	// dirty pulse, and the bridge's writes into the slot's RAM.
	logic [7:0] fa2_img [0:255];
	logic [7:0] fa2_exp [0:255];
	bit have_fa2 = 0, fa2_prog = 0;
	string fa2_path;
	int fa2_diffs, fa2_loads = 0, fa2_saves = 0, fa2_port_wr = 0;
	always @(posedge clk_sys) begin
		if (dut.fa2_ram_we) fa2_port_wr++;
		if (dut.main.cart2600.mapper_FA2.copy_state == 3'd1 && dut.main.cart2600.mapper_FA2.nvram_ready
		    && dut.main.cart2600.mapper_FA2.copy_addr == 8'hFF) fa2_loads++;
		if (dut.main.cart2600.mapper_FA2.nvram_dirty) fa2_saves++;
	end
	// Read the FA2 slot back the way the Pocket saves it, with the HSC's APF
	// read protocol (below): 65 transactions for 64 words, the last address
	// wrapping to word 0. fa2_diffs counts the bytes that differ from fa2_exp.
	task automatic fa2_readback();
		fa2_diffs = 0;
		for (int t = 0; t <= 64; t++) begin
			logic [31:0] got;
			@(posedge clk_74a); fa2_addr = t[5:0];
			repeat (4) @(posedge clk_74a);
			got = fa2_dout;
			fa2_rd = 1'b1; @(posedge clk_74a); fa2_rd = 1'b0;
			repeat (2) @(posedge clk_74a);
			if (t > 0)
				for (int k = 0; k < 4; k++)
					if (got[31 - 8*k -: 8] !== fa2_exp[4*(t-1) + k]) begin
						if (fa2_diffs < 8)
							$display("  FA2 byte %02x: expected %02x, read back %02x", 4*(t-1) + k,
								fa2_exp[4*(t-1) + k], got[31 - 8*k -: 8]);
						fa2_diffs++;
					end
		end
	endtask

	// +bios=FILE: the 7800 BIOS through its data slot (0x103, bridge address
	// 0x02000000, data.json's), at most 16 KiB.
	string bios_path;
	logic [7:0] bios_img [$];
	task automatic load_bios();
		int n;
		if ($value$plusargs("bios=%s", bios_path)) begin
			bios_img.delete();
			fd = $fopen(bios_path, "rb");
			if (fd == 0) begin $display("cannot open %s", bios_path); $finish; end
			c = $fgetc(fd);
			while (c != -1) begin bios_img.push_back(c[7:0]); c = $fgetc(fd); end
			$fclose(fd);
			n = bios_img.size();
			while (bios_img.size() % 4) bios_img.push_back(8'hFF);
			bios_download = 1'b1;
			repeat (100) @(posedge clk_74a);
			for (int i = 0; i < bios_img.size(); i += 4) begin
				@(posedge clk_74a);
				bridge_addr = 32'h02000000 + i;
				bridge_wr_data = {bios_img[i], bios_img[i+1], bios_img[i+2], bios_img[i+3]};
				bridge_wr = 1'b1;
				@(posedge clk_74a);
				bridge_wr = 1'b0;
				repeat (78) @(posedge clk_74a);
			end
			repeat (2000) @(posedge clk_74a);
			bios_download = 1'b0;
			repeat (100) @(posedge clk_sys);
			$display("BIOS slot: %0d byte file, bios_loaded %0d, address mask %04x, skip_bios %0d",
				n, dut.bios_loaded, dut.bios_mask, skip_bios);
		end
	endtask

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
		if (!nocart) begin
			fd = $fopen(path, "rb");
			if (fd == 0) begin $display("cannot open %s", path); $finish; end
			while ((c = $fgetc(fd)) != -1) image.push_back(c[7:0]);
			$fclose(fd);
		end
		image_n = image.size();
		while (image.size() % 4) image.push_back(8'hFF);

		if ($test$plusargs("hsc_on")) hsc_setting = 2'd1;
		if ($test$plusargs("hsc_off")) hsc_setting = 2'd2;
		if ($test$plusargs("sk_on")) sk_setting = 2'd1;
		if ($test$plusargs("sk_auto")) sk_setting = 2'd0;
		void'($value$plusargs("voxset=%d", vox_setting));   // AtariVox voice: 0 off .. 3 loud
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
		// +fa2save=FILE: write a 256-byte FA2 flash file through its save slot
		// port while the core is held in reset, as for +save. +fa2expect=FILE:
		// what the slot must hold when it is read back at the end (default:
		// the +fa2save file, or blank $FF without one). Either one turns the
		// read-back on.
		for (int i = 0; i < 256; i++) fa2_img[i] = 8'hFF;
		if ($value$plusargs("fa2save=%s", fa2_path)) begin
			fd = $fopen(fa2_path, "rb");
			if (fd == 0) begin $display("cannot open %s", fa2_path); $finish; end
			for (int i = 0; i < 256; i++) begin c = $fgetc(fd); fa2_img[i] = c[7:0]; end
			$fclose(fd);
			for (int i = 0; i < 64; i++) begin
				@(posedge clk_74a);
				fa2_addr = i[5:0];
				fa2_din = {fa2_img[4*i], fa2_img[4*i+1], fa2_img[4*i+2], fa2_img[4*i+3]};
				fa2_wr = 1'b1;
				@(posedge clk_74a);
				fa2_wr = 1'b0;
				repeat (20) @(posedge clk_74a);
			end
			have_fa2 = 1;
		end
		for (int i = 0; i < 256; i++) fa2_exp[i] = fa2_img[i];
		if ($value$plusargs("fa2expect=%s", fa2_path)) begin
			fd = $fopen(fa2_path, "rb");
			if (fd == 0) begin $display("cannot open %s", fa2_path); $finish; end
			for (int i = 0; i < 256; i++) begin c = $fgetc(fd); fa2_exp[i] = c[7:0]; end
			$fclose(fd);
			have_fa2 = 1;
		end
		fa2_prog = $test$plusargs("fa2prog");
		if (!$test$plusargs("bioslast")) load_bios();
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
		if (!nocart) begin
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
		end
`ifdef POCKET_BUPCHIP
		if ($test$plusargs("bupfwlast")) begin
			repeat (100) @(posedge clk_74a);
			load_bupfw();
		end
`endif
		if ($test$plusargs("bioslast")) begin
			repeat (100) @(posedge clk_74a);
			load_bios();
		end

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
		if (stop74) begin
			if ($test$plusargs("bupms")) $display("STOP74 refused: +bupms needs clk_74a (the BupChip's 48 kHz tick)");
			else begin
				run74 = 1'b0;
				$display("STOP74 clk_74a stopped at %0.3f ms", $realtime / 1.0e6);
			end
		end
		reset_in = 1'b0;
		if (ext_end) wait (1'b0);
		if ($value$plusargs("pokeyrd=%d", pr_ms)) begin
			run_ms(pr_ms);
			pokeyrd_report();
			$finish;
		end
`ifdef POCKET_DARIA
		if ($value$plusargs("daria=%d", daria_ms)) begin
			for (int ms_i = 0; ms_i < daria_ms; ms_i++) repeat (14318) @(posedge clk_sys);
			daria_report();
			$finish;
		end
`endif
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
		if (fa2_prog) begin
			// +fa2prog: the cartridge is sim/fa2_test.py's FA2 program. It
			// loads the flash into the mapper's work RAM (command 1), writes
			// bytes 0-254 back inverted, saves the work RAM (command 2), fills
			// bytes 0-254 with $5A, loads the flash again and stores $A5 at
			// $80. Wait for that (at most 2 s), then check the reload in the
			// work RAM and the save slot through the APF read protocol.
			automatic int ms = 0;
			while (dut.main.riot_inst.riot_ram.mem_q[0] !== 8'hA5 && ms < 2000) begin
				repeat (14318) @(posedge clk_sys);
				ms++;
			end
			$display("FA2 program: mapper %0d, %0s after %0d ms; flash loads %0d, saves %0d, slot RAM writes %0d",
				dut.main.cart2600.mapper, dut.main.riot_inst.riot_ram.mem_q[0] === 8'hA5 ? "done" : "not done",
				ms, fa2_loads, fa2_saves, fa2_port_wr);
			fa2_diffs = 0;
			for (int i = 0; i < 255; i++)
				if (dut.main.cart2600.mapper_FA2.working_ram.u_ram.mem_q[i] !== fa2_exp[i]) fa2_diffs++;
			$display("FA2 work RAM after the reload: %0d of 255 bytes differ from the expected file", fa2_diffs);
			run74 = 1'b1;
			fa2_readback();
			$display("FA2 save slot read back (APF read protocol): %0d of 256 bytes differ from the expected file", fa2_diffs);
			$finish;
		end
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
					run74 = 1'b1;
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
					if (stop74) run74 = 1'b0;
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
		run74 = 1'b1;   // the save-slot reads below are clk_74a transactions
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
		if (have_fa2) begin
			// What ran beside the file: the 2600 mapper detect2600.sv chose
			// (25 = BANKFA2, which runs mapper_fa2.sv), the mode, and
			// mapper_fa2's copies (a save counts once it is done, whether
			// or not it reached the slot) and the slot RAM's writes.
			$display("FA2 image: 2600 mapper %0d, cart_is_7800 %0d, tia_mode %0d; flash loads %0d, saves %0d, slot RAM writes %0d",
				dut.main.cart2600.mapper, dut.cart_is_7800, dut.tia_mode, fa2_loads, fa2_saves, fa2_port_wr);
			fa2_readback();
			$display("FA2 save slot after load, reset and 300 ms of running (APF read protocol): %0d of 256 bytes differ from the expected file", fa2_diffs);
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
