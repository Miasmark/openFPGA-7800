# DARIA step 6: the front end (`daria_fe`)

This directory holds the design of `daria_fe` and the work it rests on. `daria_fe` is DARIA's 6507-side front end for DPC+ and the CDF family (`docs/DARIA_CORE.md`, "Steps", 6).

Everything here was derived from upstream MiSTer's MIT RTL (`src/fpga/mister/rtl/`), this repository's own RTL and benches, and `docs/DARIA_CORE.md`. It contains no game data. Run statistics (counts of latches, calls, ticks) come from simulations whose outputs stay in `sim/work`.

## Files

| File | What it is |
|---|---|
| `design.md` | **The micro-architecture to build.** Modules and ports, cycle contracts, timing per access, port arbitration and the shared-edge guard, state map, audio engine, call side, F6 and copy/fill, phase detector with its SDC lines, quirks and counted differences, area, risks, implementation plan |
| `interfaces.md` | **The interfaces as frozen at step 0** (`design.md` 12.2): every port of `daria_fe` and its submodules as the stubs in `src/fpga/core/bupchip/daria_fe*.sv` have them, the bench tap names and encodings, each decision taken where the design was ambiguous (S0-1 … S0-20), the lint and Quartus results on the stubs, and the shared unit-bench infrastructure (`sim/bupchip/daria/fe_unit/`: `run_unit.sh`, `phase_gen.svh`, `DARIA_RAM_POISON`) |
| `spec/dpcplus.md`, `spec/cdf.md`, `spec/audio.md`, `spec/glue.md`, `spec/bus.md` | Cycle-exact specifications of upstream's front ends: `mapper_dpcplus`; `mapper_cdf` with its tables and fast-jump map; `arm_mapper_audio` and the controller's audio half; RAM init, the call controller and `cart2600`/`detect2600` glue; the 6507 bus and stall timing. Each was written from the RTL, then checked line by line by a second reader |
| `spec/design_inputs.md` | What DARIA's built RTL and design already fix for the front end (ports, call block, clocks, open requirements R1-R16) |
| `spec/bench.md` | The plan for the cycle-by-cycle shadow in `tb_daria` (mode A: beside upstream's front ends; mode B: with DARIA's CPU) |
| `spec/critic.md` | A cross-check of the specs: contradictions, gaps, and the decisions taken before design (D1-D10 in `design.md` follow it) |
| `alternatives/lean.md`, `alternatives/exact.md`, `alternatives/simple.md` | Three independent designs: smallest (shared datapath, state-RAM audio, counted AMPLITUDE lag); most exact (a clock-exact audio clone); easiest to verify (separate engines, one arbiter) |
| `reviews/judge_*.md` | Three reviews of the three designs: exactness and verifiability, hardware (area, timing, ports, guard), implementation risk. Totals: simple 20, lean 20, exact 19. `design.md` is built on simple, with exact's exactness mechanisms and lean's guard and fallback audio grafted in |
| `bench_stage0.md` | Stage 0 of the shadow (`sim/bupchip/daria/fe_shadow.svh`): a reference copy of upstream's front ends driven from the bench's taps matches upstream with 0 differences, and planted faults are caught |

## Status (2026-10-09)

**Step 6 is done in simulation** (2026-10-09; `docs/DARIA_CORE.md`, "Step 6 work", has the per-image table and design 12.5's criteria one by one). What remains moves to the project's step 7 (design 12.2 step 9): the wrapper wiring (1.6), the SDC, the full fit, the STA checks of 8.2 and the guard's check on the real clocks.

- Specs, design and stage-0 bench: done.
- **The owner chose the exact audio** (2026-10-07; `docs/DARIA_CORE.md`, decision 9): `design.md` 5.1, about 1,350 ALMs for the front end, which lands the device on the 84% gate. DARIA is meant as the 7800 core's last major revision, so spare area matters only as far as routing and timing closure need it: the 84% gate is a guide, and step 7's fit decides. If the exact audio causes trouble later, the lean audio (`daria_fe_audio_lean`, the same ports, about 250 ALMs less, AMPLITUDE may lag one tick, counted) is the way back.
- Step 0 of `design.md` 12.2 (the interfaces frozen as stubs, `interfaces.md`): done, and independently reviewed (`interfaces.md` section 11: fixes R-1 … R-4, questions L-1 … L-6 for the lead). Any port change from here needs the lead's sign-off.
- Step 1 (the five lanes, `lanes/*.md`): done. Every block passes its unit bench against upstream's RTL, every lane's planted mutants are caught (A 41, B 64, C 66, D 58).
- Integration (`design.md` 12.2 step 2), 2026-10-08: Verilator `-Wall` clean on the whole front end; `run_unit.sh` 10 of 10. Quartus fits of `daria_fe` alone (5CEBA4F23C8, `ap_core.qsf` settings, virtual pins):

  | Probe | Synthesis estimate | ALMs placed − [B] | ALMs needed | Registers | M10K | Slack `clk_sys` / `clk_arm` |
  |---|---|---|---|---|---|---|
  | `daria_fe` (bench hook live on virtual pins) | 1,737 | 1,389 | 1,732 | 1,097 | 0 | +55.6 / +23.6 ns |
  | `daria_fe_probe` (hook tied 0, as the core will) | 1,667 | 1,490 | 1,728 | 1,099 | 0 | +54.6 / +22.2 ns |

  The hook costs about 70 ALMs in synthesis, but single fits of a block this size vary by more than that in the fitter's packing measure, so the front end is about 1,400-1,500 ALMs against the design's 1,255-1,445. Step 7's full-core fit decides.
- Lane E (2026-10-08): done and verified. The stage-1 shadow (`lanes/E1_shadow.md`), 51 directed tests (`lanes/E2_directed.md`), and the random differential bench at 105 M cycles with 0 failures outside the classes (`lanes/E3_random.md`). Issues and decisions: `lanes/E3_rtl_issues.md`, `lanes/F1_fixes.md`.
- F1 (2026-10-08): lane E's findings decided; `lanes/F1_fixes.md`.
- Mode A on every ARM image (`design.md` 12.2 step 6), finished 2026-10-09: the 15 demos, the six added images and the nine Champ Games Presents images, 1,500 frames each, all PASS with every must-be-0 counter 0 and `a_pend_late` 0. Classes: `merge_amp` 592 (the CDF-family images, no hook), `dig_rom_lag` 5,787 (Boom! and both Draconian builds), `amp_class` 49. The batch ran on a binary built before F1's RTL change; since `a_pend_late` is 0 in all 30 runs, F1's `pclk1` clear never acted, and the runs stand for the final RTL (`docs/DARIA_CORE.md`, "Step 6 work").
- Resets, the BIOS and pause (12.2 step 7), 2026-10-09: seven console-reset runs (one per scheme, two inside a call) and six OpenBIOS runs pass; the BIOS never hands over for DPC+ revision 1 and CDFJ+ on this core, hence decision 11; pause is covered by the directed and random benches, since the Pocket never pauses (decision 10). `lanes/G_step7_resets.md`.
- Mode B (12.2 step 8), 2026-10-09: DARIA's CPU with `daria_fe`, nine runs of 300 frames at the three lattice phases, all pass the gate: the guard locks at the predicted edge (16, 18, 14) and never unlocks, the coincidence counters are 0, and DARIA's 4,620 calls match upstream's. `lanes/G_modeB.md`.
- Not met: the probe gate of 12.2 step 2 (1,300 ALMs; `daria_fe` alone is 1,389-1,490 placed, 1,671 by synthesis after F1). No lever was taken: by the owner's note to 10.3 (decision 9) the gates are guides, and step 7's fit decides.

The specs mention a few files that lived only in the session scratchpad and were not kept: a copy of MiSTer's `Atari7800.sv` wrapper, two throwaway stall benches, and a Stella `CartCDF.cxx` used for behaviour notes only.
