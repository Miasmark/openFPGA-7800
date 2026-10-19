// The AtariVox's voice for the Pocket (docs/ATARIVOX.md): the SpeakJet's
// serial input and buffer (avox_rx) and a speech engine of our own
// (avox_engine) that plays its codes with our sound tables. The SaveKey
// half of the AtariVox is the core's savekey EEPROM, as before.
//
// Port 2: `line` is the UP pin as the console drives it; `down_n` goes to
// the DOWN pin and is low while the buffer is half full.
//
// MIT licence, as the rest of the Pocket port's own code.

module atarivox (
	input  logic               clk,         // clk_sys
	input  logic               reset,
	input  logic               pal,         // clk_sys is the PAL frequency

	input  logic               line,
	output logic               down_n,

	output logic signed [15:0] sample       // 16,384 Hz, held; full scale about +-4096 x master/128
);

	// 16,384 Hz from clk_sys: 874 x 16,384 = 14.32 MHz (NTSC), 866 for PAL
	// (14.19 MHz); both within 0.1%.
	/* verilator lint_off PROCASSINIT */  // power-up value (DEVELOPING.md, "Power-up values")
	logic [9:0] div = 10'd0;
	/* verilator lint_on PROCASSINIT */
	wire  [9:0] div_last = pal ? 10'd865 : 10'd873;
	wire        tick = (div == div_last);
	always_ff @(posedge clk)
		div <= (reset || tick) ? 10'd0 : div + 10'd1;

	logic       abort_set, ready_set, pop, nonempty, half_full;
	logic [7:0] q;

	avox_rx rx (
		.clk       (clk),
		.reset     (reset),
		.line      (line),
		.abort_set (abort_set),
		.ready_set (ready_set),
		.pop       (pop),
		.q         (q),
		.nonempty  (nonempty),
		.half_full (half_full)
	);

	avox_engine engine (
		.clk           (clk),
		.reset         (reset),
		.tick          (tick),
		.abort_set     (abort_set),
		.ready_set     (ready_set),
		.fifo_q        (q),
		.fifo_nonempty (nonempty),
		.fifo_pop      (pop),
		.sample        (sample),
		/* verilator lint_off PINCONNECTEMPTY */  // the held sample is enough
		.sample_strobe ()
		/* verilator lint_on PINCONNECTEMPTY */
	);

	assign down_n = ~half_full;

endmodule
