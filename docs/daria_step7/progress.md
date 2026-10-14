# DARIA step 7: progress

Results as they land, against `plan.md`. Figures are from the lane logs named; the lanes' worktrees and logs are gitignored scratch, so each result here also names its commit.

## Phase 0 (2026-10-09)

- **Base worktree** at `aeee6d2`, detached. **R1** (plan 7.4) started there at 15:22 UTC: `tb_daria` plain, `+fp=1`, `DTRACE=0`, one binary (Verilator 5.040) for every run. From 15:44 two claim-aware workers share the list; the second is the third simulation slot (plan 4.2) and stops while a Quartus job runs.
- **Owner, question 1 (6.2):** three simulations while no Quartus job runs.
- **R1 finished** on 2026-10-10 at 01:12 UTC: 31 of 31 runs (16 at 1,500 frames, 14 at 600, Juno First at 1,500), about 45 minutes per 1,500-frame run. Two runs cut by a container restart were rerun from the start. `fp.csv` holds frames 1 to N−1. Juno First's `summarize.py` fails on its zero calls; its fingerprints are complete.

## Phase 1

### Q0: `aeee6d2`, seeds 1-3 (plan 4.3) [sta]

| Seed | `clk_sdram` worst setup, worse slow corner | Worst hold (`clk_sys`, fast 0 °C) | ALMs needed | LABs | Peak interconnect | M10K | Flow time |
|---|---|---|---|---|---|---|---|
| 1 | +1.822 ns (0 °C) | +0.095 ns | 13,003 (70%) | 1,680 / 1,848 | 43.0% | 78 / 308 | 12:48 |
| 2 | +1.850 ns (0 °C) | +0.095 ns | 13,021 (70%) | 1,683 / 1,848 | 40.4% | 78 / 308 | 12:42 |
| 3 | +1.735 ns (85 °C) | +0.068 ns | 13,021 (70%) | 1,704 / 1,848 | 43.6% | 78 / 308 | 12:40 |

- Every clock meets setup and hold at all four corners on all three seeds. `clk_arm` (still 2 × `clk_sys` here) worst setup +8.034 / +9.253 / +9.175 ns.
- Fits beside two simulations ran about 1.1 × the single-fit times (plan 4.3 budgets 1.3 ×). A kept database is about 110 MB, not 1 GB.
- On `aeee6d2` the `clk_sdram` worst path runs from MARIA's enable through `cart2600`'s decode to `sram_ub_n`.

### STA tests on Q0 seed 2's database (plan 3.5 items 4-6)

- **Vacuity:** every DARIA check with no cells fails "no such cell" ((a), (b), (c), (d), (e), (f), (k'); 13 first flops missing). (k) fails on 93 real ARIA crossings timed at the edge relationship (34.921 / −0.001 ns), as expected without `daria_constraints.sdc`.
- **(g) can fail:** it finds 18,734 paths through `cart2600` into `sram_ctrl` registers on `aeee6d2`, 6,179 of them starting at `cart2600` registers (for example `mapper_E7` bank → `sram_ub_n`, `sram_a`, `dq_out`).
- **Test 5:** `daria_constraints.sdc` read after the other files: no missing-clock warning; the ±20 ns lines are Complete and move all 93 ARIA crossings to 20 / −20 ns. The guard pair matches nothing and gives 4 × Warning 332049; kept as a tripwire (5.4 (e)).
- **Test 6:** a later `set_clock_uncertainty` on a transfer replaces the earlier one; padding rungs state the total (5.2).

### Lane I1, before F (`s7/I1`, head `d3d2c4b`)

- Commit S `8b5c6ea` (port shell only); `cart2600` hooks `77e9f0f`; `daria_smp` and `tb_daria_smp` `b83a20e`, `24e29de`, `d3d2c4b`; `bupchip_pocket` body `8f23f80`; P22 `a69a59b`, `36d1e42`.
- Gates: lint (no new warnings beyond the PINMISSING of instances wired after F); `pp_equiv` non-DARIA stream `fc52edb6…`, identical to `aeee6d2`; `tb_daria_smp` gate (five phases with and without samples, five `--x-initial unique` seeds, three past-the-image seeds, 8 of 8 mutants caught), seed sweeps 50 of 50; P22: `run_unit.sh` 10 of 10, 51 of 51 directed tests, random bench 4 seeds to 10^7 cycles, each identical to step 6.
- Review: no RTL defect; one major (the bench owed the wrong byte for a request past a reloaded image's end) fixed in the bench. Recorded: the second mask gate on `rd_ack` (plan 2.2 amended), `daria_smp`'s upset exposure (section 9).
- **P22 under plan 7.6, mode A** on Galagon, SF2fix, Draconian (RC8) and Turbo at 1,500 frames, on lane I1's tree: "no failures" on all four, and the 102 `fe.csv` columns shared with step 6's mode A runs are byte-identical (the two later columns, `obus_ffe` and `commit_pclk1`, came with the F1 bench after step 6's binary was frozen).
- `8f23f80` breaks the DARIA bench builds until B1 adds `daria_smp.sv` to their source lists, so it merges with B1, not before.

### Lane I3 (`s7/I3`, head `684ec29`)

- F's SDC hunk `d53c1a1` (only `core_constraints.sdc`); the qsf commit `684ec29` last, held back until D.
- PLL: regenerated at C3 = 24, 18 and 19; C3 = 18 differs from 24 in three counter-3 lines, selected by `ifdef POCKET_DARIA`. `pll_region` writes only registers 7 and 2, so C3 survives a retune.
- **Blocker found and fixed:** Quartus rejects `SYNCHRONIZER_IDENTIFICATION` in a `.qip` (Error 125091); the marks moved to `core/daria_sync.tcl` (plan P8 amended).
- `bup_dbg_snap` and `tb_dbg_snap`: 32 of 32 runs, 7 of 7 mutants (raw sampling and half rate included).
- Fit driver `run_step7.sh` (exit 0 pass, 3 fail verdict, 1 compile failure, 2 refused), report Tcl and checker; `selftest.sh` 47 of 47 without Quartus, 13 of 47 on the pre-review scripts; a small fitted smoke design exercises `daria.qip`, (f) and (k').
- Review: three majors fixed (the driver could delete protected directories; (k') failed benign one-level first flops, now judged on the whole fan-in; a verdict could pass with gating checks that never ran).

### Lane I2, Fix B: review finding (2026-10-10)

- The adversarial review found that P2 ("a 7800 or BIOS request and a 2600 request never meet") is false at a console reset: on one `clk_sys` edge Fix B drops the 2600 cartridge-RAM access that `aeee6d2` performs, writes included, for RAM at `$Fxxx` (A15 = 1), as Superchip and Supercharger code uses. The lane's own probe used `$1xxx` addresses and could not see it. Being fixed, with a directed reset sweep that must fail before the fix.

### Main's 2.1.3 (2026-10-10): the picture window and the SRAM margin

`origin/main` gained 2.1.3: `video_sync.sv` moves the NTSC 224-line window from MARIA lines 24-247 to 27-250. Its release fit reports `clk_sdram` +1.60 ns against 2.1.2's +1.92 ns (seed 2, slow 85 °C).

- **2600 output is unchanged.** `vblank_ex` reaches only the MARIA side of `video_mux` (`top.sv:584`); a whole-core `tb_daria` run of Galagon at `aeee6d2` plus the change gives an `fp.csv` byte-identical to R1's first 149 frames, so R1 stays the reference for R2.
- **Seed-matched fits** [sta], worse slow corner, seeds 1 / 2 / 3: 2.1.2 +1.198 / +1.806 / +2.303 ns (12,863-12,902 ALMs); 2.1.3 +1.148 / +1.596 / +1.165 ns (12,902-12,909 ALMs). Both seed-2 fits reproduce the release figures exactly. Worst hold +0.04 to +0.11 ns everywhere.
- **Why.** The changed signal is on no `clk_sdram` path (one more LUT in `video_sync`, feeding only `video_mux`'s `vblank` register, 60 ns of slack). But Quartus re-synthesises the whole design for any edit: 123 of 892 entities change their LUT counts, registers identical. In 2.1.3 synthesis built the 2600 data leg differently (one more level after mapping): cartridge size or type registers → `cart2600`'s data mux → `read_DB` → `cart_din` → `cartram_wrdata26` → the merged write data → `sram` → `dq_out`. That leg is the worst path in all three 2.1.3 fits, at least 0.67 ns worse on average than in 2.1.2 (three seeds each, no overlap; one-sided p = 0.05), on top of a seed scatter of up to 1.1 ns. A first explanation that blamed `sram_ctrl`'s request logic was refuted by a second reviewer: that leg shows no consistent change.
- **For step 7.** Neither 2.1.2 nor 2.1.3 meets +1.5 ns on every seed, so the release gate rests on Fix B moving the 2600 legs, this data leg included, onto `clk_sys` registers; check (g) on Q1 shows whether it does. Main merges as commit M after Q1/Q1b, F's behavioural runs and B1, before D; Q4 is then compared with a fit of M (Q1'), and D's text identity with M (plan 4.1, 4.3, 7.5).

### Fits Q1, Q1r, Q1b: Fix B (F = 20c7c2a), seeds 1-3 (2026-10-10) [sta]

| Fit | `clk_sdram` worst setup, worse slow corner, seeds 1 / 2 / 3 | Worst hold | ALMs needed | Peak interconnect |
|---|---|---|---|---|
| Q0 (`aeee6d2`, 1.0 ns padding) | +1.822 / +1.850 / +1.735 | +0.068 to +0.095 | 13,003 / 13,021 / 13,021 | 43.0 / 40.4 / 43.6% |
| Q1 (F, 1.5 ns padding) | **+2.390 / +1.873 / +2.714** | +0.096 to +0.108 | 12,896 / 12,896 / 12,885 | 40.0 / 36.1 / 42.2% |
| Q1b (F, 1.0 ns padding) | +2.064 / +1.945 / +2.385 | +0.083 to +0.106 | 12,860 / 12,904 / 12,876 | 40.0 / 44.0 / 39.3% |

- **F meets the +1.5 ns gate on all three seeds**; the smallest margin is seed 2, +0.37 ns above it. Q1r (seed 2 again) gave a byte-identical `.rbf`, so Quartus is reproducible here and Q4 can use bitstream identity.
- **Fix B's gain on three-seed distributions:** +0.52 ns on the mean against Q0 (no overlap), +0.33 ns with the old padding (Q1b, no overlap), +1.02 ns against 2.1.3. The padding alone (Q1 against Q1b) is +0.20 ns on the mean with overlapping seeds, not established. The design's "≥ +2.5 ns on each seed" for Build A is not met, because the worst path has moved to classes Fix B does not touch.
- **Worst paths now:** neither 2600 leg anywhere (the `t_*_q` request paths are at +5.28 ns or better). Q1 seed 1: Flicker Blend's half-period capture into `fbn_wdata`. Q1 seeds 2 and 3: the 7800 cone's SDRAM request (`cart_extent` → 7800 `bank_map` → `ch0` address → `sdram|ram_req`), which Q0 already had at +2.40 to +2.45 ns. The `ch0_din` leg (`read_DB` → `cart_din` → `sdram|data`), which DARIA's `fe_do` joins, is at +2.42 to +3.43 ns.
- **Check (g)** passes on Q1: no path from `cart2600` or `read_DB` reaches `sram_ctrl` registers or the SRAM pads except through `t_*_q`; the `c_rdata` → `t_wdata_q` paths run under the multicycle (+78.6 ns). **Check (h)**'s [E] bound of +8 ns is missed on every Fix B fit (+5.28 to +6.59 ns, 6 levels); the plan now asks for +4.5 ns (5.4 (h)).
- **Area:** Fix B saves 107-136 ALMs (the design estimated −10 to +20); 25 `t_*_q` registers survive synthesis (two address bits are constant).
- **For Build B:** about 0.4 ns of headroom at F's worst seed and 0.8 ns on average, with about 3k more ALMs to come. The classes that set the margin have no designed lever yet beyond the DARIA-only padding rung; plan 5.3 now lists the 7800 SDRAM request.

### Phase 1b: lanes I1 (after F) and I4 (B1), and merges (2026-10-11)

- **Lane I1** (`s7/I1` at `d0c7ba0`, reviewed, fixes made): `top.sv` and `atari7800_pocket.sv` wiring (P5, P6, P14, P18, P20, P21), the `bup_dbg_snap` instance. Its whole-core bench `tb_wire` passes 88 scenarios with 51 directed images (release edges against the plain build, console resets at the menu's 49-clock length, retunes in mid-game, in a call and in a long DPC+ service, back-to-back retunes, second loads both ways, Souper PCM, decision 11, Turbo beyond the window); 9 mutants caught, 2 equivalent.
- **Two retune hazards found and fixed** in the DARIA wiring (plan P20 amended): a DPC+ service running into a retune wrote front-end RAM while `pll_busy` was high (61 writes at ÷19, two with the write enable high as the clocks stopped); and on Auto the wrapper retuned at a 2600 load's end while F6 ran, from a stale header byte.
- **A shipped-core finding, for the owner:** in the non-DARIA build, and in main's 2.1.3, a PAL 2600 game on Auto region retunes forever: each retune's reset clears `tia_en`, so `region_select` falls to `cart_region[0]` (bit 0 of ROM byte 57 for a `.bin`) and asks for NTSC, and the release asks for PAL again (41,293 retunes in 1.3 simulated seconds with `pll_region` in the loop). The `tia_pal_seen` latch meant to stop this is bypassed during the reset. The DARIA build retunes once and stays PAL.
- **Lane I4** (`s7/I4` at `092e63e`, reviewed, fixes made): `tb_frames`, whose Juno First `fp.csv` is byte-identical to R1's over 1,500 frames (with and without `+stop74`); about 196 s of wall time per emulated second for the plain build. The console-reset sweep, `+midswap` and the forced coincidence are in the in-tree cartram harness; `frame_gate.py` gained the settle and cap rules (plan 7.4 amended); `s4_check` requires the snapshot check in the DARIA set.
- **Merges:** B1 (`eead112`) and M, main's 2.1.3 (`492a3b8`), on DARIA-dev. Non-DARIA stream hashes: F `6ea867f0…`, M `0ec75217…`.
- **The D candidate** (`s7/D`, local): DARIA-dev + I1 + all of I3 (including the three `ap_core.qsf` lines) + `daria_smp.sv` in `core.qip`, check (h) at +4.5 ns, and `POCKET_CHANGES.md` naming `video_mux.sv`. With `POCKET_DARIA` undefined it preprocesses to M's stream. Phase 2 (fits Q1' and Q2, mode B, the frame runs, every regression gate, a whole-commit review) runs on it.

### Fit Q1' and commit P, the PAL 2600 loop (2026-10-11)

- **Q1'** [sta] (M, `492a3b8`, seed 2, non-DARIA): `clk_sdram` +2.437 ns, worst hold +0.117 ns, 12,870 ALMs. The worst path is the 7800 SDRAM request.
- **The owner's decision:** fix the shipped core's PAL 2600 loop in 2.2.1, in both builds. **Commit P** (`b1e57ef`): `is_pal_o` is now `region_pll`, a `clk_sys` register. It follows `region_select` one clock later and is held while a 2600 image's region is not known: during its download, on the clock after it, and while its console is in reset (`tia_mode & ~tia_en`). The hold is token for token lane I1's `daria_pal`, so D takes `region_pll` in its place. Renamed back, D's DARIA stream is byte-identical.
- **Results:**
  - A PAL 2600 game on Auto retunes once, to PAL, at 955 ms, on both builds. Before the fix: 41,293 retunes in 1.3 simulated seconds, ending NTSC.
  - tb_wire: the other 27 retune, reset, second-load and PLL scenarios pass.
  - The run_sim and extra_tests gates pass, and all 58 fingerprints are byte-identical to M's.
  - Lint adds no warning, and hygiene passes.
  - The non-DARIA stream is now `9b9e7e5e…`, and D's identity gate compares against it. It differs from M's only in the `region_pll` lines.
- **Q1''** [sta] (P, seed 2, non-DARIA): `clk_sdram` +2.380 ns, worst hold +0.100 ns, 12,990 ALMs; Q4 compares with this fit.
- **Review:** signed off with 5 minor findings and no RTL change. A reviewer ran 63 more plain-build runs with `pll_region` in the loop: reset timings around the region change, manual Region changes, second loads both ways at 9 offsets, and 5 hold mutants (3 killed; one equivalent on all but one clock; one visible only against M).
- **Release edges, against M:**
  - Unchanged for regions set at load time: A78 header loads, the manual-PAL 2600 load, A78 after A78, and A78 after a 2600.
  - A Region setting changed mid-game releases 1 `clk_sys` later.
  - When a 2600 image's region changes while its console is in reset, the console is first released at the old region for about 7-15 `clk_sys`, then retuned. Both cases where this happens are listed below.
- **Accepted costs.** The DARIA build has had all three since I1, and the final region is correct in each:
  1. An unmeasured 2600 load after a PAL image runs about 14 `clk_sys` at PAL before its NTSC retune.
  2. A Region setting changed inside a 2600 image's reset is applied at the release.
  3. A 2600 load that starts within about 4-5 `clk_sys` of the previous PAL game's change gets one extra PAL retune at the load's end.
- **For the owner:**
  - After its one retune, a PAL 2600 game is shown in the NTSC picture window, at the PAL clock, for about 0.96 s more. The reset clears the TIA's measurement (`TIA.sv:1708`), and the game switches windows when the TIA decides again.
  - A 7800 image that the BIOS drops into 2600 mode is not covered by the hold. It could loop if its 2600-mode video measured PAL against an NTSC header. This is not simulated; M has the same exposure.
- **For step 8, already in M:** `pll_region.v` checks `loading` only before a retune starts. A load that starts inside a retune's clock stop holds PSRAM CE# low for about 20 µs, where the part's maximum is 4 µs. P reduces the exposure to one retune per PAL game.

### Phase 2: the D candidate at ÷18, and the `clk_arm` ladder (2026-10-11)

- **Q2** [sta] (D at `70a63ca`, ÷18, seeds 1 / 2 / 3):
  - `clk_sdram` +2.456 / +2.662 / +2.880 ns, which meets 5.3. The worst path is Flicker Blend.
  - Worst hold +0.123 / +0.053 / +0.115 ns.
  - ALMs 15,502 / 15,508 / 15,505 (83.9%), under the 15,523 guide.
  - `clk_arm` +0.548 / +0.115 / −1.736 ns. Seed 3 misses 5.2: 13 failing endpoints, TNS −8.837 ns.
  - The worst `clk_arm` path class is the same on every seed: a window or ROM RAM → `bup_cpu` execute → register-file write data, 17-18 levels, about 64% of it interconnect.
- **The ladder** (Q3) [sta]. Plan 5.2's 0.3 ns rung, an extra 0.8 ns rung, and ÷19, each on seeds 1 / 2 / 3, at the worse slow corner:

  | Fit | `clk_arm` setup | `clk_sdram` setup | Worst hold | ALMs needed |
  |---|---|---|---|---|
  | Q2: ÷18 | +0.548 / +0.115 / −1.736 | +2.456 / +2.662 / +2.880 | +0.123 / +0.053 / +0.115 | 15,502-15,508 |
  | Q3a: ÷18, 0.3 ns `clk_arm` padding | +0.533 / +0.988 / −0.303 | +2.765 / +2.883 / +3.031 | +0.080 / +0.100 / +0.119 | 15,487-15,525 |
  | Q3b: ÷18, 0.8 ns padding | −0.662 / +0.395 / +0.509 | +2.322 / +3.047 / +3.010 | +0.110 / +0.084 / +0.120 | 15,504-15,519 |
  | Q3c: ÷19, no padding | **+1.477 / +1.638 / +1.614** | +2.724 / +2.686 / +2.874 | +0.097 / +0.107 / +0.100 | 15,472-15,505 |

  - **The 0.3 ns rung still misses seed 3, so plan 5.2 now prescribes ÷19**, which meets 5.2 on every seed. Its cost: the guard never locks, so cart RAM collisions go back to the counted race, and Qyx's heaviest call rises to 97% of its budget.
  - **Padding does not fix ÷18.** Over the nine ÷18 fits, `clk_arm` averages +0.04 ns over a range of 2.7 ns, and 3 of 9 miss. 0.8 ns of padding made seed 1 worse, and the fitter never reached its own target (−1.462 / −0.405 / −0.291 ns in its view).
  - Q3a seed 3 is 2 ALMs over the guide; area alone triggers nothing (5.1).
- **The guard's registers** (plan 5.4's checks (a)-(c) and (k)):
  - In 8 of the 12 fits the router duplicated `u_guard|pd_tog`, `pd_rx` or both, for routability. `ap_core.qsf` sets `ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION` on, and `PRESERVE_REGISTER` does not stop it.
  - Every copy is timed at 6 / 1 ns. Still, (c) and (k) fail. Where `pd_rx` was copied, (a) and (b), which expect exactly one guard path, fail as well.
  - Only Q2 seed 2 and Q3c seed 3 pass every check.
  - The setup slack of `pd_tog` → `pd_rx` against 6 ns, at slow 85 °C, ran from +0.025 to +0.418 ns, and −0.031 ns once (Q3a seed 2).
- **Mode B through the wrapper at ÷18** (D, `MODE_B=1 WRAPPER=1 WIN_KB=64`) passes 9 of 9 runs:
  - **The runs:** Galagon, SF2fix, draconian RC8 and Turbo at phase 0 for 300 frames; Spiders at phase 0 for 600 frames; Galagon and Spiders at 8,730 ps and 17,460 ps for 600 frames.
  - **Calls:** 8,318 compared with upstream, 0 differ. Late calls are as R1: Spiders 16 at frames 557-572 at each phase, 0 on the other images.
  - **Guard and collisions:** the guard locks at the model's edge (16 / 18 / 14 at phases 0 / 8,730 / 17,460 ps) with 0 unlocks. `coll_d_same`, `coll_d_ld_same` and `coll_ww_same` are 0, and so is every front-end bad counter.
  - **Faults:** 0 halts, 0 PSRAM violations.
  - **Against earlier runs:** the 300-frame Galagon, SF2fix and draconian runs repeat step 6's mode-B counts exactly, except the run length and the `guard_on` share, because the wrapper releases the console later; Turbo has no step-6 counterpart. The five 600-frame runs match R1's `fp.csv` in every column over frames 1-599.
  - **Not covered:** the frame runs cover the Pocket's 6507 release and stall timeline, and `tb_load +retune` and `tb_wire` the region logic. No PAL image runs in mode B.
- **For the owner's "same frames" question:**
  - In mode B the console resumes when the later of the two calls ends, which is upstream's on almost every call.
  - DARIA's front end ends calls up to about 3.2 thousand `clk_sys` earlier. It ends later in only 1 of Galagon's 599 calls, 1 of SF2fix's 525, 59 of Turbo's 599 and 137 of draconian's 600 (phase-0 runs), and in none of Spiders' 1,199.
  - In the DARIA build DARIA's own end applies, so the 6507 resumes earlier. The frame runs below show that this is not what makes Galagon's RIOT RAM differ; that comes from a bench input.
- **Still running at the end of 2026-10-11:**
  - On D: the frame-run report (the runs are done), the regression gates, and a whole-commit review.
  - Plan 5.2's checks at ÷19: mode B at ÷19 with each collision's edge distance recorded (Galagon and Mappy first, then phase 2's set), and `tb_s4` at ÷19.
  - The guard's registers: a fix that keeps each a single register, and ÷19 fits of it on seeds 1-3.
- **Owner (2026-10-11):** nothing major starts before Tuesday 13 October, 7 PM Eastern (23:00 UTC). The owner decides between ÷18 and ÷19 after the ÷19 collision results. D's fixes, P's adoption into D, and R2 wait for that decision.

### Frame runs on D against R1 (2026-10-11)

- **The runs:** `tb_frames`, DARIA build, ÷18, phase 0, 600 frames each, checked with `frame_gate.py` against R1's first 600:
  - draconian RC8 passes, with all four columns equal on 599 of 599 frames.
  - Galagon, SF2fix and Turbo fail.
  - In every run (the official ones and 15 diagnostic ones): no halt, no PSRAM violation, no guard unlock and no late call. Call counts equal R1's, and the call cross-check is consistent.
- **The main cause is the bench.**
  - `tb_daria`, R1's bench, sets the TIA's paddle inputs to `idump = 4'b1010` (`tb_daria.sv:183`): INPT1 and INPT3 high, INPT0 and INPT2 low.
  - The Pocket wrapper drives all four low for a 2600 image on Auto (`atari7800_pocket.sv:901` in D; the same code is at line 800 in `aeee6d2`, M and F).
  - Galagon, SF2fix and Turbo read INPT1 at boot to detect a Genesis pad and keep the result in RIOT RAM, so their state differs from R1's from frame 1.
  - This, not the earlier release, is why lane I4 saw Galagon's RIOT RAM differ in every frame. With R1's release times but the Pocket's inputs, RIOT RAM still differs on all 599 frames; with the inputs matched it is equal on all 599.
- **With the inputs matched** (`tb_frames` forced to `tb_daria`'s values):
  - `len_sys` and RIOT are equal on every frame for all three, and video too, except one extra unblanked black line in SF2fix's frame 1.
  - Every call's ARM instruction count equals R1's.
  - Apart from that line, only audio still differs: Galagon on 61 frames, Turbo 107, SF2fix 391.
- **A call's release difference** is DARIA's 6507 hold minus R1's. Most calls are shorter. The medians are −286 (Galagon), −137 (SF2fix), −54 (Turbo with matched inputs; −259 on the committed bench) and −406 `clk_sys` (draconian). Over all calls the total hold is 0.84-0.97 of R1's.
- **Where the audio differences come from:**
  - **Galagon and Turbo:** the 6507 writes the TIA audio registers right after a call. Those writes move by the preceding call's release difference (Turbo: 51 of 51 writes, within −7 to +5 `clk_sys`), with the same values in the same order. With matched inputs and R1's release times, Galagon equals R1 on every column of all 599 frames. Turbo was not run with R1's release times.
  - **SF2fix:** its DPC+ music tick runs 520 `clk_sys` off upstream's. DARIA's first call runs on a cold asset cache, takes 579 `clk_sys` longer and so starts frame 1 a scanline later; the same shift gives frame 1's extra black line. With the tick delayed to match and R1's release times, its audio is equal on all 29 frames tested (1-29); only frame 1's video still differs.
- **The current P13 rule cannot pass a correct DARIA** on Galagon, SF2fix or Turbo, even with matched inputs. Against R1's hashes it also cannot tell a planted audio fault from a correct build. The planted fault is a test build that flips the least significant bit of the mixed DPC+ amplitude when the sum is 8 or more.
- **A rule that can, proposed for the owner's "same frames" decision:**
  0. **Bench parity:** `tb_frames` presents INPT0-3 as `tb_daria` does, or R1 is re-run with the Pocket's mapping.
  1. **A natural run** gates `len_sys`, video and RIOT on every frame, each call's ARM instruction count, and the call, late-call and status checks. Frame 1's video is excused only when a frame-0 call's hold differs. Audio is counted, not gated, so this run alone passes the planted fault.
  2. **An aligned run** holds each call's release to R1's and matches the tick phase of DPC+ and CDF music. It gates every column on every frame, with the same frame-1 video exception.
- **How far the rule is tested:**
  - Clean Galagon (599 frames) and SF2fix (29 frames) pass both runs.
  - The planted fault fails the aligned run on SF2fix (17 of 29 frames). Galagon never exercises it.
  - Not yet run: the aligned run on Turbo and draconian, tick-phase matching for CDF music, and SF2fix beyond frame 29 (its natural audio differences span frames 4-119 and 325-599).
- **For the owner, outside DARIA:** the Pocket core reads INPT0-3 as 0 for a 2600 image with a joystick.
  - The D review found the same line, with the same port-type override, in a copy of upstream's MiSTer wrapper; that copy was not re-checked against the pinned upstream commit. In this repository the line dates from the first commit.
  - It matches a real 2600 with a standard joystick, whose paddle pins are unconnected. `tb_daria`'s `1010` is instead a Sega Genesis pad with button C released, so R1 ran the Genesis-aware games in their Genesis mode.
  - On the Pocket these games boot in standard joystick mode, and any second-button function they offer with a Genesis pad is unavailable; nothing breaks. With the Pocket's inputs, Turbo's ARM code runs a different instruction count from R1's on 438 of 1,197 calls, from the second call on.
  - A Genesis-pad input option would be a 2600 feature, not a DARIA item.

### Phase 2 gates, the ÷19 branch and the D review (2026-10-12)

- **Every regression gate that was run passes on D** (`70a63ca`, clean tree, both builds):
  - **Static checks:** hygiene, pp_equiv (M's non-DARIA stream), pp_guards, and lint with no warning added in the three sets.
  - **Cart RAM:** the matrix and directed s19, with the nohold and nocmp mutants caught.
  - **`run_sim` and `extra_tests`:** every non-BupChip fingerprint identical across builds, BupChip equal by PCM. `extra_tests` passed on a rerun: the first run failed in its environment, because its tool download went through a proxy from before a session restart. The rerun used the tools and MiSTer firmware cached from the EXTRA_REF run.
  - **Benches:** the gate checkers' selftest (167 cases), `daria_smp` and `dbg_snap`.
  - **`tb_wire`:** 88 scenarios. The PAL 2600 scenario gives 1 retune on the DARIA build and the loop (41,293 retunes) on the plain build, as expected before P.
  - **`s4/check.sh`:** 28 of 28 on each set. In the DARIA set, all 19 `tb_s4` runs print "snap: ok".
  - **Not run:** `AR_TAPE=1` (plan 1.2 row 4).
- **The ÷19 branch** (`s7/G`, local, not merged; the owner decides the divider):
  - **Commits:**
    - `b177e64`: `pll_core.v`'s counter 3 at 19 under `POCKET_DARIA`. It also selects four PLL display strings (`output_clock_frequency0-2` and `pll_output_clk_frequency`), which the generator prints one digit lower at C3 = 19. The bench and gate defaults move to 19.
    - `3201313`: `ROUTER_REGISTER_DUPLICATION OFF`, set from `daria_sync.tcl`, so it applies to DARIA builds only. Quartus 21.1 accepts the router's duplication settings only globally: per-instance forms stop the compile, and `ADV_NETLIST_OPT_ALLOWED` on the two registers is ignored by the router.
    - `0bc63d4`: `s4/check.sh`'s ÷19 text made identical to `s7/C19`'s, so the two branches merge cleanly.
    - `618b5c3`: the guard pair is asked of the fitter at 5.5 ns. The Timing Analyzer still checks 6 / 1 ns.
    - `cbe4e89`: check (k) recognises a duplicate's name, and (c) names each duplicate. The fit driver's divider now defaults to the tree's own.
  - **What the duplication setting costs:** g1-g3 (setting off) against Q3c (Auto), on the same ÷19 netlist, means over seeds 1-3:
    - `clk_sdram` +2.740 against +2.761 ns, and `clk_arm` +1.642 against +1.576 ns.
    - ALMs and LABs are identical, and peak interconnect is within 0.6 points.
    - The 1,014-1,061 router-duplicated registers per fit go away: 14,233 registers against 15,247-15,294.
    - All within seed noise.
  - **Without the 5.5 ns constraint** (g1-g3), seed 3 missed the guard's 6 ns window at −0.109 ns, through clock skew.
  - **Fits** [sta], ÷19, seeds 1 / 2 / 3, every step-7 check passing on each. They were made on `s7/G-gpad` `35c9f01`, whose `src/fpga` tree equals `618b5c3`'s:

    | | `clk_arm` | `clk_sdram` | Worst hold | Guard window (6 ns, slow 85 °C) | ALMs needed | Router duplicates |
    |---|---|---|---|---|---|---|
    | h1-h3 | +1.662 / +2.276 / +1.993 | +2.368 / +3.074 / +3.039 | +0.103 / +0.113 / +0.123 | +0.178 / +0.102 / +0.205 | 15,478 / 15,505 / 15,497 | 0 |

  - These fits were made without P; once P is adopted, the merged tree needs its own.
- **Mode B at ÷19:** D's RTL with the bench clocked at ÷19. The bench branch `s7/C19` records, for each pair of accesses to one cart RAM word, the distance between DARIA's and the front end's clock edges in VCO periods.
  - Galagon and Mappy ran 600 frames; SF2fix, draconian RC8 and Turbo 300; Spiders 600. All six pass: every call equals upstream's, 0 halts, 0 PSRAM violations.
  - The guard never locked.
  - The 600-frame runs match R1 on frames 1-599. Spiders has the same 16 late calls as at ÷18.
  - With `clk_arm` 5.6% slower, DARIA's front end ends a call later than upstream's more often: SF2fix in 45 calls, Turbo 163 and draconian 255, against 1, 59 and 137 at ÷18.
  - Still outstanding: `tb_s4` at ÷19 (22 of 28 jobs started at 13:47 UTC) and the collision counts. They are recorded once the lane ends and a second reader has checked them. Plan 5.2 also asks for R2 and the frame gate at ÷19, with the guard expected unlocked and late calls watched.
- **The D review** (D, P's adoption, `s7/G` and `s7/C19`; no sign-off yet):
  - **Blocker, both dividers:** the router duplicated the guard's registers in 8 of the 12 step-7 fits. That fails checks (c) and (k), and (a) and (b) where `pd_rx` was copied. The fix exists only on `s7/G` (`3201313`, `618b5c3`) and has never been fitted at ÷18.
  - **Blocker at ÷18:** no fit set meets 5.2 on three seeds. ÷18 needs a waiver of P12 for `clk_arm`, or a lever the plan does not have.
  - **Major, both dividers:** a retune can still start inside F6, against P20 as amended and plan 1.2 row 1.
    - How it happens: `pll_region` starts no retune while a load sequence is in progress, so a region change between a load's slots can wait past `daria_rt_mask`'s 16-clock window. A console reset in that time starts F6. If the load then ends within F6's 0.15-0.58 ms, the retune starts while F6 writes cart RAM, and no F6 runs after it.
    - The review reproduced it with a scratch tap, and judges it unlikely on hardware. `tb_wire` cannot reach it, because it drives the loading flag per slot.
    - The fix: treat a pending retune like `pll_busy`, plus a `tb_wire` scenario that fails before the fix. Or the owner accepts it as a residual for step 8.
  - **Major, both dividers:** the tree that will ship (D + P + the chosen divider) has no gate or fit evidence yet. Plan 7.6's rerun rule requires on the merged tree:
    - hygiene, pp_equiv, pp_guards and lint;
    - `run_sim` and `extra_tests` on both builds, plus `AR_TAPE=1`;
    - s4 on both sets;
    - cartram, and `tb_wire` with `DIRECTED=1`;
    - Q2 on seeds 1-3, Q-mut, Q4 against Q1'', and Q5 (4.3, P29);
    - mode B, R2 and the frame runs, under an agreed P13 rule with bench parity.
  - **Minor:**
    - `bupchip`'s timer rate takes `region_select`, not the region the PLL runs (plan 2.5 says `region_select`).
    - The four display strings go beyond P10's "must touch only counter 3's lines". Either P10 should say "the tool's output for the selected C3", or Quartus is shown to ignore the strings and they are dropped, which needs a refit.
    - Nothing in the simulation gates checks that the benches' default divider equals `pll_core.v`'s. Only the fit driver reads the tree's divider.
  - **The guard at ÷19 is inert by construction:** on the 48:19 lattice any 13-sample window holds 6 or 7 matching samples, where the period-3 lock needs exactly 5. A transient lock would only delay front-end grants; F6 keeps its priority.
- **Owner (2026-10-11), still in force:** nothing major starts before Tuesday 13 October, 7 PM Eastern (23:00 UTC). After the ÷19 results the owner decides the divider. The review's findings, P's adoption into D and the reruns follow in the D fix round.

### Halt (2026-10-12, 17:18 UTC)

**The owner halted all work.** Every agent and simulation was stopped; no Quartus job was running. Nothing is merged beyond DARIA-dev; the local branches `s7/D`, `s7/G` and `s7/C19` keep their commits.

**Mode B at ÷19: the cart RAM coincidences.** These were counted by the lane but **not yet checked by a second reader**. Each pair is a DARIA store and a front-end read of the same cart RAM word within 69.84 ns. The distance is between their clock edges, in VCO periods of 1.455 ns:

| Image (frames) | Pairs | At 0 / 1 / 2 periods | At 3-6 periods | Over 6 | Pairs where the value changed | Per minute, all pairs |
|---|---|---|---|---|---|---|
| Galagon (600) | 8 | 0 / 1 / 0 | 2 | 5 | 3: the 1-period pair and 2 over 6 | 48 |
| Mappy (600) | 22 | 1 / 0 / 1 | 3 | 17 | 2, both over 6 | 132 |
| draconian RC8 (300) | 2 | 0 / 0 / 0 | 0 | 2 | 0 | 24 |
| SF2fix (300), Turbo (300), Spiders (600) | 0 | — | — | — | — | 0 |

- **Every pair is a front-end audio read** during a DARIA call. There are no write-write or write-load pairs.
- **The races to watch:** pairs at 0-2 periods (under 3 ns) are the likely races. There are three:
  - Galagon's 1-period pair, the only one whose value changed;
  - Mappy's 0-period pair, a store of 0 over 0;
  - Mappy's 2-period pair, which did not change.
- **The pair rate is the games', not the divider's:** step 5's counts within the same window were 50 per minute for Galagon and 134-151 for Mappy.
- **The runs are short** (5-10 seconds of play each), so the counts of near pairs are rough.
- **What a race gives:** in the Quartus image's own `altsyncram` model, a dual-clock read of a word being written in the same step gives X on the written byte lanes and the stored value on the others. The Cyclone V handbook was not in the image, so this was not checked against it.

**`tb_s4` at ÷19 was stopped at job 27 of 28:**
- By the lane's notes, 25 of jobs 1-26 pass, with 0 PSRAM model violations throughout; the stress mutants are caught as at ÷18.
- `synth_reloads` failed only its placement requirement: both of its holds fell mid-access at ÷19. Its data checks were clean: PCM identical, 0 violations, snap ok. A re-placed rerun was queued but not run.
- Job 27 (song 13 across a 20 ms pause) was interrupted, and job 28 never started.

**Not done:**
- the rest of `tb_s4` at ÷19 and the `synth_reloads` rerun;
- the second reader's recount of the coincidences;
- the lane's final report.

Everything is in the lane's gitignored work directory, with resume notes. The decisions waiting for the owner are listed above: the divider, the "same frames" rule with bench parity, and the retune-inside-F6 finding.

### Owner decisions (2026-10-12)

- **Divider: ÷19 for the first release.** ÷19 is the more promising divider, and it can be V1 even if it is not exact. Plan 5.2's ÷19 path applies: `s7/G`'s PLL lines, router setting and guard-pair constraint go into D, together with 5.2's ÷19 checks. The guard is inert at ÷19, and the rare audio-read coincidences recorded above are accepted for V1.
- **"Same frames": wanted, not required for V1.** Small discrepancies are acceptable in a first version; they are measured and documented instead of blocking the release. The P13 rule is amended on this basis when work resumes. The frame runs' proposal is the starting point: bench parity, then a natural run gating `len_sys`, video, RIOT and ARM instruction counts.
- **The retune-inside-F6 race is fixed,** not deferred to step 8. The fix is the first item when work resumes on Tuesday 13 October at 7 PM Eastern (23:00 UTC). The D review's proposal: treat a pending retune like `pll_busy`, with a `tb_wire` scenario that models the loading flag across slots and fails before the fix.

### The lead's decision on Q2 at ÷19 (2026-10-14)

- **Q2 on the shipping tree** [sta] (the D fix round's `src/`, ÷19, slow 85 °C), seeds 1 / 2 / 3:
  - `clk_arm` +1.241 / +1.077 / +1.765 ns; `clk_sdram` +2.462 / +2.683 / +2.919 ns; worst hold +0.120 / +0.098 / +0.119 ns. Every P12 gate passes on all three seeds.
  - Seed 1 fails check (h) alone: `t_*_q` → `clk_sdram` +4.298 ns against +4.5.
  - Seed 3 fails (a) and (l) alone: the guard pair `pd_tog` → `pd_rx` at −0.046 ns against its 6 ns window.
  - Seed 2 passes every check. Q4 (the non-DARIA identity fit) gives a `.rbf` equal to Q1''.
- **Decision: amend the two checks, not add a lever.** The owner's guidance is that ÷19 may be V1 even if not exact.
  - **(a) and (l) at ÷19.** At ÷19 the guard cannot lock whatever this path's delay is, so its window guards no function there.
    - The window is set by the clock skew between corners and the 1 ns hold bound: the data delay must sit in about 4.1-4.75 ns at slow 85 °C. The 5.5 ns fitter target was reached on none of six fits.
    - (a) keeps checking that the constraint is applied and that the pair is single. It reports the slack and gates only at ÷18.
    - (l) leaves this one path out at ÷19.
  - **(h): the threshold drops from +4.5 ns to +3.0 ns,** which still keeps the leg 1.5 ns clear of the +1.5 ns release gate.
    - Over ten ÷19 fits the leg ran 4.298-6.697 ns.
    - It still starts at registers: (g), (g.legs) and (h.retime) pass.
  - **Why not a lever:** a fitter or SDC lever would void Q2, Q-mut and Q5 for about a day of fits, with no sign that it would work.
- **The shipped SEED is 2,** already `ap_core.qsf`'s. It is the only seed that passes every check as first written. The held fits, Q-mut and Q5, are released.

### The D fix round (2026-10-13 to 10-14)

On `s7/D`, local, head `0b2f9e1`. `src/` has not changed since `317eaa8`, so the verification campaign's results on `317eaa8` carry to the head.

- **Merges:** DARIA-dev with commit P (`03e3b09`), the ÷19 branch (`2247bef`) and the bench branch (`68c3f41`). The non-DARIA stream equals P's (`9b9e7e5e…`), and the DARIA stream equals the ÷19 branch's apart from the `region_pll` rename.
- **The retune-inside-F6 race is fixed** (`f2c305e`, DARIA only):
  - **The mechanism.** The wrapper keeps `daria_rgn`, the region of the PLL's last completed retune. A retune is pending while `region_pll` differs from it. While one is pending, F6 is held off (`daria_rt_mask`), and a console reset of an ARM image lasts until the retune. `region_pll` is frozen while a retune is pending or under way, and withdrawn during a 2600 image's download.
  - **Evidence:**
    - `tb_wire` gained a mode that holds the loading flag across a whole load sequence, as `core_top` does. Its scenarios fail before the fix and pass after it.
    - Seven mutants of the fix are each caught.
    - A random model of the interlock is clean over 13 seeds with the fix, and finds violations without it.
    - The full `tb_wire` set passes, 96 scenarios.
- **DARIA's timer prescale** now takes `daria_rgn`, the region `clk_sys` actually runs at (`c5fb23f`).
- **Benches, rules and docs:**
  - `tb_frames` can present the reference bench's paddle inputs (bench parity).
  - `frame_gate.py`'s default is the V1 rule, with the strict rule as an option.
  - `synth_reloads` places its holds correctly at ÷19.
  - Two new gates: one checks every bench's default divider against `pll_core.v`'s, the other runs the fit driver's selftest.
  - `wire.py` counts a mutant as caught only on the named keys; a crash or timeout is an error.
  - The plan and the docs are amended for the owner's and the lead's decisions.
- **The amended checks** of 5.4 (the lead's decision above) are in `step7_checks.py`, by divider. Judged again from the fits' report files, without refitting:
  - Q2 seeds 1-3 pass as amended, and fail as before by the rules as first written.
  - The I3 STA mutants and Q-mut still fail as required.
- **Q5** (`BUP_DEBUG` + DARIA, seeds 1-3) first failed (c.cells), (f) and (k'), on a table error: it expected `cap_err_a[0]`, a flop with no load in any build. With the table corrected, all three seeds pass. The guard pair runs at +0.603 / +0.131 / −0.060 ns, gating only at ÷18.
- **Review:** five rounds. The last signed off at `0b2f9e1`, with three minor findings left.
- **The verification campaign on the shipping tree** (`317eaa8`'s `src/`):
  - **Done:** the static gates, `run_sim`, the cartram matrix, the unit benches, `tb_wire`'s full set, Q2 seeds 1-3, Q4 (equal to Q1''), Q-mut, Q5 seeds 1-3, and the three I3 STA mutants.
  - **Running:** `s4/check.sh` on both sets, `extra_tests` with `AR_TAPE=1`, the V1 frame gate on 16 images at 1,500 frames, and mode B.
- **An incident.** A reviewer's test harness wrote through a symbolic link into one of the campaign's fit reports. The intact copy was restored and its md5 checked; the campaign's verdict for that fit had been written before the change.
