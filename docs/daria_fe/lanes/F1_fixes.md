# F1: the lead's decisions on lane E's findings (DARIA step 6)

Three decisions of the lead, on `E3_rtl_issues.md` (issue 1, note 1) and `E2_directed.md` (6.1). For each: what changed, why, how it was verified, and the area. Areas are Quartus synthesis estimates of `daria_fe_probe` (`daria_fe_map.sh daria_fe_probe --synth`, the probe wrapper in `EXTRA_SRCS`), against the RTL as committed before these changes: **1,667 ALMs, 1,094 registers**.

| # | Decision | Result |
|---|---|---|
| 1 | Drop a stranded post action at `pclk1` (E3 issue 1, option (a), refined) | Done. +4 ALMs, +0 registers |
| 2 | Make `al` follow upstream's lane register exactly, and `pause_lane` must-be-0 (E3 note 1) | **Not done**: no exact equivalent exists. The near-exact form costs about 12 ALMs. `pause_lane` stays counted. It cannot occur on the Pocket, which never pauses the core; the near-exact form is kept as a patch for a MiSTer port (2, last part) |
| 3 | Accept `cdf_jump_ffe`'s exposure and count it as `obus_ffe` (E2 6.1, option (a)) | Done (bench only). 0 ALMs |

## 1. A post action stranded by a reset release

### Change

`src/fpga/core/bupchip/daria_fe_core.sv`:

- `pend_c`, `pend_s` and `pend_r` also clear at `pclk1`. The priority is reset, then the set at C, then the clear (`fire | pclk1`).
- `rcyc`, one flop: set while `rst_fe` is high, cleared at the first `pclk1` with `rst_fe` low. It means "this 6507 cycle ran some of its k reads under reset".
- `a_pend_late = pclk1 & !rcyc & (pend_c != PC_NONE | pend_s | pend_r)`.

### Why

The ready flags are held at 0 while `rst_fe` is high. When `rst_fe` falls after k[3] of a cycle that commits a DFxDATA/DATAW/FRACDATA read, a PUSH/WRITE, a DSWRITE or a DSPTR, the commit sets an action whose flag stays 0 for the rest of the cycle. Before this change the action stayed pending and fired in the first later cycle that set the flag, with that cycle's W: for a fetcher read, one fetcher's word written into another's (E3 issue 1). Now it is dropped at `pclk1`. The release cycle itself stays inexact, as option (a) said: upstream does that access, `daria_fe` does not.

The pointer buffer (`wb_v`) cannot be stranded the same way. Its set at C needs a CDF fetch or jump, and those need `fpend` or `jr`, which `rst_fe` holds at 0. Its set by DSWRITE/DSPTR needs the action to fire.

### The set never meets the clear

Every set (`at_dsw`, `at_dsp`, `at_svc`, `s_set`, `commit & dpw`) contains `commit` = `access & a_in[12]`. `access` = `mapper_phi2 && arm_driver_run`, and `mapper_phi2` = `pclk0 && ...` (top.sv:327). The system's `pclk1` and `pclk0` are `phi1_en = pclk1 & ~in_phase2` and `phi2_en = pclk0 & in_phase2` (top.sv:1421-1422), never high in one clock. So the set's priority over the `pclk1` clear never decides anything. `tb_fe_core` checks it on every clock (`commit in a pclk1 clock`): 0.

### No change outside a reset

Outside a reset every pending action has fired before `pclk1`; that is what `a_pend_late` checks, and it is 0 in every bench. The clear then never acts. The cost is one more term in four registers' next state.

`rcyc` is also 1 through the cycle that starts at a `pclk1` in whose clock `rst_fe` was high (a release exactly at an E0, as the unit bench's scheme switch makes). That cycle's reads all ran out of reset, so `a_pend_late` is not checked at its end, though it could be. It was kept as specified.

### Verification

- **`tb_fe_core`**, new release epochs after the existing rotation (so the rotation's streams are unchanged): one DPC+ and one CDF epoch, each with 8 console resets released in the `pclk0` clock (its edge is C) of a cycle at E0+5 or later that commits an action waiting for a read. The stream alternates such accesses with plain ROM reads during the reset, so the release cycle is never followed by an access that would repeat the stranded action and hide it. The release cycle's latch and words are classified (`rrel`) and the DPC+ fetchers resynced from upstream; everything after it is compared as usual.
  - Default run (`run_unit.sh`): 16 releases (DFx reads 4, PUSH/WRITE 4, DSWRITE 3, DSPTR 5), 16 actions dropped at `pclk1`, 2 latches and 15 words classified, **0 bad**.
  - The same bench with the old behaviour (the four mutants below together): FAIL, `a_pend_late` 213, `state` 2,052, `ram` 162 and more.
- **Mutants** (`tb_fe_core_mut.sh`), all caught: c29 `pend_s` not cleared at `pclk1`, c30 `pend_c` not cleared, c31 `pend_r` not cleared (each `a_pend_late`), c32 `a_pend_late` without `!rcyc` (`a_pend_late` in the release cycle). The full script: **45 of 45** (the 41 of lane A and these 4).
- Every other bench and suite listed at the end.

### Area

1,667 → 1,671 ALMs (+4), registers 1,094 → 1,094. `rcyc` is removed with `a_pend_late`, which nothing in the design reads.

## 2. `pause_lane`: not made exact

### What exactness needs

`al` would have to load, at every unpaused edge, what upstream's lane register loads: the low two bits of cart RAM port A's address (cart_ram_tdp.sv:61-64; `mapper_en` = `!pause`, top.sv:921), which is the 6507's `sel_ram_a` while `sel_ram_sel` is high and the engine's address otherwise (cart2600.sv:965-967). `sel_up` equals `sel_ram_sel` on every clock (A2). The 6507's byte address is the missing part.

Its value matters only at the last unpaused edge p before a pause in which a grant edge has the select low and its capture lands on the first unpaused edge. A grant needs the select low, so the select must fall between p and the grant. In a pause the bus and the scheme state are frozen, so it falls only through what changed at p itself:

| Last unpaused edge p | Cycles | Upstream's lane at p | Available in `daria_fe` |
|---|---|---|---|
| `pclk1` (E0): the next address appears after it | DPC+ direct DFxDATA, DATAW, FRACDATA reads, PUSH, WRITE: selected to the cycle's end (dpcplus.md 12.1, 12.4) | the post-commit address: $C00 + the stepped counter or fractional (PUSH: the stepped counter − 1); with no commit (before the lock, a hidden repeat), the pre-commit address | yes: `W[1:0]`, `W[9:8]`, `W[1:0] − 1` after k[3]; `cl`, `ba` |
| C: the state changes there | DPC+ fast-fetch reads (`fpend` clears), CDF fetches and jumps, DSWRITE (selected only with `access`) | the pre-commit address | yes: `cl`; DSWRITE `W[21:20]` or `W[17:16]` (W holds P32 by C) |
| E0+1 | A CDF fast-fetch operand cycle whose fetch offset covers the arming opcode ($A9, or $A2/$A0 with CDFJ+'s LDX/LDY options; offsets $7D-$A9), with an operand out of range | the select is high in (E0, E0+1) only, on the opcode byte still in `rom_do` (cdf.md Q8). The address is $800 + the table lookup's output in that clock (registered at E0, arm_mapper_tables.sv:157-163): the pointer of stream 32, the index in the opcode cycle's last clock | **no**: no pointer of that stream is read in such a cycle |
| E0 (and E0+1) | A DPC+ `LDA #` whose $A9 opcode sits on a hotspot: the bank switches at C with fast fetch armed, and from C+1 the new bank's byte there, if below $28, makes the cycle a register read (mapper_dpcplus.sv:113) | $C00 + the counter of a fetcher selected by that byte | **no**: that fetcher is never read |

The last two rows are transients of a stale ROM byte. They need a pause that starts on one particular edge, but they are reachable: the first by ordinary `LDA #`/`LDX #`/`LDY #` code in a CDFJ+ game with such an offset, and by lane E3's random bench, which draws offsets and pauses anywhere. There are two smaller gaps as well: `al` resets on `cart_reset` and upstream's lane register does not, and while upstream's `mapper_init_busy` is high its lane register loads only on `cartram_rd`/`cartram_wr`.

### The near-exact form and its cost

A prototype (not committed): `u_core` gives `cpu_lane`, upstream's lane for the first two rows (a one-flop "committed in this cycle" flag selects post-commit `W` lanes or pre-commit `cl`/`ba`/DSWRITE lanes), and `al <= sel_up ? cpu_lane : a_d[1:0]` at every unpaused edge. Synthesis: 1,671 → 1,683 ALMs (+12), one more register, and a new 3-bit input on `daria_fe_audio`. It would remove Note 1's case and every other non-transient one, but `pause_lane` would have to stay as a counted class for the transients.

The decision's own rule (its item 6) applies: no exact equivalent exists, and the near-exact one costs more than 5 ALMs. Nothing was implemented; `pause_lane` stays counted. No port changed, so `interfaces.md` has no new entry.

### Why lane B saw 0

`tb_fe_audio` freezes its select stream one clock before the engines see `pause` (`pause` is `pause_pg` registered; the stream stops on `pause_pg`). So the select at the engines' last unpaused edge always holds through the pause, and the case cannot arise there. B-1's "unreachable" (B_audio.md 1.3) is a property of that model, not of upstream. Making the unit bench reach it would need the select to change at the engines' last unpaused edge: the next cycle's pattern after a `pclk1`, the post-commit pattern after a commit.

### On the Pocket, and for a MiSTer port

**The Pocket never pauses the core.** `core_top.v:883` ties `pause_core` to 0. The Pocket reports its menu as `osnotify_inmenu`, and nothing uses that signal. `daria_fe`'s `pause` input is therefore always low on the Pocket, so `pause_lane` cannot occur there. Neither can `pause_call` (design 9.5), the paused cycles' $FF sample bytes, or anything else that needs `pause`. The owner decided (2026-10-08) that nothing is fixed here for the Pocket. The benches still drive `pause`, because upstream has it and `daria_fe` is compared with upstream.

**Where it matters.** On a core that is paused while it runs: upstream MiSTer pauses with its OSD menu open, and the Pocket would if `osnotify_inmenu` were ever wired to `pause_core`. There, `pause_lane` is one audio sample byte, read from another byte lane of the same word, in the first refresh after a pause that started on the wrong edge (E3 note 1).

**The patch.** `F1_pause_lane_mister.patch`, in this directory, is the near-exact form above as a diff against this commit's RTL (20 lines in `daria_fe_core.sv`, `daria_fe_audio.sv` and `daria_fe.sv`):
- `u_core` drives `cpu_lane`: upstream's `sel_ram_a[1:0]`. The pre-commit lanes are `cl`, `ba[1:0]`, or DSWRITE's `W` lane; the post-commit lanes are `W[1:0]`, `W[9:8]`, or PUSH's `W[1:0] - 1`. A one-flop "committed in this cycle" flag `cm` chooses between them.
- `u_audio`'s `al` loads `sel_up ? cpu_lane : a_d[1:0]` at every unpaused edge.

It applies cleanly and passes the lint of `interfaces.md` section 2, and its synthesis was the 1,683-ALM figure above. **It has not been simulated.** A port that applies it must verify it:
- the unit benches;
- a `tb_fe_audio` scenario whose select changes at the engines' last unpaused edge (see "Why lane B saw 0");
- the mode-A shadow with pauses.

With it, `pause_lane` still counts the two transients of the table's last two rows, and nothing else. The patch adds a port to `daria_fe_audio` (`sel_up`, `cpu_lane`) and one to `daria_fe_core` (`cpu_lane`), so `interfaces.md` needs the entry that decision 2 would have made.

### Documents

`design.md` 5.2 (`al`'s rule as built, B-1), 5.8 (why the select can fall after the last unpaused edge; the class's condition) and 9.5 (`pause_lane`'s condition: a capture on an unpaused edge after a grant edge in a pause, whose last unpaused edge had the select high, as `fe_shadow.svh` and `tb_fe_audio` evaluate it).

## 3. `obus_ffe`: the open bus after a substituted read at $1FFF

### Change

`sim/bupchip/daria/fe_shadow.svh`, O1: an `obus_exposed` whose read is at $0000 and whose immediately preceding latch was a shown, substituted read at $1FFF (CDF `stream_substitute`, a fetch or a jump; DPC+ `register_read`, which at $1FFF can only be a fast fetch) counts as the new class `obus_ffe`. Every other `obus_exposed` is still must-be-0. `obus_ffe` is in the "FE classes:" line and the last column of `fe.csv`.

`sim/bupchip/daria/fe_dir/`: `dircheck.py` accepts a requirement `cls:<class>` on a stage-1 counted class (skipped in stage 0); `cdf_jump_ffe` requires `cls:obus_ffe == 5`; `summary.py` prints it. `obus_exposed` stays in `dircheck.py`'s must-be-0 list.

### Why

On a fast JMP whose opcode is at $1FFE, the high operand is read from $0000 (TIA), whose D5-D0 are not driven. Upstream's `d_out` falls back to ROM[$1FFF] after the commit, `daria_fe`'s `fe_do` holds the substituted byte. On hardware the undriven lines most likely keep the cartridge's last driven byte, which is `daria_fe`'s value. No game does this. The RTL is unchanged.

### Verification

- `cdf_jump_ffe` (stage 1): PASS, `obus_ffe` 5, `obus_exposed` 0.
- The condition is narrow: a scratch copy of the shadow with $1FFE in place of $1FFF makes `cdf_jump_ffe` fail with `obus_exposed` 5 again.
- No other test of the suite shows `obus_ffe`.

### Area

None (bench only).

## What lane E3's random bench needs (not changed here: `fe_rand/` is lane E3's)

- **Decision 1.** With `+rst_bus=1`, a release cycle that commits a DFx read, PUSH/WRITE, DSWRITE or DSPTR still differs in that one access: `daria_fe` drops the action, upstream does it. `a_pend_late` stays 0 there (no exemption is needed). The bench must count that cycle (a class such as `rst_release`, condition: `rst_fe` fell after k[3] of a cycle whose commit set `pend_c`, `pend_s` or `pend_r`; visible as `u_core.rcyc` with a pending action at `pclk1`) and resync from upstream after it: the fetcher's state RAM words (DPC+), the DSWRITE byte and the P32 word in cart RAM (CDF), and the latch of that cycle. No stray write may follow: any later C1/C2 or RAM difference is a failure. `tb_fe_core`'s release epochs do exactly this (`rrel`).
- **Decision 2.** Nothing: its `pause_lane` class stays, and its condition (the lane registers differ at an unpaused capture after a paused grant) is already the exact one.
- **Decision 3.** Nothing: the random bench has no O1 check.

## Verification summary

All on the tree with the three changes.

| Check | Result |
|---|---|
| `run_unit.sh` | 10 of 10 pass |
| `run_unit.sh`, `POISON=1` | 10 of 10 pass |
| `tb_fe_core_mut.sh` | 45 of 45 caught (lane A's 41, c29-c32) |
| `tb_fe_audio_mut.py` | 64 of 64 caught, 1 equivalent (as lane B's) |
| Lint (`interfaces.md` section 2) | clean |
| `fe_dir/run_dir.sh`, `FLAVOR=s1` | 50 of 50 pass. `cdf_jump_ffe`: `obus_ffe` 5. The six pause tests: `pause_lane` 0 |
| Mode A, `FE=1`, 60 frames | Galagon (CDFJ): `FE result: PASS`, every must-be-0 count 0, 119 calls. SF2fix (DPC+): the same, 61 calls. `pause_lane` and `obus_ffe` 0 in both |
| Quartus synthesis, `daria_fe_probe` | 1,671 ALMs, 1,094 registers (before: 1,667, 1,094) |
