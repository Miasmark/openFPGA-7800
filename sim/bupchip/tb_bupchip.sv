// BupChip workload measurement: upstream's ARM7TDMI (arm_host) and
// bupchip_subsystem alone, fed a Souper .a78 with its ARSC block appended
// (make_arsc.py). After boot it sends one song command and then reports, per
// window and in total, how hard the firmware works the CPU.
//
//   +rom=FILE    .a78 with ARSC appended            (default game.a78)
//   +song=N      song number, command $80|N          (default 0)
//   +secs=N      seconds of audio to measure         (default 4)
//   +win=MS      report window                       (default 100)
//   +lat=N       asset memory read latency, clk_arm  (default 20)
//   +out=FILE    raw PCM, 48 kHz stereo s16le        (default out.pcm)
//
// "Idle" is the main loop polling for a command or for PCM FIFO room
// (firmware 0x178-0x18c); every other clock is work. Instruction classes
// come from the core's simulation-only retire trace.
`timescale 1ps/1ps
module tb_bupchip;
	// clk_sys 14.318 MHz and clk_arm 71.582 MHz, the MiSTer core's clocks.
	logic clk_sys = 0, clk_arm = 0;
	always #34920 clk_sys = ~clk_sys;
	always #6984  clk_arm = ~clk_arm;
	localparam real ARM_MHZ = 71.582;

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

	bupchip_subsystem #(.ROM_INIT(`ROMHEX)) bup (
		.clk_sys, .clk_arm, .reset_arm, .enabled(1'b1),
		.load_start, .load_addr, .load_valid, .load_data, .load_end, .asset_start,
		.cmd_valid_sys(cmd_valid), .cmd_data_sys(cmd_data),
		.mem_ce(1'b1), .mem_req, .mem_addr, .mem_write, .mem_wdata, .mem_wstrb, .mem_size,
		.mem_ready, .mem_abort, .mem_rdata, .arm_hold, .load_wait,
		.ddr_addr, .ddr_din, .ddr_be, .ddr_len, .ddr_req, .ddr_rnw,
		.ddr_ack, .ddr_dout, .ddr_rvalid, .ddr_timeout(1'b0),
		.audio_l, .audio_r);

	// ---- DDR3 stand-in: 64-bit words, fixed read latency, ddr_len-beat bursts.
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

	// ---- measurement
	logic [31:0] fetch_pc = 0;
	always @(posedge clk_arm) if (mem_req && mem_fetch && mem_ready) fetch_pc <= mem_addr;
	wire idle = fetch_pc >= 32'h178 && fetch_pc <= 32'h18c;

	wire [31:0] ri = cpu.arm_cpu.trace_retire_instruction;
	wire [31:0] rpc = cpu.arm_cpu.trace_retire_pc;
	typedef enum int {
		C_DP_IMM, C_DP_REG, C_DP_REGSHIFT, C_MUL, C_MUL_LONG, C_SWP, C_BX, C_PSR,
		C_LDR_STR, C_HALF_SIGNED, C_LDM_STM, C_B_BL, C_COPROC, C_SWI, C_THUMB, C_N
	} cls_t;
	string cls_name [C_N] = '{"data processing, immediate", "data processing, register",
		"data processing, shift by register", "MUL / MLA", "UMULL / SMULL / UMLAL / SMLAL",
		"SWP", "BX", "MRS / MSR", "LDR / STR (word, byte)", "LDRH / STRH / LDRSB / LDRSH",
		"LDM / STM", "B / BL", "coprocessor", "SWI", "Thumb (any)"};
	function automatic cls_t classify(input logic [31:0] i);
		if ((i & 32'h0fc000f0) == 32'h00000090) return C_MUL;
		if ((i & 32'h0f8000f0) == 32'h00800090) return C_MUL_LONG;
		if ((i & 32'h0fb00ff0) == 32'h01000090) return C_SWP;
		if ((i & 32'h0ffffff0) == 32'h012fff10) return C_BX;
		if ((i & 32'h0e000090) == 32'h00000090) return C_HALF_SIGNED;
		if ((i & 32'h0fbf0fff) == 32'h010f0000 || (i & 32'h0db0f000) == 32'h0120f000) return C_PSR;
		case (i[27:25])
			3'b000: return (i[4] ? C_DP_REGSHIFT : C_DP_REG);
			3'b001: return C_DP_IMM;
			3'b010, 3'b011: return C_LDR_STR;
			3'b100: return C_LDM_STM;
			3'b101: return C_B_BL;
			3'b110: return C_COPROC;
			default: return i[24] ? C_SWI : C_COPROC;
		endcase
	endfunction

	longint cyc = 0, idle_c = 0, win_c = 0, win_idle = 0, frames = 0, under = 0;
	longint ins = 0, win_ins = 0, dacc = 0, aacc = 0, cond_ins = 0;
	longint cls [C_N];
	bit     seen_pc [logic [31:0]];
	logic   measuring = 0;
	integer pcm_fd;
	always @(posedge clk_arm) if (measuring) begin
		cyc++; win_c++;
		if (idle) begin idle_c++; win_idle++; end
		if (retire && !idle) begin
			ins++; win_ins++;
			seen_pc[rpc] = 1;
			if (cpu.arm_cpu.trace_retire_thumb) cls[C_THUMB]++;
			else begin
				cls[classify(ri)]++;
				if (ri[31:28] != 4'he) cond_ins++;
			end
		end
		if (mem_req && mem_ready && !mem_fetch && !idle) begin
			dacc++;
			if (mem_addr[31:24] == 8'h02) aacc++;
		end
		if (bup.pcm_pop) begin
			frames++;
			if (!bup.pcm_available) under++;
			$fwrite(pcm_fd, "%c%c%c%c", bup.pcm_frame[7:0], bup.pcm_frame[15:8],
				bup.pcm_frame[23:16], bup.pcm_frame[31:24]);
		end
	end

	logic [7:0] img [0:2097151];
	initial begin
		string rom, out;
		int fd, n, song, secs, win_ms;
		real busy, peak_busy, mips, peak_mips;
		if (!$value$plusargs("rom=%s", rom)) rom = "game.a78";
		if (!$value$plusargs("out=%s", out)) out = "out.pcm";
		if (!$value$plusargs("song=%d", song)) song = 0;
		if (!$value$plusargs("secs=%d", secs)) secs = 4;
		if (!$value$plusargs("win=%d", win_ms)) win_ms = 100;
		void'($value$plusargs("lat=%d", lat));
		foreach (cls[c]) cls[c] = 0;
		pcm_fd = $fopen(out, "wb");
		fd = $fopen(rom, "rb");
		if (fd == 0) begin $display("cannot open %s", rom); $finish; end
		n = $fread(img, fd);
		$fclose(fd);
		$display("%s: %0d bytes", rom, n);

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
		wait (!arm_hold);
		repeat (200000) @(posedge clk_arm);
		$display("booted: ARSC at file offset %0d, fault %02x, PCM enabled %0d",
			asset_start, bup.fault_code, bup.pcm_enabled);
		if (bup.fault_code != 0) begin
			$display("firmware fault: no or bad ARSC block (see docs/BUPCHIP.md)");
			$finish;
		end

		// The game writes $8007 twice per command; the subsystem delivers one event.
		@(posedge clk_sys) begin cmd_valid <= 1; cmd_data <= 8'h80 | 8'(song[4:0]); end
		@(posedge clk_sys) cmd_valid <= 0;
		$display("song %0d (command $%02x), asset latency %0d clk_arm", song, 8'h80 | song[4:0], lat);
		measuring = 1;
		peak_busy = 0; peak_mips = 0;
		for (int w = 0; w < secs * 1000 / win_ms; w++) begin
			win_c = 0; win_idle = 0; win_ins = 0;
			wait (win_c >= longint'(ARM_MHZ * 1000.0 * win_ms));
			busy = 100.0 * (win_c - win_idle) / win_c;
			mips = win_ins / (win_ms * 1000.0);
			if (busy > peak_busy) peak_busy = busy;
			if (mips > peak_mips) peak_mips = mips;
			$display("%6d ms  busy %5.1f%%  %6.2f MIPS  underruns %0d  fault %02x",
				(w + 1) * win_ms, busy, mips, under, bup.fault_code);
		end

		$display("");
		$display("busy       %.1f%% average, %.1f%% peak window, of %.3f MHz", 100.0 * (cyc - idle_c) / cyc, peak_busy, ARM_MHZ);
		$display("work       %0d instructions: %.2f MIPS average, %.2f peak window; %.2f clocks per instruction",
			ins, ins / (secs * 1.0e6), peak_mips, (cyc - idle_c) * 1.0 / ins);
		$display("data       %0d accesses, %0d of them to the asset window", dacc, aacc);
		$display("audio      %0d frames, %0d underruns", frames, under);
		$display("coverage   %0d distinct instruction addresses executed", seen_pc.num());
		$display("conditional %0d instructions (%.1f%%) not 'always'", cond_ins, 100.0 * cond_ins / ins);
		$display("instruction classes (executed while working):");
		for (int c = 0; c < C_N; c++)
			$display("  %-36s %12d  %6.2f%%", cls_name[c], cls[c], 100.0 * cls[c] / ins);
		$fclose(pcm_fd);
		$finish;
	end
endmodule
