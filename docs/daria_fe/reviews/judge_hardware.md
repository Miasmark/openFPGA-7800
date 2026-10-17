# Judge (hardware lens): lean, exact, simple

Scope: ALM/FF/M10K cost, `clk_sys` critical paths at 69.84 ns under `MUX_RESTRUCTURE OFF`, M10K port use, the shared-edge guard and its phase detector (8:3 geometry, SDC), clock crossings, and the `clk_sdram` cone. Behavioural exactness is judged only where it decides a hardware choice or a D1–D10 pass/fail.

Read in full: the eight `docs/daria_fe/spec/*.md`, `docs/DARIA_CORE.md` ("The front end", "The memory system…", "Step 5 work", plus "Clock" and "Budget" for the area gate), `frontend_study/README.md` and `daria_fe3.sv`, `daria_mem.sv`, `daria_call.sv`, `bupchip_pocket.sv`, and the three designs. Upstream RTL re-checked: `top.sv:205-215, 376-396, 1108-1114`; `cart2600.sv:208-234`; `bup_capture.sv:140-170`; `core_constraints.sdc` (all). Nothing in the repository was changed.

Scratch check (no game data): `judge_tmp/det.py` simulates the three phase detectors on the VCO edge lattice.

---

## 0. Calibration and the area budget

### 0.1 Calibration points (measured, `MUX_RESTRUCTURE OFF`)

| Source | ALMs | LUT | FF | ALM/LUT |
|---|---|---|---|---|
| Sketch `daria_fe3` v3 (README §4): core 436, datapath+arbitration 239, audio 225, copy 104 | 1,004 | 1,585 | 444 | 0.63 |
| Upstream `arm_mapper_audio`, live [probe] (README §1.1) | 657 | 1,049 | 518 | 0.63 |
| Upstream `mapper_dpcplus`, live [probe] | 832 | 1,292 | 589 | 0.64 |
| FSM-arm coding of the same sketch (README §3.8) | 1,343 | | | +34% over enable style |

The sketch includes BUS (stuffing, BUS3, map rotation; I take about −70 ALMs for it) and omits the items README §4 lists (+30 to +60).

### 0.2 What the device leaves for the front end

- Device: 18,480 ALMs. The 84% gate (`BUPCHIP_CORE.md`, DC:1601) is 15,523.
- DC's step-3 projection is 14,872–15,382 with the lean line of 850–1,100 for the front end. Everything else is therefore 14,022–14,282.
- **Front-end budget to the gate: 1,241 (others at their top) to 1,501 (others at their bottom).**
- Step 5's wrapper synthesis (+948 ALMs over the shipped wrapper, with Thumb inside) suggests the "others" sit in the upper half. So read the realistic budget as about **1,240–1,320 ALMs** before the gate, with no headroom left at the top.

### 0.3 My re-estimates

| Block | lean | exact | simple |
|---|---|---|---|
| 6507 core: decode, phase-1 reads, `fe_do`, FF state, commit | 330–400 | 420–480 | 480–540 (incl. its own W, adder, B) |
| Datapath and port arbitration | 260–310 (shared W, ~11-way B, 4-owner muxes on crb/FER A, 6–7-source `stb_wd`) | 260–330 (W, `p32`, `wbuf`, 8-source post mux, 5-user crb mux) | 110–140 (`fe_arb`: 8-source crb address, 7-source `stb_wd`) |
| Audio | 270–330 (state-RAM counters, event bookkeeping, abort/grant) | 500–570 (flip-flop clone, seeds, 3 merge compares, local + remote ROM sample) | 520–580 (flip-flop replica plus a 6×32 ring with a 3:1 mux per bit: about 96 ALMs, not the 48 claimed) |
| Copy, F6, `init_busy` | 110–140 | 100–130 | 85–115 |
| Call side | 20–30 | 40–70 | 30–40 |
| Guard, sequencing | 20–25 | 10–15 | 15–20 |
| **Total (mine)** | **1,010–1,235, mid ≈ 1,120** | **1,330–1,595, mid ≈ 1,460** | **1,240–1,435, mid ≈ 1,340** |
| Designer's own | 910–1,110 | 1,280–1,540 | 1,100–1,320 |
| Flip-flops | ≈ 550 | ≈ 1,120 | ≈ 1,220 |
| New M10K | 0 | 0 | 0 |
| Device at mid (others 14,022–14,282) | 15,142–15,402 = **81.9–83.3%** | 15,482–15,742 = **83.8–85.2%** | 15,362–15,622 = **83.1–84.5%** |

How I got there:

- **lean** is about 10% optimistic. Its core figure (280–340) sits about 60 below "sketch core minus BUS". Its arbitration has more owners than the sketch: crb has four, FER A four, and the state RAM three, and `stb_wd` takes entry, stack, `crb_q`, `stb_q`, sum, field bytes and 0.
- **exact**'s audio clone, built bottom-up, comes to about 500–570:
  - tick 25, counters with folded muxes 48, three 32-bit merge compares 27, frequencies 48;
  - seeds 24 and snapshots 24 (register-only ALMs);
  - `rc` 3:1 and the 32→15 shift 50, sample address and mux 45, `daddr` 25, the CDFJ+ window `woff` 45, the route compares 26;
  - FSM, sum, notes and AMPLITUDE about 90, ROM-sample paths 20.

  That is upstream's 657 less the BUS paths. The 8-source × 32-bit post mux is about 60, not 30.
- **simple**'s core table omits the sketch's datapath share it took over (W, adder, B: 55). Its ring is a 3:1 mux on 192 bits.
- **Coding-style risk (exact, simple).** Both write the audio clone as a `case (st)` FSM that assigns many registers in many arms (exact.md:853-882; simple.md:658-690). That is the style the study measured at +34%. Their ALM figures assume the per-register enable style D10 requires, so the RTL must be re-expressed that way.

**Verdict on area.**

- Only **lean** leaves headroom under the 84% gate at its realistic size.
- **simple** sits on the gate.
- **exact** is over the gate at its midpoint, by its own numbers too (82.8–85.7%, exact.md:84, 1261). Its reductions R-a…R-d bring back counted classes.

---

## 1. `clk_sys` critical paths (69.84 ns)

Assumed figures for Cyclone V C8: M10K t_co (unregistered output) about 4–5 ns, a LUT level with routing about 1.0–1.5 ns, and a 32-bit carry chain about 3 ns. The M10K address and write enable are registered inside the block.

| Design | Worst path (my estimate) | Est. delay | Slack |
|---|---|---|---|
| lean | B3: `stb_q` (frequency) → 32-bit add (W+f) → 32→15 shift (3 LUT levels) → 15-bit add (`ofs`) → `+$800`/mask/mux → crb owner AND-OR → crb address | 25–32 ns | ≥ 37 ns |
| lean | s1: `feb_q` → lane mux → `in_rng` (9-bit compare) and `a_in==fexp` (13-bit) → normalise (8-bit subtract) → `pb+s` → crb mux | 18–24 ns | |
| exact | audio sample address: `rc` 3:1 → shift → 15-bit add → mask → crb mux | 22–28 ns | ≥ 40 ns |
| exact | mirror → `msel`: `fea_q` → lane → CDF predicates → `msel` → `u_au` → `u_wb`/`u_p32`/`u_cp` priority chain → crb address/we | 18–24 ns | |
| exact | `access` (top.sv TIA divider → pairing → `mapper_phi2` with the stall) → DSWRITE crb select/we | 15–22 ns (crosses into `bupchip_pocket`'s M10K) | |
| simple | `feb_q` → predicates → `sel_up` → `aud_take` → R owner → R address | 18–24 ns | ≥ 40 ns |
| simple | `rc` → shift → add → mask → R address | 22–28 ns | |

- Nothing is near the period.
- Every stage in all three is register or M10K q → logic → register or M10K input. None has two M10K stages in one clock.
- One structural point: in exact and simple the 6507-side decode feeds the audio grant combinationally (`msel`/`sel_up` → grant → crb owner → address). The FE block and the audio block are then coupled in one clock, across what may be a long route to `daria_mem`. It is still about 20–25 ns. lean's owner selects come from registers (`fs`, `cw`, `wbc`), which is the cleaner floor plan.

---

## 2. M10K port use: is any port needed by two users in one clock?

Short answer: **no structural double-booking in any design.** Each port has a priority encoder, and every fixed-time user is shown disjoint from the others. Details, and the near-misses:

### lean

| Port | Users, in priority order | Check |
|---|---|---|
| FER B | front end only, `cur[14:2]` every clock (the mirror) | — |
| FER A | F6 > FE s0 lookahead > audio digital ROM > copy | The capture overrides it in `cap_we` clocks, which happen only while the console is in reset; F6 starts after `c_close` (bup_capture.sv:150-152), when `cap_we` is already 0 |
| stb | F6 clear > FE (`fe_st`: DPC+ s1 and cw1–cw3) > audio | Audio steps abort and retry if not granted |
| crb | F6 > FE (`fe_crb = (cdf & fs[1]) \| fs[2] \| (wbc & \|cw)`, lean.md:207) > audio > copy | |
| W | FE in cw2/cw3 > audio (block aborts on `fe_w`) | The W-sharing argument (lean.md:479-500) holds: an audio block always consumes W in the clock after it loads it, and aborts if that clock is cw2/cw3 |

Near-misses:

- **`fs[2]` claims crb in every cycle of every scheme**, DPC+ plain ROM reads included. It is harmless, but it wastes about 1 audio/copy slot in 12.
- **`tb` (ticks ahead) is 2 bits while `tk` saturates at 7** (lean.md:598-603). If more than 3 ticks are pending when a SEED, NOTE or MERGE event is enqueued, `tb` overflows and the logical order breaks silently. `tk_sat_cnt` does not catch it. Widen `tb` to 3 bits and assert `tk ≤ 3` at enqueue.
- **The DPC+ copy is not pipelined**: CP_RD → CP_WT → CP_WR (lean.md:951-961), about 2.5 clocks per byte. A 255-byte fill or copy holds the 6507 for about 600–840 `clk_sys`, against upstream's ~70 for a fill and ~234 for a copy (GL 5.2). That is close to a scanline of extra stall per service on hardware. It is absorbed in mode A, but the copy/fill path is untested by the image set and DPC+ bB titles may use it. It is a hardware-behaviour cost, cheaply fixable (§6).

### exact

| Port | Users | Check |
|---|---|---|
| FER A | the mirror, every clock (`fea_addr = rom_a[14:2]`) | During a download `cap_we` overrides it in `daria_mem`; the console is in reset |
| FER B | CDF lookahead s0 (`!init_busy`) > digital ROM sample (local) > copy / F6 source | The lookahead and digital samples are CDF; copy is DPC+; F6 runs in reset with the lookahead gated. The local sample has a 2-clock window and meets at most one s0 |
| crb | `u_fe` (fixed slots) and `u_au` (exact grant), then `u_wb`, `u_p32`, `u_cp` | The invariant `u_fe ⇒ msel ⇒ !u_au` holds per access kind; I re-checked D3, D6, D8, C2, C5 and C6 against upstream's `sel_ram_sel` windows. `wbuf` drains at C+1 or C+2, because the audio is never granted on two consecutive edges (ISSUE then CAPTURE). That matches upstream's E7.8 writeback as every audio read sees it |
| stb | DPC+ FE (s0, s1 reads; c0 writes) > CDF merge reads > post > clear | The merge is CDF-only and the FE use is DPC+-only, so they never contend |

Near-miss: `wbuf_v` has no reset term in the register table. A pointer commit followed by a console reset one clock later still drains before F6, because F6 starts ≥ 8 clocks after the reset rise, so it is harmless. Clearing it on `cart_reset` costs nothing.

### simple

| Port | Users | Check |
|---|---|---|
| FER B | the mirror, every clock | — |
| FER A | F6 > lookahead k[0] (CDF) > digital ROM (CDF, waits one clock if it meets k[0]) > copy (DPC+) | — |
| R | F6 > core fixed (k1–k3, C, c0) > audio (exact grant) > P32 read / pointer buffer (yield) > copy | The invariant "core fixed ⇒ `sel_up`" holds per row of simple.md:506-513 |
| S | F6 clear > core fixed (DPC+) > call port | The audio uses no state RAM |

Near-miss: the **P32 read is not guard-aligned** (priority 3 has no `guard_on` term). It is only issued for DSWRITE/DSPTR, which cannot occur in the guard window, so it is not a flaw.

### All three

- **No port's q is consumed in the clock after its own partial-byte-enable write.** Every consumer is tied to a read issued in the previous clock, so `NEW_DATA_NO_NBE_READ` is never relied on (DI 2.2).
- **The call block on the state RAM is ordered by the toggles.** Port B writes F0–F7 only before the flip. `daria_call`'s port A reads F0 at A3 (≥ 2 `clk_arm` after the flip) and F1–F7 at A18–A26. Port B reads F8–FD only after the synchronised `ret_tog`.
- **During a call, lean's tick jobs write state RAM words 0x18–0x1A** while `daria_call` idles at 0xF0. These are different words, so there is no mixed-port hazard.

---

## 3. The phase detector, the guard and the SDC

### 3.1 Edge geometry (checked by simulation, `judge_tmp/det.py`)

Lattice used: `clk_sys` = VCO/48, `clk_arm` = VCO/18. A toggle launched at a `clk_arm` edge t is taken by the first `clk_sys` edge E with E − t ≥ the path delay, for delays in [1, 6] ns.

| Case | lean (lock after 6) | exact (lock after 15) | simple (lock after 12) |
|---|---|---|---|
| ÷18, delay 1, 3 or 6 ns: change pattern 1,0,1,1,0,1,… | locks, stays locked | locks, stays locked | locks, stays locked |
| ÷18, random per-launch delay in [1, 6] ns | stays locked | stays locked | stays locked |
| ÷19, fixed delays | longest consistent run 4: never locks | 4: never | 4: never |
| ÷19, random per-launch delays (400k edges) | longest run 4: never | 5: never | 5: never |
| Mode A (`clk_arm` = 5 × `clk_sys`, coincident) | longest run 2: never | 0: never | 2: never |

- **All three detectors are correct on the 8:3 geometry and inert where they must be.**
- **The phase-B edge is right in all three.** Each designates the edge right after the shared one (VCO 48 in the 144 frame): 17.46 ns after the `clk_arm` edge at 36, and 8.73 ns before the one at 54.
- **lean's margin against a false lock at ÷19 is thin**: a run of 4–5 against a lock of 6. A false lock would only delay reads, so it does no harm, but a lock of 9 costs one flop bit.

### 3.2 How each one drives the guard

**lean.** `bissue = locked & (ph == 0)`, and `ph` is the flywheel register. The guard decisions therefore come from a register that predicts, not from the constrained receiver `ph_st`, and `ph_st` feeds only `ph_st1` and the flywheel. This is the most robust form.

`guard.active` is ANDed into `crb_we` (except F6). This is D4's "no port-B write", literally. FE s1/s2 crb reads are suppressed under the guard, but their address is left "don't-care" (lean.md:512); park it on a constant instead.

**exact.** `pb_next = locked && pd_same`, and `pd_same` is combinational from the receiver `pd_st` and `pd_q`. That is correct at ÷18, where `pd_st` cannot go metastable thanks to the [1, 6] ns window.

The guard blocks `u_wb`, `u_cp` and the audio and `p32` reads that are not on phase B. **The front end's own DSWRITE and PUSH/WRITE crb writes are not blocked under the guard; they are counted `guard_wr_conflict`.** exact argues they are unreachable (a held 6507, and an 84-clock reset sequence against ~63 clocks to `daria_ready`), and I agree they are. It is still not D4's literal "no write".

**simple.** `phb_next = lk & shared_last`, also combinational from the receiver `st`. `guard_on` suppresses core priority-1 R requests (reads and writes), the pointer buffer and the copy engine. That is D4-literal.

### 3.3 SDC

All three give the pair `set_max_delay 6.0` / `set_min_delay 1.0`, reg-to-reg, on the single toggle → receiver path. In each case:

- the pair is more specific than the clock-to-clock ±20 ns pair, so it takes precedence;
- 6 ns < 8.73 ns − setup − skew;
- 1 ns keeps the toggle launched on the shared edge out of that same edge;
- the fitter-only `set_clock_uncertainty -add -hold … 0.1` into `clk_sys` (core_constraints.sdc) only adds margin.

| | lean | exact | simple |
|---|---|---|---|
| Patterns | `{*daria_fe*\|dfe_guard*\|ph_at}` → `…\|ph_st`. Matches; `ph_st1` is not matched | `{*\|daria_fe:*\|fe_guard:*\|pd_at}` → `…\|pd_st`. Matches | `{*\|daria_fe:*\|fe_phase_det:*\|g_tog}` → `…\|st`. Matches. The receiver is named `st`, which collides in name with `fe_call`'s FSM `st`; the `fe_phase_det:` qualifier saves it, but rename the receiver |
| Preserve / retiming | **None**: only `SYNCHRONIZER_IDENTIFICATION OFF` in the qsf (lean.md:1014). Physical synthesis is on in this project and may duplicate or retime the receiver | `(* preserve *)` on both flops | `PRESERVE_REGISTER ON` and `SYNCHRONIZER_IDENTIFICATION OFF` as attributes, and a step-7 check that each line covers exactly one path and that no retiming moved `st` (simple.md:908, 940) — the best of the three |

### 3.4 Remaining hardware risks, common to all three

- **Global-network skew at the shared edge** (DI:726) must be read from STA on the one path.
- **On the ÷19 fallback**, the receiver can go metastable. Every design gates the guard by `locked` and only registers otherwise, with a whole clock to resolve, so the MTBF is fine.

---

## 4. Clock crossings

| Crossing | lean | exact | simple |
|---|---|---|---|
| `ret_tog` (clk_arm) → 2 `clk_sys` flops | yes | yes (plus `ret_wait`) | yes, marked `SYNCHRONIZER_IDENTIFICATION FORCED` |
| `call_tog` → `daria_call`'s 2 `clk_arm` flops | register | register | register |
| `daria_ready` (already 2 flops in the wrapper) | used direct | registered once more | used direct |
| Digital sample: toggle out, held 19-bit address; answer toggle through 2 (lean 3) flops, held byte | yes | yes | yes |
| The detector path | its own SDC pair | its own SDC pair | its own SDC pair |
| `clk_arm` into `daria_fe` | one toggle flop | one toggle flop | one toggle flop |

- All held buses sit under the existing ±20 ns `clk_sys`/`clk_arm` exceptions and are sampled at least 2 destination clocks after their toggle.
- DC 7.3 asks that the first flop of every synchroniser be marked FORCED. Only simple says so; lean and exact should add it for `ret_s`/`ack_s`.

---

## 5. The `clk_sdram` cone (D10)

- All three: `fe_do`, `arm_call_busy`, `arm_dma_busy` and `init_busy` are registers.
- `rom_addr`/`ram_sel` for BANKDPCP/BANKCDF are constants in cart2600.
- `init_busy` feeds the D input of the wrapper's `clk_sys` reset register (R2).
- `fe_oe` is `a_in[12]`. lean and simple drive it combinationally, as every mapper already does. exact registers it (exact.md:265), which is harmless at the latch and buys nothing.
- **No design adds a path into a `clk_sdram`-captured register.**
- **`d_in`.** lean and exact take `cart_din = RW ? read_DB : write_DB` (top.sv:1112). `read_DB` carries the SDRAM byte (`rom_do`) through cart2600's output mux (cart2600.sv:217-231, a run-time-selected mux) and `fe_do` itself. Their `dl`/`din_q` registers therefore become new endpoints of the `sdram → clk_sys` multicycle class. They are still timed correctly by core_constraints.sdc's `-setup 2`, so this is not a cone violation, but it is the loop Fix B's table calls out.
- simple takes `write_DB` (the CPU's DOR, top.sv:210). It is identical on every write cycle, which is the only time `d_in` is used, and it keeps `read_DB` out of the input cone entirely. **This is the cleanest choice; graft it.**

---

## 6. Per-design verdicts

### lean (Architect A): 8 / 10

**Fatal flaws (D1–D10):** none under this lens.

**Strengths:**

- The smallest and the only one with headroom: about 1,120 ALMs mid (81.9–83.3% of the device) and about 550 FF. The state lives in the M10Ks it already has.
- One W and one adder shared, as the study measured.
- Port owners come from registers, so there is no FE→audio combinational coupling.
- The guard is D4-literal: the crb write enable is hard-gated, FE reads are suppressed, and the phase-B rule is driven by a registered flywheel prediction.
- K1 (read before the commit, read-modify-write after it) keeps all RAM-held state exact for a 2-clock phase 1. That is also the cheapest way to meet D3's "keyed to the commit edge".
- The logical event order (`tb`) gives `seed_race` = 0 and `note_race` = 0 with no extra flip-flops. It also gives `merge_race` = 0 in mode A without needing D5's consecutive-read timing.

**Weaknesses:**

- The size estimate is about 10% optimistic.
- The abort/restart background scheduler is the hardest piece to verify; starvation corrupts counters silently, and only `tk_sat` catches it.
- `tb` is 2 bits against `tk`'s 3.
- The DPC+ copy/fill is about 2.5 clocks per byte, about 10× upstream's fill.
- No `preserve`/retiming protection on the detector flops.
- FE reads suppressed under the guard leave a "don't-care" address.
- The merge reads F8–FD interleaved per voice, not in consecutive clocks. This departs from D5's letter but is logically equivalent.
- `fs[2]` claims crb in every cycle.
- The lock of 6 has a thin margin against ÷19.

### exact (Architect B): 5 / 10

**Fatal flaws:**

- **Area.** 1,280–1,540 ALMs by its own count, about 1,330–1,595 by mine. That puts the device at about 83.8–85.2% at mid, over the 84% gate, with no headroom (D10: "leave headroom"). D1 lets a design make AMPLITUDE exact only if it argues the cost, and exact's own argument shows the cost crossing the gate (exact.md:84, 1261). The listed reductions trade the exactness back.

**Strengths:**

- The cleanest port invariants of the three: `u_fe ⇒ msel` and `u_au ⇒ !u_fe`.
- The `wbuf` drain at C+1/C+2 reproduces upstream's E7.8 writeback exactly as audio reads see it.
- The `p32` flip-flop copy of stream 32 removes the DSWRITE/DSPTR pointer read and makes stream 32 immune to `tbl_alias`.
- The merge starts on the clock the synchronised `ret_tog` changes, so voice 0 merges exactly at M (window ≤ 5 clocks).
- The copy is pipelined at about 1 byte per free clock.
- The service clamps are computed at C as upstream does.
- The local digital-ROM sample runs at upstream's hit timing.
- `fe_do` follows upstream's post-commit `d_out`, which shrinks the drift.
- `(* preserve *)` sits on the detector flops.
- RAM state stays exact for a short phase 1.

**Weaknesses:**

- About 1,120 FF.
- The audio clone is written in FSM-arm style, which the study measured at +34% if coded literally.
- An 8-source × 32-bit post mux.
- The front end's own crb writes are not blocked by the guard (they are counted `guard_wr_conflict`), so D4 holds only because they are unreachable.
- `pb_next` comes combinationally from the constrained receiver.
- The registered `fe_oe` is pointless.
- `d_in = cart_din`.
- `wbuf_v` is not reset.
- RMW seeds are reloaded per voice, which gives `rmw_call` on CDF.

### simple (Architect C): 6 / 10

**Fatal flaws:**

- **A short phase 1 drops RAM writes (D1).** With C < E0+6, `late` = 0 skips:
  - the DPC+ PUSH/WRITE byte and DATA counter write-backs;
  - the CDF DSWRITE byte and every pointer update (simple.md:458).

  These are 6507 writes and state changes that upstream makes, so cart RAM and state RAM diverge for the rest of the run. Critic 26 accepted only the `fe_do` miss in such cycles, not a state divergence. It happens after an RSYNC, and possibly at the first line end after the TIA's reset (BU B2, not established either way). It is fixable by doing the reads after the commit when `!late`, as lean does.
- **Area is on the gate.** That is not fatal by itself, but with ~1,340 mid there is effectively no headroom.

**Strengths:**

- `d_in = write_DB`: the cleanest input cone.
- No shared datapath register: the core and the audio each have their own. That makes the per-clock lockstep check against `arm_mapper_audio` possible.
- The payload ring gives exact seeds, an atomic merge, an exact RMW second call and a single post data source.
- The P32 read and the pointer buffer yield to the audio.
- The fill is word-wide with byte-enable masks: 255 bytes in about 66 clocks, close to upstream's 70.
- The detector carries `PRESERVE_REGISTER` and `SYNCHRONIZER_IDENTIFICATION OFF` attributes, the plan checks SDC coverage and retiming explicitly, and `ret_s` is marked FORCED.
- D4 is literal: core requests, the buffer and the copy engine are all suppressed under `guard_on`.

**Weaknesses:**

- About 1,220 FF.
- The ring's ALMs are underestimated by about 50.
- The audio is written in FSM-arm style.
- The merge lands at M+7, a 7-clock `merge_race` window.
- The P32 read is not guard-aligned (unreachable).
- It counts 64 clocks itself, duplicating `bup_capture`'s `DRAIN` constant, where an exported `c_close` would be more robust.
- The receiver is named `st`, which collides in name with `fe_call`'s FSM.
- The decode feeds `aud_take` combinationally, which couples the FE and audio blocks in one clock.

---

## 7. Ideas worth grafting into the winner (lean)

1. **`d_in` = `write_DB`** (simple). Export `write_DB` in the `top.sv` POCKET_DARIA group instead of `cart_din`. This removes `read_DB`, and with it the SDRAM byte and `fe_do`, from `daria_fe`'s input cone. It costs nothing.
2. **Detector hygiene** (simple, exact):
   - `PRESERVE_REGISTER ON` on the toggle and the receiver;
   - `SYNCHRONIZER_IDENTIFICATION OFF` on the receiver and FORCED on `ret_s[0]`/`ack_s[0]`;
   - a step-7 STA check that each of the two SDC lines covers exactly one path and that physical synthesis did not retime or duplicate the receiver;
   - a lock of 9 instead of 6 for ÷19 margin.
3. **A pipelined DPC+ copy** (exact: one byte per free clock, the source word read while the previous byte is written) **and a word-wide fill with byte-enable masks** (simple). This brings the service stall from about 600–840 clocks to about 70 (fill) and 270 (copy) for about +15–25 ALMs.
4. **The `p32` flip-flop copy of CDF stream 32** (exact), optional at about +25 ALMs. It removes lean's cw1 pointer re-read for DSWRITE/DSPTR and takes stream 32 out of `tbl_alias`. It must be refreshed after F6 and after every call, before the release.
5. **`rel_ok = (ph2 | pclk0) & ~pclk1`** (exact, simple): the `pclk0` edge itself is also a safe release edge. This is trivial.
6. **If lean ever drops the logical merge**, adopt exact's trick: issue the first return read (F8) in the clock in which `ret_s[1] != ret_seen` is first seen, then read F8–FD back to back (D5's letter).
7. **Fixes, not grafts**:
   - widen `tb` to 3 bits and assert `tk ≤ 3` at event enqueue;
   - park the suppressed FE crb address under the guard;
   - drop the unconditional `fs[2]` crb claim for non-RAM ops.
8. **Optional and cheap:** exact's "`fe_do` follows the live `d_out` function after the commit". It shrinks `drift_fe` to the DPC+ RAM-backed direct reads.

---

## 8. Recommendation

- **Build lean.** It is the only one of the three that fits under the 84% ALM gate with headroom left. Its timing is easy, its port use has no conflicts, and its detector is correct on the 8:3 geometry. Its guard is the most D4-literal, and the most robust, because the phase-B rule comes from a registered prediction.
- **Graft:**
  - simple's `d_in = write_DB` and detector attributes;
  - exact's pipelined copy and simple's word-wide fill;
  - optionally exact's `p32`.
- **Fix** lean's `tb` width.
- **Before coding the audio**, measure lean's abort scheduler with the random-phase unit bench it proposes (lean.md 11.2 #1). That is where its risk is, not in area or timing.
- **If the owner wants exact AMPLITUDE after all**, take simple's separate audio replica (no shared W, per-clock lockstep against `arm_mapper_audio`), with:
  - lean's K1 post-commit read-modify-write, to close simple's short-phase D1 gap;
  - exact's `p32`, `wbuf` and early merge read.

  Gate that option on a synthesis probe of the audio replica alone: it needs about ≤ 450 ALMs to leave the device under 84% with headroom.
