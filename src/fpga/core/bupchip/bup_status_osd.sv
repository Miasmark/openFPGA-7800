//------------------------------------------------------------------------------
// BupChip status on screen, for BUP_DEBUG builds only (docs/BUPCHIP_CORE.md,
// "Macros and parameters"; the hardware test in step 5 reads it).
//
// While a Souper cartridge is loaded (en = souper_profile), the top-left
// 96 x 104 pixels of the picture are replaced by thirteen rows of twelve
// cells, each an 8 x 8 pixel cell with a 6 x 6 box on black. A lit box is a
// 1 bit, a grey box a 0 bit; the grey alternates in shade between groups of
// four cells, so binary values read in nibbles, most significant bit on the
// left.
//
//   row 0  flags   green: firmware loaded, ARSC block ready, CPU running
//                  (a gap)
//                  red:   halted, command overflow, PCM overflow,
//                         PCM underflow, muted (FAULT write), and the
//                         capture's seq_err and lost, the receiver's overrun
//   row 1  yellow: halt code (4 bits); orange: firmware fault code (8 bits)
//   row 2  cyan:   lowest PCM FIFO level since the boot's prefill (11 bits,
//                  from the second cell)
//   row 3  white:  halt PC, as the word address within the ROM (PC[13:2])
//   row 4  green:  firmware words written into the ROM since FWSTART
//   row 5  green:  their CRC-32 is bupchip.bin's, they came in order
//                  (a gap); magenta: foreign bytes (8 bits)
//   row 6  magenta: cartridge bytes taken late (6 bits), firmware bytes
//                  taken late (6 bits)
//   row 7  red:    bytes dropped outside the windows
//   row 8  blue:   clk_sys from the last byte to the firmware flag rising
//   row 9  blue:   clk_sys from the firmware flag falling to its last byte
//   row 10 blue:   the same for the cartridge, from load_end
//   row 11 blue:   fewest clk_sys between two words of bupchip.bin
//   row 12 red:    the first byte that set seq_err: bits 27:25 of its
//                  bridge address, then 8:0
//
// Rows 5-12 are bup_load_probe.sv's (its header has the details) and
// bupchip_pocket.sv's firmware check. A good run shows the three green
// flags, no red anywhere, rows 1 and 3 all grey, row 4 the firmware's words
// (1,956 for the 7,824-byte bupchip.bin: 0111 1010 0100) and both green
// boxes in row 5; row 2 holds the lowest level (simulation: 600 or more on
// every song). Row 0's shadow flags (the overflows and underflow) clear
// when the BupChip is next held (a cartridge load, a PAL/NTSC retune); the
// capture's flags and the probe's counts are kept from power-up.
//
// While a 2600 ARM cartridge runs on DARIA (daria = daria_profile, in
// POCKET_DARIA builds; docs/IMPROVEMENTS.md, "The step-8 DARIA status
// overlay"), the cells show DARIA's status instead, in six rows (48 lines),
// nine while the CPU is halted:
//
//   row 0  green:  CPU running, the front end's guard locked
//                  (a gap)
//                  red:   halted, the capture's seq_err and lost, the
//                         receiver's overrun
//   row 1  yellow: halt code (4 bits); orange: fault code (8 bits; always 0
//                  here, as the BupChip's peripheral is held in the 2600
//                  profile)
//   row 2  red:     late calls (12 bits, saturating at 4,095)
//   row 3  magenta: guard unlocks since power-up (12 bits, saturating)
//   row 4  blue:   calls, bits 23:12
//   row 5  blue:   calls, bits 11:0
//   row 6  white:  halt PC, bits 31:24 (the last eight cells)
//   row 7  white:  halt PC, bits 23:12
//   row 8  white:  halt PC, bits 11:0 (rows 6-8 only while halted)
//
// The counts come from daria_dbg_status, at the end of this file (dstat,
// clk_sys registers; its header gives the rules): calls and late calls since
// the console's last reset, unlocks since power-up. The halt PC is the byte
// address, so rows 6-8 read as eight hex digits. The DARIA rows exist only
// under BUP_DEBUG, so a build without it preprocesses this file to the same
// stream as before, comments dropped (pp_equiv.py; docs/daria_step7/plan.md
// 7.6).
//
// The status comes from clk_arm and clk_sys registers and is sampled here on
// clk_sys. Without POCKET_DARIA clk_arm is 2 x clk_sys from the same VCO, so
// the clk_arm bits are timed paths. With it clk_arm is VCO/18, and
// bupchip_pocket.sv passes its clk_arm bits through bup_dbg_snap.sv, a
// snapshot taken every 1,024 clk_sys, so every bit arrives here from a clk_sys
// register (open item 11, docs/DARIA_CORE.md). Display only; nothing else
// depends on it.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_status_osd (
	input  wire        clk,         // clk_sys
	input  wire        en,          // souper_profile
	input  wire [31:0] status,      // bupchip_pocket dbg_status (clk_arm; clk_sys with POCKET_DARIA)
	input  wire [31:0] halt_pc,     // bupchip_pocket dbg_halt_pc (likewise)
	input  wire [110:0] load,       // bupchip_pocket dbg_load (clk_sys and clk_arm; clk_sys with POCKET_DARIA)
`ifdef BUP_DEBUG
	input  wire        daria,       // daria_profile: DARIA's rows (0 without POCKET_DARIA)
	input  wire [48:0] dstat,       // {guard locked, late calls 12, unlocks 12, calls 24} (clk_sys)
`endif

	input  wire        ce_pix,
	input  wire        hblank,
	input  wire        vblank,
	input  wire  [7:0] r_in,
	input  wire  [7:0] g_in,
	input  wire  [7:0] b_in,
	output wire  [7:0] r_out,
	output wire  [7:0] g_out,
	output wire  [7:0] b_out
);
	logic [31:0]  st = 32'd0;
	logic [11:0]  pc = 12'd0;
	logic [110:0] ld = '0;
	always_ff @(posedge clk) begin
		st <= status;
		pc <= halt_pc[13:2];
		ld <= load;
	end
`ifdef BUP_DEBUG
	/* verilator lint_off PROCASSINIT */
	logic        dar = 1'b0;
	logic [48:0] ds = '0;
	logic [31:0] hpc = 32'd0;
	/* verilator lint_on PROCASSINIT */
	always_ff @(posedge clk) begin
		dar <= daria;
		ds <= dstat;
		hpc <= halt_pc;
	end
	// DARIA's rows: six, nine while halted (the halt PC's three)
	wire [6:0] d_lines = st[28] ? 7'd72 : 7'd48;
`endif

	// Pixel within the active line and active line within the frame,
	// saturating past the overlay.
	logic [6:0] xc = 7'd0;
	logic [6:0] yc = 7'd0;
	logic       hb_q = 1'b1;
	always_ff @(posedge clk) begin
		hb_q <= hblank;
		if (hblank)
			xc <= 7'd0;
		else if (ce_pix && !vblank && xc != 7'd127)
			xc <= xc + 7'd1;
		if (vblank)
			yc <= 7'd0;
		else if (hblank && !hb_q && yc != 7'd127)
			yc <= yc + 7'd1;
	end

	wire [3:0] col = xc[6:3];          // 0..11 inside the overlay
	wire [3:0] row = yc[6:3];          // 0..12
`ifdef BUP_DEBUG
	wire       in_osd = (dar ? yc < d_lines : en && yc < 7'd104) && !hblank && !vblank && xc < 7'd96;
`else
	wire       in_osd = en && !hblank && !vblank && xc < 7'd96 && yc < 7'd104;
`endif
	wire       in_box = xc[2:0] != 3'd0 && xc[2:0] != 3'd7 && yc[2:0] != 3'd0 && yc[2:0] != 3'd7;

	// Each row: its bits (column 0 = bit 11), which cells are drawn, and
	// the lit colour.
	logic [11:0] bits, shown;
	logic [23:0] on_rgb;
	always_comb begin
		shown = 12'hFFF;
		on_rgb = 24'h40A0FF;
`ifdef BUP_DEBUG
		if (dar) begin
			case (row)
				4'd0: begin
					bits  = {st[31], ds[48], 1'b0, st[28], ld[110:108], 5'd0};
					shown = 12'b1101_1110_0000;
					on_rgb = col < 4'd2 ? 24'h00E000 : 24'hFF2020;
				end
				4'd1: begin
					bits  = {st[27:24], st[19:12]};
					on_rgb = col < 4'd4 ? 24'hFFE000 : 24'hFF8000;
				end
				4'd2: begin
					bits  = ds[47:36];
					on_rgb = 24'hFF2020;
				end
				4'd3: begin
					bits  = ds[35:24];
					on_rgb = 24'hFF40FF;
				end
				4'd4: bits = ds[23:12];
				4'd5: bits = ds[11:0];
				4'd6: begin
					bits  = {4'd0, hpc[31:24]};
					shown = 12'h0FF;
					on_rgb = 24'hFFFFFF;
				end
				4'd7: begin
					bits  = hpc[23:12];
					on_rgb = 24'hFFFFFF;
				end
				default: begin
					bits  = hpc[11:0];
					on_rgb = 24'hFFFFFF;
				end
			endcase
		end else
`endif
		case (row)
			4'd0: begin
				bits  = {st[30], st[29], st[31], 1'b0, st[28], st[23], st[22], st[21], st[20], ld[110:108]};
				shown = 12'b1110_1111_1111;
				on_rgb = col < 4'd3 ? 24'h00E000 : 24'hFF2020;
			end
			4'd1: begin
				bits  = {st[27:24], st[19:12]};
				on_rgb = col < 4'd4 ? 24'hFFE000 : 24'hFF8000;
			end
			4'd2: begin
				bits  = {1'b0, st[10:0]};
				shown = 12'h7FF;
				on_rgb = 24'h00E0FF;
			end
			4'd3: begin
				bits  = pc;
				on_rgb = 24'hFFFFFF;
			end
			4'd4: begin
				bits  = ld[11:0];
				on_rgb = 24'h00E000;
			end
			4'd5: begin
				bits  = ld[23:12];
				shown = 12'b1100_1111_1111;
				on_rgb = col < 4'd2 ? 24'h00E000 : 24'hFF40FF;
			end
			4'd6: begin
				bits  = ld[35:24];
				on_rgb = 24'hFF40FF;
			end
			4'd7: begin
				bits  = ld[47:36];
				on_rgb = 24'hFF2020;
			end
			4'd8:  bits = ld[59:48];
			4'd9:  bits = ld[71:60];
			4'd10: bits = ld[83:72];
			4'd11: bits = ld[95:84];
			default: begin
				bits  = ld[107:96];
				on_rgb = 24'hFF2020;
			end
		endcase
	end
	wire bit_on   = bits[4'd11 - col];
	wire bit_show = shown[4'd11 - col];

	wire [23:0] off_rgb = col[2] ? 24'h585858 : 24'h303030;
	wire [23:0] osd_rgb = (in_box && bit_show) ? (bit_on ? on_rgb : off_rgb) : 24'h000000;

	assign {r_out, g_out, b_out} = in_osd ? osd_rgb : {r_in, g_in, b_in};
endmodule

`ifdef BUP_DEBUG
`ifdef POCKET_DARIA
//------------------------------------------------------------------------------
// daria_dbg_status: DARIA's counts for the overlay above (dstat). Hardware
// test builds of the DARIA core only (BUP_DEBUG and POCKET_DARIA);
// atari7800_pocket.sv instantiates it as u_dstat. All clk_sys, from clk_sys
// registers and top.sv's bus; nothing else reads them.
//
// Calls (24 bits): flips of daria_fe's call_tog, one per call posted (plan
// P22), since the console's last reset (rst: top.sv's effective_reset, which
// is also the RIOT's reset).
//
// Late calls (12 bits, saturating at 4,095), since the same reset. The rule
// is tb_frames' (sim/tb_frames.sv, slack.csv: kind 1 with slack <= 0;
// tb_daria's "RIOT timer events"): a call is late when, at the 6507's first
// read of the RIOT timer (INTIM or TIMINT) after the call's hold
// (arm_call_busy) ends, the timer it wrote before the call has wrapped past
// zero since. The game then finds its timer expired, and its frame runs long:
// Spiders' frames 557-572 with 2.2.1's CPU, 16 calls. Sampling the timer when the
// call ends would count 0 there, as the timer runs out later (plan 6.2
// question 5), so the rule needs the timer's wrap at the read. top.sv exports
// no RIOT signal, so t_* below is a copy of the RIOT's timer
// (mister/rtl/RIOT/M6532.sv: timer, prescaler, incr, rollover) on the same
// bus, clock enable (pclk0) and reset. In the 2600 map (MARIA's control.sv
// with maria_en 0, as for every 2600 image) the RIOT is A12 = 0, A7 = 1, its
// timer A9 = 1, A2 = 1. Its data in is top.sv's physical_write_DB, which is
// write_DB (db_w) but for bus stuffing, a feature of the BUS scheme, which is
// upstream's ARM mapper and is left out of this build.
//   exp    the timer has wrapped since its last write (tb_frames' expired)
//   wrote  the timer has been written since the reset
//   armed  no timer write since the last call began
//   await  a call has ended, and the 6507 has not yet read the timer
// sim/bupchip/dstat/ checks the copy against M6532.sv and the rule against
// tb_frames' on random bus traffic; tb_load and tb_frames check both in the
// whole core (BUP_DEBUG builds).
//
// Unlocks (12 bits, saturating at 4,095): dbg_unlock pulses, the guard
// dropping its lock, since power-up. locked is dbg_locked, registered.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
module daria_dbg_status (
	input  wire        clk,         // clk_sys
	input  wire        rst,         // top.sv's effective_reset
	input  wire        ce,          // top.sv's pclk0, the RIOT's clock enable
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire [15:0] ab,          // top.sv's AB (the decode reads A12, A9, A7, A4, A2, A1 and A0)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire        rw,          // top.sv's RW (1: read)
	input  wire  [7:0] db_w,        // top.sv's dout (write_DB)
	input  wire        call_busy,   // daria_fe arm_call_busy
	input  wire        call_tog,    // daria_fe call_tog
	input  wire        g_locked,    // daria_fe dbg_locked
	input  wire        g_unlock,    // daria_fe dbg_unlock
	output wire [48:0] dstat        // {guard locked, late calls 12, unlocks 12, calls 24}
);
	/* verilator lint_off PROCASSINIT */
	logic [23:0] calls = 24'd0;
	logic [11:0] late = 12'd0, unl = 12'd0;
	logic        tog_q = 1'b0, busy_q = 1'b0, locked = 1'b0, ul_q = 1'b0;
	logic  [7:0] t_timer = 8'hFF;
	logic  [9:0] t_pre = 10'd0;
	logic  [1:0] t_incr = 2'd2;
	logic        t_roll = 1'b0, exp = 1'b0, wrote = 1'b0, armed = 1'b0, await = 1'b0;
	/* verilator lint_on PROCASSINIT */

	// the RIOT's tick_inc and timer_wrap (the latter on a clock enable only)
	wire tick  = t_incr == 2'd0 || t_roll || (~|t_pre[2:0] && t_incr == 2'd1) ||
	             (~|t_pre[5:0] && t_incr == 2'd2) || (~|t_pre && t_incr == 2'd3);
	wire wrap  = ce && tick && t_timer == 8'd0;
	wire sel   = ce && ~ab[12] && ab[7] && ab[9] && ab[2];     // the timer's registers
	wire wr    = sel && ~rw && ab[4];                         // TIM1T, TIM8T, TIM64T, T1024T
	wire poll  = sel && rw && await;                          // INTIM or TIMINT, the first after a call
	wire exp_n = wr ? wrap : exp | (wrap && wrote);           // tb_frames' order: the write, then the wrap
	wire start = call_busy && !busy_q;
	wire stop  = !call_busy && busy_q;

	always_ff @(posedge clk) begin
		// the RIOT's timer, as M6532.sv updates it
		if (rst) begin
			t_timer <= 8'hFF;
			t_pre <= 10'd0;
			t_incr <= 2'd2;
			t_roll <= 1'b0;
		end else if (ce) begin
			t_pre <= t_pre + 10'd1;
			if (tick) t_timer <= t_timer - 8'd1;
			if (wr) begin
				t_pre <= 10'd0;
				t_roll <= 1'b0;
				t_incr <= ab[1:0];
				t_timer <= db_w;
			end else if (sel && rw && ~ab[0])
				t_roll <= 1'b0;                               // an INTIM read
			if (wrap) t_roll <= 1'b1;
		end
		// the late-call rule
		busy_q <= call_busy;
		if (rst) begin
			exp <= 1'b0;
			wrote <= 1'b0;
			armed <= 1'b0;
			await <= 1'b0;
			late <= 12'd0;
		end else begin
			exp <= exp_n;
			if (wr) wrote <= 1'b1;
			if (start) armed <= !wr;
			else if (wr) armed <= 1'b0;
			if (stop) await <= 1'b1;
			else if (start || poll) await <= 1'b0;
			if (poll && wrote && armed && exp_n && late != 12'hFFF) late <= late + 12'd1;
		end
		// calls, and the guard
		tog_q <= call_tog;
		if (rst) calls <= 24'd0;
		else if (call_tog != tog_q) calls <= calls + 24'd1;
		locked <= g_locked;
		ul_q <= g_unlock;
		if (ul_q && unl != 12'hFFF) unl <= unl + 12'd1;
	end

	assign dstat = {locked, late, unl, calls};
endmodule
/* verilator lint_on DECLFILENAME */
`endif
`endif

`default_nettype wire
