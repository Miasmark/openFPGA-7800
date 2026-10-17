//------------------------------------------------------------------------------
// The S1 core (src/fpga/core/bupchip/bup_cpu.sv) running at the S1 clock,
// 28.636 MHz (2 x clk_sys), with the memories and peripheral the Pocket
// build will give it:
//
//   - ROM: cache_ram_dp, 4,096 words, the stock bupchip.hex (or +romhex);
//     port A fetches, port B serves data
//   - RAM: cache_ram_tdp_dc_be, 4,096 words, port A
//   - bupchip_peripheral, unmodified: CMD_DEPTH 8 and PCM_DEPTH 1,024 with
//     the watermark remap of docs/BUPCHIP_CORE.md, "PCM and command FIFOs"
//     (build with -DPCM_DEPTH=4096 for the stock depth; the remap is then
//     the identity)
//   - assets: the ARSC block of the .a78 (offset 128 + the header's ROM
//     size onwards) as a behavioural memory that answers in W. The asset
//     cache and the PSRAM are step 4; +alat and +await add stalls.
//   - the 48 kHz pop from a clk_74a accumulator (74.25 MHz x 8 / 12,375),
//     crossed into clk_arm with a toggle, as the design does it
//
// Song mode (the default): boot, send $80|song once the firmware has
// enabled the PCM FIFO, then play +secs seconds (48,000 pops each). Writes
// every frame the firmware pushes, from power-up, to +out (the "command"
// line gives how many came before the song's first), and one line
// "clocks instructions" per batch to +batches. Every clock is charged to the
// instruction that retires at the end of it, or is still in progress, and
// the instructions retired at 0x178-0x18c (the poll loop) are idle: idle is
// decided by the retired PC, not the fetched one. A batch runs from the
// retire of 0x190 (bl render) to the retire of 0x1dc after a render or
// 0x274 after a silent batch, inclusive.
//
// Program mode (+romhex without +song): run until the FAULT register
// (0xE000901C) is written, the core halts, or +maxcyc; for ISA-style and
// halt tests. The last line is "result: ..." for scripts.
//
//   +rom=FILE       .a78 image (default: none, so no assets)
//   +romhex=FILE    ROM image ($readmemh) instead of bupchip.hex
//   +song=N         song mode, command $80|N (default 13 when no +romhex)
//   +secs=S         seconds to play (default 4)
//   +out=FILE       pushed frames, s16le stereo (default s1.pcm)
//   +batches=FILE   per-batch clocks and instructions (default: none)
//   +throttle=P     freeze P% of clocks at random (the debug throttle)
//   +alat=N         every asset load waits N clocks in W
//   +await=P        asset loads also wait at random, P% of their W clocks
//   +rehold=CLK     CLK clocks into the song, hold the core (and the
//                   peripheral) for 64 clocks, then boot and play again
//   +seed=S         for +throttle and +await (default 1)
//   +maxcyc=N       stop after N clocks (default 400,000,000)
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
`ifndef PCM_DEPTH
`define PCM_DEPTH 1024
`endif
module tb_s1;
	localparam int  PCM_DEPTH = `PCM_DEPTH;
	localparam real ARM_MHZ = 28.636364;

	logic clk = 0, clk_74a = 0;
	always #17460 clk = ~clk;			// clk_arm, 2 x clk_sys
	always #6734  clk_74a = ~clk_74a;		// 74.25 MHz

	// ---- the core and its memories ------------------------------------------
	logic        rst = 1, freeze = 0;
	wire  [11:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, reg_rdata, halt_pc;
	wire   [3:0] ram_be, halt_code;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, reg_sel, reg_write, halted, w_wait;
	logic [31:0] asset_q;
	wire         rt_start, rt_valid, rt_e_we, rt_w_we;
	wire  [31:0] rt_pc, rt_insn, rt_e_data, rt_w_data;
	wire   [3:0] rt_nzcv, rt_e_idx, rt_w_idx;
	int          a_base = 0, a_size = 0;

`ifdef BUP_THUMB
	bup_cpu #(.MODES(1'b1), .THUMB(1'b1)) cpu (	// DARIA's core in the BupChip profile
`else
	bup_cpu cpu (
`endif
		.clk, .rst, .freeze, .w_wait, .arm_only(1'b1),
		.prof26(1'b0), .img_size(20'd0), .ram32(1'b0), .call_go(1'b0), .clr_wd(32'd0), .clr_pc(32'd0),
		.clr_e(), .parked(), .returned(), .ro_valid(), .ro_idx(), .ro_data(),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size(24'(a_size)), .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc,
		.rt_start, .rt_valid, .rt_pc, .rt_insn, .rt_nzcv,
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
	int         img_n = 0, alat = 0, await_pct = 0, throttle = 0, a_cnt = 0;
	logic       a_rand = 0;
	always_comb begin
		int o;
		o = a_base + int'({w_addr[23:2], 2'b00});
		asset_q = {img[o + 3], img[o + 2], img[o + 1], img[o]};
	end
	assign w_wait = w_asset && (a_cnt < alat || a_rand);
	always @(posedge clk) begin
		a_cnt <= (w_asset && w_wait) ? a_cnt + 1 : 0;
		a_rand <= await_pct > 0 && $urandom_range(99) < await_pct;
		freeze <= throttle > 0 && $urandom_range(99) < throttle;
	end

	// ---- peripheral, with the watermark remap -----------------------------------
	logic        cmd_valid = 0;
	logic  [7:0] cmd_data = 0;
	logic [31:0] reg_wdata_eff;
	wire         pcm_pop, pcm_available, pcm_enabled, muted;
	wire  [31:0] pcm_frame;
	wire   [7:0] fault_code;

	// On writes to 0x18 the watermark W becomes clamp(W - (4096 - D), 0, D), so
	// the firmware's D - W = 200 holds for a D-deep FIFO.
	always_comb begin
		int w;
		reg_wdata_eff = reg_wdata;
		if (reg_write && reg_addr == 8'h18) begin
			w = int'(reg_wdata[28:16]) - (4096 - PCM_DEPTH);
			if (w < 0) w = 0;
			if (w > PCM_DEPTH) w = PCM_DEPTH;
			reg_wdata_eff[28:16] = 13'(w);
		end
	end

	bupchip_peripheral #(.CMD_DEPTH(8), .PCM_DEPTH(PCM_DEPTH)) per (
		.clk, .reset(rst), .cmd_valid, .cmd_data,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata(reg_wdata_eff), .reg_rdata,
		.pcm_pop, .pcm_frame, .pcm_available, .pcm_enabled, .muted, .fault_code);

	// 48 kHz: 74.25 MHz x 8 / 12,375, a toggle, three clk_arm flops.
	logic [13:0] acc74 = 0;
	logic        tog74 = 0;
	logic  [2:0] tsync = 0;
	always @(posedge clk_74a)
		if (acc74 >= 14'd12367) begin acc74 <= acc74 + 14'd8 - 14'd12375; tog74 <= ~tog74; end
		else acc74 <= acc74 + 14'd8;
	always @(posedge clk) tsync <= {tsync[1:0], tog74};
	assign pcm_pop = (tsync[2] ^ tsync[1]) && pcm_enabled && !rst;

	// ---- measurement --------------------------------------------------------------
	longint cyc = 0, charge = 0, nret = 0;
	longint busy = 0, work = 0, mclk = 0, pops = 0, under = 0, pushes = 0, mpushes = 0;
	longint bclk = 0, bins_n = 0, nbatch = 0, cmd_cyc = -1, song_frame = -1, take_cyc = -1;
	int     minlev = 1 << 30, pcm_fd = 0, bat_fd = 0;
	logic   measuring = 0, in_batch = 0, check_clear = 1, fault_seen = 0, clear_ok = 1;
	logic [7:0] fault_val = 0;
	longint fault_ret = -1;

	always @(posedge clk) if (!rst) begin
		cyc++;
		charge++;
		if (rt_start && check_clear) begin
			// The first instruction after a release must see r0-r14 = 0, as the
			// core reads them: last clock's write from the bypass, the rest
			// from the array.
			for (int k = 0; k < 15; k++) begin
				logic [31:0] v;
				v = cpu.byp_we && cpu.byp_idx == 4'(k) ? cpu.byp_data : cpu.rf[k];
				if (v !== 32'd0) begin
					clear_ok = 0;
					$display("register clear: r%0d = %08x at the first instruction", k, v);
				end
			end
			check_clear = 0;
		end
		if (rt_valid) begin
			nret++;
			if (measuring) begin
				if (!(rt_pc >= 32'h178 && rt_pc <= 32'h18c)) begin
					busy += charge;
					work++;
				end
				if (rt_pc == 32'h190 && !in_batch) begin
					in_batch = 1; bclk = 0; bins_n = 0;
				end
				if (in_batch) begin
					bclk += charge;
					bins_n++;
					if (rt_pc == 32'h1dc || rt_pc == 32'h274) begin
						in_batch = 0;
						nbatch++;
						if (bat_fd != 0) $fdisplay(bat_fd, "%0d %0d", bclk, bins_n);
					end
				end
			end
			charge = 0;
		end
		if (measuring) begin
			mclk++;
			if (pcm_enabled && int'(per.pcm_level) < minlev) minlev = int'(per.pcm_level);
		end
		if (pcm_pop) begin
			pops++;
			if (!pcm_available) under++;
		end
		if (reg_sel && reg_write && reg_addr == 8'h10) begin
			pushes++;
			if (measuring) mpushes++;
			if (pcm_fd != 0) $fwrite(pcm_fd, "%c%c%c%c", reg_wdata[7:0], reg_wdata[15:8],
				reg_wdata[23:16], reg_wdata[31:24]);
		end
		if (per.cmd_pop && song_frame < 0) begin	// the firmware takes the command
			song_frame = pushes;
			take_cyc = cyc;
		end
		if (reg_sel && reg_write && reg_addr == 8'h1c && !fault_seen) begin
			fault_seen = 1;
			fault_val = reg_wdata[7:0];
			fault_ret = nret;
		end
	end

	// ---- run -------------------------------------------------------------------------
	string  rom_file = "", romhex = "", out = "s1.pcm", bat_file = "";
	int     song = -1, secs = 4, rehold = 0, seed = 1;
	longint maxcyc = 400000000;

	task automatic release_core();
		repeat (8) @(posedge clk);
		check_clear = 1;
		rst = 0;
	endtask

	task automatic boot_and_command();
		while (!pcm_enabled && !halted && cyc < maxcyc) @(posedge clk);
		$display("booted at clock %0d (%.3f ms): fault %02x, PCM enabled %0d, %0d frames pushed",
			cyc, cyc / (ARM_MHZ * 1000.0), fault_code, pcm_enabled, pushes);
		song_frame = -1;
		@(posedge clk) begin cmd_valid <= 1; cmd_data <= 8'h80 | 8'(song[4:0]); end
		@(posedge clk) cmd_valid <= 0;
		cmd_cyc = cyc;
	endtask

	initial begin
		void'($value$plusargs("rom=%s", rom_file));
		void'($value$plusargs("romhex=%s", romhex));
		void'($value$plusargs("song=%d", song));
		void'($value$plusargs("secs=%d", secs));
		void'($value$plusargs("out=%s", out));
		void'($value$plusargs("batches=%s", bat_file));
		void'($value$plusargs("throttle=%d", throttle));
		void'($value$plusargs("alat=%d", alat));
		void'($value$plusargs("await=%d", await_pct));
		void'($value$plusargs("rehold=%d", rehold));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("maxcyc=%d", maxcyc));
		void'($urandom(seed));
		if (song < 0 && romhex == "") song = 13;
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
		if (romhex != "") begin
			foreach (rom.mem_q[i]) rom.mem_q[i] = 32'd0;
			$readmemh(romhex, rom.mem_q);
		end
		$display("S1 at %.3f MHz, PCM FIFO %0d; image %s, %0d bytes of assets; ROM %s; throttle %0d%%, asset wait %0d + %0d%%",
			ARM_MHZ, PCM_DEPTH, rom_file == "" ? "(none)" : rom_file, a_size,
			romhex == "" ? `ROMHEX : romhex, throttle, alat, await_pct);

		if (song < 0) begin
			// Program mode.
			release_core();
			while (!fault_seen && !halted && cyc < maxcyc) @(posedge clk);
			repeat (4) @(posedge clk);
			$display("result: halted=%0d code=%0d pc=%08x fault=%02x retired=%0d clocks=%0d clear=%0d",
				halted, halt_code, halt_pc, fault_seen ? fault_val : 8'h00,
				fault_seen ? fault_ret + 1 : nret, cyc, clear_ok);
			$finish;
		end else begin
			play();
			$finish;
		end
	end

	// Song mode.
	task automatic play();
		pcm_fd = $fopen(out, "wb");
		if (bat_file != "") bat_fd = $fopen(bat_file, "w");
		release_core();
		if (rehold > 0) begin
			boot_and_command();
			repeat (rehold) @(posedge clk);
			$display("hold at clock %0d for 64 clocks", cyc);
			rst = 1;
			repeat (64) @(posedge clk);
			$fclose(pcm_fd);
			pcm_fd = $fopen(out, "wb");		// keep the second boot's frames only
			pushes = 0;
			pops = 0;
			under = 0;
			rst = 0;
			check_clear = 1;
		end
		boot_and_command();
		$display("song %0d (command $%02x)", song, 8'h80 | song[4:0]);
		measuring = 1;
		pops = 0;
		under = 0;
		while (pops < 48000 * secs && !halted && cyc < maxcyc) @(posedge clk);
		measuring = 0;
		$fclose(pcm_fd);
		if (bat_fd != 0) $fclose(bat_fd);
		$display("");
		$display("clocks     %0d in %0d s of pops (%.0f per second)", mclk, secs, 1.0 * mclk / secs);
		$display("busy       %0d clocks, %.2f%% of %.3f MHz; %.2f MHz needed at 100%% busy",
			busy, 100.0 * busy / mclk, ARM_MHZ, busy / (secs * 1.0e6));
		$display("work       %0d instructions, %.2f MIPS; CPI %.4f", work, work / (secs * 1.0e6), 1.0 * busy / work);
		$display("batches    %0d", nbatch);
		$display("command    taken by the firmware %0d clocks after it was sent, with %0d frames pushed",
			take_cyc - cmd_cyc, song_frame);
		$display("audio      %0d pops, %0d underruns; %0d frames pushed while playing, %0d in all; overflow %0d",
			pops, under, mpushes, pushes, per.pcm_overflow);
		$display("fifo       lowest level %0d of %0d while playing", minlev, PCM_DEPTH);
		$display("status     fault %02x, halted %0d (code %0d, pc %08x), register clear %0s",
			fault_code, halted, halt_code, halt_pc, clear_ok ? "ok" : "FAILED");
		$display("result: busy=%0d work=%0d cpi=%.4f mips=%.3f under=%0d over=%0d minlev=%0d fault=%02x halted=%0d clear=%0d",
			busy, work, 1.0 * busy / work, work / (secs * 1.0e6), under, per.pcm_overflow, minlev,
			fault_code, halted, clear_ok);
	endtask
endmodule
