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

# POCKET_SRAM: the SRAM's cartridge / BIOS byte (sram|c_rdata) is captured
# at least two clk_sdram before the bus samples it at the second clk_sys
# edge after MARIA's strobe, like the SDRAM byte above. Its other outputs
# (Flicker Blend, SaveKey) keep the default check.
set_multicycle_path -setup 2 -from [get_registers -nowarn {*|sram_ctrl:sram|c_rdata[*]}] -to [get_clocks $clk_sys]
set_multicycle_path -hold  1 -from [get_registers -nowarn {*|sram_ctrl:sram|c_rdata[*]}] -to [get_clocks $clk_sys]
