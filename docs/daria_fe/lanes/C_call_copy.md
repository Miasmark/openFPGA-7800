# Lane C: `daria_fe_call`, `daria_fe_copy` (DARIA step 6)

This is lane C's report for `docs/daria_fe/design.md` 12.2 step 1: the call side (design 6, D5) and F6, the state-RAM clear, the DPC+ copy/fill engine, `init_busy` and `arm_dma_busy` (design 7, D3, D6, D7), with their unit benches (12.3). The ports are `docs/daria_fe/interfaces.md`'s, unchanged. No port request was needed.

**Status.** Built and passing. `tb_fe_call`: 10 configurations, 33 million `clk_sys` per pass (190,170 calls, 63,734 CDF returns read and merged, 32.1 million counter/frequency comparisons against upstream), plus a 20-seed sweep of 60 million clocks (262,285 calls); `tb_fe_copy`: 5 configurations, 21.6 million clocks (703 F6 runs checked clock by clock, 841 whole-RAM images equal to upstream's, 6,761 services byte-exact against upstream's `min()`), plus a 20-seed sweep of 58.6 million clocks. Every run passes **with and without `POISON=1`**: suite 15 of 15 both ways, sweep 40 of 40 both ways. Mutations: **66 of 66 caught** (33 per block). Area (`--fit`, ALMs placed − [B]): `daria_fe_call` **65** (10.3 guide ≤ 45), `daria_fe_copy` **141** (guide ≤ 100); slack +65.9 / +61.2 ns. Ten deviations from the letter of design 6-7 (section 1.3), three of them fixes of 6.1/6.4's pending-call handling.

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
| C-2 | 6.1 RUN (DPC+): `if (pend2)` (the value before the edge) | `pend2 \| p2_set`: a CALLFN committed in the X clock itself is posted at X | Upstream's `call_pending` rises at that edge and is accepted at M = X+1; 6.1 would lose it as C-1 does. Mutant m33 |
| C-3 | 6.4: `pend2` is posted at M_fe with the pre-merge payload | Only a CALLFN committed by X (`p2e` = 1) is. One committed after X (in RD, RDW, APPLY or HKW) is posted from REL like a fresh call (`cap1`) | Upstream accepts that CALLFN at C2+1 > M, after its merge: its payload is the merged counters, so the pre-merge capture at M_fe would be wrong. DARIA cannot capture at C2+1 (the ring holds the returns until M_fe); it captures at M_fe+2 (REL's first clock + 1). The seeds differ iff a tick falls between C2+1 and the capture: an extension of class `rmw_call` (section 6). It needs the second write of an RMW to commit after X: a very short call with stretched phases, or a pause. Mutant m13 |
| C-4 | 6.1: `else if (callfn & !pend2)` | also `& !pend_up & !REL` | Upstream ignores a CALLFN while `call_pending` (mapper_cdf.sv:245, mapper_dpcplus.sv:294): in DPC+ `pend2` is consumed at X while upstream's `call_pending` lasts to X+1. REL is C-1. Mutant m27 |
| C-5 | 6.1: `pend_up` ← 1 with every `pend2` | only for a CALLFN committed before X | After X upstream's busy is down: its `call_pending` is high for the accept clock only, which `pend_up` (a tap) does not show. The bench compares `pend_up` with upstream's `call_pending` everywhere else |
| C-6 | 6.1 RUN: `if (ret_new)` | CDF without the hook leaves RUN only when the F8 read is granted | Defensive: in CDF the core never uses S, so the read is always granted and the timing is 6.1's. If it ever were not, the F8 read would be retried rather than skipped. Equivalent in every run |
| C-7 | 6.1 `cp_cmp = rd_q & (sidx < 3)` | `rd_q & idx ∈ {1, 2, 3}` | The same three clocks (F8-FA), without a shift counter |
| K-1 | 7.3 `svc_take = svc_pend & !run & !init_busy & !f6_act` | also `& !load_start & !cart_reset` | interfaces.md 10 item 5: `load_start` must win over a take in its own clock. `!cart_reset` keeps the take pulse out of a reset clock (`svc_pend` clears there anyway). Mutant k27 |
| K-2 | 7.3: `aw_q <= src[14:2]; cp_req = … & av_q & (aw_q == src[14:2])` | `av_q <= ca_gnt & run-copy & !(a write at lane 3 at this edge)` | `src` changes only by +1 on a written byte, so the word changes exactly when lane 3 is written: the same condition without the 13-bit register and compare. Mutants k17, k18 |
| K-3 | 7.1: `rdl`, `f6_go` | `load_start` clears `rdl` and blocks `f6_go` | 7.1 "`load_start` aborts F6": a reset-rise countdown in flight must not start F6 after the abort. Not reachable in the bench (a download never starts within 8 clocks of a reset rise), so no mutant tests it |

## 2. The benches

### 2.1 `tb_fe_call` (design 12.3, `daria_fe_call`)

**Set-up.** `clk_sys` and `clk_arm` on DARIA's PLL lattice (one VCO step 1,455 ps: `clk_sys` 48 steps, `clk_arm` 18, a shared edge every third `clk_sys`); `+arm_ofs` shifts `clk_arm` by whole VCO steps, `+arm_div=5` gives mode A's 5× `clk_arm` (13.968 ns) at any picosecond offset. The DUT and the **real `daria_call`** share `daria_mem`'s state RAM: `daria_call` on port A (`clk_arm`), the DUT on port B through a bench arbiter written from design 3.2 (the core's DPC+ S use first: random reads and writes of words $00-$10 at `+k_cs` per mille of clocks; then the call port). A **stand-in for `bup_cpu`**: parked; on `call_go` it takes the 22 clear entries from `clr_wd` and checks them against the block DARIA posted for that flip (entry = F0, r13 = F1, r14 = $F000_0000, r8-r13 = F2-F7, r0-r12 zero); runs 0-260 `clk_arm` (10% up to 1,500, `+k_short` per mille 0-23); then reads six returns out through `ro_*` (each counter unchanged or random, each frequency mostly random) and raises `returned`, so `daria_call` writes F8-FD and flips `ret_tog`. A reset (two `clk_arm` flops of `cart_reset`) abandons the call; a "fault" reset (`+fault_k`) keeps the CPU running through it, so its `ret_tog` flip arrives after the reset (12.3 item 5's late `ret_tog`). `cpu_ready`: on hardware and mode B `parked & img_ready` through two `clk_sys` flops, with random `img_ready` drops; in mode A steady (6.6); per epoch at random or by `+ready`. The 6507: `fe_phase_gen` (`EXT_BUS`) with a program of CALLFN stores ($FE/$FF to $1FF3 or $105A), RMW pairs (FE→FF and FF→FE: two CALLFNs; FD→FE: the second only; FF→00: the first only), other writes and reads, `+gap` reads after each; the stall is the DUT's `arm_call_busy` (hardware, mode B) or, with `+stall_up=1`, the bench's model of upstream's busy (mode A, where the 6507 runs on after upstream's X). Epochs (`+epoch`) switch DPC+ / CDF0-J / CDFJ+ (random `cdfj_entry`/`cdfj_stack`), hook on or off, and the ready mode, always inside a reset.

**Models (bench-side, from the design and upstream's RTL).**

- **ref**: design 6.1 at the event level, with C-1 … C-5: the state, `arm_call_busy`, `pend2`, `call_win`, and every S request, address, write enable and strobe expected in each clock.
- **X**: the bench's own two flops on `ret_tog`; X is the edge at which the change is first sampled (glue.md 7.3), independent of the DUT.
- **U**: upstream: `arm_mapper_audio`'s counters and frequencies with the ticks, the seeds and the merge at M = X+1 (AUD:191-223), and the controller's `call_pending`, accept and busy (arm_mapper_controller.sv:86, 149-177; mapper_cdf.sv:159-180, 245). A stale return is rejected by upstream's completion token.
- **D**: `u_audio`'s side of the strobe contract (design 5.6, lane B's section 7): the ring (`cp_cap`, `cp_rot`, `cp_shin` + `stb_q`, `cp_cmp` → `take`), `cp_apply`, the tick deferral in `mwin` and the late add, the hook merge. D is driven only by the DUT's strobes and the state RAM's q, so a wrong strobe or a wrong read shows as D ≠ U.
- **Ticks** are placed by a sweep: L−2 … L+2 of each fresh call, M−2 … M+9 of each return, in turn. Counters and frequencies are deposited into U and D at random quiet clocks (`+k_dep`), so the values are arbitrary 32-bit words.

**Checks** (each clock; a failure is counted by name, any failure fails the run):

| 12.3 item | Check |
|---|---|
| 1 | `cl_req`/`cl_we`/`cl_a` every clock against ref (F0+k in POST, F8 in the clock the change is first seen, F9+k in RD); each posted word: F0 and F1 per scheme, F2-F7 = upstream's payload at its accept (U's capture at C+1, or at M for a DPC+ RMW, or the pre-merge values for a CDF RMW); `call_tog` flips exactly at the edge of the last post with `cpu_ready` (or the first `cpu_ready` edge in FLIP), `cnum` with it; the stand-in's launch registers against the posted block |
| 2 | F8 read in (X−1, X) (ref uses the bench's X); F9-FD in the next five clocks, all granted in CDF; `cp_shin` (X, X+1) … (X+5, X+6), `cp_cmp` the first three, `mwin` (X+1, X+2) … (X+6, X+7), `cp_apply` (X+6, X+7); and the end-to-end check: D == U (counters and frequencies of all three voices) at every edge except (X, X+7] of a CDF return without the hook, with ticks swept across L and M |
| 3 | `arm_call_busy` against ref every clock: it falls only at the first edge with REL & `rel_ok` & `cpu_ready` |
| 4 | `pend2` against ref (DPC+ at X, CDF at M_fe, hook at M, after X from REL); `pend_up` against U's `call_pending` every clock (except the accept clock of a call upstream accepts at once); the second call's payload; **one DARIA post per upstream accept**: at every quiet point (DUT idle, upstream idle, nothing pending) the number of upstream accepts equals the number of POST entries since the last reset |
| 5 | resets aimed at each of the nine states (combinationally, so one-clock HKW too), random lengths 1-30: after a reset clock `st` = IDLE, `arm_call_busy`, `pend2`, `pend_up` 0, `ret_seen` = `ret_s2` of that clock, `call_tog` unchanged; `ev_ret_unasked` = (the bench's `ret_tog` change outside a call, outside reset) every clock |
| 6 | hook epochs: RUN → HKW for one clock, no S reads, no `cp_shin`/`mwin`/`cp_apply`, `cp_cap` at M for an RMW; D merges from `hk_ret` at M and must equal U everywhere |
| taps | `ev_rmw_call` = `callfn & arm_call_busy`; `call_busy` = !IDLE; `st` one-hot (== ref) |

### 2.2 `tb_fe_copy` (design 12.3, `daria_fe_copy`)

**Set-up.** `daria_fe_copy` on `daria_mem #(.WIN_KB(32))` (run with `POISON=1` too), `clk_sys` on the lattice. The bench emulates around it:

- the download: `cart_download`, `load_start`/`load_end` (upstream's edges), the image bytes into the FE ROM through `cap_we` with random gaps, 0-4 of them after `load_end`; images DPC+ (1 in 6 of 29,696 bytes), CDF0/1/J (8 KB RAM), CDFJ+ (`ram32`), CDF files 1 in 3 longer than 32 KB (the capture keeps the first 32 KB), and non-ARM;
- `bup_capture`'s window (`cart_win` falls at `load_end` + 63, bup_capture.sv:146-164);
- the wrapper's reset register (`cart_download | old | init_busy | button`, atari7800_pocket.sv:166-172) and top.sv's `reset_hold` tail (1-8 clocks); console resets of 1-40 clocks; forced dips of `cart_reset` inside F6 (`+k_glitch`, to exercise `a_f6_live`);
- a `fe_phase_gen` stream with service stores ($105A ← 1 or 2) and RMW pairs (1→2, 2→1, 0→1, 2→3), stalled by `arm_dma_busy`;
- a model of `u_core`'s service latch: taken only while `!svc_pend` (`dma_set`), latched at C, or at E0+5 for an earlier C (lane A's reading A-4; `svc_hold` covers it), with random parameters biased to the clamps (counter near $FFF, offsets near and beyond $7400, counts 0 and 255);
- an arbiter written from design 3.1-3.3 with random competitors: core fixed, audio, P32 and pointer writes on R, lookahead and audio sample on A, the core on S, and a random `guard_on`;
- random power-up contents of cart RAM, state RAM and a stale FE ROM image.

**References.** Upstream's **`arm_mapper_ram_init`** (instantiated, `src/fpga/mister/rtl`) with its DMA requests executed by a behavioural engine (random latency) on a byte copy of the cart RAM: the image upstream builds at load end and on a console reset. The service: **`mapper_dpcplus`'s `service_fill_count`/`service_copy_count`** transcribed (mapper_dpcplus.sv:85-101, 288-301: `min(p3, $1000 − counter)`, and for a copy 0 if the offset ≥ $7400, else at most `$7400 − offset`), applied to the same reference at `svc_take`. The competitors' pointer writes go into the reference too.

**Checks:**

| 12.3 item | Check |
|---|---|
| 1 | every F6 clock against 7.2's schedule (the bench's own clock index): `f6_ph`, `cz_req`/`cz_a`, `cp_req`/`cp_a`/`cp_be`/`cp_wd` (the copied word = the image word), `ca_req`/`ca_a`, the length (2,082 / 8,226); after both inits: all 8,192 cart RAM words and all 256 state RAM words against upstream's image and the cleared words $00-$1F |
| 2 | F6 starts exactly as the bench predicts from `cart_win`, `cart_reset` and the load: at the window fall, or 8 clocks after an accepted rise (ARM image, no init); never on a fall, never on a rise while `init_busy` (counted `reset_rise_ignored_busy`), never for a non-ARM image; `load_start` aborts F6 (`f6_aborted_by_load`) and the engine (`run` low in the clock after `load_start`); a `load_start` in the very clock a latched service would be taken (`abort_on_take`): no take, nothing runs |
| 3 | `init_busy` every clock against the bench's model; high whenever upstream's `loading` is; equal to upstream's busy after an accepted rise; low at L+1 for a non-ARM image (with upstream's); `rst_quiet` = `cart_reset` high in each of the last 8 clocks; `a_f6_live` = `f6_act & !rst_quiet`, high only around a forced dip |
| 4 | `svc_take` formula; every engine write: only while `run`, only in a clock no other R user and no `guard_on` holds the port, every byte inside [dst, dst + count), written once, equal to upstream's byte; when the engine stops (not abandoned), all count bytes written and the whole cart RAM equal to upstream's; count 0 runs one clock (ends at C+2); the source bound, the destination bound and `min()` (counted when they clamp); the RMW queue (a second service latched while the first runs, taken when it stops); the whole RAM again at the end of each load |
| 5 | `arm_dma_busy` every clock against 7.4 (set at C, held while `svc_hold` or `run`, falls only at a `rel_ok` edge, 0 under `cart_reset`/`init_busy`), and 0 in the clock after any `init_busy` clock |

## 3. Results

All runs below are `run_unit.sh` builds (Verilator 5.040), each bench in its own `WORK` (`runs_C/work`), once without and once with `POISON=1`. Logs in `sim/work/bupchip/daria/fe_unit/runs_C/`.

### 3.1 The suite (`tb_fe_call_suite.sh`)

Each run must pass and show every counter in its coverage list non-zero. **15 of 15 pass, and 15 of 15 with `POISON=1`.**

| Run | Bench, arguments | What it is for | Calls (flips) | CDF returns read |
|---|---|---|---|---|
| `c_mix` | call `+seed=1 +clocks=5000000` | every scheme, hook and ready mode by epoch; resets in all nine states; the tick sweeps | 21,809 | 5,997 |
| `c_modea` | call `+seed=2` … `+stall_up=1 +gap=0 +ready=1` | mode A: the 6507 stalled by upstream's busy, so CALLFNs after X and in REL | 21,090 | 6,496 |
| `c_modea_all` | call `+seed=8` … `+stall_up=1 +gap=0 +pg_mode=all +k_rst=300` | the same with every phase shape and many resets | 19,857 | 7,904 |
| `c_dpc` | call `+seed=3 +only=1 +k_cs=400 +pg_mode=all` | DPC+ with the core taking S 40% of clocks: denied posts | 12,184 | — |
| `c_cdf_hw` | call `+seed=4 +only=2 +hook=0 +ready=0 +k_rst=300 +fault_k=600` | CDF, hardware `cpu_ready`; resets in each state, 146 with the CPU running on (late `ret_tog`) | 12,185 | 11,941 |
| `c_rmwx` | call `+seed=9 +only=1 +k_short=900 +pg_mode=all +gap=0` | DPC+, short calls: a CALLFN in the X clock (C-2) | 19,224 | — |
| `c_dense` | call `+seed=10 +k_short=900 +gap=0 +k_cf=400 +k_rmw=200 +stall_up=1 +pg_mode=all` | dense CALLFNs: upstream's pending call at M (C-4), late `pend2` (C-3), the third CALLFN in (M, M_fe] | 47,003 | 23,755 |
| `c_hook` | call `+seed=5 +only=2 +hook=1 +k_rst=300` | 12.3 item 6, resets in HKW | 8,752 | — |
| `c_5x` | call `+seed=6 +arm_div=5 +arm_ofs=3100 +ready=1` | mode A's 5× `clk_arm`, off the lattice | 15,736 | 4,027 |
| `c_ofs` | call `+seed=7 +arm_ofs=7 +pg_mode=all` | `clk_arm` shifted by 7 VCO steps | 12,330 | 3,614 |
| `k_mix` | copy `+seed=1 +loads=30` | every family, the service mix, aborts, take-clock `load_start` | — | — |
| `k_dpc` | copy `+seed=2 +loads=20 +only=1 +k_svc=300 +pg_mode=all` | DPC+ services under every phase shape; 29,696-byte images | — | — |
| `k_cdf` | copy `+seed=3 +loads=30 +only=2` | CDF 8 KB and CDFJ+ F6 | — | — |
| `k_abort` | copy `+seed=4 +loads=24 +run_clk=20000 +k_abort=600 +k_takeab=40 +k_glitch=500` | aborts of F6 and of services, forced dips | — | — |
| `k_guard` | copy `+seed=5 +loads=12 +only=1 +k_guard=700 +k_aud=500` | the engine under a busy port and a guard 70% on | — | — |

**`tb_fe_call`, all ten runs** (without `POISON`; with it the counts differ by a few percent, see section 6): 33,000,000 clocks; 190,170 flips, upstream accepted 192,728 (the difference: calls posted and then abandoned by a reset before their flip; the accept balance counts posts); 63,734 CDF returns read, each with its F8 in the first clock (`f8_in_first_clock` = returns read), 62,614 merges applied at X+7; 32,124,385 edges with all six counters and frequencies equal to upstream's; 1,536,167 posted words checked (174,956 denied clocks); 133,647 accept-balance checks; `pend_up` against upstream's `call_pending` on 2,452,553 clocks where it is set; RMW pairs: 17,798 DPC+, 14,768 CDF, 8,265 hook; 1,105 of them with a tick exactly on M (`rmw_call` value, design 6.4); CALLFNs after X (C-3) 1,138, in REL 8,812, at X (C-2) 35, at upstream's M (C-4) 272, in (M, M_fe] 758; resets aimed at IDLE 1,504, POST 1,274, FLIP 1,175, RUN 1,481, RD 568, RDW 552, APPLY 563, HKW 232, REL 1,237 (150,055 reset clocks checked); 232 fault resets and 232 `ev_ret_unasked` pulses, each in a clock where the bench's own synchroniser saw a `ret_tog` change outside a call; the tick sweep: 23,652-23,784 ticks at each of L−2 … L+2, 14,518-14,913 at each of M−2 … M+9, 29,049 deferred in `mwin`, 28,600 late adds (the rest overlapped a resync or a reset). With `POISON=1`: 191,345 flips, 61,858 CDF returns, 32,173,438 equal edges, 0 errors.

**`tb_fe_copy`, all five runs** (identical with `POISON=1`): 21,599,415 clocks; loads: 56 DPC+ (12 of 29,696 bytes), 41 CDF, 13 CDFJ+, 6 non-ARM; F6: 485 DPC+, 174 CDF 8 KB, 44 CDFJ+ (1,759,253 F6 clocks checked), 413 by the window, 323 by a reset rise, 1,089 rises ignored inside an init, 21 without an ARM image, 33 aborted by `load_start`; 841 whole images (8,192 + 256 words) equal to upstream's; services: 3,568 fills (401,573 bytes) and 3,336 copies (259,625 bytes), 6,761 checked to the byte and against the whole RAM, 2,113 clamped (1,391 by the destination, 1,007 by the source bound), 1,355 with a count of 0, 267 queued behind a running one (RMW), 526 latched late (short phase 1, `svc_hold`), 143 abandoned by a reset or load; 235 `load_start`s in a take clock; 488,475 engine clocks denied by the guard, 774,918 by any user; `arm_dma_busy` fell 6,478 times, each at a `rel_ok` edge, after 11,153 tail clocks waiting for one; 703 forced dips (`a_f6_live` high on 6,321 clocks, each within 12 clocks of a dip, 0 otherwise).

### 3.2 Seed sweep

Seeds 11-30 (bench and phase generator), each bench at its defaults: `tb_fe_call +clocks=3000000 +epoch=60000`, `tb_fe_copy +loads=20`. **40 of 40 pass without `POISON`, 40 of 40 with it.** Call: 60,000,000 clocks, 262,285 calls (262,269 with `POISON`). Copy: 58,568,549 clocks; 178 DPC+ loads (36 of 29,696 bytes), 133 CDF, 43 CDFJ+, 46 non-ARM; F6 1,279 DPC+, 517 CDF 8 KB, 164 CDFJ+; 2,546 images equal; 27,073 services checked.

### 3.3 Design requirements and where they are proven

| Requirement | Proof |
|---|---|
| 6.2: capture at L, F0-F7 at C+1 … C+8, the flip with F7 if `cpu_ready` | 12.3 item 1 checks (section 2.1); payload = upstream's at its accept, so `seed_race` is 0 by test; the stand-in sees the same block in its launch registers |
| 6.3: `ret_tog` through two flops; F8 in the first clock; six consecutive reads; apply at X+7; `mwin` X+2 … X+7 | item 2 checks; 63,734 returns; D == U outside (X, X+7] with ticks across M−2 … M+9 (the deferral and the late add exact) |
| D3/6.3: release only on `rel_ok & cpu_ready` | `arm_call_busy` against ref every clock; 1.1 million REL clocks waiting |
| 6.4: one-deep `pend2`, DPC+ at M, CDF at M_fe with the pre-merge payload, hook at M; `pend_up` | item 4 checks; accept balance |
| 6.5: reset in every state | item 5 checks; resets aimed at each state |
| 6.6: hook | `c_hook`, hook epochs in `c_mix` |
| 7.1: F6 at the window fall or rise + 8, never on a fall or inside init; `init_busy` from `load_start`; non-ARM drop | 12.3 copy items 2-3 every clock, against the bench's own prediction and upstream's busy |
| 7.2: the images and the clear | item 1 every F6 clock; 841 + 2,546 whole images against upstream's `arm_mapper_ram_init` |
| 7.3: run-time clamps = upstream's `min()`; source bound; RMW queue; audio yields; no write under the guard; count 0 | item 4; 6,761 + 27,073 services byte-exact |
| 7.4: `arm_dma_busy` | item 5 every clock |
| 1.5 rule 3 (no q after a partial write) | `POISON=1`: the engine's partial-byte writes on R are never read back by this block; every run passes poisoned |
| interfaces.md 10 item 5: `load_start` beats a take | `abort_on_take` (235): no take, `run` low the next clock |

## 4. Mutations

`tb_fe_call_mut.sh` edits a copy of one RTL file per mutant (`$WORK/mut_c/<id>/`), builds the bench on it with `run_unit.sh`'s options and runs it in a few configurations until one fails: `tb_fe_call` in six (seeds 31, 32, 33, 8, 9, 10: 0.3-1 million clocks each, the default mix with many resets, mode A with `+gap=0`, DPC+ under S contention, every phase shape, the short and dense RMW streams), `tb_fe_copy` in three (seeds 31, 32, 33: the mix, DPC+ services under every phase shape, aborts and dips). Nothing in the repository is changed.

**66 of 66 caught** (`runs_C/mut_final.log`, the final benches and RTL): 33 for `daria_fe_call` (m1-m33), 33 for `daria_fe_copy` (k1-k33). Two earlier mutants were found equivalent and replaced: "`ret_seen` not re-synced in reset" (outside RUN `ret_seen` follows `ret_s2` anyway, and in CDF the F8 read is always granted, so the reset term adds nothing observable) and "F6 starts whenever the window is low" (`bup_capture`'s window is high from `load_start` to the close without a gap, so the first low clock is the fall). m27 needed the dense configuration (seed 10): it is upstream's one-clock `call_pending` at M, which the default streams reach a few times per million clocks.

In `tb_fe_call` the first failing check is mostly the per-clock comparison with ref; ref itself is held to upstream by the end-to-end checks (D == U, the posted payload against upstream's accept, the launch registers, the accept balance, `pend_up` against `call_pending`), which pass on every run of section 3. In `tb_fe_copy` the copy and fill mutants fail on the byte checks against upstream's arithmetic, the F6 mutants on the per-clock schedule or the image.

| Id | Mutant | Caught by (check, run seed) |
|---|---|---|
| m1 | F8 not read in the clock the change is first seen | `s_req` (seed 31) |
| m2 | one synchroniser flop on ret_tog | `s_req` (seed 31) |
| m3 | mwin one clock early (X+1 deferred) | `mwin` (seed 31) |
| m4 | mwin ends before M_fe | `mwin` (seed 31) |
| m5 | take compares a fourth return | `cp_cmp` (seed 31) |
| m6 | the merge applied one clock early (before FD) | `cp_apply` (seed 31) |
| m7 | release without cpu_ready | `state` (seed 31) |
| m8 | release outside rel_ok (D3) | `state` (seed 31) |
| m9 | call_tog flips without cpu_ready | `flip` (seed 31) |
| m10 | the payload captured at C, not L | `cp_cap` (seed 31) |
| m11 | DPC+ second call not posted at X | `state` (seed 31) |
| m12 | CDF second call not captured at M_fe | `cp_cap` (seed 31) |
| m13 | a CALLFN after X posted with the pre-merge payload | `cp_cap` (seed 32) |
| m14 | pend2 survives a reset | `reset` (seed 31) |
| m15 | call_tog flips in a reset clock | `reset` (seed 31) |
| m16 | idx not cleared for a second call | `s_req` (seed 31) |
| m17 | ring rotated at F1 | `cp_rot` (seed 31) |
| m18 | CDFJ+ entry without the T bit | `post` (seed 31) |
| m19 | CDFJ+ stack not taken | `post` (seed 31) |
| m20 | DPC+ entry without the T bit | `post` (seed 31) |
| m21 | pend_up never set | `pend_up` (seed 31) |
| m22 | pend_up cleared at X, not X+1 | `pend_up` (seed 31) |
| m23 | a CALLFN committed in REL is lost | `state` (seed 32) |
| m24 | hook mode reads the returns | `state` (seed 31) |
| m25 | F8 not shifted into the ring | `cp_shin` (seed 31) |
| m26 | DPC+ second call's payload not captured | `cp_cap` (seed 31) |
| m27 | a CALLFN taken while upstream's call is still pending | `pend2` (seed 10) |
| m28 | posted words one slot off | `s_req` (seed 31) |
| m29 | a CALLFN in REL released and posted at once | `state` (seed 32) |
| m30 | ret_seen not updated at X | `ev` (seed 31) |
| m31 | CDFJ+ returns not read | `state` (seed 8) |
| m32 | call_win ends before the merge | `call_win` (seed 31) |
| m33 | a DPC+ CALLFN in the X clock lost (design 6.1 as written) | `state` (seed 8) |
| k1 | F6 at the rise + 7 | `f6` (seed 31) |
| k2 | F6 on a falling reset too | `init_busy` (seed 31) |
| k3 | a rise during init accepted | `f6` (seed 31) |
| k4 | load_start does not stop F6's phases | `f6` (seed 32) |
| k5 | init_busy dips at L+1 | `init_busy` (seed 31) |
| k6 | init_busy not set at load_start | `init_busy` (seed 31) |
| k7 | CDFJ+ fill stops at 8 KB | `f6` (seed 33) |
| k8 | DPC+ copy source $0B00 | `f6` (seed 31) |
| k9 | F6 copy written one word late | `f6` (seed 31) |
| k10 | state RAM clear of 16 words | `f6` (seed 31) |
| k11 | fill does not wait for the last copy write | `f6` (seed 31) |
| k12 | no destination clamp | `engine` (seed 31) |
| k13 | no source bound | `engine` (seed 31) |
| k14 | the source bound applied to fills | `engine` (seed 31) |
| k15 | fill mask one byte too wide | `engine` (seed 31) |
| k16 | copy byte from the destination's lane | `engine` (seed 31) |
| k17 | copy uses the old word after a crossing | `engine` (seed 31) |
| k18 | copy uses fea_q of another A user | `engine` (seed 31) |
| k19 | a service taken while one runs | `svc_take` (seed 31) |
| k20 | arm_dma_busy falls outside rel_ok | `dma_busy` (seed 31) |
| k21 | arm_dma_busy ignores a deferred latch | `dma_busy` (seed 31) |
| k22 | DPC+ fill of 2 KB | `f6` (seed 31) |
| k23 | family latched at load_start | `init_busy` (seed 31) |
| k24 | CDFJ+ RAM size not latched | `f6` (seed 33) |
| k25 | F6 on the window's rise, not its fall | `f6` (seed 31) |
| k26 | fill writes byte 0 of the first word | `engine` (seed 31) |
| k27 | a service taken in the load_start clock | `svc_take` (seed 31) |
| k28 | load_start does not stop the engine | `engine` (seed 32) |
| k29 | F6 ends with the last copy write | `f6` (seed 31) |
| k30 | rst_quiet after 4 reset clocks | `rst_quiet` (seed 31) |
| k31 | F6 after a non-ARM load | `f6` (seed 31) |
| k32 | engine advances without its grant | `engine` (seed 31) |
| k33 | family not latched at load end | `f6` (seed 31) |

## 5. Area and timing

Each block alone with `sim/bupchip/quartus_probe/daria_fe_map.sh <block> --fit` (Quartus 21.1, 5CEBA4F23C8, the core's settings, every port a virtual pin, `clk_sys` 69.841 ns), run under `flock /tmp/daria_quartus.lock`, `db/` deleted by the script. The RTL probed is the RTL delivered (no RTL change after the probe).

| Block | ALMs placed − [B] (the 10.3 measure, L-4) | 10.3 guide | ALMs needed (with virtual I/O) | ALUTs | Registers | M10K | Worst setup slack |
|---|---|---|---|---|---|---|---|
| `daria_fe_call` | **65** | ≤ 45 | 145 | 85 | 22 | 0 | +65.9 ns |
| `daria_fe_copy` | **141** | ≤ 100 | 228 | 245 | 96 | 0 | +61.2 ns |

Both are over 10.3's guides (design 10.1 estimated 35-45 and 85-110). Under the owner's note of 10.3 (the gates are guides; a lever only if it keeps every exactness result or step 7 needs it) nothing was traded for area. Where the ALMs are:

- **Call.** The 32-bit post word `cl_wd` (F0, F1, `ring0` on `idx`, with `jplus`/`is_dpc` choosing constants or `cdfj_entry`/`cdfj_stack`) has eight inputs per bit, so about two 6-LUTs per bit: some 60 of the 85 ALUTs [E]. The FSM, `idx` and the synchroniser are the rest. Synthesis removes the taps no one reads (`cnum`, `pend_up` and its `xq`): 22 of the 31 registers in the source remain. Lever (not applied): registered one-hot word selects (5 flip-flops) would bring most bits to one LUT, about −10 ALMs [E]; in the whole `daria_fe` the word also meets `u_arb`'s S data mux, so the block-alone number is not additive anyway.
- **Copy.** 96 registers (the F6 counter and copy-write address, `src` 17, `dst` 13, `rem`, `val`, the load tracking). The ALUTs: the 32-bit R data mux (F6 word, the fill byte, the copy byte lane of `fea_q`), the 13-bit R and A address muxes, the `src`/`dst`/`rem` adders with their latch muxes, the F6 end compares and the fill mask. The run-time clamps (F4) cost the 13-bit `dst == $1C00` compare and the 17-bit `src` (the core saves its clamp arithmetic instead).
- Quartus warns 10036 only on the bench-only events (`ev_rmw_call`, `ev_ret_unasked`, `a_f6_live`: "assigned a value but never read").

## 6. Open issues and notes

**For the lead (design text).**

1. **Fold C-1 … C-3 into design 6.1/6.4.** As written, 6.1 loses a CALLFN committed in REL, or in the DPC+ X clock, and leaves `pend2` set, so the next call is followed by a phantom one; and 6.4 would post a CALLFN committed after X with the pre-merge payload. The RTL follows upstream's semantics instead (section 1.3), and the bench's upstream model (one post per upstream accept, payloads from upstream's accept edge) checks it.
2. **Widen 9.5's `rmw_call`.** Condition unchanged ("a CALLFN while `call_busy`"); what may differ, besides the stall shape and a tick exactly on M: **the CDF call-2 seeds when the second CALLFN commits after X** (posted from REL, captured at M_fe+2; with the hook at M+2) and a tick falls between upstream's accept (C2+1) and that capture. Mode A (value) and B. It needs an RMW whose second write commits after X: a very short call with stretched phases, or a pause in that write's phase 1. The bench makes the case mostly with its mode-A stall and `+gap=0` streams (`late_pend2`, 1,138 in the suite), and checks such a post against DARIA's own capture (then resynchronises D to U), not against upstream's.
3. **A third CALLFN inside (M, M_fe] of a CDF RMW** (upstream queues it behind call 2; the one-deep `pend2`, still holding call 2, drops it). Unreachable from real 6507 code: the stall holds the 6507 from the RMW's last write until call 2's release (hardware, mode B), or until upstream's call-2 busy falls (mode A; its one-clock dip at X cannot complete an instruction). Only the bench's `+gap=0` stream (stores with no opcode or operand cycles) makes it; the bench's upstream model drops it too and counts `callfn_dropped_m_mfe` (758 in the suite, almost all in `c_dense`). No class needed; a note in 6.4 would do.
4. **Area** over the 10.3 guides (section 5): call 65 (≤ 45), copy 141 (≤ 100).

**For lane D (`u_arb`).** `cp_req` is F6's whenever `f6_act` (the engine never runs then: `svc_take` needs `!f6_act`, and both F6 triggers come with `run` cleared by `load_start` or `cart_reset`). The engine's and the call port's requests are raw (not gated by `guard_on`). On hardware the engine should never request R while `guard_on`: it runs only between a service store and its release, the stall holds the next instruction, no RMW value pair puts a CALLFN after a CALLFUNCTION 1/2, and DARIA's CPU is parked then (no call window, `cpu_ready` high). So `a_guard_wr` should see nothing from this block; the unit bench drives `guard_on` at random only to prove the engine waits under it.

**For lane E (stage 1, `fe_taps.svh`).**

- Taps as built: `u_call.st` (one-hot, `CS_*`), `.cnum` (flips of `call_tog`), `.pend2`, `.pend_up`, `.ret_seen`, `.call_busy`, `.ev_rmw_call` (= `callfn & call_busy`, `rmw_call`'s condition), `.ev_ret_unasked`; `u_copy.f6_act`, `.f6_ph` (one-hot while `f6_act`, else 0, `F6_*`), `.run`, `.fill`, `.src`, `.dst`, `.rem` (counts down from the requested p3: the bench forms upstream's clamped count by `min()`), `.val`, `.init_busy`, `.dma_busy`, `.a_f6_live`. All registers except the two events and `a_f6_live`.
- `pend_up` is upstream's `call_pending` except in the accept clock of a call upstream accepts at once (a fresh call, or one committed after its X): there `call_pending` is high for one clock and `pend_up` is not.
- `svc_take` is upstream's service accept (C+1) when the engine is idle; a second service waits for the engine (`svc_queued_rmw`).

**Shared infrastructure (read-only to this lane).**

- `run_unit.sh` uses one `WORK` for every lane: a run of all benches (no names) by one lane rebuilds and overwrites another lane's `obj_*` and logs while it may be running them. `tb_fe_call_suite.sh` therefore uses its own `WORK` (`runs_C/work`).
- Lane B's note stands: after a failed build `run_unit.sh` leaves the previous log in place; the suite deletes the log before each run.
- The call bench's random stream is shared by several `always` blocks, so a different build (`POISON=1`) orders them differently and gives a different, equally valid run (the counts in section 3 differ between the two columns for that reason). The copy bench's runs are identical both ways.

**Bench fixes made while resuming** (the previous agent's benches, before the runs of section 3): the stand-in's readout now waits out a reset like its run phase does (a `returned` inside `daria_call`'s reset raised no `ret_tog`, and the bench then took the next real return for a stale one); the epoch's scheme change moved into the reset's second clock (it came one clock before the reset, which a load never does); `top.sv`'s `reset_hold` tail is at least one clock (the bench's could be 0, giving a one-clock dip of `cart_reset` right after a rise, which the real reset never has); the end-of-load compare stops generating services first (a service taken during the compare was in the reference but not yet in RAM); timeouts on every wait loop. Added: the accept balance, the `rst_quiet` check, the `load_start`-in-the-take-clock case, the `run`-after-`load_start` check, the knobs `+k_short`, `+k_cf`, `+k_rmw`, `+k_takeab` and the suite's dense and short-call runs.

**Port requests.** None.

## 7. Reproducing

```sh
sim/bupchip/daria/fe_unit/run_unit.sh call copy                    # seed 1: call 1 M clk_sys (~2 s), copy 30 loads (~8 s)
POISON=1 sim/bupchip/daria/fe_unit/run_unit.sh call copy
sim/bupchip/daria/fe_unit/run_unit.sh call +seed=2 +stall_up=1 +gap=0 +ready=1   # mode A's stall
sim/bupchip/daria/fe_unit/tb_fe_call_suite.sh                      # the 15 runs of section 3.1, ~5 min
POISON=1 sim/bupchip/daria/fe_unit/tb_fe_call_suite.sh
for s in $(seq 11 30); do                                          # section 3.2 (add POISON=1 for the other half)
  sim/bupchip/daria/fe_unit/run_unit.sh call +seed=$s +pg_seed=$s +clocks=3000000 +epoch=60000
  sim/bupchip/daria/fe_unit/run_unit.sh copy +seed=$s +pg_seed=$s +loads=20
done
sim/bupchip/daria/fe_unit/tb_fe_call_mut.sh                        # section 4, about 20 min at JOBS=2
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_call --fit
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_copy --fit
```

Logs: `sim/work/bupchip/daria/fe_unit/runs_C/` (`suite/`, `suite_poison/`, `sweep_p0/`, `sweep_p1/`, `mut_final.log`).
