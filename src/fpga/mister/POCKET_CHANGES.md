# Vendored MiSTer Atari7800 sources

`rtl/` is a copy of the `rtl/` directory of the MiSTer Atari7800 core:

- Upstream: https://github.com/MiSTer-unstable-nightlies/Atari7800_MiSTer
- Commit: see `UPSTREAM_COMMIT`
- License: `LICENSE` (MIT, Jamie Blanks). Third-party files keep their own
  notices: `sdram.sv` (GPL-3.0, Sorgelig), `jt51/` (GPL-3.0, Jose Tejada
  "Jotego"), `souper.v` (zlib-style, Osman Celimli), `t65/` (BSD-style).

The upstream wrapper (`Atari7800.sv`, `sys/`) is MiSTer-specific and is not
used. Its Pocket counterpart is `../core/atari7800_pocket.sv`.

## Changes from upstream

Two upstream files are modified, and the POKEY is swapped for an older one.

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

### `rtl/top.sv`: build switches

Two build switches were added next to upstream's own `NO_ARM_MAPPER`:

| Macro        | Effect |
|--------------|--------|
| `NO_DDRAM`   | Leaves out the DDR3 bridge (`ddram`). Both of its client channels read back idle. The Pocket has no DDR3. |
| `NO_BUPCHIP` | Leaves out the BupChip player (`bupchip_subsystem`): an ARM program with DDR-resident assets. Souper carts still run; their music channel is silent. |

The Pocket build defines all three (`NO_ARM_MAPPER`, `NO_DDRAM`,
`NO_BUPCHIP`) in `../ap_core.qsf`. Without the macros `top.sv` is identical
to upstream in behaviour.

Note that 0dc8ad2 also moved PAL timing into the PLL (MiSTer retunes it to
14.1876 MHz). The Pocket keeps the NTSC clock, so PAL games run about 0.9%
fast.

## Updating

Copy a newer upstream `rtl/` over this one, re-apply the two `ifdef` blocks
in `top.sv` and the holey DMA fix in `Maria/DMA.sv` (unless upstream has
fixed it; check with `sim/extra_tests.sh`), update `UPSTREAM_COMMIT`, then build and run `sim/run_sim.sh`.
New upstream source files need adding to `../core/core.qip` (and to
`sim/run_sim.sh`).
