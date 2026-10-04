# Vendored MiSTer Atari7800 sources

`rtl/` is a copy of the `rtl/` directory of the MiSTer Atari7800 core:

- Upstream: https://github.com/MiSTer-unstable-nightlies/Atari7800_MiSTer
- Commit: see `UPSTREAM_COMMIT`
- License: `LICENSE` (MIT, Jamie Blanks). Third-party files keep their own
  notices: `sdram.sv` (GPL-3.0, Sorgelig), `jt51/` (GPL-3.0, Jose Tejada
  "Jotego"), `EEPROM_24LC256.sv` (GreyRogue, from NES_MiSTer, GPL-3.0; the
  file itself has no license line), `video_mixer_plus.sv` (GPL, Alexey
  Melnikov), `arm7tdmi/arm7tdmi_core.sv` (GPL-2.0-only), `souper.v`
  (zlib-style, Osman Celimli), `t65/` (BSD-style). The Pocket build leaves
  out `video_mixer_plus.sv`, `arm7tdmi_core.sv`, `t65/` and `Pokey/`. See
  `../../../THIRD_PARTY_NOTICES.md`.

The upstream wrapper (`Atari7800.sv`, `sys/`) is MiSTer-specific and is not
used. Its Pocket counterpart is `../core/atari7800_pocket.sv`.

## Changes from upstream

Seven upstream files are modified (`top.sv`, `Maria/DMA.sv`,
`EEPROM_24LC256.sv`, and for the firmware switch `cart.sv`, `cart2600.sv`,
`banks2600.sv`), three firmware images are removed, and the POKEY is swapped
for an older one.

### POKEY: upstream's rtl/Pokey, fixed (Watson's VHDL up to 2.0.20)

Since 2.0.21 the Pocket build uses upstream's `rtl/Pokey/` again, with two
changes in `Pokey/pokey_adapter.sv`: the write hold described below (the
cause of the Ballblazer fault), and half the output level. The new mixer's
curve gives about twice the level of Watson's linear sum for the same music,
and the core's mix was set for Watson's; the curve's compression of loud
passages is kept. Confirmed on hardware: Ballblazer plays a full match.

What follows is the history up to 2.0.20.

Upstream commit a36d55b (2026-08-25) replaced Mark Watson's VHDL POKEY with a
new schematic-level one (`rtl/Pokey/`). On Pocket hardware, Ballblazer's
procedurally generated music turns into near-silent taps and pops with the new
POKEY, and its goal siren goes silent. The 2022 Pocket core, which used
Watson's POKEY, plays it correctly on the same hardware.

Releases up to 2.0.20 therefore used Watson's POKEY: `rtl/PokeyWatson/`, from
upstream b48eac0 (the last commit with it), with its top entity renamed
`pokey` -> `pokey_watson` so it cannot collide with the new POKEY's module
name. `../core/pokey_adapter_watson.sv` provides the `pokey_adapter` module
that `cart.sv` instantiates, wired the way b48eac0 wired Watson's POKEY.
`cart.sv` itself is unchanged. (2.0.21 and later build `rtl/Pokey/` instead.)

At the time the exact fault in the new POKEY was not identified (it is below). Its pure tones match
the documented behaviour at all 256 frequencies, and rewriting its registers
every frame does not disturb them (`sim/tb_pokey.sv`).

Watson's files carry his own terms: free for non-commercial use, commercial
use needs his permission.

### `rtl/Maria/DMA.sv`: holey DMA restored

Upstream commit 0dc8ad2 (2026-09-11) replaced MARIA's sticky "holey" flag
with a per-cycle flag fed into the DMA PLA. After that change, graphics that
fall inside a hole are drawn, so sprites crossing zone boundaries show stray
rows above and below them (Midnight Mutants, Commando, 7800basic's
multisprite sample). The Pocket copy restores the previous behaviour (upstream
8c96e1f): a hole ends the object and suppresses its bytes until the next
display list entry. `sim/extra_tests.sh` renders the multisprite sample, and
each sprite then matches its source graphic row for row. The rest of that
commit is kept.

### `rtl/EEPROM_24LC256.sv`: a NACK ends a read (`EEPROM_NACK_ENDS_READ`)

In a sequential read the model fetches the next byte whatever the master
answers, and drives its first bit on the next SCL fall. A real 24LC256 goes
idle on a NACK. When that stray bit is 0, the model holds SDA low, so the
master's STOP and the next START are lost and every later transfer is
misread. Triple Punch reads 3 bytes and NACKs; with a SaveKey file of zeros
this broke every read after the first, and the game showed "Save ER". The
fix is behind `EEPROM_NACK_ENDS_READ`: after a NACK the model releases SDA
and waits for STOP or START. `sim/tb_load.sv +i2ctrace` decodes the bus.

### `rtl/top.sv`: build switches

Four build switches were added next to upstream's own `NO_ARM_MAPPER`:

| Macro        | Effect |
|--------------|--------|
| `NO_DDRAM`   | Leaves out the DDR3 bridge (`ddram`). Both of its client channels read back idle. The Pocket has no DDR3. |
| `NO_BUPCHIP` | Leaves out the BupChip player (`bupchip_subsystem`): an ARM program with DDR-resident assets. Souper carts still run; their music channel is silent unless `POCKET_BUPCHIP` brings in the Pocket's own player. |
| `POCKET_BUPCHIP` | With `NO_BUPCHIP`: `top.sv` hands the BupChip's inputs out and takes its audio back, so that the Pocket's own BupChip (`../core/bupchip/`, ARIA; `../../../docs/BUPCHIP_CORE.md`) can play the music outside it. New ports `bup_cmd_valid_o` / `bup_cmd_data_o` (the `$8007` command, `bup_cmd_*_eff`), `souper_profile_o` (`souper_profile`), and `bup_audio_l_i` / `bup_audio_r_i`, which drive `bupchip_audio_l/r` in place of the zeros, so the audio goes through upstream's gain, saturation and mix unchanged. Both blocks are `ifdef`s: a port group next to `POCKET_SRAM`'s, and the assignments inside the `NO_BUPCHIP` branch. |
| `EXTERNAL_FIRMWARE` | Builds the HSC and Supercharger firmware ROMs empty, with a load port (see below). |

The Pocket build defines all five (`NO_ARM_MAPPER`, `NO_DDRAM`,
`NO_BUPCHIP`, `POCKET_BUPCHIP`, `EXTERNAL_FIRMWARE`) in `../ap_core.qsf`.
Without the macros the changed files are identical to upstream in behaviour.

### Firmware loaded at run time (`EXTERNAL_FIRMWARE`)

Upstream builds two pieces of original firmware into the core: the High
Score Cartridge ROM (`rtl/mem4.hex`/`.mif`, used in `cart.sv`) and the
Starpath Supercharger BIOS (`rtl/ar.hex`/`.mif`, used in `banks2600.sv`). No
license is given for either, so this copy leaves both files out. They were
also removed from this branch's git history (see the README, "History
rewrite").

The BupChip's CoreTone firmware (`rtl/bupchip.hex`/`.mif`, used by
`bupchip_memory.sv`) is left out for the same reason: its source is not
published. The Pocket build leaves upstream's BupChip out (`NO_BUPCHIP`), so
nothing reads it; the Pocket's own BupChip (`POCKET_BUPCHIP`) loads the
firmware at core start from the user's `bupchip.bin`, through data slot
`0x109` (`../../../docs/BUPCHIP_CORE.md`, "Firmware load"). Simulation scripts
read a local copy at `rtl/bupchip.hex`, which `.gitignore` keeps out of git.
The files were removed by a commit after 2.0.21; unlike `mem4` and `ar`, they
were not removed from the history, which would have rewritten `main` and
the release tags.

With `EXTERNAL_FIRMWARE` defined, those two ROMs are built empty and gain a
write port (`fw_*` ports through `top.sv` -> `cart.sv`, and `top.sv` ->
`cart2600.sv` -> `mapper_AR` in `banks2600.sv`). The Pocket wrapper fills
them from the user's `highscor.rom` / `hsc.a78` and `supercharger.bin` data slots while
the core is held in reset, and keeps the HSC disabled until a full 4 KiB
image has arrived. `sim/extra_tests.sh` loads both through the slots and
checks the ROM contents byte for byte.

Upstream 0dc8ad2 also moved PAL timing into the PLL (MiSTer retunes it to
14.18758 MHz). The Pocket does the same with its own PLL
(`../core/pll/pll_core.v`, `../core/pll_region.v`), from its 74.25 MHz
reference. One difference: the TIA's 2600 region detection is cleared by
the core reset that a retune causes, which as upstream's wrapper is written
could send a PAL 2600 game back to NTSC and into another retune.
`../core/atari7800_pocket.sv` latches the detected region until the next
cart load instead.

`TIA.sv`, `video_stabilize`: the stabilised 2600 window ends 1 line before
the frame's end instead of 4. Upstream's 4 gives a standard 262-line frame
239 visible lines (285 for a 312-line PAL frame), one (three) short of the
window, and the Pocket's scaler kept whatever an earlier game left in the
missing rows: a flickering line at the bottom of every 2600 game after one
that did fill it (Kaboom!). The extra line is in the game's own vertical
blank, so it is black.

`Pokey/pokey_adapter.sv` (upstream's new POKEY, not built by default; see
above): the adapter now captures the CPU's write - address, data and write
enable - at the phase 2 strobe and holds it for the rest of phase 2.
`pokey_bus.sv` samples the write row across the whole o2 half and keeps the
last value, so it needs the address held until the next phase 1, as the
real bus holds it. In this core MARIA's DMA address can be on the bus in the
very clk that ends a write's o2 half, when DMA starts right after the write,
and the write then lands on the register MARIA's address names. Found with
`sim/run_pokey_shadow.sh` (upstream's POKEY run as a shadow of Watson's in
the whole core) on Ballblazer: its `$BBA8 STA $4007`, followed by DMA
reading `$2772`, arrived as a write to register 2. 7 of the 2,404 writes in
its first 10 s went to a wrong register (always 2), none after the fix. The
wrong writes leave channels un-silenced or retuned, and over a match they
add up to the near-silence heard on hardware. Confirmed on Pocket hardware (a
full Ballblazer match); worth reporting upstream.

### Memories in the Pocket's SRAM (`POCKET_SRAM`, `EXTERNAL_CARTRAM`, `NO_MEM_EDITOR`)

On since 2.0.21 (confirmed on hardware with a test build).
`../core/sram_ctrl.sv` puts four memories in the Pocket's SRAM (AS6C2016-55)
instead of block RAM: the cartridge RAM (128 KiB), the 2600 Flicker Blend
frame (64 KiB), the SaveKey image (32 KiB) and the BIOS (16 KiB). The
"no cartridge" screen (16 KiB) is left out, since the Pocket's cartridge slot
is required. That frees 256 M10K blocks.

- `EXTERNAL_CARTRAM` is upstream's own switch: `top.sv` takes the cartridge
  RAM from its `cartram_*` ports instead of `cart_ram_tdp`.
- `rtl/top.sv` (`POCKET_SRAM`): new outputs `mclk1_out` (MARIA's 7.16 MHz
  strobe, the SRAM's slot reference), `bios_sel_out` (a cartridge-space read
  is the BIOS), and the Flicker Blend port, passed through from `video_mux`.
- `rtl/video_mux.sv` (`POCKET_SRAM`): the frame's `spram` becomes the port
  `fb_addr` / `fb_we` / `fb_wdata` / `fb_q`, plus `fb_active`. `sram_ctrl`
  answers like the `spram` did, prefetching the next pixel.
- `rtl/bram.v` (`NO_MEM_EDITOR`): `spram` stops asking for the In-System
  Memory Content Editor (`ENABLE_RUNTIME_MOD`). Every editable memory cost a
  JTAG port and the editor a hub: about 350 ALMs of hub, plus 40-60 ALMs per
  memory.

### `rtl/cart2600.sv`: ARM front ends out with the ARM (`NO_ARM_MAPPER`)

Upstream's `NO_ARM_MAPPER` leaves out the ARM (`arm_mapper_subsystem`), but
not the 6507-side front ends of the ARM schemes, which can't run a game
without it. Under the same macro this copy also leaves out `mapper_dpcplus`,
`mapper_cdf`, `mapper_bus`, `arm_mapper_tables`, `arm_mapper_ram_init`,
`arm_mapper_writeback`, `arm_mapper_audio` and `cdf_fastjump_table`, with
everything they drove tied to idle (`mapper_init_busy` becomes 0). DPC+,
CDF and BUS cartridges get the bad game screen (`is_bad_game`) instead of
running broken. Pitfall II's DPC (`BANKP2`) and FA2 are separate mappers
and stay.

It saves about 1,750 ALMs and takes the DPC+ decode off the SRAM's
`clk_sdram` request path: Fix A in `../../../docs/SRAM_TIMING.md`. Without
the macro the file is unchanged from upstream.

### Supercharger: tape position and loading without the BIOS (`POCKET_SUPERCHARGER`)

In `rtl/banks2600.sv` (`mapper_AR`), with a `tape_rewind` port through
`rtl/cart2600.sv` and `rtl/top.sv` (driven by `loading`). Needs
`EXTERNAL_FIRMWARE`.

- **The tape keeps its place through a reset.** Upstream sends it back to
  the first image on every reset. Here only a cartridge load does, so a
  compilation tape (Party Mix, Sweat) reaches its next game after a reset,
  as on a real Supercharger after a power cycle.
- **No BIOS file: a loader stub of our own.** The BIOS ROM's power-up
  contents are `../core/ar_stub.mif` (source `../core/ar_stub.asm`). It
  reads the `.bin` through a small port in the ROM's address space
  (`$F900-$FCFF`) and writes the RAM with the Supercharger's write trick, as
  the BIOS does: a full load takes about 0.1 s. A `supercharger.bin` loaded
  into the ROM turns the port off for good, and the tape path runs as
  upstream.

`../../../docs/SUPERCHARGER_FASTLOAD.md` has the design. Without the macro
the files are unchanged from upstream.

## Updating

Copy a newer upstream `rtl/` over this one, re-apply the `ifdef` blocks in
`top.sv`, `cart.sv`, `cart2600.sv`, `banks2600.sv` and `EEPROM_24LC256.sv`, and the holey DMA fix
in `Maria/DMA.sv` (unless upstream has fixed it; check with
`sim/extra_tests.sh`). Delete `rtl/mem4.*`, `rtl/ar.*` and `rtl/bupchip.hex`/`.mif` again, update
`UPSTREAM_COMMIT`, then build and run `sim/run_sim.sh`.
New upstream source files need adding to `../core/core.qip` (and to
`sim/run_sim.sh`).
