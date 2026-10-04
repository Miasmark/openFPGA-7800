# The ARM schemes' 6507-side front ends: why they cost ~1,750 ALMs, and a lean replacement for DARIA

A design study for DARIA's step 0 (`docs/DARIA_CORE.md`, which takes its requirements from it). It reads upstream's MIT RTL; it uses no game data. `daria_fe3.sv` here is a **sizing sketch only**: it has never been simulated and is not for the core. `run_study.sh` repeats every compile below.

Scope: `mapper_dpcplus`, `mapper_cdf`, `mapper_bus`, `arm_mapper_audio`, `arm_mapper_ram_init`, `arm_mapper_tables`, `cdf_fastjump_table`. Also covered: `arm_mapper_writeback` and the audio half of `arm_mapper_controller`, which DARIA would bring back along with the ARM.

Sources:
- Upstream RTL in `src/fpga/mister/rtl/`.
- The 2.1.1 release build's fit report (seed 2).
- Quartus 21.1 compiles of each block alone (`run_study.sh`, in `sim/work/bupchip/daria/frontend_study/`).

Tags:
- **[fit]**: the 2.1.1 build.
- **[probe]**: one upstream module compiled alone. Every port except the clocks is a virtual pin, with the core's synthesis and fitter settings (`MUX_RESTRUCTURE OFF`, physical synthesis on). The clock period is 69.8 ns. ALMs = [A] used − [B] recoverable, because the [C] term is mostly virtual I/O.
- **[sketch]**: the same kind of compile of the lean sizing sketch. The sketch is not functionally verified.
- **[E]**: estimate.

## Summary

- **The 1,752 ALMs in 2.1.1 understate what DARIA brings back.** 2.1.1 is built with `NO_ARM_MAPPER` + `EXTERNAL_CARTRAM`. In that build, `call_ready`, the ARM's cart-RAM port, `cartram_word_data` and the call returns are all tied to 0. Synthesis therefore deletes:
  - DPC+'s copy/fill service and its parameters;
  - every audio counter;
  - the ARM-write snoop on the tables;
  - all call paths.

  Compiled with every input live, the seven blocks come to **2,192 ALMs** [probe]. `arm_mapper_writeback` adds **34**. `arm_mapper_controller` adds **716**; about 1,150 of its 1,328 FF only carry six 32-bit audio values across clocks.
- **In the other direction, the build inflates `mapper_dpcplus`.** It is 1,135 ALMs [fit] against 763 for the same pruned logic compiled alone [probe], so +47%.
  - The fitter duplicated logic: registers went from 515 to 733 and LUTs from 1,216 to 1,539.
  - The reason is that its register decode lies on the core's worst `clk_sdram` path (`SRAM_TIMING.md`).
- **What actually costs area:**
  1. DPC+ keeps 8 fetchers × 56 bits of state in flip-flops, with eight copies of every adder, comparator and load mux. That is about 690 of its 832 ALMs.
  2. State that already lives in cart RAM is copied again: CDF/BUS pointer, increment and map shadows, an ARM-write snoop and a cross-clock writeback.
  3. About a dozen 32-bit adders and carry registers exist, but at most two are used in any one 6507 cycle.
  4. Live audio uses 12 × 32-bit registers, three parallel adders and a 32-bit barrel shifter: **657 ALMs** [probe].
  5. A 32-Kbit lookahead bitmap exists only because the ROM arrives as a byte stream from SDRAM.
- **Lean design:** one front end for all three schemes, sequenced in time slots on `clk_sys`.
  - DPC+ fetcher state lives in a small state RAM.
  - CDF/BUS pointers, increments and maps are read and written directly in cart RAM port B, which is where the Harmony driver keeps them.
  - The front end and the audio engine share one 32-bit word register and one adder.
  - The fast-jump lookahead is read from the ROM port.
  - Every stage is registered. Read data is ready 2 `clk_sys` before the 6507 latches it.
  - **The sizing sketch compiles to 1,004–1,018 ALMs and 2 M10K** [sketch]. Adding what the sketch leaves out and polishing gives **850–1,100** [E].
- **Net effect against reusing upstream:**
  - about −1,200 to −1,450 ALMs on the front ends (including about 80 of `cart2600` glue);
  - about −550 on the call controller [E];
  - −6 M10K;
  - the ARM schemes leave the `clk_sdram` cone, because no SDRAM or SRAM is left in their 6507 path.

  Against the 2.1.1 figure the saving is −650 to −900. The plan's "reuse unmodified, about 1,750 ALMs" understates reuse: the live figure is about 2,200, plus the controller.
- **Recommendation:** write the lean front end as this project's MIT code. Verify it as a cycle-by-cycle shadow of upstream's front ends inside `sim/bupchip/daria/tb_daria.sv`, the same way `sim/run_pokey_shadow.sh` verified POKEY.

## 1. Where the ALMs go

### 1.1 Per block

| Block | 2.1.1 ALMs [fit] | LUT / FF / M10K [fit] | Live ALMs [probe] | LUT / FF [probe] | Removed or tied off in 2.1.1 |
|---|---|---|---|---|---|
| `mapper_dpcplus` | 1,134.8 | 1,539 / 733 / 0 | 831.5 | 1,292 / 589 | service, params and call (no ARM). Fitter duplication for `clk_sdram`: +218 FF, +323 LUT |
| `mapper_cdf` | 216.6 | 340 / 84 / 0 | 278.0 | 469 / 82 | call path, `pointer_update_value[7:0]` |
| `mapper_bus` | 195.5 | 254 / 184 / 0 | 217.5 | 347 / 175 | call path, `pointer_update_value[7:0]` |
| `arm_mapper_audio` | 90.2 | 163 / 69 / 0 | **657.0** | 1,049 / 518 | word data and call returns = 0, so frequencies are constant and the counters never move |
| `arm_mapper_ram_init` | 39.9 | 73 / 34 / 0 | 76.5 | 124 / 41 | the table preload reads 0 |
| `arm_mapper_tables` | 39.4 | 68 / 8 / 4 | 92.5 | 156 / 10 / 4 | ARM-write snoop (the port is idle) |
| `cdf_fastjump_table` | 35.4 | 68 / 20 / 4 | 39.0 | 70 / 18 / 4 | none |
| **Sum** | **1,751.8** | 2,505 / 1,132 / 8 | **2,192** | 3,507 / 1,433 / 8 | |
| `arm_mapper_writeback` (not in 2.1.1) | none | none | 33.5 | 65 / 156 | |
| `arm_mapper_controller` (ARM side, not in 2.1.1) | none | none | 715.5 | 1,357 / 1,328 | about 1,150 of its FFs are audio mailboxes |

`cart2600`'s own logic (304 ALMs [fit]) also holds glue that only these blocks need [E: 60–100 ALMs]:
- the table index, write and map muxes;
- DMA arbitration between init and the DPC+ service;
- the three-way call entry/stack muxes.

### 1.2 Inside `mapper_dpcplus`

State bits (RTL):

| Structure | Bits |
|---|---|
| 8 × (counter 12 + top 8 + bottom 8 + fraction 20 + increment 8) | **448** |
| random 32, params 8×8 + pointer 4 | 100 |
| waveforms 3×7, notes 11 | 32 |
| latched service request 52, call 1, bank 3, fast fetch 2 | 58 |
| **Total** | **638**. 2.1.1 keeps 515 after pruning and has 733 after fitter duplication |

The cost of each feature comes from deleting it and recompiling: one variant of the live module per row [probe].

| Feature | ALMs | LUT | FF | What it is |
|---|---|---|---|---|
| Fractional fetchers | **290** | 418 | 224 | <ul><li>8 × (20-bit fraction + 8-bit increment) in flip-flops</li><li>8 × 20-bit adders</li><li>per-fetcher FRACLOW/FRACHI/FRACINC load muxes</li><li>8:1 × 12 mux of `fraction[19:8]` into the RAM address</li></ul> |
| Integer counters, read/write paths, decode (what remains with everything else deleted) | **287** | 427 | 134 | <ul><li>8 × 12-bit counters, each with its own +1, −1 and byte/nibble loads</li><li>two 8:1 × 12 counter muxes (read index and write index) and the PUSH −1</li><li>the `$C00 +` address adder</li><li>the register read mux</li><li>`(a − $28) >> 3` computed as a 12-bit subtract</li><li>bank, waveforms, notes</li></ul> |
| Window flags | **93** | 155 | 128 | <ul><li>top and bottom flip-flops</li><li>eight parallel `(top − counter) > (top − bottom)` comparators</li></ul>They are kept per fetcher on purpose, so that the 8:1 mux comes after the compare (`mapper_dpcplus.sv:103-106`). This keeps about 3.5 ns off the ROM-to-bus path. |
| Random | **78** | 56 | 32 | 32-bit LFSR with next/prior and four byte loads (13:1 / 14:1 muxes) |
| Service + params | **69** | 130 | 71 | <ul><li>params 8 × 8 flip-flops, of which only 0–3 are ever read</li><li>latched DMA request (51 FF)</li><li>count clamps (two compares and subtracts)</li><li>`counter[params[2]]` mux</li></ul> |
| Interaction | 15 | | | |
| **Total live** | **831.5** | 1,292 | 589 | In 2.1.1: 1,135, against 762.5 for the same pruning compiled alone |

### 1.3 The other blocks

- **`mapper_cdf`** has only 82 FF. Its LUTs are 32-bit arithmetic and muxing:
  - separate expressions for pointer + inc<<12, pointer + inc<<8 (CDFJ+), pointer + 1<<20 and pointer + 1<<16 (jump and DSWRITE), all merged into a 32-bit `pointer_update_value` register;
  - the DSPTR shift-in;
  - operand range compares;
  - two 13-bit expected-address registers with their compares and incrementers.
- **`mapper_bus`** follows the same pattern. It adds `last_a` (13 FF) for its stuff state machine and three 32-bit carry registers: `pointer_update_value`, `map_update_value` and `stuff_map`.
- **`arm_mapper_audio`**, live, holds four 32-bit values per voice: counter, frequency, refresh copy and call seed (384 FF in all). It also has:
  - three parallel 32-bit adders;
  - a 32-bit variable shifter (`refresh_counter >> waveform_shift`);
  - 32-bit range compares and subtracts;
  - the digital-sample address adder.

  2.1.1 shows only 90 ALMs because every 32-bit input is tied to 0.
- **`arm_mapper_tables`, `arm_mapper_writeback` and `arm_mapper_ram_init`** exist because the combinational read path cannot read cart RAM four times within one 6507 cycle. So:
  - the pointer and increment words are copied into two dual-clock M10Ks;
  - ARM writes are snooped into those copies by three range decoders on `clk_arm`;
  - 6507-side updates are written back across clocks;
  - the copies are reloaded after every reset.
- **`cdf_fastjump_table`** is a 4-M10K bitmap that marks "`$4C`, then 0 or 1, then 0" at every image address. It is built during load because a byte-wide ROM cannot look two bytes ahead.
- **`arm_mapper_controller`** moves six 32-bit audio values (counters and frequencies, which the driver keeps in FIQ r8–r13) through payload, sync1, sync2, return, active and result registers. That is about 1,150 FF.

### 1.4 Root causes

1. **Per-fetcher state in flip-flops, with per-fetcher arithmetic.** This is about 690 of DPC+'s 832 ALMs.
2. **One combinational pass from the ROM byte to the 6507 bus.** The path runs ROM byte → decode → RAM address → data inside one 6507 cycle, and STA times it at `clk_sdram`. It forces the parallel window compares, and it drives the fitter's +47% duplication.
3. **Copies of cart-RAM state** (the tables) plus the snoop and the cross-clock writeback.
4. **Width without sharing.** About a dozen 32-bit adders and subtractors and about a dozen 32-bit carry registers across CDF, BUS and audio, of which at most two are active in any one 6507 cycle.
5. **Audio crossing clocks as 6 × 32-bit values in five register stages.**

## 2. What the 6507 can observe

### 2.1 Bus timing (`top.sv`, `cart2600.sv`, `mos6502_dp.sv`, `TIA.sv`)

One 6507 cycle is 12 `clk_sys`. TIA's divider gives each phase 6 clocks (`tia_clk_x2` = `clk_sys`/2, `pclk_div` counts 0..5). Call the phase-1 edge E0.

| Edge | What happens |
|---|---|
| **E0**, `pclk1` (`phi1_en`) | `ABL`/`ABH` load. `a_in` is valid for the whole cycle. |
| **E0+6**, `pclk0` (`phi2_en`) | The CPU latches read data (`dl <= data_in`, `mos6502_dp.sv:299`). On the same edge:<ul><li>the mappers' `access` (`mapper_phi2 && arm_driver_run`) is high, so state is committed once and `d_in` is sampled;</li><li>the RIOT latches writes.</li></ul>The TIA writes `wreg` on every clock of phase 2, so the value at E0+12 is the one that stays. |
| **E0+12** | Next address. |

A front end therefore has **6 `clk_sys` from address to data**, with setup before E0+6. It must commit state only at E0+6 and only when `access` is high:
- During an ARM call or DMA, `top.sv` holds RDY low and shows the mapper only the first phi2 of the stalled read (`stall_cycle_taken`).
- The stalled read is still presented every cycle until it completes.

How upstream meets the deadline on the Pocket:
1. `rom_read` rises at E0+1 (`~address_change`).
2. The SDRAM returns `rom_do` after about 6 `clk_sdram`, at about E0+3.
3. The DPC+/CDF/BUS decode turns it combinationally into `cartram_addr`.
4. `sram_ctrl` serves the 2600 request again whenever the address changes, taking 5–6 `clk_sdram`, so `d_out` arrives at about E0+4.5–5.

That leaves about 1 `clk_sys` of slack, all of it through combinational logic that STA times as one 17.46 ns `clk_sdram` path. This is the 2.1.1 worst path.

After the commit, upstream's `d_out` stays combinational and changes for the rest of the cycle: it shows the next fetcher byte, or the ROM operand once `fast_pending` clears. The CPU never sees this, but `top.sv`'s `open_bus` register ends the cycle holding that value.

### 2.2 Common to all three schemes

- The cartridge drives D7–D0 on every `$1xxx` read (`oe = $FF`) and nothing outside that window. BUS stuffing changes write data, not reads.
- `arm_driver_run` (the Harmony boot stub) gates every commit.
- **Call protocol:**
  1. Writing `$FE` or `$FF` to CALLFN sets `call_pending`, which raises `call_request` until `call_ready`.
  2. The 6507 is held on RDY from the next cycle (the opcode fetch) until the return.
  3. Entry, SP and Thumb are constants per scheme (CDFJ+ takes them from the image at `$17F8` and `$17F4`).
- **RAM image:** built at load end and again on every console reset, with the console held in reset meanwhile.
  - DPC+: zero `$0000–$0BFF`; copy image `$6C00–$7FFF` to RAM `$0C00–$1FFF` (display data and frequencies).
  - CDF and BUS: copy image `$0000–$07FF` (the driver); zero the rest.
- **The "LDA #" trick (fast fetch):** the mapper cannot see SYNC, so it watches the bytes it serves.
  - After it serves an `LDA #` opcode (`$A9`), the operand byte that the ROM would return is treated as a register number.
  - The value of that register is returned instead of the ROM byte.
  - Fast jump does the same for the two operands of `JMP abs` (`$4C`). BUS stuffing does the same for `STY zp` (`$84`).

### 2.3 DPC+

Register map, by low byte of the address in the `$1000` window (x = fetcher 0–7):
- **Reads** (`$1000–$1027`):

  | Address | Register | Returns |
  |---|---|---|
  | `$00` | RANDOM0NEXT | steps the LFSR (`ror11 ^ (b10 ? $10ADAB1E : 0)`), then returns the low byte |
  | `$01` | RANDOM0PRIOR | steps the LFSR back, then returns the low byte |
  | `$02–$04` | RANDOM1–3 | bytes 1–3 of the LFSR |
  | `$05` | AMPLITUDE | |
  | `$06`, `$07`, `$24–$27` | none | 0 |
  | `$08+x` | DFxDATA | RAM[`$C00` + counter], then counter += 1 (12-bit) |
  | `$10+x` | DFxDATAW | the same byte ANDed with the window flag |
  | `$18+x` | DFxFRACDATA | RAM[`$C00` + fraction[19:8]], then fraction += increment (20-bit) |
  | `$20–$23` | DFxFLAG | `$FF` when (top − counter[7:0]) > (top − bottom) |

- **Writes** (`$1028–$107F`):

  | Address | Register | Effect |
  |---|---|---|
  | `$28+x` | FRACLOW | fraction[15:8] = d. Bits [7:0] are cleared only on revision 1 (driver CRC `$A08CFB13`); otherwise kept. |
  | `$30+x` | FRACHI | fraction[19:16] = d[3:0] |
  | `$38+x` | FRACINC | increment = d, fraction[7:0] = 0 |
  | `$40+x`, `$48+x` | TOP, BOTTOM | |
  | `$50+x` | LOW | counter[7:0] = d |
  | `$58` | FASTFETCH | on when d = 0 |
  | `$59` | PARAMETER | params[ptr++] = d, while ptr < 8 |
  | `$5A` | CALLFUNCTION | 0: reset ptr. 1: copy. 2: fill. `$FE`/`$FF`: call (entry `$0C08`, Thumb, SP `$40001FFC`). |
  | `$5B–$5C` | none | |
  | `$5D–$5F` | WAVEFORM0–2 | d[6:0] |
  | `$60+x` | PUSH | counter −= 1, then RAM[`$C00` + counter] = d |
  | `$68+x` | HI | counter[11:8] = d[3:0] |
  | `$70` | RRESET | LFSR = `$2B435044` |
  | `$71–$74` | random byte writes | |
  | `$75–$77` | NOTE0–2 | frequency = RAM word at `$1C00` + 4·d |
  | `$78+x` | WRITE | RAM[`$C00` + counter] = d, then counter += 1 |

- **Banks:** six 4K banks at image `$0C00` + 4K·n. Reset bank is 5. Any access (read or write) to `$1FF6–$1FFB` selects bank 0–5, except on a fast-fetch substitution.
- **Fast fetch:** while it is on:
  - any non-register `$1xxx` read whose byte is `$A9` sets `pending`;
  - the next `$1xxx` read whose ROM byte is below `$28` becomes a read of register = that byte (6-bit index), and `pending` clears;
  - any other `$1xxx` read re-evaluates `pending`;
  - writes, and accesses outside `$1xxx`, leave `pending` unchanged.
- **Copy/fill service:** from the 4 parameters p0–p3, with f = p2's fetcher:

  | | Copy | Fill |
  |---|---|---|
  | Bytes | min(p3, `$1000` − counter[f], `$7400` − {p1,p0}) | min(p3, `$1000` − counter[f]) |
  | From | image `$0C00` + {p1,p0} | the value p0 |
  | To | RAM `$0C00` + counter[f] | RAM `$0C00` + counter[f] |

  The counter is not advanced, and the 6507 is held until the service finishes (`arm_dma_busy`).

### 2.4 CDF, CDFJ and CDFJ+

- **Banks:** seven 4K banks at image `$1000` (CDFJ+: `$0800`) + 4K·n. Reset bank is 6 (CDFJ+: 0).
  - `$1FF4` and `$1FFB` select bank 6 (CDFJ+: 0).
  - `$1FF5–$1FFA` select banks 0–5 (CDFJ+: 1–6).
  - Substituted reads do not switch banks.
- **Registers** (all writes):

  | Address | Name | Effect |
  |---|---|---|
  | `$1FF0` | DSWRITE | RAM[`$800` + P32[31:20]] = d, then P32 += 1<<20. CDFJ+ uses P32[30:16] and adds 1<<16. |
  | `$1FF1` | DSPTR | P32 = (P32<<8 & `$F0000000`) \| d<<20. CDFJ+: & `$FF000000` \| d<<16. |
  | `$1FF2` | SETMODE | fast fetch when mode[3:0] = 0; digital audio when mode[7:4] = 0; reset value `$FF` |
  | `$1FF3` | CALLFN | `$FE`/`$FF` call. Entry `$0808` and SP `$40001FFC`; CDFJ+ uses its header. |

- **Streams:** each stream has a 32-bit pointer P and increment I in cart RAM. Byte addresses:

  | Version | Pointers | Increments | Streams |
  |---|---|---|---|
  | CDF0 | `$06E0` | `$0768` | 34 |
  | CDF1 | `$00A0` | `$0128` | 34 |
  | CDFJ, CDFJ+ | `$0098` | `$0124` | 35 |

  Stream 32 is the write stream. Streams 33 and 34 are the jump streams. The amplitude "stream" is 34 (CDF) or 35 (CDFJ, CDFJ+).
- **Fast fetch:** in fast mode:
  - a non-substituted `$1xxx` read of `$A9` arms the next address (CDFJ+ also arms on `$A2`/`$A0` when the driver enables LDX/LDY);
  - the read at exactly that address, with operand v in [off, off + amp], is substituted (off is the driver's fetch offset, CDFJ+ only, else 0):
    - v − off = amp returns AMPLITUDE, and no pointer moves;
    - otherwise it returns RAM[`$800` + P[31:20]] (CDFJ+: P[30:16]), then P += I[15:0]<<12 (CDFJ+: <<8).
- **Fast jump:** in fast mode, a non-substituted `$1xxx` read of `$4C` at image address X arms when the lookahead holds: image[X+1] ∈ {0,1} and image[X+2] = 0. Then:
  - the read at X+1 is substituted if its operand is valid (CDF: 0; CDFJ: 0 or 1, which picks stream 33 + operand);
  - the read at X+2 is substituted if its operand is 0, from the same stream;
  - each substituted read returns the stream's byte and advances it by one byte (1<<20, CDFJ+ 1<<16);
  - a read at any other address cancels.

  Jump substitution takes priority over fast fetch.

### 2.5 BUS

- BUS0 is unsupported: it shows the bad-game screen.
- **Banks:** seven 4K banks at image `$1000`. Reset bank is 6. `$1FF5–$1FFB` select banks 0–6, except on jump-substituted reads.
- **BUS1/2 registers:**

  | Address | Effect |
  |---|---|
  | `$1000–$100F` (read) | stream n: RAM[`$800` + Pn[31:20]], then Pn += In[15:0]<<12 |
  | `$1010–$1013` (write) | stream n write: store d at Pn's address, then Pn += 1<<20 |
  | `$1014–$1017` (write) | pointer shift-in |
  | `$1018` (read) | AMPLITUDE |
  | `$1019` (write) | STUFFMODE: only on/off is kept |
  | `$101A` (write) | CALLFN |

- **BUS3 registers:**

  | Address | Effect |
  |---|---|
  | `$1FEE` | AMPLITUDE |
  | `$1FEF` | read stream 16 |
  | `$1FF0` | write stream 16 |
  | `$1FF1` | pointer 16 |
  | `$1FF2` | mode (the whole byte) |
  | `$1FF3` | CALLFN |

  BUS3 also has fast jump via stream 17; both operands must be 0.
- **Tables** in cart RAM:

  | | Pointers | Increments | Map |
  |---|---|---|---|
  | BUS1/2 | `$06E0` | `$0720` | `$0760` |
  | BUS3 | `$06D8` | `$0720` | `$0760` |
  | BUS0 | `$0AE0` | `$0B20` | `$0B64` |

- **Stuffing**, in stuff mode:
  1. A `$1xxx` read of `$84` (`STY zp`) arms it.
  2. The next `$1xxx` read at address+1 captures the operand as tt.
  3. The next write to exactly `$00tt` (tt ≤ `$24`; mirrors do not count) is stuffed. The data lines become `write_DB & byte`, as both TIA and RIOT see them. The byte is the next byte of stream map[tt & `$1F`][3:0]. That stream then advances by I<<12, and the map word rotates right by 4 bits.
  4. Any other write below `$1000` disarms.
- Call entry is `$0808`, SP `$40001FFC`.

### 2.6 Audio (AMPLITUDE)

- Ticks run at 20 kHz from a Bresenham divider on `clk_sys`: 20,000 / 14,318,182. On each tick, counter_v += frequency_v for v = 0..2.
- **DPC+:**
  - NOTE loads frequency_v;
  - sample_v = RAM[`$C00` + 32·waveform_v + counter_v[31:27]];
  - AMPLITUDE = the 8-bit sum of the three samples.
- **CDF/BUS:**
  - each voice has a pointer word at RAM `$7F4` (BUS), `$7F0` (CDF0) or `$1B0` (CDF1, CDFJ, CDFJ+), + 4v;
  - when the driver scan found a size table, it also has a size word, and shift = size[11:7]; otherwise shift = 27;
  - sample = RAM[`$800` + (offset + counter >> shift) mod 4K]. CDFJ+ masks by the RAM size instead of mod 4K. offset is the pointer minus `$40000800` when the pointer is inside the window, else 0;
  - AMPLITUDE is the sum of the three samples.
- **Digital mode** (CDF mode[7:4] = 0; BUS3 likewise): voice 0's pointer + counter0>>21 (CDFJ+: >>13) addresses ROM (< `rom_size`) or the RAM window, else the result is 0.
  - AMPLITUDE is one nibble of that byte. Counter bit 20 (CDFJ+: bit 12) picks which nibble.
- **During calls**, the ARM reads and writes the counters and frequencies through FIQ r8–r13:
  - each counter is replaced only if the ARM changed it relative to its value at launch;
  - the frequencies are always replaced;
  - ticks keep running during the call.

### 2.7 Upstream quirks a bit-exact clone must keep

1. DPC+ fast fetch arms on any `$1xxx` read of `$A9`, not only opcode fetches, and its operand does not have to be at address+1. CDF does require address+1.
2. DPC+ register numbers are 6 bits wide (DFxFLAG via `LDA #$2x`). DFxFLAG for fetchers 4–7 reads 0.
3. DPC+ params 4–7 are stored but never read. The service counts are clamped, and the service leaves the counter unchanged.
4. Hotspots are ignored on substituted reads.
5. The jump lookahead uses the linear image (X+1, X+2), not bank-relative addresses, so a `$4C` at `$1FFE` looks into the next bank.
6. The BUS map is indexed by a[4:0], so `$20–$24` alias entries 0–4.
7. **BUS stuffing window:** `stuff_valid` is high only in clocks E0+4..E0+5. It drops at the commit, so the TIA's phase-2 write latch finishes with the CPU's own byte, while the RIOT (which latches at E0+6) gets the stuffed byte. This looks like an upstream bug for TIA stuffing (§5 risk 4).
8. Upstream's combinational `d_out` changes after the commit (§2.1), which is visible only in `open_bus`.

## 3. Lean design

### 3.1 Where state lives

| State | Upstream | Lean |
|---|---|---|
| DPC+ fetchers, 8 × 56 bits | 448 FF | **State RAM**, two words per fetcher with fields on byte lanes: w0 = {bottom, top, 0:counter[11:8], counter[7:0]}; w1 = {increment, 0:fraction[19:16], fraction[15:0]}. TOP, BOTTOM, LOW, HI, FRACLOW, FRACHI and FRACINC become pure byte-enable writes. Only DATA, DATAW, FRACDATA, PUSH and WRITE need a read-modify-write. |
| DPC+ params | 64 FF | state RAM word, with a byte-lane write at `ptr` (only lanes 0–3 matter) |
| DPC+ random, waveforms, bank, flags, param pointer | FF | FF, about 70 bits (random is read and stepped in the same cycle) |
| CDF/BUS pointers, increments, BUS map | M10K copies + snoop + writeback + preload | **Read and written in place in cart RAM port B**, as the Harmony driver does. Nothing to snoop, write back or preload. |
| CDF/BUS fast-fetch, jump and STY tracking, mode, stuff target | FF | FF, about 60 bits (they are compared against `a_in` every cycle) |
| Audio counters, frequencies, seeds, return mailbox (15 × 32) | 384 FF in audio + ~1,150 FF in the controller | **State RAM** words. The controller reads and writes them on port A (`clk_arm`) while the CPU is halted. |
| Fast-jump lookahead | 32-Kbit bitmap, 4 M10K | two extra ROM-port reads (X+1, X+2) in the `$4C` cycle |
| ROM bytes | SDRAM byte stream | image BRAM port B (32-bit, `clk_sys`) |

The state RAM is 256 × 32: dual-clock true dual port, 2 M10K (1 M10K in simple dual-port mode if the call exchange is done from `clk_sys`). It is kept apart from cart RAM so that the ARM-visible map stays clean, which matters while CDFJ+'s RAM size is still open (§5 risk 5).

### 3.2 Slot schedule

s = clocks since E0. Read data is final at s4; the CPU latches at E0+6.

| s | ROM port B | Cart RAM port B | State RAM | Datapath / 6507 |
|---|---|---|---|---|
| 0 | issue bank_base + a[11:0] | free for audio | | address valid |
| 1 | q: the byte at a. Decode: fast fetch, jump, register. | issue the pointer word (CDF/BUS) or the map word (BUS stuff) | issue the DPC+ fetcher word | `d_out` ← ROM byte, random byte or amplitude |
| 2 | issue word + 1 (lookahead) | q: pointer. Issue the data byte at `$800` + P>>20, or (stuff) the stream's pointer. | q: fetcher word. Issue the data byte at `$C00` + counter or fraction. | W ← word; window flag; DFxFLAG ready |
| 3 | q: X+1..X+4. Compute `jump_ok`. | q: data byte. Issue the increment word, or (stuff) the data byte. | | `d_out` ← RAM byte (& flag). DPC+: W ← W ± 1 or fraction + increment. Jump and DSWRITE: W ← W + 1<<20. |
| 4 | | q: increment, so W ← W + I<<12. (Stuff: q is the byte, which becomes `stuff_data`; issue the increment.) | | stuff window opens |
| 5 | | (stuff) q: increment, so W ← W + I<<12 | | **At the E0+6 edge, if `access`:** latch `d_in` and the op; bank; flags; DSPTR shift-in. The CPU latches `d_out`. |
| 6 | | write W to the pointer word | DPC+: write W, or the field bytes | |
| 7 | | byte write (WRITE, PUSH, DSWRITE, stream write) or the rotated map word | DPC+ params byte | |
| 8–11 | copy-engine source reads; digital-audio ROM read | copy-engine destination writes; audio reads | audio counter/frequency read-modify-write, seeds, returns | audio owns W from s8 to s1 |

- The worst cases are the BUS stuffed write and a CDF fast fetch. Both use 6 of the 12 slots.
- Every stage is a registered single-cycle `clk_sys` path: M10K q → logic → M10K address. The sketch's worst setup slack is +53.9 ns at 69.8 ns [sketch].
- The 6507 sees its data from s4, two clocks before it latches.

### 3.3 Shared datapath

- One 32-bit register W and one adder: sum = W + B.
- B is one of:
  - I[15:0]<<12 or I[15:0]<<8 (stream steps);
  - 1<<20 or 1<<16 (jump and write steps);
  - 1 or `$FFF` (counter ±1, 12-bit);
  - W[31:24] (fraction step);
  - `st_q`, `st_q`>>13 or `st_q`>>21 (audio).
- W's next value is one of `ram_q`, `st_q`, sum, or the DSPTR shift-in.
- DPC+ fields wrap through the write lanes:
  - after a counter operation only lanes 0–1 are written, and every reader uses bits [11:0];
  - after a fraction operation only lanes 0–2 are written, and readers use [19:0] and [19:8];
  - so a carry into a spare nibble is harmless, and HI and FRACHI rewrite that nibble anyway.
- The window flag is a single comparator on the word just read, not eight.
- The bank base is (scheme base + 4K·bank), giving a 17-bit image address.

### 3.4 Scheme by scheme

Only one scheme is active (chosen at load), so the decodes (comparators on `a_in`, `rom_q`, `mode`) are cheap and live side by side. What differs per scheme is three things:
1. which word is read at s1;
2. the data-byte address formula (DPC+ `$C00` + counter or fraction[19:8]; CDF/BUS `$800` + P[31:20]; CDFJ+ `$800` + P[30:16]);
3. the update (counter ±1, fraction + increment, pointer + I<<k, pointer + 1<<k, shift-in, map rotate).

The decodes and expected-address registers are shared where they are mutually exclusive: CDF's fast-fetch register doubles as BUS's STY register, and the jump registers serve both CDF and BUS3.

### 3.5 Audio engine

- One job per 6507 cycle, run in s8–s1 using W:
  - **voice job:**
    - s8: read c_v; s9: W ← c_v, read f_v (and the pointer word);
    - s10: W ← c + f, and the offset is computed from the pointer;
    - s11: write c_v, and the size word gives the shift;
    - s0: read the sample at `$800` + offset + (W >> shift) (masked);
    - s1: accumulate the sample.
  - **digital job:** the pointer is loaded into W, then W + `st_q`>>k, then a ROM or RAM read and the nibble.
  - **note, seed and merge jobs:** word copies between the state RAM and cart RAM.
- A tick counter keeps ticks that arrive during a DPC+ copy; the 6507 is held during copies anyway.
- The 32→15-bit barrel shifter (about 60 ALMs) is kept for exactness.

### 3.6 Copy engine (load-time RAM image and DPC+ copy/fill)

- One byte per two background slots: read the image (ROM port B), then write cart RAM with a byte enable.
- The clamp bounds are tested as the counters run (destination = `$1C00`, source = `$7C00`, count = 0), which equals upstream's min() clamps.
- 8 KiB at load takes about 1–3 ms with the console in reset (1 byte per 2 clocks when no phi1 arrives, else 5 slots per 6507 cycle). A 255-byte service takes about 100 6507 cycles. Upstream's DDR3 DMA stall is a different length too; no game can see the difference except through scanline position.
- This replaces `arm_mapper_ram_init`, the DPC+ service registers, and upstream's DDR3 DMA and sample-read engines.

### 3.7 Calls and the controller

- The call request is unchanged: a pending flag and `call_ready`.
- The controller loads FIQ r8–r13 from the state RAM's seed and frequency words (port A, CPU halted), and returns them to the mailbox words.
- The audio engine performs the "changed since launch?" merge on `clk_sys`.
- This removes about 1,150 mailbox FF. The controller shrinks to about 100–150 ALMs [E], from 716 [probe].

### 3.8 Coding rules for this flow

`ap_core.qsf` sets `MUX_RESTRUCTURE OFF` project-wide, and coding style changes the size accordingly:

| Style | ALMs [sketch] |
|---|---|
| Registers assigned in many FSM `case` arms | 1,343 |
| Same function with mux restructuring turned on | 1,063 |
| One load enable and a ≤4-way data mux per register; one-hot slot ring; submodules | **1,018** |

So: write each register with a single load enable, a data mux of at most four inputs, one-hot slot enables, and AND-OR muxes.

## 4. ALM estimate

| Part | [sketch] v2 / v3 ALMs | LUT / FF (v3) | Assumptions | Upstream counterpart (live [probe]) |
|---|---|---|---|---|
| Slot ring, shared W + adder, port arbitration (32-bit write data to two RAMs) | 239 / 239 | 362 / 48 | 10 B sources, 4 W sources | spread across all blocks |
| Front-end core for DPC+, CDF/J/J+ and BUS: decode, small state, address generation, read data, commit | 461 / 436 | 676 / 249 | random in FF; decode by comparators | `mapper_dpcplus` + `mapper_cdf` + `mapper_bus` = 1,327 |
| Copy engine | 103 / 104 | 189 / 66 | byte-wide, dedicated counters | `ram_init` 77 + DPC+ service 69 (+ ARM-side DMA) |
| Audio engine | 216 / 225 | 358 / 81 | full barrel shift; uses W | `arm_mapper_audio` 657 |
| State RAM | 0 (2 M10K) | none | 256 × 32, dual clock | tables 93 + writeback 34 + fastjump 39 (8 M10K) |
| **Measured total** | **1,018 / 1,004** | 1,585 / 444 | | **2,226** (1,752 in 2.1.1) |
| Not in the sketch [E] | +30 to +60 | | call entry/stack select; CDF `$FF4`/`$FFB` bank cases; state-RAM clear path; BUS0 flag; exact per-family waveform offsets; re-init on reset | |
| Further savings [E] | −100 to −200 | | copy engine on the shared datapath (−50 to −70); random in state RAM (−15); table-driven address decode in one M10K (−30 to −40); single write-data path (−20 to −40); barrel shift limited to ≥16 if no game needs less (−20) | |
| **Expected** | **850–1,100** | | | |
| Call controller [E] | 100–150 | | | 716 |

**Against today:**

| Comparison | Saving |
|---|---|
| The 2.1.1 build's 1,752 | −650 to −900 |
| Reusing upstream live (2,226, plus `cart2600` glue of about 80) | −1,200 to −1,450 |
| Call controller (716 → 100–150) | about −550 more |
| M10K | net −6 |

In the plan's area terms, the saving against 2.1.1 alone is about the Thumb expander + S3 estimate (350–910); against live reuse it is more.

**What still forces flip-flops** in the lean design (about 450 FF, measured 444):
- the LFSR, which is read and stepped in one cycle;
- the expected-address and stuff-target registers, which are compared against `a_in` every cycle;
- bank, mode and waveform selects;
- the slot ring;
- audio temporaries.

None of it is per fetcher or per stream. In upstream, what forces flip-flops is the single-pass read path: all eight windows are compared in parallel, and the counter and fraction muxes sit inside the ROM-to-bus path.

## 5. Risks, and how to prove equivalence

| # | Risk | Mitigation |
|---|---|---|
| 1 | **AMPLITUDE timing is not bit-exact.** Upstream updates the amplitude a variable number of clocks after each tick, depending on its RAM grant (`!sel_ram_sel`) and SRAM/DDR3 latency. The lean engine takes a fixed 1–4 6507 cycles. A 6507 read inside that window sees the neighbouring tick's value. In a full system, ARM call lengths differ between DARIA and upstream anyway, so audio phase cannot match. | Compare the per-tick amplitude sequence exactly. Accept an AMPLITUDE read that returns the previous tick's value, and count such cases. |
| 2 | **Stall lengths differ** (calls, DPC+ copy/fill). Full-system 6507 traces drift in time. | Do the exact comparison in shadow mode (below). For full-system runs, compare per frame. |
| 3 | **`open_bus` after the commit:** upstream's `d_out` changes after E0+6, the lean `d_out` holds. Only a partially driven TIA or RIOT read in the very next cycle could see the difference, and no instruction does that after a cartridge read (the next cycle is an opcode fetch). | Compare at the latch edges. If needed, replay the read with the committed state in s8–s11. |
| 4 | **BUS stuffing window (quirk 7):** TIA writes end unstuffed in upstream. There is no BUS image in the 15-demo test set. | Check a BUS title against Stella or hardware, then decide whether to copy upstream or fix both. Get a BUS image for the bench. |
| 5 | **RAM size:** upstream's 6507 side reaches 32 KiB for CDFJ+ (`$800` + 15 bits, `mapper_ram_size` 32K). DARIA's RAM is 16 KiB. | Define wrap or abort behaviour. The measured demos stay within 16 KiB. |
| 6 | **Port sharing:** both BRAMs' port B serve front end + audio + copy engine. | Any other DARIA use of those ports (load capture, assets) must stay out of s1–s7, or be paused while the 6507 runs. |
| 7 | **Quirk fidelity (§2.7).** | Directed tests (below). |
| 8 | **Coding style under `MUX_RESTRUCTURE OFF`** (§3.8). | Measure each block as it is written, with these probes. |

Tests:
1. **Shadow comparison in `tb_daria.sv`** (MiSTer configuration, upstream ARM, the 15 Champ demos × 1,500 frames, then longer runs).
   - Instantiate the lean front end next to upstream's, with:
     - the same `a_in`, `rw`, `d_in`, `phi1`, `access`, `arm_driver_run`;
     - its own image BRAM, loaded from the same stream;
     - its own cart RAM, mirroring every ARM write from `cart_ram_tdp` port B plus its own 6507-side writes.
   - Check:
     - at every `pclk0` edge where the cartridge drives the bus: `d_out`;
     - at every commit: bank, `call_request` and `service_request` (same cycle), `stuff_valid`/`stuff_data` in s4–s5;
     - after each 6507 cycle: the DPC+ fetcher fields against `mapper_dpcplus`'s registers (hierarchical references), and the CDF/BUS pointer, increment and map words against `arm_mapper_tables`' copies (upstream's own cart RAM lags because of the writeback);
     - per tick: the amplitude sequence.
   - This takes ARM timing out of the comparison entirely, as `run_pokey_shadow.sh` did for POKEY.
2. **Directed 6507 tests per scheme**, run on both implementations, comparing bus traces. BUS needs them most, since it has no demo. Cover:
   - 12-bit counter and 20-bit fraction wraps; window edges;
   - non-adjacent DPC+ fast fetches; `$A9` as data; `$4C` at a bank end;
   - hotspots on substituted reads;
   - stuff targets `$00–$24` and their aliases; mirrors;
   - CDFJ+ LDX/LDY and the fetch offset;
   - copy/fill clamps; FRACLOW on both revisions.
3. **Random differential:** a Verilator bench drives upstream's modules and the lean block with constrained-random 6507-like cycles (random image seeded with `$A9`, `$A2`, `$A0`, `$4C`, `$84`) for at least 10⁸ cycles, with the same checks.
4. **Full system** (DARIA against upstream): per-frame video CRC and per-frame TIA write logs, aligned at frame boundaries. Expect divergence only through stall length and AMPLITUDE (risk 1).
5. **Hardware:** the 15 demos, a BUS title and a batari Basic DPC+ title.

## Appendix: the files here

- `run_study.sh [NAME ...]` compiles each project in `sim/work/bupchip/daria/frontend_study/<name>/` (gitignored) and prints the table: the upstream blocks, `mapper_dpcplus_{core,nofrac,nowindow,norandom,noservice}` (the deletion variants that `variants.py` writes), and `daria_fe3`. `gen.py` writes one project.
- `daria_fe3.sv` is v3 of the sketch: enable style, AND-OR muxes, split into `fe3_core`, `fe3_copy` and `fe3_audio` for attribution. 1,004 ALMs; 990 with mux restructuring on. Two earlier versions were compiled for §3.8 and not kept: v1 in state-machine style (1,343; 1,063 with mux restructuring on) and v2 with enables and submodules (1,018).
