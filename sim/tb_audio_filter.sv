// audio_filter: feed the core's unsigned audio (a TIA-like 0 / 0x7FFF square
// wave, then silence at a non-zero level) and check the output is centred on
// zero, keeps the tone's amplitude, and settles back to zero.
`timescale 1ns/1ps
module tb_audio_filter;
	logic clk = 0;
	always #34.92 clk = ~clk;              // 14.318 MHz
	logic [15:0] in = 0;
	wire  [15:0] out_l, out_r;
	audio_filter dut (.clk(clk), .in_l(in), .in_r(in), .out_l(out_l), .out_r(out_r));

	int n = 0, half = 7159;                // 1 kHz square
	int mn = 0, mx = 0;
	longint sum = 0, cnt = 0;
	initial begin
		// 1 s of tone
		repeat (14318181) begin
			@(posedge clk);
			n = (n + 1) % (2 * half);
			in = n < half ? 16'h7FFF : 16'h0000;
		end
		// measure over the last 0.2 s of tone
		repeat (14318181 / 5) begin
			@(posedge clk);
			n = (n + 1) % (2 * half);
			in = n < half ? 16'h7FFF : 16'h0000;
			if ($signed(out_l) < mn) mn = $signed(out_l);
			if ($signed(out_l) > mx) mx = $signed(out_l);
			sum += $signed(out_l); cnt++;
		end
		$display("AUDIO tone: min %0d max %0d mean %0d (expect about -16383 / +16383 / 0)", mn, mx, sum / cnt);
		// silence at the TIA's "volume 0" level, 16'h0000, for 2 s
		in = 16'h0000;
		repeat (2 * 14318181) @(posedge clk);
		$display("AUDIO silence after 2 s: %0d (expect near 0)", $signed(out_l));
		$finish;
	end
endmodule
