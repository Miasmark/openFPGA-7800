#!/bin/bash
# Assemble the SD card layout from a finished Quartus build:
#   dist/ + output_files/ap_core.rbf -> release/Atari7800_<version>.zip
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RBF="$ROOT/src/fpga/output_files/ap_core.rbf"
CORE="$ROOT/dist/Cores/Miasmark.7800"
VERSION=$(python3 -c "import json;print(json.load(open('$CORE/core.json'))['core']['metadata']['version'])")

[ -f "$RBF" ] || { echo "missing $RBF - build first"; exit 1; }
python3 "$ROOT/tools/reverse_bits.py" "$RBF" "$CORE/atari7800.rbf_r"

mkdir -p "$ROOT/release"
OUT="$ROOT/release/Atari7800_Pocket_${VERSION}.zip"
rm -f "$OUT"
# License texts and notices travel with the bitstream.
LIC="$CORE/licenses"
mkdir -p "$LIC"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSES/GPL-3.0.txt" "$LIC/"
cp "$ROOT/src/fpga/mister/LICENSE" "$LIC/MiSTer-Atari7800-LICENSE.txt"
cp "$ROOT/src/fpga/pocket_utils/LICENSE" "$LIC/analogue-pocket-utils-LICENSE.txt"
if command -v zip >/dev/null; then
	(cd "$ROOT/dist" && zip -r "$OUT" Cores Platforms Assets -x '*.keep')
else
	(cd "$ROOT/dist" && python3 - "$OUT" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for top in ("Cores", "Platforms", "Assets"):
        for d, _, files in os.walk(top):
            z.write(d)
            for f in files:
                if f != ".keep":
                    z.write(os.path.join(d, f))
PY
	)
fi
echo "$OUT"
