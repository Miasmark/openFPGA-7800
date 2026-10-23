# Development environment: setting up a fresh cloud container

This file is for a Claude session in a new Claude Code cloud container that has to rebuild the tools and run the openFPGA-7800 benches. It is based on a read-only inventory of the container taken on 2026-10-09, with the repo on branch `DARIA-dev` at `2f77969`. It was fact-checked the same day.

[docs/DEVELOPING.md](DEVELOPING.md) is still the reference for the core itself: its layout, build macros, the Quartus build, PLL regeneration and releases. This file does not repeat that material. Section 9 lists what this file adds and which statements in DEVELOPING.md are out of date.

**On the self-hosted VM, read section 11 first:** it lists where that machine differs from the container this file describes.

Markers:

- **[untested]**: worked out from the history and the scripts, but never run in a fresh container.
- **[not recorded]**: the inventory did not capture this detail. Read the named script or ask the user.
- **[E]**: an estimate.
- **[R]**: second-hand, for example from the session history rather than a file.

## 1. Quick start

Work from `/home/user/openFPGA-7800` unless a step says otherwise. The order comes from the apt history, the session transcripts and the scripts. Nobody has run it end to end in a fresh container **[untested]**.

```sh
# 0. Orientation
git status -sb                                 # expect DARIA-dev tracking origin/DARIA-dev
df -h /                                        # the Quartus image needs 18.6 GB (section 8.3)

# 1. System packages (an apt-get update may be needed first [not recorded])
apt-get install -y verilator iverilog gcc-arm-none-eabi binutils-arm-none-eabi ghdl git autoconf flex bison help2man libfl-dev ccache make g++ perl dasm zip libpng-dev

# 2. Verilator 5.040 into /opt (about 4 min). Clone outside the repo.
#    Same steps as sim/bupchip/setup_dev.sh:16-18, which clones into a mktemp
#    directory and builds in a (cd ... && ...) subshell.
git clone --depth 1 --branch v5.040 https://github.com/verilator/verilator
cd verilator
autoconf
./configure --prefix=/opt/verilator-5.040
make -j$(nproc)
make install
/opt/verilator-5.040/bin/verilator --version   # expect: Verilator 5.040 2025-08-30 rev v5.040

# 3. Python, from the repo root
python3 -m venv sim/work/bupchip/venv
sim/work/bupchip/venv/bin/pip install -q 'unicorn==2.1.1'
sim/work/bupchip/venv/bin/pip install -q yowasp-yosys
pip install --quiet pillow

# 4. Docker daemon, then the Quartus image (the pull took about 2 min 11 s)
#    Set D to a writable directory outside the repo first.
setsid nohup dockerd > $D/dockerd.log 2>&1 < /dev/null &
until docker info > /dev/null 2>&1; do sleep 2; done   # sketch; the original poll loop was [not recorded]
timeout 580 docker pull raetro/quartus:21.1

# 5. Ask the user for the BupChip firmware and the game images (sections 5.2 and 5.4).

# 6. Build the 7800 OpenBIOS (section 5.3). The dasm line is the source repo's own
#    Makefile command; it reproduced the expected md5 here. The clone step is [untested].
git clone --depth 1 https://github.com/7800-devtools/7800openbios /home/user/7800-devtools/7800openbios
git -C /home/user/7800-devtools/7800openbios rev-parse HEAD   # must be b8bc745a8744ae3e0d24cc151e63f669f6a87c24
mkdir -p sim/work/bupchip/bios/openbios_build
dasm /home/user/7800-devtools/7800openbios/7800openbios.asm -f3 -v0 -I/home/user/7800-devtools/7800openbios \
  -osim/work/bupchip/bios/7800openbios.bin -lsim/work/bupchip/bios/openbios_build/7800openbios.list.txt

# 7. First simulation
VERILATOR=/opt/verilator-5.040/bin/verilator sim/run_sim.sh
```

Notes:

- **Step 1** combines the three recorded apt commands (section 2.3). It also adds `zip` and `libpng-dev`, which are installed here but whose installation was not recorded.
- **Step 3.**
  - The original unicorn lines are in `sim/bupchip/setup_dev.sh:20-24`.
  - `yowasp-yosys` is not pinned; this container has 0.69.0.0.post1233.
  - Pillow is installed system-wide here (12.3.0), not in the venv, and the venv does not see system site-packages.
- **Step 5** has no commands, because its inputs come from the user.
- **Step 6.**
  - The source clone used for the current image is `/home/user/7800-devtools/7800openbios`, itself a shallow clone at `b8bc745`, the branch head when it was cloned.
  - If upstream has moved on, `--depth 1` will not contain `b8bc745`. Then clone without `--depth` and run `git checkout b8bc745`.
  - The Makefile also passes `-I../includes`, which does not exist here and is not needed.

**Alternative for steps 1-4:** `sim/bupchip/setup_dev.sh` installs the apt packages, builds Verilator 5.040, creates the venv with unicorn and runs `docker pull`. Whether it runs end to end in a fresh container is **[untested]**. It has these gaps:

- It does not install `yowasp-yosys`, Pillow, dasm or zip.
- It does not build the OpenBIOS.
- It runs `docker pull` but does not start dockerd (line 25-26).
- It needs the firmware: under `set -e`, its hex-to-bin conversion at lines 27-31 fails when `bupchip.hex` is missing, before the objdump at line 32.

## 2. Tools

### 2.1 Machine

- **System:** Ubuntu 24.04 in a cloud container with no init system, so daemons such as dockerd must be started by hand and do not survive a container restart.
- **Resources:** 4 CPUs, 15 GiB RAM, no swap. The load average was about 4 while other simulations shared the machine.
- **Persistence:** the disk persists across VM restarts; running processes do not. For the disk budget see section 8.3.
- **Reachable hosts:**
  - github.com (clones), raw.githubusercontent.com, Docker Hub, PyPI, archive.ubuntu.com.
  - `gh api` returns 403 ("GitHub access to this repository is not enabled for this session") for repositories not attached to the session.
- **Refused hosts (403 on CONNECT):** www.misterfpga.org, forums.atariage.com, openfpga-cores-inventory.github.io, www.reddit.com, www.timeextension.com, mouser, alliancememory. WebFetch reports these as ENOTFOUND, and docs.libretro.com too.

### 2.2 Tool table

| Tool | Version here | Path | Installed by | Used by |
|---|---|---|---|---|
| Verilator | 5.040 (`Verilator 5.040 2025-08-30 rev v5.040`) | `/opt/verilator-5.040/bin/verilator` (not on PATH) | source build, 2026-10-03 | every Verilator bench |
| Verilator (apt) | 5.020-1 | `/usr/bin/verilator` (first on PATH) | apt | Nothing should use it. `sim/run_sim.sh` picks it unless `VERILATOR` is set. DEVELOPING.md:57 calls 5.020 too old |
| Icarus Verilog | 12.0 (12.0-2build2) | PATH | apt | s4 PSRAM layer (`run_psram_ctl.sh`), `sim/bupchip/s4/stress/run_tick.sh` |
| GHDL | 4.1.0, mcode | PATH | apt | `POKEY=watson` in `sim/run_sim.sh:43-58`, `run_pokey_shadow.sh` |
| ARM cross toolchain | arm-none-eabi-gcc 13.2.1 (gcc-arm-none-eabi 15:13.2.rel1-2), binutils-arm-none-eabi 2.42 | PATH | apt | ARIA/DARIA test programs, see the note after this table |
| Yosys (YoWASP) | yowasp-yosys 0.69.0.0.post1233, yowasp-runtime 1.96, wasmtime 47.0.1 | `sim/work/bupchip/venv/bin/yowasp-yosys` (no `yosys` on PATH) | pip in the venv, 2026-10-03 | `sim/bupchip/daria/thumb/{aria_equiv,index_depth,yosys_cells}.sh`, `sim/bupchip/model/study/area/run_area.sh` |
| dasm | 2.20.14.1 | `/usr/bin/dasm` | apt, 2026-10-08 | 7800 OpenBIOS build |
| gcc / g++ | 13.3.0 | PATH | base image | Verilator (`CXX = g++` in verilated.mk) |
| ccache | 4.9.1 | PATH | apt | Verilator (`OBJCACHE ?= ccache`) |
| clang | 18.1.3 | PATH | base image | no tracked script |
| cmake, make | 3.28.3, GNU make 4.3 | PATH | base image | Verilator build |
| Docker | docker-ce 29.6.2; dockerd starts its own containerd v2.2.6 | PATH | base image | Quartus (section 3) |
| Quartus Prime | 21.1.1 Build 850 Lite | inside `raetro/quartus:21.1` only | `docker pull` | section 3 |
| Python | 3.11.15 | `/usr/local/bin/python3` -> `/usr/bin/python3.11` | base image | section 4 |
| node, npm, Playwright | v22.22.0 (`/opt/node22`), 10.9.4, 1.56.1 with chromium-1194 in `/opt/pw-browsers` | | base image | no tracked file (section 4) |
| Other | git 2.43.0, curl, zip 3.0, unzip 6.00, flock, setsid, nohup, timeout, nice, md5sum, gzip; libpng-dev 1.6.43, flex 2.6.4 | PATH | present | Various scripts. `tools/package.sh:28` uses zip, with a Python fallback |

Note on the ARM cross toolchain. These scripts use it to assemble test programs:

- `sim/bupchip/s1/run_directed.sh:45`
- `sim/bupchip/s4/stress/run_bounds.sh:30`
- `sim/bupchip/s4/stress/run_pophead.sh:50` (directory per `sim/bupchip/s4/README.md:12`)
- `sim/bupchip/daria/thumb/run_directed.sh:65`
- `sim/bupchip/daria/thumb/run_random.sh:36`
- `sim/bupchip/daria/modes/run_modes.sh:52`

`sim/bupchip/s4/check.sh:91` checks that the toolchain is present, and `setup_dev.sh:32` uses `arm-none-eabi-objdump`.

### 2.3 Install commands as recorded

These ran on 2026-10-03, according to `/var/log/apt/history.log`:

```sh
apt-get install -y -q verilator iverilog gcc-arm-none-eabi binutils-arm-none-eabi
apt-get install -y -q ghdl git autoconf flex bison help2man libfl-dev ccache make g++ perl
```

The Verilator v5.040 source build followed (quick start step 2; its install files are stamped 01:23:48). On 2026-10-08:

```sh
apt-get install -y dasm
```

### 2.4 Which Verilator runs

- **`sim/run_sim.sh`.**
  - It calls `${VERILATOR:-verilator}` (lines 2-3, 106, 293, 299, 305), so on this machine it picks 5.020.
  - Always run it as `VERILATOR=/opt/verilator-5.040/bin/verilator sim/run_sim.sh`.
  - The existing builds used 5.040: `sim/work_*/obj_load/*__verFiles.dat` name `/opt/verilator-5.040`.
- **The `sim/bupchip` scripts** default to `/opt/verilator-5.040` when it exists, and `VERILATOR` overrides the default. They are:
  - `run_bupchip.sh:11`
  - `verif/build.sh:12`
  - `daria/run_daria.sh:63`
  - `daria/fe_unit/run_unit.sh:27`
  - `daria/fe_rand/run_rand.sh:34`
  - `daria/fe_dir/run_dir.sh:35` (as `VERILATOR_REAL`)
  - the s4 benches (`s4/README.md:12`)
- **Spec benches.** Some scratch benches cited in the specs were built with 5.020, not 5.040: `docs/daria_fe/spec/audio.md:867` and `docs/daria_fe/spec/cdf.md:901`.

## 3. Quartus via Docker

### 3.1 Version and licence

- **Version:** Quartus Prime 21.1.1 Build 850 06/23/2022 SJ Lite Edition. The same string appears in the Quartus reports (for example `src/fpga/output_files/ap_core.fit.rpt`) and in `src/fpga/ap_core.qsf:45` (`LAST_QUARTUS_VERSION "21.1.1 Lite Edition"`).
- **Licence:** Lite needs no licence file, and the image sets no `LM_LICENSE_FILE`.
- **LogicLock:** not available in Lite (Warning 292013, Critical Warning 140003; `sim/bupchip/quartus_probe/README.md:83`).
- **Doc error, corrected 2026-10-16:** `docs/daria_fe/lanes/B_audio.md:279` and `docs/daria_fe/lanes/D_arb_guard.md:328` said "Quartus 21.1 Standard". Each now has a correction line above it: Lite. (The lines themselves are kept, because they also cite the Quartus lock's path, which `sim/check/hygiene.sh` refuses in an added line.)
- **No host install:** `quartus_sh` is not on the host PATH. Quartus runs only inside the image.

### 3.2 The image

| Field | Value |
|---|---|
| Name | `raetro/quartus:21.1` |
| Created | 2022-07-24, amd64 |
| Source | github.com/raetro/sdk-docker-fpga |
| Size | 5.91 GB content, 18.6 GB on disk |
| Workdir | `/build` |
| Environment | `QUARTUS_ROOTDIR=/opt/intelFPGA/quartus`, PATH including `quartus/bin`, `LD_PRELOAD` tcmalloc |

The image was pulled on 2026-10-03 with `timeout 580 docker pull raetro/quartus:21.1`, which took about 2 min 11 s [R]. Whether to pin it by digest is an open question (section 10).

### 3.3 Starting dockerd

- There is no init, so dockerd is down after every VM restart. Check it with `docker info`.
- There is no `/etc/docker/daemon.json`. Storage uses overlayfs with the containerd snapshotter, with its root at `/var/lib/docker`. dockerd starts its own containerd.
- Two start forms are recorded [R]. Each was followed by polling `docker info` until it answered:

  ```sh
  setsid nohup dockerd > $D/dockerd.log 2>&1 < /dev/null &
  ```

  This form was used on 2026-10-06. The dockerd running at inventory time was started on 2026-10-07 at 23:10 (per `ps`), with this form:

  ```sh
  (nohup dockerd > <a writable directory>/dockerd.log 2>&1 &)
  ```

  - Running Quartus from the local image needs no network, so this does not matter for builds.

- **"containerd is still running" after a VM restart** (2026-10-13). dockerd can refuse to start with a message that containerd is still running, although no containerd process exists: the restart left a stale `/var/run/docker/containerd/containerd.pid`. Check that no containerd runs (`pgrep -a containerd`), delete that file, and start dockerd again with one of the forms above:

  ```sh
  rm /var/run/docker/containerd/containerd.pid
  ```

### 3.4 Running Quartus

To compile the full core, run the CI form (`.github/workflows/build.yml:18-22`) from the repo root:

```sh
docker run --rm -v $PWD:/build -w /build/src/fpga raetro/quartus:21.1 quartus_sh --flow compile ap_core
```

- **After the compile:** CI greps `output_files/ap_core.sta.rpt` for "Timing requirements not met" and only warns (build.yml:24-30). It then runs `tools/package.sh` (build.yml:32-33).
- **When CI runs:** only on pushes to `main` and `Mister-Pocket-Port`, on PRs and on `workflow_dispatch` (build.yml:3-7). It does not run on `DARIA-dev` pushes, so check builds locally.
- **Runtime:** a full build takes about 12 min on 4 cores (`sim/bupchip/quartus_probe/README.md:144`).
- **PLL regeneration:** also runs in the image; see DEVELOPING.md:274-296.

**Probe wrappers:**

- `quartus_sh` is not on the host PATH, so every wrapper falls back to `QUARTUS=docker` and runs:

  ```sh
  docker run --rm -v $ROOT:/build -w /build/<rel> raetro/quartus:21.1 bash -c <steps>
  ```

- Variables:
  - `QUARTUS`: falls back to `docker`.
  - `IMAGE`: overrides the image.
  - `WORK`: the output directory. With Docker it must be inside the repo, because only `$ROOT` is mounted.
  - `KEEP_DB=1`: keeps `db/` and `incremental_db/`, which are otherwise deleted.

| Wrapper | Output, under `sim/work/bupchip/` | WORK-in-repo check | Runtime |
|---|---|---|---|
| `sim/bupchip/quartus_probe/run_probe.sh` | `qprobe/<MHz>` | line 37 | 2-4 min per clock |
| `sim/bupchip/quartus_probe/daria_fe_map.sh` | `qfe/<TOP>-<mode>` | line 47 | with `--fit`, written as a `Quartus: N s` line |
| `sim/bupchip/quartus_probe/daria_wrap_map.sh` | `qwrap/{daria,aria}` | line 26 | [not recorded] |
| `sim/bupchip/quartus_probe/upstream_arm_map.sh` | `qupstream` | none; keep `WORK` inside the repo yourself | [not recorded] |
| `sim/bupchip/quartus_probe/full/run_full.sh` (Docker only) | `fullprobe/<tag>` | line 28 | about 12 min (README.md:144) |
| `sim/bupchip/daria/frontend_study/run_study.sh` | `daria/frontend_study` | [not recorded] | [not recorded]; runs 4 builds at a time (lines 6-7), so do not run it alongside other Quartus jobs |
| `sim/bupchip/quartus_probe/step7/run_step7.sh`, the step-7 and release fit driver: one compile of a tree's `src/fpga` as CI compiles it, then `step7_report.tcl` and `step7_checks.py` (plan 5.4's checks); `TREE`, `SEED`, `TAG`, `NODARIA=1`, `PIN_ID=1`, `KEEP_DB=1`, `REPORT_ONLY=1`, `DRYRUN=1` (header) | `sim/work/step7/fit/<TAG>`, outside `sim/work/bupchip/` (`WORK` overrides) | not needed: it mounts the run directory itself; it refuses run_full.sh's and R1's directories | 12-25 min a fit; exit 0 PASS, 3 FAIL verdict, 1 compile failure, 2 refused. Needs `QUARTUS_LOCK` and refuses to start unless an ancestor holds that lock (section 3.5). Its self-test, `step7/selftest.sh`, runs without Quartus and needs 100 MB free |
| `sim/bupchip/quartus_probe/step7/smoke/run_smoke.sh`, the report script's smoke test on a small fitted design (`daria.qip`'s marks, (c.cells), (f), (k), (k')) | `sim/work/step7/smoke` (`WORK` overrides) | protected directories refused, as above | about 35 s a fitted project, five projects and two `quartus_sta` runs of about 3 s, about 3 min in all [measured 2026-10-19]; needs `QUARTUS_LOCK` as `run_step7.sh` |

Only the `daria_fe_map.sh <block> --fit` invocation is recorded here. Arguments for the other wrappers are in `sim/bupchip/quartus_probe/README.md`.

### 3.5 The Quartus lock

Run one Quartus job at a time. The convention is recorded in the lane docs (`docs/daria_fe/lanes/C_call_copy.md:242,295-296`, `A_core.md:192,233`, `D_arb_guard.md:328,395-398`, `B_audio.md:279,342-344`) and in the headers of `sim/bupchip/daria/fe_unit/tb_fe_arb_probe.v:13` and `tb_fe_audio_probe.v:11`:

```sh
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh <block> --fit
```

- **No script takes the lock itself,** so wrap every Quartus job by hand. `run_step7.sh` and `smoke/run_smoke.sh` check it: they need `QUARTUS_LOCK` set to the lock file and refuse to start unless the lock is held by one of their ancestors, so run them as `flock "$QUARTUS_LOCK" <script>`.
- **The lock file.** `/tmp/daria_quartus.lock` is an empty file owned by root. It survives VM restarts because the disk persists: it dates from 2026-10-07 21:28, before the current boot.

### 3.6 Network and disk

- **Disk:** the image takes 18.6 GB of a budget of about 39 GB [E]. `docker system df` shows it as 100% reclaimable because no container uses it, so `docker system prune -a` would delete it. Do not run that command.

## 4. Python and node dependencies

Python is 3.11.15. The only third-party imports in tracked files are unicorn and PIL.

| Package | Where | Version | Install command (recorded) | Used by |
|---|---|---|---|---|
| unicorn | venv | 2.1.1 | `pip install -q 'unicorn==2.1.1'` (`sim/bupchip/setup_dev.sh:20-24`) | `sim/bupchip/daria/thumb/thumb_iss.py`, `daria/thumb_expand.py`, `model/sweep.py`, `verif/isa/iss_run.py`, `verif/iss_fw_replay.py` |
| yowasp-yosys | venv | 0.69.0.0.post1233 | `sim/work/bupchip/venv/bin/pip install -q yowasp-yosys` | the Yosys scripts (section 6) |
| Pillow | system | 12.3.0 | `pip install --quiet pillow` | `sim/extra_tests.sh:60` and its 7800basic build |
| markdown | system | 3.11 | pip, 2026-10-09 [command not recorded] | report rendering only; the project does not need it |

- **The venv:**
  - Location: `sim/work/bupchip/venv`, created with `python3 -m venv`, with `include-system-site-packages = false`.
  - Scripts find it through `VENV` or `PYTHON`, for example `sim/bupchip/verif/isa/run_isa.sh:20-21` and `sim/bupchip/daria/thumb/run_random.sh:27-28`.
  - It lives under `sim/work`, so deleting `sim/work` deletes the venv.
- **Finding Yosys:**
  - The scripts honour a `YOSYS` override, then try `yosys` on PATH, then `$VENV/bin/yowasp-yosys`, and otherwise exit with status 2 (for example `sim/bupchip/daria/thumb/aria_equiv.sh:23`).
  - YoWASP caches compiled modules in `~/.cache/YoWASP` (205 MB).
- **Not needed:** numpy (DEVELOPING.md:59 lists it, but no tracked file imports it) and capstone.
- **Node:**
  - node v22.22.0, npm 10.9.4 and a global Playwright 1.56.1 (`PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`) come with the base image.
  - No tracked file uses them. They were used once, ad hoc, for report screenshots, by a script that is not in the repo [R].
  - There is nothing to install.

## 5. Where data lives

### 5.1 Work directories

- Every script writes to `sim/work` by default, through `WORK` (for example `sim/run_sim.sh:9` and `sim/bupchip/daria/run_daria.sh:62`).
- `.gitignore` (lines 1-18) ignores:
  - `sim/work*`, which covers `sim/work_rel` and the like;
  - `release/`;
  - Quartus `db/`, `incremental_db/` and `output_files/`;
  - `src/fpga/mister/rtl/bupchip.hex` and `.mif`.
- Disk use on 2026-10-09. These figures grow while simulations run; the fact-check values are in brackets.

| Path | Size |
|---|---|
| `/var/lib/docker` (Quartus image) | 18 GB |
| `sim/work` | 2.7 GB [2.9 GB], of which `sim/work/bupchip/daria` 1.5 GB [1.7 GB] |
| `sim/work_pup`, `sim/work_rel`, `sim/work_rel2`, `sim/work_slotfix` | about 330-364 MB each (`sim/work_review` 2.1 MB) |
| `/opt/pw-browsers` | 924 MB |
| `~/.cache/YoWASP` | 205 MB |
| `sim/work/bupchip/venv` | 189 MB |
| `/opt/verilator-5.040` | 112 MB |
| `~/.cache/ccache` | 6.2 MB [130 MB] |

### 5.2 BupChip firmware (supplied by the user, never committed)

- **Where it goes:** `src/fpga/mister/rtl/bupchip.hex` (17,604 B here) plus its `.mif` (40,910 B). Both files are gitignored.
- **History:** added in `3043d50` (2026-09-27) and removed in `0c6996b` (2026-10-03, "Remove the BupChip firmware (bupchip.hex/.mif) from the repository"). A fresh clone of `DARIA-dev` does not have it. The copy in this container dates from the original clone.
- **The user's upload:**
  - How the `.hex` was produced from the `.bin` is [not recorded].
  - Scripts convert the hex with `tools/hex2bin.py`; s4 never uses `$readmemh`.
- **Which source to use:** a new upload or git history (`0c6996b^`) is the user's decision (section 10). Ask.
- **Without the firmware:**
  - `sim/run_sim.sh` skips its BupChip end-to-end test (lines 254-257);
  - `sim/bupchip/model/check.sh` exits with status 2 (lines 16-17);
  - `sim/bupchip/verif/run_all.sh` marks the firmware steps SKIP (lines 38-41), and exits 2 if given a game (lines 28-30);
  - `sim/bupchip/s1/check.sh` (lines 29-33) and `sim/bupchip/s4/check.sh` run only their firmware-free checks;
  - `run_jukebox.sh` exits with status 2 (line 20);
  - `setup_dev.sh` stops at its hex conversion (lines 27-31).

### 5.3 7800 OpenBIOS (built locally, never committed)

- **Where it is read:** the BIOS_BOOT test in `sim/run_sim.sh` reads `BIOS=${BIOS:-$HERE/work/bupchip/bios/7800openbios.bin}` (lines 152-163). That path is always under `sim/work`, whatever `WORK` is. The test is skipped if the file is missing (line 243).
- **Build commands:**
  - The source clone in this container is `/home/user/7800-devtools/7800openbios`, a shallow clone whose HEAD is `b8bc745`.
  - The build follows that repo's `Makefile`: `dasm 7800openbios.asm -f3 -v0 -I. -I../includes -o7800openbios.bin -l7800openbios.list.txt`. The listing kept in `sim/work/bupchip/bios/openbios_build/7800openbios.list.txt` names that clone's path.
  - At fact-check, re-assembling with the dasm line in quick start step 6 reproduced the md5 above.
  - A fresh clone is **[untested]**. If the default branch has moved past `b8bc745`, use a full clone and check out `b8bc745`.
- **Licence:** the image embeds KiloParsec, which is all rights reserved, so it stays in `sim/work`. `7800_ntsc.rom` in the same directory is unused.

### 5.4 Game images (supplied by the user, never committed)

  - `Rikki_and_Vikki.a78`, `RV-Music.zip` and `FoxBox.cdf`;
  - two Champ Games demo zips;
  - the Draconian, SF2, RobotWar and spacerocks `.bin` files.

  The same directory also holds images and PDFs that are not game data.
- **Copies in this container**, all under `sim/work/bupchip/`:
  - `game`: `rv.a78`, built by `sim/bupchip/make_arsc.py`;
  - `ref`: MiSTer `song<N>.pcm`;
  - `champ`;
  - `champ_presents`;
  - `daria/roms`.
- **In a fresh container:** none of these files exist. Ask the user to upload them again. Which file each suite expects, beyond the directories above, is [not recorded]. Check each suite's README (for example `sim/bupchip/s4/README.md:12` and `sim/bupchip/model/README.md:5-7`).

### 5.5 Inputs fetched from the network

`sim/extra_tests.sh` fetches its inputs from the network:

- **Firmware files.** It uses curl to fetch `mem4.hex` and `ar.hex` from raw.githubusercontent.com (`MiSTer-unstable-nightlies/Atari7800_MiSTer`), at the commit in `src/fpga/mister/UPSTREAM_COMMIT` (lines 106-108).
- **Test-cart tools.** It fetches and builds its own dasm and 7800basic from GitHub into `$WORK/extra`, each at the commit the script pins (`DASM_REF`, `B78_REF`; 7800basic's later commits run its compiler under valgrind, which a build machine may not have). Here that dasm is `sim/work/extra/dasm/bin/dasm`.
- **Requirements.** It needs git, a C compiler, libpng-dev, flex and Pillow (lines 2-4).

### 5.6 Outside the repo

- **`/home/user/lroby74` (7.6 MB):** a clone of lroby74's MiSTer fork. Do not read its sources (section 7.1). Black-box outputs are in `sim/work/bupchip/lroby`.
- **`/home/user/mmnbass/openfpga-jaguar` (3.7 MB):** a read-only reference for the Jaguar assessment. No openFPGA-7800 script uses it.
- **`/home/user/7800-devtools/7800openbios` (276 KB):** the OpenBIOS source (section 5.3).
- **`/home/user/abdess/retrobios` (34 MB) and `/home/user/aganarr/cdfjplus-template` (508 KB):** other clones; their purpose is [not recorded].
- **Scripts outside the repo:** some files cited by docs lived only in a session's temporary directory, so a fresh container will not have them:
  - `(temporary) g7b/*.py` (`docs/daria_fe/lanes/G_step7_resets.md:276`);
  - `ref/CartCDF.cxx` (`docs/daria_fe/spec/cdf.md:49`);
  - `upstream_wrapper/Atari7800.sv` (`docs/daria_fe/spec/bus.md:22`).

## 6. Bench families

How to read the table:

- **Commands:** only two invocations are recorded verbatim with their arguments: `sim/run_sim.sh` and the `flock` form of `daria_fe_map.sh`. Other rows give the script path; arguments and environment variables are in the script header or README.
- **Pass criteria:** where a README or script states the rule or a recorded result, the table gives it. "Not recorded" means read the suite's README or script header before treating a run as good.
- **Runtimes:** taken from DEVELOPING.md:93-99, the suite READMEs and the script headers.
- **Limits:** observe the job limits (section 7.4). Detach anything that runs close to an hour (section 8.2).

| Family | Run command | Runtime | Needs | Pass criterion |
|---|---|---|---|---|
| Core simulation | `VERILATOR=/opt/verilator-5.040/bin/verilator sim/run_sim.sh` | about 24 min (aeee6d2, 4 build jobs) | Verilator 5.040; GHDL for `POKEY=watson`; firmware for the BupChip end-to-end test (`BUPFW=FILE`); OpenBIOS for BIOS_BOOT (`BIOS=FILE`) | `sim/check/run_sim_check.py LOG`: exit 0, and a skipped section fails there, as does a `SIMULATOR EXIT N` line (a bench that exited non-zero in a case piped through `grep`). The script itself exits 0 whatever its verdicts say. With `FP=1` every case writes its `+fp` fingerprint (`frame,len_sys,riot,video,audio,cpu,t_sys,rst_n,rst_sys`: the last three place each frame and the console reset's releases in absolute `clk_sys`; a last line covers the frame still in progress when the run ends), compared between builds with `sim/check/frame_gate.py --strict`. |
| Extra tests | `sim/extra_tests.sh` | about 1 h; 2 h 34 min with `AR_TAPE=1` (aeee6d2, on a machine with all four cores busy; the two tape runs simulate 34 s); step 7 adds about 16 min for its 2600 cartridge-RAM section, and with `AR_TAPE=1` the tape load with `+cartram` (artape) in that section, about 80 min more (measured on aeee6d2 with the other cores busy) | a finished `run_sim.sh`; network access to GitHub; git, a C compiler, libpng-dev, flex, Pillow | `sim/check/extra_tests_check.py LOG --ref REF_LOG` (the reference build's log, for the POKEY and DLI statistics; `--ar-tape` with `AR_TAPE=1`): exit 0. |
| 2600 cartridge RAM | `sim/cartram2600_test.py matrix --build` and `s19`; on a tree with Fix B also `reset`, `midswap` and `forcecoinc`, and each with `--mutant nohold` or `--mutant nocmp` | about 12 min for the matrix and 4 min for `s19` (aeee6d2), plus the `tb_cartram` build; `--arfw FILE` (the Supercharger BIOS) adds the tape load, about 80 min (22 simulated seconds with the monitor); on F, `reset` (14 runs, the console-reset sweep) about 8 min, `midswap` and `forcecoinc` under 1 min, a mutant's build about 1 min more (once per work directory) | a `WORK` with `run_sim.sh`'s `rtl/` links | `CARTRAM_MATRIX pass`, `CARTRAM_S19 pass`, `CARTRAM_RESET pass`, `CARTRAM_MIDSWAP pass`, `CARTRAM_FORCECOINC pass`, exit 0; with `--mutant`, `MUTANT ... CAUGHT`, exit 0 (header of the script). `--ref-logs DIR` holds the tape load's colours to another build's; `--fp` writes each run's fingerprint. |
| Step 7 gates | `sim/step7_gates.sh` (`--list` shows what is available) | hours | as its header: `SIM_LOCK`, `BIOS`, `BUPFW`, `HYGIENE_NAMES`, `PP_EXPECT`, `PP_GUARD_FROM`, `EXTRA_REF`; optional `RUN_SIM_REF`, `FP_REF` (fingerprints in tb_load's current nine-column format), `PP_ORACLE_BASE`, `CARTRAM_ONLY`, `S4_GAME` and `REFDIR`, `S4_JOBS` (`s4_check`'s simulations at once, default 2), `GAMES`, `R1_DIR`, `FRAMES_LIST`, `FRAMES_GUARD`, `FRAMES_RULE` (`v1`, the default, or `shift`), `WIRE_ONLY` and `WIRE_MUT` (the `wire` gate on some scenarios or mutants only: a quick look) | `STEP7_GATES pass`, exit 0. Exit 1 when a gate failed. Exit 3 when none failed but a gate is not available yet or ran only in part, or when no gate ran at all (every one not selected or not available). PARTIAL: `s4_check` without the firmware and game jobs; `cartram` with `CARTRAM_ONLY`; `wire` without `GAMES` (the Turbo run), `BIOS` or `BUPFW` (the four Souper runs; by default the tree's gitignored `src/fpga/mister/rtl/bupchip.hex`), or with `WIRE_ONLY` or `WIRE_MUT`; `frames` with a `FRAMES_LIST` that leaves out any of plan 1.2 row 7's 16 images (it names them); `selftest` without one of its input logs or `EXTRA_REF` (it names each one missing); `fit_selftest` with less than 100 MB free on /. Exit 2 on a usage error, before any gate runs: an unknown argument, an unknown gate name in `--only` or `--skip`, or an `--only` that names no gate (header of the script). |
| Whole-core frames | `sim/run_frames.sh IMAGE.bin` (`tb_frames`: the Pocket core on a 2600 image with `tb_daria`'s fingerprint, input script and call log; `NAME`, `FRAMES`, `WORK`; `INPUTS=tb_daria` presents the TIA's paddle inputs as `tb_daria` does, which a comparison with R1 needs) | non-DARIA build: 196 s of wall time per emulated second (Juno First, 1,500 frames, 25.0 s emulated in 82 min, beside two to three other simulations); DARIA build (`u_fe` wired): about 270 s on a 12-frame run (load included) | a `tb_frames` build (`run_sim.sh BUILD_TOP=tb_frames`, which the script makes) | `FRAMES result: PASS`, exit 0 (in a DARIA build also the call_tog, call_go and returned counts equal to the busy periods); against R1, `sim/check/frame_gate.py --auto` (the scheme the loader found picks `--strict` or the gate's rules: `--rule v1` by default, which gates `len_sys`, video, RIOT and each call's ARM instruction count and counts audio, or `--rule shift`, the strict rule; `--ref-prefix` for a run shorter than R1's; `--shift-cap` for the release_shift frames allowed per column, default the larger of 8 and 1% of the frames). |
| Step 7 lint | `sim/lint_step7.sh` | about 20 s | Verilator 5.040 | `LINT pass`: no Verilator `-Wall` warning added against `aeee6d2` in the three macro sets of plan 3.3 item 1, exit 0. |
| `tb_wire` (step 7) | `sim/bupchip/daria/wire/wire.py build daria plain`, then `wire.py run [SCENARIO ...]`; `wire.py mutant NAME` for each of plan 7.2's seven mutants; `wire.py list` shows the scenarios | hours for the full set (97 scenarios with `DIRECTED=1`, `GAMES` and `BIOS`, since `82d05f1` added `pal2600_a78`); each simulation is limited to `WIRE_TIMEOUT` (7,200 s); split the set by scenario name (section 8.4) | Verilator 5.040; `BUPFW` (the firmware) for the four Souper runs, `GAMES=DIR` for the Turbo run, `BIOS=FILE` for decision 11's runs; `ARM_DIV` (19, the default) | `wire.py run`: every scenario PASS, exit 0 (`WORK/results.txt`, one line per scenario). A mutant: `CAUGHT` (exit 0) only on the keys plan 7.2 names; NOT CAUGHT is exit 1, and a crash, timeout or `%Fatal` is ERROR (exit 2). `step7_gates.sh`'s `wire` gate runs both |
| `tb_dbg_snap` (step 7) | `sim/bupchip/dbgsnap/run_dbgsnap.sh` | not recorded | Verilator 5.040 (`VERILATOR` overrides); `MUTATIONS=0` skips the mutations, `DBGSNAP_MUTS` picks some | `run_dbgsnap.sh: PASS`: the control and power-up runs end with errors=0 and every word asked for (32 runs), and each of the 7 mutations is caught by a run that ends with its result line and errors > 0; a run without its result line, a non-zero exit or a `%Fatal` is an ERROR and fails the script |
| BupChip whole chip | `sim/bupchip/run_bupchip.sh GAME.a78 SONG` (DEVELOPING.md:95) | not recorded | Verilator 5.040 (the default) | Not recorded. |
| Jukebox | `sim/bupchip/run_jukebox.sh` | about 7 min game-free, 10 with a game (lines 13-14) | firmware; a `tb_load` build from `run_sim.sh` | Exits with status 2 without firmware or the `tb_load` build (lines 20-21); otherwise not recorded. |
| verif | `sim/bupchip/verif/run_all.sh` | about 3 min | firmware for steps 2-3; the venv | Prints a PASS/FAIL/SKIP line per step and exits non-zero on any FAIL (lines 60-61). |
| verif songs | `sim/bupchip/verif/run_songs.sh` | about 1 h (56 min on 4 cores, s1/README.md:58); detach | firmware and a game | Recorded result: 32 of 32 songs (s1/README.md:58). |
| verif ISA | `sim/bupchip/verif/isa/run_isa.sh` | not recorded | the venv (unicorn) | Not recorded. |
| s1 | `sim/bupchip/s1/check.sh` | 5 min without the game, 9 with it (s1/README.md:10) | arm-none-eabi-gcc; firmware and a game are optional | PASS/FAIL per step. Recorded: 11 of 11 with the game, 7 of 7 without firmware (s1/README.md:72). |
| s4 | `JOBS=2 sim/bupchip/s4/check.sh` | 30-40 min without a game; 53 min with the game at the default `JOBS=3`, which exceeds the 2-job rule | iverilog; arm-none-eabi-gcc (checked at line 91) | Prints "N of M passed" (check.sh:223-224). Recorded: 28 of 28 with the game, 16 of 16 without (s4/README.md:8-9). |
| s4 stress | `sim/bupchip/s4/stress/run_tick.sh`, `sim/bupchip/s4/stress/run_bounds.sh`, `sim/bupchip/s4/stress/run_pophead.sh` | not recorded | iverilog (`run_tick`), arm-none-eabi-gcc (`run_bounds`, `run_pophead`) | Not recorded. |
| model | `sim/bupchip/model/check.sh` | about 15 s (model/README.md:33) | firmware | Exits with status 2 without firmware; otherwise not recorded. |
| DARIA whole core | `sim/bupchip/daria/run_daria.sh` | 79-104 s of wall time per emulated second for a plain build; mode B about 286 s (3.5 simulated ms per wall second) | [not recorded]; `sim/work/bupchip/daria/roms` holds game copies | Not recorded. |
| DARIA regression | `sim/bupchip/daria/run_all.sh` | not recorded | builds once, then exports `NOBUILD=1`; `JOBS` defaults to 2 | Not recorded. |
| DARIA front-end unit | `sim/bupchip/daria/fe_unit/run_unit.sh` | not recorded | none beyond Verilator 5.040 | Not recorded. |
| DARIA front-end directed | `sim/bupchip/daria/fe_dir/run_dir.sh` | not recorded | `FLAVOR=s0` builds the stage-0 bench from git `d729ba7` | Not recorded. |
| Harmony model directed (`+mam`) | `sim/bupchip/daria/mam/run_dir.sh [OUTDIR]` ([HARMONY_MODEL.md](HARMONY_MODEL.md)) | 22 s for the 18 runs with the bench built (2026-10-19), plus a plain `tb_daria` build | Verilator 5.040, Python 3; `WORK`, `NOBUILD=1`, `RUNNER` (a slot wrapper) | `9 tests, 0 failing` (`dircheck.py`) and `18 traces, 0 differing: ALL OK` (`mymam_check.py`), exit 0. Recorded 2026-10-19: both. |
| DARIA front-end random | `sim/bupchip/daria/fe_rand/run_rand.sh`; campaigns with `sim/bupchip/daria/fe_rand/campaign.sh` | not recorded | `JOBS` defaults to 1 and is capped at 2 (lines 137-138); `campaign.sh` runs two at a time; `SKIP_DONE=1` skips finished seeds on restart | Each log carries a build stamp and a verdict; the verdict text is not recorded. |
| Thumb | `sim/bupchip/daria/thumb/run_directed.sh`, `sim/bupchip/daria/thumb/run_random.sh`, `sim/bupchip/daria/thumb/run_mutants.sh` | `run_mutants` about 1 h (thumb/README.md:14); others not recorded | arm-none-eabi-gcc; the venv (`run_random`) | Each mutant must make one of the suites fail (thumb/README.md:14); 17 of 17 caught at step 2 (docs/DARIA_CORE.md:214). Others not recorded. |
| Yosys checks | `sim/bupchip/daria/thumb/aria_equiv.sh`, `sim/bupchip/daria/thumb/index_depth.sh`, `sim/bupchip/daria/thumb/yosys_cells.sh`, `sim/bupchip/model/study/area/run_area.sh` | not recorded | Yosys or YoWASP | Exit with status 2 when no Yosys is found; otherwise not recorded. |
| Modes | `sim/bupchip/daria/modes/run_modes.sh` | not recorded | arm-none-eabi-gcc | Not recorded. |
| MMIO | `sim/bupchip/daria/mmio/run_mmio.sh` | not recorded | Verilator 5.040 (`VERILATOR` overrides) | Its header lists the conditions: each run ends with errors=0, an exact rate window and the expected TCR latencies (lines 1-12). |
| Quartus | section 3.4; wrap with the lock (section 3.5) | 2-4 min per clock (`run_probe`); about 12 min for a full build | dockerd running; the image | CI greps the STA report for "Timing requirements not met" and only warns (`.github/workflows/build.yml:24-30`). |

## 7. Working conventions

### 7.1 Clean room

- `arm7tdmi_core.sv` (GPL-2.0-only) is a simulation oracle only. It is never a source for the design (`docs/DARIA_CORE.md:26`).
- lroby74's MiSTer Thumb core (CC BY-NC 4.0) is a behavioural reference only.
  - Its ARM and Thumb sources are not read (`docs/DARIA_CORE.md:539`).
  - The fork was measured only as a black box: its own Quartus build and a whole-core simulation, with outputs in `sim/work`.
  - Do not open files under `/home/user/lroby74`.
- Upstream's MIT front ends may be read and reused (`docs/DARIA_CORE.md:26`).

### 7.2 Data

- **No game data in the repository:** this covers ROMs and anything derived from them, such as traces, listings and signatures (`docs/DARIA_CORE.md:27`, `sim/bupchip/model/README.md:5-7`, `docs/daria_fe/README.md:5,39`). Game files and PCM stay in `sim/work`.
- **Stella:** its sources are used for behaviour notes only (`docs/daria_fe/spec/cdf.md:49`).
- **Firmware and OpenBIOS:** neither is ever committed (sections 5.2 and 5.3).

### 7.3 Branch and commits

- **Branch:** work on `DARIA-dev`, which tracks `origin/DARIA-dev`.
  - The user asked for branch `bupchip-dev` on 2026-10-03 and had it renamed to `DARIA-dev` on 2026-10-05 [R]. `origin/bupchip-dev` still exists.
  - Other local branches may exist from earlier sessions; only `DARIA-dev` is pushed.
- **Trailers:** end commit messages with the attribution lines the session's own instructions supply.

- **WIP snapshots:**
  - The session may require a clean working tree before it ends, so unfinished work is committed as `WIP snapshot: …` rather than left uncommitted.
  - Keep generated output in gitignored paths so the hook does not ask for it to be committed.
- **`.claude/`:** this container excludes `/.claude/` through `.git/info/exclude:7`. A fresh clone does not carry that file. If a `.claude/` directory appears, add the same exclude line **[untested]**.

### 7.4 Load

- **At most 4 simulations at once while no Quartus job runs, and 3 while one does** (the owner's rule for the self-hosted VM, 2026-10-19: "4 sims or 1 quartus run +3 sims"). Quartus itself runs one job at a time, under the lock of 3.5. The container's rule (2026-10-09) was 3 and 2; [AGENT_RUNS.md](AGENT_RUNS.md) 3 describes the slot helper the step-7 runs used under it.
  - `run_rand.sh` defaults to `JOBS=1` and caps it at 3, the most that is allowed while Quartus runs.
  - `campaign.sh` runs two at a time, and `daria/run_all.sh` defaults to `JOBS=2`.
  - `s4/check.sh` defaults to `JOBS=3`, so pass `JOBS=2`.
- **Quartus parallelism.** `daria/frontend_study/run_study.sh` runs 4 Quartus builds at once. Run it alone.
- **Nice.** Builds and runs are niced: `run_daria.sh` runs `nice -n 10` itself (lines 166 and 185). Use `nice -n 10` for your own long jobs.

### 7.5 Long runs

- Detach long runs with `setsid` (with `nohup`, and output redirected to a log file). Container restarts have killed background work, and background commands hit a time cap (section 8) [R].
- The running simulations show the pattern: a worker script runs with PPID 1 and its own session ID (`setsid`), with `run_daria.sh` and `vtb` running under it. Inspect processes with:

  ```sh
  ps -o pid,ppid,pgid,sid,args
  ```

### 7.6 Verilator build directories

- **`run_daria.sh`:**
  - It uses one object directory per build flavour: `obj`, `obj_shadow<WIN_KB>` and `obj_wrap<WIN_KB>`, with the suffixes `_fe`, `_fe_s0`, `_fe_poison` and `_fe_modeB` (header lines 15-51). With `MODE_B=1` it passes `+d_div` from `D_DIV`, by default the tree's divider (`step7_prep.py --tree-div`), and notes it at the end of `run.log`.
  - It rebuilds when a source is newer than `vtb`, unless `NOBUILD=1` is set.
  - It deletes `*.gch` after each build (line 171).
- **`run_rand.sh`:**
  - It stamps each build with an md5 of the Verilator version, the options, the source names and every source's content.
  - It builds under `flock` on `$WORK/.build_<BUILD>.lock`.
  - It deletes `*.gch` and `*.o`.
- **`verif/build.sh`:** rebuilds when its args file changes or a source is newer.
- **`fe_unit/run_unit.sh`:** rebuilds when a source, the `.f` file, an include or the options change.
- **General rule:** do not share an object directory between flavours or Verilator versions.

### 7.7 Quartus lock

Wrap every Quartus job in `flock /tmp/daria_quartus.lock …` (section 3.5).

### 7.8 PIDs and deletions (session conventions)

These two rules come from the task brief only. They appear in no repo doc and in no user message (section 10).

- Stop processes with `kill <PID>`, after finding the PID with `ps`. Do not use `pkill -f` patterns; `pkill -f` was used once, on 2026-10-05 [R].
- Write `rm` commands with literal paths.

### 7.9 Disk hygiene

- Write large outputs only under `sim/work` (or `WORK` inside the repo for Quartus).
- Leave `KEEP_DB` unset unless you need the Quartus databases.
- Never run `docker system prune -a` (section 3.6).
- Check `df -h /` before large jobs (section 8.3).
- Old work directories (`sim/work_pup`, `sim/work_rel`, `sim/work_rel2`, `sim/work_slotfix`) take about 330-364 MB each.

## 8. Known pitfalls

### 8.1 Session restarts kill child processes

Background work started from the session died on restart. Task notifications record this at 2026-10-03T14:11 and 2026-10-04T04:14 [R].

- Start long runs detached with `setsid` (section 7.5) and send their output to log files.
- After a restart, find the runs by PID with `ps -o pid,ppid,pgid,sid,args` and read their logs.
- Resume `fe_rand` campaigns with `SKIP_DONE=1`.
- A VM reboot (when `uptime` resets) stops every process, detached or not, including dockerd.
- The machine stops about five minutes after the session goes idle, and comes up fresh at the next session start. Keep an agent working while detached runs must continue ([AGENT_RUNS.md](AGENT_RUNS.md) section 2).

### 8.2 The 2-hour background limit

Background commands hit a time cap: one was killed on 2026-10-07T01:38, and a report names a 2-hour cap [R]. The exact limit was not verified. Several runs come close to or exceed it:

- s4 with the game, 53 min;
- `run_mutants.sh` and `run_songs.sh`, about 1 h each;
- `fe_rand` campaigns.

Run these detached with `setsid` instead of as tool background commands.

### 8.3 Disk fills

- **Read "available", not "free".** `/` is a 252 GB ext4 volume mounted with `resv_strict,resuid=65534`. At inventory 35 GB was used and `df` showed only 3.8 GB available; at fact-check, 36 GB used and 2.8 GB available. `statvfs` reports about 232 GB free but under 4 GB available, because the blocks are reserved.
- **Budget.** The effective budget is about 39 GB [E], and the Quartus image alone is 18.6 GB. A fresh container must set aside about 19 GB for the image before anything else.
- **Consumers.** The main consumers are listed in section 5.1.

### 8.4 dockerd is down after restarts

- There is no init, so start dockerd by hand after every VM restart (section 3.3), then check it with `docker info`.
  - Quartus runs from the local image are not affected.
- If dockerd then fails with "containerd is still running", the restart left a stale `/var/run/docker/containerd/containerd.pid`: delete it and start dockerd again (3.3). This happened on 2026-10-13.
- When the session ends, the machine usually stops with it, and every process with it. A session ends about five minutes after it goes idle, after about 13 hours of work, and sometimes earlier with no cause found. At some 13-hour ends the machine has stayed up ([AGENT_RUNS.md](AGENT_RUNS.md) section 2). Split long runs into pieces of an hour or less that write their own results and skip finished pieces when run again (`wire.py run` takes scenario names, `s4/check.sh` takes `ONLY=`, frame and mode-B runs go one image at a time).

### 8.5 The wrong Verilator

apt's 5.020 comes first on PATH. `sim/run_sim.sh` uses it unless `VERILATOR=/opt/verilator-5.040/bin/verilator` is set. The Jaguar repo's simulations also call plain `verilator`.

### 8.6 Silent skips

Without the firmware or the OpenBIOS, several benches skip tests instead of failing (sections 5.2 and 5.3). A clean run without these inputs does not cover BupChip or BIOS boot.

### 8.7 Stale references

- Docs cite scripts that are not in the repo (section 5.6).
- Two lane docs said "Quartus 21.1 Standard" until 2026-10-16 (section 3.1).
- `upstream_arm_map.sh` does not check that `WORK` is inside the repo (section 3.4).

## 9. What this file adds to docs/DEVELOPING.md

This file adds:

- **Tools:**
  - the `/opt/verilator-5.040` path, and the need to set `VERILATOR` for `sim/run_sim.sh`;
  - iverilog, the ARM cross toolchain, Yosys/YoWASP, and the venv with unicorn;
  - `setup_dev.sh` as the installer, and its gaps (yowasp-yosys, Pillow, dasm, zip, starting dockerd, the OpenBIOS build, the firmware dependency).
- **Quartus and Docker:**
  - starting dockerd in a cloud container;
  - the exact version (21.1.1 Build 850 Lite), the image digest and size, and the missing LogicLock;
  - the `sim/bupchip/quartus_probe` wrappers with `QUARTUS`, `IMAGE`, `KEEP_DB` and the WORK-in-repo rule;
  - the `/tmp/daria_quartus.lock` convention.
- **Data:** where the BupChip firmware, the game images and the 7800 OpenBIOS come from and where they go, including the OpenBIOS dasm command.
- **Test suites:** the `sim/bupchip` suites (s1, s4 and stress, verif, model, daria with fe_unit, fe_dir, fe_rand, thumb, modes and mmio, and quartus_probe), with run times, inputs and the recorded pass counts.
- **Rules and machine conventions:**
  - the disk budget and output locations;
  - the job limits, and the scripts that exceed them by default;
  - detaching long runs;
  - the clean-room and data rules;
  - the branch, commit-trailer and WIP-snapshot practice.

Corrections to DEVELOPING.md. None of these have been applied there yet:

- DEVELOPING.md:59 lists numpy, but no tracked file imports it.
- The macro table (DEVELOPING.md:36-47) lacks `POCKET_SUPERCHARGER`, which `src/fpga/ap_core.qsf:744` sets and `sim/run_sim.sh:108` passes. `sim/run_sim.sh` also adds `KEEP_NOCART_ROM` (lines 91-92).
- DEVELOPING.md:57 says 5.020 is too old, but `sim/run_sim.sh` still defaults to `verilator` from PATH.
- The Layout row (DEVELOPING.md:30) describes `sim/` only as "Verilator/GHDL simulation and test carts", with no mention of the `sim/bupchip` suites.
- "Before a release" (DEVELOPING.md:456-469) lists no BupChip or DARIA regressions.

## 10. Open questions for the user

1. Should a fresh container take `bupchip.hex` from a new upload or from git history (`0c6996b^`)? The project rule is that the firmware is user-supplied and never committed.
2. Should `sim/bupchip/setup_dev.sh` be extended to cover yowasp-yosys, Pillow, dasm, zip, starting dockerd and the OpenBIOS build? Or should this file only document those steps?
3. Should "kill by PID" and "literal rm paths" become project rules in DEVELOPING.md, or remain session conventions?
4. Should the image be pinned by digest in the docs and in CI? A `docker pull` in a fresh container has not been tested this session.
5. The exact disk quota is unknown; about 39 GB is an estimate [E]. Confirm it before planning work that needs the Quartus image plus large simulation outputs.
6. Should `s4/check.sh` default to `JOBS=2`? And should `run_study.sh` take the Quartus lock and run fewer builds at once, to match the machine rules?
7. ~~What job limits apply on the self-hosted VM (section 11.6)?~~ **Answered 2026-10-19** by the owner: "4 sims or 1 quartus run +3 sims", that is at most 4 simulations while no Quartus job runs and 3 while one does (section 11.6). Section 11.7 had measured the VM and proposed 5 and 3.

## 11. The self-hosted VM

Since 2026-10-18 the project also runs on the owner's own VM. Sections 1-10 describe the cloud container; this section lists where the VM differs. It is based on an inventory of the VM taken on 2026-10-18, on `Mister-Pocket-Port` at `6e2e880`. Where this section and an earlier one disagree, this section is right for the VM.

### 11.1 Machine

- **System:** Ubuntu 26.04.1 LTS, x86_64, a KVM guest with systemd. Daemons start at boot.
- **Resources:** 10 vCPUs, 30 GiB RAM. The host is an Intel Core i7-8700K (6 cores, 12 threads, 12 MiB L3). The VM has 5 of its cores with 2 threads each, so `nproc` reports 10, but the compute is 5 cores': a second thread adds far less than a core for builds and simulations. Size parallel work by the 5 cores.
- **Disk:** `/` is a 735 GB LVM volume, with 674 GB available at inventory. The roughly 39 GB budget of section 8.3 does not apply, and the Quartus image's 18.6 GB is a small part of it.
- **Users and paths:** the user is `miasmark`, in the `sudo` and `docker` groups; sudo asks for a password. `/home/user` is a symlink to `/home/miasmark`, so the `/home/user/...` paths in this file work unchanged. The repo is `~/openFPGA-7800`.
- **Provisioning:** the scripts that built the VM are in `~/provision` (outside the repo): `01_system.sh` (apt, Docker, `/etc/environment`, the symlink), `02_user.sh` (the agent's CLI, the clone, Verilator 5.040, the venv, the image pull, the OpenBIOS), `03_seal.sh` (template sealing) and `04_ramscratch.sh` (11.4). Their logs are beside them.
- **Remotes:** `origin` is the owner's fork, `upstream` is spiritualized1997/openFPGA-7800.

### 11.2 Tools

All the tools of section 2.2 are present except those the project does not use: cmake, clang, node, npm, Playwright and a `yosys` on PATH. The versions differ:

| Tool | Version on the VM | Note |
|---|---|---|
| Verilator | 5.040 in `/opt/verilator-5.040`; apt's is 5.032 | `/etc/environment` sets `VERILATOR=/opt/verilator-5.040/bin/verilator`, so `sim/run_sim.sh` picks 5.040 without the prefix (section 8.5 does not apply to login shells) |
| Icarus Verilog | 12.0 | |
| GHDL | 5.0.1 | |
| arm-none-eabi-gcc | 14.2.1, binutils 2.45.50 | |
| gcc / g++ | 15.2.0 | |
| dasm | 2.20.14.1 | |
| ccache | 4.12.3 | |
| Python | 3.14.4 | refuses a system-wide `pip install` (PEP 668), so quick start step 3's `pip install pillow` fails: Pillow 12.1.1 comes from apt's `python3-pil` |
| venv | unicorn 2.1.1, yowasp-yosys 0.70.0.0.post1259 | `sim/work/bupchip/venv`, as section 4 |
| Docker | 29.9.1 | 11.3 |
| git, gh | 2.53.0; gh 2.102.0 in `~/.local/bin` | gh is logged in as the owner, and is git's credential helper |

### 11.3 Docker and Quartus

- **dockerd is a systemd service** (`systemctl is-active docker`), enabled at boot. Sections 3.3 and 8.4 (starting dockerd by hand, the stale containerd pid) do not apply.
- **The image** `raetro/quartus:21.1` is pulled (18.6 GB) and reports `Version 21.1.1 Build 850 06/23/2022 SJ Lite Edition`.
- **The lock.** `/tmp` is a tmpfs, so the Quartus lock file (section 3.5) does not survive a reboot. `flock` creates it again, owned by `miasmark` rather than root. Keep using the lock as section 3.5 says.

### 11.4 RAM scratch

Two tmpfs mounts, each capped at 40% of RAM (13 GB), are set in `/etc/fstab`. Their contents are lost at every reboot. `/etc/profile.d/ramscratch.sh` exports their variables, and `~/RAM_SCRATCH.md` describes them.

| Path | Variable | Use |
|---|---|---|
| `/scratch` | `$RAM_SCRATCH` | general scratch |
| `sim/work_ram` | `$RAM_WORK` | inside the repo and gitignored, so the Docker wrappers accept it as `WORK`, for example `WORK=$RAM_WORK/qprobe` |

The venv, the OpenBIOS and the game files stay on disk under `sim/work`, because they must survive a reboot.

### 11.5 Inputs

- **OpenBIOS:** built by `02_user.sh` from `~/7800-devtools/7800openbios` at `b8bc745`. On the VM, `sim/work/bupchip/bios/7800openbios.bin` has md5 `659607f14d1a0743c004d2b0bc0807fc`. Section 5.3 refers to an md5 that it does not give; whether this one matches the container's is not recorded.
- **Firmware:** the owner uploaded it on 2026-10-18. `src/fpga/mister/rtl/bupchip.hex` (17,604 B, md5 `eae50bf9b79013550a5852c71d04af3f`) and `.mif` (40,910 B, md5 `3b1ac1a950d754b4e95d6895483f60d3`) are byte-identical to the copies at `0c6996b^` (section 10, item 1). Both are gitignored. With them, `sim/bupchip/model/check.sh` (14 s) and `sim/bupchip/verif/run_all.sh` (2 min 29 s) pass with no step skipped.
- **The ROM library:** `~/ROMLibrary` (1.4 GB, outside the repo, on disk), uploaded by the owner on 2026-10-18 in two parts. New uploads arrive in `~/inbox`. Copy what a bench needs from the library into `sim/work`; never into the tree. It holds:
  - Trebor's 7800 ROM ProPack v8_17 (1,308 `.a78`: `Retail_v7_0` NTSC and PAL, and `UPHHD_20260101` with demos and hacks);
  - `atari-2600-roms-usa.zip` (259 `.a26`);
  - `supercharger/`: the Supercharger BIOS `supercharger.bin` (2,048 B, md5 `4565c1a7abce773e53c75b35414adefd`; for `--arfw FILE`, section 6), its games, `Supercharger_test_images.zip` (the three AR Test images) and a STELLA2 tape image;
  - `RikkiVikki/`: the ProSystem install `make_arsc.py` reads (`Data/FoxBox.cdf`, `Data/FoxBox.bin`, `Music/`), `Rikki and Vikki.a78` (headered), `Rikki and Vikki (BupChip).a78`, `RV_Jukebox.a78`, a `.bps` patch, old Pocket test builds, and a second copy of the firmware (identical);
  - the Champ Games demo zips: `Champ-Games_demo_all_NTSC.zip` (15 CDFJ demos) and `Champ-Games-Presents_demo_all_NTSC.zip` (13 DPC+ demos), and the full Juno First and Stratovox;
  - homebrew images: Draconian, SF2 (`SF2fix_NTSC/PAL.bin`, the Stay Frosty 2 demo), `RobotWar-2684_demo_final_NTSC_Harmonyfix.bin`, `spacerocks_Harmony_fix.bin`, Frantic, Omicron, Go Fish, Grizzards, Boulder Dash, the AtariVox speech tester, `sync.bin`, `hiscore.bin`, two Triple Punch builds;
  - the firmware files above.
  - `RikkiVikki/` also carries a `make_arsc.py` (identical to the repo's) and a `hex2bin.py`; use the repo's.
- **What the benches read,** copied from the library on 2026-10-18, under `sim/work/bupchip/`:

  | Path | Contents | Used by |
  |---|---|---|
  | `game/rv.a78` | built by `python3 sim/bupchip/make_arsc.py ~/ROMLibrary/RikkiVikki sim/work/bupchip/game/rv.a78 --rom ~/ROMLibrary/RikkiVikki/"Rikki and Vikki.a78"`: 524,416 B cartridge + 211.8 KiB ARSC, 32 songs, md5 `c7b8be98f5de9ec07667352a925823a8`, byte-identical to the uploaded `Rikki and Vikki (BupChip).a78` | s1, s4, model, verif songs, jukebox |
  | `champ/ntsc/` (and `champ/readme/`) | `Champ-Games_demo_all_NTSC.zip`, unzipped | `frames` (FRAMES16), `wire`'s Turbo run (`GAMES`) |
  | `champ_presents/arm/` | the `cgp/` images of `Champ-Games-Presents_demo_all_NTSC.zip`; `Dino-Eggs_demo_final_CGP_ NTSC.bin` renamed without its space, as `docs/daria_fe/lanes/G_step7_resets.md:61` names it | `frames` (Stratovox), the lane docs' runs |
  | `daria/roms/` | the homebrew `.bin` images above, Juno First full, the SF2 demo, `sync.bin`, `hiscore.bin` | the lane docs' runs (for example G_step7_resets.md:60-62) |

  `GAMES=sim/work/bupchip` finds all 16 FRAMES16 images (`step7_gates.sh` searches it with `find`).
- **The MiSTer reference PCMs** (`sim/work/bupchip/ref/song<N>.pcm`, section 5.4) were made on the VM on 2026-10-18, not uploaded: `WORK=sim/work/bupchip/refgen/s<N> sim/bupchip/run_bupchip.sh sim/work/bupchip/game/rv.a78 <N> 4` for songs 6, 9, 10, 13, 14 and 30 (song 13 first, which builds; the other five at once, sharing its `obj_dir`), then copied into `ref/`. Each is 767,936 B (191,984 frames, as `docs/BUPCHIP_CORE.md:872`). Song 13 took about 4 min, the five together about 3 min.
  - `sim/bupchip/s1/check.sh sim/work/bupchip/game/rv.a78`: every step PASS, songs 13, 14, 9 and 30 "PCM identical to MiSTer's" (8 min). Without the references the four songs FAIL with "PCM not compared", although they play cleanly.
  - `sim/bupchip/model/check.sh ../../work/bupchip/game/rv.a78` (from `sim/bupchip/model`): all six references equal over all 191,984 frames, PASS (3 min 11 s).
- **Reference clones:** the clones of section 5.6 (lroby74, the Jaguar repo, retrobios, cdfjplus-template) are absent. No script needs them.

### 11.6 Sessions and long runs

The VM does not stop when a session goes idle, and has no 13-hour limit (sections 8.1 and 8.4). Work is still lost when the agent's session itself ends. An interactive session ends when its terminal or SSH connection closes; any session ends when the login expires or the VM reboots.

- **Background sessions:** a session started as a background job of the agent's CLI runs under the CLI's daemon process (its parent is systemd), not under the terminal. Closing the terminal or the VNC client does not end it [observed: the process tree, 2026-10-19]; a reboot does.
- **tmux:** for an interactive session, start the agent's CLI inside tmux (`tmux new -s agent`), and come back with `tmux attach -t agent` after a disconnect.
- **Login:** a long-lived token from the CLI's `setup-token` command, exported in its OAuth-token variable, keeps a login from expiring, but its scope is inference only, so Remote Control refuses it. On 2026-10-19 that export in `~/.bashrc` was commented out for this reason, and the VM uses the normal login, which renews itself with its refresh token.
- **Detached runs:** start runs that must outlive the session with `setsid`/`nohup`, as section 7.5 says. Linger is off. With `sudo loginctl enable-linger miasmark`, `systemd-run --user` would also keep runs after a logout, with `systemctl --user` to inspect them.
- **Resuming:** a workflow can be resumed only in the session that started it. Keep the habits of section 8.4: split runs into pieces that write their own results and skip finished pieces when run again, and commit `WIP snapshot: …` commits.
- **Load:** on this VM, at most 4 simulations while no Quartus job runs, and 3 while one does; Quartus runs one job at a time, under the lock of 3.5 (the owner, 2026-10-19: "4 sims or 1 quartus run +3 sims"), as section 7.4 states. The earlier limits (3 and 2) were set for the container's 4 CPUs.

### 11.7 Headroom measured on 2026-10-18

A test of the VM under concurrent load, on `Mister-Pocket-Port` at `6e2e880`, with the balloon of 11.8 inflated (about 14 GiB usable; since 2026-10-21 at least about 22 GiB stay with the VM, 11.8). It is a measurement, not a rule; the owner set the VM's limits afterwards (11.6).

- **Method:** a simulation job was `tb_fe_guard` (built by `sim/bupchip/daria/fe_unit/run_unit.sh`, about 24 s a run, one thread) run back to back under `nice -n 10`, each run timed. The Quartus job was the CI-form full compile (section 3.4) of a copy of `src/fpga` in `$RAM_WORK`. `vmstat` and `/proc/pressure` (PSI) were sampled every 5 s. All runs passed and both compiles succeeded. The driver script was not committed.
- **Simulations:**

  | Load | Mean run | Slowdown |
  |---|---|---|
  | 1 alone | 23.5 s | - |
  | 4 at once | 24.5 s | 4% |
  | 6 at once | 25.3 s | 8% |

  CPU and memory PSI stayed at 0 in every simulation-only phase.
- **Quartus:**

  | Load | Compile | Simulations beside it |
  |---|---|---|
  | alone | 656 s (10 min 56 s) | - |
  | with 3 simulations | 718 s (9% slower) | mean 27.3 s (16% slower), worst 35.7 s |

  - Alone, the compile used 26 min 26 s of CPU time, about 2.4 cores on average, with 3.9 GB peak virtual memory.
  - With 3 simulations, CPU PSI averaged 3.7% and peaked at 19%: the first contention seen.
  - Memory PSI stayed at 0, nothing was swapped, and free memory never fell below 7.6 GiB.
- **Proposal (not adopted):** at most 5 simulations at once while no Quartus job runs, 3 while one does, and one Quartus job at a time under the lock (3.5). The bench is small; whole-core simulations (`run_daria.sh`, `tb_frames`) hold far more state and may contend more for the 12 MiB L3, so treat 5 as a ceiling. 4 simulations beside Quartus were not tested.

### 11.8 The memory balloon

- **Symptom:** the VM has a virtio balloon device (`/sys/bus/virtio/drivers/virtio_balloon/virtio3`). On 2026-10-18 `free` showed about 17 GiB used at idle, while processes held about 1 GiB and kernel memory and page cache about 2.5 GiB. The rest matches the balloon taking memory back for the host, which leaves about 14 GiB usable of the 30 GiB. Reading the balloon's size needs root (`/sys/kernel/debug/virtio-balloon`) and was not done.
- **Cause:** the host's ZFS ARC (its read cache), which takes memory back from the VM through the balloon (the owner, 2026-10-18).
- **Effect (before the cap below):** the RAM scratch caps of 11.4 (13 GB each) assume the full 30 GiB. The headroom test of 11.7 ran under the balloon without memory pressure.
- **Fix (on the host):** set the VM's minimum memory to its full allocation, or turn ballooning off, then restart the VM. Capping the host's ARC (`zfs_arc_max`) so that the host never needs the VM's memory works too.
- **Capped on 2026-10-21 (the owner):** the host may now reclaim at most 8 GiB from the VM, so at least about 22 of the 30 GiB stay with the VM, against about 14 under the old balloon. How the cap is set on the host is [not recorded]. On 2026-10-23 `free -g` showed 30 GiB total and 20 GiB available, with 17 GiB of it page cache [measured].
- **What the cap means for 11.4:** one RAM scratch mount filled to its 13 GB cap fits in the 22 GiB beside a Quartus job (3.9 GB peak virtual memory, 11.7) and the simulations. Both mounts filled at once (26 GB) would not, because tmpfs pages live in RAM or swap (a 4 GB swap file). Keep their combined use well under what the 22 GiB leaves after the running jobs.
- **What the cap means for 11.7:** the headroom test ran with about 14 GiB usable and saw no memory pressure (free memory never below 7.6 GiB), so its memory findings hold with room to spare. Its limits were set by CPU contention, and 11.6's job limits stand unchanged.
