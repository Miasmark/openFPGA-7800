#!/usr/bin/env python3
"""Figures from one bup_probe build (run_probe.sh): resources, the register
file's RAM summary, timing, and an estimate of the CPU's ALMs by block.

    probe_report.py BUILD_DIR

BUILD_DIR holds output_files/ (the Quartus reports), paths.txt (five worst
setup paths), classes.txt (the worst path into each kind of endpoint), cells.txt (every placed cell: name, type, location, from the
Timing Analyzer) and simulation/modelsim/bup_probe.vo (the fitted netlist,
for its connections).

The block breakdown. bup_cpu.sv is one module, so Quartus's "Resource
Utilization by Entity" stops at bup_cpu (and its two register-file MLAB
instances). Each of the CPU's cells is given to a block instead:
  1. by the signal it is named after (Quartus names most cells after the
     RTL signal they compute, and registers after the register), with the
     table BLOCKS below;
  2. a LUT fed by the register file's MLABs, or feeding them, is the
     register file's read or write port, whatever its name;
  3. a carry chain named after an operator (AddN, LessThanN) goes as a
     whole to the block of most of its operands;
  4. other cells named after an operator (MuxN, SelectorN, EqualN, ...) or
     after an ambiguous name (ror32 is in the shifter, the immediate
     rotation and the load lanes) take the block most of the cells they
     connect to are in, counting both the cells that drive them and the
     cells they drive. The figures are given for that rule, with the range
     from two others in brackets: loads first (pulls the load lanes and
     result muxes into the register file's write port) and drivers first
     (pulls the first shifter level into its read ports).
ALMs come from placement ("ALMs placed"): an ALM shared by two blocks'
LUTs is split between them, registers count only where an ALM holds no
LUT, and each MLAB LAB is 10 ALMs. That count runs above Quartus's own
"ALMs used" (it ignores Quartus's finer packing), so each block's share
of it is applied to the CPU's "ALMs needed" from the entity table. A cell
that computes for several blocks is counted once, so the split is only
good to the range shown.
"""
import collections
import re
import sys

# Block of each RTL name, as Quartus spells it in cell names (base name:
# without "cpu|", "~N" and "[i]"). Names not listed here are resolved from
# the connections.
BLOCKS = {
    "Register file": """rf_rtl_0 rf__dual_rtl_0 byp_we byp_idx byp_data read_reg ra rb
        rf_we rf_wa rf_wd""",
    "Decode/control": """insn ext g000 g001 psr_space k_mul k_mull k_xh k_misc k_dp k_sdt k_blk
        k_br k_bx k_mrs k_msr k_mem dp_op dp_cmp dp_mov dp_rsh dec_bad dec_code cond_ok
        condition_pass always0 always2 always8 ia ib state nstate npc rom_addr pc pc_next1
        pc_next2 r15_value link_value br_target done start seq_next halt_now halt_code_now
        halt_pc_now halted halt_code halt_pc late_v late_code late_pc late_go late_code_d
        flags_we nzcv nzcv_next clr_idx msr_value always4""",
    "Shifter/ALU": """sh_type sh_imm sh_reg sh_rrx sh_amt sh_out sh_value sh_carry imm_rot op2
        op2_c always3 rs_amt value carry carry_index rotated amt5 ge32 eq32 is_left sign
        low_live high_live shift_register alu_a alu_b alu_res alu_op sum wide add_c add_v
        arith inv_a inv_b cin always5 dp_flags flags_d""",
    "Multiplier": "Mult0 prod",
    "Load/store": """acc_addr acc_rg acc_size acc_sign acc_load acc_block chk_v chk_store chk_pc
        chk_bad chk_code in_rom in_ast in_ram in_io always6 w_raw ldata always7 st_lanes
        st_bytes ram_be ram_wdata ram_we reg_wdata reg_sel reg_addr reg_write w_asset w_addr
        w_size d_addr addr_x rg_x region t_off t_regoff t_size t_sign t_wb wb_value wb_pend
        acc_go bit_p bit_u bit_b bit_w bit_l""",
    "LDM/STM": """blk_rest blk_addr blk_pre4 blk_first blk_wb ld_pend ld_idx blk_idx blk_left
        beat_addr first_reg found count_regs n_regs""",
}
ORDER = list(BLOCKS) + ["Unresolved"]
NAME_BLOCK = {n: b for b, names in BLOCKS.items() for n in names.split()}
CHAINS = re.compile(r"^(Add|LessThan|Mult)\d+$")
OUT_PORTS = {"combout", "sumout", "cout", "shareout", "q", "portadataout", "portbdataout",
             "resulta", "resultb", "o", "outclk", "chainout"}


def base(name):
    n = name[4:] if name.startswith("cpu|") else name
    return re.split(r"[~\[|]", n.split(".")[0] if n.startswith("state.") else n)[0]


def read_cells(path):
    cells = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) == 3:
            cells[f[0]] = (f[1], f[2])
    return cells


def read_netlist(path):
    """Instance -> (type, input nets, output nets), from a Quartus .vo
    netlist; nets joined by an assign are one net."""
    text = open(path).read()
    net = re.compile(r"\\(\S+)\s*(\[\d+\])?")
    alias = {}
    for a, b in re.findall(r"^assign\s+(\\\S+\s*(?:\[\d+\])?)\s*=\s*(\\\S+\s*(?:\[\d+\])?)\s*;", text, re.M):
        (na,), (nb,) = ["".join(x) for x in net.findall(a)], ["".join(x) for x in net.findall(b)]
        alias[na] = nb

    def canon(n):
        for _ in range(8):
            if n not in alias:
                break
            n = alias[n]
        return n

    inst = {}
    for m in re.finditer(r"^(cyclonev_\w+|dffeas)\s+\\(\S+)\s*\((.*?)\);\s*$", text, re.M | re.S):
        typ, name, body = m.groups()
        ins, outs = set(), set()
        for port, expr in re.findall(r"\.(\w+)\(((?:[^()]|\([^()]*\))*)\)", body):
            nets = {canon(a + b) for a, b in net.findall(expr)}
            (outs if port in OUT_PORTS else ins).update(nets)
        inst[name] = (typ, ins, outs)
    return inst


def top(votes):
    """The block with the most votes; ties go to the first in ORDER."""
    return min(votes, key=lambda b: (-votes[b], ORDER.index(b)))


def breakdown(cells, inst, vote="both"):
    driver = {}
    for name, (typ, ins, outs) in inst.items():
        for n in outs:
            driver[n] = name
    fanin = collections.defaultdict(set)
    fanout = collections.defaultdict(set)
    for name, (typ, ins, outs) in inst.items():
        for n in ins:
            d = driver.get(n)
            if d is not None and d != name:
                fanin[name].add(d)
                fanout[d].add(name)

    cpu = [c for c in cells if c.startswith("cpu|")]
    label = {}
    for c in cpu:
        b = NAME_BLOCK.get(base(c))
        if b:
            label[c] = b
    # Whatever the name: a LUT fed by the MLAB array is a read port, and a
    # LUT feeding it is the write port (Quartus names some of these after
    # ram_wdata, which shares them).
    mlab = {n for n, v in inst.items() if v[0] == "cyclonev_mlab_cell"}
    fixed = set()
    for c in cpu:
        if (cells[c][0] == "cyclonev_lcell_comb" and not CHAINS.match(base(c))
                and (fanin[c] & mlab or fanout[c] & mlab)):
            label[c] = "Register file"
            fixed.add(c)
    # The rest: a carry chain (AddN, LessThanN) as a whole, with the block of
    # most of its operands; any other cell with the block most of the cells
    # it connects to are in: its drivers and its loads ("both"), its loads
    # first ("loads") or its drivers first ("drivers").
    groups = collections.defaultdict(list)
    for c in cpu:
        if c not in fixed and c not in label and CHAINS.match(base(c)):
            groups[base(c)].append(c)
    for _ in range(50):
        changed = False
        for c in cpu:
            if c in fixed or (c in label and NAME_BLOCK.get(base(c))) or CHAINS.match(base(c)):
                continue
            v_in = collections.Counter(label[i] for i in fanin[c] if i in label)
            v_out = collections.Counter(label[o] for o in fanout[c] if o in label)
            if vote == "both":
                v = v_in + v_out
            elif vote == "loads":
                v = v_out or v_in
            else:
                v = v_in or v_out
            if v:
                new = top(v)
                if label.get(c) != new:
                    label[c] = new
                    changed = True
        for g, members in groups.items():
            inside = set(members)
            v = collections.Counter(label[i] for c in members for i in fanin[c] if i in label and i not in inside)
            if not v:
                v = collections.Counter(label[o] for c in members for o in fanout[c] if o in label and o not in inside)
            if v:
                new = top(v)
                for c in members:
                    if label.get(c) != new:
                        label[c] = new
                        changed = True
        if not changed:
            break

    # ALMs from placement. ALM k of a LAB holds LUT cells N6k and N6k+3 and
    # registers N6k+1, +2, +4, +5.
    alm = collections.defaultdict(lambda: {"lut": [], "ff": []})
    mlab_labs = set()
    stats = {b: collections.Counter() for b in ORDER}
    for c, (typ, loc) in cells.items():
        m = re.match(r"^(\w+?)_X(\d+)_Y(\d+)_N(\d+)$", loc)
        if not m:
            continue
        x, y, n = int(m.group(2)), int(m.group(3)), int(m.group(4))
        b = label.get(c, "Unresolved") if c.startswith("cpu|") else None
        if typ == "cyclonev_mlab_cell":
            mlab_labs.add((x, y))
            continue
        key = (x, y, n // 6)
        if typ == "cyclonev_lcell_comb":
            alm[key]["lut"].append(b)
            if b:
                stats[b]["luts"] += 1
        elif typ == "cyclonev_ff":
            alm[key]["ff"].append(b)
            if b:
                stats[b]["ffs"] += 1
        elif typ == "cyclonev_mac" and b:
            stats[b]["dsp"] += 1
    cpu_labs = {k[:2] for k, a in alm.items() if any(a["lut"]) or any(a["ff"])}
    used = collections.Counter()
    for a in alm.values():
        owners = a["lut"] or a["ff"]
        for b in owners:
            if b:
                used[b] += 1.0 / len(owners)
    used["Register file"] += 10 * len(mlab_labs)
    return used, stats, len(mlab_labs), len(cpu_labs)


def section(rpt, title):
    """Rows of a Quartus report table, as lists of cells."""
    text = open(rpt, errors="replace").read()
    i = text.find("; " + title)
    if i < 0:
        return []
    rows = []
    for line in text[i:].splitlines()[1:]:
        if not line.strip():
            break
        if line.startswith(";"):
            rows.append([c.strip() for c in line.strip().strip(";").split(";")])
    return rows


def main():
    d = sys.argv[1].rstrip("/")
    out = d + "/output_files/bup_probe"
    fit = out + ".fit.rpt"
    print("build: %s" % d)
    for line in open(d + "/bup_probe.sdc"):
        if line.startswith("set period"):
            print("clock period: %s ns (%.6f MHz)" % (line.split()[2], 1000 / float(line.split()[2])))

    res = {r[0]: r[1] for r in section(fit, "Fitter Resource Usage Summary") if len(r) > 1}
    print("\n# Device (whole probe: CPU, ROM, RAM, boundary registers)")
    for k in ["ALMs needed [=A-B+C]", "[A] ALMs used in final placement [=a+b+c+d]",
              "[d] ALMs used for memory (up to half of total ALMs)",
              "[B] Estimate of ALMs recoverable by dense packing", "[C] Estimate of ALMs unavailable [=a+b+c+d]",
              "[d] Due to virtual I/Os", "Total LABs:  partially or completely used",
              "-- Logic LABs", "-- Memory LABs (up to half of total LABs)", "Combinational ALUT usage for logic",
              "Dedicated logic registers", "M10K blocks", "Total MLAB memory bits", "Total DSP Blocks"]:
        print("  %-50s %s" % (k, res.get(k, "?")))

    print("\n# Resource utilization by entity")
    print("  %-46s %-16s %-16s %-12s %-10s %-8s %-4s %s" % ("entity", "ALMs needed", "ALMs used", "ALUTs",
          "registers", "mem bits", "M10K", "DSP"))
    for r in section(fit, "Fitter Resource Utilization by Entity")[1:]:
        if len(r) > 11 and r[0].startswith("|"):
            print("  %-46s %-16s %-16s %-12s %-10s %-8s %-4s %s" % (r[0], r[1], r[2], r[6], r[7], r[9], r[10], r[11]))

    print("\n# RAM summary (name; type; mode; port A/B input registers; port A/B output registers; M10K; MLABs)")
    for r in section(fit, "Fitter RAM Summary")[1:]:
        if len(r) > 19:
            print("  %s; %s; %s; in A %s / B %s; out A %s / B %s; %s M10K; %s MLAB" %
                  (r[0], r[1], r[2], r[8], r[10], r[9], r[11], r[18], r[19]))

    print("\n# DSP")
    for r in section(fit, "Fitter DSP Block Usage Summary")[1:]:
        if len(r) > 1:
            print("  %-34s %s" % (r[0], r[1]))

    sta = out + ".sta.rpt"
    print("\n# Timing (per operating condition)")
    text = open(sta, errors="replace").read()
    for cond in re.findall(r"^; ((?:Slow|Fast) \d+mV -?\d+C) Model Fmax Summary", text, re.M):
        rows = section(sta, cond + " Model Fmax Summary")
        print("  Fmax, %s: %s" % (cond, ", ".join("%s (%s)" % (r[0], r[2]) for r in rows[1:] if len(r) > 2)))
    typ = None
    for line in open(out + ".sta.summary"):
        if line.startswith("Type"):
            typ = line.split(":", 1)[1].strip() if " Setup " in line or " Hold " in line else None
        elif line.startswith("Slack") and typ:
            print("  %-46s %s" % (typ.replace(" Model", "").replace("1100mV ", "") + ":", line.split(":", 1)[1].strip()))
            typ = None
    print("\n# Five worst setup paths, slow 85 C (slack, data delay, logic levels)")
    for line in open(d + "/paths.txt"):
        print("  " + line.rstrip())
    print("\n# Worst setup path into each kind of endpoint, slow 85 C")
    for line in open(d + "/classes.txt"):
        print("  " + re.sub(r"altsyncram:u_ram\|altsyncram_\w+:auto_generated\||dpram_\w+:auto_generated\|", "", line.rstrip()))

    vo = d + "/simulation/modelsim/bup_probe.vo"
    cells = read_cells(d + "/cells.txt")
    inst = read_netlist(vo)
    runs = {v: breakdown(cells, inst, v) for v in ("both", "loads", "drivers")}
    used, stats, nmlab, nlabs = runs["both"]
    ent = {r[0].strip("|"): r for r in section(fit, "Fitter Resource Utilization by Entity")[1:] if len(r) > 2}
    cpu = next((r for k, r in ent.items() if k.endswith("bup_cpu:cpu")), None)
    need = float(cpu[1].split()[0]) if cpu else 0.0

    def needed(u, b):
        total = sum(u[x] for x in ORDER)
        return u[b] * need / total if total else 0.0

    print("\n# bup_cpu by block (estimate; see probe_report.py)")
    print("  %-16s %16s %11s %6s %5s %4s" % ("block", "ALMs needed", "ALMs placed", "LUTs", "FFs", "DSP"))
    for b in ORDER:
        alt = [needed(r[0], b) for r in runs.values()]
        print("  %-16s %5.0f [%4.0f-%4.0f] %11.1f %6d %5d %4d" % (b, needed(used, b), min(alt), max(alt), used[b],
              stats[b]["luts"], stats[b]["ffs"], stats[b]["dsp"]))
    print("  %-16s %5.0f %10s %11.1f %6d %5d %4d" % ("bup_cpu", need, "", sum(used[b] for b in ORDER),
          sum(stats[b]["luts"] for b in ORDER), sum(stats[b]["ffs"] for b in ORDER), sum(stats[b]["dsp"] for b in ORDER)))
    print("  (register file includes %d MLAB LABs at 10 ALMs each)" % nmlab)
    print("  LABs holding bup_cpu logic: %d, plus %d MLAB LABs (a sparse fit in an empty device;"
          " derived from ALMs, not measured: packed 10 ALMs to a LAB, %.0f ALMs of logic need %d)" % (nlabs, nmlab,
          need - 10 * nmlab, -(-(need - 10 * nmlab) // 10)))


if __name__ == "__main__":
    main()
