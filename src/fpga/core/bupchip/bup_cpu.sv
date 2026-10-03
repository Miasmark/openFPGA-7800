//------------------------------------------------------------------------------
// The BupChip CPU, configuration S1 (docs/BUPCHIP_CORE.md): the ARMv4
// ARM-state subset that CoreTone's firmware (mister/rtl/bupchip.hex) uses,
// built small for the Pocket. Written from the ARM Architecture Reference
// Manual (ARMv4) and the design document; the reference core
// (arm7tdmi_core.sv, GPL-2.0-only) is used only as a simulation oracle.
// condition_pass, shift_register and ror32 come from the MIT arm7tdmi_pkg.
//
// Rule: an encoding either does exactly what an ARM7TDMI does, or the core
// halts (halt_code, halt_pc). Nothing is silently different.
//
// Pipeline. The ROM's port A address register is the fetch register: the
// next PC (rom_addr) is computed during execute and the ROM's unregistered
// output (rom_q) is decoded straight away, so a taken branch costs nothing.
// An instruction that needs more than one clock holds the PC, and the ROM
// keeps returning the same word. Clocks per instruction:
//
//   data processing, MRS, MSR, B, BL, BX, a failed condition   1
//   data processing with a shift by register                   2
//   load (ROM, RAM, assets, MMIO), LDR pc                       2 (+ w_wait)
//   store with an immediate offset to RAM                       1
//   store with a register offset, store to MMIO                 2
//   MUL, MLA / UMULL                                            2 / 3
//   STM / LDM of n registers                                    n+1 / n+2
//
// The second clock of a load, a two-clock store or an MMIO access is W: the
// access address was registered at the end of execute, the ROM, RAM and
// asset memories answer in W, and the peripheral sees reg_sel during W. The
// register file has one write port and two asynchronous read ports (MLAB),
// with last clock's write bypassed so nothing depends on when an MLAB write
// becomes visible.
//
// Memory map (bupchip_memory.sv). The region is picked from address bits
// [31:28] and [25] when the access is made; the exact window checks run on
// the registered address one clock later and halt the core if they fail:
//
//   0x00000000-0x00003FFF  ROM: fetch on port A, data on port B; no stores
//   0x02000000 + [0, asset_size)  assets, read-only; W waits on w_wait
//   0x40000000-0x40003FFF  RAM, byte lanes
//   0xE0009000-0xE00090FF  MMIO (bupchip_peripheral.sv), in W
//
// A one-clock RAM store, and an STM beat, is written at the end of its clock,
// before its check: one to 0x4xxxxxxx beyond the RAM lands in the RAM's
// alias and then halts (the design's "wild store"). Every other failed
// access writes nothing.
//
// Halt codes (halt_pc is the address of the instruction responsible):
//
//   1  UNDEF   encoding outside the subset: SWP, SWI, coprocessor, undefined,
//              SPSR access, MSR of the x or s field, multiplies with S, long
//              multiplies other than UMULL, LDRD/STRD space, LDM/STM with S,
//              with PC in the list or with an empty list; and (one clock
//              later) MSR writing a control byte other than 0xD3 or CPSR
//              bits 27:24, which this core does not have
//   2  REG     r15 where the ARM7TDMI reads PC + 12 or the result is
//              UNPREDICTABLE: a data-processing destination, the operands of
//              a shift by register, a multiply, a write-back base, a store's
//              data, a register offset, LDRB/LDRH/LDRSB/LDRSH into PC, BX
//              PC, MRS/MSR; and UMULL with RdHi == RdLo
//   3  THUMB   BX to an address with bit 0 set (one clock later)
//   4  FETCH   B, BL, BX or LDR pc to a target outside the ROM, or not word
//              aligned (one clock later)
//   5  DATA    a load or store outside every window, or past asset_size
//   6  RO      a store to the ROM or the asset window
//   7  BLOCK   LDM/STM outside the ROM and RAM (STM to ROM is RO)
//
// Interface notes:
//   - rst is synchronous. After it falls the core spends 15 clocks writing 0
//     to r0-r14 (the reference core resets its registers to 0, and CoreTone
//     pushes registers it has never written), then fetches from 0.
//   - freeze (the debug throttle) holds off the start of an instruction.
//     An instruction that has started always runs to its end, and W always
//     completes, so every MMIO access happens exactly once.
//   - w_wait holds W: the asset data is not there yet. While it is high the
//     ROM, RAM and asset addresses stay on the access. The wrapper must
//     never raise it for an MMIO access: reg_sel would stay high, and the
//     peripheral acts on every clock it sees reg_sel.
//   - asset_q is the aligned asset word at w_addr; the core does the lane
//     rotation and extension.
//   - The retire port (simulation only, as cache_ram.v keeps its models out
//     of Quartus) follows sim/bupchip/verif/README.md: rt_start on the first
//     clock of every instruction, rt_valid on its last, and every register
//     write on port E (results, write-backs, links) or W (load data).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_cpu
	import arm7tdmi_pkg::*;
(
	input  wire         clk,            // clk_arm
	input  wire         rst,            // held: reset, then clear r0-r14
	input  wire         freeze,         // do not start an instruction this clock
	input  wire         w_wait,         // the asset load in W has no data yet

	// Fetch: ROM port A. The ROM registers rom_addr; rom_q is the word at
	// the address presented one clock earlier.
	output logic [11:0] rom_addr,
	input  wire  [31:0] rom_q,

	// Data. d_addr is this clock's access address (execute, or an LDM/STM
	// beat) and otherwise the registered address of the access in W. ROM port
	// B and RAM port A take d_addr[13:2].
	output logic [31:0] d_addr,
	output logic        ram_we,
	output logic  [3:0] ram_be,
	output logic [31:0] ram_wdata,
	input  wire  [31:0] rom_dq,         // ROM port B
	input  wire  [31:0] ram_q,          // RAM port A

	// Assets.
	input  wire  [23:0] asset_size,     // bytes; offsets at or above it halt
	input  wire  [31:0] asset_q,        // aligned word at w_addr, when !w_wait
	output logic        w_asset,        // W holds an asset load
	output logic [31:0] w_addr,         // the access in W
	output logic  [1:0] w_size,         // 0 byte, 1 halfword, 2 word

	// MMIO (bupchip_peripheral.sv), during W.
	output logic        reg_sel,
	output logic  [7:0] reg_addr,
	output logic        reg_write,
	output logic [31:0] reg_wdata,
	input  wire  [31:0] reg_rdata,

	// Status: sticky until rst.
	output logic        halted,
	output logic  [3:0] halt_code,
	output logic [31:0] halt_pc
`ifndef ALTERA_RESERVED_QIS
	,
	// Retire port (sim/bupchip/verif/README.md), sampled on every edge.
	output logic        rt_start,
	output logic        rt_valid,
	output logic [31:0] rt_pc,
	output logic [31:0] rt_insn,
	output logic  [3:0] rt_nzcv,
	output logic        rt_e_we,
	output logic  [3:0] rt_e_idx,
	output logic [31:0] rt_e_data,
	output logic        rt_w_we,
	output logic  [3:0] rt_w_idx,
	output logic [31:0] rt_w_data
`endif
);
	localparam logic [3:0] HALT_UNDEF = 4'd1;
	localparam logic [3:0] HALT_REG   = 4'd2;
	localparam logic [3:0] HALT_THUMB = 4'd3;
	localparam logic [3:0] HALT_FETCH = 4'd4;
	localparam logic [3:0] HALT_DATA  = 4'd5;
	localparam logic [3:0] HALT_RO    = 4'd6;
	localparam logic [3:0] HALT_BLOCK = 4'd7;

	// Data-processing opcodes (ARM ARM A3.4), as used by the ALU below.
	localparam logic [3:0] OP_AND = 4'h0, OP_EOR = 4'h1, OP_SUB = 4'h2, OP_RSB = 4'h3;
	localparam logic [3:0] OP_ADD = 4'h4, OP_ADC = 4'h5, OP_SBC = 4'h6, OP_RSC = 4'h7;
	localparam logic [3:0] OP_TST = 4'h8, OP_TEQ = 4'h9, OP_CMP = 4'hA, OP_CMN = 4'hB;
	localparam logic [3:0] OP_ORR = 4'hC, OP_MOV = 4'hD, OP_BIC = 4'hE, OP_MVN = 4'hF;

	// Memory regions, from address bits [31:28] and [25].
	localparam logic [1:0] RG_ROM = 2'd0, RG_RAM = 2'd1, RG_AST = 2'd2, RG_IO = 2'd3;

	function automatic logic [1:0] region(input logic [31:0] a);
		case (a[31:28])
			4'h4:    region = RG_RAM;
			4'hE:    region = RG_IO;
			default: region = a[25] ? RG_AST : RG_ROM;	// 0x0: ROM or assets; others fail the check
		endcase
	endfunction

	// Index of the lowest set bit of a register list (0 for an empty list).
	function automatic logic [3:0] first_reg(input logic [15:0] list);
		logic found;
		first_reg = 4'd0;
		found = 1'b0;
		for (int k = 0; k < 16; k++)
			if (!found && list[k]) begin
				first_reg = 4'(k);
				found = 1'b1;
			end
	endfunction

	function automatic logic [4:0] count_regs(input logic [15:0] list);
		count_regs = 5'd0;
		for (int k = 0; k < 16; k++)
			count_regs = count_regs + {4'd0, list[k]};
	endfunction

	// ---- state ----------------------------------------------------------------
	typedef enum logic [2:0] {
		S_CLEAR,	// writing 0 to r0-r14 after rst
		S_RUN,		// the first (often the only) clock of an instruction
		S_W,		// a load's data, a two-clock store, an MMIO access
		S_SHR2,		// shift by register: the shift and the ALU
		S_MUL2,		// MUL/MLA result, UMULL low word
		S_MUL3,		// UMULL high word
		S_SEQ,		// LDM/STM beats
		S_HALT
	} state_t;

	state_t      state;
	logic [11:0] pc;                // word address of the instruction in rom_q
	logic  [3:0] nzcv;
	logic  [3:0] clr_idx;
	wire         flag_c = nzcv[1];

	wire  [31:0] insn = rom_q;
	wire  [12:0] pc_next1 = {1'b0, pc} + 13'd1;
	wire  [12:0] pc_next2 = {1'b0, pc} + 13'd2;
	wire  [31:0] r15_value = {17'b0, pc_next2, 2'b00};	// the instruction's address + 8
	wire  [31:0] link_value = {17'b0, pc_next1, 2'b00};	// the instruction's address + 4

	// ---- decode ---------------------------------------------------------------
	wire [3:0] f_rn = insn[19:16];
	wire [3:0] f_rd = insn[15:12];
	wire [3:0] f_rs = insn[11:8];
	wire [3:0] f_rm = insn[3:0];
	wire       bit_p = insn[24], bit_u = insn[23], bit_b = insn[22], bit_w = insn[21], bit_l = insn[20];
	wire       cond_ok = condition_pass(insn[31:28], nzcv);

	wire g000 = insn[27:25] == 3'b000;
	wire g001 = insn[27:25] == 3'b001;
	wire ext  = g000 && insn[7] && insn[4];			// multiply, swap and halfword space
	wire psr_space = insn[24:23] == 2'b10 && !bit_l;	// TST..CMN opcodes without S

	wire k_mul  = ext && insn[6:5] == 2'b00 && insn[27:22] == 6'b000000;	// MUL, MLA
	wire k_mull = ext && insn[6:5] == 2'b00 && insn[27:23] == 5'b00001;	// long multiplies
	wire k_xh   = ext && insn[6:5] != 2'b00;		// LDRH, STRH, LDRSB, LDRSH
	wire k_misc = g000 && !ext && psr_space;		// MRS, MSR register, BX
	wire k_dp   = (g000 && !ext && !psr_space) || (g001 && !psr_space);
	wire k_sdt  = insn[27:26] == 2'b01 && !(insn[25] && insn[4]);	// LDR, STR, LDRB, STRB
	wire k_blk  = insn[27:25] == 3'b100;
	wire k_br   = insn[27:25] == 3'b101;
	wire k_bx   = k_misc && insn[27:4] == 24'h12FFF1;
	wire k_mrs  = k_misc && !bit_w && f_rn == 4'hF && insn[11:0] == 12'h000;
	wire k_msr  = (k_misc && bit_w && f_rd == 4'hF && insn[11:4] == 8'h00) ||
	              (g001 && psr_space && bit_w && f_rd == 4'hF);
	wire k_mem  = k_sdt || k_xh;

	// Data processing.
	wire [3:0] dp_op  = insn[24:21];
	wire       dp_cmp = dp_op[3:2] == 2'b10;		// TST TEQ CMP CMN: no result
	wire       dp_mov = dp_op == OP_MOV || dp_op == OP_MVN;	// no Rn
	wire       dp_rsh = k_dp && !insn[25] && insn[4];	// shift amount from Rs

	// Single transfers.
	wire       t_wb     = !bit_p || bit_w;			// post-index always writes back
	wire       t_regoff = (k_sdt && insn[25]) || (k_xh && !bit_b);
	wire [1:0] t_size   = k_sdt ? (bit_b ? 2'd0 : 2'd2) : (insn[5] ? 2'd1 : 2'd0);
	wire       t_sign   = k_xh && insn[6];

	// MSR: the operand, its fields (c 16, x 17, s 18, f 19).
	logic [31:0] msr_value;

	// What halts as soon as it reaches execute (with its condition passing).
	logic       dec_bad;
	logic [3:0] dec_code;
	always_comb begin
		dec_bad = 1'b1;
		dec_code = HALT_UNDEF;
		if (k_dp) begin
			dec_code = HALT_REG;
			// Rd = PC (for TST..CMN the 26-bit "P" forms), and the operands
			// of a shift by register, which the ARM7TDMI reads as PC + 12.
			dec_bad = f_rd == 4'hF ||
				(dp_rsh && (f_rm == 4'hF || f_rs == 4'hF || (!dp_mov && f_rn == 4'hF)));
		end else if (k_mul) begin
			dec_bad = bit_l;				// MULS, MLAS
			if (!bit_l) begin
				dec_code = HALT_REG;
				dec_bad = f_rn == 4'hF || f_rs == 4'hF || f_rm == 4'hF || (bit_w && f_rd == 4'hF);
			end
		end else if (k_mull) begin
			dec_bad = insn[22:20] != 3'b000;		// only UMULL, without S
			if (insn[22:20] == 3'b000) begin
				dec_code = HALT_REG;
				dec_bad = f_rn == 4'hF || f_rd == 4'hF || f_rs == 4'hF || f_rm == 4'hF || f_rn == f_rd;
			end
		end else if (k_xh) begin
			dec_bad = !bit_l && insn[6];			// LDRD/STRD space
			if (!dec_bad) begin
				dec_code = HALT_REG;
				dec_bad = f_rd == 4'hF || (t_wb && f_rn == 4'hF) || (!bit_b && f_rm == 4'hF);
			end
		end else if (k_sdt) begin
			dec_code = HALT_REG;
			dec_bad = (t_wb && f_rn == 4'hF) || (insn[25] && f_rm == 4'hF) ||
				(f_rd == 4'hF && (!bit_l || bit_b));
		end else if (k_blk) begin
			dec_bad = bit_b || insn[15] || insn[15:0] == 16'h0000;	// S, PC in list, empty
			if (!dec_bad) begin
				dec_code = HALT_REG;
				dec_bad = f_rn == 4'hF;
			end
		end else if (k_br) begin
			dec_bad = 1'b0;
		end else if (k_bx) begin
			dec_code = HALT_REG;
			dec_bad = f_rm == 4'hF;
		end else if (k_mrs) begin
			dec_bad = bit_b;				// SPSR
			if (!bit_b) begin
				dec_code = HALT_REG;
				dec_bad = f_rd == 4'hF;
			end
		end else if (k_msr) begin
			dec_bad = bit_b || insn[18:17] != 2'b00;	// SPSR, the x and s fields
			if (!dec_bad && !insn[25]) begin
				dec_code = HALT_REG;
				dec_bad = f_rm == 4'hF;
			end
		end
	end

	// ---- register file ----------------------------------------------------------
	// r0-r14; r15 reads as the instruction's address + 8. Last clock's write is
	// held and bypassed, so an MLAB is only read for data at least two clocks old.
	(* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf [0:15];
	logic        rf_we;
	logic  [3:0] rf_wa;
	logic [31:0] rf_wd;
	logic        rf_w_class;	// for the retire port: 1 = load data (port W)
	logic        byp_we;
	logic  [3:0] byp_idx;
	logic [31:0] byp_data;
	logic  [3:0] ia, ib;

	always_ff @(posedge clk) begin
		if (rf_we) rf[rf_wa] <= rf_wd;
		byp_we <= rf_we;
		byp_idx <= rf_wa;
		byp_data <= rf_wd;
	end

	function automatic logic [31:0] read_reg(input logic [3:0] idx, input logic [31:0] arr,
		input logic hit, input logic [31:0] held, input logic [31:0] r15);
		if (idx == 4'hF) read_reg = r15;
		else if (hit) read_reg = held;
		else read_reg = arr;
	endfunction

	wire [31:0] ra = read_reg(ia, rf[ia], byp_we && byp_idx == ia, byp_data, r15_value);
	wire [31:0] rb = read_reg(ib, rf[ib], byp_we && byp_idx == ib, byp_data, r15_value);

	// ---- LDM/STM sequencer state --------------------------------------------------
	logic [15:0] blk_rest;          // registers still to transfer
	logic [31:0] blk_addr;          // lowest address of the next beat, before pre-increment
	logic        blk_pre4;          // IB and DA: each beat is at blk_addr + 4
	logic        blk_first;
	logic [31:0] blk_wb;            // final base, written in the first beat
	logic        ld_pend;           // LDM: last beat's data arrives this clock
	logic  [3:0] ld_idx;
	wire   [3:0] blk_idx  = first_reg(blk_rest);
	wire  [15:0] blk_left = blk_rest & ~(16'd1 << blk_idx);
	wire  [31:0] beat_addr = blk_addr + {29'd0, blk_pre4, 2'b00};

	// Read port selection.
	always_comb begin
		ia = f_rn;
		ib = f_rm;
		case (state)
			S_RUN: begin
				if (dp_rsh || k_mul || k_mull) ia = f_rs;
				if (k_mem && !bit_l && !t_regoff) ib = f_rd;	// one-clock store data
			end
			S_W:    ib = f_rd;					// two-clock store data
			S_MUL2: ia = f_rd;					// MLA accumulator, bits 15:12
			S_SEQ:  ib = blk_idx;				// STM data
			default: ;
		endcase
	end

	// ---- shifter --------------------------------------------------------------------
	// One shift_register serves the immediate amounts (execute) and the
	// register amounts (the second clock of a shift by register). Immediate
	// amounts of 0 encode LSR #32, ASR #32 and RRX (ARM ARM A5.1);
	// shift_register treats 0 as "no shift", which is right only for LSL #0
	// and for register amounts, so LSR/ASR #0 become 32 and ROR #0 takes its
	// own path.
	logic  [7:0] rs_amt;            // Rs[7:0], latched in the first clock
	logic [31:0] op2;
	logic        op2_c;
	wire   [1:0] sh_type = insn[6:5];
	wire   [4:0] sh_imm  = insn[11:7];
	wire         sh_reg  = state == S_SHR2;
	wire         sh_rrx  = !sh_reg && sh_type == 2'b11 && sh_imm == 5'd0;
	wire   [7:0] sh_amt  = sh_reg ? rs_amt :
	                       (sh_imm == 5'd0 && (sh_type == 2'b01 || sh_type == 2'b10)) ? 8'd32 : {3'b0, sh_imm};
	arm_shift_t  sh_out;
	assign sh_out = shift_register(rb, sh_type, sh_amt, flag_c);
	wire  [31:0] sh_value = sh_rrx ? {flag_c, rb[31:1]} : sh_out.value;
	wire         sh_carry = sh_rrx ? rb[0] : sh_out.carry;
	wire  [31:0] imm_rot = ror32({24'b0, insn[7:0]}, {insn[11:8], 1'b0});

	always_comb begin
		if (insn[25] && !sh_reg) begin
			op2 = imm_rot;
			op2_c = insn[11:8] == 4'd0 ? flag_c : imm_rot[31];
		end else begin
			op2 = sh_value;
			op2_c = sh_carry;
		end
	end

	always_comb msr_value = insn[25] ? imm_rot : rb;

	// ---- multiplier -----------------------------------------------------------------
	logic [63:0] prod;              // Rm * Rs, registered in the first clock

	// ---- ALU ------------------------------------------------------------------------
	// One adder with an optionally inverted operand on each side and a carry
	// in covers ADD, ADC, SUB, SBC, RSB, RSC, CMP, CMN; it also forms
	// transfer addresses, LDM/STM write-backs and the MLA sum.
	logic [31:0] alu_a, alu_b, alu_res, sum;
	logic  [3:0] alu_op;
	logic        add_c, add_v, arith;
	logic  [4:0] n_regs;
	assign n_regs = count_regs(insn[15:0]);

	wire [31:0] t_off = k_sdt ? (insn[25] ? sh_value : {20'b0, insn[11:0]})
	                          : (bit_b ? {24'b0, insn[11:8], insn[3:0]} : rb);

	always_comb begin
		logic        inv_a, inv_b, cin;
		logic [32:0] wide;
		alu_a = ra;
		alu_b = op2;
		alu_op = dp_op;
		if (state == S_MUL2) begin
			alu_a = bit_w ? ra : 32'd0;		// MLA adds Rn (bits 15:12)
			alu_b = prod[31:0];
			alu_op = OP_ADD;
		end else if (state == S_RUN && k_mem) begin
			alu_b = t_off;
			alu_op = bit_u ? OP_ADD : OP_SUB;
		end else if (state == S_RUN && k_blk) begin
			alu_b = {25'd0, n_regs, 2'b00};
			alu_op = bit_u ? OP_ADD : OP_SUB;
		end
		inv_a = alu_op == OP_RSB || alu_op == OP_RSC;
		inv_b = alu_op == OP_SUB || alu_op == OP_SBC || alu_op == OP_CMP;
		case (alu_op)
			OP_SUB, OP_RSB, OP_CMP: cin = 1'b1;
			OP_ADC, OP_SBC, OP_RSC: cin = flag_c;
			default:                cin = 1'b0;
		endcase
		wide = {1'b0, alu_a ^ {32{inv_a}}} + {1'b0, alu_b ^ {32{inv_b}}} + {32'd0, cin};
		sum = wide[31:0];
		add_c = wide[32];			// for a subtraction: NOT borrow
		add_v = (alu_a[31] ^ inv_a) == (alu_b[31] ^ inv_b) && sum[31] != (alu_a[31] ^ inv_a);
		arith = 1'b1;
		case (alu_op)
			OP_AND, OP_TST: begin alu_res = alu_a & alu_b;  arith = 1'b0; end
			OP_EOR, OP_TEQ: begin alu_res = alu_a ^ alu_b;  arith = 1'b0; end
			OP_ORR:         begin alu_res = alu_a | alu_b;  arith = 1'b0; end
			OP_MOV:         begin alu_res = alu_b;          arith = 1'b0; end
			OP_BIC:         begin alu_res = alu_a & ~alu_b; arith = 1'b0; end
			OP_MVN:         begin alu_res = ~alu_b;         arith = 1'b0; end
			default:        alu_res = sum;
		endcase
	end

	// NZCV after a flag-setting data-processing instruction.
	wire [3:0] dp_flags = {alu_res[31], alu_res == 32'd0, arith ? add_c : op2_c, arith ? add_v : nzcv[0]};

	// ---- the access in W --------------------------------------------------------------
	logic [31:0] acc_addr;
	logic  [1:0] acc_rg;
	logic  [1:0] acc_size;
	logic        acc_sign, acc_load, acc_block;
	logic        chk_v, chk_store;      // check the access made last clock
	logic [31:0] chk_pc;
	logic        late_v;                // a fault found last clock (branch target, MSR value)
	logic  [3:0] late_code;
	logic [31:0] late_pc;
	logic [31:0] wb_value;              // two-clock store: write-back in W
	logic        wb_pend;

	// The exact window checks, on the registered address.
	wire in_rom = acc_addr[31:14] == 18'd0;
	wire in_ast = acc_addr[31:24] == 8'h02 && acc_addr[23:0] < asset_size;
	wire in_ram = acc_addr[31:14] == 18'h10000;
	wire in_io  = acc_addr[31:8] == 24'hE00090;
	logic       chk_bad;
	logic [3:0] chk_code;
	always_comb begin
		chk_bad = 1'b0;
		chk_code = HALT_DATA;
		if (chk_v) begin
			if (acc_block) begin
				chk_bad = !(in_ram || (in_rom && !chk_store));
				chk_code = (in_rom || acc_addr[31:28] == 4'h0) && chk_store ? HALT_RO : HALT_BLOCK;
			end else if (chk_store) begin
				chk_bad = !(in_ram || in_io);
				chk_code = acc_addr[31:28] == 4'h0 ? HALT_RO : HALT_DATA;
			end else
				chk_bad = !(in_rom || in_ast || in_ram || in_io);
		end
	end

	// Load data: source, then ARM7TDMI lane rules. A word load rotates the
	// aligned word right by 8 x addr[1:0]. An odd LDRH returns the aligned
	// halfword rotated right by 8, an odd LDRSH the sign-extended byte (as
	// LDRSB); LDM ignores addr[1:0]. (GBATEK, "ARM CPU Memory Alignments".)
	logic [31:0] w_raw, ldata;
	always_comb begin
		logic [31:0] rot;
		case (acc_rg)
			RG_ROM:  w_raw = rom_dq;
			RG_RAM:  w_raw = ram_q;
			RG_AST:  w_raw = asset_q;
			default: w_raw = reg_rdata;
		endcase
		rot = ror32(w_raw, {acc_addr[1:0], 3'b000});
		case (acc_size)
			2'd0:    ldata = acc_sign ? {{24{rot[7]}}, rot[7:0]} : {24'd0, rot[7:0]};
			2'd1:
				if (!acc_addr[0])
					ldata = acc_sign ? {{16{rot[15]}}, rot[15:0]} : {16'd0, rot[15:0]};
				else
					ldata = acc_sign ? {{24{rot[7]}}, rot[7:0]} : {rot[31:24], 16'd0, rot[7:0]};
			default: ldata = acc_block ? w_raw : rot;
		endcase
	end

	// Store data on every lane, and the lanes written.
	function automatic logic [31:0] st_lanes(input logic [31:0] v, input logic [1:0] size);
		case (size)
			2'd0:    st_lanes = {v[7:0], v[7:0], v[7:0], v[7:0]};
			2'd1:    st_lanes = {v[15:0], v[15:0]};
			default: st_lanes = v;
		endcase
	endfunction
	function automatic logic [3:0] st_bytes(input logic [1:0] size, input logic [1:0] a);
		case ({size, a})
			4'b00_00: st_bytes = 4'b0001;
			4'b00_01: st_bytes = 4'b0010;
			4'b00_10: st_bytes = 4'b0100;
			4'b00_11: st_bytes = 4'b1000;
			4'b01_00, 4'b01_01: st_bytes = 4'b0011;
			4'b01_10, 4'b01_11: st_bytes = 4'b1100;
			default: st_bytes = 4'b1111;
		endcase
	endfunction

	// ---- control ----------------------------------------------------------------------
	wire [31:0] addr_x = bit_p ? sum : ra;		// single transfer address
	wire  [1:0] rg_x = region(addr_x);
	wire [29:0] br_target = {18'd0, pc} + 30'd2 + {{6{insn[23]}}, insn[23:0]};

	// Faults from earlier clocks win over the instruction now in execute.
	wire        halt_now = chk_bad || late_v || (state == S_RUN && !freeze && cond_ok && dec_bad);
	wire  [3:0] halt_code_now = chk_bad ? chk_code : late_v ? late_code : dec_code;
	wire [31:0] halt_pc_now = chk_bad ? chk_pc : late_v ? late_pc : {18'd0, pc, 2'b00};

	state_t      nstate;
	logic [11:0] npc;
	logic        start, done;
	logic        flags_we;
	logic  [3:0] flags_d;
	logic        acc_go;            // a single transfer or a beat accesses memory this clock
	logic        late_go;
	logic  [3:0] late_code_d;

	always_comb begin
		nstate = state;
		npc = pc;
		start = 1'b0;
		done = 1'b0;
		rf_we = 1'b0;
		rf_wa = f_rd;
		rf_wd = alu_res;
		rf_w_class = 1'b0;
		flags_we = 1'b0;
		flags_d = dp_flags;
		ram_we = 1'b0;
		ram_be = st_bytes(t_size, addr_x[1:0]);
		ram_wdata = st_lanes(rb, t_size);
		d_addr = acc_addr;
		acc_go = 1'b0;
		late_go = 1'b0;
		late_code_d = HALT_FETCH;
		reg_sel = 1'b0;

		case (state)
			S_CLEAR: begin
				rf_we = 1'b1;
				rf_wa = clr_idx;
				rf_wd = 32'd0;
				npc = 12'd0;
				if (clr_idx == 4'd14) nstate = S_RUN;
			end

			S_RUN: begin
				d_addr = addr_x;
				if (!freeze) begin
					start = 1'b1;
					if (!cond_ok) begin
						done = 1'b1;			// no effect, one clock
					end else if (k_dp) begin
						if (dp_rsh)
							nstate = S_SHR2;
						else begin
							done = 1'b1;
							rf_we = !dp_cmp;
							flags_we = bit_l;
						end
					end else if (k_mul || k_mull) begin
						nstate = S_MUL2;
					end else if (k_mrs) begin
						done = 1'b1;
						rf_we = 1'b1;
						rf_wd = {nzcv, 20'd0, 8'hD3};	// SVC mode, IRQ and FIQ masked: fixed
					end else if (k_msr) begin
						done = 1'b1;
						flags_we = insn[19];
						flags_d = msr_value[31:28];
						// The mode, T and I/F bits are fixed at 0xD3 and bits 27:24
						// read as 0, so writing anything else halts (one clock later).
						late_go = (insn[16] && msr_value[7:0] != 8'hD3) ||
							(insn[19] && msr_value[27:24] != 4'd0);
						late_code_d = HALT_UNDEF;
					end else if (k_br) begin
						done = 1'b1;
						npc = br_target[11:0];
						late_go = br_target[29:12] != 18'd0;
						if (insn[24]) begin			// BL
							rf_we = 1'b1;
							rf_wa = 4'd14;
							rf_wd = link_value;
						end
					end else if (k_bx) begin
						done = 1'b1;
						npc = rb[13:2];
						late_go = rb[0] || rb[1] || rb[31:14] != 18'd0;
						late_code_d = rb[0] ? HALT_THUMB : HALT_FETCH;
					end else if (k_mem) begin
						acc_go = 1'b1;
						if (bit_l) begin
							nstate = S_W;
							rf_we = t_wb;			// base write-back now, data in W
							rf_wa = f_rn;
						end else if (!t_regoff && rg_x == RG_RAM) begin
							done = 1'b1;			// one-clock store
							ram_we = 1'b1;
							rf_we = t_wb;
							rf_wa = f_rn;
						end else
							nstate = S_W;			// data read and write-back in W
					end else if (k_blk) begin
						nstate = S_SEQ;
					end
				end
				if (done) npc = (k_br || k_bx) && cond_ok ? npc : pc_next1[11:0];
			end

			S_W: begin
				if (!acc_load) begin
					ram_be = st_bytes(acc_size, acc_addr[1:0]);
					ram_wdata = st_lanes(rb, acc_size);
				end
				reg_sel = acc_rg == RG_IO && !chk_bad;
				if (!w_wait) begin
					done = 1'b1;
					npc = pc_next1[11:0];
					if (acc_load) begin
						if (f_rd == 4'hF) begin		// LDR pc
							npc = ldata[13:2];
							late_go = ldata[1:0] != 2'b00 || ldata[31:14] != 18'd0;
						end else begin
							rf_we = 1'b1;
							rf_wd = ldata;
							rf_w_class = 1'b1;
						end
					end else begin
						ram_we = acc_rg == RG_RAM;
						rf_we = wb_pend;
						rf_wa = f_rn;
						rf_wd = wb_value;
					end
				end
			end

			S_SHR2: begin
				done = 1'b1;
				npc = pc_next1[11:0];
				rf_we = !dp_cmp;
				flags_we = bit_l;
			end

			S_MUL2: begin
				rf_we = 1'b1;
				if (k_mull) begin
					rf_wa = f_rd;				// RdLo
					rf_wd = prod[31:0];
					nstate = S_MUL3;
				end else begin
					rf_wa = f_rn;				// MUL/MLA: Rd is bits 19:16
					done = 1'b1;
					npc = pc_next1[11:0];
				end
			end

			S_MUL3: begin
				rf_we = 1'b1;
				rf_wa = f_rn;					// RdHi
				rf_wd = prod[63:32];
				done = 1'b1;
				npc = pc_next1[11:0];
			end

			S_SEQ: begin
				d_addr = beat_addr;
				ram_be = 4'b1111;
				ram_wdata = rb;
				if (blk_rest != 16'd0) begin
					acc_go = 1'b1;
					ram_we = !bit_l && beat_addr[31:28] == 4'h4;
					if (!bit_l && blk_left == 16'd0) done = 1'b1;
				end else
					done = 1'b1;			// LDM: the last register arrives
				if (ld_pend) begin
					rf_we = 1'b1;
					rf_wa = ld_idx;
					rf_wd = ldata;
					rf_w_class = 1'b1;
				end else if (blk_first && bit_w) begin
					rf_we = 1'b1;				// the base, before any data comes back
					rf_wa = f_rn;
					rf_wd = blk_wb;
				end
				if (done) npc = pc_next1[11:0];
			end

			default: ;					// S_HALT
		endcase

		// A halt, or rst, stops everything this clock.
		if (rst || halt_now) begin
			nstate = S_HALT;
			npc = rst ? 12'd0 : pc;
			start = 1'b0;
			done = 1'b0;
			rf_we = 1'b0;
			flags_we = 1'b0;
			ram_we = 1'b0;
			reg_sel = 1'b0;
			acc_go = 1'b0;
			late_go = 1'b0;
		end else if (done)
			nstate = S_RUN;
	end

	assign rom_addr = npc;
	wire [3:0] nzcv_next = flags_we ? flags_d : nzcv;

	always_ff @(posedge clk) begin
		pc <= npc;
		if (rst) begin
			state <= S_CLEAR;
			clr_idx <= 4'd0;
			nzcv <= 4'd0;
			chk_v <= 1'b0;
			late_v <= 1'b0;
			ld_pend <= 1'b0;
			halted <= 1'b0;
			halt_code <= 4'd0;
			halt_pc <= 32'd0;
		end else begin
			state <= nstate;
			nzcv <= nzcv_next;
			if (state == S_CLEAR) clr_idx <= clr_idx + 4'd1;
			if (halt_now && state != S_HALT) begin
				halted <= 1'b1;
				halt_code <= halt_code_now;
				halt_pc <= halt_pc_now;
			end

			// The access made this clock, for W and for next clock's check.
			chk_v <= acc_go;
			if (acc_go) begin
				acc_addr <= d_addr;
				acc_rg <= region(d_addr);
				chk_pc <= {18'd0, pc, 2'b00};
				if (state == S_SEQ) begin
					acc_size <= 2'd2;
					acc_sign <= 1'b0;
					acc_load <= bit_l;
					acc_block <= 1'b1;
					chk_store <= !bit_l;
				end else begin
					acc_size <= t_size;
					acc_sign <= t_sign;
					acc_load <= bit_l;
					acc_block <= 1'b0;
					chk_store <= !bit_l;
				end
			end
			late_v <= late_go;
			if (late_go) begin
				late_code <= late_code_d;
				late_pc <= {18'd0, pc, 2'b00};
			end

			if (state == S_RUN) begin
				rs_amt <= ra[7:0];
				prod <= {32'd0, rb} * {32'd0, ra};
				wb_value <= sum;
				wb_pend <= t_wb;
				// LDM/STM: the write-back value, and where the first beat goes.
				blk_rest <= insn[15:0];
				blk_wb <= sum;
				blk_addr <= bit_u ? ra : sum;
				blk_pre4 <= bit_p == bit_u;
				blk_first <= 1'b1;
			end
			if (state == S_SEQ && !halt_now) begin
				blk_first <= 1'b0;
				ld_pend <= bit_l && blk_rest != 16'd0;
				if (blk_rest != 16'd0) begin
					ld_idx <= blk_idx;
					blk_rest <= blk_left;
					blk_addr <= blk_addr + 32'd4;
				end
			end else
				ld_pend <= 1'b0;
		end
	end

	// ---- outputs ----------------------------------------------------------------------
	assign w_addr    = acc_addr;
	assign w_size    = acc_size;
	assign w_asset   = state == S_W && acc_rg == RG_AST && acc_load && !chk_bad;
	assign reg_addr  = acc_addr[7:0];
	assign reg_write = !acc_load;
	assign reg_wdata = st_lanes(rb, acc_size);

`ifndef ALTERA_RESERVED_QIS
	assign rt_start  = start;
	assign rt_valid  = done && !halt_now;
	assign rt_pc     = {18'd0, pc, 2'b00};
	assign rt_insn   = insn;
	assign rt_nzcv   = nzcv_next;
	assign rt_e_we   = rf_we && !rf_w_class && state != S_CLEAR;
	assign rt_e_idx  = rf_wa;
	assign rt_e_data = rf_wd;
	assign rt_w_we   = rf_we && rf_w_class;
	assign rt_w_idx  = rf_wa;
	assign rt_w_data = rf_wd;
`endif
endmodule

`default_nettype wire
