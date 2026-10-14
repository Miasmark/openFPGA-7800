#!/usr/bin/env python3
"""The benches' and gates' default clk_arm divider against the tree's
(DARIA step 7, docs/daria_step7/plan.md 7.7; the D review's finding 7).

  div_check.py [--repo DIR]

pll_core.v selects counter 3's divider under POCKET_DARIA (VCO/18 or VCO/19);
step7_prep.py --tree-div reads which. The benches and gates that stand for
the shipped clock take their default from hand-set lines, and a partial
merge or a hand edit could leave them on the other lattice without notice.
Each site below must name the tree's divider, directly or through what it
implies (at VCO/19 daria_fe's guard never locks, so the guard is expected
"unlocked"; at VCO/18 "locked"):
  sim/tb_load.sv, sim/tb_system.sv        int arm_div = N
  sim/bupchip/daria/wire/wire.py          ARM_DIV's default "N"
  sim/run_sim.sh                          ${ARM_DIV:-N} and the guard it expects
  sim/check/frame_gate.py                 --expect-guard's default
  sim/step7_gates.sh                      ${FRAMES_GUARD:-G}; the s4_check DARIA
                                          set's ARM19=1 (19) or ARM38=1 (18)
  sim/bupchip/quartus_probe/step7/step7_report.tcl   prep's div N
  sim/bupchip/quartus_probe/step7/run_step7.sh       DIV's default is the
                                          tree's (--tree-div), not a number
  sim/bupchip/daria/run_daria.sh          MODE_B=1's +d_div: D_DIV, by default
                                          the tree's (--tree-div), passed to
                                          the mode-B shadow (the D fix round's
                                          review)
Benches on a fixed lattice by design are listed, not checked: the mode-B
shadow's own +d_div default (daria_shadow.svh, 18; run_daria.sh always
passes +d_div, so only a binary run by hand takes it), tb_dbg_snap's +div
(both lattices, run_dbgsnap.sh passes +div=19 for its VCO/19 cases) and
tb_fe_call's +arm_div (18 or 5, its lattice built in).
A tree whose pll_core.v has no POCKET_DARIA branch (divider 24) has nothing
to check. Prints one line per site and a verdict; exit 0 pass, 1 fail.
SPDX-License-Identifier: MIT
"""
import argparse
import os
import re
import subprocess
import sys

GUARD = {19: "unlocked", 18: "locked"}


def main():
    p = argparse.ArgumentParser(description="default dividers against pll_core.v's (plan 7.7)")
    p.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = p.parse_args()
    R = os.path.abspath(a.repo)
    prep = os.path.join(R, "sim/bupchip/quartus_probe/step7/step7_prep.py")
    r = subprocess.run([sys.executable, prep, os.path.join(R, "src/fpga"), "--tree-div"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip().isdigit():
        print(f"div_check: step7_prep.py --tree-div failed: {(r.stderr or r.stdout).strip()}")
        print("DIV_CHECK FAIL")
        return 1
    div = int(r.stdout.strip())
    print(f"div_check: pll_core.v's DARIA counter 3 is VCO/{div} (step7_prep.py --tree-div)")
    if div == 24:
        print("  no POCKET_DARIA branch in pll_core.v: nothing to check")
        print("DIV_CHECK pass (not applicable)")
        return 0
    bad = []

    def read(rel):
        try:
            return open(os.path.join(R, rel), errors="replace").read()
        except OSError:
            bad.append(f"{rel}: missing")
            return None

    def one(rel, pat, what, want, conv=int):
        t = read(rel)
        if t is None:
            return
        m = re.findall(pat, t, re.M)
        if len(m) != 1:
            bad.append(f"{rel}: {what}: {len(m)} matches of its line, expected 1")
            print(f"  FAIL {rel}: {what}: line not found once")
            return
        got = conv(m[0])
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {rel}: {what} {got}" + ("" if ok else f", expected {want}"))
        if not ok:
            bad.append(f"{rel}: {what} {got}, expected {want}")

    g = GUARD.get(div)
    if g is None:
        print(f"  FAIL: no known guard expectation at VCO/{div}")
        print("DIV_CHECK FAIL")
        return 1
    one("sim/tb_load.sv", r"^\s*int arm_div = (\d+)\b", "arm_div default", div)
    one("sim/tb_system.sv", r"^\s*int arm_div = (\d+)\b", "arm_div default", div)
    one("sim/bupchip/daria/wire/wire.py", r"^ARM_DIV = os\.environ\.get\(\"ARM_DIV\", \"(\d+)\"\)", "ARM_DIV default", div)
    one("sim/run_sim.sh", r"\$\{ARM_DIV:-(\d+)\}", "ARM_DIV default (the guard check's)", div)
    t = read("sim/run_sim.sh")
    if t is not None:
        m = re.findall(r"^\s*guard=(\w+); \[ \"\$\{ARM_DIV:-\d+\}\" = (\d+) \] && guard=(\w+)$", t, re.M)
        if len(m) != 1:
            bad.append("sim/run_sim.sh: the guard expectation's line not found once")
            print("  FAIL sim/run_sim.sh: the guard expectation's line not found once")
        else:
            dflt, other_div, other = m[0]
            ok = dflt == g and GUARD.get(int(other_div)) == other and int(other_div) != div
            print(f"  {'ok  ' if ok else 'FAIL'} sim/run_sim.sh: guard expected {dflt} by default, {other} at VCO/{other_div}"
                  + ("" if ok else f" (VCO/{div}: {g})"))
            if not ok:
                bad.append(f"sim/run_sim.sh: guard {dflt} by default at VCO/{div}, expected {g}")
    one("sim/check/frame_gate.py", r"\"--expect-guard\", default=\"(\w+)\"", "--expect-guard default", g, str)
    one("sim/step7_gates.sh", r"\$\{FRAMES_GUARD:-(\w+)\}", "FRAMES_GUARD default", g, str)
    one("sim/step7_gates.sh", r"^\s*DARIA=1 (ARM\d\d)=1 PSRAM_CS=", "s4_check's DARIA set", "ARM19" if div == 19 else "ARM38", str)
    one("sim/bupchip/quartus_probe/step7/step7_report.tcl", r"^array set prep \{.*\bdiv (\d+)\}", "prep div default", div)
    t = read("sim/bupchip/quartus_probe/step7/run_step7.sh")
    if t is not None:
        ok = re.search(r'^\[ -n "\$DIV" \] \|\| DIV="\$TREE_DIV"$', t, re.M) is not None \
            and re.search(r'TREE_DIV="\$\(python3 "\$HERE/step7_prep\.py" "\$TREE/src/fpga" --tree-div\)"', t) is not None
        print(f"  {'ok  ' if ok else 'FAIL'} sim/bupchip/quartus_probe/step7/run_step7.sh: DIV defaults to the tree's (--tree-div)")
        if not ok:
            bad.append("run_step7.sh: DIV's default is not the tree's divider")
    t = read("sim/bupchip/daria/run_daria.sh")
    if t is not None:
        ok = re.search(r'^\s*D_DIV="\$\{D_DIV:-\$TREE_DIV\}"$', t, re.M) is not None \
            and re.search(r'TREE_DIV="\$\(python3 "\$HERE/\.\./quartus_probe/step7/step7_prep\.py" "\$FPGA" --tree-div\)"',
                          t) is not None \
            and re.search(r'^\s*set -- "\$@" "\+d_div=\$D_DIV"$', t, re.M) is not None
        print(f"  {'ok  ' if ok else 'FAIL'} sim/bupchip/daria/run_daria.sh: MODE_B's +d_div defaults to the tree's (--tree-div)")
        if not ok:
            bad.append("run_daria.sh: MODE_B's +d_div does not default to the tree's divider")
    print("  not checked (a fixed lattice by design): daria_shadow.svh's own +d_div default (18; run_daria.sh passes the tree's), "
          "tb_dbg_snap.sv +div (run_dbgsnap.sh passes +div=19 for its VCO/19 cases), tb_fe_call.sv +arm_div (18 or 5)")
    for b in bad:
        print("  FAIL: " + b)
    print("DIV_CHECK " + ("pass" if not bad else "FAIL"))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
