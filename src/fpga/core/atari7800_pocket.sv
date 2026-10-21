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
// controller, which runs on clk_sdram (exactly 4 x clk_sys, phase aligned),
// and with POCKET_BUPCHIP the BupChip and its PSRAM controller, on clk_arm
// (exactly 2 x clk_sys, phase aligned; with POCKET_DARIA VCO/18, 38.18 MHz,
// from the same VCO, so 8 clk_arm to 3 clk_sys: pll/pll_core.v). The DARIA
// front end (POCKET_DARIA, daria_fe below) runs on clk_sys, but for one
// clk_arm flop of its guard.
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
`ifdef POCKET_BUPCHIP
	input  wire        clk_arm,         // the BupChip: 2 x clk_sys, edge aligned; VCO/18 with POCKET_DARIA
`endif
	input  wire        pll_locked,
	input  wire        pll_busy,        // clk_74a: PLL retune (PAL/NTSC) in progress
	input  wire        reset_in,        // host reset / menu reset, clk_sys

	// Download stream (clk_sys, one clk_sys cycle per byte)
	input  wire        cart_download,
	input  wire        bios_download,
	input  wire        hscfw_download,  // high score cart firmware (4 KiB, optional A78 header)
	input  wire        arfw_download,   // Supercharger BIOS (2 KiB)
`ifdef POCKET_BUPCHIP
	input  wire        bupfw_download,  // BupChip firmware, bupchip.bin (up to 16 KiB)
	input  wire        ioctl_wr_any,    // every loader byte, whatever slot flag is up (BupChip)
	input  wire  [2:0] ioctl_hi,        // bits 27:25 of its bridge address (BupChip)
`endif
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
	input  wire  [1:0] atarivox_setting, // AtariVox voice: 0 off, 1 quiet, 2 normal, 3 loud
	input  wire [12:0] sk_bridge_addr,  // 32 bit word address
	input  wire        sk_bridge_wr,
	input  wire        sk_bridge_rd,    // APF read strobe for this region
	input  wire [31:0] sk_bridge_din,   // big endian: [31:24] is the lowest byte
	output wire [31:0] sk_bridge_dout,  // word latched at the last read strobe

	// FA2 cartridge flash (256 bytes), second port for its save slot (clk_74a)
	input  wire  [5:0] fa2_bridge_addr, // 32 bit word address
	input  wire        fa2_bridge_wr,
	input  wire        fa2_bridge_rd,   // APF read strobe for this region
	input  wire [31:0] fa2_bridge_din,  // big endian: [31:24] is the lowest byte
	output wire [31:0] fa2_bridge_dout, // word latched at the last read strobe

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
	output wire        SDRAM_CKE,

`ifdef POCKET_BUPCHIP
	// PSRAM cram0 (AS1C8M16PL-70): the BupChip's music assets on die 0,
	// through agg23's psram.sv
	output wire [21:16] cram0_a,
	inout  wire [15:0] cram0_dq,
	input  wire        cram0_wait,
	output wire        cram0_clk,
	output wire        cram0_adv_n,
	output wire        cram0_cre,
	output wire        cram0_ce0_n,
	output wire        cram0_ce1_n,
	output wire        cram0_oe_n,
	output wire        cram0_we_n,
	output wire        cram0_ub_n,
	output wire        cram0_lb_n,

`endif
	// SRAM (AS6C2016-55, 128K x 16): cartridge RAM, Flicker Blend frame,
	// SaveKey and BIOS in POCKET_SRAM builds, idle otherwise
	output wire [16:0] SRAM_A,
	inout  wire [15:0] SRAM_DQ,
	output wire        SRAM_OE_N,
	output wire        SRAM_WE_N,
	output wire        SRAM_UB_N,
	output wire        SRAM_LB_N
);

//////////////////////////////  RESET  ////////////////////////////////////

reg old_cart_download = 1'b0;
wire mapper_init_busy;
reg reset;
reg [1:0] pll_busy_s = 2'b00;
`ifdef POCKET_BUPCHIP
wire bupfw_dl = bupfw_download;
`else
wire bupfw_dl = 1'b0;
`endif

`ifdef POCKET_DARIA
// DARIA (docs/daria_step7/plan.md P6, P20; the wires are under DARIA below).
// daria_hold: the front end's init_busy, which covers its RAM image (F6),
// holds the console only for an ARM image, so every other load releases on
// the same edge as in a build without DARIA. daria_rt_hold: a PLL retune
// (pll_busy) keeps an ARM image's console in reset for 16 clk_sys past
// pll_busy_s[1]'s fall. daria_fe's cart_reset is masked (daria_rt_mask,
// below) while pll_busy_s[1] is high and for the first 4 clk_sys after it
// falls, so its one rise comes with clk_sys running and no retune under
// way, and F6 starts 8 clocks after it; init_busy holds the console from
// the clock after the rise, inside the 16. The 4 clocks cover a retune that
// follows another at once (pll_region starts again on the next clk_74a when
// the region changed meanwhile): pll_busy_s can see that one clk_74a low as
// one clk_sys low, which unmasked would be a rise, and F6 would then run
// into the second retune. F6 never runs while the PLL is retuned, and no
// other front-end write reaches its RAMs then (daria_we_ok, below). Nor
// does a retune start while F6 runs, or F6 while one is pending: pll_region
// starts a retune only when no load sequence is in progress, so one asked
// for during a sequence waits for its end (core_top.v's is_downloading),
// and daria_rt_pend (below, with region_pll) marks it pending until it
// ends. While it is pending, cart_reset is masked too, and a console reset
// of an ARM image lasts until the retune, so F6 runs once, after it.
wire       daria_hold, daria_arm, daria_rt_pend;
/* verilator lint_off PROCASSINIT */
reg        daria_rt_hold = 1'b0;
reg  [3:0] daria_rt_cnt = 4'd0;
/* verilator lint_on PROCASSINIT */
always @(posedge clk_sys) begin
	daria_rt_hold <= pll_busy_s[1] | (daria_rt_cnt != 4'd0);
	if (pll_busy_s[1])
		daria_rt_cnt <= 4'd15;
	else if (daria_rt_cnt != 4'd0)
		daria_rt_cnt <= daria_rt_cnt - 4'd1;
end
`endif

always @(posedge clk_sys) begin
	old_cart_download <= cart_download;
	pll_busy_s <= {pll_busy_s[0], pll_busy};
`ifdef POCKET_DARIA
	reset <= reset_in | cart_download | bios_download | hscfw_download |
		arfw_download | bupfw_dl | old_cart_download | mapper_init_busy | ~pll_locked |
		pll_busy_s[1] | daria_hold | (daria_rt_hold & daria_arm) |
		(daria_rt_pend & reset & daria_arm);
`else
	reset <= reset_in | cart_download | bios_download | hscfw_download |
		arfw_download | bupfw_dl | old_cart_download | mapper_init_busy | ~pll_locked |
		pll_busy_s[1];
`endif
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

`ifdef POCKET_DARIA
////////////////////////////  DARIA  //////////////////////////////////////
// The 2600 ARM cartridges (DPC+, CDF, CDFJ, CDFJ+) on the DARIA front end
// (core/bupchip/daria_fe.sv, u_fe below) and the BupChip's CPU in its 2600
// profile (bupchip, below). docs/DARIA_CORE.md; docs/daria_step7/plan.md 2.
//
// daria_fbs is the bankswitching the core runs (main's force_bs, below:
// the menu's override, else detect2600's). The front end's scheme is it
// only while tia_mode, a register, says a 2600 image is loaded, so an A78
// with the override set never starts it (P5). The profile is the same
// condition registered; daria_ram32 is top.sv's mapper_ram_size == 32768.
// bupchip's level inputs come from clk_sys registers, so that its first
// clk_arm flops sample one register each (P21): daria_ram32_r, and
// daria_mres_r for the mapper reset (top.sv's effective_reset, an OR of
// two registers).
wire  [5:0] daria_fbs    = |bs_override ? {1'b0, bs_override} : force_bs;
wire  [5:0] daria_scheme = tia_mode ? daria_fbs : 6'd0;
wire        daria_ram32  = daria_fbs == 6'd23 && mapper_revision == 3'd3;
assign      daria_arm    = daria_scheme == 6'd21 || daria_scheme == 6'd23;
wire        daria_reset;                     // main's effective_reset
/* verilator lint_off PROCASSINIT */
reg         daria_profile = 1'b0;
reg         daria_ram32_r = 1'b0;
reg         daria_mres_r  = 1'b1;
/* verilator lint_on PROCASSINIT */
always @(posedge clk_sys) begin
	daria_profile <= tia_mode && (daria_fbs == 6'd21 || daria_fbs == 6'd23);
	daria_ram32_r <= daria_ram32;
	daria_mres_r  <= daria_reset;
end

// The front end's side of the system module and of the BupChip
wire [12:0] daria_a_in;
wire        daria_pclk0, daria_pclk1, daria_access;
wire  [7:0] daria_fe_do;
wire        daria_fe_oe, daria_call_busy, daria_dma_busy, daria_init_busy;
wire        daria_call_tog, daria_ret_tog, daria_ready, daria_cart_win;
wire        daria_smp_req, daria_smp_ack;
wire [18:0] daria_smp_addr;
wire  [7:0] daria_smp_data;
wire [12:0] daria_fea_addr, daria_feb_addr, daria_crb_addr;
wire [31:0] daria_fea_q, daria_feb_q, daria_crb_q, daria_crb_wd, daria_stb_q, daria_stb_wd;
wire        daria_crb_we, daria_stb_we;
wire  [3:0] daria_crb_be, daria_stb_be;
wire  [7:0] daria_stb_addr;
`ifdef BUP_DEBUG
wire        daria_dbg_locked, daria_dbg_unlock;   // u_fe's P22 exports, for the overlay
`endif
assign      daria_hold = daria_init_busy & daria_arm;

// P20 for the front end's other writes: none reaches cart RAM or state RAM
// (bupchip's port B write enables) while pll_busy_s[1] is high, unless F6
// runs. A DPC+ copy or fill that the 6507 started just before pll_busy
// rose runs on with the console in reset, a few hundred clk_sys for a
// long copy against the about 50 between pll_busy and the PLL's stop, so
// it would write while the clocks stop. The retune's F6 rewrites all of
// the cart RAM and clears the front end's state RAM words ($00-$1F), as at
// power-up, so a dropped write is never missed (the 6507, held in reset,
// posts no call). F6 itself (init_busy) is not gated: it never meets a
// retune, as none is pending or under way when F6 starts and none can be
// asked for while it runs (daria_rt_pend, region_pll), and a retune starts
// F6 only after it ends (daria_rt_mask).
wire        daria_we_ok = ~pll_busy_s[1] | daria_init_busy;
`endif

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

// The "no cartridge" image MiSTer boots into when nothing is loaded. The
// Pocket's cartridge slot is required, so the core never runs without a
// cartridge and the image is never seen: POCKET_SRAM builds leave it out
// (16 block RAMs). sim/tb_system runs its test programs from this image, so
// the simulation keeps it (KEEP_NOCART_ROM).
`ifdef POCKET_SRAM
`ifndef KEEP_NOCART_ROM
`define NO_NOCART_ROM
`endif
`endif
`ifdef NO_NOCART_ROM
assign cart_data_rom = 8'hFF;
`else
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
`endif

// The 7800 BIOS is 4 KiB (NTSC) or 16 KiB (PAL); the mask mirrors it.
// POCKET_SRAM builds keep it in the SRAM (sram_ctrl, below).
`ifndef POCKET_SRAM
spram #(.addr_width(14), .mem_name("BIOS")) bios
(
	.address (bios_download ? ioctl_addr[13:0] : (bios_addr[13:0] & bios_mask[13:0])),
	.clock   (clk_sys),
	.data    (ioctl_dout),
	.wren    (ioctl_wr & bios_download),
	.cs      (1'b1),
	.q       (bios_data)
);
`endif

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


/* verilator lint_off UNUSEDSIGNAL */
wire  [7:0] PAout;                  // [3:2] SaveKey, [0] AtariVox; the rest unused
/* verilator lint_on UNUSEDSIGNAL */
wire        sk_sda;
wire  [7:0] sk_ram_q, sk_ram_d;
wire [14:0] sk_ram_addr;
wire        sk_ram_wr, sk_ram_rd, sk_ram_done;

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
	.ram_read       (sk_ram_rd),
	.ram_write      (sk_ram_wr),
	.ram_done       (sk_ram_done)
);

`ifdef POCKET_SRAM
// The SaveKey image lives in the SRAM. The EEPROM model holds ram_read or
// ram_write until ram_done; one toggle asks sram_ctrl, its toggle answers.
reg  sk_req = 1'b0, sk_pend = 1'b0;
wire sk_ack;
assign sk_ram_done = sk_pend && (sk_ack == sk_req);
always @(posedge clk_sys) begin
	if (sk_ram_done)
		sk_pend <= 1'b0;
	else if ((sk_ram_rd | sk_ram_wr) && !sk_pend) begin
		sk_pend <= 1'b1;
		sk_req <= ~sk_req;
	end
end
`else
assign sk_ram_done = 1'b1;
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
`endif

// FA2 flash: the 256 bytes an FA2 cartridge (Star Castle Arcade) keeps in its
// flash. mapper_fa2.sv copies its work RAM to and from them through the
// fa2_nvram_* port, a byte per request/ready handshake. Upstream's
// fa2_nvram_bridge.sv answers the handshake, as on MiSTer, from a save_ram_dp
// whose other port is the fa2.sav save slot: one shared file for every FA2
// game, like hsc.sav. A new file is blank as $FF, as an erased flash (the
// unconnected port this replaces read $FF too). The Pocket writes the file in
// before the core runs, so the bridge never waits for a load, and it writes
// every save slot back itself, so the mapper's dirty pulse has no use here.
// The port is on only in 2600 mode (fa2_on: tia_mode, set at the end of a
// load that is no A78). detect2600.sv classifies every image, A78s too, and
// takes some A78 payloads for FA2 (24 or 28 KiB, or 32 KiB with a zero
// tail); cart2600.sv then runs mapper_fa2.sv, which in 7800 mode still sees
// the bus, so a 7800 game's accesses to $x0FF and $xFF4 could start a save
// and write junk over the shared file. With fa2_on low the bridge sees no
// request and the mapper gets the answers of the unconnected port this
// replaces (ready 1, $FF), so it finishes any copy without touching the slot.
wire       fa2_on = tia_mode;
wire       fa2_req, fa2_we, fa2_rdy, fa2_ram_we;
wire [7:0] fa2_addr, fa2_wdata, fa2_rdata, fa2_ram_addr, fa2_ram_d, fa2_ram_q;
/* verilator lint_off UNUSEDSIGNAL */
wire       fa2_ram_cs;                  // the bridge's select; save_ram_dp has none
/* verilator lint_on UNUSEDSIGNAL */

fa2_nvram_bridge fa2_bridge
(
	.clk                (clk_sys),
	.reset              (reset),
	.new_image          (1'b0),
	.backing_busy       (1'b0),
	.file_load_complete (1'b1),
	.request            (fa2_req & fa2_on),
	.write              (fa2_we),
	.addr               (fa2_addr),
	.wdata              (fa2_wdata),
	.ready              (fa2_rdy),
	.rdata              (fa2_rdata),
	.backing_rdata      (fa2_ram_q),
	.backing_cs         (fa2_ram_cs),
	.backing_write      (fa2_ram_we),
	.backing_addr       (fa2_ram_addr),
	.backing_wdata      (fa2_ram_d)
);

save_ram_dp #(.WORD_ADDR_BITS(6), .BLANK(8'hFF)) fa2_ram
(
	.clk_a  (clk_sys),
	.addr_a (fa2_ram_addr),
	.din_a  (fa2_ram_d),
	.we_a   (fa2_ram_we),
	.dout_a (fa2_ram_q),

	.clk_b  (clk_74a),
	.addr_b (fa2_bridge_addr),
	.din_b  (fa2_bridge_din),
	.we_b   (fa2_bridge_wr),
	.rd_b   (fa2_bridge_rd),
	.dout_b (fa2_bridge_dout)
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

// The D-pad and docked analog sticks become positions (virtual_axis5.sv).
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
wire [15:0] vx_phase [2];   // driving: ports 1 and 2 only
wire  [3:0] vbutton;
genvar vi;
generate
	for (vi = 0; vi < 4; vi = vi + 1) begin : vaxis
		// joy bits: 0 R, 1 L, 2 D, 3 U, 9 A, 10 B, 11 X, 12 Y
		assign vbutton[vi] = vjoy[vi][9] | vjoy[vi][10];
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

// The four controllers' axes (0-3) and the gun's Y (4), as one time-shared
// engine (virtual_axis5.sv): axis k updates k clk_sys after ms_tick.
wire [39:0] vx_position;
wire [31:0] vx_phase01;
virtual_axis5 vaxes (
	.clk      (clk_sys),
	.reset    (cart_download),
	.tick     (ms_tick),
	.neg      ({gun_joy[3],  vjoy[3][1],  vjoy[2][1],  vjoy[1][1],  vjoy[0][1]}),
	.pos      ({gun_joy[2],  vjoy[3][0],  vjoy[2][0],  vjoy[1][0],  vjoy[0][0]}),
	.slow     ({gun_joy[11], vjoy[3][11], vjoy[2][11], vjoy[1][11], vjoy[0][11]}),
	.fast     ({gun_joy[12], vjoy[3][12], vjoy[2][12], vjoy[1][12], vjoy[0][12]}),
	.analog   ({gun_port ? ana_b[15:8] : ana_a[15:8], vana[3][7:0], vana[2][7:0], vana[1][7:0], vana[0][7:0]}),
	.position (vx_position),
	.phase    (vx_phase01)
);
assign vx_pos[0]   = vx_position[7:0];
assign vx_pos[1]   = vx_position[15:8];
assign vx_pos[2]   = vx_position[23:16];
assign vx_pos[3]   = vx_position[31:24];
assign gun_y       = vx_position[39:32];
assign vx_phase[0] = vx_phase01[15:0];
assign vx_phase[1] = vx_phase01[31:16];
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

// The crosshair, drawn over the picture in red, as on MiSTer. (BUP_DEBUG
// builds draw the BupChip's status over that; see the end of the module.)
wire [7:0] pic_r = (gun_en & gun_target) ? 8'd255 : core_r;
wire [7:0] pic_g = (gun_en & gun_target) ? 8'd0   : core_g;
wire [7:0] pic_b = (gun_en & gun_target) ? 8'd0   : core_b;

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
// With the AtariVox's voice on, PA1 (port 2 DOWN) also reads its "buffer
// half full" line, low while it holds 32 bytes or more.
`ifdef POCKET_ATARIVOX
wire vox_down_n;
wire pa1_in = pa_in_r[1] & vox_down_n;
`else
wire pa1_in = pa_in_r[1];
`endif
assign PAin = use_sk ? {pa_in_r[7:3], sk_sda, pa1_in, pa_in_r[0]} : pa_in_r;


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
// load. The latch alone does not keep a PAL 2600 game in PAL: while the
// console is in reset (tia_en low, as through every retune) Auto reads
// cart_region[0] instead. The PLL is therefore asked for region_pll (below),
// which holds a 2600 image's region through its console resets.
reg tia_pal_seen = 1'b0;
always @(posedge clk_sys)
	if (cart_download)
		tia_pal_seen <= 1'b0;
	else if (tia_pal)
		tia_pal_seen <= 1'b1;

wire region_select = (region_setting == 2'd0) ?
	(tia_en ? (tia_pal | tia_pal_seen) : cart_region[0]) : (region_setting == 2'd2);

// The region asked of the PLL (is_pal_o, core_top.v's pll_region, whose
// retune holds the console in reset through pll_busy). It follows
// region_select a clock later, but is held while a 2600 image's region is not
// known: during its download (once the header shows no A78) and the clock
// after it, and while its console is in reset (tia_mode, tia_en low).
// Unheld, region_select falls to cart_region[0] whenever a 2600 image's
// console is in reset: 0 (cleared at the image's end), or the image's byte
// 57 during its download. A PAL game's own retune, whose reset outlasts it,
// would then ask for NTSC, that retune's reset for PAL again, and so on
// without end; and a load's end could start a retune to a stale byte 57's
// region. An A78 is not held: its region follows its header. A Region
// setting changed while a 2600 image's console is in reset reaches the PLL
// when it is released. A register, so that is_pal_o leaves clk_sys without
// glitches (pll_region samples it on clk_74a).
/* verilator lint_off PROCASSINIT */
reg region_pll = 1'b0;
/* verilator lint_on PROCASSINIT */
wire region_pll_hold = ((cart_download | old_cart_download) & ~cart_is_7800) | (tia_mode & ~tia_en);
`ifdef POCKET_DARIA
// DARIA (P20; the D review's finding 3). pll_region starts a retune only
// while no load sequence is in progress (its loading input, core_top.v's
// is_downloading, high from a slot's requestwrite to allcomplete, across
// every slot), so a region asked for during a sequence waits for the
// sequence's end, which can come at any time, during an F6 too. daria_rgn
// is the region of the PLL's last completed retune (pll_region's pll_pal,
// on clk_sys: region_pll, taken on the clock after pll_busy_s[1] falls),
// and daria_rt_pend marks a retune asked for and not yet completed. For
// daria_rgn to be exact, region_pll changes only when none is pending or
// under way, except in an A78's header and in the withdrawal (below), where
// pll_region cannot start one; so each retune is to the one region asked
// for since the last, and pll_region never starts a second one as the first
// ends. region_pll is
// - frozen while pll_busy_s[1] is high or a retune is pending, except in an
//   A78's header (below);
// - frozen while an ARM image's console is in reset (daria_reset), so that
//   it never changes on the clock where daria_fe sees a reset rise (tia_en,
//   which region_pll_hold reads, falls a clock after the reset rises) or
//   while F6 runs; a 2600 image's region is held then anyway;
// - withdrawn, set to daria_rgn, while a 2600 image downloads (when
//   region_pll_hold holds it anyway): a retune still pending from earlier
//   in the sequence (a region change while the console ran between slots)
//   would otherwise start at allcomplete, inside the F6 that the window's
//   close starts at the download's end. pll_region's loading is high from
//   the slot's requestwrite, 4 clk_sys before cart_download, so it starts
//   nothing as region_pll returns to the PLL's region; the image's own
//   region is asked for when its console is released, on P20's mid-game
//   path, which runs F6 again after the retune. The withdrawal takes
//   daria_rgn's next value (daria_rgn_nx): on the clock where a retune
//   ends, daria_rgn's old value is the region the PLL has just left, and
//   region_pll would ask for it for one clk_sys, which a load sequence
//   that ends on that clock would turn into two more retunes (RTL-2);
// - free to follow region_select in an A78's 128-byte header, even with a
//   retune pending (RTL-1): Auto reads cart_region[0] there, which keeps
//   the last image's region (0 after a 2600 image) until byte 57 sets the
//   A78's own, so a retune asked for in the header from the stale region
//   would otherwise be held, run at the load's end, and be followed by one
//   back. pll_region starts nothing in the header: loading is high until
//   allcomplete, after the image's last byte, and the last clk_sys of a
//   download, where cart_download outlives loading, are past the header,
//   where region_pll is frozen as before. That assumes an A78 longer than
//   its 128-byte header: in one of 128 bytes or less, ioctl_addr stays
//   below 128 through those clocks, and a Region setting changed in them
//   (about 4 clk_sys) could give the back-to-back retune of the first
//   sketch (tb_region's scenario C). No real image is that short.
// So no retune is pending or under way when F6 starts (daria_rt_mask keeps
// cart_reset low while one is, and a window-close F6 follows a withdrawal),
// and none can become pending while F6 runs: no retune starts inside F6.
// daria_rgn is also bupchip's daria_pal (daria_mmio's timer rate, below):
// the region clk_sys runs at. It changes only on the clock after a retune
// ends, with the console, and so daria_mmio, still in reset.
/* verilator lint_off PROCASSINIT */
reg  daria_rgn = 1'b0;
/* verilator lint_on PROCASSINIT */
assign daria_rt_pend = region_pll != daria_rgn;
wire daria_rgn_nx  = (!pll_busy_s[1] && daria_rt_cnt == 4'd15) ? region_pll : daria_rgn;
wire daria_a78_hdr = cart_download & cart_is_7800 & (ioctl_addr < 25'd128);
always @(posedge clk_sys) begin
	daria_rgn <= daria_rgn_nx;
	if (!pll_busy_s[1]) begin
		if ((cart_download | old_cart_download) & ~cart_is_7800)
			region_pll <= daria_rgn_nx;
		else if (!region_pll_hold && (!daria_rt_pend || daria_a78_hdr) && !(daria_reset & daria_arm))
			region_pll <= region_select;
	end
end

// daria_fe's cart_reset mask (P20, above): pll_busy_s[1], the 4 clk_sys after
// it falls, and while a retune is pending: pll_region can start it on any
// clk_74a once no load sequence is in progress, and pll_busy_s[1] shows it
// only about 3 clk_sys later.
wire daria_rt_mask = pll_busy_s[1] | (daria_rt_cnt[3:2] == 2'b11) | daria_rt_pend;
`else
always @(posedge clk_sys)
	if (!region_pll_hold)
		region_pll <= region_select;
`endif

`ifdef POCKET_ATARIVOX
// The AtariVox's voice (docs/ATARIVOX.md): the SpeakJet's serial input on
// PA0 (port 2 UP) and our speech engine. It is part of the AtariVox, so it
// is there whenever the SaveKey is (use_sk) and the voice setting is not
// Off. A console reset leaves it running, as the real one, powered from the
// port; a cart load resets it.
wire vox_on = use_sk && (atarivox_setting != 2'd0);
wire signed [15:0] vox_sample;
atarivox atarivox (
	.clk    (clk_sys),
	.reset  (reset_in | cart_download | ~vox_on),
	.pal    (region_pll),
	.line   (PAout[0]),
	.down_n (vox_down_n),
	.sample (vox_sample)
);

// Mixed into both channels: x4 (Quiet), x8 (Normal), x16 (Loud). The voice
// peaks near +-2,000 at the chip's full volume, against a TIA channel's
// 0-21,844 square wave, so x4 sits well under the game and x8 about level
// with it on hardware. Limited to +-32,767 on a +32,768 bias (the output
// filter removes the DC) while on; the sum saturates.
wire signed [19:0] vox_gain = (atarivox_setting == 2'd3) ? (20'(vox_sample) <<< 4) :
                              (atarivox_setting == 2'd2) ? (20'(vox_sample) <<< 3) : (20'(vox_sample) <<< 2);
wire signed [15:0] vox_lim  = (vox_gain > 20'sd32767) ? 16'sd32767 :
                              (vox_gain < -20'sd32767) ? -16'sd32767 : vox_gain[15:0];
wire        [17:0] vox_add  = vox_on ? 18'(18'(vox_lim) + 18'sd32768) : 18'd0;
wire        [15:0] core_audio_l, core_audio_r;
wire        [17:0] mix_l = 18'(core_audio_l) + vox_add;
wire        [17:0] mix_r = 18'(core_audio_r) + vox_add;
assign AUDIO_L = |mix_l[17:16] ? 16'hFFFF : mix_l[15:0];
assign AUDIO_R = |mix_r[17:16] ? 16'hFFFF : mix_r[15:0];
`endif

reg [15:0] rnd = 16'h5A5A;
always @(posedge clk_sys) rnd <= {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};

wire VBlank_orig;
wire [7:0] core_r, core_g, core_b;

// The BIOS runs only when one is loaded and Skip BIOS is off, and then only
// for a 7800 image or for an empty slot. A 2600 image always starts
// directly, as with Skip BIOS on (docs/DARIA_CORE.md, decision 11). A
// console's BIOS recognises a 2600 cartridge by a bus clash: the cartridge
// decodes only A0-A12, so it also answers at $1BEA, and RAM written there
// does not read back. The core does not model that clash, so the BIOS
// decides from its later tests, and for some images (DPC+ revision 1,
// CDFJ+) it never starts the 2600 game
// (docs/daria_fe/lanes/G_step7_resets.md, 8.8). MiSTer's wrapper
// (Atari7800.sv) is different: with Bypass Bios set to No it runs the BIOS
// for 2600 images too, giving top.sv tia_mode 0 and bypass_bios 0.
// tia_mode is 0 during a load and settles at its end while old_cart_download
// still holds the core in reset, so bypass_bios and top.sv's tia_mode
// change together, before the reset is released.
wire use_bios = bios_loaded & ~skip_bios & ~tia_mode;

// SRAM side of the system module (POCKET_SRAM)
wire [17:0] cartram_addr;
wire        cartram_wr, cartram_rd;
wire  [7:0] cartram_wrdata, sram_c_rdata;
`ifdef POCKET_SRAM
/* verilator lint_off UNUSEDSIGNAL */
wire [17:0] cartram_addr26;                // the 2600 request (Fix B); [17] unused
/* verilator lint_on UNUSEDSIGNAL */
wire        cartram_wr26, cartram_rd26;
wire  [7:0] cartram_wrdata26;
`endif
wire        mclk1, bios_sel;
wire [15:0] fb_addr;
wire        fb_we, fb_active;
wire  [7:0] fb_wdata, fb_q;

`ifdef POCKET_BUPCHIP
// The BupChip's side of the system module (POCKET_BUPCHIP; see BUPCHIP below)
wire        bup_cmd_valid, souper_profile;
wire  [7:0] bup_cmd_data;
wire [15:0] bup_audio_l, bup_audio_r;
`endif

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
`ifdef POCKET_DARIA
	.loading      (cart_download || bios_download || mapper_init_busy || daria_hold),
`else
	.loading      (cart_download || bios_download || mapper_init_busy),
`endif
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
`ifdef POCKET_DARIA
	.cpu_ce       (daria_pclk1),
`else
	.cpu_ce       (),
`endif

	// Audio
`ifdef POCKET_ATARIVOX
	.AUDIO_R      (core_audio_r),
	.AUDIO_L      (core_audio_l),
`else
	.AUDIO_R      (AUDIO_R),
	.AUDIO_L      (AUDIO_L),
`endif

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

`ifdef POCKET_SRAM
	// Cartridge RAM lives in the SRAM (EXTERNAL_CARTRAM): the 7800 request
	// on cartram_*, the 2600 request on cartram_*26_out (Fix B)
	.cartram_addr   (cartram_addr),
	.cartram_wr     (cartram_wr),
	.cartram_rd     (cartram_rd),
	.cartram_wrdata (cartram_wrdata),
	.cartram_data   (sram_c_rdata),
	.cartram_addr26_out   (cartram_addr26),
	.cartram_wr26_out     (cartram_wr26),
	.cartram_rd26_out     (cartram_rd26),
	.cartram_wrdata26_out (cartram_wrdata26),
	.mclk1_out      (mclk1),
	.bios_sel_out   (bios_sel),
	.fb_addr        (fb_addr),
	.fb_we          (fb_we),
	.fb_wdata       (fb_wdata),
	.fb_active      (fb_active),
	.fb_q           (fb_q),
`else
	// Cartridge RAM lives inside top.sv (cart_ram_tdp)
	.cartram_addr   (),
	.cartram_wr     (),
	.cartram_rd     (),
	.cartram_wrdata (),
	.cartram_data   (8'hFF),
`endif

`ifdef POCKET_BUPCHIP
	// The Pocket's BupChip (below) in place of upstream's
	.bup_cmd_valid_o  (bup_cmd_valid),
	.bup_cmd_data_o   (bup_cmd_data),
	.souper_profile_o (souper_profile),
	.bup_audio_l_i    (bup_audio_l),
	.bup_audio_r_i    (bup_audio_r),
`endif
`ifdef NO_ARM_MAPPER
`ifdef POCKET_DARIA
	// The DARIA front end (u_fe, below) in place of the ARM mapper
	.daria_a_in_o      (daria_a_in),
	.daria_pclk0_o     (daria_pclk0),
	.daria_access_o    (daria_access),
	.daria_reset_o     (daria_reset),
	.daria_fe_do_i     (daria_fe_do),
	.daria_fe_oe_i     (daria_fe_oe),
	.daria_call_busy_i (daria_call_busy),
	.daria_dma_busy_i  (daria_dma_busy),
`endif
`endif

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
	.fa2_nvram_request(fa2_req),
	.fa2_nvram_write  (fa2_we),
	.fa2_nvram_addr   (fa2_addr),
	.fa2_nvram_wdata  (fa2_wdata),
	.fa2_nvram_rdata  (fa2_on ? fa2_rdata : 8'hFF),
	.fa2_nvram_ready  (fa2_on ? fa2_rdy : 1'b1),
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
	// Recompute the tape's checksums (MiSTer's "Fix Supercharger
	// Checksums", always on): converted images with every checksum 0
	// (Excalibur, Meteroid) then load, and a good image's are unchanged.
	.fix_sc_cs    (1'b1),

	// Palette loading (not used)
	.pal_load     (1'b0),
	.pal_addr     (10'd0),
	.pal_wr       (1'b0),
	.pal_data     (8'd0),
	.blend        (flicker_blend),
	.i_read       (i_read)
);

`ifdef POCKET_SRAM
// The BIOS answers MARIA's bus strobe like the cartridge RAM does: the SRAM
// serves it in the slot that starts there, and the bus takes the byte two
// clk_sys later, as it does from SDRAM.
wire bios_rd = mclk1 & bios_sel & RW;

sram_ctrl sram
(
	.clk          (clk_sdram),
	.clk_sys      (clk_sys),
	.sys_reset    (reset),
	.game_running (~reset & cart_loaded),
	.tia_mode     (tia_en),
	.mclk1        (mclk1),

	.c_rd         (cartram_rd | bios_rd),
	.c_wr         (cartram_wr),
	.c_bios       (bios_rd),
	.c_addr       (bios_rd ? {3'd0, bios_addr[13:0] & bios_mask[13:0]} : cartram_addr[16:0]),
	.c_wdata      (cartram_wrdata),
	.t_rd         (cartram_rd26),
	.t_wr         (cartram_wr26),
	.t_addr       (cartram_addr26[16:0]),
	.t_wdata      (cartram_wrdata26),
	.c_rdata      (sram_c_rdata),

	.fb_en        (fb_active),
	.fb_addr      (fb_addr),
	.fb_we        (fb_we),
	.fb_wdata     (fb_wdata),
	.fb_q         (fb_q),

	.sk_req       (sk_req),
	.sk_we        (sk_ram_wr),
	.sk_addr      (sk_ram_addr),
	.sk_wdata     (sk_ram_d),
	.sk_ack       (sk_ack),
	.sk_rdata     (sk_ram_q),

	.dl_wr        (ioctl_wr & bios_download),
	.dl_addr      (ioctl_addr[13:0]),
	.dl_data      (ioctl_dout),

	.clk_74a      (clk_74a),
	.br_wr        (sk_bridge_wr),
	.br_rd        (sk_bridge_rd),
	.br_addr      (sk_bridge_addr),
	.br_wdata     (sk_bridge_din),
	.br_rdata     (sk_bridge_dout),

	.sram_a       (SRAM_A),
	.sram_dq      (SRAM_DQ),
	.sram_oe_n    (SRAM_OE_N),
	.sram_we_n    (SRAM_WE_N),
	.sram_ub_n    (SRAM_UB_N),
	.sram_lb_n    (SRAM_LB_N)
);
assign bios_data = sram_c_rdata;
`else
assign SRAM_A    = 17'd0;
assign SRAM_DQ   = 16'hZZZZ;
assign SRAM_OE_N = 1'b1;
assign SRAM_WE_N = 1'b1;
assign SRAM_UB_N = 1'b1;
assign SRAM_LB_N = 1'b1;
`endif

`ifdef POCKET_BUPCHIP
//////////////////////////////  BUPCHIP  //////////////////////////////////
// The Souper cartridge's music co-processor: ARIA (core/bupchip/,
// docs/BUPCHIP_CORE.md) on clk_arm, its firmware from the bupchip.bin slot,
// its assets (the cartridge file's ARSC block) in PSRAM cram0 die 0. Inputs
// come from clk_sys registers, except pll_locked and pll_busy, which the
// wrapper synchronises. The console reset is not one of them, as on MiSTer:
// the music survives a 7800 reset.
//
// With POCKET_DARIA the same CPU also runs the 2600 ARM cartridges' code,
// in its 2600 profile (daria_profile), as the DARIA front end's call side
// (u_fe, below): the call and return toggles, the cart RAM, front-end ROM
// and state RAM ports, the capture's cartridge window and the sample port.
// There the mapper reset (daria_mres_r) does reach it.
wire        psr_bank, psr_we, psr_hi, psr_lo, psr_re, psr_avail, psr_busy;
wire [21:0] psr_addr;
wire [15:0] psr_din, psr_dout;
`ifdef BUP_DEBUG
wire [31:0] bup_dbg_status, bup_dbg_halt_pc;
wire [110:0] bup_dbg_load;
`endif

bupchip_pocket bupchip
(
	.clk_sys       (clk_sys),
	.clk_arm       (clk_arm),
	.clk_74a       (clk_74a),
	.pll_locked    (pll_locked),
	.pll_busy      (pll_busy),
	.souper_profile(souper_profile),
	.pause         (pause_core),

	.byte_valid    (ioctl_wr_any),
	.byte_hi       (ioctl_hi),
	.load_addr     (ioctl_addr),
	.load_data     (ioctl_dout),
	.load_start    (~old_cart_download && cart_download),
	.load_end      (old_cart_download && ~cart_download),
	.fw_download   (bupfw_download),

	.cmd_valid     (bup_cmd_valid),
	.cmd_data      (bup_cmd_data),
	.audio_l       (bup_audio_l),
	.audio_r       (bup_audio_r),

	.psram_bank_sel        (psr_bank),
	.psram_addr            (psr_addr),
	.psram_write_en        (psr_we),
	.psram_data_in         (psr_din),
	.psram_write_high_byte (psr_hi),
	.psram_write_low_byte  (psr_lo),
	.psram_read_en         (psr_re),
	.psram_read_avail      (psr_avail),
	.psram_data_out        (psr_dout),
	.psram_busy            (psr_busy)
`ifdef POCKET_DARIA
	,
	.daria_profile  (daria_profile),
	.daria_ram32    (daria_ram32_r),
	.daria_pal      (daria_rgn),      // timer 1's rate: the region clk_sys runs at
	.daria_mreset   (daria_mres_r),
	.daria_call_tog (daria_call_tog),
	.daria_ret_tog  (daria_ret_tog),
	.daria_ready    (daria_ready),
	/* verilator lint_off PINCONNECTEMPTY */
	.daria_halted   (),               // open: the overlay shows the halt from dbg_status
	/* verilator lint_on PINCONNECTEMPTY */
	.daria_stb_addr (daria_stb_addr),
	.daria_stb_we   (daria_stb_we & daria_we_ok),
	.daria_stb_be   (daria_stb_be),
	.daria_stb_wd   (daria_stb_wd),
	.daria_stb_q    (daria_stb_q),
	.daria_crb_addr (daria_crb_addr),
	.daria_crb_we   (daria_crb_we & daria_we_ok),
	.daria_crb_be   (daria_crb_be),
	.daria_crb_wd   (daria_crb_wd),
	.daria_crb_q    (daria_crb_q),
	.daria_fea_addr (daria_fea_addr),
	.daria_fea_q    (daria_fea_q),
	.daria_feb_addr (daria_feb_addr),
	.daria_feb_q    (daria_feb_q),
	.daria_cart_win (daria_cart_win),
	.daria_smp_req  (daria_smp_req),
	.daria_smp_addr (daria_smp_addr),
	.daria_smp_ack  (daria_smp_ack),
	.daria_smp_data (daria_smp_data)
`endif
`ifdef BUP_DEBUG
	,
	.dbg_status    (bup_dbg_status),
	.dbg_halt_pc   (bup_dbg_halt_pc),
	.dbg_load      (bup_dbg_load)
`endif
);

`ifdef POCKET_DARIA
// The DARIA front end (docs/daria_fe/design.md): the 6507 side of DPC+ and
// the CDF family, in place of upstream's ARM mapper, beside cart2600 in
// top.sv (its byte, output enable and busys go back there), with its
// memories in the BupChip (daria_mem) and its calls run by the BupChip's
// CPU. clk_sys, but for its guard's one clk_arm flop.
//
// cart_reset is top.sv's effective_reset, masked while a retune is under way
// or pending (daria_rt_mask, P20, above): a retune never starts F6,
// nor runs into one; F6 runs once, when the retune ends. init_busy
// reaches the console reset and .loading through daria_hold (P6). The
// bench hooks are tied off; dbg_locked and dbg_unlock are for step 8's
// BUP_DEBUG overlay and the benches (P22).
daria_fe u_fe
(
	.clk_sys         (clk_sys),
	.clk_arm         (clk_arm),
	.cart_reset      (daria_reset & ~daria_rt_mask),
	.pause           (pause_core),
	.a_in            (daria_a_in),
	.d_in            (din),
	.rw              (RW),
	.pclk1           (daria_pclk1),
	.pclk0           (daria_pclk0),
	.access          (daria_access),
	.scheme          (daria_scheme),
	.revision        (mapper_revision),
	.cdf_ldx         (cdf_ldx),
	.cdf_ldy         (cdf_ldy),
	.fetch_off_en    (cdf_fetch_offset_enable),
	.fetch_off       (cdf_fetch_offset),
	.cdfj_entry      (cdfj_entry),
	.cdfj_stack      (cdfj_stack),
	.audio_size_addr (arm_audio_size_addr),
	.rom_size        (cart_size),
	.ram32           (daria_ram32),
	.load_start      (~old_cart_download && cart_download),
	.load_end        (old_cart_download && ~cart_download),
	.cart_win        (daria_cart_win),
	.cpu_ready       (daria_ready),
	.ret_tog         (daria_ret_tog),
	.call_tog        (daria_call_tog),
	.smp_req         (daria_smp_req),
	.smp_addr        (daria_smp_addr),
	.smp_ack         (daria_smp_ack),
	.smp_data        (daria_smp_data),
	.fe_do           (daria_fe_do),
	.fe_oe           (daria_fe_oe),
	.arm_call_busy   (daria_call_busy),
	.arm_dma_busy    (daria_dma_busy),
	.init_busy       (daria_init_busy),
	.fea_addr        (daria_fea_addr),
	.fea_q           (daria_fea_q),
	.feb_addr        (daria_feb_addr),
	.feb_q           (daria_feb_q),
	.crb_addr        (daria_crb_addr),
	.crb_we          (daria_crb_we),
	.crb_be          (daria_crb_be),
	.crb_wd          (daria_crb_wd),
	.crb_q           (daria_crb_q),
	.stb_addr        (daria_stb_addr),
	.stb_we          (daria_stb_we),
	.stb_be          (daria_stb_be),
	.stb_wd          (daria_stb_wd),
	.stb_q           (daria_stb_q),
	.hk_en           (1'b0),
	.hk_stb          (1'b0),
	.hk_ret          (192'd0),
`ifdef BUP_DEBUG
	.dbg_locked      (daria_dbg_locked),  // the DARIA status overlay (below)
	.dbg_unlock      (daria_dbg_unlock)
`else
	/* verilator lint_off PINCONNECTEMPTY */
	.dbg_locked      (),
	.dbg_unlock      ()
	/* verilator lint_on PINCONNECTEMPTY */
`endif
);
`endif

// agg23's controller (pocket_utils/psram.sv, unmodified). Every count in it
// is a minimum time, and slower settings break its state machine
// (docs/BUPCHIP_CORE.md, "Controller"). CLOCK_SPEED is 28.636364 with
// clk_arm at 2 x clk_sys, 5 clk_arm per halfword. With POCKET_DARIA clk_arm
// is VCO/18, 38.18 MHz, where one clock from oe_n to the sample (26.2 ns) is
// short of the part's output-enable access with the pad delays (about 27 ns,
// an estimate), so CLOCK_SPEED is 50.0: two clocks there, 6 clk_arm per
// halfword (docs/DARIA_CORE.md 7.4;
// docs/daria_step7/plan.md P18, which tb_load checks by the parameter).
`ifdef POCKET_DARIA
psram #(.CLOCK_SPEED(50.0)) bup_psram
`else
psram #(.CLOCK_SPEED(28.636364)) bup_psram
`endif
(
	.clk             (clk_arm),
	.bank_sel        (psr_bank),
	.addr            (psr_addr),
	.write_en        (psr_we),
	.data_in         (psr_din),
	.write_high_byte (psr_hi),
	.write_low_byte  (psr_lo),
	.read_en         (psr_re),
	.read_avail      (psr_avail),
	.data_out        (psr_dout),
	.busy            (psr_busy),
	.cram_a          (cram0_a),
	.cram_dq         (cram0_dq),
	.cram_wait       (cram0_wait),
	.cram_clk        (cram0_clk),
	.cram_adv_n      (cram0_adv_n),
	.cram_cre        (cram0_cre),
	.cram_ce0_n      (cram0_ce0_n),
	.cram_ce1_n      (cram0_ce1_n),
	.cram_oe_n       (cram0_oe_n),
	.cram_we_n       (cram0_we_n),
	.cram_ub_n       (cram0_ub_n),
	.cram_lb_n       (cram0_lb_n)
);

`ifdef BUP_DEBUG
`ifdef POCKET_DARIA
// DARIA's counts for the status overlay: calls, late calls, the guard's lock
// and unlocks, from the 6507's bus (top.sv's AB, RW and write byte, with the
// RIOT's clock enable and reset), daria_fe's call side and its P22 exports.
// daria_dbg_status, in bup_status_osd.sv, has the rules. Hardware test
// builds only; nothing else reads them.
wire [48:0] daria_dstat;
daria_dbg_status u_dstat
(
	.clk       (clk_sys),
	.rst       (daria_reset),       // top.sv's effective_reset, the RIOT's reset
	.ce        (daria_pclk0),       // the RIOT's clock enable
	.ab        (bios_addr),         // top.sv's AB
	.rw        (RW),
	.db_w      (din),               // top.sv's write_DB
	.call_busy (daria_call_busy),
	.call_tog  (daria_call_tog),
	.g_locked  (daria_dbg_locked),
	.g_unlock  (daria_dbg_unlock),
	.dstat     (daria_dstat)
);
`endif

// Hardware test builds: the BupChip's status word over the picture's
// top-left corner while a Souper cartridge is loaded, and DARIA's while a
// 2600 ARM cartridge runs (bup_status_osd.sv).
bup_status_osd bup_osd
(
	.clk     (clk_sys),
	.en      (souper_profile),
	.status  (bup_dbg_status),
	.halt_pc (bup_dbg_halt_pc),
	.load    (bup_dbg_load),
`ifdef POCKET_DARIA
	.daria   (daria_profile),
	.dstat   (daria_dstat),
`else
	.daria   (1'b0),
	.dstat   (49'd0),
`endif
	.ce_pix  (ce_pix),
	.hblank  (HBlank),
	.vblank  (VBlank),
	.r_in    (pic_r),
	.g_in    (pic_g),
	.b_in    (pic_b),
	.r_out   (R),
	.g_out   (G),
	.b_out   (B)
);
`else
assign R = pic_r;
assign G = pic_g;
assign B = pic_b;
`endif
`else
assign R = pic_r;
assign G = pic_g;
assign B = pic_b;
`endif

assign tia_mode_o = tia_en;
assign is_pal_o = region_pll;
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
	output reg  [31:0]                 dout_b
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial dout_b = 32'd0;
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
