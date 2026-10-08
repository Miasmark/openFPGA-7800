# Lane E3: RTL issues found by the random differential bench

One RTL issue (low severity: not reachable from real 6507 code, but it broke `daria_fe`'s own `a_pend_late` assertion and could corrupt a fetcher word), and three notes for the lead. No RTL file was changed by this lane. Every other failure the random bench (`sim/bupchip/daria/fe_rand/`, report `E3_random.md`) produced was traced to its first differing clock and was a bench error or a counted class of design 9.5 (E3_random.md section 7).

**After F1** (`F1_fixes.md`): issue 1 is decided and fixed in the RTL (option (a) with `rcyc`); the bench counts the release cycle as design 9.5's `rst_release` for all five kinds and fails the RTL before F1 (E3_random.md 5.3). Note 1 is decided as a counted class, not made exact; the bench counts only its exact form (E3_random.md 3.1). Notes 2 and 3 are unchanged. The final campaign found no new RTL issue (E3_random.md 5).

---

## Issue 1: a commit in the cycle where `rst_fe` falls leaves its post action pending past `pclk1` [Decided: option (a) + rcyc, F1_fixes.md 1]

**Files** (line numbers of the current RTL, after F1's commit c967eb6 and its review commits up to ec10fa3): `src/fpga/core/bupchip/daria_fe_core.sv`: the ready flags (`rdW`, `rdP`, `rdS_r`) are held at 0 while `rst_fe` is high (line 367: `if (rst_fe | pclk1)`); the post actions are set at the commit and fire on a ready flag (`pend_c` lines 298-309, `pend_s` with `s_fire` lines 503-510, `pend_r` with `r_fire` lines 530-538); since F1 the three also clear at `pclk1` (lines 307, 509, 536), `rcyc` is lines 626-630 and `a_pend_late` line 635. `daria_fe_seq.sv` has no reset, so `k[]` and `commit` run straight through `rst_fe`. `daria_fe.sv` line 97: `rst_fe = cart_reset | ...` (combinational). The table and the text below describe the RTL before F1 (commit 90ef6e7).

**What happens.** When `cart_reset` falls after k[3] of a 6507 cycle and that cycle's access is a cartridge register with a post action (DPC+ data fetcher read, PUSH/WRITE, field write, PARAMETER; CDF DSWRITE/DSPTR), the commit sets `pend_s` (or `pend_r`, `pend_c`), but the reads of k[1..4] happened under `rst_fe`, so `rdW`/`rdP` stay 0 for the rest of the cycle. The action is still pending at `pclk1` (`a_pend_late` fires) and stays pending through the following cycles. It fires at the first later cycle that sets the ready flag, with *that* cycle's `W` and the stale `sw_a`/`sw_be`. Upstream (combinational at the access, out of reset at that edge) performs the access in the release cycle.

**Minimal reproduction** (DPC+ rev 0; trace of `u_core`):

| clk_sys | `rst_fe` | `k` | bus | `commit` | `rdW` | `pend_s` | `sw_a` | upstream `counter[1]` | `daria_fe` counter[1] (state word $02) |
|---|---|---|---|---|---|---|---|---|---|
| 25211158-162 | 1 | k[0..4] | read `$1011` (DPC+ data fetcher 1), E0 at 158 | 0 | 0 | 0 | | 0 | 0 |
| 25211163 | **0** | k[5] | the access (phi2) | 1 | 0 | 0 | | 0 → 1 | 0 |
| 25211164 … 279 | 0 | | ten more cycles, none of them a data-fetcher read | (other commits) | 0 | **1** | `$02` | 1 | **0** (`a_pend_late` at every `pclk1`; C1 `counter[1] 0, upstream 1`) |
| 25211280 | 0 | k[4] | read `$100B` (fetcher 3), its k[3] sets `rdW` | 0 | 1 | 1 → fires | `$02` | 1 | written from fetcher 3's `W` into fetcher 1's word |

In this seed the stray write happened to restore counter[1] (fetcher 3's word held the same low bytes); in general it writes one fetcher's word into another's.

Reproduce (the RTL before F1): in `sim/bupchip/daria/fe_rand/`, `TAG=repro ./run_rand.sh 108 +cycles=2500000 +epoch=25000 +pg_mode=mix +rst_bus=1 +maxfail=4` gave `FAIL rtl_assert at clk 25211170 (epoch 72, cycle 1775183, scheme 21 rev 0): a_pend_late: a commit action pending at pclk1`, then `C1 state: counter[1] 0, upstream 1` (log in `sim/work/bupchip/daria/fe_rand/runs/repro_rstbus_s108.log`). `+rst_bus=1` lets the bench's CPU read any address while in reset, so the cycle in which the console reset ends can be a register access. (That stream changed since: `+rst_bus=1` now also plans writes in the release cycle, so the same command no longer replays this trace. To see the old behaviour, build the bench against a copy of `daria_fe_core.sv` without the three `pclk1` clears: `./campaign.sh rst old_dpc old_cdf`, E3_random.md 5.3.)

**Reachability.** Not from real 6507 code: a 6502 leaves reset through its reset sequence (reads at PC, the stack page, the vector `$1FFC/$1FFD`), none of them a DPC+/CDF register with a post action, and in DARIA's systems the 7800 BIOS runs first, with the 2600 path off. The bench's default (`+rst_bus=0`) therefore reads only the stack page while in reset, and the campaign never sees this. Lane A's O-1 (`a_p32_late` when `cart_reset` *rises* inside a DSWRITE/DSPTR cycle) is the same family; this one is the falling edge, and unlike O-1 its effect outlives the cycle.

**Options for the lead** (as written before the decision). (a) Drop pending post actions at `pclk1` (`pend_* <= 0` on `pclk1`, as the ready flags are), so a stranded action is lost in its own cycle instead of firing later with another cycle's data; (b) gate `commit` (or `s_set`, `pend_r`'s and `pend_c`'s sets) with a flag "this cycle's E0 was out of `rst_fe`"; (c) accept it and document it with O-1. (a) and (b) keep the release cycle inexact (upstream performs that access), but stop the corruption and keep `a_pend_late` meaningful.

## Note 1: `pause_lane` is reachable (lane B's B-1 says it is not) [Not made exact: F1_fixes.md 2]

**Files:** `src/fpga/core/bupchip/daria_fe_audio.sv` (`al`, lines 399-414), `docs/daria_fe/lanes/B_audio.md` (B-1, line 77). Upstream: `src/fpga/mister/rtl/cart_ram_tdp.sv` (`mapper_read_lane`, lines 61-64), `fe_rand_up.sv`'s port A address mux (cart2600's: the 6507's `sel_ram_a` while `sel_ram_sel`, else the audio engine's address).

**What B-1 says.** `al` loads `a_d[1:0]` at every edge with `pause` low, because "a paused 6507 cycle's select is what it was at the last unpaused edge", so the lane register and `al` always freeze at the engine's lane, and `pause_lane` "becomes unreachable".

**What happens.** `mapper_read_lane` samples the port's address *before* the last unpaused edge. When that edge is the `pclk1` that ends a 6507 cycle reading a RAM-backed register (select high), the address there is the 6507's `sel_ram_a`; the select falls only after that edge (the next cycle's address) and stays low through the pause. Upstream's lane freezes at the 6507's byte lane, `al` at the engine's (`a_d` = 0 when the engine is not issuing). A sample grant inside the pause whose capture lands on the first unpaused edge then reads a different byte lane of the same word.

**Minimal reproduction** (clock by clock; `pause` is `pause_core`):

| clk_sys edge | bus | `pause` | select | upstream `mapper_read_lane` | `daria_fe` `al` |
|---|---|---|---|---|---|
| n | DPC+ read of a RAM-backed register (here `$1012`, `sel_ram_a` lane 3), `pclk1` on this edge | 0 | 1 | ← 3 (the 6507's address) | ← 0 (`a_d`, engine idle) |
| n+1 … g | next cycle's address (`$1F18`, not RAM), frozen | 1 | 0 | 3 (frozen) | 0 (frozen) |
| g | audio refresh, voice 1 grant at byte address `$0CF4` (lane 0) | 1 | 0 | 3 | 0 |
| g+1 = first unpaused edge | capture | 0 | 0 | 3 → byte `mapper_q[3]` = `$4C` | 0 → byte `crb_q[7:0]` = `$A9` |

`sample_sum` then differs (`$14B` vs `$A8`), and so does that refresh's AMPLITUDE (one sample).

Found by seed 101 of group `mix` (n = 31221885, g = 31221908; `+trace_from=31221880 +trace_to=31221912` prints both engines in the `TA` lines). Before the bench had the class, this was `FAIL audio_bad at clk 31221911 (epoch 89, cycle 2206268, scheme 21 rev 4): A1 replica: ssum (sample_sum[7:0]) a8, upstream 4b`; the bench counted it as `pause_lane` and resynced. Since F1 the bench counts `pause_lane` only in this exact form (the select high at the last unpaused edge, each lane register holding what it loaded there) and masks only the sum and AMPLITUDE until they agree (E3_random.md 3.1).

**Impact.** One sample byte after an OSD pause, only when the pause starts right after a 6507 RAM-read cycle and an audio grant falls in the pause with its capture on the first unpaused edge. The design counts it (9.5 `pause_lane`; design.md 1191, 1608), so DARIA meets the design. Lane B's report should not call the class unreachable.

**If exactness is wanted** (the lead's call; not done here): `al` would load the port's lane as upstream's does, `sel_up ? <the 6507's RAM byte address>[1:0] : a_d[1:0]`, at every unpaused edge. That needs the 6507's RAM byte address in `u_audio` (one 2-bit input), and the bench's `pause_lane` count would then have to be 0.

## Note 2: the one-deep `pend2` (lane C issue 3), seen from this bench

Before the bench's 6502 write rule (E3_random.md 2.3) required three reads before a store, two campaign runs (seeds 101 and 102 of group `mix`) failed with cascades from a third CALLFN inside (M, M_fe] of a CDF call: upstream's one-clock busy dip at X let the stream place a CALLFN store in the cycle after the held fetch, and `pend2`, already holding call 2, dropped it. This is lane C issue 3 exactly, and as lane C says a 6507 cannot do it (a store needs its opcode and operand cycles). With the rule in place it never happened again. No action beyond lane C's note.

## Note 3: the held fetch after a service write can be a data-fetcher read (DPC+)

Design 4 (the "Hidden phase 2" row) says the held address is the opcode fetch after the CALLFN or service write, so it has no R use. Upstream's DPC+ (`mapper_dpcplus.sv` lines 113-115 and 251) arms the fast fetch on *any* read that returns `$A9` with fast fetch on, and then substitutes the next read at any address whose ROM byte is below `$28`. An RMW on a write register (`INC $105A`, CALLFUNCTION 1 then 2, as lane C's pairs) reads the ROM byte under `$105A`; if that byte is `$A9`, the opcode fetch after the RMW's writes, the held one, becomes a data-fetcher read of display RAM while the copy or fill runs. Its taken read then returns whatever byte each side's engine has written by then (different speeds, design 7.4): seed 134 of group `dpc` saw `$E2` (`daria_fe`) against `$1B` (upstream) at `$1FFF`, on the taken (shown) latch of the held cycle.

Real code reaches it only with `$A9` in ROM at the RMW's register address and an opcode below `$28` after the RMW, so it is a curiosity rather than a defect; but the design's "no R use" is not true for every 6507 program. The bench keeps its stream inside the design's assumption (E3_random.md 2.3) and counts any residual case as `held_svc_race`. A note in design 4, or a 9.5 class, would close it.
