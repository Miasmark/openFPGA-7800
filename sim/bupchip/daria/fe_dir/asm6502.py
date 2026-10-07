#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A small two-pass 6502 assembler for the daria_fe directed tests (fe_dir/).

Syntax, one statement per line, ';' starts a comment:
    label:                      a label (may share the line with a statement)
    NAME = expr                 a symbol
    .org expr                   set the location counter
    .byte e, e, ...             bytes (a "string" emits its ASCII bytes)
    .word e, e, ...             little-endian words
    .fill n [, v]               n bytes of v (default 0)
    .align n [, v]              pad with v to a multiple of n
    OPC [operand]               the documented NMOS opcodes:
        #e  e  e,X  e,Y  (e)  (e,X)  (e),Y  A  (implied: nothing)
Expressions are Python expressions over the symbols, with $hex, %bin, '*'
for the location counter, <e (low byte) and >e (high byte) as prefixes.
A value known in pass 1 and below $100 picks the zero-page form when the
opcode has one; a forward reference picks the absolute form (pass 2 keeps
pass 1's sizes). Write `a:e` to force the absolute form.

assemble(text, symbols) returns (dict address -> byte, symbol table).
"""
import re

# mnemonic -> {mode: opcode}
_OPS = {}


def _add(mn, **modes):
    _OPS[mn] = modes


_add('ADC', imm=0x69, zp=0x65, zpx=0x75, abs=0x6D, absx=0x7D, absy=0x79, indx=0x61, indy=0x71)
_add('AND', imm=0x29, zp=0x25, zpx=0x35, abs=0x2D, absx=0x3D, absy=0x39, indx=0x21, indy=0x31)
_add('ASL', acc=0x0A, zp=0x06, zpx=0x16, abs=0x0E, absx=0x1E)
_add('BIT', zp=0x24, abs=0x2C)
for _mn, _op in (('BPL', 0x10), ('BMI', 0x30), ('BVC', 0x50), ('BVS', 0x70), ('BCC', 0x90),
                 ('BCS', 0xB0), ('BNE', 0xD0), ('BEQ', 0xF0)):
    _add(_mn, rel=_op)
_add('BRK', imp=0x00)
_add('CMP', imm=0xC9, zp=0xC5, zpx=0xD5, abs=0xCD, absx=0xDD, absy=0xD9, indx=0xC1, indy=0xD1)
_add('CPX', imm=0xE0, zp=0xE4, abs=0xEC)
_add('CPY', imm=0xC0, zp=0xC4, abs=0xCC)
_add('DEC', zp=0xC6, zpx=0xD6, abs=0xCE, absx=0xDE)
_add('EOR', imm=0x49, zp=0x45, zpx=0x55, abs=0x4D, absx=0x5D, absy=0x59, indx=0x41, indy=0x51)
for _mn, _op in (('CLC', 0x18), ('SEC', 0x38), ('CLI', 0x58), ('SEI', 0x78), ('CLV', 0xB8),
                 ('CLD', 0xD8), ('SED', 0xF8), ('DEX', 0xCA), ('DEY', 0x88), ('INX', 0xE8),
                 ('INY', 0xC8), ('NOP', 0xEA), ('PHA', 0x48), ('PHP', 0x08), ('PLA', 0x68),
                 ('PLP', 0x28), ('RTI', 0x40), ('RTS', 0x60), ('TAX', 0xAA), ('TAY', 0xA8),
                 ('TSX', 0xBA), ('TXA', 0x8A), ('TXS', 0x9A), ('TYA', 0x98)):
    _add(_mn, imp=_op)
_add('INC', zp=0xE6, zpx=0xF6, abs=0xEE, absx=0xFE)
_add('JMP', abs=0x4C, ind=0x6C)
_add('JSR', abs=0x20)
_add('LDA', imm=0xA9, zp=0xA5, zpx=0xB5, abs=0xAD, absx=0xBD, absy=0xB9, indx=0xA1, indy=0xB1)
_add('LDX', imm=0xA2, zp=0xA6, zpy=0xB6, abs=0xAE, absy=0xBE)
_add('LDY', imm=0xA0, zp=0xA4, zpx=0xB4, abs=0xAC, absx=0xBC)
_add('LSR', acc=0x4A, zp=0x46, zpx=0x56, abs=0x4E, absx=0x5E)
_add('ORA', imm=0x09, zp=0x05, zpx=0x15, abs=0x0D, absx=0x1D, absy=0x19, indx=0x01, indy=0x11)
_add('ROL', acc=0x2A, zp=0x26, zpx=0x36, abs=0x2E, absx=0x3E)
_add('ROR', acc=0x6A, zp=0x66, zpx=0x76, abs=0x6E, absx=0x7E)
_add('SBC', imm=0xE9, zp=0xE5, zpx=0xF5, abs=0xED, absx=0xFD, absy=0xF9, indx=0xE1, indy=0xF1)
_add('STA', zp=0x85, zpx=0x95, abs=0x8D, absx=0x9D, absy=0x99, indx=0x81, indy=0x91)
_add('STX', zp=0x86, zpy=0x96, abs=0x8E)
_add('STY', zp=0x84, zpx=0x94, abs=0x8C)

_ZP_OF = {'abs': 'zp', 'absx': 'zpx', 'absy': 'zpy'}
_SIZE = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'rel': 2, 'indx': 2,
         'indy': 2, 'abs': 3, 'absx': 3, 'absy': 3, 'ind': 3}


class AsmError(Exception):
    pass


def _expr_py(e):
    e = e.strip()
    e = re.sub(r'\$([0-9A-Fa-f]+)', r'0x\1', e)
    e = re.sub(r'%([01]+)', r'0b\1', e)
    return e


def _eval(e, syms, pc, strict):
    e = e.strip()
    if e.startswith('<'):
        return _eval(e[1:], syms, pc, strict) & 0xFF
    if e.startswith('>'):
        return (_eval(e[1:], syms, pc, strict) >> 8) & 0xFF
    py = _expr_py(e)
    # '*' alone or as an operand of +/- means the location counter
    py = re.sub(r'(^|[\s(+\-])\*(?=$|[\s)+\-])', r'\1__pc__', py)
    env = dict(syms)
    env['__pc__'] = pc
    try:
        return int(eval(py, {'__builtins__': {}}, env))
    except NameError:
        if strict:
            raise AsmError('undefined symbol in "%s"' % e)
        return None


def _split_args(s):
    out, cur, q = [], '', False
    for ch in s:
        if ch == '"':
            q = not q
        if ch == ',' and not q:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]


def _parse_operand(opd):
    """-> (mode guess without size, expression, forced_abs)"""
    o = opd.strip()
    if o == '' :
        return 'imp', None, False
    if o.upper() == 'A':
        return 'acc', None, False
    if o.startswith('#'):
        return 'imm', o[1:], False
    m = re.match(r'^\((.*),\s*[Xx]\s*\)$', o)
    if m:
        return 'indx', m.group(1), False
    m = re.match(r'^\((.*)\)\s*,\s*[Yy]$', o)
    if m:
        return 'indy', m.group(1), False
    m = re.match(r'^\((.*)\)$', o)
    if m:
        return 'ind', m.group(1), False
    forced = False
    if o.lower().startswith('a:'):
        forced = True
        o = o[2:]
    m = re.match(r'^(.*),\s*([XxYy])$', o)
    if m:
        return ('absx' if m.group(2).upper() == 'X' else 'absy'), m.group(1), forced
    return 'abs', o, forced


def assemble(text, symbols=None, org=0):
    syms = dict(symbols or {})
    lines = text.split('\n')
    sizes = {}
    for pas in (1, 2):
        pc = org
        out = {}
        for ln, raw in enumerate(lines):
            line = raw.split(';', 1)[0].rstrip()
            if not line.strip():
                continue
            try:
                m = re.match(r'^\s*([A-Za-z_][\w.]*)\s*:(.*)$', line)
                if m and not m.group(2).startswith(':'):
                    lab = m.group(1)
                    if pas == 1 and lab in syms and syms[lab] != pc:
                        raise AsmError('label %s redefined' % lab)
                    syms[lab] = pc
                    line = m.group(2)
                    if not line.strip():
                        continue
                m = re.match(r'^\s*([A-Za-z_]\w*)\s*=\s*(.+)$', line)
                if m:
                    v = _eval(m.group(2), syms, pc, pas == 2)
                    if v is not None:
                        syms[m.group(1)] = v
                    continue
                parts = line.strip().split(None, 1)
                op = parts[0]
                arg = parts[1] if len(parts) > 1 else ''
                if op.startswith('.'):
                    d = op.lower()
                    if d == '.org':
                        pc = _eval(arg, syms, pc, True)
                    elif d in ('.byte', '.word'):
                        for a in _split_args(arg):
                            if a.startswith('"'):
                                for ch in a.strip('"'):
                                    out[pc] = ord(ch)
                                    pc += 1
                                continue
                            v = _eval(a, syms, pc, pas == 2)
                            v = 0 if v is None else v
                            if d == '.byte':
                                if pas == 2 and not -128 <= v <= 255:
                                    raise AsmError('byte out of range: %s' % a)
                                out[pc] = v & 0xFF
                                pc += 1
                            else:
                                out[pc] = v & 0xFF
                                out[pc + 1] = (v >> 8) & 0xFF
                                pc += 2
                    elif d == '.fill':
                        a = _split_args(arg)
                        n = _eval(a[0], syms, pc, True)
                        v = _eval(a[1], syms, pc, True) if len(a) > 1 else 0
                        for i in range(n):
                            out[pc + i] = v & 0xFF
                        pc += n
                    elif d == '.align':
                        a = _split_args(arg)
                        n = _eval(a[0], syms, pc, True)
                        v = _eval(a[1], syms, pc, True) if len(a) > 1 else 0
                        while pc % n:
                            out[pc] = v & 0xFF
                            pc += 1
                    else:
                        raise AsmError('unknown directive ' + op)
                    continue
                mn = op.upper()
                if mn not in _OPS:
                    raise AsmError('unknown opcode ' + op)
                modes = _OPS[mn]
                mode, ex, forced = _parse_operand(arg)
                if 'rel' in modes:
                    mode = 'rel'
                if mode == 'abs' and 'abs' not in modes and 'rel' not in modes:
                    raise AsmError('%s has no absolute mode' % mn)
                if mode in ('absx', 'absy', 'abs') and mode != 'rel':
                    key = (ln, pc if pas == 1 else None)
                    if pas == 1:
                        v = _eval(ex, syms, pc, False)
                        zpm = _ZP_OF.get(mode)
                        if (not forced and v is not None and 0 <= v < 0x100 and zpm in modes):
                            sizes[ln] = zpm
                        elif mode not in modes and zpm in modes:
                            sizes[ln] = zpm
                        else:
                            sizes[ln] = mode
                    mode = sizes[ln]
                if mode not in modes:
                    raise AsmError('%s has no %s mode' % (mn, mode))
                opc = modes[mode]
                n = _SIZE[mode]
                out[pc] = opc
                if n > 1:
                    v = _eval(ex, syms, pc, pas == 2)
                    v = 0 if v is None else v
                    if mode == 'rel':
                        d = v - (pc + 2)
                        if pas == 2 and not -128 <= d <= 127:
                            raise AsmError('branch out of range (%d)' % d)
                        out[pc + 1] = d & 0xFF
                    elif n == 2:
                        if pas == 2 and not -128 <= v <= 255:
                            raise AsmError('operand out of range: %s = %d' % (ex, v))
                        out[pc + 1] = v & 0xFF
                    else:
                        out[pc + 1] = v & 0xFF
                        out[pc + 2] = (v >> 8) & 0xFF
                pc += n
            except AsmError as err:
                raise AsmError('line %d: %s: %s' % (ln + 1, raw.strip(), err))
    return out, syms


if __name__ == '__main__':
    code, s = assemble("""
        .org $1000
    start: LDA #$12
        STA $85
        STA $1FF8
        LDA (ptr),Y
        LDX #0
    loop: DEX
        BNE loop
        JMP start
        JMP (vec)
    ptr = $80
    vec = $1F00
        .word start
        .byte "AB", <start, >start
    """)
    print(' '.join('%02X' % code[a] for a in sorted(code)))
