#!/usr/bin/env python3
"""Print an A78 header as the core reads it (atari7800_pocket.sv's loader,
cart.sv's flags): what the core will map for this file. Check this before
debugging a game; many dumps carry wrong headers (docs/DEVELOPING.md,
"A78 headers").

    python3 -I tools/a78_info.py GAME.a78
"""
import sys

FLAGS = {
    0: "POKEY at $4000", 1: "SuperGame", 2: "SuperGame RAM at $4000",
    3: "ROM at $4000", 4: "bank 6 at $4000", 5: "banked RAM at $6000",
    6: "POKEY at $450", 7: "mirror RAM at $4000", 8: "Activision",
    9: "Absolute", 10: "POKEY at $440", 11: "YM2151 at $460", 12: "Souper",
    13: "BankSets", 14: "BankSets RAM", 15: "POKEY at $800",
}
CONTROLLERS = {
    0: "none", 1: "joystick", 2: "light gun", 3: "paddles", 4: "trak-ball",
    5: "2600 joystick", 6: "2600 driving", 7: "2600 keypad", 8: "ST mouse",
    9: "Amiga mouse", 10: "AtariVox/SaveKey", 11: "SNES2Atari",
}


def main(path):
    d = open(path, "rb").read()
    if len(d) < 128 or d[1:10] != b"ATARI7800":
        print(f"{path}: no A78 header; the core takes it as a 2600 image")
        return
    ver = d[0]
    size = int.from_bytes(d[49:53], "big")
    flags = int.from_bytes(d[53:55], "big")
    title = d[17:49].split(b"\0")[0].decode("latin-1").strip()
    print(f"title      {title!r}")
    print(f"version    {ver}")
    print(f"ROM size   {size} (${size:X}); file payload {len(d) - 128}"
          + ("" if size == len(d) - 128 else "  <- differs"))
    names = [FLAGS[b] for b in range(16) if flags >> b & 1]
    print(f"cart type  ${flags:04X}: {', '.join(names) or 'plain ROM'}")
    for port, b in (("port 1", d[55]), ("port 2", d[56])):
        print(f"{port}     {b} ({CONTROLLERS.get(b, 'unknown')})")
    print(f"region     {d[57]} ({'PAL' if d[57] & 1 else 'NTSC'})")
    save = d[58]
    sv = [n for bit, n in ((0, "HSC"), (1, "SaveKey/AtariVox")) if save >> bit & 1]
    print(f"save       {save} ({', '.join(sv) or 'none'})")
    print(f"XM         {d[63]}")
    if ver >= 4:
        print(f"mapper     {d[64]} (v4)")
    if d[56] == 10 or save & 2:
        print("note       SaveKey Auto turns on; the AtariVox voice follows it")


if __name__ == "__main__":
    for p in sys.argv[1:] or sys.exit(__doc__):
        main(p)
