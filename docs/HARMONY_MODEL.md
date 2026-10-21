# The Harmony model: a timing reference for the 2600 ARM calls

A real Harmony cartridge runs its ARM code on an NXP LPC2103. This is a model
of that chip's call timing, in the simulation bench only. It sits beside
MiSTer's core as a second reference for how long each ARM call takes. Nothing
in the core uses it, and no gate reads it.

- **Where it is:** the "MAM timing estimate" block of
  `sim/bupchip/daria/tb_daria.sv`, off unless a run passes `+mam=1`. The tools
  and the directed tests are in `sim/bupchip/daria/mam/`
  ([README](../sim/bupchip/daria/mam/README.md)).
- **What it is not:** a measurement. It has never been checked on silicon.

## Why it exists

The owner, 2026-10-18: *"if you still have the simulation of the harmony
actual chip around we may start using that as a reference"*.

The model was written on 2026-10-15 in a scratch copy of the bench
([daria_step7/progress.md](daria_step7/progress.md), "Audio against a real
Harmony (2026-10-15)"). The Spiders follow-up used it on 2026-10-18. It
entered the repository on 2026-10-19.

## The reference rule

The owner, 2026-10-18: *"if the real chip meets the calls but the mister does
not, I would rather go with the chip."*

The project applies it as two cases:
- Where the chip meets a call that MiSTer misses, DARIA must be on time.
- Where the chip misses a call, matching MiSTer's miss is fine.

**Where each case arises today** [measured: model, the Spiders follow-up,
2026-10-18; its files derive from games and stay out of the repository]:
- **The first case: Spiders' 16 late calls only** (frames 557-572). At
  Spiders' settings (70 MHz, mode 2, MAMTIM 4) the modelled chip takes 91.6-92.0%
  of each call's safe budget. MiSTer's core holds the 6507 for 109.8%. 2.2.1 at
  ÷19 is late on the same 16 calls, as MiSTer is (progress.md, c77). The
  release after 2.2.1 (÷18, the L1W+L3 CPU) is on time on them, as the rule
  asks: frames 557-572 stay 262-line frames (`frame_gate.py --overrun ontime`,
  its default; `docs/DARIA_CORE.md`, decision 7).
- **The second case: nowhere found.** Seven images were modelled, 20,984 calls
  with a budget. Five ran at their settings in force (Spiders, Qyx, Gorf, Lady
  Bug and Zoo Keeper). Elevator Agent and Zaxxon have no settings in force (no
  Harmony runs them, below), so they ran at 60 MHz, mode 2, at both MAMTIM 3
  and MAMTIM 4 (`m2t3` and `m2t4`). None has a call the modelled chip misses;
  the closest is Zaxxon at 96.5% in `m2t4`. MiSTer misses no call outside Spiders' 16.
- The other 14 traced images were not simulated. An estimate puts none of them
  above 82% on the chip [estimated: the worst call's zero-wait share times a
  margin above the largest MAM factor seen].

**Whether the model is enough evidence** for this rule was the owner's
question. Settled on 2026-10-21: *"no harmony cart, we operating on the
model."* So the model stands as the evidence, and the check on a real
cartridge below ("A check on silicon") will not run unless a cartridge comes
to hand (`docs/daria_step10/plan.md`, decision 5).

### The owner's YouTube observation

The owner, 2026-10-19: *"Also I looked at youtube gameplay and saw no indication
of any frame issues during any of them, maybe emulated though."*

The owner's own hedge stands. Who recorded the videos, and on what, is not
known. A video recorded on an emulator shows that emulator's timing, not the
chip's. So this supports the model's answer, but it is not a measurement of
the chip.

## Source

- **NXP UM10161**, the LPC2101/02/03 user manual (rev. 01, 2006), **chapter 4**:
  the Memory Accelerator Module (MAM).
- Also read: the LPC2101/02/03 data sheet (rev. 04, 2009) and the Harmony BIOS
  1.06 (the public `hbios_ntsc.bin` of the HarmonyCart tool). The owner supplied
  all three. None of them is in the repository.

**What the model does** (the block's comment has the full rules):
- One flash bank behind the MAM. A flash read takes MAMTIM cycles (MAMTIM - 1
  wait states).
- Three 16-byte latches: the prefetch buffer, the branch-trail buffer and the
  data buffer. One prefetch of the next line at a time.
- A flash data read aborts the prefetch, which restarts after it.
- Mode 1 (partial) charges every non-sequential fetch and every flash data read
  a full read. Mode 2 (full) serves a latch hit in one cycle.
- SRAM and MMIO add no wait. The return into the driver costs one flash read.
  Each call starts with the MAM cold.
- **The access stream is the bench's own ARM core** (upstream's ARM7TDMI model):
  every fetch, data read and data write it makes in a call, with its S/N cycle
  type, and each instruction's internal cycles. With no waits this timeline
  equals `est_arm7` on every call (`mam_chk` = 0).
- **Ten configurations:** modes 1 and 2 at MAMTIM 3 and 4, plus two other
  readings of the manual: an instruction miss that waits for the prefetch in
  flight (`_na`), and in mode 1 "sequential" taken from the address (`_as`).
- **Per call:** `mam_<cfg>` = `est_arm7` + that configuration's wait states.
  The chip's time is `mam_<cfg>` over the game's clock.

## Settings in force, per game

From progress.md (2026-10-15). The Harmony's crystal is 10 MHz, and BIOS 1.06
runs the PLL at 70 MHz.

| Game | ARM clock | MAM during calls | Why |
|---|---|---|---|
| Gorf | 60 MHz | mode 2, MAMTIM 4 (`m2t4`) | its own start-up runs |
| Galagon, Lady Bug, Mappy, RobotWar, Wizard of Wor | 60 MHz | `m2t3` | its own start-up runs |
| Qyx, Tutankham, Spiders, Scramble | 70 MHz | `m2t4` | the entry skips the game's start-up, so the BIOS settings stay |
| Super Cobra, Zoo Keeper | 70 MHz | `m1t4`: the driver sets partial mode around each call | as above |
| Elevator Agent, Turbo, Zaxxon | 60 MHz | none established | no Harmony runs them (below) |

- Scramble's game code also sets partial mode in one function.
- Images outside this table (SF2fix, the Draconian builds, RobotWar Harmonyfix,
  spacerocks) have no established settings.

## Limits

- **Never checked on silicon.** The bench and two Python models agree access for
  access, but all three read the same manual. Their agreement checks the code,
  not the reading.
- **The prefetch rules decide the margin.** On Spiders' 16 late calls, a bracket
  model written from the MAM's general shape gives [measured: model, the
  Spiders follow-up]:
  - ideal prefetch: 89.5-89.9% of the safe budget;
  - a full wait for the prefetch in flight on every flash data miss: 97.5-97.9%;
  - the same on every data and instruction miss: 102.9-103.4%;
  - no prefetch at all: about 107%, which contradicts the manual.

  Ten readings of the manual in mode 2 at MAMTIM 4 (the bench's configurations
  and `variants.py`'s) give 90.3-93.2%.
- **MUL is charged m = 2** (one S and two I cycles, as `est_arm7`). Each of
  Spiders' late calls has 723-729 MULs [measured: the follow-up's profiler,
  per call]. m = 1 would move the chip's share by about -0.57 points, m = 4 by
  about +1.14 to +1.15 points [estimated: one I cycle less, or two more, per
  MUL at 70 MHz, against each call's safe budget; not a model run].
- **The settings rest on an inference:** that BIOS 1.06 jumps to the entry in
  the image header, past the game's own start-up. This was read from the BIOS,
  not seen on a cartridge.
  - It matters most for Spiders. If its own start-up ran (70 MHz, MAMTIM 3), the
    chip would take 86.0-86.4% on the 16 calls: still on time.
  - At 60 MHz, or in partial mode, the chip would miss them (106.8-108.6%).
    Neither setting is in force for Spiders.
- **The driver is not modelled:** its entry, its exit and the NOP/JMP hand-back
  to the 6507. A 5 µs allowance for them gives at most 92.2% on Spiders' 16
  calls [estimated].
- **Other boards.** Elevator Agent, Zaxxon and Turbo have more ARM code than the
  LPC2103's 32 KB of flash, so they need an LPC213x board (Melody). The LPC2103
  model only stands in for the first two. Turbo has no model run at all.
- **Not modelled either:** the timer interrupt of `$FE` calls
  (`mam_analyze.py` gives a bound), wait states on the peripheral bus, and
  whether upstream's core announces S and N cycles as an ARM7TDMI-S does.

## A check on silicon

The owner can check the model on a real cartridge, with no build:
- Run Spiders on a real Harmony or Harmony Encore on a 2600, and note its BIOS
  version. The model assumes BIOS 1.06's 70 MHz, mode 2, MAMTIM 4.
- Play to the first level load, about 9 s in (frames 557-572).
- **No picture shift or roll:** the chip meets the calls, as modelled.
- **A shift:** the chip misses them. The model or its settings are then wrong
  for these calls, and the reference rule's second case applies.

## Using it

```
DTRACE=0 sim/bupchip/daria/run_daria.sh IMAGE.bin +fp=1 +mam=1
python3 -I sim/bupchip/daria/mam/mam_analyze.py sim/work/bupchip/daria/runs/IMAGE --mhz 70 --cfg m2t4
```

- Give `mam_analyze.py` the game's own clock and configuration (the table
  above). Its section 3 lists the calls under each case of the reference rule.
- A 1,500-frame run takes about 50 minutes [measured: 2,966-3,069 s per image,
  2026-10-18].
- Everything a game run writes derives from the game. It stays in `sim/work`.
- The directed tests: `sim/bupchip/daria/mam/run_dir.sh` (the README).

## How it was checked

- **2026-10-15** (progress.md): Gorf's `+mam=1` run equals the plain bench's on
  every existing column. The independent model agrees on every access over
  Gorf's first 30 calls (403,217 accesses) and 18 directed traces.
- **2026-10-18:** on a 62-call sample of Spiders that holds the 16 late calls
  (1,663,852 accesses), the independent model agrees with the bench on every
  access in all ten configurations.
- **2026-10-19, the block as committed** [measured]:
  - **`+mam` off changes nothing.** Gorf for 300 frames on the bench before
    and after the block: `calls.csv`, `fp.csv`, `frames.csv`, `slack.csv`,
    `zero.csv`, `summary.txt` and `pcs.txt` identical. Mode B through the
    wrapper (`MODE_B=1 WRAPPER=1 WIN_KB=64`, Galagon, 60 frames): every output
    file identical, and both runs `MODE B result: PASS`.
  - **`+mam=1` reproduces the scratch run.** Gorf for 1,500 frames:
    `mam_summary.txt` and every column of `calls.csv` equal the scratch bench's
    run of 2026-10-15, for example `est_arm7` 64,185,985 and `m2t4` 77,638,287
    cycles. The columns the bench had before equal the plain bench's run, and
    so does `fp.csv`.
  - **The directed tests:** 9 of 9 pass in all ten configurations, and the
    independent model agrees access for access on all 18 traces.
  - `sim/lint_step7.sh` adds no warning in any set, on the AtariVox lint fix
    (6e2e880) with this block added.
