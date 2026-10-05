#!/bin/bash
# Thumb fuzz (docs/DARIA_CORE.md, "Verification", "Fuzz"): tfuzz.py programs
# of random halfwords from random states, each run by tfuzz_run.py in
# lockstep with the reference (../../verif/tb_lockstep.sv, DUT=bup with
# THUMB 1). Every halt the DUT takes must be the one predicted for that cell
# (thumb_expand.py's table for UNDEF and the C readers, the windows for
# DATA, RO and BLOCK, the aimed targets for FETCH); everything else must
# match the reference retire by retire.
#   ./run_fuzz.sh [SEED ...]            default: seeds 1-48
#   LATE_RF=1 ./run_fuzz.sh             the core built with BUP_SIM_LATE_RF
#   PLUS="+await=20 +throttle=10" ./run_fuzz.sh     plusargs for every run
#                                       (+seed=SEED is added)
# JOBS seeds run at a time (default 2), CELLS cells each (default 200).
# BUP_SRCS as for run_lockstep.sh (a mutant, say). Work files go to $WORK
# (default sim/work/bupchip/daria/thumb/fuzz), one directory per variant;
# the lockstep binary is built there. About 20 seconds per seed and job.
# Exits 0 when every seed passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/thumb/fuzz}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
IMAGE="$WORK/BLANK.a78"
[ -f "$IMAGE" ] || python3 "$ROOT/sim/bupchip/verif/make_synth_arsc.py" "$IMAGE" --none > /dev/null
LOCK="$(WORK="$WORK" THUMB=1 DUT=bup "$ROOT/sim/bupchip/verif/run_lockstep.sh" --build)"
VAR=plain
[ "${LATE_RF:-0}" = 0 ] || VAR=laterf
[ -z "$PLUS" ] || VAR="${VAR}$(echo "$PLUS" | tr -c 'a-z0-9\n' '_' | tr -d '\n')"
SEEDS=("$@")
[ $# -gt 0 ] || mapfile -t SEEDS < <(seq 1 48)
OUT="$WORK/$VAR"
mkdir -p "$OUT"
rm -f "$OUT"/tfuzz*.result.json
echo "tfuzz: ${#SEEDS[@]} seeds, ${CELLS:-200} cells each, variant $VAR, $LOCK"
T0=$(date +%s)
# shellcheck disable=SC2086
printf '%s\n' "${SEEDS[@]}" | xargs -P "${JOBS:-2}" -I{} \
	python3 "$HERE/tfuzz_run.py" "$LOCK" "$OUT" "$IMAGE" {} "${CELLS:-200}" $PLUS | tee "$OUT/summary.log" || true
T1=$(date +%s)
python3 - "$OUT" "${#SEEDS[@]}" $((T1 - T0)) <<'EOF'
import collections, glob, json, os, sys
out, nseeds, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
res = [json.load(open(p)) for p in glob.glob(os.path.join(out, "tfuzz*.result.json"))]
lines = open(os.path.join(out, "summary.log")).read().splitlines()
fails = [l for l in lines if l.startswith("FAIL")]
tot = collections.Counter()
halts, exc, fmts = collections.Counter(), collections.Counter(), collections.Counter()
for r in res:
    tot.update(cells=r["cells"], ran=r["ran"], retires=r["retires"], stores=r["stores"])
    halts.update(r["halts"])
    exc.update(r["ref_exc"])
    fmts.update(r["fmt_ran"])
print("tfuzz %s: %d of %d seeds pass, %d s" % (os.path.basename(out), len(res), nseeds, secs))
if res:
    print("  %d cells: %d ran in lockstep (%d retires, %d stores compared), %d halted as predicted: %s" % (
        tot["cells"], tot["ran"], tot["retires"], tot["stores"], sum(halts.values()),
        ", ".join("%s %d" % kv for kv in sorted(halts.items()))))
    print("  UNDEF halts where the reference took an exception at the same halfword: %d" % exc.get("UNDEF", 0))
    print("  formats run in lockstep: " + ", ".join("%s %d" % kv for kv in sorted(fmts.items())))
for l in fails:
    print("  " + l)
sys.exit(0 if len(res) == nseeds and not fails else 1)
EOF
