# Lane E1: bench stage 1, `daria_fe` beside upstream in tb_daria (DARIA step 6)

Lane E1 is points 1-3 of the original lane-E task: bench stage 1 of design 12.4 (bench.md 7.4-7.7) in `sim/bupchip/daria/fe_shadow.svh`, the tap map `fe_taps.svh` with `fe_deposit_audio`, `run_daria.sh` `FE=1` with the real `daria_fe` sources and `FE_POISON=1`, the reporting, and the mode-A runs on the image set.

**Status.**

- **Built.** `daria_fe` runs as `u_fe` on its own `daria_mem` (`fe_mem`) inside tb_daria, beside the stage-0 reference, which stays. Every check of design 12.4 and every counted class of design 9.5 is implemented; section 3 maps each one to its code and counter.
- **Mode A, 120 frames, final binary: every image passes, every bad count 0** (section 5):
  - SF2fix_NTSC (DPC+ rev 0), Galagon (CDFJ), draconian RC8 (CDF1), each with and without `+fe_merge_hook=1`;
  - Stratovox (one of the new DPC+ revision-0 games). It makes 5 DPC+ copy services, the first services any image in the set makes: R2 and R3 match, and the hold stalls the 6507 for daria_fe's slower engine with H1 at 0.
- **Classes seen:** `merge_amp` only, and only without the hook (Galagon 5, draconian 4 in 120 frames), each resynced. With the hook no AMPLITUDE class occurs, as design 0.2 and 12.5 item 2 expect.
- **No RTL issue found** by these runs. One `daria_fe` behaviour that differs on the 6507's bus was found by lane E2's directed test `cdf_jump_ffe` through this bench's O1 check (`obus_exposed`; E2 report 6.1, repeated in section 7 here).
- **The checks bite:** nine faults injected into `u_fe` or `fe_mem` (`+fe1_inj`), each caught by the check meant to see it at the first clock it is visible, and a tenth (a `dma_busy` with no service) shows the hold stalling the 6507 exactly while `u_fe` is busy, H1 0 (section 6, rerun on the final binary).
- **Bench bugs found and fixed:** three of mine (section 8), two of them found by lane E2's directed tests (E2 issues 2 and 3); E2's two failing tests pass with the fixed bench.
- **Existing builds unchanged:** plain, `SHADOW=1`, `SHADOW=1 WRAPPER=1` preprocess token-for-token as before (same line numbers); a plain run and a `FE_STAGE0=1` run are identical to stage 0's runs; `SHADOW=1 FE=1` gives a `daria.csv` identical to stage 0's (section 5.4).

Nothing was committed. No RTL, interface or other lane's file was changed. Game-derived outputs are all under `sim/work/bupchip/daria/runs/fe_e1/`.

---

## 1. What is built

| File | Change |
|---|---|
| `sim/bupchip/daria/fe_shadow.svh` | Stage 1 added (about 1,280 lines; 2,259 in all), inside `` `ifndef FE_STAGE0 ``. The stage-0 code (the reference front end, its taps and checks, S1, L3, `+hard_reset_at`) is unchanged, except that in a stage-1 build its csv is `fe_ref.csv`, its final line is `FE reference:` and its ring carries `u_fe`'s columns too. The header documents both stages |
| `sim/bupchip/daria/fe_taps.svh` | **New** (251 lines). The tap map: state RAM and cart RAM words of `fe_mem`, the CDF table layout, C1/C2/C3 comparison functions, the three A1 groups, the quiet test, `fe_deposit_audio`, the R1 payload/post words, the R2 service fields with upstream's `min()` clamps |
| `sim/bupchip/daria/tb_daria.sv` | Two existing lines extended with inline `` `ifdef FE_SHADOW ``: the declaration of `fe_hold_reset` and its term in the console `reset` (BEN 7.2 (2)). No line added, so line numbers (the `$finish` line in run.log) are unchanged |
| `sim/bupchip/daria/run_daria.sh` | `FE=1` adds the package, the eight `daria_fe_*` modules, `daria_fe.sv`, `daria_mem.sv` (unless `SHADOW=1` adds it) and `fe_taps.svh` to the rebuild list. `FE_STAGE0=1` builds the reference-only bench (`obj..._fe_s0`, `runs/..._fe_s0/`); `FE_POISON=1` adds `-DDARIA_RAM_POISON` (`obj..._fe_poison`, `runs/..._fe_poison/`). Installed by rename (the step-5 batch ran from it) |
| `sim/bupchip/daria/run_all.sh` | The same run prefixes. Installed by rename |
| `sim/bupchip/daria/dynamic_tables.py` | `sec_fe` reads stage-1 runs (`FE shadow:`/`FE bad:`/`FE classes:`/`FE inputs:`/`FE reference:`/`FE result:`) and keeps the stage-0 table for stage-0 runs. Its classes column leaves out `drift_up`/`drift_fe` (O1 information) |

Usage:

```sh
FE=1 DTRACE=0 ./run_daria.sh ROM.bin +frames=120 +snap=0 [+fe_merge_hook=1]   # stage 1: runs/fe/<rom>/
FE=1 FE_STAGE0=1 ./run_daria.sh ROM.bin ...                                    # reference only: runs/fe_s0/
FE=1 FE_POISON=1 ./run_daria.sh ROM.bin ...                                    # poisoned daria_ram: runs/fe_poison/
python3 dynamic_tables.py --only fe sim/work/bupchip/daria/runs/fe/*/
```

Plusargs (stage 1): `+fe_merge_hook=1`, `+fe_slat=N` (40), `+fe_hold=0/1` (1), `+fe_resync=0/1` (1), `+fe_full=N` (K2 every N frames, 1), `+fe_ticks=1` (`fe_ticks.csv`), `+fe_pcm=1` (`amp_up.pcm`, `amp_fe.pcm`), the self-test `+fe1_inj=K +fe1_inj_at=N`, and stage 0's `+fe_stop`, `+fe_fatal`, `+hard_reset_at`, `+hard_reset_len`.

## 2. How `u_fe` is wired (design 12.4 "Instances"; bench.md 7.4)

Every input is a continuous assign of a DUT signal or of bench state that changes only by NBA (stage 0 C.2.2), so `u_fe` samples it at the same edge as the DUT's own flops.

| Input | Driven from | Note |
|---|---|---|
| `a_in`, `rw`, `pclk1`, `pclk0`, `access` | `dut.cart2600.a_in`, `dut.RW`, `dut.pclk1`, `dut.pclk0`, `dut.cart2600.arm_access` | |
| `d_in` | `dut.write_DB` | Tap check `din_bad`: equal to `dut.cart2600.d_in` at every write latch |
| `cart_reset`, `pause` | `dut.effective_reset`, `dut.pause` | tb_daria ties `pause` to 0 |
| scheme, revision, CDF options, entry, stack, `audio_size_addr`, `rom_size`, `ram32` | tb's detect2600 wires, `cart_size`, `dut.mapper_ram_size == 32768` | as stage 0 |
| `load_start`, `load_end` | `~old_cart_download && cart_download`, `old_cart_download && ~cart_download` | the DUT's own expressions (bench.md 1.3) |
| `cart_win` | bup_capture's window rebuilt: open from the download's start to 64 clocks after its end | the bench takes the download's edges from the `cart_download` level (section 8.1) |
| `cpu_ready` | `call_controller.arm_online_sync2 && shadow_ready_sync2 && !effective_reset` | design 6.6, critic 8: no `call_busy` term |
| `clk_arm` | the bench's upstream `clk_arm` (5 × `clk_sys`, fixed phase) | lane D issue 3: no jitter; the guard never locks (`det_lock_a` 0) |
| `ret_tog` | flipped at the `clk_arm` edge upstream's `complete_toggle` flips, once `u_fe` has flipped `call_tog` for that call number; else at the first edge after `u_fe`'s flip (`ret_late`) | upstream's flip is predicted from the controller's own condition (CAPTURE_AUDIO, index 5, no mapper reset), so both toggles change on one edge; the bench checks the prediction against `complete_toggle` every `clk_arm` edge (`ret_model_bad`) |
| `smp_ack`, `smp_data` | `img[smp_addr]` after `+fe_slat` clocks | bench.md 7.4.5 |
| `hk_en`, `hk_stb`, `hk_ret` | `+fe_merge_hook`, `dut.cart2600.arm_call_done`, the six `*_return` registers | |

`fe_mem` = `daria_mem #(.WIN_KB(32))` on the bench's `clk_arm` and `clk_sys`:

- **FE ROM port A** takes the download (`ioctl_wr && cart_download && ioctl_addr < 32 KB`), the wrapper's rule.
- **Cart RAM port A** mirrors upstream's CPU writes: `cart_ram.arm_allow && arm_ram_write`, without the writeback (`mapper_wb_en`) and without DMA (`memory.dma_ram_en`), at the `clk_arm` edge `cart_ram_tdp` takes them (BEN 7.4.3).
- **State RAM port A** takes the returns: F8 + `audio_read_index` ← `state_rdata` while the controller is in CAPTURE_AUDIO (BEN 7.4.4).

**The hold (BEN 7.4.2).** `fe_hold_reset` is sticky: set while the download runs and at a console reset edge after a load, released once `u_fe.init_busy` has been seen high and has fallen (2^20-clock timeout: `init_never_busy`). The stall is forced at the falling edge with a constant right-hand side (`force dut.arm_call_stall = 1` while `tia_en && !mapper_init_busy && u_fe.arm_dma_busy`, released otherwise; question 3 of bench.md 9). **H1** checks every clock while running that `arm_call_stall`, `RDY` and `mapper_phi2` follow `tia_en && (arm_call_busy || (!mapper_init_busy && (arm_dma_busy || u_fe.arm_dma_busy)))`.

## 3. The checks (design 12.4) and what each proves

All read pre-edge values in a `posedge clk_sys` block (A1 and the deposit excepted). The 6507-level checks run while "live" (from a `pclk1` with `!effective_reset && tia_en`, as stage 0); the every-clock oracles and the assertions run from time 0.

| Check | When | Compares | Counter |
|---|---|---|---|
| **L1** | every `pclk0` with RW, scheme 21/23 | `{8{fe_oe}}` and `fe_do & oe` against `cart2600.oe`, `d_out & oe`. A hidden `pclk0` is information (`dout_hidden`) | `dout_bad`; classified: `short_dout` (cycle with E0→latch < 6), `amp_class` (an AMPLITUDE read while an audio class masks the replica), `tbl_alias` (an aliased stream's fetch); an AMPLITUDE read with no class is `amp_lag` |
| **L1 (reference)**, **L3**, **S1**, port/rom/ram/pointer/jump tap checks | as stage 0 | the stage-0 reference against upstream; kept beside `u_fe` | `FE reference:` and `FE detail:` lines, `fe_ref.csv` |
| **commit_on_hidden** | every clock | `u_seq.commit` on `pclk0 && !mapper_phi2` | `commit_on_hidden` |
| **hidden_last_bad** | at the `pclk1` after the last hidden latch of a stall (RDY high there) | that latch's L1 | `hidden_last_bad` (must be 0, stage 0 C.5) |
| **C1** (DPC+) | every `pclk1` | `fe_taps.svh` `ft_c1()`: 8 fetchers from state RAM w0/w1 (masks of design 4.2), params 0-3 from word $10, `pptr` = `parameter_pointer` directly, waveforms, LFSR, bank, fast fetch/pending, `call_pending` = `u_call.pend_up`, `service_pending` = `svc_pend` | `state_bad` |
| **C2** (CDF) | every `pclk1` | `ft_c2()`: bank, mode, `fpend` (+ `fexp` while pending), `jr` (+ `jexp`, `jstream` while non-zero), `call_pending` = `pend_up` | `state_bad` |
| **C3** | the `pclk1` after a cycle with `cdf.pointer_update` | upstream's `pointer_ram[idx]` against `fe_mem` cart RAM word `pb + idx` | `ptr_bad`; classified `q26` (that cycle was short), `tbl_alias` |
| **C4** | the `pclk1` after a cycle with `cartram_wr` | the written byte in both cart RAMs; `over32k` if `cartram_addr[17:15] != 0`; `ram_wr_noaccess` if no commit in that cycle | `ram_bad`, `over32k`, `ram_wr_noaccess` |
| **R1** | each upstream accept (`call_req`) and each `u_fe` `call_tog` flip, paired in order | `{entry \| T, stack, counters, frequencies}` against state RAM F0-F7 read when the flip has happened | `call_bad`; `seed_race` (seeds off by one tick's add, no RMW), `rmw_seed` (call 2 of an RMW: class `rmw_call`); post − accept histogram |
| **R2** | each `service_pending` rise and each `svc_pend` rise, in order | fill, source, destination, count (upstream's `min()` formed from `svc_rem`), value | `svc_bad` |
| **R3** | once both sides are quiet (no service latched, pending or running) | the bytes [dest, dest + count) of every service since, in both cart RAMs | `svc_ram_bad` |
| **I1/I2** | the first edge where both inits are done, after a load or a console reset | cart RAM [0, `mapper_ram_size`); CDF: `pointer_ram`/`increment_ram` against the words in place | `init_bad` |
| ROM check | once, when the run starts | `fe_mem.fe_rom` against the image (first 32 KB) | `rom_bad` |
| **K1** | each `clk_arm` edge where the controller first shows RUNNING | the whole cart RAM | `ram_call_bad` |
| **K2** | each frame (every `+fe_full`), at the first E0 with `mapper_wb_idle`, no pointer write-back in flight and no service | the whole cart RAM and the CDF tables | `ram_frame_bad` |
| **T1** | every clock | `u_audio.tick` against `audio_tick` (and `accum`) | `tick_bad` |
| **T2** | every clock (stricter than "at each tick") | counters and frequencies, outside the merge window (M, M_fe] of a CDF call without the hook | `audio_bad` (`merge_race` only within 2,000 clocks of a `ret_late`); `rmw_merge` (the merge after an `rmw_seed`, counters only; section 8.3); `ticks` counts the ticks compared |
| **T3** | each refresh | dispatch → IDLE, both engines; NOTE capture offset | `FE latency:` histograms |
| **T4** | each remote sample request of `u_fe` | its address against upstream's `digital_address` | `dig_bad` |
| **A1** | every clock | `ft_a1_tick` (accum, tick, NOTE latch: never masked), `ft_a1_cf` (counters, frequencies), `ft_a1_rep` (one-hot state against the enum, `rc`, `rp`, `np`, voice, sum, shift, offset, digital registers, AMPLITUDE, request, address, grant) | `audio_bad`, `tick_bad` |
| **A2** | every clock, scheme 21/23 | `sel_up` against `cart2600.sel_ram_sel` | `a2_bad` |
| **A3** | every clock | `own_r`/`own_s`/`own_a` one-hot-or-zero, `a_owner`, and `crb_use` = last clock's (fixed use with `cr_fix_use`) \| P32 \| audio | `a3_bad` |
| **O1** | at the `pclk1` after each shown cartridge read | each side's byte against its latched value; and at every passing read latch, top.sv's `read_DB` rebuilt with `u_fe`'s byte and a shadow open bus against `dut.read_DB` | `drift_up`, `drift_fe` (information), `obus_exposed` |
| **H1** | every clock while running | section 2 | `hold_bad` |
| **W1** | each upstream pointer capture | `pointer_ack_sync2 != pointer_toggle` | `wb_drop` |
| RTL assertions (9.6) | every clock | `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr`, `a_owner`, `a_fpjr`, `a_pend_late`, `a_tdef2`, `a_f6_live`; `ev_ret_unasked` | one counter each; `a_p32_late` in a 6507 cycle in which `rst_fe` was high is counted as `p32_reset` (lane A O-1, lane D issue 1) |
| `det_lock_a` | every clock | `u_guard.locked` in mode A | `det_lock_a` |
| bench self-checks | | the mirror byte against `cart_q` whenever both read one byte (`rom_bad`), `write_DB` (`din_bad`), the completion prediction (`ret_model_bad`) | |

## 4. The classes (design 9.5) as implemented

An audio class masks the replica's registers (and, where noted, the counters and frequencies) from its own edge on. At the next falling edge where both engines are quiet (both IDLE, no refresh or NOTE pending, no `tdef`, no `mwin`, no sample in flight, not inside a merge window), `fe_deposit_audio` copies upstream's state into `u_audio` and the comparison resumes (`resync`; `deposit_cf` when counters were deposited too). An `audio_bad` resyncs the same way and stays a failure.

| Class | Condition in the bench | Masks |
|---|---|---|
| `short_phase1` | `u_seq.ev_short`; its effects: `short_dout` (L1 in a cycle with E0→latch < 6), `q26` (C3 after such a cycle), `grant_steal` (`u_arb.ev_grant_steal`) | grant offset: replica, counters, frequencies |
| `merge_amp` | CDF, no hook: a refresh dispatched (either side) at an edge in (M, M_fe+1] | replica |
| `ret_late` | `u_fe`'s `call_tog` flip later than upstream's completion of that call number | allows `merge_race` for 2,000 clocks |
| `dig_rom_lag` | upstream's ROM sample request R with `digital_address` ≥ $8000, or `sample_done` not high before R+4 | replica |
| `svc_audio_race` | an audio grant reading a word of a running service's destination range (either side) | replica |
| `pause_lane` | an audio grant with `pause` high (tb_daria ties `pause` to 0; lane B: unreachable) [Decided, F1_fixes.md 2: reachable; now a sample capture on an unpaused edge right after a paused upstream grant edge whose last unpaused edge had `sel_ram_sel` high, with the two lane registers differing; any other lane difference at a capture is `audio_bad`] | replica [now the sum and AMPLITUDE only, until they agree again; no resync] |
| `pre_lock` | an upstream audio grant while `!tia_en` and out of reset | replica |
| `tbl_alias` | `u_core.ev_tbl_alias` (CDFJ+ DSWRITE into the tables); that stream is excluded from C3, its fetches' L1 and the RAM compares | |
| `rmw_call` | `u_call.ev_rmw_call`; R1's call-2 seed difference `rmw_seed`; the call-2 merge difference `rmw_merge` | counters (resync) |
| `rmw_svc` | `u_core.ev_rmw_svc` | |
| `size_over32k` | `u_audio.ev_size_hi`, or upstream's SIZE address above 32 KB | replica |
| `short_image` | DPC+ image shorter than 32 KB (information; one image per run here) | |
| `drift_fe`, `drift_up` | O1 (information) | |
| `p32_reset` | section 3, assertions | |
| `live_override`, `refresh_overlap` | not implemented: tb_daria never changes the scheme without a load, and lever 1 (drop `rc`) is not taken (lane B) | |

## 5. Results

### 5.1 Mode A, 120 frames (final binary)

`FE=1 DTRACE=0 +frames=120 +snap=0 +fire_at=40 +play_at=70`, with and without `+fe_merge_hook=1`. Runs: `sim/work/bupchip/daria/runs/fe_e1/final/`.

| Run | Scheme | Hook | Latches (of them reads) | Commits | Calls (K1) | Services (R3) | Ticks compared | C3 / C4 writes | Frames (K2) | Bad (must be 0) | Classes | Reference dout/state | Wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SF2fix_NTSC | DPC+ rev 0 | 0 | 2,374,359 (2,105,100) | 2,089,318 | 165 (165) | 0 | 39,798 | 0 / 1,488 | 119 | 0 | none | 0/0 | 455 |
| SF2fix_NTSC | DPC+ rev 0 | 1 | 2,374,359 (2,105,100) | 2,089,318 | 165 (165) | 0 | 39,798 | 0 / 1,488 | 119 | 0 | none | 0/0 | 454 |
| Galagon | CDFJ | 0 | 2,431,863 (2,117,829) | 1,948,492 | 239 (239) | 0 | 40,757 | 148,581 / 1,912 | 119 | 0 | `merge_amp` 5, `resync` 5 | 0/0 | 376 |
| Galagon | CDFJ | 1 | 2,431,863 (2,117,829) | 1,948,492 | 239 (239) | 0 | 40,762 | 148,581 / 1,912 | 119 | 0 | none | 0/0 | 376 |
| draconian RC8 | CDF1 | 0 | 2,372,614 (2,278,300) | 2,263,420 | 239 (239) | 0 | 39,765 | 25,830 / 599 | 119 | 0 | `merge_amp` 4, `resync` 4 | 0/0 | 361 |
| draconian RC8 | CDF1 | 1 | 2,372,614 (2,278,300) | 2,263,420 | 239 (239) | 0 | 39,769 | 25,830 / 599 | 119 | 0 | none | 0/0 | 360 |
| Stratovox (`champ_presents/arm`) | DPC+ rev 0 | 0 | 2,377,684 (2,077,839) | 1,924,205 | 90 (90) | 5 (5) | 39,854 | 0 / 10,996 | 119 | 0 | none | 0/0 | 358 |

Columns: latches and commits are the 6507 bus cycles L1 and C1/C2 compared from the start of the checks (frame 0, after upstream's init); "Calls (K1)" is the calls compared by R1 (payload, return words, `ret_tog`) and, in brackets, the call starts at which K1 compared the whole cart RAM; "Services (R3)" is the DPC+ services compared by R2 and, in brackets, those whose RAM ranges R3 compared; "Ticks compared" are T1 audio ticks; C3 is CDF pointer writes, C4 the 6507's writes into cart RAM; K2 is the whole cart RAM compared at each frame boundary (120 frames run, 119 boundaries after the checks start). "Bad" is the total of every must-be-0 counter of the `FE bad:` line (41 counters; section 3 says what each checks); every one is 0 in every run. Every run also has `I1/I2` 1 (the init image, `init_bad` 0), `hidden_last_bad` and `commit_on_hidden` 0, `obus_exposed` 0 (O1), `hold_bad` 0 (H1) and `E0->latch` 6..6. "Reference" is the stage-0 reference's dout/state beside `u_fe` in the same run.

Per image:

- **SF2fix_NTSC.** The hook does not apply to DPC+ (no merge), and the two runs are byte-identical (`fe.csv`, `frames.csv`, `summary.txt`). 32,317 AMPLITUDE reads compared (music mode), 357 NOTE captures with `u_fe`'s capture on upstream's clock (offset 0), 2,242 DFxLOW pointer writes, 56,271 hidden pclk0 (0 differ).
- **Galagon.** Without the hook, 5 of the 239 merges land a tick in (M, M_fe] (`merge_amp`), each followed by a resync of `u_fe`'s audio state at the next quiet point after the window (`resync` 5), with nothing left behind: the five ticks that land in that window are classed instead of compared, hence 40,757 against 40,762 ticks with the hook. With the hook M_fe = M (`merge M_fe - M {0:239}` against `{6:239}`) and no class occurs. 148,581 pointer writes (C3); fast jumps active on 32,424 E0s.
- **draconian RC8.** The same picture: `merge_amp` 4 without the hook, 0 with it. 7,735 AMPLITUDE reads, digital audio mode on 2,369,883 E0s, 39,724 digital refreshes, all through the cart RAM window (section 5.2).
- **Stratovox.** 5 DPC+ copy services in frame 47 (173, 173, 173, 173 and 86 bytes): R2 (the service words) and R3 (the destination ranges) match; the hold forced the 6507's stall for 1,008 clocks with H1 at 0 (section 7 on the engine's speed). It is also the only image here that switches banks (468 hotspot reads; upstream's bank differs from its reset value on 1,478,753 E0s).

The hook leaves the DUT alone: for each of the three images run both ways, `frames.csv`, `summary.txt` and `calls.csv` are identical with and without `+fe_merge_hook=1` (the hook only changes `u_fe`).

### 5.2 What the image set exercises, and what it does not

| | SF2fix | Galagon | draconian | Stratovox |
|---|---|---|---|---|
| Scheme | DPC+ rev 0 | CDFJ | CDF1 | DPC+ rev 0 |
| Fast fetch on (of the checked E0s) | 2,371,614 of 2,374,359 | 2,369,564 of 2,431,863 | 2,369,883 of 2,372,614 | 1,060,790 of 2,377,684 |
| `fast_pending` set at E0 | 1,205,984 | 170,150 | 304,898 | 160,802 |
| Bank switching (hotspot reads; E0s with the bank off its reset value) | 0; 0 | 0; 0 | 0; 0 | 468; 1,478,753 |
| CDF fast jumps (E0s with `jump_remaining` != 0) | - | 32,424 | 0 | - |
| Pointer writes: CDF (C3) / DPC+ DFxLOW | - / 2,242 | 148,581 / - | 25,830 / - | - / 1,367 |
| 6507 writes into cart RAM (C4) | 1,488 | 1,912 | 599 | 10,996 |
| Read latches with a RAM byte | 103,883 | 145,953 | 24,753 | 130,668 |
| Hidden pclk0 (0 differ in every run) | 56,271 | 82,187 | 7,413 | 28,034 |
| Calls / CDF merges (own path without the hook, through the hook with it) | 165 / - | 239 / 239 | 239 / 239 | 90 / - |
| Services (copy / fill / RMW) | 0 | - | - | 5 / 0 / 0 |
| Clocks of the 6507 stall forced by the hold | 0 | 0 | 0 | 1,008 |
| AMPLITUDE reads | 32,317 | 0 | 7,735 | 0 |
| NOTE captures (fe - up offset) | 357 (0) | 0 | 0 | 0 |
| Digital audio refreshes (all through the cart RAM window) | 0 | 0 | 39,724 | 0 |
| RSYNC writes | 2 | 1 | 2 | 2 |

**What the set does not exercise**, so the checks behind these stay at 0 because nothing tries them (each is covered elsewhere where noted):

- **No ROM route for digital audio.** draconian's 39,724 digital refreshes all read the cart RAM window (`FE digital:` line: ROM below 32 KB 0, ROM above 32 KB 0), so `dig_rom_lag` cannot occur and `u_fe`'s sample port is never used in these runs. Design 12.5 item 2 expected `dig_rom_lag` on draconian; it does not happen in its first 120 frames.
- **No DPC+ fill, no RMW service, no RMW call, no `svc_audio_race`, no `rmw_merge`.** Only Stratovox makes services, five copies in one burst. Lane E2's `dpc_svc` (216 services, every clamp, 6 RMW pairs) and `rmw_call_cdf` cover them with this bench (section 5.3).
- **No `ret_late`, no `merge_race`, no `seed_race`, no `note_race`** in any run, so the masks and resyncs behind them are tried only by the injections (section 6) and E2's tests.
- **No console reset after the checks start** (`FE resets: 0`), so `p32_reset`, the hold after a reset and I1 on a reload are not exercised here; `+hard_reset_at` once per scheme is open (section 9).
- **No CDFJ+ and no DPC+ revision 1** in this run list (no `tbl_alias`, no `size_over32k`, no `short_image`); spacerocks_Harmony_fix and the revision-1 games of `champ_presents/arm` were not run by this lane.
- **No fast-jump operand substituted at `$1FFF`** (`obus_exposed` 0; E2's `cdf_jump_ffe` is that case, section 7).
- **E0 -> latch is 6 on every checked cycle** (`FE S1: 0`), so `short_phase1`, `grant_steal`, `q26` and `short_dout` are never reached in tb_daria (section 9, question 3).
- **`u_guard`'s mode-A lock count is 0 clocks** in every run (`FE counts:` line).

### 5.3 Other builds

Every row here and the `FE_STAGE0=1` run of 5.4 were rebuilt and rerun from the final sources; their counts are the same as in their first runs, before the last bench edits.

| Build | Run | Result |
|---|---|---|
| `FE=1 FE_POISON=1` (the poisoned `daria_ram`: a partial-write read-back and a same-step mixed-port read show $A5) | Galagon, 60 frames (`runs/fe_e1/poison/GAL`) | PASS: 1,237,143 latches, 119 calls, every bad count 0, `merge_amp` 2 / `resync` 2. The poison build contains the model (`pz_a` in its classes), `obj_fe` does not |
| `SHADOW=1 WIN_KB=64 FE=1` (DARIA's CPU and `daria_fe` both beside upstream; two `daria_mem`s) | Mappy, 40 frames (`runs/fe_e1/reg/shadow64_fe_Mappy`) | "DARIA shadow: 79 calls compared, 0 differ"; `daria.csv` and `frames.csv` byte-identical to stage 0's `SHADOW=1 FE=1` run (`runs/fe_check/reg_shadow64_fe_Mappy`); FE stage 1 PASS (780,383 latches, 79 calls, `merge_amp` 1, `resync` 1) |
| `FE=1`, lane E2's directed tests `dpc_svc` and `rmw_call_cdf` (synthetic images, `FLAVOR=e1chk`) | final sources (`sim/work/bupchip/daria/fe_dir/e1chk/results.txt`) | both PASS. `dpc_svc`: 216 services (copy, fill, every clamp, 6 RMW pairs), 216 R3 compares, 11,747 clocks of forced stall, H1 0, `svc_audio_race` 25 and `rmw_svc` 6 classed. `rmw_call_cdf`: 3,073 calls, `rmw_call` 1,536, `rmw_seed` 2, `rmw_merge` 2, `merge_amp` 29 |


### 5.4 Regressions

Nothing that existing builds compile changed:

- **Preprocessed sources.** `verilator -E` of `tb_daria.sv` (with every include) before my edits (commit `fa36bf7`) and after: for the plain build, `SHADOW=1 WIN_KB=64` and `SHADOW=1 WRAPPER=1 WIN_KB=64` the output has the same 1,063 / 1,569 / 1,569 lines and differs in one place only, a space before a `;` (the inline `` `ifdef `` of the reset term). So those binaries are the same code and `$finish` keeps its line number.
- **Plain build**, SF2, 8 frames (`runs/fe_e1/reg/plain_SF2`): `frames.csv`, `calls.csv`, `summary.txt`, `slack.csv`, `zero.csv` and `run.log` (less the time lines) identical to stage 0's `runs/fe_check/plain_SF2`.
- **`FE_STAGE0=1`** (the reference-only bench), SF2, 8 frames (`runs/fe_e1/reg/s0_SF2`): `fe.csv` identical to the first frames of stage 0's final run (`runs/fe_check/final_SF2`); `frames.csv`, `calls.csv`, `summary.txt`, `slack.csv`, `zero.csv` identical to stage 0's `base_SF2`; dout/state and every tap check 0. Its preprocessed source differs from stage 0's only by `fe_hold_reset` (always 0 in this build) and a split line.
- **The stage-1 runs leave the DUT alone.** On all three stage-0 images the hold does not delay the console's release (upstream's init is the longer one: SF2 F6 ends at clock 80,072, upstream's init at 83,187), and SF2's `frames.csv` is identical to the plain run's. A stage-1 run's DUT timeline is therefore the plain run's, and the stage-0 reference beside `u_fe` reports 0 in every stage-1 run (`FE reference:` lines).
- The step-5 batch (`SHADOW=1 WIN_KB=64`, `obj_shadow64`, `runs/shadow64/`) was not touched; `run_daria.sh` and `run_all.sh` were replaced by rename while it ran.


## 6. Self-test: injected faults (`+fe1_inj=K`)

Each run injects one fault at checked cycle 30,000 (5 frames), on the final binary. Images: SF2 (DPC+) and Galagon (CDFJ), and draconian (CDF1) for fault 10.

| K | Fault (at the first eligible clock from checked cycle 30,000) | SF2 (DPC+) | Galagon (CDFJ) | First message (abridged) |
|---|---|---|---|---|
| 1 | `u_core.fe_do` bit 0 flipped on a cartridge read, before the 6507 latches | `dout_bad` 1 | `dout_bad` 1 | L1 dout (bit 0 differs), 1 clock later |
| 2 | `u_audio.counter[0]` + 1 at a quiet point | `audio_bad` 1 | `audio_bad` 1 | A1 counters/frequencies: counter[0] |
| 3 | `u_core.fpend` inverted in phase 2 (after the commit) | `state_bad` 1 | `state_bad` 1 | C1 (C2) state: fast_pending, at the next E0 |
| 4 | `fe_mem` cart RAM word $100 inverted | `ram_call_bad` 3, `ram_frame_bad` 2 | `ram_call_bad` 9, `ram_frame_bad` 4 | K1: cart RAM word $0100 at the next call start |
| 5 | DPC+: `fe_mem` state word 0 (fetcher 0's counter) + 1; CDF: fetcher 0's pointer word in cart RAM + $0010_0000 | `state_bad` 13,009 | `ram_call_bad` 2, `ram_frame_bad` 1 | C1 state: counter[0] one above upstream's / K1: cart RAM word $0026 |
| 6 | `u_audio.amplitude` inverted at a quiet point | `audio_bad` 1 | `audio_bad` 1 | A1 replica: amplitude |
| 7 | `u_core.bank` + 1 | 107,844 (`dout_bad`, `state_bad`, `a2_bad`, `amp_lag`, `obus_exposed`, `hidden_last_bad`, `audio_bad`) | 223,933 (the same, plus `ptr_bad`, `ram_call_bad`, `ram_frame_bad`) | A2: sel_up 1, sel_ram_sel 0 / L1 dout, 2-6 clocks later |
| 8 | `u_copy.dma_busy` forced high for 200 clocks with no service (tests the hold, not a check) | PASS, 201 clocks of forced stall, H1 0 | PASS, 201 clocks, H1 0 | none: H1 sees the forced stall follow `u_fe`'s busy on every clock |
| 9 | posted word F5 (call payload) bit 8 flipped when the post completes | `call_bad` 1 | `call_bad` 1 | R1: call N posted ..., the next clock |
| 10 | CDF only: return word FB + 1 while `u_call` reads the returns | - | `audio_bad` 1 (draconian: `audio_bad` 1) | A1 counters/frequencies: freq[0], at the merge |

Every fault is caught by the check meant for it, at the first clock it can be seen, and nothing else fires except where the fault spreads (7 moves every fetch; 5 on DPC+ moves the fetcher on every later read of it). Runs: `sim/work/bupchip/daria/runs/fe_e1/inj/<image>_<K>/` (the first two failures of each class are in `fe_err.txt` with their ring dumps).

## 7. Findings about `daria_fe`

**No RTL issue from the image runs.** Over the 7 runs of section 5.1, every 6507 latch, every scheme register after every cycle, every pointer and RAM write, every call payload, service and return, the init image, the whole cart RAM at every call start and every frame, and every audio register on every clock match upstream, except where a class of design 9.5 says they may not; `docs/daria_fe/lanes/E1_rtl_issues.md` is therefore not written.

**One behaviour that differs on the bus (found by lane E2's `cdf_jump_ffe`, through this bench's O1):** a CDF fast-jump operand substituted at `$1FFF`, followed by the operand read that wraps to `$0000` (TIA, D7-D6 driven only). Upstream's `d_out` falls back to the ROM byte after the commit and the open bus holds it; `fe_do` holds the substituted byte (design 2.4), so the TIA read's D5-D0 differ: `obus_exposed`, which design 9.6 lists as must-be-0. It is design behaviour, not an RTL slip, so it is the lead's call (E2 report 6.1 gives the options: document it, or reload `fe_do` with the mirror byte at C+1 after a substituted read at `$xFFF`). No image in the set does it (`obus_exposed` 0 in every run here). [Decided, F1_fixes.md 3: accepted (option (a)). That one read is counted as `obus_ffe`, only after a fast JMP's low operand at $1FFF and only with the values this case leaves on both sides; a fast `LDA #` at $1FFE is not in the class, since it exposes $0001 too.]

**Observations for the lead (not failures):**

- **DPC+ copy speed.** On Stratovox, `daria_fe`'s engine takes 218-221 clocks for a 173-byte copy where upstream's DMA takes 156-161 (110 against 85 for 86 bytes). With the hold, the 6507 is held about 60 clocks longer per service (1,008 forced clocks for 5 services). On hardware that is the `dma_len` difference design 9.5 counts for mode B; whether the game's kernel tolerates it is a timing question for step 7.
- **Call release.** `u_fe`'s `arm_call_busy` falls 8-14 clocks after upstream's X for a CDF call without the hook (REL waits for M_fe and `rel_ok`), 2-8 with the hook, and 1-7 for DPC+. Mode A never uses it to stall (design 8 limitation 1); it is the `call_len` of mode B.
- **draconian's digital audio never takes upstream's ROM route** in these frames (`FE digital:` line, section 5.2), so `dig_rom_lag` cannot occur there, against design 12.5 item 2's expectation ("except `dig_rom_lag` (draconian only)").


## 8. Bench bugs found and fixed

**8.1 The download's edges seen by the bench (mine).** tb_daria writes `cart_download` with a blocking assignment in its `initial` block right after an `@(posedge clk_sys)`. bench.md 1.3 assumes every clocked block sees the same value in that time step. In one build of this file it did not: a block that ran before the write saw the old level while tb_daria's `old_cart_download` flop ran after it, so the `old && !cart_download` pulse never reached that block, and I1 never armed (`0 inits` in four runs). The bench's own blocks (the `cart_win` emulation, the hold, the I1/I2 arming) now take the download's edges from the `cart_download` level through a private copy, which sees each edge exactly once whatever the order; `u_fe`'s `load_start`/`load_end` stay the DUT's expressions, as bench.md asks. The run log now shows both views ("FE load:" and "FE init: u_fe saw load_end at ..."): in every run here `u_fe` saw it on the bench's edge. See question 1 of section 9 for the remaining risk.

**8.2 R3 on a burst of services (E2 issue 2).** R3 paired the n-th upstream DMA fall with the n-th `u_copy.run` fall. In an RMW pair (`INC $105A`: a copy, then a fill latched while it runs, into one range) `daria_fe` finishes both before upstream finishes the first, so service 1's range was compared while one side already held the fill (`svc_ram_bad`). R3 now waits until both sides are quiet (nothing latched, pending or running) and then compares every range of the burst. `dpc_svc` passes (216 services, 216 compares).

**8.3 The merge after an `rmw_seed` (E2 issue 3).** When a tick lands on upstream's M of call 1 of a CDF RMW pair, call 2's seeds differ by that tick (`rmw_seed`, design 9.5 `rmw_call`). In mode A call 2's returns come from upstream's ARM, which got upstream's seeds: a voice it leaves alone returns upstream's seed; upstream keeps its counter (return = seed), `u_fe` compares the return with its own seed and takes it. The bench counted that as `audio_bad`. It is now the class `rmw_merge`: at the first compare after call 2's merge window, counters only (frequencies must match), then resynced. It is mode-A-only (in mode B DARIA's ARM returns DARIA's seeds). `rmw_call_cdf` passes (`rmw_seed` 2, `rmw_merge` 2).

**8.4 The hold injection (self-test only).** Fault 8 forces `u_copy.dma_busy` at a falling edge. When the hold's own falling-edge block ran first in that time step it saw the busy low, so the stall was forced one clock late and H1 reported it. The injection now applies the hold's force itself; the hold's real path (a busy that rises at a posedge) never had the problem.


## 9. Deviations from the specification, and open questions

**Deviations from the specification (each deliberate):**

| Where | Specification | Here | Why |
|---|---|---|---|
| bench.md 1.3 | derive `load_start`/`load_end` from the DUT's expressions, no re-timing | `u_fe` gets them so; the bench's own bookkeeping uses the `cart_download` level | section 8.1 |
| T2 | compare at each tick edge (except a tick in (M, M_fe+1], at M_fe+2) | counters and frequencies every clock outside (M, M_fe] | stricter; equal by design 5.6 |
| R3 | when both copies are done | when both sides are quiet; every range of a burst | section 8.2 |
| 9.5 `rmw_call` | stall shape; CDF call-2 seeds | plus `rmw_merge`, the call-2 merge in mode A | section 8.3; the lead may fold it into 9.5 |
| 9.5 `pause_lane` | a grant edge with `pause` high and the capture clock low | a grant with `pause` high | tb_daria ties `pause` to 0; lane B showed it unreachable [Decided, F1_fixes.md 2: the bench now counts the exact case, section 4] |
| 9.5 `tbl_alias` | until the ARM rewrites the word | until the end of the run | never occurs in the set (no CDFJ+ image here); simpler |
| `live_override`, `refresh_overlap` | classes | not implemented | the scheme never changes without a load in tb_daria; lever 1 not taken |
| fe.csv | BEN 7.7's columns plus 12.4's | those, in that order, then every other counter of the bench (the full list is the header) | one table drives the csv, the `FE bad:` and `FE classes:` lines |

**Open questions:**

1. **The `cart_download` race (section 8.1).** `u_fe`'s and the DUT's own load pulses still depend on Verilator running tb_daria's `initial` write before the clocked blocks of that time step. If a future build ordered `u_copy`'s block first, `u_fe` would miss `load_end`, F6 would never start, and the hold would keep the console in reset (a hang, not a silent pass). A robust fix is in tb_daria (change `cart_download` by NBA, or away from the clock edge), but it moves the load by a clock in every build, so plain and `SHADOW` runs would need new baselines. Lead's decision.
2. **E2's issue 1** (`obus_exposed` after a substituted read at `$1FFF`): accept and document, or change `fe_do` (section 7). [Decided, F1_fixes.md 3: accepted, counted as `obus_ffe`.]
3. **`short_phase1` and RSYNC.** No image and no directed test (E2 section 5) produces an E0→latch < 6 in tb_daria, so `short_phase1`, `grant_steal`, `q26` and `short_dout` are exercised only by the unit benches. A bench option that forces a misaligned TIA divider would be needed to see them here.
4. **Coverage gaps of the image set** (section 5.2): no digital audio through the ROM route (so no `dig_rom_lag`), no CDFJ+ or DPC+ revision 1 in this run list, no DPC+ fill or RMW service, no `ret_late`, no console reset after the checks start. E2's directed tests cover most of them; `+hard_reset_at` once per scheme (design 12.2 step 7) is still to run.



## Verification

An adversarial check of this lane on 2026-10-08, against the RTL as committed (`906ea8f`, lanes A-D done) and this lane's files as the report above describes them. Method: RTL faults in scratch copies of `daria_fe_{seq,core,audio,call,copy}.sv`, each gated by a run-time plusarg (`+emut=K +emut_n=N`, off by default, so one build holds them all; a `$display` confirms that each fault actually fired), run through `run_daria.sh FE=1` on the game images and on lane E2's synthetic directed images; the same faults built once more against this lane's bench as it was before this check, to show which ones it missed; and a read of the bench for vacuous comparisons, pre-edge sampling, classes that mask failures, and resyncs that hide them.

### V.1 Verdict

**The bench is sound and can fail, after eight fixes to `fe_shadow.svh` (V.3).** Before them, five kinds of real RTL fault passed it with every bad count 0. Each was demonstrated with the bench as the lane left it:

| Fault (scratch RTL) | Bench as left (`e1v_orig`) | Fixed bench |
|---|---|---|
| m18: `arm_dma_busy` falls while the copy engine still runs | PASS (`dpc_svc`; Stratovox 50 frames) | FAIL: `dma_cover` 10,305 / 983 |
| m12: a third `ret_tog` synchroniser flop, so `M_fe` = M+7 | PASS (Galagon 30 frames) | FAIL: `merge_late` 59 (every merge) |
| m25: the RMW pair's second post has F2 (counter 0) + $100 | PASS (`rmw_call_cdf`: all 1,536 classed `rmw_seed`) | FAIL: `call_bad` 1,536 |
| E2's M17: the sample byte not forced to $FF in a pause | PASS in 5 of 6 pause tests (E2 V.5 item 1) | FAIL in 6 of 6 (`audio_bad` 3-20) |
| E2's M31: the remote (>= 32 KB) sample byte, bit 7 flipped | PASS in 4 of 5 digital tests (E2 V.3) | FAIL in 5 of 5 (`dig_val_bad` 45 each) |

With the fixes, every game run and every directed test that passed before still passes (V.4): no fix found a failure in the real `daria_fe`. **No RTL bug was found**, so `E1_rtl_issues.md` is still not needed. The lane's claims hold: the 7 mode-A runs of section 5.1 reproduce exactly (the first 30 columns of each `fe.csv` are byte-identical to the lane's), the self-test injections still behave as section 6 says (8: PASS with 201 forced clocks; 10: `audio_bad` 1), and the plain, `SHADOW=1` and `FE_STAGE0=1` builds are untouched (V.5).

### V.2 Faults injected (23 own RTL mutations and 3 of lane E2's; every one caught except m10 on voice 2, which no input can show)

Each row is one run of the fault on the image named; "first" is the first failure in `fe_err.txt`. Counts are the bench's must-be-0 counters (the `FE bad:` line). Images: SF2 (SF2fix_NTSC, DPC+), GAL (Galagon, CDFJ), DRA (draconian RC8, CDF1), STR (Stratovox, DPC+ rev 0); `dir:` is lane E2's synthetic image of that name (game-free, mode A).

| Id | Fault | Run | Caught by (first) | Counts |
|---|---|---|---|---|
| m01 | **wrong `fe_do` byte**: the 3000th RAM data byte loaded into `fe_do` has bit 2 flipped | SF2 30, GAL 30 | L1, at that latch | `dout_bad` 1 (exactly one) |
| m02 | **late commit** by 1, 3 or 6 clocks (`u_seq.commit` delayed) | SF2 20, GAL 20 | A2 (`sel_up` against `sel_ram_sel`), first frame; 6 clocks: C1 / C3 at the next E0 | 1 clk: `a2_bad` 3,098 / 6,643, `tick_bad`, `audio_bad`, `a_collide`; 6 clk: `state_bad` 380k, `a_pend_late` 211k, `a_wb_late` 379k, `dout_bad`, `ptr_bad`, K1/K2 |
| m03 | **wrong state RAM field**: DFxBOTTOM writes the TOP lane of w0 | `dir:dpc_regs` | C1 `top[0]` | `state_bad` 12,119, `dout_bad` 180 |
| m04 | DFxFRACINC does not clear the fraction's low lane | `dir:dpc_regs` | C1 `fractional[4]` | `state_bad` 10,298, `dout_bad` 45 |
| m22 | DFxLOW writes the HI lane | SF2 30 | C1 `counter[0]`, first frame | `state_bad` 579k, `dout_bad`, `ram_bad`, K1/K2 |
| m05 | **wrong pointer write-back**: the 3000th CDF write-back has bit 12 (fraction) flipped | GAL 30, DRA 30 | C3, at that write | GAL `ptr_bad` 1, K2 1; DRA `ptr_bad` 27, K1 2, K2 1 |
| m06 | the 3000th CDF fetch's write-back goes to stream idx + 1's word | GAL 30 | C3 `pointer[6]` | `ptr_bad` 23, `dout_bad` 18, K1/K2 |
| m07 | **missed tick**: the counters and the refresh miss tick 3000 (no add, `rp` not set) | SF2 30, GAL 30 | A1 (counters, or `rp`) at that tick | `audio_bad` 1 each (then resynced) |
| m08 | the tick strobe one clock late (tick 3000) | SF2 30 | T1 `tick` | `tick_bad` 2 |
| m09 | **wrong merge**: voice 1's frequency loaded from voice 0's return | `dir:rmw_call_cdf`, `dir:digital_cdfj` | A1 `freq[1]` at M_fe+2 | `audio_bad` 3,073 / 7 |
| m10 | the own merge never takes voice N's counter | N = 0: `dir:rmw_call_cdf`; N = 1: `dir:hard_reset_frame_cdfj` | A1 `counter[N]` at M_fe+2 | `audio_bad` 1,847 / 6; N = 2: see below |
| m25 | wrong RMW second-call seeds (F2 + $100) | `dir:rmw_call_cdf` | R1 (only after fix 3) | `call_bad` 1,536 |
| m13 | **wrong post word**: F1 (stack) $40001FF8 for calls numbered $x5 | SF2 30 | R1, call 6 | `call_bad` 2 |
| m12 | the merge one clock late (third synchroniser flop) | GAL 30 | `merge_late` (only after fix 2) | `merge_late` 59 |
| m15 | **wrong F6 byte**: one copied byte (word $523 DPC+ / $123 CDF, bit 8) | SF2 5, GAL 5 | I1 at the end of init | `init_bad` 1, then K1/K2 |
| m16 | F6 fills one word with $80 (word $155 DPC+ / $355 CDF) | SF2 5, DRA 5 | I1 | `init_bad` 1, then K1/K2 |
| m17 | a DPC+ copy service stops one byte short | `dir:dpc_svc`, STR 50 | R3 | `svc_ram_bad` 12 / 5, `dout_bad`, K2 |
| m23 | a DPC+ fill writes value ^ 1 | `dir:dpc_svc` | R3 | `svc_ram_bad` 168, `dout_bad` 1,194, `audio_bad` 216 |
| m18 | `arm_dma_busy` falls while the engine runs | `dir:dpc_svc`, STR 50 | `dma_cover` (only after fix 1) | 10,305 / 983 |
| m20 | the 50th DFxPUSH/WRITE byte has bit 0 flipped | SF2 30 | C4, at that write | `ram_bad` 1, K1 1, K2 1 |
| m24 | the 10th DSWRITE byte has bit 4 flipped | `dir:dsw_cdfj` | C4 and L1 | `ram_bad` 1, `dout_bad` 1, K2 1 |
| m11 | the 3000th summed AMPLITUDE one too high | SF2 30 | A1 `amplitude` | `audio_bad` 1 |
| m21 | the 3000th digital pointer one too high | DRA 30 | A1 `dig_addr` | `audio_bad` 1 |
| E2 M17 | sample byte not forced to $FF in a pause | 6 pause tests | A1 (only after fix 5) | `audio_bad` 3-20 |
| E2 M31 / M32 | remote sample byte bit 7 / local sample lane | 5 digital tests | T5 (only after fix 6) | M31 5/5 (`dig_val_bad` 45); M32 4/5 (`digital_cdfjp` never samples lane 0, E2 V.5) |

What the game images cannot show (stimulus, not bench, limits; each fault is caught on a directed image above):

- **No game exercises the merge's values.** m09 and m10 pass on Galagon and draconian over 120 frames. On draconian a probe printed every own merge whose returned frequencies differ, and there is none; Galagon makes no AMPLITUDE read at all (section 5.2). The merge path is tried only by E2's `rmw_call_cdf` and `digital_*`.
- **m10 on voice 2 is invisible everywhere**: no ARM script (E2's scripts `FADD` r8 in `rmw_call_cdf` and r9 in the `_busy_cdf` images, never r10) and no game changes counter 2 in a call, so the take of voice 2 is never exercised (the fault is equivalent on every input available).
- SF2 writes no DFxBOTTOM or DFxFRACINC in its first 30 frames (m03, m04 caught on `dpc_regs`).
- A one-clock late commit is caught here only by the every-clock oracles (A2, T1's NOTE latch), not by L1: it stays inside the 6507's latch slack, as stage 0 found.

### V.3 Fixes (all in `sim/bupchip/daria/fe_shadow.svh`, stage-1 block only)

1. **`dma_cover` (new, must be 0).** H1 checked that the hold follows `u_fe.arm_dma_busy`, but nothing checked that the busy covers `u_fe`'s engine (design 7.4: held while a latch is pending or the engine runs). In mode A upstream's DMA stall usually covers `daria_fe`'s too, so a busy that falls early was invisible (m18). Now every clock: `(u_copy.run | u_core.svc_hold) & !arm_dma_busy`, outside init and reset, is a failure.
2. **`merge_late` (new, must be 0).** The CDF merge window (M, M_fe] is `u_fe`'s own: the bench opened it at upstream's M and closed it at `u_fe`'s `cp_apply`, accepting any `M_fe` up to 64 clocks later, and the window masks counters and frequencies. A late merge was therefore invisible (m12) and would only have raised `merge_amp`. Now `M_fe - M` must be design 5.6's 6 (F5), except within 2,000 clocks of a `ret_late`.
3. **`rmw_seed` bounded to one tick.** R1 classed any seed difference of a post flagged by `u_call.ev_rmw_call` (a `daria_fe` event) as `rmw_seed`, so wrong RMW second-call seeds passed (m25). Design 9.5 allows only one tick's add; anything else is now `call_bad`.
4. **`rmw_merge` bounded to k ticks.** The merge after an `rmw_seed` was classed whenever the frequencies matched, whatever the counters. Now each counter must be `daria_fe`'s plus k ticks (0 <= k <= 4096) of call 2's payload frequency (upstream keeps its counter for a voice the ARM left alone, `daria_fe` takes the returned seed). `rmw_call_cdf` keeps its 2 `rmw_merge` (an earlier draft used the current frequency and failed it: the frequency during call 2 is the payload's).
5. **`pause_lane` narrowed to lane B's condition** (E2 V.5 item 1; B_audio.md B-1): only a paused grant whose last unpaused edge had `sel_ram_sel` high. The old condition masked and resynced every grant in a pause (9-92 per pause test), hiding M17. Now 0 in all six pause tests on the real RTL.
6. **T5: ROM-sample amplitudes compared (new `dig_val_bad`, must be 0)** (E2 V.5 item 2). `dig_rom_lag` masks the replica and deposits upstream's state for every remote sample, so the sample-port data path was never compared (M31). Every amplitude written from a ROM sample, upstream's (`AUDIO_ROM_WAIT & rom_done`) and `daria_fe`'s (`am_rom`), is now paired in order with its sample address; one dispatched in (M, M_fe+1] or before `tia_en` is counted (`dig_val_merge`), not compared. The digital directed tests compare 164-165 each, 0 differ.
7. **`amp_class` no longer granted for the bare merge window.** An AMPLITUDE read that differed was classed (not failed) whenever the merge window was open, though AMPLITUDE can only differ there through a `merge_amp` refresh, which sets the mask itself. Now only under a mask.
8. **Mask durations: `mask_stuck` (new, must be 0) and the `FE masks:` line.** A class mask that never met a quiet point would have left A1's replica comparison off for the rest of the run, silently. A mask held longer than `+fe_mask_max` clk_sys (20,000; the longest seen in any run is 18) now fails; the line reports the clocks masked and the longest mask.

The header documents the additions; the new counters are columns at the end of `fe.csv` and items of the `FE bad:` line (45 must-be-0 counters now), which `dynamic_tables.py --only fe` reads unchanged. The `FE digital:` line adds T5's counts. No other file of the lane was changed.

### V.4 Results with the fixed bench

Mode A, 120 frames, `+fire_at=40 +play_at=70`, real `daria_fe` (`sim/work/bupchip/daria/e1v/runs/final/`):

| Run | Scheme | Latches | Commits | Calls (K1) | Services (R3) | Ticks | C3 / C4 | K2 | Result | Classes | Reference dout/state | Longest mask | Wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SF2_nohook | DPC+ rev 0 | 2,374,359 | 2,089,318 | 165 (165) | 0 | 39,798 | 0 / 1,488 | 119 | PASS (0 bad) | none | 0/0 | 0 | 383 |
| SF2_hook | DPC+ rev 0 | 2,374,359 | 2,089,318 | 165 (165) | 0 | 39,798 | 0 / 1,488 | 119 | PASS (0 bad) | none | 0/0 | 0 | 383 |
| GAL_nohook | CDFJ | 2,431,863 | 1,948,492 | 239 (239) | 0 | 40,757 | 148,581 / 1,912 | 119 | PASS (0 bad) | `merge_amp` 5, `resync` 5 | 0/0 | 18 | 475 |
| GAL_hook | CDFJ | 2,431,863 | 1,948,492 | 239 (239) | 0 | 40,762 | 148,581 / 1,912 | 119 | PASS (0 bad) | none | 0/0 | 0 | 473 |
| DRA_nohook | CDF1 | 2,372,614 | 2,263,420 | 239 (239) | 0 | 39,765 | 25,830 / 599 | 119 | PASS (0 bad) | `merge_amp` 4, `resync` 4 | 0/0 | 5 | 475 |
| DRA_hook | CDF1 | 2,372,614 | 2,263,420 | 239 (239) | 0 | 39,769 | 25,830 / 599 | 119 | PASS (0 bad) | none | 0/0 | 0 | 472 |
| STRATO_nohook | DPC+ rev 0 | 2,377,684 | 1,924,205 | 90 (90) | 5 (5) | 39,854 | 0 / 10,996 | 119 | PASS (0 bad) | none | 0/0 | 0 | 474 |
| CHG_nohook (Chaotic-Grill, added) | DPC+ rev 1 | 2,390,971 | 2,092,992 | 0 | 0 | 40,077 | 0 / 446 | 119 | PASS (0 bad) | none | 0/0 | 0 | 478 |

Every count equals section 5.1's, and for the seven runs both reports share, the first 30 columns of `fe.csv` are byte-identical to the lane's. `merge_late`, `dma_cover`, `mask_stuck` and `dig_val_bad` are 0 everywhere; T5 compares nothing in these games (no ROM-route digital audio, section 5.2). Chaotic-Grill adds DPC+ revision 1 (`stable_fractional`), but makes no call or service in 120 frames.

Lane E2's 50 directed tests on the fixed bench and the real RTL (`FLAVOR=e1v`, `sim/work/bupchip/daria/fe_dir/e1v/results.txt`): **49 of 50 pass**, as before; the one failure is still `cdf_jump_ffe` (`obus_exposed` 5, section 7). `pause_lane` is now 0 in all six pause tests, `rmw_call_cdf` keeps `rmw_seed` 2 / `rmw_merge` 2, and the digital tests compare 164-165 ROM samples each with 0 differences.

### V.5 Regressions

`tb_daria.sv`, `run_daria.sh`, `run_all.sh`, `fe_taps.svh` and `dynamic_tables.py` were not changed. Every code change in `fe_shadow.svh` lies inside the stage-1 block (`` `ifndef FE_STAGE0 ``); the header comment is the only change outside it. `verilator -E` of `tb_daria.sv` with the old and the new bench gives identical output for the plain build, `SHADOW=1 WIN_KB=64` and `FE=1 FE_STAGE0=1` (md5 equal; 1,579 lines for the stage-0 bench). The step-5 batch (`obj_shadow64`, `runs/shadow64/`) was not touched.

### V.6 Remaining issues (not fixed here)

1. **`cart_download` race in tb_daria** (section 9, question 1): unchanged; it needs a tb_daria change and new baselines (lead's decision).
2. **`cdf_jump_ffe` `obus_exposed`** (section 7, E2 issue 1): a design decision for the lead; E2 V.5 item 3 recommends accepting `daria_fe`'s value. [Decided, F1_fixes.md 3: accepted; `cdf_jump_ffe` passes with `obus_ffe` 5.]
3. **`tbl_alias` is raised by `daria_fe` itself** (`u_core.ev_tbl_alias`), and then removes that stream from C3, L1 and the RAM compares for the rest of the run (design 9.5: until the ARM rewrites the word). C4 still checks the DSWRITE byte itself at upstream's address, so a wrong alias address fails there, but a spurious alias would still blind C3 for one stream. No CDFJ+ game is in the set, so this was not exercised.
4. **Coverage of the game set** (on top of section 5.2): the merge's values (m09/m10 equivalent on every game), RMW pairs, fills, `ret_late`/`merge_race`, console resets and `short_phase1` are reached only by E2's directed tests or unit benches. The take of counter 2 at an own merge is reached by nothing (m10 on voice 2 is equivalent on all available inputs); a directed script that changes r10 in a CDF call would close it (lane E2's `tests.py`).
5. **`merge_late` and `dma_cover` are checks on `daria_fe`'s timing**, added because the bench's masks depend on it. If the lead accepts a design change to M_fe (design 5.6) or to the busy rule (7.4), these two must follow.

Verification outputs (all under `sim/work/bupchip/daria/`): `e1v/runs/final/` (the runs of V.4), `e1v/runs/inj/` (self-test reruns), `e1v_mut/runs/mut/` (the mutations on the fixed bench), `e1v_orig/runs/mut/` (the same on the bench as left), `fe_dir/e1v/` and `fe_dir/e1vm/` (directed tests; `e1vm` with E2's gated mutants, results per tag), and `e1v_mut/scripts/` (the gated RTL copies, the Verilator wrappers and the run lists). Object directories were deleted. Nothing was committed.
