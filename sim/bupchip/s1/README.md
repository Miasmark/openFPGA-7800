# BupChip S1 core: simulation

Step 2 of `docs/BUPCHIP_CORE.md`: the S1 core, `src/fpga/core/bupchip/bup_cpu.sv`, running CoreTone in simulation, checked against MiSTer's reference BupChip. The verification harness it plugs into is `../verif/` (lockstep, ISA suite, mixer harness, synthetic ARSC); this directory adds the S1 system testbench, the directed tests and the halt tests.

Game files, and anything made from them (PCM, logs), stay in `sim/work/` and out of git. The firmware is not in the repository either: the directed, halt, fuzz and ISA tests run their own programs, but `tb_s1.sv`'s song mode, the mixer harness, the synthetic ARSC checks and every game run execute CoreTone. Put your copy of MiSTer's `bupchip.hex` at `src/fpga/mister/rtl/` (`docs/BUPCHIP.md`, "Firmware: bupchip.bin"); without it `check.sh` skips those steps (SKIP in `run_all.sh`'s summary) and refuses a game argument.

## Running

```sh
sim/bupchip/s1/check.sh [sim/work/bupchip/game/rv.a78]   # everything below; 5 min without the game, 9 with it
sim/bupchip/s1/run_directed.sh                           # directed and halt tests, 15 s
LATE_RF=1 WORK=sim/work/bupchip/s1/directed_laterf sim/bupchip/s1/run_directed.sh   # the same, register-file writes late
sim/bupchip/verif/directed/run.sh                        # further directed tests, end of ROM, fuzz; 1 min
sim/bupchip/s1/run_s1.sh GAME.a78 13 4                   # one song on tb_s1.sv, about 3 min
DUT=bup sim/bupchip/verif/run_lockstep.sh GAME.a78 +song=13 +songcyc=1000000 +maxret=1000000
DUT=bup LOCKSTEP=1 sim/bupchip/verif/isa/run_isa.sh      # ISA suite: Unicorn and lockstep
sim/bupchip/verif/run_songs.sh GAME.a78                  # all 32 songs × 4 s in lockstep, about an hour on 4 cores
```

| File | What it is |
|---|---|
| `tb_s1.sv` | The core with its ROM (`cache_ram_dp`, stock `bupchip.hex`), RAM (`cache_ram_tdp_dc_be`), the unmodified `bupchip_peripheral` at CMD 8 / PCM 1,024 with the watermark remap, the ARSC block as a behavioural asset memory, and the 48 kHz pop from a `clk_74a` accumulator, all at 28.636 MHz. Song mode writes the pushed PCM and per-batch clocks and reports busy, CPI and MIPS; program mode runs a ROM image to its end marker or a halt. Plusargs are listed in its header. |
| `build_s1.sh`, `run_s1.sh` | Build it (`PCM_DEPTH=4096` for the stock FIFO depth, where the remap is the identity), run a song, compare the PCM (`pcm_check.py`) |
| `pcm_check.py` | Lines our pushed frames and run_bupchip.sh's reference up on the song's first frame (here the frame pushed after the firmware took the command, which `tb_s1.sv` reports; on MiSTer frame 4,000, after the prefill) and compares every frame from there, leading silence included; summarises the batches |
| `run_directed.sh`, `directed/*.S` | Directed tests on the reference RTL and in lockstep, twice: once plain, once with random asset waits and throttle clocks |
| `halt_tests.py` | One program per halt case; the core must halt with the expected code at the expected instruction. The `romend_*` cases put one instruction of each kind in the last ROM word, where running on must halt (FETCH) |
| `check.sh` | All of the above; `../verif/directed/run.sh`; `../verif/directed/run_vfy.sh`; the directed, halt, `run_vfy.sh` and ISA lockstep tests again with `LATE_RF=1`; `../verif/run_all.sh` with `DUT=bup LOCKSTEP=1`; songs 13, 14, 9 and 30 against `sim/work/bupchip/ref/` |

**Busy and CPI.** Every clock is charged to the instruction that retires at the end of it or is still in progress; instructions retired at 0x178–0x18c (the poll loop) are idle. So idle is decided by the retired PC, not the fetched one as in `tb_bupchip.sv`. A batch runs from the retire of 0x190 to the retire of 0x1dc after a render or 0x274 after a silent batch.

## The core

`bup_cpu.sv`'s header documents the interface, the clocks per instruction and the halt codes. In short:

- Fetch through ROM port A's address register (next PC on `rom_addr`); data on ROM port B and RAM port A from `d_addr`; the asset word on `asset_q` with `w_wait` while it is missing; the peripheral during W (`reg_sel`, a one-clock pulse because W never waits for MMIO in hardware).
- Exact NZCV everywhere (the MIT `arm7tdmi_pkg` shifter, with LSR/ASR #0 normalised to 32 and RRX on its own path), unaligned LDR rotation and odd LDRH/LDRSH as on the ARM7TDMI, r0–r14 cleared after every hold, and a halt with a code and PC for everything else, including running on past the last ROM word (MiSTer aborts the fetch from 0x4000).
- The retire port of `../verif/README.md`, in simulation only.
- `BUP_SIM_LATE_RF` (simulation only; `LATE_RF=1` in the build scripts): register-file writes land a clock late, with garbage in the entry for the clock between, as an MLAB might behave. The behavioural array otherwise makes every write visible on the next clock, so without it nothing exercises the one-clock-old bypass.

**Clean-room review.** The study's sketch was compared with `arm7tdmi_core.sv` (GPL-2.0-only) before it was used as the starting point: identifiers (6 shared of 134, all generic: `clk`, `ce`, `rf`, `sum`, `halted`, `retire`), comments (no shared five-word run), identical lines (only `always_comb begin` and a port line) and token n-grams (no literal 12-gram in common; the abstracted matches are declaration lists). The structure differs throughout: the reference is a decode/execute pipeline with forwarding descended from `gba_cpu.vhd`; the sketch is a single-execute state machine with one adder for every arithmetic operation. `bup_cpu.sv` was then written anew from the ARM ARM and the design: the shifter, condition test and rotator are the MIT package's, the immediate-shift normalisation, RRX and the alignment rules are from the ARM ARM and GBATEK, and canonical forms (byte strobes, the lowest-set-bit search) are written in this file's own way.

## Results (2026-10-03, Verilator 5.040)

| Check | Result |
|---|---|
| ISA suite, `sample.S` + 200 seeds × 300 operations | 201 of 201: the reference agrees with Unicorn, and the new core with the reference in lockstep (362,371 retires and 122,330 stores compared, 0 mismatches) |
| Directed tests (13: shifts, flags × conditions, multiplies, LDM/STM, write-back, alignment, dependences, LDR pc, MMIO, PSR, condition-failed encodings, should-be-zero fields, registers read before written) | 13 of 13 in lockstep, plain and with `+await=40 +throttle=25`; 15,411 retires and 4,002 stores each pass |
| Halt tests | 66 of 66: every case halts with its code at its instruction, including 15 with one instruction of each kind in the last ROM word |
| The same with `LATE_RF=1` (register-file writes a clock late) | 13 of 13 directed, 66 of 66 halt tests, ISA suite 201 of 201 in lockstep. With the bypass removed as a check, all 13 directed tests fail in this build and pass in the plain one. |
| `../verif/directed/run.sh` | `carry`, `rsamt`, `blk15`, `pcops`, `unpred` in lockstep; `romend` halts at 0x3FFC with code 4 after 14 retires (a taken branch there first); fuzz seeds 1–8 |
| Mixer harness, lockstep | 1,742,652 retires, 235,742 stores, 4,802 peripheral writes; 0 mismatches |
| Synthetic ARSC, lockstep, every command class | 2,135,928 retires, 118,048 stores, 9,002 peripheral writes, 431,370 replayed reads; 0 mismatches |
| Random-content ARSC seeds 1–4, lockstep | 0 mismatches; seed 4: the reference aborts at 0x40405206 and the core halts (code 5, pc 0x18a0), both after 88,940 retires |
| Rikki & Vikki, boot + Misery_F, lockstep | 1,000,000 retires, 91,683 stores, 6,202 peripheral writes, 99,279 replayed reads; 0 mismatches |
| The same, 4,000,000 retires with `+await=20` | 445,679 stores, 14,002 peripheral writes; 0 mismatches |
| The same, 2,000,000 retires with `+throttle=20 +await=30` | 0 mismatches; also with `LATE_RF=1` (209,627 stores, 8,802 peripheral writes, 148,951 replayed reads) |
| Songs 14, 9, 30 and 6, lockstep, 3,000,000 retires each | 0 mismatches |
| All 32 songs × 4 s, lockstep, odd songs with `+await=20 +throttle=10` (`../verif/run_songs.sh`, 56 min on 4 cores) | 32 of 32: 2,455,321,557 retires, 108,396,668 stores, 6,300,064 peripheral writes, 552,342,467 replayed reads; 0 mismatches, 0 halts. Re-run in round 2 with each access checked against the instruction that made it: the same totals, 0 mismatches (78 min with `JOBS=3` beside other runs). |
| `+inject=50000` / `+inject_mmio=5000` | Caught at retire 247,167 / 112,261 |
| PCM, songs 13, 14, 9, 30, 4 s each | All 187,984 song frames identical to MiSTer's for each, compared from the song's first frame (ours 1,000, MiSTer's 4,000; neither has silence before the first note); 0 underruns, 0 overflows; lowest FIFO level 660, 756, 722, 801 of 1,024 |
| Misery_F, 4 s | CPI 1.3772 (−0.4% from 1.383); 60,574,078 work instructions, 15.14 MIPS; busy 72.8% of 28.636 MHz, 20.86 MHz at 100%; busiest 0.1 s 21.48 MHz, worst batch 23.98 MHz |
| Songs 14, 9, 30 | CPI 1.3833, 1.3790, 1.3938; 5.30, 9.46, 1.81 MIPS |
| Misery_F 1 s with `+throttle=20 +await=30`; with `+alat=8`; after a hold 70 ms into the song (`+rehold`); with the stock 4,096-frame FIFO | PCM identical in each; registers read 0 after the hold (these runs predate the ROM-end fix and the song-start alignment) |

The `check.sh` rows were re-run after the ROM-end fix, the `LATE_RF` build, the end-of-run checks in `tb_lockstep.sv` and the song-start PCM alignment; the numbers did not change.

**Verification round 2.** They were run again after these changes:
- `tb_lockstep.sv` now checks which instruction made every access, and checks the leftovers at every stop;
- the fuzz now requires a reference abort behind every DATA or RO halt;
- `check.sh` now includes `run_vfy.sh`.

`check.sh` passes 11 of 11 with the game (8 min 39 s on 4 cores) with the same numbers. Without the firmware, in a fresh copy of the tree, it passes 7 of 7 in 4 min 42 s, with the mixer harness and the synthetic ARSC listed as SKIP. Fuzz seeds 9–40 also pass: 14,400 encodings, of which 9,487 ran in lockstep (257,529 retires, 35,081 stores) and 1,147 DATA or RO halts were each matched by a reference abort.

The 1.383 of the design was measured on the study's sketch with its two-line asset buffer, whose stalls added 0.29% (`../model/study/`, which reproduces it). `tb_s1.sv`'s asset memory answers every load in W, so the core's own CPI is lower; the asset cache (step 4) adds its stalls back.
