# tb_fe_copy: daria_fe_copy on daria_mem against upstream's arm_mapper_ram_init (MIT,
# src/fpga/mister/rtl) with a behavioural DMA executor, and mapper_dpcplus's service
# arithmetic transcribed in the bench (lane C; design 12.3). Run with POISON=1 as well.
src/fpga/core/bupchip/daria_mem.sv
src/fpga/core/bupchip/daria_fe_pkg.sv
src/fpga/core/bupchip/daria_fe_copy.sv
src/fpga/mister/rtl/arm_mapper_ram_init.sv
