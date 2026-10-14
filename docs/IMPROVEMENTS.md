# Possible improvements for later

Ideas that are worth doing but are not needed for the release they were found in. Each entry says what it would fix, what it would cost, and where the evidence is. An entry moves into a plan when the owner picks it.

## DARIA (2600 ARM cartridges)

### A shared-edge guard that works at ÷19

*Added 2026-10-14, by the owner's decision, for a release after 2.2.1.*

Terms: `clk_sys` is VCO/48 (14.32 MHz), the console's clock; `clk_arm` is DARIA's clock, VCO/19 (36.17 MHz) in the first DARIA release, 2.2.1. One VCO period is 1.455 ns. Mode B is the bench that runs DARIA's own CPU against upstream at the real clock ratio.

- **What it would fix.**
  - At ÷19 the front end's guard never locks. So a front-end read of cart RAM can land within a few nanoseconds of a DARIA store to the same word in the dual-clock M10K.
  - In mode B at ÷19, about 45 s of play (2,700 frames) over six images gave three such pairs within 3 ns. Only Galagon's, at one VCO period, changed the word being read. All three were front-end audio reads during a call. A second reader's recount agrees on every count (`docs/daria_step7/progress.md`, "Halt"; the D branch's plan, risk row 5a). Longer play will also meet changing pairs at 0 and 2 periods.
  - At worst such a read returns a wrong value on the bytes being written: a wrong audio sample, or, for a note or pointer read, a wrong value until its next refresh.
  - At ÷18 none can occur. The guard keeps front-end reads off the shared edge, and every other `clk_sys` edge is 8.73 ns from a `clk_arm` edge (`docs/DARIA_CORE.md`, open item 7; `docs/daria_fe/design.md` 8.1).
- **Why today's guard cannot do it.**
  - At ÷18 the clocks share an edge every 3 `clk_sys`, so the guard locks to a period-3 pattern and reads on the safe edge (`docs/daria_fe/design.md` 8.1, 8.3).
  - At ÷19 the pattern repeats only every 19 `clk_sys`. The `clk_sys` edges fall at every whole number of VCO periods from a `clk_arm` edge, from 0 (a shared edge, once in 19 `clk_sys`) to 9.
- **How it could work.** This is a lattice calculation of 2026-10-14, checked by a second reader; it is not yet a design.
  - **The pattern.** The detector's samples form a 19-step pattern. It alternates except for one pair of equal samples, the marker, and all 19 of its rotations differ, so a 19-state flywheel can find the phase.
  - **The near edges.** The `clk_sys` edges within 2, 3 or 4 VCO periods of a `clk_arm` edge (5, 7 or 9 of 19) are never two in a row.
  - **The first catch: the detector's own delay.** Where the detector places the `clk_arm` edges moves one-for-one, in whole VCO periods, with its own path's effective delay (data delay minus clock skew). In the ÷19 fits that delay runs from about 1.3 ns at the fast 0 °C corner to 5.5-5.9 ns at the slow 85 °C corner. That is five possible placements, up to ±2 periods from the middle.
  - **What the mask then costs.** Masking ±4 periods (9 of 19 edges) keeps every read at least 3 periods (4.37 ns) from a `clk_arm` edge, and a read never waits more than one `clk_sys`. A 10-period band allows a wait of two, as at ÷18 (design 3.5 budgets 0-2 clocks per read). A symmetric ±5 band would put four masked edges in a row.
  - **Whether the margin is enough** depends on the M10K's mixed-clock read-during-write window. Intel's handbook calls such a read unknown without giving the window's width, as far as the record shows (`docs/DARIA_CORE.md`, open item 7).
  - **The second catch: drift.** The pattern changes whenever the effective delay crosses a whole VCO period. It crosses 3-4 such boundaries between corners, so as the chip warms the marker jumps, and near a boundary one sample in 19 is unreliable. Today's lock rule (unlock on the first mismatch, relock after 12 matches) would drop out at each crossing. A ÷19 guard needs a lock rule that tolerates this, and a way to re-place the mask when the marker moves.
- **Cost** (an estimate). A design study with a lattice simulation like the hardware judge's scratch `det.py` (`docs/daria_fe/design.md` 8.1; not kept in the repository). New guard and arbiter RTL with its unit bench. Mode B at ÷19, expecting no near pairs. Then `docs/daria_step7/plan.md` 7.6's reruns, including seven fits (Q2 and Q5 on seeds 1-3, and Q-mut): about a day of fits, plus the simulation gates.
- **When.** After hardware tests, especially if Galagon or Mappy show audio clicks.

### Smaller items

- **S3, the faster CPU pipeline.** It would end Spiders' 16 late calls at the start of play, the same calls upstream misses. Cost: a new pipeline, 150-560 ALMs (`docs/DARIA_CORE.md`, open item 3; "stays a later revision").
- **The C flag after a Thumb MUL** is marked unknown and halts with code 8 if read. Revisit if a game ever halts with code 8 (`docs/DARIA_CORE.md`, open item 4).
- **Code or LDM above the 64 KB window** halts (codes 4 and 7). A fetch stall in front of `rom_q` would run it, if a larger CDFJ+ game needs it (`docs/DARIA_CORE.md`, open item 5).
- **Thumb hi-register forms with H1 = H2 = 0** halt. Running them is free if a game needs it (`docs/DARIA_CORE.md`, open item 14).
- **Audio in the frame gate.**
  - The V1 rule counts audio differences instead of gating them, so it is no evidence that the audio path is right. A planted fault in the DPC+ mixer passes it (the D branch's plan, P13 and 7.4).
  - An aligned run gates audio too: each call's release is held to the reference run's, and the music tick's phase is matched. It exists only as a scratch bench tap.
  - It is shown at ÷18 for Galagon (599 frames) and SF2fix's DPC+ music (29 frames), not yet at ÷19, for CDF music or for the other images (`docs/daria_step7/progress.md`, "Frame runs on D against R1").
  - Cost: two bench options and one more run per image.

## The 7800 core (both builds: with and without DARIA)

- **A PAL 2600 game's picture window after its one retune.**
  - The retune's reset clears the TIA's region measurement (`TIA.sv:1708`). So the game is shown in the NTSC window at the PAL clock for about 0.96 s, until the TIA decides again (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
  - A suggestion, untested: start the TIA's `pal_mode` after the reset from the wrapper's `tia_pal_seen` latch. That changes upstream's `TIA.sv`.
- **A Sega Genesis pad for 2600 games.** The Pocket reads a 2600 image's paddle inputs as 0 with a joystick, as a real 2600 does, so Genesis-aware games (Galagon, SF2fix, Turbo) start in single-button mode. A "Genesis pad" Port Input option would let them offer their second-button functions. It would present INPT1 (port 1) and INPT3 (port 2) high while a mapped second button is released, and low while it is pressed. It would change every 2600 game that reads those inputs (`docs/daria_step7/progress.md`, "Frame runs on D against R1").
- **An A78 image the BIOS drops into 2600 mode** is not covered by the region hold, and could loop between regions if its 2600-mode video measured PAL against an NTSC header. It is not simulated, and main's 2.1.3 has the same exposure (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
