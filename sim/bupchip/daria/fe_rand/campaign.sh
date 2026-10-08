#!/bin/bash
# campaign.sh: the 10^8-cycle campaign of the random differential bench
# (design 12.1, 12.2 step 4; lane E3), split into runs of $CYC cycles (each well
# under 30 minutes), two at a time (the machine rule), and the self-check.
#   ./campaign.sh self [G..]  the upstream-vs-upstream self-check (strict, except self_ofs)
#   ./campaign.sh fe [G..]    daria_fe against upstream: the campaign groups (or those named)
#   ./campaign.sh rst [G..]   the +rst_bus=1 groups (design 9.5 rst_release), and the same
#                             seeds against the RTL before F1 (oldrtl: must FAIL)
#   ./campaign.sh sum         the totals over every campaign log in runs/ (camp_*)
# Each group is a tag, build options and plusargs; seeds are distinct per group.
# Every run skips a seed whose log already has a verdict on the current build
# stamp and plusargs (run_rand.sh SKIP_DONE=1), so a piece can be restarted;
# "sum" reports each group's build stamps, and a group must have one.
# SPDX-License-Identifier: MIT
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_rand}"
CYC="${CYC:-2500000}"
CYC_RST="${CYC_RST:-1000000}"
# the RTL before F1 (F1_fixes.md 1): daria_fe_core.sv without the three pclk1 clears
OLDRTL="${OLDRTL:-$WORK/oldrtl}"

group() {   # tag env seeds... -- plusargs... (+cycles=, +epoch= among them replace the defaults)
	local tag="$1" envs="$2"; shift 2
	local seeds=() plus=() cyc="+cycles=$CYC" ep="+epoch=25000"
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do seeds+=("$1"); shift; done
	[ "$1" = "--" ] && shift
	plus=("$@")
	# the bench takes the first of two equal plusargs: a group's own replace the defaults
	printf '%s\n' "${plus[@]}" | grep -q '^+cycles=' && cyc=""
	printf '%s\n' "${plus[@]}" | grep -q '^+epoch=' && ep=""
	echo "== $tag ($envs) seeds ${seeds[*]} $cyc $ep ${plus[*]} ($(date '+%F %T'))"
	# shellcheck disable=SC2086
	env $envs SKIP_DONE=1 TAG="camp_$tag" JOBS=2 TIMEOUT=1800 "$HERE/run_rand.sh" "${seeds[@]}" $cyc $ep "${plus[@]}"
}

want() {   # is group $1 selected (no names given: all)
	[ ${#SEL[@]} -eq 0 ] && return 0
	printf '%s\n' "${SEL[@]}" | grep -qx "$1"
}
MODE="${1:-}"
shift
SEL=("$@")
RST="+cycles=$CYC_RST +epoch=10000 +rst_bus=1 +resets=6"
case "$MODE" in
self)
	want self_mix && group self_mix  "SELF=1" 1001 1002 1003 1004 -- +pg_mode=mix
	want self_all && group self_all  "SELF=1" 1011 1012 -- +pg_mode=all
	want self_rst && group self_rst  "SELF=1" 1031 1032 -- +pg_mode=mix $RST
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
	want nominal && group nominal   ""         149 150 -- +pg_mode=nominal
	want fastddr && group fastddr   ""         151 152 153 154 -- +pg_mode=all +ddr_lat_min=1 +ddr_lat_max=3 +ddr_long=0 +slat_min=1 +slat_max=8
	;;
rst)
	# the RTL before F1: the current daria_fe_core.sv without its three "| pclk1" clears
	if [ ! -f "$OLDRTL/daria_fe_core.sv" ]; then
		mkdir -p "$OLDRTL"
		sed 's/ | pclk1)$/)/' "$ROOT/src/fpga/core/bupchip/daria_fe_core.sv" > "$OLDRTL/daria_fe_core.sv"
	fi
	n=$(diff "$ROOT/src/fpga/core/bupchip/daria_fe_core.sv" "$OLDRTL/daria_fe_core.sv" | grep -c '^<')
	[ "$n" = 3 ] || { echo "campaign.sh: $OLDRTL/daria_fe_core.sv differs from the tree in $n lines, not the 3 pclk1 clears" >&2; exit 2; }
	want rst_dpc    && group rst_dpc    ""                  161 162 -- +pg_mode=mix +only=dpc $RST
	want rst_cdf    && group rst_cdf    ""                  163 164 -- +pg_mode=mix +only=cdf $RST
	want rst_all    && group rst_all    ""                  165 166 -- +pg_mode=all $RST
	want old_dpc    && group old_dpc    "MUT_DIR=$OLDRTL"   161 162 -- +pg_mode=mix +only=dpc $RST +maxfail=200
	want old_cdf    && group old_cdf    "MUT_DIR=$OLDRTL"   163 164 -- +pg_mode=mix +only=cdf $RST +maxfail=200
	;;
sum)
	python3 -I - "$WORK/runs" <<'PY'
import sys, glob, re, os, collections
FE = ["mix", "all", "poison", "dpc", "short", "stretch", "pause", "held", "nominal", "fastddr"]
SELF = ["self_mix", "self_all", "self_rst", "self_ofs"]
RST = ["rst_dpc", "rst_cdf", "rst_all"]
OLD = ["old_dpc", "old_cdf"]
tot = collections.Counter(); bad = collections.Counter(); runs = collections.Counter()
stamps = collections.defaultdict(set); fails = []; firsts = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "camp_*_s*.log"))):
    tag = re.sub(r"_s\d+\.log$", "", os.path.basename(f))[5:]
    if tag not in FE + SELF + RST + OLD:
        continue
    txt = open(f, errors="replace").read()
    st = re.search(r"^run_rand: build (\S+) stamp (\S+)", txt, re.M)
    v = re.search(r"^run_rand: verdict (PASS|FAIL) .* stamp (\S+) args", txt, re.M)
    if not st or not v:
        fails.append((os.path.basename(f), "no verdict (running, or killed)")); continue
    stamps[tag].add(st.group(1) + ":" + st.group(2))
    m = re.search(r"^tb_fe_rand: (\d+) epochs, (\d+) cycles, (\d+) clk_sys", txt, re.M)
    if not m:
        fails.append((os.path.basename(f), "no summary")); continue
    runs[tag] += 1
    tot[(tag, "cycles")] += int(m.group(2)); tot[(tag, "clk")] += int(m.group(3)); tot[(tag, "epochs")] += int(m.group(1))
    for k, val in re.findall(r" ([a-z_0-9]+) (\d+)", re.search(r"^  bad:(.*)$", txt, re.M).group(1)):
        if k != "total": bad[(tag, k)] += int(val)
    for k, val in re.findall(r" ([a-z_0-9]+) (\d+)", re.search(r"^  info:(.*)$", txt, re.M).group(1)):
        if k != "cycles": tot[(tag, k)] += int(val)
    r = re.search(r"^  rst_release: planned \(\+rst_bus\) (.*?) \(released (\d+), aborted (\d+)\)", txt, re.M)
    if r:
        for k, val in re.findall(r"([a-z_]+) (\d+)", r.group(1)):
            tot[(tag, "plan_" + k)] += int(val)
        tot[(tag, "plan_released")] += int(r.group(2)); tot[(tag, "plan_aborted")] += int(r.group(3))
    if v.group(1) != "PASS":
        fails.append((os.path.basename(f), "FAIL"))
        fl = re.search(r"^FAIL ([a-z_0-9]+) at clk (\d+) .*$", txt, re.M)
        if fl: firsts.append((os.path.basename(f), fl.group(0)[:200]))
def line(tags, title):
    tags = [t for t in tags if runs[t]]
    print("%s: runs %d, cycles %d, clk_sys %d" % (title, sum(runs[t] for t in tags),
          sum(tot[(t, "cycles")] for t in tags), sum(tot[(t, "clk")] for t in tags)))
    for t in tags:
        b = sum(v for (tt, k), v in bad.items() if tt == t)
        print("  %-9s runs %2d cycles %11d epochs %5d clk_sys %12d bad %d  build %s%s" % (t, runs[t], tot[(t, "cycles")],
              tot[(t, "epochs")], tot[(t, "clk")], b, ",".join(sorted(stamps[t])), "  MIXED BUILDS" if len(stamps[t]) > 1 else ""))
    keys = sorted({k for (t, k) in tot if t in tags and k not in ("cycles", "clk", "epochs")})
    print("  counters: " + ", ".join("%s %d" % (k, sum(tot[(t, k)] for t in tags)) for k in keys))
    nz = {(t, k): v for (t, k), v in bad.items() if v and t in tags}
    print("  bad counts not 0: %s" % (nz if nz else "none"))
line(FE, "campaign (daria_fe)")
line(SELF, "self-check")
line(RST, "rst_bus groups")
line(OLD, "rst_bus groups, RTL before F1 (each run must FAIL)")
print("failed runs:", fails if fails else "none")
for f, l in firsts:
    print("  first failure %s: %s" % (f, l))
PY
	;;
*) echo "usage: $0 self|fe|rst|sum [group ...]" >&2; exit 2 ;;
esac
