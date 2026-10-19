#!/usr/bin/env python3
"""The independent MAM model (mymam.py) against the bench, access for access.

  python3 -I mymam_check.py [-v] TRACE|DIR ...

TRACE is a tb_daria +mam +mamtrace file (mamtrace.txt, plain or .gz). A DIR
stands for every mamtrace.txt below it (run_dir.sh's OUTDIR/runs/*/). For
each trace, every access's wait states are recomputed by mymam.py in the
bench's ten configurations (m1t3 ... m1t4_as) and compared with the bench's
own columns; each call's wait sum is compared too. Two mode-2 readings the
bench does not have, m2t3_as and m2t4_as ("sequential" from the address),
are given as model-only totals. -v lists the first differing accesses.
Exit status 1 when any access or call sum differs, or no trace was found.
A game's trace is game-derived: keep it and this script's output in sim/work.
SPDX-License-Identifier: MIT
"""
import glob
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mymam import Cfg, run  # noqa: E402

NAMES = ['m1t3', 'm1t4', 'm2t3', 'm2t4', 'm1t3_na', 'm1t4_na', 'm2t3_na', 'm2t4_na', 'm1t3_as', 'm1t4_as']


def configs():
    cfgs = []
    for i, n in enumerate(NAMES):
        k = {}
        if n.endswith('_na'):
            k['imiss_abort'] = False
        if n.endswith('_as'):
            k['seq_by'] = 'addr'
        cfgs.append(Cfg(n, int(n[1]), int(n[3]), cmpidx=i, **k))
    cfgs.append(Cfg('m2t3_as', 2, 3, seq_by='addr'))
    cfgs.append(Cfg('m2t4_as', 2, 4, seq_by='addr'))
    return cfgs


def check(path, verbose=False):
    cfgs = configs()
    res = run(path, cfgs)
    nb = len(NAMES)
    tot_t = [0] * nb
    tot_m = [0] * len(cfgs)
    eq = [0] * nb
    nd = [0] * nb
    first = []
    for call, (th, mi, est, diffs) in sorted(res.items()):
        for i in range(nb):
            tot_t[i] += th[i]
            eq[i] += th[i] == mi[i]
        for i in range(len(cfgs)):
            tot_m[i] += mi[i]
        for d in diffs:
            nd[d[0]] += 1
            if len(first) < 8:
                first.append((call,) + tuple(d))
    ok = len(res) > 0 and all(e == len(res) for e in eq) and not any(nd)
    print('%s: %d calls, accesses differing %d, calls with equal sums %s, %s' % (
        path, len(res), sum(nd), ' '.join('%s %d' % (n, e) for n, e in zip(NAMES, eq)), 'OK' if ok else 'DIFFER'))
    if verbose or not ok:
        for i, n in enumerate(NAMES):
            print('  %-8s bench %10d  model %10d  diff %+d  accesses differing %d' % (
                n, tot_t[i], tot_m[i], tot_m[i] - tot_t[i], nd[i]))
        for i in range(nb, len(cfgs)):
            print('  %-8s (model only) %10d' % (cfgs[i].name, tot_m[i]))
        for f in first:
            # (call, config index, access number, op, address, S/N, category, model, bench)
            print('  call %d %s access %d %s %s %s %s: model %d bench %d' % (
                f[0], NAMES[f[1]], f[2], f[3], f[4], f[5], f[6], f[7], f[8]))
    return ok


def main(argv):
    verbose = '-v' in argv
    args = [a for a in argv if a != '-v']
    if not args:
        print(__doc__)
        return 2
    paths = []
    for a in args:
        if os.path.isdir(a):
            paths += sorted(glob.glob(os.path.join(a, '**', 'mamtrace.txt'), recursive=True))
            paths += sorted(glob.glob(os.path.join(a, '**', 'mamtrace.txt.gz'), recursive=True))
        else:
            paths.append(a)
    if not paths:
        print('mymam_check.py: no mamtrace.txt found')
        return 1
    bad = sum(0 if check(p, verbose) else 1 for p in paths)
    print('%d traces, %d differing: %s' % (len(paths), bad, 'ALL OK' if bad == 0 else 'DIFFS'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
