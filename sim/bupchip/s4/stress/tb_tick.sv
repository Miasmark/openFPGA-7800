//------------------------------------------------------------------------------
// bup_tick48k (src/fpga/core/bupchip/bup_tick48k.sv) across the clk_74a ->
// clk_arm crossing, for step 4 of docs/BUPCHIP_CORE.md: clk_74a at 74.25 MHz
// plus +ppm (default 0) with a random start phase and +jit74=PS of random
// extra per half period, clk_arm at +arm_mhz (default 28.636364) with its own
// random phase and +jitarm=PS. Over +ms milliseconds (default 50):
//   - every flip of the clk_74a toggle gives exactly one tick on clk_arm, in
//     order, 2 to 4 clk_arm edges after the flip (two flops and the edge
//     detect, plus the phase), and every tick is one clk_arm clock long;
//   - the flips come exactly every 12,375 / 8 clk_74a clocks on average:
//     48,000 a second at 74.25 MHz.
// The last line, "result: ...", is for run_tick.sh.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_tick;
	real    arm_mhz = 28.636364, ppm = 0.0;
	longint jit74 = 0, jitarm = 0, ms = 50;
	logic   clk_74a = 0, clk_arm = 0;
	longint h74, harm;

	wire tick;
	bup_tick48k dut (.clk_74a, .clk_arm, .tick);

	initial begin
		void'($value$plusargs("arm_mhz=%f", arm_mhz));
		void'($value$plusargs("ppm=%f", ppm));
		void'($value$plusargs("jit74=%d", jit74));
		void'($value$plusargs("jitarm=%d", jitarm));
		void'($value$plusargs("ms=%d", ms));
		begin
			int s;
			s = 1;
			void'($value$plusargs("seed=%d", s));
			void'($urandom(s));
		end
		h74 = longint'(1.0e6 / (74.25 * (1.0 + ppm * 1.0e-6)) / 2.0 + 0.5);
		harm = longint'(1.0e6 / arm_mhz / 2.0 + 0.5);
		fork
			begin
				#($urandom_range(int'(2 * h74)));
				forever begin #(h74 + (jit74 > 0 ? $urandom_range(int'(jit74)) : 0)); clk_74a = ~clk_74a; end
			end
			begin
				#($urandom_range(int'(2 * harm)));
				forever begin #(harm + (jitarm > 0 ? $urandom_range(int'(jitarm)) : 0)); clk_arm = ~clk_arm; end
			end
		join_none
	end

	// flips of the toggle, with the clk_arm edge count at the time
	longint n74 = 0, nflip = 0, narm = 0, nticks = 0, bad = 0, lat_min = 99, lat_max = 0, first74 = -1, last74 = -1;
	longint flip_arm [$];
	logic   tog_q = 0;
	always @(posedge clk_74a) begin
		n74++;
		#1;
		if (dut.tog != tog_q) begin
			tog_q = dut.tog;
			nflip++;
			flip_arm.push_back(narm);
			if (first74 < 0) first74 = n74;
			last74 = n74;
		end
	end
	logic tick_q = 0;
	always @(posedge clk_arm) begin
		narm++;
		if (tick) begin
			if (tick_q) begin
				if (bad < 5) $display("tick high for two clocks at clk_arm edge %0d", narm);
				bad++;
			end
			if (flip_arm.size() == 0) begin
				if (bad < 5) $display("tick at clk_arm edge %0d with no flip before it", narm);
				bad++;
			end else begin
				longint l;
				l = narm - flip_arm.pop_front();
				if (l < lat_min) lat_min = l;
				if (l > lat_max) lat_max = l;
				if (l < 2 || l > 4) begin
					if (bad < 5) $display("tick %0d edges after its flip", l);
					bad++;
				end
			end
			nticks++;
		end
		tick_q = tick;
	end

	initial begin
		#(ms * 1000000000);
		// the flips still in flight have not ticked yet
		$display("tick48k: clk_74a %.6f MHz (%+.1f ppm, jitter %0d ps), clk_arm %.6f MHz (jitter %0d ps), %0d ms",
			1.0e6 / (2.0 * h74), ppm, jit74, 1.0e6 / (2.0 * harm), jitarm, ms);
		$display("  %0d flips, %0d ticks (%0d flips not yet seen), %0d errors; latency %0d..%0d clk_arm edges",
			nflip, nticks, flip_arm.size(), bad, lat_min, lat_max);
		$display("  clk_74a clocks per flip: %.4f (12,375 / 8 = 1546.875)", real'(last74 - first74) / real'(nflip - 1));
		$display("result: flips=%0d ticks=%0d pending=%0d bad=%0d per=%.4f", nflip, nticks, flip_arm.size(), bad,
			real'(last74 - first74) / real'(nflip - 1));
		$finish;
	end
endmodule
