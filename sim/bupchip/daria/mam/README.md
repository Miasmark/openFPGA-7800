# The Harmony model: tools and directed tests

A model of the timing of a real Harmony cartridge's chip, the NXP LPC2103, for the
2600 ARM calls. It is a reference beside MiSTer's core, not a gate. What it is,
the settings each game runs at, and its limits: [docs/HARMONY_MODEL.md](../../../../docs/HARMONY_MODEL.md).

The model itself is the "MAM timing estimate" block of `../tb_daria.sv`. It is
off unless a run passes `+mam=1`. This directory holds the tools that read its
output, two Python models that check it, and its directed tests.

## Running it on a game

```
DTRACE=0 sim/bupchip/daria/run_daria.sh IMAGE.bin +fp=1 +mam=1
python3 -I sim/bupchip/daria/mam/mam_analyze.py sim/work/bupchip/daria/runs/IMAGE --mhz 70 --cfg m2t4
```

- `+mam=1` adds columns to `calls.csv` after the existing ones (which do not
  change) and writes `mam_summary.txt`. `mam_<cfg>` is the call's cycles on the
  chip in one configuration: `est_arm7` plus the wait states the MAM adds. The
  chip's time is `mam_<cfg>` over the game's clock.
- Pass the game's own clock and MAM setting to `mam_analyze.py`
  (`docs/HARMONY_MODEL.md`, "Settings in force").
- `+mamtrace=N` also writes every access of the first N calls. Keep N small on
  a game: a whole run's trace runs to gigabytes.
- A 1,500-frame run takes about 50 minutes [measured: 2,966-3,069 s per image
  on 2026-10-18, and 3,136 s for Gorf on 2026-10-19, beside two other
  simulations].
- Everything a game run writes derives from the game. It stays in `sim/work`.

## Files

| File | What it does |
|---|---|
| `mam_analyze.py` | The report on one `+mam=1` run: totals, per-call ratios against upstream (and DARIA with `--daria`), late calls against the safe budget (`../dynamic_tables.py`'s rule) and the reference rule's two lists, wait categories, the `$FE` bound, the readings of the manual |
| `mam_model.py` | The bench's Python twin: the same rules as the bench, in Python |
| `mam_check.py` | Runs `mam_model.py` on a `+mamtrace` file and compares every access's waits and every retired instruction's I cycles with the bench's |
| `mymam.py` | The independent model, written from UM10161 chapter 4 apart from the bench's code |
| `mymam_check.py` | Runs `mymam.py` on `+mamtrace` files and compares it with the bench, access for access, in all ten configurations |
| `variants.py` | Other readings of the manual, with `mymam.py`, on a trace: how far the totals move |
| `acceptance.py` | Checks that `+mam` changes nothing else: `fp.csv` and `calls.csv` (in the reference's columns) against a reference run of the same image |
| `dirtests.py` | Builds the nine directed tests' images (synthetic CDFJ, no game data) with `../fe_dir`'s `mkimg.py` and `armenc.py`; its docstring works out each test's waits by hand |
| `dircheck.py` | Judges the directed runs against those hand-worked waits |
| `run_dir.sh` | Builds the images and the bench, runs the 18 directed images and judges them with `dircheck.py` and `mymam_check.py` |

## The configurations

Each configuration is a MAM mode and MAMTIM T. A flash read takes T cycles.

| Name | Mode | MAMTIM | Reading |
|---|---|---|---|
| `m1t3`, `m1t4` | 1 (partial) | 3, 4 | the bench's |
| `m2t3`, `m2t4` | 2 (full) | 3, 4 | the bench's |
| `*_na` | 1 or 2 | 3, 4 | an instruction miss waits for the prefetch in flight instead of aborting it |
| `m1t3_as`, `m1t4_as` | 1 | 3, 4 | "sequential" from the address, not from the bus cycle type |

Wait categories: `br` branch target, `ns` N fetch at the next address, `sx`
sequential fetch into a new line, `si` sequential fetch in the same line, `dr`
flash data read, `ot` the return into the driver.

## The directed tests

```
sim/bupchip/daria/mam/run_dir.sh [OUTDIR]
```

- Nine tests, each at two loop counts (N1 = 4, N2 = 8): 18 images, 5 frames each.
- Each test's waits per loop iteration are worked out by hand in
  `dirtests.py`, for all ten configurations. `dircheck.py` checks them, plus
  the categories, one absolute total, the `cfn` column and `mam_chk` = 0, and
  runs `mam_check.py` on every trace. `mymam_check.py` then runs the
  independent model on every trace.
- Pass: `9 tests, 0 failing` and `18 traces, 0 differing: ALL OK`, exit 0.
- `WORK` picks the bench's work directory, `NOBUILD=1` uses the bench that is
  there, and `RUNNER` is a command each simulation runs through (a slot
  wrapper, for example).
- The images are synthetic. The outputs still stay in `sim/work`.

Both Python models read the manual the same way as the bench. Their agreement
checks the code, not the reading.
