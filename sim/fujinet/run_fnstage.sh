#!/bin/bash
# tb_fnstage: FujiNet staging (fujinet_stage.sv -> bup_asset_wr.sv -> psram.sv
# on psram_model.sv) and its replay (fujinet_rd.sv -> fujinet_loader.sv), three seeds. Prints each run's result and "FNSTAGE pass"
# or "FNSTAGE FAIL".   (WORK=dir, VERILATOR=bin optional)
# SPDX-License-Identifier: MIT
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$HERE/../../src/fpga"
WORK="${WORK:-$HERE/../work/fnstage}"
V="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
"$V" --binary --timing -O2 -Wno-fatal -Wno-lint --top-module tb_fnstage -Mdir "$WORK/obj" -o vtb \
	"$FPGA/core/fujinet_stage.sv" "$FPGA/core/fujinet_loader.sv" "$FPGA/core/fujinet_rd.sv" "$FPGA/core/bupchip/bup_asset_wr.sv" "$FPGA/pocket_utils/psram.sv" \
	"$HERE/../bupchip/s4/psram_model.sv" "$HERE/tb_fnstage.sv" > "$WORK/build.log" 2>&1 \
	|| { grep -m20 '%Error' "$WORK/build.log"; echo "FNSTAGE FAIL (build)"; exit 1; }
ok=1
for s in ${SEEDS:-1 2 3}; do
	"$WORK/obj/vtb" +seed=$s > "$WORK/seed_$s.log" 2>&1
	grep -E '^FNSTAGE|psram_model.*(viol|VIOL)' "$WORK/seed_$s.log"
	grep -q "^FNSTAGE seed $s files [0-9]* fails 0$" "$WORK/seed_$s.log" || ok=0
	grep -qi 'viol' "$WORK/seed_$s.log" && ok=0
done
[ $ok = 1 ] && { echo "FNSTAGE pass"; exit 0; }
echo "FNSTAGE FAIL"; exit 1
