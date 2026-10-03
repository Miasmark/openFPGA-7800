# ARIA (BupChip CPU): Quartus probe

Step 3 of `docs/BUPCHIP_CORE.md`. ARIA's S1 configuration, `src/fpga/core/bupchip/bup_cpu.sv`, is compiled alone on the Pocket's 5CEBA4F23C8 with the memories it will have, once with `clk_arm` at 28.636364 MHz (S1) and once at 21.477273 MHz (the final clock). The full build (`src/fpga/ap_core.qsf`) is not touched.

```sh
sim/bupchip/quartus_probe/run_probe.sh            # both clocks, 2-4 min each in Docker
sim/bupchip/quartus_probe/run_probe.sh 28.636364  # one clock
```

Quartus Prime Lite 21.1.1 runs from the `raetro/quartus:21.1` image (the one CI uses) unless `quartus_sh` is on the PATH. Each clock builds in `sim/work/bupchip/qprobe/<MHz>/`: Analysis & Synthesis, Fitter and Timing Analyzer (no Assembler), a Timing Analyzer script, then EDA Netlist Writer for the fitted netlist. The script prints `summary.txt` and keeps the reports in `output_files/`; `paths.rpt` has the five worst paths in full. It then deletes `db/`, `incremental_db/` and the netlist, unless `KEEP_DB=1`.

| File | What it is |
|---|---|
| `bup_probe_top.sv` | `bup_cpu`, the ROM (`cache_ram_dp`, 4,096 × 32, no initial contents) and the RAM (`cache_ram_tdp_dc_be`, 4,096 × 32 with byte enables, port A). Every other CPU port goes through one flip-flop to or from a virtual pin. The ROM's port B takes firmware writes while the CPU is held, as the write receiver will; without a write path Quartus would fold the uninitialised ROM, and the CPU behind it, to constants. `d_addr` is registered as well, standing in for the asset cache's M10K address registers. |
| `bup_probe.qsf`, `bup_probe.qip` | The project. It copies the settings of `ap_core.qsf` that apply to a core-only compile: HIGH PERFORMANCE EFFORT, speed, the physical synthesis options, the router options, and 0–85 °C. The seed (1) and synthesis effort (AUTO) are the defaults, which `ap_core.qsf` also uses. Every port but `clk` is a `VIRTUAL_PIN`. |
| `bup_probe.sdc` | `clk_arm` on `clk`; `run_probe.sh` rewrites the period per run |
| `run_probe.sh` | The flow above. Its Timing Analyzer script writes `paths.txt` (the five worst setup paths at slow 85 °C, with logic levels), `classes.txt` (the worst setup path into each kind of endpoint) and `cells.txt` (every placed cell) |
| `probe_report.py` | The figures: resources, the entity table, the RAM and DSP summaries, Fmax and slack per corner, the paths, and an estimate of the CPU's ALMs by block |

**Breakdown by block.** `bup_cpu.sv` is one module, so Quartus's entity table stops at `bup_cpu` and its two register-file MLAB instances. `probe_report.py` gives each cell of the fitted netlist to a block. Most cells go by the RTL signal they are named after. Cells named after an operator (`AddN`, `SelectorN`, ...) go by their connections, and LUTs next to the MLABs go to the register file. ALMs are counted from placement and scaled to the CPU's "ALMs needed". A LUT that Quartus shares between two blocks counts in only one of them, so each block is printed with the range given by three voting rules.

## Results (2026-10-03)

The two clocks give two fits. Hold slack is positive at every corner. The worst setup slack at 28.636 MHz is at slow 0 °C, not 85 °C.

| | 28.636364 MHz (34.921 ns) | 21.477273 MHz (46.561 ns) |
|---|---|---|
| `bup_cpu` ALMs needed (incl. 4 MLAB LABs = 40) | **1,297.3** | **1,271.9** |
| `bup_cpu` ALUTs / registers / DSP | 2,058 / 607 / 3 | 2,054 / 600 / 3 |
| `bup_cpu` after synthesis: ALUTs / registers | 1,866 / 308 | 1,865 / 308 |
| Whole probe ALMs needed (incl. 141 for virtual I/O) | 1,527 | 1,505 |
| M10K / MLAB bits / DSP blocks | 32 / 1,024 / 3 | 32 / 1,024 / 3 |
| LABs with CPU logic (empty device) / packed at 10 ALMs | 180 + 4 MLAB / 126 + 4 | 176 + 4 MLAB / 124 + 4 |
| Fmax, slow 85 °C / slow 0 °C | 34.97 / 34.48 MHz | 32.36 / 32.42 MHz |
| Worst setup slack, slow 85 °C / slow 0 °C | **+6.323** / +5.916 ns | **+15.654** / +15.717 ns |
| Worst hold slack (fast 0 °C) | +0.005 ns | +0.131 ns |

The physical synthesis options roughly double the register count (308 to 607), by retiming and duplication. The extra registers sit mostly in ALMs that already hold LUTs.

**Register file.** It inferred as two `altdpram` instances, one per read port, each in MLAB. Each is a Simple Dual Port 16 × 32 with registered write inputs, an unregistered read address and an unregistered output, and takes 2 MLABs: 4 MLABs and 40 ALMs in all. It is not in flip-flops or M10K. The ROM and RAM are 16 M10K each.

**Critical path.** Both fits have the same chain:

ROM port A output → decode → register-file read-port select → MLAB read → `rb` bypass mux → shifter (`ShiftLeft`, two `ror32` levels) → operand mux → 32-bit adder (`sum`) → region decode of the address in `always8`.

From there it goes to `rom_addr` (the one-clock-store decision holds or advances the PC) or to the RAM's write enable. That is 14–15 logic levels, with a data delay of 27.3 ns at 28.636 MHz and 30.4 ns at 21.477 MHz. Interconnect is 62–66% of the delay.

The worst path into each other kind of endpoint, at 28.636 MHz:

| Endpoint | Slack |
|---|---|
| RAM port A | +7.5 ns |
| MLAB write port | +7.7 ns |
| ROM port B | +8.3 ns |
| DSP inputs | +15.0 ns |

**Breakdown at 28.636 MHz** (ALMs needed; range over the three voting rules):

| Block | ALMs |
|---|---|
| Register file (4 MLAB LABs, read and bypass muxes, write port) | 347 [309–439] |
| Decode/control | 264 [237–282] |
| Shifter/ALU | 374 [374–401] |
| Multiplier | 20, plus 3 DSP |
| Load/store | 198 [110–198] |
| LDM/STM | 93 [90–97] |

**Warnings.** Analysis & Synthesis reports "bidirectional pin `global.bp.work.arm7tdmi_pkg.shift_register.carry_index_*`, `low_live`, `high_live` has no driver" (13040).

- These are the values those three function locals would carry into a call of `arm7tdmi_pkg::shift_register`. Quartus models such values when a variable is assigned on only some paths, and here they are assigned only in the `amount != 0` branch.
- Every read of them comes after an assignment in the same branch, so the placeholders feed nothing.
- No register was removed except for constant or duplicate values: `late_pc`/`chk_pc` bits 0, 1 and 14–31, `halt_code[3]`, `wb_value` merged into `blk_wb`, and the binary state bits after one-hot encoding.
