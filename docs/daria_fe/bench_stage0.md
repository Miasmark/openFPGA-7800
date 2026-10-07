# Front-end shadow, stage 0: a reference front end in tb_daria

Stage 0 of the front-end shadow (docs/daria_fe/spec/bench.md 7.9 item 0). `daria_fe` does not exist yet, so a **reference front end** stands in its place: a second copy of upstream's `mapper_dpcplus`, `mapper_cdf` and `cdf_fastjump_table`. It is driven only by continuous-assign taps of the DUT, and its outputs never feed back. The reference is upstream's own code, so every bad count must be 0. A non-zero count would mean a tap error or a timing-convention error in the bench.

**Result.** Every bad count is 0 on all three images over 300 frames: DPC+ (SF2fix_NTSC), CDFJ (Galagon) and CDF1 (draconian RC8). That covers about 5.95 to 6.02 million latches per image. No bench fix was needed.

A self-test (`+fe_mut`) breaks one tap at a time. It shows the checks do catch value errors. It also maps out what the latch-point checks cannot see: timing errors that stay inside the 6507's latch slack.

Nothing in `src/`, `docs/` or the other sims changed. Nothing was committed. Game-derived outputs are all under `sim/work/bupchip/daria/`.

---

## 1. What was built

| File | Change |
|---|---|
| `sim/bupchip/daria/fe_shadow.svh` | **New** (684 lines). The reference instances, the taps, the checks, the self-test hooks and the reporting. |
| `sim/bupchip/daria/tb_daria.sv` | `` `ifdef FE_SHADOW `include "fe_shadow.svh" `endif `` after the `DARIA_SHADOW` include, with a two-line comment. All five lines come after the `$finish` line, so existing builds' run.log is byte-identical, `$finish` line number included. |
| `sim/bupchip/daria/run_daria.sh` | `FE=1` adds `-DFE_SHADOW -I$HERE` and appends `_fe` to the object directory (`obj_fe`, `obj_shadow<WIN>_fe`, `obj_wrap<WIN>_fe`). `fe_shadow.svh` joins the `find -newer` rebuild check through an `INCS` array, only when `FE=1`, so other builds' rebuild check is unchanged. Runs go to `runs/fe/`, `runs/shadow<WIN>_fe/` or `runs/wrap<WIN>_fe/`. `NOBUILD` is unchanged. Header documented. Written atomically (temp file + rename). |
| `sim/bupchip/daria/run_all.sh` | The same `FE` line in its `PREFIX` logic, mirroring run_daria.sh. Header documented. Written atomically. |
| `sim/bupchip/daria/dynamic_tables.py` | `sec_fe`, called with `--only fe`. It reads `fe.csv` and the `FE shadow:`/`FE detail:`/`FE S1:` lines. It is not in the default `SECTIONS` list, so existing reports do not change. |

**Usage.** `FE=1 DTRACE=0 ./run_daria.sh ROM.bin +frames=300 +snap=0`. `FE=1` also combines with `SHADOW=1` (built and run: Mappy 40 frames) and with `WRAPPER=1` (supported by the scripts, not built).

**Outputs** (in the run directory):
- `fe.csv`, one line per frame at the VSYNC rise (frames.csv's rule), with these columns: `frame, latches, commits, dout_bad, dout_hidden, state_bad, reads, writes, hidden, cycles, port_bad, rom_bad, l3_bad, e0_latch_min, e0_latch_max, e0_short`. The first six follow bench.md 7.7's names.
- `fe_err.txt`: the first `+fe_stop` (default 20) failures. Each gives the class, field, clk_sys, frame, line, phases, a_in, rw, d_in, both values and the 6507 PC. The first two also get a 64-clk_sys bus ring with these columns: `p1 p0 phi2 acc rw a_in d_in up_do/oe ref_do/oe up_bank ref_bank stall dma tick`.
- run.log lines:
  - `FE checks from ...` when the checks start;
  - `FE handoff: ...` for the phase handoff, re-phasing reloads and the first RSYNC writes;
  - the final `FE shadow: <scheme> <latches> latches, <commits> commits; dout <n>, state <n> bad; E0->latch <min>..<max>`;
  - then `FE detail:`, three `FE spacing ...` histograms, `FE S1:` and `FE reloads:`.

**Plusargs:** `+fe_stop=N`, `+fe_fatal=1`, `+fe_mut=N`, `+fe_lag=N`. The last two are the self-test of section 5.

**Regressions.** All were re-run on the final sources:
- `SHADOW=1 WIN_KB=64`, Mappy, 40 frames: "DARIA shadow: 79 calls compared, 0 differ". run.log is identical to the pre-edit run apart from the wall and CPU-time lines, and daria.csv is byte-identical.
- `SHADOW=1 WRAPPER=1 WIN_KB=64`, Mappy, 40 frames: run.log, daria.csv, frames.csv, slack.csv, zero.csv, summary.txt and calls.csv are all identical to the pre-edit run.
- Plain build: compiles. No `FE_SHADOW` code is in it, and every line before `$finish` is unchanged.
- `SHADOW=1 FE=1`: daria.csv is identical to `SHADOW=1` alone, and the FE line is all 0.
- `FE=1 run_all.sh`: it resolves `runs/fe/`, skips a run whose report.txt exists and tabulates `runs/fe/*/`.

---

## 2. The taps, and why each one is exact

Every tap is a continuous assign. The reference therefore samples it pre-edge, at the same `clk_sys` edge as the DUT's own flops (bench.md 0, 7.4.1). Paths are relative to `tb_daria`.

| Reference input | Driven from | Why it is exactly what upstream's instance gets |
|---|---|---|
| `a_in`, `d_in`, `rw` | `dut.cart2600.a_in`, `.d_in`, `.rw` | These are cart2600's own input ports, which it passes unchanged to both mappers (cart2600.sv:803-841). |
| `access` | `dut.cart2600.arm_access` | The same wire cart2600 connects to both mappers' `access` (`phi2 && arm_driver_run`, cart2600.sv:247). |
| `reset` | `dut.effective_reset \|\| scheme != 21` (or `!= 23`) | cart2600 gives `reset \|\| mapper != BANKDPCP` (or `BANKCDF`). Its `reset` is top.sv's `effective_reset`, and `mapper` is `force_bs`, because the tb ties `.mapper(0)` (top.sv:1138). |
| scheme, `stable_fractional`, revision, `ldx`/`ldy`, fetch offset, `cdfj_entry`/`cdfj_stack` | tb's `detect2600` wires (`force_bs`, `mapper_revision[0]` / `[1:0]`, `cdf_*`, `cdfj_*`) | These are the nets the tb hands to `dut` and that cart2600 forwards. |
| `rom_data` | The reference's **own** read port on the tb's `rom[]`: `fe_rom_q <= rom[tia_en ? rom_a_ref : cart_7800_addr_out]`, and `ioctl_dout` while `cart_download` | The same rule as the DUT's `cart_q <= rom[cart_addr[18:0]]`. `cart_addr_out` is `tia_en ? {0, rom_a} : cart_7800_addr_out` (top.sv:332, 1108, 1149), and `.cart_out` is `cart_download ? ioctl_dout : cart_q` (tb:198). The `rom_a` mask is all ones for 21/23 (cart2600.sv:195-197). The **rom** check (`fe_rom_q == cart_q`, every clk_sys from `running`) was 0 throughout. |
| `ram_data` / `ram_rdata` | `dut.cart2600.cartram_data` | cart2600's input port, the one both mappers read: top.sv's `cartram_data_bram`, `pause` = 0. |
| `table_pointer`, `table_increment[15:0]` | `dut.cart2600.table_pointer`, `.table_increment` | The stream tables' registered lookups, the nets cart2600 connects to `mapper_cdf` (cart2600.sv:860-861). |
| `fast_jump_valid` | The reference's own `cdf_fastjump_table`, fed the tb's load strobes (`~old_cart_download && cart_download`, `ioctl_wr && cart_download`, `ioctl_addr`, `ioctl_dout`) and queried at the reference's own `rom_a[14:0]` | The same expressions as the DUT's `mapper_load_*` (tb:204-206). The query matches cart2600's `fast_jump_query_addr` for CDF (cart2600.sv:883-884). The **jump** check compares all 32,768 map bits with the DUT's map once after the load (0 differ), and the per-clock port check compares the query result. |
| `amplitude` | `dut.cart2600.arm_audio_amplitude` | The net cart2600 connects to both mappers. |
| `call_ready` | `dut.cart2600.mapper_call_ready` | The same, for both mappers' `call_ready` (cart2600.sv:661). |
| `service_ready` | `dut.cart2600.dpc_service_ready` | The same, for DPC+'s `service_ready` (cart2600.sv:428, 838). |

**The slot.** The reference's raw outputs go through a copy of cart2600's output mux (cart2600.sv:205-233): direct, `direct & rom_do`, the RAM port (`oe` 0 on a write port), or the ROM byte. `is_bad_game` is false for 21 and 23 without `NO_ARM_MAPPER`. The mux uses the reference's own `rom_data` and the tapped `cartram_data`, which are cart2600's `rom_do` and `cr_do`.

---

## 3. Comparison points and conventions

- **Start.** Checks start at the first `pclk1` (pre-edge) with `!dut.effective_reset && dut.tia_en` (bench.md 1.3 item 7). In this bench that is 14 to 22 clk_sys after the tb's "reset released", always while MARIA's phases are on the bus. The port, rom, jump and S1 counters start earlier, at `running`.
- **E0** is the `dut.pclk1` pulse itself, read pre-edge. Nothing in the bench counts clocks to find it.
- **L1.** At every `dut.pclk0` edge (pre-edge, E0+6), with `RW` and scheme 21 or 23, the bench compares:
  - `oe` equal;
  - `d & oe` equal (cart2600's `d_out`/`oe` against the reference's slot).

  A pclk0 with `!dut.mapper_phi2` is a held cycle's repeat. It is counted apart, as `hidden`, and its differences go to `dout_hidden` (information). On writes, `oe` is counted as information (L2).
- **L3** (tap check, added). This proves the latch convention. At the edge after each pclk0, `dut.cpu_inst.cpu.core.dp.dl` must equal the byte sampled at that pclk0: `read_DB` when `cpu_rwn`, else `write_DB`, which is sally's `data_in`. So what the bench samples pre-edge at pclk0 is exactly what the 6507 latches (`dl <= data_in` at `phi2_en`, which equals `dut.pclk0`; mos6502_dp.sv:267-299, top.sv:1421-1435).
- **C1** (DPC+). At every pclk1 (pre-edge), i.e. the state the previous cycle left (bench.md 7.3 floor):
  - for i = 0..7: `top`, `bottom`, `counter`, `fractional`, `increment`;
  - `params[0..3]` and `min(parameter_pointer, 4)`;
  - `waveform[0..2]`, `random_number`, `bank`, `fast_fetch`, `fast_pending`, `call_pending`, `service_pending`.
- **C2** (CDF). At every pclk1: `bank`, `mode`, `fast_pending` (and `fast_expected_address` while pending), `jump_remaining` (and `expected_address`, `jump_stream` while non-zero), `call_pending`.
- **Port** (tap check, added). Every clk_sys from `running`, the reference's raw mapper outputs are compared with upstream's:
  - DPC+: `d_out`, `flags_out`, `oe`, `rom_a`, `ram_sel`/`ram_rw`/`ram_a`, waveforms, NOTE, `call_request`, the six service fields;
  - CDF: `d_out`, `flags_out`, `oe`, `rom_a`, `table_index`, the pointer update (strobe, index, value), the RAM port (`en`, `write`, `addr`, `wdata`), `digital_audio`, the call request/entry/stack/thumb, `fast_jump_valid`.

  This is the only check that sees timing errors inside the latch slack (section 5). It is meaningful only while the reference is the same code.
- **S1.** Histograms of E0→pclk0, pclk0→E0 and E0→E0, in three windows: (0) `running` before the checks; (1) checked with MARIA's phases (`!dut.phase_source_tia`); (2) checked with the TIA's. E0→latch < 6 is counted and printed with frame and line. Added:
  - when `phase_source_tia` rises;
  - every reload of the TIA divider (`tia_inst.clockgen.hclk.edge_p2 && rsynd`, TIA.sv:565-567) that finds `pclk_div != 1`, i.e. one that re-phases;
  - RSYNC writes (rising `tia_inst.rsync`).
- **Counts.**
  - `latches`: every checked pclk0, with `latches = reads + writes + hidden`.
  - `commits`: `access && a_in[12]`.
  - `cycles`: checked pclk1 edges, i.e. C1/C2 compares.

---

## 4. Results per image (300 frames, `FE=1`, `DTRACE=0 +snap=0 +fire_at=120 +play_at=160`)

The earlier fire and play frames make gameplay start inside 300 frames. These runs used the binary built before the handoff probe was added. The checks are the same code. The handoff numbers come from 5-frame probes on the final binary (`runs/fe_selftest/probe/`), which also report all 0.

| | SF2fix_NTSC | Galagon | draconian RC8 |
|---|---|---|---|
| scheme (force_bs, rev) | DPC+ (21, 0) | CDFJ (23, 2) | CDF1 (23, 1) |
| calls | 429 | 599 | 600 |
| latches checked | 5,958,519 | 6,016,023 | 5,956,774 |
| read latches compared (L1) | 5,263,292 | 5,228,381 | 5,186,430 |
| write latches | 537,252 | 577,977 | 525,016 |
| hidden pclk0 | 157,975 | 209,665 | 245,328 |
| commits | 5,222,180 | 4,787,615 | 5,146,588 |
| cycles compared (C1/C2) | 5,958,519 | 6,016,023 | 5,956,774 |
| **dout bad / state bad** | **0 / 0** | **0 / 0** | **0 / 0** |
| dout_hidden (information) | 0 | 0 | 0 |
| L2 oe on writes differs | 0 | 0 | 0 |
| **port / rom / jump map / L3 bad** | **0 / 0 / 0 / 0** | **0 / 0 / 0 / 0** | **0 / 0 / 0 / 0** |
| E0→latch | 6..6 | 6..6 | 6..6 |
| E0→latch < 6 | 0 | 0 | 0 |
| DPC+ service / DMA events | 0 | 0 | 0 |
| wall (FE build, 300 frames) | 628 s | 642 s | 635 s |

**Spacing histograms**, identical in shape for all three (counts are for SF2; the others differ only in the TIA-phase totals):

| Window | E0→latch | latch→E0 | E0→E0 |
|---|---|---|---|
| before the checks | {6: 1} | {6: 2} | {12: 1} |
| checked, MARIA phases | {6: 75} | {6: 75} | {12: 75} |
| checked, TIA phases | {6: 5,958,444} | {6: 5,958,443} | {12: 5,958,443} |

Galagon's TIA-phase window has 6,015,948 latches and draconian's 5,956,699. Every interval in every run is 6 or 12. There are no stretched or shortened phases.

**Hidden pclk0 against the bench's stall time.** A stall should hide every pclk0 inside it except the first, so hidden ≈ stall_sys/12 − calls, using frames.csv over the same frames:

| Image | hidden | stall_sys/12 − calls |
|---|---|---|
| SF2 | 157,504 | 157,652 |
| Galagon | 209,211 | 209,535 |
| draconian | 245,063 | 245,289 |

The mean shortfall is 0.35 to 0.54 per call. That is what the window alignment predicts: the first pclk0 inside a stall comes 10 clk_sys after `arm_call_stall` rises (E0+8 → E0+18). That makes about 350 to 410 held cycles per call.

---

## 5. Self-test: which check sees which kind of tap error (`+fe_mut`, `+fe_lag`)

Bench-only, default off. Each mutation breaks one tap or convention in the reference. Runs: 5 frames for 1 to 9; 3 frames for the lag sweeps. Images: SF2 (DPC+) and Galagon (CDFJ), plus draconian (CDF1) in the sweeps. Results are in `runs/fe_selftest/mut/`.

| `+fe_mut` | Broken on purpose | L1 dout | C1/C2 state | port | rom |
|---|---|---|---|---|---|
| 0 | nothing | 0 | 0 | 0 | 0 |
| 1 | ROM byte 1 clock late (a 2-clock ROM) | 0 | 0 | 1.4-1.8k | 0 |
| 2 | RAM byte 1 clock late | 0 | 0 | 0.9-2.5k | 0 |
| 3 | table lookups 1 clock late | 0 | 0 | CDFJ 4.3k, DPC+ 0 | 0 |
| 4 | AMPLITUDE 1 clock late | 0 | 0 | 0 | 0 |
| 5 | `access` on every pclk0 (held repeats not hidden) | 0 | 0 | 0 | 0 (commits +1.4%) |
| 6 | `a_in` 1 clock late | 0 | 0 | 26-42k | 24-40k |
| 7 | reset from the tb's `reset` (before `reset_hold`) | 0 | 0 | 0 | 0 |
| 8 | `d_in` = `read_DB` on writes | 1.4-1.8k | 80-82k | 0.8-1.0M | 0 |
| 9 | slot output 1 clock late | 0 | 0 | 0 | 0 |

**Lag sweeps** (L1 bad, 3 frames; C1/C2 bad in brackets):

| | lag 2 | lag 3 | lag 4 | lag 5 | lag 6 |
|---|---|---|---|---|---|
| `+fe_mut=9` (output late), CDFJ | 0 | 497 | 723 | 20,917 | 22,026 |
| `+fe_mut=9`, CDF1 | 0 | 302 | 417 | 8,639 | 8,889 |
| `+fe_mut=9`, DPC+ | 0 | 0 | 310 | 11,174 | 11,409 |
| `+fe_mut=1` (ROM late), CDFJ | 0 | 0 | 0 | 20,917 (1,414) | 20,917 (1,414) |
| `+fe_mut=1`, CDF1 | 0 | 0 | 0 | 8,639 (1,120) | 8,639 (1,120) |
| `+fe_mut=1`, DPC+ | 0 | 0 | 0 | 11,074 (35,173) | 11,074 (35,173) |

What this shows:

- **The latch point is placed correctly.** The output-lag thresholds are exactly bench.md section 2's "readable from" edges:
  - a CDF stream byte (RAM q registered at E0+3, readable pre-edge E0+4) fails from lag 3;
  - a DPC+ fast-fetch byte (registered E0+2) fails from lag 4;
  - every plain ROM byte (registered E0+1) fails from lag 5.

  So upstream's slack before the latch is 2, 3 and 4 clk_sys on those three paths. That is how much later than upstream `daria_fe` may produce each byte and still pass L1.
- **L1, C1 and C2 see value errors, not timing inside the slack.** A one-clock error in a_in, ROM, RAM, tables or output is invisible to them. It is equally invisible to the 6507, which samples only at E0+6. Only the every-clock port check sees such errors, and it needs the reference to be the same code. With `daria_fe`, L1/C1/C2 are the right rules: they compare what the 6507 sees.
- **Stage 0's RAM and table taps are the DUT's, addressed by the DUT.** So L1 here does not test the reference's own RAM or table addressing. That is why a ROM up to 4 clocks slower still passes: the reference's late operand never addresses anything. The port check covers it (`ram_a`, `ram_addr`, `table_index` equal on every clock). With `daria_fe` and its own `fe_mem`, L1 tests the addressing end to end. Stage 0 therefore does **not** measure `daria_fe`'s ROM-latency budget (critic finding 9 / bench.md Q8).
- **m5: the hidden-pclk0 rule is not observable on this image set.** Committing every held repeat adds 1.4% commits and changes nothing. The held cycle is always the opcode fetch after the CALLFN write (top.sv:298-326), and its repeats are idempotent: they re-arm `fast_pending` at the same address. A `daria_fe` that commits on hidden pclk0 would pass L1/C1/C2 here. If that matters, add a tap check for stage 1: `daria_fe`'s commit strobe must never fire on `pclk0 && !mapper_phi2`.
- **m7: the exact reset release does not matter in this bench.** Nothing commits until `arm_driver_run` (`lock_ctrl && tia_en`), and `call_ready` is low until then. Only the reset level inside the checked window counts.
- **m4: AMPLITUDE one clock late was not seen in 5 frames.** No AMPLITUDE read landed within one clock of an amplitude change. The planned `amp_lag` class (bench.md 7.6) will need long runs to get statistics.

---

## 6. Findings worth noting

1. **E0 spacing is perfectly regular.** On all three images, over 300 frames each, every E0→latch and latch→E0 interval is 6 clk_sys, and every cycle is 12. That holds before the checks, through the MARIA-phase window and through the TIA phases. There are no RSYNC-shortened phases (critic finding 15, items 2-3). `daria_fe`'s 6-clock read budget holds for this set.
2. **The MARIA → TIA handoff** (critic finding 15 item 1; bus.md B2, BU:79-86, which asks S1 to report it). Measured on the final binary, identical on all three images:
   - The checks start on MARIA's phases. The handoff to the TIA's phases comes **901 clk_sys (75 checked cycles + 1) after the checks start**, about one scanline (912 clk_sys) after the reset release.
   - The **first line-end reload after the TIA's reset finds `pclk_div` = 5, not 1, so it does re-phase the TIA divider.** This is bus.md's "d = 5" case, a 2-clock phase 1 in the TIA's own sequence.
   - It happens 906-914 clk_sys after the reset release, while MARIA's phases are on the bus. `phase_source_tia` rises 9 clk_sys later, and the bus sees no stretched or shortened phase (all spacings 6/12).
   - Every later reload finds `pclk_div` = 1, a no-op. The reload counts equal checked latches/76 (1,113, 1,869 and 1,090 in about 4.25, 7.1 and 4.2 frames). Galagon simply runs more lines before its fifth VSYNC.
   - So in this configuration (`bypass_bios` 1, `tia_mode` 1, `cpu_driver` 1) the first line end does misalign the TIA divider, and the handoff hides it. The `cpu_phase_controller` (top.sv:1230-1345) waits in WAIT_TARGET_SAME until the TIA's own phases appear, which they do only after this reload. A `daria_fe` keyed to `pclk1`/`pclk0` (critic finding 15's resolution) sees nothing irregular.
3. **RSYNC writes.** The 6507 writes RSYNC 1-2 times early in frame 0, from the start-up code's TIA-clear loop. That is after the handoff, with the TIA's phases on the bus. **None re-phases the divider.** So in this set RSYNC never produces the 2- or 10-clock phases of bus.md B2. A directed mid-line RSYNC test (bench.md 7.9 item 7) is still needed to exercise them.
4. **Hidden pclk0 edges are common and harmless here:** 158k-245k per 300 frames, about 350-410 per call, and none differs (`dout_hidden` 0). See section 5, m5, for why their commit rule is not observable.
5. **No DPC+ service (copy/fill) and no DMA stall** in these runs (`dma_events` 0). This matches bench.md 1.5. C1's `service_pending` and the port check's six service fields were only ever compared at their idle values.
6. **Cost.** The FE build runs at about 2.1 s per frame. Plain runs logged 1.3-1.7 s per frame (1,500-frame runs from Oct 4), so the overhead is roughly +25 to +60%, inside bench.md's estimate.

---

## 7. What stage 0 does not cover, and suggestions for stage 1

- Not built, because they need `daria_fe`'s own memories and state:
  - C3/C4 (pointer and RAM effects);
  - R1-R3 (posts, service, copy RAM);
  - I1/I2 (init image);
  - K1/K2 (RAM at call start and per frame);
  - T1-T4 (audio);
  - O1 (`obus_exposed`);
  - the hold of 7.4.2 and `+hard_reset_at`.

  The CSV columns are named so that bench.md 7.7's full header can extend them.
- **Keep the reference instance in stage 1, beside `daria_fe`.** Then a mismatch between `daria_fe` and upstream while the reference agrees with upstream is unambiguously `daria_fe`'s. The port, rom and jump checks also keep proving the taps, including through any future change to `tb_daria`'s ROM or load stream.
- In stage 1, `port` stays reference-only, because `daria_fe`'s internal outputs need not match clock by clock. The `daria_fe` rules are L1, C1/C2 (through `fe_taps.svh`), L3 and S1. Add "no commit on a hidden pclk0" (section 5, m5).
- In stage 1, `rom_data` should come from `fe_mem.fe_rom` (daria_mem's registered port), not from the tb's `rom[]`. The rom check can compare that port's data with `cart_q` whenever the two addresses match.

---

## Check

An adversarial pass over stage 0 (2026-10-07). The goal was to prove that the checks bite, and to find any comparison that is vacuous. Every fault below was injected into the **reference** copy only, through its inputs or outputs (and, for the stuck flop, a `force` on the reference's own register), under plusargs that are off by default. Runs are under `sim/work/bupchip/daria/runs/fe_check/`. They use `DTRACE=0 +snap=0`, 8 frames unless stated, and at most two at a time.

**Result.**
- All five requested faults are caught, each by the class that should see it.
- The review found four problems in the bench, all fixed in `fe_shadow.svh` (and the parser in `dynamic_tables.py`):
  1. L1 compared every RAM-backed byte with itself.
  2. A race in the new injection counters.
  3. Weak handling of a console reset.
  4. One unclassified hidden latch.
- It also found compares that, on this image set, only ever see idle values.
- After the fixes, all three images still report 0 on every check over 300 frames. The plain, `SHADOW=1` and `SHADOW=1 FE=1` builds are unaffected.

### C.1 The faults, and what caught them

"inject+k" is the first failure of that class, k clk_sys after the injected clock.

| Fault | Plusarg (reference only) | Image | First caught by | Totals (8 frames) | Silent |
|---|---|---|---|---|---|
| **(a)** d_out bit flip on one latch | `+fe_flip=20000` (`+fe_flip_bit`, `+fe_flip_ofs`) | SF2, Galagon, draconian | **L1 dout**, inject+0 | dout 1, all else 0 | port, rom (the flip is on the slot byte, after the raw outputs) |
| (a') the same flip one clock **before** the latch (`+fe_flip_ofs=-1`) or **after** it (`=+1`) | | SF2, Galagon | nothing | all 0 | correct: the 6507 never sees it |
| (a'') the same flip on a **hidden** pclk0 (`+fe_flip_hidden=1`) | | SF2, Galagon | L1 hidden (information) | dout_hidden 1, dout 0 | correct |
| (a''') the flip after a console reset (`+hard_reset_at=3 +fe_flip=110000`) | | Galagon | **L1 dout**, inject+0 | dout 1 | |
| **(b)** commit one clock late (access delayed, every cycle) | `+fe_mut=10` | SF2 | **port** (d_out 2,118, flags_out 949, ram_a 394, note_write 42, waveforms 24, call_request 18); **C1**: all 1,166 are `call_pending` | port 3,545; state 1,166; dout 0 | L1 |
| | | Galagon | **port** (pointer_update 2,795, d_out 1,742, flags_out 725, ram_en 120, call_request 30); **C2**: all 2,832 are `call_pending` | port 5,412; state 2,832; L2 info 120; dout 0 | L1 |
| | | draconian | **port** (digital_audio, pointer_update), **C2 call_pending** | port 3,577; state 700; L2 info 39; dout 0 | L1 |
| **(c)** wrong bank after a hotspot | `+fe_bank_spur=20000`: a hotspot write only the reference sees, at E0+8 | SF2 | **port** rom_a inject+0, **rom** inject+1, **C1 bank** inject+4 (next E0), **L1** inject+10 (next latch) | dout 116,526; state 124,215; port 1.49 M; rom 1.49 M | |
| | | Galagon | the same sequence: C2 bank 0 vs 6 | dout 167,378; state 181,719 | |
| | | draconian | the same sequence | dout 116,783; state 122,470 | |
| **(d)** DPC+ counter off by one | `+fe_cnt=50`: DFxLOW write 50 ($1051), d_in $78 seen as $79 | SF2 | **C1 counter[1]**, inject+6 (next E0); **L1** at the next DF1 reads; port ram_a | state 19,912; dout 50; port 250 | **L1 before the fix** (see C.2.1) |
| **(e)** CDF fast_pending stuck at 0 | `+fe_fpstuck=1` | Galagon | **C2 fast_pending** at the first armed E0, then L1 and port | state 4,439; dout 2,183; port 986 k | |
| | | draconian | the same | state 17,948; dout 1,912; port 897 k | |
| (e') stuck at 1 | `+fe_fpstuck=2` | Galagon, draconian | **C2 fast_pending**, inject+12 (first E0) | state 197,279 / 124,521; port 13,626 / 11,472; dout 0 | L1 |

Notes on what each fault shows:

- **(a) proves the latch point.** A one-clock flip is caught when it covers the clock that ends at the pclk0 edge, and it is invisible one clock either side. So L1 samples exactly the pre-edge value at pclk0. L3 is 0, so that is the value the 6507 latches.
- **(b) has no L1 failures, which is right.** A commit one clock late is inside the 6507's slack, so the 6507 cannot see it. The every-clock **port** check sees it. C1/C2 see it only through the call handshake. Upstream accepts at E0+7 (`call_ready` is high pre-edge). A pending flag set at E0+7 instead misses `call_ready`, which then goes low (`call_busy`), so it sticks until the call returns.
- **(c) uses a spurious hotspot write.** The image set makes **no hotspot commit at all**: 0 reads and 0 writes to $1FF4-$1FFB in 40 frames on all three images, and in 300 frames (C.3). The as-specified variant (`+fe_bank=N`, which inverts a_in[0] at the N-th real hotspot commit) therefore never fires here, which itself shows the bank path is not exercised. The spurious write (DPC+ $1FF6+next bank; CDF $1FF5/$1FF6) changes only the reference's bank. Every check that should see it does, in the expected order: port, then rom, then C1/C2, then L1.
- **(d) needed the fix in C.2.1 to show in L1.** All 50 L1 failures had equal slots. The reference's DF1DATA byte was upstream's own RAM byte at upstream's address. Only the new independent-RAM-byte check caught them. With the original bench, L1 reported 0 for a front end that reads its fetcher RAM at the wrong address. C1 and port did catch it.
- **(e') stuck at 1 is invisible on the bus in these frames.** The 6507 never re-reads an armed operand address without fetching its opcode first. The reference keeps substituting for clocks E0+7..E0+11 after the operand commit. Port catches that, and so does C2 at the next E0.

### C.2 Review findings and fixes

1. **L1 compared RAM-backed data with itself (fixed).** In the original wiring, the reference's `ram_data`/`ram_rdata` were `dut.cart2600.cartram_data`, addressed by the DUT's arbitration, and its `table_pointer` was the DUT's lookup at the DUT's `table_index`. On every DPC+ fetcher read (DFxDATA, windowed, fractional) and every CDF stream read, the reference's slot byte was therefore upstream's byte. L1 compared it with itself and tested only the decode. Stage 0 section 5 says the port check covers the addressing; L1 itself did not.
   - **Fix.** Beside the reference, the bench reads what upstream's ports would return at the **reference's own** addresses:
     - cart RAM port A at the reference's `ram_a` (DPC+), or at `$800 + P` (CDF), with P from an own pointer-table read at the reference's `table_index`;
     - the ports' one-clock registered timing and read-during-write rules (cart_ram_tdp.sv:58-84, cache_ram.v:172-176/262-270; a sys-side table write takes the port).
   - At every L1 latch where the reference consumed RAM, its consumed byte must equal that independent byte, masked by `window_flag` for DPC+ function 2. The reference instance's inputs are unchanged, so the port check stays exact.
   - Two new tap checks prove the model:
     - **ram**: the independent byte against port A whenever both registered addresses are equal;
     - **pointer** (CDF): the independent pointer against `table_pointer` whenever both lookup indices are equal or the port was written.

     Both are 0 everywhere (C.3).
   - AMPLITUDE stays a tap, and its reads are counted apart as not independent. The reference has no audio engine; stage 1's `daria_fe` will have its own.
   - Proof: fault (d).
2. **The injection counters raced (fixed; a rule for stage 1).** The first (d) run injected one write early, into counter[2] instead of counter[1]. C1 failed 330 clk_sys before the reported injection.
   - Cause: `fe_cnt_n` was updated with a blocking `++` in the check block, and the reference read it through a continuous assign at the same edge. Whether the reference saw the old or the new count depended on process order.
   - The counters are now NBA.
   - **Rule:** anything the bench computes and feeds to `daria_fe` through a continuous assign must change only by NBA.
3. **E0 tracking over a console reset (fixed).** Stage 0 never resets the console after the load, and its gating was `fe_armed && !effective_reset`, with `fe_armed` never cleared. After a reset:
   - S1 binned the reset's phases as "checked, MARIA phases". A reset produces one 24-clk cycle (latch->E0 18).
   - The checks resumed at the first clock with `effective_reset` low, mid-cycle, without the `tia_en` test of the first start.
   - Only the first handoff was reported.

   **Fix:**
   - The checks are now "live" from a pclk1 with `!effective_reset && tia_en`, and stop while `effective_reset` is high.
   - S1 has a fourth window, "in a console reset, until the checks resume".
   - Every reset, resume and handoff is logged. A new `FE resets:` line counts them.
   - New `+hard_reset_at=F` / `+hard_reset_len=N` (FE builds only; bench.md 7.2) drive the tb's `reset_in` from the VSYNC rise of frame F, for N clk_sys.

   **Tested** at frame 4 on all three images:
   - upstream re-inits: `mapper_init_busy` holds the reset 2,500-4,300 clk_sys past the 1,000-clk_sys pulse;
   - the checks resume 14 clk_sys after the release, on MARIA's phases;
   - the TIA divider's first line-end reload again finds `pclk_div` = 5;
   - the second handoff to the TIA comes 901 clk_sys after the resume, exactly as at power-up;
   - all spacings while live are 6/12, and every count is 0;
   - a flip after the resume is caught (a''').
4. **Hidden pclk0 (checked; one class added).** The rule `hidden = pclk0 && !mapper_phi2` is exactly top.sv:320-327: `arm_call_stall && stall_cycle_taken`. A flip on a hidden latch lands only in `dout_hidden` (a''). But the **last** hidden pclk0 of a stall is not simply overwritten:
   - the core re-applies the frozen T-state unmasked at the release E0, and `dl` is latched unconditionally (mos6502_ctl.sv:874-958, mos6502_dp.sv:299; bus.md B7), so the core leaves the stall with that byte in DL;
   - for the post-CALLFN opcode fetch it is the opcode byte again, the same byte the taken latch returned, so upstream and the reference agree here (0 differ);
   - whether the released cycle's phase-1 control word reads DL depends on the instruction. This pass did not establish that it never does.

   It is now counted apart: `hidden_last` (a hidden pclk0 whose next E0 reads RDY high) and `hidden_last_bad` (information). A third to a half of the calls end this way (SF2 239 of 429, Galagon 196 of 599, draconian 282 of 600, Mappy 27 of 79). The rest end with the release artefact, a non-hidden latch already compared by L1. **For stage 1, treat `hidden_last_bad` as a failure to investigate.**
5. **Taps (checked, nothing wrong).** Every tap was traced to cart2600's own instance connections (cart2600.sv:803-884; top.sv:1112-1155, 236-327):
   - a_in, d_in = `cart_din`, rw = `RW`;
   - access = `arm_access` = `mapper_phi2 && lock_ctrl && tia_en`;
   - reset = `effective_reset || mapper != 21/23`;
   - rom_do = `cart_out` = `cart_download ? ioctl_dout : cart_q`;
   - cartram_data = `cartram_data_bram`, with `pause` 0;
   - `mapper_call_ready`, `dpc_service_ready`, `arm_audio_amplitude`, `table_pointer`/`table_increment[15:0]`;
   - revision, CDF options, and entry/stack from the same detect wires.

   All are continuous assigns or direct hierarchical reads, so they are sampled pre-edge. No compare is a signal against itself, apart from the data of C.2.1 and AMPLITUDE. C1, C2 and port compare `fe_ref_*` against `dut.cart2600.{dpcplus,cdf}`; rom compares the reference's own port with `cart_q`; jump compares two maps. L3 is a DUT-only consistency check by design.
6. **Compares that only ever saw idle values (coverage; not fixable with these images).** New `FE coverage:` line: at the checked E0s, how often upstream's state was off its idle value (C.3).
   - **bank:** never changed. No hotspot commit in 300 frames on any image, so C1/C2 `bank` and `daria_fe`'s hotspot logic are untested by this set. Fault (c) shows the compare bites.
   - **call_pending:** 0 at every E0. It is set at E0+6 and accepted at E0+7 (arm_mapper_controller.sv:86-87, 149-161), so the compare fires only on a timing fault such as (b).
   - **service_pending:** 0 (no DPC+ copy/fill).
   - DPC+ **params and `parameter_pointer`:** 0. SF2 never writes PARAMETER.
   - **AMPLITUDE reads:** tap data on both sides; counted.
   - **Exercised:**
     - DPC+ `fast_fetch` and `fast_pending`;
     - CDF fast mode, `fast_pending` and `jump_remaining`;
     - CDF digital-audio mode, on draconian only: mode $00 at 99.95% of E0s, 0 on Galagon.

     The jump maps hold 46 set bits (Galagon), 6 (draconian) and 3 (SF2).
   - Directed tests remain the only way to cover these (bench.md 7.9 item 7). Add a bank-switching test to that list.
7. Cosmetic: a string ternary of literals pads with NULs in Verilator's `$display`. Those two messages now use a string variable.

### C.3 Final runs

`FE=1 DTRACE=0 +frames=300 +snap=0 +fire_at=120 +play_at=160`, as in section 4, on the final `fe_shadow.svh`. Runs: `runs/fe_check/final_{SF2,GAL,DRA}/`.

| | SF2fix_NTSC (DPC+) | Galagon (CDFJ) | draconian RC8 (CDF1) |
|---|---|---|---|
| latches / commits (identical to section 4) | 5,958,519 / 5,222,180 | 6,016,023 / 4,787,615 | 5,956,774 / 5,146,588 |
| read latches / driven by the cartridge | 5,263,292 / 5,196,724 | 5,228,381 / 4,780,427 | 5,186,430 / 5,143,284 |
| **RAM-backed reads, now checked at the reference's own address** | 272,443 | 373,779 | 325,559 |
| AMPLITUDE reads (tap, not independent) | 80,621 | 0 | 47,800 |
| hidden pclk0 / the last of a stall | 157,975 / 239 | 209,665 / 196 | 245,328 / 282 |
| **dout / state / port / rom / ram / pointer / jump / L3 bad** | **0 / 0 / 0 / 0 / 0 / 0 / 0 / 0** | **0 / 0 / 0 / 0 / 0 / 0 / 0 / 0** | **0 / 0 / 0 / 0 / 0 / 0 / 0 / 0** |
| dout_hidden / hidden_last_bad (information) | 0 / 0 | 0 / 0 | 0 / 0 |
| ram / pointer tap checks, clocks compared | 71.2 M / (DPC+: none) | 1.91 M / 72.2 M | 1.65 M / 71.5 M |
| hotspot commits; DFxLOW writes | 0; 5,482 | 0; - | 0; - |
| coverage (E0s off idle) | bank 0, fast_fetch 5,955,774, fast_pending 3,056,528, call/service pending 0, parameter_pointer 0 | bank 0, fast mode 5,953,724, fast_pending 393,849, jump_remaining 89,322, call_pending 0, digital 0 | bank 0, fast mode 5,954,043, fast_pending 1,449,648, jump_remaining 47,559, call_pending 0, digital 5,954,043 |
| E0->latch; < 6 | 6..6; 0 | 6..6; 0 | 6..6; 0 |
| handoffs (1 re-phasing reload, pclk_div 5, 901 clk_sys after the start) | 1 | 1 | 1 |
| wall | 654 s | 664 s | 651 s |

The new checks add about 3% to section 4's wall times (628-642 s).

Regressions after the changes:

- **`SHADOW=1 WIN_KB=64`, Mappy, 40 frames** (`runs/fe_check/reg_shadow64_Mappy/`): "DARIA shadow: 79 calls compared, 0 differ or halted". run.log is identical to `runs/shadow64/Mappy_demo_final_CG_NTSC/` apart from the time lines. daria.csv, frames.csv, slack.csv, zero.csv, summary.txt and calls.csv are byte-identical.
  - The binary was rebuilt; its size is unchanged. `run_daria.sh` rewrites `$WORK/patched/*.sv` on every call, so any run makes the other builds look stale to the `find -newer` check. That is existing behaviour, not changed here.
- **Plain build**: it compiles, and `obj/` contains no `fe_ref_*` code. A plain SF2 run of 8 frames (`plain_SF2`) gives frames.csv, calls.csv, slack.csv, zero.csv, summary.txt and run.log (without the FE and time lines) identical to the FE build's run (`base_SF2`). The shadow does not disturb the DUT.
- **`SHADOW=1 FE=1 WIN_KB=64`, Mappy, 40 frames** (`reg_shadow64_fe_Mappy`):
  - daria.csv and frames.csv are identical to `SHADOW=1` alone;
  - 79 calls compared, 0 differ;
  - FE: 780,383 latches, every bad count 0; 11,232 RAM-backed reads checked, 18,169 AMPLITUDE reads, 27 last-hidden latches.
- **`SHADOW=1 WRAPPER=1 WIN_KB=64`, Mappy, 40 frames** (`reg_wrap64_Mappy`), rebuilt: 79 calls compared, 0 differ. daria.csv, frames.csv, slack.csv, zero.csv, summary.txt and calls.csv are byte-identical to stage 0's `wrap64_Mappy`, and run.log differs only in the time lines.

### C.4 What changed in the files

- `fe_shadow.svh`:
  - the independent RAM byte and pointer, with the **ram** and **pointer** tap checks and the L1 RAM test;
  - the "live" gating, S1 window 3, reset and handoff logging, and `+hard_reset_at`/`+hard_reset_len`;
  - `hidden_last`/`hidden_last_bad`;
  - counts of cartridge-driven, RAM-backed and AMPLITUDE read latches, hotspot commits and DFxLOW writes;
  - the `FE coverage:` line;
  - the fault injections `+fe_flip` (`_ofs`, `_bit`, `_hidden`), `+fe_mut=10`, `+fe_bank` (`_wr`), `+fe_bank_spur`, `+fe_cnt` and `+fe_fpstuck`;
  - the NBA injection counters.

  `fe.csv` gains seven columns at the end: `ram_bad, pointer_bad, cart_reads, ram_reads, amp_reads, hidden_last, hidden_last_bad`. "FE detail:" now reads `port N, rom N, ram N, pointer N, jump map N, L3 N bad`. New lines: `FE reads:`, `FE coverage:` and `FE resets:`.
- `dynamic_tables.py`: `sec_fe` parses the new detail fields (and the old ones), the RAM-read count and the reset/handoff count.
- `tb_daria.sv`, `run_daria.sh` and `run_all.sh` are unchanged by this pass.

### C.5 For stage 1

- Keep the independent RAM byte as the model for what `daria_fe`'s own `fe_mem` must return. Keep the ram and pointer tap checks while the reference stays beside `daria_fe`.
- Feed `daria_fe` only from continuous assigns of DUT signals or NBA-updated bench state (C.2.2).
- Make `hidden_last_bad` must-be-0, and add stage 0's "no commit on a hidden pclk0" tap check.
- The image set does not exercise the following; they need directed tests:
  - bank switching;
  - DPC+ copy/fill and PARAMETER writes;
  - a mid-line RSYNC.
- Run `+hard_reset_at` once per scheme.
