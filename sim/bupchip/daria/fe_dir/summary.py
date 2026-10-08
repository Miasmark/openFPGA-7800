#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Markdown table of the directed tests over one or more run sets
(fe_dir/run_dir.sh), for the lane report.

  summary.py WORKDIR SET [SET ...]

A SET is <flavour>[:<tag>], e.g. s0 s1 s1:hook s1p; WORKDIR is
sim/work/bupchip/daria/fe_dir. For each test: the scheme, the bins it needs
with the values the first set reached (its event counts), and per set the
verdict with the counted classes of design 9.5 (stage 1) or the reason it
failed.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dircheck  # noqa: E402

SCHEME = {(21, 0): 'DPC+', (21, 1): 'DPC+ r1', (23, 0): 'CDF0', (23, 1): 'CDF1', (23, 2): 'CDFJ',
          (23, 3): 'CDFJ+'}


def short(b, v):
    return '%s %d' % (b, v)


def main():
    work = sys.argv[1]
    sets = sys.argv[2:]
    first = sets[0].split(':')[0]
    tests = sorted(f[:-5] for f in os.listdir(os.path.join(work, first, 'img')) if f.endswith('.meta'))
    print('| Test | Scheme | Events (the bins it needs, first set) | ' + ' | '.join(sets) + ' |')
    print('|---|---|---|' + '---|' * len(sets))
    for t in tests:
        meta = dircheck.parse_meta(os.path.join(work, first, 'img', t + '.meta'))
        cells = []
        evs = None
        for s in sets:
            fl, _, tag = s.partition(':')
            run = os.path.join(work, fl, 'runs', 'fe' + ('_' + tag if tag else ''), t)
            if not os.path.exists(os.path.join(run, 'run.log')):
                cells.append('-')
                continue
            reasons, bads, got, cov, classes = dircheck.check(run, meta)
            if evs is None:
                need = meta['need']
                if len(need) > 16:     # dpc_regs and the fetch tests: summarise the families
                    fams = {}
                    for b, op, n in need:
                        k = re.sub(r'(_[a-z]?\d+)+$', '', b)
                        fams.setdefault(k, []).append((b, cov.get(b.replace('s1:', ''), 0)))
                    evs = ', '.join('%s* %d bins, min %d' % (k, len(v), min(x for _, x in v)) if len(v) > 1
                                    else '%s %d' % v[0] for k, v in fams.items())
                else:
                    evs = ', '.join(short(b, classes.get(b[4:], 0) if b.startswith('cls:') else
                                          cov.get(b.replace('s1:', ''), 0)) for b, op, n in need)
            v = 'PASS' if not reasons else 'FAIL: ' + '; '.join(reasons)
            if classes:
                v += ' (' + ', '.join('%s %d' % kv for kv in sorted(classes.items())) + ')'
            cells.append(v)
        print('| `%s` | %s | %s | %s |' % (t, SCHEME.get(meta['scheme'], meta['scheme']), evs,
                                         ' | '.join(cells)))


if __name__ == '__main__':
    main()
