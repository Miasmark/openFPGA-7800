# DARIA step 7: integration and Fix B, the plan

Branch `DARIA-dev`, base `aeee6d2` ("DARIA step 6 done in simulation"). This plan was written read-only against that tree; every `file:line` below is at `aeee6d2` unless it names a scratch path or a gitignored `sim/work/` path. Scratch evidence for this plan is in the session's scratch directory, outside the repository (called `$S7` below; its path is in the hand-off note that came with this plan): `rtl-wiring/` (the preprocessor baseline and `pp_equiv.py`), `timing-fit/` (fit times and memory from the step-3 probes), `verif/` (a `run_sim.sh` run on `aeee6d2`), `plan-rev/plan.orig.md` (revision 1 of this plan).

**Revision 2.** Two reviews of revision 1, one from the hardware and timing side and one from the verification side, were checked against the RTL and folded in. Section 10 lists where this plan departs from a reviewer's suggestion, and why.

Tags as in `docs/DARIA_CORE.md:7-18`: [E] estimate, [sim] measured in simulation, [sta] read from a timing report.

Contents:

1. Scope and done-when
2. The wiring map
3. Lanes
4. Order, integration and the fit schedule
5. Gates and fallbacks
6. Risks and open questions
7. Verification and review
8. Stale references to correct
9. Hand-over to step 8
10. Review responses

---

## 1. Scope and done-when

### 1.1 What step 7 must show

Step 7's done-when (`docs/DARIA_CORE.md:1778`):

> `run_sim.sh`, `extra_tests.sh` and `s4/check.sh` pass, the RAM mappers pass with Fix B's added latency, the 15 demos render the same frames as upstream in whole-core simulation, and `clk_sdram` has at least +1.5 ns on three seeds.

Also in scope:

- the integration itself (`POCKET_DARIA`) and Fix B (decision 2, `DARIA_CORE.md:32`; design `DARIA_CORE.md:1452-1673`);
- `docs/daria_fe/design.md` 12.2 step 9 (`design.md:1836`): wrapper wiring (1.6, `design.md:426-442`), the SDC and QSF lines (8.2, `design.md:1462-1494`), the full fit, the STA checks, the device at the 84% guide;
- the items step 6 handed over (`DARIA_CORE.md:618-626`): the DPC+ copy speed question (`DARIA_CORE.md:622`; `docs/daria_fe/lanes/E1_shadow.md:235`), and the two notes left for the lead (`DARIA_CORE.md:618`), E3's note 3 (`held_svc_race`) and the `cart_download` race in `tb_daria`'s load, decided in P27 and P28;
- open item 11, the `BUP_DEBUG` overlay's crossing (`DARIA_CORE.md:1798`), and open item 12, Fix B's margins (`DARIA_CORE.md:1799`);
- `clk_arm` at ÷18 (38.18 MHz) on three seeds, with ÷19 (36.17 MHz) as the fallback (decision 7, `DARIA_CORE.md:37`; `DARIA_CORE.md:360`);
- the lean-audio fallback (decision 9, `DARIA_CORE.md:39`) if the fit forces it.

The project rules hold throughout: no game data in the repository (`DARIA_CORE.md:27`); user-supplied firmware is never committed (`run_full.sh:39` already strips `bupchip.*` from fit copies); clean room (`DARIA_CORE.md:26`: `arm7tdmi_core.sv` only as the simulation oracle in `tb_daria`'s upstream build, lroby74's code never read); no model names in the repository. 7.7 adds a mechanical check for these rules.

### 1.2 Done-when, item by item

Each row says what counts as done, the evidence that shows it, and the lane that produces it (lanes in section 3).

| # | Item | Done when | Evidence | Lane |
|---|---|---|---|---|
| 1 | Integration (`POCKET_DARIA`) | Every port of section 2 is wired as mapped; both builds lint clean; the DARIA build runs ARM images in the whole core; F6 never writes cart RAM while the PLL is retuned (P20) | Verilator `-Wall` lint of three macro sets (shipped, shipped minus `POCKET_DARIA`, `run_daria.sh`'s WRAPPER set); the `tb_load` smoke and the scenarios of 7.3, each with its pass criteria; `MODE_B=1 WRAPPER=1` against upstream; `tb_frames` at 600 frames on one image per scheme before D merges (4.2); the game-free DARIA section of `run_sim.sh` (3.6); the frame gate (item 7) | I1, I4 |
| 2 | Fix B | `sram_ctrl.sv`, `top.sv` and `atari7800_pocket.sv` carry Fix B as `DARIA_CORE.md:1458-1502` designs it; a 7800 or BIOS request never meets a 2600 request in any bench (P2); its structural STA checks hold | The RAM-mapper matrix (item 6); the mutants of 7.2; Build A on seeds 1-3 with the structural checks rescoped as in 5.4, and (g) shown able to fail | I2, I3, I4 |
| 3 | `run_sim.sh` passes | Exit 0, with a checker that turns every printed verdict into the exit code (today `BIOS_BOOT` and `BUPCHIP_E2E` do not set it: `sim/run_sim.sh:175-185,241,286`), and in which a skipped section fails (`run_sim.sh:243,288`). The new DARIA section passes in the DARIA build | Logs and checker output for both builds, each in its own `WORK`; per-frame fingerprints (`+fp`, 3.6) compared between the builds (7.5 row 5) and between F and `aeee6d2` | I4 |
| 4 | `extra_tests.sh` passes | Exit 0 with a machine criterion for every section: `ARCHECK` (`sim/ar_test.py:144` always exits 0 today); multisprite row for row against `herodown1.png`, as the header states (`sim/extra_tests.sh:6-8`); POKEY and DLI statistics equal to the reference build's (7.5); the Fix B section placed before the network clones (`sim/extra_tests.sh:23-29`) | Logs and checker output, both builds; `AR_TAPE=1` once per build named in 4.3 | I4 |
| 5 | `s4/check.sh` passes | 28 of 28 with `DARIA=1 ARM38=1 PSRAM_CS=50.0` and the GAME argument and `REFDIR` set (without them only the game-free jobs run: `sim/bupchip/s4/check.sh:52-61,84-90`), and the non-DARIA set, at `JOBS=2`; `tb_s4` checks the snapshot (3.6) instead of only printing it (`sim/bupchip/s4/tb_s4.sv:967-968`) | `check.sh` summaries on the final tree; `tb_s4` always builds `BUP_DEBUG` (`sim/bupchip/s4/build_s4.sh:38`), so it exercises the open item 11 change | I4 |
| 6 | RAM mappers with Fix B's latency | 8 mappers (F8SC, F4SC, FA, CV, E7 two areas, 3E two banks, WD, CTY), Flicker Blend off and on: no fail code, 0 wrong, 0 stale, writes = strobes, shadow = SRAM, read and write counts equal to the expected per image; main latency bucket 11 and 7 for a repeated address on `aeee6d2`, 15 and 11 on F and D (`DARIA_CORE.md:1545-1546`); maximum ≤ 19 | The matrix on three builds: `aeee6d2`, commit F, commit D; the Supercharger runs and a 7800 RAM cart with `+cartram`; an ARM image that makes 0 `cartram_*26` strobes; the directed s19 run, which must put at least one access in the s19 bucket and none above (open item 12) | I4 (harness), I2 (first run) |
| 7 | 15 demos, same frames | For each of the 15 demos and Stratovox (the only image that makes DPC+ services, `E1_shadow.md:150`), 1,500 frames: frame length and video equal to upstream's on every frame; RIOT RAM and audio equal on every frame or classed `release_shift`; under the rules of P13 and 7.4 | `fp.csv` and `calls.csv` from `tb_daria +fp=1` (upstream) and from `tb_frames`; `sim/check/frame_gate.py` verdicts, with exit codes; per-run status lines (halts 0, PSRAM violations 0, guard locked with 0 unlocks, calls and late calls equal to upstream's) | I4 |
| 8 | `clk_sdram` ≥ +1.5 ns on three seeds | Worst setup ≥ +1.5 ns at the worse of the two slow corners (1100 mV 85 °C and 0 °C) on seeds 1, 2 and 3 of the integrated build, and worst hold over all clocks positive at every corner (`DARIA_CORE.md:1645`) | `timing.txt` and the step-7 report of 5.4 for Build B, three seeds | I3 |
| 9 | Design 12.2 step 9 | Wiring 1.6 done (item 1); SDC and QSF lines in; full fit; STA checks (a)-(e) of 5.4 hold; the device's "ALMs needed" reported against the 84% guide (15,523 ALMs, `design.md:1656`) | Build B reports | I1, I3 |
| 10 | Open item 11 | The `BUP_DEBUG` status reaches `clk_sys` through a toggle snapshot, never sampled raw | `tb_dbg_snap` (no torn word at the ÷18 lattice's three phases and at random phases, also with random power-up values); `tb_s4`'s snapshot check; `s4/check.sh`; Q5, the `BUP_DEBUG` + `POCKET_DARIA` fit on seeds 1-3 (P29) | I3, I4 |
| 11 | Open item 12 | The four margins have numbers: `c_rdata` worst-case latency seen in simulation (19 reached, never above); `t_*_q` → `clk_sdram` setup and hold; `c_rdata` multicycle slack; Flicker Blend's `fbn_*` half-period slack | The directed s19 run; the step-7 report's Fix B section on Build A and Build B | I4, I3 |
| 12 | `clk_arm` at ÷18 | Setup ≥ 0 at both slow corners and hold ≥ 0 at every corner, on seeds 1-3 of Build B; otherwise 5.2's ladder | Build B reports | I3 |
| 13 | Lean audio, if forced | Not started unless 5.1's trigger fires; then lane I6 of 3.7 | Lane I6's gate | I6 |
| 14 | Hand-over | Section 9's list is complete; `daria_fe` exports the guard's lock and unlock (P22), so step 8 changes only `BUP_DEBUG` code | Section 9; the `tb_frames` status lines read the new ports | lead, I1 |

### 1.3 Decisions this plan takes

The documents settle most of what step 7 needs. Where they disagree or leave a choice, this plan decides as below. The owner may overrule any of them; section 6.2 lists what the documents cannot settle.

| # | Decision | Basis |
|---|---|---|
| P1 | **Fix B stays under `POCKET_SRAM`**, as designed, and lands as its own commit (F) before the DARIA commit (D). F is proven behaviourally against `aeee6d2`; D is proven textually against F (7.5). No new macro. | `DARIA_CORE.md:1653-1661` (vendored-file rules), decision 2 ties Fix B to the release, not to a macro |
| P2 | **No retry for a coincident request; an assertion instead.** `t_last` loads on every `t_new`, as in the prototype. A 7800 or BIOS request and a 2600 request cannot meet: under Fix B the 7800 request exists only while `cartram_sel26` is low and the 2600 request only while it is high (`top.sv:752-759`), and `bios_sel = ~bios_en_b && AB[15]` (`top.sv:355`) never rises for a 2600 image (decision 11). A retry would start the 2600 read behind a five-cycle access and land `c_rdata` at s20 or later, past the s19 bound, with no failure anywhere (`DARIA_CORE.md:1665`). Every bench that builds `sram_ctrl` therefore stops with `$fatal` if `m_new` and `t_new` are ever high in the same `clk_sdram` cycle (a hierarchical tap; `sram_ctrl.sv` stays free of bench code), and a mutant forces the coincidence to show the assertion fires. Keep the redundant compare. | `DARIA_CORE.md:1671` (keep the compare); `sim/work/fixb/src/sram_ctrl.sv:258,272-283,410-418` |
| P3 | **Busy routing through `cart2600`:** two new `cart2600` inputs replace the stubs at `cart2600.sv:535` and `:542`, so `top.sv:306-307` keeps upstream's text. `mapper_init_busy` stays 0 (`cart2600.sv:592`). | `DARIA_CORE.md:1383` (route), `design_inputs.md:705` R2 (`mapper_init_busy` 0); `design.md:428-436` |
| P4 | **Every `POCKET_DARIA` hook in a vendored file sits inside `ifdef NO_ARM_MAPPER`.** `run_daria.sh`'s WRAPPER build defines `POCKET_DARIA` with upstream's ARM compiled in (`sim/bupchip/daria/run_daria.sh:97-102`), so an unnested hook would change the oracle. The consequence: no `tb_daria` build ever runs the real hooks, so the first run of them on games is `tb_frames` (P24, 4.2). | Wiring finding 2 |
| P5 | **`scheme` is gated by the `tia_mode` register:** `scheme = tia_mode ? fbs : 6'd0`, combinational from registers. `daria_profile` is the same condition registered (R16). A live `bs_override` change behaves as upstream's live mapper does: `daria_fe` resets on any scheme change (`daria_fe.sv:94-97`). | `design_inputs.md:719` R16, `:725` (live override); `daria_fe_copy.sv:151-157`; 2.4 |
| P6 | **`init_busy` reaches the reset and `.loading` only for an ARM scheme:** `daria_hold = init_busy & (scheme == DPCP \| scheme == CDF)`. `init_busy` rises at every `load_start` and falls at `load_end`+1 for a non-ARM image (`design.md:1335-1356`), which would hold every other load's reset one `clk_sys` longer than today. With the gate, 7800 and non-ARM 2600 loads release on the same edge as in the non-DARIA build, so those builds can be compared in lockstep. The hold never dips for an ARM image: `cart_download` and `old_cart_download` hold the reset until `load_end`+1 (`atari7800_pocket.sv:169-171`), and `scheme` is valid from `load_end`+1 (`atari7800_pocket.sv:240-263`; detect2600 changes `force_bs` on the `load_end` edge, `detect2600.sv:210`). The scheme holds the previous image's value until `load_end`, so the second-load cases (ARM then non-ARM, ARM then 7800) are tested as well as power-up (3.3, 7.3). | D6 (`design.md:438`), 2.4 |
| P7 | **Sample requester (`daria_smp.sv`, new):** one halfword read straight from the PSRAM, arbitrated ahead of the cache at `bup_asset_wr`'s read port, not a second cache client. This departs from design 5.7's "through the asset cache" (`design.md:1179`), which section 8 corrects. It answers every request; when the image is not readable (hold, load, another profile) it answers `$FF` at once, because `busy_r` clears only on an answer (`daria_fe_audio.sv:144,419,435-436`). Its request synchroniser and its `ack` toggle are never reset, by hold, `cpu_run`, the mapper reset or `pll_busy`, as `daria_fe`'s side is not (`daria_fe_audio.sv:142`): resetting one side of the toggle pair loses, repeats or mis-takes an answer. | `DARIA_CORE.md` 3.2 "Samples" (the row "a `clk_arm` requester reads one halfword between cache reads"); `design.md:1168-1176` |
| P8 | **Synchroniser marks are exact-bit instance assignments in a new `core/daria.qip`**, one `set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*\|<entity>:*\|<reg>[0]"` per first flop, the form `DARIA_CORE.md:1313` names. An RTL attribute applies to a whole declaration, and nearly every chain is a vector or shares its declaration: `bupchip_pocket.sv:214` (`hold_a`, `pause_a`), `:227` (`prof_a`, `ram32_a`, `mres_a`), `:372` (`ready_s`, `halted_s`), `:419`, `:455`, `:498`, `:550`; `daria_call.sv:71`; `daria_mmio.sv:142,183-184`; and `bup_asset_wr.sv:109` declares `t1` with `t2` and `seen`, which is no synchroniser. Splitting the declarations would duplicate always blocks under `ifdef` and break bench taps on these names (`sim/bupchip/daria/mmio/run_mmio.sh:93-128`, `mmio/tb_mmio.sv:505`). The new files (`daria_smp.sv`, `bup_dbg_snap.sv`) declare each first stage as its own scalar with the RTL attribute, as `daria_fe` does (`daria_fe_call.sv:102`, `daria_fe_audio.sv:151`). If Q2 shows Quartus ignoring the qip's instance assignments (5.4 (f)), the fallback is scalar first stages under `ifdef POCKET_DARIA`. | 2.7; the qip keeps the non-DARIA build unchanged by construction (one line removed) |
| P9 | **DARIA's constraints go in a new file, `core/daria_constraints.sdc`,** listed by an `SDC_FILE` line in `ap_core.qsf` after the `QIP_FILE` lines (`ap_core.qsf:772-773`), so that it is read after `apf_constraints.sdc` has derived the PLL clocks and read `core_constraints.sdc` (`apf/apf.qip:5`; `apf_constraints.sdc:12,20`). DARIA adds three lines to `ap_core.qsf`: the macro, `QIP_FILE core/daria.qip` (P8) and this `SDC_FILE`. A non-DARIA build removes the three. The new file defines its own clock names, the ±20 ns pair both ways (`DARIA_CORE.md:1305-1314`), the guard pair (`design.md:1466-1473`), and any later DARIA-only fitter padding (P11, 5.2, 5.3). | Avoids conditional Tcl on netlist contents; the non-DARIA constraints are unchanged by construction |
| P10 | **The PLL** is regenerated with `ip-generate` at C3 = 18 (and at C3 = 19 for the fallback, kept in scratch). The diff against today's file must touch only counter 3's lines; those lines are then selected with `ifdef POCKET_DARIA`. The values stay tool-generated; only the selection is by hand. `DEVELOPING.md`'s command hard-codes `gui_divide_factor_c3=24` and `gui_output_clock_frequency3=28.636363` (`DEVELOPING.md:287,292`); I3 updates both. `pll_region` writes only the fraction (register 7) and the start (register 2), so C3 survives a retune (`pll_region.v:73-80`). | `DEVELOPING.md:273-296` (regenerate, do not hand-edit); `pll_core.v:70,146-152` has no `ifdef` today |
| P11 | **Commit F sets the shared fitter padding once:** setup into `clk_sdram` from 1.0 to 1.5 ns (`core_constraints.sdc:57`), and a new fitter-only `-add -hold 0.1` from `clk_sys` into `clk_sdram`, for `t_*_q`'s coincident edge, where Flicker Blend's capture once failed hold by 0.13 ns (`DARIA_CORE.md:1641`; `sram_ctrl.sv:237-239`). Adding the hold line later would break the identity proof below. After F, `core_constraints.sdc` changes only in comments: any later padding goes in `daria_constraints.sdc`, and any non-comment change to `core_constraints.sdc` reopens Q1 and Q4 (7.6). Padding is only the fitter's target: 2.1.1 already had the 1.0 ns line (`git show 2.1.1:src/fpga/core/core_constraints.sdc:57`) and landed at +0.26, +0.44 and +0.28 ns (`SRAM_TIMING.md:77-82`). Q1b (4.3) fits F with `aeee6d2`'s padding, so Q0 against Q1b measures Fix B alone against the design's Build A expectation (≥ +2.5 ns, `DARIA_CORE.md:1634`), and Q1b against Q1 the padding. | `DARIA_CORE.md:1641,1645`; `core_constraints.sdc:46-59` |
| P12 | **"Three seeds" means seeds 1, 2 and 3**, the convention of every measurement so far (`SRAM_TIMING.md:77-82`, `DARIA_CORE.md:335-341`). Every gate (`clk_sdram`, `clk_arm`, hold) must hold on all three. The shipped `SEED` is the one of the three, already fitted on the final tree, that passes every gate with the most `clk_sdram` margin; setting it refits nothing (7.6). | `DARIA_CORE.md:1645` ("every seed") |
| P13 | **The frame gate** is `sim/check/frame_gate.py`, with exit codes. Both files must hold exactly the run's frame count, counted from the last reset release. `len_sys` and video are equal on every frame. RIOT RAM and audio are equal on every frame, or the difference is classed `release_shift` (7.4). R2 is the first run in which DARIA's own call length decides when the 6507 resumes: upstream holds the 6507 during each call (`DARIA_CORE.md:658`), mode B held it for the later of the two sides (`G_modeB.md:346`), and the two call lengths differ (Mappy's first call: 283 µs against 293 µs, `DARIA_CORE.md:457`). Spiders' frames 557-572 are excused if they are the overrun frames on both sides and every column matches from 573. The status lines must show 0 halts, 0 PSRAM violations, the guard locked with 0 unlocks, and the calls and late calls equal to upstream's. The gate covers the 15 demos plus Stratovox, at 1,500 frames each. | 7.4; `DARIA_CORE.md:1779` (step 8 accepts Spiders' overrun); `docs/daria_fe/lanes/G_modeB.md:61,318` (`merge_race`) |
| P14 | **The `daria_fe` instance is named `u_fe`** in `atari7800_pocket.sv`. `fe_taps.svh` hard-codes `u_fe.` 74 times, so it gets an `FE_PATH` prefix macro, defaulting to `u_fe`. | `sim/bupchip/daria/fe_taps.svh` (74 references) |
| P15 | **Open item 11 is a toggle snapshot** (new `bup_dbg_snap.sv`, about 180 FF), under `BUP_DEBUG` and `POCKET_DARIA`, with no false path. Step 8's overlay reuses it. | `DARIA_CORE.md:1288` (7.1 row 9) offers both; a false path only hides the tear |
| P16 | **I5 (the step-8 status overlay) is deferred to step 8.** Step 7 builds the snapshot generic enough for it (P15) and exports the guard's state from `daria_fe` (P22), so that step 8 touches only `BUP_DEBUG` code. | `DARIA_CORE.md:1779` |
| P17 | **Build A (Fix B alone) is fitted on seeds 1-3**, and so is a baseline of `aeee6d2`, so that Fix B's gain is measured apart from DARIA's fill; Q1b separates it from P11's padding. | `DARIA_CORE.md:1633-1636` |
| P18 | **`psram.sv`'s `CLOCK_SPEED` is 50.0 under `POCKET_DARIA`**, 28.636364 otherwise. No PSRAM model run tells the two apart at 38.18 MHz (`run_capture.sh`'s `main_a38` runs 28.636364 there with 0 violations: `sim/bupchip/daria/capture/run_capture.sh:24-27,338-344`), so the value is checked by parameter: `tb_load` stops if the elaborated value is not 50.0 in the DARIA build, and 5.4 (n) reads it from the synthesis report. | Open item 10 (`DARIA_CORE.md:1797`); `atari7800_pocket.sv:1210`; `DARIA_CORE.md:1317-1327` |
| P19 | **Not in the gate:** the six added images and the eight other Champ Games Presents ARM images run whole-core for 600 frames as evidence, through FIRE at frame 420 and the joystick from 480 (`sim/bupchip/daria/tb_daria.sv:43,46-47`). Failures there are investigated, but they do not block step 7 unless they show an integration bug. If the schedule slips, these are cut back to 300 frames first. | Coverage (7.4) |
| P20 | **F6 never runs while the PLL is retuned; it runs once, when the retune ends.** Today it would: `pll_busy` raises the console reset (`atari7800_pocket.sv:168-171`), so `daria_fe`'s `cart_reset` (`effective_reset`, `top.sv:255`) rises, and a rising `cart_reset` starts F6 eight clocks later (`design.md:1346-1349,1353`). `pll_region` raises `busy` only about 50 `clk_sys` before it stops the PLL (`pll_region.v:12-15`), and F6 lasts 2,082 or 8,226 `clk_sys` (`design.md:1369`), so F6 would write cart RAM while `clk_sys` stops and restarts. On Auto region a 2600 game's region follows the TIA's PAL detection (`atari7800_pocket.sv:863-864`), so every PAL ARM image retunes soon after it starts. The fix is in the wrapper, so `daria_fe` and its step-6 evidence stay as they are: `daria_fe`'s `cart_reset` is `daria_reset & ~pll_busy_s[1]`, and the console reset gains `daria_rt_hold & daria_arm`, a register that is high while `pll_busy_s[1]` is and for 16 `clk_sys` after it falls. While the PLL is retuned `daria_fe` sees no rising reset. When `pll_busy_s[1]` falls, `reset` is still high, so `daria_fe` sees one rise with `clk_sys` running; F6 starts eight clocks later under `rst_quiet` (`daria_fe_copy.sv:260`), and `init_busy` holds the console from the next clock, inside the 16-clock tail. The 6507 restarts with a fresh F6, as after a console reset (`DARIA_CORE.md:1102`). This contradicts `DARIA_CORE.md:1103` ("kept"), which section 8 corrects; the owner may prefer to keep the RAM (6.2 question 4). Residual: a manual region change in the menu within F6's 0.15-0.6 ms after a load still retunes during F6 (on Auto the 6507 is held through F6, so the TIA cannot detect PAL then); it is accepted and recorded for step 8. | `pll_region.v:12-15,73-80`; `design.md:1346-1357,1369`; `tb_load.sv:121` ties `pll_busy` to 0, so no bench sees this today |
| P21 | **Every synchroniser's first flop samples one source register directly**, with no logic between. Three nets change. `ready_s[0]` samples `ready_a`, a new `clk_arm` register of `parked & img_ready`; `parked` decodes a state register (`bup_cpu.sv:1464`), and at ÷18 a `clk_sys` edge can fall inside that decode's settling time, so a glitch would become a one-clock `cpu_ready`, which gates the call flip, the release and `guard_on` (`daria_fe_guard.sv:79`). `bupchip`'s `daria_ram32` and `daria_mreset` inputs come from new `clk_sys` registers in `atari7800_pocket.sv`: `daria_ram32` is a compare (2.1), and `daria_mreset` would be `reset \| reset_hold` (`top.sv:255`), an OR of two registers that can change in opposite directions on one edge (`top.sv:266-286`). `daria_fe` keeps the combinational `ram32`, which it latches at `ld1` (`design.md:1342`). The cost is one clock on levels that are static while the CPU runs, and one `clk_arm` (26 ns) on `cpu_ready`; mode B and the frame gate run on this RTL. 5.4 (k') checks it in the fit. | `bupchip_pocket.sv:372-378`; `DARIA_CORE.md:1300` |
| P22 | **`daria_fe` exports the guard's state**, observation only: `dbg_locked` (`u_guard.locked`, `daria_fe_guard.sv:37`) and `dbg_unlock`, a one-clock pulse that is today the bench-only `ev_unlock` (`daria_fe_guard.sv:56`). They drive nothing in the release build. `tb_frames`' status lines read them, so they are tested now; step 8's overlay counts and draws them under `BUP_DEBUG`, which by 7.6 re-runs only Q5 and `s4/check.sh`. Calls are counted from `call_tog` in the wrapper, and the late-call source is a bus decode (6.2 question 5), so neither needs a `daria_fe` port. This is a port change after step 6's freeze (`docs/daria_fe/README.md:27`), signed off here. | Without it, step 8 would reopen `daria_fe`'s ports and, by 7.6, mode B, the frame gate and Build B |
| P23 | **Worktrees and branches.** Each lane works on its own branch (`s7/I1` … `s7/I4`) in its own `git worktree` (about 30 MB of source each, `du` of the tree without `sim/work`); the lead merges into `DARIA-dev` in 4.1's order. A worktree `base`, detached at `aeee6d2`, holds R1 and every `aeee6d2` baseline: its binaries are built once and then run with `NOBUILD=1` (`run_daria.sh:134-143` otherwise rebuilds when any source is newer). Each worktree has its own `sim/work`; game images and the user's firmware are referenced from the main checkout's gitignored paths, never copied into a tracked path. Every gate log starts with `git rev-parse HEAD`, `git status --porcelain` (empty), the Verilator path and version, and the md5 of the binary it ran. | 7.6 ("a result counts only for the tree it ran on") needs the tree to be known |
| P24 | **R2 starts at ÷18 as soon as D merges**, in parallel with Q2, with one image per scheme first (Galagon CDFJ, Stay Frosty 2 DPC+, Draconian CDF, Turbo CDFJ+), then Spiders and Stratovox, then the rest. If ÷18 holds, about a day is saved; if Q2 forces ÷19, R2 runs again at ÷19, as it would have anyway. | 4.2 |
| P25 | **The area projection uses Quartus's "ALMs needed"**, the figure the device percentage is computed from; `daria_fe`'s is 1,728-1,732, against 1,389-1,490 "placed minus [B]" from the same fits (`docs/daria_fe/README.md:31-35`). 5.1 gives both. | `design.md:1656` |
| P26 | **Comment-only and selection-only edits do not reopen gates** when proven so (7.6): the stale-comment fixes of section 8 and the `SEED` choice of P12 land after Q2 without a new Q2. | 7.6 |
| P27 | **The `cart_download` race in `tb_daria`'s load is accepted for step 7** (`E1_shadow.md:268`, question 1). The fix in `tb_daria` would move the load by a clock in every build and void every step-5 and step-6 baseline. Instead every R1 run must show that its load was seen (detect2600 set the expected scheme, and the first call is in `calls.csv`) or it is void. `tb_frames` loads through the real loader (`tb_load.sv:74-78`) and has no such race. | `DARIA_CORE.md:618` |
| P28 | **E3's note 3 (`held_svc_race`) is accepted as a counted class.** Real code reaches it only with `$A9` in ROM at a read-modify-write's register address followed by an opcode below `$28` (`docs/daria_fe/lanes/E3_rtl_issues.md:71`); the random bench counted 0 (`E3_random.md:220`). The lead adds it to design 9.5 in the docs commit, and the frame gate's triage uses it if it is ever seen. | `DARIA_CORE.md:618` |
| P29 | **Q5, the step-8 test configuration (`BUP_DEBUG` + DARIA), is fitted on seeds 1-3** and must meet setup and hold ≥ 0 on every clock, with `clk_arm` at the shipped divider, on at least one seed, which step 8 then uses. The +1.5 ns `clk_sdram` gate is the release gate (`DARIA_CORE.md:1645`) and is reported for Q5, not required. | `DEVELOPING.md:411-412` (`BUP_DEBUG` alone was at 79% ALMs and 95% LABs) |

---

## 2. The wiring map

### 2.1 `daria_fe` ports (`src/fpga/core/bupchip/daria_fe.sv:29-83`)

The instance `u_fe` goes in `atari7800_pocket.sv`, inside the `POCKET_BUPCHIP` block after the `bupchip` instance (`atari7800_pocket.sv:1165-1203`), under `ifdef POCKET_DARIA`. All ports are `clk_sys` unless the table says otherwise.

| Port (`daria_fe.sv` line) | Connects to | Where it comes from today | Change |
|---|---|---|---|
| `clk_sys` (:29) | `clk_sys` | atari port | none |
| `clk_arm` (:30) | `clk_arm` | atari port under `POCKET_BUPCHIP` (`atari7800_pocket.sv:26-28`) | none (`POCKET_DARIA` requires `POCKET_BUPCHIP`) |
| `cart_reset` (:31) | `daria_reset & ~pll_busy_s[1]` | `daria_reset` is `top.sv:255` `effective_reset`; `pll_busy_s` is the wrapper's own two-flop copy (`atari7800_pocket.sv:168`) | new `top.sv` output; the gate of P20 |
| `pause` (:32) | `pause_core` | atari port `:63`, tied 0 in `core_top.v:883` | none (decision 10) |
| `a_in` (:33) | `daria_a_in` | `top.sv:1128` expression `{AB[12] & bios_en_b, AB[11:0]}` | new `top.sv` output, same expression |
| `d_in` (:34) | `din` | `atari7800_pocket.sv:332,1035` (= `top.sv:413` `write_DB`) | none |
| `rw` (:35) | `RW` | `atari7800_pocket.sv:1034` | none |
| `pclk1` (:36) | `daria_pclk1` | `top.sv:335` `cpu_ce = pclk1`, left open at `atari7800_pocket.sv:953` | connect the open port |
| `pclk0` (:37) | `daria_pclk0` | `top.sv:236,717` | new `top.sv` output |
| `access` (:38) | `daria_access` | `= mapper_phi2 && lock_ctrl && tia_en`, the same as `cart2600.sv:247`'s `arm_access` (`top.sv:327,1135-1136`) | new `top.sv` output |
| `scheme` (:39) | `tia_mode ? daria_fbs : 6'd0` | `daria_fbs` repeats `atari7800_pocket.sv:1058`'s expression; `tia_mode` is the register at `:181`, written at `:241,263` | new atari wires (P5) |
| `revision` (:41) | `mapper_revision` | `atari7800_pocket.sv:294` | none |
| `cdf_ldx`, `cdf_ldy`, `fetch_off_en`, `fetch_off` (:43-46) | detect2600 outputs | `atari7800_pocket.sv:295-296,310-319` | none |
| `cdfj_entry`, `cdfj_stack` (:47-48) | detect2600 outputs | `atari7800_pocket.sv:297` | none |
| `audio_size_addr` (:49) | `arm_audio_size_addr` | `atari7800_pocket.sv:298` | none |
| `rom_size` (:50) | `cart_size` | `atari7800_pocket.sv:192` | none |
| `ram32` (:51) | `daria_ram32` | `= daria_fbs == 23 && mapper_revision == 3`; equals `top.sv:778-783`. `bupchip` gets the registered copy `daria_ram32_r` instead (P21) | new atari wire and register |
| `load_start`, `load_end` (:52-53) | `~old_cart_download && cart_download`, `old_cart_download && ~cart_download` | as at `atari7800_pocket.sv:1179-1180` | none |
| `cart_win` (:54) | `daria_cart_win` | `bup_capture.cart_win` = `cap_cart_win`, internal at `bupchip_pocket.sv:247,256` | new bupchip output |
| `cpu_ready` (:55) | `daria_ready` | `bupchip_pocket.sv:173,371-376` | connect; its source is registered first (P21) |
| `ret_tog` (:56), `clk_arm` domain | `daria_ret_tog` | `bupchip_pocket.sv:172` | connect |
| `call_tog` (:57) | `daria_call_tog` | `bupchip_pocket.sv:171` | connect |
| `smp_req`, `smp_addr` (:58-59) | `daria_smp_req`, `daria_smp_addr` | none | new bupchip inputs (2.2) |
| `smp_ack`, `smp_data` (:60-61), wrapper domain | `daria_smp_ack`, `daria_smp_data` | none | new bupchip outputs (2.2) |
| `fe_do`, `fe_oe` (:62-63) | `daria_fe_do`, `daria_fe_oe` → `top.sv` → `cart2600` | none | new `top.sv` and `cart2600` inputs (2.3, 2.4) |
| `arm_call_busy`, `arm_dma_busy` (:64-65) | `daria_call_busy`, `daria_dma_busy` → `top.sv` → `cart2600` | stubs at `cart2600.sv:535,542` | P3 |
| `init_busy` (:66) | `daria_init_busy` → `daria_hold` → atari `reset` (`:169-171`) and `.loading` (`:916`) | none | P6 |
| `fea_addr`, `fea_q` (:67-68) | `daria_fea_addr`, `daria_fea_q` | `bupchip_pocket.sv:185-186` | connect |
| `feb_addr`, `feb_q` (:69-70) | `daria_feb_addr`, `daria_feb_q` | `bupchip_pocket.sv:187-188` | connect |
| `crb_*` (:71-75) | `daria_crb_*` | `bupchip_pocket.sv:180-184` | connect |
| `stb_*` (:76-80) | `daria_stb_*` | `bupchip_pocket.sv:175-179` | connect |
| `hk_en`, `hk_stb`, `hk_ret` (:81-83) | `1'b0`, `1'b0`, `'0` | bench only | tie off (`design.md:259`) |
| `dbg_locked`, `dbg_unlock` (new, after :83) | open in the release build; read by `tb_frames` | `daria_fe_guard.sv:37,56` (internal) | new outputs (P22); `daria_fe_guard` gains an `unlock` output |

Timing of these paths (`design.md:1689-1706`): every stage is register or M10K q → logic → register or M10K input, worst slack about +40 ns at 69.84 ns [E]. `access` depends on `daria_fe`'s own busy registers through `arm_call_stall` and `mapper_phi2` (`top.sv:306-307,327`): a register-to-register path, not a combinational loop.

### 2.2 `src/fpga/core/bupchip/bupchip_pocket.sv`

| Change | Where | Macro |
|---|---|---|
| New ports: `output daria_cart_win`, `input daria_smp_req`, `input [18:0] daria_smp_addr`, `output daria_smp_ack`, `output [7:0] daria_smp_data` (commit S, 4.1, with the outputs tied off) | the `POCKET_DARIA` port group, `:164-189` | `POCKET_DARIA` |
| `assign daria_cart_win = cap_cart_win;` | after the capture instance, `:251-256` | `POCKET_DARIA` |
| `daria_smp` between the cache and the writer: the cache's `rd_req`/`rd_addr`/`rd_ack` go to `daria_smp`, and `daria_smp` drives the writer's | the writer `:269-279`, the cache `:396-400` | `POCKET_DARIA` (the non-DARIA build keeps the direct wires) |
| `ready_a` (`clk_arm` register of `parked & img_ready`), sampled by `ready_s` (P21) | `:371-376` | inside the existing `POCKET_DARIA` branch |
| `bup_dbg_snap` on the `clk_arm` bits of `dbg_status`, `dbg_halt_pc` and `dbg_load` (`:555-558,600-605`); the `clk_sys` bits pass through | `:550-605` | `BUP_DEBUG` and `POCKET_DARIA` (P15) |
| Header comment: `clk_arm` is VCO/18, no longer 2 × `clk_sys` | `:7-9` | comment |

The synchroniser marks of this file's chains are not edits to it: they are in `core/daria.qip` (P8, 2.7).

`daria_smp.sv` (new file, I1), on `clk_arm`:

- `req_s0` and `req_s1` are two scalar flops on `daria_smp_req`, with `SYNCHRONIZER_IDENTIFICATION FORCED` on `req_s0` (P8). `daria_smp_addr` and `daria_smp_data` are held buses under the ±20 ns pair. `req_s*` and `ack` have power-up values and no reset of any kind (P7).
- When `req_s1 != ack`, the requester is idle and `prof26 & img_ready & ~hold_a[1]`, it latches the address and issues one halfword read at `{4'b0, addr[18:1]}` (22 bits, the width of `rd_addr`, `bup_asset_cache.sv:124`), on the image's base as the cache addresses it; the unit bench checks the byte against the cache's own `asset_q`. It has priority whenever no read is outstanding. A cache read already in flight finishes first. While the sampler's read is in flight, the cache's `rd_req` is masked, so the cache sees no `rd_ack`, and the cache ignores a `rd_avail` it did not ask for (`bup_asset_cache.sv:175`: `rx = rd_avail && f_fl`).
- Every decision comes from registered state (an owner flag and the sampler's own request register). The chain `psram_read_avail` → `rx` → `rd_req` → `psram_read_en` → `rd_ack` is combinational and all `clk_arm` (`bup_asset_cache.sv:175,269`; `bup_asset_wr.sv:164-166`); the requester may add at most one gate to it, the mask, and I3 names that chain's slack in Q2's report.
- On `rd_avail` it selects the byte by `addr[0]` (the lane order the writer packs), drives `daria_smp_data`, and flips `ack` one `clk_arm` later.
- When the image is not readable, it answers at once with `$FF` (P7).
- Worst-case answer time is one outstanding cache read, its own read, and two `clk_sys` plus two `clk_arm` of synchronisation: under 1 µs [E], against one request per 20 kHz tick (50 µs).

### 2.3 `src/fpga/mister/rtl/top.sv` (vendored)

Commit D adds a port group after the `POCKET_BUPCHIP` group (`top.sv:36-45`, before `:46`), nested as `ifdef NO_ARM_MAPPER` / `ifdef POCKET_DARIA` (P4):

```
output logic [12:0] daria_a_in_o,      // {AB[12] & bios_en_b, AB[11:0]}, as cart2600's a_in (:1128)
output logic        daria_pclk0_o,     // pclk0 (:236, :717)
output logic        daria_access_o,    // mapper_phi2 && lock_ctrl && tia_en, as cart2600's arm_access
output logic        daria_reset_o,     // effective_reset (:255)
input  logic  [7:0] daria_fe_do_i,
input  logic        daria_fe_oe_i,
input  logic        daria_call_busy_i,
input  logic        daria_dma_busy_i,
```

In the body: the four `assign`s, and four connections in the `cart2600` instance (`:1114-1206`) under the same nesting. `:306-307` (`arm_call_stall`) and `:327` (`mapper_phi2`) stay upstream's text.

Fix B (commit F, I2) adds four ports inside the existing `POCKET_SRAM` group (`:23-35`): `cartram_addr26_out[17:0]`, `cartram_wr26_out`, `cartram_rd26_out`, `cartram_wrdata26_out[7:0]`. It replaces the merge at `:752-759` with `ifdef POCKET_SRAM` split / `else` upstream merge / `endif` (`DARIA_CORE.md:1460-1477`).

### 2.4 `src/fpga/mister/rtl/cart2600.sv` (vendored)

All of these sit inside `NO_ARM_MAPPER` and `POCKET_DARIA` (P4):

| Change | Where |
|---|---|
| Inputs `fe_do[7:0]`, `fe_oe`, `fe_call_busy`, `fe_dma_busy` | port list, after `:129`, nested |
| `is_bad_game = mapper == BANKELF \|\| mapper == BANKBUS` (decision 6) | `:158-163`, an inner `ifdef POCKET_DARIA` / `else` (Fix A's line) |
| `assign arm_dma_busy = fe_dma_busy;` and `assign arm_call_busy = fe_call_busy;` replace the stubs | `:535`, `:542`, inside the `else` of `ifndef NO_ARM_MAPPER` (`:441,530,570`) |
| BANKDPCP and BANKCDF: `direct_do = fe_do`, `flags_out = 16'd1`, `out_en = {8{fe_oe}}`; `ram_sel` 0, `ram_rw` 1, `ram_a` 0, `rom_addr` 0 as now. BANKBUS unchanged | `:630-643` |
| Unchanged: `mapper_init_busy = 0` (`:592`) and every other stub at `:585-627` | |

`fe_do` then reaches the 6507 through the output mux (`cart2600.sv:213-237`) and `read_DB` (`top.sv:391-393`).

### 2.5 `src/fpga/core/atari7800_pocket.sv` (Pocket code)

Commit D, all under `ifdef POCKET_DARIA` unless noted:

| Change | Where |
|---|---|
| Wires `daria_fbs`, `daria_scheme = tia_mode ? daria_fbs : 0`, `daria_arm = daria_scheme ∈ {21, 23}`, `daria_ram32`; registers `daria_profile <= tia_mode && daria_fbs ∈ {21, 23}`, `daria_ram32_r <= daria_ram32`, `daria_mres_r <= daria_reset` (P21) | beside detect2600, after `:319` |
| `daria_rt_hold`: set while `pll_busy_s[1]`, cleared 16 `clk_sys` after it falls (P20) | beside the reset register, `:166-172` |
| `reset <= … \| daria_hold \| (daria_rt_hold & daria_arm) \| …` with `daria_hold = daria_init_busy & daria_arm` (P6, P20) | `:169-171` (an `ifdef` / `else` pair around the statement) |
| `.loading (cart_download \|\| bios_download \|\| mapper_init_busy \|\| daria_hold)` | `:916` |
| `.cpu_ce (daria_pclk1)` | `:953` |
| The `main` instance's `daria_*` ports (2.3), nested as in `top.sv` | after the `POCKET_BUPCHIP` connections, `:984-992` |
| `bupchip` instance: `daria_profile`, `daria_ram32 (daria_ram32_r)`, `daria_pal = region_select` (`:863-864`), `daria_mreset (daria_mres_r)`, the call, RAM and ROM ports, `daria_cart_win`, `daria_smp_*`; `daria_halted` stays open until step 8 | `:1165-1203` |
| `u_fe` (2.1), with `cart_reset` gated as P20 and `dbg_locked`/`dbg_unlock` open | after `:1203` |
| `psram #(.CLOCK_SPEED(50.0))` (P18), and the comment rewritten | `:1206-1210` |
| Port comment (`clk_arm` is VCO/18) and header | `:12-13,27` (comments) |

Fix B (commit F, I2): four wires from `main`'s `POCKET_SRAM` block (`:971-984`) to new `sram` inputs `t_rd`, `t_wr`, `t_addr`, `t_wdata`, plus `.clk_sys (clk_sys)` on the `sram` instance (`:1093-1106`). `c_rd = cartram_rd | bios_rd` and the BIOS address mux stay (`DARIA_CORE.md:1500-1502`; the design's line references there are about 11 lines stale).

### 2.6 `src/fpga/core/sram_ctrl.sv` (Fix B, commit F)

As `DARIA_CORE.md:1479-1498` designs it:

- new inputs `clk_sys`, `t_rd`, `t_wr`, `t_addr[16:0]` and `t_wdata[7:0]`, registered into `t_*_q` on `posedge clk_sys` inside `sram_ctrl`;
- `t_key = {t_wr_q, t_addr_q}`, `t_new = (t_rd_q | t_wr_q) & (~t_last_v | t_key != t_last)`, and `t_last_v` replaces the `7FFFF` sentinel;
- `m_new` is the rising edge of `c_rd`/`c_wr` only;
- `cq_*` becomes a three-input mux in which `m_new` wins;
- `cp` loads `cq_*`;
- `t_last` loads on every `t_new`, as in the prototype; the benches assert that `m_new` and `t_new` never coincide (P2).

The header (`sram_ctrl.sv:34-36,60-67`) is rewritten. The current merged request is at `sram_ctrl.sv:210-234`.

### 2.7 Clocks, constraints and build files (lane I3)

| File | Change | Macro or condition |
|---|---|---|
| `src/fpga/core/pll/pll_core.v` | counter 3 lines (`:70`, `:146-152`) for C3 = 18: `output_clock_frequency3` about 38.18 MHz (the string as generated), `c_cnt_hi_div3`/`lo_div3` 9/9; header `:14-23` | `ifdef POCKET_DARIA` (P10) |
| `src/fpga/core/daria_constraints.sdc` (new) | `clk_sys`/`clk_arm` names; `set_max_delay 20` and `set_min_delay -20` in both directions (`DARIA_CORE.md:1306-1310`; the probe's lines, `sim/bupchip/quartus_probe/full/daria_probe.py:266-277`); the guard pair 6.000/1.000 ns (`design.md:1466-1473`); a fitter-only block, empty at D, for the ladder rungs of 5.2 and 5.3 | loaded only by its `SDC_FILE` line (P9) |
| `src/fpga/core/daria.qip` (new) | one `SYNCHRONIZER_IDENTIFICATION FORCED` instance assignment per first flop of the table below that lives in an existing file (P8) | loaded only by its `QIP_FILE` line |
| `src/fpga/core/core_constraints.sdc` | in commit F (I3 writes the hunk, reviewed in F's merge gate): the fitter padding into `clk_sdram` to 1.5 ns (`:57`) and the new hold line (P11), the fitter block's comment (`:46-54`), the `c_rdata` multicycle comment for Fix B (`:39-44`: a 2600 byte is written by E0+19 and latched at E0+24); in commit D: the clock-plan header (`:1-13`), comments only | none |
| `src/fpga/ap_core.qsf` | `VERILOG_MACRO "POCKET_DARIA=1"` after `:754`; `QIP_FILE core/daria.qip` and `SDC_FILE core/daria_constraints.sdc` after `:773` (P9); the seed comment `:759-765`; `SEED` set last, to a seed already fitted (P12) | |
| `src/fpga/core/core.qip` | after `bupchip/bup_cpu.sv` (`:75`): `daria_mem.sv`, `daria_call.sv`, `daria_mmio.sv`, `daria_smp.sv`, `bup_dbg_snap.sv`, then `daria_fe_pkg.sv` before the `daria_fe*.sv` files (the order of `sim/bupchip/quartus_probe/daria_wrap_map.sh:43-47`) | none (unused modules are not elaborated) |
| `src/fpga/core/bupchip/bup_dbg_snap.sv` (new) | open item 11 snapshot: a `clk_sys` request toggle every 1,024 `clk_sys`, two `clk_arm` flops (the first a FORCED scalar), capture into a hold register, an ack toggle back through two `clk_sys` flops (the first a FORCED scalar), `clk_sys` output register loaded on the ack | none (instantiated under `BUP_DEBUG` and `POCKET_DARIA`) |
| `bup_asset_wr.sv`, `bup_status_osd.sv`, `core_top.v` | comments: `bup_asset_wr.sv:8-9`, `bup_status_osd.sv:42-44` (the status now arrives through the snapshot), `core_top.v:312` | comment |
| `docs/DEVELOPING.md` | the PLL command's C3 values (P10); the seed and margin text (section 8) | |

The table below is the synchroniser list (P8) and contract F3. I3 writes it and `daria.qip`; I1 writes the scalar marks in the new files. Declarations are cited, not assignments. "In Build B" says whether the chain survives synthesis in the release build; 5.4 (c) and (f) expect exactly the chains marked yes, and Q5 those marked yes in its column.

| Direction | First flop (declaration) | In Build B | In Q5 |
|---|---|---|---|
| `clk_sys` → `clk_arm` | `hold_a[0]` (`bupchip_pocket.sv:214`) | yes | yes |
| | `pause_a[0]` (`:214`) | no: its input, `pause_core`, is tied 0 (`core_top.v:883`; `atari7800_pocket.sv:1173`), so synthesis removes the chain | no |
| | `prof_a[0]`, `ram32_a[0]`, `mres_a[0]` (`:227`) | yes | yes |
| | `cmd_s[0]` (`:419`) | yes | yes |
| | `tog_s[0]` (`daria_call.sv:71`) | yes | yes |
| | `sn_a[0]` (`daria_mmio.sv:142`) | yes | yes |
| | `t1` (`bup_asset_wr.sv:109`) | yes | yes |
| | `req_s0` (`daria_smp`, new) | yes | yes |
| | the snapshot's request flop (`bup_dbg_snap`, new) | no (`BUP_DEBUG`) | yes |
| | `cap_err_a[0]` (`bupchip_pocket.sv:550`) | no (`BUP_DEBUG`) | yes |
| `clk_arm` → `clk_sys` | `ready_s[0]` (`:372`) | yes | yes |
| | `halted_s[0]` (`:372`) | no: `daria_halted` has no load until step 8 (2.5) | no |
| | `run_s[0]` (`:455`) | yes | yes |
| | `ftog_s[0]` (`:498`) | yes | yes |
| | `en_s[0]`, `w_s[0]` (`daria_mmio.sv:183-184`) | yes | yes |
| | `ret_s1`, `ack_s1` (`daria_fe`, RTL attribute already) | yes | yes |
| | the snapshot's ack flop | no | yes |
| not a synchroniser | `pd_rx` keeps `OFF` (`daria_fe_guard.sv:47`) | yes | yes |

F3 also carries the expected list of crossing endpoints for 5.4 (k'): the first flops above plus the held-bus destinations, which I3 names from the RTL. The starting set: the capture message payload into the writer (`bup_asset_wr`'s `m_pl`, `m_type`), the `$8007` byte (`cmd_byte` → `cmd_data_arm`, `DARIA_CORE.md:294`), the audio frame (`frame_tog`'s held frame, `bupchip_pocket.sv:482-501`), `daria_mmio`'s TC write and snapshot words (`w_data`, `w_strb`, the snapshot word), `smp_addr` and `smp_data`, and the debug snapshot word (Q5 only).

### 2.8 What must not change

With `POCKET_DARIA` undefined, these files must preprocess to commit F's text: `top.sv`, `cart2600.sv`, `atari7800_pocket.sv`, `bupchip_pocket.sv`, `bup_asset_wr.sv`, `bup_asset_cache.sv`, `bup_status_osd.sv`, `pll_core.v`, `core_top.v`. The SDC set and the instance assignments must be identical, because only the three removed `ap_core.qsf` lines differ, and `core_constraints.sdc` changes after F only in comments (P11). The new `daria_*` and `bup_dbg_snap` files must contain no `` `define ``, `` `undef `` or `` `timescale ``, and nothing in the non-DARIA hierarchy may instantiate them. With the WRAPPER macro set (`POCKET_DARIA` without `NO_ARM_MAPPER`), `top.sv` and `cart2600.sv` must preprocess to `aeee6d2`'s text, so upstream's oracle in `tb_daria` is untouched. Methods are in 7.5.

---

## 3. Lanes

### 3.1 Ownership

A file has one owner at a time. Two files, `top.sv` and `atari7800_pocket.sv`, change hands once: I2 owns them until commit F merges, and I1 owns them after that. `POCKET_CHANGES.md` follows the same handover. No commit before F touches either file (the port shell S holds only `bupchip_pocket.sv`, 4.1). The lead owns merges, commit assembly, the Quartus queue and the project documents. Branches and worktrees are as P23.

| Lane | Files (owned) |
|---|---|
| **I1 wiring** | `cart2600.sv`; `bupchip_pocket.sv`; new `daria_smp.sv`; `daria_fe.sv` and `daria_fe_guard.sv` for P22's two outputs; new `sim/bupchip/daria/smp/` (its unit bench); after F: `top.sv`, `atari7800_pocket.sv`, `src/fpga/mister/POCKET_CHANGES.md` |
| **I2 Fix B** | `sram_ctrl.sv`; until F: `top.sv`, `atari7800_pocket.sv`, `POCKET_CHANGES.md`; `docs/SRAM_TIMING.md` |
| **I3 clocks, constraints, CDC** | `pll_core.v`; `core_constraints.sdc`; new `daria_constraints.sdc` and `daria.qip`; `ap_core.qsf`; `core.qip`; `core_top.v`; `daria_call.sv`; `daria_mmio.sv`; `bup_asset_wr.sv`; `bup_status_osd.sv`; new `bup_dbg_snap.sv` and its bench `sim/bupchip/dbgsnap/`; the fit scripts (`sim/bupchip/quartus_probe/full/`, plus a new `step7/` beside them); `docs/DEVELOPING.md` |
| **I4 benches** | `sim/run_sim.sh`, `sim/tb_load.sv`, `sim/tb_system.sv`, `sim/extra_tests.sh`, `sim/ar_test.py`; new `sim/cartram2600_test.py`, `sim/tb_cartram.sv`, `sim/tb_frames.sv`, `sim/check/` (checkers, `frame_gate.py`, `hygiene.sh`), `sim/tools/pp_equiv.py`, `sim/step7_gates.sh`; all of `sim/bupchip/s4/` (including `psram_model.sv`); `sim/bupchip/daria/` (`run_daria.sh`, `daria_shadow.svh`, `fe_shadow.svh`, `fe_taps.svh`, `tb_daria.sv`, `run_all.sh`, `fe_dir/`); `docs/ENVIRONMENT.md` |
| **I5 overlay** | deferred to step 8 (P16) |
| **I6 lean audio** (only on 5.1's trigger, after D) | new `daria_fe_audio_lean.sv`; `daria_fe_call.sv`, `daria_fe_arb.sv`, `daria_fe.sv` (the swap, taken over from I1); `sim/bupchip/daria/fe_unit/` |
| **I7 7800 decode lever** (only on 5.3's trigger) | decided when the worst path is known; vendored 7800 mapper files, under `ifdef POCKET_DARIA` (5.3) |
| **Lead** | `docs/DARIA_CORE.md`, all of `docs/daria_fe/` (`design.md`, `README.md`, `design_inputs.md`, `lanes/*.md`), `docs/daria_step7/`; merges; the Quartus queue |

### 3.2 Interfaces between lanes (reviewed and frozen on day 0)

Each contract gets a reviewer before it freezes (7.1).

| # | Between | Contract |
|---|---|---|
| F1 | I1 ↔ I4 | `bupchip_pocket`'s new port names and widths (2.2), committed first as the port shell S with tied-off outputs, as design 12.2 step 0 did (`design.md:1827`); `top.sv`'s and `cart2600`'s new port names (2.3, 2.4), frozen as text here and landing with D; the instance path `dut.u_fe` (P14) and `daria_fe`'s two new outputs (P22). Any change after that needs the lead's sign-off. |
| F2 | I2 → I1 | Fix B's four `top.sv` ports and the `sram` `t_*` and `clk_sys` ports (2.3, 2.5, 2.6), in F before I1 touches either file. |
| F3 | I3 → I1, I4 | The synchroniser table and the expected crossing endpoints (2.7); `daria.qip`; `bup_dbg_snap`'s ports (`clk_sys`, `clk_arm`, `d_arm[N-1:0]` in, `q_sys[N-1:0]` out; N set by I1's bit list); the file list for `core.qip`. |
| F4 | I1 ↔ I3 | Register names the SDC uses: `*\|daria_fe_guard:u_guard\|pd_tog` and `pd_rx` (`daria_fe_guard.sv:45-48`, instance `u_guard` at `daria_fe.sv:455`). The `CLOCK_SPEED` (I1) matches C3 (I3): 50.0 at both ÷18 and ÷19. |
| F5 | I3 ↔ I4 | The `clk_arm` lattice the benches use: half period 13.095 ns at ÷18 (1.5 × `T_HALF_SDRAM`), PLL phase 0 (`pll_core.v:71`); ÷19 = 13.82 ns with the VCO's edge pattern; one bench switch selects 18 or 19. |
| F6 | I4 → all | `sim/tools/pp_equiv.py` (from `$S7/rtl-wiring/pp_equiv.py`), the checkers in `sim/check/` and `frame_gate.py`, with exit codes, before any lane's gate depends on them. |

### 3.3 I1, wiring

- **Inputs:** sections 2.1-2.5; `design.md` 1.2, 1.6, 5.7 and 7.1; P20-P22; F2, F3.
- **Outputs:** the RTL of 2.1-2.5 (except Fix B's lines); `daria_smp.sv` and its bench; the `POCKET_CHANGES.md` hook notes.
- **Work order.** Before F: the port shell S (`bupchip_pocket.sv` ports only), `cart2600.sv`, `bupchip_pocket.sv`'s body (`daria_smp`, `ready_a`), `daria_smp.sv`, P22's two outputs. After F: `top.sv`, `atari7800_pocket.sv` (with P20 and P21).
- **Unit gate:**
  1. Verilator `-Wall` lint with zero new warnings in three macro sets: the shipped set, the shipped set minus `POCKET_DARIA`, and `run_daria.sh`'s WRAPPER set.
  2. `pp_equiv.py`: the non-DARIA stream hash equals commit F's, with 0 `daria` tokens. For the WRAPPER set, `top.sv` and `cart2600.sv` hash to `aeee6d2`'s.
  3. `tb_daria_smp`. It drives `bup_asset_wr` loading a 512 KB synthetic image into `psram_model`, then a CPU-side asset stream through the cache, then random sample requests at the ÷18 lattice's three phases and at random phases. It checks:
     - every request is answered once;
     - each answer is the image byte, checked against the cache's own `asset_q`;
     - the cache's `asset_q` stream is unchanged against a run without samples;
     - `psram_model` reports 0 violations;
     - requests during hold, load and in the Souper profile get `$FF` at once;
     - the maximum answer time is reported.
     It runs with `--x-initial fast` as the other benches, and again with `--x-initial unique` and `+verilator+rand+reset+2` over 5 seeds, because Quartus uses the initializers or Power-Up Don't Care (`run_daria.sh:137`; `run_sim.sh:12-21`). Mutants: ack before data; wrong byte lane; no answer when not readable; cache `rd_req` not masked; `ack` reset by hold (P7).
  4. `tb_load` smoke with I4's switch (3.6), on synthetic images from `sim/bupchip/daria/fe_dir` (`mkimg.py`; no game data):
     - one DPC+ image, one CDFJ image and the synthetic `digital` image above 32 KB (`design.md:1792,1804`) boot;
     - `init_busy` covers F6, and `a_f6_live` stays 0 (`daria_fe_copy.sv:260`);
     - the console reset releases once, after F6;
     - `call_tog` and `ret_tog` flip, and every call returns;
     - `psram_model` reports 0 violations, and the elaborated `CLOCK_SPEED` is 50.0 (P18);
     - a 7800 image with `bs_override` = 21 (`tb_load`'s existing `+bs=N`, `tb_load.sv:45-48`) and a 29,696-byte A78 produce no `daria_fe` RAM write and no `daria_hold` (the P5 test);
     - a non-ARM 2600 load releases the reset on the same edge as the non-DARIA build, from power-up and as the second load after an ARM image (`+image2`, `tb_load.sv:984-989`), and so does a 7800 load after an ARM image (the P6 tests).
  5. The scenarios of 7.3, with their criteria.
  6. After P22's change to `daria_fe.sv` and `daria_fe_guard.sv`: lint, `run_unit.sh` 10 of 10 and the 51 directed tests (`docs/daria_fe/README.md:29,37`); the diff adds two ports and their assignments and nothing else (reviewed).

### 3.4 I2, Fix B

- **Inputs:** `DARIA_CORE.md:1452-1673`; the prototype in `sim/work/fixb/` (gitignored), as reference only. Re-apply it to the current files rather than copying `sim/work/fixb/src/`, which predates decision 11 (`DARIA_CORE.md:1502`).
- **Outputs:** commit F's RTL (2.3 Fix B part, 2.5 Fix B part, 2.6); `POCKET_CHANGES.md` and `SRAM_TIMING.md` updates (`DARIA_CORE.md:1657-1661`).
- **Unit gate**, on I4a's in-tree harness (`sim/cartram2600_test.py`, `sim/tb_cartram.sv`), which merges in B0 before F, so that the gate can be reproduced from a clone:
  1. 8 images × blend off/on × {`aeee6d2`, F}: the criteria of 1.2 row 6, with each build's own buckets; Supercharger full, multiload and tape with `+cartram`; the P2 assertion armed in every run.
  2. Mutants, each caught by a named check:
     - `2deep` by the bucket (19);
     - `data_stale` by wrong bytes;
     - `nocmp` by the per-image read and write counts (the prototype's E7 run gave 1,268 reads and 2,590 writes against 1,819 and 3,995: `sim/work/fixb/logs/mut_nocmp_e7.log`, `fixb_e7_b0.log`);
     - `viacp` by the bucket (16);
     - `data_comb` only by STA (5.4 (g)), whose ability to fail is shown on Q0 seed 2's database (no `data_comb` fit is needed: `aeee6d2`'s merge has the same unregistered structure);
     - a forced coincident 7800 strobe in 2600 mode by the P2 assertion.
  3. `run_sim.sh` on F matches `aeee6d2` frame for frame on the `+fp` fingerprints (3.6), apart from 2600 RAM-mapper `c_rdata` latency.

### 3.5 I3, clocks, constraints and the snapshot

- **Inputs:** `DARIA_CORE.md` 7.3-7.5 (`:1305-1340`); `design.md` 8.2-8.3; open items 9-12; F4.
- **Outputs:** 2.7's files; the report Tcl of 5.4; the fit driver.
- **Fit scripts.** A step-7 driver (based on `run_full.sh`, which deletes the 2.1.2 baseline `base_s2` when given `BASE=1 SEED=2`: `run_full.sh:30-35`) with:
  - its own `WORK` (`sim/work/step7/fit`) and a `TREE=` argument (a worktree, P23);
  - `NODARIA=1`, which deletes the three DARIA lines of `ap_core.qsf` in the copy;
  - `PIN_ID=1`, which pins `apf/build_id.mif` (stamped by `apf/build_id_gen.tcl:74,132`);
  - `OLDPAD=1`, which puts `aeee6d2`'s `core_constraints.sdc` padding back in the copy (Q1b);
  - `DIV=18|19`;
  - a report Tcl for the checks of 5.4;
  - `full_summary.py`'s entity list extended to `daria_mem`, `daria_fe`, `daria_call`, `daria_mmio` and `daria_smp` (`full_summary.py:21-41`).
- **Unit gate:**
  1. The regenerated `pll_core.v` at C3 = 18, diffed against a fresh C3 = 24 generation: only counter-3 lines differ; the same for C3 = 19.
  2. `pp_equiv.py` identity for `pll_core.v`, `bup_asset_wr.sv`, `daria_call.sv` and `daria_mmio.sv` (non-DARIA: unchanged or unreferenced).
  3. `tb_dbg_snap`: a free-running `clk_arm` counter through the snapshot at the three lattice phases and at random phases, also with `--x-initial unique` and random power-up values over 5 seeds. Every `clk_sys` output word must be a value the counter held. A mutant that samples raw must be caught.
  4. The report Tcl, run on Q1 seed 2's kept database:
     - every DARIA check reports "no such cell" as a failure, not a pass (the vacuity guard of 5.4);
     - every Fix B check runs and prints its collections;
     - check (g) on Q0 seed 2's kept database finds the merged 2600 paths, so (g) can fail; then Q0's database is deleted.
  5. On Q1 seed 2's database, `quartus_sta` with `daria_constraints.sdc` added after the other files: the file reads without a missing-clock error, and its guard-pair lines match nothing (`-nowarn`), as expected without DARIA.
  6. On the same database, with the fitter-only guard (`core_constraints.sdc:55`) removed in a scratch copy: which value applies when a second `set_clock_uncertainty -add -setup` names a clock pair that `core_constraints.sdc` already pads (the later line replacing or adding). The answer decides how 5.2 and 5.3 write their DARIA-only rungs.

### 3.6 I4, benches

- **Inputs:** F1, F5, F6; `docs/ENVIRONMENT.md` 6-8; the scratch harnesses.
- **Outputs**, in order of need:
  - **I4a** (day 0-1, no RTL dependency):
    - `pp_equiv.py` into `sim/tools/`, with the guards of 7.5;
    - checkers for `run_sim.sh` and `extra_tests.sh`, with expected-line rules per case and exit codes. A "skipped" section fails (`run_sim.sh:243,288`); `TONE` rules depend on the case, since some BIOS cases legitimately print a ratio of 0.000 (`$S7/verif/run_sim.out:45,50`). `extra_tests.sh`'s multisprite rule is the header's (`extra_tests.sh:6-8`), and its POKEY and DLI statistics must equal the reference build's (7.5);
    - `ar_test.py` exit code;
    - `run_sim.sh`: the `daria_*` and `bup_dbg_snap` sources; `POCKET_DARIA` read from the qsf with a `DARIA=0|1` override, as `BUP_DEBUG` is read (`run_sim.sh:96-103`); a `VL_JOBS` override of the `-j 4` build (`run_sim.sh:106`); a game-free **DARIA section** in the DARIA build: `tb_load` on `mkimg.py`'s synthetic DPC+ and CDFJ images and the `digital` image above 32 KB, passing when each boots, every call returns, `psram_model` reports 0 violations, the guard locks with 0 unlocks and the image's self-check value (E2's directed-test convention, `sim/bupchip/daria/fe_dir/`) reads back;
    - `tb_load` and `tb_system`: a `clk_arm` lattice switch (F5) replacing the 2× clock (`tb_load.sv:22-26`, `tb_system.sv:30-33`); a `+fp=FILE` fingerprint, one line per frame at the rising edge of the core's `VSync` output (MARIA's in 7800 mode, the TIA's in 2600 mode), with `len_sys`, RIOT RAM, video, audio and a `cpu` column hashing the CPU's address, data and R/W at each CPU clock enable; `+retune=MS`, which drives `pll_busy` as `pll_region` does (`pll_region.v:12-15`) and stops `clk_sys`, `clk_sdram` and `clk_arm` for the reconfiguration (`tb_load.sv:121` ties it to 0 today); `+stop74`, which stops `clk_74a` (`tb_load.sv:21`, used only by the loader, `:74-78`) after the last load and restarts it before a `+image2` load; the P2 assertion; the P18 parameter check;
    - the cartram harness into the tree: `cartram2600_test.py`, a `+cartram` monitor in `tb_cartram.sv` (a wrapper around `tb_load`, like `tb_fixb.sv`), expected per-image counts with exit codes, the directed s19 run (another client's access placed at s8 by sweeping its start across every `clk_sdram` phase), and the `extra_tests.sh` section placed before the clones;
    - `sim/check/frame_gate.py` (P13), `sim/check/hygiene.sh` (7.7), `sim/step7_gates.sh`, one runner for every game-free gate with an optional directory of game images for the rest;
    - the `FE_PATH` macro in `fe_taps.svh`.
  - **I4b** (after S):
    - `tb_s4.sv` (`:212-219`) and `daria_shadow.svh` (`:147-161`) connect the new `bupchip_pocket` ports;
    - `build_s4.sh`'s DARIA list (`sim/bupchip/s4/build_s4.sh:42-46`) and `run_daria.sh`'s WRAPPER list (`run_daria.sh:97-102`) gain `daria_smp.sv` and `bup_dbg_snap.sv`;
    - `tb_s4` checks the snapshot: at the end of each run, after the FIFO has been idle for two snapshot periods, `dbg_status` equals the `clk_arm`-side word (a hierarchical tap), and the shadow minimum is compared with `minlev` and reported;
    - `run_daria.sh` lifts the `MODE_B`/`WRAPPER` refusal (`run_daria.sh:42`) so that `u_fe` runs on the wrapper's ports as `atari7800_pocket` wires it;
    - ÷19 options in `tb_s4` (only `+arm38` and `+arm15` exist, `run_s4.sh:29-30`) and in mode B.
  - **I4c:** `tb_frames.sv`, a wrapper around `tb_load` with:
    - `tb_daria`'s fingerprint (`tb_daria.sv:638-660`), tapped at the same signals inside the core's `main` instance (`top.sv`'s RGB on `ce_pix` outside blank, the RIOT RAM, `AUDIO_L`/`AUDIO_R`, the TIA's VSYNC bit), not on the Pocket's video path, so blend, border and overscan settings cannot change it;
    - `tb_daria`'s input script by frame (`tb_daria.sv:43-48,788`);
    - frames counted from the last reset release;
    - a `+frames` stop;
    - NTSC forced (`region_setting`), `BUP_DEBUG` off;
    - `calls.csv` in `tb_daria`'s columns (`tb_daria.sv:12`), and the late-call measure `tb_daria` uses (`tb_daria.sv:666-711`);
    - status lines: calls, late calls, halts, `halt_code`, PSRAM violations, `dbg_locked` and the `dbg_unlock` count (P22), checked against the internal taps;
    - `+stop74` on by default;
    - `-O3 --x-assign fast --x-initial fast`, as `run_daria.sh` builds.
- **Unit gate:**
  1. Each checker passes on `aeee6d2` logs and fails on planted faults: a wrong TONE ratio, `BIOS_BOOT FAIL`, a "skipped" line, a missing `PLL_REGION` line, an `ARCHECK` mismatch, a multisprite row shift. `frame_gate.py` fails on a truncated file, a one-frame shift, one changed RIOT byte, one changed pixel and a one-clock `len_sys` change.
  2. `pp_equiv.py` reproduces `fc52edb6bbcd10b3efcd66d6036b39426d4437668e53d4acf3f319c496416f52`, the sha256 of `$S7/rtl-wiring/pp_head_stream/stream.pp`, on `aeee6d2` (`hashes.txt` beside it holds only per-file locators).
  3. The in-tree cartram harness reproduces the step-1 numbers on the `aeee6d2` base, for example E7 with blend: 1,819 reads, 3,995 writes (`DARIA_CORE.md:1562`; `sim/work/fixb/logs/base_e7_b1.log`, the same as Fix B's).
  4. `tb_frames` and `tb_daria` plain give identical `fp.csv` over 1,500 frames for a non-ARM 2600 image (Juno First, F4, from `sim/work`), through FIRE at frame 420 and the joystick from 480, so the Pocket wrapper's input path is compared too. `tb_frames` with and without `+stop74` gives identical `fp.csv`. This proves the fingerprint, the inputs and the frame alignment before any ARM image runs.
  5. `tb_daria` with the `FE_PATH` change gives a byte-identical `frames.csv` for Mappy at 40 frames against the step-5 run.

### 3.7 I6, lean audio (conditional)

Trigger: 5.1. Scope: `design.md:1683` lever 4. Build `daria_fe_audio_lean` behind `daria_fe_audio`'s ports, rewrite `u_call`'s RD/APPLY, and reserve the S owner in `u_arb` (`docs/daria_fe/alternatives/lean.md`). `daria_fe`'s top ports, and so section 2, do not change.

Unit gate, as design 12.3 for audio, with `amp_lag` moved from must-be-0 to counted (`design.md:1685`):

- `tb_fe_audio` and `tb_fe_call`;
- the 51 directed tests;
- the random bench to 10^8 cycles;
- mode A on the 30 images;
- mode B at the three phases.

Then commit D's gates are repeated, a whole-commit review included. Estimate: 3-5 days [E], plus about 30 h of CPU.

---

## 4. Order, integration and the fit schedule

### 4.1 Commits, in merge order

Every merge waits for its unit gate **and** its reviewer's sign-off (7.1).

| Commit | Content | Merges when |
|---|---|---|
| **B0** (sim only) | I4a | its unit gate (3.6 1-3) passes |
| **S** (port shell) | `bupchip_pocket.sv`'s new ports with tied-off outputs (F1) | lint of the three macro sets; `pp_equiv` non-DARIA identity |
| **F** (Fix B) | I2's RTL; I3's `core_constraints.sdc` hunk (P11's padding and hold line, the `c_rdata` and fitter comments) | I2's unit gate passes, and I3's reviewer signs the SDC hunk. Build A's result is a step gate, not a merge gate; a structural failure there is fixed forward. |
| **B1** (sim only) | I4b and I4c | its unit gate (3.6 4-5) passes; needs S |
| **D** (DARIA) | I1, I3; the three `ap_core.qsf` lines | I1's and I3's unit gates pass; then the integration gate (4.2 phase 2) and a whole-commit review |
| **Fix-ups** | as needed | each re-runs the gates its change touches (7.6) |
| **Docs** | the lead's updates (section 8), `DARIA_CORE.md` "Step 7 work", section 9's hand-over | all gates in 1.2 hold on one tree; the numbers audit of 7.1 |

No commit contains game data, firmware or anything from `sim/work/`; `hygiene.sh` (7.7) runs before each merge.

### 4.2 Phases

Three simulation slots while no Quartus job runs, two while one does (the owner's answer to 6.2 question 1, 2026-10-09). The third slot's runs start only while Quartus is idle and are stopped (`SIGSTOP` on the run's process group) for as long as a Quartus job runs, then continued; a job counts as running while it holds `/tmp/daria_quartus.lock` or a container runs. Simulations run at `nice -n 10`; Quartus runs un-niced beside them.

| Phase | Days | Work | Machine | Reviews |
|---|---|---|---|---|
| 0 | 0 | Review and freeze F1-F6. Create the `base` worktree at `aeee6d2` and the lane worktrees (P23). Start dockerd (`ENVIRONMENT.md:181-197`). Fit Q0. Start R1 in `base`, scheme representatives first (P24's order). Baselines in `base`: `run_sim.sh` (done: `$S7/verif/run_sim.out`, exit 0 in 23 min 44 s), `extra_tests.sh` with `AR_TAPE=1`, `s4/check.sh` with the GAME argument and `REFDIR`; the `pp_equiv` hash (done) | Quartus Q0; slot 1 R1; slot 2 baselines | F1-F6 |
| 1 | 1-3 | I4a, then B0 (day 1); S; I2 (Fix B), I1 up to F, I3 (PLL, SDC, qip, snapshot, scripts); F merges (day 2-3), then Q1, Q1r, Q1b and I3's tests 4-6 on the kept databases; I4b and I4c, then B1 | slot 1 R1; slot 2 lane gates; Quartus after F | B0, S, F, B1 |
| 2 | 3-5 | I1 after F. The integration gate: the `tb_load` smoke and scenarios (3.3 4-5, 7.3); the whole-core directed set (7.3); `MODE_B=1 WRAPPER=1 WIN_KB=64` on Galagon, SF2fix, draconian, Turbo at phase 0 for 300 frames and Spiders for 600, Galagon and Spiders at 8,730 and 17,460 ps for 600; the `digital` image; `tb_frames` on Galagon, SF2fix, draconian and Turbo for 600 frames against R1's first 600 (frame gate rules). D merges at the end of day 5 | 2 slots | D (whole commit) |
| 3 | 5-6 | Q2 (Build B ÷18, seeds 1-3), then Q-mut. R2 starts at ÷18 on slot 1 (P24). Slot 2: `run_sim.sh`, `extra_tests.sh` and `s4/check.sh` on both builds of D (each build its own `WORK`, e.g. `WORK=sim/work/step7/rs_daria`; `extra_tests.sh` uses `run_sim.sh`'s `obj_load`, `extra_tests.sh:21`), the cartram matrix on D, the directed s19 run | Quartus; 2 slots | |
| 4 | 6-8 | R2 on both slots once the regressions end: the 16 runs at 1,500 frames, the phase runs (Galagon, Spiders at the other two phases, 600 frames), the 14 evidence images at 600 frames; triage (7.4) | 2 slots | frame-gate verdicts |
| 5 | 9-10 | Q4 (the non-DARIA identity fit), Q5 (seeds 1-3); final regression on the frozen tree (7.6); the fresh-clone run and `hygiene.sh` (7.7); docs; the numbers audit; step 7 done | Quartus; 2 slots | docs |
| slack | 11-12 | One fix-up round: a change after Q2 costs a new Q2 (about 1-1.3 h), the frame runs 7.6 asks for (3 images, or a full R2 of 13-15 h of wall time) and the regressions, about 1.5-2 days | | as 7.1 |

The full frame runs (R2) wait for D, not for Q2: if Q2 forces ÷19, R2 runs again at ÷19 (5.2). Beyond the slack: ÷19 adds about 2 days (Q3 rounds, R2 at ÷19, mode B and `tb_s4` at ÷19); the lean audio adds 4-6 days (3.7). The plan is 10 days with 2 days of slack; with ÷19 it is about 14, with the lean audio 16-18.

### 4.3 The fit schedule

All fits run one at a time under `flock /tmp/daria_quartus.lock` (`ENVIRONMENT.md:237-246`) in `raetro/quartus:21.1` (`ENVIRONMENT.md:172`), started with `setsid nohup` because of the 2-hour cap on background commands (`ENVIRONMENT.md:483-491`). Each uses the step-7 driver with `WORK=sim/work/step7/fit` and `KEEP_DB` off, except where stated.

| Fit | Tree | Seeds | Purpose | Time [E] |
|---|---|---|---|---|
| Q0 | `base` (`aeee6d2`), `NODARIA` | 1, 2, 3; seed 2 with `KEEP_DB=1` | baseline for Fix B's gain (P17); (g)'s negative control | 3 × 12 min |
| Q1 | F (Build A) | 1, 2, 3; seed 2 with `KEEP_DB=1` and `PIN_ID=1`, `du` polled | `DARIA_CORE.md:1633-1643`; the real database peak; I3's tests 4-6 | 3 × 12 min |
| Q1r | F | 2, `PIN_ID=1` | determinism: its `.rbf` must equal Q1 seed 2's, or Q4 falls back to the netlist comparison of 7.5 | 12 min |
| Q1b | F, `OLDPAD=1` | 1, 2, 3 | Fix B's gain apart from P11's padding (P11) | 3 × 12 min |
| Q2 | D (Build B), ÷18 | 1, 2, 3; seed 1 with `KEEP_DB=1` | the step gates of 5.1-5.4 | 3 × 18-25 min |
| Q-mut | D with two mutants: one `daria.qip` line removed, and `ready_a` bypassed | 1 | (f) and (k') each catch their mutant | 18-25 min |
| Q3 | D with a ladder rung (5.2, 5.3), or ÷19 | 1, 2, 3 | only on a 5.2 or 5.3 trigger | 3 × 18-25 min each round |
| Q4 | final tree, `NODARIA=1`, `PIN_ID=1` | 2 | bitstream identity with Q1 seed 2 (7.5) | 12 min |
| Q5 | final tree + `BUP_DEBUG` | 1, 2, 3 | the step-8 test configuration (P29) | 3 × 20 min |

Measured inputs for these estimates, from the step-3 probe logs (`$S7/timing-fit/fullprobe_measurements.tsv`):

- 2.1.2 full flow: 11 min 39 s;
- the ÷18 probe: 15 min 59 s to 16 min 26 s;
- fitter peak 3.30-3.41 GB of virtual memory, and 4 cores;
- the integrated core adds about 1.7-2.3k ALMs over the probe, hence 18-25 min per seed [E].

Those were measured one fit at a time. This machine has 4 cores and 15 GB (`nproc`, `free -g`), and phases 0, 1 and 3 run two niced simulations beside Quartus, so fits are budgeted at 1.3 × [E]; Q0 runs beside R1 and measures the factor. Totals: Q0 + Q1 + Q1r + Q1b + Q2 + Q-mut + Q4 + Q5 come to about 4.5-5 h of Quartus, about 6-6.5 h with the factor; each Q3 round adds about 1.2-1.7 h.

**Disk.** 5.7 GB was available when this plan was written (`df -h /`), and `ENVIRONMENT.md:493-497` has recorded as little as 2.8 GB. The ledger:

| Item | Size | Deleted |
|---|---|---|
| Worktrees (`base`, four lanes) | about 30 MB of source each, plus their `sim/work` | at step end |
| A `run_sim.sh` `WORK` per build | about 330 MB of objects; prune `.o` and `.gch` after each run | before the next build's regression |
| Verilator object directories (`tb_daria`, `tb_frames`, mode B) | 13-67 MB each (`sim/work/bupchip/daria/obj`, `obj_shadow64_fe_modeB`) | after each batch, except the pinned R1 binary |
| Q0 seed 2's database | under 1 GB [E] | after (g)'s negative control (phase 1) |
| Q1 seed 2's database | measured by Q1 | after I3's tests 4-6; its `.rbf` and reports are kept for Q4 |
| Q2 seed 1's database | as Q1 | after the docs |
| R1 and R2 run directories | small (74 MB for every step-5 and step-6 run so far, `sim/work/bupchip/daria/runs`) | kept |

- Rule: run `df -h /` before every fit and every frame batch, and do not start one with under 2 GB available. At most two Quartus databases exist at once.
- Never run `docker system prune -a` (`ENVIRONMENT.md:250`).

**CPU.**

- Rules: at most three simulations at once while no Quartus job runs, two while one does (4.2; `ENVIRONMENT.md:423-426` still says two and is updated with the docs commit), `nice -n 10`, and one Quartus job. `s4/check.sh` runs with `JOBS=2` (its default 3 breaks the rule, `ENVIRONMENT.md:426`). While Quartus runs, `run_sim.sh` builds with `VL_JOBS=2`.
- Budget [E]:

| Item | CPU |
|---|---|
| R1: 16 × 1,500 frames (33-44 min each), 14 evidence images × 600 frames, Juno First at 1,500 | 13-17 h |
| R2: 16 × 1,500 frames (95-105 min each, before `+stop74`), 14 × 600, the phase runs (4 × 600), the Juno First calibration twice, the pre-merge runs (4 × 600) | 42-47 h |
| Regressions: `run_sim.sh` (5 runs), `extra_tests.sh` (6 runs; `AR_TAPE=1` on `aeee6d2`, F and both final builds, about 75 min each at 7.7 ms/s for 34 emulated seconds: `sim/work/fixb/logs/fixb_e7_b1.log`, `extra_tests.sh:135`), `s4/check.sh` (5 runs), the cartram matrix, `MODE_B`/`WRAPPER`, the scenarios | 25-30 h |
| Mutation runs (I1's whole-core mutants, I2's, I3's snapshot, I4's planted faults) | 4-6 h |
| Reviewer-added tests (reserve) | 10 h |
| **Total** | **about 95-110 h, about 48-55 h of wall time at two slots** |

- Contingency, not in the total: a full R2 re-run (25-28 h); ÷19 (a full R2 plus mode B and `tb_s4` at ÷19, about 30-35 h); the lean audio (about 30 h).
- R2's per-run time is an estimate; the Juno First calibration (3.6 gate 4) measures it, with and without `+stop74`, and the schedule is re-cut then.

---

## 5. Gates and fallbacks

### 5.1 Area: the 84% guide

- **Guide:** 15,523 ALMs, 84% of 18,480 (`design.md:1656`). Decision 9 makes it a guide, not a goal: "step 7's fit decides" (`DARIA_CORE.md:39`; `design.md:1663`).
- **Projection** in "ALMs needed" (P25), the figure the percentage is computed from:

| Part | ALMs | Source |
|---|---|---|
| The ÷18 probe (S1 + Thumb, the 128 KB window, no front end, no Fix B) | 13,684-13,712 | `DARIA_CORE.md:339-341` |
| The rest of the memory system | 320-550 | `DARIA_CORE.md:362-365` |
| `daria_fe`, "ALMs needed" | 1,728-1,732 | `docs/daria_fe/README.md:33-34` |
| Fix B | −10 to +20 | `DARIA_CORE.md:1649-1651` |
| New in step 7: `daria_smp`, wrapper glue, P20-P21's registers | 60-120 [E] | |
| **Total** | **about 15,780-16,130, 85.4-87.3%** | |

  With `daria_fe`'s "placed minus [B]" (1,389-1,490) instead, the total is 15,440-15,890, 83.6-86.0%. The 64 KB window (decision 8) saves a little against the probe's 128 KB; it is not counted. M10K: 195 of 308 (`DARIA_CORE.md:1745`).
- **Rule:** area alone triggers nothing. A lever is taken only when Q2 fails a timing gate (5.2, 5.3) or the fit fails to route, and the failure is placement-driven. LAB use cannot tell: 2.1.1 already used 95% of the LABs at 79% of the ALMs (`SRAM_TIMING.md:75`). The report gives, per seed, three measures that vary between seeds, and the failure counts as placement-driven when two of them say so:
  1. the failing path has no more logic levels than the same path class in the ÷18 probe or in Build A (S1's execute path had 17-18, `DARIA_CORE.md:345`), while its interconnect delay is the larger share of the slack lost [E];
  2. the fitter's peak interconnect usage (fit report, routing usage) is at least 10 points above Build A's on the same seed, or the fitter reports routing hotspots [E];
  3. the worst 20 endpoints spread across three or more unrelated entities.
- **Order** (`design.md:1677-1685`):
  1. the exact levers 1-3, which save 70-105 ALMs with no exactness cost (levers 1 and 2) or the `refresh_overlap` class (lever 3), taken together in one Q3 round;
  2. lever 4, the lean audio (lane I6), which saves 200-250 ALMs and makes `amp_lag` a counted class.

  `daria_fe`'s ports, and so the wiring map, stay the same through all of them. Their timing benefit is not quantified: 70-250 ALMs is under 1.4% of the device, so the ladder may reach the owner's choice (5.3) sooner than the order suggests.
- **Report:** ALMs needed, the share of the device, LAB use, peak interconnect usage and M10K per seed.

### 5.2 Timing: `clk_arm` at ÷18, else ÷19

- **Gate:** `clk_arm` setup ≥ 0 at the worse of the two slow corners (1100 mV 85 °C and 0 °C) and hold ≥ 0 at every corner, on seeds 1, 2 and 3 (P12). The probe had +0.288 to +1.305 ns before the front end joined (`DARIA_CORE.md:335-345`).
- **If a seed misses**, the first rung is a DARIA-only fitter padding of about 0.3 ns on `clk_arm` → `clk_arm` setup, in `daria_constraints.sdc`'s fitter-only block (P9), refitted on all three seeds (Q3). It is not there from the start, because it competes for the fitter's effort with `clk_sdram`, the release gate.
- **Otherwise, ÷19** (36.17 MHz, `DARIA_CORE.md:360`):
  - select the ÷19 counter-3 lines (`c_cnt_hi_div3` 10, `lo_div3` 9, odd duty "true", as `daria_probe.py:248-256` derives them; regenerated per P10);
  - keep `CLOCK_SPEED` 50.0, and check 0 violations in `tb_s4` at ÷19;
  - run Q3.
- **What ÷19 costs:**
  - the guard never locks, so cart RAM collisions return to the counted race (`design.md:1500-1504`; risk 8 at `design.md:1721`);
  - the model has the same 16 late Spiders calls, and Qyx at 97% of its budget (`DARIA_CORE.md:360`).
- **Verification at ÷19:**
  - mode B on the ÷19 lattice, counting `coll_*` on the 5 images of phase 2;
  - `tb_s4` with the ÷19 option;
  - R2 and the frame gate at ÷19 (the guard's status line then expects no lock).
- The owner is told the result either way.

### 5.3 Timing: `clk_sdram` ≥ +1.5 ns

- **Gate:** worst setup ≥ +1.5 ns at the worse of the two slow corners on seeds 1, 2 and 3, and the worst hold over all clocks > 0 at every corner (`DARIA_CORE.md:1645`).
- **Known margins:**
  - Fix A's seeds: +1.17, +1.76 and +2.31 ns;
  - the ÷18 probe (no front end, no Fix B): +1.852, +2.210 and +2.998 ns;
  - 2.1.1, with the 1.0 ns fitter padding already in: +0.26, +0.44 and +0.28 ns at 79% (`SRAM_TIMING.md:77-82`);
  - Build A is expected at ≥ +2.5 ns (`DARIA_CORE.md:273-279,1633-1636`; `SRAM_TIMING_REVIEW.md:168-174`), judged on Q1b.
- **If a seed misses,** the report script classifies the worst 20 paths by start and end point, and the lever follows the class. No rung edits `core_constraints.sdc` or a vendored file outside `ifdef POCKET_DARIA`, so Q1 stays the non-DARIA baseline (P11, 7.6):

| Worst path | Lever | Exactness cost |
|---|---|---|
| any, first round | a DARIA-only extra setup padding into `clk_sdram` in `daria_constraints.sdc`, written per I3's test 6 (3.5), refitted on all three seeds | none (fitter only) |
| `fe_do` / `read_DB` → `cart_din` → `sdram\|data` | Under `POCKET_DARIA`, connect `ch0_din` to `ioctl_dout`. `ch0_wr` is 0 unless `cart_download` (`atari7800_pocket.sv:398-399`), and `sdram` uses `data` only for a write (`sdram.sv:80,95-100`), so the change is exact. It removes the 2600 bus from the `clk_sdram` cone. | none |
| `sram\|t_*_q` hold | already padded in F (P11); if it still fails, analyse | none |
| the 7800 cone (MARIA / 6502 halt → 7800 mapper RAM decode → `sram` pads) | lane I7: the 7800 mappers' RAM decode (`DARIA_CORE.md:1668`), under `ifdef POCKET_DARIA`, proven in the DARIA build by 7.5 row 5 | none expected; vendored change |
| Flicker Blend's `fbn_*` half-period paths | analyse; no lever is designed (`DARIA_CORE.md:1667`) | |
| spread / congested (5.1's measures) | 5.1's levers, then the lean audio | as 5.1 |

- **The end of the ladder:** if no lever closes the gate on all three seeds, the owner chooses between shipping with the measured margin and decision 1's fallback, the per-file bitstreams (`DARIA_CORE.md:31`).
- `DEVELOPING.md:413-417` (retry seeds below +1.0 ns) is updated to +1.5 ns.

### 5.4 The STA checks (step-7 report script, every Build B seed; Fix B checks also on Build A; the chain checks also on Q5)

Every check first asserts that its cell and register collections are non-empty and prints them. An empty collection is a failure (`DEVELOPING.md:375-380`), except for the chains 2.7 marks absent, whose absence is itself the expected result.

| # | Check | Pass |
|---|---|---|
| (a) | `report_timing -setup -from *u_guard\|pd_tog -to *u_guard\|pd_rx` | exactly one path, meeting 6.000 ns (`design.md:1490-1494`) |
| (b) | the same with `-hold` | exactly one path, meeting 1.000 ns |
| (c) | fit report, "Fitter Netlist Optimizations" | `pd_rx` and `pd_tog` neither duplicated nor retimed; the same for every first flop 2.7 marks present in this build; the ones marked absent are reported absent |
| (d) | the clock-network skew on the `pd_tog` → `pd_rx` path | read off and recorded |
| (e) | `report_sdc`, `report_exceptions` | `daria_constraints.sdc` read after the clocks exist (no missing-clock warning); the four ±20 ns lines and the 6/1 ns pair listed "Complete"; the `clk_arm` → `clk_sys` max and min lines overridden on exactly the `pd_tog` → `pd_rx` path and nowhere else |
| (f) | `report_metastability` and the fit's synchronizer list | every first flop 2.7 marks present identified, with the designation "Forced" (a chain Quartus found on its own does not count); no other forced chain. MTBF is reported where Quartus computes it and is information only: the ÷18 probe had 182 chains, 94.5% without MTBF, because these clocks are related |
| (g) | Fix B check 1, rescoped | No path from `cart2600` cells reaches `sram_ctrl` registers or the SRAM pads except through `sram\|t_*_q`. The design's form, "no `clk_sdram` path through `cart2600`" (`DARIA_CORE.md:1640`), would fail regardless of Fix B: `rom_a` and `d_out` already reach `clk_sdram` through `sdram`'s `ch0_addr`/`ch0_din` (`atari7800_pocket.sv:397-400`; `top.sv:1112`). The `ch0_*` legs are reported separately. The same query on Q0 seed 2's database must find `aeee6d2`'s merged paths (3.5 test 4), or the check is void |
| (h) | Fix B checks 2-4 | `t_*_q` → `clk_sdram`: setup ≥ +8 ns and hold ≥ 0; into `t_*_q` ≥ +40 ns; `t_*_q` not retimed into `cart2600` (`DARIA_CORE.md:1641-1643`) |
| (i) | open item 12 | the `c_rdata` multicycle slack; `fbn_*` → pads setup and hold |
| (j) | tripwire | 0 paths between `clk_arm` and `clk_sdram` or `clk_sys_90` (`full_report.tcl:50-65`) |
| (k) | crossings | every `clk_sys` ↔ `clk_arm` path timed against 20 ns, except `pd_tog` → `pd_rx`, timed against 6 and 1 ns; the slacks listed |
| (k') | crossing endpoints | every endpoint of a `clk_sys` ↔ `clk_arm` path, both ways (the probe had 61-63 one way and 33-34 the other, `DARIA_CORE.md:291-294`), is in F3's expected list; anything else fails. Every first flop's crossing path comes from one register with 0 logic levels (P21). This is what catches a raw crossing that the ±20 ns exceptions would otherwise pass, such as open item 11's (`DARIA_CORE.md:1288`) |
| (l) | per clock | setup and hold positive at every corner (`DEVELOPING.md:79-82`); the gates of 5.2 and 5.3 take setup at the worse slow corner; the Clocks table names match the SDC (`DEVELOPING.md:379`) |
| (m) | area | ALMs needed, share of the device, LABs, peak interconnect usage, M10K |
| (n) | `psram`'s parameter | the synthesis report's parameter table for `bup_psram` shows `CLOCK_SPEED` 50.0 (P18) |
| (o) | PSRAM pins | `report_datasheet` clock-to-output of `cram0_a`, `cram0_adv_n` and `cram0_oe_n`, and setup and hold of `cram0_dq`'s input registers (fast I/O registers, `ap_core.qsf:786-802`; there is no `set_input_delay` or `set_output_delay` for them), compared with the budget of `DARIA_CORE.md:1317-1327` (70 ns access, about 20 ns output-enable access) at the shipped divider. Reported, not gating: there is no board model; step 8 checks hardware (section 9) |

The guard's real-clock behaviour (lock, the phase-B edge, relock after a retune) cannot be seen by STA. Gate-level timing simulation is not available for Cyclone V in Quartus Lite [E]. Step 7 therefore delivers (a)-(e) plus the `tb_fe_guard` delay sweep (1-6 ns, `DARIA_CORE.md:626`). The real-clock check passes to step 8's overlay, which shows the lock state and an unlock count from P22's ports (`G_modeB.md:346-351`). STA models C0 and C3 with aligned rising edges (`phase_shift3` "0 ps" and both counters' `prst` at 1, `pll_core.v:70-71,125-152`); that is an assumption step 8 confirms on silicon (section 9).

---

## 6. Risks and open questions

### 6.1 Risks, most severe first

| # | Risk | Mitigation |
|---|---|---|
| 1 | `clk_sdram` under +1.5 ns on a seed at 85-87% fill. 2.1.1 had the same 1.0 ns padding and landed at +0.26 to +0.44 ns at 79%; Fix A's seed 1 had +1.17 ns at 68%; Fix B does not help the 7800 cone (`DARIA_CORE.md:1668`) | P11; Q1b isolates Fix B's gain; 5.3's ladder; the exact `ch0_din` lever |
| 2 | `clk_arm` at ÷18 misses: seed 2 had +0.288 ns before the front end, the state RAM, the second cache way, the MMIO and the sampler joined (`DARIA_CORE.md:335-345`) | 5.2's padding rung, then ÷19; the ÷19 PLL lines generated in phase 1 |
| 3 | Area at 85-87% [E] with routing congestion; the lean audio is not RTL (`design.md:1685`) | 5.1's measures; I6 scoped (3.7) so that it can start the day Q2 reports |
| 4 | The real hooks in `top.sv`, `cart2600.sv` and `atari7800_pocket.sv` never run on games in `tb_daria` (P4), so a hook bug could first show in the frame runs | `tb_frames` at 600 frames per scheme before D merges; R2 from D's merge (P24); the whole-core directed set |
| 5 | F6 during a PAL/NTSC retune (P20). Residual: a manual region change within F6's 0.15-0.6 ms after a load | P20 and the `+retune` scenario; the residual recorded for step 8 |
| 6 | R2 is the first run where DARIA's call length moves the 6507's timeline (P13); benign RIOT or audio differences could stall the gate, or hide a real one | `release_shift` defined by rule (7.4), with calls compared one by one; a second reader checks every classification (7.1) |
| 7 | The frame gate's cost (about 55-64 h of CPU for R1 + R2) and run length: each 1,500-frame run is about 1.6-1.8 h, close to the 2-hour background cap | R1 starts on day 0; `setsid`; one run per process, resumable by image; the calibration measures the time first; `+stop74`; `-O3 --x-assign fast` |
| 8 | A glitch or a raw crossing reaches a synchroniser and passes STA under the ±20 ns exceptions | P21; 5.4 (k'); Q-mut shows (k') failing |
| 9 | The sample requester is new `clk_arm` design and has never been simulated against real PSRAM arbitration. A lost or mis-taken answer silences or corrupts ROM samples (`daria_fe_audio.sv:144,435-436`) | P7 (answer every request, never reset); `tb_daria_smp` with mutants and random power-up; the `digital` image in `MODE_B`/`WRAPPER`, in `tb_load` and in `run_sim.sh`'s DARIA section |
| 10 | Fix B has no spare against the `c_rdata` multicycle (s19), and simulation has never produced the worst case (`DARIA_CORE.md:1551,1665`) | no retry (P2) and its assertion; the directed s19 run must reach 19; 5.4 (h)-(i); the per-build bucket rule |
| 11 | An ungated `scheme` lets F6 overwrite ARIA's RAM in the 7800 or Souper profile (`daria_fe_copy.sv:151-157`; `detect2600.sv:204-216`). A registered gate would miss `ld1` | P5; the 3.3 4 tests |
| 12 | The guard's SDC pair has never been timed in a full build: the block probe cut the clocks (`D_arb_guard.md:358`) | 5.4 (a)-(e); if (e) shows the pair overridden, the ±20 ns lines are rewritten with `-from`/`-to` register collections that exclude `pd_tog` and `pd_rx` (`remove_from_collection`), and (e) is re-checked |
| 13 | Mode B differs from the real wiring in at least 12 ways (`fe_shadow.svh:1043-1265`; `G_modeB.md:346-351`); the stall rise, `release_dup` and the `init_busy` → reset loop are not yet behaviour | the whole-core directed set; the `tb_load` smoke; the frame gate; the console-reset scenario (7.3) |
| 14 | The DPC+ copy holds the 6507 about 60 `clk_sys` longer per service (`E1_shadow.md:235`). Only Stratovox makes services | Stratovox is in the frame gate (P13) |
| 15 | A padding or vendored change after F silently voids the non-DARIA identity proof | P11's rule; 7.6 reopens Q1 and Q4 on any non-comment change to `core_constraints.sdc` |
| 16 | The schedule: one fix-up after Q2 costs 1.5-2 days; ÷19 or the lean audio push step 7 past day 12 | 2 days of slack (4.2); speculative R2 (P24); the owner is told as soon as Q2 reports |
| 17 | PSRAM I/O at 38.18 MHz with `CLOCK_SPEED` 50.0 is unverified by STA | 5.4 (o) reports it; step 8 checks hardware (open item 10) |
| 18 | Bench references rebuilt from lane edits mid-run | P23 (pinned `base` worktree, `NOBUILD=1`, logged HEAD and binary md5) |
| 19 | Disk (as low as 2.8 GB recorded), dockerd down after a VM restart, the 2-hour cap | 4.3's ledger and rules |
| 20 | Stale documents point implementers at old routes (`mapper_init_busy` through `cart2600`, `DARIA_CORE.md:1110,1252,1394`) | section 8; reviewers check against 2.1-2.6, not the stale text |

### 6.2 Open questions for the owner

Only what the documents do not settle. Each has a default, so no lane waits for the answer.

1. **Simulation slots.** May the two-simulation rule (`ENVIRONMENT.md:423`) rise to three while no Quartus job runs? R2 would drop from about 13-15 h of wall time to about 9-10 h. **Answered 2026-10-09: yes, three simulations while no Quartus job runs** (4.2).
2. **What "the same frames" requires** (P13). Default: video and frame length equal on every frame; RIOT RAM and audio equal, or a difference classed `release_shift` by 7.4's rule, because DARIA's calls end at different times than upstream's and the 6507 is held for the call. The stricter reading (every RIOT and audio difference outside Spiders blocks step 7) may not be reachable for any image whose code stores a timer value right after a call.
3. **Spiders after frame 573.** If Spiders' frames do not match again from 573, because DARIA's 16 late calls end later or earlier than upstream's and the game's state diverges for good, is that "overruns as on upstream" (`DARIA_CORE.md:1779`)? Default: accepted, and recorded, if the divergence starts in the overrun frames, every one of the 16 calls returns the same registers and RAM writes as upstream's (as step 5 showed, `DARIA_CORE.md:454-456`), and frames 1-556 match; otherwise a gate failure.
4. **F6 after a PAL/NTSC retune** (P20). Default: F6 runs once when the retune ends, so the restarted game starts from the same cart RAM as after a console reset. The alternative keeps the RAM through the retune, as `DARIA_CORE.md:1103` says; the restarted 6507 would then boot over RAM the game had already changed.
5. **Step 8's "late calls" source** (deferred, P16). The overlay must test the RIOT timer flag at the first timer read after a release; sampling it at release would count 0 instead of 16 on Spiders (`tb_daria.sv:666-711`; Spiders' `slack.csv:1114-1144`). That needs either one more `top.sv` export or a bus decode in the wrapper. Step 7 adds neither. Recommendation: decide at step 8, and prefer the bus decode, which keeps `top.sv` and `daria_fe` unchanged.

The decisions of 1.3 stand unless the owner overrules them. Those most likely to be questioned: P1 (Fix B in the base build), P13 (the frame-gate rules), P19 (the evidence images outside the gate) and P20 (F6 after a retune).

---

## 7. Verification and review

### 7.1 Adversarial review

Each lane gets one reviewer who did not write it. The reviewer:

- works from this plan's sections and the design documents, not from the implementer's notes;
- lists concrete failure scenarios (inputs, state, wrong output);
- turns each into a test or a mutant that the lane's bench must catch;
- signs off only when every scenario is closed or explicitly accepted by the lead.

A merge waits for the sign-off (4.1). Besides the lanes, these get a reviewer: the frozen contracts F1-F6 (day 0, before freezing); commit S; commit D as a whole (every hook, against 2.1-2.8, after the lanes' reviews); a conditional lane (I6, I7) when it starts; the frame-gate verdicts (a second reader re-runs `frame_gate.py` on the stored files and checks every `release_shift` classification against `calls.csv`); and the numbers in the final documents (each traced to a log on the final tree).

| Lane | Reviewer's brief |
|---|---|
| I1 | Port-by-port against 2.1, including widths, domains and the nesting of P4. Reset and load ordering: the `init_busy` → reset → `effective_reset` → `cart_reset` loop never dips and never re-triggers (`design.md:1335-1361`), at power-up, at a second load and across a retune (P20). P5 at `ld1`. The busys follow P3, with `mapper_init_busy` still 0. `fe_oe` reaches `out_en` for BANKDPCP and BANKCDF only. P21's three registers. `daria_smp` priority, ordering and reset rules against the cache. P22's diff. `CLOCK_SPEED`. |
| I2 | Against `DARIA_CORE.md:1479-1551`: the s9 start, s15/s19 landing, `cp`, the mux priority, that a 7800 or BIOS request and a 2600 request are mode-exclusive (P2), a repeated address at s11, the clear and SaveKey paths (`DARIA_CORE.md:1574-1588`); that `cart2600.sv` is untouched (`DARIA_CORE.md:1658`). |
| I3 | SDC precedence; that no clock-group cut voids the pair; that every chain in 2.7 is marked on its exact bit, no second stage or data bus is marked, and the absent chains are right; the expected crossing list; that the PLL diff touches only counter 3; the snapshot's handshake under every phase; report-script vacuity; F's SDC hunk. |
| I4 | That each bench can fail: planted faults per checker; the fingerprint catches a one-pixel change and a one-clock frame-length change; the frame alignment rule; the `+cartram` criteria are exit codes, not eyeballed; a skipped section fails. |

### 7.2 Mutation

Each mutant is caught by the check named, or recorded as equivalent with the reason.

| Lane | Mutant | Caught by |
|---|---|---|
| I1 | raw `fbs` as `scheme` | the A78 override test (3.3 4) |
| | `cart_win` one clock late, or held high | the F6 start check in `tb_load` (F6 at the window close, `design.md:239`) |
| | `daria_hold` left out of the reset | the `tb_load` smoke: the 6507 is released before F6 ends, and `a_f6_live` fires |
| | busys swapped, or left at 0 | the whole-core directed set (7.3): CDF's `LDA #` after CALLFN, the stall rise inside [E0+6, E0+17], `release_dup` |
| | `fe_oe` constant 1 | the whole-core directed set's RIOT RAM and TIA input read-back while an ARM scheme is active, if `out_en` reaches the bus outside cartridge space (`cart2600.sv:213-237`, `top.sv:391-393`); if I1 shows it does not, the mutant is recorded as equivalent |
| | `ret_tog`/`call_tog` crossed | the `tb_load` smoke: calls never return |
| | `CLOCK_SPEED` 28.636364 | `tb_load`'s parameter check and 5.4 (n) (P18); `psram_model` does not catch it |
| | `daria_ready` without `img_ready` | equivalent: `img_ready` is low only from a download's START to its END (`bup_asset_wr.sv:125-128`), and the console is in reset through every download (`atari7800_pocket.sv:169-171`) |
| | P20's gate removed | the `+retune` scenario (F6 writes while `pll_busy_s[1]` is high) |
| | `ready_a` bypassed | 5.4 (k') in Q-mut |
| | the five `daria_smp` mutants of 3.3 | `tb_daria_smp` |
| I2 | `2deep`, `data_stale`, `nocmp`, `viacp`, `data_comb`, the forced coincidence | as 3.4 2 |
| I3 | the guard pair removed | (a)/(b) find 0 paths: `quartus_sta` on Q2 seed 1's database with the altered SDC (minutes, no fit) |
| | a clock-group cut instead of the ±20 pair | (e) shows the ±20 lines overridden everywhere: the same method |
| | a missing synchroniser mark | (f) in Q-mut, which must flag the chain as not forced even if Quartus identifies it on its own |
| | a raw-sampling snapshot | `tb_dbg_snap` |
| I4 | planted log faults per checker; a forced one-pixel, one-RIOT-byte and one-`len_sys` change, a truncated and a shifted `fp.csv`; `tb_s4` with the snapshot bypassed | the checkers, `frame_gate.py`, `tb_s4`'s snapshot check |

### 7.3 Integration checks before the frame runs

Each scenario has its pass criteria; all run in `tb_load` (the real wrapper, `atari7800_pocket.sv` with `top.sv` and `cart2600.sv`'s hooks) on synthetic images unless a game is named, in which case the image comes from the main checkout's `sim/work`.

- `MODE_B=1 WRAPPER=1 WIN_KB=64` (I4b), as in phase 2. All of mode B's checks apply (`design.md:1507-1514`; `G_modeB.md`), and the call-by-call comparison with upstream continues. `WIN_KB=64` must be passed: `run_daria.sh` defaults to 128 (`run_daria.sh:92-96`). Spiders runs 600 frames wherever it runs, so its late calls at frames 557-572 (`DARIA_CORE.md:332`) are included.
- **The whole-core directed set:** the E2 directed images (`sim/bupchip/daria/fe_dir/`) that exercise the stall rise, `release_dup`, CDF's `LDA #` after CALLFN, and RIOT and TIA reads while an ARM scheme is active, run in `tb_load` with their expected values. Pass: every image's expected values.
- **A console reset** in a DARIA game (`+resetat`): F6 runs once, `init_busy` holds the reset through it, the game restarts, 0 halts.
- **A PAL/NTSC retune mid-game** (`+retune`, P20): no `daria_fe` cart RAM or state RAM write while `pll_busy_s[1]` is high or the clocks are stopped; exactly one F6, starting after `pll_busy_s[1]` falls; the console reset never dips from `pll_busy`'s rise to F6's end; `a_f6_live` 0; the cart RAM after F6 equals a power-up F6's; a non-ARM image's retune releases on the same edge as in the non-DARIA build. The bench stops the clocks; it cannot model glitches, which step 8 covers (section 9).
- **Second loads** (`+image2`): a 7800 Souper game after a 2600 ARM game and the reverse; an ARM image then a non-ARM 2600 image, and an ARM image then a 7800 image, each releasing the reset on the same edge as the non-DARIA build (P6). Pass: the release edges equal, no `daria_fe` RAM write in the second image's profile, the Souper game's song PCM-identical to its first-load run.
- **Decision 11 with ARM images:** the BIOS loaded and Skip BIOS off, a synthetic DPC+ and a synthetic CDFJ image (`run_sim.sh:186-200` covers only a non-ARM image). Pass: the BIOS does not run (`bypass_bios` 1), the image boots, calls return.
- **Turbo beyond the 64 KB window:** every call returns, cache misses reported, 0 PSRAM violations.
- **`tb_frames` before D merges:** Galagon, SF2fix, draconian and Turbo at 600 frames against R1's first 600, under the frame gate's rules.

### 7.4 The frame gate (P13)

- **R1, the references.** `tb_daria` plain with `+fp=1`, `DTRACE=0`, `WORK=sim/work/step7/ref`, in the `base` worktree with its binary built once (P23). A separate WORK is needed because `run_all.sh` skips runs whose report exists, and `FORCE=1` would overwrite step 5's runs (`run_all.sh:32-36`). The input script is the default (FIRE at frame 420, a random joystick from 480, seed 1), on the 15 demos and Stratovox at 1,500 frames, the 14 evidence images at 600, and Juno First at 1,500 for the calibration. Every run must show its load was seen (P27).
- **R2, the integrated runs.** `tb_frames` on the same images, frame counts and inputs. `clk_arm` runs on the lattice at phase 0. Galagon and Spiders also run at the other two phases, at 600 frames.
- **Pass, per image** (`frame_gate.py`, exit code):
  - both `fp.csv` files hold exactly the run's frames;
  - `len_sys` and video equal on every frame;
  - RIOT RAM and audio equal on every frame, or classed `release_shift`;
  - Spiders' rule from P13 applies;
  - the status lines show 0 halts, 0 PSRAM violations, the guard locked with 0 unlocks (at ÷18), and the call count and late calls equal to upstream's (16 on Spiders, 0 elsewhere).
- **`release_shift`.** Calls are matched by number between `calls.csv` files, and each call's release (the 6507's hold length) is compared. A RIOT RAM or audio difference is `release_shift` when all of these hold: it starts in a frame where some call's release differs from upstream's; `len_sys` and video are equal in that frame and every later one; and the column is equal again within 8 frames [E] and stays equal until the next shifted release. The gate reports, per image, the distribution of release differences and the `release_shift` count.
- **Audio** beyond `release_shift`: each first audio difference is traced to a counted class, `merge_race` (`G_modeB.md:61,318`), design 9.5's classes or `held_svc_race` (P28). An unexplained difference is investigated as a bug, from its first differing clock.

### 7.5 Equivalence

| Step | Proof | Against |
|---|---|---|
| Fix B (F) | Behavioural: the cartram matrix on `aeee6d2` and F; `run_sim.sh` and `extra_tests.sh` `+fp` fingerprints frame by frame (no difference outside 2600 RAM-mapper `c_rdata` latency), and `extra_tests.sh`'s POKEY and DLI statistics equal; Q0 against Q1 (area within −10 to +20 ALMs, `DARIA_CORE.md:1649-1651`) | `aeee6d2` |
| DARIA (D and later), text | `pp_equiv.py` with the qsf macro set minus `POCKET_DARIA`, over Quartus's file order, `ALTERA_RESERVED_QIS` defined: the stream hash equals F's, with 0 `daria` tokens once the new files (proved unreferenced) are excluded. The WRAPPER set's `top.sv` and `cart2600.sv` equal `aeee6d2`'s. Because `pp_equiv` drops comments and covers neither VHDL nor memory files (`$S7/rtl-wiring/pp_equiv.py:8-9,61`; `mister/rtl/dpram.vhd`), three guards go with it: the diff since F has no added comment containing `synthesis`, `altera_attribute`, `translate_off` or `(*`; `git diff --stat` shows no `.vhd`, `.mif` or `.hex` change; the `ap_core.qsf` diff is exactly the three DARIA lines, the seed comment and `SEED` | F |
| DARIA, constraints | `report_sdc` and `report_exceptions` of a non-DARIA fit equal F's; P9 makes this structural, and P11's rule keeps `core_constraints.sdc` fixed after F | F (Q1) |
| DARIA, netlist | Q4 against Q1 seed 2, both with `PIN_ID=1`: identical `.rbf`, valid only if Q1r showed Quartus reproducible. Otherwise, or if Quartus embeds something else that differs, the post-fit netlists of Q4 and Q1 seed 2 are exported and compared; the per-entity resource table alone does not prove equivalence | Q1 |
| DARIA build on non-ARM stimuli, the shipped build | `run_sim.sh` and `extra_tests.sh` stimuli and the cartram matrix, on the DARIA build and on the non-DARIA build: identical `+fp` fingerprints on every frame, the `cpu` column included (cycle identity), with P6 making the reset release identical; the `+image2` runs of 7.3 likewise. BupChip runs are compared by PCM (`pcm_check`, `run_sim.sh:273`), because `clk_arm` changes their timing. `extra_tests.sh`'s POKEY and DLI statistics equal | the non-DARIA build of the same tree |
| ARIA unchanged | `s4/check.sh` with `DARIA=0` and `DARIA=1`. `s1/check.sh` and `thumb/aria_equiv.sh` (`sim/bupchip/daria/thumb/aria_equiv.sh:4-23`) only if `bup_cpu.sv` changes (none is planned) | |

All lockstep comparisons use one Verilator binary per pair (`VERILATOR` set explicitly). `run_sim.sh` otherwise picks apt's 5.020 from `PATH` (`ENVIRONMENT.md:142-147`).

### 7.6 Re-run rule

- A gate result counts only for the tree it ran on, as its log's header records (P23).
- A change to a file re-runs every gate that covers that file:
  - **DARIA RTL** (`daria_*`, `bup_cpu.sv`, `bupchip_pocket.sv`'s and `atari7800_pocket.sv`'s DARIA lines, `bup_asset_*`, the `top.sv` and `cart2600.sv` hooks, `pll_core.v`): `MODE_B`/`WRAPPER`, the integration checks of 7.3, and the full frame gate. Only `bup_dbg_snap.sv` and lines visible only under `BUP_DEBUG` are exempt (below).
  - **`daria_fe*.sv`:** in addition, step 6's quick benches: `run_unit.sh`, the 51 directed tests, the random bench to 10^7 cycles, and mode A on the four scheme representatives.
  - **`sram_ctrl.sv` or `top.sv`'s `POCKET_SRAM` lines:** the cartram matrix and the directed s19 run.
  - **Any RTL:** `run_sim.sh`, `extra_tests.sh`, `s4/check.sh` and `pp_equiv.py`.
  - **Any non-comment RTL, SDC or qsf change after Q2:** a new Q2.
  - **Any non-comment change to `core_constraints.sdc` after F:** new Q1 (and Q1r) and Q4; Q0 against Q1 is then reported against the new Q1.
- **Exempt, when proven:**
  - comment-only edits: `pp_equiv.py` gives the same stream hash on both the DARIA and the non-DARIA macro sets, the directive guard of 7.5 finds nothing, and an SDC or qsf diff with comments stripped is empty;
  - the `SEED` line, set to a seed already fitted on the same tree (P12);
  - a change visible only under `BUP_DEBUG` (the release macro set's stream hash unchanged): re-runs only Q5 and `s4/check.sh`. Step 8's overlay falls here.
- The step closes on one tree on which every row of 1.2 holds.

### 7.7 Fresh clone and hygiene

- **Fresh clone.** On the final tree, the lead clones the repository into a new directory, provides the user's firmware and the game images by path (not copied into tracked paths), and runs `sim/step7_gates.sh` with a fresh `WORK`: every game-free gate (the lint sets, `pp_equiv`, the checkers' planted faults, the cartram matrix, `tb_daria_smp`, `tb_dbg_snap`, `run_sim.sh` with its DARIA section, `extra_tests.sh`, `s4/check.sh`). It must exit 0. This also shows that I2's gate no longer depends on the gitignored `sim/work/fixb/`.
- **Hygiene** (`sim/check/hygiene.sh`, before every merge): over `git diff aeee6d2..HEAD`, no file with a cartridge-image extension (`.a26`, `.a78`, `.bin`, `.rom`) or a binary over a size limit outside a whitelist; no `bupchip.*` firmware; no absolute path into a scratch directory or `/tmp`; and none of a list of assistant and model names, which is kept outside the repository, since writing it in would break the rule it checks.

---

## 8. Stale references to correct

Each is corrected by the file's owner (3.1) in that lane's commit; the lead owns every document under `docs/` except those 3.1 gives a lane, and checks the list with commit D's docs.

| Where | What is stale | Correct to |
|---|---|---|
| `DARIA_CORE.md:1110,1252,1394` | `mapper_init_busy` and ARM-scheme `ram_*` from the front end through `cart2600` | `design.md:428-438`, `design_inputs.md:705` (R2), P6 |
| `DARIA_CORE.md:1383` | `cart2600` takes `mapper_init_busy` from a port | only the busys, by P3 |
| `DARIA_CORE.md:1313` | synchroniser marks in `ap_core.qsf` | exact-bit instance assignments in `core/daria.qip`, and scalar RTL attributes in new files (P8) |
| `DARIA_CORE.md:298`; `DARIA_CORE.md:1305` (7.3's title); `design.md:442,1464` | the ±20 ns lines and the guard pair go in `core_constraints.sdc` | `core/daria_constraints.sdc` (P9) |
| `DARIA_CORE.md:1103` | PAL retune: cart RAM "kept" | F6 once when the retune ends (P20), unless the owner chooses otherwise (6.2 question 4) |
| `design.md:1179` | the sample requester reads "through the asset cache" | a requester beside the cache, at `bup_asset_wr`'s read port (P7) |
| `DARIA_CORE.md:1288` (7.1 row 9) | `bupchip_pocket.sv:383-386,427-430` | `:555-558,600-605` |
| `DARIA_CORE.md:1327` (7.4) | `atari7800_pocket.sv:1195-1198` | `:1206-1210` |
| `DARIA_CORE.md:1332` (7.5) | "C3 = 21 or 17, `DEVELOPING.md:245-271`" | C3 = 18 (÷19 fallback), `DEVELOPING.md:271-322` |
| `DARIA_CORE.md:1500-1502` | Fix B's `atari7800_pocket.sv` lines `:960-981,1082,1090-1093` | `:971-984,1093,1101-1104` |
| `DARIA_CORE.md:1640` | Fix B check 1 as written | 5.4 (g) |
| `design.md:439` | `.loading` at `atari7800_pocket.sv:905` | `:916` |
| `design_inputs.md:719` (R16) | `atari7800_pocket.sv:1047,1258` | `:1058`, `:863-864` |
| `design.md` 9.5 | no `held_svc_race` | the class, with E3's condition (P28) |
| `DEVELOPING.md:287,292` | the PLL command's `gui_output_clock_frequency3=28.636363` and `gui_divide_factor_c3=24` | C3 = 18's values (P10) |
| `DEVELOPING.md:317-322` | `psram.sv` keeps 28.636364 "whatever the divider" | 50.0 under `POCKET_DARIA` (P18) |
| `DEVELOPING.md:389-393,413-417`; `ap_core.qsf:759-765` | seed and margin text from 2.1.1 (+1.0 ns retry) | Build B's seeds; +1.5 ns |
| `SRAM_TIMING.md:4,152-156` | "For DARIA" bullet; "none exists yet" | superseded by decision 4 and Fix B |
| `bupchip_pocket.sv:7-9`, `bup_status_osd.sv:42-44`, `core_constraints.sdc:8-13`, `core_top.v:312`, `atari7800_pocket.sv:13,27`, `bup_asset_wr.sv:8-9` | `clk_arm` = 2 × `clk_sys` | VCO/18 (in the owning lanes' commits) |
| `ENVIRONMENT.md:381`; `run_daria.sh:12` | "about 1 min of wall time per emulated second" | measured: 79-104 s of wall time per emulated second for a plain build; mode B runs at 3.5 simulated ms per wall second, about 286 s per emulated second |
| `docs/daria_fe/lanes/B_audio.md:279`, `D_arb_guard.md:328` | "Quartus 21.1 Standard" | Lite (`ENVIRONMENT.md:162,165`) |

---

## 9. Hand-over to step 8

Written into `DARIA_CORE.md` with the docs commit:

- **Fix B on hardware:** Fix A's list plus a Superchip game, an E7, a 3E and a CV title, a Supercharger multiload end to end (`DARIA_CORE.md:1670`), and the Supercharger tape path (`AR_TAPE`).
- **PSRAM at the shipped divider with `CLOCK_SPEED` 50.0** (open item 10, `DARIA_CORE.md:1797`): the BupChip's ARSC readback (`DARIA_CORE.md:1327`), and Turbo, which reads beyond the 64 KB window through the cache; 5.4 (o)'s I/O figures for reference.
- **The shipped `SEED`** and its Build B timing reports; Q5's seeds for the test builds (P29).
- **The guard on real clocks:** the overlay shows `dbg_locked` and an unlock count (P22). Expected: locked after power-up and after every retune, 0 unlocks. This also confirms the assumption that C0 and C3 rise together on silicon (5.4's closing note).
- **A PAL 2600 ARM image on Auto region** (Stay Frosty 2's PAL build, for one): one retune soon after start, one F6 after it, the game restarting in PAL (P20). The residual case, a manual region change within 0.6 ms of a load, is noted, not tested.
- **The counted classes expected on hardware:** R2's `release_shift` counts and release differences per image, `merge_race`, design 9.5's classes; Spiders' overrun frames as measured.
- **The late-call source** (6.2 question 5), and the call counter from `call_tog`, both under `BUP_DEBUG` only, so that step 8's changes fall in 7.6's `BUP_DEBUG` exemption.

---

## 10. Review responses

Every finding of both reviews was checked against the RTL and is folded into the sections above. These are the places where the plan departs from a reviewer's suggestion, or chooses between the options a reviewer offered:

1. **F6 during a retune** (P20): fixed in the wrapper, not in `daria_fe`'s `rst_rise`. Both work; the wrapper keeps `daria_fe`'s RTL, and so step 6's evidence, as it is. A retune that starts during F6 needs a manual menu change within 0.6 ms of a load, because on Auto region the 6507 is held through F6 and the TIA cannot detect PAL then; deferring `pll_region` while F6 runs would add a crossing into `clk_74a` in `core_top.v` for that case, so it is recorded instead.
2. **Synchroniser marks** (P8): the qip's exact-bit assignments, not split declarations, because `mmio`'s bench and mutants tap `en_s[1]` and `w_s[1]` by name. New files use scalar RTL attributes. The reviewer's other point stands: the plan's old line numbers were assignments, now declarations.
3. **P2:** the retry is dropped rather than kept beside an assertion. With the modes exclusive, the retry would never run in a correct design, and if it ever did it would breach s19 silently.
4. **Padding:** the hold line into `clk_sdram` goes into F at 0.1 ns from `clk_sys` only (the `t_*_q` edge), not from every core clock. The `clk_arm` padding is a ladder rung, not in D from the start, because from the start it competes with `clk_sdram`, the release gate. The reviewer's "one Q1 seed at 1.0 ns" becomes Q1b on all three seeds, so that it compares with Q0's three. The revision-1 diagnostic refit at 1.0 ns is dropped: its result could not be adopted without editing the shared file.
5. **The ±20 ns exceptions** stay clock to clock, the form open item 9 settled (`DARIA_CORE.md:1796`); the endpoint audit (k') adds the protection the reviewer asked for, without per-path exceptions.
6. **Step-8 exports** (P22): only the guard's lock and unlock go out of `daria_fe` now. Call counts come from `call_tog`, and the late-call source is undecided and needs no `daria_fe` port either way; with 7.6's `BUP_DEBUG` exemption, step 8 then re-runs only Q5 and `s4/check.sh`.
7. **Q5's gates** (P29): fitted on three seeds as asked, but held to timing ≥ 0 on one seed, not to +1.5 ns. `DARIA_CORE.md:1645` calls +1.5 ns the release gate, so the documents settle this; it is not an owner question.
8. **(g)'s negative control** uses Q0 seed 2's kept database instead of a `data_comb` fit: `aeee6d2`'s merged request has the same unregistered structure, and it costs no fit.
9. **`extra_tests.sh`'s POKEY and DLI sections** get a criterion by equality with the reference build's statistics, not domain thresholds. That needs no owner decision and fails on any change.
10. **The `tb_daria` load race** (P27) is accepted with a per-run check rather than fixed, since the fix would move every step-5 and step-6 baseline by a clock.
11. **The calibration** runs 1,500 frames, the reviewer's preferred length. The evidence images move to 600 frames, and are the first thing cut back if the schedule slips.
12. **The PSRAM pins** (5.4 (o)) are reported, not gated: without a board model, a pass or fail threshold would be invented.
13. **The `daria_ready` without `img_ready` mutant** is recorded as equivalent, not given a catcher: no reachable state has the CPU parked, the image not ready and the console out of reset.
14. **The s19 bound and the wiring map:** the reviewers confirmed both against the RTL (Fix B's worst case lands exactly at s19; the ports, widths, domains, the `ch0_din` lever and P6's ordering hold). Nothing changes there beyond the corrections above.
