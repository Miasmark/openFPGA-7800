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
// WINDOW 1 (run_probe.sh: WINDOW=1) gives the CPU DARIA's memories at full
// size instead (docs/DARIA_CORE.md, "The memory system", 1, and open item
// 1), with CODE_AW 15:
//   - the firmware ROM as above, and the 128 KB image window (32,768 x 32,
//     altsyncram with maximum_depth 8192: 8K x 1 slices, 4 deep, so a 4:1
//     output mux), both on fetch (port A) and data (port B), picked by a
//     registered profile bit: rom_q = prof ? window : firmware, likewise
//     rom_dq. The window's port B takes image writes while the CPU is held;
//   - the cart RAM at 32 KB (8,192 x 32, byte lanes), its port B on a second
//     clock, clk_sys, from and to registered virtual pins;
//   - the asset cache's data RAM, 2 x 512 x 32, read on port A at d_addr
//     (asset_q is then that M10K's output, not a flip-flop) and filled on
//     port B from virtual pins.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_probe_top #(
	parameter bit MODES = 1'b0,     // bup_cpu's MODES (run_probe.sh: MODES=1)
	parameter bit WINDOW = 1'b0,    // DARIA's memories at full size (run_probe.sh: WINDOW=1)
	parameter bit THUMB = 1'b0      // bup_cpu's THUMB (run_probe.sh: THUMB=1; arm_only from a pin)
) (
	input  wire         clk,
	input  wire         clk_sys,        // WINDOW 1: the cart RAM's port B

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
	input  wire         arm_only_i,     // THUMB 1: the profile's arm_only, registered
	// WINDOW 1 only.
	input  wire         prof_i,         // 1: the 2600 profile (the window)
	input  wire         win_we_i,       // image write into the window, while held
	input  wire  [14:0] win_addr_i,
	input  wire  [31:0] win_data_i,
	input  wire         crb_we_i,       // cart RAM port B, on clk_sys
	input  wire  [12:0] crb_addr_i,
	input  wire   [3:0] crb_be_i,
	input  wire  [31:0] crb_data_i,
	output logic [31:0] crb_q_o,
	input  wire         cf_we_i,        // asset cache fill
	input  wire   [9:0] cf_addr_i,
	input  wire  [31:0] cf_data_i,

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
	logic        rst, freeze, w_wait, fw_we, arm_only;
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
		arm_only   <= arm_only_i;
	end

	// ---- the CPU and its memories -------------------------------------------------
	localparam int CODE_AW = WINDOW ? 15 : 12;
	wire  [CODE_AW-1:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, halt_pc;
	wire  [31:0] fw_qa, fw_qb, cpu_asset_q;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, reg_sel, reg_write, halted;

	bup_cpu #(.MODES(MODES), .THUMB(THUMB), .CODE_AW(CODE_AW)) cpu (
		.clk, .rst, .freeze, .w_wait, .arm_only,
		.prof26(1'b0), .img_size(20'd0), .ram32(1'b0), .call_go(1'b0), .clr_wd(32'd0), .clr_pc(32'd0),
		.clr_e(), .parked(), .returned(), .ro_valid(), .ro_idx(), .ro_data(),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size, .asset_q(cpu_asset_q), .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc);

	cache_ram_dp #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) rom (
		.clk_i(clk),
		.addr_a_i(rom_addr[11:0]), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(fw_qa),
		.addr_b_i(rst ? fw_addr : d_addr[13:2]), .wren_b_i(rst && fw_we), .wdata_b_i(fw_data),
		.q_b_o(fw_qb));

	generate if (!WINDOW) begin : g_aria
		assign rom_q = fw_qa;
		assign rom_dq = fw_qb;
		assign cpu_asset_q = asset_q;
		cache_ram_tdp_dc_be #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) ram (
			.clk_a_i(clk), .addr_a_i(d_addr[13:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
			.wdata_a_i(ram_wdata), .q_a_o(ram_q),
			.clk_b_i(clk), .addr_b_i(12'd0), .wren_b_i(1'b0), .byteena_b_i(4'd0),
			.wdata_b_i(32'd0), .q_b_o());
		always_comb crb_q_o = 32'd0;
	end else begin : g_daria
		// The profile, as the Pocket wrapper will hold it: a clk_arm register.
		logic        prof, win_we, crb_we, cf_we;
		logic [14:0] win_addr;
		logic [31:0] win_data, crb_data, cf_data, crb_q;
		logic [12:0] crb_addr;
		logic  [3:0] crb_be;
		logic  [9:0] cf_addr;
		wire  [31:0] win_qa, win_qb;
		always_ff @(posedge clk) begin
			prof     <= prof_i;
			win_we   <= win_we_i;
			win_addr <= win_addr_i;
			win_data <= win_data_i;
			cf_we    <= cf_we_i;
			cf_addr  <= cf_addr_i;
			cf_data  <= cf_data_i;
		end
		always_ff @(posedge clk_sys) begin
			crb_we   <= crb_we_i;
			crb_addr <= crb_addr_i;
			crb_be   <= crb_be_i;
			crb_data <= crb_data_i;
			crb_q_o  <= crb_q;
		end

		// The image window: 8K-deep slices, as the Pocket-owned wrapper will
		// fix them (DARIA_CORE.md, the memory system, 1.2).
		altsyncram #(
			.intended_device_family        ("Cyclone V"),
			.lpm_type                      ("altsyncram"),
			.operation_mode                ("BIDIR_DUAL_PORT"),
			.numwords_a                    (32768),
			.numwords_b                    (32768),
			.widthad_a                     (15),
			.widthad_b                     (15),
			.width_a                       (32),
			.width_b                       (32),
			.width_byteena_a               (1),
			.width_byteena_b               (1),
			.maximum_depth                 (8192),
			.address_reg_b                 ("CLOCK0"),
			.indata_reg_b                  ("CLOCK0"),
			.wrcontrol_wraddress_reg_b     ("CLOCK0"),
			.outdata_reg_a                 ("UNREGISTERED"),
			.outdata_reg_b                 ("UNREGISTERED"),
			.outdata_aclr_a                ("NONE"),
			.outdata_aclr_b                ("NONE"),
			.power_up_uninitialized        ("FALSE"),
			.ram_block_type                ("M10K"),
			.read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
			.read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
		) window (
			.clock0    (clk),
			.address_a (rom_addr[14:0]),
			.wren_a    (1'b0),
			.data_a    (32'd0),
			.q_a       (win_qa),
			.address_b (rst ? win_addr : d_addr[16:2]),
			.wren_b    (rst && win_we),
			.data_b    (win_data),
			.q_b       (win_qb));

		assign rom_q  = prof ? win_qa : fw_qa;
		assign rom_dq = prof ? win_qb : fw_qb;

		cache_ram_tdp_dc_be #(.ADDR_WIDTH(13), .DATA_WIDTH(32)) ram (
			.clk_a_i(clk), .addr_a_i(d_addr[14:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
			.wdata_a_i(ram_wdata), .q_a_o(ram_q),
			.clk_b_i(clk_sys), .addr_b_i(crb_addr), .wren_b_i(crb_we), .byteena_b_i(crb_be),
			.wdata_b_i(crb_data), .q_b_o(crb_q));

		// The asset cache's data: two ways of 512 words, read at d_addr.
		cache_ram_dp #(.ADDR_WIDTH(10), .DATA_WIDTH(32)) cache (
			.clk_i(clk),
			.addr_a_i(d_addr[11:2]), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(cpu_asset_q),
			.addr_b_i(cf_addr), .wren_b_i(cf_we), .wdata_b_i(cf_data), .q_b_o());
	end endgenerate

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
