#!/usr/bin/env python3
"""+mam changes nothing else: one tb_daria run against a reference run of the
same image (a bench without the +mam block, or one run without +mam=1).

  python3 -I acceptance.py RUN_DIR REF_DIR

Checks:
  * fp.csv byte-identical to REF's (both runs need +fp=1);
  * calls.csv(.gz): the same number of lines, REF's header is the prefix of
    RUN's, and every row's first K fields (K = REF's column count) are
    byte-identical to REF's row. A run without +mam=1 has REF's columns, so
    this is then byte identity.
Also reported, not judged: frames.csv, slack.csv, zero.csv, summary.txt and
pcs.txt(.gz) identical or not. Exit status 0 when both checks pass.
Run directories of games are game-derived: they stay in sim/work.
SPDX-License-Identifier: MIT
"""
import gzip
import hashlib
import os
import sys


def read(path):
    if os.path.exists(path):
        with open(path, 'rb') as f:
            return f.read()
    with gzip.open(path + '.gz', 'rb') as f:
        return f.read()


def main(mine, ref):
    ok = True
    a, b = read(os.path.join(mine, 'fp.csv')), read(os.path.join(ref, 'fp.csv'))
    same = a == b
    ok &= same
    print('fp.csv: %s (%d lines, md5 %s / REF %s)' % ('IDENTICAL' if same else 'DIFFERENT', a.count(b'\n'),
                                                     hashlib.md5(a).hexdigest(), hashlib.md5(b).hexdigest()))
    m = read(os.path.join(mine, 'calls.csv')).decode().split('\n')
    r = read(os.path.join(ref, 'calls.csv')).decode().split('\n')
    k = len(r[0].split(','))
    hdr_ok = m[0].split(',')[:k] == r[0].split(',')
    rows_ok = len(m) == len(r)
    bad = 0
    for x, y in zip(m[1:], r[1:]):
        if ','.join(x.split(',')[:k]) != y:
            bad += 1
    calls_ok = hdr_ok and rows_ok and bad == 0
    ok &= calls_ok
    print('calls.csv: %s (%d rows; REF %d columns, RUN %d; header prefix %s; rows differing in REF\'s columns: %d)'
          % ('IDENTICAL in every column REF has' if calls_ok else 'DIFFERENT', len(r) - 2, k,
             len(m[0].split(',')), 'equal' if hdr_ok else 'DIFFERS', bad))
    for f in ('frames.csv', 'slack.csv', 'zero.csv', 'summary.txt', 'pcs.txt'):
        try:
            same = read(os.path.join(mine, f)) == read(os.path.join(ref, f))
        except FileNotFoundError:
            same = None
        print('%s: %s' % (f, {True: 'identical', False: 'DIFFERENT', None: 'missing'}[same]))
    print('ACCEPTANCE %s' % ('PASS' if ok else 'FAIL'))
    return ok


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(0 if main(sys.argv[1], sys.argv[2]) else 1)
