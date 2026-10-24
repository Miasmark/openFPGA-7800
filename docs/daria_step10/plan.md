# DARIA step 10: after 2.2.1, the plan (Rev 0 and the next release)

Written 2026-10-19 for the owner, on `DARIA-dev` with the tree of `04a0e69` (2.2.1 and the documents of PR #7). It revises the order of work that the design study of 2026-10-18 proposed, after the study's follow-up on Spiders. The owner approved Rev 0 on 2026-10-19: "Okay. start rev 0."

**Status, 2026-10-19.** Rev 0 is under way. It ships no release bitstream. The `src/` freeze of 2026-10-16 stayed until decision 1, which lifted it when work resumed on 2026-10-20 at 19:01 ET. The candidate CPU and the test builds live in scratch worktrees and saved patches, not in the repository. Rev 0's results are recorded beside this plan when it ends ([rev0_record.md](rev0_record.md), 2026-10-23). (2026-10-20, after decision 1, as next-release work: decision 11's hold fix is in `src/` (section 4, "The trial"; release work for F′); the overlay (A2) is in `src/`, `BUP_DEBUG` only (`0d9ce33`), with its check fixed in `5d5d591` and the review's findings closed after it (3.0 item 1).)

**Paused, 2026-10-19.** The owner: "Halt, record commit. Pause". All runs were stopped. **Work resumes on 2026-10-20 at 19:01 ET**, and `src/` unfreezes then (decision 1). Where Rev 0 stands:
- **Done and reviewed:**
  - G1's fit tools (section 10);
  - the Harmony model as a bench option, its tools and `docs/HARMONY_MODEL.md` (3.2);
  - this plan and Rev 0's documents (3.0 item 8).
  The review of these commits found no major issue. Its fixes for the step-7 plan's pointer to section 10, the smoke test's run times and item 8's done marks are in.
- **Done in scratch, not in the repository:**
  - the status overlay (A2);
  - the ÷18 debug build of the candidate and the ÷19 control build, each fitted on seeds 1-3 with at least one seed passing P29;
  - Spiders in simulation on the ÷18 debug build (0 late calls on the overlay's counter, the guard locked, 0 unlocks);
  - `s4/check.sh`'s DARIA set at 38.18 MHz;
  - `THUMB=1 s1/check.sh` with the firmware: PCM identical to MiSTer's on songs 13, 14, 9 and 30; song 13's CPI 1.4208, +2.73% over the 1.383 gate (information for decision 10).
  The two test builds and the owner's session checklist were given to the owner on 2026-10-19.
- **Open when work resumes:**
  - the review's remaining findings, none of them in the repository's commits: the whole-core overlay check can pass while checking no cell (the overlay is still in scratch; fix it before it lands in `src/`; **closed on 2026-10-20 in `5d5d591`** on branch `rev1/overlay`, the commit after the overlay's own `0d9ce33`, with `src/` the same in both: the overlay landed with the old check and the fix followed it; 3.0 item 1), and a few notes on scratch records. The checklist's Start/Reset wording and the three `docs/HARMONY_MODEL.md` nits were fixed before the pause (the nits in `dc1e882`);
  - Rev 0's three branches and this record are merged into `DARIA-dev`;
  - the hold fix trial of section 4 (decision 11), started and stopped before it ran (it ran and passed on 2026-10-20: section 4, "The trial");
  - the owner's session (3.0 item 5).

**Changes since the owner's approval, marked in place:**
- Decisions 6 and 13 are settled by the owner's words of 2026-10-19 (section 6).
- 3.0 item 8: `lint_step7.sh`'s missing AtariVox sources are done by the owner's own commit `6e2e880`. B8 waits for the release, because `POCKET_CHANGES.md` is under `src/`.
- Section 10 carries the amendment of step-7 plan 5.4 for G1, from Rev 0's fit-script lane.
- Decision 16 is settled yes by the owner's words of 2026-10-21: the campaign runs from a fresh clone (section 6).
- Decision 9 (`virtual_axis5`) is settled yes, and decision 15 as one shared `fa2.sav` for the time being, by the owner's words of 2026-10-21 (section 6).
- Decisions 7, 8 and 10 are settled by the owner's choices of 2026-10-21 (one release; MR in `ap_core.qsf`; accept R1's cost and the amended CPI gate), and decisions 2 and 3 proceed on the owner's direction of that day to land ÷18 for the release before the Rev 0 session, which still has to confirm them on silicon (section 6). The owner also chose to land the minimum first (the CPU, MR and ÷18, with ÷18 as its own commit), with one non-DARIA reference at F′.
- Decision 5 is settled by the owner's words of 2026-10-21 (no Harmony cartridge; the model is the evidence), and with it decision 4 for Spiders (section 6). 3.0 item 9 and 3.3 (the real-Harmony check) will not run.
- Section 4 gains "The trial" (2026-10-20), and decision 11's row says the trial passed and the fix is in `src/`. The fix landed after decision 1 lifted the `src/` freeze (2026-10-20 at 19:01 ET), as release work for F′. Also in section 4: the Rev 0 round's +0.1 ns margin is worded as a margin on (h) hold, "Its gates" names V-rtl as well as the `sram_ctrl.sv` row of 7.6, and any ÷19 bitstream built after the fix re-runs seeds 1-3 before a seed is chosen.
- 3.0 item 1: the overlay (A2) landed in `src/` on 2026-10-20 (`0d9ce33`), after decision 1, for the next release and `BUP_DEBUG` only, so Rev 0 no longer keeps it in scratch. The paused record's finding on its check is closed (`5d5d591`), and so are the findings of that branch's review. A debug bitstream from `DARIA-dev` now carries decision 11's copy too, so it is a new tree and needs its own Q5 under P29 (3.0 item 1).
- Decisions 2 and 3 are settled by the owner's Pocket session of 2026-10-21 on the RC debug build (section 6), and Rev 0's results are recorded beside this plan in [rev0_record.md](rev0_record.md) (2026-10-23). The session ran on the ÷18 tree before the merge of 2.2.2; the merged tree's V-hw is still owed (3.1, "The merged tree's round").
- 3.1 gains a progress block (2026-10-21): what has landed for the release and on which commits, and what is still to come. The owner's seed ruling of 2026-10-21 is recorded in the step-7 plan's P12, and decisions 4 and 5's `ontime` rule in its P13.

**How this plan came about**
- The owner asked on 2026-10-17: "How would we go about trying to improve Daria at this point? Space and logic is rather full."
- The design study (2026-10-18) measured 2.2.1's area and timing, ran four trials (T1-T4) and costed every item. It proposed four revisions, Rev 0 to Rev 3, and a list of owner decisions.
- It left one conflict. The front end's shared-edge guard locks only at ÷18, but ending Spiders' 16 late calls needed ÷17 or S3.
- A follow-up on Spiders (2026-10-18) found one more CPU change, L1W+L3, that ends them at ÷18. It also ran a model of the Harmony cartridge's chip on the same calls.
- This plan replaces the study's order of revisions and its list of decisions (the study's sections 7.3 and 7.4). A verifier reviewed it before the owner saw it. All 39 issues raised were fixed; none was rejected.

**Evidence.** The design study, the follow-up and their runs are scratch, not in the repository. This plan names that evidence by what it is: a fit, an RTL bench run, a whole-core simulation or a model. Repository documents are named by path. Nothing derived from games goes into the repository. This plan carries only per-call shares and counts, in the form the other documents already use.

**Labels**
- **[measured: source]** comes from a fit, a run or an RTL bench.
- **[estimated: method]** is arithmetic or judgement.
- **[planner's choice]** marks a threshold or option the plan's author picked. It is not a rule of this plan.

**Terms**
- **÷18** is `clk_arm` = VCO/18 = 38.18 MHz. **÷19** is VCO/19 = 36.17 MHz, the divider 2.2.1 ships. **÷17** is VCO/17 = 40.43 MHz.
- **S1** and **S3** are CPU pipelines (`docs/BUPCHIP_CORE.md`, "Decision"). S1 is today's core: each instruction executes in one clock. S3 adds a second register-file write port, so a load's data reaches the next instruction a clock earlier.
- **The study's trials:** T1 is MR alone at ÷19. T2 is ÷18 with MR, G1 and five CPU cures. T3 is the five virtual axes as one engine. T4 is S3's register file, fitted alone.
- **MR** is `MUX_RESTRUCTURE ON` on 13 `clk_sys`-domain entities: 13 qsf lines, no RTL.
- **G1** sets the guard pair `pd_tog` → `pd_rx` to [0.5, 8.0] ns in `daria_constraints.sdc`, with 7.5 ns asked of the fitter alone. Today's pair is [1.0, 6.0] ns, with 5.5 ns for the fitter.
- **T2's cures** in `bup_cpu.sv`:
  - R1 registers the shifted operand. ARM add and subtract forms with a shifted register take one clock more, and so do loads and stores with a scaled register offset. Thumb never takes the extra clock.
  - R12 decides the one-clock store from the base register's top bits, without the store's own adder.
  - R13, R14 and R2 restructure the adder's controls, the operand mux and the write-data mux.
  - R1 and R12 are gated by `THUMB`, so the build without DARIA keeps its clocks. R13, R14 and R2 apply with `THUMB` 0 too.
- **L1W** makes an aligned Thumb word load from the window or the cart RAM take 1 clock instead of 2. The word goes straight into the next instruction's register reads. **L3** takes one clock off Thumb LDMIA and POP without PC. Only Thumb state changes.
- **v4** is the L1W+L3 RTL on T2's tree (`bup_cpu.sv` md5 `4f224fbf`). **T2's tree** is `4fd89ef` + MR + G1 + T2's cures. **The candidate** is T2's tree + v4, with its bench additions.
- **Fits** (step-7 plan 4.3): Q2 is the release build on seeds 1-3, Q4 the build without DARIA, Q5 the `BUP_DEBUG` test build on seeds 1-3, Q-mut the STA mutant fit.
- **Item labels** come from the study's costing:
  - A1 is a shared-edge guard that works at ÷19, and A2 the DARIA status overlay (both in `docs/IMPROVEMENTS.md`). A3 is the PAL 50 Hz session. A5-A8 are built on demand (section 8). A9 is the aligned audio run as a gate (`docs/IMPROVEMENTS.md`, "Audio in the frame gate").
  - RTL-1, RTL-2 and B3-B8 are the items of `docs/IMPROVEMENTS.md`, "After 2.2.1: RTL-1 and the `src/` clean-ups": B3 is its item 3, and so on to B8.
  - C5 is Star Castle Arcade's FA2 saves (`docs/IMPROVEMENTS.md`). D1 is the lean audio engine and D2 its audio levers. D4 and D7 are small area cuts in `bup_cpu`.
- **P-numbers** (P10-P29) and **"plan 5.x" or "plan 7.x"** are the [step-7 plan](../daria_step7/plan.md)'s.
- **COST's principles** are the study's costing rules for bundling. Principle 3: build the audio gate before the audio path or call timing changes. Principle 4: keep the CPU unchanged in the revision that changes area settings, so that a failure points at one cause.
- **Gate sets** (the study's costing, from plan 7.6):

| Set | When | What runs |
|---|---|---|
| V-doc | documents only | `sim/check/hygiene.sh` |
| V-cmt | a comment-only edit under `src/` | `pp_equiv.py`'s hashes unchanged on both macro sets; SDC and qsf diffs empty without comments |
| V-dbg | a change seen only under `BUP_DEBUG` | Q5 and `s4/check.sh` |
| V-bench | benches, checkers, generators | the checkers' `selftest.py`; `fit_selftest` for the fit scripts; the smoke test for `step7_report.tcl`, `f3_crossings.txt`, `daria.qip` and `daria_sync.tcl`; the new bench's own runs |
| V-hw | nothing in the tree | an owner session on a Pocket |
| V-qsf | a qsf, SDC or assignment change, with no RTL | a new Q2; the smoke test or `fit_selftest` where those files change |
| V-rtl | RTL outside DARIA | `run_sim.sh`, `extra_tests.sh`, `s4/check.sh`, `pp_equiv.py`, a new Q2, and Q4 with a new non-DARIA reference |
| V-daria | DARIA RTL | V-rtl, mode B with the wrapper, plan 7.3's integration checks, the full frame gate, and the step-7 fit set (Q2, Q5, Q-mut). A c76: about 40 h of wall time [measured: `docs/daria_step7/record.md`] |
| +cpu | also `bup_cpu.sv` | `s1/check.sh`, `aria_equiv.sh`, the Thumb suites, the call and modes suites, the songs |
| +div | a new divider | the `divider` gate, and every simulation gate on the new lattice |
| +fe | also `daria_fe*.sv` | step 6's quick benches |

**Contents**
- Summary
- 1. What the Spiders follow-up changed
- 2. The study's items, one by one
- 3. The revisions: 3.0 Rev 0; 3.1 the next release; 3.2 the Harmony model; 3.3 a real-Harmony check
- 4. The `sram_ctrl` hold path
- 5. Open technical risks
- 6. The owner's decisions
- 7. No longer needed
- 8. On demand, and later
- 9. Calendar at a glance
- 10. Step-7 plan 5.4 amended for G1

---

## Summary

1. **The study's main conflict is gone.**
   - The study found that the guard wants ÷18, while ending Spiders' late calls wanted ÷17 or S3. One more CPU change fixes that.
   - L1W+L3 makes aligned Thumb word loads take one clock. On top of T2's ÷18 cures, it brings Spiders' worst call from 104.05% to **89.33%** of its budget at ÷18, with **0 late calls in 1,399** [measured: RTL].
   - The guard locks, and frames 557-572 stay normal 262-line frames [measured: whole-core simulation].
2. **The owner's rule settles the MiSTer question for Spiders, if the chip model is accepted.**
   - The rule (2026-10-18): "if the real chip meets the calls but the mister does not, I would rather go with the chip."
   - The modelled Harmony meets these 16 calls at 91.6-92.0% of budget. MiSTer misses them at 109.8% [measured: model / bench].
   - The model is written from NXP's manual and has never been checked on silicon. Whether it is enough evidence is the owner's call (decision 5).
3. **÷18 becomes the recommended divider.**
   - The owner chose ÷19 for the first release on 2026-10-12, so changing it is the owner's decision, after Rev 0's Pocket session (decision 3).
   - No longer needed: the ÷17 trial, the CPI pricing (done), the ÷19 guard (A1, unless ÷18 fails on a Pocket) and S3 (the old Rev 3).
4. **Rev 0, now, with no release.** Approved by the owner on 2026-10-19.
   - **The session.** A ÷18 debug build of the candidate core with the status overlay, for one Pocket session. It should show:
     - the guard locked;
     - Spiders with no picture shift (2.2.1 in the same session shows the shift and serves as the control);
     - the BupChip and Turbo running at 38.18 MHz;
     - the PAL 50 Hz test, in the same session.
   - **G1's fit-script changes** land before any ÷18 fit. This is bench work under `sim/`, so every ÷18 fit is judged by the tracked tools.
   - **The BupChip firmware check** runs on the cured core. It measures R1's real cost.
   - **The hold failure.** Rev 0 tries to find the cause of, and a fix for, the one hold failure in the cart-SRAM controller. The fix lands in the release.
   - **The Harmony model** goes into the repository as a test-bench option, with the scope of 3.2 (decision 6, settled 2026-10-19).
5. **Then one release (recommended).**
   - It joins the old Rev 1 (about 1,300 ALMs freed, the RTL-1 fix, Star Castle's saves) with Rev 2 (÷18, T2 + L1W+L3, the documents).
   - It needs one full verification campaign: about 8-11 calendar days after Rev 0 [estimated: arithmetic in 3.1].
   - Two releases instead would take about 9-14 days with Rev 2's development overlapping Rev 1's campaign, or 11-17 days back to back [estimated].
   - Merging saves one V-daria, about 2 days [estimated: the study's costing].
   - Against merging: COST's principle 4, and the fact that a ÷18 failure would hold back Rev 1's fixes (3.1, "One release or two").
6. **Conditions before that release:**
   - One of six fit seeds fails a hold check in `sram_ctrl`. Rev 0 tries a fix. The release needs every hold ≥ 0 and (h) passing on seeds 1-3 of the combined tree, or the owner accepts a seed rule.
   - No DARIA build has run at ÷18 on a Pocket yet.
   - The chip model comes from the manual, not from silicon. Running Spiders on a real Harmony on a 2600 would be a cheap check. It is best done before the campaign.
7. **Decisions** (section 6):
   - **Taken on 2026-10-19:** Rev 0, with the scope of the Harmony commit (decision 6); A9 deferred (decision 13).
   - **Open now:** decision 5 (is the chip model enough evidence). It can be answered now and is needed before the campaign.
   - **After Rev 0:**
     - unfreeze `src/` (1);
     - adopt L1W+L3 (2);
     - the divider (3);
     - one release or two (7);
     - R1's cost, once measured (10);
     - fix or seed rule for the hold path (11);
     - and the rest of section 6.

---

## 1. What the Spiders follow-up changed

| Fact | Before (study, 2026-10-18) | Now |
|---|---|---|
| Spiders' worst call at ÷18 | 104.05%, 16 late [measured: T2, RTL] | **89.33%, 0 late of 1,399**. The 16 calls take 87.98-89.33% (88.06-89.40% end to end) [measured: RTL] |
| Spiders at ÷19 | 109.8%, 16 late | 94.29%, 0 late [measured: RTL cycles; v4 not fitted at ÷19] |
| Qyx's worst call at ÷18 | 92.2% [measured] | 85.86% [measured: RTL] |
| Spiders' frames 557-572 | MiSTer, and 2.2.1 at ÷19: 354 lines [measured: c76]. T2 at ÷18: not run | At ÷18 with v4: 262 lines. Each of the 16 calls has +3,696 `clk_sys` of slack (MiSTer: −1,776) [measured: `tb_frames`, whole core] |
| Guard at ÷18 | Locks (T2, mode B, one run) | Mode B on Galagon at ÷18 passes: guard locked at edge 16, 0 unlocks. The Spiders frame run also shows 0 unlocks [measured: mode B; frame run] |
| `clk_arm` at ÷18 | T2: +2.403 / +2.464 / +2.298 ns | v4 on seeds 1-6: +1.963 / +1.923 / +2.645 / +2.088 / +2.367 / +1.905 ns. Q5 seeds 1-3: +2.654 / +1.749 / +1.656 ns [measured: fits] |
| Hold | T2: two hold results unexplained | T2's two are still unexplained, and T2's netlists will not ship. v4 release build, seed 3: −0.503 ns on `sram_ctrl` `t_wr_q` → `t_last[17]` (`clk_sdram`). Seed 6 passes the same check by only +0.040 ns. The other four seeds pass. All v4 Q5 holds are ≥ 0 [measured: fits] |
| Area | T2: 14,903-14,927 ALMs | v4: 14,941-14,956 ALMs, 80.8-80.9% of the device. `bup_cpu` is 2,039-2,063 ALMs with 595-598 registers. M10K and DSP use do not change [measured: six fits] |
| BupChip (ARIA firmware) | R1 costs +3.08-3.18% CPI [measured: model, T2] | Unchanged by L1W+L3, which is Thumb only. ARIA's `THUMB` 0 core is proven equivalent to `806dcd4` [measured: `aria_equiv.sh`]. The firmware PCM check with `THUMB=1` has not run on the cured RTL |
| The chip | Not modelled for Spiders | Harmony model (70 MHz, MAM mode 2, MAMTIM 4): 91.6-92.0% of budget, and 0 of 20,984 calls late on seven images. DARIA ÷18 v4 takes 0.959-0.973 of the chip's time on the 16 calls [measured: model; RTL over model] |

---

## 2. The study's items, one by one: what changes and why

### Rev 0 (study: "now, no new release bitstream")

| Item | Study | Revised | Why |
|---|---|---|---|
| A3, PAL 50 Hz session | Rev 0, on 2.2.1 | **Keep.** Run it in the same Pocket session as the ÷18 debug build, on both bitstreams | The image exists. On the ÷18 build the retune also tests the guard's relock |
| A9, audio in the frame gate | Rev 0, before any change to call timing | **Deferred** (decision 13, settled by the owner on 2026-10-19) | See "A9 in detail" below the table |
| A2, overlay as a ÷19 debug build of 2.2.1 | Rev 0 | **Optional.** It is the only positive control for the late-call counter on hardware: Spiders should read 16 at about 9 s | At ÷18 the candidate has no late calls anywhere, so only the ÷19 build can show that the counter works. It costs about 1 h of fits [estimated: 3 Q5 fits at 18.4-20.4 min] |
| ÷18 debug build of T2's tree | Rev 0 | **Changed:** build it from the candidate (T2 + L1W+L3) with the overlay, after G1's fit-script changes | One session then shows the guard lock, Spiders without the shift, and the BupChip and Turbo at 38.18 MHz |
| Two `KEEP_DB=1` refits for T2's holds (+0.027 ns on T2's seed 1; −0.557 ns on T2's Q5 seed 2) | Rev 0 | **Drop.** Replace them with the `sram_ctrl` cause-and-fix round (section 4) | See "The T2 hold refits" below the table |
| ÷17 trial (script changes + 3 fits) | Rev 0, prerequisite of the divider decision | **Drop** | L1W ends the late calls at ÷18 [measured: RTL]. At ÷17 the guard would be inert [estimated: PLL edge lattice] |
| Model pricing of CPI cuts short of S3 | Rev 0 | **Done** (in the follow-up: a profiler, two designers and a judge). L1W+L3 was chosen, built and measured | The judge priced every candidate. L1W's cycle rule matches the RTL exactly on 5,595 calls [measured] |
| B8 and stale lines (`docs/ATARIVOX.md`'s rubyQ row, `IMPROVEMENTS.md`'s PAL image, `README.md:229`'s `clk_sdram`) | Rev 0 | **Keep**, plus `lint_step7.sh`'s missing AtariVox sources. *Since the approval:* B8 waits for the release (its file is under `src/`), and the `lint_step7.sh` fix is the owner's `6e2e880` | Unchanged |
| *(moved)* G1's fit-script changes (`step7_report.tcl`, `step7_checks.py`, plan 5.4, `fit_selftest`, smoke test) | Rev 2's V-bench | **Rev 0, V-bench, before any ÷18 fit** | See "G1's fit scripts" below the table |
| *(new)* `THUMB=1 s1/check.sh` with the firmware, on the candidate | — | **Rev 0** | R1's BupChip cost is a model figure. The check takes 5-9 min [measured: the study's costing], and Rev 0 already links the firmware for `s4`. It measures song 13's CPI, the new reference, before decision 10 |
| *(new)* The Harmony model into the repository | — | **Rev 0, bench only** (section 3.2), with the scope of decision 6 | The owner asked to start using it as the reference |
| *(new)* Spiders on a real Harmony | — | **Optional owner check, best done before the campaign** (section 3.3) | A cheap check of the model at the one point that matters. Its outcome can change a campaign gate |

**A9 in detail**
- Deferring A9 reverses the study's rule: build the audio gate before the audio path or call timing changes (COST's principle 3). The Spiders result did not make A9 unnecessary.
- The merged release changes call timing on every image:
  - ÷18 shifts every call release;
  - L1W cuts 6.6-11.7% of the clocks against T2 on the five images run [measured: RTL].
- Without A9 the campaign gates no whole-core audio content:
  - Under V1 the frame gate only counts audio.
  - P13 records that the frame gate cannot tell a planted audio fault from a correct build.
  - The audio-path evidence is mode A's and mode B's per-access comparison: every audio read and refresh compared by value, in the wrapper, on three images × three offsets.
- Why the plan recommended deferring:
  - A9 costs 1-3 days plus about 35 h of runs (12-17 h wall) [estimated: the study's costing].
  - It needs CDF tick-phase matching, which does not exist yet.
  - The release touches neither `daria_fe` nor its audio engine.
  - The owner declined a one-off aligned run on Gorf on 2026-10-15.
- **Settled 2026-10-19 (decision 13).** The owner: "if deferring the audio check allows the testing to go faster then yes, skip over it at this time." A9 is built later, with D1/D2 or on a reported audio problem (section 8).

**The T2 hold refits**
- T2's two hold results remain unexplained. They matter less now only because T2's netlists will not ship.
- v4's Q5 seeds 1-3 all have hold ≥ 0 (+0.094 / +0.096 / +0.113 ns) [measured]. T2's Q5 seed-2 failure (−0.557 ns, `clk_sys`) did not recur, but its cause is unknown.
- If a Rev 0 debug fit fails a hold, it is named with a `KEEP_DB=1` refit before that seed is used.
- v4's own failing hold is named (section 4).

**G1's fit scripts**
- Under G1, the tracked scripts fail (a), (b), (k) and (e) on every ÷18 fit by construction [measured: the trial's 16 fits].
- (b) and (k) are `step7_report.tcl` checks. A fit made before the scripts change can be judged again only from its database or by a refit (plan 7.6). *Since the change (section 10):* the new `step7_checks.py` judges (b) and (k) again from a fit's own report files, so no refit is needed.
- The scripts live in `sim/`, outside the `src/` freeze.

### Rev 1 (study: "next release, ÷19, no CPU change")

| Item | Revised | Why |
|---|---|---|
| MR, T3's `virtual_axis5`, RTL-1, RTL-2, B5, the FA2 saves (C5), B4, B6 | **Keep.** Recommended merged with Rev 2 into one release at ÷18 | See "The merge, in short" below the table, and 3.1 ("One release or two") for both sides |
| B3, the `core_constraints.sdc` header comment | **Keep, reworded** (V-cmt, after the fits) | At ÷18 the line "meet clk_sys's only every 3 clk_sys" is right again. But the counter[3] line ("VCO/19, 36.17 MHz, with DARIA") goes stale. It becomes VCO/18, 38.18 MHz |
| B7, `pll_core.v`'s display-string comment | **Absorbed** by the ÷18 PLL change (P10 regenerates counter 3's lines) | |
| D2, audio levers 1-2 (optional) | **Not recommended now** | Area is not binding: about 78.6-78.7% with T3 [estimated: v4's 14,941-14,956 ALMs minus T3's −408.5] |
| A9's audio gate in the frame runs | **Deferred** (decision 13, settled 2026-10-19) | See Rev 0 |

**The merge, in short**
- The study gave two reasons for two releases: the guard's lock had been shown only in simulation, and T2's two hold results were unnamed.
- Rev 0's ÷18 session answers the first.
- T2's two hold results are still unnamed. They are moot because T2's netlists will not ship.
- v4 adds a new hold failure. It is named, but has no fix yet (section 4).
- What remains against merging:
  - A ÷18 failure in a merged campaign would hold back Rev 1's fixes (the study, 7.3).
  - COST's principle 4: keep the CPU unchanged in the revision that changes area settings.

### Rev 2 (study: "the divider the owner picks; T2's cures, G1")

| Item | Revised | Why |
|---|---|---|
| T2: R1, R12, R13, R14, R2 | **Keep** | v4 is built on it |
| **L1W+L3 (v4)** | **Add** | It meets every Spiders call at ÷18 [measured] |
| G1 in `daria_constraints.sdc` | **Keep.** Its changes to `step7_report.tcl`, `step7_checks.py` and plan 5.4 move to Rev 0 | Under G1 the guard's setup is +3.062 to +3.639 ns and its hold +0.335 to +0.757 ns on six seeds [measured] |
| `pll_core.v` and bench defaults at ÷18 | **Keep** | |
| Riders D4, D7, A8 | **Drop from Rev 2** (A8 on demand) | v4's margin is flatter than T2's: six path groups lie within 0.43 ns on seed 1 [measured]. Area is not binding |
| THUMB-gating of R13/R14/R2 for Q4 | **Only if Rev 1 and Rev 2 ship separately** | See "THUMB-gating" below the table |
| *(new)* The frame gate's Spiders rule becomes "on time" (`frame_gate.py --overrun ontime`) | **Add** (V-bench) | Decisions 4 and 5. Built and self-tested in scratch, 145/145 [measured] |
| *(new)* The `sram_ctrl` hold fix | **Add** | Section 4 |
| *(new)* Documents | **Add** | The core's behaviour changes. Section 3.1 lists them |

**THUMB-gating**
- If Rev 1 and Rev 2 ship separately, Rev 1 (MR in `ap_core.qsf`, T3, FA2) makes one new non-DARIA reference.
- Rev 2's `bup_cpu.sv` changes R13/R14/R2's netlist at `THUMB` 0, which would force a second reference.
- THUMB-gating R13, R14 and R2, with L1W's cells shown absent at `THUMB` 0, avoids that second reference whatever MR's form (the study, 6.2).
- In the merged release the cleaned `bup_cpu.sv` goes into the one new reference (3.1, "Order of commits"), so the gating is not needed there.

### Rev 3 (study: "the late calls, only if wanted")

| Item | Revised | Why |
|---|---|---|
| S3 as its own design lane (1-3 weeks) | **No longer needed for Spiders. Keep it only as a reserve** | See "Why S3 is not needed" below the table |
| A ÷17 release; A1 or a guard for another divider | **Drop** | Their only purpose was to end the late calls off ÷18 |
| A CPI cut short of S3 at ÷18 | **Done:** it is L1W+L3, moved into the release | |

**Why S3 is not needed**
- L1W gets about 71% of S3's modelled cut on Spiders' worst call, with one write port [estimated: L1W's RTL-measured saving over S3's modelled one].
- No traced call is above 89.33% [measured / bounded].
- If the chip were also the speed reference, a much faster CPU would move DARIA further from the chip. This is the planner's reasoning; the owner has not said the chip is the speed reference.

---

## 3. The revisions

### 3.0 Rev 0: now, with no release bitstream

**Contents**
1. **A2, the DARIA status overlay** (`BUP_DEBUG` only).
   - It shows calls, late calls, guard lock and unlock count, and halt and fault codes.
   - A scratch worktree carries it for the test builds. It lands in `src/` with the next release.
   - **Landed on 2026-10-20** on branch `rev1/overlay` (from `DARIA-dev` `a54b07a`): `0d9ce33` is `overlay.diff` as built for the D18 and D19 test builds, and `5d5d591` fixes its whole-core check, which could pass while checking no cell (the review's finding):
     - tb_load counts what it reads back. Each run of `run_sim.sh`'s DARIA section has its own requirement (rows whose every cell is read, at least a given number of cells; the two smoke images, whose frames never reach the TIA's window, are waived in their lines), and the section sums the cells and needs rows 0-5 in normal frames and rows 0-8 under a forced pattern. The cells are checked against `u_dstat`'s counts, not the overlay's own input.
     - A new image, `frame_cdfj` (fe_dir's `CORE_TESTS`, which `BUP_DEBUG` runs use; fe_dir's suite stays at 51 tests), draws the six rows and writes and reads the RIOT timer around each call. A forced-pattern run lights every row, cell and colour.
     - `run_sim_check.py` requires the overlay lines in a `BUP_DEBUG` build; `tb_frames` needs the same coverage and at least one picture compare; `run_dstat.sh` needs every coverage bin.
     - Planted RTL faults (`.daria(1'b0)`, the calls' low bits zeroed, the window's x bound) pass the old check and fail the new one on its read-back terms, while DARIA's own result passes (`sim/bupchip/dstat/run_ovl.sh`; `sim/step7_gates.sh --only dbg_overlay`, an opt-in gate). The calls' low bits pass the old check also because the old section had no `frame_cdfj` run, where that fault shows, not only because the old check could check nothing.
     - The release build is unchanged: `pp_equiv`'s release and non-DARIA streams equal `a54b07a`'s. The `BUP_DEBUG` streams change, the non-DARIA one included: in a BupChip-only debug build `bup_status_osd` gains the DARIA ports, tied to a constant 0 (`daria` 0, `dstat` 0), and the registers they feed, which synthesis removes as constant [estimated]. `lint_step7.sh --debug` lints both debug sets (`debug`, and `debug_nodaria` without `POCKET_DARIA`).
     - Fits: D19's Q5 (seeds 1-3; seed 1 fails `gate.clk_arm` by -0.027 ns, seeds 2 and 3 pass, and P29 needs one [measured: Rev 0's fits table]) covers this branch's debug tree only, `a54b07a` plus the overlay, which is D19's `src/` with `BUP_DEBUG` (P23; since then one comment in `bup_status_osd.sv`'s header, which `pp_equiv` shows changes no stream). After a merge with `DARIA-dev`'s `7a4bf2c` (the `sram_ctrl` key copy, decision 11) a debug bitstream from `DARIA-dev` is a new tree under P23 and needs its own Q5 on seeds 1-3, with one seed passing P29, before it ships. `s4/check.sh` builds none of the changed files (7.6).
     - Defaults taken for this lane, not yet ruled on by the owner (chosen by the orchestrator): `frame_cdfj` outside fe_dir's suite; `dbg_overlay` opt-in; `g_lint` with `--debug` (about 20 s in all [measured]); planted faults as RTL mutants; Spiders under `FRAMES_DEBUG` at ÷19 only (2.2.1's CPU reads 16 late calls at both dividers).
     - Measured on `5d5d591` [sim]: the DARIA section reads back 11,280 cells at ÷19 and at ÷18 (`digital_cdfj` 4,008, `frame_cdfj` 3,240, its pattern run 4,032; guard unlocked at ÷19, locked at ÷18, 0 unlocks). `run_ovl.sh` at ÷19 catches 3 of 3 mutants, and the old check passes all three (the `.daria(1'b0)` mutant with 0 of 0 cells). Spiders, 600 frames under `FRAMES_DEBUG` at ÷19 (on `5d5d591`'s tree: the binary was built minutes before that commit, from files no newer than the build; its `run.log` names `0d9ce33` with the fix uncommitted): 1,199 calls, row 2 reads 16 late calls, 43,272 cells read back, 0 differ; the forced halt (`+ovl_halt_at=20`) shows code 9 and its PC on nine rows. The full `run_sim.sh` in the `BUP_DEBUG` build at ÷19 and `run_sim_check.py` pass; `run_dstat.sh` passes on four seeds, every coverage bin above 0, and catches 6 of 6 mutations. `lint_step7.sh` takes 16 s, 19 s with `--debug`.
     - The full `run_sim.sh` and `run_sim_check.py` pass above was run under `LC_ALL=C`: in a UTF-8 locale `run_sim.sh`'s grep of the 2600 load's LOAD line drops it ("binary file matches") and `run_sim_check.py` fails "2600 load". The cause is older than this branch; `rev1/runsim-locale` (`3035e73`) fixes the grep, and this branch does not carry it.
   - **The branch's review (2026-10-20; 18 findings, 2 major) closed** in the commits after `39d7c69`, `src/` unchanged but for one comment:
     - The limit found in `tb_load` is gone: it compared the overlay's calls, which every console reset clears (a hard reset, a menu or slot load, a retune), with a bench count since power-up, so a correct overlay read `FAIL` after any reset that followed a call. The bench now counts calls in the overlay's own epoch (cleared while `daria_reset` is high); `dr_calls`, from power-up, stays the DARIA result's. A new run, `frame_cdfj_retune` (`+retune=150`), must pass with the reset released twice.
     - The guard and unlock terms compared only zeros at ÷19: `frame_cdfj_pattern` now forces the guard's nets (`daria_dbg_locked` high for 20 ms, 4 `daria_dbg_unlock` pulses, which the DARIA result's unlock count sees too and must equal; the guard's own register is not forced), and the guard bit is compared on every `clk_sys`. `dbg_overlay` also runs `run_ovl.sh`'s control at ÷18, where the guard locks.
     - `frame_cdfj`'s late calls must be exactly the count its `.meta` gives (23 for `+daria=300`), not merely between 0 and the calls. Rows 6-8 must not be drawn while not halted (`tb_load` at each frame's end; `tb_frames` also needs exactly rows 0-5 in its last frame without `+ovl_halt_at`).
     - `run_ovl.sh` plants three more faults: `u_dstat`'s `.g_locked(1'b0)` and `.g_unlock(1'b0)`, and the DARIA rows 72 lines tall while running. Each mutant must fail on its own term and only on terms it can reach.
     - `run_sim_check.py` requires each run's overlay line to state the requirement `run_sim.sh` gives that run. `run_frames.sh` records the build's mode (`FRAMES_DEBUG`) with the binary's md5, rebuilds or refuses a binary of the other mode, and with `FRAMES_DEBUG=1` needs `OVERLAY result: PASS`.
     - Measured on `e5ef1e1` [sim], every log naming that commit with a clean tree: the DARIA section reads back 14,544 cells at ÷19 and at ÷18 (`digital_cdfj` 4,008, `frame_cdfj` 3,240, its pattern run 4,032, the retune run 3,264). `frame_cdfj` counts 23 late calls of 47, as its `.meta` requires. The pattern run counts the 4 forced unlocks on both sides, and its guard bit equals the forced net on every `clk_sys` (286,360 locked at ÷19). The retune run compares 24 calls since its second reset release, against 48 since power-up, and passes; at ÷18 the guard locks again after it. `run_ovl.sh` at ÷19 catches 6 of 6 mutants, each on its own term: `nodaria` and `xc88` on coverage, `dstat_lo0` on cells, `g_locked0` on guard, `g_unlock0` on unlocks, `rows9` on rows (45 frames of `frame_cdfj` drew rows 6-8 while running). The full `BUP_DEBUG` `run_sim.sh` at ÷19 with `run_sim_check.py` passes (under `LC_ALL=C`, as above); `run_dstat.sh` passes (four seeds, 6 of 6 mutations); `lint_step7.sh --debug` adds no warning in its five sets; `pp_equiv`'s release and non-DARIA streams equal `a54b07a`'s, and both `BUP_DEBUG` streams equal `39d7c69`'s (the header comment changes none); `pp_guards` `a54b07a`..HEAD with `--qsf comments` passes; fe_dir's `frame_cdfj` passes and the suite stays at 51 tests. `tb_frames` under `FRAMES_DEBUG` on 30 frames of Spiders: rows 0-5 exactly, 0 frames with rows 6-8 while running, `OVERLAY result: PASS`; with `+ovl_halt_at=15`, nine rows as forced; `run_frames.sh` refuses the binary under `NOBUILD=1` and `FRAMES_DEBUG=0`. The 600-frame Spiders run was not repeated: its last frame showed exactly rows 0-5 and it never halted, so the two new terms of `tb_frames`' verdict hold there [measured: its `run.log`].
2. **G1's fit-script changes, before any ÷18 fit.** This is V-bench work in `sim/`, plus plan 5.4's amendment in this document (section 10); it is outside the `src/` freeze.
   - `step7_report.tcl` ((a), (b), (k)) and `step7_checks.py` ((a), (e)) are taught G1's 8.0 / 0.5 ns. 2.2.1's ÷19 fits keep their verdicts.
   - `fit_selftest` (117 cases) gets planted G1 cases.
   - The expected verdicts of the I3 STA mutants (Q-mut) are re-derived under G1.
   - The smoke test runs under the Quartus lock: about 3 min [measured: Rev 0's runs, section 10; the study's costing had about 12 min].
   - From then on, Rev 0's debug build, the hold round and the release's pre-campaign round are all judged by the tracked tools.
3. **A ÷18 debug test build of the candidate.**
   - The tree is `6e2e880` + the candidate patch (MR, G1, T2's cures and v4; scratch) + A2 + `BUP_DEBUG`. `6e2e880` is 2.2.1 with the owner's lint fix; its `src/` change is comment-only. The candidate patch is the trial's whole tree against `4fd89ef`, and it applies to `6e2e880` too (checked 2026-10-19). On a base that holds the Harmony commit (`2d770d5`, item 7), such as `DARIA-dev` after Rev 0 is merged, its `tb_daria.sv` hunks need a 3-way apply: `git apply --3way` applies every file cleanly, while a plain `git apply` stops at `tb_daria.sv` [measured: Rev 0's review, 2026-10-19]. A tree built without them has no `s1w_cyc` bench column.
   - Fit Q5 at ÷18 on seeds 1-3. Ship one seed that meets P29 (every clock and corner ≥ 0) and keep its `.rbf`.
   - If a seed fails a hold, name the path with a `KEEP_DB=1` refit before that seed is used. T2's Q5 seed-2 hold of −0.557 ns on `clk_sys`, on the same configuration without v4 and A2, was never explained [measured: the trial's fits].
   - Before the session:
     - **Spiders in simulation.** One `tb_frames` run of Spiders under `BUP_DEBUG` at ÷18. The overlay's counter must read 0 late calls.
     - **`s4/check.sh`'s DARIA set at 38.18 MHz** on the candidate, with the firmware linked into its gitignored path as c78 did. This is an early check of 38.18 MHz on the candidate, and the debug build's own V-dbg run. For the release it is information only: under P23 it counts only for this tree, and the release campaign re-runs it.
     - **`THUMB=1 s1/check.sh` with the firmware** on the candidate (5-9 min [measured: the study's costing]).
       - It checks PCM identity and measures song 13's CPI, which becomes the new `THUMB=1` reference for the amended CPI gate.
       - It is expected to fail today's 1.383 ±1% gate by construction (Misery_F +3.17% [measured: model, T2]).
       - It runs before the owner session and before decision 10.
4. **Optional:** the ÷19 overlay build of 2.2.1, the only positive control for the late-call counter on hardware (Spiders should read 16).
5. **One owner session (V-hw)** with two or three bitstreams: 2.2.1, the ÷18 debug build, and optionally the ÷19 debug build. *Held on 2026-10-21* on the release candidate's debug build instead of Rev 0's D18 (it carries the same CPU and divider with the release's other changes); the results, and what was not done, are in [rev0_record.md](rev0_record.md). It covers:
   - the guard locked after power-up, with 0 unlocks;
   - the PAL 50 Hz image (A3: D1, plus D2 on 2.2.1), with the guard relocking after the retune;
   - Spiders through its first level load, on both 2.2.1 and the ÷18 build.
     - 2.2.1 should show the picture shift. That is the control for "no shift".
     - The ÷18 build should not shift, and the overlay should read 0 late calls.
     - Without the optional ÷19 build, "0 late calls" rests on a counter not checked on hardware.
   - Souper games (the BupChip's songs) at 38.18 MHz;
   - Turbo, which reads beyond the 64 KB window through the PSRAM cache;
   - by ear, Galagon and Mappy (`docs/daria_step7/record.md`, "Mode B at VCO/19"):
     - at ÷19, Galagon's near-pair stores changed the word;
     - Mappy had near pairs, but each was a store of 0 over 0.
6. **The `sram_ctrl` hold: cause and fix trial** (section 4).
   - It is fit-only, in a scratch worktree, on T2 + v4.
   - It is a trial of the method. T2 + v4 will not ship, and the path is placement-sensitive, so the release's real test is the combined tree's pre-campaign round.
7. **The Harmony model into the repository**, bench only (3.2), with the scope of decision 6.
8. **Documents (V-doc):**
   - B8 (`POCKET_CHANGES.md`'s counts). *Since the approval:* it waits for the release, because the file is under `src/` and Rev 0 commits nothing there.
   - `docs/ATARIVOX.md`'s rubyQ row. *Done 2026-10-19* (`e73389c`).
   - `IMPROVEMENTS.md`'s PAL item (the image now exists). *Done 2026-10-19* (`0062943`).
   - `README.md:229`: `clk_sdram` +2.433 ns should be +2.345 ns at the gated worse slow corner [measured: 2.2.1's ÷19 seed-2 fit, the study's baseline]. *Done 2026-10-19* (`e73389c`), with the same figure in `docs/DEVELOPING.md` and `docs/ATARIVOX.md`.
   - also `lint_step7.sh`'s missing AtariVox sources, a script fix (V-bench). *Since the approval:* done by the owner's commit `6e2e880` on `Mister-Pocket-Port` ("lint_step7.sh, AtariVox: lint the AtariVox sources; waive its warnings"). It was not yet in `main` on 2026-10-19. The owner, that day: "there was a minor update on mister-pocket-port I do not think I have pushed to main yet since it has to do with a lint check or something". Rev 0 does not redo it, and its test trees start from `6e2e880`.
9. **Optional:** Spiders on a real Harmony (3.3), best in or before this session.

**What it gives the player.** Nothing in the release. It gives the owner:
- hardware evidence for decisions 3 and 7: whether ÷18, the guard and PSRAM behave on silicon, and whether the picture shift is gone;
- the measured BupChip cost for decision 10;
- fit tools that judge ÷18 builds correctly.

**Gates**
- The debug builds count as test builds, so P29 applies: Q5 on seeds 1-3, with one seed passing everything.
- The overlay's Spiders run in simulation.
- G1's fit scripts: V-bench (`fit_selftest`, the smoke test).
- The Harmony commit: V-bench (3.2).
- Documents: V-doc (`hygiene.sh`).
- The `lint_step7.sh` fix: V-bench (the owner's commit).
- The firmware check and `s4` are information for the release.
- No `src/` change is committed, so the `src/` freeze stays in place until decision 1.

**Effort and calendar** [estimated]
- **Development:** about 3-5 days to the owner session in parallel lanes, plus the time to schedule the session.
  - A2: 1-2 days.
  - G1's scripts: hours to a day.
  - The Harmony commit: 1-2 days.
  - The hold round: about 1 day.
  - The session waits for A2, then the fits, then about a day of simulation.
- **Quartus lock:** about 2.6-3.6 h, or 3.6-4.6 h with the optional ÷19 build [per fit: 18.4-20.4 min, measured: the study's costing]:
  - Q5 ×3 at ÷18: about 1 h;
  - the smoke test: about 3 min [measured: section 10];
  - the hold round's 5-7 fits: about 1.5-2.4 h.
- **Simulation:** about 1 day, mostly `s4` [measured: c78's `s4` jobs took 16.3 h for both sets].
- **Owner:** one session of 1-2 h.

**Prerequisites**
- The owner's approval of Rev 0: given on 2026-10-19.
- Decision 6's scope, before the Harmony commit (item 7): settled with that approval.
- Decision 5 can be answered now or after the session. It is needed before the release's campaign.

### 3.1 The next release: Rev 1 + Rev 2 merged at ÷18 (recommended)

**Progress, 2026-10-21.** The owner chose one release at ÷18 (decisions 2, 3 and 7), landed before Rev 0's session, which still has to confirm ÷18 on silicon. Stage 2's branch is not pushed yet.
- **In `DARIA-dev`** (`d05cb11`, Stage 1): the L1W+L3 CPU with T2's cures (`bc6a1ec`, decisions 2 and 10), MR in `ap_core.qsf` (`de9a903`, decision 8), and ÷18 with the bench defaults and G1 (`09aa7f8`, decision 3, its own commit so that it can be reverted alone), with their review fixes. The decision 11 hold fix (`7a4bf2c`) and the overlay (A2) were already in.
- **On branch `rev1/div18-s2`** (Stage 2, on top of `f29794a`):
  - `8a8bddb` `virtual_axis5` (decision 9), with `tb_vaxis5` in `run_sim.sh`;
  - `4738c65` the FA2 saves, one shared `fa2.sav` (decision 15): F′ until the Stage 2 review;
  - `35bf88f` the FA2 port only in 2600 mode, and `core.qip` without `virtual_axis.sv`: F′, the last commit that changes the build without DARIA;
  - `ba0812c` the identity chain re-based on F′ ("Order of commits", item 2);
  - `5ad0a6b` RTL-1 and RTL-2, with the unit bench `tb_region` and `tb_wire`'s `pal2600_a78` at no extra retune;
  - `dd135dd` B5, with the smoke test passing at 15 marks;
  - `5febe80` B8;
  - the documents' commit: every item of "Documents" below, except README's timing paragraph, which takes the release's Q2, and the hardware results that wait for the session (open items 7 and 10, IMPROVEMENTS's PAL items). `BUPCHIP_CORE.md`'s three items and `DEVELOPING.md`'s came with Stage 1 (`bc6a1ec`, `09aa7f8`, `9451d56`).
- **Benches and checkers** from the list below landed with Stage 1 (`s1/check.sh`'s `THUMB=1` gate at 1.4208, `frame_gate.py --overrun ontime`, `l1f.S`, the L1W mutants with `neg_of_rd` and `sbc_carry_inverted` retired, `run_call.py`'s cases, `s1w_cyc`) and with Stage 2 (`tb_vaxis5`, `tb_load`'s FA2 round trip, `tb_region`, the re-based chain).
- **Still to come**, in this order: F′'s non-DARIA reference fit with its repeat and Q4; B3 needs nothing more (the ÷18 commit made its lines right); the pre-campaign round (Q2 ×3 and Q5 ×3 on the combined tree, Q-mut, the STA mutants); the seed (P12 as amended on 2026-10-21) with B4's comment and B6; the campaign; the review; V-hw.
  - *2026-10-21, after the pre-campaign round on `ebca01a`:* F′'s repeat and Q4 are byte-equal; Q2 and Q5 seeds 1-3 pass; the STA mutants and Q-mut are caught (Q-mut with a (g) failure explained: "Stage 2's pre-campaign round" below). The seed is applied: `SEED` 3 (P12), with B4's comment and B6, comment- and selection-only (7.6). Left: the campaign, the review, V-hw.
  - *2026-10-22/23, after the merge of 2.2.2 (`a080f6f`, the new F′):* the round ran again on the merged tree and passed (Q5 by P29: "The merged tree's round" below). The seed moves to 2 (P12, `8740b65`). The campaign's DARIA-side results carry over by 7.6. Left: plan 7.7 on the final release commit, and the merged tree's V-hw.

**Contents**
- **CPU** (`bup_cpu.sv`):
  - T2's R1, R12, R13, R14 and R2, plus L1W+L3, as v4 (md5 `4f224fbf`).
  - Clean up comments and names only, so that the trial's evidence carries over. Show that the cleaned file equals v4 with a Yosys equivalence like `aria_equiv.sh`'s, where the scripts allow it, and run the Thumb suites on it. The suites test; they do not prove equality.
  - Keep L3. It is part of the verified RTL, although it saves only 2 clocks on Spiders' worst call [measured].
  - Keep `io_guess`, and drop it only if a seed falls short. It deepens the `rom_addr` cone from 20 to 24 levels [measured: Yosys proxy].
- **Clock and constraints:**
  - `pll_core.v` at C3 = 18, regenerated by P10, with the bench and gate defaults at ÷18 (`div_check.py`).
  - G1 ([0.5, 8.0] ns, fitter 7.5) in `daria_constraints.sdc`.
  - The `sram_ctrl` hold fix (section 4).
- **Area and Rev 1's items:**
  - MR (13 qsf lines, in `ap_core.qsf`);
  - T3's `virtual_axis5`;
  - RTL-1 and RTL-2;
  - B5 (`daria_sync.tcl`);
  - Star Castle Arcade's FA2 saves (C5);
  - B8 (`POCKET_CHANGES.md`'s counts), moved here from Rev 0;
  - after the fits: B3 (the counter[3] line at VCO/18), B4 (the seed comment quoting the new Q2) and B6. *Done 2026-10-21:* B4 and B6 with `SEED` 3.
- **Debug only:** A2's overlay.
- **Benches and checkers (V-bench, before the campaign):**
  - `s1/check.sh`'s song-13 CPI gate (1.383 ±1%) gets the `THUMB=1` reference that Rev 0 measured on the cured RTL with the firmware. `docs/BUPCHIP_CORE.md`'s criterion is updated to match.
  - `frame_gate.py --overrun ontime|late` (default `ontime`, resting on decisions 4 and 5), with `selftest.py`'s 12 new cases.
  - `l1f.S` joins `run_directed.sh`'s list.
  - `mutants.py` gets the six L1W mutants. The two older entries `neg_of_rd` and `sbc_carry_inverted`, which no longer apply since T2's R13, are retired or re-targeted.
  - `run_call.py` gets its two `lb`-at-return cases.
  - `tb_daria` gets the `s1w_cyc` column (the L1W cycle rule).
  - `tb_wire`'s `pal2600_a78` expectation changes: the DARIA build's extra retunes drop to 0 after RTL-1 (`docs/DARIA_CORE.md`, open item 20).
  - `tb_vaxis5` is committed; it is a scratch bench today.
  - The non-DARIA identity chain is re-based on F′ ("Order of commits" below), with planted cases in the gate checkers' self-tests.
  - The smoke test runs again after B5 lands: `daria_sync.tcl` is a smoke-test file under plan 7.6.
  - G1's fit-script changes already landed in Rev 0.
- **Documents:**
  - **README:**
    - Line 175: 36.17 → 38.18 MHz.
    - Line 219: Spiders "late on the same 16 calls as MiSTer" becomes "on time, as the modelled Harmony chip; MiSTer is late on 16 calls in frames 557-572".
    - The hardware note about the picture shift changes.
    - The FA2 known-limit row (line 144) goes.
    - The timing paragraph (lines 228-232) takes the release's Q2. *Done 2026-10-21:* seed 3's figures, with 2.2.1's kept after them.
    - Line 176's "19% of its clock to spare" is the BupChip at 28.6 MHz in the build without DARIA (`docs/BUPCHIP_CORE.md`: 28.636/24.0 − 1). R1 is THUMB-gated and does not touch that build, so the figure stays.
    - If a figure for the DARIA build is added, it uses the same form: 38.18/24.74 − 1 ≈ 54% with R1, against 36.17/23.98 − 1 ≈ 51% today [estimated].
  - **`docs/DARIA_CORE.md`:**
    - Decision 7 becomes S1 with Thumb at ÷18, with T2's cures and L1W+L3, and no S3 needed for Spiders.
    - Open item 3: S3 not needed for Spiders.
    - Open item 7: the guard locks at ÷18, with Rev 0's hardware result.
    - Open item 10: PSRAM at 38.18 MHz on hardware.
    - Open item 12 (Fix B's hold at the coincident `clk_sys`/`clk_sdram` edge): the new `sram_ctrl` hold finding and its fix.
    - Open item 20: RTL-1 fixed.
    - Add the chip-as-reference rule as 3.2 defines it.
  - **`docs/IMPROVEMENTS.md`:**
    - S3's Spiders rationale goes.
    - A1 applies only if ÷18 is ever left.
    - The overlay and PAL items are done.
    - "After 2.2.1: RTL-1 and the `src/` clean-ups": items 1-8 are done.
    - The FA2 item is done.
  - **`docs/BUPCHIP_CORE.md`:**
    - The per-class table gets the Thumb load and LDMIA/POP classes, and R1/R12's ARM classes.
    - Note that under L1W a DATA fault halts one clock after the retire (same code and PC, 210/210 [measured]).
    - The CPI criterion changes.
  - **`docs/DEVELOPING.md`:**
    - The PLL command's C3 values: `gui_output_clock_frequency3=36.172249`, `gui_divide_factor_c3=19` and the text after them. P10 requires the command to change with C3.
    - The `POCKET_DARIA` row.
    - The bench divider and guard notes.
  - **Design notes:**
    - G1's reasoning goes into `docs/daria_fe/design.md` 8.2.
    - This document carries plan P12, P13 and 5.4 forward, amended. 5.4's amendment for G1 is already here (section 10). P13's Spiders rule ("on time") and any P12 seed rule (decision 11) are added with the release.
    - *Done 2026-10-21:* P12 and P13 each carry a dated amendment in the step-7 plan's own rows: P12 the owner's seed ruling of 2026-10-21 (the safest seed that passes everything, expected to be seed 3; `SEED` moves only after the pre-campaign round), P13 the `ontime` rule of decisions 4 and 5. G1's reasoning is in `docs/daria_fe/design.md` 8.2.
  - **The AtariVox change.** The campaign also covers `4fd89ef`'s AtariVox change. The documents do not record plan 7.6's `run_sim`/`extra_tests`/`s4`/`pp_equiv` set for it (the study, 7.3 and 8.3).

**Order of commits** (keeps the non-DARIA identity chain meaningful)

Today, MR in `ap_core.qsf` fails `pp_guards`' qsf rule by construction ("exactly the three DARIA lines … plus the SEED line and comment lines"). T3, FA2 and any `bup_cpu.sv` edit fail `pp_equiv`'s `PP_EXPECT` hash by construction [read: `sim/tools/pp_guards.py:20-23`; `sim/step7_gates.sh:15, 275-277, 299`].

1. **F′: the changes that reach the build without DARIA, as their own commit.**
   - It holds MR in `ap_core.qsf`, T3, the FA2 saves and the cleaned `bup_cpu.sv`.
   - `bup_cpu.sv` is compiled in that build (`THUMB` 0), and `pp_equiv` excludes only `daria_` and `bup_dbg_snap` files, so any edit to it changes the non-DARIA stream. `aria_equiv.sh` is its `THUMB` 0 proof.
   - If the hold fix needs RTL in `sram_ctrl.sv`, which is in both builds, it belongs here too.
   - F′ gets its non-DARIA reference fit, a repeat that shows Quartus reproducible (as Q1r did), and its V-rtl evidence.
2. **Re-base the chain on F′:**
   - `PP_EXPECT` becomes F′'s non-DARIA stream hash.
   - `PP_GUARD_FROM` becomes F′.
   - `pp_guards`' qsf rule must fit that range. From F′ the `ap_core.qsf` diff should be the SEED line and comments only. `--qsf daria` as written expects the three DARIA lines to be added once, and would fail.
   - **Re-based on the merge of 2.2.2 (2026-10-22):** 2.2.2 (`origin/main` `d38fd13`) brought the POKEY read fix (`9aa125a`: `pokey_bus.sv`, `pokey.sv`, `pokey_adapter.sv`) and the AtariVox escape fix (`0f3a9db`: `avox_rx.sv`), which both builds compile, so the merge into the ÷18 tree is F′. `PP_GUARD_FROM` = `a080f6f6c8cc8d40cd17d0271e132df7b8bee6f9`, passed as the full hash. It was found as the first-parent commit that brought `READ_WHOLE_CYCLE` in: `git log -1 --format=%h --first-parent -S READ_WHOLE_CYCLE -- src/fpga/mister/rtl/Pokey/pokey_bus.sv`, run on the branch the merge is on (`rev1/merge-222`). The expression names F′ only on a branch that has the merge on its first-parent line. Without `--first-parent` it finds `9aa125a`, 2.2.2's own POKEY commit, whose tree is 2.2.1's ÷19 tree without MR or DARIA's changes, so `--qsf release` could not start there. If the branch reaches `DARIA-dev` by a `--no-ff` merge, the same expression run on `DARIA-dev` finds that later merge (its tree equals the branch's, so the guards would still pass, but the anchor would no longer name the fitted F′): use the merge's `^2`, or take the branch into `DARIA-dev` by fast-forward (`DARIA-dev` = `f3ef96a` = `a080f6f^1`, so `git merge --ff-only` works). On `main`, after a pull-request merge as for 2.2.2, it finds `d38fd13`, 2.2.2's ÷19 tree with 1 `MUX_RESTRUCTURE` line against the release's 15, where `--qsf release` fails: never evaluate it on `main` [measured: the expression on `origin/main` and `grep -c MUX_RESTRUCTURE` on both trees; the `--no-ff` case in the merge review's scratch clone, 2026-10-23]. `PP_EXPECT` = `b1b706d3b6a2e3af4668de257b284aa652f19a1e67448521270e2466ce9e877c`, the merge's non-DARIA stream (the line below's with 2.2.2's four files) [measured: `pp_equiv.py` on `a080f6f`]. The DARIA and `BUP_DEBUG` streams change in the same four files and in no DARIA file. `pp_guards` still picks `--qsf release`; from the line below's F′ (`35bf88f`) to the merge it passes all four guards, so the merge changes `ap_core.qsf` only in comments and no `.mif`. F′'s reference fit, its repeat, Q4 and the pre-campaign round (Q2 and Q5 on seeds 1-3, Q-mut, the STA mutants) run again on the merged tree, and the seed is chosen again by P12 (`sim/step7_gates.sh`'s header).
   - **Re-based on the new F′ (2026-10-21, after the Stage 2 review; replaced by the line above on 2026-10-22):** the review found that an A78 which `detect2600.sv` takes for FA2 could write junk over the shared `fa2.sav`, so the FA2 port is now on only in 2600 mode, and that commit, which also drops `virtual_axis.sv` from `core.qip`, is F′. `PP_GUARD_FROM` names it as the commit that added `fa2_on` to the wrapper: `git log -1 --format=%h -S fa2_on -- src/fpga/core/atari7800_pocket.sv` (`35bf88f` on `rev1/div18-s2`). `PP_EXPECT` = `2fe5aed73e6edfc89866145aa3ec99ec1e757a532169b39a725f168e69f74f4b`, its non-DARIA stream (the line below's, with the wrapper's FA2 gate and without `virtual_axis.sv`). `pp_guards` still picks `--qsf release`. F′'s reference fit, its repeat, Q4 and the pre-campaign round run again on it (`sim/step7_gates.sh`'s header).
   - **Re-based on F′ (2026-10-21, replaced by the line above):** F′ was the FA2 save slot's commit, then the last one that changed the build without DARIA. `PP_GUARD_FROM` names it as the commit that added `fa2_nvram_bridge` to the wrapper: `git log -1 --format=%h -S fa2_nvram_bridge -- src/fpga/core/atari7800_pocket.sv` (`4738c65` on `rev1/div18-s2`; the expression still finds it if the branch is rebased). `PP_EXPECT` = `8a7e8a3d9dc32f0134b34d78b6467c586daffde69b087cc8f02ae53fc7753b7b`, F′'s non-DARIA stream (MR, `virtual_axis5`, the FA2 slot, the L1W+L3 CPU and the `sram_ctrl` key copy). `pp_guards` picks `--qsf release` from F′: `ap_core.qsf` may change only in its SEED line and comments, so P12's move to seed 3 still fits the chain (`sim/step7_gates.sh`'s header).
   - **Interim until F′ (2026-10-21, replaced by the line above):** `PP_GUARD_FROM` = the MR commit (`git log -1 --format=%h -S MUX_RESTRUCTURE -- src/fpga/ap_core.qsf`), `PP_EXPECT` = `34b3f60afe45865c931fb8e72a6a0c8333abc7f34dd0528dde2bbdedc740bd21` (the L1W+L3 CPU and the `sram_ctrl` key copy; the MR commit's own stream, `56033140de55bce615ac8217d40ac7ed2efa8d6cb5cee960b62198a4eae498fd`, has two more lint metacomment lines in `bup_cpu.sv`); `pp_guards` picks `--qsf release` (`sim/step7_gates.sh`'s header).
3. **Then the DARIA-side changes:**
   - G1;
   - the PLL at C3 = 18, with the bench defaults;
   - RTL-1 and RTL-2, inside `atari7800_pocket.sv`'s `ifdef POCKET_DARIA` block;
   - B5;
   - the hold fix in `daria_constraints.sdc`;
   - A2 (`BUP_DEBUG` only).
   - Q4 is proven against F′.

**What it gives the player**
- **Spiders** no longer stretches 16 frames to 354 lines before a level loads. That is measured as frame lengths. That the picture no longer shifts is inferred [measured: `tb_frames`; the picture to be seen in Rev 0's session].
- **No audio-read race.** No front-end audio read can race a DARIA store while the guard stays locked. At ÷19 there were 2 word changes in 130 s of mode-B play, both on Galagon [measured: `docs/daria_step7/record.md`, "Mode B at VCO/19"].
- **More margin on every heavy call:** Qyx goes from 97.3% (2.2.1) to 85.86% [measured].
- **Star Castle Arcade** keeps its high scores.
- **PAL A78 after a PAL 2600 image:** no longer retunes twice (RTL-1).
- **About 1,300 more ALMs free** [estimated: 15,839 minus about 14,530-14,570, so about 1,270-1,310; −1,318 was measured for MR + T3 on `4fd89ef` at ÷19, seed 2]. Not visible to the player.
- **The BupChip:**
  - Its firmware takes 3.1-3.2% more clocks [measured: model, T2; Rev 0 measures it on the RTL].
  - Its clock is 5.6% faster [estimated: 38.18/36.17].
  - PCM identity is gated, so there is no audible change.

**Gates** (plan 7.6 and the study's 7.1: V-daria +cpu +div, plus Rev 1's extras)

**Pre-campaign fit round**
- It fits the full combined tree, which has never been fitted (about 14,530-14,570 ALMs [estimated]).
- It runs Q2 ×3 and Q5 ×3 at ÷18, judged by the tracked scripts with G1's changes from Rev 0.
- Pass needs all of:
  - `clk_arm` ≥ +0.5 ns on every seed (the study's MARGIN), and ≥ 0 by plan 5.2;
  - every hold ≥ 0 at every corner on seeds 1-3 (P12);
  - `clk_sdram` ≥ +1.5 ns;
  - (h) setup ≥ +4.5 ns at ÷18 (v4 ranged +4.696 to +6.103 ns [measured]), and (h) hold ≥ 0;
  - every other 5.4 check.
- Q-mut (rule amended 2026-10-21, after the round below): it passes when (f) FAILs naming `run_s[0]` and (k') FAILs naming `ready_s[0]`. Any other check that fails on the mutant is listed and explained in the record. Plan 7.2 asks only that each of the two checks catch its mutant; "nothing else fails" (`docs/daria_step7/record.md`) was c76's result, not a rule. A mutant is another netlist, so a check that selects cells by name, such as (g), can move on it without saying anything about the release.
- If the tree is frozen after this round, with only V-cmt edits such as B3, B4 and B6 to follow, these fits are the campaign's Q2 and Q5. Plan 7.6 counts a result for the tree it ran on.
- The campaign starts only after this round passes. If it fails, the diagnosis is in "One release or two" below.
- **Stage 2's pre-campaign round (2026-10-21): passed** [measured: fits on `ebca01a`, status 0; Q5 on `ebca01a` + the `BUP_DEBUG` line; Q-mut on `ebca01a` + its two faults]. After it the tree changes only in comments, documents, the `SEED` line and simulation scripts, so these fits are the campaign's Q2 and Q5.
  - F′ (`35bf88f`) and its repeat: `.rbf` byte-equal (md5 `6cae7b99`); Q4 on `ebca01a` equals them.
  - Q2, every check passing on every seed. Seeds 1 / 2 / 3: `clk_arm` +1.982 / +1.248 / +2.195 ns, `clk_sdram` +2.407 / +2.388 / +3.107 ns, worst hold +0.106 / +0.100 / +0.108 ns, (h) +6.306 / +0.264, +6.895 / +0.281 and +6.166 / +0.337 ns, 14,617 / 14,618 / 14,628 ALMs (216 M10K). Seed 3 ships (P12).
  - Q5 seeds 1-3 pass with P29: `clk_arm` +2.013 / +2.170 / +1.724 ns, worst hold +0.031 / +0.027 / +0.090 ns.
  - The three I3 STA mutants fail as section 10 expects.
  - The smoke test passes with 13 marks. P10's regenerated PLL has the tree's `POCKET_DARIA` view (the step-7 plan's P10).
  - **Q-mut: caught.** (f) names `run_s[0]` and (k') names `ready_s[0]`. (g) also FAILs, with 150 paths, explained as follows:
    - All 150 start at one register that the fitter's retiming created, `cart2600|mapper_AR|tape_num~0_OTERM2454`. It moved the 6502's address registers forward through `top.sv`'s address mux and a decode LUT that synthesis named after `mapper_AR`'s `tape_num` write decode, which shares it with the 7800 cart's decode.
    - Every path runs through `cart.sv`'s `cartram_cs`, the 7800 RAM select (101 also through `cartram_wr`), into `sram_ctrl`'s 7800 request logic (`c_rd_q`, `c_wr_q`, `cp_*`, `acc_*`, `sram_a`, `dq_out`, ...). None goes through `read_DB`, and none reaches the SRAM pads. It is the 7800 request, which Fix B lets reach `sram_ctrl` directly, not a 2600 path.
    - The register exists only with both the faults and `35bf88f`'s FA2 gating. `ebca01a` + the faults with `atari7800_pocket.sv` put back to `afd8269` fails exactly (f) and (k'), and its fit report matches round 1's Q-mut on `afd8269` line for line. Two refits of the mutant reproduce the 150.
    - No Q2 or Q5 fit has the register. There (g) finds 0 paths, with every 2600 leg reaching `t_*_q` ((g.legs)), so (g)'s PASS on the release stands.
- **The merged tree's round (2026-10-22, after the merge of 2.2.2): passed, by the reading below** [measured: fits on `7701ee9`, status 0; Q5 on `84e5065` = `7701ee9` + the `BUP_DEBUG` line; Q-mut on `7701ee9` + its two faults; the round's chain log, `rc 0`]. The merge (`a080f6f`) changes the build without DARIA (2.2.2's POKEY read fix and AtariVox escape fix), so it is F′ and the round ran again. Its rule was the same as Stage 2's round.
  - F′ (`a080f6f`) and its repeat: `.rbf` byte-equal (md5 `90dfa74b`); Q4 on `7701ee9` equals them.
  - Q2, every gate and every 5.4 check passing on every seed ("rules as first written: PASS"). Seeds 1 / 2 / 3: `clk_arm` +2.284 / +1.482 / +1.343 ns, `clk_sdram` +2.515 / +3.020 / +2.229 ns, worst hold +0.109 / +0.095 / +0.099 ns, (h) +6.476 / +0.243, +6.209 / +0.260 and +7.532 / +0.289 ns, the guard pair's setup +3.360 / +3.128 / +3.533 ns, 14,653 / 14,639 / 14,623 ALMs (216 M10K, 13 DSP).
  - **The seed moves from 3 to 2** (P12 as amended on 2026-10-21: every gate and check on seeds 1-3, then the most `clk_sdram`). The owner's ruling expected seed 3, which Stage 2's round chose; on the merged tree seed 2 wins, and P12 asks that the owner be told. Seed 2 is not best on every figure: seed 1 has the most `clk_arm` and hold margin, and seed 2 has the least worst hold (+0.095 ns) and (h) setup (+6.209 ns) of the three. Its `clk_arm` +1.482 ns passes the release's MARGIN of +0.5 ns; the +1.5 ns in section 4's trial paragraph was a criterion of that trial, not a release gate. In seed 2's favour beyond P12: Q5 meets P29 on seed 2, so the release and the debug build share a seed. Applied in `8740b65`.
  - Q5 on `84e5065`: seeds 2 and 3 meet every clock at every corner (worst hold +0.110 / +0.082 ns, `clk_arm` +2.098 / +2.015 ns), so P29 is met. **Seed 1 fails `clk_sys` hold** at all four corners: −0.504 / −0.433 / −0.266 / −0.261 ns at slow 85 °C / slow 0 °C / fast 85 °C / fast 0 °C (verdict FAIL: (l), `gate.hold`). This is the first round in which a Q5 seed fails.
    - **How the round is judged.** The pass rule above says "every hold ≥ 0 at every corner on seeds 1-3 (P12)". That bullet is P12's rule for the shipping configuration, Q2. Q5 is a test build's fit and is judged by P29 (at least one seed with every clock and corner ≥ 0), as 3.0's gates say for debug builds. Read that way the round passes; read literally, Q5's seed 1 would fail it. The round's own log printed P29 as a per-seed FAIL for seed 1; the margin script now reports each seed as meeting or not meeting P29's condition and P29 once for the set ("met: seeds 2, 3").
    - **Not named; seed not used (3.0).** *Named 2026-10-23: next bullet.* The failing clock is `clk_sys` (`clk_sdram`'s hold is +0.408 ns at slow 85 °C), so it is not `sram_ctrl`'s `t_last` path of section 4, which latched on `clk_sdram`. It is the second unexplained `clk_sys` hold failure of about −0.5 ns on the Q5 configuration, after T2's Q5 seed 2 (−0.557 ns). Its database was deleted under the round's rule, and seed 1 is not used, so 3.0's "name the path with a `KEEP_DB=1` refit before that seed is used" is not triggered. Whether the same path sits thin on seeds 2 and 3 (worst hold +0.110 / +0.082 ns) is unknown. One `KEEP_DB=1` refit of Q5 seed 1 (deterministic, about 12 min under the lock) would name it; it is optional, and it would keep a later debug-seed choice from landing on it blind.
    - **Named (2026-10-23, the clean-up pass after 2.2.4)** [measured: a `KEEP_DB=1` refit of `bca3819` (= `ba3af23` + the `BUP_DEBUG` line, the same fitted inputs as `84e5065`: the two differ only in `ap_core.qsf`'s comments and its `SEED` line, which the fit driver sets to 1) at seed 1, and `quartus_sta` on its database]. The refit repeats q5_s1: `timing.txt` and the checks are identical (−0.504 ns, verdict FAIL: (l), `gate.hold`); the `.rbf` differs only by the build-ID stamp.
      - **The path:** `sram_ctrl:sram|sk_rdata[4]` (`clk_sdram`, FF_X44_Y10_N35) → `EEPROM_24LC0X:savekey|data[5]` (`clk_sys`, FF_X44_Y10_N2): the SaveKey's read byte, bit 4, into the EEPROM model's shift register (`data <= {data_from_ram, 1'b1}`). It is the only failing `clk_sys` hold endpoint at every corner; the next is +0.289 ns (slow 85 °C, a `clk_sys` register into itself), and of 1,761 `clk_sdram` → `clk_sys` hold endpoints the next is +0.735 ns.
      - **Delay against skew:** relationship 0.003 ns (the coincident edge), data 0.736 ns, clock skew +1.177 ns, slack −0.504 ns at slow 85 °C (slow 0 °C: 0.750 / +1.120 / −0.433; fast 85 °C: 0.289 / +0.492 / −0.266; fast 0 °C: 0.270 / +0.468 / −0.261). The data path is the shortest one a LAB has: FF → local line → LAB input mux → `data~7|datac` → `data[5]|d`, 0.300 ns of routing and one LUT. The skew is the difference between the two clock trees, and `clk_sys` arrives later. It splits into the PLL counters, 0.508 ns (`clk_sdram` from counter[1], 1.407 ns; `clk_sys` from counter[0], 1.915 ns); counter to clock control, 0.488 ns (counter[1] reaches CLKCTRL_G10 through the clock buffer at X54_Y22, counter[0] at X54_Y5 reaches CLKCTRL_G6 through the one at X21_Y0); and the rest of the two trees, 0.181 ns: the global and row network, 0.096 ns, and the two registers' clock pins, 0.085 ns. Each part compares the launch clock's early delays with the latch clock's late ones, as a hold check does. The 0.451 ns ahead of the counters is removed as pessimism. In a given fit only the crossing into the later-arriving clock is exposed. Here that is `clk_sdram` → `clk_sys`; the other way, `clk_sys` → `clk_sdram` setup paths show −1.535 ns of skew (`sdram_worst.rpt`; a setup figure, not that crossing's hold skew), and `clk_sdram`'s hold is +0.408 ns. It is the same shape as section 4's `t_wr_q` → `t_last[17]` (data 0.733, skew +1.179, −0.503 ns). That fit (the trial's ÷18 seed 3, database deleted) had `clk_sdram` later, so there the exposed crossing was `clk_sys` → `clk_sdram`. A minimum route inside one LAB, across about 1.18 ns of skew into the later clock, gives about −0.5 ns at slow 85 °C. T2's Q5 seed-2 −0.557 ns on `clk_sys` fits that signature, but its path stays unnamed [estimated].
      - **Why the fitter left it:** not stated in its reports. The fitter saw it: its own view, with `core_constraints.sdc`'s fitter-only +0.1 ns hold into `clk_sys`, is −0.604 ns, and it added 122.3 ns of hold delay on `clk_sdram`,`clk_sys` → `clk_sys` transfers. The other seven bits, four of them in the same LAB, were routed long (data 1.98-2.22 ns, slack +0.735 to +0.985 ns); only bit 4 kept the minimum route. Unlike `t_last[17]` the input is not shared: the register, the local line and the LAB input mux each have fan-out 1. Setup on these paths is not the reason either: +14.2 ns at slow 85 °C.
      - **Not `BUP_DEBUG` logic.** Neither register nor the logic between them is under `BUP_DEBUG` (`bup_dbg_snap`, the overlay and `bup_status_osd` are not on it): it is the release build's SaveKey path (`POCKET_SRAM`). `BUP_DEBUG` only moves the placement. So the release build can have it on some fit. It does not on the shipped one: Q2 seed 2's worst hold over every clock and corner is +0.095 ns, and Q5 seeds 2 and 3 (the debug build ships seed 2) have +0.110 / +0.082 ns, so this path is at least that on each. Those bounds hold only for today's netlists: any netlist change re-places the design on the shipped seed 2, not only a seed change. A fit that puts it at the minimum route shows a negative `clk_sys` hold in `ap_core.sta.summary` and fails `gate.hold` under `run_step7.sh`, as this one did. The plain build (`quartus_sh --flow compile ap_core`) still writes the bitstream, and CI only warns ("Timing requirements not met"). What keeps such a fit out of a release is the release checklist (`DEVELOPING.md`, "Before a release", item 3: timing on every corner, `run_step7.sh`).
      - **The check is false in function**, as `t_last`'s was (`sram_ctrl.sv:521-528`; `atari7800_pocket.sv:606-618`; `EEPROM_24LC256.sv:72-74`). `sram_ctrl` writes `sk_rdata` only on the `clk_sdram` edge where it toggles `sk_ack`, and only for a request that is outstanding (`sk_req != sk_ack`). The EEPROM model loads `data` only when `ram_done` (`sk_pend && sk_ack == sk_req`) was already true before the `clk_sys` edge, which needs the toggle to have happened at an earlier edge; by then no SaveKey request is outstanding, so `sk_rdata` does not change on any edge where `data` takes it. The enable path keeps its full check: `sk_ack` → `savekey|data[*]` +1.568 ns at slow 85 °C, +0.294 ns at fast 0 °C.
      - **Fix:** none needed now; P29 is met by seeds 2 and 3 and no seed is changed. The options, if a later round lands on it:
        - nothing, the seed rule (P29 for test builds, P12 for the release): costs a seed, and the release checklist keeps a failing fit out of a release; recommended;
        - a fitter-only minimum delay on `sram|sk_rdata[*]` → `savekey|data[*]` in a build's own SDC: free on setup (+14 ns), but section 4's trials found the fitter leaving such a path 0.25-1.2 ns short of each target (0.3 ns gave −0.202, 0.5 ns gave +0.253, 0.7 ns gave −0.518), and it already left this one 0.6 ns short of its +0.1 ns; a trial is a Q5 round, about 40 min under the lock, with no promise;
        - a hold exception (`set_multicycle_path -hold 1 -from {*|sram_ctrl:sram|sk_rdata[*]} -to {*|EEPROM_24LC0X:savekey|data[*]}`), as section 4's option 1 for `t_last`. Unlike section 4's, `-from` names only `sk_rdata`, whose one load is `data_from_ram`, so the enable path (`sk_ack` → `sk_ram_done` → `data[*]`) keeps its full check. It is true by the argument above, but it changes what the Timing Analyzer checks in every build, so it is the owner's decision with P11 (`core_constraints.sdc`), then Q2 and Q5 on seeds 1-3 (about 75 min under the lock) and the STA mutants;
        - structural (`sram_ctrl.sv` or the wrapper, e.g. a `clk_sys` copy of `sk_rdata` loaded one edge after the toggle): changes the build without DARIA (F′, the cartram matrix, 7.6) for a check that is false in function. Not recommended.
      - The database is deleted after this record.
  - The three I3 STA mutants (nopair, cutafter, cutinstead) are each caught as section 10 expects. Q-mut is caught as expected, with only (f) naming `run_s[0]` and (k') naming `ready_s[0]`. No database is kept.
  - **V-rtl on `7701ee9`** [measured: each log's header names `7701ee9` with status 0, in a worktree of the main checkout]: `run_sim.sh` (both builds; the DARIA build's non-BupChip fingerprints equal the plain build's), the cartram gate, `extra_tests.sh` with `AR_TAPE=1` on both builds against Stage 2's base reference (the SaveKey pass tone at 1,960 Hz), `selftest.py` 306 of 306 with no input missing, and `s4/check.sh` 28 of 28 on the DARIA set with both sets run: every verdict PASS. Static gates on `a080f6f` and `7701ee9` pass, and `pp_equiv`'s streams from `f3ef96a` to `a080f6f` change only in `avox_rx.sv` and the three POKEY files, in all three macro sets.
  - **The POKEY read fix is not covered by a tracked gate on this tree.** `extra_tests.sh`'s POKEY statistics ($450, $4000, DLI) equal the pre-fix reference, because they measure audio driven by writes. The read fix's evidence here is the Star Raiders run on `7701ee9` (`tb_load +cpuprobe`: 40 RANDOM reads, none $FF, rc 0 [measured: a scratch run]), 2.2.2's own hardware test on its ÷19 build, and the V-hw still owed on this tree. A RANDOM check with `+cpuprobe` in `extra_tests.sh` would make it a gate; it is not added.
  - **What carries over from the campaign on `8cd6fe0` (7.6).** From `8cd6fe0` to `7701ee9` `src/` changes only in `avox_rx.sv`, the three POKEY files, `POCKET_CHANGES.md` and comments in `ap_core.qsf`; no DARIA file changes [measured: `git diff`, and `pp_equiv`'s per-file hashes]. So the campaign's DARIA-side results stand for the merged tree: the 16 frame pieces (each "every image run passed"), `tb_wire`, `tb_daria_smp` and `tb_dbg_snap`, mode B ×9, the phase runs ×4, `cpu_A`/`B`/`C`/`ARIA` and the songs. Two reasons are stated here:
    - The frame binary compiles `avox_rx.sv` with `POCKET_ATARIVOX`, and Stratovox is in the frame set. But the fingerprint's audio column is the MiSTer system's `AUDIO_L`/`AUDIO_R` (`tb_frames.sv`, `` `TF_M `` = `tb.dut.main`), taken before the wrapper adds the AtariVox voice, so the voice's output is outside the fingerprint.
    - `tb_load`'s FA2 round trip ran on the `tb_load.sv` before `f3ef96a`. The changes since are the SaveKey tone counted on the console's own mix and the `+cpuprobe` probe behind its plusarg; neither touches the FA2 path.
  - **Plan 7.7 is not yet passed on a tree with the merge.** The campaign on `8cd6fe0` was the fresh-clone run (decision 16), and there `extra_tests.sh` failed on the SaveKey's missing pass tone (the bench's fault, fixed by `ab887f3`), so `selftest.py` failed too. The passing runs on `7701ee9` ran in a worktree whose inputs link into the main checkout, not in a fresh clone. 7.7 is repeated on the final release commit, in a clone of the local repository (not pushed): the static gates, `run_sim.sh`, the cartram gate, `extra_tests.sh`, `selftest.py` and `s4/check.sh`. The rest carries over from `8cd6fe0`'s clone by the argument above, so 7.7 is then a union across two clones.
  - **Hardware.** The owner's Rev 0 session of 2026-10-21 (3.0 item 5) ran on the RC debug build of the ÷18 tree before the merge (seed 3). It covers the ÷18 CPU, divider and guard, which the merge does not touch, but not the merged netlist (the POKEY read fix, the AtariVox escape fix) or seed 2 on silicon. The merged tree's V-hw was held on 2026-10-23 (the owner: "tests pass"), on a debug build of the final tree from Q5 seed 2's `.rbf` (`Atari7800_Pocket_2.2.4-rc-debug.zip`): Star Raiders (its title, and its AtariVox saying "Star Raiders"), POKEY music (Ballblazer or Commando), Juno First and Stratovox speech, and a short look at Spiders' overlay (row 0 box 2 green, rows 2 and 3 grey).

**V-rtl**
- `run_sim.sh`;
- `extra_tests.sh` (`AR_TAPE=1`);
- `s4/check.sh` on both sets;
- `pp_equiv.py` against F′, and `pp_guards` from F′;
- the cartram matrix with the directed s19 run, if `sram_ctrl.sv` changes (7.6).

**V-daria, at ÷18**
- Mode B with the wrapper, at the lattice's three offsets × three images, expecting the guard locked with 0 unlocks.
- `tb_wire`'s 97 scenarios and 7 mutants.
- The full frame gate: 16 images × 1,500 frames, `--expect-guard locked`, Spiders `ontime`.
- Q2 and Q5 from the pre-campaign round, and Q-mut.

**+cpu**
- `s1/check.sh` plain and `THUMB=1` with the firmware, against the amended CPI gate.
- `aria_equiv.sh` (MODES 0 and 1).
- The Thumb suites:
  - decode;
  - directed, with `l1f.S`;
  - halts, 210;
  - random, 400 × 3;
  - fuzz × 3;
  - every mutant, including `l1w_*`, with `neg_of_rd` and `sbc_carry_inverted` retired or re-targeted first.
- `run_call`, `run_modes` and `verif/run_songs.sh`.

**+div**
- The `divider` gate.
- Every simulation gate on the ÷18 lattice.
- `tb_s4` at 38.18 MHz (PSRAM `CLOCK_SPEED` 50.0, 0 violations).

**V-bench before the campaign**
- `selftest.py` for `frame_gate.py` and for the gate checkers changed by the F′ re-base.
- `fit_selftest`, if a fit script changes again.
- The smoke test after B5 (about 3 min [measured: section 10]).
- `s1/check.sh`'s new reference.

**Rev 1's extras**
- F′'s non-DARIA reference fit and its repeat, and Q4 against F′.
- `tb_load`'s FA2 round trip.
- `tb_vaxis5`.

**Other gates**
- Review and fix round.
- Plan 7.7 in the same run, if decision 16 holds: a fresh clone and `hygiene.sh`.
- **V-hw:**
  - both libraries;
  - saves (HSC, SaveKey, FA2);
  - paddles, driving and light gun;
  - the PAL items again;
  - Spiders;
  - the guard, on the release's debug build;
  - Souper songs;
  - Turbo.

**Audio content.** Decision 13 defers A9 (2026-10-19). So no gate here checks whole-core audio content while call timing changes on every image. The audio-path evidence is mode A's and mode B's per-access comparison (P13).

**Effort and calendar** [estimated]
- **Development: about 4-6 days in parallel lanes.** It covers:
  - Rev 1's items: 3-5 days (the study's costing);
  - the CPU clean-up: 1-2 days (T2 and v4 exist and pass their suites);
  - the V-bench items: about 1 day;
  - the documents and this plan's amendments: about 1 day;
  - F′ with its two fits;
  - the hold fix landing.
- **Quartus lock: about 10 fits, about 3.1-3.4 h** [estimated: 18.4-20.4 min per fit]:
  - F′'s reference and its repeat: 2 fits;
  - the pre-campaign round, Q2 ×3 + Q5 ×3: 6 fits, about 2 h;
  - Q-mut and Q4 in the campaign: 2 fits;
  - plus the smoke test after B5: about 3 min [measured: section 10].
- **Campaign:** about 40 h of wall time [measured: c76, 39 h 45 min in 48 pieces], plus about half a day for +cpu [estimated: the study's costing].
- **Review and fix round:** about 1 day. c76's final review and fix round took about 6 h [measured: `docs/daria_step7/progress.md`].
- **One owner session.**
- **In all: about 8-11 calendar days after Rev 0.** The sum is development 4-6 + pre-campaign round about 0.5 + campaign 2-2.5 + review about 1 + owner session about 0.5, which gives 8-10.5 days.

**Prerequisites**
- Owner decisions 1, 2, 3, 4, 5, 7, 8, 9, 10, 11 and 15. Decisions 6 and 13 were taken on 2026-10-19, with Rev 0.
- Rev 0's session showing the guard locked and the BupChip and Turbo working at 38.18 MHz. *Met 2026-10-21* ([rev0_record.md](rev0_record.md)).
- **The hold fix.** Rev 0's round is a trial of the method on T2 + v4. The prerequisite is every hold ≥ 0, and (h) passing, on seeds 1-3 of the combined tree's pre-campaign round.
- G1's fit-script changes landed (Rev 0).
- The Harmony commit landed first, so that the campaign runs on the final `tb_daria.sv`.

**One release or two**

For merging:
- It saves one V-daria: about 40 h of wall time, 7-8 fits and a review [measured: c76], about 2 days [estimated: the study's costing]. It also needs one owner session and one new non-DARIA reference instead of two [estimated].
- The study's reasons for two releases are mostly answered:
  - The guard's lock on silicon is answered by Rev 0's session, if it passes.
  - T2's two unnamed hold results are moot, because T2's netlists will not ship. They are still unexplained. That includes T2's Q5 seed-2 hold of −0.557 ns on `clk_sys`, on the Q5 configuration Rev 0 builds (now with v4 and A2).

Against merging:
- **COST's principle 4:** keep the CPU unchanged in the revision that changes area settings, so that a failure points at one cause.
  - The merged tree puts MR, T3, v4 and the FA2 saves into one netlist that has never been fitted, and the hold path is already placement-sensitive.
  - If the pre-campaign round fails, the diagnosis is by comparison:
    - The six v4 fits on T2's tree (MR included) are the CPU's reference already.
    - Fit the same seeds with v4 and the hold fix but without T3 and FA2.
    - Fit MR + T3 + FA2 with G1 on 2.2.1's CPU. This comparison is for every check but `clk_arm`, which 2.2.1's CPU fails at ÷18 on seed 1 [measured: the study's baseline fits].
    - That is about 6 fits, about 2 h [estimated].
- **The study's remaining case:** a ÷18 failure in a merged campaign holds back Rev 1's fixes, RTL-1 and Star Castle's saves (the study, 7.3).
  - Rev 0 tests a debug build of a different tree (T2 + v4 + A2), not the release netlist.
  - If the release's own Pocket test fails at ÷18, the release cannot ship at ÷18. Shipping at ÷19 then needs a V-daria at ÷19, a second campaign of about 40 h wall plus fits, before Rev 1's fixes reach players [estimated].

If not merged (two releases):
- **Rev 1 at ÷19** has Rev 1's contents, with B3 (the lattice line, at ÷19) and no CPU change.
  - Gates: one V-daria at ÷19, about 9 fits including the non-DARIA reference and Q4, `tb_load` FA2, `tb_vaxis5`, a review, V-hw.
  - About 5-8 days [estimated: the study's costing].
- **Rev 2 at ÷18** has the CPU, the clock, G1, the hold fix, the V-bench items and the documents above.
  - Gates: V-daria +cpu +div, with the same list.
  - **Q4:** Rev 1 has made one new non-DARIA reference. Rev 2's `bup_cpu.sv` changes R13/R14/R2's `THUMB` 0 netlist, which forces a second one unless R13, R14 and R2 are gated by `THUMB` and L1W's cells are shown absent at `THUMB` 0 (the study, 6.2). Any edit to `bup_cpu.sv` still moves `PP_EXPECT`, with `aria_equiv.sh` as its proof.
  - About 6-9 days back to back [estimated: the study's costing plus about a day].
- **Overlap.** Rev 2's development (3-5 days [estimated]) can run during Rev 1's campaign, sharing one Quartus lock and 2-3 simulation slots with it.
  - After Rev 1 ships, Rev 2 needs its pre-campaign round, campaign, review and session: about 4-4.5 days.
  - Add whatever development did not fit in the overlap: 0-2 days [estimated].
- **Total:** about 9-14 days with overlap, 11-17 back to back [estimated]. That is one more V-daria (about 40 h of wall time, 7-8 fits [measured: c76]) and a second owner session.

If ÷18 fails on silicon in Rev 0:
- **(a) One release at ÷19 with v4.** Recommended in that case, because it keeps one campaign.
  - It has Rev 1's items and the CPU, without G1 and the PLL change: a V-daria +cpu, with no +div.
  - Spiders is still on time (94.29% [measured: RTL cycles]).
  - The guard is inert, and the ÷19 race stays as in 2.2.1: accept it, or build A1.
  - It needs three v4 fits at ÷19 first (about 1 h). They have not been made, and the hold path's behaviour at ÷19 is unknown.
- **(b) Two releases,** with Rev 2 at ÷19 and the same CPU.

### 3.2 The Harmony (LPC2103 MAM) model as a standing reference: bench only

**Contents.** The owner asked on 2026-10-18: "if you still have the simulation of the harmony actual chip around we may start using that as a reference".
- **The `+mam` block** in `sim/bupchip/daria/tb_daria.sv`.
  - It is 315 added lines in a scratch copy of the bench on `aeee6d2` [measured: `git diff --stat`].
  - It must be ported onto `4fd89ef`'s `tb_daria.sv` and stays off unless `+mam=1`.
- **The tools:**
  - the bench's Python twin of the model, its checker and its analysis, and the synthetic directed tests with their checker and run script;
  - the independent model, written separately from the same manual, and its configuration variants.
- **Hard-coded scratch paths must go**, because hygiene forbids them. The plan's grep found them in seven of the scratch tools.
- **A short reference document**, `docs/HARMONY_MODEL.md`:
  - **Source:** UM10161 ch. 4.
  - **The settings in force per game,** which `docs/daria_step7/progress.md` already records ("Audio against a real Harmony").
  - **Its limits:**
    - It has never been checked on silicon.
    - Prefetch readings span 89.5-103.4% on Spiders' 16 calls.
    - MUL is charged m = 2.
    - The settings rest on an inference: that BIOS 1.06 jumps past Spiders' own start-up.
    - The driver's entry, exit and hand-back are not modelled. A 5 µs allowance gives at most 92.2% [estimated].
    - Elevator Agent, Zaxxon and Turbo need an LPC213x (Melody) board. The LPC2103 model only stands in for the first two, and Turbo has no model run at all.
  - **The reference rule:** where the chip meets a call that MiSTer misses, DARIA must be on time. Where the chip misses a call, matching MiSTer's miss is fine.
- **Nothing derived from games** goes into the repository: no `calls.csv`, traces, ratio tables or runs. Those stay in scratch.

**What it gives the player.** Nothing directly. It gives the project a timing reference closer to the real cartridge than MiSTer's soft ARM.

**Gates (V-bench)**
1. **`+mam` off changes nothing.**
   - Rebuild `tb_daria` and run one plain image. `fp.csv` must be identical, and `calls.csv` identical up to its old columns, as the scratch acceptance check did on Gorf and the Harmony runs on seven images.
   - Also build mode B/WRAPPER and make a short mode-B run, compared with an earlier run, because mode B uses the same bench.
2. **The port reproduces the scratch figures.**
   - With `+mam=1`, the ported bench on one image (Gorf or Spiders) must give the same `est_arm7` and m2t4 totals as the scratch run.
   - The comparison is private. Game-derived output stays out of the repository.
3. **The nine directed tests** (18 images, each at N1 = 4 and N2 = 8) pass their checker in all ten configurations.
4. **The independent model agrees** access for access with the bench on the directed tests' `+mamtrace`.
5. **`hygiene.sh`, lint and `div_check`** are unchanged.

`selftest.py` is not needed, because no checker changes.

**Effort** [estimated: the size of the diff and tools, about 1,900 lines]: 1-2 days, plus a few hours of runs. A 1,500-frame `+mam=1` run took 2,966-3,069 s [measured: the follow-up's Harmony runs].

**Prerequisites.** Decision 6's scope: settled 2026-10-19 with Rev 0's approval. `sim/` is outside the `src/` freeze. Land it before the release campaign.

### 3.3 A cheap real-hardware check of the chip model (owner, optional)

**What**
- Run Spiders on a real Harmony or Harmony Encore cartridge on a 2600.
- Note its BIOS version, because the model assumes BIOS 1.06's 70 MHz, mode 2, MAMTIM 4.
- Play to the first level load, about 9 s in (frames 557-572).

**Reading**
- **No picture shift or roll:** the chip meets the calls, as modelled (91.6-92.0%). Silicon confirms decision 4's basis, which answers decision 5.
- **A shift:** the chip misses them.
  - The model or its settings are wrong for these calls. At 60 MHz or in partial mode, the model itself gives 107-109%.
  - Then the owner's rule allows matching MiSTer's miss. The frame gate cannot simply go back to `late`: with L1W, DARIA is on time on Spiders, so `--overrun late` fails by construction [measured: the trial's frame gate run], and `frame_gate.py` has no third mode. The options:
    - **(a) Keep L1W** and add an `--overrun either` mode to `frame_gate.py`, with self-test cases (a V-bench change). DARIA then differs from both MiSTer and the chip on these frames, and the README says so.
    - **(b) Drop L1W** and go back to T2, late like MiSTer and the chip, with the `late` rule. T2's frame lengths at ÷18 have never been run.
    - **(c) Pace the calls** to the chip. This is neither designed nor costed (section 8).
  - That is the owner's call.

**Cost.** One owner session of under an hour, with no build and no project time.

**When.** It is not blocking: DARIA's 89.33% is measured, and only the question "is on time right?" rests on the model. But a shift would change a campaign gate and the README's wording. So if a cartridge is at hand, do it before the release campaign; Rev 0's session is the natural slot. Without a cartridge, decision 5 is answered on the model.

---

## 4. The `sram_ctrl` hold path: cause, fix, or seed rule

**What is known** [measured: the trial's seed-3 fit at ÷18: its hold path report and its fit report]
- **The path:** `sram_ctrl:sram|t_wr_q` (`clk_sys`, FF_X41_Y10_N5) → `t_last[17]` (`clk_sdram`, FF_X41_Y10_N46). It is the write-enable bit of the `{we, addr}` key that `t_new` compares (`sram_ctrl.sv:304-322` at `a54b07a`; `:321-342` with decision 11's copy).
- **The placement:** both registers sit in one LAB, joined by a local line with 0 logic levels.
- **The numbers:**
  - 0.733 ns of data delay against +1.179 ns of `clk_sys` → `clk_sdram` clock skew gives −0.503 ns at slow 85 °C.
  - The other corners give −0.419 / −0.244 / −0.239 ns.
  - The sibling `t_*_q` → `t_last` paths have 1.96-2.25 ns of data delay and +0.78 ns or more.
- **The fitter:**
  - It added 2.427 ns of hold delay on `t_wr_q`'s other fan-out (to `cp_word[2]`), but left this path on its 0.733 ns local line.
  - The fitter's hold table shows only the top 100 entries, and the seed-3 database was deleted.
- **Why the fitter left it is not known.**
  - It has failed only on v4's netlists: 1 failure and 1 thin pass (+0.040) in 6 seeds, against 0 in T2's 3.
  - Two ingredients are clear: a clock skew larger than the shortest possible route, and the fitter's hold target.
  - Today that target is 0.1 ns, from `core_constraints.sdc`'s fitter-only line, which applies to every `clk_sys` → `clk_sdram` transfer.

**Plan (Rev 0, item 6)** [estimated: about 1 day, 5-7 fits, about 1.5-2.4 h of lock at 18.4-20.4 min per fit]
1. **Name the cause.**
   - Refit seed 3 with `KEEP_DB=1`. The fit is deterministic: the trial's two seed-3 fits gave byte-identical timing and check summaries [measured: `diff`].
   - Report the path in full detail, and the fitter's hold messages for these two cells.
   - Check whether the destination takes its data on a dedicated in-LAB input that the router cannot lengthen.
2. **Try the cheapest fix that leaves `core_constraints.sdc` and the build without DARIA untouched.**
   - P11 keeps that file fixed, and its own comment says one build's padding goes in that build's SDC.
   - The fix is a fitter-only hold target for `clk_sys` → `clk_sdram` in `daria_constraints.sdc`'s fitter-only block. Written per I3's test 6, it replaces the 0.1 ns for that transfer, so it states the total, for example 0.5-0.7 ns [estimated].
   - Alternatively, a fitter-only `set_min_delay` on `sram|t_*_q` → `sram|t_last*`.
   - The Timing Analyzer still checks the real constraint.
3. **Refit** seeds 3 and 6 first, then seeds 1-3. Accept the fix when all of these hold:
   - every hold ≥ 0 at every corner, including (h) hold ≥ 0 as plan 5.4 requires, and (h) hold ≥ +0.1 ns on every seed tried as this round's acceptance margin [planner's choice] (worded 2026-10-20: the margin is on (h) hold, as the round applied it; other holds need ≥ 0);
   - (h) setup ≥ +4.5 ns at ÷18. A larger fitter hold target on every `clk_sys` → `clk_sdram` transfer competes with this setup. v4's seed 6 had +4.696 ns and seed 4 +4.821 ns [measured];
   - `clk_sdram` setup still ≥ +1.5 ns;
   - `clk_arm` and the guard unchanged within seed noise;
   - every 5.4 check passes, with (e) showing no new warning.
   - **Gates:** V-qsf (a new Q2, which the release's fits provide). `fit_selftest` is not needed, because no check changes.
   - **This round is a trial of the method.** T2 + v4 will not ship, and the path is placement-sensitive. The release's test is the combined tree's pre-campaign round: every hold ≥ 0 and (h) passing on seeds 1-3.
4. **If the SDC cannot close it,** there are two further options:
   - **A location assignment** that keeps `t_wr_q` out of `t_last`'s LAB (the trial's notes name it). Where it lives decides whether it touches the build without DARIA: in `ap_core.qsf` it joins F′.
   - **A structural change in `sram_ctrl.sv`.**
     - By 7.6 that adds the cartram matrix and the directed s19 run.
     - It changes the build without DARIA, so it goes into F′ (3.1), with a new reference and Q4. These are already in the merged release's gates.
5. **Seed rule (fallback, owner's call):** amend P12 so that the release ships a seed that passes every gate, accepting that seeds 1-3 do not all pass this one check. **Not recommended as the first answer:**
   - P12 requires every gate on all three seeds.
   - Plan 5.3's ladder says "if it still fails, analyse".
   - Seed 6's +0.040 ns shows the path is placement-sensitive, so any later change to the tree could break the shipped seed.

**What Rev 0 found, and the owner's choice (2026-10-19)** [measured: Rev 0's seed-3 refits at ÷18 on the candidate, one with a kept database]
- **The cause.** The LAB input mux that feeds `t_last[17]`'s data input also feeds the `{we, addr}` compare that makes `t_new`. `t_new` is on (h)'s setup path. So the router cannot lengthen `t_wr_q`'s wire to `t_last` without slowing the compare. On this path it added only about 0.3 ns.
- **Fitter-only targets failed** on seed 3 (the target states the total, with `core_constraints.sdc`'s 0.1 ns):
  - 0.3 ns on every `t_*_q` path: (h) hold −0.202 ns;
  - 0.5 ns on every `t_*_q` path: hold +0.253 ns, but (h) setup fell to 4.280 ns, below the round's +4.5 ns;
  - 0.7 ns on `t_*_q` → `t_last` only: hold −0.518 ns and (h) setup 3.475 ns.
- **A hold exception was dropped.** A hold multicycle of 1 from `t_*_q` to the `t_last` registers passed every check on seed 3. It is sound only while `t_last`'s load enable keeps its full check, because the enable is low on every `clk_sys` edge where the key changes. Naming the registers also relaxed the enable path (`t_*_q` → compare → `t_new` → `t_last`'s enable), so the review rejected it. A version naming only `t_last`'s data pins was being fitted when the owner chose a structural fix instead.
- **The fix the owner chose:** a second copy of the 18 key bits `{t_wr_q, t_addr_q}`, loaded exactly like the originals and kept from merging, used only as `t_last`'s data. The compare keeps the originals. The router can then lengthen the data wires without slowing the compare, and the real hold check stays. It adds about 18 registers.
- **Its gates.** It is a change to `sram_ctrl.sv`, which both builds share. By 7.6 it brings the cartram matrix and the directed s19 run (the `sram_ctrl.sv` row) and, as any RTL change, V-rtl's set: `run_sim.sh`, `extra_tests.sh`, `s4/check.sh`, `pp_equiv.py` and a new Q2 (the "Any RTL" rows; corrected 2026-10-20). It goes into F′ with a new reference and Q4, all already in the release's gates.
- **Its trial** (scratch: the equivalence proof, the SRAM benches, the synthesis report showing the copies survive, fits on seeds 3, 6, 1 and 2 and on the build without DARIA) was started and stopped before it ran, when the owner paused the work.

**The trial (2026-10-20): it passes** [measured: the trial's scratch records; the change is `7a4bf2c`, which added this paragraph]
- **The change** (`sram_ctrl.sv`): `t_wr_qd` and `t_addr_qd`, loaded on the same `clk_sys` edge from the same inputs as `t_wr_q` and `t_addr_q`; `t_last` loads `t_key_d = {t_wr_qd, t_addr_qd}`; the compare keeps `t_key`. `DONT_MERGE_REGISTER` (as `altera_attribute`) is on the originals and the copies. The `t_key`, `t_new` and `m_new` lines are unchanged.
- **Equivalence.** Yosys (yowasp-yosys 0.70, no `opt_merge`) proves the patched module equal to `a54b07a`'s: with the flip-flops stepping together (717 of 717 `$equiv` cells), and with the three clocks as free inputs (`clk2fflogic`, 778 of 778, the copy and original pairs included). Three mutants fail as they should: a copy loaded from the wrong input (M1, M2) fails both. Copies on `clk_sdram` (M3) fail only the clock-aware pass's copy = original cells, the invariant added by hand; M3's outputs match the original's with aligned clocks. Initial values (0) are equal by inspection; `equiv_induct` does not check them. A Verilator lockstep bench (10^7 `clk` cycles, `clk_74a` asynchronous) finds no output or `t_last` difference and catches all three mutants, M3 by its copy-equals-original assertion only.
- **Synthesis.** `sram_ctrl` goes from 526 to 542 registers: `t_wr_qd` and `t_addr_qd[14:0]` survive. Bits 15 and 16 are constant 0 in the Pocket build, as in the originals. No `sram_ctrl` register is merged (the control fit merges two).
- **The fits** (the ÷18 ones on the trial's tree, `4fd89ef` + its diff; the two `a54b07a` + copy rows on `a54b07a` with the copy; figures in ns; `clk_arm` and `clk_sdram` at the worse slow corner, the hold columns the minimum over every corner):

| Fit | `clk_arm` | `clk_sdram` | Worst hold | (h) setup / hold | ALMs | Verdict |
|---|---|---|---|---|---|---|
| ÷18 seed 3, no copy (control) | +2.645 | +3.084 | −0.503 | 5.790 / −0.503 | 14,954 | FAIL: (l), gate.hold, (h), as the trial's |
| ÷18 seed 3 | +2.077 | +2.797 | +0.111 | 7.349 / +0.240 | 14,999 | PASS |
| ÷18 seed 6 | +2.109 | +2.849 | +0.108 | 7.174 / +0.222 | 14,999 | PASS |
| ÷18 seed 1 | +2.018 | +2.595 | +0.083 | 6.927 / +0.299 | 14,992 | PASS |
| ÷18 seed 2 | +1.509 | +2.644 | +0.117 | 6.965 / +0.281 | 14,986 | PASS |
| `a54b07a` + copy, DARIA ÷19, seed 2 | +1.188 | +2.397 | +0.118 | 6.904 / +0.248 | 15,842 | PASS |
| `a54b07a` + copy, no DARIA, seed 2 | — | +2.818 | +0.103 | 5.460 / +0.251 | 13,451 | PASS |

  - The control reproduces the trial's seed-3 fit to the last digit, so this machine's Quartus matches the container's.
  - On seed 3 the failing endpoint, `t_wr_qd` → `t_last[17]`, has +0.387 ns of hold at the fast 0 °C corner. Every hold path into `t_last` is at least +0.304 ns. `t_wr_qd` still sits in `t_last[17]`'s LAB, but it feeds only that register's data input.
  - Every round criterion above holds: every hold ≥ 0, (h) hold ≥ +0.1 ns on every ÷18 seed, (h) setup ≥ +4.5 ns, `clk_sdram` ≥ +1.5 ns, every gating 5.4 check passing with no new warning in (e). On the build without DARIA the DARIA checks do not apply: they report FAIL [info], and that build has no guard pair.
  - `clk_arm` moves by −0.57, +0.20, +0.06 and −0.41 ns on seeds 3, 6, 1 and 2 against the trial's fits of the same seed. That is the size of the trial's own per-seed changes (−0.54 to +0.35 ns), so it is read as seed noise; these are not paired measurements. Seed 2's +1.509 ns is just above the trial's +1.5 ns rule. The guard pair passes on every DARIA fit. The ÷19 build's guard setup is +0.002 ns at slow 85 °C (reported, not gated at ÷19). 2.2.1's own seeds 1-3 gave +0.084, +0.193 and −0.262 ns there (the first AtariVox build's −0.162 to +0.391) [measured: `docs/ATARIVOX.md`, "The full build"].
  - **A ÷19 bitstream after `7a4bf2c`:** any ÷19 bitstream built after `7a4bf2c` re-runs seeds 1-3 before a seed is chosen. `ap_core.qsf`'s `SEED` 2 comment gives 2.2.1's figures (`clk_arm` +1.474 ns, guard +0.193 ns); with the copy, the same seed and divider give `clk_arm` +1.188 ns and guard-pair setup +0.002 ns [measured: the ÷19 seed-2 fit above].
  - **No control on the same tree for the last two rows.** Neither the ÷19 fit nor the fit without DARIA has a fit without the copy on `a54b07a`. The ÷19 reference is 2.2.1's documented fit. The reference for the build without DARIA is c76's Q4 (`317eaa8`, before the AtariVox: (h) setup +6.423 ns), so its drop to +5.460 ns cannot be put on the copy or on the AtariVox. F′'s new non-DARIA reference and Q4, taken with the copy in, cover it. Isolating it needs one fit without DARIA on `a54b07a`, seed 2 (the owner's call).
  - **Router duplicates.** In the fit without DARIA the router duplicated `t_addr_q[1]`, `[4]`, `[6]` and `[12]` (`~DUPLICATE`, routability optimization) [measured: its fit report, Fitter Netlist Optimizations]. Each loads on the same `clk_sys` edge from the same D, and they fall inside the `t_*_q*` group that (h) times (45 registers there, 41 in the DARIA fits). (h.retime) looks for retiming only, so it does not list them. No DARIA fit duplicated a `t_*` register; the copies themselves were never duplicated. F′'s Q4 baseline should expect them.
- **The benches** on `a54b07a` + copy: the cartram gate passes (matrix, s19, the reset sweep, midswap, forcecoinc; the nohold and nocmp mutants are caught; the plain build's 20 fingerprints equal the DARIA build's, `cartram_armimg` excluded by design). All 21 cartram fingerprints of each build equal `a54b07a`'s. The `tb_wire` scenarios bios_dpc, bios_cdf, dpc_then_souper and souper_then_cdf pass on `a54b07a` + copy and on `a54b07a`, with identical counters. They run the DARIA build; dpc_then_souper also runs the plain build as its reference.
  - **The tested file.** The gate logs' headers record `a54b07a` with `src/fpga/core/sram_ctrl.sv` modified, not the file's hash. That file was `sram_ctrl.sv` md5 `fb82841d`, the blob `7a4bf2c` commits; every patched fit carries the same file [measured: md5 of the worktree's file, the fits' copies and `git show 7a4bf2c:src/fpga/core/sram_ctrl.sv`].
  - **What the benches show.** The cartram gate's mutants (nohold, nocmp) do not touch the copy. The copy's correctness rests on the Yosys passes and the lockstep bench; the cartram, fingerprint and `tb_wire` runs are regression checks. The copy mutant M2 (`t_addr_qd[0]` loaded from `t_addr[1]`), run once through the cartram matrix on `7a4bf2c` + M2, is CAUGHT [measured: the trial's scratch run, 2026-10-20]: 19 of the 21 cases fail, every 2600 mapper case and the three Supercharger cases. The wrong `t_last` bit makes `t_new` repeat a held request, so writes are issued 3.0-3.3 times per strobe and reads are served as late as s23 (the checks allow s19). ram7800 and armimg, which make no 2600 request, pass. Midswap passes on it (not caught), and against the copy's fingerprints the 9 blend-1 cases differ while every blend-0 case is equal. So the matrix's access checks see this kind of broken copy; that does not make the system benches the proof.
- **Not run on `a54b07a` + copy:** `run_sim.sh`, `extra_tests.sh` (`AR_TAPE=1`), `s4/check.sh`, a new Q2, and Q4 against a new non-DARIA reference. They run in the release campaign's V-rtl (section 4, "Its gates"; step-7 plan 7.6's "Any RTL" rows).
- **For F′:** the copy changes the build without DARIA, so its `pp_equiv` stream hash changes (`a54b07a` `64d9eba0…1b0d`, with the copy `478f8b4a…57b2`). F′'s `PP_EXPECT` must be taken with the copy in.

---

## 5. Open technical risks (most severe first)

1. **The `sram_ctrl` hold** (section 4).
   - It blocks a release under P12 until it is fixed or ruled on.
   - The fix is tried on T2 + v4. It proves itself only on the combined tree.
   - Related: T2's Q5 seed-2 hold of −0.557 ns on `clk_sys` was never explained. Rev 0's debug fits use the same Q5 configuration, now with v4 and A2.
2. **(h) setup at ÷18 (+4.5 ns).**
   - v4's seed 6 cleared it by 0.196 ns (+4.696) and seed 4 by 0.321 ns (+4.821) [measured].
   - The shipping tree's Q2 seed 1 at ÷19 had +4.298 ns, below +4.5 (plan 5.4 (h)).
   - A hold fix that raises the fitter's hold target on `clk_sys` → `clk_sdram` pushes against it.
3. **÷18 has never run on a Pocket.**
   - The guard's lock is shown in simulation only. G1's physical margin beyond the corner models is unknown, and so is the width of the M10K's mixed-clock read-during-write window (`docs/DARIA_CORE.md`, open item 7).
   - PSRAM at 38.18 MHz with `CLOCK_SPEED` 50.0 (the BupChip's assets, Turbo's cache) is settled in simulation only (open item 10).
   - Rev 0's session is the check, on a debug build of T2 + v4, not the release netlist.
4. **A flatter `clk_arm` margin.**
   - v4's six release seeds: minimum +1.905 ns, mean +2.149 ns. T2's mean was +2.388 ns.
   - Q5 seed 3 is at +1.656 ns, −1.10 ns against T2's Q5.
   - On seed 1, six path groups lie within 0.43 ns [measured].
   - The combined tree will place differently.
   - Known cures if a seed falls short:
     - drop `io_guess`, which takes the `rom_addr` cone from 24 back to 20 levels [measured: Yosys proxy; not fitted];
     - predecode the pending-hit select [estimated: the verifier's suggestion, unmeasured; the nearest proxy gives `rom_addr` 25 levels and `rf_wd` unchanged].
5. **The chip model is from the manual** (UM10161) and is unchecked on silicon.
   - Spiders' settings rest on an inference: that BIOS 1.06 jumps past Spiders' own start-up.
   - Readings on Spiders' 16 calls [measured: model]:
     - mode-2 readings: 90.3-93.2%;
     - a full prefetch wait on every miss: 102.9-103.4%;
     - 60 MHz: 106.8-107.3%.
   - Section 3.3 is the cheap check. A shift there would change a campaign gate.
6. **Coverage gaps on v4:**
   - 16 of the 21 traced images were not run. They are bounded by their S1 shares (≤ 85.5%, Zaxxon), since no rule adds a clock: 0 of 5,595 measured calls got slower [measured].
   - The 9 Champ Games Presents images are unpriced (≤ 57% under S1).
   - Draconian's ARM-state helpers are covered only as far as 300 frames reach them.
   - The firmware PCM check with `THUMB=1` has not run on the cured RTL, and R1's BupChip cost is a model figure (+3.08-3.18%) until Rev 0's check runs.
7. **Rev 2's full gate set has not run:**
   - the frame gate on 16 images at ÷18 (only Spiders, 600 frames, has run);
   - mode B at three offsets × three images (one run so far);
   - `tb_wire` at ÷18, `tb_s4` at 38.18 MHz, and `s1/check.sh` with the firmware.
8. **The combined tree has never been fitted** (MR + T3 + T2 + L1W + FA2). Merging breaks COST's principle 4, so a failure would not point at one cause. 3.1 gives the diagnosis.
9. **No whole-core audio gate while call timing changes,** since decision 13 defers A9. P13: under V1 the frame gate cannot tell a planted audio fault from a correct build.
10. **The picture-shift fix is inferred** from frame lengths, not rendered or seen. Rev 0's session sees it, against 2.2.1 as the control.
11. **Sound.**
    - Against MiSTer, Spiders still differs in timing on 194 of 599 frames (counted, as on 2.2.1).
    - Against the chip, DARIA is now faster in total on Spiders (−9.7%) and Qyx (−4.5%) [measured: RTL over model].
    - The owner's verdict on Gorf, "a hair out of sync for the most part" (`docs/daria_step7/record.md`), remains, now measured against a different reference.
12. **Q4's identity.**
    - In the merged release there is one new non-DARIA reference, at F′, which includes the cleaned `bup_cpu.sv`.
    - This matters only if Rev 1 and Rev 2 ship separately. Then Rev 2's R13/R14/R2 change the `THUMB` 0 netlist unless they are THUMB-gated (section 2, the Rev 2 table).

---

## 6. The owner's decisions

The study's numbers are in brackets. "When" says when each decision is needed. The status is as of 2026-10-19.

**Needed now, or before the release's campaign**

| # | Decision | When | Recommendation | Status |
|---|---|---|---|---|
| 1 | [1] Unfreeze `src/` for the next release (RTL-1, RTL-2, the clean-ups and the CPU wait for it) | After Rev 0, before the release's development lands (Rev 0 commits nothing under `src/`) | Yes | **Settled 2026-10-19: yes, from the resume.** The owner: "src can be unfrozen once we unpause on 7:01 PM ET on 10/20 tomorrow." So `src/` unfreezes on 2026-10-20 at 19:01 ET, before the owner's Rev 0 session rather than after it; the decisions that rest on that session (2, 3, 5, 7, 10) stay open. Decision 11's hold fix (`7a4bf2c`) landed after the freeze lifted, as release work for F′, not as a Rev 0 commit (2026-10-20). The freeze (2026-10-16) was for 2.2.1, with RTL-1 accepted as a known issue to fix later |
| 2 | *(new)* Adopt L1W+L3 with T2's cures as the release's CPU | After Rev 0 | Yes | **Settled 2026-10-21 by the owner's Pocket session** on the RC debug build (the ÷18 tree before the merge of 2.2.2, seed 3; [rev0_record.md](rev0_record.md)). The owner: "just tested spiders arcade. no screen shift either"; the photos show Spiders' overlay with row 0 box 2 green (the guard locked) and rows 2 and 3 grey (0 late calls, 0 unlocks); "works as expected for the pal test. and turbo seems to function as expected as well". The merge of 2.2.2 changes no DARIA file, so the CPU on silicon is the release's; the merged netlist's own V-hw is still owed (3.1). Before: **proceeding, 2026-10-21; hardware confirms.** The owner chose to land ÷18 for the release before the Rev 0 session ("Land ÷18 for the release"), so the candidate CPU goes into `src/` now on that direction. The session (3.0 item 5) still has to confirm it on silicon. Before: the trial meets every pass criterion except one hold on one seed (section 4), which decision 11's copy fixed |
| 3 | [4] The divider | After Rev 0's ÷18 session | **÷18.** Fallback ÷19 with the same CPU: late calls still end, but the guard is inert (3.1, "If ÷18 fails on silicon") | **Settled 2026-10-21: ÷18, by the owner's Pocket session** on the RC debug build ([rev0_record.md](rev0_record.md)). The guard locks on silicon (row 0 box 2 green) with 0 unlocks, also after the PAL image's retune: "stayed all grey"; Spiders does not shift; the BupChip (Rikki & Vikki) and Turbo work at 38.18 MHz. The ÷19 fallback is not needed. Before: **recommended; the study's conflict is removed** [measured: RTL, mode B, frame run]. ÷18 gives both the guard lock and no late calls, and ÷17 is dropped. **Proceeding, 2026-10-21; hardware confirms.** The owner chose to land ÷18 for the release before the Rev 0 session. ÷18 lands as its own commit so that it can be reverted alone if the session finds the guard does not lock on silicon (the ÷19 fallback with the same CPU). Before: the owner chose ÷19 for the first release on 2026-10-12 (plan 5.2) |
| 4 | [7] DARIA may differ from MiSTer on Spiders | Before the campaign | Yes. The frame gate's Spiders rule becomes "on time", and the README and `docs/DARIA_CORE.md` decision 7 change with it | **Settled for Spiders** (decision 5 settled yes on 2026-10-21). The owner's rule of 2026-10-18, "if the real chip meets the calls but the mister does not, I would rather go with the chip.", covers this case on the model's evidence |
| 5 | *(new)* Is the manual-based chip model enough evidence? | Now or after Rev 0; before the campaign | Yes, proceed. Do the real-Harmony check (3.3) before the campaign if a cartridge is at hand | **Settled 2026-10-21: yes, on the model.** The owner: "no harmony cart, we operating on the model." No real-Harmony check (3.3, checklist part E) will run, so the model stands as the evidence. Before that: the frame gate's `ontime` rule and the README's wording rest on it. A shift on a real Harmony would change both (3.3). Supporting evidence of unknown source, possibly emulators: the owner, 2026-10-19, "Also I looked at youtube gameplay and saw no indication of any frame issues during any of them, maybe emulated though." |
| 6 | *(new)* The Harmony model as a standing reference in the repository: bench option and tools only, nothing derived from games | Before Rev 0's Harmony commit | Yes, as a bench-only commit in Rev 0, before the campaign | **Settled 2026-10-19.** The intent came from the owner's request of 2026-10-18: "if you still have the simulation of the harmony actual chip around we may start using that as a reference". The scope (3.2) was the plan's proposal; the owner's approval of Rev 0 as written, "Okay. start rev 0.", accepts it |
| 7 | [5] One release or two for Rev 1 and Rev 2 | After Rev 0. If the pre-campaign round fails, revisit it after the diagnosis (3.1) | **One**, if Rev 0's ÷18 session and the pre-campaign fit round pass. Otherwise two, or one at ÷19 if ÷18 fails on silicon | **Settled 2026-10-21: one release,** the owner's choice of the recommendation (still conditional on the Rev 0 session and the pre-campaign round, as recommended). Merging saves one V-daria: about 40 h of wall time, 7-8 fits and a review [measured: c76], about 2 days [estimated]. Against it: COST's principle 4, and a ÷18 failure holding back Rev 1's fixes (3.1) |
| 8 | [2] MR in `ap_core.qsf` (both builds) or `daria.qip` (DARIA only) | Before development | `ap_core.qsf`. T3, FA2 and the cleaned `bup_cpu.sv` change the non-DARIA build anyway, so the new reference (F′) is paid either way, and the `daria.qip` form is untested | **Settled 2026-10-21: `ap_core.qsf`,** the owner's choice of the recommendation |
| 9 | [3] `virtual_axis5` | Before development | Yes: −408.5 ALMs on top of MR [measured: one seed]. It staggers the axes' 1 ms update by 0-4 `clk_sys`, and equals five instances with their ticks delayed that way on every clock over 4 × 10^7 random-stimulus clocks (a bench, not a proof) | **Settled 2026-10-21: yes.** The owner: "Decision 9 yes." |
| 10 | [6] R1's cost to the BupChip, and the amended `s1/check.sh` CPI gate | After Rev 0's firmware check | Accept. +3.1-3.2% CPI; lowest clock without underrun 24.74 MHz against 38.18 MHz [measured: model, T2]. Unchanged by L1W. Rev 0 measures it on the RTL first | **Settled 2026-10-21: accept,** the owner's choice of the recommendation. The `THUMB=1` gate of `s1/check.sh` moves to 1.4208 ±1% [measured: Rev 0, song 13 on the candidate RTL]; `THUMB` 0 stays at 1.383 |
| 11 | *(new)* The `sram_ctrl` hold: fix or seed rule | After Rev 0's hold round; final at the pre-campaign round | An RTL fix: duplicate the request-key registers that feed `t_last` (section 4, "What Rev 0 found") | **Settled 2026-10-19.** The owner: "Duplicating the register sounds like the best option." The fitter-only targets failed, and the hold exception is dropped. The change is under `src/`, in a file both builds share, so it waits for decision 1 and goes into the release (F′). Its trial passed on 2026-10-20 (section 4, "The trial"), and the change is in `src/` |
| 13 | [9] The aligned audio run (A9) as a gate | Before the campaign: it changes the campaign's gate set | **Defer**: build it with D1/D2 or on a reported audio problem. This reverses the study's rule (audio gate before call timing changes), and the merged release changes call timing on every image | **Settled 2026-10-19: deferred.** The owner: "if deferring the audio check allows the testing to go faster then yes, skip over it at this time." Choosing A9 would have added 1-3 days of bench work and about 35 h of runs (12-17 h wall) before the campaign [estimated] |
| 15 | [11] The FA2 save file: one shared file like `hsc.sav`, or one per game, and its name | Before development | No technical preference found. A per-game file mirrors the cartridge's own flash. The owner's preference decides | **Settled 2026-10-21: one shared file, `fa2.sav`, for the time being.** The owner: "Shared for the time being." It sits beside `hsc.sav` and `savekey.sav` with a constant size (`docs/DEVELOPING.md`, "Add a save slot"), so the Pocket keeps one file rather than one per game; every FA2 game shares its 256 bytes (Star Castle Arcade is the only FA2 game known). A per-game file would need a Pocket test of a size-0 slot first |

**For the release**

| # | Decision | Recommendation | Status |
|---|---|---|---|
| 12 | [8] Exact audio (`docs/DARIA_CORE.md` decision 9) | Keep. Area is not binding (about 78.6-78.7% with T3 [estimated]) | Open, but nothing argues for change |
| 14 | [10] The sound's timing | Accept as documented, now measured against the chip as well as MiSTer. Pacing the calls to the chip is "later" (section 8) | Reframed by decision 4 |

**Standing**

| # | Decision | Recommendation | Status |
|---|---|---|---|
| 16 | [12] Run the campaign from a fresh clone, so that it is also plan 7.7's run | Yes. It saves a c78: 28 h 49 min of wall time [measured] | **Settled 2026-10-21: yes.** The owner: "yes, should be plenty of room now." The campaign runs from a fresh clone, so it is also plan 7.7's run |
| 17 | [13] Plan 7.6 as written for small changes | Keep it; do not narrow it | Open (recommended as is) |
| 18 | [14] BUS and ELF stay out | Yes | **Settled** by `docs/DARIA_CORE.md` decision 6: BUS among the decisions of 2026-10-04; ELF by the owner, 2026-10-07. Nothing found argues otherwise |
| 19 | [15] The PAL image generator | Commit it under `sim/` (V-bench and hygiene; it holds no game data) | Open |
| 20 | *(new)* Drop S3 (the old Rev 3) from the plan and keep it only as a reserve | Yes | Open. With decision 4 and L1W it has no driver |

---

## 7. No longer needed, and why

- **The ÷17 trial and a ÷17 release.** L1W ends the late calls at ÷18 [measured]. At ÷17 the guard would be inert [estimated: PLL edge lattice].
- **Model pricing of CPI cuts short of S3.** Done. L1W+L3 was the outcome, and it is built, measured and fitted.
- **S3 / Rev 3 for Spiders.** Spiders is at 89.33%, and no traced call is higher [measured / bounded].
- **A1, the ÷19 guard**, and guards for ÷17, ÷20 or ÷21. Not needed while the tree stays at ÷18. They come back only if ÷18 fails on silicon.
- **The two `KEEP_DB=1` refits of T2's hold results.** T2's netlists will not ship. The two results stay unexplained. Replaced by section 4, and by naming any hold failure in Rev 0's debug fits.
- **The study's divider table** comparing ÷17, ÷18, ÷19 and S3. Only ÷18 now meets both goals.
- **Riders D4 and D7 in Rev 2.** Area is not binding, and v4's margin is flatter.
- **B7 as a separate item at ÷18.** The PLL comment is rewritten with the ÷18 lines. B3 stays as a V-cmt edit: at ÷18 the lattice line is right again, but its counter[3] line must say VCO/18, 38.18 MHz.
- **The unrun question "does T2 alone avoid the 354-line frames?"** Moot with L1W. It matters again only if L1W is dropped (3.3 (b)).
- **The second designer's branch-folding stacks** (94-95% in the model). Never lockstep-tested or fitted, and not needed.

---

## 8. On demand, and later

**On demand,** as a rider on the next V-daria unless a game is waiting:
- A7, a cartridge EEPROM and the ARM chip's other peripherals (size it from the game);
- A6, code or LDM above the 64 KB window;
- A5, the C flag after a Thumb MUL (only if a game halts with code 8);
- A8, hi-register forms with H1 = H2 = 0.

**Later:**
- **The aligned audio gate (A9).** With D1/D2, or on a reported audio problem (decision 13, deferred on 2026-10-19).
- **Pacing calls to the chip:** holding each call's hand-back until the modelled chip would finish.
  - It can only delay. With v4 it could act on every Spiders call but the boot call, and on all but 8 of Qyx's.
  - It needs the MAM and ARM7 timing in hardware, plus each game's clock and MAM settings.
  - It is neither designed nor costed. The study priced pacing to MiSTer at +50-150 ALMs [estimated].
- **Exact audio (decision 9) stays.** The lean engine (D1) only if area ever binds.
- **Further CPU speed-ups** (a one-clock MUL, faster PUSH and STMIA, branch folding). Not needed for any traced call. If the chip were also the speed reference, they would move DARIA further from the chip. That is the planner's reasoning; the owner has not said so.
- **The non-DARIA 7800 items** in `docs/IMPROVEMENTS.md`: the PAL 2600 picture window, a Genesis pad option, an A78 the BIOS drops into 2600 mode.

**Area reserve,** if a later feature needs room:
- P1 (paddles; exact only if its bench proves it);
- D9/R3 (Thumb predecode beside the window);
- P3 (MARIA line-RAM flags in RAM; diverges from upstream);
- D1;
- D2;
- MR on `bup_cpu`;
- D5.

**Not recommended:**
- BUS and ELF (decision 18);
- pacing the sound to MiSTer;
- a fetch register (R6);
- the AGGRESSIVE PERFORMANCE settings.

---

## 9. Calendar at a glance [estimated]

| Step | Development | Runs / lock | Owner | Calendar |
|---|---|---|---|---|
| Rev 0 | 3-5 days in parallel (A2, G1's fit scripts, Harmony commit, hold round, documents) | About 2.6-3.6 h of lock (3.6-4.6 h with the optional ÷19 build); about 1 day of simulation | 1 session (plus the optional Harmony check) | About 3-5 days to the session, plus the time to schedule it |
| Merged release (recommended) | 4-6 days | About 10 fits, about 3.1-3.4 h of lock (the pre-campaign round is about 2 h of it); campaign about 40 h wall | 1 session | About 8-11 days after Rev 0 |
| Two releases instead | Rev 1 3-5 days; Rev 2 3-5 days, overlapping Rev 1's campaign | Two campaigns | 2 sessions | About 9-14 days after Rev 0 (11-17 back to back) |

The bases:
- fits at 18.4-20.4 min each [measured: the study's baseline fits], and the smoke test at about 3 min [measured: Rev 0's runs, section 10];
- `s1/check.sh` at 5-9 min, and +cpu at about half a day [estimated: the study's costing];
- c76: 39 h 45 min in 48 pieces, 7-8 fits [measured: `docs/daria_step7/record.md`];
- c78: 28 h 49 min, about 70 h of run time [measured: `docs/daria_step7/record.md`];
- 5-8 days per revision; merging saves one V-daria, about 2 days [estimated: the study's costing];
- the trial's run times: `tb_frames` at 600 frames, 3,045 s; mode B at 600 frames, 4,391 s [measured].

---

## 10. Step-7 plan 5.4 amended for G1 (2026-10-19)

From Rev 0's fit-script lane (3.0 item 2), on branch `rev0/g1`: commits `6e86b89`, `e125987` and `b55b4b3`. This section carries plan 5.4 forward, amended. The step-7 plan itself is not edited, except for one dated line under its 5.4 and one under its 7.2 that point here (added at Rev 0's review, 2026-10-19).

**What changed.** Before this change the fit tools held the guard pair `pd_tog` → `pd_rx` to fixed numbers: 6.000 ns setup and 1.000 ns hold. So every fit made with G1 failed (a), (b), (e) and (k) by construction [measured: the trial's 16 fits]. Now the tools read the bounds from the SDC the fit was made with, as the Timing Analyzer read it (`sdc.rpt`). They accept only a pair from a table of known pairs in `step7_report.tcl` (`guard_pairs`). One rule judges both 2.2.1's fits and the candidate's.

**Amended 2026-10-19 (G1, Rev 0): the guard pair's bounds.**
- (a), (b), (e) and (k) hold `pd_tog` → `pd_rx` to the bounds of the SDC the fit was made with, as the Timing Analyzer read it: the one `set_max_delay` and the one `set_min_delay` from `pd_tog` to `pd_rx` in the report script's `sdc.rpt`.
- The bounds must be one of two known pairs. `step7_report.tcl`'s `guard_pairs` table lists them:
  - **as first written** (`docs/daria_fe/design.md` 8.2): setup 6.000 ns, hold 1.000 ns; the fitter alone is asked for 5.5 ns (`618b5c3`);
  - **G1** (the design study, 4.6): setup 8.000 ns, hold 0.500 ns; the fitter alone is asked for 7.5 ns.
- Any other pair fails (a), (b), (e) and (k). So do a line missing, a line given twice, and a missing `sdc.rpt`. Reading the SDC therefore cannot let a stray value judge itself.
- The bounds are absolute. Neither pair belongs to a divider. 5.4 (a)'s amendment of 2026-10-14 for ÷19 (the slack reported, not gated) holds for either pair.
- The fitter-only value is not a check. (e) reports it, from the run directory's copy of `daria_constraints.sdc`, when that copy exists.

Row changes in the 5.4 table:

| # | Pass, as amended 2026-10-19 |
|---|---|
| (a) | exactly one path at every corner, with the SDC's setup bound as its relationship (6.000 ns as first written, 8.000 ns under G1), met. The ÷19 amendment of 2026-10-14 stands: at ÷19 the slack is reported, not gated |
| (b) | exactly one path at every corner, with the SDC's hold bound as its relationship (1.000 ns as first written, 0.500 ns under G1), met |
| (e) | as before, with the guard pair's two lines at the SDC's bounds listed "Complete"; the bounds must be a known pair |
| (k) | every `clk_sys` ↔ `clk_arm` path pair timed against 20 / −20 ns, except `pd_tog` → `pd_rx` (and its `~DUPLICATE` copies), timed against the SDC's bounds |

**How the guard pair's bounds are judged** (2026-10-19):
- `step7_report.tcl` reads the bounds from `sdc.rpt`, judges (a), (b) and (k) with them, and writes them to `checks.txt` ("`# guard bounds: setup 8.000 hold 0.500 (G1; ...)`", or "`none (...)`" with the reason).
- `step7_checks.py` reads `sdc.rpt` the same way. It judges (a) and (b) again from the per-corner lines of the pair in `checks.txt`, (k) from `crossings.tsv`, and (e) from `exceptions.rpt`.
- Its reading by the bounds the report script used must give the report script's verdict, or the check fails as a misread. A report written before this change used 6.000 / 1.000 ns whatever the SDC said.
- So a G1 fit judged by the older report script is judged again correctly from its own files, with no database and no refit.
- The bounds are not a rule of 5.4 but what it measures against. So both verdict lines (`verdict:` and `rules as first written:`) use the SDC's bounds, as both use the tree's table for (c.cells). (b), (e) and (k) are the same in both lines. (a) still differs between them only by the ÷19 rule of 2026-10-14.

**What a change to the checks needs** (amended 2026-10-19). (b) and (k) move to the checks that `step7_checks.py` judges again from a fit's own report files. A change to `guard_pairs` needs no refit either: a fit whose report script read no known bounds is judged again by the tree's table. Only a report script that read known bounds other than `sdc.rpt`'s fails as a mismatch. A change to `step7_report.tcl` still needs the smoke test (7.6). The checks that `step7_report.tcl` alone makes are now (d), (g), (g.legs), (i), (j), (l.clocks), (p) and the three `gate.*` lines.

**7.2, the I3 STA mutants and Q-mut's missing mark, under G1.** The expected verdicts do not change. They were re-derived from the tools' rules. The first row was also run on G1, in the smoke test's `q5_g1_nopair`, and all four rows on c76's report files with the new tools (below).

| Mutant | Expected with the pair at [1.000, 6.000] ns | Expected under G1 | Why |
|---|---|---|---|
| the guard pair removed | (a), (b), (k), (e) | (a), (b), (k), (e) | `sdc.rpt` has no line on the pair, so no bounds are known. The path keeps the ±20 ns clock bound |
| a clock-group cut added after the ±20 ns lines | (a), (b), (k), (e), (k') | the same | no `clk_sys` ↔ `clk_arm` path at all; the ±20 ns lines and the pair's lines fully overridden. The bounds play no part |
| the cut in place of the ±20 ns lines | (a), (b), (k), (e), (k') | the same | as above |
| a missing synchroniser mark | (f) | (f) | the bounds play no part |

The reason for the first row changes. With the older tools, (a) and (b) failed because the path was timed at 20 ns, not 6 / 1. Now all four fail because the SDC has no bounds on the pair.

**Evidence**

*The fit driver's self-test* (`selftest.sh`, no Quartus) [measured: run on `rev0/g1` at `b55b4b3`]:
- 172 of 172 pass (117 before).
- The new cases plant:
  - G1 at ÷18 (pass), and at ÷19 with the pair at −0.046 ns (pass as amended);
  - Q5 with G1; G1 from a report made before the change (pass);
  - the pair as first written from such a report at ÷19, with Q2's figures (pass as amended; fail as first written on (a), (l) and (h), as before);
  - G1 at ÷18 with the pair at −0.046 ns (fail (a), (l)); G1 in the SDC with the path timed at 6 / 1;
  - a pair not in the table ([0.700, 7.300] ns); G1 half applied ([1.000, 8.000] ns); the pair removed, in both report forms; two `set_max_delay` lines; no `sdc.rpt`;
  - the report script's bounds differing from `sdc.rpt`'s; a misread of (a), (b) and (k);
  - the pair's hold slack negative; two hold paths; an ordinary crossing at 8 / 0.5 ns; a crossing with no hold path; `~DUPLICATE` copies of the pair (pass);
  - the fitter-only line at 7.5 (pass) and at 5.5 (pass, reported);
  - a copy of the table without G1's row, which fails a G1 fit on (a), (b), (e) and (k); and a G1 fit whose report script lacked G1's row, judged again by the tree's table (pass).

*Saved fits judged again* from copies of their report files, with no database and no refit [measured: `step7_checks.py` at `DARIA-dev` and at `rev0/g1`]:

| Fits | Old tools: verdict / as first written | New tools |
|---|---|---|
| 2.2.1's shipping tree (c76): Q2 seeds 1-3, the seed-3 `KEEP_DB` refit, Q4, Q5 seeds 1-3 | Q2 s1 PASS / FAIL (h); s2 PASS / PASS; s3 and its refit PASS / FAIL (l), (a); Q4 PASS / PASS; Q5 s1-2 PASS / PASS; Q5 s3 PASS / FAIL (l), (a) | identical |
| Q-mut seed 1 | FAIL (f), (k') | identical |
| The three I3 STA mutants of c76 | FAIL (a), (b), (k), (e); and (k') for the two cuts | identical |
| 2.2.1 at ÷19, seed 2, and at ÷18, seeds 1-3 (the study's baseline fits) | PASS / PASS; ÷18 s1 FAIL (l), `gate.clk_arm`; ÷18 s2 and s3 FAIL (l), (a) | identical |
| v4 at ÷18, seeds 1-6 (the trial) | FAIL (a), (b), (k), (e) by construction; s3 also (l), `gate.hold`, (h) | PASS; s3 FAIL (l), `gate.hold`, (h) only (the −0.503 ns `sram_ctrl` hold) |
| v4 Q5 at ÷18, seeds 1-3 | FAIL (a), (b), (k), (e) | PASS |
| T2 at ÷18, seeds 1-3 | FAIL (a), (b), (k), (e) | PASS |
| T2 Q5 at ÷18, seeds 1-3 | FAIL (a), (b), (k), (e); s2 also (l), `gate.hold` | PASS; s2 FAIL (l), `gate.hold` only (the −0.557 ns hold) |

These match the trial's own re-judging of (a), (b), (e) and (k), and the failures left in its fit table.

*The smoke test* (`smoke/run_smoke.sh`, under the Quartus lock) [measured: run at `b55b4b3`, clean status, 2026-10-19 02:40-02:43 UTC]:
- PASS, 68 of 68 assertions. About 3 minutes of lock time for the seven projects. The earlier run at `e125987` also passed 68 of 68.
- The smoke test now has seven projects. Three are new:
  - `q5_g1`: the smoke design fitted with the copy of `daria_constraints.sdc` set to G1 (8.000 / 0.500 ns, fitter 7.500). The report script read G1 from `sdc.rpt`. It found one setup path at 8.000 ns and one hold path at 0.500 ns at each of the four corners. (k) passed at G1's bounds over 81 pairs. (e) listed both G1 lines "Complete" and the fitter's 7.500. `step7_checks.py` read (a), (b) and (k) as the report script judged them.
  - `q5_g1_nopair`: `q5_g1`'s database, `quartus_sta` only, with the guard pair's two Timing Analyzer lines removed (Q-mut's "guard pair removed" under G1). The path is timed at 20.000 / −20.000 ns. (a), (b), (k) and (e) fail on the missing bounds. No misread.
  - `q5_g1_odd`: the same with the pair at [0.700, 7.300] ns. The path is timed at 7.300 / 0.700 ns. (a), (b), (k) and (e) fail as "not one of the known pairs". No misread.
- `q5_clean` (the tree's own SDC, [1.000, 6.000] ns) read the pair as first written, and its (k) passed as before.

**For Rev 0's ÷18 fits.** `run_step7.sh` copies `step7_report.tcl` from its own tree and runs `step7_checks.py` from there. So the debug build and the hold round use the fit driver from `rev0/g1` (or from `DARIA-dev` once it is merged), with `TREE=` the candidate tree. A fit made with an older driver can still be judged again by the new `step7_checks.py` from its report files.
