//------------------------------------------------------------------------------
// ARIA (Atari RISC Interface Accelerator), the Pocket's BupChip CPU,
// configuration S1 (docs/BUPCHIP_CORE.md): the ARMv4
// ARM-state subset that CoreTone's firmware (mister/rtl/bupchip.hex) uses,
// built small for the Pocket. Written from the ARM Architecture Reference
// Manual (ARMv4) and the design document; the reference core
// (arm7tdmi_core.sv, GPL-2.0-only) is used only as a simulation oracle.
// condition_pass, shift_register and ror32 come from the MIT arm7tdmi_pkg.
//
// Rule: an encoding either does exactly what an ARM7TDMI does, or the core
// halts (halt_code, halt_pc). Nothing is silently different.
//
// MODES (default 0) picks the processor modes. 0, ARIA's: the core stays in
// SVC mode with IRQ and FIQ masked, and the control byte reads as 0xD3.
// 1, DARIA's ARM-state additions (the 2600 cartridge drivers' music helpers
// switch to FIQ mode for r8-r13): SVC, SYS and FIQ, switched by MSR, with
// FIQ's r8-r14 and SVC's r13-r14 banked in the register file, and the I and
// F bits kept and read back (the core takes no interrupts). The SPSRs are
// not there: an access to one halts in either setting.
//
// THUMB (default 0) adds the Thumb state, for DARIA (docs/DARIA_CORE.md, "The
// CPU: Thumb"); it implies MODES 1. Thumb is decoded beside ARM into the same
// controls and merged by the T bit (ctl[5]), with the register indices taken
// from both halves of rom_q and picked by pc_h. The PC becomes a halfword
// address: pc (the word, rom_addr) and pc_h (the half of rom_q in execute).
// BX switches state; MOV pc, ADD pc, POP {pc} and the BL suffix drop bit 0
// and stay in Thumb (ARMv4T). A Thumb MUL leaves C unknown (c_unk): its bit
// is kept, and anything that reads C before something defines it halts with
// code 8 (the ARM7TDMI's C there comes from its multiplier's internals).
// arm_only (the BupChip profile) keeps the core in ARM state. With THUMB 0
// every Thumb path folds away and the core is ARIA's (aria_equiv.sh in
// sim/bupchip/daria/thumb/ proves it).
//
// CODE_AW (default 12, the 16 KB ROM) is the code space in words; the
// window checks, branch targets and the end of the code space follow it.
// With THUMB 1 the code space depends on the profile instead: the BupChip's
// 16 KB ROM, or the 2600 image up to min(img_size, 128 KB) with CODE_AW 15.
//
// THUMB 1 also has DARIA's 2600 profile (prof26, static while the core
// runs) and its call port (docs/DARIA_CORE.md, "The memory system", 4 and 5):
//
//   - The 2600 memory map: the image window 0x0000_0000 to min(img_size,
//     128 KB) - 1 (fetch and data, as the ROM); the image beyond it,
//     0x0002_0000 to img_size - 1, through the asset port (data reads only:
//     a fetch there halts FETCH, an LDM BLOCK); cart RAM at 0x4000_0000, 8 KB
//     or 32 KB (ram32); MMIO 0xE000_0000-0xE01F_FFFF (reg_sel; the wrapper
//     routes it by profile). The return sentinel 0xF000_0000 is not memory.
//   - Parked (S_IDLE): after rst the clear writes every entry, then the core
//     parks instead of fetching from 0, and it parks again after each call.
//   - Launch (P1): call_go, while parked, re-enters S_CLEAR. It writes
//     entries 0-21 with clr_wd, one a clock (clr_e says which; the wrapper
//     reads its state RAM a clock ahead): r0-r12, r13 the stack, r14
//     0xF000_0000, entry 15 unused, FIQ r8-r10 the counters and r11-r13 the
//     frequencies. FIQ r14 and SVC r13-r14 keep what they had. In the last
//     clock it fetches the entry, clr_pc (bit 0 the T bit), and loads the
//     control byte SYS with that T and I = F = 0, and NZCV 0. An entry
//     outside the code space halts FETCH, with halt_pc the entry.
//   - Return (P2): a jump whose fetch address is 0xF000_0000 (BX, MOV pc,
//     ADD pc, POP {pc}, LDR pc, the BL suffix) is not a fault in the 2600
//     profile. The next clock's fetch is not the program's: the core goes to
//     S_READOUT, puts FIQ r8-r13 (entries 16-21, whatever the mode) on port B
//     for one clock each (ro_valid, ro_idx, ro_data = rb), raises returned
//     with the last, and parks.
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
// Thumb maps onto the same classes: each BL half, MOV pc and the shifts by
// immediate take 1 clock, F4's shifts by register 2, ADD pc 2, PUSH/POP and
// LDMIA/STMIA as STM/LDM (POP {pc} as an LDM), and F6 (LDR from PC) as a ROM
// load. In Thumb two instructions share a word: the ROM is read again with
// the other half selected.
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
//   0x00000000-0x00003FFF  ROM (CODE_AW 12): fetch on port A, data on port B; no stores
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
//              later) MSR writing CPSR bits 27:24, which this core does not
//              have, or a control byte other than 0xD3 (MODES 0) or with the
//              T bit or a mode other than SVC, SYS and FIQ (MODES 1).
//              Thumb: SWI, B<cond> 1110, 0xB100-0xB3FF, 0xB600-0xBBFF,
//              0xBE00-0xBFFF, 0xE800-0xEFFF, ADD/CMP/MOV with H1 = H2 = 0,
//              BX with H1 or bits 2:0 set, empty register lists
//   2  REG     r15 where the ARM7TDMI reads PC + 12 or the result is
//              UNPREDICTABLE: a data-processing destination, the operands of
//              a shift by register, a multiply, a write-back base, a store's
//              data, a register offset, LDRB/LDRH/LDRSB/LDRSH into PC, BX
//              PC, MRS/MSR; and UMULL with RdHi == RdLo
//   3  THUMB   BX to an address with bit 0 set (one clock later), with THUMB 0
//              or arm_only
//   4  FETCH   B, BL, BX or LDR pc to a target outside the code space, or not
//              word aligned in ARM state (BX to ARM with bit 1 set); Thumb's
//              B, B<cond>, BL suffix, MOV pc, ADD pc and POP {pc} likewise;
//              running on past the end of the code space, 0x3FFC (all one
//              clock later)
//   5  DATA    a load or store outside every window, or past asset_size
//   6  RO      a store to the ROM or the asset window
//   7  BLOCK   LDM/STM outside the ROM and RAM (STM to ROM is RO)
//   8  FLAGS   THUMB 1: an instruction that reads C while it is unknown after
//              a Thumb MUL: Thumb B<cond> CS/CC/HI/LS (whether or not it
//              would branch), ADC, SBC; in ARM state a CS/CC/HI/LS condition,
//              ADC, SBC, RSC, RRX, MRS
//
// Interface notes:
//   - rst is synchronous. After it falls the core spends 15 clocks writing 0
//     to r0-r14 (the reference core resets its registers to 0, and CoreTone
//     pushes registers it has never written), then fetches from 0. With
//     MODES 1 it clears all 32 register-file entries, banked ones included,
//     and starts in SVC mode with IRQ and FIQ masked (0xD3), as an ARM7TDMI
//     leaves reset.
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
//     write on port E (results, write-backs, links) or W (load data). In
//     Thumb rt_pc is the halfword's address and rt_insn {16'h0, halfword};
//     rt_t is T after the instruction and rt_cunk whether C is unknown.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_cpu
	import arm7tdmi_pkg::*;
#(
	parameter bit MODES = 1'b0,     // 0 SVC only (ARIA), 1 SVC, SYS and FIQ (DARIA)
	parameter bit THUMB = 1'b0,     // 1: Thumb as well (DARIA; implies MODES 1)
	parameter int CODE_AW = 12,     // code space in words: 12 = the 16 KB ROM (ARIA), 15 = 128 KB
	parameter int WIN_KB = 128      // THUMB 1: the image window; smaller only for tests, where the
	                                // image beyond it (code aside) goes through the asset cache
)
(
	input  wire         clk,            // clk_arm
	input  wire         rst,            // held: reset, then clear r0-r14
	input  wire         freeze,         // do not start an instruction this clock
	input  wire         w_wait,         // the asset load in W has no data yet
	input  wire         arm_only,       // THUMB 1: stay in ARM state, BX to odd halts (BupChip)

	// DARIA (THUMB 1): the 2600 profile and the call port (docs/DARIA_CORE.md,
	// "The memory system", 4 and 5). Unused with THUMB 0.
	input  wire         prof26,         // the 2600 profile; static while the core runs
	input  wire  [19:0] img_size,       // the image's bytes (2600 profile)
	input  wire         ram32,          // 32 KB of cart RAM (CDFJ+), else 8 KB
	input  wire         call_go,        // one clock, while parked: launch a call
	input  wire  [31:0] clr_wd,         // a launch's data for entry clr_e
	input  wire  [31:0] clr_pc,         // a launch's entry address; bit 0 is the T bit
	output wire   [4:0] clr_e,          // the register-file entry the clear writes this clock
	output wire         parked,         // idle between calls
	output wire         returned,       // one clock: the readout's last
	output wire         ro_valid,       // the readout: FIQ r8-r13, one a clock
	output wire   [2:0] ro_idx,         // 0 = r8 ... 5 = r13
	output wire  [31:0] ro_data,

	// Fetch: ROM port A. The ROM registers rom_addr; rom_q is the word at
	// the address presented one clock earlier.
	output logic [CODE_AW-1:0] rom_addr,
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
	output logic  [4:0] rt_mode,
	output logic        rt_t,           // the T bit after the instruction
	output logic        rt_cunk,        // C is unknown after it (a Thumb MUL)
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
	localparam logic [3:0] HALT_FLAGS = 4'd8;

	// Data-processing opcodes (ARM ARM A3.4), as used by the ALU below.
	localparam logic [3:0] OP_AND = 4'h0, OP_EOR = 4'h1, OP_SUB = 4'h2, OP_RSB = 4'h3;
	localparam logic [3:0] OP_ADD = 4'h4, OP_ADC = 4'h5, OP_SBC = 4'h6, OP_RSC = 4'h7;
	localparam logic [3:0] OP_TST = 4'h8, OP_TEQ = 4'h9, OP_CMP = 4'hA, OP_CMN = 4'hB;
	localparam logic [3:0] OP_ORR = 4'hC, OP_MOV = 4'hD, OP_BIC = 4'hE, OP_MVN = 4'hF;

	// Memory regions, from address bits [31:28] and [25].
	localparam logic [1:0] RG_ROM = 2'd0, RG_RAM = 2'd1, RG_AST = 2'd2, RG_IO = 2'd3;

	// In the 2600 profile (p) the "assets" are the image beyond the window,
	// 0x0002_0000 up (WIN_KB): the asset cache serves them.
	localparam logic [19:0] WIN_B = 20'(WIN_KB * 1024);
	function automatic logic [1:0] region(input logic [31:0] a, input logic p);
		case (a[31:28])
			4'h4:    region = RG_RAM;
			4'hE:    region = RG_IO;
			default: region = (p ? {1'b0, a[18:0]} >= WIN_B : a[25]) ? RG_AST : RG_ROM;	// 0x0: ROM or assets; others fail the check
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
	localparam bit MD  = MODES || THUMB;	// the processor modes (THUMB implies them)
	localparam bit DC  = THUMB;		// DARIA: the 2600 profile and the call port
	localparam int RFA = MD ? 5 : 4;	// register-file address bits
	localparam int SW  = DC ? 4 : 3;	// state bits: S_IDLE and S_READOUT need a fourth

	typedef logic [SW-1:0] state_t;
	localparam state_t S_CLEAR   = SW'(0);	// writing 0 to r0-r14 after rst; a call's launch
	localparam state_t S_RUN     = SW'(1);	// the first (often the only) clock of an instruction
	localparam state_t S_W       = SW'(2);	// a load's data, a two-clock store, an MMIO access
	localparam state_t S_SHR2    = SW'(3);	// shift by register: the shift and the ALU
	localparam state_t S_MUL2    = SW'(4);	// MUL/MLA result, UMULL low word
	localparam state_t S_MUL3    = SW'(5);	// UMULL high word
	localparam state_t S_SEQ     = SW'(6);	// LDM/STM beats
	localparam state_t S_HALT    = SW'(7);
	// DC only (with SW 3 these alias S_CLEAR and S_RUN: every use is gated by DC).
	localparam state_t S_IDLE    = SW'(8);	// parked between calls
	localparam state_t S_READOUT = SW'(9);	// a call's return: FIQ r8-r13 out on port B

	state_t      state;
	logic [CODE_AW-1:0] pc;         // word address of the instruction in rom_q
	logic  [3:0] nzcv;
	logic [RFA-1:0] clr_idx;
	wire         p26 = DC && prof26;	// the 2600 profile
	logic        launch;            // DC: S_CLEAR is a call's launch, not the reset clear
	logic  [2:0] ro_cnt;            // DC: the readout's register, 0 = r8
	logic        ret_v;             // DC: last clock jumped to the return sentinel

	// The CPSR's control byte (I, F, T, mode). With MODES 0 it is 0xD3 and
	// these registers fold to constants. m_fiq and m_svc decode the mode.
	logic  [7:0] ctl;
	logic        m_fiq, m_svc;
	wire         flag_c = nzcv[1];

	// THUMB 1: the T bit (ctl[5]) and the halfword of the instruction in
	// execute (pc_h, registered with pc, so it selects the half of rom_q).
	// Both are 0 with THUMB 0, and every Thumb path folds away.
	logic        pc_h;
	wire         tm = THUMB && ctl[5];
	wire         ph = THUMB && pc_h;

	wire  [31:0] insn = rom_q;
	wire  [15:0] hw = ph ? rom_q[31:16] : rom_q[15:0];
	wire  [CODE_AW:0] pc_next1 = {1'b0, pc} + (CODE_AW+1)'(1);
	wire  [CODE_AW:0] pc_next2 = {1'b0, pc} + (CODE_AW+1)'(2);
	// The next instruction in sequence: the next word in ARM state, the next
	// halfword in Thumb (the same word again after the low half).
	wire  [CODE_AW-1:0] seq_w = (tm && !ph) ? pc : pc_next1[CODE_AW-1:0];
	wire         seq_h = tm && !ph;
	// The code space. ARIA's is CODE_AW words. DARIA's depends on the profile
	// (open item 18): the BupChip's 16 KB ROM, or the 2600 image up to
	// min(img_size, 128 KB). a is a fetch's byte address.
	function automatic logic code_ok(input logic [31:0] a, input logic p, input logic [19:0] isz);
		if (!DC) code_ok = a[31:CODE_AW+2] == '0;
		else if (p) code_ok = a[31:19] == '0 && {1'b0, a[18:0]} < WIN_B && {1'b0, a[18:0]} < isz;
		else code_ok = a[31:14] == '0;
	endfunction
	// The next instruction in sequence runs off the code space.
	wire  [31:0] seq_byte = (tm && !ph) ? 32'({pc, 2'b10}) : 32'({pc_next1, 2'b00});
	wire         seq_ovf = !DC ? (tm ? (ph && pc_next1[CODE_AW]) : pc_next1[CODE_AW])
	                           : !code_ok(seq_byte, p26, img_size);
	logic        pcrel;             // Thumb F6 and F12: r15 reads word-aligned
	// r15 reads as the instruction's address + 8 (ARM) or + 4 (Thumb).
	wire  [31:0] r15_value = tm ? 32'({pc_next1, ph && !pcrel, 1'b0}) : 32'({pc_next2, 2'b00});
	// BL's link: address + 4 (ARM); the Thumb BL suffix's: (address + 2) | 1.
	wire  [31:0] link_value = tm ? 32'({seq_w, seq_h, 1'b1}) : 32'({pc_next1, 2'b00});
	wire  [31:0] pc_byte = 32'({pc, ph, 1'b0});		// the instruction's address

	// ---- ARM decode -------------------------------------------------------------
	wire [3:0] a_rn = insn[19:16];
	wire [3:0] a_rd = insn[15:12];
	wire [3:0] a_rs = insn[11:8];
	wire [3:0] a_rm = insn[3:0];
	wire       a_p = insn[24], a_u = insn[23], a_b = insn[22], a_w = insn[21], a_l = insn[20];

	wire g000 = insn[27:25] == 3'b000;
	wire g001 = insn[27:25] == 3'b001;
	wire ext  = g000 && insn[7] && insn[4];			// multiply, swap and halfword space
	wire psr_space = insn[24:23] == 2'b10 && !a_l;		// TST..CMN opcodes without S

	wire a_mul  = ext && insn[6:5] == 2'b00 && insn[27:22] == 6'b000000;	// MUL, MLA
	wire a_mull = ext && insn[6:5] == 2'b00 && insn[27:23] == 5'b00001;	// long multiplies
	wire a_xh   = ext && insn[6:5] != 2'b00;		// LDRH, STRH, LDRSB, LDRSH
	wire a_misc = g000 && !ext && psr_space;		// MRS, MSR register, BX
	wire a_dp   = (g000 && !ext && !psr_space) || (g001 && !psr_space);
	wire a_sdt  = insn[27:26] == 2'b01 && !(insn[25] && insn[4]);	// LDR, STR, LDRB, STRB
	wire a_blk  = insn[27:25] == 3'b100;
	wire a_br   = insn[27:25] == 3'b101;
	wire a_bx   = a_misc && insn[27:4] == 24'h12FFF1;
	wire a_mrs  = a_misc && !a_w && a_rn == 4'hF && insn[11:0] == 12'h000;
	wire a_msr  = (a_misc && a_w && a_rd == 4'hF && insn[11:4] == 8'h00) ||
	              (g001 && psr_space && a_w && a_rd == 4'hF);
	wire a_mem  = a_sdt || a_xh;

	// Data processing.
	wire [3:0] a_op  = insn[24:21];
	wire       a_mov = a_op == OP_MOV || a_op == OP_MVN;	// no Rn
	wire       a_rsh = a_dp && !insn[25] && insn[4];	// shift amount from Rs

	// Single transfers.
	wire       a_wb     = !a_p || a_w;			// post-index always writes back
	wire       a_regoff = (a_sdt && insn[25]) || (a_xh && !a_b);
	wire [1:0] a_size   = a_sdt ? (a_b ? 2'd0 : 2'd2) : (insn[5] ? 2'd1 : 2'd0);
	wire       a_sign   = a_xh && insn[6];

	// MSR: the operand, its fields (c 16, x 17, s 18, f 19).
	logic [31:0] msr_value;

	// What halts as soon as it reaches execute (with its condition passing).
	logic       a_bad;
	logic [3:0] a_code;
	always_comb begin
		a_bad = 1'b1;
		a_code = HALT_UNDEF;
		if (a_dp) begin
			a_code = HALT_REG;
			// Rd = PC (for TST..CMN the 26-bit "P" forms), and the operands
			// of a shift by register, which the ARM7TDMI reads as PC + 12.
			a_bad = a_rd == 4'hF ||
				(a_rsh && (a_rm == 4'hF || a_rs == 4'hF || (!a_mov && a_rn == 4'hF)));
		end else if (a_mul) begin
			a_bad = a_l;					// MULS, MLAS
			if (!a_l) begin
				a_code = HALT_REG;
				a_bad = a_rn == 4'hF || a_rs == 4'hF || a_rm == 4'hF || (a_w && a_rd == 4'hF);
			end
		end else if (a_mull) begin
			a_bad = insn[22:20] != 3'b000;		// only UMULL, without S
			if (insn[22:20] == 3'b000) begin
				a_code = HALT_REG;
				a_bad = a_rn == 4'hF || a_rd == 4'hF || a_rs == 4'hF || a_rm == 4'hF || a_rn == a_rd;
			end
		end else if (a_xh) begin
			a_bad = !a_l && insn[6];			// LDRD/STRD space
			if (!a_bad) begin
				a_code = HALT_REG;
				a_bad = a_rd == 4'hF || (a_wb && a_rn == 4'hF) || (!a_b && a_rm == 4'hF);
			end
		end else if (a_sdt) begin
			a_code = HALT_REG;
			a_bad = (a_wb && a_rn == 4'hF) || (insn[25] && a_rm == 4'hF) ||
				(a_rd == 4'hF && (!a_l || a_b));
		end else if (a_blk) begin
			a_bad = a_b || insn[15] || insn[15:0] == 16'h0000;	// S, PC in list, empty
			if (!a_bad) begin
				a_code = HALT_REG;
				a_bad = a_rn == 4'hF;
			end
		end else if (a_br) begin
			a_bad = 1'b0;
		end else if (a_bx) begin
			a_code = HALT_REG;
			a_bad = a_rm == 4'hF;
		end else if (a_mrs) begin
			a_bad = a_b;					// SPSR
			if (!a_b) begin
				a_code = HALT_REG;
				a_bad = a_rd == 4'hF;
			end
		end else if (a_msr) begin
			a_bad = a_b || insn[18:17] != 2'b00;	// SPSR, the x and s fields
			if (!a_bad && !insn[25]) begin
				a_code = HALT_REG;
				a_bad = a_rm == 4'hF;
			end
		end
	end

	// ---- Thumb decode (THUMB 1) ----------------------------------------------------
	// Thumb is decoded beside ARM into the same controls, merged by T below
	// (docs/DARIA_CORE.md, "The CPU: Thumb"). Each format maps onto an ARM
	// class: F1-F5, F12, F13 and the BL prefix are data processing, F6-F11
	// single transfers, F14-F15 LDM/STM, F16 and F18 branches; the BL
	// suffix, MOV pc, ADD pc and BX are their own.
	wire tf1  = hw[15:13] == 3'b000 && hw[12:11] != 2'b11;	// shift by immediate
	wire tf2  = hw[15:11] == 5'b00011;			// ADD/SUB register or imm3
	wire tf3  = hw[15:13] == 3'b001;			// MOV/CMP/ADD/SUB imm8
	wire tf4  = hw[15:10] == 6'b010000;			// ALU
	wire tf5  = hw[15:10] == 6'b010001;			// hi-register ops, BX
	wire tf6  = hw[15:11] == 5'b01001;			// LDR [PC, #]
	wire tf78 = hw[15:12] == 4'b0101;			// [Rb, Ro]: F7 (hw[9] = 0), F8
	wire tf9  = hw[15:13] == 3'b011;			// LDR/STR(B) [Rb, #]
	wire tf10 = hw[15:12] == 4'b1000;			// LDRH/STRH [Rb, #]
	wire tf11 = hw[15:12] == 4'b1001;			// LDR/STR [SP, #]
	wire tf12 = hw[15:12] == 4'b1010;			// ADD Rd, PC or SP, #
	wire tf13 = hw[15:8] == 8'b1011_0000;			// ADD/SUB SP, #
	wire tf14 = hw[15:12] == 4'b1011 && hw[10:9] == 2'b10;	// PUSH, POP
	wire tf15 = hw[15:12] == 4'b1100;			// STMIA/LDMIA
	wire tf16 = hw[15:12] == 4'b1101;			// B<cond>; cond 1110 and SWI halt
	wire tf18 = hw[15:11] == 5'b11100;			// B
	wire tbl1 = hw[15:11] == 5'b11110;			// BL prefix
	wire tbl2 = hw[15:11] == 5'b11111;			// BL suffix
	wire [3:0] t4op = hw[9:6];
	wire t4sh  = tf4 && (t4op == 4'h2 || t4op == 4'h3 || t4op == 4'h4 || t4op == 4'h7);
	wire t4mul = tf4 && t4op == 4'hD;
	wire [1:0] t5op = hw[9:8];				// ADD, CMP, MOV, BX
	wire [3:0] t5d = {hw[7], hw[2:0]};
	wire [3:0] t5m = {hw[6], hw[5:3]};
	wire tbcc  = tf16 && hw[11:9] != 3'b111;
	wire tmovpc = tf5 && t5op == 2'b10 && t5d == 4'hF;
	wire taddpc = tf5 && t5op == 2'b00 && t5d == 4'hF;

	wire th_dp  = tf1 || tf2 || tf3 || (tf4 && !t4mul) || (tf5 && t5op != 2'b11 && t5d != 4'hF) ||
	              (tf5 && t5op == 2'b01) || tf12 || tf13 || tbl1;
	wire th_mem = tf6 || tf78 || tf9 || tf10 || tf11;
	wire th_blk = tf14 || tf15;
	wire th_s   = tf1 || tf2 || tf3 || tf4 || (tf5 && t5op == 2'b01);
	wire th_l   = tf6 || (tf78 && hw[9] ? hw[11] || hw[10] : hw[11]);
	wire th_imm = (tf2 && hw[10]) || tf3 || tf12 || tf13 || tbl1 || tbl2;

	logic  [3:0] th_op;
	logic [31:0] th_immv;
	always_comb begin
		th_op = OP_ADD;
		if (tf1) th_op = OP_MOV;
		else if (tf2) th_op = hw[9] ? OP_SUB : OP_ADD;
		else if (tf3)
			case (hw[12:11])
				2'd0: th_op = OP_MOV;
				2'd1: th_op = OP_CMP;
				2'd2: th_op = OP_ADD;
				default: th_op = OP_SUB;
			endcase
		else if (tf4)
			case (t4op)
				4'h0: th_op = OP_AND;
				4'h1: th_op = OP_EOR;
				4'h5: th_op = OP_ADC;
				4'h6: th_op = OP_SBC;
				4'h8: th_op = OP_TST;
				4'h9: th_op = OP_SUB;		// NEG: 0 - Rs (zero_a)
				4'hA: th_op = OP_CMP;
				4'hB: th_op = OP_CMN;
				4'hC: th_op = OP_ORR;
				4'hE: th_op = OP_BIC;
				4'hF: th_op = OP_MVN;
				default: th_op = OP_MOV;	// the shifts by register; MUL
			endcase
		else if (tf5) th_op = t5op == 2'b01 ? OP_CMP : t5op == 2'b10 ? OP_MOV : OP_ADD;
		else if (tf13) th_op = hw[7] ? OP_SUB : OP_ADD;

		th_immv = {20'd0, hw[10:0], 1'b0};					// BL suffix
		if (tf2) th_immv = {29'd0, hw[8:6]};
		else if (tf3) th_immv = {24'd0, hw[7:0]};
		else if (tf12) th_immv = {22'd0, hw[7:0], 2'b00};
		else if (tf13) th_immv = {23'd0, hw[6:0], 2'b00};
		else if (tbl1) th_immv = {{9{hw[10]}}, hw[10:0], 12'd0};
	end

	// The shift of operand 2: F1's, F4's shifts by register (type only), else LSL #0.
	wire [1:0] th_shtype = tf1 ? hw[12:11] :
	                       !t4sh ? 2'b00 : t4op == 4'h3 ? 2'b01 : t4op == 4'h4 ? 2'b10 : t4op == 4'h7 ? 2'b11 : 2'b00;
	wire [4:0] th_shimm = tf1 ? hw[10:6] : 5'd0;

	// Single transfers: always pre-indexed, added, no write-back.
	wire [1:0] th_size = tf6 || tf11 ? 2'd2 :
	                     tf78 ? (hw[9] ? (hw[10] && !hw[11] ? 2'd0 : 2'd1) : (hw[10] ? 2'd0 : 2'd2)) :
	                     tf9 ? (hw[12] ? 2'd0 : 2'd2) : 2'd1;
	wire       th_sign = tf78 && hw[9] && hw[10];
	wire [31:0] th_offv = tf9 ? (hw[12] ? {27'd0, hw[10:6]} : {25'd0, hw[10:6], 2'b00}) :
	                      tf10 ? {26'd0, hw[10:6], 1'b0} : {22'd0, hw[7:0], 2'b00};	// F6, F11

	// Register roles for the clocks after the first and for the writes: Rd
	// the result or the transfer's data, Rn the base of an LDM/STM or a
	// MUL's destination, Rm the value a shift by register shifts.
	wire [3:0] th_rd = (tf3 || tf6 || tf11 || tf12) ? {1'b0, hw[10:8]} : tf5 ? t5d :
	                   tf13 ? 4'd13 : tbl1 ? 4'd14 : {1'b0, hw[2:0]};
	wire [3:0] th_rn = tf14 ? 4'd13 : tf15 ? {1'b0, hw[10:8]} : {1'b0, hw[2:0]};

	// Encodings that halt (UNDEF): SWI and B<cond> 1110, the rest of 1011
	// (v5 and v6 space), the BLX suffix space, the hi-register forms with
	// H1 = H2 = 0, BX with H1 or bits 2:0 set, and empty register lists.
	wire th_bad = (tf16 && hw[11:9] == 3'b111) || (hw[15:12] == 4'b1011 && !tf13 && !tf14) ||
	              hw[15:11] == 5'b11101 || (tf5 && t5op != 2'b11 && !hw[7] && !hw[6]) ||
	              (tf5 && t5op == 2'b11 && (hw[7] || hw[2:0] != 3'b000)) ||
	              (tf14 && !hw[8] && hw[7:0] == 8'h00) || (tf15 && hw[7:0] == 8'h00);

	// The first clock's read ports, decoded from each half of rom_q and
	// picked by pc_h at the end, so the index path is no deeper than ARM's.
	function automatic logic [3:0] t_port_a(input logic [15:0] h);
		casez (h[15:11])
			5'b00011, 5'b0101?, 5'b011??, 5'b1000?: t_port_a = {1'b0, h[5:3]};	// F2, F7-F10
			5'b001??, 5'b1100?:                      t_port_a = {1'b0, h[10:8]};	// F3, F15
			5'b01000: t_port_a = h[10] ? {h[7], h[2:0]} : {1'b0, h[2:0]};		// F5, F4
			5'b01001, 5'b11110:                      t_port_a = 4'd15;		// F6, BL prefix
			5'b1010?: t_port_a = h[11] ? 4'd13 : 4'd15;				// F12
			5'b11111:                                t_port_a = 4'd14;		// BL suffix
			default:                                 t_port_a = 4'd13;		// F11, F13, F14
		endcase
	endfunction
	function automatic logic [3:0] t_port_b(input logic [15:0] h);
		casez (h[15:11])
			5'b00011, 5'b0101?: t_port_b = {1'b0, h[8:6]};				// F2, F7, F8
			5'b011??, 5'b1000?: t_port_b = {1'b0, h[2:0]};				// F9, F10 store data
			5'b1001?:           t_port_b = {1'b0, h[10:8]};				// F11 store data
			5'b01000:           t_port_b = h[10] ? {h[6], h[5:3]} : {1'b0, h[5:3]};	// F5, F4
			default:            t_port_b = {1'b0, h[5:3]};				// F1
		endcase
	endfunction
	wire [3:0] ta_lo = t_port_a(rom_q[15:0]), ta_hi = t_port_a(rom_q[31:16]);
	wire [3:0] tb_lo = t_port_b(rom_q[15:0]), tb_hi = t_port_b(rom_q[31:16]);

	// ---- the merged controls --------------------------------------------------------
	// With THUMB 0 (or in ARM state) these are the ARM decode's.
	wire [3:0] f_rn  = tm ? th_rn : a_rn;
	wire [3:0] f_rd  = tm ? th_rd : a_rd;
	wire [3:0] f_rm  = tm ? {1'b0, hw[2:0]} : a_rm;
	// THUMB 1: the role fields registered at the end of execute, for the
	// clocks after it (W, the second clock of a shift, MUL, LDM/STM). rom_q
	// does not change meanwhile, so they equal f_*; registered, they keep
	// the Thumb decode off the read-index and write-index paths of those
	// clocks. With THUMB 0, l_* are f_*.
	logic [3:0] x_rd, x_rn, x_rm;
	wire  [3:0] l_rd = THUMB ? x_rd : f_rd;
	wire  [3:0] l_rn = THUMB ? x_rn : f_rn;
	wire  [3:0] l_rm = THUMB ? x_rm : f_rm;
	wire       bit_p = tm ? th_mem || (tf14 && !hw[11]) : a_p;	// PUSH is STMDB
	wire       bit_u = tm ? !(tf14 && !hw[11]) : a_u;
	wire       bit_w = tm ? th_blk : a_w;
	wire       bit_l = tm ? (th_mem || th_blk ? th_l : th_s) : a_l;	// load, or S
	wire [3:0] cond  = tm ? (tbcc ? hw[11:8] : 4'hE) : insn[31:28];
	wire       cond_ok = condition_pass(cond, nzcv);

	wire k_dp    = tm ? th_dp : a_dp;
	wire k_mul   = tm ? t4mul : a_mul;
	wire k_mull  = !tm && a_mull;
	wire k_mrs   = !tm && a_mrs;
	wire k_msr   = !tm && a_msr;
	wire k_br    = tm ? tbcc || tf18 : a_br;
	wire k_bx    = tm ? tf5 && t5op == 2'b11 : a_bx;
	wire k_mem   = tm ? th_mem : a_mem;
	wire k_blk   = tm ? th_blk : a_blk;
	wire k_bl2   = tm && tbl2;		// BL suffix
	wire k_movpc = tm && tmovpc;		// MOV pc, Rm
	wire k_addpc = tm && taddpc;		// ADD pc, Rm (two clocks)
	wire br_link = !tm && insn[24];		// ARM BL

	wire [3:0] dp_op  = tm ? th_op : a_op;
	wire       dp_cmp = dp_op[3:2] == 2'b10;		// TST TEQ CMP CMN: no result
	wire       dp_rsh = tm ? t4sh : a_rsh;		// shift by register: two clocks
	wire       op_imm = tm ? th_imm : insn[25];	// operand 2 is an immediate
	wire       zero_a = tm && tf4 && t4op == 4'h9;	// NEG
	wire [15:0] list  = tm ? (tf14 ? {hw[11] && hw[8], !hw[11] && hw[8], 6'd0, hw[7:0]} : {8'd0, hw[7:0]})
	                       : insn[15:0];		// PUSH's LR is bit 14, POP's PC bit 15
	always_comb pcrel = tm && (tf6 || (tf12 && !hw[11]));

	wire       t_wb     = tm ? 1'b0 : a_wb;
	wire       t_regoff = tm ? tf78 : a_regoff;
	wire [1:0] t_size   = tm ? th_size : a_size;
	wire       t_sign   = tm ? th_sign : a_sign;

	wire       dec_bad  = tm ? th_bad : a_bad;
	wire [3:0] dec_code = tm ? HALT_UNDEF : a_code;

	// What reads C (halt 8 while c_unk is set): a condition on C, ADC, SBC,
	// RSC, RRX (as an operand or an offset) and MRS.
	wire cond_rd_c = cond == 4'h2 || cond == 4'h3 || cond == 4'h8 || cond == 4'h9;
	wire a_rrx = insn[6:5] == 2'b11 && insn[11:7] == 5'd0;
	wire op_rd_c = tm ? tf4 && (t4op == 4'h5 || t4op == 4'h6) :
	               (a_dp && (a_op == OP_ADC || a_op == OP_SBC || a_op == OP_RSC ||
	                         (!insn[25] && !a_rsh && a_rrx))) ||
	               (a_sdt && insn[25] && a_rrx) || a_mrs;

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

	// ---- register file ----------------------------------------------------------
	// r0-r14; r15 reads as the instruction's address + 8. Last clock's write is
	// held and bypassed, so an MLAB is only read for data at least two clocks old.
	// With MODES 1 the file has 32 entries: 0-14 the user and system registers,
	// 16-22 FIQ's r8-r14 and 29-30 SVC's r13-r14 (phys below), and the bypass
	// compares entries. (A mode changes only with an MSR, which writes no
	// register, so the bypass never holds a write from another mode anyway.)
	//
	// The behavioural array shows a write on the next clock, so simulation
	// alone would never need the bypass. Built with BUP_SIM_LATE_RF (simulation
	// only), an entry holds garbage (the inverted data) for the clock after
	// its write and the data from the clock after that: any read of the array
	// that the bypass does not cover then goes wrong.
	(* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf [0:(1 << RFA) - 1];
	logic        rf_we;
	logic  [3:0] rf_wa;
	logic [31:0] rf_wd;
	logic        rf_w_class;	// for the retire port: 1 = load data (port W)
	logic        byp_we;
	logic [RFA-1:0] byp_idx;
	logic [31:0] byp_data;
	logic  [3:0] ia, ib;

	// The entry that holds register r in the current mode.
	function automatic logic [RFA-1:0] phys(input logic [3:0] r, input logic fiq, input logic svc);
		logic [4:0] e;
		e = {1'b0, r};
		if (MD && fiq && r[3] && r != 4'hF) e = {2'b10, r[2:0]};
		else if (MD && svc && (r == 4'd13 || r == 4'd14)) e = {1'b1, r};
		phys = e[RFA-1:0];
	endfunction

	// THUMB 1 remaps each candidate before the select (docs/DARIA_CORE.md,
	// "Where the expander sits"): the Thumb candidates come from both halves
	// of rom_q, picked by pc_h at the end, so the index path stays as deep
	// as ARIA's. ARIA keeps its select-then-remap form.
	logic [RFA-1:0] pa_x, pb_x;
	always_comb begin
		pa_x = phys(x_rn, m_fiq, m_svc);
		pb_x = phys(x_rm, m_fiq, m_svc);
		case (state)
			S_RUN: begin
				if (tm) pa_x = ph ? phys(ta_hi, m_fiq, m_svc) : phys(ta_lo, m_fiq, m_svc);
				else if (a_rsh || a_mul || a_mull) pa_x = phys(a_rs, m_fiq, m_svc);
				else pa_x = phys(a_rn, m_fiq, m_svc);
				if (tm) pb_x = ph ? phys(tb_hi, m_fiq, m_svc) : phys(tb_lo, m_fiq, m_svc);
				else if (a_mem && !a_l && !a_regoff) pb_x = phys(a_rd, m_fiq, m_svc);
				else pb_x = phys(a_rm, m_fiq, m_svc);
			end
			S_W:    pb_x = phys(x_rd, m_fiq, m_svc);
			S_MUL2: pa_x = phys(x_rd, m_fiq, m_svc);
			S_SEQ:  pb_x = phys(blk_idx, m_fiq, m_svc);
			default: ;
		endcase
		// The readout: FIQ r8-r13 are entries 16-21, whatever the mode.
		if (DC && state == S_READOUT) pb_x = RFA'(5'd16 + {2'd0, ro_cnt});
	end
	wire [RFA-1:0] pa = THUMB ? pa_x : phys(ia, m_fiq, m_svc);
	wire [RFA-1:0] pb = THUMB ? pb_x : phys(ib, m_fiq, m_svc);
	// The clear after rst writes every entry by number.
	wire [RFA-1:0] rf_pa = MD ? (state == S_CLEAR ? clr_idx : phys(rf_wa, m_fiq, m_svc)) : rf_wa;

	always_ff @(posedge clk) begin
`ifdef BUP_SIM_LATE_RF
		if (byp_we) rf[byp_idx] <= byp_data;
		if (rf_we) rf[rf_pa] <= ~rf_wd;		// wins when both hit one entry
`else
		if (rf_we) rf[rf_pa] <= rf_wd;
`endif
		byp_we <= rf_we;
		byp_idx <= rf_pa;
		byp_data <= rf_wd;
	end

	function automatic logic [31:0] read_reg(input logic [3:0] idx, input logic [31:0] arr,
		input logic hit, input logic [31:0] held, input logic [31:0] r15);
		if (idx == 4'hF) read_reg = r15;
		else if (hit) read_reg = held;
		else read_reg = arr;
	endfunction

	wire [31:0] ra = read_reg(ia, rf[pa], byp_we && byp_idx == pa, byp_data, r15_value);
	wire [31:0] rb = read_reg(ib, rf[pb], byp_we && byp_idx == pb, byp_data, r15_value);

	// Read port selection.
	always_comb begin
		ia = l_rn;
		ib = l_rm;
		case (state)
			S_RUN:
				if (tm) begin
					ia = ph ? ta_hi : ta_lo;
					ib = ph ? tb_hi : tb_lo;
				end else begin
					ia = a_rn;
					ib = a_rm;
					if (a_rsh || a_mul || a_mull) ia = a_rs;
					if (a_mem && !a_l && !a_regoff) ib = a_rd;	// one-clock store data
				end
			S_W:    ib = l_rd;					// two-clock store data
			S_MUL2: ia = l_rd;					// MLA accumulator, bits 15:12
			S_SEQ:  ib = blk_idx;				// STM data
			default: ;
		endcase
		if (DC && state == S_READOUT) ib = 4'd8 + {1'b0, ro_cnt};	// never r15
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
	wire   [1:0] sh_type = tm ? th_shtype : insn[6:5];
	wire   [4:0] sh_imm  = tm ? th_shimm : insn[11:7];
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
		if (op_imm && !sh_reg) begin
			op2 = tm ? th_immv : imm_rot;
			op2_c = tm || insn[11:8] == 4'd0 ? flag_c : imm_rot[31];
		end else begin
			op2 = sh_value;
			op2_c = sh_carry;
		end
	end

	always_comb msr_value = insn[25] ? imm_rot : rb;

	// A control byte MSR may write: 0xD3 (MODES 0); with MODES 1 any I and F,
	// T clear, and the mode SVC, SYS or FIQ.
	function automatic logic ctl_ok(input logic [7:0] v);
		if (!MD) ctl_ok = v == 8'hD3;
		else ctl_ok = !v[5] && (v[4:0] == 5'h13 || v[4:0] == 5'h1F || v[4:0] == 5'h11);
	endfunction

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
	assign n_regs = count_regs(list);

	wire [31:0] a_off = a_sdt ? (insn[25] ? sh_value : {20'b0, insn[11:0]})
	                          : (a_b ? {24'b0, insn[11:8], insn[3:0]} : rb);
	wire [31:0] t_off = tm ? (tf78 ? rb : th_offv) : a_off;

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
		end else if (state == S_RUN && zero_a)
			alu_a = 32'd0;				// Thumb NEG: 0 - Rs
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

	// The exact window checks, on the registered address. With THUMB 1 the
	// BupChip's ROM stays 16 KB whatever CODE_AW is. DARIA's 2600 profile has
	// its own (docs/DARIA_CORE.md, "The memory system", 4): the window up to
	// the image's size, the image beyond it through the asset cache, 8 or 32 KB
	// of cart RAM, and upstream's MMIO window 0xE000_0000-0xE01F_FFFF.
	wire in_rom_b = DC ? acc_addr[31:14] == '0 : acc_addr[31:CODE_AW+2] == '0;
	wire in_ast_b = acc_addr[31:24] == 8'h02 && acc_addr[23:0] < asset_size;
	wire in_ram_b = acc_addr[31:14] == 18'h10000;
	wire in_io_b  = acc_addr[31:8] == 24'hE00090;
	wire in_rom_g = acc_addr[31:19] == '0 && {1'b0, acc_addr[18:0]} < WIN_B && {1'b0, acc_addr[18:0]} < img_size;
	wire in_ast_g = acc_addr[31:19] == '0 && {1'b0, acc_addr[18:0]} >= WIN_B && {1'b0, acc_addr[18:0]} < img_size;
	wire in_ram_g = acc_addr[31:15] == 17'h08000 && (ram32 || acc_addr[14:13] == 2'b00);
	wire in_io_g  = acc_addr[31:21] == 11'h700;
	wire in_rom = p26 ? in_rom_g : in_rom_b;
	wire in_ast = p26 ? in_ast_g : in_ast_b;
	wire in_ram = p26 ? in_ram_g : in_ram_b;
	wire in_io  = p26 ? in_io_g : in_io_b;
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
	// The one-clock store's region, from Rn and the immediate offset on an
	// adder of its own. Where the store may take one clock (an immediate
	// offset) it equals region(addr_x); it keeps the shifter and the operand
	// muxes off the path to done (BUPCHIP_CORE, risk 2).
	wire [31:0] st_off = tm ? th_offv : a_sdt ? {20'b0, insn[11:0]} : {24'b0, insn[11:8], insn[3:0]};
	wire [31:0] st_addr = bit_p ? ra + (st_off ^ {32{!bit_u}}) + 32'(!bit_u) : ra;
	wire        st_ram = region(st_addr, p26) == RG_RAM;
	// The BL suffix's target, LR + offset, likewise on an adder of its own: the
	// ALU's sum for the suffix, without the shifter and the operand muxes on
	// the path to rom_addr.
	wire [31:0] bl_sum = ra + {20'd0, hw[10:0], 1'b0};
	wire [29:0] br_target = 30'(pc) + 30'd2 + {{6{insn[23]}}, insn[23:0]};	// ARIA's, in words
	// THUMB 1: branch targets in halfwords, from the instruction's address +
	// 8 (ARM) or + 4 (Thumb, F16 and F18).
	wire [30:0] bt = 31'({pc, ph}) + (tm ? 31'd2 : 31'd4) +
		(tm ? (tf16 ? {{23{hw[7]}}, hw[7:0]} : {{20{hw[10]}}, hw[10:0]}) : {{6{insn[23]}}, insn[23:0], 1'b0});

	// Whether flags just set define C rather than pass it through: an
	// arithmetic operation, or a shift or rotation by a non-zero amount (or
	// RRX). Only c_unk below needs it.
	wire c_def = arith || (op_imm && !sh_reg ? !tm && insn[11:8] != 4'd0 : sh_rrx || sh_amt != 8'd0);

	// Faults from earlier clocks win over the instruction now in execute. With
	// c_unk set, an instruction that reads C halts with FLAGS; a condition on C
	// halts it whether or not the condition would pass.
	logic        c_unk;             // C is unknown: set by a Thumb MUL (THUMB 1)
	wire         flags_halt = c_unk && (cond_rd_c || (cond_ok && op_rd_c));
	wire         halt_now = chk_bad || late_v ||
		(state == S_RUN && !(DC && ret_v) && !freeze && (cond_ok && dec_bad || flags_halt));
	wire  [3:0] halt_code_now = chk_bad ? chk_code : late_v ? late_code :
		(!THUMB || (cond_ok && dec_bad && !(c_unk && cond_rd_c))) ? dec_code : HALT_FLAGS;
	wire [31:0] halt_pc_now = chk_bad ? chk_pc : late_v ? late_pc : pc_byte;

	state_t      nstate;
	logic [CODE_AW-1:0] npc;
	logic        npc_h;             // the next instruction's halfword (THUMB 1)
	logic        start, done;
	logic        flags_we;
	logic  [3:0] flags_d;
	logic        ctl_we;            // MSR writes the control byte (MODES 1)
	logic        t_we, t_d;         // BX writes the T bit (THUMB 1)
	logic        cu_set, cu_clr;    // c_unk: a Thumb MUL sets it, defining C clears it
	logic        acc_go;            // a single transfer or a beat accesses memory this clock
	logic        late_go;
	logic  [3:0] late_code_d;
	logic        ret_go;            // DC: a jump to the return sentinel (not late_go)
	logic        seq_next;          // npc is the next instruction in sequence

	// A jump to the byte address in v, with bit 0 dropped (Thumb's MOV pc,
	// ADD pc, POP {pc}, the BL suffix, and BX): {whether v lies outside the
	// code space (halt FETCH, one clock later), npc_h, npc}.
	function automatic logic [CODE_AW+1:0] jump(input logic [31:0] v);
		jump = {!code_ok({v[31:1], 1'b0}, p26, img_size), v[1], v[CODE_AW+1:2]};
	endfunction
	// The 2600 profile's return: a jump whose fetch address is 0xF000_0000 (bit
	// 0, the T bit, dropped), as upstream's return_fetch. 0xF000_0002 halts.
	function automatic logic is_ret(input logic [31:0] v);
		is_ret = v[31:1] == 31'h7800_0000;
	endfunction

	always_comb begin
		nstate = state;
		npc = pc;
		npc_h = pc_h;
		seq_next = 1'b0;
		start = 1'b0;
		done = 1'b0;
		rf_we = 1'b0;
		rf_wa = f_rd;
		rf_wd = alu_res;
		rf_w_class = 1'b0;
		flags_we = 1'b0;
		flags_d = dp_flags;
		ctl_we = 1'b0;
		t_we = 1'b0;
		t_d = rb[0];
		cu_set = 1'b0;
		cu_clr = 1'b0;
		ram_we = 1'b0;
		ram_be = st_bytes(t_size, addr_x[1:0]);
		ram_wdata = st_lanes(rb, t_size);
		d_addr = acc_addr;
		acc_go = 1'b0;
		late_go = 1'b0;
		late_code_d = HALT_FETCH;
		ret_go = 1'b0;
		reg_sel = 1'b0;

		case (state)
			S_CLEAR: begin
				rf_we = 1'b1;
				rf_wa = clr_idx[3:0];
				rf_wd = 32'd0;
				npc = '0;
				npc_h = 1'b0;
				if (DC && launch) begin
					// A call's launch: entries 0-21 from clr_wd, then the
					// entry (an ARM one must be word-aligned).
					rf_wd = clr_wd;
					{late_go, npc_h, npc} = jump(clr_pc);
					late_go = late_go || (!clr_pc[0] && clr_pc[1]);
					if (clr_idx == RFA'(21)) nstate = S_RUN;
					else late_go = 1'b0;
				end else if (clr_idx == (MD ? 5'd31 : 5'd14))
					nstate = p26 ? S_IDLE : S_RUN;
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
							cu_clr = bit_l && c_def;
						end
					end else if (k_mul || k_mull) begin
						nstate = S_MUL2;
					end else if (k_mrs) begin
						done = 1'b1;
						rf_we = 1'b1;
						rf_wd = {nzcv, 20'd0, MD ? ctl : 8'hD3};
					end else if (k_msr) begin
						done = 1'b1;
						flags_we = insn[19];
						flags_d = msr_value[31:28];
						cu_clr = insn[19];
						// Bits 27:24 read as 0 and the control byte takes only
						// what ctl_ok allows, so writing anything else halts (one
						// clock later), without changing the mode.
						ctl_we = MD && insn[16] && ctl_ok(msr_value[7:0]);
						late_go = (insn[16] && !ctl_ok(msr_value[7:0])) ||
							(insn[19] && msr_value[27:24] != 4'd0);
						late_code_d = HALT_UNDEF;
					end else if (k_br) begin
						done = 1'b1;
						if (THUMB) begin
							npc = bt[CODE_AW:1];
							npc_h = bt[0];
							late_go = !code_ok({bt, 1'b0}, p26, img_size);
						end else begin
							npc = br_target[CODE_AW-1:0];
							late_go = br_target[29:CODE_AW] != '0;
						end
						if (br_link) begin			// BL
							rf_we = 1'b1;
							rf_wa = 4'd14;
							rf_wd = link_value;
						end
					end else if (k_bx) begin
						// To Thumb with bit 0 set; to ARM, bit 1 must be clear.
						// arm_only (and THUMB 0) keeps the core in ARM state:
						// an odd target halts THUMB.
						done = 1'b1;
						{late_go, npc_h, npc} = jump(rb);
						late_go = late_go || (rb[0] ? !THUMB || arm_only : rb[1]);
						late_code_d = rb[0] && (!THUMB || arm_only) ? HALT_THUMB : HALT_FETCH;
						ret_go = p26 && is_ret(rb);
						t_we = THUMB && !arm_only;
					end else if (k_bl2) begin		// BL suffix: LR + offset, link
						done = 1'b1;
						{late_go, npc_h, npc} = jump(bl_sum);
						ret_go = p26 && is_ret(bl_sum);
						rf_we = 1'b1;
						rf_wa = 4'd14;
						rf_wd = link_value;
					end else if (k_movpc) begin		// MOV pc, Rm
						done = 1'b1;
						{late_go, npc_h, npc} = jump(rb);
						ret_go = p26 && is_ret(rb);
					end else if (k_addpc) begin		// ADD pc, Rm: the sum next clock
						nstate = S_MUL3;
					end else if (k_mem) begin
						acc_go = 1'b1;
						if (bit_l) begin
							nstate = S_W;
							rf_we = t_wb;			// base write-back now, data in W
							rf_wa = f_rn;
						end else if (!t_regoff && st_ram) begin
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
				if (done && !((k_br || k_bx || k_bl2 || k_movpc) && cond_ok)) begin
					npc = seq_w;
					npc_h = seq_h;
					seq_next = 1'b1;
				end
			end

			S_W: begin
				if (!acc_load) begin
					ram_be = st_bytes(acc_size, acc_addr[1:0]);
					ram_wdata = st_lanes(rb, acc_size);
				end
				reg_sel = acc_rg == RG_IO && !chk_bad;
				if (!w_wait) begin
					done = 1'b1;
					npc = seq_w;
					npc_h = seq_h;
					seq_next = 1'b1;
					rf_wa = l_rd;
					if (acc_load) begin
						if (l_rd == 4'hF) begin		// LDR pc (ARM state)
							npc = ldata[CODE_AW+1:2];
							npc_h = 1'b0;
							seq_next = 1'b0;
							late_go = ldata[1:0] != 2'b00 || !code_ok(ldata, p26, img_size);
							ret_go = p26 && ldata == 32'hF000_0000;
						end else begin
							rf_we = 1'b1;
							rf_wd = ldata;
							rf_w_class = 1'b1;
						end
					end else begin
						ram_we = acc_rg == RG_RAM;
						rf_we = wb_pend;
						rf_wa = l_rn;
						rf_wd = wb_value;
					end
				end
			end

			S_SHR2: begin
				rf_wa = l_rd;
				done = 1'b1;
				npc = seq_w;
				npc_h = seq_h;
				seq_next = 1'b1;
				rf_we = !dp_cmp;
				flags_we = bit_l;
				cu_clr = bit_l && c_def;
			end

			S_MUL2: begin
				rf_we = 1'b1;
				if (k_mull) begin
					rf_wa = l_rd;				// RdLo
					rf_wd = prod[31:0];
					nstate = S_MUL3;
				end else begin
					rf_wa = l_rn;				// MUL/MLA: Rd is bits 19:16; Thumb's hw[2:0]
					done = 1'b1;
					npc = seq_w;
					npc_h = seq_h;
					seq_next = 1'b1;
					// Thumb MUL sets N and Z, keeps V, and leaves C unknown:
					// its bit stays as it was, with c_unk set.
					flags_we = tm;
					if (tm) flags_d = {alu_res[31], alu_res == 32'd0, nzcv[1:0]};
					cu_set = tm;
				end
			end

			S_MUL3: begin
				if (THUMB && tm) begin			// ADD pc, Rm: the sum from execute
					done = 1'b1;
					{late_go, npc_h, npc} = jump(wb_value);
					ret_go = p26 && is_ret(wb_value);
				end else begin
					rf_we = 1'b1;
					rf_wa = l_rn;				// RdHi
					rf_wd = prod[63:32];
					done = 1'b1;
					npc = seq_w;
					npc_h = seq_h;
					seq_next = 1'b1;
				end
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
					rf_we = !(THUMB && ld_idx == 4'hF);	// POP {pc}: to npc instead
					rf_wa = ld_idx;
					rf_wd = ldata;
					rf_w_class = 1'b1;
				end else if (blk_first && bit_w) begin
					rf_we = 1'b1;				// the base, before any data comes back
					rf_wa = l_rn;
					rf_wd = blk_wb;
				end
				if (done) begin
					if (THUMB && ld_pend && ld_idx == 4'hF) begin
						{late_go, npc_h, npc} = jump(ldata);	// POP {pc}: T unchanged
						ret_go = p26 && is_ret(ldata);
					end else begin
						npc = seq_w;
						npc_h = seq_h;
						seq_next = 1'b1;
					end
				end
			end

			default: ;					// S_HALT; DC: S_IDLE, S_READOUT (below)
		endcase
		if (ret_go) late_go = 1'b0;			// the sentinel is not a fault

		// Running on from the end of the code space: the ARM7TDMI's fetch
		// there aborts, so halt (one clock later, as for a branch out of it)
		// rather than wrap to 0. A fault of the instruction itself wins.
		if (done && seq_next && seq_ovf && !late_go) begin
			late_go = 1'b1;
			late_code_d = HALT_FETCH;
		end

		// DARIA's call port. S_IDLE waits for a launch, which S_CLEAR writes. The
		// clock after a jump to the sentinel fetches nothing of the program's: it
		// goes to S_READOUT, which reads FIQ r8-r13 out on port B, one a clock,
		// and parks.
		if (DC && state == S_IDLE && call_go) nstate = S_CLEAR;
		if (DC && state == S_READOUT && ro_cnt == 3'd5) nstate = S_IDLE;
		if (DC && ret_v) begin
			nstate = S_READOUT;
			npc = pc;
			npc_h = pc_h;
			seq_next = 1'b0;
			start = 1'b0;
			done = 1'b0;
			rf_we = 1'b0;
			flags_we = 1'b0;
			ctl_we = 1'b0;
			t_we = 1'b0;
			cu_set = 1'b0;
			cu_clr = 1'b0;
			ram_we = 1'b0;
			reg_sel = 1'b0;
			acc_go = 1'b0;
			late_go = 1'b0;
			ret_go = 1'b0;
		end

		// A halt, or rst, stops everything this clock.
		if (rst || halt_now) begin
			nstate = S_HALT;
			npc = rst ? '0 : pc;
			npc_h = rst ? 1'b0 : pc_h;
			start = 1'b0;
			done = 1'b0;
			rf_we = 1'b0;
			flags_we = 1'b0;
			ctl_we = 1'b0;
			t_we = 1'b0;
			cu_set = 1'b0;
			cu_clr = 1'b0;
			ram_we = 1'b0;
			reg_sel = 1'b0;
			acc_go = 1'b0;
			late_go = 1'b0;
			ret_go = 1'b0;
		end else if (done)
			nstate = S_RUN;
	end

	assign rom_addr = npc;
	wire [3:0] nzcv_next = flags_we ? flags_d : nzcv;
	wire       c_unk_next = THUMB && (cu_set || (c_unk && !cu_clr));
	// A launch's last clock (P1): SYS mode with the entry's T bit, I and F
	// clear, NZCV 0, C known.
	wire       launch_end = DC && launch && state == S_CLEAR && clr_idx == RFA'(21) && !halt_now;

	always_ff @(posedge clk) begin
		pc <= npc;
		pc_h <= npc_h;
		if (rst) begin
			state <= S_CLEAR;
			clr_idx <= '0;
			nzcv <= 4'd0;
			c_unk <= 1'b0;
			ctl <= 8'hD3;
			m_fiq <= 1'b0;
			m_svc <= 1'b1;
			chk_v <= 1'b0;
			late_v <= 1'b0;
			ld_pend <= 1'b0;
			halted <= 1'b0;
			halt_code <= 4'd0;
			halt_pc <= 32'd0;
			launch <= 1'b0;
			ro_cnt <= 3'd0;
			ret_v <= 1'b0;
		end else begin
			state <= nstate;
			nzcv <= nzcv_next;
			c_unk <= c_unk_next;
			if (ctl_we) begin
				ctl <= msr_value[7:0];
				m_fiq <= msr_value[4:0] == 5'h11;
				m_svc <= msr_value[4:0] == 5'h13;
			end
			if (t_we) ctl[5] <= t_d;
			if (state == S_CLEAR) clr_idx <= clr_idx + 1'b1;
			if (DC) begin
				ret_v <= ret_go;
				ro_cnt <= state == S_READOUT ? ro_cnt + 3'd1 : 3'd0;
				if (state == S_IDLE && call_go) begin
					launch <= 1'b1;
					clr_idx <= '0;
				end
				if (launch_end) begin
					launch <= 1'b0;
					nzcv <= 4'd0;
					c_unk <= 1'b0;
					ctl <= {2'b00, clr_pc[0], 5'h1F};
					m_fiq <= 1'b0;
					m_svc <= 1'b0;
				end
			end
			if (halt_now && state != S_HALT) begin
				halted <= 1'b1;
				halt_code <= halt_code_now;
				halt_pc <= halt_pc_now;
			end

			// The access made this clock, for W and for next clock's check.
			chk_v <= acc_go;
			if (acc_go) begin
				acc_addr <= d_addr;
				acc_rg <= region(d_addr, p26);
				chk_pc <= pc_byte;
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
				late_pc <= DC && state == S_CLEAR ? {clr_pc[31:1], 1'b0} : pc_byte;	// a launch: the entry
			end

			if (state == S_RUN) begin
				rs_amt <= tm ? rb[7:0] : ra[7:0];	// Thumb F4: the amount is on port B
				x_rd <= f_rd;
				x_rn <= f_rn;
				x_rm <= f_rm;
				prod <= {32'd0, rb} * {32'd0, ra};
				wb_value <= sum;
				wb_pend <= t_wb;
				// LDM/STM: the write-back value, and where the first beat goes.
				blk_rest <= list;
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
	assign clr_e     = 5'(clr_idx);
	assign parked    = DC && state == S_IDLE;
	assign returned  = DC && state == S_READOUT && ro_cnt == 3'd5;
	assign ro_valid  = DC && state == S_READOUT;
	assign ro_idx    = ro_cnt;
	assign ro_data   = rb;
	assign w_addr    = acc_addr;
	assign w_size    = acc_size;
	assign w_asset   = state == S_W && acc_rg == RG_AST && acc_load && !chk_bad;
	assign reg_addr  = acc_addr[7:0];
	assign reg_write = !acc_load;
	assign reg_wdata = st_lanes(rb, acc_size);

`ifndef ALTERA_RESERVED_QIS
	assign rt_start  = start;
	assign rt_valid  = done && !halt_now;
	assign rt_pc     = pc_byte;
	assign rt_insn   = tm ? {16'd0, hw} : insn;
	assign rt_nzcv   = nzcv_next;
	assign rt_mode   = MD ? ctl[4:0] : 5'h13;
	assign rt_t      = THUMB && (t_we ? t_d : ctl[5]);
	assign rt_cunk   = c_unk_next;
	assign rt_e_we   = rf_we && !rf_w_class && state != S_CLEAR;
	assign rt_e_idx  = rf_wa;
	assign rt_e_data = rf_wd;
	assign rt_w_we   = rf_we && rf_w_class;
	assign rt_w_idx  = rf_wa;
	assign rt_w_data = rf_wd;
`endif
endmodule

`default_nettype wire
