#!/bin/bash
# Lane C's standard runs of tb_fe_call and tb_fe_copy (docs/daria_fe/lanes/
# C_call_copy.md): each configuration through run_unit.sh, its log kept as
# $OUT/<name>.log, and the coverage it is there for checked: a run passes
# iff the bench passes and every counter listed for it is non-zero.
#   ./tb_fe_call_suite.sh [NAME ...]      (default: every run)
# POISON=1 builds with daria_mem's poisoned RAM model (run_unit.sh), JOBS as
# there. WORK defaults to sim/work/bupchip/daria/fe_unit/runs_C/work (its
# own, so another lane's run_unit.sh does not rebuild these benches under
# it); OUT to runs_C/suite or runs_C/suite_poison. Prints one line per run
# and "suite: N of M passed"; exits 1 if any failed.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
RC="$ROOT/sim/work/bupchip/daria/fe_unit/runs_C"
export WORK="${WORK:-$RC/work}"
if [ "${POISON:-0}" = 0 ]; then OUT="${OUT:-$RC/suite}"; else OUT="${OUT:-$RC/suite_poison}"; fi
mkdir -p "$WORK" "$OUT"

# name~bench~plusargs~counters that must be non-zero
read -r -d '' RUNS <<'EOF'
c_mix~call~+seed=1 +clocks=5000000~calls_dpc calls_cdf calls_cdf_hook rmw_dpc rmw_cdf rmw_cdf_hook f8_in_first_clock applies releases rel_wait_clocks flip_wait_clocks post_denied return_reads ret_unasked reset_in_0 reset_in_1 reset_in_2 reset_in_3 reset_in_4 reset_in_5 reset_in_6 reset_in_7 reset_in_8 tick_L-2 tick_L-1 tick_L+0 tick_L+1 tick_L+2 tick_M-2 tick_M-1 tick_M+0 tick_M+6 tick_M+7 tick_M+8 tick_deferred tick_late_add rmw_call_value accept_balance_checks pend_up_compares_set deposits resyncs
c_modea~call~+seed=2 +clocks=4000000 +epoch=50000 +stall_up=1 +gap=0 +ready=1~late_pend2 rel_go_callfn rel_go_late_pend2 rmw_cdf rmw_dpc applies accept_balance_checks
c_modea_all~call~+seed=8 +clocks=4000000 +epoch=50000 +stall_up=1 +gap=0 +pg_mode=all +k_rst=300~late_pend2 rel_go_callfn reset_in_3 reset_in_4 reset_in_6 accept_balance_checks
c_dpc~call~+seed=3 +clocks=3000000 +epoch=300000 +only=1 +k_cs=400 +pg_mode=all~calls_dpc rmw_dpc post_denied releases flip_wait_clocks accept_balance_checks
c_cdf_hw~call~+seed=4 +clocks=3000000 +epoch=100000 +only=2 +hook=0 +ready=0 +k_rst=300 +fault_k=600~calls_cdf rmw_cdf applies fault_resets ret_unasked reset_in_3 reset_in_4 reset_in_5 reset_in_6 reset_in_8 flip_wait_clocks tick_M+6 tick_M+7 rmw_call_value
c_rmwx~call~+seed=9 +clocks=3000000 +epoch=300000 +only=1 +k_short=900 +pg_mode=all +gap=0~pend2_at_x rmw_dpc rel_go_callfn accept_balance_checks
c_hook~call~+seed=5 +clocks=2000000 +epoch=100000 +only=2 +hook=1 +k_rst=300~calls_cdf_hook rmw_cdf_hook reset_in_7 releases
c_5x~call~+seed=6 +clocks=3000000 +arm_div=5 +arm_ofs=3100 +ready=1~calls_dpc calls_cdf applies releases tick_M+7
c_ofs~call~+seed=7 +clocks=3000000 +arm_ofs=7 +pg_mode=all~calls_dpc calls_cdf applies releases
k_mix~copy~+seed=1 +loads=30~f6_dpc f6_cdf8k f6_cdfj_plus f6_by_window f6_by_reset reset_rise_ignored_busy reset_rise_ignored_noarm loads_other svc_fill svc_copy svc_count0 svc_src_bound svc_dst_bound svc_clamped svc_queued_rmw svc_deferred engine_denied_guard copy_src_denied dma_busy_falls dma_busy_tail_clocks fill_partial_words abort_on_take images_equal svc_checked
k_dpc~copy~+seed=2 +loads=20 +only=1 +k_svc=300 +pg_mode=all~f6_dpc svc_fill svc_copy svc_count0 svc_src_bound svc_dst_bound svc_queued_rmw svc_deferred dma_busy_tail_clocks abort_on_take loads_dpc_29k images_equal
k_cdf~copy~+seed=3 +loads=30 +only=2~f6_cdf8k f6_cdfj_plus f6_by_window f6_by_reset reset_rise_ignored_busy images_equal
k_abort~copy~+seed=4 +loads=24 +run_clk=20000 +k_abort=600 +k_takeab=40 +k_glitch=500~f6_aborted_by_load abort_on_take abort_service_load glitches a_f6_live_glitch images_equal
k_guard~copy~+seed=5 +loads=12 +only=1 +k_guard=700 +k_aud=500~svc_fill svc_copy engine_denied_guard svc_checked
EOF

want=("$@")
pass=0
fail=0
while IFS='~' read -r name bench args need; do
	[ -n "$name" ] || continue
	if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
	rm -f "$WORK/$bench.log"
	# shellcheck disable=SC2086
	"$HERE/run_unit.sh" "$bench" $args > "$OUT/$name.run" 2>&1
	st=$?
	cp "$WORK/$bench.log" "$OUT/$name.log" 2>/dev/null
	miss=""
	for k in $need; do
		v=$(awk -v k="$k" '$1 == k { print $2 }' "$OUT/$name.log" 2>/dev/null | head -1)
		[ -n "$v" ] && [ "$v" != 0 ] || miss="$miss $k"
	done
	if [ $st = 0 ] && [ -z "$miss" ]; then
		pass=$((pass + 1)); echo "PASS $name ($bench $args)"
	else
		fail=$((fail + 1))
		why=""; [ $st = 0 ] || why="bench failed"; [ -z "$miss" ] || why="$why; not covered:$miss"
		echo "FAIL $name ($bench $args): $why"
		grep -m3 '^ERROR' "$OUT/$name.log" 2>/dev/null | cut -c1-200 | sed 's/^/  /'
	fi
done <<< "$RUNS"
echo "suite: $pass of $((pass + fail)) passed${POISON:+ (POISON=$POISON)}"
[ $fail = 0 ]
