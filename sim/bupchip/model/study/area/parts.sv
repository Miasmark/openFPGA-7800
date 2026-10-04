// Datapath blocks of the S1/S3 core for Yosys cell counts (docs/BUPCHIP_CORE.md,
// "Datapath blocks"): p_shift and p_shift2 (two shifter forms), p_alu, p_mul,
// p_ld (load lanes), p_rf (register file), p_pe (LDM/STM priority encoder).
// Written only to be counted; never simulated. run_area.sh synthesises them.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module p_shift(input [31:0] rb, input [7:0] imm8, input [3:0] rot, input isimm, input [1:0] t, input [7:0] amt, input imm0chk, output [31:0] out);
	logic [31:0] sh_in, rotv, mask; logic [1:0] sh_t; logic [7:0] sh_a; logic big;
	always_comb begin
		if (isimm) begin sh_in = {24'b0, imm8}; sh_t = 2'd3; sh_a = {3'b0, rot, 1'b0}; end
		else begin sh_in = rb; sh_t = t; sh_a = amt; end
		big = (sh_a[7:5] != 0) || (imm0chk && !isimm && sh_a[4:0] == 0 && (sh_t == 1 || sh_t == 2));
		rotv = (sh_t == 2'd0) ? ((sh_in << sh_a[4:0]) | (sh_a[4:0] == 0 ? 32'b0 : (sh_in >> (6'd32 - {1'b0, sh_a[4:0]}))))
		                      : ((sh_in >> sh_a[4:0]) | (sh_a[4:0] == 0 ? 32'b0 : (sh_in << (6'd32 - {1'b0, sh_a[4:0]}))));
		mask = (sh_t == 2'd0) ? (32'hFFFFFFFF << sh_a[4:0]) : (sh_t == 2'd3) ? 32'hFFFFFFFF : (32'hFFFFFFFF >> sh_a[4:0]);
		if (big && sh_t != 2'd3) mask = 32'b0;
	end
	assign out = (rotv & mask) | ({32{sh_t == 2'd2 && sh_in[31]}} & ~mask);
endmodule
// rotator form: one right-rotator, LSL as rotate right by (32-n)
module p_shift2(input [31:0] rb, input [7:0] imm8, input [3:0] rot, input isimm, input [1:0] t, input [7:0] amt, input imm0chk, output [31:0] out);
	logic [31:0] sh_in, r, mask; logic [1:0] sh_t; logic [7:0] sh_a; logic big; logic [4:0] ra;
	always_comb begin
		if (isimm) begin sh_in = {24'b0, imm8}; sh_t = 2'd3; sh_a = {3'b0, rot, 1'b0}; end
		else begin sh_in = rb; sh_t = t; sh_a = amt; end
		big = (sh_a[7:5] != 0) || (imm0chk && !isimm && sh_a[4:0] == 0 && (sh_t == 1 || sh_t == 2));
		ra = (sh_t == 2'd0) ? (5'd0 - sh_a[4:0]) : sh_a[4:0];
		r = sh_in;
		if (ra[0]) r = {r[0], r[31:1]};
		if (ra[1]) r = {r[1:0], r[31:2]};
		if (ra[2]) r = {r[3:0], r[31:4]};
		if (ra[3]) r = {r[7:0], r[31:8]};
		if (ra[4]) r = {r[15:0], r[31:16]};
		for (int i = 0; i < 32; i++)
			mask[i] = (sh_t == 2'd3) ? 1'b1 : big ? 1'b0 : (sh_t == 2'd0) ? (i >= sh_a[4:0]) : (i < 32 - sh_a[4:0]);
	end
	assign out = (r & mask) | ({32{sh_t == 2'd2 && sh_in[31]}} & ~mask);
endmodule
module p_alu(input [31:0] opA, opB, input [3:0] aop, input C, output [31:0] res, output co, output ovf);
	logic invA, invB, cin, arith; logic [32:0] sum; logic [31:0] lres;
	always_comb begin
		invA  = aop == 4'd3 || aop == 4'd7;
		invB  = aop == 4'd2 || aop == 4'd6 || aop == 4'd10;
		cin   = (aop == 4'd2 || aop == 4'd3 || aop == 4'd10) ? 1'b1 : (aop == 4'd5 || aop == 4'd6 || aop == 4'd7) ? C : 1'b0;
		arith = aop[3:1] == 3'b001 || aop[3:2] == 2'b01 || aop[3:1] == 3'b101;
		sum   = {1'b0, opA ^ {32{invA}}} + {1'b0, opB ^ {32{invB}}} + {32'b0, cin};
		case (aop)
			4'd0, 4'd8: lres = opA & opB; 4'd1, 4'd9: lres = opA ^ opB; 4'd12: lres = opA | opB;
			4'd13: lres = opB; 4'd14: lres = opA & ~opB; default: lres = ~opB;
		endcase
	end
	assign res = arith ? sum[31:0] : lres;
	assign co = sum[32];
	assign ovf = ((opA[31] ^ invA) == (opB[31] ^ invB)) && (sum[31] != (opA[31] ^ invA));
endmodule
module p_mul(input clk, input [31:0] a, b, output reg [63:0] p);
	always @(posedge clk) p <= a * b;
endmodule
module p_rf(input clk, input we, input [3:0] wa, ra, rb, input [31:0] wd, output [31:0] qa, qb);
	logic [31:0] rf [0:15];
	always_ff @(posedge clk) if (we) rf[wa] <= wd;
	assign qa = rf[ra]; assign qb = rf[rb];
endmodule
module p_pe(input [15:0] v, input up, output [3:0] idx, output [15:0] rest);
	function automatic [3:0] lowest(input [15:0] x); lowest = 0; for (int i = 15; i >= 0; i--) if (x[i]) lowest = i[3:0]; endfunction
	function automatic [3:0] highest(input [15:0] x); highest = 0; for (int i = 0; i < 16; i++) if (x[i]) highest = i[3:0]; endfunction
	assign idx = up ? lowest(v) : highest(v);
	assign rest = v & ~(16'd1 << idx);
endmodule
module p_ld(input [31:0] raw, input [1:0] lane, sz, input sgn, output reg [31:0] ldata);
	always_comb begin
		logic [7:0] b; logic [15:0] h;
		b = raw[{lane, 3'b000} +: 8]; h = lane[1] ? raw[31:16] : raw[15:0];
		case (sz) 2'd0: ldata = {{24{sgn & b[7]}}, b}; 2'd1: ldata = {{16{sgn & h[15]}}, h}; default: ldata = raw; endcase
	end
endmodule
