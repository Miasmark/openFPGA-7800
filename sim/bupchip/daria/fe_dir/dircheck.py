#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verdict of one directed-test run (fe_dir/run_dir.sh).

  dircheck.py RUN_DIR META [--summary]

PASS needs all of:
  - the run finished ("ran N frames") without a Verilator error;
  - detect2600 classified the image as the test expects;
  - the front-end shadow ran ("FE shadow: <scheme> ...", not "not shadowed");
  - every "<name> <n>, ... bad" group of the FE lines is all 0, and every
    must-be-0 counter the FE lines name (MUST0) is 0;
  - every required coverage bin of META (fe_dir_mon's dir_cov.txt) is met:
    the test exercised what it is meant to exercise ('s1:<bin>' only in
    stage-1 builds, which print "FE bad:"); a 'cls:<class>' requirement is a
    counted class of the stage-1 "FE classes:" line (skipped in stage 0);
  - fe_dir_mon's own comparisons (dirchk_*_bad bins) are 0;
  - the comparisons ran: "FE shadow" counts latches and commits, "FE detail"
    (and in stage 1 "FE counts") read latches compared, all > 0, and a
    stage-1 log has its "FE result" line.
Prints one line: verdict, test, the bad counts, the bins, and the reasons.
"""
import os
import re
import sys

MUST0 = ('obus_exposed', 'over32k', 'wb_drop', 'hold', 'hold_bad', 'seed_race', 'note_race',
         'ret_unasked', 'hidden_last_bad', 'commit_on_hidden', 'det_bad', 'det_lock_a',
         'tick_bad', 'audio_bad', 'amp_lag', 'amp_input_race')


def parse_meta(path):
    m = {'need': [], 'args': '', 'frames': 10}
    for line in open(path):
        k, _, v = line.rstrip('\n').partition(' ')
        if k == 'scheme':
            m['scheme'] = tuple(int(x) for x in v.split())
        elif k == 'frames':
            m['frames'] = int(v)
        elif k == 'args':
            m['args'] = v
        elif k == 'need':
            b, op, n = v.split()
            m['need'].append((b, op, int(n)))
        elif k == 'desc':
            m['desc'] = v
        elif k == 'check':
            lab, a = v.split()
            m.setdefault('checks', {})[int(a)] = lab
    return m


def bad_groups(line):
    """'dout 0, state 0 bad' and the like -> {name: n}."""
    out = {}
    for seg in re.split(r'[;:]', line):
        seg = seg.strip()
        if not seg.endswith(' bad'):
            continue
        seg = seg[:-4]
        for part in seg.split(','):
            mm = re.match(r'^\s*(.*?)\s+(-?\d+)\s*$', part)
            if mm:
                out[mm.group(1).strip()] = int(mm.group(2))
    return out


def check(run, meta):
    reasons = []
    log = open(os.path.join(run, 'run.log'), errors='replace').read() if os.path.exists(
        os.path.join(run, 'run.log')) else ''
    if not re.search(r'^ran \d+ frames', log, re.M):
        reasons.append('run did not finish')
    if re.search(r'%Error|%Fatal|Assertion failed', log):
        reasons.append('simulator error')
    m = re.search(r'detect2600: force_bs (\d+) revision (\d+)', log)
    if not m or (int(m.group(1)), int(m.group(2))) != meta['scheme']:
        reasons.append('detect %s, expected %s' % (m.groups() if m else None, meta['scheme']))
    if not re.search(r'^FE shadow: (?!.*not shadowed)', log, re.M):
        reasons.append('no FE shadow line')
    stage1 = re.search(r'^FE bad:', log, re.M) is not None
    # nothing compared is not a pass (a bench whose checks never start would show 0 everywhere)
    m = re.search(r'^FE shadow: \S+ (\d+) latches, (\d+) commits', log, re.M)
    if m and (int(m.group(1)) == 0 or int(m.group(2)) == 0):
        reasons.append('nothing compared: %s latches, %s commits' % m.groups())
    for pat, req in ((r'^FE detail: (\d+) read latches compared', True),
                     (r'^FE counts: (\d+) read latches compared', stage1)):
        m = re.search(pat, log, re.M)
        if (m and int(m.group(1)) == 0) or (req and not m):
            reasons.append('no read latch compared ("%s" %s)' % (pat[1:10], m.group(1) if m else 'missing'))
    if stage1 and not re.search(r'^FE result: ', log, re.M):
        reasons.append('stage-1 log without its FE result line')
    bads = {}
    classes = {}
    result = None
    for line in log.splitlines():
        if line.startswith(('FE shadow:', 'FE reference:', 'FE detail:')):
            for k, v in bad_groups(line).items():
                bads[k] = bads.get(k, 0) + v
        if line.startswith(('FE shadow:', 'FE bad:')):
            for k in MUST0:
                for mm in re.finditer(r'(?<![\w])%s[ =](\d+)' % re.escape(k), line):
                    if int(mm.group(1)) != 0:
                        bads[k] = bads.get(k, 0) + int(mm.group(1))
        if line.startswith('FE bad:'):         # stage 1: every listed counter must be 0
            for part in line[len('FE bad:'):].split(';')[0].split(','):
                mm = re.match(r'^\s*(\w+)\s+(-?\d+)\s*$', part)
                if mm:
                    bads[mm.group(1)] = int(mm.group(2))
        if line.startswith('FE classes:'):
            for part in line[len('FE classes:'):].split(','):
                mm = re.match(r'^\s*(\w+)\s+(-?\d+)\s*$', part)
                if mm and int(mm.group(2)):
                    classes[mm.group(1)] = int(mm.group(2))
        mm = re.match(r'^FE result: (\w+)', line)
        if mm:
            result = mm.group(1)
    if result is not None and result != 'PASS':
        reasons.append('FE result %s' % result)
    nbad = {k: v for k, v in bads.items() if v}
    if nbad:
        reasons.append('bad: ' + ', '.join('%s %d' % kv for kv in sorted(nbad.items())))
    cov = {}
    cp = os.path.join(run, 'dir_cov.txt')
    if os.path.exists(cp):
        for line in open(cp):
            p = line.split()
            if len(p) == 2:
                cov[p[0]] = int(p[1])
    else:
        reasons.append('no dir_cov.txt')
    got = []
    for k, v in sorted(cov.items()):         # fe_dir_mon's own comparisons (stage 1)
        if k.startswith('dirchk_') and k.endswith('_bad') and v:
            reasons.append('%s %d (fe_dir_mon)' % (k, v))
    if cov.get('dir_selfcheck_err', 0):
        a = (cov.get('dir_res1', 0) << 8 | cov.get('dir_res0', 0)) - 2
        lab = meta.get('checks', {}).get(a, '$%04X' % a)
        reasons.append('6507 self-check failed %d times, last at %s, read $%02X' % (
            cov['dir_selfcheck_err'], lab, cov.get('dir_res2', 0)))
    for b, op, n in meta['need']:
        if b.startswith('cls:'):    # a counted class of the stage-1 shadow ("FE classes:")
            if not stage1:
                continue
            v = classes.get(b[4:], 0)
        else:
            if b.startswith('s1:'):     # a bin that exists only in stage-1 builds
                if not stage1:
                    continue
                b = b[3:]
            if b.endswith('*'):
                v = sum(x for k, x in cov.items() if k.startswith(b[:-1]))
            else:
                v = cov.get(b, 0)
        ok = {'>=': v >= n, '==': v == n, '<=': v <= n, '>': v > n}[op]
        if not ok:
            reasons.append('%s %d, needs %s %d' % (b, v, op, n))
    checked = sum(bads.values()) if bads else 0
    return reasons, bads, got, cov, classes


def main():
    run, metap = sys.argv[1], sys.argv[2]
    meta = parse_meta(metap)
    reasons, bads, got, cov, classes = check(run, meta)
    name = os.path.basename(os.path.normpath(run))
    verdict = 'PASS' if not reasons else 'FAIL'
    nb = len(meta['need'])
    print('%s %-20s bad counts all 0: %s; bins met %d/%d; classes: %s%s' % (
        verdict, name, 'yes' if not any(bads.values()) else 'NO',
        nb - sum(1 for r in reasons if ', needs ' in r), nb,
        ' '.join('%s=%d' % kv for kv in sorted(classes.items())) or '-',
        ('  << ' + '; '.join(reasons)) if reasons else ''))
    sys.exit(0 if verdict == 'PASS' else 1)


if __name__ == '__main__':
    main()
