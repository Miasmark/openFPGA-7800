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
