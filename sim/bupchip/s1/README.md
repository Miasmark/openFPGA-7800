# BupChip S1 core: simulation

Step 2 of `docs/BUPCHIP_CORE.md`: the S1 core, `src/fpga/core/bupchip/bup_cpu.sv`, running CoreTone in simulation, checked against MiSTer's reference BupChip. The verification harness it plugs into is `../verif/` (lockstep, ISA suite, mixer harness, synthetic ARSC); this directory adds the S1 system testbench, the directed tests and the halt tests.

Game files, and anything made from them (PCM, logs), stay in `sim/work/` and out of git.

## Running

```sh
sim/bupchip/s1/check.sh [sim/work/bupchip/game/rv.a78]   # everything below; 3 min without the game, 6 with it
sim/bupchip/s1/run_directed.sh                           # directed and halt tests, 10 s
sim/bupchip/s1/run_s1.sh GAME.a78 13 4                   # one song on tb_s1.sv, about 3 min
DUT=bup sim/bupchip/verif/run_lockstep.sh GAME.a78 +song=13 +songcyc=1000000 +maxret=1000000
DUT=bup LOCKSTEP=1 sim/bupchip/verif/isa/run_isa.sh      # ISA suite: Unicorn and lockstep
```

| File | What it is |
|---|---|
| `tb_s1.sv` | The core with its ROM (`cache_ram_dp`, stock `bupchip.hex`), RAM (`cache_ram_tdp_dc_be`), the unmodified `bupchip_peripheral` at CMD 8 / PCM 1,024 with the watermark remap, the ARSC block as a behavioural asset memory, and the 48 kHz pop from a `clk_74a` accumulator, all at 28.636 MHz. Song mode writes the pushed PCM and per-batch clocks and reports busy, CPI and MIPS; program mode runs a ROM image to its end marker or a halt. Plusargs are listed in its header. |
| `build_s1.sh`, `run_s1.sh` | Build it (`PCM_DEPTH=4096` for the stock FIFO depth, where the remap is the identity), run a song, compare the PCM (`pcm_check.py`) |
| `pcm_check.py` | Lines our pushed frames and run_bupchip.sh's reference up on their first nonzero frame (the song's first: the prefill is 1,000 frames here and 4,000 on MiSTer) and compares every frame from there; summarises the batches |
| `run_directed.sh`, `directed/*.S` | Directed tests on the reference RTL and in lockstep, twice: once plain, once with random asset waits and throttle clocks |
| `halt_tests.py` | One program per halt case; the core must halt with the expected code at the expected instruction |
| `check.sh` | All of the above, plus `../verif/run_all.sh` with `DUT=bup LOCKSTEP=1`, plus songs 13, 14, 9 and 30 against `sim/work/bupchip/ref/` |

**Busy and CPI.** Every clock is charged to the instruction that retires at the end of it or is still in progress; instructions retired at 0x178–0x18c (the poll loop) are idle. So idle is decided by the retired PC, not the fetched one as in `tb_bupchip.sv`. A batch runs from the retire of 0x190 to the retire of 0x1dc after a render or 0x274 after a silent batch.

## The core

`bup_cpu.sv`'s header documents the interface, the clocks per instruction and the halt codes. In short:

- Fetch through ROM port A's address register (next PC on `rom_addr`); data on ROM port B and RAM port A from `d_addr`; the asset word on `asset_q` with `w_wait` while it is missing; the peripheral during W (`reg_sel`, a one-clock pulse because W never waits for MMIO in hardware).
- Exact NZCV everywhere (the MIT `arm7tdmi_pkg` shifter, with LSR/ASR #0 normalised to 32 and RRX on its own path), unaligned LDR rotation and odd LDRH/LDRSH as on the ARM7TDMI, r0–r14 cleared after every hold, and a halt with a code and PC for everything else.
- The retire port of `../verif/README.md`, in simulation only.

**Clean-room review.** The study's sketch was compared with `arm7tdmi_core.sv` (GPL-2.0-only) before it was used as the starting point: identifiers (6 shared of 134, all generic: `clk`, `ce`, `rf`, `sum`, `halted`, `retire`), comments (no shared five-word run), identical lines (only `always_comb begin` and a port line) and token n-grams (no literal 12-gram in common; the abstracted matches are declaration lists). The structure differs throughout: the reference is a decode/execute pipeline with forwarding descended from `gba_cpu.vhd`; the sketch is a single-execute state machine with one adder for every arithmetic operation. `bup_cpu.sv` was then written anew from the ARM ARM and the design: the shifter, condition test and rotator are the MIT package's, the immediate-shift normalisation, RRX and the alignment rules are from the ARM ARM and GBATEK, and canonical forms (byte strobes, the lowest-set-bit search) are written in this file's own way.

## Results (2026-10-03, Verilator 5.040)

| Check | Result |
|---|---|
| ISA suite, `sample.S` + 200 seeds × 300 operations | 201 of 201: the reference agrees with Unicorn, and the new core with the reference in lockstep (362,371 retires and 122,330 stores compared, 0 mismatches) |
| Directed tests (13: shifts, flags × conditions, multiplies, LDM/STM, write-back, alignment, dependences, LDR pc, MMIO, PSR, condition-failed encodings, should-be-zero fields, registers read before written) | 13 of 13 in lockstep, plain and with `+await=40 +throttle=25`; 15,077 retires each pass |
| Halt tests | 51 of 51: every case halts with its code at its instruction |
| Mixer harness, lockstep | 1,742,652 retires, 235,742 stores, 4,802 peripheral writes; 0 mismatches |
| Synthetic ARSC, lockstep, every command class | 2,135,928 retires, 118,048 stores, 9,002 peripheral writes, 431,370 replayed reads; 0 mismatches |
| Random-content ARSC seeds 1–4, lockstep | 0 mismatches; seed 4: the reference aborts at 0x40405206 and the core halts (code 5, pc 0x18a0), both after 88,940 retires |
| Rikki & Vikki, boot + Misery_F, lockstep | 1,000,000 retires, 91,683 stores, 6,202 peripheral writes, 99,279 replayed reads; 0 mismatches |
| The same, 4,000,000 retires with `+await=20` | 445,679 stores, 14,002 peripheral writes; 0 mismatches |
| The same, 2,000,000 retires with `+throttle=20 +await=30` | 0 mismatches |
| Songs 14, 9, 30 and 6, lockstep, 3,000,000 retires each | 0 mismatches |
| `+inject=50000` / `+inject_mmio=5000` | Caught at retire 247,167 / 112,261 |
| PCM, songs 13, 14, 9, 30, 4 s each | All 187,984 song frames identical to MiSTer's for each; 0 underruns, 0 overflows; lowest FIFO level 660, 756, 722, 801 of 1,024 |
| Misery_F, 4 s | CPI 1.3772 (−0.4% from 1.383); 60,574,078 work instructions, 15.14 MIPS; busy 72.8% of 28.636 MHz, 20.86 MHz at 100%; busiest 0.1 s 21.48 MHz, worst batch 23.98 MHz |
| Songs 14, 9, 30 | CPI 1.3833, 1.3790, 1.3938; 5.30, 9.46, 1.81 MIPS |
| Misery_F 1 s with `+throttle=20 +await=30`; with `+alat=8`; after a hold 70 ms into the song (`+rehold`); with the stock 4,096-frame FIFO | PCM identical in each; registers read 0 after the hold |

The 1.383 of the design was measured on the study's sketch with its two-line asset buffer, whose stalls added 0.27%. `tb_s1.sv`'s asset memory answers every load in W, so the core's own CPI is lower; the asset cache (step 4) adds its stalls back.
