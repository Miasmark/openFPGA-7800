# clk_sdram timing: the SRAM request path

Notes on the core's tightest timing path, why 2.1.1 has less margin on it
than 2.0.21, and two fixes. Neither fix is in 2.1.1; Fix A is in 2.1.2
(results in `SRAM_TIMING_REVIEW.md`). Fix B ships with DARIA (step 7); its
design as built is in `DARIA_CORE.md`, "Fix B". Figures come from
Quartus 21.1.1 on the 5CEBA4F23C8, slow 1100 mV 85 °C model, unless stated
otherwise.

## The path

Every build since the SRAM work (2.0.21) has the same worst setup path, on
`clk_sdram` (57.27 MHz, 17.46 ns):

- It starts at a `clk_sys` register: MARIA's DMA bus enable (`dma|ABENF`) or
  the 6502's `halt_bus`.
- It passes the 7800's address-bus mux, the cartridge mappers' RAM decode,
  and `top.sv`'s 2600/7800 merge of the cartridge-RAM request (`:752-757`).
- It goes through `sram_ctrl`'s request logic (the 2600 address-change
  compare `c_key != c_key_last`, the pending-request mux and the arbiter).
- It ends at the SRAM's pad registers (`sram_ub_n`, `sram_lb_n`,
  `sram_a[*]`).

`clk_sdram` is 4 × `clk_sys` with the edges aligned, so the path gets one
`clk_sdram` period from the `clk_sys` edge that launches it. That is on
purpose for the 7800: a cartridge-RAM read has to start one `clk_sdram`
after the `clk_sys` edge that raises MARIA's strobe ("A" in `sram_ctrl.sv`'s
header), and the bus samples the byte two `clk_sys` later. The request
can't wait a cycle without shortening the access elsewhere.

The worst path of the 2.1.1 build (seed 2, +0.438 ns), cell by cell:

| Arrival (ns) | Cell |
|---|---|
| 9.26 | `Atari7800:main` address-bus mux (`Mux11`) |
| 10.62–14.26 | `cart2600:cart2600|mapper_dpcplus:dpcplus`: `LessThan12`, `register_read`, `ram_register_read` |
| 15.42–17.52 | `cart2600` RAM address mux (`Mux28` ×3), `cartram_addr[9]` |
| 17.91–19.26 | `sram_ctrl` 2600 address-change compare (`Equal5` ×2) |
| 19.66–21.41 | `sram_ctrl` request and arbiter (`comb~0`, `bg_ok`) |
| 23.17 | `sram_ub_n`'s input LUT |

That is 14 LUT levels, with 11.3 ns of routing and 6.0 ns of cells in a
17.29 ns data path. Split by where the path runs:

| Paths into the SRAM pad registers | Worst slack |
|---|---|
| Through `cart2600` (the 2600 mappers) | +0.438 ns |
| Through `mapper_dpcplus` alone | +0.438 ns |
| Through `cart` (the 7800 mappers) | +0.861 ns |

The 2600 side is the worst, and it is the side that doesn't need this
speed. A 2600 mapper holds its RAM strobe for most of the 6507 cycle
(`sram_ctrl.sv`'s header), and the 6507 runs at `clk_sys` / 12, about 838
ns. Quartus can't know that, because the 2600 and 7800 requests share one
set of wires from `top.sv`'s merge onward. So the 2600 cone is timed
against the 7800's 17.46 ns.

`mapper_dpcplus` sits on this path, yet it serves no game here.
`NO_ARM_MAPPER` leaves out the ARM (`arm_host`, `arm_mapper_subsystem`) but
not the 6507-side front ends of the ARM schemes. Those can't run a game
without the ARM, and in 2.1.1 they take about 1,750 ALMs:

| Entity (in `cart2600`) | ALMs |
|---|---|
| `mapper_dpcplus` | 1,134.8 |
| `mapper_cdf` | 216.6 |
| `mapper_bus` | 195.5 |
| `arm_mapper_audio` | 90.2 |
| `arm_mapper_ram_init` | 39.9 |
| `arm_mapper_tables` | 39.4 |
| `cdf_fastjump_table` | 35.4 |

## Why 2.1.1 has less margin than earlier builds

The path's logic didn't change. Its slack moves with placement, and the
fuller device (79% of ALMs, 95% of LABs) leaves it less room:

| Build | `clk_sdram` worst setup slack |
|---|---|
| 2.0.21 | +1.32 ns |
| BupChip test builds (`BUP_DEBUG`), seeds 1, 2, 3 | +0.56, +1.04, +1.26 |
| test2, test3, test3b | +0.87, +0.97, +0.65 |
| 2.1.1 release, seeds 1, 2, 3 | +0.26, **+0.44**, +0.28 |

Comparing test3b (+0.654 ns) with 2.1.1 (+0.438 ns), both have 14 LUT
levels on the worst path. The release build's data delay is the shorter of
the two (17.29 ns against 17.54 ns). It loses on clock skew: 0.38 ns in its
favour against 0.85 ns. That skew depends on where the launching register
lands relative to the clock network, which is placement.

One loss was not placement. The first three release builds gave only +0.05
to +0.11 ns, because the power-up fix of the BupChip test builds had given
`sram_oe_n`, `sram_ub_n` and `sram_lb_n` power-up high. Quartus implements
power-up high in a fast output register by inverting it inside the I/O
cell, and that cost the path its margin. Those three pins have no power-up
value again in 2.1.1 (`sram_ctrl.sv`).

## Fix A: leave the ARM schemes' front ends out with the ARM

Under `NO_ARM_MAPPER`, also leave out `mapper_dpcplus`, `mapper_cdf`,
`mapper_bus`, `arm_mapper_tables`, `arm_mapper_audio`,
`arm_mapper_ram_init` and `cdf_fastjump_table` (`cart2600.sv`), tying their
outputs to idle.

- **What it gains:**
  - About 1,750 ALMs, so roughly 79% → 70% of the device.
  - The DPC+ decode leaves the cone; the path's next worst
    leg, through the 7800 mappers, has +0.86 ns today. Other 2600 RAM
    mappers (E7, FA, 3E and others) stay in the cone, with simpler decodes.
- **What it costs:** nothing that works today. These schemes are documented
  as not included (README, "Not included"). Better than today: add
  `BANKDPCP`, `BANKCDF` and `BANKBUS` to `is_bad_game` under the same macro.
  A cartridge of those schemes then shows the core's bad-game screen
  instead of running broken.
- **Rules:** `cart2600.sv` is vendored, so the change is `ifdef` blocks only,
  identical to upstream without the macro, and recorded in
  `mister/POCKET_CHANGES.md`.
- **Checks:**
  - `sim/run_sim.sh` and `sim/extra_tests.sh`.
  - The build's `clk_sdram` slack over three seeds.
  - On hardware: 2600 games with RAM mappers (an E7, FA, 3E or SB title),
    a Supercharger game, a plain 2600 game, and a DPC+ cartridge showing
    the bad-game screen.
- **Limit:** DARIA brings these front ends back, and with them the DPC+
  decode. So Fix A is the quick win for a 2.1.x release, and Fix B has to
  come before or with DARIA.

## Fix B: give the 2600 request its own registered path

Split the two requests where `top.sv` merges them, and register the 2600
one before it reaches `sram_ctrl`'s compare and arbiter.

This is the proposal. The design as built (`DARIA_CORE.md`, "Fix B")
settles its choices: the register sits at the top of `sram_ctrl`, on
`clk_sys`; `top.sv` keeps upstream's select (`mapper_init_busy` or
`tia_en`) for the split; and a 2600 read's byte now lands 15 `clk_sdram`
after the edge that loads the 6507's address (19 at worst, the last edge
the `c_rdata` multicycle allows), against 11 (15) before.

- **`top.sv`** (`ifdef POCKET_SRAM`, beside the existing Pocket port groups):
  export the 2600 request (`cartram_addr26`, `cartram_rd26`,
  `cartram_wr26`, its write data) and `mapper_init_busy` separately from
  the 7800 request, instead of only the merged `cartram_*`.
- **The register.** Put the 2600 request through one `clk_sys` register
  (address, strobes and data) in `atari7800_pocket.sv` or at the top of
  `sram_ctrl`. The DPC+/mapper decode then has a whole `clk_sys` period
  (69.8 ns) to that register. `sram_ctrl` sees a register output, with only
  its compare and arbiter between it and the pads.
- **`sram_ctrl`.** Take the 7800 request (MARIA's slot timing, served at A)
  and the registered 2600 request as two inputs. The address-change compare
  works on the registered 2600 copy only. The 7800 cone loses the compare,
  the merge mux and the 2600 mappers.
- **Cost.** A 2600 cartridge-RAM access starts one `clk_sys` (70 ns) later.
  The access itself is 6 `clk_sdram` (105 ns) from start to data. Against
  a strobe held for most of an 838 ns 6507 cycle that should fit. Check
  each RAM mapper's read sampling point against it, in simulation first.
- **Gain.** The `clk_sdram` cone becomes the 7800 request alone: +0.86 ns in
  today's placement before taking out the compare's two levels. It should
  stop depending on the seed. Measure over three seeds; aim for +1.5 ns.
- **For DARIA:** superseded. DARIA keeps its cartridge RAM in block RAM
  (`DARIA_CORE.md`, decision 4), so no ARM traffic reaches the SRAM, and
  Fix B covers the 2600 RAM mappers alone.
- **Checks:** as for Fix A, plus a 2600 RAM-mapper test in simulation that
  writes and reads back cartridge RAM through each RAM mapper with the
  added latency. It now exists: `sim/cartram2600_test.py`'s images under
  the `+cartram` monitor (`DARIA_CORE.md`, "Fix B", section 4).

## Not recommended: timing exceptions

A multicycle or false-path exception from the 2600 cone to the pads would
also remove it from the analysis. It is valid only while `sram_ctrl` never
uses the combinational 2600 request in the first `clk_sdram` after a
`clk_sys` edge, and `tia_mode` is a register Quartus can't treat as a
constant. The exception would name cells by hierarchy, which changes
whenever the upstream mappers do. If the names stop matching, the
constraint silently stops applying (as `DEVELOPING.md`, "Timing
constraints", warns for the clock names). Fix B gets the same result in
the logic.

## Order

1. 2.1.1 ships with seed 2 (+0.438 ns, positive on every corner).
2. Fix A in the next 2.1.x: small `ifdef` change, about 1,750 ALMs back, a
   2600 hardware check.
3. Fix B before DARIA's mapper work (`BUPCHIP_CORE.md`, "Later: 2600 ARM
   cartridges"), with its own hardware test. Decision 2 in `DARIA_CORE.md`
   ties it to DARIA's release; it is built in DARIA's step 7.
4. Until then, check the seed whenever the design changes (`ap_core.qsf`'s
   comment above `SEED`).
