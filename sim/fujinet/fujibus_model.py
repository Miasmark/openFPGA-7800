#!/usr/bin/env python3
"""FujiBus packets, written from the format's description (fujinet-firmware
pico/common/src/fujibus.c and lib/bus/rs232): an independent model for
tb_fujinet.sv's checks.

Packet: device, command, length (2 bytes LE, the unescaped total), checksum,
then the first descriptor; more descriptors while bit 7 is set; the
parameter values (LE); then the payload. One descriptor per parameter: size 1
-> 0x01, 2 -> 0x05, 4 -> 0x07. Checksum: 8-bit sum with end-around carry
over the packet with its checksum byte 0. SLIP: END C0, ESC DB; C0 -> DB DC,
DB -> DB DD; a frame starts and ends with END.
"""

END, ESC, ESC_END, ESC_ESC = 0xC0, 0xDB, 0xDC, 0xDD
FIELD_SIZE = [0, 1, 1, 1, 1, 2, 2, 4]
FIELD_COUNT = [0, 1, 2, 3, 4, 1, 2, 1]


def checksum(pkt):
    c = 0
    for b in pkt:
        c += b
        c = (c >> 8) + (c & 0xFF)
    return c


def packet(device, command, params=(), payload=b"", descr=None):
    """params: (size, value) pairs. descr: explicit descriptor bytes (for
    replies with grouped fields); default one per parameter."""
    if descr is None:
        descr = []
        for i, (size, _) in enumerate(params):
            d = {1: 0x01, 2: 0x05, 4: 0x07}[size]
            if i + 1 < len(params):
                d |= 0x80
            descr.append(d)
    body = bytearray(descr[1:])
    for size, value in params:
        body += value.to_bytes(size, "little")
    body += bytes(payload)
    pkt = bytearray([device, command, 0, 0, 0, descr[0] if descr else 0]) + body
    pkt[2:4] = len(pkt).to_bytes(2, "little")
    pkt[4] = checksum(pkt)
    return bytes(pkt)


def slip(pkt):
    out = bytearray([END])
    for b in pkt:
        if b == END:
            out += bytes([ESC, ESC_END])
        elif b == ESC:
            out += bytes([ESC, ESC_ESC])
        else:
            out.append(b)
    out.append(END)
    return bytes(out)


def frame(*a, **k):
    return slip(packet(*a, **k))


def unslip(raw):
    """The packet in one raw frame (from its first END to the next)."""
    i = raw.index(END) + 1
    out = bytearray()
    esc = False
    while raw[i] != END:
        b = raw[i]
        if esc:
            out.append(END if b == ESC_END else ESC)
            esc = False
        elif b == ESC:
            esc = True
        else:
            out.append(b)
        i += 1
    return bytes(out)
