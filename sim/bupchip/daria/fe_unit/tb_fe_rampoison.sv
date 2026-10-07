//------------------------------------------------------------------------------
// tb_fe_rampoison: daria_mem.sv's daria_ram model with and without
// DARIA_RAM_POISON (docs/daria_fe/design.md 12.1; run_unit.sh POISON=1).
// With it: (a) after a partial byte-enable write the next clock's q of that
// port shows $A5 in the bytes not enabled; (b) a read on one port of a word
// the other port writes at the same time step returns $A5A5A5A5, and stays
// so until the reading port's next edge, even across an edge of the writing
// port in between. Without it: the merged word, and the old word.
// r1: both ports on one clock net. r2: port A on a fast clock, port B on a
// slow one whose edges coincide with every other fast edge. r3: r2 with the
// ports' roles swapped. r4, r5: as r2 and r3, but the writing port's clock
// is an NBA copy of the fast clock, so its edge comes later in the same time
// step and the reading port's block always runs first (the model's other
// order; Verilator runs the writer first in r1-r3). r6: two clocks whose
// edges are 0.3 ns apart, inside one 1-ns unit of $time: a read just after
// and a read just before the other port's write are no collision (review
// R-1, docs/daria_fe/interfaces.md).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_fe_rampoison;
`ifdef DARIA_RAM_POISON
	localparam bit POISON = 1'b1;
`else
	localparam bit POISON = 1'b0;
`endif
	int errors = 0;
	task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] poisoned,
			input logic [31:0] normal);
		logic [31:0] want;
		want = POISON ? poisoned : normal;
		if (got !== want) begin
			errors++;
			$display("FAIL at %0t: %s: q %h, want %h", $time, what, got, want);
		end
	endtask

	// ---- r1: one clock net ----------------------------------------------------------
	logic clk = 1'b0;
	always #5 clk = ~clk;
	logic  [3:0] aa = '0, ab = '0, bea = '0, beb = '0;
	logic        wea = 1'b0, web = 1'b0;
	logic [31:0] wda = '0, wdb = '0;
	wire  [31:0] qa, qb;
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r1 (
		.clk_a(clk), .addr_a(aa), .we_a(wea), .be_a(bea), .wd_a(wda), .q_a(qa),
		.clk_b(clk), .addr_b(ab), .we_b(web), .be_b(beb), .wd_b(wdb), .q_b(qb));

	task automatic edge1;
		@(posedge clk);
		#1;
	endtask

	// ---- r2 / r3: a fast and a slow clock with coincident edges ------------------------
	logic cf = 1'b0, cs = 1'b0;          // rising: cf at 5, 15, 25, ...; cs at 5, 25, 45, ...
	initial begin #5 cf = 1'b1; forever #5 cf = ~cf; end
	initial begin #5 cs = 1'b1; forever #10 cs = ~cs; end
	logic  [3:0] a2 = '0, b2 = '0, a3 = '0, b3 = '0;
	logic        we2 = 1'b0, we3 = 1'b0;
	logic [31:0] wd2 = '0, wd3 = '0;
	wire  [31:0] qa2, qb2, qa3, qb3;
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r2 (      // A writes on the fast clock, B reads on the slow
		.clk_a(cf), .addr_a(a2), .we_a(we2), .be_a(4'hF), .wd_a(wd2), .q_a(qa2),
		.clk_b(cs), .addr_b(b2), .we_b(1'b0), .be_b(4'h0), .wd_b(32'd0), .q_b(qb2));
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r3 (      // B writes on the fast clock, A reads on the slow
		.clk_a(cs), .addr_a(a3), .we_a(1'b0), .be_a(4'h0), .wd_a(32'd0), .q_a(qa3),
		.clk_b(cf), .addr_b(b3), .we_b(we3), .be_b(4'hF), .wd_b(wd3), .q_b(qb3));

	logic cfl = 1'b0;                     // cf, one NBA later in the same time step
	always @(cf) cfl <= cf;
	logic  [3:0] a4 = '0, b4 = '0, a5 = '0, b5 = '0;
	wire  [31:0] qa4, qb4, qa5, qb5;
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r4 (      // as r2, the writer's edge late
		.clk_a(cfl), .addr_a(a4), .we_a(we2), .be_a(4'hF), .wd_a(wd2), .q_a(qa4),
		.clk_b(cs), .addr_b(b4), .we_b(1'b0), .be_b(4'h0), .wd_b(32'd0), .q_b(qb4));
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r5 (      // as r3, the writer's edge late
		.clk_a(cs), .addr_a(a5), .we_a(1'b0), .be_a(4'h0), .wd_a(32'd0), .q_a(qa5),
		.clk_b(cfl), .addr_b(b5), .we_b(we3), .be_b(4'hF), .wd_b(wd3), .q_b(qb5));

	initial begin
		// r2-r5: the coincident edge at 25 writes word 7 on the fast port and
		// reads it on the slow one; the fast edge at 35 writes word 9.
		#20;
		a2 = 4'd7; we2 = 1'b1; wd2 = 32'h7777_7777; b2 = 4'd7;
		b3 = 4'd7; we3 = 1'b1; wd3 = 32'h7777_7777; a3 = 4'd7;
		a4 = 4'd7; b4 = 4'd7; a5 = 4'd7; b5 = 4'd7;
		#6;                                       // 26
		expect32("r2 (b) slow read of the fast write", qb2, 32'hA5A5_A5A5, 32'h0);
		expect32("r3 (b) slow read of the fast write", qa3, 32'hA5A5_A5A5, 32'h0);
		expect32("r4 (b) slow read of the late fast write", qb4, 32'hA5A5_A5A5, 32'h0);
		expect32("r5 (b) slow read of the late fast write", qa5, 32'hA5A5_A5A5, 32'h0);
		a2 = 4'd9; wd2 = 32'h9999_9999; a4 = 4'd9;
		b3 = 4'd9; wd3 = 32'h9999_9999; b5 = 4'd9;
		#10;                                      // 36: after the fast edge at 35
		expect32("r2 (b) held over a fast edge", qb2, 32'hA5A5_A5A5, 32'h0);
		expect32("r3 (b) held over a fast edge", qa3, 32'hA5A5_A5A5, 32'h0);
		expect32("r4 (b) held over a fast edge", qb4, 32'hA5A5_A5A5, 32'h0);
		expect32("r5 (b) held over a fast edge", qa5, 32'hA5A5_A5A5, 32'h0);
		we2 = 1'b0; we3 = 1'b0;
		#10;                                      // 46: after the slow edge at 45
		expect32("r2 slow read after", qb2, 32'h7777_7777, 32'h7777_7777);
		expect32("r3 slow read after", qa3, 32'h7777_7777, 32'h7777_7777);
		expect32("r4 slow read after", qb4, 32'h7777_7777, 32'h7777_7777);
		expect32("r5 slow read after", qa5, 32'h7777_7777, 32'h7777_7777);
	end

	// ---- r6: edges 0.3 ns apart are two time steps ----------------------------------
	logic c6a = 1'b0, c6b = 1'b0, we6 = 1'b0;
	logic [31:0] wd6 = 32'h2222_2222;
	wire  [31:0] qa6, qb6;
	daria_ram #(.AW(4), .MAX_DEPTH(16)) r6 (
		.clk_a(c6a), .addr_a(4'd2), .we_a(we6), .be_a(4'hF), .wd_a(wd6), .q_a(qa6),
		.clk_b(c6b), .addr_b(4'd2), .we_b(1'b0), .be_b(4'h0), .wd_b(32'd0), .q_b(qb6));
	initial begin
		#99 we6 = 1'b1;
		#1 c6a = 1'b1;                            // 100.0: A writes word 2
		#0.3 c6b = 1'b1;                          // 100.3: B reads it, one time step later
		#0.7 we6 = 1'b0;                          // 101.0
		expect32("r6 a read 0.3 ns after the other port's write", qb6, 32'h2222_2222, 32'h2222_2222);
		#2 c6a = 1'b0; c6b = 1'b0;                // 103.0
		wd6 = 32'h3333_3333;
		#2.7 c6b = 1'b1;                          // 105.7: B reads word 2
		we6 = 1'b1;
		#0.3 c6a = 1'b1;                          // 106.0: A writes it, one time step later
		#1 we6 = 1'b0;                            // 107.0
		expect32("r6 a read 0.3 ns before the other port's write", qb6, 32'h2222_2222, 32'h2222_2222);
		expect32("r6 the writer's q", qa6, 32'h3333_3333, 32'h3333_3333);
	end

	initial begin
		@(negedge clk);
		aa = 4'd3; wea = 1'b1; bea = 4'hF; wda = 32'h1122_3344;
		edge1;
		expect32("r1 full write, q", qa, 32'h1122_3344, 32'h1122_3344);
		aa = 4'd3; wea = 1'b1; bea = 4'b0011; wda = 32'hAABB_CCDD;
		edge1;
		expect32("r1 (a) partial write, q", qa, 32'hA5A5_CCDD, 32'h1122_CCDD);
		wea = 1'b0;
		edge1;
		expect32("r1 read after the partial write", qa, 32'h1122_CCDD, 32'h1122_CCDD);
		aa = 4'd5; wea = 1'b1; bea = 4'hF; wda = 32'h5555_5555; ab = 4'd5;
		edge1;
		expect32("r1 (b) B reads A's write", qb, 32'hA5A5_A5A5, 32'h0);
		expect32("r1 A's own q", qa, 32'h5555_5555, 32'h5555_5555);
		wea = 1'b0;
		edge1;
		expect32("r1 B reads after", qb, 32'h5555_5555, 32'h5555_5555);
		ab = 4'd6; web = 1'b1; beb = 4'hF; wdb = 32'h6666_6666; aa = 4'd6;
		edge1;
		expect32("r1 (b) A reads B's write", qa, 32'hA5A5_A5A5, 32'h0);
		web = 1'b0;
		edge1;
		expect32("r1 A reads after", qa, 32'h6666_6666, 32'h6666_6666);
		aa = 4'd7; wea = 1'b1; bea = 4'hF; wda = 32'h7777_7777; ab = 4'd8;
		edge1;
		expect32("r1 other address, no poison", qb, 32'h0, 32'h0);
		ab = 4'd3; web = 1'b1; beb = 4'b1000; wdb = 32'hEE00_0000; wea = 1'b0;
		edge1;
		expect32("r1 (a) on port B", qb, 32'hEEA5_A5A5, 32'hEE22_CCDD);
		web = 1'b0;
		#40;
		$display("tb_fe_rampoison (%s): %0d errors", POISON ? "DARIA_RAM_POISON" : "default model", errors);
		if (errors != 0) $fatal(1, "tb_fe_rampoison: FAIL");
		$display("tb_fe_rampoison: PASS");
		$finish;
	end
endmodule

`default_nettype wire
