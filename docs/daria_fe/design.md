# `daria_fe`: the micro-architecture (DARIA step 6, final)

This is the front end that DARIA builds and verifies. It is the 6507 side of DPC+ and of the CDF family (CDF0, CDF1, CDFJ, CDFJ+), with:

- its audio engine;
- its RAM image (F6);
- the DPC+ copy/fill engine;
- its half of the call port;
- the shared-edge guard.

BUS and ELF stay bad-game screens (D2).

**Frozen interfaces.** `docs/daria_fe/interfaces.md` records the ports as built at step 0. Where it differs from 1.3, 1.4, 1.7 or 4.1 below (`dec_t` is 38 bits, `rdl` 4 bits, a few added ports), it is authoritative (its 11.4).

**How it was made.** It is design C, "simple" (`docs/daria_fe/alternatives/simple.md`), taken as the base. Every fatal flaw and defect the three judges found in simple is fixed, and grafts from "exact" and "lean" are added where they add no risk. Appendix A traces every finding and every graft.

**Decisions.** D1-D10 are the owner's and lead's decisions, quoted where used. AMPLITUDE and NOTE are **exact** (the D1 option). The cost and risk of that choice are argued in 5.1 and 10.

**Sources.**

- `docs/daria_fe/spec/{critic,design_inputs,bench,dpcplus,cdf,audio,glue,bus}.md`, cited as CR, DI, BEN, DPC, CDF, AUD, GL, BU.
- The three designs and the three judges' reports.
- `docs/DARIA_CORE.md` (DC).
- `docs/daria_fe/bench_stage0.md` (S0).
- Repository RTL:
  - `core/bupchip/{daria_mem,daria_call,bupchip_pocket,bup_capture}.sv`;
  - `core/atari7800_pocket.sv`;
  - `core/core_constraints.sdc`.
- Upstream RTL (`rtl/` = `src/fpga/mister/rtl/`, MIT), re-read for this document:
  - `mapper_dpcplus.sv` and `mapper_cdf.sv`, in full;
  - `arm_mapper_audio.sv`, in full;
  - `cdf_fastjump_table.sv`.

Nothing was run, and no repository file was changed.

---

## 0. Summary

### 0.1 What won, what was fixed, what was grafted

**The base.** The scores were exact 19, simple 20, lean 20. Between the two tied designs, simple was taken:

- The risk judge chose simple, and the exactness judge chose "exact's architecture in simple's style". Simple already is that, apart from the fixes below.
- Lean was the hardware judge's choice, on area. Its audio becomes the specified area fallback (10.3), not the base. Its AMPLITUDE can never be checked in lockstep, and its abort/restart scheduler is the hardest piece of the three to debug.

What simple brings:

- **Small blocks with no shared datapath register** (sequencer, core, audio, call, copy/F6, guard). Each can be unit-tested against its upstream counterpart.
- **An audio engine that replicates `arm_mapper_audio` clock for clock.** Its grant comes from a replica of upstream's RAM select, so it is checked against upstream on every clock.
- **A six-word ring** that holds the payload, stages the returns and swaps the payload for an RMW call.
- **One arbiter**, `fe_arb`, which owns every memory-port mux and every collision assertion.

**Fixes to simple** (every judge finding; Appendix A):

| # | Finding | Fix here |
|---|---|---|
| F1 | **Fatal (all three judges):** a short phase 1 (C < E0+6) dropped RAM and state-RAM write-backs through `late`. State then diverged for the rest of the run. | `late` is gone. Every action a commit causes **waits for its data** (exact's `rdy` rule, 2.3):<br>- "at-commit" actions fire at C if their data is ready, else in the first clock it is;<br>- "post" actions fire in the clock after C if ready, else when ready.<br>For C = E0+6 the result is the original schedule, edge for edge. For a short phase 1, state stays exact; only `fe_do` and Q26 are counted (`short_phase1`). |
| F2 | `rst_dpc`/`rst_cdf` both drove the shared `bank`/`fpend`. As written this was contradictory and would kill DPC+ banking. | One front-end reset, `rst_fe = cart_reset \| !fe_on \| scheme != scheme_q`, with reset values chosen by the live scheme. The audio replica is reset by `cart_reset` only. |
| F3 | Short phase: fixed reads after an early commit, with `sel_up` already dropped, could collide with an audio grant. | `aud_take` includes `!fix_eff`, the core's fixed use (exact's `!u_fe`). `grant_steal` is asserted 0 outside a short-phase cycle. |
| F4 | The CALLFUNCTION 1/2 service took stale clamps at C = E0+2. | The service latches at max(C, E0+4). The clamps are applied at run time by the engine (lean's stop tests). |
| F5 | The merge landed at M+7 (`merge_race` window of 7 clocks). | The first return read is issued in the clock in which the synchronised `ret_tog` change is first seen (exact). Returns are read in six consecutive clocks, and the merge applies atomically at **M_fe = M+6**. **Ticks in (M, M_fe] are deferred and added at M_fe+1 with the returned frequency** (the exactness judge's one-tick correction). Counters and frequencies are therefore exact at every tick without the bench hook. What is left is `merge_amp`: one AMPLITUDE value of a refresh dispatched inside the window. It is counted and self-healing. |
| F6 | Missing classes: `pre_lock` (BIOS path), `live_override`, `size_over32k`. | Added (9.5). |
| F7 | The replica was written as a `case` FSM, the style the study measured at +34% ALMs. | Rewritten as per-register tables under D10 (5.3). |
| F8 | The receiver flop `st` shared its name with the call FSM. | Renamed `pd_rx` (toggle `pd_tog`). |
| F9 | The ring's ALMs were underestimated (3:1 on 192 bits), and so was the audio. | Re-estimated (10.1). There is a probe gate and fallback order (10.3). |
| F10 | The P32 read was not guard-aligned (it is unreachable). | It is suppressed under `guard_on` with the other core requests (D4: "speculative 6507-side reads may be suppressed"). |
| F11 | F6 counted 64 clocks itself. | F6 starts at the fall of the wrapper's exported `cart_win` (= `bup_capture`'s `c_close`). In mode A the bench emulates `cart_win`. |

**Grafts.**

From exact:

- the early F8 read;
- rdy-gated writes;
- the single `rst_fe`;
- `!u_fe` in the grant;
- the 4-bit `pptr` counting to 8;
- the DPC+ RMW launch at M;
- the register-reference format;
- the A1/A2/A3 every-clock oracles;
- the full-state `fe_deposit_audio` resync;
- the class list;
- the local digital-sample hit timing (R+4);
- the orphaned `sample_busy`.

From lean:

- the strict guard: no non-F6 cart RAM write, and core reads suppressed;
- a **registered** flywheel `phb_next`;
- run-time service clamps;
- assertions `fpjr`, `guard_wr`, `guard_sub`, `ret_unasked`;
- the random phase-stream unit bench and the tick-placement sweep;
- the state-RAM audio as the documented fallback.

From the hardware judge:

- lock after 12 consistent edges (≥ 9 wanted);
- `-nowarn` on the SDC patterns;
- parked addresses for suppressed reads;
- `wb_v` cleared on reset.

From the exactness judge: the one-tick merge correction, implemented as deferral.

Kept from simple:

- `d_in` = `write_DB`;
- the ROM mirror on port B;
- the six-word ring;
- `fe_arb`;
- the yielding P32 read;
- the word-wide fill;
- the D4-literal guard;
- the detector attributes.

### 0.2 Exactness in mode A (D1)

| D1 item | Level here |
|---|---|
| `d_out & oe` at every non-hidden latch (tb_daria's 1-clock ROM) | Exact. Counted: `short_phase1` (C < E0+6), plus the AMPLITUDE classes below; `rst_release` (that cycle's latch) |
| Every scheme register after every 6507 cycle | Exact. Counted: CDF Q26 inside `short_phase1`; `rst_release` (the DPC+ fetcher or parameter state the dropped action would have written) |
| Cart RAM after init, after each 6507 write, at each call start and each frame | Exact. Counted: `tbl_alias` (CDFJ+ DSWRITE into its own tables), `short_image`, `live_override`; `rst_release` (the words the dropped action would have written: a PUSH/WRITE byte, the DSWRITE byte, P32) |
| DPC+ copy/fill results | Exact, including the RMW pair. Counted: `rst_release` (a CALLFUNCTION 1/2 in that cycle: `daria_fe` makes no copy or fill for it) |
| Call payloads, in order; seeds by logical ordering | Exact: ring captured at L = C+1, so `seed_race` = 0 by construction |
| Audio ticks on the same `clk_sys` edge | Exact (same Bresenham, same reset) |
| Per-tick counters and frequencies | Exact. `merge_race` must be 0 unless the bench had to hold `ret_tog` back (`ret_late`) |
| NOTE | **Exact** (same capture edge, same word) |
| AMPLITUDE | **Exact.** Counted: `merge_amp`, `dig_rom_lag`, `svc_audio_race`, `pause_lane`, `pre_lock`, `short_phase1` |

With `+fe_merge_hook=1`, `merge_amp` is 0 as well. A run on an image without digital audio, DPC+ services, pause or RSYNC then has no counted AMPLITUDE class at all.

`rst_release` (9.5) is the one exception from a console reset: a reset released inside a 6507 cycle that commits an action waiting for a ready flag, so late that the flag is 0 at C and stays 0 to the cycle's end (9.5 gives the edges). `daria_fe` drops the action (2.3), upstream performs it. It is not reachable from 6507 code: a 6502 leaves reset through its reset sequence, and none of its reads is such a register (lanes/E3_rtl_issues.md, issue 1; lanes/F1_fixes.md 1).

### 0.3 Size

| | |
|---|---|
| ALMs | **1,255-1,445, mid about 1,350** [E] |
| FF | about 1,230 |
| New M10K | none. It uses `daria_mem`'s FE ROM, cart RAM and state RAM |
| Device | others at 14,022-14,282 put it at 82.7-85.1%, mid 83.2-84.6%, against the 84% gate (15,523) |

The owner accepts more area for correctness, but D10 asks for headroom. So the plan has:

- a probe gate per block before integration;
- an ordered lever list;
- a drop-in fallback (`daria_fe_audio_lean`) with fixed ports.

All three are in 10.3.

### 0.4 Conventions

- **E0** is the `clk_sys` edge at which `pclk1` is sampled high (pre-edge), and **E0+n** is the n-th edge after it.
- **C** is the commit edge: the edge at which `access && a_in[12]` is sampled high. It is E0+6 nominally.
- **X@n** means port X's address is presented in the clock (E0+n−1, E0+n), registers at E0+n, and its q is valid in (E0+n, E0+n+1). **X@C+n** is the same, relative to C.
- **Ports:**

  | Port | Memory |
  |---|---|
  | **B** | front-end ROM port B (the mirror) |
  | **A** | front-end ROM port A |
  | **R** | cart RAM port B |
  | **S** | state RAM port B |

- **"loaded @n"**: the register's enable is high pre-edge at E0+n, so the new value is visible from (E0+n, E0+n+1).
- **Sequence flags:**

  | Flag | High during |
  |---|---|
  | `k[j]` | (E0+j, E0+j+1) for j < 7 |
  | `k[7]` | from E0+7 until the next E0 (it saturates) |
  | `c[j]` | (C+j, C+j+1) for j < 3 |
  | `c[3]` | from C+3 on |

- **Call edges:**
  - L = C+1, upstream's accept edge.
  - S1 and S2 are the edges at which the two `ret_tog` flops load.
  - X = S3, upstream's busy fall.
  - M = X+1, upstream's merge.
  - M_fe = X+7, this design's merge.
- Everything is on `clk_sys`, except `fe_guard`'s one toggle flop (`clk_arm`) and the wrapper side of the sample port.
- File names below are relative to the repository root. `BUP/` is `src/fpga/core/bupchip/`, and `D/` is `sim/bupchip/daria/`.

---

## 1. Modules, files and ports

### 1.1 Hierarchy and files

```
daria_fe            BUP/daria_fe.sv        top: ports, scheme decode, rst_fe, fe_oe
├─ u_seq            BUP/daria_fe_seq.sv    k, c, ph2, ph1_open, rel_ok, commit
├─ u_core           BUP/daria_fe_core.sv   op latch, W + adder, fe_do, scheme state,
│  └─ u_dec         BUP/daria_fe_dec.sv    (combinational decode + sel_up)
│                                          commit actions (rdy rule), wbuf, P32,
│                                          service latch, NOTE/wave/mode outputs
├─ u_audio          BUP/daria_fe_audio.sv  tick, counters, frequencies, ring, replica
│                                          FSM, AMPLITUDE, sample client
├─ u_call           BUP/daria_fe_call.sv   post / flip / wait / read / apply / release
├─ u_copy           BUP/daria_fe_copy.sv   load tracking, F6, state-RAM clear,
│                                          init_busy, copy/fill engine, arm_dma_busy
├─ u_arb            BUP/daria_fe_arb.sv    owners and muxes of A, B, R, S; aud_take;
│                                          crb_use; assertions
└─ u_guard          BUP/daria_fe_guard.sv  phase detector (pd_tog, pd_rx), flywheel,
                                           guard_on
                    BUP/daria_fe_pkg.sv    dec_t, op-class encoding, constants
```

Every file is MIT-licensed, uses `` `default_nettype none ``, has no output-port initialisers (BEN Q9), and is written under D10:

- one load enable and at most a 4-input data mux per register;
- one-hot selects with AND-OR muxes;
- every stage registered (M10K q → logic → M10K address or register).

### 1.2 `daria_fe` ports

Everything is `clk_sys` unless noted. "reg" means the output comes straight from a flip-flop.

| Port | Dir | W | Meaning |
|---|---|---|---|
| `clk_sys` | in | 1 | 14.318 MHz |
| `clk_arm` | in | 1 | Feeds only `u_guard.pd_tog`. On the Pocket it is DARIA's ÷18. In mode A it is the bench's upstream `clk_arm` (5×), and the detector then never locks |
| `cart_reset` | in | 1 | `effective_reset` (top.sv:255) |
| `pause` | in | 1 | `pause_core` |
| `a_in` | in | 13 | `{AB[12] & bios_en_b, AB[11:0]}`, cart2600's `a_in` |
| `d_in` | in | 8 | **`write_DB`** (the CPU's DOR). Used only on write cycles, where it equals `cart_din`. It keeps the SDRAM-sourced `read_DB` out of the input cone (D10) |
| `rw` | in | 1 | `RW` |
| `pclk1`, `pclk0` | in | 1 each | `phi1_ce`, `phi2_ce` (top.sv:1420-1435) |
| `access` | in | 1 | `mapper_phi2 && arm_driver_run` (cart2600.sv:247) |
| `scheme` | in | 6 | `force_bs` with the override. 21 = DPC+, 23 = CDF |
| `revision` | in | 3 | `mapper_revision`. Bit 0 is DPC+'s `stable_fractional`; bits [1:0] are the CDF version |
| `cdf_ldx`, `cdf_ldy`, `fetch_off_en` | in | 1 each | detect2600 |
| `fetch_off` | in | 8 | detect2600 |
| `cdfj_entry`, `cdfj_stack` | in | 32 each | detect2600 |
| `audio_size_addr` | in | 16 | detect2600 |
| `rom_size` | in | 32 | `cart_size` (top.sv:1148) |
| `ram32` | in | 1 | `mapper_ram_size == 32768` |
| `load_start`, `load_end` | in | 1 each | one-clock pulses (`mapper_load_*`) |
| `cart_win` | in | 1 | **New wrapper output**: `bup_capture.cart_win`. Its fall is `c_close` (load_end + 63). Mode A: emulated by the bench |
| `cpu_ready` | in | 1 | Pocket: `daria_ready`. Mode A: `arm_online_sync2 && shadow_ready_sync2 && !effective_reset`, without `call_busy` (D5, CR 8) |
| `ret_tog` | in | 1 | `clk_arm` domain. Two `clk_sys` flops inside `u_call` |
| `call_tog` | out | 1 | reg |
| `smp_req` | out | 1 | reg. Digital-sample request toggle |
| `smp_addr` | out | 19 | reg. Image byte offset, held from the toggle to the answer |
| `smp_ack` | in | 1 | Answer toggle from the wrapper's domain. Two `clk_sys` flops inside |
| `smp_data` | in | 8 | Held by the wrapper from before the ack flip until the next request |
| `fe_do` | out | 8 | reg. `direct_do` for BANKDPCP and BANKCDF |
| `fe_oe` | out | 1 | `a_in[12]`, combinational, as every mapper's `oe` |
| `arm_call_busy`, `arm_dma_busy` | out | 1 each | reg. The stall terms (top.sv:306-307) |
| `init_busy` | out | 1 | reg. Into atari7800_pocket's reset OR (and `.loading`) |
| `fea_addr` | out | 13 | FE ROM port A word address (`daria_mem` overrides it with `cap_we`) |
| `fea_q` | in | 32 | |
| `feb_addr` | out | 13 | FE ROM port B: the mirror |
| `feb_q` | in | 32 | |
| `crb_addr`, `crb_we`, `crb_be`, `crb_wd` | out | 13, 1, 4, 32 | cart RAM port B |
| `crb_q` | in | 32 | |
| `stb_addr`, `stb_we`, `stb_be`, `stb_wd` | out | 8, 1, 4, 32 | state RAM port B (`stb_be` is already in `daria_mem`, :159, :203) |
| `stb_q` | in | 32 | |
| `hk_en` | in | 1 | Bench merge hook. **Tied 0 in synthesis**; constant propagation removes the hook paths |
| `hk_stb` | in | 1 | Bench: upstream's `call_done`, high in (X, X+1) |
| `hk_ret` | in | 192 | Bench: `{f2, f1, f0, c2, c1, c0}`, upstream's `*_return` |

The memory address, enable and data outputs are combinational from registers or M10K q, as D10 allows. `fe_oe` is combinational, as upstream's is.

### 1.3 `daria_fe_pkg`

```systemverilog
package daria_fe_pkg;
  // One-hot op class (NONE = all zero). The DPC+ classes are 0..11, the CDF classes 12..17.
  typedef struct packed {
    logic rom;   // read, not substituted (both schemes)
    logic rrnd;  // DPC+ fn 0, ix != 5 (random, 0s)
    logic amp;   // DPC+ fn 0 ix 5; CDF amplitude fetch
    logic rdat;  // DPC+ fn 1..3 (DATA, DATAW, FRACDATA)
    logic rflg;  // DPC+ fn 4
    logic dfld;  // DPC+ write g in {0,1,2,3,4,5,8} (field bytes)
    logic dpw;   // DPC+ write g in {7,10} (PUSH, WRITE)
    logic dpar;  // DPC+ $1059
    logic dcf;   // DPC+ $105A
    logic dmisc; // DPC+ g6 ix {0,5,6,7}, g9 (FASTFETCH, WAVEFORM, RRESET/RWRITE, NOTE)
    logic cfet;  // CDF fetch substitution, not amplitude, not jump
    logic cjmp;  // CDF jump substitution
    logic cdsw;  // CDF $1FF0 write
    logic cdsp;  // CDF $1FF1 write
    logic cmode; // CDF $1FF2 write
    logic ccall; // CDF $1FF3 write
  } opc_t;
  typedef struct packed {
    opc_t       c;
    logic       hot;     // hotspot attribute (read or write, not substituted)
    logic [2:0] ix;      // DPC+ register index
    logic [2:0] fn;      // DPC+ read function
    logic [3:0] g;       // DPC+ write group ((a - $028) >> 3)
    logic [5:0] idx;     // CDF table index (fetch: normalised operand; jump: stream)
    logic       arms;    // CDF arming byte ($A9, or $A2/$A0 on CDFJ+ with ldx/ldy)
    logic       b4c;     // romb == $4C
    logic       jok;     // jump lookahead (formed in k[1] by fe_core, 2.2)
    logic       romb0;   // romb[0] (CDFJ jump stream select)
    logic       a9;      // romb == $A9 (DPC+ arming)
  } dec_t;               // 16 + 26 = 42 bits
  localparam logic [23:0] TICK_TH   = 24'd14_298_182;   // CLK_RATE - AUDIO_RATE
  localparam logic [23:0] TICK_WRAP = 24'h25_D3BA;      // AUDIO_RATE - CLK_RATE mod 2^24
  localparam logic [23:0] TICK_STEP = 24'd20_000;
endpackage
```

### 1.4 Submodule ports (the fixed interfaces)

Every signal is `clk_sys`. Widths are in brackets. "comb" means it is valid in the same clock as its inputs. "pulse" means it is high for exactly one clock. Requests and grants are combinational in the same clock (1.5).

**`daria_fe_seq`**

| Dir | Signals |
|---|---|
| in | `pclk1`, `pclk0`, `access`, `a12` (= `a_in[12]`) |
| out | `k[7:0]`, `c[3:0]`, `ph2` (all reg); `commit` (comb = `access & a12`); `ph1_open` (comb = `!ph2 & !pclk0`); `rel_ok` (comb = `(ph2 \| pclk0) & !pclk1`); `ev_short` (comb = `commit & !(k[5]\|k[6]\|k[7])`) |

**`daria_fe_dec`** (combinational; instantiated in `u_core`)

| Dir | Signals |
|---|---|
| in | `a_in[12:0]`, `rw`, `access`, `romb[7:0]`, `is_dpc`, `is_cdf`, `jplus`, `jrev`, `ldx`, `ldy`, `foff_en`, `foff[7:0]`, state `ff_en`, `fpend`, `fexp[12:0]`, `jr[1:0]`, `jexp[12:0]`, `jstream[5:0]`, `mode[7:0]` |
| out | `dec` (`dec_t`, `jok` = 0 here), `sel_up`, `rom_a[14:0]` |

**`daria_fe_core`**

| Dir | Signals |
|---|---|
| in | `rst_fe`; scheme `is_dpc`, `is_cdf`, `jplus`, `jrev`, `sf` (= `revision[0]`), `ldx`, `ldy`, `foff_en`, `foff[7:0]`; bus `a_in`, `d_in`, `rw`, `access`; seq `k`, `c`, `commit`, `ph1_open`, `ev_short`; q `fea_q`, `feb_q`, `crb_q`, `stb_q`; arb `aud_take`, `look_gnt`; `guard_on`; audio `amp_nx[7:0]`; copy `svc_take` (pulse: the engine took the latched service), `init_busy`; call `call_busy` |
| out, 6507 | `fe_do[7:0]` (reg) |
| out, decode | `sel_up` (comb), `feb_addr[12:0]` (comb = `rom_a[14:2]`) |
| out, R fixed | `cr_fix` (comb), `cr_fix_a[12:0]`, `cr_fix_we`, `cr_fix_be[3:0]`, `cr_fix_wd[31:0]`, `cr_fix_use` (a consumed read) |
| out, R yield | `cr_p32` (comb), `cr_p32_a[12:0]`; `cr_wb` (= `wb_v`), `cr_wb_a[12:0]`, `cr_wb_wd[31:0]` (= `W`) |
| in, R yield | `p32_gnt`, `wb_gnt` (from `u_arb`) |
| out, S | `cs_req`, `cs_a[7:0]`, `cs_we`, `cs_be[3:0]`, `cs_wd[31:0]` (DPC+ only; always granted, 3.2) |
| out, A | `look_req` (= `k[0] & is_cdf & !init_busy`), `look_a[12:0]` (= `rom_a[14:2] + 1`) |
| out, audio | `wave0..2[6:0]` (reg), `note_stb` (reg pulse in (C, C+1)), `note_v[1:0]`, `note_val[7:0]` (reg), `cdf_dig` (= `mode[7:4] == 0`) |
| out, call | `callfn` (comb pulse at C: a DPC+ $105A or CDF $1FF3 commit with `d_in` ∈ {FE, FF}) |
| out, copy | `svc_pend` (reg), `svc_hold` (= `svc_pend` or a deferred latch pending), `svc_fill`, `svc_src[16:0]`, `svc_dst[12:0]`, `svc_rem[7:0]`, `svc_val[7:0]` (reg); `dma_set` (comb pulse at C: a taken CALLFUNCTION 1/2) |
| out, taps | 1.7 |

**`daria_fe_audio`**

| Dir | Signals |
|---|---|
| in | `cart_reset`, `pause`, `fam[1:0]` (1 DPC+, 3 CDF, 0 otherwise; live), `rev[1:0]`, `rom_size[31:0]`, `ram32`, `asz[15:0]` (`audio_size_addr`), `cdf_dig`, `wave0..2`, `note_stb`, `note_v`, `note_val` |
| in, call | `cp_cap`, `cp_rot`, `cp_shin`, `cp_cmp`, `cp_apply`, `mwin` (pulses or levels from `u_call`, 6) |
| in, hook | `hk_en`, `hk_stb`, `hk_ret[191:0]` |
| out, R | `aud_issue` (comb), `aud_addr[14:0]` (comb; byte address, `u_arb` uses [14:2]) |
| in, R | `aud_take` (comb, from `u_arb`), `crb_q` |
| in, S | `stb_q` (return words, read by `u_call`) |
| out, A | `aud_a_req`, `aud_a_a[12:0]` |
| in, A | `aud_a_gnt`, `fea_q` |
| out, sample port | `smp_req`, `smp_addr[18:0]` (reg) |
| in, sample port | `smp_ack`, `smp_data[7:0]` |
| out | `amp_nx[7:0]` (comb: the value `amplitude` holds after this edge), `ring0[31:0]` (= `ring[0]`, to `u_call`) |
| out, taps | 1.7 |

**`daria_fe_call`**

| Dir | Signals |
|---|---|
| in | `cart_reset`, `is_dpc`, `is_cdf`, `jplus`, `cdfj_entry`, `cdfj_stack`, `callfn`, `cpu_ready`, `ret_tog` (async), `rel_ok`, `ring0[31:0]`, `hk_en`, `hk_stb` |
| out, S | `cl_req`, `cl_a[7:0]`, `cl_we`, `cl_wd[31:0]` (be = F) |
| in, S | `cl_gnt` |
| out, audio | `cp_cap`, `cp_rot`, `cp_shin`, `cp_cmp`, `cp_apply` (pulses), `mwin` (level) |
| out | `call_tog`, `arm_call_busy` (reg), `call_win` (comb from the state) |
| out, taps | `st`, `cnum[7:0]`, `pend2`, `pend_up`, `ret_seen`, `ev_rmw_call`, `ev_ret_unasked` |

**`daria_fe_copy`**

| Dir | Signals |
|---|---|
| in | `cart_reset`, `load_start`, `load_end`, `cart_win`, `is_dpc`, `is_cdf`, `ram32`, `rel_ok`, `guard_on`, the latched service (`svc_pend`, `svc_hold`, `svc_fill`, `svc_src`, `svc_dst`, `svc_rem`, `svc_val`), `dma_set` |
| out | `svc_take` (pulse), `init_busy` (reg), `arm_dma_busy` (reg), `f6_act` (reg), `rst_quiet` (reg: `cart_reset` high for ≥ 8 clocks) |
| out, R | `cp_req`, `cp_a[12:0]`, `cp_we`, `cp_be[3:0]`, `cp_wd[31:0]` |
| in, R | `cp_gnt` |
| out, S | `cz_req`, `cz_a[7:0]` (F6 clear: we = 1, be = F, data 0) |
| out, A | `ca_req`, `ca_a[12:0]` |
| in, A | `ca_gnt`, `fea_q` |
| out, taps | 1.7 |

**`daria_fe_arb`** (combinational except `crb_use` and the assertion pulses)

| Dir | Signals |
|---|---|
| in | every request group above; `sel_up`; `guard_on`; `phb_next`; `f6_act`; `ev_short`; `k[1]`, `k[3]`, `commit` (for the assertions) |
| out | `fea_addr`, `crb_*`, `stb_*` to the ports (`feb_addr` passes through from `u_core`); grants `aud_take`, `p32_gnt`, `wb_gnt`, `cp_gnt`, `cl_gnt`, `look_gnt`, `aud_a_gnt`, `ca_gnt`; `crb_use` (reg); owner taps; assertion pulses (3.6) |

**`daria_fe_guard`**

| Dir | Signals |
|---|---|
| in | `clk_sys`, `clk_arm`, `call_win`, `cpu_ready` |
| out | `locked`, `phb_next` (both reg-derived), `guard_on` (comb = `locked & (call_win \| !cpu_ready)`) |
| out, taps | `pd_same`, `ph[1:0]`, `good[3:0]`, `ev_unlock` |

### 1.5 The cycle contract between modules

These rules let each module be written and unit-tested alone.

1. **Request and grant in the same clock.** A requester drives its request, address and data combinationally in clock (n−1, n), from registers or from q. `u_arb` returns the grant combinationally in the same clock. The M10K registers the winner at edge n.
2. **Data one clock later.** The read result (`*_q`) is valid in (n, n+1). The requester either registers it at n+1 or uses it combinationally for its next M10K address in (n, n+1); that is one stage.
3. **No q after a partial write on the same port in the next clock.** No module consumes q in the clock after its own partial-byte-enable write to that port. `NEW_DATA_NO_NBE_READ` is never relied on (DI 2.2).
4. **Fixed users are always granted.**
   - The core's fixed R and S users are always granted, unless `f6_act` (never true while the 6507 runs) or `guard_on` (they are then suppressed, 3.5).
   - The audio's ISSUE states hold their request until `aud_take`.
   - Yielding users (P32, wbuf, copy, call) retry each clock until granted.
5. **Strobes are one-clock pulses**, sampled at the edge that ends their clock:
   - `note_stb`, `callfn`, `dma_set`, `svc_take`;
   - `cp_cap`, `cp_rot`, `cp_shin`, `cp_cmp`, `cp_apply`.

   `mwin` is a level.
6. **Who registers what:**
   - `u_core` owns all 6507-side state, W, `wb_v`, the P32 flag and the latched service.
   - `u_audio` owns counters, frequencies, the ring and the replica.
   - `u_call` owns `call_tog`, `arm_call_busy`, `ret_seen` and the FSM.
   - `u_copy` owns `init_busy`, `arm_dma_busy` and F6.
   - `u_guard` owns the detector.
   - `u_arb` owns no state except `crb_use`.
7. **Resets.**
   - `u_core` uses `rst_fe`.
   - `u_audio`, `u_call` and `u_copy` use `cart_reset`. The sample client and `u_copy`'s load tracking are not reset by it (5.7, 7.1).
   - `u_seq` and `u_guard` have no reset; they are power-up initialised.

### 1.6 Outside `daria_fe` (step 7 wiring; not this module's files)

- **`top.sv` `POCKET_DARIA` group.**
  - Out: `a_in`, `write_DB` (as `d_in`), `RW`, `pclk1`, `pclk0`, `access`, `effective_reset`, `pause_core` and the detect2600 results.
  - In: `arm_call_busy`, `arm_dma_busy`, replacing upstream's at :306-307.
- **`cart2600.sv` `NO_ARM_MAPPER` block,** for BANKDPCP and BANKCDF:
  - `direct_do = fe_do`, `flags_out = 16'h1`, `out_en = {8{fe_oe}}`;
  - `rom_addr` and the `ram_*` outputs idle;
  - `is_bad_game` keeps BANKELF and BANKBUS only;
  - `mapper_init_busy` stays 0.
- **`atari7800_pocket.sv`.**
  - Instantiates `daria_fe` beside the BupChip wrapper, on its `daria_crb_*`, `daria_stb_*`, `daria_fea_*`, `daria_feb_*`, `daria_call_tog`, `daria_ret_tog`, `daria_ready` and `daria_ram32` ports (bupchip_pocket.sv:167-188).
  - ORs `daria_init_busy` into the `reset` register at :169-171 and into `.loading` at :905 (D6: straight into the reset, not through `mapper_init_busy`).
- **`bupchip_pocket.sv`.**
  - A new output `daria_cart_win = cap_cart_win`.
  - The sample-port requester (5.7): `clk_arm`, beside the asset cache.
- **`core_constraints.sdc`:** the two guard lines (8.2), beside the DARIA ±20 ns clock exceptions of DC 7.3.

### 1.7 Bench taps (`fe_taps.svh`, hierarchical and read-only; the RTL keeps these names)

| Group | Taps |
|---|---|
| seq | `u_fe.u_seq.k`, `.c`, `.ph2`; `u_fe.u_seq.ev_short` |
| core, both | `u_fe.u_core.op`, `.bank`, `.fpend`, `.W`, `.wb_v`, `.wb_a`, `.p32_in`, `.sel_up`, `.pend_s`, `.pend_r`, `.pend_c`, `.rdW`, `.rdP`, `.rdS`; `.rcyc` (1 bit, bench and assertion only: 1 when some edge since the last `pclk1` had `rst_fe` high, that `pclk1` edge excluded; it masks `a_pend_late`, 2.3, lanes/F1_fixes.md 1) |
| core, DPC+ | `.ff_en`, `.rnd`, `.pptr` (4-bit, compare with `parameter_pointer` directly), `.wave[0:2]`, `.svc_pend`, `.svc_fill`, `.svc_src`, `.svc_dst`, `.svc_rem` (the requested p3; the bench forms upstream's clamped count, 7.3), `.svc_val`, `.note_stb`, `.note_v`, `.note_val` |
| core, CDF | `.mode`, `.fexp`, `.jr`, `.jexp`, `.jstream` |
| state RAM | words $00-$0F (w0 mask `FFFF0FFF`, w1 mask `FF0FFFFF`), word $10 (params 0-3), $F0-$FD |
| audio | `u_fe.u_audio.tick`, `.accum`, `.counter[0:2]`, `.freq[0:2]`, `.rc[0:2]`, `.ring[0:5]`, `.take`, `.tdef`, `.st` (one-hot), `.voice`, `.ssum`, `.wsh`, `.woff`, `.dig_addr`, `.dig_low`, `.dig_ram`, `.dig_smp`, `.rp` (refresh pending), `.np` (note pending), `.amplitude`, `.dispatch`, `.al`, `.busy_l`, `.busy_r` |
| call | `u_fe.u_call.st`, `.cnum`, `.pend2`, `.pend_up` (upstream's `call_pending` as it would read; 6.1), `.ret_seen`, `.call_busy` |
| copy | `u_fe.u_copy.f6_act`, `.f6_ph`, `.run`, `.fill`, `.src`, `.dst`, `.rem`, `.val`, `.init_busy`, `.dma_busy` |
| ports | `u_fe.u_arb.crb_use`, `.own_r`, `.own_s`, `.own_a` (one-hot per clock) |
| guard | `u_fe.u_guard.locked`, `.pd_same`, `.ph`, `.phb_next`, `.guard_on` |
| events (one-clock pulses) | `u_fe.u_seq.ev_short`, `u_fe.u_core.ev_tbl_alias`, `.ev_guard_sup`, `.ev_rmw_svc`, `u_fe.u_call.ev_rmw_call`, `.ev_ret_unasked`, `u_fe.u_audio.ev_size_hi`, `u_fe.u_arb.ev_grant_steal` |
| assertions (must stay 0) | `u_fe.u_arb.a_collide`, `.a_wb_late`, `.a_p32_late`, `.a_guard_core`, `.a_guard_wr`, `u_fe.u_core.a_fpjr`, `.a_pend_late`, `u_fe.u_audio.a_tdef2`, `u_fe.u_copy.a_f6_live` |

The deposit task (7.6 of `bench.md`) writes the audio registers above. Under `` `ifdef VERILATOR ``, those registers carry `/* verilator public_flat_rw */`, which is a comment to synthesis.

---
## 2. Timing

### 2.1 `daria_fe_seq`

```systemverilog
logic [7:0] k = 8'h80;  logic [3:0] c = 4'h8;  logic ph2 = 1'b0;     // power-up, no reset
always_ff @(posedge clk_sys) begin
    k   <= pclk1  ? 8'h01 : (k[7] ? k : {k[6:0], 1'b0});    // k[0] in (E0, E0+1); saturates
    c   <= commit ? 4'h1  : (c[3] ? c : {c[2:0], 1'b0});    // c[0] in (C, C+1);   saturates
    ph2 <= pclk1  ? 1'b0  : (pclk0 ? 1'b1 : ph2);           // D3's in_phase2
end
assign commit   = access & a12;                  // this edge is a cartridge commit (DPC §14.1)
assign ph1_open = !ph2 & !pclk0;                 // this edge is before the latch edge
assign rel_ok   = (ph2 | pclk0) & !pclk1;        // a busy may fall here: E0+6 ... E0+11
assign ev_short = commit & !(k[5] | k[6] | k[7]); // a commit before E0+6 (counted, never gating)
```

**Why `!pclk1` is in `rel_ok`.** `ph2` is still 1 pre-edge at the next E0. A busy falling there would leave RDY low at that E0 but the stall low at its E0+6, so the held address would be committed twice (DI 1.2, GL 7.5). `(ph2 | pclk0) & !pclk1` allows exactly E0+6 … E0+11, whatever the phase lengths, and also during a pause in phase 2 (CR 16).

**Phase lengths.**

- `k` restarts at every `pclk1` and saturates, so a stretched phase 1 waits in `k[7]` with every read done.
- `c` restarts at every commit.
- Phase 2 is 6 or 10 clocks, so all post-commit work, which ends by C+5 even in the worst short-phase case, finishes before the next E0 (≥ C+6).

### 2.2 The mirror, the decode, the op latch and `sel_up`

```systemverilog
// ROM address (image byte offset; always < $8000): DPC+ ≤ $6BFF, CDF ≤ $7FFF, CDFJ+ ≤ $77FF
rom_a    = (is_dpc ? 15'h0C00 : (jplus ? 15'h0800 : 15'h1000)) + {bank, 12'h000} + a_in[11:0];
feb_addr = rom_a[14:2];                       // every clock: the mirror of tb_daria's cart_q
always_ff lane_q <= rom_a[1:0];               // every clock
romb     = feb_q[8*lane_q +: 8];              // = upstream's rom_do in every clock (S0 §2)
```

**What `romb` shows.** In (E0, E0+1), `romb` is the byte at {current bank, previous `a_in`}: tb_daria's stale byte. From (E0+1, E0+2) on it is the true byte, and after a bank switch it is the new bank's byte. That is exactly `cart_q <= rom[cart_addr]` (CR 9). The MiSTer `sdram.sv` transients are out of scope (D1).

**The decode.** `daria_fe_dec` is combinational and transcribes `mapper_dpcplus.sv:226-254` and `mapper_cdf.sv:79-157`.

```systemverilog
// ---- DPC+ ----
d_reg  = rw & a_in[12] & (a_in[11:0] < 12'h028 | (ff_en & fpend & romb < 8'h28));  // register_read
d_rn   = (a_in[11:0] < 12'h028) ? a_in[5:0] : romb[5:0];                           // 6 bits (DPC §14.12)
d_ix   = d_rn[2:0];  d_fn = d_rn[5:3];
d_wreg = !rw & a_in[12] & a_in[11:0] >= 12'h028 & a_in[11:0] < 12'h080;
d_g    = (a_in[11:0] - 12'h028) >> 3;                                               // 0..10
d_hot  = a_in[12] & !d_reg & a_in[11:0] >= 12'hFF6 & a_in[11:0] <= 12'hFFB;
d_sel  = (d_reg & d_fn >= 1 & d_fn <= 3)
       | (!rw & a_in[12] & ((a_in[11:0] >= 12'h060 & a_in[11:0] < 12'h068) |
                             (a_in[11:0] >= 12'h078 & a_in[11:0] < 12'h080)));      // ram_sel (:136-158)
// ---- CDF (r = revision[1:0]; jplus = r == 3; jrev = r >= 2) ----
fast_mode = mode[3:0] == 0;   amp_s = jrev ? 6'd35 : 6'd34;
arms   = romb == 8'hA9 | (jplus & ldx & romb == 8'hA2) | (jplus & ldy & romb == 8'hA0);
in_rng = foff_en ? (romb >= foff & {1'b0, romb} <= {1'b0, foff} + amp_s) : romb <= {2'b0, amp_s};
norm   = foff_en ? romb - foff : romb;
amp_op = foff_en ? (amp_s + foff[5:0]) : amp_s;                                     // 6-bit
jvalid = (jr == 2 & (jrev ? romb[7:1] == 0 : romb == 0)) | (jr == 1 & romb == 0);
c_jmp  = rw & a_in[12] & jr != 0 & a_in == jexp & jvalid;
c_fet  = rw & a_in[12] & fast_mode & fpend & a_in == fexp & in_rng;
c_sub  = c_jmp | c_fet;
c_amp  = c_fet & !c_jmp & romb[5:0] == amp_op;
c_idx  = c_jmp ? jstream + ((jrev & jr == 2) ? {5'b0, romb[0]} : 6'd0) : norm[5:0];
c_hot  = a_in[12] & !c_sub & a_in[11:0] >= 12'hFF4 & a_in[11:0] <= 12'hFFB;
c_sel  = (c_sub & !c_amp) | (access & !rw & a_in == 13'h1FF0);                     // ram_en (:140-156)
// ---- the replica of upstream's sel_ram_sel (cart2600.sv:191, 965) ----
sel_up = (is_dpc & d_sel) | (is_cdf & c_sel);
```

**Op classes** (`opc_t`, one-hot; DPC+ classes only when `is_dpc`, CDF classes only when `is_cdf`):

| Class | Condition |
|---|---|
| `rom` | DPC+ `rw & a12 & !d_reg`; CDF `rw & a12 & !c_sub` |
| `rrnd` | `d_reg & d_fn == 0 & d_ix != 5` |
| `amp` | DPC+ `d_reg & d_fn == 0 & d_ix == 5`; CDF `c_amp` |
| `rdat` | `d_reg & d_fn ∈ {1, 2, 3}` |
| `rflg` | `d_reg & d_fn == 4` (`d_fn` ≥ 5 is unreachable: `d_rn` < $28) |
| `dfld` | `d_wreg & d_g ∈ {0, 1, 2, 3, 4, 5, 8}` |
| `dpw` | `d_wreg & d_g ∈ {7, 10}` (`push` = `d_g == 7`) |
| `dpar` | `d_wreg & d_g == 6 & a[2:0] == 1` |
| `dcf` | `d_wreg & d_g == 6 & a[2:0] == 2` |
| `dmisc` | `d_wreg & ((d_g == 6 & a[2:0] ∈ {0, 5, 6, 7}) \| d_g == 9)` |
| `cfet` | `c_fet & !c_jmp & !c_amp` |
| `cjmp` | `c_jmp` |
| `cdsw` / `cdsp` / `cmode` / `ccall` | `!rw & a_in == $1FF0 / $1FF1 / $1FF2 / $1FF3` |

**Rules on `sel_up`.**

- It uses the **live** state and the live `romb`:
  - after a commit `fpend` is clear, so a fast-fetch select drops at C, as upstream's does;
  - in (E0, E0+1) the stale byte decides, as in tb_daria.
- It feeds only the audio grant (3.1).
- A2 (11.2) compares it with `sel_ram_sel` on every clock.

**The jump lookahead.**

- Port A reads `rom_a[14:2] + 1` in `k[0]` (A@1).
- In `k[1]`, with `lb1` and `lb2` the bytes at `rom_a+1` and `rom_a+2` taken from `{fea_q, feb_q}`:

  `jok = romb == $4C & lb1[7:1] == 0 & lb2 == 0 & rom_a < $7FFE`

- This is `cdf_fastjump_table`'s bit for `rom_a` (it is written as `byte[a] == $4C & byte[a+1][7:1] == 0 & byte[a+2] == 0`, with entries $7FFE/$7FFF zero), and it is valid in the same clock (E0+1, E0+2) as upstream's registered query.
- The image is linear, so a `$4C` at a bank end looks into the next bank's bytes (CDF Q18).

**The op latch.**

```systemverilog
always_ff if (k[1]) op <= {dec with .jok = jok};   // latched @2
wire dec_t opc = k[1] ? {dec, jok} : op;            // the op at a commit edge (dec if C = E0+2)
```

`a_in`, `rw`, `romb` and the state are constant from (E0+1, E0+2) up to C. So `opc` is the op upstream commits at C, whatever C is.

### 2.3 Commit actions and the ready rule (the fix for F1)

Each commit causes up to three kinds of work. Each fires as soon as its data is ready. It never fires before C, and never after the next E0 (`a_pend_late`). A deferred action (`pend_c`, `pend_s`, `pend_r`) still pending at the next E0 is dropped there: the three clear at `pclk1`. Outside a reset none is pending then. In the cycle in which `rst_fe` falls one can be: with `rst_fe` still high at the edge that sets the action's ready flag, or at a later edge before C, the flag stays 0 (9.5, `rst_release`). Dropped, it cannot fire in a later cycle with that cycle's W (lanes/F1_fixes.md 1). The release cycle itself stays inexact: upstream performs its access (9.5, `rst_release`).

**Kind 1. Flip-flop state, always at C.** These need only `opc`, `a_in` and `d_in`:

- `bank`, `fpend`, `fexp`, `jr`, `jexp`, `jstream`;
- `mode`, `rnd`, `ff_en`, `pptr`, `wave`;
- the NOTE strobe;
- `callfn`, `dma_set`;
- `din <= d_in`.

**Kind 2. At-commit actions.** Upstream applies these at C from values that DARIA reads in phase 1. They fire at C if the ready flag is high pre-edge at C. Otherwise `pend_c` is set at C, and they fire at the first later edge at which the flag is high pre-edge. They use `din` in place of `d_in` when deferred.

| Action | Ready flag | Effect at its edge |
|---|---|---|
| DSWRITE (`cdsw`) | `rdP` (W holds P32) | R byte write at `dsw_addr` (W), `{4{d}}`, be `1 << dsw_addr[1:0]`, with `we = access` on the C clock; W ← W + (`jplus` ? 1<<16 : 1<<20); `wb_v` ← 1, `wb_a` ← `pb` + 32; `rdW` ← 1 |
| DSPTR (`cdsp`) | `rdP` | W ← `shf(W, d)` = `jplus` ? `{W[23:16], d, 16'h0}` : `{W[23:20], d, 20'h0}`; `wb_v` ← 1, `wb_a` ← `pb` + 32; `rdW` ← 1 |
| CALLFUNCTION 1/2, taken (`dcf`, `d` ∈ {1, 2}, `!svc_pend` pre-edge at C) | `rdS` (params in W @3, the fetcher counter staged @4) | `svc_fill` ← (d == 2), `svc_src` ← $0C00 + {p1, p0}, `svc_dst` ← $0C00 + `cnt_st`, `svc_rem` ← p3, `svc_val` ← p0, `svc_pend` ← 1 |
| CDF fetch or jump (`cfet`, `cjmp`) | none at C | `wb_v` ← 1, `wb_a` ← `pb` + `idx` at C. The drain waits for `rdW` (3.1) |

**Kind 3. Post actions.** These are writes that upstream makes at or after C, which no audio read can tell apart from a write at C+1 (2.5 notes). They fire in the first clock **after** C in which their flag is high, so they register at C+1 nominally.

| Action | Ready flag | Write |
|---|---|---|
| S write, `rdat` | `rdW` (@4) | w0 be 0011 (DATA, DATAW) or w1 be 0111 (FRACDATA), data W |
| S write, `dpw` | `rdW` (@4) | w0 be 0011, data W |
| S write, `dfld`, `dpar` | always | field bytes or param byte (2.5), data from `din` |
| R byte, `dpw` | `rdW` (`ba` loads with it @4) | byte at `ba`, `{4{din}}`, be `1 << ba[1:0]` |

**The ready flags.** They are cleared at every `pclk1`, and set as follows:

| Flag | Set at the edge where … |
|---|---|
| `rdW` | `k[3] & op.(rdat\|dpw)` (W final @4); `k[4] & op.(cfet\|cjmp)` (W final @5); a DSWRITE/DSPTR action |
| `rdP` | `p32_q` (W ← P32 at that edge: @3, or @4 if the audio took @2) |
| `rdS` | `k[3] & op.dcf` (@4) |

**Two consequences.**

- **For C = E0+6** every flag is set before C. Every at-commit action then fires at C and every post action at C+1. That is simple's original schedule, edge for edge.
- **For C = E0+2 or E0+4** (a short phase 1), each action fires when its data is ready. That is no later than E0+5 for the flags and E0+6 for the writes, always before the next E0 ≥ C+6.
  - State, cart RAM and state RAM equal upstream's after the cycle. The exceptions are CDF Q26, where upstream itself computes the pointer from the stale index, and `fe_do`. Both are counted under `short_phase1`.
  - The phase-1 reads after an early commit lie outside upstream's select. The audio then waits a clock (`!fix_eff` in `aud_take`; `ev_grant_steal`, counted).

### 2.4 `daria_fe_core` register reference (D10)

Reset is `rst_fe` = `cart_reset | !(is_dpc | is_cdf) | (scheme != scheme_q)` (`scheme_q` is registered every clock). "—" means not reset. `wrC(x)` = `commit & !rw & a_in[11:0] == x`; `rdC` = `commit & rw`.

| Register | W | Reset | Load enable | Data (≤ 4 sources) |
|---|---|---|---|---|
| `op` | 42 | — | `k[1]` | `{dec, jok}` |
| `W` | 32 | — | `k[2] & op.(cfet\|cjmp)` \| `p32_q` → `crb_q`; `k[2] & op.(rdat\|dpw\|dcf)` → `stb_q`; `k[3] & op.(rdat\|dpw)` \| `k[4] & op.(cfet\|cjmp)` \| act(`cdsw`) → `W + Bv`; act(`cdsp`) → `shf` | `crb_q`, `stb_q`, `W + Bv`, `shf` |
| `Bv` (comb) | 32 | | one-hot AND-OR | `k4&cfet&!jplus`: `{4'h0, crb_q[15:0], 12'h0}`; `k4&cfet&jplus`: `{8'h0, crb_q[15:0], 8'h0}`; `(k4&cjmp \| act cdsw)&!jplus`: `$0010_0000`; `(…)&jplus`: `$0001_0000`; `k3&(rdat&fn!=3 \| dpw&!push)`: 1; `k3&dpw&push`: `$0FFF`; `k3&rdat&fn==3`: `{24'h0, W[31:24]}` |
| `p32_q` | 1 | 0 | every clock | `p32_gnt` (the P32 read registered at this edge) |
| `p32_got` | 1 | 0 | `k[1]` | `p32_gnt` |
| `cl` | 2 | — | `k[2] & op.(rdat\|cfet\|cjmp)` | `data_addr[1:0]` |
| `wf` | 1 | — | `k[2]` | `win(stb_q)` |
| `ba` | 13 | — | `k[3] & op.dpw` | $0C00 + (`push` ? `(W + Bv)[11:0]` : `W[11:0]`) |
| `cnt_st` | 12 | — | `k[3] & op.dcf` | `stb_q[11:0]` (w0 of fetcher p2 & 7) |
| `din` | 8 | — | `commit` | `d_in` |
| `fe_do` | 8 | 0 | `fd_k1 \| fd_flg \| fd_ram \| fd_amp` (below) | k1 byte, flag, RAM byte, `amp_nx` |
| `lane_q` | 2 | — | every clock | `rom_a[1:0]` |
| `rdW`, `rdP`, `rdS` | 1 each | 0 | 2.3 | set/clear |
| `pend_c` | 2 | 0 | `commit` (an at-commit action not ready) / its firing or `pclk1` | kind (`dsw`, `dsp`, `svc`), clear |
| `pend_s`, `sw_a`, `sw_be`, `sw_d` | 1, 5, 4, 1 | 0 | `commit` (an S post write) / its firing or `pclk1` | word ($00-$10), be, data select (W or `din` lanes) |
| `pend_r` | 1 | 0 | `commit & opc.dpw` / its firing or `pclk1` | set, clear |
| `wb_v` | 1 | 0 | set: `commit & opc.(cfet\|cjmp)`, act(`cdsw`\|`cdsp`); clear: `wb_gnt` | |
| `wb_a` | 9 | — | with `wb_v`'s set | `pb + idx` or `pb + 32` |
| `bank` | 3 | DPC+ 5; CDF `jplus` ? 0 : 6 | `commit & opc.hot` | DPC+ `a[2:0] − 6`; CDF: `jplus` ? (FF4/FFB → 0, else `a[2:0] − 4`) : (FF4/FFB → 6, else `a[2:0] − 5`) |
| `fpend` | 1 | 0 | `rdC` | DPC+ `opc.(rrnd\|amp\|rdat\|rflg)` ? 0 : `ff_en & romb == $A9`; CDF `opc.(cfet\|cjmp\|amp)` ? 0 : `fast_mode & arms` |
| `ff_en` | 1 | 0 | `wrC($058)` | `d_in == 0` |
| `rnd` (per byte b) | 4×8 | $2B435044 | `rdC & opc.rrnd & ix ≤ 1` \| `wrC($070)` \| `wrC($071 + b)` | `rnd_next[b]`, `rnd_prior[b]`, const[b], `d_in` |
| `pptr` | 4 | 0 | `wrC($059) & pptr < 8` \| `wrC($05A) & (d == 0 \| (d ∈ {1,2} & !svc_pend))` | `pptr + 1`, 0 |
| `wave[v]` | 3×7 | 0 | `wrC($05D + v)` | `d_in[6:0]` |
| `note_stb` | 1 | 0 | every clock | `commit & opc.dmisc & g == 9 & a[2:0] ≥ 5` |
| `note_v`, `note_val` | 2, 8 | 0 | the same condition | `a[1:0] − 1`, `d_in` |
| `svc_pend` | 1 | 0 | act(`svc`) / `svc_take` | 1 / 0 |
| `svc_fill`, `svc_src`, `svc_dst`, `svc_rem`, `svc_val` | 1, 17, 13, 8, 8 | 0 | act(`svc`) | 2.3 (p0..p3 = W bytes 0..3) |
| `mode` | 8 | $FF | `wrC($FF2)` | `d_in` |
| `fexp` | 13 | 0 | `rdC & !opc.(cfet\|cjmp\|amp) & fast_mode & opc.arms` | `a_in + 1` |
| `jr` | 2 | 0 | `rdC` | `cjmp` → `jr − 1`; (`jr != 0 & a_in == jexp`) → 0; (`fast_mode & opc.b4c & opc.jok`) → 2; (`jr != 0`) → 0. Unchanged on `cfet`/`amp` |
| `jexp` | 13 | 0 | `rdC & (opc.cjmp \| arm_j)` | `cjmp` ? `jexp + 1` : `a_in + 1` |
| `jstream` | 6 | 33 | `rdC & ((opc.cjmp & jrev & jr == 2) \| arm_j)` | `cjmp` ? 33 + `romb0` : 33 |

Here `arm_j = !opc.(cfet|cjmp|amp) & !(jr != 0 & a_in == jexp) & fast_mode & opc.b4c & opc.jok` (mapper_cdf.sv:222-232). The `jr` mux follows upstream's if/else-if order.

**Data addresses** (combinational, in `k[2]`, from the word read @2):

```systemverilog
pb   = rev == 0 ? 9'h1B8 : (rev == 1 ? 9'h028 : 9'h026);     // pointer table base (word)
ib   = rev == 0 ? 9'h1DA : (rev == 1 ? 9'h04A : 9'h049);     // increment table base (word)
data_addr = is_dpc ? 15'h0C00 + (op.fn == 3 ? stb_q[19:8] : stb_q[11:0])
          : jplus  ? (15'h0800 + crb_q[30:16])               // 15-bit: wraps mod $8000 (D8)
          :           15'h0800 + {3'b0, crb_q[31:20]};
dsw_addr  = jplus ? (15'h0800 + W[30:16]) : 15'h0800 + {3'b0, W[31:20]};
win(q)    = ((q[23:16] - q[7:0]) & 8'hFF) > ((q[23:16] - q[31:24]) & 8'hFF);   // top, counter, bottom
```

**`fe_do`** (D10: a register):

```systemverilog
fd_k1  = k[1] & ph1_open;                                   // @2
fd_flg = k[2] & op.rflg & ph1_open;                         // @3
fd_ram = k[3] & op.(rdat | cfet | cjmp) & ph1_open;         // @4
fd_amp = op.amp & ph1_open & !k[0] & !k[1];                 // @3 ... C−1, every edge
use_amp = (fd_k1 & dec.amp) | fd_amp;
d = ({8{fd_k1 & !dec.amp}} & (dec.rrnd ? rnd_byte(dec.ix) : romb))
  | ({8{fd_flg}} & ((op.ix < 4 & win(stb_q)) ? 8'hFF : 8'h00))
  | ({8{fd_ram}} & (crb_q[8*cl +: 8] & ((is_dpc & op.fn == 2) ? {8{wf}} : 8'hFF)))
  | ({8{use_amp}} & amp_nx);
// rnd_byte: 0 rnd_next[7:0], 1 rnd_prior[7:0], 2 rnd[15:8], 3 rnd[23:16], 4 rnd[31:24], 6/7 0
```

- `ph1_open` is 0 at C and through phase 2. `fe_do` therefore holds the byte the 6507 latched until the next cycle's E0+2. The bench counts this as `drift_fe` (information); `obus_exposed` must be 0, except for the TIA read at $0000 right after a CDF fast JMP's low operand at $1FFF (`obus_ffe`, 9.5).
- `amp_nx` is the value `amplitude` takes at this edge (5.3). Loading it at every edge up to C−1 makes `fe_do` in (C−1, C) equal upstream's `amplitude` in that clock.

### 2.5 DPC+ timing (relative to E0 and C; nominal C = E0+6)

Every row has B@1 (the mirror) and the op latched @2. "Final" is the edge from which `fe_do` holds the byte latched at C. "Select" is upstream's `sel_ram_sel` window, during which the audio cannot be granted.

| Access | Phase-1 reads | `fe_do` final | At C (kind 1, 2) | Post (kind 3), nominal edge | Select | Core R inside the select |
|---|---|---|---|---|---|---|
| ROM read $1028-$1FFF, incl. $A9 arming | — | @2 `romb` | `fpend`; hotspot | — | none | — |
| Hotspot $1FF6-$1FFB (read or write, not a register read) | — | @2 (old bank's byte) | `bank` ← a[2:0] − 6 | B@C+1 shows the new bank, as `cart_q` | none | — |
| RANDOM0NEXT/PRIOR ($1000/$1001, or fast-fetch $00/$01) | — | @2, low byte of next/prior | `rnd` ← next/prior; `fpend` ← 0 | — | none | — |
| RANDOM1-3, $1006/$1007 | — | @2 | `fpend` ← 0 | — | none | — |
| AMPLITUDE ($1005 / $05) | — | @2, then `amp_nx` at every edge to C−1 | `fpend` ← 0 | — | none | — |
| DFxFLAG ($1020-$1027 / $20-$27) | S@2 w0[ix] | @3 | `fpend` ← 0 | — | none | — |
| DFxDATA, DFxDATAW ($1008-$1017) | S@2 w0[ix]; R@3 $C00 + cnt; `wf` @3; W @3, W+1 @4 | @4 (DATAW: & flag) | `fpend` ← 0 | S@C+1 w0 be 0011 ← W | direct: (E0, next E0); fast: (E0+1, C) | R@3 ✓ |
| DFxFRACDATA ($1018-$101F) | S@2 w1[ix]; R@3 $C00 + frac[19:8]; W @3, W+inc @4 | @4 | `fpend` ← 0 | S@C+1 w1 be 0111 ← W | as DATA | R@3 ✓ |
| FRACLOW $1028+i | — | — | — | S@C+1 w1[i], be `sf` ? 0011 : 0010, lanes {x, x, din, $00} | none | — |
| FRACHI $1030+i | — | — | — | S w1, be 0100, {x, $0‖din[3:0], x, x} | none | — |
| FRACINC $1038+i | — | — | — | S w1, be 1001, {din, x, x, $00} | none | — |
| TOP $1040+i / BOTTOM $1048+i / LOW $1050+i | — | — | — | S w0, be 0100 / 1000 / 0001, `din` | none | — |
| HI $1068+i | — | — | — | S w0, be 0010, {x, x, $0‖din[3:0], x} | none | — |
| FASTFETCH $1058 | — | — | `ff_en` ← (`d_in` == 0) | — | none | — |
| PARAMETER $1059 | — | — | `pptr` ← `pptr` + 1 if < 8 | if `pptr` < 4 pre-edge: S word $10, be `1 << pptr[1:0]`, `{4{din}}` | none | — |
| CALLFUNCTION $105A | S@2 word $10 → W @3; S@3 w0[`stb_q[18:16]`] → `cnt_st` @4 | — | 0: `pptr` ← 0. 1/2 & `!svc_pend`: `pptr` ← 0, `dma_set`, service latch (kind 2). FE/FF: `callfn` | engine accept at C+1 (7.3); call (6) | none | — (S only) |
| WAVEFORM0-2 $105D-$105F | — | — | `wave[a[1:0]−1]` ← `d_in[6:0]` | — | none | — |
| PUSH $1060+i / WRITE $1078+i | S@2 w0[i]; W @3; `ba`, W ∓ 1 @4 | — | — | R@C+1 byte at `ba` ← `din`; S@C+1 w0 be 0011 ← W | (E0, next E0) | R@C+1 ✓ |
| RRESET / RWRITE0-3 $1070-$1074 | — | — | `rnd` ← const / byte ← `d_in` | — | none | — |
| NOTE0-2 $1075-$1077 | — | — | `note_stb` (C, C+1), `note_v` = a[1:0] − 1, `note_val` = `d_in` | the replica latches at C+1 (5.4) | none | — |
| Fast-fetch operand (any register) | as the register's row, with the register number from `romb` | same | same | same | (E0+1, C) | same |

**Notes.**

- **Field bytes need no read.** Each field has its own byte lane in w0/w1 (DI 5.2). Carries out of the 12-bit counter or the 20-bit fraction land in the spare nibble, which every reader masks and HI/FRACHI clear.
- **PUSH/WRITE.** Upstream strobes the byte from E2 to E6 (DPC §9.2). Upstream's select is high for the whole write cycle, so its audio reads nothing in between, and the 6507 writes. One write at C+1 therefore leaves RAM equal at every observation. `ram_wr_noaccess` is a bench assertion on upstream's side.
- **Every core R edge lies inside upstream's select (3.4).** The S port is not shared with the audio.

### 2.6 CDF family timing

Every row has B@1, plus **A@1 = the next image word** in `k[0]`, and `jok` in `k[1]` (2.2).

| Access | Phase-1 reads | `fe_do` final | At C | Post | Select | Core R inside it |
|---|---|---|---|---|---|---|
| ROM read, incl. arming ($A9; $A2/$A0 on CDFJ+ with `ldx`/`ldy`) and $4C jump arming | B@1, A@1 | @2 | `fpend`, `fexp`; `jr`/`jexp`/`jstream` (2.4); hotspot | — | (E0, E0+1) only if the stale byte satisfies a predicate (Q8, mirrored) | — |
| Hotspot $1FF4-$1FFB (read or write, not substituted) | — | @2 | `bank` (2.4 table) | B@C+1 new bank | none | — |
| Fast fetch, stream s = `norm` | R@2 ptr `pb`+s; R@3 data byte; R@4 inc `ib`+s; W = P @3, P + inc<<12 (CDFJ+ <<8) @5 | @4 | `fpend` ← 0; `wb_v`, `wb_a` = `pb`+s | R@C+1, or C+2 if the audio takes C+1: ptr ← W | (E0+1, C) | R@2, @3, @4 ✓ |
| Amplitude fetch (operand = `amp_op`) | — | @2, then `amp_nx` to C−1 | `fpend` ← 0, no pointer update | — | none (MC:142) | — |
| Jump operand 1 (stream 33, or 33 + `romb[0]` on CDFJ/J+) and operand 2 (`jstream`) | R@2 ptr; R@3 data; W = P @3, P + 1<<20 (CDFJ+ 1<<16) @5 | @4 | `fpend` ← 0; `jr` − 1, `jexp` + 1, `jstream`; `wb_v` | R@C+1/C+2 ptr ← W | (E0+1, C); plus (E0, E0+1) on operand 2 after a $00 operand 1 (stale byte, mirrored) | ✓ |
| Jump operand at $x000 after a bank-end $4C (A12 = 0) | — | not a cart cycle | nothing | — | — | — |
| DSWRITE $1FF0 | P32: R@2 (R@3 if the audio takes @2); W ← P32 the edge after | — | R byte at `dsw_addr` ← `d_in` (`we = access`, the C clock); W ← P32 + step; `wb_v`, `wb_a` = `pb`+32 (all kind 2: deferred if `!rdP`) | R@C+1/C+2 ptr[32] ← W | (C−1, C) only (`access`-gated) | R@C ✓ (the P32 read yields) |
| DSPTR $1FF1 | as DSWRITE | — | W ← `shf`; `wb_v` (kind 2) | R@C+1/C+2 ptr[32] ← W | none | the P32 read and the buffer yield |
| SETMODE $1FF2 | — | — | `mode` ← `d_in` | — | none | — |
| CALLFN $1FF3 | — | — | FE/FF: `callfn` | post (6) | none | — |
| A12 = 0 accesses | — | @2 (`oe` = 0) | nothing | — | — | — |

**Pointer write-backs.**

- The pointer update is upstream's `pointer_update_value` (mapper_cdf.sv:192-249). An amplitude fetch makes no update, because `table_index == amplitude_stream`.
- The new pointer goes into cart RAM between C+1 and C+2 (3.4). Upstream's writeback lands at E0+7.8 (CDF §14.3).
- The next read of that stream is at the next cycle's R@2, at C+8 or later.

### 2.7 Why every access fits

One M10K stage per clock: an address registered at edge n gives q in (n, n+1), and the logic between that q and the next M10K address fits one 69.8 ns clock (10.4). The longest chains:

| Chain | Edges |
|---|---|
| CDF fetch | `a_in` after E0 → B@1 → `romb`, decode, `pb + idx` → R@2 → `crb_q`, $800 + P → R@3 → byte → `fe_do` @4, latched at E0+6. That is one clock after upstream's combinational byte, inside the 2-clock slack S0 measured for this path. Increment: R@4 → W + inc @5 → R@C+1/C+2 |
| DPC+ fast-fetch DATA | B@1 → `romb` = register number → S@2 → `stb_q`, $C00 + cnt → R@3 → `fe_do` @4. That is two clocks after upstream's byte, inside S0's 3-clock slack |
| DSWRITE | P32 R@2/@3 → W @3/@4 → `dsw_addr` → R@C (needs `rdP`: C ≥ E0+4/E0+5, else deferred) |
| CALLFUNCTION 1/2 | S@2 params → S@3 w0[p2] → `cnt_st` @4 → latch at C (or @4+) |
| AMPLITUDE | `amp_nx` at every edge up to C−1 |
| Lookahead | A@1 and B@1 → `jok` in `k[1]` → `op` @2 / `opc` at C |

### 2.8 Irregular phases

| Case | What happens |
|---|---|
| Phase 1 stretched (MARIA→TIA hand-off, a pause in phase 1; CR 15) | `k` saturates; reads are done by E0+5; `fe_do` holds, and AMPLITUDE keeps reloading; `sel_up` stays upstream's; the commit at C, whenever it comes, applies kinds 1-3 at once. **Exact** |
| Phase 1 of 2 or 4 clocks (RSYNC, BU B2; S0 saw none in the image set) | Kind 1 at C from `opc` (`dec` + `jok` at E0+2); kinds 2 and 3 wait for their data (2.3). State, cart RAM and state RAM equal upstream's, except CDF Q26. `fe_do` is wrong at E0+2 and right at E0+4 only for ROM, random and AMPLITUDE. The audio may wait one clock (`grant_steal`). All counted as **`short_phase1`** (`ev_short`) |
| Phase 2 of 10 clocks | Post work ends by C+2 (nominal) or C+5 (short phase 1) |
| Hidden phase 2 (a held repeat) | `pclk0` sets `ph2` (so `rel_ok` works), and `access` = 0: no commit, no write. The repeat's reads run again (the held address is the opcode fetch after the CALLFN or service write: no R use, S0 §5 m5) |
| Pause in phase 2 | `rel_ok` holds, so a release may happen during the pause (CR 16) |
| Pause in phase 1 | Releases wait; ticks, refreshes and samples run on (D9) |
| A commit with `a_in[12]` = 0 | `commit` = 0: nothing |
| MARIA phases during reset and BIOS (4/6 clocks) | `access` = 0; `rst_fe` holds the state; F6 owns the ports while `f6_act` |

---
## 3. Port arbitration and the guard (`daria_fe_arb`)

There is one owner per port per clock, chosen by fixed priority. The owner's address, write enable, byte enables and data are presented in the clock and register on the edge that ends it (1.5). Every mux is a one-hot AND-OR of the owners' terms. A port with no owner is parked at address 0 with no write.

**No slot ring (D3).** Only the phase-1 reads are keyed to E0 (`k`), and only the commit actions to C. Every background user (the audio, the P32 read, the pointer buffer, the copy engine, the call port and F6) requests on any clock and is arbitrated per edge, so a stretched phase, a pause or a held cycle gives it more clocks, never fewer.

### 3.1 Cart RAM port B (R)

```systemverilog
fix_eff  = cr_fix & !guard_on & !f6_act;           // core fixed (suppressed under the guard)
aud_take = aud_issue & !sel_up & !fix_eff & !f6_act & (!guard_on | phb_next);
p32_gnt  = cr_p32 & !fix_eff & !aud_take & !guard_on & !f6_act;
wb_gnt   = cr_wb  & !fix_eff & !aud_take & !cr_p32 & !guard_on & !f6_act;
cp_gnt   = cp_req & (f6_act | (!fix_eff & !aud_take & !cr_p32 & !cr_wb & !guard_on));
// cr_wb = wb_v & rdW (core); cr_p32 = (k[1]&dec.(cdsw|cdsp) | k[2]&op.(cdsw|cdsp)&!p32_got)
```

| Priority | Owner | When | Access |
|---|---|---|---|
| 0 | F6 (`u_copy`, `f6_act`) | only while `cart_reset` has been high for ≥ 8 clocks. The audio, the 6507 and DARIA's CPU are all in reset | one word write per clock |
| 1 | core, fixed (`fix_eff`) | CDF: `k[1]` ptr (`dec.cfet\|cjmp`), `k[2]` data (`op.cfet\|cjmp`), `k[3]` inc (`op.cfet`). DPC+: `k[2]` data (`op.rdat`). The DSWRITE byte (kind 2). The PUSH/WRITE byte (kind 3) | read / byte write |
| 2 | audio (`aud_take`) | upstream's rule `!sel_ram_sel`, with `sel_up` for it | read |
| 3 | core P32 read (`p32_gnt`) | DSWRITE/DSPTR, `k[1]`, retried in `k[2]` | read; W ← `crb_q` next edge |
| 4 | core pointer write (`wb_gnt`) | `wb_v & rdW` | word write, be F, data W |
| 5 | copy/fill engine (`cp_gnt` without F6) | a service in progress | word (fill) or byte (copy) write |

`crb_use <= (fix_eff & cr_fix_use) | p32_gnt | aud_take` is registered: it is high in the clock whose `crb_q` is consumed. It is the bench's read side for the mode-B collision counts (BEN 6.4).

### 3.2 State RAM port B (S)

| Priority | Owner | When |
|---|---|---|
| 0 | F6 clear (`cz_req`) | words $00-$1F ← 0, first phase of F6 |
| 1 | core (`cs_req`, DPC+ only) | `k[1]`: read fetcher w0/w1[ix] (`rdat`, `rflg`, `dpw`) or word $10 (`dcf`). `k[2]`: read w0[p2 & 7] (`dcf`). Post writes (2.3) |
| 2 | call port (`cl_req`) | post writes F0-F7, return reads F8-FD |

- The audio uses no state RAM.
- The core uses S only in DPC+, and only for one clock in `k[1]`, one in `k[2]` and one after C. So a call-port word waits at most one clock.
- In CDF the call port's reads are exactly consecutive, which is what D5 asks for.
- Core writes and call writes never touch the same word.

### 3.3 Front-end ROM ports

| Port | Priority | Owner |
|---|---|---|
| B | — | the mirror, every clock: `feb_addr = rom_a[14:2]` |
| A | (in `daria_mem`) | the capture, in `cap_we` clocks (download only; console in reset) |
| A | 0 | F6 source (`ca_req & f6_act`) |
| A | 1 | CDF lookahead in `k[0]` (`look_req`, `!init_busy`) |
| A | 2 | audio local digital sample (CDF; waits one clock when it meets `k[0]`, 5.7) |
| A | 3 | DPC+ copy source (DPC+ only, so it never meets 1 or 2) |

```systemverilog
look_gnt  = look_req & !f6_act;
aud_a_gnt = aud_a_req & !f6_act & !look_req;
ca_gnt    = ca_req & (f6_act | (!look_req & !aud_a_req));
fea_addr  = ({13{look_gnt}} & look_a) | ({13{aud_a_gnt}} & aud_a_a) | ({13{ca_gnt}} & ca_a);
// S (3.2): cz has priority 0; cs is implicitly granted when !cz_req; cl_gnt = cl_req & !cz_req & !cs_req
```

### 3.4 Why the audio is granted on upstream's edges, and reads upstream's words

**(a) `fix_eff ⇒ sel_up` for C ≥ E0+6** (the invariant; A2 and `a_collide` check it). Case by case:

| Core fixed use | Clock | Why `sel_up` holds there |
|---|---|---|
| CDF fetch/jump ptr, data, inc | `k[1]`, `k[2]`, `k[3]` | the same predicate (`c_sub & !c_amp`) on the same `romb` and state, true until C |
| DPC+ data, fast fetch | `k[2]` | `d_reg & d_fn ∈ 1..3` on the true byte, until C |
| DPC+ data, direct | `k[2]` | address-decoded, for the whole cycle |
| DSWRITE byte | the C clock | `access & !rw & a_in == $1FF0` |
| PUSH/WRITE byte | (C, C+1) | the address-decoded write select holds until the next E0 |

`aud_take` contains `!sel_up` and `!fix_eff`. In mode A (guard inert) it therefore equals upstream's `ram_grant` on every clock. The only exception is a short-phase cycle: there `fix_eff & !sel_up` can occur after an early commit. The audio then waits one clock: `ev_grant_steal`, allowed only in a cycle with `ev_short`.

**(b) The yielding users never take an audio edge.** P32, the buffer and the copy engine all contain `!aud_take`.

**(c) The audio reads upstream's word.**

| Writer | When its write lands | Why the audio sees what upstream's sees |
|---|---|---|
| 6507 DSWRITE | at C | the same edge as upstream's |
| PUSH/WRITE | at C+1 | upstream's E2-E6 strobes lie inside its own select, which blocks its audio until the next E0 |
| ARM writes | from the bench mirror on upstream's own `clk_arm` edges (BEN 7.4.3); on hardware, ordered by the guard | — |
| Pointer write-backs (`wbuf`, exact's proof) | see below | — |

**The `wbuf` proof.** An ISSUE state granted at g is a CAPTURE state in (g, g+1), so the audio is never granted on two consecutive edges.

- The buffer is loaded at C and written at C+1 if the audio is not granted there, else at C+2.
- Upstream's writeback puts the pointer in cart RAM at E0+7.8. An upstream audio read of that word sees the old word at a grant ≤ E0+7, and the new one at ≥ E0+8.
- If DARIA writes at C+1: it owns the port at C+1, so no audio read happens there, and reads at ≥ C+2 see the new word.
- If DARIA writes at C+2: the audio was granted at C+1 (old word, as upstream's), and it cannot be granted at C+2.

Commits are ≥ 4 clocks apart, so the buffer never overruns (`a_wb_late`).

### 3.5 The guard (D4) at the ports

`guard_on = locked & (call_win | !cpu_ready)`. Here `call_win` runs from the `call_tog` flip until the merge is applied (6.1), and `!cpu_ready` is D4's conservative term. While `guard_on`:

| Port user | Effect |
|---|---|
| audio | ISSUE waits for `phb_next`, so every audio read registers on the phase-B edge (17.46 ns after the last `clk_arm` edge, 8.73 ns before the next). 0-2 clocks per read; `guard_shift`, hardware and mode B only |
| core fixed R (reads and writes), P32 | suppressed (`ev_guard_sup`), parked at address 0 (D4: speculative 6507-side reads may be suppressed). They occur only for a held repeat, whose data is never consumed. `a_guard_core` fires if a cycle with a suppressed request commits |
| pointer buffer, copy engine | no write |
| F6 | exempt: it runs only while `rst_quiet`, with DARIA's CPU held by `daria_mreset` |
| S, A, B | unaffected (DARIA's CPU does not use them; the call block is ordered by the toggles) |

**`a_guard_wr`.** It counts every non-F6 cart RAM write request made while `guard_on`. It must be 0 for two reasons:

- The 6507 is held from C+6 of a CALLFN to the release, and the release waits for `cpu_ready` (6.3).
- After a reset, the 6507's reset sequence (84 clocks, ROM reads only) outlasts DARIA's return to `daria_ready` (about 64 clocks, DI 3.4).

**When unlocked** (mode A at 5×, the ÷19 fallback), `guard_on` = 0 and nothing changes (D4).

**Phase-B timing**, with S a shared edge:

```
clk_sys edge     S-1    S      S+1    S+2    S'=S+3  S'+1
pd_same(clock)    0     1*     0      0      1*      0       (* = in the clock after the edge)
ph (flywheel)     2     0      1      2      0       1
phb_next          0     1      0      0      1       0       (presented in that clock -> registers at the next edge = phase B)
```

### 3.6 Assertions in `fe_arb` (one-clock pulses; the bench counts them)

| Name | Condition | Must be |
|---|---|---|
| `a_collide` | `ev_grant_steal` (`aud_issue & !sel_up & fix_eff`) in a cycle without `ev_short` | 0 |
| `a_wb_late` | `wb_v & k[1]` (the buffer is still full at the next cycle's first read) | 0 |
| `a_p32_late` | `k[3] & op.(cdsw\|cdsp) & !(p32_q \| rdP) & !guard_on` (the P32 read was not granted in `k[1]` or `k[2]`) | 0 |
| `a_guard_core` | a commit in a cycle that had `ev_guard_sup` | 0 |
| `a_guard_wr` | a non-F6 R write request while `guard_on` | 0 |
| one owner per port | `$onehot0(own_r)`, `$onehot0(own_s)`, `$onehot0(own_a)` (simulation only) | always |

---

## 4. State map

### 4.1 Flip-flops

| Block | State | Bits |
|---|---|---|
| top | `scheme_q` 6 | 6 |
| seq | `k` 8, `c` 4, `ph2` 1 | 13 |
| core, both schemes | `op` 42, `W` 32, `cl` 2, `wf` 1, `ba` 13, `din` 8, `p32_q`/`got` 2, `rdW`/`rdP`/`rdS` 3, `pend_c` 2, `pend_s`/`sw_*` 11, `pend_r` 1, `wb_v`/`wb_a` 10, `fe_do` 8, `lane_q` 2, `bank` 3, `fpend` 1 | ~141 |
| core, DPC+ | `rnd` 32, `ff_en` 1, `pptr` 4, `wave` 21, `note_*` 11, `cnt_st` 12, `svc_*` 48 | ~129 |
| core, CDF | `mode` 8, `fexp` 13, `jr` 2, `jexp` 13, `jstream` 6 | 42 |
| audio | `accum` 24, `counter` 96, `freq` 96, `ring` 192, `take` 3, `tdef` 1, `rc` 96, `st` 12, `voice` 2, `ssum` 8, `wsh` 5, `woff` 15, `dig_addr` 32, `dig_low` 1, `dig_ram` 15, `dig_smp` 1, `rp`/`np` 2, `nv`/`nval` 10, `amplitude` 8, `al` 2; sample client: `busy_l`/`busy_r` 2, `lcnt` 4, `a_done`/`a_q` 2, `rdat` 8, `smp_req` 1, `smp_addr` 19, `ack_s1`/`s2` 2, `rdone_q` 1 | ~760 |
| call | `st` 9 (one-hot), `idx` 3, `cap1` 1, `call_busy` 1, `pend2` 1, `pend_up` 1, `call_tog` 1, `ret_s1`/`s2` 2, `ret_seen` 1, `cnum` 8 | ~28 |
| copy | `loading` 1, `fe_loaded` 1, `ld1` 1, `cw_q` 1, `f6_dpc`/`f6_r32` 2, `rst_q` 1, `rdl` 3, `qcnt` 3, `rst_quiet` 1, `init_busy` 1, `f6_ph` 4, `f6_i` 13, `f6_v` 1, engine `run`/`fill`/`src` 17/`dst` 13/`rem` 8/`val` 8/`cq` 1/`cbyte` 8, `dma_busy` 1 | ~95 |
| guard | `pd_tog` (clk_arm), `pd_rx`, `pd_rx1`, `ph` 2, `good` 4, `locked` 1 | 10 |
| **Total** | | **~1,225** |

### 4.2 State RAM (256 × 32, port B)

| Word | Contents | Written by | Read by |
|---|---|---|---|
| $00-$0F | DPC+ fetcher i: w0 = word 2i = `{bottom, top, x‖counter[11:8], counter[7:0]}`; w1 = word 2i+1 = `{increment, x‖fraction[19:16], fraction[15:0]}` | core post writes; F6 clear | core S@2 (and S@3 for CALLFUNCTION) |
| $10 | DPC+ params 0-3, lane k = param k (params 4-7 are never read upstream, so they are not stored) | core (PARAMETER); F6 clear | core S@2 (CALLFUNCTION) |
| $11-$1F | unused (cleared by F6) | | |
| $20-$EF | unused (free) | | |
| $F0-$F7 | call block: entry\|T, stack, seeds 0-2, frequencies 0-2 | `u_call`, before the `call_tog` flip | `daria_call` port A (F0 at A3, F1-F7 at A18-A26) |
| $F8-$FD | returns: counters 0-2, frequencies 0-2 | `daria_call` port A (R2-R7; `ret_tog` flips after the last) | `u_call`, after the synchronised `ret_tog` change |
| $FE-$FF | unused | | |

`x` is a spare nibble. It takes adder carries, and HI/FRACHI write it as 0; the bench masks it (w0 `FFFF0FFF`, w1 `FF0FFFFF`).

### 4.3 In place in cart RAM (nothing copied or written back)

| Region | Byte addresses |
|---|---|
| CDF pointer table | `pb`×4: CDF0 $6E0, CDF1 $0A0, CDFJ/J+ $098; stream 32 at `pb`+32, the jump streams 33/34 after it |
| CDF increment table | `ib`×4: $768, $128, $124 |
| CDF data and driver area | as the driver keeps them |
| DPC+ display data | $0C00-$1BFF |
| DPC+ frequency table | $1C00-$1FFF |
| Waveform pointers | $7F0 (CDF0) / $1B0 |
| Size words | at `audio_size_addr` |

### 4.4 Front-end ROM

Image $0000-$7FFF, written by the capture (`cap_we`) during the download. Port B mirrors the 6507's bank. Port A serves the lookahead, F6's source, the copy source and local digital samples.

---

## 5. Audio engine (`daria_fe_audio`)

### 5.1 The choice: AMPLITUDE and NOTE exact (D1 option), with cost and risk

**What it is.**

- `fe_audio` is upstream's `arm_mapper_audio` re-expressed under D10, clock for clock, without BUS, `waveform_pointer` (never read) or `sample_sum[9:8]` (never used).
- Its grant is upstream's rule computed from `sel_up`.
- Its counters, frequencies, payload ring and refresh snapshot are flip-flops with their own adders.

**What it buys.**

- AMPLITUDE and NOTE are exact. The `amp_lag`, `note_race`, `amp_input_race` and `seed_race` classes of DI §7.1 do not exist.
- Every audio register can be compared with `dut.cart2600.mapper_audio` on **every clock** (A1). A divergence points at its first clock.
- No datapath register is shared with the core, so the core and the audio are unit-tested separately (12.3).

**What it costs.**

- About 520-580 ALMs against about 270-330 for lean's state-RAM audio: roughly +250 ALMs (10.1). That puts `daria_fe` on the 84% gate.
- The owner accepts area for correctness, so the design takes exactness, with three safeguards (10.3):
  1. a probe of this block alone before integration (gate: ≤ 560 ALMs);
  2. cheap levers in order (drop `rc`, narrow `dig_addr`);
  3. a drop-in fallback, `daria_fe_audio_lean`, with the same ports plus a reserved S owner, which brings back a counted `amp_lag`.

**Risks.**

1. `sel_up` must equal upstream's select on every clock. It is the same decode the core needs anyway, and A2 checks it on every clock.
2. The D10 rewrite must keep the replica's next-state function exact. The unit bench against `arm_mapper_audio` checks every clock (12.3).
3. Area (above).

### 5.2 Inputs and their substitutions

| Upstream input | Here | Equal to upstream's? |
|---|---|---|
| `ram_grant` | `aud_take` (3.1) | yes in mode A, except `short_phase1` |
| `ram_word_data` | `crb_q` | yes (3.4c), except `svc_audio_race`, `tbl_alias`, `pre_lock` |
| `ram_byte_data` | `pause ? $FF : crb_q[8*al +: 8]`, with `al` ← `aud_addr[1:0]` at every edge with `pause` low (lanes/B_audio.md, B-1) | yes, except `pause_lane` |
| `family` | `fam` = `is_dpc` ? 1 : `is_cdf` ? 3 : 0 (live, cart2600.sv:658-660) | yes |
| `revision`, `rom_size`, `mapper_ram_size`, `audio_size_addr` | inputs (`ram_size` = `ram32` ? $8000 : $2000) | yes |
| `cdf_digital_audio` | `cdf_dig` = `mode[7:4] == 0` from the core (set at C, as upstream's) | yes |
| `dpc_waveform0-2`, `dpc_note_*` | `wave0-2`, `note_stb` (C, C+1), `note_v`, `note_val` | yes |
| `call_launch` | `cp_cap` (the ring captures at L = C+1; M for a DPC+ RMW) | yes (CDF RMW: `rmw_call`) |
| `call_done` + returns | `cp_apply` at M_fe from the ring, with tick deferral (5.6); or `hk_*` at M | counters and frequencies yes; `merge_amp` |
| `rom_ready`, `rom_done`, `rom_data` | the sample client (5.7) | hit timing yes; `dig_rom_lag` |
| `reset` | `cart_reset` only (never `rst_fe`) | yes |

### 5.3 Register reference (D10; reset = `cart_reset` unless noted)

The definitions used in the table:

- `tick_eff = (tick & !mwin) | late`, with `late = tdef & !mwin`.
- `take_eff[v] = (cp_apply & fam == 3 & take[v]) | hk_take[v]`.
- `hk_apply = hk_en & hk_stb & fam == 3`, and `hk_take[v] = hk_apply & (hk_c[v] != ring[v])`.

| Register | W | Reset | Load enable | Data (≤ 4 sources) |
|---|---|---|---|---|
| `accum` | 24 | 0 | every clock | `accum + (tick ? TICK_WRAP : TICK_STEP)`; `tick = accum >= TICK_TH` |
| `counter[v]` | 3×32 | 0 | `tick_eff \| take_eff[v]` | `A + B` with `A = take_eff[v] ? (hk_apply ? hk_c[v] : ring[v]) : counter[v]` and `B = (tick_eff & !take_eff[v]) ? freq[v] : 0`. One adder per voice with folded input muxes (merge beats a same-edge tick, AUD:213-219) |
| `freq[v]` | 3×32 | 0 | `(cp_apply & fam == 3) \| hk_apply \| (st.NCAP & nv_eff == v)` | `ring[3+v]`, `hk_f[v]`, `crb_q` |
| `ring[i]`, i < 5 | 5×32 | 0 | `cp_cap \| cp_rot \| cp_shin` | `cp_cap` ? `capv[i]` : `ring[i+1]` (`capv` = counter 0-2, freq 0-2) |
| `ring[5]` | 32 | 0 | the same | `cp_cap` ? `freq[2]` : `cp_rot` ? `ring[0]` : `stb_q` |
| `take` | 3 | 0 | `cp_shin & cp_cmp` | `{stb_q != ring[0], take[2:1]}` |
| `tdef` | 1 | 0 | `(tick & mwin) \| late` | `tick & mwin` (set) / 0 |
| `rp` (refresh pending) | 1 | 0 | `tick \| dispatch` | `dispatch ? tick : (fam != 0)` (AUD:191-195, 229) |
| `np` (note pending) | 1 | 0 | `note_stb \| st.NCAP` | `note_stb` |
| `nv`, `nval` | 2, 8 | 0 | `note_stb` | `note_v`, `note_val` |
| `rc[v]` | 3×32 | 0 | `dispatch` | `counter[v]` |
| `st` | 12, one-hot | IDLE | every clock | 5.4 |
| `voice` | 2 | 0 | `dispatch \| v_inc` | `dispatch ? 0 : voice + 1` |
| `ssum` | 8 | 0 | `dispatch \| v_inc` | `dispatch ? 0 : ssum + byte` |
| `dig_smp` | 1 | 0 | `dispatch \| (st.DROUTE & in_ram)` | `!dispatch` |
| `wsh` | 5 | 27 | `dispatch \| v_inc \| (st.PCAP & !digital & asz == 0) \| st.SZCAP` | `st.SZCAP ? crb_q[11:7] : 27` |
| `woff` | 15 | 0 | `st.PCAP & !digital` | `woff_of(crb_q)` |
| `dig_addr` | 32 | 0 | `st.PCAP & digital` | `crb_q + (rc[0] >> (jplus_s ? 13 : 21))` |
| `dig_low` | 1 | 0 | `st.PCAP & digital` | `jplus_s ? rc[0][12] : rc[0][20]` |
| `dig_ram` | 15 | 0 | `st.DROUTE & in_ram` | `dig_addr[14:0]` |
| `amplitude` | 8 | 0 | `amp_we` | `nib(byte, dig_low)` (SMCAP, `dig_smp`); `ssum + byte` (SMCAP, voice 2); 0 (DROUTE, out of range); `nib(rdat, dig_low)` (RWAIT, `rom_done`) |
| `al` | 2 | 0 (`cart_reset`) | `!pause`: every unpaused edge (lanes/B_audio.md, B-1; 5.2) | `aud_addr[1:0]` |

More definitions:

```systemverilog
dispatch = st.IDLE & !(np & fam == 1) & rp;
v_inc    = st.SMCAP & !dig_smp & voice != 2;
digital  = fam == 3 & cdf_dig;                jplus_s = fam == 3 & rev == 3;
nv_eff   = (nv == 3) ? 2 : nv;                // AUD:249-253: default arm writes frequency2
in_ram   = dig_addr >= 32'h4000_0000 & (dig_addr - 32'h4000_0000) < {16'b0, ram_size};
woff_of(w) = jplus_s ? ((w < 32'h4000_0800 | (w - 32'h4000_0800) >= {16'b0, ram_size - 16'h0800})
                         ? 15'd0 : w[14:0] - 15'h0800)
                     : {3'b0, w[11:0] - 12'h800};
nib(b, lo) = lo ? {4'h0, b[3:0]} : {4'h0, b[7:4]};
byte     = pause ? 8'hFF : crb_q[8*al +: 8];
amp_we   = (st.SMCAP & (dig_smp | voice == 2)) | (st.DROUTE & !(dig_addr < rom_size) & !in_ram)
         | (st.RWAIT & rom_done);
amp_nx   = cart_reset ? 8'h00 : (amp_we ? amp_d : amplitude);    // forwarded to fe_do
```

### 5.4 State transitions (one-hot; AUD:225-363 without BUS)

| State | Next |
|---|---|
| IDLE | `np & fam == 1` → NISS; else `rp` → (`fam == 1` ? SMISS : PISS) (that is `dispatch`); else IDLE |
| NISS | `aud_take` → NCAP |
| NCAP | → IDLE (`freq[nv_eff]` ← `crb_q`; `np` ← `note_stb`) |
| PISS | `aud_take` → PCAP |
| PCAP | `digital` → DROUTE; else `asz == 0` → SMISS; else SZISS |
| SZISS | `aud_take` → SZCAP |
| SZCAP | → SMISS |
| SMISS | `aud_take` → SMCAP |
| SMCAP | `dig_smp \| voice == 2` → IDLE; else → (`fam == 1` ? SMISS : PISS) |
| DROUTE | `dig_addr < rom_size` → RISS; else `in_ram` → SMISS; else IDLE |
| RISS | `rom_ready` → RWAIT |
| RWAIT | `rom_done` → IDLE |

### 5.5 Address and request

```systemverilog
aud_issue = st.NISS | st.PISS | st.SZISS | st.SMISS;
idx  = rc_sel >> wsh;          // rc_sel = rc[voice] (3:1); 32 -> 15-bit barrel shift, [14:0] kept
sos  = woff + idx[14:0];       // 15 bits
wsel = voice == 0 ? wave0 : voice == 1 ? wave1 : wave2;               // live (AUD:113-126)
aud_addr17 = ({17{st.NISS}}  & (17'h1C00 + {nval, 2'b00}))
           | ({17{st.PISS}}  & ((rev == 0 ? 17'h07F0 : 17'h01B0) + {voice, 2'b00}))
           | ({17{st.SZISS}} & ({1'b0, asz} + {voice, 2'b00}))
           | ({17{st.SMISS}} & (dig_smp   ? {2'b0, dig_ram}
                              : fam == 1  ? 17'h0C00 + {wsel, 5'b0} + idx[4:0]
                              : jplus_s   ? (17'h0800 + sos) & ({1'b0, ram_size} - 1)
                              :              17'h0800 + sos[11:0]));
aud_addr  = aud_addr17[14:0];  ev_size_hi = st.SZISS & aud_addr17[16:15] != 0;   // size_over32k
```

### 5.6 Payload, returns and the merge, against ticks

**Capture (`cp_cap`).**

- For a call, `cp_cap` is in (C, C+1), so the ring loads at **L = C+1** with pre-edge values. It holds every tick up to and including C (= E0+6) and none at L. That is upstream's FIQ r8-r13 payload exactly (D1, AUD 10.1), so `seed_race` = 0.
- For a DPC+ RMW second call, `cp_cap` registers at M = X+1: upstream's second launch, exact.
- For a CDF RMW second call, it registers at M_fe together with `cp_apply` (6.4).

**Post (`cp_rot`).** It rotates the ring six times while F2-F7 go out from `ring[0]`, so the ring is back in place afterwards.

**Returns (`cp_shin`).**

- F8-FD shift in at X+1 … X+6.
- During the first three shifts (`cp_cmp`), `ring[0]` is the matching seed, so `take[v] = (return_v != seed_v)` (AUD 10.4).
- After six shifts, `ring` holds the six returns in place.

**Apply at M_fe = X+7 (`cp_apply`).**

- Counter v takes `ring[v]` if `take[v]`, and every frequency takes `ring[3+v]`, all on one edge.
- No tick is added on that edge (it lies in `mwin`).

**Tick deferral.**

- `mwin` is high in the clocks (X+1, X+2) … (X+6, X+7), so it covers the tick edges M+1 … M_fe.
- A tick on those edges still sets `rp`, so the refresh is dispatched on upstream's edge. Its add is deferred: `tdef` ← 1.
- At M_fe+1, `late` adds `freq[v]`, which is now the returned frequency f', to every counter.
- Ticks are ≥ 715 clocks apart, so at most one tick is deferred (`a_tdef2`).

Let T be the tick edge. The outcomes against upstream:

| Tick at | Upstream | Here | Equal at M_fe+1? |
|---|---|---|---|
| T ≤ M−1 | `c + f`, then the merge at M | `c + f`, then the apply at M_fe | yes |
| T = M | changed counter: return (the tick is lost); unchanged: `c + f` | `c + f` at M; at M_fe a changed counter takes the return, an unchanged one keeps `c + f` | yes |
| M < T ≤ M_fe | merged value + f' at T | merged at M_fe, + f' at M_fe+1 | yes |
| T > M_fe | merged + f' | merged + f' | yes |

So **counters and frequencies equal upstream's at every tick edge outside (M, M_fe+1]**. T2 compares inside that window at M_fe+2 instead (12.4). The every-clock check A1 masks counters, frequencies and `rc` in (M, M_fe+1].

**What remains: `merge_amp`.** A refresh dispatched at D ∈ (M, M_fe+1] snapshots `rc` before the merge, or without the deferred tick. That refresh's AMPLITUDE value may differ; its grant edges are the same, except in digital mode, where the route may differ until both engines are IDLE.

- It is self-healing: the next refresh compares again.
- It occurs in about 6/716 of CDF calls (a tick in [M, M_fe]).
- With the hook it is 0.

**Hook (`hk_en`, bench only).** `hk_apply` merges at upstream's own M from `hk_ret`, comparing with the seeds still in place. `mwin` is then 0, and `u_call` skips the reads (6.6).

**NOTE (DPC+).**

- `note_stb` is in (C, C+1), so `np` sets at C+1.
- NISS wins IDLE, and NCAP writes `freq[nv_eff]` at E0+10 at the earliest. It is later behind a refresh or a select, exactly as upstream (AUD 9.3).
- The overlap table (AUD 9.4) follows from the identical registers.
- `note_race` = 0.

### 5.7 Digital ROM samples and the sample port (D8)

`rom_ready = !(busy_l | busy_r)`. Neither flag is reset by `cart_reset`: an orphaned request blocks the next one until its answer comes, as upstream's `sample_busy` does (AUD 7.3 item 5, G7). At the edge R where RISS sees `rom_ready`, one of two paths starts.

**Local** (`dig_addr[31:15] == 0`, below 32 KB): from the front-end ROM.

```systemverilog
// at R: busy_l <= 1; lcnt <= 4'b0001; a_done <= 0
aud_a_req = (lcnt[0] | lcnt[1]) & !a_done;    aud_a_a = dig_addr[14:2];
// granted (A priority 2): a_done <= 1, a_q <= 1 for one clock; in the next clock rdat <= fea_q[8*dig_addr[1:0] +: 8]
lcnt <= {lcnt[2:0], 1'b0};                    // one-hot (R, R+1) .. (R+3, R+4)
rom_done = lcnt[3] & busy_l;                  // in (R+3, R+4): amplitude at R+4 = upstream's hit (AUD 8.3)
// busy_l <= 0 with rom_done
```

The A read registers at R+1, or at R+2 if R+1 is a `k[0]` lookahead edge (one per 6507 cycle). `rdat` is then valid by R+3.

**Remote** (32 KB and above, `dig_addr < rom_size` ≤ 512 KB):

```systemverilog
// at R: busy_r <= 1; smp_addr <= dig_addr[18:0]; smp_req <= ~smp_req
ack_s1 <= smp_ack; ack_s2 <= ack_s1;          // SYNCHRONIZER_IDENTIFICATION FORCED on ack_s1
if (busy_r & ack_s2 == smp_req) begin rdat <= smp_data; busy_r <= 0; rdone_q <= 1; end else rdone_q <= 0;
rom_done = (lcnt[3] & busy_l) | rdone_q;      // amplitude one edge after rdat
```

**Protocol (wrapper side, `clk_arm`, in `bupchip_pocket.sv`, step 7).**

- `smp_req` passes two `clk_arm` flops (FORCED).
- When the synchronised request differs from `smp_ack` and the requester is idle:
  1. latch `smp_addr` (stable since before the toggle);
  2. read that image byte through the asset cache over PSRAM (a requester between CPU reads, DC 3.2 "Samples");
  3. drive `smp_data` and hold it;
  4. one `clk_arm` later, set `smp_ack` ← the synchronised request.
- `smp_addr` and `smp_data` are held buses under the ±20 ns clock exceptions (DC 7.3). One request is outstanding at a time.

**Mode A.** The bench answers with `img[smp_addr]` after `+fe_slat` `clk_sys` (NBA), then flips `smp_ack` one clock later. T4 compares `smp_addr` and the local address with upstream's `digital_address` in DIGITAL_ROUTE.

**Class `dig_rom_lag`.** An upstream DDR miss (`sample_done` later than R+3), or any remote sample. The AMPLITUDE edge differs, and the replica's state is offset until both engines are IDLE with nothing pending. The bench then masks A1 and resyncs (`fe_deposit_audio`).

### 5.8 Pause (D9)

- The engine has no enable: ticks, refreshes, NOTEs and samples run on.
- Sample bytes read $FF; words read true data (top.sv:934-936).
- The 6507 bus freezes, and `sel_up` is evaluated on the frozen bus, so a frozen selecting cycle blocks grants for the whole pause, as upstream's (AUD 12.5).
- The select can still change right after the last unpaused edge: at a `pclk1` the next cycle's address appears, and at a commit the state changes, or one clock after an address or bank change, while `rom_do` still holds the byte of the clock before: the arming byte itself, the new bank's byte after a hotspot, or ROM[bank : the address of a TIA or RIOT cycle] (lanes/F1_fixes.md 2, rows 3-4). Upstream's lane register then holds the 6507's byte lane while grants run in the pause; `al` holds the engine's.
- Counted: `pause_lane` (in the stage-1 shadow: a sample capture on an unpaused edge right after a grant edge in a pause, whose last unpaused edge had the select high, with upstream's lane register and `al` differing, and each holding what it loaded at that edge: upstream's the port's lane, which with the select high is the 6507's; `al` the engine's `a_d[1:0]`; `tb_fe_audio`'s and the random bench's conditions are in lanes/F1_fixes.md 2). `al` cannot follow upstream's lane at every such edge (lanes/F1_fixes.md 2). In mode B, DARIA's CPU also runs through a pause (`pause_call`). **The Pocket never pauses** (`core_top.v:883` ties `pause_core` to 0), so neither class occurs on hardware. They matter only for a port to a core that pauses, such as MiSTer with its OSD menu; `lanes/F1_pause_lane_mister.patch` is the near-exact `al` for that case (unsimulated; F1_fixes.md 2).

### 5.9 Exactness argument

The replica's next state depends only on its own state and on the inputs of 5.2. Each input equals upstream's in mode A, except under the named classes. So `st`, `voice`, the grant edges, `aud_addr`, `amplitude` and its write edge all equal upstream's on every clock.

`fe_do` loads `amp_nx` at every edge up to C−1, so an AMPLITUDE read at any C returns upstream's value: **`amp_lag` = 0, `note_race` = 0, `amp_input_race` = 0.**

---
## 6. Call side (`daria_fe_call`, D5)

### 6.1 State machine and registers

The states are one-hot: IDLE, POST, FLIP, RUN, RD, RDW, APPLY, HKW, REL.

```systemverilog
ret_new = ret_s2 != ret_seen;                        // ret_s1 <= ret_tog; ret_s2 <= ret_s1 (ret_s1 FORCED)
always_ff @(posedge clk_sys) begin
  ret_s1 <= ret_tog;  ret_s2 <= ret_s1;  xq <= st.RUN & ret_new;  rd_q <= rd_gnt;
  if (cart_reset) begin
    st <= IDLE; call_busy <= 0; pend2 <= 0; pend_up <= 0; cap1 <= 0; ret_seen <= ret_s2;   // call_tog kept
  end else begin
    cap1 <= 0;
    if (callfn & !call_busy)     begin call_busy <= 1; st <= POST; idx <= 0; cap1 <= 1; end   // at C
    else if (callfn & !pend2)    begin pend2 <= 1; pend_up <= 1; end                          // RMW, one deep
    if (xq) pend_up <= 0;                                // upstream accepts call 2 at X+1 (tap only)
    if (ret_new & !st.RUN) ret_seen <= ret_s2;          // ev_ret_unasked = this condition (must be 0)
    case (1'b1)
    st.POST:  if (cl_gnt) begin idx <= idx + 1;
                 if (idx == 7) begin
                   if (cpu_ready) begin call_tog <= ~call_tog; cnum <= cnum + 1; st <= RUN; end
                   else st <= FLIP;
                 end end
    st.FLIP:  if (cpu_ready) begin call_tog <= ~call_tog; cnum <= cnum + 1; st <= RUN; end
    st.RUN:   if (ret_new) begin ret_seen <= ret_s2;                     // this edge is X
                 if (is_dpc)     begin if (pend2) begin pend2 <= 0; st <= POST; idx <= 0; cap1 <= 1; end
                                       else st <= REL; end
                 else if (hk_en) st <= HKW;
                 else            begin st <= RD; idx <= 1; end           // F8 was read in this clock
              end
    st.RD:    if (cl_gnt) begin idx <= idx + 1; if (idx == 5) st <= RDW; end
    st.RDW:   st <= APPLY;                               // FD's word shifts in at the end of this clock
    st.APPLY: if (pend2) begin pend2 <= 0; st <= POST; idx <= 0; end else st <= REL;
    st.HKW:   if (pend2) begin pend2 <= 0; st <= POST; idx <= 0; end else st <= REL;
    st.REL:   if (rel_ok & cpu_ready) begin call_busy <= 0; st <= IDLE; end
    endcase
  end
end
// S requests (priority 2 on S):
cl_req = st.POST | st.RD | (st.RUN & ret_new & is_cdf & !hk_en);
cl_we  = st.POST;   cl_a = st.POST ? 8'hF0 + idx : 8'hF8 + (st.RUN ? 0 : idx);
cl_wd  = idx == 0 ? F0 : idx == 1 ? F1 : ring0;      // F2..F7 = ring[0], rotating
rd_gnt = cl_gnt & !cl_we;
// strobes to u_audio:
cp_cap   = cap1 | (st.APPLY & pend2) | (st.HKW & pend2);
cp_rot   = st.POST & cl_gnt & idx >= 2;
cp_shin  = rd_q;                     cp_cmp = rd_q & (sidx < 3);     // sidx: shifts since RUN
cp_apply = st.APPLY & is_cdf;
mwin     = is_cdf & !hk_en & ((st.RD & idx != 1) | st.RDW | st.APPLY);
call_win = st.RUN | st.RD | st.RDW | st.APPLY | st.HKW;
arm_call_busy = call_busy;
```

- `F0` = DPC+ `$0000_0C09`; CDF0/1/J `$0000_0809`; CDFJ+ `{cdfj_entry[31:1], 1'b1}` (`call_entry | call_thumb`, mapper_dpcplus.sv:184-186, mapper_cdf.sv:159-162).
- `F1` = `cdfj_stack` on CDFJ+, else `$4000_1FFC`.
- `callfn` = a commit of $105A (DPC+) or $1FF3 (CDF) with `d_in` ∈ {$FE, $FF}. Upstream ignores it while `call_pending`; here, after the one-deep `pend2`, it is ignored.
- **`ev_ret_unasked`.** It fires when `ret_new` is seen outside RUN (outside reset); `ret_seen` follows the toggle so the stray flip is dropped. It must be 0.

### 6.2 Commit, capture, post, flip (nominal C = E0+6)

| Edge | What |
|---|---|
| C | `callfn`: `call_busy` ← 1, POST, `cap1`. Any rise in [E0+6, E0+17] is the same for the 6507 (GL 7.5) |
| C+1 = L | `cp_cap`: the ring takes counters and frequencies (upstream's accept edge, so `seed_race` = 0). F0 is written |
| C+2 | F1 |
| C+3 … C+8 | F2 … F7 from `ring[0]`, rotating |
| C+8 | `call_tog` flips with F7's write, if `cpu_ready` (D5). Else FLIP waits. A flip during a reset cannot happen, because reset forces IDLE |

`daria_call` reads F0 at A3 and F1-F7 at A18-A26 after its two `clk_arm` flops, so every word is in place long before (mixed-port ordering by the toggle). The flip at C+8 is earlier than any upstream return: the warm-call minimum is X ≈ C+15 (GL 7.3). So in mode A the bench never has to hold `ret_tog` back (`ret_late` is expected to be 0).

### 6.3 Return, read, apply, release

| Edge | CDF | DPC+ |
|---|---|---|
| A_c (`clk_arm`) | `ret_tog` flips; every return word was written before it (daria_call.sv) | the same |
| S1, S2 | `ret_s1`, `ret_s2` | the same |
| (S2, X) | `ret_new`: F8 read presented (the S port is the call port's in CDF) | `ret_new` |
| X = S3 | `ret_seen` ←; RD. Upstream: busy falls (X), merge at M = X+1 | `ret_seen` ←; REL, or POST + `cap1` for `pend2` (ring at M = X+1, exact) |
| X+1 … X+5 | F9 … FD reads registered (six consecutive clocks with F8, as D5 asks) | — |
| X+1 … X+6 | shifts into the ring; `take` at X+1 … X+3 | — |
| X+2 … X+7 | `mwin`: tick adds deferred (5.6) | — |
| **X+7 = M_fe** | `cp_apply`: counters and frequencies applied atomically; with `pend2`, `cp_cap` (6.4) | — |
| X+8 | `late` tick add if one was deferred | — |
| ≥ X+8 | `call_busy` ← 0 at the first edge with `rel_ok & cpu_ready` (D3) | ≥ X+1: the same rule |

**The release.**

- `rel_ok` gives D3's rule: the release falls only while in phase 2.
- `cpu_ready` makes sure DARIA's CPU is parked before the 6507 resumes. That is what keeps `a_guard_wr` at 0 on hardware (3.5). In mode A, `cpu_ready` excludes `call_busy` and is steady, so the term changes nothing there.
- In mode B and on hardware, the release-window duplicate commit of upstream (GL 7.5) is removed: `release_dup`, counted.

### 6.4 RMW CALLFN (CR 18; D5 "one-deep pending call")

A CALLFN committed while `call_busy` sets `pend2`, once.

- **CDF.**
  - At M_fe, `cp_apply` and `cp_cap` fire together. The ring takes the **pre-merge** counters and frequencies (call 2's seeds and payload) while the counters take the merge.
  - Then the FSM posts F0-F7, flips, and waits again. `call_busy` stays high between the calls.
  - Upstream launches call 2 at M with the counters pre-edge at M. They differ only if a tick falls exactly on M, which this design added at M: counted `rmw_call` (value). Deferred ticks in (M, M_fe] are not in the counters at M_fe, so they cannot pollute the capture.
- **DPC+.** DPC+ never merges, so `cp_cap` registers at X+1 = M: exact.
- **Both.**
  - Upstream's one-clock dip of the stall between the calls is not reproduced: `rmw_call` (stall shape, hardware and mode B; in mode A the stall is upstream's).
  - `pend_up` (tap only) reproduces upstream's `call_pending`: set at the second commit, cleared at X+1. C1/C2 can therefore compare `call_pending` directly.
- **Corrections from lane C** (`docs/daria_fe/lanes/C_call_copy.md` 1.3; the RTL follows them, unit-verified against upstream):
  - **C-1.** A CALLFN committed in REL is posted from REL at once. As first written, REL ignored `pend2`: the call was lost, and the next call was followed by a phantom second one.
  - **C-2.** A DPC+ CALLFN committed in the X clock itself is posted at X.
  - **C-3.** A CALLFN committed after X is upstream's new call after its merge, not an RMW: it does not take the pre-merge payload at M_fe; DARIA captures it at M_fe+2 (M+2 with the hook). Its seeds can differ if a tick falls between upstream's accept (C2+1) and that capture: counted `rmw_call`.
  - A third CALLFN in (M, M_fe] of a CDF RMW is dropped by the one-deep `pend2`, where upstream queues it. Real 6507 code cannot do this (a CALLFN takes at least one more instruction), only artificial bench streams.

### 6.5 Reset

On `cart_reset`, in any state:

- `call_busy` ← 0, `pend2` ← 0, `pend_up` ← 0, FSM ← IDLE;
- `ret_seen` ← `ret_s2` on every reset clock;
- `call_tog` keeps its value.

DARIA's CPU is reset by `daria_mreset` (the same `effective_reset`), and `daria_call` re-syncs its own seen flag (daria_call.sv:29-32). A return from an abandoned call is ignored.

### 6.6 Mode A

- `cpu_ready` = upstream's `arm_online_sync2 && shadow_ready_sync2 && !effective_reset`, without `call_busy` (CR 8).
- The bench writes upstream's returns into `fe_mem` state RAM F8-FD on the `clk_arm` edges where upstream's controller captures them (BEN 7.4.4).
- It flips the emulated `ret_tog` with upstream's `complete_toggle`, but only once `daria_fe` has flipped `call_tog` for the same call number (`cnum`). Then X is upstream's X.
- If DARIA's flip came after upstream's toggle, the bench flips at DARIA's flip instead and counts `ret_late`. The counters' `merge_race` is allowed only then.
- **Hook** (`+fe_merge_hook=1`): `hk_stb` is upstream's `call_done`, high in (X, X+1), and `hk_ret` its returns. `u_audio` merges at M. `u_call` goes RUN → HKW for one clock (the `pend2` capture at M), with no reads and no `mwin`. Use it to separate arithmetic from timing.

---

## 7. F6, the state-RAM clear, copy/fill, `init_busy`, `arm_dma_busy` (`daria_fe_copy`, D6, D7)

### 7.1 Load tracking, triggers, `init_busy`

```systemverilog
always_ff @(posedge clk_sys) begin           // load tracking is not reset by cart_reset
  if (load_start)                 begin loading <= 1; fe_loaded <= 0; end
  else if (load_end)              loading <= 0;
  ld1 <= load_end & loading;                 // scheme and ram32 are valid from load_end+1
  if (ld1) begin fe_loaded <= is_dpc | is_cdf; f6_dpc <= is_dpc; f6_r32 <= ram32; end   // latched family
  cw_q  <= cart_win;
  rst_q <= cart_reset;
  qcnt  <= cart_reset ? (qcnt == 7 ? 7 : qcnt + 1) : 0;    rst_quiet <= cart_reset & qcnt == 7;
  rst_rise = cart_reset & !rst_q & fe_loaded & !init_busy;    // never on a falling reset
  if (rst_rise) rdl <= 4'd8; else if (rdl != 0) rdl <= rdl - 1;
  // init_busy (D6): from load_start or the reset rise through F6's end, never dipping
  if (load_start | rst_rise)              init_busy <= 1;
  else if (f6_done)                       init_busy <= 0;
  else if (ld1 & !(is_dpc | is_cdf))      init_busy <= 0;      // not an ARM image: no F6
end
f6_go = (cw_q & !cart_win & fe_loaded) | (rdl == 4'd1);    // window close (= c_close), or rise + 8
```

- **The window close.** `cart_win` falls in the clock where `bup_capture`'s `c_drain == 1` (load_end + 63). The capture takes no byte from then on, so F6's first port-A read registers after the last `cap_we`.
- **A rising `cart_reset`** re-runs F6 eight clocks later. `init_busy` holds the reset, so `cart_reset` stays high (GL 4.2). A falling reset never starts F6, because the bench's and the core's reset is held by `init_busy` until F6 ends (BEN 7.4.2).
- **`load_start`** aborts F6 and any service.
- `init_busy` drives atari7800_pocket's reset register directly (D6).

### 7.2 F6 sequence (exclusive ports, one word per clock)

| Phase | DPC+ (family latched at load) | CDF0/1/J (8 KB) | CDFJ+ (`f6_r32`) |
|---|---|---|---|
| CLR | S words $00-$1F ← 0 (32 clocks): fetchers and params reset (upstream resets them on `mapper != DPCP`) | the same (harmless) | the same |
| P1 | FILL R words $000-$2FF ← 0 (RAM $0000-$0BFF) | COPY A words $000-$1FF → R $000-$1FF (image $0000-$07FF) | the same copy |
| P2 | COPY A words $1B00-$1FFF → R $300-$7FF (image $6C00-$7FFF → RAM $0C00-$1FFF) | FILL R $200-$7FF ← 0 | FILL R $200-$1FFF ← 0 |
| END | `f6_done` (one clock): `init_busy` ← 0 | the same | the same |
| Clocks | 32 + 768 + 1,280 + 2 ≈ 2,082 | 32 + 512 + 1,536 + 2 ≈ 2,082 | 32 + 512 + 7,680 + 2 ≈ 8,226 |

- COPY is a one-stage pipeline: A word i is presented in clock t, and its q is written to R (be F) in clock t+1.
- These are the ranges of `arm_mapper_ram_init.sv:133-176` (I1). Upstream takes 5,261 / 3,481 / 9,625 clocks at `lat` = 20. The difference is absorbed by the hold in mode A (BEN 7.4.2) and counted `f6_len` on hardware.
- During F6, the audio replica, the 6507 and DARIA's CPU are all in reset, so F6 owns R, S and A at priority 0 and ignores the guard (D4: F6 starts ≥ 8 clocks after the rise, while DARIA's CPU is held). `a_f6_live` asserts that `f6_act` implies `rst_quiet`.
- A 29,696-byte DPC+ image: P2 copies image bytes beyond the file. The FE ROM then holds the previous image's bytes there, where upstream reads stale DDR. Counted as `short_image`.

### 7.3 DPC+ copy/fill service (D7)

**The latch** (core, kind 2, 2.3). At max(C, E0+4), for a taken CALLFUNCTION 1/2:

| Field | Value |
|---|---|
| `svc_fill` | `d == 2` |
| `svc_src` | $0C00 + {p1, p0} (17 bits) |
| `svc_dst` | $0C00 + `cnt_st` (13 bits; `cnt_st` = the counter of fetcher p2 & 7) |
| `svc_rem` | p3 (the requested count) |
| `svc_val` | p0 |
| `svc_pend` | 1 |

These are upstream's `service_*` registers (mapper_dpcplus.sv:290-301). The only difference is the count, which upstream clamps at C and this design clamps at run time. The bench forms upstream's count as `min(p3, $1C00 − dst, fill ? ∞ : max(0, $8000 − src))` for R2. That equals `service_fill_count`/`service_copy_count` (`dest_avail = $1000 − cnt`; `src_avail = $7400 − off`, 0 if `off ≥ $7400`).

**The engine** (`u_copy`; no reset except `cart_reset` and `load_start`):

```systemverilog
// accept (= upstream's service accept at C+1): the engine is idle, no F6, no init
svc_take = svc_pend & !run & !init_busy & !f6_act;
// at svc_take: run <= 1; {fill, src, dst, rem, val} <= svc_*
stop = (rem == 0) | (dst == 13'h1C00) | (!fill & src[16:15] != 0);    // the run-time clamps
// FILL: per cp_gnt: word dst[12:2], be = mask(dst[1:0], rem), wd = {4{val}};
//       dst += adv; rem -= adv;  adv = min(4 - dst[1:0], rem)   ($1C00 is word-aligned)
// COPY: ca_req = run & !fill & !stop; ca_a = src[14:2]          (A priority 3, every clock)
//       aw_q <= src[14:2]; av_q <= ca_gnt;                        (the word whose q is valid next clock)
//       cp_req = run & !fill & !stop & av_q & (aw_q == src[14:2])
//       on cp_gnt: byte fea_q[8*src[1:0] +: 8] at dst, be 1 << dst[1:0]; src++, dst++, rem--
//       (one byte per clock inside a ROM word; one bubble per word crossing)
// run & stop -> run <= 0
```

- **Rate.** A 255-byte fill takes about 66 clocks (upstream about 70); a copy about 320 (upstream about 234 at `lat` = 20), less the audio's grants. Both are counted (`dma_len`) and absorbed in mode A by the forced stall (BEN 7.4.2).
- **The audio keeps its slots.** The engine is R priority 5 (D7, CR 21).
- **No writes while `guard_on`** (D4).
- **RMW pair.** A second taken 1/2 while the first is running latches into `svc_*` (because `svc_pend` was cleared at the accept), and the engine takes it when idle. That is upstream's semantics: pending is cleared at accept, and the next waits for `service_ready`. Results are exact; the stall shape is counted `rmw_svc` (hardware and mode B).
- **Count 0.** `stop` is true at once, so the service ends at C+2.
- **A console reset** abandons the service (upstream's DMA finishes, GL 4.3). This is invisible: the 6507 is in reset, and F6 rewrites the whole 8 KB.
- **Class `svc_audio_race`.** An audio grant reads a word in [`dst`, `dst` + count) while either side's copy or fill is running. DPC+ waveforms live in display RAM (exact's `copy_race`).

### 7.4 `arm_dma_busy` (D3)

```systemverilog
if (cart_reset | init_busy)                               dma_busy <= 0;   // forced 0 during init (R2)
else if (dma_set)                                         dma_busy <= 1;   // at C, taken 1/2
else if (dma_busy & !svc_hold & !run & rel_ok)            dma_busy <= 0;   // only while in_phase2
// svc_hold = svc_pend | (pend_c == svc): a deferred latch (short phase 1) keeps it high
```

---

## 8. Phase detector and guard (`daria_fe_guard`, D4)

### 8.1 RTL

```systemverilog
(* altera_attribute = "-name PRESERVE_REGISTER ON" *)
logic pd_tog = 1'b0;                              // the only clk_arm flop in daria_fe
always_ff @(posedge clk_arm) pd_tog <= ~pd_tog;
(* altera_attribute = "-name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION OFF" *)
logic pd_rx = 1'b0;                               // the one constrained receiver (8.2)
logic pd_rx1 = 1'b0;
logic [1:0] ph = 2'd1;  logic [3:0] good = 4'd0;  logic lk = 1'b0;
wire  pd_same = (pd_rx == pd_rx1);                // in (E, E+1): no change at E, so E was shared
always_ff @(posedge clk_sys) begin
    pd_rx <= pd_tog;  pd_rx1 <= pd_rx;
    if (pd_same != (ph == 2'd0)) begin            // mismatch: re-anchor and unlock
        ph <= 2'd1;  good <= 4'd0;  lk <= 1'b0;
    end else begin
        ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1;
        if (good != 4'd12) good <= good + 4'd1; else lk <= 1'b1;
    end
end
assign locked   = lk;
assign phb_next = lk & (ph == 2'd0);              // from the flywheel register, not the receiver
assign guard_on = lk & (call_win | !cpu_ready);
```

**At ÷48/÷18.** The 144-VCO frame holds `clk_sys` edges at 0 (shared), 48 and 96, and `clk_arm` edges every 18. With the constrained path in [1, 6] ns (0.7-4.1 VCO steps):

- the edge at 0 catches the toggles launched at −36 and −18: two, so `pd_rx` does not change;
- the edge at 48 catches 0, 18 and 36: three, so it changes;
- the edge at 96 catches 54, 72 and 90: three, so it changes.

So `pd_same` = 1 exactly in the clock after the shared edge, the flywheel's `ph == 0`. An address presented in that clock registers at 48, the **phase-B edge**: 17.46 ns after the `clk_arm` edge at 36 and 8.73 ns before the one at 54 (D4). The hardware judge's lattice simulation (`judge_tmp/det.py`) confirms the pattern for delays of 1, 3 and 6 ns and for random per-launch delays.

### 8.2 SDC and QSF lines

In `core_constraints.sdc`, beside DC 7.3's ±20 ns `clk_sys`/`clk_arm` exceptions (`-nowarn` because the registers exist only in POCKET_DARIA builds; the pattern style is the file's own, `*|entity:instance|reg`):

```tcl
# DARIA front end: the shared-edge phase detector (docs/DARIA_CORE.md; daria_fe_guard.sv).
# One clk_arm toggle into one clk_sys flop. 6 ns: a toggle launched 8.73 ns before an edge
# is always caught there. 1 ns: the toggle launched on the shared edge is never caught on it.
set_max_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 6.000
set_min_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 1.000
```

**Why they are safe.**

- Both lines are more specific than the clock-to-clock pair, so they take precedence.
- 6 ns < 8.73 ns − setup − skew.
- The fitter-only `-add -hold 0.1` into `clk_sys` only adds margin.

**RTL attributes** (in place of QSF lines, so they travel with the file):

| Register | Attributes |
|---|---|
| `pd_tog` | `PRESERVE_REGISTER ON` |
| `pd_rx` | `PRESERVE_REGISTER ON`, `SYNCHRONIZER_IDENTIFICATION OFF` |
| `u_call.ret_s1`, `u_audio.ack_s1` | `SYNCHRONIZER_IDENTIFICATION FORCED` (DC 7.3) |

**Step-7 STA check** (12.2, step 9):

- `report_timing -from pd_tog -to pd_rx -setup` and `-hold` each list exactly one path, meeting 6/1 ns;
- the fitter's register report shows `pd_rx` neither duplicated nor retimed by physical synthesis;
- the clock-network skew on that path is read off the report (DI:726).

### 8.3 Lock rule and inert cases

- Lock after 12 consecutive predictions that match (four frames). Unlock on the first mismatch.
- `ev_unlock` while `guard_on` was requested counts `det_unlock_active` (hardware; expected 0).

| Configuration | What the detector sees | Result |
|---|---|---|
| ÷48/÷18 (Pocket) | 2/3/3 toggles, period 3 | locks within 3 + 12 clocks of start or of any phase move |
| ÷19 fallback | longest consistent run 4-5 (lattice simulation) | never locks (12 > 5); `guard_on` = 0; back to the counted race (DI 9.3) |
| Mode A (`clk_arm` = 5 × `clk_sys`, or `clk_sys`) | `pd_rx` changes on every edge | never locks (`det_lock_a` must stay 0) |

### 8.4 Bench checks (mode B, `clk_d` aligned, `+d_ofs` ∈ {0, 8730, 17460}; BEN 6.3)

- **`det_bad`.** At every `clk_sys` edge after lock, `pd_same` in the following clock must equal `(($time − d_ofs) % 26190) == 0` at that edge.
- **Lock time.** Lock within 24 `clk_sys` of the run's start.
- **Never in mode A** (`det_lock_a`).
- **Collisions.** `coll_d_same` = 0, and `d_shared_stores` counted as in BEN 6.4, with `crb_use` as the read side.
- **Reverse check.** No `crb_we` from `daria_fe` on a shared edge while `guard_on`, unless F6.

---
## 9. Upstream quirks and counted differences

### 9.1 DPC+ (DPC §14)

| # | Quirk | Here |
|---|---|---|
| 1 | Commit only with `access && a_in[12]` | `commit` (2.1) |
| 2 | Latch and commit share E0+6 | `fe_do` from phase-1 values; state at C |
| 3 | RANDOM0NEXT/PRIOR return the stepped low byte and step at C; RANDOM1-3 are unstepped | `rnd_byte`; `rnd` at C |
| 4 | $006/$007/$024-$027 read $00 | `rnd_byte` 6/7; flag `ix < 4` |
| 5 | DFxFLAG only at $020-$023 | the flag & `ix < 4` |
| 6 | Window flag: 8-bit modular, on the pre-increment counter | `win(stb_q)` in `k[2]` |
| 7 | 12-, 20- and 8-bit wraps | lane writes; spare nibbles |
| 8 | FRACLOW depends on `revision[0]`; FRACHI/HI take `d[3:0]`; FRACINC clears frac[7:0]; LOW keeps [11:8] | the field rows of 2.5 |
| 9 | PUSH writes at counter−1, WRITE at counter; $068-$077 do not touch RAM | `dpw` rows; `d_sel` |
| 10 | RAM strobe at E2-E6 (E1-E6 on a repeated address), not lock-gated | one write at C+1, equal at every observation (2.5); `ram_wr_noaccess` asserted 0 upstream-side (CR 31) |
| 11 | Fast fetch arms on any committed $A9 ROM read; the next committed cart read < $28 anywhere is a register; writes and A12 = 0 do not touch it | `fpend` rules (2.4) |
| 12 | 6-bit register space | `d_rn[5:0]` |
| 13 | Hotspots on reads and writes, old bank's byte, not on a register read | `d_hot`; B@C+1 |
| 14 | `d_out` falls back after C; transients before `rom_do` settles | drift counted (O1); the tb ROM's stale byte is in `sel_up` |
| 15-17 | FASTFETCH = (d == 0); PARAMETER counts to 8, params 4-7 never read; CALLFUNCTION priorities, ignored while pending | 2.4 (`pptr` 4-bit, writes only below 4) |
| 18-19 | Clamps; `params[2] & 7`; a count of 0 still requests; source, destination, value | 7.3 (run-time, equal to `min()`) |
| 20 | Pending at C, accept at C+1, stall from the accept | busy at C (the GL 7.5 window) |
| 21 | Waveform 7 bits; NOTE strobe one clock; voice = a[1:0] − 1 | 2.5 |
| 22 | Reset values; reset on `mapper != DPCP` | `rst_fe`; the F6 state-RAM clear |
| 23 | `ram_sel` windows starve the audio | `sel_up` |
| 24-25 | S1-S5; held repeats re-present the previous address | inputs are upstream's; the release duplicate is removed on hardware (`release_dup`) |
| 26 | `rom_data` is live | the mirror (port B) |

### 9.2 CDF family (CDF §17)

| Q | Here |
|---|---|
| Q1 live predicates, Q2 tables idle at index 32 | live decode; `sel_up`. Index 32 has no RAM effect here: the pointers are in place |
| Q3 arming is byte-based and survives A12 = 0 | commit rules (2.4) |
| Q4-Q7 jump operand rules, `fast_mode` only at arming, jump step, amplitude operand | 2.2, 2.4, 2.6 |
| Q8 stale byte in (E0, E0+1) | the mirror reproduces tb_daria's. The SDRAM transient is out of scope (D1, CR 9) |
| Q9 no bank switch on substituted reads | `c_hot` requires `!c_sub` |
| Q10, Q24, Q27 no ROM refetch on a bank switch or repeated address; reads not A12-gated | SDRAM-only, out of scope; the mirror refetches as the tb ROM does |
| Q11 CDFJ+ wraps mod 32 KB; DSWRITE into the tables | `& $7FFF` (D8); **`tbl_alias`** |
| Q12-Q14 non-plus `P[31:20]`; `inc[15:0]`; the offset is not gated by version | 2.4 |
| Q15 writeback drop | no writeback (`wb_drop` is an upstream-side assertion) |
| Q16 DSWRITE is `access`-gated | the byte is written on the C clock with `we = access` |
| Q17 pending while not ready, no stall | DARIA stalls at C (R12): unreachable |
| Q18 map edges $7FFE/$7FFF; lookahead across bank ends | `rom_a < $7FFE`; linear image |
| Q19-Q22 | inputs as detect2600 gives them |
| Q23 pause | 5.8 |
| Q25 stall phase-2 accounting | top.sv's own logic; `rel_ok` |
| Q26 `pu_val` from the previous edge's index | arises only with a short phase 1: `short_phase1` |

### 9.3 Audio (AUD §16)

Items 1-19 are reproduced by the replica (5.3-5.6):

- the PAL tick constant;
- tick coalescing; a tick at D re-queues;
- NOTE beats refresh; the NOTE overlap table;
- live waveform and digital flags (including voice 1/2's pointer with counter 0, AUD 16.6);
- the mod-256 sum;
- pointer aliasing and windows; the size shift `word[11:7]`; the digital nibble; out-of-range 0;
- the merge rule;
- $FF bytes on pause;
- reset by `effective_reset` only;
- the idle address; no call gating;
- the release window (top.sv);
- launch and merge on one edge (the RMW capture at M_fe);
- the pause freeze.

G8 is applied: `waveform_pointer` is dead and the sum is 8 bits. Two exceptions are counted: the merge edge itself (`merge_amp`) and the sample latency (`dig_rom_lag`).

### 9.4 Glue and bus

| Item | Here |
|---|---|
| Init on `load_end_d` and on a rising reset; busy from `load_start`; family latched at load | 7.1. F6 starts at the window close (`c_close`) or at the rise + 8; durations are counted, absorbed by the hold |
| A reset edge during init is ignored; init survives nothing | `rst_rise` requires `!init_busy`; `load_start` aborts |
| Service/DMA runs through a pause | the engine has no pause input |
| CPU reset on console reset (G6) | `daria_mreset` |
| Release-window duplicate (GL 7.5, G1) | `rel_ok` on both busy signals (D3, CR 2) |
| 29,696-byte DPC+ image (CR 25) | `short_image` |
| `open_bus` | `fe_do` holds the committed byte: `drift_fe`; `obus_exposed` must be 0, except the TIA read at $0000 after a CDF fast JMP's low operand at $1FFF (`obus_ffe`) |
| `rom_ready` waits for an orphaned sample (G7) | `busy_l`/`busy_r` survive `cart_reset` (5.7) |

### 9.5 Counted differences (complete list)

Every class has a condition the bench can evaluate. Anything outside the classes is `dout_bad`, `state_bad`, `ptr_bad`, `ram_bad`, `call_bad`, `svc_bad`, `svc_ram_bad`, `init_bad`, `ram_call_bad`, `ram_frame_bad`, `tick_bad` or `audio_bad`: a failure.

| Class | Condition | What may differ | Mode |
|---|---|---|---|
| `short_phase1` | A cartridge commit with C < E0+6 (`ev_short`; S0 saw none in the set) | that cycle's `fe_do`; CDF Q26 pointer; a grant delayed by `grant_steal` (the replica is offset until both are IDLE, then resynced) | A, B |
| `merge_amp` | CDF call, no hook: a refresh dispatched at D ∈ (M, M_fe+1] | that refresh's AMPLITUDE value; in digital mode also its route timing until IDLE | A, B (0 with the hook) |
| `ret_late` | DARIA's `call_tog` flip came after upstream's complete toggle, so the bench delayed `ret_tog` | information; allows `merge_race` for that call | A |
| `merge_race` | Only with `ret_late`: counters/frequencies differ by the rule of BEN 7.6 | per-tick counters and frequencies (resync) | A |
| `dig_rom_lag` | Digital ROM sample: upstream's `sample_done` later than R+3 (a DDR miss), or `dig_addr ≥ $8000` | the AMPLITUDE edge; replica offset until IDLE (resync) | A, B |
| `svc_audio_race` | An audio grant reads a word in a running copy/fill's destination range (either side) | that refresh's value | A, B |
| `pause_lane` | A sample capture on an unpaused edge right after a grant edge in a pause, whose last unpaused edge p had the select high, with upstream's lane register (`mapper_read_lane`) and `al` differing, and each holding what it loaded at p: `mapper_read_lane` the port's address lane (the 6507's, the select being high), `al` the engine's `a_d[1:0]` (the stage-1 shadow's condition; `tb_fe_audio` and the random bench use wider ones, lanes/F1_fixes.md 2). Any other lane difference at a capture is `audio_bad`, so an `al` that loads at another edge or another value fails even after such a pause. Not on the Pocket, which never pauses (F1_fixes.md 2) | one sample byte: the sum and AMPLITUDE, until the next refresh rewrites them (no resync) | A (directed), B |
| `pre_lock` | Refreshes with a grant before `tia_en` (BIOS path; upstream reads the 7800 path's RAM address, AUD 12.6) | AMPLITUDE until the first refresh after `tia_en` | A |
| `tbl_alias` | A CDFJ+ DSWRITE byte address in [$098, $1B0) (pointer and increment words) | that stream's pointer and data, until the ARM rewrites the word; C3 excludes that stream | A, B |
| `rmw_call` | A CALLFN while `call_busy`, or committed after X (C-3) | the stall shape (no dip); CDF call-2 seeds iff a tick lands exactly on M, or (C-3) between upstream's accept and DARIA's capture at M_fe+2 | A (value), B |
| `rmw_svc` | A taken 1/2 while a service is pending or running | the stall shape | B |
| `short_image` | A DPC+ image shorter than $8000 bytes, after a larger one | RAM bytes copied from beyond the file | A |
| `live_override` | Scheme override changed without a reload or reset | DPC+ fetchers in state RAM keep their values (upstream: flip-flops reset); F6 family stays latched | A, B |
| `size_over32k` | `ev_size_hi`: `audio_size_addr + 8 > $7FFF` | that SIZE read (upstream addresses 128 KB) | A, B (expected 0) |
| `drift_fe` | O1: `fe_do` holds the committed byte after the latch | information; `obus_exposed` must be 0, except `obus_ffe` (below) | A |
| `obus_ffe` | O1: the TIA read at $0000 right after the low operand of a CDF fast JMP whose opcode is at $1FFE (upstream's `jump_substitute` at $1FFF with `jump_remaining` 2; the 13-bit address wraps), with the undriven bits holding the byte `daria_fe` latched at $1FFF on its side and ROM[$1FFF] on upstream's | that read's undriven bits: `fe_do` holds the substituted byte, upstream's `d_out` has fallen back to ROM[$1FFF]. One read: the 6507 then jumps to the target. On hardware the undriven bits most likely keep the cartridge's last driven byte, as `daria_fe`'s do. No game does it. A fast `LDA #` at $1FFE (CDF or DPC+) is not in the class: its next opcode comes from the TIA, so $0001 is exposed too (F1_fixes.md 3) | A |
| `rst_release` | A console reset released inside a 6507 cycle whose commit sets an action that waits for a ready flag, with `rst_fe` still high at an edge from the one that sets that flag up to C−1 (and low at C): the edge that samples k[3] (E0+4) for `rdW` and `rdS` (a DPC+ DFxDATA/DATAW/FRACDATA read, PUSH, WRITE or CALLFUNCTION 1/2), the edge that samples k[2] (E0+3) for `rdP` (a CDF DSWRITE or DSPTR: its P32 read is captured at E0+2, or at E0+3 on the retry in k[2], and `rst_fe` at E0+3 clears the first and loses the second). The flag stays 0 to the cycle's end, the action is still pending at `pclk1`, and `daria_fe` drops it there (2.3); upstream performs it. A bench sees it as `u_core.rcyc` at a `pclk1` with an action still pending. Not reachable from 6507 code (lanes/E3_rtl_issues.md, issue 1) | that cycle's access, its latch and the words it touches (the fetcher's state words, the DSWRITE byte and P32, a service's copy), resynced after it | A (`tb_fe_core`'s `rrel`: DFx reads, PUSH/WRITE, DSWRITE, DSPTR; the random bench with `+rst_bus=1`: DPC+ DFx reads only, since its reset cycles are reads. No bench strands a CALLFUNCTION 1/2, lanes/F1_fixes.md 1) |
| `refresh_overlap` | Only if lever 1 (drop `rc`) is taken: a tick or merge during a refresh | that refresh's value | A, B |
| hardware and mode B only | `call_len`, `dma_len`, `f6_len` (durations); `release_dup` (removed duplicate commit); `guard_shift` (grants moved to phase B); `pause_call` (DARIA's CPU runs during pause; mode B only, since the Pocket never pauses); `reset_in_call`; `det_unlock_active` | timing only | B |

### 9.6 Must be 0

| Group | Counters |
|---|---|
| Classes absent by construction | `seed_race`, `note_race`, `amp_lag`, `amp_input_race`; `merge_race` without `ret_late`; `tick_bad` |
| Bench assertions | `over32k`, `wb_drop`, `ram_wr_noaccess` (upstream side); `obus_exposed` (outside `obus_ffe`); `hold_bad`; `commit_on_hidden` (a `daria_fe` commit on `pclk0 && !mapper_phi2`); `commit_pclk1` (a `daria_fe` commit in a clock with `pclk1` high: top.sv makes it impossible, 2.3, lanes/F1_fixes.md 1; a guard against a change of top.sv's phases); `hidden_last_bad` (S0 C.5); `ret_unasked`; `det_bad`, `det_lock_a` |
| RTL assertions | `a_collide` (`grant_steal` outside `short_phase1`), `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr`, `a_fpjr` (`!(fpend & jr != 0)` in CDF), `a_pend_late` (a commit action still pending at the next `pclk1`, except at the end of a cycle that ran some of its k reads under `rst_fe`: `rcyc`, a flop only the assertion reads), `a_tdef2`, `a_f6_live` |
| Every-clock oracles | A1 (audio registers against upstream's, outside the class masks), A2 (`sel_up == sel_ram_sel`), A3 (one owner per port; `crb_use` consistent) |

---

## 10. ALM estimate, area gate, critical paths

### 10.1 Per module (MUX_RESTRUCTURE OFF, enable-style coding as in D10)

| Module | ALMs [E] | FF [E] | Basis |
|---|---|---|---|
| `daria_fe` (top) | 10 | 6 | scheme decode, `rst_fe`, `scheme_q` |
| `daria_fe_seq` | 10 | 13 | |
| `daria_fe_dec` | 70 | 0 | DPC+ decode 16, CDF decode 38, `sel_up` and hotspots 16 (simple 10.1) |
| `daria_fe_core` | 400-460 | ~310 | simple's core with its own W, adder and B (the hardware judge's 480-540, including the decode), less the precomputed clamps (−30), plus the ready flags and pending descriptors (+20) |
| `daria_fe_audio` | 520-580 | ~760 | The hardware judge's re-estimate of simple's replica: the ring as a 3:1 mux on 192 bits (~96), counters with folded muxes 48, frequencies 48, `rc` 34, shifter 36, sample address 25, `woff` 21, digital adder and compares 47, FSM/sum/notes/AMPLITUDE about 90, sample client 20. Deferral adds about 5. Anchor: upstream's live `arm_mapper_audio` is 657 ALMs with BUS and full-width paths |
| `daria_fe_call` | 35-45 | ~28 | FSM, toggles, `cnum`, the F0/F1/`ring0` data mux |
| `daria_fe_copy` | 85-110 | ~95 | F6 sequencer, fill masks, copy byte path, run-time stop tests |
| `daria_fe_arb` | 110-140 | ~6 | R address (6 owners × 13) 25, R data and be 31, S address and data 35, A address 10, grants 10 |
| `daria_fe_guard` | 15-20 | 10 | |
| **Total** | **1,255-1,445, mid ≈ 1,350** | **~1,230** | |
| New M10K | 0 | | `daria_mem`'s FE ROM, cart RAM and state RAM (upstream's 8 table/map M10K are gone) |

### 10.2 Device projection

- Device: 18,480 ALMs. The 84% gate is 15,523.
- Everything but the front end is 14,022-14,282 (DC "Budget", less its 850-1,100 front-end line). That leaves **1,241-1,501 ALMs** for `daria_fe`. The realistic budget is 1,240-1,320, because step 5's wrapper build suggests the upper half (hardware judge 0.2).
- At mid 1,350 the device is at 83.2-84.6%, and the range is 82.7-85.1%. **This design sits on the gate.**
- The owner accepts more area for correctness (D10), but asks for headroom. So the plan carries a gate and an ordered set of levers, and the exact audio is kept only while it fits.

### 10.3 Probe gates, levers, fallback

**Owner's note (2026-10-07).** DARIA is meant as the 7800 core's last major revision, so spare area matters only as far as routing and timing closure need it. The gates below are guides for spotting an overrun early, not targets: a lever is applied only if it keeps every exactness result, or if step 7's fit or timing needs it.

**Probes.** Each block is compiled alone with the study's probe method (`frontend_study/run_study.sh`: virtual pins, the core's settings, 69.8 ns) as soon as its unit bench passes. The targets:

| Block | Target ALMs |
|---|---|
| core + dec | ≤ 500 |
| audio | ≤ 560 |
| arb | ≤ 130 |
| copy | ≤ 100 |
| call | ≤ 45 |
| `daria_fe` whole | **≤ 1,300** |

The decision points are step 2 of 12.2 (`daria_fe` alone) and the step-7 full fit (device ≤ 84%).

**Levers, in order of exactness cost:**

| # | Lever | Saves | Cost in exactness |
|---|---|---|---|
| 1 | Narrow `dig_addr` to 20 bits plus a "high bits non-zero" flag; route compares on 20 bits (exact: `rom_size` ≤ 512 KB) | 15-25 | none |
| 2 | Apply each return word as it arrives (`stb_q` direct), keeping the ring for the payload only; deferral unchanged | 20-30 | none for counters and frequencies; the `merge_amp` window is unchanged |
| 3 | Drop the `rc` snapshot (refresh reads live counters) | 35-50 (−96 FF) | `refresh_overlap` (rare: a tick or merge during a refresh) |
| 4 | **Fallback `daria_fe_audio_lean`**: lean's state-RAM audio (`lean.md` §5, with the judges' fixes: tick-at-M sample from the return word, pending-aware deposit, 3-bit `tb`) behind `daria_fe_audio`'s ports, plus the S owner reserved in `fe_arb` (priority 1.5, tied off today). It replaces `u_audio` and the RD/APPLY part of `u_call` | 200-250 | `amp_lag`, `amp_input_race` (counted); NOTE and seeds by logical ordering |

Lever 4 is a planned swap behind fixed ports, not a redesign. It is started only if the gate fails after levers 1-3.

### 10.4 Critical paths (`clk_sys`, 69.84 ns)

| Path | Levels [E] | Delay [E] |
|---|---|---|
| `feb_q` (M10K t_co) → lane mux → CDF predicates (13-bit equality, 9-bit range) → `sel_up` → `aud_take` → R owner → R address | ~9 LUT + 1 short carry | 18-24 ns |
| `rc` → 3:1 → 32→15 shifter → 15-bit add → mask → R address | ~10 LUT + 1 carry | 22-28 ns |
| `feb_q` → decode → `norm` (8-bit subtract) → `pb + idx` (9-bit add) → R address | ~7 LUT + 2 carries | 15-18 ns |
| `crb_q` → `W + inc<<12` (32-bit carry) → W | 2 LUT + carry | 8-10 ns |
| `access` (top.sv: TIA divider → pairing → `mapper_phi2`) → DSWRITE R `we` | top's ~5 + ~3 | 12-18 ns |
| `stb_q` → `stb_q != ring[0]` (32-bit compare) → `take` | ~4 LUT | 6-8 ns |

- Every stage is a register or M10K q → logic → register or M10K input.
- Worst slack is about +40 ns.
- Nothing starts in `clk_sdram`: `d_in` = `write_DB`, `fe_do` is a register, and `rom_addr`/`ram_sel` for these schemes are constants in cart2600.
- The only cross-clock path is the detector, which has its own pair (8.2).
- The FE→audio coupling through `sel_up` in one clock (hardware judge §1) is about 24 ns and needs no register.

---

## 11. Risks and first tests

### 11.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Area at the 84% gate | Probe gates and levers (10.3). The audio is probed alone first |
| 2 | `sel_up` differs from upstream's select in some clock (stale byte, offset window, held cycle, BIOS path) | A2 every clock in the unit bench and in mode A; the first differing clock points at the term |
| 3 | The D10 rewrite of the replica changes its next-state function | `tb_fe_audio` compares every register every clock with `arm_mapper_audio` on random streams |
| 4 | The ready rule (2.3) has an untested corner (short phase with a P32 refusal, a deferred service, the next E0) | Random phase streams in `tb_fe_core`/`tb_fe_arb` with phase-1 lengths of 2, 4 and 6 and stretched phases; `a_pend_late`, `a_wb_late`; the directed RSYNC test |
| 5 | Tick deferral or the ring swap has an off-by-one at M, M_fe or M_fe+1 | `tb_fe_call` tick-placement sweep (12.3) over M−2 … M_fe+3 and L−2 … L+2, against a behavioural upstream merge |
| 6 | Exactness depends on tb_daria's 1-clock ROM | It is the stated target (D1, CR 9); hardware needs no upstream match |
| 7 | Guard SDC precedence, skew and retiming in Quartus 21.1 | The step-7 STA check (8.2); `PRESERVE_REGISTER`; `det_bad` in mode B |
| 8 | The ÷19 fallback: no exact shared edge, guard inert | Back to the counted race (DI 9.3) |
| 9 | M10K NEW_DATA_NO_NBE_READ and mixed-port behaviour unverified | Never relied on (1.5 rule 3). The poisoned `daria_ram` model proves it in the unit benches (12.1) |
| 10 | Paths the image set does not exercise: hotspots/bank switching (none in 300 frames, S0 C.3), DPC+ copy/fill and PARAMETER, CDF0, digital audio, RSYNC, hard reset, RMW CALLFN, pause, BIOS | Directed tests (12.1) and the random differential bench |
| 11 | Wrapper additions untested in step 6: `cart_win` export, the sample requester over PSRAM | Emulated in mode A; tested at step 7 with `WRAPPER=1` |
| 12 | `cpu_ready` on hardware rises late after a return (the release waits for it) | Measured as `call_len` in mode B; the release rule keeps it safe |

### 11.2 Test first (in this order)

1. **`tb_fe_audio`**: `arm_mapper_audio` against `daria_fe_audio`, every register every clock (A1). It tests the riskiest and largest block first, and its area probe is the first gate.
2. **`tb_fe_core`**: `fe_core` + `dec` against upstream `mapper_dpcplus`/`mapper_cdf` on a synthetic bus with the tb ROM model. `fe_do` at every latch, state after every cycle, RAM bytes and pointers, and `sel_up` against `sel_ram_sel` **every clock** (A2), including short and stretched phases.
3. **`tb_fe_guard`** on the VCO lattice: ÷48/÷18 at three phases and random delays, ÷19, 5×.
4. **Mode A, stage 1**, on SF2fix (DPC+), Galagon (CDFJ) and draconian (CDF1) for 120 frames, with and without `+fe_merge_hook`.
5. **Directed tests** (12.1), then the random differential bench.

---

## 12. Implementation plan

### 12.1 Files

**RTL** (`BUP/` = `src/fpga/core/bupchip/`; all new, MIT, step 6):

| File | Content | Owner lane |
|---|---|---|
| `daria_fe_pkg.sv` | 1.3 | 0 (frozen first) |
| `daria_fe.sv` | top: ports (1.2), instances, scheme decode, `rst_fe`, `fe_oe` | 0 |
| `daria_fe_seq.sv` | 2.1 | A |
| `daria_fe_dec.sv` | 2.2 | A |
| `daria_fe_core.sv` | 2.3-2.6 | A |
| `daria_fe_audio.sv` | 5 | B |
| `daria_fe_call.sv` | 6 | C |
| `daria_fe_copy.sv` | 7 | C |
| `daria_fe_arb.sv` | 3 | D |
| `daria_fe_guard.sv` | 8 | D |

**`daria_mem.sv`: the `stb_be` item.**

- No RTL change is needed. State RAM port B's byte enable is already built and wired:
  - `stb_be` port at daria_mem.sv:159, `.be_b(stb_be)` at :203;
  - `daria_stb_be` at bupchip_pocket.sv:177 and :360.
- Step 6 adds only a **simulation-only poison option** to the `daria_ram` behavioural model (the `` `else `` branch of `` `ifdef ALTERA_RESERVED_QIS ``), under `` `ifdef DARIA_RAM_POISON ``:
  - (a) after a write with a partial byte enable, the next clock's q shows $A5 in the bytes not enabled (NEW_DATA_NO_NBE_READ is "don't care");
  - (b) a same-clock read on one port of a word written on the other port returns $A5A5A5A5 (mixed-port read during write is undefined).
- The unit benches build with it, to prove contract rule 3 (1.5). The default model is unchanged, so existing benches are byte-identical.

**Step 7 (not step 6; listed so the interfaces are fixed now):**

- `top.sv`, `cart2600.sv` (`POCKET_DARIA`/`NO_ARM_MAPPER` blocks, 1.6);
- `atari7800_pocket.sv` (instance; `init_busy` into reset and `.loading`);
- `bupchip_pocket.sv` (`daria_cart_win`; the sample requester);
- `core_constraints.sdc` (8.2);
- `mister/POCKET_CHANGES.md`;
- `docs/DARIA_CORE.md` ("The front end": replace the slot schedule with this design).

**Bench** (`D/` = `sim/bupchip/daria/`):

| File | Change |
|---|---|
| `fe_shadow.svh` | **Stage 1** (BEN 7.4-7.7), see 12.4. The stage-0 reference instance and its checks stay. A `FE_STAGE0` define builds the reference-only bench for regression |
| `fe_taps.svh` | **New.** Maps the taps of 1.7 to the comparison functions: DPC+ fetcher fields from state RAM words (masks `FFFF0FFF`/`FF0FFFFF`); params from word $10; `pptr`; CDF state; audio registers; the call FSM. Holds the `fe_deposit_audio` task (a full-state deposit at a falling edge, only while both engines are IDLE with `!tdef & !mwin & !rp & !np`) |
| `run_daria.sh` | `FE=1`: set `BUP` in the FE branch too (BEN 7.2 correction); `SRCS+=("$BUP/daria_fe_pkg.sv" "$BUP"/daria_fe_{seq,dec,core,audio,call,copy,arb,guard}.sv "$BUP/daria_fe.sv")`, plus `"$BUP/daria_mem.sv"` unless `SHADOW=1` already adds it; `INCS+=("$HERE/fe_taps.svh")`; `-DDARIA_RAM_POISON` with `FE_POISON=1`. The `OBJ`/`PREFIX` rules from stage 0 are unchanged |
| `tb_daria.sv` | Under `FE_SHADOW`: the forward-declared `fe_hold_reset` in the `reset` term (BEN 7.2 (2)); `+hard_reset_at` exists since S0 |
| `run_all.sh`, `dynamic_tables.py` | `sec_fe` gains the new columns and classes (9.5) |
| `daria_shadow.svh` | Mode B (later, 12.2 step 8): `clk_d` alignment, `+d_ofs`, and the `FE_SHADOW` switch that connects `daria_fe`'s call port to `dcall` |

**Unit benches** (`D/fe_unit/`, Verilator, one `run_unit.sh`):

`tb_fe_seq.sv`, `tb_fe_core.sv`, `tb_fe_audio.sv`, `tb_fe_call.sv`, `tb_fe_copy.sv`, `tb_fe_guard.sv`, `tb_fe_arb.sv`, and `phase_gen.svh`, a shared random 6507 phase and bus generator with legal cycles. 12.3 gives what each proves.

**Directed tests** (`D/fe_dir/`).

- `mkimg.py` builds synthetic images: 6507 code, plus small hand-encoded Thumb routines for the calls (return, change frequencies, rewrite a waveform pointer, write cart RAM). **No game data.**
- `run_dir.sh` runs each through tb_daria `FE=1` in mode A, so upstream's ARM runs the calls.

| Test | Covers |
|---|---|
| `dpc_regs` | every DPC+ register; fast fetch on data bytes; PUSH/WRITE wraps; FRACLOW on both revisions; PARAMETER to 8 |
| `dpc_svc` | copy and fill with each clamp (count 0, `off ≥ $7400`, `cnt` near $FFF, the source reaching $8000), the RMW pair, a service during audio |
| `dpc_note` | NOTE with ticks at C+3/C+4/C+5 and during a refresh |
| `cdf_fetch` | offsets and the amplitude operand on every revision; LDX/LDY on CDFJ+ |
| `cdf_jump` | jumps at $xFFE/$xFFF and at image $7FFE; bank-end lookahead |
| `hotspot` | bank switching on reads and writes (none in the image set) |
| `dsw` | DSWRITE/DSPTR, including the CDFJ+ wrap into the tables (`tbl_alias`) |
| `digital` | RAM-window samples, ROM < 32 KB, ROM ≥ 32 KB (the request port, `+fe_slat` 5..200) |
| `cdf0` | the CDF0 layout ($1B8/$1DA tables, waveform base $7F0) |
| `rmw_call` | `INC $1FF3`/`INC $105A` with FE→FF, ticks at M and in (M, M_fe] |
| `rsync` | a mid-line RSYNC giving 2- and 10-clock phases (`short_phase1`) |
| `hard_reset` | `+hard_reset_at` in a call, in a service, and during F6 |
| `bios` | `use_bios` (`pre_lock`) |
| `pause` | pause in phase 1 and phase 2, in a call, in a service |

**Random differential bench** (`D/fe_rand/`: `tb_fe_rand.sv`, `run_rand.sh`).

- Upstream's cluster, wired as cart2600 wires it: `mapper_dpcplus`, `mapper_cdf`, `arm_mapper_tables`, `arm_mapper_writeback`, `cdf_fastjump_table`, `arm_mapper_audio` and the cart RAM port model. It stands against `daria_fe` + `daria_mem`.
- The two sides are driven by `phase_gen.svh`: random legal 6507 cycles, phase-1 lengths of 2, 4, 6 and stretched, phase 2 of 6/10, pauses, held repeats.
- Random images with planted $A9/$A2/$A0/$4C patterns, bank-end jumps and hotspots.
- Random scheme, revision and options.
- An ARM agent writes cart RAM on `clk_arm` edges to both sides. It answers calls after random delays with random returns: `ret_tog` for `daria_fe`, and `call_done` two `clk_sys` flops later for upstream, as its controller would.
- A DMA model holds the 6507 while either side's service runs.
- Checks: L1, C1/C2, C3/C4, R1-R3, T1/T2, A1/A2/A3 and the assertions.
- Target: 10^8 6507 cycles over seeds, all bad counts 0 outside the classes.

### 12.2 Order of work

| Step | Who | Work | Gate to pass |
|---|---|---|---|
| 0 | one engineer, first | `daria_fe_pkg.sv`, `daria_fe.sv` and every submodule as a **header with tied-off outputs**, exactly 1.4's ports. Verilator `-Wall` lint and Quartus analysis of the empty shell | interfaces reviewed and frozen; any later port change needs the lead's sign-off |
| 1 | five lanes in parallel | **A**: seq, dec, core + `tb_fe_seq`, `tb_fe_core`. **B**: audio + `tb_fe_audio`, and the audio area probe as soon as it passes. **C**: call, copy + `tb_fe_call`, `tb_fe_copy`. **D**: arb, guard + `tb_fe_arb`, `tb_fe_guard`. **E**: bench stage 1 (`fe_shadow.svh`, `fe_taps.svh`, `run_daria.sh`), `phase_gen.svh`, `mkimg.py`, the random-bench harness with the upstream cluster | each module's unit tests (12.3) pass; each block's probe is within its target (10.3) |
| 2 | lead | Integrate; lint; probe `daria_fe` alone | ≤ 1,300 ALMs, else levers in order (10.3) |
| 3 | lead + E | Mode A on SF2fix, Galagon and draconian, 120 then 300 frames, with and without the hook | every bad count 0; classes only as 9.5; the stage-0 reference still 0 |
| 4 | E | Random differential bench to 10^8 cycles | 0 outside the classes |
| 5 | A-D | The directed tests | all pass; every class seen is explained |
| 6 | E | 21 images × 1,500 frames, mode A (hook on a subset) | 0 outside the classes; class counts tabulated |
| 7 | E | `+hard_reset_at` once per scheme; `use_bios`; pause | the same |
| 8 | D + E | Mode B: `clk_d` aligned, `+d_ofs` ∈ {0, 8730, 17460} | `det_bad` 0, lock ≤ 24 clocks, `coll_d_same` 0, no write on a shared edge while `guard_on` |
| 9 | lead (project step 7) | Wrapper wiring (1.6), SDC, full fit, the STA checks (8.2); docs | device ≤ 84%; the guard path's report as in 8.2 |

### 12.3 Unit tests per module (the proof before integration)

**`daria_fe_seq`** (`tb_fe_seq`):

- `k`, `c`, `ph2` for random phase streams (6/6, 2/6, 4/6, 6/10, stretched, pause in either phase, held cycles);
- `rel_ok` is never true at a `pclk1` edge and always true from the `pclk0` edge to the next `pclk1`;
- a model 6507 with a busy released only on `rel_ok` never commits a held address twice;
- `ev_short` exactly when C < E0+6.

**`daria_fe_dec` + `daria_fe_core`** (`tb_fe_core`). Upstream `mapper_dpcplus`/`mapper_cdf` + `arm_mapper_tables` + `cdf_fastjump_table` + the tb ROM model, against `core` + a reduced `arb` (audio replaced by a random requester) + `daria_mem` with `DARIA_RAM_POISON`:

1. `sel_up == sel_ram_sel` on every clock (A2), including the stale byte, offset windows, CDFJ+ LDX/LDY, held repeats and 7800-mode addresses;
2. `fe_do` at every latch for C = E0+6 and stretched phases;
3. every scheme register after every cycle, including short phases: DPC+ exact; CDF exact except Q26-classified cycles;
4. RAM bytes and pointer words after every cycle (C3/C4), with the pointer landing between C+1 and C+2;
5. `jok` against the upstream map for every address of random images;
6. no core R use outside `sel_up` for C ≥ E0+6 (`a_collide` 0); `a_wb_late`, `a_p32_late`, `a_pend_late` and `a_fpjr` 0;
7. the service latch fields against upstream's `service_*` (count via `min()`);
8. `rst_fe` on scheme switches.

**`daria_fe_audio`** (`tb_fe_audio`). `arm_mapper_audio` against `daria_fe_audio`, both driven by the same random `sel_ram_sel` stream (realistic runs), the same random cart RAM image (waveform tables, pointers in and out of the CDFJ+ window, size words, digital pointers into ROM/RAM/out of range), random NOTE strobes, launches and merges, `cdf_dig` toggles, pause, and a ROM responder with hit/miss timing:

1. **Every register every clock** (A1): `st`, `voice`, grant, `aud_addr`, `amplitude`, `amp_nx` against the next `amplitude`, counters, frequencies, `rc`, `rp`, `np`, `wsh`, `woff`, `ssum`, `dig_*`. Merges are driven through the hook path at upstream's M, so the result is exact.
2. With the own merge path (`cp_*` from a model of `u_call`'s timing), a **tick-placement sweep** with the tick at M−2 … M_fe+3, for changed and unchanged counters and frequencies:
   - counters and frequencies equal upstream's at M_fe+2;
   - `merge_amp` only for dispatches in (M, M_fe+1];
   - `a_tdef2` 0.
3. The ring: capture at L with ticks at L−2 … L+2; the post rotation; the RMW swap at M_fe and at M (DPC+).
4. The sample client: local timing (amplitude at R+4 with and without a `k[0]` conflict); the remote protocol with random latency; an orphaned request across `cart_reset`.

**`daria_fe_call`** (`tb_fe_call`). The module + `daria_call.sv` + `daria_mem` state RAM + a scripted stand-in for `bup_cpu`'s call interface (`parked`, `returned`, `ro_*`):

1. F0-F7 contents and edges (C+1 … C+8); the flip edge; FLIP waiting on `cpu_ready`;
2. F8 issued in the clock `ret_new` is first seen; six consecutive reads; `take`; APPLY at X+7; `mwin` covering exactly X+2 … X+7;
3. release only on `rel_ok & cpu_ready`;
4. RMW `pend2` for both schemes; `pend_up` against a model of upstream's `call_pending`;
5. `cart_reset` in every state: `call_tog` kept, `ret_seen` re-synced, a late `ret_tog` ignored (`ev_ret_unasked`);
6. hook mode.

**`daria_fe_copy`** (`tb_fe_copy`). The module + `daria_mem` against a behavioural model of `arm_mapper_ram_init`'s image and upstream's service arithmetic:

1. F6 images for DPC+, CDF 8 KB and CDFJ+ (I1/I2); the state-RAM clear;
2. triggers: the `cart_win` fall, rise + 8, no start on a fall, a rise during F6 ignored, `load_start` aborting;
3. `init_busy` continuity from `load_start` to F6's end, and its drop for non-ARM images;
4. the service: random params against `min()` and the byte results; count 0; the source reaching $8000; the RMW queue; audio yields; no write under `guard_on`;
5. `arm_dma_busy` falls only on `rel_ok`, stays high through a deferred latch, and is 0 during init.

**`daria_fe_arb`** (`tb_fe_arb`). Random requesters on every port, with phase streams, a random `sel_up`, random guard lock and phase:

1. one owner per port per clock; the priority orders of 3.1-3.3;
2. yields never take an audio edge; `aud_take` equals the reference rule;
3. under `guard_on`: no non-F6 R write, every R read registered on a `phb_next` edge, suppressed requests parked;
4. `crb_use` marks exactly the consumed reads;
5. `own_*` taps one-hot.

**`daria_fe_guard`** (`tb_fe_guard`). `clk_sys`/`clk_arm` generated on the VCO lattice (VCO/48, VCO/18) with per-launch path delays in [1, 6] ns and three phase offsets; ÷19; 5×; coincident:

- lock within 24 clocks at ÷18;
- `pd_same` against the edge arithmetic, and `phb_next` on phase B;
- never locked at ÷19 or 5× over 10^6 edges;
- re-lock after a phase move (PLL relock).

### 12.4 Bench stage 1 in `fe_shadow.svh` (mode A)

**Instances.**

- `fe_mem`: `daria_mem #(.WIN_KB(32))`, as BEN 7.4.1.
- `u_fe`: `daria_fe`. All inputs are **continuous assigns** of DUT signals, or NBA-updated bench state (S0 C.2.2):

| Input | Driven from |
|---|---|
| `a_in` | `dut.cart2600.a_in` |
| `d_in` | `dut.write_DB` (tap check: equal to `dut.cart2600.d_in` on every write cycle) |
| `rw` | `dut.RW` |
| `pclk1`, `pclk0` | the DUT's phase enables |
| `access` | `dut.cart2600.arm_access` |
| `cart_reset` | `dut.effective_reset` |
| `pause` | `dut.pause_core` |
| detect wires, `rom_size`, `ram32`, `load_start`/`load_end` | as stage 0 |
| `cart_win` | emulated: `load_start \| open \| drain > 1`, with DRAIN 64 |
| `cpu_ready` | as 6.6 |
| `clk_arm` | the bench's upstream `clk_arm` |
| `ret_tog` | per call number (6.6) |
| `smp_*` | emulated (5.7) |
| `hk_*` | from upstream's `call_done` and returns when `+fe_merge_hook=1` |

**Bench machinery.**

- The ARM-write mirror into `fe_mem` cart RAM port A (BEN 7.4.3; writeback and DMA writes excluded).
- The return words into state RAM F8-FD (BEN 7.4.4).
- The sticky hold (BEN 7.4.2) with the forced `arm_call_stall` covering `u_fe.arm_dma_busy`; H1.

**Checks.** The stage-0 reference instance stays beside `u_fe`. A mismatch where the reference agrees with upstream is `daria_fe`'s.

- L1 (both), L3; `commit_on_hidden`, `hidden_last_bad`;
- C1/C2 via `fe_taps.svh` (`pptr` compared directly; `call_pending` from `pend_up`; `service_pending` from `svc_pend`);
- C3/C4;
- R1 (posts in `cnum` order against upstream's accept payload; offset histogram);
- R2 (fields; count by `min()`), R3;
- I1/I2 at the first edge where both inits are done;
- K1 at each upstream call start, K2 per frame;
- T1 (same edge);
- T2: at each tick edge, except a tick in (M, M_fe+1] of a CDF call, which is compared at M_fe+2;
- T4;
- A1 (every clock, masked by the active classes), A2 (every clock), A3;
- O1;
- S1;
- the RTL assertions of 9.6.

**Classes** are evaluated as in 9.5. After a classified audio divergence, `fe_deposit_audio` resyncs at the next falling edge where both engines are IDLE with nothing pending. `resync` counts it.

**`fe.csv`.** BEN 7.7's header plus `merge_amp`, `ret_late`, `dig_rom_lag`, `svc_audio_race`, `pause_lane`, `pre_lock`, `tbl_alias`, `rmw_call`, `rmw_svc`, `short_phase1`, `grant_steal`, `a_*` (one column each), `crb_use`, then the remaining counters in the bench's enum order, `obus_ffe` and `commit_pclk1` last.

### 12.5 Done criteria for step 6

1. All unit benches pass, and every block is within its probe target or a lever was taken and documented.
2. Mode A:
   - the 21 images × 1,500 frames, the random bench (10^8 cycles) and every directed test show 0 in every bad counter;
   - only the classes of 9.5 occur, each with its condition met (`rst_release` included, which only the unit bench's release epochs and, for DPC+ DFx reads only, the random bench's `+rst_bus=1` produce);
   - with `+fe_merge_hook=1` on the three stage-0 images, no AMPLITUDE class occurs except `dig_rom_lag` (draconian only).
3. Mode B: the guard checks of 8.4 are 0.
4. The stage-0 regressions are unchanged (S0 C.3).

---

## Appendix A. Traceability

### A.1 Judges' findings on simple, and where each is fixed

| Finding (judge) | Fixed in |
|---|---|
| F-S1 / W-S1, all three: short phase 1 drops write-backs (fatal) | 2.3 ready rule; 2.8; 12.3 core test 3 |
| W-E5 / F-S1: the service latch takes stale clamps at C = E0+2 | 2.3 kind 2 (latch at max(C, @4)); 7.3 run-time clamps |
| W-S2 (risk): contradictory shared-register reset | 2.4 single `rst_fe`; the audio on `cart_reset` |
| W-S3 (risk, exactness): merge at M+7 | 6.3 early F8; 5.6 deferral (counters exact; `merge_amp`) |
| W-S4 (risk): short-phase `a_collide` | 3.1 `!fix_eff` in `aud_take`; `ev_grant_steal` |
| W-S5 / W-E2 (risk, hardware): case-style replica | 5.3, 5.4 per-register tables |
| W-S6 (risk) and hardware 0.3: optimistic area | 10.1 re-estimate; 10.3 gates |
| W-S7 (risk): `pre_lock` missing | 9.5 |
| `live_override`, `size_over32k` missing (risk §5) | 9.5 |
| Hardware: P32 not guard-aligned | 3.5 suppressed under `guard_on` |
| Hardware: F6 counts 64 itself | 7.1 `cart_win` fall |
| Hardware: receiver named `st` | 8.1 `pd_rx`/`pd_tog` |
| Hardware: ring underestimated | 10.1 |
| Hardware (exact): `wbuf_v` not reset | `wb_v` is reset by `rst_fe` (2.4) |
| Exactness 4.1 (lean, applies to any merge): tick exactly at M | 5.6 table, row T = M |

### A.2 Grafts

| Graft | From | Where |
|---|---|---|
| Wait-for-ready post-commit writes | exact (`rdy`) | 2.3 |
| Single front-end reset | exact | 2.4 |
| `!u_fe` in the grant, `grant_steal` | exact | 3.1, 3.6 |
| Early F8 read in (S2, S3) | exact | 6.1, 6.3 |
| One-tick merge correction, as deferral | exactness judge §6.1 | 5.6 |
| 4-bit `pptr` to 8 | exact | 2.4 |
| DPC+ RMW launch at M | exact | 6.4 |
| Local sample at hit timing R+4; orphaned `sample_busy` | exact | 5.7 |
| Register reference format; A1/A2/A3; `fe_deposit_audio` | exact | 2.4, 5.3, 9.6, 12.4 |
| Class list (`pre_lock`, `copy_race` as `svc_audio_race`, `size_over32k`, `live_override`, `img29k` as `short_image`) | exact | 9.5 |
| Strict guard: no non-F6 write, suppressed core reads, counters | lean | 3.5 |
| Registered flywheel `phb_next` | lean | 8.1 |
| Run-time service clamps | lean | 7.3 |
| `fpjr`, `guard_wr`, `guard_sub` (= `a_guard_core`), `ret_unasked` | lean | 9.6 |
| Random phase-stream unit bench; tick-placement sweep | lean §11.2 | 12.1, 12.3 |
| State-RAM audio as the area fallback | lean (risk judge §7.13) | 10.3 lever 4 |
| Lock ≥ 9 (12 kept); `-nowarn`; parked suppressed addresses; FORCED first flops | hardware judge | 8.1-8.3, 3.5, 5.7 |
| Release also waits for `cpu_ready` | this document (keeps D4's write ban safe after a call) | 6.3 |
| Kept from simple: `d_in` = `write_DB`, the port-B mirror, the ring, `fe_arb`, the yielding P32 read, the word-wide fill, the detector attributes | simple | 1.2, 2.2, 5.6, 3, 7.3, 8.1 |

**Not adopted.**

- exact's `p32` flip-flop: it would need refreshes after calls and after F6. The yielding P32 read is exact in mode A. It remains an option if `tbl_alias` on stream 32 ever matters.
- exact's per-voice merge: the deferral makes the atomic merge exact.
- lean's K1 post-commit RMW and logical tick ordering: the ready rule achieves K1's short-phase exactness without moving the reads.
