# Possible improvements for later

Ideas that are worth doing but are not needed for the release they were found in. Each entry says what it would fix, what it would cost, and where the evidence is. An entry moves into a plan when the owner picks it.

## DARIA (2600 ARM cartridges)

### A shared-edge guard that works at ÷19

*Added 2026-10-14, by the owner's decision; candidate for 2.2.2.*

- **What it would fix.** At ÷19 (36.17 MHz, the divider chosen for V1) the front end's guard never locks, so a front-end read of cart RAM can land within a few nanoseconds of a DARIA store to the same word, in the dual-clock M10K. In mode B at ÷19, about 40 s of play over six games gave three such pairs within 3 ns; one changed the stored value, and all were front-end audio reads. The worst effect is an occasional wrong audio sample, and none if the M10K does not race at 1.455 ns. At ÷18 the guard prevented all of them (`docs/daria_step7/progress.md`, "Halt" and "Mode B at ÷19").
- **Why today's guard cannot do it.** At ÷18 the clocks share an edge every 3 `clk_sys`, and every other `clk_sys` edge is at least 8.73 ns from a `clk_arm` edge, so the guard locks to a period-3 pattern and reads on the safe edge (`docs/daria_fe/design.md` 8.1, 8.3). At ÷19 the pattern repeats only every 19 `clk_sys`, and the `clk_sys` edges fall at every distance from a `clk_arm` edge, down to one VCO period (1.455 ns).
- **How it could work** (a lattice calculation, 2026-10-14; not yet a design):
  - The detector's samples form a 19-step pattern with a single marker, and all 19 of its rotations differ, so a 19-state flywheel can lock to it.
  - The `clk_sys` edges within 2, 3 or 4 VCO periods of a `clk_arm` edge (5, 7 or 9 of 19) are never two in a row, so the front end would wait at most one `clk_sys` for a safe edge.
  - The catch: where the detector places the `clk_arm` edges shifts by about one VCO period per 1.455 ns of its own path delay, which spans about 1.4-4.8 ns across corners and fits. So the guard must mask a wider band, about ±5 periods, and then can wait two `clk_sys`, as at ÷18. The margin it guarantees then depends on the M10K's mixed-clock race window, which Intel does not publish.
- **Cost.** A design study with a lattice simulation like `judge_tmp/det.py`; new guard and arbiter RTL; its unit bench; mode B at ÷19 expecting no near pairs; then plan 7.6's reruns and three new fits. About 2-4 days of machine time.
- **When.** After hardware tests, especially if Galagon or Mappy show audio clicks.

### Smaller items

- **Code or LDM above the 64 KB window** halts (codes 4 and 7). A fetch stall in front of `rom_q` would run it, if a larger CDFJ+ game needs it (`DARIA_CORE.md`, open item 5).
- **Thumb hi-register forms with H1 = H2 = 0** halt. Running them is free if a game needs it (`DARIA_CORE.md`, open item 14).
- **The frame gate's audio.** The V1 rule counts audio differences instead of gating them. An aligned run, with each call's release held to the reference's and the music tick's phase matched, gates audio too. It is shown for Galagon (599 frames) and SF2fix's DPC+ music (29 frames), not yet for CDF music or the other images (`progress.md`, "Frame runs on D against R1").

## The 7800 core (both builds)

- **A PAL 2600 game's picture window after its one retune.** The retune's reset clears the TIA's region measurement, so the game is shown in the NTSC window at the PAL clock for about 0.96 s, until the TIA decides again. Starting the TIA's `pal_mode` from `tia_pal_seen` after the reset would avoid it, but changes upstream's `TIA.sv` (`progress.md`, "Fit Q1' and commit P").
- **A Sega Genesis pad for 2600 games.** The Pocket reads a 2600 image's paddle inputs as 0 with a joystick, as a real 2600 does, so Genesis-aware games (Galagon, SF2fix, Turbo) start in single-button mode. A "Genesis pad" Port Input option, presenting INPT1 and INPT3 as the second button released, would let them offer their second-button functions. It would change every 2600 game that reads those inputs (`progress.md`, "Frame runs on D against R1").
- **An A78 image the BIOS drops into 2600 mode** is not covered by the region hold, and could loop between regions if its 2600-mode video measured PAL against an NTSC header. It is not simulated, and the shipped core has the same exposure (`progress.md`, "Fit Q1' and commit P").
