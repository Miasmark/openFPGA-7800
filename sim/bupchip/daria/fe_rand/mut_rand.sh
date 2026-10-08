#!/bin/bash
# mut_rand.sh: the mutation check of the random differential bench (lane E3).
# Each mutant is one textual change to one daria_fe RTL file, written into a
# copy (the tree is never touched); the bench is built against the copy
# (run_rand.sh MUT_DIR=...) and run; a mutant is caught iff a run fails.
#   ./mut_rand.sh [ID ...]          default: every mutant below
# CYCLES (default 150000) and SEEDS (default "31 32") per mutant; JOBS (1-2).
# The work goes to $WORK/mut/<id>/; the result table to $WORK/mut/result.txt.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_rand}"
BUP="$ROOT/src/fpga/core/bupchip"
mkdir -p "$WORK/mut"

# id ^ file ^ old text ^ new text ^ what
MUTANTS=$(cat <<'MEOF'
a1^daria_fe_arb^aud_take = aud_issue & !sel_up & !fix_eff^aud_take = aud_issue & !fix_eff^audio granted inside the 6507's RAM window
a2^daria_fe_arb^wb_gnt   = cr_wb  & y_free & !cr_p32;^wb_gnt   = cr_wb  & y_free;^pointer write-back granted beside a P32 read
a3^daria_fe_arb^aud_a_gnt = aud_a_req & !f6_act & !look_req;^aud_a_gnt = aud_a_req & !f6_act;^sample A read beside the jump lookahead
s1^daria_fe_seq^ev_short = commit & !(k_r[5] | k_r[6] | k_r[7]);^ev_short = commit & !(k_r[4] | k_r[5] | k_r[6] | k_r[7]);^ev_short also at C = E0+5
s2^daria_fe_seq^rel_ok   = (ph2_r | pclk0) & !pclk1;^rel_ok   = (ph2_r | pclk0);^rel_ok true at a pclk1 edge
c1^daria_fe_call^& 32'h0000_0C09)^& 32'h0000_0C0B)^DPC+ call entry word
c2^daria_fe_call^assign cp_cmp   = rd_q & !idx[2] & (idx[1] | idx[0]);^assign cp_cmp   = rd_q & !idx[2] & idx[1];^one seed not compared at the merge
c3^daria_fe_call^assign cp_rot   = s_post & cl_gnt & wr;^assign cp_rot   = s_post & wr;^ring rotated without the S grant
k1^daria_fe_copy^wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) |^wire       stop  = (rem == 8'd0) |^service not clamped at $1C00
k2^daria_fe_copy^((d == 2'd1) & r3) | ((d == 2'd0) & r4);^((d == 2'd1) & r3) | ((d == 2'd0) & r3);^fill writes one byte too many
k3^daria_fe_copy^(f6_i == (f6_dpc ? 13'h02FF : 13'h01FF))^(f6_i == (f6_dpc ? 13'h02FE : 13'h01FF))^DPC+ F6 fill one word short
u1^daria_fe_audio^wire  [7:0] byte_d = pause ? 8'hFF : lane_b;^wire  [7:0] byte_d = lane_b;^no $FF bytes in a pause
u2^daria_fe_audio^wire [14:0] w_off = crb_q[14:0] - 15'h0800;^wire [14:0] w_off = crb_q[14:0] - 15'h0400;^waveform offset base
u3^daria_fe_audio^else if (cp_shin & cp_cmp)  take <= {stb_q != ring[0], take[2:1]};^else if (cp_shin & cp_cmp)  take <= {1'b1, take[2:1]};^every returned counter taken
d1^daria_fe_dec^(jplus ? 15'h0800 : 15'h1000)^(jplus ? 15'h1000 : 15'h1000)^CDFJ+ ROM base
o1^daria_fe_core^wire [14:0] dsw_addr  = jplus ? (15'h0800 + W[30:16])^wire [14:0] dsw_addr  = jplus ? (15'h0800 + W[31:17])^CDFJ+ DSWRITE address bits
o2^daria_fe_core^4'd0:    be_fld = sf ? 4'b0011 : 4'b0010;^4'd0:    be_fld = 4'b0011;^FRACLOW ignores stable_fractional
o3^daria_fe_core^if (commit & opc.c.dpar & (pptr < 4'd8)) pptr <= pptr + 4'd1;^if (commit & opc.c.dpar & (pptr < 4'd4)) pptr <= pptr + 4'd1;^PARAMETER pointer saturates at 4
MEOF
)

IDS=("$@")
CYCLES="${CYCLES:-150000}"
SEEDS="${SEEDS:-31 32}"
res="$WORK/mut/result.txt"
[ ${#IDS[@]} -gt 0 ] || : > "$res"
caught=0; total=0
while IFS='^' read -r id file old new what; do
	[ -n "$id" ] || continue
	if [ ${#IDS[@]} -gt 0 ] && ! printf '%s\n' "${IDS[@]}" | grep -qx "$id"; then continue; fi
	total=$((total + 1))
	d="$WORK/mut/$id"
	rm -rf "$d"; mkdir -p "$d"
	if ! python3 -I - "$BUP/$file.sv" "$d/$file.sv" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("mutant text found %d times" % s.count(old))
open(dst, 'w').write(s.replace(old, new))
PY
	then echo "$id: NOT APPLIED ($what)" | tee -a "$res"; continue; fi
	rm -f "$WORK"/runs/mut_${id}_s*.log
	out=$(MUT_DIR="$d" TAG="mut_$id" JOBS="${JOBS:-2}" "$HERE/run_rand.sh" $SEEDS +cycles="$CYCLES" +epoch=25000 +stop=3 +maxfail=20 2>&1)
	first=$(grep -h -m1 '^FAIL [a-z_0-9]* at' "$WORK"/runs/mut_${id}_s*.log 2>/dev/null | head -1 | cut -c1-160)
	if echo "$out" | grep -q '^FAIL'; then
		caught=$((caught + 1)); echo "$id: caught ($what): $first" | tee -a "$res"
	else
		echo "$id: SURVIVED ($what)" | tee -a "$res"
	fi
	rm -rf "$WORK/obj_fe_mut_$id" "$WORK/obj_fe_mut_$id.log" "$WORK/.build_fe_mut_$id.lock"
done <<< "$MUTANTS"
echo "mut_rand: $caught of $total caught" | tee -a "$res"
