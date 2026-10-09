#!/bin/bash
# Build and run tb_daria_smp.sv, the unit bench of DARIA's sample requester
# (src/fpga/core/bupchip/daria_smp.sv; docs/daria_step7/plan.md 3.3 gate
# item 3). Verilator 5.040 (set VERILATOR to override), --binary --timing.
#   ./run_smp.sh one [+plusarg ...]   build (x-initial fast) and run once
#   ./run_smp.sh sweep fast|unique FIRST LAST [+plusarg ...]
#                                     one run per seed FIRST..LAST, random
#                                     phases (unique: +verilator+rand+reset+2);
#                                     exit 0 iff every run passes
#   ./run_smp.sh gate                 the unit gate, below; exit 0 iff it passes
# The gate:
#   1. --x-initial fast: phases 0, 8,730 and 17,460 ps (the shared edge on each
#      clk_sys class), 13,095 (none shared) and a random one, each run with
#      samples and again with +nosmp; each must pass, and the CPU's load
#      stream (+stream) must be the same file with and without samples;
#   2. --x-initial unique with +verilator+rand+reset+2, seeds 1-5, random
#      phases: each must pass;
#   3. seeds 22 and 24 (fast) and 22 (unique) at +loads=15000, random phases:
#      a request drawn for the 512 KB image and started on the 160 KB one,
#      past its end (the bench's own error the review found); each must pass
#      and answer at least one such request;
#   4. the mutants of daria_smp.sv, each built from a copy (the tree is not
#      touched) and run at phase 0: each must fail.
#        ack_early   the toggle flips with the halfword's arrival (or with the
#                    $FF decision) and the byte follows a clock later
#        lane        the other byte of the halfword
#        no_ff       no answer while not readable
#        no_mask     the cache's rd_req and rd_ack not masked while the
#                    sampler owns the read port
#        ack_reset   ack reset while not readable (the hold)
#        sync1       smp_req through one flop, not two
#        race_ff     a read in flight when readable falls answers $FF
#        drop_unread readable falling drops the wanted or in-flight read
# Environment: WORK (default sim/work/bupchip/daria/smp), JOBS (build
# parallelism, default 2), LOADS (+loads for the gate's runs, default 40000).
# Every log starts with the tree's HEAD and status, the Verilator path and
# version, and the md5 of the binary it ran. The image is a pattern: nothing
# here is game data. Outputs stay in $WORK (gitignored).
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/smp}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
LOADS="${LOADS:-40000}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
B="$ROOT/src/fpga/core/bupchip"
SRCS=("$ROOT/src/fpga/mister/rtl/cache_ram.v" "$ROOT/src/fpga/pocket_utils/psram.sv" "$ROOT/sim/bupchip/s4/psram_model.sv"
	"$B/bup_asset_wr.sv" "$B/bup_asset_cache.sv")

header() {
	echo "HEAD $(git -C "$ROOT" rev-parse HEAD)"
	echo "status [$(git -C "$ROOT" status --porcelain | tr '\n' ' ')]"
	echo "verilator $VERILATOR: $("$VERILATOR" --version)"
}

# build NAME XINIT SMP_SOURCE: $WORK/obj_NAME/vtb, rebuilt when an input changed
build() {
	local obj="$WORK/obj_$1" args sig
	args=(--binary --timing -j "${JOBS:-2}" -O2 --x-assign fast --x-initial "$2" -Wno-fatal -Wno-lint -Wno-style
		-Wno-TIMESCALEMOD -Wno-MULTIDRIVEN --top-module tb_daria_smp -Mdir "$obj" -o vtb
		"${SRCS[@]}" "$3" "$HERE/tb_daria_smp.sv")
	sig="$("$VERILATOR" --version) ${args[*]} $(cat "${SRCS[@]}" "$3" "$HERE/tb_daria_smp.sv" | md5sum)"
	if [ ! -x "$obj/vtb" ] || [ "$(cat "$obj/sig" 2>/dev/null)" != "$sig" ]; then
		rm -rf "$obj"
		mkdir -p "$obj"
		"$VERILATOR" "${args[@]}" > "$obj.log" 2>&1 || { grep -m20 "%Error" "$obj.log" >&2; echo "build failed: $obj.log" >&2; return 1; }
		find "$obj" -name '*.gch' -delete
		find "$obj" -name '*.o' -delete
		echo "$sig" > "$obj/sig"
	fi
}

# run NAME LOG [+plusargs]: one run of obj_NAME; prints its result line
run() {
	local bin="$WORK/obj_$1/vtb" log="$2"
	shift 2
	{ header; echo "binary $bin md5 $(md5sum < "$bin" | cut -c1-32)"; echo "args $*"; } > "$log"
	(cd "$WORK" && "$bin" "$@") >> "$log" 2>&1
	local rc=$?
	echo "exit $rc" >> "$log"
	local res
	res="$(grep -m1 '^result:' "$log")"
	[ -n "$res" ] || res="result: FAIL (no result line, exit $rc)"
	[ $rc = 0 ] || case "$res" in "result: PASS"*) res="result: FAIL (exit $rc) ${res#result: }" ;; esac
	echo "$res"
}

# mutate NAME OUT: a mutant copy of daria_smp.sv
mutate() {
	python3 -I - "$1" "$B/daria_smp.sv" "$2" <<'EOF'
import sys
name, src, out = sys.argv[1:4]
s = open(src).read()
def rep(old, new):
    global s
    if s.count(old) != 1:
        sys.exit("mutant %s: the pattern is not there once: %r" % (name, old[:60]))
    s = s.replace(old, new)
ff = """		if (start && !readable) begin
			data <= 8'hFF;
			done <= 1'b1;
		end
"""
rx = """		if (rx) begin
			fl <= 1'b0;
			data <= addr[0] ? rd_data[15:8] : rd_data[7:0];
			done <= 1'b1;
		end
"""
dn = """		if (done) begin
			done <= 1'b0;
			ack <= ~ack;
		end
"""
if name == "ack_early":
    rep("	logic        done   = 1'b0;", "	logic        done   = 1'b0;\n	logic        ffq    = 1'b0;")
    rep(ff + rx + dn, """		if (start && !readable) begin
			ack <= ~ack;
			ffq <= 1'b1;
			done <= 1'b1;
		end
		if (rx) begin
			fl <= 1'b0;
			ack <= ~ack;
			ffq <= 1'b0;
			done <= 1'b1;
		end
		if (done) begin
			done <= 1'b0;
			data <= ffq ? 8'hFF : addr[0] ? rd_data[15:8] : rd_data[7:0];
		end
""")
elif name == "lane":
    rep("data <= addr[0] ? rd_data[15:8] : rd_data[7:0];", "data <= addr[0] ? rd_data[7:0] : rd_data[15:8];")
elif name == "no_ff":
    rep(ff, "")
elif name == "no_mask":
    rep("assign rd_req   = pend || (c_rd_req && !own);", "assign rd_req   = pend || c_rd_req;")
    rep("assign c_rd_ack = rd_ack && !own;", "assign c_rd_ack = rd_ack;")
elif name == "ack_reset":
    rep(dn, dn + "		if (!readable) ack <= 1'b0;\n")
elif name == "sync1":
    rep("wire asked = req_s1 != ack;", "wire asked = req_s0 != ack;")
elif name == "race_ff":
    rep("data <= addr[0] ? rd_data[15:8] : rd_data[7:0];",
        "data <= !readable ? 8'hFF : addr[0] ? rd_data[15:8] : rd_data[7:0];")
elif name == "drop_unread":
    rep(dn, dn + "		if (!readable) begin\n			pend <= 1'b0;\n			fl <= 1'b0;\n		end\n")
else:
    sys.exit("no mutant " + name)
open(out, "w").write(s)
EOF
}

# cover LOG: the bench's coverage lines that the gate's evidence quotes
cover() {
	sed -n -E 's/.*past the image ([0-9]+)\).*load races ([0-9]+) .*/past the image \1, load races \2/p' "$1"
	sed -n -E 's/.*: START while the sampler.s read is wanted ([0-9]+), in flight ([0-9]+);.*/START while pend \1, while fl \2/p' "$1"
}

case "${1:-}" in
one)
	shift
	build fast fast "$B/daria_smp.sv" || exit 1
	run fast "$WORK/one.log" "$@"
	;;
sweep)
	kind="${2:-}" first="${3:-}" last="${4:-}"
	case "$kind" in fast|unique) ;; *) echo "usage: run_smp.sh sweep fast|unique FIRST LAST [+plusarg ...]" >&2; exit 2 ;; esac
	shift 4 || exit 2
	fail=0
	header
	build "$kind" "$kind" "$B/daria_smp.sv" || exit 1
	echo "binary $kind $(md5sum < "$WORK/obj_$kind/vtb" | cut -c1-32), plusargs $*"
	for s in $(seq "$first" "$last"); do
		extra=()
		[ "$kind" = unique ] && extra=(+verilator+rand+reset+2 +verilator+seed+$s)
		r="$(run "$kind" "$WORK/sweep_${kind}_$s.log" "${extra[@]}" +seed=$s +phase=-1 "$@")"
		echo "seed $s: $r; $(cover "$WORK/sweep_${kind}_$s.log" | paste -sd ';' -)"
		case "$r" in *FAIL*) fail=1 ;; esac
	done
	[ $fail = 0 ] && echo "SWEEP PASS" || echo "SWEEP FAIL"
	exit $fail
	;;
gate)
	fail=0
	header
	build fast fast "$B/daria_smp.sv" || exit 1
	build unique unique "$B/daria_smp.sv" || exit 1
	echo "binaries: fast $(md5sum < "$WORK/obj_fast/vtb" | cut -c1-32), unique $(md5sum < "$WORK/obj_unique/vtb" | cut -c1-32)"
	echo "== x-initial fast: phases, with and without samples (+loads=$LOADS)"
	for ph in 0 8730 17460 13095 -1; do
		r1="$(run fast "$WORK/ph$ph.log" +seed=7 +phase=$ph +loads=$LOADS +stream="$WORK/ph$ph.stream")"
		r2="$(run fast "$WORK/ph${ph}_nosmp.log" +seed=7 +phase=$ph +loads=$LOADS +nosmp +stream="$WORK/ph${ph}_nosmp.stream")"
		if cmp -s "$WORK/ph$ph.stream" "$WORK/ph${ph}_nosmp.stream" && [ -s "$WORK/ph$ph.stream" ]; then same=same; else same=DIFFERENT; fail=1; fi
		echo "phase $ph: $r1; $(cover "$WORK/ph$ph.log" | paste -sd ';' -)"
		echo "phase $ph +nosmp: $r2"
		echo "phase $ph: CPU load stream with and without samples: $same ($(wc -l < "$WORK/ph$ph.stream") loads)"
		case "$r1$r2" in *FAIL*) fail=1 ;; esac
	done
	echo "== x-initial unique, +verilator+rand+reset+2, random phases"
	for s in 1 2 3 4 5; do
		r="$(run unique "$WORK/unique$s.log" +verilator+rand+reset+2 +verilator+seed+$s +seed=$s +phase=-1 +loads=$((LOADS / 2)))"
		echo "seed $s: $r; $(cover "$WORK/unique$s.log" | paste -sd ';' -)"
		case "$r" in *FAIL*) fail=1 ;; esac
	done
	echo "== requests started past the image (+loads=15000, random phases)"
	for k in fast:22 fast:24 unique:22; do
		b=${k%%:*} s=${k#*:} extra=()
		[ "$b" = unique ] && extra=(+verilator+rand+reset+2 +verilator+seed+$s)
		r="$(run "$b" "$WORK/past_${b}_$s.log" "${extra[@]}" +seed=$s +phase=-1 +loads=15000)"
		c="$(cover "$WORK/past_${b}_$s.log" | paste -sd ';' -)"
		case "$c" in "past the image 0,"*|"") r="$r (FAIL: no request past the image)"; fail=1 ;; esac
		echo "$b seed $s: $r; $c"
		case "$r" in *FAIL*) fail=1 ;; esac
	done
	echo "== mutants (each must fail)"
	mkdir -p "$WORK/mut"
	for m in ack_early lane no_ff no_mask ack_reset sync1 race_ff drop_unread; do
		mutate $m "$WORK/mut/daria_smp_$m.sv" || { fail=1; continue; }
		build "mut_$m" fast "$WORK/mut/daria_smp_$m.sv" || { fail=1; continue; }
		echo "mutant $m: binary $(md5sum < "$WORK/obj_mut_$m/vtb" | cut -c1-32)"
		r="$(run "mut_$m" "$WORK/mut_$m.log" +seed=7 +phase=0 +loads=$LOADS +maxms=400)"
		case "$r" in *FAIL*) v=caught ;; *) v=MISSED; fail=1 ;; esac
		echo "mutant $m: $v: $r"
		grep -m3 -E '^[0-9]+: |^%(Error|Fatal)' "$WORK/mut_$m.log" | sed 's/^/    /'
	done
	[ $fail = 0 ] && echo "GATE PASS" || echo "GATE FAIL"
	exit $fail
	;;
*)
	echo "usage: run_smp.sh one [+plusarg ...] | gate" >&2
	exit 2
	;;
esac
