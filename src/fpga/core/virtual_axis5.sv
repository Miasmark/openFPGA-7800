//------------------------------------------------------------------------------
// The five virtual axes of atari7800_pocket.sv as one time-shared engine
//
// Five axes as virtual_axis.sv makes them (same parameters, same position
// and phase), with one difference: axis k makes its 1 kHz update k clocks
// after the tick (k = 0..4) instead of on it. One datapath (velocity ramp,
// position clamp, phase step, stick follow) serves axis k in slot k; the
// state stays per axis, in registers, and so does the every-clock rest /
// analog_on logic. So each output is virtual_axis.sv's with its tick delayed
// by k clocks: at most 4 clk_sys (0.28 us) against a 1 ms update.
//
//   axes 0-3  the four controllers' paddle / driving / crosshair X axes
//   axis 4    the light-gun crosshair Y
//   phase     kept for axes 0 and 1 only (the driving controllers)
//
// Ticks must come at least 5 clocks apart.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module virtual_axis5 #(
	parameter [15:0] V_START = 16'd24  << 4,  // speed when a press starts
	parameter [15:0] V_SLOW  = 16'd24  << 4,  // top speed with "slow"
	parameter [15:0] V_NORM  = 16'd160 << 4,  // top speed
	parameter [15:0] V_FAST  = 16'd320 << 4,  // top speed with "fast"
	parameter [15:0] ACCEL   = 16'd9,         // per ms, 1/16 units
	parameter [7:0]  DEADZONE = 8'd24,
	parameter        PHASE_SHIFT = 1          // phase moves 2^n x position speed
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        tick,          // 1 kHz strobe, at least 5 clocks apart
	input  wire  [4:0] neg,           // axis k in bit k: left / up
	input  wire  [4:0] pos,           // right / down
	input  wire  [4:0] slow,
	input  wire  [4:0] fast,
	input  wire [39:0] analog,        // axis k in [8k+7:8k]: unsigned, 128 = centre
	output wire [39:0] position,      // axis k in [8k+7:8k]
	output wire [31:0] phase          // axis k (0, 1) in [16k+15:16k]
);
	// The slot: 0 on the tick's clock (axis 0's update), then 1..4 on the
	// four clocks after it (axes 1-4), then 0 again until the next tick.
	/* verilator lint_off PROCASSINIT */  // power-up values (DEVELOPING.md, "Power-up values")
	reg  [2:0] slot = 3'd0;
	/* verilator lint_on PROCASSINIT */
	always @(posedge clk)
		slot <= tick ? 3'd1 : (slot == 3'd0 || slot == 3'd4) ? 3'd0 : slot + 3'd1;

	wire [4:0] upd = {slot == 3'd4, slot == 3'd3, slot == 3'd2, slot == 3'd1, tick};

	// Each axis's state, read by the shared datapath through the slot.
	wire [15:0] ax_pos16 [0:4];
	wire [15:0] ax_vel   [0:4];
	wire        ax_aon   [0:4];
	wire  [7:0] ax_an    [0:4];
	wire [15:0] ax_phase [0:1];

	// ---- The shared datapath: the selected axis's update ----
	wire  [7:0] d_analog = ax_an[slot];
	wire [15:0] d_pos16  = ax_pos16[slot];
	wire [15:0] d_vel    = ax_vel[slot];
	wire        d_aon    = ax_aon[slot];
	wire [15:0] d_phase  = ax_phase[slot[0]];
	wire        d_pos    = pos[slot];
	wire        d_held   = neg[slot] ^ pos[slot];
	wire        d_slow   = slow[slot];
	wire        d_fast   = fast[slot];

	wire [15:0] v_top  = d_slow ? V_SLOW : d_fast ? V_FAST : V_NORM;
	wire [15:0] v_acc  = d_fast ? {ACCEL[13:0], 2'b00} : ACCEL;
	wire [15:0] v_next = (d_vel == 16'd0) ? ((V_START < v_top) ? V_START : v_top) :
	                     (d_vel + v_acc > v_top) ? v_top : d_vel + v_acc;
	wire [11:0] step   = v_next[15:4];
	wire signed [8:0] stick = $signed({1'b0, d_analog}) - 9'sd128;

	// What the update writes (n_*), and whether it writes pos16 / phase.
	reg  [15:0] n_pos16, n_phase;
	reg         w_pos16, w_phase;
	wire [15:0] n_vel = d_held ? v_next : 16'd0;
	always @* begin
		n_pos16 = d_pos16;
		n_phase = d_phase;
		w_pos16 = 1'b0;
		w_phase = 1'b0;
		if (d_held) begin
			w_pos16 = 1'b1;
			w_phase = 1'b1;
			if (d_pos) begin
				n_pos16 = (d_pos16 > 16'hFFFF - {4'd0, step}) ? 16'hFFFF : d_pos16 + {4'd0, step};
				n_phase = d_phase + ({4'd0, step} << PHASE_SHIFT);
			end else begin
				n_pos16 = (d_pos16 < {4'd0, step}) ? 16'h0000 : d_pos16 - {4'd0, step};
				n_phase = d_phase - ({4'd0, step} << PHASE_SHIFT);
			end
		end else if (d_aon) begin
			// Follow the stick: close a quarter of the gap per ms.
			w_pos16 = 1'b1;
			if ({d_analog, 8'h80} > d_pos16)
				n_pos16 = d_pos16 + (({d_analog, 8'h80} - d_pos16) >> 2);
			else
				n_pos16 = d_pos16 - ((d_pos16 - {d_analog, 8'h80}) >> 2);
			// Turn at a rate set by how far the stick is pushed.
			if (stick > $signed({1'b0, DEADZONE}) || stick < -$signed({1'b0, DEADZONE})) begin
				w_phase = 1'b1;
				n_phase = d_phase + ({{7{stick[8]}}, stick} <<< (PHASE_SHIFT + 1));
			end
		end
	end

	// ---- Per axis: the state, the every-clock rest / analog_on logic ----
	genvar k;
	generate
	for (k = 0; k < 5; k = k + 1) begin : ax
		// Position is 8.8 fixed point; speeds are in 1/256 position steps
		// per ms, with 4 more fraction bits (virtual_axis.sv).
		/* verilator lint_off PROCASSINIT */
		reg  [15:0] pos16 = 16'h8000;
		reg  [15:0] vel = 16'd0;           // 12.4
		reg         analog_on = 1'b0;
		reg   [7:0] rest = 8'd128;
		reg         rest_valid = 1'b0;
		/* verilator lint_on PROCASSINIT */

		wire  [7:0] an   = analog[8*k +: 8];
		wire        held = neg[k] ^ pos[k];
		wire  [8:0] off_rest = (an > rest) ? {1'b0, an - rest} : {1'b0, rest - an};

		always @(posedge clk) begin
			if (reset) begin
				pos16      <= 16'h8000;
				vel        <= 16'd0;
				analog_on  <= 1'b0;
				rest_valid <= 1'b0;
			end else begin
				if (!rest_valid) begin
					rest       <= an;
					rest_valid <= 1'b1;
				end else if (!analog_on && !held && off_rest > {1'b0, DEADZONE})
					analog_on <= 1'b1;

				// The update, in this axis's slot (the datapath reads this
				// axis then): written after the lines above, so its analog_on
				// clear and rest capture win, as in virtual_axis.sv.
				if (upd[k]) begin
					vel <= n_vel;
					if (w_pos16)
						pos16 <= n_pos16;
					if (held) begin
						analog_on <= 1'b0;
						rest      <= an;
					end
				end
			end
		end

		assign ax_pos16[k] = pos16;
		assign ax_vel[k]   = vel;
		assign ax_aon[k]   = analog_on;
		assign ax_an[k]    = an;
		assign position[8*k +: 8] = pos16[15:8];

		if (k < 2) begin : ph
			/* verilator lint_off PROCASSINIT */
			reg [15:0] phase_r = 16'd0;
			/* verilator lint_on PROCASSINIT */
			always @(posedge clk)
				if (!reset && upd[k] && w_phase)
					phase_r <= n_phase;
			assign ax_phase[k] = phase_r;
			assign phase[16*k +: 16] = phase_r;
		end
	end
	endgenerate

endmodule
