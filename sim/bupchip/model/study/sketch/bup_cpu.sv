// Sketch of the proposed small BupChip CPU (ARMv4 ARM-state subset) for the
// Analogue Pocket.  Scratch / proposal code, written from the ARM ARM, not
// derived from arm7tdmi_core.sv.  v2: area-trimmed.
//
// Pipeline: "fetch" is the ROM M10K address register; the next PC is
// computed in the execute cycle and drives the ROM address directly, so a
// taken B/BL/BX costs nothing.  X = decode + RF read (MLAB, async) + shift +
// ALU + memory address in one clock.  Loads finish in W (data out of the
// RAM/ROM M10K), so they take 2 clocks.  One RF write port; every RF write
// except load data goes through the ALU.
//
// Not supported (halt): Thumb, SWI, coprocessor, SWP, DP write to PC,
// LDM/STM with PC or ^ or an empty list.  LDM/STM only to ROM/RAM.  MSR is
// ignored; MRS returns {NZCV,20'b0,8'hD3}.  Logical S-ops with a register
// operand leave C unchanged (the firmware has none).  Unaligned LDR/LDRH are
// not rotated (the firmware has none).  Long multiplies are all UMULL.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_cpu #(
	parameter ROM_HEX = "bupchip.hex"
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        ce,          // run: 0 freezes everything (pause, hold)

	// slow bus for MMIO and the asset window (request held from W until ack)
	output logic        eb_valid,
	output logic [31:0] eb_addr,
	output logic        eb_we,
	output logic [31:0] eb_wdata,
	output logic  [1:0] eb_size,
	input  logic        eb_ack,
	input  logic [31:0] eb_rdata,    // aligned 32-bit word, lane-correct

	output logic        halted
`ifndef SYNTH
	, output logic        retire,
	output logic [31:0] retire_pc,
	output logic [31:0] retire_ir
`endif
);
	// ------------------------------------------------------------ memories
	logic [31:0] rom [0:2047];
	initial $readmemh(ROM_HEX, rom);
	logic [10:0] nf;                 // next fetch word address
	logic [31:0] ir, rom_b_q;
	logic [31:0] ram [0:4095];
	logic [31:0] ram_q;
	logic [31:0] daddr;
	logic        ram_we;
	logic  [3:0] ram_be;
	logic [31:0] st_data;

	always_ff @(posedge clk) if (ce) begin
		ir      <= rom[nf];
		rom_b_q <= rom[daddr[12:2]];
	end
	always_ff @(posedge clk) if (ce) begin
		if (ram_we) begin
			if (ram_be[0]) ram[daddr[13:2]][7:0]   <= st_data[7:0];
			if (ram_be[1]) ram[daddr[13:2]][15:8]  <= st_data[15:8];
			if (ram_be[2]) ram[daddr[13:2]][23:16] <= st_data[23:16];
			if (ram_be[3]) ram[daddr[13:2]][31:24] <= st_data[31:24];
		end
		ram_q <= ram[daddr[13:2]];
	end

	// ------------------------------------------------------------ register file
	logic [31:0] rf [0:15];          // r0-r14 (LUTRAM); r15 is pc
	logic        rf_we;
	logic  [3:0] rf_wa, ra_a, ra_b;
	logic [31:0] rf_wd;
	always_ff @(posedge clk) if (ce && rf_we) rf[rf_wa] <= rf_wd;

	logic [10:0] pc;                 // word address of the instruction in X
	wire  [10:0] pc1 = pc + 11'd1;
	wire  [10:0] pc2 = pc + 11'd2;
	wire  [31:0] ra = (ra_a == 4'd15) ? {19'b0, pc2, 2'b00} : rf[ra_a];
	wire  [31:0] rb = (ra_b == 4'd15) ? {19'b0, pc2, 2'b00} : rf[ra_b];

	typedef enum logic [2:0] {S_X, S_W, S_RS, S_M2, S_M3, S_BDT, S_HALT} st_t;
	st_t st;
	logic N, Z, C, V;

	// ------------------------------------------------------------ decode
	logic cpass;
	always_comb case (ir[31:28])
		4'h0: cpass = Z;          4'h1: cpass = !Z;
		4'h2: cpass = C;          4'h3: cpass = !C;
		4'h4: cpass = N;          4'h5: cpass = !N;
		4'h6: cpass = V;          4'h7: cpass = !V;
		4'h8: cpass = C && !Z;    4'h9: cpass = !C || Z;
		4'hA: cpass = N == V;     4'hB: cpass = N != V;
		4'hC: cpass = !Z && N == V; 4'hD: cpass = Z || N != V;
		4'hE: cpass = 1'b1;       default: cpass = 1'b0;
	endcase
	wire i_bx   = ir[27:4] == 24'h12FFF1;
	wire i_mul  = ir[27:22] == 6'b000000 && ir[7:4] == 4'b1001;
	wire i_mull = ir[27:23] == 5'b00001  && ir[7:4] == 4'b1001;
	wire i_ext  = ir[27:25] == 3'b000 && ir[7] && ir[4];
	wire i_hw   = i_ext && ir[6:5] != 2'b00;
	wire i_swp  = i_ext && ir[6:5] == 2'b00 && !i_mul && !i_mull;
	wire i_psr  = ir[27:26] == 2'b00 && ir[24:23] == 2'b10 && !ir[20] && !i_ext && !i_bx;
	wire i_dp   = ir[27:26] == 2'b00 && !i_ext && !i_psr && !i_bx;
	wire i_sdt  = ir[27:26] == 2'b01;
	wire i_bdt  = ir[27:25] == 3'b100;
	wire i_b    = ir[27:25] == 3'b101;
	wire i_cop  = ir[27:26] == 2'b11 || (i_sdt && ir[25] && ir[4]);
	wire [3:0] f_rn = ir[19:16], f_rd = ir[15:12], f_rs = ir[11:8], f_rm = ir[3:0];
	wire dp_regsh = i_dp && !ir[25] && ir[4];
	wire dp_cmp   = ir[24:23] == 2'b10;
	wire mem_l    = ir[20];
	wire mem_p    = ir[24], mem_u = ir[23], mem_w = ir[21];
	wire sdt_reg  = i_sdt && ir[25];
	wire hw_reg   = i_hw && !ir[22];
	wire regoff   = sdt_reg || hw_reg;
	wire is_store = (i_sdt || i_hw) && !mem_l;
	wire wb_base  = (i_sdt || i_hw) && (!mem_p || mem_w);
	// access size: 0 byte, 1 half, 2 word
	wire [1:0] msz = i_sdt ? (ir[22] ? 2'd0 : 2'd2) : i_hw ? (ir[5] ? 2'd1 : 2'd0) : 2'd2;

	// ------------------------------------------------------------ LDM/STM state
	logic [15:0] rem;
	logic  [3:0] prev_idx;
	logic        bdt_first, have_prev, moff;
	logic [31:0] maddr;
	function automatic [3:0] lowest(input [15:0] v);
		lowest = 4'd0;
		for (int i = 15; i >= 0; i--) if (v[i]) lowest = i[3:0];
	endfunction
	wire  [3:0] bidx  = lowest(rem);
	wire [15:0] brest = rem & ~(16'd1 << bidx);
	logic [4:0] popc;
	always_comb begin
		popc = 5'd0;
		for (int i = 0; i < 16; i++) popc = popc + {4'd0, ir[i]};
	end

	// ------------------------------------------------------------ RF read ports
	always_comb begin
		ra_a = f_rn;
		ra_b = f_rm;
		case (st)
			S_X: begin
				if (dp_regsh || i_mul || i_mull) ra_a = f_rs;
				if (is_store && !regoff) ra_b = f_rd;
			end
			S_W:   ra_b = f_rd;           // store data of 2-clock stores
			S_M2:  ra_a = f_rd;           // MLA accumulator (bits 15:12)
			S_BDT: ra_b = bidx;
			default: ;
		endcase
	end

	// ------------------------------------------------------------ shifter (one right-rotator)
	logic [7:0]  rs_amt;
	logic [31:0] sh_in, sh_out, rot, mask;
	logic [1:0]  sh_t;
	logic [7:0]  sh_a;
	logic [4:0]  rr;
	logic        sh_big;
	always_comb begin
		if (i_dp && ir[25]) begin
			sh_in = {24'b0, ir[7:0]}; sh_t = 2'd3; sh_a = {3'b0, ir[11:8], 1'b0};
		end else begin
			sh_in = rb; sh_t = ir[6:5];
			sh_a  = (st == S_RS) ? rs_amt : {3'b0, ir[11:7]};
		end
		sh_big = (sh_a[7:5] != 3'b0) ||
		         (st != S_RS && !(i_dp && ir[25]) && sh_a[4:0] == 5'd0 && (sh_t == 2'd1 || sh_t == 2'd2));
		rr  = (sh_t == 2'd0) ? (5'd0 - sh_a[4:0]) : sh_a[4:0];
		rot = sh_in;
		if (rr[0]) rot = {rot[0],    rot[31:1]};
		if (rr[1]) rot = {rot[1:0],  rot[31:2]};
		if (rr[2]) rot = {rot[3:0],  rot[31:4]};
		if (rr[3]) rot = {rot[7:0],  rot[31:8]};
		if (rr[4]) rot = {rot[15:0], rot[31:16]};
		mask = (sh_t == 2'd3) ? 32'hFFFFFFFF : sh_big ? 32'b0 :
		       (sh_t == 2'd0) ? (32'hFFFFFFFF << sh_a[4:0]) : (32'hFFFFFFFF >> sh_a[4:0]);
		sh_out = (rot & mask) | ({32{sh_t == 2'd2 && sh_in[31]}} & ~mask);
	end

	// ------------------------------------------------------------ multiplier (DSP)
	logic [63:0] prod;

	// ------------------------------------------------------------ ALU (all RF writes but load data)
	logic [31:0] opA, opB, res, lres;
	logic [3:0]  aop;
	logic [32:0] sum;
	logic        invA, invB, cin, arith, ovf;
	always_comb begin
		opA = ra;
		opB = sh_out;
		aop = ir[24:21];
		case (st)
			S_M2: begin opA = ir[21] ? ra : 32'b0; opB = prod[31:0]; aop = 4'd4; end
			S_M3: begin opB = prod[63:32]; aop = 4'd13; end
			default:
				if (i_sdt || i_hw) begin
					opB = sdt_reg ? sh_out : i_hw ? (hw_reg ? rb : {24'b0, ir[11:8], ir[3:0]}) : {20'b0, ir[11:0]};
					aop = mem_u ? 4'd4 : 4'd2;
				end else if (i_bdt) begin
					opB = {25'b0, popc, 2'b00};
					aop = mem_u ? 4'd4 : 4'd2;
				end else if (i_b) begin
					opB = {19'b0, pc1, 2'b00}; aop = 4'd13;
				end else if (i_psr) begin
					opB = {N, Z, C, V, 20'b0, 8'hD3}; aop = 4'd13;
				end
		endcase
		invA  = aop == 4'd3 || aop == 4'd7;
		invB  = aop == 4'd2 || aop == 4'd6 || aop == 4'd10;
		cin   = (aop == 4'd2 || aop == 4'd3 || aop == 4'd10) ? 1'b1 :
		        (aop == 4'd5 || aop == 4'd6 || aop == 4'd7)  ? C : 1'b0;
		arith = aop[3:1] == 3'b001 || aop[3:2] == 2'b01 || aop[3:1] == 3'b101;
		sum   = {1'b0, opA ^ {32{invA}}} + {1'b0, opB ^ {32{invB}}} + {32'b0, cin};
		ovf   = ((opA[31] ^ invA) == (opB[31] ^ invB)) && (sum[31] != (opA[31] ^ invA));
		case (aop)
			4'd0, 4'd8: lres = opA & opB;
			4'd1, 4'd9: lres = opA ^ opB;
			4'd12:      lres = opA | opB;
			4'd13:      lres = opB;
			4'd14:      lres = opA & ~opB;
			default:    lres = ~opB;
		endcase
		res = arith ? sum[31:0] : lres;
	end

	// ------------------------------------------------------------ load lane extraction (W)
	logic [1:0]  w_src;              // 0 ROM, 1 RAM, 2 EXT
	logic [1:0]  w_lane;
	wire  [31:0] raw = (w_src == 2'd0) ? rom_b_q : (w_src == 2'd1) ? ram_q : eb_rdata;
	wire  [1:0]  lsz = (st == S_BDT) ? 2'd2 : msz;
	wire         lsgn = i_hw && ir[6];
	logic [31:0] ldata;
	always_comb begin
		logic [7:0] b; logic [15:0] h;
		b = raw[{w_lane, 3'b000} +: 8];
		h = w_lane[1] ? raw[31:16] : raw[15:0];
		case (lsz)
			2'd0:    ldata = {{24{lsgn & b[7]}}, b};
			2'd1:    ldata = {{16{lsgn & h[15]}}, h};
			default: ldata = raw;
		endcase
	end

	// ------------------------------------------------------------ data address, regions
	wire [31:0] addr_x = mem_p ? sum[31:0] : ra;
	always_comb daddr = (st == S_X) ? addr_x : maddr;
	wire rg_rom  = daddr[31:28] == 4'h0 && !daddr[25];
	wire rg_ast  = daddr[31:28] == 4'h0 &&  daddr[25];
	wire rg_ram  = daddr[31:28] == 4'h4;
	wire rg_mmio = daddr[31:28] == 4'hE;
	wire [1:0] ssz = (st == S_BDT) ? 2'd2 : msz;
	always_comb begin
		st_data = (ssz == 2'd0) ? {4{rb[7:0]}} : (ssz == 2'd1) ? {2{rb[15:0]}} : rb;
		case (ssz)
			2'd0:    ram_be = 4'b0001 << daddr[1:0];
			2'd1:    ram_be = daddr[1] ? 4'b1100 : 4'b0011;
			default: ram_be = 4'b1111;
		endcase
	end
	assign eb_addr  = maddr;
	assign eb_wdata = st_data;
	assign eb_we    = is_store;
	assign eb_size  = msz;

	// ------------------------------------------------------------ control
	logic done, halt_now;
	st_t  nst;
	wire [10:0] tgt = pc2 + ir[10:0];
	always_comb begin
		nst = st; done = 1'b0; halt_now = 1'b0;
		rf_we = 1'b0; rf_wa = f_rd; rf_wd = res; ram_we = 1'b0;
		nf = pc;
		case (st)
			S_X: begin
				done = 1'b1;
				if (cpass) begin
					if (i_cop || i_swp || (i_dp && !dp_cmp && f_rd == 4'd15) ||
					    (i_bdt && (ir[22] || ir[15] || ir[15:0] == 16'b0)) || (i_bx && rb[0])) begin
						halt_now = 1'b1; done = 1'b0;
					end else if (i_dp) begin
						if (dp_regsh) begin nst = S_RS; done = 1'b0; end
						else rf_we = !dp_cmp;
					end else if (i_psr) begin
						rf_we = !ir[21];
					end else if (i_b) begin
						if (ir[24]) begin rf_we = 1'b1; rf_wa = 4'd14; end
					end else if (i_mul || i_mull) begin
						nst = S_M2; done = 1'b0;
					end else if (i_sdt || i_hw) begin
						rf_we = wb_base; rf_wa = f_rn;
						if (!(rg_rom || rg_ram || rg_ast || rg_mmio) || (!mem_l && (rg_rom || rg_ast))) begin
							halt_now = 1'b1; done = 1'b0; rf_we = 1'b0;
						end else if (mem_l || rg_mmio || regoff) begin
							nst = S_W; done = 1'b0;
						end else
							ram_we = rg_ram;
					end else if (i_bdt) begin
						rf_we = mem_w; rf_wa = f_rn;           // final base, before any beat
						nst = S_BDT; done = 1'b0;
					end
				end
			end
			S_RS: begin done = 1'b1; rf_we = !dp_cmp; end
			S_W: begin
				if (w_src != 2'd2 || eb_ack) begin
					done = 1'b1;
					ram_we = is_store && w_src == 2'd1;
					rf_we = mem_l && f_rd != 4'd15; rf_wd = ldata;
				end
			end
			S_M2: begin
				rf_we = 1'b1;
				if (i_mull) begin rf_wa = f_rd; nst = S_M3; end
				else begin rf_wa = f_rn; done = 1'b1; end
			end
			S_M3: begin rf_we = 1'b1; rf_wa = f_rn; done = 1'b1; end
			S_BDT: if (!bdt_first) begin
				if (mem_l && have_prev) begin rf_we = 1'b1; rf_wa = prev_idx; rf_wd = ldata; end
				if (rem != 16'b0) begin
					ram_we = !mem_l && w_src == 2'd1;
					if (!mem_l && brest == 16'b0) done = 1'b1;
				end else
					done = 1'b1;
			end
			default: ;   // S_HALT
		endcase
		// next fetch address
		if (done) begin
			nf = pc1;
			if (st == S_X && cpass && i_b)  nf = tgt;
			if (st == S_X && cpass && i_bx) nf = rb[12:2];
			if (st == S_W && mem_l && f_rd == 4'd15) nf = ldata[12:2];
		end
		if (rst) nf = 11'd0;
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			st <= S_X; pc <= 11'd0; {N, Z, C, V} <= 4'b0;
			eb_valid <= 1'b0; halted <= 1'b0;
		end else if (ce) begin
			pc <= nf;
			if (halt_now) begin st <= S_HALT; halted <= 1'b1; end
			else if (done) st <= S_X;
			else st <= nst;
			if (((st == S_X && i_dp && !dp_regsh) || st == S_RS) && cpass && ir[20]) begin
				N <= res[31]; Z <= res == 32'b0;
				if (arith) begin C <= sum[32]; V <= ovf; end
				else if (ir[25] && ir[11:8] != 4'd0) C <= sh_out[31];
			end
			if (st == S_M2 && i_mul && ir[20]) begin N <= res[31]; Z <= res == 32'b0; end
			case (st)
				S_X: if (cpass) begin
					rs_amt <= ra[7:0];
					prod   <= rb * ra;
					maddr  <= i_bdt ? (mem_u ? ra : sum[31:0]) : addr_x;
					w_lane <= daddr[1:0];
					w_src  <= rg_rom ? 2'd0 : rg_ram ? 2'd1 : 2'd2;
					moff   <= mem_u ? mem_p : !mem_p;
					rem    <= ir[15:0];
					bdt_first <= 1'b1; have_prev <= 1'b0;
					if ((i_sdt || i_hw) && (rg_ast || rg_mmio) && !halt_now) eb_valid <= 1'b1;
				end
				S_W: if (eb_ack) eb_valid <= 1'b0;
				S_BDT: begin
					bdt_first <= 1'b0;
					if (bdt_first) maddr <= maddr + {29'b0, moff, 2'b00};
					else if (rem != 16'b0) begin
						rem <= brest; prev_idx <= bidx; maddr <= maddr + 32'd4;
						have_prev <= 1'b1; w_lane <= 2'd0;
					end
				end
				default: ;
			endcase
		end
	end

`ifndef SYNTH
	always_ff @(posedge clk) if (rst) retire <= 1'b0; else if (ce) begin
		retire <= done;
		if (done) begin retire_pc <= {19'b0, pc, 2'b00}; retire_ir <= ir; end
	end
`endif
endmodule
