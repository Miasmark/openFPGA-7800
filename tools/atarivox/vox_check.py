#!/usr/bin/env python3
"""Check the AtariVox RTL against the emulator, sample for sample.

  vox_check.py avox.log [out.wav]

avox.log comes from sim/atarivox/tb_avox.sv: the clocks at which bytes
entered the buffer (and serial control aborts and "Ready" requests), and
every output sample. The same events go through voxeng.py's emulator; every
sample must match in value and clock.

MIT licence, as the rest of the Pocket port's own code.
"""
import sys

import sjhw


def main():
    events, outs = [], []
    for line in open(sys.argv[1]):
        p = line.split()
        if p[0] == "P":
            events.append((int(p[1]), "byte", int(p[2])))
        elif p[0] == "A":
            events.append((int(p[1]), "abort", 0))
        elif p[0] == "R":
            events.append((int(p[1]), "ready", 0))
        elif p[0] == "O":
            outs.append((int(p[1]), int(p[2])))
    words, rom, _, _ = sjhw.build()
    e = sjhw.voxeng.Engine(words, rom, sjhw.TICK_DIV)
    for ev in events:
        e.schedule(*ev)
    e.run_until(outs[-1][0] + 1 if outs else 0)
    ref = [(c, ((s + 32768) & 0xFFFF) - 32768) for c, s in e.out]
    big = sum(1 for _, s in e.out if not -32768 <= s < 32768)
    n = min(len(ref), len(outs))
    bad = [i for i in range(n) if ref[i] != outs[i]]
    print(f"{len(events)} events, {len(outs)} RTL samples, {len(ref)} emulator samples, "
          f"{len(bad)} mismatches, {big} out of 16-bit range, ticks missed {e.missed}")
    for i in bad[:10]:
        print(f"  #{i}: RTL {outs[i]}  emulator {ref[i]}")
    if len(sys.argv) > 2:
        sjhw.write_wav(sys.argv[2], [s for _, s in outs])
    sys.exit(1 if bad or len(ref) != len(outs) or big else 0)


if __name__ == "__main__":
    main()
