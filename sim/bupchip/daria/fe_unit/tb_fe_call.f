# tb_fe_call: daria_fe_call with the real daria_call (clk_arm side) and daria_mem's
# state RAM, a scripted stand-in for bup_cpu's call interface, and bench models of
# the audio ring (design 5.6) and of upstream's call/merge (lane C; design 12.3).
src/fpga/core/bupchip/daria_mem.sv
src/fpga/core/bupchip/daria_call.sv
src/fpga/core/bupchip/daria_fe_pkg.sv
src/fpga/core/bupchip/daria_fe_call.sv
