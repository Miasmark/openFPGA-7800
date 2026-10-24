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
- 2600 cartridges (`.a26`, `.bin`), with MiSTer's bankswitch auto-detection,
  and from 2.2.1 the ARM-based schemes too (next item).
- **2600 ARM cartridges** (from 2.2.1): DPC+ and the CDF family (CDF, CDFJ
  and CDFJ+), the Harmony and Melody games such as the Champ Games releases.
  On MiSTer they run on a soft ARM7TDMI that doesn't fit the Pocket; this
  port runs them on **DARIA**, ARIA (the BupChip's CPU, below) extended with
  Thumb, at 38.18 MHz from 2.2.4 (36.17 MHz in 2.2.1 and 2.2.2), with its own front end for the
  cartridge's 6507 side ([docs/DARIA_CORE.md](docs/DARIA_CORE.md)). In
  simulation every tested game runs the same ARM code as on MiSTer, call for
  call, with the same picture on every frame after the first. The one
  exception is by design: at the start of Spiders' play, MiSTer is late on 16
  calls in frames 557-572 and stretches those frames, while DARIA is on time
  there, as the project's model of the real cartridge's chip is
  ([docs/HARMONY_MODEL.md](docs/HARMONY_MODEL.md)). A chart sets DARIA
  beside that model, MiSTer's core and lroby74's MiSTer fork
  ([docs/DARIA_CORE.md](docs/DARIA_CORE.md#comparisons-upstream-and-lroby74s-fork)).
  2.2.1 and 2.2.2 were late
  on them, as MiSTer is. Sound effects and music are the
  same writes, landing slightly earlier or later in time (the verification
  table below). Limits: BUS and ELF cartridges are not supported (no
  released game uses BUS); ARM code beyond the first 64 KB of an image halts
  the CPU (no known game has any there; [open item
  5](docs/DARIA_CORE.md#open-items)); and the ARM chip's peripherals beyond
  its timer and memory accelerator, such as a Melody board's optional
  EEPROM, read as zero ([open item 19](docs/DARIA_CORE.md#open-items)).
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
- **FA2 saves** (Star Castle Arcade's high scores, from 2.2.4): the 256 bytes an FA2
  cartridge keeps in its flash go in **one shared file**, `fa2.sav`, beside
  `hsc.sav` and `savekey.sav`. A new file starts blank ($FF), as an erased
  flash. Every FA2 game shares it; Star Castle Arcade is the only one known.
- **AtariVox voice** (the SpeakJet speech chip on port 2), with the SaveKey
  that is the AtariVox's other half: the voice is there whenever the SaveKey
  is on (so 2600 AtariVox games need *SaveKey (port 2)* set to On), and
  *AtariVox Voice* sets its level in the mix (Off, Quiet, Normal, Loud: x4, x8 and x16, Normal about level with the game's sound). It
  is mixed into the core's output, where a real AtariVox has a jack of its
  own. The SpeakJet's sound tables are not published, so the voice is our
  own: a speech engine of our own design built from recordings of the real
  chip ([docs/ATARIVOX.md](docs/ATARIVOX.md)). It reads the same codes, at
  the same lengths, pitches and speeds; the timbre is an approximation.
- An optional BIOS: `7800bios.bin` in `/Assets/7800/common/`. By default the
  core skips it, as MiSTer does. Turn off *Skip BIOS* to boot 7800 games
  through it. Unlike on MiSTer, 2600 games always start directly, without
  the BIOS, whatever the setting: the BIOS recognises a 2600 cartridge by a
  bus clash that the core does not reproduce, so it would miss some 2600
  games and never start them. A 7800 game therefore needs its A78 header:
  an image without one is taken as a 2600 game.
- **The BupChip** (from 2.1.1), the Souper cartridge's music co-processor:
  Rikki & Vikki plays its whole soundtrack. On MiSTer it is firmware running
  on a soft ARM7TDMI; this port runs the same, unmodified firmware on
  **ARIA**, its own small ARM-compatible CPU, with the music in the Pocket's
  PSRAM ([docs/BUPCHIP_CORE.md](docs/BUPCHIP_CORE.md)). It needs two files
  the core can't ship: the BupChip firmware, `bupchip.bin` (see *Firmware
  files*), and the game's `.a78` with its music block appended
  ([docs/BUPCHIP.md](docs/BUPCHIP.md), "Files the user supplies on the
  Pocket", has the tool and the layout). Without either, Souper games run
  without the extra music channel.
- 2600 Starpath Supercharger games (`.bin` tape images, 8,448 bytes a load).
  With the Supercharger BIOS as a file they load as from tape, loading
  screen and all; without it a loader of the core's own loads them in about
  0.1 s ([docs/SUPERCHARGER_FASTLOAD.md](docs/SUPERCHARGER_FASTLOAD.md)).
  The tape keeps its place through a reset, so a compilation tape (Party
  Mix) loads its next game after one.
- Settings (the Pocket shows at most 16, so related ones share an entry):
  - *Difficulty*: both difficulty switches.
  - *Swap Controllers*, *Port 1 Input*, *Port 2 Input*, *Turbo (X/Y)*.
  - *Region*, *Palette* (warm/cool/hot), *High Score Cart*, *SaveKey
    (port 2)*, *AtariVox Voice*, *Skip BIOS*.
  - *Picture*: the border on or off, and *Overscan* (below).
  - *Audio*: Stereo TIA, and a blend of the left and right channels (25%,
    50%, or full mono) for Stereo TIA and stereo carts on headphones.
  - *2600 Video*: Flicker Blend, and De-comb, which smooths the comb
    pattern some 2600 games draw by alternating lines between frames.
  - *Compatibility*: POKEY IRQ (off by default, as on MiSTer; some games
    drive their music from POKEY timer interrupts) and Random RAM (what
    RAM holds at power-on: real hardware starts random, and some homebrew
    seeds its randomness from it).
- PAL games at the real PAL master clock, 14.18758 MHz instead of NTSC's
  14.31818 MHz, so they run at 50 Hz and play at the right pitch. The region
  follows the A78 header (2600 games: their measured frame length) or the
  *Region* setting. As on MiSTer, the PLL is retuned when the region changes,
  which holds the core in reset for a moment; a PAL 2600 game restarts once
  when it is recognised. PAL frames are taller than NTSC ones (274 visible
  lines instead of 224; 288 instead of 240 for the 2600), and the Pocket's
  display mode follows, so nothing is cut off. PAL games need no PAL BIOS
  while *Skip BIOS* is on (the default).
- **Paddles, driving controllers and the light gun**, played with the
  D-pad (or, docked, a controller's left stick). See *Controls* below. The
  A78 header picks them for 7800 games; 2600 games have no header, so set
  *Port 1 Input* / *Port 2 Input* for them (Paddles for Breakout, Kaboom!,
  Warlords; Driving for Indy 500).
- **Dual stick** for Robotron: 2084 and other twin-stick games (MiSTer's
  Robotron mode), the **2600 Booster Grip** (Omega Race, Thrust+), and
  **turbo fire** on X and Y. From 2.0.14.
- The Pocket's **display modes** (CRT and LCD looks, under *Display
  Mode* in the Pocket's video settings). From 2.0.14. The grayscale LCD
  look suits 2600 games played in B&W mode (L toggles it).
- *Overscan* (in *Picture*) shows MARIA's whole NTSC picture: 242 lines instead of
  the 224 most games stay inside (lines 27-250, where 7800basic's 224-line
  screens sit). Games that draw into the overscan, like
  Triple Punch's bonus timer at the bottom, need it. PAL games ignore it:
  their 274-line picture is already complete.

### New in 2.2.4

2.2.4 is 2.2.2 with these additions:

- **DARIA at 38.18 MHz** (36.17 MHz in 2.2.1 and 2.2.2), with a faster
  CPU: aligned Thumb word loads take one clock, and Thumb LDMIA and POP
  without the PC one clock less. In simulation every call of the tested games is
  on time, including Spiders' 16 calls before its first level loads,
  which 2.2.2 and MiSTer's core are late on, so Spiders' picture no longer
  shifts down there. At this clock the front end's shared-edge guard
  locks, so none of its audio reads can race a DARIA store
  ([docs/DARIA_CORE.md](docs/DARIA_CORE.md), decision 7 and open item 7).
  The BupChip runs on the same CPU and clock; its music is unchanged
  (PCM identical to MiSTer's in simulation).
- **FA2 saves**: Star Castle Arcade keeps its high scores, in `fa2.sav`
  (above).
- **PAL regions**: a PAL A78 loaded after a PAL 2600 game on *Region*
  Auto no longer retunes the PLL twice more (to NTSC and back), which
  showed as extra blinks, and a 2600 load that ends on the clock a retune
  ends no longer asks the PLL for the region it just left.
- **About 1,300 fewer ALMs** (79% of the FPGA, from 86%), mostly because
  the paddle and driving controllers' five virtual axes share one engine
  (`virtual_axis5`) and 13 of the core's modules are synthesised with
  Quartus's multiplexer restructuring. Nothing changes in play.

### Not included

| Feature | Why |
|---|---|
| 2600 BUS and ELF cartridges | The core shows its unsupported-cartridge screen for them, as MiSTer does for BUS0. No released game uses BUS. ELF targets a Cortex-M0+ cartridge, which needs another CPU than DARIA ([docs/DARIA_CORE.md](docs/DARIA_CORE.md), decision 6). Up to 2.1.3 every 2600 ARM scheme got this screen. |
| Trackball, keypad, mice | These need input the Pocket doesn't have. Joysticks, paddles, driving controllers and the light gun are emulated (see *Controls*). |
| Composite video filter | Only the RGB output is used. |

#### Why MiSTer's BupChip doesn't fit, and ARIA

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

Running the BupChip on the Pocket needed a much smaller ARM implementation:
**ARIA** ([docs/BUPCHIP_CORE.md](docs/BUPCHIP_CORE.md)), a clean-room,
MIT-licensed ARMv4 core with only what the CoreTone firmware uses. Anything
else halts it rather than running wrongly. It runs the firmware in about
1,810 ALMs at 28.6 MHz, with its music in PSRAM behind a small cache, and
the whole core used 79% of the FPGA in 2.1.1 (86% in 2.2.1 and 2.2.2, with DARIA and the AtariVox voice, and 79% again in 2.2.4).
From 2.2.1 the same CPU, extended with Thumb as **DARIA**, also runs the 2600 ARM cartridges: at 36.17 MHz in 2.2.1 and 2.2.2, and at 38.18 MHz from 2.2.4. In simulation its output matches
MiSTer's bit for bit, and its busiest song (Never_Lose) leaves 19% of its clock to spare.

[docs/BUPCHIP.md](docs/BUPCHIP.md) has the details it started from:
- the firmware's memory map, registers and commands, and the ARSC resource format;
- which ARM features the firmware uses: ARM state only, no Thumb, interrupts,
  SWP or coprocessor, but multiply, yes;
- the CPU load, measured in simulation with Rikki & Vikki's music:
  - up to 89% of MiSTer's 71.6 MHz ARM, about 16 million instructions a second;
  - an average of 4 clocks per instruction, most of it spent waiting on memory.

`sim/bupchip/` holds the tools that build the resource block from a game
install, measure any song, and build a jukebox cartridge that plays any song
on demand (for testing; it carries the game's music, so it stays private).

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
| 2600 frame fills the display mode | 240 active lines NTSC, 288 PAL, matching the scaler modes exactly (from 2.0.19; before, 239 / 285, and the Pocket kept an earlier game's last rows below) |
| 2600 video | 59.92 Hz, 160x240 (MiSTer's "smart" stabiliser window) |
| Audio filter | centred on zero, settles to 0 in silence |
| SaveKey | a test cart writes 8 bytes over I2C with 7800basic's AtariVox/SaveKey driver and reads them back: pass (Auto with a SaveKey header, and On); absent when the header has none |
| SaveKey reads ending in NACK | A read whose last byte is $00, answered with NACK then STOP, leaves SDA released and the STOP seen (`+i2ctrace`). Triple Punch's slot scan decodes cleanly with a zeroed and a blank file |
| SaveKey save slot | 32 KiB written in and read back under the APF read protocol: only the 8 bytes the cart wrote differ |
| HSC save slot | a hardware-written save round-trips with 0 of 2048 bytes different |
| FA2 save slot | a synthetic FA2 cartridge loads the 256-byte `fa2.sav` through the mapper's port, saves it changed and loads it again: 0 bytes wrong in the work RAM and in the slot read back under the APF read protocol, from a saved file and from none (blank $FF). Two A78 games, each run with a saved file, leave it as it was: one that the 2600 mapper detection does not take for FA2, and a test image that it does take for FA2 and that issues a save command (the FA2 port is on only in 2600 mode) |
| Display geometry | Active lines per frame match the display mode: NTSC 224 (MARIA lines 27-250: 7800basic's `screensafe` sample in 224-line mode fills them exactly, from 2.1.3), overscan 242, PAL 274 (overscan setting ignored), 2600 240 / PAL 288. Triple Punch (NTSC and PAL) shows its bonus timer at the bottom with Show Overscan on (NTSC) or always (PAL) |
| Paddles (virtual) | A 2600 test program timing INPT0-3 after the pot dump: all four paddles respond, the D-pad reaches both ends (lines 1 and 191 of 192), X and Y change the speed, A/B press the buttons, and a stick moved on controller 1 takes over (Paddles on both ports) |
| Driving controller (virtual) | SWCHA bits 5:4 step 3, 1, 0, 2 turning right and the reverse turning left; A reads on INPT4 |
| Light gun, both ports (Sentinel) | Sentinel's header asks for a gun on both ports; the gun goes on port 1 (from 2.0.18; before, port 2, aimed from controller 2) |
| Light gun (virtual) | The latched INPT4 goes low on the crosshair's line (104 of 192 centred); off the top of the picture gives no hit; the trigger reads on SWCHA bit 4, with MiSTer's polarity |
| Virtual controller axis | a 16 ms tap moves 1 step of 256; holding crosses the range in 0.5 s (0.26 s with Y); the driving code steps at most every 25 ms (D-pad) or 32 ms (stick) |
| Dual stick, Booster Grip, turbo | Dual Stick: the face buttons fire on port 2 (A right, X up, Y left) and the left stick moves port 1, with the fire buttons off. Booster Grip: X reads on INPT0 as the pot line. Turbo: Y held for 500 ms toggles fire 1 15 times on Fast, 8 on Slow |
| Firmware slots | `highscor.rom` (4 KiB), `hsc.a78` (header skipped; also a 16 KiB payload, last 4 KiB kept) and `supercharger.bin` (2 KiB) land in the ROMs with 0 bytes different; without HSC firmware the HSC stays off even when set On. Triple Punch finds the loaded HSC as it did the built-in one |
| BupChip, end to end (2.1.1) | The firmware slot after the cartridge, as the Pocket loads them, then a game-free Souper cartridge with a synthetic music block: the ROM equals the firmware file, the block's 5,192 bytes are in the PSRAM model with no timing violation, and the song's PCM equals the Python model's frame for frame, as pushed and as returned to the core clock. Without the firmware the same cartridge leaves the BupChip held and silent. `sim/bupchip/` checks the CPU in lockstep with MiSTer's ARM7TDMI and the wrapper with Rikki & Vikki's songs (`s1/check.sh`, `s4/check.sh`) |
| 2600 ARM cartridges, whole core (2.2.1) | The 15 Champ Games demos and Stratovox, 1,500 frames each (frames 1-1,499 compared, 23,984 in all), against MiSTer's core with its ARM7TDMI: frame length, picture and RIOT RAM equal on every frame (the first frame's picture excused on 3 games, whose first call holds the console for a different time), and every ARM call runs the same number of instructions. Spiders is late on the same 16 calls as on MiSTer. The sound is the same writes at slightly other times: 8,928 of the 23,984 frames (37.2%) carry an audio difference, 0 on Elevator Agent and 1,025 on Zaxxon. No CPU halt, no PSRAM timing violation |
| Spiders and Galagon at 38.18 MHz (2.2.4) | The same comparison, 1,500 frames each: Spiders' frames 557-572 stay 262-line frames with no late call, where MiSTer's core is late on 16 calls and draws 354 lines; frame length, picture and RIOT RAM equal on every other frame, every call the same number of instructions (2,999 calls each), and the front end's shared-edge guard locked with 0 unlocks. Galagon passes the same way. The sound is counted, not compared, as in the row above: 678 of Spiders' frames and 285 of Galagon's carry an audio difference. The release campaign ran the full set of 16 images the same way, with the guard locked and Spiders on time: every image passed (on the ÷18 tree before the merge of 2.2.2, whose DARIA side the merge does not change) |
| DARIA's CPU and front end against MiSTer's | Every call of 21 images compared with MiSTer's ARM: registers at return, every RAM write, the audio values. The front end clock by clock beside MiSTer's on 30 images, 1,500 frames each. With DARIA's own CPU at its real clock ratio, 19 runs: every call equal to MiSTer's |
| Everything else unchanged by DARIA (2.2.1) | `run_sim.sh`, `extra_tests.sh` and the 2600 cartridge-RAM matrix give the same frame-by-frame fingerprints with and without DARIA; the BupChip's songs are identical by PCM |
| PAL 2600 game, Region on Auto (2.2.1) | One retune, to PAL, at 955 ms, then the game runs in PAL. With the region logic of 2.1.3 and earlier, the same simulation retuned 41,293 times in 1.3 s and ended in NTSC |
| POKEY reads (2.2.2) | Star Raiders' RANDOM reads, logged in the whole core (`tb_load +cpuprobe`): before the fix 39 of the first 40 were $FF and the game looped for ever on a black screen; after it, $B3 $99 $34 $90 $D1 ..., and the title screen draws. The AtariVox receiver's unit test with the game's first 33 bytes: 31 reach the buffer (the "\V" escape consumed), no false "Ready" |
| AtariVox voice (2.2.1) | `sim/atarivox/run.sh`: bytes sent over the serial line as a game does; every output sample equals the engine emulator's, at the same clock (Juno First's title, all 72 allophones, all effects, speed/bend/pitch steps, serial control's clear and "Ready": about 357,000 samples). Whole core: the retail Juno First speaks its title and "wave one"; the retail Stratovox, under DARIA, clears and says "Ready" as play starts ([docs/ATARIVOX.md](docs/ATARIVOX.md)) |

Pitch is measured to the 5 Hz resolution of the test window. The old core
would read about half these frequencies, an octave down.

The Quartus build of 2.2.4 (fitter seed 2, DARIA's CPU clock at 38.18 MHz)
meets timing on all four corners. Worst setup slack at the worse slow
corner: +3.020 ns on clk_sdram (against a release gate of +1.5 ns),
+1.482 ns on DARIA's CPU clock (gate +0.5 ns), and +3.128 ns on the one
path of DARIA's front end that is timed on its own (its phase detector,
bounded at 8.0 / 0.5 ns), whose hold slack is +0.421 ns. Worst hold slack
+0.095 ns. Seeds 1 and 3 pass every check too, with +2.515 and +2.229 ns
on clk_sdram; seed 2 has the most clk_sdram margin, which decides
(seed 1 has more on DARIA's clock, +2.284 ns, and on hold, +0.109 ns).
It uses 14,639 of 18,480 ALMs (79%), 216 of 308 M10K blocks and 13 DSP
blocks. Before the merge of 2.2.2 the same ÷18 tree gave +2.407, +2.388
and +3.107 ns on clk_sdram, and seed 3 was chosen.
2.2.2 (fitter seed 1, DARIA at 36.17 MHz) had +2.523 ns on clk_sdram,
+1.095 ns on DARIA's CPU clock and +0.086 ns on the phase detector's 6 ns
path (seeds 2 and 3 gave +0.145 and -0.217 ns there), worst hold +0.093 ns,
and used 15,917 ALMs (86%). Its clk_sdram figure is quoted from 2.2.2's
own README, which gave 2.2.1 as +2.433 ns where this tree's record gives
the worse-slow-corner +2.345 ns, so 2.2.2's figure is probably not at the
worse slow corner either; 2.2.2's fit report is not kept with this tree,
so its worse-slow-corner value is not given here.
2.2.1 (fitter seed 2, DARIA at 36.17 MHz) had +2.345 ns on clk_sdram at the
worse slow corner (2.2.2's README gave +2.433 ns for it),
+1.474 ns on DARIA's CPU clock and +0.193 ns on the phase detector, then a
6 ns path (seeds 1 and 3 gave +0.084 and -0.262 ns there), worst hold
+0.082 ns, and used 15,839 ALMs (86%), 212 M10K blocks and 13 DSP blocks;
the AtariVox voice is about 210 ALMs of that (15,839 against DARIA's tree
without the voice, 15,625, both seed 2: [docs/ATARIVOX.md](docs/ATARIVOX.md),
"The full build"), 17 M10K and one DSP.
2.2.1 has Fix B, the structural fix in the SRAM controller: the 2600 mappers'
cartridge-RAM request reaches it through registers of its own, off the
SRAM's request path ([docs/SRAM_TIMING.md](docs/SRAM_TIMING.md)). 2.1.3
had +1.60 ns with 12,909 ALMs (70%) and 78 M10K blocks, 2.1.2 +1.92 ns,
and 2.1.1 +0.44 ns at 79%. From 2.1.2 to 2.1.3 the core left out the
6507-side logic of the ARM cartridge schemes, about 1,750 ALMs and the
slowest leg of that path (Fix A); 2.2.1 puts DARIA's own front end in
their place.
The 2.0.21 build: worst setup
slack +1.32 ns, worst hold +0.06 ns.
Up to 2.0.13 the worst setup slack was about +0.8 ns, on paths from the
loader into the 14.3 MHz core; 2.0.14 registers the loader's output on the
core clock, which gives those paths 10 ns or more (from 2.0.14). 2.0.21
uses 12,834 of 18,480 ALMs (69%) and 46 of 308 M10K blocks: the cartridge
RAM, Flicker Blend frame, SaveKey and BIOS moved to the Pocket's SRAM, and
the In-System Memory Content Editor is gone. 2.0.20 used 75% of the ALMs and
all 308 M10K blocks. The PLL produces the NTSC and PAL master clocks
exactly (14.3181818 and 14.1875800 MHz, to the PLL's 32-bit fraction).

### Hardware testing (2.0.2 to the 2.2.4 candidate, Analogue Pocket)

| Test | Result |
|---|---|
| TIA sound pitch | Correct (the old core's octave-low bug is gone) |
| Midnight Mutants, Commando, Dig Dug sprites | No corruption (holey DMA fix) |
| Ballblazer | A full match played to a win, plus several attract-mode loops: procedural music and goal siren correct. Also a full match with upstream's POKEY and the adapter fix (2.0.21-test); before the fix the music fell to near silence |
| 2600: Solaris, Adventure | Nothing significantly wrong seen |
| Picture position (2.1.3 test build) | Commando without Overscan: the score bar at the very top, with no brown rows of overscan above it (2.1.2 showed 3); with Overscan, unchanged |
| 2600 after Fix A (2.1.2 test build) | Pitfall II (DPC), Crystal Castles, Omega Race and other 2600 games work |
| Commando POKEY music | Works: typing intro, title theme and attract music. Needs a dump whose header flags the POKEY (see below) |
| SaveKey (Triple Punch) | Works from 2.0.8: shows "Save SK", saves, and the high score is back after reloading. 2.0.7 showed "Save ER" (EEPROM model bug on reads, and a zero-filled file); delete an all-zero `savekey.sav` left by older versions |
| Triple Punch, HSC and SaveKey together | Header asks for both (2.0.6): uses the HSC when present, the SaveKey with the HSC off |
| High score cart (Dig Dug, Food Fight) | Works, scores persist, one personalisation for all games (2.0.4, shared `hsc.sav`). From 2.0.7 the firmware comes from the user's file; works with `hsc.a78` |
| Supercharger | With and without `supercharger.bin` (test builds after 2.1.1): Fireball, Frogger, Dragonstomper, and Party Mix and Sweat (their next game after a reset). The first build of the core's own loader left the load number in `$80` and most games crashed; the second leaves the control byte there, as the BIOS does |
| PAL games (Choplifter, Mario Bros.) | 2.0.9: correct speed, but the picture sat low and was cut off at the bottom (224-line display mode). 2.0.10: whole screen shown; colours match comparison screenshots |
| Show Overscan | Before 2.0.10 it shifted the picture down without showing more lines. 2.0.10: fixed for NTSC (242-line modes); Triple Punch's bonus timer shows in full. PAL with it on was still cut off, because a 9th and 10th display mode are more than the Pocket accepts. 2.0.11: PAL ignores the setting (274 lines already show everything); confirmed on hardware |
| Settings menu | 2.0.12 showed only its first 12 entries; 2.0.14 to 2.0.16 refused to load ("Load error in 'interact'"). 2.0.17 loads, all 15 entries shown: 16 entries at most, and the whole menu kept to 49 list options (see docs/DEVELOPING.md) |
| Paddles (Kaboom!, Demons to Diamonds) | Work (2.0.13+). Demons to Diamonds reads the second paddle for player 1: needs *Swap Controllers* |
| Driving controller (Indy 500) | Works (2.0.13+) |
| Light gun (Sentinel) | Works from 2.0.18. Its header asks for a gun on both ports, and before 2.0.18 the gun went to port 2 (controller 2), so the cursor never moved |
| Dual Stick (Robotron: 2084) | Works from 2.0.18. In 2.0.17, three face buttons at once (an opposite pair) stopped the fire stick and corrupted the screen |
| Booster Grip | Works (2.0.14+) |
| Rikki & Vikki (Souper) | Runs, without the BupChip music (2.0.21-test). Needs an A78 header: Jamie Blanks's patch for the Steam ROM |
| Rikki & Vikki with the BupChip (2.1.1 test builds) | All 32 songs, through a jukebox test cartridge, sound as on MiSTer; in PAL they stay on key and at the same pace; the music plays on through a console reset, as on MiSTer; without `bupchip.bin` the game runs silent and unaffected. The debug build's status cells showed the firmware loaded whole (CRC-32 `95b8b4f8`), no capture error, and the music FIFO never below 639 of 1,024 |
| Cartridge RAM with a double frame buffer (2.1.1 test build) | No corruption, after the SRAM controller's power-up values changed |
| Summer Games, Winter Games | Work (2.0.21-test), with a correctly headered dump |
| Crystal Castles (2600) | Works (2.0.21-test) |
| SRAM memories (2.0.21) | BIOS boot, SuperGame and Souper cartridge RAM, SaveKey save and reload, a blank SaveKey, and Flicker Blend all pass, with Watson's POKEY and again with upstream's |
| Upstream POKEY at half level (2.0.21) | Ballblazer, Commando and the earlier POKEY games sound right; Commando no longer loud |
| Display modes | CRT and the three LCD looks all work (2.0.14+) |
| 2600 bottom line | Before 2.0.19 the last line kept whatever an earlier game drew there (after Kaboom!, in every 2600 game); 2.0.19 fills all 240 / 288 lines |
| DARIA's test build (daria-test1, 2026-10-17) | Tested on a Pocket: "everything looks good, tested the library and played the games". The owner checked the sound against YouTube captures of the games, to make sure it was not too noisy. Not completed: a PAL 2600 ARM game on Region Auto, and a PAL A78 after it, because the PAL versions at hand all seem to be PAL60 builds. A PAL60 build draws 262-line frames, which Auto treats as NTSC; Stay Frosty 2's PAL build is one. Simulation covers both. The DARIA status overlay was not built at the time; it has landed since ([docs/daria_step7/progress.md](docs/daria_step7/progress.md), "Step 8: hardware tests of daria-test1 (2026-10-17)") |
| DARIA's known differences seen on hardware (daria-test1) | Spiders: before a level loads, the whole picture shifts down for a couple of frames. The owner ties the shift to the late calls. In simulation the first such overrun is 16 calls in frames 557-572, late on MiSTer's core too; the hardware could not count them then: the DARIA status overlay did not exist yet (it has landed since). From 2.2.4, at 38.18 MHz, these calls are on time in simulation and those frames stay 262 lines, and on the 2.2.4 candidate's debug build the shift is gone (next row). Play does not seem affected: a couple of levels beaten |
| DARIA at 38.18 MHz: the 2.2.4 candidate's debug build (the owner's Pocket session of 2026-10-21) | The RC debug build of the ÷18 tree before the merge of 2.2.2 (seed 3, with the DARIA status overlay). Spiders: "no screen shift", and nothing red on the overlay; the photos show row 0's box 2 green (the shared-edge guard locked) and rows 2 and 3 grey (0 late calls, 0 guard unlocks). The PAL 50 Hz test image: "works as expected", one restart and then PAL, with row 3 "all grey" after the restart. Triple Punch (PAL) loaded after it "did not blink extra or anything": no extra retune, as in the build without DARIA (RTL-1). Rikki & Vikki's BupChip music works (the BupChip and the PSRAM at 38.18 MHz), and Turbo, which reads beyond DARIA's 64 KB window through the PSRAM cache, works. Star Castle Arcade keeps its high score in `fa2.sav` across quitting and reopening the core: "star castle test passed". The merge of 2.2.2 changes none of DARIA's files, but its POKEY read fix and AtariVox escape fix have been tested on 2.2.2's 36.17 MHz build only; on the 2.2.4 candidate itself, Star Raiders, POKEY music and AtariVox speech are still to be tested |
| 2.2.4's debug build of the final tree (the owner's Pocket session of 2026-10-23) | The merged tree (÷18 with 2.2.2's POKEY read fix and AtariVox escape fix), fitter seed 2, with the DARIA status overlay. Checked: Star Raiders (its title, and the AtariVox saying "Star Raiders"), POKEY music (Ballblazer or Commando), Juno First and Stratovox speech, and Spiders' overlay (row 0 box 2 green, rows 2 and 3 grey). The owner: "tests pass". |
| Star Raiders, POKEY reads and the AtariVox escape (2.2.2 test build) | Star Raiders (7800, 2026) shows its title and its AtariVox says "Star Raiders"; Ballblazer or Commando's POKEY music is unchanged; Juno First and Stratovox still speak. Before, it stayed on a black screen: every POKEY read returned $FF (2.0.21 to 2.2.1), and the voice swallowed the game's speech after its "\V" escape (2.2.1) |
| AtariVox voice (2.2.1 test builds) | Clearly says its words at every *AtariVox Voice* level. The first test build mixed it at x1/x2/x4 and it was hard to hear against the TIA even on Loud; from the second, x4/x8/x16 |

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
  near-silent taps and pops with it, so releases up to 2.0.20 kept Watson's.
  The cause, found in simulation: when MARIA's DMA starts right after a
  POKEY write, MARIA's address reaches the new POKEY before it has finished
  sampling the write, and the byte lands in the wrong register. The adapter
  now holds the write (see POCKET_CHANGES.md), and since 2.0.21 the core
  uses the new POKEY, at Watson's output level.

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
The simulation runs the same POKEY as the Pocket build. `POKEY=watson
sim/run_sim.sh` converts Watson's VHDL POKEY with GHDL and uses it instead,
and `sim/run_pokey_shadow.sh` runs the two side by side.

## Controls

| Pocket | Atari |
|---|---|
| D-pad | Joystick |
| A / X | Left button (fire 1); X repeats with *Turbo (X/Y)* on |
| B / Y | Right button (fire 2); Y repeats with *Turbo (X/Y)* on |
| L | Pause (7800) / Colour-B&W (2600) |
| Select | Select |
| Start | Reset |

Paddles, driving controllers and the light gun (the A78 header's choice, or
*Port 1 Input* / *Port 2 Input*):

| Pocket | Paddles | Driving controller | Light gun |
|---|---|---|---|
| D-pad left / right | Turn the knob | Turn the wheel | Move the crosshair |
| D-pad up / down | | | Move the crosshair |
| A or B | Paddle button | Fire | Trigger |
| X (held) | Turn slowly, for fine aim | Turn slowly | Move slowly |
| Y (held) | Turn fast | Turn fast | Move fast |

Movement starts slowly and speeds up the longer the D-pad is held, so a tap
moves a little and a hold crosses the whole range in about half a second
(a quarter of a second with Y).
Docked, a controller's left stick also works: a paddle or the crosshair
follows the stick's position, and a driving controller turns at a speed set
by how far the stick is pushed. The next D-pad press takes over again.

*Port 1 Input* also offers:

- **Dual Stick**, for Robotron: 2084: controller 1 drives both joystick
  ports. The D-pad (or left stick) moves; the face buttons fire in their
  direction on the diamond (X up, B down, Y left, A right), or, docked, the
  right stick. Two diagonal buttons fire diagonally; of two opposite ones
  (X and B, or Y and A) the one pressed last wins, since a real joystick
  can't point both ways.
- **Booster Grip** (2600): A fires, B is the grip's trigger and X its
  booster button.

*Turbo (X/Y)* makes X repeat A's fire 1 and Y repeat B's fire 2 while held
(each sits next to the button it copies on the diamond), at
15, 10 or 7.5 presses a second (Fast / Medium / Slow; 12.5, 8.3 and 6.25
in PAL games). A and B stay single presses.

Some 2600 paddle games read the second paddle of the pair for player 1
(Demons to Diamonds, for one; Stella keeps a "swap paddles" list for
them). If a paddle game ignores the D-pad, turn on *Swap Controllers*.

Paddles come in pairs: the two paddles on port 1 are controllers 1 and 2,
the two on port 2 are controllers 3 and 4 (docked). A driving controller
or the light gun on port 1 is controller 1, on port 2 controller 2. The
light gun draws a red crosshair; aim off the top or bottom of the picture
to shoot off-screen (to reload in some games).

## Installing

Copy the contents of a release zip to the root of the SD card. Carts go
anywhere under `/Assets/7800/`.

### Firmware files

The core does not include any console or peripheral firmware. These optional
files go in `/Assets/7800/common/`:

| File | What it is | Size | Without it |
|---|---|---|---|
| `7800bios.bin` | Atari 7800 BIOS | 4 KiB (NTSC) or 16 KiB (PAL) | The core skips the BIOS, as it does by default. With it, and *Skip BIOS* off, 7800 games boot through the BIOS; 2600 games always start directly, without it. Only one can be installed: to boot PAL 7800 carts through the BIOS use the PAL one, since the NTSC BIOS checks for the signature NTSC carts carry |
| `highscor.rom` or `hsc.a78` | High Score Cartridge firmware: a raw 4 KiB image, or the same with an A78 header | 4 KiB (+128 byte header) | No high score cart, whatever the setting |
| `supercharger.bin` | Starpath Supercharger BIOS | 2 KiB | Supercharger games load through the core's own loader, without the tape loading screen |
| `bupchip.bin` | BupChip firmware (CoreTone), from MiSTer's `bupchip.hex`: `python3 tools/hex2bin.py bupchip.hex > bupchip.bin` ([docs/BUPCHIP.md](docs/BUPCHIP.md)) | 7,824 bytes (CRC32 `95b8b4f8`); up to 16 KiB | Souper games run without the BupChip's music |

The core loads these when it starts. From 2.0.16 they are no longer listed
as "Load" items in the core settings menu: the Pocket shows at most 20
menu rows for settings and reloadable files together, and the firmware
rows were pushing settings off the end. To change one, replace the file
and restart the core.

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
- **POKEY**: the schematic-level POKEY by **Jamie Blanks** (MIT), since
  2.0.21. Releases up to 2.0.20 used **Mark Watson**'s VHDL POKEY, which the
  MiSTer 7800 core used until 2026-08-25; see POCKET_CHANGES.md.
- **Souper** mapper logic by **Osman Celimli**.
- **24LC0x EEPROM** (the SaveKey) by **GreyRogue**, from NES_MiSTer,
  GPL-3.0.
- **Light gun** module (`lightgun.sv`), the one **Sorgelig**'s MiSTer cores
  share; this port drives it from the D-pad.

**Pocket side**

- **Analogue**: the openFPGA APF framework and core template.
- **Adam Gastineau (agg23)**: `data_loader`, `sound_i2s`, `sync_fifo` and
  the PSRAM controller `psram` from
  [analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils)
  (MIT).
- **The BupChip**: **Jamie Blanks**'s design and CoreTone firmware
  (user-supplied); his `bupchip_peripheral.sv` (MIT) runs unmodified beside
  ARIA, this port's own CPU.
- **Spiritualized**: the original 2022 Pocket 7800 core, and the platform
  image and slot layout this port stays compatible with.

**References and tools**

- **Stella**, the 2600 emulator: the driving controller's gray code, the
  per-game "swap paddles" practice, and much of the 2600 behaviour the
  MiSTer core follows.
- **Analogue's openFPGA developer docs**, and **agg23's openFPGA cores**
  (the SNES core's display-mode list was the model for ours).
- **7800basic** by **Mike Saarna (RevEng)** and contributors: the SaveKey
  driver and samples the simulation test carts are built from (CC0).
- **A7800**, whose `highscor.rom` file name this core accepts.
- **Verilator**, **GHDL** and **Intel Quartus Prime Lite**, for simulation
  and builds.
- MiSTer's **ARM7TDMI core** (**Robert Peip**, the GBA_MiSTer contributors
  and **Jamie Blanks**, GPL-2.0): the simulation reference ARIA is checked
  against in lockstep. None of it is in the bitstream.
- **Unicorn**, for the fast firmware model used to measure every song.

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
- Mark Watson's POKEY (`src/fpga/mister/rtl/PokeyWatson/`), built into
  releases up to 2.0.20, is free for non-commercial use; commercial use needs
  his permission. Releases from 2.0.21 use the MIT POKEY instead.
- `src/fpga/apf/`, `core_top.v` and `core_bridge_cmd.v` are Analogue's
  framework and template, under Analogue's terms.
- No console or peripheral firmware is included: the 7800 BIOS, the high
  score cart firmware, the Supercharger BIOS and the BupChip firmware are all
  user-supplied.
- Any remainder should be considered MIT licensed.
Releases up to 2.0.20 contain Mark Watson's POKEY, under his terms above:
those may not be used or sold commercially without his permission.
