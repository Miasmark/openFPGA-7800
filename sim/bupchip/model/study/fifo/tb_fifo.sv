// FIFO-sizing experiment: MiSTer arm_host + (modified) bupchip_subsystem with a
// synthetic ARSC (synth.a78 in the working directory; no command is sent).
// Reports boot, prefill and PCM FIFO level range with the real firmware.
// run_fifo.sh builds and runs it.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it (see ../README.md).
//
// SPDX-License-Identifier: MIT
`timescale 1ps/1ps
`ifndef PCMD
`define PCMD 4096
`endif
`ifndef MEASURE_FROM
`define MEASURE_FROM t_en > 0
`endif
`ifndef REMAPV
`define REMAPV 0
`endif
module tb_fifo;
	logic clk_sys = 0, clk_arm = 0;
	always #34920 clk_sys = ~clk_sys;
	always #6984  clk_arm = ~clk_arm;
	logic reset_arm = 1;
	logic load_start = 0, load_valid = 0, load_end = 0;
	logic [24:0] load_addr = 0;
	logic  [7:0] load_data = 0;
	logic cmd_valid = 0;
	logic [7:0] cmd_data = 0;
	wire load_wait, arm_hold;
	wire [24:0] asset_start;
	wire        mem_req, mem_write, mem_ready, mem_abort, mem_fetch, retire;
	wire [31:0] mem_addr, mem_wdata, mem_rdata;
	wire  [3:0] mem_wstrb;
	wire  [1:0] mem_size;
	wire [28:0] ddr_addr;
	wire [63:0] ddr_din;
	wire  [7:0] ddr_be, ddr_len;
	wire        ddr_req, ddr_rnw;
	logic       ddr_ack = 0, ddr_rvalid = 0;
	logic [63:0] ddr_dout = 0;
	wire [15:0] audio_l, audio_r;

	arm_host cpu (
		.clk_arm, .reset_arm(reset_arm || arm_hold), .ce(1'b1),
		.halt_req(1'b0), .halted(),
		.mem_req, .mem_ready, .mem_abort, .mem_addr, .mem_write, .mem_wdata, .mem_rdata,
		.mem_size, .mem_wstrb, .mem_seq(), .mem_fetch, .mem_privileged(), .mem_lock(),
		.retire, .state_req(1'b0), .state_write(1'b0), .state_index(6'd0),
		.state_wdata(32'd0), .state_rdata(), .state_ready(), .state_commit(1'b0));

	bupchip_subsystem_mod #(.ROM_INIT(`ROMHEX), .PCM_DEPTH(`PCMD), .REMAP(`REMAPV)) bup (
		.clk_sys, .clk_arm, .reset_arm, .enabled(1'b1),
		.load_start, .load_addr, .load_valid, .load_data, .load_end, .asset_start,
		.cmd_valid_sys(cmd_valid), .cmd_data_sys(cmd_data),
		.mem_ce(1'b1), .mem_req, .mem_addr, .mem_write, .mem_wdata, .mem_wstrb, .mem_size,
		.mem_ready, .mem_abort, .mem_rdata, .arm_hold, .load_wait,
		.ddr_addr, .ddr_din, .ddr_be, .ddr_len, .ddr_req, .ddr_rnw,
		.ddr_ack, .ddr_dout, .ddr_rvalid, .ddr_timeout(1'b0),
		.audio_l, .audio_r);

	int lat = 20;
	logic [63:0] ddr [logic [28:0]];
	int rd_left = 0, rd_wait = 0;
	logic [28:0] rd_a;
	always @(posedge clk_arm) begin
		ddr_ack <= 0;
		ddr_rvalid <= 0;
		if (rd_left != 0) begin
			if (rd_wait != 0) rd_wait <= rd_wait - 1;
			else begin
				ddr_rvalid <= 1;
				ddr_dout <= ddr.exists(rd_a) ? ddr[rd_a] : 64'd0;
				rd_a <= rd_a + 1;
				rd_left <= rd_left - 1;
			end
		end else if (ddr_req && !ddr_ack) begin
			ddr_ack <= 1;
			if (!ddr_rnw) begin
				logic [63:0] w;
				w = ddr.exists(ddr_addr) ? ddr[ddr_addr] : 64'd0;
				for (int b = 0; b < 8; b++) if (ddr_be[b]) w[b*8 +: 8] = ddr_din[b*8 +: 8];
				ddr[ddr_addr] = w;
			end else begin
				rd_a <= ddr_addr;
				rd_left <= ddr_len;
				rd_wait <= lat;
			end
		end
	end

	logic [31:0] fetch_pc = 0;
	always @(posedge clk_arm) if (mem_req && mem_fetch && mem_ready) fetch_pc <= mem_addr;

	wire [12:0] level = 13'(bup.peripheral.pcm_level);
	longint cyc = 0, t_hold = -1, t_en = -1, pushes = 0, pushes_pre = 0, pops = 0, under = 0, over_ev = 0;
	int lvl_min = 99999, lvl_max = -1, lvl_at_en = -1;
	logic en_d = 0;
	always @(posedge clk_arm) begin
		cyc++;
		if (!arm_hold && t_hold < 0 && !reset_arm) t_hold = cyc;
		en_d <= bup.pcm_enabled;
		if (bup.pcm_enabled && !en_d) begin t_en = cyc; lvl_at_en = level; end
		if (bup.peripheral.pcm_push) begin
			pushes++;
			if (!bup.pcm_enabled) pushes_pre++;
			if (bup.peripheral.pcm_full) over_ev++;
		end
		if (bup.pcm_pop) begin pops++; if (bup.peripheral.pcm_empty) under++; end
		// level range once the firmware has been running enabled for 10 ms
		if (t_en > 0 && cyc > t_en + 715820) begin
			if (int'(level) < lvl_min) lvl_min = int'(level);
			if (int'(level) > lvl_max) lvl_max = int'(level);
		end
	end

	// request->answer latency per region, and the gap the CPU leaves between
	// an answer and its next request
	longint lat_sum[5], lat_n[5], lat_max[5], gap_sum = 0, gap_n = 0;
	longint req_t = -1, last_ready = -1;
	logic in_req = 0;
	function automatic int region(input logic [31:0] a);
		if (a < 32'h4000) return 0;
		if (a[31:24] == 8'h02) return 1;
		if (a[31:28] == 4'h4) return 2;
		if (a[31:8] == 24'hE00090) return 3;
		return 4;
	endfunction
	always @(posedge clk_arm) if (`MEASURE_FROM) begin
		if (mem_req && !in_req) begin
			req_t = cyc; in_req = 1;
			if (last_ready >= 0) begin gap_sum += cyc - last_ready; gap_n++; end
		end
		if (mem_req && mem_ready) begin
			int r; r = region(mem_addr);
			lat_sum[r] += cyc - req_t + 1; lat_n[r]++;
			if (cyc - req_t + 1 > lat_max[r]) lat_max[r] = cyc - req_t + 1;
			in_req = 0; last_ready = cyc;
		end
	end
	logic [7:0] img [0:2097151];
	initial begin
		int fd, n, ms;
		foreach (lat_n[r]) begin lat_n[r]=0; lat_sum[r]=0; lat_max[r]=0; end
		if (!$value$plusargs("ms=%d", ms)) ms = 200;
		fd = $fopen("synth.a78", "rb");
		n = $fread(img, fd);
		$fclose(fd);
		repeat (20) @(posedge clk_sys);
		reset_arm = 0;
		@(posedge clk_sys) load_start <= 1;
		@(posedge clk_sys) load_start <= 0;
		for (int i = 0; i < n; i++) begin
			@(posedge clk_sys);
			while (load_wait) begin load_valid <= 0; @(posedge clk_sys); end
			load_valid <= 1; load_addr <= i; load_data <= img[i];
			@(posedge clk_sys) load_valid <= 0;
		end
		@(posedge clk_sys) load_end <= 1;
		@(posedge clk_sys) load_end <= 0;
		repeat (ms) begin
			repeat (71582) @(posedge clk_arm);
		end
		$display("PCM_DEPTH=%0d REMAP=%0d: fault %02x, pcm_enabled %0d, PC %08x, watermark reg %0d",
			`PCMD, `REMAPV, bup.fault_code, bup.pcm_enabled, fetch_pc, bup.peripheral.pcm_watermark);
		$display("  boot: hold released at %0d clk, PCM enabled at %0d clk (%.3f ms after release), level at enable %0d",
			t_hold, t_en, (t_en - t_hold) / 71582.0, lvl_at_en);
		$display("  pushes %0d (%0d before enable), pushes into a full FIFO %0d, pops %0d, pops of an empty FIFO %0d",
			pushes, pushes_pre, over_ev, pops, under);
		$display("  steady-state level min %0d max %0d; sticky overflow %0d underflow %0d",
			lvl_min, lvl_max, bup.peripheral.pcm_overflow, bup.peripheral.pcm_underflow);
		foreach (lat_n[r]) if (lat_n[r] > 0)
			$display("  region %0d (0 ROM,1 asset,2 RAM,3 MMIO): %0d accesses, request-to-answer %.2f clk avg, %0d max",
				r, lat_n[r], 1.0 * lat_sum[r] / lat_n[r], lat_max[r]);
		$display("  CPU gap answer->next request %.2f clk avg over %0d", 1.0 * gap_sum / gap_n, gap_n);
		$finish;
	end
endmodule
