#!/bin/bash
# Mutation check of lane A's benches (docs/daria_fe/lanes/A_core.md): each
# mutant is one small edit of daria_fe_seq.sv, daria_fe_dec.sv or
# daria_fe_core.sv, made on a copy in $WORK/mut/; the bench named with it
# (tb_fe_core or tb_fe_seq) is built with the copy in place of the original
# and run. A mutant is caught iff its bench fails. Nothing in the repository
# is changed.
#   ./tb_fe_core_mut.sh [ID ...]        (default: every mutant)
# CYCLES (tb_fe_core, default 200000 in epochs of 20000: one turn of the
# scheme rotation), POISON=1, JOBS, VERILATOR as
# run_unit.sh. tb_fe_core runs with +formula=0: the checks that only
# restate an RTL formula are off, so a mutant must be caught by behaviour
# (against upstream, or the bench's own invariants). Prints one line per mutant and "caught N of M"; exits 1 if a
# mutant survives.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_unit}/mut"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
B="$ROOT/src/fpga/core/bupchip"
mkdir -p "$WORK"
ln -sfn "$ROOT/src/fpga/mister/rtl" "$WORK/rtl"

# ID~bench~file~python find~python replace~what it breaks
read -r -d '' MUTANTS <<'EOF'
s1~seq~seq~assign rel_ok   = (ph2_r | pclk0) & !pclk1;~assign rel_ok   = (ph2_r | pclk0);~rel_ok true in the pclk1 clock (the held-address double commit)
s2~core~seq~commit & !(k_r[5] | k_r[6] | k_r[7]);~commit & !(k_r[6] | k_r[7]);~ev_short for C = E0+6
s3~seq~seq~assign ph1_open = !ph2_r & !pclk0;~assign ph1_open = !ph2_r;~ph1_open in the pclk0 clock
s4~seq~seq~c_r   <= commit ? 4'h1  : (c_r[3] ? c_r : {c_r[2:0], 1'b0});~c_r   <= commit ? 4'h1  : {c_r[2:0], 1'b0};~c does not saturate
d1~core~dec~wire        c_hot  = a12 & !c_sub & ~wire        c_hot  = a12 & ~CDF hotspot on a substituted read (Q9)
d2~core~dec~(jrev ? (romb[7:1] == 7'd0) : (romb == 8'd0))~(romb == 8'd0)~CDFJ jump operand 1 of $01 rejected
d3~core~dec~({1'b0, romb} <= flim)~({1'b0, romb} < flim)~fetch offset range one short
d4~core~dec~(romb < 8'h28)~(romb <= 8'h28)~DPC+ fast-fetch register range
d5~core~dec~(c_sub & !c_amp) | (access & c_dsw)~(c_sub & !c_amp) | c_dsw~DSWRITE select not access-gated
d6~core~dec~wire  [5:0] amp_op = foff_en ? (amp_s + foff[5:0]) : amp_s;~wire  [5:0] amp_op = amp_s;~amplitude operand ignores the offset
d7~core~dec~((a >= 12'h060) & (a < 12'h068))~((a >= 12'h060) & (a < 12'h070))~DPC+ write select covers HI
d8~core~dec~(jplus ? 15'h0800 : 15'h1000)~15'h1000~CDFJ+ ROM base
d9~core~dec~dec.c.dfld   = is_dpc & d_wreg & ((d_g <= 4'd5) | (d_g == 4'd8));~dec.c.dfld   = is_dpc & d_wreg & (d_g <= 4'd5);~HI writes dropped
c1~core~core~assign cr_wb    = wb_v & rdW;~assign cr_wb    = wb_v;~pointer write before W is final
c2~core~core~wire        s_fire = pend_s & (!sw_d | rdW);~wire        s_fire = pend_s;~S post write before W is final
c3~core~core~4'd0:    be_fld = sf ? 4'b0011 : 4'b0010;~4'd0:    be_fld = 4'b0011;~FRACLOW ignores stable_fractional
c4~core~core~wb_a <= pb + (wb_set_f ? {3'b000, opc.idx} : 9'd32);~wb_a <= pb + (wb_set_f ? {3'b000, opc.idx} : 9'd33);~DSWRITE pointer slot
c5~core~core~ & (rom_a[14:1] != 14'h3FFF);~;~jok at $7FFE/$7FFF (Q18)
c6~core~core~wire       fd_amp  = op_r.c.amp & ph1_open & !k[0] & !k[1];~wire       fd_amp  = 1'b0;~AMPLITUDE not reloaded every edge
c7~core~core~((is_dpc & (op_r.fn == 3'd2)) ? {8{wf}} : 8'hFF)~8'hFF~DATAW without the window flag
c8~core~core~if (commit & opc.c.dpar & (pptr < 4'd8)) pptr <= pptr + 4'd1;~if (commit & opc.c.dpar & (pptr < 4'd4)) pptr <= pptr + 4'd1;~PARAMETER pointer saturates at 4
c9~core~core~({8{cs_rd2}}  & {4'h0, stb_q[18:16], 1'b0})~({8{cs_rd2}}  & {4'h0, stb_q[18:16], 1'b1})~CALLFUNCTION reads w1[p2] for the counter
c10~core~core~3'd1:    rbyte = rnd_prior[7:0];~3'd1:    rbyte = rnd_next[7:0];~RANDOM0PRIOR returns the next value
c11~core~core~wire        fp_d     = is_dpc ? (!d_regc & ff_en & opc.a9)~wire        fp_d     = is_dpc ? (!d_regc & opc.a9)~DPC+ fast fetch arms without FASTFETCH
c12~core~core~((opc.c.cjmp & jrev & (jr == 2'd2)) | arm_j)~((opc.c.cjmp & jrev) | arm_j)~jump stream reloaded on operand 2
c13~core~core~({32{bv_fp}}         & {8'h0, crb_q[15:0], 8'h00})~({32{bv_fp}}         & {4'h0, crb_q[15:0], 12'h000})~CDFJ+ increment shift
c14~core~core~if (rst_fe | pclk1) begin~if (rst_fe) begin~ready flags not cleared at E0
c15~core~core~wire act_dsw = (at_dsw | (pend_c == PC_DSW)) & rdP;~wire act_dsw = at_dsw | ((pend_c == PC_DSW) & rdP);~DSWRITE not waiting for P32 (F1)
c16~core~core~wire [11:0] d_cnt     = (op_r.fn == 3'd3) ? stb_q[19:8] : stb_q[11:0];~wire [11:0] d_cnt     = stb_q[11:0];~FRACDATA addressed by the counter
c17~core~core~assign look_a   = rom_a[14:2] + 13'd1;~assign look_a   = rom_a[14:2];~lookahead reads the same word
c18~core~core~wire ld_crb = (k[2] & (o_cfet | o_cjmp)) | p32_q;~wire ld_crb = (k[2] & (o_cfet | o_cjmp));~W never takes P32
c19~core~core~always_ff @(posedge clk_sys) lane_q <= rom_a[1:0];~always_comb lane_q = rom_a[1:0];~the mirror lane not registered (stale byte)
c20~core~core~: (hot_end ? (jplus ? 3'd0 : 3'd6)~: (hot_end ? 3'd6~CDFJ+ FF4/FFB bank
c21~core~core~note_v   <= a_in[1:0] - 2'd1;~note_v   <= a_in[1:0];~NOTE voice
c22~core~core~(d_in[7:1] == 7'h7F)~(d_in[7:2] == 6'h3F)~CALLFN on $FC/$FD
c23~core~core~svc_rem  <= W[31:24];~svc_rem  <= W[23:16];~service count from p2
c24~core~core~assign cr_p32   = (k[1] & (dec.c.cdsw | dec.c.cdsp)) | (k[2] & o_ds & !p32_got);~assign cr_p32   = (k[1] & (dec.c.cdsw | dec.c.cdsp));~no P32 retry in k[2]
c25~core~core~jexp <= opc.c.cjmp ? (jexp + 13'd1) : (a_in + 13'd1);~jexp <= opc.c.cjmp ? jexp : (a_in + 13'd1);~jump operand address not advanced
c26~core~core~wire        s_par = opc.c.dpar & (pptr < 4'd4);~wire        s_par = opc.c.dpar & (pptr < 4'd8);~params 4-7 written into word $10
c27~core~core~wire act_svc = (at_svc | (pend_c == PC_SVC)) & rdS_r;~wire act_svc = at_svc;~service latch takes stale clamps (F4)
c28~core~core~if (k[2]) wf <= win;~if (k[3]) wf <= win;~window flag from the wrong word
c29~core~core~else if (s_fire | pclk1)~else if (s_fire)~S post write not dropped at pclk1 (fires a cycle late after a release)
c30~core~core~else if (act_dsw | act_dsp | act_svc | pclk1)~else if (act_dsw | act_dsp | act_svc)~DSWRITE/DSPTR/service not dropped at pclk1
c31~core~core~else if (r_fire | pclk1)~else if (r_fire)~PUSH/WRITE byte not dropped at pclk1
c32~core~core~assign a_pend_late  = pclk1 & !rcyc & ~assign a_pend_late  = pclk1 & ~a_pend_late without rcyc (fires in a release cycle)
c33~core~core~if (pclk1)       rcyc <= 1'b0;~if (1'b0)       rcyc <= 1'b0;~rcyc never cleared (a_pend_late off for the whole run)
c34~core~core~if (pclk1)       rcyc <= 1'b0;~if (rst_fe)       rcyc <= 1'b1; else if (pclk1) rcyc <= 1'b0;~rcyc with rst_fe first (F1's first version: set by a reset high only at the E0 edge, a_pend_late off for the next cycle)
EOF

ids=("$@")
caught=0
total=0
survived=""
while IFS='~' read -r id bench file find repl what; do
	[ -n "$id" ] || continue
	if [ ${#ids[@]} -gt 0 ] && [[ ! " ${ids[*]} " =~ " $id " ]]; then continue; fi
	total=$((total + 1))
	d="$WORK/$id"
	rm -rf "$d"; mkdir -p "$d"
	for f in seq dec core; do cp "$B/daria_fe_$f.sv" "$d/"; done
	if ! python3 - "$d/daria_fe_$file.sv" "$find" "$repl" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("pattern found %d times" % s.count(a))
open(p, "w").write(s.replace(a, b))
PY
	then echo "ERROR $id: the edit does not apply"; exit 2; fi
	if [ "$bench" = seq ]; then
		srcs=("$d/daria_fe_seq.sv" "$HERE/tb_fe_seq.sv"); top=tb_fe_seq; plus=(+seq_clocks=600000)
	else
		srcs=("$B/daria_mem.sv" "$B/daria_fe_pkg.sv" "$d/daria_fe_seq.sv" "$d/daria_fe_dec.sv" "$d/daria_fe_core.sv"
			"$ROOT/src/fpga/mister/rtl/cache_ram.v" "$ROOT/src/fpga/mister/rtl/mapper_dpcplus.sv"
			"$ROOT/src/fpga/mister/rtl/mapper_cdf.sv" "$ROOT/src/fpga/mister/rtl/arm_mapper_tables.sv"
			"$ROOT/src/fpga/mister/rtl/cdf_fastjump_table.sv" "$HERE/tb_fe_core.sv")
		top=tb_fe_core; plus=(+cycles="${CYCLES:-200000}" +epoch=20000 +stop=1 +formula=0)
	fi
	defs=(); [ "${POISON:-0}" = 0 ] || defs=(-DDARIA_RAM_POISON)
	if ! nice -n 10 "$VERILATOR" --binary --timing -j "${JOBS:-2}" -O2 -Wno-fatal -Wno-lint -Wno-style \
			-Wno-TIMESCALEMOD -Wno-MULTIDRIVEN "-I$HERE" --top-module "$top" "${defs[@]}" \
			-Mdir "$d/obj" -o vtb "${srcs[@]}" > "$d/build.log" 2>&1; then
		echo "ERROR $id: the mutant does not build (see $d/build.log)"; exit 2
	fi
	(cd "$WORK/.." && timeout 900 nice -n 10 "$d/obj/vtb" "${plus[@]}") > "$d/run.log" 2>&1
	st=$?
	rm -rf "$d/obj"
	first="$(grep -m1 -E '^FAIL|errors k|FAIL \(' "$d/run.log" | cut -c1-150)"
	if [ $st != 0 ]; then
		caught=$((caught + 1)); echo "caught   $id ($what): $first"
	else
		survived="$survived $id"; echo "SURVIVED $id ($what)"
	fi
done <<< "$MUTANTS"
echo "tb_fe_core_mut: caught $caught of $total${survived:+ (survived:$survived)}"
[ -z "$survived" ]
