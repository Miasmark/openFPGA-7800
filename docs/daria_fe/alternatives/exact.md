# daria_fe, micro-architecture "exact" (Architect B, DARIA step 6)

This is a complete micro-architecture for `daria_fe`, DARIA's 6507-side front end for DPC+ and the CDF family (CDF0, CDF1, CDFJ, CDFJ+). It is designed within decisions D1–D10. It aims at **exact AMPLITUDE and NOTE** in mode A: `amp_lag` = `note_race` = `seed_race` = `amp_input_race` = 0. It also aims at per-tick audio on upstream's clk_sys edges. To get there it uses three things:

- an audio engine that clones `arm_mapper_audio` state for state, on its own datapath;
- a **grant mirror** that computes upstream's `sel_ram_sel` clock for clock;
- a front end whose cart-RAM port use stays inside upstream's select clocks, or inside clocks where the audio clone is not granted.

Paths: `rtl/` = `src/fpga/mister/rtl/` (upstream, MIT); `core/` = `src/fpga/core/`; `tb/` = `sim/bupchip/daria/`. Spec files are cited as DPC (`dpcplus.md`), CDF, AUD (`audio.md`), GL (`glue.md`), BU (`bus.md`), BEN (`bench.md`), DI (`design_inputs.md`) and CR (`critic.md`), with line numbers. DC is `docs/DARIA_CORE.md`.

**Status of this document.** Nothing here was simulated or synthesised. Every upstream fact was re-read in `rtl/` for this design. These include:

- `arm_mapper_audio.sv` 1-366, all of it;
- `mapper_dpcplus.sv` 79-325;
- `mapper_cdf.sv` 77-253;
- `cart2600.sv` 241-265 and 965-978;
- `top.sv` 255-329 and 1420-1435;
- `arm_mapper_controller.sv` 126-178;
- `arm_mapper_ram_init.sv` 133-235.

DARIA's built RTL was read as well: `core/bupchip/daria_mem.sv`, `daria_call.sv` and `bupchip_pocket.sv`. The working tree's `daria_mem.sv:159, 203` and `bupchip_pocket.sv:177, 360` already carry R1's `stb_be`.

---

## 0. Summary

### 0.1 The key choices

1. **The ROM mirror port.** Front-end ROM port A (`fea`) is addressed on every clk_sys clock with upstream's `rom_a` = scheme base + {bank, `a_in[11:0]`}. Its q is therefore, byte for byte and clock for clock, tb_daria's 1-clock `cart_q` (tb/tb_daria.sv:124-129):
   - the stale previous-address byte in s0;
   - the true byte from s1;
   - the refetch after a bank switch.

   All 6507-side decode uses this live byte, as upstream's front ends use `rom_do`.
2. **The grant mirror `msel`.** It is upstream's `sel_ram_sel` (`cart2600.sv:965`), recomputed every clock from:
   - `a_in`, `rw` and `access`;
   - the mirror byte;
   - the front-end flip-flops (fast fetch, jump tracking, mode), which change on the same commit edge as upstream's.

   The audio clone is granted iff `ram_en && !msel`, exactly upstream's `audio_ram_grant`.
3. **The cart-RAM port-B invariant.** The front end uses cart RAM port B (`crb`) only in clocks where `msel` is high, or where the audio clone is not granted.
   - Fixed-slot reads lie inside upstream's select windows (section 3.1 proves it per access kind).
   - CDF pointer updates go through a one-entry **write buffer** that drains at C+1, or at C+2 if the audio is granted at C+1. That reproduces upstream's writeback landing at E0+7.8 as every audio read sees it: the old word at E7, the new one from E8.
   - The CDF DSWRITE byte is written on the commit edge itself, inside upstream's one-clock select.
4. **The exact audio clone (`fe_audio`).** Every register of `arm_mapper_audio` (BUS paths and the dead `waveform_pointer` removed) is in flip-flops:
   - the tick accumulator;
   - three counters with three 32-bit adders;
   - three frequencies;
   - three refresh snapshots;
   - three seeds;
   - the same 12-state machine.

   AMPLITUDE is forwarded into `fe_do` (`amp_next`), so the 6507 latches the same value as upstream at every latch.
5. **Seeds by latch.** The three counters are latched at C+1, which is upstream's launch edge L = E0+7. So `seed_race` = 0 by construction, and the post can come later.
6. **Merge.** Upstream's two-flop return synchroniser is mirrored: `ret_tog`, two flops, then the first state-RAM read issued in the clock where the change is seen.
   - Voice 0's counter merges on upstream's own merge edge M = X+1.
   - The rest follow, one per clock: f0 at X+2, c1 at X+3, f1 at X+4, c2 at X+5, f2 at X+6.
   - `merge_race` is counted when a tick or a refresh dispatch falls in a voice's window.
7. **Commit on `access`**, in whatever clock it comes. Post-commit work is keyed to the commit edge C, and each write waits until its data is ready.
   - A one-hot slot ring from `phi1` schedules only the pre-commit reads.
   - Nothing background is keyed to `phi1`: the audio clone, the copy engine, the drains, the call post and the merge take any clock their port is free.
   - Busy registers fall only at edges in [`pclk0` edge, next `pclk1` edge) (D3).
8. **F6 word-wide on its own enable.** It starts at the capture window's close, or 8 clk_sys after a rising `cart_reset`, never on a falling one. It takes 2,048 clocks for DPC+, CDF, CDF1 and CDFJ, and 8,192 for CDFJ+. The state-RAM clear runs in parallel. `init_busy` runs from `load_start` to F6's end and goes straight to the wrapper's reset OR (R2).
9. **The shared-edge guard (D4)** is a 1-flop clk_arm toggle, a constrained clk_sys sampler and a 4-bit lock counter.
   - During the call window, and whenever `daria_ready` is low, it lets the audio clone's reads register only on phase-B edges.
   - It blocks front-end writes in the call window. In mode A it is inert, because it never locks there.
10. **DPC+ fetchers in the state RAM** use byte lanes (R1). CDF pointers and increments are read in place in cart RAM, with one exception: **stream 32's pointer has a flip-flop copy** (`p32`). That copy makes DSWRITE and DSPTR need no read, and makes stream 32 immune to `tbl_alias`.

### 0.2 Exactness level (mode A)

| Quantity | Result |
|---|---|
| `d_out & oe` at every non-hidden latch | Exact, except `short_phase1` (an RSYNC phase 1 of 2 clocks) |
| Scheme registers after every cycle | Exact |
| Cart RAM after init, writes and calls, and at frames | Exact, except `tbl_alias` (CDFJ+ wrap into the tables) and `img29k` |
| Call payloads, F0–F7 | Exact (`seed_race` = 0) |
| Ticks | Same edge (T1) |
| Counters and frequencies per tick | Exact, except `merge_race` (CDF, bounded windows of 1–6 clocks after M) |
| AMPLITUDE value and edge | **Exact.** Counted exceptions: `merge_race` follow-ons, `dig_rom_lat` (digital ROM samples on an upstream DDR miss, or above 32 KB), `copy_race` (audio reading bytes a DPC+ copy/fill is writing), `pause_lane`, `short_phase1` and `pre_lock` |
| NOTE | Exact (`note_race` = 0) |

### 0.3 Cost

**About 1,280–1,540 ALMs** and about 1,120 flip-flops, with no new M10K. The lean estimate is 850–1,100 (DC:1298). The premium is about **+350–450 ALMs**, mostly the audio clone (about +250–330). This moves DC's projection (14,872–15,382, DC:1598) to about 15,300–15,830 ALMs, 82.8–85.7%: across the 84% gate in the upper half. That is the top risk. Section 10 lists reductions and their exactness cost.

---

## 0.4 Conventions

- **E0** is the clk_sys edge that samples `pclk1` (`phi1`) high. **Ek** = E0 + k.
- **s_k** (slot k) is the clock (E_k, E_k+1].
  - An M10K address "issued in s_k" registers at E_k+1, and its q is valid in s_k+1 (`daria_mem.sv:71-77`: registered address, unregistered output).
  - A register "loaded at E_k" takes its D input as it stands in s_k−1.
- **C** is the **commit edge**: the edge that samples `access` high. Nominally C = E6, with `pclk0` high in s5.
  - **c_k** is the clock (C+k, C+k+1]. So c0 is the clock right after the commit.
- **X** is the clk_sys edge at which upstream's `arm_call_busy` falls. **M = X+1** is upstream's merge edge (CR:16, `arm_mapper_controller.sv:163-177`, `arm_mapper_audio.sv:213-223`).
- **g** is an audio grant edge: the edge that registers the audio's RAM address; CAPTURE is in (g, g+1].
- **T** is a tick edge. **D** is a refresh dispatch edge.
- In pseudo-RTL, `x <= ...` inside `always_ff @(posedge clk_sys)`. "Live" means combinational in the current clock.
- Schemes: `is_dpc` = (`scheme` == 21); `is_cdf` = (`scheme` == 23); `plus` = `is_cdf && revision[1:0] == 3`; `jrev` = `is_cdf && revision[1:0] >= 2`.
  - The audio family is `fam` = `is_dpc ? 1 : is_cdf ? 3 : 0` (`cart2600.sv:658-660`).

---

## 1. Modules, hierarchy, ports

### 1.1 Hierarchy (one file, `core/bupchip/daria_fe.sv`, MIT)

```
daria_fe                 top: the port arbiters (crb, stb, feb, fea), the slot/commit rings,
│                        the release gate, the bench taps
├─ fe_core               6507 side: DPC+ and CDF decode and next-state (upstream semantics),
│                        the mirror byte, msel, fe_do, op scheduling, service latch and clamps
├─ fe_dp                 front-end word datapath: W + adder, p32 (stream 32 pointer), wbuf
│                        (pointer write buffer), display/field address arithmetic
├─ fe_audio              clone of arm_mapper_audio: tick, counters, frequencies, snapshots,
│                        seeds, merge, FSM, digital-sample engine (local and remote)
├─ fe_copy               F6, state-RAM clear, DPC+ copy/fill, init_busy, dma_busy
├─ fe_call               post, call_tog, ret_tog sync, merge sequencer, pend2, call_busy
└─ fe_guard              phase detector (one clk_arm flop) and the guard windows
```

All logic runs on clk_sys, except the single `pd_at` flop in `fe_guard` (clk_arm). There are no output-port initialisers (BEN Q9). Power-up values sit on internal registers.

### 1.2 `daria_fe` ports

| Port | Width | Dir | Clock | Meaning, source |
|---|---|---|---|---|
| `clk_sys` | 1 | in | — | |
| `clk_arm` | 1 | in | — | Only for `pd_at` (D4). Hardware: DARIA's ÷18 clock. Mode A: the bench's upstream `clk_arm` (5×), which leaves the guard unlocked |
| `a_in` | 13 | in | sys | `top.sv` POCKET_DARIA group: `{AB[12] & bios_en_b, AB[11:0]}` (top.sv:1128) |
| `d_in` | 8 | in | sys | `cart_din = RW ? read_DB : write_DB` (top.sv:1112) |
| `rw` | 1 | in | sys | `RW` (top.sv:377) |
| `phi1` | 1 | in | sys | `pclk1` (top.sv:1434) |
| `phi2` | 1 | in | sys | `pclk0`, unmasked (top.sv:1435) (D3) |
| `access` | 1 | in | sys | `mapper_phi2 && lock_ctrl && tia_en` (cart2600.sv:247, top.sv:327) |
| `pause` | 1 | in | sys | `pause_core` (atari7800_pocket.sv:63; the same signal top.sv:936 uses) |
| `cart_reset` | 1 | in | sys | `effective_reset` (top.sv:255) |
| `load_start` | 1 | in | sys | Pulse: `~old_cart_download && cart_download` |
| `load_end` | 1 | in | sys | Pulse: `old_cart_download && ~cart_download` |
| `load_close` | 1 | in | sys | Pulse in the clock the capture's cartridge window closes: `bup_capture`'s `c_close` (bup_capture.sv:152), exported (R6). Mode A: `load_end` delayed by 64 |
| `scheme` | 6 | in | sys | `fbs = \|bs_override ? {1'b0, bs_override} : force_bs` (atari7800_pocket.sv:1047) |
| `revision` | 3 | in | sys | `mapper_revision` |
| `ldx`, `ldy` | 1+1 | in | sys | `cdf_ldx`, `cdf_ldy` |
| `fo_en`, `fo` | 1+8 | in | sys | `cdf_fetch_offset_enable`, `cdf_fetch_offset` |
| `cdfj_entry`, `cdfj_stack` | 32+32 | in | sys | detect2600 |
| `asz` | 16 | in | sys | `arm_audio_size_addr` |
| `rom_size` | 32 | in | sys | `cart_size` (cart2600.sv:765 uses the unclamped value) |
| `ram32` | 1 | in | sys | `mapper_ram_size == 32768` (top.sv:778-783) |
| `fe_do` | 8 | out | sys | Register. → cart2600 `direct_do[BANKDPCP/BANKCDF]` |
| `fe_oe` | 1 | out | sys | Register (`a_in[12]` registered each clock). → `out_en = {8{fe_oe}}`; `flags_out` = 1, `ram_sel` = 0, `rom_addr` = 0 (constants in cart2600, so no clk_sdram path) |
| `arm_call_busy` | 1 | out | sys | Register → top.sv:306 |
| `arm_dma_busy` | 1 | out | sys | Register → top.sv:306 (low while `init_busy`) |
| `init_busy` | 1 | out | sys | Register → atari7800_pocket.sv:169-171 reset OR (R2). Not into cart2600 |
| `daria_ready` | 1 | in | sys | Hardware: `bupchip_pocket.daria_ready`. Mode A: upstream's `arm_online_sync2 && shadow_ready_sync2` (CR finding 8) |
| `call_tog` | 1 | out | sys | Register → `daria_call_tog` |
| `ret_tog` | 1 | in | arm | → two internal clk_sys flops |
| `smp_req` | 1 | out | sys | Toggle: digital ROM sample request, offsets ≥ 32 KB (section 5.6) |
| `smp_addr` | 19 | out | sys | Held from the toggle until the answer |
| `smp_ans` | 1 | in | arm | Toggle → two internal flops |
| `smp_data` | 8 | in | arm | Held by the wrapper; taken one clock after the synchronised toggle changes |
| `fea_addr` | 13 | out | sys | Front-end ROM port A (the mirror) |
| `fea_q` | 32 | in | sys | |
| `feb_addr` | 13 | out | sys | Front-end ROM port B |
| `feb_q` | 32 | in | sys | |
| `crb_addr`, `crb_we`, `crb_be`, `crb_wd`, `crb_q` | 13, 1, 4, 32, 32 | out/in | sys | Cart RAM port B |
| `stb_addr`, `stb_we`, `stb_be`, `stb_wd`, `stb_q` | 8, 1, 4, 32, 32 | out/in | sys | State RAM port B (with R1's `stb_be`) |

Further wiring:

- **cart2600, under POCKET_DARIA:** `is_bad_game` drops DPCP and CDF. `direct_do = fe_do`, `out_en = {8{fe_oe}}`, `flags_out = 16'd1`. `ram_sel`, `ram_rw`, `ram_a` and `rom_addr` stay at the idle constants (DI:292-297). `arm_call_busy` and `arm_dma_busy` come from ports. `mapper_init_busy` stays 0 (R2).
- **top.sv:** a POCKET_DARIA group exports `a_in`, `d_in`, `rw`, `pclk1`, `pclk0`, `access` and `effective_reset`, and imports `fe_do`, `fe_oe`, `arm_call_busy` and `arm_dma_busy`.
- **Simulation-only hook** (`ifndef ALTERA_RESERVED_QIS`): `hook_en`, `hook_m`, `hook_ret[6]`. With `+fe_merge_hook=1` the bench drives upstream's six returns at M into the merge, and `merge_race` must then be 0 (CR finding 6). The hook adds no hardware.

### 1.3 Submodule interfaces (main signals)

| Module | Inputs | Outputs |
|---|---|---|
| `fe_core` | bus, `sl`, `cl`, scheme inputs, `rom_b`, `jok`, `stb_q`, `crb_q`, `amp_next`, `p32`, `W` | `msel`, `u_fe_*` requests and addresses, `fe_do`, `fe_oe`, decode registers (`q_*`), commit strobes (`cm_*`), `wave[0:2]`, `note_wr`/`note_v`/`note_val`, `cdf_dig`, `svc_*`, `cpend`/`spend` taps |
| `fe_dp` | `stb_q`, `crb_q`, `din_q`, op/slot strobes | `W`, `p32`, `wbuf_v`/`wbuf_a`/`wbuf_d`, `disp_w`/`disp_l` (display word and lane) |
| `fe_audio` | `crb_q`, `stb_q`, `feb_q`, `msel`, `u_fe`, `guard_rd`, `pb_next`, `pause`, `fam`, `revision`, `ram32`, `asz`, `rom_size`, `wave`, `note_*`, `cdf_dig`, `launch`, `mg_c[2:0]`, `mg_f[2:0]`, `pend2`, `smp_ans`/`smp_data` | `u_au`, `au_addr`, `au_feb`/`au_feb_addr`, `amp_q`, `amp_next`, `seed_sel`, `frq_sel`, `smp_req`/`smp_addr`, taps |
| `fe_copy` | `load_*`, `cart_reset`, `scheme`, `revision`, `ram32`, `svc_*`, port-free flags, `feb_q` | `cp_crb_*`, `cp_feb_addr`, `cp_stb_*` (clear), `init_busy`, `dma_busy`, `f6_end` |
| `fe_call` | `cm_callfn`, `ret_tog`, `daria_ready`, `cart_reset`, `stb` grant, `rel_ok` | `call_tog`, `arm_call_busy`, `launch`, `mq[6:0]`, `mg_c`, `mg_f`, `pend2`, `post_*`, `p32_req`, `call_win` |
| `fe_guard` | `clk_arm`, `call_win`, `daria_ready` | `locked`, `pb_next`, `guard_rd`, `guard_wr` |

### 1.4 Bench taps (BEN 7.3 and the added ones), read hierarchically by `fe_taps.svh`

| Group | Tap | Compared against |
|---|---|---|
| Bus/commit | `u_fe.sl`, `u_fe.cl`, `u_fe.core.cm` | E0/C tracking (S1) |
| DPC+ | `core.bank`, `core.ffen` (`fast_fetch`), `core.fpend`, `core.rnd`, `core.pptr` (0..8, exact), `core.wave[0:2]`, `core.cpend`, `core.spend`. Fetchers: state RAM words 0x00–0x0F (masks 0xFFFF0FFF / 0xFF0FFFFF); params: word 0x10 lanes 0–3 | C1 |
| CDF | `core.bank`, `core.mode`, `core.fpend`, `core.fexp`, `core.jr`, `core.jexp`, `core.jst`, `core.cpend`; the pointer words in place (`crb` RAM) and `dp.p32` | C2, C3 |
| Copy | `copy.svc_fill`, `svc_src`, `svc_dst`, `svc_cnt`, `svc_val`, `copy.svc_act`, `arm_dma_busy` | R2, R3 |
| Audio | `au.tick`; `au.st` (state); `au.voice`; `au.rpend`, `au.npend`, `au.nvoice`, `au.nval`; `au.cnt[0:2]`, `au.frq[0:2]`, `au.rc[0:2]`, `au.seed[0:2]`; `au.woff`, `au.wsh`, `au.ssum`; `au.daddr`, `au.dlow`, `au.draddr`, `au.dsamp`; `au.amp`; `au.grant` (= `u_au`) | **A1** every clock against upstream's same-named registers |
| Mirror | `core.msel` | **A2**: every clock, = `dut.cart2600.sel_ram_sel` |
| Strobes | `au.ncap` (NOTE_CAPTURE edge), `call.launch` (seed latch edge), `call.mg_c[v]`, `call.mg_f[v]` (merge edges), `au.amp_we` | 7.6 offsets |
| Port use | `crb_use` (this clock's port-B read is consumed: `u_fe_rd \| u_au \| u_p32`); `u_fe`, `u_au`, `u_wb`, `u_p32`, `u_cp` | **A3**: never two at once; `u_au` ⇒ `!u_fe` |
| Call | `call.busy`, `call.post_k`, `call_tog`, `call.ret_seen`, `call.pend2`, `call.call_win` | R1 |
| Guard | `guard.locked`, `guard.pb_next` | `det_bad` (section 8.4) |
| Deposit | task `fe_deposit_audio(...)`: writes every `fe_audio` register at a falling edge (resync, BEN 7.6) | |

---

## 2. Timing

### 2.1 The primitives

**The ROM mirror (front-end ROM port A).**

```
wire [14:0] rbase = is_dpc ? 15'h0C00 : (plus ? 15'h0800 : 15'h1000);
wire [14:0] rom_a = rbase + {bank, a_in[11:0]};      // = upstream rom_a[14:0] (mapper_dpcplus.sv:127, mapper_cdf.sv:130)
assign fea_addr = rom_a[14:2];                        // every clock (daria_mem routes cap_we over it during a load)
logic [1:0] ln_q;  always_ff ln_q <= rom_a[1:0];      // every clock
wire  [7:0] rom_b = fea_q[{ln_q,3'b000} +: 8];        // = tb_daria cart_q, clock for clock
```

The ranges stay inside 15 bits: DPC+ ≤ 0x6BFF, CDF ≤ 0x7FFF, CDFJ+ ≤ 0x77FF (bank ≤ 6). In s0, `rom_b` is the byte at {current bank, previous `a_in`}: tb's stale byte, with the bank refetch (CR finding 9). From s1 it is the true byte.

**The 6507 slot ring, the commit ring and the release gate** (D3):

```
logic [11:0] sl = 12'h800;   // sl[k] = s_k (k <= 10); sl[11] = s11 and later (saturates)
always_ff sl <= phi1 ? 12'h001 : (sl[11] ? sl : {sl[10:0],1'b0});
logic [3:0]  cl = 4'h8;      // cl[k] = c_k; saturates at c3
always_ff cl <= access ? 4'h1 : (cl[3] ? cl : {cl[2:0],1'b0});
logic ph2 = 1'b0;            // between a pclk0 edge and the next pclk1 edge
always_ff if (phi2) ph2 <= 1'b1; else if (phi1) ph2 <= 1'b0;
wire  rel_ok = (ph2 | phi2) & ~phi1;  // a busy register may fall at this edge: E6..E11 of any cycle
```

`rel_ok` holds exactly at the edges from the `pclk0` edge up to, but not including, the next `pclk1` edge.

- A fall at the `pclk0` edge is sampled pre-edge, so that phase 2 is still hidden.
- At the next E0, RDY is sampled high. So the held read is committed once for any phase lengths, including a pause (the phases stop and resume) and the MARIA hand-off (CR findings 15 and 16; glue's release rule, GL:359-363).

**The commit.** `cm` is set at C (`access`) and cleared at the next `phi1` edge. The next-state functions use the **live** bus and mirror byte at C (upstream's `always` blocks evaluated at that edge), so they are correct for any C.

Two kinds of post-commit work:

- **Pointer updates, loaded at C itself.** `wbuf` and `p32` load at the edge C when their data is ready: `ld = access && rdyW || cm && rdyW && !ldone`. The `wbuf` drain is then issued in c0, giving the C+1/C+2 landing of section 3.1.
- **Every other write** (state RAM fields, PUSH/WRITE byte, params) is issued in the first clock with `cm && rdy && !done`.

For C = E6 everything is ready, so pointer updates load at C and the other writes go in c0. For C = E2 (short phase 1), each one waits for its data.

**The `fe_do` rule.** `fe_do <= fe_mux` on **every** edge. `fe_mux` is upstream's d_out function (`mapper_dpcplus.sv:160-180`, `mapper_cdf.sv:140-148`) evaluated live in the current clock, with three substitutions:

- registered RAM data (`bh`, the "byte hold") in place of the combinational `ram_data`;
- registered window-flag `fq` in place of the live flag;
- `amp_next` (the value the audio clone's `amp` register will hold after this edge) in place of `amplitude`.

Hence `fe_do` in clock (k, k+1] equals upstream's `d_out` in (k, k+1] as soon as `bh` holds the byte upstream's RAM shows. That is from s3 or s4 (below) until the commit. The 6507 latches s5, (C−1, C], whatever C is.

```
// one AND-OR of four sources (D10)
wire [7:0] dpc_rb = (sel fn0 idx0: rnd_next[7:0]) | (idx1: rnd_prior[7:0]) | (idx2..4: rnd bytes)
                  | (fn4 idx<4: {8{fq}}) ;               // 0 otherwise
wire [7:0] hold_m = bh & ((fn == 2) ? {8{fq}} : 8'hFF);   // DATAW
fe_mux = ({8{f_rom}} & rom_b) | ({8{f_hold}} & hold_m) | ({8{f_reg}} & dpc_rb) | ({8{f_amp}} & amp_next);
// f_* one-hot, live from the decode of section 2.2/2.3:
//  f_amp : DPC+ register_read && fn0 idx5, or CDF amplitude_fetch
//  f_reg : DPC+ register_read && (fn0 && idx != 5 || fn4)
//  f_hold: DPC+ register_read && fn 1..3, or CDF stream_substitute && !amplitude_fetch
//  f_rom : otherwise
fe_oe <= a_in[12];
```

**Common read pipeline depth.** The slowest data reaches `fe_do` at E5:

- s0: issue the ROM word;
- s1: the byte; issue the first RAM word;
- s2: issue the data byte;
- s3: the data byte → `bh` at E4;
- s4: `fe_mux` = `bh` → `fe_do` at E5.

That is three M10K hops and two registers in five edges, before the latch at E6 (section 2.4).

### 2.2 DPC+ (every access kind)

The tables of 2.2 and 2.3 assume the nominal C = E6; section 2.4 covers the other cases.

Columns:

- **fea:** the mirror (always issuing `rom_a`).
- **feb:** ROM port B.
- **crb:** cart RAM port B.
- **stb:** state RAM port B.
- **sel:** upstream's `sel_ram_sel` (= `msel`).
- **au:** whether the audio can be granted.

"cm" means the write fires only if committed.

**D1. Plain ROM read** (a ≥ $028, not a fast-fetch operand; or any read when `!fast_fetch || !fast_pending || rom_b ≥ $28`):

| Clock | fea | crb | stb | Datapath, fe_do | sel / au |
|---|---|---|---|---|---|
| s0 | issue `rom_a`; q = stale byte | — | — | `fe_do` ← f(stale) at E1 | low / yes (unless the stale byte makes a transient register read: mirrored) |
| s1–s5 | q = true byte | — | — | `fe_mux` = `rom_b` → final from s2 | low / yes |
| C | | | | `fpend` ← `ffen && rom_b == $A9`; hotspot `bank` ← `a[2:0]−6` if $FF6–$FFB | |

**D2. Register reads $1000–$1007** (fn 0):

| Clock | crb | stb | fe_do | sel |
|---|---|---|---|---|
| s0 | — | — | `fe_mux` = `rnd_next[7:0]` ($00), `rnd_prior[7:0]` ($01), `rnd[15:8]`/`[23:16]`/`[31:24]` ($02–$04), `amp_next` ($05), 0 ($06/$07); final from s1 (amp tracks every clock) | low |
| C | | | `rnd` ← next/prior ($00/$01); `fpend` ← 0. Afterwards the live `fe_mux` shows the stepped value's next byte, as upstream does | |

**D3. DFxDATA / DFxDATAW $1008–$1017** (fn 1/2, i = a[2:0]):

| Clock | crb | stb | Datapath | fe_do | sel / au |
|---|---|---|---|---|---|
| s0 | — | issue word 2i (w0) | | | high (address) / no |
| s1 | **issue** byte $C00 + w0[11:0] (word 0x300 + w0[11:2]; lane w0[1:0]) | q = w0 | `W` ← w0 at E2; `fq` ← win(w0) at E2 | | high / no |
| s2 | q = word | | `bh` ← lane byte at E3; `W` ← `W` + 1 at E3; `rdy` | | high / no |
| s3–s5 | | | | `fe_mux` = `bh` (& {8{`fq`}} for fn 2) → valid from s4 | high / no |
| C | | | `fpend` ← 0 | | |
| c0 | | **cm**: write word 2i, be 0011, data `W` | | (post-commit: holds the old byte; upstream shows the next byte: `obus_drift`) | high (to E12) |

`win(w)` = `(w[23:16] − w[7:0]) > (w[23:16] − w[31:24])`, 8-bit modular (mapper_dpcplus.sv:107-110).

**D4. DFxFRACDATA $1018–$101F** (fn 3): as D3, with these differences:

- s0 issues word 2i+1 (w1).
- The s1 crb byte address is $C00 + w1[19:8].
- E3: `W` ← `W` + {24'b0, `W`[31:24]}, so frac + inc lands in [19:0].
- c0 writes be 0111. A carry into lane 2's spare nibble is masked; FRACHI rewrites it.

**D5. DFxFLAG $1020–$1027** (fn 4):

- s0: issue stb w0.
- s1: q → `fq` ← win at E2.
- s2: `fe_mux` = `dpc_rb` = (i < 4 ? {8{`fq`}} : 0) → final from s3.
- C: `fpend` ← 0. No write.

**D6. Fast-fetch operand** (`rw && a12`, a ≥ $028, `ffen && fpend && rom_b < $28`; the register is `rom_b[5:0]`):

| Clock | crb | stb | Datapath | fe_do | sel / au |
|---|---|---|---|---|---|
| s0 | — | — | (`rom_b` stale: decode follows it, as upstream does; `msel` mirrors any transient) | | mirrored / mirrored |
| s1 | — | fn1/2/4: issue w0[ix]; fn3: issue w1[ix] | `q_ff` ← decode at E2 | fn0: `dpc_rb`/`amp_next` live → final from s2 | high for fn1–3 / no |
| s2 | fn1–3: **issue** byte $C00 + ctr/frac | q | `W` ← q at E3; `fq` ← win at E3 | fn4: `fe_mux` = flag → from s3 | high / no |
| s3 | q | | `bh` ← byte at E4; `W` ← `W` ± 1 / + inc at E4 | | high / no |
| s4 | | | | `fe_mux` = `bh` → `fe_do` at **E5**, final in s5 | high / no |
| C | | | `fpend` ← 0; no hotspot; random step for operand $00/$01 | after C: `f_rom` (`fpend` = 0), as upstream | low from c0 |
| c0 | | **cm**: write w0 or w1 as in D3/D4 | | | |

**D7. Field writes** ($028–$057 and $068–$06F, i = a[2:0]). `din_q` ← `d_in` at C. No read.

| Register | c0 stb write (cm) | be | data |
|---|---|---|---|
| FRACLOW $28+i | w1[i] | `revision[0]` ? 0011 : 0010 | {x, x, `din`, 00} |
| FRACHI $30+i | w1[i] | 0100 | {x, {4'b0, `din[3:0]`}, x, x} |
| FRACINC $38+i | w1[i] | 1001 | {`din`, x, x, 00} |
| TOP $40+i | w0[i] | 0100 | {x, `din`, x, x} |
| BOTTOM $48+i | w0[i] | 1000 | {`din`, x, x, x} |
| LOW $50+i | w0[i] | 0001 | {x, x, x, `din`} |
| HI $68+i | w0[i] | 0010 | {x, x, {4'b0, `din[3:0]`}, x} |

**D8. DFxPUSH $60–$67 and DFxWRITE $78–$7F:**

| Clock | crb | stb | Datapath | sel / au |
|---|---|---|---|---|
| s0 | — | issue w0[i] | | high / no |
| s1 | — | q = w0 | `W` ← w0 at E2 | high / no |
| s2 | | | `ra` ← PUSH ? `sum[11:0]` : `W[11:0]` at E3; `W` ← `sum` (PUSH: B = 0xFFFF; WRITE: B = 1) at E3; `rdy` | high / no |
| C | | | `din_q` ← `d_in` | |
| c0 | **cm**: write byte $C00 + `ra` (word 0x300 + `ra[11:2]`, be 1<<`ra[1:0]`), data {4{`din_q`}} | **cm**: write w0[i], be 0011, data `W` | | high (to E12) / no |

Upstream strobes the same byte at E2–E6 (DPC:659-662). Upstream's select stands from E1 to E12, so no audio read and no consumer of that byte exists in between. Writing it at c0 is invisible. The write is gated by the commit; upstream's is not (`ram_wr_noaccess`, asserted 0: CR finding 31).

**D9. FASTFETCH $58, PARAMETER $59, WAVEFORM $5D–$5F, RRESET/RWRITE $70–$74, NOTE $75–$77:**

All of these act at C, on flip-flops:

- `ffen` ← (`d_in` == 0).
- `if (pptr < 8) pptr ← pptr + 1`.
- `wave[a[1:0]−1]` ← `d_in[6:0]`.
- `rnd` ← 0x2B435044, or a byte replaced.
- NOTE: `note_wr` ← 1 for c0 only, `note_v` ← `a[1:0]−1`, `note_val` ← `d_in`. The audio latches `npend` at C+1, as upstream at E7 (`arm_mapper_audio.sv:201-205`).

PARAMETER also writes the state RAM: c0 stb write word 0x10, be = 1<<`pptr[1:0]`, data {4{`din_q`}}, only if `pptr` < 4. Params 4–7 are never read (DPC:273).

**D10. CALLFUNCTION $5A:**

| Clock | stb | Datapath |
|---|---|---|
| s0 | issue word 0x10 (params) | |
| s1 | q = params; issue w0[params[18:16]] (p2[2:0]) | `W` ← params at E2 |
| s2 | q = w0(f) | clamps (below) → `k_fill`, `k_copy`, `k_dst` at E3 |
| C | | `d`=0: `pptr` ← 0. `d`∈{1,2} && !`spend`: `svc_*` ← (fill = `d`==2, src = 0x0C00 + `W[15:0]` (17 bits, as upstream's `service_source`, so R2 compares equal also when off ≥ 0x7400 and the count is 0), dst = 0x0C00 + ctr, cnt = `d`==2 ? `k_fill` : `k_copy`, val = `W[7:0]`), `spend` ← 1, `pptr` ← 0. `d`∈{FE,FF} && !`cpend`: `cpend` ← 1 |
| c0 | (call post may start: section 6) | copy engine accepts the service (`spend` ← 0 at C+1, `arm_dma_busy` ← 1 at C+1); call: `arm_call_busy` ← 1, seeds latched at C+1, `cpend` ← 0 |

The clamps (mapper_dpcplus.sv:85-101), with ctr = w0(f)[11:0], off = `W[15:0]` and p3 = `W[31:24]`:

```
avail = 13'h1000 - {1'b0,ctr};  k_fill = (avail < {5'b0,p3}) ? avail[7:0] : p3;
savail = 17'h07400 - {1'b0,off};
k_copy = (off >= 16'h7400) ? 8'd0 : (savail < {9'b0,k_fill}) ? savail[7:0] : k_fill;
```

**D11. Bank hotspots** $FF6–$FFB, reads or writes, not on a register read: `bank` ← `a[2:0]−6` at C. The mirror shows the old bank's byte in s5. `rom_a` moves in c0, and from c1 the mirror shows the new bank's byte at the same `a_in` (tb's refetch).

### 2.3 The CDF family (every access kind)

The pointer table base `pb` and increment base `ib` (word addresses) are: CDF0 0x1B8/0x1DA, CDF1 0x028/0x04A, CDFJ/J+ 0x026/0x049 (CDF:202-203).

`disp(P)` is the display byte address (mapper_cdf.sv:126-128):

- non-plus: 0x800 + P[31:20];
- plus: (0x800 + P[30:16]) mod 0x8000. The 15-bit sum wraps (R5).

The crb word is `disp[14:2]`, the lane `disp[1:0]`. `step` = `plus` ? 1<<16 : 1<<20. `ishift` = `plus` ? 8 : 12.

The live predicates (section 3.1) are `c_fs` (fetch_substitute), `c_js` (jump_substitute), `c_amp` (amplitude_fetch) and `c_ti` (table index).

**C1. Plain cart read, with fast-jump lookahead and arming:**

| Clock | fea | feb | Datapath | sel / au |
|---|---|---|---|---|
| s0 | issue `rom_a`; q stale | **issue** `rom_a[14:2]` + 1 (every CDF cycle, `!init_busy`) | | mirrored (`c_fs`/`c_js` on the stale byte) |
| s1 | q = word(X) | q = word(X)+1 | `la1`, `la2` = bytes X+1, X+2 of {`feb_q`, `fea_q`} at lanes `ln_q`+1, `ln_q`+2; `jok_l` = `la1[7:1]`==0 && `la2`==0 && !(X ≥ 0x7FFE); `jok` ← `jok_l` at E2 | low |
| s1–s5 | | | `fe_mux` = `rom_b` | low / yes |
| C | | | **next-state = mapper_cdf.sv:210-223** (below); hotspot `bank` (mapper_cdf.sv:184-192) | |

`X ≥ 0x7FFE` is `&rom_a[14:1]` registered at E1. It covers the map entries that are always 0 (cdf_fastjump_table.sv:34-38). At C the arming term uses `jok_l` if C = E2, else `jok`.

The arming at C (non-substituted read):

```
fpend <= fast_mode && arms(rom_b);  if (fast_mode && arms(rom_b)) fexp <= a_in + 1;
if      (jr != 0 && a_in == jexp)                    jr <= 0;
else if (fast_mode && rom_b == 8'h4C && jok_at_C)    {jr, jexp, jst} <= {2'd2, a_in + 1, 6'd33};
else if (jr != 0 && a_in != jexp)                    jr <= 0;
// arms(b) = b==A9 || (plus && ldx && b==A2) || (plus && ldy && b==A0)
```

**C2. Fast fetch, stream s ≠ 32, not the amplitude stream:**

| Clock | crb | Datapath | fe_do | sel / au |
|---|---|---|---|---|
| s0 | — | (decode on the stale byte; mirrored) | | mirrored |
| s1 | **issue** word `pb`+s | `q_cf`, `q_s` ← decode at E2 | | high / no |
| s2 | q = P; **issue** `disp(P)` | `W` ← P at E3 | | high / no |
| s3 | q = data word; **issue** word `ib`+s | `bh` ← byte at E4 | | high / no |
| s4 | q = increment I | `W` ← `W` + (I[15:0] << `ishift`) at E5; `rdy` | `fe_mux` = `bh` → **E5** | high / no |
| s5 | (free; `u_wb`/`u_cp` may use it) | | final | high / no |
| C | | `fpend` ← 0; `wbuf` ← {`pb`+s, `W`} | after C: `rom_b` (as upstream) | low from c0 |
| c0/c1 | `wbuf` drains (section 3.1) | | | |

**C3. Fast fetch of stream 32.** As C2, except that s1 issues no crb and in s2 P = `p32`, the flip-flop copy. At C: `p32` ← `W` as well. Stream 32's pointer then follows upstream's table copy even when the RAM word is changed behind it (`tbl_alias` does not affect it).

**C4. Amplitude fetch** (`c_amp`):

- s1: `fe_mux` = `amp_next` (live) → `fe_do` tracks `amplitude` clock for clock; in s5 it equals upstream's value at the latch.
- No RAM use, and `sel` is low (mapper_cdf.sv:142-146).
- C: `fpend` ← 0. No pointer update.

**C5. Jump operand** (`c_js`, stream `js` = `jst` + (`jrev && jr==2` ? `rom_b[0]` : 0)):

| Clock | crb | Datapath | fe_do | sel |
|---|---|---|---|---|
| s0 | — | operand 2 after a $00 operand 1: the stale byte (= $00) already makes `c_js` true; mirrored | | high (mirrored) |
| s1 | **issue** `pb`+`js` | decode at E2 | | high |
| s2 | q = P; **issue** `disp(P)` | `W` ← P at E3 | | high |
| s3 | q = data | `bh` at E4; `W` ← `W` + `step` at E4; `rdy` | | high |
| s4 | | | `fe_do` at E5 | high |
| C | | `fpend` ← 0; `wbuf` ← {`pb`+`js`, `W`}; `jr` ← `jr`−1; `jexp` ← `jexp`+1; if `jrev && jr==2`: `jst` ← 33 + `rom_b[0]` | | |

At a bank end, `jexp` wraps to a 13-bit $0000 with A12 = 0. That read is neither substituted nor a cancel; `jr` survives until the next cart read (CDF:608-616). This comes for free from the live predicates.

**C6. DSWRITE $1FF0** (write):

| Clock | crb | Datapath | sel / au |
|---|---|---|---|
| s1 | | `W` ← `p32` at E2 | low / yes |
| s2 | | `W` ← `W` + `step` at E3 | low / yes |
| **the clock ending at C** (s5) | **issue write** `disp(p32)`, be 1<<lane, data {4{`d_in`}}, **we = `access`** | | **high, this clock only** (mapper_cdf.sv:150-156) / no |
| C | | `p32` ← `W`; `wbuf` ← {`pb`+32, `W`} | |
| c0/c1 | `wbuf` drains | | low / yes |

The crb address select for this write is `op_dsw && access`. `access` is combinational from top.sv's phase logic into the crb mux, which is one registered stage in clk_sys. A write cycle is never hidden (BU:215-223), so `phi2` and `access` coincide here.

**C7. DSPTR $1FF1:** at C, `p32` ← `sh(p32, d_in)` and `wbuf` ← {`pb`+32, `sh`}, where

```
sh = plus ? {p32[23:16], d_in, 16'h0} : {p32[23:20], d_in, 20'h0}    // mapper_cdf.sv:237-241
```

**C8. SETMODE $1FF2:** `mode` ← `d_in` at C. `cdf_dig = (mode[7:4] == 0)` reaches the audio clone in c0. Upstream's POINTER_CAPTURE samples it live (AUD:489).

**C9. CALLFN $1FF3:** if `d_in` ∈ {FE, FF} && !`cpend`: `cpend` ← 1 at C. Then as D10's call path (section 6).

**C10. Hotspots** $FF4–$FFB, reads and writes, not on a substituted read. At C:

```
plus: bank <= (a==FF4 || a==FFB) ? 0 : a[2:0]-4
else: bank <= (a==FF4 || a==FFB) ? 6 : a[2:0]-5
```

**C11. LDX/LDY** (CDFJ+ with `ldx`/`ldy`) arm through `arms()`. **Fetch offset:** `inr`, `norm` and `amp_op` as upstream (mapper_cdf.sv:89-98), with no version gate (CDF Q14).

### 2.4 The 6-clock budget, and irregular phases

**Proof for the nominal phase (C = E6).** The latch takes `fe_do` in s5. `fe_do` is loaded at E5 from `fe_mux` in s4. Every source of `fe_mux` is upstream's value in s5 when evaluated in s4:

- `a_in`, `rw` and the front-end flip-flops are constant from E0+ to C.
- `rom_b` is the true byte from s1 (fea issued in s0, one M10K clock).
- `bh` is loaded by E4 at the latest: the crb data read is issued in s2 (D6, C2, C5) or s1 (D3/D4), with one M10K clock each.
  - The issue in s2 needs the pointer or fetcher word in s2. That comes from the read issued in s1, which needs the decode in s1, which needs `rom_b` in s1.
  - So the chain is s0 (ROM) → s1 (index) → s2 (data address) → E4 (`bh`) → E5 (`fe_do`): **three M10K clocks and two register loads, ending one edge before the latch.**
- The RAM byte at the address `bh` read equals upstream's RAM byte at E5. In a read cycle the only writers of that byte between E2 and E5 would be an ARM store (none: the ARM runs only in calls, while the 6507 is held), a DMA (it holds the 6507) or a front-end write (none in a read cycle).
- `amp_next`(E5) = the amplitude in s5.
- `dpc_rb` comes from flip-flops (`rnd`) and `fq`, loaded at E2/E3.

The CDF pointer update also needs the increment by C: it is issued in s3, its q is in s4, and `W` is final at E5 ≤ C. ∎

| Phase case | Where it comes from | Effect, and what the design does |
|---|---|---|
| Phase 1 stretched (C = E8…E12) | MARIA→TIA hand-off after a reset release (CR finding 15; top.sv:1287-1342) | Every read is done by E4. `bh`, `rom_b` and the flip-flops hold, and `amp_next` tracks, so `fe_do` stays correct until C. Upstream's select windows (address-decoded, or predicate until commit) cover s1–s3. Writes go at c0. **Exact** |
| Phase 1 of 2 clocks (C = E2) | A misaligned TIA reload, RSYNC (BU:107-113) | The latch takes s1's `fe_do`: correct for plain ROM, random, amplitude and flag; wrong for RAM-backed reads (`bh` not loaded) → `short_phase1`. State is still correct: the commit uses live inputs; `jok` uses `jok_l`; each post-commit write waits for its `rdy` (the next E0 is ≥ C+6). The fixed reads in s2/s3 then lie outside upstream's select, so the audio grant adds `!u_fe` (section 3.1) and may lag upstream's in that cycle; counted under `short_phase1` |
| Phase 2 of 10 clocks | RSYNC reload with pre-reload count 3 | Only lengthens c_k. No effect |
| Hidden `pclk0` (call/DMA hold) | top.sv:327 | No `access`: no commit and no write. Reads repeat each held cycle; the held address is W+1's opcode fetch, so there is no crb use (AUD:1209-1229). Code executing in $1000-$1027 would read crb in s1 inside its address-decoded select, still consistent |
| Pause | `pclk*` stop (top.sv:445) | `sl` saturates and nothing is issued. `fe_do` keeps tracking `amp_next`. `msel` evaluates the frozen bus every clock, as upstream does (AUD:1103-1121) |
| MARIA phases during reset and the BIOS (4/6 clocks) | top.sv:256-260 | `access` = 0. Every front-end port use is also gated by `!init_busy && !cart_reset`, so F6 owns the ports. In 7800 mode after a reset (BIOS path) `msel` is still upstream's: the address-decoded DPC+ selects are mirrored, and the ROM-gated ones are 0 because the state is reset |

### 2.5 Timelines for copy/fill, call and merge

**DPC+ copy/fill** (section 7.3): the service is latched at C, and the engine starts at C+1 with `arm_dma_busy` ← 1.

- Copy: feb issues the source byte's word in clock k; crb writes the byte in clock k+1 when crb is free (not `u_au`, `u_fe` or `u_wb`). It is pipelined at one byte per free clock.
- Fill: one byte per free clock.
- `arm_dma_busy` falls at the first `rel_ok` edge after the last write.

**Call** (C = CALLFN commit edge):

| Edge | Event |
|---|---|
| C | `cpend` ← 1 |
| C+1 | `launch`: seeds ← counters (= upstream L = E7, seeds and payload equal by construction); `arm_call_busy` ← 1; `cpend` ← 0 |
| c0–c7 | post F0..F7 on stb, one per free clock (F0 issued in c0, registered at C+1, …) |
| ≥ C+8 | `call_tog` flips at the edge of the F7 write or later, when `daria_ready && !cart_reset` (D5); `call_win` ← 1 |

**Return** (S1, S2 = `ret_s` flops; X = the next edge, as upstream's controller acts at S(⌊A_c/5⌋+3), GL:304):

| Clock / edge | CDF | DPC+ |
|---|---|---|
| (X−1, X] | `ret_new` = `ret_s[1]` != `ret_seen` → issue stb 0xF8 | `ret_new` |
| X | `ret_seen` ← `ret_s[1]` | `ret_seen` ←; if `pend2`: `launch2` in (X, X+1] |
| X+1 (= M) | **c0 merge** (q = F8); issue 0xFB | seeds reload at X+1 if `pend2` (exact: upstream launches at M) |
| X+2 | f0 merge (q = FB); issue 0xF9 | |
| X+3 | c1 merge; issue 0xFC | |
| X+4 | f1; issue 0xFA | |
| X+5 | c2; issue 0xFD | |
| X+6 | f2 | |
| X…X+3 | `p32` refresh: one crb read at the first free clock (phase-B edge if `guard_rd`) | — |
| ≥ X+7 | release at the first `rel_ok` edge, unless `pend2` (then post F2–F4 for call 2 and flip again) | release at the first `rel_ok` edge ≥ X |

### 2.6 Register reference (every non-trivial register: reset, load enable, data)

Notation:

- `wrC(x)` = `access && is_dpc && !rw && a_in[12] && a_in[11:0] == x` (or `is_cdf` for $FFx);
- `rdC` = `access && rw && a_in[12]`;
- `rst_fe` = `cart_reset || scheme != scheme_q` (the front end; never the audio clone).

All are clk_sys flip-flops with one load enable and at most four data sources (D10). Section 5.2 covers the audio clone's registers.

**fe_core**

| Register | W | Reset (`rst_fe`) | Load enable | Data |
|---|---|---|---|---|
| `bank` | 3 | DPC 5; CDF plus ? 0 : 6 | `access && a_in[12] && hot && !(d_rr \|\| c_ss)` | DPC `a[2:0]−6`; CDF table C10 |
| `rnd` | 32 | 0x2B435044 | `rdC && d_rr && fn==0 && ix<=1` \|\| `wrC($070..$074)` | {0x2B435044 ($070), `rnd_next`, `rnd_prior`, `rnd` with byte `a−$071` ← `d_in`} |
| `ffen` | 1 | 0 | `wrC($058)` | `d_in == 0` |
| `fpend` | 1 | 0 | `rdC` (selected scheme) | DPC `d_rr ? 0 : ffen && rom_b==$A9`; CDF `c_ss ? 0 : fast_mode && arms(rom_b)` |
| `fexp` | 13 | 0 | `rdC && is_cdf && !c_ss && fast_mode && arms(rom_b)` | `a_in + 1` |
| `jr` | 2 | 0 | `rdC && is_cdf` | `c_js ? jr−1 : (jr!=0 && a_in==jexp) ? 0 : (fast_mode && rom_b==$4C && jok_C) ? 2 : 0` (`c_amp`/`c_fs` without a jump: unchanged) |
| `jexp` | 13 | 0 | `rdC && is_cdf && (c_js \|\| arm_j)` | `c_js ? jexp+1 : a_in+1` |
| `jst` | 6 | 33 | `rdC && is_cdf && ((c_js && jrev && jr==2) \|\| arm_j)` | `c_js ? 33 + rom_b[0] : 33` |
| `mode` | 8 | 0xFF | `wrC($FF2)` | `d_in` |
| `pptr` | 4 | 0 | `wrC($059) && pptr<8` \|\| `wrC($05A) && (d==0 \|\| (d∈{1,2} && !spend))` | {`pptr+1`, 0} |
| `wave[v]` | 7×3 | 0 | `wrC($05D+v)` | `d_in[6:0]` |
| `note_wr` | 1 | 0 | every clock | `wrC($075..$077)` |
| `note_v`, `note_val` | 2, 8 | 0 | `wrC($075..$077)` | `a[1:0]−1`, `d_in` |
| `cpend` | 1 | 0 | set: `wrC(CALLFN) && d∈{FE,FF} && !cpend`; clear: `launch` | 1 / 0 |
| `spend` | 1 | 0 | set: `wrC($05A) && d∈{1,2} && !spend`; clear: `cl[0]` (accept at C+1) | 1 / 0 |
| `svc_fill`, `svc_src`, `svc_dst`, `svc_cnt`, `svc_val` | 1, 17, 13, 8, 8 | 0 | `spend` set condition | `d==2`, 0x0C00+`W[15:0]`, 0x0C00+`k_dst`, `d==2 ? k_fill : k_copy`, `W[7:0]` |
| `k_fill`, `k_copy`, `k_dst` | 8, 8, 12 | — | `sl[2] && q_dcf` | clamps (D10) |
| `cm` | 1 | 0 | set `access`; clear `phi1` | |
| `din_q` | 8 | — | `access` | `d_in` |
| `q_*` (address decode) | ~12 | — | `sl[0]` | from `a_in`, `rw` |
| `q_*` (ROM decode: `q_ff`, `q_cf`, `q_cj`, `q_amp`, `q_s`) | ~12 | — | `sl[1]` | from `rom_b` and predicates |
| `jok` | 1 | — | `sl[1]` | `jok_l` |
| `ln_q`, `xhi_q` | 2, 1 | — | every clock | `rom_a[1:0]`, `&rom_a[14:1]` |
| `fe_do` | 8 | 0 | every clock | `fe_mux` (four sources, section 2.1) |
| `fe_oe` | 1 | 0 | every clock | `a_in[12]` |

**fe_dp**

| Register | W | Load enable | Data |
|---|---|---|---|
| `W` | 32 | DPC: E2 (`sl[1]`: direct/CALLFN), E3 (`sl[2]`: ff); `sum` at E3 or E4. CDF: E3 (`sl[2]`: ptr), E4 (jump `sum`), E5 (fetch `sum`); DSWRITE: E2 (`p32`), E3 (`sum`) | {`stb_q`, `crb_q`, `sum`, `p32`} |
| `sum` = `W + B` (comb) | 32 | — | B (one-hot AND-OR): 1; 0xFFFF; {24'b0, `W[31:24]`}; `crb_q[15:0]`<<12; `crb_q[15:0]`<<8; 1<<20; 1<<16 |
| `p32` | 32 | `ld && is_cdf && (op∈{DSWRITE, fetch32})` \|\| `ld && DSPTR` \|\| clock after `u_p32` | {`W`, `sh`, `crb_q`} |
| `wbuf_v` | 1 | set `ld && op_ptr`; clear `u_wb` | |
| `wbuf_a` | 13 | `ld && op_ptr` | `pb + widx` (`widx` = DSWRITE/DSPTR ? 32 : `q_s`) |
| `wbuf_d` | 32 | `ld && op_ptr` | {`W`, `sh`} |
| `bh` | 8 | the clock after the data read (DPC+ direct E3; DPC+ ff E4; CDF E4) | `crb_q` at lane `dl_q` (the registered lane of the data address) |
| `fq` | 1 | E2 (direct) / E3 (ff) | `win(stb_q)` |
| `ra` | 12 | E3 in a PUSH/WRITE cycle | {`sum[11:0]` (PUSH), `W[11:0]` (WRITE)} |
| `rdy`, `rdyW` | 1, 1 | set by the pipeline (D3 E3, D6 E4, C2 E5, C5 E4, C6 E3); cleared by `phi1` | |

**fe_copy / fe_call**

| Register | W | Load enable | Data |
|---|---|---|---|
| `cp_src` | 17 | start (F6 phase or service) / each step | {start value, `cp_src` + (word ? 4 : 1)} |
| `cp_dst` | 15 | start / each step | {start value, `cp_dst` + (word ? 4 : 1)} |
| `cp_cnt` | 13 | start / each step | {count, `cp_cnt` − 1} |
| `cbyte`, `cb_v` | 8, 1 | copy feb q valid / `u_cp` taken | `feb_q` lane; set/clear |
| `f6_ph` (one-hot: CLR+A, B, P32, done) | 4 | phase end | next phase |
| `dly` | 3 | `rise` / count | {7, `dly`−1} |
| `init_busy` | 1 | set `load_start` \|\| (`rise && f6_ok`); clear F6 end \|\| (`load_end_d && !arm_img`) | |
| `arm_dma_busy` | 1 | set `cl[0] && svc accepted`; clear `!svc_act && rel_ok`; forced 0 while `init_busy` | |
| `busy` (`arm_call_busy`) | 1 | set `cl[0] && start`; clear `rel_req && !pend2 && rel_ok` \|\| `cart_reset` | |
| `post_k` | 3 | `post_act && stb granted` | `post_k` + 1 (start 0, or 2 for `pend2`) |
| `call_tog` | 1 | last post word issued (or later) `&& daria_ready && !cart_reset` | `~call_tog` |
| `ret_s`, `ret_seen`, `ret_wait` | 2, 1, 1 | section 6 | |
| `mq` | 7 | every clock | {`mq[5:0]`, `ret_new && is_cdf`} |
| `pend2` | 1 | set: CALLFN arms while `busy`; clear: second flip, or `cart_reset` | |
| `p32_req` | 1 | set `ret_new && is_cdf` \|\| F6 end (CDF); clear `u_p32` | |
| `call_win` | 1 | set at the flip; clear with `busy` | |

---

## 3. Port arbitration

### 3.1 Cart RAM port B (`crb`)

**The users and their one-hot selects** (evaluated in the clock; the address registers at its end):

| Priority | Select | When | Address / data / be / we |
|---|---|---|---|
| 1 | `u_fe` | the fixed slots of section 2: D3/D4 s1, D6 s2, C2 s1/s2/s3 (C3 s2/s3), C5 s1/s2, C6 the C clock (`access`), D8 c0 (cm); always gated by `!init_busy && !cart_reset` | `fe_crb_a`; for writes {4{byte}}, 1<<lane |
| 1 | `u_au` | `au_ram_en && !msel && !u_fe && guard_ok` (the audio clone's grant; section 5.2) | `au_addr[14:2]`; read |
| 2 | `u_wb` | `wbuf_v && !u_fe && !u_au && !guard_wr` | `wbuf_a`, `wbuf_d`, be F, we 1 |
| 3 | `u_p32` | `p32_req && !u_fe && !u_au && !u_wb && (!guard_rd \|\| pb_next)` | `pb`+32; read; `p32` ← `crb_q` next clock |
| 4 | `u_cp` | `cp_req && !u_fe && !u_au && !u_wb && !u_p32 && (!guard_wr \|\| f6)` | copy or F6 address/data/be/we |
| — | default | | `au_addr[14:2]`, we 0 |

```
assign crb_addr = ({13{u_fe}} & fe_crb_a) | ({13{u_au | idle}} & au_addr[14:2]) |
                  ({13{u_wb}} & wbuf_a) | ({13{u_p32}} & p32_word) | ({13{u_cp}} & cp_crb_a);
assign crb_we   = (u_fe & fe_crb_we) | u_wb | (u_cp & cp_crb_we);
assign crb_wd   = ({32{u_fe}} & {4{fe_wbyte}}) | ({32{u_wb}} & wbuf_d) | ({32{u_cp}} & cp_crb_d);
assign crb_be   = ({4{u_fe}} & fe_crb_be) | ({4{u_wb}} & 4'hF) | ({4{u_cp}} & cp_crb_be);
```

(`fe_wbyte` = `d_in` for DSWRITE, `din_q` for PUSH/WRITE.)

**The invariant** `u_fe ⇒ msel` (when C ≥ E6) and `u_au ⇒ !u_fe` (always), proved per access kind:

| Access | `u_fe` clocks | Upstream `sel_ram_sel` high in | Why |
|---|---|---|---|
| DPC+ direct DATA/DATAW/FRACDATA | s1 | s0–s11 | `ram_register_read` is address-decoded (mapper_dpcplus.sv:113-124, 137-143) |
| DPC+ fast-fetch DATA | s2 | s1–s5 (true byte; s0 transient mirrored) | the predicate holds on the same `rom_b` I decoded, until `fpend` clears at C |
| DPC+ PUSH/WRITE write | c0 | s0–s11 | address-decoded write select, not gated by access (:144-158) |
| CDF fetch (s ≠ 32) | s1, s2, s3 | s1–s5 | `fetch_substitute` on the true byte until C (mapper_cdf.sv:104-105, 145) |
| CDF fetch (s = 32) | s2, s3 | s1–s5 | same |
| CDF jump | s1, s2 | s1–s5 (+s0 for operand 2 after $00) | `jump_substitute` (:102-103) |
| DSWRITE | the C clock | the C clock | `access && !rw && a == $1FF0` (:150-156) |
| `wbuf` drain | c0 or c1 | any | not inside a select: it takes a clock **where the audio clone is not granted** |
| copy, `p32` | any free | any | the same rule |

So when the audio clone is granted (exactly when upstream's audio is granted), port B is idle for it, and the read lands on the same edge g as upstream's.

**Why `wbuf` drains at c0/c1, and why that is exact.**

- An ISSUE state granted at g is in CAPTURE in (g, g+1], so the audio is never granted in two consecutive clocks.
- So `wbuf` (loaded at C) is written at C+1 if the audio is not granted then, else at C+2.

Upstream's writeback puts the pointer into cart RAM at E7.8 (CDF:855-861, BU:989-994). An upstream audio read of that word sees the old word at a grant edge ≤ E7, and the new one at ≥ E8. Mine:

- written at C+1: reads at C+2 and later see the new word, and no read happens at C+1, because I own the port;
- written at C+2: the audio was granted at C+1 (old word, as upstream's) and cannot be granted at C+2.

Every audio read therefore sees the pointer word upstream's sees. The pointer words are read by the audio only through a CDFJ+ wrap, a digital RAM sample or a size word inside the table area; the rule holds in general. The next front-end read of the stream is at the next cycle's s1 (≥ C+7). Commits are ≥ 4 clocks apart (CDF:862), so `wbuf` never overruns (`wbuf_ovr` asserted 0).

**The short-phase guard.** `u_au` contains `!u_fe`. It changes nothing when the invariant holds. When C = E2 the s2/s3 reads would otherwise collide with a grant, and the audio waits a clock instead (counted `short_phase1`, `grant_steal` asserted 0 otherwise).

### 3.2 State RAM port B (`stb`)

| Priority | User | When |
|---|---|---|
| 1 | front end, DPC+ | reads in s0 (D3–D5, D8, D10) and s1 (D6, D10's second read); field/RMW/param writes in c0 (cm, ready) |
| 2 | merge reads, CDF | `mq[0..5]` (X−1 … X+5), consecutive. CDF has no front-end stb use, and DPC+ has no merge, so they never contend |
| 3 | call post | F0..F7 (or F2–F4 for `pend2`), one per clock when free; `post_k` advances on each issued write |
| 4 | state-RAM clear | words 0x00–0x10 ← 0, during `init_busy` (front end and call idle) |

Rules:

- **No q is used in the clock after a partial-be write** (`NEW_DATA_NO_NBE_READ`, DI:167-170). Front-end writes are at c0, and the next front-end read is at the next s0 (≥ C+6). Merge and post are full-word.
- **Call block discipline.** F0–F7 are written only between a merge's end and the next `call_tog` flip. F8–FD are read only after `ret_seen` changes. Port A (daria_call) reads F0 at A3 and F1–F7 at A18–A26, and writes F8–FD at R2–R7, so no word is written on one port while read on the other (CR finding 34(d)).

### 3.3 Front-end ROM ports

| Port | Users (priority) |
|---|---|
| A (`fea`) | the mirror, every clock. During a download, `cap_we` overrides it inside daria_mem (daria_mem.sv:196); the console is in reset then |
| B (`feb`) | 1. CDF lookahead, s0 of every CDF cycle, `!init_busy`. 2. digital ROM sample (local, offsets < 0x8000), in the first clock of [R, R+2] not taken by 1 (section 5.6). 3. copy source (DPC+ service) / F6 source. 2 and 3 never coexist (CDF vs DPC+; F6 runs in reset) |

### 3.4 The guard's phase-B rule (D4), concretely

With ÷48 and ÷18 from one VCO, the 144-VCO frame (209.5 ns) holds three clk_sys edges:

- **SH** (shared, at 0);
- **B** (at 48: 17.46 ns after the clk_arm edge at 36, 8.73 ns before the one at 54);
- **K** (at 96: 8.73 ns after the clk_arm edge at 90).

| Edge | `pd_same` in the clock ending here | Read may register? (`guard_rd`) | Front-end/copy write? (`guard_wr`) |
|---|---|---|---|
| SH | — | **no** | **no** |
| B | yes (`pb_next` = 1 in the clock ending at B) | **yes** | no |
| K | — | no | no |

```
guard_ok  = !guard_rd || pb_next;
guard_rd  = locked && (call_win || !daria_ready_q);   // D4: call window, and conservatively !daria_ready
guard_wr  = locked && (call_win || !daria_ready_q) && !f6_run;
```

- Under `guard_rd` the audio clone's ISSUE waits until the clock that ends on a B edge (≤ 2 clocks per read), and the `p32` refresh too.
- `guard_wr` blocks `u_wb` and `u_cp`. F6 is exempt: it runs only while `cart_reset` is high, after the 8-clock settle (section 7.1), when the CPU is held.
- A 6507-side write (DSWRITE, PUSH/WRITE) cannot be requested while `guard_wr` is high:
  - the 6507 is held during calls, and W+1 is an opcode fetch;
  - after a reset release the 6507 spends 7 cycles (84 clk_sys) in its reset sequence, while `daria_ready` returns about 64 clk_sys after `daria_mreset` falls (DI:374).

  If one ever were requested, it is **not dropped**, because that would desync. It proceeds and counts `guard_wr_conflict`, asserted 0.
- The same argument covers the front end's own fixed-slot crb **reads**: none can occur inside the guard window, because the held 6507 presents an opcode fetch and the reset sequence makes only ROM reads. They are not phase-aligned (they are tied to the 6507 cycle). If one ever occurred it counts `guard_rd_conflict`, asserted 0.
- In mode A, `locked` = 0, so the guard is inert and exactness is unaffected.

---

## 4. State placement and the state RAM map

| State | Where | Bits |
|---|---|---|
| DPC+ `bank`, `ffen`, `fpend`, `rnd`, `pptr`, `wave[0:2]`, `note_wr`/`note_v`/`note_val`, `cpend`, `spend`, `svc_*` (fill, src 15, dst 13, cnt 8, val 8) | FF | ~150 |
| DPC+ 8 fetchers | state RAM 0x00–0x0F: w0[i] = {bottom, top, 0:ctr[11:8], ctr[7:0]} at 2i; w1[i] = {inc, 0:frac[19:16], frac[15:0]} at 2i+1 | — |
| DPC+ params 0–3 | state RAM 0x10, lane k = param k | — |
| CDF `bank`, `mode`, `fpend`, `fexp`, `jr`, `jexp`, `jst`, `cpend` | FF | ~45 |
| CDF pointers and increments | in place in cart RAM (words `pb`+i, `ib`+i), except **stream 32's pointer also in FF `p32`** (refreshed after F6 and after every call) | 32 |
| CDF pointer write in flight | `wbuf` FF | 46 |
| Front-end datapath `W`, `bh`, `fq`, `ra`, `din_q`, `jok`, `ln_q`, decode regs | FF | ~90 |
| Audio clone: `tacc`, `cnt`/`frq`/`rc`/`seed`[0:2], FSM, `voice`, `woff`, `wsh`, `ssum`, `amp`, `daddr`, `dlow`, `draddr`, `dsamp`, `npend`/`nvoice`/`nval`, `rpend`, ROM-sample regs | FF | ~560 |
| Call block | state RAM 0xF0–0xFD (daria_call.sv:7-12) | — |

State RAM word map:

| Word | Use |
|---|---|
| 0x00–0x0F | DPC+ fetchers (read by daria_call port A at word 0, value unused: harmless) |
| 0x10 | DPC+ params |
| 0x11–0xEF | unused (free for later revisions) |
| 0xF0–0xF7 | call: entry \| T, stack, seeds 0–2, frequencies 0–2 (posted by `fe_call`) |
| 0xF8–0xFD | returns: counters 0–2, frequencies 0–2 (written by daria_call) |
| 0xFE–0xFF | unused |

The audio counters and frequencies are not in the state RAM. The exact tick needs all three counters stepped on the same edge T, and a refresh dispatched at D = T+1 needs all three post-tick values (`arm_mapper_audio.sv:191-195, 231-233`). Only flip-flops with three adders give that (section 10 lists the alternatives).

---

## 5. Audio engine (`fe_audio`): a clone of `arm_mapper_audio`

### 5.1 What is cloned, and what changes

Cloned state for state, edge for edge (`arm_mapper_audio.sv:59-363`):

- the tick;
- the counter add and refresh-pending rule;
- the NOTE latch and NOTE_CAPTURE;
- the dispatch with its snapshot;
- POINTER / SIZE / SAMPLE / DIGITAL_ROUTE / ROM states;
- every address formula, the window and offset rules, the shift, the sum, the nibble rule;
- same-edge priorities (merge over tick; NOTE strobe over its own clear; tick-at-dispatch keeps `rpend`).

| Change | Why | Effect |
|---|---|---|
| BUS (family 2) paths and `waveform_pointer` removed; `ssum` 8 bits | D2; dead or unused bits (AUD:161, 164) | none |
| `ram_grant` = `ram_en && !msel && !u_fe && guard_ok` | `msel` = upstream's `sel_ram_sel`; `init_ram_en` is always 0 while the audio is out of reset (init runs under reset) | exact in mode A |
| RAM data = `crb_q` (word) and lane `alane_q` (byte), byte forced 0xFF while `pause` | same port A semantics (AUD:376-389) | exact, except `pause_lane` |
| Seeds latched by `launch` (all families) and reloaded per voice for an RMW second call | payload and seed are the same register | exact (`seed_race` = 0) |
| Merge per voice at the merge sequencer's strobes, from `stb_q` | the protocol of D5 | `merge_race` (counted) |
| ROM samples: local (< 0x8000) with upstream's **hit** timing, remote port above | D8 | `dig_rom_lat` on an upstream miss, or above 32 KB |

### 5.2 Pseudo-RTL

```
module fe_audio (...);
  localparam [23:0] THR = 24'd14298182, RATE = 24'd20000;   // arm_mapper_audio.sv:8-9, 57
  typedef enum logic [3:0] {IDLE, NISS, NCAP, PISS, PCAP, SISS, SCAP, MISS, MCAP, DROUTE, RISS, RWAIT} st_t;
  // NISS/NCAP = NOTE, PISS/PCAP = POINTER, SISS/SCAP = SIZE, MISS/MCAP = SAMPLE

  // rst = cart_reset ONLY (cart2600.sv:762): a scheme change resets fe_core, never the audio clone
  // ---- tick (reset by cart_reset, as upstream's audio)
  wire tick = tacc >= THR;
  always_ff if (rst) tacc <= 0; else tacc <= tick ? tacc - THR : tacc + RATE;

  // ---- grant, ISSUE address
  wire ram_en = st inside {NISS, PISS, SISS, MISS};
  wire grant  = ram_en && !msel && !u_fe && (!guard_rd || pb_next);   // = u_au
  wire [31:0] rcv  = (voice==0) ? rc[0] : (voice==1) ? rc[1] : rc[2];
  wire [6:0]  wsel = (voice==0) ? wave[0] : (voice==1) ? wave[1] : wave[2];   // live (AUD:113-126)
  wire [31:0] shf  = rcv >> wsh;                                       // only [14:0] are used
  wire [14:0] sos  = woff + shf[14:0];
  wire [14:0] wbase = (rev == 0) ? 15'h07F0 : 15'h01B0;                 // fam 3 only
  always_comb case (st)
    NISS: au_addr = 15'h1C00 + {nval, 2'b00};
    PISS: au_addr = wbase + {voice, 2'b00};
    SISS: au_addr = asz[14:0] + {voice, 2'b00};          // asz >= 0x8000 wraps: class size_over32k
    MISS: au_addr = dsamp ? draddr :
                    (fam==1) ? 15'h0C00 + {wsel, 5'b0} + shf[4:0] :
                    plus     ? (15'h0800 + sos) & (ram32 ? 15'h7FFF : 15'h1FFF) :
                               15'h0800 + {3'b0, sos[11:0]};
    default: au_addr = 15'h0;
  endcase
  always_ff if (grant && !pause) alane_q <= au_addr[1:0];              // cart_ram_tdp.sv:61-64 (pause_lane)
  wire [7:0] rbyte = pause ? 8'hFF : crb_q[{alane_q,3'b000} +: 8];     // top.sv:936

  // ---- counters: tick add, merge (fam 3), one adder per voice
  for v in 0..2:
    wire take_v = mg_c[v] && fam == 3 && (stb_q != seed[v]);           // changed since launch
    wire [31:0] a_v = take_v ? stb_q : cnt[v];
    wire [31:0] b_v = (!take_v && tick) ? frq[v] : 32'd0;
    always_ff if (rst) cnt[v] <= 0; else if (tick || take_v) cnt[v] <= a_v + b_v;
  // ---- frequencies: NOTE (fam 1, from cart RAM) or merge (fam 3, from the call block)
  wire [31:0] fd = (fam == 1) ? crb_q : stb_q;
  for v: wire wf_v = (st == NCAP && nvoice_eff == v) || (mg_f[v] && fam == 3);
         always_ff if (rst) frq[v] <= 0; else if (wf_v) frq[v] <= fd;
  //   nvoice_eff = nvoice, value 3 -> voice 2 (AUD:249-253)
  // ---- seeds: launch (C+1 after a CALLFN; X+1 for a DPC+ pend2), or per voice at an RMW merge
  for v: always_ff if (rst) seed[v] <= 0;
                   else if (launch || (mg_c[v] && pend2)) seed[v] <= cnt[v];
  // ---- NOTE latch (AUD:201-205, 254-255)
  always_ff if (rst) npend <= 0;
    else if (note_wr) {npend, nvoice, nval} <= {1'b1, note_v, note_val};
    else if (st == NCAP) npend <= 1'b0;
  // ---- refresh pending and dispatch
  wire disp = (st == IDLE) && !(npend && fam == 1) && rpend;
  always_ff if (rst) rpend <= 0; else if (disp) rpend <= tick; else if (tick) rpend <= (fam != 0);
  for v: always_ff if (rst) rc[v] <= 0; else if (disp) rc[v] <= cnt[v];

  // ---- the state machine (AUD:225-363, BUS removed)
  always_ff if (rst) {st, voice, woff, wsh, ssum, dsamp, dlow, daddr, draddr, amp} <= {IDLE,0,0,27,0,0,0,0,0,0};
  else case (st)
    IDLE:   if (npend && fam == 1) st <= NISS;
            else if (rpend) begin voice<=0; ssum<=0; dsamp<=0; wsh<=27; st <= (fam==1) ? MISS : PISS; end
    NISS:   if (grant) st <= NCAP;
    NCAP:   st <= IDLE;                                     // frq written above
    PISS:   if (grant) st <= PCAP;
    PCAP:   if (cdf_dig) begin
              daddr <= crb_q + (plus ? rc[0] >> 13 : rc[0] >> 21);
              dlow  <= plus ? rc[0][12] : rc[0][20];   st <= DROUTE;
            end else begin
              woff <= plus ? ((crb_q < 32'h40000800 ||
                               crb_q - 32'h40000800 >= {16'b0, ramsz - 16'h0800}) ? 0 : crb_q[14:0] - 15'h0800)
                           : {3'b0, crb_q[11:0] - 12'h800};
              if (asz == 0) begin wsh <= 27; st <= MISS; end else st <= SISS;
            end
    SISS:   if (grant) st <= SCAP;
    SCAP:   begin wsh <= crb_q[11:7]; st <= MISS; end
    MISS:   if (grant) st <= MCAP;
    MCAP:   if (dsamp) begin amp <= dlow ? {4'b0,rbyte[3:0]} : {4'b0,rbyte[7:4]}; st <= IDLE; end
            else if (voice == 2) begin amp <= ssum + rbyte; st <= IDLE; end
            else begin ssum <= ssum + rbyte; voice <= voice + 1; wsh <= 27; st <= (fam==1) ? MISS : PISS; end
    DROUTE: if (daddr < rom_size) st <= RISS;
            else if (daddr >= 32'h40000000 && daddr - 32'h40000000 < {16'b0, ramsz}) begin
              draddr <= daddr[14:0]; dsamp <= 1; st <= MISS; end
            else begin amp <= 0; st <= IDLE; end
    RISS:   if (rom_ready) st <= RWAIT;
    RWAIT:  if (rom_done) begin amp <= dlow ? {4'b0,rdat[3:0]} : {4'b0,rdat[7:4]}; st <= IDLE; end
  endcase
  // ramsz = ram32 ? 16'h8000 : 16'h2000
  // ---- forwarding into fe_do
  assign amp_we   = (st==MCAP && (dsamp || voice==2)) || (st==DROUTE && out_of_range) || (st==RWAIT && rom_done);
  assign amp_next = rst ? 8'h00 : (amp_we ? amp_d : amp);   // amp_d = the value the case above assigns
endmodule
```

### 5.3 Exactness argument

The clone's next state is a function of its own state and of these inputs:

| Input | Why mine equals upstream's |
|---|---|
| `tick` | same accumulator and same reset signal; first tick at R+716 (AUD:228-246) |
| `grant` | `msel` is upstream's `sel_ram_sel` clock for clock (A2 checks it). The extra terms are 0 in mode A: `u_fe` is 0 whenever `!msel`, given C ≥ E6; `guard_rd` is 0 because the guard is unlocked |
| `crb_q` at g+1 | it equals upstream's port-A word at g: same image (F6), same 6507-side writes as seen by audio reads (section 3.1: DSWRITE at C, PUSH/WRITE invisible, pointers at C+1/C+2 = upstream's E7.8), and ARM writes (mode A mirror on upstream's non-shared edges, BEN 7.4.3). Exceptions: a DPC+ copy/fill in progress (`copy_race`), `tbl_alias` (6507-side only) |
| `rbyte` | same lane and pause rule, except a capture straddling a pause release (`pause_lane`) |
| `wave`, `cdf_dig`, `note_wr`/`note_v`/`note_val` | front-end flip-flops changed at C = E6; the NOTE strobe in c0 = (E6, E7] (mapper_dpcplus.sv:221, 311-315) |
| `launch` | C+1 = upstream's L = E7: upstream always accepts at E7 (BEN 7.4.4) |
| merge strobes and `stb_q` | not upstream's edges, except c0 at M → `merge_race` |
| `rom_done`/`rdat` | local hit timing = upstream's hit timing; differs on a miss → `dig_rom_lat` |

Hence the FSM state, `amp` and its write edge equal upstream's. `fe_do` = `amp_next` shows the same AMPLITUDE in every clock, and the 6507 latch at any C sees upstream's value. **`amp_lag` = 0.**

NOTE_CAPTURE happens on the same edge with the same word, so **`note_race` = 0**. Ticks and refreshes during calls are granted immediately, as upstream's are (AUD:1045-1054).

### 5.4 Seeds and merge against pending ticks

- **Seeds.** `seed[v]` ← `cnt[v]` at C+1, which is every tick ≤ E6 and none at ≥ E7: exactly upstream's `call_seed_counter` and payload (`arm_mapper_audio.sv:207-211`, `arm_mapper_controller.sv:149-161`). With flip-flop counters there are no deferred tick jobs, so no ordering logic is needed. **`seed_race` = 0.**
- **Merge.** At voice v's strobes (c at `Cv` = X+1+2v, f at `Fv` = X+2+2v):
  - a changed counter takes the return and loses a tick on the same edge;
  - an unchanged counter takes the tick with the old frequency;
  - the frequency is replaced on its edge, and a tick on that edge still uses the old value (non-blocking).

  These are upstream's rules applied at `Cv`/`Fv` instead of M.

**`merge_race` (exact definition, CDF only)**, for voice v of a call:

| Case | Condition |
|---|---|
| counter changed (return ≠ seed) | a tick in (M, `Cv`], or a dispatch D in (M, `Cv`] |
| frequency changed (return ≠ the live frequency) | a tick in (M, `Fv`] |
| otherwise | no difference |

Voice 0's counter is merged exactly at M, so its window is empty. The longest window is 5 clocks, so P(race) ≤ (1+3+5)/716 ≈ 1.3% of calls that change a frequency, and less for counters. With `+fe_merge_hook=1` all six merge at M and `merge_race` must be 0.

### 5.5 NOTE (DPC+)

- C: strobe `note_wr` in c0.
- C+1: `npend`, `nvoice`, `nval` latched.
- IDLE → NISS (the NOTE beats a refresh), the grant on the mirror, NCAP writes `frq[nvoice]` from `crb_q`.

The overlap table (AUD:796-820, including the "mixed" row at s = g) falls out of the identical registers.

### 5.6 Digital mode (CDF)

- **RAM samples:** MISS with `dsamp` reads `draddr` on the grant. Exact.
- **ROM samples, local** (`daddr` < 0x8000 and < `rom_size`).

  Upstream's hit timing is:
  - R = the RISS edge with `rom_ready`;
  - MEM's `sample_done` pulse in (R+3, R+4];
  - `amp` at R+4 (AUD:713-720).

  The clone's local path:

  ```
  // rom_ready = !rbusy_l && !rbusy_r   (neither reset by cart_reset: upstream's orphaned sample_busy, AUD:633-635)
  at R (st==RISS && rom_ready && local): rcnt <= 1
  rcnt counts 1..4, then 0
  feb read of daddr[14:2]: issued in the first clock with rcnt in {1,2} that is not a CDF s0 (lookahead); q next clock
  rdat <= feb_q[lane]           // byte daddr[1:0]
  rom_done = (rcnt == 4)        // (R+3, R+4]  =>  amp at R+4, as upstream's hit
  ```

  So upstream's hits are exact. Upstream's misses (a new 8-byte DDR word, or a pointer change) are later on upstream's side: `dig_rom_lat`.
- **ROM samples, remote** (≥ 0x8000):
  - at R: `smp_addr` ← `daddr[18:0]`; `smp_req` ← ~`smp_req`; `rbusy_r` ← 1.
  - Answer: `ans_s` (two flops). When `ans_s[1]` != `ans_seen`: `rdat` ← `smp_data`, `ans_seen` ←, then `rom_done` for one clock, `rbusy_r` ← 0.
  - Latency is the wrapper's: `dig_rom_lat`.

  **Protocol:** the address is held from the toggle to the answer; one request is outstanding; the wrapper's clk_arm side reads the byte through the asset cache (DC 3.2 "Samples") and flips `smp_ans`. In mode A the bench answers with `img[a]` after `+fe_slat` clocks (BEN 7.4.5).

### 5.7 Pause (D9)

- The clone has no pause input except the byte force. Ticks, counters and refreshes run on.
- Sample bytes read 0xFF; words read true data (top.sv:934-936).
- A frozen selecting 6507 cycle blocks grants through `msel`.
- Counted: `pause_lane` (a capture straddling the release reads a stale lane upstream; AUD:376-389). In mode B, DARIA's CPU runs during pause where upstream's ARM stops (`pause_call`).

### 5.8 AMPLITUDE: the residual classes (all counted, none expected in the 21 images)

| Class | Condition | Mode |
|---|---|---|
| `merge_race` | section 5.4; amplitude compared again from the first refresh dispatched after `F2` | A, B |
| `dig_rom_lat` | upstream RISS→`amp` ≠ 4, or `daddr` ≥ 0x8000 | A, B |
| `copy_race` | a grant reads a byte in [dst, dst+cnt) while either side's DPC+ copy/fill runs | A, B |
| `pause_lane` | pause high in (g−1, g], low in (g, g+1] | A |
| `short_phase1` | `pclk1`→`pclk0` < 6 | A, B |
| `pre_lock` | refreshes with a grant before `tia_en` (BIOS path; upstream reads the 7800 path's address, AUD:1127-1146) | A |
| `size_over32k` | `asz` + 8 > 0x7FFF (upstream reads 128 KiB RAM, DARIA wraps) | A, B |
| `guard_shift` | `guard_rd` delays a grant (hardware and mode B only) | B |

---

## 6. Call side (`fe_call`)

```
// at C, a CALLFN that arms (DPC+ D10 / CDF C9):
//   new call:  if (!busy) start <= 1 (strobe in c0)
//   RMW:       else if (!pend2) pend2 <= 1     // CR finding 18: second CALLFN while a call is in flight
launch     = start in c0  ||  launch2 (DPC+, the clock after ret_new with pend2)
busy       : set at C+1 (start); cleared at a rel_ok edge with rel_req && !pend2; cleared by rst
call_win   : set at the call_tog flip; cleared when busy clears; cleared by rst
// post: post_act set by start (F0..F7) or by the end of the merge with pend2 (F2..F4 only;
//   F0/F1 unchanged; F5-F7 must keep the pre-merge frequencies = call 1's words: CDF
//   frequencies change only at merges, DPC+ only at NOTE, and neither can happen in between)
//   stb_addr = 8'hF0 + post_k; stb_wd = {entry|T, stack, seed_sel, frq_sel}[post_k]; post_k++ on issue
//   entry|T = is_dpc ? 32'h0C09 : plus ? {cdfj_entry[31:1],1'b1} : 32'h0809; stack = plus ? cdfj_stack : 32'h40001FFC
// flip: call_tog <= ~call_tog at the edge that registers the last post word, or later, iff
//       daria_ready && !cart_reset (D5);  ret_wait <= 1
// return:
ret_s    <= {ret_s[0], ret_tog};        ret_new = ret_wait && (ret_s[1] != ret_seen);
if (rst)  ret_seen <= ret_s[1];          else if (ret_new) begin ret_seen <= ret_s[1]; ret_wait <= 0; end
mq       : mq[0] = ret_new && is_cdf (combinational, issues 0xF8); mq[k+1] <= mq[k] (k = 0..5)
stb read address: mq[0] F8, mq[1] FB, mq[2] F9, mq[3] FC, mq[4] FA, mq[5] FD
mg_c[0] = mq[1], mg_f[0] = mq[2], mg_c[1] = mq[3], mg_f[1] = mq[4], mg_c[2] = mq[5], mg_f[2] = mq[6]
p32_req  : set by ret_new (CDF) or by F6's end; cleared when u_p32 issues; p32 <= crb_q in the next clock
rel_req  : CDF: mq[6] done && !p32_req;  DPC+: ret_new;  then if pend2: post F2..F4, flip, pend2 <= 0
// reset (cart_reset): busy, call_win, post_act, mq, pend2, ret_wait <= 0; ret_seen <= ret_s[1];
//   call_tog keeps its value (DI:368)
```

| Situation | Behaviour |
|---|---|
| Hardware call ready | `call_ready = daria_ready && !cart_reset`. A CALLFN while not ready (R12): busy at C+1, post, then the flip waits |
| Halt during a call | the call never returns; busy stays high; a console reset recovers (DI:377) |
| Mode A | `daria_ready` = upstream's `arm_online_sync2 && shadow_ready_sync2` (without `call_busy`: CR finding 8). The bench queues each upstream return until my flip for that call number has happened, then flips the emulated `ret_tog` (BEN 7.4.4, CR finding 6). Then X matches upstream's X, and voice 0's counter merges at M |
| RMW second call | DPC+: seeds reload at X+1 = M, exact. CDF: seed v reloads at `Cv` (pre-merge value per voice), which differs from upstream's M only if a tick falls in (M, `Cv`]. My busy stays high where upstream's dips one clock. Counted `rmw_call` |
| `call_pending` tap | set at C, cleared at C+1 on a launch (upstream's clear at accept), or at `launch2`/flip for `pend2` |
| Release | `arm_call_busy` falls only at a `rel_ok` edge (D3), after the merge and `p32` refresh (CDF) or `ret_new` (DPC+). In mode B and hardware this removes upstream's release-window duplicate commit (`rel_dup`, counted). In mode A the busy-fall offset against upstream's X is a histogram |

---

## 7. F6, state-RAM clear, copy/fill, `init_busy`, `dma_busy`

### 7.1 Triggers and `init_busy` (D6)

```
// latched at load_end+1, like upstream's active_family (arm_mapper_ram_init.sv:212-218)
always_ff if (load_end_d) {f6_ok, f6_dpc, f6_plus, f6_ram32} <= {is_dpc||is_cdf, is_dpc, plus, ram32};
load_end_d <= load_end;
always_ff if (load_start) f6_ok <= 0;              // image_loaded cleared
rst_q <= cart_reset;  rise = cart_reset && !rst_q;
// start sources:
//   (a) load_close && f6_ok      (capture window closed: R6, CR finding 7)
//   (b) rise && f6_ok && !f6_run && !loading   ->  dly <= 7, count down; start at dly==0  (>= 8 clk_sys, CR finding 17, D4)
//   never on a falling cart_reset
init_busy: set by load_start, and at (b)'s rise;
           cleared at load_end_d if !(is_dpc||is_cdf)  (non-ARM image: no F6)
           cleared at F6's end.
           Continuous from load_start through the download, the 64-clock window and F6 (DI:417)
```

`init_busy` feeds the wrapper's registered reset OR (atari7800_pocket.sv:169-171). With the reset held, `cart_reset` cannot rise again during F6 (GL:90).

### 7.2 F6 (word-wide) and the state-RAM clear

| Scheme | Phase 1 | Phase 2 | Clocks |
|---|---|---|---|
| DPC+ | fill RAM words 0x000–0x2FF with 0 (768) | copy ROM words 0x1B00–0x1FFF → RAM words 0x300–0x7FF (1,280) | 2,048 + 2 |
| CDF0/1/J (8K) | copy ROM words 0x000–0x1FF → RAM 0x000–0x1FF (512) | fill RAM 0x200–0x7FF (1,536) | 2,048 + 2 |
| CDFJ+ (32K) | the same copy (512) | fill RAM 0x200–0x1FFF (7,680) | 8,192 + 2 |

These are the image and RAM ranges of `arm_mapper_ram_init.sv:141-172`:

- DPC+: fill 0x0000–0x0BFF, then copy image 0x6C00–0x7FFF to RAM 0x0C00–0x1FFF.
- CDF: copy 0x0000–0x07FF, then fill 0x0800 to `ram_size` − 1.

The copy pipeline issues feb word i in clock k and crb-writes word i (be F) in k+1, so one word per clock.

In parallel, on stb: words 0x00–0x10 ← 0, which takes 17 clocks. That resets the DPC+ fetchers and params, which upstream resets with `reset || mapper != DPCP`.

At the end, for CDF, `p32_req` loads the stream-32 copy (one crb read). Then `init_busy` ← 0.

### 7.3 DPC+ copy/fill service (D7)

```
// accepted at C+1 from svc_* (latched at C with upstream's exact clamps, section 2.2 D10)
svc_act <= 1 (C+1);  arm_dma_busy <= 1 (C+1)       // upstream: dma_busy at E7 (GL:249)
src (15, byte), dst (13, byte), cnt (8), fill, val
fill: each clock with u_cp granted: crb write dst (be 1<<dst[1:0], data {4{val}}); dst++; cnt--
copy: feb issue src[14:2] when the byte register is empty; next clock cbyte <= feb_q[src[1:0]];
      write cbyte at dst when u_cp is granted; src++, dst++, cnt--
done: cnt == 0 and no byte in flight  ->  svc_act <= 0; arm_dma_busy falls at the next rel_ok edge
arm_dma_busy is forced 0 while init_busy (R2)
```

- **Clamps.** The source stops at image 0x7FFF and the destination at 0x1BFF, by the counts computed at C (mapper_dpcplus.sv:85-101). The source bound is 0x8000, not the sketch's 0x7C00 (DI:423).
- **Rate.** About one byte per clock less the audio's grants: 255 bytes take about 270 clocks (about 22 6507 cycles). Upstream's fill is about 4 bytes per clk_sys, and its copy is DDR-paced (GL:254-255). The difference is `dur_svc` (info). In mode A the forced hold covers both (BEN 7.4.2).
- **The audio keeps priority** (CR finding 21).

---

## 8. Phase detector and guard (`fe_guard`)

### 8.1 RTL

```
// clk_arm: one flop
(* preserve *) logic pd_at = 1'b0;
always_ff @(posedge clk_arm) pd_at <= ~pd_at;
// clk_sys
(* preserve *) logic pd_st = 1'b0;          // receives pd_at on the constrained path (not a synchroniser)
logic pd_q = 1'b0;  logic [1:0] pd_ph = 2'd2;  logic [3:0] pd_lk = 4'd0;
always_ff @(posedge clk_sys) begin
  pd_st <= pd_at;
  pd_q  <= pd_st;
  pd_ph <= pd_same ? 2'd0 : ((pd_ph == 2'd2) ? 2'd2 : pd_ph + 2'd1);
  pd_lk <= (pd_same == (pd_ph == 2'd2)) ? ((pd_lk == 4'd15) ? 4'd15 : pd_lk + 4'd1) : 4'd0;
end
wire pd_same = (pd_st == pd_q);      // no parity change at the last edge: it was the shared edge
wire locked  = (pd_lk == 4'd15);
wire pb_next = locked && pd_same;    // the edge that ends this clock is phase B
```

Why it works. Take one 144-VCO frame, with clk_sys edges at 0, 48, 96 and clk_arm edges every 18. `pd_st` at a clk_sys edge holds the parity of the clk_arm edges in [previous edge, this edge):

| Interval | clk_arm edges in it | Count | `pd_st` at the end |
|---|---|---|---|
| [0, 48) | 0, 18, 36 | 3 | changes |
| [48, 96) | 54, 72, 90 | 3 | changes |
| [96, 144) | 108, 126 | 2 | holds |

The toggle launched at 144 is seen at 192, so in the clock after the shared edge `pd_st == pd_q`. That happens once in three clocks (DI:684-692). The lock needs 15 consecutive consistent clocks and drops on any inconsistency, so it re-locks by itself after a pause, a reset or a PLL relock.

- **Mode A** (`clk_arm` = 5 × clk_sys): 5 toggles per interval, always odd, so `pd_same` is never true and the detector stays unlocked. The guard is inert.
- **÷19 fallback:** no period-3 pattern, so unlocked and inert (CR finding 35).

### 8.2 SDC (two lines, `core_constraints.sdc`)

```
set_max_delay -from [get_registers {*|daria_fe:*|fe_guard:*|pd_at}] -to [get_registers {*|daria_fe:*|fe_guard:*|pd_st}] 6.000
set_min_delay -from [get_registers {*|daria_fe:*|fe_guard:*|pd_at}] -to [get_registers {*|daria_fe:*|fe_guard:*|pd_st}] 1.000
```

These are reg-to-reg and more specific than the clock-level ±20 ns pair (DC:1166-1174), so they win.

- A max of 6 ns is below 8.73 ns: the toggles launched 8.73 ns or 17.46 ns before an edge are captured by it.
- A min of 1 ns stops the toggle launched on the shared edge from being captured on that same edge, given less than 1 ns of skew between the two global networks; that skew must be checked in STA (DI:726).
- `pd_st` is not marked as a synchroniser.

### 8.3 Lock rule and windows

```
guard_rd = locked && (call_win || !daria_ready_q)                 // daria_ready_q: the input, registered
guard_wr = locked && (call_win || !daria_ready_q) && !f6_run
```

The section 3.4 table applies.

### 8.4 How the bench checks it (mode B, `+d_ofs` ∈ {0, 8730, 17460}, BEN 6.3)

- **`det_bad`.** A clk_sys edge at t is shared iff `(t − d_ofs) % 26190 == 0`, and the edge after a shared one is phase B. After `locked`, every edge with `pb_next` high pre-edge must be phase B, and every phase-B edge must have it. `det_bad` must be 0, and the detector must lock within 24 clk_sys of reset release.
- **`pb_bad`.** Count consumed crb reads (`u_au`, `u_p32`) registered in the guard window on a non-phase-B edge. Must be 0.
- **Collisions.** `coll_d_same` = 0 and `coll_d_ld_same` = 0 (BEN 6.4), with `crb_use` as the read side.
- **`guard_wr_conflict`** = 0.
- **Mode A:** `locked` must stay 0 for the whole run.

---

## 9. Upstream quirks and counted differences

### 9.1 Quirks reproduced (from the specs), and how

| # | Quirk (source) | How the design reproduces it |
|---|---|---|
| 1 | Commit only on `access && a_in[12]`; the combinational outputs act regardless (DPC 14.1, CDF 0.2) | commit at the edge sampling `access`; `fe_mux` and `msel` are live |
| 2 | The 6507 latches the pre-commit `d_out` (DPC 14.2) | `fe_do` loaded from pre-commit state; latch in s5 |
| 3 | RANDOM0NEXT/PRIOR return the low byte of the **stepped** value; no unstepped byte 0 (DPC 14.3) | `rnd_next[7:0]` / `rnd_prior[7:0]` in `fe_mux`; step at C |
| 4 | $006/$007/$024–$027 read $00 with oe = FF (DPC 14.4) | `dpc_rb` = 0; `fe_oe` = `a[12]` |
| 5 | DFxFLAG only on $020–$023; fetchers 4–7 read 0 (DPC 14.5) | `dpc_rb` term `i < 4` |
| 6 | Window flag 8-bit modular, from the pre-increment counter (DPC 14.6) | `win(w0)` from the s0/s1 read |
| 7 | 12-bit counter and 20-bit fraction wraps (DPC 14.7) | lane writes; spare nibbles masked (BEN 7.3) |
| 8 | FRACLOW keeps or clears [7:0] by `revision[0]`; FRACHI/HI use `d[3:0]`; FRACINC clears [7:0] (DPC 14.8) | D7 byte enables |
| 9 | PUSH writes at ctr−1 then decrements; WRITE at ctr then increments; $068–$077 never touch RAM (DPC 14.9) | D8 `ra`; decode |
| 10 | RAM strobe repeats E2–E6, not gated by the lock (DPC 14.10) | one write at c0, gated by the commit; invisible (section 2.2 D8); `ram_wr_noaccess` asserted 0 |
| 11 | Fast fetch arms on **any** committed cart read of $A9, is consumed by the next committed cart read < $28 at any address, and is untouched by writes and A12=0 (DPC 14.11) | upstream's next-state at C (mapper_dpcplus.sv:234-252) |
| 12 | 6-bit register space via fast fetch ($20–$27 reach FLAG) (DPC 14.12) | `rom_b[5:0]` |
| 13 | Hotspots on reads and writes return the old bank's byte; only a fast-fetch operand suppresses them (DPC 14.13) | live mirror byte in s5; bank at C |
| 14 | Fast-fetch operand: after C `d_out` falls back to the ROM operand; before the byte settles, the decode follows the stale byte (DPC 14.14) | live predicates on the mirror (tb model: s0 stale) |
| 15 | FASTFETCH = (d == 0) (DPC 14.15) | D9 |
| 16 | PARAMETER pointer saturates at 8; reset by CALLFUNCTION 0 and a taken 1/2 only (DPC 14.16) | `pptr` 4 bits; D10 |
| 17 | 1/2 ignored while `service_pending`; FE/FF ignored while `call_pending`; a write on the accept edge of a pending request is dropped (DPC 14.17, DPC 8.3) | `spend`/`cpend` with upstream's clear-at-accept |
| 18 | Clamps with index `params[2] & 7`; count 0 still runs a service (DPC 14.18) | D10; a count-0 service raises `arm_dma_busy` for one `rel_ok` window |
| 19 | `service_source = 0xC00 + off`, `dest = 0xC00 + ctr`, `value = p0` also on a copy (DPC 14.19) | D10 |
| 20 | Request at E6, accept at E7 (DPC 14.20) | `launch` and `arm_dma_busy` at C+1 |
| 21 | Waveform 7 bits; NOTE one-clock strobe; voice = `a[1:0]−1` (DPC 14.21) | D9 |
| 22 | Reset: bank 5 (DPC), 6 or 0 (CDF, from the live revision), LFSR 0x2B435044, mode 0xFF, `jst` 33 (DPC 14.22, CDF 4) | reset values; scheme change = reset |
| 23 | `ram_sel` (audio starvation) windows, including held repeats and transients (DPC 14.23, CDF Q1/Q8, AUD 13) | **`msel`**, every clock |
| 24 | S1–S5 stall effects (WSYNC re-commits, release-window duplicate, late stall, RMW lost commit) (DPC 13) | inherited through `access` in mode A. In hardware, D3's release gate removes the duplicate (`rel_dup`) |
| 25 | Held repeats re-present the previous address (DPC 14.25) | inherited |
| 26 | CDF: tables idle at stream 32 (Q2) | `p32` plays that role for DSWRITE/DSPTR |
| 27 | CDF: arming byte-based, survives A12=0 cycles (Q3) | upstream's next-state |
| 28 | CDF0/1 reject operand 1 = 01 at fetch (Q4); `fast_mode` tested only at arming (Q5) | `jov` with `jrev`; `c_js` has no `fast_mode` |
| 29 | Jump streams step one byte; fetch of 33/34 uses the increment (Q6) | C5 `step`; C2 `ishift` |
| 30 | Amplitude: no RAM, no pointer update, clears `fpend` (Q7) | C4 |
| 31 | No bank switch on substituted reads (Q9) | C10 `!c_ss` |
| 32 | CDFJ+ display address wraps mod 32 KiB (Q11), and the DSWRITE wrap does not update the table copy | `disp()` mod 0x8000. Table copy: exact for stream 32 (`p32`); `tbl_alias` for others |
| 33 | Non-plus display address `0x800 + P[31:20]` (Q12); only `inc[15:0]` (Q13); offset not version-gated (Q14) | C2 |
| 34 | DSWRITE store is a one-clock strobe tied to `access` (Q16) | C6 `we = access` |
| 35 | `call_pending` persists while not ready (Q17) | `cpend` semantics; in hardware the busy rises at C+1 regardless (R12) |
| 36 | Map edge entries 0x7FFE/0x7FFF never arm; lookahead crosses bank ends linearly (Q18, DPC 2.7.5) | `jok_l` with `!&rom_a[14:1]`; feb `+1` word linear |
| 37 | CDFJ+ entry and stack from detect, captured for every file (Q19); override inheritance (Q20) | inputs |
| 38 | Stall phase-2 accounting (Q25) | inherited |
| 39 | `pu_val` from the previous edge's table word (Q26) | only with C = E2; `short_phase1` |
| 40 | ROM reads not A12/RW-gated: the stale byte is the previous `a_in`'s, whatever it was (Q27) | the mirror registers `rom_a` for every `a_in` |
| 41 | Audio: PAL keeps NTSC `CLK_RATE` (AUD 16.1) | constants |
| 42 | Ticks coalesce; a tick at the dispatch edge stays queued; NOTE beats refresh; the NOTE overlap table (AUD 16.2–16.5) | clone |
| 43 | Waveforms and digital flags read live mid-refresh; a digital switch at voice 1/2 uses that voice's pointer with counter 0 (AUD 16.6) | clone (`wsel` live, `cdf_dig` live, `rc[0]`) |
| 44 | Sum mod 256; CDF0/1/J aliasing; CDFJ+ window and wrap; size `word[11:7]`; nibble rule; out of range → 0 (AUD 16.7–16.11) | clone |
| 45 | Merge rule: counter only if changed from the seed; frequencies always; DPC+ ignores returns (AUD 16.12) | section 5.4 (edges: `merge_race`) |
| 46 | Engine through pause: bytes FF, frozen select blocks grants, lane frozen (AUD 16.13) | `rbyte`, `msel`; `pause_lane` |
| 47 | Engine reset only by `effective_reset` (AUD 16.14) | `cart_reset` |
| 48 | Launch at M seeds pre-merge (AUD 16.18) | `pend2` rule (`rmw_call` for CDF voices 1/2) |
| 49 | `rom_ready` waits for an orphaned sample (AUD 7.3 item 5, G7) | `rbusy` not reset by `cart_reset` |

### 9.2 Counted differences (class, condition, which mode)

| Class | Condition | Mode | Expected |
|---|---|---|---|
| `merge_race` | section 5.4 | A, B | ≤ ~1% of CDF calls that change a counter or frequency |
| `rmw_call` | a CALLFN commit while my call is in flight; CDF voices 1/2 seeds and the one-clock stall dip | A, B | 0 (no driver does it) |
| `tbl_alias` | CDFJ+ DSWRITE byte address in [4·`pb`, 4·(`ib`+C)), excluding stream 32's word; the stream is excluded until the ARM rewrites the word | A, B | 0 |
| `copy_race` | section 5.8 | A, B | 0 (no image uses copy/fill) |
| `dig_rom_lat` | section 5.8 | A, B | unknown: digital use not recorded (R4) |
| `pause_lane`, `pause_call` | section 5.7 | A / B | bench ties pause to 0 |
| `short_phase1` | `pclk1`→`pclk0` < 6 | A, B | 0 unless RSYNC |
| `obus_drift` (info) / `obus_exposed` (must be 0) | DPC+ DATA/DATAW/FRACDATA direct reads after C | A | `obus_exposed` = 0 (section 9.3) |
| `pre_lock` | section 5.8 | A | 0 with `bypass_bios` |
| `size_over32k` | `asz` + 8 > 0x7FFF | A, B | assert |
| `img29k` | DPC+ 29,696-byte image: F6 and the service read front-end ROM bytes past the file (stale from the previous cartridge, as upstream's stale DDR; CR finding 25) | A, B | documented |
| `ram_wr_noaccess`, `wbuf_ovr`, `grant_steal` (outside `short_phase1`), `guard_wr_conflict` | assertions | A, B | 0 |
| `rel_dup` | upstream's release-window duplicate commit, removed by D3 | B, hardware | about half of upstream's calls |
| `guard_shift` | section 5.8 | B, hardware | inside the call window only |
| `dur_f6`, `dur_svc`, `busy_ofs` (info) | durations and busy-fall offsets | A, B | histograms |
| `live_override` | scheme change without a console reset | — | documented |
| `merge_value` | T1TC-dependent returns (BEN Q7) | B | rare |

`amp_lag`, `note_race`, `seed_race` and `amp_input_race` are **assertions (0)**.

### 9.3 Why `obus_exposed` stays 0

The only post-commit `fe_do` that differs from upstream's is the DPC+ RAM-backed direct read, which shows the old byte against upstream's next byte. Its next cycle is a cartridge read, fully driven:

- an opcode fetch; or
- a page-crossing dummy read. `LDA $10xx,X` dummy-reads `$10yy` and then reads `$11yy`, a cart read. A TIA/RIOT read after a register-window read would need a base of `$1Fxx` (DI:603).

---

## 10. Area and timing

### 10.1 Estimate per block

| Block | FF | ALMs [E] | Basis |
|---|---|---|---|
| `fe_core`: DPC+ and CDF decode and next-state, LFSR, mirror byte and `msel`, service latch and clamps, `fe_do` | ~270 | 380–430 | sketch core 436 incl. BUS (README:442); −60 BUS; +15 `msel`; +25 exact clamps and service latch |
| `fe_dp` plus the port arbiters: W + adder + B mux, `p32`, `wbuf`, display/field arithmetic, crb/stb/feb muxes, post data mux | ~150 | 260–320 | sketch datapath and arbitration 239 (README:441); −20 audio B sources; +45 `p32`/`wbuf`; +40 more port users; +30 post mux |
| `fe_audio` (clone) | ~560 | 470–560 | upstream `arm_mapper_audio` live 657 ALMs / 518 FF [probe] (README:61): −40 BUS paths, −15 dead `waveform_pointer`, sum 10→8; +96 FF seeds kept on this side; +20 local and remote ROM sample |
| `fe_copy`: F6 word mode, service byte mode, clear, reset-edge delay, latches, `init_busy`, `dma_busy` | ~85 | 100–130 | sketch copy 104 (README:443) |
| `fe_call`: post FSM, toggles and sync, merge sequencer, `pend2`, release | ~45 | 60–90 | DC's controller estimate 100–150 (DC:1298) less the clk_arm side built in daria_call |
| `fe_guard` | 9 | 8–12 | DI 9.3 |
| **Total** | **~1,120** | **1,280–1,540** | |

| Comparison | ALMs |
|---|---|
| Lean estimate (DC:1298) | 850–1,100 (sketch measured 1,004) |
| **Exactness premium** | **+350 to +450**: the audio clone about +250–330; `msel`, `wbuf` and `p32` about +60–80; merge and RMW about +30 |
| Device effect | DC:1598 projects 14,872–15,382 with the lean front end. With this one, about **15,300–15,830 (82.8–85.7% of 18,480)**, against the 84% gate (DC:1601) |
| M10K | 0 new (daria_mem as built) |

### 10.2 Reductions, if area forces them (each keeps mode A exact on the 21 images)

| Option | Saves | Exactness cost |
|---|---|---|
| R-a: drop the refresh snapshots `rc[0:2]`; the SAMPLE/DIGITAL addresses use the live `cnt[voice]` | 35–50 | `snap_race`: a counter change (tick or changed merge) between D and a voice's last issue. Ticks need ~700 clocks of blocked grants (pause or a late launch); changed merges are rare (Draconian's reset-counter helper: 4 calls) |
| R-b: no `p32` copy; DSWRITE/DSPTR read stream 32 from RAM in s1/s2 (outside upstream's select) | 20–30 | the s1/s2 reads steal audio grants → `amp_lag` returns for DSWRITE/DSPTR cycles. **Not recommended** |
| R-c: the merge compare via read-back of F2–F4 (seeds out of FF after posting) | 15–25 | +3 merge reads: windows grow by 3 clocks (`merge_race` ×1.5) |
| R-d: remote digital port left out (offsets ≥ 32 KB amplitude 0) | 15 | wrong for digital samples beyond 32 KB (none known) |

### 10.3 The clk_sys critical path (69.84 ns; nothing is near it)

| Path | Levels | Estimate |
|---|---|---|
| Audio sample address: `rc` 3:1 → 32→15 barrel shift (5) → 15-bit add (`woff`) → +0x800 & mask → crb address mux | about 12 LUTs + 2 carry chains | 25–30 ns |
| Mirror → `msel`: `fea_q` → lane 4:1 → operand range compares, `a_in` equalities (pre-registered compares possible) → `msel` → grant → crb select/address mux → M10K address | about 8 | 15–20 ns |
| CDF pointer: `crb_q` → `disp()` (15-bit add) → crb address | about 5 + carry | ~12 ns |
| Merge: `stb_q` → 32-bit compare with `seed` → counter adder input → 32-bit carry → `cnt` | about 4 + carry | ~15 ns |
| `amp_next`: `crb_q` → lane → 8-bit add → `amp` mux → `fe_mux` → `fe_do` | about 5 | ~10 ns |
| `access` (top.sv phase logic) → crb `we`/select (DSWRITE) | about 4 | ~10 ns |

- **clk_arm:** only `pd_at` (a toggle).
- **No path into clk_sdram:** `fe_do`, `fe_oe`, both busy outputs and `init_busy` are registers; `rom_addr`/`ram_sel` for BANKDPCP/BANKCDF stay constants. Fix B's structural check still finds no path.

---

## 11. Risks and what to test first

### 11.1 Risks

1. **Area (highest).** +350–450 ALMs puts the single bitstream at 83–86%.
   - Mitigation: synthesise `fe_audio` alone with `MUX_RESTRUCTURE OFF` first (README:483); pick from 10.2.
   - Fallback: drop to the lean audio with counted `amp_lag`; the rest of this design stands.
2. **`msel` fidelity.** Any decode difference against upstream's `sel_ram_sel` shifts a grant by a clock and breaks AMPLITUDE exactness.
   - Mitigation: the A2 check every clock, from the first run. The same predicates also drive the commit, so C1/C2 cross-check them.
3. **Clone fidelity.** A transcription error in the FSM.
   - Mitigation: the A1 every-clock compare against upstream's registers, and a ROM-free unit bench (11.2 step 1).
4. **The port invariant** (`u_fe ⇒ msel`, `u_au ⇒ !u_fe`). Mitigation: assertions A3 and `grant_steal`.
5. **The mirror port assumption.** It equals tb_daria's 1-clock ROM by construction. MiSTer's `sdram.sv` timings are out of scope (D1, CR finding 28).
6. **Merge in mode A.** `merge_race` depends on the bench's return queue. Mitigation: `+fe_merge_hook=1` isolates logic from timing.
7. **Digital ROM samples.** Upstream's miss latency cannot be matched, and use by real images is unknown (R4). Mitigation: T4 compares addresses; `dig_rom_lat` is counted.
8. **Hardware only.** The detector SDC pair and network skew at the shared edge (DI:726); `NEW_DATA_NO_NBE_READ` semantics (DI:727). Mitigation: STA report on the `pd_at`→`pd_st` path; the mode B `d_ofs` sweep.
9. **Untested by the image set:** DPC+ copy/fill, CDF0, RSYNC, pause, the BIOS path, `+hard_reset_at`. Directed runs are needed (BEN 7.9 item 7).
10. **`asz` ≥ 0x8000** (DI:728). Asserted (`size_over32k`).

### 11.2 Test first, in this order

1. **ROM-free unit bench of `fe_audio` against upstream's `arm_mapper_audio`** (both MIT, Verilator).
   - The same random stimuli feed both: `sel` patterns, NOTE strobes, waveform and mode changes, `launch`, `call_done` with returns, pause, ROM-sample answers with hit timing, and the cart-RAM word and byte data.
   - Merge strobes for mine are placed at M, with `pend2` off.
   - Compare every register every clock, for 10⁸ clocks.
   - This proves the clone before any 6507 logic exists.
2. **The `msel` and next-state logic beside upstream in tb_daria** (BEN 7.9 step 0: reference front end first).
   - Run A2 (`msel` == `sel_ram_sel`) and C1/C2 with my `fe_core` fed from the taps, on one DPC+ and one CDFJ image for 120 frames.
3. **The whole `daria_fe` in mode A** on the same two images: L1, T1/T2, A1 (my audio against upstream's, every clock), R1 with `seed_race` = 0, and then the hook variant.
4. **All 21 images × 1,500 frames.**
5. **Directed tests:**
   - DPC+ copy/fill with clamps (R2/R3, `copy_race`);
   - a synthetic CDF0;
   - CDF digital mode with RAM and ROM samples;
   - an RMW CALLFN;
   - a mid-line RSYNC;
   - `+hard_reset_at`;
   - pause;
   - `use_bios`.
6. **Synthesis probe** of the whole `daria_fe`: ALMs, FF, Fmax at clk_sys, and the `pd_at`→`pd_st` constraint report.
7. **Mode B** with the `d_ofs` sweep: `det_bad`, `pb_bad`, `coll_d_same`, `guard_wr_conflict`.
