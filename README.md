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
- High score cartridge saves, kept in a Pocket save file.
- An optional BIOS: `7800bios.bin` in `/Assets/7800/common/`. By default the
  core skips it, as MiSTer does. Turn off *Skip BIOS* to boot through it.
- Settings: difficulty switches, controller swap, region, palette
  (warm/cool/hot), high score cart, overscan, border, stereo TIA, and 2600
  flicker blend.

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
| This port (ARM and BupChip left out) | **11,726 / 18,480 (63%)**, fitted | 2.05 / 3.15 Mbit (65%) |
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

Pitch is measured to the 5 Hz resolution of the test window. The old core
would read about half these frequencies, an octave down.

The Quartus build meets timing on all four corners (worst setup slack
+1.81 ns, hold +0.076 ns). The PLL produces 14.3204 MHz for the 14.3182 MHz
crystal, 0.015% fast, which is not audible.

Not yet tested on a real Pocket. Hardware testing is the next step.

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
- **Souper** mapper logic by **Osman Celimli**.

**Pocket side**

- **Analogue**: the openFPGA APF framework and core template.
- **Adam Gastineau (agg23)**: `data_loader`, `sound_i2s` and `sync_fifo`
  from [analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils)
  (MIT).
- **Spiritualized**: the original 2022 Pocket 7800 core, and the platform
  image and slot layout this port stays compatible with.

## License

- The Pocket glue in `src/fpga/core/` is MIT.
- The MiSTer core in `src/fpga/mister/` is MIT (© Jamie Blanks). Its
  third-party files keep their own licenses, listed in
  [POCKET_CHANGES.md](src/fpga/mister/POCKET_CHANGES.md).
- The JT51 and SDRAM controller files are GPL-3.0, so a distributed bitstream
  is covered by GPL-3.0 as a whole. The complete source is in this repository.
- `src/fpga/apf/` is Analogue's framework, under Analogue's terms.
