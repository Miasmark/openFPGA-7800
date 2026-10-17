# Judge (exactness and verifiability): lean, exact, simple

**Lens.** I checked whether each design matches upstream at every compared point of D1 in mode A. I re-read the timing tables against `dpcplus.md`, `cdf.md`, `audio.md`, `bus.md`, `glue.md` and the upstream RTL, and I looked for concrete cycles where a design would give a different `d_out`, state, RAM byte, payload or tick value. I also judged three things:

- how well each design supports the mode-A shadow, the directed tests and the random differential bench;
- how many differences it must classify;
- how cleanly those differences can be classified.

Area matters here only where it threatens exactness, because a forced fallback would give exactness back.

**Read, in full:** the eight `docs/daria_fe/spec/*.md` files, the three designs, the requested `DARIA_CORE.md` sections, the study README and `daria_fe3.sv`, `daria_mem.sv`, `daria_call.sv`, and `bupchip_pocket.sv` (DARIA ports).

**Upstream RTL I re-read for this review:**

- `tb_daria.sv:124-129` and `:198`: the 1-clock ROM;
- `top.sv:255-335`: reset, stall, `mapper_phi2` and the `cart_addr_out` mux;
- `top.sv:1108-1170`;
- `cart2600.sv:150-265` and `:940-980`;
- `mapper_dpcplus.sv:75-192`;
- `mapper_cdf.sv:77-253`;
- `arm_mapper_audio.sv:95-366`.

Nothing was run.

---

## 1. Scores

| Design | Score | One line |
|---|---|---|
| **exact** (B) | **8.0** | AMPLITUDE and NOTE exact with tight, well-defined residues. The grant mirror is checkable on every clock. There is one real gap: an RMW DPC+ service has no queue. The area risk could force the exactness back out |
| **simple** (C) | **7.0** | The same exactness class as exact, and the best test decomposition. But it **drops** RAM and state-RAM write-backs on a short phase 1, so state diverges after one RSYNC-short register access. Its merge lag is the largest (7 clocks) |
| **lean** (A) | **5.5** | The best counter, seed and merge exactness: logical ordering gives `merge_race` = 0 in mode A. AMPLITUDE is lagged by design, as allowed. It has an unclassified AMPLITUDE error on a tick that lands exactly on M. It is the hardest to verify: no lockstep, deferred state, an abort/restart scheduler, and a high-volume `amp_lag`/`amp_input_race` classification |

None has a fatal flaw against D1–D10 for the 21-image mode-A target. Each has one concrete defect, listed in §5, that must be fixed before coding.

---

## 2. Facts re-verified that all three depend on

1. **tb_daria's ROM.** `cart_q <= rom[cart_addr[18:0]]` on every `clk_sys` edge (tb_daria.sv:129), with `cart_addr` = `rom_a` while `tia_en` (top.sv:332).
   - In s0 (E0, E0+1) `rom_do` is the byte at {current bank, previous `a_in`}.
   - From s1 it is the true byte.
   - It refetches after a bank switch.
   - exact (port A) and simple (port B) mirror this with a front-end ROM port addressed with `rom_a` on every clock and a registered lane. That is byte-identical, including Q27 (non-cartridge cycles).
   - One harmless exception: the first clock after the reset release, when `tia_en` is still 0 and the 7800 address is used.
2. **Upstream's grant.** `audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel` (cart2600.sv:965).
   - `init_ram_en` is 0 whenever the audio engine is out of reset, because init runs under the held reset.
   - So a mirror of `sel_ram_sel` is the whole grant rule.
   - DPC+ `ram_sel` = `ram_register_read` (fn 1–3), or a PUSH/WRITE address while `!rw` (mapper_dpcplus.sv:136-158), not gated by `access`.
   - CDF `ram_en` = `stream_substitute && !amplitude_fetch`, or `access && !rw && a_in == $1FF0` (mapper_cdf.sv:140-156).
   - simple's `sel_up` (simple.md:196-214) and exact's `msel` both transcribe this exactly.
3. **CDF `pointer_update_value`** is computed from `table_pointer`/`table_increment` for the index registered at the edge **before** C (mapper_cdf.sv:123-125, 200). With C = E2 the registered index is the stale-byte index (normally 32): that is Q26.
   - **None of the three reproduces Q26.** All three count it under `short_phase1`.
   - lean's §2.6 table says "state yes" for a 2-clock phase 1 (lean.md:444). That contradicts its own Q26 row (lean.md:1095). The Q26 row is right.
4. **Merge semantics** (arm_mapper_audio.sv:191-223, 229-233).
   - At M a changed counter takes the return and loses the tick on M.
   - The refresh for a tick at M is dispatched at M+1 and snapshots the **merged** counters.
   - This matters for lean (§3.1).
5. **R1 is already built.** `stb_be` exists in daria_mem.sv:159/203 and bupchip_pocket.sv:177/360, as all three note.

---

## 3. Per design

### 3.1 lean

**Exact by construction in mode A.**

- **Seeds.** SEED is enqueued at C+1 with `tb = tk − ts`. A tick at L is excluded.
- **NOTE.**
  - Its logical edge is C+4, which is upstream's N_up = E10 when the engine is idle (`audio.md` 9.3).
  - When upstream is busy at C+2, the delay comes from a refresh dispatched by some tick T_p ≤ C+1.
  - The next tick is ≥ 715 clocks later, so no tick can fall in (C+4, N_up]. The NOTE values are exact.
- **Merge.**
  - `ret_s` uses the same two `clk_sys` flops on the same toggle as `complete_sync1/2`, so X = S3 and M = S4.
  - The job applies the merge at logical M, so `merge_race` = 0 unless the bench has to hold `ret_tog` back.
  - lean posts by about C+20…C+44, against upstream's shortest warm X = E0+21, so a hold-back needs a call shorter than about 30 clocks.
- **RMW CALLFN.** SEED2 at M with the pre-merge staging is exact.

This is the best counter exactness of the three.

**Concrete mismatches.**

1. **[defect, unclassified] Tick exactly at M, CDF call that changed counter v (return ≠ seed).**
   - Upstream: at M, `counter_v ← return`; the merge beats the tick (arm_mapper_audio.sv:213-219). The refresh for that tick is dispatched at M+1 with `rc_v = return` (:229-233). So AMPLITUDE for tick M is sampled at 0x800 + (off + return >> shift).
   - lean: the tick at M is ordered before MERGE (`tb ← tk − ts + tick`, lean.md:603, 620-626). Its B3 forms the sample from `c_v + f_old` (lean.md:737).
   - The counter ends right, because MERGE overwrites it. The AMPLITUDE value for tick M is wrong.
   - lean defines `merge_race` as empty in mode A (lean.md:1134). So T2 reports this as `audio_bad`, and an AMPLITUDE read before the next tick gives an L1 `dout_bad`.
   - Expected about 1/716 of counter-changing CDF calls: a handful per music-driven image.
   - **Fix:** for a tick whose logical edge is M with a pending changed-counter merge, take the sample from the return word and suppress the add.
2. **[accepted] `amp_lag`.**
   - Upstream writes AMPLITUDE at T+7 / T+13 / T+19 plus its select blocking.
   - lean writes it at T+11…T+45 (lean.md:785-787).
   - A latch in between returns the neighbouring tick's value: about 1–4% of AMPLITUDE reads, thousands per DPC+/CDF music image.
3. **[accepted, but hard to classify] `amp_input_race`.** For example, the ARM rewrites a waveform pointer word (0x1B0 + 4v) during a call:
   - at a `clk_arm` edge after upstream's POINTER grant (≈ T+2…T+8);
   - but before lean's PTR job read (≈ T+11…T+40).

   The windows differ by tens of clocks per tick, so pointer-changing calls hit it at a few percent. Classifying it needs both sides' per-word read edges and every mirror write's edge.
4. **[accepted] `short_phase1`.**
   - `fe_do` is loaded at E2 = C, too late for the latch.
   - DPC+ state stays exact: the cw1–cw3 read-modify-writes run after C.
   - CDF fetch state differs from upstream's Q26 corruption (§2.3).
5. **[letter of D5]** The returns are read by the MERGE job interleaved with the seeds (M1 F8, M2 F2, …; lean.md:682-684), not as "0xF8–0xFD in consecutive clocks".
   - The values are unaffected, because the merge is logical.
   - On hardware it lengthens the stall by the job's duration.
   - This needs an explicit waiver of D5.
6. **[verification hazard] Resync deposit.**
   - lean deposits 0x18–0x1E "while `aud.ctr_busy == 0`" (lean.md:178).
   - With `tk ≠ 0` or a pending NOTE/SEED/MERGE event, a deposit of upstream's post-tick value is applied again by the pending job.
   - The deposit must also require `tk == 0` and no pending events, or deposit the logical value minus what is pending.

**Verifiability.**

- No per-clock audio lockstep is possible: the counters sit in the state RAM behind deferred jobs.
- T2 must compare at `tick_done` against values recorded at upstream's tick edge.
- L1's AMPLITUDE check is diluted by a high-volume accepted class.
- The abort/restart background scheduler shares W with the front end. It needs its own unit bench (lean lists one). A scheduling bug there shows only as a rare counter or AMPLITUDE corruption that the classes may absorb.
- The front end and audio share ports and W, so a front-end-only random differential has to run the audio too and mask AMPLITUDE.

**Classes in the 21-image runs:**

- `amp_lag`: high volume;
- `amp_input_race`;
- `drift_fe` and `dout_hidden`: information only;
- the tick-at-M error above, until fixed.

### 3.2 exact

**Exact by construction in mode A**, given C ≥ E6.

- **The front end's crb use stays inside upstream's select windows.** I checked each case against the RTL:
  - DPC+ direct DATA/DATAW/FRACDATA: s1, under the address-decoded select from s0.
  - DPC+ fast-fetch DATA: s2.
  - CDF fetch: s1–s3.
  - CDF jump: s1–s2.
  - DSWRITE: in the C clock, with `we = access`.
  - PUSH/WRITE: c0, under the whole-cycle write select.
- So `u_fe ⇒ msel` holds, and the clone is granted on upstream's edges.
- **What the clone reads equals upstream's RAM at each grant:**
  - DSWRITE lands at C, as upstream's does.
  - The PUSH/WRITE byte lands at C+1. Upstream writes at E2–E6, but its select blocks every audio read until E12, so the difference is invisible.
  - `wbuf` drains at C+1, or at C+2 when the audio takes C+1. Every audio read therefore sees upstream's E7.8 writeback: old at ≤ E7, new at ≥ E8.
  - ARM writes come from the mirror on upstream's non-shared `clk_arm` edges.
- **The clone's pseudo-RTL** (exact.md:799-887) matches arm_mapper_audio.sv state for state:
  - `rpend` with the dispatch/tick priority;
  - the NOTE latch and NCAP clear rule;
  - the PCAP window tests (CDFJ+ `[0x40000800, 0x4000_0000 + ram_size)`, CDF0/1/J mod 4K);
  - the shift `word[11:7]`;
  - the digital route order (ROM, then RAM window, then 0).
- **`amp_next` forwarding** is correct: `fe_do` in (C−1, C] equals the AMPLITUDE register in (C−1, C].
- **Seeds** are a flip-flop latch at C+1 = L.
- **Merge.** The first stb read is issued combinationally in (S2, S3), so `c0` merges exactly at M.

**Concrete mismatches.**

1. **[defect, unclassified] RMW DPC+ service.** Example: `INC $105A` with ROM byte $01 at $105A, which `bus.md` B28 lists as reachable, and p3 = $40.
   - W1 commits a copy at C1. `spend` is cleared and the engine is started at C1+1.
   - W2, the shown first phase 2 of the stall, commits a fill at C2 = C1+12. That overwrites `svc_*`, and `spend` clears again at C2+1 ("clear: `cl[0]`", exact.md:586, 391) while `svc_act` is still 1, because the copy takes about 64+ clocks.
   - The design does not say whether the second accept restarts the engine (truncating copy 1) or is lost. Either way the bytes differ from upstream's, whose second service waits for `dma_busy` (`service_ready`).
   - R2/R3 fail, and exact has no `rmw_svc` class.
   - **Fix:** accept only when the engine is idle, as simple does, or a one-deep `svc2` as lean has.
2. **[counted] `merge_race`, per voice.**
   - Merge edges: c0 at M, f0 at M+1, c1 at M+2, f1 at M+3, c2 at M+4, f2 at M+5.
   - Example: a call returns f1' ≠ f1, with a tick at M+2. Upstream adds f1' (written at M); exact adds f1.
   - A dispatch in (M, Cv] also snapshots a pre-merge `rc_v`.
   - About 0.7% of state-changing CDF calls. With `+fe_merge_hook=1` it is 0.
3. **[counted] `dig_rom_lat`.**
   - Local ROM samples always take upstream's **hit** timing (A = R+4, exact.md:950-956).
   - Every upstream DDR miss is a different A edge, and it shifts the clone's FSM until both sides are IDLE. A miss is every new 8-byte sample word, deterministic in tb_daria at `lat` = 20.
   - For a digital-audio CDF image this is a few percent of ticks. Whether any of the 21 images uses digital audio is unknown (R4).
4. **[counted] `rmw_call` (CDF).** Seed v reloads at Cv = M+2v, so a tick in [M, Cv) enters call 2's seed for voices 1 and 2.
5. **[letter of D4]** Under `guard_wr` a 6507-side write is not blocked but counted (`guard_wr_conflict`, exact.md:738).
   - It is unreachable, and not dropping it is the in-sync choice.
   - But D4 says "NO cart RAM port-B write".
   - lean and simple block it. One wording should be chosen.
6. **[counted] `short_phase1`.**
   - Post-commit writes wait for `rdy` (exact.md:243-244), so DPC+ state stays exact.
   - The s2/s3 reads leave upstream's select, and `u_au` adds `!u_fe`, so the grant may lag in that cycle: counted.

**Verifiability.** The strongest per-clock checking of the three:

- **A1:** every audio register against upstream's, on every clock (seeds masked for DPC+).
- **A2:** `msel == sel_ram_sel` on every clock.
- **A3:** the port invariants.
- A ROM-free unit bench of `fe_audio` against `arm_mapper_audio`.
- With the hook and no digital audio, every audio check is an assertion.
- The full-state `fe_deposit_audio` resync is specified.
- The cost is the per-voice `merge_race` rule, which is precise but per voice.

**Classes in the 21-image runs:** `merge_race` (tens per CDF image, with resync); `obus_drift` (information); `dig_rom_lat` only with digital audio.

**Area.** 1,280–1,540 ALMs puts the device at 82.8–85.7%, across the 84% gate.

- Under my lens this matters because exact's own fallback is "drop to the lean audio with counted `amp_lag`", which would undo the exactness.
- simple claims the same exactness class at about 1,200 ALMs.

### 3.3 simple

**Exact by construction in mode A.** The same three properties as exact, re-derived independently:

- **Grant mirror.** `sel_up` transcribes upstream's select exactly (simple.md:196-214).
- **Core port use inside the select.**
  - Fixed crb uses: R@2/@3/@4 for a CDF fetch, R@3 for DPC+ DATA, the DSWRITE byte at C, the PUSH/WRITE byte at C+1. All are inside upstream's select.
  - The DSWRITE/DSPTR P32 read lies outside the select, but it **yields** to `aud_take`. Audio grants are ≥ 2 edges apart, so `p32_try2` never meets one (simple.md:272-279).
- **Write-buffer timing** is equivalent to exact's `wbuf` (C+1/C+2).

simple's other properties:

- The replica FSM matches arm_mapper_audio.sv.
- `amp_nx` forwarding loads through C−1, because `ph1_open` is 0 at C.
- `cp_cap` at L = C+1.
- The payload ring gives `take` by shifting the returns past the seeds (`ring[0]` is the matching seed for the first three shifts), so the merge is one atomic edge.
- `d_in` = `write_DB` keeps `read_DB` out of the input cone.

**Concrete mismatches.**

1. **[defect, cascading] Short phase 1 drops write-backs.** `late = k[5]|k[6]|k[7]` gates these (simple.md:303-315, 458):
   - `swv` for RDAT/DPW;
   - `cwv`, the PUSH/WRITE byte;
   - `wb_v`, the CDF pointer updates;
   - the DSWRITE byte and its `W` step.

   Example: an RSYNC-shortened cycle (C = E0+2) is `LDA $1008`.
   - Upstream increments `counter[0]` at C (flip-flop state; it does not need the RAM).
   - simple skips the S@C+1 write, so `counter[0]` never steps.
   - From then on C1 is `state_bad` and every later DF0DATA read is one byte off. That cascade is not contained by `short_phase1`, which counts only the first cycle.
   - The same happens for a DSWRITE (byte and `ptr32` lost), PUSH/WRITE (byte lost) and DPC+ FRACDATA.
   - lean and exact keep this state exact by doing the write when its data is ready.
   - Critic 26 accepts short-phase **read** mismatches, not state loss.
   - It is rare (an RSYNC, or a misaligned first line after the TIA's reset, which is not yet established: critic 15.3), but it is unbounded once it happens.
   - **Fix:** exact's wait-for-`rdy` rule.
2. **[counted] `merge_race` with a 7-clock window.** M_fe = R+8 = M+7 (simple.md:799-803).
   - All six words merge at M+7, so a tick in (M, M+7] causes it. Example: a tick at M+3 with a changed counter: upstream gives return + f'; simple gives return.
   - A dispatch in the window also causes it.
   - About 1% of CDF calls: roughly 40% more than exact.
   - With the hook it is 0.
   - Issuing the first return read combinationally in (S2, S3), as exact does, would save one clock.
3. **[counted] `rmw_call`.** The ring captures the pre-merge counters at M+7, not at M (simple.md:622, 807).
4. **[counted] `dig_rom_lag`,** as for exact.

**Verifiability.** The best decomposition of the three:

- `fe_core` against `mapper_dpcplus`/`mapper_cdf` on a synthetic bus, with `sel_up` against `sel_ram_sel` on every clock;
- `fe_audio` against `arm_mapper_audio`, driven by the same select stream;
- the phase detector on its own.

Because no datapath register is shared, the random differential bench can test the core without the audio. The atomic merge makes `merge_race` a single window rule.

**Classes in the 21-image runs:** as for exact, with a larger `merge_race` count.

---

## 4. D1 item by item (mode A, nominal phases)

| D1 item | lean | exact | simple |
|---|---|---|---|
| `d_out & oe` at non-hidden latches | exact, except AMPLITUDE (`amp_lag`) and the tick-at-M value | exact, including AMPLITUDE | exact, including AMPLITUDE |
| Scheme registers after every cycle | exact; short phase: Q26 for CDF fetch (counted) | exact; short phase: Q26 (counted) | exact; **short phase: write-backs dropped, cascade** |
| Cart RAM after init, writes, call start, frame | exact (`tbl_alias`) | exact (`tbl_alias`) | exact (`tbl_alias`); short phase: bytes dropped |
| DPC+ copy/fill results | exact, including the RMW pair (`svc2_p`) | **RMW pair unhandled** | exact, including the RMW pair (accept when idle) |
| Call payloads (`seed_race` = 0) | exact (logical) | exact (FF latch) | exact (ring at L) |
| Tick edges | same | same | same |
| Counters and frequencies per tick | **exact (`merge_race` 0)** | `merge_race` windows of 0–5 clocks per voice | `merge_race` window of 7 clocks |
| AMPLITUDE | lag (counted) + **tick-at-M error (unclassified)** + `amp_input_race` | exact; `merge_race`/`dig_rom_lat`/`copy_race` | exact; `merge_race`/`dig_rom_lag`/`svc_audio_race` |
| NOTE | exact (logical) | exact (same edge) | exact (same edge) |
| Zero-class run possible? | no (`amp_lag` is inherent) | **yes, with the hook** | **yes, with the hook** |

---

## 5. Defects to fix before coding (none fatal)

1. **lean:** the AMPLITUDE of a tick exactly at M ignores a changed-counter merge. It is unclassified.
2. **simple:** a short phase 1 suppresses RAM and state-RAM write-backs, and the state diverges permanently. Adopt the wait-for-`rdy` rule.
3. **exact:** an RMW DPC+ service (1/2 → 1/2) has no queue, so the copy/fill results differ, with no class for it.
4. **lean:** the resync deposit ignores pending tick jobs and events.
5. **lean:** its §2.6 "state yes" for a 2-clock phase 1 contradicts Q26. Count CDF fetch state there.
6. **Wording against decisions:**
   - lean's interleaved return reads deviate from D5's "consecutive clocks";
   - exact's guard counts a 6507 write instead of blocking it, against D4's letter (unreachable).

---

## 6. Ideas worth grafting into the winner

1. **A one-tick merge correction (from lean's logical-order idea), so exact or simple reach `merge_race` = 0 without the hook.**
   - Ticks are ≥ 715 clocks apart, so at most one tick k ∈ {0, 1} falls in (M, M_fe].
   - At M_fe, if a tick fell in the window:
     - a changed counter takes return + f';
     - an unchanged counter takes c − f + f', using the old `f` still in the frequency register.
   - If a refresh was dispatched in the window, the same correction applies to `rc_v` before its sample issue.
   - Each voice's tick adder can do this in one more clock.
2. **exact's combinational first return read in (S2, S3).** The first merge word then lands exactly on M.
3. **simple's module split, with no datapath register shared between the core and the audio, and the per-block unit benches against upstream modules.** simple's payload ring is also worth taking: one post data source, an atomic merge, and the RMW pre-merge swap for free.
4. **exact's per-clock A1/A2/A3 assertions and its full-state `fe_deposit_audio` resync.**
5. **lean's `svc2_p` one-deep RMW service queue, or simple's "engine accepts when idle".**
6. **exact's and lean's rule that every post-commit write waits until its data is ready.** It keeps state exact for any phase-1 length.
7. **exact's `p32` flip-flop for stream 32.** DSWRITE/DSPTR then need no out-of-select read and no yield logic. Alternatively, keep simple's yielding P32 read if area matters. Both keep the grants exact.
8. **simple's `d_in = write_DB`,** which keeps the SDRAM/SRAM-sourced `read_DB` out of `daria_fe`'s input cone.
9. **lean's assertion set:**
   - `tk_sat`, `guard_wr`, `guard_sub`;
   - `fpjr` (`!(fast_pending && jr != 0)`);
   - `ret_unasked`, `ram_wr_noaccess`.

   Plus the bench's `det_bad`, and `locked` = 0 in mode A.
10. **exact's 4-bit `pptr` counting to 8.** C1 can then compare `parameter_pointer` without `min(…, 4)`.

---

## 7. Recommendation

Under exactness and verifiability, the winner is **exact's architecture**, built in simple's style:

- a flip-flop clone of `arm_mapper_audio`;
- the grant mirror;
- the ROM mirror port;
- the C+1/C+2 pointer buffer;
- seeds latched at L;
- simple's split, ring and unit-bench plan.

Then fix or add these:

- the RMW service queue;
- wait-for-ready post-commit writes (not simple's suppression);
- the one-tick merge correction (§6.1), so `merge_race` = 0 without the hook;
- the A1/A2/A3 checks from the first run.

That reaches every D1 point with no counted difference in the 21 images except `obus` drift, which is information only. The exceptions are `dig_rom_lat` (digital-audio images only) and the RSYNC/pause classes.

Area is the risk. Take simple's lower estimate (about 1,200) as the target, not exact's 1,280–1,540. The fallback order, best first:

1. exact's R-a (drop `rc`);
2. R-c (merge compare by read-back);
3. only then lean's state-RAM audio, which brings `amp_lag` back.

If the owner keeps the lean audio, lean's logical ordering is the right core. It needs:

- the tick-at-M fix;
- a pending-aware deposit;
- a bench plan that budgets for classifying `amp_lag` and `amp_input_race` on both sides' read edges.
