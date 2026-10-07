# daria_fe: what DARIA's own design already fixes

This file lists what DARIA's design already decides for its 6507-side front end (`daria_fe`, step 6). It covers:

- the ports the front end must connect to, and their exact widths and semantics;
- the call protocol on the `clk_sys` side;
- the slot schedule and the datapath rules;
- what the never-simulated sizing sketch does and what it leaves out;
- the differences the design expects against upstream;
- the coding rules, the cart-RAM collision finding and the clocks;
- what is still open, with answers where the RTL settles them (section 10).

Upstream's behaviour scheme by scheme is in the sibling files (`dpcplus.md`, `cdf.md`, `audio.md`, `glue.md`). This file cites upstream only where DARIA's design depends on it.

Paths: `docs/` = `docs/`; `study/` = `sim/bupchip/daria/frontend_study/`; `core/` = `src/fpga/core/`; `bupchip/` = `src/fpga/core/bupchip/`; `rtl/` = `src/fpga/mister/rtl/` (upstream, MIT). "file:N" is a line, "file:N-M" a range. "DC" = `docs/DARIA_CORE.md`.

Tags used below:

- **[design]**: fixed by the design text.
- **[RTL]**: fixed by built and tested RTL (step 5).
- **[shadow]**: what `sim/bupchip/daria/daria_shadow.svh` does.
- **[derived]**: my reading of the cited lines. It is not stated in the design. Each one is listed again under "Open requirements" when it needs a decision.

Review tags (adversarial check against the RTL, line by line):

- **[checked]**: re-read against every cited line; correct as written.
- **[corrected: …]**: the claim was wrong or imprecise; the text now says what the RTL does, and the bracket says what changed.
- **[added]**: missing from the first version; added from the cited lines.

---

## 0. Edge and slot conventions

The conventions are the same as `glue.md` §0.

- **E0** is the `clk_sys` rising edge at which `pclk1` (the 6507 phase-1 enable, `cpu_ce = pclk1`, rtl/top.sv:335) is sampled high. The 6507 loads its address on E0, so `a_in` is valid from just after E0 for the whole cycle (study/README.md:137; DC:78). [checked]
  - [added] `pclk1`/`pclk0` are the paired enables `phi1_en = pclk1_raw & ~in_phase2`, `phi2_en = pclk0_raw & in_phase2` (rtl/top.sv:1420-1435); each is high for exactly one `clk_sys` clock.
- **E0+6** is the edge at which `pclk0` is sampled high. On it:
  - the 6507 latches read data (`dl <= data_in`, rtl/6502/mos6502_dp.sv:299; unconditional on every `phi2_en`, also in a held cycle, :267-299) [checked];
  - the mapper commits when `access` is high (study/README.md:138; DC:78, 1287) [checked].
  - `pclk1` → `pclk0` is 6 `clk_sys` in every run [sim] (DC:1385).
  - [corrected: the 6 holds for TIA-sourced phases only] In 2600 mode the TIA divider steps once per `tia_clk_x2` (every 2nd `clk_sys`, rtl/Maria/maria.sv:154; rtl/top.sv:490), with phase 2 at `pclk_div` 2 and phase 1 at 5 (rtl/TIA.sv:505-506, 556-557): 6 `clk_sys` per phase. Two things move it: an RSYNC (`pclk_div <= 2` at an `hclk` edge, rtl/TIA.sv:565-567, and the early phase 1 at `resp0 && pclk_div == 0`, :506), and the console reset, during which the phase source is MARIA (rtl/top.sv:256-260, 397-411), whose phases are 4 or 6 `clk_sys` long (`clock_div` 1 or 2 counts of `mclk1`, rtl/Maria/maria.sv:213-227). See section 10, doubts.
- **E0+12** is the next E0. A 6507 cycle is 12 `clk_sys` (DC:78; study/README.md:133). [checked; corrected: except the RSYNC, reset and pause cases above and in 1.1]
- **s_k** (slot k) is the `clk_sys` cycle between E0+k and E0+k+1. This matches the sketch's one-hot ring: `sl <= phi1 ? 16'h0001 : …`, so `sl[0]` is high in s0, the cycle after the edge that sampled `phi1` (study/daria_fe3.sv:50-51). The ring saturates at `sl[15]` if no `phi1` arrives (daria_fe3.sv:51). [checked]
  - [corrected: when the ring saturates] `phi1` keeps arriving during the console reset (MARIA is the phase source then and runs with `ce = ~pause || effective_reset`, rtl/top.sv:445, 256-260), every 8 or 12 `clk_sys`. So during F6 the ring restarts every 8 (or 12) clocks and never reaches `sl[8]` in an 8-clock cycle. It saturates only when the phases stop, which is during a pause (section 10, R11).
  - `pclk0` / `access` is high during s5. [checked]
  - `commit = sl[5] && access` therefore updates registers at E0+6 (daria_fe3.sv:401). [checked]
- **"Issue in s_k"** means an M10K address is presented during s_k and registered by the RAM at E0+k+1. The RAMs register the address and leave the output unregistered (bupchip/daria_mem.sv:71-77: `address_reg_b CLOCK1`, `outdata_reg_* UNREGISTERED`), so q is valid during s_{k+1}. This is the study's "issue at s_k, q at s_{k+1}" (study/README.md:357-365). [checked]

---

## 1. Clocks

### 1.1 The two clocks and their edges

| Clock | Source | NTSC | PAL | Cite |
|---|---|---|---|---|
| VCO | 74.25 MHz × (9 + K/2^32) | 687.27 MHz | 681.0 MHz (K retuned; every output scales) | core/pll/pll_core.v:19-23 [checked] |
| `clk_sys` | VCO ÷ 48 (C0) | 14.318182 MHz, 69.84 ns | 14.187580 MHz | pll_core.v:6, 19; DC:1133 [checked] |
| `clk_arm` (DARIA) | VCO ÷ 18 (C3) | 38.18 MHz, 26.19 ns | 37.83 MHz | DC:37 (decision 7), 1543, 1572 [checked] |
| `clk_arm` (as shipped today) | VCO ÷ 24 | 28.636 MHz = 2 × `clk_sys` | 28.375 MHz | pll_core.v:14-17, 70. [corrected: DC:1191 still says "regenerate with C3 = 21 or 17" (pre-step-3 text); ÷18 is decision 7, DC:37, 315, 1572] |

**Edge geometry at ÷48 / ÷18 [derived from the dividers].** [checked]

- The VCO period is 1.455 ns.
- lcm(48, 18) = 144 VCO periods = 3 `clk_sys` = 8 `clk_arm` = 209.5 ns.
- Within one 144-period frame:
  - `clk_sys` edges sit at 0, 48 and 96;
  - `clk_arm` edges sit at 0, 18, 36, 54, 72, 90, 108 and 126.
- So **one `clk_sys` edge in 3 coincides with one `clk_arm` edge in 8**. Every other `clk_sys` edge is at least 6 VCO periods (8.73 ns) from the nearest `clk_arm` edge. DC:446 states the same: "either coincide, once every 3 `clk_sys`, or lie at least 8.73 ns (6 VCO periods) apart".
  - [added] Gap from each `clk_arm` edge to the next `clk_sys` edge: 0 → 48 (shared at 0, then 69.8 ns), 18 → 30 VCO (43.7 ns), 36 → 12 (17.5 ns), 54 → 42 (61.1 ns), 72 → 24 (34.9 ns), 90 → 6 (8.73 ns), 108 → 36 (52.4 ns), 126 → 18 (26.2 ns). Section 9.3 uses this.
  - [added] "Coincide" is nominal: it assumes both C counters roll over on the same VCO cycle with 0 phase shift (pll_core.v:62-71) and ignores the skew between the two global clock networks. Nothing in the repository measures that skew.
- **Consequence for the front end:** 12 is a multiple of 3. While the 6507 runs at a steady 12 `clk_sys` per cycle, the shared edges fall on the same slot residue (k mod 3 = φ) in every 6507 cycle.
  - φ stays fixed until the 6507 phase moves. That happens at the reset release (rtl/top.sv:266-288), on a phase-source switch, or on an RSYNC (`glue.md` §0).
  - [added] It also moves on **every pause**: a pause stops MARIA's `mclk0` (`ce = ~pause || effective_reset`, rtl/top.sv:445; rtl/Maria/maria.sv:156-199), so `tia_clk_x2` (maria.sv:154) and with it the TIA's phase divider (rtl/TIA.sv:499-500, 556-557) stop for a number of `clk_sys` that is arbitrary mod 3.
  - This is [derived]. Nothing in the RTL measures φ today.

**Fallback ÷19 (36.17 MHz)** if step 7 cannot hold ÷18 (DC:323). gcd(48, 19) = 1, so: [checked]

- the tightest `clk_sys`/`clk_arm` edge pair becomes 1.455 ns, not 8.73 ns;
- edges coincide once every 19 `clk_sys` (= 48 `clk_arm`) [derived].

Any guard keyed to "one in 3 / one in 8" (section 9) would need to be redone at ÷19.

**The SDC treats the two clocks as related**, with exceptions on every crossing (DC:1166-1174): [checked]

- `set_max_delay 20` and `set_min_delay -20` from `clk_sys` to `clk_arm` and back;
- `clk_arm` ↔ `clk_sdram` is kept real as a tripwire.

[corrected: listed every crossing, both directions] The front end must therefore make **no crossing between its `clk_sys` logic and `clk_arm` logic** other than these:

- `daria_call_tog` (`clk_sys` → `clk_arm`, two flops inside `daria_call`, bupchip/daria_call.sv:97) and `daria_ret_tog` (`clk_arm` register → the front end's own two flops);
- the levels `daria_ready` and `daria_halted` (already through two `clk_sys` flops in the wrapper, bupchip_pocket.sv:371-377);
- the levels `daria_profile`, `daria_ram32` and `daria_mreset` (two `clk_arm` flops each in the wrapper, bupchip_pocket.sv:226-231); `daria_pal` stays on `clk_sys` (it feeds `daria_mmio`'s `clk_sys` side, :459);
- the dual-clock M10Ks (DC:1151-1162);
- if a shared-edge guard is built (section 9.3), its single phase-detector path, with its own tight constraint.

**Bench clocks.** `tb_daria` runs `clk_sys` at a 34,920 ps half-period and DARIA's `clk_arm` at a 13,095 ps half-period. The rising edges are 4.365 ns apart and never coincide (sim/bupchip/daria/tb_daria.sv:80; daria_shadow.svh:54-55; DC:446). The bench therefore never exercises the shared edge. [checked] [added] Upstream's own `clk_arm` in the bench is 5 × `clk_sys` with coincident rising edges (tb_daria.sv:77-81).

### 1.2 The 6507 side of the bus: stall, hidden phase 2s and RDY

- `arm_call_stall = tia_en && (arm_call_busy || (!mapper_init_busy && arm_dma_busy))` (rtl/top.sv:306-307). [checked]
- `RDY = … && !arm_call_stall` (top.sv:328-329), combinational from the two busy registers. [checked]
- **The mapper sees only the first phase 2 of a stall.** `stall_cycle_taken` is set at the first `pclk0` while stalled (top.sv:320-326), and `mapper_phi2 = pclk0 && (!arm_call_stall || !stall_cycle_taken)` (top.sv:327). The comment's diagram (top.sv:309-318) shows write $1FF3 taken, the first stalled fetch taken, the repeats hidden, and the operand after the release taken. [checked]
- **`access` = `mapper_phi2 && arm_driver_run`** (DC:1259). Here `arm_driver_run = lock_ctrl && tia_en` (top.sv:1136) and `arm_access = phi2 && arm_driver_run` (rtl/cart2600.sv:247), with cart2600's `phi2 = mapper_phi2` (top.sv:1135). [checked]
- **The 6507 reads RDY once, at the phase-1 edge (E0)**, and that reading stands for the whole cycle (rtl/6502/mos6502_ctl.sv:868-880: `rdy_q <= rdy` on `phi1_en`). It latches `dl` at every E0+6 regardless (mos6502_dp.sv:299). [checked]
- [added] **The cycle right after a write cannot be held.** `hold = ~rdy_cy & ~wr_q` (mos6502_ctl.sv:875-876), and `wr_q <= c.wr` on every `phi2_en` (:1392-1394; the netlist's `rdy <= READY | ~rw_n`, :855-866). So after the CALLFN write C0:
  - C1, the opcode fetch after it, is **not held**, although RDY is low at its E0. The CPU completes it, and the mapper takes it (`stall_cycle_taken` was cleared at C0's E0+6, while the stall was still low).
  - C2, the next read (for `LDA #`, its operand), is the cycle that is held, presented again every cycle, and hidden from the mapper until the release.
  - The top.sv comment's "fetch | fetch | … | operand" (top.sv:317-319) draws the fetch as repeated; the CPU model holds the operand instead. The mapper's sequence is the same either way: write, fetch, operand.
- [corrected: precise edges] **The release edge decides whether the held read is committed twice.** Let the busy register fall on edge E0+j of a held cycle (j = 0 is that cycle's own E0):
  - j = 6…11: the stall is still high during s5, so that cycle's E0+6 is hidden; RDY is high at the next E0; the read is taken once, at the next E0+6.
  - j = 0…5: RDY was low at E0 (the value during the clock before E0), so the CPU repeats the cycle; but the stall is low during s5, so `mapper_phi2` shows that E0+6. The same read is taken at two consecutive E0+6 edges. The CPU uses the second one's byte (`dl` latches every phase 2, mos6502_dp.sv:299).
  - For CDF's `LDA #` after CALLFN, the first commit substitutes and advances the stream and clears `fast_pending`; the second returns the ROM operand (the stream index). That is the failure top.sv:310-314 says `stall_cycle_taken` fixes; with RDY read at phase 1 it comes back whenever j = 0…5.
  - Upstream's release time (its `call_done`, rtl/arm_mapper_controller.sv:174-175) is unrelated to E0, so about half of upstream's releases (6 of 12 slots) fall in the double window [derived]. Section 10, R13.
  - [added] In both cases the CPU resumes on the same cycle (the next E0). Holding a release from s0–s5 back to the E0+6 edge therefore costs no 6507 cycle; it only removes the second commit.
- During a stall the 6507 keeps presenting the held address every cycle (study/README.md:142-143). The front end's slot machine keeps running. With `access` low its speculative reads are discarded. [checked]

---

## 2. The interfaces `daria_fe` must connect to

`daria_fe` lives in the Pocket wrapper beside the CPU's memories, not inside `cart2600` (DC:1251). The CPU side is built (`bupchip_pocket.sv` under `POCKET_DARIA`). The 6507 side (`top.sv`/`cart2600.sv` `POCKET_DARIA` blocks) is designed but not yet written: `top.sv` has no `POCKET_DARIA` block today, and `ap_core.qsf` does not set the macro (src/fpga/ap_core.qsf:736-754). [checked]

### 2.1 `bupchip_pocket` DARIA ports (built) [RTL]

All are in the `clk_sys` domain at the wrapper boundary, except `daria_ret_tog`, which is a `clk_arm` register (bupchip/bupchip_pocket.sv:164-188). [checked]

| Port | Dir (wrapper view) | Width | Meaning | Cite |
|---|---|---|---|---|
| `daria_profile` | in | 1 | A 2600 ARM cartridge. Static while the CPU runs. Enters `hold` (`hold = ~locked \| busy \| ~(souper_profile \| daria_profile)`, a `clk_sys` register) and reaches `clk_arm` through two flops as `prof26` | :167, 206-210, 224-232 [checked] |
| `daria_ram32` | in | 1 | Cart RAM is 32 KB (CDFJ+), else 8 KB. Two `clk_arm` flops, then `bup_cpu.ram32` | :168, 229, 312 [checked] |
| `daria_pal` | in | 1 | Region, for timer 1's rate (`daria_mmio.pal`, `clk_sys` side) | :169, 459 [checked] |
| `daria_mreset` | in | 1 | Mapper reset, a level. Two `clk_arm` flops (`mres_a`, power-up `2'b11`). In the 2600 profile it drops `pre_run`, so `cpu_run` falls one `clk_arm` later, the CPU is reset, and `daria_call` and `daria_mmio` are held | :170, 226-241, 365, 457-459 [checked] |
| `daria_call_tog` | in | 1 | A call is posted in the call block | :171, 365 [checked] |
| `daria_ret_tog` | out | 1 | `clk_arm` register (`daria_call.ret_tog`, power-up 0). Its return words are in the call block | :172, 365; bupchip/daria_call.sv:43, 114 [checked] |
| `daria_ready` | out | 1 | `parked & img_ready` through two `clk_sys` flops (power-up 0) | :173, 371-376 [checked] |
| `daria_halted` | out | 1 | `halted` through two `clk_sys` flops (only the flag: `halt_code` and `halt_pc` are not exported). `halted` clears on the CPU's reset (bup_cpu.sv:1369) | :174, 371-377 [checked] |
| `daria_stb_addr` | in | 8 | State RAM port B word address | :175 [checked] |
| `daria_stb_we` | in | 1 | State RAM port B write enable. **Writes are whole-word: port B's byte enable is tied to 4'hF** (bupchip/daria_mem.sv:202). There is no `stb_be` port | :176; daria_mem.sv:157-160, 200-202 [checked] |
| `daria_stb_wd` | in | 32 | State RAM port B write data | :177 [checked] |
| `daria_stb_q` | out | 32 | State RAM port B read data | :178 [checked] |
| `daria_crb_addr` | in | 13 | Cart RAM port B word address (8K words = 32 KB) | :179; daria_mem.sv:152 [checked] |
| `daria_crb_we` | in | 1 | | :180 |
| `daria_crb_be` | in | 4 | Byte lanes | :181 |
| `daria_crb_wd` | in | 32 | | :182 |
| `daria_crb_q` | out | 32 | | :183 |
| `daria_fea_addr` | in | 13 | Front-end ROM port A word address. [corrected: "ignored while the cartridge loads" was too broad] Ignored in each `clk_sys` clock in which `cap_we` is high (one clock per captured byte, inside the capture's cartridge window, file offset below 32 KB); in the clock after such a write, `fea_q` is the written word as port A's read-during-write returns it, not `fea_addr`'s word | :184; daria_mem.sv:148-149, 195; bupchip_pocket.sv:354 |
| `daria_fea_q` | out | 32 | | :185 |
| `daria_feb_addr` | in | 13 | Front-end ROM port B word address (read only) | :186; daria_mem.sv:150, 197 [checked] |
| `daria_feb_q` | out | 32 | | :187 |

**Not present** in the wrapper, though the design calls for them [RTL vs design]:

- **The digital-sample request and answer.** The design has a `clk_sys` request {offset, toggle} answered with a toggle (DC:881, 994, 1160, 1214, 1234). Neither `bup_asset_cache.sv` nor `bupchip_pocket.sv` has it. [corrected: `bupchip_pocket.sv` has one match for "sample", a comment at :599; neither file has a sample port or requester.] See R4.
- **The capture's cartridge-window signal.** The front end needs it to start F6 when the window closes (DC:967). `cap_cart_win` stays internal (bupchip_pocket.sv:250-255, 354). See R6. [checked]
- **A state RAM byte enable.** See R1. [checked]
- [added] **The front end's own inputs that no listed group carries**: the image size (`cart_size`, for the digital-audio route `digital_address < rom_size`, rtl/arm_mapper_audio.sv:336), `mapper_ram_size` (CDFJ+ sample masks and window, F6's fill length: arm_mapper_audio.sv:147-149, 281-288, 338-340; rtl/arm_mapper_ram_init.sv:171), and `pause` (R11). All exist at the Pocket level.

### 2.2 The RAMs behind those ports [RTL]

Every RAM is `daria_ram` (bupchip/daria_mem.sv:36-111): [checked]

- true dual port, `BIDIR_DUAL_PORT`, one clock per port, with byte enables;
- `maximum_depth` 8,192 (256 for the state RAM);
- address registered, output unregistered (:71-77). So: **one `clk_sys` from address to data**, with q following the address registered on the previous edge, and no output enable or read enable;
- **same-port read-during-write: `NEW_DATA_NO_NBE_READ`** (:81-82).
  - [derived from Intel's altsyncram semantics, not verified here] On the device, the lanes a write leaves disabled read as undefined in the clock after that write.
  - The simulation model (:99-107) returns the merged word, so simulation is more permissive than hardware.
  - **Rule:** never use a port's q from a cycle in which that port wrote with a partial byte enable, except on the enabled lanes.
- **Mixed-port reads of a word written in the same clock are undefined** on the device. "The users order such accesses by toggles" (:28-29).
  - [added] The simulation model never shows this race: both ports read `mem_q` with a blocking read and write it with a non-blocking one (:90-107), so a read on the same time step as the other port's write returns the old word, deterministically. A bench that wants to see the race must inject it.
- [added] **Power-up contents are zero**: `power_up_uninitialized ("FALSE")` (:79) on the device, `initial … mem_q[i] = '0` (:89) in simulation. Nothing clears the state RAM or the cart RAM afterwards except the users.

| RAM | Size | Port A | Port B (front end) | Cite |
|---|---|---|---|---|
| Front-end ROM | 8,192 × 32, the image's file offsets $0000–$7FFF | `clk_sys`. While `cap_we` is high it takes the cartridge byte at `cap_addr[14:2]`, lane `cap_addr[1:0]`; otherwise it reads `fea_addr` | `clk_sys`, read only (`we_b` = 0) | daria_mem.sv:193-197 [checked] |
| Cart RAM | 8,192 × 32, byte lanes | `clk_arm`: the CPU's `d_addr[14:2]`, `ram_we`, `ram_be` (it reads `d_addr` every clock, also while parked) | `clk_sys`: `crb_*` | daria_mem.sv:188-191 [checked] |
| State RAM | 256 × 32 | `clk_arm`: `daria_call` (`sta_*`), `be_a` = 4'hF | `clk_sys`: `stb_*`, `be_b` = 4'hF | daria_mem.sv:199-202 [checked] |

**Front-end ROM contents.** [checked]

- `cap_we = load_valid && cap_cart_win && load_addr[24:15] == 0`: every cartridge-slot byte below file offset 32 KB inside the capture's cartridge window (bupchip_pocket.sv:354).
- The window is open from `load_start` until 64 `clk_sys` after `load_end` (bupchip/bup_capture.sv:141-167). [corrected: exact count] `cart_win = load_start || c_open || c_drain > 1` (bup_capture.sv:150): the `load_end` edge loads `c_drain` with 64 (:160-162), the window stays open for the next 63 clocks, and `c_close` (`c_drain == 1`, :152) is the 64th clock after `load_end`'s, taking no byte.
- The ROM is not cleared between cartridges. Words past a shorter file keep the previous cartridge's data, "which the size checks make unreachable" (DC:960).

**What lies inside 32 KB.** Everything the 6507 side reads from the image is in $0000–$7FFF (DC:879): [checked]

- the banks: DPC+ $0C00 + 4K·n with n = 0–5; CDF $1000 + 4K·n with n = 0–6; CDFJ+ $0800 + 4K·n (study/README.md:209, 227);
- the DPC+ copy source, $0C00 + {p1,p0}, clamped below $8000 (rtl/mapper_dpcplus.sv:85-100: `$7400 − {p1,p0}` bytes from `$0C00 + {p1,p0}`) [checked];
- the F6 sources $6C00–$7FFF and $0000–$07FF;
- the CDF jump lookahead. Upstream's jump table never arms at $7FFE/$7FFF, so the lookahead never needs $8000 (DC:879, citing rtl/cdf_fastjump_table.sv:28-37).
  - [added] That table entries $7FFE and $7FFF are written 0 by file bytes 0 and 1 and are never set (cdf_fastjump_table.sv:34-38). DARIA reads X+1/X+2 from a 13-bit word address, which wraps $8000/$8001 to $0000/$0001. So `jump_ok` must be forced 0 for X ≥ $7FFE (CDF bank 6 is $7000–$7FFF; CDFJ+'s banks end at $77FF and cannot reach it).
- CDFJ+'s entry and stack come from `detect2600` and need no ROM read (DC:879).
- Digital-audio ROM samples are the exception. They may lie anywhere in up to 512 KB and come from the PSRAM (DC:881, 989; see R4).
  - [added] Only above 32 KB: a digital ROM sample is read only when `digital_address < rom_size` (arm_mapper_audio.sv:336), so for an image of 32 KB or less every ROM sample lies in the front-end ROM.

**Cart RAM.** [checked]

- Port B is the front end's for all its uses: stream pointers, increments and data, DPC+ display data, WRITE/PUSH/DSWRITE, the copy engine's destination, and audio samples (DC:874, 1272).
- CDF pointers and increments are read and written **in place**, where the Harmony driver keeps them. No shadow tables, snoop or writeback (DC:1272; study/README.md:343).
- The BupChip uses the low 16 KB of the same RAM in its own profile (DC:857; bupchip_pocket.sv:94-97).
- Every cartridge download zeroes all 32 KB through port B, by words on `clk_sys` (about 0.6 ms with the core held) (DC:902). This is [design] and not built: no zeroing path exists at the wrapper. [corrected: it is not needed for exactness; R7 has the reasons.]

### 2.3 The state RAM and the call block [RTL]

The front end owns every word except the call block 0xF0–0xFD (daria_call.sv:7-12, "the front ends own the rest of the RAM"). [checked]

| Word | Contents | Written by | Read by | Cite |
|---|---|---|---|---|
| 0xF0 | Entry, **bit 0 = T bit** (`{entry[31:1], T}`) | front end (port B), before `call_tog` | `daria_call` port A at the edge that sets `loading` (A3 below); `clr_pc` takes it at the next edge | daria_call.sv:9, 83, 104-105, 109-111; bup_cpu.sv:1431 (`late_pc <= {clr_pc[31:1], 1'b0}`) [corrected: the read edge] |
| 0xF1 | Stack (→ r13, entry 13) | front end | port A, during launch (read at A18) | daria_call.sv:10, 73 |
| 0xF2–0xF4 | Counter seeds, voices 0–2 (→ FIQ r8–r10, entries 16–18) | front end | port A, during launch (A21–A23) | daria_call.sv:11, 74 |
| 0xF5–0xF7 | Frequencies, voices 0–2 (→ FIQ r11–r13, entries 19–21). The design calls them "their live words" (DC:1095) | front end | port A, during launch (A24–A26) | daria_call.sv:12, 75 |
| 0xF8–0xFA | Return counters (FIQ r8–r10) | `daria_call` port A, during readout | front end, after `ret_tog` | daria_call.sv:9, 85-88 |
| 0xFB–0xFD | Return frequencies (FIQ r11–r13) | `daria_call` port A | front end, after `ret_tog` | daria_call.sv:9-12, 85-88 |
| 0x00 | (front end's) | — | Port A reads it, value unused: at `call_go` (`word_of(0)` = 0) and at every launch entry with no state word | daria_call.sv:76, 83-84 [checked] |

Port A's address while idle is 0xF0, so it reads 0xF0 every `clk_arm` and uses it only in the loading clock (daria_call.sv:83). Port A never writes outside 0xF8–0xFD (:85-88). [checked] Words 0xFE–0xFF are unused by `daria_call`. [added]

Values posted for each scheme, from upstream's front ends (the shadow posts upstream's own `active_*`; daria_shadow.svh:248-254): [checked]

- **DPC+:** entry $0C08, Thumb, SP $4000_1FFC, so F0 = 0x0000_0C09 (rtl/mapper_dpcplus.sv:183-186).
- **CDF and CDFJ:** entry $0808, Thumb, SP $4000_1FFC, so F0 = 0x0000_0809 (rtl/mapper_cdf.sv:159-162).
- **CDFJ+:** entry `cdfj_entry` (bit 0 already 0, rtl/detect2600.sv:200) with T = 1, and SP `cdfj_stack` (mapper_cdf.sv:160-161).
- **For every scheme**, F2–F4 are the voices' counters and F5–F7 their frequencies at launch, because upstream's controller loads them into FIQ r8–r13 whatever the family (rtl/arm_mapper_controller.sv:149-161, 220-230; DC:57 P1).
- [added] An entry with T = 0 and bit 1 set halts at launch (bup_cpu.sv:1073-1074), and so does one outside the code space (bup_cpu.sv:55-57). Every scheme posts T = 1.

**What the CPU does with the block.** The CPU never addresses the state RAM; `daria_call` does it for the CPU. [checked]

- **Launch.** `bup_cpu`'s `S_CLEAR` writes register-file entries 0–21, one per `clk_arm` (bup_cpu.sv:50-56):
  - entries 0–12 ← 0;
  - entry 13 ← F1;
  - entry 14 ← 0xF000_0000;
  - entry 15 ← 0;
  - entries 16–18 ← F2–F4;
  - entries 19–21 ← F5–F7.
  - `clr_wd` is the state RAM word read one clock ahead (`sta_addr = word_of(clr_e + 1)`, daria_call.sv:70-93).
  - In the last clock it loads the PC from F0, the control byte {I = 0, F = 0, T = F0[0], SYS} and NZCV = 0 (bup_cpu.sv:1393-1399; DC:1079, 1083-1090).
  - FIQ r14 and SVC r13/r14 are not written (DC:1090; P1, DC:57).
- **Return.** A jump whose fetch address is 0xF000_0000 sends the core to `S_READOUT` (bup_cpu.sv:57-62, 1300-1307).
  - `S_READOUT` puts FIQ r8–r13 on read port B, one per clock: `ro_valid`, `ro_idx` 0–5, `ro_data` (bup_cpu.sv:1466).
  - `daria_call` writes each to word 0xF8 + `ro_idx` in that clock (daria_call.sv:85-88).
  - `returned` is high with `ro_idx` = 5 (bup_cpu.sv:1465). `ret_tog` flips on the same `clk_arm` edge that writes 0xFD (daria_call.sv:114).
  - The front end sees the flip only after its two synchroniser flops, so all six words are in the RAM by then (daria_call.sv:25-27).

[added] **Launch and return, edge by edge** (from daria_call.sv:68-116 and bup_cpu.sv:1063-1078, 1300-1307, 1386-1399). A1 is the first `clk_arm` edge at which `tog_s[0]` takes the flipped `call_tog`:

| Edge | What happens |
|---|---|
| A1, A2 | `tog_s[0]`, then `tog_s[1]` take the new value; `pending` is true after A2 |
| A3 | if `parked && !launching && !loading`: `call_seen ← tog_s[1]`, `loading ← 1`. Port A registers 0xF0 on this same edge (the idle address), so **F0 is read at A3** |
| A4 | `clr_pc ← sta_q` (F0), `call_go ← 1`, `launching ← 1` |
| A5 | `bup_cpu` leaves S_IDLE for S_CLEAR (`launch ← 1`, `clr_idx ← 0`): **`parked` falls here**, so `daria_ready` falls 2 `clk_sys` later for the whole call |
| A5…A27 | 22 S_CLEAR clocks; the clock between A(5+e) and A(6+e) has `clr_e = e` and presents `word_of(e+1)`. So F1 is read at A18, F2–F4 at A21–A23, F5–F7 at A24–A26; entry e is written at A(6+e) |
| A27 | entry 21 written; `launch_end`: PC ← entry, control byte, NZCV; `state ← S_RUN`; `launching ← 0`. The driver's first instruction executes in the clock after A27 |

| Edge (return) | What happens |
|---|---|
| R0 | the sentinel jump's clock ends: `ret_v ← 1` |
| R1 | `state ← S_READOUT` |
| R2…R7 | 0xF8…0xFD written, one per edge |
| R7 | also `ret_tog` flips and `state ← S_IDLE`, so `parked` rises with it; `daria_ready` returns about when the front end sees `ret_tog` |

Consequences for the front end [derived]:

- Any call-block write may land on the same `clk_sys` edge as the `call_tog` flip, or earlier, never later: port A reads F0 at A3, at least two `clk_arm` periods after the flip (the shadow does exactly this with F7, section 3.2).
- **One call outstanding.** A second flip before the first is taken cancels it (`pending = tog_s[1] != call_seen`, daria_call.sv:68).
- **`daria_ready` is low during every call** (A5 to R7, plus two `clk_sys`). The shadow's `d_not_ready = !daria_ready` (daria_shadow.svh:116) therefore also skips posts while DARIA runs.

### 2.4 The 6507 side (designed, not built) [design]

These are the signals of the `POCKET_DARIA` port group in `top.sv` (DC:1254-1263): [checked]

| Signal | Direction (from `top.sv`) | Meaning |
|---|---|---|
| `a_in[12:0]`, `d_in[7:0]`, `rw` | out | The 6507 bus as `cart2600` sees it. `a_in = {AB[12] & bios_en_b, AB[11:0]}` (top.sv:1128); `d_in = cart_din = RW ? read_DB : write_DB` (top.sv:1112) |
| `phi1`, `access` | out | `pclk1` (E0), and `mapper_phi2 && arm_driver_run`. Commit only on that edge (F1) |
| `scheme`, `revision`, `cdf_ldx`, `cdf_ldy`, `cdf_fetch_offset*`, `cdfj_entry`, `cdfj_stack`, `arm_audio_size_addr` | out | `detect2600`'s results |
| `cart_reset` | out | Console reset or a new image: rebuild the RAM image (F6). [added] It must be cart2600's own reset, `effective_reset = reset \| reset_hold` (top.sv:255, 1130), so that the front end's reset falls on the same edge as upstream's mapper and audio resets (the tick phase, 3.5) |
| `fe_do[7:0]`, `fe_oe` | in | The byte the cartridge drives, and whether it drives (`$1xxx` reads) |
| `arm_call_busy`, `arm_dma_busy` | in | The 6507 stall: a call in flight, or a DPC+ copy/fill |

- **`detect2600`'s outputs already exist at the Pocket level** (core/atari7800_pocket.sv:292-319). [corrected: which file] `atari7800_pocket.sv:1045-1056` passes them to `top.sv`'s ports.
  - `force_bs` there is `|bs_override ? {1'b0, bs_override} : force_bs` (atari7800_pocket.sv:1047).
  - `top.sv`'s `mapper` input is 0 in the Pocket build (atari7800_pocket.sv:1060), so `cart2600` runs `force_bs` (top.sv:1138).
  - `mapper_ram_size` is 32 KB iff `force_bs == BANKCDF && mapper_revision == 3`, else 8 KB (top.sv:778-783).
  - Scheme codes: BANKDPCP = 21, BANKCDF = 23 (rtl/detect2600.sv:2-7). `mapper_revision` is 3 bits (:21). `arm_audio_size_addr` is 16 bits (:28). `cdf_fetch_offset` is 8 bits (:25).
  - [added] `force_bs`, `mapper_revision` and `sc` change only at `load_start` (cleared) and on the `load_end` edge (detect2600.sv:205-226); `cdf_ldx/ldy`, `cdf_fetch_offset*`, `cdfj_entry/stack` and `arm_audio_size_addr` are taken during the load (:140-201) and cleared at `load_start` (:117-138). `tia_mode` is set on the `load_end` edge too (atari7800_pocket.sv:260-263).
  - [added] Upstream's mapper blocks take `mapper_revision[1:0]` (cart2600.sv:764, 849); DPC+'s `stable_fractional` is `mapper_revision[0]` (:811).
- **`cart2600.sv` changes, only inside `POCKET_DARIA`** (DC:1253; DC:1242): [checked]
  - In the `NO_ARM_MAPPER` block, `BANKDPCP`'s and `BANKCDF`'s `direct_do`, `flags_out`, `out_en`, `rom_addr` and `ram_*` come from input ports instead of the idle constants (cart2600.sv:630-643: today `direct_do = bg_data`, `flags_out = 1`, `out_en = $FF`, `ram_sel = 0`).
  - `is_bad_game` drops `BANKDPCP` and `BANKCDF` and keeps `BANKELF` and `BANKBUS` (cart2600.sv:158-167).
  - `arm_dma_busy`, `arm_call_busy` and `mapper_init_busy` come from ports instead of 0 (cart2600.sv:535, 542, 592; DC:1111, 969). See R2 for the conflict on `mapper_init_busy`: [corrected: R2 now recommends leaving :592 at 0].
  - `flags_out[0]` = 1 selects `d_out = sel_direct_do`, `oe = sel_out_en` (cart2600.sv:210-221). So `fe_do` and `fe_oe` reach the bus through that branch.
  - [added] Upstream's DPC+ and CDF drive `oe = a_in[12] ? $FF : 0` (mapper_dpcplus.sv:129; mapper_cdf.sv:132) and set `flags_out[0]` only on substituted reads, taking plain ROM bytes from the SDRAM (`rom_do`). DARIA serves every byte itself, so `flags_out` = 1 always and `out_en = {8{fe_oe}}` with `fe_oe = a_in[12]` (the sketch's `drive`, daria_fe3.sv:396).
- **`ram_sel` must stay 0 for both schemes.** Otherwise their traffic reaches the SRAM through the 2600 port (Fix B risk 5, DC:1528; DC:1445). [checked]
- **The call request** (entry, stack, T) goes from `daria_fe` to the call port beside the CPU, not through `top.sv` (DC:1265). That path is the state RAM call block plus `daria_call_tog` (section 3). [checked]

---

## 3. The call protocol on the `clk_sys` side

### 3.1 As designed (DC:1093-1115) [design]

Each side touches the block only between the two toggles (DC:1095; daria_call.sv:14-16). [checked]

| Step | Domain | What |
|---|---|---|
| 1 | `clk_sys`, at the CALLFN commit (E0+6) | `call_busy` ← 1, so `arm_call_stall` holds the 6507 from the next cycle. Queue the 3 seed copies (counter → seed) after any NOTE or tick job in flight (DC:1099). [corrected: "holds from the next cycle"] RDY is low from the next cycle, but the CPU holds only the cycle after it (C2, section 1.2) |
| 2 | `clk_sys` | Once the seeds are written, the CPU is ready (`daria_ready`) and there is no mapper reset: flip `call_tog` (DC:1100) |
| 3 | `clk_arm` | `call_tog` through 2 flops gives `call_go`. `clr_wd` is a constant or state RAM port A's q, read at `clr_idx + 1` (DC:1101) |
| 4 | `clk_arm` | 22 clocks of writes, then the driver runs (DC:1102) |
| 5 | `clk_arm` | Sentinel fetch, then `S_READOUT`: `ro_data` → return words, then `ret_tog` flips (DC:1103) |
| 6 | `clk_sys` | `ret_tog` through 2 flops. CDF and CDFJ(+): counter_v ← return_v if return_v ≠ seed_v, and frequency_v ← return frequency_v. **DPC+ skips the merge**, as upstream does for family 1. Then `call_busy` ← 0 (DC:1104) |

- **Ticks keep running during the call** and update counter_v only, never the seed, frequency or return words (DC:1110). [checked]
- NOTE writes come from the stalled 6507, so the frequencies cannot change under the launch (DC:1110). [checked]
- The stall interface `top.sv:306-329` is unchanged (DC:1111). [checked]
- **Upstream's merge** (rtl/arm_mapper_audio.sv:207-223; the family encoding is DPC+ = 1, BUS = 2, CDF = 3, rtl/cart2600.sv:658-660): [checked]
  - at `call_launch`, `call_seed_counter[v] <= counter_v`, for family ≥ 2 only (:207-211);
  - at `call_done`, for family ≥ 2: `counter_v <= return_v` iff `return_v != seed_v`, and `frequency_v <= return_frequency_v` always (:213-223).
- **Upstream's call timing** [derived from the cited lines; `glue.md` has the measured version]:
  - `call_pending` is set at the CALLFN commit (E0+6) (mapper_cdf.sv:245-246; mapper_dpcplus.sv:294-295). [checked] It is set only if not already pending.
  - `call_request = call_pending && call_ready` is combinational (mapper_cdf.sv:159; mapper_dpcplus.sv:183). [checked]
  - The controller takes the payload and sets `call_busy` at the next edge, E0+7 (arm_mapper_controller.sv:149-161). [corrected: only if `call_ready` is high then] `call_ready = arm_online && shadow_ready && !mapper_reset && !call_busy` (arm_mapper_controller.sv:86-87), and cart2600 adds `mapper_wb_idle && !mapper_init_busy` (cart2600.sv:661-662). The writeback is busy for a few `clk_sys` after each pointer update (a toggle each way through two flops, rtl/arm_mapper_writeback.sv:40-41, 61-65); a CALLFN write comes at least one instruction after any stream operation, so the launch edge L is E0+7 in practice [derived], but the RTL fixes only L ≥ E0+7.
  - `call_launch` (= `arm_call_request`, cart2600.sv:776, 945) seeds the audio block on the same edge L. The seed is the counter **before** any tick add on L (arm_mapper_audio.sv:191-195, 207-210: a non-blocking read of the old value). [checked] The FIQ r8–r10 payload is latched from the same `counter_v` on the same edge (arm_mapper_controller.sv:153-155), so seed and payload are always equal.
  - DARIA's design raises `call_busy` one clock earlier, at E0+6. That is invisible to the 6507, which samples RDY at the next E0 (section 1.2) [derived]. [checked: `stall_cycle_taken` is cleared at that E0+6 because the stall was still low before the edge, top.sv:321-323, so C1's phase 2 is taken as on upstream.]
  - [added] **Upstream's return timing.** On one `clk_sys` edge D the controller latches the six return values, clears `call_busy` and sets `call_done` (arm_mapper_controller.sv:163-177); `call_done` is a one-clock pulse (:142). So `arm_call_busy` falls on D and the audio merge registers on D+1 (arm_mapper_audio.sv:213-223). The 6507's release edge is D; the merge edge M = D+1.

### 3.2 As step 5's shadow drives it (daria_shadow.svh:286-349) [shadow]

The shadow stands in for the front end. It is the only `clk_sys`-side implementation that exists, and it passes on 61,227 calls (DC:390-415). [checked]

1. **Detect a call.** Upstream's ARM starting a call flips `up_post` (clk_arm; :244-261). On `clk_sys` the shadow passes it through three flops and acts when `[2] != [1]` (:297, 301). [checked]
   - If DARIA is still busy with the previous compare (`d_done`) or **not ready** (`d_not_ready`: `!daria_ready` in the wrapper build, :116; the bench's reset otherwise, :204), the call is skipped and counted (:302).
   - Otherwise the shadow copies upstream's 32 KB cart RAM into DARIA's (:306). This is the bench's stand-in for a shared cart RAM.
2. **Post** (phase 1, :311-317): eight writes, one per `clk_sys`. `d_stb_we`, `d_stb_addr` = 0xF0 + k and `d_stb_wd` = `up_launch[k]` are registered, so the RAM writes word 0xF0 + k on the following edge. [checked]
   - `up_launch` = {entry[31:1] | T, stack, counter0–2, frequency0–2} (:248-254).
   - The last write (0xF7) lands on the same `clk_sys` edge on which phase 2 flips `d_call_tog` (:318-319).
   - This is safe because `daria_call` reads 0xF0 only after two `clk_arm` flops plus one clock (daria_call.sv:97, 109-111), and 0xF7 about 25 `clk_arm` later. [checked: F0 at A3, F7 at A26, section 2.3]
3. **Wait** (phase 3, :323): `ret_tog` through three flops; act when `[2] != [1]` (:298, 323). Then present address 0xF8. [checked]
4. **Read the return words** (phase 4, :328-337): one address per `clk_sys`, 0xF8 to 0xFD, each word taken in the following clock (`d_res[k-1] <= d_stb_q`). Six words take 7 `clk_sys` from the first address. [checked]
   - The shadow then compares (:345-348). It performs no merge: the merge is the front end's (step 6).
5. `daria.csv`'s `e2e_sys` column is `clk_sys` from the post to the last return word read: "what a front end waits, less its own share" (:28-30, 333). [checked]
6. [added] The shadow never raises `daria_mreset` or `pause` (daria_shadow.svh:82, 89), and the bench's `pause` is 0 (tb_daria.sv:192). Reset and pause paths of the protocol are untested.

### 3.3 `clk_arm`-side timing the front end waits on [RTL]

- **Launch.** [checked; section 2.3 has the edge table]
  1. `call_tog` → `tog_s[0]` → `tog_s[1]` (2 `clk_arm`, daria_call.sv:97). `pending` is `tog_s[1] != call_seen` (:68).
  2. If `parked && pending && !launching`, then `loading` (1 clock) (:109-111), then `call_go` and `clr_pc` ← 0xF0 (:104-108). [corrected: 0xF0 is read on the edge that sets `loading`, not during the loading clock]
  3. 22 clocks of `S_CLEAR` (entries 0–21) (:113; bup_cpu.sv:1063-1078), then the driver runs.
  4. A post seen while the core is not parked waits until it parks (daria_call.sv:21-23).
- **Return.** Sentinel jump → `S_READOUT` (bup_cpu.sv:1306-1307): 6 clocks of `ro_valid` → `returned` → `ret_tog` flips with the last write (daria_call.sv:114) → park (`S_IDLE`, bup_cpu.sv:1305). `parked` and `ret_tog` change on the same `clk_arm` edge, so `daria_ready` returns at about the time the front end sees `ret_tog`. [checked] [added] The two are synchronised separately and can resolve one `clk_sys` apart; nothing in the protocol depends on their order.
- **Latency estimates** (DC:1106-1109): [checked]
  - launch ≈ one 6507 cycle for the seeds + 3 + 22 `clk_arm`; [added] from the RTL, 26 `clk_arm` from A1 to the first driver instruction;
  - return ≈ 7 + 3 `clk_arm` + 3 `clk_sys` + the merge; [added] from the RTL, 7 `clk_arm` from the sentinel jump to the `ret_tog` flip, then the front end's 2 flops and 7 `clk_sys` to read six words;
  - about 2 µs more per call than upstream's controller, 0.1–0.5% of a budget.
  - Measured: a DARIA call takes about as long as upstream's (Mappy's first: 283 µs at 38.18 MHz against 293 µs at 71.6 MHz; DC:420).

### 3.4 Reset, readiness and halts [design + RTL]

- **Mapper reset** (cart2600's `reset`, the console reset): [checked]
  - It clears `call_busy` on `clk_sys` at once (DC:1113).
  - It reaches `clk_arm` as a level through 2 flops. That resets the CPU and sets both sides' "seen" registers to their synchronised toggles, so a return from an abandoned call is ignored (DC:1114).
  - The `clk_arm` side does this in `daria_call`: on `rst`, `call_seen <= tog_s[1]`, `loading`/`launching` are cleared, and `ret_tog` keeps its value (daria_call.sv:29-32, 99-102). [added] `ret_tog` does not flip on a `returned` that coincides with `rst` (the flip is in the `else` branch, :103-115), but that clock's `ro_valid` write still lands (`sta_we = ro_valid` is combinational, :85-88). The front end ignores return words it has not seen `ret_tog` for, so this is harmless.
  - **The front end must mirror it.** On mapper reset: `ret_seen` ← the synchronised `ret_tog`, and `call_busy` ← 0. `call_tog` keeps its value (daria_call.sv:30-32: "the front ends' side does the same with ret_tog").
  - DARIA's reset clears the banked registers where upstream keeps them (accepted, open item 13; DC:1115, 1659).
- **`daria_call.rst = ~cpu_run`** (bupchip_pocket.sv:365). `cpu_run` also falls for: [checked]
  - `hold`: PLL unlocked or busy (a PAL retune), or neither profile selected;
  - a new image's START (`img_ready` low);
  - in the 2600 profile, `daria_mreset` (bupchip_pocket.sv:233-241).
  - [added] And it rises only after the cache's tag sweep (`cpu_run <= pre_run & sweep_done`, :240-241; one clock per set after `pre_run` rises, bup_asset_cache.sv:85-87, 278-283). After the release the CPU clears 32 entries before it parks (bup_cpu.sv:1076-1078, 1359). So `daria_ready` returns about 2 + 128 + 1 + 32 `clk_arm` + 2 `clk_sys` ≈ 64 `clk_sys` (5.3 6507 cycles) after `daria_mreset` falls.
- [derived] **A toggle that arrives while `daria_call` is in `rst` is absorbed**: `call_seen` tracks `tog_s[1]` every reset clock (daria_call.sv:99-100). A post made while the CPU is held is therefore lost, and the 6507 would stay held for ever. So the front end must post only when `daria_ready` is high and no mapper reset is active, which is DC:1100's rule. [corrected: precise] Only a flip that reaches `tog_s[1]` while `rst` is high is absorbed; one made in the last two `clk_arm` of `rst` survives it and launches after the release.
  - The PAL retune and a new cartridge also reset the console: `atari7800_pocket.sv:169-171` puts `cart_download`, `pll_busy_s` and `~pll_locked` in the core reset, which clears the front end's `call_busy`. So no call is left waiting [derived]. [checked]
- **Halts during a call.** The call never returns and the 6507 stays held. A console reset recovers (DC:1047). `daria_halted` is for the status overlay (step 8). [checked]
- **Upstream differs before ready:** [checked]
  - upstream's `call_ready = arm_online && shadow_ready && !mapper_reset && !call_busy` (arm_mapper_controller.sv:86-87; plus `mapper_wb_idle && !mapper_init_busy`, cart2600.sv:661-662);
  - `arm_call_busy` rises only when the call is launched, so if not ready, upstream leaves the 6507 running with `call_pending` set;
  - DARIA's step 1 raises `call_busy` at the commit regardless.
  - This only matters if a call comes while not ready, which the F6 hold makes unlikely after a reset [derived] (R12). [corrected: "unlikely" → unreachable after a reset; R12 has the count.]

### 3.5 Exactness rules the design implies but does not state [derived]

These follow from upstream's register semantics (arm_mapper_audio.sv:191-223) if counters must match upstream tick for tick (DC:1309: "AMPLITUDE compared per tick"; this task's per-tick comparison). [checked]

- **Seed instant.** Upstream's seed (and FIQ r8–r10) is the counter after every tick add up to and including E0+6 of the CALLFN cycle, and before any add at E0+7 or later. The lean audio engine applies ticks as deferred voice jobs (study/README.md:399-408). It must therefore finish every tick that arrived before E0+7 before copying the seeds, and apply ticks that arrive from E0+7 on afterwards. [corrected: E0+7 is the launch edge L only when upstream is ready then, 3.1]
  - "After any NOTE or tick job in flight" (DC:1099) covers a running job. It does not cover a tick that is pending but not started.
  - The sketch gives the seed snapshot priority over pending ticks (`launch_p` before `ticks != 0`, daria_fe3.sv:644-647), which gets this wrong.
- **Merge instant.** Upstream applies a tick strictly before `call_done` with the old frequency to counter_v, and then the merge may overwrite it. On the `call_done` edge itself the merge wins for a changed counter, and an unchanged counter takes the tick's add with the **old** frequency (non-blocking: arm_mapper_audio.sv:193-195 then :213-222). Later ticks use the returned frequency. [corrected: "the `call_done` edge" is M = D+1, the edge after `arm_call_busy` falls, 3.1] So a changed counter loses every tick up to and including M; an unchanged one keeps them all.
  - The lean equivalent: pick one `clk_sys` edge as "done" (the edge on which the synchronised `ret_tog` is seen). Apply every tick that arrived before it, with the old frequencies, before the merge. Apply every later tick after the merge.
  - The sketch gives the merge priority over pending ticks (daria_fe3.sv:644-647).
- **DPC+:** no seed comparison and no merge (`family >= 2`, arm_mapper_audio.sv:207, 213). The return words are ignored. The posted F2–F7 are still the live counters and frequencies (they load FIQ r8–r13). [checked]
- **The tick accumulator is reset by the mapper reset** (`tick_accum <= 0`, arm_mapper_audio.sv:164; `reset` = cart2600's `reset`, cart2600.sv:761-762). So the tick phase restarts at every console reset. The sketch's accumulator has no reset (daria_fe3.sv:606-608). [checked]
  - [added] Exact arithmetic (arm_mapper_audio.sv:57, 76, 191-199): with R the last edge with `reset` high, the first add is on edge R+716 (`20000·715 ≥ 14,298,182`), leaving 1,818; then every 716 or 715 `clk_sys` (mean 715.909). The sketch's comparator and steps are the same (daria_fe3.sv:605-608).
  - [added] `CLK_RATE` stays 14,318,182 in PAL: cart2600 instantiates the audio block with no parameters (cart2600.sv:760), so upstream's PAL tick is 20,000 × 14.187580 / 14.318182 = 19,817.6 Hz. DARIA must keep the NTSC constant to match, not correct it.
- **Counters, frequencies and amplitude reset to 0** on the mapper reset (arm_mapper_audio.sv:163-189). The lean equivalent is the "state-RAM clear path" the sketch leaves out (study/README.md:447). [checked] [added] Also `refresh_pending`, `note_pending` ← 0, `waveform_shift` ← 27 (:165-182). The clear must finish while `cart_reset` is still high, which F6's hold gives (section 4).
- **Ticks run during pause.** Upstream's audio block has no enable (arm_mapper_audio.sv:11-13, 160-199; cart2600.sv:758-797 passes only `clk`/`reset`). Its RAM port is disabled on pause and the byte path reads $FF (top.sv:921, 936). See R11. [corrected: word reads are not masked] `cart_ram_tdp`'s word output `cartram_word_data_tdp` (top.sv:934, 1158) is not masked by `pause`, and its port A reads every clock; only the byte path is forced to $FF (top.sv:936) and the 2600 port's writes stop (`mapper_en = !pause`, top.sv:921). So during a pause the pointer, size and NOTE words read true data and the sample bytes read $FF.

---

## 4. The RAM image (F6) and the DPC+ service

- **Who does it** (DC:964-971): [checked]
  - The front end's copy engine on `clk_sys`, from the front-end ROM (port B) into cart RAM port B.
  - It starts when `bup_capture`'s cartridge window closes, 64 `clk_sys` after `load_end` (upstream starts at `load_end` delayed, cart2600.sv:710-716). [added] The delay is one clock: `load_end_d <= load_end` (cart2600.sv:572-577).
  - It runs again on every mapper reset. The CPU plays no part.
- **What it writes** (DC:970; study/README.md:163-165; the sketch's two steps, daria_fe3.sv:569-571, match upstream's two DMAs, rtl/arm_mapper_ram_init.sv:140-172): [checked]
  - DPC+ zeroes $0000–$0BFF and copies image $6C00–$7FFF to RAM $0C00–$1FFF.
  - CDF copies image $0000–$07FF and zeroes $0800 to `mapper_ram_size` − 1.
  - [added] `mapper_ram_size` is latched at `load_end` (`active_ram_size`, arm_mapper_ram_init.sv:217). Bytes from `mapper_ram_size` to 32 KB are never written by F6, and nothing can reach them (R7).
- **The console is held** through `mapper_init_busy`, which `atari7800_pocket.sv:169-171` already ORs into the core reset (DC:969). R2 covers how that signal is routed. [checked]
- **Upstream's trigger** [C, for exactness of the re-run]: `arm_mapper_ram_init` starts on `load_end` and on the **rising edge** of `mapper_reset` while an image is loaded (`image_loaded && mapper_reset && !old_mapper_reset`, arm_mapper_ram_init.sv:212-234). It is not itself held by that reset. [checked]
  - The Pocket reset includes `mapper_init_busy` (atari7800_pocket.sv:170), so the front end's own reset input stays high while it builds the image. The copy engine must start on that edge and not be cleared by the level it causes (R6).
  - [added] Detail: `old_mapper_reset` is a register (:205); the edge is acted on only in `INIT_IDLE` and only when neither `load_start` nor `load_end` is in that clock (:207-227); `image_loaded` is cleared at `load_start` and set at `load_end` when the family is not NONE (:207-214). The download's own reset rise therefore never triggers it. The block has no reset input at all (:6-39).
  - [added] **`busy` = `loading || state != INIT_IDLE`** (arm_mapper_ram_init.sv:75): upstream holds the console from `load_start`, through the load, into F6, with no gap. DARIA starts F6 64 clocks after `load_end`, and the Pocket reset otherwise falls 2 clocks after `load_end` (`cart_download | old_cart_download`, atari7800_pocket.sv:169-170). So DARIA's `init_busy` must be high from `load_end` at the latest (best from `load_start`, as upstream) until F6 ends. A gap lets the 6507 run on an unbuilt RAM for about 60 clocks, and the reset that follows is a second rising edge that triggers F6 again.
- **DPC+ copy/fill:** [checked]
  - The 6507 is held through `arm_dma_busy`. `arm_call_stall` masks it with `!mapper_init_busy` (top.sv:306-307).
  - The sketch's `dma_busy = cp_active && !init_busy` (daria_fe3.sv:530).
  - Its length differs from upstream's DDR3 DMA. That is visible only through scanline position (study/README.md:415; risk 2, :477).
  - Copy engine rate: one byte per two background slots. 8 KB at load takes about 1–3 ms with the console in reset; a 255-byte service about 100 6507 cycles (study/README.md:413-415). [corrected: the reset-time rate] During the console reset `phi1` still arrives from MARIA every 8 (or 12) `clk_sys` (section 0), so the sketch's `go = |sl[15:8] || sl[0]` (daria_fe3.sv:520) fires only at `sl[0]` in an 8-clock cycle: one byte per 16 `clk_sys`, so 8 KB takes about 9 ms and CDFJ+'s 32 KB about 37 ms. F6 should run on its own enable while `init_busy` (the ports have no other user then), and by words where source and destination are word-aligned (both of DPC+'s and CDF's are).
  - [added] **The service clamp is $8000, not $7C00.** Upstream: count = min(p3, $1000 − counter[f]) for fill; copy also min(…, $7400 − {p1,p0}), and 0 when {p1,p0} ≥ $7400 (mapper_dpcplus.sv:85-100). The source starts at image $0C00 + {p1,p0}, so it stops at $8000. study/README.md:414 and the sketch (`src == 17'h7C00`, daria_fe3.sv:535) stop 1 KB early; DC:879's "clamped below $8000" is right.
  - [added] The service parameters are latched at the CALLFUNCTION commit, from the params and `counter[p2]` at that time, and `parameter_pointer` resets (mapper_dpcplus.sv:278-292).

---

## 5. The slot schedule and the datapath rules

### 5.1 The schedule DARIA adopts (DC:1278-1292; the study's §3.2 with BUS removed) [checked]

Each 6507 cycle is 12 `clk_sys`, s0–s11 from E0. Every stage is a registered path, M10K output → logic → M10K address, so nothing touches the `clk_sdram` cone (DC:1278).

| s | Front-end ROM | Cart RAM (port B) | State RAM (port B) | Datapath, 6507 |
|---|---|---|---|---|
| 0 | Read the bank word at `a` | (audio) | | Address valid |
| 1 | The byte at `a`: decode fast fetch, fast jump, register | Read the stream pointer (CDF) | Read the fetcher word (DPC+) | `d_out` ← ROM byte, random byte or AMPLITUDE |
| 2 | Read the next word (jump lookahead) | Pointer in; read the data byte at `$800` + P[31:20] (CDFJ+: P[30:16]) | Fetcher in; read the byte at `$C00` + counter or fraction[19:8] | W ← the word; window flag |
| 3 | Lookahead in: `jump_ok` | Data byte in; read the increment | | `d_out` ← RAM byte (and the flag); W ± 1, fraction + increment, or W + 1<<20 |
| 4 | | Increment in: W ← W + I<<12 (CDFJ+: <<8) | | Data final, two clocks early |
| 5 | | | | **Edge E0+6, if `access`:** latch `d_in` and the operation; bank; mode; DSPTR shift-in. The 6507 latches `d_out` |
| 6 | | Write the pointer back | Write the fetcher back (or field bytes) | |
| 7 | | WRITE, PUSH or DSWRITE byte | DPC+ parameter byte | |
| 8–11 | Copy-engine source | Copy-engine destination; audio samples | Audio counter and frequency read-modify-write | Audio owns W from s8 to s1; a digital-sample request to the PSRAM |

- The busiest cycle, a CDF fast fetch, uses 6 of the 12 slots (DC:1292; study/README.md:367).
- The 6507 sees its data from s4, two clocks before it latches (study/README.md:369).
- The sketch's worst setup slack is +53.9 ns at 69.8 ns [sketch] (study/README.md:368).
- Port sharing (study risk 6, README:481):
  - Both block-RAM B ports serve the front end, audio and the copy engine.
  - Any other DARIA use must stay out of s1–s7, or be paused while the 6507 runs.
  - In the built wrapper the front end is the only `clk_sys` user of cart RAM port B, state RAM port B and front-end ROM port B.
  - Front-end ROM port A is shared with the capture, but only during a download (daria_mem.sv:195). [corrected: only in the clocks with `cap_we`, 2.1]
- With the ROM's two ports (DC:873), the lookahead can use port A while port B reads the bank word. DC:1271 lists "A and B, 32-bit reads" for the ROM. The sketch used one ROM port (daria_fe3.sv:123).
- [added] The data byte addresses wrap at 15 bits: CDFJ+ `(15'd2048 + P[30:16])` mod 32 KB, CDF `$800 + P[31:20]` ≤ $17FF (rtl/mapper_cdf.sv:126-128, 152-153). R5.
- [added] The slot table assumes `pclk0` in s5 and 12-clock cycles. During the console reset (MARIA-sourced phases, 8 or 12 clocks) and after an RSYNC this does not hold (section 0). `access` is 0 during the reset (the 6507 is held), so no commit is lost there; RSYNC is in the doubts.

### 5.2 Datapath and state placement (study §3.1, §3.3–§3.7; DC:1294) [checked]

- **One 32-bit word register W and one adder** (`sum = W + B`), shared by the schemes and the audio engine (study/README.md:373).
  - B is one of:
    - I[15:0]<<12 or I[15:0]<<8 (stream steps);
    - 1<<20 or 1<<16 (jump and write steps);
    - 1 or $FFF (12-bit counter ±1);
    - W[31:24] (fraction step);
    - `st_q`, `st_q`>>13 or `st_q`>>21 (audio) (:374-379).
  - W's next value is one of `ram_q`, `st_q`, `sum` or the DSPTR shift-in (:380).
- **DPC+ fetchers in the state RAM**, two words each, with fields on byte lanes (:340):
  - w0 = {bottom, top, 0:counter[11:8], counter[7:0]};
  - w1 = {increment, 0:fraction[19:16], fraction[15:0]}.
  - TOP, BOTTOM, LOW, HI, FRACLOW, FRACHI and FRACINC become pure byte-enable writes. Only DATA, DATAW, FRACDATA, PUSH and WRITE need a read-modify-write (:340).
  - **This depends on state-RAM byte enables, which the built port B does not have** (R1).
- **Field wrap rules** (:381-384):
  - After a counter operation only lanes 0–1 are written, and every reader uses bits [11:0].
  - After a fraction operation only lanes 0–2 are written, and readers use [19:0] and [19:8].
  - So a carry into a spare nibble is harmless, and HI and FRACHI rewrite that nibble anyway.
- **One window comparator** on the fetcher word just read, not eight (:385).
- **The bank base** is scheme base + 4K·bank, giving a 17-bit image address (:386). DARIA's ROM is 32 KB, so the word address is 13 bits.
- **DPC+ params** sit in one state RAM word, written on the byte lane at `ptr`; only lanes 0–3 matter (:341). **Random, waveforms, bank, flags and param pointer** stay in flip-flops, about 70 bits (:342).
- **CDF pointers, increments and data** are read and written in place in cart RAM (:343). **CDF fast-fetch and jump tracking and the mode** stay in flip-flops, about 60 bits (:344).
- **Audio counters, frequencies, seeds and returns** live in the state RAM (:345; DC:1273). The controller exchanges them on port A while the CPU is parked (DC:1276).
- **The fast-jump lookahead** is two extra ROM reads (X+1, X+2) in the `$4C` cycle, replacing the 4-M10K bitmap (:346). The lookahead uses the linear image, so a `$4C` at a bank end looks into the next bank (quirk 5, :329; DC:1296). [added] Except at X = $7FFE/$7FFF, where upstream never arms (2.2).
- **Audio engine** (:397-409):
  - One job per 6507 cycle, run in s8–s1 using W.
  - Voice job: s8 read c_v; s9 W ← c_v, read f_v and the pointer word; s10 W ← c + f, offset from the pointer; s11 write c_v, size word → shift; s0 read the sample; s1 accumulate.
  - Digital job, and note, seed and merge jobs, the last three being word copies.
  - A tick counter keeps ticks that arrive during a DPC+ copy.
  - **The 32 → 15-bit barrel shifter is kept for exactness** (:409; DC:1294).
- **Copy engine** (:411-416):
  - One byte per two background slots.
  - Clamp bounds are tested as the counters run (destination $1C00, source $7C00, count 0), which equals upstream's min() clamps. [corrected: the source bound is $8000; with $7C00 the clamp does not equal upstream's (section 4)]
  - It replaces `arm_mapper_ram_init`, the DPC+ service registers and upstream's DDR3 DMA and sample engines.
- **Calls** (:418-423): a pending flag; the controller loads FIQ r8–r13 from the state RAM; the audio engine performs the "changed since launch?" merge on `clk_sys`.

### 5.3 Upstream behaviours DARIA keeps (DC:1296; study §2.7, README:323-332) [checked]

- DPC+ fast fetch arms on data bytes, not only opcodes; its operand need not be at address + 1. CDF does require address + 1.
- DPC+ register numbers are 6 bits, so DFxFLAG is reachable through `LDA #$2x`, and DFxFLAG for fetchers 4–7 reads 0.
- Params 4–7 are stored and never read. The service clamps apply, and the service leaves the counter unchanged.
- Hotspots are ignored on substituted reads.
- The jump lookahead crosses bank ends. [added] It never arms at image $7FFE/$7FFF (cdf_fastjump_table.sv:34-38).
- BUS quirks (6, 7) are moot because BUS is left out (decision 6, DC:36).

---

## 6. The sizing sketch (`study/daria_fe3.sv`)

**Status:** "NOT functionally verified and not for the core; it exists only to be compiled for size" (daria_fe3.sv:1-3; study/README.md:3, 15). It compiles to 1,004 ALMs and 2 M10K [sketch] (README:446, 511; DC:1298). [checked]

### 6.1 What it implements [checked]

- **`daria_fe3` top** (:8-138):
  - the one-hot slot ring (:50-52);
  - the scheme decode (DPC+ / CDF / BUS, `jplus`) (:54-57);
  - a 256 × 32 state RAM with byte enables on port B and a "ctl" port A on the same clock (:59-68);
  - the shared W and adder, with a 10-way one-hot B mux and a 4-way W source mux (:70-96);
  - the port muxes: the core owns s1–s7 (`fe_owns = |sl[7:1]`), then the copy engine or audio (:52, 121-137). [added] The ROM port is the core's in s0 and s2 only (:123).
- **`fe3_core`** (:141-499):
  - bank and ROM address (:184-194);
  - CDF/BUS table bases as word addresses (:196-206);
  - the decode at s1 of DPC+ register reads and writes, CDF fast fetch, AMPLITUDE, jump, the DSWRITE/DSPTR/SETMODE/CALLFN writes, and BUS (:225-281);
  - the s1 loads (:283-289);
  - cart RAM addressing per slot (:291-319): the s6 word write and the s7 byte write (:314-319);
  - the DPC+ state RAM field byte enables (:321-341);
  - W control per slot (:343-356);
  - read data: the random LFSR next/prior, AMPLITUDE, the window flag, the jump lookahead from {next word, this word} (:358-398);
  - the commit at s5 & `access` (:400-498): bank hotspots (:409-415), pending tracking (:417-425), jump state (:434-448), DPC+ flip-flop registers (fast fetch, param pointer, service request, waveforms, random, notes; :450-486), mode and the call (`call_request = call_pending && call_ready`, :487-498).
- **`fe3_copy`** (:502-577): one byte per two background slots (`go = |sl[15:8] || sl[0]`), the service from the params word, the clamps tested as it runs (:535), and the two-step init from `load_end` (:538-541, 563-573).
- **`fe3_audio`** (:580-727):
  - Bresenham tick, `CLK_RATE` 14,318,182 and `AUDIO_RATE` 20,000 (:605-608);
  - a job chooser at s7 with priority launch-seed > merge > note > tick (:633-648); [added] it chooses nothing while `cp_active` (:636), and only when `sl[7]` occurs;
  - job datapaths for voice, digital, note, seed and merge (:667-706);
  - the barrel shift (:655), the sample address and CDFJ+ masking (:657), pointer validity (:659), and the AMPLITUDE sum and digital nibble (:708-726).
  - Its state RAM map ST_C 0x20, ST_F 0x24, ST_SEED 0x28, ST_RC 0x2C, ST_RF 0x30 (:651) predates the built call block at 0xF0.

### 6.2 What it leaves out: the study's §4 list (study/README.md:447) [study] [checked]

"Not in the sketch [E], +30 to +60 ALMs":

1. the call entry/stack select;
2. CDF's `$FF4`/`$FFB` bank cases; [added: the sketch's `bank <= a_in[2:0] − 5` (CDF) or `− 4` (CDFJ+) (daria_fe3.sv:415) gives 7 for CDF's $FF4 and 7 for CDFJ+'s $FFB, where upstream gives 6 and 0 (mapper_cdf.sv:186-191)]
3. the state-RAM clear path;
4. the BUS0 flag;
5. exact per-family waveform offsets;
6. re-initialisation on reset.

"Further savings [E], −100 to −200" (README:448):

- the copy engine on the shared datapath (−50 to −70);
- random in the state RAM (−15);
- a table-driven address decode in one M10K (−30 to −40);
- a single write-data path (−20 to −40);
- the barrel shift limited to ≥ 16 if no game needs less (−20).

"Expected 850–1,100" (README:449; DC:1298). The call controller is 100–150 [E] (README:450).

### 6.3 Where the sketch departs from what DARIA has since fixed [derived; my reading]

These are not in the study's list. Each one follows from the RTL and design built since. [checked]

| Sketch | DARIA as built or designed |
|---|---|
| BUS included (`is_bus`, stuffing, BUS3) | BUS left out, bad-game screen (decision 6, DC:36; DC:1249) |
| RAM address 12 bits (16 KB, `ram_addr[11:0]`), CDFJ+ data address `$800 + ram_q[29:16]` (14 bits) (:32, 297) | Cart RAM is 32 KB (decision 4, DC:34), port B 13 bits (daria_mem.sv:152). The study's 16 KB was its risk 5 (README:480). CDFJ+ addresses follow upstream with 32 KB: `(15'd2048 + P[30:16])`, wrapping at 15 bits (R5) |
| ROM port 15 bits (128 KB), one port (:30, 123) | Front-end ROM 32 KB, 13-bit word address, two ports (daria_mem.sv:148-151) |
| State RAM port A on the front end's own clock, `ctl_*` ports (:44-47, 64-68) | Port A on `clk_arm`, owned by `daria_call`; call block 0xF0–0xFD (daria_call.sv:7-12) |
| `call_request`/`call_ready`/`call_launch`/`call_done` abstract ports (:37-40) | `daria_call_tog` out / `daria_ret_tog` in, `daria_ready`, `daria_halted` (bupchip_pocket.sv:171-174) |
| `call_request` waits on `call_ready` (:498); no `arm_call_busy` output | `call_busy` at the commit, then post when ready (DC:1099-1100) |
| Seed and merge jobs ahead of pending ticks (:644-647) | Exactness needs arrival order (section 3.5) |
| Tick accumulator not reset (:606-608); `ticks` is 3 bits and wraps (:625) | Upstream resets the accumulator on mapper reset (arm_mapper_audio.sv:164) |
| Digital-mode ROM sample read through the front-end ROM port (`a_rom_addr = w[16:2]`, :671, 680-683) | ROM samples come from the PSRAM by a request to `clk_arm` (DC:881, 994). The requester is not built (R4) |
| Init starts at `load_end` (:538) | F6 starts when the capture window closes, 64 `clk_sys` after `load_end`, and on every mapper reset (DC:967-968) |
| State RAM byte enables used for the DPC+ fields and params (:336-341) | The built state RAM port B has none (daria_mem.sv:202) (R1) |
| [added] Copy source clamp at `src == 17'h7C00` (:535) | Upstream stops at $8000 (mapper_dpcplus.sv:85-100; section 4) |
| [added] Lookahead from `{next word, this word}` with no bound (:378, 390-394) | X ≥ $7FFE must not arm (cdf_fastjump_table.sv:34-38); DARIA's 13-bit word address would wrap |
| [added] CDF waveform offset only for pointers in $4000_0800–$4000_17FF (`ptr_ok`, :659, 712) for every revision | Upstream checks the window only for BUS and CDFJ+; CDF0/CDF1/CDFJ take `(p[11:0] − $800) mod 4K` for any pointer (arm_mapper_audio.sv:274-291) |
| [added] Digital mode runs the three voice jobs, then the digital job (:639) | Upstream's refresh in digital mode reads only voice 0's pointer word and the sample (arm_mapper_audio.sv:264-273, 335-347); the extra reads change nothing visible, but they are cart RAM reads during calls (section 9) |
| [added] Digital ROM bound `w[31:17] == 0 && w[16:0] < rom_size` (17 bits, :664) | Upstream compares the whole 32-bit address with the 32-bit `rom_size` (arm_mapper_audio.sv:336); images go to 512 KB |
| [added] F6 driven by `go = \|sl[15:8] \|\| sl[0]` (:520) | `phi1` runs during the reset (section 0), so F6 needs its own enable (section 4) |
| [added] `revision` is 2 bits (:12) | `mapper_revision` is 3 bits (detect2600.sv:21); upstream's mappers take `[1:0]` (cart2600.sv:764, 849) |

---

## 7. Differences the design expects (and counts)

Two differences against upstream are expected, and both are counted in verification, not hidden (DC:1296, 1309; open item 15, DC:1661). [checked]

### 7.1 AMPLITUDE may lag a tick [checked]

- **Upstream** updates AMPLITUDE a variable number of clocks after each tick. The delay depends on its RAM grant (`audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel`, cart2600.sv:965: the 6507's own RAM accesses come first) and on SRAM/DDR3 latency (digital ROM samples wait on DDR3, arm_mapper_audio.sv:355-361).
- **The lean engine** takes a fixed 1–4 6507 cycles.
- A 6507 read of AMPLITUDE inside that window sees the neighbouring tick's value (study risk 1, README:476).
- **How it is checked:** compare the per-tick amplitude sequence exactly. Accept an AMPLITUDE read that returns the previous tick's value, and count such reads (README:476; DC:1309).
- In full-system runs DARIA's and upstream's call lengths differ anyway, so audio phase cannot match (README:476).
- [derived] Upstream also coalesces ticks: `refresh_pending <= audio_tick` when a refresh starts (arm_mapper_audio.sv:229-233), so two ticks before a refresh give one refresh from the later counters. That can only happen if the audio machine is stalled for longer than a tick period (about 716 `clk_sys`). A per-tick comparison must define what it compares then (`audio.md`). [added] A NOTE job also goes first in `AUDIO_IDLE` (:227-228), and a refresh started on a tick's own edge snapshots the counters before that tick's add and stays pending for it (:229-233).

### 7.2 `open_bus` keeps the committed byte [checked]

- **Upstream's** `d_out` stays combinational after the commit. It shows the next fetcher byte, or the ROM operand once `fast_pending` clears (study/README.md:153).
- `top.sv` registers the whole bus into `open_bus` every `clk_sys` (`open_bus <= DB`, top.sv:350). Undriven lines of a later read take `open_bus` (top.sv:379-393). [added] What survives into the next cycle is DB during s11 (the last `open_bus` load before the next E0), so only `fe_do` in s11 matters.
- **The lean `d_out`** is a register that holds the committed byte.
- Only a partially driven TIA or RIOT read in the very next cycle could see the difference. "No instruction does that after a cartridge read (the next cycle is an opcode fetch)" (study risk 3, README:478; quirk 8, :332).
  - [corrected: one exception] An indexed access that crosses from page $1F to $20 (`LDA $1Fxx,X` or `(zp),Y` past $1FFF) makes a dummy read at $1Fyy, a cartridge read, and then reads $20yy, a TIA/RIOT mirror (`cs_tia`/`cs_riot` decode, top.sv:379-385), in the very next cycle. No traced game is known to do it [derived].
- **How it is checked:** at the latch edges. If needed, replay the read with the committed state in s8–s11 (README:478).

### 7.3 Also expected [checked]

- **Stall lengths differ** for calls and DPC+ copy/fill, so full-system 6507 traces drift. Do the exact comparison in shadow mode and compare full-system runs per frame (study risk 2, README:477; DC:1309).
- [added] **DARIA's CPU keeps running during a pause; upstream's ARM stops** (`arm_host .ce(~pause)`, top.sv:813-816; `bup_cpu` has no pause input, and the wrapper's `paused` gates only the BupChip's PCM pop, bupchip_pocket.sv:218, 485, 491). Timer 1 does stop on pause on both (`daria_mmio.run(~pause)`, bupchip_pocket.sv:459). So a call that spans a pause returns during it on DARIA. Only full-system timing sees it.

---

## 8. Coding rules (`MUX_RESTRUCTURE OFF`) [checked]

- The project sets `MUX_RESTRUCTURE OFF` globally (src/fpga/ap_core.qsf:299). The study's probes use the same settings, with physical synthesis on (study/README.md:14).
- Measured on the sketch (study/README.md:427-433):

  | Style | ALMs |
  |---|---|
  | Registers assigned in many FSM `case` arms | 1,343 |
  | The same, with mux restructuring on | 1,063 |
  | One load enable and a data mux of at most 4 inputs per register, one-hot slot ring, submodules | 1,018 |

- **Rules** (README:435; DC:1294, 1307):
  - give each register a single load enable;
  - give it a data mux of at most four inputs;
  - use one-hot slot enables;
  - write muxes as AND-OR.
- Measure each block as it is written, with these probes (study risk 8, README:483).
- Keep every stage registered (M10K q → logic → M10K address), and nothing on the `clk_sdram` cone (DC:1278).
  - Fix B's structural check, `report_timing -to_clock clk_sdram -through *cart2600*`, must find no path (DC:1499).
  - `fe_do` enters `cart2600`'s `d_out` mux combinationally (cart2600.sv:210-221), so `fe_do` must come from a register.
  - [added] For the same reason the front end's `init_busy` should not enter `top.sv`'s cart-RAM select: under Fix B `cartram_sel26 = mapper_init_busy | tia_en` gates the 7800 strobe that runs into `clk_sdram` (DC:1325-1331). R2.

---

## 9. The cart RAM collision finding (open item 7) and the guard question

### 9.1 What was measured (DC:444-447, 1653; daria_shadow.svh:33-38, 367-391) [checked]

- **Definition.** A collision is a console-side (`clk_sys`) read of a cart RAM word less than one `clk_sys` (69.84 ns) before or after a CPU write to the same word.
  - The bench counts against upstream's `cartram_rd` reads (audio and mapper; `dut.cartram_rd && !dut.cartram_wr && addr[17:15] == 0`, daria_shadow.svh:376-383) as a stand-in for the front end's.
  - It records writes from upstream's ARM (:384-387) and from DARIA (:388-391).
  - [corrected: what is counted] "Reads" are `clk_sys` edges at which the level `cartram_rd` is high (:376). A mapper read holds it for most of a 6507 cycle (`~phi1 & ~address_change`, cart2600.sv:975-976), so one 6507 read counts several times, and the held cycle's speculative reads during a call count too. Pairs are counted in both orders: read after write (:380-381) and write after read (:385, :389).
- **Result.** Over 21 images and 402 M console-side reads: upstream's ARM 167, DARIA 163, about one in 2.4 M. Ten images have none. The most is Mappy's 56 / 63 in 18.7 M reads (DC:444, 392-415).
- **The rate is the games', not DARIA's.** Both CPUs give it, image by image, against the same reads (DC:445).
- **The count is an upper bound** (DC:446):
  - A real race needs a shared `clk_arm`/`clk_sys` edge, once every 3 `clk_sys` (section 1.1).
  - A read on a shared edge with a write to its word races in the dual-clock M10K. One 8.73 ns or more away most likely does not, but timing analysis does not check it.
  - The bench offsets the clocks by 4.37 ns, so it never produces a shared edge.
- **Where it matters** (DC:901): during a call, the audio engine reads waveform bytes on port B while the CPU may write the same word on port A. The worst case is one glitched sample per collision. Upstream has the same race in other timing.
- [derived] **What console-side reads during a call actually use.** The 6507 is held, so the front end's speculative s1–s4 reads are discarded. The one taken phase 2 of the stall is the opcode fetch after the CALLFN write, a plain ROM read, because CALLFN's operand bytes are not `$A9`. So during a call only the audio engine's cart RAM reads have consequences: [checked; added: the opcode fetch C1 is not held (`wr_q`, section 1.2), and the held cycle C2 is committed only after the release, when the CPU is parked]
  - CDF: the voice pointer word, the size word and the sample byte;
  - DPC+: the waveform byte (arm_mapper_audio.sv:133-151).
  - The front end makes no cart RAM writes during a call (no 6507 writes; no copy/fill: a service holds the 6507 until done). So CPU reads on port A cannot meet front-end writes.
  - [added] Outside calls the CPU is parked (S_IDLE: no access, DC:1080) or in reset; its port A still reads `d_addr` every clock, but the value is unused.

### 9.2 Upstream's guard [checked]

`rtl/cart_ram_tdp.sv:29-54`:

- `clk_arm` is exactly 5 × `clk_sys`. A `clk_sys`-domain toggle passes through two `clk_arm` flops to derive a phase 0–4.
- `mapper_edge = arm_phase == 4` marks the one ARM edge in five that is also a `clk_sys` edge.
- `arm_allow = arm_en && !mapper_edge` gates the ARM port's accesses, reads and writes, and `arm_accepted` makes the ARM wait.
- It relies on the two clocks being STA-related, because it samples a `clk_sys` toggle directly on `clk_arm`.
- [added] `cart_ram_tdp` is 128 KiB (four byte lanes of 2^15, :66-84), addressed by the mapper with `mapper_addr[16:2]` (:74). R5 uses this.

### 9.3 The options step 6 must choose between (DC:447, 1653) [design]

- **(a) CPU-side guard:** "a W wait on cart RAM stores, one `clk_arm` edge in 8". This touches `bup_cpu`/`bupchip_pocket`: [checked]
  - today `w_wait` has a single source, the asset cache (DC:993; bupchip_pocket.sv:395-397);
  - stores to RAM take 1 clock (bup_cpu.sv:70-75).
  - [added] `w_wait` is consulted only for an asset load in W (bup_cpu.sv:1182). A one-clock store (immediate offset) is written from execute and never waits in W. So (a) is a new execute-stage stall in the verified core, on the store decision that was step 3's critical path (DC:1648), at a clock with +0.29 ns on its worst seed (DC:323). STM bursts write every clock and need the same stall.
- **(b) Accept** a race that touches one byte-lane read in millions. [checked]

[derived] What either guard needs:

- **A phase reference that is exact.** One `clk_arm` edge in 8 (or one `clk_sys` edge in 3) is shared. At ÷19 the pattern is 1 in 19 / 1 in 48. [checked]
- **SDC care.** The design's SDC bounds every `clk_sys` ↔ `clk_arm` path by `set_max_delay 20` / `set_min_delay -20` (DC:1166-1174). That does not guarantee which `clk_arm` edge first samples a `clk_sys` toggle when the next edge is 8.73 ns away (a 20 ns bound lets it land one edge later). Upstream's direct sampling therefore needs either a tighter constraint on that single detector path (`set_max_delay` below 8.73 ns, reg-to-reg) or a detector keyed only to the non-shared transitions with that tighter bound. [checked]
- **(a) on the CPU** changes only DARIA's clocks per call: one W wait on about 1/8 of RAM stores. Results stay identical to upstream: the shadow compares register values and the order of writes, not their times (daria_shadow.svh:394-429). [checked]
- **(a′) A front-end-side alternative** (not in the design): while `call_busy`, the audio engine issues its cart RAM reads only in slots whose issue edge is not shared. φ is fixed per run (section 1.1), so this means a slot-residue choice plus a φ detector in `clk_sys`. It leaves the verified CPU untouched, but needs audio-job slack in s8–s1. [checked; corrected: "fixed per run" → fixed between resets, phase-source switches, RSYNCs and pauses]
- The task's user note: "if implementing a guard has minimal cost and does not cause the core to fall out of sync, implement it". (a) and (a′) both keep results equal to upstream. Their cost is the phase detector, its constraint and 1–3 gates (R3).

[added] **A detector that works, and why ±20 ns is not enough** [derived from the edge geometry in 1.1]:

- Let a `clk_arm` flop `at` toggle on every `clk_arm` edge and a `clk_sys` flop `st` sample it. With the sample path held to arrive between about 1 ns and well under 8.73 ns after its launch edge (a reg-to-reg `set_max_delay`/`set_min_delay` pair on that one path; the more specific exception wins over the clock-level ±20 ns, and both values are tighter):
  - the `clk_sys` edge at 48 sees the toggles launched at 0, 18 and 36 (three);
  - the edge at 96 sees 54, 72 and 90 (three);
  - the shared edge at 144 sees 108 and 126 (two); the toggle launched at 144 itself is seen at the next 48.
  - So `st` changes on two `clk_sys` edges of every three and holds on the shared one. A 2-bit flywheel then predicts the shared edge every 3 clocks; the detector re-locks on its own after any phase move.
- Under the ±20 ns bound alone the toggles launched 17.5 ns before 48 (at 36) and 8.73 ns before 96 (at 90) may be captured one edge late, and the launch at 144 has no hold check against the edge at 144, so the parity pattern is not guaranteed.
- Cost: 1 `clk_arm` flop, about 4 `clk_sys` flops (sample, previous, flywheel), about 2 ALMs, and two SDC lines. Mark `st` as the receiving register, not as a synchroniser: its timing is met by the constraint.
- The CPU-side equivalent samples a `clk_sys` toggle on `clk_arm` with the same tight pair: the toggles from 0, 48 and 96 are seen at 18, 54 and 108 (gaps of 2, 3 and 3 `clk_arm`), and the shared edge is three `clk_arm` before the change that follows the gap of 2. That needs a mod-8 flywheel and the store stall in `bup_cpu`.
- **Neither can be checked in `tb_daria` as built**: its clocks never coincide (1.1) and the RAM model returns old data on a same-time-step read (2.2). Step 6 needs a `clk_arm` phase that coincides every 3 `clk_sys` and an X-injecting RAM model for coincident mixed-port reads.

---

## 10. Open requirements (what the RTL and design text do not settle)

Each row keeps the question as first written; the **Answer** column is [added] and says what the RTL settles and what remains a decision.

| # | Item | Why it is open | Answer (from the RTL) | Cite |
|---|---|---|---|---|
| R1 | **State RAM byte enables.** The study's DPC+ field layout and params word rely on byte-lane writes. Built port B is word-only (`be_b` 4'hF) and `bupchip_pocket` has no `daria_stb_be` | Either add `stb_be` (daria_mem.sv:202 and one wrapper port), or do every field write as a read-modify-write in the slot schedule (extra s-slots) | **Add `stb_be`.** It is four RTL lines: a `[3:0] stb_be` input in `daria_mem` beside `stb_we` (:158) and `.be_b(stb_be)` at :202; a `[3:0] daria_stb_be` port in `bupchip_pocket`'s `POCKET_DARIA` group (after :176) and its connection at :359. The shadow ties it to 4'hF (daria_shadow.svh:91, 189). Port B already has `width_byteena_b` 4 and `byteena_reg_b CLOCK1` (daria_mem.sv:68-74), so the M10K and the CPU side do not change and no ALM is added. A read-modify-write would need a byte merge mux on 32 bits and an extra read slot for the params word (the s1 read targets the fetcher word, daria_fe3.sv:336). Keep the NEW_DATA_NO_NBE_READ rule (2.2): after a partial write in s6/s7, port B's q in s7/s8 is undefined on the other lanes; the sketch's next use of `st_q` is s9 | study/README.md:340-341; daria_fe3.sv:336-341; daria_mem.sv:68-74, 157-160, 200-202; bupchip_pocket.sv:175-178, 359 |
| R2 | **`mapper_init_busy` routing.** The memory system and call port take it from the front end through `cart2600.sv:592` (DC:969, 1111). Fix B says DARIA must keep `cart2600`'s `mapper_init_busy` at 0 in the Pocket build (DC:1445, risk 5 at DC:1528). It feeds `top.sv`'s `cartram_sel26` (DC:1325) and the stall mask (top.sv:306-307) | Either drive the console hold from the front end straight into `atari7800_pocket.sv:169-171` and leave `cart2600`'s port at 0, or confirm that `ram_sel` = 0 makes the 2600 request idle (cart2600.sv:966-976: `cartram_wr`/`rd` need `sel_ram_sel` or `init_ram_en`, both 0) and update Fix B's rule | **Straight into `atari7800_pocket.sv:169-171`; leave cart2600.sv:592 at 0.** Both routes reach the same register (`reset <= … \| mapper_init_busy \| …`), so the reset timing is identical. The `cart2600` route would make three things live that Fix B folds as constants: `cartram_sel26` on the 7800 strobe into `clk_sdram` (DC:1325-1331), the stall mask (top.sv:307) and `.loading` (atari7800_pocket.sv:905: clears the 7800's RAM0/RAM1 and rewinds the AR tape, top.sv:417-434, 1220, none of which a 2600 ARM game sees). With the direct route: the front end must keep its own `arm_dma_busy` low while `init_busy` (as the sketch does, daria_fe3.sv:530); DC:969, 1111 and 1242 drop `mapper_init_busy` from cart2600's port list; Fix B's DC:1336, 1445 and 1528 stand as written. `ram_sel` = 0 does keep the 2600 request idle (cart2600.sv:599, 633, 640, 973-976), so the other route would also work, at the cost of a live input in the `clk_sdram` cone | as cited; atari7800_pocket.sv:169-171, 905, 1001 |
| R3 | **The open item 7 guard:** CPU-side W wait, front-end-side slot avoidance, or none; and its phase detector and SDC line | Section 9.3 | **Front-end side (a′), following the user's rule.** Cost: the detector of 9.3 (about 5 FF, 2 ALMs, one SDC pair) plus a one-slot defer in the audio job while `call_busy`, when the read's registering edge is shared (from C2 on the 6507 is held, so s2–s7 are free for audio then; C1 must still be served). Results stay exact: the merge, the calls and the per-tick values do not change; only the clock of an audio read moves, inside the AMPLITUDE lag that 7.1 already counts. (a) would change the verified CPU on its critical path (9.3). Both are ÷18-only; at ÷19 there is no exactly shared edge and the guard would have to avoid every edge closer than a chosen margin | DC:447, 1653; 9.3 |
| R4 | **Digital-audio ROM samples.** The PSRAM sample requester (`clk_sys` request {offset, toggle} ↔ `clk_arm` answer) is designed but not built: no port on the wrapper. Alternatives: serve offsets below 32 KB from the front-end ROM and route the rest to a new port. Do the traced images use digital mode? Not established here | | **Partly settled.** A ROM sample is read only when `digital_address < rom_size` (arm_mapper_audio.sv:336), so for any image of 32 KB or less every ROM sample lies in the front-end ROM: 18 of the 21 traced images are 32 KB (DC:66, 97). Only images above 32 KB (two 64 KB demos and Turbo, 128 KB) can need the PSRAM. Whether any traced image enables digital mode (SETMODE with mode[7:4] = 0, mapper_cdf.sv:80) is not recorded: no report under `sim/work` mentions it, and finding out needs a ROM run, which this review does not do | DC:66, 881, 994, 1160, 1214, 1234; arm_mapper_audio.sv:264-272, 335-361 |
| R5 | **CDFJ+ RAM addressing at 32 KB.** The sketch masks to 16 KB. The design's data byte is `$800` + P[30:16], which can exceed $7FFF. Follow upstream's `mapper_cdf` and audio masks (`(0x800 + idx) & (ram_size − 1)` for samples, arm_mapper_audio.sv:147-149) | | **Settled: wrap at 15 bits.** `display_address = 15'd2048 + table_pointer[30:16]` (mapper_cdf.sv:126-128), the same for DSWRITE (:150-156), reaches the RAM as `{3'b0, cdf_ram_addr}` (cart2600.sv:898) into a 128 KiB RAM (cart_ram_tdp.sv:66-84). So the byte address is ($800 + P[30:16]) mod $8000: a sum past $7FFF lands in $0000–$07FF. CDFJ+'s RAM is always 32 KB (top.sv:779-783), so the sample mask `& (mapper_ram_size − 1)` (arm_mapper_audio.sv:147-149) is the same 15-bit wrap; the waveform window is `[$4000_0800, $4000_0000 + ram_size)` (:281-288); digital RAM samples use `digital_address[14:0]` under `addr − $4000_0000 < ram_size` (:338-343). CDF/CDFJ: `$800 + P[31:20]` ≤ $17FF, no wrap. In DARIA: `crb_addr` = byte address [14:2], lane [1:0]; the 13-bit word address wraps the same way | daria_fe3.sv:297, 657; DC:1284; study risk 5 |
| R6 | **F6 start and re-run.** The front end needs "the capture window has closed" (64 `clk_sys` after `load_end`; not exported) and the rising edge of the mapper reset. Its own reset is held by the `mapper_init_busy` it raises (atari7800_pocket.sv:170) | | **Settled except the export.** (1) Export the close as one more `POCKET_DARIA` output (`cap_cart_win`'s fall, or `c_close`, bup_capture.sv:150-152), or count 64 `clk_sys` from the same `load_end` with the same rule; exporting avoids copying `DRAIN`. (2) Re-run as upstream: a registered previous `cart_reset`, the rising edge acted on only when idle and the image loaded (cleared at `load_start`, set when the profile is DARIA's at `load_end`+1), in a block that `cart_reset` does not clear (arm_mapper_ram_init.sv:205-227). (3) `init_busy` continuous from `load_end` at the latest (best `load_start`) to F6's end (section 4). (4) F6 also runs the state-RAM clear (3.5). (5) F6 needs its own enable, because `phi1` runs during the reset (section 4). (6) Step 6's shadow must OR the lean front end's `init_busy` into the bench's reset beside upstream's (tb_daria.sv:100), or the 6507 may start before the lean F6 ends | DC:967-968; bup_capture.sv:141-171; arm_mapper_ram_init.sv:75, 204-234 |
| R7 | **Zeroing all 32 KB of cart RAM on every download** (about 0.6 ms) has no owner in the built RTL | | **Not needed; drop it from DC:902/960 or give it to the copy engine at `load_start`.** F6 writes every byte any user can reach: DPC+ $0000–$1FFF and CDF $0000 to `mapper_ram_size` − 1 (arm_mapper_ram_init.sv:141-175); the CPU's RAM window is 8 KB unless `ram32` (DC:1036); the 6507-side and audio addresses stay inside `mapper_ram_size` (R5; $C00 + counter ≤ $1BFF, NOTE ≤ $1FFF). Upstream never clears either. The BupChip after a 2600 game does not depend on RAM contents (open item 8, settled: DC:432, 1654). If kept, run it during the download (console in reset, no other port B user), 8,192 word writes | DC:902, 960, 1654 |
| R8 | **Seed and merge ordering against pending ticks**, the reset of the tick phase, and the clear of counters, frequencies and AMPLITUDE on mapper reset | Section 3.5 | **Settled by upstream's registers.** Seed: every tick added on an edge ≤ E0+6 before the seed copy, every later one after (latch the pending-tick count at the commit, run that many voice jobs, then the seed job). Merge: at upstream's M = D+1, a changed counter takes the return and loses the tick on M; an unchanged one takes M's tick with the old frequency; earlier ticks use the old frequency, later ones the new. Tick phase: accumulator 0 while `cart_reset`, first add at R+716 (3.5). Clear on reset: counters, frequencies, seeds, AMPLITUDE, `note_pending`, `refresh_pending` (arm_mapper_audio.sv:163-189) | 3.5 |
| R9 | **Which `clk_sys` edge is "call done"** for the per-tick comparison in a shadow where upstream's ARM supplies the returns. The harness must hand the lean front end `ret_tog` at upstream's `call_done` to compare counters exactly | | **D+1**, where D is the edge on which upstream's `arm_call_busy` falls and `call_done` is set (arm_mapper_controller.sv:174-175; `call_done` is a one-clock pulse, :142; the merge registers on the next edge, arm_mapper_audio.sv:213-223). The release seen by the 6507 is D. The lean front end cannot reach D+1 through `ret_tog`, its two flops and a 7-clock state RAM read, so step 6's shadow needs a hook: upstream's six return values and a strobe at D+1 (`dut.cart2600.arm_call_done`) straight into the merge, with the stall from upstream's `arm_call_busy` | daria_shadow.svh:323-337; arm_mapper_controller.sv:142, 163-177 |
| R10 | **Live frequency words.** DC:1095 calls F5–F7 "their live words", so the launch reads them in place and the merge writes FB–FD → F5–F7. Confirm that, or keep them elsewhere and copy six words at launch | DC:1095, 1099 | **Live, as DC:1095 says.** DC:1110 ("NOTE writes come from the stalled 6507, so the frequencies cannot change under the launch") only holds if F5–F7 are the words the ticks read. `daria_call` only reads them, at A24–A26 (2.3), and the front end's tick jobs only read them during a call, so no write meets the launch. A DPC+ NOTE committed just before CALLFN must finish its write to F5–F7 before `call_tog` flips (DC:1099). The counters are not in the block: F2–F4 are copies (seeds), because ticks change the counters during the call | DC:1095, 1099, 1110 |
| R11 | **Pause.** Upstream's ticks run during pause, while its RAM port is disabled and returns $FF. The lean slot ring stops at s15 when no `phi1` arrives (does `pclk1` stop on pause?), and the sketch's 3-bit tick counter would wrap | | **Settled: `pclk1` stops on pause.** `pause` stops MARIA (`ce = ~pause \|\| effective_reset`, top.sv:445), so `mclk0` and `tia_clk_x2` stay low (maria.sv:154, 156-199) and the TIA's phase divider does not step (TIA.sv:499-500, 556-557). Upstream meanwhile: ticks and counter adds continue; word reads (pointer, size, NOTE) return true data and sample bytes $FF (3.5), so AMPLITUDE becomes $FD (3 × $FF, 8-bit) or nibble $F, and the first AMPLITUDE reads after the pause can see it until the next refresh; the ARM stops (7.3). To match: the lean ring must keep producing background slots while no `phi1` arrives (wrap s15 to s8 instead of saturating), and sample bytes must read $FF while `pause`. The front end needs `pause` (`pause_core`, clk_sys). The 3-bit counter wraps after 8 ticks (0.4 ms). Untested: the benches tie `pause` to 0 | arm_mapper_audio.sv:160-199; top.sv:445, 921, 934, 936; daria_fe3.sv:51, 625 |
| R12 | **A call while not ready.** DARIA holds the 6507 at the commit; upstream holds only when launched. Equal unless a CALLFN comes before `daria_ready` (after power-on or a reset the F6 hold should cover it) | | **Unreachable after a reset; keep DARIA's rule.** `daria_ready` returns about 64 `clk_sys` (5.3 6507 cycles) after `daria_mreset` falls (3.4), and `daria_mreset` falls with the 6507's own reset, after F6. The 6507 needs its 7-cycle reset sequence plus at least `LDA #` and `STA abs` (6 cycles) before a CALLFN commit. Other not-ready times (START, hold) reset the console as well (3.4). If it ever happened, DARIA would delay the call while holding the 6507, where upstream runs on with `call_pending`; results equal, timing not | DC:1099-1100; arm_mapper_controller.sv:86-87, 149-161; bupchip_pocket.sv:233-241 |
| R13 | **Double commit on release.** If `arm_call_busy` (or `arm_dma_busy`) falls between E0 and E0+6 of a held cycle, the held read is committed twice. Upstream has the same exposure at random times. Decide whether the front end releases freely (as upstream) or only in s6–s11 | top.sv:320-329; mos6502_ctl.sv:868-880 | **Confirmed; restrict the release.** Double when the busy register falls on E0+0…E0+5, single on E0+6…E0+11 (1.2). Clearing `call_busy` and `dma_busy` only with the enable `\|sl[10:5]` (so they fall on E0+6…E0+11) costs about one LUT and no 6507 cycle: the CPU resumes on the same E0 either way. It removes upstream's second commit (for CDF's `LDA #` after CALLFN, the ROM stream index in place of the stream byte), which happens in about half of upstream's releases. The shadow cannot see it (the stall there is upstream's), so record it as a counted difference beside open item 15 and give it a directed test | top.sv:310-329; mos6502_ctl.sv:868-880, 1392-1394; mos6502_dp.sv:299 |
| R14 | **÷19 fallback** changes the shared-edge pattern (section 1.1) for any guard | DC:323 | (unchanged) | DC:323 |
| R15 | **Open item 15**: AMPLITUDE lag and `open_bus` must be counted, not hidden, in step 6's shadow | DC:1661 | (unchanged; add R13's release guard and 7.2's page-crossing case to the counted list) | DC:1661 |
| R16 | **The `top.sv`/`cart2600.sv` `POCKET_DARIA` blocks**, the `is_bad_game` change and the wiring of `daria_profile` / `daria_mreset` / `daria_ram32` / `daria_pal` are not written. `daria_profile` should follow `force_bs ∈ {DPCP, CDF}` (top.sv:1138, 778-783) and settle 1–2 `clk_sys` after `load_end` | DC:956, 1242-1245, 1251-1265 | **The RTL fixes the four signals** (all `clk_sys`, at `atari7800_pocket.sv`): with `fbs = \|bs_override ? {1'b0, bs_override} : force_bs` (:1047): `daria_profile = tia_mode && (fbs == BANKDPCP \|\| fbs == BANKCDF)`, registered; the `tia_mode` term (:260-263) keeps it off for an A78 with a forced bankswitch, so it never overlaps `souper_profile` (top.sv:976). `daria_ram32 = fbs == BANKCDF && mapper_revision == 3` (= top's `mapper_ram_size == 32768`, top.sv:779-783). `daria_pal = region_select`, the signal that retunes the PLL (:1258; core_top.v:905, 1107-1117). `daria_mreset` = top's `effective_reset` (top.sv:255), which needs the `cart_reset` output of the `POCKET_DARIA` group. Both `force_bs` and `tia_mode` change on the `load_end` edge (2.4), so the profile is valid from `load_end`+1 | atari7800_pocket.sv:260-263, 1047, 1258; top.sv:255, 779-783, 976 |

### Doubts that remain (not settled by the RTL)

- [added] **Upstream's launch edge.** If upstream's `call_ready` is low at E0+7 (writeback not idle), its seed and FIQ r8–r10 are taken later and include any tick in between; DARIA's would not. Expected never in practice (3.1), not proven.
- [added] **RSYNC.** The slot schedule needs `pclk0` in s5. An RSYNC can move the TIA divider (TIA.sv:505-506, 565-567) and so shorten or lengthen a phase. Whether any ARM game writes RSYNC is not established. A front end that gates its commit with `sl[5]` would miss a commit that lands in another slot.
- [added] **Live `bs_override`.** `fbs` follows the menu at run time (atari7800_pocket.sv:1047), so changing it while a game runs moves `daria_profile` and `daria_ram32` while the CPU may be in a call, with no console reset; upstream's F6 family is latched at `load_end` (arm_mapper_ram_init.sv:215) while its mapper switches live. Whether the profile should be latched at `load_end` instead is a decision.
- [added] **Clock skew at the shared edge.** The guard and the collision analysis assume the two PLL outputs' rising edges coincide at the registers. Global-network skew is not in any report here.
- [added] **NEW_DATA_NO_NBE_READ** semantics (2.2) are from Intel's documentation, not verified on the device.
- [added] **`arm_audio_size_addr` beyond 32 KB.** It is a 16-bit RAM byte offset found by a scan (detect2600.sv:146-161); upstream's 128 KiB RAM would answer an address past 32 KB, DARIA's would wrap. No traced value is checked here.
- [added] **Does upstream show the R13 double commit?** The analysis is from the RTL; no trace has been checked for a CDF stream read that returned the ROM operand after a call.
