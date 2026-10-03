#!/bin/bash
# Yosys cell counts for the design study (docs/BUPCHIP_CORE.md, the [syn]
# figures): synth_intel_alm for Cyclone V on
#   - the datapath blocks in parts.sv (shifter in two forms, ALU, multiplier,
#     load lanes, register file, LDM/STM priority encoder);
#   - the study's two whole-core sketches: proposal B's CPU
#     (../sketch/bup_cpu.sv) and proposal A's (bup_core_sketch.sv), the
#     latter with its register file in flip-flops (RF_LVT=0) and in MLAB
#     (RF_LVT=1);
#   - the S1 core, src/fpga/core/bupchip/bup_cpu.sv, as Quartus would see it
#     (ALTERA_RESERVED_QIS; Yosys does not take the package import in the
#     module header, so a copy with the package's names qualified is read);
#   - MiSTer's bupchip_peripheral at CMD 8 / PCM 1,024.
#   ./run_area.sh [NAME ...]        default: all of them
# YOSYS (default: yosys on the PATH, else the YoWASP build in
# sim/work/bupchip/venv: pip install yowasp-yosys). The study used Yosys
# 0.69. Prints one line per design: LUTs (MISTRAL_ALUT2-6 and NOT),
# arithmetic cells, flip-flops, MLAB and M10K cells, DSP blocks. Work files
# go to $WORK (default sim/work/bupchip/study/area). No game or firmware is
# needed: the sketch's ROM is filled with a fixed pseudo-random image.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../../../work/bupchip/study/area}"
VENV="$HERE/../../../../work/bupchip/venv"
if [ -z "$YOSYS" ]; then
	if command -v yosys > /dev/null; then YOSYS=yosys
	elif [ -x "$VENV/bin/yowasp-yosys" ]; then YOSYS="$VENV/bin/yowasp-yosys"
	else echo "run_area.sh: no Yosys (set YOSYS, or pip install yowasp-yosys into $VENV)" >&2; exit 2; fi
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

# The sketch CPU's ROM image (read from $WORK), and the S1 core with the
# package's names qualified.
python3 - "$WORK/rom.hex" <<'EOF'
import sys
x = 0x12345678
with open(sys.argv[1], "w") as f:
    for _ in range(2048):
        x = (x * 1103515245 + 12345) & 0xffffffff
        f.write("%08x\n" % x)
EOF
python3 - "$CORE/bup_cpu.sv" "$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$WORK/bup_cpu_s1.sv" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
pkg = open(sys.argv[2]).read()
s2 = re.sub(r"module bup_cpu\s*\n\s*import arm7tdmi_pkg::\*;\s*\n\s*\(", "module bup_cpu (", s, count=1)
assert s2 != s, "bup_cpu.sv: the module header has changed"
# Qualify the package's functions, types and enum values instead.
names = set(re.findall(r"function\s+(?:automatic\s+)?[^;(]*?\b(\w+)\s*\(", pkg))
names |= set(re.findall(r"typedef\s+(?:struct|enum|union)[^{]*\{.*?\}\s*(\w+)\s*;", pkg, re.S))
names |= set(re.findall(r"typedef\s+[^{;]*?\b(\w+)\s*;", pkg))
names |= set(re.findall(r"\b([A-Z][A-Z0-9_]+)\s*=", pkg))
for n in sorted(names):
    s2 = re.sub(r"(?<![\w:$])%s\b" % n, "arm7tdmi_pkg::" + n, s2)
open(sys.argv[3], "w").write(s2)
EOF

# Yosys reads everything from $WORK (YoWASP sees only the directory it runs in).
cp "$HERE/parts.sv" "$HERE/bup_core_sketch.sv" "$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" \
	"$RTL/bupchip_peripheral.sv" "$WORK/"
sed 's/parameter ROM_HEX = "bupchip.hex"/parameter ROM_HEX = "rom.hex"/' "$HERE/../sketch/bup_cpu.sv" > "$WORK/bup_cpu_sketch.sv"
grep -q '"rom.hex"' "$WORK/bup_cpu_sketch.sv" || { echo "run_area.sh: the sketch's ROM_HEX default has changed" >&2; exit 1; }

synth() {	# NAME TOP "READ COMMANDS" ["HIERARCHY ARGS"]
	local name="$1" top="$2" reads="$3" hier="$4"
	printf '%s\nhierarchy -top %s %s\nsynth_intel_alm -family cyclonev -top %s -noiopad -noclkbuf\nflatten\nstat\n' \
		"$reads" "$top" "$hier" "$top" > "$WORK/$name.ys"
	(cd "$WORK" && "$YOSYS" -q -l "$name.log" "$name.ys" > /dev/null 2>&1) || { echo "$name: Yosys failed, see $WORK/$name.log"; return 1; }
	python3 - "$name" "$WORK/$name.log" <<'EOF'
import re, sys
name, log = sys.argv[1:3]
text = open(log).read()
text = text[text.rfind("Printing statistics"):]
c = {}
for n, cell in re.findall(r"^\s+(\d+)\s+(MISTRAL_\w+)", text, re.M):
    c[cell] = c.get(cell, 0) + int(n)
lut = sum(v for k, v in c.items() if re.match(r"MISTRAL_ALUT\d$", k)) + c.get("MISTRAL_NOT", 0)
dsp = c.get("MISTRAL_MUL18X18", 0) + c.get("MISTRAL_MUL27X27", 0) + c.get("MISTRAL_MUL9X9", 0)
print("%-18s %5d LUT %5d arith %5d FF %4d MLAB %3d M10K %2d DSP" % (name, lut, c.get("MISTRAL_ALUT_ARITH", 0),
      c.get("MISTRAL_FF", 0), c.get("MISTRAL_MLAB", 0), c.get("MISTRAL_M10K", 0), dsp))
EOF
}

ALL=(p_shift p_shift2 p_alu p_mul p_ld p_rf p_pe sketch_b sketch_a_ff sketch_a_mlab s1_core peripheral)
NAMES=("$@")
[ $# -gt 0 ] || NAMES=("${ALL[@]}")
for n in "${NAMES[@]}"; do
	case "$n" in
		p_*) synth "$n" "$n" "read_verilog -sv parts.sv" ;;
		sketch_b) synth "$n" bup_cpu "read_verilog -sv -DSYNTH bup_cpu_sketch.sv" ;;
		sketch_a_ff) synth "$n" bup_core_sketch "read_verilog -sv arm7tdmi_pkg.sv bup_core_sketch.sv" "-chparam RF_LVT 0" ;;
		sketch_a_mlab) synth "$n" bup_core_sketch "read_verilog -sv arm7tdmi_pkg.sv bup_core_sketch.sv" "-chparam RF_LVT 1" ;;
		s1_core) synth "$n" bup_cpu "read_verilog -sv -DALTERA_RESERVED_QIS arm7tdmi_pkg.sv bup_cpu_s1.sv" ;;
		peripheral) synth "$n" bupchip_peripheral "read_verilog -sv -DNO_MEM_EDITOR cache_ram.v bupchip_peripheral.sv" \
			"-chparam CMD_DEPTH 8 -chparam PCM_DEPTH 1024" ;;
		*) echo "unknown design $n (one of: ${ALL[*]})" >&2; exit 2 ;;
	esac
done
