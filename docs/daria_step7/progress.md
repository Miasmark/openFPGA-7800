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
    - `b177e64`: `pll_core.v`'s counter 3 at 19 under `POCKET_DARIA`. It also selects four PLL display strings (`output_clock_frequency0-2` and `pll_output_clk_frequency`), which the generator prints slightly lower at C3 = 19 (14.318180 against 14.318181 MHz for C0 and C2, 57.272722 against 57.272724 MHz for C1, the VCO 687.272644 against 687.272687 MHz; this line said "one digit lower" until the final review of 2026-10-16). The bench and gate defaults move to 19.
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

**Mode B at ÷19: the cart RAM coincidences.** These were counted by the lane but **not yet checked by a second reader**. (Later: the review of `317eaa8` recounted them from the runs' pair logs and found the same counts, every pair a front-end audio read during a call, plan 5.2; on the shipping tree, c76's six phase-0 wrapper runs gave the same counts bin for bin, `record.md`, "Mode B at VCO/19".) Each pair is a DARIA store and a front-end read of the same cart RAM word within 69.84 ns. The distance is between their clock edges, in VCO periods of 1.455 ns:

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

**`tb_s4` at ÷19 was stopped at job 27 of 28** (later, on the shipping tree, both sets passed 28 of 28 in c76, `synth_reloads` with its holds placed at `+holdstep=7`: plan 5.2, `record.md`, "`s4/check.sh` on both sets"):
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

- **Q2 on the shipping tree** [sta] (the D fix round's `src/`, ÷19; setup at the worse slow corner, worst hold over every corner), seeds 1 / 2 / 3:
  - `clk_arm` +1.241 / +1.077 / +1.765 ns; `clk_sdram` +2.462 / +2.683 / +2.919 ns; worst hold +0.120 / +0.098 / +0.119 ns. Every P12 gate passes on all three seeds.
  - Seed 1 fails check (h) alone: `t_*_q` → `clk_sdram` +4.298 ns against +4.5.
  - Seed 3 fails (a) and (l) alone: the guard pair `pd_tog` → `pd_rx` at −0.046 ns against its 6 ns window, at slow 85 °C.
  - Seed 2 passes every check. Q4 (the non-DARIA identity fit) gives a `.rbf` equal to Q1''.
- **Decision: amend the two checks, not add a lever.** The owner's guidance is that ÷19 may be V1 even if not exact.
  - **(a) and (l) at ÷19.** At ÷19 the guard cannot lock whatever this path's delay is, so its window guards no function there.
    - The window is set by the clock skew between corners and the 1 ns hold bound, not by placement. On seed 3, where the skew at slow 85 °C is −1.127 ns, the data delay must sit in about 4.1-4.75 ns. The 5.5 ns fitter target was reached on none of six fits.
    - (a) keeps checking that the constraint is applied and that the pair is single. It reports the slack and gates only at ÷18.
    - (l) leaves this one path out at ÷19.
  - **(h): the threshold drops from +4.5 ns to +3.0 ns,** which still keeps the leg 1.5 ns clear of the +1.5 ns release gate.
    - Over ten ÷19 fits the leg ran 4.298-6.697 ns.
    - It still starts at registers: (g), (g.legs) and (h.retime) pass.
  - **Why not a lever:** a fitter or SDC lever would void Q2, Q-mut and Q5 for about a day of fits, with no sign that it would work.
- **The shipped SEED is 2,** already `ap_core.qsf`'s. It is the only seed that passes every check as first written. The held fits, Q-mut and Q5, are released.

### The D fix round (2026-10-13 to 10-14)

On `s7/D`, local, head `0b2f9e1`. `src/` has not changed since `317eaa8`, so the verification campaign's results on `317eaa8` carry to the head.

- **Merges:** DARIA-dev with commit P (`03e3b09`), the ÷19 branch `s7/G` (`2247bef`) and the bench branch `s7/C19` (`68c3f41`). The non-DARIA stream equals P's (`9b9e7e5e…`), and the DARIA stream equals `s7/G`'s apart from the `region_pll` rename.
- **The retune-inside-F6 race is fixed** (`f2c305e`, DARIA only):
  - **The mechanism.** The wrapper keeps `daria_rgn`, the region of the PLL's last completed retune. A retune is pending while `region_pll` differs from it.
    - `region_pll` is frozen while a retune is pending or under way, and while an ARM image's console is in reset.
    - During a 2600 image's download it is set back to `daria_rgn`, which cancels any pending retune; the image's own region is asked for when its console is released.
    - While a retune is pending, `daria_rt_mask` stops a console reset from starting F6. A console reset of an ARM image lasts until the retune completes, and F6 then runs once, after it.
  - **Evidence:**
    - `tb_wire` gained a mode that holds the loading flag across a whole load sequence, as `core_top` does. Its first six scenarios fail on the RTL before the fix and pass after it. Two added later each catch a mutant that removes one of the freezes.
    - Five mutants of the fix, each undoing one part (the mask, the withdrawal, the reset hold and the two freezes), are each caught. So are two mutants of the timer's region input (`c5fb23f`).
    - A random model of the interlock, kept outside the repository and not a gate, is clean over 13 seeds with the fix and finds violations without it.
    - The full `tb_wire` set passes, 96 scenarios.
- **DARIA's timer prescale** now takes `daria_rgn`, the region `clk_sys` actually runs at (`c5fb23f`).
- **Benches, rules and docs:**
  - `tb_frames` can present `tb_daria`'s paddle inputs, the bench R1 used (bench parity).
  - `frame_gate.py`'s default is the V1 rule, with the strict rule as an option.
  - `synth_reloads` places its holds correctly at ÷19.
  - Three new gates: `divider` checks every bench's default divider against `pll_core.v`'s, `wire` runs `tb_wire`'s full set and its mutants, and `fit_selftest` runs the fit driver's selftest.
  - `wire.py` counts a mutant as caught only on the named keys; a crash or timeout is an error. This stricter verdict had then been checked only by re-judging earlier logs (all 7 caught) and by selftest cases. (Later: its run on real simulations, round 4 at `0b2f9e1`, ran on 2026-10-15 and caught 7 of 7 on their named keys; the logs are named in `record.md`, "`tb_wire`'s full set and its mutants".)
  - The plan and the docs are amended for the owner's and the lead's decisions.
- **The amended checks** of 5.4 (the lead's decision above) are in `step7_checks.py`, by divider. Judged again from the fits' report files, without refitting:
  - Q2 seeds 1-3, and seed 3's `KEEP_DB` refit, pass as amended.
  - By the rules as first written their verdicts are unchanged: seed 1 fails (h), seed 3 fails (a) and (l), and seed 2 passes. Q4 passes both ways.
  - The I3 STA mutants and Q-mut still fail as required.
- **Q5** (`BUP_DEBUG` + DARIA, seeds 1-3):
  - Each fit's own verdict failed (c.cells), (f) and (k') on a table error: the table expected `cap_err_a[0]`, a flop with no load in any build. Seed 3 also failed (a) and (l) as first written, on the guard pair.
  - Judged again from the fits' report files, with the corrected table and the amended (a), (l) and (h), all three seeds pass. That re-judge of (c.cells) relies on a helper outside the repository; the tracked checker on the fits as fitted still reports the old table's failure. (Later: since `6477f78` the tracked checker makes it, and Q5 passes with it; `record.md`, "The fits".)
  - The guard pair's setup slack at slow 85 °C is +0.603 / +0.131 / −0.060 ns; (a) gates on it only at ÷18.
  - `daria_sync.tcl`'s line for `cap_err_a` now matches no build. It goes with the next `src/` change.
- **Review:** five rounds. The last signed off the fix round's changes at `0b2f9e1`; it does not cover the campaign's open results, which the release then still needed. (Later: c76 finished on 2026-10-16, and the final review covered its results; "The final review and c77", below.) Three minor findings were open. The final review of 2026-10-16 confirmed them as VG-1 to VG-3, and all three are now fixed, each in the commit named below (the tools fixes are also in `record.md`, "After c76: the final review"):
  - Q5's re-judge relies on the untracked helper above, and plan 7.6's rule overstates what the tracked tools can re-judge. *Fixed:* `step7_checks.py` judges (c.cells) from each fit's `firstflops.tsv` (`6477f78`), and plan 5.4 and 7.6 say which checks a fit's own report files judge again (`baca4cd`).
  - `fit_selftest` fails below 2,100 MB free, so a fresh-clone run (7.7) on this machine may fail for disk alone. Two branches of the amended checks, (h)'s hold test and (a)'s every-corner requirement, are not covered by it. *Fixed* (`6477f78`): it needs 100 MB, is PARTIAL below that, and has planted cases for both branches.
  - The plan header's list of amendments is incomplete, and the 2.7 correction is undated. *Fixed* (`42ff9db`): the header lists them, and the 2.7 row is dated 2026-10-14.
- **The verification campaign on the shipping tree** (`317eaa8`'s `src/`) finished on 2026-10-16 at 00:58 UTC, with 48 of 48 pieces passing. Its record is in `record.md`, "The verification campaign c76 on the shipping tree". At 19:24 UTC on 2026-10-14 it stood as follows:
  - **Done:** the static gates, `run_sim`, the cartram matrix, the unit benches, `tb_wire`'s full set, Q2 seeds 1-3, Q4 (equal to Q1''), Q-mut, Q5 seeds 1-3, and the three I3 STA mutants.
  - **Running:** `s4/check.sh`'s DARIA set (17 of 28 jobs passed), `extra_tests` with `AR_TAPE=1` on both builds, and the V1 frame gate on 16 images at 1,500 frames (2 passed, 1 running).
  - **Waiting:** the gate `selftest`, `s4/check.sh`'s non-DARIA set, and mode B with the wrapper (10 runs) and without it (9 runs).
- **An incident.** A reviewer's test harness wrote through a symbolic link into one of the campaign's fit reports. The intact copy was restored and its md5 checked; the campaign's verdict for that fit had been written before the change.

### Audio against a real Harmony (2026-10-15)

- **Listening.** The owner asked to hear the audio the V1 rule counts but does not gate. Gorf's first 25 s were recorded from R1's bench and from the D candidate's `tb_frames`, both through a passive tap in scratch copies of the benches. Each tapped run's `fp.csv` is byte-identical to the untapped one (R1's, and c76's). Two independent checks passed.
  - The owner's verdict: "the audio is a hair out of sync for the most part".
  - Video, RIOT and `len_sys` are equal in every frame, and so is every call's instruction count. The audio differs in timing, not in content: writes after a call land earlier on DARIA, and the CDF music tick runs at another phase. Neither build is random.
  - The owner declined the aligned run that would prove it on Gorf.
  - Galagon was recorded the same way: 9.3% of samples differ, against Gorf's 33%. The most audible spot is a 17 ms buzz near 13.95 s, which DARIA plays fuller than the reference. The owner's verdict: "nothing to be too concerned with ... it does not sound like a different game or completely off key".
- **The real cartridge, from its documents.** The owner supplied NXP's LPC2101/02/03 data sheet (rev. 04, 2009), the user manual UM10161 (rev. 01, 2006) and the Harmony BIOS 1.06. The BIOS is the public `hbios_ntsc.bin` of the HarmonyCart tool. None of them is in the repository.
  - **Clock.** The Harmony's crystal is 10 MHz. The BIOS runs the PLL at ×7 (70 MHz, the LPC2103's maximum) and passes 70,000 kHz to its flash routines.
  - **Start-up.** BIOS 1.06 never starts a game at its reset vector. It jumps to the entry in the image header, so a game's own PLL and MAM set-up runs only if that entry reaches it.
  - **Clocks in force, by game:**

    | Game | ARM clock | MAM mode | MAMTIM | Why |
    |---|---|---|---|---|
    | Gorf | 60 MHz | 2 (full) | 4 | its own start-up runs |
    | Galagon, Lady Bug, Mappy, RobotWar, Wizard of Wor | 60 MHz | 2 | 3 | its own start-up runs |
    | Qyx, Tutankham, Spiders, Super Cobra, Zoo Keeper, Scramble | 70 MHz | 2 | 4 | the entry skips it, so the BIOS settings stay |
    | Elevator Agent, Turbo, Zaxxon | 60 MHz | — | — | larger than the LPC2103's 32 KB of flash, so they need an LPC213x board (Melody) |

  - **No Harmony runs the last three.** A Harmony executes ARM code only from its chip's 32 KB, and these games have more ARM code than that (the owner, from the forums). DARIA runs code from its 64 KB window.
  - **MAM changes during calls.** The drivers of Super Cobra and Zoo Keeper set the MAM to partial around each call. Scramble's game code does the same in one function.
  - **Upstream assumes one clock for every game:** 70 MHz (its `clk_arm` 71.59 MHz). So does Stella for any image of 32 KB or less.
- **A MAM model.** UM10161 chapter 4's rules were modelled in a scratch copy of R1's bench (`+mam`): one flash bank; prefetch, branch-trail and data buffers; aborts.
  - Its Gorf run equals R1's on every pre-existing column.
  - An independent Python model, written from the manual alone, agrees on every access's wait over Gorf's first 30 calls (403,217 accesses) and 18 directed traces.
  - All of Gorf's calls use `$FF`, so no audio interrupt runs.
  - **At Gorf's own settings** (60 MHz, mode 2, MAMTIM 4) a Harmony takes 77,638,287 cycles: 1.294 s over 2,999 calls. Mode 2's totals move by 1-2% under the other readings of the manual.

    | | Gorf's calls | Against the Harmony | Median per call |
    |---|---|---|---|
    | DARIA | 1.221 s | 5.6% faster | 12.6 µs early |
    | Upstream | 1.393 s | 7.6% slower | 41.6 µs late |

  - **So on Gorf DARIA is the closer of the two.** A real cart's NOP/JMP hand-back adds a few 6507 cycles after each call that RDY does not.
- **Recorded limit.** A Melody board's optional EEPROM (up to 4 MB) would be reached through the chip's serial peripherals, which DARIA reads as 0. No traced image uses them (`docs/IMPROVEMENTS.md`; `DARIA_CORE.md` open item 19).

### The final review and c77 (2026-10-16)

- **c76 is complete.** The verification campaign on the shipping tree (`317eaa8`'s `src/`) finished at 00:58 UTC. All 48 pieces exit 0, and every gate passes under the amended rules. Its record, judged piece by piece by a second reader, is in `record.md`, "The verification campaign c76 on the shipping tree".
- **The final review** read the whole of `s7/D` at `356cea9` in four parts: RTL (3 findings), timing and constraints (4), gates and tools (11), and docs (16). That is 34 findings. A second reader checked each one against the tree and the logs, and confirmed all 34. After the check none is a blocker: 2 are major, 19 minor and 13 nits. The one reported as a blocker, the README still listing 2600 ARM cartridges as not included, was rated minor, because the README describes the released core until 2.2.1 ships.
- **The owner's decisions:**
  - **RTL-1 ships as is in 2.2.1 and is fixed later** ("Ship as is, fix later"). In the DARIA build a PAL A78 loaded after a PAL 2600 image on Auto region costs two extra retunes; the final region is right (`DARIA_CORE.md`, open item 20).
  - **`src/` is frozen for 2.2.1** as `317eaa8`'s, the tree c76 verified. The review's `src/`-only findings wait for the first change after the release (`record.md`, "After 2.2.1: `src/` clean-ups"; `docs/IMPROVEMENTS.md`).
- **The fix round** changed nothing under `src/`:
  - **Tools:** `6477f78` (`step7_checks.py` judges (c.cells) from `firstflops.tsv`, and the fit driver's self-test needs 100 MB: VG-1, VG-2, VG-9), `82d05f1` (`tb_wire`'s `pal2600_a78` pins RTL-1 on both builds), `95c3352` (`step7_gates.sh`: VG-4, VG-5, VG-6), `5e1badb` (`hygiene.sh`: VG-7), `ce14cc0` (`run_dbgsnap.sh`: VG-8), `3344b92` (`frame_gate.py`: VG-10) and `f3a9b49` (`selftest.py` runs `step7_gates.sh` on stand-ins).
  - **Re-runs after the tools commits:** `selftest.py` with c76's inputs, 267 of 267; `fit_selftest`, 117 of 117; `frame_gate.py` on c76's 16 frame runs, 16 of 16, each report byte-identical to c76's; and `step7_checks.py` on copies of every c76 fit, with the verdicts in `record.md`, "The fits".
  - **Docs:** `42ff9db` (the plan and this file), `bf3d61a` (`DARIA_CORE.md`'s step-7 record, the V1 done-when, open items 7, 10, 11, 12 and 20, and the after-2.2.1 list), `7ff3276` (the README for 2.2.1) and `51b2927` (`DEVELOPING.md`, `design.md`, `ENVIRONMENT.md` and the sim READMEs).
- **Two re-reviews of `51b2927`,** one of the tools and one of the docs, passed every finding. The tools re-review built `tb_wire` again and re-ran `pal2600_a78`: the same binaries (md5) and the same timings. Between them they found one new minor item, N1 (below), and 13 smaller ones (NEW-1 to NEW-3 and N2 to N12, where NEW-1 and N2 are one item).
- **The nits round** fixed all 13: `5676558` (`frame_gate.py --auto` prints one verdict line, NEW-3) and `baca4cd` (the docs). After it `selftest.py` with c76's inputs passes 268 of 268, and `frame_gate.py` on c76's 16 frame runs gives each report byte-identical to c76's. `src/` is still `317eaa8`'s.
- **The merge.** `s7/D` at `baca4cd` is merged into DARIA-dev (`0bfd157`) with no conflict; `src/` and `sim/` equal `s7/D`'s. The merge items were the D fix round's text above, brought up to date; `docs/IMPROVEMENTS.md`, linked from `DEVELOPING.md` (DOC-7) and given the after-2.2.1 list (N1); `ENVIRONMENT.md` 8.4, reworded to agree with 8.1 and `AGENT_RUNS.md` section 2 (DOC-8); and this record.

**c77: the runs c76 did not cover.** The final review found two items of plans 7.3 and 7.4 that c76 did not run, and no single `wire` gate run at the head (`record.md`, "What c76 does not cover"). c77 ran the two items and one `wire` gate run at the head, from 02:04 to 06:52 UTC, as seven pieces:
- **Plan 7.3's last item:** SF2fix and draconian RC8 in `tb_frames`.
- **Plan 7.4's R2 phase runs:** Galagon and Spiders in `tb_frames` at 8,730 and 17,460 ps.
- **One `wire` gate run at `s7/D`'s head of that time, `356cea9`.**

**The trees:**
- The frame runs ran on c76's tree, a detached worktree at `317eaa8` with a clean status. They used c76's `tb_frames` binary (md5 `9a6b65a6…`, built on 10-14 and unchanged since) with `NOBUILD=1`.
- The wire gate ran in a new detached worktree at `356cea9`, clean before and after the run. Its `src/fpga` hashes the same as `317eaa8`'s (`6e010d35…`). Its wire bench is newer than c76's: `tb_wire.sv`, `wire.py` and `step7_gates.sh` changed after `317eaa8`, so the gate built its own binaries.
- Verilator 5.040, benches at VCO/19.

**How it ran.** The wire gate ran three times.
- Its first attempt, at 02:04-02:05, was stopped because its builds took the free space on `/` to 2,184 MB, under the 2,200 MB that this campaign kept free (a margin above the 2 GB of `docs/AGENT_RUNS.md` section 4). The later attempts kept the builds off `/`.
- At about 02:40 the machine stopped: the working session ended early (`docs/AGENT_RUNS.md` section 2). That stopped the three pieces then running, the wire gate's second attempt (from 02:06) and SF2fix and draconian (from 02:04). Each restarted from its beginning at 02:41.
- In the run that counts, free space on `/` stayed at 2,307 MB or more.
- Every simulation ran through the simulation slots. The logs are in the D worktree's gitignored `sim/work/step7/fix/fix/c77/`.
- A second reader judged every piece from its files, and a third checked the figures again from the CSVs.

**Result: all seven pieces exit 0, and each passes its plan's gate.**
- The two plan-7.3 runs and the four phase runs pass the V1 rule.
- The wire gate passes: 96 of 96 scenarios, and 7 of 7 mutants CAUGHT on their named keys.
- c77 found no difference from c76 or round 4 that the rules gate.

**c77, plan 7.3's last item: SF2fix and draconian RC8 in `tb_frames`.** `tb_frames` ran on the DARIA build with `INPUTS=tb_daria`, at VCO/19, phase 0, for 600 frames. R1's runs of these two images are 600 frames long, so each was compared with the whole R1 run, by `frame_gate.py --auto --rule v1 --expect-guard unlocked`. The second reader re-ran `frame_gate.py` on the four files of each run, at `317eaa8` and at `baca4cd`, and got c77's gate output byte for byte. Both pass:
- Each run holds 599 of 599 frames. `len_sys` and RIOT RAM are equal on every frame, and video on every frame but SF2fix's frame 1. The rule excuses that frame: the two calls requested in frame 0 hold the 6507 for 5,197 and 1,261 `clk_sys`, against R1's 4,342 and 1,352.
- Every call's ARM instruction count equals R1's.
- Each status line shows 0 halts, 0 PSRAM violations, the guard unlocked and 0 unlocks. The call counts equal R1's, with 0 late calls. The call cross-check is consistent: busy periods, `call_tog` flips, `call_go` and returns are equal in number, with 0 in flight at the end.
- Audio is counted, not gated:

| Image | Scheme | Calls | Frames with audio differing | `release_shift` runs (frames) | Other runs (frames) | Release difference: median; total hold |
|---|---|---|---|---|---|---|
| SF2fix | DPC+ | 775 | 391 | 0 | 2 (391): frames 4-119 and 325-599 | −59 `clk_sys`; 0.911 of R1's |
| draconian RC8 | CDF | 1,200 | 1 (frame 1) | 1 (1) | 0 | −128 `clk_sys`; 0.945 of R1's |

- **Against the D runs at ÷18** ("Frame runs on D against R1", above):
  - SF2fix, against D's run with the inputs matched, gives the same figures: audio on 391 frames in the same two spans, and frame 1's video the only other difference.
  - draconian RC8 had every column equal on all 599 frames at ÷18, in D's run on the Pocket's inputs; the D record shows no draconian run with the inputs matched. At ÷19 its frame-1 audio differs, in the `release_shift` class, and every later frame is equal.
  - The median release differences at ÷19 are −59 `clk_sys` on SF2fix and −128 on draconian. The D record gives −137 and −406 at ÷18; it does not say which inputs SF2fix's figure used.

**c77, plan 7.4's R2 phase runs: Galagon and Spiders at 8,730 and 17,460 ps.** The runs are as above, with `+arm_ofs=8730` and `+arm_ofs=17460` added: `clk_arm`'s lattice starts 6 or 12 VCO periods of 1,455 ps late. They ran 600 frames each and were compared with R1's first 600 frames of 1,500 (`--ref-prefix`).

The phase was applied:
- Each `run.log` prints the offset ("CLK_ARM VCO/19, phase offset 8730 ps", or 17460), and the run's arguments carry it.
- `tb_load`'s lattice check, which stops a run when a `clk_arm` edge leaves the shifted lattice, did not fire.
- Against c76's phase-0 runs of the same images (their first 1,197 calls and frames 1-599):

| Run | Calls whose release differs from phase 0's | By | Equal to phase 0's |
|---|---|---|---|
| Galagon, 8,730 ps | 7 of 1,197 | +1 `clk_sys` | every call's request time, ARM cycles and instruction count; `fp.csv` on every column of frames 1-599, audio included |
| Galagon, 17,460 ps | 201 | +1 on 138, −1 on 62, −7 on 1 | the same |
| Spiders, 8,730 ps | 55 | +1 on 52, +7 on 2, −1 on 1 | the same |
| Spiders, 17,460 ps | 89 | +1 on 61, −1 on 24, +7 on 4 | the same |

- The two phases also differ from each other: on 196 Galagon calls and 44 Spiders calls.

All four pass:
- Each run holds 599 of 599 frames, and `len_sys`, video and RIOT RAM are equal on every frame.
- The 1,197 calls compared have the same ARM instruction counts as R1's.
- Each run makes 1,199 calls in 600 frames, with 0 halts, 0 PSRAM violations, the guard unlocked and 0 unlocks.
- Spiders has 16 late calls at every phase, at the overrun frames 557-572, as R1 does; its worst slack is −1,776 `clk_sys`, as at phase 0. Spiders' rule from P13 excuses those frames, and 1 audio frame falls in them.
- Galagon has no late call. Its worst slack is 9,108 `clk_sys` at 8,730 ps and 9,120 at 17,460 ps, against 9,108 at phase 0 over the same calls.
- Audio is counted, not gated. The figures are equal at both phases. The differing frames are also phase 0's, since `fp.csv` equals phase 0's on frames 1-599:

| Image | Frames with audio differing (frames 1-599) | `release_shift` runs (frames) | Other runs (frames) | Release difference: median; total hold |
|---|---|---|---|---|
| Galagon, both phases | 61 | 2 (4) | 10 (57) | −262 `clk_sys`; 0.924 of R1's |
| Spiders, both phases | 163, and 1 in the excused overrun frames | 6 (23) | 17 (140) | −239 `clk_sys`; 0.924 of R1's |

- **Against the other phase runs:** c76's mode-B runs at the same two offsets, with the wrapper and 600 frames, passed: 0 calls differ from upstream's, 0 front-end failures, and every audio read was checked against the RAM at the read. The `tb_frames` runs now add DARIA's own frames at those offsets.
- **What the offsets are at ÷19:**
  - At ÷18 the lattice repeats every 3 `clk_sys`, and 0, 8,730 and 17,460 ps are its three alignments with `clk_sys`. Plan 7.4's "the other two phases" was written for that.
  - At ÷19 it repeats every 19 `clk_sys` (`tb_load.sv:41-42`). An offset of k VCO periods is the phase-0 lattice moved by 2k mod 19 `clk_sys`: 12 for 8,730 ps and 5 for 17,460 ps. So the runs cover 3 of the 19 alignments.
  - Within a run, call starts do not spread over the alignments. A Galagon or Spiders frame is 238,944 `clk_sys` (19 × 12,576; Spiders' overrun frames are 322,848, 19 × 16,992), and the calls come at the same points of each frame. So in every run each image's calls are requested on 3 of the 19 alignments: 599 calls on each of two, and the first call on a third. The 5-`clk_sys` shift of 17,460 ps moves one of the two large groups onto the other's phase-0 alignment, so over the three runs the two groups start on 5 alignments, not 6.
  - Call ends do spread: because the ARM cycle count differs from call to call, the releases fall on 18 or 19 of the 19 alignments in each run.
  - Mode B's `run.log` still labels its offsets with the ÷18 classes ("shared edges: clk_sys k mod 3", `fe_shadow.svh:2995-2996`, chosen from `+d_ofs` alone). No verdict reads that label.

**c77, the `wire` gate at `356cea9`.** `step7_gates.sh --only wire` ran in the worktree at `356cea9`, with `GAMES` (the Turbo run), `BIOS` (decision 11's runs) and `BUPFW` (the four Souper runs) given, as one call through the simulation slots. It ran from 02:41 to 06:52 UTC: the two builds, the 96 scenarios with `DIRECTED=1` until 06:26, then the seven mutants. The gate's verdict is `wire PASS` and `STEP7_GATES pass`, exit 0.

Scenarios, 96 of 96 pass:
- That is the whole set at `356cea9`. `pal2600_a78` was added later (`82d05f1`).
- In all 15 `+wire_pll` scenarios, `f6_pend` and `rgn_bad` are 0.
- Turbo: 138 calls, 138 returns, 20 cache misses, 0 PSRAM violations.
- **Against c76** (`317eaa8`'s bench): the same 96 scenarios, and each of the 26 counters a scenario reports is equal, scenario by scenario. The newer `rgn_bad`, which also reads `daria_mmio`'s `pal`, gives the same value in every scenario: 0 in the 15 `+wire_pll` ones.

Mutants, all seven of plan 7.2 CAUGHT, each on its named keys:
- `nomask` by `f6_live`, `f6_busy` and `wr_busy`, in `seq_menu_dpc`, `seq_auto_dpc` and `seq_slot_dpc`;
- `nowd` by `rt_f6_early` and `f6`, in `seq_load_cdf`;
- `nohold` by `releases` and `rs_f6_rst_low` in `seq_menu_dpc` and `seq_auto_dpc`, and by `releases` in `seq_slot_dpc`;
- `nofrzpend` by `f6` and `b2b`, in `seq_back_dpc`;
- `nofrzarm` by `f6_busy` and `f6`, in `seq_rfirst_dpc`;
- `palsel` by `rgn_bad` in 7 scenarios;
- `palpll` by `rgn_bad` in 5.
- **Against round 4** (`r4/mut/`, at `0b2f9e1`, whose `sim/` equals `356cea9`'s): every mutant's failing lines and verdict are the same, figure for figure. For example, `palsel`'s seven `rgn_bad` counts run from 2,099 to 513,468 in both.

This is the single `wire` gate run at the head that c76's record found missing.

**What c77 leaves:**
- **The wire set at `baca4cd`, the merged head, is 97 scenarios.** The 97th, `pal2600_a78` (RTL-1, pinned and accepted for 2.2.1), ran on both builds in the fix round and in the tools re-review, not inside a full gate run. c78 then ran all 97 in its `wire` gate, in pieces (below).
- **Plan 7.7's fresh-clone `step7_gates.sh` run** was still owed. c78 ran it (below).
- **The phase runs cover 3 of the 19 alignments at ÷19** (above). Over the three runs, every Galagon and Spiders call but the first starts on one of 5 of them. Plan 7.4's wording, "the other two phases", dates from ÷18.

### Plan 7.7's fresh-clone run, c78 (2026-10-16 to 10-17)

- **The run.** c78 ran `sim/step7_gates.sh`'s 15 gates on a new clone of DARIA-dev from GitHub, at `843830e`, from 2026-10-16 08:15 to 10-17 13:04 UTC. The driver and the logs are in the D worktree's gitignored `sim/work/step7/fix/fix/c78/`.
- **The clone:** the `src/` tree is `94cff68`, `317eaa8`'s. Its status was clean before and after every piece and at the end, no file in it is marked assume-unchanged or skip-worktree, and nothing was committed from it. It has no `sim/work/fixb/`, so I2's gate does not depend on that directory (plan 7.7).
- **The inputs, by path** (c78's `env.sh`):
  - the BupChip firmware: the main checkout's gitignored `src/fpga/mister/rtl/bupchip.hex`, linked at the same path in the clone, which `.gitignore:14` ignores;
  - the game images, the OpenBIOS image and the BupChip PCM references: the main checkout's gitignored `sim/work/bupchip/`;
  - R1's runs and the `extra_tests` reference log: the base worktree's gitignored `sim/work/step7/`;
  - dasm, 7800basic and MiSTer's high score and Supercharger firmware for `extra_tests`: the D worktree's gitignored `sim/work/step7/gates/extra_cache/` (deviation 5);
  - the hygiene name list, kept outside the repository (plan 7.7);
  - `AR_TAPE=1` and `S4_JOBS=1`, with `FP_REF` and `RUN_SIM_REF` unset, as in c76.
- **How it ran.** Verilator 5.040, the benches at VCO/19, and at most three simulations at once through the simulation slots. Each gate wrote to a fresh output directory, and each piece's text results were copied to c78's directory as it ended. Every simulation binary was built in c78; dasm and 7800basic came built from a cache (deviation 5). The builds shared the machine's ccache; a hit needs identical compiler input, so it cannot change a result.
- **Why in pieces.** One call runs the gates in turn, and c78's pieces took about 70 h of run time: the 16 frame runs 2.1-2.2 h each, the 56 `s4` jobs 16.3 h, and `extra_tests`' two halves 6.8 and 5.0 h. Sessions end after 2-13 h (`docs/AGENT_RUNS.md` section 2). So the gates ran as 45 resumable pieces; four gates were split into several pieces or calls each (deviations 2, 3, 4 and 6, below).
- **Result: every gate passes.** 29 pieces exit 0, and the 16 frame pieces exit 3, PARTIAL alone, with 16 of 16 images passing together. By the lead's rule for this run (2026-10-16, set when the machine's stops cut the whole `s4_check` and `wire` runs), a gate run in pieces passes when its pieces cover it and each passes. A second reader re-derived every verdict from the logs and confirmed all 15.

**The gates** (`record.md`, "Plan 7.7's fresh-clone run: c78", has a short form of this table):

| Gate | Ran as | Result | Against c76 and c77 |
|---|---|---|---|
| `hygiene` | the static call | PASS: `aeee6d2..843830e`, 89 files, 18,966 added lines | c76 checked `70a63ca..317eaa8`, 43 files |
| `pp_equiv` | the static call | PASS: the non-DARIA stream is `9b9e7e5e…`, with 0 `daria` tokens; `top.sv` and `cart2600.sv` equal `aeee6d2`'s under both macro sets | equal but the header (HEAD and date) |
| `pp_guards` | the static call | PASS: 4 guards, 0 findings | equal but the header and the tree path |
| `divider` | the static call | PASS: 11 defaults, all at VCO/19 | equal but the header |
| `lint` | the static call | PASS: no warning added in the 3 sets; 71, 1 and 0 removed | equal but the header and the tree line |
| `fit_selftest` | the static call | PASS: 117 of 117 | 117 of 117 in the final review's re-run |
| `run_sim` | its own call | PASS on both builds: `BIOS_BOOT`, `BUPCHIP_E2E` (PCM identical) and `PLL_REGION` (0 errors); the DARIA section's 391, 1 and 112 calls, 0 halts, the guard unlocked; 21 fingerprint cases identical, DARIA against plain | both `.out` files equal c76's but the RTL path and md5 lines |
| `cartram` | its own call | PASS: 21 matrix cases; the s19 hand-over at s19, never above; 14 reset cases, `midswap` and `forcecoinc`; `nohold` and `nocmp` CAUGHT; 20 fingerprints identical | the log equals c76's after paths, md5, HEAD and date |
| `extra_tests`, `AR_TAPE=1` | two halves in parallel, then the gate's checks | PASS: each half exits 0 and passes `extra_tests_check.py --ar-tape`; the tape's full load differs in 0 bytes, and the multiload loads 0, then 1; 37 fingerprints identical (16 `extra_*`, 21 `cartram_*`) | the DARIA `.out` equals c76's but paths and md5; the plain one also has the two lines of its own `tb_cartram` build, which c76's plain half reused from its cut first attempt |
| `selftest` | its own call | PASS: 268 of 268, no group left out | 268 of 268 in the nits round's re-run on c76's inputs |
| `s4_check` | 56 jobs, one per call | PASS: 28 of 28 in each set; 19 `tb_s4` runs per set with 0 PSRAM model violations; "snap: ok" in all 19 DARIA runs and "snap: na" in all 19 plain ones; DARIA clocks 36.172 MHz (16 runs), 35.842 (1) and 21.281 (2) | all 56 `.out` files equal c76's after paths, times and md5 |
| `wire` | 1 build, 8 scenario groups, 7 mutant pieces | PASS: 97 of 97 scenarios; 7 of 7 mutants CAUGHT on their named keys; `f6_pend` and `rgn_bad` 0 in all 16 `+wire_pll` scenarios; Turbo 138 calls, 138 returns, 20 cache misses, 0 PSRAM violations; `pal2600_a78` with open item 20's retunes and releases, to the µs | c77's 96 scenarios: all 26 counters and the notes equal; the mutants' FAIL and MUTANT lines equal c77's |
| `daria_smp` | the unit call | PASS: 18 clean runs, 8 of 8 mutants caught | the result lines equal c76's |
| `dbg_snap` | the unit call | PASS: 32 runs, 7 of 7 mutations caught | the result lines equal c76's |
| `frames` | 16 calls, one image each | PASS, the union: below | all 80 CSVs (5 per run) byte-equal to c76's; the report lines equal |

- **The frames:**
  - All 16 images pass the V1 rule, 1,499 of 1,499 frames each, with `len_sys`, video and RIOT RAM equal on every frame.
  - Every call's ARM instruction count equals R1's. Every status line shows 0 halts, 0 PSRAM violations, the guard unlocked and 0 unlocks. Spiders has its 16 late calls, as R1 has.
  - Frame 1's video was excused on Wizard of Wor, Zaxxon and Zoo Keeper, as in c76.
  - Audio differs on 8,928 frames, as in `record.md`'s frame-gate table for c76. It is counted, not gated.
  - The second reader re-ran `frame_gate.py` on Spiders and on Wizard of Wor with the gate's arguments: both exit 0, with output byte-equal to the piece logs.
- **The simulation binaries** differ in md5 from c76's and c77's: each was built in c78, and a build embeds its source path. `tb_frames` is `398f0f36…` in all 16 frame pieces (c76: `9a6b65a6…`), and `tb_wire` is `b5254e16…` (DARIA) and `22c997d4…` (plain), against c77's `8a3f6a62…` and `19fe82b7…`.
- **Free space on `/`:** the lowest value recorded was 2,235 MB (c78's `free.log`). The monitor trimmed the shared ccache 5 times, each time free space fell under 2,240 MB.

**Deviations from plan 7.7:**
1. **No single `step7_gates.sh` call** (above). The six static gates ran as one `step7_gates.sh --only` call and the two unit gates as another; `run_sim`, `cartram` and `selftest` ran as one call each. Each of these exits 0 with "STEP7_GATES pass".
2. **`s4_check` ran per job,** as in c76: `s4/check.sh` with `ONLY=` one job and `JOBS=1`, one call per job, with the gate's environment for each set. The 09:16 stop had cut the whole gate.
   - The gate's own verdict line and its log header (plan P23) were never written. The verdict is the 56 job results together. Each piece log names the clone's HEAD and clean status at its start (`logs/s4d.log`, `logs/s4n.log`), and the driver checked both, and the firmware link, before every job.
   - As in c76, `tb_s4`'s md5 is not printed; the gate does not print it either.
3. **`wire` ran split.**
   - Two whole runs were lost: one cut by the 12:28 stop about 3 h in, and one stopped at 12:48, 7 of 97 scenarios in, to run the gate in pieces.
   - It then ran as one build (`wire.py build daria plain`), 8 groups of 4-17 scenarios (`wire.py run` with the gate's environment, 30-36 min each), and one piece per mutant on the scenarios that catch it (`wire.py mutant`). The two binaries stayed on disk, and their md5 was checked before each use.
   - `wire_judge.py`, written for c78, judged the union: each scenario of `wire.py list` in exactly one group and PASS on the build's binaries, and each mutant CAUGHT, with `wire.py`'s verdict applied again to its saved records.
4. **`extra_tests` ran its two halves in parallel,** not in turn as in c76. The gate's own check functions, taken from the clone's `step7_gates.sh`, then judged them.
5. **`extra_tests` took its tools from a cache,** as in c76. dasm, 7800basic and MiSTer's high score and Supercharger firmware were copied from the D worktree's gitignored `sim/work/step7/gates/extra_cache/` into each half's `WORK`, so `extra_tests.sh` cloned and fetched nothing. Without them it clones dasm and 7800basic at their current heads and fetches the two firmware files (`sim/extra_tests.sh:47,78,82,166`).
6. **The frames gate ran one image per piece** (`FRAMES_LIST` with one name). Each piece alone is PARTIAL; the 16 together are the gate.
7. **`GAMES` differed by gate:** Turbo's directory for `wire`, and each image's own directory for the frames, where one call takes a single `GAMES`. Each of the 16 images has one content under `sim/work/bupchip/` (Stratovox's three copies are identical), so this changes nothing.
8. **Restarts.** The machine stopped at 09:16 and 12:28 UTC on 10-16, stops of the kind `docs/AGENT_RUNS.md` section 2 describes, and the workers were stopped by PID at 09:28 to change the driver.
   - Each time, the chain (`run_sim`, `cartram`, `extra_tests` and `selftest`, which share one output directory) restarted from its beginning. The chain started at 12:29 also kept its state on disk, from the driver's fourth version (12:48); it never had to restore from it.
   - `run_sim` ran 4 times in all: two runs were cut (09:16 and 09:28), and one finished with exit 0 at 10:45 but was lost with its chain at 12:28. Their logs are kept (`logs/ch_run_sim.lost*.log`).
   - Worker 2 alone was stopped by PID at 10:45 so that `extra_tests`' plain half could start at once. It was running `s4d` on the driver's second version, which could not yield to another piece. It restarted on the third version. That cut `s4d`'s job `cache`, which reran; the chain ran on.
   - No piece was cut after 12:48 on 10-16, and the machine did not stop again.

`lint` writes into the tree's gitignored `sim/work/step7/lint` rather than under the gate's output directory (`sim/lint_step7.sh:22`). A single call does the same, so this is no deviation; the status stays clean.

**What c78 does not show:**
- `step7_gates.sh` running all 15 gates in one process, with its 15-gate `summary.txt` and its exit 0. `selftest.py` checks the runner's gate names, frames list and PARTIAL verdicts on stand-ins (`f3a9b49`).
- The frames gate's default list of 16 images, used when `FRAMES_LIST` is unset.
- The gate functions of `s4_check`, `wire` and `extra_tests` as written. Their verdicts rest on joins written for c78, outside the repository (`c78.sh` and `wire_judge.py`). The second reader re-derived all three from the raw outputs.
  - `g_wire` is unchanged since `356cea9`, where c77 ran the `wire` gate whole and it passed. `g_extra_tests` is unchanged since then too, and c76 also ran its halves as separate calls.
  - `g_s4_check` changed from `ARM38=1` to `ARM19=1` (`b177e64`) after its last whole run, which passed at `70a63ca`. It has not run whole at `ARM19`; c76 and c78 ran its 56 jobs with its environment.
- That the gates need only the firmware and the game images: `extra_tests` also needs network access, or the cache of deviation 5.

**Notes on the record:**

- **The second reader corrected the run's own notes** (c78's `NOTES.txt`, its final judgement):
  - The last piece cut was the whole `wire` run, at 12:48 on 10-16. The notes said only that none was cut after 01:24 on 10-17.
  - The lowest free space on `/`, 2,235 MB, is the lowest the monitor recorded. The monitor started at 08:20, about 5 minutes after the first pieces, and died with the stops at 09:16 and 12:28 on 10-16; it was restarted at 09:24 and 12:40. So free space went unrecorded while pieces ran for about 5, 6 and 10 minutes, from 08:15, 09:17 and 12:29.
  - `extra_tests` took dasm, 7800basic and MiSTer's two firmware files from a cache, as c76 did, which the notes' list of deviations left out. So the run does not show that the gates need only the firmware and the game images.
- **Step 7 is done for V1.** `record.md`, "Plan 7.7's fresh-clone run: c78", records c78 in short, and `DARIA_CORE.md`'s status line and done-when and the record's hand-over now say so. What remains for 2.2.1 is step 8, the hardware tests of plan section 9, and the release.

### Step 8: hardware tests of daria-test1 (2026-10-17)

**The builds.** Two test zips of the verified tree, `317eaa8`'s `src/`, both `SEED` 2: plain, with the qsf as committed, and debug, with `BUP_DEBUG` added (c76's Q5 edit to the qsf).

- **The fits equal c76's.** The plain fit's figures are those of c76's Q2 seed 2, and the debug fit's those of Q5 seed 2. The timing report, the summary's timing and ALMs-by-entity sections, and the qsf copy are byte-equal. The plain `.rbf` differs from c76's only through `apf/build_id.mif`'s date, time and random word.
  - Plain: `clk_sdram` +2.683 ns, `clk_arm` +1.077 ns, the guard pair +0.397 ns, worst hold +0.098 ns; 15,625 ALMs (85%), 195 M10K.
  - Debug: `clk_sdram` +2.265 ns, `clk_arm` +0.636 ns, the guard pair +0.131 ns, worst hold +0.121 ns; 15,802 ALMs (86%), 195 M10K.
  - Both pass the step-7 fit checks: `run_step7.sh` exits 0 with the verdict PASS. The debug fit's (c.cells) passes by the tracked table.
- **The checklist** was written for these builds (2026-10-17). Its items: A1-A21, the 15 demos and the six added images; B, the Champ Games Presents batch; C, the PSRAM at 36.17 MHz (Turbo and the BupChip); D, region; E, Fix B, DPC and the Supercharger; F, 7800 games; G, switching games and long play; H, the debug zip's baseline reading. Its section 4 lists the expected differences, and its section 7 the items these builds cannot test.

**The owner's report** (2026-10-17), as written:

> everything looks good, tested the library and played the games, I can even see where the spider arcade game gets the late calls since the whole screen shifts down for a couple of frames before the level loads. fortunately it does not seem to interfere during the actual game play as I was able to beat a couple of levels of that and it kept working.
>
> had to refer back to youtube captures to ensure that what I was hearing was not too noisy.
>
> unfortunately all the pal versions seem pal 60 so that part of the test was not able to be completed.

**What it shows:**

- **The library plays.** The owner tested the library and played the games, and everything looks good. The report is a verdict on the whole list. It gives no result per checklist item, and it does not say which zip was used.
- **The owner sees Spiders' late calls, and they do not seem to affect play.**
  - On the Pocket the whole picture shifts down for a couple of frames before a level loads.
  - The owner ties the shift to the late calls. In simulation those are 16 calls in the overrun frames 557-572, the same calls that upstream's core misses (`record.md`, "The frame gate, V1 rule"; `DARIA_CORE.md`, "Step 3 work"). The hardware cannot count them until the overlay exists.
  - In c76's frame run those 16 frames are 354 lines long instead of 262 (322,848 `clk_sys` against 238,944). R1's, from upstream's core, are the same length: the frame gate found `len_sys` equal on every frame, none excused. The run and its gate report are in the D worktree's gitignored `sim/work/step7/fix/fix/c76/frames/`.
  - The frame runs stop at 1,500 frames, about 25 s, so they hold only the first such overrun, about 9 s in.
  - Play does not seem to be affected: the owner beat a couple of levels, and the game kept working. The checklist expected this (section 4 and item A9).
- **The sound was checked against video captures.** The owner "had to refer back to youtube captures to ensure that what I was hearing was not too noisy". The report gives no click count for Galagon and Mappy (item G4).
- **The PAL region items could not be completed.** These are the checklist's D1, a PAL 2600 ARM image on Region Auto, and D2, a PAL A78 after it (RTL-1).
  - The PAL versions the owner has all seem to be PAL60 builds ("all the pal versions seem pal 60"). A PAL60 build draws 262-line frames, which Region Auto treats as NTSC. Stay Frosty 2's PAL build was already recorded as one (`DARIA_CORE.md`, "The added images").
  - So both items stay covered by simulation only, by these `tb_wire` scenarios (`sim/bupchip/daria/wire/wire.py`):
    - `pal_dpc`: a synthetic PAL DPC+ image on Auto. One retune, to PAL, then the game restarts in PAL (D1).
    - `pal2600`: a PAL 2600 tone program on Auto. One retune, to PAL.
    - `pal2600_a78`: a PAL 2600 image, then a PAL A78. The DARIA build's two extra retunes, ending in PAL (D2; `DARIA_CORE.md`, open item 20).
    - the eight `seq_*` scenarios: region changes inside load sequences. `seq_tia_dpc` runs `pal_dpc`'s image.
  - All of them pass in c78's `wire` gate, 97 of 97 scenarios (`record.md`, "Plan 7.7's fresh-clone run: c78").
  - D2 needs no ARM image. `pal2600_a78`'s first image is a plain PAL 2600 program, so any 50 Hz PAL 2600 game followed by a PAL A78 would run it. `docs/IMPROVEMENTS.md` lists the hardware test of both items.

**What this round did not test:**

- **The DARIA status overlay items.** The overlay is not built (plan P16 and P22). So neither zip shows the guard's lock state and unlock count, DARIA's call and late-call counts, the late-call source, or the halt flag, halt code and fault code. The debug zip's cells show only the BupChip. `docs/IMPROVEMENTS.md` lists the overlay as a later item.
- **The assumption that DARIA's clock and the console clock rise together** stays a timing-analysis assumption at this clock, as the checklist's section 7 says.

**The owner's call** (2026-10-17), as written: "package the core unchanged and then do the pull request. prepare the release notes as well". So step 8 is closed for 2.2.1. The PAL region items and the overlay are deferred to `docs/IMPROVEMENTS.md` (`DARIA_CORE.md`, "Steps" item 8).

**The release** (2026-10-17). 2.2.1 was released with the AtariVox voice (PR #6), as a new fit: the AtariVox build's own, `SEED` 2. Its DARIA RTL is the verified tree's, unchanged. Its figures are in the README and `docs/ATARIVOX.md` (`DARIA_CORE.md`, "Steps" item 9).
