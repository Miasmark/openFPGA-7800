// The AtariVox's serial input (docs/ATARIVOX.md): what the SpeakJet does with
// the bytes a game sends on port 2's UP pin, before its speech engine sees
// them.
//
// - 8N1, not inverted, about 19,200 baud: a bit every 744 clk_sys, as the
//   AtariVox drivers send them (62 CPU cycles on the 2600; 7800basic's loop
//   comes out the same). The start bit is checked half a bit in; each data
//   bit is sampled in its middle; a missing stop bit drops the byte.
// - Serial control mode (the SpeakJet manual's SCP): a backslash ($5C) and
//   the character after it are an escape, both consumed. "\0" enters the
//   mode (0 is the AtariVox's node); any other character after the backslash
//   leaves it, or keeps the chip out of it: a digit 1-9 is another node, and
//   a non-numeric character ends the mode. Star Raiders (7800) sends "\V",
//   which the first version took as entering the mode and then swallowed the
//   game's speech. Inside the mode: R clears the buffer and stops the voice
//   (abort), V says "Ready", W (hard reset) clears and leaves, X leaves;
//   everything else (register settings such as 8J0N, S and T) is swallowed.
//   None of it reaches the buffer.
// - The 64-byte buffer; DOWN reads low ("buffer half full") from 32 bytes,
//   and a game sends only while it is high.
//
// MIT licence, as the rest of the Pocket port's own code.

module avox_rx #(
	parameter int BIT_CLKS = 744
) (
	input  logic       clk,
	input  logic       reset,
	input  logic       line,            // port 2 UP as the console drives it (1 idle)

	output logic       abort_set,       // pulses
	output logic       ready_set,

	input  logic       pop,
	output logic [7:0] q,
	output logic       nonempty,
	output logic       half_full
);

	// ---------------------------------------------------------------- UART
	/* verilator lint_off PROCASSINIT */  // power-up values (DEVELOPING.md, "Power-up values")
	logic [1:0]  sync = 2'b11;
	logic [10:0] cnt = 11'd0;
	logic [3:0]  bitn = 4'd0;           // 0 idle, 1 start, 2-9 data, 10 stop
	logic [7:0]  sh = 8'd0;
	logic        got = 1'b0;
	logic [7:0]  got_byte = 8'd0;
	/* verilator lint_on PROCASSINIT */

	always_ff @(posedge clk) begin
		sync <= {sync[0], line};
		got  <= 1'b0;
		if (reset) begin
			bitn <= 4'd0;
		end else if (bitn == 4'd0) begin
			if (sync == 2'b10) begin                     // falling edge: a start bit
				bitn <= 4'd1;
				cnt  <= 11'(BIT_CLKS / 2 - 1);
			end
		end else if (cnt != 11'd0) begin
			cnt <= cnt - 11'd1;
		end else begin
			cnt <= 11'(BIT_CLKS - 1);
			case (bitn)
				4'd1:  bitn <= sync[1] ? 4'd0 : 4'd2;   // a glitch, not a start bit
				4'd10: begin
					bitn <= 4'd0;
					if (sync[1]) begin
						got      <= 1'b1;
						got_byte <= sh;
					end
				end
				default: begin
					sh   <= {sync[1], sh[7:1]};
					bitn <= bitn + 4'd1;
				end
			endcase
		end
	end

	// ---------------------------------------------------------------- serial control mode
	/* verilator lint_off PROCASSINIT */
	logic scp = 1'b0, esc = 1'b0;
	/* verilator lint_on PROCASSINIT */
	logic push;
	always_comb push = got && !scp && !esc && (got_byte != 8'h5C);
	always_ff @(posedge clk) begin
		abort_set <= 1'b0;
		ready_set <= 1'b0;
		if (reset) begin
			scp <= 1'b0;
			esc <= 1'b0;
		end else if (got) begin
			if (esc) begin                               // the escape's control value
				esc <= 1'b0;
				scp <= (got_byte == 8'h30);              // "\0" enters; anything else leaves
			end else if (got_byte == 8'h5C)
				esc <= 1'b1;
			else if (scp) begin
				case (got_byte)
					8'h58: scp <= 1'b0;                   // X
					8'h57: begin scp <= 1'b0; abort_set <= 1'b1; end   // W
					8'h52: abort_set <= 1'b1;            // R
					8'h56: ready_set <= 1'b1;            // V
					default: ;
				endcase
			end
		end
	end

	// ---------------------------------------------------------------- FIFO
	// A byte pushed on clock c (with an abort it is already counted from
	// c + 1) is readable from c + 2, which the engine never reaches sooner.
	/* verilator lint_off PROCASSINIT */
	logic [5:0] wp = 6'd0, rp = 6'd0;
	logic [6:0] count = 7'd0;
	/* verilator lint_on PROCASSINIT */
	(* ramstyle = "M10K, no_rw_check" *) logic [7:0] mem [0:63];
	always_ff @(posedge clk) begin
		if (push && count != 7'd64)
			mem[wp] <= got_byte;
		q <= mem[rp + (pop ? 6'd1 : 6'd0)];
	end

	always_ff @(posedge clk) begin
		if (reset || abort_set) begin
			wp    <= 6'd0;
			rp    <= 6'd0;
			count <= 7'd0;
		end else begin
			if (push && count != 7'd64)
				wp <= wp + 6'd1;
			if (pop && count != 7'd0)
				rp <= rp + 6'd1;
			count <= count + 7'((push && count != 7'd64) ? 1 : 0) - 7'((pop && count != 7'd0) ? 1 : 0);
		end
	end

	assign nonempty  = (count != 7'd0);
	assign half_full = (count >= 7'd32);

endmodule
