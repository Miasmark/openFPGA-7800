# BupChip firmware model and cycle model

Python tools from the design study behind `docs/BUPCHIP_CORE.md`. They need
only Python 3; the inventory's objdump cross-check also uses
`arm-none-eabi-objdump` when it is installed. Game files and anything made
from them (PCM, batch CSVs) stay in `sim/work/` and out of git.

| File | What it is |
|---|---|
| `armdec.py` | ARMv4 decoder; loads the firmware from `src/fpga/mister/rtl/bupchip.hex` |
| `armemu.py` | The firmware on an ARMv4 interpreter with MiSTer's memory map and peripheral. Its PCM equals the MiSTer RTL's. |
| `cycles.py` | Trace-driven cycle model: cores S1, S2, S3, S3 fallbacks and MiSTer's reference; asset cache and stream buffer; PCM FIFO level |
| `inventory.py` | Static inventory: the 1,704 code words and every instruction form they use |
| `synth_arsc.py` | A game-free ARSC block built from the formats read out of the firmware |
| `coverage.py` | What the synthetic block exercises: 1,516 of 1,704 code words, all 21 bytecode handlers, all command classes, all three faults |
| `check.sh` | Regression: the game-free checks, and with a game the PCM against MiSTer's |

## Commands

From this directory, with Rikki & Vikki built by `make_arsc.py` as
`../../work/bupchip/game/rv.a78`, and the MiSTer references from
`run_bupchip.sh` in `../../work/bupchip/ref/`:

```sh
./check.sh                                    # game-free: about 15 s
./check.sh ../../work/bupchip/game/rv.a78     # plus each ref/song<N>.pcm, 10-65 s a song

./inventory.py                                # 0.1 s
./coverage.py                                 # 10 s
./synth_arsc.py ../../work/bupchip/model/synthetic.a78
./armemu.py ../../work/bupchip/model/synthetic.a78 --song 0 --secs 1 --pcm OUT.pcm

./armemu.py ../../work/bupchip/game/rv.a78 --song 13 --secs 4 \
    --pcm ../../work/bupchip/model/song13.pcm --ref ../../work/bupchip/ref/song13.pcm   # 65 s

./cycles.py --loops                           # mixer loops per iteration, instant
./cycles.py ../../work/bupchip/game/rv.a78 --song 13 --secs 4      # 5 min
./cycles.py ../../work/bupchip/game/rv.a78 --song 13 --secs 4 --run S3/cache S3/none \
    S3/cache-nopf S3/cache32 S3/cache128 S3/cache-t4 S3/nocache      # the asset-path table, 4.5 min
./cycles.py --synth loop --secs 0.0584 --run S1/cache S2/cache S3/cache   # 16 voices, 14 batches
```

`--batches FILE` writes every batch's clocks per core as CSV, for comparing
with an RTL run batch by batch.

## What the numbers are

`armemu.py --pcm` writes the frames in the order the FIFO plays them from
power-up: the boot's 4,000 silent frames, then the song. That is what
`tb_bupchip.sv` records, so the files compare from the first byte. All six
references (songs 6, 9, 10, 13, 14, 30; 191,984 frames each) are identical.
The synthetic block needs no game, so its RTL reference can be made anywhere:

```sh
WORK=$PWD/../../work/bupchip/model/rtl ../run_bupchip.sh ../../work/bupchip/model/synthetic.a78 0 1   # 1 min
./armemu.py ../../work/bupchip/model/synthetic.a78 --song 0 --secs 1 --ref ../../work/bupchip/model/rtl/song0.pcm
```

Songs 0 and 1 match for all 48,009 frames. The small block boots before the
command arrives, so the RTL has already played 33 prefill frames; `--ref`
skips up to the prefill to line the files up.

Results of `cycles.py` on Misery_F, 4 s (960 batches, 60.63 M work
instructions):

| Core / asset path | CPI | MHz at 100% busy: average / busiest 0.1 s / worst batch | Lowest clock without underrun | FIFO low at 21.477 / 21.281 MHz |
|---|---|---|---|---|
| S1 / stream | 1.387 | 21.02 / 21.72 / 24.27 (23.31 without the song-start batch) | 21.49 | — |
| S1 / cache | 1.377 | 20.88 / 21.48 / 24.07 | 21.24 | — |
| S2 / stream | 1.123 | 17.03 / 17.75 / 19.54 | 17.55 | 641 / 639 |
| S2 / cache | 1.103 | 16.72 / 17.18 / 19.29 | 16.99 | 643 / 642 |
| S3 / cache | 1.013 | 15.35 / 15.78 / 17.87 | 15.59 | 657 / 655 |
| S3-f1 / cache | 1.096 | 16.62 / 17.08 / 19.18 | 16.89 | 644 / 643 |
| S3-f2 / cache | 1.189 | 18.02 / 18.55 / 20.88 | 18.33 | 629 / 627 |
| S3-m10k / cache | 1.014 | 15.36 / 15.80 / 17.95 | 15.61 | 656 / 654 |
| ref / none | 2.299 | 34.84 / 35.86 / 40.04 | — | — |

- `stream` is proposal B's two-line stream buffer, the asset path of the RTL
  that measured S1 at CPI 1.383; `cache` is the design's 64 × 16 B cache.
- `docs/BUPCHIP_CORE.md`'s S2 figures (CPI 1.116) came from the study's
  variant with loads 1, LDM n+1, MMIO stores 2 and the stream buffer's
  stalls taken from S1's clock. S2 as the document defines it (S3 with
  2-clock MUL/MLA and register-offset stores) gives 1.103 with the cache.
- The model does not pre-empt a fill for a demand miss, and queues a
  prefetch behind the fill in flight (the design starts one only when idle).
- A load completes once every halfword it touches has arrived, as the design
  specifies; the study's model waited for the critical halfword only. The
  difference is 180 stall clocks in 4 s.
