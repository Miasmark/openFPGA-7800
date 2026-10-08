#!/bin/bash
# Mutation check of the directed tests against daria_fe (stage 1): each mutant
# is a one-line change to a COPY of one daria_fe RTL file (in sim/work; the
# sources are not touched), built through vwrap.sh's FE_DIR_MUT, and run on
# the tests meant to see it. A mutant is caught when a test that passes on the
# real RTL fails on it.
#   ./mut.sh [ID ...]        (default: all)
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUP="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
W="$(cd "$HERE/../../../work/bupchip/daria" && pwd)/fe_dir"
# id | file | sed expression | tests
MUTS=(
"m1|daria_fe_dec.sv|s/wire        c_hot  = a12 \& !c_sub \&/wire        c_hot  = a12 \&/|hotspot_cdf1 hotspot_cdfj hotspot_cdfjp cdf_jump_cdfj"
"m2|daria_fe_dec.sv|s/(a >= 12'hFF6) \& (a <= 12'hFFB)/(a >= 12'hFF7) \& (a <= 12'hFFB)/|hotspot_dpc"
"m3|daria_fe_copy.sv|s/(dst == 13'h1C00)/(dst == 13'h1C04)/|dpc_svc"
"m4|daria_fe_copy.sv|s/(!fill \& (src\[16:15\] != 2'b00))/1'b0/|dpc_svc"
"m5|daria_fe_core.sv|s/(rom_a\[14:1\] != 14'h3FFF)/1'b1/|cdf_jump_cdf1 cdf_jump_cdfj"
"m6|daria_fe_audio.sv|s/dig_low ? dig_b\[3:0\] : dig_b\[7:4\]/dig_low ? dig_b[7:4] : dig_b[3:0]/|digital_cdfj digital_cdfjp"
"m7|daria_fe_core.sv|s/be_fld = sf ? 4'b0011 : 4'b0010;/be_fld = 4'b0010;/|dpc_regs dpc_regs_sf"
"m8|daria_fe_core.sv|s/(pptr < 4'd8)) pptr <= pptr + 4'd1;/(pptr < 4'd4)) pptr <= pptr + 4'd1;/|dpc_regs"
"m9|daria_fe_core.sv|s/(15'h0800 + W\[30:16\])/(15'h0800 + {1'b0, W[29:16]})/|dsw_cdfjp dsw_cdfj"
"m10|daria_fe_audio.sv|s/else if (!pause) al <= a_d\[1:0\];/else al <= a_d[1:0];/|pause_lane_dpc"
"m11|daria_fe_audio.sv|s/else if (!pause) al <= a_d\[1:0\];/else if (aud_take) al <= a_d[1:0];/|pause_lane_dpc"
)
sel=" $* "
: > "$W/mut_results.txt"
for m in "${MUTS[@]}"; do
	IFS='|' read -r id file expr tests <<< "$m"
	[ $# -eq 0 ] || [[ "$sel" == *" $id "* ]] || continue
	d="$W/mut/$id"
	rm -rf "$d"; mkdir -p "$d"
	sed "$expr" "$BUP/$file" > "$d/$file"
	if cmp -s "$BUP/$file" "$d/$file"; then echo "$id: the expression did not apply" | tee -a "$W/mut_results.txt"; continue; fi
	# shellcheck disable=SC2086
	FLAVOR="mut_$id" FE_DIR_MUT="$BUP/$file=$d/$file" "$HERE/run_dir.sh" $tests > "$d/run.log" 2>&1 || true
	res="$W/mut_$id/results.txt"
	if grep -q FAIL "$res" 2>/dev/null; then v=CAUGHT; else v=MISSED; fi
	echo "$id $v ($file: $expr) by: $(grep FAIL "$res" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')" | tee -a "$W/mut_results.txt"
	grep FAIL "$res" 2>/dev/null | sed 's/^/    /' | cut -c1-300 >> "$W/mut_results.txt" || true
	rm -rf "$W/mut_$id"/obj_fe* "$W/mut_$id/patched" "$W/mut_$id/rtl"
done
cat "$W/mut_results.txt"
