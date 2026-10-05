#!/usr/bin/env python3
"""The mutations of docs/DARIA_CORE.md, step 2 ("Mutations"): each one
plants one plausible Thumb bug in a copy of src/fpga/core/bupchip/bup_cpu.sv,
and every one must be caught by a check (run_mutants.sh).

  mutants.py list                 the mutant names
  mutants.py make NAME OUT.sv     write that mutant

Each patch is an exact text replacement in bup_cpu.sv; if the core's text
has changed so that a patch no longer applies, `make` fails rather than
writing an unmutated copy.
"""
import os
import sys

CORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../src/fpga/core/bupchip/bup_cpu.sv")

MUTANTS = {
    # F6 and F12 read r15 unaligned.
    "pcrel_unaligned": [("always_comb pcrel = tm && (tf6 || (tf12 && !hw[11]));",
                         "always_comb pcrel = 1'b0;")],
    # The BL prefix's offset not shifted by 12.
    "bl_prefix_noshift": [("else if (tbl1) th_immv = {{9{hw[10]}}, hw[10:0], 12'd0};",
                           "else if (tbl1) th_immv = {{21{hw[10]}}, hw[10:0]};")],
    # The BL suffix's link without bit 0.
    "bl_link_bit0": [("wire  [31:0] link_value = tm ? 32'({seq_w, seq_h, 1'b1})",
                      "wire  [31:0] link_value = tm ? 32'({seq_w, seq_h, 1'b0})")],
    # POP {pc} interworks (ARMv5): T from bit 0 of the popped value.
    "pop_pc_interworks": [("{late_go, npc_h, npc} = jump(ldata);\t// POP {pc}: T unchanged",
                           "begin {late_go, npc_h, npc} = jump(ldata); t_we = 1'b1; t_d = ldata[0]; end")],
    # F1's LSR #0 and ASR #0 as no shift (instead of #32).
    "f1_shift0_noshift": [("(sh_imm == 5'd0 && (sh_type == 2'b01 || sh_type == 2'b10)) ? 8'd32",
                           "(!tm && sh_imm == 5'd0 && (sh_type == 2'b01 || sh_type == 2'b10)) ? 8'd32")],
    # NEG as 0 - Rd.
    "neg_of_rd": [("alu_a = 32'd0;\t\t\t\t// Thumb NEG: 0 - Rs",
                   "begin alu_a = 32'd0; alu_b = ra; end")],
    # F5 MOV and ADD set flags (not only CMP).
    "f5_mov_sets_flags": [("wire th_s   = tf1 || tf2 || tf3 || tf4 || (tf5 && t5op == 2'b01);",
                           "wire th_s   = tf1 || tf2 || tf3 || tf4 || tf5;")],
    # F5 CMP sets no flags.
    "f5_cmp_no_flags": [("wire th_s   = tf1 || tf2 || tf3 || tf4 || (tf5 && t5op == 2'b01);",
                         "wire th_s   = tf1 || tf2 || tf3 || tf4;")],
    # Thumb SBC's carry-in inverted.
    "sbc_carry_inverted": [("OP_ADC, OP_SBC, OP_RSC: cin = flag_c;",
                            "OP_ADC, OP_SBC, OP_RSC: cin = (tm && alu_op == OP_SBC) ? !flag_c : flag_c;")],
    # Thumb STMIA stores the old base when the base is not first: the base is
    # written back only in the last beat.
    "stmia_old_base": [("end else if (blk_first && bit_w) begin",
                        "end else if (tm && !bit_l ? done && bit_w : blk_first && bit_w) begin")],
    # The halfword picked a clock late, not by the pc_h of the word in rom_q.
    "half_select_late": [("wire  [15:0] hw = ph ? rom_q[31:16] : rom_q[15:0];",
                          "logic ph_d; always_ff @(posedge clk) ph_d <= ph;\n"
                          "\twire  [15:0] hw = ph_d ? rom_q[31:16] : rom_q[15:0];")],
    # Thumb steps two halfwords.
    "thumb_step_word": [("wire  [CODE_AW-1:0] seq_w = (tm && !ph) ? pc : pc_next1[CODE_AW-1:0];\n"
                         "\twire         seq_h = tm && !ph;",
                         "wire  [CODE_AW-1:0] seq_w = pc_next1[CODE_AW-1:0];\n"
                         "\twire         seq_h = ph;")],
    # The read-index select keyed on T only (the low half's indices always).
    "index_select_t_only": [("if (tm) pa_x = ph ? phys(ta_hi, m_fiq, m_svc) : phys(ta_lo, m_fiq, m_svc);",
                             "if (tm) pa_x = phys(ta_lo, m_fiq, m_svc);"),
                            ("ia = ph ? ta_hi : ta_lo;", "ia = ta_lo;")],
    # c_unk never set.
    "cunk_never_set": [("cu_set = tm;", "cu_set = 1'b0;")],
    # BX to Thumb leaves T clear.
    "bx_t_clear": [("t_we = THUMB && !arm_only;", "t_we = 1'b0;")],
    # F11's data register taken from hw[2:0] (the two-clock store's data, and
    # the load's destination).
    "f11_rd_low": [("wire [3:0] th_rd = (tf3 || tf6 || tf11 || tf12) ? {1'b0, hw[10:8]}",
                    "wire [3:0] th_rd = (tf3 || tf6 || tf12) ? {1'b0, hw[10:8]}")],
    # Thumb MUL clears V.
    "mul_writes_v": [("if (tm) flags_d = {alu_res[31], alu_res == 32'd0, nzcv[1:0]};",
                      "if (tm) flags_d = {alu_res[31], alu_res == 32'd0, nzcv[1], 1'b0};")],
}


def make(name, out):
    s = open(CORE).read()
    for old, new in MUTANTS[name]:
        if s.count(old) != 1:
            sys.exit("mutant %s: patch text found %d times in bup_cpu.sv" % (name, s.count(old)))
        s = s.replace(old, new)
    open(out, "w").write(s)


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        print("\n".join(MUTANTS))
    elif len(sys.argv) == 4 and sys.argv[1] == "make":
        make(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
