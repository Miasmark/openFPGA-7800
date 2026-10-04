# ARIA: the Pocket's BupChip core

**ARIA** (Atari RISC Interface Accelerator) is the name of the CPU that runs CoreTone on the Pocket. It joins the 7800's own named chips, MARIA and SALLY, and its musical name fits its job. If it also comes to run the 2600 ARM cartridges (see "Later: 2600 ARM cartridges"), it becomes **DARIA**, the dual-use version. The RTL keeps its descriptive file and module names (`bup_cpu.sv`, `bup_*`).

This document describes ARIA, together with its memories, asset path and glue. It builds on `docs/BUPCHIP.md`, which covers what the firmware needs, and on a design study that compared three proposals. Step 1 moved the study's tools into `sim/bupchip/`: the Python model and cycle models to `sim/bupchip/model/`, the RTL sketch, PSRAM and FIFO experiments and Yosys counts to `sim/bupchip/model/study/`, and the lockstep, ISA and mixer harnesses to `sim/bupchip/verif/`. The game data did not move. The measurements used Rikki & Vikki's ARSC block, built locally with `sim/bupchip/make_arsc.py` and kept out of git (`.gitignore:10`, `sim/work*`). The firmware is not in the repository either: the scripts read the user's copy of MiSTer's `bupchip.hex` at `src/fpga/mister/rtl/bupchip.hex`, which is gitignored (`.gitignore:11-14`).

Every number carries a tag that says where it comes from:

| Tag | Meaning |
|---|---|
| [RTL] | Measured in RTL simulation (Verilator 5.040) running the unmodified firmware: on the study's sketch of proposal B, or on the S1 core where the text says so |
| [sim] | Measured in a stand-alone simulation of one block (iverilog) |
| [model] | Measured with the trace-driven cycle model (`sim/bupchip/model/cycles.py`). The model runs on a Python ARM model whose PCM matches MiSTer's RTL bit for bit: songs 6, 9, 10, 13 (Misery_F), 14 and 30, 4 s each, all 191,984 frames from power-up, of which 187,984 are the song's (`sim/bupchip/model/README.md`). |
| [syn] | Yosys 0.69 `synth_intel_alm` cell counts, converted to ALMs as described under "Datapath blocks" |
| [rpt] | The 2.0.21 Quartus reports. `src/fpga/output_files/` is gitignored (`.gitignore:4`), and every compile rewrites it. The figures below were copied from the build of 2026-10-03 01:45; the cited report sections are kept in `sim/bupchip/baseline-2.0.21.txt`. |
| [probe] | The step 3 Quartus probe: Quartus Prime Lite 21.1.1 compiles the S1 `bup_cpu.sv` alone, with its ROM and RAM, on 5CEBA4F23C8 in an otherwise empty device (`sim/bupchip/quartus_probe/`). The figures are from the run of 2026-10-03, and that directory's README keeps them, because the reports in `sim/work/` are gitignored. |
| [C] | Read from the code |
| [E] | Estimate |

## Goals and budget

**Goals:**
1. **Unmodified firmware.** Run CoreTone (MiSTer's `bupchip.hex`, 1,956 words) unchanged, with PCM output identical to MiSTer's. The user supplies it as `/Assets/7800/common/bupchip.bin`; nothing of it is built into the bitstream (see "Firmware load"). In simulation the same user-supplied file sits, untracked, at `src/fpga/mister/rtl/bupchip.hex`; without it the scripts skip, or refuse, the checks that run CoreTone.
2. **Throughput.** Sustain 16 MIPS of firmware work plus 25%, which is 20 MIPS.
   - The measured work on Misery_F is 15.14 MIPS on average and 15.58 MIPS in the busiest 0.1 s.
   - The worst 200-frame batch is equivalent to 17.43 MIPS.
   - The firmware's own ceiling of 16 looped voices is 17.74 MIPS [model].
3. **Clock.** Use the lowest practical clock, synchronous to `clk_sys`.
4. **Area.**
   - The whole BupChip must stay within 3,000–3,500 ALMs.
   - This design estimates 1,900–2,555 ALMs for S3, plus 40–70 with `BUP_DEBUG` [E]. That is 79.7–83.3% of the device, or 79.9–83.7% with `BUP_DEBUG`.
   - Step 9 gates S3 at ≤ 84% ALMs, but the slack gates are the real criterion. The fallback is S1 at 28.636 MHz: 1,807–2,042 ALMs, which is 79.2–80.5% of the device, or 79.4–80.9% with `BUP_DEBUG`.
   - The Quartus probe (step 3) measured the S1 CPU at 1,297 ALMs [probe], 5.5% above the top of its 960–1,230 estimate. Yosys had predicted 1,380–1,775. At the high end, with `BUP_DEBUG`, S1 sits 23 ALMs under step 5's 81% gate, and the uncounted firmware-load path (+20–30) uses that up ("Totals", risk 13). S3's CPU (1,390–1,810 [E]) is still unmeasured.
   - The worst register-file fallback is flip-flops, about +700 ALMs net of the MLABs they replace. It would put S3 at 83.6–87.3%, which breaks the gate and reaches the 85–90% zone where routing gets hard. With S1 it would break step 5's 81% gate too. S1 does not need it, because the probe found S1's register file in MLAB. The area-safe fallback is the M10K register file (CPI 1.014).
5. **Build switch.** One macro (`POCKET_BUPCHIP`) switches the BupChip in or out.
6. **Licence.**
   - All new RTL is MIT.
   - The GPL-2.0-only `arm7tdmi_core.sv` (`THIRD_PARTY_NOTICES.md:31`) is used only as a simulation oracle, never as a source.

**Budget, 2.0.21 build [rpt]:**

| Resource | Used today | This design [E; S1's CPU from the probe] |
|---|---|---|
| ALMs needed | 12,834 / 18,480, 69% (`ap_core.fit.rpt:4982`). Placement uses 14,101 (`:4984`), of which 1,328 are recoverable by dense packing (`:4989`). MLABs count here, as "[d] ALMs used for memory" (`:4988`). | S3: +1,900–2,555, giving 79.7–83.3%; +1,940–2,625 with `BUP_DEBUG`, giving 79.9–83.7%. S1, with the probe's CPU of 1,297 [probe]: +1,807–2,042, giving 79.2–80.5%; +1,847–2,112 with `BUP_DEBUG`, giving 79.4–80.9%. Neither includes the firmware-load path (+20–30, "Totals"). |
| LABs touched | 1,649 / 1,848, 89%. 199 are untouched (`fit.rpt:4998`). | S3: +194–263 LABs: 181–250 logic LABs at 10 ALMs each, plus 13 MLAB LABs. The high end exceeds the 199 untouched LABs, so the fit relies on the fitter packing existing logic more densely. |
| M10K | 46 / 308 (`fit.rpt:5024`) | +39, giving 85 |
| MLAB bits | 0 (`fit.rpt:5025`) | Register file (12 MLABs), command FIFO (1 MLAB). S1's register file: 4 MLABs, 1,024 bits [probe]. |
| DSP | 9 / 66 (`fit.rpt:5029`) | +3–4 (S1's CPU: 3 [probe]) |
| Global clocks | 5 / 16 (`fit.rpt:5033`) | +1 |
| `pll_core` counters | 3 (`pll_core.v:52`) | +1 |
| SRAM | Everything except words 0x1E000–0x1FFFF (`sram_ctrl.sv:9`) | Not used |
| PSRAM `cram0`/`cram1` | Tied off (`core_top.v:267-289`) | `cram0` die 0, assets only |
| Worst setup slack over the four corners (`ap_core.sta.summary`; slow 85 °C is the worst corner for every clock today) | `clk_sdram` +1.320 ns, `clk_74a` +2.868 ns, `clk_sys` +8.906 ns | No BupChip logic on `clk_sdram`. S1's CPU alone at 28.636 MHz: `clk_arm` +5.916 ns, at slow 0 °C [probe] |

**Why the SRAM's free 16 KiB is not used.** In 7800 mode the SRAM gets at most half an access slot per `clk_sys`, and it shares that slot with MARIA's cartridge reads (`sram_ctrl.sv:22-39`). The BupChip makes about 6.2 M data accesses a second. Block RAM is plentiful (262 blocks free).

**Note on `docs/BUPCHIP.md`.**
- The 2.0.21 resource figures are already there, at lines 288, 292–295 and 299–304 (commit `bf656d0`; the lines moved when `cedd87f` added the user-supplied files).
- What is stale is the measured-load section (lines 221–278).
  - The testbench decides "idle" from the last *fetched* address (`sim/bupchip/tb_bupchip.sv:95-97`), so it counts poll-loop branches as work.
  - The real figures are 15.14 / 15.58 MIPS, 13.5% B/BL and 9.4% conditional. The table says 15.7 / 16.0, 16.8% and 12.8%.
  - Line 249 lists RSC, which never appears in the firmware.
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
- **S1** is B's core with exact flags, at 28.636 MHz. It is delivered and verified in simulation: `src/fpga/core/bupchip/bup_cpu.sv` (step 2).
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
| ROM 4,096 words deep (16 KiB window), filled at run time from the user's `bupchip.bin` | C (depth); owner's decision (no built-in firmware) | ROM |
| Clean-room rule; reference core only as an oracle; Quartus run of the CPU alone before integration; slack and ALM gates | C | Steps |
| Retire record carrying both write ports, for lockstep | A | Verification (S1: one port, reported as E or W) |
| Region decode from the base register | B | Held in reserve as a timing fix |

**Rejected:**

| Rejected | Reason |
|---|---|
| C's 42.955 MHz clock | Least slack, and no compute need for it |
| A's NCO pop | Pitch would depend on the divider and K |
| B's two-chip 32-bit PSRAM | Only needed with B's 2-line buffer |
| B's trimmed flags | Breaks lockstep |
| A's support for data-processing writes to PC | Unused; halts instead |
| A 2,048-deep ROM | Saves 8 M10K, but caps the user's firmware file at 8 KiB |
| Building `bupchip.hex` into the bitstream | Licence unclear, like the HSC and Supercharger firmware this port already loads from files |

### Configurations

| | S1 (bring-up, fallback) | S3 (final) |
|---|---|---|
| CPI, Misery_F, 4 s | 1.383 [RTL] on the study's sketch. The S1 core: 1.377 [RTL] with zero-wait assets, 1.378 [model] with the asset cache. | 1.013 [model] |
| `clk_arm` NTSC / PAL | 28.636 / 28.375 MHz (VCO/24) | 21.477 / 21.281 MHz (VCO/32) |
| Capacity | 20.7 / 20.5 MIPS (sketch); 20.8 / 20.6 MIPS (S1 core) | 21.2 / 21.0 MIPS |
| Misery_F busy: average / busiest 0.1 s / worst batch after the song-start batch (with it) | Sketch: 73% / 75% / 82% (85%) [RTL]. S1 core: 72.8% / 75.0% / 80.4% (83.7%) [RTL; 80.4% from the model]. | 71.5% / 73.5% / 80% (83%) [model] |
| CPU / whole BupChip, MLAB LABs at 10 ALMs each (+40–70 with `BUP_DEBUG`) | 1,297 ALMs [probe] (1,257 of logic and 4 MLAB LABs; estimated 960–1,230) / 1,807–2,042 ALMs (the CPU measured, the rest [E]; see "Totals") | 1,390–1,810 / 1,900–2,555 ALMs [E]. The CPU is not measured yet. |
| Worst setup slack of the CPU alone, worst of the four corners | +5.916 ns at 28.636 MHz (slow 0 °C; +6.323 at slow 85 °C); +15.654 ns at 21.477 MHz (slow 85 °C) [probe] | Not measured yet; step 8 needs +10 ns at 21.477 MHz |

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
| Audio frame | `clk_arm` → `clk_sys` | Frame held, plus a toggle captured on `tog2 ^ tog3`, not upstream's `tog1 ^ tog2` (`bupchip_subsystem.sv:168-175`). The mute is applied on `clk_arm`, to the frame register as each frame is ticked, so `muted` does not cross (upstream applies `muted ? 0 : frame` at its `clk_sys` capture, `bupchip_subsystem.sv:173-179`). The capture gives zero while `souper_profile` is low, as upstream does. Timed. |

The toggles stay on the timed paths too. They cost about 20 ALMs [E]. If `clk_arm` ever moves to its own fPLL, the toggles still order the messages, but the held multi-bit buses (message type and payload, command byte, audio frame) then fall between asynchronous clock groups: constrain them with `set_max_skew` or `set_max_delay -datapath_only` below about two destination periods, and keep `clk_arm` above about 12 MHz so the receiver copies each message within the 5-`clk_sys` spacing. On the shared VCO none of this is needed. Nothing else crosses: under `BUP_DEBUG` the capture's sticky error flags (`clk_sys`) reach the `clk_arm` status word through two flops.

### 48 kHz

- A `clk_74a` accumulator, `acc += 8` wrapping at 12,375, gives 74.25 MHz × 8 / 12,375 = **exactly 48,000 Hz**. That is the same reference as the I2S LRCK, so there is no drift and no change between regions.
- It does not depend on the `clk_arm` divider.
- It replaces upstream's compile-time `POP_DIV` (`bupchip_subsystem.sv:136`). About 20 ALMs [E].

### Reset and hold

**The hold signal** is computed in `clk_sys` and reaches `clk_arm` through two flops:

```
bup_hold = ~pll_locked_s | pll_busy_s | ~souper_profile          (clk_sys)
cpu_run  = ~bup_hold_arm & fw_loaded & asset_ready & sweep_done   (clk_arm)
```

- `asset_ready` and `fw_loaded` are `clk_arm` flags owned by the write receiver; see "Capture" and "Firmware load" below.
- `sweep_done` makes the CPU wait for a 64-clock sweep (3 µs) after every release. The sweep restarts whenever the CPU is held. It does two things:
  - it invalidates the 64 cache tags;
  - it writes 0 to r0–r14 through write port E.
  
  The S1 core clears its own registers: for 15 clocks after its synchronous `rst` falls it writes 0 to r0–r14, then fetches from 0 (`bup_cpu.sv:70-72, 602-608`). With S1 the sweep only has the tags to invalidate.

**Held (in reset) while `cpu_run` is low:**
- the CPU;
- the peripheral and its FIFOs;
- the pop and the frame register (the output reads 0);
- the read cache's fill and prefetch state machines;
- the halt status, which the reset clears (`bup_cpu.sv:801-803`).

**Not held:**
- the capture (on `clk_sys`; only `load_start` restarts it);
- the `clk_arm` write receiver;
- `psram.sv`;
- `asset_ready` and `asset_size`;
- `fw_loaded` and the ROM's write path;
- the 48 kHz tick.

The download happens exactly while the CPU is held, so the capture writes must keep flowing. Upstream likewise resets its write path only with `reset_arm` (`bupchip_asset_ddr.sv:228-293`). The fill and prefetch machines start no PSRAM read while held, from the first held clock on. A read still in flight when hold rises finishes on its own and is discarded: the controller is busy for at most 5 clocks after `cpu_run` falls, and at most the read's halfword lands in the first held clock, in the line it was filling, whose tag is already invalid. The sweep then invalidates every tag. `sim/bupchip/s4/tb_cache.sv` and `tb_s4.sv` check all three, and `tb_cache.sv` changes the PSRAM behind every valid line during a hold (scenario G). The receiver starts a write only when the controller is idle.

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
- **Where they live.** The region decode, the exact checks and the sticky halt status are inside the CPU, `bup_cpu.sv` (region `:163-172`, checks `:493-513`, status `:129-132, 808-812`). The CPU therefore takes `asset_size` as an input (`:116`). In S1 each check runs in the clock after its access (`:566, 815`): in W for a load or a two-clock store. For a one-clock store or an STM's last beat, it runs in the next instruction's first clock, and the halt wins over that instruction. For any other LDM/STM beat, it runs in the LDM/STM's next clock.
- **Wild stores.** A store with addr[31:28] = 4 that lies beyond the 16 KiB RAM aliases into the RAM. It commits at the end of execute, one clock before W's exact check halts the core.
  - In S1 that is a one-clock store (immediate offset) or an STM beat (`bup_cpu.sv:43-46, 659-663, 742`). A two-clock store to the same address writes nothing, because the check halts the core in its W clock, which gates the write (`:697, 774-781`).
  - Upstream never writes in that case (`bupchip_memory.sv:85`).
  - It is harmless. The firmware never does it, and the core halts with the output silent either way.
  - Gating the write enable with the bounds check would put a 14-bit compare on the execute path [E].

Latencies are for S3, with S1 in brackets:

| Region | Address | Implementation | Load | Store |
|---|---|---|---|---|
| Fetch | 0x0000_0000–0x0000_3FFF | ROM 4,096 × 32, `cache_ram_dp` port A (`cache_ram.v:292`), no initial contents: filled from `bupchip.bin` at core start ("Firmware load"), 16 M10K | No added clocks: the next PC drives the M10K address | — |
| ROM data | Same | Port B: literals, the jump table at 0x1f0, the note table, `.data`, the silent sample at 0x1e38 | 1 [2] | Halt |
| Assets | 0x0200_0000 + [0, `asset_size`) | 64 × 16 B direct-mapped cache (data 2 M10K, tags 1 M10K; see "Cache") in front of PSRAM `cram0` die 0 | Hit 1 [2]. A miss adds T_hw + 3 = 8; an LDR, which needs two halfwords, adds 13. | Halt |
| RAM | 0x4000_0000–0x4000_3FFF | 4,096 × 32 with byte enables, `cache_ram_tdp_dc_be` port A (`cache_ram.v:190`), 16 M10K | 1 [2] | 1 [1; 2 with a register offset] |
| MMIO | 0xE000_9000–0xE000_90FF | `bupchip_peripheral.sv`, unmodified | 1 [2] | 1 [2] |
| Anything else | — | Halt, with code and PC in a sticky status word (`halted`, `halt_code`, `halt_pc`; see "Halt codes") | — | — |

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
  5. The replay read is presented one clock after the write of the last halfword it needs. The M10K therefore never sees a read and a write of the same address on the same edge, where its mixed-port read-during-write result would apply. The RTL (step 4) applies the rule more widely: no load completes on a port-A read registered on the same edge as a port-B write to the same data word or the same tag line. The data M10K is written a halfword at a time through byte enables, so a load may otherwise read a word whose *other* halfword is being written, and on the device the whole word is then undefined. That clock waits and the read is repeated (`bup_asset_cache.sv`, `dcol` and `tcol`).
  6. A load that hits the line under fill completes only once its halfwords have arrived. Until then it stalls like a miss, without starting a fill.
  7. The tag is written valid when the fill ends.
  8. A condition-failed asset load does no lookup and starts no fill.
- **S1's asset port.** In S1 the load's own second clock is W.
  - The cache's data and tag M10Ks take `d_addr` at the end of execute, as ROM port B and the RAM do, so that they answer in W. `bup_cpu.sv`'s header says the same: the memories answer in W from the address registered at the end of execute.
  - In W the CPU raises `w_asset`, with `w_addr` (the same address, registered) and `w_size`. The cache compares the tag and the arrival bits, answers with the aligned word on `asset_q`, and holds `w_wait` high until the halfwords the load touches are there.
  - While `w_wait` is high, the CPU keeps the ROM, RAM and asset addresses on the access, so `d_addr` stays put and the cache re-reads it (`bup_cpu.sv:76-81, 115-120, 682, 866-868`).
  - So `w_wait` is a W-clock tag compare on an M10K output, and it feeds the CPU's `done` and next-PC logic in front of `rom_addr`. The step 3 probe drives `w_wait` from a flip-flop, so it does not time this path. Step 5 does.

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

S1's states are CLEAR (the register clear after reset), RUN, W, SHR2, MUL2, MUL3 (UMULL's high word), SEQ and HALT (`bup_cpu.sv:193-202`). S1 needs no SQUASH: W is the load's own second clock, and `LDR pc` loads its data straight into the ROM's address register (`:687-690`).

**Freeze** stops execute only. It happens on an asset miss or a fill stall in W, or for the debug throttle.
- W is never frozen by the throttle. An asset load in W waits for its halfwords; every other W completes in its clock.
- Hold does not freeze the core. It resets it (see "Reset and hold").
- **S1 has two separate inputs** (`bup_cpu.sv:73-79, 97-98`). `freeze` is the throttle: it holds off the start of an instruction, and an instruction that has started always runs to its end (`:612`). `w_wait` holds W while an asset load's data is missing (`:682`). In S1, W belongs to the same instruction, so nothing else runs while it waits. The wrapper must never raise `w_wait` for an MMIO access: `reg_sel` would stay high, and the peripheral acts on every clock it sees it.

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
| LDM / STM of n registers | n+2 / n+1 | n / n |
| Unsupported encoding | Halt | Halt |

The S1 column is the delivered core's (`bup_cpu.sv:19-25`). B's sketch, on which the study measured CPI 1.383, takes the same except for LDM/STM: n+3 / n+2, with an extra first clock in its sequencer (`sim/bupchip/model/study/sketch/bup_cpu.sv:304-306, 324-331`). An S1 store with an immediate offset takes 1 clock only to RAM; to MMIO it takes 2.

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

| Class | Share | S1, the study's sketch, clocks each [model] | S1 core, zero-wait assets, clocks each [model] | S3 clocks each [model] |
|---|---|---|---|---|
| Data processing, register | 26.9% | 1.00 | 1.00 | 1.000 |
| LDRH / STRH / LDRSB / LDRSH | 26.4% | 1.72 | 1.68 | 1.005 |
| LDR / STR | 14.1% | 1.68 | 1.68 | 1.000 |
| B / BL | 13.5% | 1.00 | 1.00 | 1.000 |
| Data processing, immediate | 10.2% | 1.00 | 1.00 | 1.000 |
| MUL / MLA | 8.7% | 2.00 | 2.00 | 1.000 |
| LDM / STM | 0.19% | 8.06 (see below) | 8.56 | 7.06 |
| BX | 0.12% | 1.00 | 1.00 | 1.000 |
| **CPI** | | **1.383 [RTL]** (model: 1.387) | **1.3772 [RTL]** (model: 1.377) | **1.013 [model]** |

**Notes on the table:**
- The model agrees with the RTL to within 0.3% on the sketch, and to within 0.1% on the S1 core. That supports using the model for S2 and S3.
- The sketch's column comes from `cycles.py`'s `S1-sketch`, which charges LDM n+2 with write-back and n+1 without, and STM n (`sim/bupchip/model/cycles.py:51-52`). The sketch's RTL takes n+3 and n+2, which is about 9.6 per instruction [E]. That column therefore undercounts LDM/STM by about 0.003 CPI.
- The S1 core takes LDM n+2 and STM n+1 (`bup_cpu.sv:25`), modelled as `S1`. Its halfword loads cost less than the sketch's only because `tb_s1.sv`'s asset memory answers at once, where the sketch's stream buffer stalls. With the design's asset cache instead, the S1 core's CPI is 1.378 [model].
- The figures are from `cycles.py ... --song 13 --secs 4` (`sim/bupchip/model/README.md`).
- In S3, LDM/STM account for about 1.3% of clocks (0.19% × 7.06 / 1.013).
- In S3, asset stalls account for 0.13%.

### Required clock

| Configuration | CPI | Misery_F MHz at 100% busy: average / busiest 0.1 s / worst batch after the song-start batch (with it) | Lowest clock without FIFO underrun (1,024 frames) | MHz for 20 MIPS | At the chosen clock |
|---|---|---|---|---|---|
| S1, the study's sketch | 1.383 [RTL] | 20.93 / 21.53 / 23.35 (24.33) | 21.49 [model] | 27.7 | 28.636 MHz → 20.7 MIPS |
| S1 core, zero-wait assets | 1.3772 [RTL] | 20.86 / 21.48 / 23.03 (23.98) [RTL; 23.03 from the model] | 21.23 [model] | 27.5 | 28.636 MHz → 20.8 MIPS |
| S1 core with the asset cache | 1.378 [model] | 20.89 / 21.50 / 23.19 (24.11) | 21.25 | 27.6 | 28.636 MHz → 20.8 MIPS |
| S2 | 1.103 [model] | 16.72 / 17.18 / 18.55 (19.29) | 16.99 | 22.1 | — |
| **S3** | **1.013 [model]** | **15.35 / 15.78 / 17.14 (17.87)** | **15.59** | **20.25** | **21.477 MHz → 21.2 MIPS** |
| S3 without load→multiplier forwarding | 1.096 [model] | 16.62 / 17.08 / 18.45 (19.18) | 16.89 | 21.9 | 21.477 MHz → 19.6 MIPS |
| S3 without load forwarding, 2-clock MUL | 1.189 [model] | 18.02 / 18.55 / 20.07 (20.88) | 18.33 | 23.8 | 28.636 MHz → 24.1 MIPS |

- The [model] rows are `cycles.py` with the design's asset cache unless the row says otherwise (`sim/bupchip/model/README.md`; re-run 2026-10-03). The sketch's row is its RTL run (`sim/bupchip/model/study/README.md`) with the lowest clock from the model's `S1-sketch` with the stream buffer.
- S2 is the model of S2 as defined above. The study's S2 figure, CPI 1.116, came from a variant with LDM n+1, 2-clock MMIO stores and the stream buffer's stalls; it was about 1.2% high.

**Other loads under S3:**

| Load | Result |
|---|---|
| Boss_S | CPI 1.017 |
| Title | CPI 1.021 |
| 16 looped voices (synthetic) | Needs 17.92 MHz, 83% of 21.477 [model] |
| Song-start batch | Absorbed by the FIFO |

**FIFO level at 21.477 MHz.** The lowest level on Misery_F is 657 frames (NTSC) and 655 frames (PAL), about 13.7 ms, over its first 4 s [model]; over its whole length it is 614 (see below).

**Full-length sweep (2026-10-04).** The figures above come from each song's first 4 s. `sim/bupchip/model/sweep.py` (Unicorn, about 1 s of wall time per second of music) played all 32 songs of Rikki & Vikki from their commands until each ended, or its whole machine state repeated (an exact loop), or 10 minutes. Two songs peak later than their opening:

| Song | Busiest 0.1 s / worst batch, MIPS (first 4 s) | Whole length | Where | Lowest clock without underrun, S1 / S3 | Lowest FIFO level at 28.636 (S1) / 21.477 (S3) |
|---|---|---|---|---|---|
| 13 Misery_F | 15.58 / 16.69 | 17.61 / 19.04 | 32 s; loops every 49.1 s from 38.9 s | 23.78 / 17.47 MHz [model] | 620 [model], **639 [RTL, 40 s]** / 614 [model] |
| 24 Never_Lose | 1.6 / 1.9 | 17.68 / 18.34 | 17 s; still changing at 10 min | **23.98 / 17.55 MHz** [model] | 643 [model], **648 [RTL, 20 s]** / 647 [model] |
| the other 30 | | ≤ 14.4 busiest 0.1 s | | | |

- Never_Lose, not Misery_F, sets the lowest clock: 24.0 MHz for S1 (28.636 MHz has 19% to spare) and 17.6 MHz for S3 (21.477 MHz has 22% to spare). Both stay inside the 16-voice bound.
- Single batches at Misery_F's peak need up to 29.0 MHz on S1 and 22.5 MHz on S3 [model]; the FIFO absorbs them.
- The RTL runs (`sim/bupchip/s4/run_s4.sh`, the full download, PSRAM and cache path on S1) give 0 underflows and PCM bit-identical to the sweep's for all 1,919,800 and 959,800 song frames; the sweep matches MiSTer's references exactly where they exist (the first 4 s of songs 6, 9, 10, 13, 14 and 30).
- Step 9's throttle test should use Never_Lose and Misery_F past their peaks, not Misery_F's opening.

## Datapath blocks

ALM estimates use ALM ≈ (0.6–0.8) × LUT + 0.5 × arithmetic cells, plus 10 ALMs per MLAB LAB.
- The rule was checked against Quartus on `a78_cart_extent`: 106.5 predicted, 106.4 fitted.
- It under-predicts flip-flop-heavy logic by 11–32% (`sram_ctrl`).
- It over-predicts the S1 core by 7–38%. Yosys counts 1,885 LUT + 453 arithmetic cells ("Totals"), which the rule turns into 1,340–1,735 ALMs of logic. Quartus fits 1,257.3 (`bup_probe.fit.rpt`, 28.636 MHz) [probe]. The implied LUT factor is (1,257 − 0.5 × 453) / 1,885 = 0.55, below the rule's 0.6–0.8. Other [syn→E] figures converted this way, such as the cross-check of A's sketch (1,270–1,600) and the [syn] parts of the S3 CPU estimate, may be high as well. The per-block estimate for S1 (960–1,230) went the other way: it came out 5.5% low at its top end.
- Quartus counts each MLAB LAB in "ALMs needed" ("[d] ALMs used for memory", `fit.rpt:4988`). The probe shows it: 20 ALMs for each 16 × 32 bank of 2 MLABs. The totals below therefore include MLAB LABs in the ALM column.
- The per-block [syn] figures below are the study's. `sim/bupchip/model/study/area/parts.sv` keeps other forms of most blocks, and `run_area.sh` gives different counts for them: shifter 332 LUT + 7 arithmetic cells (shift and mask) or 192 + 239 (one rotator), multiplier 0 + 160 with 4 DSP, load lanes 48 LUT, LDM/STM priority encoder 42 LUT, peripheral at CMD 8 / PCM 1,024 54 + 59. Only the ALU (130 + 34) matches. The whole-core count of the S1 core under "Totals" is the better guide.

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

The bypass means the array is only ever read for data written at least two clocks earlier. Correctness therefore does not depend on when the MLAB physically writes. That timing is not verified for this device, and no MLAB is used today (`fit.rpt:5025`). The probe (step 3) confirms the read side for S1. Each of its two 16 × 32 banks is an MLAB `altdpram`, Simple Dual Port, with registered write inputs and an unregistered read address and output, in 2 MLABs [probe]. The critical path runs straight through the MLAB read, from `portbaddr` to `portbdataout` (0.66 ns).

**S1** keeps its register file inside `bup_cpu.sv` (`:318-357`): one write port, two asynchronous read ports, and last clock's write held and bypassed. The clear after reset uses the same write port (see "Reset and hold"). In plain simulation the behavioural array shows a write on the next clock, so nothing would exercise the bypass. The simulation-only build `BUP_SIM_LATE_RF` (`LATE_RF=1` in the scripts) therefore makes each entry hold garbage for the clock after its write. `sim/bupchip/s1/check.sh` runs the directed, halt and ISA lockstep tests in that build too, and with the bypass removed all 13 of `sim/bupchip/s1/`'s directed tests fail there (`sim/bupchip/s1/README.md`).

**Cost:**
- 12 MLAB LABs, about 120 ALM-equivalents [E].
  - A Cyclone V MLAB has one write address and one read address, and is at most 20 bits wide (32 × 20).
  - So each 16 × 32 bank needs two MLABs, and banks cannot share one.
- 150–200 ALMs of table, bypass and forwarding multiplexers [E], plus 10–20 ALMs for the clear [E].
- S1 uses 1 write port and 2 read banks: 4 MLAB LABs, about 40 ALM-equivalents. The probe measured exactly that: 4 MLABs, 1,024 bits, 40 ALMs [probe].

**Fallback:**
- A flip-flop file costs about +800 ALMs [syn: the whole-core sketch went from 1,631 to 2,865 LUTs and from 123 to 587 FF]. Net of the 12 MLAB LABs it replaces, that is about +700. With S3 it breaks the step 9 ALM gate (83.6–87.3%). With S1 (79.4–80.9% with `BUP_DEBUG`) it breaks step 5's 81% gate. S1 does not need it, because its register file is in MLAB (step 3).
- Alternatively, an M10K register file with one more pipeline stage: CPI 1.014 [model]. This is the area-safe fallback.

### Fetch, decode and control

- **PC.**
  - A 12-bit word address within the ROM window.
  - The `npc` mux takes: PC + 1, branch target, BX Rm, `LDR pc` data from W, or hold.
  - A target outside the window halts, and so does one that is not word-aligned. The check runs one clock later.
  - So does running on past the last ROM word, 0x3FFC, where the ARM7TDMI's fetch from 0x4000 would abort; S1 does not wrap to 0 (`bup_cpu.sv:765-771`).
- **Decode** works straight from the ROM's unregistered output. Register indices are raw instruction bits behind one mux level. `condition_pass` comes from `arm7tdmi_pkg.sv:82-111`.
- **Supported encodings** are the firmware's inventory of 1,704 code words:
  - all 16 data-processing opcodes with every operand-2 form;
  - MUL, MLA and UMULL without the S bit;
  - every LDR/STR, LDRB/STRB and LDRH/STRH/LDRSB/LDRSH addressing mode (LDRT/STRT act as LDR/STR, since there is one privilege level);
  - LDM/STM without S, without PC in the list, and with a non-empty list;
  - B, BL, BX;
  - MRS CPSR, and MSR CPSR from a register or immediate, to the f and c fields only. The f field writes NZCV, and bits 27:24 must be 0. The c field must write the fixed control byte 0xD3. The firmware's one MSR, at 0x2c, does exactly that.
- **Everything else halts:**
  - SWP, SWI, coprocessor and undefined encodings;
  - SPSR access, and MSR of the x or s field;
  - S-bit multiplies, SMULL, UMLAL, SMLAL;
  - data processing with Rd = PC, write-back to PC, and PC in register-shift or store-data positions;
  - BX to a Thumb address (bit 0 set).
  
  The halt codes below list every case.
- **Cost:** 300–450 ALMs including the state machine [E].

**Halt codes.** A halt stops the core and records a code and the address of the instruction responsible in `halt_code` and `halt_pc`. They stay until the next reset (`bup_cpu.sv:48-67, 149-155, 801-812`). A decode halt needs the instruction's condition to pass: a condition-failed halting encoding takes one clock and does nothing, as on the reference (`:566`). A fault found by an earlier clock's check wins over the instruction then in execute (`:565-568`).

| Code | Name | Meaning | Instructions (S1) |
|---|---|---|---|
| 1 | UNDEF | Encoding outside the subset | SWP, SWI, coprocessor and undefined encodings; ARMv5 forms such as BLX (register), CLZ, QADD, BKPT and LDRD/STRD; SPSR access; MSR of the x or s field; MRS, MSR and BX whose should-be-one or should-be-zero bits differ from the ARM ARM's encoding (other should-be-zero fields are ignored, as on the ARM7TDMI: `sim/bupchip/s1/directed/sbz.S`); MULS, MLAS and every long multiply but UMULL without S; LDM/STM with S, with PC in the list or with an empty list. One clock later: MSR writing a control byte other than 0xD3, or nonzero bits 27:24 (`:310, 630-638`). |
| 2 | REG | r15 where the ARM7TDMI reads PC + 12 or the result is UNPREDICTABLE | Data processing with Rd = PC, or with PC as Rm, Rs or Rn of a shift by register; PC as any register of MUL, MLA or UMULL, and UMULL with RdHi == RdLo; PC as a write-back base, an LDM/STM base, a register offset or a store's data; LDRB, LDRH, LDRSB or LDRSH into PC; BX PC; MRS into PC; MSR from PC (`:264-315`) |
| 3 | THUMB | BX to a Thumb address | BX with bit 0 of Rm set (one clock later, `:648-652`) |
| 4 | FETCH | Next PC outside the ROM | B, BL, BX or `LDR pc` to a target outside 0x0000–0x3FFF or not word-aligned (`LDR pc` with bit 0 set too: ARMv4 does not interwork there); running on past 0x3FFC. All one clock later (`:639-652, 687-690, 765-771`). |
| 5 | DATA | Load or store outside every window | A load outside the ROM, the asset window below `asset_size`, the RAM and the MMIO window; a store outside the RAM and the MMIO window, other than RO's range below. A wild store to 0x4xxx_xxxx is first written to the RAM's alias ("Memory map"). Checked one clock later (`:493-513`). |
| 6 | RO | Store to read-only memory | A store or an STM beat to 0x0000_0000–0x0FFF_FFFF, which holds the ROM and the asset window |
| 7 | BLOCK | LDM/STM outside the ROM and RAM | An LDM beat outside the ROM and the RAM; an STM beat outside the RAM, other than RO's range |

`sim/bupchip/s1/halt_tests.py` (66 cases) and `sim/bupchip/verif/directed/vhalt.py` (47 halt cases and 20 that must not halt) check each code at its instruction. The fuzz checks that every DATA or RO halt matches a reference abort in the same instruction (`sim/bupchip/verif/directed/README.md`).

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

- **Address:** Rn plus or minus a 12-bit immediate, a split 8-bit immediate, or a shifted Rm (pre-index); or Rn alone (post-index). Write-back goes through port E in execute. (S1 writes a two-clock store's base back at the end of W, the clock in which it reads the store data, `bup_cpu.sv:380, 696-701`.)
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
- **S1** takes LDM n+2 and STM n+1: execute computes the write-back value and the start address, the base is written in the first beat, and LDM's last register lands one clock after the last beat (`bup_cpu.sv:736-761, 840-861`). Its order of base and data writes is the same as described here.
- **Base register in the list.** Writing the base in the first clock gives ARM7's results without special cases: for LDM the loaded value wins; for STM the first beat stores the old base and later beats store the new one. The firmware never does this.
- **Cost:** 80–200 ALMs [E; 246 LUT + 109 arithmetic cells is an upper bound, syn].

### Totals

| Part | ALMs [E] | M10K | Other |
|---|---|---|---|
| CPU, S3: logic 1,270–1,690 (blocks above) + 12 MLAB LABs (120) | 1,390–1,810 | — | 3–4 DSP |
| ROM, 4,096 × 32 | ≈0 | 16 | — |
| RAM, 4,096 × 32 with byte enables | ≈0 | 16 | — |
| Peripheral, CMD 8 / PCM 1,024 (reused): 70–85 [syn] + 1 MLAB LAB | 80–95 | 4 | — |
| Bus glue, watermark remap, halt status (in S1 the region decode and halt status are inside `bup_cpu.sv`, and in the probe's 1,297, so S1's total counts them twice) | 40–70 | — | — |
| Asset cache, prefetch, fill state machine, per-halfword arrival bits | 140–210 | 3 | — |
| PSRAM controller | 60–100 | — | — |
| ARSC capture, byte-pair packer, message stream, `clk_arm` receiver, `asset_ready` | 100–130 | — | — |
| Crossings, 48 kHz tick, frame return with mute, hold, `pll_locked` sync | 60–80 | — | — |
| `top.sv` mixer once the audio is live (difference) | 30–60 [syn] | — | — |
| **Total** | **1,900–2,555** | **39** | 3–4 DSP |
| `BUP_DEBUG`: status word, shadow FIFO counters, throttle | +40–70 | — | — |
| CPU, S1, measured in place of the S3 CPU row: logic 1,257.3 + 4 MLAB LABs (40), at 28.636 MHz [probe] | 1,297 | — | 3 DSP |

- **Firmware load path** (packer, extra message types, ROM writes, `fw_loaded`; added after the study when the firmware became user-supplied): +20–30 ALMs [E], about 0.15% of the device. The totals and percentages in this document do not include it.
- **Device total:** 14,734–15,389 ALMs (79.7–83.3%), or 14,774–15,459 (79.9–83.7%) with `BUP_DEBUG`, and 85 of 308 M10K.
- **S1 total:** 1,807–2,042 ALMs: the probe's CPU of 1,297, with its 4 MLAB LABs [probe], plus 510–745 [E] for the other rows. That is 79.2–80.5% of the device, or 79.4–80.9% (14,681–14,946 ALMs) with `BUP_DEBUG`.
  - Step 5's 81% gate is 14,968.8 ALMs, 22.8 above the high end. The firmware-load path (+20–30) takes the high end to 80.98–81.04%, so S1 is at the gate.
  - The bus-glue row counts the halt status a second time, so the high end is slightly pessimistic.
  - Before the probe the estimate was 1,470–1,975 (CPU 960–1,230): 77.4–80.1%, or 77.6–80.5% with `BUP_DEBUG`.
- **The S1 core in Yosys.** `sim/bupchip/model/study/area/run_area.sh s1_core` counts the delivered `bup_cpu.sv` as Quartus would see it (`ALTERA_RESERVED_QIS`, so no retire port).
  - Result: 1,885 LUT + 453 arithmetic cells + 311 FF, 64 MLAB cells and 4 DSP [syn] (`sim/bupchip/model/study/README.md`; reproduced 2026-10-03). ABC moves the LUT count by a percent or two; another run gave 1,858.
  - By the rule above that is 1,340–1,735 ALMs of logic, or 1,380–1,775 with the 4 MLAB LABs [syn→E]. That is about 44% above the 960–1,230 estimated from B's sketch, which the same script counts at 1,178 LUT + 297 arithmetic cells + 155 FF.
  - Quartus does not confirm it. The probe fits 1,257.3 ALMs of logic, or 1,297.3 with the MLAB LABs [probe]. That is 5.5% above the top of the 960–1,230 estimate and below the whole Yosys range: the rule over-predicts this core ("Datapath blocks").
  - S3's CPU estimate (1,390–1,810, from A's sketch) is still unmeasured. The probe is re-run with S3's register file (step 3), and step 8 compiles the S3 CPU.
- **LABs.**
  - The BupChip (S3, debug build) needs about 181–250 logic LABs at 10 ALMs each, plus 13 MLAB LABs: 194–263 LABs in all.
  - 199 LABs are untouched today (`fit.rpt:4998`). The upper part of the range therefore depends on the fitter packing existing logic more densely, as it does when the device fills (1,328 ALMs recoverable, `fit.rpt:4989`).
  - MLABs can only go in memory-capable LABs (up to half of all LABs, `fit.rpt:5000`), and today those hold logic.
  - Steps 3, 5 and 9 record "Total LABs", "Memory LABs" and the dense-packing estimate.
  - In the probe's empty device the S1 CPU spreads over 180 logic LABs plus its 4 MLAB LABs (176 + 4 at 21.477 MHz), and the whole probe touches 199 LABs (195 logic, 4 memory; 196 at 21.477 MHz) [probe]. That fit is sparse. Packed at 10 ALMs a LAB, the CPU's 1,257 ALMs of logic would fill about 126 LABs (derived from ALMs, not measured). This document had no S1 LAB estimate to compare against.
- **Cross-check:** A's whole-core Yosys sketch, 1,631 LUT + 585 arithmetic cells + 123 FF, converts to 1,270–1,600 ALMs of logic [syn→E]. Its register file was in MLAB, so that figure excludes the MLAB LABs. The rule over-predicted the S1 core, so this may be high too.

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
| 13 | `LDR pc` without interworking | Jump table at 0x1ec | W data drives `npc`, then SQUASH (S1 needs no SQUASH). A target with bit 0 or 1 set, or outside the ROM, halts (FETCH). |
| 14 | BX to an ARM address; bit 0 set means Thumb | 63 BX | Bit 0 set halts (THUMB); bit 1 set or a target outside the ROM halts (FETCH) |
| 15 | BL link = the BL's address + 4 | 34 BL | Port E |
| 16 | MLA: Rd in [19:16], accumulator Rn in [15:12] | Mixer | P1 index mux |
| 17 | UMULL: unsigned 64-bit result, RdLo [15:12], RdHi [19:16] | 0x300, 0x1b20 | Unsigned DSP product |
| 18 | LDM/STM order and start addresses; `stmib` without write-back starts at base + 4 | Push/pop; `stmib sp,{r0,r1}` at 0x888 | Sequencer |
| 19 | Rd == Rn with write-back; base register in the list | Never | ARM7 results by construction; directed tests |
| 20 | MRS CPSR = `{NZCV, 20'b0, 8'hD3}`; MSR CPSR_f writes NZCV; MSR CPSR_c may only write the byte it already holds, 0xD3 | 0x20–0x2c: `mrs`, `bic #31`, `orr #0xd3`, `msr CPSR_c` | Constant mode bits. A control byte other than 0xD3, nonzero bits 27:24, the x or s field, or SPSR halts (UNDEF; `bup_cpu.sv:310, 629-638`). |
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
- `psram.sv` defines `` `MAX`` (`:30`), which `data_loader.sv:61` also defines, and declares `rtoi` at compilation-unit scope (`:25-27`). The two `` `MAX`` definitions are identical, and Quartus 21.1 builds both files without a redefinition warning (step 5's map report).

### Firmware load

The firmware is the user's file `/Assets/7800/common/bupchip.bin` (format and checksums: `BUPCHIP.md`, "Files the user supplies on the Pocket"). Nothing of it is in the bitstream.

- **Slot.** Data slot `0x109`, loaded once when the core starts, like the HSC and Supercharger firmware (`data.json` slots `0x106`/`0x107`). Parameters `0x88`: not reloadable, so it takes no menu row (`DEVELOPING.md`, "Menu limits").
- **Path.** The bytes come through the loader on `clk_sys`, exactly like the cartridge's, and are told apart by their own bridge address ("Which bytes are the BupChip's" below). `bup_capture` packs four bytes into a little-endian word and sends the same message stream the asset capture uses: FWSTART, one FWWRITE per word (word address and data), FWEND with the byte count. Words arrive at most every 698 ns, far slower than the asset halfwords the receiver already handles.
- **Writes.** The `clk_arm` receiver writes each word into the ROM through `cache_ram_dp` port B, which has a write port (`cache_ram.v:292-311`). FWSTART clears `fw_loaded`, so the CPU is held and port B carries no CPU reads while the ROM is written. FWEND sets `fw_loaded` if at least 8 bytes arrived; a trailing partial word is zero-padded. Bytes past 16 KiB are dropped.
- **Lifetime.** `fw_loaded` and the ROM contents survive cartridge loads, console resets, holds and PAL retunes. Only a new firmware download (a core restart) clears them.
- **Without the file,** `fw_loaded` stays low and the CPU stays held: Souper games run with the BupChip silent, and the output reads 0 as for any hold.
- **A wrong file** runs until the CPU meets an encoding it does not implement and halts, or until the firmware's own start-up checks write a fault. Either way the output is silent.
- **Cost.** About 20–30 ALMs for the packer, the extra message types and `fw_loaded` [E]. The ROM still needs no MIF, and its 16 M10K are unchanged.

### Capture (on `clk_sys`) and the write receiver (on `clk_arm`)
1. The declared size comes from header bytes 49–52, and the block starts at 128 + the declared size. This is copied from `bupchip_asset_ddr.sv:82-104` (MIT).
2. Bytes are packed in pairs into halfword writes; an odd tail is written with UB/LB.
3. `asset_size` is the number of bytes captured.
4. The capture sends an ordered message stream to `clk_arm`, through one held register and a toggle:
   - START, at `load_start`;
   - one WRITE per halfword;
   - END, carrying `asset_size`, when the cartridge's window closes (below).
   
   Consecutive messages are at least 5 `clk_sys` clocks (349 ns) apart. Every message waits in a flag until the spacing allows it, WRITE and FWWRITE with their payloads in one-entry registers (a WRITE at most 4 clocks, an FWWRITE at most 9). The order of priority is WRITE, FWSTART, FWWRITE, START, the tails, FWEND, END. A cartridge's last bytes can arrive after the firmware slot has started, so a WRITE can find another message just sent, and the firmware slot can start while that cartridge's tail WRITE and END still wait. A firmware byte that arrives in the clock the slot's download flag rises starts the first word.
   
   **Which bytes are the BupChip's.** Every byte carries its own bridge address, and `data.json`'s slot addresses differ in bits 27:25: 0 for the cartridge (`0x00000000`), 5 for `bupchip.bin` (`0x0A000000`). `core_top` passes those bits and the loader's raw byte strobe to `bupchip_pocket`, which hands the capture the bytes carrying the cartridge's or the firmware's address, whatever slot flag is up. Each download takes them while its window is open: from `load_start`, or the firmware flag rising, until 64 `clk_sys` (4.5 µs) after `load_end`, or the flag falling. END, the tails and FWEND leave when the window closes. The slot flags themselves move when the host's next requestwrite, or its allcomplete, reaches `core_top`, and the loader can still hold up to four bytes of the slot before then (its 4-entry FIFO and 10-`clk_sdram` read machine, about 50 `clk_sdram`): taken by flag, those would go to the next slot's download, and the slot would lose them. `sim/bupchip/s4/stress/run_slotswitch.sh` shows that happening when the host's next request comes within about 0.4 µs of a slot's last bridge write. The tester's Pocket leaves more than 286 µs (step 5, test2), so on it this is a safeguard, not a fix. 64 clocks is several times the loader's drain.
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

- The chain is longer than the 349 ns spacing. `psram.sv` latches the address, data and byte lanes when it accepts a request, so the receiver's copy of each message (a one-entry buffer) matters only if a WRITE has to wait for a busy controller when the next message arrives. At the loader's rate that never happens: START holds the CPU, so cache reads and capture writes never overlap. The copy, END's wait for an idle controller and the arbiter's write priority are defensive paths that no bench reaches.
- With the copy, write k finishes ≤ 376 ns after its toggle. Message k+1 cannot be seen before 349 + 94 = 443 ns.
- So the controller is idle whenever a message arrives, busy 5 of every ≥ 7.4 clocks (68%), and needs no second entry and no backpressure [E]. Step 4 checks this with the loader at 175 ns per byte.

### Cache
- 64 lines × 16 B, direct-mapped:
  - index: offset[9:4];
  - tag: offset[22:10] plus a valid bit.
- **Data:** 256 × 32, written 16 bits at a time from PSRAM and read 32 bits at a time by the CPU. It is `cache_ram_tdp_dc_be`, a true dual-port `altsyncram` (`cache_ram.v:190`; the step 3 probe confirms Quartus keeps that mode for a port that never writes), and an M10K in true dual-port mode is at most 20 bits wide, so it takes 2 M10K. A simple dual-port wrapper (port A read, port B write) would hold it in one; that is not worth a new RAM wrapper while M10K is plentiful (85 of 308). Step 5's fit report confirms the count.
- **Tags:** one M10K. Port A does the CPU lookup. Port B does the prefetch probe and the tag writes (invalid at fill start, valid at fill end).
- **Fill state:** line index, tag, demand or prefetch, and 8 per-halfword arrival bits. Only one fill runs at a time.
- Tags are invalidated by the 64-clock sweep after every hold.

### Miss and prefetch
- **A miss** fills the critical halfword first, then wraps around the line. W completes as described under "Memory map": once the halfwords the load touches have arrived, with the replay read one clock after the last of them is written. A hit on the line under fill waits the same way.
- **Prefetch:** after every asset access, the next line is probed. If it is absent and no fill is running, it is fetched from halfword 0. In the RTL the newest access's next line waits in one register until no fill is running, then is probed (newest wins); it is not dropped.
- **Pre-emption.** A demand miss to a line other than the one being filled waits for the halfword in flight (≤ 5 clocks; `psram.sv` cannot abort a read). It then pre-empts the fill. The pre-empted line's tag stays invalid, as written when that fill started.
- The cycle model does not pre-empt. There, a demand miss waits for the whole fill in flight, and those waits are part of its 0.13% stall clocks. It does not count them separately. It does count 692 late hits in 4 s: loads that hit a line still being filled. Step 4 compares the two on Misery_F and keeps pre-emption only if it stalls less. In the RTL a demand miss pre-empts any running fill: a prefetch, or the rest of an earlier demand fill.

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
  - The lowest level under load is 664 frames (the study's S1 sketch at 28.636 MHz [RTL]; 660 on the S1 core with zero-wait assets [RTL]) and 657 frames (S3 at 21.477 MHz [model]).
- **Pop.** `pop = tick48k & pcm_enabled & !pause`. `pause` is tied to 0 today.
  - An empty FIFO plays 0 (as in `bupchip_subsystem.sv:144-164`).
  - The peripheral raises `pcm_available` in the clock after a push into an empty FIFO, a clock before its M10K presents that frame (upstream's subsystem has the same race). A tick that lands in a clock where `pcm_available` has just risen waits one clock (`tick_hold`), so a stale head is never played. CoreTone at speed never lets the FIFO run empty, so `sim/bupchip/s4/stress/run_pophead.sh` checks this with firmware of its own that pushes single frames into the empty FIFO at every tick phase, with a tick also forced onto that clock; a wrapper without `tick_hold` fails it.
  - Ticks keep running while the BupChip is held, with the frame forced to 0, so the output reads 0 within one tick of any hold.
  - A FAULT write sets the peripheral's `muted` output (`bupchip_peripheral.sv:175-180`), but the peripheral does not zero `pcm_frame`. The wrapper ticks 0 into its frame register while `muted` is set, on `clk_arm`, so `muted` never crosses to `clk_sys`. Upstream applies `muted ? 0 : frame` at its `clk_sys` capture instead (`bupchip_subsystem.sv:173-179`); the only difference is the one frame ticked just before a FAULT write and captured after it, which plays here. The `clk_sys` capture zeroes the output while `souper_profile` is low, as upstream's does. `top.sv` also gates the mix on `souper_profile` (`:649-652`). `sim/bupchip/s4/stress/run_pophead.sh` checks the mute end to end (a FAULT write after frame M: every later frame 0).
- **Output path.** The frame register crosses to `clk_sys` with the mute applied, becomes `bupchip_audio_l/r`, and goes through the existing gain, saturation, midpoint and halving (`top.sv:641-668`, `ext_audio` at `:220`). The levels are therefore MiSTer's.
- **Command FIFO.** The firmware never reads register 0x08 and pops once per main-loop pass, so it cannot see the depth.
- **Debug counters.** The peripheral's sticky overflow and underflow bits and its FIFO levels are internal (`bupchip_peripheral.sv:60, 85, 89`). Its ports (`:24-51`) export only `reg_rdata`, `pcm_frame`, `pcm_available`, `pcm_enabled`, `muted` and `fault_code`. Under `BUP_DEBUG` the wrapper therefore keeps shadow counters:
  - **CMD level:** +1 on `cmd_valid`; −1 on a committed read of 0x04 while the level is non-zero; set to 0 by a write of 0x0C with bit 1 set. Command overflow = `cmd_valid` at level 8.
  - **PCM level:** +1 on a committed write of 0x10 below 1,024; −1 on a pop while not empty. PCM overflow = a push at 1,024. Underflow = a pop while `pcm_available` is low.
  - **Lowest PCM level** while `pcm_enabled` is set, from the first time the FIFO reaches its watermark (the boot's prefill), since every boot starts from an empty FIFO.
  - The flags are sticky until the next hold. Simulation checks every shadow counter against the peripheral's internal one through hierarchical references, which are allowed in simulation only. About 40–70 ALMs with the throttle [E].
- **Fallback:** the `PCM_DEPTH = 4096` parameter without the remap (16 M10K).

## Integration

### New files: `src/fpga/core/bupchip/`

| File | Contents |
|---|---|
| `bupchip_pocket.sv` | Wrapper: hold and reset, `pll_locked` sync, crossings, ROM/RAM instances, watermark remap, peripheral instance, frame return with mute, status word (from the CPU's halt outputs), shadow FIFO counters, debug throttle |
| `bup_cpu.sv` | The CPU: S1 (delivered, step 2), later S3. It also holds the region decode, the exact window checks (which is why it takes `asset_size`), the sticky halt status, and in S1 the register file. |
| `bup_regfile.sv` | Live-value-table register file with bypass and the clear after hold (S2/S3; S1 keeps its one-write-port file inside `bup_cpu.sv`) |
| `bup_asset_cache.sv` | Tags, data, per-halfword arrival bits, fill and prefetch state machines (held by `bup_hold`) |
| `bup_asset_wr.sv` | `clk_arm` message receiver: `asset_ready` and `asset_size` (also an input of `bup_cpu`), ROM writes and `fw_loaded`, PSRAM arbitration between writes and fills (not held) |
| `bup_capture.sv` | ARSC header parse, byte-pair packer, firmware word packer, START/WRITE/END and FWSTART/FWWRITE/FWEND message stream (`clk_sys`) |
| `bup_tick48k.sv` | The `clk_74a` accumulator and toggle |
| `bup_status_osd.sv` | `BUP_DEBUG` only: the status word drawn over the picture's top-left corner, so a hardware test can read it (step 5; instantiated in `atari7800_pocket.sv`) |
| `bup_load_probe.sv` | `BUP_DEBUG` only: counts and times what the loader delivers around the slot switches (bytes of another slot's address under a flag, bytes taken after a flag fell, bytes dropped, the gaps), for the overlay |

**`bup_cpu` ports (S1, `bup_cpu.sv:94-148`).** The wrapper of step 4 connects these:

| Group | Ports |
|---|---|
| Control | `clk` (`clk_arm`); `rst`, synchronous, held while `cpu_run` is low; `freeze`, the throttle; `w_wait`, the asset data is missing |
| Fetch | `rom_addr` (12-bit word address, the next PC) to ROM port A; `rom_q` back, unregistered |
| Data | `d_addr` to ROM port B and RAM port A (`[13:2]`), and to the asset cache's data and tag M10Ks, which must answer in W like the others; `ram_we`, `ram_be`, `ram_wdata`; `rom_dq`, `ram_q` back |
| Assets | `asset_size` in; `w_asset`, `w_addr`, `w_size` out; `asset_q` in, the aligned word; `w_wait` (under Control) is the cache's W-clock tag compare, which feeds the CPU's next-PC logic in front of `rom_addr` |
| MMIO | `reg_sel`, `reg_addr`, `reg_write`, `reg_wdata` to the peripheral; `reg_rdata` back |
| Status | `halted`, `halt_code`, `halt_pc`, sticky until `rst` |
| Retire (simulation only) | `rt_start`, `rt_valid`, `rt_pc`, `rt_insn`, `rt_nzcv`, `rt_e_we/idx/data`, `rt_w_we/idx/data` |

Also:
- `src/fpga/pocket_utils/psram.sv`: agg23, MIT, vendored unmodified, instantiated with `CLOCK_SPEED = 28.636364`.
- The ROM has no initial contents. Nothing from `bupchip.hex` or `bupchip.mif` is built in; the firmware arrives through the data slot below.

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
| `core/atari7800_pocket.sv` | Add `ifdef POCKET_BUPCHIP` ports `clk_arm`, `clk_74a`, `bupfw_download`, `ioctl_wr_any`, `ioctl_hi` and `cram0_*`. Hand every loader byte (`ioctl_wr_any`, `ioctl_hi`, `ioctl_addr`, `ioctl_dout`) to `bupchip_pocket`, which picks the cartridge's and the firmware's by address, and add `bupfw_download` to the core reset (`:137-138`), as for the other firmware slots. Instantiate `bupchip_pocket` next to the `mapper_load_*` expressions (`:946-950`), and `psram.sv` (`CLOCK_SPEED = 28.636364`, on `clk_arm`) on `cram0`: `bupchip_pocket` drives its user ports, so the testbench can put a model behind it. Connect `pause_core` (`:53`; tied to 0 at `core_top.v:850`), `pll_locked` (raw; the wrapper synchronises it), `pll_busy` and the new `top.sv` ports. |
| `core/core_top.v` | Connect `outclk_3` → `clk_arm` on `pll_core` (`:320-329`). Route `cram0_*` instead of the tie-offs (`:267-277`); `cram1` stays tied. Add `SLOT_BUPFW = 16'h0109` next to `:349-353` and a `bupfw_download` flag built like `arfw_download` (`:701-720`). Register the loader's address bits 27:25 beside `ioctl_addr_r` and hand them, with the ungated byte strobe `ioctl_wr_r`, to `atari7800_pocket` (`ioctl_hi`, `ioctl_wr_any`): the BupChip takes its bytes by address ("Capture"). |
| `dist/Cores/Miasmark.7800/data.json` | Add the firmware slot: name "BupChip firmware", id `0x109`, filename `bupchip.bin`, parameters `0x88` (loaded at start, not reloadable, so no menu row), extensions `bin`, `size_maximum` `0x4000`, address `0x0A000000`. `info.txt` lists the file with the other firmware (step 5). |
| `core/pll/pll_core.v` | Regenerate with 4 clocks; C3 = 24, then 32 (`DEVELOPING.md:245-271`). |
| `ap_core.qsf` | Add `VERILOG_MACRO "POCKET_BUPCHIP=1"` next to `:736-746`. Keep `NO_ARM_MAPPER`, `NO_BUPCHIP` and `NO_DDRAM`. Add `FAST_*_REGISTER` on `cram0_*`, as for the SRAM (`:758-765`). Step 5 also set `BUP_DEBUG=1` (test builds only) and the fitter seed (3). |
| `sim/run_sim.sh` | Add `-DPOCKET_BUPCHIP` to the macro list (`:77-81`), the new files and `psram.sv` to `SRCS`. The testbenches load the firmware through the data-slot path from a file named at run time (a local `bupchip.bin`, never committed). `ap_core.qsf:741-743` promises that simulation builds the same set as the qsf. |
| `sim/tb_system.sv`, `sim/tb_load.sv` | Drive `clk_arm`, `clk_74a` and a `cram0` PSRAM model on the `atari7800_pocket` instances (`tb_system.sv:49`, `tb_load.sv:85`). Step 5: `tb_load.sv` also loads the firmware slot (`+bupfw`, `+bupfwlast`) and watches the BupChip (`+bupms`, `+bupout`), and `sim/souper_test.py` builds the Souper test cartridge `run_sim.sh` plays. |
| `core/core.qip` | Add the new files, `../mister/rtl/bupchip_peripheral.sv` and `../pocket_utils/psram.sv`. Fix the stale "unmodified except `top.sv`" comment (`:3-5`). The identical `` `MAX`` definitions raise no warning ("Controller"). |
| `core/core_constraints.sdc` | Comment: add counter[3] (`:3-11`). Step 5 added a fitter-only over-constraint (1 ns more setup into `clk_sdram`, 0.1 ns more hold into `clk_sys`); see step 5. |
| `mister/POCKET_CHANGES.md` | Add a `POCKET_BUPCHIP` row to the switch table (`:80-92`) and update "Three build switches" and "all four" |
| `THIRD_PARTY_NOTICES.md` | Add `psram.sv` to the agg23 row (`:25`). Add the BupChip firmware to the user-supplied list in the paragraph at `:49-54`, which stays true: no console or peripheral firmware is built in. |
| `docs/` | `BUPCHIP.md` (load table, pointer to this document), `DEVELOPING.md` (clock plan with 4 counters), `README.md` resource figures |

### Macros and parameters

| Name | Effect |
|---|---|
| `POCKET_BUPCHIP` | `top.sv` exports the command and takes in the audio; the Pocket files build the BupChip |
| `BUP_DEBUG` | Adds a status word (halt code and PC; shadow-counter flags for command overflow, PCM overflow and PCM underflow; fault code; lowest PCM level), the load probe (`bup_load_probe.sv`), a check of the firmware as written into the ROM (word count, order, and CRC-32 against `bupchip.bin`'s published `95b8b4f8`) and the throttle, and shows them on screen: `bup_status_osd.sv` draws thirteen rows of cells over the picture's top-left 96 × 104 pixels while a Souper cartridge is loaded (step 5; its header has the layout). Hardware test builds only; off in releases. |
| `PCM_DEPTH`, `BUP_THROTTLE` | Parameters of `bupchip_pocket` |
| `ALTERA_RESERVED_QIS` | Set by Quartus. The retire port is simulation-only, as in `cache_ram.v:31` (`bup_cpu.sv:133-147, 873-885`). |
| `BUP_SIM_LATE_RF` | Simulation only: register-file writes land a clock late, with garbage in between, so that only the bypass keeps results right (`bup_cpu.sv:322-343`; `LATE_RF=1` in the scripts) |

## Verification plan

The harnesses came from the study. Step 1 brought them into `sim/bupchip/` (`verif/`, `model/`, `model/study/`) without game data or the firmware. The last column gives the S1 core's results (step 2) and where the rest is done.

| Phase | What | Pass | S1 |
|---|---|---|---|
| ISA | `sample.S`, plus `gen_random.py` (200 seeds × 300 operations) against Unicorn | All signatures equal. Unicorn models an ARM926 (ARMv5), so unaligned accesses and unpredictable forms are excluded here and covered against the reference RTL. | 201 of 201: the reference equals Unicorn, and the S1 core matches the reference in lockstep (362,371 retires) |
| Directed tests, against the reference RTL | See the list below this table | 0 mismatches; halts exactly where expected | Pass, plainly and with `LATE_RF=1` (step 2, below) |
| Lockstep, against `arm7tdmi_core` (`tb_lockstep.sv`, peripheral reads replayed) | Boot + Misery_F, 1 M instructions; mixer harness, 1.74 M; all 32 songs × 4 s overnight (local data); synthetic ARSC with every command class; random-content ARSC seeds; an injected load bit-flip | 0 mismatches and 0 halts, with no register masking (both cores start from zeroed registers). The injected fault must be caught. | 0 mismatches on every run. The one halt, random-content seed 4, matches a reference abort after the same 88,940 retires (step 2, below). |
| PCM | Misery_F, 4 s, against MiSTer's `sim/work/bupchip/ref/song13.pcm` from `run_bupchip.sh` (191,984 frames: the boot's 4,000 prefill frames, then 187,984 of the song); songs 14, 9 and 30 the same way. The Python model equals all six local references (songs 6, 9, 10, 13, 14, 30) over every frame. | Identical from the song's first frame. `sim/bupchip/s1/pcm_check.py` lines the two up on the frame pushed after the firmware took the command (MiSTer's frame 4,000), so a different run of leading silence fails, and so does a nonzero frame before the song starts. Without a song-start frame (`--song-start`), it lines them up on the first nonzero frame. | Songs 13, 14, 9 and 30: all 187,984 song frames identical |
| Performance | Clocks per batch, from the retire of 0x190 to that batch's return to 0x178: the retire of 0x1dc after a render, or of 0x274 after a silent batch. Idle is defined by the *retired* PC. | S1 within ±1% of 1.383; S2 and S3 within ±2% of the model; per-batch worst case within ±3% | 1.3772, −0.4% (zero-wait assets) |
| PSRAM | `psram.sv` against a PSRAM model (`psram.sv:36-53` timings), with `CLOCK_SPEED` = 28.636364 at clock periods of 28.636, 21.477 and 21.281 MHz | Every read and write completes in 5 clocks; the `$info` state numbers are distinct | Study, on agg23's file: 5 clocks at all three [sim]. Step 4, on the vendored copy: 23 of 23 checks, every access 5 clocks at all three, states distinct (`sim/bupchip/s4/run_psram_ctl.sh`) |
| System | Wrapper with the PSRAM model, the loader at 175–250 ns per byte, the `clk_74a` tick and the real clock ratio. Also: firmware load (missing file: CPU held and silent; a short file; firmware loaded before the cartridge, as the Pocket does), 2–3 cart reloads, a PAL retune, pause (driven in simulation; it is tied to 0 on hardware), a non-Souper cart, and a hold during a fill. | 0 underflow and 0 overflow from the shadow counters (the existing testbench checks only underruns, `tb_bupchip.sv:151`); lowest FIFO level ≥ 600; no capture message lost; misses within ±20% of the model | Step 4: songs 13, 14, 9 and 30 identical with 0 underflow, 0 overflow and lowest levels 659, 755, 721 and 801; no message lost, also with the firmware slot straight after a cartridge and asynchronous `clk_arm` (`stress/run_capstress.sh`); misses +4.9% against the model; reloads, retune, pause, holds during fills (with `psram.sv` mid-access and with the halfword arriving), the watermark remap, the mute, pushes into the empty FIFO and the held-and-silent cases pass (`sim/bupchip/s4/check.sh`, 27 jobs) |
| Quartus | CPU alone, then the integrated build | The gates in steps 3, 5, 8 and 9. Every slack gate is the worst setup slack over the four corners in `sta.summary` (slow and fast, 0 and 85 °C). | Step 3, partly done: the S1 probe passes the MLAB, slack and ALM gates. The 12-MLAB check waits for the 2W/3R register file. Step 5: the integrated build passes every slack and ALM gate (seed 3; step 5 below). |
| Hardware | 32 songs, NTSC and PAL, with the `BUP_DEBUG` status visible; throttle sweep; A/B against a MiSTer capture | Shadow-counter flags clear; fault code 0 | Steps 5 and 9 |

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

Step 2 covered every item that concerns the S1 CPU alone, in `sim/bupchip/s1/directed/`, `sim/bupchip/s1/halt_tests.py` and `sim/bupchip/verif/directed/`. That includes the throttle with an MMIO access in W and the condition-failed MMIO read (`v_mmio`, and every lockstep run with `+throttle`), the register read after a hold (`regzero.S`; `tb_s1.sv`'s `+rehold`) and the wild store (`wild_store`). Step 4 covers the asset-miss, fill and pre-emption items in `sim/bupchip/s4/tb_cache.sv` (directed scenarios A1–G, `sim/bupchip/s4/README.md`) and `sim/bupchip/s4/stress/tb_cstress.sv`, and the real firmware exercises every one of them in the system runs. "An asset miss with a dependent MLA or a store in execute" cannot arise in S1, whose next instruction starts only after W; it waits for S3's forwarding (step 7). E and W writing one register in one clock waits for the second write port (step 6).

**Lockstep retire port.** The record is `{pc, insn, the register writes from ports E and W, NZCV}`, in program order.
- The core marks the first clock of each instruction with `rt_start`, condition-failed ones included and never while frozen, and its last with `rt_valid`, which carries `rt_pc`, `rt_insn` and `rt_nzcv`. Register writes come as `rt_e_*` and `rt_w_*` on the clock they land (`bup_cpu.sv:133-147, 873-885`). S1 has one write port; it reports load data as W and every other write as E.
- Loads complete one clock after their execute clock, so the testbench applies each record to a shadow state. It closes an instruction's record at the next `rt_start`, so load data that lands with the next instruction's first clock still counts with the load.
- It does not snapshot the live register file.
- The rules are in `sim/bupchip/verif/README.md`, "The retire port".

**Game-free regression.**
- The firmware study's synthetic ARSC generator builds a 5.2 KB block (5,192 bytes; `sim/bupchip/model/synth_arsc.py`, and `sim/bupchip/verif/make_synth_arsc.py` for the lockstep runs). With it, the firmware boots, plays, uses all 21 bytecode ops and every command class, and reaches all three fault paths.
- Its reference PCM comes from the Python model, which equals MiSTer's RTL on it for songs 0 and 1 (48,009 frames; `sim/bupchip/model/README.md`).
- This, the mixer harness and the ISA suite run in CI-style scripts without game files: `sim/bupchip/verif/run_all.sh` and `sim/bupchip/model/check.sh`. Everything but the ISA suite runs CoreTone and needs the user's `bupchip.hex`; without it `run_all.sh` lists those steps as SKIP and `model/check.sh` stops.

**Testbench rules carried over:**
- The period, `ARM_MHZ` and the pop logic change together (`tb_bupchip.sv:21-22`).
- Detect halts and spins.
- Check overflow as well as underflow.

## Implementation steps

Every slack gate below is the worst setup slack over the four corners in `sta.summary`. For the S1 CPU, slow 0 °C is the worst corner, not slow 85 °C (step 3).

**Versions.** The first core release with ARIA will be **2.1.1**, set in `core.json` at release, after the hardware test passes; hardware test builds keep the version they were built from. The first release with DARIA, if it comes ("Later: 2600 ARM cartridges"), will be **2.2.1**.

1. **Tools into the repository** (`sim/bupchip/`): lockstep and ISA harnesses, mixer harness, Python model, cycle models, synthetic ARSC generator.
   *Done when:* reference against reference runs 1 M instructions with 0 mismatches; ISA passes 200/200 on the reference against Unicorn; the Python model's Misery_F PCM equals MiSTer's `sim/work/bupchip/ref/song13.pcm` (with local data); the synthetic ARSC renders non-zero PCM.
   
   **Done** (2026-10-03). The harnesses are in `sim/bupchip/verif/`, the Python model and cycle models in `sim/bupchip/model/`, and the study's RTL sketch, PSRAM and FIFO experiments and Yosys counts in `sim/bupchip/model/study/`. `sim/bupchip/setup_dev.sh` installs the tools and Unicorn. Commands and results (`sim/bupchip/verif/README.md`, `sim/bupchip/model/README.md`):
   - `sim/bupchip/verif/run_all.sh [rv.a78]` (reference against reference by default):
     - ISA: 201 of 201 (`sample.S` and 200 seeds) agree with Unicorn over 353,728 instructions, and 201 of 201 in lockstep.
     - Boot + Misery_F in lockstep: 1,000,000 retires, 0 mismatches; 4,000,000 with `+gap=25`, 0 mismatches; `+inject=50000` caught at retire 247,167.
     - Mixer harness: 4,800 of 4,800 frames nonzero, then 1,742,652 retires in lockstep, 0 mismatches.
     - Synthetic ARSC: boots and renders 42,664 of 48,009 frames nonzero with 0 underruns; the broken blocks give faults 2 and 3; Unicorn replays boot and song 0 (389,924 instructions) with every register and NZCV equal; lockstep over every command class (2,135,928 retires) and random blocks 1–4, 0 mismatches.
   - `sim/bupchip/model/check.sh [rv.a78]`: the inventory (1,704 code words), the synthetic block's coverage (1,516 of them, all 21 bytecode handlers, all three faults), and with the game the Python model's PCM identical to MiSTer's for songs 6, 9, 10, 13, 14 and 30 (191,984 frames each).
2. **S1 core in simulation.** B's sketch was compared with `arm7tdmi_core.sv` in a clean-room review and used as the starting point; `bup_cpu.sv` was then written anew from the ARM ARM and this design (`sim/bupchip/s1/README.md`, "Clean-room review"). It adds:
   - the `arm7tdmi_pkg` shifter and condition logic;
   - immediate-shift normalisation and RRX;
   - exact flags and rotations;
   - the register clear after hold;
   - the halt policy and the retire port.
   
   *Done when:* ISA and directed tests pass; lockstep has 0 mismatches on all the lockstep runs listed in the verification plan; Misery_F PCM is bit-exact for 4 s; CPI is within ±1% of 1.383.
   
   **Done** (2026-10-03, after three independent verification rounds; no open core faults). Commands and results (`sim/bupchip/s1/README.md`, `sim/bupchip/verif/directed/README.md`):
   - `sim/bupchip/s1/check.sh [sim/work/bupchip/game/rv.a78]`: 11 of 11 checks with the game (8 min 39 s on 4 cores), 7 of 7 without the firmware. It runs the directed and halt tests, `verif/directed/run.sh` and `verif/directed/run_vfy.sh`. It then runs the directed and halt tests, `run_vfy.sh` and the ISA suite in lockstep again with `LATE_RF=1`, then `verif/run_all.sh` with `DUT=bup LOCKSTEP=1`, and songs 13, 14, 9 and 30.
     - ISA suite in lockstep: 201 of 201, 362,371 retires and 122,330 stores, 0 mismatches.
     - Directed: 13 of 13 in `s1/directed/`, plainly and with `+await=40 +throttle=25`; 6 more hand-written and 16 generated tests in `verif/directed/`; halt tests 66 of 66 and `vhalt.py`'s 67 of 67; none of the firmware's 1,704 code words decodes as a halt. All pass with `LATE_RF=1` too. `verif/directed/run.sh` was run with `LATE_RF=1` separately, with fuzz seeds 1–16 (`verif/directed/README.md`).
     - Lockstep on CoreTone: mixer harness 1,742,652 retires, synthetic ARSC 2,135,928, Rikki & Vikki boot + Misery_F 1,000,000 (4,000,000 with `+await=20`), 0 mismatches; `+inject=50000` and `+inject_mmio=5000` caught.
     - PCM: songs 13, 14, 9 and 30, 4 s each, all 187,984 song frames identical to MiSTer's, 0 underruns and 0 overflows, lowest FIFO level 660, 756, 722 and 801.
     - CPI on Misery_F: 1.3772 against 1.383 (−0.4%), with zero-wait assets; 60,574,078 work instructions, 15.14 MIPS, busy 72.8% at 28.636 MHz.
   - `sim/bupchip/verif/run_songs.sh rv.a78`: all 32 songs × 4 s in lockstep, odd songs with `+await=20 +throttle=10`. 2,455,321,557 retires, 108,396,668 stores, 6,300,064 peripheral writes and 552,342,467 replayed reads; 0 mismatches, 0 halts.
   - `FUZZ="$(seq 1 440)" sim/bupchip/verif/directed/run.sh`: 198,000 random encodings, 129,771 run in lockstep (3,540,411 retires), 0 mismatches. That was before the ROM-end fix; seeds 1–48 pass after it. Seeds 9–40 also pass with every DATA or RO halt (1,147) matched by a reference abort in the same instruction.
   - `sim/bupchip/verif/directed/run_vrand.sh` with `SEEDS="$(seq 1 400)"`, plainly and with `LATE_RF=1`: 400 dense random programs, 2,572,076 retires per pass in lockstep, 0 mismatches. With `vshift_all.S`, 401 of 401 programs equal Unicorn's signature and instruction count.
   
   The round-by-round record, including the faults the verifiers found and fixed (running on past 0x3FFC now halts) and the mutation checks, is in those READMEs.
3. **Quartus probe** (once the baseline frees Quartus): S1 plus the 2-write/3-read register file, compiled alone on 5CEBA4F23C8 with 28.636 MHz and 21.477 MHz constraints.
   *Done when:*
   - The RAM summary shows the register-file banks in MLAB (12 MLABs) with unregistered read, and the memories in M10K.
   - Slack is ≥ +5 ns at 28.636 MHz (worst of the four corners).
   - ALMs are within ±25% of this document. LABs are recorded; the document has no S1 LAB estimate to hold them to.
   
   If MLAB fails, choose a fallback here. The M10K register file is the area-safe one.

   **Partly done** (2026-10-03). The S1 CPU passes, but the 2W/3R register file does not exist yet, so the probe compiled S1 alone. `sim/bupchip/quartus_probe/run_probe.sh` runs Quartus Prime Lite 21.1.1 from `raetro/quartus:21.1` and builds both clocks in about 4 minutes. It puts `bup_cpu.sv` with its ROM and RAM (`cache_ram_dp`, `cache_ram_tdp_dc_be`) on 5CEBA4F23C8, with the settings of `ap_core.qsf` and a flip-flop on every other port. The results are in `sim/bupchip/quartus_probe/README.md`; the reports are in `sim/work/bupchip/qprobe/<MHz>/`.
   - **MLAB: pass for S1.** The register file is two `altdpram` instances (`rf_rtl_0`, `rf__dual_rtl_0`), one per read port. Each is MLAB, Simple Dual Port, with registered write inputs, an unregistered read address and output, and 2 MLABs: 4 MLABs, 1,024 bits and 40 ALMs in all. The ROM and RAM are 16 M10K each. S3's 6 banks would take the 12 MLABs planned, but that figure is extrapolated, not measured. The 12-MLAB check stays open until `bup_regfile.sv` exists, before step 6 or step 8, and the probe is then re-run with it.
   - **Slack: pass.** At 28.636 MHz the worst setup slack is +5.916 ns, at slow 0 °C. It is +6.323 ns at slow 85 °C, and Fmax there is 34.97 MHz. Worst hold slack is +0.005 ns (fast 0 °C). At 21.477 MHz setup slack is +15.654 ns (slow 85 °C) and hold +0.131 ns. The critical path is under risk 2.
   - **ALMs: pass.** `bup_cpu` needs 1,297.3 ALMs at 28.636 MHz: 1,257.3 of logic plus 40 for the MLABs, with 2,058 ALUTs, 607 registers (308 after synthesis, the rest from retiming and duplication) and 3 DSP. At 21.477 MHz it needs 1,271.9. That is 5.5% above the top of the 960–1,230 estimate. The whole probe needs 1,527 ALMs, 141 of them for virtual I/O.
   - **LABs: recorded, not gated.** 180 logic LABs plus 4 MLAB LABs hold `bup_cpu` logic in this sparse fit (176 + 4 at 21.477 MHz). The whole probe touches 199 LABs: 195 logic, 4 memory.
4. **Wrapper, memories and asset path in simulation.** Peripheral 8/1024 with remap and shadow counters, ROM filled through the firmware-load path, RAM, the 64-line cache with per-halfword arrival bits, the capture message stream and receiver, and the 48 kHz tick. `psram.sv` runs with `CLOCK_SPEED` = 28.636364 against a PSRAM model at clock periods of 28.636, 21.477 and 21.281 MHz.
   *Done when:*
   - A download of `rv.a78` followed by 4 s of Misery_F gives PCM identical to MiSTer's `song13.pcm` (as compared under "Verification plan", PCM), with 0 underflow, 0 overflow and a lowest level ≥ 600.
   - The PSRAM and directed cache tests pass; no capture message is lost at 175 ns per byte.
   - Pre-emption is kept or dropped on measured stall clocks.
   - Reloads, retune and pause (in simulation) pass.

   **Done** (2026-10-04, after two independent verification rounds; round 2 passed with no major findings, and its minor ones are fixed). The RTL is in `src/fpga/core/bupchip/` (`bupchip_pocket.sv`, `bup_capture.sv`, `bup_asset_wr.sv`, `bup_asset_cache.sv`, `bup_tick48k.sv`; `bup_cpu.sv` unchanged since step 3), agg23's `psram.sv` is vendored unmodified to `src/fpga/pocket_utils/`, and the testbenches are in `sim/bupchip/s4/`, with the verifiers' stress benches in `sim/bupchip/s4/stress/` (the READMEs there have every number). `sim/bupchip/s4/check.sh sim/work/bupchip/game/rv.a78` passes 28 of 28 in 53 minutes with 3 jobs; without the game it runs the PSRAM, cache, stress and game-free checks (15 jobs). The firmware always arrives through the firmware slot's message path, never `$readmemh`.
   - **Misery_F:** a download of `rv.a78` at 174.6 ns per byte (129.4 ms; all 216,928 ARSC bytes in the PSRAM model right), then 4 s: all 187,984 song frames identical to `song13.pcm`, as pushed and as returned to `clk_sys`, 0 underflow, 0 overflow, lowest level 659 [RTL]. CPI 1.3783, busy 72.89%. Songs 14, 9 and 30 likewise (lowest levels 755, 721, 801). The peripheral's watermark is 824 after the firmware's writes of 3,896, and every write value goes through the remap right (`+wmsweep`).
   - **PSRAM:** `psram.sv` on a timing-checking model at 28.636, 21.477 and 21.281 MHz: every access 5 clocks, 0 violations, 23 of 23 checks [sim]. Song 14 with `clk_arm` at 21.281 MHz (1.5 × PAL `clk_sys`) plays identically, with a WRITE every 7.5 clocks and no message lost [RTL].
   - **Cache:** directed scenarios (the boot's cold-line bytes, word-load misses at 13 clocks and byte misses at 8, a hit on the line under fill, a demand miss during a prefetch and during a demand fill, holds during fills, a tag write colliding with a lookup, the tag sweep with new contents behind every valid line) and 200,000 random loads in 8 configurations, 0 wrong bytes, no PSRAM read started while held; 11 of 11 mutations caught [sim]. The stress bench adds every load pair at every distance, holds at every clock of a fill, PSRAM latencies 1–20 and M10K models that poison a mixed-port read-during-write: 22.2 M loads, 0 wrong, 10 of 10 mutations [sim]. Misses +4.9%, prefetches −0.5% and stall clocks −2.4% against the cycle model's S1/cache [RTL].
   - **No capture message lost** at 174.6 ns per byte, nor at 174.6–250 ns, nor at 21.281 MHz, nor with `clk_arm` asynchronous at 16–29 MHz, nor with the firmware slot starting in the clock after a cartridge's download ends, nor with a firmware byte in the clock its download starts or ends (`stress/run_capstress.sh`, 18 of 18; the old capture fails the end case with 58 and 68 wrong checks).
   - **Pre-emption kept:** 70,127 stall clocks on Misery_F with it, 72,396 without (+3.2%) [RTL].
   - **Reloads, retune, pause:** three reloads (the game, the game without its ARSC block, the game) with the holds during cache fills, one with `psram.sv` mid-access and one with the halfword arriving; a PAL retune with the hold mid-access during a fill, then 28.375 MHz; a 20 ms pause with 0 pops and silence; each then identical. Reloads of synthetic blocks with other contents give the model's PCM. A non-Souper cartridge, no firmware, a 4-byte firmware file and a cartridge without its block each leave the BupChip held and silent [RTL].
   - **PCM FIFO head and mute:** firmware of the stress bench's own pushes 6,000 single frames into the empty FIFO at every tick phase, with a tick forced onto the clock after one push: every frame comes out once and in order; a FAULT write silences every later frame; wrappers without `tick_hold` or without the mute fail [RTL].
   - **Fixed in the verification round:** FWWRITE now waits in the capture's queue (sent at once, it could follow a cartridge's END by 1–4 `clk_sys` and lose it); a firmware byte in the clock its download starts is kept; the cache starts no PSRAM read while held; the mute is applied on `clk_arm`; the cache's data RAM is counted at 2 M10K ("Cache").
   - Open for step 5: the new timing paths (`w_wait` from the tag compare into the next-PC logic, the ROM port-B address mux, the fill request through the arbiter), whether `clk_arm` runs on for about 14 clocks after `pll_busy` while `psram.sv` finishes a read (`sim/bupchip/s4/README.md`, "Open points for step 5"), and the M10K count in the fit report.
5. **Integrate S1 at 28.636 MHz** (C3 = 24).
   *Done when:*
   - Full compile with `BUP_DEBUG`: `clk_arm` slack ≥ +3 ns; `clk_sdram` ≥ +1.0 ns; `clk_74a` ≥ +2.0 ns; ALMs ≤ 81% (estimate 79.4–80.9% with `BUP_DEBUG`, from the probe's CPU, and 80.98–81.04% at the high end with the firmware-load path; "Totals"). LAB use is recorded.
   - Non-Souper simulation regressions are unchanged, with `run_sim.sh` building `POCKET_BUPCHIP`.
   - On hardware, Rikki & Vikki plays all 32 songs with the shadow-counter flags clear and fault code 0.

   **Built and passed on hardware** (2026-10-04). Integrated as "Integration" describes; `bup_cpu.sv` and the step 4 wrapper are unchanged.
   - **What changed.** `pll_core` gains counter[3] = VCO/24, regenerated with M, N and K unchanged (`DEVELOPING.md`, "Regenerate the PLL"); the timing report names it `ic|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk`, 34.921 ns. `top.sv`'s `POCKET_BUPCHIP` port group and assignments are the one vendored edit (`POCKET_CHANGES.md`). `atari7800_pocket.sv` instantiates `bupchip_pocket` and `psram.sv` (`CLOCK_SPEED` 28.636364, `cram0` die 0) and adds `bupfw_download` to the core reset; `core_top.v` routes `outclk_3` and `cram0` (`cram1` stays tied) and adds `SLOT_BUPFW` (`0x109`); `data.json` has the slot. The qsf adds `POCKET_BUPCHIP`, `BUP_DEBUG` (test builds), `FAST_*_REGISTER` on `cram0`, which are 1.8 V at 4 mA already (all 60 register bits land in I/O registers: 165 against 105), and the fitter seed.
   - **`BUP_DEBUG` is on in the test build,** and the status word is visible on the Pocket: `bup_status_osd.sv` draws it over the picture's top-left 96 × 32 pixels while a Souper cartridge is loaded, as four rows of twelve cells (a lit box is a 1, a grey box a 0; the grey alternates per nibble). Row 0: green for firmware loaded, ARSC block ready and CPU running, then red for halted, command overflow, PCM overflow, PCM underflow, muted (FAULT) and capture error. Row 1: halt code (yellow) and fault code (orange). Row 2: the lowest PCM level, 11 bits. Row 3: the halt PC's word address, PC[13:2]. The flags are sticky until the next hold (a cartridge load, a retune). Releases leave `BUP_DEBUG` out (`DEVELOPING.md`, "Before a release").
   - **Quartus** (Lite 21.1.1 in `raetro/quartus:21.1`, seed 3), worst of the four corners [rpt]:

     | Gate | This build | 2.0.21 |
     |---|---|---|
     | `clk_arm` setup ≥ +3 ns | **+8.084 ns** (slow 0 °C; Fmax 37.26 MHz; +8.259 at slow 85 °C) | — |
     | `clk_sdram` setup ≥ +1.0 ns | **+1.260 ns** (slow 85 °C) | +1.320 |
     | `clk_74a` setup ≥ +2.0 ns | **+2.759 ns** (slow 85 °C) | +2.868 |
     | `clk_sys` setup | +9.600 ns | +8.906 |
     | Hold, recovery, removal | all positive; worst hold +0.081 ns (`clk_sys`, fast 0 °C) | worst hold +0.063 |
     | ALMs ≤ 81% | **14,595 / 18,480, 79.0%** (+1,761) | 12,834, 69% |

   - **Resources** [rpt]. LABs 1,750 of 1,848 (95%): 1,746 logic and 4 memory LABs (the register file's MLABs, found a place in the full build, risk 1); 1,395 ALMs recoverable by dense packing. M10K 86 = 46 + 40: the 39 under "Totals" plus the peripheral's 8 × 8 command FIFO, which Quartus put in an M10K, not an MLAB. MLAB bits 1,024; DSP 12 (+3); global clocks 6 (+1); pins 224 of 224. ALMs needed by entity: `bupchip_pocket` 1,736.7 (the CPU 1,239.0 with its 40 MLAB ALMs, capture 178.7, cache 96.3, peripheral 72.2, receiver 32.2, tick 14.8, wrapper glue 103.6), `psram.sv` 90.0 and the status overlay 36.3: 1,863 in all. Without the overlay that is 1,827, just under the 1,867–2,142 estimated for S1 with `BUP_DEBUG` and the firmware-load path ("Totals").
   - **Timing paths.** `clk_arm`'s worst path is the CPU's own (ROM output → decode → register-file MLAB → adder → next PC into the ROM's address register). The wrapper's new paths have more margin (measured on an earlier fit of the same netlist, seed 1 with the over-constraint below) [rpt]: `w_wait` through the tag compare into the next PC +15.9 ns, the CPU's address into the tag M10K +11.5 ns, `psram.sv` +23.1 ns, the crossings `clk_sys` → `clk_arm` +30.6 ns and back +31.3 ns. Neither documented fix (the store decision from the base register, a `start_dem` register) is needed.
   - **`clk_sdram` and a hold path.** The first build (seed 1) met `clk_arm` and `clk_74a` but gave `clk_sdram` +0.154 ns and a `clk_sys` hold slack of −0.042 ns (fast 0 °C, into a JT51 shift register's M10K). Neither path holds BupChip logic. `clk_sdram`'s runs from MARIA's and the CPU's address through the 2600 mappers' RAM decode and `sram_ctrl`'s 2600 address-change compare (`c_key != c_key_last`) into the SRAM's pad registers: 13 levels, 16.2–16.9 ns of data delay in the 17.46 ns from a `clk_sys` edge to the next `clk_sdram` edge, and with 95% of the LABs in use it lost its margin. `core_constraints.sdc` now asks the fitter alone for 1 ns more setup into `clk_sdram` and 0.1 ns more hold into `clk_sys` (the Timing Analyzer checks the real constraints): hold then passes, `clk_sdram` reaches +0.555 ns (+0.477 with 2 ns), and seeds 2 and 3 give +1.042 and +1.260 ns. Seed 3 is in the qsf. The margin is now a matter of placement (risk 5); a structural fix would be in `sram_ctrl`, for example the 2600 address-change compare a `clk_sdram` earlier, and needs its own hardware test.
   - **Simulation.** `run_sim.sh` builds `POCKET_BUPCHIP` and `BUP_DEBUG`; `tb_system.sv` and `tb_load.sv` drive `clk_arm` (2 × `clk_sys`) and `psram_model.sv` on `cram0`. Every non-Souper result is identical, line for line, to the 2.0.21 tree's, and so is `extra_tests.sh`'s output [RTL]. With the user's firmware, `run_sim.sh` also checks the BupChip in the whole core [RTL]: the firmware through slot `0x109` after the cartridge, as the Pocket loads them, then a game-free Souper cartridge (`sim/souper_test.py`: 512 KiB, whose 6502 program sends `$80` through `$8007` 30 ms after reset) carrying the synthetic ARSC block. The ROM equals the file; the 5,192 ARSC bytes are in the PSRAM model, with no timing violation; the song's PCM equals `armemu.py`'s over all 10,400 song frames pushed and 9,547 returned to `clk_sys` in 250 ms; 0 underflow, 0 overflow, lowest level 636; status word `e000027c`; the audio reaches `top.sv`'s mixer. Without the firmware the same cartridge leaves the BupChip held and silent. `sim/bupchip/s4/check.sh` without the game: 16 of 16 (the wrapper is unchanged since step 4, so the game runs were not repeated).
   - **Step 4's open points** (`sim/bupchip/s4/README.md`): the new timing paths are above; the M10K count is 40; `clk_arm` runs on 3.45 µs (98 clocks) after `pll_busy` rises before a retune reconfigures the PLL (`pll_region.v` unchanged), against the 14 it needs.
   - **Still to do: the hardware test** (step 5's last gate). The test build is `release/Atari7800_Pocket_2.0.21-aria-test1.zip` (gitignored; `core.json` still says 2.0.21, see "Versions"). On the SD card it needs `/Assets/7800/common/bupchip.bin` (`tools/hex2bin.py` from MiSTer's `bupchip.hex`; CRC32 `95b8b4f8`) and Rikki & Vikki's `.a78` with its ARSC block (`sim/bupchip/make_arsc.py`; 741,344 bytes). Check, with the cells in view: all 32 songs (the jukebox cartridge plays any of them on demand: `BUPCHIP.md`, "Testing the songs"), Misery_F (13) past 32 s and Never_Lose (24) past 17 s, with no red cell, rows 1 and 3 grey and the lowest level noted (expected about 620–650 at Misery_F's and Never_Lose's peaks, "Full-length sweep"); the same in PAL (Region setting); no `bupchip.bin` (silent, first cell grey, no red); a wrong `bupchip.bin` (silent, usually with red halted or muted; the 7800 side unaffected); non-Souper 7800 and 2600 cartridges (no cells, sound and saves as in 2.0.21); a console reset (the music engine survives it, as on MiSTer); and reloading the cartridge, then another game, then Rikki & Vikki again.
   - **First hardware test (test1).** Rikki & Vikki's songs play as expected, and every cell was clean except the capture-error box. It stayed lit through a second cartridge load and with the game's `.a78` without its ARSC block. The tester's `bupchip.bin` is the published file (7,824 bytes, CRC32 `95b8b4f8`).
   - **test2: the box was a synthesis artifact.** The first explanation was the slot race above: `run_slotswitch.sh` reproduces a `seq_err` from it when the host's next request comes within about 30 `clk_74a`. test2 took bytes by address and added the load probe, the firmware check, and separate cells for `seq_err`, `lost` and `overrun`. All three were lit, on every load, with and without the ARSC block. The probe showed nothing for them to be set by: no foreign, late or dropped byte, more than 4,095 `clk_sys` (286 µs) from the last byte before the firmware slot to its flag, 19 `clk_sys` (1.33 µs) between firmware words, and the firmware's 1,956 words in order with CRC-32 `95b8b4f8`. `err_at` read 0, as it does when no byte came before `seq_err` rose. The map report said why: Quartus had removed `seq_err`, `lost` and `overrun` as "stuck at VCC". All three are flags that are only ever set, and each had its power-up value as an initializer on its output port declaration (`output logic seq_err = 1'b0`). Quartus 21.1 ignores those initializers without a warning, and with Power-Up Don't Care (the default) it chose power-up 1 and folded each register into a constant. A Quartus run on a four-register test module confirms it: the port initializer and Verilog's `output reg x = 0` are ignored, while an internal declaration's initializer and an `initial` block are kept. Simulation honours every form, so no bench could see it. Every output port initializer in the Pocket's own RTL is now an `initial` statement: the BupChip's modules, and `sram_ctrl.sv`, `pll_region.v`, `audio_filter.sv`, `stick_dirs.sv`, `virtual_axis.sv` and the ROM in `atari7800_pocket.sv`, whose registers were not folded but whose power-up levels were Quartus's choice. `pll_region.v`'s `cfg_address` and `cfg_writedata` are the exception: they are read only with `cfg_write`, and giving them a power-up value kept 550 more ALMs of the PLL reconfiguration core (the first test3 build: 15,405 ALMs, 83%), so they have none. `run_sim.sh` refuses the port form (`DEVELOPING.md`, "Power-up values"). The address-based capture stays as a safeguard.
   - **test2 build** (`release/Atari7800_Pocket_2.0.21-aria-test2.zip`, gitignored; commit `b4ea8a9`'s RTL, seed 3, `BUP_DEBUG`) [rpt]: 14,676 ALMs (79.4%, +81 for the probe, the firmware check and the larger overlay), M10K 86, DSP 12; worst setup slack `clk_sdram` +0.865 ns (slow 85 °C; test1's placement gave +1.260), `clk_74a` +2.977, `clk_arm` +7.837, `clk_sys` +9.212; worst hold +0.130 ns; recovery and removal positive. No BupChip memory has an initialisation file.
   - **test3 build** (`release/Atari7800_Pocket_2.0.21-aria-test3.zip`, gitignored; commit `1f8f965`'s RTL, seed 3, `BUP_DEBUG`) [rpt]: the power-up fix. `seq_err`, `lost` and `overrun` are registers (none of the BupChip's flags is in "Registers Removed During Synthesis"). 14,682 ALMs (79.4%), M10K 86, DSP 12; worst setup slack `clk_sdram` +0.654 ns (slow 85 °C; its margin moves with placement, risk 5), `clk_74a` +3.375, `clk_arm` +8.688, `clk_sys` +9.683; worst hold +0.063 ns; recovery and removal positive. Shipped with the jukebox built from the tester's game and `.cdf` (not in the repository).
   - **test3 on hardware:** no red cell. Rikki & Vikki and the jukebox: firmware loaded, ARSC ready, CPU running; 1,956 firmware words in order with CRC-32 `95b8b4f8`; no foreign, late or dropped byte; more than 4,095 `clk_sys` between slots; 18–19 `clk_sys` between firmware words; lowest PCM level 639 on the jukebox. Without the ARSC block: firmware loaded only, the CPU held, lowest level 1,024 (never ran), as expected. PAL (Region setting): the music stays on key and at the same pace, as the 48 kHz tick comes from `clk_74a`, which the retune does not touch. All 32 songs play through the jukebox. Without `bupchip.bin`: only the ARSC-ready cell lit, no red, silent. A console reset mid-song: the music plays on, as on MiSTer (the jukebox's own program restarts at song 0). A cartridge-RAM game with a double frame buffer (SRAM, whose controller's power-up values changed): no corruption. **Step 5 passed on hardware** (2026-10-04).
   - **2.1.1 release build** (`BUP_DEBUG` out of the qsf; `release/Atari7800_Pocket_2.1.1.zip`, gitignored) [rpt]: 14,596 ALMs (79%), M10K 86, DSP 12; the BupChip 1,716.7 ALMs (`bupchip_pocket`, the CPU 1,246.3) plus 94.8 for `psram.sv`. Seeds 1, 2 and 3 gave clk_sdram +0.26, +0.44 and +0.28 ns, worst path MARIA's DMA (`ABENF`) or the 6502's `halt_bus` through `sram_ctrl`'s arbiter into `sram_ub_n` / `sram_lb_n`; seed 2 is in the qsf. Its other setup slacks: `clk_sys` +3.043, `clk_74a` +3.069, `clk_arm` +8.517; worst hold +0.123 ns; recovery and removal positive. The first release builds had only +0.05 to +0.11: the power-up fix had given those pins' fast output registers power-up high, which Quartus implements by inverting them in the I/O cell; `sram_oe_n`, `sram_ub_n` and `sram_lb_n` now have no power-up value, as in 2.0.21 (`sram_ctrl.sv`). The margin stays a placement matter (risk 5): a structural fix in `sram_ctrl` (the cartridge request registered a `clk_sdram` before the arbiter, or the byte lanes from a register) would give it back, and needs its own hardware test.
6. **S2 in simulation:** second write port, bypass, load forwarding.
   *Done when:* all step 2 checks pass again, and CPI is within ±2% of 1.103 [model].
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

## Later: 2600 ARM cartridges (bonus goal)

Once the BupChip is complete and proven on hardware, the same CPU may also run the 2600 ARM cartridges (DPC+, CDF, CDFJ, CDFJ+), which upstream runs on the shared ARM7TDMI and the Pocket build leaves out (`NO_ARM_MAPPER`). The two never run at once, so they can share the CPU, its block RAM and the PSRAM path. The main new work is a clean-room Thumb front end: these drivers are game code, so all of Thumb has to be exact, with the same exact-or-halt rule. lroby74's MiSTer Thumb core is CC BY-NC 4.0 and may be used only as a behavioural reference. With Thumb added and the 2600 cartridges running, ARIA becomes **DARIA**: the Dual-use Atari RISC Interface Accelerator.

**Version:** the first release with DARIA will be 2.2.1 (2.1.1 is the first with ARIA; "Implementation steps", "Versions").

Test set: Champ Games' NTSC demos, supplied by the owner and kept in `sim/work/` (never committed):

| Scheme | Demos |
|---|---|
| DPC+ | Scramble |
| CDF (version 1) | Super Cobra |
| CDFJ | Galagon, Lady Bug, Mappy, RobotWar 2684, Wizard of Wor, Zoo Keeper |
| CDFJ+ | Elevator Agent (64 KB), Gorf, Qyx, Spiders, Turbo (128 KB), Tutankham, Zaxxon (64 KB) |

**First measurement (done).** `sim/bupchip/daria/` (`run_all.sh`, `tb_daria.sv`, `dynamic_tables.py`) runs each demo on upstream's core for 1,500 frames (FIRE at frame 420, play from 480) and records every ARM call: instructions by class, estimated S1 and S3 cycles, code and data footprint, and the budget, the time until the 6507's timer wait reads 0. The report stays in `sim/work/bupchip/daria/` with the traces. Summary [sim, upstream core]:

| Scheme | Largest call (instructions) | Worst share of budget on upstream | MHz needed at CPI 1.0 / 1.2 / 1.4, with 20% margin | Late calls: S1 @ 28.636 / S3 @ 21.477 / S3-style @ 28.636 |
|---|---|---|---|---|
| DPC+ (Scramble) | 25.8k | 66% | 22.6 / 27.1 / 31.6 | 0 / 0 / 0 |
| CDF1 (Super Cobra) | 24.9k | 55% | 17.6 / 21.2 / 24.7 | 0 / 0 / 0 |
| CDFJ (6 demos) | 32.5k (Zoo Keeper) | 80% (Lady Bug) | 27.2 / 32.6 / 38.0 | 0 / 1 / 0 |
| CDFJ+ (7 demos) | 55.5k (Spiders) | 110% (Spiders) | 38.3 / 45.9 / 53.6 | 189 / 297 / 16 |

- Two calls a frame: 10k–29k instructions in VBlank (budget 1.28–2.18 ms), 0.3k–6.4k in overscan (0.50–1.00 ms). All Thumb except 0.16% ARM state in Mappy; no unaligned access.
- **Spiders**, not Elevator Agent, overruns on upstream's core: 16 frames of 354 lines at the start of play. Elevator Agent's worst call uses 90% of its budget, and lroby74's "95,403 needed" matches this bench's ARM7TDMI-cycle estimate for it (95,453).
- Estimated CPI: S1 1.26–1.36, S3 1.01–1.07. S1 at 28.636 MHz serves 11 demos and S3 at 21.477 MHz 10; Elevator Agent, Zaxxon, Spiders and Qyx would have late calls. An S3-style core at 28.636 MHz misses only Spiders' 16 (as upstream does). Every call on time needs about 32 MHz, a 20% margin about 40 MHz: a timing-closure question for the Thumb front end, which must not add a clock per branch.
- Memory: code in block RAM (32 KB images: 32 M10K; 64 KB: 64; Turbo: 128), or code in block RAM plus a 2-way 4 KB data cache; a cache in front of SDRAM costs up to 42% more clock, and PSRAM is too slow for code. 16 KB of RAM covers all 15.
- Exact Harmony timing is not needed for correctness: no demo reads the ARM's timer, and the first timer read after every call is the wait loop.
- Open: longer runs and other input sequences on the four heavy demos, real Harmony timing, closure at 28.6 MHz or more, the block RAM budget.

## Open questions and risks

| # | Risk or question | Impact | Mitigation or check |
|---|---|---|---|
| 1 | Asynchronous-read MLAB inference on Cyclone V. No MLAB is used today (`fit.rpt:5025`). | +700 ALMs net as flip-flops (too much for either gate), or one more pipeline stage with an M10K register file (CPI 1.014) | **Confirmed for 16 × 32 banks with one write port** (step 3): S1's two banks are MLAB with an unregistered read address and output, 2 MLABs each, and the critical path runs through the MLAB read [probe]. Still open: S3's six-bank 2W/3R file (step 3 re-run); MLAB write timing, which is still unverified and which the bypass covers (if next-clock reads turn out to be safe, the bypass, about 100 ALMs, could be dropped); and whether the full build finds memory-capable LABs for the MLABs, which today hold logic: it does, 4 memory LABs in step 5's build. |
| 2 | Single-clock execute timing on a C8 part at about 80% fill. Estimates: S3 25–27 ns [E]. S1, measured in an empty device: 27.263 ns of data delay at 14 levels, 62% of it interconnect; setup slack +5.916 ns at slow 0 °C and +6.323 ns at slow 85 °C at 28.636 MHz [probe]. | Lower clock or less forwarding | S1's critical path is the one-clock-store decision: ROM `q` → decode → register-file read select → MLAB read → bypass → shifter → operand mux → adder → region decode → one-clock store or not → `rom_addr` or `ram_we`. Its shifter leg is functionally false, because a one-clock store needs an immediate offset (`bup_cpu.sv:434-435, 659`). If step 5 misses +3 ns, the first fix is to decide the store from the base register's region ("region decode from the base register"), or from Rn ± imm12 on its own adder. Other options: the 46.56 ns period at 21.477 MHz; reduced-forwarding variants. A LogicLock region is not available: Quartus Lite removes every region (Critical Warning 140003; tried on the probe). Steps 3, 5 and 8. In the full build (step 5) the same path gives +8.08 ns at 28.636 MHz (slow 0 °C). |
| 3 | PSRAM: 1.8 V I/O with no I/O constraints; tCEM and page mode unverified; `FAST_INPUT_REGISTER` needs DQ captured straight into the I/O register (agg23 samples DQ in fabric). `psram.sv` breaks at `CLOCK_SPEED` = 21.477/21.281. | Slower fills; no fills at all if misconfigured | `CLOCK_SPEED` fixed at 28.636364 (5 clocks per halfword), checked in step 4. Cache stall is 0.13%; 13.7 ms of FIFO margin; even uncached, the core manages 23.8 MIPS at 28.636 MHz [model]. Hardware CRC readback of the ARSC. |
| 4 | S2 and S3 figures come from the cycle model | CPI higher than planned | The model agrees with the RTL to 0.3% on the study's sketch and to 0.1% on the S1 core (1.377 against 1.3772). Steps 6 and 7 measure RTL. Fall back to S1 or S2 at 28.636 MHz. |
| 5 | Congestion: `clk_sdram` has +1.32 ns of slack today; only 199 LABs are untouched against 194–263 needed | `clk_sdram` timing failure; a fit that relies on denser packing | No BupChip logic on `clk_sdram`; slack, ALM and LAB checks in steps 3, 5 and 9; S1 fallback. LogicLock is not available in Quartus Lite (risk 2). **Seen in step 5:** with S1 in, 95% of LABs are used, and `clk_sdram`'s worst path (MARIA / 2600 mapper address into `sram_ctrl`'s pad registers, no BupChip logic) gave +0.15 ns with the default seed. A fitter-only over-constraint and seed 3 give +1.26 ns; another seed may be needed after any change. A lasting fix would shorten that path in `sram_ctrl` (step 5). **2.1.1:** +0.44 ns with seed 2; the worst path runs through the 2600 mappers (DPC+'s decode first) and `sram_ctrl`'s 2600 address compare, and two fixes are written up in `SRAM_TIMING.md`: leave the ARM schemes' 6507-side front ends out with the ARM (about 1,750 ALMs), and give the 2600 request its own registered path (needed before DARIA). |
| 6 | Deviations from the firmware contract: watermark remap; halt instead of an abort spin; fixed mode bits; CPU not paused; music starts about 64 ms earlier than on MiSTer | Visible only to other firmware | CoreTone never reads the FIFO depth or mode bits (lockstep). Document them. |
| 7 | Firmware licence. The firmware's source is not published (`BUPCHIP.md:16-17`), so building it in would contradict `THIRD_PARTY_NOTICES.md:49-54`. | Resolved: the user supplies `bupchip.bin` ("Firmware load"). The vendored `mister/rtl/bupchip.hex`/`.mif` are removed from the tree and gitignored; simulation reads a local copy at the same path. | Not removed from the git history: unlike the HSC and Supercharger rewrite (README, "History rewrite"), that would rewrite `main` and the release tags, so the owner chose a removal commit. Commits up to 2.0.21 still contain them. |
| 8 | Clean-room status of B's sketch, said to be written from the ARM ARM | GPL contamination | Reviewed in step 2 (`sim/bupchip/s1/README.md`, "Clean-room review"; `sim/bupchip/model/study/README.md`, "Clean room"), and `bup_cpu.sv` was then written anew. Reuse only MIT code (`arm7tdmi_pkg`, peripheral, capture parse, `cache_ram`, `psram.sv`). RRX and the immediate-shift normalisation are written from the ARM ARM. |
| 9 | Only Rikki & Vikki has been measured | Other content could need more | The firmware caps at 16 voices, and that bound fits at 83% |
| 10 | Command bursts beyond 8 between pops | Lost command | `BUP_DEBUG` shadow overflow flag; raise `CMD_DEPTH` (1 MLAB either way) |
| 11 | BupChip audio passes through `audio_filter`'s 256-sample boxcar (about 55.9 kHz) before I2S | Small resampling loss | Kept as MiSTer's mix for identical levels. Open: mix at the I2S input instead. |
| 12 | ROM depth | 8 M10K | A 2,048-deep ROM frees 8 blocks if M10K ever runs short, but caps `bupchip.bin` at 8 KiB |
| 13 | S1 area. The probe measured the CPU at 1,297 ALMs, 5.5% above the 960–1,230 estimated from B's sketch [probe] (Yosys had predicted 1,380–1,775) | S1 is at step 5's 81% gate once the firmware-load path is counted: 79.4–80.9% with `BUP_DEBUG`, and 80.98–81.04% at the high end with that path ("Totals"). S3's CPU (1,390–1,810 [E]) is still unmeasured. | **Resolved for S1:** step 5's build, with `BUP_DEBUG`, the firmware-load path and the status overlay, needs 14,595 ALMs, 79.0% [rpt]. Steps 3 (re-run with the 2W/3R file) and 8 measure S3's CPU. |