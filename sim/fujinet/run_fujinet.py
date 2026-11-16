#!/usr/bin/env python3
"""tb_fujinet: fujinet_mailbox.sv (the FujiNet mailbox and its FujiBus link)
against a 6502 bus model and a FujiNet model. Writes the FujiNet's replies,
builds and runs the bench, and checks every frame the core sent against
fujibus_model.py byte for byte.
  sim/fujinet/run_fujinet.py      (WORK=dir, VERILATOR=bin optional)
Prints the bench's checks and "FUJINET pass" or "FUJINET FAIL".
SPDX-License-Identifier: MIT
"""
import os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fujibus_model import frame, packet, slip

FPGA = os.path.join(HERE, "..", "..", "src", "fpga", "core")
WORK = os.environ.get("WORK", os.path.join(HERE, "..", "work", "fujinet"))
V = os.environ.get("VERILATOR", "verilator")
os.makedirs(WORK, exist_ok=True)

# The FujiNet's replies, in the order the bench sends them
bad = bytearray(packet(0x70, 0x06, payload=b"\x01\x02\x03"))
bad[4] ^= 0x01
replies = [
    b"\xFF\x00\x12" + frame(0x70, 0x06, params=[(2, 0x1234), (1, 0xC0)],
                            payload=bytes((i * 7 + 3) & 255 for i in range(300)),
                            descr=[0x85, 0x01]),
    slip(bytes(bad)),
    frame(0xFF, 0x4F, payload=bytes([0]) + (40960).to_bytes(4, "little")),
    frame(0x70, 0x15),
    frame(0x70, 0x06, payload=bytes((i * 11) & 255 for i in range(1100))),
    frame(0x71, 0x15),
]
with open(os.path.join(WORK, "replies.txt"), "w") as f:
    for r in replies:
        f.write("%d %s\n" % (len(r), " ".join("%02x" % b for b in r)))

# The frames the core must send
expect = [
    frame(0x70, 0xC4),
    frame(0x70, 0xE2, params=[(1, 3), (2, 0xC0DB), (4, 0xDEADC0DB)],
          payload=bytes((i * 37 + 0xC0) & 255 for i in range(40))),
    frame(0x70, 0xC4),
    frame(0x70, 0xF8, params=[(1, 0), (1, 1)]),
    frame(0xFF, 0x15),
    frame(0x70, 0xC4),
    frame(0x70, 0xC4),
    frame(0x71, 0x4F, params=[(4, 0x04030201)]),
    frame(0x70, 0xC4, params=[(1, 7)], payload=b"AB"),
]

src = [os.path.join(FPGA, "fujinet_uart.sv"), os.path.join(FPGA, "fujinet_mailbox.sv"),
       os.path.join(HERE, "tb_fujinet.sv")]
b = subprocess.run([V, "--binary", "--timing", "-O2", "-Wno-fatal", "-Wno-lint",
                    "--top-module", "tb_fujinet", "-Mdir", os.path.join(WORK, "obj"),
                    "-o", "vtb"] + src, capture_output=True, text=True)
if b.returncode:
    print(b.stdout[-3000:], b.stderr[-3000:])
    print("FUJINET FAIL (build)")
    sys.exit(1)
r = subprocess.run([os.path.join(WORK, "obj", "vtb")], cwd=WORK, capture_output=True, text=True)
out = r.stdout
open(os.path.join(WORK, "run.log"), "w").write(out + r.stderr)
ok = True
got = {}
for line in out.splitlines():
    if line.startswith("CHECK") or line.startswith("NOTE") or line.startswith("TB_FUJINET"):
        print(line)
        if line.startswith("CHECK FAIL") or line == "TB_FUJINET timeout":
            ok = False
    m = re.match(r"TXFRAME (\d+) (.*)", line)
    if m:
        got[int(m.group(1))] = bytes(int(x, 16) for x in m.group(2).split())
for i, e in enumerate(expect):
    g = got.get(i)
    if g == e:
        print("FRAME ok %d (%d bytes)" % (i, len(e)))
    else:
        ok = False
        print("FRAME FAIL %d\n  got    %s\n  expect %s" % (i, g.hex(" ") if g else None, e.hex(" ")))
if len(got) != len(expect):
    ok = False
    print("FRAME FAIL count %d, expected %d" % (len(got), len(expect)))
if "TB_FUJINET frames" not in out:
    ok = False
print("FUJINET pass" if ok else "FUJINET FAIL")
sys.exit(0 if ok else 1)
