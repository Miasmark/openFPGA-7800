// Smoke/perf testbench for the bup_cpu sketch: real CoreTone ROM, real
// bupchip_peripheral (8 / 1024 with the watermark remap), the ARSC block of
// the +rom image (Rikki & Vikki, never committed), 48 kHz drain at 28.636 MHz.
// Logs every PCM push to pushes.bin for comparison with the Python model.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_cpu;
	localparam int PCM_DEPTH = 1024;
	localparam int POP_DIV = 597;           // 28.636 MHz / 48 kHz = 596.6
	logic clk = 0, rst = 1, ce = 1;
	always #17.46 clk = ~clk;

	logic        eb_valid, eb_we, eb_ack, halted, retire;
	logic [31:0] eb_addr, eb_wdata, eb_rdata, retire_pc, retire_ir;
	logic [1:0]  eb_size;

	bup_cpu #(.ROM_HEX(`ROMHEX)) cpu (.*);

	// ------------------------------------------------ asset window (behavioural)
	byte unsigned asset [0:4*1024*1024-1];
	int asset_len;
	int asset_lat, alat_cnt;
	wire is_mmio  = eb_addr[31:28] == 4'hE;
	wire is_asset = eb_addr[31:28] == 4'h0 && eb_addr[25];
	logic [31:0] arw;
	always_comb begin
		int o; o = eb_addr[21:0] & ~32'd3;
		arw = {asset[o+3], asset[o+2], asset[o+1], asset[o]};
	end

	// ------------------------------------------------ peripheral (+ watermark remap)
	logic        reg_sel;
	logic [31:0] reg_rdata, reg_wdata_eff;
	logic        cmd_valid = 0; logic [7:0] cmd_data = 0;
	logic        pcm_pop, pcm_available, pcm_enabled, muted;
	logic [31:0] pcm_frame; logic [7:0] fault_code;
	assign reg_sel = eb_valid && is_mmio && ce;
	always_comb begin
		reg_wdata_eff = eb_wdata;
		if (eb_addr[7:0] == 8'h18) begin
			int w; w = (eb_wdata >> 16) & 32'h1FFF;
			w = w - (4096 - PCM_DEPTH); if (w < 0) w = 0;
			reg_wdata_eff[28:16] = w[12:0];
		end
	end
	bupchip_peripheral #(.CMD_DEPTH(8), .PCM_DEPTH(PCM_DEPTH)) per (
		.clk(clk), .reset(rst), .cmd_valid(cmd_valid), .cmd_data(cmd_data),
		.reg_sel(reg_sel), .reg_addr(eb_addr[7:0]), .reg_write(eb_we),
		.reg_wdata(reg_wdata_eff), .reg_rdata(reg_rdata),
		.pcm_pop(pcm_pop), .pcm_frame(pcm_frame), .pcm_available(pcm_available),
		.pcm_enabled(pcm_enabled), .muted(muted), .fault_code(fault_code));

	always_ff @(posedge clk) begin
		if (!eb_valid || !is_asset) alat_cnt <= 0;
		else if (!eb_ack) alat_cnt <= alat_cnt + 1;
	end
	// stream buffer + behavioural PSRAM halfword port (TPS clocks per read)
	int use_sb, tps;
	logic sb_ack; logic [31:0] sb_rdata;
	logic hw_req, hw_ready, hw_valid; logic [20:0] hw_addr; logic [31:0] hw_data;
	int ps_cnt = 0; logic [20:0] ps_a; longint ps_reads = 0, ps_busy = 0, ast_wait = 0, ast_partial = 0, ast_acc = 0, ast_miss = 0;
	assign hw_ready = ps_cnt == 0 || ps_cnt == 1;   // back-to-back
	always_ff @(posedge clk) begin
		hw_valid <= 1'b0;
		if (ps_cnt != 0) begin
			ps_busy <= ps_busy + 1;
			if (ps_cnt == 1) begin hw_valid <= 1'b1; hw_data <= `WIDE ? {asset[{ps_a[20:1], 2'd3}], asset[{ps_a[20:1], 2'd2}], asset[{ps_a[20:1], 2'd1}], asset[{ps_a[20:1], 2'd0}]} : {16'b0, asset[{ps_a, 1'b1}], asset[{ps_a, 1'b0}]}; end
			ps_cnt <= ps_cnt - 1;
		end
		if (hw_req && hw_ready) begin ps_cnt <= tps; ps_a <= hw_addr; ps_reads <= ps_reads + 1; end
		if (eb_valid && is_asset && !eb_ack) begin
			ast_wait <= ast_wait + 1;
			if (sb.hit) ast_partial <= ast_partial + 1;
		end
		if (eb_valid && is_asset && cpu.st == 1 && !$past(eb_valid)) begin
			ast_acc <= ast_acc + 1;
			if (!(sb.hit)) ast_miss <= ast_miss + 1;
		end
	end
	bup_asset #(.WIDE(`WIDE)) sb (.clk(clk), .rst(rst), .ce(ce), .asset_size(22'(asset_len)),
		.req(eb_valid && is_asset && use_sb != 0), .addr(eb_addr[21:0]), .size(eb_size), .ack(sb_ack), .rdata(sb_rdata),
		.hw_req(hw_req), .hw_addr(hw_addr), .hw_ready(hw_ready), .hw_valid(hw_valid), .hw_data(hw_data));
	assign eb_ack   = eb_valid && (is_mmio || (is_asset && (use_sb != 0 ? sb_ack : alat_cnt >= asset_lat)));
	assign eb_rdata = is_mmio ? reg_rdata : (use_sb != 0 ? sb_rdata : arw);

	// ------------------------------------------------ 48 kHz drain
	int popc = 0;
	assign pcm_pop = pcm_enabled && popc == POP_DIV - 1;
	always_ff @(posedge clk) popc <= (popc == POP_DIV - 1) ? 0 : popc + 1;

	// ------------------------------------------------ stats
	longint cyc = 0, busy = 0, instr = 0, pushes = 0, underflow_pops = 0;
	longint b_cyc = 0, b_ins = 0, b_max = 0, b_n = 0, minlev = 99999;
	logic idle_now = 1;
	int fd, bfd, song, secs;
	longint frames_target;
	int unsigned retired_pc_last = 0;
	always_ff @(posedge clk) if (!rst) begin
		cyc <= cyc + 1;
		if (retire) begin
			idle_now <= retire_pc >= 32'h178 && retire_pc < 32'h190;
		end
		if (pcm_enabled && !idle_now) begin
			busy <= busy + 1;
			if (retire) instr <= instr + 1;
		end
		if (reg_sel && eb_we && eb_addr[7:0] == 8'h10) begin
			$fwrite(fd, "%c%c%c%c", eb_wdata[7:0], eb_wdata[15:8], eb_wdata[23:16], eb_wdata[31:24]);
			pushes <= pushes + 1;
		end
		if (pcm_pop && !pcm_available) underflow_pops <= underflow_pops + 1;
		if (pcm_enabled && per.pcm_level < minlev && pushes > 4000) minlev <= per.pcm_level;
	end
	// batch timing: from leaving the poll (retire of 0x190) to returning (retire of 0x178)
	logic in_batch = 0; longint bstart = 0, bcount = 0;
	always_ff @(posedge clk) if (!rst && retire) begin
		if (retire_pc == 32'h190 && !in_batch) begin in_batch <= 1; bstart <= cyc; bcount <= 0; end
		else if (in_batch) begin
			bcount <= bcount + 1;
			if (retire_pc == 32'h178) begin
				in_batch <= 0;
				if (cyc - bstart > b_max) b_max <= cyc - bstart;
				$fwrite(bfd, "%0d %0d\n", cyc - bstart, bcount);
				b_cyc <= b_cyc + (cyc - bstart); b_ins <= b_ins + bcount; b_n <= b_n + 1;
			end
		end
	end

	initial begin
		int f, n, dsz; byte unsigned hdr [0:127]; string romf;
		if (!$value$plusargs("song=%d", song)) song = 13;
		if (!$value$plusargs("secs=%d", secs)) secs = 1;
		if (!$value$plusargs("alat=%d", asset_lat)) asset_lat = 2;
		if (!$value$plusargs("sb=%d", use_sb)) use_sb = 0;
		if (!$value$plusargs("tps=%d", tps)) tps = 5;
		if (!$value$plusargs("rom=%s", romf)) romf = "game.a78";
		f = $fopen(romf, "rb");
		n = $fread(hdr, f, 0, 128);
		dsz = {hdr[49], hdr[50], hdr[51], hdr[52]};
		void'($fseek(f, 128 + dsz, 0));
		asset_len = $fread(asset, f);
		$fclose(f);
		$display("asset bytes %0d (declared rom %0d)", asset_len, dsz);
		fd = $fopen("pushes.bin", "wb");
		bfd = $fopen("batches.txt", "w");
		repeat (4) @(posedge clk);
		rst = 0;
		wait (pcm_enabled);
		$display("PCM enabled at cycle %0d (%.3f ms), fault=%02x halted=%0d", cyc, cyc * 34.92e-6, fault_code, halted);
		@(posedge clk); cmd_valid <= 1; cmd_data <= 8'h80 | song[7:0];
		@(posedge clk); cmd_valid <= 0;
		busy = 0; instr = 0; ast_wait = 0; ast_partial = 0; ast_acc = 0; ast_miss = 0; ps_reads = 0; ps_busy = 0; b_cyc = 0; b_ins = 0; b_n = 0; b_max = 0;
		frames_target = 48000 * secs;
		begin longint c0; c0 = cyc;
		while (cyc - c0 < frames_target * POP_DIV && !halted) @(posedge clk);
		$display("song %0d, %0d s @28.636 MHz: cycles %0d busy %0d (%.1f%%) instr(non-idle) %0d CPI %.3f -> %.2f MHz needed at 100%% busy",
			song, secs, cyc - c0, busy, 100.0 * busy / (cyc - c0), instr, 1.0 * busy / instr, 28.636 * busy / (cyc - c0));
		end
		$display("batches %0d avg %.0f clk (%.0f instr, CPI %.3f) worst %0d clk = %.2f MHz-eq at 240 Hz",
			b_n, 1.0 * b_cyc / b_n, 1.0 * b_ins / b_n, 1.0 * b_cyc / b_ins, b_max, b_max * 240.0 / 1e6);
		$display("asset: accesses %0d misses %0d; stall cycles in W %0d (%.3f%% of busy; %0d waiting on a partly filled line), PSRAM reads %0d, PSRAM busy %.1f%%", ast_acc, ast_miss, ast_wait, 100.0 * ast_wait / busy, ast_partial, ps_reads, 100.0 * ps_busy / cyc);
		$display("pushes %0d, underflow pops %0d, sticky under/over %0d/%0d, min FIFO level %0d, fault %02x, halted %0d pc %08x",
			pushes, underflow_pops, per.pcm_underflow, per.pcm_overflow, minlev, fault_code, halted, retire_pc);
		$fclose(fd);
		$finish;
	end
	int ntrace = 0, tfd; longint maxcyc;
	initial begin
		if (!$value$plusargs("trace=%d", ntrace)) ntrace = 0;
		if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 400000000;
		tfd = $fopen("cpu.trace", "w");
	end
	longint nret = 0;
	always_ff @(posedge clk) if (!rst) begin
		if (retire) begin
			nret <= nret + 1;
			if (nret < ntrace) begin
				$fwrite(tfd, "%0d %08x %08x", nret, retire_pc, retire_ir);
				for (int k = 0; k < 15; k++) $fwrite(tfd, " %08x", cpu.rf[k]);
				$fwrite(tfd, " %0d%0d%0d%0d\n", cpu.N, cpu.Z, cpu.C, cpu.V);
			end
		end
		if (cyc == maxcyc) begin $display("maxcyc reached, nret %0d pc %08x halted %0d pcm_en %0d", nret, retire_pc, halted, pcm_enabled); $fflush(); $finish; end
	end
	always @(posedge halted) $display("HALT at cycle %0d, last retired pc %08x ir %08x, current pc %08x ir %08x",
		cyc, retire_pc, retire_ir, {cpu.pc, 2'b00}, cpu.ir);
endmodule
