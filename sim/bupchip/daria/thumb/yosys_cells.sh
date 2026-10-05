#!/bin/bash
# Yosys cell counts of bup_cpu.sv (docs/DARIA_CORE.md, step 2: "ARIA
# unchanged"): synth_intel_alm for Cyclone V, as Quartus sees the core
# (ALTERA_RESERVED_QIS, so without the simulation-only retire port).
#   ./yosys_cells.sh [-r REV | -f FILE] [PARAM=VALUE ...]
# reads src/fpga/core/bupchip/bup_cpu.sv, or with -r its version at git
# revision REV, or FILE, sets the parameters given (MODES, THUMB, CODE_AW) and prints
# one line: LUTs (MISTRAL_ALUT2-6 and NOT), arithmetic cells, flip-flops,
# MLAB cells, DSP blocks. Yosys does not take the package import in the
# module header, so a copy with the package's names qualified is read (as
# sim/bupchip/model/study/area/run_area.sh does). YOSYS: default yosys on the
# PATH, else the YoWASP build in sim/work/bupchip/venv (pip install
# yowasp-yosys). Work files go to $WORK (default sim/work/bupchip/daria/yosys).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/yosys}"
VENV="$ROOT/sim/work/bupchip/venv"
if [ -z "$YOSYS" ]; then
	if command -v yosys > /dev/null; then YOSYS=yosys
	elif [ -x "$VENV/bin/yowasp-yosys" ]; then YOSYS="$VENV/bin/yowasp-yosys"
	else echo "yosys_cells.sh: no Yosys (set YOSYS, or pip install yowasp-yosys into $VENV)" >&2; exit 2; fi
fi
REV=""
FILE=""
if [ "$1" = -r ]; then REV="$2"; shift 2; elif [ "$1" = -f ]; then FILE="$(realpath "$2")"; shift 2; fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
TAG="$(echo "${REV:-${FILE:-work}} $*" | tr -c 'A-Za-z0-9_=\n' _)"
if [ -n "$REV" ]; then git -C "$ROOT" show "$REV:src/fpga/core/bupchip/bup_cpu.sv" > "$WORK/src_$TAG.sv"
elif [ -n "$FILE" ]; then cp "$FILE" "$WORK/src_$TAG.sv"
else cp "$ROOT/src/fpga/core/bupchip/bup_cpu.sv" "$WORK/src_$TAG.sv"; fi
cp "$ROOT/src/fpga/mister/rtl/arm7tdmi/arm7tdmi_pkg.sv" "$WORK/"
python3 - "$WORK/src_$TAG.sv" "$WORK/arm7tdmi_pkg.sv" "$WORK/cpu_$TAG.sv" <<'PY'
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
CH=""
for p in "$@"; do CH="$CH -chparam ${p%%=*} ${p#*=}"; done
printf 'read_verilog -sv -DALTERA_RESERVED_QIS arm7tdmi_pkg.sv cpu_%s.sv\nhierarchy -top bup_cpu%s\nsynth_intel_alm -family cyclonev -top bup_cpu -noiopad -noclkbuf\nflatten\nstat\n' \
	"$TAG" "$CH" > "$WORK/$TAG.ys"
(cd "$WORK" && "$YOSYS" -q -l "$TAG.log" "$TAG.ys" > /dev/null 2>&1) || { echo "Yosys failed, see $WORK/$TAG.log" >&2; exit 1; }
python3 - "${REV:-${FILE:-working tree}} $*" "$WORK/$TAG.log" <<'PY'
import re, sys
name, log = sys.argv[1:3]
text = open(log).read()
text = text[text.rfind("Printing statistics"):]
c = {}
for n, cell in re.findall(r"^\s+(\d+)\s+(MISTRAL_\w+)", text, re.M):
    c[cell] = c.get(cell, 0) + int(n)
lut = sum(v for k, v in c.items() if re.match(r"MISTRAL_ALUT\d$", k)) + c.get("MISTRAL_NOT", 0)
dsp = c.get("MISTRAL_MUL18X18", 0) + c.get("MISTRAL_MUL27X27", 0) + c.get("MISTRAL_MUL9X9", 0)
print("%-40s %5d LUT %5d arith %5d FF %4d MLAB %2d DSP" % (name, lut, c.get("MISTRAL_ALUT_ARITH", 0),
      c.get("MISTRAL_FF", 0), c.get("MISTRAL_MLAB", 0), dsp))
PY
