//------------------------------------------------------------------------------
// BupChip status on screen, for BUP_DEBUG builds only (docs/BUPCHIP_CORE.md,
// "Macros and parameters"; the hardware test in step 5 reads it).
//
// While a Souper cartridge is loaded (en = souper_profile), the top-left
// 96 x 32 pixels of the picture are replaced by four rows of twelve cells,
// each an 8 x 8 pixel cell with a 6 x 6 box on black. A lit box is a 1 bit,
// a grey box a 0 bit; the grey alternates in shade between groups of four
// cells, so binary values read in nibbles, most significant bit on the left.
//
//   row 0  flags   green: firmware loaded, ARSC block ready, CPU running
//                  (a gap)
//                  red:   halted, command overflow, PCM overflow,
//                         PCM underflow, muted (FAULT write), capture error
//   row 1  yellow: halt code (4 bits); orange: firmware fault code (8 bits)
//   row 2  cyan:   lowest PCM FIFO level since the boot's prefill (11 bits,
//                  from the second cell)
//   row 3  white:  halt PC, as the word address within the ROM (PC[13:2])
//
// A good run shows three green boxes, no red, and rows 1 and 3 all grey;
// row 2 holds the lowest level (simulation: 600 or more on every song).
// The flags are sticky until the BupChip is next held (a cartridge load, a
// PAL/NTSC retune), as bupchip_pocket.sv's status word is.
//
// The status comes from clk_arm registers and is sampled here on clk_sys:
// a timed path, as clk_arm is 2 x clk_sys from the same VCO. Display only;
// nothing else depends on it.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_status_osd (
	input  wire        clk,         // clk_sys
	input  wire        en,          // souper_profile
	input  wire [31:0] status,      // bupchip_pocket dbg_status (clk_arm)
	input  wire [31:0] halt_pc,     // bupchip_pocket dbg_halt_pc (clk_arm)

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
	logic [31:0] st = 32'd0;
	logic [11:0] pc = 12'd0;
	always_ff @(posedge clk) begin
		st <= status;
		pc <= halt_pc[13:2];
	end

	// Pixel within the active line and active line within the frame,
	// saturating past the overlay.
	logic [6:0] xc = 7'd0;
	logic [5:0] yc = 6'd0;
	logic       hb_q = 1'b1;
	always_ff @(posedge clk) begin
		hb_q <= hblank;
		if (hblank)
			xc <= 7'd0;
		else if (ce_pix && !vblank && xc != 7'd127)
			xc <= xc + 7'd1;
		if (vblank)
			yc <= 6'd0;
		else if (hblank && !hb_q && yc != 6'd63)
			yc <= yc + 6'd1;
	end

	wire [3:0] col = xc[6:3];          // 0..11 inside the overlay
	wire [1:0] row  = yc[4:3];
	wire       in_osd = en && !hblank && !vblank && xc < 7'd96 && yc < 6'd32;
	wire       in_box = xc[2:0] != 3'd0 && xc[2:0] != 3'd7 && yc[2:0] != 3'd0 && yc[2:0] != 3'd7;

	// Each row: its bits (column 0 = bit 11) and which cells are drawn.
	logic [11:0] bits, shown;
	always_comb begin
		case (row)
			2'd0: begin
				bits  = {st[30], st[29], st[31], 1'b0, st[28], st[23], st[22], st[21], st[20], st[11], 2'b00};
				shown = 12'b1110_1111_1100;
			end
			2'd1: begin
				bits  = {st[27:24], st[19:12]};
				shown = 12'hFFF;
			end
			2'd2: begin
				bits  = {1'b0, st[10:0]};
				shown = 12'h7FF;
			end
			default: begin
				bits  = pc;
				shown = 12'hFFF;
			end
		endcase
	end
	wire bit_on   = bits[4'd11 - col];
	wire bit_show = shown[4'd11 - col];

	logic [23:0] on_rgb;
	always_comb
		case (row)
			2'd0:    on_rgb = col < 4'd3 ? 24'h00E000 : 24'hFF2020;
			2'd1:    on_rgb = col < 4'd4 ? 24'hFFE000 : 24'hFF8000;
			2'd2:    on_rgb = 24'h00E0FF;
			default: on_rgb = 24'hFFFFFF;
		endcase
	wire [23:0] off_rgb = col[2] ? 24'h585858 : 24'h303030;
	wire [23:0] osd_rgb = (in_box && bit_show) ? (bit_on ? on_rgb : off_rgb) : 24'h000000;

	assign {r_out, g_out, b_out} = in_osd ? osd_rgb : {r_in, g_in, b_in};
endmodule

`default_nettype wire
