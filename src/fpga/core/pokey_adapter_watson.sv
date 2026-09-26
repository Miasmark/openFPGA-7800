//------------------------------------------------------------------------------
// pokey_adapter, Pocket build: Mark Watson's POKEY
//
// The MiSTer core's cart.sv instantiates `pokey_adapter`. Upstream's version
// (rtl/Pokey/pokey_adapter.sv) wraps the new schematic-level POKEY added on
// 2026-08-25. On hardware, Ballblazer's procedurally generated music turns
// into near-silent taps and pops with it, and plays correctly on the 2022
// Pocket core, which used Mark Watson's POKEY - the one MiSTer's 7800 core
// used until that date (upstream b48eac0, vendored in rtl/PokeyWatson/, top
// entity renamed pokey_watson).
//
// This module keeps upstream's port list so cart.sv is untouched, and wires
// it the way b48eac0's cart.sv wired Watson's POKEY: ENABLE_179 is the CPU's
// phase 2 enable, and the audio is the plain sum of the four 4-bit channels
// scaled into 16 bits ({sum, 10'd0}), as that version mixed it.
//
// SPDX-License-Identifier: MIT (this wrapper). Watson's VHDL has its own
// non-commercial terms; see rtl/PokeyWatson.
//------------------------------------------------------------------------------

`default_nettype none

module pokey_adapter (
	input  wire        CLK,
	input  wire        PHI1_EN,
	input  wire        PHI2_EN,
	input  wire  [3:0] ADDR,
	input  wire  [7:0] DATA_IN,
	input  wire        WR_EN,
	input  wire        RESET_N,

	input  wire        keyboard_scan_enable,
	output wire  [5:0] keyboard_scan,
	input  wire  [1:0] keyboard_response,

	input  wire  [7:0] POT_IN,

	input  wire        SIO_IN1,
	input  wire        SIO_IN2,
	input  wire        SIO_IN3,
	output wire        SIO_OUT1,
	output wire        SIO_OUT2,
	output wire        SIO_OUT3,
	input  wire        SIO_CLOCKIN_IN,
	output wire        SIO_CLOCKIN_OUT,
	output wire        SIO_CLOCKIN_OE,
	output wire        SIO_CLOCKOUT,

	output wire  [7:0] DATA_OUT,
	output wire  [3:0] CHANNEL_0_OUT,
	output wire  [3:0] CHANNEL_1_OUT,
	output wire  [3:0] CHANNEL_2_OUT,
	output wire  [3:0] CHANNEL_3_OUT,
	output wire [15:0] AUD,

	output wire        IRQ_N_OUT,
	output wire        POT_RESET
);
	// cart.sv leaves the pot and serial inputs unconnected; tie them to their
	// idle levels here rather than pass an undriven net into the VHDL.
	pokey_watson pokey (
		.CLK                  (CLK),
		.ENABLE_179           (PHI2_EN),
		.ADDR                 (ADDR),
		.DATA_IN              (DATA_IN),
		.WR_EN                (WR_EN),
		.RESET_N              (RESET_N),
		.keyboard_scan_enable (keyboard_scan_enable),
		.keyboard_scan        (keyboard_scan),
		.keyboard_response    (keyboard_response),
		.POT_IN               (8'h00),
		.SIO_IN1              (1'b1),
		.SIO_IN2              (1'b1),
		.SIO_IN3              (1'b1),
		.DATA_OUT             (DATA_OUT),
		.CHANNEL_0_OUT        (CHANNEL_0_OUT),
		.CHANNEL_1_OUT        (CHANNEL_1_OUT),
		.CHANNEL_2_OUT        (CHANNEL_2_OUT),
		.CHANNEL_3_OUT        (CHANNEL_3_OUT),
		.IRQ_N_OUT            (IRQ_N_OUT),
		.SIO_OUT1             (SIO_OUT1),
		.SIO_OUT2             (SIO_OUT2),
		.SIO_OUT3             (SIO_OUT3),
		.SIO_CLOCKIN_IN       (1'b1),
		.SIO_CLOCKIN_OUT      (SIO_CLOCKIN_OUT),
		.SIO_CLOCKIN_OE       (SIO_CLOCKIN_OE),
		.SIO_CLOCKOUT         (SIO_CLOCKOUT),
		.POT_RESET            (POT_RESET)
	);

	wire [5:0] sum = CHANNEL_0_OUT + CHANNEL_1_OUT + CHANNEL_2_OUT + CHANNEL_3_OUT;
	assign AUD = {sum, 10'd0};

	wire _unused = &{1'b0, PHI1_EN, POT_IN, SIO_IN1, SIO_IN2, SIO_IN3, SIO_CLOCKIN_IN};
endmodule

`default_nettype wire
