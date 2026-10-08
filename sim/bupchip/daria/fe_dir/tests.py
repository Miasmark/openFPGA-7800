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
    """Compare A (or load `src` first) with v; count a mismatch in M_ERR and in
    RIOT $F0 + (the check's number mod 8), reported as dir_res0..7."""
    ok = L('ok')
    k = _chk[0] % 8
    _chk[0] += 1
    t = ''
    if src:
        t += '        LDA %s\n' % src
    t += '        CMP #$%02X\n        BEQ %s\n        INC M_ERR\n        INC M_RES+%d\n%s:\n' % (v, ok, k, ok)
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
