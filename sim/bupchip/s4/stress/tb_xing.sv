//------------------------------------------------------------------------------
// The step 4 wrapper's other crossings under stress (docs/BUPCHIP_CORE.md,
// "Crossings", "48 kHz", "PCM and command FIFOs"): the $8007 command
// (clk_sys -> clk_arm, byte held plus toggle), the audio frame (clk_arm ->
// clk_sys, frame held plus toggle), the 48 kHz tick (clk_74a -> clk_arm) and
// pause (clk_sys -> clk_arm, two flops), all through bupchip_pocket.sv with
// the CPU running fw_xing.S, which echoes every command, with an asset byte
// read through the cache and a sequence number, as one PCM frame.
//
// Clocks: clk_sys 14.318 MHz (+pal: x 0.99088); clk_arm 2 x clk_sys edge
// aligned (default), 1.5 x (+ratio=15), or asynchronous (+async: half period
// +arm_ps=PS with a random start phase and +armjit=PS random extra per half
// period); clk_74a 74.25 MHz off by +ppm74=N ppm (signed) with +jit74=PS
// random extra per half period.
//
// Loader: the firmware slot (+fw) then a cartridge whose 4,096-byte ARSC
// block is a pattern of the offset, one byte per 2.5 clk_sys. Then +n=N
// commands with random bytes, in bursts of 1 to +maxburst=M (default 7) at
// +smin=S clk_sys apart
// (plus 0-3), each burst followed by about 1.1 x 48 kHz ticks per command of
// silence, so the PCM FIFO is mostly empty and the pushes land at every
// phase of the pop. cmd_data carries a random byte except in a command's
// own clock, as top.sv's bup_cmd_data_eff may (BUPCHIP_FORCE_CMD).
// +pause: random pause windows (0.05-1 ms, 1-6 ms apart) meanwhile.
//
// Checks: every nonzero frame captured on clk_sys (the wrapper's frame_cap)
// is the next command in order, {byte, the asset byte at its offset, k},
// each once, and all N arrive; no pop and no nonzero frame while paused (a
// frame captured with pause high for the last 12 clk_sys); the CPU never
// halts; no command or PCM overflow (shadow counters; underflow is expected:
// the FIFO runs empty between commands); no capture error; the
// tick count against elapsed clk_74a time (48,000 x (1 + ppm) per second, +-2).
// The last line, "result: ...", is for run_xing.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_xing;
	// ---- clocks -------------------------------------------------------------------------
	longint arm_half = 17460, u15 = 11640, sys_half_async = 34920, arm_ps = 23525, armjit = 0;
	longint half74 = 6734, jit74 = 0;
	int     ratio = 2, ppm74 = 0;
	bit     async_ = 0, pal = 0;
	logic   clk_arm = 0, clk_sys = 0, clk_74a = 0;
	real    per74 = 13468.0;

	initial begin
		pal = $test$plusargs("pal");
		async_ = $test$plusargs("async");
		void'($value$plusargs("ratio=%d", ratio));
		void'($value$plusargs("arm_ps=%d", arm_ps));
		void'($value$plusargs("armjit=%d", armjit));
		void'($value$plusargs("ppm74=%d", ppm74));
		void'($value$plusargs("jit74=%d", jit74));
		if (pal) begin arm_half = 17621; u15 = 11747; sys_half_async = 35242; end
		per74 = 1.0e6 / 74.25 / (1.0 + real'(ppm74) * 1.0e-6);
		half74 = longint'(per74 / 2.0);
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
			forever begin                   // rising edges together every 12 u15
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
	// clk_74a: its own phase, ppm and jitter. The jitter is symmetric about the
	// mean period, so the long-run rate stays 74.25 MHz x (1 + ppm).
	initial begin
		#($urandom_range(13000));
		forever begin
			#(half74 + (jit74 > 0 ? longint'($urandom_range(int'(2 * jit74))) - jit74 : 0));
			clk_74a = ~clk_74a;
		end
	end

	function automatic longint sys_per();
		return async_ ? 2 * sys_half_async : ratio == 15 ? 6 * u15 : 4 * arm_half;
	endfunction

	// ---- the wrapper ------------------------------------------------------------------------
	logic        pause = 0, cart_dl = 0, cart_dl_q = 0, fw_dl = 0, ld_wr = 0;
	logic [24:0] ld_addr = 0;
	logic  [7:0] ld_data = 0;
	logic        cmd_valid = 0;
	logic  [7:0] cmd_v = 0, noise = 0;
	wire   [7:0] cmd_data = cmd_valid ? cmd_v : noise;	// noise outside a command's clock
	always @(posedge clk_sys) cart_dl_q <= cart_dl;
	always @(posedge clk_sys) noise <= 8'($urandom);

	wire [15:0] audio_l, audio_r;
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	wire [31:0] dbg_status, dbg_halt_pc;

	bupchip_pocket dut (
		.clk_sys, .clk_arm, .clk_74a,
		.pll_locked(1'b1), .pll_busy(1'b0), .souper_profile(1'b1), .pause,
		.load_start(cart_dl && !cart_dl_q), .load_addr(ld_addr), .load_valid(ld_wr && cart_dl),
		.load_data(ld_data), .load_end(!cart_dl && cart_dl_q),
		.fw_download(fw_dl), .fw_valid(ld_wr && fw_dl),
		.cmd_valid, .cmd_data,
		.audio_l, .audio_r,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_read_avail(p_avail), .psram_data_out(p_dout), .psram_busy(p_busy),
		.dbg_status, .dbg_halt_pc);

	psram_standin ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy));

	// ---- images and the loader --------------------------------------------------------------
	localparam int R = 16, BLK = 4096;
	logic [7:0] fwb [0:16383];
	int         fw_n = 0;
	function automatic logic [7:0] blk(input int b);
		return 8'((b * 7 + 3) ^ (b >> 8) ^ 8'h5A);
	endfunction
	function automatic logic [7:0] cart_byte(input int k);
		if (k == 49) return 8'(R >> 24);
		if (k == 50) return 8'(R >> 16);
		if (k == 51) return 8'(R >> 8);
		if (k == 52) return 8'(R);
		if (k < 128 + R) return 8'(k * 13);
		return blk(k - 128 - R);
	endfunction

	task automatic send(input bit fw, input int n);
		real t, bp;
		@(posedge clk_sys);
		t = $realtime;
		bp = 2.5 * real'(sys_per());
		for (int k = 0; k < n; k++) begin
			t += bp;
			while ($realtime < t - real'(sys_per())) @(posedge clk_sys);
			ld_wr <= 1;
			ld_addr <= 25'(k);
			ld_data <= fw ? fwb[k] : cart_byte(k);
			@(posedge clk_sys);
			ld_wr <= 0;
			ld_data <= 8'($urandom);
		end
	endtask

	// ---- commands ------------------------------------------------------------------------------
	int         n_cmd = 3000, smin = 2, maxburst = 7;
	logic [7:0] sent [0:65535];
	int         n_sent = 0;
	bit         do_pause = 0;

	task automatic send_commands();
		int tick_sys;
		tick_sys = int'(1.0e12 / 48000.0 / real'(sys_per()));      // clk_sys per tick
		while (n_sent < n_cmd) begin
			int b;
			b = $urandom_range(maxburst, 1);
			if (b > n_cmd - n_sent) b = n_cmd - n_sent;
			for (int i = 0; i < b; i++) begin
				logic [7:0] v;
				v = 8'($urandom);
				sent[n_sent] = v;
				n_sent++;
				cmd_valid <= 1;
				cmd_v <= v;
				@(posedge clk_sys);
				cmd_valid <= 0;
				repeat (smin - 1 + $urandom_range(3)) @(posedge clk_sys);
			end
			repeat (b * tick_sys + $urandom_range(b * tick_sys / 5)) @(posedge clk_sys);
		end
	endtask

	// Random pause windows while the commands run.
	longint n_pauses = 0;
	bit     cmds_done = 0;
	task automatic pauses();
		while (!cmds_done) begin
			repeat ($urandom_range(86000, 14000)) @(posedge clk_sys);   // 1-6 ms apart
			if (cmds_done) break;
			pause <= 1;
			n_pauses++;
			repeat ($urandom_range(14300, 700)) @(posedge clk_sys);     // 0.05-1 ms
			pause <= 0;
		end
	endtask

	// ---- frames back on clk_sys ---------------------------------------------------------------
	logic   cap_q = 0;
	int     pause_hi = 0;
	longint n_frames = 0, n_nonzero = 0, n_bad = 0, n_paused_caps = 0, paused_bad = 0;
	int     next_k = 1;
	always @(posedge clk_sys) begin
		cap_q <= dut.frame_cap;
		pause_hi <= pause ? (pause_hi < 1000 ? pause_hi + 1 : pause_hi) : 0;
		if (cap_q) begin
			n_frames++;
			if (pause_hi >= 12) begin
				n_paused_caps++;
				if ({audio_r, audio_l} != 32'd0) begin
					if (paused_bad < 5) $display("[%0t] nonzero frame %08x captured while paused", $time, {audio_r, audio_l});
					paused_bad++;
				end
			end
			if ({audio_r, audio_l} != 32'd0) begin
				logic [31:0] e;
				n_nonzero++;
				e = {sent[next_k - 1], blk(((next_k - 1) * 37) % BLK), 16'(next_k)};
				if (next_k > n_sent || {audio_r, audio_l} != e) begin
					if (n_bad < 10) $display("[%0t] frame %08x, expected %08x (command %0d of %0d sent)",
						$time, {audio_r, audio_l}, e, next_k, n_sent);
					n_bad++;
					// resynchronise on the frame's own number, so one fault is one error
					if (int'(audio_l) >= next_k) next_k = int'(audio_l) + 1;
				end else
					next_k++;
			end
		end
	end

	// ---- clk_arm watchers -------------------------------------------------------------------------
	longint n_ticks = 0, pops_paused = 0, n_pops = 0, n_held_tick = 0;
	longint t_first_tick = -1, t_last_tick = -1;
	always @(posedge clk_arm) begin
		if (dut.tick) begin
			n_ticks++;
			if (t_first_tick < 0) t_first_tick = $time;
			t_last_tick = $time;
		end
		if (dut.pcm_pop) begin
			n_pops++;
			if (dut.paused) pops_paused++;
		end
		if (dut.tick_hold) n_held_tick++;
	end

	// ---- the run ----------------------------------------------------------------------------------
	initial begin
		string fw_file;
		int fd, maxms;
		longint t0;
		maxms = 2000;
		fw_file = "";
		void'($value$plusargs("fw=%s", fw_file));
		void'($value$plusargs("n=%d", n_cmd));
		void'($value$plusargs("smin=%d", smin));
		void'($value$plusargs("maxms=%d", maxms));
		void'($value$plusargs("maxburst=%d", maxburst));
		if (maxburst < 1) maxburst = 1;
		do_pause = $test$plusargs("pause");
		if (smin < 1) smin = 1;
		if (n_cmd > 65000) n_cmd = 65000;
		fd = $fopen(fw_file, "rb");
		if (fd == 0) $fatal(1, "cannot open +fw=%s", fw_file);
		fw_n = $fread(fwb, fd);
		$fclose(fd);
		fork
			begin
				#(longint'(maxms) * 1000000000);
				$display("result: timeout");
				$finish;
			end
		join_none

		repeat (10) @(posedge clk_sys);
		fw_dl <= 1;
		repeat (20) @(posedge clk_sys);
		send(1, fw_n);
		repeat (3) @(posedge clk_sys);
		fw_dl <= 0;
		repeat (30) @(posedge clk_sys);
		cart_dl <= 1;
		repeat (20) @(posedge clk_sys);
		send(0, 128 + R + BLK);
		repeat (3) @(posedge clk_sys);
		cart_dl <= 0;
		wait (dut.pcm_enabled);
		repeat ($urandom_range(500, 50)) @(posedge clk_sys);
		t0 = $time;
		if (do_pause) fork pauses(); join_none
		send_commands();
		cmds_done = 1;
		pause <= 0;
		// drain: every frame out, the FIFO empty
		repeat (300) @(posedge clk_sys);
		while (next_k <= n_sent && $time - t0 < longint'(maxms) * 1000000000) begin
			repeat (1000) @(posedge clk_sys);
			if (dut.halted) break;
		end
		repeat (2000) @(posedge clk_sys);
		finish_run(t0);
	end

	task automatic finish_run(input longint t0);
		real secs, expect_ticks;
		longint tick_err;
		bit ok;
		secs = real'(t_last_tick - t_first_tick) * 1.0e-12;
		// ticks between the first and the last, from the rate of clk_74a as built
		expect_ticks = secs * 1.0e12 / real'(2 * half74) * 8.0 / 12375.0;
		tick_err = longint'(real'(n_ticks - 1) - expect_ticks);
		ok = next_k == n_sent + 1 && n_bad == 0 && paused_bad == 0 && pops_paused == 0 &&
			!dut.halted && dbg_status[23:22] == 2'b00 && dbg_status[11] == 1'b0 &&
			(tick_err <= 2 && tick_err >= -2) && dbg_status[31];
		$display("xing: clk_arm %s%s, clk_74a %0d ppm, jitter %0d ps; commands %0d (bursts at %0d+ clk_sys)",
			async_ ? "asynchronous" : ratio == 15 ? "1.5 x clk_sys" : "2 x clk_sys", pal ? ", PAL" : "",
			ppm74, jit74, n_sent, smin);
		$display("frames %0d captured on clk_sys, %0d nonzero, %0d wrong; %0d of %0d commands back in order",
			n_frames, n_nonzero, n_bad, next_k - 1, n_sent);
		$display("pause %0d windows, %0d captures inside, %0d nonzero; %0d pops while paused",
			n_pauses, n_paused_caps, paused_bad, pops_paused);
		$display("ticks %0d over %.6f s, expected %.1f (error %0d); %0d pops; %0d ticks held a clock (tick_hold)",
			n_ticks, secs, expect_ticks + 1.0, tick_err, n_pops, n_held_tick);
		$display("status %08x: cpu_run %0d, halted %0d (code %0d at %08x), cmd ovf %0d, pcm ovf %0d, capture error %0d",
			dbg_status, dbg_status[31], dut.halted, dut.halt_code, dbg_halt_pc,
			dbg_status[23], dbg_status[22], dbg_status[11]);
		$display("result: %s cmds=%0d back=%0d bad=%0d paused_bad=%0d pause_pops=%0d tick_err=%0d held_ticks=%0d halted=%0d st=%08x",
			ok ? "PASS" : "FAIL", n_sent, next_k - 1, n_bad, paused_bad, pops_paused, tick_err,
			n_held_tick, dut.halted, dbg_status);
		$finish;
	endtask
endmodule
