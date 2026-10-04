//------------------------------------------------------------------------------
// Audio conditioning for the Pocket's I2S DAC
//
// The MiSTer core mixes TIA, POKEY and friends into 16 bit unsigned samples
// at clk_sys (14.318 MHz). The DAC takes 48 kHz. Sampling the raw mix at
// 48 kHz would alias the TIA's and POKEY's square waves badly, so:
//
//   1. average 256 input samples (a boxcar; ~55.9 kHz output, first null at
//      55.9 kHz, and it sits well below the -3 dB point for audible tones),
//   2. remove the DC offset with a one pole high pass (~1 Hz), since the
//      core's silence level is not zero. The core's full mix spans 0..0xFFFF,
//      which maps onto the whole signed range once centred,
//   3. saturate to 16 bit signed.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module audio_filter
(
	input  wire        clk,
	input  wire [15:0] in_l,
	input  wire [15:0] in_r,
	output reg  [15:0] out_l,
	output reg  [15:0] out_r
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial out_l = 16'd0;
	initial out_r = 16'd0;

	reg  [7:0]  count = 8'd0;
	reg  [23:0] acc_l = 24'd0, acc_r = 24'd0;
	reg         sample = 1'b0;
	reg  [15:0] avg_l = 16'd0, avg_r = 16'd0;

	always @(posedge clk) begin
		count  <= count + 1'b1;
		sample <= 1'b0;
		if (count == 8'hFF) begin
			avg_l  <= (acc_l + in_l) >> 8;
			avg_r  <= (acc_r + in_r) >> 8;
			acc_l  <= 24'd0;
			acc_r  <= 24'd0;
			sample <= 1'b1;
		end else begin
			acc_l <= acc_l + in_l;
			acc_r <= acc_r + in_r;
		end
	end

	// DC blocker: y[n] = x[n] - x[n-1] + y[n-1] - y[n-1]/2^13
	// Fixed point with 8 fraction bits so the leak does not stall on small y.
	reg  signed [16:0] x_prev_l = 17'sd0, x_prev_r = 17'sd0;
	reg  signed [31:0] y_l = 32'sd0, y_r = 32'sd0;

	wire signed [16:0] x_l = {1'b0, avg_l};
	wire signed [16:0] x_r = {1'b0, avg_r};

	wire signed [31:0] y_next_l = y_l + ((x_l - x_prev_l) <<< 8) - (y_l >>> 13);
	wire signed [31:0] y_next_r = y_r + ((x_r - x_prev_r) <<< 8) - (y_r >>> 13);

	function [15:0] sat16(input signed [31:0] v);
		begin
			if (v > 32'sd32767)
				sat16 = 16'h7FFF;
			else if (v < -32'sd32768)
				sat16 = 16'h8000;
			else
				sat16 = v[15:0];
		end
	endfunction

	always @(posedge clk) begin
		if (sample) begin
			x_prev_l <= x_l;
			x_prev_r <= x_r;
			y_l <= y_next_l;
			y_r <= y_next_r;
			out_l <= sat16(y_next_l >>> 8);
			out_r <= sat16(y_next_r >>> 8);
		end
	end

endmodule
