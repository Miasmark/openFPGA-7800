# Lane A: `daria_fe_seq`, `daria_fe_dec`, `daria_fe_core` (DARIA step 6)

This is lane A's report for `docs/daria_fe/design.md` 12.2 step 1: the sequencer (2.1), the decode (2.2) and the core (2.2-2.6, 4.1, the DPC+ and CDF quirks of 9.1-9.2, the core's taps and assertions of 1.7/3.6), and their unit benches (12.3). The ports are `docs/daria_fe/interfaces.md`'s, unchanged. No port request was needed.

**Status.** Built and passing. `tb_fe_seq`: 2 runs × 9 streams × 10^7 clocks, every check 0. `tb_fe_core`: 12 runs (seeds 11-19, 21-23; 3 of them, 3.8 million cycles, with `POISON=1`), **15,992,532 6507 cycles** in 555 epochs, every bad count 0, each scheme and revision over 2.3 million cycles: DPC+ sf0 2,857,696, sf1 2,504,765; CDF0 2,610,004; CDF1 2,952,893; CDFJ 2,347,548; CDFJ+ 2,719,626. Mutations: 41 of 41 caught. Area: core + dec 590 ALMs (design 10.1: 470-530; 10.3 gate ≤ 500: **over by 90**), 298 registers, +57 ns slack.

## 1. What is built

| File | What it is |
|---|---|
| `src/fpga/core/bupchip/daria_fe_seq.sv` | 2.1 verbatim: `k`, `c`, `ph2` on power-up-initialised internal registers (no reset, 1.5 rule 7), `commit`, `ph1_open`, `rel_ok`, `ev_short` combinational |
| `src/fpga/core/bupchip/daria_fe_dec.sv` | 2.2: the DPC+ decode (mapper_dpcplus.sv:112-181) and the CDF decode (mapper_cdf.sv:77-157) on the live `romb` and state; `sel_up`; the one-hot op class (DPC+ classes only with `is_dpc`, CDF only with `is_cdf`); `rom_a` |
| `src/fpga/core/bupchip/daria_fe_core.sv` | 2.2-2.6: the mirror (`feb_addr`, `lane_q`, `romb`), the jump lookahead (`jok` in `k[1]` from `{fea_q, feb_q}`), the op latch and `opc`, W and its adder with the one-hot `Bv`, `fe_do`, the scheme state (kind 1), the at-commit actions under the ready rule (kind 2: DSWRITE, DSPTR, the service latch; `pend_c`), the post writes (kind 3: `pend_s`, `pend_r`), the pointer buffer, the P32 read, the S, R-fixed and A requests, the NOTE/waveform/mode outputs, the events and assertions of 1.7 |
| `sim/bupchip/daria/fe_unit/tb_fe_seq.{sv,f}` | the sequencer's unit bench (section 2.1 below) |
| `sim/bupchip/daria/fe_unit/tb_fe_core.{sv,f}` | the core's unit bench against upstream (section 2.2) |
| `sim/bupchip/daria/fe_unit/tb_fe_core_mut.sh` | the mutation check of both benches (section 4) |

Every file is MIT, `` `default_nettype none `` (restored at the end), no output-port initialiser. The three RTL files are clean under the lint command of interfaces.md section 2 (`-Wall`): every remaining warning of that run belongs to another lane's stub. The waivers in lane A's files are UNUSEDSIGNAL on the inputs no rule reads (`c`, `ev_short`, `aud_take`, `look_gnt`, `call_busy`, `k[7:5]`, `fea_q[31:16]`; interfaces.md 10 item 3, L-3), on the bench-only taps, on `mode[7:4]` in `u_dec`, and on two partly used intermediates; and PROCASSINIT on the sequencer's power-up values (the repository's idiom).

### 1.1 D10

- **One load enable and at most four data sources per register.** W: `crb_q`, `stb_q`, `W + Bv`, `shf`, AND-OR on `ld_crb`/`ld_stb`/`ld_add`/`ld_shf`. `fe_do`: the k[1] byte, the flag, the RAM byte, `amp_nx`, AND-OR on `fd_k1`/`fd_flg`/`fd_ram`/`use_amp`. `rnd`: per byte `rnd_next`, `rnd_prior`, the constant, `d_in`. `jr`: `jr − 1`, 2, 0. `jexp`, `jstream`, `wb_a`, `pptr`: two. `sw_a`/`sw_be`: AND-OR of three or four class terms. The bench checks every clock that no two selects of W, `Bv`, `fe_do`, `cr_fix` or `cs_*` are high together (`src` = 0 in every run).
- **AND-OR one-hot muxes** for `cr_fix_a`/`cr_fix_be` (five sources), `cs_a` (three), `Bv` (seven), W, `fe_do`. The two byte-lane selects (`romb`, the RAM byte) and the lookahead bytes stay 2-bit binary selects of a registered lane: a 4:1 byte mux on a 2-bit select is one 6-LUT per bit, an AND-OR on a one-hot lane would be two.
- **Every stage registered.** Each request address or data output is logic from registers or M10K q: `feb_q → romb → decode → pb + idx → cr_fix_a`; `crb_q → data_addr → cr_fix_a`; `stb_q → data address / w0[p2 & 7] → cr_fix_a / cs_a`; `W → dsw_addr → cr_fix_a`. No grant feeds a request of its own block (interfaces.md 10 item 3): `p32_gnt` and `wb_gnt` go only into registers (`p32_q`, `p32_got`, `wb_v`), and `aud_take`/`look_gnt` are not read.

### 1.2 Readings of the design (no change of behaviour)

| # | Where | Reading |
|---|---|---|
| A-1 | 2.4 `jr` | The four-way if/else-if is written as load enable `rdC & (cjmp \| !c_sub)` and data `cjmp ? jr − 1 : (arm_j ? 2 : 0)`. Equal: without a substitution, "cancel on the expected address", "arm", "cancel elsewhere" and "unchanged at 0" collapse to `arm_j ? 2 : 0`; on `cfet`/amplitude the register keeps its value (and is 0 there anyway: `fpend` and `jr ≠ 0` are exclusive, `a_fpjr`) |
| A-2 | 2.4 `fexp`, `jr`, `jexp`, `jstream` | Their loads are gated with `is_cdf`. `jok` is formed in every scheme's `k[1]` (the lookahead read is CDF-only, `look_req`), so in DPC+ it can be 1 on a stale `fea_q`; without the gate a DPC+ `$4C` would load CDF registers that `rst_fe` clears at the next switch anyway. Invisible in DPC+, but the CDF state then stays at its reset values exactly as upstream's held-in-reset mapper_cdf |
| A-3 | 2.4 `fpend` (CDF) | `c_sub` = `opc.(cfet \| cjmp \| amp)` with the amplitude class taken only with `is_cdf` (the DPC+ amplitude class shares the field) |
| A-4 | 2.3, 7.3, F4 | The service latch fires per 2.3's `rdS` rule: `rdS` loads at E0+4 with `cnt_st`, so a commit at C = E0+2 or E0+4 latches at E0+5 (the first edge with `rdS` high before it), and C ≥ E0+6 latches at C. F4's and 7.3's "max(C, E0+4)" is that rule written one edge early: `cnt_st` (counter[p2 & 7]) is not available before E0+4's q. Exact against upstream's fields in every short-phase case the bench made (section 3) |
| A-5 | 2.5 PARAMETER | The S post write happens iff `pptr < 4` before C (params 4-7 are never read); `pptr` itself counts to 8, as upstream's |
| A-6 | 2.5 field rows | `din`'s lanes are derived from the post word: lane 0 is $00 on w1 (FRACLOW with `sf`, FRACINC), lane 1 takes `{0, d[3:0]}` on w0 (HI), lane 2 on w1 (FRACHI), word $10 takes `din` in every lane; `sw_d` selects W (DATA, DATAW, FRACDATA, PUSH, WRITE) |
| A-7 | 2.3 DSWRITE | `cr_fix_we` is 1 for the DSWRITE byte: it is requested only by `act_dsw`, i.e. in the C clock (where `access` = `commit` = 1) or deferred. `cr_fix_wd` = `{4{d}}` with `d` = `d_in` in a commit clock and `din` otherwise (PUSH/WRITE's post byte, a deferred DSWRITE) |
| A-8 | interfaces.md 11.2 | The DPC+ write group's fetcher index is `a_in[2:0]` (the S read of PUSH/WRITE in `k[1]`, the post word), not `ix` (which is `romb`'s for $028 and up) |
| A-9 | 1.4 `cs_be` | `cs_be` = $F on the core's reads (the byte enable of a read is a don't-care) |

## 2. The benches

Both run under `run_unit.sh` (Verilator 5.040, `--binary --timing -O2`), with and without `POISON=1`, and pass iff they exit 0.

### 2.1 `tb_fe_seq` (design 12.3, `daria_fe_seq`)

Nine `fe_phase_gen` streams run side by side, one per preset (`mix`, `all`, `short`, `stretch`, `pause`, `held`, `nominal`, `all` with `pg_ph1_4 = 0`, i.e. legal streams only per L-5, and a mutant stream), each with its own `daria_fe_seq` and an independent reference: the bench counts edges since the last `pclk1` and since the last commit (saturating) and remembers the last pulse.

| Requirement | Check |
|---|---|
| `k`, `c`, `ph2` for random phase streams | every clock: `k == 1 << min(edges since E0, 7)`, `c == 1 << min(edges since C, 3)`, `ph2` == "the last pulse was `pclk0`"; the power-up values 80/8/0 before the first edge |
| `rel_ok` never true at a `pclk1` edge and always true from the `pclk0` edge to the next `pclk1` | every clock: 0 in the `pclk1` clock, 1 in the `pclk0` clock and in every clock after it up to the next `pclk1` clock, 0 inside phase 1; pauses in both phases included |
| `ph1_open`, `commit` | `ph1_open` exactly from the clock after the `pclk1` clock to the clock before the `pclk0` clock; `commit == access & a_in[12]` |
| `ev_short` exactly when C < E0+6 | at every commit, against the edge count |
| a model 6507 whose busy is released only on `rel_ok` never commits a held address twice | the bench drives the generator's stall with its own busy, which rises at random write commits (a CALLFN or a service) and falls only at an edge with the DUT's `rel_ok`; every newly loaded cycle gets an id, its held repeats keep it, a second commit of an id is an error. The mutant stream lets its busy fall at any edge: it must show double commits, which proves the check can see them |

### 2.2 `tb_fe_core` (design 12.3, `daria_fe_dec` + `daria_fe_core`)

**Upstream side** (MIT RTL from `src/fpga/mister/rtl/`): `mapper_dpcplus`, `mapper_cdf`, `arm_mapper_tables`, `cdf_fastjump_table` (and `cache_ram.v`), wired as cart2600 wires them (reset `cart_reset || scheme != X`, `table_*` from `cdf_table_index`, `sys_pointer_write = cdf_pu && is_cdf`, the map queried at `mapper_cdf.rom_a[14:0]`), on tb_daria's 1-clock ROM (`rom_q <= img[rom_a]` every clock) and a bench model of cart2600's port A and `cart_ram_tdp`: the address mux (`sel_ram_sel ? sel_ram_a : audio`), registered word and lane (lane only while `!pause`), $FF on pause, the write strobe `sel & !rw & !phi1 & !address_change & !access_taken` (`access_taken` from `mapper_phi2`), and the pointer writeback landing between C+1 and C+2 (CDF §14.3).

**DARIA side**: `daria_fe_seq` + `daria_fe_core` (+ `u_dec`) on `daria_mem #(32)`, with the scheme decode and `rst_fe` copied from `daria_fe.sv`, through a bench-local reduced `daria_fe_arb` that is design 3.1-3.3 without F6 and the copy engine and with the guard off (`fix_eff = cr_fix`; `aud_take`, `p32_gnt`, `wb_gnt`, the S and A priorities as written there). The audio is a random requester (ISSUE until granted, one CAPTURE clock, a random gap; addresses biased to the pointer and increment tables), and so are the sample client (A) and the call port (S, reads and writes of F0-FD). Both sides share one amplitude (`amp_nx` = the value upstream's `amplitude` takes at the end of the clock). A random taker clears upstream's `service_pending` and DARIA's `svc_pend` in one clock. The inputs no rule reads (`aud_take`, `look_gnt`, `call_busy`) and `guard_on` (only `ev_guard_sup` reads it) are driven at random, so the run also shows the core's requests and state do not depend on them (interfaces.md 10 item 3: the requests reach `u_arb` raw).

**Stimulus.** One `fe_phase_gen` (all presets via `+pg_mode`) carries a program-like stream from the bench: 52% "the next byte" (so `LDA #`, `LDX #`/`LDY #` and `JMP` operands follow their opcodes), TIA/RIOT accesses (A12 = 0, neither arming nor disarming), the scheme's registers with meaningful values (FASTFETCH 0, SETMODE with a zero low nibble, CALLFUNCTION 0/1/2/FE/FF, PARAMETER, field writes, PUSH/WRITE, RRESET/RWRITE/NOTE, WAVEFORM; DSWRITE, DSPTR, SETMODE, CALLFN), hotspots (reads and writes), jumps (to anywhere, to $xFF0-$xFFF, onto the arming opcode planted before each window's hotspots), repeated addresses, write bursts (RMW, pushes: the third write of a stall is hidden, so upstream strobes PUSH/WRITE without a commit). Each epoch has a new random 32 KB image dense in `$A9`/`$A2`/`$A0` + operand (in range of the epoch's offset, the amplitude operand, out of range, $27/$28 for DPC+) and `$4C o1 o2` (o1 0/1/other, o2 0/other), `$4C` at every layout's bank ends ($xFFD-$xFFF), arming opcodes right before the hotspots; random cart RAM (pointer and increment tables included); the map built by `cdf_fastjump_table` from the image through its load port; the state RAM cleared (F6). `+only=all` rotates through ten configurations (DPC+ sf 0/1, CDF0/1/J/J+ with and without the fetch offset; LDX/LDY each 75%); `+only=cdf` through eight. Every epoch has one event, in turn: a console reset in the middle of a cycle (driver off, F6 emulated by reloading both RAMs and the tables and clearing the state RAM), a live scheme switch in a `pclk1` clock (DPC+ ↔ CDF), a 7800-mode interval (`driver_run` 0), a non-ARM scheme interval (CDF only: DPC+ fetchers would be `live_override`), or none.

| 12.3 item | Check (counter in the run summary) |
|---|---|
| 1 | `sel_up == sel_ram_sel` on every clock, every scheme, reset, switch, 7800 and non-ARM interval included (`a2`). `aud_take` == upstream's `ram_grant` on every clock; the only allowed difference is `ev_grant_steal` in a cycle with C < E0+6 (`grant`; classified `grant_steal`) |
| 2 | `fe_do` == upstream's byte (`flags[0] ? d_out : rom_do`) at every `pclk0` of a read with A12, shown or hidden, while the 6507 runs (`dout`, `dout_hidden`); cycles with C < E0+6 are counted (`short_phase1`), not failed. Added: `fe_do` holds the latched byte from C until the next E0+2 (`hold`, 2.4's note) |
| 3 | at every `pclk1`, by the scheme the cycle ran: DPC+ top, bottom, counter, fractional, increment of all eight fetchers from the state RAM words (masks of 4.2), params 0-3 from word $10, `pptr` = `parameter_pointer`, waveforms, LFSR, bank, fast fetch, fast pending, service pending; CDF bank, mode, fast pending and expected address, jump remaining, expected address, jump stream (`state`). Short phases are compared like any other cycle. Q26 is classified at the commit (upstream's `table_index` differs from the index registered at the previous edge; the bench fails a Q26 outside a short cycle) and its pointer word repaired from upstream at the next `pclk1` |
| 4 | at every `pclk1`, every cart RAM word either side wrote in the cycle; all 8,192 words every 2,048 cycles and at each epoch's end (`ram`). Each pointer write lands at C+1 or C+2 for C ≥ E0+6 (`land`; histogram). Every DARIA audio read returns upstream's word at the same grant edge (`aud`): the wbuf proof of 3.4 checked on every grant |
| 5 | `u_core.jok` == `cdf_fastjump_table`'s bit in every CDF `k[1]` (`jok`), and the whole map against `byte[a] == $4C & byte[a+1][7:1] == 0 & byte[a+2] == 0 & a < $7FFE` after every load (`jmap`) |
| 6 | no fixed R use outside `sel_up` in a cycle with C ≥ E0+6 (`fix`); `a_collide` (`grant` above), `a_wb_late`, `a_p32_late` (both formed here as 3.6 writes them), `a_pend_late`, `a_fpjr` (`assert`) |
| 7 | at each rise of `svc_pend`: fill, source, destination, value and upstream's clamped count formed from `svc_rem` by `min()` (7.3), against upstream's `service_*` (`svc`); `dma_set` and `callfn` one clock before upstream's `service_pending`/`call_pending` rise (`dma`, `call`); `note_*` against `audio_note_*` and waveforms every clock (`note`, `wave`); `cdf_dig` against `digital_audio` every clock (`dig`) |
| 8 | one clock after every `rst_fe` clock (console reset, scheme switch, non-ARM scheme), every core register at its 2.4 reset value for the scheme then selected (`rst`), and the state compare of item 3 at the next `pclk1` |

**Classified, counted and repaired, never failed**: `short_phase1` (C < E0+6: `fe_do`, `grant_steal`, audio reads in the cycle), `q26`, `tbl_alias` (a CDFJ+ DSWRITE into the tables: upstream's table cache is resynced from RAM at the next `pclk1`, as the ARM would rewrite it), `ram_wr_noaccess` (an upstream PUSH/WRITE strobe in a cycle without a commit: DARIA's word is resynced). In a cycle with a console reset the state compare, `fix`, `a_wb_late` and `a_p32_late` are skipped (the 6507 and upstream's audio are in reset; see O-1).

## 3. Results

### 3.1 `tb_fe_seq`

`run_unit.sh seq +seq_clocks=10000000` with `+seq_seed=1`, and with `+seq_seed=2` and `POISON=1`: both PASS. Seed 1, per stream (10^7 clocks each):

| Stream | Cycles | Commits (C < E0+6) | Held cycles | Errors (k, c, ph2, rel_ok, ph1_open, commit, ev_short, double, power-up) |
|---|---|---|---|---|
| mix | 810,904 | 616,301 (18,302) | 113,526 | all 0 |
| all | 739,106 | 544,387 (63,117) | 121,822 | all 0 |
| short | 909,362 | 690,458 (276,604) | 127,702 | all 0 |
| stretch | 735,077 | 558,519 (0) | 103,127 | all 0 |
| pause (61,991 / 62,353 pauses in phase 1 / 2) | 621,091 | 471,682 (0) | 87,960 | all 0 |
| held | 833,334 | 459,529 (0) | 289,107 | all 0 |
| nominal | 833,334 | 647,481 (0) | 102,793 | all 0 |
| legal (no phase 1 of 4, L-5) | 733,144 | 539,247 (31,628) | 121,170 | all 0 |
| **mutant** (busy falls at any edge) | 833,333 | 480,742 | 289,882 | **14,661 double commits** (required > 0) |

Phase lengths seen over the streams: phase 1 of 2 238,432, of 4 238,613, of 6 3,964,343, stretched 207,484; phase 2 of 6 4,297,973, of 10 177,000, stretched 173,901. Every busy fell on `rel_ok` and no held cycle committed. (Seed 2: the same, mutant 14,431 double commits.)

### 3.2 `tb_fe_core`

| Run | Seed | `+only` | `+pg_mode` | Cycles | POISON |
|---|---|---|---|---|---|
| c01 | 11 | dpc | mix | 1,200,000 | 0 |
| c02 | 12 | dpc | all | 1,200,000 | 0 |
| c03 | 13 | cdf | mix | 2,400,000 | 0 |
| c04 | 14 | cdf | all | 2,400,000 | 0 |
| c05 | 15 | all | stretch | 1,000,000 | 0 |
| c06 | 16 | all | held | 1,000,000 | 0 |
| c07 | 17 | all | nominal | 1,000,000 | 0 |
| c08 | 18 | all | all, `+pg_ph1_4=0` (legal streams) | 1,000,000 | 0 |
| c09 | 19 | all | pause | 1,000,000 | 0 |
| c10 | 21 | all | mix | 2,000,000 | 1 |
| c11 | 22 | dpc | short | 600,000 | 1 |
| c12 | 23 | cdf | short | 1,200,000 | 1 |

(Each run counts one extra cycle per epoch: the bus stops in `k[0]` of the cycle after the last.) **Every bad counter is 0 in every run**: `hold`, `a2`, `grant`, `dout`, `dout_hidden`, `state`, `ram`, `land`, `aud`, `jok`, `jmap`, `fix`, `assert`, `svc`, `dma`, `call`, `note`, `wave`, `dig`, `src`, `alias`, `misc`. Totals over the twelve runs:

| | Count |
|---|---|
| commits | 14,011,699 (11,200,834 reads, 2,810,865 writes) |
| latches compared (`pclk0` of a read with A12) | 11,837,014, of them 641,685 hidden |
| state compares (item 3) | 15,991,975 (8,580 skipped: a console reset inside the cycle) |
| held cycles | 648,449 (3 commits in them, each at cycle 0 of an epoch: `fe_phase_gen` resumes with its own `ibusy` left high from the stopped epoch; the same on both sides) |
| pause clocks / stretched cycles / phase 1 of 2 / of 4 | 10,863,246 / 587,434 / 718,905 / 660,681 |
| commits by op class | rom 10,154,061; rrnd 117,387; amp 23,242; rdat 333,988; rflg 98,717; dfld 216,282; dpw 167,480; dpar 33,506; dcf 27,106; dmisc 95,913; cfet 358,437; cjmp 109,497; cdsw 507,000; cdsp 394,176; cmode 337,579; ccall 336,694; hotspot switches 1,783,708 |
| edges of the image | substituted reads at a hotspot address 77,889; jump operands at $xFFE/$xFFF 19,632; `jok` set at $xFFD-$xFFF 32,954 |
| audio grants (each checked against upstream's grant and word) | 33,980,587 |
| pointer writes | 1,369,110: at C+1 660,981, at C+2 593,786, in short cycles 114,343 (never anywhere else) |
| `jok` compares in CDF `k[1]` | 10,630,152 (367,119 set); `jmap`: 555 maps × 32,768 addresses |
| services latched | 12,857 (1,204 deferred: C < E0+6); DSWRITE/DSPTR deferred 45,257; P32 read retried in `k[2]` 151,242 |
| NOTE strobes / `cdf_dig` clocks / full RAM compares | 15,785 / 8,470,593 / 7,805 |
| `rst_fe` clocks / reset-value checks | console reset 3,721, scheme switch 179, non-ARM scheme 102,211 / 106,111 |
| epoch events | console reset 111, live switch 111, 7800 mode 111, non-ARM scheme 68 |
| **classified** | `short_phase1` cycles 1,206,855 (`fe_do` 502,969, `grant_steal` 15,890, audio words 344); `q26` 18,707 (18,694 words repaired); `tbl_alias` 1,010; `ram_wr_noaccess` 34,503 words; `a_p32_late`'s formula true after a reset inside a DSWRITE/DSPTR cycle 26 (O-1) |

Q26 occurred only in short cycles (the bench fails one outside them). The exactness claims of design 0.2 for this block therefore hold on these streams: `fe_do` exact at every latch with C ≥ E0+6 (stretched phases, pauses, held repeats and hidden `pclk0` included), every scheme register exact after every cycle including short ones (DPC+ exact; CDF exact except Q26), cart RAM exact after every cycle, every audio read returning upstream's word, `sel_up` exact on every clock.

## 4. Mutations

`tb_fe_core_mut.sh` edits a copy of one RTL file per mutant, builds the bench named with it on the copy, and runs it (`tb_fe_core`: 200,000 cycles, one turn of the ten-configuration rotation, `+formula=0`, i.e. with the checks that only restate an RTL port formula switched off, so a mutant must be caught by behaviour against upstream or by the bench's own invariants; `tb_fe_seq`: 600,000 clocks per stream).

**41 of 41 caught** (`runs_A/mut_final.log`). The first failure each mutant produced:

| Id | Mutant | Caught by |
|---|---|---|
| s1 | `rel_ok` without `!pclk1` | `tb_fe_seq`: double commits, `rel_ok` |
| s2 | `ev_short` true at C = E0+6 | `ev_short` against the edge count |
| s3 | `ph1_open` high in the `pclk0` clock | `tb_fe_seq` `ph1_open` |
| s4 | `c` does not saturate | `tb_fe_seq` `c` |
| d1 | CDF hotspot on a substituted read (Q9) | state: bank |
| d2 | CDFJ jump operand 1 of $01 rejected | A2 |
| d3 | fetch-offset range one short | `fe_do` |
| d4 | DPC+ fast-fetch register range `<= $28` | state: bank (the operand on a hotspot) |
| d5 | DSWRITE select not `access`-gated | A2 |
| d6 | amplitude operand ignores the offset | A2 |
| d7 | DPC+ write select covers HI | A2 |
| d8 | CDFJ+ ROM base $1000 | `fe_do` |
| d9 | HI writes dropped | state: counter |
| c1 | pointer write before W is final | ram (pointer word) |
| c2 | S post write before W is final | state: counter |
| c3 | FRACLOW ignores `stable_fractional` | state: fractional |
| c4 | DSWRITE pointer slot 33 | ram |
| c5 | `jok` at $7FFE/$7FFF (Q18) | `jok` |
| c6 | AMPLITUDE not reloaded every edge | `fe_do` |
| c7 | DATAW without the window flag | `fe_do` |
| c8 | PARAMETER pointer saturating at 4 | state: `pptr` |
| c9 | CALLFUNCTION reads w1[p2] for the counter | svc fields |
| c10 | RANDOM0PRIOR returns the next value | `fe_do` |
| c11 | DPC+ fast fetch arms without FASTFETCH | state: `fpend` |
| c12 | jump stream reloaded on operand 2 | state: `jstream` |
| c13 | CDFJ+ increment shifted by 12 | ram (pointer word) |
| c14 | ready flags not cleared at E0 | ram |
| c15 | DSWRITE not waiting for P32 (F1) | ram |
| c16 | FRACDATA addressed by the counter | `fe_do` |
| c17 | lookahead reads the same word | `jok` |
| c18 | W never takes P32 | ram |
| c19 | mirror lane not registered (the stale byte) | A2 |
| c20 | CDFJ+ FF4/FFB bank 6 | state: bank |
| c21 | NOTE voice `a[1:0]` | note |
| c22 | CALLFN on $FC/$FD | `callfn` |
| c23 | service count from p2 | svc fields |
| c24 | no P32 retry in `k[2]` | `a_p32_late` |
| c25 | jump operand address not advanced | A2 |
| c26 | params 4-7 written into word $10 | state: params |
| c27 | service latch at C regardless of `rdS` (F4) | svc fields |
| c28 | window flag from the wrong word | `fe_do` |

One earlier entry was replaced: "`jr` reloaded on a fast-fetch commit" is an equivalent mutant (O-6), so c25 is now "jump operand address not advanced". d3, d4, d6, d8, c3, c13 and c20 first survived a 150,000-cycle run of randomly drawn schemes; that led to the fixed rotation of configurations, the $27/$28 DPC+ operands and the jumps onto the arming opcodes planted before the hotspots, after which all were caught.

No RTL bug was found while the benches were brought up: every failure on the way was the bench's own (a table base read before its `always_comb` settled, the model strobing a frozen bus between epochs, compare ordering against same-edge repairs, a reference that gated `digital_audio` by the new scheme in a switch clock, checks not masked under a mid-cycle reset), except O-1, which is the design's. The mutation results above are the evidence that the benches can see errors of the kinds the design guards against.

## 5. Area and timing

`flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_core --fit` (5CEBA4F23C8, ap_core.qsf's settings, virtual pins, `clk_sys` 69.841 ns):

| | Measured | Design |
|---|---|---|
| ALMs needed | 853 | |
| the core's own virtual I/O (the step-0 stub core, renamed, same script) | 263 | interfaces.md L-4's 327 is `daria_fe`'s |
| **core + dec: ALMs needed − stub** | **590** | 10.1: core 400-460 + dec 70 = 470-530; 10.3 gate ≤ 500 |
| ALMs placed − [B] (the study's measure) | 590 (`daria_fe_core` 507, `u_dec` 83) | |
| registers | 298 | 4.1: ~312, less 4 for `dec_t` (S0-3) |
| M10K | 0 | 0 |
| worst setup slack, `clk_sys` | +56.98 ns (worst path about 12.9 ns) | 10.4: about +40 ns |

**The block is 90 ALMs (18%) over its 10.3 gate** and 60-120 over 10.1's estimate; the decode alone is 83 against 70. The design's estimate is "simple's core with its own W, adder and B (the hardware judge's 480-540, including the decode)". Nothing in the RTL is outside the design's register list (298 FFs against ~308), and Quartus removed the bench-only taps (the 10036 warnings name exactly `p32_in`, `rdS`, `ev_tbl_alias`, `ev_rmw_svc`, `a_fpjr`, `a_pend_late`). No lever was taken: every candidate changes a frozen port's meaning or a timing the design fixes, and the gate is the lead's decision at integration (12.2 step 2). Candidates, for the lead:

- `svc_src`/`svc_dst` carry the $0C00 offset (two adders, 17 and 13 bits, about 15 ALMs [E]); `u_copy` could add it (a change of the ports' meaning, lanes A and C);
- the `cs_wd` mux (32 × 2:1, W or `din`'s lanes) could move into `u_arb`'s S data mux, which already has the call port's word (about 16 ALMs [E]; the core would export W and the lane word separately: a port change).

The probe's `db/` is deleted by the script; the stub probe's sources and build were removed afterwards.

## 6. Open issues and observations

| # | Issue |
|---|---|
| O-1 | **`a_p32_late` (lane D's assertion) can fire under a console reset.** The core resets `rdP`/`p32_q` on `rst_fe` (2.4); a `cart_reset` that lands between `k[1]` and `k[3]` of a DSWRITE/DSPTR cycle then makes 3.6's `k[3] & op.(cdsw\|cdsp) & !(p32_q \| rdP) & !guard_on` true (seen 26 times in the 15.99 million cycles of section 3). The 6507 is in reset, so it is harmless, but mode A's `+hard_reset_at` (12.2 step 7) could hit it. `u_arb` has no reset input, so it cannot mask it today; the bench classifies it. Options for the lead: count it as a reset artifact in `fe_shadow.svh`, give `u_arb` a reset-in-cycle flag (a port), or keep `rdP` through `rst_fe` (a change of 2.4's reset column). Lane D / lead |
| O-2 | **Area over the gate** (section 5) |
| O-3 | **A live scheme switch between `k[1]` and the cycle's last post action is not exact.** `op` has no reset (2.4), so a commit after a switch in that window acts on the old scheme's op class (e.g. a CDF pointer write while DPC+ is selected), and `rst_fe` cancels pending post actions. That is inside 9.5's `live_override` (an OSD override without a reload); the bench switches in a `pclk1` clock, where everything is exact (A2 included) |
| O-4 | `ram_wr_noaccess` (an upstream-side assertion in 9.6) is reachable in random streams: a third write in a stall is hidden by top.sv's rule, and upstream's PUSH/WRITE strobe is not access-gated (DPC §14.10). The bench classifies and resyncs it (34,503 words in section 3); in the full system it needs a hidden write cycle with a DPC+ PUSH/WRITE address, which 9.6 expects never to see |
| O-5 | `d_in` versus `din` in the post and deferred actions is not observable in any bench: `write_DB` loads only at E0, and every post action fires before the next E0. The RTL uses `din` as the design says |
| O-6 | Equivalent mutant noted while building the mutation list: leaving `jr` to be reloaded on a fast-fetch commit changes nothing, because `fpend` and `jr ≠ 0` are exclusive (`a_fpjr`), so a fast fetch always meets `jr` = 0 |
| O-7 | The guard path of the core is only `ev_guard_sup` (checked as a formula with a random `guard_on` while the reduced arb keeps the guard off, which also shows that no request is gated by it); its suppression, parking and `a_guard_*` are `u_arb`'s and lane D's |
| O-8 | `fe_phase_gen` keeps its own `ibusy` across `run` = 0. A bench that stops and restarts the generator mid-busy gets a held first cycle whose `pclk0` is shown (3 commits "in a held cycle" in section 3, all at an epoch's cycle 0). Harmless for any bench comparing two sides on one stream; a note for the generator's owner (lane E) |
| O-9 | Not covered by this unit bench by construction: calls (the ring, `u_call`), the copy/fill engine (`svc_take` is a random taker), F6, the audio's values. They are lanes B-D's benches and mode A's |

## 7. Reproducing

```sh
sim/bupchip/daria/fe_unit/run_unit.sh seq core                       # defaults: 3e6 clocks/stream; 200,000 cycles
POISON=1 sim/bupchip/daria/fe_unit/run_unit.sh seq core
sim/bupchip/daria/fe_unit/run_unit.sh seq +seq_clocks=10000000 +seq_seed=1
sim/bupchip/daria/fe_unit/run_unit.sh core +only=cdf +seed=13 +pg_seed=13 +cycles=2400000 +epoch=30000   # one row of 3.2
sim/bupchip/daria/fe_unit/tb_fe_core_mut.sh                          # section 4 (about 10 minutes)
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_core --fit
```

`tb_fe_core` debug aids: `+stop=N` (failures printed with context), `+trace_from=N +trace_to=M` (one line per clock), `+events=0`, `+formula=0`. `tb_fe_stub` (the step-0 tap check: every 1.7 tap under its frozen name and width) passes with lane A's bodies in the tree. Logs of the runs above: `sim/work/bupchip/daria/fe_unit/runs_A/`.
