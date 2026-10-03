#!/bin/bash
# The PSRAM layer of step 4 (docs/BUPCHIP_CORE.md, "Controller" and the
# verification plan's PSRAM row): agg23's psram.sv, vendored unmodified to
# src/fpga/pocket_utils/, against the PSRAM model psram_model.sv.
#   ./run_psram_ctl.sh            OPS=N accesses per iverilog run (20000),
#                                 VOPS=N per Verilator run (200000)
#   1. psram.sv is upstream's file byte for byte (sha256 below);
#   2. the study's clock count (../model/study/psram/run_psram.sh) on it;
#   3. the model's self-test, tb_psram_model.sv (iverilog): good cycles
#      pass and read back; each timing and protocol check fires alone on a
#      cycle that breaks its rule; the backdoor loads, compares and dumps a
#      file (compared here with cmp);
#   4. tb_psram_ctl.sv with CLOCK_SPEED = 28.636364 on clocks of 28.636364,
#      21.477273 and 21.281 MHz (iverilog): random reads and writes on both
#      dies, every access accepted on the first edge with busy low, 5
#      clocks per access, read_avail 5 edges after the accept, data
#      correct, no model violation, DQ never driven by both;
#   5. the stress knob on each clock: read data later than the datasheet
#      by up to the margin psram.sv leaves (one clock - t_oe, less 10 ps)
#      still passes, fixed or random; 10 ps more fails every read with
#      data errors and no violation;
#   6. must fail: a 60 MHz clock (the model flags T_AADV, T_OE, T_AW,
#      T_DW), and CLOCK_SPEED set to the clock it runs on, 21.477273,
#      21.281 or 14.318181 MHz (state numbers collide, nothing completes);
#   7. six mutations of a copy of psram.sv (write address, dies, byte
#      lanes, DQ not released, a 6-clock read, OE# never low), each must
#      fail tb_psram_ctl.sv;
#   8. Verilator (VERILATOR, default /opt/verilator-5.040 if present): the
#      self-test without its four-state checks, and tb_psram_ctl.sv on the
#      three clocks with VOPS accesses.
# Work files go to $WORK (default sim/work/bupchip/s4/psram). About 1.5
# minutes on one core. Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PSRAM="$(cd "$HERE/../../../src/fpga/pocket_utils" && pwd)/psram.sv"
WORK="${WORK:-$HERE/../../work/bupchip/s4/psram}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
OPS="${OPS:-20000}"
VOPS="${VOPS:-200000}"
# agg23/analogue-pocket-utils ip/mem/psram.sv, last changed in 56391c11
# (2022-09-09), unchanged at 78482d1b (2023-08-10); git blob 2f7797f3
PSRAM_SHA256=199f9f329321eb04d6d73bb9c88b716261bcf4a40181e4a9f66ed0ebcf2a0402
CLOCKS="28.636364 21.477273 21.281"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SRCS=("$PSRAM" "$HERE/psram_model.sv" "$HERE/tb_psram_ctl.sv")
GOOD='data_errors=0 timing_errors=0 violations=0 late_reads=0 bus_errors=0 distinct=1 done=5..5 read_avail=5..5 back_to_back=[1-9][0-9]* clocks_per_access=5..5 min_gap=5$'
RESULTS=()
fails=0
note() {	# PASS|FAIL text
	RESULTS+=("$1  $2")
	[ "$1" = PASS ] || fails=$((fails + 1))
}
field() {	# name line -> value
	echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"
}

echo "=== 1. psram.sv is upstream's"
if [ "$(sha256sum "$PSRAM" | cut -d' ' -f1)" = "$PSRAM_SHA256" ]; then
	note PASS "src/fpga/pocket_utils/psram.sv is agg23's file, unmodified (sha256 ${PSRAM_SHA256:0:16}...)"
else
	note FAIL "src/fpga/pocket_utils/psram.sv differs from agg23's file"
fi

echo "=== 2. the study's clock count"
if PSRAM="$PSRAM" WORK="$WORK/study" "$HERE/../model/study/psram/run_psram.sh"; then
	note PASS "../model/study/psram/run_psram.sh on the vendored copy"
else
	note FAIL "../model/study/psram/run_psram.sh on the vendored copy"
fi

echo "=== 3. the model's self-test (iverilog)"
python3 -c "import sys; open(sys.argv[1], 'wb').write(bytes((7 * k + 3) & 255 for k in range(1001)))" "$WORK/bd.bin"
iverilog -g2012 -o "$WORK/model.vvp" "$HERE/psram_model.sv" "$HERE/tb_psram_model.sv"
out="$(vvp -n "$WORK/model.vvp" +bin="$WORK/bd.bin" +dump="$WORK/bd_dump.bin" 2>&1 || true)"
echo "$out" | grep -E "^(ok|FAIL|  [0-9]|result)"
r="$(echo "$out" | grep "^result")"
if echo "$r" | grep -q "fails=0$" && [ "$(field tests "$r")" -ge 41 ] && cmp -s "$WORK/bd.bin" "$WORK/bd_dump.bin"; then
	note PASS "model self-test, iverilog: $(field tests "$r") of $(field tests "$r"); bd_dump_bin equals the file loaded"
else
	note FAIL "model self-test, iverilog: $r"
fi

period_ps() {	# MHz -> the testbench's clock period in ps (2 x the rounded half)
	python3 -c "import sys; print(2 * round(500000 / float(sys.argv[1])))" "$1"
}
ivl() {	# name CLOCK_SPEED MHz [plusargs] -> the result line; the run's output in $WORK/<name>.log
	local name="$1" cs="$2" mhz="$3"; shift 3
	local v="$WORK/ctl_${cs}_${mhz}.vvp"
	[ -f "$v" ] || iverilog -g2012 -o "$v" -P tb_psram_ctl.CLOCK_SPEED="$cs" -P tb_psram_ctl.CLK_MHZ="$mhz" \
		-P tb_psram_ctl.OPS="$OPS" "${SRCS[@]}"
	nice vvp -n "$v" "$@" > "$WORK/$name.log" 2>&1 || true
	grep "^result" "$WORK/$name.log" || echo "result: none"
}

echo "=== 4. psram.sv with CLOCK_SPEED = 28.636364 (iverilog, $OPS accesses)"
rm -f "$WORK"/ctl_*.vvp
for mhz in $CLOCKS; do
	r="$(ivl "ctl_$mhz" 28.636364 "$mhz")"
	grep -E "^(CLOCK_SPEED|psram_model.*smallest)" "$WORK/ctl_$mhz.log" | sed 's/^/  /'
	echo "  $r"
	if echo "$r" | grep -q "$GOOD" && [ "$(field ops "$r")" = "$OPS" ]; then
		note PASS "$mhz MHz: $(field reads "$r") reads, $(field writes "$r") writes, 5 clocks each, data and timing clean"
	else
		note FAIL "$mhz MHz: $r"
	fi
done

echo "=== 5. stress: read data later than the datasheet"
for mhz in $CLOCKS; do
	m=$(( $(period_ps "$mhz") - 20000 ))	# the OE# window less t_oe: psram.sv's margin
	r="$(ivl "extra_ok_$mhz" 28.636364 "$mhz" +psram_extra_ps=$((m - 10)))"
	echo "  $mhz MHz, extra $((m - 10)) ps: $r"
	echo "$r" | grep -q "$GOOD" && ok1=1 || ok1=0
	r="$(ivl "jitter_ok_$mhz" 28.636364 "$mhz" +psram_jitter_ps=$((m - 10)) +psram_seed=3)"
	echo "  $mhz MHz, jitter 0..$((m - 10)) ps: $r"
	echo "$r" | grep -q "$GOOD" && ok2=1 || ok2=0
	r="$(ivl "extra_bad_$mhz" 28.636364 "$mhz" +psram_extra_ps=$((m + 10)))"
	echo "  $mhz MHz, extra $((m + 10)) ps (must fail): $r"
	ok3=0
	[ "$(field violations "$r")" = 0 ] && [ "$(field data_errors "$r")" -gt 0 ] && \
		[ "$(field late_reads "$r")" = "$(field reads "$r")" ] && ok3=1
	if [ $ok1$ok2$ok3 = 111 ]; then
		note PASS "$mhz MHz: margin $m ps; $((m - 10)) ps late (fixed or random) passes, $((m + 10)) fails every read"
	else
		note FAIL "$mhz MHz stress: fixed $ok1, random $ok2, over the margin caught $ok3"
	fi
done

echo "=== 6. must fail"
r="$(ivl fast_60 28.636364 60 2>&1)"
echo "  60 MHz: $r"
grep "^psram_model.* x " "$WORK/fast_60.log" | sed 's/^/  /'
if [ "$(field violations "$r")" -gt 0 ] && grep -q " x T_AADV" "$WORK/fast_60.log" && grep -q " x T_OE" "$WORK/fast_60.log" \
	&& grep -q " x T_AW" "$WORK/fast_60.log" && grep -q " x T_DW" "$WORK/fast_60.log"; then
	note PASS "a 60 MHz clock fails: the model flags T_AADV, T_OE, T_AW and T_DW"
else
	note FAIL "a 60 MHz clock was not caught: $r"
fi
for mhz in 21.477273 21.281 14.318181; do
	r="$(OPS=20 ivl "own_$mhz" "$mhz" "$mhz")"
	echo "  CLOCK_SPEED = clock = $mhz: $r"
	if [ "$(field distinct "$r")" = 0 ] && [ "$(field timing_errors "$r")" -gt 0 ]; then
		note PASS "CLOCK_SPEED = $mhz on its own clock fails: states collide, no access completes"
	else
		note FAIL "CLOCK_SPEED = $mhz on its own clock was not caught: $r"
	fi
done
rm -f "$WORK"/ctl_*.vvp

echo "=== 7. mutations of a copy of psram.sv (in \$WORK), $((OPS / 10)) accesses each: every one must fail"
while IFS='|' read -r name expr; do
	[ -n "$name" ] || continue
	sed "$expr" "$PSRAM" > "$WORK/mut.sv"
	if cmp -s "$PSRAM" "$WORK/mut.sv"; then
		note FAIL "mutation \"$name\": the edit did not apply"
		continue
	fi
	iverilog -g2012 -o "$WORK/mut.vvp" -P tb_psram_ctl.OPS=$((OPS / 10)) "$WORK/mut.sv" "$HERE/psram_model.sv" "$HERE/tb_psram_ctl.sv"
	r="$(vvp -n "$WORK/mut.vvp" 2>&1 | grep "^result" || echo "result: none")"
	echo "  $name: $r"
	if echo "$r" | grep -q "$GOOD"; then
		note FAIL "mutation \"$name\" was not caught"
	else
		note PASS "mutation \"$name\" caught: data_errors=$(field data_errors "$r") timing_errors=$(field timing_errors "$r") violations=$(field violations "$r") bus_errors=$(field bus_errors "$r")"
	fi
done <<'EOF'
write address bit 0 flipped|0,/cram_data <= addr\[15:0\];/s//cram_data <= addr[15:0] ^ 16'h0001;/
dies swapped|s/if (bank_sel) cram_ce1_n <= 0;/if (bank_sel) cram_ce0_n <= 0;/; s/else cram_ce0_n <= 0;/else cram_ce1_n <= 0;/
byte lanes swapped|s/if (write_high_byte) cram_ub_n <= 0;/if (write_high_byte) cram_lb_n <= 0;/; s/if (write_low_byte) cram_lb_n <= 0;/if (write_low_byte) cram_ub_n <= 0;/
DQ not released before a read|/STATE_READ_ADDR_LATCH_END: begin/,/STATE_READ_DATA_ENABLE: begin/ s/data_out_en <= 0;/data_out_en <= 1;/
6-clock read|s/STATE_READ_DATA_RECEIVED = READ_INITIAL_COUNT + TOTAL_READ_CYCLE_COUNT;/STATE_READ_DATA_RECEIVED = READ_INITIAL_COUNT + TOTAL_READ_CYCLE_COUNT + 1;/
OE# never low|s/cram_oe_n <= 0;/cram_oe_n <= 1;/
EOF
rm -f "$WORK/mut.sv" "$WORK/mut.vvp"

echo "=== 8. Verilator"
vbuild() {	# top obj [-G...] -> builds $obj/vtb
	local top="$1" obj="$2"; shift 2
	rm -rf "$obj"
	nice "$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module "$top" "$@" -Mdir "$obj" -o vtb > "$obj.log" 2>&1 \
		|| { grep -E "^%Error" "$obj.log" | head -20 >&2; echo "build failed: $obj.log" >&2; return 1; }
}
if vbuild tb_psram_model "$WORK/vl_model" "$HERE/psram_model.sv" "$HERE/tb_psram_model.sv"; then
	out="$("$WORK/vl_model/vtb" +verilator+error+limit+100000 +bin="$WORK/bd.bin" +dump="$WORK/bd_dump_vl.bin" 2>&1 || true)"
	r="$(echo "$out" | grep "^result")"
	echo "  $r"
	if echo "$r" | grep -q "fails=0$" && [ "$(field tests "$r")" -ge 34 ] && cmp -s "$WORK/bd.bin" "$WORK/bd_dump_vl.bin"; then
		note PASS "model self-test, Verilator: $(field tests "$r") of $(field tests "$r") (no X or bus checks in two states)"
	else
		note FAIL "model self-test, Verilator: $r"
	fi
else
	note FAIL "model self-test, Verilator: build failed"
fi
rm -rf "$WORK/vl_model"
for mhz in $CLOCKS; do
	obj="$WORK/vl_ctl_$mhz"
	if vbuild tb_psram_ctl "$obj" -GCLK_MHZ="$mhz" -GOPS="$VOPS" "${SRCS[@]}"; then
		r="$(nice "$obj/vtb" 2>&1 | grep "^result" || echo "result: none")"
		echo "  $mhz MHz: $r"
		if echo "$r" | grep -q "$GOOD" && [ "$(field ops "$r")" = "$VOPS" ]; then
			note PASS "Verilator, $mhz MHz: $(field reads "$r") reads, $(field writes "$r") writes, 5 clocks each, clean"
		else
			note FAIL "Verilator, $mhz MHz: $r"
		fi
	else
		note FAIL "Verilator, $mhz MHz: build failed"
	fi
	rm -rf "$obj"
done

echo
echo "=== Summary"
printf '%s\n' "${RESULTS[@]}"
[ $fails = 0 ] && echo "PASS: ${#RESULTS[@]} of ${#RESULTS[@]}" || { echo "FAIL: $fails of ${#RESULTS[@]}"; exit 1; }
