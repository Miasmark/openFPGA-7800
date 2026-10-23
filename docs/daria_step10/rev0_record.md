# DARIA step 10: Rev 0's results

Written 2026-10-23, on `rev1/merge-222`. [plan.md](plan.md) 3.0 says Rev 0's results are recorded beside the plan when it ends. This is that record. Each result is labelled with its source.

## What Rev 0 was

Rev 0 ran from 2026-10-19 to the owner's Pocket session of 2026-10-21. It shipped no bitstream. Its items are in [plan.md](plan.md) 3.0. Their results are recorded where the plan says, and this record points to them:

| Item (3.0) | Result | Where |
|---|---|---|
| 1. The DARIA status overlay (A2) | Landed in `src/`, `BUP_DEBUG` only (`0d9ce33`, its check fixed in `5d5d591`), and reviewed | 3.0 item 1 |
| 2. G1's fit-script changes | Landed and reviewed (`fit_selftest`, the smoke test) | section 10 |
| 3. The ÷18 debug build of the candidate, Spiders in simulation, `s4` at 38.18 MHz, `THUMB=1 s1/check.sh` | Built and fitted (Q5, P29 met). Spiders: 0 late calls on the overlay's counter, the guard locked, 0 unlocks [sim]. `s4/check.sh`'s DARIA set at 38.18 MHz passes. Song 13's CPI 1.4208, PCM identical to MiSTer's on songs 13, 14, 9 and 30 [sim] | the plan's status block; decision 10 |
| 4. The optional ÷19 overlay build of 2.2.1 | Built and given to the owner (D19); no hardware result recorded | - |
| 5. The owner's session (V-hw) | **Held on 2026-10-21**, on the release candidate's debug build (below) | this record |
| 6. The `sram_ctrl` hold: cause and fix trial | The cause found, the fix trialled; decision 11's copy is in `src/` (`7a4bf2c`) | section 4 |
| 7. The Harmony model, bench only | Landed (`docs/HARMONY_MODEL.md`) | 3.2 |
| 8. Documents | Done, except B8, which went into the release (`5febe80`) | 3.0 item 8 |
| 9. Spiders on a real Harmony (optional) | Will not run: the owner has no Harmony cartridge (decision 5) | 3.3 |

## The owner's Pocket session (2026-10-21)

### The build

The owner tested the release candidate's debug build, not Rev 0's D18. By then the owner had chosen to land ÷18 for the release before the session (decisions 2, 3 and 7), so this build carries the same CPU (L1W+L3 with T2's cures) and the same divider (÷18) as D18, with the release's other changes [read: the build's notes, outside the repository].

- The zip is `Atari7800_Pocket_div18-rc-debug.zip` (md5 `773c611a813de1d5862bb9c480bf624f`), packaged on 2026-10-21 at 21:10 ET with `tools/package.sh`.
- Its tree is `3f82cd6`: `8d7a26a` with the `BUP_DEBUG=1` line, whose code stream equals `c4d8b69`'s, the Q5 tree of Stage 2's round.
- The bitstream is that round's Q5 seed-3 fit (`ap_core.rbf` md5 `d0a72f6fe4db742137ab5bda66fd2a78`). `core.json` says 2.2.1, and `data.json` has the `fa2.sav` slot. No game, BIOS or firmware is inside.
- That is the ÷18 tree **before the merge of 2.2.2**. It has neither 2.2.2's POKEY read fix nor its AtariVox escape fix, and it is seed 3, not 2.2.4's seed 2.

The owner confirmed that this zip was the build used. Two photos of Spiders' overlay were taken on it. They are kept outside the repository.

### Results

The rows follow the session checklist's part B (kept outside the repository). The owner's words are quoted.

| Item | What was seen | Reading |
|---|---|---|
| B1, B2: Spiders through its first level load | "just tested spiders arcade. no screen shift either. no indication of collisions as far... nothing is red anyway." The photos show row 0's boxes 1 and 2 green (ARM running, guard locked), its boxes 4-7 grey (no halt, no load error), rows 1, 2 and 3 grey (no halt or fault code, 0 late calls, 0 guard unlocks), and rows 4 and 5 blue (the running call count) | **Pass.** On silicon at ÷18 the guard locks with 0 unlocks, no call is late, and the picture shift of 2.2.1 (daria-test1) is gone |
| B4: the PAL 50 Hz test image (D1) | "works as expected for the pal test." After the restart, row 3 "stayed all grey" | **Pass.** One restart, then PAL. The guard keeps 0 unlocks through the retune, the case of the retune prediction in which the retune keeps the guard's phase |
| B5: a PAL A78 after the image (D2) | "loading triple punch pal after the pal test image did not blink extra or anything" | **Pass.** No extra retune: RTL-1 works on silicon |
| B6: Rikki & Vikki | "Rikki and Vikki work fine as well." | **Pass.** The BupChip and the PSRAM run at 38.18 MHz |
| B7: Turbo | "turbo seems to function as expected as well" | **Pass.** Its reads beyond the 64 KB window come through the PSRAM cache at 38.18 MHz |
| FA2: Star Castle Arcade | "star castle test passed." The high score is kept across quitting and reopening the core | **Pass.** `fa2.sav` holds it (decision 15) |

**Not done or not recorded:**
- Part A, the 2.2.1 control: the picture shift on 2.2.1, and D1 and D2 on 2.2.1.
- B3: further level loads of Spiders.
- B8 and B9: clicks on Galagon and Mappy, by ear.
- B10: Spiders again at the end.
- Part C: the optional ÷19 build. Without it, "0 late calls" rests on a counter not checked on hardware, as 3.0 item 5 notes. The overlay's counter is checked in simulation: it reads Spiders' 16 late calls at ÷19 [sim: 3.0 item 1].

### What it settles

- **Decision 2** (the L1W+L3 CPU) and **decision 3** (÷18): settled ([plan.md](plan.md), section 6).
- `docs/DARIA_CORE.md` open item 7 (the guard locks on silicon) and open item 10 (PSRAM at 38.18 MHz on hardware).
- `docs/IMPROVEMENTS.md`: the PAL region items (D1, D2) and the FA2 item are done on hardware.
- The prerequisite in 3.1: "Rev 0's session showing the guard locked and the BupChip and Turbo working at 38.18 MHz".

### What it does not cover

A hardware result belongs to its netlist. The session covers the ÷18 tree before the merge of 2.2.2.
- The merge (`a080f6f`) changes no DARIA file, so the CPU, the divider and the guard are the same in 2.2.4.
- The merge does bring 2.2.2's POKEY read fix (`pokey_bus.sv`, `pokey.sv`, `pokey_adapter.sv`) and its AtariVox escape fix (`avox_rx.sv`), in a new placement. Those fixes have run on silicon only in 2.2.2's ÷19 build.
- Seed 2, which 2.2.4 ships, has not run on hardware at ÷18.

**Held on 2026-10-23, before 2.2.4 is tagged:** one session on a debug build of the final tree (`Atari7800_Pocket_2.2.4-rc-debug.zip`, zip md5 `6a6441c91d6ee698b01907a4f9286e2e`). The owner, after the checks below: "tests pass". The build is the merged tree's Q5 seed-2 `.rbf` (md5 `d318d6af15b18afc18960e1f45353462`), the seed the release uses. The session covers:
- Star Raiders: its title, and its AtariVox saying "Star Raiders";
- POKEY music: Ballblazer or Commando;
- AtariVox speech: Juno First and Stratovox;
- a short look at Spiders' overlay: row 0 box 2 green, rows 2 and 3 grey.
