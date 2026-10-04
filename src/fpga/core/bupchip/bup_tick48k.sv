//------------------------------------------------------------------------------
// The BupChip's 48 kHz pop tick (docs/BUPCHIP_CORE.md, "48 kHz").
//
// A clk_74a accumulator, acc += 8 wrapping at 12,375, wraps 74.25 MHz x 8 /
// 12,375 = exactly 48,000 times a second. That is the I2S LRCK's own
// reference, so the pop rate does not depend on the clk_arm divider or the
// region, and nothing drifts against the audio output.
//
// Each wrap flips a toggle. Three clk_arm flops take it across (the clocks are
// asynchronous; the clock groups in core_constraints.sdc cover the path), and
// a change between the last two is a one-clock tick on clk_arm.
//
// Not held: it runs from configuration, whatever the BupChip is doing.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_tick48k (
	input  wire  clk_74a,
	input  wire  clk_arm,
	output logic tick           // clk_arm: one clock per 1/48,000 s
);
	logic [13:0] acc = 14'd0;
	logic        tog = 1'b0;

	always_ff @(posedge clk_74a)
		if (acc >= 14'd12367) begin	// acc + 8 >= 12,375
			acc <= acc - 14'd12367;
			tog <= ~tog;
		end else
			acc <= acc + 14'd8;

	logic [2:0] sync = 3'd0;
	always_ff @(posedge clk_arm)
		sync <= {sync[1:0], tog};

	assign tick = sync[2] ^ sync[1];
endmodule

`default_nettype wire
