# BupChip verification

Checks for the Pocket's BupChip CPU (`docs/BUPCHIP_CORE.md`, "Verification plan"). The oracle is MiSTer's reference core, `arm_host` with `arm7tdmi_core` and `bupchip_subsystem` from `src/fpga/mister/rtl`; Unicorn, an independent ARM model, checks the reference in turn. `arm7tdmi_core.sv` is GPL-2.0-only: these testbenches only instantiate it and read its simulation-only state, and nothing in this directory is taken from it.

Nothing here needs game data except the optional lockstep run on a real image. Game files, and traces or PCM made from them, stay out of the repository (`sim/work*` is ignored).

## Running

```sh
sim/bupchip/setup_dev.sh                         # tools, and Unicorn in sim/work/bupchip/venv
sim/bupchip/verif/run_all.sh                     # everything game-free, about 3 minutes
sim/bupchip/verif/run_all.sh rv.a78              # plus lockstep on Misery_F, about 1 minute more
sim/bupchip/verif/directed/run.sh                # the new core: more directed tests, end of ROM, fuzz
```

`run_all.sh` runs, and each can be run alone:

| Script | What it checks |
|---|---|
| `isa/run_isa.sh [TEST.S ...]` | `isa/sample.S` and one `isa/gen_random.py` test (300 operations) per seed in `isa/seeds.txt`, on the reference RTL and on Unicorn: the RAM signatures and the instruction count to the end marker must agree. `LOCKSTEP=1` also runs each test in lockstep; `ISS=0` skips Unicorn, for directed tests outside the subset ARMv4 and ARMv5 share. |
| `run_kernel.sh` | The mixer harness, `kernel/harness.S`: the firmware's own voice mixer on 16 made-up voices. On the reference it must reach its end marker with 4,800 nonzero frames; then lockstep to the end. |
| `run_synth.sh` | A synthetic ARSC block (`make_synth_arsc.py`): the existing `tb_bupchip` (`../run_bupchip.sh`) boots it and renders nonzero PCM with no underrun; the fault paths give faults 2 and 3; Unicorn replays a reference trace of boot and song 0 (`iss_fw_replay.py`); lockstep through every command class, and over random-content blocks. |
| `run_lockstep.sh IMAGE.a78 [+args]` | One lockstep run (below). |
| `run_songs.sh GAME.a78 [SONG ...]` | Not in `run_all.sh`: lockstep through each song (default all 32) for `SECS` seconds (default 4), odd songs with random asset waits and throttle clocks; `DUT` defaults to `bup` here. About an hour on 4 cores. |

Environment: `WORK` (build products, default `sim/work/bupchip/verif`), `VERILATOR` (default `/opt/verilator-5.040/bin/verilator` if present), `VENV` or `PYTHON` (for Unicorn), `DUT` (`ref` or `bup`), `LATE_RF=1` with `DUT=bup` (the core built with `BUP_SIM_LATE_RF`: register-file writes land a clock late, with garbage in between, so only its bypass keeps results right), `JOBS` and `OPS` for the ISA suite, `MAXRET` for `run_all.sh`'s game run.

Other files: `build.sh` (Verilator builds), `ref_system.svh` (the reference BupChip, shared by both testbenches), `tb_ref_trace.sv` (runs a program on the reference; trace, signature dump), `make_kernel.py` (the harness image), `isa/iss_run.py`, `isa/bin2hex.py`, `isa/link.ld`.

## Lockstep

`tb_lockstep.sv` runs the reference and a DUT side by side, on the same image:

- **Reference:** the real `bupchip_subsystem` (peripheral, asset cache, a DDR3 stand-in), downloaded from the `.a78` as on MiSTer.
- **DUT:** `lockstep_dut_ref.sv` by default: a second `arm7tdmi_core` (`MUL_RETIRE_STAGE` off) on a zero-wait bus, with its retires turned into the retire-port stream described below. `-DDUT_BUP` (`DUT=bup`) selects `lockstep_dut_bup.sv`: the new core, `src/fpga/core/bupchip/bup_cpu.sv`, with its ROM and RAM in `cache_ram.v` blocks and a behavioural asset memory (step 2; its own checks are in `../s1/`).
- **Peripheral reads are replayed.** Every read the reference makes of `0xE0009000`–`0xE00090FF` is queued with its value, and the DUT's reads are answered from that queue, in order. The DUT waits while the queue is empty. Both cores therefore see the same IDENT, commands and FIFO status, and the poll loops run the same number of times, whatever the timing.
- **Compared, in program order:** every retire (PC, encoding, r0–r14 and NZCV after it), every RAM store (word address, byte lanes, data), every peripheral write, and the address of every peripheral read. Either side may run ahead. Both register files start at zero, and nothing is masked.
- **Stop:** `+maxret` compared retires (default 1,000,000), `+maxcyc` reference clocks, the reference's FAULT write (the end marker of the ISA tests and the harness) once the DUT has caught up, `+maxfail` mismatches (default 5), or nothing compared for `+stall` clocks. At a FAULT-write stop every RAM store, peripheral write and replayed read of either side must have found its partner, so a missing or extra last store fails. The last line is `LOCKSTEP PASS` or `LOCKSTEP FAIL`.
- **Fault injection:** `+inject=N` flips bit 0 of the DUT's Nth data load (each shell implements it), `+inject_mmio=N` of the Nth replayed read (the testbench does, for any DUT). Either must end in `LOCKSTEP FAIL`.
- Commands: `+song=N +songcyc=CLK`, or `+cmds=8d@1000000,81@3000000` (byte in hex, at that reference clock).

### The retire port (new core)

`bup_cpu` exposes these outputs in simulation only (`ifndef ALTERA_RESERVED_QIS`, as `cache_ram.v:31` does). They describe what happens on each rising edge of `clk_arm`: the testbench samples them on every edge, so they are most simply the core's own commit and register-file write signals. A core may instead register all of them by the same number of clocks; only their order relative to each other matters.

| Signal | Width | Meaning |
|---|---|---|
| `rt_start` | 1 | The first clock of an instruction's execution: once per instruction, condition-failed ones included. Never while execute is frozen (asset miss, throttle) or held. |
| `rt_valid` | 1 | The instruction's last execute clock: it commits, or fails its condition, and leaves execute. The same clock as `rt_start` for a one-clock instruction. |
| `rt_pc`, `rt_insn` | 32, 32 | Its address and encoding, with `rt_valid`. |
| `rt_nzcv` | 4 | NZCV after it, with `rt_valid`. |
| `rt_e_we`, `rt_e_idx`, `rt_e_data` | 1, 4, 32 | Port E writes register `rt_e_idx` (r0–r14) on this edge. |
| `rt_w_we`, `rt_w_idx`, `rt_w_data` | 1, 4, 32 | Port W writes register `rt_w_idx` on this edge. |

Rules:

1. Per instruction: `rt_start`, then `rt_valid` (the same clock or later), and only then the next instruction's `rt_start` (a later clock).
2. An E write belongs to the instruction in execute, in a clock from its `rt_start` to its `rt_valid`.
3. A W write belongs to an instruction that started in an earlier clock, and lands no later than the clock in which the next instruction starts. A W write in the same clock as an `rt_start` is therefore always the older instruction's.
4. Only instructions' writes are reported: not the r0–r14 clear after a hold. The shadow starts at zero, as the reference does.
5. r15 is never written through either port. A branch, `BX` or `LDR pc` shows up as the next record's `rt_pc`.

The testbench applies each sample to a shadow register file in this order: the W write; then, on `rt_start`, it closes the previous instruction's record (its PC, encoding and NZCV, with the shadow's r0–r14); then the E write; then, on `rt_valid`, it opens this instruction's record. Load data that arrives with the next instruction's first clock is thus counted with the load, and if E and W write the same register in one clock, E (the younger instruction) wins, as in the register file. The testbench reports breaches of rules 1, 2 and 5.

Examples in the S3 pipeline (`BUPCHIP_CORE.md`, "Pipeline and cycle counts"):

| Clock | Execute | `rt_start` | `rt_valid` | E | W |
|---|---|---|---|---|---|
| 1 | `ldrsb sl,[r5]`, asset miss | 1 | 1 | — | — |
| 2–9 | `mla r7,lr,sl,r9`, frozen | — | — | — | — |
| 10 | `mla` | 1 | 1 | r7 | sl (the `ldrsb`'s) |
| 11 | `ldmia sp,{r4,r5,lr}`, beat 1 | 1 | — | — | — |
| 12 | beat 2 | — | — | — | r4 |
| 13 | beat 3 | — | 1 | — | r5 |
| 14 | the next instruction | 1 | … | … | lr (the LDM's) |

`lockstep_dut_ref.sv` produces the same patterns from the second reference core, and with `+gap=P` makes P% of clocks idle, delivering owed W writes in them or with the next start. That exercises these rules before the new core exists.

### The DUT shell

`lockstep_dut_bup.sv` has the same ports as `lockstep_dut_ref.sv`. Besides the retire port, step 2 connects:

| Ports | Meaning |
|---|---|
| `clk`, `rst` | `clk_arm`; `rst` is high until the reference's CPU is released. |
| `st_valid`, `st_addr`, `st_strb`, `st_data` | A RAM store commits on this edge: word address, byte lanes, data. |
| `pw_valid`, `pw_addr`, `pw_data` | A peripheral write happens on this edge (register offset, data). |
| `pr_valid`, `pr_addr` | A peripheral read completes on this edge, taking `pr_data`. Allowed only in a clock where `pr_avail` is high; until then the core must wait (stop its clock enable, or freeze execute before the read reaches W) and should raise `pr_wait`. |
| `pr_avail`, `pr_data` | Inputs: the head of the replay queue. |
| `halted`, `halt_pc` | The core has halted, and where. |

The shell also holds the core's ROM (`+romhex`, default the `ROMHEX` define), its RAM, and the asset bytes of the `+rom` image (offset 128 + the header's ROM size onwards), and implements `+inject=N`. `lockstep_dut_bup.sv` holds a peripheral read in W with the core's `w_wait` input until `pr_avail` is high, and takes two more plusargs to vary the core's timing: `+await=P` (an asset load waits in W on P% of its clocks) and `+throttle=P` (the core's `freeze` input, the debug throttle, on P% of clocks), with `+seed=S`.

## Results with the new core (DUT=bup)

`../s1/README.md` lists the step 2 results: the ISA suite in lockstep, the mixer harness, the synthetic ARSC checks, Rikki & Vikki through boot and five songs, and the fault injections, all with 0 mismatches against the reference. `directed/` adds more directed tests (shifter carry-out from every bit, register shift amounts, LDM/STM of r0–r14, r15 as an operand, UNPREDICTABLE forms the core runs), running off the end of the ROM, and a random-encoding fuzz; its README has the results and a mutation check.

## Results (2026-10-03, reference against reference)

| Check | Result |
|---|---|
| ISA: `sample.S` + 200 seeds × 300 operations | 201 of 201 agree with Unicorn (353,728 instructions to the end markers); also 201 of 201 in lockstep |
| Mixer harness on the reference | End marker after 1,742,609 instructions, 6,854,841 clocks (3.93 per instruction); 4,800 of 4,800 frames nonzero |
| Mixer harness, lockstep | 1,742,652 retires, 235,742 RAM stores, 4,802 peripheral writes compared; 0 mismatches |
| Synthetic ARSC on `tb_bupchip`, song 0, 1 s | Boots (fault 00), 42,664 of 48,009 frames nonzero, 0 underruns; 17.84 MIPS |
| Fault paths | No ARSC tag: fault 2 after 6,292 instructions; bad CSMP tag: fault 3 after 21,713 |
| Unicorn replay, boot + song 0 | 389,924 instructions and 14,369 peripheral reads; every register and NZCV agree |
| Synthetic ARSC, lockstep, 16 commands of every class, 8 M clocks | 2,135,928 retires, 118,048 stores, 9,002 peripheral writes, 431,370 replayed reads; 0 mismatches |
| Random-content ARSC, seeds 1–4, lockstep | 0 mismatches; seed 4 aborts at a wild RAM address on both cores |
| Rikki & Vikki, boot + Misery_F, lockstep | 1,000,000 retires, 91,683 stores, 6,202 peripheral writes, 99,279 replayed reads; 0 mismatches |
| The same, 4,000,000 retires with `+gap=25 +seed=5` | 445,679 stores, 14,002 peripheral writes, 248,287 replayed reads; 0 mismatches (36 s) |
| The same with `+inject=50000` | Caught at retire 247,167 (`r0 DUT 00000fbe ref 00000fbf`) |
