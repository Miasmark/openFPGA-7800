#!/usr/bin/env python3
"""The AtariVox engine's data ROM (4,096 x 20 bits), built from the tuned
model's tables in sjsynth.py. The engine reads sounds as lists of segment
records: what sjsynth.py's SpeakJet.allophone() and effect() do, written out
as data.

Record (11 words):
  0  flags (below)
  1  base length in samples (the manual's ms x 8.192): the sound's d is
     base x LEN[len] x speed x rate
  2  duration: samples (ABS), a Q12 fraction of d (DFRAC) or samples
     scaled by speed only (CLOSURE)
  3  glide: samples (ABS) or a Q12 fraction of d (DFRAC); VFADE: 30 ms,
     or 60 ms after a voiced stop
  4  envelope control (bits 7:0), distortion (bits 15:8)
  5  pitch in Hz, for PITCH_LIT
  6-10  oscillators 1-5: frequency in Hz (bits 11:0), volume (bits 16:12)

MIT licence, as the rest of the Pocket port's own code.
"""
import math

import sjsynth as sj

RATE = 8192
WORDS = 4096

# flags
F_LAST, F_BEND, F_STRESS, F_KEEPF, F_KEEPV = 1, 2, 4, 8, 16
PITCH_REG, PITCH_LIT, PITCH_KEEP = 0 << 5, 1 << 5, 2 << 5
DUR_ABS, DUR_DFRAC, DUR_CLOSURE = 0 << 7, 1 << 7, 2 << 7
F_MIN8 = 1 << 9
GL_ABS, GL_DFRAC, GL_VFADE = 0 << 10, 1 << 10, 2 << 10
LEN_ONE, LEN_VOWEL, LEN_LIQUID, LEN_FRIC, LEN_GLIDE, LEN_STOP = range(6)
LENS = [1.0, sj.LEN_VOWEL, sj.LEN_LIQUID, sj.LEN_FRIC, sj.LEN_GLIDE, sj.LEN_STOP]

# layout
SIN_BASE = 0           # 512 words: the first half of a sine period, Q12
SPEED_TAB = 512        # 256: speed factor, Q12
BEND_TAB = 768         # 16: 0.8 + 0.04 x bend, Q12
LEN_TAB = 784          # 8: length factor by type of sound, Q12
PAUSE_TAB = 792        # 7: pause codes 0-6 in samples
STRESS_TAB = 800       # 6: IY then AX formants 1-3, Q4 (stress, relax)
LPF_TAB = 806          # 3: the output low-pass (b0, a1, a2), Q16
ALLO_IDX = 816         # 72: record address | glide << 12 | voiced stop << 13
EFF_IDX = 888          # 55: record address
READY_ROM = 944        # the "Ready" phrase (SCP V), ended by 0x100
REC_BASE = 960
REC_WORDS = 11

LPF_RATE = 16384       # the engine runs the low-pass at twice the sample rate
LPF_HZ = sj.LPF_HZ


def ms(x):
    return x * RATE / 1000


def q12(x):
    return int(round(x * 4096))


def samples(x_ms):
    return max(1, int(ms(x_ms)))


class Builder:
    def __init__(self):
        self.recs = []          # list of 11-word lists

    def rec(self, flags, base_ms, dur, glide, env, dist, pitch, f, v, length=LEN_ONE):
        f = [int(round(x)) for x in f]
        assert all(0 <= x < 4096 for x in f), f
        assert all(0 <= x < 32 for x in v), v
        w = [flags | (length << 12), int(round(ms(base_ms))), dur, glide,
             (env & 255) | ((dist & 255) << 8), pitch & 255] + \
            [fx | (vx << 12) for fx, vx in zip(f, v)]
        assert all(0 <= x < (1 << 20) for x in w), w
        self.recs.append(w)
        return len(self.recs) - 1

    def last(self):
        self.recs[-1][0] |= F_LAST


def voice_fv(f, a, nhz=0, nvol=0):
    """sjsynth's SpeakJet.voice(): oscillators 4 and 5 carry the noise."""
    nv = int(nvol * sj.NOISE_LEVEL)
    return list(f) + [min(3999, nhz), min(3999, int(nhz * 1.1))], list(a) + [nv, nv // 2]


def build():
    b = Builder()
    env_voice = sj.ENV_WAVE | 0x40
    allo = []
    for name in sj.ALLOPHONES:
        start = len(b.recs)
        glide = 0
        vstop = 0
        if name in sj.GLIDES:
            glide = 1
            ta, tb, gms = sj.GLIDES[name]
            fa, va = voice_fv(sj.T[ta][2], sj.T[ta][3])
            fb, vb = voice_fv(sj.T[tb][2], sj.T[tb][3])
            fl = F_BEND | PITCH_REG
            b.rec(fl | DUR_DFRAC | GL_ABS, gms, q12(0.4), samples(25), env_voice, 0, 0, fa, va, LEN_GLIDE)
            b.rec(fl | DUR_DFRAC | GL_DFRAC, gms, q12(0.6), q12(0.5), env_voice, 0, 0, fb, vb, LEN_GLIDE)
        else:
            typ, tms, f, a, nhz, nvol, dist = sj.T[name]
            fl = F_BEND | F_STRESS | PITCH_REG
            if typ in ("V", "N"):
                ln = LEN_LIQUID if typ == "N" or name in sj.LIQUIDS else LEN_VOWEL
                fv, vv = voice_fv(f, a)
                b.rec(fl | DUR_DFRAC | GL_VFADE, tms, q12(1.0), 0, env_voice, 0, 0, fv, vv, ln)
            elif typ in ("F", "Z"):
                fv, vv = voice_fv(f, a, nhz, nvol)
                b.rec(fl | DUR_DFRAC | GL_ABS, tms, q12(1.0), samples(15),
                      env_voice | (0x80 if typ == "Z" else 0), dist, 0, fv, vv, LEN_FRIC)
            else:                                           # S, P: closure, burst, aspiration
                vstop = 1 if typ == "S" else 0
                bar = [8, 0, 0] if typ == "S" else [0, 0, 0]
                fv, vv = voice_fv(f, bar)
                b.rec(fl | DUR_CLOSURE | GL_ABS, tms, int(round(ms(30 * sj.LEN_STOP))), samples(10),
                      env_voice, 0, 0, fv, vv, LEN_STOP)
                fv, vv = voice_fv(f, [0, 0, 0], nhz, 24)
                b.rec(fl | DUR_DFRAC | F_MIN8 | GL_ABS, tms, q12(0.3), samples(3),
                      env_voice, dist, 0, fv, vv, LEN_STOP)
                asp = 10 if typ == "P" else 0
                fv, vv = voice_fv(f, [6, 4, 2] if typ == "S" else [0, 0, 0], 1500, asp)
                b.rec(fl | DUR_DFRAC | GL_ABS, tms, q12(0.7), samples(15), env_voice, 255, 0, fv, vv, LEN_STOP)
        b.last()
        allo.append(start | (glide << 12) | (vstop << 13))

    eff = []
    no_voice = PITCH_KEEP
    for n in range(55):
        start = len(b.recs)
        fx = sj.FX_MS[n]
        if 40 <= n <= 51:
            lo, hi = sj.DTMF[n - 40]
            b.rec(no_voice | DUR_DFRAC | GL_ABS, fx, q12(1.0), samples(2), 0, 0, 0,
                  [lo, hi, 0, 0, 0], [20, 20, 0, 0, 0])
        elif 20 <= n <= 29:
            f = 600 + 180 * (n - 20)
            b.rec(no_voice | DUR_DFRAC | GL_ABS, fx, q12(1.0), samples(2), 0, 0, 0,
                  [f, 0, 0, 0, 0], [28, 0, 0, 0, 0])
        elif 10 <= n <= 19:
            steps = max(2, int(fx / 60))
            for k in range(steps):
                f = (900 if k % 2 else 1300) if n % 2 else 700 + 1600 * k / steps
                b.rec(no_voice | DUR_DFRAC | GL_ABS, fx, q12(1.0 / steps), samples(3), 0, 0, 0,
                      [f, min(3999, f * 1.5), 0, 0, 0], [22, 10, 0, 0, 0])
        elif n < 10:
            b.rec(PITCH_LIT | DUR_DFRAC | GL_ABS, fx, q12(1.0), samples(5), 3 | 0x40, 0, 70 + 12 * n,
                  [400 + 60 * n, 1200, 2400, 0, 0], [24, 14, 8, 0, 0])
        elif n == 52:
            b.rec(no_voice | DUR_ABS | GL_ABS, fx, samples(10), samples(2), 0, 0, 0,
                  [1000, 0, 0, 0, 0], [31, 0, 0, 0, 0])
            b.rec(no_voice | DUR_DFRAC | GL_DFRAC, fx, q12(1.0), q12(1.0), 0, 0, 0,
                  [1000, 0, 0, 0, 0], [0, 0, 0, 0, 0])
        elif n == 53:
            b.rec(no_voice | DUR_ABS | GL_ABS, fx, samples(5), samples(1), 0, 255, 0,
                  [0, 0, 0, 1500, 2500], [0, 0, 0, 31, 31])
            b.rec(no_voice | DUR_DFRAC | GL_DFRAC, fx, q12(1.0), q12(1.0), 0, 255, 0,
                  [0, 0, 0, 800, 1200], [0, 0, 0, 0, 0])
        elif n == 54:                                   # "WOW": WW, then AYWW
            f, a = voice_fv(sj.T["WW"][2], sj.T["WW"][3])
            b.rec(F_BEND | PITCH_REG | DUR_DFRAC | GL_ABS, 70, q12(1.0), samples(30), env_voice, 0, 0,
                  f, a, LEN_LIQUID)
            ta, tb, gms = sj.GLIDES["AYWW"]
            fa, va = voice_fv(sj.T[ta][2], sj.T[ta][3])
            fb, vb = voice_fv(sj.T[tb][2], sj.T[tb][3])
            b.rec(F_BEND | PITCH_REG | DUR_DFRAC | GL_ABS, gms, q12(0.4), samples(25), env_voice, 0, 0,
                  fa, va, LEN_GLIDE)
            b.rec(F_BEND | PITCH_REG | DUR_DFRAC | GL_DFRAC, gms, q12(0.6), q12(0.5), env_voice, 0, 0,
                  fb, vb, LEN_GLIDE)
        else:                                           # biological: placeholder warble
            for k in range(4):
                b.rec(no_voice | DUR_DFRAC | GL_ABS, fx, q12(0.25), samples(10), 0, 0, 0,
                      [300 + 200 * k, 900, 0, 0, 0], [20, 10, 0, 0, 0])
        b.last()
        eff.append(start)

    rom = [0] * WORDS
    for i in range(512):
        rom[SIN_BASE + i] = int(round(4095 * math.sin(2 * math.pi * i / 1024)))
    for s in range(256):
        rom[SPEED_TAB + s] = q12(math.exp(-sj.SPEED_K * (s - 114)))
    for k in range(16):
        rom[BEND_TAB + k] = q12(0.8 + 0.04 * k)
    for k, x in enumerate(LENS):
        rom[LEN_TAB + k] = q12(x)
    for k, x in enumerate(sj.PAUSE_MS):
        rom[PAUSE_TAB + k] = samples(max(x, 10))
    for k, x in enumerate(list(sj.T["IY"][2]) + list(sj.T["AX"][2])):
        rom[STRESS_TAB + k] = x * 16
    w0 = 2 * math.pi * LPF_HZ / LPF_RATE
    al = math.sin(w0) / (2 * 0.707)
    c = math.cos(w0)
    a0 = 1 + al
    for k, x in enumerate([(1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0]):
        rom[LPF_TAB + k] = int(round(x * 65536)) & 0xFFFFF
    for k, x in enumerate(allo):
        rom[ALLO_IDX + k] = REC_BASE + (x & 0xFFF) * REC_WORDS | (x & 0x3000)
    for k, x in enumerate(eff):
        rom[EFF_IDX + k] = REC_BASE + x * REC_WORDS
    # "Ready" (SCP V): RR EH ED IY at a flat 69 Hz; the pitch is put back after
    for k, x in enumerate([22, 69, 148, 131, 176, 128] + [0x100]):
        rom[READY_ROM + k] = x
    end = REC_BASE + len(b.recs) * REC_WORDS
    assert end <= WORDS, f"records end at {end}"
    for i, r in enumerate(b.recs):
        rom[REC_BASE + i * REC_WORDS:REC_BASE + (i + 1) * REC_WORDS] = r
    return rom, {"records": len(b.recs), "end": end, "free": WORDS - end}


CONSTS = {k: v for k, v in globals().items() if k.isupper() and isinstance(v, int)}

if __name__ == "__main__":
    rom, info = build()
    print(info)
