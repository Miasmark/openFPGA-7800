# `daria_fe`: the interfaces as frozen at step 0

This is `design.md` 12.2 step 0, "freeze the interfaces". It records the ports of `daria_fe` and of its eight submodules as they are in `src/fpga/core/bupchip/`, the bench tap names and encodings they carry, every place where the design was read one way rather than another, and the shared unit-bench infrastructure. From here on, **a change to anything in sections 3-6 needs the lead's sign-off** (12.2). The module bodies are the lanes' (12.1, 12.2 step 1). Section 11 is the independent review of step 0: its fixes (R-1 … R-4) are already folded into the sections above, and its open questions (L-1 … L-6) are the lead's.

The port tables in sections 3 and 5 are generated from the sources, so they are what the code says.

## 1. Files

| File | What it is | Lane |
|---|---|---|
| `src/fpga/core/bupchip/daria_fe_pkg.sv` | `opc_t`, `dec_t`, the TICK constants (1.3), and the step-0 encodings (S0-11) | 0 (frozen) |
| `src/fpga/core/bupchip/daria_fe.sv` | The top: the ports of 1.2, the scheme decode, `rst_fe` (F2), `fe_oe`, and the seven instances, completely wired | 0 (frozen) |
| `src/fpga/core/bupchip/daria_fe_{seq,dec,core}.sv` | Headers with the frozen ports; every output and every tap tied off (`// stub`). `u_core` instantiates `u_dec` | A |
| `src/fpga/core/bupchip/daria_fe_audio.sv` | The same | B |
| `src/fpga/core/bupchip/daria_fe_{call,copy}.sv` | The same | C |
| `src/fpga/core/bupchip/daria_fe_{arb,guard}.sv` | The same | D |
| `src/fpga/core/bupchip/daria_mem.sv` | `DARIA_RAM_POISON`, a simulation-only option of `daria_ram`'s behavioural model (12.1; section 9.4) | 0 |
| `sim/bupchip/quartus_probe/daria_fe_map.sh` | Quartus probe of `daria_fe` or any block alone: Analysis & Elaboration, `--synth`, `--fit` (section 8) | all |
| `sim/bupchip/daria/fe_unit/run_unit.sh` | Builds and runs the unit benches (section 9.1) | all |
| `sim/bupchip/daria/fe_unit/phase_gen.svh` | `fe_phase_gen`, the shared random 6507 phase and bus generator (section 9.2) | all (E owns it from here) |
| `sim/bupchip/daria/fe_unit/tb_fe_phasegen.{sv,f}` | The generator's self-test (section 9.3) | E |
| `sim/bupchip/daria/fe_unit/tb_fe_rampoison.{sv,f}` | The poisoned and default RAM models (section 9.4) | 0 |
| `sim/bupchip/daria/fe_unit/tb_fe_stub.{sv,f}` | The whole tree with `daria_mem`, 1,000 clocks (section 9.5) | 0 |

## 2. Rules for every file

- `` `default_nettype none `` (restored to `wire` at the end), the MIT SPDX line, and D10 (design 1.1): one load enable and at most a 4-input data mux per register, one-hot selects as AND-OR muxes, every stage registered.
- Ports are `input wire` and `output logic`, one per line. **No output port has an initialiser** (BEN Q9; `sim/run_sim.sh` refuses them): a power-up value goes on an internal register, and an `assign` drives the port (as `daria_call.sv` does). An `output logic` may be driven by an `always_ff` without a port change (S0-17).
- Every clocked block has a `clk_sys` port (S0-1); `u_guard` also has `clk_arm`.
- **Bench taps are internal signals, not ports** (S0-2). Each stub declares its taps with the frozen name and width, tied off, so `fe_taps.svh` can be written against the stubs now. A lane replaces the tie-off with the logic and keeps the name and the width (and the bit order of section 4 for the one-hot ones). The audio registers the deposit task writes carry `/* verilator public_flat_rw */` under `` `ifdef VERILATOR `` (1.7).
- Verilator `-Wall` reports the repository's power-up idiom (`logic x = 1'b0;` plus an `always_ff`) as PROCASSINIT. Waive it where it is used, with a `lint_off`/`lint_on` pair and a comment, as `daria_fe.sv` does for `scheme_q` (docs/DEVELOPING.md, "Power-up values").
- The lint command (section 7):

  ```sh
  B=src/fpga/core/bupchip
  /opt/verilator-5.040/bin/verilator --lint-only -Wall --top-module daria_fe \
      $B/daria_fe_pkg.sv $B/daria_fe_{seq,dec,core,audio,call,copy,arb,guard}.sv $B/daria_fe.sv
  ```

## 3. `daria_fe` (the top)

The ports are 1.2's, in 1.2's order, with 1.2's names and widths. "Inside" is where each goes in `daria_fe.sv`.

| Dir | Port | W | Inside | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `u_seq.clk_sys`, `u_core.clk_sys`, `u_audio.clk_sys`, `u_call.clk_sys`, `u_copy.clk_sys`, `u_arb.clk_sys`, `u_guard.clk_sys` | 14.318 MHz |
| input | `clk_arm` | 1 | `u_guard.clk_arm` | feeds only u_guard.pd_tog |
| input | `cart_reset` | 1 | `u_audio.cart_reset`, `u_call.cart_reset`, `u_copy.cart_reset`, `rst_fe` | effective_reset |
| input | `pause` | 1 | `u_audio.pause` | pause_core |
| input | `a_in` | 13 | `u_seq.a12`, `u_core.a_in`, `fe_oe` | {AB[12] & bios_en_b, AB[11:0]} |
| input | `d_in` | 8 | `u_core.d_in` | write_DB (the CPU's DOR) |
| input | `rw` | 1 | `u_core.rw` | RW |
| input | `pclk1` | 1 | `u_seq.pclk1`, `u_core.pclk1` | phi1_ce |
| input | `pclk0` | 1 | `u_seq.pclk0` | phi2_ce |
| input | `access` | 1 | `u_seq.access`, `u_core.access` | mapper_phi2 && arm_driver_run |
| input | `scheme` | 6 | `is_dpc`, `is_cdf`, `scheme_q`, `rst_fe` | force_bs with the override: 21 DPC+, 23 CDF |
| input | `revision` | 3 | `jplus`, `jrev`, `u_core.rev`, `u_core.sf`, `u_audio.rev` | mapper_revision: [0] stable_fractional, [1:0] CDF version; [2] is BUS's |
| input | `cdf_ldx` | 1 | `u_core.ldx` | detect2600 |
| input | `cdf_ldy` | 1 | `u_core.ldy` |  |
| input | `fetch_off_en` | 1 | `u_core.foff_en` |  |
| input | `fetch_off` | 8 | `u_core.foff` |  |
| input | `cdfj_entry` | 32 | `u_call.cdfj_entry` |  |
| input | `cdfj_stack` | 32 | `u_call.cdfj_stack` |  |
| input | `audio_size_addr` | 16 | `u_audio.asz` |  |
| input | `rom_size` | 32 | `u_audio.rom_size` | cart_size |
| input | `ram32` | 1 | `u_audio.ram32`, `u_copy.ram32` | mapper_ram_size == 32768 |
| input | `load_start` | 1 | `u_copy.load_start` | one-clock pulses (mapper_load_*) |
| input | `load_end` | 1 | `u_copy.load_end` |  |
| input | `cart_win` | 1 | `u_copy.cart_win` | bup_capture.cart_win; its fall is c_close |
| input | `cpu_ready` | 1 | `u_call.cpu_ready`, `u_guard.cpu_ready` | daria_ready (mode A: see design 1.2) |
| input | `ret_tog` | 1 | `u_call.ret_tog` | clk_arm domain |
| output | `call_tog` | 1 | `u_call.call_tog` | reg |
| output | `smp_req` | 1 | `u_audio.smp_req` | reg: digital-sample request toggle |
| output | `smp_addr` | 19 | `u_audio.smp_addr` | reg: image byte offset |
| input | `smp_ack` | 1 | `u_audio.smp_ack` | answer toggle, wrapper's domain |
| input | `smp_data` | 8 | `u_audio.smp_data` |  |
| output | `fe_do` | 8 | `u_core.fe_do` | reg: direct_do for BANKDPCP and BANKCDF |
| output | `fe_oe` | 1 | `a_in[12]` | comb: a_in[12] |
| output | `arm_call_busy` | 1 | `u_core.call_busy`, `u_call.arm_call_busy` | reg: the stall terms (top.sv:306-307) |
| output | `arm_dma_busy` | 1 | `u_copy.arm_dma_busy`, `u_core.dma_busy` | reg (`u_core`: review R-2) |
| output | `init_busy` | 1 | `u_core.init_busy`, `u_copy.init_busy` | reg: into atari7800_pocket's reset OR |
| output | `fea_addr` | 13 | `u_arb.fea_addr` | FE ROM port A word address |
| input | `fea_q` | 32 | `u_core.fea_q`, `u_audio.fea_q`, `u_copy.fea_q` |  |
| output | `feb_addr` | 13 | `u_core.feb_addr` | FE ROM port B: the mirror |
| input | `feb_q` | 32 | `u_core.feb_q` |  |
| output | `crb_addr` | 13 | `u_arb.crb_addr` | cart RAM port B |
| output | `crb_we` | 1 | `u_arb.crb_we` |  |
| output | `crb_be` | 4 | `u_arb.crb_be` |  |
| output | `crb_wd` | 32 | `u_arb.crb_wd` |  |
| input | `crb_q` | 32 | `u_core.crb_q`, `u_audio.crb_q` |  |
| output | `stb_addr` | 8 | `u_arb.stb_addr` | state RAM port B |
| output | `stb_we` | 1 | `u_arb.stb_we` |  |
| output | `stb_be` | 4 | `u_arb.stb_be` |  |
| output | `stb_wd` | 32 | `u_arb.stb_wd` |  |
| input | `stb_q` | 32 | `u_core.stb_q`, `u_audio.stb_q` |  |
| input | `hk_en` | 1 | `u_audio.hk_en`, `u_call.hk_en` | bench merge hook; tied 0 in synthesis |
| input | `hk_stb` | 1 | `u_audio.hk_stb`, `u_call.hk_stb` | bench: upstream's call_done |
| input | `hk_ret` | 192 | `u_audio.hk_ret` | bench: {f2, f1, f0, c2, c1, c0} |

**The top's own logic** (2.4, F2, 5.2):

```systemverilog
wire       is_dpc = scheme == daria_fe_pkg::SCHEME_DPCP;          // 21
wire       is_cdf = scheme == daria_fe_pkg::SCHEME_CDF;           // 23
wire       jplus  = is_cdf & (revision[1:0] == 2'd3);             // CDFJ+          (S0-4)
wire       jrev   = is_cdf & revision[1];                         // CDFJ, CDFJ+    (S0-4)
wire [1:0] fam    = {is_cdf, is_dpc | is_cdf};                    // 1 DPC+, 3 CDF, 0 otherwise
logic [5:0] scheme_q = 6'd0;  always_ff @(posedge clk_sys) scheme_q <= scheme;
wire       rst_fe = cart_reset | !(is_dpc | is_cdf) | (scheme != scheme_q);       // S0-13
assign fe_oe = a_in[12];
```

**Instances** (1.1): `u_seq`, `u_core` (with `u_core.u_dec`), `u_audio`, `u_call`, `u_copy`, `u_arb`, `u_guard`. The names are frozen: the bench taps (1.7) and the SDC lines of 8.2 (`*|daria_fe_guard:u_guard|pd_tog`, `|pd_rx`) use them.

**Outputs nothing in `daria_fe` reads** (S0-14): `u_seq.ph2`, `u_copy.rst_quiet`, `u_arb.crb_use` and `u_guard.locked` go to wires that only the bench reads.

## 4. `daria_fe_pkg`

`opc_t` and `dec_t` are 1.3's, field for field. `$bits(dec_t)` is **38**, not 42 (S0-3). `TICK_TH`, `TICK_WRAP` and `TICK_STEP` are 1.3's.

The step-0 encodings (S0-11). The bench decodes these, so they are part of the interface:

| Constant | Values | Meaning |
|---|---|---|
| `SCHEME_DPCP`, `SCHEME_CDF` | 21, 23 | `force_bs` (detect2600.sv's `bss_type`) |
| `AS_IDLE` … `AS_RWAIT` | 0 IDLE, 1 NISS, 2 NCAP, 3 PISS, 4 PCAP, 5 SZISS, 6 SZCAP, 7 SMISS, 8 SMCAP, 9 DROUTE, 10 RISS, 11 RWAIT | the bit of each state in `u_audio.st[11:0]` (one-hot; 5.4's order) |
| `CS_IDLE` … `CS_REL` | 0 IDLE, 1 POST, 2 FLIP, 3 RUN, 4 RD, 5 RDW, 6 APPLY, 7 HKW, 8 REL | the bit of each state in `u_call.st[8:0]` (one-hot; 6.1's order) |
| `F6_CLR` … `F6_END` | 0 CLR, 1 P1, 2 P2, 3 END | the bit of each phase in `u_copy.f6_ph[3:0]` (one-hot while `f6_act`; 7.2) |
| `PC_NONE`, `PC_DSW`, `PC_DSP`, `PC_SVC` | 0, 1, 2, 3 | `u_core.pend_c[1:0]`, the at-commit action still waiting (2.3, 2.4); `svc_hold = svc_pend \| (pend_c == PC_SVC)` (7.4) |
| `OR_F6` … `OR_COPY` | 0 F6, 1 core fixed, 2 audio, 3 P32, 4 pointer write, 5 copy engine | the bit of each owner in `u_arb.own_r[5:0]` = its priority (3.1) |
| `OS_CZ`, `OS_CORE`, `OS_CALL` | 0, 1, 2 | `u_arb.own_s[2:0]` (3.2) |
| `OA_F6`, `OA_LOOK`, `OA_AUD`, `OA_COPY` | 0, 1, 2, 3 | `u_arb.own_a[3:0]` (3.3; the capture's `cap_we` override is inside `daria_mem`, not an owner here) |

## 5. The submodules

Each table gives the port, its width, and what it connects to in `daria_fe.sv` (for `daria_fe_dec`, in `daria_fe_core.sv`). Then the taps: internal signals with frozen names and widths (S0-2).

### 5.1 `daria_fe_seq` (2.1; lane A)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `pclk1` | 1 | `pclk1` | phi1_ce: E0 is the edge at which it is sampled high |
| input | `pclk0` | 1 | `pclk0` | phi2_ce |
| input | `access` | 1 | `access` | mapper_phi2 && arm_driver_run |
| input | `a12` | 1 | `a_in[12]` | a_in[12] |
| output | `k` | 8 | `k` | reg: k[j] in (E0+j, E0+j+1), j < 7; k[7] saturates |
| output | `c` | 4 | `c` | reg: c[j] in (C+j, C+j+1), j < 3; c[3] saturates |
| output | `ph2` | 1 | `ph2` | reg: set at pclk0, cleared at pclk1 |
| output | `commit` | 1 | `commit` | comb: access & a12 |
| output | `ph1_open` | 1 | `ph1_open` | comb: !ph2 & !pclk0 |
| output | `rel_ok` | 1 | `rel_ok` | comb: (ph2 \| pclk0) & !pclk1 |
| output | `ev_short` | 1 | `ev_short` | comb: commit & !(k[5] \| k[6] \| k[7]) |

Taps: `k`, `c`, `ph2`, `ev_short` are ports. No reset; power-up `k = 8'h80`, `c = 4'h8`, `ph2 = 0` on internal registers (2.1, 1.5 rule 7).

### 5.2 `daria_fe_dec` (2.2; lane A; combinational, no clock)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `a_in` | 13 | `a_in` |  |
| input | `rw` | 1 | `rw` |  |
| input | `access` | 1 | `access` |  |
| input | `romb` | 8 | `romb` | feb_q[8*lane_q +: 8]: upstream's rom_do in every clock |
| input | `is_dpc` | 1 | `is_dpc` |  |
| input | `is_cdf` | 1 | `is_cdf` |  |
| input | `jplus` | 1 | `jplus` | CDFJ+ (is_cdf & revision == 3) |
| input | `jrev` | 1 | `jrev` | CDFJ or CDFJ+ (is_cdf & revision >= 2) |
| input | `ldx` | 1 | `ldx` | detect2600 cdf_ldx |
| input | `ldy` | 1 | `ldy` | detect2600 cdf_ldy |
| input | `foff_en` | 1 | `foff_en` | fetch offset enable |
| input | `foff` | 8 | `foff` | fetch offset |
| input | `bank` | 3 | `bank` | step 0 (interfaces.md S0-5): rom_a needs it |
| input | `ff_en` | 1 | `ff_en` | DPC+ fast fetch enabled |
| input | `fpend` | 1 | `fpend` | fast fetch pending (both schemes) |
| input | `fexp` | 13 | `fexp` | CDF expected fetch address |
| input | `jr` | 2 | `jr` | CDF jump operands to go |
| input | `jexp` | 13 | `jexp` | CDF expected jump operand address |
| input | `jstream` | 6 | `jstream` | CDF jump stream |
| input | `mode` | 8 | `mode` | CDF SETMODE |
| output | `dec` | dec_t (38) | `dec` | comb, jok = 0 |
| output | `sel_up` | 1 | `sel_up` | comb: (is_dpc & d_sel) \| (is_cdf & c_sel) |
| output | `rom_a` | 15 | `rom_a` | comb: image byte offset of the mirror (< $8000) |

`bank` is a step-0 addition (S0-5). `jok` in `dec` is 0 here; `u_core` forms it in `k[1]` (2.2).

### 5.3 `daria_fe_core` (2.2-2.6; lane A)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `rst_fe` | 1 | `rst_fe` | cart_reset \| !(is_dpc \| is_cdf) \| scheme != scheme_q |
| input | `is_dpc` | 1 | `is_dpc` |  |
| input | `is_cdf` | 1 | `is_cdf` |  |
| input | `jplus` | 1 | `jplus` | CDFJ+ (is_cdf & revision[1:0] == 3) |
| input | `jrev` | 1 | `jrev` | CDFJ, CDFJ+ (is_cdf & revision[1:0] >= 2) |
| input | `rev` | 2 | `revision[1:0]` | step 0 (S0-6): revision[1:0], for pb/ib (2.4) |
| input | `sf` | 1 | `revision[0]` | revision[0]: DPC+ stable_fractional |
| input | `ldx` | 1 | `cdf_ldx` |  |
| input | `ldy` | 1 | `cdf_ldy` |  |
| input | `foff_en` | 1 | `fetch_off_en` |  |
| input | `foff` | 8 | `fetch_off` |  |
| input | `a_in` | 13 | `a_in` |  |
| input | `d_in` | 8 | `d_in` | write_DB |
| input | `rw` | 1 | `rw` |  |
| input | `access` | 1 | `access` |  |
| input | `pclk1` | 1 | `pclk1` | step 0 (S0-7): the ready flags clear at every pclk1 (2.3) |
| input | `k` | 8 | `k` |  |
| input | `c` | 4 | `c` |  |
| input | `commit` | 1 | `commit` |  |
| input | `ph1_open` | 1 | `ph1_open` |  |
| input | `ev_short` | 1 | `ev_short` |  |
| input | `fea_q` | 32 | `fea_q` |  |
| input | `feb_q` | 32 | `feb_q` |  |
| input | `crb_q` | 32 | `crb_q` |  |
| input | `stb_q` | 32 | `stb_q` |  |
| input | `aud_take` | 1 | `aud_take` |  |
| input | `look_gnt` | 1 | `look_gnt` |  |
| input | `p32_gnt` | 1 | `p32_gnt` |  |
| input | `wb_gnt` | 1 | `wb_gnt` |  |
| input | `guard_on` | 1 | `guard_on` |  |
| input | `amp_nx` | 8 | `amp_nx` | the value amplitude holds after this edge |
| input | `svc_take` | 1 | `svc_take` | pulse: the engine took the latched service |
| input | `init_busy` | 1 | `init_busy` |  |
| input | `dma_busy` | 1 | `arm_dma_busy` | review R-2: u_copy's arm_dma_busy, for `ev_rmw_svc` |
| input | `call_busy` | 1 | `arm_call_busy` | u_call's arm_call_busy |
| output | `fe_do` | 8 | `fe_do` | reg |
| output | `sel_up` | 1 | `sel_up` | comb (u_dec) |
| output | `feb_addr` | 13 | `feb_addr` | comb: rom_a[14:2] |
| output | `cr_fix` | 1 | `cr_fix` | comb |
| output | `cr_fix_a` | 13 | `cr_fix_a` |  |
| output | `cr_fix_we` | 1 | `cr_fix_we` |  |
| output | `cr_fix_be` | 4 | `cr_fix_be` |  |
| output | `cr_fix_wd` | 32 | `cr_fix_wd` |  |
| output | `cr_fix_use` | 1 | `cr_fix_use` | a consumed read |
| output | `cr_p32` | 1 | `cr_p32` | comb |
| output | `cr_p32_a` | 13 | `cr_p32_a` |  |
| output | `cr_wb` | 1 | `cr_wb` | wb_v & rdW (3.1; S0-8) |
| output | `cr_wb_a` | 13 | `cr_wb_a` | {4'b0, wb_a} |
| output | `cr_wb_wd` | 32 | `cr_wb_wd` | W |
| output | `cs_req` | 1 | `cs_req` |  |
| output | `cs_a` | 8 | `cs_a` |  |
| output | `cs_we` | 1 | `cs_we` |  |
| output | `cs_be` | 4 | `cs_be` |  |
| output | `cs_wd` | 32 | `cs_wd` |  |
| output | `look_req` | 1 | `look_req` | k[0] & is_cdf & !init_busy |
| output | `look_a` | 13 | `look_a` | rom_a[14:2] + 1 |
| output | `wave0` | 7 | `wave0` | reg |
| output | `wave1` | 7 | `wave1` | reg |
| output | `wave2` | 7 | `wave2` | reg |
| output | `note_stb` | 1 | `note_stb` | reg pulse in (C, C+1) |
| output | `note_v` | 2 | `note_v` | reg |
| output | `note_val` | 8 | `note_val` | reg |
| output | `cdf_dig` | 1 | `cdf_dig` | mode[7:4] == 0 |
| output | `callfn` | 1 | `callfn` | comb pulse at C: $105A / $1FF3 commit, d_in in {FE, FF} |
| output | `svc_pend` | 1 | `svc_pend` | reg |
| output | `svc_hold` | 1 | `svc_hold` | svc_pend \| (pend_c == PC_SVC) |
| output | `svc_fill` | 1 | `svc_fill` | reg |
| output | `svc_src` | 17 | `svc_src` | reg |
| output | `svc_dst` | 13 | `svc_dst` | reg |
| output | `svc_rem` | 8 | `svc_rem` | reg: the requested p3 |
| output | `svc_val` | 8 | `svc_val` | reg |
| output | `dma_set` | 1 | `dma_set` | comb pulse at C: a taken CALLFUNCTION 1/2 |
| output | `op` | dec_t (38) | `op` | reg: the op latched @2 |
| output | `p32_q` | 1 | `p32_q` | reg: the P32 read registered at this edge |
| output | `rdP` | 1 | `rdP` | reg: W holds P32 |
| output | `wb_v` | 1 | `wb_v` | reg: the pointer buffer is full |
| output | `ev_guard_sup` | 1 | `ev_guard_sup` | pulse: a fixed R or P32 request suppressed by guard_on |

Step-0 additions: `rev` (S0-6), `pclk1` (S0-7), and the outputs `op`, `p32_q`, `rdP`, `wb_v`, `ev_guard_sup` for `u_arb`'s assertions (S0-9); the review added the input `dma_busy` (R-2). `cr_wb` is `wb_v & rdW` (S0-8). The inputs `c`, `aud_take`, `look_gnt`, `ev_short` and `call_busy` are 1.4's, though no rule in 2.3-2.6 reads them (section 10).

Internal, to and from `u_dec`: `dec` (`dec_t`), `rom_a[14:0]`, `romb[7:0]` (= `feb_q[8*lane_q +: 8]`).

Taps (1.7):

| Tap | W | Meaning |
|---|---|---|
| `op` (port) | `dec_t` | the op latched @2 |
| `bank` | 3 | |
| `fpend` | 1 | fast fetch pending |
| `W` | 32 | |
| `wb_v` (port), `wb_a` | 1, 9 | the pointer buffer; `cr_wb_a = {4'b0, wb_a}` |
| `p32_in` | 1 | = `p32_q` (S0-10) |
| `sel_up` (port) | 1 | |
| `pend_s`, `pend_r`, `pend_c` | 1, 1, 2 | `pend_c`: `PC_*` |
| `rdW`, `rdP` (port), `rdS` | 1 each | the ready flags |
| `ff_en`, `rnd`, `pptr` | 1, 32, 4 | DPC+ |
| `wave[0:2]` | 3 × 7 | unpacked; `wave0..2` are the ports |
| `svc_pend`, `svc_fill`, `svc_src`, `svc_dst`, `svc_rem`, `svc_val` (ports) | 1, 1, 17, 13, 8, 8 | the latched service (`svc_rem` = the requested p3) |
| `note_stb`, `note_v`, `note_val` (ports) | 1, 2, 8 | |
| `mode`, `fexp`, `jr`, `jexp`, `jstream` | 8, 13, 2, 13, 6 | CDF |
| `ev_tbl_alias`, `ev_guard_sup` (port), `ev_rmw_svc` | 1 each | events (one-clock pulses); `ev_rmw_svc` = a taken CALLFUNCTION 1/2 (`dma_set`) while `dma_busy` is high pre-edge (R-2, L-1) |
| `a_fpjr`, `a_pend_late` | 1 each | assertions (must stay 0) |
| `rcyc` | 1 | bench and assertion only: 1 when some edge since the last `pclk1` had `rst_fe` high, that `pclk1` edge excluded; it masks `a_pend_late` at the end of such a cycle and nothing else reads it (lanes/F1_fixes.md 1) |

### 5.4 `daria_fe_audio` (5; lane B)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `cart_reset` | 1 | `cart_reset` |  |
| input | `pause` | 1 | `pause` | pause_core |
| input | `fam` | 2 | `fam` | 1 DPC+, 3 CDF, 0 otherwise (live) |
| input | `rev` | 2 | `revision[1:0]` | revision[1:0] |
| input | `rom_size` | 32 | `rom_size` |  |
| input | `ram32` | 1 | `ram32` | ram_size = ram32 ? $8000 : $2000 |
| input | `asz` | 16 | `audio_size_addr` | audio_size_addr |
| input | `cdf_dig` | 1 | `cdf_dig` | from u_core: mode[7:4] == 0 |
| input | `wave0` | 7 | `wave0` | from u_core |
| input | `wave1` | 7 | `wave1` |  |
| input | `wave2` | 7 | `wave2` |  |
| input | `note_stb` | 1 | `note_stb` | pulse in (C, C+1) |
| input | `note_v` | 2 | `note_v` |  |
| input | `note_val` | 8 | `note_val` |  |
| input | `cp_cap` | 1 | `cp_cap` | pulse: the ring captures counters and frequencies |
| input | `cp_rot` | 1 | `cp_rot` | pulse: the ring rotates (posting F2-F7) |
| input | `cp_shin` | 1 | `cp_shin` | pulse: stb_q shifts into the ring |
| input | `cp_cmp` | 1 | `cp_cmp` | pulse: take[] compares a return with its seed |
| input | `cp_apply` | 1 | `cp_apply` | pulse: the merge at M_fe |
| input | `mwin` | 1 | `mwin` | level: tick adds deferred |
| input | `hk_en` | 1 | `hk_en` |  |
| input | `hk_stb` | 1 | `hk_stb` |  |
| input | `hk_ret` | 192 | `hk_ret` | {f2, f1, f0, c2, c1, c0} |
| output | `aud_issue` | 1 | `aud_issue` | comb |
| output | `aud_addr` | 15 | `aud_addr` | comb: byte address (u_arb uses [14:2]) |
| input | `aud_take` | 1 | `aud_take` | comb, from u_arb |
| input | `crb_q` | 32 | `crb_q` |  |
| input | `stb_q` | 32 | `stb_q` | the return words F8-FD |
| output | `aud_a_req` | 1 | `aud_a_req` |  |
| output | `aud_a_a` | 13 | `aud_a_a` |  |
| input | `aud_a_gnt` | 1 | `aud_a_gnt` |  |
| input | `fea_q` | 32 | `fea_q` |  |
| output | `smp_req` | 1 | `smp_req` | reg: request toggle |
| output | `smp_addr` | 19 | `smp_addr` | reg |
| input | `smp_ack` | 1 | `smp_ack` | answer toggle (two clk_sys flops inside) |
| input | `smp_data` | 8 | `smp_data` |  |
| output | `amp_nx` | 8 | `amp_nx` | comb: the value amplitude holds after this edge |
| output | `ring0` | 32 | `ring0` | ring[0], to u_call |

Taps (1.7):

| Tap | W | Tap | W |
|---|---|---|---|
| `tick` | 1 | `woff` | 15 |
| `accum` | 24 | `dig_addr` | 32 |
| `counter[0:2]` | 3 × 32 | `dig_low` | 1 |
| `freq[0:2]` | 3 × 32 | `dig_ram` | 15 |
| `rc[0:2]` | 3 × 32 | `dig_smp` | 1 |
| `ring[0:5]` | 6 × 32 | `rp`, `np` | 1 each |
| `take` | 3 | `amplitude` | 8 |
| `tdef` | 1 | `dispatch` | 1 |
| `st` | 12, one-hot, `AS_*` | `al` | 2 |
| `voice` | 2 | `busy_l`, `busy_r` | 1 each |
| `ssum` | 8 | `ev_size_hi` (event), `a_tdef2` (assertion) | 1 each |
| `wsh` | 5 | | |

### 5.5 `daria_fe_call` (6; lane C)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `cart_reset` | 1 | `cart_reset` |  |
| input | `is_dpc` | 1 | `is_dpc` |  |
| input | `is_cdf` | 1 | `is_cdf` |  |
| input | `jplus` | 1 | `jplus` |  |
| input | `cdfj_entry` | 32 | `cdfj_entry` |  |
| input | `cdfj_stack` | 32 | `cdfj_stack` |  |
| input | `callfn` | 1 | `callfn` | comb pulse at C, from u_core |
| input | `cpu_ready` | 1 | `cpu_ready` |  |
| input | `ret_tog` | 1 | `ret_tog` | clk_arm domain: two clk_sys flops inside (the first FORCED) |
| input | `rel_ok` | 1 | `rel_ok` | from u_seq |
| input | `ring0` | 32 | `ring0` | from u_audio |
| input | `hk_en` | 1 | `hk_en` | bench hook; tied 0 in synthesis |
| input | `hk_stb` | 1 | `hk_stb` |  |
| output | `cl_req` | 1 | `cl_req` |  |
| output | `cl_a` | 8 | `cl_a` |  |
| output | `cl_we` | 1 | `cl_we` |  |
| output | `cl_wd` | 32 | `cl_wd` | be = F |
| input | `cl_gnt` | 1 | `cl_gnt` |  |
| output | `cp_cap` | 1 | `cp_cap` | pulse |
| output | `cp_rot` | 1 | `cp_rot` | pulse |
| output | `cp_shin` | 1 | `cp_shin` | pulse |
| output | `cp_cmp` | 1 | `cp_cmp` | pulse |
| output | `cp_apply` | 1 | `cp_apply` | pulse |
| output | `mwin` | 1 | `mwin` | level |
| output | `call_tog` | 1 | `call_tog` | reg |
| output | `arm_call_busy` | 1 | `arm_call_busy` | reg |
| output | `call_win` | 1 | `call_win` | comb from the state: RUN \| RD \| RDW \| APPLY \| HKW |

Taps (1.4, 1.7): `st` (9, one-hot, `CS_*`), `cnum` (8), `pend2`, `pend_up`, `ret_seen`, `call_busy` (the register; `arm_call_busy` is its port), `ev_rmw_call`, `ev_ret_unasked` (1 each). `ret_s1` carries `SYNCHRONIZER_IDENTIFICATION FORCED` (8.2).

### 5.6 `daria_fe_copy` (7; lane C)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `cart_reset` | 1 | `cart_reset` |  |
| input | `load_start` | 1 | `load_start` | one-clock pulse |
| input | `load_end` | 1 | `load_end` | one-clock pulse |
| input | `cart_win` | 1 | `cart_win` | bup_capture's window; its fall is c_close |
| input | `is_dpc` | 1 | `is_dpc` |  |
| input | `is_cdf` | 1 | `is_cdf` |  |
| input | `ram32` | 1 | `ram32` |  |
| input | `rel_ok` | 1 | `rel_ok` | from u_seq |
| input | `guard_on` | 1 | `guard_on` | from u_guard |
| input | `svc_pend` | 1 | `svc_pend` |  |
| input | `svc_hold` | 1 | `svc_hold` |  |
| input | `svc_fill` | 1 | `svc_fill` |  |
| input | `svc_src` | 17 | `svc_src` |  |
| input | `svc_dst` | 13 | `svc_dst` |  |
| input | `svc_rem` | 8 | `svc_rem` |  |
| input | `svc_val` | 8 | `svc_val` |  |
| input | `dma_set` | 1 | `dma_set` | comb pulse at C |
| output | `svc_take` | 1 | `svc_take` | pulse |
| output | `init_busy` | 1 | `init_busy` | reg |
| output | `arm_dma_busy` | 1 | `arm_dma_busy` | reg |
| output | `f6_act` | 1 | `f6_act` | reg |
| output | `rst_quiet` | 1 | `rst_quiet` | reg: cart_reset high for >= 8 clocks |
| output | `cp_req` | 1 | `cp_req` |  |
| output | `cp_a` | 13 | `cp_a` |  |
| output | `cp_we` | 1 | `cp_we` |  |
| output | `cp_be` | 4 | `cp_be` |  |
| output | `cp_wd` | 32 | `cp_wd` |  |
| input | `cp_gnt` | 1 | `cp_gnt` |  |
| output | `cz_req` | 1 | `cz_req` |  |
| output | `cz_a` | 8 | `cz_a` |  |
| output | `ca_req` | 1 | `ca_req` |  |
| output | `ca_a` | 13 | `ca_a` |  |
| input | `ca_gnt` | 1 | `ca_gnt` |  |
| input | `fea_q` | 32 | `fea_q` |  |

Taps (1.7): `f6_act` and `init_busy` (ports), `f6_ph` (4, one-hot, `F6_*`), `run`, `fill` (1 each), `src` (17), `dst` (13), `rem` (8), `val` (8), `dma_busy` (1; `arm_dma_busy` is its port), `a_f6_live` (assertion).

### 5.7 `daria_fe_arb` (3; lane D)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `cr_fix` | 1 | `cr_fix` |  |
| input | `cr_fix_a` | 13 | `cr_fix_a` |  |
| input | `cr_fix_we` | 1 | `cr_fix_we` |  |
| input | `cr_fix_be` | 4 | `cr_fix_be` |  |
| input | `cr_fix_wd` | 32 | `cr_fix_wd` |  |
| input | `cr_fix_use` | 1 | `cr_fix_use` |  |
| input | `cr_p32` | 1 | `cr_p32` |  |
| input | `cr_p32_a` | 13 | `cr_p32_a` |  |
| input | `cr_wb` | 1 | `cr_wb` |  |
| input | `cr_wb_a` | 13 | `cr_wb_a` |  |
| input | `cr_wb_wd` | 32 | `cr_wb_wd` |  |
| input | `cs_req` | 1 | `cs_req` |  |
| input | `cs_a` | 8 | `cs_a` |  |
| input | `cs_we` | 1 | `cs_we` |  |
| input | `cs_be` | 4 | `cs_be` |  |
| input | `cs_wd` | 32 | `cs_wd` |  |
| input | `look_req` | 1 | `look_req` |  |
| input | `look_a` | 13 | `look_a` |  |
| input | `aud_issue` | 1 | `aud_issue` |  |
| input | `aud_addr` | 15 | `aud_addr` | byte address: [14:2] is the word |
| input | `aud_a_req` | 1 | `aud_a_req` |  |
| input | `aud_a_a` | 13 | `aud_a_a` |  |
| input | `cl_req` | 1 | `cl_req` |  |
| input | `cl_a` | 8 | `cl_a` |  |
| input | `cl_we` | 1 | `cl_we` |  |
| input | `cl_wd` | 32 | `cl_wd` |  |
| input | `cp_req` | 1 | `cp_req` |  |
| input | `cp_a` | 13 | `cp_a` |  |
| input | `cp_we` | 1 | `cp_we` |  |
| input | `cp_be` | 4 | `cp_be` |  |
| input | `cp_wd` | 32 | `cp_wd` |  |
| input | `cz_req` | 1 | `cz_req` |  |
| input | `cz_a` | 8 | `cz_a` |  |
| input | `ca_req` | 1 | `ca_req` |  |
| input | `ca_a` | 13 | `ca_a` |  |
| input | `sel_up` | 1 | `sel_up` | u_core: the replica of sel_ram_sel |
| input | `guard_on` | 1 | `guard_on` | u_guard |
| input | `phb_next` | 1 | `phb_next` | u_guard |
| input | `f6_act` | 1 | `f6_act` | u_copy |
| input | `ev_short` | 1 | `ev_short` | u_seq |
| input | `k` | 8 | `k` | u_seq |
| input | `commit` | 1 | `commit` | u_seq |
| input | `op` | dec_t (38) | `op` | u_core |
| input | `p32_q` | 1 | `p32_q` | u_core |
| input | `rdP` | 1 | `rdP` | u_core |
| input | `wb_v` | 1 | `wb_v` | u_core |
| input | `ev_guard_sup` | 1 | `ev_guard_sup` | u_core |
| output | `fea_addr` | 13 | `fea_addr` |  |
| output | `crb_addr` | 13 | `crb_addr` |  |
| output | `crb_we` | 1 | `crb_we` |  |
| output | `crb_be` | 4 | `crb_be` |  |
| output | `crb_wd` | 32 | `crb_wd` |  |
| output | `stb_addr` | 8 | `stb_addr` |  |
| output | `stb_we` | 1 | `stb_we` |  |
| output | `stb_be` | 4 | `stb_be` |  |
| output | `stb_wd` | 32 | `stb_wd` |  |
| output | `aud_take` | 1 | `aud_take` |  |
| output | `p32_gnt` | 1 | `p32_gnt` |  |
| output | `wb_gnt` | 1 | `wb_gnt` |  |
| output | `cp_gnt` | 1 | `cp_gnt` |  |
| output | `cl_gnt` | 1 | `cl_gnt` |  |
| output | `look_gnt` | 1 | `look_gnt` |  |
| output | `aud_a_gnt` | 1 | `aud_a_gnt` |  |
| output | `ca_gnt` | 1 | `ca_gnt` |  |
| output | `crb_use` | 1 | `crb_use` | reg: this clock's crb_q is consumed |

Step-0 additions for the assertions (S0-9): `k` is the whole `k[7:0]` (1.4: `k[1]`, `k[3]`), and `op`, `p32_q`, `rdP`, `wb_v`, `ev_guard_sup` come from `u_core`.

Taps (1.7): `crb_use` (port), `own_r` (6), `own_s` (3), `own_a` (4) (one-hot or 0, `OR_`/`OS_`/`OA_*`), `ev_grant_steal` (event), `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr` (assertions).

### 5.8 `daria_fe_guard` (8; lane D)

| Dir | Port | W | At the top | Note |
|---|---|---|---|---|
| input | `clk_sys` | 1 | `clk_sys` |  |
| input | `clk_arm` | 1 | `clk_arm` | feeds only pd_tog |
| input | `call_win` | 1 | `call_win` | from u_call |
| input | `cpu_ready` | 1 | `cpu_ready` |  |
| output | `locked` | 1 | `locked` | reg-derived |
| output | `phb_next` | 1 | `phb_next` | reg-derived: lk & (ph == 0) |
| output | `guard_on` | 1 | `guard_on` | comb: locked & (call_win \| !cpu_ready) |

Taps (1.4, 1.7, 8.1): `locked`, `phb_next`, `guard_on` (ports), `pd_tog` (the one `clk_arm` flop), `pd_rx`, `pd_rx1`, `pd_same` (1 each), `ph` (2), `good` (4), `ev_unlock` (1). `pd_tog` and `pd_rx` keep these names for the SDC of 8.2, with the attributes of 8.1.

## 6. Decisions taken at step 0

Where the design is ambiguous or inconsistent between sections, the reading most consistent with sections 2-8 was taken. Every such decision:

| # | The design says | Frozen as | Why (design sections) |
|---|---|---|---|
| S0-1 | 1.4 lists `clk_sys` only for `daria_fe_guard` | Every clocked block (`seq`, `core`, `audio`, `call`, `copy`, `arb`, `guard`) has a `clk_sys` input. `dec` has none: it is combinational | 1.4's preamble ("Every signal is `clk_sys`"); 1.5 rules 1-7; 2.1, 2.4, 5.3, 6.1, 7.1 are all `posedge clk_sys` |
| S0-2 | 1.4 has "out, taps" rows (core, audio, call, copy, guard: "1.7", or names such as `st`, `cnum`, `pd_same`, `ph`, `good`, `ev_unlock`) and "owner taps; assertion pulses" in `arb`'s outputs; 1.7 calls the taps "hierarchical and read-only; the RTL keeps these names" | **Taps are internal signals, not ports.** Each stub declares them, tied off, with frozen names and widths (section 5). A tap that is also a functional output stays a port (`k`, `c`, `ph2`, `ev_short`, `sel_up`, `op`, `p32_q`, `rdP`, `wb_v`, `ev_guard_sup`, `svc_*`, `note_*`, `f6_act`, `init_busy`, `crb_use`, `locked`, `phb_next`, `guard_on`). The guard's taps are the union of 1.4's and 1.7's | 1.7's wording; 8.1 and 2.1 give `ph`, `good`, `pd_rx`, `k`, `c`, `ph2` power-up initialisers, which an output port may not carry (BEN Q9, `run_sim.sh`); 6.1 and 5.3 write the taps as internal registers; as ports, each would need a sink at the top and could not be renamed inside a lane |
| S0-3 | 1.3's `dec_t` comment: "16 + 26 = 42 bits"; 2.4's `op` row and 4.1: 42 | `dec_t` exactly as 1.3's struct lists it: 16 + 22 = **38 bits** | The fields 1.3 lists add up to 38, and no rule in 2-8 reads a field the struct lacks. The core's FF count in 4.1 is 4 too high |
| S0-4 | 2.2: "`jplus` = r == 3; `jrev` = r >= 2" with r = `revision[1:0]`, inside the CDF block | `jplus = is_cdf & revision[1:0] == 3`, `jrev = is_cdf & revision[1]`, at the top | Every use of them is a CDF rule (2.2, 2.4, 6.1's F0/F1). The gate keeps a DPC+ image from ever reading as CDFJ+ (DPC+'s revision is 0 or 1 today: detect2600.sv:225) |
| S0-5 | 1.4's `daria_fe_dec` inputs have no `bank`; 2.2's `rom_a = base + {bank, 12'h000} + a_in[11:0]` is a `dec` output | `daria_fe_dec` input `bank[2:0]`, from the core's `bank` | 2.2 |
| S0-6 | 1.4's core inputs: `jplus`, `jrev`, `sf` only; 2.4's `pb` and `ib` differ for revision 0 (CDF0), 1 (CDF1) and 2/3 (CDFJ, CDFJ+) | `daria_fe_core` input `rev[1:0]` = `revision[1:0]` (`sf` stays as `revision[0]`) | `jplus`/`jrev` cannot tell CDF0 from CDF1 (2.4 "Data addresses"; 4.3: `pb`×4 = $6E0 / $0A0 / $098) |
| S0-7 | 2.3: "The ready flags … are cleared at every `pclk1`"; 1.4's core has no `pclk1` | `daria_fe_core` input `pclk1` | `k[0]` comes one edge after E0; in `k[0]` a stale `rdW` would change `cr_wb = wb_v & rdW` (when the previous cycle's buffer drains). 9.6's `a_pend_late` is also "at the next `pclk1`" |
| S0-8 | 1.4: "`cr_wb` (= `wb_v`)"; 3.1: "`cr_wb = wb_v & rdW` (core)"; 2.3: "The drain waits for `rdW`" | `cr_wb = wb_v & rdW` (the request); the raw `wb_v` goes to `u_arb` separately (S0-9) | 3.1 and 2.3 agree; with `cr_wb = wb_v` the short-phase drain would write W before its final value (2.3, W final @5) |
| S0-9 | 3.6's assertions in `fe_arb`: `a_wb_late = wb_v & k[1]`; `a_p32_late = k[3] & op.(cdsw\|cdsp) & !(p32_q \| rdP) & !guard_on`; `a_guard_core` = a commit in a cycle that had `ev_guard_sup` (a core event in 1.7); `a_collide` = `ev_grant_steal` in a cycle without `ev_short`. 1.4 gives `daria_fe_arb` only `k[1]`, `k[3]`, `commit`, `ev_short` for them | `daria_fe_core` outputs `op`, `p32_q`, `rdP`, `wb_v`, `ev_guard_sup`; `daria_fe_arb` inputs the same, and `k[7:0]` (the whole vector) in place of `k[1]`, `k[3]`. The assertions stay in `u_arb` | 3.6 and 1.7 put them in `u_arb`. `wb_v` cannot be recovered from `cr_wb` (`rdW` is 0 in `k[1]`), nor `p32_q`/`rdP`/`op` from anything `u_arb` sees. "In a cycle" needs a cycle boundary (`k[0]`/`k[1]`). The assertions hold their per-cycle flags in `u_arb`: that is the "assertion pulses" state 1.4 allows besides `crb_use` |
| S0-10 | 1.7 lists a core tap `p32_in`, defined nowhere in 2-8 | `p32_in` = `p32_q` (the P32 word is on `crb_q` in this clock; W takes it at this clock's end) | 2.4's `p32_q` and `rdP` rows |
| S0-11 | 1.7: `st` is "one-hot", `own_*` "one-hot per clock", `f6_ph`, `pend_c` exist; no bit order or encoding is given | The encodings of section 4, in `daria_fe_pkg` | 1.1: the package holds "dec_t, op-class encoding, constants". `fe_taps.svh` (lane E) must decode them while lanes A-D write the bodies |
| S0-12 | 1.4's port names differ from 1.2's for the same signal | At the top: core `ldx`/`ldy` = `cdf_ldx`/`cdf_ldy`; `foff_en`/`foff` = `fetch_off_en`/`fetch_off`; `sf` = `revision[0]`; audio `asz` = `audio_size_addr`, `rev` = `revision[1:0]`, `fam` = `{is_cdf, is_dpc \| is_cdf}`; core `call_busy` = `u_call`'s `arm_call_busy`; seq `a12` = `a_in[12]` | 1.4's own glosses; 5.2 for `fam`; 6.1 (`arm_call_busy = call_busy`) |
| S0-13 | F2: `rst_fe = cart_reset \| !fe_on \| scheme != scheme_q`; 2.4: "`scheme_q` is registered every clock" | Combinational at the top; `scheme_q` has power-up value 0, so `rst_fe` is high in the first clock | 2.4, 1.5 rule 7 |
| S0-14 | 1.4 lists `ph2` (seq), `rst_quiet` (copy), `crb_use` (arb), `locked` (guard) as outputs; nothing in 2-8 reads them inside `daria_fe` | Ports, wired at the top to wires only the bench reads (Verilator's UNUSEDSIGNAL waived there with a comment) | 1.4; 1.7 and BEN 6.4 read them |
| S0-15 | 1.2: `revision` is 3 bits | Bit 2 (BUS's, detect2600.sv:237) is unused; waived at the top | 1.2 |
| S0-16 | 1.1: `u_dec` lives in `u_core` | The `u_core` stub instantiates `u_dec` with every port wired (its state inputs from the core's tied-off taps); `sel_up` and `feb_addr = rom_a[14:2]` already come from `u_dec` | 1.1, 1.4, 2.2 |
| S0-17 | 1.2 "reg"/"comb" | All outputs are `output logic`, all inputs `input wire`; "reg" and "comb" stay what the RTL must make them, not a declaration | D10, BEN Q9 |
| S0-18 | 12.3: phase streams "6/6, 2/6, 4/6, 6/10, stretched, pause in either phase, held cycles"; 2.8: MARIA's 4/6 phases during reset and the BIOS, with `access` = 0 | `fe_phase_gen`: phase 1 ∈ {2, 4, 6, 6+1 … 6+`max_str`}, phase 2 ∈ {6, 10, 6+1 … 6+`max_str`}, and phase 2 of 4 only while `driver_run` = 0; `max_str` defaults to 6 | CR 15 ("stretched by up to about 6 `clk_sys`. It is never shortened"); bus.md B2 derives only phase 1 of 2 and phase 2 of 10 from the RTL, so 4 is the design's own case (2.8, 11.1 risk 4) |
| S0-19 | bus.md section 2: the address, R/W and DOR load at every E0 | `fe_phase_gen` changes `a_in`, `rw` and `d_in` only at E0, and `d_in` (= `write_DB`) at every E0, held cycles included; a held cycle keeps `a_in`, with `rw` = 1 (bus.md B7) | bus.md section 2, B7; top.sv:298-327 |
| S0-20 | 12.1: one `run_unit.sh`, `daria_ram` poisoned "in the unit benches" | Unit benches build with `-Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD` (as `run_daria.sh`); lint is the separate `-Wall` run of section 2. The poison is opt-in (`POISON=1`), so a bench is run both ways | 12.1; the default model must stay byte-identical for the existing benches |

## 7. Lint

Verilator 5.040, the command of section 2, over the package and the nine files with `daria_fe` as top.

**Result: 290 warnings, every one from a tied-off stub** (289 at step 0; the review's `u_core.dma_busy`, R-2, is the 290th). With `-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM` the run is clean (exit 0). No other warning class occurs: no UNDRIVEN, no WIDTH, no PINMISSING, no MULTIDRIVEN. `daria_fe.sv` itself has none.

| File | Warning | Count | Signals |
|---|---|---|---|
| `daria_fe_seq.sv` | UNUSEDSIGNAL | 5 | `clk_sys`, `pclk1`, `pclk0`, `access`, `a12` |
| `daria_fe_dec.sv` | UNUSEDSIGNAL | 20 | `a_in`, `rw`, `access`, `romb`, `is_dpc`, `is_cdf`, `jplus`, `jrev`, `ldx`, `ldy`, `foff_en`, `foff`, `bank`, `ff_en`, `fpend`, `fexp`, `jr`, `jexp`, `jstream`, `mode` |
| `daria_fe_core.sv` | UNUSEDSIGNAL | 42 | `clk_sys`, `rst_fe`, `rev`, `sf`, `d_in`, `pclk1`, `k`, `c`, `commit`, `ph1_open`, `ev_short`, `fea_q`, `feb_q`, `crb_q`, `stb_q`, `aud_take`, `look_gnt`, `p32_gnt`, `wb_gnt`, `guard_on`, `amp_nx`, `svc_take`, `init_busy`, `dma_busy`, `call_busy`, `dec`, `rom_a[1:0]`, `W`, `wb_a`, `p32_in`, `pend_s`, `pend_r`, `pend_c`, `rdW`, `rdS`, `rnd`, `pptr`, `wave`, `ev_tbl_alias`, `ev_rmw_svc`, `a_fpjr`, `a_pend_late` |
| `daria_fe_audio.sv` | UNUSEDSIGNAL | 57 | `clk_sys`, `cart_reset`, `pause`, `fam`, `rev`, `rom_size`, `ram32`, `asz`, `cdf_dig`, `wave0`, `wave1`, `wave2`, `note_stb`, `note_v`, `note_val`, `cp_cap`, `cp_rot`, `cp_shin`, `cp_cmp`, `cp_apply`, `mwin`, `hk_en`, `hk_stb`, `hk_ret`, `aud_take`, `crb_q`, `stb_q`, `aud_a_gnt`, `fea_q`, `smp_ack`, `smp_data`, `tick`, `accum`, `counter`, `freq`, `rc`, `ring`, `take`, `tdef`, `st`, `voice`, `ssum`, `wsh`, `woff`, `dig_addr`, `dig_low`, `dig_ram`, `dig_smp`, `rp`, `np`, `amplitude`, `dispatch`, `al`, `busy_l`, `busy_r`, `ev_size_hi`, `a_tdef2` |
| `daria_fe_call.sv` | UNUSEDSIGNAL | 23 | `clk_sys`, `cart_reset`, `is_dpc`, `is_cdf`, `jplus`, `cdfj_entry`, `cdfj_stack`, `callfn`, `cpu_ready`, `ret_tog`, `rel_ok`, `ring0`, `hk_en`, `hk_stb`, `cl_gnt`, `st`, `cnum`, `pend2`, `pend_up`, `ret_seen`, `call_busy`, `ev_rmw_call`, `ev_ret_unasked` |
| `daria_fe_copy.sv` | UNUSEDSIGNAL | 30 | `clk_sys`, `cart_reset`, `load_start`, `load_end`, `cart_win`, `is_dpc`, `is_cdf`, `ram32`, `rel_ok`, `guard_on`, `svc_pend`, `svc_hold`, `svc_fill`, `svc_src`, `svc_dst`, `svc_rem`, `svc_val`, `dma_set`, `cp_gnt`, `ca_gnt`, `fea_q`, `f6_ph`, `run`, `fill`, `src`, `dst`, `rem`, `val`, `dma_busy`, `a_f6_live` |
| `daria_fe_arb.sv` | UNUSEDSIGNAL | 57 | `clk_sys`, `cr_fix`, `cr_fix_a`, `cr_fix_we`, `cr_fix_be`, `cr_fix_wd`, `cr_fix_use`, `cr_p32`, `cr_p32_a`, `cr_wb`, `cr_wb_a`, `cr_wb_wd`, `cs_req`, `cs_a`, `cs_we`, `cs_be`, `cs_wd`, `look_req`, `look_a`, `aud_issue`, `aud_addr`, `aud_a_req`, `aud_a_a`, `cl_req`, `cl_a`, `cl_we`, `cl_wd`, `cp_req`, `cp_a`, `cp_we`, `cp_be`, `cp_wd`, `cz_req`, `cz_a`, `ca_req`, `ca_a`, `sel_up`, `guard_on`, `phb_next`, `f6_act`, `ev_short`, `k`, `commit`, `op`, `p32_q`, `rdP`, `wb_v`, `ev_guard_sup`, `own_r`, `own_s`, `own_a`, `ev_grant_steal`, `a_collide`, `a_wb_late`, `a_p32_late`, `a_guard_core`, `a_guard_wr` |
| `daria_fe_guard.sv` | UNUSEDSIGNAL | 11 | `clk_sys`, `clk_arm`, `call_win`, `cpu_ready`, `pd_tog`, `pd_rx`, `pd_rx1`, `pd_same`, `ph`, `good`, `ev_unlock` |
| `daria_fe_pkg.sv` | UNUSEDPARAM | 45 | `TICK_TH`, `TICK_WRAP`, `TICK_STEP`, `AS_IDLE`, `AS_NISS`, `AS_NCAP`, `AS_PISS`, `AS_PCAP`, `AS_SZISS`, `AS_SZCAP`, `AS_SMISS`, `AS_SMCAP`, `AS_DROUTE`, `AS_RISS`, `AS_RWAIT`, `CS_IDLE`, `CS_POST`, `CS_FLIP`, `CS_RUN`, `CS_RD`, `CS_RDW`, `CS_APPLY`, `CS_HKW`, `CS_REL`, `F6_CLR`, `F6_P1`, `F6_P2`, `F6_END`, `PC_NONE`, `PC_DSW`, `PC_DSP`, `PC_SVC`, `OR_F6`, `OR_FIX`, `OR_AUD`, `OR_P32`, `OR_WB`, `OR_COPY`, `OS_CZ`, `OS_CORE`, `OS_CALL`, `OA_F6`, `OA_LOOK`, `OA_AUD`, `OA_COPY` |
| **total** | | **290** | |

UNUSEDSIGNAL covers a stub's inputs (nothing reads them), its tied-off taps (nothing inside reads them; the bench will), and in `daria_fe_core` the outputs of the stub `u_dec` (`dec`, `rom_a[1:0]`). UNUSEDPARAM covers the package constants no stub references yet (`SCHEME_*` are used by the top).

All of them go away as the lanes fill the bodies, except where a finished block really leaves an input unused (section 10 item 3: the core's `c`, `aud_take`, `look_gnt`, `ev_short`, `call_busy`; the call's `hk_stb`; the copy's `guard_on`) or a package constant is not referenced.

## 8. Quartus

`sim/bupchip/quartus_probe/daria_fe_map.sh [TOP] [--synth | --fit]`: 5CEBA4F23C8 with `ap_core.qsf`'s synthesis and fitter settings (as `frontend_study/gen.py` copies them), every port but `clk_sys`/`clk_arm` a virtual pin, in `raetro/quartus:21.1` under Docker (`-v repo:/build`, as the other probes). `TOP` defaults to `daria_fe`; any of the eight blocks can be probed alone. Default: Analysis & Elaboration. `--synth`: Analysis & Synthesis, printing the ALM estimate, registers, block memory bits and M10K. `--fit`: synthesis, Fitter and Timing Analyzer at `clk_sys` 69.841 ns and `clk_arm` 26.190 ns (cut as asynchronous), printing ALMs needed, ALMs placed less those recoverable by dense packing (the frontend study's measure, the one 10.3's gates use), registers, M10K and the setup slack per clock. Builds go to `sim/work/bupchip/qfe/<TOP>-<mode>/`; `db/` and `incremental_db/` are deleted afterwards unless `KEEP_DB=1`. `EXTRA_SRCS` adds files (e.g. `daria_fe_audio_lean.sv`), `DEFINES` macros.

**Results on the stubs** (2026-10-07):

| Run | Result | Warnings |
|---|---|---|
| `daria_fe` (A&E) | successful, 0 errors (7 s) | 74, all 10036 ("assigned a value but never read") on the stubs' tied-off taps: core 15, audio 26, call 8, copy 9, arb 9, guard 7. None in `daria_fe.sv` or the package |
| each block alone (A&E): `daria_fe_seq`, `_dec`, `_core`, `_audio`, `_call`, `_copy`, `_arb`, `_guard` | all successful, 0 errors (7 s each) | the same 10036s: 0, 0, 15, 26, 8, 9, 9, 7 |
| `daria_fe --synth` | successful: ALM estimate 326, registers 0, block memory bits 0, M10K 0 | the 74 × 10036; 13024 with 153 × 13410 (output pins stuck at GND) |
| `daria_fe --fit` | successful (29 s): ALMs needed 327, ALMs placed − [B] 1, registers 0, M10K 0; no timing path | as `--synth`, plus 171167 (the `VIRTUAL_PIN OFF` on `clk_sys`/`clk_arm` ignored: the stubs use no clock) and 292013 (LogicLock licence) |
| `daria_fe_arb --synth`, `daria_fe_guard --fit` | successful: ALM estimate 246 (arb's virtual I/O); guard 4 needed, 0 placed − [B] | the same classes |

The ALMs of the stub builds are the virtual I/O alone (every output is stuck at GND): they are the baseline to subtract when a lane reads its block's `--synth` estimate. The fit's "ALMs placed − [B]" excludes most of it, as the study found.

## 9. Unit-bench infrastructure

### 9.1 `run_unit.sh`

```sh
sim/bupchip/daria/fe_unit/run_unit.sh [NAME ...] [+plusarg ...]     # NAME: core, tb_fe_core or tb_fe_core.sv
POISON=1 sim/bupchip/daria/fe_unit/run_unit.sh                      # with -DDARIA_RAM_POISON
```

- Runs every `tb_fe_*.sv` in `sim/bupchip/daria/fe_unit/`, or the ones named. Each lane adds its own `tb_fe_<x>.sv` and `tb_fe_<x>.f` and never edits a shared file.
- `tb_fe_<x>.f`: one path per line, relative to the repository root (upstream `src/fpga/mister/rtl/` files may be listed); `#` starts a comment; a line starting with `-` or `+` is a Verilator option (`-DNAME=1`, `+define+NAME`). The bench is added last; its top module is `tb_fe_<x>`; `fe_unit/` is on the include path.
- Verilator `--binary --timing -O2`, into `sim/work/bupchip/daria/fe_unit/obj_<x>/` (build log `obj_<x>.log`), rebuilt when a source, the `.f`, a `.svh` in `fe_unit/` or the options change. `JOBS` (default 2), `VFLAGS`, `TIMEOUT` (default 1,800 s per run), `VERILATOR`.
- Each binary runs in `sim/work/bupchip/daria/fe_unit/` (with a link `rtl` → `src/fpga/mister/rtl` for upstream's tables), output in `<x>.log`. **A bench passes iff it exits 0**: end with `$finish` on success and `$fatal` on failure. The script prints `PASS`/`FAIL` per bench and `run_unit: N of M passed`, and exits 1 if any failed.

Result today: `run_unit: 3 of 3 passed`, and `3 of 3 passed (POISON=1)` (re-run by the review from an empty `WORK`, after R-1 … R-3).

### 9.2 `phase_gen.svh`: `fe_phase_gen`

Include it once at file scope (`` `include "phase_gen.svh" ``). It is `clk_sys`-driven and makes what `daria_fe` sees from top.sv.

| Port | Dir | W | Meaning |
|---|---|---|---|
| `clk_sys` | in | 1 | |
| `run` | in | 1 | 0: no phases, the bus holds. On 1: a phase-2 remainder, then `pclk1` |
| `stall` | in | 1 | the bench's RDY low (`arm_call_stall`, e.g. the DUT's `arm_call_busy \| arm_dma_busy`) |
| `driver_run` | in | 1 | `arm_driver_run`: `access = mapper_phi2 && driver_run` |
| `ext_a`, `ext_rw`, `ext_d` | in | 13, 1, 8 | with `EXT_BUS = 1`: the next new cycle's bus |
| `pclk1`, `pclk0` | out | 1 each | registered one-clock pulses, strictly alternating |
| `mapper_phi2`, `access` | out | 1 each | comb: `pclk0 && (!stall_eff \|\| !stall_cycle_taken)`, `&& driver_run` (top.sv:316-327) |
| `a_in`, `rw`, `d_in` | out | 13, 1, 8 | load at E0 only (S0-19) |
| `pause` | out | 1 | `pause_core`: no pulse while high; the phase lasts L + the pause |
| `load` | out | 1 | comb: a new (not held) cycle's bus loads at the end of this clock (advance an `EXT_BUS` stream on it) |
| `stall_eff`, `ibusy` | out | 1 each | `stall \| ibusy`; `ibusy` is the generator's own stall |
| `held` | out | 1 | this cycle (from its E0) is a held repeat |
| `len1`, `len2` | out | 6 each | the phase lengths (pause excluded) of the cycle whose `pclk1`/`pclk0` came last |

**Legal streams.** Phase 1 of 6, 2, 4 or 6+1 … 6+`max_str`; phase 2 of 6, 10, 6+1 … 6+`max_str`, or 4 while `driver_run` is 0 (S0-18). A pause can fall anywhere inside either phase and never meets a pulse. A cycle is held iff the stall is high in its `pclk1` clock and the previous cycle was a read (bus.md B7); it re-presents the address with `rw` = 1. In a stall the first `pclk0` is shown and every later one hidden. `ibusy` rises at a write commit (`access & a_in[12] & !rw`) with probability `pg_busy`, lasts `busy_min` … `busy_max` cycles and falls only on `rel_ok = (ph2 | pclk0) & !pclk1`. The random stream is its own xorshift32, independent of `$urandom`.

**Knobs.** Parameters `SEED`, `SEED_OFS` (several generators, one seed), `MODE`, `EXT_BUS`, `USE_PLUSARGS`. Plusargs (probabilities in per mille): `+pg_seed`, `+pg_mode` (`nominal`, `mix` (default), `short`, `stretch`, `pause`, `held`, `all`), then any of `+pg_ph1_2`, `+pg_ph1_4`, `+pg_str1`, `+pg_ph2_10`, `+pg_str2`, `+pg_ph2_4`, `+pg_max_str`, `+pg_pause1`, `+pg_pause2`, `+pg_max_pause`, `+pg_busy`, `+pg_busy_min`, `+pg_busy_max`, `+pg_wr`, `+pg_a12`, `+pg_lo` (low 12 bits in $000-$07F), `+pg_hi` ($FF0-$FFF), `+pg_rep` (repeat the address), `+pg_verbose=1`.

### 9.3 `tb_fe_phasegen`: the generator's self-test

Four generators run for 400,000 `clk_sys`, each watched by `pg_check`, which restates every property independently of the generator's code: pulses alternate, one clock each, never in a pause; phase lengths in the legal sets and equal to `len1`/`len2`; the bus changes only at E0; the held rule (and never after a write); the hidden-phase rule; `access` only with `driver_run`; `ibusy` rises only at a write commit and falls only on `rel_ok`. `g1` is `g0`'s twin (same seed: equal on every clock), `g3` another seed (must differ), `g2` uses `EXT_BUS` from a counter (each value carried by exactly one new cycle, in order), the bench's own stall and `driver_run` 0. At the end every feature must have been seen.

`400000 clocks; errors g0 0, g2 0, g3 0, ext 0; twin differs 0 clocks; g3 differs from g0 in 399996`

| Feature (g0: mode `all`; g2: `EXT_BUS`, bench stall, `driver_run` 0) | Seen |
|---|---|
| g0: phase 1 of 2 | 1776 |
| g0: phase 1 of 4 | 1724 |
| g0: phase 1 of 6 | 24316 |
| g0: phase 1 stretched | 1792 |
| g0: phase 2 of 6 | 25986 |
| g0: phase 2 of 10 | 2109 |
| g0: phase 2 stretched | 1513 |
| g0: pause in phase 1 | 852 |
| g0: pause in phase 2 | 901 |
| g0: internal busy | 619 |
| g0: held cycles | 2028 |
| g0: first pclk0 of a stall | 619 |
| g0: hidden pclk0 | 2197 |
| g0: write commits | 6242 |
| g2: phase 2 of 4 (driver_run 0) | 6142 |
| g2: held cycles (bench stall) | 2074 |
| g2: hidden pclk0 (bench stall) | 2016 |
| g2: ext loads | 28515 |

g0 ran 29609 cycles; the minimum demanded for each line is 20 to 1,000.

**Mutations.** Each of eight mutants of `phase_gen.svh` fails the self-test: no hiding (`mapper_phi2 = pclk0`); a hold after a write; a pause that can meet a pulse; `ibusy` falling outside `rel_ok`; a stretch one clock too long; a held cycle with a new address; phase 2 of 4 with `driver_run`; an `EXT_BUS` cycle that skips the bench's value.

### 9.4 `DARIA_RAM_POISON` in `daria_mem.sv`

In the behavioural `daria_ram` (the `` `else `` branch of `` `ifdef ALTERA_RESERVED_QIS ``), under `` `ifdef DARIA_RAM_POISON `` (12.1):

- **(a)** after a write with a partial byte enable, that port's q in the next clock shows $A5 in the bytes not enabled;
- **(b)** a read on one port of a word the other port writes at the same time step returns $A5A5A5A5, until the reading port's next edge (also across an edge of the writing port in between). It does not depend on the order in which the two ports' blocks run. Time steps are compared as `$realtime` (review R-1): `daria_mem.sv` has no `` `timescale ``, so its `$time` counts whole nanoseconds in the benches, and edges 0.3 ns apart used to read as one time step.

**Off by default, and the default unchanged.**

- Verilator's preprocessed output (`-E -P`) of the new `daria_mem.sv` without the define is **byte-identical** to the old file's.
- `tb_daria` `SHADOW=1 WIN_KB=64` was rebuilt from the edited tree: the binary is **byte-identical** to the one built before the edit.
- Mappy, 40 frames, both binaries: "DARIA shadow: **79 calls compared, 0 differ** or halted, 0 skipped"; `daria.csv`, `frames.csv`, `slack.csv`, `summary.txt`, `zero.csv` and `calls.csv` identical, `run.log` and `report.txt` identical apart from the run name and the wall/CPU-time lines (and equal to the earlier run in `runs/shadow64/`).

**`tb_fe_rampoison`** checks the model both ways (`run_unit.sh rampoison`, and with `POISON=1`): r1 (both ports on one clock: (a) on each port, (b) in each direction, no poison at another address), r2/r3 (a fast and a slow clock with coincident edges, either port writing; the poison held over the fast port's next edge), r4/r5 (the writer's clock an NBA copy, so the reader's block runs first, the order Verilator never picks in r1-r3), and r6 (review R-1: a read 0.3 ns after, and one 0.3 ns before, the other port's write; neither is a collision). Without the define it expects the merged word and the old word. Eight mutants of the poison code (each of the four detection paths removed, rule (a) on either port removed, either stickiness removed) all fail it; the review re-ran the first six on the `$realtime` model (all fail), and the step-0 `$time` model fails r6 twice.

### 9.5 `tb_fe_stub`

`daria_fe` on `daria_mem #(.WIN_KB(32))` as atari7800_pocket will wire it (1.6), `fe_phase_gen` driving the bus with `stall = arm_call_busy | arm_dma_busy`, 1,000 clocks (CDFJ, scheme 23). It checks only what holds for the stubs and the finished design alike (`fe_oe = a_in[12]` on every clock), so it stays a smoke test of the whole tree. Since the review (R-3) it also checks, with `$bits` on hierarchical references, that every tap of design 1.7 (and the guard's and the call's 1.4 taps, `pd_tog`, `pd_rx`, `pd_rx1`) exists under its frozen name with its frozen width: a renamed tap fails the build, a resized one fails the run (both checked by mutation). It passes with and without `POISON=1`.

## 10. What looks wrong or missing in the design

Besides the decisions of section 6:

1. **`dec_t` is 38 bits, not 42** (1.3, 2.4, 4.1); 4.1's core FF count is 4 too high (S0-3).
2. **`u_copy`'s `rdl`** is 3 bits in 4.1, but 7.1 loads it with `4'd8` and counts down to 1: it needs 4 bits.
3. **Inputs with no rule**: `c`, `aud_take`, `look_gnt`, `ev_short` and `call_busy` are in 1.4's core port list, but nothing in 2.3-2.6 reads them (`p32_gnt` already contains `!aud_take`; `ev_short` is counted by the bench from `u_seq`; the post actions key on their pending flags, not on `c`). Likewise `u_call.hk_stb` (6.1 enters HKW on `ret_new`, not on `hk_stb`) and `u_copy.guard_on` (`cp_gnt` already contains `!guard_on`, 3.1). They are frozen as ports; a lane may leave them unused and waive the lint, or the lead may drop them (L-3). [review] A lane must not use `aud_take`, `look_gnt`, `p32_gnt`, `wb_gnt`, `cl_gnt`, `cp_gnt`, `ca_gnt` or `aud_a_gnt` combinationally in its own request, address or data outputs: each grant is a function of those requests (3.1-3.3), so that would close a loop (1.5 rule 1 already says "from registers or from q"). And `u_core`/`u_copy` should present their R requests raw, not gated by `guard_on`: `u_arb` suppresses them, and `a_guard_wr`/`ev_guard_sup` must see them.
4. **`rst_quiet`** (a `u_copy` output in 1.4) has no consumer outside `u_copy` (its `a_f6_live` uses it). 3.5 says F6 runs only while `rst_quiet`, which `u_copy` enforces itself.
5. **`load_start` and the latched service.** 7.1: "`load_start` aborts F6 and any service". The engine is in `u_copy` (which has `load_start`), but the latch `svc_pend` is in `u_core`, which is reset only by `rst_fe`. That is enough only if `cart_reset` is high whenever `load_start` comes (a download holds the console in reset). Lane A/C should confirm it, or `u_core` needs `load_start`. [review: settled, no port needed] atari7800_pocket's `reset` register takes `cart_download` (atari7800_pocket.sv:169-170), and `load_start` is that download's first clock, so `cart_reset` (= `effective_reset`) is high from `load_start` + 1 and `rst_fe` clears `svc_pend` and `pend_c` there; `init_busy` (set at `load_start`) blocks `svc_take` from `load_start` + 1. The one clock left is `load_start` itself: lane C must let `load_start` win over a `svc_take` in that clock (no `run` set by it), which needs nothing outside `u_copy`.
6. **`u_arb` state.** 1.5 rule 6 says `u_arb` owns no state but `crb_use`; 3.6's `a_collide` ("in a cycle without `ev_short`") and `a_guard_core` ("in a cycle that had `ev_guard_sup`") need a per-cycle flag each. Read here as part of "the assertion pulses" (1.4), and stated so in S0-9.
7. **Taps listed inconsistently between 1.4 and 1.7** (the guard's `good`/`ev_unlock` only in 1.4, `locked`/`phb_next`/`guard_on` only in 1.7; the call's `call_busy` only in 1.7; `p32_in` nowhere defined). All are frozen as the union (S0-2, S0-10).
8. **The RMW stall and the hidden fetch.** With `INC $1FF3`/`INC $105A` (CR 18, 6.4), the stall rises at the first write's C; the second write is not held (it follows a write), so its `pclk0` is the first of the stall and is shown; the opcode fetch after it is not held either (it also follows a write), but its `pclk0` is the second of the stall and is **hidden** by top.sv's rule, and so are its held repeats. Upstream's front end therefore never commits that fetch (an `LDA #` there would not arm fast fetch). `daria_fe` reproduces this by construction, since `access` comes from top.sv, and `fe_phase_gen` does too. 6.4 does not mention it; `rmw_call` and the directed test `rmw_call` (12.1) should.
9. **Phase 1 of 4** (2.8, 12.3) is not derived in bus.md: B2 shows only phase 1 of 2 and phase 2 of 10 from a misaligned reload. It is a harmless extra case for the benches.
10. **Probe numbers on virtual pins.** On the stubs, Quartus's "ALMs needed" is 327 for `daria_fe` with no logic at all (the virtual I/O). 10.3's gates (≤ 1,300 for `daria_fe`, ≤ 560 for the audio, …) should be read as "ALMs placed − [B]", the study's measure, or after subtracting the stub baseline of section 8.

## 11. Review

An independent review of step 0 (2026-10-07), before the lanes start. It checked every port of section 3 and 5 against design 1.2, 1.4, 1.5 and 1.7 and against the rules of design 2-8 that use it; the phase generator against bus.md and glue.md; and the poison model against `daria_ram` as Quartus builds it. It re-ran everything section 7-9 reports. The fixes are folded into the sections above; this section records them, what was confirmed, and what is left to the lead.

### 11.1 Fixes

| # | What was wrong | Fix |
|---|---|---|
| R-1 | **The poison model compared time steps with `$time`.** `daria_mem.sv` has no `` `timescale ``, so in the benches its `$time` is whole nanoseconds: a write on one port and a read on the other 0.3 ns apart (two time steps) read as one, and the read was poisoned. Shown with the step-0 model by a read 0.3 ns after and one 0.3 ns before the write (both $A5A5A5A5). Latent today (the stub benches' clocks never come that close), but `tb_fe_guard`-style random phases or a `clk_arm` off the VCO lattice would have produced false collisions | `realtime` records and `$realtime` comparisons in the poisoned branch only (`-1.0` "no edge yet", `-2.0` "never"). `tb_fe_rampoison` gains r6 (both orders, 0.3 ns): the step-0 model fails it twice, the new one passes, and six of the eight 9.4 mutants re-run on the new model all fail. The default model and the `ALTERA_RESERVED_QIS` branch are unchanged (Verilator `-E -P` output byte-identical to the committed file's with no define, and with `ALTERA_RESERVED_QIS` alone or with `DARIA_RAM_POISON`) |
| R-2 | **`u_core.ev_rmw_svc` (a 1.7 tap) could not be formed from `u_core`'s ports.** 9.5's `rmw_svc` is "a taken 1/2 while a service is pending or running": a taken 1/2 already means `!svc_pend`, so the condition is about `u_copy`'s engine, which `u_core` could not see | `u_core` input `dma_busy` = `u_copy.arm_dma_busy` (already a top-level net; no `u_copy` change). `ev_rmw_svc` = `dma_set & dma_busy` (pre-edge at C). `arm_dma_busy` is high whenever a service is pending or running (it is set at the same C and falls only when `!svc_hold & !run`), plus its D3 tail to the next `rel_ok`; see L-1 for why the tail belongs in the class. The only port change of the review |
| R-3 | **Nothing kept the tap names frozen.** The stubs declared every tap (a scratch bench reading all of 1.7 by hierarchical name compiled and found every width right), but no bench in the tree referenced them, so a lane could rename one unseen | `tb_fe_stub` checks every 1.7 tap, the guard's 1.4/8.1 taps and `op`'s width (`$bits(dec_t)`, 38) by hierarchical `$bits`. Mutation: a renamed tap stops the build (`Can't find definition`), a resized one fails the run |
| R-4 | Section 10 incomplete: `u_core.c`, `u_call.hk_stb` and `u_copy.guard_on` also have no reading rule; nothing said that a grant must not feed its own requester's request combinationally, or that the core's and the copy engine's R requests must reach `u_arb` ungated by `guard_on` (else `a_guard_wr` and `ev_guard_sup` are blind); item 5 was left open | Section 10 items 3 and 5 (item 5 settled without a port: `cart_reset` is high from `load_start` + 1; lane C makes `load_start` win over a `svc_take` in its own clock) |

### 11.2 Confirmed (no change)

- **Producers and consumers.** Every input of every block is driven at the top (or in `u_core` for `u_dec`); every output has a consumer, except `u_seq.ph2`, `u_copy.rst_quiet`, `u_arb.crb_use` and `u_guard.locked`, which are 1.7 taps for the bench (S0-14). Every rule of 2-8 finds its inputs on its block: `rev` for `pb`/`ib` and the waveform base, `jplus`/`ldx`/`ldy`/`foff*` for the CDF predicates, `fea_q`/`feb_q` for `jok`, `pclk1` for the ready flags, `init_busy` for `look_req` and `svc_take`, `fam`/`rev`/`ram32`/`rom_size`/`asz` for the audio, `ring0`/`cdfj_*`/`jplus` for F0-F7, `cart_win`/`load_*`/`ram32` for F6, `rel_ok` for both releases. `dec_t` (38 bits) carries every field 2.3-2.4 read from `op`/`opc`; the write-group index of DPC+ writes comes from `a_in[2:0]` in the core, not from `ix` (which is `romb`'s for $028 and up).
- **Widths.** Word addresses: `cr_fix_a`, `cr_p32_a`, `cr_wb_a` (`{4'b0, wb_a}`, `pb + idx` ≤ $1F7), `cp_a`, `look_a` (its wrap past $1FFF is the case `jok`'s `rom_a < $7FFE` excludes), `ca_a`, `aud_a_a` (13); `cs_a`, `cl_a`, `cz_a` (8). Byte addresses: `aud_addr` (15), `svc_src` (17: $0C00 + $FFFF), `svc_dst` (13: ≤ $1BFF), `smp_addr` (19: ≤ 512 KB). `rom_a` reaches $7FFF (CDF bank 6) in 15 bits. `note_v` (2) holds NOTE0-2's `a[1:0] − 1`.
- **Clocks.** `clk_arm` reaches only `u_guard` (`pd_tog`). `ret_tog` and `smp_ack` enter through two `clk_sys` flops in their blocks; `smp_data` is a held bus. `cpu_ready` is `daria_ready`, two `clk_sys` flops in bupchip_pocket.sv (:173, :377), so the combinational `guard_on` into `aud_take` has no `clk_arm` path; `cart_win` is combinational from `bup_capture`'s `clk_sys` registers (bup_capture.sv:150); detect2600 runs on `clk_sys` (atari7800_pocket.sv:300-302).
- **No `clk_sdram` cone.** As 1.6 wires them, no input comes from `clk_sdram`: `d_in` is `write_DB` (the CPU's DOR register, not `read_DB`), `a_in`/`rw` are CPU registers, `access` is `mapper_phi2 && arm_driver_run` (top.sv:327, :1136) from `clk_sys` phase logic and `daria_fe`'s own registered busys, and the detect2600 results, `cart_size`, `mapper_load_*` and `ram32` (top.sv:778-783) are `clk_sys`. Pocket ties cart2600's `mapper` to 0 (atari7800_pocket.sv:1060), so `scheme` = force_bs with the override is what cart2600 runs.
- **Resets (1.5 item 7).** `u_core` gets `rst_fe` only; `u_audio`, `u_call`, `u_copy` get `cart_reset` (the sample client and the load tracking are lane-internal exceptions); `u_seq` and `u_guard` have no reset port; `u_arb`'s state (`crb_use`, the per-cycle assertion flags) needs none (the flags restart at `k[0]`). `scheme_q`'s power-up 0 makes `rst_fe` high in the first clock.
- **Request and grant (1.5, design 3).** Every owner of every port has its request, address, data and grant: R: F6 and the copy engine (`cp_*`, `cp_gnt`, with `f6_act` telling them apart for `own_r`), the core's fixed use (`cr_fix*`, always granted unless `guard_on`/`f6_act`, both seen by `u_arb`; `cr_fix_use` for `crb_use`), the audio (`aud_issue`, `aud_addr`, `aud_take`, with `sel_up`, `guard_on` and `phb_next`), P32 (`cr_p32*`, `p32_gnt`), the pointer buffer (`cr_wb*`, `wb_gnt`); S: `cz_*` (we 1, be F, data 0 fixed in `u_arb`), `cs_*` (granted unless `cz_req`, i.e. only in F6, when the core is in reset), `cl_*`/`cl_gnt`; A: `ca_*`/`ca_gnt` (F6 or the DPC+ copy), `look_*`/`look_gnt`, `aud_a_*`/`aud_a_gnt`; B: `feb_addr` straight through. The core's suppression under the guard is `fix_eff`/`p32_gnt` in `u_arb` plus `ev_guard_sup` in `u_core` (which has `guard_on`). Every assertion of 3.6 has its operands in `u_arb` (S0-9). Traced: no grant feeds back into its own request if the lanes keep 1.5 rule 1 (section 10 item 3).
- **Taps.** Every 1.7 name exists with the width section 5 gives (R-3 makes it permanent). `op.c.*` fields resolve hierarchically.
- **`fe_phase_gen` against bus.md and glue.md.** The hidden-phase logic is top.sv:320-327 term for term (`taken` cleared while the stall is low, set at `pclk0` while it is high; `mapper_phi2 = pclk0 && (!stall || !taken)`); `access = mapper_phi2 && driver_run` is cart2600.sv:247. The hold is bus.md B7 (RDY read combinationally in the `pclk1` clock; held iff it is low there and the cycle that ends was a read; a held cycle re-presents the address with RW 1); `a_in`, `rw`, `d_in` change only at E0 (bus.md section 2: AB, DOR and `wr_pin` load at `phi1_en`); a pause stops both pulses and freezes the bus (B1, B5); pulses alternate one clock each (B3). Phase 1 of 2 and phase 2 of 10 are B2's misaligned reloads; stretched phases are CR 15's handoff; phase 2 of 4 only with `driver_run` 0 is MARIA's 7800-mode phase. The `ibusy` release on `rel_ok` cannot fall in the first half of a held cycle, so glue.md 7.5's stale re-presentation never arises from the generator's own stall (it does from a bench stall that falls there, exactly as top.sv would show it). See L-5 for phase 1 of 4.
- **The poison model against `daria_ram`.** `daria_ram` instantiates `altsyncram` BIDIR_DUAL_PORT with `NEW_DATA_NO_NBE_READ` on both ports and no mixed-port read-during-write mode (so "don't care"), unregistered outputs: (a) is that port's own q in the clock after a write (the X on disabled bytes), (b) is the mixed-port case. The device's window for (b) is a few ns around the write edge, the model's exactly the write's time step; on the ÷48/÷18 lattice non-shared edges are ≥ 8.73 ns apart, so the two agree there. With one owner per port per edge, the q after a write belongs to the writer, so only a module that reads its own write's q can trip (a): 1.5 rule 3. Not modelled (L-6): a write on both ports to one word at one edge (undefined content).
- **Re-runs.** Lint: 290 warnings, all UNUSEDSIGNAL/UNUSEDPARAM of the stubs; clean with those two off. `run_unit.sh` from an empty `WORK`: 3 of 3, and 3 of 3 with `POISON=1`. Quartus (`raetro/quartus:21.1`): `daria_fe` A&E 0 errors, 74 × 10036 (as section 8; again after R-2), each of the eight blocks alone 0 errors with 0/0/15/26/8/9/9/7 × 10036, `daria_fe --synth` ALM estimate 326 and 0 registers, `daria_fe --fit` 327 needed, 1 placed − [B], no timing path, `daria_fe_guard --fit` 4 / 0. `db/` and `incremental_db/` deleted by the script.

### 11.3 For the lead

| # | Question | Review's suggestion |
|---|---|---|
| L-1 | **R-2's port and `rmw_svc`'s definition.** 9.5 says "pending or running"; R-2 counts "while `arm_dma_busy`", which adds the D3 tail (engine done in phase 1 of the second write's cycle, the stall held for `rel_ok`). That tail is where DARIA really differs from upstream: if upstream's engine has finished by then too, its busy has dipped before the second commit (and rises again only at its accept, C2+1), so `stall_cycle_taken` clears and the opcode fetch F after the second write is **shown** to the mapper; DARIA's stall stays up across C2 (`dma_set` re-sets it), `taken` is set at C2's `pclk0`, and F is **hidden**. If F is `LDA #` with fast fetch on, the operand differs (not only "the stall shape"). While the first engine still runs at C2, both stalls are up and both hide F. An exact "running" flag would need a `u_copy` output (`run`) as well | Keep R-2 (`dma_busy`), and widen 9.5's `rmw_svc` row: condition "a taken 1/2 while `arm_dma_busy`", effect "the stall shape, and the mapper's view of the fetch after the second write". Same class (B only); the RMW store to $105A with both values 1/2 is as unlikely as glue.md's open question 6 |
| L-2 | **Fold the step-0 decisions into design.md.** 1.3's "42" is 38 (S0-3); 4.1's `rdl` needs 4 bits and the core's FF count is 4 lower; 1.4's `cr_wb (= wb_v)` is `wb_v & rdW` (S0-8); 1.4 lacks `u_dec.bank` (S0-5), `u_core.rev`, `.pclk1` (S0-6/7), the five `u_core` → `u_arb` outputs (S0-9), `u_core.dma_busy` (R-2), `clk_sys` on every clocked block (S0-1); 1.7's `p32_in` is undefined (S0-10) | Sign off S0-1 … S0-20 and R-2, and update 1.3, 1.4, 1.7, 4.1, 9.5 so the lanes read one document |
| L-3 | Inputs no rule reads (section 10 item 3: `u_core.c`, `.aud_take`, `.look_gnt`, `.ev_short`, `.call_busy`; `u_call.hk_stb`; `u_copy.guard_on`) | Keep them: synthesis removes them, and dropping them later is a port change |
| L-4 | Which number the 10.3 gates use: "ALMs needed" includes the virtual I/O (327 on the empty stubs), "ALMs placed − [B]" is the study's measure (1 on the stubs) | Gate on "ALMs placed − [B]" (section 10 item 10) |
| L-5 | `fe_phase_gen` makes phase 1 of 4 with `driver_run` 1 (presets `mix`, `short`, `all`), which bus.md B2 shows cannot happen in 2600 mode (a misaligned reload gives only 2 or 10); design 2.8 and 12.3 ask for it | Keep it (a superset; benches that compare against upstream on the same stream are unaffected, and C = E0+4 exercises the ready rule), but a check that is only claimed for legal streams must run with `+pg_ph1_4=0` |
| L-6 | The poison model leaves a same-edge write on both ports to one word defined (whichever port's block runs last wins), where the device's content is undefined | Optional: poison the word in memory too. Today the guard (and, unlocked, the counted race) is the only protection, and no bench would see such a collision |

Not a question, a scheduling note: the stubs drive every tap with an `assign`, so lane E can develop `fe_taps.svh`'s reads against them now, but not the `fe_deposit_audio` writes (1.7's `public_flat_rw` registers), which need lane B's `u_audio` first.

**Verdict.** With R-1 … R-4 applied, the interfaces are complete and consistent with design 1.2-1.7 and 2-8: **frozen**, subject to the lead's sign-off on the review's one port change (R-2, L-1).

### 11.4 The lead's sign-off (2026-10-07)

**The interfaces are frozen** as this file records them, S0-1 … S0-20 and R-1 … R-4 included. Any later port change needs the lead's sign-off and an entry here.

| # | Decision |
|---|---|
| L-1 | Keep R-2 (`u_core.dma_busy`). 9.5's `rmw_svc` reads: condition "a taken CALLFUNCTION 1/2 while `arm_dma_busy`"; effect "the stall shape, and the mapper's view of the fetch after the second write" |
| L-2 | **This file is authoritative where it differs from design.md 1.3, 1.4, 1.7 and 4.1** (`dec_t` 38 bits, `rdl` 4 bits, the added ports). design.md says so at its top; its sections are not rewritten |
| L-3 | Keep the inputs no rule reads |
| L-4 | The 10.3 area gates are read as "ALMs placed − [B]", or "ALMs needed" less the 327 of the stub baseline |
| L-5 | Keep the generator's 4-clock phase 1; a check claimed only for legal streams runs with `+pg_ph1_4=0` |
| L-6 | Not now. No path of the design writes one word from both ports on one edge; the guard keeps the front end's writes away from the CPU's |
