//------------------------------------------------------------------------------
// Atari 7800 for Analogue Pocket - system wrapper
//
// This is the Pocket equivalent of the MiSTer core's Atari7800.sv: it owns
// everything between the MiSTer `Atari7800` system module (rtl/top.sv) and
// the APF plumbing in core_top.v. Where the MiSTer wrapper's logic applies
// unchanged (A78 header parsing, cart size, 2600 detection, RIOT/TIA input
// wiring) it is carried over as-is so behaviour matches MiSTer.
//
// Everything here runs on clk_sys (14.318181 MHz) except the SDRAM
// controller, which runs on clk_sdram (exactly 4 x clk_sys, phase aligned).
//
// SPDX-License-Identifier: MIT
// Portions derived from the MiSTer Atari7800 core,
// Copyright (c) 2019-2026 Jamie Blanks (MIT).
//------------------------------------------------------------------------------

`default_nettype none

module atari7800_pocket
(
	input  wire        clk_sys,
	input  wire        clk_sdram,
	input  wire        pll_locked,
	input  wire        pll_busy,        // clk_74a: PLL retune (PAL/NTSC) in progress
	input  wire        reset_in,        // host reset / menu reset, clk_sys

	// Download stream (clk_sys, one clk_sys cycle per byte)
	input  wire        cart_download,
	input  wire        bios_download,
	input  wire        hscfw_download,  // high score cart firmware (4 KiB, optional A78 header)
	input  wire        arfw_download,   // Supercharger BIOS (2 KiB)
	input  wire        ioctl_wr,
	input  wire [24:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,

	// Settings
	input  wire  [1:0] region_setting,  // 0 auto, 1 NTSC, 2 PAL
	input  wire  [1:0] palette_temp,    // 0 warm, 1 cool, 2 hot
	input  wire  [1:0] hsc_setting,     // 0 auto, 1 on, 2 off
	input  wire        show_overscan,
	input  wire        hide_border,
	input  wire        stereo_tia,
	input  wire        swap_joysticks,
	input  wire        diff_left_b,     // 1 = B (novice)
	input  wire        diff_right_b,
	input  wire        skip_bios,
	input  wire        flicker_blend,   // 2600 only
	input  wire        pokey_irq,       // let POKEY timer IRQs reach the CPU (MiSTer "Pokey IRQ Enabled")
	input  wire        pause_core,      // Pocket menu open

	// Controllers, MiSTer joystick bit layout:
	//  0 R, 1 L, 2 D, 3 U, 4 Fire1, 5 Fire2, 6 Pause/B&W, 7 Select, 8 Reset
	input  wire [15:0] joy0,
	input  wire [15:0] joy1,

	// Video (clk_sys)
	output wire  [7:0] R,
	output wire  [7:0] G,
	output wire  [7:0] B,
	output wire        HSync,
	output wire        VSync,
	output wire        HBlank,
	output wire        VBlank,
	output wire        ce_pix,
	output wire        tia_mode_o,      // 2600 image loaded (160 wide)
	output wire        is_pal_o,
	output wire        video_pal_o,     // this frame's geometry is PAL (picks the scaler slot)

	// Audio (clk_sys), unsigned around a midpoint, as MiSTer
	output wire [15:0] AUDIO_L,
	output wire [15:0] AUDIO_R,

	// High score cartridge RAM, second port for the save slot (clk_74a)
	input  wire        clk_74a,
	input  wire  [8:0] hsc_bridge_addr, // 32 bit word address
	input  wire        hsc_bridge_wr,
	input  wire        hsc_bridge_rd,   // APF read strobe for this region
	input  wire [31:0] hsc_bridge_din,  // big endian: [31:24] is the lowest byte
	output wire [31:0] hsc_bridge_dout, // word latched at the last read strobe
	output wire        hsc_active,      // keep the shared HSC save (always)

	// SaveKey EEPROM (24LC256) RAM, second port for its save slot (clk_74a)
	input  wire  [1:0] savekey_setting, // 0 auto (A78 header), 1 on, 2 off
	input  wire [12:0] sk_bridge_addr,  // 32 bit word address
	input  wire        sk_bridge_wr,
	input  wire        sk_bridge_rd,    // APF read strobe for this region
	input  wire [31:0] sk_bridge_din,   // big endian: [31:24] is the lowest byte
	output wire [31:0] sk_bridge_dout,  // word latched at the last read strobe

	// SDRAM
	output wire [12:0] SDRAM_A,
	output wire  [1:0] SDRAM_BA,
	inout  wire [15:0] SDRAM_DQ,
	output wire        SDRAM_DQML,
	output wire        SDRAM_DQMH,
	output wire        SDRAM_nWE,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_CLK,
	output wire        SDRAM_CKE
);

//////////////////////////////  RESET  ////////////////////////////////////

reg old_cart_download = 1'b0;
wire mapper_init_busy;
reg reset;
reg [1:0] pll_busy_s = 2'b00;

always @(posedge clk_sys) begin
	old_cart_download <= cart_download;
	pll_busy_s <= {pll_busy_s[0], pll_busy};
	reset <= reset_in | cart_download | bios_download | hscfw_download |
		arfw_download | old_cart_download | mapper_init_busy | ~pll_locked |
		pll_busy_s[1];
end

////////////////////////////  CART HEADER  ////////////////////////////////

reg  [39:0] cart_header;
reg  [15:0] cart_flags;
reg   [7:0] cart_region, cart_save, cart_xm, header_mapper, header_version;
reg   [7:0] joy0_type, joy1_type;
reg         cart_is_7800;
reg         tia_mode;
reg         cart_loaded;
reg  [14:0] bios_mask;
reg         bios_loaded;
reg         hscfw_loaded;
reg         hscfw_hdr;
// Offset into the HSC firmware payload. The ROM takes it modulo 4 KiB, so a
// longer file leaves its last 4 KiB in the ROM. Header bytes land in the
// ROM first and are overwritten by the payload.
wire        hscfw_payload = ~hscfw_hdr | (ioctl_addr >= 25'd128);
wire [24:0] hscfw_off = (hscfw_hdr && ioctl_addr >= 25'd128) ? ioctl_addr - 25'd128 : ioctl_addr;
wire [31:0] cart_size;

initial begin
	cart_header = "ATARI";
	cart_flags = 0;
	cart_region = 0;
	cart_save = 0;
	cart_xm = 0;
	header_mapper = 0;
	header_version = 0;
	joy0_type = 8'd1;
	joy1_type = 8'd1;
	tia_mode = 0;
	cart_loaded = 0;
	bios_mask = 0;
	bios_loaded = 0;
	hscfw_loaded = 0;
	hscfw_hdr = 0;
end

// MiSTer picks 7800 vs 2600 from the file extension. The Pocket does not
// tell the core which extension was chosen, so the decision is made the way
// the MiSTer wrapper already makes it for headerless 7800 files: an image
// whose bytes 1-5 read "ATARI" is an A78, anything else is a 2600 image.
always @(posedge clk_sys) begin
	cart_is_7800 <= (cart_header == "ATARI");

	if (bios_download && ioctl_wr) begin
		bios_mask <= ioctl_addr[14:0];
		bios_loaded <= 1'b1;
	end

	// An hsc.a78 carries a 128 byte A78 header ("ATARI" at bytes 1-5).
	if (hscfw_download && ioctl_wr)
		case (ioctl_addr)
			25'd0: hscfw_hdr <= 1'b0;
			25'd1: hscfw_hdr <= ioctl_dout == "A";
			25'd2: hscfw_hdr <= hscfw_hdr & (ioctl_dout == "T");
			25'd3: hscfw_hdr <= hscfw_hdr & (ioctl_dout == "A");
			25'd4: hscfw_hdr <= hscfw_hdr & (ioctl_dout == "R");
			25'd5: hscfw_hdr <= hscfw_hdr & (ioctl_dout == "I");
			default: ;
		endcase

	// The whole 4 KiB image has to arrive before the HSC can be offered.
	if (hscfw_download && ioctl_wr && hscfw_off[11:0] == 12'hFFF && hscfw_payload)
		hscfw_loaded <= 1'b1;

	if (cart_download) begin
		tia_mode <= 1'b0;
		cart_loaded <= 1'b1;
		case (ioctl_addr)
			'd00: header_version <= ioctl_dout;
			'd01: cart_header[39:32] <= ioctl_dout;
			'd02: cart_header[31:24] <= ioctl_dout;
			'd03: cart_header[23:16] <= ioctl_dout;
			'd04: cart_header[15:8] <= ioctl_dout;
			'd05: cart_header[7:0] <= ioctl_dout;
			'd53: cart_flags[15:8] <= ioctl_dout;
			'd54: cart_flags[7:0] <= ioctl_dout;
			'd55: joy0_type <= ioctl_dout;   // 0=none, 1=joystick, 2=lightgun
			'd56: joy1_type <= ioctl_dout;
			'd57: cart_region <= ioctl_dout; // 0=ntsc, 1=pal
			'd58: cart_save <= ioctl_dout;   // bit 0 = high score cart, bit 1 = savekey
			'd63: cart_xm <= ioctl_dout;     // 1 = Has XM
			'd64: header_mapper <= ioctl_dout;
			default: ;
		endcase
	end else if (old_cart_download) begin
		// End of the image: a non-A78 image is a 2600 cart, and none of the
		// header fields apply to it.
		tia_mode <= ~cart_is_7800;
		if (~cart_is_7800) begin
			joy0_type <= 8'd1;
			joy1_type <= 8'd1;
			cart_flags <= 0;
			cart_region <= 0;
			cart_save <= 0;
			cart_xm <= 0;
			header_version <= 0;
			header_mapper <= 0;
		end
	end
end

// Only a v4 header defines the mapper byte.
wire [7:0] cart_mapper = (cart_is_7800 && header_version >= 8'd4) ? header_mapper : 8'd0;

a78_cart_extent cart_extent
(
	.clk           (clk_sys),
	.cart_download (cart_download),
	.ioctl_wr      (ioctl_wr),
	.ioctl_addr    (ioctl_addr),
	.ioctl_dout    (ioctl_dout),
	.cart_is_7800  (cart_is_7800),
	.tia_mode      (1'b0),
	.cart_size     (cart_size)
);

wire  [5:0] force_bs;
wire        sc;
wire  [2:0] mapper_revision;
wire        cdf_ldx, cdf_ldy, cdf_fetch_offset_enable;
wire  [7:0] cdf_fetch_offset;
wire [31:0] cdfj_entry, cdfj_stack;
wire [15:0] arm_audio_size_addr;

detect2600 detect2600
(
	.clk        (clk_sys),
	.load_start (~old_cart_download && cart_download),
	.load_addr  (ioctl_addr),
	.load_valid (ioctl_wr & cart_download),
	.load_end   (old_cart_download && ~cart_download),
	.cart_size  (cart_size),
	.data       (ioctl_dout),
	.force_bs   (force_bs),
	.sc         (sc),
	.mapper_revision(mapper_revision),
	.cdf_ldx,
	.cdf_ldy,
	.cdf_fetch_offset_enable,
	.cdf_fetch_offset,
	.cdfj_entry,
	.cdfj_stack,
	.arm_audio_size_addr
);

////////////////////////////  MEMORY  /////////////////////////////////////

wire [24:0] cart_addr;
wire        cart_read;
wire  [7:0] cart_data_sd;
wire  [7:0] cart_data_rom;
wire        cart_busy;
wire  [7:0] cart_din;
wire [15:0] bios_addr;
wire  [7:0] bios_data;
wire        RW;
wire  [7:0] din;

wire [24:0] cart_write_addr = (ioctl_addr >= 25'd128) && cart_is_7800 ?
	(ioctl_addr - 25'd128) : ioctl_addr;

// The "no cartridge" image MiSTer boots into when nothing is loaded.
spram #(
	.addr_width(14),
	.mem_name("Cart"),
	.mem_init_file("mem0.mif"),
	.sim_init_file("rtl/mem0.hex")
) cart_rom
(
	.address (cart_addr[13:0]),
	.clock   (clk_sys),
	.data    (8'd0),
	.wren    (1'b0),
	.cs      (1'b1),
	.q       (cart_data_rom)
);

// The 7800 BIOS is 4 KiB (NTSC) or 16 KiB (PAL); the mask mirrors it.
spram #(.addr_width(14), .mem_name("BIOS")) bios
(
	.address (bios_download ? ioctl_addr[13:0] : (bios_addr[13:0] & bios_mask[13:0])),
	.clock   (clk_sys),
	.data    (ioctl_dout),
	.wren    (ioctl_wr & bios_download),
	.cs      (1'b1),
	.q       (bios_data)
);

sdram sdram
(
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_nCS  (),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CLK  (SDRAM_CLK),
	.SDRAM_CKE  (SDRAM_CKE),

	.clk        (clk_sdram),
	.init       (~pll_locked),

	.ch0_addr   (cart_download ? cart_write_addr : cart_addr),
	.ch0_wr     (cart_download ? (ioctl_wr & cart_download) : 1'b0),
	.ch0_din    (cart_download ? ioctl_dout : cart_din),
	.ch0_rd     (cart_read & ~cart_download & ~reset),
	.ch0_dout   (cart_data_sd),
	.ch0_busy   (cart_busy)
);

// High score cartridge RAM ($1000-$17FF). Port B belongs to the Pocket's
// save slot, so the scores survive power-off.
wire       hsc_ram_cs;
wire [7:0] hsc_ram_dout;

save_ram_dp #(.WORD_ADDR_BITS(9)) hsc_ram
(
	.clk_a  (clk_sys),
	.addr_a (bios_addr[10:0]),
	.din_a  (din),
	.we_a   (~RW & hsc_ram_cs),
	.dout_a (hsc_ram_dout),

	.clk_b  (clk_74a),
	.addr_b (hsc_bridge_addr),
	.din_b  (hsc_bridge_din),
	.we_b   (hsc_bridge_wr),
	.rd_b   (hsc_bridge_rd),
	.dout_b (hsc_bridge_dout)
);

// Auto follows the A78 header. Its save byte is a bitfield (bit 0 HSC,
// bit 1 SaveKey/AtariVox), so a cart can ask for both: Triple Punch's is 3.
// A port 2 controller type of 10 (AtariVox/SaveKey) also asks for a SaveKey.
//
// MiSTer turns the HSC off while a SaveKey is in use, because both share its
// one save file. Here each has its own file, and on real hardware they are
// independent (the HSC sits on the cart bus, the SaveKey on port 2), so both
// can be on at once.
wire use_sk = (savekey_setting == 2'd1) ||
	(savekey_setting == 2'd0 && cart_is_7800 && (cart_save[1] || joy1_type == 8'd10));

// The HSC firmware is not built in (it is Atari's code); it comes from the
// user's highscor.rom. Without it there is no HSC, whatever the setting.
wire hsc_en = hscfw_loaded &
	((hsc_setting == 2'd0) ? (cart_save[0] || cart_xm[0]) : (hsc_setting == 2'd1));
// The high score cart save is one shared file (hsc.sav) for every cart, like
// the real HSC's single RAM. Its size in the data slot table is what the
// Pocket reads to decide whether to write the file back, so it must be
// 2 KiB for every cart, 2600 images included: a size of 0 could leave the
// shared file overwritten or dropped after playing a game without the HSC.
// It also cannot follow the High Score Cart setting, which reaches the core
// after the Pocket has read the table.
assign hsc_active = 1'b1;

// SaveKey: a 24LC256 I2C EEPROM on controller port 2, SDA on PA2 and SCL on
// PA3, as on MiSTer (EEPROM_24LC0X from the MiSTer core). Its 32 KiB live in
// block RAM whose other port is the shared savekey.sav slot, through the same
// save_ram_dp as the HSC, so it has the same APF read latch.
//
// Auto turns it on when an A78 header asks for one (see use_sk). A 2600
// image has no header, so 2600 SaveKey games need the setting On.


wire  [7:0] PAout;
wire        sk_sda;
wire  [7:0] sk_ram_q, sk_ram_d;
wire [14:0] sk_ram_addr;
wire        sk_ram_wr;

EEPROM_24LC0X #(
	.ADDR_WIDTH (15),
	.PAGE_WIDTH (6)
) savekey (
	.clk            (clk_sys),
	.ce             (1'b1),
	.reset          (reset | ~use_sk),
	.SCL            (PAout[3]),
	.SDA_in         (PAout[2]),
	.SDA_out        (sk_sda),
	.E_id           (3'd0),
	.WC_n           (1'b0),
	.data_from_ram  (sk_ram_q),
	.data_to_ram    (sk_ram_d),
	.ram_addr       (sk_ram_addr),
	.ram_read       (),
	.ram_write      (sk_ram_wr),
	.ram_done       (1'b1)
);

save_ram_dp #(.WORD_ADDR_BITS(13), .BLANK(8'hFF)) sk_ram
(
	.clk_a  (clk_sys),
	.addr_a (sk_ram_addr),
	.din_a  (sk_ram_d),
	.we_a   (sk_ram_wr),
	.dout_a (sk_ram_q),

	.clk_b  (clk_74a),
	.addr_b (sk_bridge_addr),
	.din_b  (sk_bridge_din),
	.we_b   (sk_bridge_wr),
	.rd_b   (sk_bridge_rd),
	.dout_b (sk_bridge_dout)
);

//////////////////////////////  INPUT  ////////////////////////////////////

wire [15:0] joya = swap_joysticks ? joy1 : joy0;
wire [15:0] joyb = swap_joysticks ? joy0 : joy1;

wire  [7:0] PAin, PBin, PBout;
wire        PAread;
wire  [3:0] iout;
wire  [3:0] i_read;
wire        tia_en;
wire        tia_hsync, tia_f1, tia_pal;
reg   [3:0] idump;
reg   [1:0] ilatch;
reg   [7:0] pa_in_r;

// 2600: the Pause button toggles Colour/B&W, as on MiSTer.
reg bw_mode = 1'b0;
reg old_bw = 1'b0;
wire is_bw = (joya[6] | joyb[6]) & tia_en;
always @(posedge clk_sys) begin
	old_bw <= is_bw;
	if (~old_bw & is_bw)
		bw_mode <= ~bw_mode;
end

// Two-button sensing on the 7800: PB2/PB4 low selects two-button mode.
wire joya_b2 = ~PBout[2] && ~tia_en;
wire joyb_b2 = ~PBout[4] && ~tia_en;

wire [7:0] porta_type = joy0_type == 8'd0 ? 8'd0 : 8'd1;
wire [7:0] portb_type = joy1_type == 8'd0 ? 8'd0 : 8'd1;

always @(*) begin
	// P2 F1, P2 F2, P1 F1, P1 F2
	idump = tia_en ? {(|portb_type ? 1'b0 : ~joyb[5]), 1'd0, (|porta_type ? 1'b0 : ~joya[5]), 1'd0} :
		{joyb[4], joyb[5], joya[4], joya[5]};
	pa_in_r[7:4] = {~joya[0], ~joya[1], ~joya[2], ~joya[3]}; // P1: R L D U
	pa_in_r[3:0] = {~joyb[0], ~joyb[1], ~joyb[2], ~joyb[3]}; // P2: R L D U
	ilatch[0] = tia_en ? ~joya[4] : ~(joya[4] || joya[5]);    // P1 Fire
	ilatch[1] = tia_en ? ~joyb[4] : ~(joyb[4] || joyb[5]);    // P2 Fire

	if (porta_type == 8'd0) begin pa_in_r[7:4] = 4'b1111; ilatch[0] = 1'b1; idump[1:0] = 2'b00; end
	if (portb_type == 8'd0) begin pa_in_r[3:0] = 4'b1111; ilatch[1] = 1'b1; idump[3:2] = 2'b00; end

	// In two button mode pin 6 is pulled up strongly and will not lower.
	if (joya_b2) ilatch[0] = 1'b1;
	if (joyb_b2) ilatch[1] = 1'b1;
end

// With the SaveKey on, PA2 reads the EEPROM's SDA (the RIOT ANDs it with its
// own output, so a released pin reads the EEPROM).
assign PAin = use_sk ? {pa_in_r[7:3], sk_sda, pa_in_r[1:0]} : pa_in_r;

assign PBin[7] = ~diff_right_b;           // Right difficulty: 1 = A
assign PBin[6] = ~diff_left_b;            // Left difficulty
assign PBin[5] = PBout[5];                // Not connected
assign PBin[4] = PBout[4];                // Two button sensing
assign PBin[3] = tia_en ? ~bw_mode : (~joya[6] & ~joyb[6]); // Pause / Colour-B&W
assign PBin[2] = PBout[2];                // Two button sensing
assign PBin[1] = ~joya[7] & ~joyb[7];     // Select
assign PBin[0] = ~joya[8] & ~joyb[8];     // Reset

//////////////////////////////  SYSTEM  ///////////////////////////////////

// A 2600 image's region is measured from its video (the TIA's auto_pal). That
// measurement restarts with the core's reset, and switching the master clock
// to PAL resets the core, so the result is latched here until the next cart
// load; otherwise a PAL 2600 game would flip back to NTSC and retune forever.
reg tia_pal_seen = 1'b0;
always @(posedge clk_sys)
	if (cart_download)
		tia_pal_seen <= 1'b0;
	else if (tia_pal)
		tia_pal_seen <= 1'b1;

wire region_select = (region_setting == 2'd0) ?
	(tia_en ? (tia_pal | tia_pal_seen) : cart_region[0]) : (region_setting == 2'd2);

reg [15:0] rnd = 16'h5A5A;
always @(posedge clk_sys) rnd <= {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};

wire VBlank_orig;

// As on MiSTer, running the real BIOS and running a 2600 image natively are
// the two sides of one switch: with the BIOS in charge it finds the 2600
// cartridge itself, the way the console does.
wire use_bios = bios_loaded & ~skip_bios;

Atari7800 main
(
	// HSC firmware and Supercharger BIOS: built without them
	// (EXTERNAL_FIRMWARE), loaded from the user's files instead. The HSC
	// keeps the last 4 KiB of its payload; the Supercharger the first 2 KiB.
	.fw_hsc_load  (hscfw_download),
	.fw_ar_load   (arfw_download),
	.fw_wr        (ioctl_wr & (hscfw_download ? 1'b1 : ioctl_addr[24:11] == 0)),
	.fw_addr      (hscfw_download ? hscfw_off[11:0] : ioctl_addr[11:0]),
	.fw_data      (ioctl_dout),
	.clk_sys      (clk_sys),
	.reset        (reset),
	.loading      (cart_download || bios_download || mapper_init_busy),
	.pause        (pause_core),

	// Video
	.RED          (R),
	.GREEN        (G),
	.BLUE         (B),
	.HSync        (HSync),
	.VSync        (VSync),
	.HBlank       (HBlank),
	.VBlank       (VBlank),
	.VBlank_orig  (VBlank_orig),
	.ce_pix       (ce_pix),
	.comp         (),
	.comp_tog     (),
	.comp_hs      (),
	.comp_vs      (),
	.comp_hb      (),
	.comp_vb      (),
	.comp_burst_start(),
	.comp_burst_len  (),
	.show_border  (~hide_border),
	.show_overscan(show_overscan),
	.PAL          (region_select),
	.pal_temp     (palette_temp),
	.tia_mode     (tia_mode && ~use_bios),
	.bypass_bios  (~use_bios),
	.cart_present (~(use_bios & ~cart_loaded)), // empty slot only when booting the BIOS alone
	.pokey_irq    (pokey_irq),
	.minnie_en    (1'b1),
	.minnie_alt   (1'b0),
	.hsc_en       (hsc_en),
	.hsc_ram_dout (hsc_ram_dout),
	.hsc_ram_cs   (hsc_ram_cs),
	.cpu_ce       (),

	// Audio
	.AUDIO_R      (AUDIO_R),
	.AUDIO_L      (AUDIO_L),

	// Cart interface
	.cart_out     (cart_download ? ioctl_dout : (cart_loaded ? cart_data_sd : cart_data_rom)),
	.cart_read    (cart_read),
	.cart_size    (cart_size),
	.cart_addr_out(cart_addr),
	.cart_flags   (cart_is_7800 ? cart_flags : 16'd0),
	.cart_mapper  (cart_mapper),
	.cart_save    (cart_save),
	.cart_din     (cart_din),
	.cart_xm      (cart_is_7800 ? cart_xm : 8'h0),
	.ps2_key      (11'd0),

	// Cartridge RAM lives inside top.sv (cart_ram_tdp)
	.cartram_addr   (),
	.cartram_wr     (),
	.cartram_rd     (),
	.cartram_wrdata (),
	.cartram_data   (8'hFF),

	// ARM mapper / BupChip / DDR3 - compiled out for the Pocket
	.clk_arm          (clk_sys),
	.arm_reset        (~pll_locked),
	.mapper_load_start(~old_cart_download && cart_download),
	.mapper_load_addr (ioctl_addr),
	.mapper_load_valid(ioctl_wr && cart_download),
	.mapper_load_data (ioctl_dout),
	.mapper_load_end  (old_cart_download && ~cart_download),
	.mapper_load_wait (),
	.mapper_init_busy (mapper_init_busy),
	.fa2_nvram_request(),
	.fa2_nvram_write  (),
	.fa2_nvram_addr   (),
	.fa2_nvram_wdata  (),
	.fa2_nvram_rdata  (8'hFF),
	.fa2_nvram_ready  (1'b1),
	.fa2_nvram_dirty  (),
	.ddram_clk        (),
	.ddram_addr       (),
	.ddram_burstcnt   (),
	.ddram_busy       (1'b0),
	.ddram_dout       (64'd0),
	.ddram_dout_ready (1'b0),
	.ddram_rd         (),
	.ddram_din        (),
	.ddram_be         (),
	.ddram_we         (),

	// BIOS
	.bios_out     (bios_data),
	.AB           (bios_addr),
	.RW           (RW),
	.dout         (din),

	// TIA
	.idump        (idump),
	.ilatch       (ilatch),
	.i_out        (iout),
	.tia_en       (tia_en),
	.tia_hsync    (tia_hsync),
	.use_stereo   (stereo_tia),
	.cpu_driver   (1'b1),
	.tia_f1       (tia_f1),
	.tia_pal      (tia_pal),
	.tia_stab     (1'b0),     // MiSTer default: "smart" stabiliser, fixed 240 line window

	// RIOT
	.PAin         (PAin),
	.PBin         (PBin),
	.PAout        (PAout),
	.PBout        (PBout),
	.PAread       (PAread),

	// 2600 cart flags from detect2600
	.force_bs     (force_bs),
	.mapper_revision,
	.cdf_ldx,
	.cdf_ldy,
	.cdf_fetch_offset_enable,
	.cdf_fetch_offset,
	.cdfj_entry,
	.cdfj_stack,
	.arm_audio_size_addr,
	.sc           (sc),
	.clearval     (8'h00),
	.random       (rnd[7:0]),
	.decomb       (1'b0),
	.mapper       (6'd0),
	.tape_in      (2'b00),
	.fix_sc_cs    (1'b0),

	// Palette loading (not used)
	.pal_load     (1'b0),
	.pal_addr     (10'd0),
	.pal_wr       (1'b0),
	.pal_data     (8'd0),
	.blend        (flicker_blend),
	.i_read       (i_read)
);

assign tia_mode_o = tia_en;
assign is_pal_o = region_select;
// MARIA's frame follows region_select (274 visible lines for PAL, 224 NTSC).
// A 2600 image's window follows the TIA's own region measurement (288 / 240),
// which is what the stabiliser uses, whatever the Region setting says.
assign video_pal_o = tia_mode ? tia_pal : region_select;

endmodule


// Save RAM for a Pocket save slot: bytes for the console, 32 bit words for
// the APF bridge. Four byte lanes of 2^WORD_ADDR_BITS bytes each, one per
// byte of a word, each a true dual port, dual clock RAM, so the bridge reads
// or writes a whole word in one cycle. Used for the HSC (2 KiB) and the
// SaveKey (32 KiB).
//
// Bridge reads have a one-transaction lag: the host samples dout_b a few
// cycles into a read, then pulses rd_b, and expects to have sampled the word
// latched at the previous strobe (core_bridge_cmd and agg23's data_unloader
// behave the same way). Answering with the current address instead shifted
// every saved word by one: HSC saves from 2.0.2/2.0.3 came out rotated by four
// bytes. The latch lives here so every save slot gets it.
module save_ram_dp #(
	parameter WORD_ADDR_BITS = 9,
	// 8'hFF: store bytes inverted, so the RAM's power-up zeros read as $FF.
	// A new SaveKey file then starts blank the way a real EEPROM does.
	parameter [7:0] BLANK = 8'h00
) (
	input  wire                        clk_a,
	input  wire [WORD_ADDR_BITS+1:0]   addr_a,
	input  wire  [7:0]                 din_a,
	input  wire                        we_a,
	output wire  [7:0]                 dout_a,

	input  wire                        clk_b,
	input  wire [WORD_ADDR_BITS-1:0]   addr_b,
	input  wire [31:0]                 din_b,
	input  wire                        we_b,
	input  wire                        rd_b,
	output reg  [31:0]                 dout_b = 32'd0
);
	localparam WORDS = 1 << WORD_ADDR_BITS;

	wire [7:0]  lane_q [4];
	wire [31:0] word_q;
	reg  [1:0]  lane_a;

	always @(posedge clk_a) lane_a <= addr_a[1:0];
	assign dout_a = lane_q[lane_a] ^ BLANK;

	always @(posedge clk_b)
		if (rd_b)
			dout_b <= word_q ^ {4{BLANK}};

	genvar i;
	generate
		for (i = 0; i < 4; i = i + 1) begin : lane
			altsyncram #(
				.operation_mode                 ("BIDIR_DUAL_PORT"),
				.width_a                        (8),
				.widthad_a                      (WORD_ADDR_BITS),
				.numwords_a                     (WORDS),
				.width_b                        (8),
				.widthad_b                      (WORD_ADDR_BITS),
				.numwords_b                     (WORDS),
				.outdata_reg_a                  ("UNREGISTERED"),
				.outdata_reg_b                  ("UNREGISTERED"),
				.address_reg_b                  ("CLOCK1"),
				.indata_reg_b                   ("CLOCK1"),
				.wrcontrol_wraddress_reg_b      ("CLOCK1"),
				.clock_enable_input_a           ("BYPASS"),
				.clock_enable_input_b           ("BYPASS"),
				.clock_enable_output_a          ("BYPASS"),
				.clock_enable_output_b          ("BYPASS"),
				.power_up_uninitialized         ("FALSE"),
				.read_during_write_mode_port_a  ("NEW_DATA_NO_NBE_READ"),
				.read_during_write_mode_port_b  ("NEW_DATA_NO_NBE_READ"),
				.intended_device_family         ("Cyclone V"),
				.lpm_type                       ("altsyncram")
			) ram (
				.clock0    (clk_a),
				.address_a (addr_a[WORD_ADDR_BITS+1:2]),
				.data_a    (din_a ^ BLANK),
				.wren_a    (we_a && addr_a[1:0] == i),
				.q_a       (lane_q[i]),

				.clock1    (clk_b),
				.address_b (addr_b),
				.data_b    (din_b[31 - 8*i -: 8] ^ BLANK),
				.wren_b    (we_b),
				.q_b       (word_q[31 - 8*i -: 8]),

				.aclr0 (1'b0), .aclr1 (1'b0),
				.addressstall_a (1'b0), .addressstall_b (1'b0),
				.byteena_a (1'b1), .byteena_b (1'b1),
				.clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
				.rden_a (1'b1), .rden_b (1'b1),
				.eccstatus ()
			);
		end
	endgenerate
endmodule
