#
# Atari 7800 core constraints (loaded by apf/apf_constraints.sdc)
#
# One core PLL (ic|pll) makes:
#   general[0]  clk_sys     14.318 MHz
#   general[1]  clk_sdram   57.273 MHz  (exactly 4 x clk_sys, same VCO)
#   general[2]  clk_sys_90  clk_sys at 90 degrees, video sample clock
# All three share edges, so they are one synchronous group and every crossing
# between them is timed. Everything else is asynchronous to them.

set core_clks {ic|pll|altera_pll_i|general[*].gpll~PLL_OUTPUT_COUNTER|divclk}
set clk_sys  {ic|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

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
