#!/usr/bin/env python3
"""Static inventory of the CoreTone firmware (src/fpga/mister/rtl/bupchip.hex):
which words are code, and every instruction form the code uses.

  inventory.py [--objdump arm-none-eabi-objdump]

Code is found by recursive descent from the reset and exception vectors, the
21 handler pointers in the .data image (0x1e3c, copied to RAM at boot), the
jump table after 'ldr pc' at 0x1ec, and 'mov lr,pc; bx rN' indirect calls.
Prints the code and data map, a mnemonic cross-check against objdump (when
it is installed), the instruction-form inventory, which flags each
flag-setting instruction feeds, and the shift, multiply and PC-read details
that docs/BUPCHIP_CORE.md cites. coverage.py imports discover().
"""
import argparse
import os
import re
import struct
import subprocess
import tempfile
from collections import Counter, defaultdict

from armdec import CONDS, RN, SHT, decode, firmware, reglist, text

W = firmware()
D = [decode(w, 4 * i) for i, w in enumerate(W)]
DATA_SRC, DATA_VMA, DATA_END = W[0x74 // 4], W[0x78 // 4], W[0x7c // 4]    # crt0's literals
HANDLERS = W[DATA_SRC // 4:DATA_SRC // 4 + (DATA_END - DATA_VMA) // 4]     # macro ops, channel ops
JUMP_TABLE = 0x1ec                                                         # ldr pc,[r3,r2,lsl #2]


def discover():
    """Returns (code addresses, literal address -> loading PCs, jump table)."""
    code, lits, table = set(), defaultdict(list), {}
    todo = list(range(0, 0x24, 4)) + HANDLERS
    while todo:
        a = todo.pop()
        while 0 <= a < 4 * len(W) and a not in code:
            code.add(a)
            d = D[a // 4]
            k, always = d['kind'], d['cond'] == 14
            if k == 'xfer' and d['rn'] == 15 and not d['regoff']:
                lits[a + 8 + (d['off12'] if d['u'] else -d['off12'])].append(a)
            if k == 'b':
                todo.append(d['target'])
                if always and not d['link']:
                    break
            elif k == 'bx' and always:
                p = D[a // 4 - 1]
                if not (d['rm'] != 14 and p['kind'] == 'dp' and p['opn'] == 'mov' and p['rd'] == 14 and
                        p.get('rm') == 15):
                    break                              # a return, not 'mov lr,pc; bx rN'
            elif k == 'xfer' and d['l'] and d['rd'] == 15:
                if a == JUMP_TABLE:
                    table = {a + 4 + 4 * i: W[(a + 4) // 4 + i] for i in range(4)}
                    todo.extend(table.values())
                if always:
                    break
            elif (k == 'ldm' and d['l'] and d['rlist'] >> 15 & 1 or
                  k == 'dp' and d['rd'] == 15 and not 8 <= d['op'] <= 11) and always:
                break
            a += 4
    return code, lits, table


def ranges(addrs):
    out = []
    for a in sorted(addrs):
        if out and out[-1][1] == a:
            out[-1][1] = a + 4
        else:
            out.append([a, a + 4])
    return out


def objdump_check(code, objdump):
    """Compare text() with objdump's mnemonic for every code word."""
    with tempfile.TemporaryDirectory() as t:
        path = os.path.join(t, 'fw.bin')
        open(path, 'wb').write(struct.pack('<%dI' % len(W), *W))
        out = subprocess.run([objdump, '-D', '-b', 'binary', '-marm', path], capture_output=True, text=True).stdout
    dis = {int(m.group(1), 16): m.group(2) for m in re.finditer(r'^\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(\S+)', out, re.M)}
    bad = []
    for a in sorted(code):
        mn = dis.get(a, '?')
        mn = re.sub(r'^push', 'stm', re.sub(r'^pop', 'ldm', mn))
        mn = re.sub(r'^(ldm|stm)(ia|ib|da|db)', r'\1', mn)
        mn = re.sub(r'^(lsl|lsr|asr|ror|rrx)', 'mov', mn)
        mn = re.sub(r'^(ldr|str)(b|h|sb|sh)?t', r'\1\2', mn)
        if mn != text(D[a // 4]):
            bad.append((a, dis.get(a), text(D[a // 4])))
    print('objdump cross-check: %d code words, %d mismatches' % (len(code), len(bad)))
    for a, theirs, mine in bad[:20]:
        print('  %#06x objdump %s, decoder %s' % (a, theirs, mine))


def forms(code):
    """Instruction form -> addresses."""
    inv = defaultdict(list)
    for a in sorted(code):
        d = D[a // 4]
        k = d['kind']
        if k == 'dp':
            inv[('data processing (op, S)', d['opn'], 'S' if d['s'] else '')].append(a)
            f = d['op2']
            key = ('imm, rot=%d' % d['rot'] if f == 'imm' else 'shift by imm, %s #%d' % (SHT[d['st']], d['amt'])
                   if f == 'regshift_imm' else 'shift by reg, %s' % SHT[d['st']] if f == 'regshift_reg' else f)
            inv[('operand 2', key)].append(a)
            if d['op'] in (5, 6, 7):
                inv[('carry in (ADC/SBC/RSC)', d['opn'])].append(a)
            if d['s'] and d['op'] in (0, 1, 8, 9, 12, 13, 14, 15) and (f != 'imm' or d['rot']):
                inv[('logical S with a shifter carry out', d['opn'], f)].append(a)
            if 15 in (d['rn'], d.get('rm'), d.get('rs')) and (d['op'] not in (13, 15) or d.get('rm') == 15):
                inv[('data processing reading PC', d['opn'])].append(a)
            if d['rd'] == 15 and not 8 <= d['op'] <= 11:
                inv[('data processing writing PC',)].append(a)
        elif k in ('xfer', 'xfer_h'):
            mode = ('pre' + ('!' if d['wb'] else '')) if d['p'] else 'post'
            if k == 'xfer':
                op = ('ldr' if d['l'] else 'str') + ('b' if d['b'] else '')
                off = ('imm' if d['off12'] else 'imm0') if not d['regoff'] else \
                    'reg' + ('' if d['st'] == 0 and d['amt'] == 0 else ',%s#%d' % (SHT[d['st']], d['amt']))
                if d['l'] and d['rd'] == 15:
                    inv[('LDR to PC',)].append(a)
                if not d['p'] and d['wb']:
                    inv[('LDRT/STRT',)].append(a)
            else:
                op, off = d['op'], ('imm' if d['off8'] else 'imm0') if d['immoff'] else 'reg'
            base = 'base=' + ('pc' if d['rn'] == 15 else 'sp' if d['rn'] == 13 else 'r')
            inv[('load/store', op, mode, off, 'U' if d['u'] else 'D', base)].append(a)
            if (d['wb'] or not d['p']) and d['rn'] == d['rd']:
                inv[('write-back with Rn == Rd',)].append(a)
        elif k == 'ldm':
            op = ('ldm' if d['l'] else 'stm') + ('i' if d['u'] else 'd') + ('b' if d['p'] else 'a')
            inv[('LDM/STM', op + ('!' if d['wb'] else ''), RN[d['rn']], reglist(d['rlist']),
                 '^' if d['s'] else '')].append(a)
            if d['rlist'] >> d['rn'] & 1:
                inv[('LDM/STM with the base in the list',)].append(a)
            if d['rlist'] >> 15 & 1:
                inv[('LDM/STM with PC in the list',)].append(a)
        elif k == 'b':
            inv[('branch', 'bl' if d['link'] else 'b', 'cond' if d['cond'] != 14 else 'al',
                 'back' if d['target'] <= a else 'fwd')].append(a)
        elif k == 'bx':
            inv[('BX', RN[d['rm']], 'cond' if d['cond'] != 14 else 'al')].append(a)
        elif k == 'mul':
            inv[('multiply', 'mla' if d['acc'] else 'mul', 'S' if d['s'] else '')].append(a)
        elif k == 'mull':
            inv[('multiply', text(dict(d, cond=14)))].append(a)
        elif k in ('mrs', 'msr'):
            inv[('PSR', k, 'spsr' if d['r'] else 'cpsr') + (('mask=%x' % d['mask'], 'imm' if d['i'] else 'reg')
                                                          if k == 'msr' else ())].append(a)
        else:
            inv[('other', k)].append(a)
        if d['cond'] != 14:
            inv[('conditional', k)].append(a)
    return inv


FLAGS_READ = ['Z', 'Z', 'C', 'C', 'N', 'N', 'V', 'V', 'CZ', 'CZ', 'NV', 'NV', 'ZNV', 'ZNV', '', '']


def flag_uses(code):
    """setter address -> set of (reader address, flag): every path from a
    flag-setting instruction to the next unconditional setter. Calls count as
    clobbering the flags."""
    def sets(d):
        return d['kind'] == 'dp' and d['s'] or d['kind'] in ('mul', 'mull') and d['s'] or d['kind'] == 'msr'

    def succ(a):
        d = D[a // 4]
        k, cond = d['kind'], d['cond'] != 14
        if k == 'b':
            return [] if d['link'] else [d['target']] + ([a + 4] if cond else [])
        if k == 'bx' or k == 'xfer' and d['l'] and d['rd'] == 15 or k == 'ldm' and d['l'] and d['rlist'] >> 15 & 1:
            return [a + 4] if cond else []
        return [a + 4]

    uses = defaultdict(set)
    for a in sorted(code):
        if not sets(D[a // 4]):
            continue
        seen, todo = set(), succ(a)
        while todo:
            b = todo.pop()
            if b in seen or b not in code:
                continue
            seen.add(b)
            e = D[b // 4]
            reads = set(FLAGS_READ[e['cond']])
            if e['kind'] == 'dp' and (e['op'] in (5, 6, 7) or e.get('op2') == 'rrx'):
                reads.add('C')
            uses[a] |= {(b, f) for f in reads}
            if not (sets(e) and e['cond'] == 14):
                todo.extend(succ(b))
    return uses


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--objdump', default='arm-none-eabi-objdump')
    a = ap.parse_args()
    code, lits, table = discover()
    other = set(range(0, 4 * len(W), 4)) - code - set(lits) - set(table) - \
        set(range(DATA_SRC, DATA_SRC + 4 * len(HANDLERS), 4))
    print('firmware: %d words (%d bytes); .data image at %#x (%d handler pointers), .data %#x-%#x'
          % (len(W), 4 * len(W), DATA_SRC, len(HANDLERS), DATA_VMA, DATA_END))
    print('code words: %d; literal-pool words: %d; jump-table words: %d; other data words: %d; code read as data: %d'
          % (len(code), len(lits), len(table), len(other), len(code & set(lits))))
    print('code ranges: ' + ', '.join('%#x-%#x' % (s, e - 4) for s, e in ranges(code)))
    print('other data: ' + ', '.join('%#x-%#x' % (s, e - 4) for s, e in ranges(other)))
    print('jump table at %#x: %s' % (min(table), ' '.join(hex(t) for t in table.values())))
    print('handlers: %s' % ' '.join(hex(h) for h in HANDLERS))
    try:
        objdump_check(code, a.objdump)
    except OSError:
        print('objdump cross-check skipped: %s not found' % a.objdump)

    print('\nINSTRUCTION FORMS over %d code words' % len(code))
    print('kinds: ' + ', '.join('%s %d' % kv for kv in Counter(D[x // 4]['kind'] for x in code).most_common()))
    print('conditions: ' + ', '.join('%s %d' % kv for kv in
                                       Counter(CONDS[D[x // 4]['cond']] or 'al' for x in code).most_common()))
    inv = forms(code)
    for group in ('data processing (op, S)', 'operand 2', 'carry in (ADC/SBC/RSC)', 'logical S with a shifter carry out',
                  'data processing reading PC', 'data processing writing PC', 'load/store', 'LDR to PC', 'LDRT/STRT',
                  'write-back with Rn == Rd', 'LDM/STM', 'LDM/STM with the base in the list',
                  'LDM/STM with PC in the list', 'branch', 'BX', 'multiply', 'PSR', 'other', 'conditional'):
        keys = sorted((k for k in inv if k[0] == group), key=lambda k: (-len(inv[k]), k))
        print('-- %s: %d' % (group, sum(len(inv[k]) for k in keys)))
        for k in keys:
            al = inv[k]
            print('   %-60s %4d  %s%s' % (' '.join(x for x in k[1:] if x), len(al),
                                         ','.join(hex(x) for x in al[:6]), ' ...' if len(al) > 6 else ''))

    print('\nFLAGS: setter -> flags its readers use')
    uses = flag_uses(code)
    by = defaultdict(Counter)
    for s, rs in uses.items():
        for _, f in rs:
            by[text(dict(D[s // 4], cond=14))][f] += 1
    for k, v in sorted(by.items()):
        print('   %-8s %s' % (k, ' '.join('%s %d' % kv for kv in sorted(v.items()))))
    unused = [s for s in sorted(code) if D[s // 4]['kind'] in ('dp', 'msr') and
              (D[s // 4].get('s') or D[s // 4]['kind'] == 'msr') and not uses.get(s)]
    print('   setters with no reader: ' + ' '.join('%#x %s' % (s, text(D[s // 4])) for s in unused))

    print('\nSHIFTS')
    imm = Counter((SHT[D[x // 4]['st']], D[x // 4]['amt']) for x in code
                  if D[x // 4]['kind'] == 'dp' and D[x // 4]['op2'] == 'regshift_imm')
    print('   data processing, by immediate: ' + ', '.join('%s #%d x%d' % (s, n, c) for (s, n), c in sorted(imm.items())))
    off = Counter((SHT[D[x // 4]['st']], D[x // 4]['amt']) for x in code if D[x // 4]['kind'] == 'xfer' and
                  D[x // 4]['regoff'])
    print('   LDR/STR register offsets: ' + ', '.join('%s #%d x%d' % (s, n, c) for (s, n), c in sorted(off.items())))
    print('   RRX: %d; LSR/ASR #32: %d' % (
        sum(1 for x in code if D[x // 4].get('op2') == 'rrx' or D[x // 4].get('rrx')),
        sum(1 for x in code if D[x // 4].get('amt') == 32)))
    for x in sorted(code):
        d = D[x // 4]
        if d['kind'] == 'dp' and d['op2'] == 'regshift_reg':
            print('   %#06x %s%s %s, %s, %s %s %s' % (x, d['opn'], 's' if d['s'] else '', RN[d['rd']], RN[d['rn']],
                                                RN[d['rm']], SHT[d['st']], RN[d['rs']]))
    print('\nMULTIPLIES')
    for x in sorted(code):
        d = D[x // 4]
        if d['kind'] == 'mul':
            print('   %#06x %s rd=%s rm=%s rs=%s%s' % (x, 'mla' if d['acc'] else 'mul', RN[d['rd']], RN[d['rm']],
                                                   RN[d['rs']], ' rn=' + RN[d['rn']] if d['acc'] else ''))
        elif d['kind'] == 'mull':
            print('   %#06x %s lo=%s hi=%s rm=%s rs=%s' % (x, text(d), RN[d['rdlo']], RN[d['rdhi']], RN[d['rm']],
                                                       RN[d['rs']]))


if __name__ == '__main__':
    main()
