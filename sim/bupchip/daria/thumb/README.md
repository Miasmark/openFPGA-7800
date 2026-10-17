# DARIA step 2: Thumb in simulation

The checks of `docs/DARIA_CORE.md`, step 2 ("The CPU: Thumb", "Verification"): `src/fpga/core/bupchip/bup_cpu.sv` with `THUMB` 1 against MiSTer's reference ARM7TDMI, and with `THUMB` 0 against ARIA. The reference is used only as a black box through the existing testbenches (`../../verif/`); nothing here is taken from it, or from any other Thumb core. No game data is needed: every program is generated or written here.

## Running

| Script | What it checks | Time (4 cores, `JOBS=2`) |
|---|---|---|
| `run_directed.sh [TEST.S ...]` | `directed/*.S`, one program per format group: on the reference (end marker, no abort or exception), then in lockstep plainly, with `+await=40 +throttle=25` (seeds 11 and 23) and with `LATE_RF=1` | 5 seconds after the builds |
| `run_halts.sh [NAME ...]` | `halt_thumb.py`: 210 cases, every row of the halt table (codes 1, 3–8) at its address and the neighbours that must not halt, on the core alone (`tb_thumb.sv`) plainly, with `LATE_RF=1` and with throttle and asset waits; the reference takes its UND or SWI exception at the same address where it has one, and the no-halt cases also pass lockstep | 2 minutes |
| `run_random.sh [SEEDS]` | `gen_thumb.py`, 300 operations per seed (default seeds 1–400): reference and Unicorn (`thumb_iss.py`) agree on all of RAM and the instruction count, then lockstep plainly, with `+await=20 +throttle=10` and with `LATE_RF=1` | 4 minutes |
| `run_decode.sh` | All 65,536 halfwords through the RTL decoder (`tb_tdec.sv`, the core held in Thumb state with `freeze`), in both halves of `rom_q` and with C known and unknown, against `../thumb_expand.py --table` (`tdec_check.py`) | 10 seconds |
| `run_fuzz.sh [SEED ...]` | `tfuzz.py`: random halfwords from random states (default seeds 1–48, 200 cells each); every halt predicted and checked by code and address, everything else in lockstep. `LATE_RF=1` and `PLUS="+await=20 +throttle=10"` give the other variants | 2 minutes per variant |
| `run_mutants.sh [NAME ...]` | The mutations of `mutants.py` (the design's list, one planted bug each in a copy of the core): each must make one of the suites above fail | about an hour |
| `aria_equiv.sh [REV] [MODES ...]` | Yosys proves the core with `THUMB` 0 sequentially equivalent to its version at REV (default 806dcd4, step 0), for `MODES` 0 and 1, the register file included | 10 minutes per mode |
| `index_depth.sh` | The register-index path's depth in LUT6 levels (`abc -lut 6`), from `rom_q` and the registered state to the two physical read indices, with `THUMB` 0 and 1 | 1 minute |
| `yosys_cells.sh [-r REV \| -f FILE] [PARAM=VALUE ...]` | Yosys cell counts of the core (`synth_intel_alm`) | 2 minutes |

Each takes `WORK` for its work files and builds (defaults under `sim/work/bupchip/daria/`), and `VERILATOR` as `../../verif/build.sh` does. The lockstep runs use `../../verif/run_lockstep.sh` with `DUT=bup THUMB=1`; a mutant core goes in through `BUP_SRCS` (lockstep), `CORE_SV` (`build_tb.sh`) or `BUP_CPU` (`run_decode.sh`). Unicorn comes from `sim/work/bupchip/venv` (`../../setup_dev.sh`).

ARIA's own checks run on the Thumb core too: `THUMB=1 ../../s1/check.sh GAME.a78` builds every testbench there with `THUMB` 1 in the BupChip profile (`arm_only` high).

## Files

| File | What it is |
|---|---|
| `directed/*.S`, `directed/common.inc` | The directed programs (ALU with immediates and registers, branches, hi-register forms, BX, BL, loads and stores, LDM/STM, SP and PC mixes, MUL and the C flag, interworking in SYS and FIQ mode, code that ends at the last halfword of the code space) and their shared start-up and macros |
| `halt_thumb.py`, `tb_thumb.sv`, `build_tb.sh` | The halt cases, and the core alone with ROM, RAM, peripheral and assets (`+arm_only`, `+throttle`, `+await`) |
| `gen_thumb.py`, `thumb_iss.py` | The random-stream generator, and the Unicorn golden run with its lint for anything outside ARMv4T/ARMv5 agreement (`gen_thumb.py --image` makes the image with 4 KiB of assets) |
| `tb_tdec.sv`, `tdec_check.py` | The decode probe and its checker; `../thumb_expand.py` is the table |
| `tfuzz.py`, `tfuzz_run.py` | The fuzz generator, with a prediction per cell, and its runner |
| `mutants.py` | The mutations |

## Notes

- **ARMv4T and ARMv5.** Unicorn is an ARMv5 core, so the random streams stay where the two agree: POP {pc} of odd values only, no BX PC at an address 2 mod 4, aligned word and even halfword accesses, STMIA with the base in the list only as the lowest register, and no C read after a MUL. The directed, halt and fuzz suites cover the ARMv4T-only cases against the reference alone.
- **C after a Thumb MUL** is not compared while the core reports it unknown (`rt_cunk`); the runs print how many records skipped it. The core halts with code 8 on anything that would read it.
- **Two reference behaviours the core does not copy, both as ARIA in ARM state:** LDM/STM/PUSH/POP to the peripheral page or the assets do not abort on the reference, while the core halts with code 7; and `ldr rX, [pc]` at 0x3FFE reads 0x4000, so its DATA halt (5) wins over the FETCH halt of running on.
- **A bench limit:** when the core halts, the last instruction it retired before the halt is not compared (its record closes only at the next start). For a FETCH halt that is the jump itself; such jumps are compared in the main lockstep runs, where they go to valid targets.
- The return sentinel 0xF000_0000 (P2) is step 5's; a jump there halts with code 4 today.

## Results

See `docs/DARIA_CORE.md`, "Step 2 work".
