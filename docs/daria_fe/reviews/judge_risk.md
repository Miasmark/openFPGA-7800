# Judge: implementation risk and completeness of the three `daria_fe` designs

**Lens.** This review asks two questions about each design:

- Does it leave decisions open, underspecified or self-contradictory?
- How hard is it to implement and debug, and where does it mishandle the hard cases?

The hard cases are resets, pause, irregular phases, RMW CALLFN, copy/fill, F6, the call port, and mode A versus mode B. Each design's quirk coverage is also cross-checked against `dpcplus.md` §14, `cdf.md` §17, `audio.md` §16, `glue.md` §11 and `critic.md`.

**Inputs read in full.**

- The eight `docs/daria_fe/spec/*.md` files.
- `docs/DARIA_CORE.md`: "Step 5 work", "The memory system, the call port and the clock crossings", "The front end", "Budget".
- `frontend_study/README.md`.
- `core/bupchip/{daria_mem,daria_call,bupchip_pocket}.sv`.
- `fe_design/{lean,exact,simple}.md`.

Upstream RTL was re-read where a claim turned on it:

- `arm_mapper_audio.sv:207-241` (dispatch snapshot, seed, merge);
- `mapper_dpcplus.sv:85-101` (service clamps);
- `top.sv:205-230, 328-395, 1105-1116` (`read_DB`, `cart_din`).

Nothing was run.

Notation as in the designs. C is the commit edge, cw/c_k are the clocks after it, M = X+1 is the merge edge, and Lch is the launch edge.

---

## 1. Scores at a glance

| Design | Score | Verdict |
|---|---|---|
| **simple** | **7.0** | Lowest implementation risk and the easiest to debug: separate datapaths, an audio replica that can be checked against upstream every clock, an atomic merge, and one arbiter with assertions. One deliberate design choice breaks D1/D3 in short-phase-1 cycles, and two spec slips need fixing. Area is moderate. |
| **lean** | **6.5** | The most careful on irregular phases (state exact for any phase 1 of 2 or more clocks) and the smallest. It is also the hardest to implement and debug: a micro-coded background engine that shares W with the front end, abort/restart blocks, and logical event ordering. AMPLITUDE can only be checked by classification, never in lockstep. It has a few unlisted AMPLITUDE cases. |
| **exact** | **6.0** | The most completely specified (full register reference) and the most exact, with every-clock oracles. It carries the largest project-level risk: the upper half of its area estimate crosses the 84% gate, and its own fallback is a different audio architecture. It stacks the most interacting exactness mechanisms. A short-phase gap and a D4 deviation remain. |

None of the three has a flaw that cannot be fixed inside its own architecture. The one item listed as fatal (simple's short-phase skip) is a deliberate rule in the design text that violates D1/D3 as written. It is cheap to replace.

---

## 2. Fatal flaws (things that, as written, would fail D1–D10)

### simple

**F-S1. A short phase 1 skips the commit's RAM and state-RAM write-backs.** (simple 2.7, `late`; 2.3 `swv`/`cwv`/`wb_v` gated by `late`; 3.1 the DSWRITE byte gated by `late`)

- **What happens.** When C < E0+6 (a 2-clock phase 1 after a misaligned TIA reload, `bus.md` B2), these are dropped:
  - DPC+ DATA/DATAW/FRACDATA counter and fraction steps;
  - PUSH/WRITE bytes and counters;
  - the CDF fetch/jump pointer updates;
  - the DSWRITE store and its pointer step.
- **Why it fails.** Upstream performs all of them. The fetcher or stream then diverges for the rest of the run, not just for that cycle's `fe_do`. D1 requires "every scheme register equal after every 6507 cycle". D3 requires work after a commit to be keyed to the commit edge. Critic 26 accepts only the `fe_do` mismatch for such cycles.
- **Also affected.** The DPC+ CALLFUNCTION 1/2 service latch at C uses `stage_*`, which are staged @4. At C = E0+2 it takes stale clamps and is not gated by `late`.
- **Reach.** RSYNC use in ARM games is unknown, and bench S1 will measure it. The directed RSYNC test of `bench.md` 7.9 would fail.
- **Fix.** Defer each write until its data is ready, as exact does (`rdy`). Or move the RMW reads after the commit, as lean's K1 does. Both fit simple's structure.

### lean

None.

### exact

None. The area risk (W-E1 below) is the closest: in the upper half of exact's own estimate it removes D10's headroom.

---

## 3. Per-design review

### 3.1 lean (Architect A)

**Strengths**

- **K1 ("reads before the commit, RMW after it") is the most robust answer to D3.**
  - Every state change is a post-commit RMW in cw1–cw3, independent of the phase-1 reads.
  - So state, RAM and events stay exact for any phase 1 of 2 or more clocks.
  - This includes the DPC+ service parameters, which are read in cw1/cw2.
  - Only `fe_do` is lost in a 2-clock phase 1, which is exactly critic 26's accepted class.
  - It is the only design that is fully exact in state for short phases.
- **Logical event ordering (K3) gives `seed_race` = `note_race` = 0, and `merge_race` = 0 in mode A,** without flip-flop counters.
  - Tick, SEED (C+1), NOTE (C+4) and MERGE (X+1) events carry a `tb` count of ticks that precede them logically.
  - The same-edge rules are encoded correctly: SEED excludes a tick at Lch; NOTE and MERGE come after a tick on their own edge.
  - The NOTE argument (an upstream NOTE capture can only be delayed by a refresh dispatched by a tick at or before C, so no later tick falls in (C+4, N_up]) is checked against `audio.md` 9.3 and holds.
- **The RMW CALLFN is handled exactly.**
  - SEED2 is staged in S0–S5 with pre-merge counters and pre-merge live frequencies.
  - MERGE1 still compares against call 1's seeds in F2–F4.
  - POST2 then copies the staging.
  - The split of live frequencies (0x1C–0x1E) from F5–F7 is the right consequence. It is a justified deviation from R10.
- **Smallest area** (≈ 910–1,110 ALMs, ≈ 545 FF): DC's budget line. Headroom is preserved (D10).
- **Free-running background (K2).** No `phi1` ring. Critics 15, 16, 21 and 22 are addressed. Pause and stretched phases give the background more clocks, not fewer.
- **The guard (D4) is the most explicit.**
  - A detector with re-anchor.
  - `bissue`, plus block-start alignment: B1 starts only at `ph == 1` so that B3's sample read lands on phase B.
  - All crb writes are blocked except F6's.
  - Front-end s1/s2 reads are suppressed.
  - Assertion counters `guard_wr_cnt` and `guard_sub_cnt`.
- **Copy/fill clamps** are tested as the counters run (`stop = ci==cnt0 | dst==0x1C00 | !fill & src≥0x8000`). This equals upstream's `min()` (checked against `mapper_dpcplus.sv:85-101`). Count 0 and the RMW service pair are handled.
- **F6** has its own enable, starts at `cap_close` or rising reset + 8, never on a falling reset, and runs the state-RAM clear in parallel.

**Weaknesses and risks**

- **W-L1. Highest implementation and debug complexity of the three.**
  - The audio thread is a micro-coded engine:
    - one-hot step `as` and job `aj`;
    - five jobs and 18 steps;
    - copy generators;
    - delayed register loads (`pld`, `sld`, `accq`);
    - a priority picker over three events with `tb` counters and a saturating `tk`.
  - It shares W and the adder with the front end.
  - Correctness rests on an abort/restart rule (a block step that is not granted, or that falls on `fe_w`, returns to its first step), on per-port claims, and on guard alignment.
  - The proofs in 3.2 are sound for the cases listed. The state space is large, though, and a failure shows up as a rare wrong counter or a saturated `tk`, not at a clock you can point to.
  - Risks 1–3 in lean's own list say the same.
- **W-L2. AMPLITUDE cannot be lockstep-checked.**
  - Its timing differs from upstream's on every tick, so every comparison goes through the bench's classifiers: `amp_lag` (A_up(n) against A_fe(m)), `amp_input_race`, `tbl_alias`, the pause classes and `amp_7800`.
  - Classification can mask a real bug once (`bench.md` §8 item 6). The bench logic grows with each class.
- **W-L3. Unlisted AMPLITUDE value differences.** Lean computes each tick's AMPLITUDE from the counters right after that tick. Upstream snapshots the counters at its dispatch edge D ≥ T+1 (`arm_mapper_audio.sv:229-233`), after any merge on an edge in [T, D−1].
  - A CDF merge on the tick edge itself (M = T) puts the tick first in lean (correct for the counters), but upstream's refresh then reads the merged counter. The same applies to a merge in (T, D) when D > T+1.
  - The same holds for a second tick coalesced before D.
  - None of these is in lean's class list (9.2). The rate is low (about 1/716 per CDF call that changes a counter), but the bench would report it as `audio_bad`.
  - **Copy/fill against audio** is also missing from lean's list. DPC+ waveforms live in the display RAM a service writes. Exact (`copy_race`) and simple (`svc_audio_race`) list it.
- **W-L4. D5 says "read 0xF8-0xFD in consecutive clocks".** Lean's MERGE job (M1/M2/M3 per voice, then CR/CW copies for the frequencies) does not do that. Logical ordering makes the physical timing irrelevant, so this is justified. It should be stated as a deviation from D5's letter.
- **W-L5. Post latency is the longest.**
  - SEED takes 6 × CR/CW after any pending tick jobs, then PF0/PF1. The flip lands at about C+16…C+30.
  - Upstream's warm call can end at X = C+15 (`glue.md` 7.3).
  - Very short calls therefore make the mode-A bench delay `ret_tog`, which gives `merge_race` and exercises the queue (lean risk 10).
  - Exact (flip ≈ C+9) and simple (≥ C+10) post before any upstream return.
- **W-L6. Small underspecifications.**
  - `tb` is 2 bits with no overflow assertion. `tk` saturates at 7, so up to 7 pending ticks are possible.
  - PARAMETER's cw1 byte enable `1<<pptr` must use the pre-commit `pptr`, which is updated at C. A latched copy is implied but not specified.
  - What `rst` means for the shared `bank` on a live scheme change.
  - The `+fe_merge_hook` path is declared unnecessary but sketched only as a force.
- **W-L7.** The FER A lookahead in s0 of every cycle, F6, the copy source and digital samples all share FER A through priorities. This is fine, but it is one more arbitration surface.

### 3.2 exact (Architect B)

**Strengths**

- **The most completely specified document.** It has:
  - a register reference with reset, load enable and data for every non-trivial register (2.6);
  - the port arbitration with the invariant `u_fe ⇒ msel`, proved per access kind (3.1);
  - a 49-row quirk table and a complete class list.
- **Every-clock oracles.**
  - A1: every `fe_audio` register against upstream's.
  - A2: `msel` against `sel_ram_sel`.
  - A3: port exclusivity.
  - A bug is localised to the clock it occurs in.
- **Exactness mechanisms are each argued tightly.**
  - The ROM mirror on FER A equals tb_daria's `cart_q`: stale in s0, refetch after a bank switch.
  - **`wbuf` drain:** at C+1 when the audio is not granted then, else at C+2. Audio grants are never consecutive, so every audio read sees the same pointer word as upstream's writeback at E0+7.8. This is a neat and correct argument.
  - **`p32`:** stream 32 in a flip-flop, so DSWRITE/DSPTR need no read outside upstream's one-clock select.
  - **Voice 0's counter merges exactly at M:** the F8 read is issued in (X−1, X].
  - **Local ROM-sample hit timing:** R+4.
  - **The orphaned `sample_busy`** is replicated.
- **Short phases.** Commits use the live decode, `jok_l` and rdy-gated post-commit writes, so state stays correct in most cases. The audio grant adds `!u_fe` for the off-window fixed reads (`short_phase1`).
- **The call side is clean.** Seeds latch at C+1 (`seed_race` = 0 with no ordering logic). The post is done by about C+9, before any upstream return. For DPC+, `pend2` reloads the seeds at M.

**Weaknesses and risks**

- **W-E1. Area is the top project risk.**
  - 1,280–1,540 ALMs and about 1,120 FF.
  - Exact's own projection: 15,300–15,830 ALMs, 82.8–85.7% of the device. The upper half crosses `BUPCHIP_CORE.md`'s 84% gate (DC "Budget": the lean projection already tops out at 83.2%).
  - D10 asks for headroom.
  - The stated fallback, "drop to the lean audio with counted `amp_lag`", replaces the largest block with a different architecture. That is a redesign, not a lever.
  - Reductions R-a to R-d save only 15–50 ALMs each.
- **W-E2. The audio clone's pseudo-RTL is in FSM `case` style.** Many registers (`woff`, `wsh`, `ssum`, `voice`, `dsamp`, `daddr`, `draddr`, `amp`) are assigned across case arms. That is the 1,343-ALM style that D10 and README §3.8 rule out. Recasting it under D10 is real work and puts the 470–560 estimate at risk. (simple shares this weakness.)
- **W-E3. The most interacting mechanisms.** Mirror port, `msel`, the fixed-slot pipeline with `rdy`/`rdyW`, `wbuf` with its yield rule, `p32` with post-call and post-F6 refresh and a release that waits for it, a 7-step interleaved merge sequencer, `pend2` per-voice seed reload, a local and remote ROM-sample engine, and the guard. AMPLITUDE exactness needs every one of them right at once. The oracles help, but bring-up will be long.
- **W-E4. RMW CDF second-call seeds are per voice** at Cv = X+1+2v. A tick in (M, Cv] makes voice 1 and 2 seeds differ from upstream's pre-merge-at-M values. This is counted as `rmw_call`, so it is not exact where lean is.
- **W-E5. A short-phase gap.** The DPC+ CALLFUNCTION 1/2 service is latched at C from `k_fill`/`k_copy`/`k_dst`, which load at E3. At C = E2 the service takes stale clamps. This is not listed in `short_phase1`.
- **W-E6. D4 deviation.**
  - D4: "daria_fe makes NO cart RAM port-B write" while the CPU may access cart RAM.
  - Exact lets a 6507-side write (DSWRITE, PUSH/WRITE) in the guard window proceed and counts `guard_wr_conflict`. Its front-end fixed reads are also not suppressed (`guard_rd_conflict`).
  - Both cases are argued unreachable, so this is harmless in practice. It still departs from the decision's wording, where lean and simple block or suppress.
- **W-E7. Small items.**
  - `fe_oe` is registered, so it lags `a_in[12]` by a clock. It is equal at the latch, but the bus differs from upstream's in s0 (`open_bus` only).
  - The PARAMETER byte enable has the same pre/post `pptr` ambiguity as lean.
  - A live scheme override leaves the DPC+ fetchers in state RAM (documented as `live_override`).

### 3.3 simple (Architect C)

**Strengths**

- **Lowest implementation risk by structure.** Six small blocks, and no datapath register shared between them:
  - the core has its own W and adder;
  - the audio has its own counters and adders;
  - `fe_arb` owns every port mux and the collision assertions (`a_collide`, `a_aux_late`, `a_wb_late`, `a_guard_core`).

  Each block can be unit-tested against its upstream counterpart (11.2 tests 1–3).
- **The audio is a clock-for-clock replica of `arm_mapper_audio`** with the grant from `sel_up`. The bench compares state, voice, grant, address, amplitude, counters and frequencies every clock (1.4 taps), so any divergence points at its first clock. Same verifiability as exact, at lower total cost.
- **The six-word ring is an elegant call datapath.**
  - It holds the payload, captured at Lch = C+1 (`seed_race` = 0).
  - It rotates out F2–F7 from a single data source.
  - It shifts returns in, forming the `take` bits against the seeds as they pass.
  - It applies an atomic merge.
  - For RMW it swaps the pre-merge counters and frequencies in with an NBA (`cp_cap` and `cp_apply` on one edge).
  - The call FSM is a plain nine-state machine.
- **D5 is followed to the letter.** Returns are read in six consecutive clocks, the merge applies on one edge, and then the release follows on `rel_ok`. In mode A the post lands before any upstream return (flip ≥ C+10 < C+15).
- **`d_in` = `write_DB`, not `cart_din`.**
  - `cart_din = RW ? read_DB : write_DB`, and `read_DB` includes `cart_DB_out` with SDRAM `rom_do` and `bios_out` (top.sv:379-393, 1112).
  - So lean's and exact's `dl <= d_in` / `mode <= d_in` registers sit at the end of a `clk_sdram`-launched path, against the spirit of D10.
  - Simple's choice removes that path at no cost (write cycles only).
- **Exact AMPLITUDE and NOTE, with costs argued** (5.1, 10.2). The P32 read and the write buffer yield to the audio. The DSWRITE byte at C and PUSH/WRITE at C+1 lie inside upstream's select windows (3.4).
- **Area is moderate:** about 1,200 ALMs (1,100–1,320), with levers ordered by their exactness cost (10.3).

**Weaknesses and risks**

- **W-S1.** The short-phase write-back skip (F-S1 above).
- **W-S2. Shared `bank`/`fpend` reset, as written, is contradictory.**
  - `rst_dpc = cart_reset | !is_dpc` and `rst_cdf = cart_reset | !is_cdf` drive two blocks that both assign the shared `bank`/`fpend`. The text says "either reset clears them".
  - Taken literally, `rst_cdf` is high for the whole of a DPC+ run, so `bank` is forced to 6 and `fpend` to 0 every clock. DPC+ banking and fast fetch would be dead, and the register would have multiple drivers.
  - The intent (reset to the active scheme's value) is clear, but the pseudo-RTL must be rewritten. Exact's single `rst_fe = cart_reset || scheme != scheme_q` is the clean form.
- **W-S3. The merge lands at M_fe = M+7 in mode A** (6.3).
  - The `merge_race` window is 7 clocks (about 1% of CDF calls that change something). It is counted and the hook removes it, but it is larger than exact's (≤ 5, and 0 for voice 0's counter) and lean's (0).
  - The RMW second payload is also taken at M+7 (`rmw_call`).
  - Simple's lever 2 (apply each word as it arrives) or exact's early F8 issue would shrink it.
- **W-S4. Underspecified short-phase port behaviour.**
  - After a commit at E0+2, the fixed `k[2]`/`k[3]` reads still run on `op`, while `sel_up` has dropped (`fpend` cleared).
  - `aud_take` has no `!core_fixed` term, so `a_collide` would fire.
  - Exact explicitly adds `!u_fe` to the grant for this case. Simple says nothing.
- **W-S5. The replica FSM is in `case` style.** It needs a D10 rewrite (as exact, W-E2).
- **W-S6. The bottom-up area estimate looks optimistic.** The replica plus ring plus snapshot plus FF counters is about 756 FF but only 480 ALMs, where exact estimates 470–560 for a comparable clone. Probe it first.
- **W-S7. `pre_lock` / 7800-mode audio class missing.**
  - On the `use_bios` path, upstream's grants before `tia_en` read the 7800 path's RAM address (`audio.md` 12.6). Exact has `pre_lock`; lean has `amp_7800`. Simple's 9.5 list does not.
  - A 7800-mode `sel_up` is not discussed either.

---

## 4. The hard cases, side by side

| Case | lean | exact | simple |
|---|---|---|---|
| **Resets** (`call_busy` ← 0, `ret_seen` ← sync, `call_tog` kept; audio reset only by `effective_reset`; F6 re-run on the rising edge + 8; never on a falling edge) | ✓ (state-RAM counters cleared by F6, with audio held in reset meanwhile) | ✓ (`rst_fe` vs audio `rst` separated correctly; orphan `rbusy` kept) | ✓ except W-S2 (shared-register reset as written) |
| **Pause** (D9) | Ticks and background run on; FF bytes; `pause_starve`/`lane`/`coalesce` counted (allowed) | Mirrored: `msel` on the frozen bus; FF bytes; lane freeze counted | Mirrored, as exact |
| **Stretched phase 1** | ✓ exact | ✓ exact | ✓ exact |
| **Phase 1 = 2 clocks** | State exact; `fe_do` counted | State exact except the CALLFUNCTION 1/2 service latch (W-E5) | **Write-backs skipped: state diverges** (F-S1); possible `a_collide` (W-S4) |
| **Phase 2 = 10; MARIA phases; BIOS path** | ✓ (free-running background; `tk` saturates; `amp_7800`) | ✓ (`pre_lock`) | ✓, except no `pre_lock` class (W-S7) |
| **Release** (D3 `in_phase2`, both busy signals) | `ph2 & !pclk1` | `(ph2\|phi2) & ~phi1` | `(ph2\|pclk0) & !pclk1` (all equivalent) |
| **RMW CALLFN** | Exact (SEED2 staging) | DPC+ exact; CDF voices 1–2 counted | Counted (`rmw_call`, payload at M+7) |
| **RMW service** | `svc2_p` queue, reused params (correct: params and counter unchanged) | `spend` clear-at-accept semantics | Engine queue through `svc_pending` |
| **Copy/fill** (D7: audio keeps its slots; clamps to $8000) | ✓; audio-vs-copy race class missing (W-L3) | ✓ (`copy_race`) | ✓ (`svc_audio_race`; the fill writes by word lanes) |
| **F6 / `init_busy`** (D6, R2) | ✓ | ✓ | ✓ (counts 64 itself; allowed by D6) |
| **Call port** (D5) | Post late (W-L5); returns not read in consecutive clocks (W-L4, justified) | ✓ | ✓ |
| **Mode A** (`call_ready` without `call_busy`; returns by call number; guard inert) | ✓ (merge exact by ordering, unless `ret_tog` has to be delayed) | ✓ (voice-0 counter at M; hook) | ✓ (hook) |
| **Mode B** | ✓ | ✓ (`guard_shift`) | ✓ |
| **Guard** (D4) | Strictest (blocks writes, suppresses fixed reads, aligns blocks) | Lets unreachable 6507 writes and reads through, with counters (W-E6) | Suppresses core requests (`ev_guard_sup`) |

---

## 5. Upstream quirks: what each design forgets

All three reproduce the core quirk lists:

- DPC+ §14 items 1–22: commit gating, the stepped random byte, zero registers, FLAG < 4, the window flag, wraps, field lanes, PUSH/WRITE addresses, data-byte arming, 6-bit registers, hotspots, FASTFETCH, PARAMETER saturation (compared as `min(·,4)`), the CALLFUNCTION priorities, clamps, source/dest/value, reset values.
- CDF Q3–Q7, Q9, Q11–Q14, Q16 and Q18: including `x7ffe` and the linear bank-end lookahead.
- Audio items 1, 7–12 and 14.
- Glue: family latched at load; re-init only on a rising edge from IDLE; DMA through pause.

The MiSTer-only `sdram.sv` quirks (CDF Q8/Q10/Q24/Q27, DPC §12.2) are correctly declared out of scope by all three (critic 9). Exact and simple reproduce tb_daria's stale s0 byte; lean does not need to.

The gaps:

| Quirk | lean | exact | simple |
|---|---|---|---|
| Refresh snapshot taken at D, after a merge or tick in [T, D) (`arm_mapper_audio.sv:229-233`) | **Missing class** (W-L3) | ✓ (`merge_race` includes a dispatch in (M, Cv]) | ✓ (atomic merge; `merge_race` includes a dispatch) |
| Audio reads during a DPC+ copy/fill (waveforms share display RAM) | **Missing class** | ✓ `copy_race` | ✓ `svc_audio_race` |
| Digital-mode switch mid-refresh, using voice 1/2's pointer with counter 0 (AUD 16.6) | `dig` latched at tick start: counted as `amp_input_race` | ✓ clone | ✓ replica |
| NOTE overlap table (AUD 9.4) | Counted `note_ovr` (unreachable) | ✓ replica | ✓ replica |
| `rom_ready` waits for an orphaned sample (G7) | ✓ (`smp_pend`) | ✓ | ✓ |
| 7800-mode / pre-lock audio address (AUD 12.6) | ✓ `amp_7800` | ✓ `pre_lock` | **Missing** (W-S7) |
| RMW launch at M with pre-merge seeds (AUD 16.18) | Exact | CDF voices 1/2 counted | Counted (M+7) |
| `ram_wr_noaccess` (critic 31) | Asserted | Asserted | Asserted |
| Live `bs_override` without a reset | Not discussed | Documented `live_override` | Not discussed |
| 29,696-byte DPC+ image (critic 25) | `dpc29k` | `img29k` | `short_image` |

---

## 6. Which design leaves what open

| Design | Open or underspecified |
|---|---|
| lean | `tb` width and overflow; PARAMETER byte-enable timing; the reset of the shared `bank` on a scheme change; the bench classifier logic it relies on (complex and not specified here); two missing AMPLITUDE classes |
| exact | The D10 rewrite of the audio clone and its real area; which reduction to take if the gate is crossed (the fallback is a different audio design); the short-phase service latch; PARAMETER byte-enable timing |
| simple | The shared-register reset (contradictory as written); short-phase port behaviour (`a_collide`); the D10 rewrite of the replica; the `pre_lock` class; an area figure that needs a probe |

---

## 7. Best ideas worth grafting into the winner

1. **lean K1: reads before the commit, RMWs after it.** It makes state exact for any phase length, including the DPC+ service parameter reads. Or, at minimum, exact's per-write `rdy` gating. Either removes simple's F-S1.
2. **simple's `d_in` = `write_DB`.** It keeps the `read_DB` / SDRAM cone out of `daria_fe` (D10). Free.
3. **exact's single front-end reset**, `rst_fe = cart_reset || scheme != scheme_q`, separate from the audio's `cart_reset`. It fixes simple's W-S2.
4. **exact's early return read.** Issue F8 in the clock where the synchronised `ret_tog` change is first seen, so voice 0's counter merges at M. Or apply each return as it arrives (simple's lever 2). This shrinks simple's 7-clock merge window to 0–5.
5. **exact's `wbuf` drain proof** (C+1 when the audio is not granted, else C+2, against upstream's E0+7.8 landing). Simple already has the same rule; keep exact's written proof as its test oracle.
6. **simple's six-word ring** for payload, return staging and the RMW swap, with `take` formed on shift-in. One data source for the post, and an atomic merge.
7. **simple's `fe_arb`**: one module owns every port mux, the registered `crb_use` tap and the collision assertions.
8. **lean's guard strictness.** Block every non-F6 crb write and suppress the front end's fixed crb reads under the guard, with the `guard_wr_cnt`/`guard_sub_cnt` counters. This matches D4's wording, where exact only counts.
9. **exact's `!u_fe` term in the audio grant**, plus the `grant_steal` assertion. It makes the short-phase case explicit (simple W-S4).
10. **exact's class list** (`pre_lock`, `copy_race`, `size_over32k`, `live_override`, `img29k`) and its register reference table as the template for the RTL review.
11. **exact's `p32` flip-flop copy** of stream 32 is an alternative to simple's yielding P32 read. It needs no read before DSWRITE/DSPTR, so it also survives a short phase 1. It costs a refresh after calls and after F6. Optional.
12. **lean's test plan items 1 and 2**: a random phase-stream unit bench with port and W-conflict assertions, and a model-based sweep of tick placement around Lch, N and M. Both are useful whatever the design.
13. **lean's state-RAM-resident audio** as the documented area fallback: about −250 ALMs (simple lever 3). Keep it specified, so an area overrun does not become a redesign.

---

## 8. Recommendation

**Take simple as the base.** Its structure carries the least implementation risk:

- separate datapaths;
- a replica audio engine with every-clock oracles;
- an atomic merge;
- a ring-based call datapath;
- one arbiter with assertions.

Its area sits between the other two.

**Before coding, graft these:**

- **(a)** Lean's post-commit RMW scheme (or exact's `rdy` gating) for every write-back and for the CALLFUNCTION clamps, so a short phase 1 costs only `fe_do`.
- **(b)** Exact's single front-end reset.
- **(c)** Exact's early F8 issue, so the merge lands at or near M.
- **(d)** Exact's `!u_fe` grant term and its `pre_lock`/`copy_race`/`size_over32k` classes.
- **(e)** Lean's strict guard behaviour.

Keep `d_in` = `write_DB`. Rewrite the replica FSM under D10 first, and probe it alone for ALMs (README §3.8). If it overruns, fall back to lean's state-RAM audio with counted `amp_lag`, which is already specified.

Do not take exact as the base. Its upper area range crosses the 84% gate, and its exactness depends on the most mechanisms working together.

Do not take lean as the base unless area forces it. It is the hardest of the three to bring up and debug, and AMPLITUDE can never be checked in lockstep.
