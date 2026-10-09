#!/bin/bash
# The step-7 fit driver (docs/daria_step7/plan.md 3.5 "Fit scripts", 4.3,
# 5.4): one full compile of a tree's src/fpga, as CI compiles a release
# (quartus_sh --flow compile ap_core, Quartus Prime Lite 21.1.1 in
# raetro/quartus:21.1), then step7_report.tcl (quartus_sta) and
# step7_checks.py: timing per clock and corner, the gates of 5.1-5.3 and the
# checks (a)-(p) of 5.4, with a verdict for the kind of build.
#
# Based on ../full/run_full.sh, but it never touches that script's baseline
# directories: its output is $WORK/$TAG only, and it refuses a WORK under
# sim/work/bupchip/fullprobe or a tree's sim/work/step7/ref.
#
# Run it under the machine's Quartus lock, one Quartus job at a time
# (docs/ENVIRONMENT.md 3.5), with QUARTUS_LOCK naming that lock file; it
# refuses to start when QUARTUS_LOCK is unset or the lock is free:
#   export QUARTUS_LOCK=<the lock file>
#   flock "$QUARTUS_LOCK" sim/bupchip/quartus_probe/step7/run_step7.sh
# A fit takes 12-25 min; start several seeds with setsid nohup (the 2-hour
# limit on a command), e.g. Q0:
#   setsid nohup flock "$QUARTUS_LOCK" bash -c 'for s in 1 2 3; do
#     TREE=<base worktree> NODARIA=1 SEED=$s KEEP_DB=$([ $s = 2 ] && echo 1 || echo 0) \
#     TAG=q0_s$s <this tree>/sim/bupchip/quartus_probe/step7/run_step7.sh || exit 1; done' \
#     > <log> 2>&1 < /dev/null &
#
# Environment:
#   TREE=DIR    the worktree whose src/fpga is compiled (default: this
#               script's own tree). Its HEAD and status head the log (P23)
#   WORK=DIR    where the run directory goes (default TREE/sim/work/step7/fit)
#   TAG=NAME    the run directory's name (default <tree>_<options>_s<seed>)
#   SEED=N      the fitter seed (default: the qsf's)
#   NODARIA=1   delete the three DARIA lines of ap_core.qsf in the copy
#   PIN_ID=1    no build_id_gen.tcl and a fixed apf/build_id.mif, so that two
#               compiles of one tree can give the same .rbf (Q1r, Q4)
#   OLDPAD=1    aeee6d2's core_constraints.sdc padding in the copy (Q1b)
#   DIV=18|19   clk_arm at VCO/18 (the tree's POCKET_DARIA setting) or VCO/19
#   KEEP_DB=1   keep db/ and incremental_db/ (about 1 GB; at most two kept
#               databases machine-wide); otherwise they and the .sof go
#   DRYRUN=1    print the commands and the edits to the copy, run no Quartus
#   FORCE=1     replace a run directory that holds a kept database
#   REPORT_ONLY=1  no compile: step7_report.tcl and the summaries again on
#               the kept database of $WORK/$TAG (give the same TREE, WORK and
#               TAG, or SEED and options, as the run that kept it; plan 3.5
#               test 4). Under the lock as well
#   IMAGE       the Docker image (default raetro/quartus:21.1)
#   QUARTUS_LOCK  the machine's Quartus lock file (required except DRYRUN)
# The run directory holds fpga/ (the edited copy, with the reports), run.log,
# quartus.log (the compile), report.log (quartus_sta), du.log, timing.txt,
# summary.txt (full_summary.py and step7_checks.py) and checks_summary.txt.
# The user's firmware files (bupchip.*) are never copied.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF_ROOT="$(cd "$HERE/../../../.." && pwd)"
TREE="$(cd "${TREE:-$SELF_ROOT}" && pwd)"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
DIV="${DIV:-18}"
LOCK="${QUARTUS_LOCK:-}"
die() { echo "run_step7.sh: $*" >&2; exit 2; }

[ -f "$TREE/src/fpga/ap_core.qsf" ] || die "TREE=$TREE has no src/fpga/ap_core.qsf"
case "$DIV" in 18|19) ;; *) die "DIV must be 18 or 19" ;; esac
[ "${NODARIA:-0}" = 0 ] || [ "$DIV" = 18 ] || die "DIV=19 with NODARIA=1 means nothing: counter 3 is selected by POCKET_DARIA"
[ -z "$SEED" ] || [[ "$SEED" =~ ^[0-9]+$ ]] || die "SEED must be a number"
WORK="$(realpath -m "${WORK:-$TREE/sim/work/step7/fit}")"
case "$WORK/" in
	*/sim/work/bupchip/fullprobe/*) die "WORK=$WORK is run_full.sh's; use another" ;;
	*/sim/work/step7/ref/*) die "WORK=$WORK holds the R1 references; use another" ;;
esac
mkdir -p "$WORK"

opts=""
[ "${NODARIA:-0}" = 0 ] && opts="${opts}_d$DIV" || opts="${opts}_nodaria"
[ "${PIN_ID:-0}" = 0 ] || opts="${opts}_pinid"
[ "${OLDPAD:-0}" = 0 ] || opts="${opts}_oldpad"
TAG="${TAG:-$(basename "$TREE")${opts}_s${SEED:-q}}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "TAG '$TAG' must be letters, digits, '.', '_' or '-'"

PREP=()
[ "${NODARIA:-0}" = 0 ] || PREP+=(--nodaria)
[ "${PIN_ID:-0}" = 0 ] || PREP+=(--pin-id)
[ -z "$SEED" ] || PREP+=(--seed "$SEED")
PREP+=(--div "$DIV")
if [ "${OLDPAD:-0}" != 0 ]; then
	PREP+=(--oldpad --oldpad-ref "$WORK/.aeee6d2_core_constraints.sdc")
	git -C "$TREE" show aeee6d2:src/fpga/core/core_constraints.sdc > "$WORK/.aeee6d2_core_constraints.sdc" \
		|| die "OLDPAD: cannot read aeee6d2's core_constraints.sdc from $TREE's repository"
fi

# The copy: src/fpga without build products and without the user's firmware.
make_copy() {	# DEST
	mkdir -p "$1"
	tar -C "$TREE/src" --exclude=fpga/output_files --exclude=fpga/db --exclude=fpga/incremental_db \
		--exclude='bupchip.*' -cf - fpga | tar -C "$1" -xf -
	if find "$1/fpga" -name 'bupchip.*' | grep -q .; then die "a bupchip.* file reached the copy"; fi
}

header() {
	echo "== run_step7.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC') tag $TAG"
	echo "driver $HERE: HEAD $(git -C "$SELF_ROOT" rev-parse HEAD); status $(git -C "$SELF_ROOT" status --porcelain | wc -l) lines"
	git -C "$SELF_ROOT" status --porcelain | sed 's/^/  driver: /'
	echo "TREE $TREE: HEAD $(git -C "$TREE" rev-parse HEAD); status $(git -C "$TREE" status --porcelain | wc -l) lines"
	git -C "$TREE" status --porcelain | sed 's/^/  tree: /'
	echo "options: SEED=${SEED:-qsf} NODARIA=${NODARIA:-0} PIN_ID=${PIN_ID:-0} OLDPAD=${OLDPAD:-0} DIV=$DIV KEEP_DB=${KEEP_DB:-0}"
	echo "md5: $(cd "$HERE" && md5sum run_step7.sh step7_prep.py step7_report.tcl step7_checks.py f3_crossings.txt ../full/full_summary.py | awk '{printf "%s %s; ", $2, substr($1,1,12)}')"
}

if [ "${DRYRUN:-0}" != 0 ]; then
	header
	tmp="$WORK/.dryrun_$TAG"
	rm -rf "$tmp"
	make_copy "$tmp"
	echo "-- the copy: $TREE/src/fpga -> $WORK/$TAG/fpga (no output_files, db, incremental_db, bupchip.*)"
	echo "-- edits to the copy: python3 $HERE/step7_prep.py <copy> ${PREP[*]}"
	python3 "$HERE/step7_prep.py" "$tmp/fpga" "${PREP[@]}"
	echo "-- then (not run):"
	echo "   docker run --rm -v $WORK/$TAG:/w -w /w/fpga $IMAGE bash -c 'quartus_sh --version | head -2 && quartus_sh --flow compile ap_core' > $WORK/$TAG/quartus.log"
	echo "   cp $HERE/step7_report.tcl $WORK/$TAG/fpga/"
	echo "   docker run --rm -v $WORK/$TAG:/w -w /w/fpga $IMAGE quartus_sta -t step7_report.tcl > $WORK/$TAG/report.log"
	echo "   python3 $HERE/../full/full_summary.py $WORK/$TAG > $WORK/$TAG/summary.txt"
	echo "   python3 $HERE/step7_checks.py $WORK/$TAG >> $WORK/$TAG/summary.txt"
	[ "${KEEP_DB:-0}" != 0 ] && echo "   (KEEP_DB=1: db/ and incremental_db/ kept)" \
		|| echo "   rm -rf $WORK/$TAG/fpga/db $WORK/$TAG/fpga/incremental_db $WORK/$TAG/fpga/output_files/ap_core.sof"
	rm -rf "$tmp"
	exit 0
fi

# ---- the real run ---------------------------------------------------------------------------
[ -n "$LOCK" ] || die "QUARTUS_LOCK is not set: set it to the machine's Quartus lock file (docs/ENVIRONMENT.md 3.5)"
[ -f "$LOCK" ] || die "QUARTUS_LOCK=$LOCK does not exist"
if flock -n "$LOCK" true 2>/dev/null; then
	die "the Quartus lock is free: run me as  flock \"\$QUARTUS_LOCK\" $0  (one Quartus job at a time)"
fi
dir="$WORK/$TAG"
case "$dir" in "$WORK"/?*) ;; *) die "bad run directory $dir" ;; esac

report() {	# step7_report.tcl on $dir/fpga's database, then the summaries
	cp "$HERE/step7_report.tcl" "$dir/fpga/"
	echo "== report: quartus_sta -t step7_report.tcl ($(date -u '+%H:%M:%S UTC'))"
	set +e
	docker run --rm -v "$dir:/w" -w /w/fpga "$IMAGE" quartus_sta -t step7_report.tcl > "$dir/report.log" 2>&1
	rrc=$?
	set -e
	grep -E "^Error|^Info: Quartus Prime Timing Analyzer was|TCL_ERROR|while executing" "$dir/report.log" | head -5 | sed 's/^/   /'
	[ ! -f "$dir/fpga/timing.txt" ] || cp "$dir/fpga/timing.txt" "$dir/timing.txt"
	python3 "$HERE/../full/full_summary.py" "$dir" > "$dir/summary.txt" 2>&1 || echo "full_summary.py failed" >> "$dir/summary.txt"
	set +e
	python3 "$HERE/step7_checks.py" "$dir" >> "$dir/summary.txt" 2>&1
	crc=$?
	set -e
	cat "$dir/summary.txt"
	[ "$rrc" = 0 ] || echo "run_step7.sh: step7_report.tcl failed (exit $rrc), see $dir/report.log" >&2
}

if [ "${REPORT_ONLY:-0}" != 0 ]; then
	[ -d "$dir/fpga/db" ] || die "REPORT_ONLY: $dir has no kept database"
	exec > >(tee -a "$dir/run.log") 2>&1
	echo "== REPORT_ONLY $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $dir"
	header
	report
	exit 0
fi

avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
[ "$avail" -ge 2048 ] || die "only ${avail} MB free on /; a fit needs at least 2 GB"
if [ -d "$dir/fpga/db" ] && [ "${FORCE:-0}" = 0 ]; then
	die "$dir holds a kept database; FORCE=1 replaces it"
fi
kept=$(find "$WORK" -mindepth 3 -maxdepth 3 -type d -name db -path '*/fpga/db' 2>/dev/null | grep -v "^$dir/" | wc -l)
[ "$kept" -lt 2 ] || echo "run_step7.sh: warning: $kept kept databases under $WORK already (at most two machine-wide)" >&2
rm -rf "$dir"
mkdir -p "$dir"
exec > >(tee "$dir/run.log") 2>&1
header
make_copy "$dir"
python3 "$HERE/step7_prep.py" "$dir/fpga" "${PREP[@]}"
echo "image $IMAGE $(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)"
echo "free on /: ${avail} MB"

# Disk use while Quartus runs (the database's peak, plan 4.3).
( peak=0; while [ ! -f "$dir/.done" ]; do
	s=$(du -sm "$dir" 2>/dev/null | cut -f1); [ -n "$s" ] && [ "$s" -gt "$peak" ] && peak=$s
	echo "$(date -u +%H:%M:%S) ${s:-?} MB in $TAG, peak $peak MB, $(df -BM --output=avail / | tail -1 | tr -dc 0-9) MB free" >> "$dir/du.log"
	sleep 30
done ) &
t0=$(date +%s)
echo "== compile: started $(date -u '+%H:%M:%S UTC')"
set +e
docker run --rm -v "$dir:/w" -w /w/fpga "$IMAGE" \
	bash -c "quartus_sh --version | head -2 && quartus_sh --flow compile ap_core" > "$dir/quartus.log" 2>&1
rc=$?
set -e
echo "== compile: exit $rc after $(( $(date +%s) - t0 )) s"
grep -m2 "Quartus Prime" "$dir/quartus.log" | sed 's/^/   /'
grep -E "Peak virtual memory|Elapsed time" "$dir/quartus.log" | sed 's/^ *//; s/^/   /' | head -12
if [ "$rc" != 0 ] || [ ! -f "$dir/fpga/output_files/ap_core.fit.summary" ]; then
	touch "$dir/.done"
	wait
	echo "run_step7.sh: the compile failed, see $dir/quartus.log" >&2
	[ "${KEEP_DB:-0}" != 0 ] || rm -rf "$dir/fpga/db" "$dir/fpga/incremental_db"
	exit 1
fi
report
touch "$dir/.done"
wait
echo "== disk peak $(tail -1 "$dir/du.log" | sed 's/.*peak \([0-9]*\) MB.*/\1/') MB"
[ "${KEEP_DB:-0}" != 0 ] || rm -rf "$dir/fpga/db" "$dir/fpga/incremental_db" "$dir/fpga/output_files/ap_core.sof"
echo "== $TAG done: checks $([ "$crc" = 0 ] && echo PASS || echo FAIL) ($dir/checks_summary.txt); report $([ "$rrc" = 0 ] && echo ran || echo FAILED); database $([ "${KEEP_DB:-0}" != 0 ] && echo kept || echo deleted)"
exit 0
