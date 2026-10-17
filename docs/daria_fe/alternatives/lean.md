# daria_fe, Architect A ("lean"): micro-architecture for DARIA step 6

Scope: DPC+ and CDF0/CDF1/CDFJ/CDFJ+ (D2). BUS and ELF stay bad-game screens. Target: mode A of `docs/daria_fe/spec/bench.md` (D1).

Sources read for this design (all cited by file:line in the specs, re-checked where noted):

- the eight `docs/daria_fe/spec/*.md` files;
- `docs/DARIA_CORE.md`: "The front end (daria_fe)", "The memory system, the call port and the clock crossings", "Step 5 work";
- `sim/bupchip/daria/frontend_study/README.md` and `daria_fe3.sv`;
- `src/fpga/core/bupchip/{daria_mem.sv, daria_call.sv, bupchip_pocket.sv, bup_capture.sv}`;
- upstream `rtl/` re-read directly for this design:
  - `arm_mapper_audio.sv` (all 366 lines);
  - `mapper_cdf.sv:59-254` and `mapper_dpcplus.sv:75-326`;
  - `arm_mapper_controller.sv:80-180`;
  - `arm_mapper_ram_init.sv:125-235`;
  - `top.sv:250-335` and `top.sv:1395-1440`.

Repository facts that differ from the specs:

- `daria_mem.sv:159, 203` and `bupchip_pocket.sv:177, 360` already carry `stb_be` (commit a45f2b6). R1 is built.
- `bupchip_pocket.sv` exports neither the capture's window close nor a digital-sample port. Section 1.3 lists the two wrapper additions this design needs.

## 0. Conventions and the key choices

### Conventions

| Term | Meaning |
|---|---|
| E0 | The `clk_sys` edge that samples `pclk1` high. En = E0+n |
| s_n | The clock (En, En+1) |
| "issue X in s_n" | Address X is presented during s_n and registered at En+1; q is valid during s_n+1 (1-clock M10K latency, `daria_mem.sv:71-77`) |
| C | The commit edge: the edge that samples `access` high. It is E6 in a regular cycle, but the design keys on the event, not the count |
| cw1, cw2, cw3 | The clocks (C, C+1), (C+1, C+2), (C+2, C+3) |
| T | A tick edge |
| X | The edge at which `daria_fe` acts on a new synchronised `ret_tog` |
| M = X+1 | The logical merge edge |
| L = C+1 | The logical seed edge of a CALLFN commit |
| N = C+4 | The logical NOTE edge of a DPC+ NOTE commit |
| FER | Front-end ROM |
| crb, stb | Cart RAM port B, state RAM port B |
| Port names | As in `daria_mem.sv` |

### Key choices

| # | Choice | What it buys |
|---|---|---|
| K1 | **Reads before the commit, read-modify-writes after it.** In phase 1 the front end only reads: FER in s0, one state or cart RAM word in s1, one data byte in s2. `fe_do` is final at E4 at the latest. Every state change that needs RAM is a read-modify-write in cw1–cw3, keyed to C. No front-end value is held in W across phase 1 | W is never blocked by a frozen 6507 (pause, stretched phase). Commits stay exact for any phase-1 length of 2 or more clocks (2.6) |
| K2 | **The background is free-running.** Two threads (audio first, then the copy engine) run on whatever clocks the front end does not claim. W-coupled steps form 2–4-clock blocks that abort and restart if the front end claims a resource mid-block. There is no `phi1` ring and no slot number in the background | D3; critics 15, 16, 21, 22 |
| K3 | **Audio events are applied in logical order.** Each tick is a counter in a pending-tick count. Every NOTE, SEED and MERGE event records how many ticks precede it logically (`tb`, 2 bits) and waits for them. The physical time at which a job runs then does not change any counter, seed or frequency | `seed_race` = 0 and `note_race` = 0 (5.3). In mode A, `merge_race` is 0 unless the bench has to delay `ret_tog` |
| K4 | **AMPLITUDE** is computed per tick from the logical counters, so its value is exact. It is written when DARIA's tick job ends, typically T+11 to T+40. It is forwarded into `fe_do` up to C−1, so an AMPLITUDE read follows upstream's "written at or before C−1" rule exactly | The only AMPLITUDE difference is when it changes: the counted `amp_lag` |
| K5 | **One shared W and one adder** serve the front end (cw2/cw3) and the background (block steps). Fetchers, params, counters, frequencies and staging all live in the state RAM. CDF pointers and increments are used in place in cart RAM | The lean brief |
| K6 | **The shared-edge guard** lives in `daria_fe`: a 3-flop phase detector plus a phase-B issue rule for consumed cart RAM reads, and no cart RAM writes, while DARIA's CPU may touch cart RAM. It is inert when unlocked | D4 |

**Exactness level.**

- **NOTE** is exact by construction: its logical edge is C+4, and section 5.3 shows `note_race` can only occur in a pause or a NOTE overrun.
- **AMPLITUDE**: the value per tick is exact. Its timing is the counted lag (`amp_lag`, plus `amp_input_race` and `tbl_alias`).

---

## 1. Modules, hierarchy, ports

### 1.1 Hierarchy

All modules are new and Pocket-owned, MIT, in `src/fpga/core/bupchip/daria_fe.sv`.

```
daria_fe                      top; port list 1.2; instantiated in atari7800_pocket.sv beside bupchip_pocket
├─ dfe_slot    s-ring, ph2, commit ring cw[3:1], NOTE delay nq[3:0], front-end claims
├─ dfe_core    scheme decode, s0-s3 front-end reads, fe_do, DPC+/CDF flip-flop state, commit logic,
│              post-commit front-end micro-ops (requests to dfe_dp)
├─ dfe_dp      W, adder, B mux, write-data muxes, port owners and address muxes for FER A/B, crb, stb
├─ dfe_audio   tick generator, event bookkeeping, audio job sequencer, sample addressing, AMPLITUDE,
│              digital-sample request port
├─ dfe_copy    F6 (RAM image) + state-RAM clear, DPC+ service copy/fill, init_busy, arm_dma_busy
├─ dfe_call    call post, call_tog/ret_tog, call_busy, RMW pending call, release (ph2 rule)
└─ dfe_guard   phase detector (one clk_arm flop, clk_sys flywheel), guard_active, bissue
```

### 1.2 `daria_fe` ports

Every port is on `clk_sys` except where stated. "Reg" means the output comes straight from a flop.

| Port | Dir | Width | Clock / kind | Source or sink | Meaning |
|---|---|---|---|---|---|
| `clk_sys` | in | 1 | — | core | |
| `clk_arm` | in | 1 | — | PLL C3 (÷18) | Used only by `dfe_guard.ph_at` |
| `cart_reset` | in | 1 | level | top `effective_reset` (new POCKET_DARIA output) | Console/mapper reset |
| `pause` | in | 1 | level | `pause_core` | |
| `a_in` | in | 13 | from E0 | top `{AB[12]&bios_en_b, AB[11:0]}` | |
| `d_in` | in | 8 | | top `cart_din` | |
| `rw` | in | 1 | | top `RW` | |
| `pclk1` | in | 1 | 1-clock pulse | top `pclk1` (M6502C `phi1_ce`) | E0 is the edge sampling it |
| `pclk0` | in | 1 | 1-clock pulse | top `pclk0` (new in the group, critic 24) | |
| `access` | in | 1 | 1-clock pulse | top `mapper_phi2 && arm_driver_run` | |
| `scheme` | in | 6 | static | `fbs` (`atari7800_pocket.sv:1047`); 21 = DPC+, 23 = CDF | |
| `revision` | in | 3 | static | `mapper_revision`; `[1:0]` used | |
| `cdf_ldx`, `cdf_ldy` | in | 1+1 | static | detect2600 | |
| `cdf_off_en` | in | 1 | static | detect2600 | |
| `cdf_off` | in | 8 | static | detect2600 | |
| `cdfj_entry` | in | 32 | static | detect2600 (bit 0 already 0) | |
| `cdfj_stack` | in | 32 | static | detect2600 | |
| `audio_size_addr` | in | 16 | static | `arm_audio_size_addr` | |
| `rom_size` | in | 20 | static | `cart_size`, saturated at 0xFFFFF | |
| `ram32` | in | 1 | static | `mapper_ram_size == 32768` | |
| `load_start`, `load_end` | in | 1+1 | pulses | `mapper_load_start/end` | |
| `cap_close` | in | 1 | pulse | new `bupchip_pocket` output = `bup_capture.c_close` | 64 clocks after `load_end` |
| `call_ready` | in | 1 | level | Pocket: `daria_ready`. Mode A: the bench (1.4) | |
| `ret_tog` | in | 1 | **clk_arm register** | `daria_ret_tog` | Synchronised inside |
| `fea_q`, `feb_q` | in | 32+32 | | `daria_fea_q`, `daria_feb_q` | |
| `crb_q` | in | 32 | | `daria_crb_q` | |
| `stb_q` | in | 32 | | `daria_stb_q` | |
| `smp_ack` | in | 1 | **clk_arm register** | new wrapper port | Digital-sample answer toggle |
| `smp_data` | in | 8 | held | new wrapper port | Valid once `smp_ack` has flipped |
| `fe_do` | out | 8 | reg | `cart2600` POCKET_DARIA `direct_do` | |
| `fe_oe` | out | 1 | comb, `= a_in[12]` | `cart2600` `out_en = {8{fe_oe}}` | |
| `arm_call_busy` | out | 1 | reg | top stall (`top.sv:306-307`) | |
| `arm_dma_busy` | out | 1 | reg | top stall | Kept low while `init_busy` |
| `init_busy` | out | 1 | reg | `atari7800_pocket.sv:169-171` reset OR (R2; not `cart2600`'s `mapper_init_busy`) | |
| `call_tog` | out | 1 | reg | `daria_call_tog` | |
| `fea_addr` | out | 13 | M10K address | `daria_fea_addr` | |
| `feb_addr` | out | 13 | M10K address | `daria_feb_addr` | |
| `crb_addr` | out | 13 | M10K address | `daria_crb_*` | |
| `crb_we` | out | 1 | | | |
| `crb_be` | out | 4 | | | |
| `crb_wd` | out | 32 | | | |
| `stb_addr` | out | 8 | | `daria_stb_*` | |
| `stb_we` | out | 1 | | | |
| `stb_be` | out | 4 | | | |
| `stb_wd` | out | 32 | | | |
| `smp_req` | out | 1 | reg (toggle) | wrapper | |
| `smp_addr` | out | 19 | reg (held) | wrapper | Image byte offset, 32 KB to 512 KB |

The M10K address and write-data outputs are logic from registers and M10K q into the M10K's input registers (D10: q → logic → M10K address). Nothing enters from `rom_do`, `cartram_*` or `sram_ctrl`, so no path is in the `clk_sdram` cone.

### 1.3 Changes the design needs outside `daria_fe`

| File | Change |
|---|---|
| `top.sv` (POCKET_DARIA group) | Outputs `a_in`, `d_in`, `rw`, `pclk1`, **`pclk0`** and `access` (= `mapper_phi2 && arm_driver_run`), plus `effective_reset`. Inputs `fe_do`, `fe_oe`, `arm_call_busy` and `arm_dma_busy`, which feed `arm_call_stall` |
| `cart2600.sv` (POCKET_DARIA, inside `NO_ARM_MAPPER`) | `BANKDPCP`/`BANKCDF`: `direct_do = fe_do`, `flags_out = 1`, `out_en = {8{fe_oe}}`, `ram_sel = 0`, `rom_addr = 0`. `is_bad_game` keeps ELF and BUS only. `mapper_init_busy` stays 0 (R2) |
| `bupchip_pocket.sv` (POCKET_DARIA) | New output `daria_cap_close` (= `capture.c_close`, one wire out of `bup_capture`). New inputs `daria_smp_req` and `daria_smp_addr[18:0]`. New outputs `daria_smp_ack` and `daria_smp_data[7:0]`. The digital-sample requester (5.9) |
| `atari7800_pocket.sv` | Instantiate `daria_fe`. OR `init_busy` into the reset register at :169-171. Wire `clk_arm`, `pause_core`, detect2600's outputs and `fbs` |
| `core_constraints.sdc` | The detector pair (8.2) |

### 1.4 Mode A wiring

`fe_shadow.svh` drives every input with a continuous assign.

| Input | Driven by |
|---|---|
| `call_ready` | `dut.cart2600.arm_mappers.call_controller.arm_online_sync2 && …shadow_ready_sync2 && !dut.effective_reset`, with no `call_busy` term (critic 8) |
| `ret_tog` | `complete_toggle ^ ret_bias`, released per call number: the bench holds a return until `daria_fe` has posted that call (D5) |
| `cap_close` | A pulse 64 `clk_sys` after `load_end` |
| `clk_arm` | Upstream's 5× clock. The detector never locks, so the guard is inert (8.3) |
| `smp_ack`, `smp_data` | Answer `img[smp_addr]` after `+fe_slat` clocks |
| `pclk0` | `dut.pclk0` |

The other inputs follow `bench.md` 7.4.1.

### 1.5 Bench taps

All taps are hierarchical, read-only, and mapped in `fe_taps.svh`.

| Group | Tap | Notes |
|---|---|---|
| phases | `slot.fs[5:0]`, `slot.ph2`, `slot.cw[3:1]`, `slot.wbc`, `core.commit` | |
| DPC+ registers | `core.bank`, `core.d_ff`, `core.d_fp`, `core.rnd`, `core.pptr` (0–4; compare `min(parameter_pointer,4)`), `core.wave0..2` | |
| CDF registers | `core.bank`, `core.mode`, `core.c_fp`, `core.fexp`, `core.jr`, `core.jexp`, `core.jodd` | `jump_stream` = 33 + `jodd` |
| fetchers and audio words | Backdoor of `fe_mem.state_ram.mem_q[w]`, map in section 4 | Masks: w0 `0xFFFF0FFF`, w1 `0xFF0FFFFF`, params `0xFFFFFFFF` |
| copy engine | `copy.src0` (17), `dst0` (13), `cnt0` (requested p3), `val`, `fill`, `svc2_p`, `ci`, `cp_run`, `f6_run`, `f6_ph`, `init_busy`, `dma_busy` | The bench forms `count = min(cnt0, 0x1C00−dst0, fill ? ∞ : max(0, 0x8000−src0))` for R2 |
| audio | `aud.tick` (comb), `aud.tk`, `aud.amp`, `aud.aj`/`aud.as`/`aud.av`, `aud.tick_done` (strobe, with `aud.tick_seq`), `aud.ev_note`, `aud.ev_seed`, `aud.ev_merge` (strobes at their logical edges N, L/M, M), `aud.ctr_busy` (a counter or frequency word is mid-update: no deposit) | |
| call | `call.call_tog`, `call.ret_seen`, `call.inflight`, `call.post_rdy`, `call.call2_p`, `call.follow`, `call.rel_req`, `call.post_cnt`, `call.ret_cnt` | |
| guard | `guard.ph`, `guard.lk`, `guard.locked`, `guard.bissue`, `guard.active` | |
| port use | `dp.crb_use` (this clock's crb read will be consumed), `dp.crb_own` (one-hot F6/FE/AUD/CPY), `dp.stb_own` | |
| assertions (sim only) | `aud.tk_sat_cnt`, `aud.note_ovr_cnt`, `dp.guard_wr_cnt`, `core.guard_sub_cnt`, `core.short_ph1_cnt` | |

Deposit for resync (`bench.md` 7.6): `fe_taps.svh` writes `mem_q[0x18+v]` and `mem_q[0x1C+v]` at a falling `clk_sys` edge while `aud.ctr_busy == 0`.

---

## 2. Front-end timing

### 2.1 `dfe_slot`: events, not counts

Pseudo-RTL. All registers are on `posedge clk_sys` with reset 0 unless stated.

```
fe_on   = (scheme == 21) | (scheme == 23);   dpc = scheme == 21;   cdf = scheme == 23
plus    = cdf & revision[1:0] == 3;   jrev = cdf & revision[1];   srev1 = revision[0]   // DPC+ stable_fractional

// s-ring: s0..s5, s5 sticky until pclk0 (stretched phase 1) ; 3-input data mux, one load enable
fs   : ld = pclk1 | pclk0 | (|fs[4:0])
       d  = pclk1 ? 6'b000001 : pclk0 ? 6'b000000 : {fs[4:0],1'b0}
// phase 2 flag for the release rule (D3): set at the pclk0 edge, cleared at the pclk1 edge
ph2  : ld = pclk1 | pclk0;   d = !pclk1
// commit and its ring
commit = access & a_in[12] & fe_on & !cart_reset           // acted at the edge ending this clock
cw   : ld = 1;  d = {cw[2:1], commit}                      // cw[1] high in cw1 = (C, C+1)
wbc  : ld = commit;  d = wb(cop)                           // the committed op uses cw1..cw3 (2.4)
nq   : ld = 1;  d = {nq[2:0], commit & cop.DMS & g==9 & idx>=5}   // NOTE: event at edge C+4
cfn1 : ld = 1;  d = commit & callfn(cop) & !call_busy      // high in cw1 -> SEED enqueued at C+1

// front-end claims (comb, for the clock they are evaluated in)
fe_fea = fs[0]                                             // FER A: lookahead word
fe_st  = dpc & (fs[1] | (wbc & |cw))
fe_crb = (cdf & fs[1]) | fs[2] | (wbc & |cw)
fe_w   = wbc & (cw[2] | cw[3])                             // W live from edge C+2 through cw3
```

**Front-end resource use per 6507 cycle.**

| Clock | FER B | FER A | stb | crb | W / adder |
|---|---|---|---|---|---|
| s0 | Bank word | Next word | — | — | — |
| s1 | — | — | DPC+ fetcher word | CDF pointer | — |
| s2 | — | — | — | Data byte | — |
| s3–s5+ | — | — | — | — | — |
| cw1 | — | — | DPC+ read or field write | CDF read | — |
| cw2 | — | — | DPC+ service read | CDF read or DSWRITE byte | load W at C+2 |
| cw3 | — | — | DPC+ write | CDF write or PUSH/WRITE byte | sum |

- FER port B belongs to the front end at all times. Its address is `cur[14:2]` every clock, with no mux.
- In 2600 mode the front end uses at most 5 of the 12 clocks of a cycle on stb or crb: s1, s2, cw1, cw2, cw3.
- Free runs are at least s3–s5 (3 clocks) and cw3+1 to the next s0 (4 clocks), because phase 2 is at least 6 clocks whenever a commit happens (`bus.md` B2).

### 2.2 The s0 address and the s1 decode (`dfe_core`)

```
base    = dpc ? 15'h0C00 : plus ? 15'h0800 : 15'h1000
cur     = base + {bank, a_in[11:0]}            // 15-bit image offset; lane = a_in[1:0]
feb_addr = cur[14:2]                           // every clock
fea_addr(FE, s0) = cur[14:2] + 1               // the next word, for the jump lookahead
x7ffe   = cur[14:1] == 14'h3FFF                // upstream's map entries 0x7FFE/0x7FFF are 0

// s1 (fs[1]): rom byte and lookahead
rom_b = feb_q[8*a_in[1:0] +: 8]
win8  = {fea_q, feb_q};   la1 = win8[8*(a_in[1:0]+1) +: 8];   la2 = win8[8*(a_in[1:0]+2) +: 8]
jok_d = la1[7:1] == 0 & la2 == 0 & !x7ffe                // = fast_jump_valid for rom_a = cur
```

**DPC+ decode (s1).** As `mapper_dpcplus.sv:113-124`.

```
dp_direct = a_in[11:6]==0 & a_in[5:3] < 5
dp_rreg   = dpc & rw & a_in[12] & (dp_direct | (d_ff & d_fp & rom_b < 8'h28))
dp_reg    = dp_direct ? a_in[5:0] : rom_b[5:0];  dp_fn = dp_reg[5:3];  dp_ix = dp_reg[2:0]
dp_wr     = dpc & !rw & a_in[12] & a_in[11:7]==0 & a_in[6:3] >= 5       // $028-$07F
dp_g      = a_in[6:3] - 5                                               // group 0..10
hot_d     = a_in[12] & (dpc ? a_in[11:0] inside [FF6:FFB] : a_in[11:0] inside [FF4:FFB])
```

**CDF decode (s1).** As `mapper_cdf.sv:77-112`.

```
amp_s   = jrev ? 35 : 34
in_rng  = cdf_off_en ? (rom_b >= cdf_off && {1'b0,rom_b} <= cdf_off + amp_s) : rom_b <= amp_s
amp_op  = cdf_off_en ? (amp_s + cdf_off[5:0])[5:0] : amp_s
c_fsub  = cdf & rw & a_in[12] & fast_mode & c_fp & a_in == fexp & in_rng
c_jval  = (jr==2 & (jrev ? rom_b[7:1]==0 : rom_b==0)) | (jr==1 & rom_b==0)
c_jsub  = cdf & rw & a_in[12] & jr!=0 & a_in == jexp & c_jval
c_amp   = c_fsub & !c_jsub & rom_b[5:0] == amp_op
s_d     = c_jsub ? 33 + (jr==2 ? (jrev & rom_b[0]) : jodd) : (cdf_off_en ? rom_b - cdf_off : rom_b)[5:0]
fast_mode = mode[3:0]==0;   arms(b) = b==8'hA9 | (plus & cdf_ldx & b==8'hA2) | (plus & cdf_ldy & b==8'hA0)
```

**One-hot `op_d` (the `op` register loads it at the end of s1).**

| op | Condition | Write-back (`wb`)? |
|---|---|---|
| RNG | `dp_rreg & fn==0 & ix!=5` | no |
| AMP | `(dp_rreg & fn==0 & ix==5) \| c_amp` | no |
| DAT | `dp_rreg & fn ∈ {1,2,3}` | yes |
| FLG | `dp_rreg & fn==4` | no |
| DFW | `dp_wr & g ∈ {0,1,2,3,4,5,8}`: FRACLOW, FRACHI, FRACINC, TOP, BOTTOM, LOW, HI | yes |
| DRW | `dp_wr & g ∈ {7,10}`: PUSH, WRITE | yes |
| DMS | `dp_wr & g ∈ {6,9}` | only PARAMETER with `pptr < 4` and a taken service |
| FET | `c_fsub & !c_jsub & !c_amp` | yes |
| JMP | `c_jsub` | yes |
| DSW | `cdf & !rw & a_in==13'h1FF0` | yes |
| DSP | `cdf & !rw & a_in==13'h1FF1` | yes |
| CRG | `cdf & !rw & a_in[12:1]==12'hFF9` ($1FF2, $1FF3) | no |
| ROM | `rw & a_in[12] &` none of the reads above | no |
| NIL | otherwise | no |

s1 field registers, loaded with `ld = fs[1]`, data = the decode:

- `op` (14, one-hot), `fidx` (3) = `rw ? dp_ix : a_in[2:0]`, `fn` (4) = `rw ? dp_fn : dp_g`, `w1` (1) = word select;
- `s` (6) = `(op_d.DSW|DSP) ? 32 : s_d`, `rb` (8) = `rom_b`, `jok` (1), `hot` (1) = `hot_d`.

**Commit-time selection.** `cop`, `cfidx`, `cfn`, `cs`, `crb_c` and `cjok` are `fs[1] ? <decode> : <register>`. When phase 1 is 2 clocks, the commit edge is the edge that ends s1, and the live decode is used. This keeps all state exact (2.6).

`wb(cop)` = DAT | DFW | DRW | FET | JMP | DSW | DSP | (DMS & ((g==6 & idx==1 & pptr<4) | svc_take)).

### 2.3 `fe_do` (8 FF, one load enable, 4 AND-OR sources)

```
d1      = op_d.ROM ? rom_b : op_d.RNG ? rbyte(dp_ix) : 8'h00      // rbyte: 0 next[7:0], 1 prior[7:0],
                                                                  // 2..4 rnd[15:8],[23:16],[31:24], 6,7 -> 0
flg8    = {8{win(stb_q) & fidx < 4}}                               // s2, from w0
win(w)  = (w[23:16] - w[7:0]) > (w[23:16] - w[31:24])              // 8-bit modular, DPC:107-110
rbyte8  = crb_q[8*l2 +: 8] & (op.DAT & fn==2 ? {8{flag}} : 8'hFF) // s3
amp_ref = op.AMP & !ph2 & (|fs[5:2]) & !pclk0                      // refresh until C-1
ld      = fs[1] | (fs[2] & op.FLG) | (fs[3] & (op.DAT|op.FET|op.JMP)) | amp_ref
d       = ({8{fs[1] & !op_d.AMP}} & d1) | ({8{(fs[1] & op_d.AMP) | amp_ref}} & aud.amp_fwd)
        | ({8{fs[2] & op.FLG}} & flg8)   | ({8{fs[3]}} & rbyte8)
```

- `amp_fwd` is the AMPLITUDE register's next value: `amp_we ? amp_new : amp` (5.7).
- `fe_do` stands in clock C−1 with whatever the AMPLITUDE register holds in C−1. That is upstream's rule (`audio.md` 14).
- After C, `fe_do` holds the committed byte. This is the counted `open_bus` difference.
- Other registers:
  - s2: `l2 ← addr[1:0]` of the data byte, and `flag ← win(stb_q)`, both with `ld = fs[2]`.
  - commit: `dl ← d_in` with `ld = commit`.

### 2.4 Per-access timing tables

How to read the tables:

- An entry in a port column is the address issued in that clock.
- **Final** marks the edge at which `fe_do` holds the cycle's value.
- The latch is at C (= E6 nominal).
- "C" in a row is what happens at the commit edge.

#### DPC+ register reads

| Access | s0 | s1 | s2 | s3 | Final | C | cw1 | cw2 | cw3 |
|---|---|---|---|---|---|---|---|---|---|
| RANDOM0NEXT / PRIOR ($1000/1) | FER B, A | decode; `fe_do←next/prior[7:0]` | | | **E2** | `rnd←next/prior` | | | |
| RANDOM1-3 ($1002-4) | FER | `fe_do←rnd byte` | | | E2 | — | | | |
| AMPLITUDE ($1005) | FER | `fe_do←amp_fwd` | `fe_do←amp_fwd` | `fe_do←amp_fwd` | E2 to C−1 (forwarded) | — | | | |
| $1006/7, $1024-27 | FER | `fe_do←0` | | | E2 | — | | | |
| DATA ($1008-F) | FER | stb R `{fidx,0}` | crb R `0xC00+w0[11:0]`; `flag,l2←` | `fe_do←byte` | **E4** | `fp←0` | stb R w0 | `W←w0` | stb W w0 ← W+1, be 0011 |
| DATAW ($1010-7) | as DATA | | | `fe_do←byte & flag` | E4 | `fp←0` | as DATA | | |
| FRACDATA ($1018-F) | FER | stb R `{fidx,1}` | crb R `0xC00+w1[19:8]` | `fe_do←byte` | E4 | `fp←0` | stb R w1 | `W←w1` | stb W w1 ← W+{24'b0,W[31:24]}, be 0111 |
| FLAG ($1020-7) | FER | stb R `{fidx,0}` | `fe_do←flg8` | | **E3** | `fp←0` | | | |
| Fast fetch operand (`LDA #$xx`, ROM byte < $28) | FER | decode from `rom_b` | as the direct register read | | same as the register | `fp←0`; no hotspot | | | |
| Plain ROM read, incl. hotspot reads | FER | `fe_do←rom_b` | | | E2 | `fp←d_ff & rb==A9`; hotspot `bank←a[2:0]−6` | | | |

#### DPC+ writes

`d_in` (= `write_DB`) is valid from E0. `dl` is latched at C.

| Register | C | cw1 | cw2 | cw3 |
|---|---|---|---|---|
| FRACLOW $028+x | — | stb W `{x,1}`: rev1 be 0011, data `{..,dl,00}`; rev0 be 0010 | | |
| FRACHI $030+x | — | stb W `{x,1}` be 0100, lane2 = `{4'b0,dl[3:0]}` | | |
| FRACINC $038+x | — | stb W `{x,1}` be 1001, data `{dl,..,..,00}` | | |
| TOP $040+x | — | stb W `{x,0}` be 0100, lane2 = dl | | |
| BOTTOM $048+x | — | stb W `{x,0}` be 1000 | | |
| LOW $050+x | — | stb W `{x,0}` be 0001 | | |
| HI $068+x | — | stb W `{x,0}` be 0010, lane1 = `{4'b0,dl[3:0]}` | | |
| FASTFETCH $058 | `d_ff←(d_in==0)` | | | |
| PARAMETER $059 | `pptr←min(pptr+1,4)` if `pptr<4` | stb W 0x10, be `1<<pptr`, data `{4{dl}}` | | |
| CALLFUNCTION $05A = 0 | `pptr←0` | | | |
| CALLFUNCTION = 1/2 and `!svc_busy` | `pptr←0`; `svc_busy, dma_busy←1`; `fill←(d==2)` | stb R 0x10 | `src0←0xC00+st_q[15:0]`, `cnt0←st_q[31:24]`, `val←st_q[7:0]`; stb R `{st_q[18:16],0}` | `dst0←0xC00+st_q[11:0]`; start the copy engine |
| CALLFUNCTION = 1/2 and `svc_busy` | `svc2_p←1`, `fill2←(d==2)` if `!svc2_p` (RMW, 7.3) | | | |
| CALLFUNCTION = FE/FF | call (6.1) | | | |
| WAVEFORM0-2 $05D-F | `wave[a[1:0]−1]←d_in[6:0]` | | | |
| PUSH $060+x | — | stb R w0 | `W←w0`; `da←0xC00+(w0[11:0]−1)` | stb W w0 ← W+0xFFF, be 0011; crb W byte `da` ← dl |
| WRITE $078+x | — | stb R w0 | `W←w0`; `da←0xC00+w0[11:0]` | stb W w0 ← W+1, be 0011; crb W byte `da` ← dl |
| RRESET $070 | `rnd←0x2B435044` | | | |
| RWRITE0-3 $071-4 | `rnd` byte k ← d_in | | | |
| NOTE0-2 $075-7 | `nvoice←a[1:0]−1`, `nval←d_in`; `nq[0]←1` | (NOTE event at C+4, 5.3) | | |
| $000-$027, $080-$FF5, $FFC-$FFF | — | | | |
| Hotspot write $FF6-FB | `bank←a[2:0]−6` | | | |

#### CDF family

| Access | s0 | s1 | s2 | s3 | Final | C | cw1 | cw2 | cw3 |
|---|---|---|---|---|---|---|---|---|---|
| Fast fetch, stream s (with or without fetch offset; LDX/LDY arming only changes `fp`) | FER | crb R `pb+s` | crb R `disp(crb_q)`; `l2←` | `fe_do←byte` | **E4** | `c_fp←0`; `cs←s` | crb R `pb+cs` | `W←P`; crb R `ib+cs` | crb W `pb+cs` ← W + (I[15:0]<<12, CDFJ+ <<8) |
| Amplitude stream (`s == amp`) | FER | `fe_do←amp_fwd` | refresh | refresh | E2 to C−1 | `c_fp←0`; no RAM, no pointer | | | |
| Jump arming read (`$4C` at X, not substituted) | FER B word X, FER A word X+4 | `jok←la1[7:1]==0 & la2==0 & X<0x7FFE` | | | E2 (ROM byte) | `jr←2`, `jexp←a_in+1`, `jodd←0` (rules 2.5) | | | |
| Jump operand 1 (`jr==2`, `a_in==jexp`, operand valid) | FER | crb R `pb+33+(jrev&rb[0])` | crb R `disp` | `fe_do←byte` | E4 | `c_fp←0`; `jodd←jrev&rb[0]`; `jr←1`; `jexp++` | crb R `pb+cs` | `W←P` | crb W ← W + (1<<20, CDFJ+ 1<<16) |
| Jump operand 2 (`jr==1`, operand == 0) | FER | crb R `pb+33+jodd` | crb R `disp` | `fe_do←byte` | E4 | `jr←0`; `jexp++` | as operand 1 | | |
| DSWRITE $1FF0 | FER | — | — | — | — | `dl←d_in` | crb R `pb+32` | crb W byte `disp(crb_q)` ← dl, be `1<<disp[1:0]`; `W←P32` | crb W `pb+32` ← W + (1<<20 / 1<<16) |
| DSPTR $1FF1 | FER | — | — | — | — | `dl←d_in` | crb R `pb+32` | `W←P32` | crb W `pb+32` ← `shiftin(W,dl)` |
| SETMODE $1FF2 | | | | | | `mode←d_in` | | | |
| CALLFN $1FF3 | | | | | | FE/FF: call (6.1) | | | |
| Plain ROM read, incl. reads of $1FF0-3 | FER | `fe_do←rom_b` | | | E2 | arming (2.5); hotspot | | | |
| Hotspot $1FF4-B (read or write, not substituted) | | | | | | `bank ← (FF4\|FFB) ? (plus?0:6) : a[2:0]−(plus?4:5)` | | | |

The functions used in the CDF rows:

- `disp(P)` = `plus ? (0x800 + P[30:16]) mod 0x8000 : 0x800 + P[31:20]` (a byte address; crb gets `[14:2]`, the lane is `[1:0]`; R5).
- `shiftin(W, dl)` = `plus ? {W[23:16], dl, 16'h0} : {W[23:20], dl, 20'h0}` (`mapper_cdf.sv:234-242`).
- Word bases `pb`/`ib` (`arm_mapper_tables.sv:104-122`):

  | Revision | `pb` | `ib` |
  |---|---|---|
  | CDF0 | 0x1B8 | 0x1DA |
  | CDF1 | 0x028 | 0x04A |
  | CDFJ/J+ | 0x026 | 0x049 |

Two facts about DSWRITE:

- It writes the byte before the pointer, as upstream does (port A at E6, then the writeback at E7.8).
- The pointer is read at cw1, before the byte write, so its old value is used.

**Fit proof.** A read passes through at most three M10K stages before the latch: FER (issued in s0), then the pointer or fetcher word (s1), then the data byte (s2). With 1-clock latency the byte reaches `fe_do` at E4. That is 2 edges before E6 and 3 before the pclk0 clock ends.

Every post-commit write is registered by C+3. The next cycle's first front-end read is registered no earlier than C+8, because phase 2 lasts at least 6 clocks after any commit (`bus.md` B2). The cycle after can therefore never see stale state. All C1–C4 compares at E12 see the written state.

### 2.5 Commit logic (`dfe_core`, edge C, `commit == 1`)

`cop` and the other c-values are as in 2.2.

```
// DPC+
bank   (3) : rst->5 | dpc&!rreg(cop)&hot -> a[2:0]-6            (rreg = RNG|AMP|DAT|FLG)
d_fp   (1) : rst->0 | dpc&rw: rreg ? 0 : d_ff & crb_c==8'hA9
d_ff   (1) : rst->0 | DMS&g==6&idx==0 -> d_in==0
rnd   (32) : rst->0x2B435044 ; 4-input mux: RNG&idx==0 ->next | RNG&idx==1 ->prior
             | DMS&g==9&idx==0 ->0x2B435044 | DMS&g==9&idx in 1..4 -> byte-replaced(rnd, idx-1, d_in)
pptr   (3) : rst->0 | DMS&g==6&idx==1&pptr<4 ->pptr+1 | DMS&g==6&idx==2&(d==0 | (d in{1,2}&!svc_busy)) ->0
wave0..2(7): rst->0 | DMS&g==6&idx==5/6/7 -> d_in[6:0]
nvoice(2), nval(8) : DMS&g==9&idx>=5 -> {idx[1:0]-1, d_in}
// CDF
bank   (3) : rst->(plus?0:6) | cdf&!sub(cop)&hot -> table above       (sub = FET|JMP|AMP)
mode   (8) : rst->8'hFF | CRG&!a[0] -> d_in
c_fp   (1) : rst->0 | cdf&rw: sub ? 0 : fast_mode&arms(crb_c)
fexp  (13) : cdf&rw&!sub&fast_mode&arms(crb_c) -> a_in+1
jr     (2) : rst->0 | cdf&rw: JMP ? jr-1
                          : !sub&(jr!=0)&(a_in==jexp) ? 0
                          : !sub&fast_mode&crb_c==8'h4C&cjok ? 2
                          : !sub&(jr!=0) ? 0 : jr
jexp  (13) : JMP -> jexp+1 | (!sub & jr arming) -> a_in+1          (2-input mux)
jodd   (1) : rst->0 | arming ->0 | JMP&(jr==2) -> jrev&crb_c[0]
// both
dl     (8) : commit -> d_in
callfn = (dpc&DMS&g==6&idx==2 | cdf&CRG&a[0]) & d_in[7:1]==7'h7F
svc_take = dpc&DMS&g==6&idx==2&(d_in==1|d_in==2)&!svc_busy
```

- `fast_pending && jr != 0` can never hold (`cdf.md` 10.7). Assertion `core.fpjr` checks it.
- The DPC+ "write on the accept edge is dropped" race (`dpcplus.md` 8.3) cannot happen here, because DARIA has no accept edge. It is unreachable upstream as well.

### 2.6 Irregular phases (D3)

| Case | Effect in DARIA | Exact? |
|---|---|---|
| Stretched phase 1 (MARIA to TIA handoff, `top.sv:1287-1342`) | `fs[5]` holds; `fe_do` holds; the commit comes whenever `access` does; cw1–cw3 follow C | yes |
| Phase 1 = 2 clocks (RSYNC, `bus.md` B2) | C = E2. `cop` = live s1 decode. `fs` clears at C, so there is no s2. cw1–cw3 run from C, so state, RAM and events are exact. `fe_do` was loaded at E2 = C, too late: the latch sees the previous byte | state yes; `fe_do` no, counted `short_phase1` (critic 26) |
| Phase 2 = 10 (RSYNC) | More background clocks | yes |
| MARIA 4/6-clock phases (BIOS path, 7800 mode) | `access` = 0, no commits. Claims are only s1/s2; the background runs | yes (no state change) |
| Pause | No `pclk*`. The ring stops in place; cw1–cw3 complete (`clk_sys`). Claims end after s2/cw3; the background has every clock | yes |
| Held repeats (stall) | Each repeat restarts `fs`; `op` is re-decoded for the same address. Hidden `pclk0`: no commit | yes |
| First cycle after reset release | `fs` runs through the reset (MARIA phases), so the first `access` finds a valid `op` | yes |

---

## 3. Port arbitration

### 3.1 Owners per clock

Owners are listed in priority order. F6 runs only while `init_busy` and the console is in reset.

| Port | Owner order | Notes |
|---|---|---|
| FER B | front end, always (`cur[14:2]`) | |
| FER A | F6 > front end (s0: `cur[14:2]+1`) > audio (digital ROM sample below 32 KB) > copy engine (source word) | The capture overrides it in `cap_we` clocks (wrapper, `daria_mem.sv:196`), which happen only during a download |
| stb | F6 clear > front end (`fe_st`) > audio | The copy engine has no stb access of its own: its parameter reads are the front end's cw1/cw2 |
| crb | F6 > front end (`fe_crb`) > audio > copy engine | Guard rules in 3.3 |
| W, adder | front end in cw2/cw3 (`fe_w`); audio otherwise | The copy engine and F6 never use W |

Arbitration is AND-OR, with one-hot owner selects formed at the start of each clock:

```
own_f6  = f6_run
st_fe   = !f6_run & fe_st ;            st_aud = !f6_run & !fe_st & aud.st_req
crb_fe  = !f6_run & fe_crb;            crb_aud = !f6_run & !fe_crb & aud.crb_req & crb_ok_aud
crb_cpy = !f6_run & !fe_crb & !aud.crb_req & cpy.crb_req & !guard.active
fea_fe  = !f6_run & fe_fea;            fea_aud = !f6_run & !fe_fea & aud.fea_req;   fea_cpy = ... & !aud.fea_req
```

Each client gives its address and data through its own pre-mux, and the port mux is a 4-way AND-OR by owner. A client step is **granted** when it owns every port it needs in that clock.

### 3.2 Blocks and the abort rule (the W-sharing proof)

The steps that load W, or consume W or the adder, belong to the blocks of 5.4:

| Block | Steps | Clocks |
|---|---|---|
| Voice | B1, B2, B3 | 3 |
| Digital | D0, D1, D2, D3 | 4 |
| NOTE | N1, N2 | 2 |
| Copy | CR, CW | 2 |
| Merge | M1, M2, M3 | 3 |

**The rule.** A block step that is not granted in its clock, or that falls in a clock with `fe_w` high, sends the sequencer back to the block's first step. A step that has not been granted has no side effect: there is no write and no W load. The first step of a block is a pure read, so a restart is idempotent.

**Why W stays safe.**

1. The front end loads W only at C+2, in a clock (cw2) with `fe_w` high. It consumes W only in cw3, also with `fe_w` high. So no audio step loads or uses W in those clocks.
2. An audio block always consumes W in the clock right after it loaded it (B2→B3, D1→D2→D3, M2→M3).
3. If that next clock is cw2 or cw3, the block aborts before using W.
4. W is therefore time-shared in non-overlapping 2-clock windows.

**Why the background makes progress.** Every 12-clock cycle has at least two free 3-clock runs (2.1). A pause or a held stall frees every clock except s1/s2. So a 4-clock block always completes within one cycle.

### 3.3 The shared-edge guard (D4): the phase-B rule

`guard.active` (8.3) is high while DARIA's CPU may access cart RAM, if the detector is locked. While it is high:

1. **No crb write by anyone but F6**: `crb_we` is ANDed with `!guard.active | f6_run`. Neither the front end nor the copy engine can need a write in that window (8.4). A write that this AND blocks counts `dp.guard_wr_cnt` (must be 0).
2. **Every consumed crb read is issued in a clock with `guard.bissue`**, which is `ph == 0`, the clock right after a predicted shared edge. Its address is then registered on the phase-B edge: 17.46 ns after the last `clk_arm` edge and 8.73 ns before the next.
   - Audio single reads (PTR, SIZ, N1) wait for `bissue`.
   - Blocks whose last step reads crb (B3 with a sample read; D3 with a RAM sample) start only when the read will land on a B-issue clock:
     - B1 is granted only if `ph == 1` (B3 then falls at `ph == 0`);
     - D0 only if `ph == 0` (D3 is three clocks later, also `ph == 0`).
   - Front-end s1/s2 crb reads are suppressed (`fe_crb` still claims the port, but `crb_we`=0 and the address is don't-care). During a call, the visible commits are F, its release-window duplicate and the RMW second CALLFN write. All three are opcode fetches or register writes and consume no crb data. `core.guard_sub_cnt` counts a visible commit of FET, JMP or DAT under the guard (must be 0).
   - FER and stb reads are unaffected. The state RAM's ports are ordered by the call toggles (6.4).
3. **Unlocked detector**, as in mode A (5× clock) or the ÷19 fallback: `guard.active` = 0, and the guard is inert.

---

## 4. State placement

### 4.1 State RAM word map (256 × 32, port B ours, byte enables on)

| Word | Contents | Writers (port B) | Readers |
|---|---|---|---|
| 0x00–0x0F | DPC+ fetcher x: `w0` at 2x = `{bottom[31:24], top[23:16], spare:ctr[11:8], ctr[7:0]}`; `w1` at 2x+1 = `{inc[31:24], spare:frac[19:16], frac[15:0]}` | front end cw1/cw3; F6 clear | front end s1/cw1/cw2 |
| 0x10 | DPC+ params `{p3,p2,p1,p0}` (params 4–7 not stored) | front end cw1; F6 | front end cw1 (service) |
| 0x11–0x17 | — | F6 | — |
| 0x18–0x1A | Live counters C0–C2 | audio (TICK B3, MERGE M3); F6 | audio (B1, D1, SEED) |
| 0x1B | — | | |
| 0x1C–0x1E | Live frequencies L0–L2 | audio (NOTE N2, MERGE freq copies); F6 | audio (B2, SEED) |
| 0x1F | — | | |
| 0x20–0x25 | RMW staging S0–S5 (seeds 0–2, frequencies 0–2 of a queued second call) | audio SEED (staged) | audio POST |
| 0x26–0xEF | — (cleared by F6) | F6 | |
| 0xF0 | Call block: entry \| T | audio POST (PF0) | `daria_call` A3 |
| 0xF1 | Call block: stack | POST (PF1) | A18 |
| 0xF2–0xF4 | Seeds (r8–r10) | SEED (direct) / POST (from staging) | `daria_call` A21–A23; audio MERGE |
| 0xF5–0xF7 | Posted frequencies (r11–r13) | SEED / POST | A24–A26 |
| 0xF8–0xFA | Return counters | `daria_call` R2–R4 | audio MERGE |
| 0xFB–0xFD | Return frequencies | `daria_call` R5–R7 | audio MERGE |
| 0xFE–0xFF | — | | |

**Why the live frequencies are not F5–F7** (deviation from R10):

- An RMW second call must carry the *pre-merge* frequencies, because upstream's payload at M is pre-edge (`arm_mapper_controller.sv:149-158`).
- The ticks during that second call must use the *post-merge* frequencies.
- One word cannot hold both values, so the live frequencies sit at 0x1C–0x1E and the SEED job copies them to F5–F7.

F6 clears 0x00–0xEF only. The call block is never touched on port B while `daria_call` may own it: F0–F7 are written before `call_tog` flips, and F8–FD are only read.

### 4.2 Cart RAM (in place, port B)

| Bytes | Contents |
|---|---|
| 4·pb…, 4·ib… | CDF pointer and increment tables |
| 0x7F0 (CDF0), 0x1B0 (others) | Waveform pointer words |
| `audio_size_addr`… | Size words |
| 0x800–0x17FF | CDF display data |
| 0x0800–0x7FFF | CDFJ+ display data |
| 0x0C00–0x1BFF | DPC+ display data |
| 0x1C00–0x1FFF | DPC+ frequency table |

Nothing is copied or snooped, and there is no writeback.

### 4.3 Flip-flops

| Block | Bits |
|---|---|
| `dfe_slot` | fs 6, ph2 1, cw 3, wbc 1, nq 4, cfn1 1 → **16** |
| `dfe_core` | op 14, fidx 3, fn 4, w1 1, s 6, rb 8, jok 1, hot 1, l2 2, flag 1, `fe_do` 8, dl 8, da 13; DPC+ bank 3, d_ff 1, d_fp 1, rnd 32, pptr 3, wave 21, nvoice 2, nval 8; CDF bank (shared) 0, mode 8, c_fp 1, fexp 13, jr 2, jexp 13, jodd 1 → **≈ 189** |
| `dfe_dp` | W 32, crb_use 1, slane/owner registers ~6 → **≈ 39** |
| `dfe_audio` | acc 24, tk 3, note_p/tb 3, seed_p/tb/stg 4, merge_p/tb 3, post_p 1, aj 5, as 20, av 2, ai 3, dig 1, pld 1, sld 1, accq 2, ofs 15, sh 5, ssum 8, amp 8, nib 1, slane 2, smp_req 1, smp_addr 19, ack_s 3 → **≈ 135** |
| `dfe_copy` | src0 17, dst0 13, cnt0 8, val 8, fill 1, fill2 1, svc2_p 1, ci 8, cbyte 8, csl 2, cp state 3, svc_busy 1, dma_busy 1, drel 1; F6: f6_i 13, f6_q 13, f6 phase 4, f6 delay 3, clear index 8, loading 1, f6_wait 1, img_ok 1, latched family 3, rst_q 1 → **≈ 145** |
| `dfe_call` | call_tog 1, ret_s 2, ret_seen 1, mdet 1, call_busy 1, call2_p 1, follow 1, inflight 1, post_rdy 1, rel_req 1 → **12** |
| `dfe_guard` | ph_at 1 (`clk_arm`), ph_st 1, ph_st1 1, ph 2, lk 3 → **8** |
| **Total** | **≈ 545 FF** |

---

## 5. Audio engine (`dfe_audio`)

### 5.1 Tick generator: exact upstream constants and reset (`arm_mapper_audio.sv:8-9, 57, 76, 163-199`)

```
TH = 24'd14_298_182 (0xDA2C46)
tick = acc >= TH                                  // comb
acc  : ld = 1;  d = cart_reset ? 0 : tick ? acc - TH : acc + 24'd20000
```

- `acc - TH` equals `acc + 20000 - 14318182` mod 2²⁴.
- `CLK_RATE` stays NTSC in PAL, as upstream does.
- The first tick is at R+716, where R is the last edge with `cart_reset` high. Ticks then come every 716 or 715 clocks.
- Ticks fall on the same edges as upstream's because `cart_reset` = `effective_reset` (T1).
- Ticks run during pause, during calls, during copies and before the lock. They need no `family` to step.

### 5.2 Events and the pending-tick count

```
ts  = (as == IDLE) & pick_tick                    // a tick job starts at the edge ending this clock
tk   (3): rst->0 ; d = sat7(tk + tick - ts)  ; tk==7 & tick -> tk_sat_cnt++
// each event: p (pending), tb (ticks ahead, 2 bits)
note : enq at edge C+4 (nq[3]); tb <- tk - ts + tick      (a tick AT N precedes the NOTE: old frequency)
seed : enq at edge C+1 (cfn1)  ; tb <- tk - ts            (a tick AT L follows: excluded from the seed)
       or at edge M with call2_p (RMW) ; tb <- tk - ts ; stg <- cdf
merge: enq at edge M (mdet, CDF only); tb <- tk - ts + tick   (a tick AT M is applied with old values, then merged)
on ts: every pending tb != 0 decrements
on job start of that event: p <- 0
on enqueue while p already set: note -> note_ovr_cnt++ (overwrite); seed/merge cannot overlap (one call in flight)
```

**Job picker** (when `as == IDLE`, `fe_on`, `!cart_reset`):

```
pick_note  = note_p & note_tb==0 & dpc
pick_seed  = seed_p & seed_tb==0
pick_merge = merge_p & merge_tb==0
pick_post  = post_p & !merge_p & !aj.MERGE
pick_tick  = tk != 0
priority note > seed > merge > post > tick
```

**Same-edge ordering.** SEED, then TICK, then NOTE and MERGE. This is upstream's non-blocking order:

- seeds and payload take pre-edge counters (`arm_mapper_audio.sv:207-211`);
- a tick at a NOTE or merge edge adds the *old* frequency;
- the merge overrides a changed counter (`arm_mapper_audio.sv:191-223`).

The `tb` values above encode that order. In the RMW case, SEED (tb = tk−ts) never trails MERGE (tb = tk−ts+tick).

### 5.3 Why the counters, seeds and NOTEs are exact

**Seeds.** The SEED job copies C0–C2 and L0–L2 after exactly the ticks with T ≤ C have been applied, and before any later tick (D1). So F2–F7 equal upstream's payload at L = C+1, and `seed_race` = 0.

**NOTE.** Upstream writes the frequency at edge N_up ≥ C+4: `note_pending` at C+1, NOTE_ISSUE at C+2, the grant at C+3 (the NOTE write cycle has no select), and the write at C+4 (`bench.md` 2, rows E8-E10).

- **N_up = C+4 unless upstream's engine is busy at C+2.** It is busy only with a refresh dispatched by a tick T_p ≤ C. That refresh ends within the refresh length plus the 6507's select windows, a few tens of clocks.
- **So a later tick cannot fall in (C+4, N_up].** The next tick is at least 715 clocks after T_p.
- **What DARIA does.** It applies the NOTE at the logical edge C+4: ticks with T ≤ C+4 use the old frequency and later ones the new.
- **When `note_race` can still occur:**
  - a pause with a frozen select delaying upstream's NOTE by more than a tick period;
  - a NOTE committed while DARIA's previous one is still pending (`note_ovr`, which needs an RMW on $1075-77).

  Both are counted.

**Merge.** DARIA's synchroniser uses the same two flops as upstream's `complete_sync1/2` on the same input in mode A (1.4). So DARIA's X equals upstream's X (`arm_mapper_controller.sv:163-176`), and M = X+1 is upstream's merge edge.

- Ticks ≤ M are applied with the old frequencies before the merge; later ticks after it.
- `merge_race` is 0 except when the bench has to hold `ret_tog` back because DARIA had not yet posted that call. That needs a call shorter than about 30 clocks.
- In mode B and on hardware, M is DARIA's own edge, which is the intended design.

**Physical timing does not matter** to any of these values. Event jobs only read words that no one changes before the job runs:

- the returns stay until the next call;
- the seeds stay until the next post, which waits for this merge;
- the NOTE table word cannot change between C and the job (5.6).

### 5.4 Job micro-programs

The sequencer state:

- `as`: one-hot step;
- `aj`: one-hot job (TICK, NOTE, SEED, MERGE, POST);
- `av`: voice;
- `ai`: copy index.

Step requirements in the table are in addition to owning the named ports (3.1). "→B1" means abort to that block's first step.

| Step | Port use (this clock) | Grant also needs | On grant | On no grant |
|---|---|---|---|---|
| PTR | crb R `wpw + av` (`wpw` = CDF0 0x1FC, else 0x06C) | `bissue` if guard | `pld←1`; `→ SIZ` if `audio_size_addr!=0` else `sh←27; → B1` | wait |
| SIZ | crb R `audio_size_addr[15:2] + av` (13-bit wrap) | `bissue` if guard | `sld←1; → B1` | wait |
| B1 | stb R `0x18+av` | guard & sample: `ph==1` | `→ B2` | wait |
| B2 | stb R `0x1C+av` | `!fe_w` | `W←stb_q` (counter); `→ B3` | → B1 |
| B3 | stb W `0x18+av` ← `sum` (B = `stb_q`, the frequency); if `smp`: crb R `saddr[14:2]` | `!fe_w`; if `smp` crb owned (+`bissue` if guard) | `accq←{1,av==2}` and `slane←saddr[1:0]` if `smp`; next voice or `→ D0` (digital) or done | → B1 |
| D0 | crb R `wpw` (voice 0) | `bissue` if guard | `→ D1` | wait |
| D1 | stb R `0x18` | `!fe_w` | `W←crb_q` (pointer word); `→ D2` | → D0 |
| D2 | — | `!fe_w` | `W←sum` (B = `stb_q>>(plus?13:21)`); `nib←stb_q[plus?12:20]`; `→ D3` | → D0 |
| D3 | route on W (5.6): fea R / crb R / request / none | port owned (+`bissue` for crb if guard); request needs `!smp_pend` | `→ DW` (or done with `amp←0`) | → D0 |
| DW | — | — | FER/RAM: `amp←nibble(byte)`, done. Request: wait for the answer, then `amp←nibble(smp_data)`, done | — |
| N1 | crb R `0x700 + nval` | `bissue` if guard | `→ N2` | wait |
| N2 | stb W `0x1C+nvoice` ← `crb_q` | — | done | → N1 |
| CR | stb R `src(ai)` | — | `→ CW` | wait |
| CW | stb W `dst(ai)` ← `stb_q` | — | last ? exit : `ai++; → CR` | → CR |
| M1 | stb R `0xF8+av` | — | `→ M2` | wait |
| M2 | stb R `0xF2+av` | `!fe_w` | `W←stb_q` (return); `→ M3` | → M1 |
| M3 | if `W != stb_q`: stb W `0x18+av` ← `sum` (B = 0) | `!fe_w` | `av==2` ? (`ai←0; → CR`, frequency copies) : `av++; → M1` | → M1 (only if a write was needed) |
| PF0 | stb W `0xF0` ← `entry` | — | `→ PF1` | wait |
| PF1 | stb W `0xF1` ← `stack` | — | `post_rdy←1`; done | wait |

**Jobs.**

| Job | Program |
|---|---|
| TICK, DPC+ | B1 B2 B3 for each voice (`smp` = 1; DPC+ sample address) |
| TICK, CDF, `!dig` | PTR (SIZ) B1 B2 B3 for each voice (`smp` = 1) |
| TICK, CDF, `dig` | B1 B2 B3 for each voice with `smp` = 0, then D0…DW |
| NOTE | N1 N2 |
| SEED | CR/CW for i = 0..5 |
| MERGE | M1–M3 for voices 0..2, then CR/CW for i = 0..2 |
| POST | CR/CW for i = 0..5 (only if staged), then PF0 PF1 |

`dig` is latched at TICK start as `cdf & mode[7:4]==0`. `entry` and `stack` (`mapper_cdf.sv:159-162`, `mapper_dpcplus.sv:184-186`):

| Scheme | `entry` (F0) | `stack` (F1) |
|---|---|---|
| DPC+ | 0x0C09 | 0x40001FFC |
| CDF, CDFJ | 0x0809 | 0x40001FFC |
| CDFJ+ | `cdfj_entry \| 1` | `cdfj_stack` |

**Copy generators** (8-bit adds):

| Job | `src(ai)` | `dst(ai)` | Last `ai` |
|---|---|---|---|
| SEED | `0x18 + ai + (ai≥3)` | `stg ? 0x20+ai : 0xF2+ai` | 5 |
| POST | `0x20 + ai` | `0xF2 + ai` | 5 |
| MERGE (frequencies) | `0xFB + ai` | `0x1C + ai` | 2 |

**Done actions.**

| Job | When done |
|---|---|
| SEED | `post_p←1` |
| MERGE | `merge_done` strobe (6.2) |
| POST | `post_rdy←1` (6.1) |
| TICK | `tick_done` strobe; `tick_seq++` |

**Delayed register loads.** These are not steps, and they need no port.

```
pld : ofs <= plus ? ((crb_q[31:15]==17'h08000 & |crb_q[14:11]) ? crb_q[14:0]-15'h800 : 0)
                 : {3'b0, crb_q[11:0]-12'h800}                      // AUD:274-292 (BUS row omitted)
sld : sh  <= crb_q[11:7]                                              // AUD:308
accq: byte = pause ? 8'hFF : crb_q[8*slane +: 8]
      ssum <= first ? byte : ssum + byte ;  if last: amp <= ssum + byte    // 8-bit, AUD:317-327
```

### 5.5 Sample addressing (combinational in B3)

The voice add happens in B3: `sum = W + stb_q`, where W is c_v and `stb_q` is f_v. So `sum` is the counter after this tick. It equals upstream's dispatch snapshot (D = T+1, after the tick, `arm_mapper_audio.sv:229-233`).

```
idx    = sum >> (dpc ? 27 : sh)                      // 32-bit logical shift; keep [14:0]
t      = ofs + idx[14:0]                              // 15-bit
saddr  = dpc  ? 15'h0C00 + {3'b0, wave[av], idx[4:0]} // 0xC00 + 32*wave + c[31:27], AUD:143-146
       : plus ? (15'h0800 + t) & 15'h7FFF             // mask = ram_size-1 = 0x7FFF, AUD:147-149
       :         15'h0800 + {3'b0, t[11:0]}           // AUD:150-151
```

`wave[av]` is the live DPC+ register, read in B3. Upstream reads it at its grant edge; a WAVEFORM commit between the two is `amp_input_race`.

### 5.6 Digital mode (CDF, `mode[7:4]==0`; `arm_mapper_audio.sv:264-273, 335-361`)

- All three counters are stepped first (blocks without a sample).
- Voice 0's pointer word is read in D0.
- The digital address is formed in W: `W = ptr + (C0_new >> 21)`, or `>> 13` for CDFJ+.
- `nib` is `C0_new[20]` (CDFJ+ `[12]`).

D3 routes on W, first match:

| Condition | Action |
|---|---|
| `W[31:20]==0 & W[19:0] < rom_size` and `W[19:15]==0` | FER A R `W[14:2]`, `slane←W[1:0]` |
| `W < rom_size`, at or above 32 KB | `smp_addr←W[18:0]`, `smp_req ^= 1` (`smp_pend = smp_req != ack_s2`) |
| `W[31:16]==16'h4000 & (ram32 ? !W[15] : W[15:13]==0)` | crb R `W[14:2]` (+`bissue` if guard) |
| else | `amp←0`, done |

- The nibble is `amp ← {4'b0, nib ? byte[3:0] : byte[7:4]}`.
- A RAM byte reads `FF` while `pause`. ROM bytes are real data in pause too, as upstream.
- The NOTE table word (`0x700+nval`) cannot change between the commit and N1: the 6507 cannot write `0x1C00+` (DPC+ writes stop at 0x1BFF), and the ARM runs only after the post, which waits for the NOTE. So the NOTE value is exact.

### 5.7 AMPLITUDE timing and the lag classes

The `amp` register (8 FF) is written in three places:

| Source | Value |
|---|---|
| `accq` last voice | `ssum + byte` |
| DW | nibble |
| D3 out of range | 0 |

`amp_fwd = amp_we ? amp_new : amp`, and it feeds `fe_do` (2.3). Reset is 0.

**Typical latency from the tick T to the write.**

| Path | DARIA, no front-end claims | DARIA, typical 6507 traffic | Upstream (`audio.md` 7.2) |
|---|---|---|---|
| DPC+ | T+11 (3 blocks + 1) | T+12 … T+36 | T+7 |
| CDF, no size words | T+14 | T+16 … T+40 | T+13 |
| CDF, size words | T+17 | T+20 … T+45 | T+19 |

- Upstream's figures are plus its own grant blocking.
- The lag is about 0–30 clocks per tick. At 715 clocks per tick, `amp_lag` should affect roughly 1–4% of AMPLITUDE reads. This is an estimate; it has not been run.
- The value for each tick is exact, except for the classes in section 9: `amp_input_race`, `tbl_alias`, `merge_race`, the pause classes and `amp_7800`.

### 5.8 Pause (D9)

The sequencer keeps running and ticks continue. While `pause` is high, the sample bytes are `FF`. This gives AMPLITUDE = 0xFD for DPC+ and non-digital CDF, and nibble F for digital RAM samples. Pointer, size and NOTE words are real (`audio.md` 12.5).

Three pause effects are counted, not reproduced:

| Class | Upstream behaviour |
|---|---|
| `pause_starve` | A frozen selecting 6507 cycle blocks every grant for the whole pause |
| `pause_lane` | A stale byte lane at the release |
| `pause_coalesce` | Coalesced refreshes |

### 5.9 The digital-sample request port (D8)

**Protocol.**

1. `daria_fe` issues only if `smp_req == ack_s2` (the previous request was answered). It holds `smp_addr[18:0]` (a byte offset into the image) and flips `smp_req` on the same edge.
2. The wrapper, on `clk_arm`, passes `smp_req` through two flops. On a change it reads the image byte at that offset through `bup_asset_cache`'s PSRAM path (a requester between CPU cache reads, `DARIA_CORE.md` 3.2). It places the byte on `smp_data` (held) and then flips `smp_ack`.
3. `daria_fe` takes `smp_data` when `ack_s2 == smp_req` again. `ack_s` is three `clk_sys` flops; the third is the "previous" copy.

The held bus sits under the existing ±20 ns `clk_sys`/`clk_arm` exceptions.

**Reset.** A reset abandons the job. The wrapper still answers, and the toggle pairing absorbs it.

**Bench.** `bench.md` 7.4.5, with `+fe_slat`.

---

## 6. Call side (`dfe_call`)

### 6.1 Commit → seeds → post → `call_tog`

```
call_busy : rst->0 | commit&callfn&!call_busy -> 1 | rel_go -> 0
call2_p   : rst->0 | commit&callfn&call_busy&!call2_p -> 1 | mdet -> 0          (one-deep, critic 18)
cfn1 -> SEED event at C+1 (5.2)
post_rdy  : set by POST done ; cleared at the flip
call_tog  : ld = post_rdy & call_ready & !cart_reset ; d = ~call_tog           (D5)
inflight  : set at the flip ; cleared at ret_det & !cart_reset
```

- The SEED job (normal case, `stg` = 0) writes F2–F7.
- POST writes F0 and F1. Every call-block write therefore lands before the flip, and `daria_call` reads F0 at A3, which is at least two `clk_arm` later (`design_inputs.md` 2.3).
- In the Pocket, `call_ready` = `daria_ready` (`bupchip_pocket.sv:371-377`).
- `call_busy` rises at C. That is inside the window [E6, E17] in which the bus is identical (`glue.md` 7.5).

### 6.2 `ret_tog` → returns → merge → release

```
ret_s   (2): d = {ret_s[0], ret_tog}                         // the two clk_sys flops (D5)
ret_det     = ret_s[1] != ret_seen                            // comb
ret_seen    : cart_reset -> ret_s[1] | ret_det -> ret_s[1]
mdet        : d = ret_det & inflight & !cart_reset           // high in (X, X+1): events enqueue at M = X+1
follow      : ld = mdet ; d = call2_p
done_ev     = cdf ? aud.merge_done : mdet                    // DPC+ has no merge (family 1, AUD:207,213)
rel_req     : rst->0 | done_ev & !follow -> 1 | rel_go -> 0
rel_go      = rel_req & ph2 & !pclk1                          // clears call_busy at an edge in [C'+1, E0'-1]
```

**Why `rel_go` is safe.**

- `ph2` is high from the `pclk0` edge C' up to the next `pclk1` edge E0'.
- Excluding the clock in which `pclk1` is high keeps the fall off E0'.
- So `arm_call_busy` falls only at edges in [C'+1, E0'−1]: after the held cycle's hidden `pclk0`, and before the next E0 samples RDY.
- The duplicate commit therefore cannot happen (`bus.md` B26). The 6507 resumes at the same E0 as with any other release.

**RMW CALLFN** (both writes FE/FF, critic 18):

1. The second write commits during call 1, so `call2_p` is set.
2. At M, `mdet` enqueues SEED2 (staged) and MERGE1 (CDF).
3. SEED2 copies the pre-merge counters and frequencies into S0–S5. MERGE1 then compares against call 1's seeds, still in F2–F4.
4. POST2 copies S0–S5 to F2–F7, writes F0/F1, and flips.

`call_busy` stays high through both calls. Upstream's one-clock stall dip is counted as `rmw_call`.

### 6.3 Reset rules (D5)

On `cart_reset`, every clock:

| Register | Value |
|---|---|
| `call_busy`, `call2_p`, `rel_req`, `post_rdy`, `inflight`, `follow` | 0 |
| all audio events, `aj`/`as` | idle |
| `ret_seen` | `ret_s[1]` |
| `call_tog` | kept (`daria_call.sv:29-32`) |

### 6.4 State RAM ordering (both ports)

| Port | What it touches |
|---|---|
| Port A (`daria_call`) | Reads F0 every idle `clk_arm`; reads F1–F7 at A18–A26; writes F8–FD at R2–R7 |
| Port B (`daria_fe`) | During a call, writes only C0–C2 (tick jobs) and, if RMW, S0–S5. It reads F8–FD only after `ret_det`, and writes F0–F7 only before the flip |

No word is written on one port while the other reads it.

### 6.5 Mode-A hooks

| Hook | Section |
|---|---|
| `call_ready` | 1.4 |
| `ret_tog` per call number | 1.4 |
| `+fe_merge_hook` (R9) | Not needed: with M = X+1 by construction, it is equivalent to the default emulation. If wanted, the bench forces `call.mdet` at upstream's X+1 and deposits F8–FD |

The busy outputs drive nothing in mode A. The bench records their offsets against upstream's (`busy_off` histogram).

---

## 7. F6, state-RAM clear, copy/fill, `init_busy`, `arm_dma_busy` (`dfe_copy`)

### 7.1 `init_busy` and the F6 triggers (D6)

```
loading : load_start -> 1 ; load_end_q (edge after load_end) -> 0
img_ok  : load_start -> 0 ; load_end_q -> (scheme in {21,23})      // also latch f6_dpc, f6_cdf, f6_32 (= ram32)
f6_wait : load_end_q & scheme in {21,23} -> 1 ; cap_close -> 0 (and f6_run <- 1)
rst_q   : d = cart_reset
f6_dly  : (cart_reset & !rst_q & img_ok & !loading & !f6_wait & !f6_run) -> count 8 -> f6_run <- 1   // critic 17
f6_run  : -> 0 at the last word (7.2)
init_busy = loading | f6_wait | f6_dly | f6_run       (registered OR of the four)
```

- **Never on a falling reset.** The console reset stays high through F6, because `init_busy` is ORed into it, so no second rising edge can occur.
- **`load_start` during F6** aborts it: `f6_*` ← 0, `loading` ← 1.
- **Non-ARM images** keep their start time: `init_busy` falls at `load_end`+1, inside the reset that `cart_download | old_cart_download` already holds.
- **The F6 family is latched at `load_end`**, as upstream's (`arm_mapper_ram_init.sv:212-217`).

### 7.2 F6 and the state-RAM clear (own enable: every port, one word per clock)

| Family | Phase 1 | Phase 2 | Words written |
|---|---|---|---|
| DPC+ | crb W 0x000–0x2FF ← 0 | FER A R 0x1B00+j → crb W 0x300+j (j < 0x500) | 2,048 (+1 pipe) |
| CDF/CDFJ (8 KB) | FER A R j → crb W j (j < 0x200) | crb W 0x200–0x7FF ← 0 | 2,048 |
| CDFJ+ (32 KB) | as above | crb W 0x200–0x1FFF ← 0 | 8,192 |
| all | stb W 0x00–0xEF ← 0 in parallel with phase 1 (240 clocks) | | |

- **Pipeline.** `f6_i` addresses FER A. `f6_q` (`f6_i` one clock later) addresses the crb write, with data `fea_q`.
- **Cost.** About 0.14 ms (2 K words) or 0.57 ms (CDFJ+).
- **Durations differ from upstream's DMA** (5,257, 3,473 and 9,621 clocks; `glue.md` 4.2). The bench's sticky OR hold absorbs the difference (`bench.md` 7.4.2).
- **Contents** match `arm_mapper_ram_init.sv:141-174`. No preload is needed: the tables are in RAM.
- **The audio engine and the front end are in reset** during F6, because `cart_reset` is high.
- **No 29 KB relocation.** A 29,696-byte DPC+ image copies stale FER words above the file, as upstream copies stale DDR (counted as `dpc29k`; critic 25).

### 7.3 DPC+ copy/fill service (D7)

The registers are latched in cw2 and cw3 (2.4):

| Register | Bits | Value |
|---|---|---|
| `src0` | 17 | `0xC00 + {p1,p0}` |
| `dst0` | 13 | `0xC00 + ctr[p2&7]` |
| `cnt0` | 8 | p3 |
| `val` | 8 | p0 |
| `fill` | 1 | |

```
cur_src = src0 + ci ;  cur_dst = dst0 + ci                        // 17- and 13-bit adders
stop    = (ci == cnt0) | (cur_dst == 13'h1C00) | (!fill & |cur_src[16:15])
                                                   // = upstream's min(p3, 0x1000-ctr, 0x7400-off) and 0 if off>=0x7400
CP_RD  (copy, !stop): fea R cur_src[14:2]; csl <- cur_src[1:0]      (fea owned; audio has priority)
CP_WT  : cbyte <- fea_q[8*csl +: 8]
CP_WR  (!stop): crb W byte cur_dst <- {4{fill ? val : cbyte}}, be 1<<cur_dst[1:0]
         (crb owned, i.e. no front-end claim and no audio crb request; never under guard); ci <- ci+1
stop   : svc2_p ? {fill<-fill2; ci<-0; svc2_p<-0} : {cp_run<-0; svc_busy<-0; drel<-1}
dma_busy : set at svc_take ; cleared at drel & ph2 & !pclk1 (same rule as call_busy, D3) ; forced 0 while init_busy
```

- **The counter does not advance.** That matches the quirk.
- **A count of 0 is honoured.** `dma_busy` still rises for the 3–4 clocks the start takes.
- **The audio thread keeps its slots.** It wins crb and FER A; the copy engine takes the remaining clocks, about one byte every 2–3 clocks while the 6507 is held. 255 bytes take about 50–70 6507 cycles.
- **RMW service.** Two services both in {1, 2} are reachable (`bus.md` B28). They reuse `src0`/`dst0`/`cnt0`/`val` with the second `fill`, because the params and counter are unchanged. Upstream's stall dip is counted as `rmw_svc`.
- **A console reset during a copy** aborts it. F6 then rewrites 0x0C00 and up, as upstream's DMA2 does.

---

## 8. Phase detector, guard, SDC (`dfe_guard`)

### 8.1 RTL

```
// clk_arm: the only clk_arm flop in daria_fe
always_ff @(posedge clk_arm) ph_at <= ~ph_at;
// clk_sys
always_ff @(posedge clk_sys) begin
  ph_st  <= ph_at;                       // the detector path, constrained in 8.2; NOT a synchroniser
  ph_st1 <= ph_st;
  if ((ph == 2'd0) == chg) begin ph <= 2'd1; lk <= 3'd0; end      // mismatch: re-anchor
  else begin ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1; lk <= (lk == 3'd6) ? 3'd6 : lk + 3'd1; end
end
wire chg    = ph_st ^ ph_st1;            // in clock (En, En+1): did the sampled toggle change at En?
wire locked = lk == 3'd6;                // six consecutive correct predictions = two frames
wire bissue = locked & (ph == 2'd0);     // this clock follows a shared edge; an address issued now
                                         // is registered at the next edge = phase B
guard.active = locked & ( call.inflight | aud.merge_p | aud.aj.MERGE | call.rel_req
                        | (!call_ready & !init_busy) )
```

**At ÷48 / ÷18.**

- `ph_st` samples 3, 3 and 2 toggles at the three edges of a 144-VCO frame (`design_inputs.md` 9.3).
- So `chg` is 0 exactly at the shared edge and 1 at the other two.
- After a mismatch, `ph` is set to 1. The next shared edge then finds `ph` == 0 and the flywheel locks.
- Lock takes at most 3 + 6 = 9 clocks after any phase move, including PLL relocks.

**Inert cases.**

| Configuration | What the detector sees | Result |
|---|---|---|
| Mode A (5× clock, every edge shared) | `chg` = 1 always | Never locks |
| ÷19 (no exact coincidence) | Changes at 10 of 19 edges, in no period-3 pattern | Never locks |
| The old bench phase (4.365 ns offset) | A 3/3/2 pattern; it locks onto a non-existent shared edge | Harmless: it only restricts read clocks. Run the detector check only with aligned `+d_ofs` |

### 8.2 The two SDC lines

```
set_max_delay -from [get_registers {*daria_fe*|dfe_guard*|ph_at}] -to [get_registers {*daria_fe*|dfe_guard*|ph_st}] 6.0
set_min_delay -from [get_registers {*daria_fe*|dfe_guard*|ph_at}] -to [get_registers {*daria_fe*|dfe_guard*|ph_st}] 1.0
```

- They are more specific than the clock-level ±20 ns pair (`DARIA_CORE.md` 7.3), so they win.
- With a maximum of 6 ns, the toggle launched 8.73 ns before an edge is always caught there.
- With a minimum of 1 ns, the toggle launched on the shared edge is never caught on that edge. TimeQuest includes the clock-network skew.
- `ph_st` gets `SYNCHRONIZER_IDENTIFICATION OFF` in `ap_core.qsf`, because its timing is guaranteed by the constraint.

### 8.3 Lock and unlock

- Any mismatch unlocks at once (`lk` ← 0).
- While unlocked, the guard is inert: `guard.active` = 0. This is the mode-A and ÷19 behaviour (critic 35).
- An unlock while DARIA's CPU is active removes the protection for at most 9 clocks. Count it as `det_unlock_active`; it is expected to be 0 on the device.

### 8.4 Why `guard.active` never blocks a needed write

While a call is in flight, the 6507 is held at F (`glue.md` 7.5):

- its only visible commits are F, the release-window duplicate and the RMW second CALLFN write;
- none of them writes cart RAM (`bus.md` 8.3);
- copy/fill and calls cannot overlap (`bus.md` B28);
- F6 runs only while `init_busy`, which the `!init_busy` term exempts.

`!call_ready` also covers DARIA halts. A halted call holds the 6507 anyway.

### 8.5 Bench check (mode B, `daria_shadow.svh` with `logic clk_d = 1'b1` and `+d_ofs ∈ {0, 8730, 17460}`)

| Check | Rule | Expected |
|---|---|---|
| Truth | At every `clk_sys` posedge E: `shared(E) = (($time - d_ofs) % 26190) == 0` | — |
| `det_bad` | After `locked`, `(u_fe.guard.ph == 0)` in the clock after E must equal `shared(E)` | 0 |
| Lock time | `locked` within 16 `clk_sys` of the first edge | — |
| `coll_d_same` | `bench.md` 6.4, with `fe_rt` fed from `dp.crb_use` | 0 |
| Consumed `daria_fe` reads registered on a shared edge while `guard.active` | — | 0 |
| `coll_d_ld_same` | — | 0 |
| `guard_wr_cnt`, `guard_sub_cnt` | — | 0 |

---

## 9. Upstream quirks and counted differences

### 9.1 Quirks and how this design reproduces each

**DPC+ (`dpcplus.md` §14):**

| Items | Quirk | How |
|---|---|---|
| 1, 2 | Commit only on `access` and A12; the latch and the commit share E6 | Commit = `access & a_in[12]` (2.1); the CPU sees `fe_do` from before C |
| 3 | RANDOM0NEXT/PRIOR return the stepped low byte; bytes 1–3 unstepped | `d1`, 2.3; `rnd` at C |
| 4, 5 | $006/$007/$024-$027 read 00; DFxFLAG only on $020-$023 | `rbyte` → 0; `flg8` needs `fidx<4` |
| 6 | 8-bit modular window from the pre-increment counter; DATAW = data AND flag | `win(w0)` in s2 from the pre-commit word |
| 7 | 12- and 20-bit wraps | Byte-lane writes 0011/0111; the spare nibble is masked |
| 8 | FRACLOW keeps or clears by revision; FRACHI `d[3:0]`; FRACINC clears `frac[7:0]`; LOW and HI | Field `be`/data (2.4) |
| 9, 10 | PUSH at counter−1 and WRITE at counter; one logical RAM write | cw3 byte write. Upstream writes the same byte at E2–E6; the result at E12 is identical |
| 11 | Fast fetch arms on any committed $A9 read and is consumed by the next cart read with a byte < $28 | `d_fp` rules 2.5; s1 decode |
| 12 | 6-bit register space | `dp_reg = rom_b[5:0]` |
| 13 | Hotspots on reads and writes, old bank's byte, suppressed only by a fast-fetch operand | `hot & !rreg(cop)` |
| 14 | `d_out` falls back to the ROM byte after E6 | Not reproduced: `fe_do` holds the byte (`drift_fe`). The transient part is MiSTer-only (critic 28) |
| 15 | FASTFETCH = (d == 0) | ✓ |
| 16 | PARAMETER pointer saturates; reset by CALLFUNCTION 0 and a taken 1/2 | `pptr` saturates at 4 (the bench compares `min(…, 4)`) |
| 17 | 1/2 ignored while a service is pending; FE/FF while a call is pending | `svc_busy` and `call_busy` gates, with the one-deep RMW queues `svc2_p`/`call2_p` that upstream's pending flags imply |
| 18, 19 | Clamps; stream index `params[2]&7`; source 0xC00+off; destination 0xC00+counter; value p0 also on a copy; count 0 still runs | 7.3 |
| 20 | The stall rises at E7 | DARIA's rises at C. The bus is identical (`glue.md` 7.5) |
| 21 | Waveform 7 bits; NOTE voice `a[1:0]−1` | ✓ |
| 22 | Reset values; reset on a mapper change | `fe_on` gating plus F6 clear |
| 23 | `ram_sel` windows starve upstream's audio | Not reproduced: this is the source of `amp_lag` |
| 24, 25 | S1–S5 come from top.sv; held repeats re-present the previous address | Inherited through `access`, `a_in` and `rw` |
| 26 | ROM path | The target is tb_daria's 1-clock ROM; FER refetches after a bank switch, as the target does |

**CDF (`cdf.md` §17):**

| Item | How |
|---|---|
| Q3 | Byte-based arming that survives A12=0 and write cycles: arming only on cart read commits |
| Q4 | Operand rules per version |
| Q5 | `fast_mode` checked only at arming |
| Q6 | Jump step = one byte |
| Q7 | The amplitude stream has no RAM access and clears `fp` |
| Q9 | Substituted reads do not switch banks |
| Q11 | Wrap mod 32 KB. The table-cache hole cannot be reproduced in place: counted `tbl_alias` |
| Q12–Q14 | ✓ |
| Q16 | Single DSWRITE store |
| Q18 | 0x7FFE/0x7FFF never arm: `x7ffe` |
| Q20 | Override inheritance: inputs as detect2600 gives them |
| Q22 | ✓ |
| Q23 | Pause: 5.8 |
| Q25 | top.sv's stall accounting |
| Q26 | Exact for phase 1 ≥ 3. With a 2-clock phase 1 DARIA uses the right stream where upstream may not: `short_phase1` |
| Q1, Q8, Q10, Q24, Q27 | MiSTer `sdram.sv` effects, out of scope (critic 9) |
| Q2, Q15, Q21 | No tables, no writeback (Q2, Q15); `cdf1_count` is detect2600's (Q21) |
| Q17 | CALLFN while not ready: DARIA holds the 6507 instead. Unreachable after a reset (R12); counted `call_notready` |
| Q19 | Entry and stack: detect2600's |

**Audio (`audio.md` §16):**

| Item | How |
|---|---|
| 1 | NTSC `CLK_RATE` in PAL |
| 2, 3 | Coalescing and a tick at the dispatch edge happen only with a refresh delayed by more than a tick: pause classes |
| 4, 5 | NOTE ordering is logical (5.3); overlap is `note_ovr` |
| 6 | Live waveform and mode: `amp_input_race` |
| 7–11 | mod 256; aliasing, windows and masks; size `[11:7]`; nibble rule; out of range → 0: all reproduced (5.4–5.6) |
| 12 | Merge "changed from launch", frequencies always; DPC+ ignores returns |
| 13 | Pause FF bytes |
| 14 | Reset only by `effective_reset` |
| 16 | No call gating |
| 17 | Release window: top.sv's in mode A. DARIA removes it in mode B (`ph2` release) |
| 18 | Launch at M takes pre-merge counters: SEED2 staging |
| 19 | The ARM stops in pause: mode B, counted `pause_call` |

**Glue (`glue.md`):**

- F6 contents ✓; family latched at load ✓; reset re-init on the rising edge only ✓.
- A DMA in flight at a reset: aborted, then rewritten by F6 ✓, the same final image.
- The DMA runs through pause ✓.
- G6: DARIA resets its CPU on a console reset (`reset_in_call`, mode B).

### 9.2 Counted differences (class, condition, expected rate)

| Class | Compare | Condition (the bench evaluates from taps) | Expected |
|---|---|---|---|
| `amp_lag` | L1 | An AMPLITUDE read at latch C. Upstream returns A_up(n) (the last tick whose refresh wrote at or before C−1); DARIA returns A_fe(m). It counts when m ≠ n and the per-tick values agree (A_fe(k) = A_up(k) for k = m, n) | ~1–4 % of AMPLITUDE reads [E] |
| `amp_input_race` | T2 (amp) | Between upstream's and DARIA's sampling of an input of tick n's refresh: a commit of WAVEFORM0-2, SETMODE, DFxWRITE/PUSH/DSWRITE into a byte the refresh read, or a mirror (ARM) write to a word the refresh read | rare; resync |
| `tbl_alias` | C3, K1 | A CDFJ+ DSWRITE with its byte address in [0x098, 0x1B0). That stream is excluded until an ARM write rewrites the word | ~0 |
| `note_race` | T2 | A NOTE commit since tick n and a tick in (C+4, N_up] | 0 except pause |
| `note_ovr` | | A NOTE commit while DARIA's previous NOTE event is still pending | 0 |
| `merge_race` | T2 | A tick in (min(M_up, M_fe), max(M_up, M_fe)] | 0 in mode A unless `ret_tog` was held back |
| `seed_race` | R1 | — | **must be 0** |
| `short_phase1` | L1 | `pclk1`→`pclk0` < 6 `clk_sys` with `access` (`fe_do` only; state exact) | RSYNC only |
| `dout_hidden` | L1 | `pclk0 & !mapper_phi2` | info |
| `drift_fe` / `obus_exposed` | O1 | As `bench.md` | `obus_exposed` 0 |
| `rmw_call`, `rmw_svc` | stall | Upstream's one-clock dip between two RMW calls or services | 0 in games |
| `pause_starve`, `pause_lane`, `pause_coalesce` | T2, L1 | Any tick during a pause or within one tick after it | counted |
| `amp_7800` | T2, L1 | Before the first upstream refresh whose grants all had `tia_en` (use_bios only) | excluded |
| `dpc29k` | I1 | A DPC+ image under 32 KB, bytes above the file in 0x6C00-0x7FFF | data-dependent |
| `size_hi` | T2 | `audio_size_addr ≥ 0x7FF4` (DARIA wraps at 32 KB; upstream reads its 128 KB RAM) | 0 |
| `call_notready` | timing | CALLFN commit while `!call_ready` | 0 |
| `reset_in_call` | mode B | Console reset during a call | — |
| `dig_lat`, `f6_dur`, `svc_dur`, `busy_off` | info | Latencies and durations; absorbed by the holds | histogram |
| Assertions | | `tk_sat`, `guard_wr`, `guard_sub`, `fpjr`, `det_bad` (mode B), `ret_unasked`, `ram_wr_noaccess` (upstream), `over32k`, `wb_drop`, `hold_bad` | **all 0** |

---

## 10. Size and timing

### 10.1 ALM / FF / M10K estimate

The basis is the sketch's measured split under `MUX_RESTRUCTURE OFF`: core 436, shared datapath and arbitration 239, audio 225, copy 104 (`frontend_study/README.md` 4). The adjustments are listed per block.

| Block | FF | ALMs | Basis |
|---|---|---|---|
| `dfe_slot` + claims | 16 | 12–18 | One-hot rings, 4 claim terms |
| `dfe_core` decode and s0–s3 reads, `fe_do` | 60 | 140–170 | The sketch's decode and read data without BUS (≈ −60), plus the s0 +1 word and lookahead window (+15), `x7ffe` (+2), amplitude refresh (+5) and the short-phase `cop` mux (+12) |
| `dfe_core` FF state and commit | 130 | 140–170 | `rnd` 32 with a 4-input mux and next/prior (≈ 45); 2 × 13-bit expected address with compare and increment (≈ 35); DPC+ misc (≈ 30); bank and hotspot (≈ 12); `dl`/`da` plus the 0xC00 adder (≈ 20) |
| `dfe_dp` | 39 | 230–270 | W + adder + 10-way B (the sketch's 239 included the ring); 4-owner address muxes for crb (13 b), stb (8 b), FER A (13 b); 4-source write data on both RAMs; 32-bit equality (M3) |
| `dfe_audio` | 135 | 260–310 | The sketch's 225, plus event bookkeeping (+25), abort and grant logic (+20), copy generators (+12), digital route and request port (+20), CDFJ+ window test (+8); minus the sketch's chooser (−15) |
| `dfe_copy` + F6 + init | 145 | 110–140 | The sketch's 104, plus F6's own word sequencer and clear (+25) and `svc2`/start delay/latches (+10); minus the byte-wide init (−10) |
| `dfe_call` | 12 | 15–25 | Toggles, synchroniser, flags, release gate |
| `dfe_guard` | 8 | 5–8 | |
| **Total** | **≈ 545** | **≈ 910–1,110 (mid ≈ 1,010)** | DARIA_CORE expected 850–1,100 |
| M10K | — | — | **0 new**: FER 32, cart RAM 32 and state RAM 2 are already in the memory system's budget (`DARIA_CORE.md` 1.5) |

**Headroom.**

- Against the 2.1.1 front ends this is about 1,200 ALMs less (2,192 + 716 live); against 2.1.1's 1,752 it is about 740 less.
- If a block overruns, three savings are available without design change:
  - drop the FER A lookahead in favour of a second s1 read: −15;
  - narrow `ssum`/`ofs` to the used bits: −5;
  - merge `src0+ci`/`dst0+ci` into the shared adder during copies: −20, but it would contend with the audio's W.
- Measure each block as it is written (study risk 8).

### 10.2 Critical paths on `clk_sys` (69.84 ns)

Every path is a single-cycle register or M10K q → logic → register or M10K input path. The estimates assume Cyclone V C8, M10K t_co ≈ 4.5 ns, and routing ≈ 30–40% of the total.

| # | Path | Estimate |
|---|---|---|
| 1 | B3: `stb_q` (frequency) → 32-bit adder (W + f) → barrel shift by `sh` (5 levels) → 15-bit add (`ofs`) → mask/mux (DPC+/CDF/CDFJ+) → crb address owner mux → M10K address | ≈ 30–35 ns |
| 2 | s1: `feb_q` → lane mux → `in_rng` (9-bit compare) + `a_in==fexp` (13-bit, from flops) → normalise (8-bit sub) → `pb+s` (9-bit add) → crb mux → M10K | ≈ 25–28 ns |
| 3 | cw3: `crb_q` (increment) → `<<12/<<8` → B mux → 32-bit adder → crb write-data mux → M10K data | ≈ 20–24 ns |
| 4 | Amplitude forward: `crb_q` → lane mux (pause FF) → 8-bit add (`ssum`) → `amp_fwd` mux → `fe_do` mux → `fe_do` D | ≈ 15–18 ns |
| 5 | s2: `crb_q` (pointer) → `disp` (15-bit add) → crb mux → M10K; or `stb_q` → window (2 × 8-bit sub + compare) → `flag` | ≈ 18–20 ns |
| 6 | D3: W → `rom_size` 20-bit compare / `in_ram` → owner selects → crb/FER address | ≈ 20 ns |
| 7 | `access`/`pclk0` (top.sv registers, 2–3 LUTs there) → commit enables on about 150 flops | ≈ 10–15 ns plus fan-out |

- **Worst slack** is ≥ 30 ns.
- **The detector path** (`ph_at` → `ph_st`) is a single reg-to-reg hop within [1, 6] ns. The fitter adds hold delay if it needs to.
- **No path enters or leaves the `clk_sdram` cone.** `fe_do` is a register, and `fe_oe` = `a_in[12]` is the same CPU-register path every mapper already uses.

---

## 11. Risks and first tests

### 11.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | **Background abort/restart scheduling**: an untested pattern of claims (stretched phases, back-to-back write-back cycles, guard B-issue) could starve the audio thread. `tk` saturates and the counters go wrong | `tk_sat` assertion. A unit bench with random phase streams (11.2 #1). The analytic bound is two 3-clock runs per cycle |
| 2 | **Logical ordering (`tb`)**: an off-by-one at the same-edge cases (tick at L, N or M; RMW SEED2/MERGE1) breaks `seed_race` = 0 or the per-tick counters | A dedicated model-based unit test (11.2 #2) that sweeps the tick edge over L−2…L+2, N−2…N+2, M−2…M+2 |
| 3 | **W sharing**: a missed `fe_w` check corrupts a pointer or counter rarely | The proof in 3.2; an assertion that no audio W load coincides with `fe_w`; a random bench |
| 4 | **Device M10K behaviour** that simulation does not show: mixed-port read-during-write (the written word must survive; Intel docs, critic 34e), and NEW_DATA_NO_NBE_READ (q is never consumed after a partial write, by construction) | Confirm in Intel's altsyncram documentation; an X-injecting RAM model in mode B (`design_inputs.md` 9.3) |
| 5 | **Clock skew** at the shared edge, and SDC precedence for the detector pair | Check `report_timing` on `ph_at→ph_st` and `det_bad` in mode B. On ÷19 fallback the guard is inert, and a new rule would be needed (R14) |
| 6 | **ALM overrun** under `MUX_RESTRUCTURE OFF` (the estimate is ±10%) | Per-block probes; the savings list in 10.1 |
| 7 | **`amp_lag` rate** higher than the owner accepts | Counted. An exact sequencer would be architect B's option |
| 8 | **Wrapper additions are untested**: `cap_close` export, the digital-sample requester over PSRAM | Mode A emulates both. Step 7 tests them through `WRAPPER=1` |
| 9 | **Paths no image exercises**: RSYNC, use_bios, pause, DPC+ copy/fill (`dma_events` = 0 in all 21 images), CDF0, digital audio, RMW CALLFN/service | Directed tests (11.2 #4–#6) |
| 10 | **Mode-A ret matching**: if DARIA posts after upstream returns (calls under about 30 clocks), the bench delays `ret_tog`, giving `merge_race` and possibly `ret_unasked` bugs | Histogram of post-to-accept offsets; queue logic in `fe_shadow.svh` |

### 11.2 What to test first

1. **`dfe_slot` + `dfe_dp` + `dfe_audio` sequencer alone** (Verilator, no upstream). Random `pclk1`/`pclk0`/`access` streams: 6/6, 2/6, 6/10, stretched, pauses, held repeats; random `wb` ops, random ticks, random guard lock and `ph`. Check:
   - no port double-owned;
   - no W conflict;
   - every tick job completes within one tick period;
   - no consumed crb read off `bissue` under the guard.
2. **Audio logical-order unit test** against a 60-line behavioural model of `arm_mapper_audio.sv`'s register semantics (ticks, NOTE at C+4, seed at C+1, merge at X+1, RMW). Sweep tick placement around every event edge; require identical counters, frequencies, seeds and per-tick amplitude sequences.
3. **Mode A bring-up**, `bench.md` 7.9 step 0 then step 2: the reference front end first, then `daria_fe` on one DPC+ image (Space Rocks) and one CDFJ image (Robot War), 120 frames. Pass: L1/C1/C2/C3/C4/I1/K1/R1/T1/T2 counts.
4. **Directed DPC+**: every register; fast fetch on data bytes; PUSH/WRITE wraps; FRACLOW on both revisions; copy/fill with each clamp, count 0, and the RMW pair; NOTE with ticks at C+3/C+4/C+5.
5. **Directed CDF**: fetch offset ranges and the amplitude operand; LDX/LDY; jumps at $xFFE/$xFFF and at file 0x7FFE; hotspot JMP; DSWRITE/DSPTR including a CDFJ+ wrap into the tables (`tbl_alias`); digital RAM, ROM < 32K and ROM ≥ 32K (request port); CDF0 layout.
6. **Full set in mode A** (21 images × 1,500 frames), then `+hard_reset_at`, then RSYNC, use_bios and pause directed runs.
7. **Mode B**: the `+d_ofs` sweep for the detector and guard (8.5).
