---
name: port-mister-core
description: Assess, port or refresh a MiSTer core for the Analogue Pocket, for a new core or for another author's Pocket core. Covers finding what a Pocket port is based on and what MiSTer changed since, checking licences component by component, measuring the fit, and deciding on bitstreams, PAL and save states. Use when asked whether a Pocket core is out of date, to plan or start a port or rebuild, to make a core fit in fewer bitstreams, or to check that code may be reused.
---

# Porting or refreshing a MiSTer core for the Pocket

This skill is the method, with what went wrong before. Results belong in a
report, not here: they go stale quickly.

The rules of this repository still hold:
- the clean room (ENVIRONMENT 7.1);
- no ROMs, BIOS or game-derived data in git (7.2);
- one Quartus job at a time, under the lock (3.5).

Work in other people's repositories is reading only. Open an issue or pull
request there only when the user asks.

## 1. Reading other repositories

Use anonymous git, as bare blobless clones: commits and trees, no file
contents until asked for.

```sh
GIT_LFS_SKIP_SMUDGE=1 timeout 600 git clone -q --bare --filter=blob:none \
  https://github.com/<owner>/<repo> <scratch>/<owner>__<repo>.git
```

**Safe commands:**
- `git log --no-renames --name-status`. Without `--no-renames`, rename
  detection fetches both sides of every inexact rename. A MiSTer release
  that deletes the old `.rbf` and adds a new one looks like one.
- `git ls-tree` (no `-l`).
- `git rev-parse <rev>:<path>`, which gives blob ids for free.
- `git rev-list <rev> -- <path>`.
- `git show <rev>:<path>` and `git diff <a> <b> -- <path>` on small text
  files.

**Never on a blobless clone.** These fetch every blob they touch. One
`ls-tree -r -l` on a documentation repository pulled about 640 MB and took
the disk below its floor.
- `git ls-tree -l`;
- `git log -p`, `--stat` or `--numstat` without one narrow path;
- `git show` without a path;
- `git grep` over history;
- `git archive`, or `cat-file --batch` fed blob ids.

**Clone and disk discipline:**
- Make one clone at a time. An HTTP 429 is the session's own concurrency
  cap, not GitHub's limit: retry once, in the next command.
- Check `df -m /` before each clone.
- Delete clones on their literal path when done.
- In a bare blobless clone, `git log` reads the `.mailmap` file at `HEAD`
  if there is one: one small fetch, which is harmless.
  `-c log.mailmap=false` avoids it.

## 2. Is a Pocket core out of date?

**Sources:**
- The inventory, `openfpga-cores-inventory/analogue-pocket`: each core's
  `_data/cores/<id>.yml` lists every release with its date and version,
  and the core's platform ids and `sleep_supported`.
- "Inactive" was taken as no release in 12 months.

**Traps:**
- **A release date is not a code date.** Compare the release with the
  newest commit and the newest tag of the core's repository. In 2026-10,
  three "active" cores were re-publications of 2023-2024 code.
- **Ids are messy.**
  - Duplicate ids (case or space variants) look inactive.
  - One core's id recorded another project's builds: in 2026-10, 10 of
    boogermann.msx's 12 releases were plasticbugs' MSX2.
- **Some repositories hold only a README.** The core is a closed binary:
  MiSTer commits cannot be applied to it, and updating it means a new port.
- **Look for alternatives beyond the same platform id:**
  - jotego's cores;
  - forks that are not in the inventory, such as drizzt's SNES nightly;
  - Analogue's own adapter cores.

  An active alternative that already has the MiSTer work makes an update
  worth little.

## 3. The base point, and what MiSTer changed since

**Find the base point by blob id.**
- For a core file present in both repositories, list the MiSTer commits
  that set the file to the Pocket's blob id.
- The two paths usually differ. agg23's ports keep MiSTer's `rtl/` under
  `rtl/upstream/`, and this repository keeps it under `src/fpga/mister/`.

  ```sh
  P=<pocket clone>; M=<MiSTer clone>
  pp=<path in the Pocket repository>; mp=<its path in MiSTer's>
  b=$(git -C "$P" rev-parse "HEAD:$pp")
  for c in $(git -C "$M" rev-list HEAD -- "$mp"); do
    [ "$(git -C "$M" rev-parse "$c:$mp" 2>/dev/null)" = "$b" ] && echo "$c"
  done
  ```

- The base point is at or after the newest hit, and before that file's
  next change in MiSTer. Intersect a few files to narrow it.
- Reformatted or CRLF files never match. Compare `git hash-object` of the
  `tr -d '\r'` text instead; this fetches the blobs, so keep it to small
  files.
- With no match, take the Pocket's first release date and say so.

**Sort MiSTer's commits since the base point:**
- core RTL;
- `sys/` (the MiSTer framework: none of it applies);
- `releases/` (binaries);
- docs.

**Read the top-level `<core>.sv` changes too.** Trees synced by a job that
copies only `rtl/` miss them. agg23's SNES never received MiSTer's SDRAM
refresh wiring this way.

**Ask of each fix whether the Pocket ever had the bug.**
- Many 2026 MiSTer commits repair regressions from MiSTer's own rewrites,
  for example M72's new CPU and NeoGeo's synchronous redesign.
- MiSTer features built on the HPS or DDR3 do not carry over as they are:
  cheats, rewind, renderers, the OSD, MiSTer's DDR3 save-state storage and
  file streaming such as MSU-1. Save states can be rebuilt on Pocket memory
  (section 6).
- The DE10-Nano has more than twice the logic (41.9K against 18.5K ALMs)
  and more block RAM (about 5.6 against 3 Mbit).

**Treat upstream code that says it was AI-assisted with extra care.**
MiSTer's 2026 Game & Watch SM5xx work says it was, and its README reports
about -0.4 ns of setup slack. The Pocket's FPGA is a slower speed grade
than the DE10-Nano's, so review that code and re-time it here.

## 4. Licence and provenance, component by component

Do this before porting. Record evidence, not impressions. This is not
legal advice; state what the evidence shows.

1. **Repo level.**
   - Check whether a licence file ever existed:
     `git log --all --no-renames --format= --name-only | grep -iE 'licen|copying|notice' | sort -u`.
   - A repository with none grants nothing beyond viewing and forking,
     even inside MiSTer-devel.
   - Authors differ from core to core. Never assume GPL.
2. **Per file.**
   - Read the headers.
   - Trace anything that looks borrowed (tables, comment text, helper
     code) to its source:
     - identical blob ids;
     - identical excerpts with line numbers;
     - commit messages;
     - the author's other projects.
   - Shared hardware facts (register maps, chip constants, bit layouts,
     pin names) are not evidence of copying.
3. **Version compatibility.**
   - This repository ships GPL-3 parts (`THIRD_PARTY_NOTICES.md`), and a
     core built the same way needs code that can sit beside GPL-3.
   - GPL-2-only code cannot. Ask authors to name GPL-2.0-or-later or
     GPL-3.0 explicitly.
4. **Credits.** Keep the credit for anything taken from an emulator (jzIntv,
   MAME, FreeIntv) and the notice a BSD-style licence asks for. Replace
   small uncredited fragments if that is easier.
5. **References and data.**
   - Service manuals, schematics and chip datasheets are the preferred
     references. Cite them, but never put them in the repository.
   - Code printed in documents (BIOS listings) is reading material only.
   - System ROMs stay user-supplied. Never build them into a bitstream.
     Until 2021-04-28 (9438b4d), Intv_MiSTer's build did, through a local
     `genrom.py` that compiled the user's ROMs into an uncommitted
     `rom_pack.vhd`. Don't port from a revision before that.
6. **Without a grant, rebuild clean.** Keep the unlicensed code apart from
   the new one. Use the hardware facts, the public-domain lists and the
   credited tables.

## 5. Measuring the fit

1. **Baseline.** Fit the shipped configuration(s) with the project's own
   flow, in `raetro/quartus:21.1` (Quartus 21.1.1 Lite, ENVIRONMENT 3.2)
   under the lock. Note the version the other project names. Record:
   - ALMs needed and placed, LABs, M10K, DSP;
   - setup and hold slack per clock;
   - the top of "Resource Utilization by Entity".
2. **The gap.** Run synthesis with everything enabled (`quartus_map`, a
   few minutes), then a fit attempt. A failed fit's "ALMs needed" is the
   pre-placement estimate, and says how far over the device it is.
3. **Levers.** Use `release-build` section 8: what works, what does
   nothing, the synchroniser trap, the RTL patterns with their bit-exact
   proof, and the constraint checks.
4. **Trials.** Fit each change as its own patch in a copy of the tree,
   then stack the ones that work.
5. **Re-check.** A second reader takes every figure from the report files,
   not from the trial's summary.
6. **The fit wrapper.** For another core, write one wrapper and run every
   compile through it under `flock "$QUARTUS_LOCK"` (ENVIRONMENT 3.5; no
   script takes the lock itself). It:
   - refuses to start below a disk floor;
   - names its container (`docker run --name`), and runs `docker stop` on
     it if free space falls below a lower floor;
   - copies the reports;
   - deletes the Quartus database. A full fit's database is about 110 MB
     on this core.
7. **After a restart:** as in `release-build` section 4. A killed run has
   no verdict. Delete its run directory on its literal path, or re-run it,
   and keep the finished runs.

## 6. Bitstreams, PAL and save states

**What limits:** ALMs and LABs. M10K, DSP and PLLs rarely do.

**Use a second bitstream with chip32 selection per game when one block is
large, used by few games, and identifiable from the header.** SNES's
SPC7110 is about 4,000 ALMs for three Japan-only games. Players never see
the split. The cost is another CI fit that must keep passing, and a loader
table to keep current.

**Never split for PAL. Switch the PLL at runtime instead.** This core does
it in `src/fpga/core/pll_region.v`.
1. **Keep the VCO at 600 MHz or more in both standards.** The fit report's
   PLL Usage Summary gives "PLL VCO Frequency". "PLL Freq Min Lock" times
   (M + K/2^32) / N is the 600 MHz floor.
2. **Pick common counters.** Choose M and the C counters so both standards
   fit, then switch only the fractional K. Every output keeps its ratio and
   phase that way. An earlier NES attempt changed M and C, broke the
   90-degree output and was reverted.
3. **Check the reconfiguration controller's clock.**
   - It must be one the PLL does not generate, and it must meet timing.
   - This core runs it on `clk_74a`.
   - On NES that failed timing (-0.441 ns), and it was moved to the audio
     master clock.
4. **Hold the core in reset while the PLL is busy.** Never start a retune
   during a data-slot load; `pll_region.v` says why. Guard any new
   synchroniser chain (`release-build` section 8).
5. **Regenerate the PLL with `ip-generate`** (DEVELOPING.md, "Regenerate
   the PLL"). Don't hand-edit its parameter list.

**Design save states in from the start:**
- Every register and RAM must be reachable for save and restore.
- MiSTer's save states usually stream to DDR3; the Pocket has SDRAM,
  PSRAM and SRAM.
- The state muxes are big, so budget for them before the fit is full.
  - drizzt's SNES save states add 4,754 ALUTs (17%) at synthesis to the
    CX4+GSU+SA-1+DSPn build, which then needs 21,584 ALMs (117%).
  - NES spends about 960 ALMs on its state registers.
- Declare `sleep_supported` in `core.json` only when save and restore
  work.

## 7. Handing results over

- Say per figure whether it was measured, estimated or read from code.
- Say plainly what was not run on hardware.
- Ship the report together with its patches and the full Quartus reports
  it cites (`release-build` section 6).
- Name people by handle, and use they/them.
