// Standalone POKEY test: sweep AUDF1 in a chosen AUDC/AUDCTL mode and count
// channel 1 output transitions over a window, for comparison against
// pokey_model.py (the documented divider + polynomial behaviour).
//   +audc=HEX  +audctl=HEX  +ms=N (window per AUDF value)
`timescale 1ns/1ps
module tb_pokey;
	logic clk = 0;
	always #34.92 clk = ~clk;                  // 14.318 MHz
	// CPU at 1.79 MHz: phi1 then phi2, one clk each, 8 clks per CPU cycle
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

	// One CPU write cycle. Address, data and the strobe stay valid until the
	// next cycle starts, as on the cartridge bus: POKEY samples them across
	// the whole phase 2 half, which runs up to the next phase 1.
	task automatic w(input [3:0] a, input [7:0] d);
		@(posedge clk iff ph == 3'd1);
		addr = a; din = d; wr = 1;
		@(posedge clk iff ph == 3'd1);
		wr = 0;
	endtask

	longint toggles = 0; logic [3:0] old_c0 = 0; logic counting = 0;
	longint now = 0, last_edge = 0, min_iv = 0, max_iv = 0;
	always @(posedge clk) begin
		now <= now + 1;
		old_c0 <= c0;
		if (counting && c0 != old_c0) begin
			toggles <= toggles + 1;
			if (last_edge != 0) begin
				if (min_iv == 0 || now - last_edge < min_iv) min_iv <= now - last_edge;
				if (now - last_edge > max_iv) max_iv <= now - last_edge;
			end
			last_edge <= now;
		end
	end

	int audc, audctl, ms;
	// +rewrite: like Ballblazer's PokeyFlushShadow, write AUDF1 and AUDC1 again
	// with the same values every frame (16.7 ms) while measuring.
	logic rewrite = 0;
	logic [7:0] cur_f;
	initial begin
		if (!$value$plusargs("audc=%h", audc)) audc = 'hC8;
		if (!$value$plusargs("audctl=%h", audctl)) audctl = 0;
		if (!$value$plusargs("ms=%d", ms)) ms = 20;
		rewrite = $test$plusargs("rewrite");
		repeat (64) @(posedge clk);
		rst_n = 1;
		repeat (64) @(posedge clk);
		w(4'hF, 8'h03);            // SKCTL: out of init (the adapter does this too)
		w(4'h8, audctl[7:0]);
		w(4'h1, audc[7:0]);        // AUDC1
		for (int f = 0; f < 256; f++) begin
			w(4'h0, f[7:0]);       // AUDF1
			repeat (14318 * 2) @(posedge clk);   // settle 2 ms
			toggles = 0; counting = 1;
			if (rewrite) begin
				for (int t = 0; t < ms; t += 17) begin
					w(4'h0, f[7:0]);
					w(4'h1, audc[7:0]);
					repeat (14318 * 17 - 32) @(posedge clk);
				end
			end else
				repeat (14318 * ms) @(posedge clk);
			counting = 0;
			$display("AUDF %0d %0d interval %0d..%0d clk", f, toggles, min_iv, max_iv);
			last_edge = 0; min_iv = 0; max_iv = 0;
		end
		$finish;
	end
endmodule
