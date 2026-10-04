//------------------------------------------------------------------------------
// Step 4 of docs/BUPCHIP_CORE.md: the whole Pocket BupChip
// (src/fpga/core/bupchip/bupchip_pocket.sv) with its three real clocks, fed
// the way the Pocket feeds it.
//
//   clk_sys  14.318 MHz, clk_arm 28.636 MHz (2 x, edge aligned) or with
//            +arm15 21.477 MHz (1.5 x, rising edges together every 2 clk_sys);
//            both x 0.99088 in PAL; clk_74a 74.25 MHz (asynchronous)
//   loader   one byte per +bytens ns (default 2.5 clk_sys: 174.6 ns, or 176.2
//            in PAL, data_loader.sv's 10 clk_sdram) plus a random
//            0..+bytejit ns, as a one-clock clk_sys strobe,
//            first the firmware slot (+fw, bupchip.bin), then the cartridge
//            (+rom); the cartridge's header byte 53 sets souper_profile, as
//            atari7800_pocket.sv's cart_flags does
//   PSRAM    agg23's psram.sv (src/fpga/pocket_utils/) at CLOCK_SPEED =
//            28.636364 on a psram_model.sv die, or, built with
//            -DPSRAM_STANDIN, psram_standin.sv (the same port timing)
//   command  $80|+song on the clk_sys command port once the firmware has
//            enabled PCM, as cart.sv's $8007 pair does
//
// Checks while it runs: the CPU never halts, makes no access while held, and
// reads r0-r14 as 0 at its first instruction after each release; the
// firmware words in the ROM and the ARSC bytes in the PSRAM equal the files
// once each download is published; no capture message is lost (bup_capture's
// seq_err, lost and simulation-only byte-order check, bup_asset_wr's
// overrun); every frame the wrapper hands to clk_sys arrives once, in order,
// as 0 while souper_profile is low, and a frame ticked while held, paused or
// muted is 0; the BUP_DEBUG shadow counters equal the peripheral's own
// levels on every clock, and its flags the events since the last hold; no
// asset load completes on, and no tick takes the PCM FIFO's head from, an
// M10K read registered on the same edge as a write of that address through
// the other port (from the RAM instances' own ports); every firmware write to
// 0x18 leaves the peripheral's watermark at clamp(W - (4096 - PCM_DEPTH), 0,
// PCM_DEPTH), worked out here from the CPU's own write data; while held the
// cache starts no PSRAM read and writes its data M10K only in the first held
// clock, into a line whose tag is invalid (a read in flight landing).
//
// Outputs (+out=PREFIX): PREFIX.pcm, every frame the firmware pushed since the
// last (re)boot; PREFIX.out.pcm, every frame the wrapper returned to clk_sys
// since then; PREFIX.batches, "clocks instructions" per batch. The log gives
// the frame index where the song starts in each ("song start: pushed N,
// output M") for pcm_check.py --song-start. Busy, CPI and MIPS are counted by
// the retired PC, as tb_s1.sv does; the FIFO's lowest level and underflow /
// overflow are counted from the command on, and underflow also from boot.
//
// Plusargs:
//   +fw=FILE        firmware slot image; without it no firmware is loaded
//   +rom=FILE       cartridge image (.a78 with its ARSC block)
//   +song=N +secs=S command $80|N (default 13), S seconds of pops (default 4)
//   +pops=N         N pops instead of 48,000 x S (the last play only)
//   +out=PREFIX     output files (default s4)
//   +bytens=NS +bytejit=NS   loader byte period and random extra (174.6, 0)
//   +endgap=N       clk_sys clocks from the last byte to the end of a
//                   download (default 1)
//   +skiprom        do not send the cartridge ROM's own bytes (header and
//                   ARSC block only): quicker, the BupChip ignores them
//   +pal            PAL clocks from the start
//   +arm15          clk_arm at 1.5 x clk_sys (21.477 MHz; 21.281 with +pal),
//                   S3's clock, instead of 2 x
//   +silent=MS      no song: after the downloads, run MS ms and require the
//                   BupChip held and silent (missing or short firmware)
//   +reload=MS      MS ms into the song, download +rom2 (default +rom) again,
//                   then boot, command and play +secs again
//   +reloads=N      N reloads (default 1, at most 4), each MS ms into the
//                   last song: reload k downloads +rom<k+1> (default +rom). An
//                   image the BupChip cannot play (not a Souper cartridge, or
//                   no ARSC block) must leave it held and silent for 20 ms, and
//                   the next reload follows at once; the last image must play.
//   +retune=MS      MS ms into the song, a PAL retune (pll_busy, pll_locked
//                   low, clocks x 0.99088), then boot, command and play again
//                   (before any reloads)
//   +holdfill       start each reload or retune once a cache fill has a
//                   PSRAM read in flight and at least 6 halfwords to go, so
//                   the hold lands during the fill; the log and the result
//                   line count the holds that came with a fill running, with
//                   a read in flight, and of those the ones where psram.sv
//                   was mid-access (busy) or delivering the halfword
//   +holddelay=N +holdstep=S   with +holdfill, wait N + k S more clk_arm
//                   clocks before hold k (k = 0, 1, ...): the hold reaches
//                   the cache a fixed 9 clocks after the trigger, so this
//                   moves it through the 5 clocks of a PSRAM read
//   +pause=MS +pauselen=MS   drive pause for pauselen ms from MS ms into the
//                   song (default 20 ms): no pop and silence meanwhile
//   +forcetick      force a 48 kHz tick into the first clock after a push
//                   into the empty FIFO while PCM is enabled: pcm_available
//                   has just risen, and the peripheral's M10K presents the
//                   frame a clock later; the wrapper must take the tick then
//                   ("pop" in the log; "forced" in the result line). Only
//                   firmware that lets the FIFO run empty reaches it
//                   (stress/fw_pophead.S); CoreTone at speed never does
//   +forcetick_after=MS   arm +forcetick only from MS ms of simulated time
//   +wmsweep        at time 0, every write value (W = 0..8,191 at 0x18, a
//                   sample of them elsewhere) through the watermark remap,
//                   against the formula
//   +seed=S         loader jitter (default 1)
//   +maxms=MS       stop waiting after MS ms of simulated time (default
//                   6000, or SECS x 1000 + 2000 when that is more); a play
//                   that reaches it before its pops are done, or a run still
//                   going 1 s later, ends with "result: timeout"
//
// The last line, "result: ...", is for run_s4.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
`ifndef PCM_DEPTH
`define PCM_DEPTH 1024
`endif
`ifndef PREEMPT
`define PREEMPT 1
`endif
`ifndef PREFETCH
`define PREFETCH 1
`endif
`ifndef BUP_THROTTLE
`define BUP_THROTTLE 16
`endif

module tb_s4;
	localparam int PCM_DEPTH = `PCM_DEPTH;

	// ---- clocks ------------------------------------------------------------------------
	longint arm_half = 17460;           // ps: 28.636 MHz; clk_sys is half the rate
	longint u15 = 11640;                // ps, +arm15: clk_arm period 4 u15, clk_sys 6 u15
	bit     r15 = 0;
	real    arm_mhz = 28.636364;
	logic   clk_arm = 0, clk_sys = 0, clk_74a = 0;
	initial forever begin
		if (!r15) begin
			#(arm_half); clk_arm = 1; clk_sys = 1;
			#(arm_half); clk_arm = 0;
			#(arm_half); clk_arm = 1;
			#(arm_half); clk_arm = 0; clk_sys = 0;
		end else begin                  // rising edges together every 12 u15
			#(2 * u15); clk_arm = 1; clk_sys = 1;
			#(2 * u15); clk_arm = 0;
			#(u15);     clk_sys = 0;
			#(u15);     clk_arm = 1;
			#(2 * u15); clk_arm = 0; clk_sys = 1;
			#(2 * u15); clk_arm = 1;
			#(u15);     clk_sys = 0;
			#(u15);     clk_arm = 0;
		end
	end
	always #6734 clk_74a = ~clk_74a;

	function automatic longint arm_per();
		return r15 ? 4 * u15 : 2 * arm_half;
	endfunction
	function automatic longint sys_per();
		return r15 ? 6 * u15 : 4 * arm_half;
	endfunction

	task automatic set_pal(input bit pal);
		arm_half = pal ? 17621 : 17460;
		u15 = pal ? 11747 : 11640;
		arm_mhz = (r15 ? 21.477273 : 28.636364) * (pal ? 0.99088 : 1.0);
	endtask

	// ---- the wrapper's inputs ----------------------------------------------------------------
	logic        pll_locked = 0, pll_busy = 0, souper = 0, pause = 0;
	logic        cart_dl = 0, cart_dl_q = 0, fw_dl = 0, ld_wr = 0;
	logic [24:0] ld_addr = 0;
	logic  [7:0] ld_data = 0;
	logic        cmd_valid = 0;
	logic  [7:0] cmd_data = 0;
	always @(posedge clk_sys) cart_dl_q <= cart_dl;
	// cart_flags[12], from header byte 53 as it streams past
	always @(posedge clk_sys) if (cart_dl && ld_wr && ld_addr == 25'd53) souper <= ld_data[4];

	wire [15:0] audio_l, audio_r;
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	wire [31:0] dbg_status, dbg_halt_pc;

	bupchip_pocket #(.PCM_DEPTH(PCM_DEPTH), .PREEMPT(`PREEMPT), .PREFETCH(`PREFETCH),
		.BUP_THROTTLE(`BUP_THROTTLE)) dut (
		.clk_sys, .clk_arm, .clk_74a,
		.pll_locked, .pll_busy, .souper_profile(souper), .pause,
		.byte_valid(ld_wr && (cart_dl || fw_dl)), .byte_hi(fw_dl ? 3'd5 : 3'd0),	// slot address bits 27:25
		.load_addr(ld_addr), .load_data(ld_data),
		.load_start(cart_dl && !cart_dl_q), .load_end(!cart_dl && cart_dl_q),
		.fw_download(fw_dl),
		.cmd_valid, .cmd_data,
		.audio_l, .audio_r,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_read_avail(p_avail), .psram_data_out(p_dout), .psram_busy(p_busy),
		.dbg_status, .dbg_halt_pc, .dbg_load());

`ifdef PSRAM_STANDIN
	psram_standin ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy));
	function automatic logic [8:0] psram_byte(input int b);	// {written, byte}
		logic [15:0] h;
		h = ps.mem[b >> 1];
		return {1'b1, b[0] ? h[15:8] : h[7:0]};
	endfunction
	localparam string PSRAM_KIND = "stand-in (psram_standin.sv)";
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
	localparam string PSRAM_KIND = "psram.sv + psram_model.sv";
`endif

	// ---- images and the loader ------------------------------------------------------------------
	logic [7:0] img [0:4194303];
	logic [7:0] fwb [0:65535];
	int         img_n = 0, fw_n = 0, a_base = 0, a_size = 0;
	real        byte_ps = 0.0, jit_ps = 0.0;      // ns until the plusargs are read, then ps
	bit         byte_set = 0;                     // +bytens given; else 2.5 clk_sys per byte
	int         endgap = 1;
	bit         skiprom = 0;

	task automatic read_image(input string f);
		int fd;
		fd = $fopen(f, "rb");
		if (fd == 0) $fatal(1, "cannot open %s", f);
		img_n = $fread(img, fd);
		$fclose(fd);
		a_base = 128 + {img[49], img[50], img[51], img[52]};
		a_size = img_n > a_base ? img_n - a_base : 0;
		if (a_size >= (1 << 23)) a_size = 1 << 23;
	endtask

	// One byte per strobe, as core_top.v's clk_sys register presents
	// data_loader.sv's: byte k is sampled on the first clk_sys edge at or
	// after k byte periods from the start.
	task automatic loader_send(input bit fw, input int n);
		real t, p, bp;
		@(posedge clk_sys);
		t = $realtime;
		bp = byte_set ? byte_ps : 2.5 * real'(sys_per());
		for (int k = 0; k < n; k++) begin
			if (!fw && skiprom && k >= 128 && k < a_base) continue;
			t += bp + (jit_ps > 0.0 ? real'($urandom_range(1000)) * jit_ps / 1000.0 : 0.0);
			p = real'(sys_per());
			while ($realtime < t - p) @(posedge clk_sys);
			ld_wr <= 1;
			ld_addr <= 25'(k);
			ld_data <= fw ? fwb[k] : img[k];
			@(posedge clk_sys);
			ld_wr <= 0;
		end
	endtask

	longint t_dl_start, t_dl_end;
	task automatic download(input bit fw);
		if (fw) fw_dl <= 1; else cart_dl <= 1;
		repeat (20) @(posedge clk_sys);
		t_dl_start = $time;
		loader_send(fw, fw ? fw_n : img_n);
		repeat (endgap) @(posedge clk_sys);
		if (fw) fw_dl <= 0; else cart_dl <= 0;
		t_dl_end = $time;
		@(posedge clk_sys);
	endtask

	// ---- what the downloads left behind ------------------------------------------------------------
	int rom_bad = 0, psram_bad = 0;
	task automatic check_rom();
		int bad;
		bad = 0;
		for (int w = 0; w < 4096; w++) begin
			logic [31:0] e;
			e = 0;
			for (int b = 0; b < 4; b++)
				if (4 * w + b < fw_n && 4 * w + b < 16384) e[8 * b +: 8] = fwb[4 * w + b];
			if (dut.rom.mem_q[w] !== e) begin
				if (bad < 5) $display("ROM word %0d: %08x, file %08x", w, dut.rom.mem_q[w], e);
				bad++;
			end
		end
		rom_bad += bad;
		$display("ROM check: %0d of 4,096 words differ from the firmware file (%0d bytes)", bad, fw_n);
	endtask

	task automatic check_psram();
		int bad;
		bad = 0;
		for (int b = 0; b < a_size; b++) begin
			logic [8:0] v;
			v = psram_byte(b);
			if (!v[8] || v[7:0] !== img[a_base + b]) begin
				if (bad < 5) $display("PSRAM byte %0d: %s%02x, file %02x", b, v[8] ? "" : "unwritten ", v[7:0], img[a_base + b]);
				bad++;
			end
		end
		psram_bad += bad;
		$display("PSRAM check: %0d of %0d ARSC bytes differ; asset_size %0d, asset_ready %0d",
			bad, a_size, dut.asset_size, dut.asset_ready);
	endtask

	// ---- measurement on clk_arm ------------------------------------------------------------------
	longint cyc = 0, charge = 0, nret = 0;
	longint busy = 0, work = 0, mclk = 0, pops = 0, under = 0, over = 0, pushes = 0, mpushes = 0;
	longint under_all = 0, over_all = 0;
	longint bclk = 0, bins_n = 0, nbatch = 0, cmd_cyc = -1, song_frame = -1, take_cyc = -1;
	longint c_miss = 0, c_pf = 0, c_pre = 0, c_late = 0, c_stall = 0, c_wasset = 0;
	longint shadow_bad = 0, held_push = 0, pause_pops = 0;
	int     minlev = 1 << 30, pcm_fd = 0, out_fd = 0, bat_fd = 0;
	logic   measuring = 0, in_batch = 0, check_clear = 0, clear_ok = 1, halt_seen = 0, in_pause = 0;
	logic   run_q = 0;
	longint tick_idx = 0, rec_base = 0, apops = 0, song_tick = -1;
	longint unf_since_hold = 0, ovf_since_hold = 0;
	logic   tick_q = 0, tick_paused = 0, tick_held = 0, tick_muted = 0;
	longint mute_bad = 0, n_muted = 0;
	longint n_tick_hold = 0;
	longint n_holds = 0, n_hold_fill = 0, n_hold_fl = 0;	// cpu_run falls; with a fill running; with a read in flight
	longint n_hold_mid = 0, n_hold_land = 0;	// of those: psram.sv mid-access; delivering the halfword
	longint rd_held = 0, held_wr = 0, held_wr1 = 0;	// reads started while held; data M10K writes while held
	typedef struct { longint idx; logic [31:0] val; logic paused, held, muted; } frame_t;
	int     wm_w = 0, wm_exp = 0, wm_last = -1;
	longint n_wm = 0, wm_bad = 0;
	bit     wm_chk = 0;
	function automatic int wm_remap(input int w);
		int sh;
		sh = 4096 - PCM_DEPTH;
		return w <= sh ? 0 : w - sh >= PCM_DEPTH ? PCM_DEPTH : w - sh;
	endfunction
	frame_t fq[$];

	always @(posedge clk_arm) begin
		cyc++;
		charge++;
		// the wrapper's frame register, one clock after each tick
		if (tick_q) begin
			frame_t f;
			f.idx = tick_idx++;
			f.val = dut.frame_arm;
			f.paused = tick_paused;
			f.held = tick_held;
			f.muted = tick_muted;
			if (f.muted) begin
				n_muted++;
				if (f.val != 0) begin
					if (mute_bad < 5) $display("mute: tick %0d while muted gave %08x", f.idx, f.val);
					mute_bad++;
				end
			end
			fq.push_back(f);
		end
		tick_q = dut.do_tick;
		tick_paused = dut.paused;
		tick_held = !dut.cpu_run;
		tick_muted = dut.muted;
		if (dut.tick_hold) n_tick_hold++;

		if (run_q && !dut.cpu_run) begin	// the first held clock
			n_holds++;
			if (dut.cache.f_act) n_hold_fill++;
			if (dut.cache.f_act && dut.cache.f_fl) begin
				n_hold_fl++;
				if (p_busy) n_hold_mid++;
				if (p_avail) n_hold_land++;
			end
			$display("hold at %.3f ms: fill running %0d, PSRAM read in flight %0d, controller busy %0d, halfword arriving %0d",
				ms($time), dut.cache.f_act, dut.cache.f_act && dut.cache.f_fl, p_busy, p_avail);
		end
		if (!dut.cpu_run) begin
			unf_since_hold = 0;
			ovf_since_hold = 0;
			if (dut.ram_we || dut.reg_sel) held_push++;
			// The fill and prefetch machines are held: no new PSRAM read, and
			// the data M10K written only by a read in flight landing in the
			// first held clock, in a line whose tag is invalid.
			if (dut.rd_ack) begin
				if (rd_held < 5) $display("PSRAM read started while held at %.3f ms (%0s held clock)",
					ms($time), string'(run_q ? "the first" : "a later"));
				rd_held++;
			end
			if (dut.cache.data.wren_b_i) begin
				if (run_q && !dut.cache.tags.mem_q[dut.cache.f_idx][13]) held_wr1++;
				else begin
					if (held_wr < 5) $display("data M10K written while held at %.3f ms", ms($time));
					held_wr++;
				end
			end
		end else begin
			if (!run_q) check_clear = 1;
			// shadow counters against the peripheral's own
			if (dut.sh_pcm !== dut.per.pcm_level || dut.sh_cmd !== 4'(dut.per.cmd_level)) begin
				if (shadow_bad < 5) $display("shadow mismatch at clock %0d: PCM %0d / %0d, command %0d / %0d",
					cyc, dut.sh_pcm, dut.per.pcm_level, dut.sh_cmd, dut.per.cmd_level);
				shadow_bad++;
			end
			if (dut.sh_pcm_unf !== (unf_since_hold != 0) || dut.sh_pcm_ovf !== (ovf_since_hold != 0)) begin
				if (shadow_bad < 5) $display("shadow flags at clock %0d: underflow %0d (%0d), overflow %0d (%0d)",
					cyc, dut.sh_pcm_unf, unf_since_hold, dut.sh_pcm_ovf, ovf_since_hold);
				shadow_bad++;
			end
		end
		run_q = dut.cpu_run;

		if (dut.cpu_run && dut.cpu.rt_start && check_clear) begin
			for (int k = 0; k < 15; k++) begin
				logic [31:0] v;
				v = dut.cpu.byp_we && dut.cpu.byp_idx == 4'(k) ? dut.cpu.byp_data : dut.cpu.rf[k];
				if (v !== 32'd0) begin
					clear_ok = 0;
					$display("register clear: r%0d = %08x at the first instruction", k, v);
				end
			end
			check_clear = 0;
		end
		if (dut.halted && !halt_seen) begin
			halt_seen = 1;
			$display("HALT at clock %0d: code %0d, pc %08x", cyc, dut.halt_code, dut.halt_pc);
		end
		if (dut.cpu.rt_valid) begin
			nret++;
			if (measuring) begin
				if (!(dut.cpu.rt_pc >= 32'h178 && dut.cpu.rt_pc <= 32'h18c)) begin
					busy += charge;
					work++;
				end
				if (dut.cpu.rt_pc == 32'h190 && !in_batch) begin
					in_batch = 1; bclk = 0; bins_n = 0;
				end
				if (in_batch) begin
					bclk += charge;
					bins_n++;
					if (dut.cpu.rt_pc == 32'h1dc || dut.cpu.rt_pc == 32'h274) begin
						in_batch = 0;
						nbatch++;
						if (bat_fd != 0) $fdisplay(bat_fd, "%0d %0d", bclk, bins_n);
					end
				end
			end
			charge = 0;
		end
		if (measuring) begin
			mclk++;
			if (dut.pcm_enabled && int'(dut.per.pcm_level) < minlev) minlev = int'(dut.per.pcm_level);
			if (dut.cache.st_miss) c_miss++;
			if (dut.cache.st_pf) c_pf++;
			if (dut.cache.st_preempt) c_pre++;
			if (dut.cache.st_late) c_late++;
			if (dut.cache.st_stall) c_stall++;
			if (dut.w_asset && !dut.w_wait) c_wasset++;
		end
		if (dut.pcm_pop) begin
			pops++;
			if (dut.paused) pause_pops++;
			if (!dut.pcm_available) begin
				under_all++;
				unf_since_hold++;
				if (measuring) under++;
			end else begin
				if (apops == song_frame && song_tick < 0) song_tick = tick_idx;
				apops++;
			end
		end
		if (dut.per.pcm_push && dut.per.pcm_full) begin
			over_all++;
			ovf_since_hold++;
			if (measuring) over++;
		end
		if (dut.reg_sel && dut.reg_write && dut.reg_addr == 8'h10) begin
			pushes++;
			if (measuring) mpushes++;
			if (pcm_fd != 0) $fwrite(pcm_fd, "%c%c%c%c", dut.reg_wdata[7:0], dut.reg_wdata[15:8],
				dut.reg_wdata[23:16], dut.reg_wdata[31:24]);
		end
		// The watermark remap: the peripheral must hold clamp(W - (4096 -
		// PCM_DEPTH), 0, PCM_DEPTH) after each write to 0x18.
		if (wm_chk) begin
			n_wm++;
			wm_last = int'(dut.per.pcm_watermark);
			if (wm_last != wm_exp) begin
				if (wm_bad < 5) $display("watermark: firmware wrote %0d, peripheral holds %0d, expected %0d", wm_w, wm_last, wm_exp);
				wm_bad++;
			end
			wm_chk = 0;
		end
		if (dut.cpu_run && dut.reg_sel && dut.reg_write && dut.reg_addr == 8'h18) begin
			wm_w = int'(dut.reg_wdata[28:16]);
			wm_exp = wm_remap(wm_w);
			wm_chk = 1;
		end
		if (dut.per.cmd_pop && song_frame < 0 && cmd_cyc >= 0) begin	// the firmware takes the command
			song_frame = pushes;
			take_cyc = cyc;
		end
	end

	// ---- M10K read-during-write ------------------------------------------------------------------
	// A read registered on the same edge as a write to the same address
	// through the other port is undefined on the device (the models return
	// the old data). Checked from the RAM instances' own ports: the cache's
	// data and tag M10Ks when a load completes, and the PCM FIFO's when a
	// tick takes its head.
	longint rdw_bad = 0;
	logic   col_d = 0, col_t = 0, col_p = 0;
	always @(posedge clk_arm) begin
		if (dut.w_asset && !dut.w_wait && (col_d || col_t)) begin
			if (rdw_bad < 5) $display("read-during-write: asset load at %08x completed on a collided read (data %0d, tag %0d)",
				dut.w_addr, col_d, col_t);
			rdw_bad++;
		end
		if (dut.do_tick && dut.pcm_available && col_p) begin
			if (rdw_bad < 5) $display("read-during-write: a tick took the PCM head from a collided read");
			rdw_bad++;
		end
		col_d = dut.cache.data.wren_b_i && dut.cache.data.addr_b_i == dut.cache.data.addr_a_i;
		col_t = dut.cache.tags.wren_b_i && dut.cache.tags.addr_b_i == dut.cache.tags.addr_a_i;
		col_p = dut.per.pcm_fifo.wren_a_i && dut.per.pcm_fifo.addr_a_i == dut.per.pcm_fifo.addr_b_i;
	end

	// ---- +forcetick ---------------------------------------------------------------------------------
	// The clock after a push into the empty FIFO with PCM already enabled:
	// pcm_available has just risen (not from the enable), and the head the
	// M10K presents is not that frame yet.
	bit     forcetick = 0;
	int     forced = 0, ft_after = 0;
	logic   en_q = 0;
	always @(posedge clk_arm) begin
		en_q = dut.pcm_enabled;
		#1;
		if (forcetick && forced == 0 && $time >= longint'(ft_after) * 1000000000 && en_q
				&& dut.pcm_available && !dut.avail_q && !dut.tick) begin
			forced = 1;
			$display("forced tick at %.3f ms, the clock after a push into the empty FIFO (PCM level %0d)",
				ms($time), dut.per.pcm_level);
			force dut.tick = 1'b1;
			@(posedge clk_arm);
			#1 release dut.tick;
		end
	end

	// ---- +wmsweep: the watermark remap against the formula ------------------------------------------
	longint wms_n = 0, wms_bad = 0;
	task automatic wmsweep();
		logic [31:0] v, e;
		for (int a = 0; a < 256; a++)
			for (int w = 0; w < 8192; w += (a == 8'h18 ? 1 : 97)) begin
				v = $urandom;
				v[28:16] = 13'(w);
				force dut.reg_addr = 8'(a);
				force dut.reg_wdata = v;
				#1;
				e = v;
				if (a == 8'h18) e[28:16] = 13'(wm_remap(w));
				if (dut.reg_wdata_eff !== e) begin
					if (wms_bad < 5) $display("wmsweep: address %02x, W %0d: %08x became %08x, expected %08x",
						a, w, v, dut.reg_wdata_eff, e);
					wms_bad++;
				end
				wms_n++;
			end
		release dut.reg_addr;
		release dut.reg_wdata;
		$display("wmsweep: %0d write values through the remap, %0d wrong; 3,896 becomes %0d", wms_n, wms_bad, wm_remap(3896));
	endtask

	// ---- the frames on clk_sys ---------------------------------------------------------------------
	longint ncap = 0, cross_bad = 0, nz_held = 0, n_paused = 0, nz_paused = 0;
	logic   cap_q = 0, souper_q = 0;
	always @(posedge clk_sys) begin
		if (cap_q) begin
			frame_t f;
			logic [31:0] got, want;
			got = {audio_r, audio_l};
			if (fq.size() == 0) begin
				cross_bad++;
				$display("frame crossing: a capture with no frame ticked");
			end else begin
				f = fq.pop_front();
				want = !souper_q ? 32'd0 : f.val;
				if (got !== want) begin
					if (cross_bad < 5) $display("frame crossing: tick %0d gave %08x, expected %08x", f.idx, got, want);
					cross_bad++;
				end
				// Ticks while paused pop nothing and must play 0; they are
				// left out of the file, which then holds the popped frames.
				if (f.paused) begin
					n_paused++;
					if (got != 0) nz_paused++;
				end else if (f.idx >= rec_base && out_fd != 0)
					$fwrite(out_fd, "%c%c%c%c", got[7:0], got[15:8], got[23:16], got[31:24]);
			end
			ncap++;
			if (f.held && got != 0) nz_held++;	// ticked while held: must be 0
		end
		cap_q = dut.frame_cap;
		souper_q = souper;
	end

	// ---- run ---------------------------------------------------------------------------------------
	string  fw_file = "", rom_file = "", rom2_file = "", out = "s4";
	int     song = 13, secs = 4, seed = 1, silent_ms = 0, reload_ms = 0, retune_ms = 0;
	int     pause_ms = 0, pauselen_ms = 20, maxms = 6000;
	longint pops_cfg = 0;
	longint t_release = 0, t_boot = 0;

	function automatic real ms(input longint ps);
		return ps / 1.0e9;
	endfunction

	task automatic open_outputs();
		if (pcm_fd != 0) $fclose(pcm_fd);
		if (out_fd != 0) $fclose(out_fd);
		pcm_fd = $fopen({out, ".pcm"}, "wb");
		out_fd = $fopen({out, ".out.pcm"}, "wb");
		pushes = 0;
		apops = 0;
		song_frame = -1;
		song_tick = -1;
		cmd_cyc = -1;
		rec_base = tick_idx;
		// the measurement covers the last play only
		busy = 0; work = 0; mclk = 0; nbatch = 0; in_batch = 0; minlev = 1 << 30;
		under = 0; over = 0; mpushes = 0;
		c_miss = 0; c_pf = 0; c_pre = 0; c_late = 0; c_stall = 0; c_wasset = 0;
	endtask

	// Wait for the hold to drop (cpu_run), then for the firmware to enable PCM.
	task automatic boot_and_command();
		while (!dut.cpu_run && $time < longint'(maxms) * 1000000000) @(posedge clk_arm);
		t_release = $time;
		while (!dut.pcm_enabled && !dut.halted && $time < longint'(maxms) * 1000000000) @(posedge clk_arm);
		t_boot = $time;
		$display("booted %.3f ms after the release (%.3f ms): fault %02x, PCM enabled %0d, %0d frames pushed",
			ms(t_boot - t_release), ms(t_boot), dut.fault_code, dut.pcm_enabled, pushes);
		@(posedge clk_sys) begin cmd_valid <= 1; cmd_data <= 8'h80 | 8'(song[4:0]); end
		@(posedge clk_sys) cmd_valid <= 0;
		cmd_cyc = cyc;
		$display("song %0d (command $%02x)", song, 8'h80 | song[4:0]);
		$fflush;
	endtask

	// Play until npops more pops (or a halt), with the optional pause.
	task automatic play(input longint npops);
		longint p0;
		p0 = pops;
		measuring = 1;
		while (pops - p0 < npops && !dut.halted && $time < longint'(maxms) * 1000000000) begin
			@(posedge clk_arm);
			if (pause_ms > 0 && !in_pause && $time - t_boot >= longint'(pause_ms) * 1000000000 && pause == 0) begin
				pause <= 1;
				in_pause = 1;
				$display("pause at %.3f ms for %0d ms", ms($time), pauselen_ms);
			end
			if (in_pause && $time - t_boot >= longint'(pause_ms + pauselen_ms) * 1000000000) begin
				pause <= 0;
				in_pause = 0;
				pause_ms = 0;
				$display("resume at %.3f ms (%0d pops while paused)", ms($time), pause_pops);
			end
		end
		measuring = 0;
		// Reaching +maxms before the pops are done is a failure, not a short run.
		if (pops - p0 < npops && !dut.halted) begin
			$display("play: stopped at +maxms=%0d after %0d of %0d pops", maxms, pops - p0, npops);
			$display("result: timeout");
			$finish;
		end
	endtask

	// Run until the hold begins, return the clocks it took from t0.
	task automatic await_hold(input longint t0, output longint dt);
		while (dut.cpu_run && $time < longint'(maxms) * 1000000000) @(posedge clk_arm);
		dt = ($time - t0) / arm_per();
	endtask

	// Wait (up to 100 ms) until a cache fill has a read in flight and at least
	// 6 halfwords to go.
	int hold_delay = 0, hold_step = 0, n_waits = 0;
	task automatic wait_fill();
		longint t0;
		int d;
		t0 = $time;
		while (!(dut.cache.f_act && dut.cache.f_fl && dut.cache.f_rx_n >= 4'd6) && $time - t0 < 64'd100000000000)
			@(posedge clk_arm);
		d = hold_delay + n_waits * hold_step;
		n_waits++;
		$display("fill with a read in flight at %.3f ms (%0d halfwords to go); the trigger %0d clocks later",
			ms($time), dut.cache.f_rx_n, d);
		repeat (d) @(posedge clk_arm);
	endtask

	// After an image the BupChip cannot play: held and silent for MS ms.
	longint reload_bad = 0;
	task automatic held_check(input int msec);
		longint n0, p0, c0, z0, t0;
		bit ran;
		n0 = nret; p0 = pushes; c0 = ncap; z0 = nz_held; t0 = $time;
		ran = 0;
		while ($time - t0 < longint'(msec) * 1000000000) begin
			@(posedge clk_arm);
			if (dut.cpu_run) ran = 1;
		end
		$display("held for %0d ms: cpu_run %0s, souper_profile %0d, fw_loaded %0d, asset_ready %0d, %0d retired, %0d pushed, %0d frames out (%0d nonzero)",
			msec, ran ? "rose" : "stayed 0", souper, dut.fw_loaded, dut.asset_ready, nret - n0, pushes - p0, ncap - c0, nz_held - z0);
		if (ran || nret != n0 || pushes != p0 || nz_held != z0 || ncap == c0) reload_bad++;
	endtask

	// After a cartridge download: wait for asset_ready (or, with no block to
	// publish, 2 us for the END message to land).
	task automatic await_assets();
		while (!dut.asset_ready && a_size >= 4 && $time - t_dl_end < 1000000000) @(posedge clk_arm);
		if (a_size < 4) while ($time - t_dl_end < 2000000) @(posedge clk_arm);
	endtask

	function automatic bit playable();
		return img[53][4] && a_size >= 4 && fw_n >= 8;
	endfunction

	longint hold_clk;
	string  rom_k [1:4];
	int     nreloads = 0;
	bit     holdfill = 0, playing = 0;
	initial begin
		void'($value$plusargs("fw=%s", fw_file));
		void'($value$plusargs("rom=%s", rom_file));
		void'($value$plusargs("rom2=%s", rom_k[1]));
		void'($value$plusargs("rom3=%s", rom_k[2]));
		void'($value$plusargs("rom4=%s", rom_k[3]));
		void'($value$plusargs("rom5=%s", rom_k[4]));
		void'($value$plusargs("song=%d", song));
		void'($value$plusargs("secs=%d", secs));
		void'($value$plusargs("out=%s", out));
		byte_set = $value$plusargs("bytens=%f", byte_ps);
		void'($value$plusargs("bytejit=%f", jit_ps));
		void'($value$plusargs("endgap=%d", endgap));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("silent=%d", silent_ms));
		void'($value$plusargs("reload=%d", reload_ms));
		void'($value$plusargs("retune=%d", retune_ms));
		void'($value$plusargs("pause=%d", pause_ms));
		void'($value$plusargs("pauselen=%d", pauselen_ms));
		// The default leaves room for the requested playing time: 6 s, or
		// SECS + 2 s for longer runs.
		if (!$value$plusargs("maxms=%d", maxms) && 1000 * secs + 2000 > maxms) maxms = 1000 * secs + 2000;
		void'($value$plusargs("pops=%d", pops_cfg));
		if (reload_ms > 0) nreloads = 1;
		void'($value$plusargs("reloads=%d", nreloads));
		if (nreloads > 4) $fatal(1, "+reloads: at most 4");
		if (nreloads > 0 && reload_ms <= 0) $fatal(1, "+reloads needs +reload=MS");
		skiprom = $test$plusargs("skiprom");
		forcetick = $test$plusargs("forcetick");
		void'($value$plusargs("forcetick_after=%d", ft_after));
		holdfill = $test$plusargs("holdfill");
		void'($value$plusargs("holddelay=%d", hold_delay));
		void'($value$plusargs("holdstep=%d", hold_step));
		r15 = $test$plusargs("arm15");
		byte_ps *= 1000.0;
		jit_ps *= 1000.0;
		void'($urandom(seed));
		set_pal($test$plusargs("pal"));
		for (int k = 1; k <= 4; k++) if (rom_k[k] == "") rom_k[k] = rom_file;
		// Watchdog: a run that hangs still ends, and fails.
		fork
			begin
				#(longint'(maxms + 1000) * 1000000000);
				$display("TIMEOUT at %.3f ms", ms($time));
				$display("result: timeout");
				$finish;
			end
		join_none

		if (fw_file != "") begin
			int fd;
			fd = $fopen(fw_file, "rb");
			if (fd == 0) $fatal(1, "cannot open %s", fw_file);
			fw_n = $fread(fwb, fd);
			$fclose(fd);
		end
		if (rom_file == "") $fatal(1, "no +rom");
		read_image(rom_file);
		$display("BupChip at %.3f MHz (%s clk_sys), PCM FIFO %0d, pre-emption %0d, prefetch %0d, throttle %0d/16; PSRAM: %s",
			arm_mhz, r15 ? "1.5 x" : "2 x", PCM_DEPTH, `PREEMPT, `PREFETCH, `BUP_THROTTLE, PSRAM_KIND);
		begin
			string fw_s, skip_s;
			fw_s = fw_file == "" ? "(none)" : fw_file;
			skip_s = skiprom ? ", ROM bytes skipped" : "";
			$display("firmware %s (%0d bytes); cartridge %s (%0d bytes, %0d of ARSC at %0d); loader %.1f ns + 0..%.1f ns per byte%s",
				fw_s, fw_n, rom_file, img_n, a_size, a_base,
				(byte_set ? byte_ps : 2.5 * real'(sys_per())) / 1000.0, jit_ps / 1000.0, skip_s);
		end
		bat_fd = $fopen({out, ".batches"}, "w");
		open_outputs();
		if ($test$plusargs("wmsweep")) wmsweep();

		#1000000;
		pll_locked = 1;
		if (fw_file != "") begin
			download(1);
			// FWEND, and a partial last word, leave when the capture's window
			// closes, 64 clk_sys after the flag falls (bup_capture.sv): wait
			// for fw_loaded, or 200 clk_sys for a file too short to set it.
			for (int i = 0; i < 200 && !dut.fw_loaded; i++) @(posedge clk_sys);
			repeat (40) @(posedge clk_arm);
			$display("firmware slot: %0d bytes in %.3f ms; fw_loaded %0d", fw_n, ms(t_dl_end - t_dl_start), dut.fw_loaded);
			check_rom();
		end
		download(0);
		await_assets();
		$display("cartridge: %0d bytes in %.3f ms; asset_ready %0d %.3f us after the download ended",
			img_n, ms(t_dl_end - t_dl_start), dut.asset_ready, ($time - t_dl_end) / 1.0e6);
		check_psram();
		$fflush;

		if (silent_ms > 0) begin
			longint c0, n0;
			c0 = cyc;
			n0 = ncap;
			while ($time < t_dl_end + longint'(silent_ms) * 1000000000) @(posedge clk_arm);
			$display("held for %0d ms: cpu_run %0d, fw_loaded %0d, asset_ready %0d, retired %0d, pushed %0d, %0d frames out (%0d nonzero)",
				silent_ms, dut.cpu_run, dut.fw_loaded, dut.asset_ready, nret, pushes, ncap - n0, nz_held);
			report(0);
			$display("result: silent=%0d run=%0d fw_loaded=%0d asset_ready=%0d retired=%0d pushed=%0d frames=%0d nonzero=%0d rom=%0d psram=%0d lost=%0d cross=%0d",
				dut.cpu_run == 0 && nret == 0 && pushes == 0 && nz_held == 0, dut.cpu_run, dut.fw_loaded,
				dut.asset_ready, nret, pushes, ncap - n0, nz_held, rom_bad, psram_bad,
				dut.cap_seq_err | dut.cap_lost | dut.wr_overrun | dut.capture.seq_sim, cross_bad);
			$finish;
		end

		boot_and_command();
		playing = 1;
		if (retune_ms > 0) begin
			longint t0;
			play(48 * retune_ms);
			if (holdfill) wait_fill();
			$display("retune to PAL at %.3f ms", ms($time));
			t0 = $time;
			pll_busy = 1;
			await_hold(t0, hold_clk);
			$display("retune: the CPU is held %0d clk_arm clocks after pll_busy", hold_clk);
			open_outputs();
			#5000000;
			pll_locked = 0;
			set_pal(1);
			#5000000;
			pll_locked = 1;
			#2000000;
			pll_busy = 0;
			boot_and_command();
		end
		for (int k = 1; k <= nreloads; k++) begin
			longint t0;
			if (playing) begin
				play(48 * reload_ms);
				if (holdfill) wait_fill();
			end
			read_image(rom_k[k]);
			$display("reload %0d: %s at %.3f ms (%0d bytes, %0d of ARSC; cartridge type bit 12 %0d)",
				k, rom_k[k], ms($time), img_n, a_size, img[53][4]);
			fork
				download(0);
				begin
					wait (cart_dl);
					t0 = $time;
					await_hold(t0, hold_clk);
					$display("reload %0d: the CPU is held %0d clk_arm clocks after load_start", k, hold_clk);
					open_outputs();
				end
			join
			await_assets();
			check_psram();
			if (playable()) begin
				boot_and_command();
				playing = 1;
			end else begin
				held_check(20);
				playing = 0;
			end
		end
		if (!playing) begin
			$display("the last image cannot play");
			reload_bad++;
		end else
			play(pops_cfg > 0 ? pops_cfg : 48000 * secs);
		report(1);
		$finish;
	end

	task automatic report(input bit result_line);
		real secs_r;
		secs_r = pops_cfg > 0 ? pops_cfg / 48000.0 : secs;
		if (pcm_fd != 0) $fclose(pcm_fd);
		if (out_fd != 0) $fclose(out_fd);
		if (bat_fd != 0) $fclose(bat_fd);
		pcm_fd = 0;
		out_fd = 0;
		$display("");
		$display("clocks     %0d in %.3f s of pops (%.0f per second)", mclk, secs_r, 1.0 * mclk / secs_r);
		$display("busy       %0d clocks, %.2f%% of %.3f MHz; %.2f MHz needed at 100%% busy",
			busy, 100.0 * busy / (mclk > 0 ? mclk : 1), arm_mhz, busy / (secs_r * 1.0e6));
		$display("work       %0d instructions, %.2f MIPS; CPI %.4f", work, work / (secs_r * 1.0e6),
			1.0 * busy / (work > 0 ? work : 1));
		$display("batches    %0d", nbatch);
		$display("command    taken by the firmware %0d clocks after it was sent, with %0d frames pushed",
			take_cyc - cmd_cyc, song_frame);
		$display("song start: pushed %0d, output %0d", song_frame, song_tick - rec_base);
		$display("audio      %0d pops, %0d underflows while playing (%0d since power-up), %0d overflows (%0d); %0d frames pushed while playing",
			pops, under, under_all, over, over_all, mpushes);
		$display("fifo       lowest level %0d of %0d while playing; shadow lowest %0d, status %08x",
			minlev, PCM_DEPTH, dut.dbg_status[10:0], dut.dbg_status);
		$display("cache      %0d asset loads, %0d demand misses, %0d prefetches, %0d pre-emptions, %0d late hits, %0d stall clocks (%.3f%% of clocks)",
			c_wasset, c_miss, c_pf, c_pre, c_late, c_stall, 100.0 * c_stall / (mclk > 0 ? mclk : 1));
		$display("capture    seq_err %0d (bytes out of order %0d), lost %0d, overrun %0d; ROM words differing %0d, PSRAM bytes differing %0d",
			dut.cap_seq_err, dut.capture.seq_sim, dut.cap_lost, dut.wr_overrun, rom_bad, psram_bad);
		$display("pop        %0d ticks waited a clock for the FIFO's head (pcm_available had just risen)", n_tick_hold);
		$display("crossing   %0d frames to clk_sys, %0d wrong, %0d still queued; %0d nonzero ticked while held; %0d CPU accesses while held; shadow mismatches %0d",
			ncap, cross_bad, fq.size(), nz_held, held_push, shadow_bad);
		$display("m10k       %0d completed reads that collided with a write", rdw_bad);
		if (n_paused != 0) $display("pause      %0d ticks while paused, %0d of them not silent; %0d pops", n_paused, nz_paused, pause_pops);
		$display("holds      %0d (cpu_run fell), %0d with a cache fill running, %0d of them with a PSRAM read in flight (%0d mid-access, %0d with the halfword arriving)",
			n_holds, n_hold_fill, n_hold_fl, n_hold_mid, n_hold_land);
		$display("held       %0d PSRAM reads started while held; data M10K writes while held: %0d in the first held clock into an invalid line, %0d others",
			rd_held, held_wr1, held_wr);
		$display("watermark  %0d writes to 0x18, %0d wrong; the peripheral's watermark %0d%s", n_wm, wm_bad, wm_last,
			wms_n > 0 ? $sformatf("; remap sweep %0d values, %0d wrong", wms_n, wms_bad) : "");
		$display("mute       %0d ticks while muted, %0d of them not 0; %0d forced ticks", n_muted, mute_bad, forced);
		$display("status     fault %02x, halted %0d (code %0d, pc %08x), register clear %0s",
			dut.fault_code, dut.halted, dut.halt_code, dut.halt_pc, clear_ok ? "ok" : "FAILED");
`ifndef PSRAM_STANDIN
		chip.report();
`endif
		if (result_line) $display("result: busy=%0d work=%0d cpi=%.4f mips=%.3f under=%0d under_all=%0d over=%0d minlev=%0d fault=%02x halted=%0d clear=%0d lost=%0d rom=%0d psram=%0d cross=%0d shadow=%0d miss=%0d pf=%0d pre=%0d late=%0d stall=%0d rdw=%0d held=%0d held_nz=%0d pause_nz=%0d pause_pops=%0d reload_bad=%0d mute_bad=%0d rd_held=%0d held_wr=%0d wm=%0d wm_bad=%0d wmsweep=%0d wmsweep_bad=%0d forced=%0d holds=%0d hold_fill=%0d hold_fl=%0d hold_mid=%0d hold_land=%0d",
			busy, work, 1.0 * busy / (work > 0 ? work : 1), work / (secs_r * 1.0e6), under, under_all, over,
			minlev, dut.fault_code, dut.halted, clear_ok, dut.cap_seq_err | dut.cap_lost | dut.wr_overrun | dut.capture.seq_sim,
			rom_bad, psram_bad, cross_bad, shadow_bad, c_miss, c_pf, c_pre, c_late, c_stall, rdw_bad, held_push, nz_held, nz_paused, pause_pops,
			reload_bad, mute_bad, rd_held, held_wr, wm_last, wm_bad, wms_n, wms_bad, forced, n_holds, n_hold_fill, n_hold_fl, n_hold_mid, n_hold_land);
	endtask
endmodule
