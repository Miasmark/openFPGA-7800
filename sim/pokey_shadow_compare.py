#!/usr/bin/env python3
"""Compare pokey_watson.pcm with pokey_new.pcm (run_pokey_shadow.sh output):
per window, each POKEY's AC level (RMS around the window mean) and how
closely the two waveforms agree, and write both as WAVs to listen to.
  pokey_shadow_compare.py [window_ms=100]"""
import sys, struct, wave, math
RATE = 48052
win_ms = int(sys.argv[1]) if len(sys.argv) > 1 else 100

def load(p):
    b = open(p, "rb").read()
    return struct.unpack("<%dH" % (len(b) // 2), b[:len(b) // 2 * 2])

w, n = load("pokey_watson.pcm"), load("pokey_new.pcm")
m = min(len(w), len(n))
for name, d in (("pokey_watson.wav", w), ("pokey_new.wav", n)):
    with wave.open(name, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(RATE)
        f.writeframes(struct.pack("<%dh" % m, *[v - 32768 if v >= 32768 else v for v in d[:m]]))

step = RATE * win_ms // 1000
print(f"{'ms':>6} {'Watson rms':>10} {'new rms':>8} {'ratio':>6} {'corr':>6}")
for i in range(0, m - step + 1, step):
    a, b = w[i:i + step], n[i:i + step]
    ma, mb = sum(a) / step, sum(b) / step
    da = [x - ma for x in a]; db = [x - mb for x in b]
    ra = math.sqrt(sum(x * x for x in da) / step); rb = math.sqrt(sum(x * x for x in db) / step)
    c = sum(x * y for x, y in zip(da, db)) / (step * ra * rb) if ra > 0 and rb > 0 else float("nan")
    print(f"{i * 1000 // RATE:6d} {ra:10.0f} {rb:8.0f} {rb / ra if ra else float('nan'):6.2f} {c:6.2f}")
