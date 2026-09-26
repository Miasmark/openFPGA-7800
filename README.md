# Atari 7800 for Analogue Pocket

An Atari 7800 ProSystem core for the Analogue Pocket (openFPGA), ported from
the current [MiSTer Atari7800 core](https://github.com/MiSTer-unstable-nightlies/Atari7800_MiSTer)
by **Jamie Blanks (Kitrinx)** and its contributors.

This replaces the original 2022 Pocket core (Spiritualized, 1.0.2), whose
source was never published. The old release files are kept in this
repository for reference under `Cores/`, `Platforms/` and the `*.zip` /
`*.tar.gz` archives at the root.

## Why a new port

The 1.0.2 Pocket core plays TIA sound an octave too low. MiSTer's TIA model
has the right pitch: simulating it at MiSTer's clocks gives a pure tone
(AUDC=4, AUDF=0) of 15,699.9 Hz against the TIA's 15,699.8 Hz. The TIA's
audio dividers expect a clock enable of twice the colour clock (7.16 MHz).
In 7800 mode the TIA only makes sound, since MARIA draws the picture. An
enable at half that rate halves every pitch and changes nothing else, which
matches the symptom.

This port runs the whole system from the 7800's real 14.318181 MHz master
clock, as MiSTer does. `sim/run_sim.sh` checks the pitch end to end through
the Pocket wrapper.

## Features

Everything the MiSTer core does for 7800 cartridges, except as noted below:

- The whole 7800 retail library. A78 headers are parsed exactly as MiSTer
  parses them: mappers (SuperGame, Activision, Absolute, Souper, bankset, XM,
  and others), POKEY at $450/$4000, dual POKEY, YM2151, Covox, and the
  high score cartridge.
- 2600 cartridges (`.a26`, `.bin`), with MiSTer's bankswitch auto-detection.
  The ARM-based schemes (DPC+, CDF/CDFJ) are not included; see below.
- High score cartridge saves, in **one shared file for all games**, like the
  real HSC's single RAM: `hsc.sav` (the Pocket keeps it under
  `/Saves/7800/`). Versions 2.0.2 and 2.0.3 used a file per game, and those
  files are rotated by four bytes; `tools/fix_hsc_save.py` repairs one, which
  can then be renamed `hsc.sav` to keep its scores.
- **SaveKey** (24LC256 EEPROM on controller port 2), in one shared
  `savekey.sav`, like the real device. *SaveKey (port 2)* = Auto turns it on
  when the A78 header asks for one (save byte bit 1, or an AtariVox/SaveKey
  on port 2); 2600 SaveKey games need it set to On. Unlike MiSTer, the high
  score cart stays available alongside it, since each has its own file: a
  cart whose header asks for both (such as Triple Punch) gets both.
- An optional BIOS: `7800bios.bin` in `/Assets/7800/common/`. By default the
  core skips it, as MiSTer does. Turn off *Skip BIOS* to boot through it.
- Settings: difficulty switches, controller swap, region, palette
  (warm/cool/hot), high score cart, overscan, border, stereo TIA, 2600
  flicker blend, SaveKey, and POKEY IRQ (off by default, as on MiSTer; some
  games drive their music from POKEY timer interrupts).

### Not included

| Feature | Why |
|---|---|
| **BupChip** (Souper music co-processor) | **Doesn't fit on the Pocket.** See below. Souper games run, but without the extra music channel. |
| 2600 ARM cartridges (DPC+, CDF, CDFJ) | These run on the same soft ARM CPU as the BupChip, so they don't fit either. |
| Exact PAL clock | MiSTer reprograms its PLL for PAL (14.1876 MHz). This port keeps the NTSC clock, so PAL games run and sound about 0.9% fast. |
| Light gun, paddles, trackball, keypad | These need input the Pocket doesn't have. Joysticks work. |
| Composite video filter | Only the RGB output is used. |

#### Why the BupChip doesn't fit

On MiSTer the BupChip isn't a separate chip. It's a firmware program running
on a soft **ARM7TDMI CPU** (`arm_host`), the same one that runs 2600 ARM
cartridges. Its music assets are streamed from **DDR3** memory. This was
measured with Quartus on the Pocket's FPGA (Cyclone V 5CEBA4F23C8):

| Build | Logic (ALMs) | Block RAM |
|---|---|---|
| This port (ARM and BupChip left out) | **11,539 / 18,480 (62%)**, fitted | 2.31 / 3.15 Mbit (73%, including the SaveKey's 32 KiB) |
| With the ARM CPU and BupChip | **~25,000 / 18,480 (~135%)**, synthesis estimate | 2.44 Mbit |

- The ARM CPU on its own is about 16,200 LUTs, roughly as much as the rest of
  the 7800 put together. The BupChip logic around it is small (about 630
  LUTs), but it can't work without the CPU.
- The Pocket has no DDR3. It has SDRAM (used for the cartridge), PSRAM and a
  small SRAM, so the BupChip's memory side would need rewriting as well.
- The ARM runs at 71.6 MHz. Upstream notes it is already the core's worst
  timing path on MiSTer's faster FPGA, and the Pocket's FPGA is a slower
  speed grade.

Running the BupChip on the Pocket would need a much smaller ARM
implementation. That would be a project of its own.

## Verification

`sim/run_sim.sh` runs the complete core (this Pocket wrapper plus the MiSTer
system) under Verilator at the Pocket's clock rates. Latest results:

| Check | Result |
|---|---|
| TIA pure tone, 7800 mode, AUDF 0 / 7 / 31 | 15,700.0 / 1,965 / 490 Hz vs. reference 15,699.8 / 1,962.5 / 490.6 Hz |
| TIA pure tone, 2600 mode, AUDF 0 / 14 | 15,700.0 / 1,045 Hz vs. reference 15,699.8 / 1,046.7 Hz |
| A78 loaded through the APF data loader | header parsed, 16,384 byte payload stored with 0 mismatches, cart plays the right tone |
| Headerless 2600 image through the loader | detected as 2600, stored with 0 mismatches, plays the right tone |
| High score save word port | 32 bit word lands as 4 bytes in address order |
| 7800 video | 59.96 Hz, 320x224 (372x224 with the border) |
| 2600 video | 59.92 Hz, 160x240 (MiSTer's "smart" stabiliser window) |
| Audio filter | centred on zero, settles to 0 in silence |
| SaveKey | a test cart writes 8 bytes over I2C with 7800basic's AtariVox/SaveKey driver and reads them back: pass (Auto with a SaveKey header, and On); absent when the header has none |
| SaveKey save slot | 32 KiB written in and read back under the APF read protocol: only the 8 bytes the cart wrote differ |
| HSC save slot | a hardware-written save round-trips with 0 of 2048 bytes different |

Pitch is measured to the 5 Hz resolution of the test window. The old core
would read about half these frequencies, an octave down.

The Quartus build meets timing on all four corners (worst setup slack
+2.29 ns, hold +0.070 ns). The PLL produces 14.3204 MHz for the 14.3182 MHz
crystal, 0.015% fast, which is not audible.

### Hardware testing (2.0.2, Analogue Pocket)

| Test | Result |
|---|---|
| TIA sound pitch | Correct (the old core's octave-low bug is gone) |
| Midnight Mutants, Commando, Dig Dug sprites | No corruption (holey DMA fix) |
| Ballblazer | A full match played to a win, plus several attract-mode loops: procedural music and goal siren correct |
| 2600: Solaris, Adventure | Nothing significantly wrong seen |
| Commando POKEY music | Missing, as on the 2022 core; see Known issues |
| SaveKey | New in 2.0.5; not yet tested on hardware. 2.0.6: HSC and SaveKey together when the header asks for both (Triple Punch) |
| High score cart (Dig Dug, Food Fight) | Works, scores persist, one personalisation for all games (2.0.4, shared `hsc.sav`) |

### Changes to the MiSTer sources

- **Holey DMA (sprite corruption).** Upstream's 2026-09-11 commit changed
  how MARIA handles holey DMA, and sprites crossing zone boundaries began
  showing stray rows (reported on hardware in Midnight Mutants, Commando and
  Dig Dug). This port restores the previous upstream behaviour. The failure
  and the fix both reproduce in simulation with 7800basic's multisprite
  sample. After the fix every sprite matches its source graphic row for row.
  This bug is in the MiSTer nightly too, not only here. See
  [POCKET_CHANGES.md](src/fpga/mister/POCKET_CHANGES.md).

- **POKEY.** Upstream replaced Mark Watson's long-standing VHDL POKEY with
  a new one on 2026-08-25. On Pocket hardware, Ballblazer's music turned into
  near-silent taps and pops with the new one, and it plays correctly on the
  2022 Pocket core, which used Watson's. This port uses Watson's POKEY again
  (see POCKET_CHANGES.md). What exactly the new POKEY gets wrong is not
  identified yet.

### Known issues

- **Commando: no POKEY music.** This also happens on the 2022 Spiritualized
  core, so it isn't caused by this port. The usual cause is an A78 header
  that doesn't flag the POKEY: check that the dump's header sets the POKEY
  bit (cart type bit 0, POKEY at $4000). Turning on *POKEY IRQ* made no
  difference.

`sim/extra_tests.sh` builds 7800basic's sprite and POKEY samples and the DLI
test cart locally (no ROMs are stored in this repository) and runs them
through the core. `sim/tb_pokey.sv` sweeps a POKEY channel through all 256
frequencies in any AUDC/AUDCTL mode, for comparison against `pokey_model.py`
(the documented divider and polynomial behaviour) with `pokey_compare.py`.
The simulation converts Watson's VHDL POKEY with GHDL, so it runs the same
POKEY as the Pocket build.

## Controls

| Pocket | Atari |
|---|---|
| D-pad | Joystick |
| A / Y | Left button (fire 1) |
| B / X | Right button (fire 2) |
| L | Pause (7800) / Colour-B&W (2600) |
| Select | Select |
| Start | Reset |

## Installing

Copy the contents of a release zip to the root of the SD card. Carts go
anywhere under `/Assets/7800/`, and the optional BIOS goes in
`/Assets/7800/common/7800bios.bin`.

## Building

The FPGA project is `src/fpga/ap_core.qpf`, for Quartus Prime Lite (built
with 21.1). The GitHub workflow builds it in the `raetro/quartus:21.1`
container and uploads a ready-to-copy zip. By hand:

```sh
cd src/fpga && quartus_sh --flow compile ap_core
cd ../.. && tools/package.sh      # -> release/Atari7800_Pocket_<version>.zip
```

`sim/run_sim.sh` (Verilator 5.040; 5.020 is too old for the upstream sources) runs the whole core at the
Pocket's clocks. It checks TIA pitch at the core's audio output and reports
the video geometry.

## Layout

```
src/fpga/apf/          Analogue's APF framework (unchanged, from the core template)
src/fpga/core/         Pocket glue: core_top.v, atari7800_pocket.sv, PLL, audio filter
src/fpga/mister/rtl/   MiSTer Atari7800 sources (vendored; see POCKET_CHANGES.md)
src/fpga/pocket_utils/ Data loader / I2S helpers by Adam Gastineau (agg23)
dist/                  Pocket SD card files (core, platform, JSON definitions)
sim/                   Verilator simulation
tools/                 Packaging
```

## Credits

**The MiSTer Atari7800 core.** Nearly all of this core is its work.

- **Jamie Blanks (Kitrinx)**, author of the MiSTer Atari7800 core: MARIA,
  TIA, RIOT, the 6502 ("Sally"), POKEY, Minnie, the cartridge mappers, 2600
  support, and the system as a whole.
- Contributors to the MiSTer core: **Robert Tuccitto (trebor68)** for the
  palettes and the ROM header work behind them, **Bruno Freitas
  (bootsector)**, **Sorgelig**, **José Manuel Barroso Galindo
  (theypsilon)**, **bobRetro**, **Gyorgy Szombathelyi (gyurco)**, **Roberto
  Garcia-Lago**, **TheJesusFish**, **Roberto Lari**, **PhantombrainM**,
  **Niclas Carlsson**, **Flandango** and **David Gillies**.
- People the MiSTer core thanks for its accuracy: **Mike Saarna** for his
  system knowledge, **Osman Celimli** for DMA timing traces and the Souper
  mapper, **Robert Tuccitto** for the palette research, **Remowilliams** for
  hardware testing, and **Alan Steremberg** for documentation access.

**Third-party components used by the MiSTer core**

- **JT51** (YM2151) by **Jose Tejada Gomez (Jotego)**, GPL-3.0.
- **SDRAM controller** by **Sorgelig**, GPL-3.0.
- **POKEY** by **Mark Watson**, the VHDL POKEY the MiSTer 7800 core used
  until 2026-08-25. This port still uses it; see POCKET_CHANGES.md.
- **Souper** mapper logic by **Osman Celimli**.
- **24LC0x EEPROM** (the SaveKey) by **GreyRogue**, from NES_MiSTer,
  GPL-3.0.

**Pocket side**

- **Analogue**: the openFPGA APF framework and core template.
- **Adam Gastineau (agg23)**: `data_loader`, `sound_i2s` and `sync_fifo`
  from [analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils)
  (MIT).
- **Spiritualized**: the original 2022 Pocket 7800 core, and the platform
  image and slot layout this port stays compatible with.

## License

Each part keeps its own license. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
lists every component, its license, and whether it is built into the
bitstream.

- This project's own code (`src/fpga/core/` apart from the two template
  files, `sim/`, `tools/`) is MIT: see [LICENSE](LICENSE).
- The MiSTer core in `src/fpga/mister/` is MIT (© Jamie Blanks), apart from
  the third-party files below.
- The SDRAM controller, JT51 and the SaveKey EEPROM are GPL-3.0. The full
  text is in [LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt), and the complete
  source for the bitstream is in this repository.
- Mark Watson's POKEY (`src/fpga/mister/rtl/PokeyWatson/`) is free for
  non-commercial use; commercial use needs his permission.
- `src/fpga/apf/`, `core_top.v` and `core_bridge_cmd.v` are Analogue's
  framework and template, under Analogue's terms.
- The bitstream embeds the High Score Cartridge firmware and the Supercharger
  BIOS, carried over from the MiSTer core. No license is given for either.

**Known conflict.** GPL-3.0 does not allow extra restrictions on a combined
work, and Watson's non-commercial condition is one. So, strictly, the
bitstream can't be distributed under both licenses at once. The MiSTer core
shipped the same combination for years. Until it is resolved, treat this core
as non-commercial only. It can be resolved by any one of:

1. getting Mark Watson's permission to distribute his POKEY under GPL-3.0;
2. replacing the three GPL-3.0 parts with permissively licensed ones: a new
   SDRAM controller, a new 24LC256 model, and building without the YM2151
   (only a few XM homebrews use it);
3. going back to upstream's MIT POKEY, which breaks Ballblazer on the Pocket.
