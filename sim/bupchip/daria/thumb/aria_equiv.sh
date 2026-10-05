#!/bin/bash
# Formal check that bup_cpu.sv with THUMB 0 is still ARIA (docs/DARIA_CORE.md,
# step 2: "ARIA unchanged"): Yosys proves the working tree's core, as Quartus
# sees it (ALTERA_RESERVED_QIS), sequentially equivalent to its version at a
# git revision, output by output, for the MODES values given.
#   ./aria_equiv.sh [REV] [MODES ...]      default: 806dcd4 (step 0), MODES 0 and 1
# The register file is mapped to flip-flops on both sides (memory_map), so
# the proof covers it too; new inputs are tied (arm_only = 1). Cell counts
# cannot show this: ABC's result moves by about 1% with any change to the
# source text, even a renamed wire. YOSYS as in yosys_cells.sh. Work files go
# to $WORK (default sim/work/bupchip/daria/yosys). Exits 0 when every proof
# succeeds.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/yosys}"
VENV="$ROOT/sim/work/bupchip/venv"
if [ -z "$YOSYS" ]; then
	if command -v yosys > /dev/null; then YOSYS=yosys
	elif [ -x "$VENV/bin/yowasp-yosys" ]; then YOSYS="$VENV/bin/yowasp-yosys"
	else echo "aria_equiv.sh: no Yosys (set YOSYS, or pip install yowasp-yosys into $VENV)" >&2; exit 2; fi
fi
REV="${1:-806dcd4}"
shift || true
MODESLIST=("$@")
[ $# -gt 0 ] || MODESLIST=(0 1)
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
git -C "$ROOT" show "$REV:src/fpga/core/bupchip/bup_cpu.sv" > "$WORK/eq_gold_src.sv"
cp "$ROOT/src/fpga/core/bupchip/bup_cpu.sv" "$WORK/eq_gate_src.sv"
cp "$ROOT/src/fpga/mister/rtl/arm7tdmi/arm7tdmi_pkg.sv" "$WORK/"
# Qualify the package's names (Yosys does not take the import in the module
# header) and rename the module per side.
for side in gold gate; do
python3 - "$WORK/eq_${side}_src.sv" "$WORK/arm7tdmi_pkg.sv" "$WORK/eq_$side.sv" "bup_$side" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
pkg = open(sys.argv[2]).read()
s2 = re.sub(r"module bup_cpu\s*\n\s*import arm7tdmi_pkg::\*;\s*\n\s*(#?)\s*\(", r"module %s \1(" % sys.argv[4], s, count=1)
assert s2 != s, "bup_cpu.sv: the module header has changed"
names = set(re.findall(r"function\s+(?:automatic\s+)?[^;(]*?\b(\w+)\s*\(", pkg))
names |= set(re.findall(r"typedef\s+(?:struct|enum|union)[^{]*\{.*?\}\s*(\w+)\s*;", pkg, re.S))
names |= set(re.findall(r"typedef\s+[^{;]*?\b(\w+)\s*;", pkg))
names |= set(re.findall(r"\b([A-Z][A-Z0-9_]+)\s*=", pkg))
for n in sorted(names):
    s2 = re.sub(r"(?<![\w:$])%s\b" % n, "arm7tdmi_pkg::" + n, s2)
open(sys.argv[3], "w").write(s2)
PY
done
# The gate's ports beyond the gold's are tied here.
GATE_TIES=""
grep -q "arm_only" "$WORK/eq_gate.sv" && GATE_TIES="$GATE_TIES .arm_only(1'b1),"
FAIL=0
for m in "${MODESLIST[@]}"; do
	cat > "$WORK/eq_wrap_$m.sv" <<SV
module gold (input wire clk, rst, freeze, w_wait, input wire [31:0] rom_q, rom_dq, ram_q, asset_q, reg_rdata,
	input wire [23:0] asset_size, output wire [11:0] rom_addr, output wire [31:0] d_addr, ram_wdata, w_addr,
	reg_wdata, halt_pc, output wire [3:0] ram_be, halt_code, output wire [1:0] w_size, output wire [7:0] reg_addr,
	output wire ram_we, w_asset, reg_sel, reg_write, halted);
	bup_gold #(.MODES($m)) u (.*);
endmodule
module gate (input wire clk, rst, freeze, w_wait, input wire [31:0] rom_q, rom_dq, ram_q, asset_q, reg_rdata,
	input wire [23:0] asset_size, output wire [11:0] rom_addr, output wire [31:0] d_addr, ram_wdata, w_addr,
	reg_wdata, halt_pc, output wire [3:0] ram_be, halt_code, output wire [1:0] w_size, output wire [7:0] reg_addr,
	output wire ram_we, w_asset, reg_sel, reg_write, halted);
	bup_gate #(.MODES($m)) u ($GATE_TIES .*);
endmodule
SV
	cat > "$WORK/eq_$m.ys" <<YS
read_verilog -sv -DALTERA_RESERVED_QIS arm7tdmi_pkg.sv eq_gold.sv eq_gate.sv eq_wrap_$m.sv
hierarchy -check
proc
flatten
opt_clean
memory -nomap
memory_map
opt -fast
async2sync
equiv_make gold gate equiv
hierarchy -top equiv
equiv_simple -seq 4
equiv_struct
equiv_simple -seq 4
equiv_induct -seq 4
equiv_status -assert
YS
	if (cd "$WORK" && "$YOSYS" -q -l "eq_$m.log" "eq_$m.ys" > /dev/null 2>&1); then
		echo "MODES $m: equivalent to $REV ($(grep -m1 -o 'Found [0-9]* \$equiv cells' "$WORK/eq_$m.log" || echo proven))"
	else
		echo "MODES $m: NOT proven equivalent to $REV, see $WORK/eq_$m.log"; FAIL=1
	fi
done
exit $FAIL
