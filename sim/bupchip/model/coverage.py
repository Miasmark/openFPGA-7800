#!/usr/bin/env python3
"""How much of the firmware the synthetic ARSC block (synth_arsc.py) reaches
in the Python model: the coverage of the game-free regression.

  coverage.py

Runs songs 1, 2, 3 (bad tag), 4 (no channels) and 0, and one command of every
class ($00-$03, $40-$7F, $80-$BF, $C0-$FF); then song 0 with 16 voices
looped, one-shot and reversed; then three boots that must fault (no ARSC tag,
a bad CSMP tag, a wrong IDENT). Prints the code words that never ran (of
inventory.py's 1,704), which of the 21 bytecode handlers and the four
command-class handlers ran, and the fault codes. About 20 s.
"""
import time
from collections import Counter

from armemu import ARM, Abort, Periph, boot, render
from inventory import HANDLERS, discover, ranges
import synth_arsc

COMMANDS = [(1, [0x81]), (430, [0x82]), (500, [0x83]), (505, [0x84]), (510, [0x80]), (515, [0xC5]),
            (517, [0x03]), (519, [0x02]), (521, [0x40]), (523, [0xA1]), (525, [0x00]), (527, [0x01]),
            (528, [0x3f]), (529, [0xff])]
FAULT_PARK = {0xe8: 1, 0xdc: 2, 0x11c: 3}


class WrongIdent(Periph):
    def read(self, off):
        return 0x12345678 if off == 0 else Periph.read(self, off)


def main():
    t0 = time.time()
    code, _, table = discover()
    ran = Counter()
    block = synth_arsc.build()
    m = ARM(block)
    boot(m)
    render(m, 535, cmds=dict(COMMANDS))
    ran.update(m.count)
    print('songs 0-4 and every command class, 535 batches: fault %s, overflow %s, %d frames, %d non-zero'
          % (m.p.fault, m.p.overflow, len(m.p.frames), sum(1 for f in m.p.frames if f)))
    for mode in ('loop', 'oneshot', 'reverse'):
        m = ARM(synth_arsc.build(16, mode))
        boot(m)
        render(m, 30, cmds={0: [0x80]})
        ran.update(m.count)
        print('song 0, 16 voices %-8s 30 batches: fault %s, %d non-zero frames'
              % (mode, m.p.fault, sum(1 for f in m.p.frames if f)))
    i = block.index(b'CSMP')
    for name, blk, periph in (('no ARSC tag', b'XRSC' + block[4:], None),
                              ('bad CSMP tag', block[:i] + b'XSMP' + block[i + 4:], None),
                              ('wrong IDENT', block, WrongIdent())):
        m = ARM(blk, periph)
        try:
            boot(m)
            print('%-13s boot did not fault' % name)
        except Abort:
            pc = m.r[15]
            print('%-13s fault %#x, parked at %#x (fault %d)' % (name, m.p.fault, pc, FAULT_PARK.get(pc, -1)))
            ran.update(m.count)
            ran[pc] += 1                       # the 'b .' it parked on
    missed = sorted(a for a in code if not ran[a])
    print('\ncoverage: %d of %d code words (%.1f%%); never ran (%d words):'
          % (len(code) - len(missed), len(code), 100.0 * (len(code) - len(missed)) / len(code), len(missed)))
    for s, e in ranges(missed):
        print('   %#06x-%#06x  %d words' % (s, e - 4, (e - s) // 4))
    print('bytecode handlers run: %d of %d; command-class handlers run: %s; %.0f s'
          % (sum(1 for h in HANDLERS if ran[h]), len(HANDLERS),
             ' '.join('%#x' % t for t in table.values() if ran[t]), time.time() - t0))


if __name__ == '__main__':
    main()
