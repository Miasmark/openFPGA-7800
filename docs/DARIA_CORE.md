# DARIA: the 2600 ARM cartridges on ARIA

**DARIA** (Dual-use Atari RISC Interface Accelerator) is ARIA, the Pocket's BupChip CPU (`docs/BUPCHIP_CORE.md`), extended to run the 2600's ARM cartridge schemes: DPC+, CDF, CDFJ and CDFJ+ (Harmony and Melody cartridges). Upstream MiSTer runs them on its ARM7TDMI core, which the Pocket build leaves out (`NO_ARM_MAPPER`). The first release with DARIA will be 2.2.1.

This document is at **step 0, scope**: what DARIA must do, taken from upstream's RTL and checked against traces of real games. Step 1 turns it into the design. The plan the steps come from is `BUPCHIP_CORE.md`, "Later: 2600 ARM cartridges".

Tags, as in `BUPCHIP_CORE.md`:

| Tag | Meaning |
|---|---|
| [trace] | Measured on upstream's ARM7TDMI core running the 15 Champ Games NTSC demos for 1,500 frames each (`sim/bupchip/daria/`, `tb_daria.sv`). The demos and everything made from them stay in `sim/work/`, never committed. |
| [C] | Read from upstream's RTL (`src/fpga/mister/rtl/`), Jamie Blanks's MIT code |
| [probe] | Quartus 21.1 on 5CEBA4F23C8 with the core's settings: the CPU alone with its ROM and RAM (`sim/bupchip/quartus_probe/`), or one front-end block alone with every input live (`sim/bupchip/daria/frontend_study/`) |
| [sim] | Measured in simulation of this repository's RTL |
| [doc] | Analogue's openFPGA developer documentation |
| [E] | Estimate |

## Rules

These carry over from ARIA:

- **Exact or halt.** An instruction either does exactly what the ARM7TDMI does, or the core halts with a code. Nothing is silently different.
- **Upstream is the oracle.** Upstream's ARM7TDMI and its 2600 front ends are the reference in simulation, retire by retire where the CPU is concerned, and on the 6507's bus everywhere else.
- **Clean room.** `arm7tdmi_core.sv` (GPL-2.0-only) is a simulation oracle, never a source. lroby74's MiSTer Thumb core (CC BY-NC 4.0) is a behavioural reference only. Upstream's MIT front ends may be read and reused.
- **No game data in the repository**, nor anything derived from it: ROMs, traces, listings, signatures.

## Requirements

### The CPU

| # | Requirement | Source | Status |
|---|---|---|---|
| C1 | **Thumb-1, all of it, exact or halting.** All but 40,446 of the traces' 460 M instructions are Thumb. Every format appears except SWI: F15 LDMIA in 3 demos (3,114), STMIA in 11 (1.53 M), F8 STRH in 14, F12 in 14, the rest in all 15. | [trace] | Step 2 (the expander) |
| C2 | **ARM state: the drivers' helpers.** 14 of the 15 demo images (every CDF-family one) carry the same four helpers in their 2 KB driver at 0x750–0x7FF: Thumb trampolines at 0x750, 0x754, 0x758 and 0x75C (`ldr r4, [pc, #148]; bx r4`) branch to ARM routines at 0x760 (set a voice's frequency), 0x784 (reset its counter), 0x7A0 (read its counter) and 0x7BC (set its waveform size, a read-modify-write of two RAM tables). Each returns with `orr r4, lr, #1; bx r4`. Only Mappy calls one in the traces: the first, 4,494 times, which is all of the traces' 40,446 ARM-state instructions. The DPC+ image (Scramble) has none. | [trace], the images | ARIA already runs every ARM instruction they use, except the mode changes (C3, done) and the BX back to Thumb (C4) |
| C3 | **Processor modes.** The first three helpers switch to FIQ mode (`mrs r4, cpsr; msr cpsr_c, #0xD1`) and move values into or out of r8–r13, then restore the mode with `msr cpsr_c, r4`. Calls start in SYS mode (P1). So DARIA needs SYS and FIQ, FIQ's banked r8–r14, the I and F bits kept and read back by MRS, and MSR of the control byte from an immediate or a register. No SPSR access, no exception entry. | [trace], [C] | **Done**: `bup_cpu.sv`'s `MODES` 1 (below) |
| C4 | **Interworking.** BX both ways (Thumb `bx r4` to the ARM helper, ARM `bx r4` back with bit 0 set); `POP {pc}` and `LDR pc` do not change state on ARMv4T; BL as a prefix/suffix pair. | [trace], ARM ARM | Step 2 |
| C5 | **What never happens.** No SWI, undefined or coprocessor instruction, no unaligned access, no SPSR access and no read of any MMIO register in any trace. DARIA halts on all of them, as ARIA does. | [trace] | Holds by the halt rule |
| C6 | **Speed.** Two calls a frame. Every call meets its budget at about 32 MHz with S3's CPI; S3 at 28.636 MHz misses only Spiders' 16 calls, as upstream does. | [trace] (`BUPCHIP_CORE.md`, "Later") | Step 3 measures |

### The call protocol

| # | Requirement | Source |
|---|---|---|
| P1 | **Launch.** The 6507 side posts an entry address, a stack pointer and the T bit. The CPU then starts with r0–r12 = 0, r13 = the stack, r14 = 0xF000_0000, PC = the entry, CPSR = SYS mode with the T bit, NZCV = 0, I = F = 0. FIQ's r8–r10 are loaded with the three audio counters and r11–r13 with the three frequencies. FIQ's r14 and SVC's registers are not written. | [C] `arm_mapper_controller.sv:219-232, 284-322` |
| P2 | **Return.** A fetch from 0xF000_0000 ends the call. FIQ's r8–r13 are read back. Each counter is taken only if it differs from the value it was launched with; the frequencies are always taken. | [C] `arm_mapper_controller.sv:325-358`, `arm_mapper_audio.sv:207-223` |
| P3 | **The 6507 waits.** It is held on RDY from the call until the return, and during a DMA copy outside the mapper's start-up (`arm_call_stall`). | [C] `top.sv:306-329` |
| P4 | **Reset.** A mapper reset or a new image clears MAMCR, the timer and the caches. | [C] `arm_mapper_memory.sv:739-760` |

### Memory and peripherals (the 2600 profile)

| # | Requirement | Source |
|---|---|---|
| M1 | **ROM** at 0 up to the image size (capped at 1 MB), read-only. A write aborts. Images in the test set: 32 KB (12), 64 KB (2), 128 KB (Turbo). | [C] `arm_mapper_memory.sv:375, 566-567, 624-626`; [trace] |
| M2 | **RAM** at 0x4000_0000, `mapper_ram_size` bytes: 32 KB for CDFJ+, 8 KB for every other scheme. The demos stay inside 8 KB, except three CDFJ+ ones (Elevator Agent, Turbo, Zaxxon) that reach the 16th KB. DARIA needs 32 KB (32 M10K) to be exact for CDFJ+, or must halt above what it has. | [C] `:568-569`, `top.sv:779-783`; [trace] |
| M3 | **MMIO window** 0xE000_0000–0xE01F_FFFF (`addr[31:21] == 0x700`): MAMCR (0xE01F_C000) and timer 1's TCR (0xE000_8004) and TC (0xE000_8008) read back. Everything else in the window reads 0 and drops writes, and never aborts, because the drivers program the PLL, MEMMAP, MAM timing, PINSEL and TIMER0. The traces write MAMCR (Scramble, 4,172 times) and nothing else, and read nothing. | [C] `:570-575, 606-609`; [trace] |
| M4 | **Timer 1** counts at 70 MHz while enabled (TCR bit 0). Upstream divides its 5 × `clk_sys` ARM clock: it skips 1 tick in 45 for NTSC (exactly 70 MHz) and 1 in 76 for PAL (70.0045 MHz). DARIA's clock will differ, so it counts on `clk_sys` instead: per 9 clocks 8 × 5 + 4 (NTSC), per 76 clocks 71 × 5 + 5 × 4 (PAL), the same rates. No demo reads it; Draconian does (not in the set). | [C] `:474-489, 729-737`; [E] |
| M5 | **Anything else** (outside ROM, RAM, the MMIO window and the sentinel) aborts on upstream. DARIA halts. | [C] `:603-604, 626` |

### The 6507 side (front ends)

The front ends are the cartridge logic the 6507 sees: bank switching, the data fetchers and streams, the "LDA #" fast fetch, fast jump, BUS stuffing, the call trigger, the copy/fill service and the AMPLITUDE register. `sim/bupchip/daria/frontend_study/README.md` has the full register maps and upstream's quirks; these are the requirements that shape the design.

| # | Requirement | Source |
|---|---|---|
| F1 | **Bus timing.** A 6507 cycle is 12 `clk_sys`. The address is valid from the phase-1 edge (E0). The CPU latches read data at E0+6, and the front end commits its state on that edge, only when `access` is high. So a read has 6 `clk_sys`. During a call or a copy, RDY holds the read and the front end sees only its first phase 2. | [C] `top.sv`, `6502/mos6502_dp.sv:299`, `TIA.sv:505-557` |
| F2 | **DPC+:** 8 fetchers (12-bit counter, top, bottom, 20-bit fraction, increment), the 32-bit random number, 3 waveforms and notes, PUSH and WRITE, 6 banks, fast fetch on any `$A9` read, the copy/fill service (the 6507 held meanwhile), and the call (`$FE`/`$FF` to CALLFUNCTION). | [C] `mapper_dpcplus.sv` |
| F3 | **CDF, CDFJ, CDFJ+:** 32-bit stream pointers and increments in cart RAM (34 or 35 streams; table addresses per version), DSWRITE/DSPTR, SETMODE, fast fetch at the address after `$A9` (CDFJ+ also `$A2`/`$A0` and a fetch offset), fast jump on `$4C` with a two-byte lookahead in the image, 7 banks. | [C] `mapper_cdf.sv`, `cdf_fastjump_table.sv` |
| F4 | **BUS (1–3):** streams and a map in cart RAM, STY stuffing into TIA/RIOT writes, BUS3's fast jump. BUS0 shows the bad-game screen. No BUS image is in the test set. | [C] `mapper_bus.sv` |
| F5 | **AMPLITUDE.** A 20 kHz tick on `clk_sys` adds each voice's frequency to its counter. DPC+ sums three waveform samples from RAM; CDF and BUS sum three samples through each voice's pointer and size words, or in digital mode return a nibble of a ROM or RAM byte. | [C] `arm_mapper_audio.sv` |
| F6 | **The RAM image.** At load end and on every console reset, with the console held: DPC+ zeroes RAM and copies the image's display data; CDF and BUS copy the 2 KB driver and zero the rest. | [C] `arm_mapper_ram_init.sv` |
| F7 | **Upstream's quirks**, kept where a game could see them: DPC+ fast fetch arms on data bytes too; hotspots are ignored on substituted reads; the jump lookahead crosses bank ends; the BUS map aliases `$20–$24`. Two are open: BUS stuffing reaches the RIOT but not the TIA (an upstream bug?), and upstream's data bus changes after the latch edge, which only `open_bus` keeps. | [C], study §2.7 |

**Why upstream's front ends are large.** 2.1.1 carries them at 1,752 ALMs, but with the ARM tied off synthesis has removed half of them. Compiled alone with every input live, the seven blocks take **2,192 ALMs**, and the call controller that DARIA would need with them another 716 (about 1,150 of its flip-flops carry the six audio values across clocks) [probe]. The causes:

- DPC+ keeps its 8 fetchers in flip-flops with eight copies of every adder, comparator and load mux: about 690 of its 832 live ALMs.
- CDF and BUS copy their pointer tables out of cart RAM into two M10Ks, snoop the ARM's writes into the copies and write updates back across clocks.
- About a dozen 32-bit adders and carry registers, of which at most two work in any 6507 cycle.
- Upstream's read path runs from the SDRAM byte through the decode to SRAM within one cycle and is timed at `clk_sdram`. It forces the parallel window compares, and in the full build the fitter duplicated `mapper_dpcplus` by 47% for it (the path in `SRAM_TIMING.md`).

**The lean design (proposed).** One front end for all three schemes, sequenced in 12 slots per 6507 cycle on `clk_sys`, every stage registered:

- the image ROM's port B and cart RAM's port B (DARIA's block RAMs) serve the 6507 side, with no SDRAM or SRAM in the path;
- DPC+ fetchers and the audio counters, frequencies and launch values live in a 256 × 32 state RAM (2 M10K), with the fields on byte lanes;
- CDF and BUS pointers, increments and maps are read and written in place in cart RAM, as the Harmony driver keeps them, so there is nothing to copy, snoop or write back;
- one 32-bit word register and one adder serve the front end and the audio engine;
- the fast-jump lookahead reads the ROM port, instead of a 4-M10K table;
- read data is ready two clocks before the 6507 latches it.

A sizing sketch of it (`frontend_study/daria_fe3.sv`, never simulated) compiles to **1,004 ALMs and 2 M10K**: core 436, shared datapath and port arbitration 239, audio 225, copy engine 104 [probe]. With what it leaves out, less what can still be shared: **850–1,100 ALMs** [E]. The call controller shrinks to 100–150 ALMs [E], because the audio values move through the state RAM while the CPU is halted.

| | Upstream, reused | Lean |
|---|---|---|
| Front ends | 2,192 live (1,752 as tied off in 2.1.1), plus 60–100 of `cart2600` glue [probe] | 850–1,100 [E; sketch 1,004] |
| Call controller | 716 [probe] | 100–150 [E] |
| M10K | 8 | 2 |
| On the `clk_sdram` path | yes | no |

Coding style matters under the project's `MUX_RESTRUCTURE OFF`: the same sketch written as state machines took 1,343 ALMs. Each register gets one load enable and at most a 4-way data mux.

**How it will be proved:** as a cycle-by-cycle shadow of upstream's front ends inside `tb_daria.sv`, as POKEY was (`run_pokey_shadow.sh`): the same 6507 bus into both, data compared at every latch edge, state compared after every cycle, AMPLITUDE compared per tick. Then directed tests per scheme (BUS has no demo) and a random differential bench. Two differences are expected and will be counted, not hidden: AMPLITUDE can lag a tick at a different clock, and stall lengths differ.

### Packaging

| # | Finding | Source |
|---|---|---|
| K1 | **A bitstream can be chosen per loaded file.** `core.json` may list up to 8 bitstreams. A Chip32 loader program (`framework.chip32_vm`) runs before the FPGA is configured, can read the file's extension (`GETEXT`) or header (`OPEN`, `READ`), and loads bitstream *n* (`CORE n`). agg23's SNES core picks one of 3 bitstreams from the ROM header this way. | [doc] (read from a mirror of Analogue's pages; analogue.co is blocked here), example cores |
| K2 | **No menu choice, no switch from a running core.** `variants.json` is "an upcoming feature"; no target command reloads a bitstream. Reloading the cartridge slot (`0x109`, bit 8: "the bitstream is also reloaded") restarts the core and runs the loader again, so going from a 7800 game to a 2600 ARM game should change bitstream. Not yet seen on hardware. | [doc] |
| K3 | **Alternatives:** a second core entry (`Miasmark.2600`) from this repository, with its own folders and settings; or both, sharing one 2600 bitstream. | [doc], example cores |

So a 2600-only bitstream without the 7800's MARIA, YM2151, POKEYs, 7800 mappers and BupChip (about 7,100 ALMs), can ship inside the existing core: the loader sends `.a78` files to today's bitstream and 2600 files (or only ARM-scheme ones) to the other. The cost is a loader that must load every data slot itself, a shared `interact.json`, and a 2600 bitstream that answers the save slots exactly as today's does.

## Step 0 work: the processor modes (C3)

`bup_cpu.sv` has a `MODES` parameter. 0, the default and the BupChip's, is ARIA as before. 1 adds:

- **The control byte** (`ctl`: I, F, T, mode), reset to 0xD3 (SVC, I and F masked, as the ARM7TDMI leaves reset). MRS reads it. MSR writes it when the new byte has T clear and the mode is SVC, SYS or FIQ. Anything else halts with code 1, one clock later, without changing the mode (USR, IRQ, ABT and UND are not needed).
- **Banked registers in the existing register file.** The file was already two 32-deep MLAB pairs with 16 words used. With `MODES` 1 it uses 32: 0–14 the user and system registers, 16–22 FIQ's r8–r14, 29–30 SVC's r13–r14. A remap in front of the two read ports and the write port picks the entry from the register number and the mode. The bypass of last clock's write compares entries, not register numbers.
- **The reset clear** writes all 32 entries (32 clocks instead of 15).
- **The retire port** gains `rt_mode`, so the lockstep shadow can follow the banks (`sim/bupchip/verif/README.md`).

**Cost [probe].** At 28.636 MHz, after synthesis: +31 ALUTs and +12 registers (1,866 / 308 → 1,897 / 320), roughly 20–30 ALMs, no memory, and timing unchanged (+6.84 ns of setup slack at slow 85 °C against +6.32). The fitted ALM count moved by more than that (1,297.3 → 1,258.8), because physical synthesis duplicated fewer registers, so the synthesis figures are the ones to quote (`sim/bupchip/quartus_probe/README.md`). With `MODES` 0 the probe gives ARIA's figures to the decimal.

**Checks [sim].** `sim/bupchip/daria/modes/run_modes.sh`:

- `modes.S` runs SVC, SYS and FIQ against each other: every banked register read and written in each mode and again after switching away and back, straight after the MSR; the helpers' pattern from SYS with I and F clear; MSR of the f field, of f and c together, and with a failing condition; banked registers as LDM/STM lists, load destinations, store data, multiply operands and a shift amount.
  - It reaches its end marker on upstream's core.
  - It passes in lockstep with `MODES` 1 (649 retires, 176 stores), also with random asset waits and throttle clocks, and built with late register-file writes.
  - With `MODES` 0 the core halts with code 1 at the first MSR to SYS, as it should.
- ARIA's directed tests and fuzz seeds 1–8 pass in lockstep with `MODES` 1.
- Five mutants each fail: no FIQ bank, no SVC bank, MRS reading 0xD3, I and F not kept, and a bypass that compares the wrong bits.
- ARIA's full check (`sim/bupchip/s1/check.sh` with Rikki & Vikki) still passes with `MODES` 0, including PCM identical to MiSTer's on songs 13, 14, 9 and 30.

**The hand-off (P1, P2).** Upstream crosses six 32-bit values each way through a mailbox, two-flop synchronisers and result registers: about 1,150 flip-flops in its controller. DARIA can do without them. Its launch sequence writes the register file through the write port anyway (r0–r12, r13, r14, PC, CPSR), so FIQ's r8–r13 are six more writes, and the return reads them back through a read port while the CPU is halted. With the counters, frequencies and launch values in the front ends' state RAM, the controller is 100–150 ALMs [E] against upstream's 716.

## Where step 0 leaves the budget

| Part | Upstream | DARIA | Tag |
|---|---|---|---|
| Processor modes (C3) | in the core | +31 ALUTs, +12 registers (about 25 ALMs) | [probe] |
| Front ends | 2,192 live; 1,752 tied off in 2.1.1 | 850–1,100 | [probe] / [E] |
| Call controller | 716 | 100–150 | [probe] / [E] |
| Thumb expander, S3 over S1, image capture, MMIO and timer, profile mux | the core | 650–1,450 (the plan's 750–1,600 less its share for the controller) | [E] |
| Cart RAM | 32 KB (`cart_ram_tdp`) | 32 KB: 32 M10K | [C] |

- The Mappy-specific part of the CPU work, the FIQ mode with its banked registers, turned out to be the cheapest item: the register file already had the room.
- Writing the front ends anew saves 650–900 ALMs against what 2.1.1 already spends on them. Against reusing upstream's front ends, glue and controller live (about 3,000), the front ends and controller together save 1,700–2,000.
- The Chip32 loader (K1) makes a 2600-only bitstream practical inside the existing core, which leaves about 7,100 ALMs of 7800-only logic out of the DARIA build.

**Step 0's open items**, for step 1 to settle:

1. One bitstream or two (K1–K3): a hardware test of the loader switching bitstreams on a cartridge reload.
2. BUS stuffing into TIA writes (F7): check a BUS title against Stella or hardware, and find a BUS image for the bench.
3. 32 KB of cart RAM for CDFJ+ (M2), or halt above 16 KB.
4. DARIA's clock: S3's CPI wants about 32 MHz for Spiders (C6); with a 2600-only bitstream there is room for it.
5. Port sharing. The CPU reads ROM data through the image ROM's port B, which the front ends use too. The 6507 is held during a call, but the audio engine keeps ticking and, in digital mode, reads ROM samples. So step 1 needs an arbiter on that port, or the samples from another port.
