#!/usr/bin/env python3
"""Reference model of one POKEY channel, from the documented behaviour
(Atari hardware manual; Altirra Hardware Reference Manual ch. POKEY):

  - base clock: 64 kHz = 1.79 MHz / 28 (AUDCTL bit 0 = 0), or 15 kHz = /114
    (bit 0 = 1); channel 1 may run at 1.79 MHz (AUDCTL bit 6), period AUDF+4
  - a channel's counter underflows every AUDF+1 base ticks
  - at each underflow: AUDC bit 5 set -> the output toggles (pure tone);
    otherwise, if bit 7 is clear the update only happens when poly5 is 1,
    and the new output is poly4 (bit 6 set) or poly17 (bit 6 clear)
  - the polys step every 1.79 MHz cycle, free running

Prints "AUDF <n> <transitions>" for all 256 AUDF values over <ms> ms, like
tb_pokey. Transition counts depend only on the sampling stride against the
poly lengths (15, 31, 131071), so the LFSR seeds do not matter.
"""
import sys

audc = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0xC8
audctl = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0
ms = int(sys.argv[3]) if len(sys.argv) > 3 else 20
ticks = int(1789773 * ms / 1000)

def lfsr(bits, taps, n, seed=1):
    s, out = seed, []
    for _ in range(n):
        out.append(s & 1)
        fb = 0
        for t in taps:
            fb ^= (s >> t) & 1
        s = (s >> 1) | (fb << (bits - 1))
    return out

p4 = lfsr(4, (0, 1), 15)
p5 = lfsr(5, (0, 2), 31)
p17 = lfsr(17, (0, 5), 131071)
if audctl & 0x80:
    p17 = lfsr(9, (0, 4), 511)

for f in range(256):
    if audctl & 0x40:
        period = f + 4
    else:
        period = (f + 1) * (114 if audctl & 1 else 28)
    out, tr = 0, 0
    t = period
    while t < ticks:
        if audc & 0x20:
            new = out ^ 1
        else:
            if not (audc & 0x80) and not p5[t % 31]:
                new = out
            else:
                new = p4[t % 15] if audc & 0x40 else p17[t % len(p17)]
        if new != out:
            tr += 1
        out = new
        t += period
    print(f"AUDF {f} {tr}")
