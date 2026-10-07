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

## Status (2026-10-07)

- Specs, design and stage-0 bench: done.
- **The owner chose the exact audio** (2026-10-07; `docs/DARIA_CORE.md`, decision 9): `design.md` 5.1, about 1,350 ALMs for the front end, which lands the device on the 84% gate. DARIA is meant as the 7800 core's last major revision, so spare area matters only as far as routing and timing closure need it: the 84% gate is a guide, and step 7's fit decides. If the exact audio causes trouble later, the lean audio (`daria_fe_audio_lean`, the same ports, about 250 ALMs less, AMPLITUDE may lag one tick, counted) is the way back.
- Step 0 of `design.md` 12.2 (the interfaces frozen as stubs, `interfaces.md`): done, and independently reviewed (`interfaces.md` section 11: fixes R-1 … R-4, questions L-1 … L-6 for the lead). Any port change from here needs the lead's sign-off.
- Next: build the modules and their unit benches (five lanes), then mode A on three images, then all 21 (`design.md` 12).

The specs mention a few files that lived only in the session scratchpad and were not kept: a copy of MiSTer's `Atari7800.sv` wrapper, two throwaway stall benches, and a Stella `CartCDF.cxx` used for behaviour notes only.
