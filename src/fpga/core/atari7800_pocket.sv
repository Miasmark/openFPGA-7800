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
	input  wire        pokey_irq,
	input  wire        clear_random,    // fill RAM with random values at reset (MiSTer "Clear Memory")
	input  wire        decomb,          // 2600 de-comb
	input  wire  [4:0] bs_override,     // 2600 bankswitching: 0 auto, else MiSTer's mapper number       // let POKEY timer IRQs reach the CPU (MiSTer "Pokey IRQ Enabled")
	input  wire        pause_core,      // Pocket menu open

	// Controllers, MiSTer joystick bit layout:
	//  0 R, 1 L, 2 D, 3 U, 4 Fire1, 5 Fire2, 6 Pause/B&W, 7 Select, 8 Reset
	input  wire [15:0] joy0,
	input  wire [15:0] joy1,
	input  wire [15:0] joy2,             // docked controllers 3 and 4 (paddles 3, 4)
	input  wire [15:0] joy3,
	input  wire [15:0] analog0,          // left stick {y, x}, unsigned, 128 = centre
	input  wire [15:0] analog1,
	input  wire [15:0] analog2,
	input  wire [15:0] analog3,
	input  wire  [2:0] port1_input,      // 0 auto, 1 joystick, 2 paddles, 3 driving, 4 light gun
	input  wire  [2:0] port2_input,
	input  wire [15:0] analog0r,         // right sticks {y, x}: dual-stick fire
	input  wire [15:0] analog1r,
	input  wire  [1:0] turbo,            // X / Y repeat fire: 0 off, 1 fast, 2 medium, 3 slow

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

// Turbo: X repeats fire 1 (as A does) and Y fire 2 (as B does), the
// button next to each on the Pocket's diamond; A and B stay plain. Switching
// every 2, 3 or 4 frames: 15, 10 or 7.5 presses a second at 60 Hz. Counted
// in frames so each press and release lasts whole frames, which games that
// read the buttons once a frame need.
reg  [1:0] turbo_cnt = 2'd0;
reg        turbo_on = 1'b1;
reg        turbo_vs = 1'b0;
always @(posedge clk_sys) begin
	turbo_vs <= VSync;
	if (VSync && !turbo_vs) begin
		if (turbo_cnt >= turbo) begin
			turbo_cnt <= 2'd0;
			turbo_on  <= ~turbo_on;
		end else
			turbo_cnt <= turbo_cnt + 1'd1;
	end
end
wire turbo_gate = (turbo == 2'd0) | turbo_on;

// joy bits: 4 fire 1 (A or X), 5 fire 2 (B or Y), 9 A, 10 B, 11 X, 12 Y
function [15:0] with_turbo(input [15:0] j, input gate);
	begin
		with_turbo    = j;
		with_turbo[4] = j[9]  | (j[11] & gate);
		with_turbo[5] = j[10] | (j[12] & gate);
	end
endfunction

wire [15:0] joy0t = with_turbo(joy0, turbo_gate);
wire [15:0] joy1t = with_turbo(joy1, turbo_gate);
wire [15:0] joya = swap_joysticks ? joy1t : joy0t;
wire [15:0] joyb = swap_joysticks ? joy0t : joy1t;

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

//////////////////////////  VIRTUAL CONTROLLERS  ///////////////////////////
//
// Port types use MiSTer's numbers: 0 none, 1 joystick, 2 light gun,
// 3 paddles, 6 driving, 9 Booster Grip, 10 dual stick (MiSTer's Robotron). Auto takes the A78 header's controller byte; a 2600
// image has none, so its paddle and driving games need the Port Input menu.
function [7:0] header_port_type(input [7:0] t);
	case (t)
		8'd0: header_port_type = 8'd0;
		8'd2: header_port_type = 8'd2;   // light gun
		8'd3: header_port_type = 8'd3;   // paddles
		8'd6: header_port_type = 8'd6;   // 2600 driving controller
		default: header_port_type = 8'd1; // joysticks; trakball, keypad, mice unsupported
	endcase
endfunction

function [7:0] menu_port_type(input [2:0] m, input [7:0] auto_type);
	case (m)
		3'd1: menu_port_type = 8'd1;
		3'd2: menu_port_type = 8'd3;
		3'd3: menu_port_type = 8'd6;
		3'd4: menu_port_type = 8'd2;
		3'd5: menu_port_type = 8'd10;
		3'd6: menu_port_type = 8'd9;
		default: menu_port_type = auto_type;
	endcase
endfunction

wire [7:0] porta_type = menu_port_type(port1_input, header_port_type(joy0_type));
wire [7:0] portb_type = menu_port_type(port2_input, header_port_type(joy1_type));

// The D-pad and docked analog sticks become positions (virtual_axis.sv).
// A or B is the paddle button, fire or trigger; X held moves slowly and
// finely, Y held moves fast. Controllers 1 and 2 are the two paddles on port
// 1 (2600 paddles come in pairs), 3 and 4 the two on port 2.
wire [15:0] ana_a = swap_joysticks ? analog1 : analog0;
wire [15:0] ana_b = swap_joysticks ? analog0 : analog1;

reg [13:0] ms_div = 14'd0;
reg        ms_tick = 1'b0;
always @(posedge clk_sys) begin
	ms_tick <= 1'b0;
	if (ms_div == 14'd14317) begin
		ms_div  <= 14'd0;
		ms_tick <= 1'b1;
	end else
		ms_div <= ms_div + 1'd1;
end

wire [15:0] vjoy [4];
assign vjoy[0] = joya;
assign vjoy[1] = joyb;
assign vjoy[2] = joy2;
assign vjoy[3] = joy3;
wire [15:0] vana [4];
assign vana[0] = ana_a;
assign vana[1] = ana_b;
assign vana[2] = analog2;
assign vana[3] = analog3;

wire  [7:0] vx_pos [4];
wire [15:0] vx_phase [4];
wire  [3:0] vbutton;
genvar vi;
generate
	for (vi = 0; vi < 4; vi = vi + 1) begin : vaxis
		// joy bits: 0 R, 1 L, 2 D, 3 U, 9 A, 10 B, 11 X, 12 Y
		assign vbutton[vi] = vjoy[vi][9] | vjoy[vi][10];
		virtual_axis ax (
			.clk      (clk_sys),
			.reset    (cart_download),
			.tick     (ms_tick),
			.neg      (vjoy[vi][1]),
			.pos      (vjoy[vi][0]),
			.slow     (vjoy[vi][11]),
			.fast     (vjoy[vi][12]),
			.analog   (vana[vi][7:0]),
			.position (vx_pos[vi]),
			.phase    (vx_phase[vi])
		);
	end
endgenerate

// Dual stick (Robotron: 2084 and other twin-stick games), as MiSTer's
// Robotron mode: one controller drives both ports. Port 1 moves, from the
// D-pad or left stick; port 2 fires in a direction, from the face buttons in
// their diamond (X up, B down, Y left, A right) or the right stick.
wire [15:0] anr_a = swap_joysticks ? analog1r : analog0r;
wire  [3:0] stick_l, stick_r;
stick_dirs dual_left  (.clk(clk_sys), .reset(cart_download), .stick(ana_a), .dirs(stick_l));
stick_dirs dual_right (.clk(clk_sys), .reset(cart_download), .stick(anr_a), .dirs(stick_r));
wire       dual_stick = (porta_type == 8'd10) || (portb_type == 8'd10);
wire [3:0] dual_move_raw = joya[3:0] | stick_l;                                // U D L R = 3..0
wire [3:0] dual_fire_raw = {joya[11], joya[10], joya[12], joya[9]} | stick_r;

// A joystick can't push up and down (or left and right) at once, but four
// face buttons can, and so can a stick plus the D-pad. Robotron doesn't
// expect it: opposite directions together stopped its fire stick and
// corrupted the screen. Of an opposite pair held together, the one pressed
// last wins, as on arcade stick encoders.
reg  [3:0] dual_move_d = 4'd0, dual_fire_d = 4'd0;
reg  [1:0] move_last = 2'b00, fire_last = 2'b00;   // [0] R/L: 1 = R newer; [1] D/U: 1 = D newer
always @(posedge clk_sys) begin
	dual_move_d <= dual_move_raw;
	dual_fire_d <= dual_fire_raw;
	if (dual_move_raw[0] & ~dual_move_d[0]) move_last[0] <= 1'b1;
	if (dual_move_raw[1] & ~dual_move_d[1]) move_last[0] <= 1'b0;
	if (dual_move_raw[2] & ~dual_move_d[2]) move_last[1] <= 1'b1;
	if (dual_move_raw[3] & ~dual_move_d[3]) move_last[1] <= 1'b0;
	if (dual_fire_raw[0] & ~dual_fire_d[0]) fire_last[0] <= 1'b1;
	if (dual_fire_raw[1] & ~dual_fire_d[1]) fire_last[0] <= 1'b0;
	if (dual_fire_raw[2] & ~dual_fire_d[2]) fire_last[1] <= 1'b1;
	if (dual_fire_raw[3] & ~dual_fire_d[3]) fire_last[1] <= 1'b0;
end

function [3:0] last_wins(input [3:0] d, input [1:0] last);
	begin
		last_wins = d;
		if (d[0] & d[1]) begin last_wins[0] = last[0]; last_wins[1] = ~last[0]; end
		if (d[2] & d[3]) begin last_wins[2] = last[1]; last_wins[3] = ~last[1]; end
	end
endfunction

wire [3:0] dual_move = last_wins(dual_move_raw, move_last);
wire [3:0] dual_fire = last_wins(dual_fire_raw, fire_last);

// Light-gun crosshair Y, on whichever port has the gun.
// One gun. It goes on port 1 when port 1 is a light gun, whatever port 2
// is: Sentinel's header asks for a gun on both ports, and MiSTer's choice of
// port 2 then left the gun on controller 2 and port 1 a joystick.
wire       gun_port = (portb_type == 8'd2) && (porta_type != 8'd2);  // 0: port 1, 1: port 2
wire       gun_en   = (porta_type == 8'd2) || gun_port;
wire [15:0] gun_joy = gun_port ? joyb : joya;
wire  [7:0] gun_y;
virtual_axis gun_axis_y (
	.clk      (clk_sys),
	.reset    (cart_download),
	.tick     (ms_tick),
	.neg      (gun_joy[3]),
	.pos      (gun_joy[2]),
	.slow     (gun_joy[11]),
	.fast     (gun_joy[12]),
	.analog   (gun_port ? ana_b[15:8] : ana_a[15:8]),
	.position (gun_y),
	.phase    ()
);
wire [7:0] gun_ax = gun_port ? vx_pos[1] : vx_pos[0];

// lightgun.sv's joystick mode (JOY_X/Y offset by 128) puts the crosshair
// 1.5 x X pixels across and Y - 8 lines down, so scale the 0..255 axes to the
// picture: 372, 320 or 160 pixels wide and 224 to 247 lines tall (a PAL
// picture is taller, and its bottom lines are out of the gun's reach).
wire [7:0] gun_kx = tia_en ? 8'd107 : hide_border ? 8'd213 : 8'd248;
wire [7:0] gun_ky = video_pal_o ? 8'd248 : tia_en ? 8'd240 : (show_overscan ? 8'd242 : 8'd224);
wire [15:0] gun_mx = gun_ax * gun_kx;
wire [15:0] gun_my = gun_y * gun_ky;
wire [7:0] gun_x  = gun_mx[15:8];
wire [7:0] gun_yl = gun_my[15:8] + 8'd8;

// Paddles: MiSTer's paddle_timer charges the pot line to the position, with
// the same polarity as its analog path (right = lower resistance).
wire [3:0] paddle_en = {(portb_type == 8'd3) ? 2'b11 : 2'b00, (porta_type == 8'd3) ? 2'b11 : 2'b00};
wire [3:0] pad_wire;
generate
	for (vi = 0; vi < 4; vi = vi + 1) begin : paddle
		paddle_timer pt (
			.clk        (clk_sys),
			.ce         (1'b1),
			.reset      (reset || ~paddle_en[vi]),
			.kohms      ({2'b00, ~vx_pos[vi]}),
			.clear      (~iout[1]),
			.read       (i_read[vi]),
			.charged    (pad_wire[vi]),
			.difference ()
		);
	end
endgenerate

// Driving controller: the gray code Stella uses (3, 1, 0, 2 turning right),
// on the up (bit 0) and down (bit 1) lines.
function [1:0] drive_gray(input [1:0] q);
	case (q)
		2'd0: drive_gray = 2'd3;
		2'd1: drive_gray = 2'd1;
		2'd2: drive_gray = 2'd0;
		2'd3: drive_gray = 2'd2;
	endcase
endfunction
wire [1:0] drive_a = drive_gray(vx_phase[0][15:14]);
wire [1:0] drive_b = drive_gray(vx_phase[1][15:14]);

// Light gun, MiSTer's lightgun.sv driven like its joystick mode.
wire gun_target, gun_sensor, gun_trigger;
lightgun lightgun (
	.CLK          (clk_sys),
	.RESET        (reset),
	.MOUSE        (25'd0),
	.MOUSE_XY     (1'b0),
	.LIGHT        (|core_r[7:4] || |core_g[7:4] || |core_b[7:4]),
	.H_WIDTH      (tia_en ? 10'd160 : (hide_border ? 10'd320 : 10'd372)),
	.JOY_X        ({~gun_x[7], gun_x[6:0]}),
	.JOY_Y        ({~gun_yl[7], gun_yl[6:0]}),
	.JOY_TRIG     (gun_port ? vbutton[1] : vbutton[0]),
	.HDE          (~HBlank),
	.VDE          (~VBlank_orig),
	.CE_PIX       (ce_pix),
	.BTN_MODE     (1'b0),
	.SIZE         (2'd1),
	.SENSOR_DELAY (tia_en ? 8'd20 : 8'd48),
	.LINE_DELAY   (tia_en ? 8'd1 : 8'd20),
	.TARGET       (gun_target),
	.SENSOR       (gun_sensor),
	.TRIGGER      (gun_trigger)
);

// The crosshair, drawn over the picture in red, as on MiSTer.
assign R = (gun_en & gun_target) ? 8'd255 : core_r;
assign G = (gun_en & gun_target) ? 8'd0   : core_g;
assign B = (gun_en & gun_target) ? 8'd0   : core_b;

always @(*) begin
	// P2 F1, P2 F2, P1 F1, P1 F2
	idump = tia_en ? {(|portb_type ? 1'b0 : ~joyb[5]), 1'd0, (|porta_type ? 1'b0 : ~joya[5]), 1'd0} :
		{joyb[4], joyb[5], joya[4], joya[5]};
	pa_in_r[7:4] = {~joya[0], ~joya[1], ~joya[2], ~joya[3]}; // P1: R L D U
	pa_in_r[3:0] = {~joyb[0], ~joyb[1], ~joyb[2], ~joyb[3]}; // P2: R L D U
	ilatch[0] = tia_en ? ~joya[4] : ~(joya[4] || joya[5]);    // P1 Fire
	ilatch[1] = tia_en ? ~joyb[4] : ~(joyb[4] || joyb[5]);    // P2 Fire

	case (porta_type)
		8'd0: begin pa_in_r[7:4] = 4'b1111; ilatch[0] = 1'b1; idump[1:0] = 2'b00; end
		8'd2: if (~gun_port) begin pa_in_r[7:4] = {3'b111, gun_trigger}; ilatch[0] = ~gun_sensor; idump[1:0] = 2'b00; end
		8'd3: begin pa_in_r[7:4] = {~vbutton[0], ~vbutton[1], 2'b11}; idump[1:0] = pad_wire[1:0]; ilatch[0] = 1'b1; end
		8'd6: begin pa_in_r[7:4] = {2'b11, drive_a}; ilatch[0] = ~vbutton[0]; idump[1:0] = 2'b00; end
		// Booster Grip: its trigger (B) on INPT1 and booster (X) on INPT0
		8'd9: idump[1:0] = {joya[10], joya[11]};
		default: ;
	endcase
	case (portb_type)
		8'd0: begin pa_in_r[3:0] = 4'b1111; ilatch[1] = 1'b1; idump[3:2] = 2'b00; end
		8'd2: if (gun_port) begin pa_in_r[3:0] = {3'b111, gun_trigger}; ilatch[1] = ~gun_sensor; idump[3:2] = 2'b00; end
		8'd3: begin pa_in_r[3:0] = {~vbutton[2], ~vbutton[3], 2'b11}; idump[3:2] = pad_wire[3:2]; ilatch[1] = 1'b1; end
		8'd6: begin pa_in_r[3:0] = {2'b11, drive_b}; ilatch[1] = ~vbutton[1]; idump[3:2] = 2'b00; end
		8'd9: idump[3:2] = {joyb[10], joyb[11]};
		default: ;
	endcase

	if (dual_stick) begin
		pa_in_r = ~{dual_move[0], dual_move[1], dual_move[2], dual_move[3],
		            dual_fire[0], dual_fire[1], dual_fire[2], dual_fire[3]};
		ilatch  = 2'b11;
		idump   = 4'b0000;
	end

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
wire [7:0] core_r, core_g, core_b;

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
	.RED          (core_r),
	.GREEN        (core_g),
	.BLUE         (core_b),
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
	// PAL ignores Show Overscan: its 274 line window already holds the whole
	// picture, and the Pocket has no scaler slot left for 292 lines (the APF
	// allows 8 modes; see core_top.v).
	.show_overscan(show_overscan & ~region_select),
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
	// MiSTer's Bankswitching menu: its index is the mapper number.
	.force_bs     (|bs_override ? {1'b0, bs_override} : force_bs),
	.mapper_revision,
	.cdf_ldx,
	.cdf_ldy,
	.cdf_fetch_offset_enable,
	.cdf_fetch_offset,
	.cdfj_entry,
	.cdfj_stack,
	.arm_audio_size_addr,
	.sc           (sc),
	.clearval     (clear_random ? rnd[7:0] : 8'h00),
	.random       (rnd[7:0]),
	.decomb       (decomb),
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
