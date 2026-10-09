# Developing the Atari 7800 Pocket core

This guide is for anyone who wants to change the core or update the parts
it's built from. It covers where things live, how to build and test, how to
make the common changes, and the mistakes this port has already made so you
don't repeat them.

Related documents:

- [ENVIRONMENT.md](ENVIRONMENT.md): setting up a fresh container (tools,
  Quartus in Docker, simulators, where data lives, every bench and its
  command, working conventions and pitfalls).
- [README.md](../README.md): features, installing, credits, test results.
- [src/fpga/mister/POCKET_CHANGES.md](../src/fpga/mister/POCKET_CHANGES.md):
  every change made to the vendored MiSTer sources, and how to update them.
- [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md): every component and
  its license.

## Layout

| Path | What it is | Who owns it |
|---|---|---|
| `src/fpga/apf/` | Analogue's APF framework (`apf_top.v` is the real top level) | Analogue; don't edit |
| `src/fpga/core/core_top.v` | APF glue: PLL, bridge address map, settings, data slots, video/audio out, controllers | This project (from Analogue's template) |
| `src/fpga/core/atari7800_pocket.sv` | Pocket counterpart of MiSTer's `Atari7800.sv`: header parsing, reset, SDRAM, BIOS/save RAMs, SaveKey, firmware loading | This project |
| `src/fpga/core/bupchip/` | The BupChip, ARIA: the Souper cartridge's music co-processor, its memories, asset cache and PSRAM path ([BUPCHIP_CORE.md](BUPCHIP_CORE.md)) | This project |
| `src/fpga/core/pll/` | Generated PLL and PLL-reconfiguration IP | Quartus `ip-generate` (see below) |
| `src/fpga/core/pll_region.v` | PAL/NTSC PLL retune sequence | This project |
| `src/fpga/core/audio_filter.sv`, `pokey_adapter_watson.sv` | Audio conditioning; Watson POKEY wrapper (simulation only since 2.0.21) | This project |
| `src/fpga/mister/rtl/` | The MiSTer Atari7800 core, vendored | Upstream; change only as POCKET_CHANGES.md records |
| `src/fpga/pocket_utils/` | agg23's data loader, I2S, FIFO, PSRAM controller | agg23 (MIT) |
| `dist/` | SD card layout: `Cores/Miasmark.7800/*.json`, platform files | This project |
| `sim/` | Verilator/GHDL simulation and test carts | This project |
| `tools/` | Packaging and file utilities | This project |

`src/fpga/ap_core.qsf` holds the device, the file list (through
`core/core.qip`) and the build macros:

| Macro | Effect |
|---|---|
| `NO_ARM_MAPPER` | Upstream's: leaves out the ARM7TDMI (2600 DPC+/CDF). Doesn't fit. |
| `NO_BUPCHIP` | Leaves out upstream's BupChip player (an ARM7TDMI with its assets in DDR3). Doesn't fit; see [BUPCHIP.md](BUPCHIP.md). |
| `POCKET_BUPCHIP` | The Pocket's own BupChip, ARIA (`core/bupchip/`, [BUPCHIP_CORE.md](BUPCHIP_CORE.md)), in its place: `top.sv` exports the `$8007` command and takes the audio back; the firmware comes from the `bupchip.bin` data slot, the music from the cartridge file's ARSC block, kept in PSRAM `cram0`. Needs `NO_BUPCHIP`. |
| `BUP_DEBUG` | Hardware test builds only: the BupChip's status word, shadow FIFO counters, and its status cells over the picture's top-left corner while a Souper cartridge runs (`core/bupchip/bup_status_osd.sv`). Off in releases. |
| `NO_DDRAM` | Leaves out the DDR3 bridge. The Pocket has no DDR3. |
| `EXTERNAL_FIRMWARE` | HSC firmware and Supercharger BIOS loaded from files, not built in. |
| `EEPROM_NACK_ENDS_READ` | SaveKey EEPROM fix: a NACK ends a sequential read. |
| `POCKET_SRAM` | Cartridge RAM, Flicker Blend frame, SaveKey and BIOS in the SRAM (`core/sram_ctrl.sv`), no "no cartridge" screen. Needs `EXTERNAL_CARTRAM`. On since 2.0.21. |
| `EXTERNAL_CARTRAM` | Upstream's: cartridge RAM from `top.sv`'s `cartram_*` ports. |
| `NO_MEM_EDITOR` | No In-System Memory Content Editor on `spram` memories. On since 2.0.21. |

Macros belong in the `.qsf`, never in a `.qip` (Quartus rejects them there).
`sim/run_sim.sh` passes the same set with `-D`; keep the two lists in step.

## Tools

| Tool | Version | Notes |
|---|---|---|
| Quartus Prime Lite | 21.1 | Docker image `raetro/quartus:21.1`; CI uses it. |
| Verilator | 5.040 | 5.020 is too old for the upstream sources. |
| GHDL | 4.x | Converts Watson's VHDL POKEY to Verilog, for `POKEY=watson` and the shadow comparison. |
| Python 3 | any recent | Packaging and sim helpers; numpy/Pillow for some sim scripts. |
| dasm, 7800basic | built by `sim/extra_tests.sh` | Test carts. |

## Build

```sh
cd src/fpga && quartus_sh --flow compile ap_core
cd ../.. && tools/package.sh            # release/Atari7800_Pocket_<version>.zip
```

In Docker:

```sh
docker run --rm -v "$PWD:/build" -w /build/src/fpga raetro/quartus:21.1 \
  quartus_sh --flow compile ap_core
```

After every build, check `src/fpga/output_files/ap_core.sta.summary`. All
setup and hold slacks must be positive. A negative slack with a PLL clock
name you don't recognise usually means the constraints no longer match the
clock names (see "Timing constraints").

The version is `core.json` → `core.metadata.version`. `package.sh` reads it,
bit-reverses the `.rbf` into `atari7800.rbf_r`, copies the license files into
`Cores/Miasmark.7800/licenses/`, and zips `dist/`.

CI (`.github/workflows/build.yml`) runs the same compile with `docker run`
on the GitHub runner. Don't run the job inside the Quartus container itself:
the container's glibc is too old for the Node.js runtime that
`actions/checkout` needs.

## Simulation

```sh
sim/run_sim.sh          # whole-core tests; a few minutes
sim/extra_tests.sh      # game-style tests with 7800basic carts; needs run_sim.sh first
sim/bupchip/run_bupchip.sh GAME.a78 SONG   # BupChip CPU load; see BUPCHIP.md
SRAM=0 WORK=sim/work_bram sim/run_sim.sh   # the block RAM build, as up to 2.0.20
POKEY=watson sim/run_sim.sh               # Watson's POKEY instead of upstream's
BUP_DEBUG=0 sim/run_sim.sh                # the BupChip without its debug status (a release build)
BUPCHIP=0 WORK=sim/work_nobup sim/run_sim.sh   # without the Pocket BupChip, as up to 2.0.21
```

`run_sim.sh` builds the same macros as the qsf, the BupChip
(`POCKET_BUPCHIP`, `BUP_DEBUG`) included: the testbenches run `clk_arm` at
2 x `clk_sys` and put a PSRAM model (`sim/bupchip/s4/psram_model.sv`) on
`cram0`. With the user's firmware at `src/fpga/mister/rtl/bupchip.hex`
(gitignored; [BUPCHIP.md](BUPCHIP.md)) it also runs the BupChip end to end in
the whole core: the firmware through its data slot after the cartridge, as
the Pocket loads them, a Souper test cartridge
(`sim/souper_test.py`, the synthetic ARSC block appended) whose 6502 program
sends a command through `$8007`, and the song's PCM compared with the Python
model's. Without the firmware that part is skipped. The BupChip's own
benches are in `sim/bupchip/` (its `s4/check.sh` runs the wrapper's).
`sim/bupchip/run_jukebox.sh` plays the hardware-test jukebox
(`sim/bupchip/jukebox.py`) the same way, pressing joystick 1 from a script
(`tb_load.sv`'s `+joyscript`) and checking each command, the PCM and the
screen.

`run_sim.sh` converts the POKEY with GHDL, copies the few upstream files
Verilator can't parse into `sim/work/patched/` (initialised `wire` arrays
become `logic`), builds two testbenches, and runs them:

- `tb_system`: built-in test image. TIA pitch, frame geometry, 2600 mode.
- `tb_load`: loads files through the real APF data loader. This is the
  testbench to use for anything cart-related (and the BupChip's slot).
- `tb_pll_region`, `tb_audio_filter`, `tb_virtual_axis`: unit tests.

What the sim does **not** model:

- The SDRAM chip and Sorgelig's controller. `sim_stubs.sv` answers reads on
  the next clock.
- The PLL, and therefore PAL/NTSC retuning. `tb_pll_region` tests only the
  control sequence.
- Analogue's scaler and I2S output.

Something that fails only on hardware is most likely in one of those.

`tb_load` options (`+name` or `+name=value`):

| Option | Does |
|---|---|
| `image=FILE` | Cart to load (`.a78` or a raw 2600 image) |
| `audf=N` | Expected TIA tone for the pass/fail pitch check |
| `wav=MS` | Run MS milliseconds and record `audio_raw.pcm` / `audio_filt.pcm` (48,052 Hz, 16-bit) |
| `fire` | Press fire at 300 ms for 100 ms (with `wav`) |
| `dump=N`, `dumpat=MS` | Write N frames as `frame_NNN.ppm` (at MS into a `wav` run) |
| `hsc_on`, `hsc_off` | High Score Cart setting |
| `hscfw=FILE`, `arfw=FILE` | Load HSC firmware / Supercharger BIOS through their slots |
| `bupfw=FILE`, `bupfwlast` | Load the BupChip firmware (`bupchip.bin`) through its slot (`0x109`) and check its ROM; before the cartridge, or after it with `bupfwlast` (the Pocket's order) |
| `bupms=MS`, `bupout=PREFIX`, `bupdumpat=MS` | Run MS ms after the load with the BupChip watched and print `BUPCHIP` lines (status, FIFO health, the ARSC block in the PSRAM model); write its PCM as `PREFIX.pcm` / `PREFIX.out.pcm`; with `+dump=N`, dump frames MS into the run |
| `save=FILE` | Preload a 2 KiB `hsc.sav`, check it survives |
| `sk_on`, `sk_auto` | SaveKey setting (default Off) |
| `sksave=FILE`, `skcheck` | Preload/check the SaveKey image |
| `pokeyirq` | POKEY IRQ setting on |
| `pokeylog` | Every POKEY write to `pokey_writes.txt` |
| `i2ctrace`, `i2craw_from/_to=MS` | Decode the SaveKey I2C bus; dump raw lines |
| `refreshstat` | SDRAM refresh coverage per 64 ms |
| `port1=N`, `port2=N` | Port Input setting: 0 auto, 1 joystick, 2 paddles, 3 driving, 4 light gun, 5 dual stick, 6 Booster Grip |
| `turbo=N` | Turbo (X/Y): 0 off, 1 fast, 2 medium, 3 slow |
| `inputtest` | Scripted controller test for `input_test.py`'s image (below) |

`input_test.py` builds a 2600 image that reads the ports every frame the
way paddle, driving and light-gun games do. With `+inputtest`, `tb_load`
presses buttons on a script and prints what the program read:

```sh
python3 sim/input_test.py > sim/work/input_test.a26
cd sim/work && ./obj_load/vtb +image=input_test.a26 +inputtest +port1=2 +port2=2
```

Firmware files and commercial ROMs are never stored in this repository.
`extra_tests.sh` builds its carts from 7800basic samples, and fetches
MiSTer's firmware images from GitHub at test time.

## Recipes

### Update the MiSTer core

Follow "Updating" in `src/fpga/mister/POCKET_CHANGES.md`. Then:

1. Add any new upstream source files to `core/core.qip` **and** `sim/run_sim.sh`.
2. Run `sim/run_sim.sh` and `sim/extra_tests.sh`. `extra_tests.sh` catches
   the holey DMA regression.
3. Build, and check timing and resource use (see "Resource budget").
4. Check `rtl/Pokey/pokey_adapter.sv` still holds the CPU's write through
   phase 2 and halves the level (POCKET_CHANGES.md): an upstream update to
   that file would drop both.
5. Check any new file's license header and update THIRD_PARTY_NOTICES.md.

### Add a menu setting

A setting passes through four places. Keep them in step:

**Menu limits (Analogue's interact.json docs):** at most 16 entries
from `interact.json` are shown, and interact entries plus user-reloadable
data slots (parameter bit 0 in `data.json`) may total at most 20; past
that, entries are dropped silently from the end. A list may have 16
options, and names at most 23 characters. Lists don't count against the
entry limit per option, so prefer one list over several checkboxes.

This bit the port twice: 2.0.12 (18 entries plus 5 reloadable slots)
showed only the first 12 entries (to Stereo TIA), and 2.0.14 (21 entries)
failed to load. From 2.0.16 only the cartridge slot is reloadable; the BIOS
and firmware slots (fixed filenames, loaded at start) are 0x88, not 0x89.

One more limit, found on hardware and not in the docs: the **total number
of list options** across the menu. 2.0.12's menu (51 options) loads;
2.0.16's (16 entries, 69 options) failed with "Load error in 'interact'",
although each half of it loaded on its own (28 and 41 options). 2.0.17 has
15 entries and 49 options. Stay at or under 51 until a larger count is
proven on hardware. The 2600 bankswitch override (address `0x2A0`, still
decoded by the core) was dropped from the menu to fit. A new setting has to share an entry: a
list whose value sets several `set_*` registers at once (see the combined
addresses `0x2B0`-`0x2C0` in `core_top.v`). Give a changed entry a new
`id`, so a value the Pocket saved for the old one isn't applied to it.

1. `dist/Cores/Miasmark.7800/interact.json`: a new `id`, and an `address` in
   `0x10000200`–`0x100002FF` (the next free one is `0x100002C4`).
2. `core_top.v`: a `set_*` register with the same default as
   `interact.json`, and a `case` entry for the address.
3. `core_top.v`: widen `set_s1`/`set_s2` (the clk_74a → clk_sys
   synchroniser) and wire the new bit into `atari7800_pocket`. The bit
   positions in `set_s1` and in the port list must match.
4. `atari7800_pocket.sv`: a port, and the logic that uses it.

The Pocket writes settings only after the data slots have loaded (see
below). Anything the Pocket decides while loading can't depend on a
setting.

### Add a data slot (a file the Pocket loads)

1. `data.json`: append the slot. **Never reorder existing slots.** The core
   refers to slots by their position in the list (the data slot table index)
   and by ID. Give it a bridge address with a top nibble of 0 (the data
   loader only passes `0x0xxxxxxx`), e.g. the next free `0x0C000000`.
2. `core_top.v`: a `SLOT_*` ID, a synchronised `*_download` flag in the
   clk_sys block next to `bios_download`, and include it in the loader's
   `ioctl_wr` gate.
3. `atari7800_pocket.sv`: hold the core in reset while it loads (the `reset`
   register), and write `ioctl_dout` at `ioctl_addr` where it belongs.
4. Test through `tb_load` with the same bridge write pattern.

### Add a save slot (a file the Pocket keeps)

Follow the HSC and SaveKey pattern exactly. Every item below is a bug this
port has already had:

1. Use `save_ram_dp` (in `atari7800_pocket.sv`). It includes the **APF read
   latch**. The host reads with a one-transaction lag: it samples
   `bridge_rd_data` a few cycles after setting the address, then pulses
   `bridge_rd`, and expects the word latched at the previous pulse. Answering
   with the current address rotates the saved file by 4 bytes (2.0.2–2.0.3
   HSC saves; `tools/fix_hsc_save.py` repairs them).
2. Report the slot's size in the data slot table (`core_top.v`, the
   `dt_sel` rotation, address `index * 2 + 1`), as a **constant**. The Pocket
   reads the size before it writes the settings, so a size that depends on a
   setting is wrong when it matters. A size of 0 can make it drop or
   truncate the file.
3. Give it its own bridge region (`0x20000000` HSC, `0x30000000` SaveKey; the
   next is `0x40000000`) and add it to the `bridge_rd_data` mux.
4. Decide what a new, blank file should hold. The FPGA's RAM powers up as
   zeros. A real SaveKey is blank as `$FF`, so `save_ram_dp` has a `BLANK`
   parameter. A zero-filled SaveKey broke Triple Punch.
5. `data.json`: `"nonvolatile": true`, a fixed `filename` for a file shared
   by every cart, `"parameters": "0x80"`.
6. Test a round trip in `tb_load` using the read-lag protocol (see the
   `+save` and `+sksave` code).

### Regenerate the PLL

`src/fpga/core/pll/` is generated. Don't edit the parameter list by hand.
From the repository root:

```sh
docker run --rm -v "$PWD/src/fpga/core/pll:/out" raetro/quartus:21.1 bash -c 'cd /tmp &&
 ip-generate --remove-qsys-generate-warning --project-directory=/tmp --output-directory=/tmp/pll_core \
  --file-set=QUARTUS_SYNTH --component-name=altera_pll --output-name=pll_core \
  --system-info=DEVICE_FAMILY="Cyclone V" --system-info=DEVICE=5CEBA4F23C8 --system-info=DEVICE_SPEEDGRADE=8_H6 \
  --component-parameter=gui_device_speed_grade=8 --component-parameter=gui_pll_mode="Fractional-N PLL" \
  --component-parameter=gui_reference_clock_frequency=74.25 --component-parameter=gui_operation_mode=direct \
  --component-parameter=gui_fractional_cout=32 --component-parameter=gui_dsm_out_sel=1st_order \
  --component-parameter=gui_en_reconf=true --component-parameter=gui_number_of_clocks=4 \
  --component-parameter=gui_output_clock_frequency0=14.318181 --component-parameter=gui_output_clock_frequency1=57.272727 \
  --component-parameter=gui_output_clock_frequency2=14.318181 --component-parameter=gui_ps_units2=degrees \
  --component-parameter=gui_phase_shift_deg2=90.0 --component-parameter=gui_output_clock_frequency3=28.636363 \
  --component-parameter=gui_en_adv_params=true \
  --component-parameter=gui_multiply_factor=9 --component-parameter=gui_frac_multiply_factor=1100363522 \
  --component-parameter=gui_divide_factor_n=1 --component-parameter=gui_divide_factor_c0=48 \
  --component-parameter=gui_divide_factor_c1=12 --component-parameter=gui_divide_factor_c2=48 \
  --component-parameter=gui_divide_factor_c3=24 \
  --component-parameter=gui_pll_auto_reset=Off &&
 cp /tmp/pll_core/pll_core.v /out/'
```

Then put back the explanatory header comment at the top of `pll_core.v`.
The reconfiguration controller (`pll/pll_cfg/`) comes from
`--component-name=altera_pll_reconfig --output-name=pll_cfg`.

The PLL has four outputs: `clk_sys` (C0 = 48), `clk_sdram` (C1 = 12),
`clk_sys_90` (C2 = 48, 90 degrees) and `clk_arm` (C3 = 24, 2 x `clk_sys`,
28.636 MHz: the BupChip's CPU, ARIA; [BUPCHIP_CORE.md](BUPCHIP_CORE.md),
"Clocking"). The clock plan has four rules:

- `clk_sdram` must be exactly 4 × `clk_sys`, from the same VCO and
  edge-aligned. The data loader holds each byte for four `clk_sdram` cycles
  so every `clk_sys` consumer sees exactly one write, and the SDRAM result
  timing assumes it.
- The TIA needs its 7.16 MHz enable (2 × colour clock), which MARIA derives
  from a 14.318 MHz `clk_sys`. The old Pocket core's octave-low sound is what
  a wrong TIA rate sounds like.
- PAL retunes only the fractional multiplier `K`: `clk_sys = 74.25 × (9 +
  K/2³²) / 48` MHz. NTSC `K = 1100363522` (14.3181818 MHz), PAL
  `K = 737741760` (14.1875800 MHz). If you change M, N or the dividers,
  recompute both values (`pll_region.v`) so they share the integer M.
  Adding or changing a C counter alone (as C3 was added) leaves M, N and
  both values as they are.
- `clk_arm` comes from the same VCO, so every BupChip crossing to and from
  `clk_sys` is timed. Its 48 kHz pop runs from `clk_74a`, and `psram.sv`
  keeps `CLOCK_SPEED = 28.636364` whatever the divider; a retune scales
  `clk_arm` with the rest (28.375 MHz in PAL) and holds the BupChip.

### Change the PAL/NTSC switch

`pll_region.v` runs on `clk_74a` (not a PLL output). It never retunes while a
data slot is loading, because the A78 header's region byte arrives
mid-download and stopping `clk_sdram` then would drop bytes. It raises
`busy` about 3.4 µs before starting and drops it about 3.4 µs after the PLL
relocks. `busy` resets the core through `atari7800_pocket.sv`.
`sim/tb_pll_region.sv` checks all of this against a model of Intel's
controller. Only hardware can confirm the PLL itself retunes.

A 2600 image's region is measured from its frame length. The core reset
from a retune clears that measurement, so `atari7800_pocket.sv` latches it
(`tia_pal_seen`) until the next cart load. Without the latch a PAL 2600 game
would flip back to NTSC and loop.

## Video modes

The Pocket scales each frame with a *scaler mode* from `video.json`, and the
core picks one per frame by sending its index in `rgb[23:13]` after active
video (`core_top.v`, `video_slot`). A mode's height must match the number of
lines the core actually outputs. A shorter mode shows the top of the frame
and cuts the rest, which is how PAL games and *Show Overscan* first looked.

| Slot | Size | Used for |
|---|---|---|
| 0 / 1 | 372×224 / 320×224 | NTSC 7800, with / without border |
| 2 | 160×240 | NTSC 2600 |
| 3 / 4 | 372×274 / 320×274 | PAL 7800 |
| 5 | 160×288 | PAL 2600 |
| 6 / 7 | 372×242 / 320×242 | NTSC 7800, Show Overscan |

All eight slots are in use, and 8 appears to be the Pocket's limit. A
9th and 10th mode (372×292 and 320×292 for PAL with overscan) were ignored
on hardware, so PAL games were cut off again, although the simulation
showed the right number of lines. That's why PAL now ignores *Show
Overscan*. To add a mode, first free a slot.

MARIA's windows come from `Maria/video_sync.sv` (`vblank_ex` normally,
`vblank` with overscan). The 2600's come from the TIA stabiliser in `TIA.sv`
and follow its own PAL detection, not the Region setting. Aspect ratios keep
the NTSC modes' pixel shape (320×224 is 4:3) and scale it for PAL by the
pixel clock ratio and by 242.5/287.5 visible TV lines.

`sim/tb_system.sv` measures the active lines and pixels of each frame
(`+pal`, `+overscan`, `+hide_border`, `+mode2600`, `+long`). Check it after
any change to the video path.

## Timing constraints

`src/fpga/core/core_constraints.sdc` refers to the PLL outputs by name. The
reconfigurable PLL names them
`ic|pll|altera_pll_i|cyclonev_pll|counter[N].output_counter|divclk`
(0 = `clk_sys`, 1 = `clk_sdram`, 2 = `clk_sys_90`, 3 = `clk_arm`). The earlier fixed PLL
used `general[N].gpll~PLL_OUTPUT_COUNTER|divclk`. If the names stop
matching, the clock groups and multicycle paths silently stop applying and
timing fails by several nanoseconds. Check the "Clocks" table in
`ap_core.sta.rpt`.

Other constraints already in the file:

- The four PLL outputs are one synchronous group. `clk_74a`, `clk_74b` and
  `bridge_spiclk` are asynchronous to it.
- SDRAM read data to `clk_sys` is a 2-cycle path (as in MiSTer's SDC).
- The data loader's address and data into `clk_sys` have a hold multicycle
  (they are held for ten `clk_sdram` cycles around the strobe).

The tightest path is on `clk_sdram`: the cartridge-RAM request from MARIA
or the 6502, through the mappers and `sram_ctrl`'s arbiter, into the SRAM's
pad registers. Its margin moves with placement (+0.44 ns in 2.1.1, +1.32 in
2.0.21). [SRAM_TIMING.md](SRAM_TIMING.md) has the path and two fixes.

## Resource budget

(Timing: read setup slack, not the smallest number in
`ap_core.sta.summary`, which is usually a hold slack. Hold slack only has
to stay positive, and the fitter keeps it so. Setup slack is the margin
that shrinks as logic is added: +2.8 ns in 2.0.14, limited by the loader's
FIFO on clk_74a. Anything the loader's bytes feed now starts from a clk_sys
register in `core_top.v`; keep it that way.)

The Cyclone V 5CEBA4 has 18,480 ALMs and **308 M10K blocks**. Block count,
not bit count, is the usual limit. The fitter can fail at 75% of the RAM
*bits* because every memory rounds up to whole blocks.

Current use (2.0.21) is 69% ALMs and 46 of 308 M10K blocks: the cartridge
RAM, Flicker Blend frame, SaveKey and BIOS live in the SRAM
(`core/sram_ctrl.sv`, whose header has the memory map). With the BupChip
(`POCKET_BUPCHIP` and `BUP_DEBUG`, the first test build) it is 79% ALMs
(14,595), 86 M10K blocks and 95% of the LABs. At that fill the worst
`clk_sdram` path (MARIA and 2600 mapper address into `sram_ctrl`'s pad
registers) depends on placement: `core_constraints.sdc` asks the fitter alone
for 1 ns of extra setup margin there, and `ap_core.qsf` sets the fitter seed
that gave the best result (3, +1.26 ns). After any change, check the
`clk_sdram` slack again and try other seeds if it drops below +1.0 ns. Up to 2.0.20 all
308 blocks were in use (75% ALMs), and a 16 KiB diagnostic RAM did not fit.
The SRAM's last 16 KiB (words 0x1E000-0x1FFFF) is free.
Before adding memory, check the M10K count in `ap_core.fit.summary`.
Upstream memories that the Pocket build instantiates but can't use (ARM
mapper tables, CDF jump table) are candidates to remove behind a macro if
room is needed.

Quartus is stricter than Verilator in one way that has bitten this port: a
register assigned in two `always` blocks is an error in Quartus ("multiple
constant drivers") but only a warning in the sim.

## Pocket (APF) specifics worth knowing

- **Load order.** On core start the Pocket loads every data slot in
  `data.json` order, then writes the `interact.json` settings, then releases
  reset. The Pocket writes the settings after loading, so the core can't
  consult them while loading.
- **Bridge reads lag one transaction.** See "Add a save slot".
- **Data slot table.** Word `2 * index + 1` is a slot's size. The Pocket
  reads it to decide how much of a save to write back.
- **Debug log.** Turning on the Pocket's developer debug logging writes
  `APF Debug Log` text files showing which files each slot loaded and their
  sizes. Ask testers for one whenever loading or saving misbehaves.
- **Power-up values.** Give a register its power-up value in an `initial`
  block or on an internal declaration (`logic x = 1'b0;`), never on an
  output port (`output logic x = 1'b0`, `output reg x = 0`). Quartus 21.1
  ignores the latter without a warning, and with Power-Up Don't Care (on by
  default) picks the level itself. A flag that is only ever set then becomes
  a constant 1: the BupChip's three capture flags did, and lit test1's and
  test2's red boxes on every load. Simulation honours the initializer, so
  only the map report's "Registers Removed During Synthesis" shows it.
  `run_sim.sh` refuses such declarations in `src/fpga/core`. Leaving a
  register with no power-up value at all is sometimes right: `pll_region.v`'s
  `cfg_address` and `cfg_writedata` are read only with `cfg_write`, and
  free power-up lets Quartus prune the PLL reconfiguration core to the two
  registers it writes; giving them one costs about 550 ALMs.
- **A78 headers.** The core maps POKEY, RAM and save devices only as the
  header declares, as MiSTer does. Many dumps have wrong headers. Check the
  header before debugging the core. Commando's "missing music" was a bad
  header on one copy.

## Before a release

1. `sim/run_sim.sh` and `sim/extra_tests.sh` pass.
2. `BUP_DEBUG` is out of `ap_core.qsf` (it is for hardware test builds), and
   `BUP_DEBUG=0 sim/run_sim.sh` passes.
3. The build meets timing on every corner. Note the ALM and M10K numbers.
4. Bump `core.json`'s version. Update README (features, verification table,
   hardware results) and POCKET_CHANGES.md for any upstream change.
   Hardware test builds keep the version they were built from.
5. New third-party files: add them to THIRD_PARTY_NOTICES.md, keep their
   headers, and check that `tools/package.sh` ships their license text.
6. No ROMs, BIOS or firmware images committed.
7. Hardware-test anything the sim can't model (SDRAM, PLL, video, saves)
   and record the result in the README's hardware table.
