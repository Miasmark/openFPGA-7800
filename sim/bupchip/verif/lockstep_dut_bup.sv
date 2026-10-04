//------------------------------------------------------------------------------
// Lockstep DUT shell for the new core (src/fpga/core/bupchip/bup_cpu.sv),
// selected by building tb_lockstep.sv with -DDUT_BUP (run_lockstep.sh with
// DUT=bup).
//
// The core runs with its own memories, as the Pocket wrapper will give it:
// the ROM in cache_ram_dp (fetch on port A, data on port B) and the RAM in
// cache_ram_tdp_dc_be, both from cache_ram.v, plus the asset bytes of the
// +rom image (offset 128 + the header's ROM size onwards) as a behavioural
// memory. Its peripheral accesses are the replay queue's: a read in W waits
// (w_wait) until pr_avail is high and completes with pr_data. The retire
// port is wired straight through; README.md gives the rules.
//
//   +romhex=FILE  firmware ROM (default: the ROMHEX define)
//   +rom=FILE     .a78 image; the bytes after the cartridge are the assets
//   +inject=N     flip bit 0 of the data of the Nth load into a register
//   +await=P      make P% of W clocks of an asset load wait (default 0)
//   +throttle=P   raise freeze (the debug throttle) on P% of clocks (default 0)
//   +seed=S       for +await and +throttle
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
module lockstep_dut_bup (
	input  logic        clk,
	input  logic        rst,
	output logic        rt_start,
	output logic        rt_valid,
	output logic [31:0] rt_pc,
	output logic [31:0] rt_insn,
	output logic  [3:0] rt_nzcv,
	output logic  [4:0] rt_mode,
	output logic        rt_e_we,
	output logic  [3:0] rt_e_idx,
	output logic [31:0] rt_e_data,
	output logic        rt_w_we,
	output logic  [3:0] rt_w_idx,
	output logic [31:0] rt_w_data,
	output logic        st_valid,
	output logic [31:0] st_addr,
	output logic  [3:0] st_strb,
	output logic [31:0] st_data,
	output logic        pw_valid,
	output logic  [7:0] pw_addr,
	output logic [31:0] pw_data,
	output logic        pr_valid,
	output logic  [7:0] pr_addr,
	output logic        pr_wait,
	input  logic        pr_avail,
	input  logic [31:0] pr_data,
	output logic        halted,
	output logic [31:0] halt_pc
);
	logic  [7:0] img [0:4194303];
	int          img_n = 0, a_base = 0, a_size = 0, await_pct = 0, throttle = 0, seed = 1;
	longint      inject = -1, nloads = 0;
	string       romhex;

	initial begin
		string f;
		int fd;
		if (!$value$plusargs("romhex=%s", romhex)) romhex = "";
		if (!$value$plusargs("rom=%s", f)) f = "game.a78";
		fd = $fopen(f, "rb");
		if (fd == 0) $fatal(1, "cannot open %s", f);
		img_n = $fread(img, fd);
		$fclose(fd);
		a_base = 128 + {img[49], img[50], img[51], img[52]};
		a_size = img_n > a_base ? img_n - a_base : 0;
		void'($value$plusargs("inject=%d", inject));
		void'($value$plusargs("await=%d", await_pct));
		void'($value$plusargs("throttle=%d", throttle));
		void'($value$plusargs("seed=%d", seed));
		void'($urandom(seed));
	end

	// ---- the core and its memories ------------------------------------------
	wire  [11:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, reg_sel, reg_write;
	logic        asset_wait = 0, freeze = 0;
	logic [31:0] asset_q;
	wire         inj = cpu.rt_w_we && nloads + 1 == inject;	// flip this load's bit 0

`ifdef BUP_MODES
	bup_cpu #(.MODES(1'b1)) cpu (
`else
	bup_cpu cpu (
`endif
		.clk, .rst, .freeze, .w_wait(pr_wait || (asset_wait && w_asset)),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata,
		.rom_dq(rom_dq ^ {31'd0, inj}), .ram_q(ram_q ^ {31'd0, inj}),
		.asset_size(24'(a_size)), .asset_q(asset_q ^ {31'd0, inj}),
		.w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata(pr_data ^ {31'd0, inj}),
		.halted, .halt_code, .halt_pc,
		.rt_start, .rt_valid, .rt_pc, .rt_insn, .rt_nzcv, .rt_mode,
		.rt_e_we, .rt_e_idx, .rt_e_data, .rt_w_we, .rt_w_idx, .rt_w_data);

	cache_ram_dp #(.ADDR_WIDTH(12), .DATA_WIDTH(32), .SIM_INIT_FILE(`ROMHEX)) rom (
		.clk_i(clk),
		.addr_a_i(rom_addr), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(rom_q),
		.addr_b_i(d_addr[13:2]), .wren_b_i(1'b0), .wdata_b_i(32'd0), .q_b_o(rom_dq));

	cache_ram_tdp_dc_be #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) ram (
		.clk_a_i(clk), .addr_a_i(d_addr[13:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
		.wdata_a_i(ram_wdata), .q_a_o(ram_q),
		.clk_b_i(clk), .addr_b_i(12'd0), .wren_b_i(1'b0), .byteena_b_i(4'd0),
		.wdata_b_i(32'd0), .q_b_o());

	// +romhex replaces the ROM before the core is released.
	initial begin
		@(posedge clk);
		if (romhex != "") begin
			foreach (rom.mem_q[i]) rom.mem_q[i] = 32'd0;
			$readmemh(romhex, rom.mem_q);
		end
	end

	// Assets: the aligned word, answered in W; +await adds random waits.
	always_comb begin
		int o;
		o = a_base + int'({w_addr[23:2], 2'b00});
		asset_q = {img[o + 3], img[o + 2], img[o + 1], img[o]};
	end
	always @(posedge clk) begin
		asset_wait <= await_pct > 0 && $urandom_range(99) < await_pct;
		freeze <= throttle > 0 && $urandom_range(99) < throttle;
	end

	// ---- streams for the scoreboard ---------------------------------------------
	assign pr_wait  = reg_sel && !reg_write && !pr_avail;
	assign pr_valid = reg_sel && !reg_write && pr_avail;
	assign pr_addr  = reg_addr;
	assign pw_valid = reg_sel && reg_write;
	assign pw_addr  = reg_addr;
	assign pw_data  = reg_wdata;
	assign st_valid = ram_we;
	assign st_addr  = {d_addr[31:2], 2'b00};
	assign st_strb  = ram_be;
	assign st_data  = ram_wdata;

	logic was_halted = 0;
	always @(posedge clk) begin
		if (!rst && rt_w_we) nloads++;
		if (!rst && halted && !was_halted)
			$display("bup_cpu halted: code %0d, pc %08x", halt_code, halt_pc);
		was_halted <= halted;
	end
endmodule
