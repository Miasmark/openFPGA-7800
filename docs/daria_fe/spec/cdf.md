# Upstream CDF family front end: CDF0, CDF1, CDFJ, CDFJ+

This is a cycle-exact behavioural spec of upstream's CDF family front end. It covers `mapper_cdf`, its fast-jump map, its stream tables, and the glue in `cart2600` and `top.sv` that the front end depends on. It describes upstream as written, quirks included. It is the target for a clone that will be compared at every 6507 latch edge, per commit and per audio tick.

No game data appears here. All numbers are RTL constants or are derived from the RTL.

> **Checker's pass (adversarial review).** Every behavioural claim was re-read against the cited lines.
> - `[checked]` marks a claim that was verified.
> - `[corrected: …]` marks a fix or an addition.
>
> The main changes:
> - every `AMT:` citation was wrong and has been fixed;
> - open questions 1, 2, 3 and 5 are settled from upstream's own wrapper and PLL, and by simulation;
> - the CALLFN/WSYNC bus behaviour now comes from the CPU's `wr_q` and phase-1 hold, with exact commit counts (§0.2, §12.5, §15, §15.1);
> - the per-edge `rom_do` sequence on upstream's SDRAM path is given exactly (§12.3);
> - new quirks Q24-Q27 and guards G8-G11 are added;
> - Stella parity is checked (§19.7).

---

## 0. Sources, notation, clock reference

### 0.1 Source keys

All paths are under `src/fpga/mister/rtl/` unless they start with `src/`. Upstream commit: `src/fpga/mister/UPSTREAM_COMMIT` (`ffc47192…`).

| Key | File |
|---|---|
| MC | `mapper_cdf.sv` |
| FJ | `cdf_fastjump_table.sv` |
| AMT | `arm_mapper_tables.sv` |
| C26 | `cart2600.sv` |
| D26 | `detect2600.sv` |
| TOP | `top.sv` |
| RI | `arm_mapper_ram_init.sv` |
| WB | `arm_mapper_writeback.sv` |
| CRT | `cart_ram_tdp.sv` |
| CR | `cache_ram.v` |
| AUD | `arm_mapper_audio.sv` |
| CTL | `arm_mapper_controller.sv` |
| MEM | `arm_mapper_memory.sv` |
| TIA | `TIA.sv` |
| MAR | `Maria/maria.sv` |
| DP / CPU / C65 | `6502/mos6502_dp.sv` / `6502/mos6502.sv` / `6502/mos6502_ctl.sv` |
| SDR | `sdram.sv` (upstream's own SDRAM controller; it is the platform ROM path on MiSTer, see WR) |
| POK | `src/fpga/core/atari7800_pocket.sv` (this repo's wrapper; informative. The Pocket build defines `NO_ARM_MAPPER`, so CDF is not built there at all: C26:158-167, 585-650) |
| PLL | `src/fpga/mister/rtl/pll/pll_0002.v` (upstream's PLL IP: 14.318182 / 57.272728 / 7.159091 / 71.590910 MHz, all 0 ps, lines 38-50) |
| WR | Upstream's MiSTer wrapper `Atari7800.sv` at the pinned commit `ffc47192`. **Not in this repo.** [corrected: the checker fetched it read-only from `raw.githubusercontent.com/MiSTer-unstable-nightlies/Atari7800_MiSTer/ffc47192…/Atari7800.sv` (MIT header) to settle open questions 1 and 2; line numbers refer to that file.] |
| STL | A Stella `CartCDF.cxx` (2026 header, version not pinned) found in this session's scratchpad (`scratchpad/ref/CartCDF.cxx`). Used only for the informative parity notes in §19. |

[corrected: every `AMT:` line number in the first draft pointed past the end of the file (`arm_mapper_tables.sv` has 186 lines). The correct ranges are: family/revision flops AMT:57-70; `layout()` AMT:73-129, of which the CDF cases are AMT:104-122 (CDF0 107-110, CDF1 112-115, CDFJ/J+ 116-120); both layouts evaluated AMT:131-136; ARM snoop index and enables AMT:139-150; port-A address muxes AMT:151-155; `pointer_ram` AMT:157-170; `increment_ram` AMT:172-185. All `AMT:` citations below have been rewritten to these.]

### 0.2 Clock reference (E0)

- **clk_sys** is 14.318181 MHz (POK:10; AUD:8, `CLK_RATE`). [checked for NTSC (PLL:39). On PAL upstream retunes the PLL so clk_sys = 14.18758 MHz (WR:340-365). Every figure here is in clk_sys units and does not change. AUD keeps its default `CLK_RATE` (the instance passes no parameter, C26:760), so its tick runs at 20 kHz × 14.18758/14.318182 on PAL. That is an AUD property, but it sets when `amplitude` changes.]
- **E0** is the clk_sys rising edge at which `pclk1` (the paired phase-1 enable) is sampled high.
  - `pclk0` (the phase-2 enable) is sampled high at **E0+6**.
  - The next E0 is **E0+12**.
- **Derivation of the 6/6 split:**
  - TIA's divider steps on every `ce` = `tia_clk_x2`. That signal is high on every second clk_sys (MAR:154, 197-199; TIA:498-500).
  - `pclk_div` counts 0..5 (TIA:557). Phase-2 fires at div 2 and phase-1 at div 5 (TIA:505-506).
  - So phase 1 to phase 2 is 3 steps (6 clk_sys), and phase 2 to the next phase 1 is 3 steps (6 clk_sys). DARIA_CORE F1 (`docs/DARIA_CORE.md:78`) states the same.
  - The CPU and the rest of the system get the same paired pulses (TOP:1421-1435, 712-717).
- **Exceptions:** an RSYNC can move the divider and shorten a cycle (TIA:506 `resp0` term, TIA:565-567). Every E0+n figure here assumes the nominal 12-clk cycle. The mapper itself never counts clocks; it acts on the `pclk0` edge whenever that comes.
  - [corrected: `resp0` in TIA:506 is *not* the RESP0 register strobe. It is the clock generator's local wire `resp0 = (hclk.level_p2 && rsynd) || reset` (TIA:528), and `rsynd` is the end-of-line decode `eer = ehb || rsynl || err` passed through an inverter register (TIA:610, 647). The same `rsynd` forces `pclk_div <= 2` (TIA:565-567). A normal line is 456 divider steps (76 × 6), so once the first line has aligned the divider, every later re-force lands on the value it already holds and nothing moves; the `resp0 && pclk_div == 0` term needs phase 2 with `pclk_div == 0`, which the steady ÷6 sequence never produces (phase 2 spans div 3-5, TIA:504-506, 557). It moves the divider only after an RSYNC write has reset the horizontal counter mid-line (`hclk_counter.reset = rsync`, TIA:516-519, 1972). The phase lengths are always even numbers of clk_sys, because `pclk_edge` only occurs on `tia_clk_x2` (every second clk_sys, MAR:154, 197-199).]
  - [corrected: effect on the E0+n budget. Let **L1** = (commit edge − E0), which is 6 nominally and can be 2 or 4 after an RSYNC. Every requirement in §12.2 scales with L1: RAM substitution needs k ≤ E0+L1−2, the pointer update needs k ≤ E0+L1−1, amplitude and arming need k ≤ E0+L1. On upstream's SDRAM path (k = E0+2 for a same-word read, E0+3 otherwise, §12.3), L1 = 4 already breaks a different-word substituted RAM read, and L1 = 2 breaks even a plain different-word ROM read. Phase 2 length (commit to next E0) only shortens the post-commit window. The writeback round trip (3 clk, §14.3) still fits, because two commits are always ≥ 4 clk apart.]
- **Edge and cycle conventions:**
  - "Edge E0+n" means the n-th clk_sys rising edge after E0.
  - "Cycle (E0+n-1, E0+n]" means the clk_sys period that ends at that edge.
  - A combinational value "at edge X" is its value during the period ending at X. That is what every register clocked at X samples.
- **What the 6507 does on each edge:**
  - At **E0** it loads its address (DP:202, 225-226), R/W (CPU:130-137) and write-data register DOR (DP:228, 320). RDY is read once, at E0 (C65:875-880).
  - At **E0+6** it latches read data DL (DP:267, 299). This is the "latch edge". DL is loaded at *every* phase 2, held or not (DP:299); only the T-state and control word are frozen by a hold (C65:1398-1400).
  - [corrected: RDY acts in two places, and the difference decides what the mapper sees. (1) The T-state hold at the phase-2 edge is `hold = ~rdy_q & ~wr_q`, where `rdy_q` is RDY sampled at E0 and `wr_q` is the *previous* cycle's write flag, latched at the previous phase 2 (C65:874-881, 1392-1394). So the cycle right after a write is never held. (2) At the phase-1 edge `rdy_cy` is the *live* RDY (C65:875), and `hold_mask` stops ABL and PC from loading (C65:936-958). So when RDY is low at the E0 that follows an unheld read, the bus repeats that read's address. Net effect on the bus: after a write that pulls RDY low (WSYNC, CALLFN), the next read's address is presented once normally and then repeated until an E0 samples RDY high. Confirmed in simulation (§15.1).]
- **`access`** = `arm_access` = `phi2 && arm_driver_run` (C26:247).
  - `phi2` = `mapper_phi2` = `pclk0 && (!arm_call_stall || !stall_cycle_taken)` (TOP:320-327, 1135).
  - `arm_driver_run` = `lock_ctrl && tia_en` (TOP:1136).
  - `access` is a one-clk pulse, high only in (E0+5, E0+6]. **Every `access`-qualified register update in the front end therefore happens on the same edge, E0+6, where the CPU latches.** This edge is called the *commit edge*. [checked] A phase 2 hidden by the call stall produces no `access` at all, so no commit and no DSWRITE strobe; cart2600's `access_taken` is set by the same gated `phi2` (C26:255-261).

### 0.3 Front-end inputs as seen by `mapper_cdf`

| Input | Driven by |
|---|---|
| `a_in[12:0]` | `{AB[12] & bios_en_b, AB[11:0]}` (TOP:1128). Changes only just after E0. |
| `rw` | `RW` (TOP:1129). Changes only after E0. |
| `d_in` | `RW ? read_DB : write_DB` (TOP:1112). On a write this is DOR, valid from E0 (DP:228, 320). |
| `rom_data` | `rom_do` (C26:848): the platform ROM byte for `rom_a`. Its arrival time is set by the platform (§12.3). [checked: on MiSTer `rom_do` = `cart_data_sd` = `sdram.ch0_dout` with no register in between (WR:568, 787-801; TOP:1149-1150).] |
| `table_pointer[31:0]`, `table_increment[15:0]` | Registered reads of the stream tables (C26:860-861; AMT:157-185). |
| `ram_rdata` | `cartram_data` = `pause ? 8'hFF : cart_ram_tdp.mapper_rdata` (C26:869; TOP:936). |
| `amplitude` | `arm_audio_amplitude`, a register in AUD (C26:870; AUD:188, 319-324, 345, 358-359). |
| `fast_jump_valid` | The bitmap q (C26:854, 886-894). |
| `call_ready` | `mapper_call_ready` (C26:661-662, 876). |

---

## 1. Selection and version-detection inputs

### 1.1 Family selection (at `load_end`)

`force_bs <= BANKCDF` when, checked in this priority order (D26:210-222):

1. not an ELF (D26:213);
2. not (size 24576 or 28672 and not DEVC) (D26:214-215);
3. size ≠ 29696 (D26:216);
4. not (`hasMatchCTY` and size ∈ {32768, 61440}) (D26:217);
5. **`hasMatchCDF && cdf_size`** (D26:218).

The two terms of the last test:

- **`hasMatchCDF`** = "CDF" (`43 44 46`) seen 3 times, or "PLUSCDFJ" (`50 4C 55 53 43 44 46 4A`) seen once (D26:444-468).
  - The search runs over the contiguous load byte stream (D26:320-341). The counter is `match_bytes` (D26:1479-1511).
  - The search covers the whole file, not only the first 2 KiB.
- **`cdf_size`**: the file size is exactly 32 K, 64 K, 128 K, 256 K or 512 K (D26:70-72). [checked]

The effective mapper that cart2600 runs is `|mapper ? mapper : force_bs` (TOP:1138). An OSD or header override can therefore select CDF on a file that detection did not mark as CDF. See quirk Q20.

### 1.2 Revision: `mapper_revision`

Only aligned 32-bit little-endian words are examined.

- **Word assembly:** byte 0 is the lowest byte (D26:59-63). A word is complete when `load_addr[1:0]==3` (D26:146). Only `load_addr < 2048` counts (D26:162).
- **Counters** (all reset on `load_start`, D26:118-137):
  - `cdf0_count` saturates at 3. It counts words equal to `0x00464443` ("CDF\0") (D26:171-172).
  - Otherwise, `cdfj_count` saturates at 3. It counts words equal to `0x4A464443` ("CDFJ") (D26:173-174).
  - Otherwise, `cdf1_count` counts "CDF" + byte3 ∉ {00, 'J'} (D26:175-178). **It is computed but never used.**
  - `cdfj_plus` is set when the two previous aligned words are "PLUS" and "CDFJ" and this word is `0x00000001` (D26:179-182). The previous-word registers update for words below 3072 (D26:146-148).
- **Decision at `load_end`** (D26:220-221):

  `mapper_revision = cdfj_plus ? 3 : (cdfj_count>=3 ? 2 : (cdf0_count>=3 ? 0 : 1))`

  So **CDF1 (1) is the fallback.** For example, a file that matched only "PLUSCDFJ" without the aligned `1` word gets 2, 0 or 1. [checked]
  - `mapper_revision` is cleared at `load_start` and again at `load_end` before the decision (D26:205-212), so it is valid from the clk after `load_end`. RAM init and the tables see it at `load_end_d` (C26:572-577, 712). [checked]
- **Consumers:**
  - `mapper_cdf` gets `mapper_revision[1:0]` (C26:849).
  - The tables and RAM init get all 3 bits (C26:678, 714).
  - Detection only produces 0..3 for any family (D26:209-259), so bit 2 is always 0.
- **Derived flags in MC:**
  - `jplus = (revision == 3)` (MC:77).
  - `j_revision = (revision >= 2)` (MC:78).
  - **CDF0 and CDF1 behave identically inside `mapper_cdf`.** They differ only in table layout (AMT:104-122; RI:105-116) and audio waveform base (AUD:100-102).

### 1.3 Feature flags (CDFJ+ driver features)

All are scanned in aligned words below 2048 and reset on `load_start` (D26:129-132).

| Flag | Set when | Gated in MC by |
|---|---|---|
| `cdf_ldx` | a word = `0x135200A2` (D26:163-164) | `jplus` (MC:83) |
| `cdf_ldy` | a word = `0x135200A0` (D26:165-166) | `jplus` (MC:84) |
| `cdf_fetch_offset_enable` / `cdf_fetch_offset` | `(word & 0xFFFFFF00) == 0xE2422000`; offset = `word[7:0]`, and the last match wins (D26:167-170) | **Nothing.** It applies to every revision (MC:89-98). See Q14. |

[checked] All three are sticky until the next `load_start` and are taken from the ROM file, never from cart RAM. Stella differs on the offset (informative, STL:749-776): it scans for it only in the CDFJ+ branch, and it compares against `myRAM[offset]`, the live RAM copy of the instruction's low byte, not a value latched at load.

### 1.4 CDFJ+ call entry and stack

- `cdfj_stack` = the LE word at file offset `0x17F4..0x17F7` (D26:196-198).
- `cdfj_entry` = the LE word at `0x17F8..0x17FB`, `& 0xFFFFFFFE` (D26:199-200).
- Both are captured for every file. Only `jplus` uses them (MC:160-161).
- Those offsets are bank 0's `$1FF4..$1FFB` window in the CDFJ+ layout (§2.2). [checked: the capture is outside the `< 3072` block, so it fires for any file that reaches 0x17FB (D26:196-201).]

### 1.5 RAM size

- `mapper_ram_size = (force_bs == BANKCDF && mapper_revision == 3) ? 32768 : 8192` (TOP:778-783).
- It reads `force_bs`, the detected value, not the effective mapper.
- **Consumers:**
  - the ARM RAM window `0x40000000 + size` (MEM:568-569);
  - RAM init's zero fill `0x800..size-1` (RI:169-172, 217);
  - the CDFJ+ audio sample mask and window (AUD:147-149, 281-285, 339-341).
- The front end's own RAM addresses are bounded by construction:
  - non-plus: `0x0800..0x17FF`;
  - plus: `0x0000..0x7FFF` (§8.3).

### 1.6 Driver gating

- Before `lock_ctrl && tia_en`, `access` never rises (C26:243-247; TOP:1136). The front end keeps its reset state, and reads serve ROM from the reset bank.
- In 2600 mode with the BIOS bypassed, lock and `tia_en` are set on the first clk after reset (TOP:1376-1382). [checked]
- [checked] Gating covers commits only. The substitution predicates have no `access` term (§5.2), but `fast_pending` and `jump_remaining` hold their reset value 0 until a commit, so nothing substitutes before the driver runs.

---

## 2. Per-version parameters

### 2.1 Summary table

| | CDF0 (rev 0) | CDF1 (rev 1) | CDFJ (rev 2) | CDFJ+ (rev 3) | Source |
|---|---|---|---|---|---|
| `jplus` / `j_revision` | 0/0 | 0/0 | 0/1 | 1/1 | MC:77-78 |
| ROM base of bank 0 | 0x1000 | 0x1000 | 0x1000 | 0x0800 | MC:130-131 |
| Reset bank | 6 | 6 | 6 | 0 | MC:166 |
| Pointer format | 12.20 | 12.20 | 12.20 | 16.16 (bit 31 unused for the address) | MC:123-128 |
| Display RAM byte for pointer p | 0x800 + p[31:20] | same | same | (0x800 + p[30:16]) mod 0x8000 | MC:126-128 |
| Fast-fetch step | p + (inc[15:0] << 12) | same | same | p + (inc[15:0] << 8) | MC:123-125 |
| Jump / DSWRITE step | p + 0x0010_0000 | same | same | p + 0x0001_0000 | MC:200-202, 230-232 |
| DSPTR | ((p<<8) & 0xF000_0000) \| (d<<20) | same | same | ((p<<8) & 0xFF00_0000) \| (d<<16) | MC:237-241 |
| Amplitude stream | 34 | 34 | 35 | 35 | MC:81 |
| Jump stream(s) | 33 | 33 | 33 / 34 | 33 / 34 | MC:115-117, 205-206 |
| Jump operand 1 accepted | == 0x00 | == 0x00 | ∈ {0x00, 0x01} | ∈ {0x00, 0x01} | MC:99-101 |
| Jump operand 2 accepted | == 0x00 | == 0x00 | == 0x00 | == 0x00 | MC:101 |
| LDX#/LDY# arming | no | no | no | if `cdf_ldx` / `cdf_ldy` | MC:82-84 |
| Fetch offset | if detected | if detected | if detected | if detected | MC:89-98 |
| Table `stream_count` | 34 | 34 | 35 | 35 | AMT:104-122 |
| Pointer table base, word (byte) | 0x1B8 (0x6E0) | 0x028 (0x0A0) | 0x026 (0x098) | 0x026 (0x098) | AMT:108, 113, 118 |
| Increment table base, word (byte) | 0x1DA (0x768) | 0x04A (0x128) | 0x049 (0x124) | 0x049 (0x124) | AMT:109, 114, 119 |
| Audio waveform base (byte) | 0x7F0 | 0x1B0 | 0x1B0 | 0x1B0 | AUD:100-102 |
| Call entry / stack | 0x0000_0808 / 0x4000_1FFC | same | same | `cdfj_entry` / `cdfj_stack` | MC:160-161 |
| `mapper_ram_size` | 8 K | 8 K | 8 K | 32 K | TOP:778-783 |

[checked] Every row above was re-read against the cited lines. The bases, amplitude stream, jump mask and waveform base also agree with Stella (STL:749-821): byte bases 0x6E0/0x768, 0x0A0/0x128, 0x098/0x124, 0x098/0x124; amplitude 0x22/0x22/0x23/0x23; operand-1 mask 0xFF/0xFF/0xFE/0xFE; waveform base 0x7F0/0x1B0/0x1B0/0x1B0.

### 2.2 Bank mapping and ROM address

`rom_a = base + {bank, 12'b0} + a_in[11:0]` (19-bit, MC:130-131). cart2600 passes it unmasked, because CDF is not in the wrap list (C26:195-197).

The hotspots are `a_in[11:0]` in `0xFF4..0xFFB`, on reads or writes (MC:182-192):

| Offset | non-plus `bank` (`a[2:0]-5`, FF4/FFB forced 6) | plus `bank` (`a[2:0]-4`, FF4/FFB forced 0) |
|---|---|---|
| FF4 | 6 | 0 |
| FF5 | 0 | 1 |
| FF6 | 1 | 2 |
| FF7 | 2 | 3 |
| FF8 | 3 | 4 |
| FF9 | 4 | 5 |
| FFA | 5 | 6 |
| FFB | 6 | 0 |

- The formula alone already gives FFB→6 (non-plus) and FF4→0 (plus). Each special case changes only the other entry: FF4 would be 7 (non-plus) and FFB would be 7 (plus). Bank 7 is unreachable.
- ROM windows:
  - non-plus: bank b covers `0x1000+b·0x1000 … +0xFFF`, so bank 6 = `0x7000..0x7FFF`;
  - plus: bank b covers `0x0800+b·0x1000 … +0xFFF`, so bank 6 = `0x6800..0x77FF`.
- All 6507-visible bytes lie below 32 KiB in every version. That is what lets the 15-bit fast-jump map cover them (§10.1). [checked]
- [checked] `bank` is a register, and `rom_a` and the fast-jump query address are combinational in it (MC:130-131; C26:883-884). Both therefore change in the clk after a hotspot commit, (E0+6, E0+7]. On upstream's ROM path that does **not** start a new ROM read (§3, §6): `rom_do` keeps the old bank's byte until `a_in` next changes.

---

## 3. Glue in cart2600 and top.sv

- **Instance** (C26:841-879):
  - `reset = reset || mapper != BANKCDF`, where `reset` is the console `effective_reset` (TOP:255, 1130).
  - `access = arm_access`.
  - `table_increment = table_increment[15:0]`: only the low half of the 32-bit increment word reaches the mapper (C26:861).
- **Table index and write muxes** (C26:663-673):
  - Both lookup indices are `cdf_table_index` when `mapper==BANKCDF`.
  - `table_pointer_write = mapper==BANKCDF && cdf_pointer_update`.
  - The write index and value come from the CDF.
- **Stream tables** (C26:675-706):
  - `family = 2` for CDF (C26:652-653) and `revision = mapper_revision`.
  - The sys pointer port writes come from `init || table write`, and init wins both index and data (C26:687-691).
  - The sys increment port is written only by init (C26:692-694).
  - Map writes (init or BUS) are discarded for the CDF family, because `sys_map_write_valid` needs `family==BUS` (AMT:153-155; arm-side map writes are blocked the same way, AMT:148-150).
  - The ARM snoop port sees `arm_cartram_{en,write,addr,wdata,wstrb}` qualified by `arm_cartram_accepted` (C26:701-705).
- **RAM init** (C26:708-737):
  - `family = init_family = 3` for CDF (C26:658-660); this is a different encoding from the tables' 2.
  - `load_end = load_end_d`, `load_end` delayed one clk (C26:572-577, 712).
  - `mapper_reset` is the console reset.
  - [checked] RAM init triggers on `load_end_d` and on every rising edge of `mapper_reset` while `image_loaded` (RI:204-226). Its `busy` covers the whole download (`loading`) and every init state (RI:75). Upstream's wrapper ORs `mapper_init_busy` into the console reset (WR:75-78, registered on clk_sys), so the CDF front end is held in reset for the whole init and never drives port A meanwhile.
- **Writeback** (C26:739-758):
  - `pointer_write = table_pointer_write`.
  - `pointer_addr = table_pointer_base + {9'b0, index}`, a word address.
  - The map path is BUS only.
  - `idle → mapper_wb_idle`.
  - Both sides are reset by the console reset (C26:741, 751).
- **Shared ARM-side RAM port:** writeback wins over the ARM (C26:430-439). `arm_cartram_accepted = arm_cartram_en && !mapper_wb_en && arm_ram_accepted` (C26:437-438).
- **Fast-jump query:** `rom_addr[BANKCDF][14:0]`, shared with BUS (C26:883-894).
- **Cart RAM select** (C26:896-898):
  - `ram_sel = cdf_ram_en`;
  - `ram_rw = !cdf_ram_write`;
  - `ram_a = {3'b0, cdf_ram_addr}`.
- **Call mux:** the CDF request, entry, stack and thumb are selected when `mapper==BANKCDF` (C26:945-953).
- **Cart RAM port A** (C26:965-978; TOP:752-759, 918-936):
  - `cartram_addr = init_ram_en ? init : (sel_ram_sel ? sel_ram_a : audio_ram_addr)`.
  - `cartram_wr = !init_ram_en && sel_ram_sel && !sel_ram_rw && ~phi1 && ~address_change && ~access_taken`.
  - `cartram_wrdata = d_in`. **`cdf_ram_wdata` is unused** (C26:977); the two are equal anyway (MC:138).
  - Outside init, port A is enabled every clk while not paused: `mapper_en = !pause` (TOP:921). `cartram_rd` therefore has no effect outside init.
- **Platform ROM read request:** `rom_read = ~address_change` (C26:157), and `address_change = old_ain != a_in` (C26:241, 263-265). It drops for exactly the one clk after `a_in` changes. **A bank switch does not pulse it.** [checked]
  - [corrected: it is not gated by A12 or by R/W. Every `a_in` change starts a ROM read of `rom_a` for the new `a_in`, including zero-page, TIA, RIOT and write cycles. On MiSTer: `cart_read = read_2600` in 2600 mode unless paused (TOP:331), and `ch0_rd = cart_read & ~cart_download & ~reset`, `ch0_addr = cart_addr = {6'b0, rom_a}` (WR:796-799; TOP:1108, 1149-1150). So "the previous read" in §12.3 means the previous cycle whose `a_in` differed, whatever it addressed.]
- **Output mux** (C26:211-234):
  - If `|out_en`, that is `a_in[12]`:
    - `flags[0]` → `d_out` = mapper `d_out`, `oe = FF`;
    - else if `ram_sel` with `ram_rw=0` (only DSWRITE) → `d_out = 00`, `oe = 00`;
    - else `d_out = rom_do`, `oe = FF`.
  - If `a_in[12] = 0`: `d_out = 00`, `oe = 00`.
  - `flags[1]` and the `ram_sel && ram_rw` branch never occur for CDF.
  - The bad-game screen is never shown for CDF in the ARM build (C26:165-166). [checked]

---

## 4. State and reset values

Reset is synchronous on any clk with `reset || mapper != BANKCDF` (MC:164-176; C26:843). [checked: every register in the table, widths and values re-read. The reset bank reads `revision` live during reset (MC:166), so it follows `mapper_revision` as it stands while reset is high.]

| Register | Width | Reset value | Changes on |
|---|---|---|---|
| `bank` | 3 | plus ? 0 : 6 (MC:166) | E0+6 commit |
| `mode` | 8 | 0xFF (MC:167): fast fetch off, digital audio off | E0+6 (SETMODE) |
| `fast_pending` | 1 | 0 | E0+6 |
| `fast_expected_address` | 13 | 0 | E0+6, only when arming |
| `jump_remaining` | 2 | 0 | E0+6 |
| `expected_address` | 13 | 0 | E0+6 |
| `jump_stream` | 6 | 33 (MC:172) | E0+6 |
| `call_pending` | 1 | 0 | set E0+6 (CALLFN); cleared on any clk with `call_pending && call_ready` (MC:179-180) |
| `pointer_update` | 1 | 0 | one-clk pulse: set at E0+6, cleared at the next clk (MC:178) |
| `pointer_update_index` / `_value` | 6 / 32 | 0 / 0 | E0+6; hold otherwise |

**State outside `mapper_cdf` that the front end depends on:**

- the pointer and increment tables (64×32 each, AMT:157-185; power-up zero per CR:230);
- cart RAM (CRT);
- the fast-jump map (32768×1, FJ:42-51; power-up zero per CR:41);
- the writeback mailbox (WB);
- the audio `amplitude` register (AUD).

A console reset does not clear the tables or RAM directly. It re-runs RAM init (§14.1). [checked] The fast-jump map is never touched by any reset; only a download rewrites it.

---

## 5. Combinational behaviour (every clk_sys)

### 5.1 Derived values

- `fast_mode = (mode[3:0] == 0)` (MC:79).
- `digital_audio = (mode[7:4] == 0)` (MC:80).
- `amp = j_revision ? 35 : 34` (MC:81).
- `opcode_arms_fetch = rom_data==A9 || (jplus && ldx && rom_data==A2) || (jplus && ldy && rom_data==A0)` (MC:82-84).
- **Operand range** (MC:89, 94-96):
  - without offset: `rom_data <= amp`;
  - with offset: `rom_data >= off && rom_data <= off + amp`, a 9-bit compare, so there is no wrap.
- `normalized = offset_en ? rom_data - off : rom_data` (8-bit) (MC:97-98).
- `amplitude_operand = offset_en ? (amp + off[5:0])[5:0] : amp` (MC:90-93).
- **`jump_operand_valid`** (MC:99-101):
  - `(jr==2 && (j_revision ? rom_data[7:1]==0 : rom_data==0))`
  - or `(jr==1 && rom_data==0)`.

[checked] All of §5.1 against MC:77-101. Widths: `fetch_limit` 9 bits, `amplitude_operand_sum` 7 bits, `normalized_operand` 8 bits, `table_index` 6 bits, `display_address` 15 bits, `pointer_step` 32 bits (MC:59-75).

### 5.2 Substitution predicates

None of these predicates include `access`. They are live for the whole cycle and evaluate whatever `rom_data` currently shows (§12.2). [checked] The address compares are full 13-bit compares against `a_in`, which carries the slot's gated A12 (TOP:1128).

- `jump_substitute = rw && a_in[12] && jr!=0 && a_in==expected_address && jump_operand_valid` (MC:102-103).
- `fetch_substitute = rw && a_in[12] && fast_mode && fast_pending && a_in==fast_expected_address && operand_in_range` (MC:104-105).
- `stream_substitute = jump_substitute || fetch_substitute` (MC:106).
- `amplitude_fetch = fetch_substitute && !jump_substitute && rom_data[5:0] == amplitude_operand` (MC:111-112).
  - This is the same as `normalized == amp`, because `normalized ∈ [0, 35] ⊂ [0, 63]` whenever it is in range.

### 5.3 Table index and the pointer arithmetic

`table_index` (MC:115-121, 150-151):

- if `jump_substitute`: `jump_stream + ((j_revision && jr==2) ? rom_data[0] : 0)`;
- else if `fetch_substitute`: `normalized[5:0]`;
- else: **32**.

The DSWRITE branch also forces 32, which is redundant because writes never substitute. **So whenever nothing substitutes, both tables are continuously looked up at stream 32.**

The arithmetic on the looked-up words:

- `pointer_step = jplus ? p + (inc<<8) : p + (inc<<12)`, 32-bit, wrapping (MC:123-125).
- `display_address = jplus ? (0x800 + p[30:16]) mod 2^15 : 0x800 + p[31:20]` (MC:126-128).
- Here `p = table_pointer` and `inc = table_increment[15:0]`, both the registered table outputs for the index sampled at the previous clk edge. [checked] The one exception is the clk after a pointer write: the pointer port's address at that edge was the write index, and q shows the written value (new-data read-during-write, CR:232, 275). Seen in simulation (§15.1): after a commit at E0+6, q in (E0+7, E0+8] is the new word of the updated stream, and index 32's word follows from (E0+8, E0+9].

### 5.4 Outputs

- Defaults (MC:130-138):
  - `rom_a` per §2.2;
  - `oe = a_in[12] ? FF : 00`;
  - `flags_out = 0`, `d_out = 0`;
  - `ram_en = ram_write = 0`;
  - `ram_addr = display_address`;
  - `ram_wdata = d_in`.
- If `stream_substitute` (MC:140-148):
  - `flags_out[0] = 1`;
  - if `amplitude_fetch`: `d_out = amplitude` and no RAM access;
  - else: `ram_en = 1` and `d_out = ram_rdata`.
- If `access && !rw && a_in == 13'h1FF0` (MC:150-156): `table_index = 32`, `ram_addr = display_address`, `ram_en = ram_write = 1`.
  - This is the DSWRITE store strobe. It is high only in (E0+5, E0+6]. [checked; simulated store at edge E0+6, §15.1]
- Call outputs (MC:159-162):
  - `call_request = call_pending && call_ready`, combinational;
  - `call_entry = jplus ? cdfj_entry : 0x808`;
  - `call_stack = jplus ? cdfj_stack : 0x40001FFC`;
  - `call_thumb = 1`.

---

## 6. Banking

- **Decode** (MC:182-192): `access && a_in[12] && !stream_substitute && a_in[11:0] ∈ [FF4, FFB]`. Reads and writes both count.
- **A substituted read never switches banks.** This covers a fast-fetch operand or JMP operand that happens to sit at FF4..FFB (MC:183).
- **Commit:** E0+6. `rom_a` and the fast-jump query address change immediately after E0+6, so the map q follows at E0+7.
- **Post-commit ROM byte:** on upstream's platform ROM path the read request is level `~address_change` (C26:157). A bank change with the same `a_in` does not start a new ROM read on the SDRAM path (SDR:88, 95). So `rom_do`, and therefore `d_out`, keeps the pre-switch byte until `a_in` changes at the next E0 (§12.4). [checked]
- [corrected: added] **Repeated address after a hotspot commit.** If the next 6507 cycle presents the *same* `a_in`, no ROM read starts for it either. That happens when RDY repeats an opcode-fetch address after a write (§12.5, §15.1), on the RMW dummy cycles, or with `STA abs,X` dummy-read-then-write. In that cycle `rom_do` still holds the **old** bank's byte, while `rom_a`, and with it the fast-jump query (C26:883-884), already point at the **new** bank. Every predicate and arming decision of that cycle (§9.1, §10.3) therefore mixes the old bank's byte with the new bank's map bit, and a read returns the old bank's byte to the CPU. A clone must model `rom_do` as "byte of the last *address change*", not "byte at the current `rom_a`".

---

## 7. Register writes ($1FF0-$1FF3)

### 7.1 Conditions and timing

- **Condition:** `access && a_in[12] && !rw` and `a_in[11:0]` = FF0..FF3. The `case` is on `a_in[11:0]` (MC:182, 194, 225-249).
- **Commit:** E0+6.
- **Write data:** `d_in` = `write_DB`, valid from E0 (TOP:1112; DP:228, 320).
- **Other effects:** writes never touch `fast_pending`, `fast_expected_address`, `jump_remaining`, `expected_address` or `jump_stream` (MC:194-250). Writes to FF4..FFB switch banks (§6). Reads of FF0..FF3 have no register effect.

### 7.2 The four registers

| Address | Name | Action |
|---|---|---|
| `$1FF0` | DSWRITE | **RAM store:** combinational strobe in (E0+5, E0+6] at byte `display_address(ptr[32])` with `d_in` (MC:150-156). cart RAM port A writes it at **edge E0+6** (CRT:61-83, 75; C26:973-977; TOP:921-924). **Pointer:** `ptr[32] ← ptr[32] + (plus ? 0x0001_0000 : 0x0010_0000)`, latched at E0+6 (MC:227-233) and written to the table at E0+7 (§11.2). |
| `$1FF1` | DSPTR | Plus: `ptr[32] ← ((ptr[32]<<8) & 0xFF00_0000) \| (d << 16)`. Non-plus: `ptr[32] ← ((ptr[32]<<8) & 0xF000_0000) \| (d << 20)` (MC:234-242). Two writes d1, d2 give non-plus `p[31:20] = {d1[3:0], d2}` or plus `p[31:16] = {d1, d2}`, with the fraction cleared. |
| `$1FF2` | SETMODE | `mode ← d` (MC:243). `fast_mode` and `digital_audio` follow combinationally after E0+6. |
| `$1FF3` | CALLFN | If `d ∈ {0xFE, 0xFF}` and `!call_pending`: `call_pending ← 1` (MC:244-247). Other values are ignored. FE and FF are identical here; the entry and stack do not depend on `d` (MC:160-161). |

[checked] All four rows against MC:225-249.

### 7.3 DSWRITE store details

- `ptr[32]` used for the store is the table output for index 32. Index 32 has been looked up on every clk of the write cycle, and on the clks after any previous commit's write-back clk (§13.1). So the store address is `ptr[32]` *before* this commit's increment.
- `cartram_wr` additionally needs `~phi1 && ~address_change && ~access_taken` (C26:973-974).
  - `access_taken` is cleared at E0 (by `phi1`) and also at E0+1 when `a_in` changed, and set at E0+6 by a *shown* phase 2 (C26:255-261). [checked]
  - In (E0+5, E0+6] all three terms are 1, so exactly one store happens. [checked; the store data is DOR, `write_DB`, which the CPU loads at E0 of the write cycle (DP:228); `cartram_wrdata = d_in` (C26:977)]

---

## 8. Streams and tables

### 8.1 Stream roles

| Index | Role |
|---|---|
| 0..31 | General datastreams; fast-fetchable. |
| 32 | The write ("comm") stream: target of DSWRITE and DSPTR. Also fast-fetchable (operand 32 reads `display(ptr[32])` and steps it by `inc[32]`). |
| 33 | Jump stream (every version). Also fast-fetchable with `inc[33]`. |
| 34 | CDFJ/J+: second jump stream, and fast-fetchable with `inc[34]`. CDF0/1: amplitude. |
| 35 | CDFJ/J+: amplitude. |

The fetchable range is 0..amp. Operand == amp returns `amplitude` (§9.3).

### 8.2 Table storage

- **Pointer table:** `cache_ram_tdp_dc_be` 64×32 (AMT:157-170).
  - Port A runs on clk_sys: `addr = sys_pointer_write ? sys_pointer_index : pointer_lookup_index` (AMT:151-152), with byte enables F.
  - Port B runs on clk_arm, for the snoop.
  - Address is registered and output unregistered, so a read takes **1 clk**: q at edge n+1 is the word addressed at edge n (CR:228-229, 275).
  - Same-port read-during-write returns **new data** (CR:232, 275).
- **Increment table:** the same structure (AMT:172-185). For CDF its port A address is always `increment_lookup_index` = `cdf_table_index`, because sys increment writes happen only during init and map writes are invalid (AMT:153-155; C26:692-699). [checked]
- **Unused high half:** only `inc[15:0]` is used (C26:861). An increment word with bits [31:16] ≠ 0 behaves as its low 16 bits (Q13).
- **Layout** (word address in cart RAM; byte = word·4) (AMT:104-122; RI:105-122):
  - CDF0: pointers `0x1B8..0x1D9`, increments `0x1DA..0x1FB`.
  - CDF1: pointers `0x028..0x049`, increments `0x04A..0x06B`.
  - CDFJ/J+: pointers `0x026..0x048`, increments `0x049..0x06B`.
  - Entry i of a table mirrors RAM word `base + i` for `i < stream_count`.
  - The writeback address for index i is `pointer_base + i` (C26:743-745). Stream 32's word is CDF0 `0x1D8`, CDF1 `0x048`, CDFJ/J+ `0x046`. [checked; the bench's DSWRITE writeback landed on word 0x048 for CDF1, §15.1]

### 8.3 Display data

- Every datastream and jump-stream byte is read from cart RAM at `display_address`.
- **Non-plus:** `0x800 + p[31:20]`, range `0x800..0x17FF`.
- **Plus:** `0x800 + p[30:16]` in a 15-bit adder. It wraps for `p[30:16] ≥ 0x7800` into `0x0000..0x07FF`, which includes the tables (Q11).
- The byte reaches cart RAM port A as `{3'b0, addr}` (C26:898). Port A is word `[16:2]` plus lane `[1:0]`, with a registered lane select (CRT:57, 61-64, 74). Read latency is **1 clk**.

---

## 9. Fast fetch (LDA#, plus LDX#/LDY# on CDFJ+)

### 9.1 Arming

At the commit (E0+6) of every **non-substituted read** with `a_in[12]=1` (MC:194, 210-213):

- `fast_pending ← fast_mode && opcode_arms_fetch`. `rom_data` here is the live ROM byte of this access.
- If that is 1: `fast_expected_address ← a_in + 1` (13-bit; `0x1FFF+1 = 0x0000`).
- Otherwise `fast_expected_address` holds its old value.

Arming does not care what the byte is to the CPU (opcode, operand or data). Any cart-space read of `A9` (or `A2`/`A0` under the plus flags) arms. See Q3. [checked; Stella does the same, STL:321, 362-366]

[checked] "Live ROM byte" means `rom_do` as it stands in (E0+5, E0+6]. That is the byte of the last `a_in` change, which after a hotspot commit on a repeated address is the old bank's byte (§6).

### 9.2 Disarming

| Event | Effect on `fast_pending` |
|---|---|
| Any **substituted** read commit (fetch *or* jump) | cleared (MC:196) |
| Any non-substituted cart-space read commit | re-evaluated as in §9.1 |
| Writes | untouched (MC:225-250) |
| `a_in[12]=0` accesses | untouched (MC:182) |

### 9.3 The substituted read

It happens when `fetch_substitute` is true, i.e. the next cart read is at `fast_expected_address` and in range (§5.2).

- **Stream index:** `idx = normalized[5:0]`. With offset `o` the operand range is `[o, o+amp]` and `idx = operand - o`. Without offset the range is `[0, amp]`.
- **Data (non-amplitude case):** `d_out = cart RAM[display_address(ptr[idx])]`, through the 2-clk pipeline in §12.2.
  - At E0+6: `pointer_update ← 1`, `index ← idx`, `value ← pointer_step = ptr[idx] + (inc[idx][15:0] << (plus ? 8 : 12))` (MC:197-203).
  - Table write at E0+7.
- **Amplitude case** (`idx == amp`, i.e. 34 on CDF0/1 and 35 on CDFJ/J+):
  - `d_out = amplitude`, the AUD register's value in (E0+5, E0+6], i.e. whatever AUD last wrote at or before edge E0+5 (MC:142-143; AUD:317-327, 335-347, 355-361). [checked]
  - **No RAM access and no pointer update** (MC:197).
  - `fast_pending` is still cleared.
- **Other state:** the jump state is untouched by a pure fetch substitution (MC:204-209 only run for jumps). The bank is untouched (§6).
- **Pointer advance per version:** non-plus `inc<<12` on 12.20; plus `inc<<8` on 16.16. In both, `inc = 0x0100` is one display byte per fetch. [checked; simulated, §15.1: three fetches with `inc = 0x0100` on CDF1 each advanced the pointer by 0x0010_0000]

---

## 10. Fast jump (JMP through the jump streams)

### 10.1 Bitmap construction (during load)

FJ:26-63. Writes happen on `load_valid && load_addr < 32768`. `load_addr` is the file offset. [corrected: the cited source was the Pocket wrapper, which does not build CDF. On MiSTer, cart2600's `load_*` are top's `mapper_load_*` (TOP:1159-1163), fed from the HPS download stream: `mapper_load_addr = ioctl_addr`, `mapper_load_valid = ioctl_wr && cart_download`, `mapper_load_start = ~old_cart_download && cart_download` (WR:585-589). A 2600 image is written to SDRAM at the same offset (`cart_write_addr = ioctl_addr` when not a 7800 cart, WR:756, 796). So map entry N and ROM byte `rom_a = N` describe the same file byte.]

- **History registers:** `byte_minus_two` and `byte_minus_one` hold the two previous load bytes.
  - On `load_start` they reset to 0 and `load_valid ? data : 0` respectively, which handles a first byte arriving with `load_start` (FJ:55-63).
- **For `load_addr ≥ 2`:**
  - `map[load_addr-2] ← (b[N]==0x4C && b[N+1][7:1]==0 && b[N+2]==0x00)`, where N = `load_addr-2`.
  - So entry N is computed when byte N+2 arrives (FJ:34-38).
- **For `load_addr` 0 and 1:** entries `0x7FFE` and `0x7FFF` are written 0 (FJ:34-35, 37).
- **Coverage:** entries `0..32765` are defined by the file. Entries `32766` and `32767` are always 0.
  - CDF files are at least 32 KiB (§1.1), so the whole map is rewritten on every CDF load.
  - It is not cleared on `load_start`; stale entries can only survive when a file is shorter than 32 KiB.
- **Meaning:** "the file bytes at N, N+1, N+2 are `4C`, `00|01`, `00`". The first operand is admitted as 0 or 1 for all versions; the mapper narrows it per version (§10.4) (FJ:7-8).

### 10.2 Query

- `query_addr = rom_addr[BANKCDF][14:0]` (C26:883-884). It is `rom_a` for the current `bank` and `a_in`.
- Single-port M10K, registered address, read latency 1 (FJ:28, 42-53; CR:40, 43).
- **Value used at the commit E0+6** = `map[rom_a]` for the current access. `rom_a` is stable from just after E0, or from the previous commit for bank changes, so q is settled from E0+1.

### 10.3 Arming

At the commit of a **non-substituted** read with `a_in[12]=1` (MC:214-223), this priority chain runs:

1. If `jr != 0 && a_in == expected_address`: `jr ← 0`. This cancels: the expected operand was read but did not validate.
2. Else if `fast_mode && rom_data == 0x4C && fast_jump_valid`: arm.
   - `jr ← 2`;
   - `expected_address ← a_in + 1` (13-bit);
   - `jump_stream ← 33`.
3. Else if `jr != 0 && a_in != expected_address`: `jr ← 0`. This cancels on a different address.

The same commit also runs §9.1. A `4C` byte never arms fast fetch, so `fast_pending ← 0` here.

`fast_mode` is tested **only at arming**. `jump_substitute` does not test it (MC:102-103).

### 10.4 Operand substitution

It happens when `jump_substitute` is true: the cart read is at `expected_address`, `jr ≠ 0`, and the live byte validates (§5.1).

**Validation per version:**

- Operand 1 (`jr==2`): CDF0/1 need `00`; CDFJ/J+ need `00` or `01`.
- Operand 2 (`jr==1`): all versions need `00`.

**Stream:**

- Operand 1 uses `33 + (j_revision ? rom_data[0] : 0)`.
- Operand 2 uses `jump_stream`.
- At operand 1's commit, if `j_revision`: `jump_stream ← 33 + rom_data[0]` (MC:205-206).
- So both bytes come from the same stream:
  - CDF0/1: always 33;
  - CDFJ/J+: 33 for `JMP $0000` and 34 for `JMP $0001`.

**Data:** `d_out = cart RAM[display_address(ptr[s])]`. The amplitude case cannot apply, because `amplitude_fetch` requires `!jump_substitute` (MC:111).

**Commit at E0+6** (MC:195-209):

- `fast_pending ← 0`;
- `pointer_update ← 1`, `index ← s`, `value ← ptr[s] + (plus ? 0x0001_0000 : 0x0010_0000)`;
- `jr ← jr-1`;
- `expected_address ← expected_address + 1`.

The increment table is not used for jump streams.

### 10.5 What the CPU gets

`JMP` is 3 consecutive cart reads: opcode, operand 1, operand 2.

- **Both operands valid:** both are substituted, and the CPU jumps to `{byte2, byte1}` read from stream s. Each byte advances `ptr[s]` by one display byte.
- **Operand 1 fails validation:** that read is not substituted. Rule 10.3.1 cancels. The CPU gets the ROM operand, and the hotspot logic applies to it.
- **Operand 1 substituted, operand 2 fails:** the CPU gets stream byte 1 plus the ROM byte 2. Rule 10.3.1 cancels.
  - [corrected: the map guarantees file byte N+2 == 0 for the opcode's own bank, so a live operand 2 that fails needs the operands to come from a different bank than the opcode. That happens when the opcode read itself was a hotspot (FF4..FFB) and switched banks: the opcode is checked against the old bank, the operands are read and validated from the new one (§10.7). A bank *end* does not produce this case. There operand 2 is at A12=0, so it is neither validated nor substituted, and the CPU gets stream byte 1 plus whatever answers at $x000 outside the cartridge (§10.7).]

### 10.6 Cancellation summary

- `jr` is cleared by any **non-substituted** cart-space read commit, except one that re-arms on another `4C`.
  - [corrected: more precisely, a non-substituted read **at** `expected_address` always cancels (rule 1 wins even if its byte is `4C` with the map bit set). A non-substituted read at any other cart address re-arms (`jr ← 2`, rule 2) if it is a valid `4C`, and cancels otherwise (rule 3) (MC:214-223).]
- `jr` is **not** cleared by:
  - writes (MC:225-250);
  - `a_in[12]=0` accesses (MC:182);
  - **fetch** substitutions at another address (MC:204 only runs for jumps). [corrected: this case is unreachable, see §10.7. `fast_pending` and `jr ≠ 0` are never true together, so no fetch substitution can occur while a jump is pending.]
- `expected_address` and `jump_stream` hold their values when `jr = 0`. A register-level comparison must keep these "don't care" values exact (§11.1).

### 10.7 Priority, bank end and hotspots

**Priority over fast fetch.** If both predicates were true:

- `table_index` takes the jump path (MC:115-117);
- `amplitude_fetch` is forced off (MC:111);
- the pointer update uses the jump step (MC:200-202);
- the jump state advances.

Both pending at the same `a_in` cannot happen, because every non-substituted cart read sets `fast_pending` from its own byte and a `4C` never arms it. The priority is defensive.

[corrected: a stronger invariant holds, and a clone may assert it: **`fast_pending && jump_remaining != 0` is never true**. Proof from MC:194-223:
- `fast_pending` only becomes 1 in the non-substituted read branch, from a byte in {A9, A2, A0}.
- That same commit leaves `jr` at 0: rule 1 or rule 3 clears it, and rule 2 needs the byte to be `4C`.
- `jr` only becomes 2 in that branch from a `4C` byte, which leaves `fast_pending` at 0.
- Every substituted commit clears `fast_pending`.
- Writes and A12=0 accesses change neither.
- Reset clears both.]

**Bank end:**

- `expected_address` is 13-bit. A JMP opcode at `a[11:0]=0xFFE` puts operand 2 at 16-bit `$2000`, which is 13-bit `0x0000` with A12=0.
  - That read is never substituted, because the predicate needs `a_in[12]`, and it does not cancel (A12=0).
  - `jr` stays 1 until the next cart-space read, which cancels it.
- An opcode at `0xFFF` puts both operands outside cart space.
- In both cases the map looked at the next *file* bytes, which are the next bank's first bytes (or entries 32766/32767 = 0 at the image end). It did not look at what the 6507 reads.
  - [corrected: precise per version. Non-plus banks 0-5 end at file 0x1FFF … 0x6FFF, so their `$xFFE/$xFFF` entries look at the next bank's first bytes. Bank 6 ends at 0x7FFF, whose entries 0x7FFE/0x7FFF are always 0, so a JMP opcode at bank 6's `$xFFE/$xFFF` **never arms**. Plus bank b ends at 0x17FF + b·0x1000. Bank 6's last two entries, at 0x77FE/0x77FF, look at file bytes 0x7800-0x7801, which no bank shows the 6507.]
- Fast fetch is the same: `LDA #` at `0xFFF` expects 13-bit `0x0000` and never substitutes. `fast_pending` survives until the next cart read.

**Hotspots:**

- A JMP opcode read *at* a hotspot is checked against the pre-switch bank's map entry and live byte. The operands are then read from the new bank. [checked: the map is queried with the pre-commit `rom_a` (C26:883-884), and `bank` changes on the same commit edge (MC:184-192). Stella differs here (informative): a JMP-arming peek returns before its hotspot switch (STL:246-254 vs 324-358), so in Stella a fast-jump `JMP` opcode at FF4..FFB does **not** switch banks. Upstream switches.]
- A substituted operand at a hotspot does not switch banks. A non-substituted one does.

---

## 11. Commit semantics: the complete next-state function

### 11.1 mapper_cdf, evaluated at every clk_sys edge

Let `acc = access` (a pulse at E0+6). Every right-hand side uses pre-edge values.

```
if reset || mapper != CDF:            # C26:843, MC:165-176
    bank=plus?0:6; mode=FF; fast_pending=0; fast_exp=0; jr=0; exp=0;
    jump_stream=33; call_pending=0; pointer_update=0; pu_idx=0; pu_val=0
else:
    pointer_update = 0                                        # MC:178
    if call_pending && call_ready: call_pending = 0           # MC:179-180
    if acc && a_in[12]:                                       # MC:182
        if !stream_substitute && a_in[11:0] in [FF4..FFB]:    # MC:184-192
            bank = map_hotspot(a_in[11:0], plus)              # §2.2
        if rw:
            if stream_substitute:                             # MC:195-209
                fast_pending = 0
                if table_index != amp || jump_substitute:
                    pointer_update = 1; pu_idx = table_index
                    pu_val = jump_substitute ? ptr + (plus?0x10000:0x100000)
                                             : pointer_step
                if jump_substitute:
                    if j_revision && jr == 2: jump_stream = 33 + rom_data[0]
                    jr = jr - 1; exp = exp + 1
            else:                                             # MC:210-224
                fast_pending = fast_mode && opcode_arms_fetch
                if fast_mode && opcode_arms_fetch: fast_exp = a_in + 1
                if   jr != 0 && a_in == exp:                       jr = 0
                elif fast_mode && rom_data == 4C && fast_jump_valid:
                                       jr = 2; exp = a_in + 1; jump_stream = 33
                elif jr != 0 && a_in != exp:                       jr = 0
        else:                                                 # MC:225-249
            case a_in[11:0]:
              FF0: pointer_update=1; pu_idx=32; pu_val=ptr+(plus?0x10000:0x100000)
              FF1: pointer_update=1; pu_idx=32; pu_val=DSPTR(ptr, d_in)
              FF2: mode = d_in
              FF3: if d_in in {FE,FF} && !call_pending: call_pending = 1
```

Here `ptr`, `pointer_step`, `table_index`, `rom_data`, `fast_jump_valid`, `d_in` and the predicates are the combinational values at this edge (§5). In the FF0/FF1 rows `ptr` is the table output for index 32. [checked against MC:164-253]

[checked] `pu_val` is computed from `table_pointer`, which is the word for the index registered at the *previous* edge, while `pu_idx` is the index at this edge. They describe the same stream only if `table_index` was already stable at E0+5, that is k ≤ E0+5 (§12.2). Otherwise upstream writes stream B's stepped pointer into stream A. A clone that is fed the same `rom_do` timeline reproduces this automatically. One that "fixes" it diverges.

### 11.2 Effects outside mapper_cdf, by edge

| Edge | Effect |
|---|---|
| E0+6 | **Cart RAM byte write** for DSWRITE (§7.3). **CPU latches** `d_out` (DP:299). |
| E0+7 | **Pointer table write** at `pu_idx` with `pu_val`. This is port A with `sys_pointer_write` (C26:687-691; AMT:151-152, 159-161); the lookup is pre-empted for this one clk. **Writeback mailbox** latches `{base+pu_idx, pu_val}` and flips its toggle, if the previous one is acknowledged (WB:61-65). **Call controller** samples `call_request`: if ready, `call_busy ← 1` and the payload is latched (CTL:149-161), and `call_pending` clears at this same edge (MC:179-180). |
| E0+7 to E0+9 | `mapper_wb_idle` is low in (E0+7, E0+9], so `mapper_call_ready` is low (C26:661-662; WB:40-41). |
| E0+7.8 | **Writeback word lands in cart RAM** through the ARM port, at the clk_arm edge that ends ARM phase 3 (§14.3). [corrected: exact, not approximate; simulated, §15.1] |

---

## 12. One 6507 cycle relative to E0; what `d_out` shows

### 12.1 Fixed events

| Edge or interval | Event |
|---|---|
| E0 | CPU drives the new `a_in`, `rw` and DOR. `access_taken ← 0` (C26:257). |
| (E0, E0+1] | `address_change = 1`, so `rom_read = 0` (C26:157, 241). Every combinational term re-evaluates on the new `a_in` against the **current** `rom_do`, which is still the previous access's byte (§12.3). [checked; only when `a_in` actually changed. With a repeated `a_in` there is no `address_change`, no ROM read, and `rom_do` keeps the byte of the last address change for the whole cycle.] |
| E0+1 | `old_ain` catches up (C26:263-265), so `rom_read` returns to 1 and the platform ROM read starts. On MiSTer the SDRAM controller sees the rise at its next edge, E0+1.25 (§12.3). The map, pointer table, increment table and cart RAM all register their current addresses, and do so on every edge. |
| E0+k | First edge at which `rom_do` is the correct byte for this access (platform; §12.3). |
| E0+6 | Commit (§11). CPU latch. DSWRITE store. |
| E0+7 | Table write and writeback start; call launch (§11.2). |
| E0+12 | Next E0. |

### 12.2 Read-path pipeline and required ROM arrival

Let edge k be the first edge whose preceding clk shows the correct `rom_do`.

- **Fetch or jump substitution, non-amplitude:**
  - (k-1, k]: `table_index` is correct, and the tables register it at k.
  - (k, k+1]: `table_pointer = ptr[s]`, so `display_address` is correct. `cdf_ram_en = 1` makes it `cartram_addr` (C26:966), and cart RAM registers it at k+1.
  - (k+1, k+2]: `cartram_data` is the stream byte, and `d_out` is correct.
  - **The latch at E0+6 is correct iff k ≤ E0+4.** The pointer update also needs `ptr[s]` at E0+6, which means k ≤ E0+5.
  - [corrected: "iff" is slightly too strong. With k > E0+4 the latch is wrong *unless* a stale byte earlier in the cycle already selected the same stream s. The pipeline only needs `table_index` = s from E0+4 on, whichever byte produced it.]
- **Amplitude:** `d_out = amplitude` from (k-1, k], so k ≤ E0+6 suffices. No RAM access is made.
- **Jump arming:** needs `rom_data == 4C` at E0+6 (k ≤ E0+6). The map q is valid from E0+1.

[checked by simulation, §15.1, with a ROM model giving k = E0+3. Per clk:
- (E0+2, E0+3]: `fetch_substitute` = 1 and `table_index` = s. `cartram_addr` is `display(ptr[32])`, and `d_out` is the RAM byte at the address port A registered at E0+2 (the audio address, 0 here).
- (E0+3, E0+4]: `table_pointer` = `ptr[s]`, and `d_out` = RAM[`display(ptr[32])`].
- (E0+4, E0+6]: `d_out` = the stream byte.
- (E0+6, E0+7]: `d_out` = raw `rom_do`, and `pointer_update` = 1.
- E0+7: table write.
`cdf_ram_en` was high for exactly the 4 clks (E0+2, E0+6].]

**`d_out` during a substituted read cycle, before the commit**, with `oe = FF` throughout:

- while the predicate is false: the current `rom_do`;
- in the first clk with the predicate true: the cart RAM byte at whatever address port A registered on the previous edge. That is the audio engine's address, or 0, when the CDF was not selecting the port (C26:965-967; AUD:129-151);
- in the next clk: the cart RAM byte at `display_address` of the table entry registered one edge earlier. Normally that is index 32, so this shows the write stream's current display byte;
- from (k+1, k+2] to (E0+5, E0+6]: the correct stream byte. In the amplitude case it is `amplitude` from the first clk the predicate holds with the right byte. [checked; simulated, §15.1]

The predicate can turn true early on a stale or transient `rom_do` (Q8). That only changes which garbage appears before k+1; the latch is still correct if k ≤ E0+4.

### 12.3 Platform ROM arrival

[corrected: this was "informative" and based on the Pocket wrapper. It is upstream MiSTer's actual ROM path, settled from WR and PLL:
- `sdram` runs on `clk_vid` (WR:787-792), PLL `outclk_1` = 57.272728 MHz = 4 × clk_sys with 0 ps phase (PLL:39-44; WR:42-50). The wrapper states the 4× and 5× ratios hold across the NTSC/PAL retune (WR:340-342).
- `ch0_rd = cart_read & ~cart_download & ~reset` and `ch0_addr = cart_addr = {6'b0, rom_a}` (WR:796-799; TOP:331, 1108, 1149-1150).
- `rom_do = cart_data_sd = ch0_dout`, combinational from the controller's registers (WR:568; SDR:193).
- No other client uses channel 0 outside a download, and the controller has no refresh timer: it issues AUTO_REFRESH only in place of a same-word read (SDR:101, 164). So the timing below is deterministic.]

The front end does not set `rom_do` timing; the platform does. The start is triggered by the rising edge of `rd = rom_read` (SDR:88, 95-104):

- **Different 16-bit word from the last read:**
  - the request starts at sdram edge E0+1.25;
  - `last_data` loads at E0+2.75 (SDR:63-68, 184-187);
  - so k = E0+3, leaving one clk of slack.
  - Between E0+1.25 and E0+2.75, `ch0_dout = a[0] ? last_data[15:8] : last_data[7:0]` shows a byte of the *previous* word (SDR:193). This is a transient that can satisfy the predicates.
- **Same word** (`last_a` hit, SDR:101): the correct byte appears at E0+1.25, so k = E0+2.

MiSTer's own wrapper is not in the repo (Open question 1). A clone with a clk_sys ROM read at E0+1 would have k = E0+2 and no stale window. [corrected: such a clone would match the latch values but not upstream's transient windows; see below]

[corrected: the wrapper has been read (see WR). Here is what every clk_sys register samples from `rom_do`, for a cycle whose `a_in` differs from the previous cycle's. "Previous" means any cycle, since reads are not gated by A12 or R/W (§3).
- **Edge E0+1:** the previous read's byte.
- **Edge E0+2:** the correct byte if the new `rom_a` is in the same 16-bit word as the previous read, i.e. `rom_a[18:1]` is equal (SDR:101). Otherwise it is `prev_word[rom_a[0] ? 15:8 : 7:0]`: the previous word, at the new address's lane (SDR:193, `a` latched at E0+1.25).
- **Edges E0+3 onward:** the correct byte.
- **Same `a_in` as the previous cycle:** the previous read's byte throughout, even if `bank` changed (§6).

A clone that must match upstream clk by clk, which it must for the `cdf_ram_en` windows and therefore AUD's RAM grant timing (§16), has to reproduce this byte sequence, not just "valid by E0+3".]

### 12.4 After the commit, (E0+6, E0+12]

- A substituted read's predicate is false from E0+6, because `fast_pending=0`, or because `expected_address` has moved on while `a_in` has not.
- So `flags=0`, `ram_en=0`, and **`d_out = rom_do` with `oe = FF`**. That is the raw ROM byte at `rom_a`: the operand index for a fast fetch, `00`/`01` for jump operands. [checked; simulated: (E0+6, E0+7] showed the raw operand]
- After a hotspot commit `rom_a` changes, but on the SDRAM path `rom_do` keeps the pre-switch byte, because there is no new `rd` edge (§6).
- That end-of-cycle value is the bus charge. `open_bus <= DB` every clk (TOP:348-352), and the next cycle's undriven lines read it (TOP:379-393). Only a following TIA or RIOT read with undriven bits can observe it. [checked: in 2600 mode every A12=0 address decodes to TIA (A7=0) or RIOT (A7=1) (`Maria/control.sv:96-101`), and a cart read drives all eight lines (C26:217-231).]
- **Writes:** on a DSWRITE commit, port A returns to the audio engine's address from E0+6. On a write cycle `d_out` and `oe` are irrelevant, because `read_DB` uses the cart only when `RW=1` (TOP:380-393). For DSWRITE they are 0 during the strobe (C26:224-228).

### 12.5 Held reads (RDY low)

- [corrected: what is "held" on the bus. After a write that pulls RDY low (WSYNC, TIA:1966-1972, 2193-2203), the next read, normally the opcode fetch, completes its T-state, because `wr_q` blocks the hold (§0.2). From then on its **address** is re-presented until an E0 samples RDY high (`tia_RDY_seen_high` delays the release to a phase-1 sample, TOP:288-296). Simulated (§15.1): for TIA hold lengths of 13-50 clk after `STA WSYNC`, the next opcode address committed 2-5 times. The following operand fetch (`LDA #` → fast fetch) committed exactly once and returned the correct stream byte in every run.]
- **WSYNC and other non-call RDY holds:** `mapper_phi2 = pclk0`, so each held repetition is a separate access.
  - The first commit of a substituted read clears `fast_pending` (or moves `expected_address`).
  - Repetitions are therefore non-substituted, and the CPU's final latch would get the raw `rom_do`.
  - This is reachable only if RDY holds a substituted read. WSYNC holds the next opcode fetch, which only the zero-page-`A9` pattern can substitute (Q3). [checked; concretely, the write instruction's last *cart* read must be an arming byte at the address just before the next opcode, e.g. `STA ($A9),Y` or `STA $A9,X` aimed at WSYNC. The A12=0 cycles in between do not disarm.]
  - For non-substituted reads repetition is idempotent:
    - the same address re-arms the same `fast_pending`/`fast_exp` and re-arms the same JMP;
    - a hotspot re-selects the same bank. [corrected: the bank is the same, but from the first repetition `rom_do` is the *old* bank's byte while the map query is the new bank's (§6). Arming on a repeat of a hotspot opcode fetch therefore uses the old byte with the new bank's map bit. The CPU latches the same old-bank byte on every repetition, because `rom_do` does not refetch.]
- **Call stall:** see §15.

---

## 13. Console-side memory traffic (clk_sys)

### 13.1 Pointer table, port A

- **Read** at every edge with address `table_index`, except at E0+7 after a commit that set `pointer_update`. That edge **writes** `pu_idx` instead, and q after E0+7 is the new value (new-data read-during-write).
  - From E0+8 the address is index 32 again, because nothing substitutes after a commit within the same 6507 cycle.
- In a cycle with no substitution the address is 32 on every edge.
- In a substituted cycle the address is s from the first clk the predicate holds until E0+6. It is 32 before that, unless a transient (§12.2). [checked; simulated, §15.1]

### 13.2 Increment table, port A

- Read at every edge with address `table_index`.
- Never written by the console. Writes come only from init and the ARM snoop. [checked: no `table_increment_write` path exists for CDF (C26:692-694); `sys_map_write_valid` is BUS-only (AMT:153-155)]

### 13.3 Cart RAM, port A (byte)

- **Address owner per clk** (C26:965-967):
  - `init_ram_en` → RAM init;
  - else `cdf_ram_en` → the CDF's `display_address`. That covers every clk in which a non-amplitude substitution predicate holds, and (E0+5, E0+6] of a DSWRITE;
  - else the audio engine's `ram_addr`, which is 0 outside its ISSUE states (AUD:129-151).
- **CDF reads:** the byte at `display_address(ptr[s])`, registered at each edge from k+1 through **E0+6**. The address is still driven in (E0+5, E0+6], so E0+6 registers it once more.
- **CDF writes:** exactly one byte, at edge E0+6 of a `$1FF0` write.
- **Audio grant:** `audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel` (C26:965). The audio state machine waits in its ISSUE state while the CDF owns the port (AUD:259-262, 302-305, 312-315). [checked. A CAPTURE state reads the data registered at its grant edge, so the CDF taking the port during CAPTURE does not corrupt the audio read (AUD:264-265, 307-308, 317-327). The reverse also holds: in the first clk the CDF's predicate is true, `d_out` shows the audio engine's byte (§12.2).]

### 13.4 Cart RAM, port B (word, ARM side)

- One writeback word write per pointer commit, at the clk_arm edge E0+7.8 (§14.3). [corrected: exact, simulated]

### 13.5 Fast-jump map

- Read at every edge with address `rom_a[14:0]`.
- Never written outside a load. [checked; during a load the load address takes the port (FJ:27-36), so queries are meaningless then, but the console is in reset anyway (WR:75-78)]

---

## 14. Coherence: init, snoop, writeback, call gating

### 14.1 Initial and reset load (RI)

**Triggers:**

- `load_end_d` (RI:212-219);
- every rising edge of the console reset while `image_loaded` (RI:205, 222-226).

**Sequence for family 3 (CDF):**

1. **DMA 1:** copy ROM file bytes `0x000..0x7FF` to RAM `0x000..0x7FF`; `dma_fill=0`, source 0 (RI:149-152).
2. **DMA 2:** fill RAM `0x800..ram_size-1` with `0x00` (RI:169-172).
3. **Pointer pass:** for `i = 0..stream_count-1`, READ (address = word `pointer_base+i`) then WRITE (table ← `mapper_word_rdata`). That is 2 clk per entry (RI:181-199, 255-264).
4. **Increment pass:** the same, over the increment words (RI:266-276).

**So the pointer and increment tables start as the driver image's words** at the bases in §2.1, and display RAM starts at zero.

- Entries ≥ `stream_count` are not loaded. They are never read for data, apart from the amplitude index, whose value is unused.
- **Wrapper difference:** the Pocket wrapper holds the console in reset while `mapper_init_busy` (POK:166-171). Upstream MiSTer's wrapper is not in the repo (Open question 2).
  - [corrected: settled. Upstream's wrapper does the same. Its clk_sys-registered `reset <= RESET | buttons[1] | status[0] | cart_download | bios_download | status[48] | old_cart_download | mapper_init_busy | pll_busy | ~clock_locked` (WR:75-78) feeds top's `reset` (WR:527), and it also passes `loading = … || mapper_init_busy` (WR:528). Because the hold is registered, it starts one clk after `busy`, but `busy` itself starts at `load_start` (`loading`, RI:75, 207-208), or one clk after the reset edge that triggers a re-init (RI:223-224). That reset is already high then, and a button or OSD reset lasts far longer than 2 clk. So the 6507, the CDF front end (`effective_reset`) and the writeback are held for the whole init, and released one clk after `busy` falls, plus `reset_hold`'s phase alignment (TOP:262-283). Nothing in the front end runs against a half-initialised table.]
- The init DMA writes go through the ARM port (MEM:507, 637-641), so they are snooped into the tables too. The pointer and increment passes then overwrite those entries.

### 14.2 ARM → tables (snoop)

- Every ARM-port write that cart RAM **accepts** is mirrored into the tables when its word address is in range (AMT:139-147, 157-185; C26:701-705):
  - pointer range `[pointer_base, pointer_base+stream_count)`;
  - increment range `[increment_base, increment_base+stream_count)`.
- The mirror uses the same `arm_wdata` and the same byte strobes, on the same clk_arm edge as the RAM write.
- `index = (addr[5:0] - base[5:0]) mod 64`. That is exact, because `stream_count ≤ 35 < 64`.
- `family` and `revision` for the snoop pass through clk_sys and then clk_arm flops (AMT:57-70, 131-136).
- **"Accepted"** excludes:
  - the clk_arm edge shared with clk_sys (CRT:29-39, 56);
  - any cycle where writeback owns the port (C26:437-438).
- So snoop writes never land on a clk_sys edge, and port A reads never race them on a shared edge. [checked]
- [corrected: writeback writes are **not** snooped. The table's `arm_write`/`arm_accepted` are the ARM client's own `arm_cartram_*` signals, and `arm_cartram_accepted` is false while `mapper_wb_en` (C26:437-438, 701-702). The writeback only copies a value the table already has, so nothing is lost.]
- Covered writers: the CPU (MEM:637-641) and DMA (MEM:507). There is no ARM-side RAM cache; RAM accesses go straight to the port (MEM:600-601).

### 14.3 Console → RAM (writeback)

- **clk_sys side** (WB:43-73): on `pointer_write` while `ack_sync2 == toggle`, it latches `{addr, data}` and flips `toggle`.
  - **If a previous write is still unacknowledged, the new write is dropped from RAM** (Q15). The table still has it.
- **clk_arm side** (WB:91-131):
  1. 2-flop sync;
  2. `active` with the payload, giving `ram_en = ram_write = 1` and `wstrb = F` (WB:85-89);
  3. on `ram_accepted`: `ack ← token`, `active ← 0`.
- **Timing**, assuming `clk_arm = 5 × clk_sys` with phase 4 ending on the shared edge (CRT:29-54): [corrected: no longer an assumption. Upstream's `clk_arm` is PLL `outclk_3` = 71.590910 MHz = 5 × clk_sys at 0 ps (PLL:48-50; WR:49, 340-342). `arm_phase` is forced to 2 in every clk_sys period from the observed `sys_toggle` change (CRT:41-54), so the phase relation is fixed from the second clk_sys edge after configuration, with no start-up ambiguity. The figures below were reproduced exactly by simulating `arm_mapper_writeback` + `cart_ram_tdp` (§15.1): RAM write at the clk_arm edge E0+7.8 (`arm_phase` 3), `idle` low in (E0+7, E0+9], high from E0+9.]
  - toggle at E0+7;
  - sync1 at E0+7.2, sync2 at E0+7.4;
  - `active` at E0+7.6;
  - accepted, meaning **RAM written**, at E0+7.8 (not the shared phase);
  - `ack_sync1` at E0+8, `ack_sync2` at E0+9;
  - **`idle` true after E0+9.**
- The next possible pointer commit is at least 12 clk later, so no write is ever dropped in practice. [corrected: "at least 12" holds for nominal cycles. With RSYNC-shortened phases two commits can be as close as 4 clk (two 2-clk phases), which still leaves 1 clk of margin over the 3-clk round trip. So Q15 stays unreachable.]
- **Calls:** `mapper_call_ready` requires `mapper_wb_idle` (C26:661-662). An ARM call never starts while a pointer word is unwritten, so the ARM always reads current pointers.

### 14.4 Not cached at all

- Display data: read straight from cart RAM on every substitution, written straight by DSWRITE.
- `mode` (not visible to the ARM).
- Increments: the console never writes them.

### 14.5 Holes

- (a) A CDFJ+ DSWRITE that wraps into `0x098..0x1AF` changes RAM but not the table copy (Q11).
- (b) The writeback drop in Q15.
- (c) Unlike the RAM, the tables are not reset by `mapper != CDF`. They are reloaded only by init. [corrected: neither the tables nor cart RAM are reset by `mapper != CDF`; only `mapper_cdf`'s own registers are (C26:843). Both are rebuilt only by RAM init (§14.1). Table entries ≥ `stream_count` keep whatever an earlier BUS or CDF image left there, but CDF never reads them except the amplitude index, whose word is unused.]

---

## 15. ARM call handshake and the stall

1. **CALLFN commit at E0+6:** `call_pending ← 1`.
2. **`call_request`** = `call_pending && mapper_call_ready`, where `mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy` (C26:661-662) and `arm_call_ready = online && shadow_ready && !mapper_reset && !call_busy` (CTL:86-87).
3. **At E0+7, if ready:** CTL latches the entry, stack and thumb, plus the audio counters and frequencies, and sets `call_busy` (CTL:149-161). `call_pending` clears at the same edge (MC:179-180).
4. **If not ready:** `call_pending` stays set and the 6507 keeps running. The call fires whenever ready rises, and further CALLFN writes are ignored meanwhile (MC:245).
5. **Stall:** `arm_call_stall = tia_en && (arm_call_busy || (!mapper_init_busy && arm_dma_busy))` (TOP:306-307). RDY falls after E0+7 (TOP:328-329) and is read at the next E0 (C65:875-880). So the cycle after the CALLFN write, normally the next opcode fetch, is held.
   - [corrected: `arm_call_busy` is CTL's `call_busy` register (C26:485; CTL:158-160), so the stall is high from (E0+7, …] of the write cycle W. At the next E0 (the opcode fetch F) RDY is low, but `wr_q` = 1 from W blocks the hold (§0.2). **F completes its T-state.** At the E0 after F, live RDY is still low and `wr_q` is now 0, so `hold_mask` keeps F's address on the bus (C65:875-876, 936-958). Every following cycle re-presents **F's address**, with its T-state held, until an E0 samples the stall low. Only then does the next cycle (F+1, normally the operand) start. So the draft's conclusion, \"the opcode fetch is held\", is right at bus level, but the mechanism is \"F completes, then its address repeats\".]
6. **Which phi2s the mapper sees:** `mapper_phi2` shows the **first** phi2 of the stall and hides the rest while `arm_call_stall` stays high (TOP:309-327). Once the stall drops, every phi2 is shown again. So the held fetch may commit a second time at the cycle that completes it (Open question 3). [settled below]
   - [corrected, settled by simulation (§15.1). F's own phase 2 has `stall = 1, taken = 0`, so it is shown and sets `stall_cycle_taken`. That is F's first commit. Repeats of F's address are hidden while the stall is high. Let the stall's first low clk be (E0+c, E0+c+1] of some repeat cycle R, i.e. CTL clears `call_busy` at edge E0+c (CTL:174):
     - **c = 0…5** (the stall drops after the E0 that sampled RDY low, at or before R's phase-2 edge): R is a repeat of F's address, its phase 2 is shown, and **F's address commits a second time**. The next E0 samples RDY high, and F+1 commits once.
     - **c = 6…11** (the stall drops after R's phase 2, at or before the next E0): R's phase 2 was hidden, the next E0 samples RDY high, that cycle is already F+1, and **F commits once**.
     - In every case F+1 commits exactly once and, for `LDA #`, is substituted correctly. F's count is 1 or 2 depending only on `(call length) mod 12`.]
7. **CDF safety:** in CDF this repeat is harmless.
   - After `STA $1FF3` the last cart reads were `8D`, `F3`, `1F`, so `fast_pending=0` and `jr=0`.
   - The held fetch is non-substituted, and repeating a non-substituted read is idempotent (§12.5).
   - If the fetch is `A9` (LDA #), the first shown phi2 arms the fast fetcher. That is the case top.sv's comment exists for (TOP:309-316). [checked; the second commit re-arms with the same `fast_expected_address`]
8. [corrected: added] **The first phi2 of the stall goes to whatever cycle follows W.** If W is the first of two writes, as with an RMW on `$1FF3` (`INC/DEC/ASL/… $1FF3`: read, write old, write new), the second write cannot be held (`wr_q`). It takes the one shown phase 2 and commits: a second CALLFN can re-arm `call_pending`, because the launch cleared it at W's E0+7, and that call queues behind the first. **The following opcode fetch's own pass is then hidden.** It commits only if the stall happens to drop at c = 0…5 of one of its address repeats (step 6). Otherwise an `A9` there never arms, and the operand comes back raw. This needs an RMW on the CALLFN hotspot, so no driver does it, but a clone must use the same rule: show the first phase 2 after the stall rises, whatever its cycle is.
9. [corrected: added] **Hidden phases and other state.** A hidden phase 2 has no `access`. It therefore causes no bank switch, no pointer update and no DSWRITE store, and it does not set `access_taken` (C26:255-261). The ARM may write pointer and increment words through the snoop during the call (§14.2). The first commit after the stall, normally F+1, reads the tables after `call_busy` has fallen, which happens only after the ARM's completion handshake (CTL:163-178). So it sees the ARM's final values, provided the ARM's last store is accepted before it raises completion. That ordering is on the ARM side and was not re-derived here.

### 15.1 Simulation (checker's bench)

[corrected: added] Bench `scratchpad/cdf_check_sim/tb_cdf_hold.sv`, built with Verilator 5.020 `--binary --timing`.
- **Upstream units, verbatim:** `6502/*` (sally) and `M6502C` extracted from TOP:1395-1469. Only a copy of `mos6502_ctl.sv` with four `PROCASSINIT` lint comments removed, which this Verilator rejects. Plus `mapper_cdf`, `arm_mapper_tables`, `cart_ram_tdp`, `arm_mapper_writeback` and `cache_ram`.
- **Transcribed:** TOP:288-296 and 306-329 (stall, `mapper_phi2`, RDY), C26:211-234, 241-265 and 965-978 (output mux, `address_change`, `access_taken`, `cartram_wr`).
- **Models:** a TIA WSYNC latch of TIA:2193-2203's shape; an ARM call modelled as `call_busy` for N clk; a ROM model with k = E0+3 that reads only on an `a_in` change.
- **Program:** a synthetic CDF1 program, no game data: `SETMODE` fast-fetch on, `STX $1FF3` (FF), `LDA #5`, `STA WSYNC`, `LDA #6`, `STA WSYNC`, `LDA zp`, `LDA #7`, `DSWRITE`.

Results:
- **Call stall, swept over all 12 drop phases** (call lengths 20-58 clk): `LDA #` opcode-address commits = 2 for c = 0…5 and 1 for c = 6…11. Operand commits = 1 in every run. Value stored = the stream byte in every run. Pointer advanced exactly once.
- **WSYNC hold** of 13-50 clk: the next opcode address committed 2-5 times (each repeat shown), the `LDA #` operand once, and the value was always correct.
- **CPU internals at F** (`STX $1FF3`, then F = `A9` at `$F00A`):
  - F's phase 2: `hold = 0`, `wr_q = 1`, `rdy_q = 0`, shown.
  - Next two phases: AB = `$F00A` again, `hold = 1`, hidden.
  - Then AB = `$F00B`, substituted, `d_out` = stream byte.
- **Pipeline and writeback timings** as given in §12.2 and §14.3: DSWRITE store at edge E0+6, table write at E0+7, writeback RAM write at clk_arm edge E0+7.8 (`arm_phase` 3), `idle` low in (E0+7, E0+9].

---

## 16. Audio interface (what the front end shares)

- **`cdf_digital_audio`** = `mode[7:4]==0` (MC:80). It changes right after a SETMODE commit (E0+6). AUD reads it when it captures a waveform pointer (AUD:107-108, 264-268).
- **`amplitude`** is an AUD register.
  - It changes in AUD's SAMPLE_CAPTURE, DIGITAL_ROUTE and ROM_WAIT states (AUD:317-327, 335-347, 355-361), at times set by its 20 kHz accumulator (AUD:76, 191-197) and by RAM grants.
  - The amplitude fetch returns the value at E0+6.
- **Port contention:** AUD's ISSUE states wait for `audio_ram_grant`, which is false whenever `cdf_ram_en` (C26:965).
  - So **every clk in which the CDF holds the port delays AUD's RAM read by one clk**. That includes clks where only a stale or transient ROM byte satisfies the predicate.
  - This is the only way the front end perturbs audio timing (Open question 4). [checked; DSWRITE's one-clk strobe in (E0+5, E0+6] counts too, because it raises `cdf_ram_en`]
  - [checked, and expanded for open question 4.
    - The 20 kHz tick (`tick_accum`), the counter accumulation and `refresh_pending` run on every clk with no grant dependency (AUD:191-199), so **tick times are never perturbed**.
    - What moves is when a refresh *finishes*. Without contention a CDF refresh is 3 voices × {POINTER_ISSUE, POINTER_CAPTURE, [SIZE_ISSUE, SIZE_CAPTURE when `audio_size_addr ≠ 0`], SAMPLE_ISSUE, SAMPLE_CAPTURE} (AUD:225-333). That is 12 or 18 clk from the IDLE state that takes the tick, and `amplitude` is written at the third SAMPLE_CAPTURE edge. Each clk in which `cdf_ram_en` is high while AUD sits in an ISSUE state adds one clk.
    - The digital path, `mode[7:4] == 0`, is POINTER → DIGITAL_ROUTE → one RAM sample read, or a DDR ROM read whose latency is outside the front end (AUD:264-272, 335-361).
    - The *values* AUD writes depend on RAM bytes and counters, not on this delay. They change only if the sampled bytes or counters change inside the delay window: an ARM write, a `call_done` counter merge (AUD:213-223), or a DSWRITE into the waveform area.
    - The 6507 observes timing in one place: an amplitude fast fetch latches `amplitude` at E0+6, which is the old or new value depending on whether the delayed write edge is ≤ E0+5.
    - So: compare **values** per tick, and the amplitude byte at every 6507 latch. A clk-exact AUD comparison is only meaningful if the clone reproduces `cdf_ram_en` clk by clk, which needs §12.3's per-edge `rom_do` sequence, including the stale-byte windows. The refresh lengths above are derived from the state machine, not simulated.]
- **Calls:** AUD seeds and merges its counters around calls (AUD:207-223) using `arm_call_request` and `arm_call_done`. Those are timed by §15.

---

## 17. Quirks

Each quirk is upstream behaviour the clone must reproduce.

[checked: every quirk below was re-read against its citations. Corrections are marked inline.]

- **Q1 — Live predicates.** Substitution is decided combinationally from `rom_do`, `a_in` and the state, with no `access`. Only the commit is edge-qualified (MC:102-112, 182).
- **Q2 — Tables idle at stream 32.** Whenever nothing substitutes, the tables are looked up at index 32, and `ram_addr` shows `display(ptr[32])` (MC:120-121, 137).
- **Q3 — Arming is byte-based and survives non-cart cycles.** Any non-substituted cart read of `A9` (or `A2`/`A0` on CDFJ+ with the flags) arms. `a_in[12]=0` accesses and writes neither arm nor disarm (MC:182, 194, 211-213, 225-250).
  - Example: `LDA zp` with operand `A9` at P+1, then the zero-page read, then an opcode fetch at P+2. That fetch **is substituted** if its byte is in range, so opcode bytes `00..amp` (or the offset range) are replaced with stream data.
  - The same holds for jump cancel and arm, which are skipped on A12=0 cycles.
  - [checked: Stella behaves the same way. It arms on any `A9` peek and disarms on every other non-fast-fetch cart peek, and A12=0 accesses never reach its `peek` (STL:321, 362-366).]
- **Q4 — Jump operand rules.** For CDF0/1 the map admits operand 1 = `01`, but the mapper rejects it at fetch time. The JMP then runs to `$0001` from ROM, and the read cancels (MC:99-101, 214-215; FJ:7-8). [corrected: the draft also said "or `$01xx`". Operand 2 is the high byte, and the map guarantees it is `00` in the file, so the target is exactly `$0001` unless operand 2 comes from another bank (§10.5).]
- **Q5 — `fast_mode` only at arming for JMP.** `jump_substitute` does not test `fast_mode` (MC:102-103, 216).
- **Q6 — Jump streams share the jump step.** Both bytes advance by exactly one display byte, independent of `inc[33/34]`. A fast fetch of 33 or 34 uses the increment instead (MC:200-202 vs 123-125).
- **Q7 — Amplitude.** It never touches RAM or the pointer table and always clears `fast_pending` (MC:142-143, 196-197).
- **Q8 — Stale and transient `rom_do`.** Right after E0 the predicates see the previous byte, and on SDRAM a byte of the previous 16-bit word (SDR:193). A stale byte that is in range at the expected address makes the predicate true early. That drives a wrong `table_index`, raises `cdf_ram_en`, blocks the audio grant, and puts transient values on `d_out`, until the real byte arrives. Example: a fast-fetch range moved by an offset that covers `A9`. The latch value is unaffected if k ≤ E0+4.
  - [checked, made exact by §12.3. At edge E0+1 the predicate sees the previous read's byte. For an `LDA #` operand that is the `A9` opcode itself, so any offset in [0x86, 0xA9] makes the predicate true in (E0, E0+1] with index `0xA9 − off`. At edge E0+2 it sees the previous 16-bit word's byte at the new lane. That is the correct byte when the opcode is at an even address, and the byte *before* the opcode when the opcode is at an odd one.]
- **Q9 — No bank switch on substituted reads, even at FF4..FFB** (MC:183-185).
- **Q10 — Bank switch does not refetch ROM.** On upstream's SDRAM path the post-commit `d_out` and the bus charge keep the old bank's byte until `a_in` changes (C26:157; SDR:95). [checked; this extends to every following cycle that repeats the same `a_in`, see Q24]
- **Q11 — CDFJ+ display address wraps mod 32 KiB.** Pointers with `p[30:16] ≥ 0x7800` address RAM `0x0000..0x07FF`, i.e. driver, tables and waveforms.
  - A DSWRITE there writes RAM through port A **without updating the table cache**. The ARM sees the new RAM; the 6507's streams keep the old table value.
  - Bit 31 is ignored for addressing but carried in arithmetic (MC:127, 152).
  - [checked. Stella differs (informative): it uses `idx = p[31:16]`, drops a DSWRITE and reads 0 when `idx ≥` the display size, and never wraps (STL:231-233, 385-389, 709-711). So the table-cache hole has no Stella counterpart. In Stella such a store cannot reach the driver or table area at all.]
- **Q12 — Non-plus display address uses p[31:20] with no wrap** (`0x800..0x17FF`).
- **Q13 — Only `inc[15:0]` is used** (C26:861). For non-plus the step is `inc<<12` (inc 8.8 → 12.20); for plus it is `inc<<8`. [checked; Stella also truncates: `const uInt16 increment` (STL:705)]
- **Q14 — The fetch offset is not gated by version.** If the CDFJ+ `SUB R2, R2, #imm` signature appears in the first 2 KiB of any CDF revision, the offset applies (D26:167-170; MC:89-98). LDX/LDY are gated by `jplus` (MC:83-84). [checked; Stella gates the offset to CDFJ+ (STL:749-776) and reads its value live from RAM, so this is an upstream-only behaviour.]
- **Q15 — Writeback is single-slot and drops overruns.** A pointer commit arriving while the previous write is unacknowledged updates the table but never reaches RAM (WB:61-65). This is unreachable: round trip ≈3 clk, commit spacing ≥12 clk. [corrected: the round trip is exactly 3 clk (§14.3), and the spacing is ≥ 4 clk even with RSYNC-shortened phases (§0.2). Still unreachable.]
- **Q16 — The DSWRITE store is a one-clk strobe tied to `access`** (MC:150-156). `access_taken` and `~address_change` in `cartram_wr` are redundant second guards for CDF (C26:255-261, 973-974).
- **Q17 — `call_pending` persists while not ready, and the 6507 is not stalled until the call actually launches** (MC:159, 179-180, 245; TOP:306-307).
- **Q18 — Map edge entries.** Map entries 32766 and 32767 are always 0. JMP lookahead at a bank's last two bytes reads the next bank's file bytes (FJ:34-38). [checked; consequence: on CDF0/1/J, a JMP opcode at bank 6's `$xFFE/$xFFF` (file 0x7FFE/0x7FFF) never arms, §10.7]
- **Q19 — The CDFJ+ entry and stack are captured for every file**, from bank 0's `$1FF4..$1FFB` window (D26:196-201).
- **Q20 — Override inheritance.** With an OSD or header mapper override:
  - `mapper_revision`, `cdf_ldx/ldy`, the offset and the entry/stack are whatever detection produced for that file;
  - `mapper_ram_size` stays 8 K unless *detection* chose CDFJ+ (TOP:778-783, 1138; D26:205-259).
- **Q21 — `cdf1_count` is dead.** CDF1 is the default revision (D26:175-178, 220-221).
- **Q22 — `cdf_ram_wdata` is unconnected.** cart2600 writes `d_in` directly; the two are equal (MC:138; C26:977).
- **Q23 — Pause.** `cartram_data` reads `FF` and port A stops registering (TOP:921, 936). The clocks stop too, so no commit sees it. [checked: MARIA, which generates `tia_clk_x2` for the TIA and so the CPU phases, is clock-enabled by `~pause || effective_reset` (TOP:445; MAR:154). The ARM host is gated too (TOP:813-816). Two things keep running: AUD, which has no pause input, so a refresh during pause samples `FF` bytes (`ram_byte_data` = `cartram_data`, C26:793); and the mapper's combinational outputs. The next tick after the pause recomputes `amplitude`.]
- **Q24 — [corrected: added] Repeated address after a hotspot.** A cycle that repeats the previous `a_in` starts no ROM read, so `rom_do` is the old bank's byte, while `rom_a` and the map query already use the new bank (§6). Reached by RDY address repeats (§12.5, §15), RMW dummy cycles, and `STA abs,X` dummy reads.
- **Q25 — [corrected: added] Stall phase-2 accounting** (§15, settled by simulation). The first phase 2 after the stall rises is shown, whatever cycle it belongs to, normally the next opcode fetch F, whose T-state completes. Repeats of F's address are hidden while the stall is high. If the stall's first low clk is (E0+c, E0+c+1] with c ∈ 0…5 of a repeat, that repeat is shown too: a **second commit of F's address**. With c ∈ 6…11 there is none.
- **Q26 — [corrected: added] `pu_val` uses the previous edge's table word** (§11.1). If `table_index` changes in (E0+5, E0+6], which needs k = E0+6, the update writes one stream's stepped pointer into another stream's slot. This is unreachable at the nominal L1 = 6 on upstream's ROM path, but reachable with an RSYNC-shortened phase 1.
- **Q27 — [corrected: added] ROM reads are not A12- or R/W-gated** (C26:157; WR:799). The stale byte a cart cycle sees at E0+1 (Q8) is the byte for the previous cycle's `a_in`, mapped through `rom_a`, even when that cycle was a zero-page, TIA, RIOT or write cycle.

---

## 18. Guard candidates

This section follows the run's instruction to implement a guard when it is cheap and keeps the clone in sync with upstream.

| # | Hazard | Reachable? | Guard | Cost | Keeps sync? |
|---|---|---|---|---|---|
| G1 | Writeback overrun drop (Q15) | No: ≥12 clk between commits vs ≈3 clk round trip [corrected: ≥4 clk even after RSYNC, vs exactly 3] | Queue one more write or stall, or at least assert | Small | **Yes.** Never fires in reachable cases; implement. |
| G2 | ROM byte late, k > E0+4 (§12.2) | Not with a clk_sys ROM [corrected: on upstream, yes, after an RSYNC shortens phase 1 to 4 or 2 clk (§0.2). The requirement is k ≤ E0+L1−2.] | Assertion that `rom_do` is valid by E0+L1−2 | Trivial | **Yes**, as an assertion or counter only. It must not change the data path, because upstream latches whatever the pipeline shows. |
| G3 | Table port-A read racing a port-B write | Upstream excludes the shared edge (§14.2) | If the clone's clocks differ, sit out the coincident edge, or re-read before E0+5 | Small | **Yes**, as long as the reads at E0+5 and E0+6 see the final value. |
| G4 | Stale or transient predicate (Q8) | Yes, on upstream's SDRAM path | Gate predicates until `rom_do` is valid | Small | **No.** It changes `cdf_ram_en` windows and so AUD grant timing (§16). Only safe if audio is compared at tick granularity with tolerance. Do not change unless the comparison allows it. |
| G5 | CDFJ+ wrap-store not reflected in tables (Q11) | Only by pathological software | Snoop console port-A writes into the tables | Small | **No.** It diverges from upstream when it fires. At most flag or count it. |
| G6 | Held substituted read gets the raw byte (§12.5) | Practically no | Re-serve the substitute on repeats | Medium | **No.** It changes upstream behaviour if ever hit; assert or flag only. |
| G7 | A12=0 cycles not disarming (Q3), bank-end lookahead (§10.7), hotspot+JMP (§10.7) | Yes | — | — | **No.** These define upstream behaviour; do not guard. |
| G8 | [corrected: added] Invariant `!(fast_pending && jump_remaining != 0)` (§10.7) | Never true in upstream | Assertion | Trivial | **Yes.** Implement. It catches a clone bug without changing behaviour. |
| G9 | [corrected: added] `pu_idx` differs from the index registered at the previous edge (Q26) | Only with k = E0+L1 (RSYNC) | Assertion or counter | Trivial | **Yes**, as a flag only. Copying upstream's value is what keeps sync. |
| G10 | [corrected: added] Second commit of the opcode address after CALLFN (Q25), N commits of the opcode address after WSYNC (§12.5) | Yes: about half of all calls (c = 0…5, set by call length mod 12) and every WSYNC hold | None. Reproduce `stall_cycle_taken`/`mapper_phi2` exactly (TOP:309-327) and feed the clone the same phase stream | — | **No guard.** The repeats are idempotent for CDF, but a commit-by-commit comparison counts them. |
| G11 | [corrected: added] Repeated-address cycle after a hotspot mixes the old bank's ROM byte with the new bank's map bit (Q24) | Rare (RDY repeat or dummy cycle on a hotspot) | None. Model `rom_do` as "byte of the last address change" | — | **No.** "Fixing" it, i.e. refetching on a bank change, diverges from upstream. |

---

## 19. Open questions

[corrected: the checker answered these from the RTL, the upstream wrapper (WR), the PLL IP and simulation. Each original question is kept, followed by its answer.]

1. **ROM arrival time on upstream MiSTer.** MiSTer's wrapper, its SDRAM clock ratio and `rom_do` latency are not in this repo. §12.3 uses this repo's `sdram.sv` at 4 × clk_sys (k = E0+2 or E0+3). The latch value is invariant for k ≤ E0+4, but the transient windows and audio grant timing are not (Q8, §16).
   - **Answer (settled):** upstream's SDRAM controller is this same `sdram.sv`, clocked by `clk_vid` = 4 × clk_sys at 0 ps phase (WR:787-792; PLL:39-44). `ch0_rd` is `cart_read & ~cart_download & ~reset` and `ch0_addr` is `{6'b0, rom_a}` (WR:796-799), and `rom_do` is `ch0_dout` with no register in between (WR:568).
   - So k = E0+2 for a same-word read and E0+3 otherwise. The per-edge byte sequence, stale bytes included, is in §12.3.
   - What remains platform-dependent is board-level SDRAM timing (DQ capture at the READY state), which the RTL treats as ideal.
2. **Console held during RAM re-init after a console reset on upstream MiSTer?** The Pocket wrapper holds reset while `mapper_init_busy` (POK:166-171). RI re-runs on every reset rising edge (RI:222-226), and top.sv does not stall the CPU for init (TOP:306-307).
   - **Answer (settled): yes.** WR:75-78 ORs `mapper_init_busy` into the registered console reset. The front end, the 6507 and the writeback stay in reset for the whole init, after a download and after every console reset (§14.1).
3. **Does the held fetch after CALLFN commit twice?** By `mapper_phi2 = pclk0 && (!stall || !taken)` (TOP:320-327) and RDY being read at E0 (C65:875-880), the phi2 that completes the held fetch has `arm_call_stall = 0` and is shown. That gives a second commit, against the "hide" in the diagram at TOP:317-319. It is idempotent for CDF (§15), but a commit-by-commit comparison needs the exact count. Settle it by simulation.
   - **Answer (settled by simulation, §15.1): sometimes.**
     - The opcode fetch F after the write completes its T-state on its first pass (`wr_q`), which is shown. Its address then repeats while hidden.
     - F's address commits a **second** time exactly when the stall's first low clk falls in (E0, E0+6] of a repeat cycle (c = 0…5). Otherwise F commits once.
     - The operand F+1 always commits once and is substituted correctly.
     - The diagram at TOP:317-319 is right that the repeats are hidden. It is incomplete in that the last repeat is shown when the stall drops during that repeat's phase 1.
4. **Audio tick comparisons at clk granularity.** These depend on the exact `cdf_ram_en` windows (§13.3, Q8), and those depend on platform `rom_do` timing and transients. Decide whether the per-tick comparison is value-at-tick (insensitive) or clk-exact.
   - **Answer (partly; the choice is the bench's):**
     - Tick *times* never depend on the front end.
     - Refresh *completion* moves one clk per contended ISSUE clk. Values change only if the sampled data changes inside that window.
     - The 6507 observes timing only through an amplitude fast fetch landing between the unperturbed and the perturbed update edge (§16).
     - Recommendation: compare by value per tick, and compare the amplitude byte at every 6507 latch. Compare AUD clk-exact only if the clone reproduces §12.3's per-edge `rom_do` sequence, and with it `cdf_ram_en` clk for clk.
5. **clk_arm phase.** The writeback landing (≈E0+7.8) and idle (E0+9) figures assume `clk_arm = 5 × clk_sys` with `arm_phase` 4 ending on the shared edge (CRT:29-54). The sync start-up phase and any clk_sys/clk_arm jitter could move these by one clk_arm. They are invisible to the 6507 unless a call is requested within 3 clk of a pointer commit, which cannot happen because CALLFN is a write cycle with no pointer update.
   - **Answer (settled): exact.** `clk_arm` is PLL `outclk_3`, 5 × clk_sys at 0 ps (PLL:48-50; WR:49, 340-342). `arm_phase` is re-forced to 2 every clk_sys period (CRT:47-53), so there is no start-up ambiguity after the second clk_sys edge. Simulation reproduced RAM written at E0+7.8 and `idle` from E0+9 (§15.1).
6. **RSYNC-shortened cycles.** The E0+n figures assume the nominal 12-clk cycle. With RSYNC (TIA:506, 565-567) the commit still happens at the phase-2 edge, but the pipeline budget in §12.2 shrinks.
   - **Answer:**
     - Phase lengths are even (2, 4 or 6 clk). Only an RSYNC write moves the divider; the end-of-line re-force is otherwise a no-op (§0.2).
     - With L1 = commit − E0, the requirements are: RAM substitution k ≤ E0+L1−2; pointer update k ≤ E0+L1−1, else Q26; amplitude and arming k ≤ E0+L1.
     - On upstream's path, L1 = 4 breaks a different-word substituted read, and L1 = 2 breaks a different-word plain ROM read too.
     - The exact divider sequence after an RSYNC was not simulated.
7. **Stella parity is not checked.** This spec follows upstream RTL. Items that may differ from Stella have not been verified against it:
   - Q3: arming is byte-based on any cart read;
   - Q13: increment bits [31:16] are dropped;
   - Q14: the offset is not gated by version;
   - the non-plus FF4 → bank 6 mapping.
   - **Answer (checked against STL; informative only, the clone follows upstream):**
     - **Same as Stella:**
       - Q3 arming (STL:321, 362-366);
       - Q13 16-bit increment (STL:705);
       - FF4 → bank 6 and FFB → 6 on non-plus, FF4/FFB → 0 on plus (STL:324-358, 418-448);
       - no bank switch on a substituted read (STL:240, 314, 318 return before the switch);
       - `fast_mode` not re-tested for jump operands (STL:223-224).
     - **Different from Stella:**
       - Q14: Stella applies the offset only to CDFJ+ and reads it live from RAM (STL:749-776).
       - Q11: Stella never wraps a CDFJ+ display index, and drops or zero-reads `idx ≥` the display size (STL:231-233, 385-389, 709-711). Upstream's wrap-into-tables store, and its stale table cache, have no Stella counterpart.
       - A fast-jump-arming `JMP` opcode at FF4..FFB switches banks upstream but not in Stella (STL:246-254).
       - Stella checks the operand bytes only at arming, from the image, and never re-validates them at fetch (STL:222-243). Upstream checks both.
       - Stella's cancel clears only `myJMPoperandAddress`, not `myFastJumpActive` (STL:257). After a cancelled jump, a later peek of `$x000` would be substituted in Stella. Upstream clears `jr`.
       - A JMP-arming peek and a jump-operand peek in Stella leave a pending `LDA #` arming intact (they return before STL:321). Upstream clears `fast_pending` on both.
