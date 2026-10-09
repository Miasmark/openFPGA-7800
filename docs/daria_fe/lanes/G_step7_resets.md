# Lane G: design 12.2 step 7: console resets and the 7800 BIOS in game runs, and where pause is covered (DARIA step 6)

Design 12.2 step 7 asks for "`+hard_reset_at` once per scheme; `use_bios`; pause", with the gate of step 6: 0 outside the classes of design 9.5. This lane ran the reset part and the BIOS part in mode A, with bench stage 1: `tb_daria` with `FE=1`, `daria_fe` beside upstream's front ends (E1_shadow.md). It used one game image per scheme for each. For the BIOS part it added `+bios=FILE` to `tb_daria` and ran the games through the 7800 OpenBIOS (section 8). It also states where the coverage of pause comes from, since the Pocket never pauses, and what covers the BIOS path besides these runs.

**Status.**

- **Every reset run passes.** There are seven runs:
  - five with `+hard_reset_at`, one per scheme: DPC+ revision 0 and 1, CDF1, CDFJ and CDFJ+;
  - two with a console reset inside a running ARM call, on DPC+ and CDF1.

  In each run the reset lands during gameplay, and the "FE reset:" lines show the console reset. `daria_fe` then runs F6 again (2,082 clk_sys; 8,226 for CDFJ+) while upstream re-initialises, and the checks resume. Every one of the 46 must-be-0 counters of the `FE bad:` line is 0: before the reset, in the frame that holds it, and in every frame after it (section 3).
- **Classes seen in the reset runs.** `merge_amp` (CDF without the hook, each one resynced) is the only class of design 9.5 that occurs, as in lane E1's runs. The other non-zero count is the O1 information counter `drift_up`. `pre_lock` is 0 in every reset run; it occurs only on the BIOS path (section 8).
- **Resets inside an ARM call.** `+hard_reset_at` cannot place one there. It raises the reset at the VSYNC rise that starts frame F, which is a 6507 write, and the 6507 is held while upstream's ARM runs a call or a DPC+ service.
  - The bench can still do it, through lane E2's event monitor (`fe_dir_mon.sv`, `+dir_rst=1`). The monitor raises the reset a set number of clk_sys after the n-th call accept, and is built into the same stage-1 bench.
  - Two runs use it, on SF2fix (DPC+) and draconian RC8 (CDF1). Each places the reset halfway through a gameplay call, while upstream's controller is in CTRL_RUNNING (section 2.2).
- **The same state after the reset as after the load.** On draconian (both runs) and Dino Eggs, the 99 frames after the reset are identical, row for row, to the 99 frames after the power-on load, in `frames.csv` and in `fe.csv`. On those games the boot screen ignores the joystick (section 3.3).
- **The directed reset and pause tests were rerun on this RTL**: all 17 pass (section 4).
- **`use_bios`: `tb_daria` takes `+bios=FILE` now** (8.2). Every BIOS run, diagnostic and `FE=1` regression run below was repeated on the final binary, `bios4`, after the review's one change to the bench's counters (8.2), with the same results. It serves the BIOS as the Pocket does: `bypass_bios` 0, `tia_mode` 0, a ROM read with one clk_sys of latency, at an address masked by the file's size. Without `+bios` the bench is unchanged: a plain run and two `FE=1` runs, one with a console reset, give byte-identical outputs on the old and the new binary (8.3).
- **BIOS runs with the 7800 OpenBIOS, one image per scheme, and one with a console reset: every must-be-0 counter is 0 in all six** (8.5).
  - **SF2fix (DPC+ r0), draconian RC8 (CDF1) and Mappy (CDFJ).** The BIOS hands over to 2600 mode 319,137-319,225 clk_sys after the release: INPTCTRL $FD sets `lock_ctrl` and `tia_en` at one clock. The game then runs 300 frames into gameplay. Its frames are identical to those of the runs without the BIOS until the random input makes them differ (all 299 on Mappy).
  - **draconian with a console reset at frame 230.** The BIOS boots again and hands over again; PASS, with `pre_lock` 4,005 in each boot. The 99 frames after the reset are identical to the 99 after the load, in `frames.csv` and `fe.csv`. Against the 99 after the reset of the run without the BIOS, `frames.csv` is identical too, and `fe.csv` differs only in per-frame counts of ticks, `crb_use` and the classes: the BIOS's boot moves the audio tick's phase against VSYNC (8.5).
  - **`daria_fe` stays correct through the BIOS's 7800-mode cartridge reads** (8.7):
    - about 390 slot cycles with A12 in each boot, among them the bank-switch hotspot $1FF8;
    - no commit on either side;
    - C1/C2 equal at every one of the 39,080-39,090 `pclk1` of each boot.
  - **`pre_lock` occurs, with its condition confirmed** (8.6): 1,335 times on SF2fix and 4,005 on draconian and Mappy. At every one of those grants upstream's port A held the 7800 path's address. Without the bench's resyncs, AMPLITUDE differs during the boot and up to the end of the first refresh after `tia_en`, never after it.
- **A core finding, outside `daria_fe`** (8.8). On this core the OpenBIOS never hands over for a DPC+ revision 1 or CDFJ+ image, and this holds for every such image in `sim/work`.
  - The BIOS reads the reset vector through `cart.sv`, which maps a 2600 image as a 7800 cartridge. It finds $0000 (Dino Eggs) or $FFFF (Elevator Agent), takes the slot as empty and starts its own game after about 5.3 s of Fuji screen.
  - The Pocket builds the same `cart.sv` and `top.sv`.
  - Those two runs still check `daria_fe` through 77 million clk_sys of 7800 mode: 9,616,380 `pclk1` compared, 0 differ; `pre_lock` 322,395 and 967,185. They pass, but they cover no hand-over for those two schemes.
- **Pause is not built:** the Pocket never pauses. Section 5 states where its coverage comes from, with counts, and what covers the BIOS path besides section 8. It also corrects the brief: lane E3's 7800-mode intervals do not exercise `pre_lock`, because E3's model of port A does not follow the 7800 path's address. Only the BIOS runs of section 8 do.
- **No `daria_fe` RTL issue found.** The only file changed besides this report is `sim/bupchip/daria/tb_daria.sv`, and nothing was committed. Game- and BIOS-derived outputs are under `sim/work/bupchip/daria/fe_reset/` (section 7). The BIOS image is all rights reserved in part, so nothing derived from it may be committed.
- **One observation outside this lane (section 6.1).** The mode-A batch now running (`obj_fe_modeA`) uses a binary built before F1's RTL and bench changes.

---

## 1. Builds and commands

### 1.1 Builds

The first three builds are from commit `1fb9d95` with a clean tree. The checksums of every source file used are in `sim/work/bupchip/daria/fe_reset/sources.md5`, and every job checked them or its binary's md5 before it ran. The two `bios3` builds are from the same sources with this lane's `tb_daria.sv` (section 8.2; checksums in `fe_reset/bios3_sources.md5`, which differs from `sources.md5` in that file alone). Two earlier builds of the change, `fe_reset/bios` and `fe_reset/bios2`, were replaced by them (8.3). The `bios4` build is the final one: `bios3`'s sources with the review's change to the `BIOS pre_lock:` line's counters (8.2; `fe_reset/bios4_sources.md5` differs from `bios3_sources.md5` in `tb_daria.sv` alone, and lists no `fe_dir` file, which `bios4` does not build). The BIOS runs, the diagnostics and the `FE=1` regression were all repeated on it. The commit `54bf688` since then adds only a draft of this report. The `daria_fe` RTL is unchanged since `65a11f0` (F1's review), so these runs are on the final step-6 RTL.

| Build | Command | Binary (md5) | Used for |
|---|---|---|---|
| `frame` | `WORK=…/fe_reset/frame FE=1 sim/bupchip/daria/run_daria.sh --build-only` | `fe_reset/frame/obj_fe/vtb` (`56a59e02…`) | the five `+hard_reset_at` runs |
| `call` | the same with `WORK=…/fe_reset/call VERILATOR=sim/bupchip/daria/fe_dir/vwrap.sh`: lane E2's wrapper adds `fe_dir_mon.sv`, bound into `tb_daria` and read-only except for its injections (off by default) | `fe_reset/call/obj_fe/vtb` (`3e106750…`) | the two resets inside a call. Byte-identical to the binary `fe_dir/run_dir.sh` built for the directed rerun (section 4) |
| `plain` | `WORK=…/fe_reset/plain sim/bupchip/daria/run_daria.sh` (no `FE`) | `fe_reset/plain/obj/vtb` (`994820c6…`) | one timing run, to find when Elevator Agent's gameplay starts (2.3); the old side of the plain regression (8.3) |
| `bios3` | `WORK=…/fe_reset/bios3 FE=1 sim/bupchip/daria/run_daria.sh --build-only`, with `+bios` in `tb_daria.sv` | `fe_reset/bios3/obj_fe/vtb` (`015ec0c0…`) | the first BIOS runs, the diagnostics and the new side of the `FE=1` regression (section 8), all repeated on `bios4` |
| `bios3_plain` | `WORK=…/fe_reset/bios3_plain sim/bupchip/daria/run_daria.sh --build-only`, the same `tb_daria.sv` | `fe_reset/bios3_plain/obj/vtb` (`7ae550cb…`) | the new side of the plain regression (8.3); `bios4`'s change does not reach a plain build |
| `bios4` | `WORK=…/fe_reset/bios4 FE=1 sim/bupchip/daria/run_daria.sh --build-only`, the final `tb_daria.sv` | `fe_reset/bios4/obj_fe/vtb` (`f148b517…`) | the final BIOS runs, diagnostics and `FE=1` regression runs (8.3, 8.5) |

Each build has its own `WORK`, so that nothing here touches the shared `obj_fe` or the mode-A batch's `obj_fe_modeA`. Each run used `NOBUILD=1` against its frozen binary, and the job checked the binary's md5 first. Only one simulation of this lane ran at a time, through a queue (`fe_reset/queue.txt` and `fe_reset/runner.log` for the reset runs, `fe_reset/queue_bios.txt` and `fe_reset/runner_bios.log` for the regression and the BIOS runs on `bios3`, `fe_reset/queue_bios4.txt` and `fe_reset/runner_bios4.log` for their repeat on `bios4`). The `frame` binary is also the old side of the `FE=1` regression (8.3).

### 1.2 Runs

Every run is `run_daria.sh` with `FE=1 NOBUILD=1 DTRACE=0` and `+snap=0`. Every command has the form `cd /home/user/openFPGA-7800 && WORK=/home/user/openFPGA-7800/sim/work/bupchip/daria/fe_reset/<build> FE=1 NOBUILD=1 DTRACE=0 NAME=<name> sim/bupchip/daria/run_daria.sh /home/user/openFPGA-7800/<image> <plusargs>` (the exact lines are in `fe_reset/queue.txt`), with:

| Name (build) | Image | Plusargs |
|---|---|---|
| `dpcp0_SF2fix` (frame) | `sim/work/bupchip/daria/roms/SF2fix_NTSC.bin` | `+frames=300 +snap=0 +fire_at=40 +play_at=70 +hard_reset_at=180` |
| `dpcp1_DinoEggs` (frame) | `sim/work/bupchip/champ_presents/arm/Dino-Eggs_demo_final_CGP_NTSC.bin` | `+frames=600 +snap=0 +fire_at=420 +play_at=480 +hard_reset_at=500` |
| `cdf1_draconian` (frame) | `sim/work/bupchip/daria/roms/draconian_20171020_RC8.bin` | `+frames=330 +snap=0 +fire_at=140 +play_at=150 +hard_reset_at=230` |
| `cdfj_Mappy` (frame) | `sim/work/bupchip/champ/ntsc/Mappy_demo_final_CG_NTSC.bin` | `+frames=430 +snap=0 +fire_at=185 +play_at=200 +hard_reset_at=340` |
| `cdfjp_ElevatorAgent` (frame) | `sim/work/bupchip/champ/ntsc/Elevator-Agent_demo_final_CG_NTSC.bin` | `+frames=860 +snap=0 +fire_at=0 +play_at=40 +hard_reset_at=760` |
| `dpcp0_SF2fix_call` (call) | SF2fix_NTSC.bin | `+frames=250 +snap=0 +fire_at=40 +play_at=70 +dir_rst=1 +dir_rst_n=226 +dir_rst_dly=4000` |
| `cdf1_draconian_call` (call) | draconian_20171020_RC8.bin | `+frames=300 +snap=0 +fire_at=140 +play_at=150 +dir_rst=1 +dir_rst_n=401 +dir_rst_dly=8000` |

`+hard_reset_len` was left at its default (1,000 clk_sys); section 2.1 explains why no longer value was needed. The `+fire_at`/`+play_at` values are needed because `tb_daria`'s defaults (FIRE at frame 420, random input from 480) would keep every game at its title for the first 420 frames; section 2.3 explains each choice. The run lengths go beyond the brief's "about 300 frames" only where the game's own start takes longer: Mappy shows a logo for 180 frames before its title takes FIRE, Dino Eggs ignores FIRE for at least its first 107 frames, and Elevator Agent has a title menu and a 400-frame level intro.

## 2. Where the resets land

### 2.1 `+hard_reset_at=F`

The reset is raised in `fe_shadow.svh:635-647`. At the first clk_sys where `tb_daria`'s `frame` equals F, which is the VSYNC rise that starts frame F, it sets `reset_in`. It clears it `+hard_reset_len` clk_sys later. What happens then:

1. `tb_daria` registers `reset_in` into the console `reset` (`tb_daria.sv:100`). The bench sees `effective_reset` high 2 clk_sys after the drive ("FE reset: console reset from …; checks paused"); 1 clk_sys after it for the monitor's drive of 2.2.
2. `daria_fe` sees the rise on `cart_reset` (its `rst_fe`) and starts F6 9 clk_sys after the bench first sees the console reset, as in every E2 reset test (design 7.1: F6 eight clocks after the rise). `init_busy` holds the console in reset.
3. The bench's sticky hold (`fe_shadow.svh:1097-1117`) and upstream's own `mapper_init_busy` keep the console in reset until both inits are done.

Upstream's re-init is the longer of the two in every run, as at the load: 5,259 clk_sys for DPC+, 3,475-3,479 for CDF and 9,623 for CDFJ+, against `daria_fe`'s F6 of 2,082 and 8,226 clk_sys. So the 1,000-clk_sys pulse is only the trigger, and the release is upstream's ("FE init: upstream's init done at …"). The checks resume 13-24 clk_sys later, at the first `pclk1` with the console running. With `bypass_bios`, `tia_en` rises in the first clock after the release, so the window in which design 9.5's `pre_lock` could arise is at most that one clock; no audio grant fell in it (`pre_lock` 0 in every run).

A VSYNC rise is a 6507 write. During an upstream call or DPC+ service the 6507 is held (`arm_call_stall`), so this reset can never land inside one (E2_directed.md 2.3). In all five runs the previous call had ended 10,673 to 224,067 clk_sys before the reset, and no service was running. The reset lands at a frame start in the middle of gameplay, between the game's calls, with the fetchers, the audio engine and (CDF) the stream pointers in use.

### 2.2 Inside a call: `+dir_rst=1` (lane E2's monitor)

`fe_dir_mon.sv` (`+dir_rst=1 +dir_rst_n=N +dir_rst_dly=D`, lines 19-31 and 158-175) drives the same `reset_in`, for `+dir_rst_len` clk_sys (1,000), D clk_sys after upstream's N-th call accept. Its "DIR inject:" line records the controller's state at that clock.

The call and the delay were chosen from the `+hard_reset_at` run of the same image and inputs. That run is identical to the call-reset run up to the reset: both have call N's request on the same clk_sys. Each reset lands about halfway through a gameplay call.

| Run | Call | Requested at | That call's length (from the frame run) | Reset at | In the call | DIR inject: |
|---|---|---|---|---|---|---|
| `dpcp0_SF2fix_call` | #226, frame 150 line 3 (72 frames into gameplay) | 35,746,928 | 9,577 clk_sys | 35,750,928 | +4,000 (42%) | `call_busy 1 ctl 5 dma_busy 0 init_busy 0` |
| `cdf1_draconian_call` | #401, frame 200 line 3 (53 frames into gameplay) | 47,671,148 | 16,507 clk_sys | 47,679,148 | +8,000 (48%) | `call_busy 1 ctl 5 dma_busy 0 init_busy 0` |

`ctl 5` is CTRL_RUNNING (`arm_mapper_controller.sv:182-191`): upstream's ARM was executing the call's code, with the 6507 held.

`daria_fe` had posted that call 7 clk_sys after the accept, as for every call (R1 "post - accept {7:…}"). The reset drops it (design 6.5). Upstream accepted 381 calls and completed 380 on SF2, and 600 and 599 on draconian (the monitor's `call_accept`/`call_done`). R1 compared every post, the abandoned one included, and on draconian the abandoned call made no merge (599 own-path merges for 600 calls).

The monitor's "DIR: marker …, self-check errors …" figures in these two logs are meaningless here. They read the RIOT RAM bytes $FF and $FE, which E2's synthetic programs use as markers and which a game uses for its own data.

### 2.3 Gameplay: how the frames were chosen

The joystick inputs are `tb_daria`'s: FIRE held for 6 frames from `+fire_at`, then from `+play_at` a pseudo-random joystick and a FIRE pressed most of the time (`tb_daria.sv:788-806`). Whether a game is in play was judged from its per-frame ARM profile (`frames.csv`: calls and ARM instructions per frame). That profile was matched against the reference runs of the same images (`runs/<image>/`, 1,500 frames, FIRE at 420), whose snapshots show the screen every 150 frames. No snapshot was taken in these runs (`+snap=0`).

| Image | Profile of this run | Gameplay from | Reset frame |
|---|---|---|---|
| SF2fix (DPC+ r0) | title: 1 call a frame, about 2,500 instructions (FIRE at 40 is ignored there); the random FIRE starts the game at frame 76; from frame 78, 2 calls a frame, about 21,700 instructions (the reference's frames 430+; its snapshot at 600 shows the level in play) | 78 | 180 (+102) |
| Dino Eggs (DPC+ r1) | no ARM call on the title; FIRE at 420 starts the game at once: 5 copy services in frame 420, then 1-2 calls a frame (5,579-11,854 instructions), the pattern the reference run keeps to its last frame | 420 | 500 (+80) |
| draconian RC8 (CDF1) | boot screen to frame 128 (about 1,300 instructions a frame, input ignored), title from 129, FIRE at 140, from 147 2 calls a frame, about 35,000 instructions (the reference's frames 430+; its snapshot at 600 shows SECTOR 1 in play) | 147 | 230 (+83) |
| Mappy (CDFJ) | logo to 179, title from 180, FIRE at 185, READY at 191-204, round start 205-236, from 237 2 calls a frame alternating about 16,900 and 19,500 instructions (the reference's frames 520+; its snapshot at 600 shows the mansion in play) | 237 | 340 (+103) |
| Elevator Agent (CDFJ+) | logo and title to frame 276 (2 calls a frame, about 12,000 instructions, then alternating about 31,000 and 55,000); the random FIRE from 40 starts the game at frame 277 (19,000 instructions); the opening sequence from 278 (2 calls a frame, 29,000-34,000 instructions); from 680 2 calls a frame, 31,284-31,363 instructions. This is the reference run's profile shifted by 232 frames, frame for frame: its game start is 509 and its landing 912 | 680 | 760 (+80) |

Two images needed more than a first guess:

- **Dino Eggs.** A first run with `+fire_at=40 +play_at=70` made no ARM call through frame 107: the title ignored both the FIRE at 40 and the random FIRE from 70. That run was stopped (its process killed by PID, its partial outputs deleted) and replaced by the reference run's inputs, which start the game at frame 420.
- **Elevator Agent.** In the reference run, the first FIRE (frame 420) brings up a menu. The next one starts the game (frame 507). A 402-frame opening sequence follows: the agent rides a zip line down to the roof. The roof landing, where the player takes control, is at frame 912 (`runs/Elevator-Agent_demo_final_CG_NTSC/`, snapshots 450-1050).
  - A plain-build run (`fe_reset/plain/runs/explore_ElevatorAgent`, 450 frames, random input from frame 40, no front-end shadow, the same DUT timeline) showed the game starting at frame 278. FIRE skips the logo.
  - So the landing falls near frame 680, and the reset frame is 760.
  - The FE run's own `frames.csv` is identical to the plain run's in all 449 rows they share (frames 1-449). Its profile from frame 277 on is the reference run's from 509 on, frame for frame (2.3's table), so the landing is at frame 680 (912 − 232). The reset at 760 is 80 frames after it.

## 3. Results

### 3.1 Per run

"FE result" is the `FE result:` line: PASS means all 46 counters of the `FE bad:` line are 0 (design 9.6's list and the bench's own must-be-0 checks; E1_shadow.md 3, V.3). Counts are from `FE shadow:`/`FE counts:`. Clocks are clk_sys from time 0.

| Run | Scheme | Frames | Reset driven (frame) | Where it landed | F6 again (start, length) | Upstream's init done; checks resume | First call after | FE result | Classes (design 9.5) |
|---|---|---|---|---|---|---|---|---|---|
| `dpcp0_SF2fix` | DPC+ r0 | 300 | 42,912,152 (180) | VSYNC rise; call #285 (frame 179 line 241) ended 15,619 earlier; no call or service in flight | 42,912,163, 2,082 | 42,917,413; 42,917,437 | #286, +38,532 | PASS (0 bad) | none |
| `dpcp1_DinoEggs` | DPC+ r1 | 600 | 119,414,132 (500) | VSYNC rise; call #105 (frame 499 line 13) ended 224,067 earlier | 119,414,143, 2,082 | 119,419,393; 119,419,417 | #106 (the boot call, as #1 at power-on), +40,092 | PASS (0 bad) | none |
| `cdf1_draconian` | CDF1 | 330 | 54,836,624 (230) | VSYNC rise; call #460 (frame 229 line 230) ended 26,192 earlier | 54,836,635, 2,082 | 54,840,101; 54,840,121 | #461, +36,720 | PASS (0 bad) | `merge_amp` 11 (8 before the reset, 3 after), `resync` 11 |
| `cdfj_Mappy` | CDFJ | 430 | 81,129,212 (340) | VSYNC rise; call #679 (frame 339 line 246) ended 12,479 earlier | 81,129,223, 2,082 | 81,132,693; 81,132,709 | #680, +44,508 | PASS (0 bad) | `merge_amp` 10 (7 before, 3 after), `resync` 10 |
| `cdfjp_ElevatorAgent` | CDFJ+ | 860 | 182,269,460 (760) | VSYNC rise; call #1519 (frame 759 line 247) ended 10,673 earlier | 182,269,471, 8,226 | 182,279,085; 182,279,101 | #1520, +749,352: the game's first call, 739,727 clk_sys after upstream's init, as #1 came 739,733 after the load's release | PASS (0 bad) | `merge_amp` 21 (18 before the reset, 3 after), `resync` 21 |
| `dpcp0_SF2fix_call` | DPC+ r0 | 250 | 35,750,928 (150) | inside call #226, 4,000 after its request, controller RUNNING | 35,750,938, 2,082 | 35,756,188; 35,756,209 | #227, +44,300 | PASS (0 bad) | none |
| `cdf1_draconian_call` | CDF1 | 300 | 47,679,148 (200) | inside call #401, 8,000 after its request, controller RUNNING | 47,679,158, 2,082 | 47,682,624; 47,682,637 | #402, +43,360 | PASS (0 bad) | `merge_amp` 9 (6 before, 3 after), `resync` 9 |

In every run:

- "FE resets: 1 console resets after the checks started, 2 starts of the checks, 2 handoffs to the TIA's phases";
- I1/I2 compared the whole cart RAM (and, for CDF, the stream tables) after both inits, twice ("2 inits"), with `init_bad` 0;
- `E0->latch` 6..6 and `FE S1: 0`; `pre_lock` 0; `p32_reset` 0; `merge_late` 0; the longest A1 mask at most 18 clk_sys (`mask_stuck` 0);
- the stage-0 reference beside `u_fe` 0/0 ("FE reference:");
- `drift_up` (O1 information: upstream's `d_out` moving after the latch) 195,136 to 2,351,060 a run, as in every mode-A run; `drift_fe` 0.

### 3.2 What was compared, in all and from the reset on

From the reset on means the row of the frame that holds the reset plus every later row of `fe.csv` (the frame counter stops while the TIA is in reset, so that row covers the end of the frame before the reset, the reset, the re-init and the boot up to the game's first VSYNC).

| Run | Latches (all / from the reset) | Commits (all) | Calls R1/K1 (all / from the reset) | Services R2/R3 | Ticks (all / from the reset) | C3 pointer writes (all / from the reset) | K2 frames (all / from the reset) | Must-be-0 in `fe.csv` rows from the reset | Wall |
|---|---|---|---|---|---|---|---|---|---|
| `dpcp0_SF2fix` | 5,943,438 / 2,374,359 | 5,168,318 | 406 / 121 | 0 | 99,622 / 39,798 | 0 | 299 / 120 | 0 | 900 s |
| `dpcp1_DinoEggs` | 11,923,688 / 1,979,444 | 10,788,771 | 106 / 1 | 5 (frames 263 and 420) | 199,863 / 33,179 | 0 | 599 / 100 | 0 | 2,280 s |
| `cdf1_draconian` | 6,537,308 / 1,974,374 | 5,915,475 | 659 / 199 | 0 | 109,567 / 33,091 | 234,834 / 21,490 | 329 / 100 | 0 | 1,199 s |
| `cdfj_Mappy` | 8,529,966 / 1,775,983 | 7,370,809 | 858 / 179 | 0 | 142,966 / 29,765 | 503,778 / 87,547 | 429 / 90 | 0 | 1,697 s |
| `cdfjp_ElevatorAgent` | 17,208,758 / 2,033,419 | 13,084,556 | 1,718 / 199 | 0 | 288,427 / 34,080 | 2,377,225 / 256,522 | 859 / 100 | 0 | 3,320 s |
| `dpcp0_SF2fix_call` | 4,948,429 / 1,976,710 | 4,268,416 | 381 / 156 | 0 | 82,944 / 33,133 | 0 | 249 / 100 | 0 | 1,071 s |
| `cdf1_draconian_call` | 5,940,851 / 1,975,277 | 5,449,158 | 600 / 200 | 0 | 99,570 / 33,106 | 173,313 / 21,499 | 299 / 100 | 0 | 1,293 s |

The "must-be-0" column sums all 46 must-be-0 columns of `fe.csv` over the rows from the reset on (every counter of the `FE bad:` line has a column). The rows before the reset sum to 0 as well. After the reset each game is back at its boot or title screen. Dino Eggs makes no call there (as at power-on), so its post-reset part checks the bus, the fetchers, the audio engine and the RAM, but no call.

### 3.3 The state after the reset

Two of the games ignore the joystick on their boot screen: draconian for its first 128 frames, Dino Eggs for at least its first 107 (2.3). For these, the frames after the reset can be compared with the frames after the power-on load, since the inputs cannot make them differ.

| Run | Rows equal, the 99 frames after the reset against frames 1-99 after the load |
|---|---|
| `cdf1_draconian` | 99 of 99 in `frames.csv` (calls, ARM instructions, ARM cycles, stall and DMA clocks, every column but the frame number and its time) and 99 of 99 in `fe.csv` (every compared count and every must-be-0 counter) |
| `cdf1_draconian_call` | 99 of 99 and 99 of 99. Its 99 post-reset rows are also identical to `cdf1_draconian`'s: the reset leaves the same state whether it hits a frame start or the middle of a call |
| `dpcp1_DinoEggs` | 99 of 99 and 99 of 99; the boot call #106 lasts 5,416 clk_sys, as #1 did |
| `dpcp0_SF2fix` / `_call` | 11 / 17 of 99, until the random joystick, which was off at power-on, changes the title's behaviour |
| `cdfj_Mappy` | 0 of 89. The instruction counts agree in the first frames but the ARM cycle and stall columns do not (23,842 against 23,782 cycles in the first frame), so upstream's ARM timing differs after a reset; then the random input ends the logo early. Not a front-end quantity |
| `cdfjp_ElevatorAgent` | 7 of 99 in `frames.csv`, 23 of 99 in `fe.csv`. The first call comes 739,727 clk_sys after upstream's init, against 739,733 after the load's release, and lasts 5,368 clk_sys both times. The instruction counts agree for the first 19 frames, but from the 8th frame the ARM cycle column differs by a few cycles (32,703 against 32,708), as on Mappy. Then the random input, on from the reset's first frame but only from frame 40 after the load, changes the title's behaviour. Not a front-end quantity |

### 3.4 Failures

None. No `daria_fe` failure was logged (`fe_err.txt` reads "No failures" in all seven runs), so there is nothing to trace and no reproduction to give.

## 4. The directed reset and pause tests on this RTL

Lane E2's 17 reset and pause tests were rerun, one simulation at a time, against the tree at `1fb9d95`: `FLAVOR=g7 JOBS=1 sim/bupchip/daria/fe_dir/run_dir.sh <the 17 tests>`. The results are in `sim/work/bupchip/daria/fe_dir/g7/results.txt`. All 17 pass: every bad count 0, every required bin met.

| Test | Scheme | What it does (counts from `dir_cov.txt` and the run log) | Classes |
|---|---|---|---|
| `hard_reset_call_dpc` | DPC+ | a reset 15 clk_sys after the 3rd call accept, inside the call (`inj_rst_in_call` 1, `reset_in_call` 1); 2 inits | `drift_up` |
| `hard_reset_call_cdf` | CDFJ | a reset 40 clk_sys after the 4th call accept, inside the call; 2 inits | `drift_up` |
| `hard_reset_svc_dpc` | DPC+ | a reset 4 clk_sys into the 4th DMA service (`reset_in_svc` 1); 14 services; 2 inits | `drift_up` |
| `hard_reset_dsw_cdfj` / `_cdfjp` | CDFJ / CDFJ+ | 5 resets each, 4 of them rising in the phase 1 of a DSWRITE/DSPTR cycle (`reset_in_dsw_ph1` 4); 6 inits | `p32_reset` 2 each, `drift_up` |
| `hard_reset_init_cdfjp` | CDFJ+ | a pulse during the load-time init and F6: no extra edge (the sticky hold), 1 init | `drift_up` |
| `hard_reset_rel_dpc` / `_rel_cdf1` | DPC+ / CDF1 | a reset 3 clk_sys after the first release: a second init and F6 right after the first; 2 inits | `drift_up` |
| `hard_reset_frame_dpc` / `_frame_cdfj` | DPC+ / CDFJ | `+hard_reset_at=3`; 2 inits | `drift_up` |
| `pause_dpc_ph1` | DPC+ | 69 pauses starting in phase 1, 9,453 paused clk_sys | `drift_up` |
| `pause_dpc_ph2` | DPC+ | 85 pauses starting in phase 2, 7,905 paused clk_sys | `svc_audio_race` 2, `resync` 2 |
| `pause_dpc_call` | DPC+ | 6 pauses inside calls, 1,800 paused clk_sys | `drift_up` |
| `pause_dpc_svc` | DPC+ | 13 pauses inside services, 3,250 paused clk_sys | `svc_audio_race` 1, `resync` 1 |
| `pause_cdf_ph` | CDFJ | 84 pauses in phase 1 (1 of them in a call), waveform and digital frames, 15,204 paused clk_sys | `merge_amp` 1, `resync` 1 |
| `pause_cdf_call` | CDFJ | 7 pauses inside calls, 2,800 paused clk_sys | `drift_up` |
| `pause_lane_dpc` | DPC+ | 31 pauses from a `pclk1` with `sel_ram_sel` high to just after a paused sample grant, 16,614 paused clk_sys; 31 sample captures right after a paused grant, all 31 with the select high at the last unpaused edge | `pause_lane` 23, `amp_class` 9, `svc_audio_race` 1, `resync` 1 |

In all: 17 console reset edges in 10 tests (and one pulse absorbed by the hold), and 295 pauses with 57,026 paused clk_sys in 7 tests. The counts equal those of E2_directed.md 3.2 and of F1_fixes.md's verification table where those give them.

## 5. Pause and the BIOS path: where their coverage comes from

`tb_daria` ties `pause` to 0, so no game run pauses. The BIOS path is run now, through the 7800 OpenBIOS (section 8); 5.2 says what covers it besides those runs.

### 5.1 Pause

**On the Pocket the core never pauses.** `core_top.v:883` ties `pause_core` to 0, and `daria_fe`'s `pause` input is always low (DARIA_CORE.md decision 10; F1_fixes.md 2). So pause matters only for a MiSTer port and for the comparison with upstream, which does pause. Its coverage:

- **Lane E2's pause tests** (section 4, rerun on `1fb9d95`): 7 tests, 295 pauses, 57,026 paused clk_sys.
  - 160 pauses start in phase 1 (DPC+ and CDFJ) and 104 in phase 2 (DPC+).
  - 14 fall inside calls (DPC+ and CDFJ) and 13 inside DPC+ services.
  - `pause_lane_dpc` places 31 pauses at the exact edge pair that design 9.5's `pause_lane` needs, and reaches the class 23 times.
  - All pass with 0 bad. The six older tests show `pause_lane` 0.
  - Each pause is a force on `dut.pause`, a bench stand-in for the core's `pause_core` (E2_directed.md 5).
- **Lane E3's random bench** (E3_random.md 5.1-5.2, the campaign on the F1 RTL): pauses inside either phase, at any point, in the `mix`, `all`, `poison`, `dpc`, `pause` and `fastddr` groups. Over the 42 runs and 105,000,215 6507 cycles:
  - 88,188,291 paused clk_sys;
  - 564,098 of the 10,400,859 audio grants paused;
  - 12,819 sample captures right after a paused grant, 129 of them with the select high at the last unpaused edge;
  - `pause_lane` 95 times in its exact form, and no lane difference failed the check;
  - 0 failures.
- **The unit benches** pause too: `tb_fe_audio` (lane B; B_audio.md, F1_fixes.md 2) and the benches driven by `fe_phase_gen` (`+pg_pause1`, `+pg_pause2`: a pause inside phase 1 or phase 2).

### 5.2 The BIOS path (`use_bios`, class `pre_lock`)

**What the path is.** On the Pocket, `use_bios = bios_loaded & ~skip_bios` (`atari7800_pocket.sv:875`) gives the core `bypass_bios = 0` and `tia_mode = 0` (`:933-934`). The 7800 BIOS then runs in 7800 mode with `access` 0, on MARIA's phases: phase 1 of 4 or 6 clk_sys, cycles of 8, 10 or 12 (section 8.7). It runs until it locks 2600 mode and `tia_en` rises (critic finding 22).

Before the lock, upstream's audio engine still ticks and refreshes. Its grants read whatever the 7800 path puts on cart RAM port A, because `top.sv:756-757` gives the port the 2600 path's address only with `mapper_init_busy || tia_en` (spec/audio.md 12.6; spec/bus.md B19). `daria_fe` reads its own RAM at the engine's address. So AMPLITUDE may differ until the first refresh after `tia_en`. That is design 9.5's `pre_lock`, a mode-A class. On the Pocket there is no upstream engine to differ from.

**Where it is covered:**

- **The BIOS runs (section 8)** are the direct coverage. There are five runs with the 7800 OpenBIOS, one image per scheme, and a sixth with a console reset (8.5).
  - **Three hand over to 2600 mode** (DPC+ r0, CDF1, CDFJ). In each:
    - the BIOS's 7800-mode cartridge reads (390-392 slot cycles with A12, the hotspot $1FF8 among them) leave `daria_fe`'s state equal to upstream's at all 39,080-39,090 `pclk1` of the boot;
    - `pre_lock` occurs, 1,335 or 4,005 times, with its condition confirmed at every grant, and its effect ends with the first refresh after `tia_en` (8.6);
    - the game then runs 300 frames with every must-be-0 count 0.
  - **For DPC+ revision 1 and CDFJ+ the BIOS does not hand over on this core** (8.8). Those two runs cover 77 million clk_sys of 7800 mode (9,616,380 `pclk1` compared, 0 differ; `pre_lock` 322,395 and 967,185), but no lock into 2600 mode.
- **Lane E2's directed tests** do not run the BIOS. Its ten reset tests (section 4) cover what a console reset does to `daria_fe` up to the release, which is the same with the BIOS. On the Pocket, with a BIOS, every console reset is followed by a new boot; one run covers that (8.5, `bios_reset_cdf1_draconian`).
- **Lane E3's 7800-mode intervals** (E3_random.md 2.3; `tb_fe_rand.sv:2555-2563`).
  - **The counts.** There are 1,050 intervals in the campaign (`ev_7800`), each of 20 to 3,019 clk_sys, started only with nothing in flight. In each, `tia_en` and `arm_driver_run` are low and the console is out of reset. Each ends with `tia_en` rising again without a reset, which is the transition a BIOS lock makes.
  - **What they exercise.** `daria_fe` and upstream run side by side with the 2600 driver off (no commit, the stall gate off). The audio engines keep ticking and refreshing, with A1/T1/T2 comparing every clock, and then return to 2600 mode. In the `all`, `dpc`, `fastddr` and `rst_all` groups the phase generator also gives phase 2 of 4 clk_sys while the driver is off, MARIA's 7800-mode timing (`fe_phase_gen`, `+pg_ph2_4`; 200 per mille in `all`).
  - **What they do not exercise: `pre_lock`.** E3's model of port A follows the 2600 side's address whatever `tia_en` is; only the 6507's write is gated (`fe_rand_up.sv:355-358`: "without tia_en the port is the 7800 path's (not modelled: no write)"). So both engines read the same word, and the class's condition never arises. E3 lists `pre_lock` as not reachable (E3_random.md 3.1, 5.2), and its count is 0. This corrects the brief, which had E3's intervals exercise `pre_lock`; only the BIOS runs of section 8 do.
- **Console resets** take `tia_en` down and back up with the engine running: `tia_en = tia_req && !eff_reset` (`tb_fe_rand.sv:198`). E3 makes 5,250 of them (1,050 at a random moment, 4,200 downloads), all followed by I1/I2 (5,250 inits). The ten E2 reset tests and the seven runs of section 3 make 24 more. With `bypass_bios`, `tia_en` rises in the first clock after the release, so none of them gives a `pre_lock` window. `pre_lock` is 0 in every run of section 3 and every test of section 4.
- **MARIA's phases before the first handoff.** Every `tb_daria` run starts its checks on MARIA's phases. Without the BIOS it hands over to the TIA's phases 901 clk_sys later ("FE handoff: TIA phases from …"). It does so again after every reset, twice in each run of section 3, with `tia_en` already high. With the BIOS the hand-over to the TIA's phases comes 8,946 to 23,094 clk_sys after `tia_en`, at the game's first RSYNC write (8.7).

**Not covered:**
- **the hand-over to 2600 mode for DPC+ revision 1 and CDFJ+.** With the OpenBIOS this core never reaches it for any such image here (8.8). For those two schemes:
  - the runs cover the 7800-mode interval, with C1/C2 and the every-clock checks throughout;
  - the reset runs of section 3 cover the start of 2600 mode after a release;
  - what is not run is the lock after a BIOS boot, with the state that boot leaves;
- **other BIOSes.** The Atari BIOS was not used, by instruction. Its cartridge check makes other 7800-mode reads;
- **a BIOS boot after a console reset on schemes other than CDF1.** There is one such run (8.5).

## 6. Observations

1. **The mode-A batch runs a pre-F1 binary.** `sim/work/bupchip/daria/obj_fe_modeA/vtb`, the binary of the 30-image batch now running, has the timestamp of the old `obj_fe/vtb`: 2026-10-08 08:10.
   - That is before F1's commits `c967eb6`/`45b1376` and `65a11f0` (authored 08:58 and 10:18).
   - Its strings contain neither `obus_ffe` nor `commit_pclk1`. This lane's `1fb9d95` build contains both.
   - So that batch checks the RTL and the bench as they were before F1.
   - This lane did not touch it. Whether its results stand for the final RTL is the lead's call.
2. **`tb_daria`'s `+reset_at` is the 2600's RESET switch** (held for 6 frames, `tb_daria.sv:43, 794`), not a console reset. It was not used.
3. **Run time.** The `FE=1` runs took 3.0 to 4.4 s a frame on this machine while the batch and another lane's mode-B runs shared it (load average 6 on 4 cores at times).
4. **The OpenBIOS and DPC+ revision 1 or CDFJ+ images (8.8).** On this core, and so on the Pocket, these images do not boot through the OpenBIOS. The cause is the 7800 path's view of a 2600 image in `cart.sv` and the missing bus conflict at $1BEA, both in upstream's files. It is for the lead.
5. **No other lane edits `tb_daria.sv`.** The mode-B lane's worktree changes `fe_shadow.svh`, `fe_taps.svh`, `daria_shadow.svh`, `run_daria.sh` and `run_all.sh`, but not `tb_daria.sv`. This lane's block calls `fe_taps.svh`'s `ft_c1`, `ft_c2`, `ft_uw`, `ft_cw`, `ft_a1_rep`, `ft_a1_cf` and `ft_up_dispatch`. A merge that renames them would need the same rename there.

## 7. Outputs

All under `sim/work/bupchip/daria/` (game data, not in git):

- `fe_reset/frame/runs/<name>/`, `fe_reset/call/runs/<name>/`: `run.log`, `fe.csv`, `fe_ref.csv`, `fe_err.txt` ("No failures"), `frames.csv`, `calls.csv.gz`, `summary.txt`, `report.txt`; the call runs also have `dir_cov.txt`.
- `fe_reset/plain/runs/explore_ElevatorAgent/`: the timing run.
- `fe_dir/g7/`: the directed rerun (`results.txt`, `runs/fe/<test>/`). Its images are synthetic.
- `fe_reset/sources.md5`, `fe_reset/{frame,call}/vtb.md5`, `fe_reset/queue.txt`, `fe_reset/runner.log`, `fe_reset/dir_g7.log`.
- `fe_reset/bios4/runs/<name>/`: the final BIOS runs (`bios_*`), the `+fe_resync=0` diagnostics (`diag_resync0_*`) and the `FE=1` regression runs (`reg_new_fe_*`); `fe_reset/bios3/runs/<name>/`: the same runs on `bios3`; `fe_reset/bios3_plain/runs/reg_new_plain_SF2fix/`; the old sides in `fe_reset/frame/runs/reg_old_fe_*` and `fe_reset/plain/runs/reg_old_plain_SF2fix/`. They derive from the BIOS image or the games, so they stay here.
- `fe_reset/bios/` and `fe_reset/bios2/`, with their `_plain` builds: the two earlier builds of the change (8.3) and their runs, superseded. Among them is the first Elevator Agent BIOS run on `bios2`, stopped by PID after 31 minutes without a frame, and the time-limited diagnostic that followed (`bios2/runs/diag_bios_ElevatorAgent`, 900 s; 8.8).
- `fe_reset/{bios3,bios4}_sources.md5`, `fe_reset/{bios3,bios3_plain,bios4,plain}/vtb.md5`, `fe_reset/queue_bios.txt`, `fe_reset/runner_bios.log`, `fe_reset/queue_bios4.txt`, `fe_reset/runner_bios4.log`.
- The scripts used to compare and summarise are in the session's scratchpad, not in the repository: `scratchpad/g7b/cmp_runs.py` (8.3), `prof.py` (the frame profiles), `biostab.py` (the BIOS lines), `biosdetect.py` (8.8), and the reset runs' `scratchpad/g7_ana.py` and `g7_after.py`.

## 8. `use_bios`: game runs through the 7800 OpenBIOS

**Decided** (owner, 2026-10-09; `docs/DARIA_CORE.md`, decision 11): the core never runs the BIOS for a 2600 image. With a BIOS loaded and "skip BIOS" off, a 2600 image now starts directly, as with "skip BIOS" on: `use_bios = bios_loaded & ~skip_bios & ~tia_mode` (`atari7800_pocket.sv:886`). The BIOS runs only for a 7800 image or an empty slot. So the finding of 8.8 no longer occurs on the Pocket. This section describes the core before that change: 8.2's `atari7800_pocket.sv` lines are the old ones, and `tb_daria.sv`'s `+bios`, which wires `use_bios` itself, still boots 2600 images through the BIOS. `sim/run_sim.sh` checks the new rule (`BIOS_BOOT`).

### 8.1 The BIOS image

The image is the 7800 OpenBIOS, built with dasm from `github.com/7800-devtools/7800openbios` at `b8bc745`: `sim/work/bupchip/bios/7800openbios.bin`, 16,384 bytes, md5 `659607f1…`. Its source is CC0, but the image embeds the game KiloParsec, which is all rights reserved. So the image and everything a run derives from it stay in `sim/work`, and nothing of it is in git. The Atari BIOS dump in the same directory (`7800_ntsc.rom`) was not used.

What the BIOS does with a 2600 cartridge, from its source (`7800openbios.asm`) and the listing of that build:

1. **Boot.** From RESET at $F800 it sets INPTCTRL to $02 (MARIA on, the BIOS on). It clears RAM $2000-$27FF, copies the 2600 loader to RIOT RAM at $0480 and the cartridge check to RAM at $2300, and clears the TIA and MARIA registers $01-$2B. Until INPTCTRL is locked it hears every TIA write, so that loop also writes INPTCTRL with 0. Then it sets $02 again.
2. **The cartridge check** runs from RAM at $2300 with INPTCTRL $06 (the BIOS off, the cartridge on). It reads $1BEA, writes it and reads it back, compares $FE00-$FE7F with $FD80,Y (the same bytes), reads the reset vector at $FFFC/$FFFD and the region byte at $FFF8, and calls the cartridge a 2600 one at the $FFF8 tests. Then it sets INPTCTRL to $02 and returns to the ROM.
3. **The hand-over.** For a 2600 cartridge it skips the Fuji screen and jumps to $0480. The loader turns MARIA off, clears the TIA, and runs the probes of Atari's own loader, whose TIA writes again reach INPTCTRL. It ends with `lda #$FD; sta $08`: INPTCTRL $FD locks it with MARIA off, the BIOS off and the TIA on. Then `jmp ($FFFC)` takes the cartridge's reset vector.

### 8.2 The bench change: `+bios=FILE` in `tb_daria.sv`

On the Pocket, `use_bios = bios_loaded & ~skip_bios` (`atari7800_pocket.sv:875`). With it the core gets `bypass_bios = 0` and `tia_mode = 0`, and `cart_present` stays 1 with a cartridge loaded (`:933-935`). The BIOS ROM is an `spram` (`:366-377`): its address is `bios_addr[13:0] & bios_mask[13:0]` and its read is registered (`bram.v`, `cache_ram.v`), so `bios_data` comes one clk_sys after the address. `bios_mask` is the last download address (`:219-221`), the file's size less one.

`tb_daria.sv` does the same with `+bios=FILE`:

- **Line 93** declares `use_bios` (0), `bo_stop` (0), `bios_q` (the ROM's registered byte, 0 at power-up like the M10K) and `bios_ab`.
- **Lines 196-199** connect `.bypass_bios(!use_bios)`, `.tia_mode(tia_mode && !use_bios)`, `.bios_out(bios_q)` and `.AB(bios_ab)`. Before, these were `1'b1`, `tia_mode`, `8'd0` and an open `AB`.
- **Line 953**, the frame loop, also stops on `bo_stop`: `while (frame < frames && !bo_stop)`. The run then ends as usual, with `summary.txt` and the final lines written.
- **Line 39**, the header, points to the new block.
- **Lines 1015-1228**, after the `FE` include, hold the new block:
  - the ROM: 16,384 bytes, zero-filled, with `bios_q <= bios_rom[bios_ab[13:0] & bios_mask]` at every clk_sys;
  - the plusarg: the file must hold 1 to 16,384 bytes, else the run stops; `bios_mask` is its size less one;
  - the end of a run that cannot reach 2600 mode. `bo_stop` is set when the BIOS locks INPTCTRL with `tia_en` 0, which keeps 7800 mode until a reset, or when `tia_en` has not risen `+bios_wait=N` clk_sys after the release (default 100,000,000; 0 for no limit). Without it, such a run never ends: the frame counter counts the TIA's VSYNCs (8.8);
  - the "BIOS" lines of section 8.4. They are printed only with `+bios`, and their `daria_fe` part only in a stage-1 `FE=1` build. Their counts cover the first boot, from the release to the first `tia_en`. In `bios3` the `BIOS pre_lock:` line's two port-A counts (`bf_gr_addr`, `bf_gr_word`) also counted a later boot while its grant count (`bf_gr_up`) did not, so after a console reset the line contradicted itself ("4005 upstream grants before tia_en, 8010 with port A at another word"). The review asked for one scope: `bios4` counts both over the first boot too (`bo_boot` in their condition, `tb_daria.sv:1164`), and the line says "before the first `tia_en`". The second boot's `pre_lock` count is in `fe.csv`, and its port-A condition in `bios3`'s run (8.6).

The existing lines were changed in place, in `bios4` too (five lines changed in three places, three of them a comment: `tb_daria.sv:1154-1156`, `:1164` and `:1224`; none added). No line was added before the `$finish` (line 965), so `run.log`'s "`tb_daria.sv:965: Verilog $finish`" line is unchanged.

**Without `+bios`, the DUT sees exactly what it saw before.** `use_bios` stays 0, so `bypass_bios` is 1 and `tia_mode` is the bench's own, as before. The ROM is all zero, so `bios_q` stays 0, the value `bios_out` was tied to. `AB` is an output. `bo_stop` is set only by the new block, and only with `+bios`. No other file was changed: `fe_shadow.svh` already rebuilt `read_DB` with `bios_sel ? bios_out` (`fe_shadow.svh:1372-1373`).

### 8.3 Unchanged without `+bios`: the regression

Each pair below is the same command on the old binary (`1fb9d95`'s `tb_daria.sv`) and on the new one (this `tb_daria.sv`, all other sources the same: `fe_reset/bios3_sources.md5` against `fe_reset/sources.md5`). Each run is `DTRACE=0`. The pairs were compared file by file with `scratchpad/g7b/cmp_runs.py`:

- `.gz` files are compared decompressed;
- `run.log` leaves out only the Verilator report's three lines and the `wall` line, which hold wall-clock times;
- `report.txt`'s title, which names the run directory, has the name replaced.

| Run | Old binary | New binary | Files compared | Result |
|---|---|---|---|---|
| plain, SF2fix, `+frames=40 +snap=0 +fire_at=10 +play_at=20` | `fe_reset/plain/obj/vtb` (`994820c6…`) | `fe_reset/bios3_plain/obj/vtb` (`7ae550cb…`) | 8: `calls.csv.gz`, `frames.csv`, `pcs.txt.gz`, `report.txt`, `run.log`, `slack.csv`, `summary.txt`, `zero.csv` | identical |
| `FE=1`, SF2fix, the same and `+hard_reset_at=25` | `fe_reset/frame/obj_fe/vtb` (`56a59e02…`) | `fe_reset/bios3/obj_fe/vtb` (`015ec0c0…`) | 11: the same and `fe.csv`, `fe_ref.csv`, `fe_err.txt` | identical; PASS, with a console reset |
| `FE=1`, draconian RC8 (CDF1), `+frames=30 +snap=0` | as above | as above | 11 | identical; PASS |

The same two `FE=1` runs on the final binary `bios4` are identical, file by file, to their `bios3` runs above, and so to the old binary's. `bios4`'s change is inside `` `ifdef FE_SHADOW `` / `` `ifndef FE_STAGE0 `` and only with `+bios`: `verilator -E -P` of `tb_daria.sv` with `bios3`'s and with `bios4`'s file gives identical output for a plain, a `SHADOW=1` and an `FE=1 FE_STAGE0=1` build, and 2 changed lines for `FE=1` (the condition and the line's text). So `bios3_plain` stands for the final plain build.

The build logs' warnings are the same as before as well. Two earlier builds of this change gave the same identical results: `fe_reset/bios/` (the `FE=1` SF2fix pair) and `fe_reset/bios2/` (all three pairs). They differ from the final one only in the "BIOS" lines and, for `bios2`, in the end of a run that cannot reach 2600 mode. The final one was built after the runs of 8.8 showed that such a run never ends.

### 8.4 What the bench prints with `+bios`

- `BIOS: INPTCTRL …` at each change of {`lock_ctrl`, `maria_en`, `bios_en_b`, `tia_en`} after the release, with the 6507's PC. Also the clock of the loader's first opcode at $0480, of `tia_en` (with the count of BIOS ROM reads and INPTCTRL writes) and of the game's first cartridge opcode, or the line that ends a run without a hand-over.
- `BIOS slot:` what the 2600 slot saw while `tia_en` was low. That is `cart2600`'s `a_in` with A12 set (INPTCTRL's BIOS bit gates A12, `top.sv:1126-1128`) at each `mapper_phi2`, cart2600's phi2. It gives reads, writes, the addresses as runs, and upstream's `arm_access` (its commits).
- `BIOS FE:` (stage 1). Over the same interval:
  - C1 or C2 at every `pclk1` (`fe_taps.svh`'s `ft_c1`/`ft_c2`, the functions of the live check);
  - `daria_fe`'s commits (`u_seq.commit`);
  - the audio grants on each side and the refreshes;
  - the clocks with AMPLITUDE or the replica (A1's `rep` group, `ft_a1_rep`) differing.
- `BIOS pre_lock:` design 9.5's condition, at each upstream grant with `tia_en` low, out of reset and out of init:
  - whether cart RAM port A had another word than the engine's (`dut.cartram_addr` against `cart2600.cartram_addr`);
  - whether the word the engine captured at the next clock differs from the word at its own address (`ft_uw`);
  - the first three grants in detail;
  - AMPLITUDE and the replica from `tia_en` to the end of the first refresh dispatched after it, and from there to the game's first call accept, with counters and frequencies too.

### 8.5 Runs and results

Six runs: one image per scheme, with the same images and inputs as the reset runs (2.3), and draconian again with a console reset. Each is `WORK=…/fe_reset/bios4 FE=1 NOBUILD=1 DTRACE=0 NAME=<name> sim/bupchip/daria/run_daria.sh <image> <plusargs> +bios=/home/user/openFPGA-7800/sim/work/bupchip/bios/7800openbios.bin`, one at a time after the binary's and the sources' md5 checks (`fe_reset/queue_bios4.txt`, `fe_reset/runner_bios4.log`). Each was run first on `bios3` (`queue_bios.txt`, `runner_bios.log`), and each `bios4` run is identical to its `bios3` run file by file, but for the `BIOS pre_lock:` line of `run.log`: its wording, and in the reset run its port-A counts, now over the first boot (8.2):

**The boot.** Clocks are clk_sys from time 0; the release is the end of the load's reset ("reset released at"). "Slot cycles" are the `mapper_phi2` cycles with `a_in[12]` set before `tia_en`, as the 2600 slot saw them.

| Run (image) | Scheme | The BIOS's decision (8.8) | Release → `tia_en` | `pclk1` before `tia_en`: C1/C2 compared, differ | Slot cycles (reads, writes) and their addresses | Commits before `tia_en`: upstream / `daria_fe` | The game's first opcode; first call | TIA's phases from |
|---|---|---|---|---|---|---|---|---|
| `bios_dpcp0_SF2fix` | DPC+ r0 | 2600, at the second $FFF8 test ($FFF8 = $07) | 83,187 → 402,412 (319,225), with the lock | 39,090, 0 | 392, 1: $1BEA ×3, $1D00-$1D7F, $1E00-$1E7F ×2, $1FF8 ×2, $1FFC-$1FFD ×2 | 0 / 0 | $F189, 66 clk_sys after `tia_en`; 435,724 | 425,422 (+23,010) |
| `bios_cdf1_draconian` | CDF1 | 2600, at the first $FFF8 test ($FFF8 = $00) | 81,403 → 400,544 (319,141), with the lock | 39,080, 0 | 391, 1: the same, $1FF8 ×1 | 0 / 0 | $7064, +66; 433,820 | 423,638 (+23,094) |
| `bios_cdfj_Mappy` | CDFJ | 2600, at the first $FFF8 test ($FFF8 = $00) | 81,407 → 400,544 (319,137), with the lock | 39,080, 0 | 391, 1: the same, $1FF8 ×1 | 0 / 0 | $F382, +66; 442,148 | 409,490 (+8,946) |
| `bios_dpcp1_DinoEggs` | DPC+ r1 | no cartridge: reset vector $0000 | 83,187 → none. INPTCTRL locked in 7800 mode ($13) at 77,019,072, 6507 at $FF82 (the BIOS's game) | 9,616,380, 0 | 390, 1: $1BEA ×3, $1D00-$1D7F, $1E00-$1E7F ×2, $1FFC-$1FFD ×2 | 0 / 0 | — | — |
| `bios_cdfjp_ElevatorAgent` | CDFJ+ | no cartridge: reset vector $FFFF | 165,375 → none. Locked in 7800 mode at 77,101,260, 6507 at $FF82 | 9,616,380, 0 | 388, 1: the same, $1FFC-$1FFD ×1 | 0 / 0 | — | — |
| `bios_reset_cdf1_draconian` | CDF1 | 2600, as in `bios_cdf1_draconian`, in both boots | 81,403 → 400,544 (319,141), as there. After the console reset: upstream's init done at 55,159,277, the checks live again at 55,478,425 (+319,148) | 39,080, 0 in the first boot (the bench's lines follow the first boot only) | 391, 1 in the first boot | 0 / 0 | $7064, +66; 433,820 | 423,638 (+23,094); after the reset 55,501,514 (+23,089 from the checks) |

Every boot that hands over made 24,598 BIOS ROM reads and 103 INPTCTRL writes up to `tia_en`. The two runs without a hand-over made 8,492,329 (Dino Eggs) and 8,492,337 (Elevator Agent) BIOS ROM reads and 51 INPTCTRL writes up to the lock in 7800 mode. In every run INPTCTRL changed as the source says (8.1), and the hand-over write set `lock_ctrl` and `tia_en` at one clock.

**The results.**

| Run | Plusargs (and `+snap=0 +bios=…`) | Frames, calls | Gameplay | Latches compared (L1 and C1/C2 from `tia_en`) | FE result | `pre_lock` | Other classes | Wall |
|---|---|---|---|---|---|---|---|---|
| `bios_dpcp0_SF2fix` | `+frames=300 +fire_at=40 +play_at=70` | 300, 525 | from frame 78, as without the BIOS. Frames 1-75 are identical, every `frames.csv` column but the time, to the reset run's (2.3), which has the same inputs; the game's random play then differs | 5,958,524 | PASS (0 bad) | 1,335 | `resync` 445 | 987 s |
| `bios_cdf1_draconian` | `+frames=300 +fire_at=140 +play_at=150` | 300, 600 | from frame 147, as without the BIOS; frames 1-145 identical to the reset run's | 5,956,778 | PASS (0 bad) | 4,005 | `merge_amp` 5, `resync` 450 | 934 s |
| `bios_cdfj_Mappy` | `+frames=300 +fire_at=185 +play_at=200` | 300, 599 | from frame 237, as without the BIOS; all 299 rows identical to the reset run's | 5,957,552 | PASS (0 bad) | 4,005 | `merge_amp` 5, `resync` 450 | 927 s |
| `bios_dpcp1_DinoEggs` | `+frames=500 +fire_at=420 +play_at=480` | 0, 0 (the run ends at the lock in 7800 mode) | none: the game never starts | 0: the 6507-level checks never start; the every-clock checks and assertions ran throughout | PASS (0 bad) | 322,395 | `resync` 107,465 | 1,191 s |
| `bios_cdfjp_ElevatorAgent` | `+frames=300 +fire_at=0 +play_at=40` | 0, 0 (the same) | none | 0, as above | PASS (0 bad) | 967,185 | `resync` 107,465 | 1,113 s |
| `bios_reset_cdf1_draconian` | `+frames=330 +fire_at=140 +play_at=150 +hard_reset_at=230` | 330, 659 | from frame 147; the console reset at frame 230 returns it to its boot screen (below) | 6,537,316 | PASS (0 bad) | 8,010: 4,005 in each boot | `merge_amp` 7, `resync` 897 | 1,051 s |

**The console reset with the BIOS** (`bios_reset_cdf1_draconian`):
- **The reset.** It was driven at clk_sys 55,155,800, the VSYNC rise of frame 230, 83 frames into gameplay. The previous call (#460) had ended 26,193 clk_sys earlier.
- **The re-init.** `daria_fe` ran F6 again from 55,155,811 for 2,082 clk_sys; upstream's init was done at 55,159,277.
- **The second boot.** The BIOS then booted again, as on the Pocket with a BIOS: the same 4,005 grants (`fe.csv`'s `pre_lock` in the reset frame's row), all at the 7800 path's word (`bios3`'s run, which counted the port-A condition over both boots: 8,010 of 8,010; `bios4` prints the first boot's). The checks resumed at 55,478,425, 319,148 clk_sys after upstream's init, on MARIA's phases, and the TIA's phases came 23,089 clk_sys later, as in the first boot. "FE resets: 1 console resets after the checks started, 2 starts of the checks, 2 handoffs to the TIA's phases".
- **The same state as after the load.** The 99 frames after the reset are identical, row for row, to the 99 frames after the load, in `frames.csv` (every column but the frame number and its time) and in `fe.csv` (every compared count and must-be-0 counter). Against the 99 frames after the reset of the run without the BIOS (`cdf1_draconian`, section 3), `frames.csv` is identical as well (99 of 99 rows). `fe.csv` is not: 63 of 99 rows are identical, and the other 36 differ only in per-frame counts that follow the audio tick's phase, `ticks` (34 rows), `crb_use` (32), `dig_ram_window` (30), and `merge_amp`, `resync` and `masked_clocks` (6 each); the first is frame 233, 333 ticks against 334. Every must-be-0 counter is 0 in both. The cause is the BIOS's boot, not `daria_fe`: the tick's accumulator restarts at the console reset, and the BIOS's 319,000 clk_sys before the hand-over put the game's frames at another phase against it than in the run without the BIOS, while the boot after the load and the boot after the reset put them at the same one. The frame that holds the reset is 319,176 clk_sys longer there (359,700 against 40,524), which is the BIOS's boot.
- **Before the reset**, frames 1-145 equal those of the run without the BIOS, as in `bios_cdf1_draconian`.
- **The counts.** Every must-be-0 counter of `fe.csv` sums to 0 before the reset, in the frame that holds it and after it.

In every run every must-be-0 counter of the `FE bad:` line is 0 ("total 0"), `fe_err.txt` reads "No failures", and the only classes are design 9.5's `pre_lock` and `merge_amp` (CDF without the hook), each resynced, besides the O1 information counter `drift_up` (259,876-471,773 in the four runs that reach 2600 mode). `short_phase1`, `grant_steal` and `a_collide` are 0 although the boot runs on MARIA's phase 1 of 4 clk_sys (37,467-37,477 cycles before the hand-over, 9,615,179 in the runs without one). Those cycles have no commit (`access` 0), so they are not the class's condition.

In the two runs without a hand-over, `run_daria.sh` exits with status 1 after the run, because `summarize.py` has no frame to report (`report.txt` is empty). `run.log`, `fe.csv` and the other outputs are complete.

### 8.6 `pre_lock`: its count and its condition

**Counts.** `pre_lock` (the bench counts each clock with an upstream or a `daria_fe` audio grant while `tia_en` is 0, out of reset, `fe_shadow.svh:1664-1667`) is 1,335 in the SF2fix run and 4,005 in the draconian and Mappy runs, over the 445 refreshes of the 319,000-clk_sys boot: three grants a refresh on DPC+, nine on the CDF family. In the runs without a hand-over it is 322,395 (Dino Eggs, DPC+) and 967,185 (Elevator Agent, CDFJ+) over 107,465 refreshes, again three and nine a refresh. In every run the upstream grants, `daria_fe`'s grants and the bench's count are equal: the two engines grant on the same clocks before the lock.

**The condition.** Design 9.5: "Refreshes with a grant before `tia_en` (BIOS path; upstream reads the 7800 path's RAM address, AUD 12.6)". At every one of those grants, in all six runs, cart RAM port A had another word than the engine's. `top.sv:756-757` gives the port `cartram_addr78`, which `cart.sv:485` derives from the bus address: the first three grants of each run show the words $0E08-$0E09 (bytes $3820-$3827), and the engine captured 00000000 there.

| Run | Upstream grants before `tia_en` | Port A at another word than the engine's | The captured word differs from the word at the engine's address |
|---|---|---|---|
| `bios_dpcp0_SF2fix` | 1,335 | 1,335 | 1,335 (the engine's word $0300 holds 6323371E) |
| `bios_cdf1_draconian` | 4,005 | 4,005 | 2,934 |
| `bios_cdfj_Mappy` | 4,005 | 4,005 | 1,874 |
| `bios_dpcp1_DinoEggs` | 322,395 | 322,395 | 0 (the engine's words were 0 as well) |
| `bios_cdfjp_ElevatorAgent` | 967,185 | 967,185 | 661,325 |
| `bios_reset_cdf1_draconian` | 8,010: 4,005 in each boot (`run.log` gives the first boot's; the reset frame's `fe.csv` row holds the second 4,005) | 8,010 (first boot 4,005 in `bios4`'s `run.log`; both boots in `bios3`'s) | 5,868: 2,934 in each boot (likewise) |

**What may differ, and until when.** Design 9.5: "AMPLITUDE until the first refresh after `tia_en`". The bench masks the replica at each such grant and resyncs at the next quiet point (`resync` 445 or 450 in the runs above, one a refresh), so a normal run shows no difference. Two diagnostic runs show what the engines do without the resyncs. They use `+fe_resync=0`, 10 frames, the bench's own counts of the "BIOS" lines, and the final binary (`bios4/runs/diag_resync0_*`; the same on `bios3`):

| Run | During the boot: AMPLITUDE / the replica differ on | From `tia_en` to the end of the first refresh after it | From there to the game's first call |
|---|---|---|---|
| SF2fix | 318,491 / 318,495 clk_sys | 89 clk_sys (402,412 to 402,501): AMPLITUDE and the replica differ on all 89 | 33,223 clk_sys: the replica differs on 0, counters and frequencies on 0 |
| draconian | 117,227 / 316,625 clk_sys | 181 clk_sys (400,544 to 400,725): differ on all 181 | 33,095 clk_sys: 0 and 0 |

So AMPLITUDE differs until the end of the first refresh after `tia_en` and never after it, as the class says. On draconian the engine's other per-refresh registers differ before the lock as well (the replica group of A1: the state, the waveform pointer's route and the digital registers), since they too come from the word the engine captured. They are internal, the 6507 reads only AMPLITUDE, and they agree again from the same refresh on. Design 9.5's "What may differ" could say so; the bench's mask already covers the whole replica. No 6507 read of AMPLITUDE fell in that window in any run (`amp_class` 0). The game's first opcode comes 66 clk_sys after `tia_en`, and the first refresh after it ends 89-181 clk_sys after `tia_en`.

On the Pocket there is no upstream engine, so nothing can differ: `daria_fe` reads its own RAM at its own address before the lock, as after it.

### 8.7 `daria_fe` through the BIOS's 7800-mode cartridge reads

**What reaches `daria_fe` in 7800 mode.** `daria_fe` takes `cart2600`'s inputs (E1_shadow.md 2):
- `a_in = {AB[12] & bios_en_b, AB[11:0]}` (`top.sv:1126-1128`): A12 only with the BIOS off in INPTCTRL;
- `rw`;
- phi2 = `mapper_phi2`;
- `access = mapper_phi2 && lock_ctrl && tia_en` (`cart2600.sv:247`, `top.sv:1136`).

Before the lock, `access` is 0, so neither side may commit. The bus data of those cycles comes from the 7800 path (`cart.sv`), not from either front end (`top.sv:332-334`).

**The reads.** In each boot the slot saw about 390 cycles with A12, all from the cartridge check that runs from RAM at $2300 with INPTCTRL $06 (8.1):
- $1BEA: read, write, read back;
- $1D00-$1D7F: the dummy reads of `cmp $FD80,Y` crossing a page;
- $1E00-$1E7F, twice;
- the reset vector at $1FFC-$1FFD;
- in the three runs that go on to 2600 mode, the region byte at $1FF8, once or twice.

$1FF8 is a bank-switch hotspot of both schemes (`mapper_dpcplus.sv:231`: $FF6-$FFB; `mapper_cdf.sv:185`: $FF4-$FFB). $1FFC-$1FFD are not.

**`daria_fe` stayed correct.** In every run:
- No bank switch, fetch, write or call happened on either side. Upstream's `arm_access` was never high before the lock, and `daria_fe` made no commit (`u_seq.commit` 0).
- C1 (DPC+) or C2 (CDF) compared the whole visible state at every `pclk1` of the boot: the bank, the fetchers or stream state, fast fetch and fast jump, the call and service pendings. That was 39,080-39,090 `pclk1` in the runs that hand over and 9,616,380 in the runs that stay in 7800 mode, with 0 differences.
- At the first live `pclk1`, 5 clk_sys after `tia_en`, the stage-1 checks start: L1 at every latch, C1/C2, C3, C4 and the rest. They found nothing in the 300 frames that followed (`state_bad` 0, `dout_bad` 0).
- The every-clock checks ran through the boot: A1 (outside the `pre_lock` masks), A2 (`sel_up` against `sel_ram_sel`), A3 and the RTL assertions. They found nothing, including over the 5.3 s of Fuji screen with MARIA's DMA in the two runs that stay in 7800 mode.

**After the hand-over.** The game's code runs 66 clk_sys after `tia_en`, still on MARIA's phases, now 12 clk_sys a cycle with MARIA off. Upstream hands the phases to the TIA 8,946-23,094 clk_sys after `tia_en`, right after the game's first RSYNC write re-phases the TIA's divider. Without the BIOS the hand-over comes 901 clk_sys after the checks start. The checks are live through those 745-1,924 cycles ("FE spacing, checked, MARIA phases": E0→latch 6 in every one), so they cover a stretch of 2600 code on MARIA's phases that the runs without the BIOS do not have.

### 8.8 A core finding: the OpenBIOS does not hand over for DPC+ revision 1 and CDFJ+ images

This is outside `daria_fe`, which behaved correctly throughout (8.7). It affects the console with a BIOS loaded and "skip BIOS" off.

**What happens.** The cartridge check (8.1) decides from bytes the 7800 path reads, and `cart.sv` presents a 2600 image as a 7800 cartridge:
- An image of 48 KB or less sits unbanked at the top of $4000-$FFFF, so $FFFC reads the image's byte at its size less 4 (`cart.sv:265-273, 379-380`).
- An image of 64 KB or more is a SuperGame cartridge, with its highest 16 KB bank at $C000 (`cart.sv:195-198, 386, 396`).

Either way the BIOS reads the image's last bytes, not the reset vector of the 6507's bank.
- For Dino Eggs (`00 00` at $FFFC-$FFFD) and Elevator Agent (`FF FF`), `lda $FFFC; and $FFFD` or `ora $FFFD` takes the slot as empty.
- The BIOS then shows its Fuji screen for DISPLAYTIME (10 half-second ticks).
- It locks INPTCTRL at $13 (MARIA on, the BIOS on, locked) and starts its built-in game at $CBCC (`GameStart`, 6507 at $FF82 when the lock lands).
- `tia_en` never rises.

The runs show exactly this:
- the slot's reads stop at $1FFC-$1FFD (no $1FF8);
- no "2600 loader" line appears;
- the lock lands 76,935,885 clk_sys (5.37 s) after the release, in both runs.

**On hardware** the first test already decides. With the BIOS off, a 2600 cartridge answers at $1BEA (it sees A12 and nothing above it), so the RAM there reads back wrong, and every 2600 cartridge goes to 2600 mode ("see if the 4k mirror ROM is interfering with Maria RAM"). `top.sv` selects only the RAM at $1BEA (`cs_cart` is the complement of the other selects, `top.sv:354`), so the test passes here and the later tests decide on the 7800 path's bytes.

**Which images.** `scratchpad/g7b/biosdetect.py` follows the BIOS's tests on `cart.sv`'s mapping. It agrees with all five runs: the same decision, at the same test, with the same reads of $1FF8 and $1FFC-$1FFD. Over the 33 images in `sim/work/bupchip` (`champ/ntsc`, `champ_presents/ntsc`, `daria/roms`):
- every CDFJ+ image ends in `FF … FF EA` and is taken as an empty slot: Elevator Agent, Gorf, Qyx, Spiders, Turbo, Tutankham and Zaxxon;
- so is every DPC+ image of the Champ Games series, which ends in eight zeros: Scramble and Dino Eggs (both revision 1), Chaotic Grill, Lucky Chase, Stratovox, The End and Tomahawk 777;
- the others are taken as 2600 at a $FFF8 test, by a byte that happens to have bit 0 clear or a high nibble other than $F. They include SF2fix, Spacerocks, every CDF1 and CDFJ image, and the rest.

So the BIOS path cannot reach 2600 mode for DPC+ revision 1 or CDFJ+ on this core. The two runs cover `daria_fe` through the boot and 77 million clk_sys of 7800 mode for those schemes, but no hand-over.

**The Pocket builds the same files** (`src/fpga/core/core.qip:57, 68`: `../mister/rtl/cart.sv`, `../mister/rtl/top.sv`). With a BIOS loaded and "skip BIOS" off, these images should start the OpenBIOS's own game on the Pocket too. The Atari BIOS was not run (by instruction); its own cartridge check may decide otherwise. The file is upstream's (`src/fpga/mister/rtl/`, not edited). Whether to present a 2600 image in 7800 mode as a 2600 cartridge (13 address lines, the current bank), or to model the bus conflict at $1BEA, is the lead's call.

**Minimal reproduction** (any image of the lists above; the plain build prints the same "BIOS" lines without the `daria_fe` part):

```sh
cd /home/user/openFPGA-7800
WORK=<a work directory> FE=1 DTRACE=0 NAME=repro sim/bupchip/daria/run_daria.sh \
  sim/work/bupchip/champ_presents/arm/Dino-Eggs_demo_final_CGP_NTSC.bin +frames=10 +snap=0 \
  +bios=/home/user/openFPGA-7800/sim/work/bupchip/bios/7800openbios.bin
```

`run.log` shows:
- no "BIOS: the 2600 loader starts at $0480" line;
- "BIOS: INPTCTRL locked with tia_en 0 at clk_sys 77019072, 6507 pc ff82";
- "BIOS slot: … 1ffc-1ffd:4", with no $1FF8.

It takes about 16 minutes. Without this lane's `bo_stop` the run would never end, since the frame counter counts the TIA's VSYNCs. Offline: `python3 scratchpad/g7b/biosdetect.py <image>`.

### 8.9 Failures

None in `daria_fe`, so there is no differing clock to trace. The checks found no difference on any BIOS cartridge read: no bank switch, fetch or call on either side, and C1/C2 equal at every `pclk1`. Every must-be-0 counter is 0 in all six runs and both diagnostics. The one failure is the core's: for DPC+ revision 1 and CDFJ+ the BIOS never hands over (8.8, with its reproduction).
