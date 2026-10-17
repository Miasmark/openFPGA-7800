# 6507 bus timing seen by the 2600 ARM front ends (upstream)

Target: a cycle-exact clone of upstream's DPC+, CDF and BUS front ends, compared
at every 6507 latch edge, per commit and per audio tick.

Sources are the vendored MiSTer RTL under `src/fpga/mister/rtl/` (paths below
are relative to it unless they start with `core/` = `src/fpga/core/`). The
vendored files differ from upstream only behind `ifdef`s (`NO_ARM_MAPPER`,
`NO_DDRAM`, `NO_BUPCHIP`, `POCKET_*`, `EXTERNAL_*`); without those macros
they behave as upstream (`../POCKET_CHANGES.md`, "rtl/top.sv: build
switches"). Everything below is the macro-free (MiSTer) behaviour unless it
says Pocket.

[checker note: every claim below was re-read against the cited RTL. Marks:
`[checked]` = confirmed as written; `[corrected: ...]` = changed or added.
Two sources outside `rtl/` settle the old open questions 1, 2 and 7:
- **PLL** = `src/fpga/mister/rtl/pll/pll_0002.v` (vendored): outclk0
  14.318182 MHz, outclk1 57.272728 MHz, outclk2 7.159091 MHz, outclk3
  71.590910 MHz, all `phase_shift = 0 ps` (`pll_0002.v:39-49`).
- **WR** = upstream's MiSTer wrapper `Atari7800.sv` (module `emu`, MIT
  header, Jamie Blanks), a read-only copy at
  `scratchpad/upstream_wrapper/Atari7800.sv`, which the cdf.md checker
  fetched from MiSTer-unstable-nightlies/Atari7800_MiSTer at `ffc47192`
  (cdf.md:48). It is not in the repo; line numbers refer to that copy.]

## 0. Conventions

- **clk_sys** is the 7800 master clock: 14.318182 MHz NTSC, 14.18758 MHz PAL
  (`arm_mapper_audio.sv:8` default; `core/core_constraints.sdc:5`).
  [corrected: `arm_mapper_audio.sv:8` is only the audio engine's `CLK_RATE`
  constant. The clock itself: PLL outclk0 (`pll_0002.v:39`); upstream retunes
  the PLL's fractional M for PAL and states that clk_vid = 4 x clk_sys and
  clk_arm = 5 x clk_sys hold in both regions (WR:336-370).]
- **E0** is the clk_sys rising edge at which `pclk1` is sampled 1. `pclk1` and
  `pclk0` are one-clk_sys pulses (section 1). **Ek** is the k-th clk_sys edge
  after E0. **pk** is the clk_sys period that **ends** at Ek. So `pclk1` is high
  in p0 (= p12 of the previous cycle), `pclk0` is high in p6, and a register
  that "sees pclk0" acts at E6. A combinational value "in p6" is what every
  register samples at E6.
- One 6507 cycle is E0..E12 (12 clk_sys) in steady state. The next cycle's E0
  is this cycle's E12.
- "Front end" = `mapper_dpcplus`, `mapper_cdf`, `mapper_bus`. "Commit" = the
  E6 at which the front end's `access` is 1.
- 2600 mode = `tia_en`=1, `maria_en`=0 (INPTCTRL after the BIOS, or bypass).

## 1. Where pclk1 / pclk0 come from

**B1. MARIA makes the master enables.** `mclk0`/`mclk1` are registered,
alternate every clk_sys (`Maria/maria.sv:156-160, 197-199`), and
`tia_clk_x2 = tia_clk_en && mclk0` is a one-clk_sys pulse every second
clk_sys (`maria.sv:153-154`). The TIA's `ce` is `tia_clk_x2` (`top.sv:490`).
MARIA's `ce` is `~pause || effective_reset` (`top.sv:445`): pause stops every
phase. [checked: `mclk0`/`mclk1` default to 0 each clk and are set only
under `ce` (`maria.sv:157-160, 166, 197-199`), so `tia_clk_x2` is 0 during
pause. `tia_clk_en` = `~|tia_enable_count` is 1 for good after two `mclk1`s
from power-up (`maria.sv:134, 153, 174-175`).]

**B2. Two dividers, same 6/6 phases.** `top.sv:259-260` selects the TIA's
divider as the phase source when `cpu_driver && !effective_reset &&
ctrl_writes == 2 && tia_en`; otherwise MARIA's.

- TIA divider (`TIA.sv:461-577`): `pclk_edge` = every `ce` (`:498-500`);
  `pclk_div` counts 0..5 on each `ce` (`:556-558`);
  `pclk_gen_edge_p2` = `pclk_div==2 && ce && ~pclk_clock` (`:505`),
  `pclk_gen_edge_p1` = `pclk_div==5 && ce && pclk_clock` (`:506`). So phase 1
  and phase 2 are each 3 `ce` = **6 clk_sys**, cycle 12 clk_sys. Both are
  combinational one-clk_sys pulses. Exported as `phi1_gen`/`phi0_gen`
  (`TIA.sv:2007-2008`) to `pclk1_t`/`pclk0_t` (`top.sv:496-497`).
  Irregular phases only around RSYNC: `hclk.edge_p2 && rsynd` reloads
  `pclk_div <= 2` (`TIA.sv:565-567`), and `resp0 && pclk_div==0` can fire
  phase 1 early (`:506, :528`). Reset sets `pclk_div=4`, `pclk_clock=0`
  (`:569-574`), so the first TIA edge after reset is a phase 2.
  Derived by stepping `:543-575` from reset (not stated in RTL): with the TIA
  source, phase 1 lands on an `oclk.edge_p2` clk (= `cart_ce`,
  `TIA.sv:1814`) and phase 2 on an `oclk.edge_p1` clk. Whether an RSYNC
  reload keeps that polarity depends on when `hclk.edge_p2` fires, which was
  not checked.
  [corrected, and the polarity question settled:
  - **The reload is not RSYNC-only.** `rsynd` is `eer = ehb || rsynl || err`
    registered on `hclk.level_p1` (`TIA.sv:610, 647`), and `ehb` is the
    horizontal LFSR's end-of-line state `010100` (`:626`). So the reload fires
    once per scanline. A line is 228 colour clocks = 456 `ce` = 76 x 6, so once
    the divider is aligned, every line-end reload sees `pclk_div==1` and
    writes the 2 that the counter would reach anyway: a no-op. It changes
    the phase only after something misaligns the line end against the divider:
    an RSYNC write (`rsynl`), or the first line end after the TIA's reset.
  - **Polarity is invariant (proof from the RTL).** `pclk_div` and `oclk_tog`
    both step on every `ce` (`:545-547, 556-558`) and reset to 4 and 0
    together (`:569-574`), and 6 is even, so `pclk_div` is even exactly on the
    `ce`s with `oclk_tog=0` (`oclk.edge_p1`). The reload happens only on an
    `hclk.edge_p2`. hclk's `tick` is `oclk.edge_p2`, a one-clk pulse, so
    `tick_edge = tick` and `hclk.edge_p2` is always an `oclk_tog=1` `ce`
    (`:369-372, 521`). There the pre-reload `pclk_div` is odd, and the reload
    puts 2 (even) on the next, `oclk_tog=0`, `ce`. So parity is kept through
    every reload and through the MARIA->TIA handoff. `pclk_gen_edge_p2` (div 2)
    is always an `oclk.edge_p1` clk, and `pclk_gen_edge_p1` (div 5) is always
    an `oclk.edge_p2` = `cart_ce` clk. With the TIA source, `cart_ce` is high
    in p0, p4 and p8 of every regular cycle. No ARM front end uses `ce`
    (their ports, `mapper_cdf.sv:6-49`, `mapper_dpcplus.sv:6-46`,
    `mapper_bus.sv:6-51`), so the polarity matters only to other mappers.
  - **`resp0 && pclk_div==0` cannot fire with the TIA source.** It needs
    `pclk_clock=1` at div 0. With `is_7800=0`, `pclk_clock` rises only at
    div 2 and is cleared by the div-5 phase 1 that always follows: reloads
    only replace an odd div by 2, never by 0. It can fire only while
    `is_7800=1` (`pclk_clock` follows `pext`, `:508-509`), i.e. as a one-off
    during the post-reset handoff (`top.sv:1291-1296`).
  - **Shape of a misaligned reload** (reload at an `oclk_tog=1` `ce` whose
    pre-reload div is d): d=1 is a no-op; d=3, one `ce` into phase 2, makes
    **phase 2 last 5 `ce` = 10 clk_sys**; d=5, the `ce` that fires phase 1,
    makes **phase 1 last 1 `ce` = 2 clk_sys**. That cycle is 16 or 8 clk_sys
    instead of 12, and the timelines of section 5 stretch or compress with it.
    With a 2-clk phase 1, a ROM byte from a new SDRAM word, which arrives at
    E2+3/4 (B16), arrives after that cycle's latch.]
- MARIA divider (`maria.sv:213-222`): in 2600 mode `sel_slow_clock = 1`
  (`Maria/control.sv:64`), so `clock_div` reloads 2 every time
  (`maria.sv:220`): a phase every 3 `mclk1` = **6 clk_sys**. `pclk1`/`pclk0` are
  registered one-clk_sys pulses (`maria.sv:157-160, 218-219`).

**B3. Pairing.** `cpu_phase_controller` passes the active source's pulses
through combinationally in RUN (`top.sv:1283-1286`), alternating
phase 1 / phase 2 via `last_phase2` (`:1303-1310`). `M6502C` gates them again
with `in_phase2` (`top.sv:1420-1427`) and exports the gated pulses as the
system `pclk1`/`pclk0` (`top.sv:714-717, 1434-1435`). So `pclk1` and `pclk0`
strictly alternate, one clk_sys each, 6 clk_sys apart. Everything on the
2600 bus (CPU, TIA writes, RIOT `ce`=`pclk0` `top.sv:684`, the cart's `phi1`
`top.sv:1133`, `mapper_phi2` `top.sv:327`) uses these same pulses.
[checked. With the TIA source the TIA's own write/strobe timing uses its
internal `pclk` (`is_7800=0`, `TIA.sv:508-512`), which is the same
`pclk_gen_edge_*` pulse that becomes the system pclk0/pclk1 through
`top.sv:1283-1286, 1420-1422`. With the MARIA source the TIA follows `pext` =
the system pclk0/pclk1 (`TIA.sv:508-509, 2001-2002`; `top.sv:498, 526`).]

**B4. Which source.** Pocket hardwires `cpu_driver = 1`
(`core/atari7800_pocket.sv:1033`), so 2600 games run on the TIA divider after
the post-reset hand-off (`top.sv:1230-1345`). The MiSTer wrapper is not
vendored, so its `cpu_driver` default is unknown (open question Q1). The
steady-state phase lengths are 6/6 for both sources (B2).
[corrected: settled from WR. Upstream passes `.cpu_driver (~status[21])`
(WR:623), and the OSD entry is `"D2P3OL,CPU Driver,TIA,Maria;"` (WR:155):
option bit 21 ("L"), value 0 = TIA. So by default MiSTer also runs 2600
games on the TIA divider, as the Pocket does. MARIA is selected only if the
user picks it in the OSD.]

**B5. Pause.** No `pclk*` during pause (B1). `cart_read` becomes
`~|pause_clock` (`top.sv:331`), cart RAM port A is disabled and reads `$FF`
(`top.sv:921, 936`), and the ARM stops (`top.sv:816`). `open_bus`,
`pause_clock` and `last_address` still update every clk_sys
(`top.sv:348-352`). The front ends' clocked logic and `arm_mapper_audio` are
not gated by pause (they run on clk_sys with no enable: `mapper_bus.sv:174`,
`arm_mapper_audio.sv:160`).
[corrected: "port A is disabled" is too strong. `mapper_en = !pause` gates
only port A's write enable and the byte-lane register (`cart_ram_tdp.sv:61-64,
75`). The lane RAMs still register `cartram_addr` at every edge
(`cart_ram_tdp.sv:74`, no clock enable). Only the **byte** output is forced to
`$FF` (`top.sv:936`). The **word** output (`cartram_word_data_tdp`,
`top.sv:934, 1158`) is not forced. So during pause the audio engine keeps
ticking (`tick_accum`, `arm_mapper_audio.sv:191-199`, not gated), reads real
waveform-pointer and size words, and reads every sample byte as `$FF`
(`arm_mapper_audio.sv:317-327` use `ram_byte_data` = `cartram_data` =
`cartram_data_bram`, `cart2600.sv:793`). A per-tick audio comparison across a
pause sees that. The ARM memory system's timer is gated by `mem_ce = ~pause`
(`arm_mapper_memory.sv:732-736`; `top.sv:1187`). On MiSTer, `pause` is the
OSD pause `core_paused_eff` (WR:529).]

## 2. The 6507 core's latch points

The core is `M6502C` -> `sally` -> `mos6502` (`top.sv:712-732, 1395-1469`;
`6502/sally.sv:213-236`). In 2600 mode SALLY's halt never engages
(`cpu_halt_n` follows MARIA's `halt_n` only after `ctrl_writes==2`,
`top.sv:330`, and MARIA does no DMA with `maria_en`=0), so `phi1_en`/`phi2_en`
reach the core ungated (`sally.sv:196-198`).

| Edge | What the core does | Source |
|---|---|---|
| **E0** (`phi1_en`) | `ABL`/`ABH` load: the address for this cycle is on `AB` from p1. | `6502/mos6502_dp.sv:202, 225-226`; `top.sv:368-373` |
| E0 | `DOR <= DB`: write data on `DB_OUT`/`write_DB` from p1. [corrected: `dor <= db` is the core's *internal* data bus, loaded at **every** E0, read or write (`mos6502_dp.sv:228`). So `write_DB` changes at every E0, and is the store byte from p1 to p12 of a write cycle.] | `mos6502_dp.sv:228, 320`; `top.sv:722` |
| E0 | `wr_pin`, `sync_pin` load: R/W and SYNC for this cycle from p1. | `6502/mos6502.sv:129-138`; `top.sv:377` |
| E0 | RDY is read once: `rdy_cy = phi1_en ? rdy : rdy_q`, `rdy_q <= rdy`. | `6502/mos6502_ctl.sv:874-881` |
| E0 | Phase-1 register loads (A/X/Y/S, flags, AI/BI) using the control word `c`. | `mos6502_dp.sv:201-260` |
| **E6** (`phi2_en`) | **`DL <= data_in`** (= `read_DB` on a read). This is the read latch. [checked: `data_in = RD ? DB_IN : DB_OUT` (`top.sv:1450`), where `RD` is the CPU's own `rw_n`, so on a write DL takes the CPU's own `DOR`.] | `mos6502_dp.sv:299`; `top.sv:1450` |
| E6 | `IR <= data_in` on an opcode fetch (`t==1`), only if not held. [checked; with `int_active` IR takes `$00` instead (`mos6502_ctl.sv:1429`), normally unreachable in 2600 mode: `NMI_n = NMI_ung_n || ~maria_en` = 1 (`maria.sv:141`), and `IRQ_n` is the 7800 cart's POKEY IRQ, 1 unless the OSD `pokey_irq` option is on (`cart.sv:318`; `top.sv:1062`).] | `mos6502_ctl.sv:1418-1430` |
| E6 | `t`, `c_reg` advance (or freeze if held); `PCL/PCH` load; `wr_q <= c.wr`. | `mos6502_ctl.sv:1387-1420`; `mos6502_dp.sv:307-308` |
| E6 | `phase2 <= 1`, so `data_oe = wr_pin & phase2` drives the bus p7..p12 of a write. | `mos6502.sv:111-118, 142` |
| E12 | Next cycle's E0. | |

**B6. Data must be valid in p6** (sampled at E6). The address is valid from
p1 to p12; the next address appears in p13 (= p1 of the next cycle). A read
has p1..p6 (6 clk_sys) from address to latch. [checked for regular 6/6
cycles. In a cycle shortened by a misaligned TIA reload (B2) phase 1 is
2 clk_sys, so the read has p1..p2 only.]

**B7. RDY rule (the "hold").** `hold = ~rdy_cy & ~wr_q`
(`mos6502_ctl.sv:874-876`). `rdy_cy` is RDY as it stood in p0 (read at E0), and
`wr_q` is the *previous* cycle's write term until this cycle's E6
(`:1394`). So:

- a cycle is held iff RDY was 0 in its p0 **and** the cycle before it was not
  a write. The cycle right after a write is never held (`:858-866`).
- A held cycle applies `hold_mask(c_reg)`: `adl_abl=0`, PC increment off, no
  write, `adh_abh` only on the carry path (`:936-958`). In practice the address
  register keeps the previous cycle's address: **a held cycle re-presents the
  last address, RW=1**.
- During a held cycle `t` and `c_reg` freeze at E6 (`:1398-1417`), but
  **`DL` is re-latched at every held E6** (`mos6502_dp.sv:299`, unconditional).
  IR is not reloaded (`:1428` is in the `!hold` branch).
- On release (first E0 with RDY=1), the frozen control word is applied
  unmasked: the address of the *next* bus cycle loads at that E0, and the last
  `DL` latched (the last held E6) is the value the core goes on with.
- SYNC is held through a stall (`mos6502_ctl.sv:155-162, 1395`).
- [checked: `rdy_cy = phi1_en ? rdy : rdy_q` (`mos6502_ctl.sv:875`), so the
  E0 decision uses RDY as it stands in p0, combinationally, and the E6
  decision uses the copy `rdy_q` taken at that E0 (`:879-880`). `wr_q <= c.wr`
  at every E6 (`:1394`) is this cycle's write term, used from the next cycle
  on.]
- [corrected/added: **a held cycle can be one whose control word is a write.**
  `hold` does not test this cycle's own `c.wr`, only the previous cycle's
  `wr_q`. If RDY is 0 in p0 of a cycle whose control word is a write (say the
  write of `STA abs`) and the cycle before it was a read, `hold`=1 at that E0:
  `hold_mask` clears `wr` and `adl_abl` (`:936-955`), `wr_pin <= c.wr` = 0
  (`mos6502.sv:131-132`). The bus then shows the previous read's address with
  RW=1, repeated until release, and the store happens after the release. This
  matters only for a delayed launch (B28, 8.3). With an immediate launch the
  first held cycle always follows W+1's opcode fetch.]

## 3. The system bus in 2600 mode

**B8. Selects.** With `maria_en`=0: `cs_tia` = A12=0 & A7=0, `cs_riot` = A12=0
& A7=1 (`Maria/control.sv:97-102`); RAM0/1 and MARIA are never selected.
`cs_cart = ~|{cs_ram0, cs_ram1, cs_tia, cs_riot, cs_maria}` (`top.sv:354`), so
**the cart is selected iff A12=1**. `bios_sel = ~bios_en_b && AB[15]`
(`top.sv:355`) is 0 in 2600 mode (`bios_en_b`=1). [checked:
`Maria/control.sv:97-100`.]

**B9. Read resolution** (`top.sv:364-395`, all combinational):
`read_DB = open_bus` by default; only when `RW`=1 does a selected chip drive,
and only on its `oe` lines: cart =
`(cart_DB_out & cart_DB_oe) | (open_bus & ~cart_DB_oe)` when
`cs_cart && (cart_present || bios_sel)` (`:391-393`); TIA and RIOT likewise
with their masks (`:383-384`). In 2600 mode `cart_DB_out`/`cart_DB_oe` are
cart2600's `d_out`/`oe` (`top.sv:333-334, 1124, 1216`). [checked]

**B10. The resolved bus.** `DB = cpu_DB_oe ? physical_write_DB : read_DB`
(`top.sv:346`), with `physical_write_DB = (tia_en && bus_stuff_valid) ?
write_DB & bus_stuff_data : write_DB` (`top.sv:213-214`). `cpu_DB_oe` is high
only p7..p12 of a write (`mos6502.sv:142`). In p1..p6 of a write nothing
drives (`RW`=0 skips every chip, `top.sv:380`), so `DB = open_bus`.
[checked: `phase2` is set at E6 and cleared at E12 (`mos6502.sv:111-115`);
`data_oe = wr_pin & phase2` (`:142`); SALLY masks it only for a halt
(`sally.sv:193`), which never engages in 2600 mode.]

**B11. `open_bus <= DB` at every clk_sys edge**, unconditionally
(`top.sv:348-352`). Undriven lines therefore keep the last driven value, with
one clk_sys of lag. The value carried into a cycle is `DB` in p12 of the
previous cycle (registered at E12 = next E0). Consequences:
- After a cart read the carried value is the cart's output in p12, i.e.
  **after** the E6 commit (section 5.4), not necessarily the byte the CPU
  latched.
- After a write it is the CPU's byte (`physical_write_DB` in p12; stuffing is
  over by then, section 5.3).
- During a stall it is the held read's byte (section 6).
[checked. Added: the TIA drives only D7 or D7:D6 (`TIA.sv:1944-1964`), so a
TIA read leaves the other bits as `open_bus`. The RIOT drives all eight
lines but only in p6 (`drive = ... && ce`, `RIOT/M6532.sv:134-135`), so
`read_DB` is `open_bus` in p1..p5 and p7..p12 of a RIOT read, and the RIOT
byte reaches `open_bus` at E6.]

**B12. What the cart slot sees.** `a_in = {AB[12] & bios_en_b, AB[11:0]}`
(`top.sv:1128`); `rw = RW` (`:1129`); `d_in = cart_din = RW ? read_DB :
write_DB` (`top.sv:1112`), so on a write the cart sees `DOR` from p1 (not just
phase 2) and never the stuffed byte; `phi1 = pclk1` (`:1133`);
`phi2 = mapper_phi2` (`:1135`, section 6); `arm_driver_run = lock_ctrl &&
tia_en` (`:1136`); `reset = effective_reset` (`:1130`). [checked. Added:
`a_in` is 13 bits, so two consecutive cycles whose 16-bit addresses differ
only in A15:A13 (e.g. `$F0xx` and its `$10xx` mirror) present the same
`a_in` to every 2600 front end.]

## 4. The cart2600 path

**B13. `access`.** `arm_access = phi2 && arm_driver_run` (`cart2600.sv:247`)
feeds every front end's `access` (`:806, 844, 903`). It is high in p6 only,
and only on cycles where `mapper_phi2` shows the phi2. Every front-end
register written from the 6507 bus is gated by it (`mapper_cdf.sv:182`,
`mapper_dpcplus.sv:227`, `mapper_bus.sv:225`), except BUS's stuffing FSM and
`last_a`/`last_rw`, which run every clk_sys (`mapper_bus.sv:175-176,
203-223`); the request-pending flags clear on their own handshakes
(`mapper_cdf.sv:179-180`, `mapper_dpcplus.sv:222-225`, `mapper_bus.sv:200-201`). With `arm_driver_run`=0 (the
Harmony boot stub: before the BIOS locks 2600 mode) the combinational reads
still answer but no state moves. [checked. Two exceptions to "no state
moves" with `arm_driver_run`=0: DPC+ `DFxPUSH`/`DFxWRITE` still strobe cart
RAM (5.3), because `cartram_wr` does not use `access`; and `access_taken` is
set by `phi2`, not by `access` (`cart2600.sv:255-261`), so the strobe still
closes at E6.]

**B14. `address_change`** `= old_ain != a_in`, `old_ain <= a_in` every clk_sys
(`cart2600.sv:241, 263-265`). It is 1 in p1 of a cycle whose address differs
from the previous cycle's, else 0. Consecutive cycles at one address (stall
repeats, RMW read/dummy-write/write, `STA abs,X` dummy read + write) give no
`address_change`. [checked; the compare is on the 13-bit `a_in` (B12) and
ignores RW. BUS's own `bus_change` also compares RW (`mapper_bus.sv:94`).]

**B15. ROM request.** For every ARM front end `rom_read = ~address_change`
(`cart2600.sv:157`, AR excepted), and `cart_read = read_2600`
(`top.sv:331`, not paused). So the request line drops in p1 and rises at E1;
the slot's ROM address is `cart_2600_addr_out = {6'b0, rom_a}`
(`top.sv:1108, 1149`; `cart2600.sv:195-197`, unmasked for DPC+/CDF/BUS), with
`rom_a` combinational from `a_in` and the bank register
(`mapper_cdf.sv:130-131`, `mapper_dpcplus.sv:127-128`, `mapper_bus.sv:140-141`).
A bank change at E6 does not re-request; the new bank is read at the next
address change. [checked. Added: `rom_read` ignores A12 and RW, so **every**
cycle with a new `a_in` issues an SDRAM read, including writes and
TIA/RIOT cycles (A12=0), at `rom_a` = bank base + `a_in[11:0]`. The
"previous request's byte" that B16 and 5.2 call stale is therefore the
ROM byte at the previous new-address cycle's `rom_a`. After a zero-page or
TIA access that is a ROM byte from the current bank at that low offset.]

**B16. ROM data timing (Pocket, `sdram.sv` on clk_sdram = 4 x clk_sys,
edge-aligned, `core/atari7800_pocket.sv:10-11`)** (instance
`core/atari7800_pocket.sv:380-403`, `cart_out` mux `:949`):
the controller takes a rising `rd` in IDLE (`sdram.sv:86-104`). The clk_sdram
edge coincident with E1 still sees `rd`=0, so the request is taken at
E1+1/4. State 1..6 follow (`:63-68, 112-115`), READ issues at E2, and
`last_data` is captured at **E2+3/4** (`:184-188`); `ch0_dout` is a
combinational byte select of `last_data` by the registered `a[0]` (`:193`).
If the new address is in the same 16-bit word as the last read, no read is
issued (`ram_req=0`, `:101`) and only the byte select changes at E1+1/4.
Until the new byte arrives, `rom_do` still shows the **previous address's
byte**. The SDC makes sdram -> clk_sys a 2-cycle path
(`core/core_constraints.sdc:24-28`, "as in the MiSTer core's
Atari7800.sdc"): only captures at **E4 or later** are timed for a byte
launched at E2+3/4.
**MiSTer:** same `sdram.sv`, but its clock and channel wiring are in the
unvendored `Atari7800.sv` (`../POCKET_CHANGES.md:17-18`), so the arrival edge
is not established here (Q2). The core-level contract is the same:
request edge E1, byte consumed by E6.
[corrected: settled. Upstream clocks `sdram` from `clk_vid` (WR:787-792), PLL
outclk1 = 57.272728 MHz = 4 x clk_sys at 0 ps (`pll_0002.v:42-43`, wired
WR:42-50), with `ch0_rd = cart_read & ~cart_download & ~reset` and
`ch0_addr = cart_addr` (WR:796-799), and `cart_out = cart_loaded ?
cart_data_sd : ...` (WR:568). So **MiSTer's ROM byte timing is identical to
the Pocket's**: request taken at E1+1/4, READ at E2, `last_data` at E2+3/4.
Exact clk_sys view, as every clk_sys register sees `rom_do` for a cycle whose
`a_in` differs from the previous cycle's (state checked against
`sdram.sv:63-68, 86-116, 184-193`; the same table is in cdf.md section 12.3):
- **E1** samples the previous request's byte.
- **E2** samples the correct byte if the new `rom_a` is in the same 16-bit
  word as the last word read (`ram_req=0`, `sdram.sv:101`: only `a[0]`
  changes, at E1+1/4). Otherwise it samples `last_word[new a[0]]`, the
  **previous word at the new byte lane**: a byte of the old word that may be
  neither the old nor the new address's byte.
- **E3 onward** sample the correct byte.
- If `a_in` did not change, there is no request and `rom_do` keeps the last
  request's byte, even across a bank switch.
The controller has no refresh timer: `AUTO_REFRESH` replaces a same-word read
(`sdram.sv:164`), and nothing else uses channel 0 outside a download, so this
sequence is deterministic in simulation. On silicon the SDC makes
`sdram|*` -> clk_sys a 2-cycle setup path. The Pocket's
`core/core_constraints.sdc:24-28` says MiSTer's `Atari7800.sdc` does the
same, but that file is not in the repo. So only E3 (for `a`, launched E1+1/4)
and E4 (for `last_data`, launched E2+3/4) are *timed* captures; the E2/E3
samples above are what RTL simulation gives.]

**B17. d_out/oe are combinational** (`cart2600.sv:211-234`): for the ARM
front ends `oe = a_in[12] ? $FF : $00` (`mapper_cdf.sv:132`,
`mapper_dpcplus.sv:129`, `mapper_bus.sv:142`); `flags_out[0]` selects the front
end's `d_out` (register/stream/RAM byte), else the ROM byte `rom_do`; a RAM
*write* port (`ram_sel && !ram_rw`) drives nothing (`oe=0`). The whole path
`rom_do`/`cartram_data` -> front end -> `d_out` -> `read_DB` -> `DL` has no
register; the registers in it are the table RAMs and cart RAM port A
(B19, B20). [checked (`cart2600.sv:211-234`). Added: for the ARM front ends
the `sel_ram_sel && !flags_out[0]` branch is reached only on **write** cycles
(DPC+ PUSH/WRITE, BUS stream write, CDF DSWRITE): BUS stream writes have
`ram_rw = !access`, so `d_out = cr_do`, `oe=$FF` in p1..p5 and p7..p12 and
`oe=0` in p6. `read_DB` ignores the cart when RW=0 (`top.sv:380`), so none of
this reaches the bus.]

**B18. Cart RAM strobes** (`cart2600.sv:965-978`):
- `cartram_addr = init_ram_en ? init : (sel_ram_sel ? sel_ram_a :
  audio_ram_addr)` (`:966-967`).
- `cartram_wr = !init_ram_en && sel_ram_sel && ~sel_ram_rw && ~phi1 &&
  ~address_change && ~access_taken` (`:973-974`).
- `cartram_rd = init_ram_en || audio_ram_grant || (sel_ram_sel &&
  sel_ram_rw && ~phi1 && ~address_change)` (`:975-976`).
- `audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel` (`:965`):
  the 6507-side selection always wins the port over audio.
- `cartram_wrdata = d_in` (`:977`), i.e. `write_DB`.
- `access_taken` is cleared by `reset || address_change || phi1` and set by
  `phi2` (= `mapper_phi2`) (`:255-261`): 0 from E0 (or E1) to E6, 1 after a
  shown phi2. [checked. Exactly: 0 in p1..p6. After a shown phi2 it is 1 in
  p7..p12 and is cleared at E12 by `pclk1` (p12 = next p0). After a hidden
  phi2 it is 0 in p1..p12. The clear has priority over the set.]
- In 2600 mode these are the `cartram_*26` set (`top.sv:752-759`). While
  `tia_en`=0 (reset, BIOS in 7800 mode) the port belongs to the 7800 path.
  [checked. `mapper_init_busy` also selects the `*26` set whatever `tia_en`
  is (`top.sv:752-759`). Added: `audio_ram_grant` is computed in cart2600
  regardless of `tia_en`, so if the audio engine issues a read while
  `tia_en`=0 and init is idle (the BIOS phase without `bypass_bios`), port A
  registers the 7800 path's address and the audio engine captures that
  word/byte. With upstream's default `bypass_bios` (`~status[17]`, WR:554)
  `tia_en` rises on the first clk after reset (section 7).]

**B19. Cart RAM port A timing (MiSTer, `cart_ram_tdp`).**
`mapper_en = mapper_init_busy ? (cartram_wr || cartram_rd) : !pause`
(`top.sv:921`), so outside init **port A reads every clk_sys** at whatever
`cartram_addr` is, and `cartram_rd` is ignored. [corrected: port A reads
every clk_sys **always**, in init and in pause too: the lane RAMs' address
register has no enable (`cart_ram_tdp.sv:74`; altsyncram without `clocken`,
`cache_ram.v:118-155`). `mapper_en` gates only `wren_a` (`:75`) and the
byte-lane register `mapper_read_lane` (`:61-64`). `cartram_rd` matters only
as a term of `mapper_en` during init, and to the Pocket SRAM (B21).] The lane RAMs register the
address at every edge and have unregistered outputs
(`cart_ram_tdp.sv:66-85`; `cache_ram.v:118-155`: `outdata_reg_a
"UNREGISTERED"`, no clock enable); `mapper_read_lane` is registered when
`mapper_en` (`cart_ram_tdp.sv:57, 61-64`). **Read latency: address in pk -> data in
p(k+1).** Writes: `wren_a = mapper_en && mapper_write && lane match`, one per
edge where `cartram_wr` is high; read-during-write on port A returns new data
(`cache_ram.v:135, 172-176`). Byte out = `cartram_data_bram = pause ? $FF :
mapper_rdata` (`top.sv:936`); word out (`mapper_word_rdata`, all four lanes)
goes to init and audio (`top.sv:934, 1158`).

**B20. Table RAMs** (`arm_mapper_tables.sv`): pointer and increment tables
are clk_sys port-A M10Ks with registered address
(`cache_ram_tdp_dc_be`, `:157-185`). Port A address = `sys_*_write ?
write index : lookup index` (`:151-155`): **lookup index in pk -> value in
p(k+1)**. Sys writes come from init and from the front ends' registered
`pointer_update`/`map_update` pulses (in p7, written at E7)
(`cart2600.sv:687-699`). Port B mirrors the ARM's own cart RAM writes that
fall in the pointer/increment/map windows, on accepted (non-shared) clk_arm
edges only (`arm_mapper_tables.sv:139-150`).
[checked. Added:
- **Read-during-write (old open question Q6, settled).** Both table RAMs'
  port A is `read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ"`
  (`cache_ram.v:232`), and the sys port always writes with `byteena_a = 4'hF`
  (`arm_mapper_tables.sv:161, 176`), so "no NBE read" never applies: the
  edge that writes a word returns **that new word** in the next clk (sim
  model `cache_ram.v:269-276`, `q_a_out <= wren ? wdata : mem`). A
  `pointer_update` in p7 therefore gives `pointer` = the updated value of
  the *written* index in p8. In p8 the address is the lookup index again, so
  from p9 `pointer` is the lookup index's word. For a stream access the two
  indices are the same, so `pointer` is the new value from p8.
- A BUS `map_update` writes the **increment** RAM at index `16 + map_index`
  (`arm_mapper_tables.sv:153-155, 175-177`). For that one clk (p7) it takes
  the increment RAM's port-A address away from `increment_lookup_index`, so
  `increment` in p8 is the map word just written.
- The snoop sees `arm_cartram_*`, i.e. the ARM CPU *and* the memory system's
  DMA engine (`cart2600.sv:701-705`; `arm_mapper_memory.sv:637-643`), but not
  the table writeback (`mapper_wb_*`).]

**B21. Cart RAM on Pocket (`EXTERNAL_CARTRAM`).** `cartram_data` is
`sram_c_rdata` from `core/sram_ctrl.sv` (`top.sv:937-941`;
`core/atari7800_pocket.sv:960-966, 1076-1095`). In 2600 mode a request is a
rising `c_rd`/`c_wr` or any change of `{c_wr, c_bios, c_addr}`
(`sram_ctrl.sv:216-226`, header `:32-34`); an access is 5 clk_sdram and the
byte is registered one clk_sdram later (`:13-17, 176-206`), with a
2-cycle SDC path (`core/core_constraints.sdc:39-44`). The current Pocket build
has no ARM front ends (`NO_ARM_MAPPER`: DPC+/CDF/BUS get the bad-game screen,
`cart2600.sv:585-650`; `arm_call_busy`=`arm_dma_busy`=0, `:530-570`), so
`arm_call_stall` is always 0 there and `mapper_phi2 = pclk0`.

## 5. Per-cycle timelines (no stall)

### 5.1 Read cycle, plain ROM byte

| Period / edge | Event | Source |
|---|---|---|
| p0 | `pclk1`=1; `cartram_wr`/`rd` forced 0 (`~phi1`). | B3; `cart2600.sv:974-976` |
| E0 | Address, RW=1, SYNC load. `access_taken <= 0`. TIA `pclk_clock <= 0`. RDY read. | §2; `cart2600.sv:257`; `TIA.sv:560-563` |
| p1 | `a_in` new; `address_change`=1 (if new address); `rom_read`=0; BUS `bus_change`=1. Front-end combinational outputs see the new `a_in` with `rom_do` still the previous address's byte. | B14, B15; `mapper_bus.sv:94` |
| E1 | `old_ain <= a_in`; BUS `last_a/last_rw` load. ROM request edge. | `cart2600.sv:264`; `mapper_bus.sv:175-176` |
| p2..p6 | ROM byte arrives (Pocket: after E2+3/4); front end resolves. [corrected: both platforms (B16). Same 16-bit word as the last request: correct byte from E1+1/4, first sampled at E2. New word: the old word's byte at the new lane shows from E1+1/4 to E2+3/4, so E2 samples it; the correct byte is first sampled at E3.] | B16 |
| p6 | `read_DB` final; `pclk0`=1; `mapper_phi2`/`access`=1. | B9; `top.sv:327`; `cart2600.sv:247` |
| **E6** | **CPU latches `DL`** (and IR on a fetch). Front-end commit. `access_taken <= 1`. RIOT `ce`. | §2; `cart2600.sv:259-260`; `top.sv:684` |
| p7..p12 | `d_out` may change from the commit (5.4); `open_bus` follows. | B11 |
| E12 | Next cycle's E0. | |

### 5.2 Front-end reads that substitute data

All are combinational from `a_in`, `rw`, `rom_data` (= `rom_do`) and state,
with the registered RAM stages of B19/B20 in the path. The latest edge at
which each input must be stable for the right byte in p6:

- **CDF fast fetch** (`LDA #` / `LDX #` / `LDY #` operand at
  `fast_expected_address`): `fetch_substitute` needs `fast_pending`, the
  address match and `operand_in_range(rom_data)` (`mapper_cdf.sv:94-98,
  104-105`); `table_index = rom_data - offset` (`:118-119`) -> pointer RAM
  registers it -> `display_address` (`:126-128`) -> `ram_addr` (`:137`) ->
  `cartram_addr` -> port A registers it -> `d_out = ram_rdata` (`:146`).
  Two registered stages after `rom_data`: **the operand byte must be stable in
  p4** (index registered at E4, RAM address at E5, data in p6). That matches
  the SDC's "E4 or later" (B16). The amplitude stream returns the `amplitude`
  register with no RAM stage (`:111-112, 142-143`). [checked. In RTL
  simulation the byte is sampled from E2 (same word) or E3 (new word), so
  the RAM byte is valid from p4 or p5.]
- **CDF fast jump** (`JMP` operands after a marked `$4C`): `jump_substitute`
  needs `rom_data` = 0 (or 0/1 for J) (`:99-103`), index `jump_stream`
  (+`rom_data[0]`) (`:115-117`); same two stages. `fast_jump_valid` is a
  registered-address 1-bit RAM looked up with `rom_a` (`cdf_fastjump_table.sv`,
  `cart2600.sv:883-894`).
- **DPC+ register reads** `$1000-$1027` (address only, from p1) and the DPC+
  fast fetch (`fast_fetch && fast_pending && rom_data < $28`, no address
  compare) (`mapper_dpcplus.sv:112-115`). Function 1-3 reads select RAM at
  `$0C00 + counter` (or `fractional[19:8]`) (`:123-124, 137-143`): one
  registered stage, so `rom_data` must be stable in p5 for the fast fetch.
  `d_out` per `:160-180` (random, amplitude, RAM, RAM & window flag, flag).
- **BUS stream read** (`$1000-$100F` BUS1/2, `$1FEF` BUS3) is address-only
  (`mapper_bus.sv:96-98`): pointer lookup index registered at E1, RAM address
  at E2, data from p3. BUS3 fast jump needs `rom_data`=0 (`:115-116`).
  Amplitude at `$1018`/`$1FEE` (`:99-101, 156-158`).

`sel_ram_sel` is high for as long as the decode holds: address-only selects
(DPC+ `$1000-$1027`, BUS streams) from p1 to p12; `rom_data`-gated selects
(CDF fetch/jump, DPC+ fast fetch) from the ROM byte's arrival to E6, because
the commit clears `fast_pending`/`jump_remaining` (`mapper_cdf.sv:195-209`,
`mapper_dpcplus.sv:235-236`). While it is high the audio engine cannot get
port A (B18), so **the audio engine's port-A schedule depends on these
waveforms clk_sys by clk_sys**, including when `rom_do` arrives (Q3).
[corrected: the exact `sel_ram_sel` window per access kind
(`cart2600.sv:896-898, 941-943` for CDF/BUS `ram_sel = *_ram_en`; DPC+ drives
`ram_sel` itself):
- DPC+ read `$1008-$101F` (functions 1-3 only; functions 0 and 4, i.e.
  `$1000-$1007` and `$1020-$1027`, select no RAM, `mapper_dpcplus.sv:123-124`):
  p1..p12.
- DPC+ `DFxPUSH`/`DFxWRITE` (a write): p1..p12 (`:144-158`).
- BUS stream read `$1000-$100F`/`$1FEF`: p1..p12. BUS stream **write**
  `$1010-$1013`/`$1FF0`: also p1..p12, because `ram_en=1` for the whole cycle
  and only `ram_write` waits for `access` (`mapper_bus.sv:161-163`).
- BUS stuffing: p4..p6 (states DATA and READY, `mapper_bus.sv:164-166`).
- CDF `DSWRITE` `$1FF0`: p6 only (`mapper_cdf.sv:150-156`).
- CDF/BUS3 amplitude reads: never (`amplitude_fetch` drops `ram_en`,
  `mapper_cdf.sv:142-147`; `mapper_bus.sv:156-158`).
- `rom_data`-gated (CDF fetch, CDF jump, BUS3 jump, DPC+ fast fetch): high in
  every clk from p1 to p6 in which the predicate holds **on the `rom_do` then
  visible**, not only from the true byte's arrival. Before arrival `rom_do`
  is the previous request's byte (sampled at E1), then, in the new-word case,
  the old word's byte at the new lane (sampled at E2, B16). Cases that are true on a stale
  byte in normal code:
  - **the second JMP operand (CDF and BUS3)**: `jump_remaining==1` needs
    `rom_data==0` (`mapper_cdf.sv:101`, `mapper_bus.sv:116`), and the stale
    byte is the first operand, which is `$00` for a stream-0 jump. So the
    select is high in p1 (sampled at E1), whatever the high operand turns
    out to be. For `JMP` at address A: if A is odd, the high operand A+2 is
    in A+1's word, so E2 onward see the real byte. If A is even, A+2 starts a
    new word, E2 sees lane 0 of the old word, which is the `$4C` at A (select
    low), and E3 onward see the real byte.
  - In general, in the new-word case and when the previous request was the
    address just before, E2 sees the byte two addresses back, which can
    satisfy `operand_in_range` or `rom_data==0` for that one clk.
  - The CDF fast-fetch operand's stale byte is the `LDA/LDX/LDY #` opcode
    (`$A9/$A2/$A0`). That is out of range unless `fetch_offset_enable` puts
    the window over it (`mapper_cdf.sv:94-96`). The DPC+ fast fetch's stale
    byte is `$A9` (>= `$28`), so it never fires early.
  The same stale windows also drive `table_index` (CDF), and so the
  pointer-table read address.]

### 5.3 Write cycle

| Period / edge | Event | Source |
|---|---|---|
| E0 | Address, RW=0, `DOR` load: `write_DB` valid p1..p12. | §2 |
| p1..p6 | Nothing drives `DB` (`= open_bus`); cart `d_in = write_DB`. | B10, B12 |
| **E6** | Front-end commit with `d_in`. RIOT latches `physical_write_DB` (in p6). TIA's first write edge. | `top.sv:684, 696`; `TIA.sv:1899-1901` |
| p7..p12 | CPU drives `DB = physical_write_DB`; `open_bus` takes it from E7. TIA rewrites `wreg` at every edge E7..E12 while `pclk.level_p2` (`TIA.sv:1899`), so the TIA keeps the value in p12. | B10; `TIA.sv:510-512, 560-563` |

**Cart RAM writes by the 6507** (6507-originated, port A):

- **CDF `DSWRITE` `$1FF0`**: `ram_en`/`ram_write` only while `access`
  (`mapper_cdf.sv:150-156`), so `cartram_wr` is high in p6 only: one write
  at **E6** to `2048 + pointer[32]` high bits. `pointer_update` (index 32)
  registered at E6, table and writeback from E7 (`:227-233`).
- **BUS stream write** (`$1010-$1013` BUS1/2, `$1FF0` BUS3): `ram_en` for the
  whole cycle, `ram_write = access` (`mapper_bus.sv:102-104, 161-163`): one
  write at **E6**. `pointer_update` at E6 (`:264-267`).
- **DPC+ `DFxPUSH` `$1060-$1067` / `DFxWRITE` `$1078-$107F`**: `ram_sel`,
  `ram_rw=0` from `!rw && a_in[12] && range`, **not gated by `access`**
  (`mapper_dpcplus.sv:144-158`). `cartram_wr` is therefore high in p2..p6
  (0 in p1 from `address_change`, 0 after E6 from `access_taken`): **five
  identical writes at E2, E3, E4, E5, E6** to `$0C00 + counter` (PUSH:
  `counter-1`), data `write_DB`. The counter moves at the E6 commit
  (`:302, :319`), after which the strobe is off. If the phi2 is hidden
  (section 6), `access_taken` never sets and the strobe stays on p2..p11
  (10 writes, counter unchanged). The strobe is not gated by
  `arm_driver_run` either.
  [corrected: "0 in p1 from `address_change`" holds only if the address
  changed at E0. A store that repeats the previous cycle's address, i.e. the
  write of `STA abs,X`/`abs,Y`/`(zp),Y` (dummy read first), or either write of
  a RMW on `$1060-$107F`, has `address_change`=0 in p1, and `access_taken`
  was cleared at E0 by `pclk1`. So the strobe is high p1..p6: **six writes,
  E1..E6** (eleven, E1..E11, if the phi2 is hidden). For a RMW the second
  write (W2) uses the counter moved at E6 of W1, and its p1 write lands at
  E13 at the new address.]

**BUS stuffing** (read from cart RAM during a 6507 write below `$1000`):
`stuff_candidate = !rw && !a_in[12] && stuff_target_valid && a_in ==
target && a_in[6:0] <= $24` (`mapper_bus.sv:113-114`). The FSM runs every
clk_sys, ungated by `access` (`:203-223`): IDLE->MAP at E1 (needs
`bus_change` in p1), MAP->STREAM at E2 (`stuff_map <= table_increment`),
STREAM->DATA at E3, DATA->READY at E4. `ram_en` in DATA/READY (`:164-166`)
puts `display_address` on port A in p4 (registered E4), so
`stuff_data = ram_rdata` is valid p5..p6 and `stuff_valid` is high **p5..p6
only** (`:149-150`); the E6 commit clears `stuff_target_valid` and returns
to IDLE (`:286-294`). So `physical_write_DB` is stuffed in p5..p6: the RIOT
(latches at E6) gets the stuffed byte, but the TIA's last write (E12) gets the
plain byte (Q4).
[checked (`mapper_bus.sv:113-114, 125-135, 149-150, 164-166, 203-223,
286-294`). Precisely:
- p1: `increment_lookup_index = 16 + a_in[4:0]` (IDLE && candidate,
  `:131-133`), registered at E1, so `table_increment` = map word in p2, taken
  into `stuff_map`/`stuff_stream` at E2.
- p3: `stream_index = stuff_stream` (state >= STREAM, `:125-126`), pointer
  index registered at E3, pointer valid p4.
- p4 (DATA): `ram_en`, `display_address` on port A, registered E4; p5
  (READY): `stuff_data = ram_rdata` valid and `stuff_valid`=1; port A
  re-registers the same address at E5, so p6 holds the same byte.
- The TIA: `wreg` takes the stuffed byte at E6 (`TIA.sv:1899-1901`) and the
  plain `write_DB` at E7..E12. So **the stuffed value stands in the TIA's
  register for exactly one clk (p7)**, and the plain byte from p8 on.
- Needs `bus_change` in p1 (`:205`): a write that repeats the previous cycle's
  address *and* RW does not start the FSM. The RMW final write
  after its dummy write is such a write, so only the dummy write can stuff,
  and its commit disarms the target.
- With `arm_driver_run`=0 there is no `access`, so READY persists and
  `stuff_valid` stays high p5..p12 (`:219-222`); unreachable in practice,
  because the target can be armed only by an `access`.
- `stuff_candidate` needs `a_in[11:0] == {4'b0, stuff_target}` and
  `a_in[6:0] <= $24` with A12=0 (`:113-114`), so the only stuffable writes are
  to `$0000-$0024` (TIA) and `$0080-$00A4` (RIOT RAM), mirrors excluded.]

### 5.4 After the commit (p7..p12)

`d_out` is still combinational after E6 and sees the committed state, so
`open_bus` at E12 can differ from the latched byte:
- CDF fast fetch: `fast_pending` clears at E6 (`mapper_cdf.sv:196`), so from p7
  `d_out = rom_do` (the operand byte).
- DPC+ `$1000-$1027` data reads: the counter steps at E6 (`mapper_dpcplus.sv:244-247`),
  so from p8 `d_out` is the next RAM byte.
- BUS stream read: the pointer table is written at E7 (B20), so `d_out`
  becomes the next stream byte a few clk_sys later.
Only a partially driven read in the next cycle (TIA D5:D0, `TIA.sv:1944-1964`)
can see this; after a cart data read the next cycle is normally an opcode
fetch from the cart (fully driven).
[corrected: exact edges, plus the cases that were missing. `open_bus` after
the cycle is `d_out` in p12:
- CDF fast fetch: from p7 `d_out = rom_do`, the raw operand byte
  (`mapper_cdf.sv:196`; `cart2600.sv:229-231`). [checked]
- CDF and BUS3 jump operand: `expected_address`/`jump_operand_address` moves
  at E6 (`mapper_cdf.sv:208`; `mapper_bus.sv:238`), so from p7 `d_out =
  rom_do` = `$00`/`$01`.
- **DPC+ fast fetch** (missing): `fast_pending` clears at E6
  (`mapper_dpcplus.sv:236`), so `register_read`=0 and from p7 `d_out =
  rom_do`, the raw operand (`< $28`).
- DPC+ `$1008-$1017` (functions 1, 2): `counter` steps at E6
  (`:244-245`). `ram_counter_address` moves in p7, port A registers it at
  E7, and the next RAM byte appears in p8. For function 2 the window flag
  (`:109-110, 125, 175`) is combinational from `counter`, so it changes in
  p7 against the old RAM byte, and both are new from p8.
- DPC+ function 3 (`$1018-$101F`): `fractional += increment` at E6
  (`:246-247`). The RAM address `fractional[19:8]` may change in p7, and the
  byte in p8.
- **DPC+ random reads** (missing): `$1000`/`$1001` step `random_number` at E6
  (`:238-242`). `d_out` is combinational (`random_next`/`random_prior` of the
  new value), so it changes **from p7**. `$1002-$1004` read the register and
  change with it.
- BUS stream read: from p8 `pointer` is the new word (read-during-write, B20).
  `display_address` changes, port A registers it at E8, and **from p9** `d_out`
  is the next stream byte.
- Amplitude reads (CDF, BUS, DPC+ `$1005`): `amplitude` changes only at the
  audio engine's own capture edges (`arm_mapper_audio.sv:317-327, 345,
  355-360`), which can fall anywhere in the cycle, so it can also change
  between E6 and E12 (or before E6).]

## 6. ARM call and DMA stall

**B22. Stall signal.** `arm_call_stall = tia_en && (arm_call_busy ||
(!mapper_init_busy && arm_dma_busy))` (`top.sv:306-307`);
`RDY = maria_RDY && tia_RDY && (~tia_en || tia_RDY_seen_high) &&
!arm_call_stall` (`top.sv:328-329`). `arm_call_busy` is the controller's
clk_sys register (`arm_mapper_controller.sv:123, 147, 160, 174`);
`arm_dma_busy` the memory system's (`arm_mapper_memory.sv:269, 342, 346`).
[checked. `RDY` is combinational from `call_busy`, so the stall reaches the
6507's E0 sample in the same clk. Note `dma_busy` is reset only by `reset_sys`
= `arm_reset` (`arm_mapper_memory.sv:232-269`; `cart2600.sv:444`), not by the
6507 reset. During a 6507 reset the stall is masked by `tia_en`=0 instead.]

**B23. What the mapper sees.**
`stall_cycle_taken`: cleared at any edge where `arm_call_stall` was 0, set at a
`pclk0` edge where it was 1 (`top.sv:320-326`).
`mapper_phi2 = pclk0 && (!arm_call_stall || !stall_cycle_taken)`
(`top.sv:327`). So, sampled in p6 of each cycle: the **first** `pclk0` with the
stall high is shown; every later one is hidden while it stays high; the first
`pclk0` after it falls is shown. `mapper_phi2` drives `access` and
`access_taken` (`cart2600.sv:247, 259`); nothing else in cart2600 uses `phi2`.
[checked. The general rule, which covers every case below: **a `pclk0` is
hidden iff the stall is high in its clk (p6) and an earlier `pclk0` edge
already saw the stall high with no stall-low clk since.** Any single clk of
stall-low clears `stall_cycle_taken` (the `!arm_call_stall` branch has
priority, `top.sv:322-323`). If that low clk is p6 itself, that phi2 is
shown because the stall is low, and the next `pclk0` is shown too if the stall
has risen again by then (B28).]

**B24. Launch timing.** The trigger is a 6507 write W:
CDF `$1FF3` with `$FE/$FF` (`mapper_cdf.sv:244-247`), DPC+ CALLFUNCTION
`$105A` with `$FE/$FF` (call) or `1`/`2` (copy/fill DMA)
(`mapper_dpcplus.sv:278-296`), BUS `$101A` (BUS1/2) or `$1FF3` (BUS3) with
`$FE/$FF` (`mapper_bus.sv:281-285`).
- E6(W): commit sets `call_pending` (or `service_pending`).
- p7(W): `call_request = call_pending && call_ready` (`mapper_cdf.sv:159`,
  `mapper_dpcplus.sv:183, 187`, `mapper_bus.sv:169`), with
  `call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy`
  (`cart2600.sv:661-662`) and `arm_call_ready = arm_online && shadow_ready &&
  !mapper_reset && !call_busy` (`arm_mapper_controller.sv:86-87`).
  DMA: `service_request = service_pending && service_ready`,
  `service_ready = !mapper_init_busy && dma_ready`, `dma_ready =
  shadow_ready && !dma_busy` (`cart2600.sv:428`; `arm_mapper_memory.sv:228`).
  [corrected: `arm_online` and `shadow_ready` are the 2-flop clk_sys
  synchronised copies `arm_online_sync2` (of `!reset_arm`) and
  `shadow_ready_sync2` (`arm_mapper_controller.sv:86, 138-141`), and
  `dma_ready` uses the memory system's own `shadow_ready_sync2`
  (`arm_mapper_memory.sv:228, 280-281`). `mapper_reset` is `effective_reset`
  (`cart2600.sv:447`). `call_request` and `service_request` are
  combinational, so a pending request launches at the first edge on which its
  ready is 1, whatever the 6507 phase. The DMA's ready does **not** test
  `call_busy`, and the call's ready does not test `dma_busy`.]
- **E7(W): `call_busy <= 1`** (`arm_mapper_controller.sv:149-161`) or
  `dma_busy <= 1` (`arm_mapper_memory.sv:335-343`); `call_pending <= 0`
  (`mapper_cdf.sv:179-180`); audio seeds its counters (`call_launch` in p7,
  `arm_mapper_audio.sv:207-211`). **`arm_call_stall` = 1 from p8(W).**
  [checked. The seeding is BUS/CDF only (`family >= 2`, `:207`; DPC+ is
  family 1). The controller also captures the payload (entry, stack, thumb,
  the six audio words) at E7 (`arm_mapper_controller.sv:149-160`).]
- Steady state, `call_ready` is 1 at E6(W) (see 8.3), so this E7(W) launch is
  the normal case ("immediate launch").

**B25. The stalled sequence (immediate launch).** W is the CALLFN write.
For every store mode the cycle after the write is the next instruction's
opcode fetch; for RMW (`INC/DEC/ASL...` on CALLFN) W is the dummy write, W+1
the final write, W+2 the fetch. Times are from E0(W).

| Cycle | Edges | RDY at E0 | Held? | Address | Mapper phi2 (p6) | CPU at E6 |
|---|---|---|---|---|---|---|
| W (write `$1FF3`/`$105A`/...) | E0-E12 | 1 | no | CALLFN | **shown** (commit sets pending) | `wr_q <= 1` |
| W+1 (opcode fetch at PC) | E12-E24 | 0 (stall since p8) | **no**: W was a write (B7) | PC | **shown**: first `pclk0` with stall high; `stall_cycle_taken <= 1` at E18 | **IR <= opcode**, `t` 1->2, PC+1, `wr_q <= 0` |
| W+2 .. R (held repeats) | E24-... | 0 | yes | PC (re-presented) | **hidden** | `DL <=` bus (opcode byte again); `t`, `c_reg` frozen |
| R+1 (resume) | first E0 with RDY=1 | 1 | no | PC+1 (the T2 word unmasked) | shown | normal |

So the CPU completes the fetch (IR latched at E18, before the ARM runs) and
then re-presents the same address, RW=1, every 12 clk_sys until RDY returns.
During the held repeats:
- `AB`, `RW` constant; no `address_change`, so no ROM re-request; `rom_do`,
  `d_out`, `read_DB` constant (the opcode byte) unless something the decode
  reads changes under it (only possible for a held stream address, 8.3).
  `open_bus` = that byte (B11).
- `access_taken` is cleared by each repeat's `phi1` and never set (B18).
- TIA, RIOT timer and video keep running (`pclk` never stops: B3, `top.sv:684`).
- The front end commits nothing (no `access`), so `fast_pending`, the jump
  arming and BUS `sty_pending` armed by W+1's fetch survive the stall.
- `arm_mapper_audio` keeps ticking (8.2).
[checked (the table: `mos6502_ctl.sv:874-876, 1394, 1398-1430`; W+2's T2
word is masked: `adl_abl`=0, and `adh_abh` survives only on the
`sb_adh` carry path, which a T2 fetch-PC word does not use, `:936-955`).
Added, the **short-call case**: everything above assumes X >= E24 (W+2's p0
sees the stall). If the call completes with X <= E23, W+2 is not held at
all, and no cycle repeats. If X <= E17, W+1's phi2 is shown because the stall
is low, not as the first stalled phi2. That is the same outcome. The minimum
call is the clk_arm handshake (2-flop sync, 23 state writes, COMMIT,
RELEASE, the ARM's own return path, 6 audio read-backs, completion toggle,
`arm_mapper_controller.sv:264-356`) plus a 2-flop clk_sys sync
(`:134-135, 163-177`). That is about 10-15 clk_sys for an empty function, so
X just before E24 is not excluded by the RTL alone. It depends on the ARM
core's `state_ready` and fetch latency, which this spec does not cover.]

**B26. Release.** `call_busy <= 0` (and `call_done <= 1`) at the clk_sys edge X
after the completion toggle crosses (`arm_mapper_controller.sv:163-177`);
`arm_call_stall` = 0 from p(X+1); `stall_cycle_taken <= 0` at X+1. Let R be
the held cycle containing X, with edges E0(R)..E12(R):
- **X in E0(R)..E5(R)** (stall falls in R's phase 1): p6(R) sees the stall low,
  so `mapper_phi2` = 1: **the held address is shown to the mapper a second
  time** at E6(R). The CPU is still held at E6(R) (`rdy_q` = 0 from E0(R)) and
  re-latches DL. E12(R): RDY=1, resume.
- **X in E6(R)..E11(R)**: E6(R) was hidden; E12(R) resumes. No second take.
In both cases the CPU goes on with the DL of the last held E6 and the next
cycle presents PC+1 (B7). Which case occurs depends on the call's length
modulo 12 clk_sys (clk_arm CDC and program length), so it is not under the
6507's control (Q5).
[checked by re-running the writer's bench (`stallbench/obj_dir/tbsim`, no
ROM) and by the rule in B23. Added: `call_done` is a one-clk pulse in p(X+1)
(`arm_mapper_controller.sv:142, 175`). The audio engine applies the returned
counters and frequencies at E(X+1) (`arm_mapper_audio.sv:213-223`), and the
controller's `audio_*_return` registers change at X (`:168-173`). The release
edge X is a clk_sys edge after a 2-flop sync of a clk_arm toggle, so it can
fall on any of the 12 phases.]

**B27. Effect of the second take** (the held address is the opcode fetch at
PC, `rom_data` = opcode, same state as after E18):
- CDF: idempotent. Not a substitute (expected addresses are PC+1);
  `fast_pending <= fast_mode && opcode_arms_fetch` and the `$4C` arming
  (`jump_remaining <= 2`, expected `<= PC+1`) repeat with the same values
  (`mapper_cdf.sv:210-223`).
- DPC+: idempotent. `register_read` needs `rom_data < $28` but the opcode is
  `$A9` when `fast_pending` (`mapper_dpcplus.sv:112-115, 251`).
- **BUS: not idempotent.** If W+1 armed `jump_remaining` (`$4C`, BUS3) or
  `sty_pending` (`$84`), the second take sees `jump_remaining != 0` without
  `jump_substitute` and clears it (`mapper_bus.sv:232-241`), and sees
  `sty_pending` with `a_in != sty_operand_address` and clears it
  (`:248-253`). So a `JMP` or `STY zp` right after a BUS call loses its fast
  jump / stuff arming in the X-in-phase-1 case only.
- Bank hotspots would also re-fire, but only if the opcode sits on one.
[checked against `mapper_cdf.sv:182-224`, `mapper_dpcplus.sv:227-252`,
`mapper_bus.sv:225-263`. Precisely, for BUS: `jump_remaining` is armed only
on BUS3 with `fast_mode`, `rom_data==$4C` and `fast_jump_valid` (`:242-246`).
`sty_pending` is armed with `fast_mode` and `rom_data==$84` (`:254-256`). CDF
cannot be armed by W+1 against an older `expected_address`, because the
CALLFN instruction's own operand reads cleared any jump arming (`:221-223`).
DPC+'s second take re-evaluates `fast_pending <= fast_fetch && rom_data==$A9`
(`:251`), the same value. The re-fired hotspot selects the same bank.]

**B28. Variants.**
- **RMW on CALLFN**: W dummy write (old value) can launch; W+1 (final write)
  is shown at E18 (first phi2 with stall high) and can set `call_pending`
  again if its value is `$FE/$FF`; W+2 (fetch) is **not held** (W+1 was a
  write) but its phi2 is **hidden** (`stall_cycle_taken`=1): the CPU latches
  IR from a fetch the mapper never sees. A second pending call launches at
  X+1 (`call_ready` needs `!call_busy`), so the stall is low for exactly one
  clk_sys, p(X+1), and `stall_cycle_taken` clears: the next phi2 inside the new
  stall is shown. If p(X+1) is a p0 (X = E11 of a held cycle), RDY reads 1
  there, so one whole cycle runs between the two calls (bench: the operand
  fetch ran, then the second stall re-presented the operand address).
  [checked by re-running the bench with `+rmw` and X swept over a held
  cycle. Added: **if the one-clk dip p(X+1) is the held cycle's p6**
  (X = E5 of a held cycle), that phi2 is shown because the stall is low, and
  the dip has also cleared `stall_cycle_taken`. So the **next** cycle's phi2,
  with the stall high again, is shown too: the held fetch address is
  committed twice in a row (bench `+x=46`: cycles 23 and 24 both
  `mapper_phi2=1`, then hidden). For any other dip position exactly one
  phi2 is shown: the first one after the dip.
  Which RMW values matter (`INC/DEC/ASL/LSR/ROL/ROR` and the illegal RMW
  opcodes write `v` then `f(v)`): two calls need `v, f(v)` both in
  `{$FE,$FF}`: INC `$FE`, DEC `$FF`, ASL `$FF`, ROL `$FF` (either C), and
  ROR `$FE` or `$FF` with C=1. For DPC+, two DMA services need both in `{1,2}`:
  INC 1, DEC 2, ASL 1, LSR 2, ROL 1 with C=0, ROR 2 with C=0. One call plus
  one DMA in either order is **unreachable**: no RMW maps `{1,2}` to
  `{$FE,$FF}` or back. The read value `v` is whatever the cart returns at
  the CALLFN address (a ROM byte for all three front ends).]
- **Delayed launch** (`call_ready`=0 at E6(W)): `call_pending` stays and
  `call_busy` rises at the first edge with `call_ready` (any clk_sys). The 6507
  keeps running meanwhile; the cycle containing the rise completes, and is
  held from the next E0 only if it was a read (B7). The first `pclk0` with the
  stall high is shown, whatever cycle it belongs to. The held address can then
  be any read, including a stream read (8.3).
  [checked, with the exact cases. Let N be the cycle in which `call_busy`
  rises, at edge Ek(N):
  - k <= 5: N's own phi2 (p6) sees the stall and is the shown one. N's
    commit and any DSWRITE/stream-write port-A write at E6(N) happen with the
    call in flight. N+1 is held iff N was not a write. If N+1 is held, it
    re-presents N's address (RW=1), even if N+1's control word is a write
    (B7), and every held phi2 is hidden.
  - k >= 6: N's phi2 was before the rise. N+1's phi2 is the first with the
    stall high and is **shown**. If N was a read, N+1 is held and presents
    N's address again, so **the mapper commits N's address a second time**:
    a stream read advances its pointer twice, a DPC+ `$1008-$101F` read
    steps its counter twice, and the CPU keeps the DL of the last held E6. If N
    was a write, N+1 runs normally, shown, with its own address, and N+2 is
    held.]
- **DPC+ copy/fill (`arm_dma_busy`)**: same launch (E7(W)) and the same
  `mapper_phi2` rule. The DMA runs in `arm_mapper_memory.sv:858-892`: a count of
  0 completes in DMA_IDLE (`:868-869`), a fill writes one byte per accepted
  clk_arm (`:878-892`), a copy waits on DDR per 8 bytes. W+2 is held only if
  `dma_busy` is still 1 in p0 of W+2 (p24 from E0(W)); a short service holds
  nothing (W+1 is never held). `arm_call_stall` ignores `arm_dma_busy` while
  `mapper_init_busy` (`top.sv:306-307`).
  [checked (`arm_mapper_memory.sv:858-892`). Added: the fill and copy writes
  go to port B through the memory system (`dma_ram_en`, `:507, 637-643`), one
  byte lane per accepted clk_arm. The CPU path is locked out meanwhile
  (`ram_phase = ram_target && !dma_ram_en`, `:601`). `dma_busy` falls two
  clk_sys after the completion toggle (`:345-347`). A short service (count 0
  or a few bytes) can end before W+2's p0. Then nothing is held, and the
  DMA's port-B writes all fall between E7(W) and about E7(W)+3 clk_sys + 1.25
  clk_arm per byte. The next 6507 cart RAM access is no earlier than W+2.]

**B29. Bench check (game-free).** [checked: re-ran the built
`stallbench/obj_dir/tbsim` with `+rmw +x=40..52`. The results agree with
B25-B28 and with the double show at a p6 dip. The bench models
`call_busy` directly, so it does not cover the controller's CDC or the
writeback.] `scratchpad/stallbench/tb.sv` runs
upstream's `mos6502` with a 12-clk phase generator, top.sv's
`stall_cycle_taken`/`mapper_phi2`/RDY lines and a CDF-style trigger
(`LDA #$FF; STA $1FF3; LDA #$05`); `tb_bus.sv` adds upstream's `mapper_bus`
(BUS3, `LDA #0; STA $1FF2; LDA #$FE; STA $1FF3; STY $80`). Built with
`verilator --binary --timing -Wfuture-PROCASSINIT`, no ROM. Results:
- `call_busy` rises at E7 of the write; the fetch after it runs unheld with
  `mapper_phi2`=1 and IR latched; the repeats re-present the fetch address with
  `mapper_phi2`=0 and `hold`=1; the operand fetch follows the release (B25).
- X at E11 or E6 of a held cycle: no second take. X at E0 or E5: second take
  with the CPU still held (B26).
- RMW (`INC $1FF3`, `$FE`): dummy write launches, final write shown, fetch
  unheld but hidden, second call after a one-clk dip (B28).
- BUS3: with the second take, `sty_pending` clears and `STY $80` does not arm
  stuffing (`stuff_target` stays 0); without it, the target is armed (B27).

## 7. Resets

- `effective_reset = reset | reset_hold` (`top.sv:255`). `reset_hold` asserts
  immediately and releases on a phase boundary: on a `pclk1` with the MARIA
  source stable, or, for bypassed 2600 without `cpu_driver`, 2 master
  half-cycles into phase 1 (`top.sv:261-262, 266-286`). MARIA keeps `pclk`
  running through reset (`maria.sv:210-212`); the TIA divider restarts
  (`TIA.sv:569-574`); after release the source hands over to the TIA divider
  with `cpu_driver` (`top.sv:259-260, 1312-1344`).
  [corrected: the bypassed-2600-without-`cpu_driver` case
  (`first_phase_is_phi1 = bypass_bios && tia_mode && !cpu_driver`,
  `top.sv:254, 261-262`) waits for a MARIA `pclk0`, which sets
  `reset_phase_wait=3` at that edge. The following edges count 3->2, 2->1, and
  the third edge after the `pclk0` edge clears `reset_hold`
  (`top.sv:273-281`). With the `pclk0` edge as E6 of a MARIA cycle, release
  is at **E9**, mid **phase 2** (the comment's "high phase"), not phase 1, and
  the CPU's first enable is the next `pclk1`. Every other case releases at an
  edge where `pclk1` is high, i.e. **at an E0** (`:282-283`), so
  `effective_reset`=0 from p1. Both need the MARIA source running and stable
  (`phase_source_stable && phase_valid && !phase_source_tia`, `:271-272`).
  Upstream's defaults (`cpu_driver`=1, `bypass_bios`=1, WR:554, 623) take
  the E0 path.]
- `ctrl_reg` clears `tia_en`/`lock` in reset (`top.sv:1369-1375`), so
  `arm_call_stall` = 0 and `arm_driver_run` = 0 during reset, and the cart RAM
  port belongs to the 7800 path (`top.sv:752-759`). With `bypass_bios` the first
  clk_sys after reset sets `lock = tia_en = tia_mode` (`:1376-1382`), so
  `arm_driver_run` = 1 from the second clk_sys after release. [checked:
  release at E0 -> `rst`=0 in p1 -> `lock`/`tia_en` set at E1 ->
  `arm_driver_run`=1 from p2 of the first cycle. That cycle's phi2 can
  therefore commit. `ctrl_writes`=2 at E1 too, which starts the TIA handoff
  request (`top.sv:259-260`).]
- Front ends reset with `effective_reset` (`cart2600.sv:805, 843, 902`);
  `call_pending`/`service_pending` clear.
- A reset during a call: `call_busy <= 0` at the next edge
  (`arm_mapper_controller.sv:144-147`); the ARM side goes to WAIT_HALT after its
  2-flop sync (`:271-276`; `arm_mapper_subsystem.sv:107-115`), `halt_req`=1
  (`arm_mapper_controller.sv:211`). `arm_mapper_ram_init` re-runs on every
  rising `mapper_reset` once an image is loaded (`arm_mapper_ram_init.sv:223-226`):
  DMA fill/copy and table reload, `mapper_init_busy` high meanwhile. Pocket
  holds the 6507 in reset while `mapper_init_busy` (`core/atari7800_pocket.sv:166-172`);
  the MiSTer wrapper is not vendored (Q1).
  [corrected: settled. Upstream does the same:
  `reset <= RESET | buttons[1] | status[0] | cart_download | bios_download |
  status[48] | old_cart_download | mapper_init_busy | pll_busy | ~clock_locked`
  on clk_sys (WR:75-79), fed to top's `reset` (WR:527), and top's `loading`
  also includes `mapper_init_busy` (WR:528). `busy` covers the whole download
  (`loading`, `arm_mapper_ram_init.sv:75, 207-208`) and every init state, so
  the 6507, the front ends and the audio engine (all on `effective_reset`) are
  held for the whole init. They are released one clk after `busy` falls,
  plus `reset_hold`'s phase alignment. The init re-run is triggered by the
  rising edge of `effective_reset` (`arm_mapper_ram_init.sv:205, 222-226`),
  i.e. by every console reset once an image is loaded.]
- The writeback's both sides reset on `reset` (`cart2600.sv:741, 751`), which
  drops a writeback in flight. Audio resets with `reset` (`cart2600.sv:762`).
- `arm_reset` (power-on) resets the ARM and the call/memory clk_arm sides
  (`top.sv:812, 1157`); `call_ready` waits for `arm_online`.
  [corrected: `arm_reset` also resets the clk_sys sides of the controller and
  the memory system (`reset_sys` = `reset_arm`, `cart2600.sv:444`;
  `arm_mapper_controller.sv:92-124`; `arm_mapper_memory.sv:232-269`),
  including `call_busy`, `dma_busy` and both `shadow_ready` syncs. Upstream
  drives it with `!clock_locked` (WR:592), i.e. at power-up and on every PLL
  relock (a region change, WR:390-425). It clears `shadow_ready`
  (`arm_mapper_memory.sv:659`), which is set again only at the end of a
  download (`:770-777`).]

## 8. Cart RAM during an ARM call (for the guard)

### 8.1 Upstream's ports and its own guard

- Port A (clk_sys): the console side, B19. Port B (clk_arm = 5 x clk_sys,
  `cart_ram_tdp.sv:29-31`): `arm_ram_*`, shared by the table writeback
  (priority) and the ARM memory system (`cart2600.sv:430-439`), which itself
  muxes its DMA engine over the CPU (`arm_mapper_memory.sv:600-601, 637-643`).
- **Port B never writes on a clk_sys edge.** `arm_phase` tracks the clk_sys
  toggle and `arm_allow = arm_en && !mapper_edge` is 0 in the clk_arm period
  that ends on the one clk_arm edge in five that coincides with a clk_sys edge
  (`cart_ram_tdp.sv:33-56`). Port B's write enable is `arm_allow && ...`
  (`:80`) and `arm_accepted = arm_allow` (`:56`); the ARM, the DMA engine, the
  writeback and the table snoop all wait for `ram_accepted` before they count
  an access done (`arm_mapper_memory.sv:620, 637-643, 878-879, 1009`;
  `arm_mapper_writeback.sv:110-117`; `arm_mapper_tables.sv:142-150`). Port B's
  address register has no clock enable, so it still *reads* on the shared edge,
  but that data is never accepted. So in upstream no port-B write, and no
  port-B read that is used, shares an edge with port A; the nearest is one
  clk_arm (13.97 ns NTSC) away.
  [checked by stepping `cart_ram_tdp.sv:41-54` with edge-aligned clocks
  (PLL 0 ps, `pll_0002.v:40-49`). Shared edges are E_k = t, t+5, ... in
  clk_arm units. The coincident clk_arm edge samples the old `sys_toggle`, so
  `sys_toggle_arm` changes at t+1 and the reload `arm_phase <= 2` happens at
  t+2. The phase-4 period is (t+4, t+5), which ends on the next shared edge.
  Accepted port-B edges are therefore E_k+1/5 .. E_k+4/5.]
- [added] **Writeback timing, exact.** A `pointer_update` in p7 flips
  `pointer_toggle` at E7 (`arm_mapper_writeback.sv:61-65`); `pointer_sync1`
  at E7+1/5, `sync2` at E7+2/5; `active` at E7+3/5 (`:118-123`). The period
  (E7+3/5, E7+4/5) is accepted, so the word is written at **E7+4/5** and
  `pointer_ack_arm` toggles there (`:110-117`). `ack_sync1` at E8, `ack_sync2`
  at E9, so `idle` (`:40-41`) is 1 **from p10**. A BUS stuffing commit
  raises `pointer_update` and `map_update` together: the map word follows,
  `active` at E8 and written at **E8+1/5**, and `idle` is 1 from **p11**. In
  both cases this completes well before the next cycle's E6 (E18), so the
  writeback never drops an update (`:61, 67` need `idle`), since updates are
  at least 12 clk apart. The same E7+4/5 is in cdf.md section 13.4,
  simulated.
- The ARM CPU only runs between CTRL_RELEASE and its return
  (`halt_req = control_state != CTRL_RUNNING`, `arm_mapper_controller.sv:211`),
  i.e. strictly inside `call_busy`: it starts after the 2-flop call sync and the
  23 state writes (`:264-265, 284-318`) and is halted before the 6 audio
  read-backs and the completion toggle, which then takes 2 more clk_sys flops
  before `call_busy` falls (`:134-135, 163-177, 325-356`). [checked. The
  return is detected on the ARM's fetch of `RETURN_SENTINEL`
  (`return_fetch = hit_sentinel`, `arm_mapper_memory.sv:578, 633`). The ARM
  bus is a single `mem_req`/`mem_ready` port (`top.sv:819-827`), and a cart
  RAM store gets `mem_ready` only once it is `ram_accepted`
  (`arm_mapper_memory.sv:602, 619-620`), with no write posting. So every ARM
  cart RAM write of the call has landed before that fetch is answered. `CTRL_IDLE` also needs `shadow_ready` and the previous
  completion acknowledged (`arm_mapper_controller.sv:285-287`).]

### 8.2 Console-side cart RAM traffic while a call is in flight (immediate launch)

"In flight" = `call_busy` = 1, i.e. p8(W) to X.

| # | Access | Port / clock | During the call | Consumed? | Source |
|---|---|---|---|---|---|
| 1 | Unconditional port-A read of `cartram_addr` | A, every clk_sys | Every edge. Address = `audio_ram_addr`, which is `0` outside an audio ISSUE state. | Only in an audio CAPTURE state (row 2). | `top.sv:921`; `cart2600.sv:966-967`; `arm_mapper_audio.sv:132` |
| 2 | **Audio engine reads** | A | Yes. Free-running 20 kHz tick on clk_sys (`tick_accum`, every 715/716 clk_sys; `CLK_RATE` stays 14318182 in PAL), unaffected by the stall. Per tick: DPC+ (family 1) 3 sample bytes at `$0C00 + wave*32 + idx`; CDF/BUS (families 3/2) per voice a waveform-pointer word at `waveform_base + 4v`, a size word at `audio_size_addr + 4v` if that is non-zero, and a sample byte at `$0800 + offset` (CDFJ+ masked to RAM size); digital mode one pointer word, then a RAM sample byte or a ROM sample (DDR, not cart RAM). DPC+ NOTE reads (`$1C00 + 4n`) need a 6507 write, so none. Each read: address in the ISSUE period (only when granted), registered by port A at the edge leaving ISSUE, consumed at the edge leaving CAPTURE. | **Yes**: amplitude, waveform pointer/size. These words are ones the ARM may write during the call. [checked. Added: (a) whether a given audio read sees the ARM's old or new word depends on where the ARM's port-B write falls against the audio engine's grant edge, i.e. on the ARM program's timing (fetch/DDR latency) relative to the free-running tick. A clone with different ARM timing gets the same words only if the ARM writes them before the next tick's reads, or after the call's last tick. (b) During the call `sel_ram_sel`=0 (row 3), so every ISSUE state is granted in its first clk: each read takes exactly ISSUE + CAPTURE = 2 clk. (c) The DPC+ NOTE path cannot start during a call: `dpc_note_write` needs a committed 6507 write to `$1075-$1077` (`mapper_dpcplus.sv:311-315`), and a note committed before W has been serviced within a few clk, because IDLE gives `note_pending` priority (`arm_mapper_audio.sv:226-228`).] | `arm_mapper_audio.sv:57, 76, 99-157, 191-199, 225-363`; `cart2600.sv:658-660, 760-801, 965` |
| 3 | Front-end reads of the held address | A | **None.** [checked; this also covers W+1 itself, the shown fetch at PC in p13..p24, which is inside the call. `fast_pending` is 0 there in CDF and DPC+, because the CALLFN instruction's operand reads (`$F3 $1F`, `$5A $10`, `$1A $10`) set it to "is this byte an arming opcode" = 0, `mapper_cdf.sv:211`, `mapper_dpcplus.sv:251`. A CDF `fetch_offset_enable` window covering those bytes is the only exception, and then `a_in` must still equal `fast_expected_address`.] The held address is the opcode fetch at PC (B25), which selects no RAM in any family: CDF substitutes only at `fast_expected_address`/`expected_address` = PC+1 (`mapper_cdf.sv:99-105`); DPC+ needs PC < `$1028`, or `fast_pending` with `rom_data < $28` while `rom_data` is the `$A9` that set it (`mapper_dpcplus.sv:112-115, 251`); BUS needs PC in its stream window or PC = `jump_operand_address` = PC+1 (`mapper_bus.sv:96-98, 115-116`). So `sel_ram_sel`=0 and audio always has the port. | n/a | as cited |
| 4 | 6507 cart RAM writes | A | **None** (8.3). | n/a | |
| 5 | BUS stuffing reads | A | None: needs a 6507 write below `$1000` (`mapper_bus.sv:113-114`). | n/a | |
| 6 | Init reads / init DMA | A / B | None: a call needs `!mapper_init_busy` (`cart2600.sv:661-662`). | n/a | |
| 7 | Table RAM sys-port reads | tables, clk_sys | Every edge at the default lookup index (CDF 32, BUS 0; DPC+ has none) (`mapper_cdf.sv:120-121`; `mapper_bus.sv:127-128`). [corrected: with DPC+ the tables still read every edge, at index 0. The lookup mux takes the BUS front end's index when `mapper != BANKCDF` (`cart2600.sv:663-666`), and that front end is held in reset (`:902`). CDF's `display_address` from index 32 also drives CDF's idle `ram_addr`, but `ram_en`=0.] | No: nothing reads `table_pointer`/`table_increment` without a stream access. | `arm_mapper_tables.sv:151-155` |
| 8 | Table snoop writes | tables port B, clk_arm | On each accepted ARM write into a pointer/increment/map window. | Seen by the first stream access after the call. | `arm_mapper_tables.sv:139-150` |
| 9 | Table writeback | B (mapper-owned) | **None.** A call launches only with the writeback idle (`cart2600.sv:661`), and the only shown phi2s inside the call (W+1's fetch, or for RMW the final CALLFN write; the possible second take) are opcode fetches or CALLFN writes, which raise no `pointer_update`/`map_update` (`mapper_cdf.sv:194-224`; `mapper_bus.sv:231-263`). | n/a | `arm_mapper_writeback.sv:40-41, 61-71` |
| 10 | DPC+ copy/fill DMA | B (mapper-owned) | Not concurrent with a call, except in the RMW edge case of B28 (dummy write `1/2`, final write `$FE/$FF`: `call_ready` does not test `dma_busy`). [corrected: that edge case is **unreachable**: no 6502 RMW maps a value in `{1,2}` to one in `{$FE,$FF}` or back (B28). A DMA and a call can overlap only through a delayed launch. A DMA on its own (CALLFUNCTION 1/2) is a separate stall with the same `mapper_phi2` rule: its port-B writes run while the audio engine reads port A (row 2), and it holds the 6507 only if it outlasts W+1 (B28).] | | `cart2600.sv:661-662`; `mapper_dpcplus.sv:281-295` |
| 11 | [added] Audio-side DDR sample (CDF/BUS3 digital mode) | DDR via the memory system's sample path, not cart RAM | Can run during a call: `sample_ready = shadow_ready_sync2 && !sample_busy` does not test `call_busy` (`arm_mapper_memory.sv:229`), and the one DDR state machine serves it in turn with the ARM's cache-line fills and DMA copies (`:763-790, 808, 837-844, 988`). Its latency, and so when `amplitude` changes, depends on ARM DDR traffic. | Yes (`amplitude`) | `arm_mapper_audio.sv:335-361` |
| 12 | [added] Audio register update at release | registers | `call_done` in p(X+1) loads the returned counters/frequencies at E(X+1) (counters only if the ARM changed them from the launch seed) (`arm_mapper_audio.sv:207-223`). Ticks between E7(W) and X use the pre-call frequencies. | Yes | `arm_mapper_controller.sv:163-177` |

After X the ARM is already halted. The first consumed front-end RAM read
after a call is in R+1 or later (its address registered from E1 of that
cycle at the earliest), so it never overlaps the ARM. [checked. The second
take at E6(R) is a commit of the opcode fetch, which reads no RAM (row 3).
In the RMW double call, the cycle between the calls (B28) is an operand
fetch at PC+1. That *can* be a substituted read (`LDA #` fast fetch, or a
JMP operand) whose port-A reads run with the first call finished (the ARM is
halted) and before the second call's ARM starts (2-flop sync + 23 state
writes later). So it does not overlap the ARM either. In that case the
second call launches at that cycle's own E0 (L). The ARM can reach
`CTRL_RUNNING` no earlier than L + (2 sync + 1 IDLE + 23 writes + COMMIT +
RELEASE)/5 = **L+5.6 clk_sys**, since each state write takes at least one
clk_arm (`arm_mapper_controller.sv:264-318`). The operand's port-A word is
read at the E5 address register and latched by the 6507 at E6 = L+6 from that
E5 read, so no ARM write can reach it.]

### 8.3 Can the 6507 write cart RAM while a call is in flight?

**No, in every sequence reachable with an immediate launch.** After E7(W) the
6507 executes only: the rest of W (the CALLFN write itself; `$1FF3`, `$105A`,
`$101A` are not RAM-writing addresses: `mapper_cdf.sv:150`,
`mapper_dpcplus.sv:144-146`, `mapper_bus.sv:102-104`), W+1 (an opcode fetch,
or the RMW final write to the same CALLFN address), W+2 in the RMW case (a
fetch), then held reads until X. Stack pushes go to page 1 (A12=0), never the
cart (B8).

**Only a delayed launch can overlap**, i.e. `call_ready`=0 at E6(W). The
conditions are `!arm_online` (ARM power-on reset), `!shadow_ready` (ROM shadow
not loaded), `mapper_reset`, `call_busy`, `!mapper_wb_idle`,
`mapper_init_busy` (`arm_mapper_controller.sv:86-87`; `cart2600.sv:661-662`).
In steady state none holds at a CALLFN commit: the 6507 is stalled while
`call_busy`; init and reset hold the front ends; and the writeback is idle
again about E10-E11 after the update's E6 (toggle at E7, two clk_arm flops,
one active cycle, at most two more for `ram_accepted`, two clk_sys flops back:
`arm_mapper_writeback.sv:56-71, 105-131`), while the earliest CALLFN commit
after any pointer/map update is at least one 6507 cycle (12 clk_sys) later.
[corrected, with each term settled:
- writeback: idle from exactly **p10** (pointer only) or **p11** (pointer +
  map) of the updating cycle (8.1). `call_request` is evaluated in p7(W),
  and W is never itself an updating cycle (a CALLFN write raises no update).
  So `mapper_wb_idle`=1 at every CALLFN.
- `mapper_init_busy` and `mapper_reset`: the 6507 is in reset for both on
  MiSTer as on the Pocket (WR:75-79, section 7), so no CALLFN can commit.
- `shadow_ready_sync2` (old open question Q7, settled within the RTL): an
  ARM family's init starts at `load_end` with `INIT_DMA_FIRST`, which waits
  for `dma_ready` = the memory system's `shadow_ready_sync2`
  (`arm_mapper_ram_init.sv:212-218, 229-232`; `cart2600.sv:426`;
  `arm_mapper_memory.sv:228`). The controller's `shadow_ready_sync2` is an
  identical 2-flop sync of the same clk_arm signal, with the same reset
  (`arm_mapper_controller.sv:140-141`; `arm_mapper_memory.sv:280-281`). So
  both copies are 1 before `busy` can fall, and the 6507 (in reset while
  `busy`) cannot run with it 0. After an `arm_reset` without a reload
  (`!clock_locked`, a PLL relock, WR:592) `shadow_ready` stays 0. The re-init
  that the accompanying console reset triggers then waits in
  `INIT_DMA_FIRST`, `busy` stays 1, and the 6507 stays in reset. So that does
  not open a delayed-launch window either; it just never starts.
- `arm_online_sync2`: 1 two clk_sys after `arm_reset` falls
  (`arm_mapper_controller.sv:138-139`). WR's console `reset` includes
  `~clock_locked` (WR:76-78), so the 6507 is in reset then too.
- `call_busy`: the 6507 is stalled for the whole call. Only the RMW final
  write (B28) commits a CALLFN while `call_busy`=1, and its pending call
  launches at X+1 with the 6507 held (or in the one-cycle gap of B28).
So on upstream MiSTer a delayed launch happens only through the RMW
double call. That launch is at X+1, between calls, with the 6507 held at an
opcode fetch, or, if X = E11, running one operand-fetch read (above).]
If a delayed launch did happen, the cycle in which `call_busy` rises (and the
next one, if that cycle is a write) can write cart RAM with the call in flight:
CDF `$1FF0` and BUS stream writes only if their phi2 is the shown first one
(B23); DPC+ `DFxWRITE/PUSH` regardless, through the ungated strobe (5.3),
with the counter frozen if the phi2 is hidden. A held stream read would also
keep a front-end port-A read (row 3) live for the whole call, consumed at the
last held E6.
[corrected: "the next one, if that cycle is a write" is right, but the held
cycle is not "a held stream read" kept live with its substitution. Per B28,
after N's commit the held repeats present N's address, while the front end's
state has already moved: a fast fetch or jump operand no longer substitutes
(5.4), a stream read substitutes again with the advanced pointer, and a
second commit is possible (k >= 6). Added, for the only delayed launch
reachable upstream (RMW double call, X = E11, B28): the operand fetch N runs
shown at the second call's launch cycle, N+1 is held re-presenting the
operand address, and the held E6s re-latch DL from `d_out` after the commit.
That is the raw ROM operand for a CDF/DPC+ fast fetch (5.4). The 6507 core
re-applies the frozen control word on release (`mos6502_ctl.sv:904-913`).
Whether the instruction's register load then takes the re-latched DL is a
property of the core's control words, not traced here; the bench run `+x=40`
reproduces the bus sequence.]

### 8.4 What a guard has to cover (facts only)

- Upstream has no same-edge port-A/port-B access at all (8.1). The only
  console-side reads whose data is used while the ARM runs are the audio
  engine's (row 2). Unconsumed reads (rows 1, 7) cannot matter.
- No console-side cart RAM write is concurrent with ARM activity (8.3), and
  the mapper-owned port-B writers (writeback, DMA) are idle during a call
  (rows 9, 10).
- [added] **Answer to the guard question: can the 6507 write cart RAM while
  a call is in flight?** On upstream MiSTer, never while the ARM CPU runs.
  With an immediate launch (every CALLFN, given 8.3) the cycles inside
  `call_busy` are: the rest of W, W+1 (fetch, or the RMW final write to the
  CALLFN address), W+2 for RMW (fetch, hidden), then held fetches. None of
  them is a cart-RAM-writing access. The only access shown while `call_busy`=1
  that commits anything is W+1 (and the RMW final write, which only re-arms
  `call_pending`), plus the second take at release. The RMW double call's
  one-cycle gap (X = E11) is a read. The same holds while `dma_busy`=1 for a
  DPC+ service: W+1 is a fetch, and the 6507 either stays held until
  `dma_busy` falls or runs on only after it has fallen (B28). So a guard that
  blocks 6507-side cart RAM writes (and 6507-side substituted RAM reads)
  while `call_busy || dma_busy` (or from E6(W) to X) **never fires on any
  sequence upstream can produce**. It does not change any value a
  per-commit or per-tick comparison sees. Things a guard *cannot* block
  without diverging from upstream: the audio engine's port-A reads during the
  call (row 2: consumed, and dependent on ARM timing), the snoop writes into
  the tables (row 8), and the DDR sample path (row 11).
- [added] Same-edge collisions do not exist upstream (8.1: port B accepts only
  at E+1/5..E+4/5). A clone whose ARM side shares clk_sys edges with port A
  must give priority to one side; upstream's observable order is "port A
  samples at E_k; port-B writes land strictly between clk_sys edges".]

## 9. MiSTer vs Pocket, bus-relevant

| Item | MiSTer (upstream) | Pocket (this repo, today) |
|---|---|---|
| Phase source in 2600 mode | `cpu_driver` from the wrapper (unknown) [corrected: TIA divider by default, `cpu_driver = ~status[21]`, OSD default TIA (WR:155, 623)] | TIA divider (`cpu_driver`=1) |
| ROM byte | `sdram.sv` via the unvendored wrapper; arrival edge unknown; consumed by E6, multicycle SDC [corrected: `sdram.sv` on `clk_vid` = 4 x clk_sys, 0 ps (WR:787-799; `pll_0002.v:42-43`): identical to the Pocket column, B16] | `sdram.sv` at 4 x clk_sys: request E1+1/4, byte at E2+3/4 (B16) |
| [added] 6507 held in reset during `mapper_init_busy` | yes (WR:75-79) | yes (`core/atari7800_pocket.sv:166-172`) |
| [added] `arm_reset` | `!clock_locked` (WR:592) | `~pll_locked` (`core/atari7800_pocket.sv:994`), unused with `NO_ARM_MAPPER` |
| Cart RAM | `cart_ram_tdp` M10K, port A every clk_sys, 1-clk latency (B19) | SRAM via `sram_ctrl`, request on level change, about 1.5-2 clk_sys plus slot waits (B21) |
| ARM front ends | present; `arm_call_stall` live | `NO_ARM_MAPPER`: bad-game screen, no stall (B21) |
| `clk_arm` | 5 x clk_sys (`cart_ram_tdp.sv:29`) | `clk_sys` passed in (`core/atari7800_pocket.sv:993`); unused |

## 10. Open questions

- **Q1.** MiSTer's wrapper (`Atari7800.sv`) is not vendored: its
  `cpu_driver` default, whether it holds the 6507 in reset while
  `mapper_init_busy` (Pocket does), and its SDRAM clock.
  [answered from WR and the vendored PLL: `cpu_driver` defaults to 1 (TIA)
  (WR:155, 623); the 6507 is held in reset while `mapper_init_busy`
  (WR:75-79); SDRAM runs on `clk_vid` = 4 x clk_sys at 0 ps (WR:787-792;
  `pll_0002.v:42-43`). Caveat: WR is a scratchpad copy of upstream at
  `ffc47192`, not a repo file.]
- **Q2.** The MiSTer ROM byte's arrival edge (B16). The front ends' own
  comments assume a 20 ns budget from the ROM (`mapper_cdf.sv:107-110`,
  `mapper_dpcplus.sv:103-106`, `cart_ram_tdp.sv:32-34`), which the vendored
  RTL does not pin to an edge.
  [answered for the edge: identical to the Pocket. Request taken at E1+1/4.
  For a same-word address the byte is visible from E1+1/4, first sampled at
  E2. For a new word the old word's byte at the new lane shows from E1+1/4,
  and the true byte is captured at E2+3/4 and first sampled at E3 (B16). Not
  answered: what the "20 ns" refers to. No path in the RTL is 20 ns. A
  clk_vid period is 17.46 ns, and with the SDC multicycle the
  `last_data` -> clk_sys budget is E2+3/4 -> E4 (87 ns). The comments read
  as fitter-budget notes. They do not change the functional edges, and the
  MiSTer `Atari7800.sdc` they may refer to is not in the repo.]
- **Q3.** `sel_ram_sel` for `rom_data`-gated selects rises when the ROM byte
  arrives, and before that the decode sees the previous address's byte (B16,
  5.2). Audio grants therefore depend on ROM latency clk by clk. A clone with a
  different ROM (front-end M10K) will grant audio on different clks; whether
  that is acceptable for the per-tick comparison is a decision, not an RTL fact.
  [still a decision. Facts the RTL now fixes: upstream's `rom_do` sequence
  per clk is fully determined by B16, including the stale p1 byte and the
  new-word lane byte in p2..p3. The select can be high **before** the true
  byte arrives (second JMP operand after a `$00` low operand, 5.2). A clone
  can reproduce upstream exactly by modelling that sequence: previous
  request's byte at E1; at E2 the true byte if same 16-bit word, else
  `prev_word[new a[0]]`; true byte from E3. That gives identical
  `sel_ram_sel` waveforms and audio grants. Any other ROM latency changes
  when audio ISSUE states are granted. The captured *values* then match
  unless a write to the same RAM word lands between the two grant clks: a
  6507-side write (DPC+ waveforms share display RAM at `$0C00+`, 5.3) or an
  ARM write during a call. But `amplitude` changes on different clks, so a
  per-tick comparison of `amplitude` sampled at a fixed clk can differ by
  one update within the tick.]
- **Q4.** BUS stuffing reaches the RIOT (latch at E6) but not the TIA's final
  register value (rewritten through E12 with the plain byte) (5.3). It looks
  unintended (`top.sv:690-695` says the RIOT must see the same bus the TIA
  does), but it is upstream's behaviour.
  [confirmed as upstream behaviour, exact form: the TIA register holds the
  stuffed value only during p7 (written E6, overwritten E7..E12,
  `TIA.sv:1899-1901`); RIOT RAM/registers take the stuffed byte at E6. Still
  a decision for the clone.]
- **Q5.** The release phase decides whether the held fetch is shown twice
  (B26), and that changes BUS state (B27). A clone with different call lengths
  cannot match it per call. Choose a rule (always the hidden case, or
  replicate by X mod 12).
  [still a decision. Facts that bound it: only BUS is affected (CDF and DPC+
  are idempotent, B27), and only when W+1's opcode is `$4C` (BUS3,
  `fast_mode`, `fast_jump_valid`) or `$84` (`fast_mode`). With the RMW double
  call, a dip on p6 shows the held address twice in a row (B28), but that
  needs an RMW on CALLFN. The rule "X mod 12 in E0..E5 => second take" is
  exact for a single call (B23).]
- **Q6.** Read-during-write of the table RAMs on their update edge E7
  (`cache_ram_tdp_dc_be`, mode not checked) affects only the post-commit
  `d_out`/`open_bus` (5.4).
  [answered: new data (`cache_ram.v:232`, `byteena_a = 4'hF`), so `pointer`
  is the updated word from p8 and a BUS stream byte changes from p9 (B20,
  5.4).]
- **Q7.** `shadow_ready` after a load on MiSTer: if the 6507 can run before
  it (Q1), an early CALLFN would take the delayed-launch path (8.3).
  [answered: it cannot. The 6507 is in reset while `mapper_init_busy`, and
  init cannot finish before `shadow_ready_sync2`=1 (8.3). The only
  delayed launch upstream can produce is the RMW double call (B28, 8.3).]
- **Q8.** [added, was in B2] TIA-source phase polarity relative to `oclk`
  across RSYNC: [answered: invariant, proof in B2. Phase 1 is always a
  `cart_ce` clk. RSYNC (and the first misaligned line end) can make one
  cycle 8 or 16 clk_sys long.]
