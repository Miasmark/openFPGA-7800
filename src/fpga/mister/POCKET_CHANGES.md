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
`banks2600.sv`), two firmware images are removed, and the POKEY is swapped
for an older one.

### POKEY: Mark Watson's VHDL instead of upstream's rtl/Pokey

Upstream commit a36d55b (2026-08-25) replaced Mark Watson's VHDL POKEY with a
new schematic-level one (`rtl/Pokey/`). On Pocket hardware, Ballblazer's
procedurally generated music turns into near-silent taps and pops with the new
POKEY, and its goal siren goes silent. The 2022 Pocket core, which used
Watson's POKEY, plays it correctly on the same hardware.

The Pocket build therefore uses Watson's POKEY: `rtl/PokeyWatson/`, from
upstream b48eac0 (the last commit with it), with its top entity renamed
`pokey` -> `pokey_watson` so it cannot collide with the new POKEY's module
name. `../core/pokey_adapter_watson.sv` provides the `pokey_adapter` module
that `cart.sv` instantiates, wired the way b48eac0 wired Watson's POKEY.
`cart.sv` itself is unchanged, and `rtl/Pokey/` stays in the tree unbuilt.

The exact fault in the new POKEY is not identified yet. Its pure tones match
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

Three build switches were added next to upstream's own `NO_ARM_MAPPER`:

| Macro        | Effect |
|--------------|--------|
| `NO_DDRAM`   | Leaves out the DDR3 bridge (`ddram`). Both of its client channels read back idle. The Pocket has no DDR3. |
| `NO_BUPCHIP` | Leaves out the BupChip player (`bupchip_subsystem`): an ARM program with DDR-resident assets. Souper carts still run; their music channel is silent. |
| `EXTERNAL_FIRMWARE` | Builds the HSC and Supercharger firmware ROMs empty, with a load port (see below). |

The Pocket build defines all four (`NO_ARM_MAPPER`, `NO_DDRAM`,
`NO_BUPCHIP`, `EXTERNAL_FIRMWARE`) in `../ap_core.qsf`. Without the macros
the changed files are identical to upstream in behaviour.

### Firmware loaded at run time (`EXTERNAL_FIRMWARE`)

Upstream builds two pieces of original firmware into the core: the High
Score Cartridge ROM (`rtl/mem4.hex`/`.mif`, used in `cart.sv`) and the
Starpath Supercharger BIOS (`rtl/ar.hex`/`.mif`, used in `banks2600.sv`). No
license is given for either, so this copy leaves both files out. They were
also removed from this branch's git history (see the README, "History
rewrite").

With `EXTERNAL_FIRMWARE` defined, those two ROMs are built empty and gain a
write port (`fw_*` ports through `top.sv` -> `cart.sv`, and `top.sv` ->
`cart2600.sv` -> `mapper_AR` in `banks2600.sv`). The Pocket wrapper fills
them from the user's `highscor.rom` / `hsc.a78` and `supercharger.bin` data slots while
the core is held in reset, and keeps the HSC disabled until a full 4 KiB
image has arrived. `sim/extra_tests.sh` loads both through the slots and
checks the ROM contents byte for byte.

Note that 0dc8ad2 also moved PAL timing into the PLL (MiSTer retunes it to
14.1876 MHz). The Pocket keeps the NTSC clock, so PAL games run about 0.9%
fast.

## Updating

Copy a newer upstream `rtl/` over this one, re-apply the `ifdef` blocks in
`top.sv`, `cart.sv`, `cart2600.sv`, `banks2600.sv` and `EEPROM_24LC256.sv`, and the holey DMA fix
in `Maria/DMA.sv` (unless upstream has fixed it; check with
`sim/extra_tests.sh`). Delete `rtl/mem4.*` and `rtl/ar.*` again, update
`UPSTREAM_COMMIT`, then build and run `sim/run_sim.sh`.
New upstream source files need adding to `../core/core.qip` (and to
`sim/run_sim.sh`).
