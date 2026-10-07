#!/usr/bin/env python3
"""tb_fe_audio_mut.py: mutation test of tb_fe_audio (lane B; docs/daria_fe/lanes/B_audio.md).

Each mutant below is a plausible bug in src/fpga/core/bupchip/daria_fe_audio.sv. A
copy of the RTL is written with every mutant selectable at run time: each mutated
expression becomes ((tb_mut == N) ? (mutant) : (original)), and tb_mut comes from
+mut=N (0: the original). The copy and tb_fe_audio are built once with
run_unit.sh's Verilator options, the original is run first (it must pass), then
each mutant; a mutant is caught when the bench fails.

  sim/bupchip/daria/fe_unit/tb_fe_audio_mut.py [+plusarg ...]      e.g. +scale=50 +seed=3
  POISON=1 ...   builds with -DDARIA_RAM_POISON;  ONLY=3,7 runs those mutants only

Work goes to $WORK/mut_audio (WORK as run_unit.sh). Exits 1 if a mutant survives.
SPDX-License-Identifier: MIT
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
WORK = os.environ.get('WORK', os.path.join(ROOT, 'sim', 'work', 'bupchip', 'daria', 'fe_unit'))
MW = os.path.join(WORK, 'mut_audio')
VERILATOR = os.environ.get('VERILATOR', '/opt/verilator-5.040/bin/verilator')
RTL = os.path.join(ROOT, 'src', 'fpga', 'core', 'bupchip', 'daria_fe_audio.sv')

# (name, [(prefix, original, mutant), ...]): the search key is prefix + original and
# must occur exactly once in the text as it stands (earlier mutants already applied).
MUTANTS = [
    ('tick: > for >=',                     [('', 'accum >= TICK_TH', 'accum > TICK_TH')]),
    ('accum: wrong wrap step',             [('', '(tick ? TICK_WRAP : TICK_STEP)', "(tick ? TICK_WRAP + 24'd1 : TICK_STEP)")]),
    ('merge does not beat a tick',         [('', '{32{tick_eff & !take_eff}} & freq[v]', '{32{tick_eff}} & freq[v]')]),
    ('no deferral in mwin',                [('tick_eff = ', '(tick & !mwin) | late', 'tick | late')]),
    ('late add inside mwin',               [('late     = ', 'tdef & !mwin', 'tdef')]),
    ('tdef never cleared',                 [('tdef <= ', 'tick & mwin', 'tick | tdef')]),
    ('NOTE voice 3 not frequency2',        [('', "(nv == 2'd3) ? 2'd2 : nv", 'nv')]),
    ('payload: freq1 for freq0',           [('assign capv[3] = ', 'freq[0]', 'freq[1]')]),
    ('rotation feeds ring[1]',             [('cp_rot}}           & ', 'ring[0]', 'ring[1]')]),
    ('take compares ring[1]',              [('', '{stb_q != ring[0], take[2:1]}', '{stb_q != ring[1], take[2:1]}')]),
    ('take shifts the wrong way',          [('', '{stb_q != ring[0], take[2:1]}', '{take[1:0], stb_q != ring[0]}')]),
    ('a tick at dispatch is lost',         [('', "dispatch ? tick : (fam != 2'd0)", "dispatch ? 1'b0 : (fam != 2'd0)")]),
    ('refresh pending with family 0',      [('', "dispatch ? tick : (fam != 2'd0)", "dispatch ? tick : 1'b1")]),
    ('NCAP clears a same-edge strobe',     [('np <= ', 'note_stb', "1'b0")]),
    ('refresh beats NOTE',                 [('assign dispatch = ', 'st[S_IDLE] & !(np & f_dpc) & rp', 'st[S_IDLE] & rp')]),
    ('NOTE in any family',                 [('', '(st[S_IDLE] & np & f_dpc)', '(st[S_IDLE] & np)')]),
    ('voice runs to 3',                    [('v_inc    = ', "st[S_SMCAP] & !dig_smp & (voice != 2'd2)", "st[S_SMCAP] & !dig_smp & (voice != 2'd3)")]),
    ('sum not cleared at dispatch',        [('ssum <= ', "dispatch ? 8'h00 : ssum + byte_d", 'ssum + byte_d')]),
    ('size shift word[12:8]',              [('', 'crb_q[11:7]', 'crb_q[12:8]')]),
    ('shift not reset at dispatch',        [('else if (', 'dispatch | v_inc | (pc_wave & sz_zero) | st[S_SZCAP]', 'v_inc | (pc_wave & sz_zero) | st[S_SZCAP]')]),
    ('window from $4000_1000',             [('', "(crb_q[14:11] != 4'd0)", "(crb_q[14:12] != 3'd0)")]),
    ('window ignores ram_size',            [('', "(ram32 | (crb_q[14:13] == 2'd0))", "1'b1")]),
    ('window keyed on jplus_s (design 5.3)', [('woff <= ', "({15{rev3 & w_win}} & w_off) | ({15{!rev3}} & {3'b0, w_off[11:0]})",
                                             "({15{jplus_s & w_win}} & w_off) | ({15{!jplus_s}} & {3'b0, w_off[11:0]})")]),
    ('12-bit offset not truncated',        [('({15{!rev3}} & ', "{3'b0, w_off[11:0]}", 'w_off')]),
    ('digital shifts swapped',             [('rc0_sh = ', "jplus_s ? {13'd0, rc[0][31:13]} : {21'd0, rc[0][31:21]}",
                                             "jplus_s ? {21'd0, rc[0][31:21]} : {13'd0, rc[0][31:13]}")]),
    ('digital nibble bit 13',              [('dig_low  <= ', 'jplus_s ? rc[0][12] : rc[0][20]', 'jplus_s ? rc[0][13] : rc[0][20]')]),
    ('RAM window ignores ram_size',        [('', "(ram32 | (dig_addr[14:13] == 2'd0))", "1'b1")]),
    ('ROM route <= rom_size',              [('rom_lt  = ', 'dig_addr < rom_size', 'dig_addr <= rom_size')]),
    ('RAM route before ROM',               [('dr_rom  = ', 'st[S_DROUTE] & rom_lt', 'st[S_DROUTE] & rom_lt & !in_ram')]),
    ('digital nibbles swapped',            [('', 'dig_low ? dig_b[3:0] : dig_b[7:4]', 'dig_low ? dig_b[7:4] : dig_b[3:0]')]),
    ('amplitude without the last byte',    [('({8{am_sum}}          & ', '(ssum + byte_d)', 'ssum')]),
    ('amp_nx ignores cart_reset',          [('assign amp_nx = ', "cart_reset ? 8'h00 : (amp_we ? amp_d : amplitude)", '(amp_we ? amp_d : amplitude)')]),
    ('NOTE table at $1800',                [('', "(15'h1C00 + {5'd0, nval, 2'b00})", "(15'h1800 + {5'd0, nval, 2'b00})")]),
    ('pointer base keyed on rev 1',        [('', "(rev == 2'd0) ? 15'h07F0 : 15'h01B0", "(rev == 2'd1) ? 15'h07F0 : 15'h01B0")]),
    ('pointer base $7F0 outside CDF (design 5.5)', [('', "15'h07F4", "15'h07F0")]),
    ('DPC+ index idx[5:1]',                [('', "{10'd0, idx[4:0]}", "{10'd0, idx[5:1]}")]),
    ('CDFJ+ mask ignores ram_size',        [('rmask = ', "ram32 ? 15'h7FFF : 15'h1FFF", "15'h7FFF")]),
    ('13-bit sample offset',               [('', "{3'b0, sos[11:0]}", "{2'b0, sos[12:0]}")]),
    ('pause does not mask bytes',          [('byte_d = ', "pause ? 8'hFF : lane_b", 'lane_b')]),
    ('lane loads in a pause',              [('else if (', 'aud_take & !pause', 'aud_take')]),
    ('local sample at R+3',                [('rom_done  = ', '(lcnt[3] & busy_l) | rdone_q', '(lcnt[2] & busy_l) | rdone_q')]),
    ('local read not retried',             [('aud_a_req = ', '(lcnt[0] | lcnt[1]) & !a_done', 'lcnt[0] & !a_done')]),
    ('local read address [15:3]',          [('aud_a_a   = ', 'dig_addr[14:2]', 'dig_addr[15:3]')]),
    ('local byte lane 0 from fea_q[15:8]', [("(dig_addr[1:0] == 2'd0)}} & ", 'fea_q[7:0]', 'fea_q[15:8]')]),
    ('ack after one flop',                 [('ack_hit = ', 'busy_r & (ack_s2 == req_q)', 'busy_r & (ack_s1 == req_q)')]),
    ('rom_ready ignores busy_r',           [('rom_ready = ', '!(busy_l | busy_r)', '!busy_l')]),
    ('smp_addr not held',                  [('smp_addr  = ', 'saddr_q', 'dig_addr[18:0]')]),
    ('apply loads counters into freq',     [('& ', 'ring[3+v]', 'ring[v]')]),
    ('hook compares the live counter',     [('', '(hk_c != ring[v])', '(hk_c != counter[v])')]),
    ('DPC+ next voice through PISS',       [('st_n[S_PISS]   = ', '((dispatch | v_inc) & !f_dpc)', '((dispatch & !f_dpc) | v_inc)')]),
    ('size read when asz is 0',            [('', '(pc_wave & !sz_zero)', '(pc_wave & sz_zero)')]),
    ('RISS ignores rom_ready',             [('st_n[S_RISS]   = ', 'dr_rom | (st[S_RISS] & !rom_ready)', 'dr_rom'),
                                            ('st_n[S_RWAIT]  = ', '(st[S_RISS] & rom_ready)', 'st[S_RISS]')]),
    ('ev_size_hi from bit 16 only',        [('', "(sz_a[16:15] != 2'd0)", 'sz_a[16]')]),
    ('ring does not shift (ring[v])',      [('', 'cp_cap ? capv[v] : ring[v + 1]', 'cp_cap ? capv[v] : ring[v]')]),
    ('ring ignores cp_shin',               [('ring_en = ', 'cp_cap | cp_rot | cp_shin', 'cp_cap | cp_rot')]),
    ('payload includes a tick at L',       [('assign capv[0] = ', 'counter[0]', "counter[0] + (tick ? freq[0] : 32'd0)")]),
    ('rc includes a tick at dispatch',     [('rc[v] <= ', 'counter[v]', "counter[v] + (tick ? freq[v] : 32'd0)")]),
    ('dig_smp set on the ROM route',       [('else if (', 'dispatch | dr_ram', 'dispatch | dr_ram | dr_rom')]),
    ('take shifts six times',              [('else if (', 'cp_shin & cp_cmp', 'cp_shin')]),
    ('out-of-range keeps amplitude',       [('amp_we = ', 'am_dig | am_sum | dr_none | am_rom', 'am_dig | am_sum | am_rom')]),
    ('NOTE loads stb_q',                   [('({32{ncap}}                          & ', 'crb_q', 'stb_q')]),
    ('merge with family 1 too',            [('own_apply = ', 'cp_apply & f_mrg', 'cp_apply')]),
    ('lane from the address bits [2:1]',   [('al <= ', 'a_d[1:0]', 'a_d[2:1]')]),
    ('remote request not toggled',         [('req_q   <= ', '~req_q', 'req_q')]),
]


def die(msg):
    print('tb_fe_audio_mut: ' + msg, file=sys.stderr)
    sys.exit(2)


def build_text():
    text = open(RTL).read()
    for n, (name, sites) in enumerate(MUTANTS, 1):
        for pre, orig, mut in sites:
            key = pre + orig
            c = text.count(key)
            if c != 1:
                die('mutant %d (%s): "%s" occurs %d times' % (n, name, key, c))
            text = text.replace(key, '%s((tb_mut == %d) ? (%s) : (%s))' % (pre, n, mut, orig))
    anchor = "\tlocalparam logic [4:0] WSH0 = 5'd27;"
    if text.count(anchor) != 1:
        die('no anchor for tb_mut')
    text = text.replace(anchor, anchor + '\n\tint tb_mut = 0;\n\tinitial void\'($value$plusargs("mut=%d", tb_mut));')
    return text


def sources():
    srcs, opts = [], []
    for line in open(os.path.join(HERE, 'tb_fe_audio.f')):
        line = line.split('#')[0].strip()
        if not line:
            continue
        if line[0] in '-+':
            opts.append(line)
        else:
            p = os.path.join(ROOT, line)
            srcs.append(os.path.join(MW, 'daria_fe_audio.sv') if os.path.abspath(p) == RTL else p)
    return srcs + [os.path.join(HERE, 'tb_fe_audio.sv')], opts


def main():
    plus = [a for a in sys.argv[1:] if a.startswith('+')]
    only = [int(x) for x in os.environ.get('ONLY', '').split(',') if x]
    os.makedirs(MW, exist_ok=True)
    text = build_text()
    mrtl = os.path.join(MW, 'daria_fe_audio.sv')
    if not os.path.exists(mrtl) or open(mrtl).read() != text:
        open(mrtl, 'w').write(text)
    srcs, opts = sources()
    obj = os.path.join(MW, 'obj')
    args = [VERILATOR, '--binary', '--timing', '-j', os.environ.get('JOBS', '2'), '-O2', '-Wno-fatal', '-Wno-lint',
            '-Wno-style', '-Wno-TIMESCALEMOD', '-Wno-MULTIDRIVEN', '-I' + HERE, '--top-module', 'tb_fe_audio']
    if os.environ.get('POISON', '0') != '0':
        args.append('-DDARIA_RAM_POISON')
    args += opts + ['-Mdir', obj, '-o', 'vtb'] + srcs
    exe = os.path.join(obj, 'vtb')
    sig = ' '.join(args)
    stale = (not os.path.exists(exe) or open(os.path.join(MW, 'args')).read() != sig if os.path.exists(os.path.join(MW, 'args')) else True)
    if not stale:
        t = os.path.getmtime(exe)
        stale = any(os.path.getmtime(f) > t for f in srcs + [os.path.join(HERE, 'phase_gen.svh')])
    if stale:
        t0 = time.time()
        with open(os.path.join(MW, 'build.log'), 'w') as log:
            r = subprocess.run(['nice', '-n', '10'] + args, stdout=log, stderr=subprocess.STDOUT)
        if r.returncode != 0:
            die('build failed, see ' + os.path.join(MW, 'build.log'))
        for dp, _, fs in os.walk(obj):
            for f in fs:
                if f.endswith('.gch'):
                    os.remove(os.path.join(dp, f))
        open(os.path.join(MW, 'args'), 'w').write(sig)
        print('built in %d s' % (time.time() - t0))

    def run(n):
        t0 = time.time()
        r = subprocess.run(['nice', '-n', '10', exe, '+mut=%d' % n] + plus, cwd=MW, capture_output=True, text=True,
                           timeout=int(os.environ.get('TIMEOUT', '1800')))
        first = next((l for l in r.stdout.splitlines() if l.startswith('ERR') or 'NOT COVERED' in l or 'Fatal' in l), '')
        return r.returncode, time.time() - t0, first

    rc, t, first = run(0)
    print('original: %s (%d s) %s' % ('PASS' if rc == 0 else 'FAIL', t, first[:150]))
    if rc != 0:
        die('the original fails')
    missed = []
    for n, (name, _) in enumerate(MUTANTS, 1):
        if only and n not in only:
            continue
        rc, t, first = run(n)
        caught = rc != 0
        if not caught:
            missed.append(n)
        print('%2d %-42s %s (%3d s)  %s' % (n, name, 'caught' if caught else 'MISSED', t, first[:120]))
    total = len(only) if only else len(MUTANTS)
    print('tb_fe_audio_mut: %d of %d mutants caught%s' % (total - len(missed), total,
                                                        (', missed: ' + ', '.join(map(str, missed))) if missed else ''))
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
