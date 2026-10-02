# Third-party components and licenses

This core combines code from several authors under several licenses. The
tables list every third-party part in the repository, its license, and
whether it goes into the bitstream (`atari7800.rbf_r`) that releases ship.
"Built" means synthesised into the bitstream; "repo only" means the file is
vendored with the upstream source but the Pocket build leaves it out.

The complete source for every built part is in this repository, which is
also where the source for a release is published:
https://github.com/Miasmark/openFPGA-7800

## Code

| Component | Path | Author | License | In bitstream |
|---|---|---|---|---|
| Atari 7800 system (MARIA, Sally 6502, TIA, RIOT, cart mappers, Minnie, video/audio) | `src/fpga/mister/rtl/` | Jamie Blanks and contributors | MIT (`src/fpga/mister/LICENSE`) | Built |
| SDRAM controller | `src/fpga/mister/rtl/sdram.sv` | Sorgelig | GPL-3.0-or-later (`LICENSES/GPL-3.0.txt`) | Built |
| JT51 (YM2151) | `src/fpga/mister/rtl/jt51/` | Jose Tejada (Jotego) | GPL-3.0-or-later (`LICENSES/GPL-3.0.txt`) | Built |
| 24LC0x EEPROM (SaveKey) | `src/fpga/mister/rtl/EEPROM_24LC256.sv` | GreyRogue, from NES_MiSTer; adapted upstream | GPL-3.0 (NES_MiSTer's license, `LICENSES/GPL-3.0.txt`) | Built |
| POKEY (schematic-level, `k7800`) | `src/fpga/mister/rtl/Pokey/` | Jamie Blanks | MIT | Built (from 2.0.21) |
| Paddle timing, light gun | `src/fpga/mister/rtl/paddles.sv`, `lightgun.sv` | Jamie Blanks (`paddles.sv`); `lightgun.sv` has no header and matches the light-gun module in Sorgelig's MiSTer cores | MIT with the rest of the MiSTer 7800 repository; `lightgun.sv` may also be under those cores' GPL (`LICENSES/GPL-3.0.txt`) | Built (from 2.0.13) |
| Souper mapper | `src/fpga/mister/rtl/souper.v` | Osman Celimli | zlib-style (file header) | Built |
| SN76489 | `src/fpga/mister/rtl/SN76489/` | Jamie Blanks | MIT | Built |
| `data_loader`, `sound_i2s`, `sync_fifo` | `src/fpga/pocket_utils/` | Adam Gastineau (agg23) | MIT (`src/fpga/pocket_utils/LICENSE`) | Built |
| APF framework | `src/fpga/apf/` | Analogue | Analogue's APF Software License Agreement (file headers); `mf_*.v` also carry the Intel Program License | Built |
| PLL and PLL reconfiguration IP (generated) | `src/fpga/core/pll/` | Intel | Intel Program License (file headers): for use with Intel devices | Built |
| Core template glue (`core_top.v`, `core_bridge_cmd.v`) | `src/fpga/core/` | Analogue, modified for this port | Analogue's APF terms | Built |
| Pocket wrapper, audio filter, POKEY adapter, PLL setup, sim, tools | `src/fpga/core/`, `sim/`, `tools/` | this project | MIT (`LICENSE`) | Built (HDL) |
| Video mixer | `src/fpga/mister/rtl/video_mixer_plus.sv` | Alexey Melnikov (Sorgelig) | GPL | Repo only |
| ARM7TDMI core | `src/fpga/mister/rtl/arm7tdmi/arm7tdmi_core.sv` | Robert Peip / Jamie Blanks | GPL-2.0-only | Repo only |
| T65 | `src/fpga/mister/rtl/t65/` | Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll | BSD-style (file headers) | Repo only |
| Watson POKEY | `src/fpga/mister/rtl/PokeyWatson/` | Mark Watson | Own terms: free for non-commercial use; commercial use needs his permission. See the file headers | Repo only (built up to 2.0.20; simulation) |

The 6502 assembler test programs in `sim/` pull in 7800basic's
`i2c7800.inc` at build time. It is not stored here; 7800basic's includes are
CC0.

## Embedded ROM images

The bitstream contains these images from the MiSTer core (MIT):

| Image | Path | What it is |
|---|---|---|
| `mem0.mif` | `src/fpga/mister/rtl/` | The MiSTer core's "no cartridge" screen |
| `ooo.mif` | `src/fpga/mister/rtl/` | The MiSTer core's "unsupported cartridge" screen |
| palettes | `src/fpga/mister/rtl/palettes/` | 7800 colour palettes |

No console or peripheral firmware is included. The MiSTer core builds in the
High Score Cartridge firmware (`mem4`) and the Starpath Supercharger BIOS
(`ar`), which are the original makers' code with no license given. This port
removes both from the repository and builds with `EXTERNAL_FIRMWARE`, which
loads them at run time from the user's own `highscor.rom` (or `hsc.a78`)
and `supercharger.bin`, as it already did for the 7800 BIOS.

## Platform files

`dist/Platforms/7800.json` and `dist/Platforms/_images/7800.bin` come from
Spiritualized's 2022 Pocket 7800 core, which this core replaces.
`dist/Cores/Miasmark.7800/icon.bin` is the placeholder from Analogue's core
template.

## Notices shipped with releases

`tools/package.sh` puts these in `Cores/Miasmark.7800/licenses/` in every
release zip: this project's `LICENSE`, this file, `GPL-3.0.txt`, the MiSTer
core's `LICENSE`, analogue-pocket-utils' `LICENSE`, and Analogue's APF
Software License Agreement (`Analogue-APF-Software-License.txt`), copied
word for word from its source header. Releases up to 2.0.20, which built
Mark Watson's POKEY, also carried his notice (`PokeyWatson-NOTICE.txt`).

## References

No code from these is included, but the port's behaviour follows them:
Stella (2600 driving controller gray code, paddle swapping), Analogue's
openFPGA documentation, and agg23's openFPGA cores (the `video.json`
display-mode list). The simulation's test carts use 7800basic's includes
(CC0), fetched at test time.

## POKEY

Since 2.0.21 the bitstream builds upstream's MIT POKEY (`rtl/Pokey`).
Mark Watson's POKEY, still in `rtl/PokeyWatson` for simulation and built
into releases up to 2.0.20, keeps its own license: free for non-commercial
use, and commercial use or sale, in source or binary form, needs his
permission (scrameta at gmail). That applies to those releases and to any
bitstream built with it.
