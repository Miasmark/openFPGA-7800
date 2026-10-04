# Review: `SRAM_TIMING.md`

A review of [SRAM_TIMING.md](SRAM_TIMING.md) (the `clk_sdram` SRAM request
path and Fixes A and B), checked against the 2.1.1 sources. Line numbers are
from that tree.

## Verdict

The note is sound, and its order is right:

1. ship 2.1.1 on seed 2;
2. Fix A in the next 2.1.x;
3. Fix B before DARIA's 2600 mapper work;
4. check the seed on every change until then.

**What checks out:**

- **The path.** It is as described: the bus state, the mapper RAM decode,
  `top.sv`'s 2600/7800 merge (`:752-757`), then `sram_ctrl`'s address-change
  compare and arbiter, ending at the pad registers. All of it is inside one
  17.46 ns `clk_sdram` period.
- **The 2600 slack is real.**
  - The 2600 mappers' `phi1` is `pclk1`, a one-clock phase-1 enable, not a
    half-cycle level (`top.sv`, the `cart2600` instance).
  - So `cartram_rd` / `cartram_wr` (`cart2600.sv`, end of file) are held for
    the whole 6507 cycle. They drop only for the `phi1` clock and the clock
    where the address changes, and the write also drops after phase 2
    (`access_taken`).
  - Quartus can't see this, because the 2600 and 7800 requests share wires
    from the merge on.
- **The seed variation.** The explanation fits the figures: clock skew from
  where the launching register lands.
- **The power-up finding.** Power-up high on a fast output register is done
  by inverting it inside the I/O cell, and that explains the +0.05–0.11 ns
  builds. A good catch.
- **The case against timing exceptions.** They would name cells by
  hierarchy, and stop applying silently when upstream renames them.

## Additions

### 1. Fix A does not touch Pitfall II or FA2

"DPC" is the obvious worry with Fix A, so the note should say this.

- Pitfall II's original DPC is its own scheme, `BANKP2` (`mapper_P2`), not
  `mapper_dpcplus`.
- FA2 (`mapper_fa2`) is separate too.
- Both stay in.

### 2. Fix A also makes `mapper_init_busy` a constant

Only the DPC+, BUS and CDF families start the RAM initialisation
(`init_family`). With them left out it is tied to 0, and `top.sv`'s merge
drops its outer `mapper_init_busy ?` mux. That is one more mux level off the
cone, for nothing.

### 3. 2600 write data is valid when the strobe rises

This matters for Fix B's register, and for `sram_ctrl` as it stands, which
captures the write byte at the strobe's rising edge.

- `cart2600` takes write data from the bus (`cartram_wrdata = d_in`, and
  `top.sv`'s `cart_din = RW ? read_DB : write_DB`).
- `write_DB` is the 6502's output latch. `dor` loads at the phase-1 enable
  (`6502/mos6502_dp.sv`, "phase 1 loads").
- The write strobe rises only after `phi1`.

So the byte is valid from the strobe's first clock, and a registered copy
sees the same byte. The Supercharger is the exception to "write data is the
CPU's latch"; see below.

### 4. The Supercharger: the 2600 RAM case to test

Among the 2600 RAM mappers, the Supercharger (`mapper_AR`,
`banks2600.sv:902`) differs in three ways that matter for Fix B.

**a. It writes its RAM while the CPU reads.** The 6507 has no write line on
the cartridge port, so the Supercharger writes by counting address changes:

- The game reads `$F0xx`. The low byte `xx` becomes the byte to write
  (`we_byte`), and a 5-step shift counter starts (`we_cycle`).
- Every change of address on the bus shifts the counter, including the
  6507's dummy cycles.
- On the fifth change, if the address is in the RAM area and writing is
  enabled (`ram_we`), the mapper writes `we_byte` there
  (`ram_rw` low, `banks2600.sv:1011`).
- That cycle is a read as far as the CPU is concerned. The mapper also
  drives `we_byte` onto the bus as the read result
  (`d_out = ~ram_rw ? we_byte : ...`).

The write is placed only by the count of bus cycles. If it lands in the
wrong cycle, or is lost, nothing reports an error: one byte of the loaded
program is wrong.

**b. Its write data reaches the RAM through the bus.** `cart2600` always
takes RAM write data from the bus (`cartram_wrdata = d_in`). For the
Supercharger that is the mapper's own output looping back:

`we_byte` → `d_out` → `read_DB` → `cart_din` → `cartram_wrdata`

- For every other RAM mapper the data is the CPU's output latch, which is
  set at the start of the cycle.
- Here it is combinational from the mapper's state through the bus mux. It
  is still valid when the strobe rises, because `we_byte` and `we_cycle` are
  registers.
- But it is the longest and least ordinary data path into `sram_ctrl`, and
  the one most likely to catch a mistake in Fix B's register: for example,
  registering the strobe and address but taking the data unregistered.

**c. It writes far more than any other 2600 game.**

- A Supercharger game loads from tape. The real BIOS decodes the tape bits
  (`$1FF9`) and writes every byte of the program into the 6 KiB RAM with
  this trick, so a load is a long, dense run of these writes.
- A multiload game does it again for each part.
- A Superchip game, by comparison, writes a few bytes a frame.

If Fix B's extra `clk_sys` lost or misplaced even an occasional write, a
load would show it: a checksum error, or a game that crashes.

**Checks for Fix B:**

- **Simulation:** a test cart that runs the `$F0xx` sequence, including a
  dummy-cycle variant (an indexed read with no page crossing), and checks
  that the right byte reaches the right RAM address with and without the
  register. `extra_tests.sh` already fetches MiSTer's Supercharger BIOS, so
  with a tape image the test could also run the real loader.
- **Hardware:** load a Supercharger game end to end, ideally a multiload
  title (Dragonstomper, Escape from the Mindmaster). Tape images are
  commercial, so this is likely a hardware test.

### 5. Fix B's added latency fits, and can't reorder a write

- **Latency.** A 2600 read becomes:
  - one `clk_sys` for the register (70 ns);
  - at most one Flicker Blend access ahead of it (87 ns), since cartridge
    requests have top priority;
  - the access itself (6 `clk_sdram`, 105 ns).

  That is about 260 ns, against an 838 ns 6507 cycle.
- **Ordering.** `sram_ctrl` keeps one pending cartridge request, and a newer
  one replaces it. That can't drop a write:
  - a 2600 write strobe ends at phase 2 (`access_taken`);
  - the next read can't start until after the next `phi1`, at least
    6 `clk_sys` (about 420 ns) later;
  - the write is served long before that.

## On the margin itself

+0.438 ns at the slow 85 °C corner is a real pass, not a near-miss.

The concern is that it moves by up to a nanosecond with placement, on a
device at 95% of its LABs. Any change can tip it negative, so step 4,
checking the seed on every change, is the right stopgap.

Fix A should make it much less sensitive:

- it removes the worst leg (the DPC+ decode);
- it frees about 9% of the device, which helps routing too (11.3 ns of the
  17.29 ns path is routing).

## Fix A, implemented

Implemented in `cart2600.sv` under `NO_ARM_MAPPER`, as `SRAM_TIMING.md`
describes, plus `mapper_init_busy` tied to 0 and `arm_mapper_writeback`
left out with the rest. Recorded in `mister/POCKET_CHANGES.md`.

**Quartus, three seeds** (slow 1100 mV 85 °C):

| | 2.1.1 | With Fix A |
|---|---|---|
| `clk_sdram` worst setup, seeds 1 / 2 / 3 | +0.26 / +0.44 / +0.28 ns | **+1.17 / +1.76 / +2.31 ns** |
| ALMs | 79% | 68% (12,630-12,641) |
| Worst hold (any clock) | | +0.29 ns |

**The new worst path** starts at `a78_cart_extent`'s size registers
(`hcart_size`, `cart_size_eof`). It runs through the 7800 mappers' decode to
`sram_ctrl`'s write-data pad register (`dq_out`).

- The DPC+ leg is gone; what's left is the 7800 cone, as the note predicted.
- Its source only changes while a cartridge loads. An exception on it would
  be sound in logic, but carries the hierarchy-name risk the note describes.
  Not worth it at +1.2 ns.

**Simulation:**

- `sim/run_sim.sh` passes: tones, frame geometry, loads, the PLL region
  switch, the audio filter and the virtual axes.
- A 29,696-byte 2600 image (detected as DPC+, mapper 21) now shows the bad
  game screen ("out of order").
- `sim/extra_tests.sh` passes: holey DMA, both POKEY placements, the DLI
  test, the SaveKey (including the 32 KiB save round trip), the HSC and the
  firmware slots.

**Still to do on hardware:**

- 2600 games with RAM mappers (an E7, FA, 3E or SB title, and a Superchip
  game);
- Pitfall II (DPC, which must still work);
- a plain 2600 game;
- a DPC+ cartridge, which should show the screen.
