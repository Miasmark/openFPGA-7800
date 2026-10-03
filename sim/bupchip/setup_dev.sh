#!/bin/bash
# Set up a BupChip ARM-core work area: installs tools (apt), builds the
# testbench, and disassembles the firmware to $WORK/fw.dis for reference.
#   ./setup_dev.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../../src/fpga/mister/rtl"
WORK="${WORK:-$HERE/../work/bupchip}"
mkdir -p "$WORK"
command -v verilator >/dev/null && command -v arm-none-eabi-objdump >/dev/null || \
	apt-get install -y -q verilator iverilog gcc-arm-none-eabi binutils-arm-none-eabi
# Verilator 5.040 is required (5.020 compiles but is too old for the upstream sources).
if [ ! -x /opt/verilator-5.040/bin/verilator ]; then
	apt-get install -y -q autoconf flex bison help2man libfl-dev ccache make g++ perl ghdl
	T="$(mktemp -d)"
	git clone -q --depth 1 --branch v5.040 https://github.com/verilator/verilator "$T/v"
	(cd "$T/v" && autoconf && ./configure --prefix=/opt/verilator-5.040 && make -j"$(nproc)" && make install)
fi
# Quartus Prime Lite 21.1.1 runs from the same image CI uses (needs a running dockerd).
docker image inspect raetro/quartus:21.1 >/dev/null 2>&1 || docker pull raetro/quartus:21.1
python3 - "$RTL/bupchip.hex" "$WORK/fw.bin" <<'PY'
import struct, sys
w = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], "wb").write(b"".join(struct.pack("<I", x) for x in w))
PY
arm-none-eabi-objdump -D -b binary -marm "$WORK/fw.bin" > "$WORK/fw.dis"
echo "firmware disassembly: $WORK/fw.dis"
echo "build + run the testbench with run_bupchip.sh GAME.a78 SONG SECS"
