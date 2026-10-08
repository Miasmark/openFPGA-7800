# Lane B: `daria_fe_audio` (DARIA step 6)

This is lane B's report for `docs/daria_fe/design.md` 12.2 step 1: the audio engine of design 5 (the exact audio of decision 9: upstream's `arm_mapper_audio` re-expressed clock for clock under D10), the quirks of 9.3, the audio taps and assertions of 1.7, its unit bench (12.3, `daria_fe_audio`, items 1-4) and its area probe (10.3). The ports are `docs/daria_fe/interfaces.md`'s, unchanged. No port request was needed.

**Status.** Built and passing. `tb_fe_audio`: 30 seeds × 3.4 million `clk_sys` with the default RAM model and the same 30 with `POISON=1`, plus one 34-million-clock run with `POISON=1`: **0 errors**. Every clock compares every register of the replica with upstream's. Only the counted classes of design 9.5 mask anything, and only while their own condition holds. Mutations: **64 of 64 caught**, plus 1 equivalent. Area: **542 ALMs** as the core will contain it (hook tied 0; "ALMs placed − [B]" less the stub's 1), within the 10.3 guide of 560. The block probed alone is 618, because the bench-only hook stays alive on virtual pins (section 6). 660 registers, +59.0 ns setup slack at 69.84 ns. No lever applied.

## 1. What is built

| File | What it is |
|---|---|
| `src/fpga/core/bupchip/daria_fe_audio.sv` | Design 5: the tick, counters and frequencies with the merge and the deferral of 5.6, the six-word ring, the replica (12 one-hot states, `daria_fe_pkg::AS_*`), AMPLITUDE and `amp_nx`, the address and request of 5.5, the sample client of 5.7, the taps of 1.7 |
| `sim/bupchip/daria/fe_unit/tb_fe_audio.{sv,f}` | The unit bench (section 2): upstream's `arm_mapper_audio` on upstream's `cart_ram_tdp`, against `daria_fe_audio` on `daria_mem` |
| `sim/bupchip/daria/fe_unit/tb_fe_audio_mut.py` | The mutation test (section 5): one build with 65 run-time-selectable mutants (`+mut=N`) |
| `sim/bupchip/daria/fe_unit/tb_fe_audio_probe.v` | The area-probe wrapper (section 6): the block with `hk_en`/`hk_stb`/`hk_ret` tied 0, as `daria_fe` is synthesised. A `.v` file, so `run_unit.sh` does not take it for a bench |

Every file is MIT and uses `` `default_nettype none `` (restored at the end). No output port has an initialiser: power-up values sit on internal registers, equal to the reset values, and `assign` statements drive the ports. The RTL is clean under interfaces.md's `-Wall` lint; every remaining warning of the `daria_fe` run belongs to another lane's file. Its waivers:

- UNUSEDSIGNAL on the two bench-only taps (`ev_size_hi`, `a_tdef2`) and on `idx[31:15]` (upstream keeps `[14:0]`);
- PROCASSINIT on the power-up values (the repository's idiom).

Quartus 21.1 gives two 10036 warnings ("assigned but never read"), on the same two taps. The 1.7 taps that `fe_deposit_audio` writes carry `/* verilator public_flat_rw */`, and so do `nv`, `nval`, `busy_l` and `busy_r`. The `tb_fe_stub` tap check passes with this body, with and without `POISON=1`.

### 1.1 The engine against upstream

Each row of design 5.3 is one register with one load enable. Where the design restates an upstream condition more narrowly, upstream's condition is kept (1.3).

| Register | Upstream (AUD) | Here |
|---|---|---|
| `accum`, `tick` | :191-199, :76 | `tick = accum >= TICK_TH`; `+TICK_WRAP` on a tick, else `+TICK_STEP` |
| `counter[v]` | :193-195, :213-219 | One adder `A + B`: A = the hook's or the ring's return when taken, else the counter; B = `freq` on an effective tick that is not taken. The merge beats a tick on its edge |
| `freq[v]` | :213-222, :248-253 | NOTE's load (`nv` = 3 writes frequency 2), the hook, or `ring[3+v]` at `cp_apply`. NOTE's load wins on a shared edge (upstream's statement order) |
| `ring[0:5]` | (CTL payload, AUD seeds) | `cp_cap` takes counters 0-2 and frequencies 0-2; `cp_rot` rotates; `cp_shin` shifts `stb_q` in at `ring[5]` |
| `take`, `tdef` | (5.6) | `take ← {stb_q ≠ ring[0], take[2:1]}` on `cp_shin & cp_cmp`. `tdef` is set by a tick inside `mwin`; `late = tdef & !mwin` adds the returned frequency at M_fe+1 |
| `rp`, `np`, `nv`, `nval` | :196, :201-205, :229-230, :254-255 | As design 5.3 |
| `rc[v]` | :231-233 | Loads at `dispatch` |
| `st` (12, one-hot) | :225-363 | The 12 next-state equations of 5.4 |
| `voice`, `ssum`, `wsh`, `dig_smp` | :234-238, :307-331, :341-342 | As 5.3; `ssum` is the 8 bits upstream uses |
| `woff` | :274-292 | The CDFJ+ window with `revision == 3`; otherwise `{3'b0, word[11:0] − $800}` |
| `dig_addr`, `dig_low`, `dig_ram` | :266-271, :335-347 | `crb_q + (rc[0] >> 13 or 21)`; the route is ROM if `dig_addr < rom_size`, else RAM if in the window, else amplitude 0 |
| `amplitude`, `amp_nx` | :317-361 | Four writers: the RAM-window nibble, `ssum + byte`, 0 (out of range), the ROM nibble. `amp_nx` = `cart_reset ? 0 : amp_we ? amp_d : amplitude` |
| `al` | `cart_ram_tdp.sv` `mapper_read_lane` | `a_d[1:0]` at every edge with `pause` low (1.3, B-1) |
| `aud_issue`, `aud_addr`, `ev_size_hi` | :129-154 | The four ISSUE states; the address as AND-OR of five terms; `ev_size_hi` = SZISS with bits [16:15] of the 17-bit sum set |
| Sample client | MEM sample port | 5.7. Local (`dig_addr[31:15] == 0`): `lcnt` one-hot over (R, R+4), the A read retried in (R+1, R+2), `rdat` from `fea_q`'s lane, `rom_done` in (R+3, R+4). Remote: `smp_req` toggles at R, `smp_addr` held, `ack_s1` (FORCED) and `ack_s2`, then `rdat ← smp_data` and `rdone_q`. `busy_l`, `busy_r`, `lcnt`, the toggle and the address are not reset |

### 1.2 D10

**One load enable and at most four data sources per register:**

- counters: one adder with folded input muxes (A has 2 sources with the hook tied, 3 in simulation);
- frequencies: 3 sources;
- `ring[0:4]`: 2 sources; `ring[5]`: 3;
- `amplitude`: 3 sources and 0;
- `wsh`, `voice`, `ssum`, `dig_smp`, `rp`: 2 each.

`rdat` takes `fea_q`'s byte lane or `smp_data`. That is design 5.7's own structure, written as one five-term AND-OR (the four lanes of the port's word, and the held remote byte).

**One-hot AND-OR muxes:**

- `a_d` (five terms), `rc_sel`, `wsel`, `lane_b`;
- `amp_d`, the frequency data, the counter's A operand, `ring[5]`, `rdat`.

**Every stage registered.** Each M10K q feeds logic that ends in a register:

- `crb_q` → `woff` / `dig_addr` (adder) / `wsh` / `freq`;
- `crb_q` → byte → `ssum` / `amplitude`;
- `stb_q` → compare → `take`, and `stb_q` → `ring[5]`;
- `fea_q` → `rdat`.

Registers → `aud_addr` and `aud_a_a` → M10K address. `amp_nx` is `crb_q` → byte → `ssum + byte` → u_core's `fe_do` register: one stage.

**No grant feeds a request of its own block** (interfaces.md 10 item 3). `aud_take` goes only into `st`. `aud_a_gnt` goes only into `a_done` and `a_q`. `aud_issue`, `aud_addr` and `aud_a_req` come from registers only.

### 1.3 Deviations from the design and readings (ports unchanged)

| # | Design | Built | Why |
|---|---|---|---|
| B-1 | 5.3: `al` loads `aud_addr[1:0]` on `aud_take & !pause` | `al` loads `a_d[1:0]` at **every** edge with `pause` low | Upstream's lane register loads the port's address at every edge with `mapper_en` = `!pause`. The address is the engine's whenever the select is low, and a grant needs the select low. A paused 6507 cycle's select is what it was at the last unpaused edge (AUD 12.5). So a capture after a grant inside a pause reads upstream's lane. **`pause_lane` becomes unreachable**: 0 in every run, against 18-45 paused-grant captures per run, which would differ under 5.3's rule. Mutant 41 (5.3's rule) fails against upstream. Same cost. [Corrected, F1_fixes.md 2: reachable. The select can fall right after the last unpaused edge, at a `pclk1` or a commit, or one clock after an address or bank change, while `rom_do` still holds the byte of the clock before: the arming byte itself, the new bank's byte after a hotspot, or ROM[bank : the address of a TIA or RIOT cycle] (F1_fixes.md 2, rows 3-4); this bench freezes its select one clock before the engines see `pause`, so it cannot show that] |
| B-2 | 5.3 `woff_of`: window when `jplus_s` (`fam == 3 & rev == 3`) | Window when `rev == 3` | Upstream tests `revision == 2'd3` (AUD:281) with `family != 2`. The two differ when the family changes in the middle of a refresh (live). Mutant 23 (the design's form) fails against upstream in the `live` segment |
| B-3 | 5.5: PISS address `(rev == 0 ? $7F0 : $1B0) + 4·voice` | `$7F4` when the family is not CDF | AUD:100-102: `waveform_base = $7F4` unless `family == 3`. Reachable when `rp` was set under a non-zero family and the family is 0 at dispatch. Mutant 35 fails |
| B-4 | 5.3: `take_eff`, `hk_apply`, the frequency enable on `fam == 3` | `fam[1]` (upstream's `family >= 2`) | Equal for `fam` ∈ {0, 1, 3}, the only values the top makes |
| B-5 | 5.3: `dig_smp`, `dig_ram` enabled on `st.DROUTE & in_ram` | `st.DROUTE & !rom_lt & in_ram` | Upstream's DIGITAL_ROUTE tests `< rom_size` first. They differ only with `rom_size` above $4000_0000; the bench's `dig_edges` segment makes that case (mutant 29) |
| B-6 | 5.3: `in_ram` and the CDFJ+ window as 32-bit subtract-and-compare | Bit tests: `[31:15] == $8000`, `[14:11] != 0`, `ram32 \| [14:13] == 0` | The same sets as AUD:282-284 and :338-340, without the subtractors |
| B-7 | 4.1, 5.7 | `busy_l` is a register beside `lcnt`, as 4.1 counts it. `a_tdef2 = tick & tdef` covers both cases: a second tick inside `mwin`, and one on M_fe+1 while the late add is due | |

## 2. The bench (`tb_fe_audio`)

**Two engines on one stimulus**, with `clk_arm` = 5 × `clk_sys`, edge-aligned (mode A).

*Upstream:*

- `arm_mapper_audio` on upstream's `cart_ram_tdp` (lane register, `mapper_en = !pause`, `pause ? $FF` bytes, word data unmasked);
- a model of `arm_mapper_memory`'s sample port: `rom_ready = !sample_busy`; `sample_done` at R+3 (hit) or later (a miss, `dig_rom_lag`); for remote addresses at R+6+latency, where design 5.7's protocol puts ours;
- call edges: `call_launch` at L (and at M for an RMW's second call), `call_done` with the returns in (X, X+1).

*Ours:*

- `daria_fe_audio` on `daria_mem` (cart RAM port B, state RAM port B, front-end ROM port A; poisoned with `POISON=1`);
- mode A's grant `aud_take = aud_issue & !sel_up`;
- a k[0] lookahead on port A (random in `k[0]`, and placed on (R, R+1));
- a model of u_call's strobes (design 6.1-6.4): `cp_cap` at L, `cp_rot` on six posts F2-F7 with random S-port stalls, the F8 read in (X−1, X), `cp_shin` X+1..X+6, `cp_cmp` the first three, `mwin` (X+1, X+7), `cp_apply` at X+7 (with `cp_cap` for an RMW). The hook instead: `hk_stb` in (X, X+1) and, for an RMW, `cp_cap` there;
- the wrapper side of the sample port: an answer after a random latency of 0-60 clocks, 100-300, or 800-2,000; `smp_data` undefined until then.

**The shared stimulus:**

- **Image and cart RAM:** one random image and cart RAM, written into both RAMs. Planted pointer words cover:
  - inside the CDFJ+ window, its first and last byte, just past it, just below it;
  - 12-bit style values;
  - digital: local ROM, remote ROM, the RAM window, out of range, and the route's exact boundaries;
  - size words with every `[11:7]`, and the DPC+ frequency table.
- **Selects:** `fe_phase_gen`'s cycles (phase 1 of 2/4/6/stretched, phase 2 of 6/10/stretched, pauses, held cycles), each with a select pattern: none, phase-1 reads, until the commit, the whole cycle, or random clocks. The select is frozen from the last unpaused edge through a pause, as a frozen 6507 cycle's select is.
- **Writes:** 6507 byte stores at C under the select (the same edge into both RAMs), and clk_arm word writes through upstream's port-B arbitration (never on a shared edge; ours on the same edge).
- **NOTE strobes:** at C+1 and at random clocks, and placed on a NOTE read's grant edge g (combinational) and on g+1, covering AUD 9.4's overlap rows. Voice 3 included.
- **Other inputs:** waveforms and `cdf_dig` toggles at commits and at random clocks; live changes of `rev`, `ram32`, `asz` (including size words above 32 KB) and `rom_size` (including above $4000_0000); family changes between calls and in the middle of a refresh; resets mid-refresh, mid-call and mid-sample.
- **Calls:** random calls with random returns (each counter and frequency changed or unchanged; changed values sometimes the old value + 1), RMW second calls, and the scheduled sweeps of section 4.
- **Accumulator deposits:** the bench sometimes moves both accumulators together, so that a tick lands on a dispatch edge (AUD 9.3's re-queue) or the accumulator meets TH exactly (AUD:76's `>=`). In a natural run that happens only once per 10,000 ticks after a reset.

**Segments** (`+seg=N`):

| # | Name | Covers |
|---|---|---|
| 0 | `cdf_hook` | CDFJ+ |
| 1 | `dpc_hook` | NOTE |
| 2 | `live` | Option and family changes; starts on `size_over32k` |
| 3 | `cdf_own_sweep` | The own merge path |
| 4 | `sample` | Digital samples: latencies, orphans, k[0] |
| 5 | `exact_cdf` | No pause, no miss, **no class allowed** |
| 6 | `exact_dpc` | The same for DPC+ |
| 7 | `cdf_own_random` | The own merge path with random calls |
| 8 | `cdf_hook_sweep` | Tick at M−1..M+1 under the hook |
| 9 | `dig_edges` | The digital route's boundaries |
| 10 | `pause` | Many 1-4-clock pauses |

**Checks, at every falling edge.**

- **A1, the registers.** `accum`, `tick`, `counter[0:2]`, `freq[0:2]`, `nv`, `nval` are always compared. Under a class mask: `st` against upstream's enum (one-hot), `rc[0:2]`, `rp`, `np`, `voice`, `ssum`, `wsh`, `woff`, `dig_addr`, `dig_low`, `dig_ram`, `dig_smp`, `amplitude`, `dispatch`, `aud_issue`, `aud_addr` (when issuing), `ev_size_hi`.
- **A1, the outputs and assertions.** `amp_nx` against the next amplitude on every clock, reset clocks included. `tdef` equal to "a tick in [M+1, M_fe] of an own-path merge, until M_fe" on every clock. `a_tdef2` never.
- **The ring.** After every capture, against upstream's launch values. On each rotation, `ring0` against the next payload word. Back in place after the post. The hook's seeds against `call_seed_counter`. Under the own path, the six returns and `take` at `cp_apply`.
- **The sample client.** The local A read granted at R+1, or R+2 behind a lookahead, never later, at address `dig_addr[14:2]`. `busy_l` clear by R+4. `smp_req` toggles once per request. `smp_addr` held while `busy_r`.
- **The RAMs.** Both cart RAMs equal word for word at each segment's end.

**Counted classes.** Each is set only by its own condition. It masks the replica's registers (never the counters or frequencies) until both engines are IDLE with nothing pending, no merge window and no sample in flight. Then upstream's replica registers are deposited into ours (`fe_deposit_audio`'s rule) and the comparison resumes. The classes:

- `merge_amp`: own path, a dispatch in (M, M_fe+1];
- `dig_rom_lag`: an upstream miss on a local sample;
- `pause_lane`: a paused grant whose last unpaused edge had the select high;
- `size_over32k`: upstream's SIZE read above 32 KB;
- `rmw_call`: own path, a tick on M under an RMW. The bench checks that our capture is upstream's payload plus that tick's frequency, then deposits upstream's seeds.

The own path's counters and frequencies are masked only in (M, M_fe+1].

**Pass criterion.** No error, and every coverage minimum met (full runs only: all segments, `+scale` ≥ 100).

## 3. Results

| Run | Clocks compared | Every register compared | Replica masked by a class | Counters masked (M, M_fe+1] | Errors |
|---|---|---|---|---|---|
| seeds 1-30, default RAM model | 30 × 3.40 M | ≈ 99.7% (seed 1: 3,387,952 of 3,399,546) | ≈ 0.3% (seed 1: 11,594) | ≈ 0.1% (seed 1: 3,920) | **0** |
| seeds 1-30, `POISON=1` | 30 × 3.40 M | the same | | | **0** |
| seed 101, `POISON=1`, `+scale=1000` | 33,995,972 | 33,951,974 | 43,998 | 39,280 | **0** |

Seed 1 at `+scale=100` takes 11.5 s of CPU. Its coverage:

| What | Count |
|---|---|
| Upstream refreshes | 4,719 (DPC+ 735, CDF waveform 1,784, digital: ROM 740 / RAM window 333 / out of range 1,133) |
| CDFJ+ window pointers in the window / size words read | 987 / 4,701 |
| Grants delayed by the select | 22,648 |
| Sample bytes read in a pause ($FF) / grants on a pause's last clock | 113 / 26 |
| Ticks on a dispatch edge (re-queued) / coalesced / accumulator exactly at TH | 140 / 140 / 310 |
| Family changed mid-refresh / digital route at `rom_size` − 1 or `rom_size` / `rom_size` above $4000_0000 | 33 / 47 / 23 |
| NOTE loads / strobe at g / strobe at g+1 / voice 3 | 2,514 / 373 / 393 / 126 |
| Calls / RMW second calls (hook at M 95, own at M_fe 68, DPC+ at M 21) | 2,286 / 186 |
| Hook merges / own-path merges / hook merges with a tick on M and a changed counter | 1,547 / 560 / 50 |
| Counters returned changed / unchanged; frequencies changed / unchanged | 3,715 / 3,689; 3,816 / 3,588 |
| Ring captures / rotations / back in place / hook seeds | 2,469 / 14,808 / 2,467 / 1,546 |
| Deferred ticks (`tdef`) / late adds | 158 / 158 |
| Tick sweep T − M = −2 .. +9 × 4 return patterns | every cell 6-7 |
| Launch offsets L − T = −2 .. +2 | 89 / 83 / 75 / 88 / 91 |
| Local samples / A read at R+1 / at R+2 (k[0]) / remote / orphans / RISS waiting on a busy port | 306 / 197 / 109 / 434 / 134 / 18 |
| `merge_amp` / `dig_rom_lag` / `pause_lane` / `size_over32k` / `rmw_call` / resyncs | 184 / 57 / **0** / 901 / 4 / 520 |

In the `exact_cdf` and `exact_dpc` segments no class occurred in any run, so every register matched upstream's on every clock. `merge_amp` occurs only under the own path (the hook removes it), `dig_rom_lag` only where the bench made upstream miss, and `size_over32k` only where the bench set `audio_size_addr` + 8 above $7FFF.

## 4. Design requirements and the tests that prove them

| Requirement | Test |
|---|---|
| 12.3 item 1: every register every clock (A1), merges through the hook at upstream's M | A1 over all segments. Hook merges are exact on every clock, including the tick on M (`cdf_hook_sweep`: 50 per run with a changed counter) and the RMW capture at M (95) |
| 12.3 item 2: own merge path, tick sweep M−2 .. M_fe+3, changed and unchanged; counters and frequencies equal at M_fe+2; `merge_amp` only for dispatches in (M, M_fe+1]; `a_tdef2` 0 | `cdf_own_sweep`: 12 offsets × 4 return patterns (none, all, c0/c2/f0, c1 and the frequencies changed), each 6-7 times. Counters and frequencies compared on every clock outside (M, M_fe+1], so from M_fe+1 on. `tdef` checked every clock. `merge_amp` is the only class there and fires only at a dispatch inside the window. Random own-path calls in `cdf_own_random` |
| 12.3 item 3: ring capture at L with ticks at L−2 .. L+2; post rotation; RMW swap at M_fe and at M (DPC+) | The sweep places L at T−2 .. T+2 (75-91 each); every capture, rotation and post-return is checked. RMW at M_fe (own), at M (hook) and at M (DPC+). The own RMW with a tick on M is checked as `rmw_call` |
| 12.3 item 4: sample client: local timing with and without a k[0] conflict; the remote protocol with random latency; an orphan across `cart_reset` | A1 against upstream's hit (amplitude at R+4) with the A read at R+1 (197) and at R+2 (109). Remote against R+6+latency, latency 0-2,000. Orphans (134) whose answer comes after the next refresh's RISS (18 waits, both sides `rom_ready` low) |
| 5.2 inputs: pause bytes, words unmasked; live waveforms and digital flags; NOTE overlap rows; reset by `cart_reset` only | `pause` segment and pauses elsewhere; live changes; strobes at g and g+1; mid-run resets |
| 5.7: neither busy flag reset by `cart_reset` | Orphan runs (mutants 47, 53) |
| 9.3 quirks: tick coalescing, a tick at D re-queues, NOTE beats refresh, voice 1/2 pointer with counter 0 in digital mode, the mod-256 sum, the size shift `word[11:7]`, the digital nibble, out-of-range 0, the merge rule, the launch-and-merge on one edge | Exercised and compared (coverage above). Mutants 1, 12, 15, 17-20, 25-31, 58-61 |
| 1.5 rule 3: no q after a partial write on the same port | `POISON=1`: 6507 byte stores on cart RAM port B, poisoned q in the next clock, never consumed (0 errors) |
| 1.7 taps exist with frozen names and widths | `tb_fe_stub` passes, with and without `POISON=1` |

## 5. Mutations

`tb_fe_audio_mut.py` writes the RTL with every mutant selectable at run time, builds once with `run_unit.sh`'s options and runs the bench per mutant (default scale, seed 1): **64 of 64 caught**, plus one equivalent.

| # | Mutant | First check that fails |
|---|---|---|
| 1 | `tick` on `>` | `tick` (the accumulator at TH) |
| 2 | wrong wrap step | `accum` |
| 3 | merge does not beat a tick | `counter0` (hook, tick on M) |
| 4 | no deferral in `mwin` | ring capture (own RMW) |
| 5 | late add inside `mwin` | `tdef` |
| 6 | `tdef` never cleared | `tdef` |
| 7 | NOTE voice 3 not frequency 2 | `freq2` |
| 8 | payload: frequency 1 for 0 | ring after capture |
| 9 | rotation feeds `ring[1]` | ring after the post |
| 10 | `take` compares `ring[1]` | `take` |
| 11 | `take` shifts the wrong way | `take` |
| 12 | a tick at dispatch lost | `rp` |
| 13 | refresh pending with family 0 | `rp` |
| 14 | NCAP clears a same-edge strobe | `np` |
| 15 | refresh beats NOTE | `dispatch` |
| 16 | NOTE in any family | `st` |
| 17 | voice runs to 3 | `st` |
| 18 | sum not cleared at dispatch | `ssum` |
| 19 | size shift `word[12:8]` | `wsh` |
| 20 | shift not reset at dispatch | `wsh` |
| 21 | window from $4000_1000 | `woff` |
| 22 | window ignores `ram_size` | `woff` |
| 23 | window keyed on `jplus_s` (design 5.3) | `woff` |
| 24 | 12-bit offset not truncated | `woff` |
| 25 | digital shifts swapped | `dig_addr` |
| 26 | digital nibble bit 13 | `dig_low` |
| 27 | RAM window ignores `ram_size` | `st` |
| 28 | ROM route on `<= rom_size` | `st` (`dig_edges`) |
| 29 | RAM route before ROM | `st` (`dig_edges`) |
| 30 | digital nibbles swapped | `amplitude` |
| 31 | amplitude without the last byte | `amplitude` |
| 32 | `amp_nx` ignores `cart_reset` | `amp_nx` |
| 33 | NOTE table at $1800 | `aud_addr` |
| 34 | pointer base keyed on rev 1 | `aud_addr` |
| 35 | pointer base $7F0 outside CDF (design 5.5) | `aud_addr` |
| 36 | DPC+ index `idx[5:1]` | `aud_addr` |
| 37 | CDFJ+ mask ignores `ram_size` | `aud_addr` |
| 38 | 13-bit sample offset | `aud_addr` |
| 39 | pause does not mask bytes | `amplitude` |
| 40 | lane loads in a pause | `ssum` (`pause`) |
| 41 | lane only on grants (design 5.3) | `ssum` |
| 42 | local sample at R+3 | `st` |
| 43 | local read not retried | `amplitude` |
| 44 | local read address `[15:3]` | local A address |
| 45 | local lane 0 from `fea_q[15:8]` | `amplitude` |
| 46 | ack after one flop | `st` |
| 47 | `rom_ready` ignores `busy_r` | `st` (orphan) |
| 48 | `smp_addr` not held | `smp_addr` hold |
| 49 | apply loads counters into frequencies | `freq0` |
| 50 | hook compares the live counter | `counter1` |
| 51 | DPC+ next voice through PISS | `st` |
| 52 | size read when `asz` is 0 | `st` |
| 53 | RISS ignores `rom_ready` | `st` (orphan) |
| 54 | `ev_size_hi` from bit 16 only | `ev_size_hi` |
| 55 | ring does not shift | `ring0` |
| 56 | ring ignores `cp_shin` | ring returns |
| 57 | payload includes a tick at L | ring after capture (sweep) |
| 58 | `rc` includes a tick at dispatch | `rc0` |
| 59 | `dig_smp` set on the ROM route | `dig_smp` |
| 60 | `take` shifts six times | `take` |
| 61 | out-of-range keeps amplitude | `amplitude` |
| 62 | NOTE loads `stb_q` | `freq1` |
| 64 | lane from address bits [2:1] | `amplitude` |
| 65 | remote request not toggled | `smp_addr` hold |

63, "merge with family 1 too" (`cp_apply` without the family test), is **equivalent**: u_call raises `cp_apply` only for CDF (design 6.1: `cp_apply = st.APPLY & is_cdf`).

The first mutation run caught 51 of 64. Each miss pointed at a stimulus the bench did not make, a check it lacked, or a design rule:

- **Stimuli added:** the accumulator at TH exactly; a tick on a dispatch edge; the hook with a tick on M; the route's boundaries and `rom_size` above $4000_0000; orphans meeting the next refresh; family changes mid-refresh; grants on a pause's last clock.
- **Checks added:** `amp_nx` in reset clocks; `smp_addr` held.
- **Design rule:** B-1.

## 6. Area and timing

Quartus 21.1 Standard, 5CEBA4F23C8, `ap_core.qsf`'s settings, `daria_fe_map.sh --fit` under `flock /tmp/daria_quartus.lock`. The stub baselines are the step-0 stub (commit 8fee22a) in the same wrapper.

| Probe | ALMs needed | ALMs placed − [B] | Stub baseline (needed / placed − [B]) | L-4 measure | Registers | M10K | `clk_sys` setup slack |
|---|---|---|---|---|---|---|---|
| `daria_fe_audio` alone (hook inputs free) | 868 | 619 | 244 / 1 | **618** (624 by "needed") | 659 | 0 | +55.6 ns |
| `tb_fe_audio_probe` (hook tied 0, as in the core) | 692 | 543 | 147 / 1 | **542** (545 by "needed") | 660 | 0 | +59.0 ns |

**Reading the gate.** Design 10.1's estimate (520-580) and its gate of 560 count the block as the core contains it. Design 1.2 says the hook is "tied 0 in synthesis; constant propagation removes the hook paths". On that measure, **542 ALMs, within the guide**.

Probed alone, the block keeps the hook alive on virtual pins. That costs 76 ALMs: three 32-bit comparisons against the seeds, and a third input on 192 bits of counter and frequency muxing. In the core, `daria_fe`'s instance in `atari7800_pocket` must tie `hk_en` to a constant 0 (step 7) to get the 542.

**Levers.** Measured in scratch copies, hook tied, not applied:

| Lever | ALMs placed − [B] | Registers | Exactness |
|---|---|---|---|
| none | 543 | 660 | exact |
| 10.3 #1: `dig_addr` kept as `[19:0]` plus two flags of `[31:20]` | 533 (−10) | 650 | exact for `rom_size` ≤ 1 MB; the 32-bit `dig_addr` tap would need a new meaning |
| 10.3 #3: drop `rc` (the refresh reads the live counters) | 544 (+1) | 565 | `refresh_overlap` (counted) |

Dropping `rc` saves registers, not ALMs: the 96 flip-flops sit in ALMs that carry logic anyway. Under the owner's note of 10.3 (commit b11bbe1: "a lever is applied only if it keeps every exactness result, or if step 7's fit or timing needs it"), no lever is applied. Lever 3 should come off the list, since it buys nothing. Lever 1 is worth about 10 ALMs if step 7 ever needs them.

## 7. Open issues and notes

**For lane C (`u_call`).** The bench's model of u_call is design 6.1-6.4. `tb_fe_call` should hold `daria_fe_call` to the same contract, because the audio relies on it exactly:

- `cp_cap` is one clock: (C, C+1) for a launch; (X, X+1) for a DPC+ RMW or a hook RMW; (X+6, X+7) with `cp_apply` for a CDF RMW.
- `cp_rot` comes exactly six times, in the clocks F2-F7 are written.
- The F8 read is presented in (X−1, X), and F9-FD in the next five clocks.
- `cp_shin` is high in (X, X+1) … (X+5, X+6), with `stb_q` the matching word; `cp_cmp` on the first three.
- `mwin` is high in (X+1, X+2) … (X+6, X+7).
- `cp_apply` is high in (X+6, X+7), and only for CDF.
- With `hk_en`: no `cp_shin`, `mwin` or `cp_apply`.

**For lane D (`u_arb`).** The audio reads only `aud_take` and `aud_a_gnt`, and neither reaches its requests combinationally.

**For lane E (stage 1).**

- `al` follows B-1. With the select constant through a pause (AUD 12.5), `pause_lane` should be 0. [Corrected, F1_fixes.md 2: it is not always 0; the class stays.] If the stage-1 bench keeps the class, its condition is "a grant edge in a pause whose last unpaused edge had `sel_ram_sel` high". [Decided, F1_fixes.md 2: the stage-1 bench counts a sample capture on an unpaused edge right after such a grant edge, and only when upstream's lane register and `al` differ and each holds what it loaded at the last unpaused edge (second review); it masks only the sum and AMPLITUDE until they agree again, and any other lane difference is `audio_bad`.]
- The deposit set the unit bench uses is `rc`, `voice`, `ssum`, `wsh`, `woff`, `dig_addr`, `dig_low`, `dig_ram`, `dig_smp`, `amplitude` and `np`. `st` and `rp` are equal at the deposit by its condition.
- The 1.7 taps are registers, except `tick`, `dispatch`, `ev_size_hi` and `a_tdef2`, which are combinational.

**For the lead.**

- Tie `hk_en`, `hk_stb` and `hk_ret` to constants at step 7, so the hook's 76 ALMs go (section 6).
- Design 5.1 lists the levers as "drop `rc`, narrow `dig_addr`", while 10.3's table orders them by exactness cost (narrow first, drop `rc` third). The measurement says drop `rc` saves nothing.
- B-2, B-3 and B-5 are places where design 5.3/5.5 restate upstream's conditions too narrowly. The RTL follows upstream, and the bench shows the design's forms differ from upstream (mutants 23, 35, 29).

**Shared infrastructure (read-only to this lane).**

- `run_unit.sh` leaves the previous `$WORK/<x>.log` in place when a build fails. A script that greps the log after a FAIL (build) reads a stale result. This bit once during development. Deleting the log before the build would avoid it.
- With Verilator 5.040 `--timing`, a `continue` inside an `initial` block's `for` loop produced C++ that does not compile ("jump to label … crosses initialization"). The bench avoids it. Other benches may meet it.
- `phase_gen.svh` has no issue for this lane.

**Port requests.** None.

## 8. Reproducing

```sh
sim/bupchip/daria/fe_unit/run_unit.sh audio                         # seed 1, 3.4 M clk_sys, ~12 s
sim/bupchip/daria/fe_unit/run_unit.sh audio +seed=7 +pg_seed=7     # another seed
POISON=1 sim/bupchip/daria/fe_unit/run_unit.sh audio +scale=1000   # 34 M clk_sys
sim/bupchip/daria/fe_unit/run_unit.sh audio +seg=3                 # one segment (coverage minimums off)
sim/bupchip/daria/fe_unit/tb_fe_audio_mut.py                        # 65 mutants, ~10 min
flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh daria_fe_audio --fit
EXTRA_SRCS=sim/bupchip/daria/fe_unit/tb_fe_audio_probe.v \
  flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh tb_fe_audio_probe --fit
```
