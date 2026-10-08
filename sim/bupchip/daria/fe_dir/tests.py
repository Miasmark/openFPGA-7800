# SPDX-License-Identifier: MIT
"""The daria_fe directed tests (design.md 12.1; bench.md 7.9 item 7).

Each test is a function returning (Img, meta). meta:
  scheme  (force_bs, revision) that detect2600 must report
  frames  how many frames to run (+frames)
  args    extra plusargs (injections, latencies)
  need    [(bin, op, value)]: fe_dir_mon coverage bins the run must reach;
          a test whose feature never fires fails ('s1:<bin>': required only
          in stage-1 builds, where the bin exists)
  desc    one line
"""
from mkimg import Img
from armenc import OP_W8, OP_W16, OP_W32, OP_FSET, OP_ADD32, OP_COPY, OP_FILL, OP_FADD

TESTS = {}


def test(fn):
    TESTS[fn.__name__] = fn
    return fn


def need(*items):
    return [tuple(x) for x in items]


@test
def smoke_dpc():
    img = Img('dpc', scripts=[[], [(OP_W8, 0x40000C10, 0x5A)]])
    img.program(5, init="""
        LDA #$10
        STA DF0LOW
        LDA #0
        STA DF0HI
""", body="""
        LDA DF0DATA
        STA $80
        LDA #$FF
        STA CALLFUNCTION
        LDA #$10
        STA DF0LOW
        LDA DF0DATA
        STA $81
        INC M_DONE
""")
    return img, dict(scheme=(21, 0), frames=4,
                     need=need(('call_accept', '>=', 3), ('dpc_rd_f1_i0', '>=', 6), ('dir_marker', '>=', 3)),
                     desc='DPC+ boot, frames, a call that writes display RAM')


@test
def smoke_cdf():
    img = Img('cdf', rev=2, scripts=[[(OP_FILL, 0x40000800, 0x04030201, 64)]])
    img.cdf_tables({0: img.ptr_value(0)}, {0: 0x100})
    img.program(6, init="""
        LDA #$FF
        STA CALLFN
        LDA #0
        STA SETMODE
""", body="""
        LDA #0
        STA $80
        LDA #0
        STA $81
        INC M_DONE
""")
    return img, dict(scheme=(23, 2), frames=4,
                     need=need(('call_accept', '>=', 1), ('cdf_fetch_s0', '>=', 6), ('dir_marker', '>=', 3)),
                     desc='CDFJ boot, a fill call, stream 0 fetches')


# ---------------------------------------------------------------- helpers
_lab = [0]


def L(prefix='l'):
    _lab[0] += 1
    return '%s_%d' % (prefix, _lab[0])


_chk = [0]


def chk(v, src=None):
    """Compare A (or load `src` first) with v. A mismatch calls ckfail, which
    counts it in M_ERR and keeps the failing check's address and value in RIOT
    $F0-$F2 (dir_res0..2); mkimg writes each check's label to the .meta."""
    ok = L('ok')
    k = _chk[0]
    _chk[0] += 1
    t = ''
    if src:
        t += '        LDA %s\n' % src
    t += '        CMP #$%02X\n        BEQ %s\nck_%d_%02X:\n        JSR ckfail\n%s:\n' % (v, ok, k, v & 0xFF, ok)
    return t


def sta(addr, v, r='X'):
    """Store a constant with LDX #/STX (DPC+ fast fetch arms only on LDA #)."""
    return '        LD%s #$%02X\n        ST%s $%04X\n' % (r, v & 0xFF, r, addr)


def dpc_set(i, low=None, hi=None, top=None, bot=None, fraclow=None, frachi=None, fracinc=None):
    """Program DPC+ fetcher i (absolute writes; LDA # operands kept >= $28 or
    used only while fast fetch is off)."""
    t = ''
    if top is not None: t += sta(0x1040 + i, top)
    if bot is not None: t += sta(0x1048 + i, bot)
    if low is not None: t += sta(0x1050 + i, low)
    if hi is not None: t += sta(0x1068 + i, hi)
    if fracinc is not None: t += sta(0x1038 + i, fracinc)
    if fraclow is not None: t += sta(0x1028 + i, fraclow)
    if frachi is not None: t += sta(0x1030 + i, frachi)
    return t


def bins_all(fmt, *ranges):
    import itertools
    return [(fmt % combo, '>=', 1) for combo in itertools.product(*ranges)]


# ---------------------------------------------------------------- DPC+
def _dpc_regs(sf):
    img = Img('dpc', sf=sf, scripts=[[]])
    # a RAM byte $EA (NOP) for the fast-fetch-on-a-data-byte opcode substitution
    init = ''
    for i in range(8):
        init += dpc_set(i, low=(i * 0x31) & 0xFF, hi=i & 0xF, top=0x40 + i * 8, bot=0x20 + i * 4,
                        fracinc=0x10 * i + 3, fraclow=0x80 + i, frachi=i & 0xF)
    body = ''
    # 1. every write register, each with a value from the frame counter mixed in
    #    (straight-line code; PUSH/WRITE/HI/LOW of each fetcher included)
    body += '        LDA M_FRAME\n        STA $80\n'
    for a in range(0x1028, 0x1080):
        g, ix = (a - 0x1028) >> 3, a & 7
        if a == 0x1058:            # FASTFETCH: off here (tested below)
            body += sta(a, 0xFF)
        elif a == 0x1059:          # PARAMETER: ten writes, the pointer stops at 8
            for k in range(10):
                body += sta(a, 0x50 + k)
        elif a == 0x105A:          # CALLFUNCTION: 0 (pointer reset), 3 and $FD (nothing)
            body += sta(a, 0x00) + sta(a, 0x03) + sta(a, 0xFD)
        else:
            body += '        LDA $80\n        EOR #$%02X\n        STA $%04X\n' % ((a * 7) & 0xFF, a)
    # 2. every read register $1000-$1027, twice
    for r in range(2):
        for a in range(0x1000, 0x1028):
            body += '        LDA $%04X\n' % a
    # 3. wraps: DF5 counter 0 -> PUSH writes $FFF; DF6 $FFF -> WRITE wraps; DF7 $FFF
    #    -> DATA read wraps; DF4 fractional near $FFFFF -> FRACDATA wraps
    body += dpc_set(5, low=0x00, hi=0x00) + sta(0x1065, 0x77)          # PUSH at counter-1 = $FFF
    body += '        LDA $100D\n' + chk(0x77)                            # DF5 now $FFF: DATA reads it
    body += dpc_set(6, low=0xFF, hi=0x0F) + sta(0x107E, 0x66)          # WRITE at $FFF, counter -> 0
    body += sta(0x107E, 0x67)                                          # WRITE at 0
    body += dpc_set(7, low=0xFF, hi=0x0F) + '        LDA $100F\n        LDA $100F\n'   # DATA wrap
    body += dpc_set(4, fracinc=0xFF, fraclow=0xFF, frachi=0x0F)
    body += '        LDA $101C\n' * 4                                  # FRACDATA wrap
    # DF6 back to $FFF: DATA reads $66, then (wrapped) $67
    body += dpc_set(6, low=0xFF, hi=0x0F) + '        LDA $100E\n' + chk(0x66) + '        LDA $100E\n' + chk(0x67)
    # 4. window flags: DF0 top $40 bottom $20: counters $30 (in), $50 (out), $40, $20
    for c in (0x30, 0x50, 0x40, 0x20, 0x41, 0x1F):
        body += dpc_set(0, low=c, top=0x40, bot=0x20) + '        LDA $1020\n        LDA $1010\n'
        body += dpc_set(3, low=c, top=0x40, bot=0x20) + '        LDA $1023\n        LDA $1013\n'
    # 5. fast fetch: on, LDA # $00..$27 (every register through the operand),
    #    $28 and $FF (not registers), then an $A9 data byte arming it and a PHP
    #    opcode ($08 < $28) substituted by DF0DATA's byte (an $EA NOP placed there)
    body += dpc_set(0, low=0xC0, hi=0x0E) + sta(0x1078, 0xEA) + dpc_set(0, low=0xC0, hi=0x0E)
    body += sta(0x1058, 0x00)
    for v in range(0x28):
        body += '        LDA #$%02X\n' % v
    body += '        LDA #$28\n        LDA #$FF\n'
    body += dpc_set(0, low=0xC0, hi=0x0E)
    body += '        LDA a9byte\n        PHP\n        NOP\n'     # PHP becomes the NOP from RAM
    body += '        TSX\n        TXA\n' + chk(0xEF)      # the PHP did not run: SP unchanged
    body += sta(0x1058, 0xFF)
    body += '        INC M_DONE\n'
    extra = '\na9byte: .byte $A9\n'
    img.program(5, init=init, body=body, lines=4, extra=extra)
    req = (bins_all('dpc_rd_f%d_i%d', range(5), range(8)) +
            [b for b in bins_all('dpc_wr_g%d_i%d', range(11), range(8))] +
            bins_all('dpc_ffsub_f%d_i%d', range(5), range(8)) +
            need(('dpc_arm_data', '>=', 1), ('dpc_ffsub_opcode', '>=', 1), ('dpc_push_wrap', '>=', 1),
                 ('dpc_write_wrap', '>=', 1), ('dpc_data_wrap', '>=', 1), ('dpc_frac_wrap', '>=', 1),
                 ('dpc_flag_ff', '>=', 1), ('dpc_flag_00', '>=', 1), ('dpc_dataw_ff', '>=', 1),
                 ('dpc_dataw_00', '>=', 1), ('dpc_fraclow_sf%d' % int(sf), '>=', 8),
                 ('dpc_param_ptr8', '>=', 1), ('dpc_param_ptr7', '>=', 1), ('dpc_cf_0', '>=', 1),
                 ('dpc_cf_other', '>=', 2), ('dpc_note', '>=', 3), ('dir_marker', '>=', 5),
                 ('dir_selfcheck_err', '==', 0)))
    return img, dict(scheme=(21, int(sf)), frames=6, need=req,
                     desc='every DPC+ register, fast fetch (incl. on a data byte), wraps, '
                          'window flags, PARAMETER to 8, FRACLOW sf=%d' % int(sf))


@test
def dpc_regs():
    return _dpc_regs(False)


@test
def dpc_regs_sf():
    return _dpc_regs(True)


def dpc_svc_call(fn, p0, p1, p2, p3):
    """CALLFUNCTION 0 (parameter pointer reset), four PARAMETERs, CALLFUNCTION fn."""
    return (sta(0x105A, 0) + sta(0x1059, p0) + sta(0x1059, p1) + sta(0x1059, p2) +
            sta(0x1059, p3) + sta(0x105A, fn))


def dpc_display():
    return bytes(((i * 37 + 11) ^ (i >> 5)) & 0xFF for i in range(0x1000))


def dpc_readback(i, start, n):
    """Read n bytes of display RAM from counter `start` through DFiDATA: L1 then
    compares daria_fe's own RAM (through its fetcher) with upstream's, byte by
    byte, so a service's result is checked in daria_fe's memory too."""
    return dpc_set(i, low=start & 0xFF, hi=start >> 8) + ('        LDA $%04X\n' % (0x1008 + i)) * n


@test
def dpc_svc():
    img = Img('dpc', scripts=[[]])
    disp = dpc_display()
    rom = lambda off: (disp[off - 0x6C00] if 0x6C00 <= off < 0x7C00 else None)
    body = ''
    # a. copy: ROM $0C00+$6000 = $6C00 (display data) -> DF1 counter $100
    body += dpc_set(1, low=0x00, hi=0x01) + dpc_svc_call(1, 0x00, 0x60, 1, 0x40)
    body += dpc_set(1, low=0x00, hi=0x01) + '        LDA $1009\n' + chk(disp[0])
    body += '        LDA $1009\n' + chk(disp[1])
    body += dpc_readback(1, 0x100, 0x40)
    # b. fill $5A -> DF2 $200, $80 bytes
    body += dpc_set(2, low=0x00, hi=0x02) + dpc_svc_call(2, 0x5A, 0, 2, 0x80)
    body += dpc_set(2, low=0x7F, hi=0x02) + '        LDA $100A\n' + chk(0x5A)
    body += '        LDA $100A\n' + chk(disp[0x280])
    body += dpc_readback(2, 0x200, 0x82)
    # c. count 0 (fill): nothing written, the service still runs
    body += dpc_set(2, low=0x00, hi=0x02) + dpc_svc_call(2, 0x33, 0, 2, 0)
    body += dpc_set(2, low=0x00, hi=0x02) + '        LDA $100A\n' + chk(0x5A)
    # d. copy with the ROM offset >= $7400: count 0 ($7400 and $FFFF)
    body += dpc_set(3, low=0x00, hi=0x03) + dpc_svc_call(1, 0x00, 0x74, 3, 0x20)
    body += dpc_svc_call(1, 0xFF, 0xFF, 3, 0x20)
    body += dpc_set(3, low=0x00, hi=0x03) + '        LDA $100B\n' + chk(disp[0x300])
    body += dpc_readback(3, 0x300, 0x20)
    # e. destination clamp: counter $FF8 (8 left), fill $40 -> 8; copy at $FFC -> 4
    body += dpc_set(4, low=0xF8, hi=0x0F) + dpc_svc_call(2, 0x77, 0, 4, 0x40)
    body += dpc_set(4, low=0xFF, hi=0x0F) + '        LDA $100C\n' + chk(0x77)
    body += '        LDA $100C\n' + chk(disp[0])          # wrapped to $000: untouched
    body += dpc_set(4, low=0xFC, hi=0x0F) + dpc_svc_call(1, 0x10, 0x60, 4, 0x40)
    body += dpc_set(4, low=0xFC, hi=0x0F) + '        LDA $100C\n' + chk(disp[0x10])
    body += dpc_readback(4, 0xFF0, 0x14)
    # f. source clamp: offset $73F0 -> 16 bytes (to $7FFF), $73FF -> 1
    body += dpc_set(5, low=0x00, hi=0x05) + dpc_svc_call(1, 0xF0, 0x73, 5, 0x40)
    body += dpc_set(5, low=0x00, hi=0x05) + dpc_svc_call(1, 0xFF, 0x73, 5, 0x40)
    body += dpc_readback(5, 0x500, 0x12)
    # g. the RMW pair: INC $105A reads the ROM byte $01 there, writes $01 (copy)
    #    then $02 (fill, latched while the copy runs); DEC $105A: $01 then $00
    body += dpc_set(6, low=0x00, hi=0x06)
    body += sta(0x105A, 0) + sta(0x1059, 0x00) + sta(0x1059, 0x60) + sta(0x1059, 6) + sta(0x1059, 0x10)
    body += '        INC $105A\n'
    body += dpc_set(6, low=0x00, hi=0x06) + '        LDA $100E\n' + chk(0x00)
    body += dpc_readback(6, 0x600, 0x11)
    body += dpc_set(6, low=0x00, hi=0x06)
    body += sta(0x105A, 0) + sta(0x1059, 0x20) + sta(0x1059, 0x60) + sta(0x1059, 6) + sta(0x1059, 0x10)
    body += '        DEC $105A\n'
    body += dpc_set(6, low=0x00, hi=0x06) + '        LDA $100E\n' + chk(disp[0x20])
    body += dpc_readback(6, 0x600, 0x11)
    # h. services during audio: voice 0's waveform 8 reads RAM $0D00-$0D1F, voice 1's
    #    9; DF7 at $100 so each 255-byte fill covers both; 24 fills a frame
    body += sta(0x105D, 8) + sta(0x105E, 9) + sta(0x1075, 0x30) + sta(0x1076, 0x51)
    body += '        LDY #24\nsvloop:\n'
    body += dpc_set(7, low=0x00, hi=0x01) + sta(0x105A, 0)
    body += '        TYA\n        STA $1059\n' + sta(0x1059, 0) + sta(0x1059, 7) + sta(0x1059, 0xFF)
    body += sta(0x105A, 2) + '        LDA $1005\n        DEY\n        BNE svloop\n'
    body += dpc_readback(7, 0x100, 0x20) + dpc_readback(7, 0x1F0, 0x10)
    body += '        INC M_DONE\n'
    img.put(img.bank_base(5) + 0x05A, [0x01], 'rmw')
    img.program(5, init='', body=body, lines=4)
    req = need(('dpc_svc_copy', '>=', 8), ('dpc_svc_fill', '>=', 30), ('dpc_svc_req0', '>=', 1),
               ('dpc_svc_cnt0', '>=', 3), ('dpc_svc_offclamp', '>=', 2), ('dpc_svc_srcclamp', '>=', 2),
               ('dpc_svc_dstclamp', '>=', 2), ('dpc_svc_while_dma', '>=', 2), ('dpc_svc_rmw', '>=', 2),
               ('svc_dma', '>=', 40), ('svc_aud_overlap', '>=', 3), ('dir_marker', '>=', 5),
               ('dir_selfcheck_err', '==', 0))
    return img, dict(scheme=(21, 0), frames=7, need=req,
                     desc='DPC+ copy/fill: every clamp, count 0, the RMW pair, services over the audio')


@test
def dpc_note():
    img = Img('dpc', scripts=[[]])
    body = sta(0x105D, 0) + sta(0x105E, 1) + sta(0x105F, 2) + sta(0x1058, 0)
    # every NOTE register written every 4 cycles, AMPLITUDE read between, the
    # loop length changing with the frame so the tick sweeps the NOTE phase
    body += '''        LDA M_FRAME
        AND #7
        TAX
        INX
dly:    DEX
        BNE dly
        LDY #0
nloop:  STY $1075
        STY $1076
        LDA $1005
        STY $1077
        LDA #$05
        INY
        BNE nloop
        INC M_DONE
'''
    img.program(5, init='', body=body, lines=4)
    req = need(('dpc_note', '>=', 3000), ('dpc_note_tick_c+3', '>=', 2), ('dpc_note_tick_c+4', '>=', 2),
               ('dpc_note_tick_c+5', '>=', 2), ('dpc_note_busy', '>=', 5), ('aud_note_capture', '>=', 1000),
               ('dpc_ffsub_f0_i5', '>=', 1000), ('dir_marker', '>=', 10))
    return img, dict(scheme=(21, 0), frames=12, need=req,
                     desc='DPC+ NOTE with ticks at C+3/4/5 and NOTEs during a refresh; AMPLITUDE reads')


@test
def rmw_call_dpc():
    img = Img('dpc', scripts=[[], [(OP_W8, 0x40000C40, 0x11)], []])
    body = '''        LDY #40
rloop:  INC $105A
        LDA $1005
        DEY
        BNE rloop
        LDY #20
rloop2: DEC $105A
        DEY
        BNE rloop2
        INC M_DONE
'''
    img.put(img.bank_base(5) + 0x05A, [0xFE], 'rmw')
    img.program(5, init='', body=body, lines=4)
    req = need(('dpc_cf_while_call_busy', '>=', 40), ('call_accept', '>=', 200), ('dir_marker', '>=', 3))
    return img, dict(scheme=(21, 0), frames=4, need=req,
                     desc='DPC+ INC/DEC $105A over $FE: a second call latched while the first runs')


# ---------------------------------------------------------------- CDF family
def pattern(n, seed=0):
    return bytes((((i + seed) * 29 + 7) ^ ((i + seed) >> 3) ^ 0x5A) & 0xFF for i in range(n))


def cdf_data(img, data, ram_off):
    """Place `data` in the image's free ROM area; return the COPY entry that puts
    it at display RAM $800 + ram_off (ARM address 0x40000800 + ram_off)."""
    off, mx = img.data_area()
    used = getattr(img, '_data_used', 0)
    data = bytes(data) + bytes((-len(data)) % 4)
    assert used + len(data) <= mx, 'data area full'
    img.put(off + used, data, 'data')
    img._data_used = used + len(data)
    return (OP_COPY, 0x40000800 + ram_off, off + used, len(data) // 4)


def call_cdf():
    """CALLFN $FF on the CDF family (LDA #$FF is outside every stream range)."""
    return '        LDA #$FF\n        STA CALLFN\n'


def _cdf_fetch(rev, foff=None, ldx=False, ldy=False, asize=None, size=32768, digital=False):
    img = Img('cdf', rev=rev, size=size, ldx=ldx, ldy=ldy, foff=foff, asize=asize)
    n = img.nstreams                 # 34 (CDF0/1) or 35 (CDFJ, CDFJ+)
    amp = img.amp_stream
    data = pattern(n * 16, rev)
    incs = [0x100, 0x080, 0x000, 0x200, 0x0C0, 0x100, 0x040, 0x180]
    ptrs = {i: img.ptr_value(i * 16, frac=(0x30000 if i % 5 == 1 else 0)) for i in range(n)}
    img.cdf_tables(ptrs, {i: incs[i % len(incs)] for i in range(n)},
                   {0: 0x40000800 + 0x40, 1: 0x40000800 + 0x80, 2: 0x40001000})
    if asize is not None:
        for v in range(3):
            img.put32(asize + 4 * v, [0x0D80, 0x0C00, 0x0A80][v], 'size')
    img.scripts = [[cdf_data(img, data, 0),
                    (OP_FSET, 11, 0x01234567), (OP_FSET, 12, 0x00ABCDEF), (OP_FSET, 13, 0x07654321)]]
    o = foff or 0
    ops = list(range(max(0, o - 2), o)) + list(range(o, o + amp + 3))
    body = ''
    for k in ops:
        body += '        LDA #$%02X\n' % k
    if img.jplus:
        for k in ops:
            body += '        LDX #$%02X\n' % k
        for k in ops:
            body += '        LDY #$%02X\n' % k
    else:
        body += '        LDX #$%02X\n        LDY #$%02X\n' % (o + 3, o + 4)
    # stream 2 has increment 0: always its first byte
    body += '        LDA #$%02X\n' % (o + 2) + chk(data[2 * 16])
    # the amplitude operand twice more, and a slow-mode stretch (no substitution)
    body += '        LDA #$%02X\n        LDA #$%02X\n' % (o + amp, o + amp)
    body += '        LDA #$F1\n        STA SETMODE\n        LDA #$%02X\n        LDA #$%02X\n' % (o, o + 1)
    body += '        LDA #$%02X\n        STA SETMODE\n' % (0x00 if digital else 0xF0)
    body += '        INC M_DONE\n'
    init = call_cdf() + '        LDA #$%02X\n        STA SETMODE\n' % (0x00 if digital else 0xF0)
    img.program(img.reset_bank, init=init, body=body, lines=4)
    req = [('cdf_fetch_s%d' % i, '>=', 3) for i in range(n)] + need(
        ('cdf_amp', '>=', 3 * (3 if img.jplus and ldx and ldy else 1)), ('dir_marker', '>=', 5),
        ('dir_selfcheck_err', '==', 0), ('call_accept', '>=', 1), ('aud_ptr_capture', '>=', 50))
    if foff is not None:
        req += need(('cdf_fetch_offset', '>=', 30))
    if img.jplus and ldx:
        req += need(('cdf_arm_a2', '>=', 30))
    if img.jplus and ldy:
        req += need(('cdf_arm_a0', '>=', 30))
    if not (img.jplus and ldx):
        req += need(('cdf_arm_a2', '==', 0))
    if not (img.jplus and ldy):
        req += need(('cdf_arm_a0', '==', 0))
    if asize is not None:
        req += need(('aud_size_capture', '>=', 50))
    req += need(('cdf_ff_outrange', '>=', 5))
    return img, dict(scheme=(23, rev), frames=6, need=req,
                     desc='CDF rev %d stream fetches over every operand (offset %s, LDX %d, LDY %d), '
                          'the amplitude operand, out-of-range operands, slow mode' % (rev, foff, ldx, ldy))


@test
def cdf_fetch_cdf0():
    return _cdf_fetch(0)


@test
def cdf_fetch_cdf1():
    return _cdf_fetch(1)


@test
def cdf_fetch_cdf1_off():
    return _cdf_fetch(1, foff=0x40)


@test
def cdf_fetch_cdfj():
    return _cdf_fetch(2, asize=0x0300)


@test
def cdf_fetch_cdfj_xy():
    return _cdf_fetch(2, foff=0x10, ldx=True, ldy=True)        # flags without CDFJ+: no LDX/LDY fetch


@test
def cdf_fetch_cdfjp():
    return _cdf_fetch(3, asize=0x0300)


@test
def cdf_fetch_cdfjp_xy():
    return _cdf_fetch(3, foff=0x80, ldx=True, ldy=True, asize=0x0300)


# ---------------------------------------------------------------- hotspots
def hot_addr(img, b):
    """The hotspot that selects bank b."""
    if img.kind == 'dpc':
        return 0x1FF6 + b
    if img.jplus:
        return 0x1FF4 if b == 0 else 0x1FF4 + b
    return 0x1FF4 if b == 6 else 0x1FF5 + b


def hot_bank(img, a):
    if img.kind == 'dpc':
        return a - 0x1FF6
    if img.jplus:
        return 0 if a in (0x1FF4, 0x1FFB) else a - 0x1FF4
    return 6 if a in (0x1FF4, 0x1FFB) else a - 0x1FF5


def _hotspot(kind, rev=0):
    img = Img(kind, rev=rev, scripts=[[]])
    hot = list(range(0x1FF6, 0x1FFC)) if kind == 'dpc' else list(range(0x1FF4, 0x1FFC))
    main = img.reset_bank
    b = ''
    for a in hot:                                   # reads
        b += '        LDA $%04X\n' % a + chk(hot_bank(img, a), 'BANKID')
    for a in reversed(hot):                         # writes
        b += '        STA $%04X\n' % a + chk(hot_bank(img, a), 'BANKID')
    for a in hot:                                   # BIT (read), INC (read, write, write)
        b += '        BIT $%04X\n' % a + chk(hot_bank(img, a), 'BANKID')
        b += '        INC $%04X\n' % a + chk(hot_bank(img, a), 'BANKID')
    for a in reversed(hot):                         # indexed read and write (dummy read first)
        b += '        LDX #$%02X\n        LDA $1FF0,X\n' % (a - 0x1FF0) + chk(hot_bank(img, a), 'BANKID')
        b += '        STA $1FF0,X\n' + chk(hot_bank(img, a), 'BANKID')
    # the chain through the hotspot area: an operand at a hotspot that is
    # substituted (DPC+ fast fetch register / CDF stream) switches nothing
    if kind == 'dpc':
        on, off = sta(0x1058, 0), sta(0x1058, 0xFF)
        entry, tbank = 0x1FF5, 3
    elif img.jplus:            # bank 0's $1FF4-$1FFB hold the CDFJ+ entry and stack words:
        on, off = '        LDA #$F0\n        STA SETMODE\n', '        LDA #$F1\n        STA SETMODE\n'
        entry, tbank = 0x1FF5, 5   # enter from bank 1 at $1FF5
        on += '        STA $1FF5\n'
    else:
        on, off = '        LDA #$F0\n        STA SETMODE\n', '        LDA #$F1\n        STA SETMODE\n'
        entry, tbank = 0x1FF4, 3
    b += '        LDX #0\n        STX $82\n' + on + '        JMP $%04X\n' % entry
    b += 'chainT:\n' + chk(tbank, 'BANKID') + off
    b += '        LDA $82\n        BNE chdone\n        INC $82\n' + (
        '        STA $1FF5\n' if img.jplus else '') + '        JMP $%04X\n' % entry
    b += 'chdone:\n        LDA $%04X\n' % hot_addr(img, main) + chk(main, 'BANKID')
    b += '        INC M_DONE\n'
    labs = img.program_all(init='', body=b, lines=4)
    T = labs['chainT']
    for bk in range(img.nbanks()):
        base = img.bank_base(bk)
        if kind == 'dpc':      # $1FF5 LDA #$05 (AMPLITUDE through fast fetch), $1FF7 JMP chainT
            img.put(base + 0xFF5, [0xA9, 0x05, 0x4C, T & 0xFF, T >> 8], 'chain')
        elif not img.jplus:    # $1FF4 LDA #$00 (stream 0 in fast mode), $1FF6 JMP chainT
            img.put(base + 0xFF4, [0xA9, 0x00, 0x4C, T & 0xFF, T >> 8], 'chain')
        elif bk != 0:          # CDFJ+: the same from $1FF5
            img.put(base + 0xFF5, [0xA9, 0x00, 0x4C, T & 0xFF, T >> 8], 'chain')
    p = 'dpc' if kind == 'dpc' else 'cdf'
    req = need(('%s_hot_rd' % p, '>=', 100), ('%s_hot_wr' % p, '>=', 100), ('%s_bank_change_rd' % p, '>=', 50),
               ('%s_bank_change_wr' % p, '>=', 20), ('%s_hot_sub' % p, '>=', 5), ('dir_marker', '>=', 5),
               ('dir_selfcheck_err', '==', 0))
    return img, dict(scheme=(21 if kind == 'dpc' else 23, rev), frames=6, need=req,
                     desc='bank switching on hotspot reads, writes, BIT, INC, indexed; no switch on a '
                          'substituted operand at a hotspot')


@test
def hotspot_dpc():
    return _hotspot('dpc')


@test
def hotspot_cdf1():
    return _hotspot('cdf', 1)


@test
def hotspot_cdfj():
    return _hotspot('cdf', 2)


@test
def hotspot_cdfjp():
    return _hotspot('cdf', 3)


# ---------------------------------------------------------------- CDF fast jumps
def _cdf_jump(rev):
    img = Img('cdf', rev=rev)
    J = rev >= 2
    main = img.reset_bank
    JB = 2 if img.jplus else 1
    nb = 7
    hs = lambda bk: '        STA $%04X\n' % hot_addr(img, bk)
    b = call_cdf()                                        # script 1+: re-point streams 33/34
    b += '        JMP $0000\n'                            # (a) fast jump, stream 33 -> T1
    b += 'T1:\n' + hs(JB) + '        JMP $1FFD\n'         # (b) JB's $1FFD: JMP $0000, operands $xFFE/$xFFF
    b += 'T2:\n' + chk(JB, 'BANKID') + '        LDA $1FFD\n'  # (d) data-read arming at $xFFD
    if img.jplus:
        b += hs(1)                                        # bank 0's $1FF4-$1FFB are the entry/stack words
    else:
        b += hs(main)
    b += '        JMP $1FF5\n'                            # (c) operands at the hotspots $1FF6/$1FF7
    tb = 1 if img.jplus else 0
    b += 'T3:\n' + chk(tb, 'BANKID')
    b += hs(4) + '        LDA $1FFE\n'                    # (d) $xFFE: lookahead into bank 5's first byte
    b += hs(5) + '        LDA $1FFF\n'                    # (d) $xFFF: lookahead into bank 6's first bytes
    b += hs(main)
    if not img.jplus:
        b += '        LDA $1FFE\n'                        # (d) image $7FFE: never in the map
    b += '        LDA #$4C\n        .byte $00, $00, $00\n'  # (e) arming on an operand: the BRK opcode
    #                                                       becomes the stream's $2C (BIT abs), lo from it
    if J:
        b += '        JMP $0001\n'                        # (a) stream 34 -> T4
        b += 'T4:\n'
    b += '        JMP T5\nT5:\n'                          # (f) a plain JMP: no map
    b += '        LDA #$F1\n        STA SETMODE\n' + hs(JB) + '        LDA $1FFD\n'   # (g) slow: no arming
    b += hs(main) + '        LDA #$F0\n        STA SETMODE\n'
    b += '        INC M_DONE\n'
    init = call_cdf() + '        LDA #$F0\n        STA SETMODE\n'
    labs = img.program_all(init=init, body=b, lines=4)
    ov = {JB: {0x1FFD: [0x4C, 0x00, 0x00]}, 4: {0x1FFE: [0x4C, 0x00]}, 5: {0x1FFF: [0x4C]}}
    if not img.jplus:
        ov[main] = {0x1FFE: [0x4C, 0x00]}
    for bk, o in ov.items():
        for a, bs in o.items():
            img.put(img.bank_base(bk) + (a & 0xFFF), bs, 'ov')
    for bk in range(nb):
        if img.jplus and bk == 0:
            continue
        img.put(img.bank_base(bk) + 0xFF5, [0x4C, 0x00, 0x00], 'hj')
    lohi = lambda a: [a & 0xFF, a >> 8]
    s33 = lohi(labs['T1']) + lohi(labs['T2']) + lohi(labs['T3']) + [0x2C, 0x80]
    s34 = lohi(labs['T4']) if J else []
    p33 = img.ptr_value(0x400)
    p34 = img.ptr_value(0x500)
    repoint = [(OP_W32, 0x40000000 + img.ptr_base + 4 * 33, p33)]
    if J:
        repoint.append((OP_W32, 0x40000000 + img.ptr_base + 4 * 34, p34))
    img.scripts = [[cdf_data(img, bytes(s33), 0x400)] + ([cdf_data(img, bytes(s34), 0x500)] if J else []),
                   repoint]
    img.cdf_tables({33: p33, 34: p34} if J else {33: p33}, {})
    req = need(('cdf_jarm', '>=', 5 * (4 if J else 3)), ('cdf_jsub_at_ffe', '>=', 5), ('cdf_jsub_at_fff', '>=', 5),
               ('cdf_hot_sub', '>=', 10), ('cdf_jarm_data', '>=', 5 * 4), ('cdf_jarm_at_ffd', '>=', 5),
               ('cdf_jarm_at_ffe', '>=', 5), ('cdf_jarm_at_fff', '>=', 5), ('cdf_jcancel', '>=', 15),
               ('cdf_4c_nomap', '>=', 10), ('dir_marker', '>=', 5), ('dir_selfcheck_err', '==', 0))
    if J:
        req += need(('cdf_jsub_r2_s34', '>=', 5))
    if not img.jplus:
        req += need(('cdf_4c_nomap_7ffe', '>=', 5))
    return img, dict(scheme=(23, rev), frames=6, need=req,
                     desc='CDF fast jumps: stream 33/34, operands at $xFFE/$xFFF and at hotspots, '
                          'data-byte arming at bank ends (lookahead into the next bank), $7FFE, '
                          'an operand arming over a BRK opcode, slow mode')


@test
def cdf_jump_cdf1():
    return _cdf_jump(1)


@test
def cdf_jump_cdfj():
    return _cdf_jump(2)


@test
def cdf_jump_cdfjp():
    return _cdf_jump(3)


@test
def cdf_jump_ffe():
    """A fast JMP whose opcode is at $1FFE: the low operand at $1FFF comes from
    stream 33, the high one from TIA $0000, i.e. the open bus, which upstream
    leaves holding ROM[$1FFF] ($00) after the commit: the 6507 lands in zero
    page RAM. A front end that holds the committed byte would show a different
    open bus there (bench.md 7.5 O1, obus_exposed)."""
    img = Img('cdf', rev=2)
    main = img.reset_bank
    b = call_cdf() + '        STA CXCLR\n        STA $%04X\n' % hot_addr(img, 3) + '        JMP $1FFE\n'
    b += 'back:\n' + chk(main, 'BANKID') + '        INC M_DONE\n'
    init = call_cdf() + '        LDA #$F0\n        STA SETMODE\n'
    ZP = 0xC5      # the stream byte and the routine's address: bits 5-0 non-zero, so the
    #               open bus that supplies the high operand differs between upstream
    #               ($00, ROM[$1FFF]) and a front end holding the committed $C5
    zinit = lambda zp: ''.join('        LDA #$%02X\n        STA $%02X\n' % (v, ZP + i) for i, v in enumerate(zp))
    labs = img.program_all(init=zinit([0xEA] * 6) + init, body=b, lines=4)     # sizes only
    # zero page routine at $C5: STA $1FF4 (back to bank 6), JMP back
    zinit = zinit([0x8D, 0xF4, 0x1F, 0x4C, labs['back'] & 0xFF, labs['back'] >> 8])
    img2 = Img('cdf', rev=2)
    labs2 = img2.program_all(init=zinit + init, body=b, lines=4)
    assert labs2['back'] == labs['back']
    img2.put(img2.bank_base(3) + 0xFFE, [0x4C, 0x00], 'ov')
    p33 = img2.ptr_value(0x400)
    img2.scripts = [[cdf_data(img2, bytes([ZP, ZP]), 0x400)],
                    [(OP_W32, 0x40000000 + img2.ptr_base + 4 * 33, p33)]]
    img2.cdf_tables({33: p33}, {})
    req = need(('cdf_jsub_at_fff', '>=', 5), ('cdf_jarm_at_ffe', '>=', 5), ('dir_marker', '>=', 5),
               ('dir_selfcheck_err', '==', 0))
    return img2, dict(scheme=(23, 2), frames=6, need=req,
                      desc='fast JMP at $1FFE: high operand from the TIA open bus (obus_exposed in stage 1)')


# ---------------------------------------------------------------- DSWRITE / DSPTR
def _dsw(rev):
    img = Img('cdf', rev=rev)
    jp = img.jplus
    stx = lambda a, v: '        LDX #$%02X\n        STX $%04X\n' % (v, a)
    dsptr = lambda off: stx(0x1FF1, (off >> 8) & 0xFF) + stx(0x1FF1, off & 0xFF)
    dsw = lambda v: stx(0x1FF0, v)
    rd = '        LDA #32\n'
    b = ''
    # three writes and their read-back through stream 32 (increment 1 byte)
    b += dsptr(0x100) + dsw(0xA1) + dsw(0xA2) + dsw(0xA3)
    b += dsptr(0x100) + rd + chk(0xA1) + rd + chk(0xA2) + rd + chk(0xA3)
    # RMW on DSWRITE: INC $1FF0 reads the ROM byte $40 there, writes $40 then $41
    b += dsptr(0x110) + '        INC $1FF0\n' + dsptr(0x110) + rd + chk(0x40) + rd + chk(0x41)
    # an indexed store: dummy read of $1FF0 first, then the write
    b += dsptr(0x120) + '        LDX #1\n        LDA #$C6\n        STA $1FEF,X\n' + dsptr(0x120) + rd + chk(0xC6)
    # the end of the offset range: the pointer wraps (CDF: 12 bits, $800+$FFF ->
    # $800; CDFJ+: $800+$7FFF wraps the address to $07FF, then offset 0 -> $800)
    top = 0x7FFF if jp else 0xFFF
    b += dsptr(top) + dsw(0xB1) + dsw(0xB2) + dsptr(top) + rd + chk(0xB1) + rd + chk(0xB2)
    if jp:
        # CDFJ+ only: offsets $7898 and $7930 address $0098 and $0130 (wrapped):
        # stream 0's pointer and stream 3's increment in the tables (tbl_alias).
        # The next call rewrites both words; streams 0 and 3 are not fetched meanwhile.
        b += dsptr(0x7898) + dsw(0xC3) + dsptr(0x7930) + dsw(0x05)
        b += call_cdf()
    b += '        INC M_DONE\n'
    init = call_cdf() + '        LDA #$F0\n        STA SETMODE\n'
    img.program(img.reset_bank, init=init, body=b, lines=4)
    img.put(img.bank_base(img.reset_bank) + 0xFF0, [0x40], 'rmw')
    p0, i3 = img.ptr_value(0x40), 0x100
    img.cdf_tables({0: p0, 32: img.ptr_value(0)}, {3: i3, 32: 0x100})
    restore = [(OP_W32, 0x40000000 + img.ptr_base, p0), (OP_W32, 0x40000000 + img.inc_base + 12, i3)]
    img.scripts = [[], restore]
    req = need(('cdf_dsw', '>=', 5 * 8), ('cdf_dsp', '>=', 5 * 10), ('cdf_fetch_s32', '>=', 5 * 8),
               ('dir_marker', '>=', 5), ('dir_selfcheck_err', '==', 0))
    if jp:
        req += need(('cdf_dsw_tbl', '>=', 10), ('cdf_dsw_wrap', '>=', 15), ('cdf_dsw_below800', '>=', 15))
    return img, dict(scheme=(23, rev), frames=6, need=req,
                     desc='DSWRITE/DSPTR: writes and read-back, RMW and indexed stores, the offset wrap%s' % (
                         ', the CDFJ+ wrap into its own tables (tbl_alias)' if jp else ''))


@test
def dsw_cdf1():
    return _dsw(1)


@test
def dsw_cdfj():
    return _dsw(2)


@test
def dsw_cdfjp():
    return _dsw(3)


# ---------------------------------------------------------------- digital samples
def _digital(rev, slat=None, lat=None):
    img = Img('cdf', rev=rev, size=65536)
    jp = img.jplus
    F = 0x1000 if jp else 0x00100000             # half a sample byte per tick
    amp = img.amp_stream
    img.put(0x8000, pattern(0x8000, 3), 'rom_hi')
    wp = 0x40000000 + img.wave_base
    ramend = 0x40000000 + (0x8000 if jp else 0x2000)
    phase = lambda ptr: [(OP_W32, wp, ptr), (OP_FSET, 8, 0), (OP_FSET, 11, F)]
    img.scripts = [
        [cdf_data(img, pattern(256, 9), 0)] + phase(0x40000800),   # RAM window
        phase(0x00000C00),                                        # ROM below 32 KB
        phase(0x00009000),                                        # ROM at and above 32 KB
        phase(0x20000000),                                        # nowhere: amplitude 0
        phase(0x00007FF8),                                        # ROM crossing $8000
        phase(ramend - 8),                                        # RAM window's end
        phase(0x40000900)]
    b = call_cdf() + '        LDX #0\naloop:  LDA #$%02X\n        STA $80\n        DEX\n        BNE aloop\n' % amp
    b += '        INC M_DONE\n'
    init = '        LDA #$00\n        STA SETMODE\n'
    img.program(img.reset_bank, init=init, body=b, lines=4)
    req = need(('aud_dig_ram', '>=', 30), ('aud_dig_rom_lo', '>=', 30), ('aud_dig_rom_hi', '>=', 30),
               ('aud_dig_none', '>=', 30), ('cdf_amp', '>=', 1500), ('cdf_digital_clk', '>=', 10000),
               ('merge_counter_set', '>=', 5), ('dir_marker', '>=', 7),
               # stage 1: the ROM-route samples compared by fe_dir_mon (the bench masks the
               # >= 32 KB route: dig_rom_lag)
               ('s1:dirchk_rom_lo_n', '>=', 30), ('s1:dirchk_rom_hi_n', '>=', 30))
    args = []
    # the variant's inputs are required bins too (a variant whose arguments are
    # lost runs the default latencies and must fail): tb_lat everywhere,
    # fe_slat in stage-1 builds only ('s1:', dircheck.py)
    if slat is not None:
        args.append('+fe_slat=%d' % slat)
        req += need(('s1:fe_slat', '==', slat))
    if lat is not None:
        args.append('+lat=%d' % lat)
        req += need(('tb_lat', '==', lat))
    return img, dict(scheme=(23, rev), frames=8, need=req, args=args,
                     desc='digital samples from the RAM window, ROM below and above 32 KB (64 KB image), '
                          'nowhere, across $8000 and the RAM end; AMPLITUDE read throughout%s' % (
                              ' (+fe_slat=%s +lat=%s)' % (slat, lat) if args else ''))


@test
def digital_cdfj():
    return _digital(2)


@test
def digital_cdfj_s5():
    return _digital(2, slat=5, lat=5)


@test
def digital_cdfj_s200():
    return _digital(2, slat=200, lat=60)


@test
def digital_cdfjp():
    return _digital(3)


@test
def digital_cdf1_s100():
    return _digital(1, slat=100, lat=30)


# ---------------------------------------------------------------- RMW CALLFUNCTION
@test
def rmw_call_cdf():
    img = Img('cdf', rev=2)
    amp = img.amp_stream
    img.cdf_tables({}, {}, {0: 0x40000800, 1: 0x40000880, 2: 0x40000900})
    img.scripts = [[cdf_data(img, pattern(0x180, 5), 0), (OP_FSET, 11, 0x02000000),
                    (OP_FSET, 12, 0x01100000), (OP_FSET, 13, 0x00733000)],
                   [(OP_FADD, 11, 0x00011111), (OP_FADD, 12, 0x00002345), (OP_FADD, 8, 0x01000000)]]
    b = '''        LDY #0
rloop:  INC CALLFN
        LDA #$%02X
        STA $80
        INY
        BNE rloop
        INC M_DONE
''' % amp
    init = call_cdf() + '        LDA #$F0\n        STA SETMODE\n'
    img.program(img.reset_bank, init=init, body=b, lines=4)
    img.put(img.bank_base(img.reset_bank) + 0xFF3, [0xFE], 'rmw')
    req = need(('cdf_cf_while_call_busy', '>=', 1000), ('call_accept', '>=', 2500), ('tick_m+0', '>=', 1),
               ('tick_in_m_mfe', '>=', 5), ('merge_counter_set', '>=', 1000), ('merge_freq_change', '>=', 1000),
               ('dir_marker', '>=', 5))
    return img, dict(scheme=(23, 2), frames=7, need=req,
                     desc='CDFJ INC $1FF3 over $FE: FE then FF, the second call latched while the first '
                          'runs; returns that change counters and frequencies; ticks at M and in (M, M+6]')


# ---------------------------------------------------------------- RSYNC
def delay(d):
    """Straight-line code taking exactly d CPU cycles (d != 1)."""
    t = ''
    if d % 2:
        t += '        BIT $80\n'
        d -= 3
    t += '        NOP\n' * (d // 2)
    return t


def _rsync(kind, rev=0):
    img = Img(kind, rev=rev, scripts=[[]])
    if kind == 'dpc':
        act = '        LDA $1008\n        LDA #$08\n        STX $1078\n        LDA $1020\n'
        on = sta(0x1058, 0)
    else:
        act = '        LDA #$00\n        STX DSWRITE\n        LDA #$01\n        LDA #$%02X\n' % img.amp_stream
        on = '        LDA #$F0\n        STA SETMODE\n'
    b = ''
    ds = [d for d in range(0, 64) if d != 1]
    n = len(ds) // 2
    # two bodies alternating by frame, so each frame stays short
    b += '        LDA M_FRAME\n        AND #1\n        BEQ half0\n        JMP half1\nhalf0:\n'
    for d in ds[:n]:
        b += '        STA WSYNC\n' + delay(d) + '        STA RSYNC\n' + act
    b += '        JMP rsdone\nhalf1:\n'
    for d in ds[n:]:
        b += '        STA WSYNC\n' + delay(d) + '        STA RSYNC\n' + act
    b += 'rsdone:\n        INC M_DONE\n'
    img.program(img.reset_bank, init=on, body=b, lines=4)
    # In tb_daria's TIA an RSYNC write never misaligns the CPU divider (the
    # reload that follows it always finds pclk_div == 1): E0->latch stays 6, so
    # short_phase1 cannot be reached here; the test records the spacings.
    req = need(('tia_rsync_clk', '>=', 300), ('sp_e0p0_6', '>=', 10000), ('dir_marker', '>=', 6))
    return img, dict(scheme=(21, 0) if kind == 'dpc' else (23, rev), frames=8, need=req,
                     desc='mid-line RSYNC at every cycle position of a line, cartridge commits right '
                          'after (the spacings are recorded: no short phase arises in this TIA)')


@test
def rsync_dpc():
    return _rsync('dpc')


@test
def rsync_cdfj():
    return _rsync('cdf', 2)


# ---------------------------------------------------------------- resets and pause
def _busy_dpc():
    """A DPC+ program doing a little of everything each frame: a call, a fill
    and a copy, NOTEs, fetcher reads and writes, AMPLITUDE reads."""
    img = Img('dpc', scripts=[[(OP_W8, 0x40000C20, 0x99)], [(OP_W32, 0x40000C40, 0x01020304)]])
    b = sta(0x105D, 8) + sta(0x1075, 0x40) + sta(0x1076, 0x21)
    b += '        LDA #$FF\n        STA $105A\n'                                  # a call
    b += dpc_set(1, low=0x00, hi=0x01) + dpc_svc_call(2, 0x3C, 0, 1, 0xFF)          # a 255-byte fill
    b += dpc_set(2, low=0x00, hi=0x03) + dpc_svc_call(1, 0x00, 0x60, 2, 0xC0)       # a 192-byte copy
    b += '        LDY #64\nbl:     LDA $1005\n        LDA $1009\n        STY $1078\n        DEY\n        BNE bl\n'
    b += '        INC M_DONE\n'
    img.program(5, init='', body=b, lines=6)
    return img


def _busy_cdf(rev=2):
    img = Img('cdf', rev=rev)
    amp = img.amp_stream
    img.cdf_tables({i: img.ptr_value(i * 16) for i in range(8)}, {i: 0x100 for i in range(8)},
                   {0: 0x40000800, 1: 0x40000880, 2: 0x40000900})
    img.scripts = [[cdf_data(img, pattern(0x200, 2), 0), (OP_FSET, 11, 0x02000000), (OP_FSET, 12, 0x01300000)],
                   [(OP_FADD, 11, 0x00100000), (OP_FADD, 9, 0x10000000)]]
    b = call_cdf()
    b += '        LDY #64\nbl:     LDA #$00\n        LDA #$03\n        LDA #$%02X\n        STX DSWRITE\n' % amp
    b += '        DEY\n        BNE bl\n'
    b += '        LDA M_FRAME\n        AND #1\n        BEQ md\n        LDA #$00\n        STA SETMODE\n'
    b += '        JMP me\nmd:     LDA #$F0\n        STA SETMODE\nme:\n'
    b += '        INC M_DONE\n'
    init = call_cdf() + '        LDA #$F0\n        STA SETMODE\n'
    img.program(img.reset_bank, init=init, body=b, lines=6)
    return img


def _reset_test(img, scheme, args, req, desc, frames=8):
    return img, dict(scheme=scheme, frames=frames, args=args, need=need(*req), desc=desc)


@test
def hard_reset_call_dpc():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_rst=1', '+dir_rst_n=3', '+dir_rst_dly=15'],
                       [('inj_rst_in_call', '>=', 1), ('reset_in_call', '>=', 1), ('console_reset', '>=', 1),
                        ('reset_release', '>=', 2), ('init_rise', '>=', 2), ('dir_marker', '>=', 3)],
                       'DPC+: a console reset 15 clk_sys after the 3rd call accept (the ARM runs)')


@test
def hard_reset_svc_dpc():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_rst=2', '+dir_rst_n=4', '+dir_rst_dly=4'],
                       [('inj_rst_in_svc', '>=', 1), ('reset_in_svc', '>=', 1), ('console_reset', '>=', 1),
                        ('reset_release', '>=', 2), ('init_rise', '>=', 2), ('dir_marker', '>=', 3)],
                       'DPC+: a console reset 4 clk_sys into the 4th service (DMA running)')


@test
def hard_reset_call_cdf():
    return _reset_test(_busy_cdf(), (23, 2), ['+dir_rst=1', '+dir_rst_n=4', '+dir_rst_dly=40'],
                       [('inj_rst_in_call', '>=', 1), ('reset_in_call', '>=', 1), ('console_reset', '>=', 1),
                        ('reset_release', '>=', 2), ('init_rise', '>=', 2), ('dir_marker', '>=', 3)],
                       'CDFJ: a console reset 40 clk_sys after the 4th call accept')


@test
def hard_reset_dsw_cdfj():
    return _reset_test(_busy_cdf(2), (23, 2), ['+dir_rst=5', '+dir_rst_n=30', '+dir_rst_dly=1', '+dir_rst_len=300',
                                               '+dir_rst_rep=101', '+dir_rst_max=5'],
                       [('inj_rst', '>=', 4), ('reset_in_dsw_ph1', '>=', 3), ('console_reset', '>=', 4),
                        ('dir_marker', '>=', 3)],
                       'CDFJ: console resets landing in the phase 1 of DSWRITE cycles (daria_fe\'s P32 read: '
                       'a_p32_late there is the p32_reset class)', frames=16)


@test
def hard_reset_dsw_cdfjp():
    return _reset_test(_busy_cdf(3), (23, 3), ['+dir_rst=5', '+dir_rst_n=30', '+dir_rst_dly=1', '+dir_rst_len=300',
                                               '+dir_rst_rep=101', '+dir_rst_max=5'],
                       [('inj_rst', '>=', 4), ('reset_in_dsw_ph1', '>=', 3), ('console_reset', '>=', 4),
                        ('dir_marker', '>=', 3)],
                       'CDFJ+: console resets landing in the phase 1 of DSWRITE cycles', frames=16)


@test
def hard_reset_init_cdfjp():
    return _reset_test(_busy_cdf(3), (23, 3), ['+dir_rst=3', '+dir_rst_dly=100', '+dir_rst_len=3000'],
                       [('inj_rst_in_init', '>=', 1), ('reset_release', '>=', 1), ('dir_marker', '>=', 5)],
                       'CDFJ+: a console reset pulse during the load-time init (and F6); no extra edge')


@test
def hard_reset_rel_dpc():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_rst=4', '+dir_rst_n=1', '+dir_rst_dly=3', '+dir_rst_len=200'],
                       [('console_reset', '>=', 1), ('reset_release', '>=', 2), ('init_rise', '>=', 2),
                        ('dir_marker', '>=', 3)],
                       'DPC+: a console reset 3 clk_sys after the first release: the re-init (and F6) '
                       'right after the first')


@test
def hard_reset_rel_cdf1():
    img = _busy_cdf(1)
    return _reset_test(img, (23, 1), ['+dir_rst=4', '+dir_rst_n=1', '+dir_rst_dly=3', '+dir_rst_len=200'],
                       [('console_reset', '>=', 1), ('reset_release', '>=', 2), ('init_rise', '>=', 2),
                        ('dir_marker', '>=', 3)],
                       'CDF1: a console reset 3 clk_sys after the first release')


@test
def hard_reset_frame_cdfj():
    return _reset_test(_busy_cdf(2), (23, 2), ['+hard_reset_at=3'],
                       [('console_reset', '>=', 1), ('reset_release', '>=', 2), ('dir_marker', '>=', 3)],
                       'CDFJ: the bench\'s +hard_reset_at=3 (a reset at a frame start)')


@test
def pause_dpc_ph1():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_pause=1', '+dir_pause_n=500', '+dir_pause_dly=2',
                                               '+dir_pause_len=137', '+dir_pause_rep=211'],
                       [('inj_pause_ph1', '>=', 20), ('pause_seen', '>=', 2000), ('dir_marker', '>=', 3)],
                       'DPC+: pauses starting in phase 1 (every 211th E0)')


@test
def pause_dpc_ph2():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_pause=1', '+dir_pause_n=500', '+dir_pause_dly=8',
                                               '+dir_pause_len=93', '+dir_pause_rep=173'],
                       [('inj_pause_ph2', '>=', 20), ('pause_seen', '>=', 2000), ('dir_marker', '>=', 3)],
                       'DPC+: pauses starting in phase 2')


@test
def pause_dpc_call():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_pause=2', '+dir_pause_n=2', '+dir_pause_dly=12',
                                               '+dir_pause_len=300', '+dir_pause_rep=1'],
                       [('inj_pause_in_call', '>=', 3), ('dir_marker', '>=', 3)],
                       'DPC+: a pause inside every call from the 2nd')


@test
def pause_dpc_svc():
    return _reset_test(_busy_dpc(), (21, 0), ['+dir_pause=3', '+dir_pause_n=2', '+dir_pause_dly=3',
                                               '+dir_pause_len=250', '+dir_pause_rep=1'],
                       [('inj_pause_in_svc', '>=', 5), ('dir_marker', '>=', 3)],
                       'DPC+: a pause inside every service from the 2nd')


@test
def pause_cdf_ph():
    return _reset_test(_busy_cdf(), (23, 2), ['+dir_pause=1', '+dir_pause_n=400', '+dir_pause_dly=4',
                                               '+dir_pause_len=181', '+dir_pause_rep=157'],
                       [('inj_pause', '>=', 20), ('pause_seen', '>=', 2000), ('dir_marker', '>=', 3)],
                       'CDFJ (waveform and digital audio frames): pauses in phase 1')


@test
def pause_cdf_call():
    return _reset_test(_busy_cdf(), (23, 2), ['+dir_pause=2', '+dir_pause_n=2', '+dir_pause_dly=20',
                                               '+dir_pause_len=400', '+dir_pause_rep=1'],
                       [('inj_pause_in_call', '>=', 3), ('dir_marker', '>=', 3)],
                       'CDFJ: a pause inside every call from the 2nd')


@test
def dpc_short():
    """A 29,696-byte DPC+ image (detect2600's size rule): the init copy of
    $6C00-$7FFF reads 1 KB past the end of the file (short_image)."""
    img = Img('dpc', size=29696, scripts=[[]])
    img.put(0x6C00, pattern(0x7400 - 0x6C00, 1), 'display')
    b = dpc_readback(0, 0x000, 0x10) + dpc_readback(1, 0x7F8, 0x10) + dpc_readback(2, 0xFF8, 0x8)
    b += sta(0x1075, 0x10) + '        LDA $1005\n        INC M_DONE\n'
    img.program(5, init='', body=b, lines=4)
    req = need(('dpc_rd_f1_i0', '>=', 50), ('dpc_rd_f1_i1', '>=', 50), ('dir_marker', '>=', 5))
    return img, dict(scheme=(21, 0), frames=6, need=req,
                     desc='29,696-byte DPC+ image: display RAM and the NOTE table partly beyond the file')


@test
def hard_reset_frame_dpc():
    return _reset_test(_busy_dpc(), (21, 0), ['+hard_reset_at=3'],
                       [('console_reset', '>=', 1), ('reset_release', '>=', 2), ('dir_marker', '>=', 3)],
                       'DPC+: the bench\'s +hard_reset_at=3 (a reset at a frame start)')
