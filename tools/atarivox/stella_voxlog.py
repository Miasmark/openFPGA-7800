#!/usr/bin/env python3
"""Log the bytes a 2600 game sends its AtariVox, in real time, through the
Stella emulator (docs/ATARIVOX.md). Much faster than tb_load +voxlog, which
runs at a few seconds of game time an hour; the two agree byte for byte.

Stella writes AtariVox bytes to a serial port; a socat pseudo-terminal pair
stands in for it:

  socat pty,raw,echo=0,link=p0 pty,raw,echo=0,link=p1 &
  stella_voxlog.py p1 vox.log [--snap] &
  stella -rc AtariVox -avoxport "$(readlink p0)" game.bin

The log has tb_load's format ("VOX t ms: n $hh", t from the logger's
start), so sjsynth.py --log reads it. A "SNAP" line marks each phrase
start (a byte after more than 1 s of quiet); with --snap the logger also
presses F12 there (xdotool, $DISPLAY) so Stella saves a screenshot of what
the game was doing when it spoke.

Our own code, MIT licence.
"""
import os
import subprocess
import sys
import termios
import time


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    snap = "--snap" in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    fd = os.open(args[0], os.O_RDONLY | os.O_NOCTTY)
    attr = termios.tcgetattr(fd)
    attr[0] = attr[1] = 0                              # raw in and out
    attr[3] &= ~(termios.ICANON | termios.ECHO)
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    t0, last = time.time(), -9.0
    with open(args[1], "w", buffering=1) as out:
        while True:
            data = os.read(fd, 64)
            t = time.time() - t0
            if t - last > 1.0:
                out.write("SNAP\n")
                if snap:
                    subprocess.Popen(["xdotool", "key", "F12"])
            last = t
            for c in data:
                out.write("VOX %.3f ms: %3d $%02x\n" % (t * 1000, c, c))


if __name__ == "__main__":
    main()
