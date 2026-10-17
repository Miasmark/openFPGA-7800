#!/bin/bash
# Halt tests of DARIA's Thumb (docs/DARIA_CORE.md, "What halts" and
# "Verification", the "Halts" row): halt_thumb.py, one program per case, on
# the core alone (tb_thumb.sv, plain, LATE_RF=1, and with throttle and
# asset waits), each halting with the expected code at the expected
# address; the reference (../../verif/tb_ref_trace.sv) takes its UNDEF or
# SWI exception at the same address, or runs the BX and H1 = H2 = 0 forms
# naturally; the neighbours that must not halt also pass in lockstep
# (../../verif/tb_lockstep.sv, DUT=bup THUMB=1, and ARM_ONLY=1 for the
# BupChip profile's).
#   ./run_halts.sh [NAME ...]      only the cases whose names contain NAME
# JOBS (default 2) cases run at once. The image carries 1 KiB of asset
# bytes, so 0x02000400 is past the asset window. Work files and builds go
# to $WORK (default sim/work/bupchip/daria/thumb). Exits 0 when every case
# passes.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/../../verif" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/thumb}"
mkdir -p "$WORK/halt"
WORK="$(cd "$WORK" && pwd)"
export WORK
IMG="$WORK/assets.a78"
T0=$(date +%s)

python3 - "$IMG" <<'EOF'
import sys
h = bytearray(128)
h[0] = 3
h[1:10] = b"ATARI7800"
h[49:53] = (4096).to_bytes(4, "big")
h[100:128] = b"ACTUAL CART DATA STARTS HERE"
assets = bytes((i * 37 + 0x81) & 0xff for i in range(1024))
open(sys.argv[1], "wb").write(bytes(h) + bytes([0xff]) * 4096 + assets)
EOF

TB="$("$HERE/build_tb.sh")"
TB_LATE="$(LATE_RF=1 "$HERE/build_tb.sh")"
REF_BIN="$("$VERIF/build.sh" ref_trace tb_ref_trace)"
LOCK_BIN="$(DUT=bup THUMB=1 "$VERIF/run_lockstep.sh" --build)"
LOCK_AO="$(DUT=bup THUMB=1 ARM_ONLY=1 "$VERIF/run_lockstep.sh" --build)"
st=0
python3 "$HERE/halt_thumb.py" "$WORK/halt" "$IMG" "$TB" "$TB_LATE" "$REF_BIN" "$LOCK_BIN" "$LOCK_AO" "$@" || st=$?
echo "halt tests: $(( $(date +%s) - T0 )) s"
exit $st
