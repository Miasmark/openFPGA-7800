# More directed tests for the new core

These extend `../../s1/run_directed.sh` (13 directed tests, 51 halt tests). Every test runs the new core (`src/fpga/core/bupchip/bup_cpu.sv`) against MiSTer's reference in lockstep (`../tb_lockstep.sv`, `DUT=bup`). Each lockstep run happens twice: once as is, and once with random asset waits and throttle clocks (`+await=40 +throttle=25`). Nothing here needs game data.

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
| `romend.S` | Execution that falls off the last ROM word, on `tb_s1.sv`. MiSTer aborts the fetch from 0x4000, so the core must halt with code 4 rather than wrap to 0. |
| `fuzz.py`, `fuzz_run.py` | Random encodings from every instruction class except branches (see `fuzz.py`). The core may halt on any of them; `fuzz_run.py` swaps each one it halts on for a NOP, and everything left must match the reference in lockstep. |
| `run.sh` | Runs all of the above. Work files go to `sim/work/bupchip/verif/directed`. |

The hand-written tests use `../../s1/directed/common.inc`. Each one ends by summing what it stored into a register, because `tb_lockstep.sv` does not check, at the end marker, that both cores' store queues are empty.

## Results (2026-10-03)

| Check | Result |
|---|---|
| `carry`, `rsamt`, `blk15`, `pcops`, `unpred` | Pass, in lockstep and with waits and throttle. The signatures of `carry`, `rsamt` and `pcops` also equal Unicorn's. `blk15` differs from Unicorn only where the base is in an STM list that is not first: the ARM7TDMI stores the written-back base, ARMv5 the original. |
| `romend` | **Fails.** The core wraps from 0x3FFC to 0 (`pc_next1[11:0]`) instead of halting. The reference takes a prefetch abort at 0x4000. |
| Fuzz seeds 1–440, 450 cells each | 440 of 440 pass. Of 198,000 encodings, 129,771 ran in lockstep (3,540,411 retires and 480,771 stores compared, 0 mismatches). The other 68,229 halted: UNDEF 43,459, RO 12,227, REG 5,868, DATA 4,003, BLOCK 2,672. |

## Mutants

To see what these tests catch, single faults were put into a copy of `bup_cpu.sv`, and `../../s1/run_directed.sh` and this `run.sh` (fuzz seeds 1 and 2) were run on each. This was a one-off check; the script that made the faults is not kept, because it patches the current text of `bup_cpu.sv`.

| Fault | Caught by (s1 = `../../s1/run_directed.sh`) |
|---|---|
| RRX carry-out taken from bit 31, not bit 0 | `carry` only (the ISA suite also catches it). `s1/directed/shifts.S` misses it: its values have bit 0 equal to bit 31. |
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
| The bypass removed, array written at once | nothing. The behavioural array makes a write visible on the next clock, so simulation never exercises the bypass unless the write is delayed as above. |
