# Possible improvements for later

Ideas that are worth doing but are not needed for the release they were found in. Each entry says what it would fix, what it would cost, and where the evidence is. An entry moves into a plan when the owner picks it.

## DARIA (2600 ARM cartridges)

### The design study after 2.2.1, and the plan it led to

*Added 2026-10-19. The study (2026-10-18) and its follow-up on Spiders are scratch, not in the repository. The plan that takes their items forward is `docs/daria_step10/plan.md`.*

- **Area is not the limit; the CPU clock is.** 2.2.1 needs 15,839 of 18,480 ALMs (85.7%), about 2,755 of them DARIA's. At ÷18, 2.2.1 failed on all three seeds tried: seed 1 on `clk_arm`, seeds 2 and 3 on the guard pair [measured: fits].
- **Two area wins** [measured: fits]:
  - MR, `MUX_RESTRUCTURE ON` on 13 `clk_sys`-domain entities (13 qsf lines, no RTL): 909-918 fewer ALMs at ÷19 on seeds 1-3, with every ÷19 gate passing.
  - `virtual_axis5`, the five virtual axes as one time-shared engine: 409 fewer again on top of MR, 1,318 fewer than 2.2.1 in all (one seed). It staggers the axes' 1 ms update by 0-4 `clk_sys`. It equals five instances with their ticks delayed that way on every clock over 4 × 10^7 random-stimulus clocks (a bench, not a proof).
  - *2026-10-21:* both are in the release tree. MR is `de9a903` (in `DARIA-dev`); `virtual_axis5` is `8a8bddb`, with its bench `tb_vaxis5` in `run_sim.sh` (seeds 1-4 of 10^7 clocks, 0 mismatches) and the whole-core input test (paddles, driving and gun) identical to the tree before it. The release's Q2 measures the area. *Measured (the release's Q2, seeds 1-3 on `ebca01a`):* 14,617-14,628 ALMs (79%); the shipped seed's 14,628 is 1,211 fewer than 2.2.1's 15,839, with every gate and check passing; 216 M10K blocks, against 212 in 2.2.1 and on `09aa7f8`.
- **The clock.** Five restructurings in `bup_cpu.sv` (T2), with the guard pair re-bounded to [0.5, 8.0] ns (G1), meet ÷18 with `clk_arm` +2.298 to +2.464 ns on seeds 1-3 [measured: fits]. They cost the BupChip's firmware 3.1-3.2% more clocks [measured: model].
- **L1W+L3, Spiders' late calls.** One-clock aligned Thumb word loads (L1W), and one clock off Thumb LDMIA and POP (L3). On top of T2 they bring Spiders' worst call at ÷18 from 104.05% to 89.33% of its budget, with 0 of 1,399 calls late [measured: RTL]. Frames 557-572 become normal 262-line frames [measured: whole-core simulation]. The cost is about 30 ALMs over T2 [measured: fits].
- **The hold path.** On one of six seeds the candidate fails a `clk_sdram` hold in `sram_ctrl` by 0.503 ns (`t_wr_q` → `t_last[17]`, two registers in one LAB) [measured: fit]. Rev 0 tries a fix (plan, section 4).
- **What the plan does with the items below.** S3 is no longer needed for Spiders. The ÷19 guard is not needed at ÷18. The overlay and the PAL session are in Rev 0. The aligned audio gate is deferred. MR, `virtual_axis5`, T2 with L1W+L3, RTL-1, the clean-ups and the FA2 saves go into one release at ÷18, the plan's recommendation; the owner decides after Rev 0 (plan, section 6).
  - *2026-10-21:* the owner chose one release at ÷18, landed before the Rev 0 session, which still has to confirm ÷18 on silicon (plan, decisions 2, 3 and 7). MR, `virtual_axis5`, T2 with L1W+L3, RTL-1 and the FA2 saves are now in the release tree (branch `rev1/div18-s2` on top of `DARIA-dev`), and so are the clean-ups except the two that wait for the release's fits ("After 2.2.1", items 4 and 6). The PAL session waits for Rev 0's Pocket session. Each entry below says where it stands.

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
  - *2026-10-19:* not needed at ÷18, where the guard locks. The plan for the next release recommends ÷18 (`docs/daria_step10/plan.md`, decision 3, open until after Rev 0). This item comes back only if ÷18 fails on a Pocket.
  - *2026-10-21:* the release tree is at ÷18 (`09aa7f8`, its own commit so that it can be reverted alone), where the guard locks in simulation. A1 applies only if ÷18 is ever left: if the Pocket session finds the guard does not lock on silicon, the ÷19 fallback brings this item back.

### The step-8 DARIA status overlay

*Added 2026-10-17, after step 8's hardware tests. Debug-only. It was planned for step 8 but not built, and `src/` is frozen for 2.2.1.*

**Done, 2026-10-20 (branch `rev1/overlay`, for the next release; `BUP_DEBUG` builds only).** Built in Rev 0 as A2 (`docs/daria_step10/plan.md`, 3.0 item 1) and landed in `src/` in `0d9ce33`, the overlay as built for the D18 and D19 test builds; its whole-core check was then made to fail when it checks nothing (`5d5d591`). What it draws is in `bup_status_osd.sv`'s header and `docs/BUPCHIP_CORE.md` (the `BUP_DEBUG` row): while a 2600 ARM cartridge runs, the CPU's running and halt state, the guard's lock, the halt and fault codes, late calls, guard unlocks, calls, and the halt PC while halted. `daria_dbg_status` (same file) counts them, with the late-call rule on a copy of the RIOT's timer (`docs/daria_step7/plan.md` 6.2 question 5, answered). The checks: `sim/bupchip/dstat/run_dstat.sh` (the counts against `M6532.sv` and `tb_frames`' rule), `run_sim.sh`'s DARIA section in a `BUP_DEBUG` build and `sim/bupchip/dstat/run_ovl.sh` (every cell read back from the picture, its planted faults caught), and `tb_frames` with `FRAMES_DEBUG=1` on a game; `sim/step7_gates.sh --only dbg_overlay` runs the first two. In simulation, Spiders at ÷19 shows 16 late calls on row 2, as expected [sim]. The hardware readings wait for the owner's session (`docs/daria_step10/plan.md` 3.0 item 5). The text below is the item as written before it was built.

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
  - *2026-10-19:* in Rev 0 (`docs/daria_step10/plan.md` 3.0, item 1). Rev 0's debug test builds carry it from a scratch worktree. It lands in `src/` with the next release.

### The PAL region items on hardware, with a 50 Hz PAL image

*Added 2026-10-17, after step 8's hardware tests.*

- **What it would show.** Step 8's checklist items D1 and D2 on a Pocket:
  - D1: a PAL 2600 ARM image on Region Auto restarts once, about 1 s after loading, then runs in PAL at 50 Hz;
  - D2: a PAL A78 loaded after a PAL 2600 image ends in PAL, with RTL-1's two extra retunes in 2.2.1 (`docs/DARIA_CORE.md`, open item 20). With RTL-1 fixed (`5ad0a6b`, the release after 2.2.1) the release's debug build should retune once, as the build without DARIA does.
- **Why it is not done.** The PAL versions the owner has all seem to be PAL60 builds. A PAL60 build draws 262-line frames, which Region Auto treats as NTSC; Stay Frosty 2's PAL build is one (`docs/DARIA_CORE.md`, "The added images"). So neither item could be completed in step 8 (`docs/daria_step7/progress.md`, "Step 8: hardware tests of daria-test1 (2026-10-17)").
- **What covers them today.** Simulation only: `tb_wire`'s `pal_dpc`, `pal2600`, `pal2600_a78` and `seq_*` scenarios (`sim/bupchip/daria/wire/wire.py`). All pass in c78's `wire` gate (`docs/daria_step7/record.md`, "Plan 7.7's fresh-clone run: c78").
- **What it needs.**
  - For D1, a 2600 ARM image that draws 50 Hz PAL frames (312 lines). A synthetic one made by the project's own scripts would do, as `pal_dpc` is. Like every generated image, it stays out of git.
  - D2 needs no ARM image. `pal2600_a78`'s first image is a plain PAL 2600 program, so any 50 Hz PAL 2600 game followed by a PAL A78 runs it.
- **The image now exists** (2026-10-17): `release/daria-pal50-test.zip`, gitignored.
  - `daria_pal50_test.bin` is a synthetic DPC+ image that draws 312-line frames from its first frame. The project's own scripts made it, and it holds no game data.
  - The zip also holds a PAL A78 for D2, the picture D1 gives in simulation, and a README with the pass and fail rules.
  - D1 and D2 were simulated with it on `tb_wire`, on the shipping tree.
  - Its generator is in scratch, not in the repository (`docs/daria_step10/plan.md`, decision 19).
- **Cost.** One test session on the build under test. No RTL change.
- **When.** Rev 0's Pocket session, on 2.2.1 and on the ÷18 debug build (`docs/daria_step10/plan.md` 3.0, item 5).
- **Done on the ÷18 debug build** (2026-10-21, the owner's Pocket session on the 2.2.4 candidate's debug build; `docs/daria_step10/rev0_record.md`). D1: the image restarts once and then runs in PAL, "works as expected for the pal test", and the overlay's row 3 "stayed all grey" after the restart (0 guard unlocks). D2 with Triple Punch's PAL build after it: "did not blink extra or anything", so RTL-1's two extra retunes are gone on silicon. The 2.2.1 control (D1 and D2 on 2.2.1) was not recorded.

### Smaller items

- **S3, the faster CPU pipeline**, kept only as a reserve. A second register-file write port, so that a load's data reaches the next instruction a clock earlier: more margin on every heavy call. It was first meant to end Spiders' 16 late calls; L1W+L3 does that at ÷18 with one write port, and that is in the release tree (`docs/DARIA_CORE.md`, decision 7). Cost: a new pipeline, 150-560 ALMs (`docs/DARIA_CORE.md`, open item 3).
  - *2026-10-19:* no longer needed for Spiders. L1W+L3 ends those calls at ÷18 with one write port (above). S3 stays only as a reserve (`docs/daria_step10/plan.md`, decision 20, open).
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
  - *2026-10-19:* deferred by the owner: "if deferring the audio check allows the testing to go faster then yes, skip over it at this time." It is built later, with D1/D2 or on a reported audio problem (`docs/daria_step10/plan.md`, decision 13).

### After 2.2.1: RTL-1 and the `src/` clean-ups

*Added 2026-10-16, from step 7's final review. The owner froze `src/` for 2.2.1 that day, so each item waits for the first `src/` change after the release. The numbers are those of `docs/daria_step7/record.md`, "After 2.2.1: `src/` clean-ups", which has the details and the line numbers.*

1. **RTL-1: a PAL A78 after a PAL 2600 image, Region on Auto** (`docs/DARIA_CORE.md`, open item 20). **Done** for the release after 2.2.1, in `5ad0a6b`: `region_pll` follows the region while an A78's 128-byte header downloads, which is narrower than the sketch below so that a download's last `clk_sys` keeps the freeze. `tb_wire`'s `pal2600_a78` now expects no extra retune, and the new unit bench `tb_region` (`sim/run_region.sh`, in `run_sim.sh`) checks it with planted variants.
   - **What it would fix.** In the DARIA build such an A78 costs two extra retunes, to NTSC and back to PAL, and its console is released 62 µs later than without DARIA. The final region is right. Main and the build without DARIA make no extra retune. The owner accepted it for 2.2.1 as a known minor issue.
   - **Cost.** A few lines in `atari7800_pocket.sv`: let `region_pll` follow the region while an A78 downloads, even with a retune pending. The last few `clk_sys` of a download need checking against the `seq_*` scenarios and the mutants. As a change to DARIA's RTL it re-runs the gates of `docs/daria_step7/plan.md` 7.6, with a new Q2.
   - **Evidence.** `tb_wire`'s scenario `pal2600_a78` runs on both builds and pins the DARIA build's two extra retunes; the build without DARIA makes none. Its expected DARIA count drops to 0 with the fix.
   - **When.** The next revision after 2.2.1.
2. **RTL-2.** During a 2600 download `region_pll` is set back to the region of the last retune. On the clock where a retune completes it takes the old region, for one `clk_sys`. A unit bench saw 3 retunes instead of 1 with a 70-byte download; no real image is that short. Cost: one line, best done with RTL-1. **Done** with RTL-1 in `5ad0a6b`: the withdrawal takes `daria_rgn`'s next value; `tb_region` catches the old line (3 retunes in 33 of 1,641 trials).
3. **`core_constraints.sdc`'s comment** gives VCO/18's lattice ("only every 3 `clk_sys`"). At VCO/19 the edges meet every 19 `clk_sys`. **Done** by the move back to ÷18 (`09aa7f8`): the lattice line is right again, and the counter[3] line says VCO/18, 38.18 MHz.
4. **`ap_core.qsf`'s seed comment** gives 2.1.1's margins, before the AtariVox build's seeds that 2.2.1 added, and still asks for a fix in `sram_ctrl` that Fix B made. **Done** with the seed move (`SEED` 3, 2026-10-21): the comment quotes the release's Q2, seeds 1-3 on `ebca01a`.
5. **`daria_sync.tcl`'s FORCED mark on `cap_err_a[0]`** matches no build, and Quartus lists it as ignored. **Done** in `dd135dd`: the mark is gone (15 marks), and the smoke test, which now expects 15, passes. *2026-10-21 (Stage 2 review):* the marks on `pause_a[0]` and `halted_s[0]` matched no build either (`pause_core` is tied 0, and the wrapper leaves `daria_halted` open, the overlay included), and the fitter listed both as ignored in Q2 and Q5; they are removed too (13 marks), and the smoke test expects 13.
6. **`core_top.v`'s audio comment** says 298 samples per output, about 48 kHz. `audio_filter.sv` averages 256, about 55.9 kHz. **Done** with item 4 (2026-10-21): the comment says 256 and about 55.9 kHz.
7. **`pll_core.v`'s comment** says the VCO/19 display strings are "one digit lower". Only two of the four are. **Done** with the ÷18 PLL change (`09aa7f8`): the header is rewritten for C3 = 18, and the sentence is gone.
8. **`src/fpga/mister/POCKET_CHANGES.md`** counts eight modified upstream files where there are eleven, and its "Updating" list re-applies six. Until it is fixed, `docs/DEVELOPING.md`, "Update the MiSTer core", lists all eleven. **Done** in `5febe80`: `POCKET_CHANGES.md` counts eleven and its "Updating" list names them all; `DEVELOPING.md`'s workaround is shortened.

- **Cost of items 3-8.** Items 3, 4, 6 and 7 change comments only. They need plan 7.6's proof: the same `pp_equiv` hashes on both macro sets, and an SDC or qsf diff that is empty with comments stripped. Item 5 changes an assignment file, so it needs a new Q2 and the smoke test. Item 8 is a document.
- **When.** Items 1 and 2 in the next revision; the rest with the first `src/` change after 2.2.1.
  - *2026-10-19:* the plan puts items 1-8 into the next release (`docs/daria_step10/plan.md` 3.1). At ÷18 item 3's lattice line is right again, but its counter[3] line must then say VCO/18, 38.18 MHz. Item 7 goes with the ÷18 PLL change. Item 8 waits for the release too: Rev 0 changes nothing under `src/`.
  - *2026-10-21:* items 1, 2, 3, 5, 7 and 8 are done (above). Items 4 and 6 are left. Item 4 waits for the release's Q2, whose figures the seed comment will quote, and goes in with the seed (`docs/daria_step7/plan.md` P12, as amended 2026-10-21). Item 6 is a comment and goes in with it, under plan 7.6's proof.
  - *2026-10-21, after the release's Q2:* items 4 and 6 are done, with `SEED` 3 (P12): every `pp_equiv` stream is unchanged, and `ap_core.qsf` differs only in the `SEED` line with comments stripped.

## The 7800 core (both builds: with and without DARIA)

- **A PAL 2600 game's picture window after its one retune.**
  - The retune's reset clears the TIA's region measurement (`TIA.sv:1708`). So the game is shown in the NTSC window at the PAL clock for about 0.96 s, until the TIA decides again (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
  - A suggestion, untested: start the TIA's `pal_mode` after the reset from the wrapper's `tia_pal_seen` latch. That changes upstream's `TIA.sv`.
- **A Sega Genesis pad for 2600 games.** The Pocket reads a 2600 image's paddle inputs as 0 with a joystick, as a real 2600 does, so Genesis-aware games (Galagon, SF2fix, Turbo) start in single-button mode. A "Genesis pad" Port Input option would let them offer their second-button functions. It would present INPT1 (port 1) and INPT3 (port 2) high while a mapped second button is released, and low while it is pressed. It would change every 2600 game that reads those inputs (`docs/daria_step7/progress.md`, "Frame runs on D against R1").
- **An A78 image the BIOS drops into 2600 mode** is not covered by the region hold, and could loop between regions if its 2600-mode video measured PAL against an NTSC header. It is not simulated, and main's 2.1.3 has the same exposure (`docs/daria_step7/progress.md`, "Fit Q1' and commit P").
- **FA2 saves: Star Castle Arcade's high scores.** *Added 2026-10-17, from the owner's finding on the Pocket, for a release after 2.2.1.* **Done** for 2.2.4, in `4738c65`, with the port gated to 2600 mode in `35bf88f` (an A78 that `detect2600.sv` takes for FA2 could otherwise write over the file; `run_sim.sh` runs one): one shared `fa2.sav` of 256 bytes beside `hsc.sav` and `savekey.sav` (the owner, 2026-10-21: "Shared for the time being."), behind upstream's `fa2_nvram_bridge.sv`. `run_sim.sh` checks the round trip with a synthetic FA2 cartridge. The release's Q2 (seeds 1-3 on `ebca01a`, and again on the merged tree `7701ee9`) passes every gate and check. **Hardware-tested** on 2026-10-21, in the owner's Pocket session on the 2.2.4 candidate's debug build (the ÷18 tree before the merge of 2.2.2, which changes no FA2 file): Star Castle Arcade keeps its high score across quitting and reopening the core. The owner: "star castle test passed." (`docs/daria_step10/rev0_record.md`).
  - **What it would fix.** Star Castle Arcade, an FA2 game, does not keep its high-score saves on the Pocket.
    - The FA2 mapper (`mapper_fa2.sv`) copies its 256-byte work RAM to and from the cartridge's flash through the `fa2_nvram_*` port.
    - The Pocket wrapper leaves that port unconnected (`atari7800_pocket.sv:1282-1288` in 2.2.1). Every read returns $FF, as from a blank flash, every request is ready at once, and every write is dropped.
    - On MiSTer, upstream's `fa2_nvram_bridge.sv` connects the port to the core's save RAM. The Pocket build does not use it.
    - The stub dates from the port's first commit (`3043d50`), so every release of this port has it. It is not DARIA's.
  - **Cost.** A 256-byte nonvolatile save slot behind the FA2 port, like `hsc.sav`.
    - `docs/DEVELOPING.md`, "Add a save slot", is the recipe: `save_ram_dp` with its APF read latch, a constant size in the data slot table, the next bridge region (`0x40000000`), a `data.json` slot appended after the others, a new file blank as $FF, and a round trip in `tb_load`.
    - It changes `src/` in both builds. By `docs/daria_step7/plan.md` 7.6 it re-runs `run_sim.sh`, `extra_tests.sh`, `s4/check.sh` and `pp_equiv.py`, and needs a new Q2.
  - **Evidence.** The owner's finding on the Pocket.
  - **When.** After 2.2.1, with the first `src/` change.
    - *2026-10-19:* in the plan for the next release (`docs/daria_step10/plan.md` 3.1). One shared file or one per game is the owner's call (decision 15).
