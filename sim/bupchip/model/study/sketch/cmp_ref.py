#!/usr/bin/env python3
"""Compare the sketch's retire trace (tb_cpu.sv +trace=N, cpu.trace) with the
reference's (../../../verif/tb_ref_trace.sv +trace=FILE), instruction by
instruction: PC, encoding, every register the reference has written so far,
and NZCV. Stops at the first difference. From the design study
(docs/BUPCHIP_CORE.md), which measured the sketch register-exact for 85,258
instructions of Rikki & Vikki's boot.

  cmp_ref.py REF.trace[.gz] CPU.trace

SPDX-License-Identifier: MIT
"""
import gzip
import sys

ref = (gzip.open if sys.argv[1].endswith(".gz") else open)(sys.argv[1], "rt")
dut = open(sys.argv[2])
regs = [0] * 15
written = [False] * 15
flags = None
n = 0
for rl, dl in zip(ref, dut):
    rp = rl.split('#')[0].split()
    pc, ir = rp[1], rp[2]
    for t in rp[3:]:
        if t.startswith('r') and '=' in t:
            k, v = t[1:].split('=')
            if int(k) < 15:
                regs[int(k)] = int(v, 16)
                written[int(k)] = True
        elif t.startswith('f='):
            flags = int(t[2:], 16)
    dp = dl.split()
    if dp[1] != pc or dp[2] != ir:
        print('PC/IR mismatch at', n, rl.strip(), '|', dl.strip())
        break
    dregs = [int(x, 16) for x in dp[3:18]]
    bad = [k for k in range(15) if written[k] and dregs[k] != regs[k]]
    df = int(dp[18], 2)
    if bad or (flags is not None and df != flags):
        print('mismatch at', n, rl.strip())
        print('   dut', ' '.join('r%d=%08x' % (k, dregs[k]) for k in bad), 'flags', dp[18], 'ref flags', flags,
              ' '.join('r%d=%08x' % (k, regs[k]) for k in bad))
        break
    n += 1
else:
    print('match for', n, 'instructions')
