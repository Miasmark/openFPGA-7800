#!/bin/bash
# Mutation check of lane D's benches (docs/daria_fe/lanes/D_arb_guard.md):
# each mutant is one small edit of daria_fe_arb.sv (checked by tb_fe_arb)
# or daria_fe_guard.sv (checked by tb_fe_guard), made on a copy in
# $WORK/mut_d/; the bench is built with the copy in place of the original
# and run. A mutant is caught iff its bench fails. Nothing in the repository
# is changed.
#   ./tb_fe_arb_mut.sh [ID ...]        (default: every mutant)
# CYCLES (tb_fe_arb, default 300000), EDGES (tb_fe_guard, default 200000),
# POISON=1, VERILATOR as run_unit.sh. Prints one line per mutant and
# "caught N of M"; exits 1 if a mutant survives.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_unit}/mut_d"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
B="$ROOT/src/fpga/core/bupchip"
mkdir -p "$WORK"

# ID#file#find (literal, must occur exactly once)#replace#what it breaks
read -r -d '' MUTANTS <<'EOF'
a1#arb#wire fix_eff = cr_fix & r_quiet;#wire fix_eff = cr_fix & !f6_act;#core fixed R not suppressed under the guard
a2#arb#assign aud_take = aud_issue & !sel_up & !fix_eff#assign aud_take = aud_issue & !fix_eff#audio granted inside upstream's select
a3#arb#assign aud_take = aud_issue & !sel_up & !fix_eff & !f6_act#assign aud_take = aud_issue & !sel_up & !f6_act#audio and core fixed both granted
a4#arb#& !f6_act & (!guard_on | phb_next);#& !f6_act;#audio off phase B under the guard
a5#arb#& !f6_act & (!guard_on | phb_next);#& !f6_act & phb_next;#audio waits for phase B without the guard
a6#arb#assign aud_take = aud_issue & !sel_up & !fix_eff & !f6_act#assign aud_take = aud_issue & !sel_up & !fix_eff#audio granted during F6
a7#arb#wire y_free  = r_quiet & !fix_eff & !aud_take;#wire y_free  = r_quiet & !fix_eff;#yielding users take an audio edge
a8#arb#assign wb_gnt   = cr_wb  & y_free & !cr_p32;#assign wb_gnt   = cr_wb  & y_free;#pointer write beside the P32 read
a9#arb#wire cpy_gnt = cp_req & y_free & !cr_p32 & !cr_wb;#wire cpy_gnt = cp_req & y_free & !cr_p32;#copy engine beside the pointer write
a10#arb#wire cpy_gnt = cp_req & y_free & !cr_p32 & !cr_wb;#wire cpy_gnt = cp_req & y_free & !cr_wb;#copy engine beside the P32 read
a11#arb#wire f6_gnt  = cp_req & f6_act;#wire f6_gnt  = cp_req & f6_act & !cr_fix;#F6 below the core's fixed use
a12#arb#use_q <= (fix_eff & cr_fix_use) | p32_gnt | aud_take;#use_q <= (fix_eff & cr_fix_use) | aud_take;#crb_use misses the P32 read
a13#arb#use_q <= (fix_eff & cr_fix_use) | p32_gnt | aud_take;#use_q <= fix_eff | p32_gnt | aud_take;#crb_use on core writes
a14#arb#assign crb_use = use_q;#assign crb_use = (fix_eff & cr_fix_use) | p32_gnt | aud_take;#crb_use not registered (marks the grant clock)
a15#arb#assign crb_we   = (cp_gnt & cp_we) | (fix_eff & cr_fix_we) | wb_gnt;#assign crb_we   = (cp_gnt & cp_we) | (fix_eff & cr_fix_we);#pointer write never written
a16#arb#| ({4{wb_gnt}}  & 4'hF);#| ({4{wb_gnt}}  & 4'h7);#pointer write's top byte lost
a17#arb#| ({13{aud_take}} & aud_addr[14:2])#| ({13{aud_take}} & aud_addr[12:0])#audio word address from the byte address
a18#arb#assign crb_wd   = ({32{cp_gnt}}  & cp_wd)#assign crb_wd   = ({32{cpy_gnt}}  & cp_wd)#F6 writes zeros
a19#arb#assign cl_gnt = cl_req & !cz_req & !cs_req;#assign cl_gnt = cl_req & !cz_req;#call port beside the core on S
a20#arb#assign stb_we   = cz_req | (cs_gnt & cs_we)#assign stb_we   = (cs_gnt & cs_we)#F6 clear never written
a21#arb#assign stb_wd   = ({32{cs_gnt}} & cs_wd)#assign stb_wd   = ({32{cs_req}} & cs_wd)#F6 clear writes the core's data
a22#arb#assign look_gnt  = look_req & !f6_act;#assign look_gnt  = look_req;#lookahead during F6
a23#arb#assign aud_a_gnt = aud_a_req & !f6_act & !look_req;#assign aud_a_gnt = aud_a_req & !f6_act;#audio sample beside the lookahead
a24#arb#assign ca_gnt    = ca_req & (f6_act | (!look_req & !aud_a_req));#assign ca_gnt    = ca_req & !look_req & !aud_a_req;#F6 source below the lookahead
a25#arb#| ({13{ca_gnt}} & ca_a);#;#copy/F6 source address lost
a26#arb#assign own_r[B_OR_COPY] = cpy_gnt;#assign own_r[B_OR_COPY] = cp_gnt;#owner tap: F6 also as copy
a27#arb#assign own_a[B_OA_COPY] = ca_gnt & !f6_act;#assign own_a[B_OA_COPY] = ca_gnt;#owner tap: F6 source also as copy
a28#arb#wire  sh_c  = ev_short     | (sh_q  & !k[0]);#wire  sh_c  = ev_short;#a_collide forgets the cycle's early commit
a29#arb#wire  sh_c  = ev_short     | (sh_q  & !k[0]);#wire  sh_c  = ev_short     | sh_q;#a_collide's cycle never ends
a30#arb#assign a_guard_core   = (commit & sup_c) | (ev_guard_sup & cm_q & !k[0]);#assign a_guard_core   = (commit & sup_c);#a_guard_core misses a suppression after the commit
a31#arb#assign a_guard_wr     = guard_on & ((cr_fix & cr_fix_we) | cr_wb | (cp_req & cp_we & !f6_act));#assign a_guard_wr     = guard_on & ((cr_fix & cr_fix_we) | (cp_req & cp_we & !f6_act));#a_guard_wr misses the pointer write
a32#arb#& !(p32_q | rdP) & !guard_on;#& !(p32_q | rdP);#a_p32_late under the guard
a33#arb#assign a_wb_late      = wb_v & k[1];#assign a_wb_late      = wb_v & k[2];#a_wb_late one clock late
a34#arb#assign ev_grant_steal = aud_issue & !sel_up & fix_eff;#assign ev_grant_steal = aud_issue & fix_eff;#steal counted inside upstream's select
a35#arb#| ({4{cl_gnt}} & 4'hF);#| ({4{cl_gnt}} & 4'hE);#call port's byte 0 lost
a36#arb#wire r_quiet = !guard_on & !f6_act;#wire r_quiet = !f6_act;#P32, pointer write and copy under the guard
g1#guard#assign pd_same = pd_rx == pd_rx1;#assign pd_same = pd_rx != pd_rx1;#detector inverted
g2#guard#assign phb_next = lk & (ph == 2'd0);#assign phb_next = lk & pd_same;#phb_next from the receiver
g3#guard#if (mism | (good == 4'd12)) lk   <= !mism;#if (mism | (good == 4'd11)) lk   <= !mism;#locks after 12 matches, not 13
g4#guard#if (mism | (good == 4'd12)) lk   <= !mism;#if (good == 4'd12) lk   <= 1'b1;#never unlocks
g5#guard#ph <= mism ? 2'd1 :#ph <= mism ? 2'd0 :#re-anchored one clock off
g6#guard#((ph == 2'd2) ? 2'd0 : ph + 2'd1)#ph + 2'd1#flywheel period 4
g7#guard#assign guard_on = lk & (call_win | !cpu_ready);#assign guard_on = lk & call_win;#guard ignores !cpu_ready
g8#guard#assign guard_on = lk & (call_win | !cpu_ready);#assign guard_on = call_win | !cpu_ready;#guard on while unlocked
g9#guard#assign ev_unlock = lk & mism;#assign ev_unlock = mism;#ev_unlock while unlocked
g10#guard#pd_rx1 <= pd_rx;#pd_rx1 <= pd_tog;#receiver pair skips a stage
g11#guard#good <= mism ? 4'd0 : good + 4'd1;#good <= good + 4'd1;#good not cleared on a mismatch
g12#guard#always_ff @(posedge clk_arm) pd_tog#always_ff @(posedge clk_sys) pd_tog#toggle on the wrong clock
EOF

want=("$@")
DEFS=()
[ "${POISON:-0}" = 0 ] || DEFS+=(-DDARIA_RAM_POISON)
caught=0
total=0
while IFS='#' read -r id file find repl what; do
	[ -n "$id" ] || continue
	if [ ${#want[@]} -gt 0 ]; then
		hit=0; for w in "${want[@]}"; do [ "$w" = "$id" ] && hit=1; done
		[ $hit = 1 ] || continue
	fi
	total=$((total + 1))
	d="$WORK/$id"
	rm -rf "$d"; mkdir -p "$d"
	src="$B/daria_fe_$file.sv"
	if ! python3 - "$src" "$d/daria_fe_$file.sv" "$find" "$repl" <<'PY'
import sys
s = open(sys.argv[1]).read()
n = s.count(sys.argv[3])
if n != 1:
    sys.exit("find string occurs %d times" % n)
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
	then echo "ERROR $id: mutation not applied"; continue; fi
	if [ "$file" = arb ]; then
		srcs=("$B/daria_mem.sv" "$B/daria_fe_pkg.sv" "$d/daria_fe_arb.sv" "$HERE/tb_fe_arb.sv")
		top=tb_fe_arb; plus=("+cycles=${CYCLES:-300000}")
	else
		srcs=("$d/daria_fe_guard.sv" "$HERE/tb_fe_guard.sv")
		top=tb_fe_guard; plus=("+edges=${EDGES:-200000}")
	fi
	if ! nice -n 10 "$VERILATOR" --binary --timing -j 2 -O1 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
			-Wno-MULTIDRIVEN "-I$HERE" --top-module "$top" "${DEFS[@]}" -Mdir "$d/obj" -o vtb "${srcs[@]}" \
			> "$d/build.log" 2>&1; then
		echo "ERROR    $id: the mutant does not build (see $d/build.log)"; rm -rf "$d/obj"; continue
	fi
	(cd "$WORK" && timeout 600 nice -n 10 "$d/obj/vtb" "${plus[@]}") > "$d/run.log" 2>&1
	st=$?
	rm -rf "$d/obj"
	if [ $st != 0 ]; then
		first=$(grep -m1 -E "ERROR|COVERAGE|FAIL" "$d/run.log" | cut -c1-110)
		echo "caught   $id: $what  [$first]"; caught=$((caught + 1))
	else
		echo "SURVIVED $id: $what"
	fi
done <<< "$MUTANTS"
echo "caught $caught of $total"
[ $caught = $total ]
