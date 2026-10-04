# More directed tests for the new core

These extend `../../s1/run_directed.sh` (13 directed tests, 66 halt tests). Every test runs the new core (`src/fpga/core/bupchip/bup_cpu.sv`) against MiSTer's reference in lockstep (`../tb_lockstep.sv`, `DUT=bup`). Each lockstep run happens twice: once as is, and once with random asset waits and throttle clocks (`+await=40 +throttle=25`). Nothing here needs game data.

```sh
sim/bupchip/verif/directed/run.sh                 # everything, about 1 minute
sim/bupchip/verif/directed/run.sh rsamt.S         # one test
FUZZ="$(seq 1 140)" sim/bupchip/verif/directed/run.sh   # about 15 minutes
```

| File | What it checks |
|---|---|
| `carry.S` | The shifter's carry-out from every position: each shift type by immediate (including LSR #32, ASR #32 and RRX) and by register amounts 0–255 and 0x100, on values whose neighbouring bits and end bits differ, with C in 0 and 1 |
| `rsamt.S` | Shift by register where only Rs[7:0] counts (0x100, 0x120, 0xffffff00, 0xffffff21, 0x1ff); ROR by 64, 96, 128 and 224; ADC/SBC/RSC/RSB with register shifts and carry in 0 and 1; Rd == Rm == Rs |
| `blk15.S` | LDM/STM of r0–r14 in all four modes, with and without write-back, with the base in the list; sp and lr as the base; STM of registers written in the clock before; LDM straight after STM |
| `pcops.S` | r15 as an operand that reads as the address + 8: Rm, Rn, flag-setting forms, load bases with immediate and register offsets |
| `unpred.S` | UNPREDICTABLE forms the core runs rather than halts on: halfword post-index with W set, Rd == Rm, two-clock store of the base with write-back, overlapping multiply registers |
| `romend.S` | The last ROM word, on `tb_s1.sv`: a branch there that is taken must not halt; one whose condition fails runs off the end, and as MiSTer aborts the fetch from 0x4000, the core must halt with code 4 at 0x3FFC (after exactly 14 retires) rather than wrap to 0. `../../s1/halt_tests.py` has one `romend_*` case per kind of instruction in that word. |
| `fuzz.py`, `fuzz_run.py` | Random encodings from every instruction class except branches (see `fuzz.py`). The core may halt on any of them; `fuzz_run.py` swaps each one it halts on for a NOP, and everything left must match the reference in lockstep. A DATA or RO halt says the reference would abort there, so before its NOP goes in the program runs in lockstep with `+abort_ok=1`, and the reference must take a data abort in that same instruction. |
| `run.sh` | Runs all of the above. Work files go to `sim/work/bupchip/verif/directed`. |

The hand-written tests use `../../s1/directed/common.inc`. Each one ends by summing what it stored into a register. They were written when `tb_lockstep.sv` did not check, at the end marker, that both cores' store queues were empty; it now does, and the sums remain as a second check. `../../s1/check.sh` runs `run.sh` with the default fuzz seeds, and `run_vfy.sh` plainly and with `LATE_RF=1`. Nothing here needs the firmware except `run_vfy.sh`'s decode probe, which is skipped without it.

## Results (2026-10-03)

| Check | Result |
|---|---|
| `carry`, `rsamt`, `blk15`, `pcops`, `unpred` | Pass, in lockstep and with waits and throttle. The signatures of `carry`, `rsamt` and `pcops` also equal Unicorn's. `blk15` differs from Unicorn only where the base is in an STM list that is not first: the ARM7TDMI stores the written-back base, ARMv5 the original. |
| `romend` | Failed at first: the core wrapped from 0x3FFC to 0 (`pc_next1[11:0]`) instead of halting, where the reference takes a prefetch abort at 0x4000. `bup_cpu.sv` now halts with code 4 (FETCH) when an instruction in the last word completes and the next PC is sequential; the test passes, as do the 15 `romend_*` halt tests. |
| Fuzz seeds 1–440, 450 cells each | 440 of 440 pass. Of 198,000 encodings, 129,771 ran in lockstep (3,540,411 retires and 480,771 stores compared, 0 mismatches). The other 68,229 halted: UNDEF 43,459, RO 12,227, REG 5,868, DATA 4,003, BLOCK 2,672. (Before the ROM-end fix and the end-of-run queue checks in `tb_lockstep.sv`.) |
| After both: the hand-written tests and fuzz seeds 1–48 | All pass. Of 21,600 encodings, 14,175 ran in lockstep (386,268 retires and 52,606 stores compared, 0 mismatches). |
| The same with `LATE_RF=1`, fuzz seeds 1–16 | All pass. Of 7,200 encodings, 4,669 ran in lockstep (128,784 retires and 17,407 stores compared, 0 mismatches). |
| Round 2: fuzz seeds 9–40 with the DATA/RO check | All pass. Of 14,400 encodings, 9,487 ran in lockstep (257,529 retires and 35,081 stores compared, 0 mismatches); every one of the 1,147 DATA and RO halts was matched by a reference abort in the same instruction. |
| Over-strict halts (verification round 2) | Before the DATA/RO check, any halt passed the fuzz. Two mutants that halt where the reference does not abort passed seeds 1–4 under the old `fuzz_run.py` and fail all four now: DATA on an odd-address halfword load, and the asset window cut to half its size. A mutant that halts on the last 64 bytes of the asset window passes both versions, because the fuzz never loads that far in; `vhalt.py`'s window-edge cases cover it. |

## Mutants

To see what these tests catch, single faults were put into a copy of `bup_cpu.sv`, and `../../s1/run_directed.sh` and this `run.sh` (fuzz seeds 1 and 2) were run on each. This was a one-off check; the script that made the faults is not kept, because it patches the current text of `bup_cpu.sv`.

| Fault | Caught by (s1 = `../../s1/run_directed.sh`) |
|---|---|
| RRX carry-out taken from bit 31, not bit 0 | `carry` (the ISA suite also catches it). `s1/directed/shifts.S` missed it, as its values had bit 0 equal to bit 31; it now also shifts 0x00000001, 0x80000000 and 0xaaaaaaaa and catches it. |
| ASR #0 not turned into ASR #32 | s1 `shifts`; `carry`; fuzz |
| Rs[4:0] used as the amount instead of Rs[7:0] | s1 `shifts`; `carry`, `rsamt`; fuzz |
| Rotated-immediate carry left unchanged | s1 `shifts`; fuzz |
| RSC carry-in fixed at 1 | s1 `flags`; `rsamt`; fuzz |
| V cleared by logical operations | s1 `flags`, `sbz`; fuzz |
| Odd LDRSH returning the halfword | s1 `align`; fuzz |
| LDM/STM base written back in the last beat | s1 `flags`, `ldmstm`; `blk15`; fuzz |
| LDM rotating unaligned words like LDR | s1 `ldmstm`; fuzz |
| NV condition passing | s1 `flags`; fuzz |
| BL link = address + 8 | s1 `ldrpc` |
| UMULL low word written to RdHi | s1 `deps`, `mul`; `blk15`, `unpred`; fuzz |
| W held by the throttle (an MMIO access repeated) | s1 `ldmstm`, `mmio`, `shifts`; `rsamt` (all in the throttled lockstep run) |
| Two-clock store data read from Rm | nearly every test |
| Register file written one clock late (as an MLAB might be) | nothing, as it should be: the bypass covers it |
| The same, with the bypass removed | nearly every test |
| The bypass removed, array written at once | nothing in a plain build. The behavioural array makes a write visible on the next clock, so simulation never exercises the bypass unless the write is delayed as above. `bup_cpu.sv` therefore has a simulation-only `BUP_SIM_LATE_RF` build (an entry holds garbage for the clock after its write, and the data from the clock after that); `LATE_RF=1` selects it in the build scripts, and `../../s1/check.sh` runs the directed, halt and ISA lockstep tests with it. With the bypass removed, all 13 `s1` directed tests fail in that build and pass in the plain one. |

## The verifier's tests (`run_vfy.sh`)

An independent set, written from `docs/BUPCHIP_CORE.md` without reference to the tests above: `vgen.py` generates them as `.S` files into the work directory, `vhalt.py` holds further halt cases, and `tb_vdec.sv` probes the decoder. Nothing here needs game data; the decode probe needs the user's firmware and is skipped without it.

```sh
sim/bupchip/verif/directed/run_vfy.sh             # about 30 s on 4 cores
LATE_RF=1 sim/bupchip/verif/directed/run_vfy.sh   # the core built with BUP_SIM_LATE_RF
```

| File | What it checks |
|---|---|
| `vgen.py` | 16 tests, each run by `run.sh` (reference, `tb_s1.sv` without a halt, lockstep plain and with waits and throttle). `v_shift`: each shift type by register amounts 0, 1, 31, 32, 33, 64, 224, 255, 256, 0x1f1, 0xffffff20 and 0x80000021 and by immediate 1, 31, LSL #0, LSR #32, ASR #32 and RRX, through MOV, MOVS, ADCS, RSCS, BICS, TEQ and CMN with the flags both ways, on ten values; scaled register offsets. `v_imm`: rotated immediates through all 16 opcodes, rotation 0 against a rotation giving the same value. `v_cond`: the 16 NZCV values against the 15 conditions for 14 instruction classes. `v_mul`: 12 x 12 corner values, the overlaps ARMv4 defines. `v_blk`: LDM/STM in every mode, list and write-back form. `v_deps1`-`5`: 19 producers of a register against 22 consumer positions, at once and one instruction later, plus BL's link. `v_wb`: Rd == Rn with write-back in every size and addressing mode, Rm == Rn, Rd == Rm, the T forms. `v_align`: every byte offset in RAM, ROM, the asset window (to its last byte) and the peripheral; unaligned stores. `v_blkx`: the base in the list. `v_mmio`: peripheral accesses under every NZCV and condition, offsets, write-back, sizes. `v_nv`: the NV condition on every class. `v_unpred`: MUL/MLA Rd == Rm and UMULL RdLo/RdHi == Rm. The five in `iss.txt` (`v_shift`, `v_imm`, `v_cond`, `v_mul`, `v_blk`) stay inside the subset ARMv4 and ARMv5 share, and also go through `../isa/run_isa.sh`, where the reference's signature must equal Unicorn's. |
| `vhalt.py` | 47 halt cases beyond `../../s1/halt_tests.py` (ARMv5 and coprocessor encodings, r15 in the remaining operand positions, PSR forms, S and signed multiplies, block transfers with PC, S or an empty list, branches below 0, one byte past each window) and 20 cases that must reach the end marker (the last byte or word of each window, LDM from the ROM, MSR forms that write only what the core has, condition-failed halting encodings). |
| `tb_vdec.sv` | Every one of the firmware's 1,704 code words (`../../model/inventory.py`) on the core's instruction input: none may decode as a halt, so a decode change that breaks a path no test reaches still fails. |
| `run_vfy.sh` | Runs all of the above. Work files go to `sim/work/bupchip/verif/vfy` (`vfy_laterf` with `LATE_RF=1`). |

**Results (2026-10-03).** All pass, plainly and with `LATE_RF=1`: the 16 tests in lockstep (122,660 retires and 5,795 RAM stores compared per pass; `v_mmio` adds 119 peripheral writes and 235 replayed reads); the five Unicorn-checked tests equal Unicorn's signature and instruction count; 67 of 67 `vhalt.py` cases; 1,704 code words, none decoding as a halt.

**Mutants.** 24 single faults, each patched into a copy of `bup_cpu.sv` and run through `run_vfy.sh` (one-off; the patch script is not kept). All 24 are caught:

| Fault | Caught by |
|---|---|
| RRX carry from bit 31; LSR #0 or ASR #0 not made #32 | `v_shift` (also against Unicorn) |
| Rotated-immediate carry taken from bit 31 with rotation 0 | `v_imm` |
| Loads and stores run when their condition fails | `v_cond`, `v_mmio`, `v_nv`, two `vhalt.py` cases |
| NV condition passing | `v_nv` |
| A peripheral pulse from a condition-failed access | `v_mmio` |
| UMULL low word = high word; MLA accumulator from Rd | `v_mul`, `v_cond`, `v_deps*` (`v_unpred` too) |
| LDM/STM start offset wrong for DA and DB | `v_blk`, `v_blkx`, `v_cond` |
| STM base written back before the first beat (stores the new base when it is lowest) | `v_blkx` |
| Odd LDRH not rotated; LDRSB zero-extended | `v_align` (and `v_cond`, `v_deps2`, `v_wb`) |
| Register-offset store loses its write-back | `v_wb`, `v_shift`, `v_mmio` |
| V cleared by logical operations; ADC without carry in | `v_shift`, `v_imm` (`v_cond`) |
| Rs[4:0] as the shift amount | `v_shift`, `v_deps*` |
| BL link = address + 8 | `v_cond`, `v_deps5` |
| Bypass removed on either read port, `LATE_RF=1` | every test |
| MSR control-byte check removed; LDR pc with bit 0 set accepted; STRH of PC accepted; asset offset == size accepted | `vhalt.py` (`msr_sys_mode`, `msr_irq_enable`; `ldr_pc_bit0`; `strh_pc`; `ldrh_past_assets`) |

## Dense random programs and the shifter sweep (`run_vrand.sh`)

Added in verification round 3. The tests above check one behaviour at a time: `fuzz.py` puts a known state before each encoding, and `../isa/gen_random.py` stores every result before the next operation. Here random operations follow each other directly and read what the last few wrote, so the multi-clock instructions run back to back in every order. Nothing here needs game data or the firmware.

```sh
sim/bupchip/verif/directed/run_vrand.sh                        # seeds 1-64, about 1 minute
SEEDS="$(seq 1 400)" sim/bupchip/verif/directed/run_vrand.sh   # about 8 minutes on 4 cores
LATE_RF=1 sim/bupchip/verif/directed/run_vrand.sh              # the core built with BUP_SIM_LATE_RF
```

| File | What it checks |
|---|---|
| `vrand.py` | One program per seed, 1,800 operations, every one of them defined on the ARM7TDMI and implemented by the core: data processing in every operand form (r15 as Rn or Rm too), MUL/MLA/UMULL, every single-transfer size and addressing mode at any byte offset (so unaligned words and odd halfwords), Rd == Rn, LDM/STM in every mode, with the base in the list (STM, or LDM without write-back), conditional pops, loads from the ROM, the asset window and the peripheral, MRS/MSR, forward B/BL/BX and LDR pc. About a quarter are conditional. The sources are biased to the registers written in the last few operations. With `--iss` it keeps to what ARMv4 and ARMv5 do alike and stores r0–r9, lr and the CPSR every 40 operations, so that Unicorn can check it. |
| `vshift_all.S` | MOVS with every shift type by every register amount 0–259 and by every immediate encoding (LSL #0–31, LSR #1–32, ASR #1–32, ROR #1–31, RRX), on 16 values, with NZCV in as 0000 and 1111. The reference and the new core share `arm7tdmi_pkg`'s shifter, so lockstep alone cannot fault it; Unicorn can. |
| `run_vrand.sh` | For each seed: the full mix through `run.sh` (reference to the end marker without an abort, `tb_s1.sv` without a halt, lockstep plainly and with waits and throttle); the `--iss` mix and `vshift_all.S` through `../isa/run_isa.sh` (signature and instruction count equal to Unicorn's, and lockstep). Work files go to `sim/work/bupchip/verif/vrand` (`vrand_laterf` with `LATE_RF=1`). |

**Results (2026-10-03).** Seeds 1–400 pass, plainly and with `LATE_RF=1` (about 6 minutes each on 4 cores, beside other runs). The full mix: 400 of 400 programs in lockstep, 2,572,076 retires, 1,372,994 RAM stores, 4,013 peripheral writes and 8,138 replayed reads compared per pass, 0 mismatches; about 1.19 M of the retires are the random operations, the rest the RAM fill. Against Unicorn: `vshift_all.S` (199,406 instructions, 32 signature words) and the 400 `--iss` programs, 401 of 401 equal in signature and instruction count, and 2,733,943 retires in lockstep. Two deliberate faults in a copy of `bup_cpu.sv`, run with `BUP_SRCS` set to the copy, failed all of seeds 1–16: the bypass compared on three index bits, and LDM retiring as its last beat issues (the last register landing in the next instruction's first clock). No fault in the core was found.
