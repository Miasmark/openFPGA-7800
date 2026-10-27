#!/usr/bin/env python3
"""Disassemble a 7800 cartridge's 6502 code with py65 (pip install py65),
to read what a game is doing at the addresses tb_load +cpuprobe prints.

    python3 -I tools/d78.py GAME.a78                 # vectors, then code at RESET
    python3 -I tools/d78.py GAME.a78 F123 40         # 40 instructions from $F123
    python3 -I tools/d78.py GAME.a78 8000 20 --bank 3

The payload (after the 128-byte header) is mapped so that it ends at $FFFF,
as a cart of 48 KiB or less sits. For a SuperGame cart that is its last
48 KiB: banks 5-7 of 8 at $4000-$FFFF, with the last bank fixed at
$C000; --bank N puts 16 KiB bank N at $8000 instead.
"""
import argparse
from py65.devices.mpu6502 import MPU
from py65.disassembler import Disassembler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("addr", nargs="?", help="hex start address (default RESET)")
    ap.add_argument("count", nargs="?", type=int, default=32)
    ap.add_argument("--bank", type=int, help="16 KiB bank mapped at $8000")
    a = ap.parse_args()

    d = open(a.image, "rb").read()
    if d[1:10] == b"ATARI7800":
        d = d[128:]
    mem = bytearray(0x10000)
    top = d[-0xC000:]
    mem[0x10000 - len(top):] = top
    if a.bank is not None:
        mem[0x8000:0xC000] = d[a.bank * 0x4000:(a.bank + 1) * 0x4000]

    word = lambda x: mem[x] | mem[x + 1] << 8
    print(f"NMI ${word(0xFFFA):04X}  RESET ${word(0xFFFC):04X}  IRQ ${word(0xFFFE):04X}")
    pc = int(a.addr, 16) if a.addr else word(0xFFFC)
    mpu = MPU(memory=mem)
    dis = Disassembler(mpu)
    for _ in range(a.count):
        n, text = dis.instruction_at(pc)
        raw = " ".join(f"{mem[(pc + i) & 0xFFFF]:02X}" for i in range(n))
        print(f"${pc:04X}  {raw:<9} {text}")
        pc = (pc + n) & 0xFFFF


if __name__ == "__main__":
    main()
