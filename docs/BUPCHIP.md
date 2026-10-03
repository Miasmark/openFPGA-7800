# The BupChip: what it needs

These are the notes for anyone building a BupChip that fits the Pocket. The
Pocket core leaves it out (`NO_BUPCHIP`; see the README). Everything here was
measured on the MiSTer core's own implementation, which is vendored in
`src/fpga/mister/rtl`. The tools that reproduce it are in `sim/bupchip/`.

## How MiSTer does it

The real cartridge's BupChip is a microcontroller with its own flash. MiSTer
replaces it with three parts:

- **A firmware program**, `rtl/bupchip.hex`: 1,956 words (7.8 KB) of ARM
  code that Jamie Blanks wrote, called CoreTone after the original engine. Its
  source is not published.
- **A soft ARM7TDMI**, `rtl/arm7tdmi/arm7tdmi_core.sv`, derived from
  GBA_MiSTer's CPU and shared with the 2600 ARM mappers. It runs at 71.58 MHz
  (`clk_arm`).
- **The game's music resources**, appended to the `.a78` as an ARSC block
  (see below). MiSTer keeps them in DDR3 behind a 16-line cache
  (`bupchip_asset_ddr.sv`).

### ARM memory map (`bupchip_memory.sv`)

| Address | Size | Contents |
|---|---|---|
| `0x00000000` | 16 KiB window | Firmware ROM (7.8 KB used), read-only |
| `0x02000000` | the ARSC block | Music resources, read-only |
| `0x40000000` | 16 KiB | RAM. Static data and BSS end at `0x40002080`; the stack starts at the top. |
| `0xE0009000` | 256 B | BupChip registers (below) |

Any other address aborts. Every access takes at least two clocks
(request, answer), and the asset window adds a cache lookup.

### Registers (`bupchip_peripheral.sv`)

| Offset | Read | Write |
|---|---|---|
| `0x00` | IDENT `0x42555001` ("BUP", revision 1) | — |
| `0x04` | Next command: bit 8 = valid, bits 7:0 = byte. Reading pops it. | — |
| `0x08` | Command FIFO level and flags | — |
| `0x0C` | — | Clear command overflow (bit 0), flush (bit 1) |
| `0x10` | — | Push one stereo frame: `{right, left}`, signed 16-bit |
| `0x14` | PCM status: bit 18 = level below watermark, bit 17 full, bit 16 empty, bits 15:0 level | — |
| `0x18` | — | PCM control: bit 0 enable, bit 1 clear flags, bits 28:16 watermark |
| `0x1C` | — | Fault: mutes the output, bits 7:0 = code |

The PCM FIFO holds 4,096 frames (85 ms, 16 KiB). The hardware pops one frame
every `clk_arm / 48000` clocks. That large FIFO is there to ride out MiSTer's
DDR3 stalls; a design with predictable memory needs far less.

### Commands

The 7800 game writes `$8007` twice per command (`souper.v`). The firmware
splits the byte on bits 7:6:

| Byte | Action |
|---|---|
| `$80`–`$9F` | Play song n (low 5 bits), from the ARSC song table |
| `$00`, `$02`, `$03` | Control commands (firmware 0x79c, 0x788, 0x774). Not traced further. |
| `$40`–`$7F` | Firmware 0x808. Not traced further. |
| `$C0`–`$FF` | Firmware 0x82c, with `(n << 2) | 3`. Not traced further. |

### The firmware's main loop (from 0x88)

1. **Start-up checks.** It checks IDENT and the ARSC tag, then parses the CSMP
   and CINS chunks. On failure it writes fault code 1 (wrong IDENT), 2 (no
   `ARSC` tag) or 3 (bad chunk), and stops.
2. **PCM set-up.** It sets the watermark to 3,896 frames and enables PCM.
3. **Loop forever.**
   - If a command is waiting, it handles it.
   - Otherwise, if the PCM level is below the watermark, it renders 200 frames
     (4.17 ms, a 240 Hz tick) and pushes them.
   - It counts down 60 silent batches after the music stops, then pushes zeros
     without rendering.
   - Otherwise it polls again (0x178–0x18c). The testbench counts every clock
     spent here as idle.

## The ARSC block

`sim/bupchip/make_arsc.py` builds it from a ProSystem/FoxBox install, such as
the Steam release of Rikki & Vikki. That install has these files:

- **`Data/FoxBox.cdf`:** lists, under `CORETONE`, the sample bank, the
  instrument macros and the songs, in command order.
- **`.smp`, `.ins` and `.mus` files:** already the firmware's `CSMP`, `CINS`
  and `CMUS` chunks, byte for byte.

```
+0    "ARSC"
+4    u32  offset of the CSMP chunk   (all offsets from the "ARSC" tag, 4-byte aligned)
+8    u32  offset of the CINS chunk
+12   u32  song offsets [32]          (0 = none; song n is command $80|n)
...   the chunks
```

The block starts straight after the cartridge data: file offset 128 + the
header's declared ROM size. The firmware also knows a `CSFX` tag; Rikki &
Vikki has no sound-effect bank. For Rikki & Vikki the block is 211.8 KiB:

| Chunk | Size |
|---|---|
| CSMP (`RV_Samples.smp`, 30 samples) | 121,119 bytes |
| CINS (`RV_Macros.ins`) | 3,177 bytes |
| CMUS (32 songs) | 92,600 bytes |

Use the Steam `.a78` image with the header patch from the MiSTer forum
(`--bps`), or an already headered `.a78`.

## Measured load

These figures come from `sim/bupchip/run_bupchip.sh`, measuring 4 s of each
song after its start command, on MiSTer's CPU and memory system:

| Song | Busy (average / busiest 0.1 s) | Million instructions/s (average / busiest 0.1 s) | Multiplies per second |
|---|---|---|---|
| 13 Misery_F | **87% / 89%** | **15.7 / 16.0** | 1.32 M |
| 9 Boss_S | 62% / 64% | 11.0 / 11.4 | 0.81 M |
| 10 Boss_C | 54% | 9.9 / 11.7 | 0.68 M |
| 6 Metal | 42% / 46% | — | — |
| 14 Title | 42% | 7.6 / 8.9 | 0.43 M |
| 30 Irregular | 26% / 30% | — | — |

- No song underran the PCM FIFO.
- Title runs at the same load with the asset memory 5× faster (latency 4
  instead of 20 clocks). Only the ROM and RAM speed matter.
- **The core averages 4 clocks per instruction.** It is not the instructions
  that are slow: every instruction fetch and every data access waits through
  the two-clock request/answer handshake.
- **Misery_F leaves MiSTer only about 11% headroom.** Any design has to
  sustain about 16 million instructions per second.

### Which parts of the ARM it uses

**Statically**, the firmware contains:

- **Present:** ARM instructions only, with conditional execution throughout.
  Data processing, including ADC/SBC/RSC and shifts by register. LDR/STR,
  LDRH/STRH/LDRSB/LDRSH, LDM/STM (push/pop and two STM forms), B/BL, and BX to
  ARM addresses.
- **Multiply:** 11 MUL, 11 MLA and 2 UMULL.
- **Mode:** one MRS/MSR pair at reset, which enters SVC mode with IRQ and
  FIQ masked and stays there.
- **Exception vectors:** each one branches to itself.
- **Absent:** Thumb, SWP, coprocessor instructions, SWI, any interrupt or
  abort handler, and any mode change after start-up.
- **Function pointers:** both tables, at `0x1e3c` (copied to RAM), hold only
  word-aligned ARM addresses.

**Measured on Misery_F** (one second, 15.4 million instructions while
working; 960 distinct instruction addresses ran):

| Class | Share |
|---|---|
| Data processing, register operand | 26.0% |
| LDRH / STRH / LDRSB / LDRSH | 25.2% |
| B / BL | 16.8% |
| LDR / STR | 13.6% |
| Data processing, immediate | 9.8% |
| MUL / MLA | 8.3% |
| LDM / STM | 0.2% |
| BX | 0.1% |
| Shift by register | 0.01% |
| UMULL family | 18 in the second |
| SWP, MRS/MSR, coprocessor, SWI, Thumb | 0 |

12.8% of the instructions are conditional.

## What a Pocket BupChip would need

| Need | Requirement |
|---|---|
| Throughput | About 16 MIPS sustained, with margin. With one instruction per clock that is about 25–30 MHz. A CPU that takes 3–5 clocks per instruction would need 50–80 MHz, no better than today. |
| Instruction set | ARMv4 ARM state only, conditional execution, the barrel shifter, halfword and signed loads, LDM/STM. |
| Can drop | Thumb, IRQ/FIQ/abort/SWI entry, SPSRs and banked registers (one mode), SWP, coprocessor. |
| Multiply | MUL/MLA at about 1.3 million a second (8% of instructions), so several clocks each is fine. UMULL is very rare and can be slow. |
| ROM and RAM | 7.8 KB of code and 16 KiB of RAM, answering in one clock for the throughput above, so block RAM or caches. Since 2.0.21 the core uses 46 of 308 M10K blocks, so about 26 for this is easy. |
| Assets | 212 KiB for Rikki & Vikki. Latency barely matters, so PSRAM, SDRAM or SRAM all work. |
| Output | 48 kHz stereo 16-bit. The FIFO can be much smaller than MiSTer's 85 ms. |

For scale, MiSTer's ARM core alone is about 16,200 LUTs. The 2.0.21 Pocket
build uses 12,834 of 18,480 ALMs (69%) and 46 of 308 M10K blocks, so about
5,600 ALMs are free. Routing gets hard well before 100%, so a whole BupChip
(CPU, registers, FIFOs and asset path) should aim for about 3,000-3,500 ALMs.

### Memory options

**Update, 2.0.21:** the core now does what this section proposed. The
cartridge RAM, Flicker Blend frame, SaveKey and BIOS live in the SRAM
(`core/sram_ctrl.sv`): 12,834 of 18,480 ALMs (69%) and 46 of 308 M10K blocks
are used, so 262 blocks are free. The SRAM is full apart from its last 16 KiB
(words 0x1E000-0x1FFFF), so a BupChip's own memories would go in block RAM, and
its assets in the PSRAM. The analysis below is how it was worked out.

The Pocket's memories, with the parts Analogue fitted, as they were before
2.0.21 (the "used by" column is updated). The speed figures are
the parts' asynchronous access times; check the datasheets before designing
to them.

| Memory | Part | Size and width | Speed | Used by this core |
|---|---|---|---|---|
| FPGA block RAM | Cyclone V M10K | 308 blocks, 1 KB each at ×8/×16/×32 | 1 clock | 46 of 308 since 2.0.21 (all 308 before) |
| SRAM (`sram_*`) | AS6C2016-55 | 256 KB (128K × 16) | 55 ns asynchronous | All but the last 16 KiB since 2.0.21 |
| PSRAM (`cram0_*`, `cram1_*`) | AS1C8M16PL-70 | 16 MB (8M × 16) each, address/data multiplexed on the Pocket (`cram*_a[21:16]` plus `dq`) | 70 ns asynchronous; page and synchronous burst modes | No |
| SDRAM (`dram_*`) | — | 64 MB, 16-bit | Fast bursts; each row change and refresh costs several clocks | The cartridge |

**No external memory can feed the CPU directly.** A 25–30 MHz CPU wants a
32-bit word every 33–40 ns:

| Memory | Time per 32-bit word | Equivalent rate |
|---|---|---|
| SRAM | about 110 ns (two 16-bit reads) | about 9 MHz |
| PSRAM, random access | about 140 ns | about 7 MHz |
| PSRAM and SDRAM, bursts | Fast once streaming | — |

The burst modes only help sequential reads, which is what a cache refill does.

**So the firmware and working RAM need block RAM or caches.**

- **Firmware ROM:** 7.8 KB, 8 M10K blocks. The code it executes is smaller
  still: Misery_F ran 960 distinct instruction addresses (3.8 KB), so even a
  4 KB instruction cache would almost never miss.
- **Working RAM:** 16 KiB as MiSTer sizes it, 16 blocks. The static data ends
  at 8.1 KiB, and the stack top is not yet measured. About 40% of the
  executed instructions are loads and stores (6.2 million data accesses a
  second on Misery_F), far too many for 55 ns SRAM without a data cache.
- **PCM buffer:** a few hundred frames, 1–2 blocks. Nothing on the Pocket
  stalls the way MiSTer's DDR3 does.

That is about 26 M10K blocks, or fewer with caches in front of external
memory.

**The block RAM can be freed.** The fitter report (2.0.21 test build) puts
two thirds of the 308 blocks in five memories. An M10K holds 1 KB at byte
width, so every KiB costs a block:

| Memory | Size | M10K blocks | Read by | Candidate home |
|---|---|---|---|---|
| Cartridge RAM (`top.sv` `cart_ram_tdp`, 4 byte lanes) | 128 KiB | 128 | 6502 and MARIA DMA (SuperGame, Souper, XM RAM); upstream's 2600 ARM mappers on port B | SRAM, if MARIA's DMA reads can be met |
| 2600 Flicker Blend frame (`video_mux.sv` `ram0`) | 64 KiB | 64 | Video, one byte per pixel | SDRAM or PSRAM, or a smaller frame (see below) |
| SaveKey EEPROM image (`save_ram_dp sk_ram`) | 32 KiB | 32 | I2C, a few kHz | SRAM, easily |
| BIOS (`bios`) | 16 KiB | 16 | 6502 and MARIA | SRAM or SDRAM |
| "No cartridge" screen (`cart_rom`, `mem0.mif`) | 16 KiB | 16 | 6502 and MARIA | SRAM or SDRAM |

Notes on each:

- **SaveKey.** A real 24LC256 holds 32 KiB, and the save file is the whole
  chip, so the image can't shrink. It is the easiest to move: the I2C bus runs
  at a few kHz. The bridge save and load path has to follow it.
- **Cartridge RAM.** It is sized for the largest cartridges, and the 2600 ARM
  mappers the Pocket build leaves out also use it. 128 KiB fits in the 256 KB
  SRAM, but MARIA can DMA from cartridge RAM. 55 ns plus pin delays is close
  to one 69.8 ns `clk_sys` period, so check the read timing first.
- **Flicker Blend.** It only serves the 2600 Flicker Blend option. It stores
  one byte per TIA pixel: 160 × 312 lines (PAL) is 49,920 bytes, rounded up to
  a 64 KiB address space. Sizing it to the visible 240 or 288 lines (38–46
  blocks) frees 18–26 blocks; moving it to SDRAM or PSRAM frees all 64.

Moving the SaveKey alone (32 blocks) already covers the BupChip's 26. Each of
these moves needs its own hardware test before any BupChip work. Upstream
memories the Pocket can't use (ARM mapper tables, CDF jump table) are smaller
candidates; see DEVELOPING.md, "Resource budget".

**The asset block goes in the PSRAM.** It is 212 KiB, written once while the
cartridge loads, and read through a small cache like
`bupchip_asset_ddr.sv`. Asset latency barely matters (Title ran the same
with 5× faster asset memory), and nothing else uses the chip. The SDRAM would
also work, but its reads would compete with the cartridge.

Suggested layout:

| Memory | Contents |
|---|---|
| Block RAM, freed as above | Firmware ROM (8 KB, or a 4 KB instruction cache), working RAM (16 KiB), PCM buffer |
| SRAM | SaveKey image first; BIOS, "no cartridge" screen or cartridge RAM if more room is needed |
| PSRAM | ARSC asset block, behind a small cache |
| SDRAM | The cartridge, unchanged |

## Reproducing

```sh
sim/bupchip/make_arsc.py "Rikki & Vikki" rv.a78 --bps "Rikki and Vikki.bps" --list
VERILATOR=/path/to/verilator sim/bupchip/run_bupchip.sh rv.a78 13 4   # Misery_F, 4 s
```

`run_bupchip.sh` prints per-window load, then totals and the instruction
class table, and writes the song as a WAV in `sim/work/bupchip/`. It needs
about 90 s of wall time per second of audio. The game files and anything built
from them stay out of the repository.
