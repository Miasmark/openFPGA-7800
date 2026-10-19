#!/usr/bin/env python3
"""Other readings of UM10161 chapter 4, run with the independent model
(mymam.py) on a tb_daria +mam +mamtrace file: how far the totals move when
the manual is read another way.

  python3 -I variants.py TRACE [OUT.csv]

Prints, for each reading and each of the four primary configurations (mode
1 or 2, MAMTIM 3 or 4), the wait-state total over the trace's calls and its
change against the baseline (the bench's reading), as a share of the
baseline's cycles (est_arm7 + waits). OUT.csv, if given, holds one row per
call: call, est_arm7, then the waits of each reading:configuration.
The readings:
  baseline               the bench's reading
  mimic_no_flash         mode 1: a non-sequential fetch of a latched line
                         takes a read's time but does not use the flash
  keep_done_pf_on_data   a completed prefetch survives a flash data read
  no_pf_if_buffered      no prefetch of a line already latched
  br_to_pf_line_into_BT  a branch into the prefetched line puts it in BT
  warm_calls             the latches are kept from one call to the next
  pf_capture_t+1         the next prefetch starts a cycle after a capture
  na                     an instruction miss waits for the prefetch in flight
  as                     "sequential" from the address, not the S/N cycle
  na+as                  both
A game's trace and these figures are game-derived: keep them in sim/work.
SPDX-License-Identifier: MIT
"""
import csv
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mymam import Cfg, run  # noqa: E402

BASE = [('m1t3', 1, 3), ('m1t4', 1, 4), ('m2t3', 2, 3), ('m2t4', 2, 4)]
VARIANTS = {
    'baseline': {},
    'mimic_no_flash': {'mimic_uses_flash': False},
    'keep_done_pf_on_data': {'data_loses_done_pf': False},
    'no_pf_if_buffered': {'pf_skip_if_buffered': True},
    'br_to_pf_line_into_BT': {'nseq_capture_bt': True},
    'warm_calls': {'warm': True},
    'pf_capture_t+1': {'pf_on_capture': 't+1'},
    'na': {'imiss_abort': False},
    'as': {'seq_by': 'addr'},
    'na+as': {'imiss_abort': False, 'seq_by': 'addr'},
}


def main(trace, out=None):
    cfgs, keys, idx = [], [], {}
    for vn, kw in VARIANTS.items():
        for n, mo, M in BASE:
            idx[(vn, n)] = len(cfgs)
            keys.append(vn + ':' + n)
            cfgs.append(Cfg(vn + ':' + n, mo, M, cmpidx=None, **kw))
    res = run(trace, cfgs)
    est = sum(r[2] for r in res.values())
    print('calls %d, est_arm7 %d' % (len(res), est))
    tot = {k: sum(r[1][i] for r in res.values()) for k, i in idx.items()}
    print('%-24s' % 'reading' + ''.join('%26s' % n for n, _, _ in BASE))
    for vn in VARIANTS:
        row = '%-24s' % vn
        for n, _, _ in BASE:
            w, b = tot[(vn, n)], tot[('baseline', n)]
            row += '%14d %+7.2f%%  ' % (w, 100.0 * (w - b) / (est + b) if est + b else 0.0)
        print(row)
    if out:
        with open(out, 'w', newline='') as f:
            wr = csv.writer(f)
            wr.writerow(['call', 'est_arm7'] + keys)
            for call, (th, mi, e, diffs) in sorted(res.items()):
                wr.writerow([call, e] + mi)
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:3]))
