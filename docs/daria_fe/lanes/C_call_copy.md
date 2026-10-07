# Lane C: `daria_fe_call`, `daria_fe_copy` (DARIA step 6)

This is lane C's report for `docs/daria_fe/design.md` 12.2 step 1: the call side (design 6, D5) and F6, the state-RAM clear, the DPC+ copy/fill engine, `init_busy` and `arm_dma_busy` (design 7, D3, D6, D7), with their unit benches (12.3). The ports are `docs/daria_fe/interfaces.md`'s, unchanged. No port request was needed.

**Status.** Built and passing. @@STATUS@@

## 1. What is built

| File | What it is |
|---|---|
| `src/fpga/core/bupchip/daria_fe_call.sv` | Design 6: the one-hot FSM (IDLE, POST, FLIP, RUN, RD, RDW, APPLY, HKW, REL; `daria_fe_pkg::CS_*`), the posts of F0-F7, the flip of `call_tog` on `cpu_ready`, `ret_tog` through two flops (`ret_s1` FORCED), the F8 read in the clock the change is first seen, F9-FD in the next five, the ring strobes to `u_audio`, the release on `rel_ok & cpu_ready`, the one-deep `pend2`, the hook path, the taps and events of 1.4/1.7 |
| `src/fpga/core/bupchip/daria_fe_copy.sv` | Design 7: load tracking (not reset by `cart_reset`), the two F6 triggers, `init_busy`, `rst_quiet`, the F6 sequencer (CLR, P1, P2, END; `daria_fe_pkg::F6_*`), the copy/fill engine with the run-time clamps, `arm_dma_busy`, the taps and `a_f6_live` |
| `sim/bupchip/daria/fe_unit/tb_fe_call.{sv,f}` | `daria_fe_call` + the real `daria_call.sv` + `daria_mem`'s state RAM + a stand-in for `bup_cpu`'s call interface (section 2.1) |
| `sim/bupchip/daria/fe_unit/tb_fe_copy.{sv,f}` | `daria_fe_copy` + `daria_mem` against upstream's `arm_mapper_ram_init` (instantiated) and `mapper_dpcplus`'s service arithmetic (section 2.2) |
| `sim/bupchip/daria/fe_unit/tb_fe_call_suite.sh` | The lane's standard runs of both benches through `run_unit.sh`, with a coverage list per run (section 3) |
| `sim/bupchip/daria/fe_unit/tb_fe_call_mut.sh` | The mutation check of both benches (section 4) |

Every file is MIT, `` `default_nettype none `` (restored at the end), with no output-port initialiser (power-up values on internal registers, ports driven by `assign`). Both RTL files are clean under the lint command of interfaces.md section 2 (`-Wall`, the whole tree: 0 warnings today). The waivers are UNUSEDSIGNAL on the inputs no rule reads (`u_call.hk_stb`, `u_copy.guard_on`; interfaces.md 10 item 3, L-3), on `cdfj_entry[0]` (replaced by the T bit), on the bench-only events, and PROCASSINIT on the power-up values (the repository's idiom).

### 1.1 `daria_fe_call`

| Edge | What (nominal C = E0+6; design 6.2, 6.3) |
|---|---|
| C | `callfn & !call_busy`: `call_busy` ← 1, POST, `cap1` ← 1, `idx` ← 0 |
| C+1 = L | `cp_cap` (= `cap1`) in (C, C+1): the ring takes the payload at L. F0 written |
| C+2 … C+8 | F1, then F2-F7 = `ring0` with `cp_rot` on each granted word. A denied word (DPC+: the core's S use) waits; every word and the flip follow it |
| C+8 | the last write flips `call_tog` (and `cnum`) if `cpu_ready`, else FLIP waits for it |
| (S2, X) | `ret_new = ret_s2 ^ ret_seen`. CDF without the hook: the F8 read is presented in this very clock; X is the edge that registers it |
| X | `ret_seen` ← `ret_s2`. CDF: RD, `idx` ← 1. Hook: HKW. DPC+: REL, or POST + `cap1` for a pending call (`cp_cap` at M = X+1) |
| X+1 … X+5 | F9-FD registered; `cp_shin` (= `rd_q`) in (X, X+1) … (X+5, X+6), `cp_cmp` on the first three |
| (X+1, X+2) … (X+6, X+7) | `mwin` |
| X+7 = M_fe | `cp_apply` in (X+6, X+7); with a pending call committed before X also `cp_cap` (the pre-merge payload, 6.4) |
| ≥ X+7 (CDF), ≥ X (DPC+) | REL: `call_busy` ← 0 at the first edge with `rel_ok & cpu_ready` |

`call_win` = RUN | RD | RDW | APPLY | HKW. `cl_a` = `{4'hF, !POST, idx}` (F0+idx while posting, F8+idx while reading), `cl_we` = POST, `cl_wd` = AND-OR of F0, F1 and `ring0` on `idx`. F0 = `$0000_0C09` (DPC+), `$0000_0809` (CDF0/1/J), `{cdfj_entry[31:1], 1}` (CDFJ+); F1 = `cdfj_stack` (CDFJ+), else `$4000_1FFC`. Reset (6.5): IDLE, `call_busy`, `pend2`, `pend_up` 0, `ret_seen` ← `ret_s2` on every reset clock, `call_tog` and `cnum` kept; a flip is gated by `!cart_reset`.

**D10.** One load enable and at most three data sources per register (`idx`: 0, 1, `idx`+1; `st` is next-state logic with the reset; the rest have one or two). AND-OR one-hot muxes for `st`'s next state and `cl_wd`. Every stage registered: `cl_req`/`cl_a`/`cl_we`/`cl_wd` come from `st`, `idx`, `ret_s2`, `ret_seen` and `ring0` (a `u_audio` register); `cl_gnt` reaches only the FSM, `idx`, `rd_q` and `ret_seen`, never a request, address or data output of the block (interfaces.md 10 item 3).

### 1.2 `daria_fe_copy`

- **Load tracking and triggers** are 7.1 as written: `loading`, `ld1` (`load_end & loading`), `fe_loaded`/`f6_dpc`/`f6_r32` latched at `ld1` (upstream's `load_end_d`), `rst_rise = cart_reset & !rst_q & fe_loaded & !init_busy`, `rdl` 8 → 1, `f6_go` = the `cart_win` fall with an ARM image loaded, or `rdl == 1`. `qcnt`/`rst_quiet` as 7.1. `init_busy` rises at `load_start` or an accepted rise and falls at `f6_done`, or at `ld1` for a non-ARM image.
- **F6** (7.2) is one counter `f6_i` and the one-hot `f6_ph`. CLR writes S words $00-$1F (`cz_req`). DPC+: P1 fills R words $000-$2FF, P2 copies FE ROM words $1B00-$1FFF to R $300-$7FF. CDF: P1 copies FE ROM words $000-$1FF to R $000-$1FF, P2 fills R $200-$7FF ($200-$1FFF with `ram32`). A copy reads word `f6_i` on port A in one clock and writes its q in the next (`f6_v`, `f6_wa`); the CDF fill waits that one write. END holds the last copy write, then `f6_done`. 2,082 clocks for DPC+ and CDF 8 KB, 8,226 for CDFJ+ (design 7.2's counts, checked every clock).
- **The engine** (7.3). `svc_take = svc_pend & !run & !init_busy & !f6_act & !load_start & !cart_reset`. `stop = rem == 0 | dst == $1C00 | (!fill & src >= $8000)`. A fill writes one word per granted clock, byte lanes [dst, min(dst + rem, word end)), and advances `dst`/`rem` by the lane count. A copy reads `src[14:2]` on port A every clock it runs (`ca_req`); `av_q` marks a clock whose `fea_q` is that word (granted last clock, and no word crossing written at that edge); then one byte per granted clock from lane `src[1:0]` to lane `dst[1:0]`.
- **`arm_dma_busy`** (7.4) as written: 0 under `cart_reset | init_busy`, set by `dma_set`, cleared only at an edge with `rel_ok` once `!svc_hold & !run`.
- **D10.** At most three data sources per register (`rdl`: 0, 8, `rdl`−1; `src`/`dst`/`rem`: the latch or the step). AND-OR one-hot muxes for `cp_a`, `cp_be`, `cp_wd` (`sel_cw`, `sel_fw`, `sel_eg`) and `ca_a`. Every stage registered: `fea_q` → byte lane → `cp_wd` (M10K q → logic → M10K), the rest from registers. No grant reaches a request: `cp_gnt` goes only into `src`/`dst`/`rem`, `ca_gnt` only into `av_q`. The requests reach `u_arb` raw, not gated by `guard_on` (the engine yields through `cp_gnt`).

### 1.3 Deviations from the design and readings (ports unchanged)

| # | Design | Built | Why |
|---|---|---|---|
| C-1 | 6.1 REL: `if (rel_ok & cpu_ready)` release; a CALLFN committed in REL sets `pend2` | REL posts a pending call or a CALLFN committed in REL at once (`rel_go`: POST + `cap1`, `call_busy` stays high), and releases only when neither is there | 6.1 as written loses such a call and leaves `pend2` set: the next fresh call is then followed by a phantom second call after its return. Upstream accepts a CALLFN committed after its X at C+1 like any new call; posting it from REL with `cap1` captures at the same L (exact for a CALLFN committed in REL). Mutants m23, m29 |
| C-2 | 6.1 RUN (DPC+): `if (pend2)` (the value before the edge) | `pend2 \| p2_set`: a CALLFN committed in the X clock itself is posted at X | Upstream's `call_pending` rises at that edge and is accepted at M = X+1; 6.1 would lose it as C-1 does. Mutant m11 |
| C-3 | 6.4: `pend2` is posted at M_fe with the pre-merge payload | Only a CALLFN committed by X (`p2e` = 1) is. One committed after X (in RD, RDW, APPLY or HKW) is posted from REL like a fresh call (`cap1`) | Upstream accepts that CALLFN at C2+1 > M, after its merge: its payload is the merged counters, so the pre-merge capture at M_fe would be wrong. DARIA cannot capture at C2+1 (the ring holds the returns until M_fe); it captures at M_fe+2 (REL's first clock + 1). The seeds differ iff a tick falls between C2+1 and the capture: an extension of class `rmw_call` (section 6). It needs the second write of an RMW to commit after X: a very short call with stretched phases, or a pause. Mutant m13 |
| C-4 | 6.1: `else if (callfn & !pend2)` | also `& !pend_up & !REL` | Upstream ignores a CALLFN while `call_pending` (mapper_cdf.sv:245, mapper_dpcplus.sv:294): in DPC+ `pend2` is consumed at X while upstream's `call_pending` lasts to X+1. REL is C-1. Mutant m27 |
| C-5 | 6.1: `pend_up` ← 1 with every `pend2` | only for a CALLFN committed before X | After X upstream's busy is down: its `call_pending` is high for the accept clock only, which `pend_up` (a tap) does not show. The bench compares `pend_up` with upstream's `call_pending` everywhere else |
| C-6 | 6.1 RUN: `if (ret_new)` | CDF without the hook leaves RUN only when the F8 read is granted | Defensive: in CDF the core never uses S, so the read is always granted and the timing is 6.1's. If it ever were not, the F8 read would be retried rather than skipped. Equivalent in every run |
| C-7 | 6.1 `cp_cmp = rd_q & (sidx < 3)` | `rd_q & idx ∈ {1, 2, 3}` | The same three clocks (F8-FA), without a shift counter |
| K-1 | 7.3 `svc_take = svc_pend & !run & !init_busy & !f6_act` | also `& !load_start & !cart_reset` | interfaces.md 10 item 5: `load_start` must win over a take in its own clock. `!cart_reset` keeps the take pulse out of a reset clock (`svc_pend` clears there anyway). Mutant k27 |
| K-2 | 7.3: `aw_q <= src[14:2]; cp_req = … & av_q & (aw_q == src[14:2])` | `av_q <= ca_gnt & run-copy & !(a write at lane 3 at this edge)` | `src` changes only by +1 on a written byte, so the word changes exactly when lane 3 is written: the same condition without the 13-bit register and compare. Mutants k17, k18 |
| K-3 | 7.1: `rdl`, `f6_go` | `load_start` clears `rdl` and blocks `f6_go` | 7.1 "`load_start` aborts F6": a reset-rise countdown in flight must not start F6 after the abort |

## 2. The benches

@@BENCHES@@

## 3. Results

@@RESULTS@@

## 4. Mutations

@@MUTATIONS@@

## 5. Area and timing

@@AREA@@

## 6. Open issues and notes

@@OPEN@@

## 7. Reproducing

@@REPRO@@
