//------------------------------------------------------------------------------
// DARIA's core alone in the 2600 profile (src/fpga/core/bupchip/bup_cpu.sv,
// THUMB 1, CODE_AW 15): the memory map and the call port (docs/DARIA_CORE.md,
// "The memory system", 4 and 5), for the directed tests of run_call.py.
//
//   - window: cache_ram_dp, 32,768 words, the first 128 KB of +img; port A
//     fetches, port B data (in the BupChip profile, +prof26=0, the same RAM
//     stands for the 16 KB firmware ROM)
//   - cart RAM: cache_ram_tdp_dc_be, 8,192 words (32 KB), port A
//   - the image beyond the window: a behavioural memory on the asset port,
//     w_wait at random (+await)
//   - MMIO: MAMCR at 0xE01F_C000 read back, everything else 0 (the wrapper's
//     daria_mmio.sv is tested on its own)
//
// Calls. +calls=N launches N calls in turn, each when the core is parked:
// call_go for a clock, then clr_wd follows clr_e from the entries of
// docs/DARIA_CORE.md 5.1 (r13 the stack, r14 0xF000_0000, FIQ r8-r10 the
// seeds, r11-r13 the frequencies: call k's stack is +stack - 0x100 k, and
// its seeds and frequencies +seed/+freq + 0x100 i + k for the i-th).
// Each readout is printed. A call that has not returned after +maxcyc
// clocks, or a halt, ends the run.
//
// The last lines are for run_call.py:
//   ro: K r8 r9 r10 r11 r12 r13     each call's readout (hex)
//   ram: A V                        +dump=N words of cart RAM from +dump_base
//   result: calls=C halted=H code=X pc=P parked=K
//
//   +img=FILE       the image (binary), required
//   +img_size=N     bytes (default: the file's size)
//   +prof26=0       the BupChip profile (arm_only, no calls: runs from 0)
//   +ram32=1        32 KB of cart RAM (default 8 KB)
//   +entry=H        the entry, bit 0 the T bit (default 0x21: Thumb at 0x20)
//   +stack=H +seed=H +freq=H   (defaults 0x40001F00, 0x1000, 0x2000)
//   +dump_base=H    (default 0x40000000)
//   +calls=N        (default 1)
//   +await=P +throttle=P +rseed=S   asset waits and the debug throttle, P%
//   +dump=N         cart RAM words to print (default 64)
//   +maxcyc=N       per call (default 200,000)
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_call;
	logic clk = 0;
	always #13095 clk = ~clk;		// 38.18 MHz

	logic        rst = 1, freeze = 0, prof26 = 1, ram32 = 0, call_go = 0;
	logic [19:0] img_size = 0;
	logic [31:0] clr_wd, clr_pc = 32'h21;
	wire  [14:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, halt_pc, ro_data;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire   [4:0] clr_e;
	wire   [2:0] ro_idx;
	wire         ram_we, w_asset, reg_sel, reg_write, halted, w_wait, parked, returned, ro_valid;
	logic [31:0] asset_q, reg_rdata;

	bup_cpu #(.MODES(1'b1), .THUMB(1'b1), .CODE_AW(15)) cpu (
		.clk, .rst, .freeze, .w_wait, .arm_only(!prof26),
		.prof26, .img_size, .ram32, .call_go, .clr_wd, .clr_pc,
		.clr_e, .parked, .returned, .ro_valid, .ro_idx, .ro_data,
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size(24'h4000), .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc,
		.rt_start(), .rt_valid(), .rt_pc(), .rt_insn(), .rt_nzcv(), .rt_mode(), .rt_t(), .rt_cunk(),
		.rt_e_we(), .rt_e_idx(), .rt_e_data(), .rt_w_we(), .rt_w_idx(), .rt_w_data());

	cache_ram_dp #(.ADDR_WIDTH(15), .DATA_WIDTH(32)) win (
		.clk_i(clk),
		.addr_a_i(rom_addr), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(rom_q),
		.addr_b_i(d_addr[16:2]), .wren_b_i(1'b0), .wdata_b_i(32'd0), .q_b_o(rom_dq));

	cache_ram_tdp_dc_be #(.ADDR_WIDTH(13), .DATA_WIDTH(32)) ram (
		.clk_a_i(clk), .addr_a_i(d_addr[14:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
		.wdata_a_i(ram_wdata), .q_a_o(ram_q),
		.clk_b_i(clk), .addr_b_i(13'd0), .wren_b_i(1'b0), .byteena_b_i(4'd0),
		.wdata_b_i(32'd0), .q_b_o());

	// ---- the image beyond the window ------------------------------------------
	logic [7:0] img [0:1048575];
	int         await_pct = 0, throttle = 0;
	logic       a_rand = 0;
	always_comb begin
		int o;
		o = int'({w_addr[19:2], 2'b00});
		asset_q = {img[o + 3], img[o + 2], img[o + 1], img[o]};
	end
	assign w_wait = w_asset && a_rand;
	always @(posedge clk) begin
		a_rand <= await_pct > 0 && $urandom_range(99) < await_pct;
		freeze <= throttle > 0 && $urandom_range(99) < throttle;
	end

	// ---- MMIO -------------------------------------------------------------------------
	logic [31:0] mamcr = 0;
	always_comb reg_rdata = (reg_sel && w_addr == 32'hE01F_C000) ? mamcr : 32'd0;
	always @(posedge clk)
		if (reg_sel && reg_write && w_addr == 32'hE01F_C000) begin
			logic [3:0] be;
			be = w_size == 2'd0 ? 4'b0001 : w_size == 2'd1 ? 4'b0011 : 4'b1111;
			for (int b = 0; b < 4; b++) if (be[b]) mamcr[b*8 +: 8] <= reg_wdata[b*8 +: 8];
		end

	// ---- the call port ------------------------------------------------------------
	logic [31:0] stack = 32'h4000_1F00, seed = 32'h1000, freq = 32'h2000, dump_base = 32'h4000_0000;
	int          k = 0;	// the call being launched
	always_comb begin
		case (clr_e)
			5'd13:   clr_wd = stack - 32'(k) * 32'h100;
			5'd14:   clr_wd = 32'hF000_0000;
			5'd16, 5'd17, 5'd18: clr_wd = seed + 32'(clr_e - 5'd16) * 32'h100 + k;
			5'd19, 5'd20, 5'd21: clr_wd = freq + 32'(clr_e - 5'd19) * 32'h100 + k;
			default: clr_wd = 32'd0;
		endcase
	end
	logic [31:0] ro [0:5];
	always @(posedge clk) if (ro_valid) ro[ro_idx] <= ro_data;

	initial begin
		string  img_file = "";
		int     n = 0, calls = 1, dump = 64, p26 = 1, r32 = 0, isz = -1, rseed = 1;
		longint maxcyc = 200000, c;
		void'($value$plusargs("img=%s", img_file));
		void'($value$plusargs("img_size=%d", isz));
		void'($value$plusargs("prof26=%d", p26));
		void'($value$plusargs("ram32=%d", r32));
		void'($value$plusargs("entry=%h", clr_pc));
		void'($value$plusargs("stack=%h", stack));
		void'($value$plusargs("seed=%h", seed));
		void'($value$plusargs("freq=%h", freq));
		void'($value$plusargs("calls=%d", calls));
		void'($value$plusargs("await=%d", await_pct));
		void'($value$plusargs("throttle=%d", throttle));
		void'($value$plusargs("rseed=%d", rseed));
		void'($value$plusargs("dump=%d", dump));
		void'($value$plusargs("dump_base=%h", dump_base));
		void'($value$plusargs("maxcyc=%d", maxcyc));
		void'($urandom(rseed));
		if (img_file == "") $fatal(1, "+img=FILE is required");
		begin
			int fd;
			foreach (img[i]) img[i] = 8'h00;
			fd = $fopen(img_file, "rb");
			if (fd == 0) $fatal(1, "cannot open %s", img_file);
			n = $fread(img, fd);
			$fclose(fd);
		end
		prof26 = p26 != 0;
		ram32 = r32 != 0;
		img_size = 20'(isz >= 0 ? isz : n);
		@(posedge clk);
		foreach (win.mem_q[i]) win.mem_q[i] = {img[4*i + 3], img[4*i + 2], img[4*i + 1], img[4*i]};
		foreach (ram.mem_q[i]) ram.mem_q[i] = 32'd0;
		repeat (8) @(posedge clk);
		rst = 0;
		if (!prof26) begin
			c = 0;
			while (!halted && c < maxcyc) begin @(posedge clk); c++; end
		end else
			for (k = 0; k < calls && !halted; k++) begin
				c = 0;
				while (!parked && !halted && c < maxcyc) begin @(posedge clk); c++; end
				if (!parked) break;
				call_go = 1;
				@(posedge clk);
				call_go = 0;
				c = 0;
				while (!returned && !halted && c < maxcyc) begin @(posedge clk); c++; end
				if (!returned) break;
				@(posedge clk);
				$display("ro: %0d %08x %08x %08x %08x %08x %08x", k, ro[0], ro[1], ro[2], ro[3], ro[4], ro[5]);
			end
		repeat (4) @(posedge clk);
		for (int i = 0; i < dump; i++)
			$display("ram: %08x %08x", dump_base + 4 * i, ram.mem_q[13'((dump_base - 32'h4000_0000) / 4 + i)]);
		$display("result: calls=%0d halted=%0d code=%0d pc=%08x parked=%0d", k, halted, halt_code, halt_pc, parked);
		$finish;
	end
endmodule
