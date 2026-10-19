#!/usr/bin/env python3
"""Judge the +mam directed tests: per test, the per-iteration wait states
(difference between the N2 and N1 images, divided by N2 - N1) against the
hand-worked values in dirtests.py, the absolute totals where given, the
categories, mam_chk = 0, the cfn column, every call of a run equal, and the
Python reference model (mam_check.py) on each run's trace.
  python3 -I dircheck.py OUTDIR
OUTDIR is run_dir.sh's: OUTDIR/runs/<test>_n<N>/ holds each run's calls.csv
and mamtrace.txt. Exit status 1 when a test fails.
SPDX-License-Identifier: MIT"""
import csv
import io
import os
import sys
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dirtests as T     # noqa: E402
import mam_check         # noqa: E402

PRIM = T.NAMES[:4]


def calls(d, name, n):
    with open(os.path.join(d, 'runs', '%s_n%d' % (name, n), 'calls.csv')) as f:
        return list(csv.DictReader(f))


def main(d):
    fails = 0
    lines = []
    for name, (_, _, per_it, cfn) in T.TESTS.items():
        res = {}
        ok = True
        notes = []
        for n in (T.N1, T.N2):
            rows = calls(d, name, n)
            if len(rows) < 2:
                ok = False
                notes.append('only %d calls at N=%d' % (len(rows), n))
                continue
            keys = ['mam_' + c for c in T.NAMES] + ['est_arm7', 'mam_chk', 'cfn'] + \
                ['mw_%s_%s' % (c, k) for c in PRIM for k in ('br', 'ns', 'sx', 'si', 'dr', 'ot')]
            first = {k: rows[0][k] for k in keys}
            for r in rows[1:]:
                if {k: r[k] for k in keys} != first:
                    ok = False
                    notes.append('calls differ at N=%d' % n)
                    break
            if int(first['mam_chk']) != 0:
                ok = False
                notes.append('mam_chk %s' % first['mam_chk'])
            if int(first['cfn'], 16) != cfn:
                ok = False
                notes.append('cfn %s' % first['cfn'])
            res[n] = first
            buf = io.StringIO()
            with redirect_stdout(buf):
                bad = mam_check.check(os.path.join(d, 'runs', '%s_n%d' % (name, n), 'mamtrace.txt'))
            if bad:
                ok = False
                notes.append('reference model differs at N=%d' % n)
        if len(res) == 2:
            dn = T.N2 - T.N1
            got = []
            for c in T.NAMES:
                w2 = int(res[T.N2]['mam_' + c]) - int(res[T.N2]['est_arm7'])
                w1 = int(res[T.N1]['mam_' + c]) - int(res[T.N1]['est_arm7'])
                got.append((w2 - w1) / dn)
            if got != per_it:
                ok = False
                notes.append('per-iteration got %s' % got)
            for k, exp in T.CATS.get(name, {}).items():
                g = [(int(res[T.N2]['mw_%s_%s' % (c, k)]) - int(res[T.N1]['mw_%s_%s' % (c, k)])) / dn for c in PRIM]
                if g != exp:
                    ok = False
                    notes.append('category %s got %s expected %s' % (k, g, exp))
            for (tn, n), exp in T.ABS.items():
                if tn == name:
                    g = [int(res[n]['mam_' + c]) - int(res[n]['est_arm7']) for c in T.NAMES]
                    if g != exp:
                        ok = False
                        notes.append('absolute N=%d got %s expected %s' % (n, g, exp))
                    else:
                        notes.append('absolute N=%d %s ok' % (n, g))
        fails += 0 if ok else 1
        lines.append('%-3s %s per-iteration %s (cfn %02X, est N1 %s N2 %s) %s' % (
            name, 'PASS' if ok else 'FAIL', per_it, cfn, res.get(T.N1, {}).get('est_arm7'),
            res.get(T.N2, {}).get('est_arm7'), '; '.join(notes)))
    print('configurations: ' + ' '.join(T.NAMES))
    print('\n'.join(lines))
    print('%d tests, %d failing' % (len(T.TESTS), fails))
    return fails


if __name__ == '__main__':
    sys.exit(1 if main(sys.argv[1]) else 0)
