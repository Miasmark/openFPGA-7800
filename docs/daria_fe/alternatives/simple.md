# `daria_fe`, architecture C: "simple to verify"

A micro-architecture for DARIA step 6: the 6507-side front end for DPC+ and the CDF family (CDF0, CDF1, CDFJ, CDFJ+), its audio engine, its RAM image (F6), the DPC+ copy/fill engine, its half of the call port and the shared-edge guard. BUS and ELF stay bad-game screens (D2).

Written from `docs/daria_fe/spec/{critic,design_inputs,bench,dpcplus,cdf,audio,glue,bus}.md`, `docs/DARIA_CORE.md` ("The front end", "The memory system…", "Step 5 work"), `frontend_study/{README.md,daria_fe3.sv}`, `core/bupchip/{daria_mem,daria_call,bupchip_pocket}.sv`, and upstream RTL re-read where a spec was unclear (`mapper_dpcplus.sv:99-160`, `mapper_cdf.sv:77-160`, `arm_mapper_audio.sv` whole, `top.sv:236-330, 1395-1435`, `bup_capture.sv:140-170`, `tb_daria.sv:95-215`). Spec citations use the keys of `critic.md`: DPC, CDF, AUD, GL, BU, BEN, DI, CR (critic). `rtl/` = `src/fpga/mister/rtl/`, `core/` = `src/fpga/core/`.

Nothing was run and no repository file was changed.

---

## 0. Summary

### 0.1 The choices

1. **Six small blocks, one arbiter.** `fe_seq` (phase tracking), `fe_core` (6507 side), `fe_audio` (audio), `fe_call` (call port), `fe_copy` (F6, state-RAM clear, DPC+ copy/fill, `init_busy`, `arm_dma_busy`), `fe_guard` (phase detector and shared-edge guard), and `fe_arb` (every M10K port mux and the collision assertions). No datapath register is shared between blocks: the core has its own word register W and adder; the audio engine has its own counters and adders. Each block can be unit-tested against its upstream counterpart on its own.
2. **Timing keyed to events.** Phase-1 work is keyed to E0 through a one-hot `k` started by `pclk1`. Post-commit work is keyed to the commit edge C through a one-hot `c` started by `access`. Background engines run on every clock with per-edge arbitration: there is no slot ring at all (D3). Data reach `fe_do` at E0+2 (ROM byte, random, AMPLITUDE), E0+3 (DFxFLAG) or E0+4 (every RAM-backed byte): 2 to 4 clocks before the E0+6 latch.
3. **Front-end ROM port B is a mirror of the bench ROM.** It is addressed on every clock with the current `a_in`'s image word, exactly as tb_daria's `cart_q <= rom[cart_addr]` is (tb_daria.sv:127-129). Its byte is therefore upstream's `rom_do` in every clock, the stale byte in (E0, E0+1) included. Port A serves the CDF jump lookahead (one fixed clock per 6507 cycle), F6, the copy engine and digital ROM samples.
4. **AMPLITUDE and NOTE are exact in mode A (D1 option taken).** `fe_audio` is `arm_mapper_audio`'s state machine clock for clock. Its RAM grant is upstream's rule, `!sel_ram_sel`, evaluated on `sel_up`, a live replica of upstream's 6507-side RAM select built from the same decode the core uses and the mirrored ROM byte. The core uses cart RAM port B only on edges where `sel_up` holds the port anyway; every other front-end access (the DSWRITE/DSPTR pointer read, pointer write-backs, copy/fill) yields to the audio. So every audio read is granted on upstream's edge and reads upstream's data. Cost and risk are argued in 5.1 and 10.
5. **Counters, frequencies and the call payload live in flip-flops.** Ticks add on the tick edge itself. The payload (seeds and frequencies) is captured on L = C+1, upstream's accept edge, so `seed_race` is 0 by construction. The merge applies all six words on one edge. A six-word ring holds payload, return staging and the RMW second call's payload, and it shifts the call block in and out of the state RAM with a single data source.
6. **Pointer write-backs go through a one-entry buffer** written at C+1 or C+2, on whichever edge the audio does not take. Upstream's writeback lands between C+1 and C+2 (E0+7.8, CDF §14.3), so cart RAM holds the same word as upstream's at every audio grant edge.
7. **Call side (D5).** Post F0-F7 through state RAM port B, flip `call_tog` when ready and not in reset, see `ret_tog` through two flops, read F8-FD in six consecutive clocks, merge (CDF only) atomically, then release. `arm_call_busy` and `arm_dma_busy` fall only on `rel_ok = (ph2 | pclk0) & ~pclk1`, the edges E0+6…E0+11 of whatever cycle is current (D3; 2.2 explains the `~pclk1`).
8. **Guard (D4).** A `clk_arm` toggle flop sampled by one `clk_sys` flop on a 6 ns / 1 ns constrained path, a three-phase flywheel, lock after 12 consistent edges. While locked and DARIA's CPU may store, the audio is granted only on phase-B edges, and `daria_fe` writes no cart RAM. Inert when unlocked (mode A, ÷19).
9. **F6 (D6).** Its own word-wide sequencer at one word per clock, with exclusive ports. Start at `load_end`+64 (the capture's `c_close`, counted the same way) or 8 clocks after a rising `cart_reset`; never on a falling one. `init_busy` from `load_start` to F6's end.
10. **`d_in` is the CPU's `write_DB`**, not `cart_din`. Every use of `d_in` is a write cycle, where the two are equal, and this keeps the SDRAM-sourced `read_DB` out of `daria_fe`'s input cone.

### 0.2 What is exact and what is counted (mode A)

| Item | Level |
|---|---|
| `fe_do & oe` at every non-hidden latch | exact, except `short_phase1` (a phase 1 under 6 clocks) |
| scheme registers after every cycle; cart RAM after init, writes, at call starts, per frame | exact (`tbl_alias` for a CDFJ+ DSWRITE into its own tables) |
| copy/fill results; call payloads | exact |
| tick edges; counters and frequencies per tick | exact, except `merge_race` (a tick within 7 clocks of a CDF merge) |
| NOTE frequency write edge | exact |
| AMPLITUDE edge and value | exact, except `merge_race`, `dig_rom_lag` (digital ROM samples on an upstream DDR miss or above 32 KB), `svc_audio_race` (an audio read of a byte a DPC+ copy/fill is writing), `pause_lane` |

### 0.3 Size

About **1,200 ALMs** (range 1,100-1,320), about 1,220 FF, **no new M10K** (10). That is 100-220 above `DARIA_CORE.md`'s 850-1,100 line, most of it the flip-flop audio state that buys exactness. Levers are listed in 10.3.

### 0.4 Conventions

- **E0** is the `clk_sys` edge at which `pclk1` is sampled high; **E0+n** the n-th edge after it. **C** is the edge at which `access` is sampled high (the commit edge, E0+6 nominally).
- **`X@n`** means: port X's address is presented during (E0+n−1, E0+n), the M10K registers it at edge E0+n, and its q is valid during (E0+n, E0+n+1). `X@C+1` is the same relative to C. Ports: **B** front-end ROM port B, **A** front-end ROM port A, **R** cart RAM port B, **S** state RAM port B.
- **"loaded @n"** for a register: its enable is sampled high at edge E0+n, so it holds the new value from (E0+n, E0+n+1).
- `k[j]` is high during (E0+j, E0+j+1) for j < 7; `k[7]` from E0+7 on. `c[j]` is high during (C+j, C+j+1) for j < 3; `c[3]` from C+3 on.
- All logic is on `clk_sys` except `fe_guard`'s one toggle flop.

---

## 1. Modules, hierarchy, ports

### 1.1 Hierarchy

```
daria_fe                      (top: ports, scheme decode, resets)
├─ fe_seq                     k, ph2, c, rel_ok, ph1_open, commit, late
├─ fe_core                    decode (fe_dec_dpc, fe_dec_cdf: combinational), op latch,
│                             W + adder, fe_do, scheme state flip-flops, write descriptors,
│                             write buffer, sel_up, port requests
├─ fe_audio                   tick, counters, frequencies, payload ring, snapshot,
│                             the replica state machine, AMPLITUDE, sample client
├─ fe_call                    post / flip / wait / read returns / apply / release
├─ fe_copy                    load tracking, F6, state-RAM clear, init_busy,
│                             DPC+ service engine, arm_dma_busy
├─ fe_guard                   fe_phase_det (clk_arm toggle + clk_sys sampler), guard_on
└─ fe_arb                     owners and muxes of ports A, B, R, S; crb_use; assertions
```

### 1.2 `daria_fe` ports

All on `clk_sys` unless noted. "Reg" means driven straight from a flip-flop.

| Port | Dir | Width | Clock | Meaning |
|---|---|---|---|---|
| `clk_sys` | in | 1 | — | 14.318 MHz |
| `clk_arm` | in | 1 | — | Feeds only `fe_phase_det`'s toggle flop. Pocket: DARIA's ÷18. Mode A: the bench's upstream `clk_arm` (5×) or `clk_sys`; the detector then never locks |
| `a_in` | in | 13 | sys | `{AB[12] & bios_en_b, AB[11:0]}` (top.sv:1128) |
| `d_in` | in | 8 | sys | **`write_DB`** (the CPU's DOR, top.sv:210). Sampled only on write cycles |
| `rw` | in | 1 | sys | `RW` |
| `pclk1`, `pclk0` | in | 1 each | sys | The paired phase enables (`phi1_ce`, `phi2_ce`, top.sv:1420-1435) |
| `access` | in | 1 | sys | `mapper_phi2 && arm_driver_run` (cart2600.sv:247) |
| `cart_reset` | in | 1 | sys | `effective_reset` (top.sv:255) |
| `pause` | in | 1 | sys | `pause_core` |
| `scheme` | in | 6 | sys | `force_bs` with the override (atari7800_pocket.sv:1047). 21 = DPC+, 23 = CDF |
| `revision` | in | 3 | sys | `mapper_revision`; bits [1:0] used, bit 0 is DPC+'s `stable_fractional` |
| `cdf_ldx`, `cdf_ldy`, `fetch_off_en` | in | 1 each | sys | detect2600 |
| `fetch_off` | in | 8 | sys | detect2600 |
| `cdfj_entry`, `cdfj_stack` | in | 32 each | sys | detect2600 |
| `audio_size_addr` | in | 16 | sys | detect2600 |
| `rom_size` | in | 32 | sys | `cart_size` (top.sv:1148), the image size |
| `ram32` | in | 1 | sys | `daria_ram32` (= `mapper_ram_size == 32768`) |
| `load_start`, `load_end` | in | 1 each | sys | one-clock pulses, as the core's `mapper_load_*` |
| `cpu_ready` | in | 1 | sys | Pocket: `daria_ready`. Mode A: the bench's `arm_online_sync2 && shadow_ready_sync2 && !effective_reset` |
| `ret_tog` | in | 1 | arm | `daria_ret_tog`; two `clk_sys` flops inside |
| `call_tog` | out | 1 | sys, reg | `daria_call_tog` |
| `hk_en` | in | 1 | static | bench merge hook enable; tied 0 in synthesis |
| `hk_stb` | in | 1 | sys | bench: upstream's `call_done` (high in (X, X+1)) |
| `hk_ret` | in | 192 | sys | bench: `{f2,f1,f0,c2,c1,c0}` = upstream's `audio_*_return` |
| `smp_req` | out | 1 | sys, reg | digital-sample request toggle |
| `smp_addr` | out | 19 | sys, reg | image byte offset, held from the toggle until the answer |
| `smp_ack` | in | 1 | wrapper's | answer toggle; two `clk_sys` flops inside |
| `smp_data` | in | 8 | wrapper's | the byte, held from before the ack flip until the next request |
| `fe_do` | out | 8 | sys, reg | to `direct_do[BANKDPCP]` and `direct_do[BANKCDF]` |
| `fe_oe` | out | 1 | sys | `a_in[12]`; `out_en = {8{fe_oe}}`, `flags_out = 1` |
| `arm_call_busy`, `arm_dma_busy` | out | 1 each | sys, reg | the stall terms (top.sv:306-307) |
| `init_busy` | out | 1 | sys, reg | straight into atari7800_pocket's reset OR (R2) |
| `fea_addr` | out | 13 | sys | front-end ROM port A word address (ignored by `daria_mem` while `cap_we`) |
| `fea_q` | in | 32 | sys | |
| `feb_addr` | out | 13 | sys | front-end ROM port B (the mirror) |
| `feb_q` | in | 32 | sys | |
| `crb_addr`, `crb_we`, `crb_be`, `crb_wd` | out | 13, 1, 4, 32 | sys | cart RAM port B |
| `crb_q` | in | 32 | sys | |
| `stb_addr`, `stb_we`, `stb_be`, `stb_wd` | out | 8, 1, 4, 32 | sys | state RAM port B (`stb_be` exists: daria_mem.sv:159, bupchip_pocket.sv:177) |
| `stb_q` | in | 32 | sys | |

The memory address, enable and data outputs are combinational (M10K q or register → logic → the M10K's own input registers), as D10 allows.

### 1.3 What the wiring around it changes (not `daria_fe`'s files)

- `top.sv` `POCKET_DARIA` group: carry `write_DB` (as `d_in`), `pclk0`, `pause` and `cart_reset` = `effective_reset` out; take `arm_call_busy`, `arm_dma_busy` in.
- `cart2600.sv` `NO_ARM_MAPPER` block: `direct_do = fe_do`, `flags_out = 16'h1`, `out_en = {8{fe_oe}}`, `rom_addr = 0`, `ram_sel = 0` for both schemes; `is_bad_game` keeps ELF and BUS only; `mapper_init_busy` stays 0 (R2).
- `atari7800_pocket.sv`: `init_busy` into the reset OR at :169-171.
- `bupchip_pocket.sv`: the sample port (`smp_*`) to a `clk_arm` requester beside the asset cache (5.5); `daria_ready` to `cpu_ready`.
- `core_constraints.sdc`: the guard's two lines (8.2).

### 1.4 Bench taps (for `fe_taps.svh`, BEN 7.3)

Hierarchical, read-only. Names are part of this design; the RTL keeps them.

| Group | Tap | Meaning |
|---|---|---|
| bus | `u_fe.u_seq.k`, `.ph2`, `.c` | phase tracking |
| core | `u_fe.u_core.op`, `.opv` | the op latched at E0+2 |
| core | `.bank`, `.mode`, `.ff_en`, `.fpend`, `.fexp`, `.jr`, `.jexp`, `.jstream` | DPC+/CDF state (`bank` and `fpend` serve both schemes) |
| core | `.rnd`, `.pp`, `.wave[0:2]` | DPC+ random, parameter pointer (saturates at 4: compare `min(parameter_pointer, 4)`), waveforms |
| core | `.call_pend_tap` | = `u_fe.u_call.pend2` (upstream's `call_pending` after its accept edge) |
| core | `.svc_pending`, `.svc_fill`, `.svc_src`, `.svc_dst`, `.svc_cnt`, `.svc_val` | the latched service |
| core | `.note_stb`, `.note_voice`, `.note_val` | NOTE strobe, (C, C+1) |
| core | `.sel_up` | the replica of upstream's `sel_ram_sel` |
| core | `.wb_v`, `.wb_a`, `.W` | write buffer |
| state RAM | `fe_mem.state_ram` words 0x00-0x10 | fetchers (w0 mask `FFFF0FFF`, w1 mask `FF0FFFFF`) and params 0-3 |
| audio | `u_fe.u_audio.tick` | tick strobe (= `accum >= 14,298,182`) |
| audio | `.counter[0:2]`, `.freq[0:2]`, `.amplitude` | per-tick state |
| audio | `.ring[0:5]`, `.take` | payload / staging |
| audio | `.state`, `.voice`, `.aud_take`, `.aud_addr`, `.rc[0:2]`, `.dig_addr` | lockstep with `mapper_audio.{state, voice, ram_grant, ram_addr, refresh_counter, digital_address}` |
| audio | `.note_cap`, `.mrg_apply`, `.cap` | NOTE-capture, merge and payload-capture strobes (for 7.6 offsets) |
| copy | `u_fe.u_copy.busy`, `.mode`, `.src`, `.dst`, `.cnt`, `.f6_active` | engine state |
| call | `u_fe.u_call.st`, `.cnum`, `.call_busy`, `.ret_seen` | call FSM and call number |
| ports | `u_fe.u_arb.crb_use` | high in the clock whose `crb_q` is consumed (core, P32, audio) |
| ports | `u_fe.u_arb.owner_r`, `.owner_s`, `.owner_a` | one-hot owner per clock |
| guard | `u_fe.u_guard.locked`, `.shared_last`, `.phb_next`, `.guard_on` | detector and guard |
| events | `u_fe.ev_short_phase1`, `.ev_tbl_alias`, `.ev_rmw_call`, `.ev_rmw_svc`, `.ev_guard_sup` | one-clock pulses for the bench's counters |
| asserts | `u_fe.u_arb.a_collide`, `.a_aux_late`, `.a_wb_late`, `.a_guard_core`, `u_fe.u_audio.a_size_hi` | must stay 0 |

---

## 2. Timing

### 2.1 `fe_seq`

```systemverilog
// power-up: k = 8'h80, ph2 = 0, c = 4'h8
always_ff @(posedge clk_sys) begin
    if (pclk1)       k   <= 8'h01;              // k[0] high in (E0, E0+1)
    else if (!k[7])  k   <= {k[6:0], 1'b0};     // saturates at k[7]
    if (pclk1)       ph2 <= 1'b0;               // D3's in_phase2: set at pclk0, cleared at pclk1
    else if (pclk0)  ph2 <= 1'b1;
    if (access)      c   <= 4'h1;               // c[0] high in (C, C+1)
    else if (!c[3])  c   <= {c[2:0], 1'b0};
end
assign commit   = access && a_in[12];           // pre-edge: this edge is a commit
assign ph1_open = !ph2 && !pclk0;               // this edge is still before the latch edge
assign rel_ok   = (ph2 || pclk0) && !pclk1;     // a busy may fall here: E0+6 ... E0+11
assign late     = k[5] | k[6] | k[7];           // at a commit edge: C >= E0+6
```

- **Why `~pclk1` in `rel_ok`.** `ph2` is still 1 before the edge that samples `pclk1`. A busy falling there (j = 0 of the next cycle) leaves RDY low at that cycle's E0 but the stall low at its E0+6, so the held address is committed twice (DI 1.2, GL 7.5). `(ph2 | pclk0) & ~pclk1` allows exactly E0+6…E0+11, for any phase length, and during a pause in phase 2 (CR 16).
- **Irregular phases.** `k` restarts on every `pclk1` and saturates, so a stretched phase 1 (MARIA→TIA handoff, a pause, CR 15) simply waits in `k[7]` with every read done. `c` restarts on every commit, whenever it comes. Phase 2 is 6 or 10 clocks with `access` possible (BU B2; CR 10, 11), so post-commit work (done by C+2) always ends before the next E0. A phase 1 of 2 clocks (RSYNC, BU B2) is handled in 2.7.

### 2.2 The live decode and the op latch

The decode is combinational on every clock from `a_in`, `rw`, `romb` and the state flip-flops. `romb` is the mirrored ROM byte: `feb_q` lane `lane_q`, where `lane_q <= rom_a[1:0]` on every edge.

```systemverilog
// ROM address, both schemes (17-bit image byte address; all values < $8000)
rom_a   = (is_dpc ? 17'h0C00 : (jplus ? 17'h0800 : 17'h1000)) + {bank, 12'h000} + a_in[11:0];
feb_addr = rom_a[14:2];                          // every clock: the mirror
// ---- DPC+ (mapper_dpcplus.sv:112-158) ----
d_dir  = a_in[11:0] < 12'h028;
d_reg  = rw & a_in[12] & (d_dir | (ff_en & fpend & romb < 8'h28));
d_rn   = d_dir ? a_in[5:0] : romb[5:0];   d_fn = d_rn[5:3];   d_ix = d_rn[2:0];
d_hot  = a_in[12] & !d_reg & a_in[11:0] >= 12'hFF6 & a_in[11:0] <= 12'hFFB;
d_wreg = !rw & a_in[12] & a_in[11:0] >= 12'h028 & a_in[11:0] <= 12'h07F;
d_g    = (a_in[11:0] - 12'h028) >> 3;           // 0..10, a multiple-of-8 base
d_sel  = (d_reg & d_fn >= 1 & d_fn <= 3)
       | (!rw & a_in[12] & (a_in[11:3] == 9'h00C | a_in[11:3] == 9'h00F));   // PUSH, WRITE
// ---- CDF (mapper_cdf.sv:77-157), with r = revision[1:0] ----
jplus = r == 3;  jrev = r >= 2;  fast_mode = mode[3:0] == 0;
amp_s = jrev ? 35 : 34;
arms  = romb == 8'hA9 | (jplus & cdf_ldx & romb == 8'hA2) | (jplus & cdf_ldy & romb == 8'hA0);
in_rng = fetch_off_en ? (romb >= fetch_off & {1'b0,romb} <= {1'b0,fetch_off} + amp_s) : romb <= amp_s;
norm   = fetch_off_en ? romb - fetch_off : romb;
amp_op = fetch_off_en ? (amp_s + fetch_off[5:0]) : amp_s;           // 6-bit
jvalid = (jr == 2 & (jrev ? romb[7:1] == 0 : romb == 0)) | (jr == 1 & romb == 0);
c_jump = rw & a_in[12] & jr != 0 & a_in == jexp & jvalid;
c_fet  = rw & a_in[12] & fast_mode & fpend & a_in == fexp & in_rng;
c_sub  = c_jump | c_fet;
c_amp  = c_fet & !c_jump & romb[5:0] == amp_op;
c_idx  = c_jump ? jstream + ((jrev & jr == 2) ? romb[0] : 0) : norm[5:0];
c_hot  = a_in[12] & !c_sub & a_in[11:0] >= 12'hFF4 & a_in[11:0] <= 12'hFFB;
c_sel  = (c_sub & !c_amp) | (access & !rw & a_in == 13'h1FF0);
// ---- the replica of upstream's sel_ram_sel (cart2600.sv:191, 965) ----
sel_up = is_dpc ? d_sel : (is_cdf ? c_sel : 1'b0);
```

`sel_up` uses the **live** state (after a commit `fpend` is clear, so a fast-fetch select drops at C as upstream's does) and the live `romb` (stale in (E0, E0+1), as tb_daria's `cart_q` is). It feeds only the audio grant (3.4, 5.4).

**Op classes** (one-hot), formed from the decode and latched with their fields:

| Class | DPC+ condition | CDF condition | Fields kept |
|---|---|---|---|
| `ROM` | `rw & a12 & !d_reg` | `rw & a12 & !c_sub` | `romb`, `hot`, `jok` |
| `RRND` | `d_reg & d_fn == 0 & d_ix != 5` (and fn 5-7, unreachable) | — | `ix` |
| `AMP` | `d_reg & d_fn == 0 & d_ix == 5` | `c_amp` | — |
| `RDAT` | `d_reg & d_fn in 1..3` | — | `ix`, `fn` |
| `RFLG` | `d_reg & d_fn == 4` | — | `ix` |
| `CFET` | — | `c_fet & !c_jump & !c_amp` | `idx` |
| `CJMP` | — | `c_jump` | `idx`, `romb[0]` |
| `DFLD` | `d_wreg & d_g in {0,1,2,3,4,5,8}` | — | `g`, `ix` |
| `DPW` | `d_wreg & d_g in {7,10}` (PUSH / WRITE) | — | `ix`, `push` |
| `DPAR` | `d_wreg & d_g == 6 & ix == 1` | — | — |
| `DCF` | `d_wreg & d_g == 6 & ix == 2` | — | — |
| `DMISC` | `d_wreg & ((d_g == 6 & ix in {0,5,6,7}) | d_g == 9)` | — | `g`, `ix` |
| `CDSW`, `CDSP`, `CMODE`, `CCALL` | — | `!rw & a_in == $1FF0/1/2/3` | — |
| `NONE` | otherwise | otherwise | — |

`hot` (`d_hot` / `c_hot`) is an attribute of any class with `a_in[12]`, read or write.

```systemverilog
always_ff @(posedge clk_sys) if (k[1]) op <= dec;    // the op, latched @2 (E0+2)
wire [..] opc = k[1] ? dec : op;                     // the op at a commit edge (dec only if C = E0+2)
```

The ROM byte, `a_in`, `rw` and the state do not change between (E0+1, E0+2) and C, so the op latched @2 is the op upstream commits at C. `jok`, the fast-jump lookahead, is formed in `k[1]` (2.5).

### 2.3 `fe_core` registers (pseudo-RTL)

The schedule tables (2.4, 2.5) say when each enable fires. Every register below has one enable and a data mux of at most four terms (one-hot AND-OR).

```systemverilog
// ---- W, the core's only word register, and its adder ----
wire w_crb = (k[2] & (op.CFET | op.CJMP)) | p32_q;            // pointer word, or P32 the edge after its read
wire w_stb = k[2] & (op.RDAT | op.DPW | op.DCF);               // fetcher word, or params
wire w_sum = (k[3] & (op.RDAT | op.DPW)) | (k[4] & (op.CFET | op.CJMP))
           | (commit & opc.CDSW & late);
wire w_shf = commit & opc.CDSP & late;
always_ff if (w_crb | w_stb | w_sum | w_shf)
    W <= ({32{w_crb}} & crb_q) | ({32{w_stb}} & stb_q) | ({32{w_sum}} & (W + Bv)) | ({32{w_shf}} & shf);
// Bv, one-hot AND-OR:
//   k[4] & CFET & !jplus : {4'h0, crb_q[15:0], 12'h000}      (pointer + inc<<12)
//   k[4] & CFET &  jplus : {8'h00, crb_q[15:0], 8'h00}        (pointer + inc<<8)
//   (k[4] & CJMP | commit & CDSW) & !jplus : 32'h0010_0000
//   (k[4] & CJMP | commit & CDSW) &  jplus : 32'h0001_0000
//   k[3] & (RDAT & fn != 3 | DPW & !push)  : 32'h1           (counter + 1)
//   k[3] & DPW & push                      : 32'h0000_0FFF   (counter - 1, 12-bit)
//   k[3] & RDAT & fn == 3                  : {24'h0, W[31:24]}   (fraction + increment)
shf = jplus ? {W[23:16], d_in, 16'h0000} : {W[23:20], d_in, 20'h00000};   // DSPTR
// carries past bit 11 (counter) or 19 (fraction) land in the spare nibble, which the
// lane writes leave alone or readers mask (DI 5.2)

// ---- the P32 read (DSWRITE, DSPTR): yields to the audio ----
wire p32_try1 = k[1] & (dec.CDSW | dec.CDSP);
wire p32_try2 = k[2] & (op.CDSW | op.CDSP) & !p32_got;
always_ff begin
    p32_q   <= (p32_try1 | p32_try2) & !aud_take;     // registered here: W takes crb_q next edge
    if (k[1]) p32_got <= p32_try1 & !aud_take;
end
// Audio grants are at least 2 edges apart (ISSUE, CAPTURE), so p32_try2 never meets one.

// ---- small registers ----
always_ff begin
    if (k[2] & (op.RDAT | op.CFET | op.CJMP)) cl <= data_addr[1:0];  // lane of the data byte
    if (k[2])                                 wf <= win(stb_q);      // DPC+ window flag, pre-commit
    if (k[3] & op.DPW) ba <= 13'h0C00 + (op.push ? (W + Bv)[11:0] : W[11:0]);  // PUSH/WRITE byte
    if (commit)        din <= d_in;
end
// win(q) = ((q[23:16] - q[7:0]) mod 256) > ((q[23:16] - q[31:24]) mod 256)   // top, counter, bottom

// ---- data addresses (combinational, in k[2]) ----
data_addr = is_dpc ? 15'h0C00 + (op.fn == 3 ? stb_q[19:8] : stb_q[11:0])
          : jplus  ? (15'h0800 + crb_q[30:16])              // wraps mod $8000 (R5)
          :           15'h0800 + crb_q[31:20];
dsw_addr  = jplus ? (15'h0800 + W[30:16]) : 15'h0800 + W[31:20];   // W = P32
```

Write descriptors and the write buffer, loaded at C:

```systemverilog
always_ff @(posedge clk_sys) begin
    // state RAM write at C+1
    if (commit) begin
        swv <= (late & (opc.RDAT | opc.DPW)) | opc.DFLD | (opc.DPAR & pp < 4);
        swa <= opc.DPAR ? 8'h10 : {4'h0, opc.ix, opc.word1};   // word1: FRACDATA, FRACLOW/HI/INC
        sbe <= opc.DPAR ? (4'b0001 << pp[1:0]) : opc.be;       // 2.4, field table
        swk <= {opc.DPAR, opc.RDAT | opc.DPW, opc.DFLD};       // which data term
    end else if (c[0]) swv <= 1'b0;
    // cart RAM byte at C+1 (PUSH/WRITE)
    cwv <= commit & late & opc.DPW;
    // pointer write buffer (CDF)
    if (rst_cdf) wb_v <= 1'b0;
    else if (commit & late & (opc.CFET | opc.CJMP | opc.CDSW | opc.CDSP)) begin
        wb_v <= 1'b1;
        wb_a <= ptr_base + ((opc.CDSW | opc.CDSP) ? 6'd32 : opc.idx);   // 9-bit word address
    end else if (own_wb) wb_v <= 1'b0;
end
// the buffer's data is W, which holds the new pointer from E0+5 (fetch, jump) or C (DSWRITE,
// DSPTR) until the next cycle's E0+3; own_wb comes at C+1 or C+2 (3.1)
```

`fe_do` (D10: a register):

```systemverilog
wire fd_k1  = k[1];                                                   // @2
wire fd_flg = k[2] & op.RFLG;                                         // @3
wire fd_ram = k[3] & (op.RDAT | op.CFET | op.CJMP);                   // @4
wire fd_amp = op.AMP & ph1_open & !k[0] & !k[1];                      // @3 ... C-1
wire use_amp = (fd_k1 & dec.AMP) | fd_amp;
always_ff if (fd_k1 | fd_flg | fd_ram | fd_amp)
    fe_do <= ({8{fd_k1 & !dec.AMP}} & (dec.RRND ? rnd_byte(dec.ix) : romb))
           | ({8{fd_flg}} & ((op.ix < 4 & win(stb_q)) ? 8'hFF : 8'h00))
           | ({8{fd_ram}} & (crb_byte(crb_q, cl) & {8{op.fn != 2 | wf}}))
           | ({8{use_amp}} & amp_nx);
// rnd_byte(i): 0 random_next[7:0], 1 random_prior[7:0], 2 rnd[15:8], 3 rnd[23:16],
//              4 rnd[31:24], 6/7 8'h00   (mapper_dpcplus.sv:160-180)
// amp_nx: the value fe_audio's amplitude register takes at this edge (5.4)
```

`fe_do` loads at C neither for AMPLITUDE (`ph1_open` is 0 at C) nor for anything else, so it holds the committed byte through phase 2 (DI 7.2).

### 2.4 DPC+ schedule

Every row: **B@1** (the mirror holds the cycle's ROM byte from (E0+1, E0+2)), op latched @2, `fe_do` default @2. "Final" is the edge from which `fe_do` holds the byte the 6507 latches at E0+6. "Upstream select" is the window in which upstream's `sel_ram_sel` is high, so its audio is not granted (DPC §12, BU 5.2).

| Access | Reads | `fe_do` final | At C | After C | Upstream select | Core R/S edges inside it |
|---|---|---|---|---|---|---|
| ROM read $1028-$1FFF (not consumed), incl. $A9 arming | — | @2 `romb` | `fpend <= ff_en & romb == $A9`; hotspot | — | none | — |
| Hotspot $1FF6-$1FFB, read or write, not a register read | — | @2 (old bank's byte) | `bank <= a[2:0] − 6` | B@C+1 shows the new bank's byte, as `cart_q` does | none | — |
| RANDOM0NEXT/PRIOR $1000/$1001 or fast-fetch $00/$01 | — | @2 low byte of next/prior | `rnd <= next`/`prior`, `fpend <= 0` | — | none | — |
| RANDOM1-3 $1002-$1004, $1006/$1007, fn 5-7 | — | @2 | `fpend <= 0` | — | none | — |
| AMPLITUDE $1005 or fast-fetch $05 | — | @2, reloaded every edge to C−1 with `amp_nx` | `fpend <= 0` | — | none | — |
| DFxFLAG $1020-$1027 or fast-fetch $20-$27 | S@2 w0[ix] | @3 (`$FF/$00`, 0 for ix ≥ 4) | `fpend <= 0` | — | none | S only |
| DFxDATA $1008-$100F or fast-fetch | S@2 w0[ix]; R@3 `$C00+cnt` | @4 | `fpend <= 0`; `swv` | S@C+1 w0, be 0011, `W` (= cnt+1, @4) | (E0, E12) direct; (E0+1, C) fast | R@3 ✓ |
| DFxDATAW $1010-$1017 | as DATA; `wf` @3 | @4 byte & flag | as DATA | as DATA | as DATA | R@3 ✓ |
| DFxFRACDATA $1018-$101F | S@2 w1[ix]; R@3 `$C00+frac[19:8]` | @4 | `fpend <= 0`; `swv` | S@C+1 w1, be 0111, `W` (= frac+inc, @4) | as DATA | R@3 ✓ |
| FRACLOW $1028-$102F | — | — | `swv` | S@C+1 w1, be `sf ? 0011 : 0010`, `{x, x, din, $00}` | none | — |
| FRACHI $1030-$1037 | — | — | `swv` | S@C+1 w1, be 0100, `{x, $0‖din[3:0], x, x}` | none | — |
| FRACINC $1038-$103F | — | — | `swv` | S@C+1 w1, be 1001, `{din, x, x, $00}` | none | — |
| TOP $1040-$1047 | — | — | `swv` | S@C+1 w0, be 0100, `{x, din, x, x}` | none | — |
| BOTTOM $1048-$104F | — | — | `swv` | S@C+1 w0, be 1000, `{din, x, x, x}` | none | — |
| LOW $1050-$1057 | — | — | `swv` | S@C+1 w0, be 0001, `{x, x, x, din}` | none | — |
| HI $1068-$106F | — | — | `swv` | S@C+1 w0, be 0010, `{x, x, $0‖din[3:0], x}` | none | — |
| FASTFETCH $1058 | — | — | `ff_en <= (d_in == 0)` | — | none | — |
| PARAMETER $1059 | — | — | `if (pp < 4) pp++`; `swv` | S@C+1 word $10, be `1<<pp`, `{4{din}}` | none | — |
| CALLFUNCTION $105A | S@2 params; S@3 w0[p2&7]; counts staged @4 | — | 0: `pp <= 0`. 1/2, `!svc_pending`: latch the service, `svc_pending`, `pp <= 0`, `arm_dma_busy`. FE/FF: call (6) | copy engine from C+1 (7); call CAP at C+1 | none | S only |
| WAVEFORM0-2 $105D-$105F | — | — | `wave[a[1:0]−1] <= d_in[6:0]` | — | none | — |
| PUSH $1060-$1067 | S@2 w0[ix]; `W`, `ba` @4 (cnt−1) | — | `swv`, `cwv` | R@C+1 byte at `ba`, `{4{din}}`; S@C+1 w0, be 0011 | (E0, E12) | R@C+1 ✓ |
| WRITE $1078-$107F | S@2 w0[ix]; `ba` = cnt, `W` = cnt+1 @4 | — | `swv`, `cwv` | as PUSH | (E0, E12) | R@C+1 ✓ |
| RRESET / RWRITE0-3 $1070-$1074 | — | — | `rnd` constant / byte | — | none | — |
| NOTE0-2 $1075-$1077 | — | — | `note_stb <= 1` (one clock), voice `a[1:0]−1`, value `d_in` | `fe_audio` latches at C+1 | none | — |
| Fast-fetch operand (any register) | as the register's row, with the register number from `romb` (B@1 → decoded in k[1]) | same | same | same | (E0+1, C) | same edges |
| Copy / fill (CALLFUNCTION 1/2) | 7 | | | | | |

Notes.
- Field bytes need no read: the fetcher words keep each field on its own byte lane (DI 5.2). `x` = lane not written.
- Every R edge of the core lies where upstream's select is high, so upstream's audio could not have been granted there (3.4).
- PUSH/WRITE: upstream strobes the same byte at E2…E6 (DPC §9.2). Nothing reads that word in between (the select blocks the audio; the 6507 is in a write), so writing once at C+1 leaves RAM equal at every observation.

### 2.5 CDF family schedule

Every row: **B@1**, and for the jump lookahead **A@1** = the next image word (`rom_a[14:2]+1`, presented in k[0]). In k[1]: `jok = romb == $4C & lb1[7:1] == 0 & lb2 == 0 & rom_a < $7FFE`, with `lb1`, `lb2` the bytes at `rom_a+1`, `rom_a+2` from `{fea_q, feb_q}`. The image is linear, so a `$4C` at a bank's end looks into the next bank's first bytes, and `rom_a < $7FFE` reproduces the map's two always-zero entries (CDF Q18, DI 2.2).

| Access | Reads | `fe_do` final | At C | After C | Upstream select | Core R edges inside it |
|---|---|---|---|---|---|---|
| ROM read, incl. $A9 (and $A2/$A0 on CDFJ+ with `ldx`/`ldy`) arming and $4C jump arming | B@1, A@1 | @2 | `fpend`, `fexp`; jump rules (below); hotspot | — | (E0, E0+1) only if the stale byte satisfies a predicate (CDF Q8) | — |
| Hotspot $1FF4-$1FFB, read or write, not substituted | — | @2 | `bank` (CDF table: non-plus FF4→6, FF5-FFA→0-5, FFB→6; plus FF4→0, FF5-FFA→1-6, FFB→0) | B@C+1 new bank | none | — |
| Fast fetch, stream s = `romb` (− `fetch_off`) | R@2 ptr[s]; R@3 data `$800+P[31:20]` (CDFJ+ `($800+P[30:16]) & $7FFF`); R@4 inc[s]; W = P @3, P + inc<<12 (<<8) @5 | @4 | `fpend <= 0`; `wb_v` | R@C+1 or @C+2: ptr[s] ← W | (E0+1, C) | R@2, @3, @4 ✓ |
| Amplitude fetch (operand = `amp_op`) | — | @2, reloaded every edge to C−1 with `amp_nx` | `fpend <= 0`; no pointer | — | none (MC:142) | — |
| LDX # / LDY # operand (CDFJ+) | as fast fetch: only the arming byte differs | | | | | |
| Jump operand 1 (stream 33, or 33+`romb[0]` on CDFJ/J+) and operand 2 (`jstream`) | R@2 ptr; R@3 data; W = P @3, P + 1<<20 (1<<16) @5 | @4 | `fpend <= 0`; `jr−1`, `jexp+1`, `jstream` (operand 1, `jrev`); `wb_v` | R@C+1/C+2 ptr ← W | (E0+1, C), and (E0, E0+1) on operand 2 when operand 1 was $00 (stale byte) | ✓ |
| Jump operand at $x000 after a bank-end $4C (A12 = 0) | — | not a cart cycle | nothing (`jr` stays) | — | — | — |
| DSWRITE $1FF0 | R@2 (or R@3 if the audio takes @2) ptr[32]; W = P the edge after | — | R@C byte at `dsw_addr`, be `1<<lane`, `{4{d_in}}`, write enable = `access`; W ← P + 1<<20 (1<<16); `wb_v` | R@C+1/C+2 ptr[32] ← W | (C−1, C) only (`access`-gated, MC:150) | R@C ✓; the P32 read yields |
| DSPTR $1FF1 | as DSWRITE | — | W ← `shf`; `wb_v` | R@C+1/C+2 ptr[32] ← W | none | P32 read and buffer yield |
| SETMODE $1FF2 | — | — | `mode <= d_in` | — | none | — |
| CALLFN $1FF3 | — | — | FE/FF: call (6) | CAP at C+1 | none | — |
| Other $1Fxx, A12 = 0 accesses | — | @2 | nothing (A12 = 0: no commit) | — | — | — |

CDF commit rules (MC:182-249, CDF §11.1), all on the op latched @2 and pre-edge state:

```systemverilog
if (rst_cdf) begin bank <= jplus ? 0 : 6; mode <= 8'hFF; fpend <= 0; fexp <= 0;
                   jr <= 0; jexp <= 0; jstream <= 33; end
else if (commit) begin
    if (opc.hot) bank <= cdf_hot_bank(a_in[2:0], jplus);
    if (rw & (opc.CFET | opc.CJMP | opc.AMP)) begin           // substituted read
        fpend <= 0;
        if (opc.CJMP) begin
            if (jrev & jr == 2) jstream <= 33 + opc.romb0;
            jr <= jr - 1;  jexp <= jexp + 1;
        end
    end else if (rw) begin                                     // not substituted
        fpend <= fast_mode & opc.arms;
        if (fast_mode & opc.arms) fexp <= a_in + 1;
        if (jr != 0 & a_in == jexp)                    jr <= 0;
        else if (fast_mode & opc.romb == 8'h4C & opc.jok) begin jr <= 2; jexp <= a_in + 1; jstream <= 33; end
        else if (jr != 0)                              jr <= 0;
    end
    if (opc.CMODE) mode <= d_in;
end
```

DPC+ commit rules (DPC:193-325):

```systemverilog
if (rst_dpc) begin bank <= 5; rnd <= 32'h2B435044; ff_en <= 0; fpend <= 0; pp <= 0;
                   wave <= '0; svc_pending <= 0; end
else if (commit) begin
    if (opc.hot) bank <= a_in[2:0] - 3'd6;
    if (rw & (opc.RRND | opc.AMP | opc.RDAT | opc.RFLG)) begin
        fpend <= 0;
        if (opc.RRND & opc.ix == 0) rnd <= random_next(rnd);
        if (opc.RRND & opc.ix == 1) rnd <= random_prior(rnd);
    end else if (rw) fpend <= ff_en & opc.romb == 8'hA9;
    // writes: FASTFETCH, PARAMETER (pp saturates at 4), CALLFUNCTION, WAVEFORM, RRESET,
    // RWRITE0-3 (per byte lane: const / next / prior / d_in, 4 terms), NOTE strobe
end
```

`rst_dpc = cart_reset | !is_dpc`, `rst_cdf = cart_reset | !is_cdf` (upstream resets each front end on `reset || mapper != own`, cart2600.sv:805, 843). `bank` and `fpend` are shared; either reset clears them (bank to the scheme's value: 5, 6 or 0, `revision` read live as MC:166 does).

### 2.6 Why every access fits

One M10K stage per clock: an address registered at edge n gives q in (n, n+1); logic between q and the next address fits one 69.8 ns clock (10.4). The longest chains:

| Chain | Edges |
|---|---|
| CDF fetch | `a_in` valid after E0 → B@1 → `romb`, decode, `ptr_base+idx` → R@2 → `crb_q`, `$800+P` → R@3 → `crb_q` byte → `fe_do` @4 → latched at E0+6 (2 spare). Increment: R@4 → `W+inc` @5 → buffer → R@C+1/C+2 |
| DPC+ fast-fetch DATA | B@1 → `romb` = register number → S@2 → `stb_q`, `$C00+cnt` → R@3 → `fe_do` @4 (2 spare). `W` @3, @4; S@C+1 |
| DSWRITE | P32 R@2/@3 → W @3/@4 → `dsw_addr` → R@C (needs W by C−1: C ≥ E0+5) |
| CALLFUNCTION 1/2 | S@2 params → S@3 w0[p2] → counts @4 (2 clocks before C) |
| AMPLITUDE | `amp_nx` at every edge up to C−1: equal to upstream's register in (C−1, C) |

### 2.7 Irregular phases

| Case | What happens |
|---|---|
| Phase 1 stretched (handoff, pause in phase 1) | `k` saturates; reads are done by E0+4; `fe_do` holds (AMPLITUDE keeps reloading); `sel_up` stays as upstream's (the predicate holds until the commit); the commit at C, whenever it comes, starts `c` |
| Phase 1 of 2 or 4 clocks | The commit at E0+2 or E0+4 uses `opc` (`dec` at E0+2). Flip-flop state follows exactly (it depends only on the ROM byte and `a_in`). **`late` = 0**: RAM and state-RAM write-backs are skipped. `fe_do` is right only for ROM, random and AMPLITUDE at E0+4, and wrong at E0+2. Counted as **`short_phase1`** (`ev_short_phase1` = a commit with `!late` on a cartridge cycle), CR 26 |
| Phase 2 of 10 | post-commit work ends at C+2 anyway |
| Hidden phase 2 (stall) | `pclk0` sets `ph2` (so `rel_ok` works), `access` is 0: no commit, no `c` restart, no write. The held repeat is decoded again next cycle |
| Pause in phase 2 | `rel_ok` true: a release may happen during the pause (CR 16) |
| Commit with `a_in[12]` = 0 | `commit` is 0: nothing |

---

## 3. Port arbitration

One owner per clock per port, by fixed priority. The owner's address (and write) is presented during the clock and registers on the edge that ends it.

### 3.1 Cart RAM port B (R)

| Priority | Owner | When | Read or write |
|---|---|---|---|
| 0 | F6 | `f6_active` (console in reset; audio in reset) | word writes, 1 per clock |
| 1 | core, fixed | `k[1]` & `dec.(CFET\|CJMP)`: ptr; `k[2]` & `op.(CFET\|CJMP\|RDAT)`: data; `k[3]` & `op.CFET`: inc; `access` & `op.CDSW` & `late`: DSWRITE byte; `c[0]` & `cwv`: PUSH/WRITE byte | as listed |
| 2 | audio | `aud_take = aud_issue & !sel_up & !init_busy & (!guard_on \| phb_next)` | read |
| 3 | core, yielding | `p32_try1/2 & !aud_take` (P32 read); else `wb_v & !aud_take & !guard_on` (pointer write) | read / write |
| 4 | copy engine | service in progress, none of the above, `!guard_on` | byte or word writes |
| — | idle | address 0, no write | — |

`crb_use <= core_rd | p32_rd | aud_take` (registered: high in the clock whose q is consumed).

### 3.2 State RAM port B (S)

| Priority | Owner | When |
|---|---|---|
| 0 | F6 clear | words $00-$1F zeroed at F6's start |
| 1 | core, fixed | `k[1]` & `dec.(RDAT\|RFLG\|DPW\|DCF)`: read (fetcher or params); `k[2]` & `op.DCF`: read w0[p2]; `c[0]` & `swv`: write |
| 2 | call port | post writes F0-F7, return reads F8-FD |

The audio engine does not use the state RAM. The core uses it only in DPC+, and only on fixed edges, so the call port waits at most one clock for each. For CDF the call port's timing is exact (6.3).

### 3.3 Front-end ROM ports

| Port | Priority | Owner |
|---|---|---|
| B | — | the mirror, every clock (`feb_addr = rom_a[14:2]`) |
| A | (inside `daria_mem`) | the capture, in clocks with `cap_we` (download only; console in reset) |
| A | 0 | F6 source (exclusive) |
| A | 1 | core lookahead in `k[0]`, CDF only |
| A | 2 | audio digital ROM sample (CDF only; waits one clock if it meets `k[0]`) |
| A | 3 | copy engine source (DPC+ only, so never with 1 or 2) |

### 3.4 Why the audio and the core never meet

Every core priority-1 access on R is made in a clock where `sel_up` = 1:

- CDF ptr/data/inc reads in k[1]-k[3]: the same predicate (`c_sub & !c_amp`) on the same byte and state is `sel_up`.
- DPC+ data read in k[2]: `d_reg & d_fn in 1..3` is `sel_up`.
- DSWRITE byte at C: `sel_up` contains `access & !rw & a_in == $1FF0`.
- PUSH/WRITE byte in c[0]: the write cycle's address decode keeps `sel_up` high until the next E0 (≥ C+6).

`aud_take` requires `!sel_up`, so the two cannot coincide. `fe_arb` asserts it anyway (`a_collide = core_fixed & aud_issue & !sel_up`). Everything else that uses R (P32 read, the buffer, the copy engine) yields to `aud_take`. So the audio is granted on exactly upstream's edges. What the audio reads is also upstream's word: 6507-side bytes land on upstream's edge (DSWRITE at C) or where no audio read can see the difference (PUSH/WRITE), pointer words land between C+1 and C+2 as upstream's writeback does (C+1 if the audio does not read then, else C+2), and ARM writes come from the bench mirror on upstream's own `clk_arm` edges (BEN 7.4.3).

### 3.5 The guard's phase-B rule, concretely

Let S be a shared edge (a `clk_arm` edge falls on it). Phase B is S+1: 17.46 ns after the last `clk_arm` edge, 8.73 ns before the next (D4). The detector reports, in the clock (S, S+1), `shared_last = 1`, so `phb_next = locked & shared_last`: an address presented in this clock registers on S+1.

```
clk_sys edge     S-1    S      S+1    S+2    S+3=S'  S'+1   S'+2
shared_last       0     1*     0      0      1*      0      0     (* = during the clock after it)
phb_next          0     1      0      0      1       0      0     (presented in that clock, registers next edge)
audio ISSUE enters at S+1 → may register only on S'+1 → grant S'+1, CAPTURE (S'+1, S'+2)
```

While `guard_on`:
- the audio's ISSUE states wait for `phb_next` as well as `!sel_up` (adds 0-2 clocks per read);
- the write buffer and the copy engine do not write R;
- core priority-1 R requests are suppressed (`ev_guard_sup`); they occur only for a held address in the DPC+ register window (the held repeats are hidden and their data unused, D4) and `a_guard_core` must stay 0 for a consumed access.
- F6 is not affected: it runs only while `rst_quiet` (8).

---

## 4. State placement

### 4.1 Flip-flops

| Block | State | Bits |
|---|---|---|
| core, both | `bank` 3, `fpend` 1, `op` ~26, `W` 32, `wf` 1, `cl` 2, `ba` 13, `din` 8, `p32_q/got` 2, `swv/swa/sbe/swk` 16, `cwv` 1, `wb_v/wb_a` 10, `fe_do` 8, `lane_q` 2 | ~125 |
| core, DPC+ | `rnd` 32, `ff_en` 1, `pp` 3, `wave` 21, `note_*` 11, `svc_*` 48, service stage 21 | ~137 |
| core, CDF | `mode` 8, `fexp` 13, `jr` 2, `jexp` 13, `jstream` 6 | 42 |
| seq | `k` 8, `ph2` 1, `c` 4 | 13 |
| audio | `counter` 96, `freq` 96, `ring` 192, `take` 3, `rc` 96, `accum` 24, `dig_addr` 32, `dig_ram` 15, `woff` 15, `wshift` 5, `ssum` 8, `amplitude` 8, `state` 12, `voice` 2, `note` 11, `al` 2, sample client ~35, misc 8 | ~756 |
| call | FSM 9, `widx`/`ridx` 6, `call_busy`, `pend2`, `call_tog`, `ret_s1/s2`, `ret_seen`, `cnum` 8 | ~30 |
| copy | `src` 17, `dst` 15, `cnt` 16, `val` 8, mode 7, F6 step 3, `ldc` 7, `loading`, `fe_loaded`, `f6_fam` 2, `f6_r32`, `rdl` 3, `rst_q`, `init_busy`, `dma_busy`, `qa` 13 | ~95 |
| guard | `g_tog` (arm), `st`, `st1`, `pos` 3, `good` 4, `locked` | 11 |

### 4.2 State RAM (256 × 32, port B)

| Word | Contents | Written | Read |
|---|---|---|---|
| $00-$0F | DPC+ fetcher i: w0 = word 2i = `{bottom, top, 4'bx‖counter[11:8], counter[7:0]}`; w1 = word 2i+1 = `{increment, 4'bx‖fraction[19:16], fraction[15:0]}` | core S@C+1; F6 clear | core S@2/S@3 |
| $10 | DPC+ params 0-3, one per lane | core S@C+1 (PARAMETER); F6 clear | core S@2 (CALLFUNCTION) |
| $11-$1F | unused (cleared by F6) | | |
| $20-$EF | unused | | |
| $F0-$F7 | call block (entry\|T, stack, seeds 0-2, frequencies 0-2) | call port, before `call_tog` | `daria_call` port A |
| $F8-$FD | returns (counters 0-2, frequencies 0-2) | `daria_call` port A | call port, after `ret_tog` |
| $FE-$FF | unused | | |

The spare nibbles (`x`) take adder carries; every reader masks them, and HI/FRACHI write them as 0 (DI 5.2).

### 4.3 In place in cart RAM

CDF pointers and increments (CDF0 words $1B8/$1DA, CDF1 $028/$04A, CDFJ/J+ $026/$049; stream 32 at base+32), display data, the CDF driver area, DPC+ display data $0C00-$1BFF and frequency table $1C00-$1FFF, the waveform pointers and size words. Nothing is copied, snooped or written back (DC "The front end").

---

## 5. Audio engine (`fe_audio`)

### 5.1 Why a replica, and what it costs

The audio engine is upstream's `arm_mapper_audio` re-expressed under D10, clock for clock, with the grant computed from `sel_up`. This is the simplest thing to verify: the bench can compare its state with `dut.cart2600.mapper_audio` on **every clock** (`state`, `voice`, `ram_grant`, `ram_addr`, `amplitude`, counters, frequencies), and any divergence points at its first clock. It removes the shared word register, the job chooser, the tick backlog, the seed and merge ordering rules and the `amp_lag`, `note_race`, `seed_race` and `amp_input_race` classes of DI §7.1.

What it needs beyond any separate audio datapath, with the critic's list (CR 27):
- a separate audio datapath: this architecture has one by construction;
- a cart-RAM write buffer: the pointer buffer of 2.3 (no read forwarding is needed, because the buffer's edge matches upstream's writeback, 3.4);
- the previous ROM byte: the mirror port B gives it in every clock;
- AMPLITUDE forwarded into `fe_do`: `amp_nx`, 8 bits;
- flip-flop counters, frequencies, payload ring and snapshot: about +250 ALMs over DI's state-RAM counters (10).

Risk: `sel_up` must equal upstream's select on every clock. It is the same decode the core must get right anyway, and the per-clock lockstep check finds an error at its first clock.

### 5.2 Tick

```systemverilog
localparam [23:0] TH = 24'd14_298_182;            // CLK_RATE - AUDIO_RATE, NTSC and PAL alike
wire tick = accum >= TH;
always_ff if (cart_reset) accum <= 24'd0;
          else            accum <= accum + (tick ? 24'h25D3BA : 24'd20_000);
```

Reset by `cart_reset`, the same signal as upstream's audio reset, so the first tick is at R+716 (R = the last edge with `cart_reset` high) and ticks fall on upstream's edges (AUD 3.3).

### 5.3 Counters, frequencies, payload ring, snapshot

```systemverilog
// family: 1 DPC+, 3 CDF, 0 otherwise (cart2600.sv:658-660); fam3 = family == 3
// merge strobes from fe_call (CDF only): apply (own path) or hk_apply = hk_en & hk_stb
wire       mrg  = (cp_apply & fam3) | (hk_apply & fam3);
wire [2:0] tk   = hk_apply ? {hk_c2 != ring[2], hk_c1 != ring[1], hk_c0 != ring[0]} : take;
// counter v: one adder with folded input muxes (arith ALMs)
always_ff
    if (cart_reset)          counter[v] <= 0;
    else if (mrg & tk[v])    counter[v] <= hk_apply ? hk_c[v] : ring[v];   // merge wins over a tick
    else if (tick)           counter[v] <= counter[v] + freq[v];
always_ff
    if (cart_reset)          freq[v] <= 0;
    else if (mrg)            freq[v] <= hk_apply ? hk_f[v] : ring[3+v];
    else if (note_cap & nvoice == v) freq[v] <= crb_q;                    // NOTE_CAPTURE
// payload / staging ring r[0..5] = {seed0, seed1, seed2, fpay0, fpay1, fpay2}
always_ff
    if (cart_reset)          ring <= '0;
    else if (cp_cap)         ring <= {freq[2], freq[1], freq[0], counter[2], counter[1], counter[0]};
    else if (cp_rot)         ring <= {ring[0], ring[5:1]};                // post: r[0] goes out
    else if (cp_shin)        ring <= {stb_q, ring[5:1]};                  // return word in
always_ff if (cart_reset) take <= 0; else if (cp_shin & cp_j < 3) take <= {stb_q != ring[0], take[2:1]};
// refresh snapshot
always_ff if (cart_reset) rc <= '0; else if (dispatch) rc <= counter;
```

- `cp_cap` is L = C+1 for a call, so `ring` holds upstream's FIQ r8-r13 payload exactly: counters with every tick up to E0+6 and none at E0+7 (the pre-edge value at C+1) and frequencies at L (D1, AUD 10.1). For an RMW second call `cp_cap` comes at the merge edge together with `cp_apply`, so the ring takes the **pre-merge** values while the counters take the merged ones (AUD 2, CR 18).
- `cp_rot` rotates six times while F2-F7 are posted, so the ring is back in place afterwards.
- `cp_shin` shifts in F8-FD as they arrive; while the first three arrive, `ring[0]` is the matching seed, so `take[v] = (return_v != seed_v)` (AUD 10.4). After six shifts `ring` = the six returns in place.
- `mrg` applies all six on one edge. A tick on that edge adds to a counter that is not replaced (old frequency), and is lost on a replaced one, as AUD:191-223 do.
- DPC+ (family 1) never merges; its ring is captured and posted only.
- Hook mode (`hk_en`, bench): the merge applies at upstream's own M from `hk_ret`, compared with the in-place seeds.

### 5.4 The replica state machine

States one-hot, as AUD:59-72: IDLE, NOTE_ISSUE, NOTE_CAPTURE, POINTER_ISSUE, POINTER_CAPTURE, SIZE_ISSUE, SIZE_CAPTURE, SAMPLE_ISSUE, SAMPLE_CAPTURE, DIGITAL_ROUTE, ROM_ISSUE, ROM_WAIT. Substitutions against AUD:
- `ram_grant` → `aud_take` (3.1);
- `ram_word_data` → `crb_q`;
- `ram_byte_data` → `pause ? 8'hFF : crb_q[8*al +: 8]`, `al <= aud_addr[1:0]` on `aud_take` (top.sv:936; the lane freeze across a pause is counted, 5.8);
- `call_launch`/`call_done` → `cp_cap` and `mrg` (5.3);
- `rom_ready`, `rom_done`, `rom_data` → the sample client (5.5);
- `waveform_pointer` dropped (never read), `sample_sum` 8 bits (only [7:0] is used), the shifter 15 bits wide (only `sample_offset_sum[14:0]` is used).

```systemverilog
// address (AUD:129-154), 17-bit byte address
aud_issue = st.NOTE_ISSUE | st.POINTER_ISSUE | st.SIZE_ISSUE | st.SAMPLE_ISSUE;
idx15     = rc[voice] >> wshift;                       // 15 bits kept
aud_addr  = st.NOTE_ISSUE    ? 17'h1C00 + {note_value, 2'b00}
          : st.POINTER_ISSUE ? wave_base + {voice, 2'b00}       // CDF0 $7F0, CDF1/J/J+ $1B0
          : st.SIZE_ISSUE    ? {1'b0, audio_size_addr} + {voice, 2'b00}
          : dig_smp          ? {2'b0, dig_ram}
          : family == 1      ? 17'h0C00 + {wave[voice], 5'b0} + rc[voice][31:27]
          : jplus_s          ? (17'h0800 + (woff + idx15)) & (ram_size - 1)
          :                    17'h0800 + (woff + idx15)[11:0];
crb_addr (when aud_take) = aud_addr[14:2];             // a_size_hi asserts aud_addr[16:15] == 0
dispatch  = st.IDLE & !(note_pending & family == 1) & refresh_pending;

always_ff if (cart_reset) begin st <= IDLE; refresh_pending <= 0; note_pending <= 0; voice <= 0;
                                wshift <= 27; ssum <= 0; dig_smp <= 0; amplitude <= 0; ... end
else begin
    if (tick) refresh_pending <= family != 0;
    if (note_stb) begin note_pending <= 1; nvoice <= note_voice; note_value <= note_val; end
    case (1'b1)
    st.IDLE:            if (note_pending & family == 1) st <= NOTE_ISSUE;
                        else if (refresh_pending) begin
                            refresh_pending <= tick;            // a tick at D stays queued
                            voice <= 0; ssum <= 0; dig_smp <= 0; wshift <= 27;   // rc <= counter (5.3)
                            st <= family == 1 ? SAMPLE_ISSUE : POINTER_ISSUE;
                        end
    st.NOTE_ISSUE:      if (aud_take) st <= NOTE_CAPTURE;
    st.NOTE_CAPTURE:    begin /* note_cap: freq[nvoice] <= crb_q */ if (!note_stb) note_pending <= 0; st <= IDLE; end
    st.POINTER_ISSUE:   if (aud_take) st <= POINTER_CAPTURE;
    st.POINTER_CAPTURE: if (digital) begin
                            dig_addr <= crb_q + (rc[0] >> (jplus_s ? 13 : 21));
                            dig_low  <= jplus_s ? rc[0][12] : rc[0][20];
                            st <= DIGITAL_ROUTE;
                        end else begin
                            woff <= woff_of(crb_q);             // AUD:274-292, 6.3
                            if (audio_size_addr == 0) begin wshift <= 27; st <= SAMPLE_ISSUE; end
                            else st <= SIZE_ISSUE;
                        end
    st.SIZE_ISSUE:      if (aud_take) st <= SIZE_CAPTURE;
    st.SIZE_CAPTURE:    begin wshift <= crb_q[11:7]; st <= SAMPLE_ISSUE; end
    st.SAMPLE_ISSUE:    if (aud_take) st <= SAMPLE_CAPTURE;
    st.SAMPLE_CAPTURE:  if (dig_smp) begin amplitude <= nib(byte, dig_low); st <= IDLE; end
                        else if (voice == 2) begin amplitude <= ssum + byte; st <= IDLE; end
                        else begin ssum <= ssum + byte; voice <= voice + 1; wshift <= 27;
                                   st <= family == 1 ? SAMPLE_ISSUE : POINTER_ISSUE; end
    st.DIGITAL_ROUTE:   if (dig_addr < rom_size) st <= ROM_ISSUE;
                        else if (dig_addr >= 32'h4000_0000 & dig_addr - 32'h4000_0000 < ram_size) begin
                            dig_ram <= dig_addr[14:0]; dig_smp <= 1; st <= SAMPLE_ISSUE; end
                        else begin amplitude <= 0; st <= IDLE; end
    st.ROM_ISSUE:       if (rom_ready) st <= ROM_WAIT;
    st.ROM_WAIT:        if (rom_done) begin amplitude <= nib(rom_data, dig_low); st <= IDLE; end
    endcase
end
// digital = (family == 3 & mode[7:4] == 0); jplus_s = family == 3 & revision[1:0] == 3
// woff_of(w): CDFJ+: (w in [$4000_0800, $4000_0000 + ram_size)) ? w[14:0] - $800 : 0;
//             CDF0/1/J: {3'b0, w[11:0] - $800}  (no window test)
// nib(b, low) = low ? {4'h0, b[3:0]} : {4'h0, b[7:4]}
// amp_nx = amp_we ? amp_wd : amplitude   (the D input above, exported to fe_core)
```

The waveform registers, `mode` (digital) and `family` are read live, as upstream's are (AUD 5.8).

### 5.5 Digital ROM samples and the sample port

`rom_ready = !smp_busy`. At the edge R where ROM_ISSUE is left (`rom_ready`): `smp_busy <= 1`, and:
- **below 32 KB** (`dig_addr[31:15] == 0`): port A reads `dig_addr[14:2]` at R+1 (or R+2 if R+1 is a `k[0]` edge); the byte is registered by R+3; `rom_done` is a pulse in (R+3, R+4), so AMPLITUDE changes at **R+4**, upstream's timing on a sample-cache hit (AUD 8.3).
- **32 KB and above** (`dig_addr < rom_size`, at most 512 KB): `smp_addr <= dig_addr[18:0]`, `smp_req <= ~smp_req` at R. Two flops on `smp_ack`; when the synchronised ack equals `smp_req`, take `smp_data` (held by the wrapper since before its flip), pulse `rom_done`; AMPLITUDE changes one edge later.
- `smp_busy` clears with `rom_done`. A console reset does not clear it, so an orphaned request blocks the next one until its answer comes, as upstream's `sample_busy` does (AUD 7.3 item 5; G7).

**Port protocol (wrapper side, `clk_arm`).** Synchronise `smp_req` through two flops; when it differs from the last value seen, read the byte at image offset `smp_addr` through the asset path (the cache over PSRAM, a requester between CPU reads, DC 3.2), drive `smp_data`, then flip `smp_ack`. `smp_addr` and `smp_data` are held buses under the ±20 ns clock exceptions (DC 7.3). The bench (mode A) answers with `img[smp_addr]` after `+fe_slat` `clk_sys` and flips the ack.

### 5.6 Seeds, merges and NOTEs against ticks

- **Seeds:** captured on L = C+1 from counters that already hold every tick ≤ E0+6. No ordering rule is needed.
- **Merges:** atomic on `mrg`. A tick before it uses the old frequency; one on it is kept for an unchanged counter and lost for a replaced one; later ticks use the returned frequency (AUD 10.4).
- **NOTE:** the strobe is latched at C+1, NOTE_ISSUE wins IDLE, the frequency is written at NOTE_CAPTURE: E0+10 at the earliest, later behind a running refresh or a select, as upstream. `note_race` = 0.

### 5.7 AMPLITUDE: when it changes, and the classes

A = upstream's A on every refresh: T+7 (DPC+), T+13 or T+19 (CDF), T+4/T+6 (digital out of range / RAM), plus one clock per clock of `sel_up` met in an ISSUE state. The 6507 reads `amp_nx` (2.3), so an AMPLITUDE read returns upstream's value at every latch. Counted classes (all must be explained by their condition; anything else is `dout_bad` or `audio_bad`):

| Class | Condition | Effect |
|---|---|---|
| `merge_race` | a CDF call whose window (M_up, M_fe] = (X+1, X+8] (6.3) contains a tick or a refresh dispatch | counters, frequencies (resync, BEN 7.6 rule) and that refresh's AMPLITUDE |
| `dig_rom_lag` | a digital ROM sample where upstream's `sample_done` came later than R+3 (a DDR miss) or the address is ≥ 32 KB | AMPLITUDE edge, and the replica's state offset until both machines are IDLE with nothing pending |
| `svc_audio_race` | an audio read whose word lies in [`svc_dst`, `svc_dst`+`svc_cnt`) while either side's DPC+ copy/fill is running | that refresh's value |
| `pause_lane` | a capture whose grant edge had `pause` high and capture clock low (upstream's frozen lane, AUD 5.3) | one sample byte |

With `+fe_merge_hook=1`, `merge_race` must be 0.

### 5.8 Pause (D9)

The audio engine has no enable: ticks, refreshes and NOTEs run on. Sample bytes read `$FF` while `pause` (above). The 6507 freezes with its bus standing; `sel_up` is evaluated on that frozen bus, so a frozen selecting cycle blocks every grant for the whole pause, as upstream (AUD 12.5). Counted: `pause_lane`; DARIA's CPU running through a pause (DI 7.3); everything else follows upstream.

---

## 6. Call side (`fe_call`)

### 6.1 State machine

States one-hot: IDLE, CAP, POST, FLIP, RUN, RD, RDW, APPLY, REL.

```systemverilog
wire callfn = commit & opc.callfn & (d_in == 8'hFE | d_in == 8'hFF);
                 // opc.callfn: CDF CCALL, or DPC+ DCF; upstream ignores FE/FF while call_pending
always_ff @(posedge clk_sys) begin
    ret_s1 <= ret_tog;  ret_s2 <= ret_s1;                    // SYNCHRONIZER_IDENTIFICATION FORCED
    if (cart_reset) begin
        call_busy <= 0; pend2 <= 0; st <= IDLE; ret_seen <= ret_s2;    // DI 3.4, daria_call.sv:29-32
    end else begin
        if (callfn & !call_busy)        begin call_busy <= 1; st <= CAP; cnum <= cnum + 1; end
        else if (callfn & !pend2)       begin pend2 <= 1; /* ev_rmw_call */ end
        case (1'b1)
        st.CAP:   begin st <= POST; widx <= 0; end                       // cp_cap in this clock
        st.POST:  if (own_s_cp) begin widx <= widx + 1; if (widx == 7) st <= FLIP; end
        st.FLIP:  if (cpu_ready & !cart_reset) begin call_tog <= ~call_tog; st <= RUN; end
        st.RUN:   if (hk_en ? hk_done & (ret_s2 != ret_seen) : ret_s2 != ret_seen) begin
                      ret_seen <= ret_s2;
                      if (hk_en) st <= APPLY_HK; else begin st <= RD; ridx <= 0; end
                  end
        st.RD:    if (own_s_cp) begin ridx <= ridx + 1; if (ridx == 5) st <= RDW; end
        st.RDW:   if (cp_j == 6) st <= APPLY;                            // last word shifted in
        st.APPLY: if (pend2) begin pend2 <= 0; st <= POST; widx <= 0; end   // cp_apply (+ cp_cap)
                  else st <= REL;
        st.REL:   if (rel_ok) begin call_busy <= 0; st <= IDLE; end
        endcase
    end
end
// strobes to fe_audio:
//   cp_cap   = st.CAP | (st.APPLY & pend2)
//   cp_rot   = st.POST & own_s_cp & widx >= 2                 (F2..F7 are ring[0])
//   cp_shin  = rd_q (a return read registered at the last edge); cp_j counts 0..5
//   cp_apply = st.APPLY
// state RAM requests: POST: write word $F0+widx, data = widx==0 ? F0 : widx==1 ? F1 : ring[0];
//                     RD:   read $F8+ridx.   own_s_cp = granted (3.2)
// hook mode: hk_done is set by hk_apply (the merge already applied at upstream's M);
//            APPLY_HK does the pend2 swap only (cp_cap), then REL / POST.
```

`F0` = DPC+ `$0000_0C09`; CDF/CDFJ `$0000_0809`; CDFJ+ `{cdfj_entry[31:1], 1'b1}`. `F1` = `cdfj_stack` on CDFJ+, else `$4000_1FFC` (DPC:184-186, MC:159-162).

### 6.2 Commit to post to flip

| Edge | What |
|---|---|
| C | CALLFN commit: `call_busy <= 1` (GL 7.5: any rise in [E0+6, E0+17] is identical for the 6507) |
| C+1 = L | `cp_cap`: ring ← counters and frequencies (upstream's accept edge) |
| C+2…C+9 | F0…F7 written (S), one per clock; in DPC+ a core S edge delays one word by one clock |
| ≥ C+10 | `call_tog` flips when `cpu_ready & !cart_reset` (D5; a flip during `rst` would be absorbed, DI 3.4). The block is complete before the flip; `daria_call` reads F0 at A3 |

`cpu_ready` low with the 6507 held is DARIA's rule (R12).

### 6.3 Return, merge, release

| Edge | What |
|---|---|
| A_c | `ret_tog` flips (`clk_arm`); every return word already written |
| S1, S2 | `ret_s1`, `ret_s2` |
| R = S3 | `ret_s2 != ret_seen`: `ret_seen` ← it; RD |
| R+1…R+6 | S reads of F8…FD (CDF: the core never uses S, so exactly these edges) |
| R+2…R+7 | `cp_shin`: each word shifts into the ring; the first three set `take` |
| **R+8 = M_fe** | `cp_apply`: CDF merge (5.3); `pend2`: second call's payload captured |
| ≥ R+8 | `call_busy <= 0` on the first `rel_ok` edge (D3), then IDLE |

Upstream: X = S3 (busy falls), merge at M = X+1 = S4 (GL 7.3). So M_fe = M + 7: the `merge_race` window is 7 clocks (about 1% of CDF calls meet a tick, CR 29). For DPC+ the reads happen and nothing is applied.

### 6.4 RMW CALLFN (CR 18)

A CALLFN commit while `call_busy` sets `pend2` (once). At the first call's APPLY, `cp_apply` and `cp_cap` fire together: the ring takes the pre-merge counters and frequencies (the second call's seeds and payload) while the counters take the merge. The FSM goes back to POST, posts, flips and waits; `call_busy` stays high between the calls. Upstream's one-clock dip of the stall is not reproduced: class **`rmw_call`** (hardware and mode B; in mode A the stall is upstream's). Payload values match (in mode A with the hook exactly; without it, a tick in (M, M_fe] is `rmw_call` too).

### 6.5 Reset

On `cart_reset`: `call_busy <= 0`, `pend2 <= 0`, FSM to IDLE, `ret_seen <= ret_s2` on every reset clock, `call_tog` kept. The CPU is reset by `daria_mreset` (the same `effective_reset`), and `daria_call` re-syncs its seen flag. A return from an abandoned call is ignored.

### 6.6 Mode-A hooks

- `cpu_ready` from the bench (no `call_busy` term, CR 8).
- Returns matched by `cnum` (BEN R1): the bench releases upstream's return words and flips `ret_tog` only after `daria_fe` has flipped `call_tog` for that call number.
- `hk_en`: the merge from upstream's `call_done` and returns at M (CR 6). With the hook, `merge_race` must be 0.

---

## 7. F6, the state-RAM clear, copy/fill, `init_busy`, `arm_dma_busy` (`fe_copy`)

### 7.1 Load tracking and start

```systemverilog
always_ff @(posedge clk_sys) begin
    // loads
    if (load_start)               begin loading <= 1; fe_loaded <= 0; ldc <= 0; end
    else if (load_end & loading)  begin loading <= 0; ldc <= 7'd64; end          // = bup_capture's DRAIN
    else if (ldc != 0)            ldc <= ldc - 1;
    ld1 <= load_end & loading;
    if (ld1) begin f6_fam <= is_dpc ? DPC : (is_cdf ? CDF : NONE); f6_r32 <= ram32;
                   fe_loaded <= is_dpc | is_cdf; end                 // scheme is valid from load_end+1
    // console reset re-run (arm_mapper_ram_init.sv:204-227), CR 17
    rst_q <= cart_reset;
    rst_rise = cart_reset & !rst_q & fe_loaded & !loading & !load_start & !load_end & !f6_active;
    if (rst_rise) rdl <= 3'd7; else if (rdl != 0) rdl <= rdl - 1;
    // init_busy (D6): from load_start or the reset edge through F6's end
    if (load_start | rst_rise)              init_busy <= 1;
    else if (f6_done)                       init_busy <= 0;
    else if (ld1 & !(is_dpc | is_cdf))      init_busy <= 0;   // not an ARM image
end
wire f6_go = ((ldc == 7'd1) & fe_loaded) | (rdl == 3'd1);    // load_end+64, or rising reset+8
```

- `ldc == 1` is the clock in which `bup_capture`'s `c_drain == 1` (bup_capture.sv:150-162): the window takes its last byte at `load_end`+63, so F6's first port-A read registers at +65 or later.
- A rising `cart_reset` re-runs F6 8 clocks later, while `cart_reset` stays high (the `init_busy` OR holds it). A falling reset never starts F6. `load_start` aborts F6 and any service.
- `init_busy` never dips between `load_start` and F6's end.

### 7.2 F6 sequence (exclusive ports, one word per clock)

| Step | DPC+ (family latched at load) | CDF / CDFJ / CDFJ+ |
|---|---|---|
| CLR | S: words $00-$1F ← 0 (32 clocks): fetchers and params reset (DPC:194-219) | same (harmless) |
| 1 | FILL R words $000-$2FF ← 0 (RAM $0000-$0BFF) | COPY A words $000-$1FF → R words $000-$1FF (image $0000-$07FF) |
| 2 | COPY A words $1B00-$1FFF → R words $300-$7FF (image $6C00-$7FFF → RAM $0C00-$1FFF) | FILL R words $200 to (`f6_r32` ? $1FFF : $7FF) ← 0 |
| done | `f6_done` pulse | same |

COPY is a one-stage pipeline: the A address of word i is presented in clock t, its q is written to R in clock t+1. Durations: DPC+ 32 + 768 + 1,280 + 2 ≈ 2,082 clocks; CDF 8 K 32 + 512 + 1,536 + 2 ≈ 2,082; CDFJ+ 32 + 512 + 7,680 + 2 ≈ 8,226 (upstream at `lat` = 20: 5,261 / 3,481 / 9,625, GL 4.2; the hold absorbs the difference, BEN 7.4.2). The audio engine and the 6507 are in reset meanwhile. `rst_quiet` (the guard's exemption) is `cart_reset` held for ≥ 8 clocks.

### 7.3 DPC+ copy/fill service (D7)

At the CALLFUNCTION cycle (2.4): S@2 reads the params word into W; S@3 reads w0 of fetcher `p2 & 7`; @4 stages, with p0..p3 = W bytes 0..3 and `cnt` = `stb_q[11:0]`:

```
dest_avail = $1000 - cnt                       (13 bits, 1..$1000)
fill_count = dest_avail < p3 ? dest_avail[7:0] : p3
off        = {p1, p0}
src_avail  = $7400 - off                       (17 bits)
copy_count = off >= $7400 ? 0 : (src_avail < fill_count ? src_avail[7:0] : fill_count)
stage_cnt  <= (d_in == 2) ? fill_count : copy_count;   stage_dst <= $0C00 + cnt
```

At C, if `d_in` is 1 or 2 and `!svc_pending` (pre-edge): `svc_fill <= (d_in == 2)`, `svc_src <= $0C00 + off` (17 bits), `svc_dst <= stage_dst`, `svc_cnt <= stage_cnt`, `svc_val <= p0`, `svc_pending <= 1`, `pp <= 0`. The copy source thus stops at image $8000 and the destination at RAM $1C00 (DPC:85-101).

Engine (accepts when idle and `!init_busy`, clearing `svc_pending`; R priority 4; never writes while `guard_on`):

```systemverilog
// FILL: one word per granted clock, byte enables from dst[1:0] and the bytes left
be   = fill_mask(dst[1:0], cnt);   adv = popcount(be);
write R word dst[14:2], be, {4{val}};  dst <= dst + adv;  cnt <= cnt - adv;
// COPY (byte-wise): A addressed with src[14:2] every clock; qa <= src[14:2];
// when qa == src[14:2] (q is this word) and R is granted:
write R word dst[14:2], be = 1 << dst[1:0], {4{fea_q byte src[1:0]}};  src++; dst++; cnt--;
// one byte per clock inside a ROM word, one bubble when the source crosses a word
```

`arm_dma_busy`:

```systemverilog
if (cart_reset)                                         dma_busy <= 0;   // the engine aborts too
else if (commit & opc.DCF & taken12 & !init_busy)       dma_busy <= 1;   // at C
else if (dma_busy & !svc_pending & engine_idle & rel_ok) dma_busy <= 0;
```

It covers a second, RMW-queued service with no dip (counted `rmw_svc`). A count of 0 ends at C+2. A 255-byte fill takes about 66 clocks (upstream about 70), a 255-byte copy about 320 (upstream about 234 at `lat` = 20); both are counted (CR 30) and absorbed in mode A by the forced stall (BEN 7.4.2). On a console reset the service is abandoned (upstream's DMA finishes, GL 4.3): invisible, since the 6507 is in reset and F6 rewrites the region.

---

## 8. The phase detector and the guard (`fe_guard`)

### 8.1 RTL

```systemverilog
module fe_phase_det (input wire clk_arm, clk_sys, output wire locked, shared_last, phb_next);
    logic g_tog = 1'b0;                                     // clk_arm: toggles on every edge
    always_ff @(posedge clk_arm) g_tog <= ~g_tog;
    (* altera_attribute = "-name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION OFF" *)
    logic st = 1'b0;                                        // the one constrained receiver
    logic st1 = 1'b0;
    always_ff @(posedge clk_sys) begin st <= g_tog; st1 <= st; end
    assign shared_last = (st == st1);                       // even toggle count: the last edge was shared
    // flywheel: pos[0] = "this clock's shared_last should be 1"
    logic [2:0] pos = 3'b001;  logic [3:0] good = 4'd0;  logic lk = 1'b0;
    always_ff @(posedge clk_sys)
        if (shared_last != pos[0]) begin                    // mismatch: unlock, re-phase
            good <= 4'd0;  lk <= 1'b0;
            pos  <= shared_last ? 3'b010 : {pos[1:0], pos[2]};
        end else begin
            pos  <= {pos[1:0], pos[2]};
            if (good != 4'd12) good <= good + 1'b1; else lk <= 1'b1;
        end
    assign locked   = lk;
    assign phb_next = lk & shared_last;                     // the coming edge is phase B
endmodule
// guard_on = locked & (call_window | (!cpu_ready & !rst_quiet))
//   call_window = fe_call in RUN, RD, RDW, APPLY or REL (from the flip to the release)
//   rst_quiet   = cart_reset high for >= 8 clocks (the CPU is held: F6 may write)
```

At ÷48/÷18 the `clk_sys` edges see 3, 3, 2 toggles: `st` changes twice in three edges and holds on the shared one (DI 9.3). `!cpu_ready` covers the clocks after a reset release before DARIA parks; the 6507 cannot make a cart RAM access then (its reset sequence takes 84 clocks, DARIA parks after about 64, DI 3.4), which `a_guard_core` checks.

### 8.2 SDC (`core_constraints.sdc`)

```tcl
set_max_delay -from [get_registers {*|daria_fe:*|fe_phase_det:*|g_tog}] -to [get_registers {*|daria_fe:*|fe_phase_det:*|st}] 6.000
set_min_delay -from [get_registers {*|daria_fe:*|fe_phase_det:*|g_tog}] -to [get_registers {*|daria_fe:*|fe_phase_det:*|st}] 1.000
```

6 ns captures a toggle launched 8.73 ns before a `clk_sys` edge with margin; 1 ns keeps the toggle launched on the shared edge itself out of that edge. Both are tighter than, and more specific than, the clock-level ±20 ns exceptions (DC 7.3). Step 7 checks in the timing report that each line covers exactly one path and that no physical-synthesis retiming moved `st`.

### 8.3 Lock rule

Lock after 12 consecutive edges that match the three-edge pattern (four periods); unlock on the first mismatch. Mode A (`clk_arm` = 5 × `clk_sys`): 5 toggles per clock, `st` changes on every edge, `shared_last` is never 1, so it never locks. ÷19: the 2/3-toggle pattern has period 19 and never repeats every third edge for 12 edges, so it never locks. Unlocked, `guard_on` = 0 and nothing changes.

### 8.4 How the bench checks it

Mode B with `clk_d` aligned (`+d_ofs` ∈ {0, 8730, 17460}, BEN 6.3):
- `det_bad`: at every `clk_sys` edge after lock, `u_guard.shared_last` (during the following clock) must equal `(($time - d_ofs) % 26190) == 0` at that edge;
- lock within 24 `clk_sys` of the run's start, and never in mode A (`det_lock_a` must stay 0);
- `coll_d_same` = 0 and `d_shared_stores` counted as BEN 6.4, with `crb_use` as the read side;
- a reverse check: no `crb_we` by `daria_fe` on a shared edge while `guard_on`.

---

## 9. Upstream quirks and counted differences

### 9.1 DPC+ (DPC §14)

| # | Quirk | Here |
|---|---|---|
| 1 | commit only with `access && a_in[12]` | `commit` (2.1) |
| 2 | latch and commit share E6 | `fe_do` from phase-1 values; state at C |
| 3 | RANDOM0NEXT/PRIOR return the stepped low byte, step at E6; 1-3 unstepped | `rnd_byte`, `rnd` at C |
| 4 | $006/$007/$024-$027 read $00 | `rnd_byte` 6/7, flag ix ≥ 4 |
| 5 | DFxFLAG only $020-$023 | flag & `ix < 4` |
| 6 | window flag 8-bit modular, pre-increment counter | `win(stb_q)` at k[2] |
| 7 | 12/20/8-bit wraps | lane writes, spare nibbles |
| 8 | FRACLOW by `revision[0]`; FRACHI/HI `d[3:0]`; FRACINC clears [7:0]; LOW keeps 11:8 | field table (2.4) |
| 9 | PUSH at counter−1; WRITE at counter; $068-$077 no RAM | DPW rows |
| 10 | RAM strobe E2-E6 (E1-E6 on a repeated address), not lock-gated | one write at C+1; equal at every observation (2.4); `ram_wr_noaccess` asserted 0 (CR 31) |
| 11 | fast fetch arms on any committed $A9 ROM read; next committed cart read < $28 anywhere; writes and A12=0 don't touch it | `fpend` rules |
| 12 | 6-bit register space | `d_rn[5:0]` |
| 13 | hotspots on reads and writes, old bank's byte, not on a fast-fetch operand | `d_hot`; B@C+1 |
| 14 | `d_out` falls back after E6; transients before `rom_do` settles | drift counted (O1); the tb ROM's stale byte is in `sel_up` |
| 15-17 | FASTFETCH = (d==0); PARAMETER saturates; CALLFUNCTION priorities, ignores | 2.4 |
| 18-19 | clamps, `params[2] & 7`, count 0 requests; source/dest/value | 7.3 |
| 20 | pending at C, accept at C+1, stall from accept | busy at C (GL 7.5 window) |
| 21 | waveform 7 bits; NOTE strobe one clock; voice `a[1:0]−1` | 2.4 |
| 22 | reset values; reset on `mapper != DPCP` | `rst_dpc`; F6 clear |
| 23 | `ram_sel` windows starve the audio | `sel_up` |
| 24-25 | S1-S5; held repeats re-present the previous address | inputs are upstream's; the release-window duplicate (S2) is removed by `rel_ok` on hardware (`release_dup`, not visible in mode A) |
| 26 | `rom_data` live | mirror port B |

### 9.2 CDF (CDF §17)

| Q | Here |
|---|---|
| Q1 live predicates, Q2 tables idle at 32 | live decode; `sel_up` (index 32 has no RAM effect here: pointers are in place) |
| Q3 arming byte-based, survives A12=0 | commit rules |
| Q4-Q7 jump operand rules, `fast_mode` only at arming, jump step, amplitude | 2.5 |
| Q8 stale byte (E0, E0+1) | mirror port: reproduced for tb_daria's ROM; the SDRAM E2 old-word transient is out of scope (CR 9, 28) |
| Q9 no bank switch on substituted reads | `c_hot` needs `!c_sub` |
| Q10, Q24, Q27 no ROM refetch on a bank switch / repeated address; reads not A12-gated | SDRAM-only: out of scope; the mirror refetches as the bench ROM does |
| Q11 CDFJ+ wrap mod 32 KB; DSWRITE into the tables | `& $7FFF`; **`tbl_alias`** |
| Q12-Q14 | non-plus `P[31:20]`; `inc[15:0]`; offset ungated by version |
| Q15 writeback drop | no writeback |
| Q16 DSWRITE `access`-gated | R@C with `we = access` |
| Q17 pending while not ready, no stall | DARIA stalls at the commit (R12), unreachable |
| Q18 map edges | `rom_a < $7FFE` |
| Q19-Q22 | inputs as detect2600 gives them |
| Q23 pause | 5.8 |
| Q25 stall phase-2 accounting | top.sv's own logic; `rel_ok` |
| Q26 `pu_val` from the previous edge's word | only with a short phase 1: `short_phase1` |

### 9.3 Audio (AUD §16)

1-19 are reproduced by the replica (5.4): PAL tick rate (fixed constant), tick coalescing, a tick at D re-queues, NOTE beats refresh, NOTE overlap table (the replica's own `note_stb`/`note_pending` logic), live waveform and digital flags (including the voice-1/2 pointer with counter 0), mod-256 sum, pointer aliasing and windows, size shift `word[11:7]`, digital nibble, out-of-range 0, merge rule, `$FF` bytes on pause, reset by `effective_reset` only, idle address, no call gating, release window (top.sv), launch and merge on one edge (5.3), pause freeze. G8 applied (dead `waveform_pointer`, 8-bit sum).

### 9.4 Glue and bus

| Item | Here |
|---|---|
| init on `load_end_d` and rising reset; busy from `load_start`; family latched at load | 7.1 (start at +64 and +8: durations counted, absorbed by the hold) |
| upstream's init survives nothing; reset edge during init ignored | `!f6_active` in `rst_rise` |
| service/DMA run through pause | engine has no pause input |
| CPU reset on console reset (G6) | DARIA's |
| release window duplicate (GL 7.5, G1) | `rel_ok` on both busy signals (D3, CR 2) |
| 29,696-byte DPC+ image: F6 copies $7400-$7FFF past the file | FE ROM holds the previous image there: **`short_image`** (CR 25), upstream reads stale DDR |
| `open_bus` | `fe_do` holds the committed byte: `drift_fe`, `obus_exposed` must be 0 |

### 9.5 Counted differences (complete list)

| Class | Condition | Mode A? |
|---|---|---|
| `short_phase1` | a cartridge commit with C < E0+6 | yes |
| `merge_race` | 5.7 | yes (0 with the hook) |
| `dig_rom_lag` | 5.7 | yes |
| `svc_audio_race` | 5.7 | yes |
| `pause_lane` (and pause in general, D9) | 5.7, 5.8 | bench has no pause |
| `tbl_alias` | a CDFJ+ DSWRITE byte address in [$098, $1B0) (the pointer and increment words); exclude that stream until the ARM rewrites the word (CR 20) | yes |
| `rmw_call`, `rmw_svc` | a CALLFN while `call_busy`; a taken CALLFUNCTION 1/2 while a service is pending or running | yes |
| `short_image` | 9.4 | only after a larger image |
| `drift_fe` | O1 | yes (information) |
| `call_len`, `dma_len`, `f6_len`, `release_dup` | lengths and the removed duplicate commit | hardware / mode B |
| **must be 0** | `seed_race`, `note_race`, `amp_lag` outside the classes above, `amp_input_race`, `tick_bad`, `over32k`, `wb_drop`, `a_collide`, `a_aux_late`, `a_wb_late` (buffer still full at the next E0+2), `a_guard_core`, `a_size_hi` (`audio_size_addr + 8 ≥ $8000`), `ram_wr_noaccess`, `obus_exposed`, `det_bad` | |

---

## 10. Estimate and critical path

### 10.1 ALMs, FF, M10K

| Block | ALMs [E] | FF [E] | Basis |
|---|---|---|---|
| `fe_seq` | 8 | 13 | |
| `fe_core` | 450 | 305 | bottom-up: DPC+ decode 16, CDF decode 38, ROM address and lookahead 26, op latch 12, W + adder + B 55, DSPTR 16, data addresses 22, word addresses 8, random 40, flag/`fe_do` 27, CDF state 30, DPC+ small state 45, service clamps and stage 46, write descriptors and buffer 30, `sel_up`/hotspots 16, commit glue 20. The sketch's core was 436 with BUS and without its W, adder or call side (README §4) |
| `fe_audio` | 480 | 756 | bottom-up: counters (adders with folded muxes) 48, frequencies 48, ring 48 (+ its compare 25), snapshot 34, digital adder 16, tick 18, offset 21, shifter (3:1 + 32→15) 36, sample address 25, address mux 20, digital compares 31, FSM/notes/sum/amplitude/sample client 90. Anchor: upstream's live `arm_mapper_audio` is 657 ALMs, 518 FF, with a full 32-bit shifter and full-width compares (README §1.1) |
| `fe_call` | 30 | 30 | FSM, toggles, counters; F0/F1 terms counted in `fe_arb` |
| `fe_copy` | 75 | 95 | sketch's copy engine 104 with the service registers (now in the core) |
| `fe_arb` | 100 | 6 | R address (8 sources × 13) 25, R data 20, be 5, S address 6, S data (fields, W, `{4{din}}`, F0, F1, `ring[0]`, 0) 32, A address 8, owners 4 |
| `fe_guard` | 8 | 11 | DI 9.3 |
| **Sum** | **1,151** | **~1,216** | |
| with fitter inefficiency 5-15% | **~1,200** (1,100-1,320) | | |
| M10K | 0 new | | uses `daria_mem`'s FE ROM, cart RAM, state RAM (upstream's tables and jump map, 8 M10K, are gone) |

Against `DARIA_CORE.md`'s 850-1,100 (Budget): +100 to +220. The step-3 projection (80.5-83.2%) moves to about 81-84%.

### 10.2 Where the extra area goes, and what it buys

| Item | ALMs | Buys |
|---|---|---|
| Flip-flop counters and frequencies with their own adders | ~130 over state-RAM words | exact ticks; no tick jobs or backlog; T2 compares exactly |
| Payload ring | ~75 | exact seeds and payload with no ordering rule; atomic merge; RMW swap; single post data source |
| Snapshot `rc` | ~34 | exact AMPLITUDE when a merge or a starved tick meets a refresh |
| Separate core W and adder | ~55 | no W contention between core and audio |
| `sel_up` replica, buffer yield, `amp_nx` | ~35 | AMPLITUDE and NOTE on upstream's edges |

### 10.3 Area levers, if step 7's fit needs them (in this order)

1. Drop the snapshot `rc`: −34. Adds a class `refresh_overlap` (a merge or a tick inside a refresh).
2. Non-atomic merge (apply each word as it arrives; drop the ring's staging role, keep its payload role): −25. Merge edges become per word; the bench's `merge_race` rule becomes per voice.
3. DI's state-RAM counters with deferred jobs: about −250. Brings back `amp_lag`, `note_race`, seed/merge ordering (DI R8).

### 10.4 Critical path (`clk_sys`, 69.84 ns)

| Path | Levels [E] | Delay [E] |
|---|---|---|
| `feb_q` (M10K tco) → lane mux → CDF predicates (13-bit equality, 9-bit range) → `c_sel` → `aud_take` → R owner → R address mux → M10K | ~9 LUT + 1 short carry | 16-20 ns |
| `feb_q` → decode → `c_idx` (8-bit subtract) → `ptr_base + idx` (9-bit add) → R address | ~7 LUT + 2 carries | 15-18 ns |
| `rc` → 3:1 → 5-level shifter → 15-bit add → mask → address mux → R address | ~10 LUT + 1 carry | 18-22 ns |
| `crb_q` → `W + inc<<12` (32-bit carry) → W | 2 LUT + carry | 8-10 ns |
| `access` (top.sv: TIA divider → pairing → `mapper_phi2` with the stall) → `c_sel` / DSWRITE `we` → R | top's ~5 + ~4 | 12-15 ns |

Every stage is register or M10K q → logic → register or M10K input; nothing starts in `clk_sdram` (`d_in` = `write_DB`, 1.3). Worst slack is about +45 ns. The detector path is the only cross-clock one and has its own pair (8.2).

---

## 11. Risks, and what to test first

### 11.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Area: about 1,200 ALMs against the 84% gate | Levers 10.3; measure each block with the study's probe as it is written (README §3.8) |
| 2 | `sel_up` differs from upstream's select in some clock (a stale-byte case, the offset window, a held cycle) | Audio lockstep compare every clock (11.2, test 2): the first differing grant points at the clock and the decode term |
| 3 | Exactness depends on the bench ROM's 1-clock timing (the mirror) | It is the stated target (D1, CR 9); hardware needs no upstream match |
| 4 | A short phase 1 (RSYNC) corrupts CDF/DPC+ RAM state | Counted, side effects skipped, directed RSYNC test; frequency in games unknown |
| 5 | The 7-clock merge window | Counted; the hook run proves the arithmetic; 6 → fewer clocks would need the merge before the reads finish |
| 6 | Guard SDC precedence and retiming in Quartus Lite 21.1 | Check the report for exactly one path per line; `PRESERVE_REGISTER` |
| 7 | ÷19 fallback: no exact shared edge, guard inert | Back to the counted race (DI 9.3) |
| 8 | NEW_DATA_NO_NBE_READ semantics unverified | Not relied on: no port's q is used in the clock after its own partial write |
| 9 | Untested paths in the image set: DPC+ copy/fill, CDF0, digital mode, RSYNC, hard reset, RMW CALLFN | Directed tests 11.2 |
| 10 | The P32 read and buffer depend on audio grants being ≥ 2 edges apart | Asserted (`a_aux_late`, `a_wb_late`) |

### 11.2 Test first

1. **`fe_core` alone against upstream's `mapper_dpcplus` and `mapper_cdf`** in a small Verilator bench with a synthetic bus and the tb ROM model (BEN 7.9 step 0, the study's random differential): `fe_do` at every latch, state after every cycle, `sel_up` against `sel_ram_sel` **on every clock**. Images seeded with $A9, $A2, $A0, $4C at bank ends, offsets.
2. **`fe_audio` against `arm_mapper_audio`**: both driven by the same `sel_ram_sel` stream, RAM, ticks, NOTE strobes, launches and merges (`hk` path), compared every clock. This proves the replica before integration.
3. **`fe_phase_det`** with aligned ÷48/÷18 clocks (three phases), ÷19 and 5×: lock, `shared_last` against the edge arithmetic, never locking where it must not.
4. tb_daria mode A on one DPC+ and one CDFJ image for 120 frames, then the set.
5. Directed: DPC+ copy/fill with the clamps (count 0, `off ≥ $7400`, `cnt` near $FFF), CDF0, CDFJ+ wrap and `tbl_alias`, digital mode below and above 32 KB, mid-line RSYNC, `+hard_reset_at`, RMW on CALLFN (FE→FF), `+fe_merge_hook=1`.
6. Mode B with `+d_ofs` sweep for the guard.
