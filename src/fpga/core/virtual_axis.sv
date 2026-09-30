//------------------------------------------------------------------------------
// One axis of a virtual paddle, driving controller or light-gun crosshair
//
// The Pocket has a D-pad and, docked, controllers that may have analog
// sticks. This turns either into what those controllers need:
//
//   position  0..255, clamped at the ends: paddle position, crosshair X or Y
//   phase     wraps: a driving controller's rotation (top two bits)
//
// D-pad: the position moves in 1/256 steps, updated once a millisecond.
// Movement starts slowly, so a tap nudges by a pixel or so, and speeds up
// the longer the direction is held, up to a top speed. "slow" caps the speed
// low for fine aiming; "fast" doubles the top speed and quadruples the
// acceleration.
//
// Analog stick: once the stick moves clearly away from where it rested when
// the axis was reset, it takes over. The position follows the stick (lightly
// smoothed) and the phase turns at a rate set by how far the stick is
// pushed. The next D-pad press hands control back. A controller without a
// stick reports a constant value, so it never takes over.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module virtual_axis #(
	parameter [15:0] V_START = 16'd24  << 4,  // speed when a press starts
	parameter [15:0] V_SLOW  = 16'd24  << 4,  // top speed with "slow"
	parameter [15:0] V_NORM  = 16'd160 << 4,  // top speed
	parameter [15:0] V_FAST  = 16'd320 << 4,  // top speed with "fast"
	parameter [15:0] ACCEL   = 16'd9,         // per ms, 1/16 units
	parameter [7:0]  DEADZONE = 8'd24,
	parameter        PHASE_SHIFT = 1          // phase moves 2^n x position speed
	// With these, the phase's top two bits (a driving controller's gray
	// code) step at most every 25 ms (D-pad, fast) or 32 ms (stick pushed
	// all the way): slower than a game reading once a frame can follow.
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        tick,         // 1 kHz strobe
	input  wire        neg,          // left / up
	input  wire        pos,          // right / down
	input  wire        slow,
	input  wire        fast,
	input  wire  [7:0] analog,       // unsigned, 128 = centre
	output wire  [7:0] position,
	output reg  [15:0] phase = 16'd0
);
	// Position is 8.8 fixed point; speeds are in 1/256 position steps per ms,
	// with 4 more fraction bits so the ramp can be gentle.
	reg  [15:0] pos16 = 16'h8000;
	reg  [15:0] vel = 16'd0;           // 12.4
	reg         analog_on = 1'b0;
	reg   [7:0] rest = 8'd128;
	reg         rest_valid = 1'b0;

	assign position = pos16[15:8];

	wire        held   = neg ^ pos;
	wire [15:0] v_top  = slow ? V_SLOW : fast ? V_FAST : V_NORM;
	wire [15:0] v_acc  = fast ? {ACCEL[13:0], 2'b00} : ACCEL;
	wire [15:0] v_next = (vel == 16'd0) ? ((V_START < v_top) ? V_START : v_top) :
	                     (vel + v_acc > v_top) ? v_top : vel + v_acc;
	wire [11:0] step   = v_next[15:4];

	wire  [8:0] off_rest = (analog > rest) ? {1'b0, analog - rest} : {1'b0, rest - analog};
	wire signed [8:0] stick = $signed({1'b0, analog}) - 9'sd128;

	always @(posedge clk) begin
		if (reset) begin
			pos16      <= 16'h8000;
			vel        <= 16'd0;
			analog_on  <= 1'b0;
			rest_valid <= 1'b0;
		end else begin
			if (!rest_valid) begin
				rest       <= analog;
				rest_valid <= 1'b1;
			end else if (!analog_on && !held && off_rest > {1'b0, DEADZONE})
				analog_on <= 1'b1;

			if (tick) begin
				if (held) begin
					vel       <= v_next;
					analog_on <= 1'b0;
					rest      <= analog;
					if (pos) begin
						pos16 <= (pos16 > 16'hFFFF - {4'd0, step}) ? 16'hFFFF : pos16 + {4'd0, step};
						phase <= phase + ({4'd0, step} << PHASE_SHIFT);
					end else begin
						pos16 <= (pos16 < {4'd0, step}) ? 16'h0000 : pos16 - {4'd0, step};
						phase <= phase - ({4'd0, step} << PHASE_SHIFT);
					end
				end else begin
					vel <= 16'd0;
					if (analog_on) begin
						// Follow the stick: close a quarter of the gap per ms.
						if ({analog, 8'h80} > pos16)
							pos16 <= pos16 + (({analog, 8'h80} - pos16) >> 2);
						else
							pos16 <= pos16 - ((pos16 - {analog, 8'h80}) >> 2);
						// Turn at a rate set by how far the stick is pushed.
						if (stick > $signed({1'b0, DEADZONE}) || stick < -$signed({1'b0, DEADZONE}))
							phase <= phase + ({{7{stick[8]}}, stick} <<< (PHASE_SHIFT + 1));
					end
				end
			end
		end
	end

endmodule
