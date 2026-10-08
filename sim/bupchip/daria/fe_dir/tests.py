# SPDX-License-Identifier: MIT
"""The daria_fe directed tests (design.md 12.1; bench.md 7.9 item 7).

Each test is a function returning (Img, meta). meta:
  scheme  (force_bs, revision) that detect2600 must report
  frames  how many frames to run (+frames)
  args    extra plusargs (injections, latencies)
  need    [(bin, op, value)]: fe_dir_mon coverage bins the run must reach;
          a test whose feature never fires fails
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
    # b. fill $5A -> DF2 $200, $80 bytes
    body += dpc_set(2, low=0x00, hi=0x02) + dpc_svc_call(2, 0x5A, 0, 2, 0x80)
    body += dpc_set(2, low=0x7F, hi=0x02) + '        LDA $100A\n' + chk(0x5A)
    body += '        LDA $100A\n' + chk(disp[0x280])
    # c. count 0 (fill): nothing written, the service still runs
    body += dpc_set(2, low=0x00, hi=0x02) + dpc_svc_call(2, 0x33, 0, 2, 0)
    body += dpc_set(2, low=0x00, hi=0x02) + '        LDA $100A\n' + chk(0x5A)
    # d. copy with the ROM offset >= $7400: count 0 ($7400 and $FFFF)
    body += dpc_set(3, low=0x00, hi=0x03) + dpc_svc_call(1, 0x00, 0x74, 3, 0x20)
    body += dpc_svc_call(1, 0xFF, 0xFF, 3, 0x20)
    body += dpc_set(3, low=0x00, hi=0x03) + '        LDA $100B\n' + chk(disp[0x300])
    # e. destination clamp: counter $FF8 (8 left), fill $40 -> 8; copy at $FFC -> 4
    body += dpc_set(4, low=0xF8, hi=0x0F) + dpc_svc_call(2, 0x77, 0, 4, 0x40)
    body += dpc_set(4, low=0xFF, hi=0x0F) + '        LDA $100C\n' + chk(0x77)
    body += '        LDA $100C\n' + chk(disp[0])          # wrapped to $000: untouched
    body += dpc_set(4, low=0xFC, hi=0x0F) + dpc_svc_call(1, 0x10, 0x60, 4, 0x40)
    body += dpc_set(4, low=0xFC, hi=0x0F) + '        LDA $100C\n' + chk(disp[0x10])
    # f. source clamp: offset $73F0 -> 16 bytes (to $7FFF), $73FF -> 1
    body += dpc_set(5, low=0x00, hi=0x05) + dpc_svc_call(1, 0xF0, 0x73, 5, 0x40)
    body += dpc_set(5, low=0x00, hi=0x05) + dpc_svc_call(1, 0xFF, 0x73, 5, 0x40)
    # g. the RMW pair: INC $105A reads the ROM byte $01 there, writes $01 (copy)
    #    then $02 (fill, latched while the copy runs); DEC $105A: $01 then $00
    body += dpc_set(6, low=0x00, hi=0x06)
    body += sta(0x105A, 0) + sta(0x1059, 0x00) + sta(0x1059, 0x60) + sta(0x1059, 6) + sta(0x1059, 0x10)
    body += '        INC $105A\n'
    body += dpc_set(6, low=0x00, hi=0x06) + '        LDA $100E\n' + chk(0x00)
    body += sta(0x105A, 0) + sta(0x1059, 0x20) + sta(0x1059, 0x60) + sta(0x1059, 6) + sta(0x1059, 0x10)
    body += '        DEC $105A\n'
    body += dpc_set(6, low=0x00, hi=0x06) + '        LDA $100E\n' + chk(disp[0x20])
    # h. services during audio: voice 0's waveform 8 reads RAM $0D00-$0D1F, voice 1's
    #    9; DF7 at $100 so each 255-byte fill covers both; 24 fills a frame
    body += sta(0x105D, 8) + sta(0x105E, 9) + sta(0x1075, 0x30) + sta(0x1076, 0x51)
    body += '        LDY #24\nsvloop:\n'
    body += dpc_set(7, low=0x00, hi=0x01) + sta(0x105A, 0)
    body += '        TYA\n        STA $1059\n' + sta(0x1059, 0) + sta(0x1059, 7) + sta(0x1059, 0xFF)
    body += sta(0x105A, 2) + '        LDA $1005\n        DEY\n        BNE svloop\n'
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
