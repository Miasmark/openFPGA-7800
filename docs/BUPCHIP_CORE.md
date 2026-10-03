# BupChip core for the Pocket: design

This document describes the CPU that runs CoreTone on the Pocket, together with its memories, asset path and glue. It builds on `docs/BUPCHIP.md`, which covers what the firmware needs, and on a design study that compared three proposals. The study's scripts, cycle models and RTL sketch move into `sim/bupchip/` in step 1. The game data does not. The measurements used Rikki & Vikki's ARSC block, built locally with `sim/bupchip/make_arsc.py` and kept out of git (`.gitignore:10`, `sim/work*`).

Every number carries a tag that says where it comes from:

| Tag | Meaning |
|---|---|
| [RTL] | Measured in RTL simulation (Verilator 5.040) running the unmodified firmware |
| [sim] | Measured in a stand-alone simulation of one block (iverilog) |
| [model] | Measured with the trace-driven cycle model. The model runs on a Python ARM model whose PCM matches MiSTer's RTL bit for bit (187,984 frames of Misery_F). |
| [syn] | Yosys 0.69 `synth_intel_alm` cell counts, converted to ALMs as described under "Datapath blocks" |
| [rpt] | The 2.0.21 Quartus reports. `src/fpga/output_files/` is gitignored (`.gitignore:4`), and every compile rewrites it. The figures below were copied from the build of 2026-10-03 01:45; the cited report sections are kept in `sim/bupchip/baseline-2.0.21.txt`. |
| [C] | Read from the code |
| [E] | Estimate |

## Goals and budget

**Goals:**
1. **Unmodified firmware.** Run `bupchip.hex` (1,956 words) unchanged, with PCM output identical to MiSTer's.
2. **Throughput.** Sustain 16 MIPS of firmware work plus 25%, which is 20 MIPS.
   - The measured work on Misery_F is 15.14 MIPS on average and 15.58 MIPS in the busiest 0.1 s.
   - The worst 200-frame batch is equivalent to 17.43 MIPS.
   - The firmware's own ceiling of 16 looped voices is 17.74 MIPS [model].
3. **Clock.** Use the lowest practical clock, synchronous to `clk_sys`.
4. **Area.**
   - The whole BupChip must stay within 3,000–3,500 ALMs.
   - This design estimates 1,900–2,555 ALMs for S3, plus 40–70 with `BUP_DEBUG` [E]. That is 79.7–83.7% of the device.
   - Step 9 gates S3 at ≤ 84% ALMs, but the slack gates are the real criterion. S1 at 28.636 MHz (77.6–80.5%) is the fallback.
   - The worst register-file fallback is flip-flops, about +700 ALMs net of the MLABs they replace. It would put S3 at 83.6–87.3%, which breaks the gate and reaches the 85–90% zone where routing gets hard. So it is only an option together with S1. The area-safe fallback is the M10K register file (CPI 1.014).
5. **Build switch.** One macro (`POCKET_BUPCHIP`) switches the BupChip in or out.
6. **Licence.**
   - All new RTL is MIT.
   - The GPL-2.0-only `arm7tdmi_core.sv` (`THIRD_PARTY_NOTICES.md:31`) is used only as a simulation oracle, never as a source.

**Budget, 2.0.21 build [rpt]:**

| Resource | Used today | This design [E] |
|---|---|---|
| ALMs needed | 12,834 / 18,480, 69% (`ap_core.fit.rpt:4982`). Placement uses 14,101 (`:4984`), of which 1,328 are recoverable by dense packing (`:4989`). MLABs count here, as "[d] ALMs used for memory" (`:4988`). | S3: +1,900–2,555, or +1,940–2,625 with `BUP_DEBUG`, giving 79.7–83.7%. S1: +1,470–2,045, giving 77.4–80.5%. |
| LABs touched | 1,649 / 1,848, 89%. 199 are untouched (`fit.rpt:4998`). | S3: +194–263 LABs: 181–250 logic LABs at 10 ALMs each, plus 13 MLAB LABs. The high end exceeds the 199 untouched LABs, so the fit relies on the fitter packing existing logic more densely. |
| M10K | 46 / 308 (`fit.rpt:5024`) | +38, giving 84 |
| MLAB bits | 0 (`fit.rpt:5025`) | Register file (12 MLABs), command FIFO (1 MLAB) |
| DSP | 9 / 66 (`fit.rpt:5029`) | +3–4 |
| Global clocks | 5 / 16 (`fit.rpt:5033`) | +1 |
| `pll_core` counters | 3 (`pll_core.v:52`) | +1 |
| SRAM | Everything except words 0x1E000–0x1FFFF (`sram_ctrl.sv:9`) | Not used |
| PSRAM `cram0`/`cram1` | Tied off (`core_top.v:267-289`) | `cram0` die 0, assets only |
| Worst setup slack, slow 85 °C (`ap_core.sta.summary`) | `clk_sdram` +1.320 ns, `clk_74a` +2.868 ns, `clk_sys` +8.906 ns | No BupChip logic on `clk_sdram` |

**Why the SRAM's free 16 KiB is not used.** In 7800 mode the SRAM gets at most half an access slot per `clk_sys`, and it shares that slot with MARIA's cartridge reads (`sram_ctrl.sv:22-39`). The BupChip makes about 6.2 M data accesses a second. Block RAM is plentiful (262 blocks free).

**Note on `docs/BUPCHIP.md`.**
- The 2.0.21 resource figures are already there, at lines 177, 181–184 and 188–193 (commit `bf656d0`).
- What is stale is the measured-load table (lines 115–167).
  - The testbench decides "idle" from the last *fetched* address (`sim/bupchip/tb_bupchip.sv:95-97`), so it counts poll-loop branches as work.
  - The real figures are 15.14 / 15.58 MIPS, 13.5% B/BL and 9.4% conditional. The table says 15.7 / 16.0, 16.8% and 12.8%.
  - Line 138 lists RSC, which never appears in the firmware.
- Step 10 fixes all of these.

## Decision summary

### The three proposals

| | A: "min-freq" | B: "min-area" (BUP-S) | C: "reuse" |
|---|---|---|---|
| Pipeline | 2 stages, two register-file write ports, load data forwarded into execute, 1-clock MUL/MLA | 1 write port; loads and MUL take 2 clocks | Fetch/execute/memory with an instruction register; no forwarding |
| CPI on Misery_F | 1.013 [model] | **1.383 [RTL]** | 1.505 [model] |
| Clock | 21.477 MHz (1.5 × `clk_sys`) | 28.636 MHz (2 ×) | 42.955 MHz (3 ×) |
| Whole BupChip | 1,900–2,400 ALMs [syn→E] | 1,300–1,700 ALMs [syn→E] | 1,700–2,400 ALMs [E] |
| Evidence | Cycle model, plus a Yosys sketch that was never simulated | **RTL sketch running the real firmware:** register-exact for 85,258 instructions; PCM bit-exact for 4 s of Misery_F and 1 s each of songs 9, 14 and 30 | Cycle model |

All three proposals reject reusing `arm7tdmi_core.sv`, for three reasons:
- Stripped of everything the firmware does not use, it is still 7,584 LUTs + 1,129 arithmetic cells + 2,485 FF [syn].
- Even with zero-wait memory it runs at CPI 2.30 [model].
- It is GPL-2.0-only.

### Scores (0–10, higher is better)

| Criterion | A | B | C |
|---|---|---|---|
| Fits the area budget with routing margin | 7 | 9 | 7 |
| Clock frequency (lower is better; synchronous to `clk_sys` is a plus) | 9 | 7 | 4 |
| Correctness risk with unmodified firmware | 6 | 9 | 8 |
| Verification effort | 5 | 8 | 7 |
| Integration effort | 7 | 6 | 8 |
| **Total (of 50)** | **34** | **39** | **34** |

**A.**
- *Area:* 12 MLAB LABs and three read ports. Its flip-flop fallback (+800) fits the 3,000–3,500 ALM budget but not the step 9 ALM gate.
- *Clock:* the lowest, with about 45% estimated slack.
- *Correctness:* it carries the most hazard logic of the three: two write ports, forwarding into the DSP, a squash state, and a freeze from the W stage. Only a model backs any of it.
- *Verification:* the hazards need many directed tests.
- *Integration:* its 48 kHz NCO depends on the PLL divider and on K.

**B.**
- *Area:* the smallest, and measured from code that runs.
- *Clock:* 28.636 MHz leaves only 3.4% over 20 MIPS (2.5% in PAL). Real songs stay at or below 82% busy.
- *Correctness:* the best evidence. Its trimmed shifter carry, RRX and unaligned rotation are unused by the firmware, but they are silent differences that break a flag-exact lockstep.
- *Integration:* it drives both PSRAM chips in lockstep.

**C.**
- *Area:* similar to A, plus 50 M10K.
- *Clock:* the execute path is estimated at 15–20 ns against a 23.28 ns period on a C8 part (`ap_core.qsf:292,303`) at about 80% fill. That is the tightest of the three.
- *Correctness:* the simplest hazards, but no RTL exists yet.
- *Integration:* the easiest: stock FIFO depth and MIF, no watermark remap.

### Decision

**B wins and is the base.** It is the only proposal whose RTL already runs the unmodified firmware bit-exactly, and it is the smallest.

**The final core reaches A's timing rules in measured steps:**
- **S1** is B's core with exact flags, at 28.636 MHz.
- **S2** adds 1-clock loads.
- **S3** adds 1-clock MUL/MLA, giving CPI 1.013. With that, `clk_arm` drops to 21.477 MHz.

Every step is verified against the reference before the next. S1 at 28.636 MHz remains a shippable fallback at every step.

**Ideas grafted from the other proposals:**

| Idea | From | Where it goes |
|---|---|---|
| Working RTL base: fetch through the ROM's address register, next PC computed in execute, halt policy, MMIO access in W, firmware-in-the-loop testbench | B | S1 |
| Second register-file write port (live-value table over MLAB), load data forwarded into execute, third read port, 1-clock MUL/MLA | A | S2, S3 |
| `clk_arm` = VCO/32 = 1.5 × `clk_sys` | A | Final clock |
| 64 × 16 B M10K asset cache, critical halfword first, next-line prefetch, one PSRAM die | A (C similar) | Asset path |
| Partial-line rule: a load completes once the halfwords it touches have arrived | B (`bup_asset_v1.sv`) | Asset path |
| `asset_ready`: cleared when a download starts, set only if an ARSC block was captured, and published after the last PSRAM write, in order with the writes (as upstream's `end_toggle` does, `bupchip_asset_ddr.sv:137-146, 275-279`) | A, B, C; condition from C | Capture |
| PCM FIFO 1,024 frames with watermark remap; command FIFO 8 | A, B | FIFOs |
| 48 kHz pop tick from `clk_74a` | B, C | Clocking |
| MIT `arm7tdmi_pkg` functions verbatim; exact NZCV everywhere | C (A) | Shifter, ALU |
| One-clock-old write bypass, so the design does not depend on MLAB write timing | C | Register file |
| Stock `bupchip.mif` (4,096 words) | C | ROM |
| Clean-room rule; reference core only as an oracle; Quartus run of the CPU alone before integration; slack and ALM gates | C | Steps |
| Retire record carrying both write ports, for lockstep | A | Verification |
| Region decode from the base register | B | Held in reserve as a timing fix |

**Rejected:**

| Rejected | Reason |
|---|---|
| C's 42.955 MHz clock | Least slack, and no compute need for it |
| A's NCO pop | Pitch would depend on the divider and K |
| B's two-chip 32-bit PSRAM | Only needed with B's 2-line buffer |
| B's trimmed flags | Breaks lockstep |
| A's support for data-processing writes to PC | Unused; halts instead |
| A 2,048-deep ROM MIF | Saves 8 M10K, but adds a generated file to keep in step with upstream |

### Configurations

| | S1 (bring-up, fallback) | S3 (final) |
|---|---|---|
| CPI, Misery_F, 4 s | 1.383 [RTL] | 1.013 [model] |
| `clk_arm` NTSC / PAL | 28.636 / 28.375 MHz (VCO/24) | 21.477 / 21.281 MHz (VCO/32) |
| Capacity | 20.7 / 20.5 MIPS | 21.2 / 21.0 MIPS |
| Misery_F busy: average / busiest 0.1 s / worst batch | 73% / 75% / 82% [RTL] | 71.5% / 73.5% / 83% [model] |
| CPU / whole BupChip, MLAB LABs at 10 ALMs each (+40–70 with `BUP_DEBUG`) | 960–1,230 / 1,470–1,975 ALMs [E] | 1,390–1,810 / 1,900–2,555 ALMs [E] |

## Clocking

### `clk_arm`

`clk_arm` is a new output, counter[3], on `pll_core`. It is fed from the same VCO as `clk_sys` (C = 48) and `clk_sdram` (C = 12).

| Divider | NTSC | PAL | Relation to `clk_sys` | Worst setup relation to `clk_sys` / `clk_sdram` | Use |
|---|---|---|---|---|---|
| C = 24 | 28.636 MHz | 28.375 MHz | 2 ×, edge-aligned | 34.9 ns / 17.46 ns | S1 bring-up and fallback |
| C = 32 | 21.477 MHz | 21.281 MHz | 1.5 ×; edges coincide every 2 `clk_sys` | 23.3 ns / 5.82 ns | Final |

- **No path may join `clk_sdram` and `clk_arm`.** The BupChip's inputs all come from `clk_sys` registers.
  - `mapper_load_*`: `atari7800_pocket.sv:946-950`, registered into `clk_sys` at `core_top.v:684-698`.
  - `souper_profile` and the command.
  - `pause_core`, which `core_top.v:850` ties to 0.
  - `pll_locked` is the exception. It arrives raw and asynchronous (`core_top.v:819`; its only synchronised copy is on `clk_74a`, `:331`). The wrapper therefore adds two `clk_sys` flops (`pll_locked_s`), as `atari7800_pocket.sv:132-136` does for `pll_busy`.
- **Adding the counter.** Use the recipe at `DEVELOPING.md:245-271`, with `gui_number_of_clocks=4`, `gui_output_clock_frequency3` and `gui_divide_factor_c3`. That changes `number_of_clocks` (`pll_core.v:52`) and `output_clock_frequency3` (`:62`).
  - M, N and K are unchanged, so `pll_region.v`'s NTSC and PAL fractions stay valid (`DEVELOPING.md:280-285`).
  - Afterwards, check the clock names in the timing report's "Clocks" table (`DEVELOPING.md:336-343`).
- **SDC.** `core_constraints.sdc:13` already covers `counter[*]`, and the synchronous group is at `:16-20`. Only the header comment (`:3-11`) changes.
- **Regions.** A PAL retune scales every counter by 0.99088 and holds the core in reset across it (`pll_region.v:12-15`). The BupChip is held too; see "Reset and hold" below.

### Crossings

| Signal | Direction | Method |
|---|---|---|
| `$8007` command: one `clk_sys` pulse from `cart.sv:875-895`, exported as `bup_cmd_*_eff` (`top.sv:948-956`) | `clk_sys` → `clk_arm` | Byte held, plus a toggle; change detect. Timed path. |
| `bup_hold` (from `souper_profile`, `pll_locked_s`, `pll_busy_s`); `pause_core` (tied to 0 today) | `clk_sys` → `clk_arm` | Two flops. Timed. |
| Capture messages: START, one WRITE per halfword, END | `clk_sys` → `clk_arm` | The message is held in a register, plus a toggle. The receiver copies it when it sees the change. Messages are at least 5 `clk_sys` clocks (349 ns) apart. Timed. |
| 48 kHz tick | `clk_74a` → `clk_arm` | Toggle into three flops. Asynchronous; covered by the clock groups (`core_constraints.sdc:16-20`). |
| Audio frame | `clk_arm` → `clk_sys` | Frame held, plus a toggle captured on `tog2 ^ tog3`, not upstream's `tog1 ^ tog2` (`bupchip_subsystem.sv:168-175`). The capture applies `muted ? 0 : frame`, and zero while `souper_profile` is low (`bupchip_subsystem.sv:173-179`). Timed. |

The toggles stay on the timed paths too. They cost about 20 ALMs [E] and keep the design correct if `clk_arm` ever moves to its own fPLL.

### 48 kHz

- A `clk_74a` accumulator, `acc += 8` wrapping at 12,375, gives 74.25 MHz × 8 / 12,375 = **exactly 48,000 Hz**. That is the same reference as the I2S LRCK, so there is no drift and no change between regions.
- It does not depend on the `clk_arm` divider.
- It replaces upstream's compile-time `POP_DIV` (`bupchip_subsystem.sv:136`). About 20 ALMs [E].

### Reset and hold

**The hold signal** is computed in `clk_sys` and reaches `clk_arm` through two flops:

```
bup_hold = ~pll_locked_s | pll_busy_s | ~souper_profile          (clk_sys)
cpu_run  = ~bup_hold_arm & asset_ready & sweep_done               (clk_arm)
```

- `asset_ready` is a `clk_arm` flag owned by the write receiver; see "Capture" below.
- `sweep_done` makes the CPU wait for a 64-clock sweep (3 µs) after every release. The sweep restarts whenever the CPU is held. It does two things:
  - it invalidates the 64 cache tags;
  - it writes 0 to r0–r14 through write port E.

**Held (in reset) while `cpu_run` is low:**
- the CPU;
- the peripheral and its FIFOs;
- the pop and the frame register (the output reads 0);
- the read cache's fill and prefetch state machines;
- the halt status, which is cleared on release.

**Not held:**
- the capture (on `clk_sys`; only `load_start` restarts it);
- the `clk_arm` write receiver;
- `psram.sv`;
- `asset_ready` and `asset_size`;
- the 48 kHz tick.

The download happens exactly while the CPU is held, so the capture writes must keep flowing. Upstream likewise resets its write path only with `reset_arm` (`bupchip_asset_ddr.sv:228-293`). A PSRAM read still in flight when hold rises finishes on its own (≤ 5 clocks) and is discarded. The receiver starts a write only when the controller is idle.

**What is not in the hold:**
- **The console reset.** It is left out, as on MiSTer (`top.sv:802`), so the music engine survives a 7800 reset.
- **`asset_ready` is never cleared by reset.** After a PAL retune the CPU reboots and parses the ARSC again from PSRAM. This fixes the reset-parity trap found in `bupchip_asset_ddr.sv`'s toggle scheme.

**Pause.**
- `pause_core` (`atari7800_pocket.sv:53`, passed to `top.sv` at `:866`) is tied to 0 at `core_top.v:850`. The Pocket build never pauses the core today.
- The BupChip still takes the input. It costs one gate and is kept so that the behaviour is already right if the Pocket menu pause is ever wired up. When asserted, it stops the pop and forces the output to 0.
- The CPU keeps running. With the FIFO above the watermark, the firmware sits in its poll loop (fw `0x178–0x18c`).
- MiSTer freezes the ARM on pause (`top.sv:803-806`) to protect state it shares with the 2600 mappers. That does not apply here.
- Pause is tested in simulation only, by driving the port.

## Memory map and timing per region

**Decode.**
- The region comes from bits [31:28] and [25] of the address computed in execute. It only selects which memory's data W returns.
- The exact checks are registered and checked in W; a failure halts. They cover:
  - window bounds;
  - asset offset < `asset_size`;
  - writes to ROM or assets;
  - LDM/STM outside ROM and RAM.
- **Wild stores.** A store with addr[31:28] = 4 that lies beyond the 16 KiB RAM aliases into the RAM. It commits at the end of execute, one clock before W's exact check halts the core.
  - Upstream never writes in that case (`bupchip_memory.sv:85`).
  - It is harmless. The firmware never does it, and the core halts with the output silent either way.
  - Gating the write enable with the bounds check would put a 14-bit compare on the execute path [E].

Latencies are for S3, with S1 in brackets:

| Region | Address | Implementation | Load | Store |
|---|---|---|---|---|
| Fetch | 0x0000_0000–0x0000_3FFF | ROM 4,096 × 32, `cache_ram_dp` port A (`cache_ram.v:292`), stock `bupchip.mif` (found through `ap_core.qsf:750`), 16 M10K | No added clocks: the next PC drives the M10K address | — |
| ROM data | Same | Port B: literals, the jump table at 0x1f0, the note table, `.data`, the silent sample at 0x1e38 | 1 [2] | Halt |
| Assets | 0x0200_0000 + [0, `asset_size`) | 64 × 16 B direct-mapped cache (data 1 M10K, tags 1 M10K) in front of PSRAM `cram0` die 0 | Hit 1 [2]. A miss adds T_hw + 3 = 8; an LDR, which needs two halfwords, adds 13. | Halt |
| RAM | 0x4000_0000–0x4000_3FFF | 4,096 × 32 with byte enables, `cache_ram_tdp_dc_be` port A (`cache_ram.v:190`), 16 M10K | 1 [2] | 1 [1] |
| MMIO | 0xE000_9000–0xE000_90FF | `bupchip_peripheral.sv`, unmodified | 1 [2] | 1 [2] |
| Anything else | — | Halt, with code and PC in a sticky status word | — | — |

**How each access works (S3):**
- **Execute, closing edge.** The address, write enable, byte enables and data go to every M10K. A RAM store commits on that edge.
- **W.** The data source is chosen from the registered region, then lane-extracted and sign-extended. The result is written through register-file port W and forwarded into execute in the same clock.
- **MMIO.**
  - `reg_sel = mmio & commit` is registered at the end of execute.
  - `reg_sel` is a one-clock pulse: it clears after its W clock, whatever execute is doing. Only execute stalls (for the throttle or an asset miss); W always drains. This matters because `cmd_pop` and `pcm_push` fire on every clock that `reg_sel` is high (`bupchip_peripheral.sv:72, 92`).
  - The peripheral access happens in W. `reg_rdata` is combinational (`bupchip_peripheral.sv:187-199`), and the side effects (pop, push, control writes) land at the end of W.
  - So each MMIO access happens exactly once, in program order, and never for a frozen or condition-failed instruction.
- **Asset miss.**
  1. The tag compare runs in W. On a miss, execute freezes and commits nothing, and the PC holds (the ROM re-reads the same word).
  2. The fill starts at the critical halfword, the one holding the access's lowest byte, and wraps around the line. The line's tag is written invalid when the fill starts, and its 8 per-halfword arrival bits are cleared.
  3. Each arriving halfword is written to the data RAM and sets its arrival bit.
  4. W completes once every halfword the load touches has arrived:
     - one halfword for LDRB, LDRH, LDRSB and LDRSH;
     - both halfwords of the aligned word for LDR. An unaligned LDR rotates within that word.
     
     The boot code depends on this. It reads the ARSC tag with word loads at `0x2000004` and `0x2000008` (fw `0xf8`, `0xfc`). It reads bytes 0–3 back to back (`0xac`, `0xc0`, `0xc8`, `0xec`), about 3 clocks apart while the next halfword is still 5 clocks away. Completing on the critical halfword alone returns stale data and ends in fault 2 at `0xd4`.
  5. The replay read is presented one clock after the write of the last halfword it needs. The M10K therefore never sees a read and a write of the same address on the same edge, where its mixed-port read-during-write result would apply.
  6. A load that hits the line under fill completes only once its halfwords have arrived. Until then it stalls like a miss, without starting a fill.
  7. The tag is written valid when the fill ends.
  8. A condition-failed asset load does no lookup and starts no fill.

## Pipeline and cycle counts

```
 npc mux {pc+1 | branch target | BX Rm | LDR-pc data from W | pc (hold)}
   |
 [ROM M10K port A address register]  = the fetch/execute register
   | q (unregistered)
 EX: decode, cond(NZCV reg) -> RF read x3 (+bypass, +W forward) -> shifter -> ALU | DSP
     -> RF port E, NZCV; address -> ROM B | RAM | cache data+tag | MMIO request register
 W:  data -> lane/sign -> RF port W, forwarded to EX;  tag compare -> freeze
```

**Execute takes one clock, and taken branches cost nothing.**
- `npc` is computed in execute and loaded straight into the ROM's address register.
- The condition test reads the *registered* NZCV. A CMP followed by a branch needs no forwarding, because the CMP writes NZCV at the end of its execute clock.

**Control states:**
- RUN.
- SEQ: LDM/STM beats.
- UMULL2.
- SHR2: shift by register.
- SQUASH: the clock after `LDR pc`.
- HALT.

**Freeze** stops execute only. It happens on an asset miss or a fill stall in W, or for the debug throttle.
- W is never frozen by the throttle. An asset load in W waits for its halfwords; every other W completes in its clock.
- Hold does not freeze the core. It resets it (see "Reset and hold").

**Commit gate.** `commit = advance & cond_pass & !halt` gates every side effect: register-file writes, NZCV, RAM write enable, `reg_sel`, fills and redirects.

### Cycles per class

| Class | S1 | S3 |
|---|---|---|
| Data processing (immediate, register, shift by immediate, S bit), MRS, MSR | 1 | 1 |
| Data processing, shift by register | 2 | 2 |
| Any instruction whose condition fails | 1 | 1 |
| B, BL, BX, taken or not | 1 | 1 |
| Load from ROM, RAM, MMIO, or an asset hit | 2 | 1; the next instruction may use the data |
| Asset miss | + wait for the halfwords it needs | + T_hw + 3 = 8 clocks; 13 for LDR (T_hw = 5 [sim]) |
| Store, immediate offset | 1 | 1 |
| Store with register offset; any MMIO store | 2 | 1 |
| `LDR pc` | 2 | 2 |
| MUL / MLA | 2 | 1 |
| UMULL | 3 | 2 |
| LDM / STM of n registers | n+3 / n+2 (B's RTL sequencer) | n / n |
| Unsupported encoding | Halt | Halt |

S2 is S3 with 2-clock MUL/MLA and 2-clock register-offset stores.

### The hot loop at 0xc00 under S3

This is the forward, other-voices loop (`fw.dis:776-802`). It shows each forwarding path:

| Clock | Execute | W | Operands |
|---|---|---|---|
| 1 | `ldrh r9,[r4,r2]!` | — | r4 written through port E |
| 2 | `ldrsb sl,[r5]` (asset) | `ldrh r9` | — |
| 3 | `mla r7,lr,sl,r9` | `ldrsb sl` | `sl` from W this clock, into Rs of the DSP; `r9` from last clock's W write |
| 4 | `strh r7,[r4]` | — | `r7` from last clock's E write |
| 5 | `ldrh r7,[r4,#2]` | — | — |
| 6 | `mla r5,ip,sl,r7` | `ldrh r7` | `r7` from W this clock, into the accumulator |
| 7 | `strh r5,[r4,#2]` | — | `r5` from last clock's E write, as store data |

The whole iteration is 22 instructions:

| Core | Clocks per iteration |
|---|---|
| S3 | 22 [model] |
| S1 | 30 [model] |
| ARM7TDMI cycles | 45 |
| MiSTer | about 86 |

### Weighted CPI on Misery_F (4 s, 60.6 M work instructions)

| Class | Share | S1 clocks each [model] | S3 clocks each [model] |
|---|---|---|---|
| Data processing, register | 26.9% | 1.00 | 1.000 |
| LDRH / STRH / LDRSB / LDRSH | 26.4% | 1.72 | 1.005 |
| LDR / STR | 14.1% | 1.68 | 1.001 |
| B / BL | 13.5% | 1.00 | 1.000 |
| Data processing, immediate | 10.2% | 1.00 | 1.000 |
| MUL / MLA | 8.7% | 2.00 | 1.000 |
| LDM / STM | 0.19% | 8.06 (see below) | 7.06 |
| BX | 0.12% | 1.00 | 1.000 |
| **CPI** | | **1.383 [RTL]** (model: 1.387) | **1.013 [model]** |

**Notes on the table:**
- The S1 model agrees with the S1 RTL to within 0.3%, which supports using the model for S2 and S3.
- The S1 model charges LDM n+2 and STM n. B's RTL takes n+3 and n+2, which is about 9.6 per instruction [E]. The model therefore undercounts LDM/STM by about 0.003 CPI.
- In S3, LDM/STM account for about 1.3% of clocks (0.19% × 7.06 / 1.013).
- In S3, asset stalls account for 0.13%.

### Required clock

| Configuration | CPI | Misery_F MHz at 100% busy: average / busiest 0.1 s / worst batch | Lowest clock without FIFO underrun (1,024 frames) | MHz for 20 MIPS | At the chosen clock |
|---|---|---|---|---|---|
| S1 | 1.383 [RTL] | 20.96 / 21.53 / 23.35 | — | 27.7 | 28.636 MHz → 20.7 MIPS |
| S2 | 1.116 [model] | 16.90 / 17.49 / 19.56 | — | 22.3 | — |
| **S3** | **1.013 [model]** | **15.35 / 15.78 / 17.86** | **15.59** | **20.25** | **21.477 MHz → 21.2 MIPS** |
| S3 without load→multiplier forwarding | 1.096 [model] | 16.62 / 17.08 / 19.17 | 16.89 | 21.9 | 21.477 MHz → 19.6 MIPS |
| S3 without load forwarding, 2-clock MUL | 1.189 [model] | 18.02 / 18.55 / 20.87 | 18.33 | 23.8 | 28.636 MHz → 24.1 MIPS |

**Other loads under S3:**

| Load | Result |
|---|---|
| Boss_S | CPI 1.017 |
| Title | CPI 1.021 |
| 16 looped voices (synthetic) | Needs 17.92 MHz, 83% of 21.477 [model] |
| Song-start batch | Absorbed by the FIFO |

**FIFO level at 21.477 MHz.** The lowest level on Misery_F is 657 frames (NTSC) and 655 frames (PAL), about 13.7 ms [model].

## Datapath blocks

ALM estimates use ALM ≈ (0.6–0.8) × LUT + 0.5 × arithmetic cells, plus 10 ALMs per MLAB LAB.
- The rule was checked against Quartus on `a78_cart_extent`: 106.5 predicted, 106.4 fitted.
- It under-predicts flip-flop-heavy logic by 11–32% (`sram_ctrl`).
- Quartus counts each MLAB LAB in "ALMs needed" ("[d] ALMs used for memory", `fit.rpt:4988`). The totals below therefore include MLAB LABs in the ALM column.

### Register file

| Property | Design |
|---|---|
| Registers | r0–r14 are stored. r15 is not: reads return PC + 8. |
| Write port E | Data-processing results, base write-back, BL link, MRS, MUL/MLA, UMULL low and high words |
| Write port W | Load data, LDM beats |
| Read port P1 | Bits [19:16]; bits [15:12] for the MLA accumulator |
| Read port P2 | Bits [3:0] |
| Read port P3 | Bits [11:8]; or bits [15:12] for store data; or the STM sequencer's index |
| Storage | Live-value table: 6 banks of 16 × 32 MLAB, one per (write port, read port) pair, plus a 15-bit table in flip-flops. If both ports write the same register in one clock, E wins: it holds the younger instruction. |
| Bypass | Last clock's E and W writes are registered (index and data). Read priority: this clock's W data, then last clock's E, then last clock's W, then the array. |
| Inference | `ramstyle "MLAB, no_rw_check"` |
| Reset | The sweep after every hold writes 0 to r0–r14 through port E, and sets the live-value table to E. This matches the reference core, which zeroes its registers on reset (`arm7tdmi_core.sv:2550-2552`). It is needed because the firmware stores callee-saved registers it has never written, and later pops them back: `push {r4,r5}` at fw `0x88` and `push {r4-fp,lr}` at `0x880` (retires 6,279 and 6,306 of the reference trace), with the pop at `0x9b4`. Without the clear, a reboot would restore stale values where MiSTer restores 0, and lockstep would flag the pop. |

The bypass means the array is only ever read for data written at least two clocks earlier. Correctness therefore does not depend on when the MLAB physically writes. That timing is not verified for this device, and no MLAB is used today (`fit.rpt:5025`).

**Cost:**
- 12 MLAB LABs, about 120 ALM-equivalents [E].
  - A Cyclone V MLAB has one write address and one read address, and is at most 20 bits wide (32 × 20).
  - So each 16 × 32 bank needs two MLABs, and banks cannot share one.
- 150–200 ALMs of table, bypass and forwarding multiplexers [E], plus 10–20 ALMs for the clear [E].
- S1 uses 1 write port and 2 read banks: 4 MLAB LABs, about 40 ALM-equivalents.

**Fallback:**
- A flip-flop file costs about +800 ALMs [syn: the whole-core sketch went from 1,631 to 2,865 LUTs and from 123 to 587 FF]. Net of the 12 MLAB LABs it replaces, that is about +700. With S3 it breaks the step 9 ALM gate (83.6–87.3%), so it is only paired with S1.
- Alternatively, an M10K register file with one more pipeline stage: CPI 1.014 [model]. This is the area-safe fallback.

### Fetch, decode and control

- **PC.**
  - A 12-bit word address within the ROM window.
  - The `npc` mux takes: PC + 1, branch target, BX Rm, `LDR pc` data from W, or hold.
  - A target outside the window halts. The check runs one clock later.
- **Decode** works straight from the ROM's unregistered output. Register indices are raw instruction bits behind one mux level. `condition_pass` comes from `arm7tdmi_pkg.sv:82-111`.
- **Supported encodings** are the firmware's inventory of 1,704 code words:
  - all 16 data-processing opcodes with every operand-2 form;
  - MUL, MLA and UMULL without the S bit;
  - every LDR/STR, LDRB/STRB and LDRH/STRH/LDRSB/LDRSH addressing mode (LDRT/STRT act as LDR/STR, since there is one privilege level);
  - LDM/STM without S, without PC in the list, and with a non-empty list;
  - B, BL, BX;
  - MRS CPSR, and MSR CPSR from a register or immediate.
- **Everything else halts:**
  - SWP, SWI, coprocessor and undefined encodings;
  - SPSR access;
  - S-bit multiplies, SMULL, UMLAL, SMLAL;
  - data processing with Rd = PC, write-back to PC, and PC in register-shift or store-data positions;
  - BX to a Thumb address (bit 0 set).
- **Cost:** 300–450 ALMs including the state machine [E].

### Shifter

- `arm7tdmi_pkg::shift_register` (`arm7tdmi_pkg.sv:134-185`) is used verbatim. It covers:
  - LSL, LSR, ASR and ROR by register amounts 0–255 from Rs[7:0];
  - non-zero immediate amounts;
  - the carry-out.
- It does not cover the immediate encodings of amount 0:
  - It treats an amount of 0 as no shift, with value and C unchanged (`:153-155`). That is right for LSL #0 and for register shifts, but wrong for immediate LSR #0 and ASR #0, which mean #32.
  - It has no RRX case. ROR with amt5 = 0 and a non-zero amount is ROR #32 (`:164`).
- So decode normalises immediate shifts first:
  - immediate LSR #0 and ASR #0 become amount 32;
  - ROR #0 selects RRX, a separate path that returns {C, op2[31:1]} with carry = op2[0].
- Both are written from the ARM ARM, not from `arm7tdmi_core.sv`. That core's `immediate_shift_amount` and RRX datapath (`arm7tdmi_core.sv:1675-1692, 1121-1123`) are GPL-2.0-only.
- The firmware uses none of these encodings: 0 RRX and 0 LSR/ASR #0 among its 1,704 code words. Halting on them would also meet the exact-or-halt rule, but implementing them keeps the ISA suite and lockstep simple.
- Rotated immediates go through `ror32` (`:113-121`). Their carry is bit 31 when the rotation is not 0, and unchanged otherwise.
- A shift by register takes 2 clocks: Rs[7:0] is latched in the first.
- **Cost:** 250–330 ALMs [syn: 355 LUT + 104 arithmetic cells], plus 10–20 for the normalisation and the RRX path [E].

### ALU and flags

- One 32-bit adder with an inverted operand and carry-in serves ADD, ADC, SUB, SBC, RSB, RSC, CMP and CMN. The logic operations (AND, EOR, ORR, BIC, MOV, MVN, TST, TEQ) are separate.
- **Flags:**
  - N and Z from the result.
  - C from the adder's carry (meaning "not borrow" for subtraction), or the shifter's carry for logical operations.
  - V from the adder.
- **Cost:** 95–130 ALMs [syn: 130 LUT + 34 arithmetic cells].

### Multiplier

- One unsigned 32 × 32 → 64 multiplier, Rm × Rs, on 3–4 DSP blocks [syn: 2 × 27×27 + 2 × 18×18].
- **S3:**
  - MUL/MLA take 1 clock: the low word plus Rn goes to port E. Load data forwards into Rm, Rs and Rn.
  - UMULL takes 2 clocks: RdLo first, then RdHi from a register.
- **S1:** the product is registered, and the ALU adds the accumulator in a second clock.
- There is no early termination; nothing in the firmware depends on cycle counts.
- **Cost:** 30–130 ALMs [syn: 46 LUT + 192 arithmetic cells; Quartus may fold the partial-product adders into the DSPs].

### Load/store unit

- **Address:** Rn plus or minus a 12-bit immediate, a split 8-bit immediate, or a shifted Rm (pre-index); or Rn alone (post-index). Write-back goes through port E in execute.
- **Stores:**
  - byte enables: one-hot from addr[1:0] for a byte, from addr[1] for a halfword, all four for a word;
  - data is replicated across the lanes.
- **Loads:**
  1. Source mux: ROM port B, RAM, cache, or the MMIO register.
  2. Rotate right by addr[1:0] × 8.
  3. Zero or sign extend.
  4. Odd-address LDRH/LDRSH follow the ARM7TDMI.
- **Cost:** 100–160 ALMs [E; the lane logic alone is 77 LUT, syn].

### LDM/STM

- **First clock:** base write-back Rn ± 4n, with n from a popcount. The start address is:

  | Mode | Start address |
  |---|---|
  | IA | Rn |
  | IB | Rn + 4 |
  | DA | Rn − 4n + 4 |
  | DB | Rn − 4n |

- **Each beat:** the lowest remaining register (priority encoder), then address + 4.
  - STM reads that register through P3.
  - LDM writes it through W, one clock later.
- **Cost:** n clocks in S3.
- **Base register in the list.** Writing the base in the first clock gives ARM7's results without special cases: for LDM the loaded value wins; for STM the first beat stores the old base and later beats store the new one. The firmware never does this.
- **Cost:** 80–200 ALMs [E; 246 LUT + 109 arithmetic cells is an upper bound, syn].

### Totals

| Part | ALMs [E] | M10K | Other |
|---|---|---|---|
| CPU, S3: logic 1,270–1,690 (blocks above) + 12 MLAB LABs (120) | 1,390–1,810 | — | 3–4 DSP |
| ROM, 4,096 × 32 | ≈0 | 16 | — |
| RAM, 4,096 × 32 with byte enables | ≈0 | 16 | — |
| Peripheral, CMD 8 / PCM 1,024 (reused): 70–85 [syn] + 1 MLAB LAB | 80–95 | 4 | — |
| Bus glue, watermark remap, halt status | 40–70 | — | — |
| Asset cache, prefetch, fill state machine, per-halfword arrival bits | 140–210 | 2 | — |
| PSRAM controller | 60–100 | — | — |
| ARSC capture, byte-pair packer, message stream, `clk_arm` receiver, `asset_ready` | 100–130 | — | — |
| Crossings, 48 kHz tick, frame return with mute, hold, `pll_locked` sync | 60–80 | — | — |
| `top.sv` mixer once the audio is live (difference) | 30–60 [syn] | — | — |
| **Total** | **1,900–2,555** | **38** | 3–4 DSP |
| `BUP_DEBUG`: status word, shadow FIFO counters, throttle | +40–70 | — | — |

- **Device total:** 14,734–15,389 ALMs (79.7–83.3%), or 14,774–15,459 (79.9–83.7%) with `BUP_DEBUG`, and 84 of 308 M10K.
- **S1 total:** 1,470–1,975 ALMs (CPU 960–1,230 including 4 MLAB LABs), giving 77.4–80.1%; 77.6–80.5% with `BUP_DEBUG`.
- **LABs.**
  - The BupChip (S3, debug build) needs about 181–250 logic LABs at 10 ALMs each, plus 13 MLAB LABs: 194–263 LABs in all.
  - 199 LABs are untouched today (`fit.rpt:4998`). The upper part of the range therefore depends on the fitter packing existing logic more densely, as it does when the device fills (1,328 ALMs recoverable, `fit.rpt:4989`).
  - MLABs can only go in memory-capable LABs (up to half of all LABs, `fit.rpt:5000`), and today those hold logic.
  - Steps 3, 5 and 9 record "Total LABs", "Memory LABs" and the dense-packing estimate.
- **Cross-check:** A's whole-core Yosys sketch, 1,631 LUT + 585 arithmetic cells + 123 FF, converts to 1,270–1,600 ALMs of logic [syn→E]. Its register file was in MLAB, so that figure excludes the MLAB LABs.

## ARMv4 behaviours that must be exact

**Rule:** an encoding is either implemented exactly as on the ARM7TDMI (ARMv4) or it halts. Nothing is silently different.

| # | Behaviour | Firmware use | How it is kept |
|---|---|---|---|
| 1 | r15 reads as the instruction's address + 8 | 107 literal loads; `mov lr,pc` at 0x708, 0x106c, 0x18cc; `add r3,pc,#4` at 0x1e4 | Substituted on every read port. The PC+12 forms halt. |
| 2 | Shift by register uses Rs[7:0]. LSL/LSR by 32 or more give 0; ASR by 32 or more fills with the sign bit; a shift of 0 leaves the value and C unchanged. | The 64-bit divide, 0x2cc–0x360, with amounts 0–63 and 225–255; the VLQ decoders `orr r7,r7,r0,lsl r5` at 0x1098 and `orr r6,r6,r0,lsl r4` at 0x18f8, with amounts 0, 7, 14, … | `shift_register` |
| 3 | Immediate `LSR #32`, `ASR #32` and RRX, encoded as LSR #0, ASR #0 and ROR #0 | Unused (0 of 1,704 code words) | Decode maps LSR/ASR #0 to amount 32 before `shift_register`, which would otherwise treat 0 as no shift (`arm7tdmi_pkg.sv:153-155`). RRX is its own path. Both are written from the ARM ARM and covered by directed tests. |
| 4 | A rotated immediate sets C = bit 31 when the rotation is not 0 | `tst #0x40000`, `tst #0x100` | Rotator |
| 5 | Shifter carry-out on logical S operations | ANDS (only Z is read) | Exact, so that NZCV lockstep holds |
| 6 | C = "not borrow" after a subtraction; ADC/SBC carry-in | `rsbs; adc` at 0x480 and 0x9a4; SUBS/SBCS at 0x334/0x338 and RSBS/SBCS at 0x374/0x380 | Inverted operand with carry-in |
| 7 | V for add, subtract, CMP and CMN | GT/GE/LT/LE in the mixer's wrap tests | Adder overflow |
| 8 | A condition-failed instruction has no side effect, but still takes one clock and retires | `ldrcc` at 0x44; conditional LDR/STR/BX; `blne` at 0x1870 | `commit` |
| 9 | Halfword immediate split across bits [11:8] and [3:0]; `[Rn,±Rm]!` write-back | `ldrh r7,[r3,-r2]!` at 0xb9c | Decode; write-back through port E |
| 10 | Little-endian byte and halfword store lanes | `strh [r0,#18]` into the word at +16 | Byte enables |
| 11 | LDRSB/LDRSH sign extension | Samples; loop ends | W lane logic |
| 12 | Unaligned LDR rotation; odd LDRH/LDRSH | Never executed | Lane rotator; checked against the reference RTL only |
| 13 | `LDR pc` without interworking | Jump table at 0x1ec | W data drives `npc`, then SQUASH |
| 14 | BX to an ARM address; bit 0 set means Thumb | 63 BX | Bit 0 set halts |
| 15 | BL link = the BL's address + 4 | 34 BL | Port E |
| 16 | MLA: Rd in [19:16], accumulator Rn in [15:12] | Mixer | P1 index mux |
| 17 | UMULL: unsigned 64-bit result, RdLo [15:12], RdHi [19:16] | 0x300, 0x1b20 | Unsigned DSP product |
| 18 | LDM/STM order and start addresses; `stmib` without write-back starts at base + 4 | Push/pop; `stmib sp,{r0,r1}` at 0x888 | Sequencer |
| 19 | Rd == Rn with write-back; base register in the list | Never | ARM7 results by construction; directed tests |
| 20 | MRS CPSR = `{NZCV, 20'b0, 8'hD3}`; MSR CPSR_c ignored; MSR CPSR_f writes NZCV | 0x20–0x2c | Constant mode bits |
| 21 | MMIO is 32-bit, one access per instruction, in program order | Every boot and poll | `reg_sel` driven from W as a one-clock pulse |
| 22 | Where MiSTer aborts (`bupchip_memory.sv:125-136`), halt | Never in normal play | HALT. The visible result matches MiSTer's `b .` vectors: silence. |

## Asset memory path

### Storage
- PSRAM `cram0`, die 0 (`ce0_n`): 4M × 16, asynchronous.
- The address is split: A[21:16] go on `cram0_a`, and A[15:0] are multiplexed on DQ and latched by `adv_n`.
  - The pins are declared at `core_top.v:80-91`.
  - The controller does the multiplexing (`psram.sv:278-288` for writes, `:303-308` for reads).
- Asset byte b is stored in halfword b >> 1. `cram1` stays tied off (`core_top.v:279-289`).

### Controller
- agg23's MIT `psram.sv`, vendored unmodified to `src/fpga/pocket_utils/`, running on `clk_arm`. It is not held by `bup_hold`.
- **`CLOCK_SPEED` stays at 28.636364 for both dividers.** It must not be set to the real 21.477 or 21.281 MHz. Here is why:
  - The file derives its state numbers from the period (`psram.sv:85-119, 144-212`).
  - At CLOCK_SPEED = 21.477273, 21.281 and 14.318181, the 70 ns totals come out at 2 clocks (`TOTAL_READ/WRITE_CYCLE_COUNT`, `:111-119`). That is no more than the 1-clock phases that come before them.
  - So `STATE_READ_DATA_ENABLE` = `STATE_READ_DATA_RECEIVED` = 22, and `STATE_WRITE_DATA_START` = `STATE_WRITE_DATA_END` = 3 (its own `$info` output, `:214-230`).
  - The case statement takes the earlier item, so `DATA_RECEIVED` (`:362-380`) and `WRITE_DATA_END` (`:331-347`) never run. In simulation, 0 reads completed in 200 clocks [sim]. A write leaves `we_n` low while the state counter runs on through the read states.
- Every count in the file is a minimum time, so the 28.636 MHz setting is safe on a slower clock.
  - It gives 5 clocks per halfword read or write [sim: 5.00 clocks per read].
  - That is 175 ns at 28.636 MHz, 233 ns at 21.477 MHz and 235 ns at 21.281 MHz.
  - The cycle model already assumes 5 clocks per halfword.
- Fixing the file instead means making each total at least one clock longer than its phases, plus an elaboration check that the state numbers are distinct. That still takes 5 clocks at 21.477 MHz. A 4-clock controller would need a different state machine, and gains little: the model's 4-clock variant stalls 0.10% instead of 0.13%.
- `psram.sv` defines `` `MAX`` (`:30`), which `data_loader.sv:61` also defines, and declares `rtoi` at compilation-unit scope (`:25-27`). Expect Quartus redefinition warnings once both files are in `core.qip`. The two `` `MAX`` definitions are identical.

### Capture (on `clk_sys`) and the write receiver (on `clk_arm`)
1. The declared size comes from header bytes 49–52, and the block starts at 128 + the declared size. This is copied from `bupchip_asset_ddr.sv:82-104` (MIT).
2. Bytes are packed in pairs into halfword writes; an odd tail is written with UB/LB.
3. `asset_size` is the number of bytes captured.
4. The capture sends an ordered message stream to `clk_arm`, through one held register and a toggle:
   - START, at `load_start`;
   - one WRITE per halfword;
   - END, carrying `asset_size`, after `load_end`.
   
   Consecutive messages are at least 5 `clk_sys` clocks (349 ns) apart. Only the tail WRITE and END ever need delaying.
5. The receiver copies each message into its own register when it sees the toggle change, and handles messages in order:
   - START clears `asset_ready`, which holds the CPU from that clock on.
   - WRITE goes to `psram.sv` as soon as the controller is idle.
   - END waits until the controller is idle after the last write. It then latches `asset_size`, and sets `asset_ready` only if `asset_size` ≥ 4.
   
   A released CPU can therefore never read a halfword that has not been written. Upstream publishes ready the same way, through `end_toggle` (`bupchip_asset_ddr.sv:137-146, 275-279`).

**Write rate.** The loader delivers at most one byte per 174.6 ns (10 `clk_sdram` per byte: `core_top.v:669`, `data_loader.sv:161-164`) and has no backpressure (`atari7800_pocket.sv:951`). A WRITE therefore arrives at most every 349 ns: 7.5 clocks at 21.477 MHz, 7.4 at 21.281 MHz and 10 at 28.636 MHz. Budget at 21.281 MHz, the worst case:

| Step | Clocks | ns |
|---|---|---|
| Toggle seen by the receiver (two flops plus the change detect) | 2–3 | 94–141 |
| PSRAM write (`CLOCK_SPEED` = 28.636364) | 5 | 235 |
| Toggle to write done | ≤ 8 | ≤ 376 |

- The chain is longer than the 349 ns spacing. The receiver must therefore copy each message when it detects it (a one-entry buffer); it cannot read the `clk_sys` register when it starts the write.
- With the copy, write k finishes ≤ 376 ns after its toggle. Message k+1 cannot be seen before 349 + 94 = 443 ns.
- So the controller is idle whenever a message arrives, busy 5 of every ≥ 7.4 clocks (68%), and needs no second entry and no backpressure [E]. Step 4 checks this with the loader at 175 ns per byte.

### Cache
- 64 lines × 16 B, direct-mapped:
  - index: offset[9:4];
  - tag: offset[22:10] plus a valid bit.
- **Data:** one M10K, written 16 bits at a time from PSRAM and read 32 bits at a time by the CPU.
- **Tags:** one M10K. Port A does the CPU lookup. Port B does the prefetch probe and the tag writes (invalid at fill start, valid at fill end).
- **Fill state:** line index, tag, demand or prefetch, and 8 per-halfword arrival bits. Only one fill runs at a time.
- Tags are invalidated by the 64-clock sweep after every hold.

### Miss and prefetch
- **A miss** fills the critical halfword first, then wraps around the line. W completes as described under "Memory map": once the halfwords the load touches have arrived, with the replay read one clock after the last of them is written. A hit on the line under fill waits the same way.
- **Prefetch:** after every asset access, the next line is probed. If it is absent and no fill is running, it is fetched from halfword 0.
- **Pre-emption.** A demand miss to a line other than the one being filled waits for the halfword in flight (≤ 5 clocks; `psram.sv` cannot abort a read). It then pre-empts the fill. The pre-empted line's tag stays invalid, as written when that fill started.
- The cycle model does not pre-empt. There, a demand miss waits for the whole fill in flight (691 late cases in 4 s). Step 4 compares the two on Misery_F and keeps pre-emption only if it stalls less.

### Measured cost [model, Misery_F, 4 s, 2.62 M asset reads, S3]

All rows use 5 PSRAM clocks per halfword and 3 clocks of miss overhead.

| Asset path | Effect |
|---|---|
| **64 × 16 B with prefetch (chosen)** | 7,910 demand misses, 65,471 prefetches, 0.13% stall clocks |
| No prefetch | 63,191 misses, CPI 1.020 |
| 32 lines | 1.7% stall |
| 128 lines | 0.07% stall |
| No cache (a one-halfword buffer) | CPI 1.203 |

The firmware reads samples sequentially, one `ldrsb` per voice per frame, which is why prefetching works.

**If the hardware PSRAM is slower than modelled:**
- 128 lines;
- `cram1` in parallel for 32-bit fills (B's arrangement, about +20 ALMs [E]);
- or go back to 28.636 MHz.

## PCM and command FIFOs

- **The peripheral is reused unmodified,** with `CMD_DEPTH = 8` and `PCM_DEPTH = 1024` (4 M10K). Its defaults are 32 and 4,096 (`bupchip_peripheral.sv:18-23`).
- **Watermark remap.** On writes to 0x18, the bus glue replaces `reg_wdata[28:16]` with `clamp(W − (4096 − D), 0, D)`.
  - The firmware writes 3,896 (literal at fw 0x28c, stored at 0x124 and 0x174), so the effective watermark is 824. This keeps the firmware's only assumption, D − W = 200.
  - **Without the remap, boot deadlocks.** The watermark is truncated, not clamped (`bupchip_peripheral.sv:169`). With a 512-frame FIFO, the CPU was measured stuck at 0x14c [RTL].
- **Levels.**
  - The steady level is 823–1,022 frames, so a command is heard after 17–21 ms. On MiSTer it is 81–85 ms.
  - The lowest level under load is 664 frames (S1 at 28.636 MHz [RTL]) and 657 frames (S3 at 21.477 MHz [model]).
- **Pop.** `pop = tick48k & pcm_enabled & !pause`. `pause` is tied to 0 today.
  - An empty FIFO plays 0 (as in `bupchip_subsystem.sv:144-164`).
  - A FAULT write sets the peripheral's `muted` output (`bupchip_peripheral.sv:175-180`), but the peripheral does not zero `pcm_frame`. The wrapper's `clk_sys` frame capture applies `muted ? 0 : frame`, and it zeroes the output while `souper_profile` is low. Both follow upstream (`bupchip_subsystem.sv:173-179`). `top.sv` also gates the mix on `souper_profile` (`:649-652`).
- **Output path.** The frame register crosses to `clk_sys` with the mute applied, becomes `bupchip_audio_l/r`, and goes through the existing gain, saturation, midpoint and halving (`top.sv:641-668`, `ext_audio` at `:220`). The levels are therefore MiSTer's.
- **Command FIFO.** The firmware never reads register 0x08 and pops once per main-loop pass, so it cannot see the depth.
- **Debug counters.** The peripheral's sticky overflow and underflow bits and its FIFO levels are internal (`bupchip_peripheral.sv:60, 85, 89`). Its ports (`:24-51`) export only `reg_rdata`, `pcm_frame`, `pcm_available`, `pcm_enabled`, `muted` and `fault_code`. Under `BUP_DEBUG` the wrapper therefore keeps shadow counters:
  - **CMD level:** +1 on `cmd_valid`; −1 on a committed read of 0x04 while the level is non-zero; set to 0 by a write of 0x0C with bit 1 set. Command overflow = `cmd_valid` at level 8.
  - **PCM level:** +1 on a committed write of 0x10 below 1,024; −1 on a pop while not empty. PCM overflow = a push at 1,024. Underflow = a pop while `pcm_available` is low.
  - **Lowest PCM level** while `pcm_enabled` is set.
  - The flags are sticky until the next hold. Simulation checks every shadow counter against the peripheral's internal one through hierarchical references, which are allowed in simulation only. About 40–70 ALMs with the throttle [E].
- **Fallback:** the `PCM_DEPTH = 4096` parameter without the remap (16 M10K).

## Integration

### New files: `src/fpga/core/bupchip/`

| File | Contents |
|---|---|
| `bupchip_pocket.sv` | Wrapper: hold and reset, `pll_locked` sync, crossings, ROM/RAM instances, decode, watermark remap, peripheral instance, frame return with mute, status, shadow FIFO counters, debug throttle |
| `bup_cpu.sv` | The CPU: S1, later S3 |
| `bup_regfile.sv` | Live-value-table register file with bypass and the clear after hold |
| `bup_asset_cache.sv` | Tags, data, per-halfword arrival bits, fill and prefetch state machines (held by `bup_hold`) |
| `bup_asset_wr.sv` | `clk_arm` message receiver, `asset_ready` and `asset_size`, PSRAM arbitration between writes and fills (not held) |
| `bup_capture.sv` | ARSC header parse, byte-pair packer, START/WRITE/END message stream (`clk_sys`) |
| `bup_tick48k.sv` | The `clk_74a` accumulator and toggle |

Also:
- `src/fpga/pocket_utils/psram.sv`: agg23, MIT, vendored unmodified, instantiated with `CLOCK_SPEED = 28.636364`.
- The ROM uses the stock `mister/rtl/bupchip.mif`. No new MIF is needed.

### Vendored file (`POCKET_CHANGES.md` rule: `ifdef` blocks only, identical to upstream without the macro, `:90-92`)

`mister/rtl/top.sv` is the only vendored file touched.
- **Port group.** Add one next to `POCKET_SRAM` (`:23-35`):

  ```systemverilog
  `ifdef POCKET_BUPCHIP
  	output logic        bup_cmd_valid_o,
  	output logic  [7:0] bup_cmd_data_o,
  	output logic        souper_profile_o,
  	input  logic [15:0] bup_audio_l_i,
  	input  logic [15:0] bup_audio_r_i,
  `endif
  ```

- **Assignments.** Inside the `else` of `ifndef NO_BUPCHIP` (`:1017-1034`), add an `ifdef POCKET_BUPCHIP` block:
  - `bupchip_audio_l/r` take the inputs;
  - the command outputs take `bup_cmd_valid_eff` and `bup_cmd_data_eff` (`:948-956`);
  - `souper_profile_o` takes `souper_profile` (`:966`);
  - the zeros stay in that block's `else`.

`cart.sv`, `souper.v`, `bupchip_peripheral.sv` and `cache_ram.v` are not changed.

### Pocket-owned edits

| File | Change |
|---|---|
| `core/atari7800_pocket.sv` | Add `ifdef POCKET_BUPCHIP` ports `clk_arm`, `clk_74a` and `cram0_*`. Instantiate `bupchip_pocket` next to the `mapper_load_*` expressions (`:946-950`). Connect `pause_core` (`:53`; tied to 0 at `core_top.v:850`), `pll_locked` (raw; the wrapper synchronises it), `pll_busy` and the new `top.sv` ports. |
| `core/core_top.v` | Connect `outclk_3` → `clk_arm` on `pll_core` (`:320-329`). Route `cram0_*` instead of the tie-offs (`:267-277`); `cram1` stays tied. |
| `core/pll/pll_core.v` | Regenerate with 4 clocks; C3 = 24, then 32 (`DEVELOPING.md:245-271`). |
| `ap_core.qsf` | Add `VERILOG_MACRO "POCKET_BUPCHIP=1"` next to `:736-746`. Keep `NO_ARM_MAPPER`, `NO_BUPCHIP` and `NO_DDRAM`. Add `FAST_*_REGISTER` on `cram0_*`, as for the SRAM (`:758-765`). |
| `sim/run_sim.sh` | Add `-DPOCKET_BUPCHIP` to the macro list (`:77-81`), the new files and `psram.sv` to `SRCS`, and `bupchip.hex` to the `rtl/` links (`:14`). `ap_core.qsf:741-743` promises that simulation builds the same set as the qsf. |
| `sim/tb_system.sv`, `sim/tb_load.sv` | Drive `clk_arm`, `clk_74a` and a `cram0` PSRAM model on the `atari7800_pocket` instances (`tb_system.sv:49`, `tb_load.sv:85`). |
| `core/core.qip` | Add the new files, `../mister/rtl/bupchip_peripheral.sv` and `../pocket_utils/psram.sv`. Fix the stale "unmodified except `top.sv`" comment (`:3-5`). Expect the `` `MAX`` redefinition warning described under "Controller". |
| `core/core_constraints.sdc` | Comment only: add counter[3] (`:3-11`) |
| `mister/POCKET_CHANGES.md` | Add a `POCKET_BUPCHIP` row to the switch table (`:80-92`) and update "Three build switches" and "all four" |
| `THIRD_PARTY_NOTICES.md` | Add `psram.sv` to the agg23 row (`:25`). Note `bupchip.hex`/`.mif` as built in. Rewrite the paragraph at `:49-54`, which says no console or peripheral firmware is included and explains why the HSC and Supercharger firmware are loaded at run time. |
| `docs/` | `BUPCHIP.md` (load table, pointer to this document), `DEVELOPING.md` (clock plan with 4 counters), `README.md` resource figures |

### Macros and parameters

| Name | Effect |
|---|---|
| `POCKET_BUPCHIP` | `top.sv` exports the command and takes in the audio; the Pocket files build the BupChip |
| `BUP_DEBUG` | Adds a status word (halt code and PC; shadow-counter flags for command overflow, PCM overflow and PCM underflow; fault code; lowest PCM level) and the throttle |
| `PCM_DEPTH`, `BUP_THROTTLE` | Parameters of `bupchip_pocket` |
| `ALTERA_RESERVED_QIS` | Set by Quartus. The retire port is simulation-only, as in `cache_ram.v:31`. |

## Verification plan

The harnesses already exist from the study. Step 1 brings them into `sim/bupchip/` without game data.

| Phase | What | Pass |
|---|---|---|
| ISA | `sample.S`, plus `gen_random.py` (200 seeds × 300 operations) against Unicorn | All signatures equal. Unicorn models an ARM926 (ARMv5), so unaligned accesses and unpredictable forms are excluded here and covered against the reference RTL. |
| Directed tests, against the reference RTL | See the list below this table | 0 mismatches; halts exactly where expected |
| Lockstep, against `arm7tdmi_core` (`tb_lockstep.sv`, peripheral reads replayed) | Boot + Misery_F, 1 M instructions; mixer harness, 1.74 M; all 32 songs × 4 s overnight (local data); synthetic ARSC with every command class; random-content ARSC seeds; an injected load bit-flip | 0 mismatches and 0 halts, with no register masking (both cores start from zeroed registers). The injected fault must be caught. |
| PCM | Misery_F, 4 s, against `rtl13.pcm` (187,984 frames); other songs against the Python model | Identical |
| Performance | Clocks per batch, from the retire of 0x190 to that batch's return to 0x178: the retire of 0x1dc after a render, or of 0x274 after a silent batch. Idle is defined by the *retired* PC. | S1 within ±1% of 1.383; S2 and S3 within ±2% of the model; per-batch worst case within ±3% |
| PSRAM | `psram.sv` against a PSRAM model (`psram.sv:36-53` timings), with `CLOCK_SPEED` = 28.636364 at clock periods of 28.636, 21.477 and 21.281 MHz | Every read and write completes in 5 clocks; the `$info` state numbers are distinct |
| System | Wrapper with the PSRAM model, the loader at 175–250 ns per byte, the `clk_74a` tick and the real clock ratio. Also: 2–3 cart reloads, a PAL retune, pause (driven in simulation; it is tied to 0 on hardware), a non-Souper cart, and a hold during a fill. | 0 underflow and 0 overflow from the shadow counters (the existing testbench checks only underruns, `tb_bupchip.sv:151`); lowest FIFO level ≥ 600; no capture message lost; misses within ±20% of the model |
| Quartus | CPU alone, then the integrated build | The gates in steps 3, 5, 8 and 9 |
| Hardware | 32 songs, NTSC and PAL, with the `BUP_DEBUG` status visible; throttle sweep; A/B against a MiSTer capture | Shadow-counter flags clear; fault code 0 |

**Directed tests, all checked against the reference RTL:**
- shift amounts 0/1/31/32/33/224/255 × 4 types × S bit;
- immediate LSR #0, ASR #0 and ROR #0 (RRX), with and without S;
- every flag source × 16 conditions;
- MUL/MLA/UMULL corners;
- every LDM/STM form, including base in list;
- Rd == Rn with write-back;
- unaligned and odd accesses;
- load into Rm/Rs/Rn of MLA, into BX, into store data and into a base;
- E and W writing the same register in one clock;
- `LDR pc`;
- an asset miss with a dependent MLA or a store in execute;
- an asset word-load (LDR) miss;
- back-to-back byte reads across halfwords on a cold line (the boot's 0xac–0xec sequence);
- a hit on the line under fill;
- a demand miss during a prefetch (the pre-empted line must miss again);
- a register read before any write after a hold (must read 0);
- a wild store to 0x4000_4000 (must halt);
- the throttle freezing execute while an MMIO pop is in W (must pop once);
- a condition-failed MMIO read (must not pop);
- one test per halt class.

**Lockstep retire record.** The record is `{pc, insn, the register writes from ports E and W, NZCV}`, in program order.
- Loads complete one clock after their execute clock, so the testbench applies each record to a shadow state.
- It does not snapshot the live register file.

**Game-free regression.**
- The firmware study's synthetic ARSC generator builds a 5.2 KB block. With it, the firmware boots, plays, uses all 21 bytecode ops and every command class, and reaches all three fault paths.
- Its reference PCM comes from the Python model.
- This, the mixer harness and the ISA suite run in CI-style scripts without game files.

**Testbench rules carried over:**
- The period, `ARM_MHZ` and the pop logic change together (`tb_bupchip.sv:21-22`).
- Detect halts and spins.
- Check overflow as well as underflow.

## Implementation steps

1. **Tools into the repository** (`sim/bupchip/`): lockstep and ISA harnesses, mixer harness, Python model, cycle models, synthetic ARSC generator.
   *Done when:* reference against reference runs 1 M instructions with 0 mismatches; ISA passes 200/200 on the reference against Unicorn; the Python model's Misery_F PCM equals `rtl13.pcm` (with local data); the synthetic ARSC renders non-zero PCM.
2. **S1 core in simulation.** Import B's core as `bup_cpu.sv` after a clean-room review. Add:
   - the `arm7tdmi_pkg` shifter and condition logic;
   - immediate-shift normalisation and RRX;
   - exact flags and rotations;
   - the register clear after hold;
   - the halt policy and the retire port.
   
   *Done when:* ISA and directed tests pass; lockstep has 0 mismatches on all the lockstep runs listed in the verification plan; Misery_F PCM is bit-exact for 4 s; CPI is within ±1% of 1.383.
3. **Quartus probe** (once the baseline frees Quartus): S1 plus the 2-write/3-read register file, compiled alone on 5CEBA4F23C8 with 28.636 MHz and 21.477 MHz constraints.
   *Done when:*
   - The RAM summary shows the register-file banks in MLAB (12 MLABs) with unregistered read, and the memories in M10K.
   - Slack is ≥ +5 ns at 28.636 MHz (slow 85 °C).
   - ALMs and LABs are within ±25% of this document.
   
   If MLAB fails, choose a fallback here. The M10K register file is the area-safe one.
4. **Wrapper, memories and asset path in simulation.** Peripheral 8/1024 with remap and shadow counters, ROM from the stock MIF, RAM, the 64-line cache with per-halfword arrival bits, the capture message stream and receiver, and the 48 kHz tick. `psram.sv` runs with `CLOCK_SPEED` = 28.636364 against a PSRAM model at clock periods of 28.636, 21.477 and 21.281 MHz.
   *Done when:*
   - A download of `rv.a78` followed by 4 s of Misery_F gives PCM identical to `rtl13.pcm`, with 0 underflow, 0 overflow and a lowest level ≥ 600.
   - The PSRAM and directed cache tests pass; no capture message is lost at 175 ns per byte.
   - Pre-emption is kept or dropped on measured stall clocks.
   - Reloads, retune and pause (in simulation) pass.
5. **Integrate S1 at 28.636 MHz** (C3 = 24).
   *Done when:*
   - Full compile with `BUP_DEBUG`: `clk_arm` slack ≥ +3 ns; `clk_sdram` ≥ +1.0 ns; `clk_74a` ≥ +2.0 ns; ALMs ≤ 81% (estimate 77.6–80.5%). LAB use is recorded.
   - Non-Souper simulation regressions are unchanged, with `run_sim.sh` building `POCKET_BUPCHIP`.
   - On hardware, Rikki & Vikki plays all 32 songs with the shadow-counter flags clear and fault code 0.
6. **S2 in simulation:** second write port, bypass, load forwarding.
   *Done when:* all step 2 checks pass again, and CPI is within ±2% of 1.116.
7. **S3 in simulation:** third read port, 1-clock MUL/MLA, forwarding of loads into the multiplier.
   *Done when:* all step 2 checks pass; CPI is within ±2% of 1.013; the 16-voice harness needs ≤ 18.5 MHz.
8. **S3 timing:** standalone compile at 21.477 MHz.
   *Done when:* slack ≥ +10 ns. If not, drop load→multiplier forwarding (CPI 1.096) or stay at 28.636 MHz.
9. **Build S3 at 21.477 MHz** (C3 = 32; `psram.sv` keeps `CLOCK_SPEED` = 28.636364).
   *Done when:*
   - The step 5 slack gates hold, and ALMs are ≤ 84% (estimate 79.9–83.7% with `BUP_DEBUG`). LAB use is recorded.
   - On hardware, all 32 songs play under NTSC and PAL.
   - Misery_F has no underflow with the throttle at 13/16 (17.45 MHz effective; the model's lowest underrun-free clock is 15.59 MHz).
   - The lowest passing throttle setting is recorded here.
   
   *Fallback:* if S3 misses the ALM or slack gates, ship S2 or S1 at 28.636 MHz (C3 = 24), which passed step 5.
10. **Documentation.** Update `BUPCHIP.md` (load table, pointer to this document), `POCKET_CHANGES.md`, `THIRD_PARTY_NOTICES.md` (including `:49-54`), `README.md` and `DEVELOPING.md`.
    *Done when:* every number in them matches the shipped build's reports.

## Open questions and risks

| # | Risk or question | Impact | Mitigation or check |
|---|---|---|---|
| 1 | Asynchronous-read MLAB inference on Cyclone V. No MLAB is used today (`fit.rpt:5025`). | +700 ALMs net as flip-flops (only viable with S1), or one more pipeline stage with an M10K register file (CPI 1.014) | Step 3. The bypass already removes any dependence on MLAB write timing. If next-clock reads turn out to be safe, the bypass (about 100 ALMs) could be dropped. |
| 2 | Single-clock execute timing on a C8 part at about 80% fill. Estimates: S3 25–27 ns, S1 19–30 ns [E]. | Lower clock or less forwarding | 46.56 ns period at 21.477 MHz; reduced-forwarding variants; region decode from the base register; a LogicLock region. Steps 3 and 8. |
| 3 | PSRAM: 1.8 V I/O with no I/O constraints; tCEM and page mode unverified; `FAST_INPUT_REGISTER` needs DQ captured straight into the I/O register (agg23 samples DQ in fabric). `psram.sv` breaks at `CLOCK_SPEED` = 21.477/21.281. | Slower fills; no fills at all if misconfigured | `CLOCK_SPEED` fixed at 28.636364 (5 clocks per halfword), checked in step 4. Cache stall is 0.13%; 13.7 ms of FIFO margin; even uncached, the core manages 23.8 MIPS at 28.636 MHz [model]. Hardware CRC readback of the ARSC. |
| 4 | S2 and S3 figures come from the cycle model | CPI higher than planned | S1's model and RTL agree to 0.3%. Steps 6 and 7 measure RTL. Fall back to S1 or S2 at 28.636 MHz. |
| 5 | Congestion: `clk_sdram` has +1.32 ns of slack today; only 199 LABs are untouched against 194–263 needed | `clk_sdram` timing failure; a fit that relies on denser packing | No BupChip logic on `clk_sdram`; slack, ALM and LAB checks in steps 3, 5 and 9; LogicLock; S1 fallback |
| 6 | Deviations from the firmware contract: watermark remap; halt instead of an abort spin; fixed mode bits; CPU not paused; music starts about 64 ms earlier than on MiSTer | Visible only to other firmware | CoreTone never reads the FIFO depth or mode bits (lockstep). Document them. |
| 7 | `bupchip.hex` in the bitstream. `mister/rtl` is MIT (`THIRD_PARTY_NOTICES.md:17`), but the firmware's source is not published (`BUPCHIP.md:13-15`). Building it in contradicts `THIRD_PARTY_NOTICES.md:49-54`. | Release blocker | Confirm with upstream before release. *Fallback:* load the 7.8 KB image at run time from a data slot, as the HSC and Supercharger firmware are (`EXTERNAL_FIRMWARE`, `ap_core.qsf:739`; slots `0x106`/`0x107` in `data.json`). It is written into the ROM M10K through `cache_ram_dp` port B, which has a write port (`cache_ram.v:292-311`), while the CPU is held; a `fw_loaded` flag joins `cpu_run`. |
| 8 | Clean-room status of B's sketch, said to be written from the ARM ARM | GPL contamination | Reviewer sign-off in step 2. Reuse only MIT code (`arm7tdmi_pkg`, peripheral, capture parse, `cache_ram`, `psram.sv`). RRX and the immediate-shift normalisation are written from the ARM ARM. |
| 9 | Only Rikki & Vikki has been measured | Other content could need more | The firmware caps at 16 voices, and that bound fits at 83% |
| 10 | Command bursts beyond 8 between pops | Lost command | `BUP_DEBUG` shadow overflow flag; raise `CMD_DEPTH` (1 MLAB either way) |
| 11 | BupChip audio passes through `audio_filter`'s 256-sample boxcar (about 55.9 kHz) before I2S | Small resampling loss | Kept as MiSTer's mix for identical levels. Open: mix at the I2S input instead. |
| 12 | ROM depth | 8 M10K | A 2,048-deep MIF frees 8–9 blocks if M10K ever runs short |