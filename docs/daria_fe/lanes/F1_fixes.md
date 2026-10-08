# F1: the lead's decisions on lane E's findings (DARIA step 6)

Three decisions of the lead, on `E3_rtl_issues.md` (issue 1, note 1) and `E2_directed.md` (6.1). For each: what changed, why, how it was verified, and the area. Areas are Quartus synthesis estimates of `daria_fe_probe` (`daria_fe_map.sh daria_fe_probe --synth`, the probe wrapper in `EXTRA_SRCS`), against the RTL as committed before these changes: **1,667 ALMs, 1,094 registers**.

Four reviewers then checked the first version, and the lead ruled on their findings (2026-10-08). This text is the revised version: each section says what the review changed.

| # | Decision | Result |
|---|---|---|
| 1 | Drop a stranded post action at `pclk1` (E3 issue 1, option (a), refined) | Done. +4 ALMs, +0 registers |
| 2 | Make `al` follow upstream's lane register exactly, and `pause_lane` must-be-0 (E3 note 1) | **Not done**: no exact equivalent exists. The near-exact form costs about 12 ALMs. `pause_lane` stays counted, now counted only in its exact case (2, "The class as the benches count it"). It cannot occur on the Pocket, which never pauses the core (`docs/DARIA_CORE.md`, decision 10); the near-exact form is kept as a patch for a MiSTer port (2, "On the Pocket, and for a MiSTer port") |
| 3 | Accept `cdf_jump_ffe`'s exposure and count it as `obus_ffe` (E2 6.1, option (a)) | Done (bench only), narrowed to that one case and its values. 0 ALMs |

## 1. A post action stranded by a reset release

### Change

`src/fpga/core/bupchip/daria_fe_core.sv`:

- `pend_c`, `pend_s` and `pend_r` also clear at `pclk1`. The priority is reset, then the set at C, then the clear (`fire | pclk1`).
- `rcyc`, one flop, read only by the assertion: cleared at every `pclk1` edge, set at any other edge with `rst_fe` high (`if (pclk1) rcyc <= 1'b0; else if (rst_fe) rcyc <= 1'b1;`). It is 1 exactly when some edge since the last `pclk1` edge had `rst_fe` high: "this 6507 cycle ran some of its k reads under reset".
- `a_pend_late = pclk1 & !rcyc & (pend_c != PC_NONE | pend_s | pend_r)`.

### Why

The ready flags are held at 0 while `rst_fe` is high. When `rst_fe` falls after k[3] of a cycle that commits a DFxDATA/DATAW/FRACDATA read, a PUSH/WRITE, a CALLFUNCTION 1/2, a DSWRITE or a DSPTR, the commit sets an action whose flag stays 0 for the rest of the cycle. Before this change the action stayed pending and fired in the first later cycle that set the flag, with that cycle's W: for a fetcher read, one fetcher's word written into another's (E3 issue 1). Now it is dropped at `pclk1`. The release cycle itself stays inexact, as option (a) said: upstream does that access, `daria_fe` does not. Design 9.5 counts that cycle as `rst_release`.

A stranded CALLFUNCTION 1/2 (`pend_c = PC_SVC`, DPC+) changes more than its own access. `dma_set` fires at C whether or not `rdS_r` is set (`daria_fe_core.sv`: `dma_set = at_svc`), so `arm_dma_busy` rises, and `svc_hold` (`svc_pend | pend_c == PC_SVC`) keeps it up (`daria_fe_copy.sv`, the `dma_busy` clear needs `!svc_hold`). Before this change nothing could release it: only `rdS_r` fires the action, `rdS_r` needs a later CALLFUNCTION write, and the 6507 is stalled by `arm_dma_busy`. That was a hang (`svc_hold` and `arm_dma_busy` stuck high). Now `pend_c` clears at `pclk1`, `svc_hold` falls, and `arm_dma_busy` falls at the next `rel_ok`: one stall cycle and no copy, where upstream does the copy. No bench here strands a service: `tb_fe_core`'s release epochs choose only the other actions, and that bench has no `u_copy`. Lane E3's random bench must cover it (the last section).

The pointer buffer (`wb_v`) cannot be stranded the same way. Its set at C needs a CDF fetch or jump, and those need `fpend` or `jr`, which `rst_fe` holds at 0. Its set by DSWRITE/DSPTR needs the action to fire.

### The set never meets the clear

Every set (`at_dsw`, `at_dsp`, `at_svc`, `s_set`, `commit & dpw`) contains `commit` = `access & a_in[12]`. `access` = `mapper_phi2 && arm_driver_run` (cart2600.sv:247), and `mapper_phi2` = `pclk0 && ...` (top.sv:327). The system's `pclk1` and `pclk0` are M6502C's `phi1_ce` and `phi2_ce` (top.sv:716-717), which are `phi1_en = pclk1 & ~in_phase2` and `phi2_en = pclk0 & in_phase2` (top.sv:1421-1422, 1434-1435). `in_phase2` is one bit, so the two are never high in one clock; a pause, a stall or a reset only removes `pclk0` pulses. So the set's priority over the `pclk1` clear never decides anything. That is the proof.

The stage-1 shadow checks it on the system's own phases: `commit_pclk1` (`fe_shadow.svh`, must be 0) counts a `u_fe` commit in a clock with `dut.pclk1` high. `tb_fe_core` also checks it on every clock ("commit in a pclk1 clock"), but there it cannot fail: its phase generator emits `pclk1` and `pclk0` in exclusive branches of one `if` (phase_gen.svh:292-304). It is kept as a sanity check of that bench only.

### No change outside a reset

Outside a reset every pending action has fired before `pclk1`; that is what `a_pend_late` checks, and it is 0 in every bench. The clear then never acts. The cost is one more term in four registers' next state.

**`rcyc`'s meaning (review).** The first version set `rcyc` while `rst_fe` was high and cleared it at the first `pclk1` with `rst_fe` low. After a reset whose last high clock was a `pclk1` clock (a release exactly at an E0, as the unit bench's scheme switch makes), it stayed 1 through the whole next cycle, whose reads all ran out of reset. `a_pend_late` was then not checked at that cycle's end, and the new clear could drop a late action there without a trace. The exact form costs nothing (synthesis removes `rcyc` with `a_pend_late`), so it is built. The masking still covers every release of `tb_fe_core`'s release epochs: each releases `cart_reset` in the `pclk0` clock of a cycle at E0+5 or later, so the edges E0+1 to C−1 had `rst_fe` high, and `rcyc` is 1 at that cycle's `pclk1`.

### Verification

- **`tb_fe_core`**, release epochs after the existing rotation (so the rotation's streams are unchanged): one DPC+ and one CDF epoch, each with 8 console resets released in the `pclk0` clock (its edge is C) of a cycle at E0+5 or later that commits an action waiting for a read. The stream alternates such accesses with plain ROM reads during the reset, so the release cycle is never followed by an access that would repeat the stranded action and hide it. The release cycle's latch and words are classified (`rrel`) and the DPC+ fetchers resynced from upstream; everything after it is compared as usual. Two checks were added by the review:
  - `rcyc` against its meaning, on every clock: a model kept apart from the RTL (the last edge with `rst_fe` high is later than the last `pclk1` edge), a must-be-0 class `rcyc`. It stays on in mutation runs (`+formula=0`), since `rcyc` switches `a_pend_late` off.
  - The release counter now shows a drop: a `pclk1` with `rcyc` before which actions were pending and after which none of them is ("dropped there"); "still pending after it" counts the rest. The first version's counter counted pending actions at such a `pclk1`, which the old RTL had as well. Every release must count one drop, and none may leave an action pending (a coverage minimum).
  - Default run (`run_unit.sh`): 16 releases (DFx reads 4, PUSH/WRITE 4, DSWRITE 3, DSPTR 5); 16 dropped at `pclk1`, 0 still pending after it; 2 latches and 15 words classified; **0 bad** (`rcyc` 0). The same with `POISON=1`.
  - The same bench with the old behaviour (the four mutants c29-c32 together, in a scratch copy): 0 dropped, 16 still pending; FAIL with `a_pend_late` (assert) 213, `state` 2,052, `ram` 162, `dout` 12, `aud` 12, `fix` 3, `grant` 1 (2,455 bad), and the coverage minimum fails.
- **Mutants** (`tb_fe_core_mut.sh`): c29 `pend_s` not cleared at `pclk1`, c30 `pend_c` not cleared, c31 `pend_r` not cleared (each `a_pend_late`), c32 `a_pend_late` without `!rcyc` (`a_pend_late` in the release cycle), and, from the review, c33 `rcyc` never cleared: with `rcyc` stuck at 1 `a_pend_late` is off for the whole run, and the first version's bench passed it; now the `rcyc` check catches it. The full script: **46 of 46** caught (lane A's 41 and c29-c33); c33 by the `rcyc` check (`rcyc got 1 exp 0`), c29-c32 by `a_pend_late`.
- **System:** `commit_pclk1` 0 in every stage-1 run (the directed suite in both builds, mode A).
- Every other bench and suite listed at the end.

### Area

1,667 → 1,671 ALMs (+4), registers 1,094 → 1,094, the same as the first version (synthesis of `daria_fe_probe` at commit c753c0c). `rcyc` is removed with `a_pend_late`, which nothing in the design reads: Quartus reports `a_pend_late` as assigned but never read (warning 10036), and the register count does not change.

## 2. `pause_lane`: not made exact

### What exactness needs

`al` would have to load, at every unpaused edge, what upstream's lane register loads: the low two bits of cart RAM port A's address (cart_ram_tdp.sv:61-64; `mapper_en` = `!pause`, top.sv:921), which is the 6507's `sel_ram_a` while `sel_ram_sel` is high and the engine's address otherwise (cart2600.sv:965-967). `sel_up` equals `sel_ram_sel` on every clock (A2). The 6507's byte address is the missing part.

Its value matters only at the last unpaused edge p before a pause in which a grant edge has the select low and its capture lands on the first unpaused edge. A grant needs the select low, so the select must fall between p and the grant. In a pause the bus and the scheme state are frozen, so it falls only through what changed at p itself, or through the ROM byte, which lags the address by one clock:

| Last unpaused edge p | Cycles | Upstream's lane at p | Available in `daria_fe` |
|---|---|---|---|
| `pclk1` (E0): the next address appears after it | DPC+ direct DFxDATA, DATAW, FRACDATA reads, PUSH, WRITE: selected to the cycle's end (dpcplus.md 12.1, 12.4) | the post-commit address: $C00 + the stepped counter or fractional (PUSH: the stepped counter − 1); with no commit (before the lock, a hidden repeat), the pre-commit address | yes: `W[1:0]`, `W[9:8]`, `W[1:0] − 1` after k[3]; `cl`, `ba` |
| C: the state changes there | DPC+ fast-fetch reads (`fpend` clears), CDF fetches and jumps, DSWRITE (selected only with `access`) | the pre-commit address | yes: `cl`; DSWRITE `W[21:20]` or `W[17:16]` (W holds P32 by C) |
| E0+1 | A CDF fast-fetch or fast-jump operand cycle whose first clock still shows an in-range byte in `rom_do` (cdf.md Q8): either the arming opcode under a covering fetch offset (a fetch: $A9, or $A2/$A0 with CDFJ+'s LDX/LDY options; offsets $7D-$A9), or, after an arming opcode on a hotspot ($1FF4-$1FFB; the bank switches at C in the commit that arms), the new bank's byte at that address, at any offset, on any revision (a fetch: in range and not the amplitude stream; a jump: a valid operand, $00, or $00/$01 on CDFJ and CDFJ+). The operand that follows is out of range, or the amplitude stream (`amplitude_fetch` reads no RAM, mapper_cdf.sv:111, 140-147), so the select falls at E0+1 | the select is high in (E0, E0+1) only. The address is $800 + the table lookup's output in that clock (registered at E0, arm_mapper_tables.sv:157-163): the pointer of stream 32, the index in the opcode cycle's last clock | **no**: no pointer of that stream is read in such a cycle |
| E0 (and E0+1) | A DPC+ `LDA #` whose $A9 opcode sits on a hotspot: the bank switches at C with fast fetch armed, and from C+1 the new bank's byte there makes the cycle a register read if it is below $28 (mapper_dpcplus.sv:113-115), and a RAM read if it is in $08-$1F: DFxDATA, DFxDATAW ($08-$17) or FRACDATA ($18-$1F) of fetcher (byte & 7) (mapper_dpcplus.sv:122-143). A byte in $00-$07 or $20-$27 (the random number, AMPLITUDE and the other function-0 reads; the flags) is a register read with the select low: no transient | $C00 + the counter (DFxDATA, DFxDATAW: lane `counter[1:0]`) or the fractional's [19:8] (FRACDATA: lane `fractional[9:8]`) of the fetcher that byte selects | **no**: that fetcher is never read |

The last two rows are transients of a stale ROM byte. They need a pause that starts on one particular edge, but they are reachable by ordinary code: on CDF, a fast-fetch `LDA #`/`LDX #`/`LDY #` or a fast JMP whose opcode sits on a hotspot (any revision, any offset), or a fast fetch under a fetch offset that covers its own opcode (CDFJ+'s offset option); on DPC+, a fast-fetch `LDA #` on a hotspot. Lane E3's random bench, which draws offsets and pauses anywhere, reaches them too. The review confirmed the CDF fetch form on a hotspot on upstream's `mapper_cdf` alone (revision 0, offset off: the select high for one clock on stream 32's lane, then low); the jump form is from reading the code only. There are two smaller gaps as well: `al` resets on `cart_reset` and upstream's lane register does not, and while upstream's `mapper_init_busy` is high its lane register loads only on `cartram_rd`/`cartram_wr`.

### The near-exact form and its cost

A prototype: `u_core` gives `cpu_lane`, upstream's lane for the first two rows (a one-flop "committed in this cycle" flag selects post-commit `W` lanes or pre-commit `cl`/`ba`/DSWRITE lanes), and `al <= sel_up ? cpu_lane : a_d[1:0]` at every unpaused edge. Synthesis: 1,671 → 1,683 ALMs (+12), one more register, and a new 3-bit input on `daria_fe_audio`. It would remove Note 1's case and every other non-transient one, but `pause_lane` would have to stay as a counted class for the transients.

The decision's own rule (its item 6) applies: no exact equivalent exists, and the near-exact one costs more than 5 ALMs. It was not built into the RTL; `pause_lane` stays counted. No port changed, so `interfaces.md` has no new entry.

### Why lane B saw 0

`tb_fe_audio` freezes its select stream one clock before the engines see `pause` (`pause` is `pause_pg` registered; the stream stops on `pause_pg`). So the select at the engines' last unpaused edge always holds through the pause, and the case cannot arise there. B-1's "unreachable" (B_audio.md 1.3) is a property of that model, not of upstream. Making the unit bench reach it would need the select to change at the engines' last unpaused edge: the next cycle's pattern after a `pclk1`, the post-commit pattern after a commit.

### The class as the benches count it (review)

The first version's `fe_shadow.svh` counted `pause_lane` at every grant edge in a pause (upstream's or `u_fe`'s) whose last unpaused edge had the select high: word grants and grants whose capture was still paused included, and whether or not the lanes differed. It then masked the whole A1 replica until the next resync. It now counts the case this section describes, and only it:

- **`fe_shadow.svh`** (mode A, the stage-1 shadow): a clock in which upstream's engine is in AUDIO_SAMPLE_CAPTURE and `u_audio` in SMCAP with `pause` low (the byte is read, not $FF), the clock before it was an upstream grant clock with `pause` high, `sel_ram_sel` was high in the last clock with `pause` low (`f1_sel_unp`), and the two lane registers differ (cart_ram_tdp's `mapper_read_lane` against `u_audio.al`). It masks only what that one byte writes: the sum and AMPLITUDE are left out of the replica compare, and the 6507's AMPLITUDE reads are counted as `amp_class`, until both registers agree again. The next refresh clears the sum and rewrites AMPLITUDE from new bytes, so no resync is needed; every other compare of A1 stays on throughout, and `mask_stuck` bounds the mask. Any other lane difference at an unpaused sample capture, with the replica in step, is `audio_bad` ("A1 lane"). The "FE masks:" line reports the check's exposure: the sample captures on an unpaused edge right after a paused grant, and how many of them had the select high.
- **`tb_fe_audio`** (lane B, comment changes only): a capture clock (upstream in SMCAP) with `pause` low right after a grant clock with `pause` high, with the select high at upstream's last lane load (`pause` low). It has no lane term, and it masks the replica until the resync. It never occurs there ("Why lane B saw 0"), and its count is only reported.
- **`tb_fe_rand`** (lane E3; not changed here): a capture clock with `pause` low whose last upstream grant had `pause` high, with the two lane registers differing. It has no select term, and it masks the A1 replica until the resync. The last section says what it needs.

Results: the six pause tests of the directed suite (`FLAVOR=s1` and `s1p`, commit c753c0c): `pause_lane` 0, `audio_bad` 0, every test passes. None of them reaches the class or the new lane check: their pauses end after a fixed length, and in each the "FE masks:" line shows 0 sample captures on an unpaused edge right after a paused grant.

A scratch experiment, not committed, did reach it: a copy of `fe_dir/fe_dir_mon.sv` with two more injections, a pause whose last unpaused edge is the `pclk1` that ends a cycle with `sel_ram_sel` high, and a pause end right after an upstream sample grant edge, both forced between two edges; and a test on the busy DPC+ program of the pause tests (8 frames). With a stage-1 build of this revision and that copy:

- 31 pauses; 31 sample captures on the first unpaused edge right after a paused grant, all 31 with the select high at the last unpaused edge; 23 counted as `pause_lane` (the other 8 had equal lanes);
- 9 AMPLITUDE reads counted as `amp_class`; the longest A1 mask 720 clk_sys, about one refresh: the sum and AMPLITUDE agreed again with no resync;
- `FE result: PASS (0 bad)`.

The only failures were in the stage-0 reference's RAM tap check, 31, one at each pause's first clock. That check compares port A's byte with its own model at the registered address, and does not model top.sv's $FF mask (top.sv:936) when the pause rises within a clock: a limitation of that tap check, not of `daria_fe`. Forcing the pause at a posedge instead, as the suite's existing pause injection does, races the blocks that sample `pause` at that edge. In that variant upstream's lane register and the shadow disagreed on which edge was the last unpaused one, and the new lane check reported it at every such pause (23 "A1 lane" `audio_bad`), so the check is live. A suite test of the class would need the between-edge injection, a stage-0 RAM tap check that models the pause mask, and a way to run the test in stage 1 only (the stage-0 snapshot that `FLAVOR=s0` builds cannot change). That is left to the lead.

### On the Pocket, and for a MiSTer port

**The Pocket never pauses the core.** `core_top.v:883` ties `pause_core` to 0. The Pocket reports its menu as `osnotify_inmenu`, and nothing uses that signal. `daria_fe`'s `pause` input is therefore always low on the Pocket, so `pause_lane` cannot occur there. Neither can `pause_call` (design 9.5), the paused cycles' $FF sample bytes, or anything else that needs `pause`. The owner decided (2026-10-08) that nothing is fixed here for the Pocket (`docs/DARIA_CORE.md`, decision 10). The benches still drive `pause`, because upstream has it and `daria_fe` is compared with upstream.

**Where it matters.** On a core that is paused while it runs: upstream MiSTer pauses with its OSD menu open, and the Pocket would if `osnotify_inmenu` were ever wired to `pause_core`. There, `pause_lane` is one audio sample byte, read from another byte lane of the same word, in the first refresh after a pause that started on the wrong edge (E3 note 1).

**The patch.** `F1_pause_lane_mister.patch`, in this directory, is the near-exact form above as a diff against the RTL of this revision (20 lines in `daria_fe_core.sv`, `daria_fe_audio.sv` and `daria_fe.sv`; regenerated after the review's comment changes, with the same added and removed lines):
- `u_core` drives `cpu_lane`: upstream's `sel_ram_a[1:0]`. The pre-commit lanes are `cl`, `ba[1:0]`, or DSWRITE's `W` lane; the post-commit lanes are `W[1:0]`, `W[9:8]`, or PUSH's `W[1:0] - 1`. A one-flop "committed in this cycle" flag `cm` chooses between them.
- `u_audio`'s `al` loads `sel_up ? cpu_lane : a_d[1:0]` at every unpaused edge.

It applies cleanly (`git apply --check`) and the patched tree passes the lint of `interfaces.md` section 2; its synthesis was the 1,683-ALM figure above. **It has not been simulated.** A port that applies it must verify it:
- the unit benches;
- a `tb_fe_audio` scenario whose select changes at the engines' last unpaused edge (see "Why lane B saw 0");
- the mode-A shadow with pauses.

With it, `pause_lane` still counts the transients of the table's last two rows, and nothing else outside these transients and `short_phase1`: the patch's pre-commit lanes use `cl`, which loads at the end of k[2], and DSWRITE's `W` lane, which is there only with `rdP`, so with C before E0+6 `al` can load a stale lane at p = C. The patch adds a port to `daria_fe_audio` (`sel_up`, `cpu_lane`) and one to `daria_fe_core` (`cpu_lane`), so `interfaces.md` needs the entry that decision 2 would have made.

### Documents

`design.md` 5.2 (`al`'s rule as built, B-1), 5.3 (`al`'s row: load enable `!pause`, reset `cart_reset`), 5.8 (why the select can fall after the last unpaused edge; the class's condition) and 9.5 (`pause_lane`: the stage-1 shadow's condition, which the other two benches widen as above); `B_audio.md` B-1 and its note for lane E; the comments of `daria_fe_audio.sv` and `tb_fe_audio.sv`.

## 3. `obus_ffe`: the open bus after a fast JMP's operand at $1FFF

### Change

`sim/bupchip/daria/fe_shadow.svh`, O1: an `obus_exposed` counts as the class `obus_ffe` instead when all of these hold:

- its read is the TIA read at $0000;
- the immediately preceding latch was a shown read at $1FFF that upstream substituted as the first (low) operand of a CDF fast JMP: `jump_substitute` with `jump_remaining` 2, so the JMP's opcode is at $1FFE;
- the values are the ones this case leaves: the undriven bits (`~tia_DB_oe`) of `u_fe`'s rebuilt bus equal the byte `u_fe` latched at $1FFF, and those of `read_DB` equal ROM[$1FFF] in the bank in use.

The predecessor flag clears whenever the checks are not live (a console reset, until the next live `pclk1`). Every other `obus_exposed` is still must-be-0. `obus_ffe` is in the "FE classes:" line and in `fe.csv` (after every older counter).

`sim/bupchip/daria/fe_dir/`: `dircheck.py` accepts a requirement `cls:<class>` on a stage-1 counted class (skipped in stage 0); `cdf_jump_ffe` requires `cls:obus_ffe == 5`; `summary.py` prints it, with the value of the first stage-1 set given ('-' if none is), in both of its Events forms. `obus_exposed` stays in `dircheck.py`'s must-be-0 list.

### Why

On a fast JMP whose opcode is at $1FFE, the low operand is substituted at $1FFF and the high operand is read from $0000 (TIA), whose D5-D0 are not driven. Upstream's `d_out` falls back to ROM[$1FFF] after the commit, `daria_fe`'s `fe_do` holds the substituted byte. On hardware the undriven lines most likely keep the cartridge's last driven byte, which is `daria_fe`'s value. The 6507 then jumps to the target, so exactly one read is exposed. No game does this. The RTL is unchanged.

**Why only that case (review).** The first version also counted a CDF `fetch_substitute` at $1FFF (a fast `LDA #`/`LDX #`/`LDY #` at $1FFE) and a DPC+ `register_read` there (a fast-fetch `LDA #` at $1FFE). Those are not the accepted case. After such an operand the next opcode comes from TIA $0000, and every opcode's second cycle reads $0001, also TIA and partly driven, so the difference is exposed again at $0001: the class would have relabelled only the first of two or more exposed reads. E2_directed.md 6.1's "would expose the same way" was wrong on this point. `jump_remaining` 2 also leaves out a JMP at $1FFD, whose high operand is the one at $1FFF: its next read is an opcode at the jump target. The first version did not check the values either, so a change of `fe_do` between C and the address change would have been counted too.

### Verification

- `cdf_jump_ffe` (stage 1): PASS in `s1` and `s1p`, `obus_ffe` 5, `obus_exposed` 0.
- The fast `LDA #` analogue, `cdf_lda_ffe` (a review's scratch test: CDFJ, `A9 00` at $1FFE in bank 3, stream 0 bytes $C5 then $00; upstream's 6507 runs BRK from $0000, reads $0001, takes the vector, whose high byte at $1FFF is again a stream fetch, and lands in a zero-page routine). The suite has no expected-fail mechanism, so it is not in `tests.py`; it was run in a scratch copy with the stage-1 binary of this revision: FAIL as it must, `obus_exposed` 10 (the reads at $0000 and at $0001 in each of 5 frames: "read_DB 00, with daria_fe's bus 05"), `obus_ffe` 0. The first version counted the $0000 reads as `obus_ffe` and failed on the $0001 reads alone (`obus_ffe` 5, `obus_exposed` 5). Its `cdf_jump_ffe` image is byte for byte the suite's.
- No other test of the suite shows `obus_ffe`.

### Area

None (bench only).

## What lane E3's random bench needs (not changed here: `fe_rand/` is lane E3's)

- **Decision 1.** With `+rst_bus=1`, a release cycle that commits a DFx read, PUSH/WRITE, CALLFUNCTION 1/2, DSWRITE or DSPTR still differs in that one access: `daria_fe` drops the action, upstream does it. `a_pend_late` stays 0 there (no exemption is needed). The bench must count that cycle as design 9.5's `rst_release` (condition: `rst_fe` fell after k[3] of a cycle whose commit set `pend_c`, `pend_s` or `pend_r`; visible as `u_core.rcyc` with a pending action at `pclk1`) and resync from upstream after it: the fetcher's state RAM words (DPC+), the DSWRITE byte and the P32 word in cart RAM (CDF), and the latch of that cycle. No stray write may follow: any later C1/C2 or RAM difference is a failure. `tb_fe_core`'s release epochs do exactly this (`rrel`), but they never strand a service. The resync must also cover a CALLFUNCTION 1/2 in the release cycle: `daria_fe` drops the service (no copy or fill; `arm_dma_busy` falls at the next `rel_ok`, one stall cycle), upstream performs it. So the copy's destination range in cart RAM, upstream's `service_pending`, and the stall shape (the held cycles and `arm_dma_busy`) differ, and the bench must take them from upstream and expect no copy from `daria_fe`.
- **Decision 2.** Its `pause_lane` condition is not the exact one: it has no select term, so it counts and masks any lane difference after a paused grant, whatever produced it, and cannot fail on an `al` defect that shows only there (the `!pause` gate removed, design 5.3's old rule, a `cpu_lane` bug from the MiSTer patch). The bench should record `sel_ram_sel` at the last clock with `pause` low, count `pause_lane` only when that bit is 1 and the lanes differ, and treat any other lane difference as a failure, as `fe_shadow.svh` now does.
- **Decision 3.** Nothing: the random bench has no O1 check.

## Verification summary

All on commit c753c0c (the RTL and benches of this revision; this text and the regenerated patch came after it and change no source), each binary rebuilt from it.

| Check | Result |
|---|---|
| `run_unit.sh` | 10 of 10 pass |
| `run_unit.sh`, `POISON=1` | 10 of 10 pass |
| `tb_fe_core` (in both) | 16 releases, 16 dropped at `pclk1`, 0 still pending; 0 bad (`rcyc` 0) |
| `tb_fe_core_mut.sh` | 46 of 46 caught (lane A's 41, c29-c33) |
| `tb_fe_audio_mut.py` | 64 of 64 caught, 1 equivalent (as lane B's) |
| Lint (`interfaces.md` section 2) | clean; also with `F1_pause_lane_mister.patch` applied (`git apply --check` clean) |
| `fe_dir/run_dir.sh`, `FLAVOR=s1` | 50 of 50 pass. `cdf_jump_ffe`: `obus_ffe` 5. The six pause tests: `pause_lane` 0, `audio_bad` 0. `commit_pclk1` 0 in every test |
| `fe_dir/run_dir.sh`, `FLAVOR=s1p FE_POISON=1` | 50 of 50 pass; the same counts |
| `cdf_lda_ffe` (scratch, stage 1) | FAIL as it must: `obus_exposed` 10, `obus_ffe` 0 |
| Mode A, `FE=1`, 60 frames | Galagon (CDFJ): `FE result: PASS (0 bad)`, every must-be-0 count 0, `commit_pclk1` 0, 119 calls. SF2fix (DPC+): the same, 61 calls. `pause_lane` and `obus_ffe` 0 in both |
| Quartus synthesis, `daria_fe_probe` | 1,671 ALMs, 1,094 registers (before F1: 1,667, 1,094); `rcyc` synthesizes away |
