#!/bin/bash
# The PCM FIFO sizing experiment of the design study (docs/BUPCHIP_CORE.md,
# "PCM and command FIFOs"): MiSTer's reference BupChip with the PCM FIFO cut
# to DEPTH frames, with or without the watermark remap, booting CoreTone on
# the synthetic ARSC block (../../../verif/make_synth_arsc.py, no game data).
# tb_fifo.sv reports the boot, the PCM-enable point and the steady FIFO level.
#   ./run_fifo.sh ["DEPTH REMAP" ...]   default: "512 0" "512 1" "1024 0" "1024 1" "4096 0"
# The reference files are not edited: bupchip_peripheral.sv and
# bupchip_subsystem.sv (MIT, Jamie Blanks) are copied into $WORK with the
# module renamed, PCM_DEPTH passed down and, with REMAP=1, the watermark
# written as clamp(W - (4096 - DEPTH), 0, DEPTH), as the Pocket's bus glue
# will. MS (default 100) simulated milliseconds per run, JOBS at once
# (default nproc). Work files go to $WORK (default
# sim/work/bupchip/study/fifo). Needs the firmware at
# src/fpga/mister/rtl/bupchip.hex. Exits 0 when 512 frames without the remap
# deadlock (the prefill loop at 0x140-0x14c pushes into a full FIFO for ever,
# PCM never enabled) and 1,024 with it run with no underflow or overflow.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../../src/fpga/mister/rtl" && pwd)"
VERIF="$(cd "$HERE/../../../verif" && pwd)"
WORK="${WORK:-$HERE/../../../../work/bupchip/study/fifo}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
[ -f "$RTL/bupchip.hex" ] || { echo "run_fifo.sh: no firmware at $RTL/bupchip.hex (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2; exit 2; }
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
CASES=("$@")
[ $# -gt 0 ] || CASES=("512 0" "512 1" "1024 0" "1024 1" "4096 0")

python3 - "$RTL" "$WORK" <<'EOF'
import sys
rtl, work = sys.argv[1:3]
def patch(name, edits):
    s = open(f"{rtl}/{name}.sv").read()
    for old, new in edits:
        assert s.count(old) == 1, f"{name}.sv: cannot find {old!r}"
        s = s.replace(old, new)
    open(f"{work}/{name}_mod.sv", "w").write(s)
patch("bupchip_peripheral", [
    ("module bupchip_peripheral #(",
     "module bupchip_peripheral_mod #(\n\tparameter int CONTRACT_DEPTH = 4096,\n\tparameter bit REMAP = 1'b0,"),
    ("pcm_watermark <= reg_wdata[16 +: PCM_AW+1];",
     "if (!REMAP) pcm_watermark <= reg_wdata[16 +: PCM_AW+1];\n"
     "\t\t\t\t\t\telse if (reg_wdata[28:16] <= 13'(CONTRACT_DEPTH - PCM_DEPTH)) pcm_watermark <= '0;\n"
     "\t\t\t\t\t\telse if (reg_wdata[28:16] - 13'(CONTRACT_DEPTH - PCM_DEPTH) >= 13'(PCM_DEPTH))"
     " pcm_watermark <= (PCM_AW+1)'(PCM_DEPTH);\n"
     "\t\t\t\t\t\telse pcm_watermark <= (PCM_AW+1)'(reg_wdata[28:16] - 13'(CONTRACT_DEPTH - PCM_DEPTH));"),
])
patch("bupchip_subsystem", [
    ("module bupchip_subsystem #(",
     "module bupchip_subsystem_mod #(\n\tparameter int PCM_DEPTH = 4096,\n\tparameter bit REMAP = 1'b0,"),
    ("bupchip_peripheral peripheral (",
     "bupchip_peripheral_mod #(.PCM_DEPTH(PCM_DEPTH), .REMAP(REMAP)) peripheral ("),
])
EOF
python3 "$VERIF/make_synth_arsc.py" "$WORK/synth.a78" > /dev/null

one() {	# DEPTH REMAP -> $WORK/d<DEPTH>_r<REMAP>/run.log
	local d="$WORK/d$1_r$2"
	mkdir -p "$d"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_fifo -DROMHEX="\"$RTL/bupchip.hex\"" -DPCMD="$1" -DREMAPV="$2" \
		"$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/arm7tdmi/arm7tdmi_core.sv" "$RTL/arm_host.sv" \
		"$RTL/cache_ram.v" "$RTL/bram.v" "$RTL/bupchip_memory.sv" "$WORK/bupchip_peripheral_mod.sv" \
		"$RTL/bupchip_asset_ddr.sv" "$WORK/bupchip_subsystem_mod.sv" "$HERE/tb_fifo.sv" \
		-Mdir "$d/obj" -o vtb > "$d/build.log" 2>&1 || { echo "build failed: $d/build.log"; return 1; }
	find "$d/obj" -name '*.gch' -delete
	cp "$WORK/synth.a78" "$d/"
	(cd "$d" && ./obj/vtb +ms="${MS:-100}" | grep -v "^- " > run.log)
}
export -f one
export WORK RTL HERE VERILATOR MS
printf '%s\n' "${CASES[@]}" | xargs -P "${JOBS:-$(nproc)}" -I{} bash -c 'one {}'
for c in "${CASES[@]}"; do
	set -- $c
	cat "$WORK/d$1_r$2/run.log"
done
ok=1
if [ -f "$WORK/d512_r0/run.log" ]; then
	grep -q "pcm_enabled 0, PC 0000014[0-9a-f]" "$WORK/d512_r0/run.log" && grep -q "sticky overflow 1" "$WORK/d512_r0/run.log" ||
		{ echo "FAIL: 512 frames without the remap did not deadlock in the prefill loop (0x140-0x14c)"; ok=0; }
fi
if [ -f "$WORK/d1024_r1/run.log" ]; then
	grep -q "pcm_enabled 1," "$WORK/d1024_r1/run.log" &&
		grep -q "pops of an empty FIFO 0" "$WORK/d1024_r1/run.log" &&
		grep -q "sticky overflow 0 underflow 0" "$WORK/d1024_r1/run.log" ||
		{ echo "FAIL: 1,024 frames with the remap"; ok=0; }
fi
[ $ok = 1 ] && echo "PASS" || exit 1
