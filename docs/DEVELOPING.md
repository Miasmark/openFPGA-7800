# Developing the Atari 7800 Pocket core

This guide is for anyone who wants to change the core or update the parts
it's built from. It covers where things live, how to build and test, how to
make the common changes, and the mistakes this port has already made so you
don't repeat them.

Related documents:

- [ENVIRONMENT.md](ENVIRONMENT.md): setting up a fresh container (tools,
  Quartus in Docker, simulators, where data lives, every bench and its
  command, working conventions and pitfalls).
- [AGENT_RUNS.md](AGENT_RUNS.md): running long multi-agent work here
  (poll at most every 4 minutes, restarts and resuming, simulation slots,
  disk).
- [IMPROVEMENTS.md](IMPROVEMENTS.md): improvements found but left for a
  later release (a guard that works at ÷19, S3, a cartridge EEPROM, the
  `src/` clean-ups after 2.2.1), each with what it would fix and its cost.
- [HARMONY_MODEL.md](HARMONY_MODEL.md): the bench's model of a real Harmony
  cartridge's chip (LPC2103), a second timing reference for the 2600 ARM
  calls beside MiSTer's core: the settings per game, its limits, and the
  owner's rule for using it.
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
| `src/fpga/core/bupchip/` | The BupChip, ARIA: the Souper cartridge's music co-processor, its memories, asset cache and PSRAM path ([BUPCHIP_CORE.md](BUPCHIP_CORE.md)); with `POCKET_DARIA`, DARIA, the same CPU running the 2600 ARM cartridges: `daria_*.sv` (memories, call port, MMIO, sample requester, the front end `daria_fe*.sv`) and `bup_dbg_snap.sv` ([DARIA_CORE.md](DARIA_CORE.md)) | This project |
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
| `NO_ARM_MAPPER` | Upstream's: leaves out the ARM7TDMI (2600 DPC+/CDF), which doesn't fit. With `POCKET_DARIA` those cartridges run on DARIA instead. |
| `NO_BUPCHIP` | Leaves out upstream's BupChip player (an ARM7TDMI with its assets in DDR3). Doesn't fit; see [BUPCHIP.md](BUPCHIP.md). |
| `POCKET_BUPCHIP` | The Pocket's own BupChip, ARIA (`core/bupchip/`, [BUPCHIP_CORE.md](BUPCHIP_CORE.md)), in its place: `top.sv` exports the `$8007` command and takes the audio back; the firmware comes from the `bupchip.bin` data slot, the music from the cartridge file's ARSC block, kept in PSRAM `cram0`. Needs `NO_BUPCHIP`. |
| `POCKET_DARIA` | DARIA ([DARIA_CORE.md](DARIA_CORE.md)), on since 2.2.1: the 2600 ARM cartridges (DPC+, CDF, CDFJ, CDFJ+) on the BupChip's CPU extended with Thumb, at VCO/19 (36.17 MHz), with its own front end (`daria_fe`) in place of upstream's left-out one. Its own `QIP_FILE core/daria.qip` and `SDC_FILE core/daria_constraints.sdc` lines follow in `ap_core.qsf` ("Timing constraints"). Needs `POCKET_BUPCHIP` and `NO_ARM_MAPPER`. |
| `BUP_DEBUG` | Hardware test builds only: the BupChip's status word, shadow FIFO counters, and its status cells over the picture's top-left corner while a Souper cartridge runs (`core/bupchip/bup_status_osd.sv`). Off in releases. |
| `NO_DDRAM` | Leaves out the DDR3 bridge. The Pocket has no DDR3. |
| `EXTERNAL_FIRMWARE` | HSC firmware and Supercharger BIOS loaded from files, not built in. |
| `EEPROM_NACK_ENDS_READ` | SaveKey EEPROM fix: a NACK ends a sequential read. |
| `POCKET_SRAM` | Cartridge RAM, Flicker Blend frame, SaveKey and BIOS in the SRAM (`core/sram_ctrl.sv`), no "no cartridge" screen. Needs `EXTERNAL_CARTRAM`. On since 2.0.21. |
| `EXTERNAL_CARTRAM` | Upstream's: cartridge RAM from `top.sv`'s `cartram_*` ports. |
| `NO_MEM_EDITOR` | No In-System Memory Content Editor on `spram` memories. On since 2.0.21. |
| `POCKET_SUPERCHARGER` | The Supercharger tape keeps its place through a reset, and without `supercharger.bin` the core's own loader loads games straight from the file ([SUPERCHARGER_FASTLOAD.md](SUPERCHARGER_FASTLOAD.md)). Needs `EXTERNAL_FIRMWARE`. |

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
setup and hold slacks must be positive (in the DARIA build, one setup path
aside: the front end's guard pair, which at ÷19 is reported, not gated; see
"Regenerate the PLL"). A negative slack with a PLL clock
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
(`POCKET_BUPCHIP`, `BUP_DEBUG`) and DARIA (`POCKET_DARIA`) included, and
puts a PSRAM model (`sim/bupchip/s4/psram_model.sv`) on `cram0`. The
testbenches run `clk_arm` as the PLL does: at VCO/19 (36.17 MHz) on its
lattice with `clk_sys` in the DARIA build (`tb_load.sv`'s `arm_div`, 19 by
default), and at 2 x `clk_sys` without DARIA. `DARIA=0` or `DARIA=1`
overrides the qsf's setting, and `ARM_DIV=18` runs the DARIA build at
VCO/18 (38.18 MHz), the divider before 2026-10-12. The DARIA build adds a
game-free DARIA section: three synthetic ARM images in the whole core.
With the user's firmware at `src/fpga/mister/rtl/bupchip.hex` (gitignored; [BUPCHIP.md](BUPCHIP.md)) it also runs the BupChip end to end in
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

Follow "Updating" in `src/fpga/mister/POCKET_CHANGES.md`, but re-apply the
Pocket changes to all eleven modified upstream files: `top.sv`, `cart.sv`,
`cart2600.sv`, `banks2600.sv`, `EEPROM_24LC256.sv`, `Maria/DMA.sv`,
`Maria/video_sync.sv`, `video_mux.sv`, `TIA.sv`, `bram.v` and
`Pokey/pokey_adapter.sv`. POCKET_CHANGES.md's own summary counts eight and
its "Updating" list names six, which would drop the TIA window fix, the
SRAM frame port, the memory-editor removal and the POKEY write hold; its
sections describe all eleven. It is under `src/`, which stays as verified
for 2.2.1, so it is corrected after 2.2.1
([daria_step7/record.md](daria_step7/record.md), "After 2.2.1: `src/`
clean-ups"). Then:

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
The tool writes a scratch file, never the tree's `pll_core.v`, which holds
two settings (below). From the repository root, for the `POCKET_DARIA`
setting, C3 = 19 (`sim/work/` is not tracked):

```sh
mkdir -p sim/work/pll/c19
docker run --rm -v "$PWD/sim/work/pll/c19:/out" raetro/quartus:21.1 bash -c 'cd /tmp &&
 ip-generate --remove-qsys-generate-warning --project-directory=/tmp --output-directory=/tmp/pll_core \
  --file-set=QUARTUS_SYNTH --component-name=altera_pll --output-name=pll_core \
  --system-info=DEVICE_FAMILY="Cyclone V" --system-info=DEVICE=5CEBA4F23C8 --system-info=DEVICE_SPEEDGRADE=8_H6 \
  --component-parameter=gui_device_speed_grade=8 --component-parameter=gui_pll_mode="Fractional-N PLL" \
  --component-parameter=gui_reference_clock_frequency=74.25 --component-parameter=gui_operation_mode=direct \
  --component-parameter=gui_fractional_cout=32 --component-parameter=gui_dsm_out_sel=1st_order \
  --component-parameter=gui_en_reconf=true --component-parameter=gui_number_of_clocks=4 \
  --component-parameter=gui_output_clock_frequency0=14.318181 --component-parameter=gui_output_clock_frequency1=57.272727 \
  --component-parameter=gui_output_clock_frequency2=14.318181 --component-parameter=gui_ps_units2=degrees \
  --component-parameter=gui_phase_shift_deg2=90.0 --component-parameter=gui_output_clock_frequency3=36.172249 \
  --component-parameter=gui_en_adv_params=true \
  --component-parameter=gui_multiply_factor=9 --component-parameter=gui_frac_multiply_factor=1100363522 \
  --component-parameter=gui_divide_factor_n=1 --component-parameter=gui_divide_factor_c0=48 \
  --component-parameter=gui_divide_factor_c1=12 --component-parameter=gui_divide_factor_c2=48 \
  --component-parameter=gui_divide_factor_c3=19 \
  --component-parameter=gui_pll_auto_reset=Off &&
 cp /tmp/pll_core/pll_core.v /out/'
```

`pll_core.v` holds two settings, selected by `ifdef POCKET_DARIA`: C3 = 19
(VCO/19, 36.172249 MHz) for DARIA, and C3 = 24 (28.64 MHz, 2 × `clk_sys`)
otherwise. Each is the tool's output for its C3; only the selection is by
hand. ÷19 is DARIA's divider since 2026-10-12: at C3 = 18 (38.18 MHz)
`clk_arm` missed setup on one of three seeds, with or without fitter
padding ([daria_step7/plan.md](daria_step7/plan.md) 5.2). To regenerate,
run the command once as above and once with `gui_divide_factor_c3=24` and
`gui_output_clock_frequency3=28.636363` into `sim/work/pll/c24`. Diff each
against the tree's file. At C3 = 19 eight lines differ from C3 = 24's:
counter 3's (`output_clock_frequency3`, `c_cnt_hi_div3(10)`,
`c_cnt_lo_div3(9)`, `c_cnt_odd_div_duty_en3("true")`) and four display
strings, which the tool prints slightly lower for the same M, N, K and
C0-C2: `output_clock_frequency0` and `2`, 14.318180 against 14.318181 MHz;
`output_clock_frequency1`, 57.272722 against 57.272724 MHz; and
`pll_output_clk_frequency`, the VCO, 687.272644 against 687.272687 MHz.
(`pll_core.v`'s header comment calls this "one digit lower", which holds
for C0 and C2 alone; it is corrected after 2.2.1.)
Copy those lines into the matching `ifdef` branch, the C3 = 19 output under
`POCKET_DARIA` and the C3 = 24 output in its `else`; the rest of the tree's
file, the selection and the explanatory header comment included, stays as
it is. Copying a whole generated file over it would drop the selection,
and a build without DARIA would then run `clk_arm` at the other setting.
`sim/bupchip/quartus_probe/step7/step7_prep.py --tree-div` reads which
output the `POCKET_DARIA` view is (18, 19 or 24, from all eight values),
and the step-7 gate `divider` (`sim/check/div_check.py`) holds every
bench's and gate's default divider to it. With advanced parameters on, the
tool takes the counters from the `gui_divide_factor_*` values; the
frequency strings it writes are computed from them. C3 = 18 (38.181818 MHz)
is generated the same way and differs from C3 = 24 in counter 3's lines
alone.
The reconfiguration controller (`pll/pll_cfg/`) comes from
`--component-name=altera_pll_reconfig --output-name=pll_cfg`.

The PLL has four outputs: `clk_sys` (C0 = 48), `clk_sdram` (C1 = 12),
`clk_sys_90` (C2 = 48, 90 degrees) and `clk_arm`, the BupChip's CPU
([BUPCHIP_CORE.md](BUPCHIP_CORE.md), "Clocking"): C3 = 19 (VCO/19,
36.17 MHz) with `POCKET_DARIA` ([DARIA_CORE.md](DARIA_CORE.md), decision 7),
otherwise C3 = 24 (2 × `clk_sys`, 28.636 MHz, ARIA). The clock plan has four
rules:

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
  `clk_sys` is timed. At C3 = 24 its edges are `clk_sys`'s; at C3 = 19 they
  meet every 19 `clk_sys` (48 `clk_arm`; at C3 = 18 every 3 `clk_sys`), and
  every crossing is a synchroniser with held data, bounded at ±20 ns in
  `core/daria_constraints.sdc`. Its 48 kHz pop runs from `clk_74a`.
  `psram.sv`'s `CLOCK_SPEED` is 50.0 under `POCKET_DARIA` and 28.636364
  otherwise: it sets the controller's read and write state sequence, and
  50.0 adds a clock after `oe_n` falls ([DARIA_CORE.md](DARIA_CORE.md),
  7.4); it is the value for both C3 = 18 and 19. A retune scales `clk_arm`
  with the rest (in PAL, 28.375 MHz at C3 = 24 or 35.842 MHz at C3 = 19)
  and holds the BupChip. `pll_region.v` writes only the fraction and the
  start register, so C3 is kept.
- Two DARIA-only fitter settings come with C3 = 19, both for daria_fe's
  shared-edge guard pair `u_guard|pd_tog` → `pd_rx`, which the Timing
  Analyzer holds to 6 ns setup and 1 ns hold
  ([daria_fe/design.md](daria_fe/design.md) 8.2-8.3). `core/daria_sync.tcl`
  ends with `ROUTER_REGISTER_DUPLICATION OFF`: the router copied the pair's
  registers for routability in 8 of 12 step-7 fits, which breaks the single
  path the guard's checks need, and Quartus 21.1 takes the router's
  duplication settings only globally (a per-instance form stops the
  compile). It applies to DARIA builds only, since `daria.qip` sources the
  file. And `core/daria_constraints.sdc`'s fitter-only block asks the
  fitter for 5.5 ns on the pair (a `set_max_delay` read only by
  `quartus_fit`), 0.5 ns under the 6 ns that the Timing Analyzer checks:
  without it one of three ÷19 seeds missed the window by 0.109 ns, through
  clock skew. The rung does not close the window at ÷19. On the shipping
  tree the fitter reached 5.5 ns on none of the six fits that had it, and
  seed 3 still misses 6 ns, by 0.046 ns at slow 85 °C (Q5 seed 3: 0.060
  ns). The window there is set by the clock skew between corners and the
  1 ns hold bound, not by placement. At ÷19 the guard cannot lock whatever
  this path's delay, so the window guards no function, and the step-7
  checks report the pair's setup slack without gating on it
  ([daria_step7/plan.md](daria_step7/plan.md) 5.4 (a) and (l), the lead's
  decision of 2026-10-14). A negative `clk_sys` setup slack on
  `pd_tog` -> `pd_rx` alone is therefore not a timing failure at ÷19;
  `sim/bupchip/quartus_probe/step7/step7_checks.py` judges it (it passes
  only when it is the only failing `clk_sys` endpoint and `pd_rx`'s only
  fan-in is `pd_tog`). Any other negative slack is. 2.2.1's fit, seed 2,
  meets the 6 ns as well (+0.193 ns; [README](../README.md), "Verification").

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
- The SRAM's cartridge / BIOS byte (`sram|c_rdata`) into `clk_sys` is a
  2-cycle path; with Fix B a 2600 byte has no `clk_sdram` to spare against
  it (the comment above the lines has the budget).
- A fitter-only block asks the fitter, not the Timing Analyzer, for 1.5 ns
  more setup into `clk_sdram` and 0.1 ns more hold into `clk_sys` and from
  `clk_sys` into `clk_sdram`.

DARIA (`POCKET_DARIA`) adds two files through its own lines in
`ap_core.qsf`, so that a build without it reads exactly the constraints
above: `core/daria_constraints.sdc` (an `SDC_FILE` line after the
`QIP_FILE` lines, so it is read after the PLL clocks exist), which bounds
the `clk_sys` <-> `clk_arm` crossings at ±20 ns and holds the front end's
phase detector pair (`pd_tog` -> `pd_rx`) to 6 / 1 ns (the header comment
of `core_constraints.sdc` says that with DARIA the edges meet "only every
3 `clk_sys`": that is VCO/18's lattice, stale since ÷19, and it is
corrected after 2.2.1; at VCO/19 they meet every 19 `clk_sys`); and
`core/daria.qip`, which marks the first flop of each synchroniser that
shares its declaration `SYNCHRONIZER_IDENTIFICATION FORCED`, bit by bit.
The marks are in `core/daria_sync.tcl`, which `daria.qip` sources
(`SOURCE_TCL_SCRIPT_FILE`): Quartus refuses that assignment in a qip
itself and stops Analysis & Synthesis (it tags a qip's assignments with
`-qip`, an option this one does not take).
DARIA's new files mark theirs in the RTL, on scalar first stages. Padding for
the DARIA build alone goes in `daria_constraints.sdc`'s own fitter-only
block, never in `core_constraints.sdc`, which then stays the same in both
builds. A later `set_clock_uncertainty` on a clock transfer replaces the
earlier one rather than adding to it (the last line wins, setup and hold
each on their own; `-add` adds to the derived uncertainty only), so a line
there states the total padding for the transfers it names, 2.0 ns into
`clk_sdram` for 0.5 ns more than `core_constraints.sdc`'s 1.5, and names
no other transfer.

The tightest path is on `clk_sdram`: the cartridge-RAM request from MARIA
or the 6502, through the mappers and `sram_ctrl`'s arbiter, into the SRAM's
pad registers. Its margin moves with placement (+1.60 ns in 2.1.3, +1.92 in 2.1.2,
+0.44 in 2.1.1, +1.32 in 2.0.21). [SRAM_TIMING.md](SRAM_TIMING.md) has the path and two fixes; Fix B
([DARIA_CORE.md](DARIA_CORE.md), "Fix B") registers the 2600 mappers'
request, which leaves the 7800's in that cone. The release gate is +1.5 ns
on each of seeds 1, 2 and 3. DARIA's verified tree (`317eaa8`), with Fix B,
gives +2.462, +2.683 and +2.919 ns on seeds 1-3, and its worst
`clk_sdram` paths are Flicker Blend's half-period paths in `sram_ctrl`.
2.2.1 adds the AtariVox voice to that tree, with DARIA's RTL unchanged,
and ships the AtariVox build's own seed-2 fit: `clk_sdram` +2.345 ns. The
[README](../README.md) ("Verification") has its other figures, and
[ATARIVOX.md](ATARIVOX.md) the voice build's seeds.

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

Current use (2.2.1, with DARIA and the AtariVox voice, fitter seed 2) is
15,839 of 18,480 ALMs (86%) and 212 of 308 M10K blocks (README,
"Verification"). DARIA's verified tree, without the voice, used
15,600-15,625 ALMs (85%), 195 M10K blocks and 1,767-1,770 of 1,848 LABs
over seeds 1-3, with a peak interconnect use of 60.4-60.8%. Its ALM count is
77-102 ALMs over the 84% that DARIA's design took as a guide, which
triggers nothing ([daria_step7/record.md](daria_step7/record.md),
"The fits").
DARIA's 64 KB image window (64 M10K), its 32 KB of cart RAM (32) and the front ends' 32 KB
copy of the image's start (32) take most of the M10K. The firmware ROM
(16) is ARIA's, already in 2.1.3's 78 M10K.
The cartridge RAM, Flicker Blend frame, SaveKey and BIOS live in the SRAM
(`core/sram_ctrl.sv`, whose header has the memory map); 2.0.21, without
the BupChip, used 69% ALMs and 46 M10K, and 2.1.3, with the BupChip,
12,909 ALMs (70%) and 78 M10K. Fix B took the 2600 mappers' leg off the
`clk_sdram` path, so its worst paths are now Flicker Blend's half-period
paths in `sram_ctrl` (into `fbn_*` on seeds 1 and 2 of DARIA's verified tree,
from `fbn_addr` on seed 3). They still depend on placement: `core_constraints.sdc` asks the
fitter alone for 1.5 ns of extra setup margin there, and `ap_core.qsf` sets
the fitter seed, one already fitted on the release tree. Its comment still
gives 2.1.1's seeds and margins (+0.26, +0.44 and +0.28 ns at 79%), with
the AtariVox build's seeds after them since 2.2.1; the 2.1.1 part is
corrected after 2.2.1. The verified tree's seeds 1, 2 and 3 gave `clk_sdram`
+2.462, +2.683 and +2.919 ns, and seed 2 was kept as the only one that
passed every step-7 check as first written
([daria_step7/plan.md](daria_step7/plan.md) 5.2, P12). After any change,
check the `clk_sdram` slack again on seeds 1, 2 and 3; the release gate is
+1.5 ns at the worse slow corner on each ([DARIA_CORE.md](DARIA_CORE.md),
"Fix B", 5). Up to 2.0.20 all
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
   In the DARIA build at ÷19 the front end's guard pair (`pd_tog` ->
   `pd_rx`) is reported, not gated ("Regenerate the PLL"); run
   `sim/bupchip/quartus_probe/step7/run_step7.sh` for the step-7 checks.
4. Bump `core.json`'s version. Update README (features, verification table,
   hardware results) and POCKET_CHANGES.md for any upstream change.
   Hardware test builds keep the version they were built from.
5. New third-party files: add them to THIRD_PARTY_NOTICES.md, keep their
   headers, and check that `tools/package.sh` ships their license text.
6. No ROMs, BIOS or firmware images committed.
7. Hardware-test anything the sim can't model (SDRAM, PLL, video, saves)
   and record the result in the README's hardware table.
