# Possible improvements for later

Ideas that are worth doing but are not needed for the release they were found in. Each entry says what it would fix, what it would cost, and where the evidence is. An entry moves into a plan when the owner picks it.

## DARIA (2600 ARM cartridges)

### A shared-edge guard that works at ÷19

*Added 2026-10-14, by the owner's decision, for a release after 2.2.1.*

Terms: `clk_sys` is VCO/48 (14.32 MHz), the console's clock; `clk_arm` is DARIA's clock, VCO/19 (36.17 MHz) in the first DARIA release, 2.2.1. One VCO period is 1.455 ns. Mode B is the bench that runs DARIA's own CPU against upstream at the real clock ratio.

- **What it would fix.**
  - At ÷19 the front end's guard never locks. So a front-end read of cart RAM can land within a few nanoseconds of a DARIA store to the same word in the dual-clock M10K.
  - In mode B at ÷19, about 45 s of play (2,700 frames) over six images gave three such pairs within 3 ns. Only Galagon's, at one VCO period, changed the word being read. All three were front-end audio reads during a call. A second reader's recount agrees on every count (`docs/daria_step7/progress.md`, "Halt"; `docs/daria_step7/plan.md`, risk row 5a). Longer play will also meet changing pairs at 0 and 2 periods.
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
  - *2026-10-17:* in step 8's hardware tests the owner checked the sound against YouTube captures of the games, to make sure it was not too noisy. The report gave no click count (`docs/daria_step7/progress.md`, "Step 8: hardware tests of daria-test1 (2026-10-17)").

### The step-8 DARIA status overlay

*Added 2026-10-17, after step 8's hardware tests. Debug-only. It was planned for step 8 but not built, and `src/` is frozen for 2.2.1.*

- **What it would show.** On the debug build, while a 2600 ARM game runs: DARIA's calls and late calls, the guard's lock state and unlock count, and the halt flag, halt code and fault code. Today the debug build's cells appear only for a Souper cartridge, and show only the BupChip.
- **Why.**
  - In step 8's hardware tests the owner could only see Spiders' late calls, as the picture shifting down. The overlay would count them: 16 are expected in the first overrun, about 9 s in. The frame runs do not reach later level loads, which may add more.
  - It would show on silicon that the guard stays unlocked at ÷19, with 0 unlocks after power-up and after every retune. Today only simulation shows it, in mode B at ÷19.
  - A halted ARM game just stops today. The overlay would show why.
- **Cost.** `BUP_DEBUG` code only, so by plan 7.6 it re-runs only Q5 and `s4/check.sh`. Step 7 prepared it (`docs/daria_step7/plan.md` P15, P16 and P22):
  - `daria_fe` exports `dbg_locked` and `dbg_unlock`, which drive nothing in the release build;
  - calls can be counted from `call_tog` in the wrapper, and plan 6.2 question 5 recommends a bus decode for the late-call source (not yet decided or built); neither needs a `daria_fe` port (P22);
  - the halt status already reaches `clk_sys` through two flops (`docs/DARIA_CORE.md`, 7.2, "New DARIA crossings");
  - `bup_dbg_snap.sv`, the snapshot of open item 11, is meant to carry it.
- **Evidence.** `docs/daria_step7/record.md`, "Hand-over to step 8"; `docs/daria_step7/progress.md`, "Step 8: hardware tests of daria-test1 (2026-10-17)".
- **When.** After 2.2.1, with the next debug build.

### The PAL region items on hardware, with a 50 Hz PAL image

*Added 2026-10-17, after step 8's hardware tests.*

- **What it would show.** Step 8's checklist items D1 and D2 on a Pocket:
  - D1: a PAL 2600 ARM image on Region Auto restarts once, about 1 s after loading, then runs in PAL at 50 Hz;
  - D2: a PAL A78 loaded after a PAL 2600 image ends in PAL, with RTL-1's two extra retunes (`docs/DARIA_CORE.md`, open item 20).
- **Why it is not done.** The PAL versions the owner has all seem to be PAL60 builds. A PAL60 build draws 262-line frames, which Region Auto treats as NTSC; Stay Frosty 2's PAL build is one (`docs/DARIA_CORE.md`, "The added images"). So neither item could be completed in step 8 (`docs/daria_step7/progress.md`, "Step 8: hardware tests of daria-test1 (2026-10-17)").
- **What covers them today.** Simulation only: `tb_wire`'s `pal_dpc`, `pal2600`, `pal2600_a78` and `seq_*` scenarios (`sim/bupchip/daria/wire/wire.py`). All pass in c78's `wire` gate (`docs/daria_step7/record.md`, "Plan 7.7's fresh-clone run: c78").
- **What it needs.**
  - For D1, a 2600 ARM image that draws 50 Hz PAL frames (312 lines). A synthetic one made by the project's own scripts would do, as `pal_dpc` is. Like every generated image, it stays out of git.
  - D2 needs no ARM image. `pal2600_a78`'s first image is a plain PAL 2600 program, so any 50 Hz PAL 2600 game followed by a PAL A78 runs it.
- **Cost.** One test session on the build under test. No RTL change.
- **When.** When such an image is at hand.

### Smaller items

- **S3, the faster CPU pipeline.** It would end Spiders' 16 late calls at the start of play, the same calls upstream misses. On hardware the owner sees Spiders' late calls as the picture shifting down for a couple of frames before a level loads, and they do not seem to affect play (step 8, 2026-10-17). Cost: a new pipeline, 150-560 ALMs (`docs/DARIA_CORE.md`, open item 3; "stays a later revision").
- **The C flag after a Thumb MUL** is marked unknown and halts with code 8 if read. Revisit if a game ever halts with code 8 (`docs/DARIA_CORE.md`, open item 4).
- **Code or LDM above the 64 KB window** halts (codes 4 and 7). A fetch stall in front of `rom_q` would run it, if a larger CDFJ+ game needs it (`docs/DARIA_CORE.md`, open item 5).
- **A cartridge EEPROM, and the ARM chip's other peripherals.**
  - **The hardware:** a Melody board can carry an optional EEPROM of up to 4 MB, besides up to 128 KB of flash and 64 KB of RAM (the board's description, quoted by the owner on 2026-10-15). Its LPC213x chip has no external memory bus, so a game would reach the EEPROM through the chip's serial peripherals.
  - **What DARIA does today:** it emulates only MAMCR and timer 1. Every other register in the peripheral window reads 0 and drops writes (`docs/DARIA_CORE.md`, M3 and open item 19).
  - **The effect:** a game that used an EEPROM, for saves or for data beyond its ROM, would read zeros and lose what it writes, without halting. No traced image touches these peripherals.
  - **Two smaller points:** DARIA maps images up to 512 KB, although the Pocket's cartridge slot takes files up to 4 MB. And CDFJ+ itself addresses at most 32 KB of cart RAM, all of which DARIA has.
  - **Cost:** model the peripheral that a real game uses (SPI/SSP or I²C) in `daria_mmio`, and back the EEPROM with Pocket memory saved through the core's save files, as the SaveKey and the High Score Cart already are. Size it when such a game exists.
- **Thumb hi-register forms with H1 = H2 = 0** halt. Running them is free if a game needs it (`docs/DARIA_CORE.md`, open item 14).
- **Audio in the frame gate.**
  - The V1 rule counts audio differences instead of gating them, so it is no evidence that the audio path is right. A planted fault in the DPC+ mixer passes it (`docs/daria_step7/plan.md`, P13 and 7.4).
  - An aligned run gates audio too: each call's release is held to the reference run's, and the music tick's phase is matched. It exists only as a scratch bench tap.
  - It is shown at ÷18 for Galagon (599 frames) and SF2fix's DPC+ music (29 frames), not yet at ÷19, for CDF music or for the other images (`docs/daria_step7/progress.md`, "Frame runs on D against R1").
  - Cost: two bench options and one more run per image.

### After 2.2.1: RTL-1 and the `src/` clean-ups

*Added 2026-10-16, from step 7's final review. The owner froze `src/` for 2.2.1 that day, so each item waits for the first `src/` change after the release. The numbers are those of `docs/daria_step7/record.md`, "After 2.2.1: `src/` clean-ups", which has the details and the line numbers.*

1. **RTL-1: a PAL A78 after a PAL 2600 image, Region on Auto** (`docs/DARIA_CORE.md`, open item 20).
   - **What it would fix.** In the DARIA build such an A78 costs two extra retunes, to NTSC and back to PAL, and its console is released 62 µs later than without DARIA. The final region is right. Main and the build without DARIA make no extra retune. The owner accepted it for 2.2.1 as a known minor issue.
   - **Cost.** A few lines in `atari7800_pocket.sv`: let `region_pll` follow the region while an A78 downloads, even with a retune pending. The last few `clk_sys` of a download need checking against the `seq_*` scenarios and the mutants. As a change to DARIA's RTL it re-runs the gates of `docs/daria_step7/plan.md` 7.6, with a new Q2.
   - **Evidence.** `tb_wire`'s scenario `pal2600_a78` runs on both builds and pins the DARIA build's two extra retunes; the build without DARIA makes none. Its expected DARIA count drops to 0 with the fix.
   - **When.** The next revision after 2.2.1.
2. **RTL-2.** During a 2600 download `region_pll` is set back to the region of the last retune. On the clock where a retune completes it takes the old region, for one `clk_sys`. A unit bench saw 3 retunes instead of 1 with a 70-byte download; no real image is that short. Cost: one line, best done with RTL-1.
3. **`core_constraints.sdc`'s comment** gives VCO/18's lattice ("only every 3 `clk_sys`"). At VCO/19 the edges meet every 19 `clk_sys`.
4. **`ap_core.qsf`'s seed comment** gives 2.1.1's margins, before the AtariVox build's seeds that 2.2.1 added, and still asks for a fix in `sram_ctrl` that Fix B made.
5. **`daria_sync.tcl`'s FORCED mark on `cap_err_a[0]`** matches no build, and Quartus lists it as ignored.
6. **`core_top.v`'s audio comment** says 298 samples per output, about 48 kHz. `audio_filter.sv` averages 256, about 55.9 kHz.
7. **`pll_core.v`'s comment** says the VCO/19 display strings are "one digit lower". Only two of the four are.
8. **`src/fpga/mister/POCKET_CHANGES.md`** counts eight modified upstream files where there are eleven, and its "Updating" list re-applies six. Until it is fixed, `docs/DEVELOPING.md`, "Update the MiSTer core", lists all eleven.

- **Cost of items 3-8.** Items 3, 4, 6 and 7 change comments only. They need plan 7.6's proof: the same `pp_equiv` hashes on both macro sets, and an SDC or qsf diff that is empty with comments stripped. Item 5 changes an assignment file, so it needs a new Q2 and the smoke test. Item 8 is a document.
- **When.** Items 1 and 2 in the next revision; the rest with the first `src/` change after 2.2.1.

## The 7800 core (both builds: with and without DARIA)

- **A PAL 2600 game's picture window after its one retune.**
  - The retune's reset clears the TIA's region measurement (`TIA.sv:1708`). So the game is shown in the NTSC window at the PAL clock for about 0.96 s, until the TIA decides again (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
  - A suggestion, untested: start the TIA's `pal_mode` after the reset from the wrapper's `tia_pal_seen` latch. That changes upstream's `TIA.sv`.
- **A Sega Genesis pad for 2600 games.** The Pocket reads a 2600 image's paddle inputs as 0 with a joystick, as a real 2600 does, so Genesis-aware games (Galagon, SF2fix, Turbo) start in single-button mode. A "Genesis pad" Port Input option would let them offer their second-button functions. It would present INPT1 (port 1) and INPT3 (port 2) high while a mapped second button is released, and low while it is pressed. It would change every 2600 game that reads those inputs (`docs/daria_step7/progress.md`, "Frame runs on D against R1").
- **An A78 image the BIOS drops into 2600 mode** is not covered by the region hold, and could loop between regions if its 2600-mode video measured PAL against an NTSC header. It is not simulated, and main's 2.1.3 has the same exposure (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
- **FA2 saves: Star Castle Arcade's high scores.** *Added 2026-10-17, from the owner's finding on the Pocket, for a release after 2.2.1.*
  - **What it would fix.** Star Castle Arcade, an FA2 game, does not keep its high-score saves on the Pocket.
    - The FA2 mapper (`mapper_fa2.sv`) copies its 256-byte work RAM to and from the cartridge's flash through the `fa2_nvram_*` port.
    - The Pocket wrapper leaves that port unconnected (`atari7800_pocket.sv:1233-1239`). Every read returns $FF, as from a blank flash, every request is ready at once, and every write is dropped.
    - On MiSTer, upstream's `fa2_nvram_bridge.sv` connects the port to the core's save RAM. The Pocket build does not use it.
    - The stub dates from the port's first commit (`3043d50`), so every release of this port has it. It is not DARIA's.
  - **Cost.** A 256-byte nonvolatile save slot behind the FA2 port, like `hsc.sav`.
    - `docs/DEVELOPING.md`, "Add a save slot", is the recipe: `save_ram_dp` with its APF read latch, a constant size in the data slot table, the next bridge region (`0x40000000`), a `data.json` slot appended after the others, a new file blank as $FF, and a round trip in `tb_load`.
    - It changes `src/` in both builds. By `docs/daria_step7/plan.md` 7.6 it re-runs `run_sim.sh`, `extra_tests.sh`, `s4/check.sh` and `pp_equiv.py`, and needs a new Q2.
  - **Evidence.** The owner's finding on the Pocket.
  - **When.** After 2.2.1, with the first `src/` change.
