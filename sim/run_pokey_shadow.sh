#!/bin/bash
# Build tb_load with upstream's new POKEY (rtl/Pokey) running as a shadow of
# the Watson POKEY the Pocket uses: same clock, phases, bus and writes, cycle
# for cycle, its output recorded but never heard or read by the CPU. Any
# difference between the two recordings is the new POKEY's own doing.
#   sim/run_pokey_shadow.sh            build into $WORK/obj_shadow
# then, in $WORK:
#   ./obj_shadow/vtb +image=CART.a78 +wav=MS
# writes pokey_watson.pcm and pokey_new.pcm (48,052 Hz, 16 bit, the AUD node
# of each) next to the usual audio_raw.pcm.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../src/fpga/mister/rtl"
WORK="${WORK:-$HERE/work}"
SH="$WORK/shadow"
mkdir -p "$SH"

# The new POKEY's adapter, renamed so it can sit beside Watson's.
sed 's/^module pokey_adapter (/module pokey_adapter_new (/' "$RTL/Pokey/pokey_adapter.sv" > "$SH/pokey_adapter_new.sv"
# FIXPOKEY=1: the candidate fix - the adapter captures the CPU's write at
# the phase 2 strobe and holds it for the rest of phase 2, so a bus that
# moves on early cannot change which register the write lands on.
if [ -n "$FIXPOKEY" ]; then
	python3 - "$SH/pokey_adapter_new.sv" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """	wire  [3:0] a_i    = boot_wr ? 4'hF : ADDR;
	wire  [7:0] d_in_i = boot_wr ? (in_reset ? 8'h00 : 8'h03) : DATA_IN;
	wire        rw_i   = boot_wr ? 1'b0 : ~WR_EN;"""
new = """	// Hold the CPU's write through phase 2 (FIXPOKEY).
	logic       in_o2 = 1'b0;
	logic [3:0] addr_h; logic [7:0] data_h; logic wr_h;
	always_ff @(posedge CLK) begin
		if (PHI2_EN) begin in_o2 <= 1'b1; addr_h <= ADDR; data_h <= DATA_IN; wr_h <= WR_EN; end
		else if (PHI1_EN) in_o2 <= 1'b0;
	end
	wire        held   = in_o2 & ~PHI2_EN;
	wire  [3:0] addr_e = held ? addr_h : ADDR;
	wire  [7:0] data_e = held ? data_h : DATA_IN;
	wire        wr_e   = held ? wr_h   : WR_EN;
	wire  [3:0] a_i    = boot_wr ? 4'hF : addr_e;
	wire  [7:0] d_in_i = boot_wr ? (in_reset ? 8'h00 : 8'h03) : data_e;
	wire        rw_i   = boot_wr ? 1'b0 : ~wr_e;"""
assert old in s, "adapter text changed"
s = s.replace(old, new, 1).replace("wire   read_sel = ~boot_wr & ~WR_EN;", "wire   read_sel = ~boot_wr & ~wr_e;")
open(p, "w").write(s)
PY
fi

# cart.sv with the shadow wired in parallel to the 4000 POKEY (the_penguin).
python3 - "$RTL/cart.sv" "$SH/cart.sv" <<'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "pokey_adapter return_of_pokey ("
assert anchor in s
shadow = """// SIM ONLY: upstream's new POKEY, shadowing the_penguin.
wire [15:0] shadow_aud;
wire  [3:0] shadow_ch0, shadow_ch1, shadow_ch2, shadow_ch3;
wire  [7:0] shadow_dout;
pokey_adapter_new shadow_pokey (
	.CLK(clk_sys), .PHI1_EN(pclk1), .PHI2_EN(pclk0),
	.ADDR(address_in[3:0]), .DATA_IN(din), .WR_EN(~rw & pokey_cs), .RESET_N(~reset),
	.keyboard_scan_enable(1'b0), .keyboard_scan(), .keyboard_response(2'b11),
	.POT_IN(8'h00), .SIO_IN1(1'b1), .SIO_IN2(1'b1), .SIO_IN3(1'b1),
	.DATA_OUT(shadow_dout), .CHANNEL_0_OUT(shadow_ch0), .CHANNEL_1_OUT(shadow_ch1),
	.CHANNEL_2_OUT(shadow_ch2), .CHANNEL_3_OUT(shadow_ch3), .AUD(shadow_aud),
	.IRQ_N_OUT(), .SIO_OUT1(), .SIO_OUT2(), .SIO_OUT3(), .SIO_CLOCKIN_IN(1'b1),
	.SIO_CLOCKIN_OUT(), .SIO_CLOCKIN_OE(), .SIO_CLOCKOUT(), .POT_RESET());

"""
open(sys.argv[2], "w").write(s.replace(anchor, shadow + anchor, 1))
PY

# Reuse run_sim.sh's source list (run it once first: it makes the patched
# copies and the converted Watson POKEY this needs), with cart.sv swapped.
FPGA="$HERE/../src/fpga"
PATCHED="$WORK/patched"
[ -f "$WORK/pokey_watson.v" ] || { echo "run sim/run_sim.sh first"; exit 1; }
eval "$(sed -n '/^SRCS=(/,/^)/p' "$HERE/run_sim.sh" | sed "s#\"\$RTL/cart.sv\"#\"$SH/cart.sv\"#")"
SRCS+=("$SH/pokey_adapter_new.sv" $(ls "$RTL"/Pokey/*.sv | grep -v pokey_adapter.sv))
"${VERILATOR:-verilator}" --binary --timing -j 4 -O2 ${VTHREADS:+--threads $VTHREADS} -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
	-DNO_ARM_MAPPER -DNO_BUPCHIP -DNO_DDRAM -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ -DPOKEY_SHADOW \
	--top-module tb_load -Mdir "$WORK/obj_shadow${VTHREADS:+_mt}${OBJSUFFIX}" -o vtb "${SRCS[@]}" "$HERE/tb_load.sv" > "$WORK/obj_shadow.log" 2>&1 \
	|| { grep -m20 "%Error" "$WORK/obj_shadow.log"; exit 1; }
echo "built $WORK/obj_shadow/vtb"
