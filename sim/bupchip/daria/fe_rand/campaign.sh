#!/bin/bash
# campaign.sh: the 10^8-cycle campaign of the random differential bench
# (design 12.1, 12.2 step 4; lane E3), split into runs of $CYC cycles (each well
# under 30 minutes), two at a time (the machine rule), and the self-check.
#   ./campaign.sh self [G..] the upstream-vs-upstream self-check (strict: no class)
#   ./campaign.sh fe [G..] daria_fe against upstream: the groups below (or those named)
#   ./campaign.sh sum      the totals over every log in runs/ (camp_*)
# Each group is a tag, build options and plusargs; seeds are distinct per group.
# SPDX-License-Identifier: MIT
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_rand}"
CYC="${CYC:-2500000}"

group() {   # tag env seeds... -- plusargs...
	local tag="$1" envs="$2"; shift 2
	local seeds=() plus=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do seeds+=("$1"); shift; done
	[ "$1" = "--" ] && shift
	plus=("$@")
	echo "== $tag ($envs) seeds ${seeds[*]} ${plus[*]}"
	env $envs TAG="camp_$tag" JOBS=2 TIMEOUT=1800 "$HERE/run_rand.sh" "${seeds[@]}" +cycles="$CYC" +epoch=25000 "${plus[@]}"
}

want() {   # is group $1 selected (no names given: all)
	[ ${#SEL[@]} -eq 0 ] && return 0
	printf '%s\n' "${SEL[@]}" | grep -qx "$1"
}
MODE="${1:-}"
shift
SEL=("$@")
case "$MODE" in
self)
	want self_mix && group self_mix  "SELF=1" 1001 1002 1003 1004 -- +pg_mode=mix
	want self_all && group self_all  "SELF=1" 1011 1012 -- +pg_mode=all
	want self_ofs && group self_ofs  "SELF=1" 1021 1022 -- +pg_mode=all +self_ofs=5
	;;
fe)
	want mix     && group mix       ""         101 102 103 104 105 106 107 108 109 110 -- +pg_mode=mix
	want all     && group all       ""         111 112 113 114 115 116 117 118 -- +pg_mode=all
	want poison  && group poison    "POISON=1" 121 122 123 124 125 126 -- +pg_mode=mix
	want dpc     && group dpc       ""         131 132 133 134 -- +pg_mode=all +only=dpc
	want short   && group short     ""         141 142 -- +pg_mode=short
	want stretch && group stretch   ""         143 144 -- +pg_mode=stretch
	want pause   && group pause     ""         145 146 -- +pg_mode=pause
	want held    && group held      ""         147 148 -- +pg_mode=held
	want fastddr && group fastddr   ""         151 152 153 154 -- +pg_mode=all +ddr_lat_min=1 +ddr_lat_max=3 +ddr_long=0 +slat_min=1 +slat_max=8
	;;
sum)
	python3 -I - "$WORK/runs" <<'PY'
import sys, glob, re, os, collections
tot = collections.Counter(); bad = collections.Counter(); runs = collections.Counter(); fails = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "camp_*_s*.log"))):
    tag = re.sub(r"_s\d+\.log$", "", os.path.basename(f))[5:]
    txt = open(f, errors="replace").read()
    m = re.search(r"^tb_fe_rand: (\d+) epochs, (\d+) cycles, (\d+) clk_sys", txt, re.M)
    if not m:
        fails.append((f, "no summary")); continue
    runs[tag] += 1
    tot[(tag, "cycles")] += int(m.group(2)); tot[(tag, "clk")] += int(m.group(3)); tot[(tag, "epochs")] += int(m.group(1))
    for k, v in re.findall(r" ([a-z_0-9]+) (\d+)", re.search(r"^  bad:(.*)$", txt, re.M).group(1)):
        if k != "total": bad[(tag, k)] += int(v)
    for k, v in re.findall(r" ([a-z_0-9]+) (\d+)", re.search(r"^  info:(.*)$", txt, re.M).group(1)):
        tot[(tag, k)] += int(v)
    if "tb_fe_rand: PASS" not in txt: fails.append((f, "FAIL"))
tags = sorted(runs)
allc = sum(tot[(t, "cycles")] for t in tags if not t.startswith("self"))
selfc = sum(tot[(t, "cycles")] for t in tags if t.startswith("self"))
print("runs %d, daria_fe cycles %d, self-check cycles %d" % (sum(runs.values()), allc, selfc))
for t in tags:
    b = sum(v for (tt, k), v in bad.items() if tt == t)
    print("%-10s runs %2d cycles %11d epochs %5d clk_sys %12d bad %d" % (t, runs[t], tot[(t, "cycles")], tot[(t, "epochs")], tot[(t, "clk")], b))
keys = sorted({k for (t, k) in tot if k not in ("cycles", "clk", "epochs")})
print("totals (daria_fe groups):")
print("  " + ", ".join("%s %d" % (k, sum(tot[(t, k)] for t in tags if not t.startswith("self"))) for k in keys))
print("totals (self-check groups):")
print("  " + ", ".join("%s %d" % (k, sum(tot[(t, k)] for t in tags if t.startswith("self"))) for k in keys))
nz = {(t, k): v for (t, k), v in bad.items() if v}
print("bad counts not 0:", nz if nz else "none")
print("failed runs:", fails if fails else "none")
PY
	;;
*) echo "usage: $0 self|fe|sum" >&2; exit 2 ;;
esac
