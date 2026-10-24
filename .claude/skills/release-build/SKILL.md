---
name: release-build
description: Build, choose the seed for, package and land a release or hardware-test build of the Pocket core. Use when asked to make a test build, a release, "pull to main", a new version, or when a change needs a Quartus fit (timing, seeds, ALMs), does not fit, or shrinks the margins.
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

The core is nearly full (each seed's ALMs are in the comment above `SEED`
in `ap_core.qsf`), so every change moves placement, and one seed is not
enough. Fit all three on the exact tree that
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
durable check-in with the session's `send_later` tool (about 30-45
min out) that says what is running, where its log is and what to do next.
When it fires: check the log and `ps`, restart dockerd and the remaining
seeds if they died, re-arm. Delete the check-in when all the fits are done.

Wait on a PID with `kill -0 <PID>`, not `pgrep -f` (a pattern containing
`+` is a regex and never matches). Stop jobs with `kill <PID>`, never
`pkill -f` (it matched the session's own shell and killed it, twice).

After a restart has killed a fit:

- The killed seed's run directory has no verdict but still holds its
  Quartus database (about 110 MB). Don't read its reports.
- Re-run only the seeds that died: the section 2 command with
  `for s in <the dead seeds>` and `FORCE=1` before `SEED=$s`, so they keep
  their `TAG`s. The driver replaces only run directories it made itself,
  and it writes `.step7_run` before the compile, so a killed run qualifies.
  Or delete the directory with `rm -rf` on its literal path. The finished
  seeds' verdicts stand.
- Apply trial patches in a copy of the tree (a `git worktree`), never in
  the checkout you are editing. The driver compiles a copy of `src/fpga`,
  but in the SNES study (2026-10) trials patched the study's checkout in
  place to save disk. A restart killed one mid-fit and left the checkout
  patched, and it had to be restored with `git checkout`.

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
- Hand-overs: when a note or report cites fit results, send the user the
  full Quartus reports it cites (`*.fit.rpt`, `*.sta.rpt`, `*.map.rpt`),
  not only a table of figures. Pack them with `tar -cf - <report files> |
  xz -6 -T4 > <name>.tar.xz` (172 MiB of the NES/SNES study's reports,
  patches and notes became a 7.3 MB archive) and send the archive as in
  section 5.

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

## 8. When a change does not fit, or the margins shrink

These were measured with this Quartus (21.1.1 Lite):

- on this core: the design study after 2.2.1. It is summarised in
  `docs/IMPROVEMENTS.md`; the study itself is not in the repository.
- on agg23's NES and SNES Pocket cores: a fit study in 2026-10. Its
  reports are outside the repository.

**Read the right number.**
- The fitter's "ALMs needed" is `[=A-B+C]`:
  - A: ALMs used in final placement;
  - B: minus what it estimates dense packing could recover;
  - C: plus the ALMs it counts as unavailable.
- What is really left shows in A and the LAB count. The NES all-in build
  needed 16,676 ALMs (90%), but 17,844 were placed (97%) and every LAB was
  in use.
- Fits move more than synthesis predicts: two NES builds 421 ALMs apart in
  synthesis fitted about 1,100 apart. Judge a few hundred ALMs on seeds 1-3
  (section 2), not on one fit.

**`MUX_RESTRUCTURE ON` is the lever that works.**
- It packs the same logic into fewer LUTs, so behaviour does not change.
- Here it saves 909-918 fitted ALMs on 13 `clk_sys` entities (in
  `ap_core.qsf`). It is kept off `bup_cpu`, which holds `clk_arm`'s
  critical path, as a precaution: it can lengthen paths. No study measured
  a loss.
- NES and SNES had it off for the whole design. Turning it on globally
  saved about 2,000 ALMs on NES and 2,200-2,700 on SNES at synthesis, and
  both still met timing.

**Settings that gave nothing:**
- Per-entity `OPTIMIZATION_TECHNIQUE AREA`, and on SNES per-entity
  `AUTO_RESOURCE_SHARING` too. No change here, on NES or on SNES. Here the
  study put it down to the global `OPTIMIZATION_MODE`, which all three
  projects set to "HIGH PERFORMANCE EFFORT".
- AGGRESSIVE PERFORMANCE, extra physical synthesis, placement effort 2.0,
  maximum router timing and final placement. No gain beyond seed noise
  here.
- The SNES fitter packing settings cost 114-146 ALMs.
- Fitter padding on `clk_arm` (0.3 and 0.8 ns) gave no gain that survived
  three seeds. The `clk_sdram` padding in `core_constraints.sdc` stays; its
  comment says why.
- LogicLock regions are not available in Lite (ENVIRONMENT 3.1).

**Synchronisers can become block-RAM shift registers.**
- On SNES, global `OPTIMIZATION_TECHNIQUE AREA` turned a 3-flop
  synchroniser into an `altshift_taps` M10K shift register.
- On NES, adding a 3-flop chain for runtime PAL (`pll_busy_s`) made Quartus
  fold it and six `synch_3` input synchronisers into one `altshift_taps`
  RAM. The builds with only the global area flags had none.
- A build like that must not ship. Whenever a global area setting is
  tried, or a synchroniser chain is added, set
  `AUTO_SHIFT_REGISTER_RECOGNITION OFF` on the synchroniser stages.
- After such a change, compare `grep -c shift_taps <project>.map.rpt` with
  the base build's. It must not grow.

**RTL patterns to look for in "Resource Utilization by Entity":**
- **A register array with several read and write ports.** The NES sprite
  evaluation (OAMEval) keeps the 256-byte OAM and the 64-byte secondary OAM
  in flip-flops, with about six read ports. That was 5,984 ALMs, a third of
  the device. Moved to LUT RAM (MLAB), they freed 5,399 ALMs on the shipped
  configuration.
- **A big constant table built in logic.** The SNES 65C816 microcode was
  about 1,030 ALMs in two copies. In M10K the two copies drop to about 45
  ALMs, for 22 more M10K. The net saving measured at synthesis was 464
  ALMs; the effect in a fit was not isolated.
- **Two pipelined dividers whose result is read many cycles later.** The
  SNES SPC7110's pair is 950-980 ALMs. Upstream's iterative SA-1 divider is
  about 200. An iterative SPC7110 divider has not been written; it is
  estimated to save about 750 ALMs.
- **The In-System Memory Content Editor** (`ENABLE_RUNTIME_MOD=YES`). It
  costs a JTAG hub plus 30-70 ALMs per memory. The hub measured 58-61 ALMs
  on NES, 157 on SNES and about 350 here. This core has had the editor off
  since 2.0.21 (`NO_MEM_EDITOR`).

Before an RTL change's fit counts, prove the change bit-exact against the
original module: a lockstep bench, plus mutants that show the bench can
fail.

**Constraints, whenever an SDC changes:**
- **Multicycles.** A two-clock multicycle is `-setup 2` with `-hold 1`.
  `-hold 2` moves the hold check a whole period back, so the real check
  silently disappears. This was copied from a fork in the SNES study.
- **Clock groups.** Clock groups and false paths must name the PLL
  instances of every build variant. In each variant's STA report, check
  that every clock appears in its group.
  - The SNES PAL build's PLL instance (`mf_pllbase_pal_inst`) did not match
    the groups in its SDC (`mf_pllbase_inst`).
  - Quartus ignored the groups and timed asynchronous crossings as
    synchronous, so that build's timing had never been analysed correctly.
- **Copied constraints.** Constraints copied from another core can name
  hierarchy that does not exist; SNES's named `ic|nes|...`. Quartus warns
  and ignores them, so read the STA's ignored-constraint warnings.
