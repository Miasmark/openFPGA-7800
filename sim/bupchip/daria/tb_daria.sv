//------------------------------------------------------------------------------
// DARIA dynamic measurement: the MiSTer core's own 2600 path (the vendored
// top.sv, Atari7800) running a 2600 ARM cartridge (DPC+, CDF, CDFJ, CDFJ+) on
// upstream's ARM7TDMI (arm_host) and ARM mapper (arm_mapper_*, mapper_dpcplus,
// mapper_cdf), as MiSTer builds it: no NO_ARM_MAPPER, clk_arm = 5 x clk_sys
// (71.59 MHz), the ROM shadow in a behavioural DDR3. Nothing in src/ changes;
// everything measured is read through hierarchical references.
//
// The bench loads the image the way the MiSTer loader does (detect2600 picks
// the scheme), drives the console switches and joystick from a simple script,
// and records every ARM call (CALLFN $FE/$FF):
//   calls.csv   one line per call: when (frame, scanline), how long the 6507
//               was held, ARM clocks, instructions (Thumb/ARM), fetch and
//               data traffic by region, distinct code footprint, an
//               ARM7TDMI zero-wait cycle estimate, I/D-cache misses, and
//               DARIA S1/S3 cycle estimates (s1_cyc, s3_cyc: each retired
//               instruction charged its ARM equivalent's clocks from
//               docs/BUPCHIP_CORE.md "Cycles per class", zero-wait memory)
//   slack.csv   per call, the RIOT-timer slack the 6507 had left when it
//               first polled INTIM/TIMINT after the call (negative: overrun),
//               and the 6507 PC of that poll
//   zero.csv    the same slack measured to the clock INTIM first reads 0
//               (where an LDx INTIM / BNE wait ends) instead of the wrap;
//               it also resolves calls whose timer is reloaded before it
//               wraps (negative: the wait would end late)
//   frames.csv  per frame: length in clk_sys and scanlines, calls, work
//   summary.txt totals: Thumb format mix, ARM-state classes, region traffic,
//               RAM traffic by KiB, MMIO addresses, cache hit rates, data
//               accesses not aligned to their size (as the ARM bus shows them)
//   pcs.txt     every retired PC with its count (game-derived: sim/work only)
//   snap_*.ppm  frames for checking the game got past its title screen
//   dtrace.txt  with +dtrace=1 (game-derived: sim/work only)
//   mmio.csv    with +mmiolog=1: every MMIO access
//
// Plusargs:
//   +rom=FILE      2600 image (.bin)                         (required)
//   +out=PREFIX    output path prefix, e.g. dir/              (default ./)
//   +frames=N      frames to run after reset release          (default 1500)
//   +fire_at=F     hold FIRE for 6 frames at frame F (0: off)  (default 420)
//   +reset_at=F    hold console RESET for 6 frames at F       (default 0)
//   +select_at=F   hold console SELECT for 6 frames at F      (default 0)
//   +play_at=F     from frame F, a pseudo-random joystick and FIRE
//                  (0: off)                                    (default 480)
//   +seed=N        joystick LFSR seed                          (default 1)
//   +lat=N         DDR3 read latency in clk_arm                (default 20)
//   +snap=N        write a snapshot every N frames (0: off)    (default 150)
//   +arm_div=K     run the ARM and its memory system one clk_arm in K, by
//                  forcing their clock enables (the core's pause inputs):
//                  a reference K times slower, to check call budgets
//                  against real overruns                       (default 1)
//                  NOTE: with K = 2 the run makes no progress (seen
//                  2026-10-04 on Galagon and Elevator Agent); not debugged
//   +dtrace=1      also write dtrace.txt: every ARM data read from
//                  cartridge ROM as one hex word, size << 24 | address,
//                  and "c CALL FRAME" where each call starts   (default 0)
//   +mmiolog=1     also write mmio.csv: every MMIO access with its call,
//                  frame, the instructions retired and clk_arm edges
//                  since the call started, clk_arm edges since time 0,
//                  and the data written or read           (default 0)
//
// Cache model: direct-mapped, 1/2/4/8/16 KiB, 16 and 32 byte lines, cold at
// power-up and warm across calls. Stream I is the retired-PC stream in
// cartridge ROM (one access per instruction, what a DARIA front end would
// fetch), D is the ARM's data reads from ROM, U is both through one cache.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_daria;
	// clk_sys 14.3184 MHz and clk_arm 71.592 MHz, rising together every
	// clk_sys, the MiSTer core's clock plan (decision 0088, NTSC).
	logic clk_sys = 0, clk_arm = 0;
	always #34920 clk_sys = ~clk_sys;
	always #6984  clk_arm = ~clk_arm;
	localparam real SYS_HZ = 14318181.0;
	localparam real ARM_HZ = 5.0 * 14318181.0;
	localparam int  SYS_PER_LINE = 912;     // 228 colour clocks x 4
	localparam int  SYS_PER_CPU  = 12;      // 6507 cycle = 3 colour clocks

	// ------------------------------------------------------------------ load
	logic        reset_in = 1, arm_reset = 1;
	logic        cart_download = 0, old_cart_download = 0;
	logic        ioctl_wr = 0;
	logic [24:0] ioctl_addr = 0;
	logic  [7:0] ioctl_dout = 0;
	logic        tia_mode = 0;
	logic        reset = 1;
	wire         mapper_load_wait, mapper_init_busy;
	wire  [31:0] cart_size;

	always @(posedge clk_sys) begin
		old_cart_download <= cart_download;
		reset <= reset_in | cart_download | old_cart_download | mapper_init_busy;
	end

	a78_cart_extent cart_extent (
		.clk(clk_sys), .cart_download, .ioctl_wr, .ioctl_addr, .ioctl_dout,
		.cart_is_7800(1'b0), .tia_mode(1'b0), .cart_size);

	wire  [5:0] force_bs;
	wire        sc;
	wire  [2:0] mapper_revision;
	wire        cdf_ldx, cdf_ldy, cdf_fetch_offset_enable;
	wire  [7:0] cdf_fetch_offset;
	wire [31:0] cdfj_entry, cdfj_stack;
	wire [15:0] arm_audio_size_addr;

	detect2600 detect (
		.clk(clk_sys),
		.load_start(~old_cart_download && cart_download),
		.load_addr(ioctl_addr), .load_valid(ioctl_wr & cart_download),
		.load_end(old_cart_download && ~cart_download),
		.cart_size, .data(ioctl_dout), .force_bs, .sc, .mapper_revision,
		.cdf_ldx, .cdf_ldy, .cdf_fetch_offset_enable, .cdf_fetch_offset,
		.cdfj_entry, .cdfj_stack, .arm_audio_size_addr);

	// Cartridge ROM on the 6507 side: a registered read, like the block RAM
	// image tb_system's 2600 mode runs from (the Pocket's SDRAM is slower).
	logic  [7:0] rom [0:(1<<19)-1];
	logic  [7:0] cart_q = 8'hFF;
	wire  [24:0] cart_addr;
	always @(posedge clk_sys) cart_q <= rom[cart_addr[18:0]];

	// ----------------------------------------------------- DDR3 stand-in
	// 64-bit words, fixed read latency, BURSTCNT beats, never busy.
	int lat = 20;
	wire [28:0] ddram_addr;
	wire  [7:0] ddram_burstcnt, ddram_be;
	wire [63:0] ddram_din;
	wire        ddram_rd, ddram_we;
	logic [63:0] ddram_dout = 0;
	logic        ddram_dout_ready = 0;
	logic [63:0] ddr [0:(1<<17)-1];
	int          ddr_left = 0, ddr_wait = 0;
	logic [16:0] ddr_a = 0;
	always @(posedge clk_arm) begin
		ddram_dout_ready <= 0;
		if (ddr_left != 0) begin
			if (ddr_wait != 0) ddr_wait <= ddr_wait - 1;
			else begin
				ddram_dout_ready <= 1;
				ddram_dout <= ddr[ddr_a];
				ddr_a <= ddr_a + 1;
				ddr_left <= ddr_left - 1;
			end
		end
		if (ddram_rd) begin
			ddr_a <= ddram_addr[16:0];
			ddr_left <= ddram_burstcnt;
			ddr_wait <= lat;
		end
		if (ddram_we) begin
			logic [63:0] w;
			w = ddr[ddram_addr[16:0]];
			for (int b = 0; b < 8; b++) if (ddram_be[b]) w[b*8 +: 8] = ddram_din[b*8 +: 8];
			ddr[ddram_addr[16:0]] = w;
		end
	end

	// ------------------------------------------------------- controls
	logic fire = 0, sw_reset = 0, sw_select = 0;
	logic [3:0] dirs = 0;          // {right, left, down, up}, 1 = pressed
	wire  [7:0] PBout;
	wire  [7:0] PAin = {~dirs, 4'hF};
	// Difficulty B/B, colour, as the Pocket wrapper presents them.
	wire  [7:0] PBin = {2'b00, PBout[5], PBout[4], 1'b1, PBout[2], ~sw_select, ~sw_reset};
	wire  [1:0] ilatch = {1'b1, ~fire};
	wire  [3:0] idump = 4'b1010;

	// ---------------------------------------------------------- the core
	wire  [7:0] R, G, B;
	wire        HSync, VSync, HBlank, VBlank, ce_pix;

	Atari7800 dut (
		.fw_hsc_load(1'b0), .fw_ar_load(1'b0), .fw_wr(1'b0), .fw_addr(12'd0), .fw_data(8'd0),
		.clk_sys, .reset, .pause(1'b0),
		.RED(R), .GREEN(G), .BLUE(B), .HSync, .VSync, .HBlank, .VBlank, .VBlank_orig(),
		.ce_pix, .PAL(1'b0), .pal_temp(2'd0), .hsc_en(1'b0), .hsc_ram_cs(),
		.hsc_ram_dout(8'd0), .dout(), .cpu_ce(), .AUDIO_R(), .AUDIO_L(),
		.show_border(1'b1), .show_overscan(1'b0), .bypass_bios(1'b1), .cart_present(1'b1),
		.tia_mode, .cpu_driver(1'b1),
		.cart_xm(8'd0), .cart_read(), .cart_out(cart_download ? ioctl_dout : cart_q),
		.bios_out(8'd0), .AB(), .cart_addr_out(cart_addr), .cart_flags(16'd0),
		.cart_mapper(8'd0), .cart_save(8'd0), .cart_size, .cart_din(), .RW(),
		.loading(cart_download || mapper_init_busy),
		.cartram_addr(), .cartram_wr(), .cartram_rd(), .cartram_wrdata(), .cartram_data(8'hFF),
		.clk_arm, .arm_reset,
		.mapper_load_start(~old_cart_download && cart_download),
		.mapper_load_addr(ioctl_addr), .mapper_load_valid(ioctl_wr && cart_download),
		.mapper_load_data(ioctl_dout), .mapper_load_end(old_cart_download && ~cart_download),
		.mapper_load_wait, .mapper_init_busy,
		.fa2_nvram_request(), .fa2_nvram_write(), .fa2_nvram_addr(), .fa2_nvram_wdata(),
		.fa2_nvram_rdata(8'hFF), .fa2_nvram_ready(1'b1), .fa2_nvram_dirty(),
		.ddram_clk(), .ddram_addr, .ddram_burstcnt, .ddram_busy(1'b0), .ddram_dout,
		.ddram_dout_ready, .ddram_rd, .ddram_din, .ddram_be, .ddram_we,
		.idump, .i_out(), .ilatch, .tia_stab(1'b0), .tia_f1(), .tia_pal(), .tia_en(),
		.PAin, .PBin, .PAout(), .PBout, .PAread(),
		.force_bs, .mapper_revision, .cdf_ldx, .cdf_ldy, .cdf_fetch_offset_enable,
		.cdf_fetch_offset, .cdfj_entry, .cdfj_stack, .arm_audio_size_addr, .sc,
		.clearval(8'd0), .random(8'd0), .tape_in(2'b00), .fix_sc_cs(1'b0), .tia_hsync(),
		.comp(), .comp_tog(), .comp_hs(), .comp_vs(), .comp_hb(), .comp_vb(),
		.comp_burst_start(), .comp_burst_len(),
		.use_stereo(1'b0), .ps2_key(11'd0), .pokey_irq(1'b0), .minnie_en(1'b1),
		.minnie_alt(1'b0), .decomb(1'b0), .mapper(6'd0), .pal_load(1'b0), .pal_addr(10'd0),
		.pal_wr(1'b0), .pal_data(8'd0), .blend(1'b0), .i_read()
	);

	// ------------------------------------------------------------- taps
	wire        a_retire  = dut.arm_host.arm_cpu.retire;
	wire [31:0] a_rpc     = dut.arm_host.arm_cpu.trace_retire_pc;
	wire [31:0] a_rins    = dut.arm_host.arm_cpu.trace_retire_instruction;
	wire        a_rthumb  = dut.arm_host.arm_cpu.trace_retire_thumb;
	wire        m_req     = dut.arm_mem_req;
	wire        m_rdy     = dut.arm_mem_ready;
	wire        m_fetch   = dut.arm_mem_fetch;
	wire        m_wr      = dut.arm_mem_write;
	wire [31:0] m_addr    = dut.arm_mem_addr;
	wire  [1:0] m_size    = dut.arm_mem_size;
	wire  [3:0] ctl_state = dut.cart2600.arm_mappers.call_controller.control_state;
	wire        ret_fetch = dut.cart2600.arm_mappers.memory.return_fetch;
	wire [31:0] rom_size  = dut.cart2600.arm_mappers.memory.rom_size;
	wire        call_req  = dut.cart2600.arm_call_request && dut.cart2600.arm_call_ready;
	wire        call_done = dut.cart2600.arm_call_done;
	wire        call_stall = dut.arm_call_stall;
	wire        dma_busy  = dut.arm_dma_busy;
	wire        vsync_raw = dut.tia_inst.vsync_o;
	// RIOT timer
	wire        r_ce      = dut.riot_inst.ce;
	wire        r_sel     = dut.riot_inst.CS1 && !dut.riot_inst.CS2_n && dut.riot_inst.RS_n &&
	                        dut.riot_inst.addr[2];
	wire        r_rw      = dut.riot_inst.RW_n;
	wire        r_a4      = dut.riot_inst.addr[4];
	wire        r_wrap    = dut.riot_inst.timer_wrap;
	wire        r_tick    = dut.riot_inst.tick_inc;
	wire  [7:0] r_timer   = dut.riot_inst.timer;
	localparam logic [3:0] CTRL_RUNNING = 4'd5;

	// +arm_div: arm_ce is the enable for the coming clk_arm edge. ce_last is
	// the one the core used at the previous edge: a registered output such as
	// retire holds through disabled edges and is new only after an enabled one.
	int   arm_div = 1;
	int   arm_ph = 0;
	logic arm_ce = 1;
	logic ce_last = 1;
	always @(posedge clk_arm) begin
		arm_ph <= (arm_ph + 1 >= arm_div) ? 0 : arm_ph + 1;
		arm_ce <= (arm_ph + 1 >= arm_div);
	end
	// Only while the call runs: the call controller's state writes and its
	// one-clock commit expect the CPU enabled on every edge.
	wire   arm_ce_run = (ctl_state == CTRL_RUNNING) ? arm_ce : 1'b1;

	// ---------------------------------------------------- Thumb formats
	typedef enum int {
		T1_SHIFT, T2_ADDSUB, T3_IMM8, T4_ALU, T4_SHIFTREG, T4_MUL, T5_HIREG, T5_BX,
		T6_LDRPC, T7_LDR_REG, T7_STR_REG, T8_LDRSX_REG, T8_STRH_REG, T9_LDR_IMM,
		T9_STR_IMM, T10_LDRH_IMM, T10_STRH_IMM, T11_LDR_SP, T11_STR_SP, T12_ADR,
		T13_ADDSP, T14_PUSH, T14_POP, T15_LDMIA, T15_STMIA, T16_BCOND, T17_SWI, T18_B,
		T19_BL_HI, T19_BL_LO, T_UNDEF,
		A_DP_IMM, A_DP_REG, A_DP_REGSHIFT, A_MUL, A_MUL_LONG, A_SWP, A_BX, A_PSR,
		A_LDR_STR, A_HALF_SIGNED, A_LDM_STM, A_B_BL, A_COPROC, A_SWI, K_N
	} kind_t;
	string kname [K_N] = '{
		"F1 shift by immediate (LSL/LSR/ASR #)", "F2 add/subtract (reg or imm3)",
		"F3 MOV/CMP/ADD/SUB #imm8", "F4 ALU register op (not shift/MUL)",
		"F4 shift by register (LSL/LSR/ASR/ROR Rs)", "F4 MUL", "F5 hi-register ADD/CMP/MOV",
		"F5 BX", "F6 LDR [PC,#]", "F7 LDR/LDRB [Rb,Ro]", "F7 STR/STRB [Rb,Ro]",
		"F8 LDRH/LDRSB/LDRSH [Rb,Ro]", "F8 STRH [Rb,Ro]", "F9 LDR/LDRB [Rb,#]",
		"F9 STR/STRB [Rb,#]", "F10 LDRH [Rb,#]", "F10 STRH [Rb,#]", "F11 LDR [SP,#]",
		"F11 STR [SP,#]", "F12 ADD Rd,PC/SP,#", "F13 ADD SP,#", "F14 PUSH", "F14 POP",
		"F15 LDMIA", "F15 STMIA", "F16 B<cond>", "F17 SWI", "F18 B", "F19 BL (high half)",
		"F19 BL (low half)", "undefined Thumb",
		"ARM data processing, immediate", "ARM data processing, register",
		"ARM data processing, shift by register", "ARM MUL/MLA", "ARM long multiply",
		"ARM SWP", "ARM BX", "ARM MRS/MSR", "ARM LDR/STR", "ARM LDRH/STRH/LDRSB/LDRSH",
		"ARM LDM/STM", "ARM B/BL", "ARM coprocessor", "ARM SWI"};

	function automatic kind_t thumb_kind(input logic [15:0] i);
		if (i[15:13] == 3'b000 && i[12:11] != 2'b11) return T1_SHIFT;
		if (i[15:11] == 5'b00011) return T2_ADDSUB;
		if (i[15:13] == 3'b001) return T3_IMM8;
		if (i[15:10] == 6'b010000) begin
			if (i[9:6] == 4'b1101) return T4_MUL;
			if (i[9:6] == 4'b0010 || i[9:6] == 4'b0011 || i[9:6] == 4'b0100 || i[9:6] == 4'b0111)
				return T4_SHIFTREG;
			return T4_ALU;
		end
		if (i[15:10] == 6'b010001) return (i[9:8] == 2'b11) ? T5_BX : T5_HIREG;
		if (i[15:11] == 5'b01001) return T6_LDRPC;
		if (i[15:12] == 4'b0101) begin
			if (!i[9]) return i[11] ? T7_LDR_REG : T7_STR_REG;
			return (i[11:10] == 2'b00) ? T8_STRH_REG : T8_LDRSX_REG;
		end
		if (i[15:13] == 3'b011) return i[11] ? T9_LDR_IMM : T9_STR_IMM;
		if (i[15:12] == 4'b1000) return i[11] ? T10_LDRH_IMM : T10_STRH_IMM;
		if (i[15:12] == 4'b1001) return i[11] ? T11_LDR_SP : T11_STR_SP;
		if (i[15:12] == 4'b1010) return T12_ADR;
		if (i[15:8] == 8'b10110000) return T13_ADDSP;
		if (i[15:12] == 4'b1011 && i[10:9] == 2'b10) return i[11] ? T14_POP : T14_PUSH;
		if (i[15:12] == 4'b1100) return i[11] ? T15_LDMIA : T15_STMIA;
		if (i[15:8] == 8'b11011111) return T17_SWI;
		if (i[15:12] == 4'b1101 && i[11:8] != 4'b1110) return T16_BCOND;
		if (i[15:11] == 5'b11100) return T18_B;
		if (i[15:11] == 5'b11110) return T19_BL_HI;
		if (i[15:11] == 5'b11111) return T19_BL_LO;
		return T_UNDEF;
	endfunction

	function automatic kind_t arm_kind(input logic [31:0] i);
		if ((i & 32'h0fc000f0) == 32'h00000090) return A_MUL;
		if ((i & 32'h0f8000f0) == 32'h00800090) return A_MUL_LONG;
		if ((i & 32'h0fb00ff0) == 32'h01000090) return A_SWP;
		if ((i & 32'h0ffffff0) == 32'h012fff10) return A_BX;
		if ((i & 32'h0e000090) == 32'h00000090) return A_HALF_SIGNED;
		if ((i & 32'h0fbf0fff) == 32'h010f0000 || (i & 32'h0db0f000) == 32'h0120f000) return A_PSR;
		case (i[27:25])
			3'b000: return (i[4] ? A_DP_REGSHIFT : A_DP_REG);
			3'b001: return A_DP_IMM;
			3'b010, 3'b011: return A_LDR_STR;
			3'b100: return A_LDM_STM;
			3'b101: return A_B_BL;
			3'b110: return A_COPROC;
			default: return i[24] ? A_SWI : A_COPROC;
		endcase
	endfunction

	// ARM7TDMI cycles with zero-wait memory (DDI 0210C, chapter 6), charged
	// on the instruction alone. A change of flow found at the next retire
	// adds the refill (2) to anything whose base does not already hold it.
	// MUL is taken as 1S+2I (m = 2): the multiplier's value is not traced.
	function automatic int base_cycles(input kind_t k, input logic [31:0] i);
		int n;
		case (k)
			T4_SHIFTREG, A_DP_REGSHIFT: return 2;
			T4_MUL, A_MUL: return 3;
			A_MUL_LONG: return 4;
			T6_LDRPC, T7_LDR_REG, T8_LDRSX_REG, T9_LDR_IMM, T10_LDRH_IMM, T11_LDR_SP: return 3;
			T7_STR_REG, T8_STRH_REG, T9_STR_IMM, T10_STRH_IMM, T11_STR_SP: return 2;
			T14_PUSH, T15_STMIA: begin n = $countones(i[7:0]) + (k == T14_PUSH ? i[8] : 0); return n + 1; end
			T14_POP, T15_LDMIA:  begin n = $countones(i[7:0]) + (k == T14_POP ? i[8] : 0); return n + 2; end
			T18_B, T19_BL_LO, T5_BX, T17_SWI, A_BX, A_B_BL, A_SWI: return 3;
			A_LDR_STR, A_HALF_SIGNED: return i[20] ? 3 : 2;
			A_LDM_STM: begin n = $countones(i[15:0]); return i[20] ? n + 2 : n + 1; end
			A_SWP: return 4;
			default: return 1;
		endcase
	endfunction
	function automatic bit refill_in_base(input kind_t k);
		return k == T18_B || k == T19_BL_LO || k == T5_BX || k == T17_SWI ||
			k == A_BX || k == A_B_BL || k == A_SWI;
	endfunction

	// DARIA estimate: a Thumb instruction costs what its ARM equivalent costs
	// on ARIA (docs/BUPCHIP_CORE.md, "Cycles per class"), with zero-wait
	// memory and no Thumb-specific penalty. S1: loads 2, register-offset
	// stores 2, MUL 2, shift by register 2, LDM n+2, STM n+1, the rest 1.
	// S3: loads, stores and MUL 1, shift by register 2, LDM/STM n, plus 1
	// when an LDM loads the PC (as S3's LDR pc). A BL is two instructions.
	function automatic int list_n(input kind_t k, input logic [31:0] i);
		int n;
		if (k == A_LDM_STM) n = $countones(i[15:0]);
		else n = $countones(i[7:0]) + ((k == T14_PUSH || k == T14_POP) ? int'(i[8]) : 0);
		return n == 0 ? 1 : n;
	endfunction
	function automatic int s1_cycles(input kind_t k, input logic [31:0] i);
		case (k)
			T4_SHIFTREG, A_DP_REGSHIFT, T4_MUL, A_MUL: return 2;
			A_MUL_LONG: return 3;
			T6_LDRPC, T7_LDR_REG, T8_LDRSX_REG, T9_LDR_IMM, T10_LDRH_IMM, T11_LDR_SP: return 2;
			T7_STR_REG, T8_STRH_REG: return 2;
			T14_POP, T15_LDMIA: return list_n(k, i) + 2;
			T14_PUSH, T15_STMIA: return list_n(k, i) + 1;
			A_LDR_STR: return (i[20] || i[25]) ? 2 : 1;
			A_HALF_SIGNED: return (i[20] || !i[22]) ? 2 : 1;
			A_LDM_STM: return list_n(k, i) + (i[20] ? 2 : 1);
			A_SWP: return 4;
			default: return 1;
		endcase
	endfunction
	function automatic int s3_cycles(input kind_t k, input logic [31:0] i);
		case (k)
			T4_SHIFTREG, A_DP_REGSHIFT: return 2;
			A_MUL_LONG: return 2;
			T14_POP: return list_n(k, i) + int'(i[8]);
			T14_PUSH, T15_STMIA, T15_LDMIA: return list_n(k, i);
			A_LDM_STM: return list_n(k, i) + int'(i[20] & i[15]);
			A_SWP: return 2;
			default: return 1;
		endcase
	endfunction

	// ----------------------------------------------------- cache models
	localparam int NCFG = 10;
	localparam int NSTR = 3;            // I, D, U
	int cfg_bytes [NCFG] = '{1024, 2048, 4096, 8192, 16384, 1024, 2048, 4096, 8192, 16384};
	int cfg_line  [NCFG] = '{16, 16, 16, 16, 16, 32, 32, 32, 32, 32};
	int unsigned ctag [NSTR][NCFG][1024];
	longint g_acc [NSTR];
	longint g_miss [NSTR][NCFG];
	longint c_acc [NSTR];
	longint c_miss [NSTR][NCFG];
	function automatic void cache_touch(input int s, input int unsigned a);
		c_acc[s]++;
		for (int k = 0; k < NCFG; k++) begin
			int unsigned ln;
			int idx;
			ln = a / cfg_line[k];
			idx = int'(ln % (cfg_bytes[k] / cfg_line[k]));
			if (ctag[s][k][idx] != ln) begin
				ctag[s][k][idx] = ln;
				c_miss[s][k]++;
			end
		end
	endfunction

	// ------------------------------------------------ per-call (clk_arm)
	typedef enum int {
		S_ARMCYC, S_THUMB, S_ARM, S_FREQ, S_FROM, S_FRAM, S_FOTHER, S_RD_ROM, S_RD_RAM,
		S_WR_RAM, S_RD_MMIO, S_WR_MMIO, S_RD_OTHER, S_WR_OTHER, S_TAKEN, S_EST,
		S_DPC, S_DL16, S_DL32, S_RD_ROM_B, S_RD_ROM_H, S_RD_ROM_W, S_S1, S_S3, S_N
	} stat_t;
	string sname [S_N] = '{"arm_cyc", "thumb", "arm", "fetch_req", "fetch_rom", "fetch_ram",
		"fetch_other", "rd_rom", "rd_ram", "wr_ram", "rd_mmio", "wr_mmio", "rd_other",
		"wr_other", "taken", "est_arm7", "dist_pc", "dist_l16", "dist_l32", "rd_rom_b",
		"rd_rom_h", "rd_rom_w", "s1_cyc", "s3_cyc"};
	longint cs [S_N];
	longint gs [S_N];
	longint kind_cnt [K_N];
	longint taken_by_kind [K_N];
	longint ram_rd_kib [32], ram_wr_kib [32];
	longint rom_rd_kib [512];
	longint pc_count [int unsigned];
	longint mmio_rd [int unsigned], mmio_wr [int unsigned];
	int     pc_stamp [0:262143];     // ROM PCs >> 1 (512 KiB)
	int     l16_stamp [0:32767], l32_stamp [0:16383];
	bit     g_l16 [0:32767], g_l32 [0:16383];
	int     call_id = 0;             // calls started
	int     dtrace = 0, fd_dt = 0;
	int     mmiolog = 0, fd_mm = 0;
	longint t_arm = 0;               // clk_arm edges since time 0
	longint unal_rd = 0, unal_wr = 0;
	int     unal_n = 0;
	logic [31:0] unal_addr [16], unal_pc [16];
	logic  [1:0] unal_size [16];
	logic        unal_wr_ex [16];
	logic   in_call = 0;
	logic   prev_valid = 0;
	logic [31:0] prev_pc;
	int     prev_size;
	kind_t  prev_kind;
	logic [31:0] first_bl = 0;
	longint max_call_thumb = 0;
	// Results of the last finished call, handed to the clk_sys side.
	longint done_cs [S_N];
	longint done_miss [NSTR][NCFG];
	longint done_acc [NSTR];
	logic [31:0] done_bl;
	int     done_id = 0;

	function automatic void close_prev(input logic [31:0] next_pc, input bit flow);
		if (!prev_valid) return;
		if (flow) begin
			cs[S_TAKEN]++;
			taken_by_kind[prev_kind]++;
			if (!refill_in_base(prev_kind)) cs[S_EST] += 2;
		end
	endfunction

	always @(posedge clk_arm) begin
		// call boundaries
		if (!in_call && ctl_state == CTRL_RUNNING) begin
			in_call = 1;
			call_id++;
			foreach (cs[s]) cs[s] = 0;
			for (int s = 0; s < NSTR; s++) begin
				c_acc[s] = 0;
				for (int k = 0; k < NCFG; k++) c_miss[s][k] = 0;
			end
			prev_valid = 0;
			first_bl = 0;
			if (dtrace != 0) $fwrite(fd_dt, "c %0d %0d\n", call_id, frame);
		end
		t_arm++;
		if (in_call) cs[S_ARMCYC]++;

		if (a_retire && in_call && ce_last) begin
			kind_t k;
			int sz;
			bit flow;
			sz = a_rthumb ? 2 : 4;
			k = a_rthumb ? thumb_kind(a_rins[15:0]) : arm_kind(a_rins);
			flow = prev_valid && (a_rpc != prev_pc + prev_size);
			close_prev(a_rpc, flow);
			if (prev_valid && prev_kind == T19_BL_LO && first_bl == 0 && flow) first_bl = a_rpc;
			kind_cnt[k]++;
			if (a_rthumb) cs[S_THUMB]++; else cs[S_ARM]++;
			cs[S_EST] += base_cycles(k, a_rins);
			cs[S_S1] += s1_cycles(k, a_rins);
			cs[S_S3] += s3_cycles(k, a_rins);
			if (pc_count.exists(a_rpc)) pc_count[a_rpc]++; else pc_count[a_rpc] = 1;
			if (a_rpc < rom_size) begin
				int ix;
				ix = int'(a_rpc[18:1]);
				if (pc_stamp[ix] != call_id) begin pc_stamp[ix] = call_id; cs[S_DPC]++; end
				ix = int'(a_rpc[18:4]);
				if (l16_stamp[ix] != call_id) begin l16_stamp[ix] = call_id; cs[S_DL16]++; end
				g_l16[ix] = 1;
				ix = int'(a_rpc[18:5]);
				if (l32_stamp[ix] != call_id) begin l32_stamp[ix] = call_id; cs[S_DL32]++; end
				g_l32[ix] = 1;
				cache_touch(0, a_rpc);
				cache_touch(2, a_rpc);
			end
			prev_valid = 1;
			prev_pc = a_rpc;
			prev_size = sz;
			prev_kind = k;
		end

		if (m_req && m_rdy && in_call && arm_ce_run) begin
			bit is_rom, is_ram, is_mmio;
			is_rom  = m_addr < rom_size;
			is_ram  = m_addr[31:28] == 4'h4;
			is_mmio = m_addr[31:28] == 4'hE;
			if (!m_fetch && ((m_size == 2'd1 && m_addr[0]) || (m_size == 2'd2 && m_addr[1:0] != 2'd0))) begin
				if (m_wr) unal_wr++; else unal_rd++;
				if (unal_n < 16) begin
					unal_addr[unal_n] = m_addr;
					unal_size[unal_n] = m_size;
					unal_wr_ex[unal_n] = m_wr;
					unal_pc[unal_n] = prev_pc;
					unal_n++;
				end
			end
			if (m_fetch) begin
				cs[S_FREQ]++;
				if (is_rom) cs[S_FROM]++; else if (is_ram) cs[S_FRAM]++; else cs[S_FOTHER]++;
			end else if (m_wr) begin
				if (is_ram) begin cs[S_WR_RAM]++; ram_wr_kib[m_addr[14:10]]++; end
				else if (is_mmio) begin
					cs[S_WR_MMIO]++;
					if (mmiolog != 0) $fwrite(fd_mm, "%0d,%0d,%0d,%0d,%0d,w,%08x,%08x,%0d\n", call_id, frame,
						cs[S_THUMB] + cs[S_ARM], cs[S_ARMCYC], t_arm, m_addr, dut.arm_mem_wdata, m_size);
					if (mmio_wr.exists(m_addr)) mmio_wr[m_addr]++; else mmio_wr[m_addr] = 1;
				end else cs[S_WR_OTHER]++;
			end else begin
				if (is_rom) begin
					cs[S_RD_ROM]++;
					rom_rd_kib[m_addr[18:10]]++;
					if (m_size == 2'd0) cs[S_RD_ROM_B]++;
					else if (m_size == 2'd1) cs[S_RD_ROM_H]++;
					else cs[S_RD_ROM_W]++;
					cache_touch(1, m_addr);
					cache_touch(2, m_addr);
					if (dtrace != 0) $fwrite(fd_dt, "%0x\n", {6'd0, m_size, m_addr[23:0]});
				end else if (is_ram) begin cs[S_RD_RAM]++; ram_rd_kib[m_addr[14:10]]++; end
				else if (is_mmio) begin
					cs[S_RD_MMIO]++;
					if (mmiolog != 0) $fwrite(fd_mm, "%0d,%0d,%0d,%0d,%0d,r,%08x,%08x,%0d\n", call_id, frame,
						cs[S_THUMB] + cs[S_ARM], cs[S_ARMCYC], t_arm, m_addr, dut.arm_mem_rdata, m_size);
					if (mmio_rd.exists(m_addr)) mmio_rd[m_addr]++; else mmio_rd[m_addr] = 1;
				end else cs[S_RD_OTHER]++;
			end
		end

		if (in_call && ret_fetch) begin
			// The return's own flow change (BX lr / POP {pc} to the sentinel).
			close_prev(32'hF0000000, 1'b1);
			in_call = 0;
			foreach (cs[s]) begin done_cs[s] = cs[s]; gs[s] += cs[s]; end
			for (int s = 0; s < NSTR; s++) begin
				done_acc[s] = c_acc[s];
				g_acc[s] += c_acc[s];
				for (int k = 0; k < NCFG; k++) begin
					done_miss[s][k] = c_miss[s][k];
					g_miss[s][k] += c_miss[s][k];
				end
			end
			done_bl = first_bl;
			done_id = call_id;
		end
		ce_last = arm_ce_run;
	end

	// ----------------------------------------- system side (clk_sys)
	longint now = 0;
	longint t_vs = 0;               // last VSYNC rise
	int     frame = 0;              // frames since reset release
	logic   old_vs = 0;
	logic   running = 0;
	int     fd_calls, fd_slack, fd_frames, fd_zero;
	// call in progress (6507 side)
	logic   sys_call = 0;
	longint t_req = 0, stall = 0;
	int     req_frame, req_line;
	int     sys_calls = 0;
	// per-frame
	int     f_calls = 0;
	longint f_instr = 0, f_armcyc = 0, f_stall = 0, f_dma = 0, f_max_instr = 0;
	longint dma_cycles = 0, dma_events = 0;
	logic   old_dma = 0;
	// RIOT timer
	longint t_timer_write = -1, t_expire = -1;
	logic   expired = 0;
	logic   await_poll = 0, pending_slack = 0;
	int     poll_call;
	longint poll_req_t, poll_done_t, t_poll;
	int     overruns = 0;
	longint worst_slack = 64'sh7fffffffffffffff;
	// INTIM reads 0 from the tick that takes the counter from 1 to 0 (the
	// read is one ahead, M6532.sv:162-167) until the wrap one interval later.
	longint t_zero = -1, zero_poll_t = 0;
	logic   zeroed = 0, pending_zero = 0;
	int     zero_call;
	// 6507 PC of the instruction now running: the address of its opcode
	// fetch (SYNC), held through the instruction's later cycles.
	wire        c_sync    = dut.cpu_inst.cpu.sync;
	logic [15:0] op_pc = 0, poll_pc = 0;
	always @(posedge clk_sys) if (c_sync) op_pc <= dut.cpu_AB;

	always @(posedge clk_sys) begin
		now++;
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

			// ---- ARM calls as the 6507 sees them
			if (call_req && !sys_call) begin
				sys_call = 1;
				t_req = now;
				stall = 0;
				req_frame = frame;
				req_line = int'((now - t_vs) / SYS_PER_LINE);
				if (pending_slack) begin
					// The timer never expired before the next call: leave it unresolved.
					$fwrite(fd_slack, "%0d,2,%0d,0,%04x\n", poll_call, poll_done_t, poll_pc);
					pending_slack = 0;
				end
				await_poll = 0;
				pending_zero = 0;
			end
			if (sys_call && call_stall) stall++;
			if (sys_call && call_done) begin
				sys_call = 0;
				sys_calls++;
				$fwrite(fd_calls, "%0d,%0d,%0d,%0d,%0d,%0d,%08x", done_id, req_frame, req_line,
					t_req, now - t_req, stall, done_bl);
				foreach (done_cs[s]) $fwrite(fd_calls, ",%0d", done_cs[s]);
				for (int s = 0; s < NSTR; s++) begin
					$fwrite(fd_calls, ",%0d", done_acc[s]);
					for (int k = 0; k < NCFG; k++) $fwrite(fd_calls, ",%0d", done_miss[s][k]);
				end
				$fwrite(fd_calls, "\n");
				f_calls++;
				f_instr += done_cs[S_THUMB] + done_cs[S_ARM];
				f_armcyc += done_cs[S_ARMCYC];
				f_stall += stall;
				if (done_cs[S_THUMB] + done_cs[S_ARM] > f_max_instr)
					f_max_instr = done_cs[S_THUMB] + done_cs[S_ARM];
				await_poll = 1;
				poll_call = done_id;
				poll_req_t = t_req;
				poll_done_t = now;
			end
			// mapper DMA (DPC+ copy/fill functions) also holds the 6507
			if (dma_busy && !mapper_init_busy) begin dma_cycles++; f_dma++; end
			if (dma_busy && !old_dma && !mapper_init_busy) dma_events++;
			old_dma <= dma_busy;

			// ---- frames: the raw VSYNC bit's rising edge
			old_vs <= vsync_raw;
			if (vsync_raw && !old_vs) begin
				if (frame > 0)
					$fwrite(fd_frames, "%0d,%0d,%0d,%.2f,%0d,%0d,%0d,%0d,%0d,%0d\n", frame, t_vs,
						now - t_vs, real'(now - t_vs) / SYS_PER_LINE, f_calls, f_instr, f_armcyc,
						f_stall, f_dma, f_max_instr);
				frame++;
				t_vs = now;
				f_calls = 0; f_instr = 0; f_armcyc = 0; f_stall = 0; f_dma = 0; f_max_instr = 0;
			end
		end
	end

	// ------------------------------------------------- input script
	int fire_at = 420, reset_at = 0, select_at = 0, play_at = 480, seed = 1;
	logic [15:0] lfsr = 16'hACE1;
	int last_frame_seen = -1;
	always @(posedge clk_sys) if (running && frame != last_frame_seen) begin
		last_frame_seen = frame;
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
	end

	// ------------------------------------------------------ snapshots
	int snap_every = 150;
	string out;
	logic [23:0] pic [0:319][0:639];
	int px = 0, py = 0, maxx = 0;
	logic line_px = 0, old_hb = 1, old_vsv = 0;
	always @(posedge clk_sys) if (running && snap_every != 0) begin
		old_hb <= HBlank;
		old_vsv <= VSync;
		if (ce_pix && !HBlank && !VBlank) begin
			if (px < 640 && py < 320) pic[py][px] <= {R, G, B};
			px <= px + 1;
			line_px <= 1;
		end
		if (!old_hb && HBlank) begin
			if (line_px) py <= py + 1;
			if (px > maxx) maxx <= px;
			px <= 0;
			line_px <= 0;
		end
		if (!old_vsv && VSync) begin
			if (frame % snap_every == 0 && py > 0) begin
				int fd;
				fd = $fopen($sformatf("%ssnap_%05d.ppm", out, frame), "wb");
				$fwrite(fd, "P6\n%0d %0d\n255\n", maxx > 640 ? 640 : maxx, py > 320 ? 320 : py);
				for (int y = 0; y < py && y < 320; y++)
					for (int x = 0; x < maxx && x < 640; x++)
						$fwrite(fd, "%c%c%c", pic[y][x][23:16], pic[y][x][15:8], pic[y][x][7:0]);
				$fclose(fd);
			end
			py <= 0;
			maxx <= 0;
		end
	end

	// ------------------------------------------------------------- run
	logic [7:0] img [0:(1<<19)-1];
	initial begin
		string romfile;
		int fd, n, frames;
		real secs;
		if (!$value$plusargs("rom=%s", romfile)) begin $display("need +rom=FILE"); $finish; end
		if (!$value$plusargs("out=%s", out)) out = "./";
		if (!$value$plusargs("frames=%d", frames)) frames = 1500;
		void'($value$plusargs("fire_at=%d", fire_at));
		void'($value$plusargs("reset_at=%d", reset_at));
		void'($value$plusargs("select_at=%d", select_at));
		void'($value$plusargs("play_at=%d", play_at));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("lat=%d", lat));
		void'($value$plusargs("snap=%d", snap_every));
		void'($value$plusargs("arm_div=%d", arm_div));
		void'($value$plusargs("dtrace=%d", dtrace));
		void'($value$plusargs("mmiolog=%d", mmiolog));
		if (arm_div > 1) begin
			force dut.arm_host.ce = arm_ce_run;
			force dut.cart2600.mem_ce = arm_ce_run;
		end
		lfsr = 16'(seed * 40503 + 1);
		foreach (rom[i]) rom[i] = 8'hFF;
		foreach (ddr[i]) ddr[i] = 64'd0;
		foreach (pc_stamp[i]) pc_stamp[i] = 0;
		foreach (l16_stamp[i]) l16_stamp[i] = 0;
		foreach (l32_stamp[i]) l32_stamp[i] = 0;
		foreach (g_l16[i]) g_l16[i] = 0;
		foreach (g_l32[i]) g_l32[i] = 0;
		for (int s = 0; s < NSTR; s++) begin
			g_acc[s] = 0;
			for (int k = 0; k < NCFG; k++) begin
				g_miss[s][k] = 0;
				for (int j = 0; j < 1024; j++) ctag[s][k][j] = 32'hFFFFFFFF;
			end
		end
		foreach (gs[s]) gs[s] = 0;
		foreach (kind_cnt[k]) begin kind_cnt[k] = 0; taken_by_kind[k] = 0; end
		foreach (ram_rd_kib[i]) begin ram_rd_kib[i] = 0; ram_wr_kib[i] = 0; end
		foreach (rom_rd_kib[i]) rom_rd_kib[i] = 0;

		fd = $fopen(romfile, "rb");
		if (fd == 0) begin $display("cannot open %s", romfile); $finish; end
		n = $fread(img, fd);
		$fclose(fd);
		for (int i = 0; i < n; i++) rom[i] = img[i];
		$display("ROM %s: %0d bytes", romfile, n);

		fd_calls = $fopen({out, "calls.csv"}, "w");
		$fwrite(fd_calls, "call,frame,line,t_req_sys,busy_sys,stall_sys,first_bl");
		foreach (sname[s]) $fwrite(fd_calls, ",%s", sname[s]);
		for (int s = 0; s < NSTR; s++) begin
			$fwrite(fd_calls, ",acc_%s", s == 0 ? "I" : s == 1 ? "D" : "U");
			for (int k = 0; k < NCFG; k++)
				$fwrite(fd_calls, ",miss_%s_%0dk_%0d", s == 0 ? "I" : s == 1 ? "D" : "U",
					cfg_bytes[k] / 1024, cfg_line[k]);
		end
		$fwrite(fd_calls, "\n");
		fd_slack = $fopen({out, "slack.csv"}, "w");
		$fwrite(fd_slack, "call,kind,sys_end_to_poll,slack_sys,poll_pc\n");
		fd_zero = $fopen({out, "zero.csv"}, "w");
		$fwrite(fd_zero, "call,slack_zero_sys\n");
		fd_frames = $fopen({out, "frames.csv"}, "w");
		if (dtrace != 0) fd_dt = $fopen({out, "dtrace.txt"}, "w");
		if (mmiolog != 0) begin
			fd_mm = $fopen({out, "mmio.csv"}, "w");
			$fwrite(fd_mm, "call,frame,call_instr,call_arm_cyc,t_arm,rw,addr,data,size\n");
		end
		$fwrite(fd_frames, "frame,t_sys,len_sys,lines,calls,instr,arm_cyc,stall_sys,dma_sys,max_call_instr\n");

		// Power-up, then the download as the MiSTer loader streams it, paced
		// by the ARM mapper's load_wait (MiSTer's ioctl_wait).
		repeat (50) @(posedge clk_sys);
		arm_reset = 0;
		repeat (50) @(posedge clk_sys);
		cart_download = 1;
		for (int i = 0; i < n; i++) begin
			@(posedge clk_sys);
			while (mapper_load_wait) @(posedge clk_sys);
			ioctl_addr <= 25'(i);
			ioctl_dout <= img[i];
			ioctl_wr <= 1;
			@(posedge clk_sys) ioctl_wr <= 0;
		end
		repeat (4) @(posedge clk_sys);
		cart_download = 0;
		tia_mode = 1;
		repeat (4) @(posedge clk_sys);
		$display("detect2600: force_bs %0d revision %0d ldx %0d ldy %0d fetch_offset %0d/%0d entry %08x stack %08x audio %04x size %0d",
			force_bs, mapper_revision, cdf_ldx, cdf_ldy, cdf_fetch_offset_enable, cdf_fetch_offset,
			cdfj_entry, cdfj_stack, arm_audio_size_addr, cart_size);
		repeat (20) @(posedge clk_sys);
		reset_in = 0;
		while (reset) @(posedge clk_sys);
		$display("reset released at %0d clk_sys (mapper init done)", now);
		running = 1;
		while (frame < frames) @(posedge clk_sys);
		running = 0;
		secs = real'(now) / SYS_HZ;
		$display("ran %0d frames, %0d calls", frame, sys_calls);
		write_summary();
		$fclose(fd_calls);
		$fclose(fd_slack);
		$fclose(fd_frames);
		$fclose(fd_zero);
		if (dtrace != 0) $fclose(fd_dt);
		if (mmiolog != 0) $fclose(fd_mm);
		$finish;
	end

	task automatic write_summary();
		int fd;
		longint tot, l16, l32;
		fd = $fopen({out, "summary.txt"}, "w");
		$fwrite(fd, "scheme force_bs %0d revision %0d cart_size %0d rom_size %0d\n",
			force_bs, mapper_revision, cart_size, rom_size);
		$fwrite(fd, "frames %0d calls %0d dma_events %0d dma_sys %0d timer_overruns %0d worst_slack_sys %0d\n",
			frame, sys_calls, dma_events, dma_cycles, overruns, worst_slack);
		foreach (gs[s]) $fwrite(fd, "total %s %0d\n", sname[s], gs[s]);
		tot = gs[S_THUMB] + gs[S_ARM];
		foreach (kind_cnt[k]) if (kind_cnt[k] != 0)
			$fwrite(fd, "kind %0d %0d %0d %s\n", k, kind_cnt[k], taken_by_kind[k], kname[k]);
		l16 = 0; l32 = 0;
		foreach (g_l16[i]) l16 += g_l16[i];
		foreach (g_l32[i]) l32 += g_l32[i];
		$fwrite(fd, "distinct_pc %0d distinct_l16 %0d distinct_l32 %0d\n", pc_count.size(), l16, l32);
		for (int s = 0; s < NSTR; s++) begin
			$fwrite(fd, "cache %s acc %0d", s == 0 ? "I" : s == 1 ? "D" : "U", g_acc[s]);
			for (int k = 0; k < NCFG; k++)
				$fwrite(fd, " %0dk/%0d:%0d", cfg_bytes[k] / 1024, cfg_line[k], g_miss[s][k]);
			$fwrite(fd, "\n");
		end
		foreach (ram_rd_kib[i]) if (ram_rd_kib[i] != 0 || ram_wr_kib[i] != 0)
			$fwrite(fd, "ram_kib %0d rd %0d wr %0d\n", i, ram_rd_kib[i], ram_wr_kib[i]);
		foreach (rom_rd_kib[i]) if (rom_rd_kib[i] != 0)
			$fwrite(fd, "rom_rd_kib %0d %0d\n", i, rom_rd_kib[i]);
		foreach (mmio_rd[a]) $fwrite(fd, "mmio_rd %08x %0d\n", a, mmio_rd[a]);
		foreach (mmio_wr[a]) $fwrite(fd, "mmio_wr %08x %0d\n", a, mmio_wr[a]);
		$fwrite(fd, "unaligned rd %0d wr %0d\n", unal_rd, unal_wr);
		for (int u = 0; u < unal_n; u++)
			$fwrite(fd, "unaligned_ex %08x size %0d %s after_pc %08x\n", unal_addr[u],
				unal_size[u], unal_wr_ex[u] ? "wr" : "rd", unal_pc[u]);
		$fclose(fd);
		fd = $fopen({out, "pcs.txt"}, "w");
		foreach (pc_count[a]) $fwrite(fd, "%08x %0d\n", a, pc_count[a]);
		$fclose(fd);
	endtask
endmodule
