# BupChip design study: RTL sketch and block experiments

`docs/BUPCHIP_CORE.md` was written from a design study that compared three proposals. Its cycle models and firmware tools are one level up (`../`). This directory keeps the rest of what the design's figures rest on:

- proposal B's RTL sketch, which ran the firmware before the core existed;
- the PSRAM controller fact check;
- the PCM FIFO sizing experiment;
- the Yosys cell counts.

None of it is the core. The core is `src/fpga/core/bupchip/bup_cpu.sv`, and its checks are in `../../s1/` and `../../verif/`. Steps 4 and 5 can start from these files: the asset path, capture, PSRAM controller and wrapper sketches.

Everything here is this project's and MIT (`LICENSE`), like the rest of `sim/bupchip/`. Nothing in this directory is game data or comes from game data.

Most of the scripts need the firmware at `src/fpga/mister/rtl/bupchip.hex` (`docs/BUPCHIP.md`, "Firmware: bupchip.bin"). `run_sketch.sh` also needs a game image with its ARSC block. Build products go to `sim/work/bupchip/study/`.

## Clean room

`arm7tdmi_core.sv` is GPL-2.0-only. Every `.sv` file here was compared with it. No file shares a run of 15 code tokens with it, or a run of 5 words in its comments. The shared identifiers are generic ones: `clk`, `rst`, `insn`, the MIT `arm7tdmi_pkg` names. Proposal A's sketch imports `arm7tdmi_pkg` (MIT, Jamie Blanks) unchanged from `src/fpga/mister/rtl/arm7tdmi/`. The FIFO experiment builds modified copies of `bupchip_peripheral.sv` and `bupchip_subsystem.sv` (MIT, Jamie Blanks) in the work directory at run time, so they are not stored here.

## Files

| Path | What it is |
|---|---|
| `sketch/bup_cpu.sv` | Proposal B's CPU sketch, v2, written from the ARM ARM. S1 started from it. Its header lists what it leaves out. |
| `sketch/bup_asset.sv`, `bup_asset_v1.sv` | B's two-line asset stream buffer, versions 2 and 1. Version 1 has the partial-line rule the design adopted: a load completes once the halfwords it touches have arrived. |
| `sketch/bup_capture.sv`, `bup_psram.sv`, `bup_pocket.sv` | ARSC capture, an asynchronous PSRAM controller and the whole Pocket BupChip. They were written for area estimates and never simulated. They pass `verilator --lint-only`. |
| `sketch/tb_cpu.sv`, `run_sketch.sh` | The sketch playing a song with the real peripheral, at 28.636 MHz. The PCM is compared with MiSTer's, and CPI and batch figures are reported. |
| `sketch/cmp_ref.py` | Compares the sketch's retire trace with the reference's (`../../verif/tb_ref_trace.sv`), register by register |
| `psram/tb_psram.sv`, `run_psram.sh` | agg23's `psram.sv`, counted clock by clock (iverilog) |
| `fifo/tb_fifo.sv`, `run_fifo.sh` | MiSTer's reference BupChip with the PCM FIFO cut down, with and without the watermark remap, booting the synthetic ARSC block |
| `area/parts.sv`, `bup_core_sketch.sv`, `run_area.sh` | Yosys `synth_intel_alm` counts: the datapath blocks, both proposals' whole-core sketches, the S1 core and the peripheral |

## Commands and results (2026-10-03)

From the repository root, with Rikki & Vikki built by `make_arsc.py` and MiSTer's PCM from `run_bupchip.sh` in `sim/work/bupchip/ref/`:

```sh
S=sim/bupchip/model/study
$S/sketch/run_sketch.sh sim/work/bupchip/game/rv.a78 13 4            # 2 minutes
TRACE=90000 $S/sketch/run_sketch.sh sim/work/bupchip/game/rv.a78 13 1
PSRAM=path/to/psram.sv $S/psram/run_psram.sh     # seconds; default src/fpga/pocket_utils/psram.sv
$S/fifo/run_fifo.sh                              # 30 s
$S/area/run_area.sh                              # 1 minute
```

### The sketch, Misery_F

The defaults are those of the study's measurement: stream buffer v2, both PSRAM chips in lockstep (`WIDE=1`) and 5 clocks per read.

| Run | CPI | MHz needed: average / busiest 0.1 s / worst batch | Lowest FIFO level | PCM |
|---|---|---|---|---|
| Song 13, 4 s, defaults | 1.383 | 20.93 / 21.53 / 24.33 (23.35 without the song-start batch) | 664 | Identical to MiSTer's over all 187,984 frames, compared from the first nonzero frame |
| Song 13, 4 s, `WIDE=0` | 1.431 | 21.66 / 22.59 / 24.92 | 659 | Identical |
| Song 13, 4 s, `WIDE=0 ASSET=v1` | 1.421 | 21.50 / 22.53 / 24.69 | 660 | Identical |
| Songs 9, 14 and 30, 1 s each | 1.386, 1.393, 1.404 | — | 726, 755, 809 | Identical (47,800, 47,800 and 48,000 frames) |

- With `TRACE=90000`, the sketch matches the reference register for register for 85,258 instructions of the boot.
- The first difference is a read of the FIFO status: the sketch's FIFO is 1,024 frames deep and the reference's 4,096.
- These are the figures in `docs/BUPCHIP_CORE.md` ("Decision summary", and the 664-frame level under "PCM and command FIFOs").
- The S1 core itself measures CPI 1.3772 with zero-wait assets and a lowest level of 660 (`../../s1/README.md`).

### PSRAM controller

With `CLOCK_SPEED` = 28.636364, every read and every write takes 5 clocks, and the state numbers are distinct. That holds on clocks of 28.636 MHz (175 ns), 21.477 MHz (233 ns) and 21.281 MHz (235 ns).

`CLOCK_SPEED` set to 21.477273, 21.281 or 14.318181 does not work:
- the read and write totals collide with an earlier state (write states 1 2 3 3, read states 20 21 22 22);
- no read or write completes in 200 clocks.

This is why the design keeps `CLOCK_SPEED` at 28.636364. The study checked its own copy of `psram.sv`. Step 4 vendored the same file, unmodified, to `src/fpga/pocket_utils/psram.sv`, which the script now reads by default; the results are the same, and `../../s4/run_psram_ctl.sh` runs this script as one of its checks (`../../s4/README.md`).

### PCM FIFO depth (synthetic ARSC, 100 ms)

| PCM depth, remap | Result |
|---|---|
| 512, none | Deadlock. The watermark (3,896) is truncated to 824, beyond a 512-frame FIFO. The prefill loop at 0x140–0x14c pushes into the full FIFO for good, and PCM is never enabled. |
| 512, remap | Runs. Watermark 312, PCM enabled 1.41 ms after release, steady level 311–510 |
| 1,024, none | Deadlock, as for 512 (watermark 1,848) |
| 1,024, remap | Runs. Watermark 824, enabled 1.53 ms after release, steady level 823–1,022, no overflow or underflow |
| 4,096, none (MiSTer) | Runs. Watermark 3,896, enabled 2.12 ms after release, steady level 3,895–4,094 |

### Yosys 0.69 (`synth_intel_alm -family cyclonev`)

| Design | LUT | Arithmetic | FF | MLAB | M10K | DSP |
|---|---|---|---|---|---|---|
| `p_shift` (shift and mask) | 332 | 7 | — | — | — | — |
| `p_shift2` (one rotator) | 192 | 239 | — | — | — | — |
| `p_alu` | 130 | 34 | — | — | — | — |
| `p_mul` (32 × 32 → 64, registered) | 0 | 160 | 64 | — | — | 4 |
| `p_ld` (load lanes) | 48 | — | — | — | — | — |
| `p_rf` (register file) | — | — | — | 64 | — | — |
| `p_pe` (LDM/STM priority encoder) | 42 | — | — | — | — | — |
| B's sketch CPU | 1,178 | 297 | 155 | 64 | 30 | 4 |
| A's sketch, flip-flop register file | 2,770 | 573 | 587 | — | — | 4 |
| A's sketch, MLAB register file | 1,673 | 585 | 123 | 192 | — | 4 |
| S1 core (`bup_cpu.sv`) | 1,885 | 453 | 311 | 64 | — | 4 |
| Peripheral, CMD 8 / PCM 1,024 | 54 | 59 | 57 | 8 | 4 | — |

LUT includes the NOT cells. The counts are repeatable, but ABC's mapping moves by a percent or two with incidental changes: reading the same S1 source by an absolute path gave 1,858 LUT. The script runs with `-noiopad`, and the sketch's ROM holds a fixed pseudo-random image, so the counts differ slightly from the study's logs:
- B's sketch: the study's last run gave 1,159 LUT, 297 arithmetic and 155 FF, with the firmware in its ROM.
- A's sketch: the study gave 2,865 / 572 / 587 (flip-flops) and 1,631 / 585 / 123 (MLAB), with I/O pads. These are the figures under "Register file" and "Totals" in the design document.

## Changes from the study's files

- **`tb_cpu.sv`:** the image comes from `+rom=` instead of a compiled-in path, and three debug printouts were removed.
- **`bup_asset_v1.sv`:** gained a `hit` wire, so that `tb_cpu.sv`'s statistics work with either version.
- **`cmp_ref.py`:** takes both traces as arguments.
- **Scripts:** `run_sketch.sh` replaces the study's `run4.sh`. One parameterised `tb_psram.sv`, which also counts writes, replaces four copies.
- **Headers:** each file gained a header with the licence.
- **Left out:**
  - v1 of the CPU sketch and its testbench (superseded);
  - proposal B's own cycle model (`../cycles.py` models it as `S1-sketch/stream`, CPI 1.387);
  - the study's firmware reachability scripts (`../inventory.py`);
  - the Yosys calibration runs on existing modules;
  - A's single-feature area variants;
  - every file made from the game or the firmware.
