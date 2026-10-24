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

Thirteen upstream files are modified: `top.sv`, `cart.sv`, `cart2600.sv`,
`banks2600.sv`, `EEPROM_24LC256.sv`, `Maria/DMA.sv`, `Maria/video_sync.sv`,
`video_mux.sv`, `TIA.sv`, `bram.v`, and three of the POKEY's,
`Pokey/pokey_adapter.sv`, `Pokey/pokey.sv` and `Pokey/pokey_bus.sv`. The
sections below describe each. Three firmware images are removed. The build
uses upstream's POKEY (`rtl/Pokey/`, with a changed adapter and, from 2.2.2,
the read fix); Watson's older one, which releases up to 2.0.20 used, stays in
`rtl/PokeyWatson/` for simulation.

### POKEY: upstream's rtl/Pokey, fixed (Watson's VHDL up to 2.0.20)

Since 2.0.21 the Pocket build uses upstream's `rtl/Pokey/` again, with two
changes in `Pokey/pokey_adapter.sv`: the write hold described below (the
cause of the Ballblazer fault), and half the output level. From 2.2.2 a
third, the read fix below, in `pokey_adapter.sv`, `pokey.sv` and
`pokey_bus.sv`. The new mixer's
curve gives about twice the level of Watson's linear sum for the same music,
and the core's mix was set for Watson's; the curve's compression of loud
passages is kept. Confirmed on hardware: Ballblazer plays a full match.

**Reads (2.2.2).** The die drives its data pads, and fires the read strobes
behind them, only in the o2 half of the cycle. Through the adapter, o2
starts at `PHI2_EN`, which `cart.sv` drives from pclk0: the clk on which the
CPU latches a read. So every POKEY read saw the precharged bus and returned
$FF, apart from the odd stretched cycle. Music was unaffected (it is all
writes); a game that reads POKEY was not. Star Raiders (7800, 2026) loops on
RANDOM for a free slot in a 128-entry table and stayed on a black screen:
39 of its first 40 RANDOM reads were $FF. `pokey_bus.sv` has a parameter,
`READ_WHOLE_CYCLE` (default 0, the die as upstream), that keeps the read
strobes and pads live in o1 too; `pokey.sv` passes it on and the adapter
sets it. Reads have no side effects in this POKEY, and the address latch is
transparent in o1, so the CPU gets the addressed register. Watson's POKEY,
up to 2.0.20, read the same way. Upstream (MiSTer's nightly ffc4719 and its
release 0dc8ad2) wires and gates reads the same as before this fix, so it
very likely has the fault too. Confirmed on hardware: Star Raiders reaches
its title; Ballblazer or Commando's music is unchanged.

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

### `rtl/Maria/video_sync.sv`: the 224 line window moved down 3 lines

Without *Show Overscan*, NTSC shows the 224 lines of `vblank_ex`. Upstream
puts them at MARIA lines 24-247 (of 16-257). Games draw 3 lines lower:
7800basic's 224 line screens fill lines 27-250 (its `screensafe` sample in
`tb_load +overscan`), and Commando's score bar starts at line 27. Upstream's
window showed 3 lines of the game's overscan at the top (Commando's
background above the score bar) and cut 3 picture lines at the bottom.
The Pocket copy uses lines 27-250. PAL keeps 24-297 (274 lines).

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

Five build switches were added next to upstream's own `NO_ARM_MAPPER`:

| Macro        | Effect |
|--------------|--------|
| `NO_DDRAM`   | Leaves out the DDR3 bridge (`ddram`). Both of its client channels read back idle. The Pocket has no DDR3. |
| `NO_BUPCHIP` | Leaves out the BupChip player (`bupchip_subsystem`): an ARM program with DDR-resident assets. Souper carts still run; their music channel is silent unless `POCKET_BUPCHIP` brings in the Pocket's own player. |
| `POCKET_BUPCHIP` | With `NO_BUPCHIP`: `top.sv` hands the BupChip's inputs out and takes its audio back, so that the Pocket's own BupChip (`../core/bupchip/`, ARIA; `../../../docs/BUPCHIP_CORE.md`) can play the music outside it. New ports `bup_cmd_valid_o` / `bup_cmd_data_o` (the `$8007` command, `bup_cmd_*_eff`), `souper_profile_o` (`souper_profile`), and `bup_audio_l_i` / `bup_audio_r_i`, which drive `bupchip_audio_l/r` in place of the zeros, so the audio goes through upstream's gain, saturation and mix unchanged. Both blocks are `ifdef`s: a port group next to `POCKET_SRAM`'s, and the assignments inside the `NO_BUPCHIP` branch. |
| `EXTERNAL_FIRMWARE` | Builds the HSC and Supercharger firmware ROMs empty, with a load port (see below). |
| `POCKET_DARIA` | Only together with `NO_ARM_MAPPER`: hooks for the Pocket's DARIA front end, which runs the 2600 ARM cartridges outside this module. See "DARIA front end hooks" below. |

The Pocket build defines all six (`NO_ARM_MAPPER`, `NO_DDRAM`,
`NO_BUPCHIP`, `POCKET_BUPCHIP`, `EXTERNAL_FIRMWARE`, `POCKET_DARIA`) in
`../ap_core.qsf`. A build without the DARIA front end deletes
`POCKET_DARIA` there, with the qsf's two other DARIA lines (`core/daria.qip`
and `core/daria_constraints.sdc`).
Without the macros, `top.sv`, `cart.sv`, `cart2600.sv`, `banks2600.sv`,
`EEPROM_24LC256.sv`, `video_mux.sv` and `bram.v` are identical to upstream in
behaviour; the changes to `TIA.sv`, `Maria/DMA.sv`, `Maria/video_sync.sv` and
`Pokey/pokey_adapter.sv` have no macro. `Pokey/pokey.sv` and
`Pokey/pokey_bus.sv` have none either: their `READ_WHOLE_CYCLE` parameter
defaults to upstream's behaviour, and the adapter sets it.

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
the core reset that a retune causes, and while the console is in reset the
Auto region falls back to the A78 header's region byte, which a 2600 image
does not have; as upstream's wrapper is written, that sends a PAL 2600 game
back to NTSC and into another retune, without end.
`../core/atari7800_pocket.sv` latches the detected region until the next
cart load (`tia_pal_seen`), and asks the PLL for `region_pll`, which holds
a 2600 image's region during its download and while its console is in
reset, so a PAL 2600 game retunes once. An A78's region (its header) and
the Region setting reach the PLL as before, one `clk_sys` later (a setting
changed while a 2600 image's console is in reset, when it is released).

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
  Fix B (`../../../docs/DARIA_CORE.md`, "Fix B") adds the outputs
  `cartram_addr26_out`, `cartram_wr26_out`, `cartram_rd26_out` and
  `cartram_wrdata26_out`, and splits upstream's merge of the 2600 and 7800
  cartridge-RAM requests (an `ifdef POCKET_SRAM` / `else` upstream merge /
  `endif` block) under the merge's own select: `cartram_*` carries the 7800
  request alone, and the new ports carry the 2600 request, which `sram_ctrl`
  registers on `clk_sys`. That keeps the 2600 mappers' decode off the SRAM's
  `clk_sdram` request path. `POCKET_SRAM` therefore needs `EXTERNAL_CARTRAM`
  (`../ap_core.qsf` and `sim/run_sim.sh` set both): without it,
  `cart_ram_tdp` would see no 2600 request.
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

### DARIA front end hooks (`POCKET_DARIA`, inside `NO_ARM_MAPPER`)

With `POCKET_DARIA` the Pocket runs DPC+ and the CDF family (CDF0, CDF1,
CDFJ, CDFJ+) again, on its own front end (`../core/bupchip/daria_fe.sv`,
instance `u_fe` in `../core/atari7800_pocket.sv`) and the BupChip's CPU
(`../../../docs/DARIA_CORE.md`, `../../../docs/daria_fe/design.md`). Every
hook below sits inside `ifdef NO_ARM_MAPPER` and `ifdef POCKET_DARIA`, so
upstream's own build with the ARM (`NO_ARM_MAPPER` undefined, as the
simulation oracle `sim/bupchip/daria/tb_daria.sv` builds it, `POCKET_DARIA`
or not) sees none of it.

- `rtl/cart2600.sv`: four inputs, `fe_do[7:0]` (the front end's data byte,
  a register), `fe_oe` (its output enable, A12), `fe_call_busy` and
  `fe_dma_busy`. `BANKDPCP` and `BANKCDF` drive `fe_do` as their direct
  byte with `out_en` from `fe_oe`; the cartridge RAM is never selected for
  them and their ROM address stays 0, as without DARIA. `arm_call_busy`
  and `arm_dma_busy` take the front end's busys in place of the stubs, so
  `top.sv`'s `arm_call_stall` (and with it `RDY` and `mapper_phi2`) keeps
  upstream's text; `mapper_init_busy` stays 0. `is_bad_game` keeps the bad
  game screen for ELF and BUS only.
- `rtl/top.sv`: a port group after `POCKET_BUPCHIP`'s, with outputs
  `daria_a_in_o` (`{AB[12] & bios_en_b, AB[11:0]}`, cart2600's `a_in`),
  `daria_pclk0_o` (`pclk0`), `daria_access_o` (`mapper_phi2 && lock_ctrl
  && tia_en`, cart2600's `arm_access`) and `daria_reset_o`
  (`effective_reset`), and inputs `daria_fe_do_i`, `daria_fe_oe_i`,
  `daria_call_busy_i` and `daria_dma_busy_i`, which go to the four
  `cart2600` inputs above. The front end also takes the CPU's clock enable
  from the existing `cpu_ce` output (`pclk1`), and `write_DB` and `RW` from
  `dout` and `RW`.

The wrapper holds the console in reset through the front end's RAM image at
load and after a reset (`init_busy`, for an ARM image only) and across a PLL
retune; see the DARIA section of `../core/atari7800_pocket.sv`.

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

Copy a newer upstream `rtl/` over this one and re-apply the changes to all
thirteen modified files:

- the `ifdef` blocks in `top.sv`, `cart.sv`, `cart2600.sv`, `banks2600.sv`
  and `EEPROM_24LC256.sv`;
- the holey DMA fix in `Maria/DMA.sv` (unless upstream has fixed it; check
  with `sim/extra_tests.sh`);
- the 224 line window in `Maria/video_sync.sv`;
- the SRAM frame port in `video_mux.sv` and the memory editor's removal in
  `bram.v`;
- the stabilised window's end in `TIA.sv`;
- the write hold and the halved level in `Pokey/pokey_adapter.sv`;
- the read fix (2.2.2): the `READ_WHOLE_CYCLE` parameter in `Pokey/pokey_bus.sv`,
  passed on by `Pokey/pokey.sv` and set by `Pokey/pokey_adapter.sv` (unless
  upstream has fixed its reads; check with `sim/tb_load.sv`'s `+cpuprobe` on
  a game that reads RANDOM).

Delete `rtl/mem4.*`, `rtl/ar.*` and `rtl/bupchip.hex`/`.mif` again, update
`UPSTREAM_COMMIT`, then build and run `sim/run_sim.sh`.
New upstream source files need adding to `../core/core.qip` (and to
`sim/run_sim.sh`).
