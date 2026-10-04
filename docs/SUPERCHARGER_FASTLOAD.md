# Supercharger without the BIOS: plan

Status: plan, not started. The real-BIOS path stays as it is.

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

## Design

### Which path

| `supercharger.bin` loaded | Path |
|---|---|
| Yes | Today's tape path, unchanged: authentic loading screen and timing |
| No | Fast path, below |

The wrapper latches a flag when the firmware slot delivers a full 2 KiB,
the way it does for the High Score Cart firmware. `mapper_AR` takes the flag
as an input.

### The stub ROM

The fast path puts a small 6502 program of our own in the BIOS's 2 KiB
(`ar_rom`, which already exists and is filled from `supercharger.bin` when
there is one). It becomes `ar_rom`'s power-up contents, and a loaded BIOS
file overwrites it. It's our own code, written to the behaviour above, and
MIT. Stella's `scrom.asm` is GPL, so it's a reference, not a source to copy.

| Entry | What it does |
|---|---|
| Reset vector | `SEI`, `CLD`, clear zero page, then load number 0 |
| `$F800` (multiload) | Copy `$FA` to `$80`, clear page 7 of RAM bank 1, then load |
| Load | Read `$F900 + load number` (see "Talking to the mapper"); the CPU is held until the RAM is filled |
| After the load | Read the header's control byte and start address from the mapper; clear `$04-$2C` and `$81-$9D`; set the control byte with the write trick; set A, X, Y, SP; jump to the start |

About 150 bytes. It needs no progress screen. A short one could be added
later, for players who like to see something happen.

### Talking to the mapper

The mapper can't read the 2600's RAM (Stella's emulator can), so the stub
passes values over the bus, the way the Supercharger's write trick does:

- **Load number.** The stub reads `$F9xx` (ROM bank, fast path only), where
  `xx` is the load number. The mapper latches the low byte and starts.
- **Header values.** While the fast path is active, ROM reads of three fixed
  addresses (for example `$FFE0-$FFE2`) return the loaded header's control
  byte and start address instead of ROM.

Both decodes apply only when the fast-path flag is set and ROM bank 3 is
mapped in, so a real BIOS never sees them.

### The mapper's fast loader

A small state machine in `mapper_AR`, beside the tape player:

1. **Find the load image.** The `.bin` holds one or more 8,448-byte images
   (8,192 bytes of pages, then a 256-byte header). Pick the one whose header
   byte 5 (load number) matches. This is the same
   `tape_offset` stride (`$2100`) the tape player uses.
2. **Copy the pages.** For each page `j` below header byte 3 (page count, at
   most 24):
   - the header's page map (byte `16 + j`) gives the RAM bank (bits 1:0)
     and the page (bits 4:2);
   - read the 256 bytes from the image in SDRAM (`rom_a` / `rom_do`, as
     the header reads do today);
   - write them into cartridge RAM.

   Checksums are not checked: the tape path checks them because a tape can
   be misread, and a file can't.
3. **Hold the CPU.** `cart2600` already has an output that stalls the 6507
   (`arm_call_busy`, which drives `top.sv`'s `arm_call_stall` onto RDY). It is
   idle under `NO_ARM_MAPPER` (Fix A), so the fast loader can drive it while
   it copies. The stub's read of `$F9xx` then simply completes after the
   load. No `top.sv` change.
4. **Then** expose the header bytes and drop the stall.

### Writing the RAM

`cart2600` always takes RAM write data from the bus (`cartram_wrdata = d_in`).
During the fast load the bus carries the stub's stalled fetch, not our data.

- **Write data.** One `ifdef` in `cart2600.sv` muxes the AR fast loader's
  data in instead.
- **Strobe and address.** These come from `mapper_AR`'s `ram_sel` /
  `ram_rw` / `ram_a`, driven by the loader during the copy.
- **Write gating** stays the existing gating (`~phi1 & ~address_change &
  ~access_taken`): one write per 6507 cycle (838 ns).

A full 6 KiB load is then about 5 ms instead of about 20 s. `sram_ctrl`
sees ordinary 2600 RAM writes, one per cycle, well inside its budget.

## Cost

- **Logic:** the loader state machine and the two decodes, an estimated
  150-300 ALMs. Tape-path logic is unchanged.
- **Memory:** none new. The stub lives in `ar_rom`.
- **Vendored files:** `banks2600.sv` (`mapper_AR`) and `cart2600.sv` (the
  write-data mux), in `ifdef` blocks, recorded in `POCKET_CHANGES.md`.
- **Tools:** the stub is assembled with `dasm` (already built by
  `sim/extra_tests.sh`). The assembled `.mif` / `.hex` is committed beside
  its source, so a core build doesn't need `dasm`.

## Tests

**Simulation:**

- A synthetic single-load image (header, pages, and a short program that
  plays a known tone, as `tone_test.py` does) loads with no BIOS and plays
  its tone.
- A synthetic multiload image whose load 0 asks for load 1, which plays a
  different tone.
- RAM contents checked against the image's pages.
- The same images with `sim/extra_tests.sh`'s fetched BIOS still take the
  tape path. This is a long run: the tape takes simulated seconds.

**Hardware:**

- A single-load game and a multiload game (Dragonstomper, Escape from the
  Mindmaster), each:
  - without `supercharger.bin` (fast path);
  - with it (tape path, which also confirms that path on hardware for the
    first time).

## Open points

- **Stella's random A value.** Games shouldn't depend on it, but the real
  BIOS leaves one. Use a free-running counter.
- **Load not found.** If a multiload asks for a load number that isn't in
  the file, the stub should do something visible: hold a coloured screen,
  as Stella reports an error.
- **Image size.** Some `.bin` dumps are 6,144 bytes (pages only) with no
  header. Stella supplies a default header for those (from z26). Decide
  whether to do the same; it is a fixed 256-byte table.
