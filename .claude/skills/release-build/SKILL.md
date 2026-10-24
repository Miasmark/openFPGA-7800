---
name: release-build
description: Build, choose the seed for, package and land a release or hardware-test build of the Pocket core. Use when asked to make a test build, a release, "pull to main", a new version, or when a change needs a Quartus fit (timing, seeds, ALMs).
---

# Release and test builds

The full checklist is `docs/DEVELOPING.md` "Before a release"; the
machine is described in `docs/ENVIRONMENT.md` (sections 3, 7 and 8). This
skill is the order to do it in and what went wrong before.

## 1. Before any fit

- `sim/run_sim.sh` passes (`VERILATOR=/opt/verilator5/bin/verilator` if the
  one on PATH is not 5.040; ENVIRONMENT 8.5). Run it under `setsid nohup`
  with a log, never in the foreground (2-hour cap, restarts kill children).
- `BUP_DEBUG` is out of `src/fpga/ap_core.qsf` for a release (test builds
  may keep it), and `BUP_DEBUG=0 sim/run_sim.sh` passes.
- `docker info` works; if not, restart dockerd as ENVIRONMENT 3.3 says (it
  is down after every container restart).
- `df -h /` has room: a fitted tree with its database is about 150 MB.

## 2. Fit seeds 1, 2 and 3

The core is at about 86% ALMs and 96% LABs, so every change moves
placement, and one seed is not enough. Fit all three on the exact tree that
will ship, with the step-7 driver, under the Quartus lock, detached:

```sh
export QUARTUS_LOCK=/tmp/daria_quartus.lock
setsid nohup flock "$QUARTUS_LOCK" bash -c 'for s in 1 2 3; do
  SEED=$s TAG=<name>_s$s sim/bupchip/quartus_probe/step7/run_step7.sh; rc=$?
  [ $rc = 0 ] || [ $rc = 3 ] || exit $rc; done' > sim/work/<name>_fits.log 2>&1 < /dev/null &
```

- Exit 0 pass, 3 a check failed (keep going to the next seed), 1 compile
  failure, 2 refused. Each fit takes 12-25 min. Output lands in
  `sim/work/step7/fit/<TAG>/`.
- Clock names in the reports: PLL `counter[0]` is clk_sys (14.32 MHz),
  `counter[1]` clk_sdram (57.27 MHz, the SRAM/SDRAM margin), `counter[3]`
  clk_arm (DARIA). DARIA's guard pair (`pd_tog` -> `pd_rx`, a 6 ns window) is
  gated at ÷18 and only reported at ÷19.
- One Quartus job at a time, machine-wide. Up to 3 sims may run alongside
  (ENVIRONMENT 7.4).
- Without the step-7 driver (a non-DARIA question, or a quick size check),
  copy the tree per seed and compile it as CI does:
  `tar -C . -cf - src/fpga | tar -C sim/work_<x>/q_seed$s -xf -`, set
  `SEED` in the copy's qsf, then under the lock
  `docker run --rm -v $PWD/sim/work_<x>/q_seed$s:/build -w /build/src/fpga raetro/quartus:21.1 quartus_sh --flow compile ap_core`
  (about 27 min). Read the slack per clock from
  `output_files/ap_core.sta.rpt`; you check the gates yourself then.

## 3. Pick the seed (plan P12, as amended by the owner)

Ship the seed of 1-3 that passes **every gate and every step-7 check**, and
among those the one with the most **clk_sdram** margin. Record all three
seeds' figures in the comment above `SEED` in `ap_core.qsf` (keep the
history lines; say which release chose what and why). Setting `SEED` to a
seed already fitted refits nothing: take that seed's `.rbf` from its run
directory. If no seed passes, stop and tell the user, with the failing
path and figures. Don't loosen a constraint.

## 4. Watch the fits so a restart doesn't lose them

Container restarts kill background jobs and the session's waiters. Arm a
durable check-in with `mcp__Claude_Code_Remote__send_later` (about 30-45
min out) that says what is running, where its log is and what to do next.
When it fires: check the log and `ps`, restart dockerd and the remaining
seeds if they died, re-arm. Delete the check-in when all the fits are done.

Wait on a PID with `kill -0 <PID>`, not `pgrep -f` (a pattern containing
`+` is a regex and never matches). Stop jobs with `kill <PID>`, never
`pkill -f` (it matched the session's own shell and killed it, twice).

## 5. Package

- Put the chosen `.rbf` at `src/fpga/output_files/ap_core.rbf`, then
  `tools/package.sh` writes `release/Atari7800_Pocket_<version>.zip`
  (`release/` is gitignored; the user uploads releases themselves).
- A release that ships a hardware-tested build must ship **that** bitstream:
  check that `Cores/Miasmark.7800/atari7800.rbf_r` in the new zip is
  byte-identical (`cmp`) to the one in the tested zip, and say so in the
  notes ("ships the bitstream of the hardware test build unchanged").
- Version: `dist/Cores/Miasmark.7800/core.json` (version and date). A
  hardware-test build keeps the version it was built from and gets a
  distinct zip name (e.g. `..._2.2.1-starraiders-test.zip`).
- Send the zip to the user with `SendUserFile` (display `attach`).

## 6. Docs and notes

- README: features, the verification table, hardware results, build
  figures (ALMs, M10K, the margins of the shipped seed).
- `src/fpga/mister/POCKET_CHANGES.md` for any edit to upstream MiSTer files.
- Third-party files: `THIRD_PARTY_NOTICES.md`, and check `package.sh` ships
  their licence text.
- Release notes go in `release/RELEASE_NOTES_<version>.md` (gitignored).
  The house style is in the earlier ones there: one summary paragraph, then
  `##` sections of bold-led bullets in plain words (what was wrong, why,
  what changed), "Under the hood" with the seed figures, "When upgrading",
  "Tested on hardware" with the date, "Licenses", and the Full Changelog
  compare link. If the user supplies notes, edit theirs; don't replace them.

## 7. Land it

- Work on the branch the session names. The branches are shared with
  other sessions (the DARIA side pushes too): `git fetch` and
  `git rebase origin/<branch>` before every push. Never force-push. Retry a
  502 or other network error with backoff.
- "Pull to main" means a PR to `main`, opened only when the user asks.
  The PR body follows the session's attribution rules. After it merges,
  restart the branch from the new `main` for the next piece of work.
- Never commit ROMs, BIOS, firmware, or traces and recordings derived from
  games (ENVIRONMENT 7.2). Game files stay in the scratchpad or `sim/work*`.
