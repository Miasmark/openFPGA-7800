#!/usr/bin/env python3
"""A synthetic SpeakJet test phrase for sim/atarivox/run.sh (our own codes,
no game data), on stdout as run.sh's byte file: hex bytes, one per line.

  python3 sim/atarivox/make_phrase.py > phrase.txt
  sim/atarivox/run.sh phrase.txt +ms=2000

It takes the place of a phrase copied from a game (removed 2026-11-16)
and exercises what that phrase did, the way a game's title phrase drives
the engine:
  - the controls with a value: volume (20), speed (21), pitch (22) and bend
    (23), set at the start and changed again before the first sound;
  - a pitch change before almost every allophone: a staircase up (84 to
    204) on a vowel and down (210 to 90) on a liquid, so the engine
    retunes between allophones, across the whole range a game uses;
  - a speed change in the middle of the phrase, a pause 0 between its two
    halves, and a pause 2 at its end;
  - among the allophones (codes 128-199): vowels, an affricate, voiced and
    unvoiced fricatives, a nasal, a liquid and two plosives.
75 bytes, about 2.4 s of speech: +ms=2000 runs the test to its end (run.sh's
default, 400 ms after the last byte, stops at about 1.3 s). The output
never changes: the phrase is a fixed list, built the same way on every run.

SPDX-License-Identifier: MIT
"""
import sys

VOLUME, SPEED, PITCH, BEND = 20, 21, 22, 23
PAUSE0, PAUSE2 = 0, 2


def phrase():
    c = [VOLUME, 100, SPEED, 85, PITCH, 80, BEND, 4,   # the settings
         SPEED, 95, BEND, 6, VOLUME, 120]              # changed before the first sound
    c += [0xB6, 0x84]                                  # CH (an affricate), AY
    for p in range(84, 205, 15):                       # the staircase up, 9 steps, on AW
        c += [PITCH, p, 0x88]
    c += [0xC4, PAUSE0]                                # EK (a plosive), then pause 0
    c += [SPEED, 110, 0xA8, 0x8D]                      # faster: ZH (a voiced fricative), NE (a nasal)
    for p in range(210, 89, -20):                      # the staircase down, 7 steps, on LO (a liquid)
        c += [PITCH, p, 0x92]
    c += [SPEED, 90, 0xBB, 0xC7, PAUSE2]               # back to speed: SE (unvoiced), PO (a plosive), the end
    assert all(0 <= b <= 255 for b in c)
    return c


def main():
    if len(sys.argv) > 1:
        sys.exit(__doc__)
    sys.stdout.write("".join(f"{b:02x}\n" for b in phrase()))


if __name__ == "__main__":
    main()
