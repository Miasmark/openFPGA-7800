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
// The status comes from clk_arm and clk_sys registers and is sampled here on
// clk_sys: timed paths, as clk_arm is 2 x clk_sys from the same VCO.
// Display only; nothing else depends on it.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_status_osd (
	input  wire        clk,         // clk_sys
	input  wire        en,          // souper_profile
	input  wire [31:0] status,      // bupchip_pocket dbg_status (clk_arm)
	input  wire [31:0] halt_pc,     // bupchip_pocket dbg_halt_pc (clk_arm)
	input  wire [110:0] load,       // bupchip_pocket dbg_load (clk_sys, clk_arm)

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
	wire       in_osd = en && !hblank && !vblank && xc < 7'd96 && yc < 7'd104;
	wire       in_box = xc[2:0] != 3'd0 && xc[2:0] != 3'd7 && yc[2:0] != 3'd0 && yc[2:0] != 3'd7;

	// Each row: its bits (column 0 = bit 11), which cells are drawn, and
	// the lit colour.
	logic [11:0] bits, shown;
	logic [23:0] on_rgb;
	always_comb begin
		shown = 12'hFFF;
		on_rgb = 24'h40A0FF;
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

`default_nettype wire
