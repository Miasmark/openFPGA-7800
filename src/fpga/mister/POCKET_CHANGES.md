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

Only `rtl/top.sv` is modified. Two build switches were added next to
upstream's own `NO_ARM_MAPPER`:

| Macro        | Effect |
|--------------|--------|
| `NO_DDRAM`   | Leaves out the DDR3 bridge (`ddram`). Both of its client channels read back idle. The Pocket has no DDR3. |
| `NO_BUPCHIP` | Leaves out the BupChip player (`bupchip_subsystem`): an ARM program with DDR-resident assets. Souper carts still run; their music channel is silent. |

The Pocket build defines all three (`NO_ARM_MAPPER`, `NO_DDRAM`,
`NO_BUPCHIP`) in `../ap_core.qsf`. Without the macros `top.sv` is identical
to upstream in behaviour.

## Updating

Copy a newer upstream `rtl/` over this one, re-apply the two `ifdef` blocks
in `top.sv`, update `UPSTREAM_COMMIT`, then build and run `sim/run_sim.sh`.
New upstream source files need adding to `../core/core.qip` (and to
`sim/run_sim.sh`).
