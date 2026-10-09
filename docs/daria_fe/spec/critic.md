# Critic: the daria_fe spec set (step 6)

**Scope.** I read all seven specs in this directory: `dpcplus.md` (DPC), `cdf.md` (CDF), `audio.md` (AUD), `glue.md` (GL), `bus.md` (BU), `bench.md` (BEN) and `design_inputs.md` (DI). The task calls the last one `design.md`; no file of that name exists. Every finding below names its evidence by file:line. Where specs disagree, I re-read the upstream RTL myself and cite it.

**Paths.**
- `rtl/` = `src/fpga/mister/rtl/`
- `core/` = `src/fpga/core/`
- `tb/` = `sim/bupchip/daria/`
- `sk/` = `sim/bupchip/daria/frontend_study/daria_fe3.sv`, the sizing sketch

**What was not done.** Nothing was run. No ROM was used. No repository file was changed. Nothing under `rtl/arm7tdmi/` or `/home/user/lroby74` was opened.

**Edge conventions.**
- **E0** is the `clk_sys` edge that samples `pclk1`. E0+k is k `clk_sys` edges later.
- **s_k** is the slot (E0+k, E0+k+1). An M10K address issued in s_k is registered at E0+k+1.
- **X** is the edge where upstream's `arm_call_busy` falls. **M = X+1** is the merge edge. **Lch** is the launch edge (E0+7). **Ld** is the `load_end` edge.

**Tags.**
- **[blocker]**: must be decided before `daria_fe` or `fe_shadow.svh` is coded.
- **[fix]**: spec text is wrong.
- **[gap]**: no spec covers the behaviour.
- **[accept]**: the lean design cannot match upstream here; it should be counted, not fixed.

---

## 1. Contradictions between the specs

### 1. [fix] Which address the 6507 holds during a call stall

**What DI says.**
- DI:107-114: "C2 … is the cycle that is held, presented again every cycle". "The CPU model holds the operand instead". With a release at j = 0…5, "the first commit substitutes and advances the stream … the second returns the ROM operand".
- DI:652: "the held cycle C2 is committed only after the release".
- DI:716 (R13): the guard "removes upstream's second commit (… the ROM stream index in place of the stream byte)".
- DI:729 (doubt): repeats the same claim.

**What the other six specs say.** The held repeats present the address of **F**, the opcode fetch after the CALLFN write. The duplicate at release is F's address again. The operand is committed once and substituted correctly.
- BU:740-745, 891-892
- GL:346-347, 362, 369
- CDF:886-891, 908-913
- DPC:90-102, 601-609, 903-906
- AUD:850-865

**RTL (re-read).**
- The hold is `hold = ~rdy_cy & ~wr_q` (rtl/6502/mos6502_ctl.sv:874-876).
- `hold_mask` clears `adl_abl`. `adh_abh` survives only on the `sb_adh & carry` path (:936-955). It is applied through `c_pre` at the phase-1 edge (:957-967).
- ABL and ABH load only at `phi1_en`, under `adl_abl`/`adh_abh` (rtl/6502/mos6502_dp.sv:201, 225-226).
- So a held cycle never loads its own address. Every repeat reads F's address. C2's address appears only in its completing pass.

**Consequence.** The release-window duplicate is a second commit of F, an opcode fetch. It is idempotent for CDF and DPC+ (BU:793-813). It changes state only if F lies in the DPC+ register window: `$x000`, `$x001` or `$x008-$x01F` (GL:369).

**Resolution.**
- Rewrite DI §1.2 (bullets "C1"/"C2", "j = 0…5"), the bracket in §9.1, and the R13 "Answer" column.
- R13's guard stops being a correctness fix. Keep it only in the phase-flag form of finding 16, or drop it.
- DI §9.1's conclusion still holds: during a call, only audio reads are consumed.

### 2. [fix] Whether the release guard applies to `arm_dma_busy` too

**The disagreement.**
- GL:452 (G1) says: guard `arm_call_busy` only. Do not guard `arm_dma_busy`; match upstream's DMA X instead.
- DI:716 (R13) gates both `call_busy` and `dma_busy` with `|sl[10:5]`.

**Why GL's premise fails for DARIA.** GL assumes the clone reproduces upstream's DMA X. DARIA's copy engine does not.
- Upstream's fill falls at E0+11+⌊(N−2)/4⌋. Its copy depends on the DDR3 latency D (GL:201-207, 254-255).
- DARIA's engine moves one byte per two background slots (DI:422, 489-492; sk:520).

**Resolution.**
- For DARIA, apply the guard to both signals or to neither. Note in GL G1 that it holds only for a clone that reproduces upstream's DMA timing.
- In mode A neither guard is visible: the 6507 stall there is upstream's (BEN:658, 844).

### 3. [blocker] Which guard to build for the shared-edge race (open item 7)

**The disagreement.**
- DI:706 (R3) chooses the front-end guard (a′).
- BEN:508 records "Decision for this run (user): build the guard" for the CPU-side store W-wait. BEN:908 (§10 row 1) costs it at "≈ 10 FF + a W term".

**Why the CPU-side guard is not cheap.**
- Stores to cart RAM are one-clock stores. They raise `ram_we` in execute (core/bupchip/bup_cpu.sv:1155-1161).
- `w_wait` is consulted only for an asset load in W (bup_cpu.sv:148, 179; DI:673).
- STM beats write on every clock (bup_cpu.sv:1258-1263).
- So guard (a) is a new execute-stage stall on step 3's critical path, which has +0.29 ns on its worst seed (DI:673).

**Why BEN's detector is not exact.**
- BEN:509 samples a `clk_sys` toggle on `clk_d` through two flops, under the clock-pair bound of ±20 ns.
- DI:679 and DI:691 show that this bound does not fix which edge captures a toggle 8.73 ns away. So the 2, 3, 3 interval pattern BEN relies on is not guaranteed.

**Resolution.**
- Under the user's rule ("minimal cost and does not cause the core to fall out of sync"), adopt (a′). Section 4 has the facts and the spec.
- Replace BEN §10 row 1 and the BEN:508 bullet.
- Keep BEN's `+d_ofs` sweep and coincidence counters, with `daria_fe`'s consumed reads as the read side.

### 4. [blocker] Exact audio timing versus a counted lag

**The disagreement.**
- DI §7.1 (DI:588-595) expects AMPLITUDE to lag, counted as `amp_lag`. DI §5.1-5.2 confines audio to s8–s1 on a W register shared with the front end (DI:444, 460-467, 484-487).
- BEN:826, 861-863 and 910 (guard 3) say an exact sequencer costs "a few states" and make `amp_lag` = `note_race` = 0. BEN:739 adds "With an exact sequencer it must be 0".

**Why the exact sequencer does not fit.** On DI's datapath and port plan it is not a few states (finding 27).

**Resolution.**
- The step-6 target is DI §7.1: `amp_lag` and `note_race` are counted and exactly classified.
- Reword BEN Q2 and §10 row 3 as a costed option, not a pass criterion.

### 5. [fix] Seeds latched at E0+7 versus deferred tick jobs

**The disagreement.**
- BEN:717, 867 and 909 say: latch the three counters at E0+7, so `seed_race` = 0.
- DARIA applies a tick as deferred voice jobs, one voice per 6507 cycle, each chosen at s7 (DI:388-390, 485; sk:636-647, 671-676).

**Why a literal latch fails.**
- Take a tick at an edge T ≤ E0+6. Its three voice jobs need up to about three cycles. If they have not all run, the tick is missing from the state-RAM counters at E0+7.
- Upstream's seed and payload include every tick up to E0+6 and none at E0+7 or later (rtl/arm_mapper_audio.sv:191-195, 207-211; rtl/arm_mapper_controller.sv:149-161).

**Resolution.**
- Define the seed as the *logical* counter in (E0+6, E0+7].
- Get it by ordering, as DI R8 says: count the pending ticks at the commit, run them, then run the seed job.
- Keep `seed_race` = 0 as the acceptance. Remove "latch the state-RAM words at E0+7" from BEN §10 row 2.

### 6. [blocker for the bench] How mode A delivers the returns

**The disagreement.**
- DI:712 (R9) feeds upstream's six returns and a strobe at M = X+1 straight into the merge, which is exact.
- BEN:684-685, 741 and 864-866 emulate `ret_tog`. `daria_fe` then syncs it and reads the returns itself, so the merge is late. That is classed as `merge_race` and resynced.

**Resolution.**
- Make BEN's emulation the default, because it tests the real return path.
- Add R9's hook as `+fe_merge_hook=1`. With the hook, `merge_race` must be 0. That separates merge-logic bugs from timing races.

### 7. [fix] When F6 starts

**The disagreement.**
- BEN:854 and 911 start F6 on `load_end`, because "the front-end ROM is complete at `load_end` anyway".
- DI:407 and DI:709 (R6) start it when the capture window closes, 64 `clk_sys` after `load_end`.

**What the Pocket does.**
- The cartridge's last bytes can arrive about 10 `clk_sys` after `cart_download` falls (core/bupchip/bup_capture.sv:37-45).
- The capture takes them by address until `c_close` (bup_capture.sv:141, 150-162; `cap_we` at core/bupchip/bupchip_pocket.sv:354).
- DPC+'s F6 copies image $6C00-$7FFF, which is the last bytes of the file (rtl/arm_mapper_ram_init.sv:156-161).
- BEN's statement is true only in tb_daria, where `load_end` comes four edges after the last byte (BEN:80).

**Resolution.**
- Start F6 at the window close, exported or counted as in R6. The bench uses the same rule.
- The OR hold (BEN:608-628) absorbs the later start.
- GL:161 ("busy for exactly upstream's duration") applies only to a clone run without that hold. Note this in GL.

### 8. [blocker for the bench] What drives `call_ready` in mode A

**What BEN says.** BEN:602 and 855 drive `call_ready` from `dut.cart2600.arm_call_ready`.

**Why that fails.**
- `arm_call_ready` includes `!call_busy` (rtl/arm_mapper_controller.sv:86-87).
- `call_busy` is high from E0+7 (:149-161) until X (:163-177).
- DARIA posts only after its seed copies (DI:310-311). The sketch runs three seed jobs, one per cycle (sk:629, 644, 690-693).
- So the lean's post would wait until X. By then the emulated `ret_tog` (BEN:685) has already flipped:
  - the bench sees `ret_unasked`;
  - the lean never sees its return;
  - its `call_busy` sticks;
  - every later CALLFN is mistracked.
- A constant ready does not fix it. A warm upstream call ends at X = E0+21 (GL:317), before a lean post at about E0+20…44.

**Resolution.**
- In mode A, set `call_ready = arm_online_sync2 && shadow_ready_sync2 && !effective_reset`, with no `call_busy` term.
- The bench queues each upstream return (the six words and the flip) and releases it only after the lean has posted that call number.
- Compare posts with accepts by call number (BEN R1).

### 9. [blocker] Which ROM timing is the target

**What CDF, DPC and BU say.** They specify MiSTer's `sdram.sv` path:
- stale bytes at E0+1, and at E0+2 the previous word's byte at the new lane;
- no refetch after a bank switch;
- "a clone must model `rom_do` as byte of the last address change".

Evidence: CDF:391, 744-750, 976 (Q24), 999 (G11); DPC:275-286, 832-841, 999-1001; BU:340-352.

**What the comparison actually uses.**
- tb_daria's oracle ROM is `cart_q <= rom[cart_addr[18:0]]` on every `clk_sys` edge (tb/tb_daria.sv:124-129; `cart_out` at :198). It shows the current `rom_a`'s byte from E0+1 and refetches after a bank switch.
- The lean reads its own front-end ROM at the current bank in s0 (DI:436).

**Resolution.**
- State that step 6's exactness target is tb_daria's 1-clock ROM (BEN:185).
- Mark CDF Q8/Q24/G11 and DPC §12.2's transients as MiSTer-only, outside the target.
- An `sdram.sv`-like ROM model, if wanted, can only serve upstream; the lean cannot follow it (finding 28).

### 10. [minor] How RSYNC changes the phase lengths

**The disagreement.**
- CDF:66 and 1030 say L1 "can be 2 or 4".
- BU:79-113 says phase 1 is 6 or 2 `clk_sys`, and phase 2 is 6 or 10.

**RTL.** The reload `pclk_div <= 2` happens at `hclk.edge_p2 && rsynd` (rtl/TIA.sv:565-567). That edge is always an `oclk_tog = 1` ce, where the pre-reload count is odd.
- A pre-reload count of 3 gives a 10-clock phase 2.
- A pre-reload count of 5 gives a 2-clock phase 1 (:505-506, 556-558).

**Resolution.** Use BU's figures. Fix CDF §0.2 and Q6.

### 11. [minor] MARIA's cycle length during a reset

**What DI says.** MARIA's phases are "4 or 6" `clk_sys` and `phi1` comes "every 8 or 12 `clk_sys`". From that, DI derives an F6 rate of 1 byte per 16 `clk_sys`, so 8 KB takes about 9 ms and 32 KB about 37 ms (DI:42, 45, 422, 456).

**RTL.**
- `ctrl_reg` is reset by `effective_reset` (rtl/top.sv:742), which clears `maria_en` (:1369-1371).
- `sel_slow_clock` is 1 while `!maria_en` (rtl/Maria/control.sv:64).
- `slow_clk_latch` takes `sel_slow_clock` at each `pclk0` (rtl/Maria/maria.sv:192-193).
- `clock_div` reloads with 2 for both phases (:220).
- So a 2600 reset runs 6/6 phases: 12-clock cycles. One 10-clock cycle is possible only right after leaving 7800 mode.

**Corrected rate.** The sketch's `go` (sk:520) gets 5 slots per cycle, about 2.5 bytes per 12 clocks. That is about 2.7 ms for 8 KB and 11 ms for 32 KB.

**Resolution.** The conclusion stands: F6 runs on its own enable. Correct the numbers. Shorter 7800-mode cycles do exist on the BIOS path (finding 22).

### 12. [minor] Whether upstream always accepts a call at E0+7

**The disagreement.**
- BEN:695: "upstream always accepts at E0+7".
- BU:815-833 and 1093-1098, AUD:184-196 and 896-901: an RMW on CALLFN queues a second call, accepted at X+1. Its seeds are the pre-merge counters.

**Resolution.** BEN R1 must allow an accept at X+1. Finding 18 covers the rest.

### 13. [minor] Stale cross-references in AUD

AUD:864-865 and AUD:1450-1465 say that DPC §8.3 assumes W+2's address is on the bus. DPC:601-609 already says W+1. Fix AUD's wording.

### 14. [minor] Notation clashes

| Letter | Meaning in one spec | Meaning in another |
|---|---|---|
| D | upstream's release edge (DI:329, 391, 712) | the audio dispatch edge (AUD:83) |
| X | upstream's release edge (GL, BU, AUD) | — |
| L | the `load_end` edge (GL:48) | the launch edge (AUD:87, DI) |

**Resolution.** Use X for the release, M for the merge, Lch for the launch and Ld for `load_end`.

---

## 2. Behaviour no spec covers, or covers wrongly

### 15. [blocker] A commit tied to `sl[5]` misses irregular cycles

**What DI says.** DI keys the commit to the slot: `commit = sl[5] && access` (DI:47, 441, 456; sk:401).

**What the other specs say.** GL:14, CDF:64, DPC:63-65 and BU:110-111 key every rule on the `pclk1`/`pclk0` events themselves.

**Three kinds of irregular cycle occur with `arm_driver_run` = 1.**

1. **The MARIA → TIA handoff after every reset release.**
   - In WAIT_TARGET_SAME, `cpu_phase_controller` keeps emitting the active (MARIA) phases. It switches only after the TIA produces the same phase as the last one emitted, then takes the TIA's opposite phase (rtl/top.sv:1287-1297, 1325-1342).
   - So a phase can be stretched by up to about 6 `clk_sys`. It is never shortened.
   - The request starts when `ctrl_writes == 2 && tia_en` (rtl/top.sv:259-260). With `bypass_bios` that is the first clock after release (rtl/top.sv:1376-1382), so `access` can already be 1 in that cycle (BU:924-928).
   - A stretched phase 1 puts `pclk0` in s(5+j).
2. **RSYNC.** Phase 1 can be 2 `clk_sys` (`pclk0` in s1), or phase 2 can be 10 (BU:107-113).
3. **The first line end after the TIA's reset.** It may misalign the divider (BU:79-86). Whether it does is not established. BEN S1 (BEN:729) must report it.

**Resolution.**
- Set `commit = access` in whatever slot it comes.
- Key the post-commit writes (DI's s6 and s7) to commit+1 and commit+2.
- Generate the background slots from a free-running sequencer, not from the `phi1` ring. This also fixes findings 21 and 22, and pause.
- Add `pclk0` as an input.
- A phase 1 shorter than 4 clocks remains a mismatch (finding 26).

### 16. [gap] The release guard misbehaves in a pause and in irregular phases

**The problem.**
- R13 lets the busy signals fall only in `|sl[10:5]` (DI:716).
- R11 wraps the ring from s15 to s8 during a pause (DI:714). So s8–s10 recur while the 6507 is frozen, possibly in its phase 1. After the pause, the held cycle's `pclk0` sees the stall low, and the duplicate commit returns.
- A stretched phase 1 (finding 15) also puts s5–s10 inside phase 1.

**Resolution.**
- Release only while `in_phase2`: set at `pclk0`, cleared at `pclk1`. These are the paired enables (rtl/top.sv:1420-1427).
- This is exact for any cycle length. It needs `pclk0` as an input, because `access` is 0 on a hidden phase.

### 17. [gap] A console reset during a call races F6 against the CPU's last stores

**How long the CPU keeps storing.**
- `daria_mreset` passes through `mres_a`, two `clk_arm` flops, then `cpu_run`, one more (core/bupchip/bupchip_pocket.sv:226-241).
- `ram_we` is combinational from the execute state (bup_cpu.sv:1155-1161, 1201, 1262).
- So stores can continue for about 3 `clk_arm` (about 1.1 `clk_sys`) after `cart_reset` rises.

**Why that races F6.**
- Upstream's first DMA is accepted at Q+2 (GL:88-89).
- F6 starts at word 0 for both schemes (rtl/arm_mapper_ram_init.sv:141-152).
- A CPU store in that window can land after F6 has written the word, or on the same shared edge. An M10K write/write collision there is undefined.
- DI intends a clean image (DI:369; GL:457 G6).

**Resolution.** Start F6 at least 4 `clk_sys` after the rising `cart_reset`. Use 8, with a 3-bit counter. This costs almost nothing and causes no desync: F6's duration differs from upstream's anyway, and the hold absorbs it.

### 18. [gap] An RMW on CALLFN: a second CALLFN while busy

**Upstream.**
- The final write W+1 is shown and sets `call_pending` again.
- The second call launches at M with the pre-merge counters as seeds and payload; the merge compares against the old seeds.
- The stall dips for one clock.
- Evidence: BU:815-841; AUD:184-196, 1343-1344; CDF:896; DPC:924-935.

**The gap.** DI §3.1 (DI:310-315) has no rule for a CALLFN commit while `call_busy` is high.

**Resolution.**
- Keep a one-deep pending flag.
- At the first call's merge, take the *pre-merge* counters as the second call's F2-F4, then merge.
- Keep `call_busy` high between the two calls. Upstream's one-clock dip cannot be matched; count it as `rmw_call`.
- No driver does this, but the values must still match.

### 19. [gap] DI's pause behaviour is incomplete

**What DI says.** R11 (DI:714): AMPLITUDE becomes $FD or nibble $F during a pause.

**What AUD:1103-1126 adds.**
1. If the frozen 6507 cycle raises a select (a DPC+ function 1-3 read, PUSH/WRITE, or a CDF substitution once the ROM byte has arrived), upstream grants no audio read for the whole pause. AMPLITUDE keeps its pre-pause value.
2. Digital ROM samples read real data.
3. `mapper_read_lane` freezes, so a capture that straddles the release reads a stale lane (AUD:379-389; rtl/cart_ram_tdp.sv:61-64).
4. Upstream's ARM stops during a pause, while DARIA's CPU runs on (DI:609).

**Resolution.**
- Either mirror the frozen select from `daria_fe`'s own decode, or declare pause outside step 6's scope.
- The bench ties `pause` to 0 (tb/tb_daria.sv:192). Count any post-pause divergence.

### 20. [gap] A CDFJ+ DSWRITE that wraps into the table area

**Upstream.**
- The pointer and increment tables are copies. They are written only by init, by the port-B snoop and by their own writeback (CDF:832-845; rtl/arm_mapper_tables.sv:139-150).
- A 6507-side DSWRITE whose display byte wraps into 0x098-0x1AF changes RAM only (CDF:873, 958-961).
- That range holds the CDFJ/CDFJ+ pointer words 0x026-0x048 and increment words 0x049-0x06B.

**DARIA.** It reads pointers and increments in place in cart RAM (DI:201, 480), so it takes the new value where upstream keeps the old one.

**Coverage.** DI does not mention this. BEN's C3 and I2 would report `ptr_bad`.

**Resolution.**
- Add a class `tbl_alias`: a CDFJ+ DSWRITE with a byte address in [4·pb, 4·(ib+C)).
- Exclude that stream from the comparison until the ARM rewrites the word.
- A shadow table is not cheap.

### 21. [gap] Audio stops during a DPC+ copy

**The problem.**
- The sketch chooses no audio job while `cp_active` (sk:636).
- A 255-byte service takes about 100 6507 cycles, about 1,200 `clk_sys` (DI:422). That is more than 716, so at least one tick's voice jobs wait.
- Upstream's audio engine runs through the DMA, with its reads granted at once (AUD:1045-1054).
- BEN T2 (BEN:725) then reports an unclassified `audio_bad`. L1's class A, which allows one tick of lag, can be exceeded right after the release.

**Resolution.** Choose one:
- keep s8–s11 for audio and give the copy the other free slots; or
- compare *logical* counters at T2 (state plus pending ticks × frequency) and widen class A to the pending-tick count.

### 22. [gap] The Pocket's BIOS boot path

**What happens.**
- With `use_bios`, the core gets `bypass_bios` = 0 and `tia_mode` = 0 (core/atari7800_pocket.sv:875, 933-934, before decision 11; since then a 2600 image never boots through the BIOS on the Pocket, DARIA_CORE.md).
- The BIOS then runs in 7800 mode on MARIA phases of 4 or 6 clocks until it locks 2600 mode. `access` stays 0 meanwhile.
- In an 8-clock cycle the `phi1` ring never reaches s8, so no audio job runs. Upstream's engine keeps ticking (AUD:1127-1149).
- The sketch's 3-bit tick backlog wraps (sk:615, 624).
- Frequencies are 0 before the lock, so the counters still agree.

**Coverage.** The bench uses `bypass_bios` = 1 (tb/tb_daria.sv:196), so this path is untested.

**Resolution.**
- Use the free-running background sequencer of finding 15.
- Make the backlog saturate, or drop it while `!tia_en`.
- Add one directed `use_bios` run.

### 23. [gap] 6507 writes that land inside an audio refresh

**The problem.**
- Upstream samples the DPC+ waveform registers and every RAM byte at each grant, between T+1 and T+19. It samples `digital_mode` at POINTER_CAPTURE (AUD:484-499).
- DARIA samples in its voice-job slots, one voice per 6507 cycle, at least two cycles after T.
- One of these between the two sampling times yields an AMPLITUDE that is neither A(n) nor A(n−1):
  - a WAVEFORM write ($105D-F);
  - a SETMODE ($1FF2);
  - a DFxWRITE or PUSH into the waveform bytes at 0x0C00 and up;
  - a DSWRITE into sample bytes.
- BEN's class A (BEN:739) does not cover that.

**Resolution.** Add a class `amp_input_race`: a commit of one of those kinds between tick n and DARIA's last voice job for tick n. Classify it and resync AMPLITUDE.

### 24. [gap] Ports missing from DI §2.4

DI's port table (DI:273-283) lacks these inputs:
- `pclk0` (findings 15 and 16);
- `pause` (R11);
- `load_start` (BEN:550);
- the capture-window close (R6);
- `cart_size` and `mapper_ram_size` (already noted at DI:158).

**Resolution.** Add them to the `POCKET_DARIA` group.

### 25. [minor] The 29,696-byte DPC+ image

**The problem.**
- DI:185 relies on DC:960: "the size checks make unreachable" any ROM word past the file.
- But F6 copies image $6C00-$7FFF, and the service clamp allows sources up to $7FFF, whatever the file size (GL:479; DPC:1071-1081; rtl/mapper_dpcplus.sv:85-101).
- The front-end ROM still holds the previous cartridge there. Upstream reads stale DDR3.
- The two agree in tb_daria only because both are zero-initialised (BEN:845).

**Resolution.** Either document it as a known difference, or zero the front-end ROM words at and above the file size at `load_end`.

---

## 3. Where the lean schedule cannot reproduce upstream

### 26. [accept] A phase 1 of 2 clocks (RSYNC)

**Upstream in the bench.**
- `cart_q` is registered at E0+1 (tb/tb_daria.sv:129).
- So at an E0+2 latch, upstream gives the right plain ROM byte, DPC+ register byte and address-decoded DFxDATA byte.
- Its CDF substitutions are wrong at E0+2, and `pu_val` takes the previous edge's word (CDF:978).

**DARIA.**
- `fe_do` must come from a register (DI:632, DC:1499).
- It is first loaded from the ROM byte at E0+2 (DI:437). So the E0+2 latch sees the previous cycle's byte, and every read in such a cycle mismatches.

**Resolution.** Count such cycles as `short_phase1`, keyed on `pclk1` → `pclk0` < 4 (BEN S1), and add a directed RSYNC test (BEN:812).

### 27. [accept] AMPLITUDE and NOTE edges (the detail behind finding 4)

**Upstream.**
- An audio read is granted on every clock with no 6507 select (rtl/cart2600.sv:965), two clocks per access.
- AMPLITUDE is written at T+7 for DPC+, and at T+13 or T+19 for CDF. A NOTE frequency is written at E0+10 or later (AUD:613-621, 778-794).

**Why DARIA cannot follow it.**
- **Port B after a commit.** After a CDF fetch, jump, DSWRITE or DSPTR, DARIA uses port B in s6 (a pointer write, registered at E0+7) and in s7 (a byte write, registered at E0+8). Upstream's CDF select ends at E0+6, and DSPTR never selects at all (AUD:1182-1186; CDF:792-795).
- **DSWRITE.** It needs two port-B writes after a commit that is known only at E0+6 (sk:314-319).
- **The shared W.** DARIA has one W register (DI:460-467). Upstream's state machine computes offsets and sums in its CAPTURE states at arbitrary clocks.
- **The `fe_do` register.** It samples one clock before upstream's (E0+5, E0+6] AMPLITUDE.

**What exactness would need.**
- a separate audio datapath;
- a one-entry cart-RAM write buffer with read forwarding;
- a register holding the previous ROM byte, to mirror the stale predicate in (E0, E0+1];
- AMPLITUDE forwarded into `fe_do`.

**Resolution.**
- None of that belongs in step 6.
- DI §3.5 should also state the NOTE rule: a tick at T uses the old frequency iff T is at or before DARIA's own frequency-write edge. Classify the difference against upstream's edge as `note_race`.

### 28. [accept] MiSTer-only ROM effects

These are the effects of finding 9: stale-byte predicates, new-word lane bytes, and no refetch after a bank switch. DARIA's ROM read in s0 cannot follow `sdram.sv`. This matters only if MiSTer parity becomes a goal.

### 29. [accept] The merge edge M = X+1

**Upstream.** It merges at M from 2-flop copies (rtl/arm_mapper_controller.sv:163-177; rtl/arm_mapper_audio.sv:213-223).

**DARIA.**
- DARIA sees `ret_tog` through two flops and compares it at S3. It then reads six words (BEN:864).
- DI does not fix the read slots. With one job per 6507 cycle that takes about 72 clocks; about 10% of CDF calls would then have a tick inside the window.
- Reading in consecutive clocks takes about 7 clocks, about 1%.

**Resolution.** Add to DI §3.1 step 6:
- read F8-FD in consecutive clocks in the first held cycle after `ret_tog` (s1–s7 are free then, DI:706);
- merge in the next audio slot;
- release the stall after the merge.

### 30. [accept] F6 and copy/fill durations

**Facts.**
- DARIA's F6 and copy/fill take different times from upstream's (DI:421-422; GL:153-157, 254-257).
- In full-system runs that shifts timing (DI:608). In mode A, the OR hold and the forced stall absorb it (BEN:606-655).
- Upstream's release-window duplicate after a DMA comes from top.sv by itself. DARIA's release guard removes it.

**Resolution.** Count the difference.

### 31. [accept] Upstream-only RAM writes that cannot occur

**The behaviour.**
- Upstream's DPC+ PUSH and WRITE strobes have no `access` term. They write RAM before the lock, or on a hidden `phi2` (DPC:657-665; BU:572-589).
- DARIA writes only at a commit.
- Neither case is reachable: `lock` and `tia_en` are set together (rtl/top.sv:1376-1389), and no write cycle is ever hidden after a CALLFN or a service.

**Resolution.** Assert that `ram_wr_noaccess` is 0.

---

## 4. Console-side cart RAM traffic during an ARM call: facts for the guard

### 32. Upstream, for reference

- Port B never accesses on a `clk_sys` edge. Its accepted edges are E+1/5 … E+4/5 (rtl/cart_ram_tdp.sv:29-56; BU:971-988).
- During a call the only console-side reads that are consumed are audio reads, and each is granted at once (BU:1019-1033; AUD:1045-1054).
- No 6507-side write occurs while `call_busy` is high (BU:1050-1098, 1129-1150).

### 33. When DARIA's CPU writes cart RAM

- Port A is written only by stores executed between A27, the first driver instruction, and the sentinel jump (DI:247-263; bup_cpu.sv:1063-1078, 1300-1307). The one exception is the first `clk_arm` of a reset (finding 17).
- `daria_ready` (`parked & img_ready` through two `clk_sys` flops; bupchip_pocket.sv:373-376) is low from A5 + 2 `clk_sys` to about R7 + 2. That interval contains every such store.
- `daria_fe`'s own `call_busy`, high from the E0+6 commit until after the merge, also contains them.

### 34. `daria_fe`'s port-B traffic while the CPU writes

**(a) The 6507 slots s1–s7.**
- `daria_fe` owns cart-RAM port B on every clock of s1–s7 (sk:52, 125-128). It issues reads for the held bus, which is F's address (finding 1).
- None of these reads is consumed. The held address is never a substitution (BU:1023 row 3; AUD:1213-1228). The exception is code executing in the DPC+ register window, $1000-$1027 (GL:369).
- No writes: s6 and s7 write only after a commit (sk:314-316). The only commits inside the window are F and its possible duplicate, both opcode fetches.

**(b) The audio jobs: the reads that are consumed.**

| Job | Read | Issued in | Registered at |
|---|---|---|---|
| voice | pointer word | s9 | E0+10 |
| voice | size word | s10 | E0+11 |
| voice | sample word | s0 | E0+1 |
| digital | pointer word | s8 | E0+9 |
| digital | sample word | s11 | E0+12 |
| NOTE | frequency word | s8 | E0+9 |

- Sources: sk:674-677, 712-717 (voice); 680-684, 718-722 (digital); 685-689 (NOTE).
- A NOTE job never runs inside a call: it needs a 6507 commit.
- Relative to E0, the registering edges fall on residues (mod 3) {1, 2, 1} for a voice job and {0, 0} for a digital job.

**(c) The copy engine and F6.**
- The copy engine is idle. A service holds the 6507 until it is done, and a call and a service cannot overlap, because no RMW maps {1, 2} to {$FE, $FF} (BU:834-841).
- F6 runs only during a console reset, while the CPU is held, except as in finding 17.

**(d) The state RAM.**
- `daria_fe` reads F5-F7 and read-modify-writes counter words that lie outside 0xF0-0xFD.
- `daria_call`'s port A reads 0xF0 on every idle `clk_arm`, reads F1-F7 at A18-A26, and writes F8-FD at R2-R7 (core/bupchip/daria_call.sv:68-116).
- So no word is written on one port while it is read on the other during a call.
- F0-F7 are written before the toggle and read at least two `clk_arm` later (DI:267).

**(e) Reads that are not consumed.**
- core/bupchip/daria_mem.sv:28-29 states only that a mixed-port read of a word being written is undefined.
- That the written word itself is unaffected is Intel's documented behaviour. Nothing in the repository verifies it. Confirm it before relying on it.

### 35. Where the shared edges fall

- At ÷48 / ÷18, one `clk_sys` edge in 3 coincides with a `clk_arm` edge. Every other pair is at least 8.73 ns apart (DI:63-73).
- A clk_sys-side detector predicts "the next edge is shared" every third edge. It does not need E0, but it does need the tight reg-to-reg SDC pair on its one path (DI:684-692).
- **Mode A.** `fe_mem`'s `clk_arm` there is 5 × `clk_sys`, and every `clk_sys` edge coincides with one (tb/tb_daria.sv:79-81). The mirror's writes avoid those edges (BEN:675). A ÷18 detector sees five toggles per `clk_sys`, an odd count on every edge, so it never locks. The guard must therefore do nothing while it is unlocked.
- **÷19 fallback.** No edge coincides exactly (DI:78-83). The guard is inert again, and a different rule would be needed.

### 36. Recommended guard (meets the user's rule)

**Rule.** While `!daria_ready` (or `call_busy`) and the detector is locked, stall the audio job by one `clk_sys` whenever its next read would register on a predicted shared edge.

**Equivalent form.** Give the whole job a fixed offset that depends on the shared residue φ:

| φ | Offset | Voice-job residues after the offset |
|---|---|---|
| 0 | none | {1, 2, 1} |
| 1 | +1 clock | {2, 0, 2} |
| 2 | +2 clocks | {0, 1, 0} |

**What it requires.**
- The offset moves voice reads into s0–s3 during held cycles. Amend DI:451 ("other users stay out of s1–s7") to allow that once F's cycle has passed.
- Add finding 17's F6 delay.

**Cost.**
- 1 `clk_arm` flop and about 4 `clk_sys` flops for the detector;
- about 3 flops and a few LUTs for the stall;
- two SDC lines;
- one 3-bit counter for the F6 delay.

**Why it does not desync.**
- It is inert in mode A.
- On hardware and in mode B it moves only DARIA's own audio read clocks, inside the `amp_lag` that is already counted.
- Calls, merges and per-tick counters do not change.

**Acceptance (mode B, `+d_ofs` ∈ {0, 8730, 17460}, BEN:463-483).**
- Consumed `daria_fe` reads registered on a shared edge while the CPU is active: 0.
- `coll_d_same`: 0.
- Detector predictions against `($time-34920)%69840==0`: no mismatch after lock.

The CPU-side guard (a) is then unnecessary.

---

## 5. Decisions to make before coding `daria_fe` and `fe_shadow.svh`

| # | Decision | Recommended | Findings |
|---|---|---|---|
| 1 | Exactness target for audio | DI §7.1: count `amp_lag` and `note_race`; add `amp_input_race` and `tbl_alias` | 4, 20, 23, 27 |
| 2 | ROM timing target | tb_daria's 1-clock ROM; MiSTer `sdram.sv` quirks out of scope | 9, 28 |
| 3 | Commit and slot keying | commit on `access`; post-commit writes relative to the commit; a free-running background sequencer; `pclk0` as an input | 15, 22, 24 |
| 4 | Release guard | `in_phase2` form, for both busy signals, or none | 1, 2, 16 |
| 5 | Shared-edge guard | front-end side (a′) plus the F6 start delay; drop BEN's CPU-side guard 1 | 3, 17, 33-36 |
| 6 | Mode-A call port | `call_ready` without `call_busy`; returns matched by call number; R9 hook as an option | 6, 8 |
| 7 | Seeds and merge | logical seeds by ordering; returns read in consecutive clocks; a one-deep pending call for RMW | 5, 18, 29 |
| 8 | F6 | start at the capture close plus the delay; own enable; correct DI's rate figures | 7, 11, 17 |
| 9 | Copy engine versus audio | keep audio in its slots during a copy, or compare logical counters | 21 |
| 10 | Text fixes | DI §1.2/§9.1/R13 (held address); CDF L1; AUD cross-references; notation | 1, 10, 13, 14 |
