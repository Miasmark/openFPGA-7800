#!/bin/bash
# The verifier's directed tests for the new core (vgen.py, vhalt.py,
# tb_vdec.sv), in four parts:
#   1. vgen.py writes the v_*.S tests; run.sh runs each on the reference RTL
#      (end marker, no abort), on tb_s1.sv (no halt) and in lockstep with
#      the new core (DUT=bup), plainly and with random asset waits and
#      throttle clocks;
#   2. the tests vgen.py lists in iss.txt (inside the subset ARMv4 and ARMv5
#      agree on) through ../isa/run_isa.sh: the reference's signature and
#      instruction count must equal Unicorn's, and the new core must agree
#      in lockstep;
#   3. vhalt.py: more halt cases, and edge cases that must not halt, on
#      tb_s1.sv;
#   4. when the user's firmware (src/fpga/mister/rtl/bupchip.hex) is there,
#      tb_vdec.sv: none of its 1,704 code words may decode as a halt.
#   ./run_vfy.sh
# LATE_RF=1 builds the core with BUP_SIM_LATE_RF throughout. Work files go to
# $WORK (default sim/work/bupchip/verif/vfy, or vfy_laterf); the reference
# and lockstep builds are shared with ../ ($VWORK) and tb_s1 with ../../s1
# ($S1WORK). Unicorn as for run_isa.sh (VENV or PYTHON). About 30 seconds
# once those are built. Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/.." && pwd)"
S1="$(cd "$HERE/../../s1" && pwd)"
SUFFIX=""
[ "${LATE_RF:-0}" = 0 ] || SUFFIX=_laterf
WORK="${WORK:-$HERE/../../../work/bupchip/verif/vfy$SUFFIX}"
VWORK="${VWORK:-$HERE/../../../work/bupchip/verif}"
S1WORK="${S1WORK:-$HERE/../../../work/bupchip/s1}"
VENV="${VENV:-$HERE/../../../work/bupchip/venv}"
mkdir -p "$WORK/iss" "$VWORK" "$S1WORK"
WORK="$(cd "$WORK" && pwd)"
VWORK="$(cd "$VWORK" && pwd)"
S1WORK="$(cd "$S1WORK" && pwd)"
VENV="$(cd "$VENV" 2>/dev/null && pwd || echo "$VENV")"
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}

python3 "$HERE/vgen.py" "$WORK/gen"
step "v_*.S: reference, tb_s1 and lockstep (run.sh)" \
	env WORK="$WORK/run" VWORK="$VWORK" S1WORK="$S1WORK" "$HERE/run.sh" "$WORK"/gen/v_*.S

# run_isa.sh builds into its own WORK; lend it the builds already in $VWORK.
LOCK=obj_lockstep_bup
[ -z "$SUFFIX" ] || LOCK=obj_lockstep_bup_laterf
for o in obj_ref_trace "$LOCK"; do
	[ -e "$WORK/iss/$o" ] || [ ! -d "$VWORK/$o" ] || ln -s "$VWORK/$o" "$WORK/iss/$o"
done
ISS_TESTS=()
while read -r t; do [ -n "$t" ] && ISS_TESTS+=("$WORK/gen/$t.S"); done < "$WORK/gen/iss.txt"
step "${#ISS_TESTS[@]} of them against Unicorn and in lockstep (../isa/run_isa.sh)" \
	env WORK="$WORK/iss" VENV="$VENV" ISS=1 LOCKSTEP=1 DUT=bup "$VERIF/isa/run_isa.sh" "${ISS_TESTS[@]}"

S1_BIN="$(WORK="$S1WORK" "$S1/build_s1.sh")"
step "halt and no-halt cases on tb_s1 (vhalt.py)" \
	python3 "$HERE/vhalt.py" "$S1_BIN" "$WORK/halt" "$WORK/run/assets.a78"

# With the user's firmware in place: none of its code words may decode as a halt.
vdec() {
	local d="$WORK/vdec" core
	core="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
	mkdir -p "$d"
	(cd "$HERE/../../model" && python3 -B -c 'import inventory
for a in sorted(inventory.discover()[0]): print("%08x %08x" % (a, inventory.W[a // 4]))') > "$d/code.txt" || return 1
	"$VERILATOR" --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_vdec \
		-Mdir "$d/obj" -o vtb "$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$core/bup_cpu.sv" "$HERE/tb_vdec.sv" \
		> "$d/build.log" 2>&1 || { echo "build failed: $d/build.log"; return 1; }
	(cd "$d" && ./obj/vtb +list=code.txt) | grep -v "^- " | tee "$d/vdec.log"
	grep -q "^decode probe: 1704 code words, 0 decode as a halt" "$d/vdec.log"
}
RTL="$(cd "$HERE/../../../../src/fpga/mister/rtl" && pwd)"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
if [ -f "$RTL/bupchip.hex" ]; then
	step "every firmware code word decodes without a halt (tb_vdec.sv)" vdec
else
	echo "=== no $RTL/bupchip.hex (user-supplied, docs/BUPCHIP.md): decode probe skipped"
fi

echo
echo "=== summary"
printf '%s\n' "${RESULTS[@]}"
! printf '%s\n' "${RESULTS[@]}" | grep -q "^FAIL"
