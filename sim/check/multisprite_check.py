#!/usr/bin/env python3
"""extra_tests.sh's multisprite rule as a check (DARIA step 7, plan 1.2 row 4).

  multisprite_check.py DIR [--frame 2] [--bg 1] [--sprites 24]

DIR is extra_tests.sh's multisprite directory: frame_NNN.ppm (tb_load
+dump), gfx/herodown1.png (the 7800basic sample's sprite). The rule, from
extra_tests.sh's header: every sprite must match gfx/herodown1.png row for
row, with nothing drawn above or below it.

The sprite is 16 x 16 pixels of 160A (two frame pixels wide each), index 0
transparent, indices 1-3 one colour each (its palette). The background is
frame --bg (the screen before the game draws its sprites). In frame
--frame every pixel that differs from the background must belong to a
sprite drawn there: the check places sprites from the top of the pile down
(a placement fits when its opaque pixels not yet claimed by a placement
above it show one colour per index and at least one of them differs from
the background), claims their opaque pixels, and repeats until nothing more
fits. It fails when a differing pixel is left unclaimed (a row drawn in the
wrong place, a stray row above or below a sprite, garbage), when the number
of sprites found is not --sprites, or when a placement found shows fewer
than --min-visible of its pixels.
Exit status 0 pass, 1 fail, 2 missing input.
SPDX-License-Identifier: MIT
"""
import argparse
import os
import sys

from PIL import Image


def load_ppm(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    return w, h, [[px[x, y] for x in range(w)] for y in range(h)]


def sprite_pattern(path):
    im = Image.open(path)
    if im.mode != "P":
        raise SystemExit(f"{path}: expected an indexed PNG")
    w, h = im.size
    px = im.load()
    return [[px[x, y] for x in range(w)] for y in range(h)]


def check(d, frame, bg, want, min_visible, xscale=2):
    pf = os.path.join(d, f"frame_{frame:03d}.ppm")
    pb = os.path.join(d, f"frame_{bg:03d}.ppm")
    ps = os.path.join(d, "gfx", "herodown1.png")
    for p in (pf, pb, ps):
        if not os.path.exists(p):
            print(f"MULTISPRITE FAIL: missing {p}")
            return 2
    w, h, F = load_ppm(pf)
    wb, hb, B = load_ppm(pb)
    if (w, h) != (wb, hb):
        print(f"MULTISPRITE FAIL: frame sizes differ ({w}x{h}, background {wb}x{hb})")
        return 1
    S = sprite_pattern(ps)
    sh, sw = len(S), len(S[0])
    # opaque pixels of the sprite in frame coordinates: (dx, dy, index)
    opq = [(i * xscale + k, j, S[j][i]) for j in range(sh) for i in range(sw) if S[j][i] for k in range(xscale)]
    first = {}
    for dx, dy, c in opq:
        first.setdefault(c, (dx, dy))
    diff = {(x, y) for y in range(h) for x in range(w) if F[y][x] != B[y][x]}
    if not diff:
        print("MULTISPRITE FAIL: no sprite drawn (the frame equals the background)")
        return 1
    claimed = set()
    found = []
    # candidate origins: any placement whose box touches a differing pixel
    xs = range(min(x for x, _ in diff) - sw * xscale + 1, max(x for x, _ in diff) + 1)
    ys = range(min(y for _, y in diff) - sh + 1, max(y for _, y in diff) + 1)
    # anchors: a few opaque pixels spread over the sprite, for a quick reject
    anchors = opq[::max(1, len(opq) // 12)]
    while True:
        new = []
        for oy in ys:
            for ox in xs:
                if (ox, oy) in [(f[0], f[1]) for f in found]:
                    continue
                col, ok, vis = {}, True, 0
                for dx, dy, c in anchors:
                    x, y = ox + dx, oy + dy
                    if not (0 <= x < w and 0 <= y < h):
                        ok = False; break
                    if (x, y) in claimed:
                        continue
                    if col.setdefault(c, F[y][x]) != F[y][x]:
                        ok = False; break
                if not ok:
                    continue
                differs = False
                for dx, dy, c in opq:
                    x, y = ox + dx, oy + dy
                    if not (0 <= x < w and 0 <= y < h):
                        ok = False; break
                    if (x, y) in claimed:
                        continue
                    if col.setdefault(c, F[y][x]) != F[y][x]:
                        ok = False; break
                    vis += 1
                    differs |= (x, y) in diff
                if ok and differs and vis >= min_visible:
                    new.append((ox, oy, vis))
        if not new:
            break
        for ox, oy, vis in new:
            found.append((ox, oy, vis))
            for dx, dy, c in opq:
                claimed.add((ox + dx, oy + dy))
    left = sorted(diff - claimed, key=lambda p: (p[1], p[0]))
    print(f"multisprite {pf}: {len(found)} sprites placed, {len(diff)} pixels differ from the background, "
          f"{len(left)} of them unexplained")
    for ox, oy, vis in sorted(found, key=lambda f: (f[1], f[0])):
        print(f"  sprite at x {ox}, y {oy}: {vis} of {len(opq)} pixels visible")
    bad = []
    if left:
        rows = sorted({y for _, y in left})
        bad.append(f"{len(left)} differing pixels belong to no sprite (rows {rows[:8]}{'...' if len(rows) > 8 else ''})")
    if want and len(found) != want:
        bad.append(f"{len(found)} sprites, expected {want}")
    for b in bad:
        print("  FAIL: " + b)
    print("MULTISPRITE " + ("pass" if not bad else "FAIL"))
    return 0 if not bad else 1


def main():
    p = argparse.ArgumentParser(description="extra_tests.sh multisprite rule")
    p.add_argument("dir")
    p.add_argument("--frame", type=int, default=2)
    p.add_argument("--bg", type=int, default=1)
    p.add_argument("--sprites", type=int, default=24)
    p.add_argument("--min-visible", type=int, default=8)
    a = p.parse_args()
    sys.exit(check(a.dir, a.frame, a.bg, a.sprites, a.min_visible))


if __name__ == "__main__":
    main()
