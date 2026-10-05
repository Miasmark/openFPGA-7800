#!/usr/bin/env python3
"""Summary of one full-build probe (run_full.sh): the device's resources,
the ALMs of the BupChip's blocks, and the timing from full_report.tcl.

Usage: full_summary.py DIR   (DIR holds fpga/output_files and timing.txt)
"""
import os
import re
import sys

d = sys.argv[1]
out = os.path.join(d, "fpga", "output_files")

print(f"build: {d}")
with open(os.path.join(out, "ap_core.fit.summary")) as f:
    for line in f:
        if re.match(r"(Logic utilization|Total registers|Total RAM Blocks|Total DSP Blocks|Fitter Status)", line):
            print("  " + line.strip())

# The entity table: the BupChip, its CPU and the memories DARIA adds.
want = ["|atari7800_pocket:atari|", "|bupchip_pocket:bupchip|", "|bup_cpu:cpu|", "|altsyncram:window|",
        "|bup_asset_cache:cache|", "|bupchip_peripheral:per|", "|bup_capture:capture|", "|bup_asset_wr:writer|",
        "|psram:bup_psram|"]
print("\n# ALMs by entity (needed, with the entity's own in brackets; ALMs placed; registers; M10K)")
with open(os.path.join(out, "ap_core.fit.rpt"), encoding="latin-1") as f:
    rpt = f.read()
sec = rpt[rpt.index("; Fitter Resource Utilization by Entity"):]
hdr = None
for line in sec.splitlines()[1:]:
    if not line.startswith(";"):
        continue
    cols = [c.strip() for c in line.strip("; \n").split(";")]
    if cols[0] == "Compilation Hierarchy Node":
        hdr = cols
        continue
    win = re.fullmatch(r"\|altsyncram:(g_win\[\d\]\.)?window\|", cols[0])
    if hdr is None or len(cols) < len(hdr) or (cols[0] not in want and not win):
        continue
    row = dict(zip(hdr, cols))
    print(f"  {cols[0]:32s} {row['ALMs needed [=A-B+C]']:>18s}  {row['[A] ALMs used in final placement']:>18s}"
          f"  {row.get('Dedicated Logic Registers', ''):>14s}  M10K {row.get('M10Ks', '?')}")
    if cols[0] in want:
        want.remove(cols[0])

print("\n# Timing (full_report.tcl)")
t = os.path.join(d, "timing.txt")
if os.path.exists(t):
    with open(t) as f:
        print("".join("  " + l for l in f))
else:
    print("  timing.txt missing")
