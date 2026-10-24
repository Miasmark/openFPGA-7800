# openFPGA-7800

The MiSTer Atari7800 core ported to the Analogue Pocket. Start with
`docs/DEVELOPING.md` (layout, build, simulation, recipes, the release
checklist) and `docs/ENVIRONMENT.md` (setting up a container, working
conventions, known pitfalls).

Skills in `.claude/skills/`:

- `release-build`: fitting seeds 1-3, choosing the seed, packaging, release
  notes and landing a release or a hardware-test build.
- `debug-game-in-sim`: running a game in the whole-core simulation and
  finding why it fails.

Rules that always hold:

- **No game data, BIOS or firmware in git.** That includes traces,
  recordings and listings made from games. Keep them in `sim/work*`,
  `release/` or the scratchpad, which are all gitignored.
- **Clean room** (ENVIRONMENT 7.1): `arm7tdmi_core.sv` is a simulation
  oracle only. Don't open `/home/user/lroby74`. Stella's sources are for
  behaviour notes only.
- **Shared branches:** other sessions push to the same branches. Fetch and
  rebase before pushing, and never force-push.
- **Processes:** stop them with `kill <PID>`, never `pkill -f`. Write `rm`
  with literal paths.
- **Long jobs:** run them under `setsid nohup` with a log. Run Quartus
  under `flock /tmp/daria_quartus.lock`, one job at a time.
