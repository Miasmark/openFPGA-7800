#!/usr/bin/env python3
"""Compare tb_s1.sv's PCM with a MiSTer reference, and summarise its batches.

  pcm_check.py OURS.pcm [REF.pcm] [--batches FILE]

Both files are 48 kHz stereo s16le frames. OURS holds every frame the
firmware pushed from power-up; REF is run_bupchip.sh's output (the frames
MiSTer's FIFO played). They start with different amounts of silence: the
boot prefill (1,000 frames with a 1,024-deep FIFO, 4,000 with 4,096) and
whatever silent batches ran before the song command. So both are lined up
on their first nonzero frame, the song's first, and every frame both have
from there on must be equal; the last line says whether OURS covered the
whole reference. Exit status 1 on any difference.

--batches takes tb_s1.sv's "clocks instructions" lines (one per batch of
200 frames, 240 a second) and prints the average and worst batch and the
busiest 0.1 s (24 consecutive batches) as MHz needed at 100% busy, plus the
CPI over the batches.
"""
import argparse
import struct
import sys

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("ours")
ap.add_argument("ref", nargs="?")
ap.add_argument("--batches")
a = ap.parse_args()


def frames(path):
    d = open(path, "rb").read()
    return struct.unpack("<%dI" % (len(d) // 4), d[:len(d) // 4 * 4])


ok = True
ours = frames(a.ours)
fo = next((i for i, x in enumerate(ours) if x), None)
print("ours: %d frames pushed, first nonzero at %s" % (len(ours), fo))
if a.ref:
    ref = frames(a.ref)
    fr = next((i for i, x in enumerate(ref) if x), None)
    if fo is None or fr is None:
        print("PCM FAIL: no nonzero frame (ours %s, reference %s)" % (fo, fr))
        ok = False
    else:
        want = len(ref) - fr
        have = len(ours) - fo
        n = min(want, have)
        bad = [i for i in range(n) if ours[fo + i] != ref[fr + i]]
        print("reference: %d frames, first nonzero at %d; compared %d song frames, %d differ%s"
              % (len(ref), fr, n, len(bad), ", first at song frame %d" % bad[0] if bad else ""))
        if bad:
            ok = False
            print("PCM FAIL")
        elif have < want:
            print("PCM IDENTICAL over the first %d of the reference's %d song frames (ours is shorter)" % (n, want))
        else:
            print("PCM IDENTICAL: all %d of the reference's song frames" % want)

if a.batches:
    rows = [tuple(map(int, line.split())) for line in open(a.batches) if line.strip()]
    if rows:
        c = [r[0] for r in rows]
        i = [r[1] for r in rows]
        w = 24
        peak = max(sum(c[k:k + w]) for k in range(max(1, len(c) - w + 1))) * 240 / min(w, len(c)) / 1e6
        print("batches %d: average %.2f MHz, busiest 0.1 s %.2f MHz, worst batch %.2f MHz (%d clocks); CPI %.4f"
              % (len(c), sum(c) * 240 / len(c) / 1e6, peak, max(c) * 240 / 1e6, max(c), sum(c) / sum(i)))
sys.exit(0 if ok else 1)
