# BupChip CPU Quartus probe. run_probe.sh rewrites the "set period" line for
# each clock it compiles: 34.921 ns is 28.636364 MHz (S1, VCO/24), 46.561 ns
# is 21.477273 MHz (the final clk_arm, VCO/32).
set period 34.921
create_clock -name clk_arm -period $period [get_ports clk]
# WINDOW 1: the cart RAM's port B runs on clk_sys (14.318 MHz), which no
# path here shares with clk_arm.
create_clock -name clk_sys -period 69.841 [get_ports clk_sys]
set_clock_groups -asynchronous -group {clk_arm} -group {clk_sys}
derive_clock_uncertainty
