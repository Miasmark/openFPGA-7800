//------------------------------------------------------------------------------
// DARIA's core alone (src/fpga/core/bupchip/bup_cpu.sv with THUMB 1, MODES 1,
// CODE_AW 12: the 16 KB ROM) on the memories ../../s1/tb_s1.sv gives ARIA,
// for the Thumb halt tests (halt_thumb.py, run_halts.sh):
//
//   - ROM: cache_ram_dp, 4,096 words, +romhex; port A fetches, port B data
//   - RAM: cache_ram_tdp_dc_be, 4,096 words, port A
//   - bupchip_peripheral, unmodified (PCM_DEPTH 4,096; nothing pops it)
//   - assets: the ARSC block of the .a78 (offset 128 + the header's ROM size
//     onwards) as a behavioural memory that answers in W
//
// The program runs until the FAULT register (0xE000901C) is written, the
// core halts, or +maxcyc. The last line is for scripts:
//   result: halted=H code=C pc=P fault=F retired=N last=L t=T cunk=U
// with P the halt PC, N the instructions retired, L the PC of the last one
// retired (ffffffff if none), T the T bit and U c_unk at the end.
//
//   +romhex=FILE    ROM image ($readmemh), required
//   +rom=FILE       .a78 image (default: none, so no assets)
//   +arm_only=1     the BupChip profile: stay in ARM state, BX to odd halts 3
//   +throttle=P     freeze P% of clocks at random (the debug throttle)
//   +await=P        asset loads wait at random, P% of their W clocks
//   +seed=S         for +throttle and +await (default 1)
//   +maxcyc=N       stop after N clocks (default 200,000)
//
// Built with -DBUP_SIM_LATE_RF (LATE_RF=1 in build_tb.sh), register-file
// writes land a clock late (bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_thumb;
	logic clk = 0;
	always #17460 clk = ~clk;

	logic        rst = 1, freeze = 0, arm_only = 0;
	wire  [11:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, reg_rdata, halt_pc;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, reg_sel, reg_write, halted, w_wait;
	logic [31:0] asset_q;
	wire         rt_start, rt_valid, rt_e_we, rt_w_we, rt_t, rt_cunk;
	wire  [31:0] rt_pc, rt_insn, rt_e_data, rt_w_data;
	wire   [3:0] rt_nzcv, rt_e_idx, rt_w_idx;
	wire   [4:0] rt_mode;
	int          a_base = 0, a_size = 0;

	bup_cpu #(.MODES(1'b1), .THUMB(1'b1), .CODE_AW(12)) cpu (
		.clk, .rst, .freeze, .w_wait, .arm_only,
		.prof26(1'b0), .img_size(20'd0), .ram32(1'b0), .call_go(1'b0), .clr_wd(32'd0), .clr_pc(32'd0),
		.clr_e(), .parked(), .returned(), .ro_valid(), .ro_idx(), .ro_data(),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size(24'(a_size)), .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc,
		.rt_start, .rt_valid, .rt_pc, .rt_insn, .rt_nzcv, .rt_mode, .rt_t, .rt_cunk,
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

	// ---- assets ---------------------------------------------------------------
	logic [7:0] img [0:4194303];
	int         img_n = 0, await_pct = 0, throttle = 0, seed = 1;
	logic       a_rand = 0;
	always_comb begin
		int o;
		o = a_base + int'({w_addr[23:2], 2'b00});
		asset_q = {img[o + 3], img[o + 2], img[o + 1], img[o]};
	end
	assign w_wait = w_asset && a_rand;
	always @(posedge clk) begin
		a_rand <= await_pct > 0 && $urandom_range(99) < await_pct;
		freeze <= throttle > 0 && $urandom_range(99) < throttle;
	end

	// ---- peripheral ----------------------------------------------------------------
	wire        pcm_available, pcm_enabled, muted;
	wire [31:0] pcm_frame;
	wire  [7:0] fault_code;
	bupchip_peripheral #(.CMD_DEPTH(8), .PCM_DEPTH(4096)) per (
		.clk, .reset(rst), .cmd_valid(1'b0), .cmd_data(8'd0),
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.pcm_pop(1'b0), .pcm_frame, .pcm_available, .pcm_enabled, .muted, .fault_code);

	// ---- what happened -------------------------------------------------------------
	longint      cyc = 0, nret = 0, fault_ret = -1;
	logic        fault_seen = 0;
	logic  [7:0] fault_val = 0;
	logic [31:0] last_pc = 32'hffffffff;
	always @(posedge clk) if (!rst) begin
		cyc++;
		if (rt_valid) begin
			nret++;
			last_pc = rt_pc;
		end
		if (reg_sel && reg_write && reg_addr == 8'h1c && !fault_seen) begin
			fault_seen = 1;
			fault_val = reg_wdata[7:0];
			fault_ret = nret;
		end
	end

	initial begin
		string  rom_file = "", romhex = "";
		longint maxcyc = 200000;
		int     ao = 0;
		void'($value$plusargs("rom=%s", rom_file));
		void'($value$plusargs("romhex=%s", romhex));
		void'($value$plusargs("arm_only=%d", ao));
		void'($value$plusargs("throttle=%d", throttle));
		void'($value$plusargs("await=%d", await_pct));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("maxcyc=%d", maxcyc));
		void'($urandom(seed));
		arm_only = ao != 0;
		if (romhex == "") $fatal(1, "+romhex=FILE is required");
		if (rom_file != "") begin
			int fd;
			fd = $fopen(rom_file, "rb");
			if (fd == 0) $fatal(1, "cannot open %s", rom_file);
			img_n = $fread(img, fd);
			$fclose(fd);
			a_base = 128 + {img[49], img[50], img[51], img[52]};
			a_size = img_n > a_base ? img_n - a_base : 0;
		end
		@(posedge clk);
		foreach (rom.mem_q[i]) rom.mem_q[i] = 32'd0;
		$readmemh(romhex, rom.mem_q);
		repeat (8) @(posedge clk);
		rst = 0;
		while (!fault_seen && !halted && cyc < maxcyc) @(posedge clk);
		repeat (4) @(posedge clk);
		$display("result: halted=%0d code=%0d pc=%08x fault=%02x retired=%0d last=%08x t=%0d cunk=%0d",
			halted, halt_code, halt_pc, fault_seen ? fault_val : 8'h00,
			fault_seen ? fault_ret + 1 : nret, last_pc, cpu.ctl[5], cpu.c_unk);
		$finish;
	end
endmodule
