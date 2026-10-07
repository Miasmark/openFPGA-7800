#!/bin/bash
# Mutation check of lane C's benches (docs/daria_fe/lanes/C_call_copy.md):
# each mutant is one small edit of daria_fe_call.sv (bench tb_fe_call) or
# daria_fe_copy.sv (bench tb_fe_copy), made on a copy in $WORK/mut_c/; the
# bench is built with the copy in place of the original and run in a few
# configurations. A mutant is caught iff a run fails. Nothing in the
# repository is changed.
#   ./tb_fe_call_mut.sh [ID ...]        (default: every mutant)
# POISON=1, JOBS, VERILATOR as run_unit.sh. Prints one line per mutant and
# "caught N of M"; exits 1 if a mutant survives.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_unit}/mut_c"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
B="$ROOT/src/fpga/core/bupchip"
mkdir -p "$WORK"
ln -sfn "$ROOT/src/fpga/mister/rtl" "$WORK/rtl"

# the runs of each bench (one line each); a mutant is caught by the first that fails
CALL_RUNS=(
	"+seed=31 +clocks=400000 +epoch=40000 +k_rst=300"
	"+seed=32 +clocks=300000 +epoch=30000 +stall_up=1 +gap=0 +k_rst=100"
	"+seed=33 +clocks=200000 +epoch=200000 +only=1 +k_cs=400 +pg_mode=all"
	"+seed=8 +clocks=300000 +epoch=50000 +stall_up=1 +gap=0 +pg_mode=all +k_rst=300"
)
COPY_RUNS=(
	"+seed=31 +loads=8 +run_clk=30000"
	"+seed=32 +loads=6 +run_clk=40000 +only=1 +k_svc=300 +pg_mode=all"
	"+seed=33 +loads=10 +run_clk=20000 +k_abort=600 +k_takeab=40 +k_glitch=500"
)

# ID~bench~python find~python replace~what it breaks
read -r -d '' MUTANTS <<'EOF'
m1~call~assign cl_req = s_post | s_rd | f8_rd;~assign cl_req = s_post | s_rd;~F8 not read in the clock the change is first seen
m2~call~		ret_s2 <= ret_s1;~		ret_s2 <= ret_tog;~one synchroniser flop on ret_tog
m3~call~((s_rd & (idx != 3'd1)) | s_rdw | s_apply)~(s_rd | s_rdw | s_apply)~mwin one clock early (X+1 deferred)
m4~call~((s_rd & (idx != 3'd1)) | s_rdw | s_apply)~((s_rd & (idx != 3'd1)) | s_rdw)~mwin ends before M_fe
m5~call~assign cp_cmp   = rd_q & !idx[2] & (idx[1] | idx[0]);~assign cp_cmp   = rd_q & (idx != 3'd0) & (idx <= 3'd4);~take compares a fourth return
m6~call~assign cp_apply = s_apply & is_cdf;~assign cp_apply = s_rdw & is_cdf;~the merge applied one clock early (before FD)
m7~call~wire rel_end = s_rel & !pend2 & !callfn & rel_ok & cpu_ready;~wire rel_end = s_rel & !pend2 & !callfn & rel_ok;~release without cpu_ready
m8~call~wire rel_end = s_rel & !pend2 & !callfn & rel_ok & cpu_ready;~wire rel_end = s_rel & !pend2 & !callfn & cpu_ready;~release outside rel_ok (D3)
m9~call~wire flip    = (p_last | s_flip) & cpu_ready & !cart_reset;~wire flip    = (p_last | s_flip) & !cart_reset;~call_tog flips without cpu_ready
m10~call~assign cp_cap   = cap1 | mrg_go;~assign cp_cap   = start | mrg_go;~the payload captured at C, not L
m11~call~wire p2_now  = pend2 | p2_set;~wire p2_now  = 1'b0;~DPC+ second call not posted at X
m12~call~wire mrg_go  = mrg_end & pend2 & p2e;~wire mrg_go  = 1'b0;~CDF second call not captured at M_fe
m13~call~		if (p2_set)                        p2e <= !in_x;~		if (p2_set)                        p2e <= 1'b1;~a CALLFN after X posted with the pre-merge payload
m14~call~		if (cart_reset | again)            pend2 <= 1'b0;~		if (again)                         pend2 <= 1'b0;~pend2 survives a reset
m15~call~wire flip    = (p_last | s_flip) & cpu_ready & !cart_reset;~wire flip    = (p_last | s_flip) & cpu_ready;~call_tog flips in a reset clock
m16~call~		if (ld_post)                       idx <= 3'd0;~		if (start)                         idx <= 3'd0;~idx not cleared for a second call
m17~call~	wire        wr = idx[2] | idx[1];             // F2-F7: ring[0], rotating~	wire        wr = idx[2] | idx[1] | idx[0];~ring rotated at F1
m18~call~({32{jplus}}            & {cdfj_entry[31:1], 1'b1});~({32{jplus}}            & cdfj_entry);~CDFJ+ entry without the T bit
m19~call~	wire [31:0] f1 = ({32{jplus}}  & cdfj_stack)~	wire [31:0] f1 = ({32{1'b0}}  & cdfj_stack)~CDFJ+ stack not taken
m20~call~32'h0000_0C09~32'h0000_0C08~DPC+ entry without the T bit
m21~call~		else if (p2_set & !in_x)           pend_up <= 1'b1;~		else if (1'b0)                     pend_up <= 1'b1;~pend_up never set
m22~call~		else if (xq)                       pend_up <= 1'b0;~		else if (leave)                    pend_up <= 1'b0;~pend_up cleared at X, not X+1
m23~call~	wire rel_go  = s_rel & (pend2 | callfn);~	wire rel_go  = s_rel & pend2;~a CALLFN committed in REL is lost
m24~call~	wire nxt_hk  = leave & !is_dpc & hk_en;~	wire nxt_hk  = 1'b0;~hook mode reads the returns
m25~call~		rd_q   <= cl_gnt & (s_rd | f8_rd) & !cart_reset;~		rd_q   <= cl_gnt & s_rd & !cart_reset;~F8 not shifted into the ring
m26~call~		cap1   <= !cart_reset & (start | (nxt_dpc & p2_now) | rel_go);~		cap1   <= !cart_reset & (start | rel_go);~DPC+ second call's payload not captured
m27~call~	wire p2_set  = callfn & call_busy & !pend2 & !pend_up & !s_rel;~	wire p2_set  = callfn & call_busy & !pend2 & !s_rel;~a CALLFN taken while upstream's call is still pending
m28~call~	assign cl_a   = {4'hF, !s_post, idx};~	assign cl_a   = {4'hF, !s_post, idx + 3'd1};~posted words one slot off
k1~copy~		else if (rst_rise)     rdl <= 4'd8;~		else if (rst_rise)     rdl <= 4'd7;~F6 at the rise + 7
k2~copy~	wire rst_rise = cart_reset & !rst_q & fe_loaded & !ib_q;~	wire rst_rise = (cart_reset ^ rst_q) & fe_loaded & !ib_q;~F6 on a falling reset too
k3~copy~	wire rst_rise = cart_reset & !rst_q & fe_loaded & !ib_q;~	wire rst_rise = cart_reset & !rst_q & fe_loaded;~a rise during init accepted
k4~copy~		if (load_start) f6_ph <= 4'd0;~		if (1'b0) f6_ph <= 4'd0;~load_start does not stop F6's phases
k5~copy~		else if (f6_done | (ld1 & !(is_dpc | is_cdf)))     ib_q <= 1'b0;~		else if (f6_done | ld1)                            ib_q <= 1'b0;~init_busy dips at L+1
k6~copy~		if (load_start | rst_rise)                         ib_q <= 1'b1;~		if (rst_rise)                                      ib_q <= 1'b1;~init_busy not set at load_start
k7~copy~(f6_i == ((f6_r32 & !f6_dpc) ? 13'h1FFF : 13'h07FF))~(f6_i == 13'h07FF)~CDFJ+ fill stops at 8 KB
k8~copy~(f6_i | {f6_dpc, f6_dpc, 11'd0})~(f6_i | {1'b0, f6_dpc, 11'd0})~DPC+ copy source $0B00
k9~copy~	assign cp_a     = ({13{sel_cw}} & {2'b00, f6_wa})~	assign cp_a     = ({13{sel_cw}} & f6_i)~F6 copy written one word late
k10~copy~	wire clr_lst = ph_clr & (f6_i[4:0] == 5'h1F);~	wire clr_lst = ph_clr & (f6_i[3:0] == 4'hF);~state RAM clear of 16 words
k11~copy~	wire fw      = in_fill & !f6_v;~	wire fw      = in_fill;~fill does not wait for the last copy write
k12~copy~	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) | (!fill & (src[16:15] != 2'b00));~	wire       stop  = (rem == 8'd0) | (!fill & (src[16:15] != 2'b00));~no destination clamp
k13~copy~	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) | (!fill & (src[16:15] != 2'b00));~	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00);~no source bound
k14~copy~	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) | (!fill & (src[16:15] != 2'b00));~	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) | (src[16:15] != 2'b00);~the source bound applied to fills
k15~copy~((d == 2'd1) & r3) | ((d == 2'd0) & r4);~((d == 2'd1) & r3) | ((d == 2'd0) & r3);~fill mask one byte too wide
k16~copy~	wire [7:0] cbyte = fea_q[{d_src, 3'b000} +: 8];~	wire [7:0] cbyte = fea_q[{d, 3'b000} +: 8];~copy byte from the destination's lane
k17~copy~		av_q <= ca_gnt & e_cr & !(e_wr & (d_src == 2'b11));~		av_q <= ca_gnt & e_cr;~copy uses the old word after a crossing
k18~copy~		av_q <= ca_gnt & e_cr & !(e_wr & (d_src == 2'b11));~		av_q <= e_cr & !(e_wr & (d_src == 2'b11));~copy uses fea_q of another A user
k19~copy~	wire       take  = svc_pend & !run & !ib_q & !f6_q & !load_start & !cart_reset;~	wire       take  = svc_pend & !ib_q & !f6_q & !load_start & !cart_reset;~a service taken while one runs
k20~copy~		else if (dma_busy & !svc_hold & !run & rel_ok)      dma_busy <= 1'b0;~		else if (dma_busy & !svc_hold & !run)               dma_busy <= 1'b0;~arm_dma_busy falls outside rel_ok
k21~copy~		else if (dma_busy & !svc_hold & !run & rel_ok)      dma_busy <= 1'b0;~		else if (dma_busy & !run & rel_ok)                  dma_busy <= 1'b0;~arm_dma_busy ignores a deferred latch
k22~copy~(f6_i == (f6_dpc ? 13'h02FF : 13'h01FF))~(f6_i == (f6_dpc ? 13'h01FF : 13'h01FF))~DPC+ fill of 2 KB
k23~copy~		ld1 <= load_end & loading;~		ld1 <= load_start;~family latched at load_start
k24~copy~			f6_r32 <= ram32;~			f6_r32 <= 1'b0;~CDFJ+ RAM size not latched
k25~copy~	wire win_fall = cw_q & !cart_win & fe_loaded;                // c_close~	wire win_fall = !cw_q & cart_win & fe_loaded;                // c_close~F6 on the window's rise, not its fall
k26~copy~	assign fbe[0] = d == 2'd0;~	assign fbe[0] = 1'b1;~fill writes byte 0 of the first word
m29~call~	wire rel_end = s_rel & !pend2 & !callfn & rel_ok & cpu_ready;~	wire rel_end = s_rel & !pend2 & rel_ok & cpu_ready;~a CALLFN in REL released and posted at once
m30~call~		if (cart_reset | (ret_new & (!s_run | leave)))~		if (cart_reset | (ret_new & !s_run))~ret_seen not updated at X
m31~call~	wire nxt_rd  = leave & !is_dpc & !hk_en;~	wire nxt_rd  = leave & is_cdf & !hk_en & !jplus;~CDFJ+ returns not read
m33~call~	wire p2_now  = pend2 | p2_set;               // pending at X (DPC+ leaves RUN in this clock)~	wire p2_now  = pend2;                        // pending at X (DPC+ leaves RUN in this clock)~a DPC+ CALLFN in the X clock lost (design 6.1 as written)
m32~call~	assign call_win      = s_run | s_rd | s_rdw | s_apply | s_hkw;~	assign call_win      = s_run | s_rd | s_rdw | s_hkw;~call_win ends before the merge
k27~copy~	wire       take  = svc_pend & !run & !ib_q & !f6_q & !load_start & !cart_reset;~	wire       take  = svc_pend & !run & !ib_q & !f6_q & !cart_reset;~a service taken in the load_start clock
k28~copy~		if (cart_reset | load_start)  run <= 1'b0;~		if (cart_reset)               run <= 1'b0;~load_start does not stop the engine
k29~copy~	wire f6_done = ph_end & !f6_v;~	wire f6_done = ph_end;~F6 ends with the last copy write
k30~copy~		quiet_q <= cart_reset & (qcnt == 3'd7);~		quiet_q <= cart_reset & (qcnt == 3'd3);~rst_quiet after 4 reset clocks
k31~copy~	wire win_fall = cw_q & !cart_win & fe_loaded;                // c_close~	wire win_fall = cw_q & !cart_win;                            // c_close~F6 after a non-ARM load
k32~copy~	wire       e_wr  = cp_gnt & (e_fl | e_cp);       // the engine's write registers at this edge~	wire       e_wr  = cp_req & (e_fl | e_cp);       // the engine's write registers at this edge~engine advances without its grant
k33~copy~		if (ld1) begin~		if (ld1 & 1'b0) begin~family not latched at load end
EOF

ids=("$@")
caught=0
total=0
survived=""
while IFS='~' read -r id bench find repl what; do
	[ -n "$id" ] || continue
	if [ ${#ids[@]} -gt 0 ] && [[ ! " ${ids[*]} " =~ " $id " ]]; then continue; fi
	total=$((total + 1))
	d="$WORK/$id"
	rm -rf "$d"; mkdir -p "$d"
	cp "$B/daria_fe_$bench.sv" "$d/"
	if ! python3 - "$d/daria_fe_$bench.sv" "$find" "$repl" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("pattern found %d times" % s.count(a))
open(p, "w").write(s.replace(a, b))
PY
	then echo "ERROR $id: the edit does not apply"; exit 2; fi
	if [ "$bench" = call ]; then
		srcs=("$B/daria_mem.sv" "$B/daria_call.sv" "$B/daria_fe_pkg.sv" "$d/daria_fe_call.sv" "$HERE/tb_fe_call.sv")
		runs=("${CALL_RUNS[@]}")
	else
		srcs=("$B/daria_mem.sv" "$B/daria_fe_pkg.sv" "$d/daria_fe_copy.sv"
			"$ROOT/src/fpga/mister/rtl/arm_mapper_ram_init.sv" "$HERE/tb_fe_copy.sv")
		runs=("${COPY_RUNS[@]}")
	fi
	defs=(); [ "${POISON:-0}" = 0 ] || defs=(-DDARIA_RAM_POISON)
	if ! nice -n 10 "$VERILATOR" --binary --timing -j "${JOBS:-2}" -O2 -Wno-fatal -Wno-lint -Wno-style \
			-Wno-TIMESCALEMOD -Wno-MULTIDRIVEN "-I$HERE" --top-module "tb_fe_$bench" "${defs[@]}" \
			-Mdir "$d/obj" -o vtb "${srcs[@]}" > "$d/build.log" 2>&1; then
		echo "ERROR $id: the mutant does not build (see $d/build.log)"; exit 2
	fi
	st=0
	first=""
	for r in "${runs[@]}"; do
		# shellcheck disable=SC2086
		(cd "$WORK/.." && timeout 900 nice -n 10 "$d/obj/vtb" $r +max_err=3) > "$d/run.log" 2>&1
		st=$?
		if [ $st != 0 ]; then first="[$r] $(grep -m1 '^ERROR' "$d/run.log" | cut -c1-140)"; break; fi
	done
	rm -rf "$d/obj"
	if [ $st != 0 ]; then
		caught=$((caught + 1)); echo "caught   $id ($what): $first"
	else
		survived="$survived $id"; echo "SURVIVED $id ($what)"
	fi
done <<< "$MUTANTS"
echo "tb_fe_call_mut: caught $caught of $total${survived:+ (survived:$survived)}"
[ -z "$survived" ]
