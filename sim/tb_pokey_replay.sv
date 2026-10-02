// Replay a POKEY write log (tb_load +pokeylog: "ms reg value" per line)
// into one POKEY on its own and report, per 16 ms frame, how many times
// each channel's output changed. Runs in seconds what the whole core takes
// hours to reach. Writes in the same ms are spaced 4 CPU cycles apart.
//   +log=FILE  +from=MS +to=MS (report window)
`timescale 1ns/1ps
module tb_pokey_replay;
	logic clk = 0;
	always #34.92 clk = ~clk;
	// CPU cycles of 8 clk (1.79 MHz), or of 12 (the 7800's slow TIA/RIOT
	// cycles) for +slow=PCT percent of them, phase 1 first, phase 2 halfway.
	int slow_pct = 0;
	initial void'($value$plusargs("slow=%d", slow_pct));
	logic [3:0] ph = 0, len = 8;
	always @(posedge clk) begin
		if (ph == len - 1) begin
			ph <= 0;
			len <= ($urandom % 100 < slow_pct) ? 4'd12 : 4'd8;
		end else ph <= ph + 1;
	end
	wire phi1 = ph == 4'd0;
	wire phi2 = ph == len / 2;

	logic [3:0] addr = 0; logic [7:0] din = 0; logic wr = 0; logic rst_n = 0;
	wire [3:0] c [4]; wire [15:0] aud;
	pokey_adapter dut (
		.CLK(clk), .PHI1_EN(phi1), .PHI2_EN(phi2), .ADDR(addr), .DATA_IN(din),
		.WR_EN(wr), .RESET_N(rst_n),
		.keyboard_scan_enable(1'b0), .keyboard_scan(), .keyboard_response(2'b11),
		.POT_IN(8'h00), .SIO_IN1(1'b1), .SIO_IN2(1'b1), .SIO_IN3(1'b1),
		.SIO_OUT1(), .SIO_OUT2(), .SIO_OUT3(), .SIO_CLOCKIN_IN(1'b1),
		.SIO_CLOCKIN_OUT(), .SIO_CLOCKIN_OE(), .SIO_CLOCKOUT(),
		.DATA_OUT(), .CHANNEL_0_OUT(c[0]), .CHANNEL_1_OUT(c[1]), .CHANNEL_2_OUT(c[2]),
		.CHANNEL_3_OUT(c[3]), .AUD(aud), .IRQ_N_OUT(), .POT_RESET());

	longint cyc = 0;
	always @(posedge clk) cyc <= cyc + 1;
	logic [15:0] amin = 16'hFFFF, amax = 0;
	always @(posedge clk) begin
		if (aud < amin) amin <= aud;
		if (aud > amax) amax <= aud;
	end
	int tog [4]; logic [3:0] oc [4];
	always @(posedge clk) for (int i = 0; i < 4; i++) begin
		oc[i] <= c[i];
		if (c[i] != oc[i]) tog[i] <= tog[i] + 1;
	end

	task automatic w(input [3:0] a, input [7:0] d);
		@(posedge clk iff ph == 4'd1);
		addr = a; din = d; wr = 1;
		@(posedge clk iff ph == 4'd1);
		wr = 0;
	endtask

	int from_ms = 0, to_ms = 1000000, start_ms = 0;
	initial void'($value$plusargs("start=%d", start_ms));
	initial begin
		void'($value$plusargs("from=%d", from_ms));
		void'($value$plusargs("to=%d", to_ms));
		fork
			forever begin   // report every 16 ms frame in the window
				automatic longint t0 = cyc;
				automatic int t[4];
				for (int i = 0; i < 4; i++) t[i] = tog[i];
				repeat (14318 * 16) @(posedge clk);
				if (t0 / 14318 + start_ms >= from_ms && t0 / 14318 + start_ms < to_ms)
					$display("FRAME %6d ms  toggles ch1 %4d ch2 %4d ch3 %4d ch4 %4d  aud %5d..%5d",
						t0 / 14318 + start_ms, tog[0] - t[0], tog[1] - t[1], tog[2] - t[2], tog[3] - t[3], amin, amax);
				amin = 16'hFFFF; amax = 0;
			end
		join_none
	end

	string path; int fd, ms, r, v, n;
	initial begin
		if (!$value$plusargs("log=%s", path)) path = "pokey_writes.txt";
		fd = $fopen(path, "r");
		repeat (64) @(posedge clk); rst_n = 1;
		repeat (64) @(posedge clk);
		begin
			// +start: the register values as of START go in first.
			automatic logic [7:0] st [16];
			automatic logic seen [16];
			for (int i = 0; i < 16; i++) seen[i] = 0;
			while (start_ms > 0 && $fscanf(fd, "%d %h %h", ms, r, v) == 3 && ms < start_ms) begin
				st[r[3:0]] = v[7:0]; seen[r[3:0]] = 1;
			end
			if (start_ms > 0) begin
				if (seen[15]) w(4'hF, st[15]);
				for (int i = 0; i < 9; i++) if (seen[i]) w(i[3:0], st[i]);
			end
		end
		if (start_ms > 0) begin   // the line read past START still applies
			while (cyc < longint'(ms - start_ms) * 14318) @(posedge clk);
			w(r[3:0], v[7:0]);
		end
		while ($fscanf(fd, "%d %h %h", ms, r, v) == 3) begin
			while (cyc < longint'(ms - start_ms) * 14318) @(posedge clk);
			w(r[3:0], v[7:0]);
			repeat (16) @(posedge clk);
		end
		repeat (14318 * 20) @(posedge clk);
		$finish;
	end
endmodule
