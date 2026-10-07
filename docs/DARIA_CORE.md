# DARIA: the 2600 ARM cartridges on ARIA

**DARIA** (Dual-use Atari RISC Interface Accelerator) is ARIA, the Pocket's BupChip CPU (`docs/BUPCHIP_CORE.md`), extended to run the 2600's ARM cartridge schemes: DPC+, CDF, CDFJ and CDFJ+ (Harmony and Melody cartridges). Upstream MiSTer runs them on its ARM7TDMI core, which the Pocket build leaves out (`NO_ARM_MAPPER`). The first release with DARIA will be 2.2.1.

**Steps 0 (scope), 1 (design), 2 (Thumb in simulation) and 3 (the probe build) are done; step 5 (the memory system) is in progress.** The first half of this document is what DARIA must do, taken from upstream's RTL and checked against traces of real games, and the decisions taken on it. "Design (step 1)" is how DARIA does it. "Steps" lists the work that follows, and "Open items" what is still to settle and when. The work started from `BUPCHIP_CORE.md`, "Later: 2600 ARM cartridges".

Tags, as in `BUPCHIP_CORE.md`:

| Tag | Meaning |
|---|---|
| [trace] | Measured on upstream's ARM7TDMI core, 1,500 frames per image (`sim/bupchip/daria/`, `tb_daria.sv`): the 15 Champ Games NTSC demos (the demo set) and, since 2026-10-05, six more images ("The added images", below). The images and everything made from them stay in `sim/work/`, never committed. |
| [C] | Read from upstream's RTL (`src/fpga/mister/rtl/`), Jamie Blanks's MIT code |
| [probe] | Quartus 21.1 on 5CEBA4F23C8 with the core's settings: the CPU alone with its ROM and RAM (`sim/bupchip/quartus_probe/`), or one front-end block alone with every input live (`sim/bupchip/daria/frontend_study/`) |
| [sim] | Measured in simulation of this repository's RTL, or of a scratch copy of it (step 1's experiments, in `sim/work/`) |
| [syn] | Yosys 0.69 (`abc -lut 6`, `synth_intel_alm`) on a small model of one block |
| [sta] | Read from a saved Quartus timing report |
| [doc] | Analogue's openFPGA developer documentation |
| [E] | Estimate |

## Rules

These carry over from ARIA:

- **Exact or halt.** An instruction either does exactly what the ARM7TDMI does, or the core halts with a code. Nothing is silently different.
- **Upstream is the oracle.** Upstream's ARM7TDMI and its 2600 front ends are the reference in simulation, retire by retire where the CPU is concerned, and on the 6507's bus everywhere else.
- **Clean room.** `arm7tdmi_core.sv` (GPL-2.0-only) is a simulation oracle, never a source. lroby74's MiSTer Thumb core (CC BY-NC 4.0) is a behavioural reference only. Upstream's MIT front ends may be read and reused.
- **No game data in the repository**, nor anything derived from it: ROMs, traces, listings, signatures.

## Decisions (2026-10-04)

1. **One bitstream.** DARIA joins the existing 7800 build. ARIA and DARIA are one CPU instance: a Souper game and a 2600 ARM game never run at once. The per-file bitstream findings (K1–K3) stay as the fallback if the single build cannot close.
2. **Fix B ships with DARIA** (`SRAM_TIMING.md`): the 2600 cartridge-RAM request gets its own registered path in the same release. With the device back at 80% or more, `clk_sdram`'s margin must not depend on placement again.
3. **Images up to 512 KB**, CDFJ+'s largest, with no game above 128 KB to test yet: a block-RAM window for the start of the image and a cache for the rest. (Step 1 serves the rest from the PSRAM rather than the SDRAM: "Design", choice 4.)
4. **32 KB of cart RAM** in block RAM (32 M10K), as upstream gives CDFJ+; the other schemes keep their 8 KB window inside it.
5. **`bupchip.bin` stays resident.** The CPU's ROM gets 16 KB beside the image window, and the profile picks the firmware or the image with one address bit set at load. A 2600 ARM game then never overwrites the firmware, and a Souper game loaded after one does not depend on the Pocket reloading `bupchip.bin` (16 M10K).
6. **No BUS.** BUS cartridges show the bad-game screen, as BUS0 already does upstream and every ARM scheme does in 2.1.x. No released game uses BUS. AtariAge will not sell BUS games because the scheme fails on a number of consoles, mostly the 2600 Junior and the 7800, and nothing has come of it since 2020.
7. **S1 with Thumb at 38.18 MHz (VCO ÷ 18); no S3** (2026-10-05, after step 3). DARIA is late only on Spiders' 16 calls at the start of play, the same calls upstream misses. S3 would end them in time too, but it costs a new pipeline and 150–560 ALMs. The owner takes the better 80% for the work: S3 stays a later revision ("Step 3 work", decisions).
8. **A 64 KB image window** (2026-10-07, step 5), not 128 KB. The small-window runs showed the cache over the PSRAM serving the image beyond 48 and 32 KB windows with no late call. Every image's code ends below 0xB30A, so 64 KB leaves about 19 KB of headroom for a larger CDFJ+ game's code. It frees 64 M10K for later improvements, and the fetch mux becomes 2:1. Code beyond the window halts with FETCH (open item 5). The owner kept 48 KB, closer to what the cart traditionally shows at once, as the tighter option.

## Requirements

### The CPU

| # | Requirement | Source | Status |
|---|---|---|---|
| C1 | **Thumb-1, all of it, exact or halting.** All but 40,446 of the demos' 460 M instructions are Thumb. Every format appears except SWI: F15 LDMIA in 3 demos (3,114), STMIA in 11 (1.53 M), F8 STRH in 14, F12 in 14, the rest in all 15. The added images use no other format and nothing that halts ("What halts"). | [trace] | Step 2 (the expander) |
| C2 | **ARM state: the drivers' helpers.** 14 of the 15 demo images (every CDF-family one) carry the same four helpers in their 2 KB driver at 0x750–0x7FF: Thumb trampolines at 0x750, 0x754, 0x758 and 0x75C (`ldr r4, [pc, #148]; bx r4`) branch to ARM routines at 0x760 (set a voice's frequency), 0x784 (reset its counter), 0x7A0 (read its counter) and 0x7BC (set its waveform size, a read-modify-write of two RAM tables). Each returns with `orr r4, lr, #1; bx r4`. Among the demos only Mappy calls one: the first, 4,494 times, which is all of the demos' 40,446 ARM-state instructions. Draconian, one of the added images, carries the helpers byte for byte and calls the first three: 5, 4 and 144 times (1,525 ARM-state instructions). Its second and third end with an ARM B to the first one's return, which no demo executes. The DPC+ images (Scramble; Space Rocks and Stay Frosty 2 among the added ones) have none. The 2026 CDFJ+ template (driver version 48) calls the same four at the same addresses (`defines_cdfjplus.c`), and its helpers are the demos' instruction for instruction, bar two RAM table addresses. The rest of a driver's first 2 KB is the Harmony's own bus loop, which no traced image executes: every traced PC is at 0x750 or above. | [trace], the images, [CDFJ+ template](https://github.com/Aganarr/cdfjplus-template) | ARIA already runs every ARM instruction they use, except the mode changes (C3, done) and the BX back to Thumb (C4) |
| C3 | **Processor modes.** The first three helpers switch to FIQ mode (`mrs r4, cpsr; msr cpsr_c, #0xD1`) and move values into or out of r8–r13, then restore the mode with `msr cpsr_c, r4`. Calls start in SYS mode (P1). So DARIA needs SYS and FIQ, FIQ's banked r8–r14, the I and F bits kept and read back by MRS, and MSR of the control byte from an immediate or a register. No SPSR access, no exception entry. | [trace], [C] | **Done**: `bup_cpu.sv`'s `MODES` 1 (below) |
| C4 | **Interworking.** BX both ways (Thumb `bx r4` to the ARM helper, ARM `bx r4` back with bit 0 set); `POP {pc}` and `LDR pc` do not change state on ARMv4T; BL as a prefix/suffix pair. | [trace], ARM ARM | Step 2 |
| C5 | **What never happens.** No SWI, undefined or coprocessor instruction, no unaligned access and no SPSR access in any trace. DARIA halts on all of them, as ARIA does. MMIO reads are as rare: the only one in any trace is Draconian's T1TC read (M4). | [trace] | Holds by the halt rule |
| C6 | **Speed.** Two calls a frame. Every call meets its budget at about 32 MHz with S3's CPI; S3 at 28.636 MHz misses only Spiders' 16 calls, as upstream does. The added images' worst calls need 17.7–21.3 MHz at CPI 1.4, against the demos' 11.8–41.6. | [trace] (`BUPCHIP_CORE.md`, "Later") | Step 3 measures |

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
| M1 | **ROM** at 0 up to the image size (capped at 1 MB), read-only. A write aborts. Images in the demo set: 32 KB (12), 64 KB (2), 128 KB (Turbo); the six added images are 32 KB. **DARIA supports images up to 512 KB**, CDFJ+'s largest (Stella's `CartCDF.hxx`: 64–512 KB of ROM with 16 or 32 KB of RAM, on the LPC213x boards; upstream's `detect2600.sv:70-72` accepts CDF images up to 524,288 bytes). None above 128 KB is available to test. The cartridge slot takes files up to 4 MB, and the loader keeps the whole file in SDRAM. | [C] `arm_mapper_memory.sv:375, 566-567, 624-626`; [trace]; `data.json` |
| M2 | **RAM** at 0x4000_0000, `mapper_ram_size` bytes: 32 KB for CDFJ+, 8 KB for every other scheme. A CDFJ+ game uses 8 KB with a 32 KB ROM, 16 KB with 64 or 128 KB, and 32 KB with 256 or 512 KB (the template's `cdfj+_template.asm` header). The demos stay inside 8 KB, except three CDFJ+ ones (Elevator Agent, Turbo, Zaxxon) that reach the 16th KB. The added images stay inside 8 KB. DARIA has the full 32 KB (Decisions, 4). | [C] `:568-569`, `top.sv:779-783`; [trace]; the CDFJ+ template |
| M3 | **MMIO window** 0xE000_0000–0xE01F_FFFF (`addr[31:21] == 0x700`): MAMCR (0xE01F_C000) and timer 1's TCR (0xE000_8004) and TC (0xE000_8008) read back. Everything else in the window reads 0 and drops writes, and never aborts, because the drivers program the PLL, MEMMAP, MAM timing, PINSEL and TIMER0. The demos write MAMCR (Scramble, 4,172 times) and nothing else, and read nothing. Of the added images, the DPC+ ones write MAMCR twice a call, and Draconian uses timer 1 (M4). Timer 1's other registers (prescaler, match, capture; the template defines them all) and APBDIV read 0 on upstream too, so a game that set T1PR would see the timer run at full rate there as well. | [C] `:570-575, 606-609`; [trace]; the CDFJ+ template |
| M4 | **Timer 1** counts at 70 MHz while enabled (TCR bit 0). Upstream divides its 5 × `clk_sys` ARM clock: it skips 1 tick in 45 for NTSC (exactly 70 MHz) and 1 in 76 for PAL (70.0045 MHz). DARIA's clock will differ, so it counts on `clk_sys` instead: per 9 clocks 8 × 5 + 4 (NTSC), per 76 clocks 71 × 5 + 5 × 4 (PAL), the same rates. No demo touches it. Draconian times one frame with it at power-on and compares the count with 1,171,987, 0.33% above an NTSC frame's ("The added images"), so the rate must be right to better than that; counting `clk_arm` undivided would read 2.3% high on upstream. | [C] `:474-489, 729-737`; [trace]; [sim]; [E] |
| M5 | **Anything else** (outside ROM, RAM, the MMIO window and the sentinel) aborts on upstream. DARIA halts. | [C] `:603-604, 626` |

### The 6507 side (front ends)

The front ends are the cartridge logic the 6507 sees: bank switching, the data fetchers and streams, the "LDA #" fast fetch, fast jump, BUS stuffing, the call trigger, the copy/fill service and the AMPLITUDE register. `sim/bupchip/daria/frontend_study/README.md` has the full register maps and upstream's quirks; these are the requirements that shape the design.

| # | Requirement | Source |
|---|---|---|
| F1 | **Bus timing.** A 6507 cycle is 12 `clk_sys`. The address is valid from the phase-1 edge (E0). The CPU latches read data at E0+6, and the front end commits its state on that edge, only when `access` is high. So a read has 6 `clk_sys`. During a call or a copy, RDY holds the read and the front end sees only its first phase 2. | [C] `top.sv`, `6502/mos6502_dp.sv:299`, `TIA.sv:505-557` |
| F2 | **DPC+:** 8 fetchers (12-bit counter, top, bottom, 20-bit fraction, increment), the 32-bit random number, 3 waveforms and notes, PUSH and WRITE, 6 banks, fast fetch on any `$A9` read, the copy/fill service (the 6507 held meanwhile), and the call (`$FE`/`$FF` to CALLFUNCTION). | [C] `mapper_dpcplus.sv` |
| F3 | **CDF, CDFJ, CDFJ+:** 32-bit stream pointers and increments in cart RAM (34 or 35 streams; table addresses per version), DSWRITE/DSPTR, SETMODE, fast fetch at the address after `$A9` (CDFJ+ also `$A2`/`$A0` and a fetch offset), fast jump on `$4C` with a two-byte lookahead in the image, 7 banks. | [C] `mapper_cdf.sv`, `cdf_fastjump_table.sv` |
| F4 | **BUS (1–3), left out (Decisions, 6):** streams and a map in cart RAM, STY stuffing into TIA/RIOT writes, BUS3's fast jump. BUS0 shows the bad-game screen. No released game uses BUS: Stella calls the scheme experimental and lists only development builds and demos from 2016–2017 (an early Draconian, `128bus`, `128chronocolour`, `parrot`, `rpg`; `CartBUS.hxx`). None is in the test set: the library's two Draconian builds are CDF1. | [C] `mapper_bus.sv`; Stella |
| F5 | **AMPLITUDE.** A 20 kHz tick on `clk_sys` adds each voice's frequency to its counter. DPC+ sums three waveform samples from RAM; CDF and BUS sum three samples through each voice's pointer and size words, or in digital mode return a nibble of a ROM or RAM byte. | [C] `arm_mapper_audio.sv` |
| F6 | **The RAM image.** At load end and on every console reset, with the console held: DPC+ zeroes RAM and copies the image's display data; CDF and BUS copy the 2 KB driver and zero the rest. | [C] `arm_mapper_ram_init.sv` |
| F7 | **Upstream's quirks**, kept where a game could see them: DPC+ fast fetch arms on data bytes too; hotspots are ignored on substituted reads; the jump lookahead crosses bank ends; the BUS map aliases `$20–$24`. Two are open: BUS stuffing reaches the RIOT but not the TIA (an upstream bug?), and upstream's data bus changes after the latch edge, which only `open_bus` keeps. | [C], study §2.7 |

**Why upstream's front ends are large.** 2.1.1 carried them at 1,752 ALMs (2.1.2 leaves them out: `SRAM_TIMING.md`, Fix A), but with the ARM tied off synthesis had removed half of them. Compiled alone with every input live, the seven blocks take **2,192 ALMs**, and the call controller that DARIA would need with them another 716 (about 1,150 of its flip-flops carry the six audio values across clocks) [probe]. The causes:

- DPC+ keeps its 8 fetchers in flip-flops with eight copies of every adder, comparator and load mux: about 690 of its 832 live ALMs.
- CDF and BUS copy their pointer tables out of cart RAM into two M10Ks, snoop the ARM's writes into the copies and write updates back across clocks.
- About a dozen 32-bit adders and carry registers, of which at most two work in any 6507 cycle.
- Upstream's read path runs from the SDRAM byte through the decode to SRAM within one cycle and is timed at `clk_sdram`. It forces the parallel window compares, and in the full build the fitter duplicated `mapper_dpcplus` by 47% for it (the path in `SRAM_TIMING.md`).

The lean front end that replaces them is in "Design (step 1)".

### The added images (2026-10-05)

Six images joined the test library after step 1, all of them 32 KB. Each was traced as the demos were [trace]. The images, their traces and the scripts' per-image output stay in `sim/work/`; below are statistics only.

| Image | Scheme | Calls | ARM state | MMIO | Cart RAM | Worst call: MHz at CPI 1.4 |
|---|---|---|---|---|---|---|
| Draconian, Harmony-fix build | CDF1 | 3,000 | the helpers: 1,525 instructions in 147 calls | timer 1: 3 writes, 1 read | 8 KB | 18.41 |
| Draconian, 2017-10-20 RC8 | CDF1 | the same trace, call for call | | | | |
| Space Rocks, Harmony fix | DPC+ | 2,999 | none | MAMCR, 2 writes a call | 8 KB | 17.65 |
| Robot War: 2684 demo, Harmony fix | CDFJ | 2,999 | none | none | 8 KB | 18.03 |
| Stay Frosty 2 (`SF2fix`), NTSC | DPC+ | 2,577 | none | MAMCR, 2 writes a call | 8 KB | 21.29 |
| Stay Frosty 2 (`SF2fix`), PAL | DPC+ | the NTSC build's trace, call for call | | | | |

- **The Harmony fixes do not reach DARIA.** The two Draconian builds differ in 927 bytes, all inside the 2 KB driver. 925 lie below 0x750, in the Harmony's own start-up and bus code, which no trace executes. The other 2 lie at 0x7F8–0x7FC, past the helpers' literals: the only ROM reads in that kilobyte are the trampolines' 153 literal loads. So the two traces are identical. Robot War's Harmony-fix build keeps the demo's driver byte for byte and differs from the demo in 28,724 bytes after it, so it is a rebuilt game and is traced as one. Its worst call needs 18.03 MHz at CPI 1.4, the demo's 17.84.
- **Draconian's helpers (C2).** It is the only traced game that resets a voice's counter (the second helper, 4 calls) or reads one (the third, 144). That makes it the first real use of P1's counter load into FIQ r8–r10 and of P2's rule that a counter is taken back only if it changed.
- **Draconian's timer (M4)** is a single frame measurement at power-on, in its second and fourth calls; "Precision" in the memory system (6) has the numbers and DARIA's error budget for it.
- **Space Rocks' first call** is its start-up: 117,525 instructions, 3.5 ms on upstream with the 6507 held, and no timer deadline after it. At 32.73 MHz and CPI 1.4 it would take about 5.0 ms, once, at power-on.
- **Stay Frosty 2** makes about one call a frame in its attract mode and two in play. Its PAL build differs from the NTSC one in 281 bytes and also runs 262-line frames, so it is a PAL60 build; its trace matches the NTSC build's call for call. (The bench runs the console with NTSC clocks, as it does every image.)
- **Nothing new for the CPU.** No Thumb form the demos do not use, nothing that halts, no MUL site from which a path reads C (C1; "The CPU: Thumb"), and code ends below 0x5700.
- Every image reaches play in its trace (the snapshots at frame 1,350).

### Packaging

| # | Finding | Source |
|---|---|---|
| K1 | **A bitstream can be chosen per loaded file.** `core.json` may list up to 8 bitstreams. A Chip32 loader program (`framework.chip32_vm`) runs before the FPGA is configured, can read the file's extension (`GETEXT`) or header (`OPEN`, `READ`), and loads bitstream *n* (`CORE n`). agg23's SNES core picks one of 3 bitstreams from the ROM header this way. | [doc] (read from a mirror of Analogue's pages; analogue.co is blocked here), example cores |
| K2 | **No menu choice, no switch from a running core.** `variants.json` is "an upcoming feature"; no target command reloads a bitstream. Reloading the cartridge slot (`0x109`, bit 8: "the bitstream is also reloaded") restarts the core and runs the loader again, so going from a 7800 game to a 2600 ARM game should change bitstream. Not yet seen on hardware. | [doc] |
| K3 | **Alternatives:** a second core entry (`Miasmark.2600`) from this repository, with its own folders and settings; or both, sharing one 2600 bitstream. | [doc], example cores |

So a 2600-only bitstream without the 7800's MARIA, YM2151, POKEYs, 7800 mappers and BupChip (about 7,100 ALMs) could ship inside the existing core. It is the fallback, not the plan (Decisions, 1): the loader sends `.a78` files to today's bitstream and 2600 files (or only ARM-scheme ones) to the other. The cost is a loader that must load every data slot itself, a shared `interact.json`, and a 2600 bitstream that answers the save slots exactly as today's does.

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

**The hand-off (P1, P2)**, as step 0 sized it (step 1 designs it: the memory system, 5). Upstream crosses six 32-bit values each way through a mailbox, two-flop synchronisers and result registers: about 1,150 flip-flops in its controller. DARIA can do without them. Its launch sequence writes the register file through the write port anyway (r0–r12, r13, r14, PC, CPSR), so FIQ's r8–r13 are six more writes, and the return reads them back through a read port while the CPU is halted. With the counters, frequencies and launch values in the front ends' state RAM, the controller is 100–150 ALMs [E] against upstream's 716.

## Step 2 work: Thumb in simulation

`bup_cpu.sv` has two more parameters and one more input:

- **`THUMB`** (default 0). 1 is DARIA: Thumb as well as ARM, with `MODES` 1 implied. With 0 every Thumb path folds away.
- **`CODE_AW`** (default 12, the 16 KB ROM): the code space in words. The window checks, branch targets, jump targets and the end-of-code check follow it. DARIA's 128 KB window is 15.
- **`arm_only`**, a static input, the BupChip profile: T stays 0, and BX to an odd address halts with code 3, as in ARIA. The Pocket wrapper ties it high.

The retire port gains `rt_t` (T after the instruction) and `rt_cunk` (C unknown after it).

**How it is built** (current line numbers in `bup_cpu.sv`):

- **The halfword PC.** `pc` stays the word address (`rom_addr`), and `pc_h` is the half of `rom_q` in execute, registered with it (`:274-295`). The next instruction in sequence is the same word with the other half after a low half (`seq_w`, `seq_h`). The end of the code space is checked on the step that leaves it. r15 reads address + 4 in Thumb, word-aligned for F6 and F12 (`pcrel`). The Thumb BL suffix links (address + 2) | 1.
- **Decode beside ARM.** ARIA's decode keeps its logic under `a_` names (`:297-395`). The Thumb decode (`th_`, `:397-529`) fills the same controls from the pre-muxed halfword, and the controls the rest of the core uses are merged by T (`:531-590`). Each Thumb format maps onto an ARM class: data processing, a single transfer, LDM/STM, or a branch. Four cases have controls of their own: the BL suffix (`k_bl2`), MOV pc, ADD pc (two clocks: the sum goes through `wb_value`, and the second clock reuses UMULL's `S_MUL3`) and BX.
- **The read indices.** The first clock's Thumb indices come from both halves of `rom_q` (`t_port_a`, `t_port_b`) and are picked by `pc_h` at the end. With `THUMB` 1, each candidate is bank-remapped before the select (`pa_x`, `pb_x`, `:636-660`).
- **Registered role fields.** The register fields of the clocks after execute (W, a shift's second clock, MUL, LDM/STM) are registered at the end of execute (`x_rd`, `x_rn`, `x_rm`). They equal the re-decoded fields, because `rom_q` does not change meanwhile. Registered, they keep the Thumb decode off those clocks' index and write paths. The design document did not have this: the depth check below found that without it the later clocks' re-decode set the depth.
- **Jumps.** Register targets (BX, MOV pc, ADD pc, POP {pc}, the BL suffix's sum) go through one function, `jump`. It drops bit 0, splits the address into word and half, and flags a target outside the code space (`:938-943`). BX writes T from bit 0 of Rm, unless `arm_only`. POP {pc} loads the jump from its last beat and leaves T as it is.
- **C after a Thumb MUL.** The MUL's second clock writes N and Z, keeps C's bit and V, and sets `c_unk`. Anything that defines C clears it: an arithmetic flag-setting operation, a non-zero shift or rotation, or MSR with the f field. An instruction that reads C while it is set halts with code 8 (`flags_halt`, `:914-922`). A condition on C halts whether or not the condition would pass.

**Results [sim]** (on the core at the commit that closes this step):

| Check | Result |
|---|---|
| Directed (`thumb/run_directed.sh`): 12 programs, every format group, the flag corners, interworking in SYS and FIQ mode, code at the last halfword of the code space | 12 of 12 on the reference; in lockstep plainly, with `+await=40 +throttle=25` (two seeds) and with `LATE_RF=1`, 0 mismatches |
| Halts (`run_halts.sh`): 210 cases | Every code (1, 3–8) at its expected address, plainly, with `LATE_RF=1` and with throttle and waits. Where the reference takes UND or SWI (36 cases) it does so at the same address. The 46 cases that must not halt also pass lockstep. |
| Exhaustive decode (`run_decode.sh`): 65,536 halfwords × both halves × C known and unknown | 0 differences from `thumb_expand.py --table` |
| Random streams (`run_random.sh`): seeds 1–400, 300 operations | 400 of 400: reference and Unicorn agree on all of RAM and the instruction count; lockstep plainly, with `+await=20 +throttle=10` and with `LATE_RF=1`, each 523,864 retires, 413,172 RAM stores and 800 peripheral writes compared, 0 mismatches (C skipped in 42,673 records after a Thumb MUL) |
| Fuzz (`run_fuzz.sh`): seeds 1–48, 200 cells each | 48 of 48 plainly, with `LATE_RF=1` and with `+await=20 +throttle=10`. Per variant: 193,605 retires compared, and 2,191 halts, each at the predicted halfword with the predicted code. |
| Mutations (`run_mutants.sh`): the 16 of "The CPU: Thumb", verification (F5's flags split in two, so 17) | 17 of 17 caught: 12 by the decode check, 5 by the directed tests (POP {pc} interworking, NEG of Rd, SBC's carry inverted, STMIA storing the old base, MUL writing V). The suites' own authors planted 11 to 45 more each while building them; every one was caught. |
| ARIA unchanged, formally (`aria_equiv.sh`) | With `THUMB` 0 the core is sequentially equivalent to its step 0 version (806dcd4), register file included: `MODES` 0 (1,890 signals matched) and `MODES` 1 (2,430) |
| ARIA's checks on the Thumb core (`THUMB=1 s1/check.sh rv.a78`: `THUMB` 1 with `arm_only`) | Every step passes: the directed and halt tests, the further directed tests and fuzz, the verifier's tests (also with `LATE_RF=1`), the ISA suite and the mixer harness in lockstep, the synthetic ARSC checks, Rikki & Vikki through boot and Misery_F, and songs 13, 14, 9 and 30 PCM-identical to MiSTer's (Misery_F at CPI 1.3772) |
| ARIA's checks with `THUMB` 0 (`s1/check.sh rv.a78`) | The same, every step passing, with the same CPI |
| Step 0's modes checks on the Thumb core (`THUMB=1 ARM_ONLY=1 daria/modes/run_modes.sh`) | `modes.S` in lockstep plainly, with waits and throttle and with `LATE_RF=1`; on `tb_s1` it runs to its end marker (MODES 1 takes its MSRs); ARIA's directed tests and fuzz seeds 1–8 in lockstep |
| Index-path depth (`index_depth.sh`, LUT6 levels after `abc -lut 6`, from `rom_q` and the registered state to the physical read indices) | ARIA: port A 4, port B 5. DARIA: port A 5, port B 4. The worst of the two is unchanged. Port B, which feeds the shifter on the critical path, is a level shorter. Port A, which goes straight to the adder, is a level longer. |

- **"ARIA unchanged" is a proof, not a cell count.** The plan asked for Yosys cell counts equal to today's. They cannot show it: ABC's result moves by about 1% with any change to the source text, even a renamed wire (`yosys_cells.sh`: 1,885 LUTs before the step, 1,862 after only re-expressing the same logic with `CODE_AW`). The equivalence proof is the stronger check.
- **Area [syn, probe].** Yosys: 2,410 LUTs and 341 flip-flops with `THUMB` 1, against 1,867 and 323 with `THUMB` 0 (`MODES` 1). Quartus, with DARIA's memories: 1,720 ALMs, +345 over ARIA. That is inside the 300–500 estimate.
- **Timing [probe]:** "Clock", the early probe. 32.73 MHz closes with +0.03 ns in an empty device, so the one-clock-store fix moves into step 3's must-haves.
- **What the reference does that DARIA does not, both as ARIA in ARM state:**
  - LDM/STM, PUSH and POP to the peripheral page or the assets do not abort on the reference. DARIA halts with code 7.
  - An `ldr rX, [pc]` at 0x3FFE reads 0x4000. Its DATA halt (5) wins over the FETCH of running on.
- **A bench limit.** When the DUT halts, the last instruction it retired before the halt is not compared, because a record closes only at the next start. For a FETCH halt that is the jump itself. Such jumps are compared in the lockstep runs where they reach valid targets.
- **`verif/directed/vhalt.py`** expects MSR to SYS mode, and MSR with I or F clear, to run on when the core has `MODES` 1 (`THUMB=1` or `MODES=1` in the environment).

## Step 3 work: the probe build

**The one-clock-store fix** (`BUPCHIP_CORE.md`, risk 2). `bup_cpu.sv` now decides a one-clock store from Rn and the immediate offset on an adder of its own (`st_off`, `st_addr`, `st_ram`, `:896-898`), not from the region of the ALU's sum. A store can take one clock only with an immediate offset, and there the two addresses are the same, so the change is exact:

- `thumb/aria_equiv.sh`: with `THUMB` 0 the core is still sequentially equivalent to step 0's ARIA (806dcd4), for `MODES` 0 (1,888 signals matched) and `MODES` 1 (2,428).
- The step 2 suites on the changed core:
  - decode: 0 differences;
  - directed: 12 of 12 in all five variants;
  - halts: 210 of 210;
  - fuzz: 48 of 48 in all three variants, with the same 193,605 retires and 2,191 predicted halts;
  - random: 400 of 400 seeds;
  - `s1/check.sh rv.a78`: passes with `THUMB` 1 + `arm_only` and with `THUMB` 0. The four songs are PCM-identical to MiSTer's in both, and Misery_F's CPI is unchanged at 1.3772.
- The adder costs about 50 ALMs. In the empty device the CPU is 1,769–1,781 ALMs, against 1,720 before.

**Empty device [probe]** (`quartus_probe/run_probe.sh`, `WINDOW=1 THUMB=1`: DARIA's memories at full size, 180 M10K). Worst setup slack at slow 85 °C:

| Seed | CPU ALMs | 32.73 MHz | 40.43 MHz |
|---|---|---|---|
| 1 | 1,773 | +3.135 ns (Fmax 36.47) | −2.310 ns (36.97) |
| 2 | 1,778 | +2.042 ns (35.07) | |
| 3 | 1,769 | +2.771 ns (35.99) | |

- **The worst path no longer goes through the store decision.** Seeds 1 and 2 end in the register file's write data: window → slice mux → profile mux → read-index select → MLAB read → bypass → shifter → operand mux → adder → result mux, 17–18 levels. That is S1's ordinary execute path.
- **Seed 3 ends in `rom_addr`, through the Thumb BL suffix's target** (`jump(sum)`, LR + offset). Its shifter leg is just as false as the store's was. From `rom_addr` the path runs into the window's per-slice read-enable decode (`altsyncram`'s low-power decode) and then the slices' clock enables. Both are taken out below ("Two more levers").

**Full build at ÷21 and ÷17 [probe]** (`quartus_probe/full/run_full.sh`, Quartus Lite 21.1.1 as CI runs it). The probe is the shipped core (`POCKET_BUPCHIP`, no `BUP_DEBUG`) with DARIA's CPU and memories in `bupchip_pocket.sv`:

- the CPU: `THUMB` 1, `CODE_AW` 15, `arm_only` low in the 2600 profile;
- the firmware ROM and the 128 KB window behind the profile mux;
- the 32 KB cart RAM, with port B on `clk_sys`;
- the 32 KB front-end ROM on `clk_sys`;
- `clk_arm` at VCO ÷ 21 (PLL counter 3 at 11/10, with odd duty) or ÷ 17 (9/8);
- the crossings below.

It does not have:

- the front ends' logic;
- the call port, the MMIO and timer;
- the state RAM and the cache's second way (4 M10K);
- Fix B.

Against the core as it is (`BASE=1`, ARIA at ÷24), at slow 85 °C:

| Build | ALMs | M10K | CPU ALMs | `clk_arm` setup (Fmax) | hold into `clk_arm`, worst corner | `clk_sdram` setup | `clk_sys` setup |
|---|---|---|---|---|---|---|---|
| ARIA, ÷24 (28.64 MHz), seed 2 | 12,968 (70.2%) | 78 | 1,308 | +9.552 ns (39.42) | +0.121 ns | +1.158 ns | +11.318 ns |
| DARIA, ÷21 (32.73 MHz), seed 1 | 13,617 (73.7%) | 254 | 1,748 | +2.197 ns (35.26) | +0.128 ns | +2.356 ns | +10.532 ns |
| DARIA, ÷21, seed 2 | 13,604 (73.6%) | 254 | 1,729 | +3.072 ns (36.38) | +0.023 ns | +2.656 ns | +8.114 ns |
| DARIA, ÷21, seed 3 | 13,609 (73.6%) | 254 | 1,741 | +3.019 ns (36.31) | −0.033 ns (the $8007 byte, a crossing) | +2.109 ns | +10.893 ns |
| DARIA, ÷17 (40.43 MHz), seed 2 | 13,710 (74.2%) | 254 | 1,812 | −1.181 ns (38.58) | +0.139 ns | +2.471 ns | +10.587 ns |

**The crossings (open item 9).** The clock groups stay as they are. The `clk_sys` ↔ `clk_arm` paths get `set_max_delay 20` and a `set_min_delay`, each way, in place of the edge relation. At ÷21 that relation can be one VCO period (1.46 ns).

- **The forms built:**
  - seeds 1 and 2 also bounded `clk_arm` against `clk_sdram` and `clk_sys_90`;
  - seed 3 used 7.3's form, which leaves those two at their real relation as a tripwire;
  - the three ÷21 builds used `set_min_delay` 0, the later builds 7.3's −20.
- **Quartus Lite 21.1 honours the exceptions.** Its exceptions report lists each as complete, not overridden, and every crossing is timed against 20 ns.
- **The tripwire stays quiet.** There is no path at all between `clk_arm` and `clk_sdram` or `clk_sys_90`, so the two forms time the same paths.
- **The paths**, across the three seeds:

  | Direction | Endpoints | Worst setup slack | The path |
  |---|---|---|---|
  | `clk_sys` → `clk_arm` | 61–63 | +15.1 ns | the capture's message payload into the receiver, about 4 ns of data delay |
  | `clk_arm` → `clk_sys` | 33–34 | +15.2 ns | the frame toggle, 2.6 ns |

- **Hold: keep −20.** With `set_min_delay` 0 the crossings were checked for hold too. On seed 3 the $8007 command byte (`cmd_byte` → `cmd_data_arm`) missed by 0.033 ns at fast 0 °C. That bus is held for two `clk_arm` clocks before the toggle lets it be used, so the check means nothing there, and 7.3's −20 removes it.
- **Hold inside `clk_arm`** has positive slack at every corner on every build. On seeds 1 and 2 even the worst hold slack of any path into `clk_arm`, crossings included, is +0.128 ns and +0.023 ns, against +0.121 ns for ARIA.
- **This is step 7's form.** The same lines go into `core_constraints.sdc`, and its comment that `clk_arm` is 2 × `clk_sys` goes.

**Two more levers: S1 at 40.43 MHz [probe].** All ten of the worst paths in the 40.43 MHz full build ran:

- from the window, through the register-file read, the shifter and the adder;
- to `rom_addr[14]` and the window's per-slice read-enable decode (`altsyncram`'s low-power decode);
- into the slices' clock enables.

That is the Thumb BL suffix's target, LR + offset, which went through the ALU (`jump(sum)`), so its shifter leg is false like the store's was. Two changes take it out:

1. **`bup_cpu.sv` computes the suffix's target on an adder of its own** (`bl_sum`, `:902`, used at `:1041`). It is exact, so the Thumb suites pass unchanged on it:
   - directed: 12 of 12 in all five variants;
   - halts: 210 of 210;
   - fuzz: 48 of 48 in all three variants;
   - random: 400 of 400;
   - decode: 0 differences.

   With `THUMB` 0 the suffix never decodes, and `aria_equiv.sh` proves the final core, with both adders, equivalent to step 0's ARIA for `MODES` 0 and 1.
2. **The window as four 8K-deep RAMs read every clock, with a 4:1 mux on registered address bits** (`daria_probe.py --win4`, `run_full.sh WIN4=1`). There is no read-enable decode on `rom_addr`'s path. This is how step 5's wrapper builds the window (1.2).

With both, 40.43 MHz misses by −0.466 ns (Fmax 39.68 MHz, 13,705 ALMs, seed 2), against −1.181 ns without them. The worst path is now S1's ordinary execute path, from the window through the register-file read, the shifter and the adder into the register file's write data. Neither lever touches it.

**Late calls by clock and CPU [trace]** (`daria/dynamic_tables.py --only divs` on the traced runs: the bench's S1 and S3 cycle estimates, the image in block RAM, no margin). These are all 21 traced images, the 15 demos and the added ones:

| CPU, clock | Late calls | The highest share of a call's budget |
|---|---|---|
| S1, ÷21 (32.73 MHz) | 34: Spiders 33, Qyx 1 | Spiders 121%, Qyx 107%, Zaxxon 100%, Elevator Agent 99% |
| S1, ÷20 (34.36 MHz) | 17: Spiders 16, Qyx 1 | Spiders 116%, Qyx 102% |
| S1, ÷19 (36.17 MHz) | 16, all Spiders | Spiders 110%, then Qyx 97% |
| **S1, ÷18 (38.18 MHz)** | **16, all Spiders** | **Spiders 104%, then Qyx 92%** |
| S1, ÷17 (40.43 MHz) | 0 | Spiders 98% |
| S3, ÷24 (28.64 MHz) | 16, all Spiders | Spiders 111%, then Qyx 96% |
| S3, ÷21 (32.73 MHz) | 0 | Spiders 97% |

- **Spiders' 16 are upstream's 16.** At ÷19 and ÷18 they are the same calls the reference misses on upstream's own core, frames 557–572 at the start of play (`sim/work/bupchip/daria/dynamic_report.md`, "Spiders overruns on upstream's own core").
- **Step 8 already accepts these 16:** "Spiders aside if it overruns as on upstream".

**Full build at ÷18 (38.18 MHz) [probe]**, S1 + Thumb with both levers, `set_min_delay` −20:

| Seed | ALMs | CPU ALMs | `clk_arm` setup (Fmax) | hold into `clk_arm`, worst corner | `clk_sdram` setup |
|---|---|---|---|---|---|
| 1 | 13,700 (74.1%) | 1,876 | +1.305 ns (40.18) | +0.143 ns | +1.852 ns |
| 2 | 13,712 (74.2%) | 1,877 | +0.288 ns (38.61) | +0.112 ns | +2.210 ns |
| 3 | 13,684 (74.0%) | 1,866 | +0.708 ns (39.24) | +0.170 ns | +2.998 ns |

The setup slack and `clk_sdram` are at slow 85 °C; the hold slack is the worst corner, fast 0 °C.

- **The worst paths** are S1's execute path into the register file's write data, 17–18 levels.
- **The crossings** have at worst +13.5 ns of setup slack, and no hold check at −20.
- **Nothing crosses** between `clk_arm` and `clk_sdram` or `clk_sys_90`.
- **At this clock** the fitter spends about 130 ALMs more on the CPU than at ÷21.

**Decisions.**

- **CPU and clock: S1 with Thumb at ÷18, 38.18 MHz. S3 is not built.** The owner accepted this (decision 7).
  - **The result is upstream's.** Only Spiders' 16 calls at the start of play run late, the same ones upstream misses. Every other traced call stays within 92% of its budget.
  - **What S3 would add.** At 32.73 MHz it would end those 16 calls in time too (Spiders at 97%). The price:
    - step 4, a new pipeline with a 2-write/3-read register file;
    - 150–560 ALMs, whose top end breaks the 84% gate (the projection below);
    - a path at 32.73 MHz that nobody has measured.
  - **S3 stays a later revision**, in case Spiders' start-of-play overrun ever matters, as the carry after a Thumb MUL does (open item 4).
  - **40.43 MHz** would end every call in time with S1, but it misses by 0.47 ns.
  - **The timing margin at ÷18 is thin on some seeds.** It ranges from +0.29 to +1.31 ns, and the front end and the rest of the memory system still have to join. If step 7's integrated build cannot hold ÷18 on three seeds, ÷19 (36.17 MHz) is the fallback. It has the same 16 late calls and 1.46 ns more period, but Qyx's heaviest call then takes 97% of its budget, against 92%.
- **Window: 128 KB, as four 8K-deep RAMs** with a registered 4:1 mux. It fits and closes at that clock. The probe's 254 M10K, plus the 4 it leaves out, is the 258 of 308 budgeted. A 64 KB window is not needed.
- **Area.** The projection adds what the probe leaves out:
  - the front end, 850–1,100;
  - the rest of the memory system, 320–550 (the 390–620 of "Budget", less the window's mux, which the probe measured);
  - Fix B, −10 to +20.

  | Build | ALMs | Share of the device |
  |---|---|---|
  | Measured at ÷18 (the largest seed) | 13,712 | 74.2% |
  | Projected | 14,872–15,382 | 80.5–83.2% |
  | S3, had it been built (+150–560 more) | 15,022–15,942 | 81.3–86.3% |

- **What follows for later steps:**
  - step 4 (S3) is dropped;
  - `psram.sv` at 38.18 MHz becomes open item 10;
  - the BupChip runs at 38.18 MHz too. CoreTone paces itself on the 48 kHz tick, so it only idles more.

## Step 5 work: the memory system (done 2026-10-07)

Paused by the owner on 2026-10-05 with the pieces built and tested on their own benches, and DARIA compared with upstream call by call on five images; resumed on 2026-10-06 with the wrapper; done on 2026-10-07. DARIA matches upstream's ARM call by call on all 21 images, late only where upstream is, and the cache serves the image beyond 32, 48 and 64 KB windows with no late call. The owner took the 64 KB window (decision 8).

### What is built

| Part | File | State |
|---|---|---|
| The 2600 profile and the call port in the CPU | `bup_cpu.sv` (`WIN_KB`, `prof26`, `img_size`, `ram32`, `call_go`, `clr_*`, `parked`, `returned`, `ro_*`) | Done. The map of section 4 (window and image beyond it split at `WIN_KB`; 8 or 32 KB of cart RAM; MMIO 0xE000_0000–0xE01F_FFFF), code space per profile (open item 18: 16 KB in the BupChip profile), the parked state, the launch through S_CLEAR (22 entries, `clr_e`/`clr_wd`), the 0xF000_0000 return on every kind of jump, and the FIQ r8–r13 readout. Existing instances tie the new ports |
| Memories | `daria_mem.sv` | Done: the window as `WIN_KB` / 32 RAMs of 8K × 32 with a registered mux (two and 2:1 at decision 8's 64 KB; four and 4:1 at 128 KB, kept for test builds), cart RAM 8K × 32 with byte lanes (port B on `clk_sys`), the front-end ROM, the state RAM, all one `daria_ram` (TDP, byte lanes, `maximum_depth` 8,192) |
| Call port, `clk_arm` side | `daria_call.sv` | Done: the call block in state RAM words 0xF0–0xFD, `call_tog`/`ret_tog` |
| MMIO and timer 1 | `daria_mmio.sv` | Done (section 6, with the changes below) |
| Image capture | `bup_capture.sv`, `bup_asset_wr.sv` | Done (section 2, with the changes below) |
| Two-way cache | `bup_asset_cache.sv` (`WAYS`) | Done (section 3, with the changes below) |
| Wrapper | `bupchip_pocket.sv` under `POCKET_DARIA` | Done (2026-10-06; below). The shipped build is unchanged |

### The wrapper (`POCKET_DARIA`)

- **Profile and hold.** `daria_profile`, `daria_ram32` and the mapper reset reach `clk_arm` through two flops. The hold also releases for `daria_profile`. The run gate is `img_ready` in the 2600 profile and `fw_loaded & asset_ready` in the BupChip's, and a mapper reset holds the CPU in the 2600 profile only (a 7800 reset leaves the music playing, as before).
- **CPU:** `THUMB` 1, `CODE_AW` 15, `WIN_KB`; `arm_only` in the BupChip profile.
- **Memories:** `daria_mem`. The profile picks `rom_q` and `rom_dq` between the window and the firmware ROM. The cart RAM replaces the BupChip's RAM, which is its low 16 KB. The front-end ROM takes the cartridge slot's bytes below 32 KB inside the capture's cartridge window.
- **Cache:** `WAYS` 2. `daria_call` and `daria_mmio` are both held while `cpu_run` is low, so a new cartridge, a mapper reset or a PAL retune clears MAMCR, TCR and TC (P4) and abandons a call.
- **MMIO.** The peripheral sees `reg_sel` only in the BupChip profile, `daria_mmio` only in the 2600 one, and the peripheral is held in the 2600 profile. Upstream's peripheral decodes `reg_rdata` from `reg_addr` alone, without `reg_sel`. Its word is therefore masked in the 2600 profile; otherwise a MAMCR read would OR in its ID word, and a T1TC read its status bits.
- **Front ends' side** (`clk_sys`): `daria_call_tog` in, `daria_ret_tog` out, `daria_ready` (parked and `img_ready`) and `daria_halted` through two flops, and the state RAM's, cart RAM's and front-end ROM's B ports.
- **Synthesis** (`quartus_probe/daria_wrap_map.sh`, Analysis & Synthesis only). Every RAM maps as designed:
  - the window, the cart RAM and the front-end ROM as 8K × 32 true-dual-port M10K, the cart RAM with byte lanes on two clocks;
  - the state RAM 256 × 32;
  - the cache's tags 2 × 128 × 14 and data 2 × 512 × 32.

  The wrapper's estimates:

  | Wrapper | ALMs (estimate) | Registers | Block memory bits |
  |---|---|---|---|
  | DARIA, 64 KB window (decision 8) | 2,981 | 1,283 | 1.26 M |
  | DARIA, 128 KB window | 3,007 | 1,285 | 1.78 M |
  | The shipped wrapper | 2,033 | 948 | 0.30 M |

  The check found that the two-way cache's bare `generate` `if` fails Quartus 21.1, in the shipped build too; it now spells out the region.
- **The benches through it.**
  - `s4`: `DARIA=1` builds the wrapper with `POCKET_DARIA`, `+arm38` runs `clk_arm` at 38.18 MHz, `PSRAM_CS` sets `psram.sv`'s `CLOCK_SPEED`, and `ARM38=1` runs a whole `check.sh` at 38.18 MHz.
  - `tb_daria`: `WRAPPER=1` runs DARIA as the whole wrapper in the 2600 profile. The cartridge is captured from the loader, and the image beyond the window comes through the cache over `psram.sv` and `psram_model.sv`.

### Results

- **ARIA unchanged.** The formal check (`thumb/aria_equiv.sh`) shows `bup_cpu.sv` with `THUMB` 0 equivalent to 806dcd4 with `MODES` 0 and 1. The Thumb suites pass on the step 5 core: directed 12 of 12 (plain, waits and throttle, `LATE_RF`), halts 210 of 210, decode 0 of 65,536 halfwords differ, random 400 of 400 seeds, fuzz seeds 1–48 in all three variants. `run_modes.sh THUMB=1` passes, and so does `s1/check.sh` with `THUMB` 1; songs 9, 13, 14 and 30 are PCM-identical to MiSTer's.
- **The call port** (`sim/bupchip/daria/call/`): the core alone in the 2600 profile, 26 tests in three variants (plain, asset waits and throttle, `LATE_RF`), 78 of 78 runs, and 20 of 20 planted faults caught.
- **MMIO** (`sim/bupchip/daria/mmio/`): seven clock variants (NTSC and PAL, aligned and asynchronous, 28.5–44.6 MHz) and three controls pass; 22 of 22 mutations caught. The counter matches the model on every `clk_sys` edge. The Draconian-like reading lands 10.6–30.5 counts below the ideal (bound 55), leaving a margin of 3,826–3,841 counts to the game's limit.
- **Capture** (`sim/bupchip/daria/capture/`): 81 of 81 checks in each of six clock variants (28.64–39.7 MHz, `CLOCK_SPEED` 28.636364 and 50.0), random mixes of images up to 594 KB, A78s and firmware, and 18 of 18 mutations. For an A78 and the firmware the message stream and every receiver output are bit-identical to before (lockstep, 0 differences over about 10 M clocks in each of three clock variants). `stress/run_slotswitch.sh` passes 31 of 31. `s4/check.sh` with the game, on the step 5 tree (the new capture, the cache at `WAYS` 1, the stress benches with their header), passes 28 of 28, every song PCM-identical.
- **Cache** (`s4/run_cache.sh`, `s4/stress/run_cstress.sh`): `WAYS` 1 is the step 4 cache clock for clock (0 differences beside a copy of it). Both settings pass 24 of 24 cache runs and 26 of 26 stress runs, with 22.2 M stress loads and 0 wrong. Mutations caught: 11 of 11 and 10 of 10 (`WAYS` 1), 24 of 24 and 20 of 20 (`WAYS` 2). With `WAYS` 2 in the wrapper, every song in `s4/check.sh` stays PCM-identical. Song 13 then has 1,269 demand misses and 11,381 stall clocks, against 8,297 and 70,127 with one way.
- **DARIA beside upstream** (`tb_daria` with `daria_shadow.svh`; `run_all.sh` with `SHADOW=1` over the 15 demos and the six added images). 1,500 frames each, with the 128 KB window. Every call is posted the way the front ends will post it (state RAM port B, `call_tog`), and compared once both have returned: FIQ r8–r13, every RAM write (address, lanes, data), and every MMIO access, T1TC reads within 200 counts (open item 17). Late calls are counted against each call's safe budget (`dynamic_tables.py --only daria`), with DARIA's measured time and with the model's `s1_cyc`.

  | Image | Calls | Differ | RAM writes compared | MMIO compared | Late (DARIA / model) | Highest share of a budget (DARIA / model) | Collisions (upstream / DARIA) |
  |---|---|---|---|---|---|---|---|
  | Elevator Agent | 2,999 | 0 | 6,893,261 | 0 | 0 / 0 | 85% / 85% | 0 / 0 |
  | Galagon | 2,999 | 0 | 3,969,599 | 0 | 0 / 0 | 53% / 52% | 21 / 21 |
  | Gorf | 2,999 | 0 | 3,681,218 | 0 | 0 / 0 | 58% / 57% | 0 / 0 |
  | Lady Bug | 2,999 | 0 | 4,801,428 | 0 | 0 / 0 | 75% / 75% | 9 / 4 |
  | Mappy | 2,999 | 0 | 2,577,215 | 0 | 0 / 0 | 31% / 31% | 56 / 63 |
  | Qyx | 2,999 | 0 | 2,040,732 | 0 | 0 / 0 | 92% / 92% | 0 / 0 |
  | Robot War 2684 | 2,999 | 0 | 2,217,434 | 0 | 0 / 0 | 45% / 45% | 7 / 17 |
  | Scramble | 2,086 | 0 | 3,065,860 | 4,172 | 0 / 0 | 60% / 60% | 0 / 0 |
  | Spiders | 2,999 | 0 | 2,911,793 | 0 | **16 / 16** | 104% / 104% | 0 / 0 |
  | Super Cobra | 2,999 | 0 | 2,291,314 | 0 | 0 / 0 | 48% / 48% | 3 / 6 |
  | Turbo | 2,999 | 0 | 3,792,485 | 0 | 0 / 0 | 52% / 52% | 0 / 0 |
  | Tutankham | 2,999 | 0 | 3,961,169 | 0 | 0 / 0 | 52% / 52% | 0 / 0 |
  | Wizard of Wor | 3,003 | 0 | 2,388,948 | 0 | 0 / 0 | 31% / 31% | 4 / 1 |
  | Zaxxon | 2,999 | 0 | 4,778,952 | 0 | 0 / 0 | 86% / 86% | 0 / 0 |
  | Zoo Keeper | 2,999 | 0 | 4,955,099 | 0 | 0 / 0 | 60% / 59% | 8 / 7 |
  | Draconian (Harmony fix) | 3,000 | 0 | 4,850,003 | 4 | 0 / 0 | 46% / 46% | 17 / 12 |
  | Draconian RC8 | 3,000 | 0 | 4,850,003 | 4 | 0 / 0 | 46% / 46% | 17 / 12 |
  | Robot War 2684 (Harmony fix) | 2,999 | 0 | 1,834,595 | 0 | 0 / 0 | 45% / 44% | 14 / 9 |
  | Space Rocks (Harmony fix) | 2,998 | 0 | 3,172,104 | 5,996 | 0 / 0 | 44% / 44% | 11 / 11 |
  | Stay Frosty 2, NTSC | 2,577 | 0 | 2,518,303 | 5,154 | 0 / 0 | 56% / 56% | 0 / 0 |
  | Stay Frosty 2, PAL | 2,577 | 0 | 2,518,303 | 5,154 | 0 / 0 | 56% / 56% | 0 / 0 |
  | **21 images** | **61,227** | **0** | **74,069,818** | **20,484** | **16 / 16** | | **167 / 163** |

  - **Every call matches.** No register at return, RAM write or MMIO access differs, no call halts, and none is skipped.
  - **Late only where upstream is.** Spiders' 16 calls at the start of play are late, on DARIA and in the model alike: the same calls upstream misses on its own core. Every other image's highest share of a budget is the model's, or 1 point above it.
  - **DARIA's clocks per call are the model's `s1_cyc`**: a median ratio of 1.00 on 19 images and 1.01 on Super Cobra and Wizard of Wor, and at most 1.16 in one call (Draconian). The model's lateness table ("Step 3 work") stands.
  - A DARIA call takes about as long as upstream's: Mappy's first, 283 µs at 38.18 MHz against 293 µs at 71.6 MHz.
  - **Identical pairs.** The two Draconian builds give identical counts, and so do Stay Frosty 2's NTSC and PAL builds, as their traces predicted ("The added images").
  - **The 64 KB window (decision 8).** These runs use the 128 KB window. Turbo is the only image larger than 64 KB; every other image is 32 or 64 KB, so it lies whole in either window and runs alike. Turbo at 64 KB runs through the whole wrapper (below): all 2,999 calls match.
  - **Timer reads (open item 17)**, from 64 KB runs of 300 frames (520 for Scramble, whose calls start at frame 427). The final report gives the range of DARIA's reading less upstream's. Only Draconian reads T1TC: once, at power-on, in both builds. DARIA reads 37 counts above upstream. The bound is 200; the game's own margin is 3,872 counts. Scramble (MAMCR), Space Rocks and Stay Frosty 2 access MMIO, but none of them reads T1TC, so their accesses match exactly.
- **The BupChip through the DARIA wrapper.** Song 13 is PCM-identical in both streams:

  | Clock | `CLOCK_SPEED` | Busy | Cache misses | Stall clocks | PSRAM model violations |
  |---|---|---|---|---|---|
  | 28.64 MHz | 28.636364 | 72.8% | 1,269 | 11,381 | 0 |
  | 38.18 MHz | 50.0 | 54.6% | 1,275 | 13,091 | 0 |

  `s4/check.sh` on the DARIA wrapper at 38.18 MHz (`DARIA=1 ARM38=1 PSRAM_CS=50.0`) passes 28 of 28: the PSRAM layer, the cache and stress benches, the synthetic ARSC jobs, the game's songs PCM-identical (also across reloads, a PAL retune, a 20 ms pause and loader jitter), and the held-and-silent cases (no firmware, a 4-byte firmware, not a Souper cartridge, no ARSC block). The retune job's hold delay now follows the clock (3 at 38.18 MHz, 2 at 28.64). `check.sh`'s tally is fixed too: each job writes its own exit code, so a run of several hours no longer loses a finished job's status to `wait`. Before the fix, 3 of 28 jobs had read FAIL with PASS in their logs.
- **Open item 8** (CoreTone after a 2600 game). All 32 KB of cart RAM were filled with random words before the downloads (`tb_s4 +ramjunk`). Song 13 is still PCM-identical, and its counts equal the clean run's clock for clock (83,432,084 busy clocks). CoreTone does not depend on what the RAM holds at boot.
- **Through the whole wrapper in the 2600 profile** (`tb_daria`, `WRAPPER=1`): Mappy's 79 calls (40 frames) match upstream. The cartridge comes through the capture, `psram.sv` runs at `CLOCK_SPEED` 50.0, and the PSRAM model reports 0 violations.
- **Small windows through the whole wrapper** (`tb_daria`, `WRAPPER=1`, 1,500 frames, open items 6 and 10). The image beyond the window comes through the cache from `psram.sv` (`CLOCK_SPEED` 50.0 at 38.18 MHz) on the PSRAM model. Every call matches upstream, none is late, and the highest share of a budget is the model's, or 1 point above it:

  | Image | Window | Calls (differ) | Demand misses | Prefetches | Clocks W waited, whole run | Highest share (model) | PSRAM model violations |
  |---|---|---|---|---|---|---|---|
  | Elevator Agent | 48 KB | 2,999 (0) | 38 | 31 | 941 | 85% (85%) | 0 |
  | Turbo | 48 KB | 2,999 (0) | 614 | 1,851 | 7,030 | 53% (52%) | 0 |
  | Zaxxon | 32 KB | 2,999 (0) | 67 | 214 | 1,248 | 86% (86%) | 0 |
  | **Turbo** | **64 KB (decision 8)** | 2,999 (0) | 150 | 924 | 2,220 | 52% (52%) | 0 |

  Against its 128 KB run, Elevator Agent's calls take 941 clocks more in all, at most 726 in one call (a cold fill). The 4 KB two-way cache with 16 B lines is enough (open item 6). These runs led to decision 8. `psram.sv` at `CLOCK_SPEED` 50.0 meets the model's timing at 38.18 MHz (open item 10, in simulation; step 8 checks hardware).
- **Cart RAM collisions** (open item 7, counted by the shadow): a console-side read within one `clk_sys` of a CPU write to the same word. Over the 21 images, 167 for upstream's ARM and 163 for DARIA in 402 M console-side reads, about one in 2.4 M. Ten images have none. The most is Mappy's 56 and 63, in 18.7 M reads.
  - **The rate is the games', not DARIA's:** both CPUs give it, image by image, against the same reads.
  - **The count is an upper bound:** it takes any read within 69.84 ns of a write. `clk_arm` and `clk_sys` come from one VCO (÷18 and ÷48), so their rising edges either coincide, once every 3 `clk_sys`, or lie at least 8.73 ns (6 VCO periods) apart. A read on a shared edge with a write to its word races in the dual-clock M10K. One 8.73 ns or more away most likely does not, but the timing analysis does not check it. The bench offsets the two clocks by 4.37 ns, so it never puts them on a shared edge.
  - **Upstream sits out the shared edge:** its ARM's cart RAM port takes no access on the one `clk_arm` edge in five that is also a `clk_sys` edge (`cart_ram_tdp.sv:29-39`). DARIA has no such guard. Step 6, which builds the console-side reader, decides between that guard (a W wait on cart RAM stores, one `clk_arm` edge in 8) and accepting a race that touches one byte-lane read in millions (open item 7).

### Changes against the design

- **Capture (2.2, 7.1):**
  - The END payload's bit 24 marks an image (1 when the file is not an A78), not an A78. With that polarity an A78's and the firmware's streams are bit-identical to before. The size field is 24 bits.
  - WRITE gains bit 40 (image: also write the window); `msg_pl` stays 44 bits, not 48.
  - Bytes 0–5 are held until byte 5 decides the mode. An image sends them afterwards as three WRITEs, in slots the stream leaves free.
  - A cartridge byte in `load_start`'s clock is now taken as byte 0.
  - About 76 more FF, as budgeted, but about 90–120 ALMs, above the 40–70 estimated.
  - The s4 stress benches' generated A78 files now carry "ATARI" at bytes 1–5; without it they are images.
- **Cache (3.2, 1.1, 1.5, 8):**
  - Tags are offset[22:11] (12 bits) per way, so one instance serves the BupChip's 8 MiB of assets too.
  - The tags take 2 M10K, not 1: one 27-bit word for both ways exceeds the 20-bit true-dual-port width. The cache is 6 M10K; the device total is 259 of 308.
  - The FIFO bit is p0 XOR p1, one bit in each way's tag word, flipped when a fill completes.
- **MMIO (6):**
  - A TC read is at most 5 `clk_sys` old (about 24 counts), not 8.
  - One TC write is in flight at a time. Later ones are kept in the mirror and sent together when it lands. A write lands about 3 `clk_sys` (about 15 counts) later than on upstream.
  - 221 FF.
  - The two resets come from one level, which must last at least 4 `clk_sys`; the held buses are deliberately not reset.
  - Step 7 marks `en_s[0]`, `w_s[0]` and `sn_a[0]` as synchronisers.

### The 64 KB window (decision 8)

- **`daria_mem`** builds the window as `WIN_KB` / 32 RAMs of 8K × 32: two, with a 2:1 mux on registered bit 13. Any size up to 128 KB builds for tests.
- **Synthesis:** block memory falls from 1,781,312 to 1,257,024 bits (64 M10K fewer), and the logic by 26 ALMs.
- **The call suite** (`WIN_KB=64`) passes 81 of 81 runs, with a new test that a fetch at the window's end halts.
- **Through the wrapper at 64 KB:** Mappy matches on all its calls, and so does Turbo, the one image larger than 64 KB, over 1,500 frames (above).
- **The rest of the images** are 32 or 64 KB and lie whole in the window, so the 128 KB shadow runs stand for them.

### Step 5's done-when

- **"Every demo and added image ... call by call":** all 21 match on every call (registers at return, every RAM write, every MMIO access, the audio values in FIQ r8–r13).
- **"No lateness beyond the model's":** DARIA is late on Spiders' 16 calls, as the model is and as upstream is.
- **"Again with a small window":** Elevator Agent at 48 KB, Zaxxon at 32 KB, and Turbo at 48 and 64 KB. The cache serves each through `psram.sv` with every call matching and none late.
- **Open items:**
  - 6, 8 and 18 are settled, and 10 is settled in simulation.
  - 17 is settled: the one timer read is 37 counts from upstream's.
  - 7 is counted. Step 6 decides whether the shared edge needs a guard.

## Step 6 work: the front ends (in progress)

Started on 2026-10-07. `docs/daria_fe/` holds the work; its README indexes it.

- **Specs.** Upstream's DPC+ and CDF front ends, the audio engine, the RAM init and call-controller glue, and the 6507 bus and stall timing are specified clock by clock, from the RTL, each checked line by line by a second reader (`docs/daria_fe/spec/`). A cross-check (`spec/critic.md`) settled the decisions the design starts from: commit on `access` in whatever clock it comes, background work on a free-running sequencer, seeds by logical order, a one-deep pending call for a read-modify-write CALLFN, F6 started at the capture's close, and the shared-edge guard in the front end.
- **The shared-edge guard (open item 7).** In the front end, at no cost to the CPU, so step 5's comparison and timing stand. While DARIA's CPU may touch cart RAM, the front end writes none, and every read it uses registers on the `clk_sys` edge 17.46 ns after the last `clk_arm` edge and 8.73 ns before the next. A phase detector finds that edge from the clocks: one `clk_arm` toggle sampled by one `clk_sys` flop, on a path with its own 6 ns / 1 ns SDC pair. It cannot lock where no edge is shared (the bench's 5 × `clk_sys` upstream clock, a ÷19 fallback), and is inert there.
- **Design.** Three independent micro-architectures (smallest; most exact; easiest to verify) were reviewed for exactness, hardware and risk. `docs/daria_fe/design.md` builds on the easiest to verify, with the exact design's mechanisms and the smallest one's guard and audio as a fallback. As designed, every compared point of the shadow is exact, AMPLITUDE and NOTE included, at about 1,255–1,445 ALMs (mid 1,350): 82.7–85.1% of the device, on the 84% gate. The lean audio (`daria_fe_audio_lean`, same ports) saves about 250 ALMs and brings back a counted one-tick AMPLITUDE lag. **Open for the owner: which audio.**
- **Stage 0 of the shadow** (`sim/bupchip/daria/fe_shadow.svh`, `run_daria.sh FE=1`). A second copy of upstream's front ends, driven only from the bench's taps, matches upstream at every latch, register, RAM byte and mapper output: 0 differences over 300 frames on SF2fix (DPC+), Galagon (CDFJ) and draconian RC8 (CDF1). Planted faults (a flipped data bit, a late commit, a wrong bank, a counter off by one, a stuck flag) are each caught by the check that should see them. The image set makes no bank switch, no DPC+ copy or fill and no RSYNC that moves the phases, so directed tests must cover those.
- **Also done:** the state RAM's front-end port has byte enables (`stb_be`, R1); `daria_call.sv` takes its power-up values from internal registers, so `run_sim.sh`'s initialiser guard passes again.

## Comparisons: upstream and lroby74's fork (2026-10-07)

Upstream MiSTer's ARM is the reference DARIA follows. The owner asked how a second implementation handles the same cartridges: lroby74's fork of the MiSTer core (github.com/lroby74/Atari7800_ARM_MiSTer, CC BY-NC 4.0). Its ARM and Thumb sources are not read (the clean-room rule), so it is measured as a black box only: its own Quartus build and its reports, and simulation of the whole core at the console's outputs. Everything built from it stays in `sim/work`.

| | Upstream MiSTer | lroby74's fork (MiSTer) | DARIA (Pocket) |
|---|---|---|---|
| CPU | ARM7TDMI (GPL core) | its own Thumb CPU, one for 2600 and one for 7800 cartridges | ARIA (the BupChip's CPU) with ARM and Thumb, one instance for both uses |
| CPU clock | 71.59 MHz (5 × `clk_sys`) | 57.27 MHz (4 × `clk_sys`, the video clock); Fmax 59.2 MHz at slow 100 °C | 38.18 MHz (VCO ÷ 18); Fmax 38.6–40.2 MHz on three seeds, slow 85 °C |
| Device | 5CSEBA6, speed grade 7 | 5CSEBA6, speed grade 7 | 5CEBA4, speed grade 8 |
| CPU size | 13,424 ALUTs, 2,846 registers, 5 DSP [syn] | about 3,600 ALMs, 2,348 registers, 2 DSP, plus an instruction cache in 16 MLABs [fit] | 1,876 ALMs, 628 registers [fit, step 3] |
| Whole ARM cost | 13,760 ALMs, 7,855 registers, 5 DSP, 72 Kbit of block RAM over the build without it [syn] | about 9,700 ALMs and 281 M10K for both paths; the 2600 path about 6,200 ALMs and 168 M10K [fit] | the wrapper's DARIA additions about 950 ALMs and 135 M10K with the 64 KB window [syn]; front ends 850–1,100 ALMs [E] |
| Image | DDR3 shadow, 2 KB I- and D-caches | first 128 KB in block RAM (128 M10K) | first 64 KB in block RAM (64 M10K, decision 8), the rest through a 4 KB cache over PSRAM |

- **Sources.** Upstream: `quartus_probe/upstream_arm_map.sh`, Analysis & Synthesis of its core with and without `NO_ARM_MAPPER` on 5CSEBA6 (estimates, no fit). The fork: a full compile of its own project in Quartus 21.1 (its project targets 17.0.2), from the fitter's per-entity table and timing reports. That compile also fills 74% of the 5CSEBA6's ALMs and 93% of its M10K, and meets timing on every core clock. Its PLL has a 64.43 MHz output that nothing uses.
- **Upstream's ARM** is larger than the whole Pocket core's logic budget allows. That is why the Pocket build leaves it out (`NO_ARM_MAPPER`) and DARIA exists.
- **The fork's ARM blocks** alone would take over half the Pocket's 18,480 ALMs and 91% of its 308 M10K. That suits MiSTer's larger device, not the Pocket.
- **Behaviour** (whole cores, frame fingerprints: `tb_daria +fp=1`, `fp_compare.py`; 600 frames each, through FIRE at 420 and the joystick script from 480):

  | Image (scheme) | Frame length | RIOT RAM | Picture | Audio |
  |---|---|---|---|---|
  | Mappy (CDFJ) | same | same | differs every frame | 145 frames differ, from 7 |
  | Stay Frosty 2 (DPC+) | same | same | differs every frame | 391 differ, from 4 |
  | Draconian (CDF) | same | 2 frames differ, from 426; the same after | differs every frame | 1 differs, frame 1 |
  | Galagon (CDFJ) | same | same | differs every frame | 53 differ, from 85 |
  | Turbo (CDFJ+) | same | same | differs every frame | 73 differ, from 421 |

  - The game's state and timing match upstream's, so the ARM's work comes out the same.
  - Draconian's two frames come right after FIRE and then agree again. They point at the fork's other changes (its TIA and controller handling), not at the ARM; telling which would need more diagnostics.
  - The picture differs by one extra black line per frame on upstream's side, shown on Mappy: every line both draw is identical.
- **Audio differs in two ways:**
  - Upstream holds the 6507 during each call (about 5,500 `clk_sys` at the median), so AUDV0 stops changing there; the fork's 6507 keeps writing it.
  - In the main kernel, the values written differ: upstream's are 0, 3, 6, 9 or 12 where the fork's take every value 0–12.

  Which is right is for step 6, the front ends, to check against Stella. DARIA follows upstream.

## Design (step 1)

Four sections follow: the CPU's Thumb support, the memory system with the call port and the clock crossings, the front end, and Fix B. Line references to `bup_cpu.sv` in this part are to its version before step 2 (806dcd4); "Step 2 work" points into the current one. Each was drafted with experiments of its own: Yosys on models of the decode, black-box runs of the reference core, elaborations of `psram.sv`, and 57 whole-core simulations of Fix B. Those experiments are kept in `sim/work/` until their step moves them into `sim/bupchip/daria/`; none uses game data.

| Block | Where | Clock | Section |
|---|---|---|---|
| CPU: `bup_cpu.sv` with `THUMB` 1 and `MODES` 1, one instance for both profiles | `bupchip_pocket.sv` | `clk_arm` | Thumb; memory system 4–5 |
| Firmware ROM 16 KB, image window 128 KB, cart RAM 32 KB | beside the CPU | `clk_arm`; cart RAM port B on `clk_sys` | memory system 1 |
| Front-end ROM 32 KB, state RAM | beside the front end | `clk_sys`; state RAM port A on `clk_arm` | memory system 1; front end |
| Asset cache over the PSRAM: the image beyond 128 KB, digital samples | ARIA's, widened to 2 ways | `clk_arm` | memory system 3 |
| `daria_fe`: DPC+ and the CDF family | the Pocket wrapper; `cart2600` and `top.sv` through `POCKET_DARIA` blocks | `clk_sys` | front end |
| Call port | a sequencer in `bup_cpu`; the hand-off through the state RAM | both | memory system 5 |
| MAMCR, timer 1 | `daria_mmio.sv` | both | memory system 6 |
| Fix B | `sram_ctrl.sv`, `top.sv` | `clk_sys`, `clk_sdram` | Fix B |

**Choices step 1 made**, beyond the decisions above (each is argued in its section):

1. **Thumb is decoded beside ARM**, into the same controls, not translated into ARM first. The register-index path that starts the critical path keeps today's depth [syn]; translating first would cost about 4–7 ns and miss 32.73 MHz [E].
2. **The C flag after a Thumb MUL is unknown.** An instruction that reads it before anything rewrites it halts with a new code 8. The reference computes that C from the ARM7TDMI multiplier's internals [sim]; no executed path in the demos or the added images reads it [trace].
3. **The front ends get their own 32 KB copy of the image's start** (32 M10K). A block-RAM port has one clock, and the CPU (`clk_arm`) needs both ports of the window.
4. **Bytes beyond the window (64 KB since decision 8; 128 KB as designed) come from the PSRAM** through ARIA's asset cache, not from the SDRAM. The SDRAM controller and its `clk_sdram` paths stay untouched, the CPU's misses cross no clock, and a miss takes 13 `clk_arm` instead of 24–30.
5. **Code must lie in the window:** a fetch beyond it (64 KB since decision 8) halts (code 4). Code ends below 0xB30A in every demo (below 0x5700 in the added images), and the CDFJ+ template starts it at `C_START` ≤ $7800.
6. **`clk_arm` stays a related clock** in the SDC, with bounded delays on the held buses that cross.
7. **Fix B's register sits inside `sram_ctrl`.**

### The CPU: Thumb

This section designs DARIA's Thumb-1 support (C1, C4) on ARIA's S1 core, `src/fpga/core/bupchip/bup_cpu.sv`, for step 2. It covers fetch, where the expander sits and what it does to the clock, the expansion format by format, what halts, the changes to ARIA's blocks, area, and verification.

Tags are this document's, plus [syn]: Yosys 0.69 (`sim/work/bupchip/venv/bin/yowasp-yosys`), `abc -lut 6` and `synth_intel_alm`, on small models of the decode, as in `BUPCHIP_CORE.md`.

**How the reference was observed.** The [sim] facts below come from game-free programs: an ARM start-up, then Thumb bodies built with `arm-none-eabi-gcc` (or `.hword` for encodings GAS refuses). They ran on the reference BupChip (`ref_system.svh`) through a copy of `tb_ref_trace.sv` that also prints `trace_retire_thumb` and `cpsr`. Those are signals the harness already reads (`tb_daria.sv:206-208`, `ref_system.svh:119-125`). Nothing was read from `arm7tdmi_core.sv`. The programs, the trace testbench, the Yosys models and the trace-statistics scripts are in `sim/work/daria_thumb/`. Step 2 moves the programs and models into `sim/bupchip/daria/thumb/`; they hold no game data.

#### Summary

1. **Thumb is decoded beside ARM, not translated into ARM.** A Thumb decoder produces the same control signals as ARIA's ARM decode, and a mux on T merges the two at the last level. The register indices are decoded from both halfwords of `rom_q` at once, and the registered PC bit 1 picks one at the end. ARIA's bank remap moves in front of the select.
   - With this structure the register-index path, where ARIA's critical path starts, has the same depth as today's ARIA: 4 LUT6 levels, or 5 in the ALM mapping [syn].
   - Translating each halfword into an ARM encoding for ARIA's decode instead costs 3–4 more levels [syn], about +4–7 ns [E].
   - Taken branches stay free.
2. **The PC becomes a halfword address** (17 bits, byte bits 17:1). `rom_addr` is its word part. PC bit 1, registered with `rom_addr`, picks the halfword, so two sequential Thumb instructions read the same word twice and nothing is buffered.
3. **BL runs as two instructions**, as ARMv4T defines it and as the reference retires it [sim]. The prefix is an ADD to LR. The suffix branches to LR + offset and links (address + 2) | 1. Each takes one clock, and lone halves work.
4. **The C flag after MUL.** The reference sets C from both operands, ignores the old C and keeps V [sim]. Its MUL time follows the ARM7TDMI's early termination (4 + m clocks between retires), so it models the real multiplier [sim]. DARIA does not reproduce that carry. It marks C unknown after a Thumb MUL and halts (new code 8) on any instruction that reads C before something rewrites it. No executed path in the 15 demos or the added images reads C after a MUL [trace]. The lockstep testbench compares C only when it is known.
5. **What halts.** SWI, Bcc with cond 1110, the v5/v6 encoding spaces, BX with H1 or nonzero should-be-zero bits, the H1 = H2 = 0 hi-register forms, and empty register lists halt with UNDEF (1). Bad targets halt with FETCH (4). BX to an odd address no longer halts, except in the BupChip profile.
6. **Area:** about 300–500 ALMs [E; 289 ALUTs of decode measured, syn]. No M10K.

#### What the reference does [sim]

| Behaviour | Observed |
|---|---|
| Retire of a Thumb instruction | One retire. `trace_retire_pc` is the halfword's byte address, `trace_retire_instruction` is `{16'h0000, hw}`, and `trace_retire_thumb` is 1. |
| BL | Two retires. The prefix sets LR = address + 4 + (sext(imm11) << 12): 0x58 for offset 0, and 0xFFFF_F09C for a backward BL at 0x98, a full 32-bit value. The suffix sets PC = LR + (imm11 << 1) and LR = (address + 2) \| 1. |
| Lone BL suffix | Runs, with whatever LR holds. Bit 0 of the target is dropped: LR 0x85 with offset 1 goes to 0x86. |
| BX to ARM or Thumb | T changes in the BX's own retire (`cpsr` sampled there). |
| BX PC | At a word-aligned address: ARM at address + 4. At an address that is 2 mod 4: the reference fetches the word at address + 2 (bit 1 dropped). |
| BX with H1 = 1 (`0x4788`), or with bits 2:0 ≠ 0 (`0x4721`) | Both act as a plain BX of Rm. No link is written. |
| PC as an operand | F6 and F12 read (address + 4) & ~3 at either alignment. `mov rd, pc`, `add rd, pc` and `cmp` read address + 4, unaligned. |
| MOV pc, Rm / ADD pc, Rm | PC = value & ~1, and the core stays in Thumb (0xB1 → 0xB0, 0xB4 → 0xB4, 0xB6 + 4 + 9 → 0xC2). |
| POP {pc} | PC = value & ~1, and the core stays in Thumb whatever bit 0 holds (ARMv4T). |
| LDMIA Rb! with Rb in the list | The loaded value wins, whether Rb is first, middle or last. |
| STMIA Rb! with Rb in the list | Rb lowest: the old base is stored. Otherwise: the new, written-back base. |
| Empty lists | LDMIA loads PC from [Rb] and adds 0x40 to Rb. STMIA and PUSH store address + 6 and move the base by 0x40. POP goes to whatever the stack held. |
| ADD/CMP/MOV with H1 = H2 = 0 | The natural result: r1 = r1 + r2 or r1 = r2 without flags; CMP sets flags. |
| `0xDExx`, `0xB1xx`, `0xBExx`, `0xE800` | Undefined-instruction exception: UND mode, LR = address + 2, `trace_retire_exception` = 1. |
| `0xDFxx` | SWI exception. |
| Odd LDRH, odd LDRSH, LDRSB, unaligned LDR, odd STRH, unaligned STR | The same as ARIA's ARM lane rules (`bup_cpu.sv:563-606`): rotate, sign-extend the byte, store aligned. |
| MULS, 1,184 cases (corner and random operands, 121 with Rd = Rm, random C and V before) | The product, N and Z are exact in all cases, and V is unchanged in all. C after is 1 in 203 cases and 0 in 981, with no relation to C before. One operand pair always gives the same C. For example, a multiplicand of 0 with a multiplier of 0x8000_0000 gives C = 1 with a product of 0. Clocks between retires are 5, 6, 7 or 8, exactly 4 + m, where m = 1–4 is the number of 8-bit steps until the multiplier's (Thumb Rd's) remaining bits are all 0s or all 1s. |
| Flag corners | NEG 0 gives C = 1. NEG 0x8000_0000 gives N and V. ROR by 32 gives C = bit 31. A register shift by 0 keeps C. LSR/ASR #0 in F1 means #32. `adds rd, rs, #0` gives C = V = 0. MOVS #imm8 keeps C and V. |

#### Fetch

**PC.** ARIA keeps a 12-bit word address (`bup_cpu.sv:223`) and fetches the word at `rom_addr = npc` (`:842`). DARIA keeps `pc[17:1]`, the halfword address of the instruction in execute. Byte bit 0 is never stored, and in ARM state bit 1 is always 0.

| Signal | ARM state (T = 0) | Thumb state (T = 1) |
|---|---|---|
| `rom_addr` | `npc[17:2]` | `npc[17:2]` |
| Instruction | `rom_q` | `pc[1] ? rom_q[31:16] : rom_q[15:0]` |
| Next sequential `npc` | `pc + 2` (halfwords) | `pc + 1` |
| r15 on a read port | address + 8 | address + 4; (address + 4) & ~3 for F6 and F12 |
| Link | BL: address + 4 | BL suffix: (address + 2) \| 1 |
| Branch target | `pc + 4 + (sext(imm24) << 1)` | F16: `pc + 2 + sext(imm8)`; F18: `pc + 2 + sext(imm11)` |

- **Two Thumb instructions per word, with no buffer.** The M10K re-reads its address every clock anyway. After the first halfword, `npc` = `pc` + 1 lands on the same word, and the ROM returns it again with the other half selected.
- **The fetch register scheme is unchanged.** `npc` is computed during execute and goes straight into the ROM's address register. `pc[1]` is registered in the same clock, so the first instruction after a taken branch to an odd halfword is selected correctly, with no extra clock. A multi-clock instruction holds `pc`, and the same word and half come back.
- **Branch targets** use ARIA's branch adder (`:611`), with a three-way offset mux in front: imm24 << 1, sext(imm8), sext(imm11), all in halfwords.
  - The BL suffix, MOV pc and POP {pc} take other `npc` inputs: the ALU sum, `rb`, and the load data. These are the paths ARIA already uses for BX (`:700-704`) and `LDR pc` (`:739-742`).
  - ADD pc, Rm takes 2 clocks: its sum is registered (`wb_value`, `:904`), then loaded into `npc`. It never runs in the demos [trace].
- **The T bit** is CPSR bit 5 in `ctl` (`:229`, MODES 1).
  - BX sets T from bit 0 of Rm. Nothing else changes it in Thumb.
  - MSR still cannot set T: `ctl_ok` (`:464-467`) halts with UNDEF.
  - MRS runs only in ARM state, so it always reads T = 0.
  - The launch (P1) writes T and `pc` together.
- **Range checks** move to 32-bit targets, one clock later as today (`late_go`, `:694, 703, 742, 820-823`).
  - A target outside the code space halts with FETCH.
  - The return sentinel 0xF000_0000 instead ends the call, reached in either state (`bx lr` goes there in ARM state, `pop {pc}` in Thumb).
  - Running sequentially past the end of the code space halts, as at 0x3FFC today.
- **Fetch beyond the window** (images over 128 KB) needs a fetch-wait input that holds the start of an instruction while `rom_addr` stays put, like `freeze` (`:662`). The Thumb front end needs nothing more: it only ever sees a 32-bit word and the registered `pc[1]`.

#### Where the expander sits

ARIA's critical path in the full build is 26.8 ns: ROM `q` → decode → register-file read select → MLAB read → bypass → shifter → operand mux → adder → region decode → one-clock-store decision → `rom_addr` or `ram_we`. Its head is the register index. Every Thumb format puts its registers in different bits, so the index is where an expander costs time.

**Measured index depth [syn].** `sim/work/daria_thumb/depth/idx.sv` models only that head: `rom_q` and the registered state in, the two physical read indices of `MODES` 1 out. The ARM part is ARIA's `:240-264, 365-376, 412-426`.

| Variant | LUT6 levels | ALM-map levels | ALUTs |
|---|---|---|---|
| ARIA today (select, then bank remap) | 4 | 5 | 30 |
| ARIA with the remap applied to each candidate before the select | 3 | 4 | 39 |
| Serial: halfword → 32-bit ARM encoding → ARIA's decode | 7 | 9 | 165 |
| Parallel Thumb decode of a pre-muxed halfword, T mux after the remap | 5 | 7 | 96 |
| Parallel decode of both halfwords, late select, T mux after the remap | 5 | 6 | 134 |
| Parallel decode of a pre-muxed halfword, remap first on both sides | 4 | 6 | 108 |
| **Parallel decode of both halfwords, remap first on both sides, one final mux on {T, `pc[1]`}** | **4** | **5** | **154** |

The last row needs two things. r0–r7 are never banked, so the Thumb candidates other than the hi registers, SP and LR need no remap. And ARM's Rn, Rs, Rd and Rm can each be remapped in parallel with the select. The remaining Thumb controls (operation, immediates, shift, size, lists, condition, halts; `depth/tctl.sv`) come from one pre-muxed halfword in 4 LUT6 levels and 165 ALUTs [syn], 5 levels after the T mux. They feed the operand mux, the ALU and the shifter's controls, which the register value reaches only after the index, the MLAB read and the bypass: about 6 levels [syn/E]. The shift type and amount have the least slack, about one level.

**Options.**

| | Taken branch | Index path | Area | M10K | Complexity |
|---|---|---|---|---|---|
| A. Serial expansion into ARIA's decode (`thumb_expand.py` in RTL) | free | +3–4 levels, +4–7 ns: 30.8–33.8 ns, misses 30.55 [E] | about 165 ALUTs on the index alone, plus the rest | 0 | lowest: ARIA's decode is reused unchanged |
| **B. Parallel decode, merged at the last level (recommended)** | free | +0 levels against today [syn]; +1 against the best ARM-only form | 300–500 ALMs in all [E] | 0 | moderate: ARIA's decode becomes a control record that both decoders fill |
| C. Registered predecode (an instruction register after the expander) | +1 clock. Taken branches are 14.4% of instructions (10.7–19.8% per demo) [trace]: CPI +0.11–0.20, +10–20% clock, more than the shorter path wins. An early target for B and BL hides only 5.6%; the 8.3% that are taken conditional branches remain. | indices from flip-flops | +100–150 FF and a flush | 0 | high: two-stage fetch, squash, retire order |
| D. Predecoded copy of the code (expander on the load path, 4 bits per halfword beside the window) | free | as ARM's, so no better than B | about 30 ALMs | +8 for 32 KB of code; +32 for the 128 KB window at 8K×1 slices (the ×40 parity bits are not free: they need deeper slices, so a deeper output mux) | correctness depends on the loader; code from the cache or RAM still needs B's decoder |

**Recommendation: B.** It is the only option that keeps both requirements: taken branches free, and no depth added to the path that limits the clock. C is the only one that shortens the path, and it pays more in CPI than it gains. D costs block RAM the budget can barely spare (258 of 308 already) and buys nothing over B on this path. A is the simplest, but it makes the baseline clock unreachable.

**Timing [E].** Each level costs about 1.2–1.9 ns here: the S1 probe's path was 27.263 ns of data delay over 14 levels, 62% of it interconnect (risk 2).

| | Critical path | 32.73 MHz (30.55 ns) | 40.43 MHz (24.73 ns) |
|---|---|---|---|
| ARIA in the full build ("Clock") | 26.8 ns | +3.7 ns | −2.1 ns |
| DARIA with B. The index path is unchanged; the other decode outputs gain one merge level but keep slack, so 0 to +1 level. | 26.8–28.3 ns | +2.2 to +3.7 ns | −2.1 to −3.6 ns |
| B, with the one-clock store decided from the base's region (risk 2: about two levels, −2.4 to −3.8 ns) | 23.0–25.9 ns | +4.6 to +7.5 ns | −1.2 to +1.7 ns |
| A (serial) | 30.8–33.8 ns | −0.3 to −3.3 ns | — |

So 32.73 MHz holds with B even without the store fix. 40.43 MHz needs at least the store fix, and it is still uncertain: DARIA adds other things to the head of the same path that this section does not count (the window's output mux, see "Open items"). B already includes the remap-first decode. That decode is functionally identical to today's, and on its own it would gain ARIA one level.

#### The expansion, format by format

"A / B" are the read ports in the first clock (ARIA's `ia` / `ib`; P1 and P2 in `BUPCHIP_CORE.md`). Clocks are S1's, with S3's in brackets where they differ (`BUPCHIP_CORE.md`, "Cycles per class"). No Thumb instruction costs more than the trace model charged for it (`tb_daria.sv:349-386`); the one exception, ADD pc, never runs. So the CPI estimates stand: S1 1.26–1.36, S3 1.01–1.07 [trace].

| Format | Encoding | ARIA operation | A / B | Clocks | Exact details |
|---|---|---|---|---|---|
| F1 | `000 op imm5 Rs Rd` (op ≠ 11) | MOVS Rd, Rs, LSL/LSR/ASR #imm5 | — / hw[5:3] | 1 | LSR/ASR #0 mean #32 (ARIA's normalisation, `:442-443`); LSL #0 keeps C; V is kept |
| F2 | `00011 I op Rn/imm3 Rs Rd` | ADDS/SUBS Rd, Rs, Rn or #imm3 | hw[5:3] / hw[8:6] | 1 | `#0` still sets C = V = 0 |
| F3 | `001 op Rd imm8` | MOVS, CMP, ADDS, SUBS Rd, #imm8 | hw[10:8] / — | 1 | MOVS keeps C and V (rotation 0, `:453`) |
| F4 | `010000 op Rs Rd` | AND EOR ADC SBC TST CMP CMN ORR BIC MVN with Rn = Rd and operand Rs; LSL LSR ASR ROR by Rs; NEG; MUL | hw[2:0] / hw[5:3] for all 16 ops | 1; shifts 2; MUL 2 (1) | Shifts latch the amount from port B (`rs_amt`, `:902`, gains a T mux) and shift Rd in the second clock (port B re-pointed to hw[2:0]); C as ARM register shifts (0 keeps C; 32 and over as `shift_register`). NEG is 0 − Rs with ALU input A forced to 0 (MLA's existing zero, `:492`): C = (Rs = 0), V = (Rs = 0x8000_0000). ADC and SBC take C in. MUL: see below. |
| F5 | `010001 op H1 H2 Rs Rd` | ADD (no flags), CMP (flags), MOV (no flags) on r0–r15 | {H1,hw[2:0]} / {H2,hw[5:3]} | 1; ADD pc 2 | r15 reads address + 4; Rd = PC: MOV loads `npc` from `rb` & ~1, ADD from the registered sum & ~1, T unchanged; CMP may use PC either side; H1 = H2 = 0 halts |
| F5 BX | `010001 11 0 H2 Rs 000` | BX Rm | — / {H2,hw[5:3]} | 1 | T = Rm[0]; to ARM with Rm[1] set halts FETCH; H1 = 1 or bits 2:0 ≠ 0 halt UNDEF |
| F6 | `01001 Rd imm8` | LDR Rd, [PC, #imm8 << 2] | PC aligned / — | 2 (1) | Reads the code window through ROM port B: 5.98% of all instructions [trace] |
| F7 | `0101 L B 0 Ro Rb Rd` | LDR, STR, LDRB, STRB [Rb, Ro] | hw[5:3] / hw[8:6]; store data in W from hw[2:0] | 2 (S3: 1) | The offset is not shifted |
| F8 | `0101 H S 1 Ro Rb Rd` | STRH, LDRH, LDRSB, LDRSH [Rb, Ro] (HS = 00, 10, 01, 11) | as F7 | 2 (1) | Odd addresses as ARIA's lanes |
| F9 | `011 B L imm5 Rb Rd` | LDR/STR #imm5 << 2, LDRB/STRB #imm5 | hw[5:3] / hw[2:0] (store data) | load 2 (1), store 1 (to RAM) | |
| F10 | `1000 L imm5 Rb Rd` | LDRH/STRH #imm5 << 1 | hw[5:3] / hw[2:0] | 2 (1) / 1 | |
| F11 | `1001 L Rd imm8` | LDR/STR Rd, [SP, #imm8 << 2] | 13 / hw[10:8] | 2 (1) / 1 | A two-clock (MMIO) store reads its data from hw[10:8] in W, not hw[2:0] |
| F12 | `1010 S Rd imm8` | ADD Rd, PC or SP, #imm8 << 2 (no flags) | aligned PC or 13 / — | 1 | |
| F13 | `1011 0000 S imm7` | ADD/SUB SP, #imm7 << 2 (no flags) | 13 / — | 1 | |
| F14 | `1011 L 10 R list` | PUSH = STMDB SP!, {list, LR if R}; POP = LDMIA SP!, {list, PC if R} | 13 / sequencer | n+1 / n+2 (S3: n, n+1 with PC) | POP {pc}: the last data goes to `npc` & ~1 with T unchanged, as `LDR pc` does in W; empty list halts |
| F15 | `1100 L Rb list` | STMIA/LDMIA Rb!, {list} | hw[10:8] / sequencer | n+1 / n+2 (n) | Base in the list: ARIA's order (base written in the first beat, `:803-807`) gives the reference's results; empty list halts |
| F16 | `1101 cond imm8` | B<cond> | — | 1 | cond 1110 halts; 1111 is F17 |
| F17 | `1101 1111 imm8` | SWI | — | — | halts |
| F18 | `11100 imm11` | B | — | 1 | |
| F19 prefix | `11110 imm11` | ADD LR, PC, #sext(imm11) << 12 (no flags) | 15 / — | 1 | PC reads address + 4; the 32-bit sum may wrap |
| F19 suffix | `11111 imm11` | `npc` = (LR + (imm11 << 1)) & ~1; LR = (address + 2) \| 1 | 14 / — | 1 | LR from last clock's write comes through the bypass; the target goes through the ALU sum (no shifter) to `npc` |
| — | `11101 …`, `1011` other than F13 and F14 | — | — | — | halt |

**Datapath controls the Thumb decoder supplies.** The ALU opcode in ARM numbering (`:174-177`), S, the operand-2 source and immediate, the shift type and amount (or LSL #0), size, sign, load/store, register offset or not, the LDM/STM mode and list, the condition (AL except F16), the write index, and four Thumb-only bits:
- `pcrel`: clear bit 1 of r15;
- `zero_a`: NEG;
- `reads_c`: ADC, SBC, Bcc CS/CC/HI/LS;
- `c_unk_set`: MUL.

The later clocks of multi-clock instructions (S_W, S_SHR2, S_MUL2, S_SEQ) read these from the merged record, because ARIA re-decodes `rom_q` in every clock (for example `rf_wa = f_rn` in S_SEQ, `:805`).

**MUL and the C flag.** Rd = (Rm × Rd)[31:0], computed as ARIA's MUL (`prod`, `:903`; written in S_MUL2 to hw[2:0]). N and Z come from the result, and V is kept [sim]. ARMv4 leaves C UNPREDICTABLE. The reference computes it from both operands, and so presumably does the silicon (the same 4 + m timing) [sim]. Matching it would mean a model of the ARM7TDMI multiplier's internal carry beside the DSP blocks, known only from black-box samples: hundreds of ALMs [E] and an unverifiable risk. DARIA takes another route:

- A Thumb MUL leaves C's bit as it was and sets a flip-flop, `c_unk`.
- Any instruction that defines C clears `c_unk`:
  - an arithmetic S operation;
  - a shift whose amount is not 0 (immediate after normalisation, or `rs_amt` in S_SHR2);
  - an ARM rotated immediate with a rotation other than 0;
  - MSR with the f field;
  - the launch.
- Logical operations with a shift of 0 pass C through, and `c_unk` with it.
- An instruction that reads C while `c_unk` is set halts with code 8 (FLAGS) at its own address:
  - Thumb: Bcc with CS, CC, HI or LS; ADC; SBC;
  - ARM state: a CS, CC, HI or LS condition; ADC, SBC, RSC; RRX; MRS, whose result would expose C.

A program can see C only through those readers, so nothing is silently different. The demos never trip it: they execute 4.33 M MULs at 693 sites [trace]. From 692 of the sites, every executed path writes C before any read. One site, run once in Turbo, returns from its function first, and the static walk stops at the return. No path reaches a read (`sim/work/daria_thumb/mulc_scan.py`). The added images' MUL sites (32 in Draconian, 18 in Space Rocks, 32 in Robot War, 4 in Stay Frosty 2) all write C first on every executed path. ARM-state MULS and MLAS still halt with UNDEF, as in ARIA.

**MUL with Rd = Rm** runs. ARMv4T calls it UNPREDICTABLE, but the reference returns the product in 121 of 121 cases [sim]. ARIA's ARM MUL runs the same form (`:293-298`). GCC 13 used a spare register for a square; GAS accepts `muls r0, r0`.

#### What halts

`halt_pc` is the byte address of the halfword. Thumb has no conditional execution outside F16, so every halt below happens whenever the instruction is reached.

| Code | Thumb | The reference |
|---|---|---|
| 1 UNDEF | SWI (`0xDFxx`); Bcc cond 1110 (`0xDExx`); `0xB100–0xB3FF`, `0xB600–0xBBFF`, `0xBE00–0xBFFF` (v5 and v6 space); `0xE800–0xEFFF` (BLX suffix); BX with H1 = 1 (`0x4780–0x47FF`) or bits 2:0 ≠ 0; ADD, CMP, MOV with H1 = H2 = 0 (`0x4400–0x443F`, `0x4500–0x453F`, `0x4600–0x463F`); LDMIA/STMIA with an empty list (`0xC000`–`0xCF00` with a zero low byte); PUSH/POP with an empty list (`0xB400`, `0xBC00`) | UND or SWI exception; BX as a plain BX; H forms natural; empty lists move the base by 0x40 and PC [sim] |
| 2 REG | none in Thumb: every r15 use above is defined | |
| 3 THUMB | only in the BupChip profile (`arm_only`): BX to an odd address, as ARIA | |
| 4 FETCH (one clock later) | B, Bcc, BL suffix, BX, MOV pc, ADD pc or POP {pc} to a target outside the code space, other than the return sentinel; BX to ARM with bit 1 set, including BX PC at an address 2 mod 4; running past the end of the code space | fetches the word with bit 1 dropped, or aborts |
| 5, 6, 7 | as in ARM state, for every Thumb load, store, PUSH/POP and LDM/STM | |
| 8 FLAGS (new) | an instruction that reads C while it is unknown after a Thumb MUL (above) | reads its computed carry |

The H1 = H2 = 0 forms could run for free, because the reference's result is the natural one. They halt because ARMv4T leaves them UNPREDICTABLE, GAS refuses them for `-mcpu=arm7tdmi` ("MOV Rd, Rs with two low registers is not permitted on this architecture"), and no demo executes one [trace]. This is also `thumb_expand.py`'s choice (`:95`).

`thumb_expand.py`, the project's executable expander spec, needs three changes to match this section:
- a lone BL half runs instead of halting (`:159`);
- MUL with Rd = Rm runs (`:80`);
- the new code 8.

**Usage of the special forms, all 15 demos [trace].** These come from `pcs.txt.gz` and the images; the script is `sim/work/daria_thumb/usage.py`.
- **Common:** F6 LDR PC-relative 5.98% (half of them at addresses 2 mod 4), BL 2.31 M pairs, POP {pc} 1.27 M, BX LR 0.77 M.
- **Rare:** MOV pc, Rm 7,188 (2 demos); PC read as a hi-register operand 4,494 (1 demo).
- **Never executed:** ADD pc, CMP with PC, the H1 = H2 = 0 forms, MUL with Rd = Rm, LDMIA/STMIA with the base in the list, BX PC.
- **The added images** use only forms the demos use, and none of those above. Draconian reads PC as a hi-register operand at its helper calls, as Mappy does (153 times); the DPC+ images never.

#### Changes to ARIA's blocks

New parameter `THUMB`. At 0 everything below folds away and the core is today's ARIA. At 1 it is DARIA, with `MODES` 1.

On the single instance that serves both profiles (Decision 1), a static input `arm_only` (the BupChip profile) holds T at 0 and keeps BX to an odd address halting with code 3. ARIA's halt suites then stay valid unchanged. CoreTone never sets bit 0 for BX, so its run is identical either way.

| Block | Change | Where [C] | BupChip (ARM state) |
|---|---|---|---|
| PC and fetch | `pc[17:1]`; increments, r15 and link values by T; `pc[1]` picks the halfword; range checks on 32-bit targets, with the sentinel | `:223, 233-237, 611, 817-823, 842` | `pc[1]` = 0: the same sequence |
| Decode | ARM decode refactored into a control record, with the bank remap before the select; the Thumb decoder fills the same record; one mux on {T, `pc[1]`} | `:239-339, 365-376, 412-426` | the same functions; the remap-first form is equivalent |
| Register reads | r15 = address + 4 in Thumb, bit 1 cleared for `pcrel` | `:236, 390-398` | address + 8 |
| Shifter | Thumb type and amount (F1, else LSL #0); register-shift amount from port B; S_SHR2 reads Rd on port B | `:435-447, 902, 421` | unchanged |
| ALU and flags | Thumb immediates in the operand-2 mux; `zero_a`; MUL writes N and Z; `c_unk`; halt 8 | `:476-526, 614-616` | ARM MULS still halts |
| Load/store | sizes and signs from the record; store-data index per format (F11: hw[10:8]) | `:271-276, 419-421` | unchanged |
| LDM/STM | Thumb lists (PUSH's LR as bit 14, POP's PC as bit 15); POP {pc} loads `npc` in its last clock; PC in an ARM list still halts | `:316, 788-813` | unchanged |
| Branches, BX, T | offset mux before the branch adder; BL prefix as an ADD to LR; suffix target from the ALU sum; MOV pc from `rb`; T in `ctl[5]` | `:611, 691-704` | BX to odd halts 3 with `arm_only` |
| Halt codes | the Thumb rows above; code 8 | `:56-76, 165-171` | unreachable by CoreTone |
| Retire port (simulation) | `rt_pc` is the byte address; `rt_insn` = `{16'h0, hw}` in Thumb; new `rt_t` (T after the instruction) and `rt_cunk` | `:148-163, 934-947` | `rt_t` = `rt_cunk` = 0 |
| S3 (if chosen) | the third read port's Thumb index: store data hw[2:0] or hw[10:8], or the sequencer's | | |

#### Area [E]

ALUTs convert at about 0.6 ALMs each, Quartus's ratio on S1: 1,257 ALMs from 2,058 ALUTs [probe].

| Addition | ALMs | Basis |
|---|---|---|
| Thumb read indices (two copies, late select) and the ARM remap-first form | 70–90 | 154 − 30 = 124 ALUTs [syn] |
| Thumb control decode: class, op, flags, immediates, shift, size, list, condition, halts | 100–140 | 165 ALUTs [syn] (`depth/tctl.sv`, never simulated) |
| Merging about 60 controls by T; Thumb immediates into operand 2 | 40–80 | [E] |
| 17-bit halfword PC, increments by T, r15 and link values | 25–45 | [E] |
| Branch offset mux; `npc` inputs (sum, `rb`, the registered sum, load data); 32-bit range checks and the sentinel | 30–60 | [E] |
| T, BX interworking, launch T, `arm_only` | 5–15 | [E] |
| MUL flags, `c_unk`, halt 8 | 10–20 | [E] |
| F4 port roles, `rs_amt` mux, NEG | 10–20 | [E] |
| PUSH/POP lists, POP {pc} | 15–30 | [E] |
| **Total** | **305–500 (about 400)** | ARIA's per-block estimate came out 5.5% low at the top (risk 13) |

This sits inside step 0's 650–1,450 for "Thumb expander, S3 over S1, image capture, MMIO and timer, profile mux". S3 would add 10–15 for its third port's Thumb index. Nothing here uses M10K or DSP.

#### Verification

**Retire port and testbench.** The existing lockstep already runs Thumb programs reference against reference: five of the programs above, 14,637 retires, 0 mismatches [sim] (`run_lockstep.sh --build`, DUT=ref, with `+romhex`). The record (`tb_lockstep.sv:86`) and the access tagging by retire count need no change for Thumb. Step 2 adds:

1. **T in the record.** Reference: `cpu.arm_cpu.cpsr[5]` at the retire; the BX retire already shows the new T [sim]. DUT: `rt_t`. It is compared like NZCV (`:117-130, 181, 232`). `lockstep_dut_ref.sv` takes it from its own core's `cpsr`.
2. **C compared only when known.** While the DUT's `rt_cunk` is set, the C bit is skipped, and the run prints how many records skipped it. This is the only masking in the bench, and halt 8 bounds it.
3. **`rt_insn` = `{16'h0, hw}` and `rt_pc` = the halfword's byte address**, matching `trace_retire_*` [sim]. BL is two records, as on the reference.
4. **Builds.** `lockstep_dut_bup.sv` gets `THUMB` and `MODES` defines and a ROM depth parameter (`:77, 103`).
5. **Exceptions.** The reference takes UND or SWI where DARIA halts. As for ARIA, halt tests run the DUT alone against an expected code and PC (`s1/halt_tests.py`). `tb_ref_trace` confirms the reference's exception at the same address.
6. **The ISA flow works for Thumb as it is** [sim]. `run_isa.sh` builds `-marm` objects whose `.thumb` bodies assemble fine (`:28`). `iss_run.py` starts Unicorn in ARM state and follows BX into Thumb. Three differences need handling:
   - Unicorn counts a BL pair as one instruction and the reference as two, so the end-marker counts differ by the number of BLs (`t1_basic`: 21 against 22).
   - ARM926 is ARMv5T. POP {pc} with bit 0 clear switches it to ARM, and a misaligned BX PC faults on it [sim].
   - It leaves C unchanged after MUL.
   
   Directed tests of ARMv4T-only behaviour therefore run with `ISS=0`, and random streams pop only odd values.

**Retire examples (S1, Thumb).** The rules are the README's ("The retire port"), unchanged.

| Clock | Execute | `rt_start` | `rt_valid` | E | W | `rt_t` / `rt_cunk` |
|---|---|---|---|---|---|---|
| 1 | `bl` prefix at 0x54 | 1 | 1 | lr = 0x58 | — | 1 / 0 |
| 2 | `bl` suffix at 0x56 | 1 | 1 | lr = 0x59 | — | 1 / 0 |
| 3 | target, `push {r4, lr}`, clock 1 | 1 | — | — | — | 1 / 0 |
| 4–5 | beats: r4, lr stored | — | 5 | sp, in the first beat | — | 1 / 0 |
| 6 | `muls r0, r1`, clock 1 | 1 | — | — | — | 1 / 0 |
| 7 | MUL2 | — | 1 | r0 | — | 1 / 1 (C is skipped) |
| 8 | `adds r2, #1` | 1 | 1 | r2 | — | 1 / 0 |
| 9 | `pop {r4, pc}`, clock 1 | 1 | — | — | — | 1 / 0 |
| 10–11 | beats | — | — | sp, in the first beat | r4 in 11 | 1 / 0 |
| 12 | PC data into `npc` | — | 1 | — | — | 1 / 0 |
| 13 | the return target | 1 | … | … | — | 1 / 0 |

**Tests** (`sim/bupchip/daria/thumb/`, game-free).

| Test | Content |
|---|---|
| Directed | One program per format, every F4 op and condition, every F5 H combination with PC on each side, MOV/ADD pc, BX both ways and to hi registers, BX PC aligned, BL forward and backward (LR wrap) and lone halves, POP {pc} with bit 0 set and clear, LDM/STM with the base first, middle and last, PUSH/POP of r0–r7 + LR/PC, every load and store alignment, the flag corners above, MUL with Rd = Rm, a MUL followed by each kind of C writer and pass-through. The experiments in `sim/work/daria_thumb/t*.S` are the start. |
| Halts | Every row of the halt table at its address, and neighbours that must not halt: `0xB000`, `0xB080`, `0xB500`, `0xBD00`, `0xDDxx`, `0xF000` and `0xF800` alone, hi forms with one H bit set, MUL Rd = Rm; code 8 after a MUL for each reader, and none after each writer. |
| Random streams | `gen_thumb.py`, 400 seeds × 300 instructions, formats weighted by the trace mix. Forward branches, BL/BX calls, PUSH/POP and LDM/STM to a RAM scratch area, flags captured with Bcc into the signature. No C read after a MUL before a C write. Odd values only for POP {pc}. Signatures equal on the reference and Unicorn, then lockstep with DARIA: plainly, with `+await` and `+throttle`, and with `LATE_RF=1`. |
| Exhaustive decode | All 65,536 halfwords through the RTL decoder (in a Verilator harness) against the updated `thumb_expand.py --table` (`:270-276`): class, operation, indices, immediates, halt code. |
| Fuzz | Random halfwords from random states in lockstep, as `verif/directed/fuzz.py` does for ARM. Every halt must match the table; every other encoding must match the reference. |
| ARIA unchanged | `s1/check.sh` with Rikki & Vikki and `daria/modes/run_modes.sh`, built with `THUMB` 0 and with `THUMB` 1 + `arm_only`. Songs 13, 14, 9 and 30 identical to MiSTer's. With `THUMB` 0, the core proven equivalent to today's (`thumb/aria_equiv.sh`; step 2 replaced the planned cell-count comparison, "Step 2 work"). |

**Mutations**, each of which must fail a check above:
- PC for F6/F12 not word-aligned;
- the BL prefix's offset not shifted by 12;
- the suffix's link without bit 0;
- POP {pc} interworking (ARMv5);
- F1 LSR/ASR #0 as no shift;
- NEG as 0 − Rd;
- F5 MOV setting flags, or F5 CMP not;
- SBC's carry-in inverted;
- STMIA storing the old base when the base is not first;
- the halfword picked by `npc[1]` instead of the registered `pc[1]`;
- a Thumb increment of 2 halfwords;
- the late select keyed on T only;
- `c_unk` never set;
- BX to Thumb leaving T clear;
- F11's two-clock store data read from hw[2:0];
- MUL writing V.

**Step 2 is done when:**
- every directed and halt test passes, and the exhaustive decode check shows 0 differences;
- the random streams (400 seeds) and fuzz seeds 1–48 pass in lockstep with 0 mismatches, also with `LATE_RF=1` and with `+await=20 +throttle=10`;
- every mutation above is caught;
- ARIA's checks pass with `THUMB` 0 and with `THUMB` 1 + `arm_only`, and the four songs are bit-identical;
- the Yosys depth of the index path is not above today's (4 LUT6 levels on `idx.sv`'s harness of the real decode).

The demos' own code is step 5's: `tb_daria`, call by call.

### The memory system, the call port and the clock crossings

This section designs the memories DARIA's CPU and the lean 6507-side front ends share, the capture of the 2600 image, the cache for images over 128 KB, the 2600 memory map beside the BupChip's, the call port, timer 1 and MAMCR, and what the move of `clk_arm` off 2 × `clk_sys` changes. It takes decisions 1–6 as given, with images up to 512 KB. The front ends' own schedule and logic belong to another section (`sim/bupchip/daria/frontend_study/README.md`); here only their memory ports are fixed. The Thumb front end and S3 belong to steps 2 and 4; where this design depends on them, it says so.

#### Summary

- **The image ROM cannot be one port pair shared by the CPU and the front ends.** Step 0's open item 3 ("Port sharing") had the CPU's ROM data reads and the front ends on the image ROM's port B. An M10K port has one clock: the CPU's reads are on `clk_arm`, the front ends' on `clk_sys`, and the two clocks become asynchronous. The CPU needs two `clk_arm` ports (fetch and data) for the whole window, and the front ends need a `clk_sys` port onto the 6507-visible 32 KB. This design gives the front ends their own **32 KB front-end ROM** (+32 M10K). The M10K total becomes about **258 of 308** (262 with an 8 KB cache), not about 231. The alternatives are listed under 1.4.
- **CPU ROM:** two physical RAMs behind one 128 KB + 16 KB address space. The resident firmware stays in ARIA's 4,096 × 32 ROM (16 M10K). The image window is a new 32,768 × 32 RAM (128 M10K). Both have port A for fetch and port B for data, on `clk_arm`, and a static profile bit picks between them.
- **Cart RAM:** one 8,192 × 32 RAM with byte lanes (32 M10K) replaces ARIA's 16 KB RAM. Port A (`clk_arm`) is the CPU's in both profiles (the BupChip sees the low 16 KB); port B (`clk_sys`) is the front ends'.
- **Image capture:** the cartridge's bytes, taken by bridge address as `bup_capture` already does, go to four places. The SDRAM gets them as today. The front-end ROM is written directly on `clk_sys`. For a file that is not A78, the existing WRITE messages carry the whole file to the PSRAM, as they carry an A78's ARSC block, and the receiver also writes the first 128 KB into the window. No new message type.
- **Beyond 128 KB:** the BupChip's own asset path. The image sits in the PSRAM, and ARIA's asset cache, widened to 2 ways × 2 KB (5 M10K), serves data reads beyond the window through the asset port and `w_wait`, on `clk_arm`, with no clock crossing. A miss costs 13 `clk_arm` for a word load (8 for a byte or halfword). The SDRAM and its controller are untouched. Fetches beyond the window halt.
- **Call port:** a sequencer inside `bup_cpu`, built on its existing register-clear state, with no new input on the register-file write mux or the `npc` mux. The launch writes entries 0–21 in 22 clocks. The return reads FIQ r8–r13 out through read port B after forcing FIQ mode. The audio values cross through the front ends' dual-clock state RAM, with one toggle each way.
- **Decode:** the RAM test, `addr[31:28] == 4`, is the only part of the region decode on the critical path, and it is the same in both profiles. Everything that depends on the profile is registered or runs in W.
- **Timer 1** counts on `clk_sys` (M4). The CPU reads a `clk_arm` mirror of it. MAMCR and TCR are plain `clk_arm` registers.
- **Clock:** every existing BupChip crossing is already a synchroniser, except the `BUP_DEBUG` overlay's sampling. `psram.sv`'s state machine is the same at 28.636, 32.727 and 40.426 MHz [sim]. At 40.43 MHz its output-enable window is too short, and `CLOCK_SPEED` 50.0 fixes that.

#### 1. Physical memories and ports

##### 1.1 What each memory serves

| Memory | Words × bits | M10K | Port A | Port B |
|---|---|---|---|---|
| Firmware ROM (ARIA's, `bupchip_pocket.sv:234-238`) | 4,096 × 32 | 16 | `clk_arm`: fetch, BupChip profile | `clk_arm`: CPU data reads (BupChip); FWWRITE while `fw_loaded` is low |
| Image window (new) | 16,384 × 32 (64 KB, decision 8; designed as 32,768 × 32) | 64 | `clk_arm`: fetch, 2600 profile | `clk_arm`: CPU data reads (2600); the receiver's image writes while `img_ready` is low |
| Front-end ROM (new) | 8,192 × 32, byte lanes | 32 | `clk_sys`: capture writes during a download; a second front-end read port at run time (for example the jump lookahead) | `clk_sys`: 6507 reads, copy engine (DPC+ copy, F6) |
| Cart RAM (ARIA's RAM, `:240-244`, widened) | 8,192 × 32, byte lanes | 32 (16 were ARIA's) | `clk_arm`: CPU loads, stores, LDM/STM in both profiles | `clk_sys`: front ends, copy engine, audio samples (was tied off) |
| State RAM (front ends) | 256 × 32, dual clock | 2 | `clk_arm`: the call port, only while the CPU is parked | `clk_sys`: DPC+ fetchers, audio counters, frequencies, seeds, call block |
| Asset cache data (ARIA's, widened to 2 ways) | 2 × 512 × 32 | 4 (2 were ARIA's) | `clk_arm`: CPU reads in W | `clk_arm`: fills from the PSRAM, a halfword at a time |
| Asset cache tags (ARIA's) | 128 × {fifo, 2 × (valid, tag)} | 1 | `clk_arm`: lookup | `clk_arm`: probe, sweep, fill start and end |

- The 6507's ROM, the DPC+ copy source ($0C00 + {p1,p0}, clamped below $8000), F6's sources ($6C00–$7FFF and $0000–$07FF) and the CDF jump lookahead all lie inside image $0000–$7FFF. Upstream's jump table never arms at $7FFE or $7FFF (`cdf_fastjump_table.sv:28-37`), so the lookahead never needs $8000. So 32 KB serves the front ends exactly. CDFJ+'s entry and stack come from `detect2600` (`atari7800_pocket.sv:300`) and need no ROM read.
- The CPU needs the whole window on both of its ports. In the traces, code runs up to 0xB30A (Elevator Agent) and 0xAF76 (Turbo) (`sim/work/bupchip/daria/static_report.md`, code spans) [trace], and ROM data reads reach up to 0x1DE94 (Turbo).
- **Digital-audio ROM samples** (CDF, CDFJ, CDFJ+ in digital mode) can address any of the 512 KB, and they keep running during calls. They come from the PSRAM, which holds the whole image (section 3): one request per 20 kHz tick, crossing to `clk_arm` with a toggle each way. The image ports therefore carry no front-end traffic during a call, and the front-end study's slot s8–s11 "digital-audio ROM read" becomes that request.

##### 1.2 The CPU ROM: two RAMs, one address bit

- **Fetch:** `rom_q = prof26 ? win_qa : fw_qa`. The firmware RAM takes `npc[11:0]`, the window `npc[14:0]` (plus Thumb's halfword bit, step 2). `prof26` is a static `clk_arm` register (section 4).
- **Data:** `rom_dq = prof26 ? win_qb : fw_qb`. This folds into W's source mux (`bup_cpu.sv:568-575`).
- **Slices.** The window is built from 8K × 1 blocks, 4 deep by 32 wide, so its own output decoder is a 4:1 mux on registered address bits [14:13]. A Pocket-owned wrapper fixes `maximum_depth` 8192. Upstream's `cache_ram.v` leaves the choice to Quartus, which could pick 2K × 4 slices and a 16:1 decoder.
- **Since step 3:** the wrapper builds the window as four 8K × 32 RAMs read every clock, with the 4:1 mux on registered bits [14:13]. Since decision 8 it is two, with a 2:1 mux on bit 13 (`daria_mem.sv`, `WIN_KB`). One `altsyncram` puts a per-slice read-enable decode between `rom_addr` and the slices' clock enables, and that led the 40.43 MHz probe's worst paths.
- **Timing [E], the main risk of this design.**
  - The fetch output becomes a 4:1 slice mux followed by the 2:1 profile mux: one or two LUT levels in front of decode, where ARIA has none (`BUPCHIP_CORE.md`, "Pipeline").
  - `npc` fans out to 144 M10K instead of 16, and `d_addr` to about 180 (window, firmware, cart RAM, cache) instead of 35. They spread over about half the device's M10K columns.
  - Together these could cost 2–5 ns on a path that had +8.08 ns of slack at 28.64 MHz.
  - Step 3's probe must include the RAMs at full size. If the fan-out dominates, the first fix is to duplicate the last `npc` and `d_addr` mux stage per quarter of the window (about 60–120 ALMs).
  - The firmware cannot share slice decoding with the window. It has to stay resident (decision 5), and a 5:1 decode needs 8 LUT inputs either way.

##### 1.3 Cart RAM and the BupChip's RAM

- **Yes, ARIA's 16 KB RAM is folded in.** The instance at `bupchip_pocket.sv:240` becomes `ADDR_WIDTH` 13, with port B wired to the front ends instead of tied off. It costs +16 M10K net, as decision 4 budgets.
- The BupChip's window check stays at 16 KB (`bup_cpu.sv:544`). A wild store beyond it now lands in the unused upper 16 KB instead of aliasing (`BUPCHIP_CORE.md`, "Wild stores"), which is better.
- **Port B** is 32 bits wide, with byte enables for the 6507's byte writes, as the study's word register needs.
- **A collision to accept:** during a call the audio engine reads waveform bytes on port B while the CPU may write the same word on port A. With asynchronous ports such a read is undefined for that clock. It would give one glitched sample per collision, and upstream has the same race in other timing. It is counted, not prevented (open question 7). Step 5 counted it, and found the race narrower: the clocks share a VCO, so only a shared edge races. Step 6 decides whether to guard that edge as upstream does ("Step 5 work", results).
- **Clearing.** Every cartridge download zeroes all 32 KB through port B, by words on `clk_sys`: about 0.6 ms, with the core held anyway. The BupChip then never starts on RAM a 2600 game left behind (open question 8).

##### 1.4 The third port: alternatives considered

| Option | M10K | Cost |
|---|---|---|
| **Front-end ROM copy of $0000–$7FFF (chosen)** | +32 | none on the CPU; about 5–10 ALMs of capture |
| CPU fetch and ROM data share port A; the front ends get port B | 0 | +1 clock per ROM data read. These are 6.6–13.6% of instructions [trace], so CPI rises 6.6–13.6% under S3 and the 32.73 MHz baseline is lost. |
| All CPU ROM data reads through a 2-way 4 KB cache filled from window port B (`clk_sys`) | +5 | D hit 92–98% at 4K/16 [trace]: about +2–10% CPI, worst in the calls that evict each other. Not affordable at the baseline clock. |
| Window port B on a glitch-free clock mux (`clk_sys` between calls, `clk_arm` during them) | 0 | A switched clock on an M10K port, a second global and exclusive generated clocks. A timing and verification risk this project avoids. |
| Window cut to 96 KB, to stay near step 0's figure | +32 −32 | Turbo's top 32 KB goes through the cache. Reverses decision 3's 128 KB. |
| Front ends on `clk_arm` | 0 | Asynchronous to the 6507's bus; breaks the 12-slot schedule and the shadow verification |

##### 1.5 Block RAM budget

| | One bitstream | 2600-only fallback |
|---|---|---|
| Start (2.1.2), including ARIA's ROM 16, RAM 16, PCM 4 and asset cache 3 | 78 | 50 |
| Image window, 64 KB (decision 8; designed at 128 KB: +128, +112) | +64 | +48 (the firmware ROM reused) |
| Front-end ROM, 32 KB (new in this design) | +32 | +32 |
| Cart RAM to 32 KB | +16 | +16 |
| State RAM | +2 | +2 |
| Asset cache widened to 4 KB 2-way, as built (step 5: 6 M10K, the tags in 2) | +3 | +6 (no BupChip cache to widen) |
| **Total of 308** | **195 (63%)**; 259 with the 128 KB window | **154** |

The budget fits with 113 M10K spare (49 with the 128 KB window), which decision 8 keeps for later improvements. The step 0 figure of about 231 lacked the front-end ROM.

#### 2. Image capture

##### 2.1 Four destinations for one byte stream

| Destination | Bytes | Path | Clock |
|---|---|---|---|
| SDRAM | all, up to 4 MB | unchanged: `ch0_wr` (`atari7800_pocket.sv:397-400`); the 6507's reads for every other scheme | `clk_sdram` |
| Front-end ROM | file offsets 0–0x7FFF | direct byte-lane write on port A: `load_valid` (bridge bits 27:25 = 0, inside `bup_capture`'s cartridge window) and `load_addr < 0x8000` | `clk_sys` |
| PSRAM | the whole file, for a file that is not A78 | the existing WRITE messages, at the image's offset, as an A78's ARSC block goes today | `clk_sys` → `clk_arm` |
| Image window | offsets 0–0x1FFFF of that file | the receiver writes the same halfword into window port B, with its byte enables | `clk_arm` |

- **Bytes are taken by bridge address**, not by `cart_download`, exactly as `bup_capture` takes them (`bup_capture.sv:18-31`). The cartridge's last bytes can still be in the loader after its flag falls.

##### 2.2 Message stream changes (`bup_capture.sv`, `bup_asset_wr.sv`)

- **No new message type.** A file that is not A78 sends WRITE for every halfword from offset 0. An A78 file keeps sending WRITE only for its ARSC block, as today. The rate is the one the ARSC capture already sustains: one WRITE per halfword at the loader's pace, with the PSRAM busy 5 of every 10 or more `clk_arm` (`bup_asset_wr.sv:29-31`).
- **A78 gate.** The capture compares bytes 1–5 with "ATARI", as `atari7800_pocket.sv:243-249` does, and picks ARSC mode or image mode. Without the gate, a 2600 ROM whose bytes 49–52 happen to be non-zero would look like an A78 with an ARSC block (`bup_capture.sv:159-163`).
- **END payload:** {`is_a78`, 23-bit size}. For an A78 file the receiver sets `asset_size` and `asset_ready` as today (`bup_asset_wr.sv:101-104`). Otherwise it sets `img_size` = min(size, 512 KB) (20 bits) and `img_ready` = size ≥ 8.
- **Receiver.**
  - START clears both ready flags, so the CPU is held in either profile.
  - A WRITE below 128 KB in image mode also writes window port B. The port belongs to the receiver while `img_ready` is low, mirroring `fw_loaded`'s rule at `bupchip_pocket.sv:237`.
  - The receiver stays out of the hold, as today (`BUPCHIP_CORE.md`, "Reset and hold").
- **The PSRAM area.** The image overwrites the area an A78's ARSC block uses. The ARSC data belongs to the loaded A78 and is captured again with it, so nothing is lost.

##### 2.3 Ordering, reloads and resets

- **Firmware and cartridge** write different RAMs and set different flags, so their order does not matter. The capture's existing priorities already interleave a cartridge's tail with a firmware download (`bup_capture.sv:51-62`).
- The **profile** settles 1–2 `clk_sys` after `load_end` (`tia_mode`, `force_bs`). END leaves at least 64 `clk_sys` later, and START has held the CPU since `load_start`, so the CPU never runs on a stale profile.

| Event | Window and front-end ROM | Asset cache | MAMCR, TCR, TC | CPU | Cart RAM |
|---|---|---|---|---|---|
| New cartridge | rewritten from offset 0; words past the new file keep old data, which the size checks make unreachable | invalidated by its sweep after the release | cleared at START (P4) | held from START; registers cleared; released at END | zeroed, then F6 when the window closes |
| Console reset (mapper reset) | kept | swept | cleared (P4) | reset through two `clk_arm` flops: any call is abandoned and the registers are cleared | F6 again, the console held (`mapper_init_busy`) |
| PAL retune, `pll_busy` | kept | swept | TC cleared by reset | held, as ARIA | kept |

##### 2.4 The RAM image (F6): who does it

- **The front ends' copy engine on `clk_sys`** does it, from the front-end ROM (port B) into cart RAM port B.
- It starts when `bup_capture`'s cartridge window closes, 64 `clk_sys` after `load_end`, so trailing bytes are in. Upstream starts at `load_end` delayed (`cart2600.sv:710-716`).
- It runs again on every mapper reset.
- **The console is held** through `mapper_init_busy`, which `atari7800_pocket.sv:169-171` already adds to the core reset. With `POCKET_DARIA`, `cart2600.sv:592` takes it from the front end instead of 0.
- **DPC+** zeroes $0000–$0BFF and copies $6C00–$7FFF to RAM $0C00–$1FFF. **CDF** copies $0000–$07FF and zeroes the rest of `mapper_ram_size`.
- The CPU plays no part. The window is not needed, and a call cannot come before the 6507 runs.

#### 3. Bytes beyond the window (64 KB, decision 8): the asset cache over PSRAM

##### 3.1 Why PSRAM, not SDRAM

The cartridge loader already puts the image in SDRAM, so a cache over SDRAM was the first plan (decision 3). Working it through showed its cost:
- the SDRAM controller has one byte channel, and a DARIA client would need it, through a mux on a `clk_sys` → `clk_sdram` path, the class Fix B exists to relieve;
- the controller only refreshes when a read repeats a word, so a refresh keeper would be needed;
- a 16-bit tap in the vendored `sdram.sv` (GPL-3.0) would halve the fills;
- every fill would cross `clk_arm` → `clk_sys` → `clk_sdram` and back: about 24–30 `clk_arm` to the critical word.

In the 2600 profile the BupChip is idle, and so are its PSRAM, its `psram.sv` controller on `clk_arm` and its asset cache. The capture already writes an ARSC block there at the loader's rate. So the image goes to the PSRAM too, and the CPU reads it through the asset path it already has.

##### 3.2 Organisation

| Item | Choice | Why |
|---|---|---|
| Storage | The whole image in PSRAM die 0, at offset 0 (the ARSC area) | The digital-audio samples can address any offset (section 1.1) |
| Cache | `bup_asset_cache.sv` with a `WAYS` parameter: 2 ways × 2 KB = 4 KB (8 KB an option), 16 B lines | Per-call working set 0.2–1.0 KiB, at most 2.2 KiB; 89–98% of lines reused frame to frame; Spiders' tables 24 KiB apart alias in any direct-mapped cache up to 8 KB, and 2-way 4 KB hits 99.93% [trace] |
| Index, tag | offset[10:4] (128 sets); tag offset[18:11] per way, plus valid; one FIFO bit per set | Tags the full 19-bit offset, so a small-window test build (16–32 KB) caches correctly |
| Fill | As today: critical halfword first, round the line; prefetch and pre-emption kept (`bup_asset_cache.sv:37-45`) | The BupChip keeps its behaviour with `WAYS` = 1 |
| CPU side | ARIA's asset port: `w_asset`, `w_addr`, `w_size`, `asset_q`, `w_wait` (`bup_cpu.sv:130-135`). In the 2600 profile, RG_AST means "ROM beyond the window": 0x0002_0000 to `img_size` − 1, asset offset = address | No new CPU input; `w_wait` keeps its single source |
| Samples | A `clk_sys` request {offset, toggle} from the front ends; a `clk_arm` requester reads one halfword between cache reads and answers with a toggle | One per 20 kHz tick; about 0.5 µs including the crossings [E] |
| Invalidate | The cache's sweep, after every release (new image, mapper reset, hold) | P4 |

##### 3.3 The CPU side

- **Fetches beyond the window halt** with code 4 (FETCH), checked one clock late as today (`bup_cpu.sv:694, 703, 742`).
  - A fetch through the cache would need a stall in front of `rom_q`, on the critical path.
  - Code in the 15 demos ends at or below 0xB30A, and in the added images below 0x5700 [trace]; the CDFJ+ template starts its C code at `C_START`, at most $7800.
- **LDM/STM beats into the cache region** halt with code 7 (BLOCK), as asset LDMs do today (`:552-554`). The traced LDMIAs read RAM.

##### 3.4 Miss latency

`psram.sv` takes 5 `clk_arm` per halfword at 32.73 MHz (`CLOCK_SPEED` 28.636364), or 6 at 40.43 MHz (`CLOCK_SPEED` 50.0, section 7.4).

| | At 32.73 MHz | At 40.43 MHz |
|---|---|---|
| Byte or halfword load, over a hit | 8 `clk_arm`, 0.24 µs | about 9, 0.22 µs |
| Word load, over a hit | 13 `clk_arm`, 0.40 µs | about 15, 0.37 µs |
| Whole line | about 40 `clk_arm`, 1.2 µs | about 48, 1.2 µs |

- The step 0 study charged 524 ns per 16 B line [trace, assumption]; the critical word comes back faster than that, and the line about as fast.
- With the 128 KB window, no traced image misses at all. A small-window build ("Budget", testing) measures the cost on Turbo, Zaxxon and Elevator Agent. **Measured in step 5:** with 48 and 32 KB windows the cache serves them with no late call ("Step 5 work"), which led to the 64 KB window (decision 8). At 64 KB, Turbo alone reaches beyond the window: 150 demand misses in 1,500 frames, every call matching upstream.

#### 4. The two memory maps and the profile switch

| Region | BupChip profile (`bup_cpu.sv:42-49`) | 2600 profile |
|---|---|---|
| ROM, fetch and data | 0x0000_0000–0x0000_3FFF, firmware RAM | 0x0000_0000 to min(`img_size`, 128 KB) − 1, window |
| Beyond the window | — | 0x0002_0000 to `img_size` − 1: data reads through the asset cache over PSRAM (W waits on `w_wait`); fetch halts (4); LDM halts (7) |
| Assets | 0x0200_0000 + [0, `asset_size`), PSRAM cache | — (halts 5); the same cache serves the region above |
| RAM | 0x4000_0000–0x4000_3FFF (cart RAM, low half) | 0x4000_0000 + [0, `mapper_ram_size`): 8 KB, or 32 KB for CDFJ+ (`top.sv:779-783`) |
| MMIO | 0xE000_9000–0xE000_90FF, `bupchip_peripheral` | 0xE000_0000–0xE01F_FFFF: MAMCR 0xE01F_C000, T1TCR 0xE000_8004, T1TC 0xE000_8008 read back; anything else reads 0 and drops writes |
| Return | — (a branch there halts 4) | a fetch of exactly 0xF000_0000 ends the call |
| Everything else, stores to ROM | halt 5, 6 or 7 | halt 5, 6 or 7, where upstream aborts (M5) |

**Keeping the decode off the critical path:**
- **Region at execute** (`bup_cpu.sv:182-188`). Only `rg_x == RG_RAM` reaches the one-clock store decision (`:711`), and it is `addr[31:28] == 4` in both profiles. Since step 3 that test is `st_ram`, on Rn ± the immediate ("Step 3 work").
  - The ROM/asset split becomes `prof26 ? |a[18:17] : a[25]`. That feeds only the `acc_rg` register (`:879`), never logic in the same clock.
  - `prof26` is a `clk_arm` register: the profile through two flops, stable whenever the CPU runs (2.3).
- **Exact checks in W** (`:542-561`) gain the profile as one more LUT input:
  - `in_rom`: `acc_addr[31:17] == 0 && acc_addr[16:0] < img_size` (a 17-bit compare, needed when the image is under 128 KB), or 0x0000–0x3FFF.
  - `in_ast`: `acc_addr[31:19] == 0 && |acc_addr[18:17] && acc_addr[18:0] < img_size`.
  - `in_ram`: `acc_addr[31:15] == 17'h8000 && (ram32 || acc_addr[14:13] == 0)`, or the 16 KB test.
  - `in_io`: `acc_addr[31:21] == 11'h700`, or today's 0xE00090xx.
  - They feed only the halt register.
- **MMIO.**
  - The CPU's `reg_sel`, `w_addr`, `w_size` and `reg_wdata` (`:927-932`) go to both blocks. Each answers zero unless its profile is selected, and `reg_rdata` is their OR.
  - DARIA's block compares the full byte address, as upstream does (`arm_mapper_memory.sv:606-609, 953-960`). A byte access at +1 to +3 therefore reads 0 and drops its write, as there.
  - The byte strobes come from `w_size` and `w_addr[1:0]` (`st_bytes`, `:596-606`).
- **Return sentinel.**
  - The late target check (`:694, 703, 742`, and step 2's POP {pc} and hi-register MOV/ADD pc) gains a parallel compare. The fetch address the target implies is word-aligned in ARM state and halfword-aligned in Thumb. If it equals 0xF000_0000 in the 2600 profile, the core returns instead of halting.
  - That is upstream's `mem_fetch && mem_addr == 32'hF0000000` (`arm_mapper_memory.sv:558`). So 0xF000_0001 (Thumb) returns, and 0xF000_0002 halts.
  - The compare sits in the registered `late_go` path, not in `npc`.
- **Halts during a call.** The call never returns, and the 6507 stays held. `halted`, `halt_code` and `halt_pc` reach `clk_sys` through two flops for DARIA's status overlay (step 8). A console reset recovers. Upstream's abort lands in the driver's vectors, which is no better.
- **`MODES` 1 for both profiles.** CoreTone's one MSR writes 0xD3, which `MODES` 1 accepts, and ARIA's tests pass in lockstep with `MODES` 1 ("Step 0 work").

#### 5. The call port

##### 5.1 A sequencer inside `bup_cpu`, not an external port

- The register file has one write port, and its data mux sits on the ALU result path.
- **Launch writes.** `S_CLEAR` already writes entry `clr_idx` with `rf_wd = 0` and sets `npc = 0` (`bup_cpu.sv:652-658`); with `MODES` 1, `rf_pa = clr_idx` (`:376`).
  - The launch reuses that state. The constant 0 becomes the input `clr_wd`, and `npc = 0` becomes `clr_pc`, both registered by the wrapper.
  - Neither mux gains an input. At most a constant turns into a signal (check in step 3).
  - An external port would need a second path into the MLAB's single write port, which is a mux anyway.
- **Return reads.** The readout uses read port B, as the store-data path does (`ib`, `:413-426`).
  - On the return it sets `m_fiq` = 1 and `m_svc` = 0. The existing `phys()` remap (`:365-374`) then maps r8–r13 to FIQ entries 16–21 with no new mux.
  - `ib` gains one state-selected case.

**New `bup_cpu` ports (`MODES` 1):**

| Port | Direction | Meaning |
|---|---|---|
| `prof26` | in | 2600 profile, static while running |
| `call_go` | in | one clock; legal only while `parked` |
| `clr_wd[31:0]`, `clr_pc` | in | data for the entry being written; the entry PC (0 for the reset clear) |
| `clr_idx` | out | entry written this clock (the wrapper reads the state RAM one clock ahead) |
| `parked`, `returned` | out | idle between calls; one clock when the readout ends |
| `ro_valid`, `ro_idx[2:0]`, `ro_data[31:0]` | out | FIQ r8–r13 during the readout (`ro_data` = `rb`) |
| `img_size[19:0]`, `ram32` | in | for the W checks (with `asset_size` kept for the BupChip) |

**States** (they add to S1's eight at `:209-218`; S3 will have the same three):

| State | Effect |
|---|---|
| S_CLEAR | After `rst`: entries 0–31 ← 0, then S_RUN at 0 (BupChip) or S_IDLE (2600). For a launch: entries 0–21 ← `clr_wd` (22 clocks), then `pc` ← `clr_pc`, NZCV ← 0, control byte ← {I = 0, F = 0, T = 1, SYS}, then S_RUN. |
| S_IDLE | Parked: no fetch is used, no memory access, no register write |
| S_READOUT | Set FIQ mode; then 6 clocks with `ib` = r8…r13 → `ro_*`; then S_IDLE and `returned` |

- **What the launch writes** (`clr_wd` by entry):
  - 0–12: 0.
  - 13: the stack.
  - 14: 0xF000_0000.
  - 15: 0. That entry is unused; r15 is never read from the file.
  - 16–18 (FIQ r8–r10): the three counter seeds.
  - 19–21 (FIQ r11–r13): the three frequencies.
- **What it leaves:** FIQ r14 (entry 22) and SVC r13–r14 (29–30), as P1 requires and upstream does (`arm_mapper_controller.sv:219-231`).
- The T bit and a halfword PC come with step 2. All four schemes call in Thumb (`mapper_dpcplus.sv:186`, `mapper_cdf.sv:162`).

##### 5.2 Hand-off through the state RAM

The front ends keep a call block of 14 words in their state RAM: entry, stack, seed ×3, frequency ×3 (their live words), return counter ×3, return frequency ×3. Each side touches a word only between the two toggles.

| Step | Where | What |
|---|---|---|
| 1 | `clk_sys`, at the CALLFN commit (E0+6) | `call_busy` ← 1, so `arm_call_stall` holds the 6507 from the next cycle. Queue the 3 seed copies (counter → seed, read-write in background slots) after any NOTE or tick job in flight. |
| 2 | `clk_sys` | Seeds written, the CPU ready (`parked & img_ready`, through 2 flops), no mapper reset: flip `call_tog` |
| 3 | `clk_arm` | `call_tog` through 2 flops: `call_go`. The wrapper drives `clr_wd`: constants, or state RAM port A `q`, read at `clr_idx` + 1. |
| 4 | `clk_arm` | 22 clocks of writes, then the driver runs |
| 5 | `clk_arm` | Sentinel fetch: S_READOUT. The wrapper writes `ro_data` to the 6 return words (port A). Then it flips `ret_tog`. |
| 6 | `clk_sys` | `ret_tog` through 2 flops. For CDF and CDFJ(+): counter_v ← return_v if return_v ≠ seed_v; frequency_v ← return frequency_v (`arm_mapper_audio.sv:207-223`). DPC+ skips the merge, as upstream does for family 1. Then `call_busy` ← 0. |

- **Latency [E].**
  - Launch: one 6507 cycle for the seeds + 3 `clk_arm` + 22 `clk_arm`, about 1.6 µs at 32.73 MHz.
  - Return: 7 + 3 `clk_arm` + 3 `clk_sys` + the merge, about 1.7 µs.
  - That is about 2 µs more per call than upstream's controller. With two calls a frame and budgets of 0.5–2.2 ms, it costs 0.1–0.5% of a budget.
- **Ticks run on during the call.** They update counter_v only, never the seed, frequency or return words. NOTE writes come from the stalled 6507, so the frequencies cannot change under the launch.
- **Stall interface.** `top.sv:306-329` stays as it is (`arm_call_stall`, `mapper_phi2`). With `POCKET_DARIA`, `cart2600.sv:535, 542, 592` take `arm_dma_busy`, `arm_call_busy` and `mapper_init_busy` from the front ends instead of 0.
- **Reset.**
  - A mapper reset (cart2600's `reset`, the console reset) clears `call_busy` on `clk_sys` at once.
  - It also reaches `clk_arm` as a level through 2 flops, puts the CPU in `rst`, and sets both sides' "seen" registers to their synchronised toggles, as upstream does (`arm_mapper_controller.sv:144-147, 271-276`). A return from an abandoned call is then ignored.
  - A deviation: DARIA's reset clears the banked registers, while upstream keeps them through a mapper reset. Only a driver that reads FIQ r14 or SVC r13/r14 before writing them could see it; none in the traces does.

#### 6. Timer 1 and MAMCR

| Register | Lives on | Behaviour (upstream `arm_mapper_memory.sv:474-489, 729-737, 953-960`) |
|---|---|---|
| MAMCR 0xE01F_C000 | `clk_arm`, 32 FF | Byte-strobed write, read back; cleared by mapper reset and START |
| T1TCR 0xE000_8004 | `clk_arm`, 32 FF | Byte-strobed, read back; bit 0 reaches `clk_sys` through 2 flops as the count enable |
| T1TC 0xE000_8008 | the counter on `clk_sys`; a mirror on `clk_arm` | The counter adds 5 or 4 per `clk_sys`: NTSC 8 × 5 + 4 per 9 clocks (14.318 MHz × 44/9 = 70.000 MHz); PAL 71 × 5 + 5 × 4 per 76 clocks, the fours spread evenly (70.0045 MHz) (M4). It stops on `pause`, upstream's `mem_ce`. |

- **Writes to TC.** {data, strobes, token} go held, with a toggle, to `clk_sys`, which merges the strobed bytes into the counter. A write wins over the increment in that clock, as upstream's later assignment does. The mirror takes the written bytes at once.
- **Reads of TC.** Every 4 `clk_sys`, the counter is copied into a hold register with a toggle; `clk_arm` copies it into the mirror only when the snapshot's token matches the last write. A read is then at most about 8 `clk_sys` (0.56 µs, about 40 counts) stale, and never older than the CPU's own last write.
- **Precision.** Draconian is the only traced game that uses the timer, and only at power-on [trace; sim, `tb_daria +mmiolog=1`]. 42–44 instructions into its second call it zeroes T1TC and sets TCR bit 0; 43 instructions into its fourth, a frame later, it clears the bit and reads T1TC three instructions on: 1,168,115 on upstream, one NTSC frame at 70 MHz less 0.8 µs. It compares that with 1,171,987 [C, comment], so the margin is 3,872 counts (0.33%). Both accesses lie the same depth into their calls, so DARIA's slower clock moves the reading by under 1 µs (about 55 counts); the stop's two-flop delay and the read's staleness add at most about 55 more. Together that is about 3% of the margin. **Measured in step 5:** DARIA reads 37 counts above upstream, in both Draconian builds.
- MAMCR keeps all 32 bits, because upstream reads them back. Scramble writes it 4,172 times with `strb` [trace].
- Cost: about 230 FF; 110–150 ALMs [E].

#### 7. What the clock change touches

**Edge relationships.** From the 687.27 MHz VCO, `clk_sys` is ÷48, `clk_sdram` ÷12 and `clk_arm` ÷21 or ÷17. The tightest edge pair between `clk_sys` and `clk_arm` is gcd × 1.455 ns: 4.37 ns at ÷21 and 1.46 ns at ÷17. Between `clk_sdram` and `clk_arm` it is 4.37 ns or 1.46 ns. No logic meets that, so every crossing must be a synchroniser or a bus held behind one.

##### 7.1 Crossings that exist today in the BupChip path

| # | Signal | File:line | Kind | At 32.73 or 40.43 MHz |
|---|---|---|---|---|
| 1 | `pll_locked`, `pll_busy` → `clk_sys` | `bupchip_pocket.sv:147-153` | 2 flops, level | unchanged |
| 2 | hold `clk_sys` → `clk_arm` | `:148-158` | 2 flops, level | OK |
| 3 | pause `clk_sys` → `clk_arm` | `:155-160` | 2 flops, level | OK |
| 4 | `$8007` command | `:262-268` → `:270-277` | toggle through 3 flops; byte held, sampled each clock | the byte needs a bounded delay |
| 5 | capture messages | `bup_capture.sv:214-244` → `bup_asset_wr.sv:84-117` | toggle through 2 flops; 44 (now 48) bits held at least 5 `clk_sys` | copied within 3 `clk_arm` (92 or 74 ns); bounded delay on the payload |
| 6 | 48 kHz tick, `clk_74a` | `bup_tick48k.sv:159-173` | toggle through 3 flops | already asynchronous |
| 7 | audio frame `clk_arm` → `clk_sys` | `bupchip_pocket.sv:308-323` → `:326-338` | toggle through 3 flops; frame held 20.8 µs | OK |
| 8 | `BUP_DEBUG` capture error → `clk_arm` | `:376-380` | 2 flops | OK |
| 9 | `BUP_DEBUG` status to the overlay (`dbg_status`, `dbg_halt_pc`, `dbg_load`'s `clk_arm` bits) | `:383-386, 427-430`; `bup_status_osd.sv:43-44, 72-90` | **none: sampled raw on `clk_sys`**, timed only because `clk_arm` = 2 × `clk_sys` | Needs a fix: a snapshot with a toggle once per frame (about 180 FF), or a false path on these display-only bits |

Every one but #9 was built for asynchronous clocks and stress-tested at 16–29 MHz ("Clock"); they are re-run at the new rates.

##### 7.2 New DARIA crossings

| Signal | Direction | Kind |
|---|---|---|
| image-mode WRITE, END payload | `clk_sys` → `clk_arm` | the message stream (#5) |
| profile (`prof26`, scheme, `ram32`) | `clk_sys` → `clk_arm` | 2 flops, static while the CPU runs |
| mapper reset | `clk_sys` → `clk_arm` | 2 flops, level |
| `call_tog` / `ret_tog` | both ways | toggle through 2 flops; data in the dual-clock state RAM |
| CPU ready (`parked & img_ready`), halt status | `clk_arm` → `clk_sys` | 2 flops, level |
| digital-sample request and answer | both ways | toggle through 2 flops; offset and byte held |
| TCR[0]; TC write; TC snapshot | both ways | 2 flops; held write plus toggle; held snapshot plus toggle |
| cart RAM, state RAM | — | dual-clock M10K, ordered by the toggles above |

##### 7.3 SDC (`core_constraints.sdc`)

- **Groups.** Today the four counters form one synchronous group (`:12-22`). `counter[0..2]` stay in it.
- **`clk_arm` (counter[3])** stays related. All `clk_sys` ↔ `clk_arm` paths get exceptions [E]:
  - `set_max_delay -from [get_clocks $clk_sys] -to [get_clocks $clk_arm] 20.0`, the same in reverse, and `set_min_delay … -20.0` both ways.
  - 20 ns is under one `clk_arm` period at 40.43 MHz. That bounds the held buses (#4, #5, the call block's toggles, the sample request, the TC mailbox), which are sampled at least 2 destination clocks after their toggle.
- **Not asynchronous groups.** In TimeQuest a clock-group cut outranks `set_max_delay`, so asynchronous groups would leave those buses unconstrained.
- **`clk_arm` ↔ `clk_sdram` and ↔ `clk_sys_90`** keep their real 4.37 ns or 1.46 ns relationship as a tripwire. Any path there is a design error, and it then fails timing visibly.
- **Synchronisers.** Mark the first flop of every chain `SYNCHRONIZER_IDENTIFICATION FORCED` in `ap_core.qsf`, so the fitter packs the chains and reports their MTBF.
- **Fitter over-constraint.** The fitter-only block (`:55-59`) still covers `core_clks` → `clk_sdram`.
- Step 3's probe confirms the form with `report_timing` on the crossings. **Confirmed** (open item 9): the exceptions apply. −20 stays: with 0, a held bus fails a hold check that means nothing for it.

##### 7.4 `psram.sv`'s `CLOCK_SPEED` (the BupChip's assets)

- **[sim]:** iverilog elaborations of `psram.sv`, run here (`sim/work/daria_step1/`), print the same states at 28.636364, 32.727272 and 40.425532:
  - Read: 20, 21, 22, 23.
  - Write: 1, 2, 3, 4.
- **Read timing [C]** (`psram.sv:248-381`). `adv_n` falls at the accept edge, `oe_n` at state 22's edge, and the data is sampled at state 23's edge.
  - From `adv_n`: 4 clocks, so 122 ns at 32.73 MHz and 99 ns at 40.43 MHz, against the 70 ns access time.
  - From `oe_n`: 1 clock, so 30.6 ns or 24.7 ns, against the part's output-enable access of about 20 ns plus about 7 ns of pad delays [E].
- **32.73 MHz:** keep 28.636364. It behaves as today, at 5 clocks (153 ns) per halfword.
- **40.43 MHz:** use 50.0 [sim]. Reads become 20, 21, 22, 24 (two clocks from `oe_n`) and writes 1, 2, 3, 5: 6 clocks (148 ns) per halfword.
- In both cases update the comment at `atari7800_pocket.sv:1195-1198` and check on hardware with the ARSC readback.

##### 7.5 Everything else that assumed 2 × `clk_sys`

- **Comments:**
  - `pll/pll_core.v:14`, and the setting at `:70` (`output_clock_frequency3`; regenerate with C3 = 21 or 17, `DEVELOPING.md:245-271`);
  - `core_top.v:312`;
  - `atari7800_pocket.sv:13, 27`;
  - `bupchip_pocket.sv:7-9`;
  - `bup_asset_wr.sv:8-9` ("10 `clk_arm`");
  - `core_constraints.sdc:3-13`.
- **Testbenches:** `sim/tb_system.sv:32` and `sim/tb_load.sv:26` drive `clk_arm` at `2 * T_HALF_SDRAM`. They need their own period, and a free-running phase so the crossings are exercised.
- **Upstream's `cart_ram_tdp.sv:27-50`** relies on 5 × `clk_sys`. It is not built (`EXTERNAL_CARTRAM`) and DARIA does not use it.
- **Unchanged:** `sram_ctrl.sv:54, 265` are `clk_sys` ↔ `clk_sdram` paths.

#### 8. Area and files

| Part | ALMs [E] | M10K | Assumption |
|---|---|---|---|
| Window and firmware ROM: slice and profile muxes on two 32-bit read ports | 60–100 | 128 new, 16 kept | 8K × 1 slices |
| Front-end ROM and its capture decode | 5–10 | 32 | byte lanes, no output decoder |
| Cart RAM (ARIA's widened) | 0–5 | 32 (16 kept) | |
| State RAM | 0 | 2 | dual-clock TDP |
| Capture: A78 gate, image-mode WRITE, END; receiver window writes, `img_ready`, `img_size` | 40–70 | — | about 100 FF |
| `bup_cpu` map: profile checks, ROM/cache split, sentinel, 32 KB RAM, MMIO window | 30–50 | — | |
| Call port in `bup_cpu` (S_IDLE, S_READOUT, launch end index, PC and control-byte load) | 40–70 | — | |
| Call port, wrapper side (`clr_wd` 4:1, state RAM port A, toggles) | 50–70 | — | |
| MMIO and timer 1 | 110–150 | — | about 230 FF |
| Asset cache: a second way, FIFO bit, image offsets; the sample requester | 40–70 | +2 (+6 at 8 KB) | |
| New synchronisers | 15–25 | — | |
| **Total** | **390–620** | **+180 over 2.1.2 (258 of 308)** | |
| Optional: `npc`/`d_addr` duplication per window quarter | +60–120 | — | only if step 3 needs it |

- **Against step 0's budget:**
  - Call controller: 100–150 there, 90–140 here.
  - Cache: 150–250 there, 40–70 here, by reusing ARIA's.
  - Capture, MMIO, timer, profile mux and the window's muxes: 275–415 here. That fits inside the 650–1,450 row once Thumb and S3 take their 350–910.
- The front ends (850–1,100) are not in this table.

**New files** (Pocket-owned, MIT, `src/fpga/core/bupchip/`):
- `daria_mem.sv`: the window, the front-end ROM, the cart RAM and the state RAM, with `maximum_depth` set, and the port muxes.
- `daria_mmio.sv`: MAMCR, TCR, the TC mirror and counter.
- `daria_call.sv`: the `clk_arm` side of the call port.

**Changed Pocket files:**
- `bup_cpu.sv`: section 5.1, and the map in section 4.
- `bupchip_pocket.sv`: the profile, the run gate (`cpu_run = ~hold & (souper ? fw_loaded & asset_ready : img_ready) & sweep_done & ~mreset`), the new instances, `ifdef POCKET_DARIA` ports.
- `bup_capture.sv`, `bup_asset_wr.sv`: the A78 gate, image-mode WRITE, END.
- `bup_asset_cache.sv`: `WAYS`, image offsets, the sample requester.
- `bup_status_osd.sv`: #9.
- `atari7800_pocket.sv`: the DARIA wiring, `psram`'s `CLOCK_SPEED`.
- `core_top.v`, `pll/pll_core.v`, `core_constraints.sdc`.
- `ap_core.qsf`: `POCKET_DARIA`, synchroniser assignments.
- `core.qip`, `sim/run_sim.sh`, `sim/tb_system.sv`, `sim/tb_load.sv`.

**Vendored** (`ifdef POCKET_DARIA` blocks only; identical to upstream without the macro, `POCKET_CHANGES.md:91-93`):
- `mister/rtl/cart2600.sv`: `arm_call_busy`, `arm_dma_busy` and `mapper_init_busy` from ports (`:535, 542, 592`); the front ends' hook-up and `is_bad_game` (`:158-167`) are the front-end section's.
- `mister/rtl/top.sv`: a port group beside `POCKET_BUPCHIP`'s, for the front ends.
- `cache_ram.v` stays unchanged: the new RAMs use Pocket wrappers.
- Add a `POCKET_DARIA` row to `POCKET_CHANGES.md`.

### The front end (`daria_fe`)

One Pocket-owned module serves DPC+ and the CDF family (CDF0, CDF1, CDFJ, CDFJ+). It replaces upstream's `mapper_dpcplus`, `mapper_cdf`, `arm_mapper_tables`, `arm_mapper_audio`, `arm_mapper_ram_init`, `arm_mapper_writeback` and `cdf_fastjump_table`, none of which is in the build since 2.1.2. Its architecture is the front-end study's (`sim/bupchip/daria/frontend_study/README.md`, §3), without BUS (Decisions, 6).

**Where it sits.** `daria_fe` lives beside the CPU's memories in the Pocket wrapper, not inside `cart2600`, because it reads its own image ROM and cart RAM directly. The vendored files change only through `POCKET_DARIA` blocks (`mister/POCKET_CHANGES.md`):

- `cart2600.sv`, inside the existing `NO_ARM_MAPPER` block: the `BANKDPCP` and `BANKCDF` outputs (`direct_do`, `flags_out`, `out_en`, `rom_addr`, `ram_*`) come from new input ports instead of the idle constants, and `is_bad_game` drops `BANKDPCP` and `BANKCDF` (it keeps `BANKELF` and `BANKBUS`).
- `top.sv`: a `POCKET_DARIA` port group, beside the `POCKET_SRAM` one, carries the 6507 side out and the answers back in. `arm_call_busy` and `arm_dma_busy`, which already feed `arm_call_stall` (`top.sv:306-307`), come from the Pocket side under the macro.

| Signal | Direction | What it is |
|---|---|---|
| `a_in[12:0]`, `d_in[7:0]`, `rw` | out of `top.sv` | the 6507 bus, as `cart2600` sees it |
| `phi1`, `access` | out | `pclk1` (the phase-1 edge, E0) and `mapper_phi2 && arm_driver_run`: commit only on this edge (F1) |
| `scheme`, `revision`, `cdf_ldx`, `cdf_ldy`, `cdf_fetch_offset*`, `cdfj_entry`, `cdfj_stack`, `arm_audio_size_addr` | out | `detect2600`'s results for the loaded image |
| `cart_reset` | out | console reset or a new image: rebuild the RAM image (F6) |
| `fe_do[7:0]`, `fe_oe` | in | the byte the cartridge drives, and whether it drives (`$1xxx` reads) |
| `arm_call_busy`, `arm_dma_busy` | in | the 6507 stall: a call in flight, or a DPC+ copy/fill |

The call request (entry, stack, T bit) goes from `daria_fe` to the call controller beside the CPU, not through `top.sv`.

**Memories it uses** (all on `clk_sys`; the memory-system section has the ports' other users):

| Memory | Port | Use |
|---|---|---|
| Front-end ROM: image $0000–$7FFF, 32 KB (the memory system, 1.1) | A and B, 32-bit reads | the 6507's bank bytes, the fast-jump lookahead, the copy engine's source |
| Cart RAM, 32 KB | B, 32-bit with byte enables | CDF stream pointers, increments and data (in place, as the driver keeps them), DPC+ display data, WRITE/PUSH/DSWRITE, the copy engine's destination |
| State RAM, 256 × 32 | B | DPC+ fetchers (two words each, fields on byte lanes), DPC+ parameters, the audio counters, frequencies and their launch values |
| PSRAM (the whole image) | a request to `clk_arm` | digital-audio samples, one per 20 kHz tick, wherever they lie (the memory system, 3.2) |

The call controller reaches the audio words through the state RAM's other port while the CPU is halted (P1, P2).

**The slot schedule.** Each 6507 cycle is 12 `clk_sys` (s0–s11 from E0). Every stage is a registered path, M10K output → logic → M10K address, so nothing here touches the `clk_sdram` cone.

| s | Front-end ROM | Cart RAM | State RAM | Datapath, 6507 |
|---|---|---|---|---|
| 0 | read the bank word at `a` | (audio) | | address valid |
| 1 | the byte at `a`: decode fast fetch, fast jump, register | read the stream pointer (CDF) | read the fetcher word (DPC+) | `d_out` ← ROM byte, random byte or AMPLITUDE |
| 2 | read the next word (jump lookahead) | pointer in; read the data byte at `$800` + P[31:20] (CDFJ+: P[30:16]) | fetcher in; read the byte at `$C00` + counter or fraction[19:8] | W ← the word; window flag |
| 3 | lookahead in: `jump_ok` | data byte in; read the increment | | `d_out` ← RAM byte (and the flag); W ± 1, fraction + increment, or + 1<<20 |
| 4 | | increment in: W ← W + I<<12 (CDFJ+: <<8) | | data final, two clocks early |
| 5 | | | | **edge E0+6, if `access`:** latch `d_in` and the operation; bank; mode; DSPTR shift-in. The 6507 latches `d_out`. |
| 6 | | write the pointer back | write the fetcher back (or field bytes) | |
| 7 | | WRITE, PUSH or DSWRITE byte | DPC+ parameter byte | |
| 8–11 | copy-engine source | copy-engine destination; audio samples | audio counter and frequency read-modify-write | audio owns W from s8 to s1; a digital-sample request to the PSRAM |

The busiest cycle, a CDF fast fetch, uses 6 of the 12 slots (study §3.2).

**The rest of the design** is the study's (§3.3–§3.7): one 32-bit word register W and one adder shared by the schemes and the audio engine, one window comparator on the fetcher word just read, a copy engine for the RAM image and DPC+ copy/fill, and the audio engine (one voice job per 6507 cycle in s8–s1, the barrel shift kept for exactness). The coding rules of §3.8 apply: under `MUX_RESTRUCTURE OFF`, one load enable and at most a 4-way data mux per register.

**Upstream behaviours kept** (study §2.7): DPC+ fast fetch arming on data bytes, 6-bit DPC+ register numbers, params 4–7 stored and never read, the service clamps, hotspots ignored on substituted reads, the jump lookahead crossing bank ends. Two differences are expected and counted in verification: AMPLITUDE may lag a tick (upstream's update latency varies with its RAM grant), and `open_bus` keeps the committed byte where upstream's combinational `d_out` changes after the latch edge.

**Size.** A sizing sketch of it (`frontend_study/daria_fe3.sv`, never simulated, with BUS) compiles to **1,004 ALMs and 2 M10K**: core 436, shared datapath and port arbitration 239, audio 225, copy engine 104 [probe]. With what it leaves out, less what can still be shared: **850–1,100 ALMs** [E]. The call controller shrinks to 100–150 ALMs [E], because the audio values move through the state RAM while the CPU is halted.

| | Upstream, reused | Lean |
|---|---|---|
| Front ends | 2,192 live (1,752 as tied off in 2.1.1, none since 2.1.2), plus 60–100 of `cart2600` glue [probe] | 850–1,100 [E; sketch 1,004] |
| Call controller | 716 [probe] | 100–150 [E] |
| M10K | 8 | 2 |
| On the `clk_sdram` path | yes | no |

Coding style matters under the project's `MUX_RESTRUCTURE OFF`: the same sketch written as state machines took 1,343 ALMs. Each register gets one load enable and at most a 4-way data mux.

**How it will be proved:** as a cycle-by-cycle shadow of upstream's front ends inside `tb_daria.sv`, as POKEY was (`run_pokey_shadow.sh`): the same 6507 bus into both, data compared at every latch edge, state compared after every cycle, AMPLITUDE compared per tick. Then directed tests per scheme (BUS has no demo) and a random differential bench. Two differences are expected and will be counted, not hidden: AMPLITUDE can lag a tick at a different clock, and stall lengths differ.

### Fix B: the 2600 cartridge-RAM request on its own registered path

Step 1 design for Fix B (`SRAM_TIMING.md`, "Fix B"; decision 2). It ships with DARIA. DARIA's own cart RAM is in block RAM (decision 4), so Fix B covers the 2600 RAM mappers that remain on the SRAM. Line numbers are from the current tree (2.1.2 + Fix A).

Clock names: E*n* is the *n*th `clk_sys` edge after E0. E0 is the edge where `pclk1` loads the 6507's address. `clk_sdram` edges are counted from E0 too, so E1 = s4, E2 = s8, E6 = s24.

#### 1. The split

##### `top.sv` (vendored, `ifdef POCKET_SRAM`)

- **Ports.** Four new outputs go in the existing `POCKET_SRAM` port group (`:23-35`): `cartram_addr26_out[17:0]`, `cartram_wr26_out`, `cartram_rd26_out` and `cartram_wrdata26_out[7:0]`. Upstream names its internal nets `cartram_*26` (`:247-250`), so the ports take `_out`, as `mclk1_out` does.
- **The merge** (`:752-759`) becomes `ifdef POCKET_SRAM` *split* / `else` *upstream merge, unchanged* / `endif`:

```systemverilog
wire cartram_sel26 = mapper_init_busy | tia_en;      // the merge's own select
assign cartram_wr = ~cartram_sel26 & cartram_wr78 & mclk1;   // 7800 request only
assign cartram_rd = ~cartram_sel26 & cartram_rd78 & mclk1;
assign cartram_addr = cartram_addr78;
assign cartram_wrdata = cartram_wrdata78;
assign cartram_wr26_out = cartram_sel26 & cartram_wr26;       // 2600 request
assign cartram_rd26_out = cartram_sel26 & cartram_rd26;
assign cartram_addr26_out = cartram_addr26;
assign cartram_wrdata26_out = cartram_wrdata26;
```

Together the two ports carry exactly what the merge carried, under the same select. `mapper_init_busy` is 0 under `NO_ARM_MAPPER` (`cart2600.sv:592`), so in the Pocket build the select is `tia_en`.

##### `sram_ctrl.sv` (Pocket code)

- **Ports.** New inputs `clk_sys` and a 2600 request port: `t_rd`, `t_wr`, `t_addr[16:0]`, `t_wdata`. The `c_*` port keeps the 7800 request and the BIOS read. `c_rdata` serves both ports: it stays one client (`CL_CART`).
- **The register lives in `sram_ctrl`,** not in `atari7800_pocket.sv`. Inside the module, nothing can feed the compare from the unregistered port by mistake.
- **The request logic.** It replaces `:210-234`; the header (`:34-36`, `:60-61`) changes to match.

```systemverilog
always @(posedge clk_sys) begin          // one clk_sys: the mappers' decode ends here
	t_rd_q <= t_rd; t_wr_q <= t_wr; t_addr_q <= t_addr; t_wdata_q <= t_wdata;
end
wire [17:0] t_key = {t_wr_q, t_addr_q};
wire t_new = (t_rd_q | t_wr_q) & (~t_last_v | t_key != t_last);  // compare: registers only
wire m_new = (c_rd & ~c_rd_q) | (c_wr & ~c_wr_q);                // 7800: rising strobe only
wire c_new = m_new | t_new;
// t_last/t_last_v: loaded on t_new, cleared while the registered strobe is low
wire [16:0] cq_word = m_new ? c_word : (t_new ? {1'b0, t_addr_q[16:1]} : cp_word);
// cq_we, cq_lane, cq_data alike; cq_v = c_new | cp_v; cp loads cq_* when not taken
```

`t_last_v` replaces the `7FFFF` sentinel, which the `bios` bit made safe before. Without that bit, `7FFFF` is a real 2600 key. The 7800 strobe selects last, so its cone sees one mux there.

##### `atari7800_pocket.sv`

Three new wires go from the `main` instance's `POCKET_SRAM` block (`:960-981`) to `t_*`. `.clk_sys` goes to `sram` (`:1082`). `c_rd = cartram_rd | bios_rd` and the `c_addr` BIOS mux (`:1090-1093`) stay.

##### What leaves the `clk_sdram` cone

The 2.1.1-era worst path [sta] ran through the 2600 mappers: `last_address` → `mapper_3E` `Equal0` → `mapper_AR` `ram_rw` → `cart2600` `Mux18` ×2 → `top.sv` `cartram_wr` ×2 → `sram` `Equal5` ×2 (fan-out 66) → `cq_word` → `go_word` → `sram_a[6]`. That is 12 levels: AR and 3E sit where DPC+ sat in `SRAM_TIMING.md`'s path. Fix A removed DPC+; this leg stays until Fix B.

| Cone into the pad registers | Before | After Fix B |
|---|---|---|
| 2600 mappers' decode, `a_in`, AR's `ram_rw`, its `we_byte` → `d_out` → `cart_din` loop | in, timed at 17.46 ns | ends at `sram\|t_*_q`, timed at 69.8 ns |
| `top.sv` merge (`tia_en ?` on 28 bits) | 1–2 levels | address/data: none; strobe: an AND that can merge with `& mclk1` |
| Address compare (`c_key`, 19 bits incl. `c_wr`) | 2 levels on the 7800 strobe *and* address (`tia_mode` is a register Quartus can't fold) | off the 7800 path; on the 2600 side it starts at registers |
| 7800 decode → `m_new` → `cq` → `go` → pads | in | in (by design: served at A) |

In the [sta] path, the compare's two levels cost 1.84 ns with routing and the merge's two cells 0.8–1.6 ns. The 7800 leg should gain **1.5–2.5 ns** [E].

**Alternatives rejected:**

- **Through `cp` only** (the 2600 request reaches the arbiter as the pending register). It costs one more `clk_sdram`, which breaks the read budget in the worst case (§2).
- **A timing exception** (`SRAM_TIMING.md`, "Not recommended").

#### 2. Latency, mapper by mapper

##### The deadline

- **Physical.** The 6507 latches read data at E6 (`pclk0`; `mos6502_dp.sv:299`). That is `pclk1`→`pclk0` = 6 `clk_sys` in every run [sim].
- **Under the constraints.** `c_rdata` → `clk_sys` has `-setup 2` (`core_constraints.sdc:43-44`). A byte written at s*k* is only guaranteed by the **second** `clk_sys` edge after s*k*. For the latch at E6 = s24, `c_rdata` must be written **by s19**.
- **Correction to the review.** `SRAM_TIMING_REVIEW.md` §5 compares about 260 ns with the whole 838 ns cycle. The real budget is 262 ns from the strobe at E1 to s19.

##### The timeline

| Step | Today | Fix B | Through `cp` (rejected) |
|---|---|---|---|
| Mapper strobe valid (`cart2600.sv:973-976`: `~phi1 & ~address_change`) | E1 = s4 (E0 if the address repeats) | same | same |
| `sram_ctrl` sees it | s5 | s9 (`t_*_q` loads at E2 = s8) | s9, then s10 |
| Access starts, nothing in flight | s5 | s9 | s10 |
| `c_rdata` written (start + 6: `:194-207`, `:365`) | **s11** | **s15** | s16 |
| Worst: another client's access starts on the edge before, so the cart waits for `free` at start + 5 (cart has top priority, `:331`) | s15 | **s19 = the limit** | s20: past it |
| Repeated address (WSYNC stall, the store after `STA abs,X`'s dummy read) | s7 | s11 | s12 |

[sim], all runs below, Flicker Blend off and on:

| Build | `c_rdata` at (s) | Largest seen | Minimum margin to the latch (s24) |
|---|---|---|---|
| 2.1.2 | 7 / 11 | 14 (blend) | 10 |
| **Fix B** | **11 / 15** | **15** | **9** |
| Through `cp` | 12 / 16 | 16 | 8 |
| Mutant: two `clk_sys` registers | 15 / 19 | 19 | 5 |

- **Flicker Blend never delayed a normal Fix B read** [sim]. Its accesses are phase-locked to the 6507 cycle (both come from the TIA clock), and they land before s9. It delays the repeated-address case (s11 → s14), as it delays today's reads.
- **The worst case comes from the other clients:** the SaveKey bridge (any phase, through a synchroniser) or the SaveKey EEPROM model starting an access at s8. Simulation does not produce it, so the s19 bound rests on the analysis above [C]. Fix B fits with **no** `clk_sdram` to spare under the constraint, and 5 physically.

##### Per mapper

Every 2600 RAM mapper builds its strobe the same way (`cart2600.sv:966-977`). Its address depends only on `a_in` and on bank registers that change at `a_change` (E1). None of these mappers uses a RAM byte inside the cycle that reads it: `cr_do` goes only to `d_out` (`:226`). The ones that did (DPC+, CDF, BUS, the ARM audio) are out under `NO_ARM_MAPPER`, and with DARIA they use block RAM. [sim] found no address or direction change inside a held strobe in any run.

| Mapper | RAM, ports [C] | Address depends on | [sim] Fix B, blend on: reads / writes | Fits |
|---|---|---|---|---|
| Superchip family: F8, F6, F4, FE, E0, 3F, P2, 2K, UA, F0, 32, SB, EF, JANE, DF, 4K (`sc`, `detect2600.sv:227-290`) | 128 B: W `$1000-$107F`, R `$1080-$10FF` (`banks2600.sv:23-25`, same in each) | `a_in` | F8SC 1,855 / 3,943; F4SC 1,855 / 3,943 | yes |
| FA (RAM+) | 256 B: W `$10xx`, R `$11xx` (`:653-655`) | `a_in` | 1,819 / 3,993 | yes |
| CV | 1 KiB: R `$1000-$13FF`, W `$1400-$17FF` (`:695-697`) | `a_in` | 1,819 / 3,993 | yes |
| E7 | 1 KiB in bank 7 + 4 × 256 B at `$18xx`/`$19xx` (`:795-797`) | `bank`, `ram_bank` (hotspots at E1, `:808-816`) | 1,819 / 3,995 (both areas) | yes |
| 3E | 32 × 1 KiB: R `$1000-$13FF`, W `$1400-$17FF` (`:1408-1410`) | `ram_bank`, written while `a_in` = `$3E` (a TIA write cycle, `:1419-1427`) | 1,819 / 3,995 (banks 0 and 5) | yes |
| WD | 64 B: R `$1000-$103F`, W `$1040-$107F` (`:1360-1362`) | `a_in` | 1,918 / 3,898 | yes |
| CTY | 60 B: W `$1004-$103F`, R `$1044-$107F` (`:580-582`) | `a_in` | 1,935 / 3,871 | yes |
| AR (Supercharger) | 6 KiB, 3 banks (`:1012-1014`) | `bank`; a write when `we_cycle[5]` (shifted at E1, `:1266`) | full load 232,458 / 6,144, `ar_test.py check` 0 differ; multiload 1,516,502 / 512, both loads | yes |
| FA2 | own `spram` and NVRAM bridge; `ram_sel` = 0 (`cart2600.sv:1165`) | — | not on this path | n/a |
| DPC+, CDF, BUS | left out (`ram_sel` = 0, `cart2600.sv:633-648`) | — | — | n/a |

- **[sim] per run:** 0 wrong bytes, 0 reads without a fresh access, writes issued = write strobes, and every written byte in the SRAM afterwards. That holds for all 8 images and the Supercharger in all three builds, Flicker Blend off and on (57 runs).
- **The test programs.** Each one writes and reads back with `STA/CMP abs,X` and `(zp),Y`. It runs a routine from cart RAM whose `STA` writes the opcode of its own next instruction, fetched from RAM in the very next cycle.
- **A 7800 RAM cart** (type `0x0004`: write, read back, run from `$4100`) passes in base and Fix B, and fails without RAM.

#### 3. Write data, strobe edges, `mapper_init_busy`, clear, SaveKey and Flicker Blend

- **Write data.**
  - A CPU write's byte is `write_DB` (`top.sv:1112`), and `dor` loads at phase 1 (`mos6502_dp.sv:228`). The Supercharger's byte is `we_byte` through `d_out` (`banks2600.sv:1055`) → `read_DB` → `cart_din`; its `ram_rw` and `we_byte` change at E1.
  - The register samples address, strobe and data on the same edge. So `sram_ctrl` takes the byte that was on the port when the strobe rose, as today. The data never changed inside a strobe [sim].
- **What the mutants show** [sim]:
  - *Data sampled one `clk_sys` before the strobe* fails at once. It fails on the Superchip store after `STA abs,X`'s same-address dummy read (old open-bus byte), and on the Supercharger (5,929 of 6,144 bytes wrong).
  - *Data taken unregistered* (the review's example) passes every test. The port is stable for the whole strobe, so the mistake would only put the AR data loop back into the `clk_sdram` cone. Only the timing check in §5 catches it.
- **Strobe ends.** A write strobe ends at E6 (`access_taken`, `cart2600.sv:255-261`), so the registered copy ends at E7. The access is out by s13 and done by s18. The next request can't come before the next cycle (s57). Writes therefore can't be reordered or dropped, as the review argued. `phi1` re-arms `access_taken`, so a dummy-read write and the store after it are two accesses (writes issued = strobes [sim]).
- **The address compare.**
  - It is now redundant: the registered strobe is low for at least one `clk_sys` between cycles. A mutant with rising-edge detection only passes everything [sim].
  - Keep it: off the 7800 path it costs nothing in the cone, and it guards against a future mapper that moves its address inside a strobe.
- **`mapper_init_busy`.** The split keeps upstream's select. Under `EXTERNAL_CARTRAM` the upstream RAM initialisation can't work through the SRAM anyway: it reads `cartram_word_data`, which is 0 (`top.sv:941`). DARIA must keep it 0 in the Pocket build (cart RAM in block RAM, decision 4). The reset hold on it (`atari7800_pocket.sv:169-171`) is unchanged.
- **Power-up clear, SaveKey, bridge.** They keep their order behind the cart and Flicker Blend (`sram_ctrl.sv:331-353`). Each can put at most one 5-`clk_sdram` access ahead of a cart request, the case §2 budgets. The clear stops at `game_running`. The SaveKey toggles and the bridge are unchanged. A 2600 SaveKey game on a RAM mapper is the one live combination: its rare EEPROM accesses wait behind the cart, as today.
- **Flicker Blend.** Its load is unchanged: at most one cart access per 6507 cycle, as before. Its falling-edge capture (`:237-248`) is untouched.

#### 4. Simulation test plan

**New script `sim/cartram2600_test.py`** (from `sim/work/fixb/make_ramtest.py`; our own code):

- One image per mapper (F8SC, F4SC, FA, CV, E7, 3E, WD, CTY), running the five phases of §2 over every RAM area. E7 and 3E each test two areas.
- It prints the `+bs=` index on stderr.
- `AUDF0` is 1 at start, 16 + (iteration & 7) after each pass, and 2 + 5 × area + phase on a failure. `tb_load +arprobe` already logs it in 2600 mode.

**`tb_load.sv`, a `+cartram` monitor** (from `sim/work/fixb/tb_fixb.sv`). At each `pclk0` where `cart2600` answers from `cr_do`, it checks:

- the byte against the SRAM model;
- that an access completed since E0;
- `c_rdata`'s write edge counted from E0 (a histogram).

It also keeps a write scoreboard: the mapper-side `cartram_wr26` against `sram`'s issued writes, and a shadow compared with the SRAM at the end. It prints `CARTRAM` lines.

**`extra_tests.sh`.** Add a section after the Supercharger block. It needs no download, so it should run before the `dasm`/`7800basic` clones (or behind a flag) and keep working offline.

```sh
echo "-- 2600 cartridge RAM, every RAM mapper (expect pass codes 16-23, 0 wrong, writes = strobes, c_rdata at E0+15, never past E0+19)"
for m in f8sc f4sc fa cv e7 3e wd cty; do
	bs=$(python3 "$HERE/cartram2600_test.py" $m 2>&1 >"$X/cr/$m.bin")
	for bl in "" +blend; do
		"$WORK/obj_load/vtb" +image="$X/cr/$m.bin" +bs=$bs +arprobe +cartram +wav=60 $bl | grep -E "^AR .*AUDF0|^CARTRAM"
	done
done
```

- **Also:** `+cartram` on the existing Supercharger runs (full load, multiload, and `AR_TAPE=1` once with the BIOS), and the 7800 RAM image (`make_a78.py --type 0x0004`) in `run_sim.sh`'s load section.
- **Pass criteria:** no fail code; at least one pass code; `CARTRAM` with 0 wrong, 0 stale, writes = strobes, shadow = SRAM, the histogram's main bucket at 15 (11 for repeated addresses), maximum ≤ 19.
- **Runtime:** about 2 minutes [sim: 60 ms runs take 6–10 s each].
- **Sensitivity [sim]:**

| Mistake | Caught by |
|---|---|
| A second register (normal case moves to 19) | the latency bucket |
| Stale data | functional tests (Superchip and AR) |
| A missing write | the scoreboard |
| Unregistered data or address | §5's timing check only |
| No compare | not caught (harmless today) |

#### 5. Timing measurement plan and cost

**Build A: 2.1.2 + Fix B, seeds 1/2/3,** slow 1100 mV 85 °C, plus fast 0 °C hold.

- **Expected:** `clk_sdram` worst setup ≥ +2.5 ns on each seed, against Fix A's +1.17/+1.76/+2.31 [E]. The seed spread should shrink from 1.1 ns to under about 0.7 ns [E].
- **The new worst path** should be the 7800 cone with no `Equal*` cell and no `cart2600` cell. It may instead be Flicker Blend's half-period paths: `fbn_*` on the falling edge → arbiter → pads, 8.73 ns, with no slack figure on record.

**Structural checks** (they must hold whatever the slack):

1. `report_timing -setup -to_clock <clk_sdram> -through [get_cells -hierarchical *cart2600*]` finds no paths. This is the check for unregistered data or address.
2. From `sram|t_*_q` into `clk_sdram`: setup ≥ +8 ns (≤ 5 levels) and hold ≥ 0 [E]. Flicker Blend's same-edge capture once failed hold by 0.13 ns (`sram_ctrl.sv:237-239`). If this one does, use a fitter-only `-add -hold` uncertainty into `clk_sdram`, like the one into `clk_sys` (`core_constraints.sdc:58`). That is padding, not an exception.
3. Into `sram|t_*_q` (`clk_sys`, 69.8 ns): ≥ +40 ns [E].
4. The fit report's retiming list (retiming is on, `ap_core.qsf:313`) doesn't move `t_*_q` into `cart2600`.

**Build B: the DARIA integration (step 7), seeds 1/2/3.** Accept at **≥ +1.5 ns on every seed** at 80–85% of the device. This is the release gate. The worst hold over all clocks should stay positive (2.1.2: +0.29 ns).

**Cost [E]:**

- **Registers:** +27 (`t_rd_q`, `t_wr_q`, 17 address, 8 data). `t_last` + `t_last_v` (19) replace `c_key_last` (19).
- **Logic:** `top.sv`'s 28 merge muxes become wires and four ANDs (about −26 LUTs). `cq_*` grows from 2 to 3 inputs on 27 bits, still one LUT per bit.
- **Net:** −10 to +20 ALMs, no M10K.

#### 6. Vendored-file rules

| File | Change |
|---|---|
| `mister/rtl/top.sv` | Two `ifdef POCKET_SRAM` blocks: the four `_out` ports in the existing port group, and split/`else` upstream merge/`endif` at `:752`. Without the macro the file is identical to upstream. |
| `mister/rtl/cart2600.sv` | **None.** Its `cartram_*` ports already carry only the 2600 request, and `mapper_init_busy` is already 0 under `NO_ARM_MAPPER` (Fix A). |
| `mister/POCKET_CHANGES.md` | In "Memories in the Pocket's SRAM", the `top.sv` bullet adds the `cartram_*26_out` ports and the split: under `POCKET_SRAM`, `cartram_*` carries the 7800 request alone. It notes that `POCKET_SRAM` needs `EXTERNAL_CARTRAM` (both set at `ap_core.qsf:748-749` and `run_sim.sh:92`); without it, `cart_ram_tdp` would see no 2600 request. The "Updating" checklist already covers re-applying `top.sv`'s blocks. |
| `core/sram_ctrl.sv`, `core/atari7800_pocket.sv`, `core/core_constraints.sdc` | Pocket code. Rewrite the header's 2600 paragraph and the `c_rdata` multicycle comment: a 2600 byte is written by E0+19, and the latch at E0+24 is the second `clk_sys` edge after it. |
| `docs/SRAM_TIMING.md` | Fix B's "For DARIA" bullet (ARM traffic as another registered client) is superseded by decision 4: no ARM traffic reaches the SRAM. |

#### 7. Risks and open questions

1. **No spare against the multicycle.** In the worst case `c_rdata` lands exactly at s19. Any added 2600 latency breaks the constraint's assumption silently, and simulation won't show it, because Flicker Blend is phase-locked. That includes a second register stage, the `cp` arrangement, a longer SRAM access, or a client allowed ahead of the cart. The `+cartram` bucket at 15 and the header's budget are the guards. If more room is ever needed: block background starts at s8 in 2600 mode (a `clk_sys` phase bit), or shorten the access.
2. **Hold at the `clk_sys`→`clk_sdram` coincident edge** (§5, check 2).
3. **The next limit** may be Flicker Blend's half-period paths, not the 7800 cone; nothing on record shows their slack.
4. **The 7800 cone stays** (MARIA needs its request at A). If DARIA's fill pushes that leg under +1.5 ns, Fix B can't help: the next step would be the 7800 mappers' RAM decode.
5. **DARIA's integration must keep `cart2600`'s ARM-scheme `ram_sel` at 0** (as Fix A does) and `mapper_init_busy` at 0. Otherwise their RAM traffic would land in the SRAM through the 2600 port.
6. **Hardware:** as Fix A's list, plus a Superchip game, an E7, a 3E and a CV title, and a Supercharger multiload end to end. `AR_TAPE=1` (BIOS tape path, about 20 simulated seconds) was not run here.
7. **Open:** drop the redundant compare (about 10 ALMs) or keep it as a guard? Recommended: keep it.

Scratch evidence (gitignored): `sim/work/fixb/`, holding `src/` (patched copies, with the mutant switches), `tb_fixb.sv`, `make_ramtest.py`, `make_ram7800.py`, `build.sh`, `run_matrix.sh` and `logs/`.

## Clock

The BupChip and DARIA share one CPU and one clock. CoreTone does not depend on the CPU clock: it paces itself on a 48 kHz tick taken from the Pocket's 74.25 MHz reference (`bup_tick48k.sv`) and on its PCM FIFO, so a faster CPU only idles more.

| `clk_arm` (687.27 MHz VCO ÷ C) | What it gives |
|---|---|
| ÷24, 28.64 MHz (today) | S3 misses Spiders' 16 late calls, as upstream does |
| ÷21, 32.73 MHz | Every measured call on time with S3's CPI [trace]. The baseline until step 3 |
| ÷20, 34.36 MHz | A little margin |
| ÷18, 38.18 MHz | **DARIA's clock** (step 3): S1 with Thumb, late only on Spiders' 16 calls, as upstream |
| ÷17, 40.43 MHz | 20% margin with S3, or every call on time with S1's CPI [trace]. **Dropped** (step 3): it does not close |

- **What fits today.** In the 2.1.1 build ARIA had +8.08 ns of setup slack at 28.64 MHz: a critical path of about 26.8 ns, so a ceiling near 37 MHz. 32.73 and 34.36 MHz fit; 40.43 MHz needs the path shortened first, and the Thumb expander and S3's forwarding each add to it. The first fix is known: decide a one-clock store from the base register's region, not after the adder (`BUPCHIP_CORE.md`, risk 2).
- **What changes with the divider.** The PLL's counter 3; `psram.sv`'s `CLOCK_SPEED` (28.636364 today); and `core_constraints.sdc`, which times `clk_arm` with `clk_sys` as one synchronous group only because it is exactly 2 × `clk_sys`. At any other ratio the crossings are declared asynchronous. The BupChip's crossings are synchronisers, stress-tested asynchronously at 16–29 MHz; they are re-run at the new rate, and DARIA's own crossings are built the same way.
- Step 3's probe measures 32.73 and 40.43 MHz, with the path fix, inside the full build. If 40.43 MHz does not close, S3 at 32.73 MHz does the work S1 would need 40 MHz for. (Step 3 took a third way: S1 at 38.18 MHz, late only where upstream is. See below.)

**The early probe (2026-10-05, during step 2) [probe].** `sim/bupchip/quartus_probe/run_probe.sh` with `WINDOW=1` gives the CPU DARIA's memories at full size: the 16 KB firmware ROM and the 128 KB window (`altsyncram` with `maximum_depth` 8192, so 8K × 1 slices and a 4:1 output mux) behind a registered profile mux, the 32 KB cart RAM with its port B on `clk_sys`, and the asset cache's 4 KB of data read at `d_addr` (180 M10K). `THUMB=1` compiles the step 2 core. One seed each, in an empty device, worst setup slack at slow 85 °C:

| CPU and memories | ALMs (CPU) | 32.73 MHz | 40.43 MHz |
|---|---|---|---|
| ARIA (`MODES` 1), ARIA's memories (16 KB ROM, 16 KB RAM; 32 M10K) | 1,268 | +4.71 ns (Fmax 38.7) | −0.57 ns (39.5) |
| ARIA (`MODES` 1, `CODE_AW` 15), DARIA's memories | 1,375 | +2.75 ns (36.0) | −1.46 ns (38.2) |
| DARIA (`THUMB` 1), DARIA's memories | 1,720 | **+0.03 ns (32.75)** | −3.97 ns (34.8) |

- **The window costs 1–2 ns**: its 4:1 slice mux and the profile mux sit in front of the decode (2.3 ns of the path with their routing), and `rom_addr` fans out to 144 M10K through duplicated drivers.
- **Thumb costs about 2.7 ns more**, not the 0–1.9 ns this design estimated: the levels stay at 20, but the merged decode, the wider operand mux and the busier placement add delay along the whole path.
- **The path** at 32.73 MHz with Thumb: window → slice mux → profile mux → read-index select (4 levels) → MLAB read → bypass → shifter (4) → operand mux → `alu_b` (2) → adder → the region of the sum (the one-clock-store decision) → `done` → `rom_addr` → 144 M10K address registers: 29.1 ns of data delay. The tail from the adder on is `BUPCHIP_CORE.md`'s risk 2.
- **So:** 32.73 MHz closes with no margin, before the full build and before S3; the one-clock-store fix (the store decided from the base register's region, about 2–3.8 ns [E]) becomes required for it, not only for 40.43 MHz. **40.43 MHz is out of reach** without restructuring well beyond that fix (−4 ns with the window and Thumb); it is dropped as a goal unless step 3 finds otherwise. The Thumb core's area, +345 ALMs over ARIA with the same memories, is inside the 300–500 estimate.

**Step 3 (2026-10-05) [probe]** ("Step 3 work"). The changes:
- the store decision and the BL suffix's target each on an adder of its own;
- the window built as four RAMs.

| Build | Result |
|---|---|
| S1 + Thumb in the full build | 32.73 MHz with +2.20 to +3.07 ns on three seeds; 38.18 MHz (÷18) with +0.29 to +1.31 ns, and the fallback ÷19 |
| 40.43 MHz | Misses by 0.47 ns |

- **The clock: ÷18 with S1.** It is late only on Spiders' 16 calls, as upstream is.
- **`psram.sv`'s `CLOCK_SPEED` at 38.18 MHz** is open item 10.

## Budget

**ALMs [E]**, added to 2.1.2's 12,899 (70%):

| Part | ALMs | Source |
|---|---|---|
| Processor modes | about 25 | [probe] (step 0) |
| Thumb | 305–500 | "The CPU: Thumb", area |
| S3 over S1, if chosen | 150–560 | `BUPCHIP_CORE.md` |
| Memory system, call port, MMIO and timer, capture, cache, crossings | 390–620 | "The memory system", 8 |
| Front end (DPC+, the CDF family) | 850–1,100 | "The front end", size |
| Fix B | −10 to +20 | "Fix B", 5 |
| **Total** | **1,710–2,825** (1,560–2,265 with S1) | |

So the single bitstream lands at about 14,600–15,700 ALMs, 79–85% of the device (78–82% with S1). Area decides the CPU: step 3's probe measures the Thumb decoder and S3 before anything is integrated, and S1 with Thumb is the fallback.

**Measured at step 3 [probe].** The full-build probe has DARIA's CPU (S1 + Thumb), the window, the firmware ROM, the 32 KB cart RAM and the front-end ROM.

| | ALMs | M10K | Share of the device |
|---|---|---|---|
| The core as it is, the same seed | 12,968 | 78 | 70.2% |
| The probe at ÷21, three seeds | 13,604–13,617 | 254 | 73.6–73.7% |
| The probe at ÷18, three seeds | 13,684–13,712 | 254 | 74.0–74.2% |
| Projected, S1 at ÷18 | 14,872–15,382 | | 80.5–83.2% |

- **The probe's CPU** is 1,729–1,748 ALMs at ÷21, +421–440 over ARIA's 1,308 and inside the Thumb line above. At ÷18 it is 1,866–1,877, as the fitter spends area for the faster clock.
- **The projection** adds what the probe leaves out (the "Step 3 work" decisions). Without S3, even its top end, 83.2%, stays under `BUPCHIP_CORE.md`'s 84% gate.
- **M10K:** 254, plus the 4 left out, is the 258 budgeted.

**M10K:** 195 of 308 with the 64 KB window of decision 8 (258 as designed with 128 KB), "The memory system", 1.5. The 2600-only fallback bitstream would take 217.

- **Against upstream.** The Mappy-specific CPU work, FIQ mode with its banked registers, turned out the cheapest item: the register file already had the room. Since 2.1.2 the ARM schemes' front ends are out of the build (Fix A), so the lean ones are an addition to the shipped core. Against bringing upstream's back live (about 3,000 ALMs with glue and controller), the lean front end and call port save 1,700–2,000. They use block RAM, not the SRAM, so they stay off the `clk_sdram` path that Fix A cleared.
- **Images above 128 KB do not fit in block RAM alone:** 256 KB would need 352 M10K of 308, 512 KB 608. The window holds the start of the image: the 6507 banks (in the first 32 KB, by each scheme's layout), the driver, the code (it ends below 0xB30A, about 45 KB, in every demo) and as many tables as fit. The rest of the data comes through the asset cache from the PSRAM. In the traces, every data read outside the code span through a 4 KB cache cost a median 2% more clock; with the 128 KB window no demo touches the cache at all.
- **Testing it without a large game:** build DARIA with a small window (16–32 KB), so that Turbo, Zaxxon and Elevator Agent run through the cache on their real traffic, and check them against upstream as for any other build; then a synthetic 512 KB image whose code reads tables across the whole range.
- **If the area or the fetch path is tight:** S1 with Thumb; a 64 KB window (64 fewer M10K, a 2:1 slice mux instead of 4:1, the code still inside); and last, the 2600-only bitstream (K1).

## Verification

| Layer | What | Step |
|---|---|---|
| CPU, Thumb | Directed tests per format, halt tests, random streams (400 seeds), the exhaustive 65,536-halfword decode check, fuzz and mutations, all in lockstep with the reference ("The CPU: Thumb", verification). The record gains T, and C is skipped only while the core reports it unknown. | 2 (done) |
| CPU, modes | `daria/modes/run_modes.sh` | 0 (done) |
| CPU, ARIA unchanged | `s1/check.sh` with Rikki & Vikki, with `THUMB` 0 and with `THUMB` 1 + `arm_only`; the four songs bit-identical to MiSTer; `thumb/aria_equiv.sh`, the formal proof that `THUMB` 0 is ARIA | 2 (done) |
| Memory system and calls | `tb_daria` runs every demo and added image on DARIA beside upstream: registers at each return, every RAM write, the audio values. Again with a 16–32 KB window, so the asset cache serves real traffic; then a synthetic 512 KB image. | 5 |
| Capture | 2600 images through the loader into the window, the front-end ROM and the PSRAM, each compared with the file; A78 files as today | 5 |
| Front end | A cycle-by-cycle shadow of upstream's front ends in `tb_daria`, directed tests per scheme, the random differential bench | 6 |
| Fix B | `cartram2600_test.py` and the `+cartram` monitor in `extra_tests.sh`; the structural check that no `clk_sdram` path runs through `cart2600` | 7 |
| Integration | `run_sim.sh`, `extra_tests.sh`, `s4/check.sh`; the demos' frames against upstream in whole-core simulation | 7 |
| Timing | Step 3's probe with the RAMs at full size, at 32.73 and 40.43 MHz; the release gate, `clk_sdram` ≥ +1.5 ns on three seeds | 3, 7 |
| Hardware | A status overlay; the 15 demos, the six added images (Draconian uses the timer), RAM-mapper games, the Supercharger, 7800 games and the BupChip | 8 |

## Steps

Each step has a done-when, as ARIA's had.

0. **Scope.** *Done:* this document's requirements, checked against the traces; `MODES` 1.
1. **Design.** *Done:* "Design (step 1)", "Budget" and "Verification"; every open item is decided or given to a step ("Open items").
2. **Thumb in simulation**, on the S1 core: the decoder, the T bit, `BX` both ways, halt code 8. *Done* (2026-10-05): "Step 2 work". *Done when* the conditions in "The CPU: Thumb" hold: every directed and halt test passes, the exhaustive decode check shows 0 differences, 400 random streams and fuzz seeds 1–48 pass in lockstep (also with `LATE_RF=1` and with waits and throttle), every mutation is caught, ARIA's checks pass with `THUMB` 0 and 1, and the four songs are bit-identical.
3. **Probe build:** DARIA alone in an empty device and inside the full build, with the window, firmware ROM and cart RAM at full size. *Done* (2026-10-05): "Step 3 work". The choices: S1 with Thumb, ÷18 (38.18 MHz), and the 128 KB window as four RAMs. *Done when* ALMs and Fmax are measured at 32.73 and 40.43 MHz, the window size is confirmed (128 or 64 KB), and S3 or S1 with Thumb is chosen.
4. **S3** (ARIA's steps 6–7). *Not built* (step 3): S1 with Thumb at 38.18 MHz matches upstream's call timing, so S3 is left for a later revision (open item 3). *Its done-when, if it is ever built:* CPI within ±2% of the model on the demos' traces and the BupChip.
5. **2600 memory system.** *Done* (2026-10-07): "Step 5 work". All 21 images match upstream call by call, late only on Spiders' 16 calls as upstream is; the cache serves Turbo, Zaxxon and Elevator Agent through 32–64 KB windows; the window is 64 KB (decision 8). The step covers image capture into the window, the front-end ROM and the PSRAM; the asset cache for the image beyond the window; 32 KB of cart RAM; MMIO and timer; the return sentinel; the call port. *Done when* `tb_daria` runs every demo and added image on DARIA and matches upstream's ARM call by call (registers at return, every RAM write, the audio values), with no lateness beyond the model's; and again with a small window, so the cache serves Turbo, Zaxxon and Elevator Agent.
6. **Front ends:** the lean front end for DPC+ and CDF/CDFJ/CDFJ+. *In progress* (2026-10-07): the specs of upstream's front ends, the micro-architecture and stage 0 of the shadow are done (`docs/daria_fe/`, "Step 6 work"). *Done when* it matches upstream's front ends as a cycle-by-cycle shadow in `tb_daria` on every demo and added image, and passes directed tests per scheme and the random differential bench.
7. **Integration** (`POCKET_DARIA`) **and Fix B**. *Done when* `run_sim.sh`, `extra_tests.sh` and `s4/check.sh` pass, the RAM mappers pass with Fix B's added latency, the 15 demos render the same frames as upstream in whole-core simulation, and `clk_sdram` has at least +1.5 ns on three seeds.
8. **Hardware test builds** with a DARIA status overlay (calls, late calls, halts, fault code). *Done when* all 15 demos and the six added images play, Spiders aside if it overruns as on upstream, and 7800 games, 2600 RAM-mapper games, the Supercharger and the BupChip are unaffected.
9. **2.2.1.**

## Open items

What step 1 leaves open, each with the step that settles it:

| # | Item | Settled in |
|---|---|---|
| 1 | **The fetch path:** the window's 4:1 slice mux and the profile mux on `rom_q`, and the fetch and data addresses fanning out to 144–180 M10K. The early probe ("Clock") measured it at 1–2 ns, and Thumb at about 2.7 ns more. | **Settled (step 3):** three changes cut the path. The store decision (item 2) and the BL suffix's target each get an adder of their own, and the window is built as four 8K-deep RAMs with a registered 4:1 mux, so no read-enable decode sits on `rom_addr`. With them, DARIA (S1 + Thumb, the 128 KB window) closes ÷18, 38.18 MHz, in the full build with +0.29 to +1.31 ns on three seeds ("Step 3 work"). Levers still unused: duplicating the last address stage (60–120 ALMs), a 64 KB window |
| 2 | **The one-clock-store fix** (`BUPCHIP_CORE.md`, risk 2) is now needed for 32.73 MHz itself: the worst path ends in the store decision taken from the adder's sum. **40.43 MHz** (−3.97 ns in the early probe) is out of reach without more than that fix. | **Done (step 3):** the store is decided on its own adder, exactly, for about 50 ALMs. 40.43 MHz is dropped. It missed by 2.31 ns in an empty device and by 1.18 ns in the full build. With the two further levers of item 1 it still misses by 0.47 ns, on S1's execute path |
| 3 | **S3 or S1 with Thumb**, by area. | **Accepted by the owner (2026-10-05), decision 7. Step 3 chose S1 with Thumb at ÷18 (38.18 MHz).** Its only late calls are Spiders' 16 at the start of play, the same ones upstream misses, which step 8 already accepts. S3 at 32.73 MHz would end those too, but it costs a new pipeline and 150–560 ALMs. It stays a later revision ("Step 3 work", decisions) |
| 4 | **Masking C in lockstep** while the core reports it unknown after a Thumb MUL: a narrow exception to "nothing is masked", bounded by halt code 8. The alternative, a model of the reference's multiplier carry, is not recommended. | **Accepted by the owner (2026-10-05):** no traced image reads C after a MUL, so DARIA leaves the carry out; revisit in a later revision if a game ever halts with code 8 |
| 5 | **Code or LDM above the window** (64 KB, decision 8) halts (codes 4 and 7). Revisit if a large CDFJ+ game needs it: a fetch stall in front of `rom_q`. | When such a game appears |
| 6 | **The cache's size, line and replacement** (4 KB, 16 B, FIFO) on traffic beyond the window. | **Settled (step 5):** 4 KB in two ways of 2 KB, 16 B lines, FIFO. Through the whole wrapper with 32, 48 and 64 KB windows, every call of Elevator Agent, Turbo and Zaxxon matches upstream and none is late. Turbo, the one image larger than 64 KB, has 150 demand misses in 1,500 frames at 64 KB. With `WAYS` 2 the BupChip's song 13 has 1,269 demand misses, against 8,297 with one way ("Step 5 work") |
| 7 | **Cart RAM collisions** across the two clocks during calls (audio reads against CPU writes): count them. | **Counted (step 5); guarded (step 6):** within one `clk_sys` of a write to the same word, upstream's ARM gives 167 and DARIA 163 in 402 M console-side reads over the 21 images; ten images have none. Intel's handbook (CV-52002, 2023.10.18, pp. 2-3, 2-5, 2-13) leaves a read on one clock of a word written on the other clock at the same time unknown, and two writes to one word unknown. The owner asked for a guard if it is cheap and keeps the core in step. **It is in the front end, and the CPU is unchanged:** a phase detector on `clk_sys` finds the shared edge, and while DARIA's CPU may touch cart RAM the front end writes none, and issues every read it uses on the edge 17.46 ns after the last `clk_arm` edge (`docs/daria_fe/design.md`, 3.5 and 8) |
| 8 | **CoreTone after a 2600 ARM game:** the cart RAM is zeroed on every load; check that a Souper game then starts as from power-up. | **Settled (step 5):** with all 32 KB of cart RAM filled with random words before the downloads (`tb_s4 +ramjunk`), song 13 is PCM-identical and its busy clocks equal the clean run's. CoreTone does not depend on what the RAM holds at boot |
| 9 | **The SDC form** for the held buses that cross (`set_max_delay` on related clocks) in Quartus Lite 21.1. | **Settled (step 3):** 7.3's form works. Quartus Lite 21.1 applies `set_max_delay` / `set_min_delay` between clocks of one synchronous group (complete, not overridden), and every crossing path is timed against 20 ns, with at worst +15.1 ns of setup slack. Keep 7.3's `set_min_delay` −20. The first builds used 0, and with it the $8007 byte's held bus missed hold by 0.033 ns at fast 0 °C on one seed. A hold check means nothing on a bus that is held for two clocks before use. Step 7 copies the probe's lines |
| 10 | **PSRAM at 40.43 MHz** with `CLOCK_SPEED` 50.0. Since step 3: `psram.sv` at 38.18 MHz, between the 32.73 MHz where 28.636364 is known to work and the 40.43 MHz that needs 50.0 (7.4). It serves the BupChip's assets and the cache beyond the window. | **Settled in simulation (step 5):** `psram.sv` with `CLOCK_SPEED` 50.0 at 38.18 MHz meets the PSRAM model's timing (0 violations) for the BupChip's song 13 through the DARIA wrapper and for the cache beyond the window in every small-window run. Step 8 checks hardware |
| 11 | **The `BUP_DEBUG` overlay** samples `clk_arm` bits raw; it needs a snapshot with a toggle once the clocks are no longer 2:1. | Step 7 |
| 12 | **Fix B's margins:** no spare against the `c_rdata` multicycle in the worst case (E0+19), hold at the coincident `clk_sys`/`clk_sdram` edge, and Flicker Blend's half-period paths as the possible next limit ("Fix B", 7). | Step 7 |
| 13 | **Banked registers after a mapper reset:** DARIA clears them, upstream keeps them. No driver reads them first. | Accepted |
| 14 | **Thumb hi-register forms with H1 = H2 = 0** halt; running them is free if a game needs it. | When needed |
| 15 | **AMPLITUDE may lag a tick, and `open_bus` keeps the committed byte** where upstream's changes after the latch: counted, not hidden. | Step 6 |
| 16 | **The added images** (Draconian in two builds, Space Rocks, Robot War, Stay Frosty 2 NTSC and PAL; 2026-10-05): traced: nothing new for the CPU, the call protocol or the memory map ("The added images"). | Done |
| 17 | **Timer readings in step 5's comparison.** Draconian's T1TC reading cannot match upstream's to the count, because the clocks differ ("Precision" in the memory system, 6). Step 5 compares it within a bound (about 200 counts), and then compares what the game does with it. | **Settled (step 5):** Draconian is the only image that reads T1TC: once, at power-on, in both builds. DARIA's reading is 37 counts above upstream's, inside the 200 bound and about 1% of the game's 3,872-count margin. Every call after it matches upstream's |
| 18 | **The code space per profile.** With `CODE_AW` 15, the BupChip profile's code space must still end at 16 KB, as ARIA's does. FETCH applies past 0x3FFC and to jumps above it, and DATA to ROM reads above 16 KB. Step 3's probe left it at 128 KB in both profiles. Step 5 adds the profile to those checks. They run a clock late or in W, off the critical path. | **Done (step 5):** the call suite's BupChip-profile tests on the `CODE_AW` 15 core halt a jump to 0x4000, the fall-through past 0x3FFC and a ROM read at 0x4000, and the return sentinel stays a fetch fault there (`call/run_call.py`, `bup_*`) |
