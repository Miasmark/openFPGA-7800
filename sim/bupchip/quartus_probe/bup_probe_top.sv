//------------------------------------------------------------------------------
// Quartus probe for the BupChip CPU (docs/BUPCHIP_CORE.md, implementation
// step 3): bup_cpu.sv compiled alone on the Pocket's 5CEBA4F23C8, with the
// memories it will have in the Pocket build and a register on every other
// port, so the CPU's own timing paths are register to register and nothing
// is optimised away.
//
//   - ROM: cache_ram_dp, 4,096 x 32 (16 M10K), no initial contents. Port A
//     fetches (rom_addr, rom_q). Port B serves data (d_addr[13:2], rom_dq)
//     and, while the CPU is held in rst, takes the firmware writes, as the
//     write receiver will after a load of bupchip.bin. The writes are what
//     keep Quartus from folding an uninitialised ROM to zero.
//   - RAM: cache_ram_tdp_dc_be, 4,096 x 32 with byte enables (16 M10K),
//     port A only, as in bupchip_memory.sv and sim/bupchip/s1/tb_s1.sv.
//   - Everything else (rst, freeze, w_wait, asset_size, asset_q,
//     reg_rdata, and every output) goes through one flip-flop to or from a
//     virtual pin (bup_probe.qsf). d_addr is registered too: it stands for
//     the asset cache's M10K address registers, which it will drive.
//
// The asset and MMIO read data come from flip-flops here. In the Pocket
// build asset_q comes from the cache's M10K and reg_rdata from the
// peripheral's read mux, so those two inputs are optimistic; ram_q and
// rom_dq, which take the same path through the load lanes, are not.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_probe_top #(
	parameter bit MODES = 1'b0      // bup_cpu's MODES (run_probe.sh: MODES=1)
) (
	input  wire         clk,

	// Virtual pins.
	input  wire         rst_i,
	input  wire         freeze_i,
	input  wire         w_wait_i,
	input  wire  [23:0] asset_size_i,
	input  wire  [31:0] asset_q_i,
	input  wire  [31:0] reg_rdata_i,
	input  wire         fw_we_i,        // firmware write into the ROM, while held
	input  wire  [11:0] fw_addr_i,
	input  wire  [31:0] fw_data_i,

	output logic [31:0] d_addr_o,
	output logic        w_asset_o,
	output logic [31:0] w_addr_o,
	output logic  [1:0] w_size_o,
	output logic        reg_sel_o,
	output logic  [7:0] reg_addr_o,
	output logic        reg_write_o,
	output logic [31:0] reg_wdata_o,
	output logic        halted_o,
	output logic  [3:0] halt_code_o,
	output logic [31:0] halt_pc_o
);
	// ---- inputs, one register each ----------------------------------------------
	logic        rst, freeze, w_wait, fw_we;
	logic [23:0] asset_size;
	logic [31:0] asset_q, reg_rdata, fw_data;
	logic [11:0] fw_addr;

	always_ff @(posedge clk) begin
		rst        <= rst_i;
		freeze     <= freeze_i;
		w_wait     <= w_wait_i;
		asset_size <= asset_size_i;
		asset_q    <= asset_q_i;
		reg_rdata  <= reg_rdata_i;
		fw_we      <= fw_we_i;
		fw_addr    <= fw_addr_i;
		fw_data    <= fw_data_i;
	end

	// ---- the CPU and its memories -------------------------------------------------
	wire  [11:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, halt_pc;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, reg_sel, reg_write, halted;

	bup_cpu #(.MODES(MODES)) cpu (
		.clk, .rst, .freeze, .w_wait,
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size, .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc);

	cache_ram_dp #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) rom (
		.clk_i(clk),
		.addr_a_i(rom_addr), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(rom_q),
		.addr_b_i(rst ? fw_addr : d_addr[13:2]), .wren_b_i(rst && fw_we), .wdata_b_i(fw_data),
		.q_b_o(rom_dq));

	cache_ram_tdp_dc_be #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) ram (
		.clk_a_i(clk), .addr_a_i(d_addr[13:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
		.wdata_a_i(ram_wdata), .q_a_o(ram_q),
		.clk_b_i(clk), .addr_b_i(12'd0), .wren_b_i(1'b0), .byteena_b_i(4'd0),
		.wdata_b_i(32'd0), .q_b_o());

	// ---- outputs, one register each -------------------------------------------------
	always_ff @(posedge clk) begin
		d_addr_o    <= d_addr;
		w_asset_o   <= w_asset;
		w_addr_o    <= w_addr;
		w_size_o    <= w_size;
		reg_sel_o   <= reg_sel;
		reg_addr_o  <= reg_addr;
		reg_write_o <= reg_write;
		reg_wdata_o <= reg_wdata;
		halted_o    <= halted;
		halt_code_o <= halt_code;
		halt_pc_o   <= halt_pc;
	end
endmodule

`default_nettype wire
