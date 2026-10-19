#!/usr/bin/env python3
"""Re-run mam_model.py on a tb_daria +mamtrace file (plain or .gz) and compare
every access's wait states, per configuration, with the bench's.
  python3 -I mam_check.py mamtrace.txt[.gz] [ROM_SIZE]
The I cycles are recomputed from the retired instruction (mam_model.icycles)
and compared with the trace's too. Prints one line per call and a verdict;
exit status 1 when any call differs.
SPDX-License-Identifier: MIT"""
import gzip
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mam_model as M   # noqa: E402

CFGS = [(1, 3, False, False), (1, 4, False, False), (2, 3, False, False), (2, 4, False, False),
        (1, 3, True, False), (1, 4, True, False), (2, 3, True, False), (2, 4, True, False),
        (1, 3, False, True), (1, 4, False, True)]
NAMES = ['m1t3', 'm1t4', 'm2t3', 'm2t4', 'm1t3_na', 'm1t4_na', 'm2t3_na', 'm2t4_na', 'm1t3_as', 'm1t4_as']


def calls(path):
    op = gzip.open if path.endswith('.gz') else open
    cur = None
    with op(path, 'rt') as f:
        for ln in f:
            if ln.startswith('#'):
                continue
            p = ln.split()
            if p[0] == 'C':
                cur = {'call': int(p[1]), 'frame': int(p[2]), 'cfn': p[3], 'ev': []}
            elif p[0] == 'R':
                cur['ev'].append(('R', int(p[1], 16), int(p[2], 16), p[3] == 'T', int(p[4])))
            elif p[0] == 'A':
                cur['ev'].append(('A', p[2], int(p[3], 16), int(p[4]), p[5] == 'S', p[7], int(p[8]),
                                  [int(x) for x in p[9:]]))
            elif p[0] == 'E':
                cur['end'] = p
                yield cur
                cur = None


def check(path, rom_size=32768):
    bad_total = 0
    n = 0
    for c in calls(path):
        ms = [M.Mam(*cfg, rom_size=rom_size) for cfg in CFGS]
        bad = 0
        badi = 0
        sums = [0] * len(CFGS)
        nacc = 0
        nicyc = 0
        first_bad = None
        for e in c['ev']:
            if e[0] == 'R':
                ic = M.icycles(e[2], e[3])
                if ic != e[4]:
                    badi += 1
                nicyc += ic
                for m in ms:
                    m.icycles(ic)
                continue
            nacc += 1
            for k, m in enumerate(ms):
                w, cat = m.access(e[1], e[2], e[3], 1 if e[4] else 0)
                sums[k] += w
                if w != e[7][k] or (cat or '-') != e[5]:
                    bad += 1
                    if first_bad is None:
                        first_bad = (NAMES[k], e, w, cat)
        end = c['end']
        est = int(end[7])
        tb_sums = [int(x) for x in end[8:]]
        ok = bad == 0 and badi == 0 and sums == tb_sums and est == nacc + nicyc - 1
        bad_total += 0 if ok else 1
        n += 1
        print('call %d cfn %s acc %d icyc %d est %d chk %d mismatches %d icyc_mism %d sums %s %s' % (
            c['call'], c['cfn'], nacc, nicyc, est, est - (nacc + nicyc - 1), bad, badi,
            'equal' if sums == tb_sums else 'DIFFER %s vs %s' % (sums, tb_sums), 'OK' if ok else 'FAIL'))
        if first_bad:
            print('  first mismatch', first_bad)
    print('%d calls, %d failing' % (n, bad_total))
    return bad_total


if __name__ == '__main__':
    sys.exit(1 if check(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 32768) else 0)
