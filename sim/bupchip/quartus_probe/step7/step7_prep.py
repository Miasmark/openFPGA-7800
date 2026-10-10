#!/usr/bin/env python3
"""Edits a copy of src/fpga for one step-7 fit (run_step7.sh; docs/daria_step7/
plan.md 3.5 "Fit scripts", 4.3). Every edit is checked: each must find exactly
what it replaces, and the result is verified. Prints what it changed, as a
diff against the copy before the edits.

Usage: step7_prep.py FPGA_COPY [--nodaria] [--pin-id] [--oldpad] [--div 18|19]
                     [--seed N] [--oldpad-ref FILE]

  --nodaria     delete the three DARIA lines of ap_core.qsf (the macro
                POCKET_DARIA, QIP_FILE core/daria.qip, SDC_FILE
                core/daria_constraints.sdc); a tree without them (aeee6d2,
                commit F) is left as it is, and says so. Refused when an
                active qsf line names POCKET_DARIA, daria.qip or
                daria_constraints.sdc and is not one of the three lines
                exactly (a changed or extra line would leave DARIA in the
                build while the kind says base), and checked afterwards:
                no active line of the copy's qsf names any of them
  --pin-id      no PRE_FLOW_SCRIPT_FILE (apf/build_id_gen.tcl stamps
                apf/build_id.mif with the date, the time and a random word on
                every compile) and a fixed apf/build_id.mif, so that two
                compiles of the same tree can give the same bitstream
  --oldpad      core_constraints.sdc's fitter-only padding as at aeee6d2
                (setup into clk_sdram 1.0 ns, no hold line from clk_sys into
                clk_sdram): commit F's padding taken out again (Q1b, P11).
                Verified against --oldpad-ref, aeee6d2's file
  --div 19      clk_arm at VCO/19 under POCKET_DARIA: pll_core.v's
                POCKET_DARIA branches take ip-generate's C3 = 19 counter-3
                lines, and the four display strings the tool prints with
                them, so that the copy, preprocessed with POCKET_DARIA, is
                the tool's C3 = 19 output (plan P10, 5.2)
  --seed N      the SEED line
Writes FPGA_COPY/step7_prep.txt: the settings and the kind of build
(base: no Fix B, no DARIA; builda: Fix B, no DARIA; daria; q5: DARIA and
BUP_DEBUG), which step7_report.tcl and step7_checks.py read. The kind is
read from the edited copy, not from the options: DARIA when the copy's
qsf has the three DARIA lines, BUP_DEBUG when it defines that macro. Any
other place that defines POCKET_DARIA (a .qip, or a `define in a source
file) is refused.
"""
import argparse
import difflib
import os
import re
import sys

DARIA_LINES = [
    'set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"',
    "set_global_assignment -name QIP_FILE core/daria.qip",
    "set_global_assignment -name SDC_FILE core/daria_constraints.sdc",
]
PRE_FLOW = 'set_global_assignment -name PRE_FLOW_SCRIPT_FILE "quartus_sh:apf/build_id_gen.tcl"'
PINNED_MIF = """-- Build ID Memory Initialization File
-- Pinned by the step-7 fit driver (PIN_ID=1): no date, time or random word,
-- so that two compiles of one tree can be compared bit for bit.

DEPTH = 256;
WIDTH = 32;
ADDRESS_RADIX = HEX;
DATA_RADIX = HEX;

CONTENT
BEGIN

   0E0 : 20000101;
   0E1 : 00000000;
   0E2 : 00000000;

END;
"""
# ip-generate's C3 = 19 output against its C3 = 24 output (the tree's lines
# outside POCKET_DARIA). The counter-3 lines go into the POCKET_DARIA branches;
# the four display strings are outside them.
DIV19_C3 = [
    ('.output_clock_frequency3("38.181816 MHz")', '.output_clock_frequency3("36.172244 MHz")'),
    (".c_cnt_hi_div3(9)", ".c_cnt_hi_div3(10)"),
    (".c_cnt_lo_div3(9)", ".c_cnt_lo_div3(9)"),
    ('.c_cnt_odd_div_duty_en3("false")', '.c_cnt_odd_div_duty_en3("true")'),
]
DIV19_DISPLAY = [
    ('.output_clock_frequency0("14.318181 MHz")', '.output_clock_frequency0("14.318180 MHz")'),
    ('.output_clock_frequency1("57.272724 MHz")', '.output_clock_frequency1("57.272722 MHz")'),
    ('.output_clock_frequency2("14.318181 MHz")', '.output_clock_frequency2("14.318180 MHz")'),
    ('.pll_output_clk_frequency("687.272687 MHz")', '.pll_output_clk_frequency("687.272644 MHz")'),
]


def die(msg):
    sys.exit("step7_prep.py: " + msg)


def read(p):
    with open(p, encoding="latin-1") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="latin-1") as f:
        f.write(s)


def show(path, before, after, root):
    rel = os.path.relpath(path, root)
    d = list(difflib.unified_diff(before.splitlines(), after.splitlines(), "tree/" + rel, "copy/" + rel,
                                  lineterm="", n=1))
    print("\n".join(d) if d else f"(no change to {rel})")


def active(lines):
    """The qsf lines Quartus reads: not blank, not a comment."""
    return [l for l in lines if l.strip() and not l.lstrip().startswith("#")]


def daria_named(lines):
    """Active qsf lines that name POCKET_DARIA, daria.qip or daria_constraints.sdc."""
    return [l for l in active(lines) if re.search(r"POCKET_DARIA|daria\.qip|daria_constraints\.sdc", l)]


def sdc_code(s):
    """The SDC's lines with comments and blank lines dropped."""
    out = []
    for line in s.splitlines():
        line = line.split("#", 1)[0].strip() if line.lstrip().startswith("#") else line.rstrip()
        if line.strip():
            out.append(" ".join(line.split()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fpga")
    ap.add_argument("--nodaria", action="store_true")
    ap.add_argument("--pin-id", action="store_true")
    ap.add_argument("--oldpad", action="store_true")
    ap.add_argument("--oldpad-ref")
    ap.add_argument("--div", type=int, default=18, choices=(18, 19))
    ap.add_argument("--seed", type=int)
    a = ap.parse_args()
    root = a.fpga
    qsf_p = os.path.join(root, "ap_core.qsf")
    qsf0 = qsf = read(qsf_p)
    notes = []

    # ---- SEED -----------------------------------------------------------------------------
    if a.seed is not None:
        n = len(re.findall(r"(?m)^set_global_assignment -name SEED \d+$", qsf))
        if n != 1:
            die(f"ap_core.qsf has {n} SEED lines, expected 1")
        qsf = re.sub(r"(?m)^set_global_assignment -name SEED \d+$", f"set_global_assignment -name SEED {a.seed}", qsf)

    # ---- the DARIA lines ----------------------------------------------------------------------
    lines = qsf.splitlines()
    named = daria_named(lines)
    present = [l for l in DARIA_LINES if lines.count(l) == 1]
    for l in DARIA_LINES:
        if lines.count(l) > 1:
            die(f"ap_core.qsf has '{l}' {lines.count(l)} times")
    other = [l for l in named if l not in DARIA_LINES]
    if other:
        die("ap_core.qsf has active lines that name POCKET_DARIA, daria.qip or daria_constraints.sdc but are not "
            f"one of the three DARIA lines exactly (whitespace, quotes and order count): {other}")
    if present and len(present) != 3:
        die(f"ap_core.qsf has {len(present)} of the 3 DARIA lines: {present}")
    if present:
        iq = max(i for i, l in enumerate(lines) if l.startswith("set_global_assignment -name QIP_FILE "))
        isdc = lines.index(DARIA_LINES[2])
        if isdc < iq:
            die("the SDC_FILE core/daria_constraints.sdc line comes before a QIP_FILE line (P9)")
    if a.nodaria:
        if present:
            lines = [l for l in lines if l not in DARIA_LINES]
            notes.append("NODARIA: the 3 DARIA lines deleted")
        else:
            notes.append("NODARIA: the tree has none of the 3 DARIA lines; nothing to delete")
        left = daria_named(lines)
        if left:
            die(f"NODARIA: active qsf lines still name POCKET_DARIA, daria.qip or daria_constraints.sdc: {left}")
    elif not present:
        notes.append("the tree has no DARIA lines: a build without DARIA")
    daria = bool(present) and not a.nodaria      # as planned; checked against the copy below
    qsf = "\n".join(lines) + ("\n" if qsf.endswith("\n") else "")
    # POCKET_DARIA from anywhere else would build DARIA under another kind.
    elsewhere = []
    for dp, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(dp, f)
            if f.endswith(".qip"):
                elsewhere += [f"{os.path.relpath(p, root)}: {l.strip()}" for l in read(p).splitlines()
                              if not l.lstrip().startswith("#") and "POCKET_DARIA" in l]
            elif f.endswith((".v", ".sv", ".svh", ".vh")):
                elsewhere += [f"{os.path.relpath(p, root)}: {l.strip()}" for l in read(p).splitlines()
                              if re.match(r"\s*`define\s+POCKET_DARIA\b", l)]
    if elsewhere:
        die(f"POCKET_DARIA is defined outside ap_core.qsf's macro line: {elsewhere[:4]}")
    debug = any(re.match(r'\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"?BUP_DEBUG(=1)?"?\s*$', l)
                for l in active(qsf.splitlines()))

    # ---- PIN_ID ------------------------------------------------------------------------------------
    if a.pin_id:
        if qsf.splitlines().count(PRE_FLOW) != 1:
            die("PIN_ID: the PRE_FLOW_SCRIPT_FILE line for apf/build_id_gen.tcl is not there once")
        qsf = "\n".join(l for l in qsf.splitlines() if l != PRE_FLOW) + "\n"
        mif = os.path.join(root, "apf", "build_id.mif")
        mif0 = read(mif)
        write(mif, PINNED_MIF)
        show(mif, mif0, PINNED_MIF, root)
        notes.append("PIN_ID: no build_id_gen.tcl; apf/build_id.mif fixed")
    write(qsf_p, qsf)
    show(qsf_p, qsf0, qsf, root)

    # ---- OLDPAD -----------------------------------------------------------------------------------------
    sdc_p = os.path.join(root, "core", "core_constraints.sdc")
    if a.oldpad:
        if not a.oldpad_ref:
            die("--oldpad needs --oldpad-ref (aeee6d2's core_constraints.sdc)")
        sdc0 = sdc = read(sdc_p)
        ref = read(a.oldpad_ref)
        if sdc_code(sdc) == sdc_code(ref):
            notes.append("OLDPAD: core_constraints.sdc already has aeee6d2's constraints; nothing to change")
        else:
            new_setup = "-to [get_clocks $clk_sdram] 1.5\n"
            hold_line = "\tset_clock_uncertainty -add -hold -from [get_clocks $clk_sys] -to [get_clocks $clk_sdram] 0.1\n"
            if sdc.count(new_setup) != 1 or sdc.count(hold_line) != 1:
                die("OLDPAD: core_constraints.sdc's fitter block is not commit F's (1.5 ns setup, the clk_sys -> "
                    "clk_sdram hold line)")
            sdc = sdc.replace(new_setup, "-to [get_clocks $clk_sdram] 1.0\n").replace(hold_line, "")
            if sdc_code(sdc) != sdc_code(ref):
                d = "\n".join(difflib.unified_diff(sdc_code(ref), sdc_code(sdc), "aeee6d2", "copy", lineterm=""))
                die("OLDPAD: the edited core_constraints.sdc still differs from aeee6d2's outside comments:\n" + d)
            write(sdc_p, sdc)
            show(sdc_p, sdc0, sdc, root)
            notes.append("OLDPAD: core_constraints.sdc's constraints are aeee6d2's (comments as in the tree)")

    # ---- DIV ---------------------------------------------------------------------------------------------
    pll_p = os.path.join(root, "core", "pll", "pll_core.v")
    if a.div == 19:
        if not daria:
            die("DIV=19 needs a DARIA build (counter 3 is selected by POCKET_DARIA)")
        pll0 = pll = read(pll_p)
        blocks = list(re.finditer(r"`ifdef POCKET_DARIA\n(.*?)`else\n", pll, re.S))
        if len(blocks) != 2:
            die(f"pll_core.v has {len(blocks)} `ifdef POCKET_DARIA branches, expected 2")
        out, pos = [], 0
        for m in blocks:
            body = m.group(1)
            for old, new in DIV19_C3:
                if old == new:
                    continue
                body = body.replace(old, new) if body.count(old) == 1 else body
            out.append(pll[pos:m.start(1)] + body)
            pos = m.end(1)
        pll = "".join(out) + pll[pos:]
        for old, new in DIV19_C3:
            if old != new and pll.count(new) != 1:
                die(f"DIV=19: '{new}' should appear once in pll_core.v after the edit")
        for old, new in DIV19_DISPLAY:
            if pll.count(old) != 1:
                die(f"DIV=19: '{old}' is not in pll_core.v once")
            pll = pll.replace(old, new)
        write(pll_p, pll)
        show(pll_p, pll0, pll, root)
        notes.append("DIV=19: pll_core.v's POCKET_DARIA counter 3 is ip-generate's C3 = 19, with its display strings")

    # ---- what kind of build: from the copy as written -----------------------------------------------------
    final = read(qsf_p).splitlines()
    have = [l for l in DARIA_LINES if final.count(l) == 1]
    if len(have) not in (0, 3) or len(daria_named(final)) != len(have):
        die(f"the copy's qsf has {len(have)} of the 3 DARIA lines and {len(daria_named(final))} lines naming DARIA")
    daria = len(have) == 3
    if a.nodaria and daria:
        die("NODARIA: the copy's qsf still has the DARIA lines")
    sram = read(os.path.join(root, "core", "sram_ctrl.sv"))
    fixb = bool(re.search(r"\bt_(rd|wr)_q\b", sram))
    kind = ("q5" if debug else "daria") if daria else ("builda" if fixb else "base")
    pll = read(pll_p)
    div = a.div if daria else 24
    with open(os.path.join(root, "step7_prep.txt"), "w") as f:
        f.write(f"kind {kind}\ndaria {int(daria)}\nbup_debug {int(debug)}\nfixb {int(fixb)}\ndiv {div}\n"
                f"seed {a.seed if a.seed is not None else '-'}\npin_id {int(a.pin_id)}\noldpad {int(a.oldpad)}\n")
    for n in notes:
        print("note: " + n)
    print(f"build kind: {kind} (DARIA {int(daria)}, BUP_DEBUG {int(debug)}, Fix B {int(fixb)}, clk_arm VCO/{div})")


main()
