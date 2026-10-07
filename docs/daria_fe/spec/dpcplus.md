# DPC+ front end: cycle-exact behavioural spec of upstream `mapper_dpcplus`

Target: a clone of upstream's DPC+ 6507-side front end that matches it at every
6507 latch edge, at every commit and at every audio tick.

Sources, all under `src/fpga/mister/rtl/` (upstream MiSTer Atari7800 rtl,
`../UPSTREAM_COMMIT` = ffc47192a58e4ead08919bd1e4ce984df138fcb2). File:line
references are relative to that directory unless they start with `core/`
(= `src/fpga/core/`). Main files:

- `mapper_dpcplus.sv` (the front end, 326 lines; abbreviated **DPC** below)
- `cart2600.sv` (instance at 803-839 and the surrounding wiring; **C26**)
- `top.sv` (bus, clocks, stall; **TOP**), `6502/*.sv` (CPU model),
  `TIA.sv`, `Maria/maria.sv`, `arm_mapper_audio.sv`, `arm_mapper_controller.sv`,
  `arm_mapper_memory.sv`, `arm_mapper_ram_init.sv`, `cart_ram_tdp.sv`,
  `cache_ram.v`, `detect2600.sv`, `sdram.sv`.

Build assumed: `NO_ARM_MAPPER` **not** defined. With `NO_ARM_MAPPER` (the
Pocket build, `ap_core.qsf:736`) the front end is not instantiated: DPC+ gets
the bad-game screen (C26:158-163, C26:585-650).

**Review status.** This file was re-checked line by line against the RTL by an
adversarial reviewer. Markers: **[checked]** = the claim was verified as
written; **[corrected: ...]** = the claim was wrong or imprecise and has been
fixed (the bracket says what changed); **[added]** = new material. §17 records
a ROM-free directed simulation (the real `6502/` model + upstream
`mapper_dpcplus.sv`, with the TOP/cart2600 glue for phases, stall,
`mapper_phi2`, `access_taken` and the RAM strobe transcribed into a bench) that
was run for this review; its results overturned the original S1 and refined S2
and the hold semantics in §0.2.

---

## 0. Conventions and clocking

### 0.1 Edge names [checked]

- `clk_sys` = 14.318182 MHz NTSC (`pll/pll_0002.v:39`); MiSTer retunes it to
  14.18758 MHz for PAL (`../POCKET_CHANGES.md:123-124`). All front-end state is
  on `posedge clk` = clk_sys (C26:804, TOP:1131).
- **E0** = the clk_sys posedge at which `pclk1` (the 6507 phase-1 enable,
  TOP `phi1_ce`, TOP:1421,1434) is sampled high. **Ek** = E0 + k clk_sys
  posedges. **(Ek,Ek+1)** = the clk_sys period after posedge Ek. A
  combinational signal "in (E5,E6)" is what posedge E6 samples. `pclk1` and
  `pclk0` are one-clk pulses (`phi1_en = pclk1 & ~in_phase2`,
  `phi2_en = pclk0 & in_phase2`, TOP:1420-1427).
- In 2600 mode the 6507 cycle is 12 clk_sys long: `pclk0` (phase-2 enable)
  is sampled at **E6** and the next `pclk1` at **E12** (= next cycle's E0).
  Derivation: MARIA pulses `mclk0` on every second clk_sys
  (`Maria/maria.sv:158,166,197-199`); `tia_clk_x2 = tia_clk_en && mclk0`
  (`Maria/maria.sv:153-154`) is the TIA's `ce` (TOP:490); the TIA steps
  `pclk_div` once per `ce` (`TIA.sv:498-499,556-557`) and makes phase-1 at
  `pclk_div==5`, phase-2 at `pclk_div==2` (`TIA.sv:505-506`), i.e. 3 `ce` =
  6 clk_sys apart in each direction. Exceptions: RSYNC reloads `pclk_div`
  (`TIA.sv:565-566`) and reset (`resp0` term, `TIA.sv:506`). The front end
  is only active after the 2600 lock (§2), when the TIA is (or is about to
  become) the phase source (TOP:259-260, 397-411).
- [added] MARIA's own phases are also 6/6 once `maria_en=0`
  (`sel_slow_clock` forced to 1, `Maria/control.sv:64`; reload 2 → 3 `mclk1`
  = 6 clk_sys per half, `Maria/maria.sv:213-221`). The MARIA→TIA source
  handoff that the lock write triggers (`phase_source_request_tia`,
  TOP:259-260; `cpu_phase_controller`, TOP:1230-1347) can produce one half
  cycle of another length, and RSYNC does too. Every "Ek" statement below
  assumes the regular 6/6 spacing; a comparison bench should key E0/E6 on the
  `pclk1`/`pclk0`/`mapper_phi2` pulses themselves, not on a fixed count.

### 0.2 What the 6507 does at each edge (CPU model, not the front end)

- [checked] AB and R/W change at **E0**: `abl/abh` load on `phi1_en`
  (`6502/mos6502_dp.sv:202,225-226`); `wr_pin <= c.wr` on `phi1_en`
  (`6502/mos6502.sv:129-133`), `rw_n = ~wr_pin` (`6502/mos6502.sv:137`);
  `RW = cpu_RW_oe ? cpu_rwn : 1` (TOP:377).
- [checked] Write data: DOR loads at **E0** (`6502/mos6502_dp.sv:228`); the
  cart's `d_in` is `RW ? read_DB : write_DB` (TOP:1112), so on a write cycle
  `d_in` is the store byte from (E0,E1) to (E11,E12).
- [checked] Read data is latched at **E6**: `dl <= data_in` under `phi2_en`
  (`6502/mos6502_dp.sv:267,299`), `data_in = RD ? DB_IN : DB_OUT`
  (TOP:1450), `DB_IN = read_DB` (TOP:721), and `read_DB` takes the cart's
  `d_out & oe` combinationally when `cs_cart && (cart_present || bios_sel)`
  (TOP:391-393; with `maria_en=0` every `AB[12]=1` address is `cs_cart`,
  `Maria/control.sv:96-100`). **The 6507 takes the cart byte that stands in
  (E5,E6).** `dl` is overwritten at every `phi2_en`, held repeats included,
  so a held cycle keeps only the byte of its completing pass.
- [checked] RDY is sampled once per cycle, at E0 (`rdy_cy`, `rdy_q`:
  `6502/mos6502_ctl.sv:874-881`): the cycle whose E0 samples RDY low is held,
  unless the previous cycle was a write (`hold = ~rdy_cy & ~wr_q`, `wr_q <=
  c.wr` at every `phi2_en`: `6502/mos6502_ctl.sv:856-876,1394`). So the cycle
  right after a write is never held. `phi2_en` (and so `pclk0`) still pulses
  in every held repeat (TOP:1421-1422,1435).
- [corrected: the original said "a held (repeated) read cycle keeps its
  address"; it does not show its own address at all] **A held cycle
  re-presents the address of the last completed cycle.** `hold_mask`
  (`6502/mos6502_ctl.sv:936-954`, applied through `c_pre`, :957-958) clears
  `adl_abl` and `wr` and lets `adh_abh` through only on the indexed
  hold-carry path, so at the held cycle's E0 ABL (and normally ABH) are not
  reloaded: every held repeat is a **read of the previous cycle's address**.
  The held cycle's own address appears only in its completing pass (the
  first E0 that samples RDY high), which then loads it normally. Example
  (sim, §17): `STX $105A` (W) → W+1 = opcode fetch at A → held repeats at A
  → completing pass at A+1. TOP's comment ("the cycle that stalls is the
  following instruction fetch", TOP:298-305) describes this bus view; the
  CPU comment (`6502/mos6502_ctl.sv:861-866`) describes the internal state. Both hold.

### 0.3 The commit edge [checked]

The front end changes state only at a posedge where `access` is high
(DPC:227). `access` = `mapper_phi2 && lock_ctrl && tia_en` (C26:247,806;
TOP:1135-1136), and `mapper_phi2` is `pclk0` minus the pulses the ARM-stall
mask hides (TOP:327). So the commit edge is **E6**, the same posedge at which
the 6507 latches read data. **The 6507 always receives the pre-commit
`d_out`; the committed state is visible on `d_out` from (E6,E7) on.**

---

## 1. Ports and wiring in cart2600 [checked]

Instance: C26:803-839.

| Port (DPC:8-45) | Connected to | Source / sink and notes |
|---|---|---|
| `clk` | `clk` (clk_sys) | C26:804 |
| `reset` | `reset \|\| mapper != BANKDPCP` | C26:805. `reset` = TOP `effective_reset = reset \| reset_hold` (TOP:255,1130). `mapper` = `\|mapper ? mapper : force_bs` (TOP:1138). [added] Where the user override enters is wrapper-specific: the Pocket wrapper ties TOP's `mapper` to 0 and substitutes the override into `force_bs` (`core/atari7800_pocket.sv:1047,1060`); either way `mapper_revision` is the detector's (`core/atari7800_pocket.sv:1048`, TOP:1139). |
| `access` | `arm_access = phi2 && arm_driver_run` | C26:247,806. `phi2` = TOP `mapper_phi2` (TOP:1134-1135, 327). `arm_driver_run` = `lock_ctrl && tia_en` (TOP:1136). |
| `rw` | `RW` | TOP:1129, 377 |
| `a_in[12:0]` | `{AB[12] & bios_en_b, AB[11:0]}` | TOP:1128. Only `a_in[12]` and `a_in[11:0]` are decoded. |
| `d_in[7:0]` | `cart_din = RW ? read_DB : write_DB` | TOP:1112,1125 |
| `rom_data[7:0]` | `rom_do` = TOP `cart_out` | C26:810, TOP:1147, TOP:86 (a TOP input). Supplied by the wrapper; see §4.3 and §16 Q1 for its timing. |
| `stable_fractional` | `mapper_revision[0]` | C26:811, TOP:1139 (§10) |
| `d_out` | `direct_do[BANKDPCP]` | C26:812 |
| `flags_out[15:0]` | `flags_out[BANKDPCP]` | C26:813. Only bit 0 is ever set (DPC:130,161). |
| `oe[7:0]` | `out_en[BANKDPCP]` | C26:814 |
| `rom_a[18:0]` | `rom_addr[BANKDPCP]` | C26:815; output `rom_a` is not masked for DPC+ (C26:195-197); TOP sends it out as `cart_addr_out[18:0]` with bits 24:19 = 0 (TOP:1108,1149,332). |
| `ram_sel`, `ram_rw`, `ram_a[17:0]` | `ram_sel/ram_rw/ram_a[BANKDPCP]` | C26:816-818 → `sel_ram_*` (C26:190-192) → cart RAM port (C26:965-978). |
| `ram_data[7:0]` | `cartram_data` | C26:819; TOP: `cartram_data_bram = pause ? FF : cartram_data_tdp` (TOP:936). |
| `amplitude[7:0]` | `arm_audio_amplitude` | C26:820, from `arm_mapper_audio` (C26:800). |
| `audio_waveform0..2[6:0]` | `dpc_audio_waveform0..2` | C26:821-823 → `arm_mapper_audio` (C26:770-772) |
| `audio_note_write/voice/value` | `dpc_audio_note_*` | C26:824-826 → `arm_mapper_audio` (C26:773-775) |
| `call_request/entry/stack/thumb` | `dpc_call_*` | C26:827-830 → `arm_call_*` when `mapper == BANKDPCP` (C26:945-953) → `arm_mapper_controller` (C26:474-477) |
| `call_ready` | `mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy` | C26:831, 661-662 |
| `service_request` | `dpc_service_request_raw` | C26:832; gated `&& mapper == BANKDPCP` (C26:657); muxed to the one DMA engine when `!mapper_init_busy` (C26:416-417) |
| `service_fill/source/dest/count/value` | `dpc_service_*` | C26:833-837 → `arm_dma_*` with zero-extension (C26:418-425) |
| `service_ready` | `dpc_service_ready = !mapper_init_busy && arm_dma_ready` | C26:838, 428; `arm_dma_ready = shadow_ready_sync2 && !dma_busy` (`arm_mapper_memory.sv:228`) |

Other DPC+-specific wiring:

- Audio family for DPC+ = 1 (`init_family`, C26:658-660), passed to
  `arm_mapper_audio` with `revision = mapper_revision[1:0]` (C26:763-764).
  The family-1 audio paths never read `revision` (`arm_mapper_audio.sv:99-157,
  225-333`).
- RAM-init family for DPC+ = 1 (C26:708-737) (§9.4).
- The call-controller audio payload is `arm_audio_counter0..2` /
  `arm_audio_frequency0..2` from `arm_mapper_audio` (C26:478-483, 784-789).
- `arm_call_busy`, `arm_dma_busy` go out to TOP and stall the 6507
  (C26:110-111, 466, 485; TOP:306-307) (§8).
- [added] C26 also emits `rom_read = ~address_change` for DPC+ (C26:157),
  TOP's `cart_read` in 2600 mode (TOP:331). It is the wrapper's ROM read
  request (§4.3).

---

## 2. When the front end is allowed to change state

- [checked] **Every** state change except reset, the two pending-flag clears
  and the note-strobe default is inside `if (access && a_in[12])` (DPC:227).
- `access` is high in (E5,E6) of a 6507 cycle only if all hold:
  - `pclk0` (E6 of the cycle) (TOP:327).
  - [corrected: not only "hidden repeats"; a completed cycle can be hidden
    too, §13 S5] Not masked by the ARM stall: `!arm_call_stall ||
    !stall_cycle_taken` (TOP:321-327; §8.3).
  - `lock_ctrl && tia_en` (TOP:1136): the INPTCTRL lock and TIA-enable bits,
    written together by the BIOS's lock write (`~latch_b && cs && pclk0`,
    TOP:1383-1389) or, [corrected: not "at reset"] with `bypass_bios`, set on
    the first clk after `effective_reset` falls (`lock = tia_en = tia_mode`,
    TOP:1376-1382). Before that the front end is inert, but its
    combinational outputs (d_out, ram_sel, rom_a) still follow the bus.
- [checked] Accesses with `a_in[12] = 0` (TIA, RIOT, RAM, zero page) never
  commit, whatever `access` is (DPC:227).
- [checked] Every clk, regardless of `access` (DPC:221-225):
  - `audio_note_write <= 0` (so the note strobe is a one-clk pulse).
  - `call_pending <= 0` if `call_pending && call_ready`.
  - `service_pending <= 0` if `service_pending && service_ready`.

[checked] Reset (`reset` input high at a posedge) is synchronous and
overrides all (DPC:194-219).

---

## 3. State and reset values [checked]

All registers are reset by `reset || mapper != BANKDPCP` (C26:805), so a
console reset (including the `reset_hold` phase-alignment tail, TOP:255,
264-286) **or** any change of the selected mapper away from DPC+ clears them,
and they stay cleared while another mapper is selected (also during a load:
`force_bs <= BANK00` at `load_start`, `detect2600.sv:206-207`).

| State | Width | Reset value | Line |
|---|---|---|---|
| `bank` | 3 | 5 | DPC:195 |
| `top[0..7]` | 8 | 0 | DPC:197 |
| `bottom[0..7]` | 8 | 0 | DPC:198 |
| `counter[0..7]` | 12 | 0 | DPC:199 |
| `fractional[0..7]` | 20 | 0 | DPC:200 |
| `increment[0..7]` | 8 | 0 | DPC:201 |
| `params[0..7]` | 8 | 0 | DPC:202 |
| `waveform[0..2]` | 7 | 0 | DPC:204-205 |
| `random_number` | 32 | `0x2B435044` ("DPC+" little-endian) | DPC:206 |
| `fast_fetch` | 1 | 0 | DPC:207 |
| `fast_pending` | 1 | 0 | DPC:208 |
| `parameter_pointer` | 4 | 0 | DPC:209 |
| `call_pending` | 1 | 0 | DPC:210 |
| `service_pending` | 1 | 0 | DPC:211 |
| `service_fill/source/dest/count/value` (output regs) | 1/19/15/8/8 | 0 | DPC:212-216 |
| `audio_note_write/voice/value` (output regs) | 1/2/8 | 0 | DPC:217-219 |

There is no other state. `amplitude` belongs to `arm_mapper_audio` and is
reset by cart2600's `reset` only, not by the mapper selection
(C26:762; `arm_mapper_audio.sv:163-189`). [added] The call controller's
`call_busy` is cleared by cart2600's `reset` (`mapper_reset_sys`,
`arm_mapper_controller.sv:144-147`); the DMA engine's `dma_busy` is cleared
only by `reset_arm` (`arm_mapper_memory.sv:235,269`).

Constant outputs: `call_entry = 0x00000C08`, `call_stack = 0x40001FFC`,
`call_thumb = 1` (DPC:184-186).

---

## 4. Combinational decode (DPC:79-190) [checked]

Everything here is a pure function of `a_in`, `rw`, `rom_data`, `ram_data`,
`amplitude` and the current state. It is **not** gated by `access`.

### 4.1 Register read detect [checked]

```
register_read = rw && a_in[12] &&
                ( a_in[11:0] < 0x028 ||
                  (fast_fetch && fast_pending && rom_data < 0x28) )      DPC:113-115
register_address[5:0] = (a_in[11:0] < 0x028) ? a_in[5:0] : rom_data[5:0] DPC:120
read_index    = register_address[2:0]                                    DPC:121
read_function = register_address[5:3]                                    DPC:122
ram_register_read = register_read && read_function in {1,2,3}            DPC:123-124
```

- A direct address `< $028` takes priority over the fast-fetch operand
  (DPC:120).
- The register address is 6 bits, so a fast-fetch operand `$20-$27` reaches
  DFxFLAG (DPC:116-119). `read_function` is 0..4 on both paths; 5..7 are
  unreachable (the `default: d_out = 0`, DPC:178).

### 4.2 Window flag [checked]

```
window_set[i] = ((top[i] - counter[i][7:0]) mod 256) > ((top[i] - bottom[i]) mod 256)   DPC:107-110
window_flag   = window_set[read_index] ? 0xFF : 0x00                                    DPC:125
```

All operands are 8 bits, so both differences are 8-bit modular and the compare
is unsigned 8-bit (SV relational operands sized to the wider side, 8). Only
`counter[i][7:0]` takes part. The flag is from the **current** (pre-commit)
counter.

### 4.3 ROM address, output enable and ROM read strobe

```
rom_a = 3072 + bank*4096 + a_in[11:0]   (19 bits)      DPC:127-128
oe    = a_in[12] ? 0xFF : 0x00                          DPC:129
```

[checked] `rom_a` is computed for every access, including register reads,
fast-fetch operands and `a_in[12]=0` cycles. It always uses the current
`bank`. The image layout this implies: bank b = image bytes
`0x0C00 + b*0x1000 .. +0xFFF` (banks 0-5 = `0x0C00-0x6BFF`). `bank` only
ever holds 0..5 (§6.1).

[added] The ROM read request is `rom_read = ~address_change` (C26:157,
`address_change = old_ain != a_in`, C26:241,263-265): low only in the clk
(E0,E1) after `a_in` changes. The vendored `sdram.sv` starts a read on the
**rising edge** of its `rd` (`sdram.sv:95`), and serves a read of the same
16-bit word as its previous read from its holding register without an SDRAM
access (`sdram.sv:101,187,193`). So, on any ROM path built that way (the
Pocket's is, `core/atari7800_pocket.sv:394-401`; MiSTer's wrapper is not
vendored), `rom_do` is **not refetched when only `rom_a` changes**: a bank
switch at E6 is not reflected in `rom_do` until the next `a_in` change. The
6507 cannot see this except when the same `a_in` is presented again after a
bank switch (a re-presented hotspot read, §0.2/§13). A clone's ROM model in a
comparison bench must be the same on both sides.

### 4.4 Cart RAM port (console side) [checked]

Defaults: `ram_sel=0`, `ram_rw=1`, `ram_a=0` (DPC:132-134).

| Condition | `ram_sel` | `ram_rw` | `ram_a` | Line |
|---|---|---|---|---|
| `ram_register_read`, fn 1 or 2 (DFxDATA, DFxDATAW) | 1 | 1 | `0x0C00 + counter[read_index]` | DPC:137-143 |
| `ram_register_read`, fn 3 (DFxFRACDATA) | 1 | 1 | `0x0C00 + fractional[read_index][19:8]` | DPC:137-143 |
| else `!rw && a_in[12] && a_in[11:0] in $060-$067` (DFxPUSH) | 1 | 0 | `0x0C00 + ((counter[a_in[2:0]] - 1) mod 4096)` | DPC:144-154,157 |
| else `!rw && a_in[12] && a_in[11:0] in $078-$07F` (DFxWRITE) | 1 | 0 | `0x0C00 + counter[a_in[2:0]]` | DPC:144-146,155-157 |
| otherwise | 0 | 1 | 0 | DPC:132-134 |

`ram_a` is 18 bits; all reachable values are `0x0C00-0x1BFF`. DFxHI
($068-$06F) and $070-$077 never select RAM (DPC:147-150). Reads of
$060-$07F select nothing (the write branch needs `!rw`). The write branch is
not gated by `access`, so it stands from (E0,E1) to (E11,E12) of the write
cycle (and even pre-lock).

### 4.5 d_out and flags_out [checked]

`d_out = 0`, `flags_out = 0` unless `register_read` (DPC:130-131). When
`register_read`, `flags_out[0] = 1` and (DPC:160-180):

| `read_function` | `read_index` | d_out |
|---|---|---|
| 0 | 0 | `random_next[7:0]` |
| 0 | 1 | `random_prior[7:0]` |
| 0 | 2 | `random_number[15:8]` |
| 0 | 3 | `random_number[23:16]` |
| 0 | 4 | `random_number[31:24]` |
| 0 | 5 | `amplitude` |
| 0 | 6, 7 | `0x00` |
| 1 | i | `ram_data` |
| 2 | i | `ram_data & window_flag` |
| 3 | i | `ram_data` |
| 4 | 0..3 | `window_flag` |
| 4 | 4..7 | `0x00` |

### 4.6 What cart2600 puts on the bus (C26:211-234) [checked]

DPC+ is not `is_bad_game` in this build (C26:165-166). With `sel_out_en = oe`:

- `a_in[12] = 0`: `d_out = 0`, `oe = 0` (cart not driving).
- `a_in[12] = 1` and `flags_out[0]` (register read): `d_out = direct_do`
  (the front end's `d_out`), `oe = 0xFF` (C26:218-220).
- `a_in[12] = 1`, no register read, `ram_sel = 1` (only on a PUSH/WRITE
  write cycle, so `ram_rw = 0`): `d_out = 0`, `oe = 0` (C26:224-228).
  Irrelevant to the 6507 (write cycle), but it is what the mux says.
- otherwise: `d_out = rom_do`, `oe = 0xFF` (C26:229-231).

So a DPC+ cart drives all 8 lines on every read of $1000-$1FFF; $006/$007 and
$024-$027 read as `$00`, never open bus. TOP merges with `open_bus` only
where `oe` is clear, and only reads the slot when `cart_present` (TOP:391-393).

---

## 5. The LFSR (random number) [checked]

```
random_next  = ROR32(r, 11) ^ (r[10] ? 0x10ADAB1E : 0)                     DPC:79-80
x            = r[31] ? (r ^ 0x10ADAB1E) : r                                 DPC:81-82
random_prior = ROL32(x, 11)                                                 DPC:83-84
```

`random_prior(random_next(r)) == r`: ROR11 puts `r[10]` at bit 31, and
`0x10ADAB1E[31] = 0`, so the next value's bit 31 says whether the constant was
applied.

When it steps: only at a committed read with register address $00 or $01
(direct or fast fetch) (DPC:237-243). The byte the 6507 latches at E6 is
`random_next[7:0]` / `random_prior[7:0]` computed from the pre-commit `r`,
i.e. **the low byte of the stepped value**; at the same E6 `random_number`
takes that stepped value. There is no read of byte 0 without stepping.
$02-$04 return bytes 1-3 of the current value with no step.

Writes (§6.3): $070 RRESET → `0x2B435044`; $071-$074 RWRITE0-3 replace byte
0..3 (DPC:306-310).

---

## 6. Commit rules (posedge with `access && a_in[12]`, DPC:227-322)

### 6.1 Bank hotspots (reads and writes) [checked]

`if (!register_read && a_in[11:0] in [$FF6, $FFB]) bank <= a_in[2:0] - 6`
(3-bit arithmetic) (DPC:230-232): $FF6→0, $FF7→1, $FF8→2, $FF9→3, $FFA→4,
$FFB→5. Applies to read **and** write cycles (the test is outside
`if (rw)`).

Ignored when:
- the cycle is a register read, which for these addresses can only be a
  fast-fetch operand (`fast_fetch && fast_pending && rom_data < $28`)
  (DPC:228-230);
- `access` is low (pre-lock, masked by the ARM stall).

The byte the 6507 reads from a hotspot is from the **old** bank (`rom_a` uses
pre-commit `bank`); `rom_a` moves to the new bank in (E6,E7) (and `rom_do`
follows only as §4.3 allows).

### 6.2 Read cycles (`rw = 1`) [checked]

If `register_read` (DPC:235-249):
- `fast_pending <= 0`
- fn 0: index 0 → `random_number <= random_next`; index 1 →
  `random_number <= random_prior`; 2..7 no effect.
- fn 1, 2: `counter[i] <= counter[i] + 1` (12-bit wrap, $FFF → $000).
- fn 3: `fractional[i] <= fractional[i] + {12'b0, increment[i]}` (20-bit
  wrap).
- fn 4: no effect.

Else (a ROM read at $028-$FFF) (DPC:250-252):
- `fast_pending <= fast_fetch && rom_data == 0xA9`.

### 6.3 Write cycles (`rw = 0`), $028-$07F only (DPC:253-322) [checked]

Group `g = (a_in[11:0] - 0x028) >> 3`, index `i = a_in[2:0]` (0x028 is a
multiple of 8). Data is `d_in` as it stands in (E5,E6).

| Addr | g | Name | Effect at E6 | Line |
|---|---|---|---|---|
| $028-$02F | 0 | DFxFRACLOW | `fractional[i] = (fractional[i] & M) \| (d << 8)`, `M = stable_fractional ? 0xF0000 : 0xF00FF`. Bits 15:8 = d; 19:16 kept; 7:0 cleared if `stable_fractional`, kept otherwise. | DPC:255-258 |
| $030-$037 | 1 | DFxFRACHI | `fractional[i] = {d[3:0], fractional[i][15:0]}` (d[7:4] ignored) | DPC:259-260 |
| $038-$03F | 2 | DFxFRACINC | `increment[i] = d`; `fractional[i][7:0] = 0` (19:8 kept) | DPC:261-265 |
| $040-$047 | 3 | DFxTOP | `top[i] = d` | DPC:266 |
| $048-$04F | 4 | DFxBOT | `bottom[i] = d` | DPC:267 |
| $050-$057 | 5 | DFxLOW | `counter[i][7:0] = d` (11:8 kept) | DPC:268 |
| $058 | 6 | FASTFETCH | `fast_fetch = (d == 0)` | DPC:271 |
| $059 | 6 | PARAMETER | if `parameter_pointer < 8`: `params[ptr[2:0]] = d`, `ptr++`; else ignored (pointer saturates at 8) | DPC:272-277 |
| $05A | 6 | CALLFUNCTION | §8 | DPC:278-296 |
| $05B-$05C | 6 | — | nothing | DPC:299 |
| $05D-$05F | 6 | WAVEFORM0-2 | `waveform[a[1:0]-1] = d[6:0]` (a[1:0] = 1,2,3 → voice 0,1,2) | DPC:297-298 |
| $060-$067 | 7 | DFxPUSH | `counter[i] = counter[i] - 1` (12-bit wrap); RAM byte written at `0x0C00 + counter[i]-1` by cart2600 (§9) | DPC:302, 153-154 |
| $068-$06F | 8 | DFxHI | `counter[i][11:8] = d[3:0]` | DPC:303 |
| $070 | 9 | RRESET | `random_number = 0x2B435044` | DPC:306 |
| $071-$074 | 9 | RWRITE0-3 | `random_number[8k+7:8k] = d`, k = a-$071 | DPC:307-310 |
| $075-$077 | 9 | NOTE0-2 | `audio_note_write = 1` (one clk, (E6,E7)), `audio_note_voice = a[1:0]-1` (0,1,2), `audio_note_value = d` | DPC:311-315 |
| $078-$07F | 10 | DFxWRITE | `counter[i] = counter[i] + 1`; RAM byte written at `0x0C00 + counter[i]` (pre-increment) by cart2600 | DPC:319, 155-156 |

Writes to $000-$027, $080-$FF5 and $FFC-$FFF change nothing; a write to
$FF6-$FFB switches the bank (§6.1). Write cycles never touch `fast_pending`
(DPC:234-253). (Sim §17 test 3 confirms PUSH/WRITE land once each at the
addresses above, with no stray write at the stepped address.)

---

## 7. Fast fetch (LDA #imm redirection) [checked]

State: `fast_fetch` (enable, written by $058) and `fast_pending` (armed flag).

Transitions, all at a commit edge (E6) of a cartridge access
(`access && a_in[12]`):

| Committed access | `fast_pending` next |
|---|---|
| read, `register_read` (direct $000-$027 **or** fast-fetch operand) | 0 (DPC:236) |
| read, not a register read (ROM byte at $028-$FFF) | `fast_fetch && rom_data == $A9` (DPC:251) |
| write (any cart address) | unchanged |
| any `a_in[12]=0` access, or not committed (`access` low) | unchanged |

A read is consumed as a fast-fetch operand when, combinationally,
`rw && a_in[12] && a_in[11:0] >= $028 && fast_fetch && fast_pending &&
rom_data < $28` (DPC:113-115). Then `register_address = rom_data[5:0]`,
the read behaves exactly as a direct read of that register (d_out, RAM
address, side effects, §4.5/§6.2), no hotspot fires, and `fast_pending`
clears. The commit uses `rom_data` as it stands in (E5,E6).

Consequences a clone must match:

- Arming is not tied to opcode fetches: **any** committed cartridge ROM read
  returning $A9 arms it (data-table reads, dummy reads, operand bytes, e.g.
  `LDA #$A9`, hotspot reads, reads of the write-only $028-$07F area).
- Consumption is not tied to address+1: the **next committed cartridge read**
  is the candidate, at any address $028-$FFF, after any number of
  intervening writes or non-cartridge accesses.
- If that next read's ROM byte is ≥ $28 it is a plain ROM read and re-arms or
  disarms by the $A9 rule.
- If `fast_fetch` is turned off, a still-set `fast_pending` cannot be
  consumed (the consume term needs `fast_fetch`), and the next ROM read
  clears it (DPC:251).
- Fast-fetch register addresses can be any of $00-$27 (random, amplitude,
  DATA, DATAW, FRACDATA, FLAG).
- `register_read`, `ram_sel` and `ram_a` on a fast-fetch operand depend on
  `rom_data` combinationally (DPC:115,120,143). Until the wrapper's
  `rom_do` shows the operand byte, the cycle decodes from whatever `rom_do`
  shows. [corrected: the original said the stale byte "is normally the $A9
  opcode"] That is the opcode byte only on a ROM path that holds the old byte;
  on the `sdram.sv` path a new-word read shows the **other byte of the
  previous word** for part of the cycle (§12.2), which can be < $28 and then
  makes the cycle a transient register read (ram_sel high, wrong `ram_a`) in
  those clks. Nothing commits from it (the commit sees (E5,E6)), but it
  blocks the audio engine's RAM grant there.
- [added] Held repeats (WSYNC, or the visible ones of an ARM stall)
  re-present the previous cycle's address (§0.2). After `STA WSYNC` that is
  the next opcode fetch: if it is the $A9 of `LDA #`, every repeat re-commits
  it and re-arms `fast_pending` (idempotent), and the operand is consumed in
  the completing pass, so the 6507 gets the **register** byte (sim §17).

---

## 8. PARAMETER, CALLFUNCTION, DMA service, ARM call, 6507 stall

### 8.1 Parameter block [corrected: "accepted" → "taken"]

`params[0..7]`, pointer `parameter_pointer[3:0]`. Write $059: store at
`ptr[2:0]` and increment while `ptr < 8`; at 8 further writes are dropped
(DPC:272-277). The pointer resets to 0 on reset, CALLFUNCTION 0, and a
CALLFUNCTION 1 or 2 that is **taken** (written while `service_pending` is
clear; DPC:279-282,292), independent of when the DMA engine later accepts the
request. It is not reset by FE/FF or by an ignored 1/2.

### 8.2 CALLFUNCTION ($05A), at the commit edge E6 (DPC:278-296) [checked]

Priority chain on `d` (the data byte):

1. `d == 0`: `parameter_pointer = 0`. Always, even with a service pending.
2. `d == 1 or 2` and `!service_pending` (pre-edge value):
   - `service_fill = (d == 2)`
   - `service_source = 3072 + {params[1], params[0]}` (19 bits; an
     **image byte offset**, the DMA reads the DDR3 shadow of the loaded image
     at `SHADOW_BASE_WORD + source[24:3]`, `arm_mapper_memory.sv:778-780`)
   - `service_dest = 3072 + counter[params[2][2:0]]` (15 bits; a cart RAM
     byte address, `0x0C00-0x1BFF`)
   - `service_count = (d == 2) ? fill_count : copy_count`
   - `service_value = params[0]` (also set for a copy, unused there)
   - `service_pending = 1`, `parameter_pointer = 0`
   - If `service_pending` is already 1 the write is ignored completely
     (pointer not reset).
3. `d == $FE or $FF` and `!call_pending`: `call_pending = 1`. FE and FF are
   identical. Ignored if a call is already pending.
4. any other value: nothing.

Counts, from the pre-commit `params` and counters (DPC:85-101):

```
off            = {params[1], params[0]}                     (16 bits)
dest_avail     = 0x1000 - counter[params[2] & 7]            (13 bits, 1..0x1000)
fill_count     = (dest_avail < params[3]) ? dest_avail[7:0] : params[3]
src_avail      = 0x7400 - off                               (17 bits)
copy_count     = (off >= 0x7400) ? 0
               : (src_avail < fill_count) ? src_avail[7:0] : fill_count
```

So a copy never reads past image byte `0x8000` and neither copy nor fill
writes past RAM byte `0x1BFF`. The fill uses the same masked stream index as
the copy (`params[2] & 7`). `params[3] = 0`, or `off >= 0x7400` for a copy,
still issue a request with count 0 (the only ways to get 0: `dest_avail` and
`src_avail` are ≥ 1 otherwise).

### 8.3 Handshake and stall timing

[checked] Same-edge race: the pending-clear (DPC:222-225) and the
CALLFUNCTION set (DPC:282, 293-295) both test the pre-edge pending flag, and
the set needs it clear, so a CALLFUNCTION write landing on the accept edge of
a still-pending request is dropped.

Service (DMA) [checked]:

- `service_request = service_pending && service_ready` (combinational,
  DPC:187), high in (E6,E7) after the write if `service_ready`.
- `service_ready = !mapper_init_busy && shadow_ready_sync2 && !dma_busy`
  (C26:428; `arm_mapper_memory.sv:228`).
- On the accepting posedge (E7 at the earliest) the front end clears
  `service_pending` (DPC:224-225), and the DMA engine latches the payload
  and sets `dma_busy` (`arm_mapper_memory.sv:335-343`). The front-end
  `service_*` registers keep their values until the next taken 1/2.
- If not ready, `service_pending` stays set and the 6507 is **not** stalled
  until it is accepted; meanwhile further 1/2 writes are ignored. A pending
  service and a pending call are independent and can both be outstanding.
- DMA engine: count 0 completes at once on the ARM side
  (`arm_mapper_memory.sv:868-869`); fill writes `value` to `dest..dest+count-1`
  one byte per accepted ARM-port slot; copy reads 8-byte DDR words and writes
  bytes (`arm_mapper_memory.sv:859-893`, 637-644). All DMA RAM writes go
  through the ARM-side port of the cart RAM, not the console port.
  `dma_busy` falls when the completion toggle has crossed back
  (`arm_mapper_memory.sv:345-348`).

Call (ARM):

- [corrected: the readiness terms are the synchronised copies]
  `call_request = call_pending && call_ready` (DPC:183), `call_ready =
  arm_call_ready && mapper_wb_idle && !mapper_init_busy` (C26:661-662), and
  `arm_call_ready = arm_online_sync2 && shadow_ready_sync2 &&
  !mapper_reset_sys && !call_busy` (`arm_mapper_controller.sv:86-87`; the
  two `_sync2` flops are clk_sys synchronisers, :138-141;
  `mapper_reset_sys` = cart2600's `reset`, `arm_mapper_subsystem.sv:122`).
  `mapper_wb_idle` is the table writeback's idle, which DPC+ never makes
  busy (no pointer or map writes for DPC+: C26:667-669, 654).
- [checked] On the accepting posedge (E7 at the earliest) the front end
  clears `call_pending` and the controller latches entry/stack/thumb and the
  six audio words and sets `call_busy` (`arm_mapper_controller.sv:149-161`).
- [checked] ARM entry state written by the controller
  (`arm_mapper_controller.sv:219-232,284-318`): R0-R12 = 0, R13 =
  `0x40001FFC`, R14 = `0xF0000000` (return sentinel, line 48), R15 =
  `0x00000C08`, CPSR = T | SYS (Thumb), state indices 17-22 = the three
  audio counters and three frequencies. The call ends when the ARM fetches
  the sentinel (`arm_mapper_memory.sv:633`), then the controller reads six
  FIQ registers back and toggles completion; `call_busy` falls on clk_sys
  (`arm_mapper_controller.sv:163-177`). The returned audio values are
  ignored for DPC+ (`arm_mapper_audio.sv:207-223` need `family >= 2`).

Stall (TOP, not the front end):

- [checked] `arm_call_stall = tia_en && (arm_call_busy || (!mapper_init_busy
  && arm_dma_busy))` (TOP:306-307). It pulls RDY low (TOP:328-329).
- [checked] After a CALLFUNCTION write committed at E6 and accepted at once
  (ready high in (E6,E7)), the stall is high from (E7,E8) of the write cycle W.
- [checked] `stall_cycle_taken` clears on any clk where the stall is low and
  sets at a `pclk0` while it is high (TOP:321-326); `mapper_phi2 = pclk0 &&
  (!arm_call_stall || !stall_cycle_taken)` (TOP:327). So during a stall the
  first `pclk0` reaches the front end and later ones are hidden until the
  stall falls. A one-clk gap in the stall (e.g. a second queued call accepted
  the clk after the first ends) clears `stall_cycle_taken` and makes the next
  `pclk0` visible again.
- [corrected: what the held repeats present] With the CPU model's hold rule
  (§0.2): W+1 (the next opcode fetch, address A) completes (it follows a
  write) and is the stall's first, visible `pclk0` at E6 of W+1 = W's E0 +
  18. W+2 is held: its repeats are reads of **A again** (not W+2's own
  address) and are hidden; the completing pass (first E0 that samples RDY
  high) presents W+2's own address (A+1 after `STA abs`) and is visible. So
  the mapper sees A once and then W+2 once, **except** in the release window
  (§13 S2), where it sees A twice. Sim §17: `STX $105A; LDA #<DF0DATA>` with
  fast fetch returns the DF0DATA byte for every stall length.
- [checked] How long the stall lasts is set by the ARM program or the DMA and
  the clock-domain crossings (clk_arm = 5 x clk_sys, `cart_ram_tdp.sv:29-33`),
  not by the front end.
- [added] If the request is not accepted at W's E7 (call/service not ready,
  e.g. during `mapper_init_busy`, C26:428,661-662), the stall rises later at
  an arbitrary phase. Then §13 S3 applies.

---

## 9. Cart RAM, console side (port A of `cart_ram_tdp`)

### 9.1 Addresses the front end uses [checked]

All byte addresses in the 128 KiB cart RAM (`cartram_addr[16:0]`, TOP:923):

| Access | Address | When |
|---|---|---|
| DFxDATA / DFxDATAW read (direct $008-$017 or fast-fetch operand) | `0x0C00 + counter[i]` | every clk with `register_read` and fn 1/2 |
| DFxFRACDATA read (direct $018-$01F or fast-fetch operand) | `0x0C00 + fractional[i][19:8]` | every clk with `register_read` and fn 3 |
| DFxPUSH write ($060-$067) | `0x0C00 + (counter[i] - 1 mod 4096)` | every clk with `!rw && a_in[12]` and that address |
| DFxWRITE write ($078-$07F) | `0x0C00 + counter[i]` | same, $078-$07F |

Range `0x0C00-0x1BFF` (4 KiB display RAM). The front end never addresses the
frequency table (`0x1C00-0x1FFF`) or the ARM's working RAM (`0x0000-0x0BFF`)
on the console side. (The DMA it requests writes `0x0C00-0x1BFF` through the
ARM port, §8.)

### 9.2 Port mux and strobes (C26:965-978)

- [checked] `cartram_addr = init_ram_en ? init_ram_addr : (sel_ram_sel ?
  sel_ram_a : audio_ram_addr)` (C26:966-967). So the front end owns the
  console port in every clk where its `ram_sel` is 1, and the audio engine
  gets it otherwise (`audio_ram_grant = audio_ram_en && !init_ram_en &&
  !sel_ram_sel`, C26:965). [added] `init_ram_en` is never high for family 1
  (it is only set in the BUS/CDF table-read states,
  `arm_mapper_ram_init.sv:191-192`). TOP passes C26's port through while
  `tia_en` or `mapper_init_busy` (TOP:752-759).
- [checked] Write strobe: `cartram_wr = !init_ram_en && sel_ram_sel &&
  !sel_ram_rw && !phi1 && !address_change && !access_taken` (C26:973-974);
  data = `d_in` (C26:977). TOP forwards it only with `tia_en` (or during
  `mapper_init_busy`) (TOP:752-753).
  - `address_change = old_ain != a_in` (C26:241, 263-265): high in (E0,E1)
    when the address differs from the previous cycle's.
  - `access_taken` clears at a posedge with `phi1` (= `pclk1`, E0) or
    `address_change`, sets at a posedge with `phi2` (= `mapper_phi2`, E6)
    (C26:255-261; TOP:1133-1135). It uses `mapper_phi2`, **not**
    `arm_access`.
  - Result for a PUSH/WRITE cycle: strobe high in (E1,E6) (and (E0,E1) too
    if the address equals the previous cycle's), so the RAM writes the same
    byte to the same pre-commit address at posedges E2-E6 (E1-E6). After E6
    `access_taken` blocks the strobe while `ram_a` already points at the
    stepped counter; in (E11,E12) `phi1` blocks it. One logical write per
    cycle (sim §17 test 3).
  - The strobe is **not** gated by `lock_ctrl` (`arm_driver_run`): with
    `tia_en` set and the lock not yet set, a PUSH/WRITE address writes RAM
    with no counter change.
- [corrected: "outside RAM init" → "outside `mapper_init_busy`", and what
  happens inside it] Read strobe `cartram_rd` (C26:975-976) is unused by
  `cart_ram_tdp` while `mapper_init_busy` is low: port A is enabled on every
  clk with `!pause` (TOP:921). While `mapper_init_busy` is high, port A's
  enable is `cartram_wr || cartram_rd` (TOP:921), and the front end's part of
  `cartram_rd` is `sel_ram_sel && sel_ram_rw && ~phi1 && ~address_change`:
  the lane select (`cart_ram_tdp.sv:61-64`) is then not updated in (E0,E1)
  of an address change or in (E11,E12). The byte at E6 is still
  `RAM[ram_a in (E4,E5)]` (the lane RAMs themselves read every clk,
  `cache_ram.v:172-176`), but (E0,E2) can show a byte from the wrong lane.
  Also during `mapper_init_busy`: DMA busy does not stall the 6507
  (TOP:306-307), CALLFUNCTION requests are not accepted (C26:428,661-662),
  and RAM `0x0C00-0x1FFF` may not be loaded yet (§9.4).

### 9.3 Read latency (upstream `cart_ram_tdp`) [checked]

Port A samples its address on every clk_sys posedge and returns the byte one
clk later: `q <= mem[addr]` (`cache_ram.v:172-176`; altsyncram with
registered address and unregistered output, `cache_ram.v:119-154`); the lane
select is registered alongside (`cart_ram_tdp.sv:57,61-64`). Read-during-
write returns the new byte. So `ram_data` in (Ek,Ek+1) =
`RAM[cartram_addr in (Ek-1,Ek)]`, and the byte the 6507 latches at E6 is
`RAM[ram_a in (E4,E5)]`. TOP forces `ram_data = 0xFF` while paused
(TOP:936). (With `EXTERNAL_CARTRAM` this is different; see §16 Q6.)

### 9.4 RAM initialisation (not the front end, but it sets what DPC+ reads)

[checked] On `load_end` (delayed one clk: C26 passes `load_end_d`,
C26:572-577,712) and on every rising edge of cart2600's `reset` once an image
is loaded (`arm_mapper_ram_init.sv:204-227`), for family 1: DMA 1 fills
`0x0000-0x0BFF` with 0 (lines 141-143: fill, value 0, dest 0, count
`0xC00`); DMA 2 copies image `0x6C00-0x7FFF` to RAM `0x0C00-0x1FFF`
(lines 156-161). `mapper_init_busy` is high throughout, and also for the whole
download (`busy = loading || state != INIT_IDLE`, line 75), blocking
`call_ready` and `service_ready` (C26:428,661-662).

[added] The family is **latched at `load_end_d`** (`active_family <= family`,
line 215) and `image_loaded` is set only if that family is not NONE (line
214). A reset re-runs the init of the load-time family (lines 222-226), not
of the mapper selected now. So a DPC+ selected by override **after** the load
(on an image detected as a non-ARM mapper) never gets its display data and
frequency table copied into RAM; selected before the load (MiSTer OSD
override set when the file is opened) it does.

---

## 10. Revision and the FRACLOW quirk

- [checked] `stable_fractional = mapper_revision[0]` (C26:811), straight from
  `detect2600` (TOP:1139; `detect2600` lives in the wrapper,
  `core/atari7800_pocket.sv:300-311` on the Pocket).
- [checked] `detect2600` sets `mapper_revision = 0` at load start and at
  `load_end`, then for a DPC+ detection (`hasMatchDPCP` = "DPC+"
  (`44 50 43 2B`) seen at least twice, `detect2600.sv:403-414`, and size
  exactly 32768): `mapper_revision = (dpc_driver_crc == 0xA08CFB13) ? 1 : 0`
  (`detect2600.sv:223-225`). `dpc_driver_crc` is `nextCRC32_D8`
  (`detect2600.sv:1430-`) over image bytes with `load_addr < 3072`, in
  arrival order, seeded with 0 at `load_start` (`detect2600.sv:128,
  140-144`), no final inversion.
- [added] Detection priority (`detect2600.sv:213-226`): ELF; 24576/28672
  bytes without the DEVC pattern → FA2; 29696 bytes → FA2 if the FA2 loader
  signature was seen, else DPC+ revision 0; CTY (32768/61440); CDF (sizes
  32K-512K); only then DPC+ (32768 bytes). A 32K image that also matches CDF
  is CDF.
- [checked] A 29696-byte image is selected as DPC+ (unless the FA2 loader
  signature is seen), with revision 0 (`detect2600.sv:210-216`). The front
  end still adds the 3072-byte offset in `rom_a` and the DMA source, the RAM
  init still copies image `0x6C00-0x7FFF`, and the ARM entry is still
  `0xC08`; nothing in `rtl/` relocates the image (§16 Q5).
- [checked] The user mapper override does not change `mapper_revision`, so a
  forced DPC+ takes bit 0 of whatever the detector set for the detected
  mapper. [added] Bit 0 is 1 for: DPC+ with the CRC match; CDF revision 1 or
  3 (CDF1, CDFJ+) (:220-221); BUS revision 1 or 3 (:237); the 8195-byte WD
  dump (:252-254); UA "mickey" (:257-259).

Effect (DPC:255-258), on a DFxFRACLOW write:

| `stable_fractional` | new `fractional[i]` |
|---|---|
| 1 (revision 1, CRC match) | `{frac[19:16], d, 8'h00}` (low byte cleared) |
| 0 (revision 0) | `{frac[19:16], d, frac[7:0]}` (low byte kept) |

(For reference only, not checkable from `rtl/`: this is meant to match
Stella's `myFractionalLowMask` 0x0F0000 for its old-driver image and 0x0F00FF
otherwise.)

---

## 11. Audio interface (what DPC+ feeds `arm_mapper_audio`, family 1)

- [checked] Waveforms: `audio_waveformN = waveform[N]` (DPC:188-190),
  registers that change at the WAVEFORM write's E6. [added] The audio block
  reads them **live** in each AUDIO_SAMPLE_ISSUE clk
  (`selected_dpc_waveform`, `arm_mapper_audio.sv:113-126,143-146`), not as a
  snapshot, so a WAVEFORM write during a refresh affects the voices not yet
  sampled.
- [checked] NOTE: `audio_note_write` is high in (E6,E7) after a $075-$077
  write (DPC:221,311-315). The audio block latches `note_pending`,
  `note_voice`, `note_value` at E7 (`arm_mapper_audio.sv:201-205`). In
  AUDIO_IDLE a pending note beats a pending refresh (lines 227-229):
  AUDIO_NOTE_ISSUE drives `ram_addr = 0x1C00 + 4*value` (lines 129-135) and
  waits for `ram_grant`; the next state (AUDIO_NOTE_CAPTURE) loads
  `frequencyN` with the 32-bit little-endian word `ram_word_data =
  {lane3..lane0}` read at that address (lines 248-257; `cart_ram_tdp.sv:58`;
  TOP:934,1158 — this word path is **not** forced to FF on pause). Best case:
  IDLE in (E7,E8) → state NOTE_ISSUE at E8, granted in (E8,E9) (a NOTE write
  cycle has `ram_sel = 0`) → CAPTURE in (E9,E10) → `frequencyN` updated at
  E10. The frequency table is RAM `0x1C00-0x1FFF`, loaded from image
  `0x7C00-0x7FFF` by §9.4 and writable by the ARM. A second note strobe
  before the grant overwrites voice and value (only the last note is
  loaded); a strobe in the CAPTURE clk keeps `note_pending` (line 254).
  (A strobe landing exactly on the grant edge would pair the new voice with
  the old value's word. Strobes are ≥ 12 clks apart (an RMW on $1075-$1077
  gives two, 12 clks apart), the port is free during NOTE write cycles, and
  a pending note is taken at the next IDLE clk, so the first note is always
  loaded before the second strobe: not reachable in practice.)
- [checked] Tick: a 20 kHz accumulator, `CLK_RATE = 14318182` fixed (lines
  8-9, 57, 76, 191-199; C26:760 passes no parameter): on a tick `counterN +=
  frequencyN` and a refresh is queued (line 196). The tick runs on clk_sys
  with no enable (it keeps running in pause) and its phase relative to E0 is
  set by the time since cart2600's `reset`.
- [checked] Refresh (family 1): for voices 0,1,2, AUDIO_SAMPLE_ISSUE reads
  `0x0C00 + waveform[N]*32 + (counterN_snapshot >> 27)[4:0]` (lines
  140-146, 231-239), each waiting for `ram_grant`, and
  `amplitude = (s0 + s1 + s2) mod 256` (lines 317-332). The counters are
  snapshotted when the refresh starts (lines 231-233).
- [checked] `amplitude` is what DPC+ register $05 returns (DPC:170, C26:820),
  as it stands in (E5,E6); a refresh capture at a posedge ≤ E5 is seen by
  that read.
- [checked] **Arbitration:** `ram_grant` is low in every clk where the front
  end's `ram_sel` is 1 (C26:965). So a DPC+ register read of fn 1-3 or a
  PUSH/WRITE write cycle delays any note load or sample read. Per-tick
  equality needs `ram_sel` to match clk for clk (§12), including during held
  repeats (a re-presented DFxDATA address keeps `ram_sel` high for the whole
  hold, §13 S3).

---

## 12. Within one 6507 cycle: d_out, ram_sel and state, edge by edge

[corrected: precise definition] Notation: `L` = the smallest k such that
every clk_sys posedge from Ek+1 on samples `rom_do` = the byte for the
cycle's `rom_a` (what a ROM model with k registered address stages gives:
the byte stands in (Ek,Ek+1) onwards). Intervals "(E0,E0+L)" below mean "as
seen by clk_sys samples". Not defined in `rtl/`; §16 Q1 gives the Pocket
path's value (L = 1 or 2).

### 12.1 Direct register read ($1000-$1027, `rw=1`) [checked]

| Interval | What stands |
|---|---|
| (E0,E1) | new `a_in`; `register_read=1`, `flags_out[0]=1`, `oe=FF`; `ram_sel` set for fn 1-3 with the pre-commit address; `ram_data` still the byte for the address of (E-1,E0), so d_out for fn 1-3 is stale. Random, amplitude and flag d_out are already right. |
| (E1,E6) | `ram_data` = byte at the current `ram_a`. d_out valid. |
| **posedge E6** | 6507 latches d_out (pre-commit). Front end commits (if `access`): counter, fractional or LFSR step; `fast_pending=0`. |
| (E6,E7) | `register_read` still 1 (direct address). fn 1/2: `ram_a` = new counter, `ram_data` still the old byte; DATAW = old byte & flag of the new counter. fn 3: same with the new fractional. fn 0 idx 0/1: d_out now shows the next step (e.g. `random_next(random_next(r))[7:0]`). |
| (E7,E12) | fn 1-3: `ram_data` = byte at the new address. `ram_sel` stays 1 until the address changes at E12, so the audio engine is locked out for the whole cycle. |

### 12.2 Fast-fetch operand read (`LDA #` operand at $1028-$1FFF)

| Interval | What stands |
|---|---|
| (E0,E0+L) | `rom_do` not yet the operand. Decode follows whatever it shows: on a hold-last-byte path that is the $A9 opcode (≥ $28: not a register read; d_out = `rom_do`, `ram_sel = 0`); on the `sdram.sv` path see below. |
| (E0+L,E6) | `rom_data` = operand < $28: register read; `ram_sel`/`ram_a` from `rom_data`; `ram_data` right from (E0+L+1). [corrected: split by function] Correct data at E6 needs `rom_do` valid in (E4,E5), i.e. **L ≤ 4**, for fn 1-3 (RAM-backed: DATA, DATAW, FRACDATA); fn 0 and 4 (random, amplitude, flag) only need (E5,E6), L ≤ 5. Sim §17: L = 0..4 correct, L = 5 returns the wrong DATA byte. |
| **posedge E6** | 6507 latches the register byte. Commit: side effect (register chosen by `rom_data` in (E5,E6)), `fast_pending=0`, no hotspot. |
| (E6,E12) | `fast_pending=0`: **no longer a register read**: d_out = `rom_do` (the operand byte), `flags_out=0`, `ram_sel=0` (audio may use the port). |

[added] On the Pocket's ROM path (`sdram.sv` on `clk_sdram` = 4 × clk_sys,
edge-aligned, `ch0_rd = cart_read`; `core/atari7800_pocket.sv:10-11,394-401,
949`) the clk_sys samples of `rom_do` in an operand cycle are: E1 = the
previous byte (the $A9); E2 = the operand if it is in the same 16-bit word as
the opcode (opcode at an even address), otherwise the **other byte of the
opcode's word** (the byte before the opcode); E3 on = the operand. Derivation:
the read is accepted at the first `clk_sdram` edge after `rom_read` rises
(E1 + ¼), which also switches the byte select `a[0]`; a new word is loaded
into `last_data` at STATE_READY, 6 `clk_sdram` edges later (E2 + ¾)
(`sdram.sv:54-67,95-104,187,193`). So L = 1 (same word) or 2 (new word).
Whether MiSTer's wrapper uses the same arrangement is not visible
(`Atari7800.sv` is not vendored; the PLL's 57.272728 MHz output,
`pll/pll_0002.v:42`, is 4 × clk_sys).

### 12.3 ROM read ($1028-$1FFF, not consumed) [checked]

d_out = `rom_do` throughout. At E6: hotspot bank change (if $FF6-$FFB),
`fast_pending = fast_fetch && rom_data==$A9`. After E6 `rom_a` follows the new
bank; `rom_do` follows only if the ROM path refetches (§4.3).

### 12.4 Write cycle [checked]

`d_in` valid from (E0,E1). Register effects at E6 from `d_in` in (E5,E6).
PUSH/WRITE: `ram_sel=1`, `ram_rw=0` from (E0,E1) to (E11,E12); RAM strobe as
in §9.2; `ram_a` steps at E6 but no strobe follows.

### 12.5 Held cycles [added]

During a held repeat the bus carries the previous cycle's address as a read
(§0.2), and the front end decodes **that** address exactly as in
12.1-12.3 (d_out, `ram_sel`, and — if the repeat is visible — a commit). The
6507 latches every repeat's byte but keeps only the completing pass's
(`dl`, `6502/mos6502_dp.sv:299`). The completing pass is an ordinary cycle at
the held cycle's own address.

---

## 13. System-level behaviour the front end inherits (TOP / CPU, not DPC)

These come from `access`, `a_in` and `rw`, which the clone receives
unchanged if it keeps TOP. A clone that rebuilds the stall or adds its own
repeat suppression must reproduce them to stay in step with upstream. S1-S3
and S5 were checked in the simulation of §17; S4 is from the RTL only.

- **S1. WSYNC: every held repeat is committed, and it re-commits the next
  opcode fetch.** [corrected: the original said the 6507 completes `LDA
  #<reg>` with the ROM operand byte; simulation shows it gets the register
  byte] `wsync` is combinational on `~RW_n && pclk.level_p2 && cs`
  (`TIA.sv:1966-1971`) and the `sr_latch` output is combinational
  (`TIA.sv:166-187,2193-2203`), so `tia_RDY` falls in (E6,E7) of the
  `STA WSYNC` write W [corrected: not E7]. W+1 (next opcode fetch, address A)
  cannot be held and completes. W+2 is held; each held repeat reads A again
  and is visible (`mapper_phi2` masks only during an ARM stall, TOP:327), so
  A is committed once per repeat: for a ROM opcode that re-evaluates
  `fast_pending` with the same byte and re-applies a hotspot (both
  idempotent). Release: RDY also needs `tia_RDY_seen_high`, set only at a
  `pclk1` with `tia_RDY` high (TOP:290-297,328), so the cycle whose E0 first
  sees `tia_RDY` high is still held and the next one completes, at W+2's own
  address. `STA WSYNC; LDA #<DF0DATA>` with fast fetch: the operand is
  consumed once, in the completing pass, and the 6507 gets the DF0DATA byte
  (sim: `zp80 = $40`, counter +1). A register read is re-committed during a
  WSYNC hold only if the opcode fetch after `STA WSYNC` is itself at
  $1000-$1027.
- **S2. ARM-stall release window: the re-presented address is committed a
  second time.** [corrected: it is the previous cycle's address, not the
  held cycle's, and in the normal CALLFUNCTION flow it is harmless] Let the
  stall fall at posedge P (low from (P,P+1)). A held repeat with E0 = R is
  held because RDY was low in (R-1,R) (P ≥ R) and is visible if its E6 sees
  the stall low (P ≤ R+5). For P in [R, R+5] (6 of the 12 phase positions)
  that repeat and the completing pass are both committed: the address of the
  last completed cycle is committed once more, then the held cycle's own
  address once. After `STX $105A` that extra commit is the opcode fetch A,
  so data are unaffected (sim: stall lengths 17-22, 29-34, 41-46 clks after
  an E7 accept give `commits − completed = +1`, P = W+24..29, +12k; every
  stall length returns the right DF0DATA byte).
- **S3. A stall that rises late re-commits the previous cycle.** [corrected:
  the original only said "the first pclk0 of a stall is always committed"]
  If the stall rises at posedge Q with Q ∈ [E6, E11] of a read cycle C (so
  C's E6 does not see it but C+1's E0 does), C+1 is held, and its first held
  repeat — a read of C's address — carries the stall's first `pclk0`, which
  is visible. C's address is therefore committed twice; if C was a direct
  register read its side effect happens twice (sim: a call released while
  the 6507 runs `LDA $1008` steps counter 0 one extra time when Q falls in
  the second half of the $1008 cycle; with stall lengths ≡ 0 mod 12, S2 then
  does not hit; with ≡ 6, S2 hits the same address again: +2). This needs a
  request accepted away from W's E7, i.e. one queued while `call_ready` or
  `service_ready` was low (`mapper_init_busy`, ARM not online, shadow not
  ready). A re-presented DFxDATA/FRACDATA address also keeps `ram_sel` high
  for the whole hold, starving the audio engine.
- **S4. Pause** stops the phase enables (MARIA `ce`, TOP:445); the audio
  block keeps ticking on clk_sys and reads `ram_data = 0xFF` (TOP:936)
  while port A is disabled (TOP:921). [checked]
- **S5. [added] A read-modify-write on $105A loses a commit.** `INC/DEC/
  ASL/LSR/ROL/ROR $105A` writes twice. The first write W1 commits
  CALLFUNCTION(old) and, if accepted at once, raises the stall; the second
  write W2 cannot be held, carries the stall's first `pclk0` (visible) and
  commits CALLFUNCTION(new) (which can queue a second call). W2+1, the next
  opcode fetch, cannot be held either (it follows a write) and completes, but
  its `pclk0` is hidden: the mapper never sees it (no fast-fetch arming, no
  hotspot). Sim: `INC $105A` with ROM byte $FE then `LDA #<DF0DATA>` returns
  the ROM operand ($08) for a 40-clk stall. Generally: once the stall's
  first `pclk0` has passed, every `pclk0` while the stall stays high is
  hidden whether or not the CPU is holding, so a cycle that cannot be held
  (one right after a write) completes unseen.

---

## 14. Quirks a clone must reproduce (checklist)

1. Commit only when `access` (mapper_phi2 && lock_ctrl && tia_en) and
   `a_in[12]` (DPC:227); combinational outputs act regardless. [checked]
2. 6507 latch and commit share E6: CPU always sees pre-commit `d_out`.
   [checked]
3. RANDOM0NEXT/RANDOM0PRIOR return the low byte of the **stepped** value and
   step at E6; RANDOM1-3 return bytes 1-3 unstepped; no unstepped byte 0.
   [checked]
4. $006, $007, $024-$027 read `$00` with `oe=FF` (not open bus). [checked]
5. DFxFLAG only on $020-$023. [checked]
6. Window flag: 8-bit modular `(top - lo8(counter)) > (top - bottom)`, from
   the pre-increment counter; DATAW = data AND flag. [checked]
7. Counters 12-bit wrap both ways; fractional 20-bit wrap; increment 8-bit
   zero-extended. [checked]
8. FRACLOW keeps or clears `fractional[7:0]` by `mapper_revision[0]`;
   FRACHI uses `d[3:0]` only; FRACINC clears `fractional[7:0]`; LOW keeps
   11:8; HI uses `d[3:0]`. [checked]
9. PUSH writes at `counter-1` and decrements; WRITE writes at `counter` and
   increments; $068-$077 never touch RAM. [checked]
10. RAM write strobe repeats E2-E6 (E1-E6 for an unchanged address) at the
    pre-commit address, blocked after E6 by `access_taken` (set by
    `mapper_phi2`, not `access`); not gated by the 2600 lock. [checked]
11. Fast fetch arms on **any** committed cart ROM read of $A9 (with
    `fast_fetch`), is consumed by the **next** committed cart read whose ROM
    byte is < $28 at any address ≥ $028, is unaffected by writes and
    non-cart accesses, and clears on every register read. [checked]
12. Fast-fetch register space is 6 bits ($00-$27). [checked]
13. Hotspots $FF6-$FFB switch on reads and writes, return the old bank's byte,
    and are suppressed only by a fast-fetch operand. [checked]
14. Fast-fetch operand: after E6 `d_out` falls back to the ROM operand and
    `ram_sel` drops; before `rom_do` settles the decode follows whatever
    `rom_do` shows (transient register reads possible). [corrected: added
    the pre-settle part]
15. FASTFETCH enable = (written byte == 0). [checked]
16. PARAMETER pointer saturates at 8 (writes dropped); reset by CALLFUNCTION 0
    and by a taken 1/2, not by FE/FF or an ignored 1/2. [corrected: wording]
17. CALLFUNCTION 1/2 ignored entirely while `service_pending`; FE/FF ignored
    while `call_pending`; FE and FF identical; other values no-op; a write on
    the accept edge of a pending request is dropped. [checked]
18. Copy/fill clamps of §8.2, stream index `params[2] & 7` for both; count 0
    still requests a DMA (and stalls for its round trip). [checked]
19. `service_source = 0xC00 + offset` (image byte), `service_dest = 0xC00 +
    counter` (RAM byte), `service_value = params[0]` also on a copy.
    [checked]
20. Request/accept: pending set at E6, request combinational, accepted and
    cleared at E7 at the earliest; stall only from acceptance. [checked]
21. Waveform 7 bits; NOTE strobe one clk in (E6,E7); voice = `a[1:0]-1`.
    [checked]
22. Reset: bank 5, LFSR `0x2B435044`, everything else 0; also reset whenever
    `mapper != BANKDPCP`. [checked]
23. `ram_sel` (and so audio starvation) for the whole cycle on direct
    fn 1-3 reads and PUSH/WRITE writes, including pre-lock cycles and held
    repeats whose re-presented address is such a register; only (E0+L,E6) on
    fast-fetch operands (plus any transient of item 14). [corrected: held
    repeats decode the previous cycle's address]
24. S1-S5 of §13 (inherited through `access`, `a_in`, `rw`). [corrected]
25. [added] Held repeats re-present the previous cycle's address (§0.2), so
    a re-committed address during WSYNC or in the S2/S3 cases is the
    previous cycle's, never the held cycle's own.
26. [added] The front end reads `rom_data` live; a bench must give both
    sides the same ROM path, including the no-refetch-on-bank-switch
    behaviour of §4.3 if it models `sdram.sv`.

---

## 15. Guard notes (for "guard if cheap and does not desync")

Behaviour-neutral (cannot change any upstream-visible result) [checked]:

- All array indices are 3 bits into 8-entry arrays; waveform and note voice
  indices are `a[1:0]-1` with `a[2:0]` in {5,6,7}, so 0..2 (DPC:298,313).
  Bounds guards are free and neutral.
- `bank` can only hold 0..5 (reset 5, hotspots 0..5); a guard on 6/7 is
  neutral.
- `ram_a` ≤ `0x1BFF` and DMA dest ≤ `0x1BFF` by construction; clamping to 13
  bits is neutral.
- `read_function` 5..7 unreachable; the default arm is neutral.

Not neutral (would desync from upstream at commits or audio ticks): any
same-address repeat suppression (S1, S2, S3), restoring the commit S5 loses,
gating RAM writes with the 2600 lock, changing the fast-fetch arming or
consumption rules, decoding the fast-fetch operand only once `rom_do` is
known-good (changes `ram_sel` timing, item 14), re-arbitrating the RAM port
against audio, clearing `fast_pending` on writes. [added] Also not neutral:
forcing `stable_fractional = 0` for a DPC+ that the detector did not choose
(§16 Q8), relocating 29696-byte images (§16 Q5), and running the RAM init for
the current rather than the load-time family (§9.4): each changes what a
forced or 29K DPC+ does relative to upstream, so under the stated rule they
should not be implemented in the compared clone (or only behind an option
that is off for comparison).

---

## 16. Answers to the writer's open questions

1. **ROM latency L.** [answered for the Pocket path; open for MiSTer]
   `sdram.sv` **is** vendored in `rtl/` (GPL-3.0, `../POCKET_CHANGES.md:6-8`);
   what is not is MiSTer's wrapper `Atari7800.sv`, which connects TOP's
   `cart_read` / `cart_addr_out` / `cart_out` to the ROM memory and picks its
   clock (`../POCKET_CHANGES.md:16-17`). On the Pocket wrapper, which uses this same
   `sdram.sv` (`core/core.qip:24`) on 4 × clk_sys with `ch0_rd = cart_read`
   and `cart_out = ch0_dout` (`core/atari7800_pocket.sv:10-11,394-401,949`),
   L = 1 when the byte is in the same 16-bit word as the previous SDRAM read
   and L = 2 otherwise, with the E2 sample showing the previous word's other
   byte in the second case (§12.2). Both satisfy fast fetch's L ≤ 4 (§12.2,
   confirmed by simulation: L ≤ 4 works, L = 5 fails). Because `rom_read`
   (C26:157) only rises after an `a_in` change, there is no refetch on a bank
   switch (§4.3). The Pocket build does not instantiate DPC+
   (`NO_ARM_MAPPER`), so for a comparison bench L is a bench parameter and
   must be the same for upstream and clone; L = 1/2 with the sdram.sv
   transient is the realistic choice.
2. **S1 and S2** [answered by simulation, §17]: S2's window is exactly as
   derived (6 of 12 positions); S1 was wrong as written (the 6507 gets the
   register byte), because held repeats re-present the previous cycle's
   address (§0.2). Both are now stated from the simulation.
3. **Which cycle the CPU holds after a write** [answered]: internally W+2
   (W+1 follows a write and cannot be held, `6502/mos6502_ctl.sv:861-876`),
   but `hold_mask` keeps the address, so on the bus the held repeats are reads
   of W+1's address — which is what TOP's comment calls the stalled
   "following instruction fetch" (TOP:298-319). The two comments agree on the
   bus. Release window: R = W's E0 + 24 + 12k, P ∈ [R, R+5]; with acceptance
   at W's E7 that is a stall of 17-22 (+12k) clks (sim).
4. **Stall length** [not settled by the front end; guidance]: a per-commit
   comparison needs identical stall lengths, because the stall length decides
   S2 (one extra commit of the re-presented address). In the normal
   CALLFUNCTION flow that extra commit is an opcode-fetch re-read and leaves
   state equal, so a comparison may merge consecutive identical-address read
   commits around a stall. In the S3/S5 cases (late acceptance, RMW
   CALLFUNCTION) the stall timing changes front-end state (double register
   side effect, or a lost arming), so there the clone must reproduce the
   upstream stall timing or the comparison must accept the divergence.
5. **29696-byte images** [settled as far as `rtl/` goes]: `rtl/` assumes the
   32K layout everywhere (`rom_a` +3072, DPC:127; DMA source +3072, DPC:284;
   RAM init source `0x6C00`, `arm_mapper_ram_init.sv:159`; ARM entry `0xC08`,
   DPC:184) and has no relocation; the mapper load stream and its addresses
   are TOP inputs (TOP:104-108) and the ROM load is the wrapper's. A 29K
   image can only run if the wrapper places it at +3072, both in the ROM
   memory and in the DDR3 shadow (which also bounds the ARM's ROM view by the
   loaded size, `arm_mapper_memory.sv:775-777`). Whether MiSTer's wrapper
   does this is not visible, and no intent is stated anywhere in `rtl/`.
   For the clone: reproduce `rtl/` as is (no relocation); relocating would
   be a desync (§15).
6. **Pocket `EXTERNAL_CARTRAM`** [answered]: upstream's DPC+ cannot work with
   it at all. With `EXTERNAL_CARTRAM` TOP ties `arm_ram_accepted = 0`,
   `arm_ram_rdata = 0` and `cartram_word_data_tdp = 0`, and passes
   `cartram_data` through without the pause override (TOP:937-942). So the
   ARM gets no RAM, every DMA (RAM init included) waits forever on
   `ram_accepted` (`arm_mapper_memory.sv:878-879`), `mapper_init_busy` never
   falls, no call or service is ever accepted, and NOTE loads 0. The Pocket
   also sets `NO_ARM_MAPPER` (`ap_core.qsf:736,748-749`). The reference
   timing for a comparison is therefore `cart_ram_tdp`'s (§9.3); a Pocket
   clone that uses the SRAM (`core/sram_ctrl.sv:13-37`: 5+1 `clk_sdram` per
   access, 2600-mode reads re-served on address change, requested by
   `cartram_rd | bios_rd`, `core/atari7800_pocket.sv:1090`) must still
   present `RAM[ram_a in (E4,E5)]` at E6 and the same `ram_sel`/grant pattern
   to match.
7. **PAL** [answered]: `CLK_RATE` is a fixed parameter
   (`arm_mapper_audio.sv:8`) not overridden at the instance (C26:760); TOP's
   `pal` reaches only the ARM subsystem (C26:445). With MiSTer's PAL clk_sys
   of 14.18758 MHz the tick is 20000 × 14187580/14318182 ≈ 19817.6 Hz. For a
   per-tick comparison this does not matter as long as both sides count the
   same accumulator on the same clk_sys from the same reset: ticks fall on
   identical clk_sys edges.
8. **Revision under a user override** [facts settled, intent not]: a forced
   DPC+ uses the detector's `mapper_revision[0]` (§10 lists when it is 1).
   Forcing 0 would be cheap, but it changes forced-DPC+ behaviour relative to
   upstream (FRACLOW low byte kept instead of cleared), so under the
   "guard only if it does not desync" rule it should not be done in the
   compared clone (§15). Related: a DPC+ forced after the load also gets no
   RAM init (§9.4).

---

## 17. Simulation record [added]

ROM-free directed bench, written for this review, in
`dpcplus_sim/tb.sv`
(Verilator 5.020, `--binary --timing`). DUT: upstream
`6502/mos6502*.sv` (unmodified except two unknown-to-this-Verilator lint
pragmas stripped; `mos6502` instantiated directly, without the `sally`
wrapper, whose only addition is the HALT gate, idle with MARIA disabled) and
`mapper_dpcplus.sv`. Glue transcribed from TOP/C26:
`pclk1` at phase 11, `pclk0` at phase 5 of a 12-clk counter; WSYNC set/clear
latch and `tia_RDY_seen_high`; `stall_cycle_taken`/`mapper_phi2`/RDY;
`old_ain`/`address_change`/`access_taken`/`cartram_wr`; a 1-clk
registered cart RAM; the C26 output mux; a ROM with `romlat` registered
address stages (romlat = k ⇔ L = k); a call model that sets busy at the
accept edge and drops it `stall` clks later (`call_ready = !busy`). Program
(hand-written, bank 5): DF0LOW=$10, DF0HI=0, FASTFETCH on, then per test.
RAM $0C10+i = $40+i. `commits − completed` counts `mapper_phi2` pulses minus
`pclk0`s with `hold = 0`, from the first write of $105A on.

| Test | Program | Result |
|---|---|---|
| 0 | `STA WSYNC; LDA #$08; STA $80; LDA #$08; STA $81; STX $105A (X=$FE); LDA #$08; STA $82; LDA $1008; STA $83` | `$80=$40` (register byte after WSYNC), `$81=$41`, `$82=$42`, `$83=$43`, counter $14, for every stall 1-50. `commits − completed` = +1 for stall 17-22, 29-34, 41-46, else 0. Trace: held repeats show the opcode address ($110F / $111C), completion shows the operand address. |
| 0, L sweep | same, stall 40 | L = 0..4 correct; L = 5: the three fast-fetch DATA reads return $00 (direct `LDA $1008` still $43). |
| 1 | `STX $105A` (FE) with `call_ready` held low, then `LDA $1008` ×40; `call_ready` released at clk T (sweep 61 values) | stall 120: +1 commit for every T; counter +1 extra when the held cycle follows the $1008 cycle (S2 or S3 on $1008). stall 126: +2 or 0 by phase; +2 extra counter steps when both hit $1008. |
| 2 | `INC $105A` (ROM byte $FE) then `LDA #$08; STA $82` | stall 40: `$82 = $08` (ROM operand: the $A9 fetch after the second write was hidden, S5); stall 46: correct with +2 commits; stall 60: correct, 0. |
| 3 | `STA DF0WRITE` ($AA), `STA DF0WRITE` ($BB), `STA DF0PUSH` ($CC) | RAM $0C10=$AA, $0C11=$CC, $0C12 untouched ($42); counter $11. |

Not covered by the bench (outside the front end, or needing parts not
modelled): the DMA service path (same TOP mask as the call, so S2/S3/S5
apply equally), the real ARM controller's CDC delays, MARIA→TIA phase
handoff, the audio block.
