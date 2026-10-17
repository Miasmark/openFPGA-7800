# Glue around upstream's 2600 ARM front ends (DPC+, CDF family)

What a replacement for upstream's `mapper_dpcplus` / `mapper_cdf` and their ARM service must reproduce at the seams: the RAM image built at load end and on console reset, the DPC+ copy/fill DMA, the call handshake, the 6507 stall, the scheme parameters from `detect2600`, and the `cart2600` output contract.

All paths are relative to `src/fpga/mister/rtl/` unless they start with `sim/`, `docs/` or `src/fpga/core/`. "file:N" cites a line. BUS is covered only where the glue is shared (DARIA leaves BUS out, `docs/DARIA_CORE.md` decision 6).

**Review status.** An adversarial pass re-read every cited line. Markers: **[checked]** the claim was re-read and holds; **[corrected: …]** the original was wrong or imprecise and is fixed here; **[added]** new material. Unmarked sentences inside a [checked] paragraph were checked with it.

## 0. Conventions and how this was checked

- **clk_sys edges.** `S(n)` is the n-th rising edge of `clk_sys`. A register "set at S(n)" holds its new value in the cycle after S(n). A combinational signal "in cycle (S(n), S(n+1))" is sampled at S(n+1). [checked]
- **E0** is the `clk_sys` edge at which `pclk1` (the 6507 phase-1 enable, `cpu_ce`, top.sv:335) is sampled high. Phase 2 (`pclk0`) is sampled at **E0+6**, and the next phase 1 at E0+12. The TIA divider counts six `pclk_edge`s per 6507 cycle, phase 2 at `pclk_div == 2` and phase 1 at `pclk_div == 5` (TIA.sv:505-506, 556-558). One `pclk_edge` comes every 2 `clk_sys`, so the spacing is 6/6. The 12-`clk_sys` cycle is also tb_daria's `SYS_PER_CPU` (sim/bupchip/daria/tb_daria.sv:85). [checked; [core] confirms the CALLFN commit at the `pclk0` edge 6 after the write cycle's `pclk1`]
  - [corrected: the 6/6 spacing holds for the TIA phase source] The 6507's phases come through `cpu_phase_controller` (top.sv:396-411), which switches from MARIA's to the TIA's pair once `phase_source_request_tia` (top.sv:259-260) holds after reset, and through M6502C's pairing gate, which drops an unpaired phase (top.sv:1418-1427). `pclk1`/`pclk0` in this spec are those gated phases.
  - [corrected: RSYNC has two effects, not one] An RSYNC write sets `pclk_div` to 2 on the next `hclk.edge_p2` (TIA.sv:565-567) and, through `resp0` (TIA.sv:528), allows a phase-1 edge at `pclk_div == 0` (TIA.sv:506). Either breaks the 6/6 spacing for that cycle. Every glue rule below is keyed to the actual `pclk1`/`pclk0` edges (RDY at `pclk1`, `stall_cycle_taken` and `mapper_phi2` at `pclk0`), so it still holds if "E0+6" is read as "the next `pclk0`" and "E0+12" as "the next `pclk1`". A replacement must key on those events, never on `clk_sys` counts.
- **clk_arm** is exactly 5 × `clk_sys` from the same PLL, with one ARM edge in five on the `clk_sys` edge (cart_ram_tdp.sv:28-34; tb_daria.sv:80-81). `A(k)` is the k-th `clk_arm` edge, numbered so that **S(n) = A(5n)**. "S(n)+0.2·j" means A(5n+j). [checked]
  - A `clk_sys` toggle changed at S(n) is first seen by a `clk_arm` sync1 flop at A(5n+1) and by sync2 at A(5n+2). Logic that compares sync2 acts at A(5n+3). [checked]
  - A `clk_arm` toggle changed at A(k) is first seen by a `clk_sys` sync1 at S(⌊k/5⌋+1) and by sync2 at S(⌊k/5⌋+2). Logic that compares sync2 acts at **S(⌊k/5⌋+3)**. This holds for k = 5n too: a flop sampling at the shared edge sees the old value. [checked]
- **Evidence tags.**
  - **[sim]** marks timings the original writer confirmed in a scratch simulation (Icarus 12 / Verilator 5.020) of upstream's own `arm_mapper_memory`, `arm_mapper_ram_init`, `arm_mapper_tables`, `arm_mapper_writeback`, `arm_mapper_controller`, `cart_ram_tdp`, `cache_ram`, `ddram`, `mapper_dpcplus`, `mapper_cdf` and `6502/mos6502*.sv`, with `cart2600`'s glue and `top.sv`'s stall logic transcribed, a synthetic 32 KiB image, tb_daria's DDR3 model (`lat` = 20, `DDRAM_BUSY` = 0; tb_daria.sv:133, 151-174, 210), and a **stub** ARM (state port answering in the cycle asked, `cpu_halted` one `clk_arm` after `halt_req`).
  - **[bb]** [added] marks results of this review's scratch Verilator 5.040 bench: upstream's real `arm_host` + `arm7tdmi_core` compiled as a **black box** (its source was not opened; only its ports, its `retire`/`trace_retire_*` outputs that tb_daria already taps, and three `arm7tdmi_pkg` constants printed by `$display` were observed), with `arm_mapper_subsystem`, `arm_mapper_ram_init`, `cart_ram_tdp`, `cache_ram`, `ddram` and tb_daria's DDR model (`lat` 20). Synthetic image, hand-assembled Thumb snippets (`bx lr`; `push {lr}; pop {pc}`; eight `mov r8,r8` then `bx lr`; a counted loop).
  - **[core]** [added] marks results of this review's full-core run: tb_daria's own source list (as `sim/bupchip/daria/run_daria.sh` builds it, patched copies in scratch) with `tb_daria` instantiated under a probe module, running a synthetic 32 KiB DPC+ image written for the purpose: a 6507 loop `LDA #$FE; STA $105A; NOP; NOP; NOP; JMP` and a Thumb routine that loops a RAM counter + 1 times, so successive calls sweep the busy fall X across E0+24 to E0+59. No game data was used.
  - Nothing in the repository was changed. The scratch files were deleted.

## 1. Who drives what [checked]

| Signal | Driver | Consumers |
|---|---|---|
| `reset` of cart2600 | `effective_reset = reset \| reset_hold` (top.sv:255, 1130) | every front end's reset with `mapper != X` (cart2600.sv:805, 843, 902); the subsystem's `mapper_reset` (cart2600.sv:447); `ram_init.mapper_reset` (:710); writeback, both domains (:741, :751; the `clk_arm` half takes the `clk_sys` level unsynchronised); audio (:762) |
| `reset_arm` | wrapper power-on reset `arm_reset` (top.sv:1157); Pocket: `~pll_locked` (atari7800_pocket.sv:994) | subsystem `reset_sys` **and** `reset_arm` (cart2600.sv:444, 456); [added] the CPU (`arm_host` reset = `arm_reset \|\| (souper_profile && bup_hold)`, top.sv:812) and the DDR bridge (top.sv:861). The controller's "system online" and every mailbox reset come from this, not from the console reset. |
| `ce` of the ARM, `mem_ce` of the memory system | [added] `~pause` (top.sv:816, 1187; arm_host.sv:15-18, 62) | the CPU stops while paused; the memory system holds a finished answer and stops its timer (arm_mapper_memory.sv:48-51, 527-529, 729-737, 978-979, 1002-1005, 1012-1013, 1021-1022). See section 8. |
| `mapper` | `\|mapper ? mapper : force_bs`: the OSD override or detect2600 (top.sv:1138) | every `mapper == BANKx` select in cart2600 |
| `a_in` of cart2600 | [added] `{AB[12] & bios_en_b, AB[11:0]}` (top.sv:1128): A12 is gated by INPTCTRL's cart-enable bit | every front end's address |
| `phi1`, `phi2` of cart2600 | `pclk1`, `mapper_phi2` (top.sv:1133-1135) | `access_taken`, the cartram strobes, `arm_access` |
| `arm_driver_run` | `lock_ctrl && tia_en` (top.sv:1136) | `arm_access = phi2 && arm_driver_run` (cart2600.sv:247), the front ends' `access` |
| `mapper_init_busy` | `arm_mapper_ram_init.busy` (cart2600.sv:716) | wrapper reset; top.sv cart-RAM mux and port enable; DMA ownership; call and service gating; stall masking (sections 3, 4) |
| `arm_call_busy` | controller `call_busy` (cart2600.sv:485) | `arm_call_stall` (top.sv:306-307) |
| `arm_dma_busy` | memory `dma_busy` (cart2600.sv:466) | `arm_call_stall`, masked by `!mapper_init_busy` (top.sv:306-307) |
| `mapper_ram_size` | 32768 if `force_bs == BANKCDF && mapper_revision == 3`, else 8192 (top.sv:778-783). This uses `force_bs`, not the OSD `mapper`. | ARM RAM decode (arm_mapper_memory.sv:568-569); init DMA2 count for CDF (arm_mapper_ram_init.sv:171); audio |
| `rom_size` of cart2600 | `cart_size` (top.sv:1148) | ARM shadow size (cart2600.sv:452 → arm_mapper_memory.sv:329, 775-777); audio's digital route (cart2600.sv:765) |

Scheme codes (detect2600.sv:2-8): BANKDPCP = 21, BANKCTY = 22, BANKCDF = 23, BANKBUS = 24, BANKELF = 32. [checked; [core]: detect2600 reported `force_bs 21` for the synthetic DPC+ image] Two family encodings exist and must not be confused:

- `init_family`, used by ram_init and audio: DPC+ 1, BUS 2, CDF 3, else 0 (cart2600.sv:658-660). [checked]
- `table_family`, used by arm_mapper_tables: BUS 1, CDF 2, else 0 (cart2600.sv:652-653). [checked]

## 2. detect2600: what DPC+ and CDF consume, and when it is valid [checked]

All outputs reset at `load_start`: the per-byte ones at detect2600.sv:117-137, and `force_bs`, `sc` and `mapper_revision` at :206-209. `load_end` here is the raw pulse `old_cart_download && ~cart_download`. Call **L** the edge at which it is sampled (tb_daria.sv:119, 206; atari7800_pocket.sv:999).

| Output | How | Valid from | DPC+ uses | CDF uses |
|---|---|---|---|---|
| `force_bs` | Priority chain at L (detect2600.sv:210-226): ELF, then FA2 (24K/28K without DEVC), then **29,696 bytes → DPCP unless the FA2 loader signature** (:216), then CTY (32K/60K with "LENIN", :217), then **CDF if `hasMatchCDF && cdf_size`** (:218), then **DPCP if `hasMatchDPCP` and 32,768 bytes** (:223). `cdf_size` is 32/64/128/256/512 KiB (:70-72). `hasMatchCDF`: "CDF" three times, or "PLUSCDFJ", anywhere in the image (:444-468). `hasMatchDPCP`: "DPC+" twice (:403-414). [added] Patterns match only across consecutive download addresses, and occurrences may overlap (detect2600.sv:320-341, 1479-1513). | after L | scheme select | scheme select |
| `mapper_revision` | Cleared at L (:212), then set by the branch that wins. DPC+: 1 if the CRC32 of bytes 0-3071 is 0xA08CFB13, else 0 (:142-144, 225). [corrected: the CRC variant was underspecified] The CRC is `nextCRC32_D8` (detect2600.sv:1428-1475): polynomial 0x04C11DB7, **MSB first, not reflected** ("the first serial bit is D[7]", :1429), seed 0, no final XOR, folded over the bytes in download order whenever `load_valid && load_addr < 3072`. It is not zlib's CRC-32. The 29,696-byte DPCP path leaves the revision 0 (:216). CDF: 3 (CDFJ+) if `cdfj_plus`, else 2 (CDFJ) if `cdfj_count ≥ 3`, else 0 (CDF0) if `cdf0_count ≥ 3`, else 1 (:220-221). | after L | bit 0 → `stable_fractional` (cart2600.sv:811) | [1:0] → mapper_cdf, audio (cart2600.sv:849, 764); [2:0] → ram_init (latched), tables (live), `mapper_ram_size` |
| `cdf_ldx`, `cdf_ldy` | Set when an aligned word below byte 2048 equals 0x135200A2 / 0x135200A0 (:162-166) | after that word | no | enable LDX#/LDY# fast fetch (CDFJ+ only, mapper_cdf.sv:82-84) |
| `cdf_fetch_offset_enable`, `cdf_fetch_offset` | Aligned word below byte 2048 with `(w & 0xFFFFFF00) == 0xE2422000`; the offset is its low byte (:167-170). The last match wins. | after that word | no | mapper_cdf.sv:89-98 |
| `cdfj_stack`, `cdfj_entry` | Little-endian words at image bytes 0x17F4 and 0x17F8, taken whatever the scheme. Entry is `& 0xFFFFFFFE` (:196-200). | after byte 0x17FB | no | CDFJ+ call stack and entry only (mapper_cdf.sv:160-161) |
| `arm_audio_size_addr` | After an aligned word 0xE3C55D3E below byte 3072, the first of the next ≤ 20 aligned words whose top half is 0x4000; its low half (:149-161). [added] A later 0xE3C55D3E restarts the scan, and a later match overwrites the value. | after that word | not read on the DPC+ path (arm_mapper_audio.sv:238-239) | waveform size words (arm_mapper_audio.sv:293-310) |
| `cart_size` (`rom_size`) | Last download address + 1 for a 2600 image (a78_cart_extent.sv:37-45, 71-76): the address of the most recent `ioctl_wr`, plus one; 0x8000 at power-up (:32-35) | after the last byte | ARM ROM bound | ARM ROM bound; audio's digital source route (arm_mapper_audio.sv:336) |

Notes:

- "Word" means four bytes assembled little-endian, completed at `load_addr[1:0] == 3` (detect2600.sv:59-63, 146). The window is rebuilt from the byte with `addr[1:0] == 0`, so the four bytes must arrive in address order. [checked]
- The 29,696-byte DPCP case still addresses the ROM at 3072 + bank·4096 (mapper_dpcplus.sv:127). See open question 7. [checked]
- When each value is consumed: [checked]
  - ram_init latches `family`, `revision` and `mapper_ram_size` at **L+1**, on the delayed `load_end_d` (cart2600.sv:572-577, 712; arm_mapper_ram_init.sv:212-219). That is why the delay exists: `force_bs` changes at L.
  - The ARM shadow takes `rom_size` when its end message is processed, after L (arm_mapper_memory.sv:316-333, 770-777).
  - Everything else is read live. [added] Two exceptions: `mapper_cdf` samples `revision` into its reset bank while its reset is high (mapper_cdf.sv:166), and arm_mapper_tables keeps one-flop `clk_sys` and `clk_arm` copies of family and revision for its ARM-port decode (arm_mapper_tables.sv:57-70).

## 3. Load, RAM image and front-end start-up: the sequence

1. **load_start** (pulse; tb_daria.sv:117, 204): `ram_init.loading` ← 1, so `mapper_init_busy` = 1 from the next cycle (arm_mapper_ram_init.sv:75, 207-211). Other things happen on the same edge: [checked]
   - The memory system toggles its epoch. On `clk_arm`, `shadow_ready` ← 0, both caches, the fetch line and the sample cache are invalidated, and MAMCR and the timer are cleared (arm_mapper_memory.sv:288-294, 739-749).
   - detect2600 resets (section 2). `load_end_d` is cleared (cart2600.sv:573-574).
   - The fast-jump map starts rebuilding (cdf_fastjump_table.sv:26-39, 61-68).
   - The wrapper's reset is already high from `cart_download` (atari7800_pocket.sv:166-172; tb_daria.sv:98-101).
   - [added] Not touched: the DMA engine, the call controller and `dma_busy`/`call_busy`; they reset only on `reset_arm` (arm_mapper_memory.sv:235-270, 649-716; arm_mapper_controller.sv:92-124, 238-262).
2. **Download.** Bytes pack into 64-bit words and are written to the DDR3 shadow at word `0x06000000 + addr[24:3]` (arm_mapper_memory.sv:8, 296-314, 764-769). `load_wait = word_pending || end_pending` paces the loader (:227). The fast-jump map and detect2600 scan the same stream. [checked]
3. **L** (`load_end`): detect2600 decides `force_bs` and `mapper_revision`; memory sets `end_pending` (arm_mapper_memory.sv:316-317). [checked]
4. **L+1**: `load_end_d` reaches ram_init. `loading` ← 0, and `state` ← `INIT_DMA_FIRST` if `family != NONE`, so `busy` stays high without a gap. Family, revision and RAM size are latched, and `image_loaded = (family != NONE)` (arm_mapper_ram_init.sv:212-219). The same edge flushes the partial last word or sends the end message (arm_mapper_memory.sv:319-333), provided the last full word's write has been acknowledged (`!word_pending`). [checked]
5. **Shadow ready.** On `clk_arm`, once DDR_IDLE has no word left to write: `shadow_ready` ← 1 and `rom_size` ← min(size, 1 MiB) (arm_mapper_memory.sv:770-777). It reaches `clk_sys` through two flops. `dma_ready = shadow_ready_sync2 && !dma_busy` (:228). [sim]: end message at L+1, `shadow_ready` at L+1.6, `dma_ready` at L+3, DMA 1 accepted at **L+4**. [checked; [bb] reproduces L+4]
6. **DMA 1, then DMA 2, then the tables** (section 4). [checked]
7. **busy falls** at the edge where ram_init returns to `INIT_IDLE`. The wrapper's registered reset falls one edge later (atari7800_pocket.sv:169-171; tb_daria.sv:100). `reset_hold` releases on a later phase edge (top.sv:266-285). Then `effective_reset` = 0. [checked]
8. **Front ends start.** Each front end's reset is `reset || mapper != BANKx` (cart2600.sv:805, 843). Reset values that matter to the glue: `call_pending = 0` and `service_pending = 0` (mapper_dpcplus.sv:210-211; mapper_cdf.sv:173). The first bank is 5 for DPC+, and 6 for CDF (0 for CDFJ+) (mapper_dpcplus.sv:195; mapper_cdf.sv:166). [checked]
   - They commit nothing until `arm_driver_run = lock_ctrl && tia_en` (cart2600.sv:243-247). With `bypass_bios` and a 2600 image, `ctrl_reg` sets both on the first edge after reset (top.sv:1376-1382). Through the 7800 BIOS, that happens when the BIOS locks 2600 mode. [checked]
   - [corrected: "ignores registers" was too strong] Until then a front end serves its reset bank from ROM and changes no state (no hotspot, register write, fetcher step or CALLFN), but its combinational outputs still decode: DPC+ answers a read of `$x000-$x027` from its register file (`register_read` is not gated by `access`, mapper_dpcplus.sv:112-125, 160-180), and a DPC+ DFxPUSH/DFxWRITE address still raises `ram_sel` with `ram_rw` = 0, so `cartram_wr` (cart2600.sv:973-974, no `access` term) writes cart RAM if `tia_en` routes the 2600 port (top.sv:752-753). CDF's DSWRITE is gated by `access` (mapper_cdf.sv:150) and its substitutions need state set by commits, so CDF reads plain ROM.
9. **Console reset with an image loaded**, i.e. a rising edge of cart2600's `reset`: [checked; [bb] reproduced Q+1 and Q+2]
   - This is the core reset: OSD/menu reset or the wrapper's reset sources. It is not the 2600 RESET switch, which is a RIOT input (tb_daria.sv:181).
   - If `reset` rises at Q, ram_init sees `mapper_reset && !old_mapper_reset` at Q+1 and enters `INIT_DMA_FIRST`; busy = 1 from Q+1 (arm_mapper_ram_init.sv:205, 222-227).
   - The first DMA is accepted at Q+2 if the engine is idle. Then everything runs as from step 6. [sim]
   - Only `INIT_IDLE` looks for the edge, so a reset edge during an init is ignored. [added] With the wrapper's OR of `mapper_init_busy` into its reset, cart2600's `reset` stays high from Q until after busy falls, so a second rising edge during an init cannot occur at all.
   - [added] While `reset` is high, the `clk_arm` controller is forced to `CTRL_WAIT_HALT` every cycle and the memory system refuses new ARM requests (`req_phase` is gated by `!mapper_reset`, arm_mapper_memory.sv:557; controller :271-276). A CPU that was mid-call keeps its one outstanding request pending through the whole held reset, including the init, and has it served after the reset falls. Only then does it halt [bb]. If that request was a RAM store, the store lands **after** the RAM image was rebuilt. See 7.4.
   - [added] The init is not affected by pause: port A is enabled by `cartram_wr || cartram_rd` while busy (top.sv:921), the table loads read the unforced word bus (`cartram_word_data_tdp`, top.sv:934, 1158), and the DMA engine has no pause input.

### What holds the console while busy [checked]

| Hold | Where |
|---|---|
| The wrapper's reset register ORs `mapper_init_busy` | atari7800_pocket.sv:169-171; tb_daria.sv:100. [corrected: MiSTer settled] MiSTer's `emu` does the same, through a `clk_sys` register (`Atari7800.sv:75-79`, a copy outside the repository; see open question 3). top.sv only exports the signal (top.sv:110) and never holds its own reset on it (top.sv:255), so the hold exists only where a wrapper adds it. |
| `loading` = download or busy clears the 7800 RAMs and rewinds the Supercharger tape | top.sv:417-434, 1220; atari7800_pocket.sv:905; tb_daria.sv:201 |
| The cart-RAM port is forced to the 2600 path, enabled only on `cartram_wr \|\| cartram_rd` | top.sv:752-759, 921 |
| `mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy` | cart2600.sv:661-662 |
| `dpc_service_ready = !mapper_init_busy && arm_dma_ready`, and the init owns the one DMA engine | cart2600.sv:414-428 |
| `arm_dma_busy` does not stall the 6507 while busy | top.sv:306-307 |
| The ARM stays halted: `halt_req` is 1 in every controller state but RUNNING, and no call can be accepted | arm_mapper_controller.sv:211 |

Power-up with nothing loaded: busy = 0, because `loading` = 0, `state` = IDLE and `image_loaded` = 0 (arm_mapper_ram_init.sv:291-300). Before the first image ends, nothing runs. [checked]

## 4. The RAM image (arm_mapper_ram_init.sv)

### 4.1 What is written, in order [checked]

DMA 1 runs to completion, then DMA 2, then the table loads, strictly in sequence (arm_mapper_ram_init.sv:229-287). `dma_fill` defaults to 1, `dma_source` to 0 and `dma_value` to 0 (:134-139). "RAM" byte addresses are those of `cart_ram_tdp`, which the ARM sees at 0x4000_0000 + address (section 5.3).

| Family (rev) | DMA 1 (:141-154) | DMA 2 (:155-174) | Tables (:77-127, 178-202) |
|---|---|---|---|
| **DPC+** (`init_family` 1, any revision) | **fill 0x00 → RAM 0x0000-0x0BFF** (3,072 B) | **copy image 0x6C00-0x7FFF → RAM 0x0C00-0x1FFF** (5,120 B: display data, then the 1 KiB frequency table that NOTE writes read at 0x1C00 + 4·n, arm_mapper_audio.sv:134-135) | none. Ends after DMA 2 (`has_tables` = 0). |
| **CDF** (3), revs 0/1/2 | **copy image 0x0000-0x07FF → RAM 0x0000-0x07FF** (2,048 B, the driver) | **fill 0x00 → RAM 0x0800-0x1FFF** (`mapper_ram_size` − 0x800 = 6,144 B) | pointer[i] = RAM word at byte 4·(pb+i), then increment[i] = word at 4·(ib+i), for i = 0..C−1. **rev 0**: pb 0x1B8 (byte 0x6E0), ib 0x1DA (0x768), C 34. **rev 1**: pb 0x028 (0x0A0), ib 0x04A (0x128), C 34. **rev 2**: pb 0x026 (0x098), ib 0x049 (0x124), C 35. |
| **CDFJ+** (3, rev 3) | the same 2 KiB copy | **fill 0x00 → RAM 0x0800-0x7FFF** (30,720 B) | as rev 2: pb 0x026, ib 0x049, C 35 |
| BUS (2) rev 0 | copy 0x000-0xBFF | fill RAM 0xC00-0x1FFF | pb 0x2B8, ib 0x2C8, C 16; map base 0x2D9, 37 entries. Rev 0 shows the bad-game screen anyway (cart2600.sv:165-166). |
| BUS rev 1/2 | copy 0x000-0x7FF | fill RAM 0x800-0x1FFF | pb 0x1B8, ib 0x1C8, C 16, map 0x1D8 ×37 |
| BUS rev 3 | as rev 1 | as rev 1 | pb 0x1B6, ib 0x1C8, C 18, map 0x1D8 ×37 |
| none (0) | not run. `default: dma_count = 131072` at :153 is unreachable. | | |

[added] The family comes from the live `mapper` at L+1, so an OSD override selects the family; the revision is detect2600's, whatever it detected; `mapper_ram_size` follows `force_bs` (section 1). On a later console reset the init re-runs with the family, revision and size latched at the last load end (arm_mapper_ram_init.sv:212-227), even if the OSD selection changed since.

**Table load mechanics** (arm_mapper_ram_init.sv:178-202, 255-286): [checked]

- Each entry takes two `clk_sys` cycles: READ, then WRITE.
- In the READ state `init_ram_en` = 1 and `cartram_addr = {1'b0, word<<2}` (cart2600.sv:966). The port's address is registered (cache_ram.v:172-175), so the 32-bit `mapper_word_rdata = {q3,q2,q1,q0}` (byte 0 in the low byte, cart_ram_tdp.sv:58 [corrected: line 59 is `arm_rdata`]) is valid in the WRITE state and written to the table at the WRITE edge.
- The tables take init writes in preference to front-end updates (cart2600.sv:687-699).
- BUS map entries go into the increment RAM at index 16 + i (arm_mapper_tables.sv:153-155, 175-177).
- [sim]: after a CDFJ+ init, table entries equal the RAM words.

The DMA writes are themselves snooped into the tables when they land in a table range (section 5.3), so the copies agree with RAM before the explicit loads run. [checked]

### 4.2 Duration (exact for the tb_daria environment) [checked; every row reproduced by [bb]]

Let P be the edge that enters `INIT_DMA_FIRST`: L+1 at load end, Q+1 on a reset edge.

1. DMA 1 is accepted at **r1** = the first edge after P with `arm_dma_ready` high in the preceding cycle (arm_mapper_ram_init.sv:229-232; cart2600.sv:426). In [sim] and [bb], r1 = L+4 after a load and Q+2 on a reset.
2. DMA 1's busy falls at **F1** (section 5.2). `dma_done` is high in cycle (F1, F1+1).
3. ram_init enters `INIT_DMA_SECOND` at F1+1, and DMA 2 is accepted at **r2 = F1+2** (:234-246).
4. DMA 2 falls at **F2**. At F2+1 the state is `INIT_POINTER_READ` for CDF/BUS, or IDLE for DPC+ (:248-253).
5. busy falls at:
   - **DPC+: F2+1.**
   - **CDF: F2+1+4C**, i.e. +136 (C = 34) or +140 (C = 35).
   - BUS: F2+1+4C+74.

Totals with tb_daria's DDR model (`lat` = 20), from r1 [sim] and from L [bb]:

| Scheme | Steps | r1 → busy falls | L → busy falls [bb] |
|---|---|---|---|
| DPC+ | fill 3072: F1 = r1+771; copy 5120: F2 = r2+4483; end F2+1 | **5,257 clk_sys** | **5,261** |
| CDF/CDF1 (8K, C 34) | copy 2048: F1 = r1+1795; fill 6144: F2 = r2+1539; tables +137 | 3,473 | 3,477 |
| CDFJ (8K, C 35) | as above; tables +141 | 3,477 | 3,481 |
| CDFJ+ (32K) | copy 2048: r1+1795; fill 30720: r2+7683; tables +141 | **9,621** | **9,625** |
| BUS rev 0 / rev 1-2 / rev 3 | [added] | 4,115 / 3,475 / 3,483 | 4,119 / 3,479 / 3,487 |

Copy times depend on the DDR3 latency, so on hardware they vary (open question 4). Fill times do not. [checked]

[added] **Why the duration matters for a lock-step clone.** The console starts when the wrapper reset falls (busy fall + 1) and `reset_hold` then releases on a phase edge (top.sv:266-285), so the 6507's first cycle, and with it every later frame and audio phase, is set by when busy falls. A clone compared edge for edge from load end must hold busy for exactly these durations (for the bench's `lat` = 20), or the comparison must be re-aligned at the reset release. A different duration that crosses a phase edge shifts the whole run.

### 4.3 Aborts and corner cases [checked]

- `load_start` during an init: `state` ← IDLE and `loading` ← 1 (arm_mapper_ram_init.sv:207-211). A DMA already in the engine continues, because the engine has no reset but `reset_arm` (arm_mapper_memory.sv:649-716). The next init's DMA 1 waits for `!dma_busy` and the new shadow. [added] A copy still running reads a mix of old and new shadow words, since load writes take DDR priority (:763-788); the next init overwrites the result.
- `mapper_reset` does not abort a running DMA. `arm_dma_busy` is cleared only by completion or `reset_arm` (arm_mapper_memory.sv:269, 345-348). [added] A DPC+ service DMA running when the console reset rises therefore finishes first; DMA 1 of the new init waits for it (`dma_ready` includes `!dma_busy`), and its `dma_done` pulse is ignored because ram_init is in `INIT_DMA_FIRST`, not a WAIT state (:229-241). Its bytes land at 0x0C00 and above, which DMA 2 then overwrites.
- `old_mapper_reset` is updated on every edge, including the `load_start`/`load_end` edges (:205).

## 5. The one DMA engine (arm_mapper_memory.sv) and the shared RAM port

### 5.1 Handshake [checked]

- **Request mux.** While `mapper_init_busy`, the init drives `arm_dma_*`. Otherwise the DPC+ service does: `{6'b0, src19}`, `{2'b0, dst15}`, `{10'b0, cnt8}`, `dpc_service_value` (cart2600.sv:416-428). The ready and done signals are split the same way.
- **clk_sys side.**
  - A request is accepted at the edge where `dma_request && dma_ready` (`dma_ready = shadow_ready_sync2 && !dma_busy`). The payload is captured, `dma_toggle` flips and **`dma_busy` ← 1** (arm_mapper_memory.sv:228, 335-343).
  - `dma_busy` ← 0 and `dma_done` ← 1 for one cycle at the edge where `dma_busy && dma_complete_sync2 == dma_toggle` (:345-348).
- **clk_arm side.**
  - `DMA_IDLE` sees `dma_sync2 != dma_seen` at A(5r+3) and takes the payload (:858-876).
  - Count 0 completes immediately (:868-869). Fill goes to `DMA_RAM_WRITE`; copy goes to `DMA_COPY_COMMAND`.

### 5.2 Timing recipe (exact; [sim] at `lat` = 20) [checked; [bb] reproduces fill 200 → r+53, copy 20 from 0xC10 → r+23, fill 53 → r+16, and every init number above]

With the request accepted at S(r):

```
k0 = 5r+3                                  # DMA_IDLE takes the command
N == 0 : kL = k0
fill   : bytes written on the first N edges e > k0 with e mod 5 != 0
         (one byte per accepted edge; the shared edge e = 5n is refused,
          cart_ram_tdp.sv:35-57); kL = edge of byte N
copy   : e = k0                            # in DMA_COPY_COMMAND at edge e
         repeat:
           launch = e+1                    # DDR_IDLE -> DDR_DMA_COMMAND (arm_mapper_memory.sv:778-782)
           data   = launch + D             # DDR_DMA_READ -> DMA_RAM_WRITE (:822-835)
           write bytes on edges e' > data with e' mod 5 != 0, until the byte
           with source[2:0] == 7 (then e = its edge, back to COPY_COMMAND,
           :886-889) or the last byte (kL = its edge)
busy falls (and dma_done rises) at S(floor(kL/5) + 3)
```

- **D** is the DDR round trip. With `ddram.sv` (present on the edge after the request, accept when `!DDRAM_BUSY`, ddram.sv:101, 115-117, 165-187) and tb_daria's model (read seen on the accept edge, `lat` wait edges, then a beat, tb_daria.sv:151-174), **D = lat + 4** clk_arm. Each 8-byte copy group then takes lat+14 or lat+15 clk_arm, depending on phase. At `lat` = 20 that is exactly 35 = 7 `clk_sys` per aligned group. [checked] [added] In general D = 2 + (edges `DDRAM_BUSY` delays the accept) + (edges from accept to the beat being sampled). The `launch` assumes DDR_IDLE; anything already in DDR (a load word, a sample read, an ARM cache fill) delays it.
- **Closed forms** (S(r) = request edge):
  - **fill, N ≥ 2: busy falls at S(r + 4 + ⌊(N−2)/4⌋)**.
  - N = 0 or 1: busy falls at S(r+3).
  - Copy at `lat` = 20 with an 8-aligned source and N = 8m: S(r + 7m + 3).
  - [added] Copy at `lat` = 20 with an 8-aligned source, any N = 8m + g (1 ≤ g ≤ 8): **S(r + 8 + 7m + q(g))**, q = 0, 1, 1, 1, 1, 2, 2, 2 for g = 1…8. Derivation: the first data edge is 5r+28 (≡ 3 mod 5); a group's bytes land at data + 1, 3, 4, 5, 6, 8, 9, 10; that phase repeats every 35 clk_arm. An unaligned source starts with a short group of 8 − source[2:0] bytes and changes phase; use the recipe.
  - Verified [sim]: fill 200 → r+53; fill 3072 → r+771; fill 6144 → r+1539; fill 30720 → r+7683; copy 2048 → r+1795; copy 5120 → r+4483; copy 20 bytes from 0xC10 → r+23.
- **DDR priority.** In DDR_IDLE: pending load words, then the end message, then a DMA command, then an audio sample (:763-788). [corrected: an ARM cache fill also yields to a pending sample command] An ARM cache fill starts only from DDR_IDLE, and only while neither a DMA copy command nor a sample command is pending (:980-982). A sample read (CDF/BUS digital audio from ROM, arm_mapper_audio.sv:335-361) in flight therefore delays the ARM's cache misses: **a CDF call's length depends on where the audio tick falls**.
- [added] **DDR timeout.** If the bridge abandons a read (`ddr_timeout`, after 8,191 `clk_arm` without progress, ddram.sv:37, 149-160), DDR_DMA_READ re-issues the command (arm_mapper_memory.sv:827-830). This never happens with tb_daria's model.

### 5.3 The ARM's cart-RAM port and the console's [checked]

`cart_ram_tdp` is one 128 KiB RAM of four byte lanes (cart_ram_tdp.sv:68-84; top.sv:918-933). (top.sv:776 calls it "32K": that is 32K words of four lanes.)

- **Port A, `clk_sys` (the console side).** The byte address is `cartram_addr[16:0]`, with lane `addr[1:0]` latched when `mapper_en` (cart_ram_tdp.sv:63-66).
  - `mapper_en` = `!pause` normally, or `cartram_wr || cartram_rd` while init-busy (top.sv:921). It gates only the write and the lane latch; each lane's read address is registered every edge (cache_ram.v:172-175).
  - The address mux in cart2600 has three levels: init > the selected front end's `ram_a` > audio (cart2600.sv:965-967).
  - The read data `cartram_data` is forced to 0xFF while paused (top.sv:936). [added] The 32-bit `cartram_word_data` is not forced.
- **Port B, `clk_arm`, 32-bit with byte strobes.** Address = byte address [16:2].
  - Users: the ARM at 0x4000_0000 + byte offset, bounded by `mapper_ram_size` (arm_mapper_memory.sv:568-569, 637-644); the DMA engine (unbounded, 17-bit destination); the table writeback.
  - The DMA writes one byte per access: `wdata = {4{byte}}`, `wstrb = 1 << dest[1:0]` (:639-644). DMA has priority over the ARM's own access (:601, 637).
  - The table writeback has priority over both: `arm_cartram_accepted = arm_cartram_en && !mapper_wb_en && arm_ram_accepted` (cart2600.sv:432-439).
  - Port B is refused on the shared edge, `arm_accepted = arm_en && !mapper_edge` (cart_ram_tdp.sv:35-57). So nothing writes port B on a `clk_sys` edge. [sim]: accepted writes land at S(n)+0.2…+0.8, never at S(n).
- **Same bytes on both ports.** Front-end `ram_a` X is ARM address 0x4000_0000 + X. For example, DPC+ display data at 0xC00 + counter (mapper_dpcplus.sv:143, 157), and CDF data at 0x800 + pointer bits (mapper_cdf.sv:126-128).
- **Snooping.** Every accepted port-B write that falls in a table's word range, DMA writes included, is mirrored into `arm_mapper_tables` with its strobes. The layout comes from `family_arm`/`revision_arm`, two registered copies (arm_mapper_tables.sv:62-70, 139-150, 157-185). DPC+ has `stream_count` 0, so nothing is snooped.
- [added] **Timer and MAMCR.** Timer 1 counts in `clk_arm` (44 of 45 ticks NTSC, 75 of 76 PAL) whenever `mem_ce` = `~pause`, independent of calls, so it runs between calls while the CPU is halted. It is cleared by `load_start` and by the console reset (arm_mapper_memory.sv:474-489, 729-737, 746-748, 757-759). This is ARM-visible state; DARIA's MMIO covers it (docs/DARIA_CORE.md §6).

## 6. DPC+ copy/fill service [checked]

**Front end.** A write to `$1x5A` (register 0x05A: group 6, index 2) is handled at its access edge (mapper_dpcplus.sv:227, 253-254, 278-296):

- With data 1 (copy) or 2 (fill), and `!service_pending`:
  - `service_fill` = (d == 2)
  - `service_source` = 3072 + {p1, p0}
  - `service_dest` = 3072 + `counter[p2[2:0]]`
  - `service_value` = p0
  - `service_count` = the clamped count at that edge (:85-101):
    - `fill_count = min(p3, 0x1000 − counter[p2])`, keeping 8 bits;
    - `copy_count = 0` if `{p1,p0} ≥ 0x7400`, else `min(fill_count, 0x7400 − {p1,p0})`.
  - `service_pending` ← 1, and the parameter pointer resets.
- 0 resets the parameter pointer; 0xFE/0xFF is CALLFN (section 7). [added] Any other value, and 1 or 2 while `service_pending`, does nothing; the parameter pointer is not reset then.
- `service_request = service_pending && service_ready` (:187), cleared at the edge it is taken (:224-225). `service_ready = !mapper_init_busy && arm_dma_ready` (cart2600.sv:428). The request is also masked to `mapper == BANKDPCP` (:657).

**Timeline** for a service write cycle starting at E0 [sim; [bb]]:

| Edge | Event |
|---|---|
| E0+6 | commit: `service_pending` ← 1 |
| E0+7 | DMA accepts; **`arm_dma_busy` ← 1**, so `arm_call_stall` ← 1 (top.sv:306-307). `service_pending` ← 0. |
| E0+7+0.6 | DMA_IDLE takes the command |
| … | fill: bytes from E0+7.8. Copy: DDR request at E0+7.8, first byte after D. |
| S(⌊kL/5⌋+3) | **`arm_dma_busy` ← 0** |

- Fill: busy falls at **E0+11+⌊(N−2)/4⌋** (N ≥ 2), or E0+10 (N ≤ 1, including a count clamped to 0).
- Copy at `lat` = 20: 20 bytes from an aligned source falls at E0+30. [added] Aligned source, N = 8m+g: E0+15+7m+q(g) (section 5.2).
- The 6507 effect follows the same release rule as a call (section 7.5). A fill of **N ≤ 53** bytes ends by E0+23 and does not delay the 6507 at all.
- [added] Fills whose fall lands in the first half of a held cycle, and so give the stale re-presentation of section 7.5: N = 54-77, 102-125, 150-173, 198-221, 246-255.
- Writes land at RAM 0x0C00 + counter upwards, at most 255 bytes; the destination clamp keeps them below 0x1C00.
- Source bytes come from the DDR3 shadow at image offset `source` (arm_mapper_memory.sv:779-780, 508-509), so a copy reads the downloaded image, never a RAM copy of it.
- [added] The DMA runs on during pause ([bb]: a fill of 53 started while paused fell at r+16, as unpaused). The 6507 is stopped, so a DMA that ends inside a pause costs it nothing.

## 7. The call path

### 7.1 Request side (clk_sys) [checked]

| Scheme | CALLFN | entry | stack | Thumb |
|---|---|---|---|---|
| DPC+ | write 0xFE/0xFF to `$1x5A` when `!call_pending` (mapper_dpcplus.sv:293-295) | 0x0000_0C08 | 0x4000_1FFC | 1 (:184-186) |
| CDF, CDFJ (rev 0-2) | write 0xFE/0xFF to `$1FF3` when `!call_pending` (mapper_cdf.sv:244-246) | 0x0000_0808 | 0x4000_1FFC | 1 (:160-162) |
| CDFJ+ (rev 3) | same | `cdfj_entry` (bit 0 cleared) | `cdfj_stack` | 1 |
| BUS | `$101A` (BUS1/2) or `$1FF3` (BUS3) (mapper_bus.sv:280-284) | 0x0000_0808 | 0x4000_1FFC | 1 (:170-172) |

- **Mux.** `arm_call_request` selects by `mapper` (DPCP, CDF, BUS, else 0). Entry, stack and Thumb default to the BUS values for other schemes (cart2600.sv:945-953).
- `call_request = call_pending && call_ready`, where `call_ready = mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy` (cart2600.sv:661-662; mapper_cdf.sv:159; mapper_dpcplus.sv:183).
- `arm_call_ready = arm_online_sync2 && shadow_ready_sync2 && !mapper_reset_sys && !call_busy` (arm_mapper_controller.sv:86-87). Here `arm_online` = `!reset_arm` and `shadow_ready` come through two `clk_sys` flops (:138-141).
- So a request and its acceptance are the same event. If ready is low at the commit, `call_pending` waits with **no stall** and the call launches later (open question 5: no path after the init, see 12). [bb]: a call made pending while another was busy launched at X+1.
- **Accept** at the edge where `call_request` (E0+7 in the normal case; [core] confirms E0+7). The controller captures entry, stack and Thumb plus the six audio words (`counter0-2`, `frequency0-2` as they stand in cycle (E0+6, E0+7)). It flips `call_toggle` and sets **`call_busy` ← 1** (arm_mapper_controller.sv:149-161). The front end clears `call_pending` (mapper_cdf.sv:179-180; mapper_dpcplus.sv:222-223).
- At the same edge, if `init_family ≥ 2` (BUS/CDF), audio copies `counter0-2` into `call_seed_counter` (`call_launch = arm_call_request`; arm_mapper_audio.sv:207-211; cart2600.sv:776). An audio tick sampled at E0+7 updates the counters after these copies, so both see the pre-tick values.

### 7.2 clk_arm side (arm_mapper_controller.sv:235-360)

[added] **Port constants and core latencies, measured [bb].** `arm7tdmi_pkg::STATE_FIQ_R8` = 17, `CPSR_T` = 0x20, `MODE_SYS` = 31, so index 16 is written 0x3F. The core's state port asserts `state_ready` in the **second** cycle of a request (`state_req` rising), then every cycle while `state_req` stays high. `cpu_halted` falls on the first `clk_arm` edge after `halt_req` falls, and the core presents its first fetch in that same cycle. After the sentinel fetch, `cpu_halted` rises **2** `clk_arm` later (details under Return). With `ce` low (pause), the state port, the halt handshake and execution all freeze.

- After `reset_arm`: `CTRL_WAIT_HALT` until `cpu_halted`, then `CTRL_IDLE` (:262, 279-282). [checked] [added] `mapper_reset_arm` also forces WAIT_HALT every cycle (:271-276), so after a console reset IDLE is reached at A(5R+3) or later, R being the edge where cart2600's `reset` falls, and only once the CPU is halted.
- **IDLE accepts** when all of these hold: `sys_online_sync2`, `shadow_ready` (clk_arm), `cpu_halted`, `complete_ack_sync2 == complete_toggle` (the previous completion acknowledged), and `call_sync2 != call_seen` (:284-305). That is A(5(E0+7)+3) = **E0+7.6** at the earliest. [checked; [bb]]
  - Accepting copies the payload, sets `call_ack_arm` and `write_index` = `state_index_q` = 0, and moves to `CTRL_WRITE_STATE`.
- **CTRL_WRITE_STATE**: `state_req` = `state_write` = 1 and `state_index = state_index_q` (:212-215). On each `state_ready`, the index steps. After index 22 → `CTRL_COMMIT` (:307-315). `state_index_q` also steps on that last write (the `else` at :311 covers only the `write_index` line), so it reads 23 in COMMIT; harmless. [checked] [corrected: with the real core this takes 24 clk_arm, not 23] The first cycle waits for `state_ready`; the 23 writes are then consumed on the next 23 edges [bb].

  | index | 0-12 | 13 | 14 | 15 | 16 | 17-19 | 20-22 |
  |---|---|---|---|---|---|---|---|
  | data (:219-232) | 0 | stack | 0xF000_0000 | entry | `(thumb ? CPSR_T : 0) \| MODE_SYS` | counter0-2 | frequency0-2 |

  Indices 0-16 are r0-r15 and the CPSR. Indices 17-22 are the registers read back from `STATE_FIQ_R8 + 0..5` (:328, 352-353). [corrected: no longer inferred] `STATE_FIQ_R8` = 17 [bb], and these are FIQ r8-r13 (`docs/DARIA_CORE.md` P1). FIQ r14 and the SVC, ABT, IRQ and UND banks are not written.
- **CTRL_COMMIT** (`state_commit` = 1) for one clk_arm, then **CTRL_RELEASE** for one, then **CTRL_RUNNING**. `halt_req` = 0 only in RUNNING (:211, 317-318). [checked] [corrected: E0+12.8 with the real core, not E0+12.6] With the accept at S(a): writes consumed at A(5a+5) … A(5a+27), **COMMIT at A(5a+27)**, RELEASE at A(5a+28), **RUNNING at A(5a+29)**, **`cpu_halted` falls at A(5a+30)**, and the first instruction fetch is presented in the following cycle and can be answered at A(5a+31) at the earliest (a held-line hit). For a = E0+7: COMMIT E0+12.4, RELEASE E0+12.6, RUNNING E0+12.8, halted falls E0+13.0 [bb]. The original [sim] stub gave RUNNING at E0+12.6.
- **Return.** `return_fetch` (combinational) is high in a cycle with `mem_req && bus_state == BUS_IDLE && !mapper_reset && mem_fetch && mem_addr == 0xF000_0000` (arm_mapper_memory.sv:557-558, 578, 633). [checked]
  - That cycle also answers `mem_ready` = 1, `mem_abort` = 0, `mem_rdata` = 0. No term of the read mux is enabled (:623-632).
  - RUNNING → `CTRL_RETURN_HALT` at that edge, A_ret (:320-323), and `halt_req` = 1 from it.
  - [added, answers open question 2] **What the core does after the sentinel [bb].** In the cycle after A_ret it presents one more sequential fetch: 0xF000_0004 in ARM state (`bx lr` lands in ARM state, since r14 = 0xF000_0000 has bit 0 clear) or 0xF000_0002 in Thumb state (`pop {pc}`). The memory answers that fetch at A_ret+1 with `mem_ready` = 1 and **`mem_abort` = 1** (`hit_none`, :604, 626). `cpu_halted` rises at **A_ret+2**. Neither the zero word nor the aborted word retires (no `retire` pulse). No exception is entered: no vector fetch follows, the CPSR read back after the call is still SYS (0x1F, or 0x3F after a Thumb return), PC reads 0xF000_0000, and the next call's first fetch is its entry. The ABT bank is never touched. All four test programs gave the same.
- **CTRL_RETURN_HALT** waits `cpu_halted`, then `CTRL_READ_AUDIO` with index `STATE_FIQ_R8` (:325-331): at **A_ret+3** [bb]. [checked]
- **READ_AUDIO / CAPTURE_AUDIO** repeat six times: READ waits `state_ready`, then CAPTURE takes `state_rdata` a cycle later, with `state_req` = 0 by then (:333-356). The values go to `audio_counter_result[0..2]`, then `audio_frequency_result[0..2]`. On the sixth capture, `complete_token` ← `active_token` and **`complete_toggle` flips**, at edge A_c, back to IDLE. [corrected: "at least 12 clk_arm after `cpu_halted`" → exactly 18 from READ_AUDIO] Each read costs 3 clk_arm with this core (a wait cycle, the `state_ready` cycle, CAPTURE). So **A_c = A_ret + 21** exactly [bb, every call of every test program]. The captured values are correct, since `state_rdata` holds in CAPTURE [bb: the returns equalled the launched values when the routine left FIQ r8-r13 alone].

### 7.3 Completion (clk_sys) [checked; [bb]]

At **X = S(⌊A_c/5⌋+3)**, 2.2-3.0 `clk_sys` after A_c (arm_mapper_controller.sv:163-177), if `call_busy`, `call_ack_sync2 == call_toggle` and `complete_token_sync2 == call_toggle`:

- the six `*_return` registers take their two-flop copies (written on or before A_c, so already settled);
- **`call_busy` ← 0**;
- **`call_done`** is high for one cycle (X, X+1);
- `complete_ack_sys` ← `complete_sync2`. [corrected: "about 0.4 clk_sys later"] `clk_arm` sees it in sync2 at X+0.4, so IDLE could accept from X+0.6; a new call's toggle cannot exist before X+1 (`call_ready` needs `!call_busy`), so the earliest next IDLE accept is X+1.6 [bb].

At **X+1**, audio merges for BUS/CDF only (arm_mapper_audio.sv:213-223): `counter_v` ← `return_v` if `return_v ≠ seed_v`, and all three frequencies ← their returns. These assignments come after a tick's add at the same edge, so they win over it. DPC+ (family 1) ignores the returns.

[added] **The merge depends on X.** Ticks keep adding to `counter_v` during the call. A counter the ARM changed is overwritten at X+1, discarding the ticks during the call, and the new frequencies apply from X+1. A clone whose call ends at a different X than upstream's therefore ends with different audio counters whenever an audio tick (about every 716 `clk_sys`, arm_mapper_audio.sv:57, 191-199) falls between the two X+1s. Per-tick audio equality across a call needs X to match, not just the 6507 timing.

[corrected: the stub numbers are replaced by the real core's] Real core [bb]: sentinel at A_ret → halted A_ret+2 → READ_AUDIO A_ret+3 → toggle A_c = A_ret+21 → **X = S(⌊(A_ret+21)/5⌋ + 3)**. (The original [sim] stub gave READ_AUDIO at A_ret+2 and the toggle at A_ret+14.)

[added] **Closed form for the whole call.** Let T = A_ret − A(5a+30), the number of `clk_arm` edges from `cpu_halted` falling to the sentinel fetch being answered (the driver's own run time; T = 4 for a warm `bx lr`: three halfword fetches, then the sentinel). Then **X = a + 13 + ⌊(T+1)/5⌋ = E0 + 20 + ⌊(T+1)/5⌋** for a = E0+7. [bb]: warm `bx lr` gives X = E0+21; the same call cold (first after load, I-cache miss, `lat` 20) gives T = 33, X = E0+26. The 6507 is not delayed at all when T ≤ 18.

### 7.4 Resets during a call [checked; [bb]]

- **clk_sys.** While `mapper_reset_sys`: `complete_seen` and `complete_ack_sys` follow `complete_sync2`, `call_busy` ← 0 with no `call_done`, and `call_ready` = 0 (arm_mapper_controller.sv:86-87, 144-147). [bb]: busy fell at Q+1.
- **clk_arm.** `mapper_reset_arm` (two flops, arm_mapper_subsystem.sv:104-115) forces these every cycle (:271-276):
  - `call_seen` = `call_ack_arm` = `call_sync2`;
  - `complete_toggle` = `complete_ack_sync2`;
  - `complete_token` = 0;
  - `CTRL_WAIT_HALT` (so `halt_req` = 1, which halts a running call). [bb]: WAIT_HALT at A(5Q+3).
  - The memory system goes back to `BUS_IDLE`, clears `fill_answer_held`, invalidates both caches and the fetch line (not the sample cache) and clears MAMCR and the timer. `req_phase` is blocked while reset (arm_mapper_memory.sv:557, 751-760, 937).
- An abandoned call's return is then ignored. Registers not in the 23 writes, and FIQ r8-r13, are not cleared.
- [added] **The CPU does not halt during the reset.** Its outstanding request cannot be answered while `req_phase` is blocked, so it halts only after the console reset falls, once that request is served ([bb]: the pending fetch became a cache miss after the release, then `cpu_halted` rose). In a real system the reset is held through the whole init, so the abandoned call's last access happens **after** the RAM image is rebuilt. If it is a store to RAM (0x4000_xxxx), that byte or word lands on the fresh image. DARIA resets its CPU instead (docs/DARIA_CORE.md:1113-1115); see G6.

### 7.5 Timeline: CALLFN commit to the 6507 resuming [checked; [core] confirms every 6507 and mapper row for X = E0+24 … E0+59]

The CALLFN write cycle W starts at E0. F is the next instruction's opcode fetch (E0+12 to E0+24); O is the cycle after it.

| clk_sys | Event | Source |
|---|---|---|
| E0+6 | front end commits: `call_pending` ← 1 | mapper_cdf.sv:244-246; mapper_dpcplus.sv:293-295 |
| E0+7 | controller accepts; **`arm_call_busy` = 1**, so `arm_call_stall` = `RDY` = 0 from here; payload and audio seeds captured | arm_mapper_controller.sv:149-161; top.sv:306-307, 328-329 |
| E0+7.2 / 7.4 | `call_sync1` / `call_sync2` | :264-265 |
| E0+7.6 | IDLE → WRITE_STATE | :284-305 |
| E0+8.0 … E0+12.4 | [corrected] one wait cycle, then state writes 0-22 consumed on 23 edges [bb] | :307-315 |
| E0+12 | F's phase 1: RDY sampled low, but F is the cycle after a write and cannot be held (`wr_q`) | mos6502_ctl.sv:874-881, 1387-1395 |
| E0+12.4 / 12.6 / 12.8 | [corrected: was "12.2 to 12.6 with an immediate state port"] COMMIT, RELEASE, RUNNING (`halt_req` 0) [bb] | :307-318 |
| E0+13.0 | [added] `cpu_halted` falls; first fetch presented in the next cycle [bb] | |
| E0+18 | **F's phase 2. F completes, and the mapper sees it**: `stall` = 1 but `stall_cycle_taken` = 0. `stall_cycle_taken` ← 1. | top.sv:320-327 [sim][core] |
| E0+24 | O's phase 1: RDY low, so O is held. The address bus keeps showing **F's address**, because the address load is gated by RDY. | mos6502_ctl.sv:874-876, 902-923, 958, 1398-1418 [sim][core] |
| E0+30, +42, … | held repeats; the mapper's phase 2 is **hidden** while `stall && stall_cycle_taken` | top.sv:327 [sim][core] |
| … | the ARM runs: T `clk_arm` from E0+13.0 to the sentinel (7.3) | |
| A_ret | sentinel fetch answered: RUNNING → RETURN_HALT; `halt_req` 1 | arm_mapper_memory.sv:633; controller :320-323 |
| A_ret + 0.2 | [added] one more sequential fetch, answered with abort, never executed [bb] | arm_mapper_memory.sv:604, 626 |
| A_ret + 0.4 | [corrected: H = 2 clk_arm] `cpu_halted` [bb] | |
| A_ret + 0.6 | READ_AUDIO [bb] | :325-331 |
| A_c = A_ret + 4.2 | [corrected: exact, was "≥ A_ret+H+12·0.2"] `complete_toggle` [bb] | :346-349 |
| **X = S(⌊A_c/5⌋+3)** | **`arm_call_busy` = 0**; returns latched; `call_done` in (X, X+1) | :163-177 |
| X+1 | audio merge (BUS/CDF) | arm_mapper_audio.sv:213-223 |
| **E″** = first `pclk1` edge > X | **the 6507 resumes**: RDY sampled high, O runs at its own address | [sim][core] |
| E″+6 | O's phase 2: data latched, seen by the mapper | [sim][core] |

**Release rule** [sim, all twelve phases swept; [core], 45 calls, X = E0+24 … E0+59, no mismatch]: let j ≥ 0 and X be the edge where busy falls.

- **X ≤ E0+23**: no delay. F at E0+18 and O at E0+30 run normally.
- **X ∈ [E0+24+12j, E0+29+12j]** (the first half of a held cycle, from its phase-1 edge): O completes at E0+42+12j. The held repeat at E0+30+12j is **shown to the mapper once more, with F's address** (stall = 0 by then while the CPU still holds). So the mapper sees F's address twice: at E0+18 and E0+30+12j.
- **X ∈ [E0+30+12j, E0+35+12j]**: O completes at E0+42+12j, and no repeat is shown.

**What a replacement must match:** [checked]

- `arm_call_busy`/`arm_dma_busy` may rise at **any edge in [E0+6, E0+17]** with identical 6507 and mapper behaviour [sim: E0+6 and upstream's E0+7 give the same bus]. A rise at E0+18 or later changes which phase 2 is "taken". [added] A rise at E0+5 or earlier is equally wrong: W's own phase 2 at E0+6 would then be the "taken" one and F would be hidden.
- Exactness still requires the audio payload and seeds to be the values as at E0+7, i.e. as they stand in cycle (E0+6, E0+7) (section 7.1).
- The stale second presentation of F's address is produced by top.sv itself (`mapper_phi2`), not by a front end. So a replacement whose busy falls at the same X reproduces it with no extra logic. [corrected: "idempotent in practice" is now bounded by the RTL] It repeats F, an **opcode fetch** at the same address with the same ROM byte. For the usual absolute-mode store (`STA $1FF3`, `STA $105A`), the last read before the write is the address high byte (`$1x`), which leaves `fast_pending` = 0 in both front ends (mapper_dpcplus.sv:251; mapper_cdf.sv:211). So F is a plain ROM fetch both times: CDF re-derives `fast_pending`/`fast_expected_address`/jump state from the same address and byte (mapper_cdf.sv:210-223), DPC+ re-derives `fast_pending` (mapper_dpcplus.sv:250-252), and a bank hotspot re-selects the same bank. The repeat changes state only if F's address is itself a DPC+ register read with a side effect: `$x000`/`$x001` (random step) or `$x008-$x01F` (counter or fraction step) (mapper_dpcplus.sv:113-125, 235-249). That needs code executing from the register window. Indexed or RMW stores to CALLFN, which could leave `fast_pending` set or write twice, are not covered by this argument (open question 6).

## 8. Stall plumbing in top.sv [checked]

- `arm_call_stall = tia_en && (arm_call_busy || (!mapper_init_busy && arm_dma_busy))` (top.sv:306-307).
- `RDY = maria_RDY && tia_RDY && (~tia_en || tia_RDY_seen_high) && !arm_call_stall` (:328-329). The 6507 reads RDY once per cycle, at phase 1 (mos6502_ctl.sv:874-881). A cycle right after a write is never held (`wr_q`, :876, 1394).
- `stall_cycle_taken` ← 0 when not stalling, else ← 1 on `pclk0` (:320-326). **`mapper_phi2 = pclk0 && (!arm_call_stall || !stall_cycle_taken)`** (:327). This is cart2600's `phi2` (:1135). [corrected: it does not gate the read strobe] It gates `arm_access`, and with it every front-end commit, and `access_taken` (cart2600.sv:255-261), which ends the cart-RAM write strobe. `cartram_rd` has no `phi2` term (cart2600.sv:975-976). TIA, RIOT and MARIA see `pclk0` itself.
- Pause: MARIA's clock enable stops (top.sv:445), and the TIA's with it (`tia_clk_x2`, top.sv:448, 490), so there are no phases. The ARM and its memory system stop (`ce`/`mem_ce = ~pause`, top.sv:816, 1187). The DMA engine, both controller FSMs and audio ticks have no pause input (arm_mapper_memory.sv:858-896; arm_mapper_controller.sv:235-360; arm_mapper_audio.sv:191-199). Port A is disabled and reads 0xFF (top.sv:921, 936). [corrected: the controller does not "keep going"]
  - The `clk_sys` half of the controller runs on, but has nothing to do while the 6507 is stopped.
  - The `clk_arm` half has no pause input, but every state except IDLE, COMMIT and RELEASE waits on the CPU (`state_ready`, `return_fetch`, `cpu_halted`), and the CPU is frozen. A call in flight therefore **freezes with the CPU** and finishes after unpause; `arm_call_busy` stays high meanwhile [bb: pauses during WRITE_STATE, during an I-cache miss and at RETURN_HALT each froze the call]. The memory system holds a completed cache fill for the frozen requester (`fill_answer_held`, arm_mapper_memory.sv:527-529, 1002-1005).
  - The DMA engine runs to completion during pause [bb].
  - [added] Audio refreshes during pause read sample **bytes** as 0xFF (`cartram_data` forced, top.sv:936) but pointer, size and NOTE **words** correctly (`cartram_word_data` is not forced and its address still registers). The AMPLITUDE computed during a pause is therefore garbage until the first refresh after unpause.

## 9. Writeback and the stream tables (CDF) [checked]

The tables are copies; cart RAM is authoritative (arm_mapper_tables.sv:4-5). They are kept coherent three ways:

- init loads (section 4.1);
- ARM and DMA writes snooped on port B (section 5.3);
- front-end updates.

**Front-end updates.** `pointer_update` is a one-cycle pulse in (E0+6, E0+7) after a DSWRITE/DSPTR write or a substituted read (mapper_cdf.sv:178, 195-203, 226-242). At E0+7:

- the sys port writes the pointer table (cart2600.sv:667-673, 687-691);
- the writeback latches `{table_pointer_base + index, value}` and flips its toggle, but only if idle: **a second write while one is in flight is dropped** (arm_mapper_writeback.sv:61-71).

On `clk_arm`: sync at E0+7.2/7.4, `active` at E0+7.6, and the write is accepted at **E0+7.8** with all four strobes. Writeback has top priority on port B. The ack comes back through two `clk_sys` flops, so **`mapper_wb_idle` is low from E0+7 to E0+9**: sampled low at E0+8 and E0+9, high from E0+10 (writeback.sv:40-41, 91-131) [sim].

The next 6507 commit is at E0+18 or later, so neither the drop nor the call gate (`mapper_wb_idle` in `mapper_call_ready`) can trigger in practice.

**Invariant for a replacement that keeps pointers only in RAM:** each front-end pointer write must be visible to the next front-end read (≥ E0+18) and to the ARM before a call starts. The ARM is halted outside calls, and a call starts only with the writeback idle.

## 10. cart2600's output contract for BANKDPCP and BANKCDF

Selection: `sel_* = *[mapper]` (cart2600.sv:187-192). Data-bus mux (:211-234): [checked]

```
if (is_bad_game)            d_out = bg_data,               oe = FF
else if (|sel_out_en):
    if (flags[0])           d_out = direct_do,             oe = sel_out_en
    else if (flags[1])      d_out = direct_do & rom_do,    oe = sel_out_en
    else if (ram_sel)
        if (ram_rw)         d_out = cartram_data (cr_do, :978), oe = sel_out_en
        else                (nothing: oe stays 00)
    else                    d_out = rom_do,                oe = sel_out_en
else                        d_out = 00, oe = 00
```

| Output | DPC+ (upstream) | CDF (upstream) |
|---|---|---|
| `out_en` | `a_in[12] ? FF : 00` (mapper_dpcplus.sv:129) | same (mapper_cdf.sv:132) |
| `flags_out` | bit 0 = `register_read` (register file `$000-$027` or fast-fetch operand); bit 1 never (:130, 160-161) | bit 0 = `stream_substitute` (:133, 140-141) |
| `direct_do` | [corrected: not "cartram_data itself" for every RAM function] by `register_address[5:3]` (:162-179): 0 → index 0 `random_next[7:0]`, 1 `random_prior[7:0]`, 2-4 `random_number` bytes 1-3, 5 AMPLITUDE, 6-7 zero; 1 (DFxDATA) and 3 (DFxFRACDATA) → `cartram_data`; 2 (DFxDATAW) → `cartram_data & window_flag`; 4 (DFxFLAG) → `window_flag` for index < 4, else 0 | `amplitude` or `cartram_data` (:142-147) |
| `rom_addr` | 3072 + bank·4096 + a[11:0] (:127-128) | (CDFJ+ ? 2048 : 4096) + bank·4096 + a[11:0] (:130-131) |
| `ram_sel` / `ram_rw` / `ram_a` | DFx data reads: 0xC00 + counter or fraction[19:8], read. DFxPUSH/DFxWRITE: write at counter−1 / counter (:137-158). | `ram_sel = cdf_ram_en`, `ram_rw = !cdf_ram_write`, `ram_a = {3'b0, cdf_ram_addr}` (cart2600.sv:896-898): a substituted read, or a DSWRITE in its access cycle only (mapper_cdf.sv:150-156) |

- **ROM address.** `rom_a = rom_addr[mapper]`, with **no** wrap mask for DPCP or CDF (cart2600.sv:195-197). It goes to `cart_2600_addr_out[18:0]`. `rom_read = ~address_change` (:157). [checked]
- **Cart-RAM strobes** (cart2600.sv:965-977): [checked]
  - `cartram_wr = !init_ram_en && ram_sel && !ram_rw && ~phi1 && ~address_change && ~access_taken`. `access_taken` is set on `phi2` and re-armed by `phi1`, `address_change` or reset (:255-261). So a write strobe runs from after the address settles to the access edge E0+6. [added] It is high for several `clk_sys`, so the same byte address is written on every edge from the cycle after `address_change` through E0+6; only the last write, at E0+6, carries the committed data for certain.
  - `cartram_rd = init_ram_en || audio_ram_grant || (ram_sel && ram_rw && ~phi1 && ~address_change)`.
  - `audio_ram_grant = audio_ram_en && !init_ram_en && !ram_sel`.
  - Write data = `d_in`.
- **`is_bad_game`.** Upstream: `BANKELF || (BANKBUS && rev 0)` (:165-166). Under `NO_ARM_MAPPER`: `BANKELF || BANKDPCP || BANKCDF || BANKBUS` (:162-163). [checked]
- **`NO_ARM_MAPPER` block** (:585-650). Every front-end, init, writeback, audio, DMA and call signal is tied idle: [checked]
  - `mapper_init_busy` = 0 (:592);
  - DPCP, CDF and BUS outputs = `bg_data`, `flags` 1, `out_en` FF, no RAM, `rom_addr` 0 (:630-650);
  - the subsystem's outputs are 0, `arm_call_busy` and `arm_dma_busy` included (:530-570); `mapper_wb_idle` = 1 and `load_wait` = 0 (:532, 601).
- **Mapper reset.** Front ends: `reset || mapper != BANKx` (:805, 843, 902). ARM subsystem, ram_init, writeback and audio: `reset` only, not a mapper change (:447, 710, 741, 751, 762). Tables have no reset. The fast-jump map is rebuilt on every download. [checked]

**What a replacement under `NO_ARM_MAPPER` must drive:** [checked]

- the five `BANKDPCP`/`BANKCDF` arrays with the semantics above;
- `arm_call_busy` and `arm_dma_busy` with the stall timing of sections 6-8;
- `mapper_init_busy` covering its own RAM-image build, for exactly upstream's duration (section 4.2), because it holds the wrapper reset;
- `is_bad_game` without DPCP and CDF.
- [added] **Routing of the busy.** The reset hold needs the wrapper's OR (atari7800_pocket.sv:169-171) and its `loading` (:905) to see the replacement's busy. docs/DARIA_CORE.md:1445 and 1528 say `cart2600`'s `mapper_init_busy` must stay 0 in the Pocket build, while :969 and :1111 have DARIA drive it. Inside top.sv the signal acts only while the console is held: the stall mask (:307), the cart-RAM mux (:752-759, which then selects the idle 2600 request), and the port enable (:921, not built under `EXTERNAL_CARTRAM`). So either route keeps the console identical; the docs should agree on one.

## 11. Guards

[corrected: re-judged against the user's rule "implement a guard if it costs little and does not make the core fall out of sync"]

| # | Upstream hazard | Guard | Cost | In step with upstream? | Verdict |
|---|---|---|---|---|---|
| G1 | The stale re-presentation of F's address when busy falls in the first half of a held cycle (section 7.5) | If busy would fall at an edge t with E′ ≤ t ≤ E′+5, where E′ is a `pclk1` edge at which `arm_call_stall` was sampled high and the previous cycle was not a write (so the CPU holds), make it fall at E′+6 instead. A fall exactly at E′+6 still hides that phase 2, because the stall is sampled before the edge. Apply it to the busy outputs only, not to `call_done`, the returns or the audio merge. | 2-3 flops | 6507 timing identical: O still completes at E′+18 [core: the 6507 rows are the same for X = E′ and X = E′+6]. Mapper: one duplicate commit fewer, idempotent under the conditions of 7.5. **Calls:** the clone's own X differs from upstream's anyway (different CPU), so its commit trace around a call cannot match upstream's whether or not G1 is applied. **DPC+ DMA:** the clone can reproduce upstream's X exactly (deterministic, section 5.2), and top.sv then reproduces the duplicate by itself. G1 there would drop a commit that upstream makes. | **Implement for `arm_call_busy` only.** Do not apply to `arm_dma_busy`; match upstream's DMA X instead. |
| G2 | Writeback drops a second update while one is in flight (writeback.sv:61-71) | Write RAM directly, or queue | none or tiny | Unreachable at 6507 rates (section 9). | **Implement** (free; nothing to diverge from). |
| G3 | CALLFN with call-ready low launches later without a stall (section 7.1) | Raise busy at the commit regardless of ready, and launch when ready | tiny | Unreachable after the init (open question 5). [added] Its only reachable trigger in upstream is `reset_arm` after a load, which loses the shadow for good; then upstream never launches and the 6507 runs on, while G3 would hang it. Both are broken states. | **Not needed.** Make the replacement's call port always ready after its own init; if it can be not ready, G3 is the safer choice. |
| G4 | A reset edge during an init is ignored, and a running DMA survives `mapper_reset` (sections 3, 4.3) | Restart the image build on any reset edge | tiny | [corrected] Unreachable: with the wrapper OR, cart2600's `reset` cannot rise again during an init (section 3, step 9). The image content is the same either way. | **Not needed.** Harmless if done, provided the busy duration of a normal init stays exactly upstream's. |
| G5 | DMA, controller and audio ticks run on through pause (section 8) | Gate them with `~pause` | tiny | [corrected] **Not in step.** Upstream's audio counters advance during pause, and a DMA in flight finishes during pause (the 6507 never sees its tail). A gated clone diverges after any pause in audio counters, and in 6507 timing if a DMA spans the pause start. The call itself already freezes with the CPU in upstream. | **Do not implement.** Reproduce upstream: DMA and audio run through pause, and the call freezes with the CPU. |
| G6 | [added] A console reset during a call leaves the CPU's outstanding request pending through the init; if it is a store, it lands on the rebuilt image (7.4) | Reset the CPU on the console reset (DARIA already does, docs/DARIA_CORE.md:1113-1115) | none | Diverges from upstream only when a console reset lands inside a call (microseconds per frame) and the access in flight is a RAM store. The clone's image is then the clean one. | **Implement** (DARIA's design). Note the deviation in the comparison's exceptions. |

## 12. Open questions, with what the RTL settles

1. **arm7tdmi latencies.** [answered by [bb], section 7.2] State port: `state_ready` in the second cycle of a request, then every cycle while held. Launch: RUNNING at accept + 29 `clk_arm`, `cpu_halted` falls at + 30, first fetch answerable at + 31. Return: `cpu_halted` at A_ret + 2, READ_AUDIO at A_ret + 3, toggle at A_ret + 21. Hence X = E0 + 20 + ⌊(T+1)/5⌋. `STATE_FIQ_R8` = 17, `CPSR_T` = 0x20, `MODE_SYS` = 31, printed from the package. The core source was not read; these are port-level observations of one build (`MUL_RETIRE_STAGE` 1, arm_host.sv:59).
2. **The zero word after the sentinel.** [answered by [bb], section 7.2] It is not executed. The core fetches one more word, which is answered with an abort and not executed either. No exception is entered (CPSR stays SYS, no vector fetch), so the ABT bank is never touched.
3. **MiSTer's own top level** (`Atari7800.sv`/`emu`) is not in this repository (src/fpga/mister/POCKET_CHANGES.md:16). [settled from a copy of the wrapper] The session scratchpad holds `upstream_wrapper/Atari7800.sv` (module `emu`, MIT, Jamie Blanks; copied there earlier in this session; its provenance against `UPSTREAM_COMMIT` was not re-checked). It is the same as the Pocket and tb_daria:
   - `reset <= RESET | buttons[1] | status[0] | cart_download | bios_download | status[48] | old_cart_download | mapper_init_busy | pll_busy | ~clock_locked`, a registered OR on `clk_sys` (:75-79), so the reset falls at busy fall + 1;
   - `.loading(cart_download || bios_download || mapper_init_busy)` (:528);
   - `mapper_load_start`/`mapper_load_end` from `old_cart_download` exactly as in tb_daria (:436, 585, 589);
   - `arm_reset = !clock_locked` (:592), and the real `DDRAM_BUSY` (:596).
   In top.sv itself the hold is absent (top.sv:255, 110); ram_init's header gives the intent, "before releasing the 6507 reset" (arm_mapper_ram_init.sv:4-5). [added] The wrapper reprograms the PLL on power-up and on every region change, which can follow the TIA's PAL detection when the region is on auto (:337, 386-425). That raises `pll_busy` and so a console reset, and the init re-runs. If the relock also drops `clock_locked`, `arm_reset` pulses and the shadow is lost (see 5). Whether it does is vendor-PLL behaviour that the wrapper itself flags as unchecked (:386-389).
4. Real DDR3 latency on MiSTer, and hence the DPC+ copy stall and init copy times. tb_daria fixes `lat` = 20 and `DDRAM_BUSY` = 0. Still open; section 5.2 gives the general D. A clone with on-chip image storage must emulate D to keep DPC+ copy stalls in step.
5. **Can `arm_call_ready` be low at a CALLFN after the init?** [settled: no reachable path in normal operation] Its terms (arm_mapper_controller.sv:86-87; cart2600.sv:661-662):
   - `arm_online_sync2` falls only with `reset_arm`.
   - `shadow_ready_sync2` falls only with `reset_arm` or `load_start` (arm_mapper_memory.sv:739-741); a download also holds the console reset.
   - `mapper_reset_sys` also resets the front end and clears `call_pending`.
   - `call_busy` cannot be high at a commit, because the 6507 is stalled until X, or not delayed at all when X ≤ E0+23.
   - `mapper_wb_idle` recovers by E0+10 after any pointer update (section 9).
   - `!mapper_init_busy` holds after the init.
   The one exception is `reset_arm` after a load (on MiSTer `!clock_locked`, `Atari7800.sv:592`; on the Pocket `~pll_locked`): it clears `shadow_ready`, and nothing sets it again until the next download. CALLFN then never launches, DPC+ services never run (`dma_ready` low), and the next console reset hangs in `INIT_DMA_FIRST` with the console held (arm_mapper_ram_init.sv:229-232).
6. **Does a game put F, the opcode after CALLFN or after a DPC+ copy/fill write, at a side-effecting address?** [narrowed, section 7.5] Only an opcode fetch from the DPC+ register window (`$x000`, `$x001`, `$x008-$x01F`) changes state on the repeat; hotspots re-select the same bank, and CDF cannot substitute F after an absolute-mode store. Still open: whether any title executes code there, or reaches CALLFN or a service write through an indexed or RMW store (which could leave `fast_pending` set from a dummy-read byte 0xA9). Settling it needs a scan of the titles' 6507 code, not the RTL.
7. **29,696-byte images detected as DPC+** (detect2600.sv:216). [facts settled; intent not] Every 6507 ROM address is ≤ 3072 + 5·4096 + 0xFFF = 0x6BFF, inside the image, so upstream treats such a file as the first 29 KiB of the 32 KiB layout (3 KiB driver first). The init's DMA 2 reads shadow words for image 0x6C00-0x7FFF; 0x7400-0x7FFF (the top 2 KiB of display data and the whole frequency table) were not written by this load and hold whatever DDR3 had: an earlier, larger image, or power-up contents. The service copy clamp (0x7400 relative to 3072) also allows sources up to image 0x7FFF. The clamp's 0x7400 is the size of a 32 KiB image after its 3 KiB driver, which suggests the 29 KiB format is "a 32 KiB image without the driver". If so, upstream misplaces every bank by 3 KiB for these files. Whether such files exist in the target set, and how the reference emulator places them, needs checking outside the RTL. A padded 32 KiB file avoids the question.
8. **RSYNC near a CALLFN.** [settled for the glue, section 0] RSYNC moves `pclk_div` (TIA.sv:565-567) and can add a phase-1 edge (TIA.sv:506, 528). The glue is keyed to the actual phase edges, so a replacement that keys on `pclk1`/`pclk0` events, as upstream does, stays exact. Only fixed `clk_sys` offsets break. Whether a title does it is a data question and does not matter if events are used.
9. BUS rev 3 has 18 increments at indices 0-17 of the increment RAM while the map starts at index 16 (arm_mapper_tables.sv:141, 153-155, 175-182), so increments 16-17 alias map entries 0-1. Out of DARIA's scope (no BUS), noted for completeness. [checked]
10. [added] **Pause.** Reproduce upstream, which costs nothing (G5): DMA and audio ticks run on, the call freezes with the CPU, and audio sample bytes read 0xFF during pause.
