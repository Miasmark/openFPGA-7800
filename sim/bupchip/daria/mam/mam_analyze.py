#!/usr/bin/env python3
"""One image on a real Harmony (LPC2103 + MAM), as modelled: the analysis of a
tb_daria +mam=1 run (docs/HARMONY_MODEL.md).

  python3 -I mam_analyze.py RUN_DIR [--mhz F] [--cfg CFG] [--daria CSV]
                            [--daria-col COL] [--daria-mhz F] [--trace TRACE]
                            [--out FILE]

RUN_DIR      a run_daria.sh run with +mam=1 (calls.csv.gz, slack.csv, zero.csv,
             frames.csv, summary.txt, mam_summary.txt)
--mhz F      the Harmony's ARM clock in MHz, the game's setting in force
             (docs/HARMONY_MODEL.md; default 70)
--cfg CFG    the MAM configuration in force (default m2t4: mode 2, MAMTIM 4)
--daria CSV  DARIA's clocks per call, matched by call number: a calls.csv of
             a tb_frames run (column arm_cyc) or daria.csv of a shadow run
             (--daria-col daria_clk); --daria-mhz its clock (default VCO/18,
             38.181818 MHz, DARIA's divider)
--trace T    the run's +mamtrace file: re-checked with mam_check.py and used
             for the reference model's sensitivity runs
--out FILE   also write the report there
Upstream (MiSTer's core) is the run itself: arm_cyc at 71.59 MHz, and the
time it holds the 6507, stall_sys at 14.318 MHz.

Budgets are dynamic_tables.py's safe budgets (the held time plus the slack to
the clock INTIM first reads 0). Section 3 applies the reference rule: where
the chip meets a call that MiSTer misses, DARIA must be on time; where the
chip misses a call, matching MiSTer's miss is fine.
Everything this prints derives from the game: keep it in sim/work.
SPDX-License-Identifier: MIT
"""
import argparse
import csv
import gzip
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.dirname(HERE))
import mam_model as M      # noqa: E402
import mam_check           # noqa: E402
import dynamic_tables as DT  # noqa: E402

F_UP = 5 * 14318181.0            # upstream clk_arm
F_SYS = 14318181.0               # 6507-side clk_sys
LINE_SYS = 76 * 12               # one scanline in clk_sys
PRIM = ['m1t3', 'm1t4', 'm2t3', 'm2t4']
ALL = PRIM + ['m1t3_na', 'm1t4_na', 'm2t3_na', 'm2t4_na', 'm1t3_as', 'm1t4_as']
KCAT = ['br', 'ns', 'sx', 'si', 'dr', 'ot']


def label(c):
    base = 'mode %s, MAMTIM %s' % (c[1], c[3])
    if c.endswith('_na'):
        return base + ', no abort'
    if c.endswith('_as'):
        return base + ', S/N by address'
    return base


def pct(v, p):
    s = sorted(v)
    if not s:
        return float('nan')
    k = max(0, min(len(s) - 1, int(math.ceil(p / 100.0 * len(s))) - 1))
    return s[k]


def fmt_dist(v, f='%.0f'):
    d = [min(v), pct(v, 1), pct(v, 10), pct(v, 50), pct(v, 90), pct(v, 99), max(v), sum(v) / len(v)]
    return ' '.join(f % x for x in d)


def read_daria(path, col):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rt') as f:
        return {int(r['call']): r for r in csv.DictReader(f) if r.get(col, '') not in ('', None)}


def read_summary(path):
    summ = {}
    if not os.path.exists(path):
        return summ
    for ln in open(path):
        q = ln.split()
        if not q:
            continue
        if q[0] == 'cfg':
            summ[q[1]] = {q[i]: int(q[i + 1]) for i in range(2, len(q) - 1, 2)}
        elif q[0] == 'flash_accesses':
            summ['_n'] = {q[i]: int(q[i + 1]) for i in range(1, len(q) - 1, 2)}
    return summ


def analyze(a):
    R = DT.Run(a.run, {})
    rows = R.rows
    n = len(rows)
    F_H = a.mhz * 1e6
    cfg = a.cfg
    L = []
    w = L.append
    instr = sum(r['instr'] for r in rows)
    est = sum(r['est_arm7'] for r in rows)
    up_cyc = sum(r['arm_cyc'] for r in rows)
    t_up = up_cyc / F_UP
    tot = {c: sum(r['mam_' + c] for r in rows) for c in ALL}
    bad_chk = sum(1 for r in rows if r['mam_chk'] != 0)
    cfn = {}
    for r in rows:
        cfn[r['cfn']] = cfn.get(r['cfn'], 0) + 1
    da = None
    if a.daria:
        dd = read_daria(a.daria, a.daria_col)
        da = {}
        mism = 0
        for r in rows:
            d = dd.get(r['call'])
            if d is None:
                continue
            if 'thumb' in d and 'arm' in d and int(d['thumb']) + int(d['arm']) != r['instr']:
                mism += 1
            da[r['call']] = int(d[a.daria_col]) / (a.daria_mhz * 1e6)
    summ = read_summary(os.path.join(a.run, 'mam_summary.txt'))

    w('%s on a real Harmony (LPC2103 + MAM, as modelled): %.0f MHz, %s in force' % (R.name, a.mhz, label(cfg)))
    w('=' * 88)
    w('')
    w('The bench ran the image with +mam=1: every bus access the ARM core made in each call')
    w('went through a model of the LPC2103\'s Memory Accelerator Module (UM10161 chapter 4).')
    w('Harmony cycles = est_arm7 (ARM7TDMI at zero wait) + the wait states the MAM adds.')
    w('The model has never been checked on silicon (docs/HARMONY_MODEL.md, "Limits").')
    w('')
    w('Checks behind the numbers')
    w('  calls %d; instructions %d; est_arm7 %d cycles' % (n, instr, est))
    w('  calls where the model\'s zero-wait timeline (accesses + I cycles - 1) differs from')
    w('  est_arm7 (mam_chk not 0): %d' % bad_chk)
    w('  CALLFUNCTION values: %s' % ', '.join('$%s: %d calls' % (k.upper(), v) for k, v in sorted(cfn.items())))
    if da is not None:
        w('  DARIA (%s, column %s, %.6f MHz): %d of %d calls matched; instruction counts differing: %d'
          % (os.path.basename(a.daria), a.daria_col, a.daria_mhz, len(da), n, mism))
    if a.trace:
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            bad = mam_check.check(a.trace)
        w('  mam_check.py on the trace (%s): %s' % (os.path.basename(a.trace), buf.getvalue().strip().split('\n')[-1]))
    w('')
    # ---- 1. totals
    w('1. Totals over all %d calls' % n)
    w('')
    w('  %-42s %12s %12s %8s %6s' % ('', 'cycles', 'waits', 'seconds', 'CPI'))
    w('  %-42s %12d %12s %8.4f %6.3f' % ('ARM7TDMI zero-wait (est_arm7)', est, '-', est / F_H, est / instr))
    for c in ALL:
        w('  %-42s %12d %12d %8.4f %6.3f' % ('Harmony, ' + label(c) + (' *' if c == cfg else ''), tot[c],
                                            tot[c] - est, tot[c] / F_H, tot[c] / instr))
    w('  %-42s %12d %12s %8.4f %6.3f' % ('upstream (MiSTer), 71.59 MHz', up_cyc, '-', t_up, up_cyc / instr))
    if da is not None:
        t_d = sum(da.values())
        w('  %-42s %12s %12s %8.4f %6s' % ('DARIA, %.3f MHz (matched calls)' % a.daria_mhz, '-', '-', t_d, '-'))
    w('  (* the configuration in force; seconds at %.0f MHz for the Harmony rows)' % a.mhz)
    w('')
    # ---- 2. per call
    w('2. Per call: core time over the modelled Harmony\'s (%s at %.0f MHz)' % (label(cfg), a.mhz))
    w('')
    w('  Columns: min, 1st percentile, 10th, median, 90th, 99th, max, mean. Above 1: the core')
    w('  is slower than the chip on that call. Each core\'s ARM clocks from the call\'s start')
    w('  to its return over its clock.')
    h_us = {r['call']: r['mam_' + cfg] / F_H * 1e6 for r in rows}
    ru = [r['arm_cyc'] / F_UP * 1e6 / h_us[r['call']] for r in rows]
    w('    %-26s %s' % ('upstream / Harmony', fmt_dist(ru, '%6.3f')))
    if da is not None and da:
        rd = [da[c] * 1e6 / h_us[c] for c in sorted(da)]
        w('    %-26s %s' % ('DARIA / Harmony', fmt_dist(rd, '%6.3f')))
        w('    calls where DARIA is slower than the chip: %d of %d' % (sum(1 for x in rd if x > 1), len(rd)))
    w('    calls where upstream is slower than the chip: %d of %d' % (sum(1 for x in ru if x > 1), n))
    w('')
    # ---- 3. budgets and the reference rule
    bud = R.budgeted
    w('3. Budgets and the reference rule (%d calls with a safe budget)' % len(bud))
    w('')
    w('  Share = time / safe budget. The chip\'s time is mam_<cfg> at %.0f MHz; upstream\'s is the' % a.mhz)
    w('  time it holds the 6507 (stall_sys). Late: share above 100%.')
    w('')
    w('  %-42s %10s %22s' % ('', 'late calls', 'worst share (call, frame)'))

    def share_line(name, f):
        if not bud:
            w('  %-42s %10s %22s' % (name, '-', '-'))
            return
        sh = [(f(r) / r['safe'], r) for r in bud]
        worst = max(sh, key=lambda x: x[0])
        w('  %-42s %10d %13.1f%% (%d, %d)' % (name, sum(1 for s, _ in sh if s > 1), 100 * worst[0],
                                               worst[1]['call'], worst[1]['frame']))
    share_line('ARM7TDMI zero-wait, %.0f MHz' % a.mhz, lambda r: r['est_arm7'] / F_H * F_SYS)
    for c in ALL:
        share_line('Harmony, ' + label(c) + (' *' if c == cfg else ''), lambda r, c=c: r['mam_' + c] / F_H * F_SYS)
    share_line('upstream (MiSTer), held time', lambda r: r['stall_sys'])
    chip_late = [r for r in bud if r['mam_' + cfg] / F_H * F_SYS > r['safe']]
    up_late = [r for r in bud if r['stall_sys'] > r['safe']]
    chip_late_ids = set(r['call'] for r in chip_late)
    meets_up_misses = [r for r in up_late if r['call'] not in chip_late_ids]
    w('')
    w('  The reference rule, at the configuration in force:')
    w('    calls the chip meets and MiSTer misses (DARIA must be on time): %d%s' % (
        len(meets_up_misses), ': ' + ' '.join(str(r['call']) for r in meets_up_misses[:40]) if meets_up_misses else ''))
    w('    calls the chip misses (matching MiSTer\'s miss is fine): %d%s' % (
        len(chip_late), ': ' + ' '.join(str(r['call']) for r in chip_late[:40]) if chip_late else ''))
    w('')
    # ---- 4. waits by category
    w('4. Where the wait cycles come from (all calls)')
    w('')
    if '_n' in summ:
        nn = summ['_n']
        w('  Flash accesses: %s' % ', '.join('%s %d' % (k, nn[k]) for k in KCAT))
    w('  br  non-sequential fetch of a branch target (taken branches, and each call\'s entry)')
    w('  ns  N-cycle fetch at the address right after the previous fetch: the fetch after a')
    w('      store, and a taken branch to that address; only mode 1 charges it')
    w('  sx  sequential fetch into a new 16-byte line (waits only while the prefetch is not done)')
    w('  si  sequential fetch inside the current line (never waits)')
    w('  dr  data read from flash (literal pools, ROM tables)')
    w('  ot  the return into the driver (one per call)')
    w('')
    w('  %-34s %10s %s' % ('', 'waits', ' '.join('%15s' % k for k in KCAT)))
    for c in ALL:
        if c not in summ:
            continue
        s = summ[c]
        w('  %-34s %10d %s' % (label(c), s['waits'], ' '.join(
            '%9d %4.1f%%' % (s[k], 100.0 * s[k] / s['waits'] if s['waits'] else 0) for k in KCAT)))
    w('')
    # ---- 5. IRQ ($FE)
    fe = [r for r in rows if r['cfn'].lower() == 'fe']
    w('5. Calls made with $FE ("call with IRQ driven audio")')
    w('')
    lines_cyc = LINE_SYS / F_SYS * F_H
    w('  %d of %d calls wrote $FE to CALLFUNCTION. A scanline (76 6507 cycles) is %.1f ARM' % (len(fe), n, lines_cyc))
    w('  cycles at %.0f MHz. The model leaves the timer interrupt out. A bound: each scanline a' % a.mhz)
    w('  call spans costs the interrupt (130-155 ARM cycles, Stella\'s figure) plus the MAM')
    w('  refill after it (one or two flash reads of T-1 waits), so the call grows by 1/(1 - c/%.0f).' % lines_cyc)

    def irq_total(sel, c, isr, refill):
        T = int(c[3])
        per = isr + refill * (T - 1)
        return sum(r['mam_' + c] / (1 - per / lines_cyc) for r in sel), per
    sel = fe if fe else []
    for c in PRIM:
        if not sel:
            break
        base = sum(r['mam_' + c] for r in sel)
        lo, plo = irq_total(sel, c, 130, 1)
        hi, phi = irq_total(sel, c, 155, 2)
        w('    %s: c = %d .. %d cycles per scanline: the $FE calls +%.1f%% .. +%.1f%%'
          % (label(c), plo, phi, 100 * (lo / base - 1), 100 * (hi / base - 1)))
    if not sel:
        w('  No call used $FE, so no timer interrupt would run during the calls on a Harmony.')
    w('')
    # ---- 6. assumptions and sensitivity
    w('6. Readings of the manual (whole run, from the bench\'s extra configurations)')
    w('')
    for x, y, what in (('m1t3', 'm1t3_na', 'an instruction miss waits for the prefetch in flight, m1t3'),
                       ('m1t4', 'm1t4_na', '... m1t4'), ('m2t3', 'm2t3_na', '... m2t3'),
                       ('m2t4', 'm2t4_na', '... m2t4'),
                       ('m1t3', 'm1t3_as', 'mode 1 "sequential" by address, not S/N, m1t3'),
                       ('m1t4', 'm1t4_as', '... m1t4')):
        w('    %-62s %8.4f s -> %.4f s (%+.1f%%)' % (what, tot[x] / F_H, tot[y] / F_H, 100 * (tot[y] / tot[x] - 1)))
    if a.trace:
        w('')
        w('  On the trace, with the reference model (mam_model.py):')
        for line in sensitivity(a.trace):
            w('    ' + line)
    w('')
    w('  More readings: variants.py on the trace (the independent model, mymam.py).')
    return L


def sensitivity(trace):
    cfgs = [(1, 3), (1, 4), (2, 3), (2, 4)]
    calls = list(mam_check.calls(trace))
    out = []
    base = {}
    var = {'keep': {}, 'warm': {}}
    est = sum(int(c['end'][7]) for c in calls)
    for cfg in cfgs:
        for kind in ('base', 'keep', 'warm'):
            m = M.Mam(cfg[0], cfg[1], keep_done_pf=(kind == 'keep'))
            tw = 0
            for c in calls:
                if kind == 'warm':
                    m.warm_restart()
                else:
                    m.reset()
                for e in c['ev']:
                    if e[0] == 'R':
                        m.icycles(M.icycles(e[2], e[3]))
                    else:
                        tw += m.access(e[1], e[2], e[3], 1 if e[4] else 0)[0]
            if kind == 'base':
                base[cfg] = tw
            else:
                var[kind][cfg] = tw
    out.append('%d calls, est_arm7 %d cycles' % (len(calls), est))
    for cfg in cfgs:
        b = est + base[cfg]
        out.append('mode %d T%d: %d cycles; a completed prefetch survives a data read: %+.2f%%; '
                   'latches warm from the previous call: %+.2f%%' % (
                       cfg[0], cfg[1], b, 100.0 * (var['keep'][cfg] - base[cfg]) / b,
                       100.0 * (var['warm'][cfg] - base[cfg]) / b))
    return out


def main(argv):
    p = argparse.ArgumentParser(description='Analyse a tb_daria +mam=1 run (docs/HARMONY_MODEL.md).')
    p.add_argument('run')
    p.add_argument('--mhz', type=float, default=70.0)
    p.add_argument('--cfg', default='m2t4', choices=ALL)
    p.add_argument('--daria')
    p.add_argument('--daria-col', default='arm_cyc')
    p.add_argument('--daria-mhz', type=float, default=38.181818)
    p.add_argument('--trace')
    p.add_argument('--out')
    a = p.parse_args(argv)
    L = analyze(a)
    text = '\n'.join(L) + '\n'
    if a.out:
        with open(a.out, 'w') as f:
            f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
