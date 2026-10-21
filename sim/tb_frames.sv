//------------------------------------------------------------------------------
// tb_frames: the whole Pocket core (tb_load: atari7800_pocket, the APF loader,
// the SRAM, PSRAM and SDRAM models) running a 2600 image for a number of
// frames, with tb_daria's fingerprint, input script and call log, so that its
// files compare directly with tb_daria's (sim/check/frame_gate.py). DARIA
// step 7 (docs/daria_step7/plan.md 3.6 I4c, 7.4 R2).
//
//   fp.csv      frame,len_sys,riot,video,audio: tb_daria's fingerprint
//               (bupchip/daria/tb_daria.sv, "Frame fingerprint"), tapped at
//               the same signals inside the core's main instance (top.sv):
//               its RED, GREEN, BLUE on ce_pix outside HBlank and VBlank,
//               the RIOT's 128 RAM bytes, AUDIO_L/AUDIO_R, and the TIA's VSYNC
//               bit (tia_inst.vsync_o), not the Pocket's video path, so Flicker
//               Blend, the border and overscan cannot change it. Frames are
//               counted from the last release of the wrapper's console reset
//               (atari7800_pocket's reset, which main takes): frame 1 starts
//               at the first VSYNC rise after it. With +frames=N the run stops
//               at the N-th rise, so fp.csv holds frames 1..N-1 under its
//               header, as tb_daria's does with +frames=N. A later release
//               (a retune's pll_busy, an init_busy dip) after a frame or a
//               call has been written starts every file again, headers
//               included, with the call numbers, the late-call measure and
//               the input script (as at time 0); halts, PSRAM violations and
//               unlocks still count over the whole run. The run.log line
//               "FRAMES console reset released again ... the files start
//               again" says so.
//   calls.csv   call,frame,line,t_req_sys,busy_sys,stall_sys,first_bl,arm_cyc,
//               thumb,arm: tb_daria's first ten columns, one line per call as
//               the 6507 sees it, counted as tb_daria counts upstream's: the
//               request (t_req_sys, clk_sys from time 0; frame and scanline)
//               is the clock daria_fe commits the call, the one before its
//               registered arm_call_busy (u_fe) rises, as upstream's
//               arm_call_request comes the clock before its busy; busy_sys
//               runs from there to the busy's fall, stall_sys counts the
//               clocks top.sv's arm_call_stall held the 6507 in it (one less
//               than busy_sys, as in tb_daria); arm_cyc the BupChip CPU's
//               clk_arm from call_go to returned, thumb and arm the
//               instructions it retired in them (first_bl is 0: upstream's
//               ARM only). Calls are numbered from 1 from time 0, as tb_daria's
//               call_id. Only in the DARIA build with u_fe (SIM_DARIA_FE);
//               otherwise the header alone.
//   slack.csv   call,kind,sys_end_to_poll,slack_sys,poll_pc and zero.csv
//               call,slack_zero_sys: tb_daria's late-call measure
//               (tb_daria.sv, "RIOT timer events"), on the same RIOT taps:
//               the RIOT-timer slack the 6507 had left at its first INTIM or
//               TIMINT read after each call; kind 1 with slack <= 0 is a late
//               call (an overrun).
//   frames.csv  frame,t_sys,len_sys,lines,calls,stall_sys,dma_sys: per frame,
//               tb_daria's columns of those names.
//   run.log     (stdout) the status lines, ending with
//                 STATUS calls C, late L, halts H, halt_code X, psram_viol V, guard G, unlocks U
//               (frame_gate.py reads it): calls and late calls as above, the
//               BupChip CPU's halts (rises of halted) and its halt_code, the
//               PSRAM model's timing violations, daria_fe's guard at the end
//               (dbg_locked: locked or unlocked; none without u_fe) and the
//               unlocks counted from dbg_unlock (P22's two outputs), each
//               checked on every clk_sys against u_fe's own guard (u_guard.lk,
//               ev_unlock), and the line "FRAMES result: PASS|FAIL ...".
//               The calls are also counted where they are posted and run
//               (P22: from call_tog): u_fe's call_tog flips (clk_sys),
//               bupchip's call_go and returned pulses (clk_arm); the line
//               "FRAMES calls: ..." gives them: each must equal the busy
//               periods (C), but for the one call that may be in flight at
//               the end (posted, and maybe started or returned, its busy not
//               yet fallen), or the result is FAIL.
//
// The input script is tb_daria's (+fire_at=F, +reset_at=F, +select_at=F,
// +play_at=F, +seed=N; defaults 420, 0, 0, 480, 1), applied by frame through
// the Pocket's own input path: tb_load's joy0 (bit 9 fire, as the A button;
// bits 3..0 up, down, left, right; bit 7 select, bit 8 reset). It changes on
// the clk_sys edge that sees the frame's VSYNC rise, as in tb_daria.
//
// Plusargs, besides tb_load's (+image=FILE is the image; +bs=N, +blend, ...):
//   +out=PREFIX    output path prefix, e.g. dir/              (default ./)
//   +frames=N      frames to run after the last reset release  (default 1500)
//   +nostop74      keep clk_74a running after the load (tb_load's +stop74 is
//                  on by default here: nothing after the load needs it). In
//                  the core clk_74a clocks the APF bridge's sides (the high
//                  score and SaveKey RAMs' port B, idle after the load) and,
//                  in bupchip_pocket.sv, only bup_tick48k: the 48 kHz tick
//                  pops the PCM FIFO and loads the frame register, whose
//                  audio_l/audio_r are 0 outside the Souper profile; in the
//                  2600 profile the peripheral is held in reset (POCKET_DARIA),
//                  so no tick reaches the 2600, daria_fe or the fingerprint.
//                  Juno First's 1,500 frames are byte-identical with and
//                  without it (the non-DARIA build).
//   +region=N      tb_load's region_setting (default 1 here: NTSC forced)
//   +inputs_tbdaria  present the TIA's paddle inputs (INPT0-3: the wrapper's
//                  idump) as tb_daria does (tb_daria.sv's idump = 4'b1010:
//                  INPT1 and INPT3 high), not as the wrapper maps them (for a
//                  2600 image with a joystick on Auto, INPT1 = INPT3 = 0);
//                  the frame gate against R1's tb_daria runs passes it
//                  (sim/run_frames.sh INPUTS=tb_daria, sim/step7_gates.sh):
//                  bench parity, plan P13. run.log says which in its line
//                  "FRAMES inputs: ...", which frame_gate.py reads.
//   +maxms=MS      give up after MS ms of simulated time (default 2 x the
//                  frames at 60 Hz, plus 2 s)
// Build with run_sim.sh BUILD_TOP=tb_frames (BUP_DEBUG off, -O3 --x-assign
// fast --x-initial fast); sim/run_frames.sh builds and runs it.
//
// With FRAMES_DEBUG=1 (run_sim.sh, run_frames.sh) the build has BUP_DEBUG,
// and the bench also checks the DARIA status overlay (daria_dbg_status's
// counts, bup_status_osd.sv's DARIA rows; tb_load.sv's overlay block
// checks the RIOT timer's copy and reads the rows back from the picture):
// at every frame's end the overlay's calls, late calls, unlocks and guard
// state must equal this bench's (calls since the last restart, late calls
// as above, unlocks over the run, dbg_locked), and run.log gets the lines
//   OVERLAY frame F: what the picture showed (each time it changes, and
//                    every 100 frames)
//   OVERLAY counts / checks / result: PASS|FAIL
// +ovl_halt_at=F forces the overlay's halt rows from frame F (below); give
// +ovl_rows=1FF with it, so that every cell of the nine rows must have been
// read back. Without it the last whole frame must show exactly rows 0-5, and
// no frame may draw rows 6-8 while the halt bit is 0 (tb_load.sv's
// ovl_rows_bad). The result also needs what tb_load.sv's overlay block requires
// of what was checked (+ovl_rows, default 3F: rows 0-5 complete; +ovl_cells),
// and at least one of the end-of-run compares of the picture with the bench.
// The overlay's result joins the run's. The frames, calls and every file
// are those of the build without BUP_DEBUG, which observes only.
//
// Every file here derives from the game image: keep them in sim/work.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_frames;
	tb_load tb ();

	`define TF_M tb.dut.main
	localparam int SYS_PER_LINE = 912;     // 228 colour clocks x 4

	string  out = "./";
	int     frames = 1500, maxms = 0;
	int     fd_fp = 0, fd_calls = 0, fd_slack = 0, fd_zero = 0, fd_frames = 0;
	bit     stop74 = 1'b1;

	// tb_load's hooks, set before its load ends (it reads them after that):
	// NTSC, clk_74a stopped after the load, and its own end of run left to
	// this bench.
	initial begin
		int rg;
		void'($value$plusargs("out=%s", out));
		void'($value$plusargs("frames=%d", frames));
		rg = 1;
		void'($value$plusargs("region=%d", rg));
		stop74 = !$test$plusargs("nostop74");
		if (!$value$plusargs("maxms=%d", maxms)) maxms = 2 * frames * 1000 / 60 + 2000;
		#1;
		tb.region_tb = 2'(rg);
		tb.stop74 = stop74;
		tb.ext_end = 1'b1;
		open_files();
		$display("FRAMES image (tb_load's +image), %0d frames, region_setting %0d, stop74 %0d, out %s",
			frames, rg, stop74, out);
	end

	// the five files, opened (truncated) with their headers
	task automatic open_files();
		fd_fp = $fopen({out, "fp.csv"}, "w");
		if (fd_fp == 0) $fatal(1, "tb_frames: cannot open %sfp.csv", out);
		$fwrite(fd_fp, "frame,len_sys,riot,video,audio\n");
		fd_calls = $fopen({out, "calls.csv"}, "w");
		$fwrite(fd_calls, "call,frame,line,t_req_sys,busy_sys,stall_sys,first_bl,arm_cyc,thumb,arm\n");
		fd_slack = $fopen({out, "slack.csv"}, "w");
		$fwrite(fd_slack, "call,kind,sys_end_to_poll,slack_sys,poll_pc\n");
		fd_zero = $fopen({out, "zero.csv"}, "w");
		$fwrite(fd_zero, "call,slack_zero_sys\n");
		fd_frames = $fopen({out, "frames.csv"}, "w");
		$fwrite(fd_frames, "frame,t_sys,len_sys,lines,calls,stall_sys,dma_sys\n");
	endtask

	// ---- taps inside main (top.sv) ------------------------------------------------------
	wire        vsync_raw = `TF_M.tia_inst.vsync_o;
	wire  [7:0] R = `TF_M.RED, G = `TF_M.GREEN, B = `TF_M.BLUE;
	wire        ce_pix = `TF_M.ce_pix, HBlank = `TF_M.HBlank, VBlank = `TF_M.VBlank;
	wire [31:0] fp_snd = {`TF_M.AUDIO_L, `TF_M.AUDIO_R};
	// RIOT timer (tb_daria.sv's taps)
	wire        r_ce    = `TF_M.riot_inst.ce;
	wire        r_sel   = `TF_M.riot_inst.CS1 && !`TF_M.riot_inst.CS2_n && `TF_M.riot_inst.RS_n &&
	                      `TF_M.riot_inst.addr[2];
	wire        r_rw    = `TF_M.riot_inst.RW_n;
	wire        r_a4    = `TF_M.riot_inst.addr[4];
	wire        r_wrap  = `TF_M.riot_inst.timer_wrap;
	wire        r_tick  = `TF_M.riot_inst.tick_inc;
	wire  [7:0] r_timer = `TF_M.riot_inst.timer;
	wire        c_sync  = `TF_M.cpu_inst.cpu.sync;
	wire        call_stall = `TF_M.arm_call_stall;
	wire        con_reset = tb.dut.reset;          // the wrapper's console reset, main's reset
`ifdef SIM_DARIA_FE
	wire        fe_busy  = tb.dut.u_fe.arm_call_busy;
	wire        fe_dma   = tb.dut.u_fe.arm_dma_busy && !tb.dut.u_fe.init_busy;
	wire        d_go     = tb.dut.bupchip.call_go;
	wire        d_ret    = tb.dut.bupchip.returned;
	wire        d_rt     = tb.dut.bupchip.cpu.rt_valid;
	wire        d_rt_t   = tb.dut.bupchip.cpu.rt_t;
	wire        d_halted = tb.dut.bupchip.halted;
	wire  [3:0] d_hcode  = tb.dut.bupchip.halt_code;
	wire        g_dbg_lk = tb.dut.u_fe.dbg_locked, g_dbg_ul = tb.dut.u_fe.dbg_unlock;
	wire        g_lk     = tb.dut.u_fe.u_guard.lk, g_ul = tb.dut.u_fe.u_guard.ev_unlock;
`else
	wire        fe_busy = 1'b0, fe_dma = 1'b0;
`endif

	// ---- the system side (clk_sys), as tb_daria's -----------------------------------------
	localparam logic [63:0] FNV_OFFSET = 64'hcbf29ce484222325;
	localparam logic [63:0] FNV_PRIME  = 64'h00000100000001b3;
	function automatic logic [63:0] fnv(input logic [63:0] h, input logic [7:0] b);
		return (h ^ {56'd0, b}) * FNV_PRIME;
	endfunction
	longint now = 0;                // clk_sys since time 0
	longint t_vs = 0;               // last VSYNC rise
	int     frame = 0;              // frames since the last reset release
	logic   old_vs = 0, rst_q = 1;
	logic   running = 0;
	int     releases = 0, restarts = 0;
	logic [63:0] fp_video = FNV_OFFSET, fp_audio = FNV_OFFSET;
	logic [31:0] fp_last = 0;
	// calls (the 6507's view: daria_fe's arm_call_busy)
	logic   sys_call = 0;
	longint t_req = 0, stall = 0;
	int     req_frame, req_line, sys_calls = 0, f_calls = 0;
	longint f_stall = 0, f_dma = 0;
	// RIOT timer (tb_daria.sv's late-call measure)
	longint t_timer_write = -1, t_expire = -1;
	logic   expired = 0, await_poll = 0, pending_slack = 0;
	int     poll_call, overruns = 0;
	longint poll_req_t, poll_done_t, t_poll;
	longint worst_slack = 64'sh7fffffffffffffff;
	longint t_zero = -1, zero_poll_t = 0;
	logic   zeroed = 0, pending_zero = 0;
	int     zero_call;
	logic [15:0] op_pc = 0, poll_pc = 0;
	always @(posedge tb.clk_sys) if (c_sync) op_pc <= `TF_M.cpu_AB;
	// the BupChip CPU's side of each call (clk_arm), handed to the clk_sys side
	int     call_id = 0;            // calls started (busy rises), as tb_daria's call_id
	longint d_cyc = 0, d_thumb = 0, d_arm = 0, done_cyc = 0, done_thumb = 0, done_arm = 0;
	logic   d_in = 0;
	int     halts = 0;
	logic   d_halted_q = 0;
	int     g_lk_bad = 0, g_ul_bad = 0, unlocks = 0;
	// the calls where they are posted and run (P22): call_tog flips, call_go and returned
	int     n_tog = 0, n_go = 0, n_ret = 0, base_tog = 0, base_go = 0, base_ret = 0;
	bit     cross_off = 0;
`ifdef SIM_DARIA_FE
	logic   tog_q = 0;
	longint t_last_tog = -100;
	always @(posedge tb.clk_sys) begin
		if (tb.dut.u_fe.call_tog !== tog_q) begin n_tog++; t_last_tog = now; end
		tog_q <= tb.dut.u_fe.call_tog;
	end
	always @(posedge tb.clk_arm) begin
		if (d_go) n_go++;
		if (d_ret) n_ret++;
	end
	always @(posedge tb.clk_arm) begin
		if (d_go) begin d_in = 1; d_cyc = 0; d_thumb = 0; d_arm = 0; end
		else if (d_in) d_cyc++;
		if (d_in && d_rt) begin if (d_rt_t) d_thumb++; else d_arm++; end
		if (d_in && d_ret) begin
			d_in = 0;
			done_cyc = d_cyc; done_thumb = d_thumb; done_arm = d_arm;
		end
	end
	always @(posedge tb.clk_sys) begin
		if (d_halted && !d_halted_q) begin
			halts++;
			$display("FRAMES the BupChip CPU halted: code %0d, pc %08x, frame %0d", d_hcode, tb.dut.bupchip.halt_pc, frame);
		end
		d_halted_q <= d_halted;
		if (g_dbg_lk !== g_lk) g_lk_bad++;
		if (g_dbg_ul !== g_ul) g_ul_bad++;
		if (g_dbg_ul) unlocks++;
	end
`endif

	always @(posedge tb.clk_sys) begin
		now++;
		// frames restart with every release of the console reset
		if (rst_q && !con_reset) begin
			releases++;
			running = 1;
			if (releases > 1 && (frame > 0 || call_id > 0)) begin
				$display("FRAMES console reset released again at clk_sys %0d, after frame %0d and %0d calls: the files start again, frames counted from here",
					now, frame, call_id);
				restart_files();
			end else if (releases > 1)
				$display("FRAMES console reset released again at clk_sys %0d: frames counted from here", now);
			frame = 0;		// (t_vs keeps the last rise, 0 before any: tb_daria's line for a call before frame 1)
		end
		rst_q = con_reset;
		if (!running) begin
			old_vs <= vsync_raw;
		end else begin
			// ---- RIOT timer events (phi2)
			if (r_ce && r_sel && !r_rw && r_a4) begin
				t_timer_write = now;
				expired = 0;
				zeroed = 0;
			end
			if (r_ce && r_tick && r_timer == 8'd1 && !zeroed && t_timer_write >= 0 && t_timer_write != now) begin
				zeroed = 1;
				t_zero = now;
				if (pending_zero) begin
					$fwrite(fd_zero, "%0d,%0d\n", zero_call, t_zero - zero_poll_t);
					pending_zero = 0;
				end
			end
			if (r_ce && r_wrap && !expired && t_timer_write >= 0) begin
				expired = 1;
				t_expire = now;
				if (pending_slack) begin
					$fwrite(fd_slack, "%0d,1,%0d,%0d,%04x\n", poll_call, poll_done_t, t_expire - t_poll, poll_pc);
					if (t_expire - t_poll < worst_slack) worst_slack = t_expire - t_poll;
					pending_slack = 0;
				end
			end
			if (r_ce && r_sel && r_rw && await_poll) begin
				await_poll = 0;
				t_poll = now;
				poll_pc = op_pc;
				poll_done_t = t_poll - poll_done_t;   // 6507 time from call end to poll
				if (t_timer_write >= 0 && t_timer_write <= poll_req_t) begin
					if (zeroed) $fwrite(fd_zero, "%0d,%0d\n", poll_call, t_zero - t_poll);
					else begin
						pending_zero = 1;
						zero_call = poll_call;
						zero_poll_t = t_poll;
					end
				end
				if (t_timer_write < 0 || t_timer_write > poll_req_t) begin
					$fwrite(fd_slack, "%0d,0,%0d,0,%04x\n", poll_call, poll_done_t, poll_pc);
				end else if (expired) begin
					$fwrite(fd_slack, "%0d,1,%0d,%0d,%04x\n", poll_call, poll_done_t, t_expire - t_poll, poll_pc);
					if (t_expire - t_poll < worst_slack) worst_slack = t_expire - t_poll;
					overruns++;
				end else
					pending_slack = 1;
			end

			// ---- calls as the 6507 sees them: daria_fe's arm_call_busy, from the
			// commit clock (the one before the registered busy rises)
			if (fe_busy && !sys_call) begin
				sys_call = 1;
				call_id++;
				t_req = now - 1;
				stall = 0;
				req_frame = frame;
				req_line = int'((t_req - t_vs) / SYS_PER_LINE);
				if (pending_slack) begin
					$fwrite(fd_slack, "%0d,2,%0d,0,%04x\n", poll_call, poll_done_t, poll_pc);
					pending_slack = 0;
				end
				await_poll = 0;
				pending_zero = 0;
			end
			if (sys_call && call_stall) stall++;
			if (sys_call && !fe_busy) begin
				sys_call = 0;
				sys_calls++;
				$fwrite(fd_calls, "%0d,%0d,%0d,%0d,%0d,%0d,%08x,%0d,%0d,%0d\n", call_id, req_frame, req_line,
					t_req, now - t_req, stall, 32'd0, done_cyc, done_thumb, done_arm);
				f_calls++;
				f_stall += stall;
				await_poll = 1;
				poll_call = call_id;
				poll_req_t = t_req;
				poll_done_t = now;
			end
			if (fe_dma) f_dma++;

			// ---- frames: the raw VSYNC bit's rising edge
			old_vs <= vsync_raw;
			if (vsync_raw && !old_vs) begin
				if (frame > 0) begin
					logic [63:0] h;
					h = FNV_OFFSET;
					for (int i = 0; i < 128; i++) h = fnv(h, `TF_M.riot_inst.riot_ram.mem_q[i]);
					$fwrite(fd_fp, "%0d,%0d,%016x,%016x,%016x\n", frame, now - t_vs, h, fp_video, fp_audio);
					$fwrite(fd_frames, "%0d,%0d,%0d,%.2f,%0d,%0d,%0d\n", frame, t_vs, now - t_vs,
						real'(now - t_vs) / SYS_PER_LINE, f_calls, f_stall, f_dma);
				end
				fp_video = FNV_OFFSET;
				fp_audio = FNV_OFFSET;
				frame++;
				t_vs = now;
				f_calls = 0; f_stall = 0; f_dma = 0;
				script();
				if (frame >= frames) finish_run();
			end
			// ---- fingerprint: this clock's pixel and sound
			if (ce_pix && !HBlank && !VBlank) fp_video = fnv(fnv(fnv(fp_video, R), G), B);
			if (fp_snd != fp_last) begin
				for (int i = 0; i < 4; i++) fp_audio = fnv(fp_audio, fp_snd[i*8 +: 8]);
				fp_last = fp_snd;
			end
		end
	end

	// A later release after something was written: the files and the per-run
	// counts start again (halts, psram_viol and unlocks keep counting).
	task automatic restart_files();
		$fclose(fd_fp); $fclose(fd_calls); $fclose(fd_slack); $fclose(fd_zero); $fclose(fd_frames);
		open_files();
		// a call in flight at the release (none expected: the console reset
		// abandons it) is logged as call 1 of the new files
		call_id = sys_call ? 1 : 0; sys_calls = 0; overruns = 0; worst_slack = 64'sh7fffffffffffffff;
		base_tog = n_tog; base_go = n_go; base_ret = n_ret;
		if (sys_call) begin
			$display("FRAMES a call was in flight at the release: logged as call 1 of the new files, with its frame and line from before; the call counts are not cross-checked");
			cross_off = 1;
		end
		t_timer_write = -1; t_expire = -1; expired = 0; zeroed = 0; t_zero = -1;
		await_poll = 0; pending_slack = 0; pending_zero = 0;
		f_calls = 0; f_stall = 0; f_dma = 0;
		fp_video = FNV_OFFSET; fp_audio = FNV_OFFSET;
		restarts++;
		script_reset();
		tb.joy0 = '0;
	endtask

	// ---- the TIA's paddle inputs (+inputs_tbdaria) -------------------------------------
	// R1's bench (tb_daria) drives INPT0-3 with a constant 4'b1010; the
	// Pocket's wrapper drives 0 on INPT1 and INPT3 for a 2600 image with a
	// joystick. A Genesis-pad-aware game takes INPT1 high as a Genesis pad
	// with button C released, so R1 ran such games in their Genesis mode and
	// the Pocket's inputs run them in another: the gate against R1 holds the
	// inputs to tb_daria's value. Without the option the wrapper's mapping
	// stands.
	initial begin
		if ($test$plusargs("inputs_tbdaria")) begin
			force tb.dut.idump = 4'b1010;
			$display("FRAMES inputs: tb_daria's (the TIA's INPT0-3, the wrapper's idump, held at 4'b1010; +inputs_tbdaria)");
		end else
			$display("FRAMES inputs: the Pocket's (INPT0-3 as the wrapper maps them)");
	end

	// ---- the input script (tb_daria.sv's), by frame, through joy0 -------------------------
	int fire_at = 420, reset_at = 0, select_at = 0, play_at = 480, seed = 1;
	logic [15:0] lfsr = 16'hACE1;
	logic fire = 0, sw_reset = 0, sw_select = 0;
	logic [3:0] dirs = 0;           // {right, left, down, up}, 1 = pressed (tb_daria's)
	initial begin
		void'($value$plusargs("fire_at=%d", fire_at));
		void'($value$plusargs("reset_at=%d", reset_at));
		void'($value$plusargs("select_at=%d", select_at));
		void'($value$plusargs("play_at=%d", play_at));
		void'($value$plusargs("seed=%d", seed));
		script_reset();
	end
	// as at time 0: nothing pressed (tb_load's joy0 starts at 0), the generator at its seed
	function automatic void script_reset();
		lfsr = 16'(seed * 40503 + 1);
		fire = 0; sw_reset = 0; sw_select = 0; dirs = 0;
	endfunction
	function automatic void script();
		fire      = (fire_at   != 0 && frame >= fire_at   && frame < fire_at + 6);
		sw_reset  = (reset_at  != 0 && frame >= reset_at  && frame < reset_at + 6);
		sw_select = (select_at != 0 && frame >= select_at && frame < select_at + 6);
		if (play_at != 0 && frame >= play_at) begin
			if (frame % 12 == 0) begin
				for (int i = 0; i < 5; i++) lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
				case (lfsr[2:0])
					3'd0: dirs = 4'b0000;
					3'd1: dirs = 4'b0001;   // up
					3'd2: dirs = 4'b0010;   // down
					3'd3: dirs = 4'b0100;   // left
					3'd4: dirs = 4'b1000;   // right
					3'd5: dirs = 4'b0101;
					3'd6: dirs = 4'b1010;
					default: dirs = 4'b1000;
				endcase
			end
			fire = (frame % 24) < 4 || lfsr[5];
		end
		// joy bits: 0 R, 1 L, 2 D, 3 U, 7 select, 8 reset, 9 A (fire 1)
		tb.joy0 = {6'd0, fire, sw_reset, sw_select, 3'd0, dirs[0], dirs[1], dirs[2], dirs[3]};
	endfunction
	// Before the first frame nothing is pressed, as in tb_daria (whose script
	// first runs at the reset release, frame 0, where every _at is past).

`ifdef BUP_DEBUG
`ifdef SIM_DARIA_FE
	// ---- the DARIA status overlay (FRAMES_DEBUG=1; the header) ------------------------------
	// Compared in the clock after each VSYNC rise, when no call, timer poll
	// or unlock is under way: the frame counter has moved on by then.
	int     ovl_cnt_bad = 0, ovl_cnt_n = 0;
	logic   ovl_vs_q = 0, ovl_vs_q2 = 0;
	logic [11:0] ovl_shown_late = 12'hFFF, ovl_shown_unl = 12'hFFF;
	logic   ovl_shown_lk = 1'b1;
	// the bench's values at the last two frame ends, for the end-of-run check
	int     ovl_b_late [0:1], ovl_b_unl [0:1];
	logic   ovl_b_lk [0:1];
	initial begin ovl_b_late = '{-1, -2}; ovl_b_unl = '{-1, -2}; ovl_b_lk = '{1'b0, 1'b1}; end
	function automatic int sat12(input int v); return v > 4095 ? 4095 : v; endfunction
	always @(posedge tb.clk_sys) begin
		ovl_vs_q <= vsync_raw;
		ovl_vs_q2 <= ovl_vs_q;
		if (running && ovl_vs_q && !ovl_vs_q2 && frame > 1) begin
			int calls_b;
			calls_b = n_tog - base_tog;
			ovl_cnt_n++;
			if (tb.dut.u_dstat.calls != 24'(calls_b) || tb.dut.u_dstat.late != 12'(sat12(overruns)) ||
				tb.dut.u_dstat.unl != 12'(sat12(unlocks)) || tb.dut.u_dstat.locked != g_dbg_lk) begin
				if (ovl_cnt_bad < 5)
					$display("OVERLAY frame %0d: counts calls %0d late %0d unlocks %0d guard %0d, the bench's %0d %0d %0d %0d",
						frame, tb.dut.u_dstat.calls, tb.dut.u_dstat.late, tb.dut.u_dstat.unl, tb.dut.u_dstat.locked, calls_b, overruns, unlocks, g_dbg_lk);
				ovl_cnt_bad++;
			end
			ovl_b_late[1] = ovl_b_late[0]; ovl_b_late[0] = overruns;
			ovl_b_unl[1] = ovl_b_unl[0]; ovl_b_unl[0] = unlocks;
			ovl_b_lk[1] = ovl_b_lk[0]; ovl_b_lk[0] = g_dbg_lk;
			if (tb.ovl_frames > 0 && (tb.ovl_last[2] != ovl_shown_late || tb.ovl_last[3] != ovl_shown_unl ||
				tb.ovl_last[0][10] != ovl_shown_lk || frame % 100 == 0)) begin
				$display("OVERLAY frame %0d: %0s", frame, tb.ovl_shown());
				ovl_shown_late = tb.ovl_last[2];
				ovl_shown_unl = tb.ovl_last[3];
				ovl_shown_lk = tb.ovl_last[0][10];
			end
		end
	end
	// +ovl_halt_at=F: from frame F on, the BupChip's debug status word and
	// halt PC (bupchip.dbg_status_arm and halt_pc, which only the overlay
	// reads) are forced to a halt: CPU running, halted, halt code 9, halt PC
	// 0x40001234. The overlay then draws its nine rows, and the end of the
	// run expects the picture to show exactly that. The CPU runs on, so the
	// frames, calls and counts stay the run's own.
	int     ovl_halt_at = 0;
	initial void'($value$plusargs("ovl_halt_at=%d", ovl_halt_at));
	always @(posedge tb.clk_sys)
		if (ovl_halt_at > 0 && running && frame == ovl_halt_at) begin
			force tb.dut.bupchip.dbg_status_arm = 32'h9900_0000;
			force tb.dut.bupchip.halt_pc = 32'h4000_1234;
		end
	// At the end: what the picture showed, the checks, and the result. The
	// picture's last whole frame is compared with the bench's counts only
	// where these stood still over the last two frame ends; at least one of
	// the three must be compared (a run where none is checks nothing there).
	function automatic bit ovl_finish();
		bit ok, late_ok, unl_ok, lk_ok;
		int n_cmp;
		string late_s, unl_s, lk_s;
		late_ok = 1; unl_ok = 1; lk_ok = 1; n_cmp = 0;
		late_s = "not compared (changed in the last two frames)"; unl_s = late_s; lk_s = late_s;
		if (ovl_b_late[0] == ovl_b_late[1]) begin
			n_cmp++; late_ok = tb.ovl_last[2] == 12'(sat12(ovl_b_late[0])); late_s = late_ok ? "equal" : "DIFFER"; end
		if (ovl_b_unl[0] == ovl_b_unl[1]) begin
			n_cmp++; unl_ok = tb.ovl_last[3] == 12'(sat12(ovl_b_unl[0])); unl_s = unl_ok ? "equal" : "DIFFER"; end
		if (ovl_b_lk[0] == ovl_b_lk[1]) begin
			n_cmp++; lk_ok = tb.ovl_last[0][10] == ovl_b_lk[0]; lk_s = lk_ok ? "equal" : "DIFFER"; end
		$display("OVERLAY counts: calls %0d, late %0d, unlocks %0d, guard %0s; %0d of %0d frame ends differ from the bench's",
			tb.dut.u_dstat.calls, tb.dut.u_dstat.late, tb.dut.u_dstat.unl, tb.dut.u_dstat.locked ? "locked" : "unlocked", ovl_cnt_bad, ovl_cnt_n);
		$display("OVERLAY checks: the RIOT copy differs on %0d clk_sys; %0d of %0d cells read back differ from the layout; %0d frames drew rows 6-8 while not halted; the picture against the bench (%0d of 3 compared): late calls %0s, unlocks %0s, guard %0s",
			tb.ovl_rt_bad, tb.ovl_px_bad, tb.ovl_px_n, tb.ovl_rows_bad, n_cmp, late_s, unl_s, lk_s);
		$display("OVERLAY %0s; %0s", tb.ovl_checked(), tb.ovl_cover_ok() ? "enough" : "NOT ENOUGH");
		$display("OVERLAY %0s", tb.ovl_shown());
		// a game's frame shows all six rows, and rows 6-8 only while halted
		ok = ovl_cnt_bad == 0 && ovl_cnt_n > 0 && tb.ovl_rt_bad == 0 && tb.ovl_px_bad == 0 && tb.ovl_frames > 0 &&
			tb.ovl_rows_bad == 0 && (ovl_halt_at > 0 ? tb.ovl_last_rows[5:0] == 6'h3F : tb.ovl_last_rows == 9'h03F) &&
			late_ok && unl_ok && lk_ok && n_cmp > 0 && tb.ovl_cover_ok();
		if (ovl_halt_at > 0) begin
			bit h_ok;
			h_ok = tb.ovl_last_rows == 9'h1FF && tb.ovl_last[0][11] && tb.ovl_last[0][8] && tb.ovl_last[1] == 12'h900 &&
				{tb.ovl_last[6][7:0], tb.ovl_last[7], tb.ovl_last[8]} == 32'h4000_1234;
			$display("OVERLAY the forced halt (+ovl_halt_at=%0d): %0s", ovl_halt_at,
				h_ok ? "shown as forced (halted, code 9, fault code 0, PC 40001234, nine rows)" : "NOT shown as forced");
			ok = ok && h_ok;
		end
		$display("OVERLAY result: %s", ok ? "PASS" : "FAIL");
		return ok;
	endfunction
`endif
`endif

	// ---- the end ------------------------------------------------------------------------
	task automatic finish_run();
		bit ok, calls_ok;
		string guard;
		int psram_viol;
		real secs;
		$fclose(fd_fp); $fclose(fd_calls); $fclose(fd_slack); $fclose(fd_zero); $fclose(fd_frames);
		fd_fp = 0;
		secs = real'(now) / 14318181.0;
`ifdef POCKET_BUPCHIP
		psram_viol = tb.cram0_chip.n_viol;
`else
		psram_viol = 0;
`endif
`ifdef SIM_DARIA_FE
		guard = g_dbg_lk ? "locked" : "unlocked";
`else
		guard = "none";
`endif
		$display("ran %0d frames, %0d calls", frame, sys_calls);
		$display("FRAMES %0d frames after release %0d of the console reset (the files started again %0d times); %.3f s emulated; %0d calls, %0d late (overruns), worst slack %0d clk_sys",
			frame, releases, restarts, secs, sys_calls, overruns, sys_calls == 0 ? 0 : worst_slack);
`ifdef SIM_DARIA_FE
		$display("FRAMES guard: dbg_locked %0d (u_guard.lk %0d), %0d clk_sys where dbg_locked differed from u_guard.lk, %0d where dbg_unlock differed from ev_unlock; halt_code %0d",
			g_dbg_lk, g_lk, g_lk_bad, g_ul_bad, d_hcode);
		begin
			int tg, go, rt;
			bit flight;
			string since, verdict;
			tg = n_tog - base_tog; go = n_go - base_go; rt = n_ret - base_ret;
			// One call at most in flight at the end: posted (call_tog flipped,
			// the busy up or about to rise) and not yet ended. Every ended call
			// was posted, started and returned once; a started one was posted,
			// a returned one started.
			flight = sys_call || fe_busy || now - t_last_tog <= 4;
			calls_ok = cross_off || (tg == sys_calls + (flight ? 1 : 0) && go >= sys_calls && go <= tg && rt >= sys_calls && rt <= go);
			since = "";
			if (restarts != 0) since = " (since the last restart)";
			verdict = calls_ok ? "consistent" : "MISMATCH";
			if (cross_off) verdict = "not checked (a call in flight at a restart)";
			$display("FRAMES calls: %0d busy periods (the 6507's), %0d call_tog flips, %0d call_go, %0d returned%s, %0d in flight at the end: %s",
				sys_calls, tg, go, rt, since, flight, verdict);
		end
		$display("STATUS calls %0d, late %0d, halts %0d, halt_code %0d, psram_viol %0d, guard %s, unlocks %0d",
			sys_calls, overruns, halts, halts != 0 ? int'(d_hcode) : 0, psram_viol, guard, unlocks);
		ok = halts == 0 && psram_viol == 0 && unlocks == 0 && g_lk_bad == 0 && g_ul_bad == 0 && calls_ok && frame == frames;
`ifdef BUP_DEBUG
		ok = ovl_finish() && ok;
`endif
`else
		$display("FRAMES no daria_fe in the wrapper (not a POCKET_DARIA build, or u_fe not wired): calls not seen");
		$display("STATUS calls %0d, late %0d, halts %0d, halt_code %0d, psram_viol %0d, guard %s, unlocks %0d",
			sys_calls, overruns, 0, 0, psram_viol, guard, 0);
		ok = psram_viol == 0 && frame == frames;
`endif
		$display("FRAMES result: %s", ok ? "PASS" : "FAIL");
		$finish;
	endtask
	initial begin
		#1;
		#(longint'(maxms) * 1000000);
		$display("FRAMES timeout: %0d ms of simulated time, %0d frames after %0d releases", maxms, frame, releases);
		$display("FRAMES result: FAIL");
		$fatal(1, "tb_frames: timeout");
	end
endmodule
