// Does a POKEY keep playing after a short trip through init mode?
// Ballblazer re-initialises POKEY with SKCTL $00 then $03 only 6 CPU cycles
// apart (its routine at $B11D); at power-on the gap is ~25 cycles. Plays a
// channel 1 tone (or noise), counts its output transitions per 20 ms window
// before and after each kind of init, and reports both.
//   +audc=HEX (default AF, pure tone)  +audctl=HEX (default 00: 64 kHz)
`timescale 1ns/1ps
module tb_pokey_init;
	logic clk = 0;
	always #34.92 clk = ~clk;                  // 14.318 MHz
	logic [2:0] ph = 0;
	always @(posedge clk) ph <= ph + 1;
	wire phi1 = ph == 3'd0;
	wire phi2 = ph == 3'd4;

	logic [3:0] addr = 0; logic [7:0] din = 0; logic wr = 0; logic rst_n = 0;
	wire [3:0] c0, c1, c2, c3; wire [15:0] aud;

	pokey_adapter dut (
		.CLK(clk), .PHI1_EN(phi1), .PHI2_EN(phi2), .ADDR(addr), .DATA_IN(din),
		.WR_EN(wr), .RESET_N(rst_n),
		.keyboard_scan_enable(1'b0), .keyboard_scan(), .keyboard_response(2'b11),
		.POT_IN(8'h00), .SIO_IN1(1'b1), .SIO_IN2(1'b1), .SIO_IN3(1'b1),
		.SIO_OUT1(), .SIO_OUT2(), .SIO_OUT3(), .SIO_CLOCKIN_IN(1'b1),
		.SIO_CLOCKIN_OUT(), .SIO_CLOCKIN_OE(), .SIO_CLOCKOUT(),
		.DATA_OUT(), .CHANNEL_0_OUT(c0), .CHANNEL_1_OUT(c1), .CHANNEL_2_OUT(c2),
		.CHANNEL_3_OUT(c3), .AUD(aud), .IRQ_N_OUT(), .POT_RESET());

	task automatic w(input [3:0] a, input [7:0] d);
		@(posedge clk iff ph == 3'd1);
		addr = a; din = d; wr = 1;
		@(posedge clk iff ph == 3'd1);
		wr = 0;
	endtask

	longint toggles = 0; logic [3:0] old_c0 = 0;
	always @(posedge clk) begin
		old_c0 <= c0;
		if (c0 != old_c0) toggles <= toggles + 1;
	end

	task automatic window(string what);
		longint t0 = toggles;
		repeat (14318 * 20) @(posedge clk);
		$display("INIT %-40s %6d transitions in 20 ms", what, toggles - t0);
	endtask

	// SKCTL $00, then $03 `gap` CPU cycles later (the write itself is one).
	task automatic reinit(int gap);
		w(4'hF, 8'h00);
		repeat ((gap - 1) * 8) @(posedge clk);
		w(4'hF, 8'h03);
	endtask

	int audc, audctl;
	initial begin
		if (!$value$plusargs("audc=%h", audc)) audc = 'hAF;
		if (!$value$plusargs("audctl=%h", audctl)) audctl = 0;
		repeat (64) @(posedge clk);
		rst_n = 1;
		repeat (64) @(posedge clk);
		w(4'hF, 8'h03);
		w(4'h8, audctl[7:0]);
		w(4'h0, 8'h40);            // AUDF1
		w(4'h1, audc[7:0]);        // AUDC1
		repeat (14318 * 5) @(posedge clk);
		window("before any re-init");
		if ($test$plusargs("siren")) begin
			// Ballblazer's interrupt-driven effect ($FDF4..$FE49): AUDCTL $60
			// (channels 1 and 3 on 1.79 MHz), AUDF1 $FA, AUDF3 $FF, then each
			// interrupt writes AUDF1..4 and steps them by $01,$22,$01,$22-ish,
			// with AUDC $Ax volumes ramping. ~1 s at 60 Hz, then the game's
			// $B11D: SKCTL $00/$03 six cycles apart, AUDCTL 0.
			automatic logic [7:0] f [4] = '{8'hFA, 8'h80, 8'hFF, 8'h40};
			automatic logic [7:0] step [4] = '{8'h01, 8'h22, 8'h01, 8'h22};
			w(4'h8, 8'h60);
			for (int fr = 0; fr < 60; fr++) begin
				automatic logic [7:0] v = 8'hA0 | ((fr >> 1) & 8'h0F);
				w(4'h1, v); w(4'h3, v); w(4'h5, v); w(4'h7, v ^ 8'h60);
				for (int c = 3; c >= 0; c--) begin
					w(4'(c * 2), f[c]);
					f[c] = f[c] + step[c];
				end
				repeat (14318 * 16) @(posedge clk);
			end
			window("during the siren (AUDCTL $60)");
			reinit(6);
			w(4'h8, 8'h00);
			w(4'h1, 8'h00); w(4'h3, 8'h00); w(4'h5, 8'h00); w(4'h7, 8'h00);
			// The music resumes: a pure tone on channel 1, 64 kHz clock.
			w(4'h0, 8'h40); w(4'h1, audc[7:0]);
			window("music after siren + $B11D re-init");
			window("  ...next 20 ms");
			repeat (14318 * 200) @(posedge clk);
			window("  ...200 ms later");
			$finish;
		end
		reinit(25);
		window("after SKCTL 00->03, 25 cycles (power-on)");
		reinit(6);
		window("after SKCTL 00->03, 6 cycles ($B11D)");
		window("  ...and the next 20 ms");
		reinit(2);
		window("after SKCTL 00->03, 2 cycles");
		w(4'h0, 8'h40); w(4'h1, audc[7:0]);
		window("after rewriting AUDF1/AUDC1");
		$finish;
	end
endmodule
