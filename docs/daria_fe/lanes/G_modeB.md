# Lane G: mode B of the shadow, daria_fe with DARIA's own CPU (DARIA step 6, design 12.2 step 8)

This is the report for `docs/daria_fe/design.md` 12.2 step 8: mode B of the stage-1 shadow (`docs/daria_fe/spec/bench.md` 6.3, 6.4, 7.1), with `clk_d` on the PLL's lattice and the `+d_ofs` sweep for the shared-edge guard (design 3.5, 8).

**Status.** Done, and revised after the lane's verification (section 11 lists each finding and its fix). Mode B is built behind `MODE_B=1` and **passes design 12.2 step 8's gate in all nine game runs** (one image per scheme at `+d_ofs=0`, SF2fix and Galagon at 8,730 and 17,460; 300 frames each), all on the final binary:

- `det_bad` 0. The guard locks at all three offsets, as design 8 says it must, at `clk_sys` edge 16, 18 and 14, and never unlocks. Those are the edges a zero-delay model of design 8.1 predicts, and the bench now checks each lock against that model (`lock_edge_bad`), so design 8.3's 12-match threshold is pinned.
- `coll_d_same`, `coll_d_ld_same` and `coll_ww_same` are 0. No `daria_fe` write, and no consumed read, lands on a shared edge while `guard_on` or while DARIA runs a call.
- Every mode-A must-be-0 check that applies is 0. DARIA's 4,620 calls match upstream's call by call.
- **Every audio refresh is compared by value** (new): upstream's n-th against `daria_fe`'s n-th, read by read (word and value) and in AMPLITUDE and the sum at its end. The `call_amp` and `guard_shift` masks now only stop the every-clock compare. A pair is excused only by another class or by a word an ARM wrote in the call's flight whose two reads differ, and even then `daria_fe`'s value must be one its RAM held in the flight. `refresh_bad`, `refresh_count_bad` and `deposit_bad` (a resync overwriting a difference nothing excuses) are 0 in every game run, over 902,767 refresh pairs, 39,267 of them during a call in flight.
- **The CDF merge rule now demands upstream's frequencies** (new): after each merge window `daria_fe`'s three frequencies must equal upstream's, and the counters may differ only by bench.md 7.6's k > 0 ticks, with the step from upstream's returned frequency and take. Before, a wrong returned frequency passed as `merge_race`.

Seven self-tests each make the run fail by their own check, four of them new: a `coll_d_same` and a `coll_d_ld_same`/`coll_ww_same` positive control, a wrong returned frequency word, and an undefined read (the poisoned RAM's $A5A5A5A5). Three faults the verification put in a scratch copy of `daria_fe`'s RTL, which the bench used to pass, now fail it (section 6.2). The existing builds are unchanged: their preprocessed sources are identical to HEAD's for nine configurations. No RTL issue was found.

Nothing was committed. No RTL was changed (`src/fpga/core/bupchip/daria_fe*.sv` and `src/fpga/mister/rtl/` untouched; the faults of 6.2 were in a copy in the session's scratchpad). Game-derived outputs are under `sim/work/bupchip/daria/runs/` of this worktree (`modeB/`, `reg/`).

---

## 1. What was built

| File | Change |
|---|---|
| `sim/bupchip/daria/run_daria.sh` | `MODE_B=1` (:31-46, :126-129): sets `SHADOW=1 FE=1` itself, refuses `WRAPPER=1` and `FE_STAGE0=1`, adds `-DFE_MODE_B`; object directory `obj_shadow<WIN_KB>_fe_modeB` (`_fe_modeB_poison` with `FE_POISON=1`), runs in `runs/shadow<WIN_KB>_fe_modeB/` |
| `sim/bupchip/daria/run_all.sh` | The same prefix for `MODE_B=1` (:10, :17-19, :26) |
| `sim/bupchip/daria/daria_shadow.svh` | Every change is inside `` `ifdef FE_MODE_B `` / `` `ifndef FE_MODE_B ``, with the step-5 text verbatim in the other branch. Header (:43-72). `clk_d` on the lattice and `+d_ofs`; the self-test clock for `+mb_inj=2` (:85-117). DARIA's reset follows the console reset (:201-209). `dmem`'s front-end ports are `u_fe`'s, with the front-end ROM capture as the wrapper's (:255-292). The window load and `daria_ready` (:308-335). The step-5 poster with its snapshot copy (:414-469) and its `clk_d` access logger (:474-487) are not built in mode B. The cart RAM coincidences and the 69.84 ns window on `daria_fe`'s consumed reads, the positive controls of self-tests 4 and 5, and the values each word held during a call's flight (`mb_hist`, for the refresh compare) (:515-627). DARIA's record of each call, K1d and the compare trigger (:629-718). `shadow_compare` reads `` `D_RES``/`` `D_ACC``/`` `D_CYC``/`` `D_E2E`` (:719-729), which expand to the step-5 names outside mode B. The final lines (:801-809) |
| `sim/bupchip/daria/fe_shadow.svh` | Every change is inside `` `ifdef FE_MODE_B `` (or the `else` of one). Header (:47-119). `` `FE_MEM`` (:1025-1029). `cpu_ready` = `daria_ready` (:1061-1068); hook off (:1085-1089); mode A's `ret_tog` emulation not built, its completion predictor kept (:1114-1128). `u_fe` on `dmem`'s wires with `clk_arm` = `clk_d`; `fe_mem` is mode A's only (:1152-1205). The hold adds `u_fe.arm_call_busy` (:1236-1242), and H1 follows (:1840-1845). The counters (:1276-1288). Mode B's merge-window state and `mb_race_ok`, the lock model `mb_lock_model`, the refresh compare (`mb_val_ok`, `mb_ref_close`) (:1356-1574). Masks other than `call_amp`/`guard_shift` noted (:1583-1588). `det_lock_a` mode A only (:1811-1813). The detector, guard, lock-edge and port-B checks, ahead of A1 (:1859-1928). The merge rule at the first compare after a window (:1939-1950, :1963-1965). The merge window, with upstream's take at U (:2037-2114). `call_amp` and the busy falls (:2151-2180). Each refresh's bookkeeping: its reads, flight and class flags (:2232-2294). K2 waits for both calls (:2450-2458). At each falling edge before the resync: the refreshes closed and compared, `refresh_count_bad`, `deposit_bad` (:2744-2794). Self-tests 6 and 7 (:2804-2835). Report (:2896-2898, :2917-2938); names and must-be-0 flags (:2987-3001, :3019-3027); the banner and the self-tests' forces (:3039-3066) |
| `sim/bupchip/daria/fe_taps.svh` | The memory taps read `` `FE_MEM`` (`fe_mem` in mode A, `dmem` in mode B; :23-24, :40-55) |
| `docs/daria_fe/lanes/G_modeB.md` | This report |

**Use.**

```sh
MODE_B=1 WIN_KB=64 DTRACE=0 sim/bupchip/daria/run_daria.sh ROM.bin +frames=300 +snap=0 +fire_at=40 +play_at=70 +d_ofs=0
#   +d_ofs=PS      clk_d phase: 0, 8730, 17460 (the PLL's lattice); 13095 is step 5's phase (no edge shared)
#   +mb_inj=K      self-test K (1 to 7, section 6; off by default); +mb_det_ofs=PS for K = 2 (default 8730)
MODE_B=1 FE_POISON=1 WIN_KB=64 ...       # with the poisoned daria_ram (mixed-port same-step reads give $A5)
```

The final lines of `run.log` in mode B: step 5's `DARIA shadow:` (unchanged fields), `DARIA collisions:` (mode B form), `DARIA mode B:`, the stage-1 `FE ...` lines, then `FE mode B:`, `FE mode B port B:`, `FE mode B calls:`, `FE mode B refreshes:` and `MODE B result: PASS|FAIL`. Before them, `FE mode B refresh excused` (the first five pairs excused whose values differ) and `FE mode B resync ... overwrites` (the first five resyncs that overwrote a difference, with what excused it). `fe.csv` gets one column per mode-B counter at its end.

## 2. How mode B differs from mode A

| | Mode A (E1) | Mode B (this lane) |
|---|---|---|
| Who runs the calls for `daria_fe` | Upstream's ARM; the bench writes its return words into `fe_mem` and flips `ret_tog` per call number | DARIA's CPU (`dcpu`) through `dcall`; `u_fe` posts F0-F7 through state RAM port B and flips `call_tog` |
| `daria_fe`'s memories | Its own `fe_mem`; cart RAM port A mirrors upstream's CPU writes on upstream's `clk_arm` | DARIA's `dmem`: the front-end ROM (captured from the download as the wrapper does), cart RAM port B, state RAM port B. Port A is DARIA's CPU and `dcall`, on `clk_d` |
| `u_fe.clk_arm` | The bench's 5 × `clk_sys`: the detector never locks (`det_lock_a`) | DARIA's `clk_d`, on the lattice: the detector locks and the guard acts |
| `clk_d` | step 5's 4.365 ns offset, never a shared edge | Starts high, toggles every 13,095 ps from `+d_ofs`: rises at `d_ofs` + 26,190 n. 0, 8,730, 17,460 put the shared edge on `clk_sys` edges k ≡ 1, 0, 2 (mod 3) (bench.md 6.3) |
| `cpu_ready` | upstream's `arm_online_sync2 && shadow_ready_sync2 && !effective_reset` | `daria_ready`: DARIA's `parked` through two `clk_sys` flops, as `bupchip_pocket.sv` makes it (`img_ready` is 1 in this bench) |
| DARIA's reset | released once at `running`, never again | the console reset (`daria_mreset`, design 6.5): held while `effective_reset` is high |
| Step 5's poster and per-call RAM snapshot copy | (not built in mode A) | Left out (bench.md 7.1). `up_snap` is still taken at upstream's call start, for K1d |
| Hold of the 6507 | forced `arm_call_stall` for `u_fe.arm_dma_busy` | the same force, plus `u_fe.arm_call_busy` (bench.md 7.1): the 6507 waits for whichever call ends last |
| The merge hook | `+fe_merge_hook=1` available | off: `daria_fe` merges DARIA's returns |

**Comparisons that change, and why** (none is dropped silently; each is listed with its counter):

| Comparison | Mode B | Why |
|---|---|---|
| R1 (payload at upstream's accept against F0-F7 posted) | unchanged | `daria_fe` captures the ring at L = C+1, upstream's accept edge, whoever runs the call |
| Return words, merge | The CDF merge window runs from the first of U (upstream's M, `call_done`) and D (`daria_fe`'s X+1, `u_call.xq`) to after both U and M_fe. At the first compare after it, `daria_fe`'s three frequencies must equal upstream's. The counters may then differ only by bench.md 7.6's rule, and only when k > 0: per voice, upstream − `daria_fe` = s · k · (take ? f_ret : f_ret − f_old), k the ticks in (min(U,D), max(U,D)], s = +1 when U < D, f_ret upstream's returned frequency and take upstream's own (its return ≠ its seed, taken at U). That is counted `merge_race` and resynced. Anything else, any difference with k = 0 included, is `audio_bad` | The two ARMs return at different times, so the two merges are on different edges (bench.md question 7). D is X+1, not M_fe, because `daria_fe` defers the ticks of (X+1, M_fe] and adds them with the returned frequency (design 5.6): its counters are those of a merge at X+1. With k = 0 both merges leave the same state (7.6). The step comes from upstream, not from `daria_fe`'s own registers, so that a wrong returned frequency cannot explain itself |
| `merge_late` | M_fe − X = 7 (design 6.3), `daria_fe`'s own timing | M_fe − M = 6 needs mode A's `ret_tog`, which follows upstream's X |
| `ret_late` | not applicable (0) | there is no emulated `ret_tog` |
| A1 every clock, the replica (state, grant, address, AMPLITUDE, the sum, the digital registers) | masked, counted and resynced while a refresh runs during a call in flight on either side (`call_amp`), and from an audio grant held for phase B by the guard (`guard_shift`) until the next quiet point. Counters and frequencies (cf) and the tick group stay compared every clock outside the merge window | In a call each ARM writes its own cart RAM at its own pace, so a refresh then may read words that differ; and the guard moves `daria_fe`'s grants to phase B (design 3.5, 9.5 "hardware and mode B only"). These masks move timing only: the values are compared by the next row |
| Every refresh, by value (new) | Upstream's refreshes and `daria_fe`'s are paired in order. Each pair must read the same words with the same values, read by read, and end with the same AMPLITUDE and sum (`refresh_bad`). A pair is excused, and counted, in two cases only. One: either refresh ran under the mask of a class other than `call_amp` and `guard_shift`. Two: a read whose two values differ, of a word either ARM wrote since the call's flight began (`up_wt`, `d_wt`), with `daria_fe`'s value one its RAM held in the flight (`mb_hist`: the word as the flight found it, or after any store to it there); the rest of that pair may then follow the value. Under any class, a read in a flight of a word DARIA stored there must still return a value it held. At a quiet point both sides must have run as many refreshes (`refresh_count_bad`), and a resync that overwrites any difference, with no excused pair and no other class since the last resync, is `deposit_bad` | Two ARMs writing one word at different times is the only cause of a value difference that `call_amp` stands for; a fault in a grant, an address, a lane or a read is not one. The RAM-history rule is the value check of the coincidences: a read that meets a store of its word on one edge is undefined on the M10K, and the poisoned model returns $A5A5A5A5 for it (self-test 7) |
| K2 (whole cart RAM each frame) | also waits until neither side has a call in flight | mid-call the two RAMs differ by design (two CPUs). K1 (at upstream's call start) is unchanged: nothing of DARIA's call has run there |
| K1d (new) | DARIA's cart RAM at each `call_go` against `up_snap`, upstream's at the start of the same call | DARIA's input is `daria_fe`'s RAM, no longer a copy of upstream's |
| DARIA's calls (step 5) | every call compared in order once both have returned: FIQ r8-r13, every RAM write, every MMIO access (T1TC within `MMIO_TOL`) | as step 5. `daria.csv`'s `e2e_sys` is now `daria_fe`'s C (busy rise) to X+1 |
| `det_lock_a` | mode A only | the detector must lock in mode B |
| Release-window duplicate commit (design 6.3, `release_dup`) | not measurable here | the stall on the bus is still top.sv's (forced), so both front ends see one bus; `daria_fe`'s own release rule is checked by `tb_fe_call`/`tb_fe_seq` |
| Digital samples beyond 32 KB | as mode A (emulated port, `+fe_slat`) | the real requester is in the wrapper (step 7) |

## 3. Where the guard should lock (design 8)

Design 8.1/8.3: with `clk_sys` = VCO/48 and `clk_arm` = VCO/18 on one lattice, each 144-VCO frame has one shared edge, which catches two `pd_tog` toggles; the other two `clk_sys` edges catch three. `pd_same` is therefore 1 exactly in the clock after the shared edge, a period-3 pattern, and the flywheel locks after 13 consecutive matches, "within 3 + 12 clocks of start" (8.3), bound 24 (8.4). Where no edge is shared it must not lock (5 ×, ÷19).

In the bench (zero delay) a toggle launched on the shared edge is never caught on it (`pd_rx <= pd_tog` reads the value before the edge's update), and one launched 8.73 ns earlier always is: the bench's equivalent of the 1/6 ns SDC pair. Edges are numbered from time 0: `clk_sys` edge n rises at 34,920 + 69,840 (n − 1) ps (k = n − 1 below). So:

| `+d_ofs` | `clk_d` rises at | Shared `clk_sys` edges | Should lock? | Lock edge: zero-delay model of 8.1 (with the time-0 edge; without it) | Measured |
|---|---|---|---|---|---|
| 0 | 26,190 m | k ≡ 1 (mod 3): n = 2, 5, 8, … (104,760, 314,280, … ps) | **yes** (÷48/÷18 on the lattice); `phb_next` in the clock after each shared edge | 16 (16) | 16 (all 5 images) |
| 8,730 | 8,730 + 26,190 m | k ≡ 0: n = 1, 4, 7, … (34,920, 244,440, … ps) | **yes** | 18 (15) | 18 (both images) |
| 17,460 | 17,460 + 26,190 m | k ≡ 2: n = 3, 6, 9, … (174,600, … ps) | **yes** | 14 (17) | 14 (both images) |
| 13,095 (step 5's phase) | 13,095 + 26,190 m | none | not a Pocket clock (the PLL puts both on one lattice); 8.3 says nothing | 18 (15): in zero delay the toggle counts per `clk_sys` are still 3, 3, 2, period 3, so the flywheel locks on the two-toggle clock, and every predicted shared edge is wrong (`det_bad` one clock in three) | 18, then `det_bad` one clock in three (Mappy, section 8) |

So the guard must lock at all three lattice offsets, by edge 24 (8.4), and the bench requires it (`lock_late`). It also requires the lock at the edge the zero-delay model predicts for the detector's own clock (`lock_edge_bad`; `fe_shadow.svh`'s `mb_lock_model`, the model below written into the bench, with 8.1's lock after the 12 matches that follow the first): a flywheel with another threshold, or a receiver that catches the toggles differently, locks at another edge (6.2: a threshold of 15 locks at edge 21 at 8,730, and fails). The model's edge is printed on the `FE mode B:` line.

**The time-0 edge.** `u_fe`'s `clk_arm` is the bench's wire `fb_clk_arm` (`clk_d`, or the `+mb_inj=2` copy; daria_shadow.svh:112). `clk_d` starts high, and Verilator 5.040 sees a rising edge at time 0 on a clock that reaches an `always_ff` through such a continuous assign, though not on the variable itself. A 20-line test (Verilator 5.040, `--binary --timing --x-assign fast --x-initial fast` as run_daria.sh; not kept) shows it: through the wire, the `pd_tog` analogue reads 1 at 1 ps; on `clk_d` directly, 0. So `pd_tog` starts with one extra toggle, as if it powered up at 1. That moves the first lock by up to 3 clocks (15 → 18 at 8,730, 17 → 14 at 17,460) and changes nothing after it. On the Pocket the first lock depends on when the PLL starts both counters anyway, and 8.3's "3 + 12 clocks" covers any start. DARIA's own `clk_d` flops (on `clk_d` directly) see no such edge. The model restates 8.1's receiver and flywheel at these clock times, with the time-0 edge (a 36-line Python script first, now `mb_lock_model` in the bench); the measured edges match it exactly in every run, self-test 2 included (its detector clock is `clk_d` + 8,730 ps, so the model gives 18 there).

The run's start is time 0: `daria_fe_guard` has no reset (power-up values), and `clk_d` runs from 0 (`d_ofs` ≤ 17.46 ns of idle high before its first toggle).


## 4. The checks

All in the `clk_sys` block of the stage-1 shadow, reading pre-edge values, from time 0 (the refresh compare, `refresh_count_bad` and `deposit_bad` at the falling edge, before the resync there); each must-be-0 counter is in `FE bad:` and `fe.csv` (the coincidence counts come from `daria_shadow.svh`'s `clk_d`/`clk_sys` blocks and are folded in as they arrive).

| Check | Rule | Counter |
|---|---|---|
| Detector (8.4 `det_bad`) | after lock, at every `clk_sys` edge: `pd_same` (the clock just ended) == "the last edge was shared", the edge arithmetic `(t − d_ofs) % 26,190 == 0` of the real `clk_d` | `det_bad` |
| Flywheel | after lock, `phb_next` == the same | `phb_bad` |
| Lock time (8.4) | locked by `clk_sys` edge 24 from time 0 | `lock_late`; the lock edge is printed |
| Lock edge (new) | locked at the edge the zero-delay model of 8.1 gives for the detector's clock (section 3) | `lock_edge_bad` |
| No unlock | `ev_unlock` never fires (no phase move in the bench) | `det_unlock` |
| Guard window tap | `guard_on` == `locked & (call_win \| !cpu_ready)` (3.5), formed by the bench | `gwin_bad` |
| Port B on a shared edge, in the guard's window | a non-F6 port-B write, or a port-B read whose q `u_fe` consumes (the clock before `crb_use`: the core's fixed read with `cr_fix_use`, the P32 read, the audio), registered on a shared edge while the window is open | `wr_shared_guard`, `rd_shared_guard` |
| Port B on a shared edge, while DARIA runs | the same while DARIA's CPU is between `call_go` and `returned` (the bench's own view, not the guard's) | `wr_shared_daria`, `rd_shared_daria` |
| Coincidences (bench.md 6.4), exact to the ps | a DARIA store and a consumed `daria_fe` read of one word at one time step (`coll_d_same`); a `daria_fe` write and a DARIA load registered at one time step (`coll_d_ld_same`, the reverse race); two writes (`coll_ww_same`) | `coll_d_same`, `coll_d_ld_same`, `coll_ww_same` |
| K1d | DARIA's cart RAM at `call_go` == upstream's at its call start | `ram_dcall_bad` |
| The merge (changed) | at the first compare after a CDF merge window: the frequencies equal upstream's; counters equal, or (k > 0) different by bench.md 7.6's k ticks of upstream's step (section 2) | `audio_bad` (`merge_race` counted when the rule holds) |
| Every refresh by value (new) | pairs in order: the same words read with the same values, and the same AMPLITUDE and sum at the end, unless excused (section 2); a read in a flight of a word DARIA stored there returns a value it held, whatever the class | `refresh_bad` |
| The refresh count (new) | at a quiet point, no refresh left unpaired on either side, unless another class came since the last resync | `refresh_count_bad` |
| What a resync overwrites (new) | at a resync, A1's replica (and with cf the counters and frequencies) equal on both sides, unless an excused pair or another class came since the last resync | `deposit_bad` |
| DARIA's calls (step 5) | each call: FIQ r8-r13, RAM writes, MMIO | `daria_call_bad` (= `DARIA shadow:`'s differ) |
| Mode A's must-be-0 checks | E1's 46 `FE bad:` counters less `det_lock_a`, i.e. 45 (L1, C1-C4, R1-R3, I1/I2, K1/K2, T1/T2/T4/T5, A1-A3, O1, H1 with `u_fe.arm_call_busy`, W1, the RTL assertions, `merge_late` in its mode-B form, `dma_cover`, `mask_stuck`, …) | as E1 |

Counted (information): `guard_shift` (clocks an audio read waits for phase B), `call_amp` (refreshes run during a call in flight), `merge_race`, the shares of port-B writes/reads and of DARIA's stores/loads on shared edges, the `guard_on` share, D − U and the busy-fall offsets; the refresh pairs compared (`refresh_pairs`, `refresh_pairs_fl` in a flight), excused by an ARM-written word (`refresh_x_arm`) or by another class (`refresh_x_class`), the excused ones whose values differ (`refresh_x_differ`), refreshes left unpaired under another class (`refresh_unpaired`) and resyncs that overwrote an excused difference (`deposit_differ`).


## 5. Results

Nine game runs: `MODE_B=1 WIN_KB=64 DTRACE=0 NAME=modeB/d<d_ofs>/<image>`, `+frames=300 +snap=0 +fire_at=40 +play_at=70 +d_ofs=<d_ofs>`, on the final binary (`sim/work/bupchip/daria/obj_shadow64_fe_modeB`, md5 `36607870…`; `_poison` `d04339d4…`), built once from the final sources before every run of this report. They ran up to four at once once the mode-A batch had finished (23-25 min each). Run directories: `runs/modeB/d0/`, `d8730/`, `d17460/` (`run.log`, `fe.csv`, `daria.csv`, `fe_err.txt`, …). The DUT and `daria_fe` do the same as in the lane's first runs, clock for clock: every count of 5.2-5.5 below that the first runs had is the same.

### 5.1 The gate (design 12.2 step 8)

| Run | Scheme | `+d_ofs` | Frames | Lock edge (model; bound 24) | det_bad | phb_bad | coll_d_same | coll_d_ld_same | coll_ww_same | wr_shared_guard | rd_shared_guard | refresh_bad / refresh_count_bad / deposit_bad | Mode-A must-be-0 (FE bad less mode B's) | DARIA calls compared / differ | Result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | DPC+ rev 0 | 0 | 300 | 16 (16) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 525 / 0 | **PASS** |
| Dino-Eggs | DPC+ rev 1 | 0 | 300 | 16 (16) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 49 / 0 | **PASS** |
| draconian RC8 | CDF1 | 0 | 300 | 16 (16) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 600 / 0 | **PASS** |
| Galagon | CDFJ | 0 | 300 | 16 (16) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 599 / 0 | **PASS** |
| Elevator-Agent | CDFJ+ | 0 | 300 | 16 (16) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 599 / 0 | **PASS** |
| SF2fix_NTSC | DPC+ rev 0 | 8,730 | 300 | 18 (18) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 525 / 0 | **PASS** |
| Galagon | CDFJ | 8,730 | 300 | 18 (18) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 599 / 0 | **PASS** |
| SF2fix_NTSC | DPC+ rev 0 | 17,460 | 300 | 14 (14) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 525 / 0 | **PASS** |
| Galagon | CDFJ | 17,460 | 300 | 14 (14) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 / 0 | 0 (45 counters) | 599 / 0 | **PASS** |

Every gate item holds at every offset:

| Gate item | `+d_ofs` 0 (5 images) | 8,730 (SF2fix, Galagon) | 17,460 (SF2fix, Galagon) |
|---|---|---|---|
| `det_bad` 0 (and `phb_bad`, `det_unlock`, `gwin_bad` 0) | yes | yes | yes |
| Locks where it should, within 24 clocks, at the model's edge: all three offsets should (section 3); `lock_late` and `lock_edge_bad` 0 | 16 at every image; model 16 | 18; model 18 | 14; model 14 |
| `coll_d_same` 0, `coll_d_ld_same` 0 (and `coll_ww_same` 0) | yes | yes | yes |
| No front-end write on a shared edge while `guard_on` (`wr_shared_guard`; also `a_guard_wr`, and no write or consumed read on a shared edge in the window or while DARIA runs) | 0 | 0 | 0 |
| Every mode-A must-be-0 check that applies (45; `det_lock_a` is mode A's) | 0 | 0 | 0 |
| Every refresh by value, and every resync (`refresh_bad`, `refresh_count_bad`, `deposit_bad`) | 0 | 0 | 0 |
| DARIA's calls match upstream's call by call (FIQ r8-r13, every RAM write, every MMIO access), and K1d | 2,372 calls, 0 differ, 0 skipped | 1,124, 0 | 1,124, 0 |

Comparisons that mode B's timing makes inapplicable or changes are listed with their reasons in section 2 (the CDF merge rule, `merge_late`'s form, `ret_late`, A1's `call_amp` and `guard_shift` masks, K2's wait, `release_dup`); none is dropped silently, and each mask or class is counted below. The `FE latency:` line's two mode-A histograms do not apply in mode B (section 10).

### 5.2 Every refresh by value

| Run | `+d_ofs` | Refresh pairs compared by value | in a call's flight | excused: an ARM-written word / another class | excused that differ | refresh_bad | refresh_count_bad (unpaired under a class) | resyncs overwriting a difference (excused) | deposit_bad | A1 masked clocks (longest) |
|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | 0 | 99,877 | 4,278 | 0 / 0 | 0 | 0 | 0 (0) | 0 | 0 | 36,399 (11) |
| Dino-Eggs | 0 | 99,931 | 150 | 0 / 0 | 0 | 0 | 0 (0) | 0 | 0 | 1,357 (10) |
| draconian RC8 | 0 | 99,846 | 4,407 | 2 / 510 | 0 | 0 | 0 (0) | 0 | 0 | 272,259 (3,058) |
| Galagon | 0 | 100,841 | 4,845 | 246 / 667 | 115 | 0 | 0 (0) | 83 | 0 | 431,574 (1,960) |
| Elevator-Agent | 0 | 100,836 | 7,341 | 0 / 1,307 | 0 | 0 | 0 (0) | 0 | 0 | 911,830 (3,428) |
| SF2fix_NTSC | 8,730 | 99,877 | 4,278 | 0 / 0 | 0 | 0 | 0 (0) | 0 | 0 | 36,349 (11) |
| Galagon | 8,730 | 100,841 | 4,845 | 246 / 667 | 115 | 0 | 0 (0) | 83 | 0 | 432,970 (1,960) |
| SF2fix_NTSC | 17,460 | 99,877 | 4,278 | 0 / 0 | 0 | 0 | 0 (0) | 0 | 0 | 36,392 (11) |
| Galagon | 17,460 | 100,841 | 4,845 | 247 / 667 | 115 | 0 | 0 (0) | 83 | 0 | 432,347 (1,960) |

902,767 refresh pairs over the nine runs, 39,267 of them during a call in flight (`call_amp`'s refreshes); 741 excused by a word an ARM wrote in the flight, 3,818 by another class (almost all `merge_amp`: CDF refreshes dispatched in a merge window), and 345 of the excused differ in AMPLITUDE or the sum. "Resyncs overwriting a difference" are the resyncs after those, each excused by the pair or the class before it. The masked clocks are A1's every-clock compare, which these masks stop and the compare by value replaces (section 8, "What the masks cost").

### 5.3 The detector and the guard

| Run | Scheme | `+d_ofs` | Shared class (k mod 3) | Locked at edge (model; lock_edge_bad) | Locked clocks | `guard_on` | Unlocks | det_bad | phb_bad | gwin_bad | guard_shift clocks |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | DPC+ rev 0 | 0 | 1 | 16 (16; 0) | 71,586,329 of 71,586,345 | 3.69% | 0 | 0 | 0 | 0 | 10,737 |
| Dino-Eggs | DPC+ rev 1 | 0 | 1 | 16 (16; 0) | 71,625,317 of 71,625,333 | 0.26% | 0 | 0 | 0 | 0 | 457 |
| draconian RC8 | CDF1 | 0 | 1 | 16 (16; 0) | 71,562,689 of 71,562,705 | 4.01% | 0 | 0 | 0 | 0 | 3,889 |
| Galagon | CDFJ | 0 | 1 | 16 (16; 0) | 72,274,589 of 72,274,605 | 4.23% | 0 | 0 | 0 | 0 | 37,456 |
| Elevator-Agent | CDFJ+ | 0 | 1 | 16 (16; 0) | 72,355,205 of 72,355,221 | 6.19% | 0 | 0 | 0 | 0 | 54,207 |
| SF2fix_NTSC | DPC+ rev 0 | 8,730 | 0 | 18 (18; 0) | 71,586,327 of 71,586,345 | 3.69% | 0 | 0 | 0 | 0 | 10,687 |
| Galagon | CDFJ | 8,730 | 0 | 18 (18; 0) | 72,274,587 of 72,274,605 | 4.23% | 0 | 0 | 0 | 0 | 37,398 |
| SF2fix_NTSC | DPC+ rev 0 | 17,460 | 2 | 14 (14; 0) | 71,586,331 of 71,586,345 | 3.69% | 0 | 0 | 0 | 0 | 10,730 |
| Galagon | CDFJ | 17,460 | 2 | 14 (14; 0) | 72,274,591 of 72,274,605 | 4.23% | 0 | 0 | 0 | 0 | 37,457 |

### 5.4 Port B on shared edges, and the coincidences

| Run | `+d_ofs` | daria_fe writes: all / on a shared edge / of them in the window / while DARIA runs | consumed reads: all / shared / window / DARIA | coll_d_same | coll_d_ld_same | coll_ww_same | DARIA stores (on a shared edge) | DARIA cart RAM loads (on a shared edge) | Within 69.84 ns: upstream / DARIA |
|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | 0 | 8,216 / 6,851 / 0 / 0 | 701,035 / 97,881 / 0 / 0 | 0 | 0 | 0 | 524,261 (65,605) | 785,189 (98,642) | 0 / 0 |
| Dino-Eggs | 0 | 7,288 / 5,918 / 0 / 0 | 362,256 / 100,054 / 0 / 0 | 0 | 0 | 0 | 37,911 (6,111) | 15,793 (1,987) | 0 / 0 |
| draconian RC8 | 0 | 358,261 / 350,893 / 0 / 0 | 1,204,389 / 367,212 / 0 / 0 | 0 | 0 | 0 | 671,462 (93,524) | 894,475 (115,874) | 3 / 2 |
| Galagon | 0 | 533,535 / 510,824 / 0 / 0 | 2,368,378 / 710,071 / 0 / 0 | 0 | 0 | 0 | 720,143 (88,864) | 932,454 (126,607) | 4 / 1 |
| Elevator-Agent | 0 | 853,156 / 816,609 / 0 / 0 | 3,290,480 / 1,003,408 / 0 / 0 | 0 | 0 | 0 | 1,360,957 (155,686) | 1,478,507 (199,573) | 0 / 0 |
| SF2fix_NTSC | 8,730 | 8,216 / 682 / 0 / 0 | 701,035 / 497,792 / 0 / 0 | 0 | 0 | 0 | 524,261 (67,838) | 785,189 (98,169) | 0 / 0 |
| Galagon | 8,730 | 533,535 / 5,474 / 0 / 0 | 2,368,378 / 810,266 / 0 / 0 | 0 | 0 | 0 | 720,143 (92,465) | 932,454 (111,716) | 4 / 0 |
| SF2fix_NTSC | 17,460 | 8,216 / 683 / 0 / 0 | 701,035 / 94,647 / 0 / 0 | 0 | 0 | 0 | 524,261 (63,183) | 785,189 (97,347) | 0 / 0 |
| Galagon | 17,460 | 533,535 / 17,237 / 0 / 0 | 2,368,378 / 810,622 / 0 / 0 | 0 | 0 | 0 | 720,143 (98,964) | 932,454 (117,859) | 4 / 3 |

"While DARIA runs" is DARIA's CPU between `call_go` and `returned`; "the window" is `locked & (call_win | !cpu_ready)` as the bench forms it. "Within 69.84 ns" is step 5's information count (either order, same word; upstream's ARM against its console-side reads, DARIA against `daria_fe`'s consumed reads).

### 5.5 DARIA's calls against upstream's, and the merges

| Run | `+d_ofs` | Calls compared (differ, skipped) | RAM writes / MMIO compared | T1TC | K1d (differ, not compared) | CDF merges: D - U (clk_sys) | merge_race | merge_late | call_amp | Busy falls daria_fe - upstream (daria_fe later) |
|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | 0 | 525 (0, 0) | 524,261 / 1,050 | - | 525 (0, 0) | 0: - | 0 | 0 | 4,278 | -1238 .. 578 (1) |
| Dino-Eggs | 0 | 49 (0, 0) | 37,911 / 0 | - | 49 (0, 0) | 0: - | 0 | 0 | 150 | -164 .. 536 (40) |
| draconian RC8 | 0 | 600 (0, 0) | 671,462 / 4 | 1 reads compared, DARIA - upstream 36 to 36 counts | 600 (0, 0) | 600: -3225 .. 79 | 0 | 0 | 4,407 | -3213 .. 87 (137) |
| Galagon | 0 | 599 (0, 0) | 720,143 / 0 | - | 599 (0, 0) | 599: -1984 .. 264 | 0 | 0 | 4,845 | -1972 .. 277 (1) |
| Elevator-Agent | 0 | 599 (0, 0) | 1,360,957 / 0 | - | 599 (0, 0) | 599: -3480 .. -156 | 0 | 0 | 7,341 | -3472 .. -146 (0) |
| SF2fix_NTSC | 8,730 | 525 (0, 0) | 524,261 / 1,050 | - | 525 (0, 0) | 0: - | 0 | 0 | 4,278 | -1237 .. 578 (1) |
| Galagon | 8,730 | 599 (0, 0) | 720,143 / 0 | - | 599 (0, 0) | 599: -1984 .. 264 | 0 | 0 | 4,845 | -1972 .. 277 (1) |
| SF2fix_NTSC | 17,460 | 525 (0, 0) | 524,261 / 1,050 | - | 525 (0, 0) | 0: - | 0 | 0 | 4,278 | -1237 .. 578 (1) |
| Galagon | 17,460 | 599 (0, 0) | 720,143 / 0 | - | 599 (0, 0) | 599: -1984 .. 264 | 0 | 0 | 4,845 | -1972 .. 277 (1) |

D − U: `daria_fe`'s X+1 against upstream's merge (M) per CDF call; negative when DARIA returned first. Busy falls: `daria_fe`'s `arm_call_busy` fall less upstream's, per call; the 6507 waits for the later one.

### 5.6 Counts and classes

| Run | `+d_ofs` | Frames | Latches | Commits | Ticks | AMPLITUDE reads | C3 / C4 | Services | K1 / K2 | Stall clocks forced | FE bad | Classes | Result | Wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | 0 | 300 | 5,958,595 | 4,976,458 | 99,877 | 79,452 | 0 / 6,168 | 0 | 525 / 299 | 2,565,530 | 0 | resync 4278, guard_shift 10737, call_amp 4278 | **PASS** | 1,419 |
| Dino-Eggs | 0 | 300 | 5,961,844 | 5,466,142 | 99,931 | 0 | 0 / 5,235 | 5 | 49 / 299 | 106,529 | 0 | resync 150, guard_shift 457, call_amp 150 | **PASS** | 1,434 |
| draconian RC8 | 0 | 300 | 5,956,774 | 5,122,575 | 99,336 | 48,814 | 354,710 / 1,503 | 0 | 600 / 299 | 2,795,114 | 0 | resync 4178, merge_amp 510, guard_shift 3889, call_amp 4407 | **PASS** | 1,443 |
| Galagon | 0 | 300 | 6,016,099 | 4,414,425 | 100,174 | 0 | 526,695 / 4,792 | 0 | 599 / 299 | 2,985,529 | 0 | resync 4567, merge_amp 667, guard_shift 37456, call_amp 4845 | **PASS** | 1,464 |
| Elevator-Agent | 0 | 300 | 6,015,819 | 4,625,571 | 99,530 | 0 | 840,172 / 4,792 | 0 | 599 / 299 | 4,319,072 | 0 | resync 6534, merge_amp 1306, guard_shift 54207, call_amp 7341 | **PASS** | 1,453 |
| SF2fix_NTSC | 8,730 | 300 | 5,958,595 | 4,976,458 | 99,877 | 79,452 | 0 / 6,168 | 0 | 525 / 299 | 2,565,595 | 0 | resync 4278, guard_shift 10687, call_amp 4278 | **PASS** | 1,414 |
| Galagon | 8,730 | 300 | 6,016,099 | 4,414,425 | 100,174 | 0 | 526,695 / 4,792 | 0 | 599 / 299 | 2,985,532 | 0 | resync 4566, merge_amp 667, guard_shift 37398, call_amp 4845 | **PASS** | 1,423 |
| SF2fix_NTSC | 17,460 | 300 | 5,958,595 | 4,976,458 | 99,877 | 79,452 | 0 / 6,168 | 0 | 525 / 299 | 2,565,696 | 0 | resync 4278, guard_shift 10730, call_amp 4278 | **PASS** | 1,403 |
| Galagon | 17,460 | 300 | 6,016,099 | 4,414,425 | 100,174 | 0 | 526,695 / 4,792 | 0 | 599 / 299 | 2,985,597 | 0 | resync 4567, merge_amp 667, guard_shift 37457, call_amp 4845 | **PASS** | 1,419 |

A1 masked (class or `call_amp`), clocks and the longest mask: see 5.2.

## 6. Self-tests, and the verification's faults

### 6.1 The self-tests

Each is injected only by `+mb_inj=K` (default 0), on the final binary, Mappy (CDFJ), 15 frames, `+d_ofs=0`. Each must FAIL, and each does, by the check meant for it. Runs: `runs/modeB/selftest/inj<K>_Mappy/` (`fe_err.txt` has the first five of each failure, the first two with the bus ring). 1-3 are the lane's own; 4-7 were added after the verification. Without an injection the same run passes on the final binary (`selftest/inj0_Mappy`: 29 calls, 0 differ; 4,736 refresh pairs, 0 bad, one excused by an ARM-written word; `merge_race` 2).

| K | Injection | Result | Failures (FE bad) | First targeted failure (abridged) |
|---|---|---|---|---|
| 1 | The guard forced off at its consumers: `u_fe.guard_on` (the guard's output net, which `u_core` and `u_arb` read) forced 0, while its window is held open: `u_fe.call_win` forced 1 into `u_guard` (only `u_guard` reads it). The bench forms the window itself (`locked & (call_win \| !cpu_ready)`), so it sees the window open while the ports ignore it | **FAIL** (22,733 bad) | `wr_shared_guard` 4,215, `rd_shared_guard` 18,262, `rd_shared_daria` 256; every other check 0 (L1, C1-C4, K1/K2, the refreshes by value, the calls: 29 compared, 0 differ) | the run's first failure: clk_sys 82,127, frame 0, "a consumed port-B read of word $006c on a shared edge in the guard's window" (an audio read before the first call; the window is held open from the lock on). The first write: clk_sys 121,568, a DSPTR write of word $0046 at $1FF1, the 6507's own; the first read while DARIA runs: clk_sys 122,936, word $0135 |
| 2 | The detector on the wrong phase: `u_fe`'s `clk_arm` is a copy of `clk_d` 8,730 ps later, so it is still on the lattice and the detector locks (at edge 18, the model's edge for that clock), but on the k ≡ 0 class while DARIA's real shared edges are k ≡ 1 | **FAIL** (4,631,401 bad) | `det_bad` 2,314,930, `phb_bad` 2,314,930 (two of every three clocks after lock), `rd_shared_guard` 774, `rd_shared_daria` 767 | clk_sys 20: "det_bad: pd_same 1, the last clk_sys edge (1,292,040 ps) was not shared"; then the audio, released on the wrong phase-B edge, reads on real shared edges while DARIA runs |
| 3 | A front-end read on a shared edge: `u_fe.phb_next` (the guard's net into `u_arb`) forced 1, so in the guard's window the audio is granted on every edge | **FAIL** (2,315,446 bad) | `rd_shared_guard` 259, `rd_shared_daria` 256, `phb_bad` 2,314,931 | `phb_bad` from clk_sys 17 (the forced net, from time 0); the targeted one at clk_sys 122,936, frame 0: "a consumed port-B read of word $0135 on a shared edge in the guard's window" |
| 4 | `coll_d_same`'s positive control: on every shared edge where DARIA stores a cart RAM word, the coincidence counters also see a consumed `daria_fe` read of that word (only the counters see it: nothing reaches `u_fe`) | **FAIL** (1,365 bad) | `coll_d_same` 1,365: exactly DARIA's 1,365 stores on a shared edge, each counted once | clk_sys 122,463, frame 0: "coll_d_same: a DARIA store and a consumed daria_fe read of one word on one edge" |
| 5 | `coll_d_ld_same`'s and `coll_ww_same`'s: on every shared edge, the counters also see a `daria_fe` write of the cart RAM word DARIA's port A is at (1,106,760 such edges) | **FAIL** (2,664 bad) | `coll_d_ld_same` 1,299: exactly DARIA's 1,299 cart RAM loads registered on a shared edge; `coll_ww_same` 1,365: its 1,365 stores there | clk_sys 122,451: "coll_d_ld_same: a daria_fe write and a DARIA load of one word on one edge" |
| 6 | A wrong returned frequency: state RAM word FB (voice 0's returned frequency) has bit 8 flipped in `dmem` while `u_call` reads the returns, every CDF call (29 flips). DARIA's own record (FIQ r8-r13) and upstream are untouched, so the call compare still passes | **FAIL** (29 bad) | `audio_bad` 29, one per call; `merge_race` 0 | clk_sys 126,642, frame 0: "A1 counters/frequencies: counter[0] 100, upstream 0 (after a merge window: U 126640, D 126502, 1 ticks between; voice 0: frequency daria_fe 00000100, upstream 00000000)". The rule before the fix took the step from `daria_fe`'s own frequency, and that difference (−k · $100) passed it as `merge_race` |
| 7 | An undefined read: $A5A5A5A5, what the poisoned `daria_ram` returns to a read that meets a write of its word at one time step, forced into `daria_fe`'s port-B q in the clock its audio capture takes it, for each audio read in a call's flight of a word DARIA has stored in that flight (49 reads) | **FAIL** (33 bad) | `refresh_bad` 20, `deposit_bad` 13. 13 of the 20 pairs are under `call_amp` alone; the other 7 are also under `merge_amp`, and fail by the rule that holds under any class | clk_sys 125,107, frame 0: "refresh_bad: read 2 of word 0470: a5a5a5a5, a value daria_fe's memory never held in the flight" |

Notes.

- In 1 and 3 the forced net is the same Verilator variable as `u_guard`'s output port, so the bench's tap of `u_guard.guard_on` reads 0 in 1 ("guard_on 0 clocks") and its tap of `phb_next` reads 1 in 3 (hence `phb_bad` there). The window and the shared edges the checks use are the bench's own (`locked`, `call_win`, `cpu_ready`, and the edge arithmetic), so the targeted checks do not depend on those taps. `gwin_bad` is not checked in 1 and 3, whose forces it would only restate.
- In 1, every port-B write lands somewhere: 4,898 of the 6,630 on a shared edge. 4,215 of them are non-F6 writes in the held-open window, and fail. The other 683 are F6's (the init copy, a third of its 2,048 writes), which the check exempts: F6 never meets a call (design 3.5, `a_f6_live`). On a normal run no `daria_fe` write is ever requested in a real guard window (`a_guard_wr` 0), so a non-F6 write on a shared edge in the window needs both faults, the window held open and the guard ignored at the ports; with the guard alone forced off, the reads are what land on shared edges (`rd_shared_daria` 256 here, 767 in 2).
- In 1-3 the refreshes by value stay equal (`refresh_bad` 0): the guard moves the grants, not the words read.
- 4 and 5 count each injected access exactly as a real one, in the same two blocks: their counts equal DARIA's shared-edge stores and loads, so the counters miss no coincidence and count none twice.
- In 6, every merge is caught, at k = 1 and at k = 0 alike (with k = 0 the counters agree, and only the frequency differs). Upstream's 29 merges include the two that `merge_race` explains on a normal run (k > 0, frequencies equal).

### 6.2 The verification's faults in a scratch copy of the RTL

The verification put faults in a scratch copy of `daria_fe`'s RTL, and the bench of the time passed these three. The same faults, each behind a plusarg in a copy of `src/fpga/core/bupchip` in the session's scratchpad (`gfix/tree`; the worktree's RTL untouched), were built with the final bench (`gfix/workf`) and run like the self-tests:

| Fault (plusarg) | What it does | Run | Before (the verification) | Now |
|---|---|---|---|---|
| `+gv_audbad` | `daria_fe_arb.sv`: port B reads word `aud_addr[14:2] ^ 1` for an audio grant while `guard_on` | Mappy, 15 frames | PASS (45 wrong values overwritten by the resync) | **FAIL** (169 bad: refresh_bad 87, deposit_bad 82) |
| `+gv_audbad` | the same | draconian, 30 frames | PASS (4 overwritten) | **FAIL** (67 bad: refresh_bad 34, deposit_bad 33) |
| `+gv_badfreq` | `daria_fe_audio.sv`: every merged frequency is `ring[3+v] ^ $100` | Mappy, 15 frames | PASS (29 frequencies overwritten as `merge_race`) | **FAIL** (29 bad: audio_bad 29) |
| `+gv_thr15` | `daria_fe_guard.sv`: the flywheel locks after 15 matches, not 12 | Mappy, 2 frames, `+d_ofs` 0 / 8,730 / 17,460 | PASS at 8,730 (locked at 21, within 24) | FAIL at 0 (locked at 19, the model 16); FAIL at 8,730 (locked at 21, the model 18); FAIL at 17,460 (locked at 17, the model 14) |

## 7. Regressions

Every existing build must be exactly as before. Two proofs, against a copy of HEAD's bench files (1fb9d95: `run_daria.sh`, `tb_daria.sv`, `daria_shadow.svh`, `fe_shadow.svh`, `fe_taps.svh`, `sim_stubs.sv`, with the same RTL):

1. **Preprocessed sources**, compared again on the final sources of this revision. `verilator -E -P` with each build's own sources and defines (taken from each tree's `run_daria.sh`), blank lines dropped: identical to HEAD's for plain, `SHADOW=1` (`WIN_KB` 128 and 64), `SHADOW=1 WRAPPER=1 WIN_KB=64`, `FE=1`, `FE=1 FE_STAGE0=1`, `FE=1 FE_POISON=1`, `SHADOW=1 WIN_KB=64 FE=1` and `SHADOW=1 WRAPPER=1 WIN_KB=64 FE=1` (24,374 to 31,743 lines each). The only differences are blank lines where a mode-B block is left out, which move line numbers inside the `.svh` files only; `tb_daria.sv`'s own lines, and so the `$finish` line in `run.log`, are unchanged. So each of those binaries is built from the same code as before. (Mode B itself is 30,700 lines, 30,727 with `FE_POISON=1`.)
2. **Short runs**, made by the lane before the verification, each built from both trees (separate work directories) and run with the same arguments; every output file compared (`run.log` less its wall-clock lines and the source path in the `$finish` line, which names the tree):

| Build | Image, frames | Files compared | Identical | What the run shows |
|---|---|---|---|---|
| plain | SF2fix_NTSC, 8 | run.log, frames.csv, calls.csv, summary.txt, slack.csv, zero.csv, report.txt, pcs.txt | 8 of 8 | 9 calls |
| `FE=1 FE_STAGE0=1` | SF2fix_NTSC, 8 | the same and fe.csv, fe_err.txt | 10 of 10 | reference dout/state 0 |
| `FE=1` (mode A) | Galagon, 20 | the same and fe_ref.csv | 11 of 11 | FE result PASS, 39 calls |
| `SHADOW=1 WIN_KB=64` | Mappy, 20 | step 5's set and daria.csv | 9 of 9 | 39 calls compared, 0 differ |
| `SHADOW=1 WRAPPER=1 WIN_KB=64` | Mappy, 10 | the same | 9 of 9 | 19 calls compared, 0 differ; PSRAM model 0 violations |

Runs: `runs/reg/new/` (this tree); the HEAD copy's runs were made in the session's scratch area and are not kept. They were not repeated after the verification's fixes: every change since is inside `` `ifdef FE_MODE_B `` or in comments, and proof 1, rerun on the final sources, shows each of these five builds' preprocessed source unchanged, so each binary is the one those runs used.


## 8. Observations

**The sweep moves the shared edge across the 6507 cycle's slots** (bench.md 6.3, "what the three classes cover"). The share of `daria_fe`'s port-B traffic that registers on a shared edge changes with `+d_ofs`, as it should; DARIA's share stays near 1 in 8 (8 `clk_d` edges per shared edge):

| Image | `+d_ofs` | `daria_fe` writes on a shared edge | consumed reads on a shared edge | DARIA stores on a shared edge | DARIA cart RAM loads on a shared edge |
|---|---|---|---|---|---|
| SF2fix (DPC+ rev 0) | 0 | 6,851 of 8,216 (83.4%) | 97,881 of 701,035 (14.0%) | 65,605 of 524,261 (12.5%) | 98,642 of 785,189 (12.6%) |
| | 8,730 | 682 (8.3%) | 497,792 (71.0%) | 67,838 (12.9%) | 98,169 (12.5%) |
| | 17,460 | 683 (8.3%) | 94,647 (13.5%) | 63,183 (12.1%) | 97,347 (12.4%) |
| Galagon (CDFJ) | 0 | 510,824 of 533,535 (95.7%) | 710,071 of 2,368,378 (30.0%) | 88,864 of 720,143 (12.3%) | 126,607 of 932,454 (13.6%) |
| | 8,730 | 5,474 (1.0%) | 810,266 (34.2%) | 92,465 (12.8%) | 111,716 (12.0%) |
| | 17,460 | 17,237 (3.2%) | 810,622 (34.2%) | 98,964 (13.7%) | 117,859 (12.6%) |

At `+d_ofs=0` nearly every 6507-side write (DSPTR/DSWRITE pointer writes, DPC+ WRITE/PUSH) registers on a shared edge; at 8,730 almost none do, and the consumed reads move instead. Every one of those is outside the guard's window and outside DARIA's calls (the `0 / 0` columns of 5.4): the 6507 is held for the whole call window, so the 6507-side traffic cannot meet DARIA's CPU, and the guard only has to place the audio reads, which it does (`guard_shift`; design 3.5: 0-2 clocks per read).

**DARIA's stores are not guarded, by design.** About 1 store in 8 lands on a shared edge (11.4-16.1% over the nine runs), as bench.md 6.4 predicted for an unguarded CPU. Its acceptance item 1 there (`d_shared_stores` = 0) belonged to the CPU-side guard (a W wait on stores) that the project did not take: the guard is in the front end and the CPU is unchanged (docs/DARIA_CORE.md, open item 7; design 8.4: "`d_shared_stores` counted"). What must hold instead is that no front-end access meets one of those stores on its edge: `coll_d_same`, `coll_d_ld_same` and `coll_ww_same` are 0 in every run, and so are the port-B checks.

**The detector and the guard.** In every run the guard locked at the modelled edge (16, 18, 14 for 0, 8,730, 17,460; `lock_edge_bad` 0) and never unlocked: `det_bad` and `phb_bad` are 0 over 71.6-72.4 M `clk_sys` per run, all but the first 14-18 locked. `guard_on` was high 0.26% (Dino-Eggs: 49 calls) to 6.19% (Elevator-Agent) of the clocks, and `gwin_bad` is 0, so it is exactly `locked & (call_win | !cpu_ready)`. `guard_shift` (audio reads moved to phase B) is 457-54,207 clocks per run.

**DARIA's calls are independent of the phase.** For each image the call compare is identical at the three offsets: SF2fix 525 calls, 524,261 RAM writes and 1,050 MMIO accesses compared, 0 differ; Galagon 599 calls, 720,143 RAM writes, 0 differ. DARIA's cycle count is the same for every call at every offset (`daria.csv`), and its latency from `daria_fe`'s C to X+1 differs by at most 1 `clk_sys` per call between offsets (SF2fix 783-8,666 `clk_sys`, mean 4,884.4 / 4,884.6 / 4,884.7), as the toggle synchronisers see coincident edges at different phases (bench.md 6.3). K1d is 0 everywhere: DARIA always starts from the cart RAM upstream's ARM started from. The one T1TC read (draconian) differs by 36 counts against a bound of 200.

**Calls: who returns first.** DARIA usually returns well before upstream's ARM: D − U (`daria_fe`'s X+1 against upstream's merge M) is −3,480 to +264 `clk_sys` over the CDF runs. The 6507 is released by the later of the two busy falls, and `daria_fe`'s is the later one in 1 (SF2fix, Galagon), 40 of 49 (Dino-Eggs: its usual call takes DARIA about as long as upstream's ARM, 6,466 `clk_d` ≈ 2,425 `clk_sys` against 11,769 of upstream's 5 × `clk_sys` ARM clocks ≈ 2,354 `clk_sys`, so `daria_fe`'s post and return synchronisation decide), 137 of 600 (draconian) and 0 (Elevator-Agent) calls. In those calls the bus follows `daria_fe`'s own release, and both front ends still agree cycle by cycle (H1, C1-C4 and L1 at 0).

**The merge.** Every CDF merge of the game runs passed section 2's rule with nothing to explain: after each window the frequencies were upstream's and the counters agreed exactly (`merge_race` 0, `audio_bad` 0), so in every merge either no tick fell between the two merge edges or the voice's step was 0. Mappy's 15-frame runs have two merges with a tick between them and a nonzero step: both pass as `merge_race` (frequencies equal, the counters different by exactly k ticks of upstream's step), and self-test 6 shows that the rule now fails a wrong frequency at k = 1 as at k = 0. `merge_late` is 0: M_fe − X = 7 for every merge (design 6.3).

**What the masks cost.** A1's every-clock compare of the replica is masked, by a class or `call_amp`, on 0.002% (Dino-Eggs, 1,357 clocks) to 1.26% (Elevator-Agent, 911,830 clocks) of the clocks; the longest mask is 3,428 `clk_sys` (Elevator-Agent), well under `mask_stuck`'s 20,000. Since the verification those masks cost timing only: every refresh they cover is still compared by value (5.2), and every resync that ends one is checked for what it overwrites. Counters, frequencies and the tick group are compared outside the merge windows throughout, and K2 compared the whole cart RAM once per frame (299 per run).

**The refreshes by value.** Each run compares about 100,000 refresh pairs (one a tick), read by read and at their ends, 39,267 of them over the nine runs during a call in flight. Most pairs in a flight are equal: the two engines read their RAMs a few clocks apart, and the ARMs rarely write a word a refresh reads in between. The excused ones are of two kinds, each read in the logs (the `FE mode B refresh excused` lines):
- **An ARM's store between the two reads.** On Galagon, word $0400 (cart RAM byte $1000, a sample word the game's ARM code rewrites during the call) reads f4aaf4aa on upstream's side and f4aa4204 on `daria_fe`'s in the same refresh: DARIA had stored f4aa4204 before `daria_fe`'s read (by 12.9 µs), and upstream's ARM stored it only after upstream's read (by 51.5 µs). `daria_fe`'s value is the one DARIA stored, which the RAM-history rule checks. On draconian two pairs are excused this way, with equal AMPLITUDEs all the same; on Elevator-Agent, SF2fix and Dino-Eggs no read of an ARM-written word differed.
- **Another class.** Almost all `merge_amp`: a CDF refresh dispatched in a merge window takes its counters from a merge the two sides make at different edges (E1, design 9.5).

On the verification's Mappy run, the one pair it found overwritten without examination (clk_sys 1,786,018, AMPLITUDE `0c` against `08`) is of the first kind: word $0211, read by `daria_fe` after DARIA's store of 00000404 and by upstream before its ARM's store (section 11).

**The 69.84 ns window** (step 5's information count, now on `daria_fe`'s consumed reads): 0-3 for DARIA per run against 0-4 for upstream's own ARM against its console-side reads. None is on a shared edge (`coll_d_same` 0): they are reads 8.73 ns or more from a store, which most likely do not race on the device, though the timing analysis does not check it (docs/DARIA_CORE.md, step 5's results on open item 7). With the guard, a read in the window registers 17.46 ns after the last `clk_d` edge.

**The extra runs.** Two, beside the gate (`runs/modeB/extra/`), on the final binaries:

| Run | What it shows | Result |
|---|---|---|
| `MODE_B=1 FE_POISON=1`, Galagon, 60 frames (`+fire_at=20 +play_at=30`, `+d_ofs=0`) | `daria_mem`'s poisoned model (design 12.1): a read on one port of a word the other port writes at the same time step returns $A5A5A5A5, and a port's q after a partial-byte-enable write shows $A5 in the bytes not enabled. What it checks by value, of the coincidences the counters count by time: a `daria_fe` read that meets a DARIA store (`coll_d_same`) can only be an audio read, since the 6507 is held while DARIA runs, and every audio read in a call's flight of a word DARIA stored there must return a value the word held (the RAM-history rule of 5.2; self-test 7 shows a poisoned read failing it). A DARIA load that meets a `daria_fe` write (`coll_d_ld_same`) shows only through what it changes in DARIA's call (FIQ r8-r13, its stores, its MMIO, all compared), and two writes on one edge (`coll_ww_same`) in K1d and K2. The verification found that the first claim did not hold before the refresh compare: the masks and the resync then hid every audio value read in a call | **PASS**: 119 calls compared, 0 differ; FE 0 bad; locked at edge 16 (the model's), `det_bad` 0; the coincidences 0; 20,738 refresh pairs, 664 in a flight, 0 `refresh_bad` (one pair excused by an ARM-written word, $0400); 66,162 of 70,587 `daria_fe` writes and 117,002 of 376,319 consumed reads on shared edges, none in the window; `guard_on` 3.35% |
| `+d_ofs=13095` (step 5's phase, no shared edge), Mappy, 15 frames | The detector where no edge is shared, in zero delay (section 3) | **FAIL, as expected**: locked at edge 18 (the model's: `lock_edge_bad` 0), then `det_bad` = `phb_bad` = 1,157,465, one clock in three of the 3,472,395 locked ones; first at `clk_sys` 20: "pd_same 1, the last clk_sys edge (1,292,040 ps) was not shared". Nothing else fails (no shared edge exists, so the port-B and coincidence counts are 0; 29 calls compared, 0 differ; 4,736 refresh pairs, 0 `refresh_bad`). On the Pocket this clock cannot occur (both clocks are on the PLL's lattice); here it shows that `det_bad` judges the detector against the real clock, not against itself |


## 9. RTL issues

None. Every gate holds in every run, and no check outside the classes fired, the refreshes by value and the stricter merge rule included, so there is no first differing clock to trace and no reproduction to give. `src/fpga/core/bupchip/daria_fe*.sv` was not edited. The refresh pairs the bench excuses with a difference were each read in the logs (section 8, "The refreshes by value"): every one is an ARM's store landing between the two engines' reads of a word, or a refresh of another class.

## 10. Not done, and why

| Item | Why |
|---|---|
| `daria_fe`'s stall outputs driving the 6507, and `release_dup` (design 6.3) | The hold is still the bench's `force` of top.sv's `arm_call_stall` (7.4.2), now the OR of both sides' busies, so one bus serves both front ends and the comparison stays exact. `daria_fe`'s busy fall does release the bus in the calls where it is the later one (section 8, "Calls"), and both front ends still agree there, but its stall rise inside [E0+6, E0+17] and the release-window duplicate commit are not behaviour here: they need `daria_fe` on the bus (step 7's wrapper wiring), or `tb_fe_call`/`tb_fe_seq` |
| `WRAPPER=1` with mode B | Refused by `run_daria.sh` and by `daria_shadow.svh` (`$finish`): mode B runs on `dcall`/`dmem`; the wrapper's PSRAM path and `bupchip_pocket` wiring of `daria_fe` are step 7 (design 1.6) |
| A console reset in mode B (`+hard_reset_at`) | Not run. The bench handles it (DARIA's reset follows `effective_reset`, records in flight are dropped and the call numbers re-aligned, `daria_shadow.svh:201-209` and the `effective_reset` branch of the compare; the refresh compare drops both sides' open refreshes at a reset), but the gate asks for none and mode A's reset runs are step 7's lane. Every run here has one reset, the start |
| Phase moves, a PLL relock, path delay and jitter on `pd_tog` → `pd_rx` | `tb_daria` is zero-delay with a fixed `+d_ofs` per run, so `det_unlock` can only show that nothing moves. Moves, stops and per-launch delays in [1, 6] ns are `tb_fe_guard`'s (lane D, 2.2: `d18_mvA/B`, `d18_stop`, `d18_bad`; issue O-3 on 5×/1× with jitter, which concerns mode A only). The 6/1 ns SDC pair and its STA check are step 9 (design 8.2) |
| Pause in mode B (`pause_call`) | Not exercised: no run pauses the console, and the Pocket never pauses (design 9.5) |
| Digital samples above 32 KB | As in mode A: the emulated sample port (`+fe_slat`); the real requester is in the wrapper (step 7) |
| Length and breadth | 300 frames per run, one image per scheme at 0 and one DPC+ and one CDF-family image at 8,730 and 17,460, as asked; mode A's 1,500-frame batch is a separate lane |
| The `FE latency:` line's mode-A histograms | Not changed: in mode B, "busy fall fe − up" pairs upstream's fall with `daria_fe`'s next one, so with `daria_fe` usually first it lands in the 63+ bin, and the "merge M_fe − M" bins hold M_fe − X (7, design 6.3). The `FE mode B calls:` line has the mode-B measures. Information only; no check reads them |
| A coincidence `daria_fe`'s own RTL makes, by value | No run makes one: with the guard, no consumed read or write of `daria_fe`'s lands on a shared edge while DARIA runs, and with the guard forced off (self-tests 1-3) none meets a store of the same word within 15 frames. The counters' positive controls are self-tests 4 and 5, and the value check's is self-test 7, which puts the poisoned model's $A5A5A5A5 where a coincidence would |
| The refresh compare under another class | A pair either of whose refreshes ran under the mask of a class other than `call_amp`/`guard_shift` (`merge_amp`, `pre_lock`, `svc_audio_race`, `dig_rom_lag`, `grant_steal`, `size_over32k`, `pause_lane`, or a failure) is counted (`refresh_x_class`) and not compared by value; those classes have their own rules (design 9.5, E1), and the resync clears their masks. The one rule that still holds there is the RAM-history one (any read of a word DARIA stored in the flight returns a value it held) |
| Upstream's own reads | The refresh compare takes upstream's values as the reference: only `daria_fe`'s value is checked against its RAM's history |
| The time-0 edge on `fb_clk_arm` (section 3) | Left as is: it is Verilator's view of a clock that starts high through a continuous assign, it only moves the first lock (15-18 clocks, bound 24), and it is documented. The lock-edge check's model includes it, so a simulator that did not see it would fail `lock_edge_bad` at 8,730 and 17,460 (15 and 17), and point here |


## 11. The verification's findings and what changed

The verification of this lane (a review of the bench, with faults in scratch copies of the RTL and the bench) reported for mode B one blocking finding, three should-fix (one of them the blocking one again) and three nits. All were fixed; none was wrong. The bench changes are all inside `` `ifdef FE_MODE_B `` (proof 1 of section 7), and every run of this report was repeated on the final binary.

| Finding | Fix | Evidence now |
|---|---|---|
| The merge rule never checked the frequencies: `mb_race_ok` took the step from `daria_fe`'s own frequency, so a wrong returned frequency explained itself, was counted `merge_race` and was overwritten by the resync (a fault in the merged frequency passed on Mappy, and on draconian was caught at one merge of 59). Reported twice, as blocking and as should-fix | `mb_race_ok` (`fe_shadow.svh:1390-1425`) first requires `daria_fe`'s three frequencies to equal upstream's; with k = 0 any counter difference is `audio_bad`; with k > 0 the step is upstream's returned frequency (less upstream's old one when upstream kept its counter), with upstream's own take captured at U (:2055-2060) | self-test 6 (a returned word corrupted in `dmem`): FAIL, `audio_bad` 29 of 29 calls; the scratch RTL fault `+gv_badfreq` (6.2): FAIL; the game runs: `merge_race` 0, `audio_bad` 0; Mappy's two `merge_race` cases on a normal run (k > 0, frequencies equal) still pass |
| `call_amp` and `guard_shift` masked every refresh run in a call, and the resync then overwrote whatever differed, so no audio value read under the guard was ever compared (a fault reading the wrong word under `guard_on` passed; one baseline Mappy difference was overwritten unexamined) | Every refresh is compared by value at its end, read by read, with the excuse limited to a read of a word an ARM wrote in the flight whose values differ, `daria_fe`'s value checked against its RAM's history (`mb_ref_close`, `mb_val_ok`, `mb_hist`); `refresh_count_bad` at quiet points; `deposit_bad` for any difference a resync overwrites with nothing to excuse it (sections 2, 4) | the game runs: `refresh_bad`, `refresh_count_bad`, `deposit_bad` 0 over 902,767 pairs; `+gv_audbad` (6.2): FAIL on Mappy and draconian; self-test 7: FAIL. The baseline difference (Mappy, clk_sys 1,786,018, AMPLITUDE `0c` against `08`) is one pair excused for a reason: word $0211, a waveform word DARIA stored at 124,735,296,330 ps in that flight, read after that store by `daria_fe` (00000404) and before upstream's ARM's store by upstream (00000000) |
| The report said the poisoned run checks by value what the coincidence counters count, which it could not: every audio read in a call was masked and overwritten | The claim is replaced by what holds now (section 8, "The extra runs"): with the refresh compare and the RAM-history rule, a poisoned audio read in a flight fails the run; a poisoned DARIA load shows in DARIA's call compare only through what it changes; two writes on one edge show in K2 and K1d | self-test 7 is the positive control of that value path, and self-tests 4 and 5 of the counters |
| (nit) `lock_late` bounds the lock at edge 24 only, so the 12-match threshold was not pinned | `lock_edge_bad`: the lock must come at the edge of a zero-delay model of 8.1 for the detector's clock (`mb_lock_model`, :1432-1456; section 3) | all runs: 0, at 16/18/14; `+gv_thr15` (6.2): FAIL at 8,730 (21 against 18), and at 0 and 17,460 |
| (nit) no positive control for `coll_d_same`/`coll_d_ld_same` | self-tests 4 and 5 (`daria_shadow.svh`) | each counter fires exactly as often as DARIA's shared-edge stores (1,365) or loads (1,299), and fails the run |
| (nit) self-test 1's write counts were not explained, and its listed first failure was not the run's first | section 6.1: 4,215 non-F6 writes fail, the other 683 shared-edge writes are F6's, which the check exempts; the run's first failure is `rd_shared_guard` at clk_sys 82,127 | |
