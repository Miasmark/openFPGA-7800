#
# Atari 7800 core constraints (loaded by apf/apf_constraints.sdc)
#
# One core PLL (ic|pll) makes:
#   counter[0]  clk_sys     14.318 MHz (14.188 MHz for PAL, see pll_region.v)
#   counter[1]  clk_sdram   4 x clk_sys (same VCO)
#   counter[2]  clk_sys_90  clk_sys at 90 degrees, video sample clock
#   counter[3]  clk_arm     2 x clk_sys (same VCO): the BupChip (ARIA,
#               POCKET_BUPCHIP; docs/BUPCHIP_CORE.md, "Clocking")
# The PLL is reconfigurable, which names its outputs by counter. Timing is
# checked at the NTSC (faster) setting; PAL only slows every clock by 0.9%.
# All four share edges, so they are one synchronous group and every crossing
# between them is timed. Everything else is asynchronous to them.

set core_clks {ic|pll|altera_pll_i|cyclonev_pll|counter[*].output_counter|divclk}
set clk_sys  {ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [get_clocks $core_clks]

# The SDRAM read result, as in the MiSTer core's Atari7800.sdc: the byte in
# sdram|last_data is consumed at the bus cycle's closing enable, at least five
# clk_sdram periods after it is captured, never on the next clk_sys edge.
set_multicycle_path -setup 2 -from [get_registers {*|sdram:sdram|*}] -to [get_clocks $clk_sys]
set_multicycle_path -hold  1 -from [get_registers {*|sdram:sdram|*}] -to [get_clocks $clk_sys]

# The APF data loader (clk_sdram) changes write_addr / write_data on the same
# edge its write strobe rises, then holds them for at least ten clk_sdram
# cycles. Every clk_sys consumer uses them one to four clk_sdram cycles later,
# never on the coincident edge, so the default same-edge hold check does not
# apply to them. The strobe (write_en) keeps its full check.
set_multicycle_path -hold 1 \
 -from [get_registers {ic|loader|write_addr[*] ic|loader|write_data[*]}] \
 -to [get_clocks $clk_sys]

# POCKET_SRAM: the SRAM's cartridge / BIOS byte (sram|c_rdata) is consumed
# at the second clk_sys edge after it is written, like the SDRAM byte above,
# never on the next one. A 7800 or BIOS byte is captured at least two
# clk_sdram before the bus samples it at the second clk_sys edge after
# MARIA's strobe. A 2600 byte (Fix B: the mapper's request is registered
# into sram|t_*_q at E2) is written by E0+19 and latched by the 6507 at
# E0+24 (E6, pclk0), the second clk_sys edge after it. E0 is the edge where
# pclk1 loads the 6507's address; the counts are clk_sdram edges, so E1 =
# E0+4. E0+19 is the worst case, another client's access started just
# before the cart's; the usual one is E0+15. Fix B has no clk_sdram to
# spare against this exception, so any added 2600 latency breaks it
# silently (docs/DARIA_CORE.md, "Fix B", 2 and 7). Its other outputs
# (Flicker Blend, SaveKey) keep the default check.
set_multicycle_path -setup 2 -from [get_registers -nowarn {*|sram_ctrl:sram|c_rdata[*]}] -to [get_clocks $clk_sys]
set_multicycle_path -hold  1 -from [get_registers -nowarn {*|sram_ctrl:sram|c_rdata[*]}] -to [get_clocks $clk_sys]

# Fitter only: more margin than the real constraints, which the Timing
# Analyzer (quartus_sta) still checks unchanged. The fitter stops improving a
# path once it meets its constraint, and the padding is only its target: the
# result can land well under it.
# - Setup into clk_sdram, 1.5 ns. With the BupChip (POCKET_BUPCHIP) the
#   device is 79% full, and the first build left clk_sdram's worst setup
#   path (MARIA / 2600 mapper address and strobes into sram_ctrl's pad
#   registers; no BupChip logic) at +0.15 ns (docs/BUPCHIP_CORE.md, step 5).
#   1.0 ns of padding then gave 2.1.1 +0.26 to +0.44 ns. The release gate
#   is now +1.5 ns on every seed (docs/DARIA_CORE.md, "Fix B", 5), so the
#   padding asks for that much.
# - Hold into clk_sys, 0.1 ns: a clk_sys hold path into a JT51 shift
#   register's M10K was at -0.04 ns (fast 0 C).
# - Hold from clk_sys into clk_sdram, 0.1 ns: Fix B's request registers
#   (sram|t_*_q, clk_sys) are sampled by sram_ctrl on the coincident
#   clk_sdram edge, where a clk_sys register once failed hold by 0.13 ns
#   (Flicker Blend's frame pointer, sram_ctrl.sv's negedge capture).
# Padding for one build only goes in that build's own SDC file, so that this
# file reads the same in every build.
if {$::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {
	set clk_sdram {ic|pll|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}
	set_clock_uncertainty -add -setup -from [get_clocks $core_clks] -to [get_clocks $clk_sdram] 1.5
	set_clock_uncertainty -add -hold -from [get_clocks $core_clks] -to [get_clocks $clk_sys] 0.1
	set_clock_uncertainty -add -hold -from [get_clocks $clk_sys] -to [get_clocks $clk_sdram] 0.1
}
