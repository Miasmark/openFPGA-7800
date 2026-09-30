# Atari 7800 for Analogue Pocket

To be clear and upfront, this port was assisted by Claude. I wanted it to exist and tested
functionality as best I could.

An Atari 7800 ProSystem core for the Analogue Pocket (openFPGA), ported from
the current [MiSTer Atari7800 core](https://github.com/MiSTer-unstable-nightlies/Atari7800_MiSTer)
by **Jamie Blanks (Kitrinx)** and its contributors.

This replaces the original 2022 Pocket core (Spiritualized, 1.0.2), whose
source was never published. Its release files were in this repository until
2.0.11 and remain in the git history (before the port's first commit).

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
- The high score cartridge, which needs its firmware as a file (see
  *Firmware files* below). Its saves go in **one shared file for all games**, like the
  real HSC's single RAM: `hsc.sav` (the Pocket keeps it under
  `/Saves/7800/`). Versions 2.0.2 and 2.0.3 used a file per game, and those
  files are rotated by four bytes; `tools/fix_hsc_save.py` repairs one, which
  can then be renamed `hsc.sav` to keep its scores.
- **SaveKey** (24LC256 EEPROM on controller port 2), in one shared
  `savekey.sav`, like the real device. A new file starts blank ($FF), as a
  real SaveKey does. *SaveKey (port 2)* = Auto turns it on
  when the A78 header asks for one (save byte bit 1, or an AtariVox/SaveKey
  on port 2); 2600 SaveKey games need it set to On. Unlike MiSTer, the high
  score cart stays available alongside it, since each has its own file: a
  cart whose header asks for both (such as Triple Punch) gets both.
- An optional BIOS: `7800bios.bin` in `/Assets/7800/common/`. By default the
  core skips it, as MiSTer does. Turn off *Skip BIOS* to boot through it.
- 2600 Starpath Supercharger games, given the Supercharger BIOS as a file.
  Untested on hardware.
- Settings: difficulty switches, controller swap, region, palette
  (warm/cool/hot), high score cart, overscan, border, stereo TIA, SaveKey,
  and POKEY IRQ (off by default, as on MiSTer; some games drive their music
  from POKEY timer interrupts). From 2.0.12, also these MiSTer options:
  - *Stereo Mix* (None / 25% / 50% / 100%): blends the left and right
    channels, for Stereo TIA and stereo carts on headphones.
  - *Clear Memory* (Zero / Random): what RAM holds at power-on. Real
    hardware starts random, and some homebrew seeds its randomness from it.
  - *2600 De-comb*: smooths the comb pattern some 2600 games draw by
    alternating lines between frames.
  - *2600 Bankswitching*: forces a cartridge mapper when auto-detection
    picks the wrong one. The ARM mappers (DPC+, CDF, BUS) aren't in this
    build, so they aren't offered.
- PAL games at the real PAL master clock, 14.18758 MHz instead of NTSC's
  14.31818 MHz, so they run at 50 Hz and play at the right pitch. The region
  follows the A78 header (2600 games: their measured frame length) or the
  *Region* setting. As on MiSTer, the PLL is retuned when the region changes,
  which holds the core in reset for a moment; a PAL 2600 game restarts once
  when it is recognised. PAL frames are taller than NTSC ones (274 visible
  lines instead of 224; 288 instead of 240 for the 2600), and the Pocket's
  display mode follows, so nothing is cut off. PAL games need no PAL BIOS
  while *Skip BIOS* is on (the default).
- *Show Overscan* shows MARIA's whole NTSC picture: 242 lines instead of
  the 224 most games stay inside. Games that draw into the overscan, like
  Triple Punch's bonus timer at the bottom, need it. PAL games ignore it:
  their 274-line picture is already complete.

### Not included

| Feature | Why |
|---|---|
| **BupChip** (Souper music co-processor) | **Doesn't fit on the Pocket.** See below. Souper games run, but without the extra music channel. |
| 2600 ARM cartridges (DPC+, CDF, CDFJ) | These run on the same soft ARM CPU as the BupChip, so they don't fit either. |
| Light gun, paddles, trackball, keypad | These need input the Pocket doesn't have. Joysticks work. |
| Composite video filter | Only the RGB output is used. |

#### Why the BupChip doesn't fit

On MiSTer the BupChip isn't a separate chip. It's a firmware program running
on a soft **ARM7TDMI CPU** (`arm_host`), the same one that runs 2600 ARM
cartridges. Its music assets are streamed from **DDR3** memory. This was
measured with Quartus on the Pocket's FPGA (Cyclone V 5CEBA4F23C8):

| Build | Logic (ALMs) | Block RAM |
|---|---|---|
| This port (ARM and BupChip left out) | **11,668 / 18,480 (63%)**, fitted | 2.31 / 3.15 Mbit (73%, including the SaveKey's 32 KiB) |
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
| SaveKey reads ending in NACK | A read whose last byte is $00, answered with NACK then STOP, leaves SDA released and the STOP seen (`+i2ctrace`). Triple Punch's slot scan decodes cleanly with a zeroed and a blank file |
| SaveKey save slot | 32 KiB written in and read back under the APF read protocol: only the 8 bytes the cart wrote differ |
| HSC save slot | a hardware-written save round-trips with 0 of 2048 bytes different |
| Display geometry | Active lines per frame match the display mode: NTSC 224, overscan 242, PAL 274 (overscan setting ignored), 2600 240 / PAL 288. Triple Punch (NTSC and PAL) shows its bonus timer at the bottom with Show Overscan on (NTSC) or always (PAL) |
| Firmware slots | `highscor.rom` (4 KiB), `hsc.a78` (header skipped; also a 16 KiB payload, last 4 KiB kept) and `supercharger.bin` (2 KiB) land in the ROMs with 0 bytes different; without HSC firmware the HSC stays off even when set On. Triple Punch finds the loaded HSC as it did the built-in one |

Pitch is measured to the 5 Hz resolution of the test window. The old core
would read about half these frequencies, an octave down.

The Quartus build (2.0.11) meets timing on all four corners (worst slack
+0.097 ns, a hold path). The PLL produces the NTSC and PAL master clocks
exactly (14.3181818 and 14.1875800 MHz, to the PLL's 32-bit fraction).

### Hardware testing (2.0.2 to 2.0.11, Analogue Pocket)

| Test | Result |
|---|---|
| TIA sound pitch | Correct (the old core's octave-low bug is gone) |
| Midnight Mutants, Commando, Dig Dug sprites | No corruption (holey DMA fix) |
| Ballblazer | A full match played to a win, plus several attract-mode loops: procedural music and goal siren correct |
| 2600: Solaris, Adventure | Nothing significantly wrong seen |
| Commando POKEY music | Works: typing intro, title theme and attract music. Needs a dump whose header flags the POKEY (see below) |
| SaveKey (Triple Punch) | Works from 2.0.8: shows "Save SK", saves, and the high score is back after reloading. 2.0.7 showed "Save ER" (EEPROM model bug on reads, and a zero-filled file); delete an all-zero `savekey.sav` left by older versions |
| Triple Punch, HSC and SaveKey together | Header asks for both (2.0.6): uses the HSC when present, the SaveKey with the HSC off |
| High score cart (Dig Dug, Food Fight) | Works, scores persist, one personalisation for all games (2.0.4, shared `hsc.sav`). From 2.0.7 the firmware comes from the user's file; works with `hsc.a78` |
| Supercharger BIOS file | New in 2.0.7; not tested on hardware |
| PAL games (Choplifter, Mario Bros.) | 2.0.9: correct speed, but the picture sat low and was cut off at the bottom (224-line display mode). 2.0.10: whole screen shown; colours match comparison screenshots |
| Show Overscan | Before 2.0.10 it shifted the picture down without showing more lines. 2.0.10: fixed for NTSC (242-line modes); Triple Punch's bonus timer shows in full. PAL with it on was still cut off, because a 9th and 10th display mode are more than the Pocket accepts. 2.0.11: PAL ignores the setting (274 lines already show everything); confirmed on hardware |

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

### POKEY music missing? Check the ROM's header

The core maps a POKEY in only where the A78 header says there is one, as
MiSTer does. A dump whose header leaves the POKEY out plays its TIA sound
effects but no POKEY music. Commando did exactly this on hardware until the
dump was replaced with one whose header sets cart type bit 0 (POKEY at
$4000); with that, the music played at once.

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
anywhere under `/Assets/7800/`.

### Firmware files

The core does not include any console or peripheral firmware. These optional
files go in `/Assets/7800/common/`:

| File | What it is | Size | Without it |
|---|---|---|---|
| `7800bios.bin` | Atari 7800 BIOS | 4 KiB (NTSC) or 16 KiB (PAL) | The core skips the BIOS, as it does by default. Only one can be installed: to boot PAL carts through the BIOS use the PAL one, since the NTSC BIOS checks for the signature NTSC carts carry |
| `highscor.rom` or `hsc.a78` | High Score Cartridge firmware: a raw 4 KiB image, or the same with an A78 header | 4 KiB (+128 byte header) | No high score cart, whatever the setting |
| `supercharger.bin` | Starpath Supercharger BIOS | 2 KiB | Supercharger games do not load |

Either HSC file works; use one. `highscor.rom` is the name the A7800 emulator
uses. In `hsc.a78` the header is detected and skipped. If a file holds more
than 4 KiB, the core keeps its last 4 KiB. A MiSTer-style `.hex` image (one byte per line) converts with
`python3 tools/hex2bin.py file.hex > highscor.rom`.

Up to 2.0.6 the high score cart and Supercharger firmware were built into the
core, as they are on MiSTer. From 2.0.7 they are loaded from these files, so
this repository and its releases carry no firmware whose license is unclear.

**History rewrite (2026-09-26).** The first port commit vendored MiSTer's
`rtl/mem4.hex`/`.mif` (High Score Cartridge firmware) and `rtl/ar.hex`/`.mif`
(Starpath Supercharger BIOS). Both are the original makers' code with no
license given, so they were removed from the whole history of the
`Mister-Pocket-Port` branch, not just from its latest commit. Nothing else
changed: every commit keeps its content and message, but has a new hash. A
clone made before that date should be re-cloned, or reset with
`git fetch && git reset --hard origin/Mister-Pocket-Port`. Pocket builds
2.0.0 to 2.0.6 contain both images in their bitstream; please use 2.0.7 or
later.

## Building

Changing the core or updating its parts? Start with
[docs/DEVELOPING.md](docs/DEVELOPING.md): layout, tools, recipes (settings,
data and save slots, PLL, upstream updates) and known pitfalls.

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
- No console or peripheral firmware is included: the 7800 BIOS, the high
  score cart firmware and the Supercharger BIOS are all user-supplied.
- Any remainder should be considered MIT licensed.
The POKEY portion keeps its own license, Mark Watson's terms above: the core
may not be used or sold commercially without his permission.
