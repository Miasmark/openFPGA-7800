// Test for core/pll_region.v against a model of altera_pll_reconfig with
// WAIT_FOR_LOCK: waitrequest is held for a few clocks after each write, and
// after the start command the PLL drops lock, relocks, and only then is
// waitrequest released. The real PLL is not modelled; this checks the
// sequence, the values and the guard times.
`timescale 1ns/1ps
module tb_pll_region;
	logic clk = 0; always #6.734 clk = ~clk;
	logic is_pal = 0, loading = 0, locked = 1, waitreq = 0;
	wire busy, cfg_write; wire [5:0] cfg_address; wire [31:0] cfg_writedata;

	pll_region dut (.clk, .is_pal, .loading, .pll_locked(locked), .busy,
		.cfg_waitrequest(waitreq), .cfg_write, .cfg_address, .cfg_writedata);

	int errors = 0, writes = 0, starts = 0;
	longint busy_rise, start_at, relock_at, busy_fall;
	logic [31:0] frac;
	logic busy_d = 0;

	// Controller model
	int wr_hold = 0, relock = 0;
	always @(posedge clk) begin
		busy_d <= busy;
		if (busy && !busy_d) busy_rise = $time;
		if (!busy && busy_d) busy_fall = $time;
		if (wr_hold) begin wr_hold--; if (wr_hold == 0 && relock == 0) waitreq <= 0; end
		if (relock) begin
			relock--;
			if (relock == 900) locked <= 0;
			if (relock == 0) begin locked <= 1; waitreq <= 0; relock_at = $time; end
		end
		if (cfg_write) begin
			if (waitreq) begin $display("FAIL write while waitrequest"); errors++; end
			writes++;
			waitreq <= 1; wr_hold = 3;
			if (cfg_address == 6'd7) frac = cfg_writedata;
			else if (cfg_address == 6'd2) begin
				starts++; start_at = $time; relock = 1000;
				if (loading) begin $display("FAIL started while loading"); errors++; end
			end else begin $display("FAIL write to register %0d", cfg_address); errors++; end
		end
	end

	task automatic expect_switch(string what, logic [31:0] want);
		int s0 = starts;
		wait (busy); wait (!busy); repeat (2) @(posedge clk);
		if (starts != s0 + 1) begin $display("FAIL %0s: %0d starts", what, starts - s0); errors++; end
		if (frac != want) begin $display("FAIL %0s: fraction %0d, want %0d", what, frac, want); errors++; end
		$display("%0s: fraction %0d, reset held %.1f us before the start and %.1f us after relock",
			what, frac, (start_at - busy_rise) / 1000.0, (busy_fall - relock_at) / 1000.0);
		if (start_at - busy_rise < 3000 || busy_fall - relock_at < 3000) begin
			$display("FAIL %0s: guard time under 3 us", what); errors++;
		end
	endtask

	initial begin
		repeat (2000) @(posedge clk);
		if (busy || writes) begin $display("FAIL retuned at power-up in NTSC"); errors++; end

		// A PAL cart: the header sets the region mid-download; nothing may
		// happen until the download ends.
		loading = 1; repeat (100) @(posedge clk); is_pal = 1;
		repeat (5000) @(posedge clk);
		if (busy || writes) begin $display("FAIL retuned during a download"); errors++; end
		loading = 0;
		expect_switch("NTSC -> PAL", 32'd737741760);

		repeat (3000) @(posedge clk);
		if (busy) begin $display("FAIL retuned again with the region unchanged"); errors++; end

		is_pal = 0;
		expect_switch("PAL -> NTSC", 32'd1100363522);

		$display("PLL_REGION %0s (%0d errors)", errors ? "FAIL" : "pass", errors);
		$finish;
	end
endmodule
