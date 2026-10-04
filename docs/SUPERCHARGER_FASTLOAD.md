# Supercharger without the BIOS: plan

Status: built (`POCKET_SUPERCHARGER`); hardware test pending. The real-BIOS
path stays, apart from keeping the tape position through a reset.

## Why

Today the core loads a Supercharger game the way the hardware did, from a
simulated tape (`mapper_AR`, `mister/rtl/banks2600.sv`):

1. The mapper turns the `.bin` back into a tape signal, bit by bit, at tape
   speed: a preamble tone, the header, then every page with its checksum.
2. The real BIOS (`supercharger.bin`, the user's file) reads that signal
   through `$1FF9`, decodes the bits, and writes each byte into the 6 KiB
   RAM with the Supercharger's write-by-read trick.

The data starts in memory and ends in memory, and the tape signal in between
exists only to be decoded again. There is no tape on the Pocket. So:

- **Without `supercharger.bin`, Supercharger games don't load at all.**
- **A load takes about as long as the tape did.** A full 6 KiB load is
  8,448 bytes at roughly 0.3 ms a bit, about 20 seconds, and multiload games
  pay that again for every part.
- **Loading is the densest RAM-write traffic any 2600 game makes.** That
  makes it the hardest case for `sram_ctrl` (see `SRAM_TIMING_REVIEW.md`).

Stella has loaded Supercharger games without the BIOS for decades, and its
`CartAR.cxx` and `src/tools/scrom.asm` are the reference for what the BIOS
does.

## What the BIOS does

1. **Loads** a numbered load image from the tape into RAM.
2. **Starts the game.** After a load, the BIOS:
   - clears TIA registers `$04-$2C` and RAM `$81-$9D`;
   - writes the header's control byte to `$FFF8` (bank layout, RAM write
     enable, ROM power), using the write trick;
   - sets A to a random value, X = `$FF`, Y = `$00`, SP = `$FF`;
   - jumps to the header's start address.

   At reset it first clears zero page and loads load number 0.
3. **Multiload.** A game that wants its next part puts the load number in
   `$FA`, switches the ROM back in, and jumps to `$F800`. The BIOS:
   - copies the load number to `$80`;
   - clears page 7 of RAM bank 1;
   - loads that part;
   - starts it as in point 2.

Nothing else. The progress bars and tones are cosmetic, and Stella skips
them as an option.

## Design (as built, `POCKET_SUPERCHARGER`)

### The load image

A `.bin` holds one to four 8,448-byte images: 8,192 bytes of pages, then a
256-byte header. Checked against released games (Dragonstomper's first
load starts at `$F100` with control byte `$0B`):

| Header byte | Meaning |
|---|---|
| 0, 1 | Start address, low and high |
| 2 | Control byte: bank configuration (bits 4:2), RAM write enable (bit 1), ROM power off (bit 0) |
| 3 | Page count (at most 24) |
| 4 | Header checksum: bytes 0-7 sum to `$55` |
| 5 | Load number |
| 6, 7 | Loading-bar speed and colour; `$24`, `$02` in every image seen |
| 16 + j | Page j's place: RAM bank in bits 1:0, page in bits 4:2 |
| 64 + j | Page j's checksum: the page, its place byte and this sum to `$55` |

Page j of the file is at offset `j * 256`.

### Which path

| `supercharger.bin` loaded | Path |
|---|---|
| Yes | The tape path: authentic loading screen and timing |
| No | The fast path, below |

`mapper_AR` decides by itself: a write into its BIOS ROM from the firmware
slot sets `real_bios`, which turns the fast path off until the core is
reloaded.

### The tape keeps its place through a reset

Upstream rewinds the tape to its first image on every reset. Here only a
cartridge load does (`tape_rewind`, from `top.sv`'s `loading`). A real tape
stays where it stopped through a power cycle, and compilation tapes rely
on it: Party Mix and Sweat number every image 0, and the next game is the
next one on the tape. A reset during a load leaves the tape on the image
being played, so it plays again from its start. Both paths share this.

### The stub ROM

`core/ar_stub.asm`: our own 6502 code, MIT, about 300 bytes. Stella's
`scrom.asm` is GPL; it was not used. The stub is `ar_rom`'s power-up
contents (`core/ar_stub.mif`), and a BIOS file overwrites it.

| Entry | What it does |
|---|---|
| Reset vector | Clear TIA and RAM (load number 0 in `$80`), then load |
| `$F800` (multiload) | Copy `$FA` to `$80`, then load |
| Load | Find the image: start at the tape position, take the first whose header load number matches, wrapping at the end of the file. Copy its pages into the RAM. Move the tape position on |
| Start | Clear TIA `$04-$2C` and RAM `$81-$9D`; A from the RIOT timer, X = `$FF`, Y = 0, SP = `$FF`; set the header's control byte and jump to its start address |
| Not found | A red screen |

The control byte can switch the ROM out, so the last two instructions
(`CMP $FFF8` / `JMP start`) run from RAM at `$FA-$FF`, which Stella's own
BIOS replacement also uses. Until then the stub touches only `$80-$9D`,
where it is cleared anyway: a multiload game keeps its state above that.

### Talking to the mapper

The stub reads the image through a port in the ROM's own address space.
The pages it occupies hold no stub code, and it exists only on the fast
path with the ROM mapped at `$F800`:

| Read | Effect |
|---|---|
| `$F9xx` | Image `xx >> 6`; pointer bits 13:8 = `xx & $3F` |
| `$FAxx` | Pointer bits 7:0 = `xx` |
| `$FB00` | The image byte at the pointer; the pointer steps on after it |
| `$FB01` | Bits 5:4 the tape position, bits 1:0 the file's last image |
| `$FC0x` | The tape position becomes `x` |

The mapper fetches the byte at `image * $2100 + pointer` from SDRAM
through the tape player's own ROM port (`rom_a` / `rom_do`, a read every
3.58 MHz `ce`), and holds it for the stub.

### Writing the RAM

The stub writes each byte the way the BIOS does, with the write trick:
`CMP $F000,X` puts the byte in the data hold register, and `CMP (PTR),Y`
makes the target address the fifth access after it. So the RAM sees the
same kind of writes the tape path makes, through the same `cart2600` and
`sram_ctrl` path, and nothing outside `mapper_AR` changes. This replaces
the plan's hardware copier, which would have needed the 6507 held on RDY
and a write-data mux in `cart2600`.

About 20 cycles a byte: a full 6 KiB load takes about 0.1 s, against about
20 s from tape.

Checksums are not checked: a file can't be misread, and some converted
images have them all 0. The tape path now recomputes them
(`fix_sc_cs`, MiSTer's "Fix Supercharger Checksums", on for good), so those
images load there too.

## Cost

- **Logic:** the port, the pointer and its address adder in `mapper_AR`:
  about 260 ALMs (12,899, 70%, against 12,630 for Fix A alone). `clk_sdram`
  worst setup +1.92 ns (seed 2), all corners positive.
- **Memory:** none new. The stub lives in `ar_rom`.
- **Vendored files:** `banks2600.sv`, with the `tape_rewind` port through
  `cart2600.sv` and `top.sv`, in `ifdef` blocks recorded in
  `POCKET_CHANGES.md`.
- **Tools:** the stub is assembled with `dasm` (built by
  `sim/extra_tests.sh`) and `tools/bin2mem.py`. The `.mif` and `.hex` are
  committed, so a core build needs neither.

## Tests

**Simulation** (`sim/extra_tests.sh`, "Supercharger"; images from
`sim/ar_test.py`, each load setting its own background colour and TIA
tone, which `tb_load +arprobe` logs):

| Test | Result |
|---|---|
| No BIOS: a full 24-page load, RAM dumped from the SRAM model and compared | Running about 0.1 s after start; 0 of 6,144 bytes differ |
| No BIOS: multiload, load 0 asks for load 1 after 60 frames | Load 1 running 1 ms after the request |
| No BIOS: two loads both numbered 0, reset after the first | The second loads after the reset |
| With the BIOS (`AR_TAPE=1`): the same full load and multiload from tape | See below |

**Hardware:**

- `ar_multi.bin` and `ar_tape.bin` from `sim/ar_test.py`: red then green;
  blue, then yellow after a reset.
- Games, with and without `supercharger.bin`: Fireball (single load),
  Dragonstomper or Escape from the Mindmaster (multiload), Party Mix (its
  second game after a reset), Excalibur or Meteroid (checksums all 0).

## Open points

- **Image size.** Some `.bin` dumps are 6,144 bytes (pages only) with no
  header. Stella supplies a default header for those (from z26). Neither
  path loads them yet; it would be a fixed 256-byte table in the mapper.
- **What the BIOS leaves in RAM.** The stub uses `$80-$9D` and `$FA-$FF`.
  The real BIOS's own use of zero page is not known exactly; Stella's
  replacement uses the same top bytes, and released games run with it.
