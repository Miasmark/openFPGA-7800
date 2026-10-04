//------------------------------------------------------------------------------
// An analog stick as four joystick directions
//
// A direction is held while the stick is pushed more than THRESHOLD away
// from where it rested at reset, as MiSTer's Robotron mode reads its sticks
// (more than 63 from centre). Measuring from the rest value rather than
// from 128 means a controller without a stick, which reports a constant,
// never holds a direction, whatever that constant is.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module stick_dirs #(
	parameter [7:0] THRESHOLD = 8'd64
) (
	input  wire        clk,
	input  wire        reset,
	input  wire [15:0] stick,        // {y, x}, unsigned
	output reg   [3:0] dirs   // 0 R, 1 L, 2 D, 3 U (MiSTer joystick order)
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial dirs = 4'd0;
	reg  [7:0] rest_x = 8'd128, rest_y = 8'd128;
	reg        rest_valid = 1'b0;

	wire [7:0] x = stick[7:0];
	wire [7:0] y = stick[15:8];

	always @(posedge clk) begin
		if (reset) begin
			rest_valid <= 1'b0;
			dirs       <= 4'd0;
		end else if (!rest_valid) begin
			rest_x     <= x;
			rest_y     <= y;
			rest_valid <= 1'b1;
		end else begin
			dirs[0] <= x > rest_x && x - rest_x > THRESHOLD;
			dirs[1] <= x < rest_x && rest_x - x > THRESHOLD;
			dirs[2] <= y > rest_y && y - rest_y > THRESHOLD;
			dirs[3] <= y < rest_y && rest_y - y > THRESHOLD;
		end
	end
endmodule
