#!/usr/bin/env python3
"""Compare tb_tdec.sv's dumps of DARIA's Thumb decoder with the table of
../thumb_expand.py (record(), --table), halfword by halfword.

  tdec_check.py TABLE.txt DUMP.txt [DUMP.txt ...] [--show N]

Each dump is one tb_tdec run: all 65,536 halfwords in the half of rom_q that
pc_h selects (the other half holds a decoy), with C known or unknown. For
every halfword the effective class is the first class bit in the order
bup_cpu.sv's execute clock tests them (k_dp, k_mul / k_mull, k_mrs, k_msr,
k_br, k_bx, k_bl2, k_movpc, k_addpc, k_mem, k_blk); exactly one may be set
unless the halfword halts. Then, where the table gives a value ('-' is
"anything"), per class:

  all    halt decision and code (dec_bad, dec_code), condition, and whether
         it reads C (cond_rd_c | op_rd_c); with C unknown also the FLAGS
         decision (flags_halt, halt_code_now)
  DP     dp_op, S (bit_l), zero_a, ports A / B (ia, ib in the first clock),
         the register shifted by a register amount (f_rm), the result index
         (f_rd, or dp_cmp for TST..CMN), the immediate (op_imm, th_immv) or
         the shift (sh_type, normalised sh_amt, sh_rrx, dp_rsh), and c_def
         where a flag-setting form defines C or passes it through
  MUL    ports A / B, the product's index (f_rn), no accumulate (bit_w)
  MEM    load, size, sign, register offset, P / U / W, ports A / B, f_rd,
         the immediate offset (th_offv)
  BLK    load, list, P / U / W, port A, the write-back index (f_rn)
  BR     the target (bt) against address + 4 + 2 x boff, no link
  BX, MOVPC  port B; ADDPC ports A / B, ADD of an unshifted register
  BL2    port A, ADD, the immediate, the link (address + 2) | 1
  r15    where a port reads r15: r15_value = address + 4, or
         (address + 4) & ~3 for pcrel (F6, F12 with PC)

Both halves' port candidates (ta_lo / tb_lo, ta_hi / tb_hi) are checked too:
the selected half's against the halfword's ports, the other's against the
decoy's. Prints the number of differences per run and the first ones,
grouped by format; exit status 1 if there are any.
SPDX-License-Identifier: MIT
"""
import collections
import sys

CLASS_ORDER = [("k_dp", "DP"), ("k_mul", "MUL"), ("k_mull", "MULL"), ("k_mrs", "MRS"), ("k_msr", "MSR"),
               ("k_br", "BR"), ("k_bx", "BX"), ("k_bl2", "BL2"), ("k_movpc", "MOVPC"),
               ("k_addpc", "ADDPC"), ("k_mem", "MEM"), ("k_blk", "BLK")]
SHIFTS = {"LSL": 0, "LSR": 1, "ASR": 2, "ROR": 3}


def load_table(path):
    tab = {}
    for line in open(path):
        if line.startswith("#"):
            continue
        f = line.split()
        tab[int(f[0], 16)] = dict(kv.split("=", 1) for kv in f[3:])
    if len(tab) != 65536:
        sys.exit("tdec_check: %s has %d rows, not 65536" % (path, len(tab)))
    return tab


def load_dump(path):
    with open(path) as fh:
        head = fh.readline().strip()
        names = fh.readline().split()
        rows = []
        for line in fh:
            v = line.split()
            rows.append({n: int(x, 16) for n, x in zip(names, v)})
    ctx = dict(kv.split("=") for kv in head.split()[2:])
    return {k: int(v) for k, v in ctx.items()}, rows


def check(d, t, ctx, td):
    """Differences of one dumped halfword d against its table row t (and the
    decoy's row td): a list of (field, got, want)."""
    out = []

    def want(field, got, exp):
        if got != exp:
            out.append((field, got, exp))

    def hx(v):
        return int(v, 16)

    addr = ctx["pc"] * 4 + ctx["pc_h"] * 2
    want("pc_byte", d["pc_byte"], addr)
    want("state/tm/pc_h/c_unk", (d["state"], d["tm"], d["pc_h"], d["c_unk"]), (1, 1, ctx["pc_h"], ctx["c_unk"]))
    # Both halves' port candidates.
    sel, oth = ("hi", "lo") if ctx["pc_h"] else ("lo", "hi")
    for row, half in ((t, sel), (td, oth)):
        if row["A"] != "-":
            want("ta_" + half, d["ta_" + half], hx(row["A"]))
        if row["B"] != "-":
            want("tb_" + half, d["tb_" + half], hx(row["B"]))

    want("cond", d["cond"], hx(t["cond"]))
    want("reads C", d["cond_rd_c"] | d["op_rd_c"], int(t["rdc"]))
    if t["cls"] == "HALT":
        want("dec_bad", d["dec_bad"], 1)
        want("dec_code", d["dec_code"], int(t["halt"]))
        if ctx["c_unk"]:
            want("halt_code_now", d["halt_code_now"], int(t["halt"]))
        return out
    want("dec_bad", d["dec_bad"], 0)
    if ctx["c_unk"]:
        want("flags_halt", d["flags_halt"], int(t["rdc"]))
        if t["rdc"] == "1":
            want("halt_code_now", d["halt_code_now"], 8)
    got = [name for k, name in CLASS_ORDER if d[k]]
    want("class", got[0] if got else "none", t["cls"])
    if len(got) > 1:
        out.append(("class bits", "+".join(got), t["cls"]))
    cls = t["cls"]
    if t["pc"] != "-":
        want("r15_value", d["r15_value"], ((addr + 4) & ~3) if t["pc"] == "a" else addr + 4)
        want("pcrel", d["pcrel"], int(t["pc"] == "a"))
    if t["A"] != "-":
        want("ia", d["ia"], hx(t["A"]))
    if t["B"] != "-":
        want("ib", d["ib"], hx(t["B"]))

    if cls == "DP":
        want("dp_op", d["dp_op"], hx(t["op"]))
        want("S", d["bit_l"], int(t["s"]))
        want("zero_a", d["zero_a"], int(t["za"]))
        if t["rd"] == "-":
            want("dp_cmp", d["dp_cmp"], 1)
        else:
            want("dp_cmp", d["dp_cmp"], 0)
            want("f_rd", d["f_rd"], hx(t["rd"]))
        if t["imm"] != "-":
            want("op_imm", d["op_imm"], 1)
            want("th_immv", d["th_immv"], hx(t["imm"]))
        else:
            want("op_imm", d["op_imm"], 0)
            sh = t["sh"]
            if sh == "RRX":
                want("shift", (d["dp_rsh"], d["sh_type"], d["sh_rrx"]), (0, 3, 1))
            elif sh.endswith(":R"):
                want("shift", (d["dp_rsh"], d["sh_type"]), (1, SHIFTS[sh[:3]]))
                want("f_rm", d["f_rm"], hx(t["M"]))
            else:
                want("shift", (d["dp_rsh"], d["sh_type"], d["sh_amt"], d["sh_rrx"]),
                     (0, SHIFTS[sh[:3]], int(sh[4:]), 0))
        if t["s"] == "1" and t["cdef"] in "YN":
            want("c_def", d["c_def"], int(t["cdef"] == "Y"))
    elif cls == "MUL":
        want("f_rn", d["f_rn"], hx(t["rd"]))
        want("bit_w (accumulate)", d["bit_w"], 0)
    elif cls == "MEM":
        want("L", d["bit_l"], int(t["L"]))
        want("t_size", d["t_size"], int(t["size"]))
        want("t_sign", d["t_sign"], int(t["sign"]))
        want("t_regoff", d["t_regoff"], int(t["roff"]))
        want("P/U/W", (d["bit_p"], d["bit_u"], d["t_wb"]), tuple(int(c) for c in t["pu"]))
        want("f_rd", d["f_rd"], hx(t["rd"]))
        if t["off"] != "-":
            want("th_offv", d["th_offv"], hx(t["off"]))
    elif cls == "BLK":
        want("L", d["bit_l"], int(t["L"]))
        want("list", d["list"], hx(t["list"]))
        want("P/U/W", (d["bit_p"], d["bit_u"], d["bit_w"]), tuple(int(c) for c in t["pu"]))
        want("f_rn", d["f_rn"], hx(t["rd"]))
    elif cls == "BR":
        want("br_link", d["br_link"], 0)
        want("bt", d["bt"], ((addr >> 1) + 2 + int(t["boff"])) & 0x7FFFFFFF)
    elif cls == "BL2":
        want("dp_op", d["dp_op"], hx(t["op"]))
        want("op_imm", d["op_imm"], 1)
        want("th_immv", d["th_immv"], hx(t["imm"]))
        want("zero_a", d["zero_a"], 0)
        want("link_value", d["link_value"], (addr + 2) | 1)
    elif cls == "ADDPC":
        want("dp_op", d["dp_op"], hx(t["op"]))
        want("operand 2", (d["op_imm"], d["sh_type"], d["sh_amt"], d["sh_rrx"], d["zero_a"]), (0, 0, 0, 0, 0))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--show")]
    show = 3
    for a in sys.argv[1:]:
        if a.startswith("--show"):
            show = int(a.split("=")[1])
    if len(args) < 2:
        sys.exit(__doc__.split("\n\n")[1])
    tab = load_table(args[0])
    total = 0
    for path in args[1:]:
        ctx, rows = load_dump(path)
        if len(rows) != 65536:
            print("%s: %d rows, not 65536" % (path, len(rows)))
            total += 1
            continue
        by_fmt = collections.defaultdict(list)
        n = 0
        for d in rows:
            t = tab[d["hw"]]
            diffs = check(d, t, ctx, tab[d["decoy"]])
            if diffs:
                n += 1
                by_fmt[t["fmt"]].append((d["hw"], diffs))
        total += n
        print("%s (pc_h %d, C %s): %d of 65536 halfwords differ" % (
            path, ctx["pc_h"], "unknown" if ctx["c_unk"] else "known", n))
        for fmt, lst in sorted(by_fmt.items()):
            fields = collections.Counter(f for _, diffs in lst for f, _, _ in diffs)
            print("  %-7s %5d halfwords; fields: %s" % (fmt, len(lst), ", ".join(
                "%s %d" % kv for kv in fields.most_common())))
            for hw, diffs in lst[:show]:
                print("    %04x: %s" % (hw, "; ".join("%s got %s want %s" % (
                    f, g if not isinstance(g, int) else "%x" % g, w if not isinstance(w, int) else "%x" % w)
                    for f, g, w in diffs)))
    print("decode check: %d difference%s" % (total, "" if total == 1 else "s"))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
