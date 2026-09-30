// Unit test for virtual_axis.sv: how a D-pad press or an analog stick moves
// a virtual paddle / crosshair axis. One clock per 1 kHz tick, so a
// simulated "ms" is a tick.
`timescale 1ns/1ps

module tb_virtual_axis;
	logic clk = 0, reset = 1, neg = 0, pos = 0, slow = 0, fast = 0;
	logic [7:0] analog = 8'd0;
	wire  [7:0] position;
	wire [15:0] phase;
	always #5 clk = ~clk;

	virtual_axis dut (.clk(clk), .reset(reset), .tick(1'b1), .neg(neg), .pos(pos),
		.slow(slow), .fast(fast), .analog(analog), .position(position), .phase(phase));

	task automatic ms(int n); repeat (n) @(posedge clk); endtask

	// Hold a direction target the position reaches `target`; report the time.
	task automatic travel(string what, bit right, bit s, bit f, logic [7:0] target);
		int t = 0;
		neg = !right; pos = right; slow = s; fast = f;
		while ((right ? position < target : position > target) && t < 10000) begin ms(1); t++; end
		neg = 0; pos = 0; slow = 0; fast = 0; ms(1);
		$display("AXIS %-28s %4d ms to reach %3d", what, t, target);
	endtask

	initial begin
		ms(3); reset = 0; ms(3);
		$display("AXIS start at %0d", position);
		// A tap: one 16 ms press (a frame).
		pos = 1; ms(16); pos = 0; ms(1);
		$display("AXIS 16 ms tap right: %0d", position);
		travel("right to the end", 1, 0, 0, 8'd255);
		travel("left across, normal", 0, 0, 0, 8'd0);
		travel("right across, fast (Y)", 1, 0, 1, 8'd255);
		travel("left 64, slow (X)", 0, 1, 0, 8'd191);
		for (int mode = 0; mode < 2; mode++) begin
			automatic int steps = 0, shortest = 1000, since = 0;
			automatic logic [1:0] q = phase[15:14];
			pos = 1; fast = mode;
			for (int t = 0; t < 1000; t++) begin
				ms(1); since++;
				if (phase[15:14] != q) begin
					q = phase[15:14]; steps++;
					if (t > 300 && since < shortest) shortest = since;
					since = 0;
				end
			end
			pos = 0; fast = 0; ms(1);
			$display("AXIS driving, 1 s right%0s: %0d gray steps, %0d ms apart at full speed",
				mode ? " fast (Y)" : "", steps, shortest);
		end
		// Analog: the stick rests at 0 on a controller without one (the
		// value captured at reset), so a jump to 200 takes over.
		analog = 8'd200; ms(40);
		$display("AXIS stick 200 -> position %0d after 40 ms", position);
		analog = 8'd60; ms(40);
		$display("AXIS stick 60 -> position %0d after 40 ms", position);
		neg = 1; ms(20); neg = 0; ms(1);
		analog = 8'd250; ms(40);
		$display("AXIS D-pad press (rest now 60), then stick 250: %0d", position);
		begin
			automatic int steps = 0, since = 0, shortest = 1000;
			automatic logic [1:0] q = phase[15:14];
			analog = 8'd255;
			for (int t = 0; t < 1000; t++) begin
				ms(1); since++;
				if (phase[15:14] != q) begin q = phase[15:14]; steps++; if (steps > 1 && since < shortest) shortest = since; since = 0; end
			end
			$display("AXIS driving, stick pushed fully right 1 s: %0d gray steps, %0d ms apart", steps, shortest);
		end
		$finish;
	end
endmodule
