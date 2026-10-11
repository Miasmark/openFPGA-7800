#!/usr/bin/env python3
"""A model of the SpeakJet (the AtariVox's speech chip), for tuning sound
tables by ear before any of it goes into the FPGA.

The synthesizer follows Magnevation's SpeakJet User's Manual (2004): five
oscillators (0-3999 Hz, volume 0-31) and a sixth that envelopes them at the
voice's pitch, noise ("distortion") on oscillators 4 and 5, a master volume,
8,192 samples a second. Codes and controls follow the manual's Tables D and
E. The sound tables below are ours: the chip's own (its "MSA" database) are
not published. Vowels and voiced sounds put textbook English formants on
oscillators 1-3; hiss and bursts use 4 and 5 with noise.

  sjsynth.py out.wav 31 21 100 23 3 22 200 14 179 ...    codes as numbers
  sjsynth.py out.wav --log tb_out.log                     tb_load +voxlog output

MIT licence, as the rest of the Pocket port's own code.
"""
import math
import re
import struct
import sys
import wave

import numpy as np

RATE = 8192
# Length factor on every sound and pause, on top of the per-type factors
# below (--stretch).
STRETCH = 1.0
# Real length / the manual's length, by type of sound: 20 words of the
# AtariVox demo's A-Z list (codes from Magnevation's Phrase-A-Lator
# dictionary), each aligned to our render of its codes, 118 sounds in all.
# Words as a whole: 1.24 (11.82 s against 9.54 s), in line with game phrases
# (Juno First, Stratovox: 1.09-1.24).
LEN_VOWEL, LEN_LIQUID, LEN_FRIC, LEN_GLIDE, LEN_STOP = 1.41, 1.33, 1.25, 1.22, 0.85
# Speed: length x exp(-SPEED_K x (speed - 114)), about 2% a step (0: the
# plain 114 / speed). Fitted to rubyQ's title at speed 80 ("Ru-", "-by":
# real ~0.41 / ~0.30 s, ours 0.38 / 0.32), with Juno First (speeds 90-127).
SPEED_K = 0.02
# A sound that repeats the one before it gets no transition time, so it
# keeps the manual's length: Juno First holds its vowels with OW x8, RR x5
# ("Foolish human": UX x6); with this, those phrases come to 1.42 s and
# 1.22 s against the real 1.40 s and 1.26 s.
REPEAT_PLAIN = 1
LIQUIDS = {"LE", "LO", "WW", "RR"}
# The voice's envelope wave (register 8 bits 1:0): 0 saw, 1 sine, 2 triangle,
# 3 square. Juno First's clean bands came from its customised voice; the
# default voice (the alphabet demo, Stratovox's "Game over") shows the dense,
# full-height buzz of a saw.
ENV_WAVE = 0
# Hiss (oscillators 4 and 5) against the vowels. Juno First's title: the
# real hiss sits 20 dB under its vowels; at 0.5 ours was 13.4 dB under.
NOISE_LEVEL = 0.25
# The SpeakJet's PWM output goes through a two-pole low-pass (the manual's
# Figure 1), which the AtariVox board has too. Fitted to a clean recording of
# the real chip reciting the alphabet at default settings (87 Hz voice): one
# 2-pole low-pass at 2,200 Hz brings the long-term spectrum to within 3.4 dB
# of it, against 13-14 dB without. 0 turns it off (--lpf).
LPF_HZ = 2200
# Restart oscillators 1-3 at every pitch period (--sync 0 to turn off). The
# real chip's output is periodic at exactly the commanded pitch (Juno First:
# 170, 91-165, 225, 110 Hz, as its codes ask); free-running oscillators
# against the envelope are not, and track as nonsense.
PITCH_SYNC = 1

# ---------------------------------------------------------------- tables
# name: (type, ms, [F1, F2, F3], [A1, A2, A3], noise_hz, noise_vol, dist)
#   type: V vowel/voiced, N nasal, F voiceless fricative, Z voiced
#   fricative, S voiced stop, P voiceless stop, A affricate
# Diphthongs and R-coloured vowels: "a>b" glides from a's target to b's.
T = {}
def v(name, ms, f, a=(22, 14, 8)): T[name] = ("V", ms, list(f), list(a), 0, 0, 0)
def nas(name, ms, f): T[name] = ("N", ms, list(f), [20, 4, 2], 0, 0, 0)
def fr(name, ms, nhz, nvol, dist, voiced=False, f=(250, 1400, 2500)):
    T[name] = ("Z" if voiced else "F", ms, list(f), [14, 0, 0] if voiced else [0, 0, 0], nhz, nvol, dist)
def st(name, ms, nhz, voiced, f):
    T[name] = ("S" if voiced else "P", ms, list(f), [0, 0, 0], nhz, 20, 200)

v("IY", 70, (270, 2290, 3010)); v("IH", 70, (300, 1775, 2520)); v("EY", 70, (480, 1870, 2460))  # IH: "Foolish human"; EY: Stratovox "Game over"
v("EH", 70, (590, 1650, 2480)); v("AY", 70, (660, 1720, 2410)); v("AX", 70, (500, 1500, 2500))  # EH: the alphabet's F, L, M, N, S
v("UX", 70, (605, 1335, 2390)); v("OH", 70, (730, 1090, 2440)); v("AW", 70, (610, 1030, 2410))  # UX: "Foolish human", held at 110-200 Hz; AW: the alphabet's R
v("OW", 70, (490, 910, 2450)); v("UH", 70, (440, 1020, 2240)); v("UW", 70, (300, 870, 2240))
nas("MM", 70, (280, 1150, 2200)); nas("NE", 70, (250, 1700, 2600)); nas("NO", 70, (250, 1300, 2500))  # MM measured: "Foolish human"
nas("NGE", 70, (250, 2000, 2700)); nas("NGO", 70, (250, 1100, 2400))
v("LE", 70, (360, 1300, 2700), (20, 10, 4)); v("LO", 70, (360, 900, 2600), (20, 10, 4))
v("WW", 70, (290, 610, 2150), (20, 8, 2)); v("RR", 70, (435, 1310, 1765), (24, 12, 3))  # measured: Juno First's "First" (RR x5)
GLIDES = {  # code name: (from, to, ms)
    "IYRR": ("IY", "RR", 200), "EYRR": ("EH", "RR", 200), "AXRR": ("AX", "RR", 190),
    "AWRR": ("AW", "RR", 200), "OWRR": ("OW", "RR", 185), "EYIY": ("EY", "IY", 165),
    "OHIY": ("OH", "IY", 200), "OWIY": ("OW", "IY", 225), "OHIH": ("OH", "IH", 185),
    "IYEH": ("IY", "EH", 170), "EHLL": ("EH", "LE", 140), "IYUW": ("IY", "UW", 180),
    "AXUW": ("AX", "UW", 170), "IHWW": ("IH", "WW", 170), "AYWW": ("AY", "WW", 200),
    "OWWW": ("OW", "WW", 131),
}
fr("JH", 70, 2500, 16, 160, True); fr("VV", 70, 3500, 6, 255, True); fr("ZZ", 70, 3900, 12, 160, True)
fr("ZH", 70, 2500, 12, 160, True); fr("DH", 70, 3800, 5, 255, True)
st("BE", 45, 900, True, (250, 1800, 2500)); st("BO", 45, 800, True, (250, 900, 2300))
st("EB", 10, 900, True, (250, 1800, 2500)); st("OB", 10, 800, True, (250, 900, 2300))
st("DE", 45, 3500, True, (250, 1800, 2700)); st("DO", 45, 3200, True, (250, 1400, 2600))
st("ED", 10, 3500, True, (250, 1800, 2700)); st("OD", 10, 3200, True, (250, 1400, 2600))
st("GE", 55, 2200, True, (250, 2200, 2800)); st("GO", 55, 1500, True, (250, 1200, 2300))
st("EG", 55, 2200, True, (250, 2200, 2800)); st("OG", 55, 1500, True, (250, 1200, 2300))
fr("CH", 70, 2600, 20, 160); fr("HE", 35, 1800, 4, 255); fr("HO", 35, 1100, 4, 255)  # H: barely audible on the real chip ("Help me")
fr("WH", 70, 900, 8, 255); fr("FF", 70, 1800, 6, 255); fr("SE", 40, 3950, 22, 120)  # FF: quiet, mostly below 1.5 kHz (Gorf's "Gorf": ~22 dB under the vowel)
fr("SO", 40, 3700, 22, 120); fr("SH", 50, 2500, 22, 160); fr("TH", 40, 3800, 5, 255)
st("TT", 50, 3800, False, (250, 1800, 2700)); st("TU", 70, 3800, False, (250, 1800, 2700))
T["TS"] = ("P", 170, [250, 1800, 2700], [0, 0, 0], 3950, 22, 120)
st("KE", 55, 2400, False, (250, 2200, 2800)); st("KO", 55, 1600, False, (250, 1200, 2300))
st("EK", 55, 2400, False, (250, 2200, 2800)); st("OK", 45, 1600, False, (250, 1200, 2300))
st("PE", 99, 1000, False, (250, 1500, 2500)); st("PO", 99, 900, False, (250, 900, 2300))

ALLOPHONES = ("IY IH EY EH AY AX UX OH AW OW UH UW MM NE NO NGE NGO LE LO WW RR IYRR EYRR "
              "AXRR AWRR OWRR EYIY OHIY OWIY OHIH IYEH EHLL IYUW AXUW IHWW AYWW OWWW JH VV ZZ ZH "
              "DH BE BO EB OB DE DO ED OD GE GO EG OG CH HE HO WH FF SE SO SH TH TT TU TS KE KO "
              "EK OK PE PO").split()
assert len(ALLOPHONES) == 72
# Every code must have a table entry: a missing one would only show up when a
# phrase reaches it.
assert all(a in T or a in GLIDES for a in ALLOPHONES), [a for a in ALLOPHONES if a not in T and a not in GLIDES]
assert all(a in T and b in T for a, b, _ in GLIDES.values())
DTMF = {0: (941, 1336), 1: (697, 1209), 2: (697, 1336), 3: (697, 1477), 4: (770, 1209),
        5: (770, 1336), 6: (770, 1477), 7: (852, 1209), 8: (852, 1336), 9: (852, 1477),
        10: (941, 1209), 11: (941, 1477)}
FX_MS = [80] * 10 + [300, 101, 102, 540, 530, 500, 135, 600, 300, 250] + \
        [200, 270, 280, 260, 300, 100, 104, 100, 270, 262] + \
        [160, 300, 182, 120, 175, 350, 160, 260, 95, 75] + [95] * 12 + [125, 250, 530]
PAUSE_MS = [0, 100, 200, 700, 30, 60, 90]
ARGS = {20, 21, 22, 23, 24, 25, 26, 28, 29, 30}


# ---------------------------------------------------------------- synthesizer
class Synth:
    """The manual's 5-channel synthesizer, one sample at a time."""

    def __init__(self):
        self.freq = [0.0] * 6         # register 0 = envelope, 1-5 oscillators
        self.vol = [0] * 6            # 1-5 used
        self.dist = 0                 # register 6, oscillators 4 and 5
        self.master = 96              # register 7
        self.env_ctl = 0b01000000     # register 8: saw, envelope on 1-3
        self.ph = [0.0] * 6
        self.rng = np.random.default_rng(7800)

    def env(self):
        p = self.ph[0]
        return [1.0 - p, 0.5 - 0.5 * math.cos(2 * math.pi * p),
                1.0 - abs(2 * p - 1), 1.0 if p < 0.5 else 0.0][self.env_ctl & 3]

    def sample(self):
        out = [0.0] * 6
        for i in range(6):
            f = self.freq[i]
            if i in (4, 5) and self.dist:
                f += (self.rng.random() - 0.5) * self.dist * 16
            nxt = self.ph[i] + f / RATE
            if i == 0 and nxt >= 1.0 and PITCH_SYNC and self.env_ctl & 0x40:
                # A new pitch period: restart the enveloped oscillators, so the
                # output repeats exactly at the pitch, as the real chip's does.
                for k in (1, 2, 3):
                    self.ph[k] = 0.0
            self.ph[i] = nxt % 1.0
            out[i] = math.sin(2 * math.pi * self.ph[i])
        m1 = sum(out[i] * self.vol[i] for i in (1, 2, 3)) / 63
        m2 = sum(out[i] * self.vol[i] for i in (4, 5)) / 62
        e = self.env()
        if self.env_ctl & 0x40:
            m1 *= e
        if self.env_ctl & 0x80:
            m2 *= 0.5 + 0.5 * e
        return (m1 + m2) * self.master / 127


# ---------------------------------------------------------------- MSA model
class SpeakJet:
    def __init__(self):
        self.s = Synth()
        self.out = []
        self.reset()

    def reset(self):
        self.last = None
        self.volume, self.speed, self.pitch, self.bend = 96, 114, 88, 5
        self.next_rate, self.next_stress = 1.0, 0

    def run(self, ms, targets=None, glide_ms=30):
        """Run ms, gliding oscillators 1-5 towards targets (freqs, vols)."""
        n = max(1, int(ms * RATE / 1000))
        start_f = self.s.freq[1:6]
        start_v = self.s.vol[1:6]
        g = max(1, int(glide_ms * RATE / 1000))
        for k in range(n):
            if targets:
                t = min(1.0, (k + 1) / g)
                tf, tv = targets
                for i in range(5):
                    self.s.freq[i + 1] = start_f[i] + (tf[i] - start_f[i]) * t
                    self.s.vol[i + 1] = start_v[i] + (tv[i] - start_v[i]) * t
            self.out.append(self.s.sample())

    def bendf(self, f):
        return f * (0.8 + 0.04 * self.bend)

    def voice(self, f, a, noise_hz=0, noise_vol=0, dist=0, half_env=False):
        self.s.freq[0] = self.pitch
        self.s.env_ctl = ENV_WAVE | 0x40 | (0x80 if half_env else 0)
        self.s.dist = dist
        fs = [self.bendf(x) for x in f] + [min(3999, noise_hz), min(3999, noise_hz * 1.1)]
        nv = int(noise_vol * NOISE_LEVEL)
        return fs, list(a) + [nv, nv // 2]

    def speed_factor(self):
        # Length against the default speed (114). SPEED_K = 0: 114 / speed.
        if SPEED_K:
            return math.exp(-SPEED_K * (self.speed - 114))
        return 114 / max(1, self.speed)

    def dur(self, ms):
        r = ms * STRETCH * self.speed_factor() * self.next_rate
        return r

    def allophone(self, name):
        if name in GLIDES:
            a, b, ms = GLIDES[name]
            d = self.dur(ms) * LEN_GLIDE
            ta, tb = T[a], T[b]
            self.run(d * 0.4, self.voice(ta[2], ta[3]), 25)
            self.run(d * 0.6, self.voice(tb[2], tb[3]), d * 0.5)
            return
        typ, ms, f, a, nhz, nvol, dist = T[name]
        if self.next_stress:
            # STRESS pulls formants towards IY, RELAX towards a central vowel
            tgt = T["IY"][2] if self.next_stress > 0 else T["AX"][2]
            f = [x + (y - x) * 0.25 for x, y in zip(f, tgt)]
        d = self.dur(ms) * (LEN_STOP if typ in ("S", "P") else LEN_FRIC if typ in ("F", "Z")
                            else LEN_LIQUID if typ == "N" or name in LIQUIDS else LEN_VOWEL)
        self.prev_type, self.cur_type = getattr(self, "cur_type", None), typ
        if name == self.last and REPEAT_PLAIN:
            # The same sound again has no transition to make: the manual's length.
            d = self.dur(ms)
        self.last = name
        if typ in ("V", "N"):
            # After a voiced stop the voice fades in over ~60 ms (Gorf's "Gorf":
            # about 120 ms from 16 dB under to full); otherwise 30 ms.
            after_stop = self.prev_type == "S"
            self.run(d, self.voice(f, a), 60 if after_stop else 30)
        elif typ in ("F", "Z"):
            self.run(d, self.voice(f, a, nhz, nvol, dist, half_env=(typ == "Z")), 15)
        elif typ in ("S", "P"):
            # closure (silent, or a low voice bar), burst, then aspiration
            bar = [8, 0, 0] if typ == "S" else [0, 0, 0]
            self.run(30 * STRETCH * LEN_STOP * self.speed_factor(), self.voice(f, bar), 10)
            self.run(max(8, d * 0.3), self.voice(f, [0, 0, 0], nhz, 24, dist), 3)
            asp = 10 if typ == "P" else 0
            self.run(d * 0.7, self.voice(f, [6, 4, 2] if typ == "S" else [0, 0, 0],
                                         1500, asp, 255), 15)

    def effect(self, n):
        ms = self.dur(FX_MS[n])
        s = self.s
        s.env_ctl, s.dist = 0, 0
        if 40 <= n <= 51:                                   # DTMF: the standard pairs
            lo, hi = DTMF[n - 40]
            self.run(ms, ([lo, hi, 0, 0, 0], [20, 20, 0, 0, 0]), 2)
        elif 20 <= n <= 29:                                 # beeps
            f = 600 + 180 * (n - 20)
            self.run(ms, ([f, 0, 0, 0, 0], [28, 0, 0, 0, 0]), 2)
        elif 10 <= n <= 19:                                 # alarms: two-tone warbles and sweeps
            steps = max(2, int(ms / 60))
            for k in range(steps):
                f = (900 if k % 2 else 1300) if n % 2 else 700 + 1600 * k / steps
                self.run(ms / steps, ([f, f * 1.5, 0, 0, 0], [22, 10, 0, 0, 0]), 3)
        elif n < 10:                                        # robot: buzz on a fixed chord
            s.freq[0], s.env_ctl = 70 + 12 * n, 3 | 0x40
            self.run(ms, ([400 + 60 * n, 1200, 2400, 0, 0], [24, 14, 8, 0, 0]), 5)
        elif n == 52:                                       # sonar ping
            self.run(10, ([1000, 0, 0, 0, 0], [31, 0, 0, 0, 0]), 2)
            self.run(ms, ([1000, 0, 0, 0, 0], [0, 0, 0, 0, 0]), ms)
        elif n == 53:                                       # pistol shot
            s.dist = 255
            self.run(5, ([0, 0, 0, 1500, 2500], [0, 0, 0, 31, 31]), 1)
            self.run(ms, ([0, 0, 0, 800, 1200], [0, 0, 0, 0, 0]), ms)
        elif n == 54:                                       # "WOW"
            self.allophone("WW"); self.allophone("AYWW")
        else:                                               # biological: placeholder warble
            for k in range(4):
                self.run(ms / 4, ([300 + 200 * k, 900, 0, 0, 0], [20, 10, 0, 0, 0]), 10)

    def pause(self, ms):
        f, v = self.s.freq[1:6], [0] * 5
        self.run(max(ms * STRETCH, 10) if ms else 10, (f, v), 10)

    def play(self, codes):
        it = iter(codes)
        for c in it:
            if c in ARGS:
                x = next(it, 0)
                if c == 20: self.volume = x; self.s.master = min(127, x)
                elif c == 21: self.speed = x
                elif c == 22: self.pitch = x
                elif c == 23: self.bend = x
                elif c == 26:
                    nxt = next(it, None)
                    for _ in range(x): self.play([nxt])
                elif c == 30: self.pause(10 * x)
                continue
            if c <= 6: self.pause(PAUSE_MS[c])
            elif c == 7: self.next_rate = 0.5; continue
            elif c == 8: self.next_rate = 1.5; continue
            elif c == 14: self.next_stress = 1; continue
            elif c == 15: self.next_stress = -1; continue
            elif c == 31: self.reset(); self.s.master = 96
            elif 128 <= c <= 199: self.allophone(ALLOPHONES[c - 128])
            elif 200 <= c <= 254: self.effect(c - 200)
            self.next_rate, self.next_stress = 1.0, 0
        self.pause(0)                                       # auto-silence


def main():
    global STRETCH
    global ENV_WAVE
    global LPF_HZ
    global PITCH_SYNC
    while len(sys.argv) > 2 and sys.argv[1] in ("--stretch", "--env", "--lpf", "--sync"):
        if sys.argv[1] == "--stretch": STRETCH = float(sys.argv[2])
        elif sys.argv[1] == "--lpf": LPF_HZ = float(sys.argv[2])
        elif sys.argv[1] == "--sync": PITCH_SYNC = int(sys.argv[2])
        else: ENV_WAVE = int(sys.argv[2])
        del sys.argv[1:3]
    out = sys.argv[1]
    if len(sys.argv) > 3 and sys.argv[2] == "--log":
        codes = [int(m.group(1)) for m in re.finditer(r"VOX [\d.]+ ms:\s+(\d+)", open(sys.argv[3], errors="replace").read())]
    else:
        codes = [int(x, 0) for x in sys.argv[2:]]
    sj = SpeakJet()
    sj.play(codes)
    x = np.array(sj.out)
    if LPF_HZ:
        w0 = 2 * math.pi * LPF_HZ / RATE; al = math.sin(w0) / (2 * 0.707); c = math.cos(w0)
        b0, b1, a0, a1, a2 = (1 - c) / 2, 1 - c, 1 + al, -2 * c, 1 - al
        y = np.zeros_like(x); x1 = x2 = y1 = y2 = 0.0
        for i, v in enumerate(x):
            o = (b0 * v + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2) / a0
            x2, x1, y2, y1 = x1, v, y1, o; y[i] = o
        x = y
    x = np.clip(x * 0.8, -1, 1)
    # 8,192 Hz, as the chip; most players resample it themselves
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(x)}h", *(int(s * 32767) for s in x)))
    print(f"{out}: {len(codes)} codes, {len(x) / RATE:.2f} s")


if __name__ == "__main__":
    main()
