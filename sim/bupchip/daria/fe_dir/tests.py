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
