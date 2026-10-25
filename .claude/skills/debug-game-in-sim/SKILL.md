---
name: debug-game-in-sim
description: Find out why a game misbehaves on the core (black screen, no sound, no speech, wrong mapping, wrong position) by running it in the whole-core simulation and reading what its CPU does. Use when the user reports a game that fails, sends a ROM to check, or asks whether MiSTer has the same bug.
---

# Debugging a game in the whole-core simulation

The bench is `sim/tb_load.sv`: the file goes through the real APF loader
into `atari7800_pocket`, as on the Pocket. Its option table is in
`docs/DEVELOPING.md` "Simulation"; the probes below are the ones that
found real bugs.

## 0. Keep the game out of the repo

ROMs, and the traces, frames and recordings made from them, never go in
git (ENVIRONMENT 7.2). Copy the user's upload into a run directory under
`sim/work*` (gitignored), never into a tracked path.

## 1. Read the header first

```sh
python3 -I tools/a78_info.py GAME.a78
```

The core maps POKEY, RAM, the HSC and the SaveKey/AtariVox only as the
header says. Many dumps have wrong headers (Commando's "missing music" was
one). A port 2 type of 10 or save bit 1 turns SaveKey Auto on, and the
AtariVox voice with it. A file with no `ATARI7800` header runs as a 2600
image.

## 2. Build tb_load once

```sh
WORK=sim/work_<name> BUILD_TOP=tb_load VERILATOR=/opt/verilator5/bin/verilator \
  sim/run_sim.sh
```

The build takes several minutes and writes `$WORK/obj_load/vtb`. Rebuild
it after any RTL change, and use one `WORK` per tree or flavour.

## 3. Run the game

Run from a fresh directory one level below `WORK` with `rtl` linked, as
`run_sim.sh` does (the MiSTer sources load `rtl/...` hex files):

```sh
mkdir -p sim/work_<name>/run1 && cd sim/work_<name>/run1 && ln -sfn ../rtl rtl
cp /path/to/upload/GAME.a78 game.a78
setsid nohup stdbuf -oL ../obj_load/vtb +image=game.a78 +wav=8000 \
  +cpuprobe +joyscript=s.txt > out.log 2>&1 < /dev/null &
```

- **Speed:** about 3.6 ms of game per second of wall time. 13 s of game
  took about 58 min, so keep runs short and run them detached. At most 3-4
  sims run at once (ENVIRONMENT 7.4).
- **`stdbuf -oL`:** without it, output stays buffered and the log looks
  empty for a long time.
- **`+wav=MS`** sets the run length and records `audio_raw.pcm` and
  `audio_filt.pcm` (48,052 Hz s16le mono).
- **`+joyscript=FILE`:** one line per event, `MS HEX` or `MS dump`.
  - `MS HEX` sets joy0 at MS ms after reset. Bits: 0 right, 1 left,
    2 down, 3 up, 9 A (fire 1), 10 B. `0200` presses fire, `0000`
    releases it.
  - `MS dump` writes the next whole frame as `frame_NNN.ppm`.
  - A title screen usually needs a press and a release, e.g. `4000 0200`
    then `4300 0000`.
- **Other frame options:** `+dumpat=MS +dump=N` with `+wav`.
- **Saves:** `+sk_on` or `+sk_auto` for the SaveKey; the default is off.
  `+hsc_on`, with `+hscfw=` for the HSC firmware.
- **AtariVox:** `+voxset=N` (0-3), `+voxlog` (the bytes the game sends) and
  `+voxpcm` (writes `vox.pcm`, 16,384 Hz s16le). The voice needs the
  SaveKey on. `docs/ATARIVOX.md` has the checks.
- **Pass/fail:** a frame "shows something" when any pixel is not black.
  Check with Python (`python3 -I`) rather than looking at every frame.
  Convert the frames to PNG to show the user.

## 4. Read what the CPU is doing

`+cpuprobe` prints:

- the first 300 MARIA register writes, and every CTRL write;
- 96 bus addresses at 1, 3 and 5 s, which show where the CPU is spending
  its time;
- the first 40 POKEY RANDOM reads, with the value on the bus.

Disassemble those addresses:

```sh
python3 -I tools/d78.py game.a78 <hex addr> 40 [--bank N]
```

`d78.py` maps the payload so it ends at $FFFF. For SuperGame carts, pass
`--bank N` to map bank N at $8000.

A loop that never ends usually waits on a value a device returns. Read the
loop, find which register it reads, and check what the core returns for
it. This is how Star Raiders found the POKEY read bug in 2.2.2: RANDOM
always read $FF, so a search for a free slot never ended. The bug was a
read strobe that was live only in o2, after the CPU had latched the data.

## 5. Cross-check

- **Stella:** run the same game in Stella 6.7.1, if installed, to see what
  the real behaviour is. `tools/atarivox/stella_voxlog.py` logs the
  AtariVox bytes through a pty, and `--snap` takes screenshots under Xvfb.
  Stella's sources are behaviour notes only, never code.
- **MiSTer:** the vendored MiSTer RTL is under `src/fpga/mister/`. Its
  edits are listed in `POCKET_CHANGES.md`. To judge whether MiSTer has the
  same bug, compare the wiring around the fault with upstream (nightly and
  release). Say "very likely", not "yes", unless it was run.

## 6. Fix and prove it

- **Add a check:** add the smallest test that shows the fix. That can be a
  unit test (like `sim/atarivox/starraiders.txt`, the game's opening bytes)
  or a probe line in `tb_load`. Make sure `run_sim.sh` still passes.
- **Re-run the game:** run it again and show the frame or sound that now
  works.
- **Hardware test:** then make a test build with the `release-build`
  skill.

## Pitfalls

- **Waiting on a run:** wait on its PID with `kill -0 <PID>`. A `pgrep -f`
  pattern containing `+` is a regex and never matches.
- **Stopping a run:** use `kill <PID>`, never `pkill -f`, which killed the
  session's own shell.
- **Helper script names:** a helper named like a stdlib module
  (`dis.py`, `json.py`) shadows it. Keep helpers in the session's scratch
  directory and run them with `python3 -I`.
- **No foreground sleep:** it is blocked. Long runs go under
  `setsid nohup` with a log, plus a `send_later` check-in if they outlast
  the session (see `release-build` step 4).
- **One process per log:** two `vtb` processes writing the same log
  corrupt it. Give each run its own directory.
