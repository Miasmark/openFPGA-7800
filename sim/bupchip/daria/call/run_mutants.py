#!/usr/bin/env python3
"""Planted faults in bup_cpu.sv's 2600 profile and call port: each must make
run_call.py fail (the plain variant). A mutant that passes is a hole in the
tests.

  run_mutants.py [NAME ...]

Environment: WORK (default sim/work/bupchip/daria/call), CORE_SV (the core to
mutate; default the working tree's).
SPDX-License-Identifier: MIT
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../../.."))
WORK = os.environ.get("WORK", os.path.join(ROOT, "sim/work/bupchip/daria/call"))
CORE = os.environ.get("CORE_SV", os.path.join(ROOT, "src/fpga/core/bupchip/bup_cpu.sv"))

MUTANTS = {
    "launch_zero_data":   ("rf_wd = clr_wd;", "rf_wd = 32'd0;"),
    "launch_t_ignored":   ("ctl <= {2'b00, clr_pc[0], 5'h1F};", "ctl <= {2'b00, 1'b0, 5'h1F};"),
    "launch_svc_mode":    ("ctl <= {2'b00, clr_pc[0], 5'h1F};", "ctl <= {2'b00, clr_pc[0], 5'h13};"),
    "launch_nzcv_kept":   ("					nzcv <= 4'd0;\n", ""),
    "launch_short":       ("if (clr_idx == RFA'(21)) nstate = S_RUN;", "if (clr_idx == RFA'(20)) nstate = S_RUN;"),
    "launch_writes_22":   ("if (clr_idx == RFA'(21)) nstate = S_RUN;", "if (clr_idx == RFA'(22)) nstate = S_RUN;"),
    "launch_idx_kept":    ("					clr_idx <= '0;\n", ""),
    "sentinel_wrong":     ("is_ret = v[31:1] == 31'h7800_0000;", "is_ret = v[31:2] == 30'h3C00_0000;"),
    "sentinel_any_prof":  ("ret_go = p26 && is_ret(rb);\n\t\t\t\t\t\tt_we", "ret_go = DC && is_ret(rb);\n\t\t\t\t\t\tt_we"),
    "readout_offset":     ("pb_x = RFA'(5'd16 + {2'd0, ro_cnt});", "pb_x = RFA'(5'd17 + {2'd0, ro_cnt});"),
    "readout_short":      ("if (DC && state == S_READOUT && ro_cnt == 3'd5) nstate = S_IDLE;",
                           "if (DC && state == S_READOUT && ro_cnt == 3'd4) nstate = S_IDLE;"),
    "reset_runs":         ("nstate = p26 ? S_IDLE : S_RUN;", "nstate = S_RUN;"),
    "ret_decode_halts":   ("(state == S_RUN && !(DC && ret_v) && !freeze", "(state == S_RUN && !freeze"),
    "ram_ignores_ram32":  ("(ram32 || acc_addr[14:13] == 2'b00)", "1'b1"),
    "rom_size_off":       ("< WIN_B && {1'b0, acc_addr[18:0]} < img_size;\n\twire in_ast_g",
                           "< WIN_B && {1'b0, acc_addr[18:0]} <= img_size;\n\twire in_ast_g"),
    "ast_size_ignored":   (">= WIN_B && {1'b0, acc_addr[18:0]} < img_size;", ">= WIN_B;"),
    "split_by_bit25":     ("(p ? {1'b0, a[18:0]} >= WIN_B : a[25])", "a[25]"),
    "bup_code_128k":      ("else code_ok = a[31:14] == '0;", "else code_ok = a[31:17] == '0;"),
    "io_window_small":    ("acc_addr[31:21] == 11'h700", "acc_addr[31:20] == 12'hE00"),
    "entry_unchecked":    ("late_go = late_go || (!clr_pc[0] && clr_pc[1]);", "late_go = 1'b0;"),
}


def main():
    names = sys.argv[1:] or list(MUTANTS)
    src = open(CORE).read()
    d = os.path.join(WORK, "mut")
    os.makedirs(d, exist_ok=True)
    holes = 0
    for n in names:
        old, new = MUTANTS[n]
        if src.count(old) != 1:
            print("BAD  %-20s the pattern matches %d times" % (n, src.count(old)))
            holes += 1
            continue
        m = os.path.join(d, n + ".sv")
        open(m, "w").write(src.replace(old, new))
        env = dict(os.environ, CORE_SV=m, VARIANTS="plain", WORK=os.path.join(d, n))
        env["OBJ"] = os.path.join(d, n, "obj")
        r = subprocess.run([sys.executable, os.path.join(HERE, "run_call.py")], env=env,
                           capture_output=True, text=True)
        fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        if r.returncode != 0 and fails:
            print("CAUGHT %-20s %d failing, first: %s" % (n, len(fails), fails[0].split()[1]))
        elif r.returncode != 0:
            print("BAD  %-20s run error: %s" % (n, (r.stderr or r.stdout).strip().splitlines()[-1:]))
            holes += 1
        else:
            print("HOLE %-20s every test passes" % n)
            holes += 1
    print("mutants: %d of %d caught" % (len(names) - holes, len(names)))
    sys.exit(1 if holes else 0)


if __name__ == "__main__":
    main()
