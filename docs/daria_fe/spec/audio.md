# 2600 ARM audio: cycle-exact behavioural spec of upstream `arm_mapper_audio` and its call hand-off

Target: a clone of upstream's 2600 ARM-cartridge audio engine (DPC+, BUS, CDF,
CDFJ, CDFJ+) that matches upstream at every 6507 latch edge, at every commit
and at every audio tick. It covers upstream as written, quirks included.

Sources, all under `src/fpga/mister/rtl/` (upstream MiSTer Atari7800 rtl,
`../UPSTREAM_COMMIT` = ffc47192a58e4ead08919bd1e4ce984df138fcb2). File:line
references are relative to that directory. Abbreviations:

| Tag | File |
|---|---|
| AUD | `arm_mapper_audio.sv` (366 lines, the engine) |
| CTL | `arm_mapper_controller.sv` (call controller; its audio half) |
| C26 | `cart2600.sv` (instance at 760-801, RAM mux 965-978) |
| TOP | `top.sv` |
| SUB | `arm_mapper_subsystem.sv` |
| MEM | `arm_mapper_memory.sv` (digital-sample ROM path) |
| TDP | `cart_ram_tdp.sv` (the cart RAM) |
| CR | `cache_ram.v` (RAM primitive models) |
| DDR | `ddram.sv` (DDR3 bridge) |
| DET | `detect2600.sv` |
| RI | `arm_mapper_ram_init.sv` |
| DPC / MC / MB | `mapper_dpcplus.sv` / `mapper_cdf.sv` / `mapper_bus.sv` |

Build assumed: `NO_ARM_MAPPER` **not** defined, `EXTERNAL_CARTRAM` **not**
defined (MiSTer). With `NO_ARM_MAPPER` (today's Pocket build) the engine is
not instantiated and `arm_audio_amplitude` is tied to 0 (C26:585-617). With
`EXTERNAL_CARTRAM` the word read path the engine depends on is tied to 0
(TOP:937-942) (see §12.6).

Not read, by rule: anything under `arm7tdmi/` (so the value of the package
constant `STATE_FIQ_R8` is inferred, §10.2) and anything outside this repo.

**Review status (adversarial check, 2026-10-07).** Every cited line in AUD,
CTL, C26 (760-801, 940-978), TOP (230-360, 745-790, 905-942, 1120-1200), TDP,
CR, MEM (sample path), DDR, DET, RI, DPC, MC and MB was re-read. Tags:
**[checked]** = re-read and correct as written; **[corrected: ...]** = was
wrong or imprecise, fixed here; **[added: ...]** = was missing. The main
correction is §10.1/§13.4: a scratch simulation of upstream's own 6502 core
(`6502/mos6502*.sv`, unmodified) with TOP's stall logic shows that during an
ARM call the bus keeps **W+1's** address (the opcode fetch after the CALLFN
store), not W+2's, so **no front-end select can stand during a call** (when
the launch is at E7, as in all normal code) and the engine is never starved
by one (§13.4). Second correction, §12.5: a pause freezes the 6507 with its
selects live, so a frozen selecting cycle blocks every grant for the whole
pause. The tick closed form (§3.3) was re-simulated and holds. A new BUS3
front-end hazard surfaced on the way (§13.4, release window).

---

## 0. Conventions [checked]

### 0.1 Clocks and edges

- `clk_sys` = 14.318182 MHz NTSC (`pll.v:83`; `../../core/atari7800_pocket.sv:10`),
  14.18758 MHz PAL (`../../core/pll_region.v:47`, `../../core/core_top.v:1094`).
  The engine runs on `clk` = TOP `clk_sys` (C26:761, TOP:1131).
- `clk_arm` = exactly 5 x `clk_sys`, same PLL, edge-aligned: every 5th
  `clk_arm` posedge coincides with a `clk_sys` posedge (TDP:29-33;
  MEM:477-481).
- **E0** = the `clk_sys` posedge at which `pclk1` (6507 phase 1, C26 `phi1`,
  TOP:1133) is sampled high. **Ek** = E0 + k `clk_sys` posedges. In 2600 mode
  a 6507 cycle is 12 `clk_sys` long: phase 2 (`pclk0`) at E6, next E0 at E12.
  The 6507 drives AB/RW at E0, latches read data at **E6** (the byte standing
  in (E5,E6)), and samples RDY at E0. The front ends commit at E6
  (`access = mapper_phi2 && lock_ctrl && tia_en`, C26:247, TOP:327,1135-1136).
  These are the conventions of `docs/daria_fe/spec/dpcplus.md` §0 (derivation there:
  TIA.sv:505-506,557; TOP:1420-1435; `6502/mos6502_dp.sv:202,267`).
  [checked: `pclk1`/`pclk0` are one-clk enables (TOP:1420-1427); ABL/ABH load
  only at `phi1_en` (`mos6502_dp.sv:202,225-226`), R/W is retimed to the same
  edge (`mos6502.sv` `wr_pin`), DL at `phi2_en`. A cycle whose control word is
  masked by a hold does **not** load ABL/ABH, which is what §10.1 turns on.]
- **(X, X+1)** = the `clk_sys` period after posedge X. A combinational signal
  "in (X-1, X)" is what posedge X samples. A register "written at X" shows
  its new value from (X, X+1).

### 0.2 Audio notation

- **T** = a tick edge: the posedge at which `audio_tick` is sampled high and
  the counters step (AUD:76, 191-196).
- **D** = the dispatch edge: the posedge at which AUDIO_IDLE starts a refresh
  (AUD:229-240).
- **g_i** = the posedge at which the i-th RAM ISSUE state of a sequence is
  granted (§5.3).
- **A** = the posedge at which `amplitude` is written.
- **L** = the call launch edge (the posedge sampling `call_launch` high);
  **M** = the merge edge (the posedge sampling `call_done` high).

### 0.3 The engine is free-running

Nothing in the engine is referenced to E0. Its only inputs that move with the
6507 are the NOTE strobe, the waveform registers, the digital-mode flags, the
call launch/return, and the front ends' RAM selects that block its grants
(§13). Tick edges are fixed by counting `clk_sys` posedges from reset release
(§3.4).

---

## 1. Wiring (C26:760-801) [checked]

| AUD port | Connected to | Notes |
|---|---|---|
| `clk` | `clk` = TOP `clk_sys` | C26:761, TOP:1131 |
| `reset` | cart2600 `reset` = TOP `effective_reset = reset \| reset_hold` | C26:762, TOP:255,1130. **Not** `reset \|\| mapper != X` (unlike the front ends, C26:805,843,902). Not gated by `pause`. |
| `family[1:0]` | `init_family`: DPC+ = 1, BUS = 2, CDF = 3, else 0 | C26:658-660,763. `mapper` = `\|mapper ? mapper : force_bs` (TOP:1138). |
| `revision[1:0]` | `mapper_revision[1:0]` | C26:764. DPC+ 0/1; BUS 0-3; CDF 0 = CDF0, 1 = CDF1, 2 = CDFJ, 3 = CDFJ+ (DET:218-225, 236-238). |
| `rom_size[31:0]` | TOP `cart_size` | C26:44,765; TOP:1148 |
| `mapper_ram_size[15:0]` | 32768 iff `force_bs == BANKCDF && mapper_revision == 3`, else 8192 | C26:766, TOP:778-783 |
| `audio_size_addr[15:0]` | `arm_audio_size_addr` from DET | C26:40,767; TOP:1146; DET:135,146-161 (§6.2) |
| `bus_digital_audio` | MB `digital_audio = mode[7:4]==0` | C26:768,931; MB:93 |
| `cdf_digital_audio` | MC `digital_audio = mode[7:4]==0` | C26:769,871; MC:80 |
| `dpc_waveform0..2[6:0]` | DPC `waveform[0..2]` | C26:770-772,821-823; DPC:188-190 |
| `dpc_note_write/voice/value` | DPC `audio_note_*` | C26:773-775,824-826; DPC:217-221,311-315 |
| `call_launch` | `arm_call_request` (front-end mux) | C26:776,945-947 |
| `call_done` | CTL `call_done` | C26:777,486; SUB:135 |
| `counterN_return`, `frequencyN_return` | CTL `audio_*_return` | C26:778-783,487-492 |
| `counterN`, `frequencyN` (outputs) | CTL payload inputs `audio_counterN/frequencyN` | C26:784-789,478-483 |
| `ram_en`, `ram_addr[16:0]` | `audio_ram_en`, `audio_ram_addr` → cart RAM port A mux | C26:790-791,965-967 |
| `ram_grant` | `audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel` | C26:792,965 |
| `ram_byte_data` | `cartram_data` = TOP `cartram_data_bram = pause ? 8'hFF : cartram_data_tdp` | C26:793; TOP:936,1155 |
| `ram_word_data` | `cartram_word_data` = TDP `mapper_word_rdata` (not pause-masked) | C26:794; TOP:934,1158; TDP:58 |
| `rom_request/addr/ready/done/data` | `arm_sample_*` ↔ MEM sample port | C26:795-799,468-473; SUB:184-189 |
| `amplitude[7:0]` | `arm_audio_amplitude` → DPC, MC, MB `amplitude` inputs only | C26:800,820,870,930 |

Parameters are not overridden at the instance (C26:760), so `CLK_RATE =
14318182` and `AUDIO_RATE = 20000` (AUD:8-9) on NTSC **and** PAL.

`amplitude` does not reach any mixer: it is only what the 6507 reads (§14).

[checked: every row re-read at the cited lines. Additions:]
- [added] AUD has no `pal`, `pause`, `tia_en`, `lock_ctrl`, `call_busy` or
  `phi` input (AUD:11-56); everything E0-related reaches it only through the
  rows above.
- [added] `revision` is `mapper_revision[1:0]` (C26:764): bit 2 of the 3-bit
  DET revision is dropped (it is always 0 for these families, DET:220-237).
- [added] The PAL `clk_sys` figure is confirmed in-tree on the MiSTer side too:
  MEM:477-481 gives PAL `clk_arm` = 70.937900 MHz = 5 x 14.18758 MHz.
- [added] The front ends that feed `bus_digital_audio`, `cdf_digital_audio`,
  the waveforms and the NOTE strobe are each held in reset unless selected
  (C26:805,843,902), so the unselected ones read 0 (`mode` resets to 0xFF, so
  `digital_audio` = 0, MC:167, MB:180).

---

## 2. State [checked]

All on `posedge clk`, synchronous reset (AUD:163-189).

| Register | Width | Reset | Written at |
|---|---|---|---|
| `tick_accum` | 24 | 0 | every edge (AUD:191-199) |
| `counter0..2` | 32 | 0 | tick (193-195), merge (214-219) |
| `frequency0..2` | 32 | 0 | merge (220-222), NOTE_CAPTURE (249-253) |
| `refresh_pending` | 1 | 0 | tick (196), IDLE dispatch (230) |
| `note_pending`, `note_voice[1:0]`, `note_value[7:0]` | | 0 | strobe (201-205), NOTE_CAPTURE (254-255) |
| `call_seed_counter[0..2]` | 32 | 0 | launch (207-211) |
| `state` | 4 | AUDIO_IDLE | (225-363) |
| `voice[1:0]` | 2 | 0 | dispatch (234), SAMPLE_CAPTURE (328) |
| `refresh_counter[0..2]` | 32 | 0 | dispatch only (231-233) |
| `waveform_pointer` | 32 | 0 | POINTER_CAPTURE (265). **Never read**: dead. |
| `waveform_offset` | 15 | 0 | POINTER_CAPTURE (274-292) |
| `waveform_shift` | 5 | 27 | dispatch (237), POINTER_CAPTURE (294), SIZE_CAPTURE (308), SAMPLE_CAPTURE (329) |
| `sample_sum` | 10 | 0 | dispatch (235), SAMPLE_CAPTURE (327). Only bits [7:0] are ever used (324). |
| `digital_sample` | 1 | 0 | dispatch (236), DIGITAL_ROUTE (342) |
| `digital_low_nibble` | 1 | 0 | POINTER_CAPTURE (270-271) |
| `digital_address` | 32 | 0 | POINTER_CAPTURE (267-269) |
| `digital_ram_addr` | 15 | 0 | DIGITAL_ROUTE (341) |
| `amplitude` | 8 | 0 | SAMPLE_CAPTURE (319-324), DIGITAL_ROUTE (345), ROM_WAIT (358-359) |

Combinational (AUD:99-158): `waveform_base`, `digital_mode`, `jplus_sample`,
`shifted_sample_index`, `selected_dpc_waveform`, `sample_offset_sum`,
`ram_en`, `ram_addr`, `rom_request`, `rom_addr`, `audio_tick`.

Same-edge priority (later non-blocking assignment wins, AUD source order):
- `counterN`: tick `+= frequencyN` (193-195) is overridden by a merge that
  takes the return value (214-219).
- `frequencyN`: merge (220-222) then NOTE_CAPTURE (250-252). They cannot
  coincide: merge needs `family >= 2`, NOTE_CAPTURE needs family 1 (227).
- `refresh_pending`: tick sets it (196); an IDLE dispatch at the same edge
  writes `audio_tick` (230), i.e. 1 on a tick edge, so the tick stays queued.
- `note_pending`: set by the strobe (202); NOTE_CAPTURE clears it only if the
  strobe is low at that edge (254-255).
- [added] `call_seed_counter[N]` vs the merge: launch (207-211) and merge
  (213-223) can be sampled at the **same** edge. `call_launch` needs
  `!call_busy` (CTL:86-87) and `call_busy` is low from (X, X+1) while
  `call_done` is high in the same period, so a CALLFN request that was left
  pending during the previous call launches at M itself. Then (family >= 2):
  the new seeds take the **pre-merge** counters, the merge compares the returns
  against the **old** seeds, and CTL's payload also takes the pre-merge counters
  and frequencies (CTL:149-158). The second call therefore starts from the
  values the first call's return has not yet replaced. Reachable only if a
  second CALLFN write commits during the first call: the RMW case of §10.1
  (`INC`/`DEC` of CALLFN whose old and new values are both $FE/$FF), whose
  second write is W+1 and is shown to the front end (CALLFN's `call_pending`
  was cleared at L, DPC:222-223, MC:179-180, MB:200-201). Replicate it.
- [checked] Same-edge rule for `frequencyN`: merge and NOTE_CAPTURE cannot
  coincide in practice (NOTE_CAPTURE is reached only through an IDLE edge with
  `family == 1`, merges need `family >= 2`; `family` only moves with the mapper
  selection).

---

## 3. The 20 kHz tick [checked]

### 3.1 Constants (AUD:8-9, 57, 76, 191-199)

| Name | Decimal | Hex (24-bit) |
|---|---|---|
| `CLK_RATE` | 14,318,182 | 0xDA7A66 |
| `AUDIO_RATE` | 20,000 | 0x004E20 |
| `TICK_THRESHOLD = CLK_RATE - AUDIO_RATE` | 14,298,182 | 0xDA2C46 |
| step on a tick, `AUDIO_RATE - CLK_RATE` mod 2^24 | -14,298,182 | 0x25D3BA |

### 3.2 Per-edge rule

```
audio_tick = (tick_accum >= 14298182)            // combinational, AUD:76
at each posedge with reset low:
    if audio_tick: tick_accum <= tick_accum - 14298182   // AUD:192 (24-bit, never wraps)
    else:          tick_accum <= tick_accum + 20000      // AUD:198
at each posedge with reset high: tick_accum <= 0        // AUD:164
```

`tick_accum` stays in [0, 14,318,182) < 2^24, and after a tick it is in
[0, 20000), so two consecutive edges never both tick.

### 3.3 Closed form

Number the posedges at which `reset` is sampled low as n = 1, 2, 3, ...
counted from the last posedge at which `reset` was sampled high. Tick j
(j = 1, 2, ...) happens at posedge

```
n_j = ceil(14318182 * j / 20000)
```

So n_1 = 716, n_2 = 1432, ..., n_10 = 7160, n_11 = 7876, n_12 = 8591.
Intervals are 716 clk (10 of every 11, roughly) and 715 clk (1 of 11);
over 200,000 ticks: 181,820 x 716 and 18,180 x 715 (checked by direct
simulation of 3.2 against the closed form). Mean 715.9091 clk = 59.66 6507
cycles. Per tick the phase against E0 advances by 716 mod 12 = 8 or 715 mod
12 = 7 clk.

Rate: 20,000.00 Hz on NTSC `clk_sys`; on PAL `clk_sys` (14.18758 MHz) the
same constants give **19,817.57 Hz** (no PAL override, C26:760).

### 3.4 Origin and gating

- Clock: `clk_sys`. Reset: `effective_reset` (TOP:255) = TOP `reset` |
  `reset_hold`. `reset_hold` powers up 1 (TOP:242) and clears at a posedge sampling
  `pclk1` (normal case) or 3 edges after a `pclk0` (the bypassed-BIOS
  2600 path) (TOP:266-286). The tick phase is therefore set by the reset
  release edge and the clk count since, never by later 6507 activity.
  [added: exact edges. `reset_hold` is a register cleared *at* the release
  edge Z, so AUD still samples `effective_reset` high at Z and n = 1 is Z+1.
  Normal case: Z is the posedge that samples `pclk1` (an E0 of whatever phase
  source runs then, normally MARIA in 7800 mode), with `reset` low and
  `phase_source_stable && phase_valid && !phase_source_tia` (TOP:271-283), so
  tick j is at Z + n_j. Bypassed-BIOS 2600 path (`first_phase_is_phi1`): P =
  the posedge sampling `pclk0` with `reset_phase_wait == 0` loads 3; P+1 -> 2;
  P+2 -> 1; Z = P+3 clears `reset_hold` (TOP:275-280); n = 1 at P+4. The tick
  phase against the *2600-mode* E0 is then fixed by the whole clk count from
  Z, including the BIOS's 7800-mode run before the lock, so a clone must run
  the same BIOS path clk for clk (or release at the same edge relative to the
  first 2600-mode E0).]
- Not gated by: `pause`, `ce`, `tia_en`, `lock_ctrl`, `call_busy`,
  `arm_dma_busy`, `mapper` or `family`. The accumulator and the counter steps
  run for every family, including 0 (AUD:191-199 have no condition).
  Only the refresh request is family-gated: `refresh_pending <= family != 0`
  (AUD:196).

---

## 4. Counters and frequencies [checked]

### 4.1 Tick step (AUD:193-195)

At each tick edge T, simultaneously for N = 0, 1, 2:
`counterN <= counterN + frequencyN`, 32-bit modular, using the pre-edge
values of both (non-blocking). No voice order. Unless overridden by a merge
at the same edge (§10.4).

### 4.2 All writers

| Register | Writer | Where |
|---|---|---|
| `counterN` | tick | §4.1 |
| `counterN` | merge, `family >= 2`, only if `counterN_return != call_seed_counter[N]` | AUD:213-219, §10.4 |
| `frequencyN` | merge, `family >= 2`, unconditional | AUD:220-222 |
| `frequencyN` | NOTE_CAPTURE, family 1, voice `note_voice` | AUD:248-253, §9 |
| all | reset → 0 | AUD:174-179 |

So for BUS/CDF (family 2/3) the frequencies change **only** at merges; for
DPC+ (family 1) **only** at NOTE loads. Counters change only at ticks and (BUS/
CDF) merges.

### 4.3 Ticks during ARM calls

The engine has no call input except `call_launch` and `call_done`. During a
call (and during a DPC+ copy/fill stall) ticks keep stepping the live
counters with the frequencies that stood at launch, and refreshes keep running
and reading cart RAM (§11). See §10.5 for the counter algebra at return.
[checked; corrected: and every one of those in-call reads is granted on its
first ISSUE clk, because no front-end select can stand during a call (§13.4).]

---

## 5. The refresh state machine [checked; additions in 5.3]

### 5.1 States and outputs (AUD:59-72, 129-157, 225-363)

| State | `ram_en` | `ram_addr` (17-bit byte address, when `ram_en`) | Other output | Leaves at the next posedge when |
|---|---|---|---|---|
| IDLE | 0 | 0 | | §5.2 |
| NOTE_ISSUE | 1 | `0x1C00 + 4*note_value` | | `ram_grant` → NOTE_CAPTURE |
| NOTE_CAPTURE | 0 | 0 | | always → IDLE |
| POINTER_ISSUE | 1 | `waveform_base + 4*voice` | | `ram_grant` → POINTER_CAPTURE |
| POINTER_CAPTURE | 0 | 0 | | always → DIGITAL_ROUTE, SIZE_ISSUE or SAMPLE_ISSUE |
| SIZE_ISSUE | 1 | `audio_size_addr + 4*voice` | | `ram_grant` → SIZE_CAPTURE |
| SIZE_CAPTURE | 0 | 0 | | always → SAMPLE_ISSUE |
| SAMPLE_ISSUE | 1 | §6.4-6.6 | | `ram_grant` → SAMPLE_CAPTURE |
| SAMPLE_CAPTURE | 0 | 0 | | always → IDLE, SAMPLE_ISSUE or POINTER_ISSUE |
| DIGITAL_ROUTE | 0 | 0 | | always → ROM_ISSUE, SAMPLE_ISSUE or IDLE |
| ROM_ISSUE | 0 | 0 | `rom_request = rom_ready` | `rom_ready` → ROM_WAIT |
| ROM_WAIT | 0 | 0 | | `rom_done` → IDLE |

`ram_addr` is 0 outside the ISSUE states (AUD:132), so whenever no front end
selects the RAM and the engine is not issuing, the console port reads byte 0
(C26:966-967). `rom_addr = digital_address[24:0]` always (AUD:157).

The 4-bit encoding (AUDIO_IDLE = 0 ... AUDIO_ROM_WAIT = 11) is internal; the
unlisted codes 12-15 fall into the `default` (ROM_WAIT) arm (AUD:355).

### 5.2 IDLE dispatch (AUD:226-241)

At a posedge X with `state == IDLE` in (X-1, X):

1. If `note_pending && family == 1`: → NOTE_ISSUE. (NOTE beats refresh.)
2. Else if `refresh_pending`: dispatch, X = D:
   - `refresh_pending <= audio_tick` (so a tick at D itself stays queued);
   - `refresh_counter[N] <= counterN` (the values in (D-1, D): including any
     tick or merge **before** D, excluding one **at** D);
   - `voice <= 0`, `sample_sum <= 0`, `digital_sample <= 0`,
     `waveform_shift <= 27`;
   - family 1 → SAMPLE_ISSUE; any other family → POINTER_ISSUE.
3. Else stay.

Ticks are **coalesced**: `refresh_pending` is one bit. Any number of ticks
while a refresh (or NOTE) is in progress produce one refresh, dispatched at
the first IDLE edge, using the counters as they stand then. The counters
themselves still step at every tick.

There is no family check at dispatch: a refresh queued while `family != 0`
is dispatched even if `family` later reads 0 (it only changes with the
mapper selection; irrelevant in practice).

### 5.3 The grant rule

In an ISSUE state (NOTE/POINTER/SIZE/SAMPLE), at posedge Y the engine leaves
for the CAPTURE state iff `ram_grant` is high in (Y-1, Y):

```
ram_grant = ram_en && !init_ram_en && !sel_ram_sel        // C26:965
```

- `init_ram_en` = RI table-read states (RI:191-192), only during RAM
  initialisation after a load or after a reset rising edge (RI:204-227).
- `sel_ram_sel` = the selected front end's RAM select (C26:191; DPC:132-158,
  C26:896 `cdf_ram_en`, C26:941 `bus_ram_en`) (§13).
- If an ISSUE state is entered at posedge Y0 (state is ISSUE in (Y0, Y0+1)),
  the earliest grant is g = Y0 + 1. Each clk with the select high adds one.
- At g the cart RAM (port A) registers `cartram_addr = audio_ram_addr`
  (C26:966-967) and the byte lane (TDP:61-64). The CAPTURE state, in
  (g, g+1), sees `ram_word_data` / `ram_byte_data` = the RAM content at that
  address as of posedge g (CR:172-176; TDP:57-58) (§12).
- The ISSUE state's `ram_addr` is combinational on live registers and inputs;
  only its value in (g-1, g) matters.
- [added] The word lanes register their address at **every** clk_sys edge
  (no enable on `addr_a_i`, TDP:73-74), but the byte-lane register
  `mapper_read_lane` updates only when `mapper_en` (TDP:61-64), and outside
  RAM init `mapper_en = !pause` (TOP:921). So `ram_word_data` at g+1 is always
  the word at g's address, while `ram_byte_data` at g+1 is
  `pause in (g, g+1) ? 0xFF : lane L of that word`, where L = `addr[1:0]` of
  the address at the last edge <= g with `pause` low before it. The two differ
  only on a capture that straddles a pause release (`pause` high in (g-1, g),
  low in (g, g+1)): the byte then comes from the **stale** lane. During RAM
  init `mapper_en = cartram_wr || cartram_rd` and `cartram_rd` includes
  `audio_ram_grant` (C26:975), so the lane follows the engine's grants.
- [added] In 2600 mode the RAM sees cart2600's `cartram_addr` only because
  TOP selects `cartram_addr26` when `tia_en || mapper_init_busy`
  (TOP:756-757); before that see §12.6.

### 5.4 Family 1 (DPC+) refresh

```
D:    -> SAMPLE_ISSUE, voice 0
g0 >= D+1   (sample voice 0)  addr = 0x0C00 + 32*dpc_waveform0 + refresh_counter[0][31:27]
g0+1: SAMPLE_CAPTURE: sample_sum += byte; voice 1; shift 27; -> SAMPLE_ISSUE
g1 >= g0+2  (sample voice 1)
g1+1: sample_sum += byte; voice 2 -> SAMPLE_ISSUE
g2 >= g1+2  (sample voice 2)
A = g2+1:   amplitude <= sample_sum[7:0] + byte  (8-bit); -> IDLE
```

(AUD:238-239, 140-146, 317-333.) Minimum: D = T+1, A = **T+7**.

### 5.5 Family 2/3 (BUS, CDF), not digital

Per voice v = 0, 1, 2:

```
POINTER_ISSUE   grant g_p(v):  read word at waveform_base + 4v
POINTER_CAPTURE g_p(v)+1:      waveform_offset <- f(word) (§6.3)
                               if audio_size_addr == 0: shift <- 27, -> SAMPLE_ISSUE
                               else -> SIZE_ISSUE
[SIZE_ISSUE     grant g_s(v):  read word at audio_size_addr + 4v
 SIZE_CAPTURE   g_s(v)+1:      waveform_shift <- word[11:7], -> SAMPLE_ISSUE]
SAMPLE_ISSUE    grant g_b(v):  read byte at §6.4 address
SAMPLE_CAPTURE  g_b(v)+1:      v<2: sample_sum += byte, voice+1, shift <- 27, -> POINTER_ISSUE
                               v=2: amplitude <- sample_sum[7:0] + byte, -> IDLE
```

(AUD:259-333.) The digital test is made at each POINTER_CAPTURE (§5.6, §5.8).
Minimum: without size words A = **T+13**; with size words A = **T+19**.

### 5.6 Digital mode (BUS3, CDF*)

```
digital_mode = (family==2 && revision==3 && bus_digital_audio)
            || (family==3 && cdf_digital_audio)                       // AUD:107-108
jplus_sample = (family==3 && revision==3)                             // AUD:111
```

At a POINTER_CAPTURE edge with `digital_mode` high (AUD:266-272):

```
digital_address    <- word + (refresh_counter[0] >> (jplus_sample ? 13 : 21))   // 32-bit
digital_low_nibble <- jplus_sample ? refresh_counter[0][12] : refresh_counter[0][20]
-> DIGITAL_ROUTE
```

At the DIGITAL_ROUTE edge (AUD:335-348), unsigned 32-bit compares:

| Condition (first match) | Action |
|---|---|
| `digital_address < rom_size` | → ROM_ISSUE (§8) |
| `digital_address >= 0x40000000 && digital_address - 0x40000000 < mapper_ram_size` | `digital_ram_addr <= digital_address[14:0]`, `digital_sample <= 1`, → SAMPLE_ISSUE |
| else | `amplitude <= 0`, → IDLE |

Then:
- RAM: SAMPLE_ISSUE reads byte `{2'b0, digital_ram_addr}` (AUD:141-142);
  SAMPLE_CAPTURE: `amplitude <= low ? {4'b0, byte[3:0]} : {4'b0, byte[7:4]}`,
  → IDLE (AUD:318-322).
- ROM: `amplitude <= low ? {4'b0, rom_data[3:0]} : {4'b0, rom_data[7:4]}` at
  the ROM_WAIT edge that sees `rom_done` (AUD:355-361).

Nibble rule: counter bit 20 (CDFJ+: bit 12) **set → low nibble**, clear → high
nibble.

Timeline: pointer grant g0 ≥ D+1; POINTER_CAPTURE edge g0+1; DIGITAL_ROUTE
edge g0+2.
- out of range: A = g0+2, minimum **T+4** (amplitude = 0);
- RAM sample: grant g1 ≥ g0+3, A = g1+1, minimum **T+6**;
- ROM sample: ROM_ISSUE in (g0+2, g0+3); request edge R = first posedge
  ≥ g0+3 with `rom_ready` in (R-1, R); A = R+4 on a sample-cache hit, minimum
  **T+9**; a miss adds the DDR3 latency (§8).

### 5.7 Amplitude formula

| Mode | `amplitude` |
|---|---|
| DPC+, BUS/CDF non-digital | `(b0 + b1 + b2) mod 256` (b_v = voice v's sample byte; `sample_sum[7:0] + b2`, AUD:324) |
| Digital, RAM or ROM | `{4'b0, nibble}` (0x00-0x0F) |
| Digital, address in neither ROM nor the RAM window | `0x00` (AUD:345) |
| After reset | `0x00` (AUD:188) |

`amplitude` changes only at the edges above. Between a tick and A the register
holds the previous result; no partial sum is ever visible (`sample_sum` is
separate).

### 5.8 Inputs read live in mid-refresh

These are sampled at the edge noted, not at D:

| Input | Sampled at | Consequence |
|---|---|---|
| `dpc_waveformN` | each DPC+ sample grant g (AUD:116-124,144-146) | A WAVEFORM write committed at E6 ≤ g-1 changes the sample of a voice not yet granted. |
| `digital_mode` (`bus/cdf_digital_audio`) | each POINTER_CAPTURE edge (AUD:266) | A SETMODE committed mid-refresh switches mode at the next POINTER_CAPTURE: if it turns digital at voice 1 or 2, `digital_address` = **that voice's** pointer word + `refresh_counter[0] >> k` (voice is not reset, the pointer address is `base + 4*voice`, AUD:136-137), and the partial `sample_sum` is discarded. |
| `audio_size_addr`, `mapper_ram_size`, `rom_size`, `family`, `revision` | live | Constant after load. |
| `refresh_counter[N]` | snapshot at D | Ticks and merges after D do not affect this refresh. |
| RAM contents | at each grant g | ARM writes during a call are seen if they landed before g (§12.4). |

[added] A SETMODE that turns digital audio **off** mid-refresh has no effect
on a refresh already past its POINTER_CAPTURE in digital mode: DIGITAL_ROUTE,
the RAM sample and ROM_WAIT never re-test `digital_mode` (AUD:317-322,
335-361), and `digital_sample` stays set until the next dispatch (AUD:236).
Turned off before a later voice's POINTER_CAPTURE of a non-digital refresh,
nothing changes either (that refresh was never digital).

---

## 6. Address formulas [checked]

All are byte addresses into the 128 KiB cart RAM, port A, 17 bits
(`cartram_addr[16:0]`, TOP:923). Word reads use `addr[16:2]` and return
`{byte3, byte2, byte1, byte0}` (little-endian) of that aligned word, whatever
`addr[1:0]` is (TDP:58, 74). Byte reads return lane `addr[1:0]` (TDP:57,
61-64).

### 6.1 Waveform pointer words (AUD:100-102, 136-137)

| Family / revision | `waveform_base` | Voice 0 / 1 / 2 pointer word at |
|---|---|---|
| BUS (family 2), any revision | 0x7F4 | 0x7F4 / 0x7F8 / 0x7FC |
| CDF0 (family 3, rev 0) | 0x7F0 | 0x7F0 / 0x7F4 / 0x7F8 |
| CDF1, CDFJ, CDFJ+ (family 3, rev 1-3) | 0x1B0 | 0x1B0 / 0x1B4 / 0x1B8 |

Digital mode reads only one pointer word per refresh: `base + 4*voice` with
`voice = 0` normally (voice 1 or 2 only in the §5.8 mode-switch case).

### 6.2 Size words and shift (AUD:138-139, 293-298, 302-310; DET:135, 146-161)

- `audio_size_addr` comes from the load-time scan in DET: in image bytes
  0..3071, at every aligned word, once the word `0xE3C55D3E` is seen, the next
  up to 20 aligned words are scanned; the first whose upper half is `0x4000`
  sets `arm_audio_size_addr = word[15:0]`. Reset to 0 at `load_start`. The
  scan runs for every image, any family.
  [added: exact rule. Words are assembled little-endian (DET:59-63) and tested
  at the byte with `load_addr[1:0] == 3` and `load_addr < 3072` (DET:146), so
  the last word tested starts at byte 3068 and an active scan simply stops
  there. The magic test comes first (DET:149-151): a later `0xE3C55D3E`
  restarts the 20-word window, also after an address was already found, so the
  **last** hit wins, not the first. The 20 words examined are the 20 aligned
  words after the magic word (`audio_size_words` 20 -> 1, DET:152-160).]
- If `audio_size_addr == 0`: no size reads; `waveform_shift = 27`.
- Else, voice v's size word is the word at `{1'b0, audio_size_addr} + 4v`
  (17-bit sum, word-aligned down by the RAM), and
  **`waveform_shift = word[11:7]`** (5 bits, 0-31).
- DPC+ never reads size words; its shift is always 27.

### 6.3 Pointer → `waveform_offset` (15 bits; AUD:274-292), non-digital only

`w` = the pointer word.

| Family / revision | In-window test | Offset if in window | Else |
|---|---|---|---|
| BUS (family 2) | `0x40000800 <= w < 0x40001800` | `w[14:0] - 0x800` (15-bit) | 0 |
| CDFJ+ (family 3, rev 3) | `w >= 0x40000800 && (w - 0x40000800) < (mapper_ram_size - 0x800)` (the latter 16-bit, zero-extended), i.e. `0x40000800 <= w < 0x40000000 + mapper_ram_size` | `w[14:0] - 0x800` (15-bit) | 0 |
| CDF0, CDF1, CDFJ (family 3, rev 0-2) | none | `{3'b0, (w[11:0] - 0x800) mod 4096}` | — |

### 6.4 BUS/CDF sample byte address (AUD:115-128, 147-151)

```
idx = refresh_counter[voice] >> waveform_shift          // 32-bit logical shift
sum = {17'b0, waveform_offset} + idx                     // 32-bit
CDFJ+ (family 3, rev 3):  addr = (0x800 + sum[14:0]) & (mapper_ram_size - 1)   // 17-bit
all other family 2/3:     addr =  0x800 + sum[11:0]
```

- BUS and CDF0/1/J: the sample stays in RAM 0x0800-0x17FF and wraps mod
  4 KiB. A BUS pointer outside its window, and any CDF0/1/J pointer outside
  0x40000800-0x400017FF, aliases (BUS: offset 0; CDF: low 12 bits).
- CDFJ+: wraps mod `mapper_ram_size` (normally 32 KiB, mask 0x7FFF): an
  offset + index past 0x77FF wraps into 0x0000-0x07FF (the driver area). With
  `mapper_ram_size` 8192 (only if the CDFJ+ revision reaches the engine while
  `force_bs` is not CDF, TOP:778-783) the mask is 0x1FFF.
- Default shift 27 gives 32-entry waveforms (`idx` = counter[31:27]).

### 6.5 DPC+ sample byte address (AUD:143-146)

```
addr = 0x0C00 + {waveform_v[6:0], 5'b0} + refresh_counter[v][31:27]
```

Range 0x0C00-0x1BFF (`waveform_v` is the live DPC register, §5.8).

### 6.6 Digital addresses (AUD:267-269, 336-342)

- ROM: `rom_addr = digital_address[24:0]`, a byte offset into the loaded
  image (the ARM's ROM is mapped at 0, MEM:566-567), used only if
  `digital_address < rom_size`.
- RAM: byte `digital_address[14:0]` when `digital_address - 0x40000000 <
  mapper_ram_size`.

### 6.7 NOTE frequency word (AUD:134-135)

`0x1C00 + 4*note_value`: words 0x1C00-0x1FFC (256 entries).

---

## 7. When AMPLITUDE changes after a tick [checked; 7.3 corrected]

### 7.1 Recurrence

```
T      tick edge
D      = first posedge >= T+1 with state IDLE in (D-1,D) and not (note_pending && family==1)
         (= T+1 if the engine is idle; else 1 + the edge at which the running
          sequence returned to IDLE, plus any NOTE loads that win IDLE first)
g_0   >= D+1
g_i+1 >= g_i + 2                       (CAPTURE takes one clk; next ISSUE starts after it)
         digital: pointer grant g_0; DIGITAL_ROUTE at g_0+2; RAM sample grant >= g_0+3
each g_i = first posedge at which ram_grant is high in (g_i - 1, g_i)
A     = g_last + 1                      (RAM paths)
A     = g_0 + 2                         (digital, out of range)
A     = R + 4                           (digital ROM, cache hit)  -- §8.3
A     = S1 + 3                          (digital ROM, miss)       -- §8.3
```

### 7.2 Minimum latencies (engine idle at T, no blocking)

| Path | Accesses (RAM) | A |
|---|---|---|
| DPC+ | 3 bytes | T+7 |
| BUS/CDF non-digital, no size table | 3 words + 3 bytes | T+13 |
| BUS/CDF non-digital, with size table | 6 words + 3 bytes | T+19 |
| Digital, address out of range | 1 word | T+4 |
| Digital, RAM sample | 1 word + 1 byte | T+6 |
| Digital, ROM sample, sample-cache hit | 1 word + MEM | T+9 |
| Digital, ROM sample, miss | 1 word + MEM + DDR3 | T+9 + (DDR3 path, §8.3) |

### 7.3 Every source of variable latency

1. **Front-end RAM select** (`sel_ram_sel`, C26:965): each clk it is high
   while the engine sits in an ISSUE state adds one clk. Windows per front end
   in §13. This is the dominant term while the 6507 runs.
2. **RAM init** (`init_ram_en`, C26:965; RI:191-192): only after a load or a
   reset rising edge.
3. **Engine busy at T**: a refresh or NOTE still running delays D (§5.2).
4. **NOTE loads** (DPC+): a pending NOTE wins IDLE: +3 clk minimum per NOTE
   ahead of the refresh (NOTE_ISSUE ≥1, NOTE_CAPTURE 1, back to IDLE 1).
5. **`rom_ready`**: `shadow_ready_sync2 && !sample_busy` (MEM:229): a ROM
   request waits while the shadow is not ready (after a load) or a previous
   sample (possibly orphaned by a reset) is still in flight.
6. **The DDR3 path** for a ROM-sample miss (§8.3): the MEM DDR state machine
   may be busy with an ARM line fill (4-beat burst) or a DMA read; then the
   bridge, the MiSTer DDR3 port's busy and read latency (not in this repo, not
   deterministic: the HPS shares it), and the bridge timeout/re-issue
   (DDR:147-160; MEM:842-845).
7. **Not** a source: `ram_byte_data` vs `ram_word_data` (both 1 clk), the
   ARM's port B (separate port, §12.4). [corrected: `pause` *is* a source,
   item 8; it does not only change data.]
8. [added] **`pause`** (§12.5): the 6507 freezes mid-cycle with its address,
   R/W and `rom_do` standing. If that frozen cycle raises a front-end select
   that is not gated by `access` (DPC+ register read fn 1-3 or PUSH/WRITE
   store; CDF fetch/jump substitution; BUS stream read/write, jump
   substitution, stuff states), no grant comes for the whole pause.

[corrected: the previous text said a held W+2 operand could keep the select
up for the whole call. It cannot.] During an ARM call (or a DPC+ copy/fill
stall) the bus shows W+1's address for the whole hold (§10.1, simulated), an
opcode fetch at a code address, and no front end selects RAM for that (§13.4).
So **every engine grant during a call is immediate** (the §7.2 minima apply
from the first ISSUE clk), unless the launch was late (§10.1, "late L"). The
fast fetch / fast jump that W+1 armed substitutes in W+2, which runs only
after the release, as an ordinary cycle with its ordinary select window.

### 7.4 What a refresh reads

Each capture sees the RAM as of its grant edge g: every port A write
strobed at a posedge before g (a port A write needs `sel_ram_sel`, so none can
coincide with a grant, C26:965,973), and every port B (ARM, DMA, writeback)
write made at a `clk_arm` edge strictly before g (§12.4).

---

## 8. Digital ROM samples: the DDR3 path [checked]

The audio never touches the console SDRAM. The image stays in SDRAM for the
6507 (`rom_do`); MEM keeps a read-only DDR3 shadow of it for the ARM, and the
digital samples are read from that shadow (MEM:4-5, 8, 783-788).

### 8.1 Request (clk_sys)

- `rom_request = (state == ROM_ISSUE) && rom_ready` (AUD:156);
  `rom_ready = sample_ready = shadow_ready_sync2 && !sample_busy` (MEM:229).
- At the request edge R (both see the same edge): AUD → ROM_WAIT (AUD:350-353);
  MEM `sample_addr_payload <= digital_address[24:0]`, `sample_toggle` flips,
  `sample_busy <= 1` (MEM:350-354).
- Completion (MEM:356-360): at the clk_sys edge where `sample_busy &&
  sample_complete_sync2 == sample_toggle`: `sample_data <=
  sample_result_sync2`, `sample_busy <= 0`, `sample_done <= 1` (a one-clk
  pulse, MEM:283). AUD's ROM_WAIT takes `rom_done`/`rom_data` at the next edge.

### 8.2 clk_arm side (MEM:717-726, 762-856, 898-925)

- 2-flop sync of the toggle (MEM:725-726).
- SAMPLE_IDLE: on `sample_sync2 != sample_seen`: latch address/token →
  SAMPLE_CHECK (MEM:899-906).
- SAMPLE_CHECK (MEM:908-922):
  - `addr >= MEM.rom_size` (the load size clamped to 1 MiB, MEM:770-777):
    result 0, complete;
  - one-entry sample cache hit (`sample_cache_valid && sample_cache_tag ==
    addr[24:3]`, an 8-byte DDR word): result = byte `addr[2:0]`, complete;
  - else → SAMPLE_COMMAND.
- DDR_IDLE dispatch priority (MEM:763-789): image word write > end-of-load >
  DMA copy command > sample command. The ARM's own cache fill is started from
  its bus FSM only if `ddr_state == DDR_IDLE && dma_state != DMA_COPY_COMMAND
  && sample_state != SAMPLE_COMMAND` (MEM:980-990): a queued sample beats a
  new fill but waits for one in progress.
- DDR_SAMPLE_COMMAND holds `ddr_req` (len 1) until `ddr_ack`
  (MEM:402-410, 837-840); DDR_SAMPLE_READ takes the first `ddr_rvalid` beat:
  fills the cache line, result = byte `addr[2:0]`, complete (MEM:842-855).
  `ddr_timeout` re-issues (MEM:843-844).
- Cache invalidated only by a new load (`epoch`, MEM:739-745) or `reset_arm`
  (MEM:691); a console/mapper reset leaves it (MEM:751-760).
- Bridge (DDR): command presented one `clk_arm` after `ch1_req`
  (DDR:171-186), accepted on the first cycle with `!DDRAM_BUSY` (`ack`,
  DDR:101,115), one beat per `DDRAM_DOUT_READY` (DDR:105,117). ch1 (2600 ARM)
  has priority over ch2 (BupChip, idle for 2600 carts) (DDR:107-109).

### 8.3 Latency

- **Hit or out of range: exactly A = R+4** (clk_sys). Derivation, with
  `clk_arm` edges a1..a4 inside (R, R+1): a1 sync1, a2 sync2, a3 SAMPLE_IDLE
  latch, a4 SAMPLE_CHECK sets `sample_complete_toggle` (MEM:911,917). R+1
  `complete_sync1`, R+2 `complete_sync2` (MEM:276-279), R+3 `sample_done`,
  R+4 `amplitude`. The argument holds for any clk_arm phase offset (the four
  ARM edges always fall before R+1).
- **Miss**: let c = the `clk_arm` edge at which DDR_SAMPLE_READ sees
  `ddr_rvalid`, S1 = the first clk_sys posedge strictly after c. Then
  `sample_done` at S1+2 and **A = S1+3**. Before the DDR3 port's own latency
  the path adds ≥3 `clk_arm` after SAMPLE_CHECK (MEM dispatch, bridge
  present, accept), plus any in-progress fill. The DDR3 latency is outside
  this repo and not deterministic on MiSTer.
- A miss happens whenever the sample address enters a new 8-byte DDR word,
  i.e. once per 2^24 of `counter0` advance (CDFJ+: 2^16), since the byte
  address steps every 2^21 (CDFJ+: 2^13) (AUD:267-269). How many refreshes
  that is depends on `frequency0`.
- [added] Also a miss: any refresh whose `digital_address` falls in a
  different 8-byte word than the cached one for another reason (the ARM or
  the 6507 moved the pointer word, `counter0` was replaced at a merge, or a
  RAM-window or out-of-range sample came in between: those do not touch the
  cache, so the next ROM sample in the old word still hits). The cache is
  one entry for the whole engine.
- [checked: the ">= 3 `clk_arm`" before the port's own latency is SAMPLE_CHECK
  edge a -> a+1 DDR_IDLE dispatch (MEM:784-788) -> a+2 bridge presents
  (DDR:171-186) -> a+3 earliest accept with `!DDRAM_BUSY` (`ch1_ack`
  combinational, DDR:101,115; MEM:837-840).]

### 8.4 Coupling with the ARM

During an ARM call, a sample miss can wait behind an ARM line fill, and a
queued sample command blocks the ARM from starting its next fill (MEM:980-982).
So digital ROM audio during a call can lengthen the call by a DDR3 round trip,
which moves the call's return (§10) and so the 6507's timeline against the
ticks. Not cycle-reproducible on any platform whose shadow memory differs.

---

## 9. NOTE handling (DPC+ only) [checked]

### 9.1 Strobe

A 6507 write to `$1075/$1076/$1077` (DPC `(a-0x28)>>3 == 9`, `a[2:0]` 5-7)
committed at E6 sets `audio_note_write = 1`, `audio_note_voice = a[1:0]-1`
(0, 1, 2), `audio_note_value = d_in` (DPC:304-315). The strobe is a one-clk
pulse in (E6, E7) (DPC:221). DPC is reset (and the strobe 0) whenever DPC+ is
not the selected mapper (C26:805).

### 9.2 Latch and load (AUD:201-205, 227-228, 243-257)

- At E7: `note_pending <= 1`, `note_voice <= voice`, `note_value <= value`.
  A later strobe overwrites both.
- IDLE (family 1 only): `note_pending` → NOTE_ISSUE, beating a pending refresh.
- NOTE_ISSUE: word at `0x1C00 + 4*note_value` (value as it stands in
  (g-1, g)), wait for grant g.
- NOTE_CAPTURE at g+1: `frequency[note_voice] <= ram_word_data`
  (`note_voice` as it stands in (g, g+1)); `note_pending <= 0` unless a strobe
  is sampled at g+1. → IDLE.
- The frequency table (RAM 0x1C00-0x1FFF) is loaded from image
  0x7C00-0x7FFF by RAM init (RI:155-161; `dpcplus.md` §9.4) and is writable by
  the ARM.
- Family 2/3 latch `note_pending` but never act on it (AUD:227); DPC is the
  only strobe source anyway.

### 9.3 Timing relative to E0 (engine idle, no blocking)

| Edge | Event |
|---|---|
| E6 | NOTE write commits (DPC:311-315) |
| E7 | `note_pending`, voice, value latched |
| E8 | IDLE → NOTE_ISSUE |
| E9 | earliest grant (RAM registers the address) |
| E10 | `frequencyN` written |

A tick at edge T uses the new frequency iff the frequency was written at an
edge ≤ T-1. A busy engine at E8 (a refresh in flight) delays this to the edge
after that refresh's A (§5.2).
[checked; made exact: the refresh's last edge A puts the state back to IDLE,
so NOTE_ISSUE starts at A+1 (the NOTE beats any queued refresh there), the
grant is >= A+2 and `frequencyN` is written at >= A+3. For a ROM-sample
refresh A is the ROM_WAIT edge that sees `rom_done`.]

### 9.4 Overlapping NOTE strobes (replicate exactly)

Let the first note be granted at g; a second strobe is sampled at edge s.

| s | Result |
|---|---|
| s < g | first note lost; second loaded normally (voice and value both replaced before the grant) |
| s = g | **mixed**: RAM reads the first value's word (address registered at g), but `note_voice` is the second's at g+1, so `frequency[voice2] <= table[value1]`; the strobe is low at g+1, so `note_pending` clears and the second note is **lost** |
| s = g+1 | first note completes (voice1, value1); `note_pending` stays set; second loads next |
| s ≥ g+2 | both load in order |

Reachability: two NOTE strobes are at least 12 clk apart (an RMW `INC $1075`
writes twice in consecutive cycles), and between them no 6507 cycle can raise
the DPC+ RAM select (a write to $1075-$1077 or an RMW's read of it is not a
RAM register cycle, DPC:113-124,144-146). The first note's grant comes at
most ~8 clk after its strobe is latched (E7 → E15) even behind a DPC+ refresh dispatched at E7, so s ≤ g+1 needs
starvation the 6507 cannot produce. Treat rows 1-2 as unreachable but
replicate the logic as written (it costs nothing).
[checked: worst case re-derived. Refresh dispatched at E7 of the NOTE store
cycle k: grants E8, E10, E12, A = E13, NOTE_ISSUE E14, grant E15. The clks
E8-E15 belong to cycle k (a store to $1075-$1077, no select, DPC:144-146) and
to cycle k+1 (the next opcode fetch, or an RMW's second store), neither of
which selects; the earliest second strobe is E19 = g+4. Neither a pause nor a
call can add a strobe (the 6507 is stopped). See §17 G1 for the guard
verdict under the user's rule.]

---

## 10. ARM call hand-off (the audio half of CTL) [checked; 10.1 corrected]

### 10.1 Launch edge L and what is captured

- `call_launch = arm_call_request` = the selected front end's
  `call_pending && mapper_call_ready` (C26:945-947; DPC:183, MC:159, MB:169),
  `mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy`
  (C26:661-662), `arm_call_ready = arm_online_sync2 && shadow_ready_sync2 &&
  !mapper_reset_sys && !call_busy` (CTL:86-87).
- `call_pending` is set by the CALLFN write commit at E6 (DPC:293-295 $105A;
  MC:244-246 $1FF3; MB:281-284 $101A or BUS3 $1FF3), so **L = E7** of that
  write cycle when ready, else the first later edge at which it is ready.
  The pulse is one clk (the front end clears `call_pending` at L).
- At L, all from the values in (L-1, L) (pre-edge; a tick at L itself is
  not included):
  - CTL payload: `audio_counter_payload[N] <= counterN`,
    `audio_frequency_payload[N] <= frequencyN`, `call_toggle` flips,
    `call_busy <= 1` (CTL:149-161). Every family.
  - AUD seeds, **`family >= 2` only**: `call_seed_counter[N] <= counterN`
    (AUD:207-211). Since `call_launch` implies the controller accepts
    (`mapper_call_ready` ⊂ `arm_call_ready`), seeds always equal the payload
    counters.
- From (L, L+1) `call_busy` = 1 → `arm_call_stall` (TOP:306-307) → RDY low
  (TOP:328-329). The cycle after a write cannot be held (`hold = ~rdy_cy &
  ~wr_q`, `6502/mos6502_ctl.sv:874-880,1392-1394`), so W+1 (the next opcode
  fetch, W = the CALLFN write cycle) still runs and is committed.
  [corrected: the earlier text said W+2 is held with W+2's address on the bus.
  The CPU holds W+2's *T-state*, but the bus keeps **W+1's address** for the
  whole hold.] W+2's E0 samples RDY low, so `hold` = 1 at that edge and the
  held control word is `hold_mask(c_reg)`, which clears `adl_abl`, `ipc` and
  `wr` and keeps `adh_abh` only on the indexed-carry path
  (`mos6502_ctl.sv:936-958`). ABL/ABH load only at `phi1_en` from those lines
  (`mos6502_dp.sv:202,225-226`), so W+2's address is never loaded while held:
  every held repeat presents W+1's address, read, with W+1's byte on `rom_do`.
  W+2's own address appears only at the first E0 >= X+1 (RDY high).
  - What the front end sees (TOP:320-327): W at its E6 (taken, L = E7); W+1 at
    its E6, the stall's first `pclk0` (taken; `stall_cycle_taken` set);
    W+1's address again at every held repeat, all hidden; then W+2 at its real
    address, taken. This matches TOP:309-319's diagram ("write | fetch | fetch
    ... | operand"; the "fetch" repeats are W+1's address) and `cdf.md` §15.
    `dpcplus.md` §8.3 and this spec's old §13.4 assumed W+2's address was on
    the bus during the hold; that is wrong.
  - **Simulated** (scratch bench, not a repo file:
    `scratchpad/audio_chk/tb_stall.sv`, Verilator 5.020, upstream's unmodified
    `6502/mos6502*.sv`, TOP's `stall_cycle_taken`/`mapper_phi2`/RDY logic, a
    CALLFN front end setting `call_pending` at the shown write commit and
    `call_busy` one clk later). `LDA #$FF; STA $1FF3; LDA #$05`, 100-clk call:
    W E6 at clk 282 (shown, `call_busy` set at 283 = E7); W+1 E6 at 294,
    address $F005 (the `LDA #` opcode), shown, `hold` 0, T1; E6 at 306 ... 378,
    address **$F005**, hidden, `hold` 1, T2; `call_busy` cleared at 383 (E11);
    E6 at 390 address $F006 (the operand), shown, `hold` 0. Same pattern
    (held repeats at W+1's address) for `STA $1FF3; JMP`, `STA $1FF3,X; NOP`
    and `STA $1FF3; LDA $1008`.
  - **Release window** (simulated over X = E0 ... E11): if `call_busy` is
    cleared at X = E0 ... E5 of a held repeat, that repeat's E6 sees the stall
    low and is **shown**, so W+1's address is committed a **second** time
    (the CPU still treats the repeat as held: its E0 sampled RDY low); W+2
    follows at the next E0. X = E6 ... E11: no duplicate. Which case occurs
    depends on the call's duration mod 12. For the audio engine the duplicate
    is harmless (an opcode fetch: no NOTE, no select); for the front ends see
    §13.4.
  - [added] **Late L.** If `mapper_call_ready` is low at E7 (writeback busy,
    `!arm_online_sync2`, `!shadow_ready_sync2`, init busy), the 6507 keeps
    running until L. With W's E0 = E0: L <= E17 behaves exactly as above;
    L in E18 ... E23 still holds W+2 at W+1's address, but W+1's E6 (E18) was
    seen with the stall low, so the first held repeat's E6 is the stall's
    first `pclk0` and is **shown** (W+1's address committed twice); L >= E24:
    the held cycle is the first non-post-write cycle whose E0 >= L+1, and the
    bus holds the address of the read cycle **before** it, which can be any
    read (§13.4 corner cases). In practice L = E7 (a writeback finishes within
    a 6507 cycle of its trigger, and every CALLFN store is at least 3 cycles
    after any pointer update).
  - [added] **RMW CALLFN** (`INC`/`DEC $1FF3`, both values $FE/$FF): the
    first write is W, the second write is W+1 (shown, and it sets
    `call_pending` again, §2), W+2 (the opcode fetch) cannot be held either
    (`wr_q` set by W+1) and runs **hidden** (`stall_cycle_taken` already set),
    and W+3 is held at W+2's address (simulated). A front end then misses
    W+2's opcode commit.

### 10.2 Into the ARM: FIQ r8-r13

- clk_arm: `call_toggle` through 2 flops (CTL:264-265); CTRL_IDLE accepts when
  `sys_online_sync2 && shadow_ready && cpu_halted && complete_ack_sync2 ==
  complete_toggle && call_sync2 != call_seen`, copying the payload to
  `active_*` (CTL:284-304).
- CTRL_WRITE_STATE writes state indices 0..22 in order, one per `state_ready`
  (CTL:307-315), with data (CTL:210-232):

| Index | Value |
|---|---|
| 0-12 | 0 |
| 13 | stack (`call_stack`) |
| 14 | `0xF0000000` (return sentinel, CTL:48) |
| 15 | entry |
| 16 | CPSR = SYS mode, T per `call_thumb` |
| 17, 18, 19 | `counter0`, `counter1`, `counter2` at L |
| 20, 21, 22 | `frequency0`, `frequency1`, `frequency2` at L |

- Indices 17-22 are FIQ r8-r13 (inferred: the readback below indexes
  `STATE_FIQ_R8 + 0..5` for the same six values, and the repo's `docs/DARIA_CORE.md:57-58`
  states r8-r10 = counters, r11-r13 = frequencies; the package constant itself
  lives in `arm7tdmi/`, not read). FIQ r14 and SVC registers are not written.
  [checked; corroboration added: `docs/DARIA_CORE.md:390,479` record that the
  repo's DARIA shadow bench compared, on every call of 21 images, DARIA's FIQ
  r8-r13 at return against upstream's returned audio values and found them
  equal; DARIA reads them as FIQ r8-r13 after forcing FIQ mode
  (DARIA_CORE.md:1060,1081). With `STATE_FIQ_R8` != 17 an untouched counter
  would also come back "changed" on every call. Still an inference from the
  allowed files: the constant itself was not read.]
- [added] `state_wdata` is selected by `write_index` (CTL:219-232), the index
  presented by `state_index_q`; both move together in CTRL_WRITE_STATE, so the
  data and the index agree.
- The ARM runs in SYS mode; only code that switches to FIQ mode sees or
  changes r8-r13 (the drivers' helpers do, DARIA_CORE.md:47-48).
- (CTL:312-313 lack `begin/end`: `state_index_q` advances even at index 22,
  to 23. Harmless.)

### 10.3 Out of the ARM

- A fetch from `0xF0000000` (`return_fetch`, MEM:558,578,633) → RETURN_HALT
  → on `cpu_halted`, 6 reads of `STATE_FIQ_R8 + i`, i = 0..5
  (CTL:320-356): i 0-2 → `audio_counter_result[i]`, i 3-5 →
  `audio_frequency_result[i-3]` (index arithmetic `audio_read_index[1:0] -
  2'd3` = 0, 1, 2 for 3, 4, 5; CTL:342-344). With the last capture,
  `complete_token <= active_token`, `complete_toggle` flips (CTL:346-349).
- clk_sys (CTL:126-141, 163-177): `complete_toggle`, `complete_token` and all
  six results pass through 2-flop chains every clk. Let c = the `clk_arm` edge
  of the toggle flip, S1 = the first clk_sys posedge strictly after c.
  `complete_sync2` shows the flip in (S1+1, S1+2); at **X = S1+2**, if
  `call_busy && call_ack_sync2 == call_toggle && complete_token_sync2 ==
  call_toggle`: `audio_*_return <= audio_*_sync2` (all six already new: the
  last result was written at c, the others earlier),
  `call_busy <= 0`, `call_done <= 1` (one clk, CTL:142).
- **M = X+1**: the engine merges (§10.4). `call_busy` low from (X, X+1)
  releases RDY combinationally (TOP:328-329); RDY is sampled at E0, so the
  6507 resumes no earlier than the first E0 ≥ X+1 = M (later if another RDY
  term holds it). **The merge is complete by the time the 6507 executes
  again.**
- The call's duration (ARM run time, `state_ready` handshakes in `arm_host`/
  `arm7tdmi`, DDR3 fills) is outside this spec.
- [checked: X = S1+2 and M = X+1 re-derived from CTL:134-135, 163-177 and
  AUD:213; the RDY release and "first E0 >= X+1" reproduced in the §10.1
  simulation for X = E0 ... E11.]
- [added] A `pause` inside a call lengthens it: the ARM's memory system and
  core are clock-enabled by `~pause` (TOP:1187 `mem_ce`, "paired with
  arm_host's own ce"), while AUD keeps ticking (§12.5). So M moves by the pause
  length plus the ARM's own phase on resume.

### 10.4 Merge rule at M (AUD:213-223), `family >= 2` only

For each N:
```
if (counterN_return != call_seed_counter[N]) counterN <= counterN_return;   // wins over a tick at M
frequencyN <= frequencyN_return;                                            // always
```
- "Changed" means changed **from the launch value**. An ARM that writes back
  the same value it was given (e.g. resets an already-zero counter) is seen as
  unchanged, and the live counter is kept.
- Frequencies are always replaced. Since nothing else writes BUS/CDF
  frequencies, an untouched r11-r13 returns the launch value = the live value,
  so the replacement is a no-op unless the ARM changed it.
- No seed is kept for frequencies.
- [checked] "Left alone" means exactly `counterN_return == call_seed_counter[N]`
  (32-bit compare, AUD:214-219); the seed is the counter in (L-1, L).
- [added] A launch sampled at M itself (a second CALLFN left pending during
  the call, §2) seeds from the pre-merge counters while this merge compares
  against the old seeds.

### 10.5 Ticks during the call: the counter algebra

Let F = launch-time frequency, F' = returned frequency, and ticks at edges t.
- Counter the ARM left alone: after M it is
  `seed + F * #{ticks with L ≤ t ≤ M} + F' * #{ticks after M}`
  (a tick at L is pre-launch for the seed but still steps the live counter;
  a tick at M uses F, the pre-edge frequency).
- Counter the ARM changed to r: `r + F' * #{ticks after M}`; every tick in
  [L, M] is discarded, including one at M.
- Refreshes during the call read the live counters (snapshot at each D),
  which step with the launch-time frequencies.
- **Consequence for cloning:** M's position relative to the tick edges fixes
  every later counter value, and the call duration shifts the 6507's timeline
  against the free-running ticks for the rest of the run. Per-tick equality
  after a call needs an identical call duration (§18).

### 10.6 DPC+ (family 1)

The payload still carries counters and frequencies into r8-r13 (CTL:149-158,
225-230), but AUD neither seeds nor merges (AUD:207,213). The return values
are dropped. DPC+ frequencies come only from NOTE loads.

### 10.7 Reset during a call

`mapper_reset_sys` = cart2600 `reset` = the engine's reset (C26:447;
SUB:122). While it is high CTL clears `call_busy` without `call_done`
(CTL:144-147), so no merge; the engine's own reset zeroes counters,
frequencies and seeds anyway. CTL's clk_sys side and the `audio_*_return`
registers reset only with `reset_arm` (C26:444; CTL:92-109).

---

## 11. Every console-side cart RAM access the engine makes [corrected: in-call column]

All engine accesses are **reads** on **port A** of `cart_ram_tdp` (the clk_sys
"mapper" port, TDP:9-13, 73-77), through cart2600's mux
`cartram_addr = init_ram_en ? init : (sel_ram_sel ? sel_ram_a :
{1'b0, audio_ram_addr})` (C26:966-967), granted only when neither the RAM
init nor the selected front end holds the port (C26:965). The engine never
writes (no write strobe path: C26:973-974 needs `sel_ram_sel`). It never uses
port B. It is never gated by a call: none of these checks `call_busy`.

| # | Access | Family / condition | Data path | Byte address | Per | During an ARM call? |
|---|---|---|---|---|---|---|
| 0 | [added] Passive idle read | any | — | byte 0 (`ram_addr` = 0 outside ISSUE, AUD:132) | every clk nothing else holds port A | Yes, harmless: no side effect, nothing captures it; it only sets what a front end sees as stale data in its first selected clk (§16 item 15) |
| 1 | NOTE frequency word | 1 (DPC+), `note_pending` | word, `mapper_word_rdata` | `0x1C00 + 4*value` | NOTE write | [corrected] In practice never: a NOTE load ends <= ~10 clk after its strobe (§9.4) and a CALLFN store commits >= 4 cycles after any NOTE store; the held 6507 makes no NOTE write during a call |
| 2 | DPC+ waveform sample, x3 | 1 | byte (lane) | `0x0C00 + 32*wf_v + ctr_v[31:27]` | tick | **Yes**, granted at once (†) |
| 3 | Waveform pointer word, x3 (x1 digital) | 2, 3 | word | `base + 4v` (§6.1) | tick | **Yes**, granted at once (†) |
| 4 | Waveform size word, x3 | 2, 3, `audio_size_addr != 0`, non-digital | word | `audio_size_addr + 4v` | tick | **Yes**, granted at once (†) |
| 5 | Waveform sample byte, x3 | 2, 3, non-digital | byte | §6.4 | tick | **Yes**, granted at once (†) |
| 6 | Digital RAM sample, x1 | BUS3 / CDF*, digital, RAM window | byte | `digital_address[14:0]` | tick | **Yes**, granted at once (†) |
| — | Digital ROM sample | digital, `< rom_size` | **not cart RAM**: DDR3 shadow via MEM (§8) | image offset | tick | **Yes**, competing with ARM fills (§8.4); its pointer word (row 3) is granted at once (†) |

(†) [corrected: the earlier footnote said a held W+2 RAM substitution kept
port A for the whole call.] The engine never looks at `call_busy`, so it keeps
issuing during calls and DPC+ copy/fill stalls. During the hold the bus shows
W+1's address (an opcode fetch, §10.1), which raises no front-end select
(§13.4), and `init_ram_en` is idle, so **every in-call access is granted on
its first ISSUE clk** (§7.2 minima, measured from each tick). In-call reads
see port B (ARM, DMA, writeback) writes made at `clk_arm` edges before the
grant (§12.4). The only exception is a late L (§10.1), which does not occur
in practice; a pause during a call freezes the same W+1 address and adds no
select.
[added] In 7800 mode (before `tia_en`) the same reads land on the 7800 path's
RAM address (§12.6).

Counts per tick: DPC+ 3; BUS/CDF 6 (9 with size words); digital 1 (RAM 2).
Ticks come every 715/716 clk, so the engine takes port A on at most 9 grant
edges per tick (each a single clk), plus any NOTE loads.

What the ARM side sees: nothing. The engine has no effect on port B, MEM's
RAM path, or the ARM, except through the DDR3 path in §8.4.

---

## 12. Port A mechanics the engine depends on [checked; 12.5-12.6 corrected]

### 12.1 Latency
Address registered at every clk_sys posedge, data out one clk later,
unregistered output (CR:118-156 altsyncram, `outdata_reg_a UNREGISTERED` at CR:131;
portable model CR:172-176). No read enable on the lane RAMs: port A reads
every clk (TDP:66-85). The byte lane select `mapper_read_lane` is registered
from `mapper_addr[1:0]` at the same edge when `mapper_en` (TDP:61-64).

### 12.2 `mapper_en`
`mapper_init_busy ? (cartram_wr || cartram_rd) : !pause` (TOP:921).
`cartram_rd` includes `audio_ram_grant` (C26:975), so the lane register
follows the engine's grant edges even during RAM init.

### 12.3 Read-during-write on port A
New data (CR:135, 175). Cannot happen for the engine: its grant excludes any
front-end select, and the write strobe needs one (C26:965, 973).
[checked for 2600 mode. Added: in 7800 mode (`tia_en` 0, no init) TOP drives
port A from the 7800 path, `cartram_wr78 & mclk1` (TOP:752-757), which AUD's
grant does not see; a 7800-path write in the same clk as an engine grant
returns the new byte. Only affects the pre-lock garbage of §12.6.]

### 12.4 Port B (ARM, DMA, writeback) against an engine read
Port B is enabled on 4 of every 5 `clk_arm` edges: the edge that coincides
with a clk_sys edge is skipped (`arm_phase == 4`, TDP:34-56). So an engine read
registered at clk_sys edge g sees every port B write made at a `clk_arm` edge
strictly before g and none at or after it; there is no same-edge collision.
During a call, the ARM's progress at edge g therefore decides what a refresh
reads if the ARM is rewriting pointers, size words or waveform data.

### 12.5 Pause [corrected: a frozen 6507 cycle can block every grant]
`cartram_data_bram = pause ? 8'hFF : data` (TOP:936) masks **bytes only**;
`mapper_word_rdata` is not masked (TOP:934,1158). The engine keeps running
through a pause (no gating, §3.4): counters keep stepping and ticks keep
queueing refreshes.

[added] What the earlier text missed: **the 6507 and the front ends freeze
mid-cycle, but their selects stay live.** MARIA's `ce = ~pause ||
effective_reset` (TOP:445) stops `mclk0` (`Maria/maria.sv:157-166,197`), and
with it `tia_clk_x2` (`maria.sv:154`), TIA's only clock enable (TOP:490), so
neither phase source issues `pclk1`/`pclk0`: the CPU stops with its address,
R/W and `rom_do` standing, and no `access` commits. Every select that is not
gated by `access` (DPC+ register read fn 1-3 and PUSH/WRITE stores; CDF
fetch/jump substitution; BUS stream read/write, jump substitution and the
stuff states; §13) is evaluated on that frozen cycle for the whole pause.
- Frozen cycle **selects**: no grant for the whole pause (the port also writes
  nothing: `mapper_en` = 0, TOP:921). The engine sits in its ISSUE state,
  ticks coalesce, `amplitude` keeps its pre-pause value; the first grant comes
  after the release, when the select drops.
- Frozen cycle **does not select**: refreshes run and see byte data 0xFF:
  DPC+ and BUS/CDF non-digital amplitude = `0xFF*3 mod 256 = 0xFD`; digital
  RAM → `0x0F`; digital ROM → real data (the MEM sample path has no `pause`
  or `mem_ce` term, MEM:350-360, 898-922); NOTE, pointer and size words real.
- The byte lane register is frozen (`mapper_en` = 0), so a capture straddling
  the release reads the stale lane (§5.3).
- The ARM is stopped too (`mem_ce = ~pause`, TOP:1187), so a call in progress
  lengthens by the pause (§10.3).
After the pause the counters have advanced by the pause's ticks while the 6507
did not.

### 12.6 Which address the RAM sees outside 2600 mode
TOP takes `cartram_addr26` only when `mapper_init_busy || tia_en`
(TOP:756-757); otherwise (7800 mode, before the BIOS locks 2600 mode) the RAM
port follows the 7800 path. The engine still ticks and refreshes then (its
family is set at load), so its grants read whatever the 7800 path addresses.
Frequencies are 0 (no NOTE, no call before the lock), so counters stay 0;
only `amplitude` is meaningless until the first refresh after the lock.
[checked. Precisions added:]
- "Before the lock" for the counters means before `arm_driver_run = lock_ctrl
  && tia_en` (TOP:1136): without it no front end commits (C26:247), so no
  NOTE strobe and no CALLFN, and every frequency and counter stays 0 from
  reset. These two registers are therefore equal on any two implementations
  up to the lock without any comparison effort.
- The garbage `amplitude` is clean from the first refresh whose every grant g
  has `tia_en || mapper_init_busy` high in (g-1, g). Before `tia_en` the 6507
  cannot see it at all: the cartridge data TOP muxes onto the bus is
  `cart_7800_DB_out` while `tia_en` is 0 (TOP:333). Between `tia_en` and the
  first clean refresh (at most one tick interval plus one refresh) a 6507
  read of AMPLITUDE could see it; the front ends' `d_out` is combinational and
  does not need `access`.
- In 7800 mode the 2600 front ends still evaluate their selects on the
  7800-mode bus (`a_in = {AB[12] & bios_en_b, AB[11:0]}`, TOP:1128), so some
  engine grants are delayed there too; irrelevant to the (garbage) result.

`EXTERNAL_CARTRAM` builds (the Pocket's SRAM) tie `cartram_word_data_tdp` to 0
(TOP:937-942): every word read above (NOTE, pointer, size) would read 0. A
Pocket clone needs its own word-read path.
[checked; added: the same branch also ties `arm_ram_rdata` to 0 and
`arm_ram_accepted` to 0 (TOP:939-940), so under `EXTERNAL_CARTRAM` upstream's
ARM could not reach cart RAM either: upstream's ARM mapper is not usable in
that build at all, and today's Pocket build also sets `NO_ARM_MAPPER`, which
removes the engine (C26:585-617). The clone's console-side path must give, for
an address presented in (g-1, g): the 32-bit little-endian word at
`addr[16:2]` and the byte at lane `addr[1:0]` (subject to §5.3's lane rule),
both valid in (g, g+1), reflecting every port B write made before g (§12.4).]

---

## 13. Front-end RAM selects that block the grant [checked; 13.4 rewritten]

`sel_ram_sel = ram_sel[mapper]` (C26:191). Exact clk windows are in the
front-end specs; summary of what raises it:

### 13.1 DPC+ (`ram_sel`, DPC:132-158), combinational, not gated by `access`
- Register read of function 1-3 (`$1008-$101F`, or a fast-fetch operand
  `< $28` after `LDA #`): `register_read && fn in 1..3` (DPC:113-124,137-143).
  Direct addresses: the whole cycle E0-E12 (`dpcplus.md` §12.1). Fast-fetch
  operand: from `rom_do` arrival to E6 (§12.2 there).
  [checked; precision added: an address-decoded select of cycle k is high in
  (E0, E12) of k (ABL/ABH and R/W change only at E0), so it blocks grant edges
  E1 ... E12 of k; E12 = the next E0 still samples cycle k's bus. A select
  cleared by the E6 commit (fast fetch, fast jump) is low from (E6, E7).]
- Writes to `$1060-$1067` (PUSH) and `$1078-$107F` (WRITE): the whole cycle
  (DPC:144-158; `dpcplus.md` §12.4).

### 13.2 CDF (`cdf_ram_en`, MC:135-156)
- `stream_substitute && !amplitude_fetch` (fast fetch or fast jump): from the
  clk the predicate holds (depends on `rom_do` arrival) to E6 (`cdf.md`
  §12-13). An amplitude fetch does **not** select RAM (MC:142-143).
- DSWRITE (`access && !rw && a == $1FF0`): (E5, E6] (MC:150-156).

### 13.3 BUS (`bus_ram_en`, MB:145-166)
- `stream_read` (`$1000-$100F` BUS1/2, `$1FEF` BUS3) and BUS3
  `jump_substitute`: address-decoded, the whole read cycle (jump: once
  `rom_data == 0`).
- `stream_write` (`$1010-$1013`, BUS3 `$1FF0`): the whole write cycle.
- Bus-stuff states STUFF_DATA / STUFF_READY (MB:164-166).
- `amplitude_read` does **not** select RAM (MB:156-158).

### 13.4 During a call (or a DPC+ copy/fill stall) [corrected: rewritten]

The previous version of this section assumed the held cycle presents W+2's
address (the operand of the instruction after the CALLFN store), so that a
`STA CALLFN; LDA #<stream>` pair would hold the RAM select for the whole call
and starve the engine. Upstream's CPU does not do that (§10.1, simulated):
**the bus shows W+1's address for the whole hold**, and W+2 runs only after
the release.

- The stall is high from (E7, E8) of the CALLFN (or service) write cycle W
  (TOP:306-307; §10.1). W itself selects nothing: DPC+ $105A is outside the
  PUSH/WRITE windows (DPC:144-146), CDF $1FF3 is not DSWRITE $1FF0
  (MC:150), BUS $101A / BUS3 $1FF3 are not stream writes (MB:102-104).
- W+1 (the opcode fetch at code address P, byte `op` on `rom_do`) cannot be
  held; its E6 is the stall's first `pclk0`, shown, so the front end commits
  it (TOP:320-327).
- Every held repeat presents (P, read, `op`) and is hidden. The front ends'
  selects on that bus, after W+1's commit:
  - **DPC+**: `register_read` needs `P[11:0] < $28` (code is not in the
    register window) or `fast_fetch && fast_pending && rom_data < $28`
    (DPC:113-115). W+1's commit set `fast_pending = fast_fetch && op == $A9`
    (DPC:251), and then `rom_data` = $A9 >= $28. PUSH/WRITE need a write.
    **No select.**
  - **CDF/CDFJ/CDFJ+**: `fetch_substitute` needs `a_in ==
    fast_expected_address`, which W+1's commit set to P+1 (MC:104-105,
    211-213); `jump_substitute` needs `a_in == expected_address` = P+1
    (MC:102-103, 216-220) or a live chain (none: the reads before W cleared
    any stale one, MC:221-223, and writes do not touch it); DSWRITE needs a
    write. **No select.**
  - **BUS**: `stream_read` needs P in $1000-$100F (BUS1/2) or P = $1FEF (BUS3)
    (MB:96-98), not code; `jump_substitute` needs `a_in ==
    jump_operand_address` = P+1 (MB:115-116, 242-246); stream writes and the
    stuff states need a write (MB:102-104, 113-114). **No select.**
- So in every case the engine's grants during the hold are immediate (§11).
  `init_ram_en` is idle (no load, no reset rising edge).
- **After the release** W+2 appears at P+1 at the first E0 >= X+1 (§10.3). If
  W+1 armed a substitution (`LDA #`, CDFJ+ `LDX #`/`LDY #`, a fast `JMP`),
  W+2 is an ordinary substituted cycle and selects RAM in its ordinary window
  (§13.1-13.3: from its E0 plus the `rom_do` latency to its E6). That one
  window can delay a refresh that was dispatched during the call; nothing more.
- **Release window** (§10.1: `call_busy` cleared at E0 ... E5 of a held
  repeat): W+1's address is committed a second time at that repeat's E6. For
  the engine this changes nothing directly. For the front ends:
  - DPC+ and CDF re-arm exactly what W+1 armed (DPC:251; MC:211-213, and the
    fast-jump re-arm at MC:216-220 has priority over the cancel at MC:221):
    benign.
  - **BUS3: the duplicate cancels what W+1 armed.** With `jump_remaining`
    = 2 the program-read branch finds no substitution at P and clears it
    (MB:232-241); a pending fast `STY` is likewise dropped (`sty_pending`
    cleared because `a_in != sty_operand_address`, MB:248-253). W+2 is then
    not jump-substituted (the 6507 takes the literal operand) and the STY is
    not stuffed, which also removes their RAM selects (and the stuff states')
    from the engine's timeline. Whether this happens depends on the call's
    length mod 12. [This is a front-end finding for `bus.md`; noted here
    because it moves engine grants after the call.]
- **Corner cases** (not reached by normal code, replicate anyway):
  - *Late L* (§10.1): the held cycle presents the address of the cycle
    before it. If that was an address-decoded RAM read (DPC+ $1008-$101F,
    BUS1/2 $1000-$100F, BUS3 $1FEF), the select stands for the whole call and
    the engine gets no grant until the release.
  - *RMW CALLFN* (§10.1): W+2, an opcode fetch, runs hidden and W+3 is held at
    W+2's address: still no select during the hold, but an `LDA #`/`JMP`
    opcode at W+2 is never seen, so W+3's operand is not substituted.
  - *Pause during a call*: the frozen bus is the same (P, read, `op`); no
    select (§12.5).

---

## 14. What the 6507 reads [checked]

| Front end | Read that returns `amplitude` | Lines |
|---|---|---|
| DPC+ | register `$1005` (fn 0, index 5), direct or fast-fetch operand `$05` | DPC:162-173 |
| CDF0/1 | fast-fetch of stream 34; CDFJ/J+ stream 35 (with the fetch offset if enabled) | MC:81, 89-93, 111-112, 142-143 |
| BUS1/2 | `$1018`; BUS3 `$1FEE` | MB:99-101, 156-158 |

- `d_out = amplitude` combinationally; the 6507 latches at E6 the value in
  (E5, E6). So a read returns the **new** refresh result iff A ≤ E5, else the
  previous one. No intermediate value exists (§5.7).
- These reads are side-effect free for the engine. They never select RAM, so
  they never delay a grant.
- Between a tick and its A the read returns the previous refresh's result
  (computed from counters one tick older).
- After reset and until the first refresh completes: 0.
- [added] The `d_out` paths are combinational and need no `access`
  (DPC:160-172, MC:140-143, MB:156-158): a read of AMPLITUDE returns it
  even before `lock_ctrl`, as long as `tia_en` routes `cart_2600_DB_out` to
  the bus (TOP:333). Before `tia_en` the 6507 cannot see it (§12.6).
- [added] A CDF amplitude fetch is a fast fetch, so it exists only in the
  operand cycle after an `LDA #` (CDFJ+: `LDX #`/`LDY #`) commit with fast mode
  on; after a call that operand is W+2, read after the release (§13.4).

---

## 15. Audio-relevant events relative to E0 [checked]

| Event | Edge |
|---|---|
| NOTE write ($1075-7) commit | E6; latched E7; earliest frequency write E10 (§9.3) |
| WAVEFORM write ($105D-F) commit | E6 (DPC:297-298); used by DPC+ sample grants at ≥ E7 |
| SETMODE commit (CDF $1FF2, BUS3 $1FF2, BUS1/2 $1019) | E6 (MC:243, MB:275-280); `digital_audio` new in (E6, E7); used at POINTER_CAPTURE edges ≥ E7. BUS1/2 store 0x00/0x0F so `bus_digital_audio` is 1 after any STUFFMODE write, but `digital_mode` needs revision 3 (AUD:104-108) |
| CALLFN write commit | E6; L = E7 if ready (§10.1) |
| [added] W+1 (opcode fetch after the CALLFN store) | runs, committed at its E6 (the stall's first shown `pclk0`); every held repeat keeps W+1's address, hidden (§10.1, simulated) |
| [added] Call return | X = S1+2 (`call_busy` low from (X, X+1)); merge M = X+1 (§10.3) |
| [added] Release window | X at E0 ... E5 of a held repeat: W+1's address committed again at that E6 |
| 6507 resumes after a call | no earlier than the first E0 ≥ M (§10.3); [added] that cycle is W+2 at its own address |
| AMPLITUDE read | value in (E5, E6) |
| Ticks | free-running, n_j from reset release (§3.3) |

---

## 16. Quirks to replicate

1. Fixed `CLK_RATE` on PAL: 19,817.57 Hz ticks (§3.3).
2. Ticks coalesce while a refresh/NOTE runs; counters still step (§5.2).
3. A tick at the dispatch edge: the refresh uses pre-tick counters, and a second
   refresh follows (AUD:230).
4. NOTE beats refresh in IDLE (AUD:227-229).
5. NOTE overlap table (§9.4).
6. DPC+ waveform registers, CDF/BUS3 digital flags read live mid-refresh
   (§5.8), including the digital switch that uses voice 1/2's pointer with
   counter 0.
7. Sum is mod 256 (AUD:324).
8. CDF0/1/J pointers alias mod 4 KiB with no window check; BUS/CDFJ+ fall back
   to offset 0 outside their windows; CDFJ+ wraps mod `mapper_ram_size`
   (§6.3-6.4).
9. Size shift is `word[11:7]` of the word at `audio_size_addr + 4v`, read only
   when the load-time scan found it (§6.2).
10. Digital nibble: bit set → low nibble (§5.6).
11. Digital out-of-range → amplitude 0 at DIGITAL_ROUTE (AUD:344-346).
12. Merge: counter taken only if it differs from the seed; frequencies always
    (§10.4). DPC+ ignores the return (§10.6).
13. Engine runs through pause with byte reads of 0xFF (§12.5).
    [corrected: unless the frozen 6507 cycle raises a select, in which case
    no grant comes for the whole pause.]
14. Engine reset is only `effective_reset`; a mapper change does not reset it
    (C26:762).
15. Idle port A address is 0 (AUD:132); the front ends see `RAM[0]` (or the
    engine's last ISSUE address) as stale data in their first selected clk.
16. No call gating: the engine reads RAM throughout calls. [corrected: the
    held cycle presents W+1's address, which selects nothing, so every in-call
    grant is immediate; the "W+2 substitution starves the engine" case does
    not exist (§10.1, §13.4).]
17. [added] Release window: a call that ends at E0 ... E5 of a held repeat
    makes the front end commit W+1's address twice (§10.1). Benign for DPC+,
    CDF and the engine; cancels a BUS3 fast jump or fast `STY` armed by W+1
    (§13.4).
18. [added] Launch and merge on the same edge (a CALLFN left pending during
    a call): new seeds and CTL payload take the pre-merge counters (§2).
19. [added] Pause freezes the 6507 but not the engine, and also stops the ARM
    (`mem_ce`), lengthening a call in progress (§12.5).

---

## 17. Guards a clone can add (per the user's rule: minimal cost, no desync) [corrected: verdicts re-done against the user's rule; G9 withdrawn]

The user's rule: implement a guard when it is cheap **and** cannot make the
clone fall out of sync with upstream. "Cannot desync" here means: no 6507-,
ARM- or tick-visible value or edge differs on any sequence a 6507 program can
produce.

| # | Hazard | Guard | Desyncs from upstream? | Verdict |
|---|---|---|---|---|
| G1 | NOTE overlap (§9.4) | in NOTE_CAPTURE, take the voice latched with the address at the grant, and keep `note_pending` if a strobe was sampled at g or g+1 | Only in rows 1-2 of §9.4, which no 6507 sequence reaches (§9.4; a pause or a call stops the 6507, so neither adds a strobe) | [corrected] **Implement** (rule satisfied: a few flops, no reachable difference). Replicating upstream is equally in sync. |
| G2 | ROM sample that never returns | timeout / re-issue on the clone's sample memory | No, as long as it can only fire where upstream's own bridge watchdog would (DDR:147-160; MEM:843-844) | **Implement**; values unaffected. |
| G3 | Digital ROM read beyond the image | clamp | No (upstream returns 0 / `rom_size` check, AUD:336, MEM:909-912) | Replicate the same checks; free. |
| G4 | Audio reads during 7800 mode (§12.6) | hold refresh while `!tia_en` | Yes: the refresh in flight at the switch and the first post-switch A edge move, and a 6507 read of AMPLITUDE between `tia_en` and the first clean refresh can differ | Do not add, unless the comparison excludes that window (§18 item 7). |
| G5 | Running through pause (§12.5) | freeze on pause | Yes, after every pause | Do not add. |
| G6 | Port A collision with ARM writes | — | Upstream already arbitrates by skipping the shared edge (§12.4) | A clone sharing one port must give the engine the RAM state "as of edge g"; any other arbitration changes what in-call refreshes read. Requirement, not a guard. |
| G7 | `sample_busy` orphaned by an engine reset | — | Upstream already waits for it (§7.3 item 5) | Replicate. |
| G8 | Dead `waveform_pointer`, 10-bit `sample_sum` | drop / narrow to 8 bits | No observable difference (`amplitude` uses `sample_sum[7:0]`, AUD:324; `waveform_pointer` is never read) | **Implement** (area saving). |
| G9 | [corrected: withdrawn] "Engine starved for a whole call when W+2 is a RAM substitution" | — | The hazard does not exist: the hold presents W+1's address (§10.1, §13.4) | Nothing to add. |
| G10 | [added] BUS3 release-window duplicate commit cancels a fast `JMP`/`STY` armed by W+1 (§13.4) | hide the held repeat's phi2 even after the release, or ignore a re-commit at the same address | **Yes**: the 6507 would then get the substituted jump target / the stuffed byte where upstream gives the literal operand / the unstuffed one, about half the time | Do not add (front-end matter; flag for `bus.md`). |
| G11 | [added] Launch sampled at M (§2) seeds from pre-merge counters | seed from the post-merge values | Yes, for an RMW CALLFN (reachable by a program) | Do not add; replicate. |
| G12 | [added] Late-L starvation (§13.4 corner) | let the engine through during the hold | Only in a case normal code never reaches, but then it moves every in-call A edge | Not needed; replicate (same cost). |
| G13 | [added] Pause boundary stale byte lane (§5.3) | register the lane on every grant regardless of `pause` | Yes, on a capture straddling a pause release | Do not add; replicate `mapper_read_lane`'s `!pause` enable. |

## 18. Open questions [answered where the RTL settles them]

1. **`STATE_FIQ_R8`.** Its value lives in `arm7tdmi/` (not read). The write
   side uses literal indices 17-22, the read side `STATE_FIQ_R8 + 0..5`; the
   mapping to FIQ r8-r13 is inferred from that symmetry and from
   `docs/DARIA_CORE.md:57-58`.
   **[partly settled]** Not provable from the allowed files. Added
   corroboration (§10.2): DARIA_CORE.md:390,479 record call-by-call equality of
   DARIA's FIQ r8-r13 with upstream's returned audio values on 21 images, and
   a value other than 17 would make every untouched counter look "changed".
   Treat 17 as established for cloning; it stays formally an inference.
2. **Call duration.** The merge edge M, and every counter value after a call,
   depends on the ARM's run time and `arm_host`'s `state_ready` timing (23
   writes + 6 reads) — not derivable from these files. Per-tick equality after
   a call needs the clone's call to end at the same clk_sys edge (or the
   comparison must re-align after each call).
   **[not settled; fixed part added]** What CTL fixes: L flips `call_toggle`;
   `call_sync2` is new after the 2nd `clk_arm` edge after L and CTRL_IDLE
   accepts at the 3rd if `cpu_halted`, `shadow_ready`, `sys_online_sync2` and
   the previous completion's ack hold (CTL:264-265, 284-304); then 23
   `state_ready`-paced writes, COMMIT and RELEASE (1 `clk_arm` each,
   CTL:317-318), the ARM's run, RETURN_HALT until `cpu_halted`, 6 x (wait
   `state_ready`, 1 capture clk), and from the last capture edge c: X = S1+2,
   M = X+1 (§10.3). Everything else (`state_ready`, `cpu_halted`, run time) is
   in `arm7tdmi/`. Recommendation for the comparison: either the clone's call
   ends at upstream's X (identical duration), or the bench drives the clone's
   engine with upstream's recorded L, X and return values and compares the
   rest; after a call with a different X, counters (§10.5), tick-vs-E0 phase
   and every later A edge legitimately differ.
3. **DDR3 latency on MiSTer** for ROM-sample misses is set by the framework
   and the HPS and is not deterministic; only hits (A = R+4) are cycle-exact.
   What latency should the Pocket clone's sample path model (PSRAM)?
   **[not settled; recommendation]** Reproduce the hit and out-of-range path
   exactly (A = R+4, one 8-byte entry tagged `addr[24:3]`, invalidated only by
   a new load or `reset_arm`, MEM:691,739-745,908-922), and treat a miss as
   "A = S1+3 after the read data arrives" with S1 from the clone's own memory.
   Misses occur when the sample address leaves the cached 8-byte word (every
   2^24 of `counter0`, CDFJ+ 2^16, or on a pointer change). A bench comparing
   against upstream should replay upstream's recorded `ddr_rvalid` edge for
   each miss; real MiSTer captures cannot be matched at miss refreshes.
4. **`rom_do` arrival time** on MiSTer (wrapper, not in repo) sets the
   fast-fetch/substitution select windows that block grants (`cdf.md` OQ 1,
   `dpcplus.md` §12.2), and so the exact A edge.
   **[not settled; scope corrected]** It sets only the per-cycle windows of
   fast-fetch / fast-jump operand cycles (including W+2 after a call). It no
   longer sets the start of any in-call starvation: there is none (§13.4).
5. **Reset origin.** The MiSTer wrapper's `reset` (download, OSD) is not in
   the repo; the tick phase is counted from the last posedge with
   `effective_reset` high. A clone must release at the same edge.
   **[in-core part settled, §3.4]** n = 1 is the edge after the one that
   clears `reset_hold` (a `pclk1` edge, or P+3 after a `pclk0` edge on the
   bypassed path). The wrapper's `reset`, and whether it is held during RAM
   init (`mapper_init_busy` is a TOP output, TOP:110), remain outside.
6. **Pause in the comparison**: upstream's engine keeps stepping through
   pauses; is pause part of the comparison runs?
   **[behaviour settled, policy open]** §12.5 now gives the full behaviour:
   counters step, the ARM stops, the 6507 freezes mid-cycle with its selects
   live (no grants at all if the frozen cycle selects), bytes read 0xFF, the
   lane register freezes. Replicable exactly; whether runs include pauses is
   the bench owner's call.
7. **7800-mode reads** (§12.6): is equality of `amplitude` required before the
   first post-lock refresh?
   **[partly settled]** Counters and frequencies are 0 on both sides until
   `lock_ctrl && tia_en` (no commits before it), so they need no special
   handling. `amplitude` is invisible to the 6507 before `tia_en` (TOP:333).
   Recommendation: compare `amplitude` from the first refresh whose every
   grant has `tia_en || mapper_init_busy` high; a clone that drives the same
   shared RAM port from the 7800 path gets equality earlier for free.
8. **PAL tick rate** (19.82 kHz) — intended upstream, or an omission? The clone
   should copy it for sync either way.
   **[partly settled]** AUD has no region input and the instance overrides
   nothing (C26:760-801), so 19,817.57 Hz on PAL is what upstream does. The
   same author made the ARM timer region-aware (MEM:477-488, `pal` input, C26
   `pal`), which suggests the audio omission is unintended; not provable.
   Copy it.
9. **Size-word bits [11:7].** Taken from RTL as written; no in-repo source
   explains the encoding, so a clone must not "fix" it.
10. **Which cycle the call stall holds.** From the CPU RTL (`hold = ~rdy_cy &
    ~wr_q`, `6502/mos6502_ctl.sv:874-880,1394`) the cycle after the CALLFN
    store (W+1) cannot be held and W+2 is held; `dpcplus.md` §8.3 agrees. The
    comment at TOP:309-320 and `cdf.md` §15 item 5 say W+1 (the fetch) is
    held. It decides whether the engine is starved for a whole call after
    `STA CALLFN / LDA #<stream>` (W+2 held: yes; W+1 held: no). This spec
    follows the RTL; confirm by simulating that sequence.
    **[settled by simulation, §10.1]** Both readings are half right. The CPU
    holds W+2's T-state, but a held cycle never loads its address
    (`hold_mask` clears `adl_abl`, `mos6502_ctl.sv:936-958`; ABL/ABH load only
    at `phi1_en`, `mos6502_dp.sv:202,225-226`), so the bus keeps **W+1's
    address** for the whole hold and W+2's address appears only after the
    release. What the front end sees is therefore exactly TOP:309-319's
    diagram and `cdf.md` §15: W+1 taken once, its repeats hidden, the operand
    taken after the stall. **The engine is not starved** after `STA CALLFN;
    LDA #<stream>` (§13.4). `dpcplus.md` §8.3 should be corrected the same way.
11. ~~**Fast-fetch operand arrival inside W+2** sets the clk at which the
    starvation of §13.4 begins.~~ [corrected: withdrawn; there is no in-call
    starvation. W+2's operand arrival only sets W+2's ordinary post-call
    select window (item 4).]
12. [added] **`EXTERNAL_CARTRAM`** (settled, §12.6): the word path and the
    whole ARM port B are tied off (TOP:937-942), so upstream's engine and ARM
    mapper cannot work in that build; the clone needs its own console-side
    32-bit word read with port A's timing and the §5.3 lane rule.
13. [added] **BUS3 release window** (§13.4): a call that ends at E0-E5 of a
    held repeat cancels a fast `JMP` or fast `STY` that W+1 armed. Upstream
    behaviour, reachable about half the time after such a pair; to be carried
    into `bus.md` and replicated.
