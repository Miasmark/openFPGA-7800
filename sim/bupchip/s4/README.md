# ARIA (BupChip), step 4: the Pocket wrapper in simulation

Step 4 of `docs/BUPCHIP_CORE.md`: the wrapper, memories, asset path and PSRAM around the S1 core, in simulation. This README has one section per layer; the PSRAM layer is below.

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
  - `data_loader.sv:61` defines the same `` `MAX``, inside its module. Neither iverilog 12 nor Verilator 5.040 (`-Wall`) warns about that, in either file order. Quartus is expected to warn once both files are in `core.qip` (docs/BUPCHIP_CORE.md, "Controller").
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

`run_psram_ctl.sh`: **23 of 23**, 1 min 34 s.

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
