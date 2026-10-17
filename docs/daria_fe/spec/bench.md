# Bench: shadowing `daria_fe` beside upstream's front ends in tb_daria

This file says how to run a new front end, `daria_fe` (DPC+ and the CDF family; `docs/DARIA_CORE.md` "The front end"), as a cycle-by-cycle shadow of upstream's front ends inside `sim/bupchip/daria/tb_daria.sv`. The comparison runs at every 6507 latch edge, at every commit and at every audio tick. It covers:

- what the bench does today;
- every hierarchical path the shadow must tap;
- how the image arrives;
- how the step 5 shadow (`daria_shadow.svh`) mirrors cart RAM and posts calls;
- how DARIA's `clk_d` is made, and the one-line change that puts its edges where the PLL puts them;
- the POKEY shadow bench, which serves as the model;
- a concrete plan: files, plusargs, what to compare when, and reporting;
- the bench's limits.

Path conventions: `RTL/` = `src/fpga/mister/rtl/`, `BUP/` = `src/fpga/core/bupchip/`, `D/` = `sim/bupchip/daria/`. "file:N" cites a line. Nothing here was run against a ROM. All timings come from the RTL and the bench sources; run times come from the existing `run.log` "wall" lines in `sim/work/bupchip/daria/runs/`.

**Checker's pass (adversarial review, this revision).** Every cited line was re-read. Markers: **[checked]** = re-read and confirmed; **[corrected: …]** = the claim was wrong or imprecise, with what changed; **[added]** = missing before. The largest corrections: the CDFJ+ 6507-side RAM address wraps inside 32 KB, so the `over32k` class cannot occur (sections 7.5, 7.6, 8); the DPC+ NOTE frequency lands at E0+10 at the earliest, not E0+9 (7.6); `+hard_reset_at` must be timed in `clk_sys`, not frames, because the frame counter stops during a reset (7.2); the hold needs a sticky guard so the console reset never drops between upstream's init and `daria_fe`'s (7.4.2); `arm_call_stall` has four readers, not two (7.4.2); `d_rst` is three `clk_d` flops, not two (4); `d_addr`'s width (7.4.3). Section 9 now answers the open questions the RTL settles. Section 10 lists the guards to build. Per the user's decision for this run, a guard is built whenever it costs little and does not put the core out of step with upstream.

Contents: 0 Conventions · 1 The bench today · 2 The 6507 cycle in clk_sys · 3 Tap list · 4 The step 5 shadow · 5 The POKEY shadow · 6 clk_d · 7 The plan · 8 Limits · 9 Open questions and answers · 10 Guards to build.

---

## 0. Conventions

- **E0** is the `clk_sys` rising edge at which `dut.pclk1` is sampled high. **E0+k** is k `clk_sys` edges later. Phase 2 (`dut.pclk0`) is sampled at **E0+6**, and the next phase 1 at **E0+12**:
  - TIA's divider steps once per `pclk_edge` (every 2 `clk_sys`), with phase 2 at `pclk_div==2` and phase 1 at `pclk_div==5` (RTL/TIA.sv:505-506, 556-557);
  - the bench's own `SYS_PER_CPU = 12` (D/tb_daria.sv:85).

  Same convention as `docs/daria_fe/spec/glue.md` §0 and `docs/daria_fe/spec/audio.md` §0.1. [checked]

  [added] **When 12 does not hold.** `pclk_edge` is MARIA's `tia_clk_x2` (top.sv:448, 490; Maria/maria.sv:153-154), one `clk_sys` in two. The divider is set to 4 while the console is in reset (TIA.sv:569-570). It is set to 2 at `hclk.edge_p2 && rsynd` (TIA.sv:565-567). `rsynd` fires at every line end and after an RSYNC write (TIA.sv:610, 647). At a normal line end this is meant to be a no-op, because 228 colour clocks are 76 CPU cycles. After a mid-line RSYNC it re-phases the CPU clock. `resp0` can also bring phase 1 early at `pclk_div==0` (TIA.sv:506, 528). Before the TIA takes over, the phases are MARIA's: after every console reset the source starts on MARIA and hands over to the TIA once `ctrl_writes==2 && tia_en` (top.sv:259-260, 1230-1345). Consecutive `pclk0` edges are always at least 4 `clk_sys` apart: the phases alternate, and each needs its own `pclk_edge` (TIA.sv:505-509, 560-563; top.sv:1420-1427). S1 (7.5) measures the real spacing.
- **"Valid from E0+k"** [added] in section 2 means *registered at edge E0+k*. The value can first be read (pre-edge) at E0+k+1.
- **Pre-edge sampling.** In a bench block `always @(posedge clk_sys)`, any DUT signal read is its value just before that edge: register outputs before their NBA updates, and combinational signals derived from them. "Compare at E0+6" therefore means "the values the 6507 latches at E0+6". [checked]
- **Upstream's `clk_arm`** in this bench is 5 × `clk_sys`, rising together with `clk_sys` on every `clk_sys` edge (D/tb_daria.sv:77-81). **A(k)** is the k-th `clk_arm` edge with S(n) = A(5n) (glue.md §0). [checked; [added] in absolute bench time, counting the `clk_arm` rise at 6,984 ps as edge 0, `clk_sys` edge n is `clk_arm` edge 5n+2 (section 1.2). Only the coincidence matters, so the two indexings are equivalent.]
- **DARIA's clock** in the bench is `clk_d`, 8 per 3 `clk_sys` (D/daria_shadow.svh:53-56; section 6). [checked]
- Scheme codes (RTL/detect2600.sv:2-8): DPC+ = `BANKDPCP` = 21, CDF family = `BANKCDF` = 23 (revision 0 = CDF0, 1 = CDF1, 2 = CDFJ, 3 = CDFJ+), `BANKBUS` = 24, `BANKELF` = 32. [checked; [added] the DPC+ revision is 1 when the 3 KB driver's CRC32 is 0xA08CFB13, else 0 (detect2600.sv:223-225). It reaches `mapper_dpcplus` as `stable_fractional` = `mapper_revision[0]` (cart2600.sv:811), the FRACLOW mask (mapper_dpcplus.sv:255-258).]

---

## 1. The bench as it stands

### 1.1 Files

| File | Role |
|---|---|
| `D/tb_daria.sv` (1,009 lines) | Top `tb_daria`. Instantiates upstream's `Atari7800` (`RTL/top.sv`) as `dut` (tb_daria.sv:190-222), MiSTer configuration: ARM mapper live, `clk_arm` = 5 × `clk_sys`, a behavioural DDR3 (tb_daria.sv:131-173), the 6507-side ROM as a 1-clock block RAM (:124-129), `detect2600` and `a78_cart_extent` outside the core (:103-122). Records every ARM call: `calls.csv`, `slack.csv`, `zero.csv`, `frames.csv`, `summary.txt`, `pcs.txt`, snapshots, and optionally `dtrace.txt`, `mmio.csv`, `fp.csv` (:12-37). Includes `daria_shadow.svh` under `DARIA_SHADOW` (:1006-1008). [checked] |
| `D/daria_shadow.svh` (470 lines) | Step 5: DARIA's CPU (`bup_cpu`, `daria_mem`, `daria_call`, `daria_mmio`), or with `DARIA_WRAPPER` the whole `bupchip_pocket`, on `clk_d`. Runs the same calls as upstream's ARM and compares them call by call (section 4). [checked] |
| `D/run_daria.sh` (112 lines) | Builds with Verilator and runs one image. Gzips outputs and runs `summarize.py` (section 1.5). [checked] |
| `D/run_all.sh` (27 lines) | Builds once (`--build-only`), runs every `.bin` in a directory with `xargs -P ${JOBS:-2}` and `NOBUILD=1`, then `summarize.py --table` (run_all.sh:11-27). [corrected: it skips a run that has `report.txt` unless `FORCE` is set to *any* non-empty value, `FORCE=0` included; the test is `[ -z "$FORCE" ]`, run_all.sh:24] |
| `D/summarize.py` | Per-run report and cross-run table from `calls.csv.gz`, `slack.csv`, `zero.csv` and `frames.csv`. Scheme names come from `(force_bs, revision)`: (21,0/1) DPC+, (23,0..3) CDF0/CDF1/CDFJ/CDFJ+ (summarize.py:28-29). [checked] |
| `D/dynamic_tables.py` | Report sections over many runs (`--only SECTION,...`). `sec_daria` reads `daria.csv` and the `DARIA shadow:` line of `run.log` (dynamic_tables.py:612-659). A new `sec_fe` belongs here (section 7.7). [checked; [added] `sec_daria` takes the skipped count from the third comma-separated field of that line (:639-640). A change to `daria_shadow.svh` must leave the line's first three fields as they are.] |
| `D/frontend_study/README.md` | The front-end study. §5 test 1 is the shadow this file specifies. [checked] |

### 1.2 Clocks in the bench [checked]

`timescale 1ps/1ps` (tb_daria.sv:74).

| Clock | Source | Half period | Rising edges at (ps) | Note |
|---|---|---|---|---|
| `clk_sys` | tb_daria.sv:79-80, `logic clk_sys = 0; always #34920` | 34,920 ps | 34,920 + 69,840·k | 14.3184 MHz. The bench uses 69.840 ns, not 69.8413. [added] That makes `clk_arm` exactly 5 × (69,840 = 5 × 13,968), and 3 `clk_sys` = 8 `clk_d` exactly (209,520 ps). |
| `clk_arm` (upstream) | tb_daria.sv:79, 81, `always #6984` | 6,984 ps | 6,984 + 13,968·m | Exactly 5 × `clk_sys`. A(5k+2) coincides with every `clk_sys` rise (m = 2 + 5k). |
| `clk_d` (DARIA) | daria_shadow.svh:54-55, `logic clk_d = 0; always #13095` | 13,095 ps | 13,095 + 26,190·n | 38.18 MHz, 8 per 3 `clk_sys`. Never coincides with `clk_sys` (section 6). |
| `clk_74a` | daria_shadow.svh:66-67, `#6734` (WRAPPER only) | 6,734 ps | | Unrelated to the others. |

### 1.3 How the image is loaded: the ioctl stream [checked]

Before the stream (tb_daria.sv:893-897): `$fread` fills `img[0:512K-1]` (:850), and `rom[]` (the 6507-side ROM, :126) gets the same bytes directly. The 6507 side therefore never depends on the stream. Only the core's DDR shadow, `detect2600`, `a78_cart_extent`, `cdf_fastjump_table` and the upstream init do. [added] So do the ARM memory's `rom_size` (captured from the stream's end, arm_mapper_memory.sv:769-777) and `rom_do` during the download (`cart_out = cart_download ? ioctl_dout : cart_q`, :198).

The stream itself (tb_daria.sv:926-952):

1. 50 `clk_sys` with `arm_reset = 1`; then `arm_reset = 0`; then 50 more (:928-930).
2. `cart_download = 1` (:931). For each byte i:
   1. one `@(posedge clk_sys)`;
   2. `load_gap` more (0 in MiSTer mode, 1 with `DARIA_WRAPPER`, :137-141);
   3. wait while `mapper_load_wait` (the ARM mapper's DDR shadow backpressure, top.sv:955);
   4. NBA `ioctl_addr <= i; ioctl_dout <= img[i]; ioctl_wr <= 1`, and at the next edge `ioctl_wr <= 0` (:932-940).

   So `ioctl_wr` is high for exactly one sampled edge per byte, at least 2 `clk_sys` apart.

   [added] `cart_download`, `tia_mode`, `reset_in` and `running` are **blocking** writes made in the `initial` block just after an `@(posedge clk_sys)` (:931, 942-943, 949, 952). Which value the clocked blocks of that same timestep see is up to Verilator's scheduler. It is the same for every clocked block, so a shadow must derive `load_start`/`load_end` from the same expressions as the DUT (`~old_cart_download && cart_download`, `old_cart_download && ~cart_download`). It must not re-time them with its own flops.
3. 4 edges, `cart_download = 0`, then `tia_mode = 1` (:941-943). `load_end = old_cart_download && ~cart_download` is high for one edge (:119, :206). `old_cart_download` is registered at :99.
4. The core's load ports (tb_daria.sv:204-207):
   - `mapper_load_start = ~old_cart_download && cart_download`;
   - `mapper_load_valid = ioctl_wr && cart_download`;
   - `mapper_load_addr = ioctl_addr`, `mapper_load_data = ioctl_dout`;
   - `mapper_load_end` as above.

   `detect2600` takes the same strobes (:115-122). `cart_out` is `ioctl_dout` during the download and `cart_q` after (:198).
5. 4 edges; the bench prints the detect results (:944-947); 20 edges; `reset_in = 0` (:948-949); then it waits while `reset` (:950).
6. The DUT's `reset` is a bench register: `reset <= reset_in | cart_download | old_cart_download | mapper_init_busy` (tb_daria.sv:98-101). The console therefore stays in reset until upstream's RAM image is built (`arm_mapper_ram_init`: `busy` at RTL/arm_mapper_ram_init.sv:75, started by `load_end_d` at :212-219; `load_end_d` is `load_end` one clock late, cart2600.sv:572-577). [added] `busy` is already high from `load_start` (`loading`, arm_mapper_ram_init.sv:207-208), so it covers the whole download.
7. `running = 1` (:952). Frames are counted on the rising edge of the TIA's raw VSYNC bit (`dut.tia_inst.vsync_o`, :242, 755-775). The run ends after `+frames` frames (:953).

   [added] `running` rises when the bench's `reset` register falls. `effective_reset = reset | reset_hold` (top.sv:255) falls later, at the next MARIA phase 1 (top.sv:266-286; `first_phase_is_phi1` is 0 here because `tia_clock_after_reset` is 1, :254, 261-262). `ctrl_reg` then sets `lock_ctrl` and `tia_en` one clock later (top.sv:1376-1382). The checks of section 7.5 therefore start at the first E0 with `!dut.effective_reset && dut.tia_en`, not at `running`.

`detect2600`'s outputs are registered at the `load_end` edge (RTL/detect2600.sv:206-237). The CDFJ+ entry and stack come from file offsets $17F8 and $17F4 as they stream (:196-201). The LDX/LDY flags, fetch offset and audio size word come from the first 2 KB or 3 KB (:139-170). [checked; [added] `force_bs`, `sc` and `mapper_revision` are cleared at `load_start` and set at `load_end` (:204-237). The other outputs are registered as the bytes stream.]

The console's RESET and SELECT switches (`+reset_at`, `+select_at`) go to `PBin` (tb_daria.sv:181, 787-812). They are game inputs, not the reset line. **The bench never pulses the console reset after the load**, so upstream's re-init on a reset edge (arm_mapper_ram_init.sv:222-226) is never exercised. [checked; [added] the re-init is on the **rising** edge of `mapper_reset` (= `effective_reset`), and only while `image_loaded` and idle (:205, 223).]

### 1.4 The DUT hierarchy [checked: every instance name and line]

`tb_daria.dut` is `Atari7800` (tb_daria.sv:190). Instances on the 2600 ARM path:

```
dut (Atari7800, RTL/top.sv)
├─ phase_controller   cpu_phase_controller                     top.sv:397
├─ cpu_inst           M6502C                                   top.sv:712
│   └─ cpu            sally                                    top.sv:1440
│       └─ core       mos6502                                  6502/sally.sv:213
│           ├─ ctl    mos6502_ctl                              6502/mos6502.sv:87
│           └─ dp     mos6502_dp                               6502/mos6502.sv:97
├─ tia_inst           TIA (phases, RDY, vsync_o)               top.sv:487
│   └─ clockgen       clockgen (pclk_div)                      TIA.sv:1992   [added]
├─ riot_inst          M6532 (patched copy)                     top.sv:681
├─ ctrl               ctrl_reg (lock_ctrl, tia_en)             top.sv:735
├─ arm_host           arm_host (ARM7TDMI; not read here)       top.sv:810
├─ ddr_bridge         ddram                                    top.sv:859
├─ cart_ram           cart_ram_tdp                             top.sv:918
│   └─ ram_lane[0..3].lane_ram   cache_ram_tdp_dc (8-bit, 32K words)  cart_ram_tdp.sv:68-84
└─ cart2600           cart2600                                 top.sv:1114
    ├─ arm_mappers    arm_mapper_subsystem                     cart2600.sv:442
    │   ├─ call_controller  arm_mapper_controller              arm_mapper_subsystem.sv:119
    │   └─ memory           arm_mapper_memory                  arm_mapper_subsystem.sv:158
    ├─ stream_tables  arm_mapper_tables                        cart2600.sv:675
    │   ├─ pointer_ram    cache_ram_tdp_dc_be (64 × 32)         arm_mapper_tables.sv:157
    │   └─ increment_ram  cache_ram_tdp_dc_be (64 × 32)         arm_mapper_tables.sv:172
    ├─ ram_init       arm_mapper_ram_init                      cart2600.sv:708
    ├─ table_writeback arm_mapper_writeback                    cart2600.sv:739
    ├─ mapper_audio   arm_mapper_audio                         cart2600.sv:760
    ├─ dpcplus        mapper_dpcplus                           cart2600.sv:803
    ├─ cdf            mapper_cdf                               cart2600.sv:841
    ├─ jump_table     cdf_fastjump_table (map_ram: cache_ram 32K × 1)  cart2600.sv:886
    └─ bus            mapper_bus (out of DARIA's scope)        cart2600.sv:900
```

All of `dpcplus`, `cdf` and `bus` are always instantiated. The ones not selected are held in reset (`reset || mapper != BANKx`, cart2600.sv:805, 843, 902). The memories' arrays are `mem_q` in their simulation branch (RTL/cache_ram.v:160 for `cache_ram_tdp_dc`, :259 for `_be`, [added] :58 for `cache_ram`). `daria_shadow.svh` already reads `dut.cart_ram.ram_lane[k].lane_ram.mem_q[i]` (daria_shadow.svh:256-258), and the bench reads `dut.cart2600.arm_mappers.call_controller.control_state` (tb_daria.sv:235). Hierarchical references this deep work in this Verilator build.

[added] **Simulation read-during-write.** `cache_ram_tdp_dc` and `_be` return the new data on the writing port (`q <= wren ? wdata : mem_q[addr]`, cache_ram.v:172-182, 269-285). The `_be` version returns the whole `wdata` word even for a partial byte enable. A read on the other port in the same timestep returns the old data, because the write is an NBA.

### 1.5 Build flags and run times

`run_daria.sh` (D/run_daria.sh:23-112): [checked]

- **Verilator:** `/opt/verilator-5.040/bin/verilator` if present, else `verilator` (:28). The file says it was tested with 5.040 (:12).
- **Work directory:** `WORK=${WORK:-sim/work/bupchip/daria}` (:27).
  - `$WORK/rtl/{palettes,Minnie,ooo.hex}` are symlinks, because the sources read tables relative to the working directory (:37-39).
  - Patched copies of `Maria/control.sv`, `banks2600.sv`, `video_mux.sv` and `RIOT/M6532.sv` turn initialised unpacked `wire` arrays into `logic` (:40-46).
- **Sources** (:48-67): `sim_stubs.sv`, arm7tdmi (pkg, core), `arm_host`, `ddram`, the 6502, MARIA, POKEY, Minnie, SN76489, jt51, `cache_ram.v`, `bram.v`, `composite_out`, `cart_ram_tdp`, `cdf_fastjump_table`, `arm_mapper_{memory,controller,subsystem,tables,ram_init,writeback,audio}`, `mapper_{dpcplus,cdf,bus,fa2}`, `fa2_nvram_bridge`, `ps2_to_pokey`, `souper`, `TIA`, `cart`, `cart2600`, `banks2600` (patched), `video_mux` (patched), `detect2600`, `a78_cart_extent`, `M6532` (patched), `top.sv`, `EEPROM_24LC256`, `lightgun`, `tb_daria.sv`.
- **Defines and flags** (:88-91):

  ```
  --binary --timing -j 2 -O3 --x-assign fast --x-initial fast
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD
  -DNO_BUPCHIP -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ
  --top-module tb_daria -Mdir $OBJ -o vtb
  ```

  - No `NO_ARM_MAPPER`, so the ARM and front ends are live. [corrected: cart2600.sv:441 is an `` `ifndef NO_ARM_MAPPER `` whose own branch, the `arm_mappers` instance, is taken. cart2600.sv:585 is an `` `ifdef NO_ARM_MAPPER `` whose `` `else `` branch, :651-954 with the front ends, is taken.]
  - No `NO_DDRAM` (`ddr_bridge` is live; the bench's DDR model answers it).
  - No `EXTERNAL_CARTRAM` (the in-core `cart_ram_tdp` is used, top.sv:913-942).
- **`SHADOW=1`** adds `bup_cpu.sv`, `daria_mem.sv`, `daria_call.sv` and `daria_mmio.sv`, plus `-DDARIA_SHADOW -DDARIA_WIN_KB=${WIN_KB:-128} -I$HERE`. Object directory `obj_shadow<WIN>`, runs in `runs/shadow<WIN>/` (:70-74, 97-99).
- **`WRAPPER=1`** (with `SHADOW=1`) adds `bupchip_peripheral`, `bup_tick48k`, `bup_capture`, `bup_asset_wr`, `bup_asset_cache`, `bupchip_pocket`, `pocket_utils/psram.sv` and `s4/psram_model.sv`, plus `-DDARIA_WRAPPER -DPOCKET_DARIA`. Object directory `obj_wrap<WIN>` (:75-81).
- **Rebuild check:** the binary is rebuilt if any source or `daria_shadow.svh` is newer (:84-86). A new `fe_shadow.svh` must be added to that `find`. [added] With `NOBUILD=1` the check is skipped whenever the binary exists.
- **Run:** `vtb +rom=… +out=… +dtrace=${DTRACE:-1} "$@"` from `$WORK`, logging to `run.log` with a final `wall N s` line. Then `ppm2png`, gzip of `calls.csv`, `pcs.txt` and `dtrace.txt`, and `summarize.py > report.txt` (:104-112).

**Measured** (the existing `run.log` and `obj_*.log` files in `sim/work/bupchip/daria/`): [checked: every number re-read from those files]

| Build | Verilator walltime | 1,500 frames (about 25 s emulated), wall |
|---|---|---|
| plain (`obj`) | (not logged) | 1,985–3,244 s per image (21 images) |
| `SHADOW=1`, 128 KB | 19.4 s | 3,803–8,282 s |
| `WRAPPER=1`, 64 KB | 37.8 s | 5,549 s (Turbo) |
| `WRAPPER=1`, 32/48 KB | 17.3 s (32 KB) | about 14,900–15,000 s |

The FE shadow adds per-`clk_sys` work: one comparison per latch, a state compare per 6507 cycle, and a small RAM model. An estimate is +20 to +60% over a plain run [E]. `DTRACE=0` and `+snap=0` save time and disk.

[added] **What the image set exercises** (from those runs' `summary.txt`: scheme fields on line 1, `dma_events`/`dma_sys` on line 2): 4 DPC+ images (3 revision 0, 1 revision 1), 3 CDF1, 7 CDFJ, 7 CDFJ+, **no CDF0**. **`dma_events` is 0 in all 21 runs**, so no image issued a DPC+ copy/fill (CALLFUNCTION 1 or 2) in its 1,500 frames under the bench's input script. Section 8 lists the consequences.

---

## 2. A 6507 cycle in clk_sys units (what the shadow is timed against)

| Edge | Upstream (MiSTer config, tb_daria's 1-clock ROM) | Source |
|---|---|---|
| **E0** | `pclk1`. The CPU loads ABL/ABH, `wr_pin`, `sync_pin` and `dor` on `phi1_en`, so `AB`, `RW` and the write byte (`write_DB` = `dor`) change just after E0 and hold for the whole cycle. [checked; [added] the CPU samples RDY here, once per cycle; a cycle right after a write is never held (`rdy_cy`, `wr_q`; mos6502_ctl.sv:874-881)] | 6502/mos6502_dp.sv:200-226, 320; 6502/mos6502.sv:129-134; top.sv:712-733 |
| (E0, E0+1) | `address_change = old_ain != a_in` is high (if the address changed). It suppresses `cartram_rd/wr`. [corrected: it does not "make" `rom_read`. `rom_read = ~address_change` (cart2600.sv:157) is *low* in this window. It drives only the core's `cart_read` output, which tb_daria leaves unconnected (tb_daria.sv:198).] | cart2600.sv:157, 241, 263-265, 973-976 |
| **E0+1** | The ROM byte registers: `cart_q <= rom[cart_addr]`, with `cart_addr = rom_a` (combinational from `a_in` and the bank). `rom_do` is valid from E0+1. Registered reads of the DPC+ RAM address taken from `a_in` alone (DFxDATA etc. at $1008+) also land at E0+1. The jump map's `map_q` (address `rom_a[14:0]`) registers at E0+1. [corrected: the RAM's registered read is at cache_ram.v:172-176. cart_ram_tdp.sv has only 86 lines; :173-175 does not exist] | tb_daria.sv:129, 198; mapper_dpcplus.sv:127-128, 137-143; cdf_fastjump_table.sv:26-53; cart_ram_tdp.sv:61-64; cache_ram.v:172-176 |
| **E0+2** | DPC+ fast fetch: the RAM address comes from `rom_data` (operand < $28), so the RAM byte is valid from E0+2. CDF: `table_index` (from `rom_data`) → `stream_tables` registered q (`table_pointer`, `table_increment`) valid from E0+2. [checked] | mapper_dpcplus.sv:112-143, 174-176; mapper_cdf.sv:114-121; arm_mapper_tables.sv:151-185 |
| **E0+3** | CDF stream byte: the RAM address is `$800 + P[31:20]` (CDFJ+ `P[30:16]`) from `table_pointer`, so the RAM q is valid from E0+3. `d_out` is final for every DPC+/CDF read path by E0+3, i.e. readable from E0+4. [checked; [added] the address is computed in **15 bits** (`display_address`, `ram_addr` are `[14:0]`, mapper_cdf.sv:36, 75, 126-128), so CDFJ+'s `$800 + P[30:16]` **wraps modulo $8000**. `cartram_addr[17:15]` is always 0 for CDF (cart2600.sv:898)] | mapper_cdf.sv:126-128, 140-148 |
| E0+2..E0+6 | A DPC+ WRITE/PUSH (`$1x78-7F`, `$1x60-67`) drives `cartram_wr` on every edge from E0+2 to E0+6: high while `~phi1 && ~address_change && ~access_taken`. The byte is `d_in` = `write_DB`, stable since E0. The last write, at E0+6, is the one that counts. [corrected: from **E0+1** when the write's address equals the previous cycle's (no `address_change` at E0+1; `access_taken` was cleared by `phi1` at E0, cart2600.sv:256-261), for example the second write of a RMW. The address and byte are the same on every edge (the counter steps only at the E0+6 commit), so the final RAM contents do not change. The strobe has no `access` term: it also writes during a stall or with `arm_driver_run` low.] | cart2600.sv:256-261, 973-974, 977; mapper_dpcplus.sv:144-158 |
| (E0+5, E0+6) | `pclk0` high, and `mapper_phi2 = pclk0 && (!arm_call_stall \|\| !stall_cycle_taken)`, so `access = mapper_phi2 && lock_ctrl && tia_en`. [checked] | top.sv:327, 1133-1136; cart2600.sv:247 |
| **E0+6** | **Latch:** `dl <= data_in`. **Commit**, if `access && a_in[12]`: bank, fetchers, random, fast-fetch and jump trackers, `call_pending`, `service_pending`, `mode`, `pointer_update`, `audio_note_write`. A CDF DSWRITE writes RAM on this one edge only (`ram_en` needs `access`). RIOT write latch. `access_taken <= 1`. [checked; [added] `access_taken` is set by `mapper_phi2`, not by `access` (cart2600.sv:259-260)] | mos6502_dp.sv:267, 299; mapper_dpcplus.sv:193-325; mapper_cdf.sv:150-156, 164-253; cart2600.sv:255-261; top.sv:684 |
| (E0+6, E0+12) | Upstream's `d_out` stays combinational and can change: the next fetcher byte, or the ROM operand after `fast_pending` clears. `open_bus <= DB` every edge, so the cycle ends holding upstream's post-commit byte. [checked] | top.sv:348-352, 379-395; study §2.1 |
| **E0+7** | CDF table write (`sys_pointer_write`) and writeback payload capture (`mapper_wb_idle` low from E0+7 to E0+9). Controller accept: `call_request` → `call_busy`, payload, `call_toggle`. Audio seeds (`call_launch`, BUS/CDF). DPC+ service → `dma_busy`. DPC+ `note_pending`. [checked; [added] the writeback's RAM write lands at the 4th `clk_arm` edge after E0+7 (E0+7.8, a non-shared edge), and `mapper_wb_idle` reads high again pre-edge at E0+10 (arm_mapper_writeback.sv:91-131, 56-57). At the E0+7 edge the pointer table's lookup address is the write index, so `table_pointer` is the written value during (E0+7, E0+8] (arm_mapper_tables.sv:151-152)] | cart2600.sv:663-673, 687-691; arm_mapper_writeback.sv:40-41, 61-65; arm_mapper_controller.sv:149-161; arm_mapper_audio.sv:201-211; arm_mapper_memory.sv:335-343; glue.md §7.5, §9 |
| **E0+8** [added] | `arm_call_stall` reads high pre-edge after a call accept or a DPC+ service accept, from `call_busy`/`dma_busy` set at E0+7. DPC+ NOTE: `AUDIO_NOTE_ISSUE` is entered here if the audio engine is idle. | top.sv:306-307; arm_mapper_audio.sv:226-228 |
| **E0+9** [added] | DPC+ NOTE: `AUDIO_NOTE_CAPTURE` is entered if `ram_grant` is high pre-edge, and the frequency word's address registers in port A. | arm_mapper_audio.sv:243-246; cart2600.sv:965-967 |
| **E0+10** [added] | DPC+ NOTE: **`frequencyN <= ram_word_data`** at the earliest. A tick at this edge still adds the old frequency. | arm_mapper_audio.sv:248-257 |
| **E0+12** | Next E0. | |

**Stalls.** `arm_call_stall = tia_en && (arm_call_busy || (!mapper_init_busy && arm_dma_busy))` drives `RDY` low (top.sv:306-307, 328-329). The phases keep running: `pclk1`/`pclk0` come from `M6502C`'s pairing gate, not from RDY (top.sv:1420-1427). The held read is presented every cycle, but the front ends see only its first phase 2 (`stall_cycle_taken`, top.sv:320-327). The CPU still executes `dl <= data_in` at every `pclk0` (mos6502_dp.sv:267-299). [checked; [added] the CPU reads RDY once per cycle at phase 1, and the cycle after a write is never held (mos6502_ctl.sv:874-881). So after a CALLFN write W the opcode fetch F completes, its phase 2 at E0+18 is the "taken" one, and the next cycle O is the held one, showing F's address (glue.md §7.5). `dl` is overwritten at each held `pclk0`. The CPU consumes only the latch of the cycle that completes.]

The release-phase artefact (the stalled address shown to the mapper once more) is described in glue.md §7.5. The shadow sees it automatically, because it takes `access` from upstream. [checked]

---

## 3. Tap list: exact hierarchical paths [checked: every path exists with the stated name and width]

All paths are relative to `tb_daria`. Widths are in brackets.

### 3.1 The 6507 bus and phases

| What | Path | Note |
|---|---|---|
| phase 1 / phase 2 enables | `dut.pclk1`, `dut.pclk0` | = `cpu_inst.phi1_ce`/`phi2_ce` (top.sv:236, 716-717); `dut.cpu_ce` = `pclk1` (:335) |
| raw source phases | `dut.pclk1_raw`, `dut.pclk0_raw`; TIA's divider `dut.tia_inst.clockgen.pclk_div[2:0]` [corrected: the path was elided] | top.sv:237, 405-406; TIA.sv:493, 1992 |
| phase source [added] | `dut.phase_source_tia` (1 once the TIA drives the phases), `dut.phase_controller.state` | top.sv:238, 259-260, 1246-1345 |
| address bus | `dut.AB[15:0]` (resolved), `dut.cpu_AB[15:0]` (CPU pins) | top.sv:366-372 |
| front-end address | `dut.cart2600.a_in[12:0]` = `{AB[12] & bios_en_b, AB[11:0]}` | top.sv:1128 |
| R/W | `dut.RW` = `dut.cart2600.rw` | top.sv:377, 1129 |
| write byte | `dut.write_DB[7:0]` (= `dor`) | top.sv:210, 722; mos6502_dp.sv:320 |
| front-end data in | `dut.cart_din[7:0]` = `dut.cart2600.d_in` (`RW ? read_DB : write_DB`) | top.sv:1112, 1125 |
| what the CPU latches | `dut.read_DB[7:0]` (pre-edge at E0+6); the CPU's latch is `dut.cpu_inst.cpu.core.dp.dl` | top.sv:379-395; mos6502_dp.sv:299 |
| open bus | `dut.open_bus[7:0]`; [added] the bus as driven, `dut.DB` = `cpu_DB_oe ? physical_write_DB : read_DB` | top.sv:346, 348-352 |
| chip selects | `dut.cs_cart` (= `~\|{cs_ram0, cs_ram1, cs_tia, cs_riot, cs_maria}`), `dut.cs_tia`, `dut.cs_riot`; partial-drive masks `dut.tia_DB_oe`, `dut.riot_DB_oe` | top.sv:226, 354, 218 [corrected: the pipe in the code span is escaped so the table renders] |
| other drivers (for O1) [added] | `dut.tia_DB_out`, `dut.riot_DB_out`, `dut.maria_DB_out`, `dut.maria_DB_oe`, `dut.ram0_DB_out`, `dut.ram1_DB_out`, `dut.cs_ram0`, `dut.cs_ram1`, `dut.cs_maria`, `dut.bios_sel`, `dut.cpu_DB_oe`, `dut.physical_write_DB` | top.sv:213-226, 355, 379-394 |
| SYNC (opcode fetch) | `dut.cpu_inst.cpu.sync` | tb_daria.sv:633 uses it |
| RDY | `dut.RDY` | top.sv:328-329 |

### 3.2 Access, driver run, stall

| What | Path | Note |
|---|---|---|
| `mapper_phi2` | `dut.mapper_phi2` = `dut.cart2600.phi2` | top.sv:327, 1135 |
| `stall_cycle_taken` | `dut.stall_cycle_taken` | top.sv:320-326 |
| `arm_driver_run` | `dut.cart2600.arm_driver_run` = `dut.lock_ctrl && dut.tia_en` | top.sv:1136 |
| `access` | `dut.cart2600.arm_access` | cart2600.sv:247 |
| `access_taken` | `dut.cart2600.access_taken` | cart2600.sv:255-261 |
| stall | `dut.arm_call_stall`, `dut.arm_call_busy`, `dut.arm_dma_busy`, `dut.mapper_init_busy` | top.sv:252, 306-307, 802; tb port `mapper_init_busy` |
| console reset seen by the mappers | `dut.effective_reset` (= `reset \| reset_hold`) = `dut.cart2600.reset` | top.sv:255, 1130 |

### 3.3 Scheme and detect outputs

| What | Path |
|---|---|
| `force_bs[5:0]`, `mapper_revision[2:0]`, `cdf_ldx`, `cdf_ldy`, `cdf_fetch_offset_enable`, `cdf_fetch_offset[7:0]`, `cdfj_entry[31:0]`, `cdfj_stack[31:0]`, `arm_audio_size_addr[15:0]`, `sc` | tb wires `force_bs`, `mapper_revision`, … (tb_daria.sv:107-122), the outputs of `detect`. The same values reach `dut.cart2600.mapper_revision` etc. |
| mapper actually used | `dut.cart2600.mapper` (= `\|mapper ? mapper : force_bs`; tb ties `.mapper(6'd0)`, so `force_bs`) |
| image size | tb `cart_size` = `dut.cart2600.rom_size` (top.sv:1148). [added] **Not** the tb's `rom_size` wire (tb_daria.sv:237). That one is `arm_mapper_memory`'s copy, clamped to 1 MiB and captured at the stream's end (arm_mapper_memory.sv:769-777). `arm_mapper_audio` uses the unclamped `cart_size` (cart2600.sv:765). |
| RAM size | `dut.mapper_ram_size[15:0]` (32768 for CDFJ+, else 8192; top.sv:778-783) |
| families | `dut.cart2600.init_family` (DPC+ 1, BUS 2, CDF 3), `dut.cart2600.table_family` (BUS 1, CDF 2) (cart2600.sv:652-660) |
| init [added] | `dut.cart2600.load_end_d` (cart2600.sv:572-577); `dut.cart2600.ram_init.{state, loading, image_loaded, active_family, active_revision, active_ram_size, table_index}` (arm_mapper_ram_init.sv:58-73); `dut.cart2600.init_ram_en` |

### 3.4 Mapper outputs (what the 6507 sees)

| What | Path | Note |
|---|---|---|
| final cartridge byte / drive mask | `dut.cart2600.d_out`, `dut.cart2600.oe` (= `dut.cart_2600_DB_out`, `dut.cart_2600_DB_oe`) | cart2600.sv:211-233 picks between direct, ROM and RAM. [added] A write-port cycle (`ram_sel` with `!ram_rw`) gives `d_out = 0`, `oe = 0` (:224-228). |
| DPC+ raw | `dut.cart2600.dpcplus.{d_out, flags_out, oe, rom_a, ram_sel, ram_rw, ram_a}` | mapper_dpcplus.sv:112-181 |
| CDF raw | `dut.cart2600.cdf.{d_out, flags_out, oe, rom_a, ram_en, ram_write, ram_addr, table_index}` | mapper_cdf.sv:114-157 |
| ROM address / byte | `dut.cart2600.rom_a` = tb `cart_addr`; `dut.cart2600.rom_do` = tb `cart_q` after the load | tb_daria.sv:128-129, 198. [added] `cart_addr` is the 2600 address only while `tia_en` (top.sv:332). |
| 6507-side cart RAM port | `dut.cartram_addr[17:0]`, `dut.cartram_wr`, `dut.cartram_rd`, `dut.cartram_wrdata`; data `dut.cart2600.cartram_data` | top.sv:752-759; cart2600.sv:965-978 |
| port A arbitration [added] | `dut.cart2600.sel_ram_sel`, `dut.cart2600.init_ram_en`, `dut.cart2600.audio_ram_en`, `dut.cart2600.audio_ram_addr[16:0]`, `dut.cart2600.audio_ram_grant` (= `audio_ram_en && !init_ram_en && !sel_ram_sel`). Address priority: init, then the 6507 mapper, then audio. | cart2600.sv:965-967 |
| read-path classifiers | DPC+: `dut.cart2600.dpcplus.{register_read, register_address, read_function, read_index, ram_register_read, window_set}`. CDF: `dut.cart2600.cdf.{fetch_substitute, jump_substitute, stream_substitute, amplitude_fetch}` | mapper_dpcplus.sv:62-69, 107-125; mapper_cdf.sv:59-75, 99-112 |

### 3.5 Commit state

**DPC+**, `dut.cart2600.dpcplus.` (mapper_dpcplus.sv:47-60). [checked; [added] every field below resets to 0 except where noted, synchronously on `reset || mapper != BANKDPCP` (:193-219, cart2600.sv:805)]

| Field | Note |
|---|---|
| `bank[2:0]` | reset 5; hotspots $1FF6-$1FFB → 0..5, on reads and writes, not on a register read (:230-232) |
| `top[0:7][7:0]`, `bottom[0:7][7:0]` | |
| `counter[0:7][11:0]`, `fractional[0:7][19:0]`, `increment[0:7][7:0]` | |
| `random_number[31:0]` | reset `0x2B435044` |
| `fast_fetch`, `fast_pending` | |
| `params[0:7][7:0]`, `parameter_pointer[3:0]` | [added] `params[4..7]` are write-only. Nothing reads them (:85-101, 284-290). The pointer counts to 8 and stops (:273-276). A clone that keeps 4 params is equivalent if its pointer saturates at 4. Compare `min(parameter_pointer, 4)`. |
| `waveform[0:2][6:0]` | |
| `call_pending`, `call_request` | [added] `call_request = call_pending && call_ready` is combinational (:183). The pending flag clears at the accept edge (:222-223). |
| `service_pending`, `service_request`, `service_fill`, `service_source[18:0]`, `service_dest[14:0]`, `service_count[7:0]`, `service_value[7:0]` | [added] a CALLFUNCTION 1/2 while `service_pending` is ignored entirely, including the pointer reset; a CALLFUNCTION FE/FF while `call_pending` is ignored (:278-295) |
| `audio_note_write`, `audio_note_voice`, `audio_note_value` | one-clock pulse, high pre-edge at E0+7 (:221, 311-315) |

**CDF**, `dut.cart2600.cdf.` (mapper_cdf.sv:50-57). [checked]

| Field | Note |
|---|---|
| `bank[2:0]` | reset 6, or 0 for CDFJ+ (from `revision` at reset, :166) |
| `mode[7:0]` | reset `0xFF` |
| `fast_pending`, `fast_expected_address[12:0]` | [added] `fast_expected_address` is read only while `fast_pending` (:104-105). Compare it only then. |
| `jump_remaining[1:0]`, `expected_address[12:0]`, `jump_stream[5:0]` | [added] `jump_stream` resets to 33. `expected_address` and `jump_stream` are read only while `jump_remaining != 0` (:99-103, 114-117, 214-223). Compare them only then. |
| `call_pending`, `call_request` | |
| `pointer_update`, `pointer_update_index[5:0]`, `pointer_update_value[31:0]` | one-clock pulse, high pre-edge at E0+7 (:178, 196-203, 227-242) |

**CDF table copies** (the 6507 side's authoritative pointers and increments; cart RAM lags through the writeback, glue.md §9):

| What | Path |
|---|---|
| copies | `dut.cart2600.stream_tables.pointer_ram.mem_q[i]`, `dut.cart2600.stream_tables.increment_ram.mem_q[i]` (i < `stream_count`) |
| registered lookups | `dut.cart2600.table_pointer`, `dut.cart2600.table_increment` |
| layout | `dut.cart2600.table_pointer_base`, `table_increment_base`, `table_stream_count`. Word addresses: CDF0 0x1B8 / 0x1DA / 34, CDF1 0x028 / 0x04A / 34, CDFJ and CDFJ+ 0x026 / 0x049 / 35 (arm_mapper_tables.sv:104-121) |
| ARM writes into the copies [added] | an ARM CPU or DMA write to a table word in cart RAM also writes the copy, on `clk_arm` port B, with its byte strobes (`arm_cartram_accepted`, which excludes the writeback; arm_mapper_tables.sv:139-147; cart2600.sv:701-705) |
| fast-jump map | `dut.cart2600.jump_table.map_ram.mem_q[x]`, query `dut.cart2600.fast_jump_valid` |
| writeback | `dut.cart2600.mapper_wb_idle`, `dut.cart2600.table_writeback.{pointer_toggle, pointer_ack_sync2}`, `dut.cart2600.mapper_wb_en` |

### 3.6 Calls, service, DMA, cart RAM [checked]

**Call request** (cart2600.sv:661-662, 945-953):

- `dut.cart2600.arm_call_request` (the scheme's `call_pending && mapper_call_ready`);
- `dut.cart2600.mapper_call_ready` (= `arm_call_ready && mapper_wb_idle && !mapper_init_busy`);
- `dut.cart2600.arm_call_ready` (controller `call_ready` = `arm_online_sync2 && shadow_ready_sync2 && !mapper_reset_sys && !call_busy`, arm_mapper_controller.sv:86-87);
- entry, stack, Thumb: `dut.cart2600.arm_call_entry`, `arm_call_stack`, `arm_call_thumb`;
- the bench's tap: `call_req = arm_call_request && arm_call_ready` (tb_daria.sv:238).

**Controller** (`dut.cart2600.arm_mappers.call_controller.`):

- clk_sys side: `call_toggle`, `call_busy`, `call_done`; payload `call_entry_payload`, `call_stack_payload`, `call_thumb_payload`, `audio_counter_payload[0:2]`, `audio_frequency_payload[0:2]`; returns `audio_counter0_return` … `audio_frequency2_return`; `complete_sync2`, `complete_seen` (arm_mapper_controller.sv:50-78, 125-178).
- clk_arm side: `control_state` (5 = RUNNING, 0 = IDLE; :182-192), `active_entry`, `active_thumb`, `active_stack`, `active_audio_counter[0:2]`, `active_audio_frequency[0:2]`, `audio_read_index[2:0]`, `state_rdata`, `audio_counter_result[0:2]`, `audio_frequency_result[0:2]`, `complete_toggle`. [added] CAPTURE_AUDIO = 8 (:191).
- Return detect: `dut.cart2600.arm_mappers.memory.return_fetch` (arm_mapper_memory.sv:633; tb_daria.sv:236).
- [added] **Return timing:** `complete_toggle` flips at the `clk_arm` edge A_c that captures the last word (:346-349). S1 is the first `clk_sys` edge strictly after A_c (at a coincident edge the flop takes the old value). `complete_sync2` is new after S2. At **X = S3**, `call_busy <= 0`, the returns are loaded from the 2-flop copies, and `call_done <= 1` (:163-176). The CDF audio merge is at **X+1** (arm_mapper_audio.sv:213-223). This is glue.md's X = S(⌊A_c/5⌋+3).

**DPC+ service / DMA:**

- `dut.cart2600.dpc_service_request` (gated by `mapper == BANKDPCP`, cart2600.sv:657);
- `dut.cart2600.arm_dma_{request, fill, source, dest, count, value, ready, busy, done}` (cart2600.sv:394-399, 416-428);
- memory side: `dut.cart2600.arm_mappers.memory.{dma_busy (clk_sys), dma_state, dma_ram_en, dma_active_dest, dma_remaining}` (arm_mapper_memory.sv:228-348, 490-509, 858-893). [added] A count of 0 still raises `dma_busy` for the toggle round trip (:868-869, 345-347), which is about 3-4 `clk_sys`.

**ARM side of cart RAM** (port B of `cart_ram_tdp`, `clk_arm`):

- port: `dut.arm_ram_en`, `dut.arm_ram_write`, `dut.arm_ram_addr[14:0]` (word address), `dut.arm_ram_wdata`, `dut.arm_ram_wstrb`;
- accept: `dut.cart_ram.arm_allow` = `arm_en && !mapper_edge` (cart_ram_tdp.sv:38-39, 56, 80). [added] In steady state `mapper_edge` is high exactly on the `clk_arm` edges that coincide with a `clk_sys` edge: `arm_phase` reads 4 pre-edge there (cart_ram_tdp.sv:34-54; it locks within two `clk_sys` of time 0);
- who is writing:
  - `dut.cart2600.mapper_wb_en`: the table writeback, which has priority (cart2600.sv:432-439);
  - `dut.cart2600.arm_cartram_{en, write, addr, wdata, wstrb, accepted}`: the CPU and the DMA;
  - `dut.cart2600.arm_mappers.memory.dma_ram_en`: the DMA (arm_mapper_memory.sv:507, 637-644).

**Upstream's cart RAM contents:** byte lane k of word w is `dut.cart_ram.ram_lane[k].lane_ram.mem_q[w]` (cart_ram_tdp.sv:66-84). The 6507 side's byte address is `cartram_addr[16:0]`, so word = `[16:2]` and lane = `[1:0]`. [added] The array is 128 KB, but no DPC+ or CDF path reaches above 32 KB: DPC+ ≤ $1BFF (mapper_dpcplus.sv:143, 157), CDF wraps at 15 bits (section 2), audio is ≤ 17 bits masked by the RAM size (arm_mapper_audio.sv:134-151, 341), the ARM's window is `mapper_ram_size` (arm_mapper_memory.sv:568-569), and init stays below it (arm_mapper_ram_init.sv:141-175).

### 3.7 Audio: AMPLITUDE and the tick [checked]

**Engine**, `dut.cart2600.mapper_audio.` (arm_mapper_audio.sv):

| Field | Source line |
|---|---|
| `tick_accum[23:0]` | :75 |
| `audio_tick` (wire; `tick_accum >= 14,298,182`) | :57, 76 |
| `amplitude[7:0]` (= `dut.cart2600.arm_audio_amplitude`) | |
| `counter0..2`, `frequency0..2` (= `dut.cart2600.arm_audio_counter0` …) | |
| `call_seed_counter[0:2]` | |
| `refresh_pending`, `note_pending`, `note_voice`, `note_value` | |
| `state` (AUDIO_IDLE = 0 …) | :59-74 |
| `voice`, `sample_sum` | |
| `waveform_pointer`, `waveform_offset`, `waveform_shift` | |
| `digital_sample`, `digital_low_nibble`, `digital_address` | |
| `ram_en`, `ram_addr`, `ram_grant`, `rom_request`, `rom_addr` | |

**Tick rule:** +20,000 per `clk_sys`, and on a tick +20,000 − 14,318,182 (:191-199). Ticks come every 715 or 716 `clk_sys` (mean 715.909). The accumulator resets with `effective_reset` (:163-164; cart2600.sv:762). [added] Let R be the last edge with `effective_reset` high pre-edge. The **first tick is at R+716**: 20,000·715 ≥ 14,298,182 > 20,000·714. It leaves 1,818 in the accumulator. Ticks run whatever the family (only `refresh_pending` needs `family != 0`, :196).

[added] **Which paths each family uses:** NOTE (`dpc_note_write` → frequency) only for family 1, DPC+ (:227). Call seeds and the return merge only for family ≥ 2, BUS/CDF (:207, 213). So **DPC+ has no seed and no merge**: its calls' audio payload and returns are ignored by the engine. **CDF has no NOTE path.**

[added] **Same-edge priorities** (later NBA wins, :191-257): at a merge edge the merge overrides the tick's counter add (counter = return when return ≠ seed) and sets the frequency. At a NOTE_CAPTURE edge the NOTE's frequency write follows the merge in source order, but the two never share a family. A tick at a merge or capture edge adds the old (pre-edge) frequency.

**Digital-sample path** (DDR): `dut.cart2600.arm_sample_{request, addr, ready, busy, done, data}` (cart2600.sv:409-413). [added] The memory keeps the last 8-byte DDR word as a one-entry sample cache (`sample_cache_*`, arm_mapper_memory.sv:523-525, 846-848), so upstream's sample latency is short on a hit and `+lat` plus overhead on a miss.

---

## 4. The step 5 shadow (`daria_shadow.svh`): how it mirrors cart RAM and posts calls [checked]

It is included at the end of `tb_daria` under `DARIA_SHADOW` (tb_daria.sv:1006-1008). It uses the bench's names (`img`, `rom_size`, `ctl_state`, `m_*`, `arm_ce_run`, `frame`, `now`, `out`, [added] `running`).

- **DARIA's core** (non-wrapper, daria_shadow.svh:134-224):
  - `bup_cpu #(MODES 1, THUMB 1, CODE_AW 15, WIN_KB)` as `dcpu`, `daria_mem` as `dmem`, `daria_call` as `dcall`, `daria_mmio` as `dmmio`, all on `clk_d`.
  - The window is loaded by backdoor from `img` when the run starts: `dmem.g_win[w].win.mem_q[i]` (:212-217).
  - The image beyond the window answers on the asset port from `img`, with `w_wait` on a random `+d_await` percent of clocks (:167-172).
  - `d_rst` comes from `d_rst_sys` through `clk_d` flops (:218-222). [corrected: three flops, not two: `d_rst_s[0]`, `d_rst_s[1]`, then `d_rst`]
  - `dmem`'s front-end ROM and cart RAM port B are tied off (:185-189). Only state RAM port B (`d_stb_*`) is driven.
- **With `DARIA_WRAPPER`** (:58-132): `bupchip_pocket` as `dw`, fed from the same ioctl stream (`byte_valid = ioctl_wr && cart_download`, :83-84). PSRAM is `psram.sv` plus `psram_model` on `clk_d`. `D_CART_RAM` = `dw.mem.cart_ram` (:117).
- **Upstream side, on `clk_arm`** (:230-284):
  - On the rising edge of `ctl_state == CTRL_RUNNING` (detected with a registered copy, `up_run_q`):
    - `up_call++`;
    - the launch from the controller's `active_*`: `{entry[31:1], thumb}`, stack, three counters, three frequencies (:248-254);
    - **a full blocking snapshot of upstream's cart RAM**, 8,192 words from the four lanes (:255-258);
    - `up_post` toggles.
  - While running, each CPU data access (`m_req && m_rdy && !m_fetch && arm_ce_run`) is queued: RAM writes as `{word address, wstrb, wdata}`, MMIO reads and writes by value (:262-269).
  - After the return, at `CTRL_IDLE`, the six results (`audio_counter_result`, `audio_frequency_result`), the cycle count and the access list are filed under the call number (:270-283).
- **DARIA side, on `clk_sys`** (:286-349): `d_post_s` is a 3-flop sync of `up_post`.
  - **ph0**, on a change:
    - if DARIA is busy (`d_done`) or not ready (`d_not_ready`, i.e. `d_rst_sys` or `!d_ready`), the call is **skipped** and counted;
    - otherwise the snapshot is copied by backdoor into DARIA's cart RAM (`D_CART_RAM.mem_q[i] = up_snap[i]`, :306).
  - **ph1:** the 8 launch words go into state RAM `0xF0..0xF7` through port B, one per `clk_sys` (:311-317).
  - **ph2:** `call_tog` flips (:318-322).
  - **ph3:** wait for `ret_tog` through a 3-flop sync (:323-327).
  - **ph4:** read `0xF8..0xFD` through port B, data one clock after the address (:328-337). Then `d_done`, and `d_e2e` = post to last word.
- **Comparison** (:394-447), once both sides are done (:345-348):
  - the six return words;
  - then, in order, every RAM write (word address, lanes, data on those lanes) and every MMIO access;
  - T1TC (`0xE0008008`) reads within ±200 counts (`MMIO_TOL`, :294, 416-423).
  - Output: `daria.csv` (:433-434, 453-454), and on the first bad calls `$display`. `+shadow_stop=N` stops after N bad calls (:438, 450).
- **Cart RAM collisions** (:367-391):
  - Console-side reads are `dut.cartram_rd && !dut.cartram_wr && cartram_addr[17:15]==0` on `clk_sys`, while `running`.
  - Each is compared against the last upstream ARM write (`clk_arm`) and the last DARIA write (`d_ram_we`, `clk_d`) to the same word. Anything within `COLL_PS` = 69,840 ps counts, in either order. [added] The upstream write tap is the CPU's data writes only (:384); DMA and writeback writes are not counted.
  - Final lines (:456-470): `DARIA shadow: …`, `DARIA collisions: …`, `DARIA T1TC: …` (and the cache line in wrapper builds).

**What it does not do:** it never mirrors cart RAM continuously. DARIA gets a whole-RAM copy at each call start, and DARIA's writes are compared as a list, not by their effect on a RAM the 6507 reads.

That is enough for step 5, because the 6507 only ever reads upstream's RAM. A front-end shadow reads its own RAM during and after calls (audio during a call, stream data after it). It therefore needs every upstream ARM write applied to its RAM at the edge upstream applies it (section 7.4.3).

---

## 5. The model: the POKEY shadow bench [checked]

The POKEY shadow is `sim/run_pokey_shadow.sh` (59 lines), `sim/tb_load.sv` under `POKEY_SHADOW`, and `sim/pokey_shadow_compare.py`.

- **Build** (run_pokey_shadow.sh):
  - It makes renamed and patched copies in `$WORK/shadow`, never touching the repository: `pokey_adapter.sv` → `module pokey_adapter_new` (:19).
  - A Python splice inserts the shadow instance into a copy of `cart.sv`, just before the anchor `pokey_adapter return_of_pokey (`, and asserts that the anchor exists (:24-45).
  - The shadow gets the same clock, the same phase enables (`PHI1_EN(pclk1)`, `PHI2_EN(pclk0)`), the same bus and the same write enable (`~rw & pokey_cs`). Its outputs go to new wires only (`shadow_aud`, `shadow_dout`, …): **never heard, never read by the CPU** (:29-41).
  - It reuses `run_sim.sh`'s `SRCS=( … )` block by `eval`, with `cart.sv` swapped (:53). It needs `POKEY=watson run_sim.sh` to have produced `$WORK/pokey_watson.v` (:51).
  - `-DPOKEY_SHADOW` plus `NO_ARM_MAPPER NO_BUPCHIP NO_DDRAM …`, into `obj_shadow` (:55-58).
  - [added] **It cannot run in this checkout today.** `sim/work/pokey_watson.v` is absent, so it stops at :51. `run_sim.sh` cannot make it, because its output-port-initialiser guard (run_sim.sh:18-21) fires on `BUP/daria_call.sv:43` and `:50`, and the guard comes before anything else (the guard's `grep` was re-run for this check; it matches those two lines). See section 9, question 9.
- **Checks** (tb_load.sv:186-259):
  1. A 64-entry ring of the bus (`p1 p0 rw cs halt_n addr data shadow_strobes`) per `clk_sys`, dumped at the first two wrong arrivals (:187-203).
  2. Every CPU write to POKEY (`pclk0 && pokey_cs && !rw`) must show up within 48 `clk_sys` as a rising write strobe inside the shadow (`u_pokey.addr_wr[i]`), for the same register and with `write_data` equal to the CPU's byte. The adapter's own boot writes (`boot_wr`) are excluded. Outcomes are counted ok / arrived wrong / lost / unasked, with the first 30 printed (:205-246).
  3. A final summary line, `SHADOW writes: …` (:247).
  4. Both outputs (the AUD node of each POKEY) are written at about 48.05 kHz (`rec_div` 0..297, :179) to `pokey_watson.pcm` and `pokey_new.pcm` (:250-258), [added] only while recording (`+wav=MS`).
- **Offline** (pokey_shadow_compare.py:1-29): per window, each stream's RMS around its mean, their ratio and their correlation. Both are written as WAVs.

**What carries over to the front-end shadow:**

- driven only by the live bus, outputs never fed back;
- event checks sorted into named classes with counters;
- a bus ring dumped on the first failures;
- one final summary line in `run.log`;
- per-tick output streams for offline comparison;
- its own build directory and define, with the repository untouched.

**What does not carry over:** the source splice. tb_daria already reaches every needed signal hierarchically (section 3), as `daria_shadow.svh` does, so the front-end shadow is a tb-level include and needs no patched copy of `cart2600.sv`. [added] One exception, and only if needed: the hold of 7.4.2 changes `top.sv`'s `arm_call_stall`. It does so with `force`, not with a splice.

---

## 6. DARIA's `clk_d`: generation, phase, and the change to align it

### 6.1 As it is [checked: every offset recomputed]

`logic clk_d = 0; always #13095 clk_d = ~clk_d;` (daria_shadow.svh:54-55). The period is 26,190 ps. Rising edges fall at 13,095 + 26,190·n ps, and 8 periods = 209,520 ps = 3 `clk_sys` periods exactly. `D_HZ = 687,272,727 / 18` (:56).

Measured from the preceding `clk_sys` rise (34,920 + 69,840·k), the eight `clk_d` rises of each 3-`clk_sys` frame fall at:

| Offset after `clk_sys` rise | ns |
|---|---|
| 1st `clk_sys` | 4.365, 30.555, 56.745 |
| 2nd `clk_sys` | 13.095, 39.285, 65.475 |
| 3rd `clk_sys` | 21.825, 48.015 |

Every one of these is ≡ 4.365 ns (mod 8.730 ns). So **no `clk_d` edge ever coincides with a `clk_sys` edge**, and the nearest pair is 4.365 ns apart on either side. `docs/DARIA_CORE.md` (step 5 results, :446) says the same: "the bench offsets the two clocks by 4.37 ns, so it never puts them on a shared edge".

### 6.2 What the PLL does [checked arithmetic; [added] repository facts]

The VCO runs at 687.27 MHz (period 1.4550 ns). `clk_sys` = VCO/48 (69.84 ns) and `clk_arm` = VCO/18 (26.19 ns), with zero phase shift on both counters. Every rising edge of either clock therefore lies on a multiple of 6 VCO periods (8.73 ns) from the common origin, and the two coincide every lcm(48, 18) = 144 VCO periods = 3 `clk_sys` = 8 `clk_arm`.

Relative to the preceding `clk_sys` rise, the `clk_arm` rises fall at {0, 26.19, 52.38}, {8.73, 34.92, 61.11} and {17.46, 43.65} ns. The bench's offset of 4.365 ns is 3 VCO periods, half the 6-VCO lattice.

[added] **What the repository shows today.** `core/pll/pll_core.v` has no ÷18 output yet. Its `counter[3]` is ARIA's `clk_arm` = 2 × `clk_sys` (core_constraints.sdc:4-9). The zero-phase outputs (c0, c1, c3) all have `c_cnt_prst = 1` and `c_cnt_ph_mux_prst = 0`, so they start counting together (pll_core.v:125-150). The SDC times all core counters as one synchronous group (core_constraints.sdc:12-22), so a shared-edge transfer is checked for hold at 0 ns. A ÷18 counter added the same way (0 ps, the same presets) would share edges with `clk_sys` by construction. That is an inference from the parameters, not a device measurement. The PLL is reconfigurable (NTSC/PAL, core_constraints.sdc:5, 10-11). A reconfiguration relocks the PLL and may restart the counters (an inference; the repository does not say), so the guard of 6.4 must re-detect the shared edge after each one, and it costs nothing to do so continuously.

### 6.3 The change [checked: the coincidence arithmetic was recomputed]

- **Minimal (one character):** `logic clk_d = 1;` in daria_shadow.svh:54, with `always #13095 clk_d = ~clk_d;` unchanged.
  - `clk_d` then falls at 13,095 and rises at **26,190·n ps** (n ≥ 1; an initialiser is not an edge).
  - It coincides with a `clk_sys` rise when 26,190·n = 34,920 + 69,840·k, i.e. 3n = 4 + 8k, i.e. **n ≡ 4 (mod 8), at `clk_sys` edges k ≡ 1 (mod 3)**: 104,760, 314,280, … ps. That is once every 3 `clk_sys`, as the PLL does.
  - The other seven `clk_d` edges of each frame lie 8.73·m ns from a `clk_sys` edge, m = 1..7.
- **Parameterised (recommended),** so that each of the three possible coincidence classes, and the old phase, can be run:

  ```systemverilog
  logic clk_d = 1'b1;
  int   d_ofs = 0;      // +d_ofs=PS: 0, 8730 or 17460 are PLL-aligned
                        // (coincidence at clk_sys k ≡ 1, 0, 2 mod 3);
                        // 13095 reproduces the step 5 phase
  initial begin
      void'($value$plusargs("d_ofs=%d", d_ofs));
      #(d_ofs);
      forever #13095 clk_d = ~clk_d;
  end
  ```

  Rising edges then fall at `d_ofs` + 26,190·n. With `d_ofs` = 8,730·j: 3n + j = 4 + 8k, so j = 0, 1, 2 put the shared edge on `clk_sys` classes k ≡ 1, 0, 2 (mod 3). The value 13,095 ≡ 4,365 (mod 8,730) is the current phase. [checked: j = 1 gives the first shared edge at 34,920 ps (k = 0); j = 2 at 174,600 ps (k = 2)]

  [added] **What the three classes cover.** A 6507 cycle is 12 = 4 × 3 `clk_sys`, so between re-phasings the shared edge falls on the same E0-relative slots in every cycle: E0+c, E0+c+3, E0+c+6, E0+c+9. The sweep therefore puts it on each slot class once. A console reset (TIA.sv:569-570) or an RSYNC (TIA.sv:565-567) can change c during a run, because the divider restarts while the clocks run on.
- **Who sees the change:**
  - DARIA's core, `daria_mem` port A, `daria_call`, `daria_mmio` (`clk_arm` side), the d_rst synchroniser, and in `WRAPPER` builds `bupchip_pocket`, `psram.sv` and `psram_model`.
  - Upstream's `clk_arm` (5×) and `clk_sys` are untouched.
  - The MMIO bench already passed both aligned and asynchronous clock variants ("Step 5 work", MMIO; docs/DARIA_CORE.md:387).
  - [added] With aligned clocks every DARIA `clk_sys`↔`clk_d` synchroniser (`daria_call`'s `tog_s`, the shadow's `d_post_s`/`d_ret_s`, `daria_mmio`) sees coincident edges. In simulation such a flop takes the old value (NBA). Call latencies and T1TC readings can shift by a clock against the step 5 numbers. `MMIO_TOL` absorbs that.

### 6.4 What alignment makes measurable (open item 7, the shared-edge guard)

In simulation, a write on one port of `daria_ram` and a read of the same word on the other port at the same timestep reads **old data, deterministically**. The read is a blocking read of `mem_q` and the write an NBA (BUP/daria_mem.sv:90-107). On an M10K with two clocks that read is undefined. The bench must therefore **count** such events; it cannot rely on their values. [checked]

Add to daria_shadow.svh:

- **Exact-coincidence counters,** beside the 69.84 ns window (:376-391). In the `clk_sys` read block, `if (d_wt[w] == $time) coll_d_same++`. In the `clk_d` write block, `if (fe_rt[w] == $time) coll_d_same++`. Exactly one of the two fires for each coincident pair, whichever block runs second. [checked] [added] In mode B the reads that matter are `daria_fe`'s own port-B reads (`crb_addr` with `crb_use`, 7.3), not upstream's `cartram_rd`. Feed `fe_rt` from them in FE builds. Also count the reverse race: a `daria_fe` port-B *write* (in-place pointers, DPC+ WRITE/PUSH, copy engine) on a shared edge with a DARIA CPU *load* of the same word (`coll_d_ld_same`).
- **Stores on a shared edge, whatever they hit:** in the `clk_d` block, `if (d_ram_we && (($time - 34920) % 69840) == 0) d_shared_stores++`. This is exact integer arithmetic at 1 ps resolution, and it is independent of the order of the clk blocks within a timestep. [checked]
- **Guard acceptance** (a store W-wait on the shared edge, `docs/DARIA_CORE.md` open item 7):
  1. `d_shared_stores` = 0 for every `d_ofs` in {0, 8730, 17460};
  2. `coll_d_same` = 0;
  3. every call still matches upstream (`DARIA shadow: … 0 differ`);
  4. no call is late beyond the model's (`dynamic_tables.py --only daria`), and T1TC stays within `MMIO_TOL`.

  Without a guard, about 1 store in 8 should land on a shared edge [E].

  The guard's phase detector must not assume which `clk_sys` class coincides: in hardware it depends on lock. That is why three `d_ofs` values are needed.
- **Recommendation:** gate the guard with the 2600 profile (`prof26`), so the BupChip profile's timing (CoreTone, `s4/check.sh`) is unchanged.
- [added] **Decision for this run (user):** build the guard, because it costs little and does not put the core out of step: it delays only stores, by one `clk_d`, on one edge in 8, and the acceptance above proves the calls still match.
- [added] **The phase detector, specified from the clocks alone** (the 8:3 analogue of cart_ram_tdp.sv:34-54). On `clk_sys`, flip `sys_tog` every edge. On `clk_d`, sample it through two flops and note the `clk_d` edges at which the first flop's value is new. With 8 `clk_d` per 3 `clk_sys` and a coincident edge at `clk_d` 0, the `clk_sys` edges fall at `clk_d` 0, 2⅔ and 5⅓. A coincident flip is sampled old at its own edge, so the new value is first seen at `clk_d` 1, 3, 6, 9, 11, 14, …, at intervals 2, 3, 3, 2, 3, 3. The change seen two edges after the previous one marks shared edge = (that change's edge) − 3, and shared edges then recur every 8 `clk_d`. That needs a 3-bit counter and a 2-bit interval timer (≈ 10 FF). It depends on neither E0 nor RSYNC. **Bench check:** for every `d_ofs`, the detector's predicted shared edges must equal `($time - 34920) % 69840 == 0` on every `clk_d` edge after lock (`det_bad` = 0), and it must lock within 16 `clk_d` of reset release.

---

## 7. Plan: the front-end shadow

### 7.1 Two modes [checked]

| | Mode A: **front end alone** (the exactness gate) | Mode B: **front end + DARIA** (system rehearsal, later) |
|---|---|---|
| ARM that runs the calls | upstream's | DARIA's (`SHADOW=1`), with the 6507 held until both have returned |
| `daria_fe`'s cart RAM | its own `daria_mem` (`fe_mem`); port A is a **mirror of upstream's ARM writes** on upstream's `clk_arm` | DARIA's `dmem`, shared with DARIA's CPU (port A on `clk_d`) |
| Call return to `daria_fe` | the bench emulates `daria_call`, from upstream's controller, edge-for-edge | the real `daria_call` |
| What it proves | the 6507-side behaviour, audio and RAM image, cycle for cycle | the call block, the toggles, the audio merge from DARIA's FIQ words, and the shared-edge guard against real reads |
| Expected differences | AMPLITUDE lag, `open_bus`, NOTE/merge/seed races (7.6) | as A, plus audio counters after a call **only when a tick falls between the two merge edges** (7.6, [corrected: not "after every call that changes them"]) |

**Mode A first.** Step 6's done-when ("matches upstream's front ends as a cycle-by-cycle shadow in tb_daria on every demo and added image") is mode A. Mode B disables step 5's per-call RAM snapshot copy (daria_shadow.svh:306): `daria_fe`'s own RAM is DARIA's input then. [added] Mode B also disables step 5's poster (ph0-ph4, :296-339), because `daria_fe` posts the calls, and it holds the 6507 with the same `force` as 7.4.2, adding `u_fe.arm_call_busy`.

### 7.2 Files

| File | New / changed | Content |
|---|---|---|
| `BUP/daria_fe.sv` | new (the front end) | Must expose the ports and taps of 7.3. No output-port initialisers (section 9, question 9). |
| `D/fe_shadow.svh` | new | Mode A, sections 7.4-7.7. Included from tb_daria under `` `ifdef FE_SHADOW ``. |
| `D/fe_taps.svh` | new | One place that maps `daria_fe`'s internal state (state RAM layout, register names) to the bench's comparison functions (7.3, "Taps"). When `daria_fe` changes its layout, only this file changes. [added] It also provides the deposit task the resync needs (7.6). |
| `D/tb_daria.sv` | changed | (1) `` `ifdef FE_SHADOW `include "fe_shadow.svh" `endif `` at the end, beside :1006-1008. (2) A forward-declared `logic fe_hold_reset = 0;` near :88-96 under `FE_SHADOW`, added to the `reset` term at :100: `reset <= reset_in \| cart_download \| old_cart_download \| mapper_init_busy \| fe_hold_reset;`. It is declared before use because the include comes last. (3) Optional `+hard_reset_at=F`: pulse `reset_in` at frame F (a separate `always`; `-Wno-MULTIDRIVEN` is already set). This exercises the re-init on a reset edge on both sides (arm_mapper_ram_init.sv:222-226). [corrected: the pulse must be timed in `clk_sys` (`+hard_reset_len=N`, default 1,000), not "for 6 frames". The TIA is in reset with the console (top.sv:517), VSYNC stops, and `frame` (tb_daria.sv:757) would never advance: the pulse would never end.] |
| `D/daria_shadow.svh` | changed | `clk_d` alignment and `+d_ofs` (6.3), exact-coincidence counters and the detector check (6.4). Mode B: a `FE_SHADOW` switch that skips the snapshot copy and the poster, and connects `daria_fe`'s call port to `dcall`. Keep the `DARIA shadow:` line's first three fields (1.1). |
| `D/run_daria.sh` | changed | `FE=1`: `SRCS+=("$BUP/daria_fe.sv")`, plus `daria_mem.sv` unless `SHADOW=1` already adds it; `DEFS+=(-DFE_SHADOW -I$HERE)`; `OBJ=${OBJ}_fe` (`obj_fe`, or `obj_shadow128_fe`); `PREFIX` `fe/` (or `shadow128_fe/`); `fe_shadow.svh` and `fe_taps.svh` in the `find -newer` list (:85-86). [corrected: `BUP` is set only inside the `SHADOW` branch (:71), so `FE=1` must set it too] |
| `D/run_all.sh` | changed | The same `FE` handling of `PREFIX` (run_all.sh:15-17 duplicates run_daria.sh:97-99, so keep them in step). |
| `D/dynamic_tables.py` | changed | `sec_fe` (7.7), added to `SECTIONS`. [corrected: `--only fe` needs no registration; it dispatches through `globals()["sec_" + name]` (:777-783). `SECTIONS` (:752-753) is only the default list.] |
| `D/fe_amp_compare.py` | new, optional | Like `pokey_shadow_compare.py`, for the per-tick AMPLITUDE streams. |

### 7.3 What the bench needs from `daria_fe`

The port names are proposals following `docs/DARIA_CORE.md` "The front end"; `fe_taps.svh` adapts to whatever is built.

**Inputs, all on `clk_sys`:**

| Group | Signals |
|---|---|
| 6507 bus | `a_in[12:0]`, `d_in[7:0]`, `rw`, `phi1` (= `pclk1`), `access` (= `mapper_phi2 && arm_driver_run`). [added] `access_taken` in upstream uses `mapper_phi2`, not `access` (cart2600.sv:259). They are equal whenever `arm_driver_run` is 1, which holds from one clock after reset release (1.3, item 7). Pass `mapper_phi2` too if `daria_fe` must match during reset. |
| reset and load | `cart_reset` (the console reset level: `effective_reset`), `load_end` (one-clock pulse), [added] `load_start` (one-clock pulse; upstream's init is busy from it, arm_mapper_ram_init.sv:207-208) |
| scheme | `scheme[5:0]` (`force_bs`), `revision[2:0]`, `cdf_ldx`, `cdf_ldy`, `fetch_offset_en`, `fetch_offset[7:0]`, `cdfj_entry`, `cdfj_stack`, `audio_size_addr[15:0]`, `rom_size[31:0]`, `ram32` |
| call port | `call_ready`, `ret_tog` |
| digital-sample port | answer toggle and byte |
| memories | `fea_q`, `feb_q` (front-end ROM ports A and B), `crb_q` (cart RAM port B), `stb_q` (state RAM port B) |

**Outputs:**

| Group | Signals |
|---|---|
| to the 6507 | `fe_do[7:0]`, `fe_oe[7:0]` |
| stall and init | `arm_call_busy`, `arm_dma_busy`, `init_busy` |
| call port | `call_tog` |
| digital-sample port | request toggle and address |
| memory ports | `fea_addr`, `feb_addr`; `crb_addr/we/be/wd`; `stb_addr/we/wd` |

**Taps** (hierarchical, read-only, named in `fe_taps.svh`):

| Group | Taps |
|---|---|
| bank, mode, fast fetch, jump | `bank`; CDF `mode`; DPC+ `fast_fetch`/`fast_pending`; CDF `fast_pending`, `fast_expected_address`, `jump_remaining`, `expected_address`, `jump_stream` |
| DPC+ registers | `random`; `parameter_pointer`; `waveform[0:2]`; `call_pending`; `service_pending` |
| copy engine | its parameters (fill, source, dest, count, value) and busy |
| audio | `tick` strobe, `amplitude`, the tick's applied event; [added] the NOTE-capture, merge and seed-latch edges (strobes), so 7.6 can measure each offset against upstream's |
| cart RAM use | `crb_use`: this clock's cart RAM port-B read result will be consumed. Needed for real collision counting, because an M10K port reads every clock. |
| state RAM addresses | the DPC+ fetchers. The study's layout is two words per fetcher, `w0 = {bottom, top, 0:counter[11:8], counter[7:0]}` and `w1 = {increment, 0:fraction[19:16], fraction[15:0]}`, compared under masks `0xFFFF0FFF` and `0xFF0FFFFF`, because the spare nibbles may carry garbage (study §3.1, §3.3). Also params 0-3 (one word, lanes 0-3; params 4-7 are never read upstream, mapper_dpcplus.sv:85-89, 284-290), and counters, frequencies and seeds for voices 0-2. The call block is 0xF0-0xFD (BUP/daria_call.sv:8-16). [checked] |

[added] **The state the RTL makes observable** (the floor for C1/T2; everything else may be laid out freely). DPC+: per fetcher `top`, `bottom` (8 each), `counter` (12), `fractional` (20), `increment` (8); `params[0..3]`; `min(parameter_pointer, 4)`; `random_number` (32); `bank` (3); `fast_fetch`, `fast_pending`; `waveform[0..2]` (7 each); the pending call and service with the service's five latched fields; three counters and three frequencies (32 each). CDF: `bank`, `mode`, `fast_pending` (+ `fast_expected_address` while pending), `jump_remaining` (+ `expected_address`, `jump_stream` while non-zero), the pending call, the 35 or 34 pointers and increments (in place in cart RAM), three counters, frequencies and seeds. The seeds are needed only from accept to merge.

### 7.4 Wiring inside `fe_shadow.svh` (mode A)

#### 7.4.1 Instances [checked]

- **`fe_mem`:** `daria_mem #(.WIN_KB(32))` (BUP/daria_mem.sv:113-203), `clk_arm` = the bench's upstream `clk_arm`, `clk_sys`.
  - The window is unused: `rom_addr` = 0, `img_ready` = 1, `win_we` = 0.
  - Front-end ROM port A: `cap_we = ioctl_wr && cart_download && ioctl_addr[24:15] == 0`, `cap_addr = ioctl_addr[14:0]`, `cap_data = ioctl_dout`. This is the wrapper's own capture rule (BUP/bupchip_pocket.sv:354), on the same stream the core sees (tb_daria.sv:932-940). [added] The wrapper also requires `cap_cart_win`; tb_daria's stream is only the cartridge, so the term is always true here.
  - Ports B (and front-end ROM port A outside the load) go to `daria_fe`.
- **`u_fe`:** `daria_fe` on `clk_sys`. [added] All inputs are **continuous assigns** from the DUT, so `u_fe` samples them pre-edge exactly as the DUT's own flops do. Do not register them in the bench.

  | Input | Driven from |
  |---|---|
  | `a_in` | `dut.cart2600.a_in` |
  | `d_in` | `dut.cart2600.d_in` |
  | `rw` | `dut.RW` |
  | `phi1` | `dut.pclk1` |
  | `access` | `dut.cart2600.arm_access` |
  | `cart_reset` | `dut.effective_reset` |
  | `load_start` [added] | `~old_cart_download && cart_download` |
  | `load_end` | `old_cart_download && !cart_download` |
  | scheme inputs | the tb's `detect` wires (3.3) |
  | `rom_size` | `cart_size` |
  | `ram32` | `dut.mapper_ram_size == 16'd32768` (as daria_shadow.svh:68, 137) |
  | `call_ready` | `dut.cart2600.arm_call_ready` |

**Check after the load:** `fe_mem.fe_rom.mem_q[w]` must equal `{img[4w+3], …, img[4w]}` for every w below min(n, 32 KB) / 4. [checked]

#### 7.4.2 Reset and the hold (`+fe_hold`, default 1)

**At load.** `fe_hold_reset <= u_fe.init_busy`. The console stays in reset until both upstream's `arm_mapper_ram_init` and `daria_fe`'s copy engine have built the RAM image. `daria_fe`'s F6 is byte-wide at about 1 byte per 2 `clk_sys` (study §3.6), slower than upstream's DMA for the CDF clears. Without the hold the console would start while `daria_fe`'s image is incomplete.

[corrected: the plain `fe_hold_reset <= u_fe.init_busy` is not safe] If `u_fe.init_busy` rises later than upstream's `mapper_init_busy` falls, or dips for a clock between F6's phases, the bench `reset` drops for a clock and then rises again. That rising `effective_reset` edge makes upstream re-run its whole init (arm_mapper_ram_init.sv:223), and the console may run a cycle. **Guard (sticky, a few flops):**

```systemverilog
// fe_shadow.svh, on clk_sys
logic fe_seen_busy = 0, fe_rst_q = 0;
always @(posedge clk_sys) begin
    fe_rst_q <= dut.effective_reset;
    if ((~old_cart_download && cart_download) ||            // load_start
        (fe_loaded && dut.effective_reset && !fe_rst_q)) begin // console reset edge
        fe_hold_reset <= fe_hold;                          // +fe_hold
        fe_seen_busy  <= 0;
    end else if (fe_hold_reset) begin
        if (u_fe.init_busy) fe_seen_busy <= 1;
        else if (fe_seen_busy || fe_hold_timeout) fe_hold_reset <= 0;
    end
end
```

`fe_hold_timeout` is a counter (2^20 `clk_sys`) that reports `fe_init_never_busy` and releases. While `fe_hold_reset` is high, `effective_reset` stays high throughout, so upstream sees no new reset edge and does not re-init (arm_mapper_ram_init.sv:222-226). [checked]

[added] **F6 must not wait for the reset to fall.** The bench (like upstream's own `mapper_init_busy` term) holds the console reset until init is done. An F6 that starts on a falling `cart_reset` would deadlock. Start it as upstream starts its init: on `load_end` (upstream: `load_end_d`, one clock later, arm_mapper_ram_init.sv:212-218) and on a rising `cart_reset` while an image is loaded (:222-226).

**DPC+ copy/fill.** Upstream's fill writes about 4 bytes per 5 `clk_arm` (one per accepted edge), and its copy re-reads DDR every 8 bytes (arm_mapper_memory.sv:858-893). It is therefore faster than the study's lean engine (about 100 6507 cycles for 255 bytes, study §3.6). [checked]

To keep the 6507 held until both are done:

```systemverilog
force dut.arm_call_stall = dut.tia_en &&
    (dut.arm_call_busy ||
     (!dut.mapper_init_busy && (dut.arm_dma_busy || u_fe.arm_dma_busy)));
```

- This mirrors top.sv:306-307.
- It forces only `top.sv`'s internal `arm_call_stall`. It does not force `arm_dma_busy`, which aliases a register inside `arm_mapper_memory`. [corrected: `arm_call_stall` has **four** readers, not two: `RDY` (top.sv:328-329), `mapper_phi2` (:327), the `stall_cycle_taken` flop (:321-326), and the bench's own `call_stall` tap (tb_daria.sv:240), which feeds `stall_sys` in `calls.csv` and `frames.csv` (:727, 742). The self-check must cover the first three. With the hold, the fourth includes `daria_fe`'s extra hold time.]
- [added] **A constant-RHS form, preferred** (question 3). It does not depend on how Verilator re-evaluates a non-constant force expression. All inputs are `clk_sys` registers, so their value at the falling edge is the value through the next rising edge:

  ```systemverilog
  always @(negedge clk_sys)
      if (fe_hold && dut.tia_en && !dut.mapper_init_busy && u_fe.arm_dma_busy)
          force dut.arm_call_stall = 1'b1;
      else
          release dut.arm_call_stall;      // top.sv's own assign applies
  ```

- Self-check, on every `posedge clk_sys` while `running`, with `exp = dut.tia_en && (dut.arm_call_busy || (!dut.mapper_init_busy && (dut.arm_dma_busy || u_fe.arm_dma_busy)))` computed in the bench: `dut.arm_call_stall == exp`; `dut.RDY == 0` whenever `exp`; `dut.mapper_phi2 == (dut.pclk0 && (!exp || !dut.stall_cycle_taken))`. Count `hold_bad`, which must be 0. [corrected: was only `!dut.RDY`, and missed `mapper_init_busy`]
- With the hold, upstream's 6507 timing differs from a plain run (calls.csv times shift). Both front ends still see one and the same bus. [checked]
- [added] **No image in the set exercises it** (1.5: `dma_events` = 0 in all 21). The hold and R2/R3 need a directed DPC+ copy/fill test (7.9).

**Calls.** Not held. In mode A `daria_fe`'s `arm_call_busy` follows the emulated `ret_tog`, which follows upstream's own completion (7.4.4). [checked]

#### 7.4.3 The cart RAM mirror (upstream's ARM CPU writes only)

On every `posedge clk_arm`, drive `fe_mem`'s cart RAM port A, [added] with **continuous assigns** (so `fe_mem` samples them at the same edge as `cart_ram_tdp`):

```systemverilog
assign fe_d_addr    = {15'd0, dut.arm_ram_addr, 2'b00};   // 32 bits
assign fe_ram_we    = dut.cart_ram.arm_allow && dut.arm_ram_write
                      && !dut.cart2600.mapper_wb_en
                      && !dut.cart2600.arm_mappers.memory.dma_ram_en;
assign fe_ram_be    = dut.arm_ram_wstrb;
assign fe_ram_wdata = dut.arm_ram_wdata;
```

[corrected: `d_addr` was written `{17'd0, arm_ram_addr, 2'b00}`, which is 34 bits for a 32-bit port. `daria_mem` uses `d_addr[14:2]` (daria_mem.sv:190).]

- **Same edge as upstream.** This is the edge upstream writes `cart_ram_tdp` port B (cart_ram_tdp.sv:80). `arm_allow` keeps it off every `clk_sys` edge (cart_ram_tdp.sv:29-54), so `daria_fe`'s port-B reads see the write from the same `clk_sys` edge as upstream's mapper port, with no same-edge race. [checked]
- **Writeback writes are excluded.** `daria_fe` writes its pointers in place itself. A late upstream writeback (E0+7.8, glue.md §9) would otherwise overwrite a newer `daria_fe` value. [checked]
- **DMA writes are excluded** (init and DPC+ service). `daria_fe`'s copy engine must produce them itself; they are compared in 7.5. [checked]
- **6507-side writes are not mirrored.** Each front end makes its own. [checked]
- The ARM's RAM window is below `mapper_ram_size` (arm_mapper_memory.sv:568-569), so `arm_ram_addr` < 8,192 words always fits `fe_mem`'s 8K-word cart RAM. [checked]
- [added] The ARM's writes to the CDF table words reach `fe_mem` through this mirror. In upstream they also update the table copies (3.5), so after a call both sides hold the same pointers.

#### 7.4.4 Call-port emulation (in place of `daria_call`)

- **Return words.** On every `posedge clk_arm` where `ctl_state == CTRL_CAPTURE_AUDIO` (8), write `fe_mem` state RAM port A: `sta_addr = 0xF8 + audio_read_index`, `sta_we = 1`, `sta_wd = state_rdata`. The values are pre-edge, so this is the same edge at which the controller captures them (arm_mapper_controller.sv:338-345). Indices 0..2 are counters and 3..5 frequencies, matching `daria_call`'s layout (0xF8-0xFA r8-r10, 0xFB-0xFD r11-r13; daria_call.sv:8-16). [checked; [added] drive `sta_*` with continuous assigns, for the same reason as 7.4.3]
- **`ret_tog`.** Assign it from `dut.cart2600.arm_mappers.call_controller.complete_toggle ^ ret_bias`, where `ret_bias` is the value at reset. It therefore flips at the same `clk_arm` edge as upstream's (:346-349), and `daria_fe`'s synchroniser samples it at the same `clk_sys` edges as `complete_sync1/2` (:134-135). Every return word is written on or before that edge. [checked; [added] `complete_toggle` does not move under a mapper reset (it is loaded with `complete_ack_sync2`, which already equals it, :271-276, 144-147). If `daria_fe` follows `daria_call`'s reset rule and loads its "seen" flag from the synchronised `ret_tog` while reset (daria_call.sv:29-32, 99-100), `ret_bias` = 0 works. Count `ret_unasked`: a flip with no `call_tog` flip outstanding.]
- **`call_tog`.** When `daria_fe` flips it, read words 0xF0-0xF7 of `fe_mem`'s state RAM by backdoor. Queue them, and compare in order with upstream's payload, which is latched at upstream's accept edge (arm_mapper_controller.sv:149-161):

  | Word | Must equal |
  |---|---|
  | 0xF0 | `{call_entry_payload[31:1], call_thumb_payload}` |
  | 0xF1 | `call_stack_payload` |
  | 0xF2-0xF4 | `audio_counter_payload[0..2]` (the seeds) |
  | 0xF5-0xF7 | `audio_frequency_payload[0..2]` |

  Report the offset in `clk_sys` between `daria_fe`'s post and upstream's accept. Upstream can accept late when the writeback is busy (`mapper_call_ready`, cart2600.sv:661); glue.md §9 shows this does not happen at 6507 rates. [checked; [added] the RTL settles it: a CALLFN commit at E0+6 needs the writeback idle pre-edge at E0+7, and the last possible pointer capture is the previous cycle's, at E0−5 or earlier. That capture is idle again 3 `clk_sys` later, at E0−2 (arm_mapper_writeback.sv:56-65, 91-131). `arm_call_ready` is low only while a call is busy or in reset (arm_mapper_controller.sv:86-87). So upstream always accepts at E0+7. Upstream's DPC+ payload carries counters and frequencies too, though the engine ignores the returns (3.7).]
- **Mode B.** Both are replaced by `dcall` and `dmem`. [checked]

#### 7.4.5 Digital-sample port emulation [checked]

When `daria_fe` raises a sample request for byte address `a < rom_size`, answer with `img[a]` after `+fe_slat` `clk_sys` (default 40 [E]) and flip the answer toggle.

Compare `a` with upstream's `mapper_audio.digital_address[24:0]` for the same tick, taken in `AUDIO_DIGITAL_ROUTE`. RAM-window samples and the 0 for out-of-range addresses (arm_mapper_audio.sv:335-348) are `daria_fe`'s own and are checked by the per-tick compare. [added] Upstream's own latency is the DDR model's `+lat` on a miss of its one-word sample cache and a few clocks on a hit (3.7). So `amp_lag` in digital mode measures the difference between the two latencies, not a defect.

### 7.5 What to compare, and when

"Pre" means sampled at that edge before its updates. Every row is counted, and the first failures are dumped with the ring (7.7). [added] All rows start at the first E0 with `!dut.effective_reset && dut.tia_en` (1.3, item 7), except I1/I2 and the ROM check. "E0+12" means **the next `pclk1` edge**, whatever its spacing (S1).

| # | When (`clk_sys`, relative to E0) | Condition | Upstream | `daria_fe` | Rule / class on failure |
|---|---|---|---|---|---|
| L1 | **E0+6** (pre), every `pclk0`, including hidden ones during a stall | `dut.RW && dut.tia_en` and the scheme is 21 or 23 | `oe = dut.cart2600.oe`, `d = dut.cart2600.d_out` | `fe_oe`, `fe_do` | `oe` equal, and `d & oe` equal. Else `dout_bad`, unless class A (AMPLITUDE: upstream reading `dpcplus.register_read && read_function==0 && read_index==5`, or `cdf.amplitude_fetch`, and the two values differ only by one tick's update, 7.6). [corrected: a mismatch at a **hidden** `pclk0` (`dut.pclk0 && !dut.mapper_phi2`) is `dout_hidden`, information only. The CPU overwrites `dl` there and consumes only the completing cycle's latch (section 2, "Stalls").] |
| L2 | **E0+6** | `!dut.RW` | `oe` | `fe_oe` | Information only. The DUT ignores the slot's `oe` on writes (top.sv:380-395). [checked] |
| L3 | **E0+6** | always | `dut.read_DB` | | Sanity: the next edge's `dp.dl` equals it. This checks the tap, not `daria_fe`. [checked] |
| C1 | **E0+12** (pre), after every cycle, whether or not it committed | scheme 21 | `dpcplus.{bank, fast_fetch, fast_pending, random_number, parameter_pointer, params[0:3], waveform[0:2], call_pending, service_pending}`; for i = 0..7, `top[i]`, `bottom[i]`, `counter[i]`, `fractional[i]`, `increment[i]` | taps / state RAM words (masked) | Equal, else `state_bad`, with the field named. `daria_fe`'s write-backs at s6/s7 (E0+6..E0+8) are done by E0+12. [corrected: compare `min(parameter_pointer, 4)` (3.5). Compare `call_pending`/`service_pending` only if `daria_fe` keeps flags with upstream's clear-at-accept rule (mapper_dpcplus.sv:222-225). Otherwise compare the accept counts (R1, R2), because a pending flag held across a post is an implementation detail.] |
| C2 | **E0+12** | scheme 23 | `cdf.{bank, mode, fast_pending, fast_expected_address, jump_remaining, expected_address, jump_stream, call_pending}` | taps | Equal, else `state_bad`. [corrected: `fast_expected_address` only while `fast_pending`; `expected_address`, `jump_stream` only while `jump_remaining != 0` (3.5)] |
| C3 | **E0+12**, after a cycle with `cdf.pointer_update` in (E0+6, E0+7) | scheme 23 | `stream_tables.pointer_ram.mem_q[pointer_update_index]` | `fe_mem.cart_ram.mem_q[pointer_base + index]` | Equal, else `ptr_bad`. [checked; [added] also check upstream's own `dut.cart_ram` word against its table, after the writeback (`wb_lag_bad`, a tap check)] |
| C4 | **E0+12**, after a 6507-side cart RAM write in the cycle (DPC+ WRITE/PUSH: `cartram_wr` at E0+6; CDF DSWRITE) | | the byte at `cartram_addr` (word [16:2], lane [1:0]) in `dut.cart_ram` | the same byte in `fe_mem.cart_ram` | Equal, else `ram_bad`. [corrected: `cartram_addr[17:15]` is always 0 for DPC+ and CDF (3.6), so there is no `over32k` case. Keep it as an assertion (`over32k` must be 0).] |
| R1 | Each upstream accept (`call_req` at E0+7) and each `daria_fe` `call_tog` flip | in order | payload | call block 0xF0-0xF7 | Equal, else `call_bad`. Seeds that differ only by one tick's add → class `seed_race` (7.6). The post offset goes to a histogram. [added] If `daria_fe` latches its seeds and frequencies at E0+7 (section 10), `seed_race` must be 0. |
| R2 | Each `service_pending` rise (E0+6) and `daria_fe`'s copy-engine start | scheme 21, in order | `service_{fill, source, dest, count, value}` | copy-engine taps | Equal, else `svc_bad`. [added] `service_pending` is set at the E0+6 edge, so it reads high pre-edge at E0+7, where `dma_busy` is also set (arm_mapper_memory.sv:335-343). |
| R3 | When both copies are done: upstream `arm_dma_busy` has fallen and `u_fe.arm_dma_busy` has fallen | | bytes [dest, dest+count) of `dut.cart_ram` | `fe_mem.cart_ram` | Equal, else `svc_ram_bad`. A count of 0 is legal (the clamps, mapper_dpcplus.sv:91-101). [added] Upstream still raises `dma_busy` for about 3-4 `clk_sys` on a count of 0 (3.6). |
| I1 | The first `clk_sys` edge where both `dut.mapper_init_busy` and `u_fe.init_busy` are low after a `load_end` or a reset edge | | `dut.cart_ram` bytes [0, `mapper_ram_size`) | `fe_mem.cart_ram` | Equal, else `init_bad` (first 16 words listed). Expected images: DPC+ 0 in [0, $C00), image $6C00-$7FFF in [$C00, $2000); CDF image $0000-$07FF in [0, $800) and 0 above (arm_mapper_ram_init.sv:133-176). [checked] |
| I2 | Same edge | scheme 23 | `pointer_ram`/`increment_ram` [0, `stream_count`) | the in-place words | Equal (upstream preloads them from RAM, arm_mapper_ram_init.sv:178-202, 255-276) [checked] |
| K1 | At each upstream call start: the `clk_arm` edge where `control_state` becomes RUNNING (as daria_shadow.svh:240-244) | | all `mapper_ram_size`/4 words of `dut.cart_ram` | `fe_mem.cart_ram` | Equal, else `ram_call_bad`. The writeback is idle at a call start (`mapper_call_ready`), so upstream's RAM is consistent. The 6507 is held, so `daria_fe` is quiet. This is the strongest RAM check. [checked; [added] "quiet" holds for writes: between accept and RUNNING the only 6507 commit is F's phase 2 at E0+18, an opcode fetch after an absolute store, which neither substitutes nor writes RAM (glue.md §7.5). `daria_fe`'s audio may read meanwhile.] |
| K2 | Each frame (VSYNC rise, tb_daria.sv:757), at the first edge where `dut.cart2600.mapper_wb_idle` | | full RAM, plus the CDF increment tables | `fe_mem` | Equal, else `ram_frame_bad` [checked] |
| T1 | Each upstream tick: the edge with `mapper_audio.audio_tick` (pre) = 1 | | edge time | `daria_fe`'s tick strobe | **Same edge**, else `tick_bad`, which is fatal: the Bresenham constants or the reset differ. [added] The first tick is at R+716 (3.7). |
| T2 | Each tick edge n+1 (pre): the state left by tick n | family 1 or 3 | `counter0..2`, `frequency0..2`, `amplitude` | state RAM words, `amplitude` tap | Equal. Else classify by the events since tick n (7.6): `note_race` (family 1 only), `merge_race`, `seed_race` (family 3 only), else `audio_bad`. Then resync if `+fe_resync`. |
| T3 | Each tick | | latency from the tick to `amplitude` changing (or not) | the same | Histogram only (risk 1 of the study) |
| T4 | Each tick in digital mode | | `digital_address` | the sample request | Equal, else `dig_bad` |
| O1 | **E0+11** (pre E0+12) of each cartridge read cycle | | `dut.cart2600.d_out` vs its value at E0+6 | `fe_do` vs its value at E0+6 | Count `drift_up` / `drift_fe`. If the **next** cycle's latch reads TIA or RIOT with a partial `oe` (`dut.cs_tia && tia_DB_oe != 8'hFF`, or the same for RIOT), count `obus_exposed`, which must be 0. That would be the only way the `open_bus` difference (study §2.7 item 8, risk 3) reaches the CPU. [corrected: make it exact rather than "next cycle". Keep a shadow `fe_obus`, updated every `clk_sys` as `fe_obus <= cpu_DB_oe ? physical_write_DB : fe_read_DB`. `fe_read_DB` is top.sv:379-394 with `open_bus` replaced by `fe_obus`, and `cart_DB_out`/`cart_DB_oe` replaced by `fe_do`/`fe_oe`. At every latch where L1 passes and `fe_read_DB != dut.read_DB`, count `obus_exposed`. The leak survives across consecutive partially driven cycles until a full drive or a write's phase 2 overwrites it (top.sv:346-352).] [Decided, F1_fixes.md 3: one exception, counted as `obus_ffe` instead: the TIA read at $0000 right after a CDF fast JMP's low operand at $1FFF (the JMP's opcode at $1FFE), with the undriven bits holding `daria_fe`'s substituted byte on its side and ROM[$1FFF] on upstream's. Every other `obus_exposed` must be 0.] |
| S1 | Every E0 and every `pclk0` | | spacing E0→`pclk0` and `pclk0`→E0 | | Histogram. Any E0→latch < 6 (an RSYNC, TIA.sv:565-567) is reported with its frame. `daria_fe`'s 6-clock read budget assumes 6. [added] Report separately the cycles while `!dut.phase_source_tia` (MARIA phases after every reset, 0) and those after a mid-line RSYNC. |
| W1 | Every upstream `pointer_write` (E0+7) | | `table_writeback.pointer_ack_sync2 != pointer_toggle`, i.e. a payload would be dropped (arm_mapper_writeback.sv:61-65) | | Count `wb_drop`, expected 0 (glue.md §9). If ever non-zero, upstream's RAM diverges from its own table, and K1/K2 must exclude that word. [added] The RTL rules it out (question 5): a capture is idle again after 3 `clk_sys`, and two commits are at least 4 `clk_sys` apart. Keep W1 as an assertion. |
| H1 [added] | every `clk_sys` while `running` | | the hold self-check of 7.4.2 | | `hold_bad`, must be 0 |

**Order within a clk_sys edge.** Run L1-L3 and the E0+6 latches before C1-C4. They read pre-edge values in the same `always @(posedge clk_sys)`, so the order is free. All checks start at `running = 1` (tb_daria.sv:952), except I1/I2 and the ROM check. [corrected: they start at the first E0 after `effective_reset` falls with `tia_en` high, as stated above the table]

### 7.6 Allowed differences: classification and resync

| Class | Cause (upstream source) | Rule |
|---|---|---|
| `amp_lag` (L1) | Upstream refreshes AMPLITUDE a variable time after each tick, waiting on `ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel` (cart2600.sv:965; arm_mapper_audio.sv:229-333). `daria_fe` uses fixed slots. | Accept a read where the two values are A(n) and A(n-1) of the same tick sequence (from T2's record). Count it. [checked; [added] it is avoidable (question 2). With an exact sequencer it must be 0.] |
| `note_race` (T2) | A DPC+ NOTE commit (E0+6) loads the frequency at upstream's `AUDIO_NOTE_CAPTURE` and at `daria_fe`'s job slot. A tick between the two adds different frequencies. [corrected: upstream writes the frequency at **E0+10** at the earliest (`note_pending` at E0+7, NOTE_ISSUE entered at E0+8, NOTE_CAPTURE entered at E0+9 if granted, the write at E0+10). It is later if the engine is mid-refresh or the grant is blocked (arm_mapper_audio.sv:201-205, 226-257).] | Classify when a NOTE commit occurred since tick n and `counter_fe − counter_up` = k·(`f_new − f_old`), with k the number of ticks in (N_up, N_fe] (or the reverse), N being each side's frequency-write edge. Resync. |
| `merge_race` (T2) | Upstream merges at X+1 after `call_done` at X (arm_mapper_audio.sv:213-223; glue.md §7.3). `daria_fe` merges after its `ret_tog` synchroniser and job slot. [added] CDF only. | Classify when a call returned since tick n. Resync. [added] Exact rule: with merge edges U (upstream) and D (`daria_fe`), the post-merge difference is `f_ret`·k for a voice whose return ≠ seed, and (`f_ret − f_old`)·k otherwise, where k = ticks in (min(U,D), max(U,D)]. When k = 0 the states agree after both merges, and nothing needs resync. |
| `seed_race` (R1, T2) | Upstream's seeds are the counters at the accept edge (E0+7, arm_mapper_audio.sv:207-211). `daria_fe`'s are taken when it posts. | Classify when the posted seed differs by one tick's add. Resync. [added] CDF only. Avoidable at no cost: latch the seeds (and frequencies) at E0+7 (section 10). |
| `over32k` (C4, K1) | A CDFJ+ 6507-side address `$800 + P[30:16]` can reach $87FF (mapper_cdf.sv:126-128). `cart_ram_tdp` is 128 KB; DARIA's cart RAM is 32 KB (daria_mem.sv:16-18). | Count, and exclude from RAM compares. Risk 5 of the study. [corrected: **cannot occur.** The sum is 15 bits wide (`display_address [14:0]`, `ram_addr [14:0]`, mapper_cdf.sv:36, 75, 126-128, 152-153) and wraps modulo $8000. `ram_a[BANKCDF] = {3'b0, cdf_ram_addr}` (cart2600.sv:898). Upstream's 6507-side window is exactly 32 KB with wrap, the same as DARIA's. `daria_fe` must wrap the same way: `($800 + P[30:16]) & $7FFF`. Kept only as a must-be-0 assertion; nothing is excluded.] |
| `drift_*` (O1) | Upstream's `d_out` changes after the latch; `daria_fe`'s holds. | Count. `obus_exposed` must stay 0. [checked] [Decided, F1_fixes.md 3: except `obus_ffe`, the TIA read at $0000 after a CDF fast JMP's low operand at $1FFF.] |

**Resync** (`+fe_resync=1`, the default): after a classified audio divergence, write upstream's `counter0..2` and `frequency0..2` by backdoor into `daria_fe`'s state RAM words at the next tick edge, and count `resync`. An `audio_bad` (unclassified) also resyncs, but still counts as a failure. [corrected: a blocking backdoor write at a tick edge races `daria_fe`'s own NBA tick update to the same word, and the NBA wins. Deposit at the **falling** `clk_sys` edge after the tick edge, the post-tick values (`dut.cart2600.mapper_audio.counterN` read after the NBAs). Use a `fe_taps.svh` task that knows where `daria_fe` keeps them, in RAM or in flops. Do not deposit while `daria_fe`'s audio sequencer is mid-update of those words (a tap flag); retry at the next falling edge instead.]

### 7.7 Reporting [checked]

- **`fe.csv`**, one line per frame (written at the VSYNC rise, as frames.csv):

  ```
  frame, latches, commits, dout_bad, dout_hidden, state_bad, ptr_bad, ram_bad, calls_up, calls_fe,
  call_bad, svc, svc_bad, ticks, tick_bad, audio_bad, amp_lag, note_race, merge_race,
  seed_race, resync, drift_up, drift_fe, obus_exposed, over32k, hold_bad
  ```

  [added: `dout_hidden`, `hold_bad`]
- **`fe_err.txt`:** the first `+fe_stop` failures (default 20). For each: the class and field, the E0 time, frame and scanline, `a_in`, `rw`, `d_in`, both values, and the 6507 PC (`op_pc`, tb_daria.sv:634-635). The first two also get a 64-entry ring dump (POKEY-style). Ring entries, one per `clk_sys`:

  ```
  pclk1 pclk0 access rw a_in d_in up_do up_oe fe_do fe_oe
  up_bank fe_bank arm_call_stall arm_dma_busy audio_tick
  ```

- **`fe_ticks.csv`** (`+fe_ticks=1`): per tick: tick time, `amplitude` up/fe, refresh latency up/fe, and resync/class.

  **`amp_up.pcm` / `amp_fe.pcm`** (`+fe_pcm=1`): one byte per tick, for `fe_amp_compare.py`.

  Both derive from the game and stay in `sim/work`.
- **Final line in `run.log`:**

  ```
  FE shadow: <scheme> <latches> latches, <commits> commits, <calls> calls,
  <svc> services, <ticks> ticks compared; dout <n>, state <n>, ram <n>, call <n>,
  svc <n>, tick <n>, audio <n> bad; amp_lag <n>, races <n>/<n>/<n>, resync <n>,
  obus_exposed <n>, over32k <n>, wb_drop <n>, hold <n>; E0->latch <min>..<max>
  ```

  Plus `FE latency:` lines (the histograms of T3, R1 and the busy-fall offset). [added: the NOTE-capture and merge-edge offsets (up − fe) as two more histograms]
- **`dynamic_tables.py --only fe`:** per image, the bad counts by class (all must be 0) and the counted classes, beside `sec_daria`'s columns.
- **Pass** (step 6, mode A): every image, 1,500 frames, all `*_bad` = 0, `tick_bad` = 0, `obus_exposed` = 0 (`obus_ffe` apart, F1_fixes.md 3). `amp_lag` and the races are reported with their rates. [added] Also `over32k` = 0, `wb_drop` = 0, `hold_bad` = 0, `seed_race` = 0, and the directed DPC+ copy/fill and CDF0 runs of 7.9 pass.

### 7.8 Plusargs and environment [checked]

| Name | Default | Meaning |
|---|---|---|
| `FE=1` | | Build with `-DFE_SHADOW` (`obj_fe`, `runs/fe/`) |
| `+fe_stop=N` | 20 | Stop printing after N failures. With `+fe_fatal=1`, `$finish` at the first. |
| `+fe_hold=0/1` | 1 | 7.4.2 |
| `+fe_resync=0/1` | 1 | 7.6 |
| `+fe_slat=N` | 40 | Digital-sample latency (`clk_sys`) |
| `+fe_ticks=1`, `+fe_pcm=1` | 0 | 7.7 |
| `+fe_full=N` | 1 | K2 every N frames |
| `+hard_reset_at=F` | 0 | Console reset pulse at frame F (7.2) |
| `+hard_reset_len=N` [added] | 1000 | Its length in `clk_sys` (not frames: 7.2) |
| `+d_ofs=PS` | 0 | `clk_d` phase (6.3; DARIA builds only) |
| existing | | `+frames`, `+fire_at`, `+play_at`, `+seed`, `+lat`, `+snap=0`, `+fp` |
| — | | Do not use `+arm_div` > 1 (tb_daria.sv:55-56 notes K = 2 makes no progress) |

`DTRACE=0` is recommended for FE runs.

### 7.9 Bring-up order and cost

0. [added] **Before `daria_fe` exists** (the front-end work starts now, per the user): build `fe_shadow.svh` with a *reference* front end in place of `u_fe`. That is a second instance of upstream's `mapper_dpcplus` or `mapper_cdf`, fed from the same taps, with `ram_data`/`ram_rdata` = `dut.cart2600.cartram_data`, `table_pointer`/`table_increment` = upstream's, and `amplitude` = upstream's. L1, L2, C1, C2 and S1 must then report 0. This proves the taps, the pre-edge conventions and the E0 tracking cheaply, before any `daria_fe` code is suspect. Then swap in `daria_fe`.
1. Build (about 20-40 s of Verilator, as `obj_shadow128`).
2. One DPC+ and one CDFJ image, `+frames=120`: the load, init and first frames, about 3-5 min [E].
3. All 21 images × 300 frames, then × 1,500 frames with `run_all.sh` (`JOBS=2`): about 1-1.5 h per image [E], so roughly 11-16 h for the set.
4. `+hard_reset_at` on one image per scheme.
5. A run with `--x-initial unique` and `+verilator+rand+reset+2` (`daria_fe`'s registers random at power-up, section 8 item 12).
6. Mode B and the `d_ofs` sweep for the guard.
7. [added] **Directed runs the image set cannot give** (section 8): a DPC+ copy/fill test (CALLFUNCTION 1 and 2, including the count clamps), a CDF0 image or synthetic CDF0 test, a digital-audio CDF test, and a mid-line RSYNC test. They exercise the hold, R2/R3 and the CDF0 layout.

The directed per-scheme tests and the random differential bench (study §5 tests 2-3) are separate benches. They drive upstream's `mapper_dpcplus`/`mapper_cdf` and `daria_fe` from a synthetic 6507 bus with the same checkers (L1, C1-C4, T1-T2) factored into a shared include.

---

## 8. Bench limitations

Each item says whether it makes a comparison impossible and how the plan handles it.

1. **`daria_fe`'s stall outputs never drive the 6507** in mode A. Upstream's `arm_call_busy`/`arm_dma_busy` do. Their timing against the bus can only be checked as offsets, not as behaviour. glue.md §7.5 notes a rise anywhere in [E0+6, E0+17] gives an identical bus. Full verification of the stall is mode B or step 7. [checked against glue.md §7.5 and mos6502_ctl.sv:874-881: F, the cycle after the CALLFN write, cannot be held, so a rise up to E0+17 still makes F's phase 2 at E0+18 the taken one]
2. **A slower copy engine** (F6 or DPC+ copy/fill) lets upstream's 6507 resume or start before `daria_fe`'s RAM is ready. Every later RAM-backed read could then differ. **Comparison impossible without the hold** (7.4.2): the `reset` term and the forced `arm_call_stall`. [checked; [added] and without the sticky guard, a gap between the two inits re-runs upstream's init]
3. **CDFJ+ addresses at or above 32 KB** on the 6507 side (`cartram_addr[16:15] != 0`) cannot be compared: DARIA's cart RAM is 32 KB, upstream's 128 KB. They are counted as `over32k`. [corrected: **not a limitation.** Upstream's CDF address is 15 bits and wraps inside 32 KB (section 2, E0+3 row). Every 6507-side, audio, ARM and init address of DPC+ and CDF stays below 32 KB (3.6).]
4. **BUS** has no `daria_fe` (decision 6), and no image in the set is BUS (study §5 risk 4). The shadow reports "scheme not shadowed" for 24. ELF (32) and BUS revision 0 are bad-game screens upstream (cart2600.sv:164-166). [checked]
5. **AMPLITUDE timing and `open_bus`** cannot match by design (study risks 1 and 3). They are classified, and `obus_exposed` proves the second invisible. [corrected: AMPLITUDE timing *can* match. Upstream's refresh timing is a deterministic function of the tick, the bus decode (`sel_ram_sel`) and init, all of which `daria_fe` has (question 2). Only the `open_bus` drift is by design.] [Decided, F1_fixes.md 3: `obus_exposed` proves it invisible everywhere but in one accepted case, `obus_ffe`: the TIA read at $0000 after a CDF fast JMP's low operand at $1FFF.]
6. **The audio races** (NOTE, merge, seed) change counters permanently. Without resync, every later tick would differ. With resync the comparison continues, but a real counter bug that coincides with a race could be masked once; it would show again at the next tick. [checked; [added] the merge race is the only one inherent to the design (7.6). It needs a tick inside the merge-offset window, about offset/716 per CDF call.]
7. **Digital samples beyond the window** come from an emulated port with a fixed latency. The real path (cache over `psram.sv`) exists only in `WRAPPER` builds, whose cart RAM port A belongs to DARIA's CPU: mode A cannot use the wrapper's memories. Run mode A with its own `fe_mem` beside a `WRAPPER` build if needed. In tb_daria, upstream's samples come through the behavioural DDR at `+lat`. [checked]
8. **Shared-edge races** are invisible with today's `clk_d` phase (section 6.1). In mode A they do not arise: the mirror is on upstream's `clk_arm`, which sits out shared edges (cart_ram_tdp.sv:29-54). The guard can only be judged in a DARIA build with `clk_d` aligned (6.4). Because sim reads old data deterministically, races are counted, not observed as wrong values. [checked]
9. **The console reset re-init** (F6 on a reset edge) is not exercised by today's bench (1.3). Add `+hard_reset_at`. [checked; [added] timed in `clk_sys` (7.2)]
10. **No pause and no PAL.** `pause` and `PAL` are tied to 0 (tb_daria.sv:192-194). `daria_fe`'s pause behaviour (glue.md §8, G5) and PAL are untested here. [checked]
11. **RSYNC** can shorten E0→latch (TIA.sv:565-567). If S1 ever reports < 6, `daria_fe`'s slot schedule (data final at s4) is out of contract for that cycle, while upstream's combinational path is not. A mismatch there is real but needs a directed test. [checked; [added] so can MARIA's phases in the few cycles after each reset release, before the handoff to the TIA (section 0)]
12. **`--x-initial fast`** (run_daria.sh:88) starts unreset registers at fast-path values (in practice 0). A missing reset in `daria_fe` can hide. Hence step 5 of 7.9. [checked]
13. **The upstream oracle's own artefacts** are compared as they are:
    - the stale second presentation of the held address (glue.md §7.5);
    - DPC+ fast fetch arming on data bytes;
    - 6-bit register numbers;
    - hotspots ignored on substituted reads;
    - the bank-crossing jump lookahead.

    `daria_fe` must copy them (study §2.7). A deliberate deviation shows up as a `*_bad` and needs its own class. [checked]
14. [added] **The image set never issues a DPC+ copy/fill** (`dma_events` = 0 in all 21 runs, 1.5). R2, R3 and the hold of 7.4.2 are therefore untested by the set. A directed test is needed (7.9, item 7).
15. [added] **No CDF0 image.** CDF0's table layout (0x1B8/0x1DA, arm_mapper_tables.sv:107-109) and waveform base 0x7F0 (arm_mapper_audio.sv:101-102) are not exercised.
16. [added] **Mode A's call timing is upstream's.** The emulated `ret_tog` makes `daria_fe`'s busy fall when upstream's does, so `daria_fe`'s G1 rule (glue.md G1) and its own call latency are tested only in mode B.
17. [added] **Image below 32 KB.** DPC+ copies image bytes $6C00-$7FFF at init. For a 29,696-byte DPC+ image (detect2600.sv:216), upstream reads past the end from the DDR model (zero-filled, tb_daria.sv:875) and `daria_fe` from its zero-initialised ROM. They agree in this bench by accident of initialisation, not by design.

---

## 9. Open questions (not settled from the RTL) and answers

1. **`daria_fe`'s interface is not fixed yet.** Port names; the state RAM map (fetchers, params, counters, frequencies, seeds, beside the call block at 0xF0-0xFD); the digital-sample port protocol; whether `call_ready` is `daria_ready & !busy` or upstream's; whether F6 starts on `load_end`, on `img_ready`, or on a `cart_reset` edge. `fe_taps.svh` isolates the bench from these choices, but the C1 and T2 field lists depend on them.

   [answered in part from the RTL]
   - **F6's start:** upstream starts its init at `load_end_d` (= `load_end` + 1 clock) and again on every **rising** `effective_reset` while idle with an image loaded. It is busy from `load_start` (arm_mapper_ram_init.sv:204-226; cart2600.sv:572-577). `daria_fe` should do the same: start on `load_end` (or one clock later), restart on a rising `cart_reset`, and raise `init_busy` from `load_start`. It must **not** start on a falling `cart_reset`, which would deadlock (7.4.2). `img_ready` belongs to DARIA's capture path. The front-end ROM is complete at `load_end` anyway: every byte below 32 KB is written as it streams (daria_mem.sv:194-197), and F6 reads only below $8000 (DPC+ $6C00-$7FFF, CDF $0000-$07FF).
   - **`call_ready`:** upstream accepts when `arm_call_ready && mapper_wb_idle && !mapper_init_busy` (cart2600.sv:661-662). At 6507 rates that is always true at E0+7 (7.4.4). Mode A: feed `dut.cart2600.arm_call_ready`, AND-ed with `daria_fe`'s own `!init_busy`. `daria_fe` has no writeback. Mode B and the Pocket: `daria_ready && !busy` from `daria_call`. Either way the accept edge is E0+7.
   - **State RAM map:** the RTL fixes only which state is observable (7.3, "The state the RTL makes observable"). The layout is free.
   - **Sample protocol:** not settled. Upstream's (request/ready/done through a toggle and one-word cache, arm_mapper_memory.sv:350-360, 899-930) is upstream-internal. The bench emulation (7.4.5) adapts to whatever DARIA chooses.
2. **Should `daria_fe` merge returns and load NOTE frequencies on exactly upstream's edges** (X+1; `AUDIO_NOTE_CAPTURE`) so the races vanish? Upstream's NOTE edge depends on `ram_grant`, which depends on 6507-side RAM use, so exact replication may cost more than the classes. The rates in `fe.csv` will tell.

   [answered from the RTL]
   - **NOTE and AMPLITUDE: yes, it can, cheaply.** `ram_grant` = `audio_ram_en && !init_ram_en && !sel_ram_sel` (cart2600.sv:965). `sel_ram_sel` is a combinational decode of the bus and mapper state that `daria_fe` computes anyway (DPC+ `ram_register_read` or a WRITE/PUSH write; CDF `stream_substitute && !amplitude_fetch`, or a DSWRITE with `access`). So a sequencer that copies arm_mapper_audio.sv:225-363 state for state, with its grant computed from `daria_fe`'s own decode, lands every NOTE capture and every AMPLITUDE update on upstream's edge. The cost is the grant term plus a few states.
     - Condition: `daria_fe`'s own 6507-side port-B traffic must sit inside the clocks where upstream's `sel_ram_sel` is high. Otherwise the audio's read data arrives late. In particular, an in-place CDF pointer write-back must happen at the E0+6 commit edge itself, where upstream's grant is still blocked, not at E0+7/E0+8, where upstream's audio may be granted.
     - Then `note_race` and `amp_lag` must be 0, and the classes become assertions.
   - **Merges: not exactly.** Upstream applies the returns at X+1 = S3+1, from 2-flop copies that are already valid at S3 (arm_mapper_controller.sv:126-131, 163-176). A front end that sees `ret_tog` through the same 2-flop synchroniser and then reads six return words through one state-RAM port at one word per clock cannot merge before about S3+6.
     - The post-merge state still agrees whenever no tick falls in the offset window (7.6, exact rule). The expected rate is about offset/716 per CDF call, roughly 1% for a 7-clock offset.
     - Keep `merge_race` with its exact classification and resync. In mode B and on hardware the merge edge is DARIA's anyway, so upstream's edge is not the target there.
   - **Seeds: yes, at no cost.** Latch the three counters and three frequencies at E0+7 (the accept edge), whatever the post time. Then `seed_race` = 0.
3. **Does Verilator 5.040's `force` on `dut.arm_call_stall`** (an `assign`ed `logic` read by `RDY` and `mapper_phi2`) reach both consumers? Expected yes. Confirm with the self-check in 7.4.2.

   [partly answered] There are four readers, not two (7.4.2): `RDY`, `mapper_phi2`, the `stall_cycle_taken` flop, and the bench's `call_stall` tap. The 5.040 binary contains Verilator's force machinery (`__VforceEn`, `__VforceVal`, `__VforceRd`; checked with `strings` on `/opt/verilator-5.040/bin/verilator_bin`). That scheme redirects every read of a forced variable to a `__VforceRd` copy, so all four readers should see the forced value. Whether a **non-constant** force expression is re-evaluated continuously could not be settled without running Verilator, which this check did not do. The bench's only existing use of a non-constant force RHS is `+arm_div`'s (tb_daria.sv:869-872), and that mode is broken for an unknown reason. Use the constant-RHS force/release at the falling edge (7.4.2), which does not depend on it, and keep the `hold_bad` self-check.
4. **Which images use DPC+ copy/fill, digital audio, AMPLITUDE reads near ticks, RSYNC, or CDFJ+ RAM at or above $8000?** These decide whether the hold, the sample emulation and the classes matter. The first FE runs count them; the RTL cannot say.

   [partly answered]
   - **CDFJ+ RAM at or above $8000: none, by the RTL.** The address wraps (7.6).
   - **DPC+ copy/fill: none** of the 21 images in 1,500 frames, from the existing runs' `summary.txt` (`dma_events` 0, 1.5). The hold needs a directed test.
   - **Digital audio, RSYNC, AMPLITUDE reads near ticks:** not logged by today's bench. The first FE runs count them (T4, S1, L1 class A).
5. **Can upstream's writeback ever drop a payload** (arm_mapper_writeback.sv:61-65) in tb_daria? glue.md §9 says not at 6507 rates. W1 counts it.

   [answered: no] After a capture at edge P, the `clk_arm` side sees the toggle at A+3 (sync1, sync2, then `active`). It writes at the first non-shared edge, A+4 (P+0.8 `clk_sys`); the writeback has priority on the port (cart2600.sv:432-439), so only `mapper_edge` can refuse it. The ack is back through two `clk_sys` flops, so `idle` reads high pre-edge at P+3 (arm_mapper_writeback.sv:40-41, 56-57, 91-131). A drop needs a second `pointer_write` at P+1 or P+2. Pointer writes follow commits, which need `pclk0`. Two `pclk0` edges are at least 4 `clk_sys` apart (section 0). The only other drop is a console reset mid-flight (`reset_sys`/`reset_arm` are the console reset, cart2600.sv:741, 751), possible only with `+hard_reset_at`. W1 stays as an assertion.
6. **Which `clk_sys` class carries the coincident edge on the Pocket's PLL**, and does the Cyclone V counter release guarantee exact coincidence? The bench sweeps all three (`d_ofs`); the guard must find the phase at run time.

   [partly answered]
   - **The class relative to E0 is not fixed by anything in the RTL.** The TIA divider restarts at every console reset (TIA.sv:569-570) and can re-phase on RSYNC (:565-567), while the PLL runs on. A PAL/NTSC reconfiguration relocks the PLL and may restart its counters (core_constraints.sdc:5, 10-11; an inference).
   - **The guard needs only the clock relationship**, not E0. The detector of 6.4 finds it from the clocks alone.
   - **On coincidence:** the repository's PLL starts its zero-phase counters with equal presets (`c_cnt_prst = 1`, `ph_mux_prst = 0`, pll_core.v:125-150), and the SDC times all counters as one synchronous group (core_constraints.sdc:12-22). So a ÷18 counter added the same way shares edges with ÷48, and the transfer is hold-checked at the shared edge. The residual skew is the clock network's, which TimeQuest includes. The device's counter-release behaviour itself is not in the repository.
7. **Mode B's audio after calls.** DARIA and upstream return at different times. Should mode B resync after every call, or compare only RAM and 6507 data there?

   [answered from the RTL] Neither. After both merges the counters and frequencies are identical unless a tick falls in (min(U,D), max(U,D)] for the two merge edges (arm_mapper_audio.sv:191-223; 7.6). Ticks are `clk_sys`-locked and identical on both sides. Compare audio exactly in mode B. Resync, and count, only the voices of calls with a tick in that window, using the formula of 7.6. This assumes the two CPUs return the same words, which step 5 established. A call that reads T1TC may legitimately return different words (`MMIO_TOL`); class those as `merge_value` and resync.
8. **The study's "data final at s4"** assumes `daria_fe` reads its front-end ROM at s0. With the shadow's `rom_do` from tb_daria's 1-clock ROM, upstream is final by E0+3. Both are inside E0+6, but `daria_fe`'s budget is not checked against a slower ROM, which matches the BRAM it will have. [checked; [added] `daria_fe` reads its own `fe_mem.fe_rom`, a registered `daria_ram` with the same 1-clock latency (daria_mem.sv:194-197), not tb_daria's `rom[]`]
9. **Output-port initialisers.** `BUP/daria_call.sv:43` (`output logic ret_tog = 1'b0`) and `:50` (`clr_pc = 32'd0`) match `run_sim.sh`'s guard pattern. The guard (sim/run_sim.sh:18-21) greps all of `core/bupchip/*.sv` and exits 1, so `run_sim.sh` and `run_pokey_shadow.sh`, which needs `run_sim.sh`'s output, now refuse to run. Quartus 21.1 also ignores such initialisers (docs/DEVELOPING.md, "Power-up values"). This is outside tb_daria, but `daria_fe.sv` must not repeat it, and step 7's regressions will hit it.

   [answered as far as the repository goes]
   - **Confirmed:** the guard's `grep` matches exactly those two lines today.
   - [corrected: `run_pokey_shadow.sh` itself has no guard. It stops at :51 because `sim/work/pokey_watson.v` is absent here, and only `run_sim.sh`, which refuses, can make it.]
   - **Not recorded as a known issue** in docs/DARIA_CORE.md or docs/DEVELOPING.md. `daria_call.sv` came in with commit c22e3cc ("DARIA step 5 (WIP)").
   - **Step 7 must fix it:** its done-when requires `run_sim.sh` to pass (docs/DARIA_CORE.md:1637). The fix is an internal declaration or an `initial` block.
   - **Functionally harmless on hardware:** `clr_pc` is loaded before every use (daria_call.sv:104-105). `ret_tog` toggles, so it cannot become a constant, and its power-up value does not matter if the front end loads its seen flag from the synchronised `ret_tog` while reset, as daria_call.sv:29-32 prescribes. `daria_fe` must do that (7.4.4).
10. **`+arm_div` > 1** makes no progress (tb_daria.sv:55-56). The mirror taps `cart_ram_tdp`'s port, so it is exact either way, but the cause is unknown. [checked; still open. Do not run the FE shadow with it.]

---

## 10. Guards to build [added]

Per the user's decision for this run, each guard below is built if it costs little and keeps the core in step with upstream.

| # | Where | Guard | Cost | Effect |
|---|---|---|---|---|
| 1 | DARIA (`bup_cpu`/`daria_mem` port A, `prof26` only) | W-wait a cart RAM store that would land on a shared `clk_arm`/`clk_sys` edge; shared edge found by the 8:3 detector of 6.4 | ≈ 10 FF + a W term | Removes the open item 7 race. Delays one store in 8 by one `clk_d`. Accepted by 6.4's four checks plus `det_bad` = 0. |
| 2 | `daria_fe` | Latch the call's seeds and frequencies at the accept edge E0+7 | 6 × 32 FF, or write them to state RAM at E0+7 | `seed_race` = 0 (R1 exact) |
| 3 | `daria_fe` | Audio sequencer in step with upstream's, grant = `!init && !sel_ram_sel`-equivalent; in-place pointer write-back at the E0+6 edge | a few states | `note_race` = `amp_lag` = 0 |
| 4 | `daria_fe` | Load the return "seen" flag from the synchronised `ret_tog` while in reset; start F6 on `load_end` and on a rising `cart_reset`, never on a falling one; `init_busy` from `load_start` | none | Power-up value of `ret_tog` irrelevant; no init deadlock; same init edges as upstream |
| 5 | `daria_fe` | CDFJ+ display address computed modulo $8000 | none | Matches upstream's wrap (7.6) |
| 6 | bench | Sticky `fe_hold_reset` (7.4.2) | a few flops | The console reset never drops between the two inits |
| 7 | bench | Constant-RHS force/release at the falling edge, plus the `hold_bad` self-check (7.4.2) | — | Hold independent of Verilator's handling of a non-constant force RHS |
| 8 | bench | `+hard_reset_len` in `clk_sys` | — | The reset pulse ends |
| 9 | bench | W1 and `over32k` as assertions | — | Proves the RTL facts of question 5 and 7.6 on every run |
