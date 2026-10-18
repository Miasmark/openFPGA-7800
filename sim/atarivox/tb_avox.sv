// Unit test for the AtariVox (src/fpga/core/atarivox): sends bytes on the
// serial line as a game does (one whenever DOWN is high, 8N1 at 744 clocks a
// bit) and logs, by clock (0 = the first clock out of reset):
//   P clk byte     a byte entering the buffer
//   A clk / R clk  serial control R (abort) / V ("Ready")
//   O clk sample   an output sample (the engine's out 0)
// tools/atarivox/vox_check.py replays the P/A/R events through the emulator
// and compares every O line.
//
//   +bytes=FILE    hex bytes, one per line ("gap N" waits N ms)
//   +ms=N          run N ms after the last byte (default 400)
//   +pal           PAL tick divider
//
// MIT licence, as the rest of the Pocket port's own code.
`timescale 1ns/1ps
module tb_avox;
	logic clk = 0, reset = 1, line = 1, pal = 0;
	always #34.92 clk = ~clk;          // 14.318 MHz

	wire down_n;
	wire signed [15:0] sample;
	atarivox dut (.clk(clk), .reset(reset), .pal(pal), .line(line), .down_n(down_n), .sample(sample));

	longint cyc = 0;
	integer lf;
	always @(posedge clk) begin
		if (reset) cyc <= 0;
		else begin
			cyc <= cyc + 1;
			if (dut.rx.push && dut.rx.count != 7'd64) $fwrite(lf, "P %0d %0d\n", cyc, dut.rx.got_byte);
			if (dut.rx.abort_set) $fwrite(lf, "A %0d\n", cyc);
			if (dut.rx.ready_set) $fwrite(lf, "R %0d\n", cyc);
			if (dut.engine.sample_strobe) $fwrite(lf, "O %0d %0d\n", cyc - 1, sample);
		end
	end

	task automatic send(input [7:0] b);
		integer i;
		while (!down_n) @(posedge clk);
		line = 0; repeat (744) @(posedge clk);
		for (i = 0; i < 8; i++) begin line = b[i]; repeat (744) @(posedge clk); end
		line = 1; repeat (744) @(posedge clk);
	endtask

	initial begin
		string path, w;
		integer f, ms, n, v;
		if (!$value$plusargs("ms=%d", ms)) ms = 400;
		pal = $test$plusargs("pal");
		lf = $fopen("avox.log", "w");
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (20000) @(posedge clk);          // the engine's start-up
		if ($value$plusargs("bytes=%s", path)) begin
			f = $fopen(path, "r");
			while ($fscanf(f, "%s", w) == 1) begin
				if (w == "gap") begin
					n = $fscanf(f, "%d", v);
					repeat (v * 14318) @(posedge clk);
				end else begin
					n = $sscanf(w, "%h", v);
					send(v[7:0]);
				end
			end
			$fclose(f);
		end
		repeat (ms * 14318) @(posedge clk);
		$fclose(lf);
		$finish;
	end
endmodule
