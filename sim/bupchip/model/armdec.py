#!/usr/bin/env python3
"""ARMv4 (ARM state) decoder shared by the BupChip model tools.

  decode(word, addr) -> dict with 'kind', 'cond' and the encoding's fields
  text(d)            -> short mnemonic with condition, for the objdump check
  firmware()         -> the CoreTone firmware words (src/fpga/mister/rtl/bupchip.hex)

Kinds: dp, mul (MUL/MLA), mull (UMULL family), xfer (LDR/STR/LDRB/STRB),
xfer_h (LDRH/STRH/LDRSB/LDRSH), ldm (LDM/STM), b (B/BL), bx, mrs, msr, and
the ones the firmware never uses: swp, swi, cop, cop_ldst, undef. Shifts by
an immediate follow the ARM ARM: LSR #0 and ASR #0 mean #32 ('amt' = 32),
ROR #0 is RRX.
"""
import os

HEX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../src/fpga/mister/rtl/bupchip.hex')

CONDS = ['eq', 'ne', 'cs', 'cc', 'mi', 'pl', 'vs', 'vc', 'hi', 'ls', 'ge', 'lt', 'gt', 'le', '', 'nv']
DPOPS = ['and', 'eor', 'sub', 'rsb', 'add', 'adc', 'sbc', 'rsc', 'tst', 'teq', 'cmp', 'cmn', 'orr', 'mov', 'bic', 'mvn']
SHT = ['lsl', 'lsr', 'asr', 'ror']
RN = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'sl', 'fp', 'ip', 'sp', 'lr', 'pc']


def firmware():
    return [int(line, 16) for line in open(HEX) if line.strip()]


def ror32(v, r):
    r &= 31
    return ((v >> r) | (v << (32 - r))) & 0xffffffff if r else v


def _imm_shift(w):
    """Shift type and amount of an immediate-shift operand: (st, amt, rrx)."""
    st, amt = (w >> 5) & 3, (w >> 7) & 31
    if amt == 0 and st in (1, 2):
        amt = 32
    return st, amt, st == 3 and amt == 0


def decode(w, addr=0):
    d = {'w': w, 'addr': addr, 'cond': w >> 28}
    rn, rd = (w >> 16) & 15, (w >> 12) & 15     # the usual Rn and Rd fields
    if w >> 28 == 0xf:
        d['kind'] = 'undef'
    elif (w & 0x0ffffff0) == 0x012fff10:
        d.update(kind='bx', rm=w & 15)
    elif (w & 0x0fc000f0) == 0x00000090:
        # Rd is in [19:16] and the accumulator Rn in [15:12]
        d.update(kind='mul', acc=(w >> 21) & 1, s=(w >> 20) & 1, rd=(w >> 16) & 15, rn=(w >> 12) & 15,
                 rs=(w >> 8) & 15, rm=w & 15)
    elif (w & 0x0f8000f0) == 0x00800090:
        d.update(kind='mull', signed=(w >> 22) & 1, acc=(w >> 21) & 1, s=(w >> 20) & 1,
                 rdhi=(w >> 16) & 15, rdlo=(w >> 12) & 15, rs=(w >> 8) & 15, rm=w & 15)
    elif (w & 0x0fb00ff0) == 0x01000090:
        d['kind'] = 'swp'
    elif (w & 0x0e000090) == 0x00000090 and (w & 0x60):
        l, sh = (w >> 20) & 1, (w >> 5) & 3
        op = {(1, 1): 'ldrh', (1, 2): 'ldrsb', (1, 3): 'ldrsh', (0, 1): 'strh'}.get((l, sh))
        d.update(kind='xfer_h' if op else 'undef', op=op, p=(w >> 24) & 1, u=(w >> 23) & 1,
                 immoff=(w >> 22) & 1, wb=(w >> 21) & 1, l=l, rn=rn, rd=rd, rm=w & 15,
                 off8=((w >> 4) & 0xf0) | (w & 15))
    elif (w & 0x0fbf0fff) == 0x010f0000:
        d.update(kind='mrs', r=(w >> 22) & 1, rd=rd)
    elif (w & 0x0db0f000) == 0x0120f000 and ((w >> 25) & 1 or (w & 0xff0) == 0):
        d.update(kind='msr', i=(w >> 25) & 1, r=(w >> 22) & 1, mask=(w >> 16) & 15, rm=w & 15,
                 imm=ror32(w & 0xff, ((w >> 8) & 15) * 2))
    elif (w >> 26) & 3 == 0:
        op, s = (w >> 21) & 15, (w >> 20) & 1
        d.update(kind='dp', op=op, opn=DPOPS[op], s=s, rn=rn, rd=rd, i=(w >> 25) & 1)
        if 8 <= op <= 11 and not s:
            d['kind'] = 'undef'
        elif d['i']:
            rot = ((w >> 8) & 15) * 2
            d.update(op2='imm', imm=ror32(w & 0xff, rot), rot=rot)
        elif (w >> 4) & 1:
            d.update(op2='regshift_reg', rm=w & 15, st=(w >> 5) & 3, rs=(w >> 8) & 15)
        else:
            st, amt, rrx = _imm_shift(w)
            form = 'rrx' if rrx else 'reg' if st == 0 and amt == 0 else 'regshift_imm'
            d.update(op2=form, rm=w & 15, st=st, amt=amt)
    elif (w >> 26) & 3 == 1:
        if (w >> 25) & 1 and (w >> 4) & 1:
            d['kind'] = 'undef'
            return d
        d.update(kind='xfer', regoff=(w >> 25) & 1, p=(w >> 24) & 1, u=(w >> 23) & 1, b=(w >> 22) & 1,
                 wb=(w >> 21) & 1, l=(w >> 20) & 1, rn=rn, rd=rd)
        if d['regoff']:
            st, amt, rrx = _imm_shift(w)
            d.update(rm=w & 15, st=st, amt=amt, rrx=rrx)
        else:
            d['off12'] = w & 0xfff
    elif (w >> 25) & 7 == 4:
        d.update(kind='ldm', p=(w >> 24) & 1, u=(w >> 23) & 1, s=(w >> 22) & 1, wb=(w >> 21) & 1,
                 l=(w >> 20) & 1, rn=rn, rlist=w & 0xffff)
    elif (w >> 25) & 7 == 5:
        off = w & 0xffffff
        off -= (off & 0x800000) << 1
        d.update(kind='b', link=(w >> 24) & 1, target=(addr + 8 + off * 4) & 0xffffffff)
    elif (w >> 25) & 7 == 6:
        d['kind'] = 'cop_ldst'
    else:
        d['kind'] = 'swi' if (w >> 24) & 1 else 'cop'
    return d


def reglist(m):
    return '{' + ', '.join(RN[i] for i in range(16) if m >> i & 1) + '}'


def text(d):
    """Mnemonic plus condition, in objdump's unified spelling (ldrbeq, not ldreqb)."""
    k, c = d['kind'], CONDS[d['cond']]
    if k == 'dp':
        return d['opn'] + ('s' if d['s'] and d['op'] not in (8, 9, 10, 11) else '') + c
    if k == 'xfer':
        return ('ldr' if d['l'] else 'str') + ('b' if d['b'] else '') + c
    if k == 'xfer_h':
        return d['op'] + c
    if k == 'ldm':
        return ('ldm' if d['l'] else 'stm') + c
    if k == 'b':
        return ('bl' if d['link'] else 'b') + c
    if k == 'mul':
        return ('mla' if d['acc'] else 'mul') + ('s' if d['s'] else '') + c
    if k == 'mull':
        return ('s' if d['signed'] else 'u') + ('mlal' if d['acc'] else 'mull') + ('s' if d['s'] else '') + c
    return k + c
