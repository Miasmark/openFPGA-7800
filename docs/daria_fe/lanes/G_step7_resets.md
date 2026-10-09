# Lane G: design 12.2 step 7, console resets in game runs, and where BIOS and pause are covered (DARIA step 6)

Design 12.2 step 7 asks for "`+hard_reset_at` once per scheme; `use_bios`; pause", with the gate of step 6: 0 outside the classes of design 9.5. This lane ran the reset part in mode A, with bench stage 1: `tb_daria` with `FE=1`, `daria_fe` beside upstream's front ends (E1_shadow.md). It used one game image per scheme. It also states where the coverage of the BIOS path and of pause comes from, since neither can be run here.

**Status.**

- **Every reset run passes.** There are seven runs:
  - five with `+hard_reset_at`, one per scheme: DPC+ revision 0 and 1, CDF1, CDFJ and CDFJ+;
  - two with a console reset inside a running ARM call, on DPC+ and CDF1.

  In each run the reset lands during gameplay, and the "FE reset:" lines show the console reset. `daria_fe` then runs F6 again (2,082 clk_sys; 8,226 for CDFJ+) while upstream re-initialises, and the checks resume. Every one of the 46 must-be-0 counters of the `FE bad:` line is 0: before the reset, in the frame that holds it, and in every frame after it (section 3).
- **Classes seen.** `merge_amp` (CDF without the hook, each one resynced) is the only class of design 9.5 that occurs, as in lane E1's runs. The other non-zero count is the O1 information counter `drift_up`. `pre_lock` is 0 in every run.
- **Resets inside an ARM call.** `+hard_reset_at` cannot place one there. It raises the reset at the VSYNC rise that starts frame F, which is a 6507 write, and the 6507 is held while upstream's ARM runs a call or a DPC+ service.
  - The bench can still do it, through lane E2's event monitor (`fe_dir_mon.sv`, `+dir_rst=1`). The monitor raises the reset a set number of clk_sys after the n-th call accept, and is built into the same stage-1 bench.
  - Two runs use it, on SF2fix (DPC+) and draconian RC8 (CDF1). Each places the reset halfway through a gameplay call, while upstream's controller is in CTRL_RUNNING (section 2.2).
- **The same state after the reset as after the load.** On draconian (both runs) and Dino Eggs, the 99 frames after the reset are identical, row for row, to the 99 frames after the power-on load, in `frames.csv` and in `fe.csv`. On those games the boot screen ignores the joystick (section 3.3).
- **The directed reset and pause tests were rerun on this RTL**: all 17 pass (section 4).
- **BIOS and pause** are not built: there is no 7800 BIOS image here, and the Pocket never pauses. Section 5 states where their coverage comes from, with counts. It also corrects the brief on one point:
  - lane E3's 7800-mode intervals do not exercise `pre_lock`;
  - they exercise everything around it except the thing the class is about, the 7800 path's address on cart RAM port A, which lane E3's model of that port does not follow (E3_random.md 3.1, 5.2);
  - no bench reaches `pre_lock` itself.
- **No RTL issue found.** No `daria_fe` RTL, bench or script was changed, and nothing was committed. Game-derived outputs are under `sim/work/bupchip/daria/fe_reset/` (section 7).
- **One observation outside this lane (section 6.1).** The mode-A batch now running (`obj_fe_modeA`) uses a binary built before F1's RTL and bench changes.

---

## 1. Builds and commands

### 1.1 Builds

All three builds are from commit `1fb9d95` with a clean tree. The checksums of every source file used are in `sim/work/bupchip/daria/fe_reset/sources.md5`, and every job checked them before it ran. The `daria_fe` RTL is unchanged since `65a11f0` (F1's review), so these runs are on the final step-6 RTL.

| Build | Command | Binary (md5) | Used for |
|---|---|---|---|
| `frame` | `WORK=…/fe_reset/frame FE=1 sim/bupchip/daria/run_daria.sh --build-only` | `fe_reset/frame/obj_fe/vtb` (`56a59e02…`) | the five `+hard_reset_at` runs |
| `call` | the same with `WORK=…/fe_reset/call VERILATOR=sim/bupchip/daria/fe_dir/vwrap.sh`: lane E2's wrapper adds `fe_dir_mon.sv`, bound into `tb_daria` and read-only except for its injections (off by default) | `fe_reset/call/obj_fe/vtb` (`3e106750…`) | the two resets inside a call. Byte-identical to the binary `fe_dir/run_dir.sh` built for the directed rerun (section 4) |
| `plain` | `WORK=…/fe_reset/plain sim/bupchip/daria/run_daria.sh` (no `FE`) | `fe_reset/plain/obj/vtb` | one timing run, to find when Elevator Agent's gameplay starts (2.3) |

Each build has its own `WORK`, so that nothing here touches the shared `obj_fe` or the mode-A batch's `obj_fe_modeA`. Each run used `NOBUILD=1` against its frozen binary, and the job checked the binary's md5 first. Only one simulation of this lane ran at a time, through a queue (`fe_reset/queue.txt`, `fe_reset/runner.log`).

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

Upstream's re-init is the longer of the two in every run, as at the load: 5,259 clk_sys for DPC+, 3,475-3,479 for CDF and TBD for CDFJ+, against `daria_fe`'s F6 of 2,082 and 8,226 clk_sys. So the 1,000-clk_sys pulse is only the trigger, and the release is upstream's ("FE init: upstream's init done at …"). The checks resume 13-24 clk_sys later, at the first `pclk1` with the console running. With `bypass_bios`, `tia_en` rises in the first clock after the release, so the window in which design 9.5's `pre_lock` could arise is at most that one clock; no audio grant fell in it (`pre_lock` 0 in every run).

A VSYNC rise is a 6507 write. During an upstream call or DPC+ service the 6507 is held (`arm_call_stall`), so this reset can never land inside one (E2_directed.md 2.3). In all five runs the previous call had ended 12,479 to 224,067 clk_sys before the reset, and no service was running. The reset lands at a frame start in the middle of gameplay, between the game's calls, with the fetchers, the audio engine and (CDF) the stream pointers in use.

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
| Elevator Agent (CDFJ+) | TBD | TBD | 760 (TBD) |

Two images needed more than a first guess:

- **Dino Eggs.** A first run with `+fire_at=40 +play_at=70` made no ARM call through frame 107: the title ignored both the FIRE at 40 and the random FIRE from 70. That run was stopped (its process killed by PID, its partial outputs deleted) and replaced by the reference run's inputs, which start the game at frame 420.
- **Elevator Agent.** In the reference run, the first FIRE (frame 420) brings up a menu. The next one starts the game (frame 507). A 402-frame opening sequence follows: the agent rides a zip line down to the roof. The roof landing, where the player takes control, is at frame 912 (`runs/Elevator-Agent_demo_final_CG_NTSC/`, snapshots 450-1050).
  - A plain-build run (`fe_reset/plain/runs/explore_ElevatorAgent`, 450 frames, random input from frame 40, no front-end shadow, the same DUT timeline) showed the game starting at frame 278. FIRE skips the logo.
  - So the landing falls near frame 680, and the reset frame is 760.
  - The FE run's own `frames.csv` is identical to the plain run's for their 450 common frames. TBD

## 3. Results

### 3.1 Per run

"FE result" is the `FE result:` line: PASS means all 46 counters of the `FE bad:` line are 0 (design 9.6's list and the bench's own must-be-0 checks; E1_shadow.md 3, V.3). Counts are from `FE shadow:`/`FE counts:`. Clocks are clk_sys from time 0.

| Run | Scheme | Frames | Reset driven (frame) | Where it landed | F6 again (start, length) | Upstream's init done; checks resume | First call after | FE result | Classes (design 9.5) |
|---|---|---|---|---|---|---|---|---|---|
| `dpcp0_SF2fix` | DPC+ r0 | 300 | 42,912,152 (180) | VSYNC rise; call #285 (frame 179 line 241) ended 15,619 earlier; no call or service in flight | 42,912,163, 2,082 | 42,917,413; 42,917,437 | #286, +38,532 | PASS (0 bad) | none |
| `dpcp1_DinoEggs` | DPC+ r1 | 600 | 119,414,132 (500) | VSYNC rise; call #105 (frame 499 line 13) ended 224,067 earlier | 119,414,143, 2,082 | 119,419,393; 119,419,417 | #106 (the boot call, as #1 at power-on), +40,092 | PASS (0 bad) | none |
| `cdf1_draconian` | CDF1 | 330 | 54,836,624 (230) | VSYNC rise; call #460 (frame 229 line 230) ended 26,192 earlier | 54,836,635, 2,082 | 54,840,101; 54,840,121 | #461, +36,720 | PASS (0 bad) | `merge_amp` 11 (8 before the reset, 3 after), `resync` 11 |
| `cdfj_Mappy` | CDFJ | 430 | 81,129,212 (340) | VSYNC rise; call #679 (frame 339 line 246) ended 12,479 earlier | 81,129,223, 2,082 | 81,132,693; 81,132,709 | #680, +44,508 | PASS (0 bad) | `merge_amp` 10 (7 before, 3 after), `resync` 10 |
| `cdfjp_ElevatorAgent` | CDFJ+ | 860 | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| `dpcp0_SF2fix_call` | DPC+ r0 | 250 | 35,750,928 (150) | inside call #226, 4,000 after its request, controller RUNNING | 35,750,938, 2,082 | 35,756,188; 35,756,209 | #227, +44,300 | PASS (0 bad) | none |
| `cdf1_draconian_call` | CDF1 | 300 | 47,679,148 (200) | inside call #401, 8,000 after its request, controller RUNNING | 47,679,158, 2,082 | 47,682,624; 47,682,637 | #402, +43,360 | PASS (0 bad) | `merge_amp` 9 (6 before, 3 after), `resync` 9 |

In every run:

- "FE resets: 1 console resets after the checks started, 2 starts of the checks, 2 handoffs to the TIA's phases";
- I1/I2 compared the whole cart RAM (and, for CDF, the stream tables) after both inits, twice ("2 inits"), with `init_bad` 0;
- `E0->latch` 6..6 and `FE S1: 0`; `pre_lock` 0; `p32_reset` 0; `merge_late` 0; the longest A1 mask at most 18 clk_sys (`mask_stuck` 0);
- the stage-0 reference beside `u_fe` 0/0 ("FE reference:");
- `drift_up` (O1 information: upstream's `d_out` moving after the latch) TBD a run, as in every mode-A run; `drift_fe` 0.

### 3.2 What was compared, in all and from the reset on

From the reset on means the row of the frame that holds the reset plus every later row of `fe.csv` (the frame counter stops while the TIA is in reset, so that row covers the end of the frame before the reset, the reset, the re-init and the boot up to the game's first VSYNC).

| Run | Latches (all / from the reset) | Commits (all) | Calls R1/K1 (all / from the reset) | Services R2/R3 | Ticks (all / from the reset) | C3 pointer writes (all / from the reset) | K2 frames (all / from the reset) | Must-be-0 in `fe.csv` rows from the reset | Wall |
|---|---|---|---|---|---|---|---|---|---|
| `dpcp0_SF2fix` | 5,943,438 / 2,374,359 | 5,168,318 | 406 / 121 | 0 | 99,622 / 39,798 | 0 | 299 / 120 | 0 | 900 s |
| `dpcp1_DinoEggs` | 11,923,688 / 1,979,444 | 10,788,771 | 106 / 1 | 5 (frames 263 and 420) | 199,863 / 33,179 | 0 | 599 / 100 | 0 | 2,280 s |
| `cdf1_draconian` | 6,537,308 / 1,974,374 | 5,915,475 | 659 / 199 | 0 | 109,567 / 33,091 | 234,834 / 21,490 | 329 / 100 | 0 | 1,199 s |
| `cdfj_Mappy` | 8,529,966 / 1,775,983 | 7,370,809 | 858 / 179 | 0 | 142,966 / 29,765 | 503,778 / 87,547 | 429 / 90 | 0 | 1,697 s |
| `cdfjp_ElevatorAgent` | TBD | | | | | | | | |
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

### 3.4 Failures

None. No `daria_fe` failure was logged (`fe_err.txt` is empty in all seven runs), so there is nothing to trace and no reproduction to give.

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

## 5. BIOS and pause: where their coverage comes from

Neither is run in a game here. `tb_daria` ties `bypass_bios` to 1 and `bios_out` to 0 (`tb_daria.sv:196`), there is no BIOS image, and `pause` is tied to 0.

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

**What the path is.** On the Pocket, `use_bios = bios_loaded & ~skip_bios` (`atari7800_pocket.sv:875`) gives the core `bypass_bios = 0` and `tia_mode = 0` (`:933-934`). The 7800 BIOS then runs in 7800 mode, on MARIA's phases of 4 or 6 clk_sys with `access` 0, until it locks 2600 mode and `tia_en` rises (critic finding 22).

Before the lock, upstream's audio engine still ticks and refreshes. Its grants read whatever the 7800 path puts on cart RAM port A, because `top.sv:756-757` gives the port the 2600 path's address only with `mapper_init_busy || tia_en` (spec/audio.md 12.6; spec/bus.md B19). `daria_fe` reads its own RAM at the engine's address. So AMPLITUDE may differ until the first refresh after `tia_en`. That is design 9.5's `pre_lock`, a mode-A class. On the Pocket there is no upstream engine to differ from.

Counters and frequencies are 0 before the lock (no NOTE, no call), and the 6507 cannot read AMPLITUDE before `tia_en` (the cartridge data on the bus is the 7800 path's then). So the only exposure is an AMPLITUDE read between `tia_en` and that first refresh (spec/audio.md 12.6).

**What is covered, and where:**

- **Lane E3's 7800-mode intervals** (E3_random.md 2.3; `tb_fe_rand.sv:2555-2563`).
  - **The counts.** There are 1,050 intervals in the campaign (`ev_7800`), each of 20 to 3,019 clk_sys, started only with nothing in flight. In each, `tia_en` and `arm_driver_run` are low and the console is out of reset. Each ends with `tia_en` rising again without a reset, which is the transition a BIOS lock makes.
  - **What they exercise.** `daria_fe` and upstream run side by side with the 2600 driver off (no commit, the stall gate off). The audio engines keep ticking and refreshing, with A1/T1/T2 comparing every clock, and then return to 2600 mode. In the `all`, `dpc`, `fastddr` and `rst_all` groups the phase generator also gives phase 2 of 4 clk_sys while the driver is off, MARIA's 7800-mode timing (`fe_phase_gen`, `+pg_ph2_4`; 200 per mille in `all`).
  - **The correction.** These intervals do **not** exercise `pre_lock`. E3's model of port A follows the 2600 side's address whatever `tia_en` is; only the 6507's write is gated (`fe_rand_up.sv:355-358`: "without tia_en the port is the 7800 path's (not modelled: no write)"). So both engines read the same word, and the class's condition never arises. E3 lists `pre_lock` as not reachable (E3_random.md 3.1, 5.2), and its count is 0.
- **Console resets** take `tia_en` down and back up with the engine running: `tia_en = tia_req && !eff_reset` (`tb_fe_rand.sv:198`). E3 makes 5,250 of them (1,050 at a random moment, 4,200 downloads), all followed by I1/I2 (5,250 inits). The ten E2 reset tests and the seven runs of section 3 make 24 more. With `bypass_bios`, `tia_en` rises in the first clock after the release, so none of them gives a `pre_lock` window. `pre_lock` is 0 in every run of section 3 and every test of section 4.
- **MARIA's phases before the first handoff.** Every `tb_daria` run starts its checks on MARIA's phases and hands over to the TIA's 901 clk_sys later ("FE handoff: TIA phases from …"). It does so again after every reset, twice in each run of section 3, with `tia_en` already high.

**Not covered by any bench:** `pre_lock` itself. That is the 7800 path's address on port A while upstream's engine refreshes before the lock, and the first lock after a load with no earlier 2600 activity. It needs a BIOS image and `bypass_bios = 0` in `tb_daria` (E2_directed.md 7, question 3). The lead's task list has it as a separate item ("use_bios runs: `+bios` in tb_daria"). Until then the evidence is the argument above: the class can change AMPLITUDE only, and only until the first refresh after `tia_en`.

## 6. Observations

1. **The mode-A batch runs a pre-F1 binary.** `sim/work/bupchip/daria/obj_fe_modeA/vtb`, the binary of the 30-image batch now running, has the timestamp of the old `obj_fe/vtb`: 2026-10-08 08:10.
   - That is before F1's commits `c967eb6`/`45b1376` and `65a11f0` (authored 08:58 and 10:18).
   - Its strings contain neither `obus_ffe` nor `commit_pclk1`. This lane's `1fb9d95` build contains both.
   - So that batch checks the RTL and the bench as they were before F1.
   - This lane did not touch it. Whether its results stand for the final RTL is the lead's call.
2. **`tb_daria`'s `+reset_at` is the 2600's RESET switch** (held for 6 frames, `tb_daria.sv:43, 794`), not a console reset. It was not used.
3. **Run time.** The `FE=1` runs took 3.0 to 4.4 s a frame on this machine while the batch and another lane's mode-B runs shared it (load average 6 on 4 cores at times).

## 7. Outputs

All under `sim/work/bupchip/daria/` (game data, not in git):

- `fe_reset/frame/runs/<name>/`, `fe_reset/call/runs/<name>/`: `run.log`, `fe.csv`, `fe_ref.csv`, `fe_err.txt` (empty), `frames.csv`, `calls.csv.gz`, `summary.txt`, `report.txt`; the call runs also have `dir_cov.txt`.
- `fe_reset/plain/runs/explore_ElevatorAgent/`: the timing run.
- `fe_dir/g7/`: the directed rerun (`results.txt`, `runs/fe/<test>/`). Its images are synthetic.
- `fe_reset/sources.md5`, `fe_reset/{frame,call}/vtb.md5`, `fe_reset/queue.txt`, `fe_reset/runner.log`, `fe_reset/dir_g7.log`.
