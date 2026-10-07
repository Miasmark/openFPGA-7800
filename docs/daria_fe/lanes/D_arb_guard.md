# Lane D: `daria_fe_arb`, `daria_fe_guard` (DARIA step 6)

This is lane D's report for `docs/daria_fe/design.md` 12.2 step 1. It covers:

- the port arbiter of design 3: the owners and muxes of front-end ROM port A, cart RAM port B (R) and state RAM port B (S); the grants; `crb_use`; the guard's effects at the ports (3.5); and the assertions of 3.6;
- the shared-edge phase detector and guard of design 8 (D4);
- their unit benches (12.3) and their Quartus probes (10.3).

The ports are `docs/daria_fe/interfaces.md`'s, unchanged. **No port request was needed.**

**Status.** Built and passing.

- **`tb_fe_arb`:** 28 million `clk_sys` with the default RAM model and the same 28 million with `POISON=1`, in 10 runs each (seeds 1, 101-108, 12; every `fe_phase_gen` preset). Every check is 0.
- **`tb_fe_guard`:** 17 clock lanes × 10^6 `clk_sys` edges, seeds 1-3 (seed 1 also under `POISON=1`). Every check is 0.
  - At ÷48/÷18 the detector locks 15-17 clocks after start, and relocks within 18 clocks of every phase move or clock stop (237-251 per seed, every one relocked).
  - `phb_next` marks exactly the edge 17.46 ns after a `clk_arm` edge: about 333,000 times per lane, never elsewhere.
  - It never locks at ÷19 (five offsets), 5× (two offsets) or 1× (longest consistent run 5, 3 and 3, against 13 needed).
- **Mutations:** 58 of 58 caught (44 in the arbiter, 14 in the guard).
- **Area:** arb **107 ALMs**, guard **6 ALMs** (design 10.3 gate for the arb ≤ 130; 10.1 estimates 110-140 and 15-20).

The RTL files are those of the earlier, interrupted lane-D agent: `daria_fe_guard.sv` as committed in 25ed575, `daria_fe_arb.sv` as committed in 906ea8f, neither changed since. This agent read them against design 3 and 8 and interfaces.md, judged them finished and correct, and changed nothing in them. This agent's own work:

- the guard bench's long-stop lane, never-lock `guard_on` check and `+restate` switch;
- ten more mutants;
- the arb timing wrapper;
- every run and probe below;
- this report.

## 1. What is built

| File | What it is |
|---|---|
| `src/fpga/core/bupchip/daria_fe_arb.sv` | Design 3:<br>- the grants of 3.1 (R), 3.2 (S) and 3.3 (A), each the highest-priority eligible request;<br>- one-hot AND-OR muxes onto `crb_*`, `stb_*` and `fea_addr`, parked at address 0 / no write / be 0 / data 0 without an owner;<br>- `crb_use` (reg);<br>- the owner taps `own_r`/`own_s`/`own_a` (bit = priority, `daria_fe_pkg::OR_/OS_/OA_*`);<br>- `ev_grant_steal`;<br>- the assertions `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr`, plus `a_owner` (3.6's "one owner per port") |
| `src/fpga/core/bupchip/daria_fe_guard.sv` | Design 8.1 term for term:<br>- `pd_tog` on `clk_arm`; `pd_rx` and `pd_rx1` on `clk_sys`;<br>- `pd_same`;<br>- the flywheel `ph`/`good`/`lk`;<br>- `phb_next = lk & ph == 0` (from the flywheel register);<br>- `guard_on = lk & (call_win \| !cpu_ready)`;<br>- `ev_unlock`;<br>- the 8.2 attributes on `pd_tog` and `pd_rx`;<br>- power-up values, no reset (1.5 rule 7) |
| `sim/bupchip/daria/fe_unit/tb_fe_arb.{sv,f}` | The arbiter's unit bench (section 2.1) |
| `sim/bupchip/daria/fe_unit/tb_fe_guard.{sv,f}` | The guard's unit bench on the VCO lattice (section 2.2) |
| `sim/bupchip/daria/fe_unit/tb_fe_arb_mut.sh` | Mutation check of both benches (section 4). `GPLUS=+restate=0` runs the guard mutants against the physical checks alone |
| `sim/bupchip/daria/fe_unit/tb_fe_arb_probe.v` | Timing-probe wrapper: `daria_fe_arb` between two rows of `clk_sys` registers (section 5). A `.v` file, so `run_unit.sh` does not take it for a bench |

Every file is MIT, `` `default_nettype none `` (restored at the end), with no output-port initialiser.

**Lint.** Both RTL files are clean under interfaces.md section 2's `-Wall` lint. The whole tree exits 0, and each block alone reports only the package's UNUSEDPARAM. The waivers:

- UNUSEDSIGNAL on `aud_addr[1:0]`, `k[7:4,2]` and the `op` fields other than `c.cdsw`/`c.cdsp`;
- UNUSEDSIGNAL on the bench-only assertion taps;
- PROCASSINIT on the power-up values (the repository's idiom).

### 1.1 D10

- **Muxes.** Every mux is a one-hot AND-OR of the owners' terms, and the grants are one-hot by construction:

  | Port | Address terms | Data, byte enables, write enable |
  |---|---|---|
  | R | 5 (F6 and the copy engine share `cp_*`) | 3 owners |
  | S | 3 | 3 owners |
  | A | 3 | — |

  These feed the M10K's own port registers. The design prescribes them (3.1-3.3; 10.1 budgets "R address (6 owners × 13)").
- **Registers.** The arbiter's fabric registers are `crb_use` and the three per-cycle assertion flags (`sh_q`, `sup_q`, `cm_q`). Each has one data input and no enable.
- **Every stage registered.** The arbiter is combinational between its requesters, whose outputs come from registers or M10K q (1.5 rule 1), and the M10K inputs.
  - No grant feeds a request inside `u_arb`.
  - Lane B confirms the audio reads `aud_take` and `aud_a_gnt` only into registers.
  - Lane A confirms the same for `p32_gnt` and `wb_gnt`.
- **Guard.** `good` and `lk` have one load enable and a two-input data mux each. `ph` has a three-way data mux (1, 0, `ph + 1`) and no enable.

### 1.2 Readings of the design (no change of behaviour)

| # | Where | Reading |
|---|---|---|
| D-1 | 3 "parked at address 0 with no write" | A port with no owner presents address 0, `we` 0, `be` 0 and data 0 |
| D-2 | 3.1 R data mux | On a read by the core's fixed user, `crb_be`/`crb_wd` carry `cr_fix_be`/`cr_fix_wd`. They are a don't-care with `we` = 0, and dropping the `!cr_fix_we` gate saves logic. The bench checks be and data on every write and on every parked clock |
| D-3 | 3.6 "in a cycle" (S0-9, interfaces.md 10 item 6) | A cycle runs from a `k[0]` clock to the clock before the next `k[0]`. Three registered flags hold "`ev_short` / `ev_guard_sup` / a commit seen in this cycle before this clock". The two assertions that use them:<br>- **`a_collide`** = a steal with no `ev_short` in its cycle up to and including this clock. A steal before an early commit is a real collision (until C, `fix_eff ⇒ sel_up`, 3.4 (a)).<br>- **`a_guard_core`** fires in two cases: at a commit when a suppression came earlier in the cycle or in the same clock; and at a suppression that follows the commit in the same cycle (a committed cycle's post write being dropped) |
| D-4 | 3.6 "one owner per port … (simulation only)" | An added internal tap `a_owner` (two owners on R, S or A), a pulse like the other assertions. Verilator and Quartus see a plain signal, and synthesis removes it. The bench requires it 0 and checks `$onehot0` on the three owner taps |
| D-5 | `daria_fe_pkg` owner bits | `B_OR_*`/`B_OS_*`/`B_OA_*` are local copies of the package constants: Quartus 21.1 rejects a package-scoped name in a select on an `assign`'s left-hand side. The values are the package's |
| D-6 | 1.7 `own_r`, `own_a` | F6 and the copy engine share `cp_*`/`ca_*` and are told apart by `f6_act`:<br>- `own_r[OR_F6] = cp_req & f6_act`;<br>- `own_r[OR_COPY]` = the copy grant without `f6_act`;<br>- `own_a` likewise |
| D-7 | 8.1, 8.3 "lock after 12 consistent edges" | 8.1's code verbatim: `good` counts 0 … 12 after a re-anchor, and `lk` loads at the next match. So the lock comes in the 14th clock after the mismatching clock: 13 consecutive matches (8.3's 12, plus the first). The bench's flywheel restatement uses that count, and the measured lock times (15-17 from power-up, whose anchor `ph = 1` is arbitrary; ≤ 18 after a move) are within 8.4's 24 |
| D-8 | 1.4 `ev_unlock` | `ev_unlock = lk & mism`: high in the clock whose ending edge drops `locked` |

## 2. The benches

Both run under `run_unit.sh` (Verilator 5.040, `--binary --timing -O2`), with and without `POISON=1`. Each passes iff it exits 0.

### 2.1 `tb_fe_arb` (design 12.3, `daria_fe_arb`)

**The ports.** `daria_fe_arb` drives `daria_mem #(.WIN_KB(32))`'s cart RAM port B, state RAM port B and front-end ROM port A. The ROM is a random image, loaded through `cap_we` first.

**The requesters.** Each one is a bench process with design 1.5's protocol: request, address, write enable, byte enables and data are registers (NBA at the edge), held while it waits, with the grant back in the same clock.

| Port | Requester | Behaviour |
|---|---|---|
| R | core fixed (`cr_fix`) | One clock per request, never retried. Biased to `k[1..3]` (reads, `cr_fix_use` on them) and to commit clocks (byte writes, random partial byte enables), with noise elsewhere |
| R | P32, pointer write, copy engine and F6 (`cp_*`) | Retry until granted |
| R | audio | ISSUE until `aud_take`, then one CAPTURE clock, then a random gap, as the audio's FSM does |
| S | core (`cs_*`) | One clock per request |
| S | call port (`cl_*`) | Retries until granted |
| S | F6 clear (`cz_*`) | Mostly during F6 |
| A | lookahead | One clock, mostly in `k[0]` |
| A | audio sample, copy/F6 source | Retry until granted |

Addresses are biased half the time to eight hot words, so collisions of interest occur.

**The controls.**

- `fe_phase_gen` (`MODE all`, or `+pg_mode`) gives `pclk1`/`pclk0`/`access`/`a_in`, and a copy of design 2.1 gives `k`, `commit` and `ev_short`.
- `sel_up` toggles at random.
- `f6_act` comes in bursts of 20-120 clocks, about every 2,000.
- A bench flywheel of period 3 gives `phb_next`. `locked` comes in long locked and unlocked stretches, and `guard_on = locked &` a random window.
- `op.c.cdsw`/`cdsp`, `p32_q`, `rdP` and `wb_v` are random.
- `ev_guard_sup = guard_on & (cr_fix | cr_p32)`, `u_core`'s formula (lane A, `daria_fe_core.sv`).

**The reference.** An independent restatement of 3.1-3.3. On each port the owner is the first eligible requester in priority order:

| Port | Eligible requesters, highest priority first |
|---|---|
| R | F6 = `cp_req & f6_act`; core fixed (not under `guard_on`/`f6_act`); audio (`aud_issue & !sel_up & !f6_act & (!guard_on \| phb_next)`); P32, pointer write, copy engine (each not under `guard_on`/`f6_act`) |
| S | `cz` > core > call |
| A | F6 source > lookahead > audio sample > copy source (the last three not under `f6_act`) |

The bench keeps a shadow of cart RAM and of state RAM, updated from the reference owner's writes.

| 12.3 requirement | Check (every clock) |
|---|---|
| 1. one owner per port per clock; the priority orders of 3.1-3.3 | **own:** `own_r`/`own_s`/`own_a` are `$onehot0` and equal to the reference owner.<br>**gnt:** every grant output equals "this requester owns the port".<br>**port:** `crb_*`/`stb_*`/`fea_addr` are the owner's address and write enable, and on writes its be and data; with no owner, all 0.<br>**mem:** every R read (consumed or not), S read and A read returns the shadow's or the image's word one clock later, which checks each mux end to end through `daria_mem`.<br>**Coverage** (any run of ≥ 10^6 clocks; ≥ 1,000 each unless noted): every owner of every port; the contention pairs fixed/audio, fixed/P32, audio/P32, P32/pointer, pointer/copy, F6/any (≥ 100); S `cz`/core (≥ 100), core/call; A lookahead/audio, audio/copy, F6/lookahead (≥ 100) |
| 2. yields never take an audio edge; `aud_take` equals the reference rule | **yld:** no P32, pointer or copy grant in a clock with `aud_issue & !sel_up` (coverage: a yielding user waiting at an audio edge).<br>**aud:** `aud_take == aud_issue & !sel_up & !fix_eff & !f6_act & (!guard_on \| phb_next)` |
| 3. under `guard_on`: no non-F6 R write, every R read registered on a `phb_next` edge, suppressed requests parked | **grd:** while `guard_on`:<br>- no `crb_we` except F6's;<br>- the core fixed and P32 never own R;<br>- every non-F6 owner is the audio in a `phb_next` clock (so it registers on the phase-B edge);<br>- with a suppressed request and no owner, R shows address 0 and no write.<br>Coverage: audio on phase B, audio waiting for it, suppressed requests, writes waiting, F6 writes under the guard |
| 4. `crb_use` marks exactly the consumed reads | **use:** `crb_use` == "the previous clock's owner was the core fixed with `cr_fix_use`, P32 or the audio"; in each such clock `crb_q` equals the shadow's word at that read's address |
| 5. `own_*` one-hot | **own** (above), and `a_owner` 0 |
| 3.6 assertions | **asr:** `ev_grant_steal`, `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr` equal the bench's restatement every clock (the per-cycle bookkeeping restarts at `k[0]`). The random stimulus makes each one fire (≥ 100 times in a run of ≥ 10^6 clocks) and not fire, so both polarities of each formula are exercised |

`+cycles=N` (default 2,000,000), `+seed=N`, `+verbose=1`, and `fe_phase_gen`'s `+pg_*`. The coverage minimums apply from 10^6 clocks.

### 2.2 `tb_fe_guard` (design 12.3, `daria_fe_guard`; 8.4)

**Clocks.** Every lane is one `daria_fe_guard` with its own `clk_arm`, all on one `clk_sys`, on the Pocket's VCO lattice:

| Clock | VCO steps | Period |
|---|---|---|
| one VCO step (687.27 MHz) | 1 | 1,455 ps |
| `clk_sys` | 48 | 69,840 ps |
| DARIA's `clk_arm` (÷18) | 18 | 26,190 ps |
| phase B (after a `clk_arm` edge) | 12 | 17,460 ps |

**Path delays.** The constrained `pd_tog → pd_rx` path is modelled per launch. Each rising `clk_arm` edge reaches the DUT d ps after its lattice time, with d drawn for that edge in [1,000, 6,000] (each bound 10% of the time). `clk_arm` feeds only `pd_tog`, so that is exactly the launch-to-capture delay of that toggle. No arrival coincides with a `clk_sys` edge (a 1 ps nudge).

| Lane | Clocks | What it is for |
|---|---|---|
| `d18_o0`, `d18_o6`, `d18_o12` | ÷18, lattice offset 0, 8,730, 17,460 ps | The shared edge on each of the three `clk_sys` edges of the 144-step frame (8.4's `d_ofs`) |
| `d18_mvA`, `d18_mvB` | ÷18 with phase moves | Every 2,000-22,000 clocks `clk_arm` stops for 0-5 `clk_sys` (no stop in a quarter of the moves), then resumes on a random one of the three offsets (the same one in a third of them) |
| `d18_stop` | ÷18 with long stops | As above, with stops of 20-400 `clk_sys` |
| `d19_o0` … `d19_o16` | ÷19 (27,645 ps), five offsets | The fallback |
| `x5_o0`, `x5_o3` | `clk_arm` = 5 × `clk_sys`, offsets 0 and 3 ns | Mode A's upstream `clk_arm` |
| `x1` | `clk_arm` = `clk_sys` | Coincident |
| `d18_bad` | ÷18 with d in [1, 10] ns, outside 8.2's bound | Negative control: the lattice check must see errors |
| `x5_amb`, `x1_amb` | 5× / 1× with a `clk_arm` edge 3 ns before every `clk_sys` edge | Information only (section 6, O-3) |

`call_win` and `cpu_ready` are random registered levels.

**Every clock of every lane:**

| Check | |
|---|---|
| **ps** | `pd_same` == the parity of the toggles that arrived between the last two `clk_sys` edges (the receiver pair, independent of the lattice) |
| **fly** | `ph`, `good`, `locked` against a restatement of 8.1's flywheel:<br>- `ph` = (clocks since the last mismatch) mod 3;<br>- `good` = min(that − 1, 12);<br>- locked iff that ≥ 14.<br>And `phb_next` == that "locked & ph == 0" (from the flywheel, not `pd_same`) |
| **gd** | `guard_on == locked & (call_win \| !cpu_ready)`; `ev_unlock` == locked now and not in the next clock |

| 12.3 / 8.4 requirement | Check |
|---|---|
| `pd_same` against the edge arithmetic | **lat** (8.4's `det_bad`): in every settled ÷18 clock, `pd_same` == "the edge before this clock is shared": `(T − a0) mod 26190 == 0`. A clock is settled iff the launches that decide it, and the lattice edge before them, lie outside every move's transient (last old lattice edge … resume + 6 clocks) |
| `phb_next` on phase B | **phb:** `phb_next` only in a clock whose ending edge is 17,460 ps after a lattice `clk_arm` edge, the one after a shared edge. Once locked after the last move, `phb_next` in every such clock |
| lock within 24 clocks at ÷18 | **lock:** the first correct lock (locked, with `phb_next` agreeing with the arithmetic) within 24 clocks of the run's start, and of every resume after a move or stop. No unlock in a settled regime once locked |
| re-lock after a phase move | **lock** in `d18_mvA/B` and `d18_stop`. Coverage: ≥ 10 relocks per lane |
| unlock rule (8.3: unlock on the first mismatch; nothing to lock on without `clk_arm`) | **dead:** while `clk_arm` is stopped, unlocked from the fourth clock after its last toggle's arrival until it resumes. Coverage: ≥ 1,000 such clocks in `d18_stop` |
| never locked at ÷19 or 5× over 10^6 edges | In the ÷19, 5× and 1× lanes: `locked` never high, and `guard_on` never high (8.3, D4: unlocked, `guard_on` = 0). The longest consistent run is reported |
| (the check is not blind) | `d18_bad` must show lattice errors |

`+seed=N` (default 1), `+edges=N` (default 10^6), `+verbose=1`. `+restate=0` counts the ps, fly and gd checks without failing on them, so only the physical checks above can fail the run (section 4).

## 3. Results

### 3.1 `tb_fe_arb`

Every run: **errors own 0, port 0, gnt 0, aud 0, yld 0, grd 0, use 0, mem 0, asr 0**, and no coverage hole. Each run was made twice, with and without `POISON=1`, with identical results.

| Run | Clocks | Commits (short) |
|---|---|---|
| default (`run_unit.sh`, seed 1, `all`) | 2,000,000 | 123,117 (14,421) |
| seed 101, `all` | 2,000,000 | 123,287 (14,376) |
| seed 102, `nominal` | 2,000,000 | 150,018 (0) |
| seed 103, `short` | 2,000,000 | 158,902 (63,594) |
| seed 104, `stretch` | 2,000,000 | 128,567 (0) |
| seed 105, `pause` | 2,000,000 | 108,553 (0) |
| seed 106, `held` | 2,000,000 | 101,833 (0) |
| seed 107, `mix` | 2,000,000 | 141,700 (4,234) |
| seed 108, `all` | 2,000,000 | 123,637 (14,344) |
| seed 12, `all` | 10,000,000 | 618,064 (72,241) |
| **total** | **28,000,000** (×2) | |

**The 10-million-clock run (seed 12), in detail:**

| What | Counts |
|---|---|
| R owners | F6 140,106; fixed 816,854; audio 947,251; P32 233,017; pointer 410,958; copy 400,987; none 7,050,827 |
| S owners | clear 218,951; core 1,955,718; call 1,255,731 |
| A owners | F6 127,177; lookahead 948,610; audio 874,364; copy 704,339 |
| Contention, R | fixed/audio 105,426; fixed/P32 99,806; audio/P32 56,871; P32/pointer 100,096; pointer/copy 184,516; F6/any 138,433 |
| Contention, S and A | `cz`/core 43,658; core/call 313,582; lookahead/audio 93,121; audio/copy 79,526; F6/lookahead 12,407 |
| Audio grant edges | 1,519,879, with a yielding user waiting in 837,066 of them |
| Guard on | 3,329,119 clocks (1,109,831 with `phb_next`): audio on phase B 274,010; audio waiting for it 303,972; suppressed core requests 1,873,718; writes waiting 2,631,026; F6 writes under the guard 42,014 |
| Reads checked | R 1,895,078 (consumed 1,808,075); S 1,997,223; A 9,999,999 |
| Assertion formulas checked every clock, firing | steal 105,426; collide 97,896; `wb_late` 36,947; `p32_late` 68,079; `guard_core` 1,016,204; `guard_wr` 2,732,006 |

The poisoned model changes nothing here, as expected:

- The arbiter never puts two owners on a port, so rule (b) cannot trigger (port A of cart RAM is idle).
- The bench reads q only in the clock after a read, never after a partial write (1.5 rule 3).

### 3.2 `tb_fe_guard`

Seeds 1, 2, 3, each 17 lanes × 10^6 `clk_sys` edges; seed 1 also with `POISON=1` (no memory in this bench; identical result). **ps, fly, gd and evu errors are 0 in every lane.** Seed 1:

| Lane | Settled clocks | Shared edges | `phb_next` | lat / phb errors | First lock (clocks) | Moves / relocks (max clocks) | Clocks checked with `clk_arm` stopped (locked) | Locked clocks | Longest consistent run |
|---|---|---|---|---|---|---|---|---|---|
| `d18_o0` | 999,999 | 333,333 | 333,329 | 0 / 0 | 15 | — | — | 999,986 | 999,999 |
| `d18_o6` | 999,999 | 333,333 | 333,328 | 0 / 0 | 17 | — | — | 999,984 | 999,997 |
| `d18_o12` | 999,999 | 333,333 | 333,328 | 0 / 0 | 16 | — | — | 999,985 | 999,998 |
| `d18_mvA` | 999,150 | 333,041 | 332,857 | 0 / 0 | 15 | 84 / 84 (18) | 13 (0) | 998,811 | 38,248 |
| `d18_mvB` | 999,144 | 333,036 | 332,844 | 0 / 0 | 17 | 86 / 86 (18) | 7 (0) | 998,792 | 59,191 |
| `d18_stop` | 983,369 | 327,782 | 327,589 | 0 / 0 | 15 | 81 / 81 (18) | 15,677 (0) | 982,953 | 21,917 |
| `d19_o0` … `d19_o16` | — | — | 0 | — | never | — | — | **0** (`guard_on` 0) | 5 |
| `x5_o0`, `x5_o3` | — | — | 0 | — | never | — | — | **0** (`guard_on` 0) | 3 |
| `x1` | — | — | 0 | — | never | — | — | **0** (`guard_on` 0) | 3 |
| `d18_bad` (negative control) | 999,999 | 333,333 | 84,433 | **135,914 / 234** | — | — | — | 275,020 | 128 |
| `x5_amb` (information) | — | — | — | — | — | — | — | 80 | 19 |
| `x1_amb` (information) | — | — | — | — | — | — | — | 101 | 19 |

**Seeds 2 and 3** give the same first-lock times, every relock within 18 clocks, and 0 in every check. The moves differ: 84/80/86 (seed 2) and 82/73/82 (seed 3) in `d18_mvA`/`d18_mvB`/`d18_stop`. The stopped-clock checks number 20,262 and 17,883 in `d18_stop`. The ÷19/5×/1× lanes are never locked, with the same longest runs (5/3/3).

**Reading the table.**

- **Lock time.** 8.3's "3 + 12 clocks" is the design's 13 matches plus up to 3 clocks to the first shared edge. The worst relock is 18, against the 24 acceptance.
- **Never-lock margin.** The longest consistent run at ÷19 is 5, against 13 needed. This matches the lattice simulation 8.3 quotes ("longest consistent run 4-5").
- **The negative control** shows why 8.2's 6 ns bound matters. With up to 10 ns, a toggle launched 8.73 ns before an edge is sometimes missed. `pd_same` is then wrong in 13.6% of the clocks, and the detector keeps losing its lock: 21,901 unlocks, longest consistent run 128 clocks.
- **`phb_next` per lane** is the 333,333 shared edges less the 4-5 before the first lock. The phb check confirms `phb_next` at every phase-B edge once locked, and only there.

## 4. Mutations

`tb_fe_arb_mut.sh` applies each mutant to a copy of the RTL file (a literal find-and-replace that must match exactly once) and builds and runs the bench on the copy: `tb_fe_arb` with 300,000 clocks, `tb_fe_guard` with 200,000 edges. A mutant is caught iff the bench fails.

**58 of 58 caught.**

- **Arbiter, 44 of 44:** `runs_D/mut_all.log`. The guard entries in that log ran on the bench before the stop lane was added.
- **Guard, 14 of 14,** on the final bench: `runs_D/mut_guard.log`.

Every arbiter catch is a check error (`own`, `port`, `gnt`, `use`, `asr`), not a coverage hole: coverage minimums apply only from 10^6 clocks.

| # | Mutant (what it breaks) | First failing check |
|---|---|---|
| a1 | core fixed R not suppressed under the guard | own (owner under the guard) |
| a2 | audio granted inside upstream's select (`!sel_up` dropped) | own |
| a3 | audio and the core's fixed use both granted (`!fix_eff` dropped) | own (not one-hot) |
| a4 | audio granted off phase B under the guard | own |
| a5 | audio waits for phase B without the guard | own |
| a6 | audio granted during F6 | own |
| a7 | yielding users take an audio edge | own (not one-hot) |
| a8 | pointer write beside the P32 read | own |
| a9 | copy engine beside the pointer write | own |
| a10 | copy engine beside the P32 read | own |
| a11 | F6 below the core's fixed use | own |
| a12 | `crb_use` misses the P32 read | use |
| a13 | `crb_use` on the core's writes | use |
| a14 | `crb_use` not registered (marks the grant clock) | use |
| a15 | pointer write never written | port |
| a16 | pointer write's top byte lost | port |
| a17 | audio word address taken from the byte address | port |
| a18 | F6 writes zeros | port |
| a19 | call port beside the core on S | own |
| a20 | F6 clear never written | port |
| a21 | F6 clear writes the core's data | port |
| a22 | lookahead during F6 | own |
| a23 | audio sample beside the lookahead | own |
| a24 | F6 source below the lookahead | port |
| a25 | copy/F6 source address lost | port |
| a26 | owner tap: F6 also counted as copy | own |
| a27 | owner tap: F6 source also counted as copy | own |
| a28 | `a_collide` forgets the cycle's early commit | asr |
| a29 | `a_collide`'s cycle never ends | asr |
| a30 | `a_guard_core` misses a suppression after the commit | asr |
| a31 | `a_guard_wr` misses the pointer write | asr |
| a32 | `a_p32_late` fires under the guard | asr |
| a33 | `a_wb_late` one clock late | asr |
| a34 | steal counted inside upstream's select | asr |
| a35 | call port's byte 0 lost | port |
| a36 | P32, pointer write and copy granted under the guard | own |
| a37 | core fixed byte write as a word write | port |
| a38 | core S partial write as a word write | port |
| a39 | `a_collide` ignores this clock's `ev_short` and the `k[0]` restart | asr |
| a40 | `a_collide`'s cycle starts one clock late (`k[1]`) | asr (first at clock 147,753 of 300,000: a steal in a `k[0]` clock after a short cycle is rare) |
| a41 | suppressed core address not parked | port |
| a42 | suppressed core write still written | port |
| a43 | `crb_use` on an audio request not granted | use |
| a44 | core S request beside the F6 clear | own |
| g1 | detector inverted (`pd_same` = change) | ps; lat |
| g2 | `phb_next` from the receiver (`lk & pd_same`) | fly (in `d18_stop`) |
| g3 | locks after 12 matches, not 13 | fly |
| g4 | never unlocks | fly; dead |
| g5 | re-anchored one clock off (`ph` ← 0) | fly |
| g6 | flywheel period 4 | fly; lock |
| g7 | `guard_on` ignores `!cpu_ready` | gd |
| g8 | `guard_on` while unlocked | gd; never-lock `guard_on` |
| g9 | `ev_unlock` while unlocked | gd |
| g10 | receiver pair skips a stage | ps; lat |
| g11 | `good` not cleared on a mismatch | fly; lock |
| g12 | `pd_tog` toggled on `clk_sys` | ps; lat |
| g13 | `phb_next` one clock late (the edge after phase B) | fly; phb |
| g14 | `good` not cleared by a mismatch once saturated | fly (in `d18_stop`) |

**The guard's acceptance checks alone.** The "fly" and "gd" checks restate 8.1's code. To see what the physical checks catch on their own (lat, phb, lock, dead, never locked), the guard mutants were re-run with `GPLUS=+restate=0`. Result: **8 of 14** (`runs_D/mut_phys.log`):

- **Caught:** g1, g4, g6, g8, g10, g11, g12, g13. g4 and g8 were survivors before the `d18_stop` lane and the never-lock `guard_on` check were added; those two checks were written for them.
- **Survivors:** rules the design states rather than physics.
  - g2: `phb_next` from the receiver equals the flywheel's in every settled clock and differs only inside a move's transient. 8.1 asks for the flywheel because `pd_rx` is the asynchronously sampled flop.
  - g3, g5: the exact lock count and re-anchor value; both still lock within 24 clocks.
  - g7, g9: the definitions of `guard_on` and of the `ev_unlock` tap.
  - g14: a lock after one match once a lock has been seen, which matters only if `clk_arm` changes frequency.

## 5. Area and timing

Quartus 21.1 Standard, 5CEBA4F23C8, `ap_core.qsf`'s settings, `daria_fe_map.sh … --fit` under `flock /tmp/daria_quartus.lock`. The stub baseline is the step-0 stub (commit 8fee22a) in the same script: the arbiter's measured here (renamed copy, since removed), the guard's from interfaces.md section 8.

| Probe | ALMs needed | ALMs placed − [B] | Stub (needed / placed − [B]) | **L-4 measure** | Registers | M10K | Setup slack |
|---|---|---|---|---|---|---|---|
| `daria_fe_arb` | 355 | 108 | 247 / 1 | **107** (108 by "needed") | 1 (`crb_use`) | 0 | none: no register-to-register path (inputs are virtual pins) |
| `tb_fe_arb_probe` (registered inputs and outputs; timing only) | 349 | 103 | — | — | 438 | 0 | `clk_sys` **+62.69 ns** (multicorner worst; path about 7.1 ns) |
| `daria_fe_guard` | 10 | 6 | 4 / 0 | **6** (6 by "needed") | 10 (13 after the fitter's duplication) | 0 | `clk_sys` +67.10 ns, `clk_arm` +23.97 ns |

**Against the design.**

- The arbiter is within 10.3's gate (≤ 130) and just under 10.1's estimate (110-140).
- The guard is under 10.1's 15-20.
- Quartus removed every bench-only tap: its 10036 warnings name exactly `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr`, `a_owner` and `ev_unlock`. The per-cycle flags went with them, which leaves the arbiter one register.
- The arbiter's own depth is about 7.1 ns register to register. That covers `sel_up`/`guard_on`/`phb_next` → `aud_take` → owner → R address, the arbiter's part of 10.4's first critical path (18-24 ns estimated in total).

**The guard's attributes** (8.2), from the fit's reports:

- `pd_tog` and `pd_rx` are "protected by synthesis attribute" and "not to be touched by netlist optimizations".
- `SYNCHRONIZER_IDENTIFICATION OFF` is applied to `pd_rx`, and no synchronizer chain is reported.
- Physical synthesis duplicated only `ph[0]`, `ph[1]` and `good[1]` (routability). **`pd_rx` and `pd_tog` are neither duplicated nor retimed.**

The probes' `db/` were deleted by the script.

## 6. Open issues and observations

| # | Issue |
|---|---|
| O-1 | **`a_p32_late` under a console reset** (lane A's O-1, addressed to lane D). The assertion is 3.6's formula `k[3] & op.(cdsw\|cdsp) & !(p32_q \| rdP) & !guard_on`. `u_core` clears `rdP`/`p32_q` on `rst_fe`, so a `cart_reset` between `k[1]` and `k[3]` of a DSWRITE/DSPTR cycle fires it, with the 6507 in reset.<br>`u_arb`'s frozen ports carry no reset, and the assertion is simulation-only (Quartus removes it). **Lane D's recommendation: no port.** The stage-1 bench (`fe_taps.svh`/`fe_shadow.svh`, lane E) should classify an `a_p32_late` in a 6507 cycle during which `rst_fe` (or `cart_reset`) was high as a reset artifact. The other assertions are not affected: `a_wb_late` reads `wb_v`, which `rst_fe` clears; the per-cycle flags restart at the next `k[0]`. For the lead |
| O-2 | **A phase move can leave the detector locked on the old phase for up to 2 clocks.** This is inherent in a period-3 predictor: the move shows at the first edge whose `pd_same` differs from the prediction. Measured as "stale ≤ 2" in `d18_mvA/B` (0 in `d18_stop`, where the stop itself unlocks within 3 clocks). In that window one audio read could register on a non-phase-B edge while `guard_on`.<br>On the Pocket a phase move means a PLL relock of both clocks, which is not expected while the core runs. Observation, no change |
| O-3 | **5× and 1× can lock briefly if `clk_arm` has per-edge jitter near the `clk_sys` edges.** With a `clk_arm` edge inside the [1, 6] ns window before every `clk_sys` edge and a random delay per launch, `x5_amb`/`x1_amb` show 80-137 locked clocks per 10^6 (longest consistent run 18-19).<br>Mode A's clocks have no such jitter, and its deterministic phases never lock (`x5_o0`, `x5_o3`, `x1`). So `det_lock_a` stays 0 as long as the stage-1 bench does not add random per-edge delays to `clk_arm` close to `clk_sys` edges. Note for lane E. Hardware never runs 5× |
| O-4 | **The 8.2 SDC pair is not timed by the block probe.** `daria_fe_map.sh` cuts `clk_sys`/`clk_arm` as asynchronous clock groups, which take precedence over `set_max_delay`/`set_min_delay`. Step 7's STA check (8.2: one path each way, meeting 6/1 ns) remains.<br>What the probe does show: the register names the patterns need exist under `daria_fe_guard`, and `daria_fe.sv` names the instance `u_guard`, as the pattern `*\|daria_fe_guard:u_guard\|pd_tog` expects. The attributes hold (section 5) |
| O-5 | **Requests reach `u_arb` ungated** (interfaces.md 10 item 3): `u_core`'s `cr_fix`/`cr_p32`, with `ev_guard_sup = guard_on & (cr_fix \| cr_p32)`, and `u_copy`'s `cp_req`, which reads no `guard_on`, as of this writing. `a_guard_wr` and the suppression therefore see them. Lane C's files are still being finished; the integration bench should keep `a_guard_wr` and `a_guard_core` at 0 |

**Port requests.** None.

## 7. The SDC lines of design 8.2 (for step 7; not in `core_constraints.sdc` yet)

Beside DC 7.3's ±20 ns `clk_sys`/`clk_arm` exceptions in `src/fpga/core/core_constraints.sdc`:

```tcl
# DARIA front end: the shared-edge phase detector (docs/DARIA_CORE.md; daria_fe_guard.sv).
# One clk_arm toggle into one clk_sys flop. 6 ns: a toggle launched 8.73 ns before an edge
# is always caught there. 1 ns: the toggle launched on the shared edge is never caught on it.
set_max_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 6.000
set_min_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 1.000
```

- **Precedence.** Both lines are more specific than the clock-to-clock pair, so they take precedence. They need the ±20 ns exceptions, **not** a clock-group cut, between the two clocks (O-4).
- **Margin.** 6 ns < 8.73 ns − setup − skew.
- **No QSF lines.** `PRESERVE_REGISTER` on `pd_tog` and `pd_rx`, and `SYNCHRONIZER_IDENTIFICATION OFF` on `pd_rx`, are RTL attributes in `daria_fe_guard.sv`.
- **The step-7 STA check:**
  - `report_timing -from pd_tog -to pd_rx` lists exactly one path for setup and one for hold, meeting 6 / 1 ns;
  - the fitter's register report shows `pd_rx` neither duplicated nor retimed;
  - the clock-network skew on that path is read off the report.

## 8. Reproducing

```sh
sim/bupchip/daria/fe_unit/run_unit.sh arb guard                       # defaults: 2e6 clocks; 1e6 edges x 17 lanes
POISON=1 sim/bupchip/daria/fe_unit/run_unit.sh arb guard
sim/bupchip/daria/fe_unit/run_unit.sh arb +seed=12 +pg_seed=12 +cycles=10000000
sim/bupchip/daria/fe_unit/run_unit.sh arb +seed=103 +pg_seed=203 +pg_mode=short
sim/bupchip/daria/fe_unit/run_unit.sh guard +seed=2
sim/bupchip/daria/fe_unit/tb_fe_arb_mut.sh                            # section 4 (about 15 minutes)
GPLUS=+restate=0 sim/bupchip/daria/fe_unit/tb_fe_arb_mut.sh g1 g2 g3 g4 g5 g6 g7 g8 g9 g10 g11 g12 g13 g14
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_arb --fit
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_guard --fit
EXTRA_SRCS=sim/bupchip/daria/fe_unit/tb_fe_arb_probe.v \
  flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh tb_fe_arb_probe --fit
```

**Logs** of the runs above are in `sim/work/bupchip/daria/fe_unit/runs_D/`:

- `arb_*`: `_p` = `POISON=1`;
- `guard_s1..3`;
- `mut_all`, `mut_guard`, `mut_phys`.

`tb_fe_stub` (the step-0 tap check) passes with lane D's bodies in the tree.
