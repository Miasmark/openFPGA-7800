# BupChip CPU Quartus probe. run_probe.sh rewrites the "set period" line for
# each clock it compiles: 34.921 ns is 28.636364 MHz (S1, VCO/24), 46.561 ns
# is 21.477273 MHz (the final clk_arm, VCO/32).
set period 34.921
create_clock -name clk_arm -period $period [get_ports clk]
derive_clock_uncertainty
