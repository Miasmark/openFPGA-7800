#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Synthetic DPC+ and CDF-family images for the daria_fe directed tests.

Everything in an image is generated here: the driver area holds only what
upstream's detect2600 needs to classify the image and what its RAM init
copies (the signature words, the CDF stream tables and waveform pointers),
the ARM side is armenc.call_routine (hand-encoded Thumb/ARM), and the 6507
side is assembled by asm6502 from the test sources in tests.py. No game data.

  mkimg.py OUTDIR [TEST ...]     write OUTDIR/<test>.bin and OUTDIR/<test>.meta
                                 (all tests when none is named)

Layouts (upstream mapper_dpcplus/mapper_cdf, arm_mapper_ram_init):
  DPC+   32 KB. $0000-$0BFF driver (CRC32 of it picks revision 1 when it is
         $A08CFB13: we forge 4 bytes to get it), 6507 bank b at $0C00+b*$1000
         (reset bank 5), display data $6C00-$7BFF (RAM $0C00-$1BFF at init),
         NOTE frequency table $7C00-$7FFF (RAM $1C00). Call entry $0C08
         (Thumb), stack $40001FFC. "DPC+" twice anywhere.
  CDF    32 KB (or 64 KB). $0000-$07FF driver, copied to RAM $0000-$07FF at
         init (RAM above it is cleared): the stream pointer and increment
         tables (CDF0 words $1B8/$1DA, CDF1 $028/$04A, CDFJ/J+ $026/$049) and
         the waveform pointers (CDF0 byte $7F0, others $1B0). 6507 bank b at
         $1000+b*$1000 (reset bank 6), CDFJ+ at $0800+b*$1000 (reset bank 0).
         Entry $0808 Thumb, stack $40001FFC; CDFJ+ entry/stack from the words
         at $17F8/$17F4. Revision from aligned words in the first 2 KB:
         "CDF\\0" x3 (CDF0), "CDF\\1" x3 (CDF1), "CDFJ" x3 (CDFJ),
         "PLUS" "CDFJ" 1 (CDFJ+); options LDX $135200A2, LDY $135200A0,
         fetch offset $E24220xx, audio size scan $E3C55D3E then $4000xxxx.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm6502          # noqa: E402
import armenc           # noqa: E402

CRC_EQ = [(0x41, 0x41000000), (0xC3, 0xC3000000), (0xC7, 0xC7000000), (0x8E, 0x8E000000),
          (0x5D, 0x5D000000), (0xFB, 0xFB000000), (0xF6, 0xF6000000), (0xAD, 0xAD000000),
          (0x1B, 0x1B000001), (0x36, 0x36000002), (0x2D, 0x2D000004), (0x1B, 0x1B000008),
          (0x77, 0x77000010), (0xEE, 0xEE000020), (0xDC, 0xDC000040), (0xB8, 0xB8000080),
          (0x31, 0x31000100), (0x62, 0x62000200), (0xC4, 0xC4000400), (0x88, 0x88000800),
          (0x10, 0x10001000), (0x20, 0x20002000), (0x01, 0x01004000), (0x43, 0x43008000),
          (0x86, 0x86010000), (0x0C, 0x0C020000), (0x59, 0x59040000), (0xB2, 0xB2080000),
          (0x64, 0x64100000), (0xC8, 0xC8200000), (0x90, 0x90400000), (0x20, 0x20800000)]
DPC_REV1_CRC = 0xA08CFB13


def _par(x):
    return bin(x).count('1') & 1


def crc_detect(data):
    """detect2600's nextCRC32_D8 chain from 0 (its dpc_driver_crc)."""
    c = 0
    for d in data:
        n = 0
        for i, (dm, cm) in enumerate(CRC_EQ):
            n |= (_par(d & dm) ^ _par(c & cm)) << i
        c = n
    return c


def forge_crc(buf, lo, hi, pos, target):
    """Set the 4 bytes at buf[pos:pos+4] so crc_detect(buf[lo:hi]) == target.
    The CRC (initial 0, no final xor) is linear over GF(2) in the data."""
    buf[pos:pos + 4] = bytes(4)
    base = crc_detect(buf[lo:hi])
    cols = []
    for bit in range(32):
        t = bytearray(hi - lo)
        t[pos - lo + bit // 8] = 1 << (bit % 8)
        cols.append(crc_detect(t))
    want = base ^ target
    # Gaussian elimination: find x (32 bits) with sum x_i * cols[i] = want
    rows = []           # (pivot vector, combination)
    for i, v in enumerate(cols):
        comb = 1 << i
        for pv, pc in rows:
            if v & (pv & -pv):
                v ^= pv
                comb ^= pc
        if v:
            rows.append((v, comb))
    x = 0
    v = want
    for pv, pc in rows:
        if v & (pv & -pv):
            v ^= pv
            x ^= pc
    assert v == 0, 'CRC not reachable'
    buf[pos:pos + 4] = x.to_bytes(4, 'little')
    assert crc_detect(buf[lo:hi]) == target


# 6507-side names
TIA = dict(VSYNC=0x00, VBLANK=0x01, WSYNC=0x02, RSYNC=0x03, COLUBK=0x09, CXCLR=0x2C,
           INTIM=0x284, TIM64T=0x296, CXM0P=0x00)
DPC = dict(RANDOM0NEXT=0x1000, RANDOM0PRIOR=0x1001, RANDOM1=0x1002, RANDOM2=0x1003,
           RANDOM3=0x1004, AMPLITUDE=0x1005, DF0DATA=0x1008, DF0DATAW=0x1010,
           DF0FRACDATA=0x1018, DF0FLAG=0x1020, DF0FRACLOW=0x1028, DF0FRACHI=0x1030,
           DF0FRACINC=0x1038, DF0TOP=0x1040, DF0BOT=0x1048, DF0LOW=0x1050, FASTFETCH=0x1058,
           PARAMETER=0x1059, CALLFUNCTION=0x105A, WAVEFORM0=0x105D, DF0PUSH=0x1060,
           DF0HI=0x1068, RRESET=0x1070, RWRITE0=0x1071, NOTE0=0x1075, DF0WRITE=0x1078)
CDF = dict(DSWRITE=0x1FF0, DSPTR=0x1FF1, SETMODE=0x1FF2, CALLFN=0x1FF3)
# RIOT RAM markers (fe_dir_mon reads them at the end)
MARK = dict(M_DONE=0xFF, M_ERR=0xFE, M_FRAME=0xFD, M_RES=0xF0)

KERNEL_HEAD = """
start:  SEI
        CLD
        LDX #$EF
        TXS
        LDA #0
        LDX #$80
clrram: STA 0,X
        INX
        BNE clrram
"""

FRAME = """
frame:  LDA #$FE
        STA WSYNC
        STA VSYNC
        STA WSYNC
        STA WSYNC
        STA WSYNC
        LDA #$FD
        STA VSYNC
{body}
        LDX #256-{lines}
fl_ln:  STA WSYNC
        INX
        BNE fl_ln
        INC M_FRAME
        JMP frame
"""
# (The kernel uses no immediate below $E0: in CDF fast mode an LDA # (and on
# CDFJ+ with the options, LDX #/LDY #) with an operand in the stream range is
# a stream fetch, and in DPC+ fast fetch an LDA # below $28 is a register.)


class Img:
    def __init__(self, kind, rev=0, size=32768, sf=False, ldx=False, ldy=False, foff=None,
                 asize=None, scripts=None, fill=0x00):
        self.kind = kind            # 'dpc' or 'cdf'
        self.rev = rev
        self.size = size
        self.rom = bytearray([fill]) * size
        self.sf = sf
        self.ldx, self.ldy, self.foff, self.asize = ldx, ldy, foff, asize
        self.scripts = scripts if scripts is not None else [[]]
        self.syms = {}
        self.syms.update(TIA)
        self.syms.update(MARK)
        self.syms.update(DPC if kind == 'dpc' else CDF)
        self.used = {}              # rom offset -> owner, to catch overlaps
        if kind == 'dpc':
            self.reset_bank = 5
            self.entry = 0x0C08
            self.cnt_addr = 0x40000800
        else:
            self.jplus = rev == 3
            self.reset_bank = 0 if self.jplus else 6
            self.entry = 0x0400 if self.jplus else 0x0808
            self.cnt_addr = 0x400003F0
            if rev == 0:
                self.ptr_base, self.inc_base, self.nstreams, self.wave_base = 0x1B8 * 4, 0x1DA * 4, 34, 0x7F0
            elif rev == 1:
                self.ptr_base, self.inc_base, self.nstreams, self.wave_base = 0x028 * 4, 0x04A * 4, 34, 0x1B0
            else:
                self.ptr_base, self.inc_base, self.nstreams, self.wave_base = 0x026 * 4, 0x049 * 4, 35, 0x1B0
            self.amp_stream = 35 if rev >= 2 else 34

    # ---- placement
    def put(self, off, data, owner='?'):
        for i, b in enumerate(data):
            o = off + i
            if o in self.used and self.used[o] != owner:
                raise ValueError('ROM $%05X: %s overlaps %s' % (o, owner, self.used[o]))
            self.used[o] = owner
            self.rom[o] = b

    def put32(self, off, v, owner='?'):
        self.put(off, (v & 0xFFFFFFFF).to_bytes(4, 'little'), owner)

    def bank_base(self, b):
        if self.kind == 'dpc':
            return 0x0C00 + b * 0x1000
        return (0x0800 if self.jplus else 0x1000) + b * 0x1000

    def asm(self, bank, text, org=0x1000, syms=None):
        s = dict(self.syms)
        if syms:
            s.update(syms)
        code, labs = asm6502.assemble(text, s, org)
        base = self.bank_base(bank)
        for a, v in code.items():
            assert 0x1000 <= a <= 0x1FFF, hex(a)
            self.put(base + (a & 0xFFF), [v], 'bank%d' % bank)
        return labs

    def program(self, bank, init, body, lines=8, extra='', syms=None, reset=True):
        """The standard program in `bank`: clear RAM, init, then a frame loop
        (VSYNC, body, `lines` WSYNC lines, M_FRAME++). Returns the labels."""
        text = KERNEL_HEAD + init + FRAME.format(body=body, lines=lines) + extra
        labs = self.asm(bank, text, syms=syms)
        if reset:
            self.vector(bank, labs['start'])
        return labs

    def vector(self, bank, addr):
        base = self.bank_base(bank)
        self.put(base + 0xFFC, [addr & 0xFF, (addr >> 8) & 0xFF], 'vec%d' % bank)

    # ---- the scheme's driver area and header
    def _driver(self):
        if self.kind == 'dpc':
            self.put(0x0010, b'DPC+ synthetic driver area: DPC+', 'sig')
            # the ARM call routine
            code, labs = armenc.call_routine(self.entry, self.cnt_addr, self.scripts)
            self.put(self.entry, code, 'arm')
            self.arm_end = self.entry + len(code)
            if self.sf:
                forge_crc(self.rom, 0, 0xC00, 0x0BF0, DPC_REV1_CRC)
                self.used.update({o: 'crc' for o in range(0xBF0, 0xBF4)})
            elif crc_detect(self.rom[0:0xC00]) == DPC_REV1_CRC:
                self.rom[0x0BF0] ^= 1
            return
        # CDF family: signature words (aligned, first 2 KB)
        if self.rev == 0:
            sig = [0x00464443] * 3
        elif self.rev == 1:
            sig = [0x01464443] * 3
        elif self.rev == 2:
            sig = [0x4A464443] * 3
        else:
            sig = [0x53554C50, 0x4A464443, 0x00000001]
        for i, w in enumerate(sig):
            self.put32(0x0010 + 4 * i, w, 'sig')
        o = 0x0020
        if self.ldx:
            self.put32(o, 0x135200A2, 'sig')
            o += 4
        if self.ldy:
            self.put32(o, 0x135200A0, 'sig')
            o += 4
        if self.foff is not None:
            self.put32(o, 0xE2422000 | self.foff, 'sig')
            o += 4
        if self.asize is not None:
            self.put32(o, 0xE3C55D3E, 'sig')
            self.put32(o + 4, 0x40000000 | self.asize, 'sig')
            o += 8
        code, labs = armenc.call_routine(self.entry, self.cnt_addr, self.scripts)
        self.put(self.entry, code, 'arm')
        self.arm_end = self.entry + len(code)
        if self.jplus:
            self.put32(0x17F4, 0x40007FFC, 'jplus')       # stack
            self.put32(0x17F8, self.entry | 1, 'jplus')   # entry

    def cdf_tables(self, ptrs, incs, waves=None):
        """Initial stream pointers/increments (lists, index -> value) and the
        three waveform pointers, in the driver area (RAM after init)."""
        for i, v in ptrs.items():
            self.put32(self.ptr_base + 4 * i, v, 'tbl')
        for i, v in incs.items():
            self.put32(self.inc_base + 4 * i, v, 'tbl')
        for i, v in (waves or {}).items():
            self.put32(self.wave_base + 4 * i, v, 'wave')

    def ptr_value(self, ram_off, frac=0):
        """A stream pointer that addresses display RAM byte $800 + ram_off."""
        if self.jplus:
            return (ram_off << 16) | (frac & 0xFFFF)
        return (ram_off << 20) | (frac & 0xFFFFF)

    def build(self):
        self._driver()
        return bytes(self.rom)


def classify(rom):
    """A Python model of the detect2600 decisions the tests rely on."""
    size = len(rom)

    def count(p):
        n, i = 0, rom.find(p)
        while i >= 0:
            n += 1
            i = rom.find(p, i + 1)
        return n
    words = [int.from_bytes(rom[i:i + 4], 'little') for i in range(0, min(2048, size), 4)]
    has_cdf = (count(b'CDF') >= 3 or count(b'PLUSCDFJ') >= 1) and size in (32768, 65536, 131072, 262144, 524288)
    if has_cdf:
        plus = any(words[i] == 0x53554C50 and words[i + 1] == 0x4A464443 and words[i + 2] == 1
                   for i in range(len(words) - 2))
        cj = sum(1 for w in words if w == 0x4A464443)
        c0 = sum(1 for w in words if w == 0x00464443)
        rev = 3 if plus else (2 if cj >= 3 else (0 if c0 >= 3 else 1))
        return 23, rev
    if count(b'DPC+') >= 2 and size == 32768:
        return 21, 1 if crc_detect(rom[0:3072]) == DPC_REV1_CRC else 0
    return None, None


def main():
    import tests
    out = sys.argv[1]
    names = sys.argv[2:] or list(tests.TESTS)
    os.makedirs(out, exist_ok=True)
    for n in names:
        img, meta = tests.TESTS[n]()
        rom = img.build()
        bs, rev = classify(rom)
        exp = meta['scheme']
        if (bs, rev) != exp:
            raise SystemExit('%s: classified as %s, expected %s' % (n, (bs, rev), exp))
        with open(os.path.join(out, n + '.bin'), 'wb') as f:
            f.write(rom)
        with open(os.path.join(out, n + '.meta'), 'w') as f:
            f.write('scheme %d %d\n' % exp)
            f.write('frames %d\n' % meta.get('frames', 10))
            f.write('args %s\n' % ' '.join(meta.get('args', [])))
            for k, op, v in meta.get('need', []):
                f.write('need %s %s %d\n' % (k, op, v))
            f.write('desc %s\n' % meta.get('desc', ''))
        print('%-14s %6d bytes  scheme %d rev %d' % (n, len(rom), bs, rev))


if __name__ == '__main__':
    main()
