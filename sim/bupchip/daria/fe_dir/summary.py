#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Markdown table of the directed tests over one or more run sets
(fe_dir/run_dir.sh), for the lane report.

  summary.py WORKDIR SET [SET ...]

A SET is <flavour>[:<tag>], e.g. s0 s1 s1:hook s1p; WORKDIR is
sim/work/bupchip/daria/fe_dir. For each test: the scheme, the bins it needs
with the values the first set reached (its event counts; a 'cls:<class>'
requirement, a counted class of the stage-1 shadow, with the value of the
first stage-1 set, '-' if no set given is stage 1), and per set the verdict
with the counted classes of design 9.5 (stage 1) or the reason it failed
('skipped' for a tree_bench test in FLAVOR=s0).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dircheck  # noqa: E402

SCHEME = {(21, 0): 'DPC+', (21, 1): 'DPC+ r1', (23, 0): 'CDF0', (23, 1): 'CDF1', (23, 2): 'CDFJ',
          (23, 3): 'CDFJ+'}


def short(b, v):
    return '%s %s' % (b, v)


def is_stage1(run):
    """A stage-1 log has the "FE bad:" line (as dircheck.check decides)."""
    try:
        log = open(os.path.join(run, 'run.log'), errors='replace').read()
    except OSError:
        return False
    return re.search(r'^FE bad:', log, re.M) is not None


def value(b, cov, cls):
    """A need's value: a bin from the first set's coverage, a class from the first stage-1 set's."""
    if b.startswith('cls:'):
        return '-' if cls is None else cls.get(b[4:], 0)
    return cov.get(b.replace('s1:', ''), 0)


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
        cov0 = None            # the first set's coverage bins
        cls1 = None            # the first stage-1 set's counted classes
        for s in sets:
            fl, _, tag = s.partition(':')
            run = os.path.join(work, fl, 'runs', 'fe' + ('_' + tag if tag else ''), t)
            if not os.path.exists(os.path.join(run, 'run.log')):
                vp = os.path.join(run, 'verdict.txt')
                skip = os.path.exists(vp) and open(vp).read().startswith('SKIP')
                cells.append('skipped (tree_bench)' if skip else '-')
                continue
            reasons, bads, got, cov, classes = dircheck.check(run, meta)
            if cov0 is None:
                cov0 = cov
            if cls1 is None and is_stage1(run):
                cls1 = classes
            v = 'PASS' if not reasons else 'FAIL: ' + '; '.join(reasons)
            if classes:
                v += ' (' + ', '.join('%s %d' % kv for kv in sorted(classes.items())) + ')'
            cells.append(v)
        evs = None
        if cov0 is not None:
            need = meta['need']
            if len(need) > 16:     # dpc_regs and the fetch tests: summarise the families
                fams = {}
                clsev = []
                for b, op, n in need:
                    if b.startswith('cls:'):
                        clsev.append(short(b, value(b, cov0, cls1)))
                        continue
                    k = re.sub(r'(_[a-z]?\d+)+$', '', b)
                    fams.setdefault(k, []).append((b, value(b, cov0, cls1)))
                evs = ', '.join(['%s* %d bins, min %d' % (k, len(v), min(x for _, x in v)) if len(v) > 1
                                 else '%s %d' % v[0] for k, v in fams.items()] + clsev)
            else:
                evs = ', '.join(short(b, value(b, cov0, cls1)) for b, op, n in need)
        print('| `%s` | %s | %s | %s |' % (t, SCHEME.get(meta['scheme'], meta['scheme']), evs,
                                         ' | '.join(cells)))


if __name__ == '__main__':
    main()
