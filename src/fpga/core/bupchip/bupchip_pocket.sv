//------------------------------------------------------------------------------
// The Pocket's BupChip (docs/BUPCHIP_CORE.md): ARIA (bup_cpu.sv) with its
// firmware ROM and RAM, the asset cache in front of the PSRAM, the capture of
// the firmware and ARSC downloads, upstream's peripheral, and the crossings
// between clk_sys, clk_arm and clk_74a.
//
// Clocks. clk_sys (console, loader, audio out); clk_arm (the CPU and
// everything around it; 2 x clk_sys for S1, from the same VCO and edge
// aligned); clk_74a (the 48 kHz tick only). Crossings (design, "Crossings"):
//
//   $8007 command    clk_sys -> clk_arm   byte held, toggle, change detect
//   hold, pause      clk_sys -> clk_arm   two flops
//   capture messages clk_sys -> clk_arm   bup_capture / bup_asset_wr
//   48 kHz tick      clk_74a -> clk_arm   bup_tick48k
//   audio frame      clk_arm -> clk_sys   frame held, toggle, captured on the
//                                         change between the second and third
//                                         flops
//
// Nothing else crosses, so the wrapper stays correct if clk_arm ever gets a
// PLL of its own: the peripheral's mute (clk_arm) is applied to the frame as
// it is ticked, not on clk_sys as upstream does, and BUP_DEBUG's capture
// flags (clk_sys) reach the status word through two clk_arm flops.
//
// Hold (design, "Reset and hold"):
//
//   hold    = ~pll_locked_s | pll_busy_s | ~souper_profile        (clk_sys)
//   pre_run = ~hold (two clk_arm flops) & fw_loaded & asset_ready (clk_arm)
//   cpu_run = pre_run & sweep_done, registered
//
// While cpu_run is low the CPU (and its halt status), the peripheral and its
// FIFOs, and the cache's fill and prefetch are held in reset, and the audio
// frame reads 0. The capture, the write receiver, asset_ready, asset_size,
// fw_loaded, the ROM's write path, the tick and the PSRAM controller are not
// held. sweep_done follows a 64-clock tag sweep after every release (the S1
// core clears its own registers after rst). The console reset is not part of
// the hold, as on MiSTer, so the music survives a 7800 reset.
//
// Memories: ROM 4,096 x 32 (cache_ram_dp; port A fetches, port B serves data
// and, while fw_loaded is low, takes the firmware's words), no initial
// contents: the firmware comes through the data slot. RAM 4,096 x 32 with
// byte lanes (cache_ram_tdp_dc_be, port A). Assets: bup_asset_cache.
//
// Peripheral: upstream's bupchip_peripheral.sv, unmodified, at CMD_DEPTH 8 and
// PCM_DEPTH (1,024). On writes to 0x18 the watermark W becomes
// clamp(W - (4096 - PCM_DEPTH), 0, PCM_DEPTH), so the firmware's 3,896 keeps
// its assumption D - W = 200 (design, "PCM and command FIFOs").
//
// Pop: pop = tick & pcm_enabled & !pause (and cpu_run). An empty FIFO plays 0,
// and so does a tick while muted (a FAULT write), held or paused. On clk_sys
// the frame reads 0 while souper_profile is low.
// The peripheral raises pcm_available in the clock after a push into an
// empty FIFO, one clock before its M10K presents that frame. A tick landing
// in a clock where pcm_available has just risen (that, or PCM being enabled)
// waits one clock, so the frame read is never stale.
//
// PSRAM: the wrapper drives psram.sv's user ports (agg23, MIT, vendored in
// pocket_utils/psram.sv, instantiated by the parent on clk_arm with
// CLOCK_SPEED = 28.636364 and bank 0 of cram0).
//
// BUP_DEBUG adds dbg_status / dbg_halt_pc (clk_arm), dbg_load, shadow FIFO
// counters and the throttle (BUP_THROTTLE of every 16 clocks may start an
// instruction):
//
//   dbg_status [31] cpu_run      [30] fw_loaded     [29] asset_ready
//              [28] halted       [27:24] halt_code
//              [23] command overflow [22] PCM overflow [21] PCM underflow
//              [20] muted        [19:12] fault code [11] capture error
//              [10:0] lowest PCM level since the FIFO first reached its
//                     watermark (the boot's prefill), saturating at 2,047
//                     (only reachable with PCM_DEPTH above 1,024)
//   dbg_load   the capture's seq_err and lost, the receiver's overrun, the
//              load probe's counts (bup_load_probe.sv) and the firmware
//              check below; bup_status_osd.sv has the layout
//
// The shadow flags (overflows, underflow) are cleared by the hold; capture
// error, seq_err, lost and overrun are sticky from power-up. Shadow counters: command level
// +1 on cmd_valid, -1 on a read of 0x04 while not empty, 0 on a flush;
// overflow is cmd_valid at 8. PCM level +1 on a push below PCM_DEPTH, -1 on a
// pop while not empty; overflow is a push at PCM_DEPTH, underflow a pop while
// pcm_available is low.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bupchip_pocket #(
	parameter int PCM_DEPTH    = 1024,
	parameter int BUP_THROTTLE = 16,    // BUP_DEBUG: clocks of every 16 that may start an instruction
	parameter bit PREEMPT      = 1'b1,  // bup_asset_cache
	parameter bit PREFETCH     = 1'b1   // bup_asset_cache
) (
	input  wire        clk_sys,
	input  wire        clk_arm,
	input  wire        clk_74a,

	input  wire        pll_locked,      // raw: synchronised here
	input  wire        pll_busy,        // raw: synchronised here
	input  wire        souper_profile,  // clk_sys (top.sv)
	input  wire        pause,           // clk_sys (pause_core)

	// Downloads, clk_sys. Every byte the loader delivers (byte_valid, with
	// load_addr / load_data) and bits 27:25 of its bridge address: the
	// cartridge slot's bytes (0x00000000) have 0 there, bupchip.bin's
	// (0x0A000000) 5, whatever slot flag is up (bup_capture.sv, "Which bytes
	// are the BupChip's"). The cartridge's start and end
	// (atari7800_pocket.sv's mapper_load_*), and the firmware slot's flag.
	input  wire        byte_valid,
	input  wire  [2:0] byte_hi,
	input  wire [24:0] load_addr,
	input  wire  [7:0] load_data,
	input  wire        load_start,
	input  wire        load_end,
	input  wire        fw_download,

	// $8007 commands, clk_sys, one clock per command (bup_cmd_*_eff).
	input  wire        cmd_valid,
	input  wire  [7:0] cmd_data,

	// Audio, clk_sys: signed 16-bit as plain bits (top.sv bupchip_audio_*).
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// psram.sv's user side, clk_arm.
	output wire        psram_bank_sel,
	output wire [21:0] psram_addr,
	output wire        psram_write_en,
	output wire [15:0] psram_data_in,
	output wire        psram_write_high_byte,
	output wire        psram_write_low_byte,
	output wire        psram_read_en,
	input  wire        psram_read_avail,
	input  wire [15:0] psram_data_out,
	input  wire        psram_busy
`ifdef BUP_DEBUG
	,
	output logic [31:0] dbg_status,
	output logic [31:0] dbg_halt_pc,
	output logic [110:0] dbg_load     // bup_status_osd.sv, rows 4-12 and the capture's flags
`endif
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial audio_l = 16'd0;
	initial audio_r = 16'd0;
	// ---- hold ---------------------------------------------------------------------
	logic [1:0] locked_s = 2'b00, busy_s = 2'b00;
	logic       hold_sys = 1'b1;
	always_ff @(posedge clk_sys) begin
		locked_s <= {locked_s[0], pll_locked};
		busy_s <= {busy_s[0], pll_busy};
		hold_sys <= ~locked_s[1] | busy_s[1] | ~souper_profile;
	end

	logic [1:0] hold_a = 2'b11, pause_a = 2'b00;
	always_ff @(posedge clk_arm) begin
		hold_a <= {hold_a[0], hold_sys};
		pause_a <= {pause_a[0], pause};
	end
	wire paused = pause_a[1];

	wire        asset_ready, fw_loaded, sweep_done;
	wire [23:0] asset_size;
	wire        pre_run = ~hold_a[1] & fw_loaded & asset_ready;
	logic       cpu_run = 1'b0;
	always_ff @(posedge clk_arm)
		cpu_run <= pre_run & sweep_done;

	// ---- capture and write receiver ------------------------------------------------
	wire  [2:0] msg_type;
	wire [43:0] msg_pl;
	wire        msg_tog, cap_seq_err, cap_lost, cap_cart_win, cap_fw_win, wr_overrun, wr_fw_start;
	wire        load_valid = byte_valid && byte_hi == 3'd0;
	wire        fw_valid   = byte_valid && byte_hi == 3'd5;

	bup_capture capture (
		.clk(clk_sys),
		.load_start, .load_addr, .load_valid, .load_data, .load_end,
		.fw_download, .fw_valid,
		.msg_type, .msg_pl, .msg_tog,
		.seq_err(cap_seq_err), .lost(cap_lost), .cart_win(cap_cart_win), .fw_win(cap_fw_win));

	wire        rom_we;
	wire [11:0] rom_wa;
	wire [31:0] rom_wd;
	wire        rd_req, rd_ack;
	wire [21:0] rd_addr;

	bup_asset_wr writer (
		.clk(clk_arm),
		.msg_type, .msg_pl, .msg_tog,
		.asset_ready, .asset_size, .fw_loaded,
		.rom_we, .rom_wa, .rom_wd,
		.rd_req, .rd_addr, .rd_ack,
		.psram_bank_sel, .psram_addr, .psram_write_en, .psram_data_in,
		.psram_write_high_byte, .psram_write_low_byte, .psram_read_en, .psram_busy,
		.overrun(wr_overrun), .fw_start(wr_fw_start));

	// ---- the CPU and its memories -------------------------------------------------------
	wire  [11:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, reg_rdata, asset_q;
	wire   [3:0] ram_be;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, w_wait, reg_sel, reg_write;
	wire         halted;
	wire   [3:0] halt_code;
	wire  [31:0] halt_pc;
	wire         freeze;

`ifndef ALTERA_RESERVED_QIS
	// Retire port, for the testbench (bup_cpu.sv, sim/bupchip/verif/README.md).
	wire         rt_start, rt_valid, rt_e_we, rt_w_we;
	wire  [31:0] rt_pc, rt_insn, rt_e_data, rt_w_data;
	wire   [3:0] rt_nzcv, rt_e_idx, rt_w_idx;
`endif

	bup_cpu cpu (
		.clk(clk_arm), .rst(~cpu_run), .freeze, .w_wait, .arm_only(1'b1),
		.prof26(1'b0), .img_size(20'd0), .ram32(1'b0), .call_go(1'b0), .clr_wd(32'd0), .clr_pc(32'd0),
		.clr_e(), .parked(), .returned(), .ro_valid(), .ro_idx(), .ro_data(),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size, .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc
`ifndef ALTERA_RESERVED_QIS
		,
		.rt_start, .rt_valid, .rt_pc, .rt_insn, .rt_nzcv,
		.rt_e_we, .rt_e_idx, .rt_e_data, .rt_w_we, .rt_w_idx, .rt_w_data
`endif
	);

	// Port B belongs to the receiver while fw_loaded is low: the CPU is held
	// then, so it makes no data reads.
	cache_ram_dp #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) rom (
		.clk_i(clk_arm),
		.addr_a_i(rom_addr), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(rom_q),
		.addr_b_i(fw_loaded ? d_addr[13:2] : rom_wa), .wren_b_i(rom_we && !fw_loaded),
		.wdata_b_i(rom_wd), .q_b_o(rom_dq));

	cache_ram_tdp_dc_be #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) ram (
		.clk_a_i(clk_arm), .addr_a_i(d_addr[13:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
		.wdata_a_i(ram_wdata), .q_a_o(ram_q),
		.clk_b_i(clk_arm), .addr_b_i(12'd0), .wren_b_i(1'b0), .byteena_b_i(4'd0),
		.wdata_b_i(32'd0), .q_b_o());

	wire st_miss, st_pf, st_preempt, st_late, st_stall;
	bup_asset_cache #(.PREEMPT(PREEMPT), .PREFETCH(PREFETCH)) cache (
		.clk(clk_arm), .pre_run, .run(cpu_run), .sweep_done,
		.d_addr, .w_asset, .w_addr, .w_size, .asset_q, .w_wait,
		.rd_req, .rd_addr, .rd_ack, .rd_avail(psram_read_avail), .rd_data(psram_data_out),
		.st_miss, .st_pf, .st_preempt, .st_late, .st_stall);

`ifdef BUP_DEBUG
	logic [3:0] thr_phase = 4'd0;
	always_ff @(posedge clk_arm) thr_phase <= thr_phase + 4'd1;
	assign freeze = BUP_THROTTLE < 16 && {28'd0, thr_phase} >= BUP_THROTTLE;
`else
	assign freeze = 1'b0;
`endif

	// ---- $8007 commands ---------------------------------------------------------------
	logic       cmd_tog = 1'b0;
	logic [7:0] cmd_byte = 8'd0;
	always_ff @(posedge clk_sys)
		if (cmd_valid) begin
			cmd_byte <= cmd_data;
			cmd_tog <= ~cmd_tog;
		end

	logic [2:0] cmd_s = 3'd0;
	logic       cmd_valid_arm = 1'b0;
	logic [7:0] cmd_data_arm = 8'd0;
	always_ff @(posedge clk_arm) begin
		cmd_s <= {cmd_s[1:0], cmd_tog};
		cmd_valid_arm <= cmd_s[2] ^ cmd_s[1];
		cmd_data_arm <= cmd_byte;
	end

	// ---- peripheral, with the watermark remap -------------------------------------------
	localparam int WM_SHIFT = 4096 - PCM_DEPTH;
	logic [31:0] reg_wdata_eff;
	always_comb begin
		reg_wdata_eff = reg_wdata;
		if (reg_addr == 8'h18) begin
			if ({19'd0, reg_wdata[28:16]} <= WM_SHIFT)
				reg_wdata_eff[28:16] = 13'd0;
			else if ({19'd0, reg_wdata[28:16]} - WM_SHIFT >= PCM_DEPTH)
				reg_wdata_eff[28:16] = 13'(PCM_DEPTH);
			else
				reg_wdata_eff[28:16] = reg_wdata[28:16] - 13'(WM_SHIFT);
		end
	end

	wire        pcm_pop, pcm_available, pcm_enabled, muted;
	wire [31:0] pcm_frame;
	wire  [7:0] fault_code;

	bupchip_peripheral #(.CMD_DEPTH(8), .PCM_DEPTH(PCM_DEPTH)) per (
		.clk(clk_arm), .reset(~cpu_run),
		.cmd_valid(cmd_valid_arm), .cmd_data(cmd_data_arm),
		.reg_sel, .reg_addr, .reg_write, .reg_wdata(reg_wdata_eff), .reg_rdata,
		.pcm_pop, .pcm_frame, .pcm_available, .pcm_enabled, .muted, .fault_code);

	// ---- 48 kHz pop and the frame register ------------------------------------------------
	wire  tick;
	bup_tick48k tick48k (.clk_74a, .clk_arm, .tick);

	logic        tick_hold = 1'b0, avail_q = 1'b0;
	logic [31:0] frame_arm = 32'd0;
	logic        frame_tog = 1'b0;
	wire         tick_now = tick | tick_hold;
	wire         head_ok = !pcm_available || avail_q;	// pcm_frame shows the head
	wire         do_tick = tick_now && head_ok;
	assign pcm_pop = do_tick && cpu_run && pcm_enabled && !paused;

	always_ff @(posedge clk_arm) begin
		avail_q <= pcm_available;
		tick_hold <= tick_now && !head_ok;
		if (do_tick) begin
			frame_arm <= cpu_run && pcm_available && !paused && !muted ? pcm_frame : 32'd0;
			frame_tog <= ~frame_tog;
		end
	end

	// ---- the frame back to clk_sys ----------------------------------------------------------
	logic [2:0] ftog_s = 3'd0;
	wire        frame_cap = ftog_s[2] ^ ftog_s[1];
	always_ff @(posedge clk_sys) begin
		ftog_s <= {ftog_s[1:0], frame_tog};
		if (frame_cap) begin
			audio_l <= frame_arm[15:0];
			audio_r <= frame_arm[31:16];
		end
		if (!souper_profile) begin
			audio_l <= 16'd0;
			audio_r <= 16'd0;
		end
	end

`ifdef BUP_DEBUG
	// ---- shadow FIFO counters and the status word -------------------------------------------
	localparam int LW = $clog2(PCM_DEPTH) + 1;
	logic    [3:0] sh_cmd = 4'd0;
	logic [LW-1:0] sh_pcm = '0, sh_min = '0, sh_wm = '0;
	logic          sh_cmd_ovf = 1'b0, sh_pcm_ovf = 1'b0, sh_pcm_unf = 1'b0, sh_armed = 1'b0;

	wire c_wr    = reg_sel && reg_write;
	wire c_inc   = cmd_valid_arm && sh_cmd != 4'd8;
	wire c_dec   = reg_sel && !reg_write && reg_addr == 8'h04 && sh_cmd != 4'd0;
	wire c_flush = c_wr && reg_addr == 8'h0C && reg_wdata[1];
	wire p_push  = c_wr && reg_addr == 8'h10;
	wire p_inc   = p_push && sh_pcm != LW'(PCM_DEPTH);
	wire p_dec   = pcm_pop && sh_pcm != '0;

	always_ff @(posedge clk_arm)
		if (!cpu_run) begin
			sh_cmd <= 4'd0;
			sh_pcm <= '0;
			sh_min <= LW'(PCM_DEPTH);
			sh_wm <= '0;
			sh_armed <= 1'b0;
			sh_cmd_ovf <= 1'b0;
			sh_pcm_ovf <= 1'b0;
			sh_pcm_unf <= 1'b0;
		end else begin
			sh_cmd <= c_flush ? {3'd0, c_inc} : sh_cmd + {3'd0, c_inc} - {3'd0, c_dec};
			if (cmd_valid_arm && sh_cmd == 4'd8) sh_cmd_ovf <= 1'b1;
			sh_pcm <= sh_pcm + LW'(p_inc) - LW'(p_dec);
			if (p_push && sh_pcm == LW'(PCM_DEPTH)) sh_pcm_ovf <= 1'b1;
			if (pcm_pop && !pcm_available) sh_pcm_unf <= 1'b1;
			if (c_wr && reg_addr == 8'h18) sh_wm <= reg_wdata_eff[16 +: LW];
			if (pcm_enabled && sh_wm != '0 && sh_pcm >= sh_wm) sh_armed <= 1'b1;
			if (sh_armed && pcm_enabled && sh_pcm < sh_min) sh_min <= sh_pcm;
		end

	// The capture's sticky flags, clk_sys, through two clk_arm flops.
	logic       cap_err_sys = 1'b0;
	logic [1:0] cap_err_a = 2'b00;
	always_ff @(posedge clk_sys) cap_err_sys <= cap_seq_err | cap_lost;
	always_ff @(posedge clk_arm) cap_err_a <= {cap_err_a[0], cap_err_sys};

	wire [10:0] sh_min11 = (sh_min > LW'(2047)) ? 11'h7FF : 11'(sh_min);
	assign dbg_status = {cpu_run, fw_loaded, asset_ready, halted, halt_code,
		sh_cmd_ovf, sh_pcm_ovf, sh_pcm_unf, muted, fault_code,
		cap_err_a[1] | wr_overrun, sh_min11};
	assign dbg_halt_pc = halt_pc;

	// The firmware as written into the ROM (clk_arm): words since FWSTART,
	// whether each went to the word after the last, and their CRC-32 (zlib's,
	// over the bytes in file order) against bupchip.bin's published one
	// (docs/BUPCHIP.md, "Files the user supplies on the Pocket").
	function automatic logic [31:0] crc32_word(input logic [31:0] c, input logic [31:0] w);
		logic [31:0] x;
		x = c ^ w;
		for (int i = 0; i < 32; i++)
			x = x[0] ? (x >> 1) ^ 32'hEDB88320 : x >> 1;
		return x;
	endfunction
	logic [31:0] fc_crc = 32'hFFFFFFFF;
	logic [11:0] fc_count = 12'd0, fc_next = 12'd0;
	logic        fc_order = 1'b1;
	always_ff @(posedge clk_arm)
		if (wr_fw_start) begin
			fc_crc <= 32'hFFFFFFFF;
			fc_count <= 12'd0;
			fc_next <= 12'd0;
			fc_order <= 1'b1;
		end else if (rom_we && !fw_loaded) begin
			fc_crc <= crc32_word(fc_crc, rom_wd);
			if (fc_count != 12'hFFF) fc_count <= fc_count + 12'd1;
			if (rom_wa != fc_next) fc_order <= 1'b0;
			fc_next <= rom_wa + 12'd1;
		end
	wire fc_crc_ok = fw_loaded && ~fc_crc == 32'h95B8B4F8;

	// What the loader delivered around the slot switches (clk_sys).
	wire  [7:0] pr_foreign;
	wire  [5:0] pr_cart_late, pr_fw_late;
	wire [11:0] pr_dropped, pr_t_pre, pr_fw_tail, pr_cart_tail, pr_word_min, pr_err_at;
	bup_load_probe probe (
		.clk(clk_sys), .byte_wr(byte_valid), .byte_hi, .byte_addr(load_addr),
		.load_start, .load_end, .fw_download, .cart_win(cap_cart_win), .fw_win(cap_fw_win),
		.seq_err(cap_seq_err),
		.foreign(pr_foreign), .cart_late(pr_cart_late), .fw_late(pr_fw_late), .dropped(pr_dropped),
		.t_pre(pr_t_pre), .fw_tail(pr_fw_tail), .cart_tail(pr_cart_tail), .word_min(pr_word_min),
		.err_at(pr_err_at));

	// Display only: bup_status_osd samples it on clk_sys.
	assign dbg_load = {cap_seq_err, cap_lost, wr_overrun,
		pr_err_at, pr_word_min, pr_cart_tail, pr_fw_tail, pr_t_pre, pr_dropped,
		pr_cart_late, pr_fw_late, fc_crc_ok, fc_order, 2'b00, pr_foreign, fc_count};
`endif
endmodule

`default_nettype wire
