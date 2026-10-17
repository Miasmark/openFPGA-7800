#!/bin/bash
# The depth of the register-index path in the real bup_cpu.sv (docs/
# DARIA_CORE.md, "Where the expander sits", and step 2's done-when): the
# logic from rom_q and the registered state to the two physical read
# indices (pa, pb), in LUT6 levels after abc -lut 6, for ARIA (THUMB 0,
# MODES 1) and DARIA (THUMB 1).
#   ./index_depth.sh
# Every flip-flop is cut into a port first (expose -evert-dff), so only the
# combinational cone of pa and pb counts; ltp then gives its longest path.
# YOSYS as in yosys_cells.sh. Work files go to $WORK (default
# sim/work/bupchip/daria/yosys).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/yosys}"
VENV="$ROOT/sim/work/bupchip/venv"
if [ -z "$YOSYS" ]; then
	if command -v yosys > /dev/null; then YOSYS=yosys
	elif [ -x "$VENV/bin/yowasp-yosys" ]; then YOSYS="$VENV/bin/yowasp-yosys"
	else echo "index_depth.sh: no Yosys (set YOSYS, or pip install yowasp-yosys into $VENV)" >&2; exit 2; fi
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
cp "$ROOT/src/fpga/mister/rtl/arm7tdmi/arm7tdmi_pkg.sv" "$WORK/"
python3 - "$ROOT/src/fpga/core/bupchip/bup_cpu.sv" "$WORK/arm7tdmi_pkg.sv" "$WORK/idx_cpu.sv" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
pkg = open(sys.argv[2]).read()
s2 = re.sub(r"module bup_cpu\s*\n\s*import arm7tdmi_pkg::\*;\s*\n\s*(#?)\s*\(", r"module bup_cpu \1(", s, count=1)
assert s2 != s, "bup_cpu.sv: the module header has changed"
names = set(re.findall(r"function\s+(?:automatic\s+)?[^;(]*?\b(\w+)\s*\(", pkg))
names |= set(re.findall(r"typedef\s+(?:struct|enum|union)[^{]*\{.*?\}\s*(\w+)\s*;", pkg, re.S))
names |= set(re.findall(r"typedef\s+[^{;]*?\b(\w+)\s*;", pkg))
names |= set(re.findall(r"\b([A-Z][A-Z0-9_]+)\s*=", pkg))
for n in sorted(names):
    s2 = re.sub(r"(?<![\w:$])%s\b" % n, "arm7tdmi_pkg::" + n, s2)
open(sys.argv[3], "w").write(s2)
PY
for t in 0 1; do
	cat > "$WORK/idx_$t.ys" <<YS
read_verilog -sv -DALTERA_RESERVED_QIS arm7tdmi_pkg.sv idx_cpu.sv
hierarchy -top bup_cpu -chparam MODES 1 -chparam THUMB $t
setattr -set keep 1 w:pa w:pb
synth -flatten -top bup_cpu
abc -lut 6
opt_clean
write_json idx_$t.json
YS
	(cd "$WORK" && "$YOSYS" -q -l "idx_$t.log" "idx_$t.ys" > /dev/null 2>&1) || { echo "Yosys failed: $WORK/idx_$t.log" >&2; exit 1; }
	python3 - "$WORK/idx_$t.json" "$t" <<'PY'
import json, sys
sys.setrecursionlimit(100000)
m = json.load(open(sys.argv[1]))["modules"]["bup_cpu"]
drv = {}                                # bit -> (cell type, input bits)
for c in m["cells"].values():
    ins = [b for p, d in c["port_directions"].items() if d == "input" for b in c["connections"][p]]
    for p, d in c["port_directions"].items():
        if d == "output":
            for b in c["connections"][p]:
                drv[b] = (c["type"], ins)
memo = {}
def depth(b):                           # LUT levels from a flip-flop, port or constant
    if isinstance(b, str) or b not in drv:
        return 0
    if b in memo:
        return memo[b]
    typ, ins = drv[b]
    memo[b] = 0
    d = 0 if typ != "$lut" else 1 + max([depth(x) for x in ins] or [0])
    memo[b] = d
    return d
res = {}
for n in ("pa", "pb"):
    bits = m["netnames"][n]["bits"]
    res[n] = max(depth(x) for x in bits)
luts = sum(1 for c in m["cells"].values() if c["type"] == "$lut")
print("THUMB %s: index path pa %d, pb %d LUT6 levels (abc -lut 6; %d LUTs in the core)" % (sys.argv[2], res["pa"], res["pb"], luts))
PY
done
