//------------------------------------------------------------------------------
// Exhaustive Thumb decode probe for DARIA's core (run_decode.sh): bup_cpu
// with THUMB 1 runs a two-word ARM start-up that BXes into Thumb state, then
// is held with freeze, so nothing more starts but the combinational decode
// still follows rom_q, the T bit and pc_h. Each of the 65,536 halfwords is
// then put in the half of rom_q that pc_h selects, with a decoy halfword in
// the other half, and the decode is dumped through hierarchical references:
// the class bits, the merged controls, the first clock's read ports (the
// selected pair and both halves' candidates), immediates, shift, transfer,
// list, condition, halt decision, the C-flag readers and the PC-derived
// values (r15, branch target, link). tdec_check.py compares the dump with
// thumb_expand.py --table.
//
//   +odd=0|1   enter Thumb at 0x10 (0) or 0x12 (1)
//   +mul=0|1   run a Thumb MULS first, so that C is unknown (c_unk) while
//              probing; the probe then sits on the next halfword, so pc_h
//              is odd ^ mul
//   +out=FILE  the dump (default tdec.txt): a header line naming the
//              columns, then one line per halfword, all in hex
//
// The decoy is (hw * 0x9e37 + 0x7f4a) mod 2^16, a permutation, so every
// halfword also passes through the unselected half once per run.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ns
module tb_tdec;
	logic        clk = 0, rst = 1;
	logic [31:0] rom [0:15];
	logic [31:0] rom_reg = 0, probe_w = 0;
	logic        probing = 0;
	int          odd = 0, mul = 0;
	wire  [31:0] q = probing ? probe_w : rom_reg;
	wire  [11:0] rom_addr;

	// Hold the core from its first Thumb instruction on (after the MULS with
	// +mul=1, once C is unknown).
	wire freeze = cpu.ctl[5] && (mul == 0 || cpu.c_unk);

	bup_cpu #(.MODES(1'b1), .THUMB(1'b1)) cpu (
		.clk, .rst, .freeze, .w_wait(1'b0), .arm_only(1'b0),
		.rom_addr, .rom_q(q),
		.d_addr(), .ram_we(), .ram_be(), .ram_wdata(), .rom_dq(32'd0), .ram_q(32'd0),
		.asset_size(24'd0), .asset_q(32'd0), .w_asset(), .w_addr(), .w_size(),
		.reg_sel(), .reg_addr(), .reg_write(), .reg_wdata(), .reg_rdata(32'd0),
		.halted(), .halt_code(), .halt_pc(),
		.rt_start(), .rt_valid(), .rt_pc(), .rt_insn(), .rt_nzcv(), .rt_mode(), .rt_t(), .rt_cunk(),
		.rt_e_we(), .rt_e_idx(), .rt_e_data(), .rt_w_we(), .rt_w_idx(), .rt_w_data());

	always @(posedge clk) rom_reg <= rom[rom_addr[3:0]];

	task automatic tick();
		#5 clk = 1;
		#5 clk = 0;
	endtask

	initial begin
		string f;
		int    fd, n;
		logic [15:0] hw, decoy;
		if (!$value$plusargs("out=%s", f)) f = "tdec.txt";
		void'($value$plusargs("odd=%d", odd));
		void'($value$plusargs("mul=%d", mul));
		foreach (rom[i]) rom[i] = 32'h46c0_46c0;		// Thumb: mov r8, r8
		rom[0] = 32'he3a0_0011 | (odd != 0 ? 32'h2 : 32'h0);	// mov r0, #0x11 or #0x13
		rom[1] = 32'he12f_ff10;					// bx r0
		if (mul != 0)						// muls r0, r1 at the entry
			rom[4] = odd != 0 ? 32'h4348_46c0 : 32'h46c0_4348;
		repeat (4) tick();
		rst = 0;
		n = 0;
		while (!(freeze && cpu.state == 3'd1) && n < 200) begin	// S_RUN, held
			tick();
			n++;
		end
		if (n == 200 || !cpu.tm || cpu.pc_h != ((odd != 0) ^ (mul != 0)) || cpu.c_unk != (mul != 0) || cpu.halted)
			$fatal(1, "tb_tdec: not held in Thumb as expected (T %0d, pc %0d, pc_h %0d, c_unk %0d, halted %0d)",
				cpu.tm, cpu.pc, cpu.pc_h, cpu.c_unk, cpu.halted);
		fd = $fopen(f, "w");
		if (fd == 0) $fatal(1, "cannot open %s", f);
		$fwrite(fd, "# tb_tdec odd=%0d mul=%0d pc=%0d pc_h=%0d c_unk=%0d\n", odd, mul, cpu.pc, cpu.pc_h, cpu.c_unk);
		$fwrite(fd, "hw decoy state tm pc_h c_unk pc_byte k_dp k_mul k_mull k_mrs k_msr k_br k_bx k_mem k_blk k_bl2 k_movpc k_addpc br_link");
		$fwrite(fd, " dp_op bit_l bit_p bit_u bit_w t_wb dp_rsh dp_cmp op_imm zero_a pcrel t_size t_sign t_regoff");
		$fwrite(fd, " f_rd f_rn f_rm ia ib ta_lo tb_lo ta_hi tb_hi th_immv th_offv sh_type sh_imm sh_amt sh_rrx");
		$fwrite(fd, " list cond cond_rd_c op_rd_c dec_bad dec_code c_def bt link_value r15_value flags_halt halt_code_now\n");
		probing = 1;
		for (int i = 0; i < 65536; i++) begin
			hw = 16'(i);
			decoy = 16'(i * 32'h9e37 + 32'h7f4a);
			probe_w = cpu.pc_h ? {hw, decoy} : {decoy, hw};
			#1;
			$fwrite(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
				hw, decoy, cpu.state, cpu.tm, cpu.pc_h, cpu.c_unk, cpu.pc_byte,
				cpu.k_dp, cpu.k_mul, cpu.k_mull, cpu.k_mrs, cpu.k_msr, cpu.k_br, cpu.k_bx, cpu.k_mem,
				cpu.k_blk, cpu.k_bl2, cpu.k_movpc, cpu.k_addpc, cpu.br_link);
			$fwrite(fd, " %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
				cpu.dp_op, cpu.bit_l, cpu.bit_p, cpu.bit_u, cpu.bit_w, cpu.t_wb, cpu.dp_rsh, cpu.dp_cmp,
				cpu.op_imm, cpu.zero_a, cpu.pcrel, cpu.t_size, cpu.t_sign, cpu.t_regoff);
			$fwrite(fd, " %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
				cpu.f_rd, cpu.f_rn, cpu.f_rm, cpu.ia, cpu.ib, cpu.ta_lo, cpu.tb_lo, cpu.ta_hi, cpu.tb_hi,
				cpu.th_immv, cpu.th_offv, cpu.sh_type, cpu.sh_imm, cpu.sh_amt, cpu.sh_rrx);
			$fwrite(fd, " %h %h %h %h %h %h %h %h %h %h %h %h\n",
				cpu.list, cpu.cond, cpu.cond_rd_c, cpu.op_rd_c, cpu.dec_bad, cpu.dec_code, cpu.c_def,
				cpu.bt, cpu.link_value, cpu.r15_value, cpu.flags_halt, cpu.halt_code_now);
		end
		$fclose(fd);
		$display("tb_tdec: odd=%0d mul=%0d, 65536 halfwords at pc_h %0d, c_unk %0d -> %s", odd, mul, cpu.pc_h, cpu.c_unk, f);
		$finish;
	end
endmodule
