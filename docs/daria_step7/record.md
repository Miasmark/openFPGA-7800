# DARIA step 7: the record (2026-10-09 to 10-17)

This is the record of DARIA's step 7, integration and Fix B. It was the section "Step 7 work" of [`DARIA_CORE.md`](../DARIA_CORE.md) until 2026-10-17, when it moved here to keep that file under the hygiene check's size limit of 262,144 bytes (`sim/check/hygiene.sh`). The text is as it was, with its headings one level up. Its pointers are fixed for the new place: `plan.md` and `progress.md` are beside it, and where it names a part of `DARIA_CORE.md`, such as an open item or a decision, it now names the file too. `DARIA_CORE.md` keeps a short summary under the old heading, so references to "Step 7 work" still land.

`plan.md` is the plan, with every amendment marked in place, and `progress.md` records the runs as they landed. This file records the result. **The tree verified for 2.2.1 is `317eaa8`'s `src/`,** and 2.2.1 ships its DARIA RTL unchanged (`DARIA_CORE.md`, "Steps" item 9). At the final review's head `src/` is byte-identical to it, and the owner froze it as verified (2026-10-16). The verification campaign on that tree, c76, ran from 2026-10-14 09:13 to 2026-10-16 00:58 UTC. Every piece exits 0, and every gate passes under the amended rules. Plan 7.7's fresh-clone run, c78 (2026-10-16 to 10-17), passes every gate, as the union of its pieces, on DARIA-dev at `843830e`, with the same `src/` (below).

## What was built

- **The integration** (`POCKET_DARIA`, which `ap_core.qsf` now sets):
  - `daria_fe` sits in `atari7800_pocket.sv` beside the BupChip wrapper.
  - The hooks in the vendored `top.sv` and `cart2600.sv`: for DPC+ and the CDF family, `cart2600` takes the front end's byte (`fe_do`), its output enable (`fe_oe`) and its two busys (`fe_call_busy`, `fe_dma_busy`). `is_bad_game` keeps only `BANKELF` and `BANKBUS`. `mapper_init_busy` stays 0: `daria_fe`'s `init_busy` goes straight into the wrapper's reset (`daria_hold`).
  - `daria_smp`, the sample requester beside the asset cache.
  - `bup_dbg_snap`, the `BUP_DEBUG` status word's snapshot (`DARIA_CORE.md`, open item 11).
  - The DARIA-only build files: `core/daria_constraints.sdc` (the ±20 ns crossing bounds and the guard pair's 6 / 1 ns) and `core/daria.qip`, which sources `core/daria_sync.tcl` (the synchroniser marks, and `ROUTER_REGISTER_DUPLICATION OFF`).
- **Fix B** (commit F, `20c7c2a`): the 2600 cartridge-RAM request goes to `sram_ctrl` on its own `clk_sys` registers (`t_*_q`), off the SRAM's `clk_sdram` request path (`DARIA_CORE.md`, "Fix B").
- **Commit P** (`b1e57ef`), in both builds: the shipped core's PAL 2600 loop on Auto region is fixed. `is_pal_o` is now `region_pll`, which is held while a 2600 image's region is not known. Before the fix, a PAL 2600 game made 41,293 retunes in 1.3 simulated seconds and ended in NTSC; after it, one retune, to PAL, at 955 ms.
- **The clock:** ÷19, 36.17 MHz (`DARIA_CORE.md`, decision 7; `b177e64`). `daria_sync.tcl` turns the router's register duplication off (`3201313`). `daria_constraints.sdc`'s fitter-only block asks for 5.5 ns on the guard pair (`618b5c3`).
- **The retune-inside-F6 race, fixed** (`f2c305e`). The wrapper keeps `daria_rgn`, the region of the PLL's last completed retune, and a retune is pending while `region_pll` differs from it. `region_pll` is frozen while a retune is pending or under way, and while an ARM image's console is in reset. During a 2600 download it is set back to `daria_rgn`. While a retune is pending, F6 cannot start, so F6 runs once, after the retune. DARIA's timer prescale takes `daria_rgn` (`c5fb23f`).
- **The kept seed:** `SEED` 2, `ap_core.qsf`'s already. It is the only seed that passed every check as first written. 2.2.1 ships the AtariVox build's own seed-2 fit (`docs/DARIA_CORE.md`, "Steps", item 9). The seed comment above it still gives 2.1.1's margins (open: "After 2.2.1", below).

## Decisions taken in step 7

- **÷19 for the first release** (owner, 2026-10-12, "V1 even if not exact"; plan 5.2). At ÷18, Q2 on D met `clk_arm` on two seeds of three (+0.548 / +0.115 / −1.736 ns). Fitter padding did not fix it: over nine ÷18 fits `clk_arm` averaged +0.04 ns over a range of 2.7 ns, and 3 of 9 missed. ÷19 met it on every seed with no padding (+1.477 / +1.638 / +1.614 ns). Its cost: the guard is inert, so cart RAM coincidences are a counted race again (`DARIA_CORE.md`, open item 7), and Qyx's heaviest call takes 97% of its budget.
- **"Same frames": wanted, not required for V1** (owner, 2026-10-12). Plan P13 and 7.4 became the V1 rule. It gates frame length, video, RIOT RAM and each call's ARM instruction count on every frame. Audio is counted and documented, not gated. R2 runs with bench parity: `tb_frames` presents the TIA's paddle inputs as R1's bench did.
- **The retune-inside-F6 race is fixed,** not left to step 8 (owner, 2026-10-12): `f2c305e`, above.
- **Q2 at ÷19: two checks amended, no lever** (the lead, 2026-10-14; plan 5.4).
  - At ÷19 the guard cannot lock whatever the delay of its `pd_tog` → `pd_rx` path, so that path's 6 ns window guards no function. Check (a) still requires the constraint applied and the pair single, and reports the pair's setup slack without gating on it. Check (l) leaves out that one path when it is the only failing `clk_sys` endpoint.
  - Check (h)'s `t_*_q` → `clk_sdram` threshold drops from +4.5 to +3.0 ns, still 1.5 ns clear of the +1.5 ns release gate.
  - A lever (a fitter target, or other bounds on the pair) would have voided Q2, Q-mut and Q5, about a day of fits, with no sign that it would close.
- **At the final review** (owner, 2026-10-16): `src/` is frozen as verified for 2.2.1. The review's `src/`-only findings move to after 2.2.1 ("After 2.2.1", below). RTL-1 is accepted for 2.2.1 as a known minor issue (`DARIA_CORE.md`, open item 20).

## Fix B (Build A)

Fix B was fitted alone first (Q1, seeds 1 / 2 / 3, `clk_sdram` worst setup at the worse slow corner). It meets the +1.5 ns gate on all three seeds: +2.390 / +1.873 / +2.714 ns, against +1.822 / +1.850 / +1.735 ns on `aeee6d2` (Q0). Its smallest margin is +0.37 ns above the gate.
- Check (g) passes: no path from `cart2600` or `read_DB` reaches `sram_ctrl`'s registers or the SRAM pads except through `t_*_q`. The same query finds 18,734 such paths on `aeee6d2`.
- Fix B saves 107-136 ALMs.
- Q1r, seed 2 again, gave a byte-identical `.rbf`, so Quartus is reproducible here. That makes Q4's identity proof possible (below).

## The verification campaign c76 on the shipping tree (2026-10-14 to 10-16)

Plan 7.6's reruns, on `317eaa8`'s `src/`.
- **How it ran.** Every simulation ran on a detached worktree at `317eaa8` with a clean status, Verilator 5.040, and the benches at VCO/19. The fits ran under the Quartus lock on the same tree. Q5 added only the `BUP_DEBUG` line to the qsf, and Q-mut only its two mutants. The campaign went through several session restarts, and each piece was resumed or restarted from its beginning.
- **The logs** are in the D worktree's gitignored `sim/work/step7/fix/fix/c76/`.
- **The second reader** judged every piece and fit against plan 5.x and 7.6, under the amendments of 2026-10-14.

**Benches and checkers changed after `317eaa8`; the RTL did not.** The changed files, up to `356cea9` (`git diff --stat 317eaa8 356cea9 -- sim/`: 9 files), are `tb_wire.sv`, `wire.py`, `selftest.py`, `step7_checks.py`, the table in `step7_report.tcl`, `f3_crossings.txt`, `quartus_probe/step7/selftest.sh` (the fit driver's self-test), `quartus_probe/step7/smoke/smoke.sv` (the smoke test's design) and `step7_gates.sh`. Where a c76 piece ran an older tool, the run that covers the current tool is named.

### Static gates

- **Hygiene** over `70a63ca..317eaa8`: 43 files, 1,854 added lines.
- **`pp_equiv`:** the non-DARIA stream is `9b9e7e5e…`, P's, with 0 `daria` tokens. `top.sv` and `cart2600.sv` equal `aeee6d2`'s under both `tb_daria` macro sets.
- **`pp_guards`:** 4 guards, 0 findings.
- **`divider`:** 11 bench and gate defaults, all at VCO/19.
- **Lint:** no warning added in any of the three macro sets.
- **The builds:** `tb_wire` (DARIA and plain), `tb_frames` (DARIA, `BUP_DEBUG` off), and `tb_daria` mode B with and without the wrapper at `WIN_KB=64`. Every wire, frame and mode-B piece names the binary it ran, and each is one of these. `run_sim`, the cartram matrix, `extra_tests`, `s4/check.sh` and the unit benches build their own.

### `run_sim`, the cartram matrix and `extra_tests`, on both builds

- **`run_sim.sh`:** passes on both builds.
  - `BIOS_BOOT`, `BUPCHIP_E2E` and `PLL_REGION` pass, and the BupChip's PCM is identical to the reference.
  - The DARIA section's three synthetic images run 391, 1 and 112 calls. Every call returns, with 0 halts and 0 PSRAM violations; the guard stays unlocked with 0 unlocks.
  - All 21 fingerprint cases are identical between the DARIA and plain builds on every column, the CPU column included (plan 7.5 row 5).
- **The cartram matrix:** passes.
  - The matrix covers 8 mappers with Flicker Blend off and on, the Supercharger, a 7800 RAM cart and an ARM image.
  - The directed s19 run passes: the latest hand-over is at s19, never above.
  - The 14 console-reset cases, `midswap` and `forcecoinc` pass.
  - Both mutants are caught: `nohold` by the reset sweep and by `forcecoinc`, `nocmp` by `midswap`.
  - All 20 fingerprints are identical between the builds.
- **`extra_tests.sh` with `AR_TAPE=1`:** passes. It ran as the gate's two halves, each with its own `obj_load`.
  - Each half exits 0, and `extra_tests_check.py --ar-tape` passes on each against the reference build's log: the POKEY and DLI statistics, `ARCHECK`, multisprite row for row, the tape's full load, and the multiload's 0-then-1 order.
  - All 37 fingerprints (16 `extra_*`, 21 `cartram_*`) are identical between the builds.
  - The tape multiload ends white (`$0e`), not the header's red and green, on both builds and in the reference. The checker notes this and does not fail it.

### `s4/check.sh` on both sets

- **Both sets pass 28 of 28.**
  - The DARIA set ran with `ARM19=1 PSRAM_CS=50.0 SNAP_REQUIRED=1`.
  - Each job ran alone (`ONLY=`, `JOBS=1`) and every `.rc` is 0. Each call therefore labels itself "a subset, not the gate"; the 28 results together are the set.
- **The DARIA set:**
  - All 19 `tb_s4` runs print "snap: ok", with 0 PSRAM model violations.
  - Clocks: 36.172 MHz; 35.842 MHz in the PAL retune job; 21.281 MHz in the two `arm15pal` jobs, which set their own clock.
  - `synth_reloads` meets its placement requirement at ÷19 (`+holdstep=7`): one hold falls mid-access and one on the arriving halfword.
- **The non-DARIA set:** 19 runs at 28.636 MHz, "snap: na", 0 violations.
- **PCM:** every job with a reference is PCM-identical to it, in both sets.

### Unit benches and the gate checkers

- **`tb_daria_smp`:** 18 clean runs and 8 of 8 mutants caught.
- **`tb_dbg_snap`:** 32 runs pass, one of them at ÷19 with a random phase, and 7 of 7 mutations are caught.
- **The checkers' selftest:** 232 of 232 on `317eaa8`'s `selftest.py`. The 14 `wire.py` cases added in `2ed7e15` passed in round 4's gate run at `dfccd7f` (179 of 179).
- **`fit_selftest`:** 88 of 88 at `0412aac`, outside c76.

### `tb_wire`'s full set and its mutants

- **c76:** 96 of 96 scenarios pass on `317eaa8`'s bench (`DIRECTED=1`, `GAMES`, `BIOS`, and the four Souper runs).
  - In all 15 `+wire_pll` scenarios, `f6_pend` and `rgn_bad` are 0.
  - Turbo: 138 calls, 138 returns, 20 cache misses, 0 PSRAM violations.
- **The newer bench** (`rgn_bad` also reads `daria_mmio`'s `pal`; a mutant counts as CAUGHT only on its named keys) is covered by two rounds:
  - **Round 3** ran the 15 `+wire_pll` scenarios on a binary identical to the committed bench's (md5 `dbf97f17…`). All pass.
  - **Round 4** (at `0b2f9e1`, whose `sim/` equals `356cea9`'s) ran the seven mutants of plan 7.2 on real simulations. Every one is CAUGHT on the keys 7.2 names:
    - `nomask` by `f6_live`, `f6_busy` and `wr_busy` in three scenarios;
    - `nowd` by `rt_f6_early` and `f6`;
    - `nohold` by `releases` and `rs_f6_rst_low`;
    - `nofrzarm` by `f6_busy` and `f6`;
    - `nofrzpend` by `f6` and `b2b`;
    - `palpll` by `rgn_bad` in 5 scenarios;
    - `palsel` by `rgn_bad` in 7.
  - Round 4 also re-ran the 7 `+wire_pll` scenarios outside `seq_*` with the new `wire.py`, and all pass. Its gate test exits 1, as intended: with `WIRE_MUT=nofrzpend,nofrzarm` and only `seq_back_dpc` run, `nofrzpend` is CAUGHT and `nofrzarm`, whose scenario did not run, is an ERROR, which fails the gate.
  - Round 4's logs are in the gitignored `sim/work/step7/fix/fix/r4/mut/`. This is the run on real simulations that the D fix round's record in `progress.md` was waiting for; it ran on 2026-10-15.

### The fits

Figures are in ns. Setup is at the worse slow corner, and the guard pair's slack at slow 85 °C. (h) is the `t_*_q` → `clk_sdram` setup. Verdicts are from `step7_checks.py` at `356cea9`, run on copies of each fit's report files without a refit.

| Fit | `clk_arm` | `clk_sdram` | Worst hold | Guard pair | (h) | ALMs needed | Verdict as amended (as first written) |
|---|---|---|---|---|---|---|---|
| Q2 seed 1 | +1.241 | +2.462 | +0.120 | +0.217 | +4.298 | 15,602 | PASS (FAIL (h)) |
| **Q2 seed 2, kept** | +1.077 | +2.683 | +0.098 | +0.397 | +6.697 | 15,625 | PASS (PASS) |
| Q2 seed 3 | +1.765 | +2.919 | +0.119 | −0.046 | +6.338 | 15,600 | PASS (FAIL (a), (l)) |
| Q2 seed 3, `KEEP_DB=1` | the same figures as seed 3 | | | | | | PASS |
| Q4 (no DARIA, `PIN_ID=1`) | — | +2.380 | +0.100 | — | +6.423 | 12,990 | PASS; `.rbf` md5 `8569ab1e…`, equal to Q1''s |
| Q-mut, seed 1 | +1.539 | +2.788 | +0.090 | +0.380 | +4.925 | 15,521 | FAIL (f), (k') only, as required |
| Q5 seed 1 | +0.151 | +2.618 | +0.107 | +0.603 | +5.212 | 15,799 | PASS once (c.cells) is judged by the corrected table (below) |
| Q5 seed 2 | +0.636 | +2.265 | +0.121 | +0.131 | +5.634 | 15,802 | the same |
| Q5 seed 3 | +1.929 | +2.665 | +0.095 | −0.060 | +5.981 | 15,818 | the same ((a), (l) as first written fail) |

- **Q2 meets plan 5.2 and 5.3 on every seed.**
  - `clk_arm` ≥ 0, `clk_sdram` ≥ +1.5 ns, and hold > 0 at every corner.
  - Area: 84.4-84.6% of the device. LABs are 1,767-1,770 of 1,848, M10K 195 of 308, and peak interconnect 60.4-60.8%. That is 77-102 ALMs over the 84% guide, which by plan 5.1 triggers nothing.
- **Q2 under the amended checks:**
  - Seed 1's (h), +4.298 ns, clears +3.0 ns.
  - On seed 3, (a) finds exactly one setup path at every corner with the 6.000 ns relationship: −0.046 ns at slow 85 °C, +0.049 at slow 0 °C. (l) leaves it out: the Slow 85 °C Setup Summary gives `clk_sys` a slack and End Point TNS of −0.046 ns both, so no other `clk_sys` endpoint fails, and `pd_rx`'s only fan-in is `pd_tog`.
  - Every other check passes on all three seeds, (c) included: neither the guard pair nor any first flop is duplicated or retimed.
- **Q4** passes every gating check, and its `.rbf` equals Q1''s: the build without DARIA is the same bitstream as commit P's.
- **Q-mut:** (f) names `run_s[0]`, and (k') names `ready_s[0]`. Nothing else fails.
  - *2026-10-21:* "Nothing else fails" is c76's result, not a rule: plan 7.2 asks that (f) and (k') each catch their mutant. From the release after 2.2.1, Q-mut passes when (f) names `run_s[0]` and (k') names `ready_s[0]`, and any other failure is explained. That round's Q-mut also failed (g), with 150 paths of the 7800 cart-RAM request from a register that the fitter's retiming named after `mapper_AR`'s `tape_num` decode; no release fit has it (`docs/daria_step10/plan.md` 3.1, "Stage 2's pre-campaign round").
- **The I3 STA mutants,** run `REPORT_ONLY` on copies of the `KEEP_DB` refit, fail as plan 7.2 requires:
  - the guard pair removed fails (a), (b), (k) and (e), because the path is timed at 20 ns instead of 6 / 1;
  - a clock-group cut added after the ±20 ns lines fails (a), (b), (k), (e) and (k');
  - the cut in place of those lines fails the same five.
- **The guard detail on the `KEEP_DB` database** (information, not a gate): the chain's script stopped on a Tcl option error (rc 3), and its rerun by hand agrees with seed 3. Setup −0.046 / +0.049 / +2.860 / +3.198 ns and hold +2.265 / +2.116 / +0.439 / +0.271 ns, at slow 85 °C, slow 0 °C, fast 85 °C and fast 0 °C.
- **Q5:**
  - Each fit's own verdict failed (c.cells), because `317eaa8`'s report table expected `cap_err_a[0]`, a flop no build has (plan 2.7).
  - Re-judged by the corrected table, 22 of 22 rows match on all three seeds, and every check passes: P29 holds on all three.
  - The second reader made that re-judgement by hand. Since `6477f78` (the final review) `step7_checks.py` makes it from each fit's `firstflops.tsv`: on copies of the c76 fits, Q5 seeds 1-3 give `verdict: PASS` with the tracked tools.
  - Area: 15,799-15,818 ALMs, peak interconnect 59.2-72.2%.
- **The margins of open item 12** (`DARIA_CORE.md`; Q2 seeds 1 / 2 / 3):
  - `t_*_q` → `clk_sdram`: setup +4.298 / +6.697 / +6.338 ns, hold +0.263 / +0.337 / +0.266 ns.
  - The `c_rdata` multicycle into `clk_sys`: setup +70.904 / +68.276 / +68.613 ns against an 87.306 ns relationship; hold +0.795 / +0.784 / +1.000 ns.
  - Flicker Blend's half-period paths: into `fbn_*` +2.462 / +2.683 / +2.969 ns, and `fbn_*` → the pad registers +3.316 / +3.792 / +3.403 ns, both against 8.730 ns; hold at least +8.67 ns.
  - Flicker Blend's half-period paths are `clk_sdram`'s worst on every seed: into `fbn_*` on seeds 1 and 2, and from `fbn_addr` to `fb_cur_d` on seed 3 (+2.919 ns).

### The frame gate, V1 rule (16 images, 1,500 frames)

`tb_frames` ran on the DARIA build with `INPUTS=tb_daria`, at VCO/19, phase 0, against R1. `frame_gate.py --rule v1 --expect-guard unlocked` judged each run.

**All 16 images pass.**
- Each run holds 1,499 of 1,499 frames. `len_sys`, video and RIOT RAM are equal on every frame.
- Every call's ARM instruction count equals R1's.
- Every status line shows 0 halts, 0 PSRAM violations, the guard unlocked and 0 unlocks.
- Call counts and late calls equal R1's: 16 late on Spiders, at the overrun frames 557-572, and 0 elsewhere.
- Frame 1's video was excused on Wizard of Wor, Zaxxon and Zoo Keeper, each by the rule's frame-0 call.

Audio is counted, not gated (plan 7.4 asks for the numbers per image):

| Image | Calls | Frames with audio differing | `release_shift` runs (frames) | Other runs (frames) |
|---|---|---|---|---|
| Elevator Agent | 2,999 | 0 | — | — |
| Galagon | 2,999 | 277 | 30 (75) | 49 (202) |
| Gorf | 2,999 | 697 | 11 (31) | 26 (666) |
| Lady Bug | 2,999 | 56 | 13 (31) | 8 (25) |
| Mappy | 2,999 | 492 | 4 (12) | 64 (480) |
| Qyx | 2,999 | 713 | 11 (27) | 85 (686) |
| RobotWar 2684 | 2,999 | 860 | 5 (9) | 70 (851) |
| Scramble | 2,086 | 883 | 0 | 28 (883) |
| Spiders | 2,999, 16 late | 544, and 1 in the excused overrun frames | 12 (40) | 94 (504) |
| Stratovox | 1,094 | 11 | 0 | 1 (11) |
| Super Cobra | 2,999 | 946 | 4 (17) | 81 (929) |
| Turbo | 2,999 | 635 | 7 (26) | 86 (609) |
| Tutankham | 2,999 | 688 | 17 (34) | 42 (654) |
| Wizard of Wor | 3,003 | 794 | 13 (31) | 118 (763) |
| Zaxxon | 2,999 | 1,025 | 4 (9) | 6 (1,016) |
| Zoo Keeper | 2,999 | 307 | 21 (48) | 42 (259) |
| **All 16** | | **8,928 of 23,984 (37.2%)** | **152 (390)** | **800 (8,538)** |

- **The differences are timing, not content.** On Gorf the owner listened to 25 s of both and judged the audio "a hair out of sync for the most part". Writes after a call land earlier on DARIA, and the CDF music tick runs at another phase (`progress.md`, "Audio against a real Harmony").
- **Against a real Harmony** (a model of the LPC2103's MAM): on Gorf's own settings DARIA's calls run 5.6% faster than the real cartridge and upstream's 7.6% slower.
- **What V1 does not prove:** under V1 the frame gate is no evidence of audio-path correctness. `daria_fe`'s audio is checked access by access against upstream in mode A and mode B (step 6, `DARIA_CORE.md`, "Step 6 work"; and mode B below).

### Mode B at VCO/19

All 19 runs pass at `+d_div=19`.
- **The runs:** 10 with the wrapper (the six images of the halt's record, plus Galagon and Spiders at the two other lattice phases) and the nine of `G_modeB.md` without it.
- **The calls:** every call equals upstream's (0 differ, 0 skipped), with 0 front-end failures, and every audio read is checked against the RAM at the read.
- **The guard** never locked, as expected at ÷19.
- **Spiders** has its 16 late calls at every phase, with the worst slack −1,776 `clk_sys`.
- **The frames:** the seven 600-frame wrapper runs equal R1 on frames 1-599. In mode B the console runs upstream's ARM with DARIA beside it, so this checks the bench, not DARIA's frames.

**Shared-edge pairs** are a DARIA store and a front-end read of the same cart RAM word less than 69.84 ns apart. Every one is a front-end audio read during a DARIA call; there are no write-load or write-write pairs. The bench's 0-period bins equal its coincidence counters, and no distance falls off the lattice.

| Run (frames) | Pairs | At 0 / 1 / 2 VCO periods (under 3 ns) | At 3-6 | Over 6 | Stores that changed the word |
|---|---|---|---|---|---|
| Galagon, phase 0 (600) | 8 | 0 / 1 / 0 | 2 | 5 | 3: the 1-period pair and 2 over 6 |
| Galagon, 8,730 ps (600) | 6 | 0 / 0 / 1 | 0 | 5 | 3: the 2-period pair and 2 over 6 |
| Galagon, 17,460 ps (600) | 8 | 0 / 0 / 0 | 2 | 6 | 3: both at 3-6 and 1 over 6 |
| Mappy (600) | 22 | 1 / 0 / 1 | 3 | 17 | 2, both over 6 |
| draconian RC8 (300) | 2 | 0 / 0 / 0 | 0 | 2 | 0 |
| SF2fix, Turbo (300); Spiders at three phases (600) | 0 | — | — | — | — |
| Without the wrapper: Galagon at three phases (300 each); draconian (300) | 1 each; 2 | none under 3 ns | 0 | all | 0 |
| Without the wrapper: SF2fix at three phases, Dino Eggs, Elevator Agent (300) | 0 | — | — | — | — |

- **The phase-0 wrapper runs repeat the halt's record bin for bin:** Galagon 8, Mappy 22, draconian 2, none elsewhere. The near pairs are the same three:
  - Galagon's at 1 period (1.46 ns), whose store changed the word;
  - Mappy's at 0 and 2 periods, each a store of 0 over 0.
- **The phase runs add one near pair:** Galagon at 8,730 ps, at 2 periods (2.91 ns), whose store also changed the word.
- **Galagon's word-changing pairs come from three stores** (frames 441, 560 and 573), which change the word at every phase. The phase decides only which of them, if any, falls within 3 ns of a read. In the bench the read took the old value when it came first (phase 0, frame 573) and the new value when the store came first (8,730 ps, frame 560).
- **Over all 19 runs** (7,800 frames, about 130 s of play) there are 4 near pairs. 2 of them changed the word, both on Galagon. On hardware each is the counted race of `DARIA_CORE.md`'s open item 7, accepted for V1.

### What c76 does not cover

- **`tb_frames` on SF2fix and draconian RC8** (600 frames against R1, plan 7.3's last item) was not run on the shipping tree. Galagon and Turbo are covered by their 1,500-frame runs above. c77 ran both on 2026-10-16, and both pass (`progress.md`, "The final review and c77 (2026-10-16)").
- **R2's phase runs** (plan 7.4: Galagon and Spiders in `tb_frames` at the two other lattice phases, 600 frames) were not run. The mode-B runs at those phases check every call and audio read against upstream, but say nothing about DARIA's frames. c77 ran all four, and all pass. At ÷19 the three phases cover 3 of the lattice's 19 alignments, and every call but the first starts on one of 5 of them (`progress.md`, "The final review and c77 (2026-10-16)").
- **No single gate run at the head** covered `tb_wire`'s current bench or the current selftest. c76 and rounds 3 and 4 covered them together, and c77's `wire` gate at `356cea9` passed 96 of 96 scenarios and caught 7 of 7 mutants. c78 ran both at `843830e` (below). `selftest` ran as one gate call. `wire` ran in pieces, judged as a union, and included its 97th scenario, `pal2600_a78` (`82d05f1`).
- **Plan 7.7's fresh-clone run** was owed; c78 ran it (below).

## After c76: the final review (2026-10-16)

A whole-branch review of `356cea9` found 34 findings, and a second reader checked each one. The tools findings are fixed in `sim/`, with no change to `src/`:
- **`step7_checks.py`** judges (c.cells) again from `firstflops.tsv` (`6477f78`). (c) and (h.retime) fail on a fit report without its Fitter Netlist Optimizations table.
- **The fit driver's self-test** needs 100 MB free, not 2,100 MB.
- **`step7_gates.sh`** (`95c3352`):
  - the frames gate's default is the 16 images above, and a shorter list is PARTIAL;
  - the selftest gate names the inputs it lacked and is PARTIAL without them;
  - an unknown gate name exits 2.
- **`hygiene.sh`** fails a name list that holds no name (`5e1badb`).
- **`run_dbgsnap.sh`** counts a mutation run that ends without its verdict as an ERROR, not a catch (`ce14cc0`).
- **`frame_gate.py --auto`** compares an ARM image whose R1 run makes no call strictly (`3344b92`).
- **`selftest.py`** runs `step7_gates.sh` itself against stand-ins (`f3a9b49`).
- **`frame_gate.py --auto`** prints one verdict line (`5676558`, the re-review of `51b2927`). On the strict paths it printed "FRAME_GATE pass (identical)" before its FAIL line when the frames matched but the calls or the status line failed. The exit codes were right and are unchanged. `selftest.py` now holds every `--auto` case to one verdict line that agrees with its exit status.

The re-runs after those fixes:
- `selftest.py` with c76's inputs: 267 of 267 cases as expected; 268 of 268 after `5676558`, where 4 cases are WRONG against the old `frame_gate.py`.
- `fit_selftest`: 117 of 117.
- `frame_gate.py --rule v1` on c76's 16 runs: 16 of 16 pass, each report byte-identical to c76's, before and after `5676558`.
- `run_dbgsnap.sh`: 7 of 7 mutations caught as in c76. A planted `%Fatal` is reported as an ERROR and fails the run.
- `step7_checks.py` on every c76 fit: the verdicts in the table above.

**RTL-1** is the one behavioural finding. It is accepted for 2.2.1 (`DARIA_CORE.md`, open item 20). `tb_wire`'s scenario `pal2600_a78` pins it on both builds (`82d05f1`, run at `f3a9b49`, DARIA binary md5 `dbf97f17…` as in round 3):
- **DARIA build:** retunes to PAL at 955.036 ms, to NTSC at 1,005.606 ms and to PAL again at 1,005.636 ms, then releases the A78's console at 1,005.667 ms. It ends with `is_pal` 1, `b2b` 0, `rgn_bad` 0 and `f6_pend` 0.
- **Plain build:** one retune, to PAL at 955.036 ms. It releases the A78 at 1,005.605 ms and ends with `is_pal` 1.

The other `src/` findings are listed under "After 2.2.1" below.

Two documentation findings were left to the merge into DARIA-dev, and were done there:
- linking `docs/IMPROVEMENTS.md` from `DEVELOPING.md` (DOC-7);
- reconciling `ENVIRONMENT.md` 8.4's VM restarts with DARIA-dev's later explanation (DOC-8).

## Plan 7.7's fresh-clone run: c78 (2026-10-16 to 10-17)

c78 ran `sim/step7_gates.sh`'s 15 gates on a new clone of DARIA-dev at `843830e`, whose `src/` is `317eaa8`'s, from 2026-10-16 08:15 to 10-17 13:04 UTC. The clone stayed clean and has no `sim/work/fixb/`. The firmware was linked into its gitignored path; the game images, BIOS and references came by path from the main checkout's and the base worktree's gitignored `sim/work/`.

**Every gate passes, and the frames gate's 16 pieces cover all 16 images.** By the lead's rule for this run (2026-10-16), a gate run in pieces passes when its pieces cover it and each passes, as c76's `s4` jobs did; under that rule c78 is plan 7.7's pass. A second reader re-derived every verdict and confirmed all 15. The full record is in `progress.md`, "Plan 7.7's fresh-clone run, c78"; the logs are in the D worktree's gitignored `sim/work/step7/fix/fix/c78/`.

**Why in pieces.** One call runs the gates in turn, and c78's pieces took about 70 h of run time: the 16 frame runs 2.1-2.2 h each, the `s4` jobs 16.3 h, `extra_tests`' halves 6.8 and 5.0 h. Sessions end after 2-13 h (`docs/AGENT_RUNS.md` section 2). So it ran as 45 resumable pieces: 29 exit 0, and the 16 frame pieces exit 3, PARTIAL alone.

| Gate | Result | Against c76 and c77 |
|---|---|---|
| the six static gates, one call | PASS: hygiene over `aeee6d2..843830e`, 89 files; stream `9b9e7e5e…`, 0 `daria` tokens; 4 guards, 0 findings; 11 defaults at VCO/19; no lint warning added; 117 of 117 | logs equal c76's but headers and paths, hygiene aside (c76: `70a63ca..317eaa8`, 43 files); `fit_selftest` as the final review's re-run |
| `run_sim` | PASS: the DARIA section's 391, 1 and 112 calls, 0 halts; 21 fingerprint cases identical, DARIA against plain | `.out` files equal but paths and md5 |
| `cartram` | PASS: 21 matrix cases, s19 at most, 14 reset cases, both mutants CAUGHT, 20 fingerprints identical | equal but paths, md5, HEAD, date |
| `extra_tests`, `AR_TAPE=1` | PASS: both halves exit 0 and pass the checks; 37 fingerprints identical | equal but paths, md5 and the plain half's own `tb_cartram` build |
| `selftest` | PASS: 268 of 268 | as the nits round's re-run |
| `s4_check` | PASS: 28 of 28 per set, 0 PSRAM violations, "snap: ok" in all 19 DARIA runs | all 56 job outputs equal, normalised |
| `wire` | PASS: 97 of 97 scenarios, 7 of 7 mutants CAUGHT; `pal2600_a78` as `DARIA_CORE.md`'s open item 20 | c77's 96: all 26 counters equal |
| `daria_smp`, `dbg_snap` | PASS: 18 runs, 8 of 8 mutants; 32 runs, 7 of 7 mutations | result lines equal |
| `frames` | PASS (16 pieces): 1,499 of 1,499 frames each; every call's ARM count equal to R1's; audio on 8,928 frames, counted | all 80 CSVs byte-equal |

**Deviations from plan 7.7:** no single call that exits 0; `s4_check` per job (`ONLY=`, `JOBS=1`), so its verdict line and log header (P23) were never written; `wire` as one build, 8 scenario groups and a piece per mutant, judged as a union by `wire_judge.py`, written for c78; `extra_tests`' two halves in parallel (c76 ran them in turn), with dasm, 7800basic and MiSTer's firmware from a cache, as c76 did (`sim/extra_tests.sh:47,78,82,166`); the frames one image per call. The chain restarted after the stops at 09:16 and 12:28 on 10-16 and the driver change at 09:28; the 12:28 stop cut a whole `wire` run.

**What c78 does not show:** `step7_gates.sh` running all 15 gates in one process and exiting 0; the frames gate's default list; the `s4_check`, `wire` and `extra_tests` gate functions as written (`g_s4_check` has not run whole since it took `ARM19=1` in `b177e64`); and that the gates need only the firmware and the game images, since `extra_tests` also needs network access or that cache.

## Step 7's done-when, item by item (as amended for V1)

1. **`run_sim.sh`, `extra_tests.sh` and `s4/check.sh` pass:** yes, on both builds, `AR_TAPE=1` included (c76, and again in c78).
2. **The RAM mappers pass with Fix B's added latency:** yes. The cartram matrix passes on 8 mappers × Flicker Blend, and the directed s19 run passes at s19, never above (c76 and c78).
3. **The 15 demos, and Stratovox, under the V1 rule:** yes, 16 of 16 (c76 and c78). Audio is documented per image above.
4. **`clk_sdram` ≥ +1.5 ns on three seeds:** yes: +2.462 / +2.683 / +2.919 ns, and hold positive at every corner.

**Step 7 is done for V1** (2026-10-17). Every item above holds on the verified tree, `317eaa8`'s `src/` (c76). On 2026-10-16 c77 ran plan 7.3's and 7.4's items under "What c76 does not cover", and one `wire` gate at `356cea9` (96 scenarios, before `pal2600_a78` was added); all pass (`progress.md`, "The final review and c77 (2026-10-16)"). c78, plan 7.7's fresh-clone run, passes every gate as the union of its pieces (above). At step 7's close, what remained for 2.2.1 was step 8, the hardware tests of plan section 9 (below), and the release. Step 8 has since run, and is closed for 2.2.1 ("Hand-over to step 8").

## Hand-over to step 8

Plan section 9, corrected for ÷19 at the final review. At step 7's close (2026-10-17), step 8 (its done-when, `DARIA_CORE.md`'s "Steps" item 8, and this list) and the release remained for 2.2.1. Step 8 has since run and is closed for 2.2.1; its results follow.

**Step 8's results (2026-10-17).** The owner tested daria-test1 on a Pocket. The report is a verdict on the whole checklist, not per item: "everything looks good, tested the library and played the games" (`progress.md`, "Step 8: hardware tests of daria-test1 (2026-10-17)"). On that verdict step 8's done-when holds. The owner's call, the same day: "package the core unchanged and then do the pull request. prepare the release notes as well". So step 8 is closed for 2.2.1 without the PAL region items and the overlay, which are deferred to `docs/IMPROVEMENTS.md` (`DARIA_CORE.md`, "Steps" item 8). A dated note under each item below gives what the report says on it.

- **Fix B on hardware:**
  - Fix A's list, plus a Superchip game, an E7, a 3E and a CV title;
  - a Supercharger multiload end to end, and the tape path (`AR_TAPE`).
  - *2026-10-17, step 8:* covered only by the owner's whole verdict. The report names none of these titles or schemes.
- **PSRAM at 36.17 MHz with `CLOCK_SPEED` 50.0** (`DARIA_CORE.md`, open item 10):
  - the BupChip's ARSC readback;
  - Turbo, which reads beyond the 64 KB window through the cache;
  - plan 5.4 (o)'s I/O figures for reference.
  - *2026-10-17, step 8:* covered only by the owner's whole verdict. The report does not name Turbo or the BupChip.
- **The shipped `SEED` 2** and its Q2 reports. Test builds with `BUP_DEBUG` use Q5's seeds (all three pass).
  - *2026-10-17, step 8:* the test builds were `SEED` 2. The report does not say which one was used. 2.2.1 ships a new fit, the AtariVox build's own `SEED` 2, not Q2's (`DARIA_CORE.md`, "Steps" item 9).
- **The guard on real clocks:** the overlay shows `dbg_locked` and an unlock count (P22).
  - Expected at ÷19: `dbg_locked` 0 and 0 unlocks at all times, after power-up and after every retune. That confirms the guard is inert, as in every mode-B run at ÷19.
  - Any lock is a finding to investigate.
  - The plan's ÷18 expectation ("locked after power-up and after every retune") no longer applies. At ÷19 the guard cannot confirm that C0 and C3 rise together on silicon; that stays an STA assumption.
  - *2026-10-17, step 8:* **not tested.** The overlay was not built (P16, P22).
- **A PAL 2600 ARM image on Auto region** (Stay Frosty 2's PAL build, for one): one retune soon after the start, one F6 after it, and the game restarting in PAL. No retune residual is left to look for: a manual region change within 0.6 ms of a load is closed by `f2c305e`.
  - *2026-10-17, step 8:* **not completed** (checklist D1). The PAL versions the owner has all seem to be PAL60 builds. A PAL60 build draws 262-line frames, which Region Auto treats as NTSC; Stay Frosty 2's PAL build is one. Covered by simulation only: `tb_wire`'s `pal_dpc` and the `seq_*` scenarios, `seq_tia_dpc` with `pal_dpc`'s image.
- **A PAL A78 after a PAL 2600 image on Auto region** (`DARIA_CORE.md`, open item 20): two more retunes than the plain build, ending in PAL.
  - *2026-10-17, step 8:* **not completed** (checklist D2, which used D1's image). Covered by simulation only: `pal2600_a78`. It needs no ARM image: that scenario's first image is a plain PAL 2600 program.
- **The counted classes expected on hardware:**
  - the per-image audio differences above;
  - `merge_race`, and design 9.5's classes;
  - Spiders' 16 late calls in its overrun frames;
  - the rare audio-read coincidences of `DARIA_CORE.md`'s open item 7.
  - *2026-10-17, step 8:* the owner sees Spiders' late calls as the whole picture shifting down for a couple of frames before a level loads. Play does not seem to be affected: the owner beat a couple of levels, and the game kept working. The owner checked the sound against YouTube captures of the games, to make sure it was not too noisy ("had to refer back to youtube captures to ensure that what I was hearing was not too noisy"). The report gives no click count (checklist G4). `merge_race` and design 9.5's classes cannot be seen on hardware.
- **`daria_smp`'s upset exposure:** `pend` and `fl` are never reset, so an upset that leaves `fl` at 1 with no read in flight would hold the asset read port until power-down. This is recorded, not hardened.
  - *2026-10-17, step 8:* nothing to test on hardware, and the report says nothing on it. It stays recorded, not hardened.
- **The late-call source** (plan 6.2 question 5) and the call counter from `call_tog`, both under `BUP_DEBUG` only. A change seen only under `BUP_DEBUG` re-runs only Q5 and `s4/check.sh` (plan 7.6).
  - *2026-10-17, step 8:* **not tested.** The overlay was not built (P16, P22).

## After 2.2.1: `src/` clean-ups

The owner froze `src/` as verified for 2.2.1 (2026-10-16). These findings change only `src/` and are deferred to the first change after 2.2.1. A comment-only change needs plan 7.6's proof: the same `pp_equiv` hashes on both macro sets, and an SDC or qsf diff that is empty with comments stripped. Any other change re-runs the gates 7.6 names. `docs/IMPROVEMENTS.md`, "After 2.2.1: RTL-1 and the `src/` clean-ups", mirrors this list in short. The line numbers below are `317eaa8`'s. In 2.2.1 the AtariVox voice adds lines above them: 10 in `atari7800_pocket.sv`, 4 in `ap_core.qsf` and 3 in `core_top.v`.

1. **RTL-1** (`DARIA_CORE.md`, open item 20): the freeze of `region_pll` in `atari7800_pocket.sv:1037`. The fix is sketched there; `pal2600_a78`'s expected DARIA count then drops to 0. *Done (2026-10-21) in `5ad0a6b`*, in a narrower form than the sketch (only while an A78's 128-byte header downloads); `pal2600_a78` expects no extra retune.
2. **RTL-2:** in the withdrawal branch (`atari7800_pocket.sv:1032-1036`), `region_pll <= daria_rgn` uses `daria_rgn`'s old value on the clock where `daria_rgn` updates. `region_pll` then holds the previous region for one `clk_sys`.
   - A unit bench started a retune just before a 70-byte 2600 download. With allcomplete 760-792 `clk_74a` after the request, the DARIA build made 3 retunes instead of 1; the plain build made 1 at every distance. No real image is that short: a 2600 image is at least 2 KB, an ARM image at least 24 KB.
   - The fix: `region_pll <= (daria_rt_cnt == 4'd15) ? region_pll : daria_rgn;`, or compute `daria_rgn`'s next value once. The comments at `:1004-1006` and `:1016-1018` say this cannot happen.
   - *Done (2026-10-21) in `5ad0a6b`:* the withdrawal takes `daria_rgn`'s next value (`daria_rgn_nx`).
3. **RTL-3, C3 and DOC-11** (one line): `core_constraints.sdc:15-17` says that with DARIA `clk_arm`'s edges meet `clk_sys`'s "only every 3 `clk_sys`". That is VCO/18's lattice. At VCO/19 they meet every 19 `clk_sys` (48 `clk_arm`), as `daria_constraints.sdc`, `pll_core.v` and `DEVELOPING.md` say.
4. **C1:** `ap_core.qsf:760-766`, the seed comment, still gives 2.1.1's figures: "79% full", and seeds 1-3 at +0.26, +0.44 and +0.28 ns. It also says a structural fix belongs in `sram_ctrl`; that fix is Fix B, now in. The comment should give:
   - Q2's seeds on the shipping tree: `clk_sdram` +2.462 / +2.683 / +2.919 ns, 15,600-15,625 ALMs (about 85%);
   - the +1.5 ns release gate;
   - why `SEED` 2: the only seed that passed every check as first written.
   - *2.2.1:* the AtariVox voice added its build's seeds after the comment. The 2.1.1 figures and the call for a fix in `sram_ctrl` are still there. The figures to give are now the AtariVox build's, not Q2's.
   - *Done (2026-10-21)* with the release after 2.2.1's seed move to 3 (plan P12): the comment gives that release's Q2, seeds 1-3 on `ebca01a`, and the gates.
5. **C2:** `daria_sync.tcl:49`, the FORCED mark on `cap_err_a[0]`, matches no build, and Quartus lists it as ignored. Its comment at `:31-34` says the BUP_DEBUG build has the chain; Q5 does not. The fix deletes `:49` and corrects `:31-34`. As a non-comment change to an assignment file, it needs a new Q2 and the smoke test. *Done (2026-10-21) in `dd135dd`* (15 marks); the marks on `pause_a[0]` and `halted_s[0]`, which match no build either, went after the Stage 2 review (13 marks).
6. **`core_top.v:1040`:** the audio comment says the mix is "box filtered down to ~48 kHz (298 clk_sys samples per output)". `core/audio_filter.sv` averages 256 samples, about 55.9 kHz. *Done (2026-10-21)* with item 4.
7. **`pll_core.v:39-41`:** the comment says the C3 = 19 display strings are "one digit lower". Only C0 and C2's differ by one in the last digit; C1's differs by 2 and the VCO's by 43 (DOC-15).
8. **`src/fpga/mister/POCKET_CHANGES.md`** (DOC-13):
   - Its summary (`:21-24`) counts eight modified upstream files. There are eleven: it leaves out `TIA.sv`, `bram.v` and `Pokey/pokey_adapter.sv`, which its own sections describe.
   - It says the POKEY is "swapped for an older one". Since 2.0.21 the build uses upstream's `rtl/Pokey/` with a changed adapter.
   - Its "Updating" list (`:281-286`) re-applies only six files. `DEVELOPING.md`'s "Update the MiSTer core" gives all eleven until this is fixed.
   - *Done (2026-10-21) in `5febe80`:* eleven files, the POKEY sentence, and an "Updating" list that names all eleven.
