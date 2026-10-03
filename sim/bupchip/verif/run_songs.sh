#!/bin/bash
# Lockstep through every song of a game (docs/BUPCHIP_CORE.md, "Verification
# plan": all 32 songs x 4 s, overnight, local data). Each song runs on its own:
# the reference against DUT (default bup, the new core) from power-up, the
# command sent at reference clock 1,000,000, and the run stopped at SECS x 72
# million reference clocks (clk_arm is 71.582 MHz there). Odd songs also get
# random asset waits and throttle clocks (+await=20 +throttle=10, seeded with
# the song number).
#   ./run_songs.sh GAME.a78 [SONG ...]       default: songs 0-31
# SECS (default 4), JOBS at once (default nproc), DUT and LATE_RF as for
# run_lockstep.sh. Logs go to $WORK/songs/song<N>.log (WORK defaults to
# sim/work/bupchip/verif). About an hour for 32 songs on 4 cores. Exits 0
# when every song ends in LOCKSTEP PASS.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
mkdir -p "$WORK/songs"
WORK="$(cd "$WORK" && pwd)"
export WORK
export DUT="${DUT:-bup}"
GAME="$(realpath "${1:?usage: run_songs.sh GAME.a78 [SONG ...]}")"
shift
SONGS=("$@")
[ $# -gt 0 ] || SONGS=($(seq 0 31))
BIN="$("$HERE/run_lockstep.sh" --build)"
MAXCYC=$(( ${SECS:-4} * 72000000 ))

one() {	# song number -> $WORK/songs/song<N>.log, and one summary line
	local s="$1" extra=()
	[ $((s % 2)) = 0 ] || extra=(+await=20 +throttle=10 +seed="$s")
	"$BIN" +rom="$GAME" +song="$s" +songcyc=1000000 +maxcyc="$MAXCYC" +maxret=10000000000 "${extra[@]}" \
		2>&1 | grep -v "^- " > "$WORK/songs/song$s.log" || true
	echo "song $s${extra:+ (waits, throttle)}: $(grep -E '^(compared|mismatches|LOCKSTEP)' "$WORK/songs/song$s.log" | tr '\n' ' ')"
}
export -f one
export BIN GAME MAXCYC
printf '%s\n' "${SONGS[@]}" | xargs -P "${JOBS:-$(nproc)}" -I{} bash -c 'one {}' | tee "$WORK/songs/results.txt"

pass=0
for s in "${SONGS[@]}"; do grep -q "^LOCKSTEP PASS" "$WORK/songs/song$s.log" && pass=$((pass + 1)); done
python3 - "$WORK/songs" "${SONGS[@]}" <<'EOF'
import re, sys
d, songs = sys.argv[1], sys.argv[2:]
tot = [0, 0, 0, 0]
for s in songs:
    m = re.search(r"^compared: (\d+) retires, (\d+) RAM stores, (\d+) peripheral writes; (\d+) peripheral reads",
                  open("%s/song%s.log" % (d, s)).read(), re.M)
    if m:
        tot = [a + int(b) for a, b in zip(tot, m.groups())]
print("compared in all: {:,} retires, {:,} RAM stores, {:,} peripheral writes, {:,} replayed reads".format(*tot))
EOF
echo "songs: $pass of ${#SONGS[@]} pass"
[ "$pass" -eq "${#SONGS[@]}" ]
