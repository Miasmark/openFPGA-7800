# ARIA (BupChip), step 4: the Pocket wrapper in simulation

Step 4 of `docs/BUPCHIP_CORE.md`: the wrapper, memories, asset path and PSRAM around the S1 core, in simulation. Nothing here is built into the core yet; step 5 integrates it. This README has one section per layer: the PSRAM layer, then the wrapper layer (with the cache).

## Running everything

```sh
sim/bupchip/s4/check.sh sim/work/bupchip/game/rv.a78   # every check: 28 of 28, 53 minutes with JOBS=3
sim/bupchip/s4/check.sh                                # without the game: 16 of 16 (PSRAM, cache, stress, game-free system runs), about 30-40 minutes
```

`check.sh` runs up to `JOBS` (default 3) jobs at once, niced, with work files in `sim/work/bupchip/s4` (`WORK` overrides; the stress benches in `$WORK/stress`, the logs of the PSRAM, cache and stress jobs in `$WORK/logs`). Verilator is `/opt/verilator-5.040` if present (`VERILATOR` overrides); the PSRAM layer and `stress/run_tick.sh` also need iverilog, and `stress/run_bounds.sh` and `stress/run_pophead.sh` arm-none-eabi-gcc. The firmware comes from the user's `src/fpga/mister/rtl/bupchip.hex` (gitignored), turned into `$WORK/bupchip.bin` by `tools/hex2bin.py` and loaded through the firmware slot's path (FWSTART, FWWRITE, FWEND), never with `$readmemh`. Without it only the PSRAM layer, the cache and the firmware-free stress benches run, and a game argument is an error. With a game, `REFDIR` (default `sim/work/bupchip/ref`, whatever `WORK` is) must hold `song<N>.pcm` for songs 13, 14 and every song in `SONGS`; `check.sh` stops with exit 2 before starting anything if one is missing. Game data and everything made from it (PCM, logs) stay in `$WORK`, which git ignores.

| `check.sh` job | Needs | Passes when |
|---|---|---|
| PSRAM layer (`run_psram_ctl.sh`) | iverilog | 23 of 23 (below) |
| Asset cache (`run_cache.sh`) | — | 48 of 48 runs (`WAYS` 1 and 2 × 8 configurations × 3 seeds) pass every directed check (scenario G, the tag sweep, included; H1–H4 with two ways) and the random streams, the 24 with one way in lockstep with the step 4 cache; 35 of 35 mutations of the cache are caught (11 per `WAYS`, 13 more of the second way) |
| Stress: the cache (`stress/run_cstress.sh`) | — | 52 of 52 runs (26 per `WAYS`) and 30 of 30 mutations (`stress/README.md`) |
| Stress: the download path (`stress/run_capstress.sh`) | — | 22 of 22: random downloads, the firmware slot straight after a cartridge, byte 0 in the clock the firmware download starts, synchronous and asynchronous `clk_arm`; the fast loader and a 12.2 MHz `clk_arm` must raise `lost` and `overrun` |
| Stress: the 48 kHz tick (`stress/run_tick.sh`) | iverilog | 18 of 18 |
| Stress: the asset window's bounds (`stress/run_bounds.sh`) | arm-none-eabi-gcc | 11 of 11 |
| Stress: the PCM FIFO's head and the mute (`stress/run_pophead.sh`) | arm-none-eabi-gcc | 6,000 single pushes into the empty FIFO, every frame once and in order, with ticks held on real collisions, one forced; a FAULT write after frame 3,051 silences every later frame; wrappers without `tick_hold` or without the mute fail |
| Synthetic ARSC: song 0 for 2 s, and every write value through the watermark remap (`+wmsweep`) | firmware | PCM identical to `../model/armemu.py`'s, as pushed and as returned to `clk_sys`; the remap equals the formula for all 8,192 values at 0x18 |
| Synthetic ARSC with an odd-length block and a 7,827-byte firmware file | firmware | Both tails written; PCM identical |
| Synthetic ARSC, three reloads: the Souper image, the image without its Souper bit (held and silent for 20 ms), then the Souper image (`+holdfill +holdstep=2`) | firmware | The first two holds come during fills with a read in flight, one with the halfword arriving and one with `psram.sv` mid-access; PCM identical after the third |
| Stress: reloads of blocks with other contents (`stress/run_reload.sh`) | firmware | 5 of 5, PCM identical to the model's for the last block |
| Synthetic ARSC: download and boot with `clk_arm` at 1.5 × `clk_sys` in PAL (21.281 MHz) | firmware | Every capture message arrives, the PSRAM equals the file, fault 00 |
| Not a Souper cartridge; no firmware; a 4-byte firmware file | firmware | Held and silent: 0 retired, 0 pushed, every frame out 0 |
| Songs 13, 14, 9, 30 for 4 s | game | PCM identical to MiSTer's `song<N>.pcm` (both streams), 0 underflow, 0 overflow, lowest level ≥ 600 |
| Song 13: three reloads (the game; the game without its ARSC block, held and silent; the game), `+holdfill +holdstep=2` | game | Two holds during fills with a read in flight, one with the halfword arriving and one mid-access; PCM identical after the last |
| Song 13 after a PAL retune (`+holdfill +holddelay=2`) | game | The hold during a fill, mid-access; PCM identical at 28.375 MHz |
| Song 14 with `clk_arm` at 21.281 MHz (1.5 × `clk_sys`, PAL) | game | PCM identical; 0 underflow; lowest level ≥ 600 |
| Song 13 with the loader at 174.6–250 ns per byte; without pre-emption; with the throttle at 13/16; across a 20 ms pause | game | PCM identical, levels as above; no pop and silence while paused |
| The game without its ARSC block | game | Held and silent |

`bup_cpu.sv` is not part of step 4 and did not change (`git diff 1bc151f -- src/fpga/core/bupchip/bup_cpu.sv` is empty), so `../s1/check.sh` was not re-run. Run it whenever `bup_cpu.sv` changes.

## PSRAM layer

agg23's `psram.sv`, vendored unmodified, drives one die of the Pocket's `cram0` PSRAM. This layer is that file, a model of the chip that checks its timing, and the tests that tie the two together. The wrapper's system testbench builds the same pair (`build_s4.sh`, `PSRAM=real`).

### Running

```sh
sim/bupchip/s4/run_psram_ctl.sh      # every check below: 23 of 23, about 1.5 min on one core
OPS=100000 VOPS=1000000 sim/bupchip/s4/run_psram_ctl.sh   # longer random runs
# one run by hand (iverilog), e.g. 21.281 MHz with reads 26.98 ns later than the datasheet:
iverilog -g2012 -o sim/work/bupchip/s4/psram/ctl.vvp -P tb_psram_ctl.CLK_MHZ=21.281 \
    src/fpga/pocket_utils/psram.sv sim/bupchip/s4/psram_model.sv sim/bupchip/s4/tb_psram_ctl.sv
vvp -n sim/work/bupchip/s4/psram/ctl.vvp +psram_extra_ps=26980
```

Work files go to `sim/work/bupchip/s4/psram` (`WORK` overrides). Verilator is `/opt/verilator-5.040` if present (`VERILATOR` overrides). No game data and no firmware are needed.

| File | What it is |
|---|---|
| `src/fpga/pocket_utils/psram.sv` | agg23's asynchronous PSRAM controller, vendored unmodified (see "Provenance") |
| `psram_model.sv` | One Pocket PSRAM chip (AS1C8M16PL-70: two dies of 4M × 16, `ce0_n`/`ce1_n`) in the asynchronous mode `psram.sv` uses. It runs a timing check on every edge, has a stress knob for late read data, and has a backdoor. It runs in iverilog and in Verilator (`--timing`). |
| `tb_psram_model.sv` | Self-test of the model, driven pin by pin: correct cycles must pass and read back, each check must fire alone on a cycle that breaks its rule, and the backdoor must load, compare and dump a file |
| `tb_psram_ctl.sv` | `psram.sv` (`CLOCK_SPEED` = 28.636364) driving the model with random reads and writes on both dies, at any clock (`CLK_MHZ`). It checks every access clock by clock against the port contract below, and checks the data against its own shadow. |
| `run_psram_ctl.sh` | All of the above, plus stress runs, runs that must fail, and mutations |

### Provenance and caveats of `psram.sv`

- **Source.** https://github.com/agg23/analogue-pocket-utils, `ip/mem/psram.sv`. Last changed upstream in `56391c11` (2022-09-09, "Added MIT license to the top of each IP file"). It is unchanged at `78482d1b` (2023-08-10), the upstream HEAD when it was vendored.
- **Identity.** It is byte-identical to that file: git blob `2f7797f3`, sha256 `199f9f32…0402`. `run_psram_ctl.sh` checks the sha256 first.
- **Licence.** MIT, "Copyright (c) 2022 Adam Gastineau" in its header. That is the same notice as `src/fpga/pocket_utils/LICENSE`, which already covers agg23's other files there. `THIRD_PARTY_NOTICES.md` lists it in the agg23 row.
- **`` `MAX``, `` `CEIL`` and `rtoi`.**
  - `psram.sv` defines `` `CEIL`` and `` `MAX`` at file scope and never undefines them (`:29-30`).
  - It declares `function integer rtoi` in the compilation unit (`:25-27`).
  - `data_loader.sv:61` defines the same `` `MAX``, inside its module. Neither iverilog 12 nor Verilator 5.040 (`-Wall`) warns about that, in either file order. Quartus 21.1 does not warn either (step 5's map report; docs/BUPCHIP_CORE.md, "Controller").
  - Nothing else in `src/fpga` defines `rtoi` or `` `CEIL``. A future file that does will clash: Verilator shares one `$unit` across all files.
- **Real-to-integer conversion.**
  - `` `CEIL`` passes a real to `rtoi`'s integer argument and relies on the real-to-integer conversion, which rounds. Verilator `-Wall` reports this as 30 REALCVT warnings.
  - At `CLOCK_SPEED` = 28.636364 every ratio's fraction is below 0.5, so rounding and truncation give the same numbers. Both simulators print the same states: write 1 2 3 4, read 20 21 22 23 (`tb_psram_ctl.sv`'s summary line).
- **Upstream's other `-Wall` lint** is harmless:
  - PROCASSINIT ×11 (initialised output regs);
  - UNUSEDPARAM ×2;
  - UNUSEDSIGNAL `cram_wait`;
  - WIDTHEXPAND on the `case`.
- **Power-up.** `busy`, `read_avail`, `data_out` and `cram_a` have no initial value. They are X until the first clock edge in a four-state simulator.

### Port contract of `psram.sv` (for the wrapper)

Valid only with `CLOCK_SPEED` = 28.636364, whatever the clock is (28.636, 21.477 or 21.281 MHz). Edge e is the rising edge that accepts the request.

| Port | Contract |
|---|---|
| `clk` | `clk_arm`. There is no reset and no abort. An accepted access always takes exactly 5 clocks. |
| `write_en`, `read_en` | Levels, sampled on every rising edge. An access starts at edge e if the controller is idle and either is high. If both are high, the write wins. **Idle ⇔ `busy` low**, so the client makes its own acknowledge: `ack = (write_en \| read_en) & ~busy`, from the registered `busy`. A request seen at an edge while busy is ignored. A request still high at e+5 starts a second access: drop it after the accept, or gate it with `~busy` (`bup_asset_wr.sv` gates both requests with `!psram_busy` and uses `rd_ack = psram_read_en`, which meets this). |
| `bank_sel`, `addr[21:0]`, `data_in`, `write_high_byte`, `write_low_byte` | Sampled at edge e only; they may change from the next clock on. `bank_sel` 0 selects die 0 (`ce0_n`), 1 selects die 1. `addr` is the halfword address within the die. `write_high_byte` writes DQ[15:8] (UB#), `write_low_byte` writes DQ[7:0] (LB#). With both 0, the access still takes 5 clocks and writes nothing. A read always reads both bytes. |
| `busy` | Registered. High from edge e to edge e+4 (set by the accepting edge itself), low after e+4. Edge e+5 accepts the next request. Back to back, that is one access every 5 clocks: 175 / 233 / 235 ns at 28.636 / 21.477 / 21.281 MHz. |
| `read_avail` | High for exactly one clock, after edge e+4 until edge e+5. Low after writes. |
| `data_out` | Registered at edge e+4 (DQ sampled as OE# rises). It holds until the next read's e+4; writes leave it alone. A registered consumer sees `read_avail` = 1 and the data at edge e+5, the same edge that can accept its next request. |
| Write completion | No strobe: `busy` falling after e+4 is the completion. The halfword is in the chip from e+4 (WE# and CE# rise), so a read accepted at e+5 returns it. |
| `cram_*` pins | e: the die's CE#, ADV#, `cram_a` = A[21:16] and DQ = A[15:0] go low or are driven; UB#/LB# go low (both for a read, per byte enable for a write); WE# goes low for a write. e+1: ADV# rises, latching the address. e+2: DQ is released. e+3: OE# goes low for a read; the data is driven for a write. e+4: CE#, OE#/WE#, UB# and LB# rise and DQ is released. `cram_clk` and `cram_cre` stay 0. `cram_wait` is ignored. |

This is read from the code (`psram.sv:243-382`), and `tb_psram_ctl.sv` checks it at every edge of every access. Each accept must land on the first edge where `busy` is low after the request was raised. `busy` must be high before e+1…e+4 and low before e+5. `read_avail` must be high only before e+5 of a read. `data_out` must be right there.

With `CLOCK_SPEED` set to the slower clock itself, the state numbers collide and nothing completes. "Idle ⇔ `busy` low" also stops being true: the state counter wraps through 256 states with CE# low for 11–17 µs. `run_psram_ctl.sh` shows this failing.

**Timing on the pins** (the model's smallest measured values over the run, ns; the limit is in brackets):

| Clock | ADV# pulse, address setup, CE# to ADV# high (5, 5, 7) | Address hold (2) | WE# low, ADV# to write end (45, 70) | Data setup (20) | Read: ADV# to sample (70) | Read: OE# to sample (20) | Margin for later data |
|---|---|---|---|---|---|---|---|
| 28.636 MHz | 34.92 | 34.92 | 139.68 | 34.92 | 139.68 | 34.92 | 14.92 |
| 21.477 MHz | 46.56 | 46.56 | 186.24 | 46.56 | 186.24 | 46.56 | 26.56 |
| 21.281 MHz | 46.99 | 46.99 | 187.96 | 46.99 | 187.96 | 46.99 | 26.99 |

- The binding limit is OE# to sample: one clock against t_oe = 20 ns.
- The stress runs confirm each margin to 10 ps. Data 10 ps less late than the margin passes, both fixed and random. 10 ps more late than the margin fails every read, as data errors with no timing violation.
- The testbench rounds each half period to a whole ps, so its period is 34.920 ns against the exact 34.921 ns.

### The model (`psram_model.sv`)

**Instantiating it.** The ports are `psram.sv`'s pin names: `cram_a`, `cram_dq`, `cram_wait`, `cram_clk`, `cram_adv_n`, `cram_cre`, `cram_ce0_n`, `cram_ce1_n`, `cram_oe_n`, `cram_we_n`, `cram_ub_n` and `cram_lb_n`. It needs `` `timescale 1ps/1ps`` (it carries its own) and, under Verilator, `--timing`.

**Checks.** Each check is an `$error`, counted in `n_viol` and `viol_n[]`. The first `MAX_MSGS` (10) of each kind are printed.

| Check | Rule |
|---|---|
| T_VP, T_AVS, T_AVH, T_CVS | ADV# low ≥ 5 ns; address (A and DQ) stable ≥ 5 ns before ADV# rises and ≥ 2 ns after; CE# low ≥ 7 ns before ADV# rises |
| T_WP, T_AW, T_DW | A write: WE# and CE# low together ≥ 45 ns; ADV# fall to the end of the write ≥ 70 ns; written lanes stable ≥ 20 ns before it ends |
| T_AADV, T_OE | A read ending (OE# or CE# rising, where `psram.sv` samples) ≥ 70 ns after ADV# fell and ≥ 20 ns after OE# fell |
| T_CEM | CE# low ≤ 4 µs. This is not in `psram.sv`'s list: it is the CellularRAM family's refresh limit, unverified for this part (risk 3). `T_CEM` = 0 turns it off. |
| CE_BOTH, CRE, CLK, NO_ADDR | Both dies selected; `cram_cre` high with a die selected; `cram_clk` not 0; a read or write with no address latched in its CE# cycle |
| CTRL_X, ADDR_X, DATA_X, BUS | Four-state only. X/Z on a control pin while selected, in a latched address, or in a written lane. BUS fires if the host has not released DQ when the die's outputs turn on, or drives DQ while the die does. |

The datasheet values are the ones `psram.sv`'s header lists (`:36-50`), including its commented-out t_oe. Its two guesses, "8 ns" and "3 ns after the address is released", are not datasheet values, so the bus turnaround is checked structurally instead (BUS). `tb_psram_model.sv` makes every check fire on its own: 41 tests in iverilog, and 34 in Verilator, which has no X.

**Read data.**
- Before it is valid, the die drives X (Verilator: the bitwise inverse of the data).
- Data is valid at max(ADV# fall + 70, OE# fall + 20) ns, plus `+psram_extra_ps=N` and a random 0…`+psram_jitter_ps=N` per read (seeded by `+psram_seed=N`; the same knobs exist as parameters).
- A read that ends after the datasheet time but before the stressed time is not a violation. It counts in `late_reads` and returns the garbage.

**Contents.**
- A die byte reads as unwritten until a write or the backdoor sets it.
- Unwritten bytes read as X in iverilog. Under Verilator, or with `UNWRITTEN_X` = 0, they read as `unwritten_pattern(die, addr)`.
- `n_written` counts the halfwords with any byte written. `unwritten_reads` counts reads that touched an unwritten byte; a cache that prefetches past the end of the assets makes such reads, and they are legal.

**Backdoor.** Call these hierarchically. `die` is 0 or 1; `addr` is a halfword address; `byte_addr` is a byte address, with byte b in halfword b >> 1, the low byte when b is even, as the capture writes it.

| Call | Does |
|---|---|
| `bd_write(die, addr, data, be)` | Writes the lanes `be` selects |
| `bd_read(die, addr)` | Returns the halfword as a read would |
| `bd_written(die, addr)` | Returns the {high, low} written bits |
| `bd_clear()` | Marks everything unwritten |
| `bd_load_bin(file, die, byte_addr, n)` | Loads a binary file's bytes |
| `bd_dump_bin(file, die, byte_addr, nbytes)` | Writes them back out; unwritten bytes as 0 |
| `bd_compare_bin(file, die, byte_addr, n, bad, first_bad)` | Compares; a byte counts as bad if it is unwritten or different |
| `report()` | Prints counts, violations, and the smallest measured value of each timing |

**Under Verilator** the first `$error` stops the simulation, because the default `+verilator+error+limit` is 1. That suits a system test; pass `+verilator+error+limit+N` to count on past it.

**Stopping `clk_arm`.** A testbench that stops `clk_arm` while `psram.sv` is mid-access holds CE# low and trips T_CEM after 4 µs. Hardware would fail the same way, with no refresh while CE# is low. A retune or hold test should keep `clk_arm` running, or stop it only while `busy` is low. On the Pocket, whether the PLL reconfiguration lets `clk_arm` run on for the ≤ 5 clocks after the hold reaches the cache is a step 5 question.

### Results (2026-10-03, iverilog 12.0, Verilator 5.040)

`run_psram_ctl.sh`: **23 of 23**, 1 min 34 s beside other runs (60 s on an idle core).

| Check | Result |
|---|---|
| `psram.sv` identity | sha256 equal to upstream's |
| The study's clock count (`../model/study/psram/run_psram.sh`) on the vendored copy | 5.00 clocks per read and per write at 28.636, 21.477 and 21.281 MHz; states distinct. `CLOCK_SPEED` = 21.477273, 21.281 or 14.318181: states collide, 0 completions. |
| Model self-test, iverilog | 41 of 41; `bd_dump_bin` output identical (`cmp`) to the 1,001-byte file loaded at an odd byte address |
| `tb_psram_ctl`, iverilog, 20,000 accesses per clock | At each of 28.636364, 21.477273 and 21.281 MHz: 11,037 reads (2,087 touching unwritten bytes) and 8,963 writes (175 with no byte enabled), over both dies. 13,110 back to back. Every access 5 clocks; `read_avail` 5 edges after the accept; every accept on the first edge with `busy` low. 0 data errors, 0 timing errors, 0 model violations, 0 bus conflicts. At the end, every pool word matches the shadow and no halfword is written outside the pool. |
| Stress, each clock | Data 14,910 / 26,550 / 26,980 ps later than the datasheet passes, fixed and as random jitter (seed 3). 14,930 / 26,570 / 27,000 ps fails: all 11,037 reads late, 8,984 data errors (the rest read unwritten bytes, which are X either way), 0 violations. |
| Must fail | A 60 MHz clock: 11,037 × T_AADV, 11,037 × T_OE, 8,963 × T_AW, 15,055 × T_DW. `CLOCK_SPEED` = clock at 21.477273, 21.281 or 14.318181 MHz: no access completes, and T_CEM fires (CE# low 11.03, 11.14 and 16.55 µs). |
| Mutations of a copy of `psram.sv`, 2,000 accesses each | All 6 caught. Write address bit 0 flipped: 1,830 data errors. Dies swapped: 1,068. Byte lanes swapped: 532. DQ not released before a read: 1,859 violations and 1,078 bus conflicts. A 6-clock read: 4,039 timing errors. OE# never low: 1,078 data errors. |
| Verilator | Self-test 34 of 34 (dump identical). `tb_psram_ctl` with 200,000 accesses at each clock: 109,840 reads, 90,160 writes, 131,589 back to back, all clean. |

The verification plan's PSRAM row ("every read and write completes in 5 clocks; the `$info` state numbers are distinct") passes on the vendored copy.

## Wrapper layer

The Pocket BupChip around ARIA S1: `src/fpga/core/bupchip/bupchip_pocket.sv` and the blocks it is made of, run with the three real clocks and fed the way the Pocket feeds it: the firmware through its data slot, the cartridge at the loader's rate, the PSRAM behind `psram.sv` and the PSRAM model above.

### Running

```sh
sim/bupchip/s4/run_s4.sh sim/work/bupchip/game/rv.a78 13 4                 # one song, about 6 minutes
NAME=x sim/bupchip/s4/run_s4.sh GAME.a78 13 4 +reload=300 +reloads=3 +rom3=OTHER.a78 +holdfill
NAME=y sim/bupchip/s4/run_s4.sh GAME.a78 14 4 +arm15 +pal                  # clk_arm at 21.281 MHz
sim/bupchip/s4/run_cache.sh                               # the cache, WAYS 1 and 2: directed, random and mutations, about 25 minutes
PSRAM=standin sim/bupchip/s4/run_s4.sh GAME.a78 13 4      # the stand-in instead of psram.sv and the model
```

`run_s4.sh` passes `tb_s4.sv`'s plusargs through (its header lists them all) and takes `NAME`, `REF`, `FW` (`FW=none`: no firmware), `MINLEV`, `WM`, `HOLDFILL`, `HOLDMID`, `HOLDLAND`, `WMSWEEP` and `build_s4.sh`'s `PSRAM`, `PREEMPT`, `PREFETCH`, `PCM_DEPTH` and `THROTTLE` from the environment. It checks its inputs before building: no firmware is exit 2, and so is a `REF` that names a missing file. `REF=none` compares no PCM (the result says so); with `REF` unset it compares `sim/work/bupchip/ref/song<N>.pcm` if that exists and otherwise ends `SKIP`, never `PASS`. The default build is agg23's `psram.sv` on `psram_model.sv` with `BUP_DEBUG`.

| File | What it is |
|---|---|
| `src/fpga/core/bupchip/bupchip_pocket.sv` | The wrapper: hold (`pll_locked` and `pll_busy` synchronised, `souper_profile`), `cpu_run`, the ROM (`cache_ram_dp`, no contents until the firmware slot fills it through port B) and RAM, `bupchip_peripheral` unmodified at CMD 8 / PCM 1,024 with the watermark remap, the `$8007` crossing, the 48 kHz pop, the frame back to `clk_sys` with the mute and `souper_profile`, and under `BUP_DEBUG` the status word, shadow FIFO counters and throttle. It drives `psram.sv`'s user ports; the parent instantiates `psram.sv` with `CLOCK_SPEED` = 28.636364 on `cram0` (step 5). |
| `src/fpga/core/bupchip/bup_capture.sv` | `clk_sys`: the A78 header parse (copied from upstream's `bupchip_asset_ddr.sv`, MIT), the byte-pair packer with the odd tail on one lane, the firmware word packer, and the START/WRITE/END and FWSTART/FWWRITE/FWEND stream as one held 47-bit register and a toggle, messages at least 5 `clk_sys` apart |
| `src/fpga/core/bupchip/bup_asset_wr.sv` | `clk_arm`, not held: the receiver (two flops, change detect, one-entry copy), `asset_ready`/`asset_size`, ROM writes and `fw_loaded`, PSRAM writes, and the arbitration between them and the cache's reads |
| `src/fpga/core/bupchip/bup_asset_cache.sv` | `clk_arm`, held. `WAYS` = 1 (ARIA, the default): 64 × 16 B direct-mapped, data in 2 M10K and tags in 1. `WAYS` = 2 (DARIA): 128 sets of 2 ways × 16 B, 4 KB, FIFO replacement, data in 4 M10K and tags in 2. Per-halfword arrival bits, critical halfword first, next-line prefetch, pre-emption (`PREEMPT`), the completion rule, the tag sweep (one clock per set) |
| `src/fpga/core/bupchip/bup_tick48k.sv` | `clk_74a` accumulator (`+= 8` mod 12,375) and the toggle into three `clk_arm` flops |
| `src/fpga/pocket_utils/psram.sv` | agg23's controller, vendored unmodified (PSRAM layer above) |
| `check.sh` | Every step 4 check (above) |
| `tb_s4.sv`, `build_s4.sh`, `run_s4.sh` | The system testbench (its header lists the plusargs and every check), its build, and one run with the PCM compared (`../s1/pcm_check.py`, from the song's first frame, leading silence included) |
| `tb_cache.sv`, `run_cache.sh` | The cache alone behind `bup_asset_wr`'s arbiter and `psram.sv` on the model, with one way and with two: directed scenarios, random streams, mutations; with one way also in lockstep with the step 4 cache |
| `stress/` | An independent verifier's stress benches, all run by `check.sh` (`stress/README.md`) |
| `psram_standin.sv` | `psram.sv`'s user ports and 5-clock timing on a plain array (`PSRAM=standin`), an option only. It was the stand-in until `psram.sv` and the model arrived; in `run_cache.sh` it gives the same counts as `psram.sv` on the model, clock for clock, which cross-checks the port contract. |

### What `tb_s4.sv` checks

On every run, besides the PCM:

- the ROM's 4,096 words equal the firmware file (zero-padded) once `fw_loaded` is set, and every ARSC byte in the PSRAM model equals the file once `asset_ready` is set, after every download;
- no capture message is lost: `bup_capture`'s `seq_err` and `lost`, the simulation-only byte-order check, and `bup_asset_wr`'s `overrun` stay low;
- every frame the wrapper ticks reaches `clk_sys` once and in order, and 0 while `souper_profile` is low; a frame ticked while held, paused or muted is 0;
- after every write to 0x18 the peripheral holds the watermark `clamp(W − (4096 − PCM_DEPTH), 0, PCM_DEPTH)`, worked out in the testbench from the CPU's own write data, and `run_s4.sh` requires CoreTone's last one to be `PCM_DEPTH` − 200 (824); `+wmsweep` puts every value through the remap at time 0;
- the `BUP_DEBUG` shadow levels equal the peripheral's own `pcm_level` and `cmd_level` on every clock, and the shadow flags equal the underflows and overflows counted since the last hold;
- no asset load completes on a cache M10K read registered on the same edge as a port-B write to that word or line, and no tick takes the PCM FIFO's head from such a read (checked from the RAM instances' ports, not from the cache's own logic);
- the CPU never halts, makes no access while held, and reads r0–r14 as 0 at its first instruction after every release; the PSRAM model reports no timing or protocol violation (under Verilator the first `$error` ends the run);
- after a reload of an image the BupChip cannot play (not a Souper cartridge, or no ARSC block), `cpu_run` stays low for 20 ms with nothing retired, nothing pushed and every frame 0;
- while held, the cache starts no PSRAM read, and its data M10K is written only in the first held clock, into a line whose tag is invalid (a read in flight landing);
- every hold (`cpu_run` falling) is logged with whether a cache fill was running and had a PSRAM read in flight, and if so whether `psram.sv` was mid-access (`busy`) or delivering the halfword (`read_avail`) in the first held clock. With `+holdfill` the reloads and the retune are started once a fill has a read in flight and 6 or more halfwords to go; the hold then reaches the cache 9 clocks later, always at the same point of the 5-clock read, and `+holddelay=N +holdstep=S` moves hold k by N + k·S clocks. At 2 × `clk_sys` a delay of 0 or 1 lands the hold on the halfword's arrival and 2–9 mid-access (the trigger is quantised to `clk_sys`). `HOLDFILL`, `HOLDMID` and `HOLDLAND` make `run_s4.sh` require that many of each.

Busy, CPI and MIPS are counted by the retired PC as in `tb_s1.sv`; underflow, overflow and the lowest FIFO level from the command on (underflow also from power-up); the cache's demand misses, prefetches, pre-emptions, late hits and stall clocks while playing.

**Clocks.** `clk_sys` 14.318 MHz and `clk_arm` 28.636 MHz, edge aligned, or with `+arm15` 21.477 MHz (1.5 ×, rising edges together every 2 `clk_sys`), both × 0.99088 with `+pal` or after `+retune`; `clk_74a` 74.25 MHz, asynchronous. The retune keeps `clk_arm` running while it changes the period (`pll_busy` high, `pll_locked` low for 5 µs), as the PSRAM layer requires (T_CEM, below). The loader sends one byte per 2.5 `clk_sys` (174.6 ns, 176.2 ns in PAL: 10 `clk_sdram`), sampled on `clk_sys` as `core_top.v` presents it, unless `+bytens` says otherwise.

### What `tb_cache.sv` checks

The driver behaves as S1 does at the asset port (execute with the address on `d_addr`, then W held by `w_wait`), behind `bup_asset_wr`'s arbiter and `psram.sv` on the model. Every completed load must return the pattern the PSRAM was loaded with; no load may complete on a collided M10K read; no load or fill may hang; the cache must start no PSRAM read while held; and the data M10K must not be written while the cache is held, except that a read in flight at the hold may land in the first held clock, in the line it was filling, whose tag is then invalid (the log counts them).

`run_cache.sh` builds it for `WAYS` = 1 and, with `-DWAYS2`, for `WAYS` = 2; the scenarios and the load mix take the cache's geometry (64 or 128 sets; `+size` defaults to 64 KiB per way). With one way the bench runs exactly as in step 4, and the step 4 cache (`git show 633faf4:…`, renamed `bup_asset_cache_ref`) runs beside the new one on the same inputs: every output must agree on every clock (`eqv`). With two ways every check covers both ways' RAMs (a collision in either counts, as the cache's own rule does), and two more are made on every clock: the line under fill is valid in neither way, and no set holds one line in both (`dup`).

**Directed scenarios** (before the random phase). Each first puts another tag's bytes, all different, in the index it tests, so a stale read is a wrong byte, and afterwards reads every line it filled word by word. Results with pre-emption and prefetch on (W clocks waited; 28.636 MHz, `psram.sv` on the model):

| | Scenario | Result |
|---|---|---|
| A1 | The boot's byte reads of a cold line (fw `0xac`, `0xc0`, `0xc8`, `0xec`, with 4, 1 and 2 instructions between) and its word loads at +4 and +8 (fw `0xf8`, `0xfc`) | One demand miss, waiting 8 clocks; the other five complete as their halfwords arrive (the word at +8 waits 6, a late hit); every byte right |
| A2 | The same six loads back to back | Byte 2 waits 1 clock: halfword 1 was written on the edge its first read was registered, the replay case; both word loads are late hits; every byte right |
| B1–B3 | LDR miss; unaligned LDR miss (+14, the word at +12); odd LDRH miss (+7) on an idle cache | 13, 13 and 8 clocks, as the design's "T_hw + 3 = 8; 13 for LDR" |
| C | A byte in the last halfword of the line under fill | No new fill; a late hit; waits 33 clocks for the halfword |
| D1 | A demand miss while the next line's prefetch has 2–4 halfwords in and a read in flight | Pre-empts after 10 clocks (at most 14 allowed: the read in flight, one issued with its arrival, and 8); the pre-empted line misses again. Without `PREEMPT` it waits for the prefetch, and the line then hits |
| D2 | A demand miss while the previous demand fill runs | The same: pre-empts after 10 clocks, the first line misses again |
| E1–E3 | A hold while a fill has a read in flight: after its load completed; while W waits on the miss (the load is dropped, as the CPU is reset); during a prefetch | Each line misses again after the release, and is right; E2's reload waits 13 clocks |
| F | A load whose tag read is registered on the edge a prefetch writes that line's tag invalid | It waits (14 clocks: one for the collision, then a miss that pre-empts the prefetch) instead of completing on the collided read |
| G | The tag sweep: all 64 lines valid (filled from line 63 down, one at a time), a 100-clock hold, and every byte of the PSRAM changed behind them meanwhile, as a reload of another block would | 0 tags valid when the cache runs again, and all 256 word loads of the 64 lines return the new bytes. Without the sweep, or with it one tag short, G fails (before, every hold left the same bytes behind the stale tags, so nothing could see it) |

109 checks with prefetch, 79 without (D1, E3 and F need it), counting the end-of-phase checks (no stray write, no read started while held, nothing stuck).

With two ways, F first replaces the prefetched line beside the one it reads (a third line of the set; else the probe would find it and write no tag), G fills both ways of all 128 sets (256 lines, tags 63 then 62) and reads back 1,024 words, and these come before G, on sets 70–127, which A–F leave alone (each load drained, so every fill completes first):

| | Scenario | Result (with pre-emption and prefetch) |
|---|---|---|
| H1 | Three lines A, B, C of one set: A, B, then A, B, A, C, B, A, C, B, A | A and B both stay resident, one in each way; C replaces A, the first in, not B, the least recently used; then A replaces B and B replaces C. Every load misses or hits as FIFO says, a hit waiting 0 clocks |
| H2 | A line of a set valid, then a miss on the line before another line of that set | The prefetch fills the set's other way; both lines then hit |
| H3a | V valid in a set, P prefetched into its other way, and a demand miss on a third line M while P's fill has a read in flight | M pre-empts the prefetch and takes P's way: V hits, M hits, P misses. Without `PREEMPT` M waits for P, whose fill completes and flips the FIFO bit, so M replaces V |
| H3b | The same with P a demand fill | The same |
| H4 | For each of the 12 tag bits, two lines of one set whose tags differ in that bit alone (tag 0x555 and its neighbour, offsets up to 7 MiB) | Both miss, then both hit, each with its own bytes |

260 checks with prefetch, 210 without (H2 and H3a need it too).

**Random phase.** 200,000 loads per run: 16 voice streams of byte loads, the boot's cold-line pattern, same-index conflicts and anything else (bytes, halfwords and words, odd and unaligned ones too), 0–40 clocks apart, with a hold of 1–100 clocks about every 20,000 clocks. Each run must reach demand misses, word-load misses, late hits, holds during a fill and, where enabled, prefetches, pre-emptions and misses on pre-empted lines.

**Mutations** of a copy of `bup_asset_cache.sv`, each of which must fail: a load completing once its critical halfword is in (LDR then reads a stale halfword); no data read-during-write wait; no tag read-during-write wait; no invalid tag at a fill's start; an LDR waiting for one halfword; a hold leaving the read in flight marked; pre-emption not waiting for the read in flight; the tag written valid a halfword early; no tag sweep; a sweep one tag short; reads issued while held (the RTL before `rd_req` was gated with `run`). All 11 are caught: 10 by the directed checks (1 to 29 failing), "the tag written valid a halfword early" only by the random loads (2 wrong).

With two ways the same 11 are caught (by 1 to 68 directed checks; "the tag written valid a halfword early" again by the random loads alone, 25 wrong), and 13 of the second way: the FIFO bit never flipping (40 directed checks), or flipping when a fill starts instead of when it completes (2: H3a and H3b, where M then replaces V); demand fills always into way 0 (37); a fill's start invalidating the other way (40); the hit way's data not selected (90); the line under fill read from way 0 (43); way 1's tag compare ignoring the top bit (2: H4's bit 11) and way 0's ignoring the bottom bit (78); a fill writing both ways' data (2, and 228 wrong bytes); the prefetch probing way 0 only (no wrong byte, but 9,162 clocks with a line in both ways); the read-during-write waits seeing way 0's tag writes only (3, one completed collided read) or data writes only (42); the sweep clearing way 0 only (2).

### Design notes

Where the RTL settles something `docs/BUPCHIP_CORE.md` left open (the design text now says the same):

- **M10K read-during-write.** The design has the replay read come one clock after the write of the last halfword a load needs. The data M10K is written a halfword at a time through byte enables, so a load can also read a word whose *other* halfword is being written on the same edge (halfword 0 arrived, halfword 1 arriving); on the device the whole word is then undefined. The cache therefore never uses a port-A read that was registered on an edge with a port-B write of the same data word or the same tag line: that clock waits and the read is repeated. The design's rule is the special case of this. Scenarios A2 and F exercise both halves.
- **A read in flight at a hold.** `psram.sv` cannot abort it. The cache drops the fill at the edge after `cpu_run` falls, so the halfword may still be written in the first held clock, into the line it was filling, whose tag is invalid; the sweep then invalidates every tag before the CPU runs again. The fill machine starts no read once `cpu_run` is low (`rd_req` is gated with `run`; before, a hold landing on a read's arrival clock issued one more read in the first held clock, harmless but keeping `psram.sv` busy into the hold), so the controller is idle at most 5 clocks after `cpu_run` falls.
- **Prefetch while a fill runs.** The next line of the latest asset access waits (one register, newest wins) until no fill is running, then is probed; the design's "if no fill is running" would drop it. The cycle model queues every prefetch.
- **Pre-emption** stops any running fill, a prefetch or the rest of a demand fill, once its halfword in flight is back.
- **The PCM FIFO's head.** `bupchip_peripheral` raises `pcm_available` in the clock after a push into an empty FIFO, a clock before its M10K presents that frame (the same race is in upstream's subsystem). A tick that lands in a clock where `pcm_available` has just risen waits one clock (`tick_hold`), so a stale frame is never played. CoreTone at speed never pushes into an empty FIFO, so `stress/run_pophead.sh` exercises it with firmware of its own, and `+forcetick` forces a tick onto that clock (before, `+forcetick` fired where the firmware enables PCM over a full FIFO, whose head is valid, so it tested nothing).
- **The mute** is applied on `clk_arm`: a tick while `muted` puts 0 in the frame register, so `muted` no longer crosses to `clk_sys` unsynchronised (upstream applies it at its `clk_sys` capture). The only difference from upstream is the one frame ticked just before a FAULT write and captured after it. `BUP_DEBUG`'s capture flags reach the `clk_arm` status word through two flops. With these, nothing crosses between the clocks but the toggled registers, should `clk_arm` ever get its own PLL.
- **Output while held.** Ticks keep toggling the frame register while the CPU is held, with the frame 0, so the output reads 0 within one tick of any hold (upstream's would hold its last value).
- **Lowest level.** The shadow's lowest PCM level starts once the FIFO has first reached its watermark (the boot's prefill), since the boot always starts from an empty FIFO.
- **Message format.** One 47-bit register (3-bit type, 44-bit payload) and a toggle. WRITE leaves in the clock its last byte arrives; everything else waits in a flag for the 5-clock spacing, FWWRITE too, in a one-word register (at most 9 clocks). FWWRITE used to leave at once: a firmware download starting straight after a cartridge's could then send it 1–4 clocks after the cartridge's END, and at 1–2 clocks the receiver lost the END (`stress/run_capstress.sh`'s `xstream` runs: 29–37 wrong checks of about 210). A firmware byte in the clock `fw_download` rises used to be dropped; it now starts the first word (`+fwrise`).
- **M10K count.** The cache's data RAM is `cache_ram_tdp_dc_be`, a true dual-port `altsyncram`, and a true dual-port M10K is at most 20 bits wide, so its 256 × 32 takes 2 M10K, not 1: the BupChip needs 39 M10K (design, "Totals"). Step 5's fit report confirms it.
- **Two ways (DARIA, `WAYS` = 2).** `docs/DARIA_CORE.md` ("Bytes beyond 128 KB") widens this cache for 2600 images beyond the 128 KB window; `WAYS` = 1 stays the default, so the BupChip as shipped is this step's cache, clock for clock (`run_cache.sh`'s lockstep). With two ways: 128 sets (offset[10:4]), a 12-bit tag per way (offset[22:11]: the BupChip's assets need all 23 bits of the offset, a 2600 image 19, and the cache serves both in one instance with no profile input), both ways' tags and data read in parallel at `d_addr`, `asset_q` from the way whose tag matches (or the way under fill). A set's FIFO bit is the XOR of one bit in each way's tag word, so a fill writes only its own way's word: it keeps its way's bit as it starts and flips it as it completes. A pre-empted or held fill therefore leaves the FIFO bit on its own, now invalid, way, and with the sweep clearing both bits a valid line is never replaced while its set has an invalid way. The prefetch probes both ways and fills the FIFO way. The read-during-write waits take a write to either way (a hit can wait a clock for a write to the other way), which keeps the way select off `w_wait`. M10K: data 2 × 512 × 32 in 4 (true dual-port, at most 20 bits wide), tags 2 × 128 × 14 in 2: 6 in all, one more than the design's 5, which assumed 8-bit tags in one word of 2 × 9 + 1 bits. Timing: the way select puts a 2:1 mux after the tag compare on `asset_q`, into `bup_cpu`'s W source mux.

### Results (2026-10-03, Verilator 5.040, `psram.sv` on `psram_model.sv`)

`check.sh sim/work/bupchip/game/rv.a78`: **28 of 28**, 52 min 45 s with `JOBS=3` on 4 cores (after verification round 2); without the game, **16 of 16** in 41 min with `JOBS=2` (the step 5 review). Earlier: 27 of 27 and 15 of 15 after round 1. Every game row is a full download of the 741,344-byte image at 174.6 ns per byte (129.439 ms; all 216,928 ARSC bytes in the PSRAM model equal the file; `asset_ready` 0.384 µs after the download ended; no capture message lost, no overrun), the firmware booting 3.220 ms after the release with fault 00 and taking the command 7 clocks after it is sent, then 4 s of pops: PCM identical to MiSTer's `song<N>.pcm` over all 187,984 song frames, both as pushed and as returned to `clk_sys`; 0 underflow (from power-up), 0 overflow; every check above clean. The firmware slot takes 7,824 bytes (CRC32 `95b8b4f8`) in 1.366 ms and the ROM's 4,096 words equal the file.

| Song | CPI | MIPS | Busy | Busiest 0.1 s / worst batch | Lowest level | Demand misses | Prefetches | Pre-emptions | Late hits | Stall clocks |
|---|---|---|---|---|---|---|---|---|---|---|
| 13 (Misery_F) | 1.3783 | 15.14 | 72.89% | 21.50 / 24.10 MHz | 659 | 8,297 | 65,172 | 295 | 68 | 70,127 (0.061%) |
| 14 | 1.3845 | 5.30 | 25.62% | 9.56 / 10.31 MHz | 755 | 2,898 | 39,623 | 248 | 149 | 26,178 |
| 9 | 1.3808 | 9.47 | 45.64% | 13.80 / 15.23 MHz | 721 | 7,332 | 137,496 | 1,574 | 260 | 68,959 |
| 30 | 1.3946 | 1.81 | 8.83% | 3.66 / 3.80 MHz | 801 | 675 | 43,969 | 109 | 35 | 6,132 |

| Run | Result |
|---|---|
| Song 13 against the cycle model | `../model/cycles.py rv.a78 --song 13 --secs 4 --run S1/cache`: CPI 1.378, 7,910 misses (ours +4.9%), 65,471 prefetches (−0.5%), 445 late hits, 71,825 stall clocks (−2.4%); within the plan's ±20%. With `tb_s1.sv`'s zero-wait assets the S1 core takes CPI 1.3772 and keeps a lowest level of 660. |
| Song 13, `PREEMPT=0` | 72,396 stall clocks against 70,127 with pre-emption (+3.2%), 8,292 misses, 64,959 prefetches, CPI 1.3784, lowest level 659. **Pre-emption is kept** (`PREEMPT=1`, the default). |
| Song 13, loader at 174.6–250 ns per byte | Download 157.359 ms (firmware 1.661 ms); from the boot on, identical to the plain run |
| Song 13, throttle 13/16 (`THROTTLE=13`, 23.27 MHz effective) | Lowest level 626; busy 87.38% of all clocks; CPI 1.6525 |
| Song 13, three reloads 300 ms into each play | Reload 1 (the game) and reload 2 (the game without its ARSC block) each came during a cache fill with a PSRAM read in flight, the first with the halfword arriving in the first held clock (it was written there, into the invalid line), the second with `psram.sv` mid-access; the CPU was held 9 `clk_arm` clocks after `load_start`; no read started while held. After reload 2: `asset_size` 0, `asset_ready` 0, held and silent for 20 ms (960 frames, all 0). After reload 3 the PSRAM again equals the file, the firmware reboots in 3.220 ms and the song is identical, lowest level 659. The PSRAM model saw 325,392 writes and 680,540 reads, 0 violations. |
| Song 13 after a PAL retune 500 ms in | The hold came during a fill with `psram.sv` mid-access, 9 clocks after `pll_busy`; firmware and assets kept; reboot at 28.375 MHz 3.250 ms after the release; busy 73.56%, lowest level 657 |
| Song 13 across a 20 ms pause | 960 ticks paused, 0 pops and 0 nonzero frames meanwhile; the output file leaves the paused ticks out and still matches |
| Song 14 at 21.281 MHz (`+arm15 +pal`) | Loader 176.2 ns per byte (2.5 PAL `clk_sys`), so a WRITE every 7.5 `clk_arm`: no message lost, no overrun, the PSRAM equals the file, `asset_ready` 0.446 µs after the download. Busy 34.47%, CPI 1.3845, lowest level 732; 2,897 misses, 26,170 stall clocks. The model's smallest PSRAM timings: 46.988 ns (OE# to sample, data setup), 187.952 ns (ADV# to sample, WE# low). |
| Synthetic ARSC (game-free), song 0, 2 s | Identical to `armemu.py` over its 48,000 song frames, both streams; 17.71 MIPS, busy 84.95%, lowest level 636; 370 misses, 7,080 prefetches. The firmware's two writes to 0x18 leave 824 in the peripheral; `+wmsweep`: 29,867 values through the remap (all 8,192 at 0x18), 0 wrong. On a wrapper whose remap is one too high, both checks fail (825; 1,023 values wrong). |
| The same, a 5,193-byte block and a 7,827-byte firmware file | Both tails written (the odd byte on its low lane; the last word zero-padded); PCM identical |
| The same, three reloads (Souper, not Souper, Souper) | The first two holds came during fills with a read in flight, one with the halfword arriving and one mid-access; the image without the Souper bit held the BupChip for 20 ms (`souper_profile` 0, nothing retired, 960 frames all 0); after the last image, PCM identical. On the cache as it was before `rd_req` was gated, the landing hold starts a PSRAM read in the first held clock and the run fails. |
| Synthetic ARSC at 21.281 MHz, download and boot | No message lost; the PSRAM equals the file; boot 1.486 ms after the release, fault 00 |
| Not a Souper cartridge; no firmware; a 4-byte firmware file; the game without its ARSC block | Held and silent: the CPU never released (0 retired, 0 pushed), 960 frames out in 20 ms, all 0; `fw_loaded` / `asset_ready` 1/1, 0/1, 0/1, 1/0 |
| `run_cache.sh` | 24 of 24 runs: 109 (79 without prefetch) directed checks each, then 200,000 random loads with 0 wrong bytes, 0 completed collided reads and 0 reads started while held. With pre-emption and prefetch, per seed: about 136,000 demand misses (20,000 of them word loads), 7,300 prefetches, 129,000 pre-emptions, 120,000 misses on pre-empted lines, 14,000 late hits, 138–159 holds, all but 1–4 of them during a fill. `psram.sv` on the model and the stand-in give the same counts. Mutations: 11 of 11 caught. |
| `run_psram_ctl.sh` | 23 of 23 (PSRAM layer) |
| Stress (`stress/`) | `run_cstress.sh` 26 of 26 runs and 10 of 10 mutations (22.2 M loads, 0 wrong); `run_capstress.sh` 22 of 22; `run_tick.sh` 18 of 18; `run_bounds.sh` 11 of 11; `run_pophead.sh` 8 of 8 (12 ticks held a clock on real collisions at 28.636 MHz, 7 at 21.281, one forced; the FAULT run silent from frame 3,051); `run_reload.sh` 5 of 5. Numbers in `stress/README.md`. |

**Area [syn].** Yosys 0.69 (`synth_intel_alm`, as `../model/study/area/run_area.sh` runs it) on `bupchip_pocket` with the CPU, the peripheral and the RAMs as black boxes: 500 LUT + 236 arithmetic cells + 466 FF; 534 + 260 + 510 with `BUP_DEBUG`. By the design's rule that is 418–518 ALMs (+32–39 for `BUP_DEBUG`), against the design's 360–520 for the same rows ("Totals": bus glue, cache, capture and receiver with the firmware path, crossings); with the 0.55 LUT factor the S1 probe measured, about 393. `psram.sv` is not in it.

### DARIA's 2-way cache (2026-10-05, Verilator 5.040)

`WAYS` and the benches above, run by `check.sh` with the game on the tree at c22e3cc plus the new cache and benches; then the same `check.sh` again with `bupchip_pocket.sv`'s cache set to `WAYS` = 2 (a scratch copy under `sim/work`, its `run_cache.sh` and `stress/run_cstress.sh` jobs left out since they do not depend on the wrapper).

| Run | Result |
|---|---|
| `run_cache.sh` | 48 of 48. With one way all 24 result lines equal step 4's bench on step 4's cache, counter for counter, and the step 4 cache in lockstep differs on no clock. With two ways, 260 (210 without prefetch) directed checks each, then 200,000 random loads with 0 wrong bytes, 0 completed collided reads, 0 reads started while held and 0 clocks with a line in both ways; with pre-emption and prefetch, per seed, about 128,000 demand misses (20,000 word loads), 7,700 prefetches, 120,000 pre-emptions, 108,000 misses on pre-empted lines and 14,700 late hits. `psram.sv` on the model and the stand-in give the same counts. Mutations: 35 of 35 caught. |
| `stress/run_cstress.sh` | 52 of 52 runs and 30 of 30 mutations; numbers in `stress/README.md` |
| `check.sh` with the game, both trees | Every job's own log ends in PASS: all 28 with `WAYS` = 1, all 26 with `WAYS` = 2 (PCM identical in every game row, held and silent where expected). `check.sh`'s tally said 25 of 28 and 25 of 26: for `run_cache.sh`, song 14 and the 21.281 MHz boot (`WAYS` = 1) and the 21.281 MHz boot (`WAYS` = 2), `wait` returned non-zero although the job had printed PASS and exited through its last line. Both runs took about 3 hours on a machine shared with other simulations, and PIDs wrapped (`pid_max` 32,768) during them; a lost `wait` status is the likely cause, not checked further. With `WAYS` = 1 the four songs' cache counts equal step 4's table above. |
| Songs 13, 14, 9 and 30 with `WAYS` = 2 | PCM identical to MiSTer's, both streams. Song 13: 1,269 demand misses, 30,760 prefetches, 86 pre-emptions, 63 late hits, 11,381 stall clocks (0.010%), against 8,297, 65,172, 295, 68 and 70,127 (0.061%) with one way; busy 72.84%, lowest level 659. Song 14: 900 misses, 9,169 stall clocks (26,178 with one way); song 9: 2,937 and 29,098 (68,959); song 30: 399 and 3,806 (6,132). |

### Open points for step 5

Settled by step 5's build (`docs/BUPCHIP_CORE.md`, step 5): the new paths have +11.5 to +31 ns of slack at 28.636 MHz (`clk_arm`'s worst, +8.08 ns, is the CPU's own fetch-to-next-PC path), the BupChip takes 40 M10K (the command FIFO went to an M10K), and `pll_region.v` keeps `clk_arm` running for 98 clocks after `pll_busy`. What follows is the list as step 4 left it.

- **Timing paths new with the wrapper.** `w_wait` is a tag compare plus the in-fill and read-during-write checks, and it feeds the CPU's next-PC logic in front of `rom_addr` (the step 3 probe drove it from a flip-flop). ROM port B's address goes through a 2:1 mux on `d_addr` (the firmware writes while `fw_loaded` is low). Cache fills drive `psram_read_en` through the arbiter. `start_dem` also drives the tag M10K's port-B address and write enable (`tb_addr`, `tb_we`) in the same clock, from the tag M10K's unregistered output through a 13-bit compare and `rd_ack`: an M10K-out to M10K-address path within one `clk_arm` period, tighter at S3's 21.477 MHz. If it fails timing, start the pre-emption one clock later (the miss path already tolerates waiting).
- **`clk_arm` across a PLL reconfiguration.** The retune here keeps `clk_arm` running. If the PLL stops it while `psram.sv` is mid-access, CE# stays low (T_CEM, unverified for this part). The cache starts no read once `cpu_run` is low, so `psram.sv` is idle at most 5 `clk_arm` clocks after `cpu_run` falls, which is 8–9 clocks after `pll_busy` rises (the retune runs here): `clk_arm` must run on for about 14 clocks (0.5 µs) after `pll_busy`. It does: `pll_region.v` raises `busy` 256 `clk_74a` clocks (3.45 µs) before it starts the reconfiguration (`pll_region.v:12-15`), about 98 `clk_arm` clocks at 28.636 MHz and 74 at 21.477 MHz.
- **M10K.** The cache's data RAM takes 2 M10K in true dual-port mode (design, "Cache"), so the BupChip needs 39; step 5's fit report confirms it.
- **Not compared instruction by instruction on the real cache.** The CPU runs the firmware on this cache with bit-exact PCM on every run, and `tb_cache.sv` checks every load's data, but no lockstep run uses the cache's timing; step 2's lockstep runs with `+await` (random asset waits) cover the CPU's side of `w_wait`.
