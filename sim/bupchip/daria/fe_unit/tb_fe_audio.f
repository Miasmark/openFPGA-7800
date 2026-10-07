# tb_fe_audio: daria_fe_audio against upstream's arm_mapper_audio (lane B; design 12.3).
# Upstream's engine runs on upstream's cart RAM (cart_ram_tdp, cache_ram.v), ours on
# daria_mem; both are fed the same image, the same select stream and the same strobes.
src/fpga/core/bupchip/daria_mem.sv
src/fpga/core/bupchip/daria_fe_pkg.sv
src/fpga/core/bupchip/daria_fe_audio.sv
src/fpga/mister/rtl/arm_mapper_audio.sv
src/fpga/mister/rtl/cart_ram_tdp.sv
src/fpga/mister/rtl/cache_ram.v
