//------------------------------------------------------------------------------
// The reference BupChip, included inside the module of tb_ref_trace.sv and
// tb_lockstep.sv: MiSTer's arm_host (arm7tdmi_core) and bupchip_subsystem,
// the DDR3 stand-in from tb_bupchip.sv, the cartridge download, a command
// sender and a few helpers. Clocks are MiSTer's (clk_sys 14.318 MHz, clk_arm
// 71.582 MHz).
//
// Plusargs:
//   +rom=FILE      .a78 image; an ARSC block, if any, follows the cartridge
//   +romhex=FILE   firmware ROM image ($readmemh, up to 4096 words), loaded
//                  over the build-time ROMHEX before the CPU is released
//   +lat=N         DDR3 read latency in clk_arm clocks (default 20)
//   +cmds=LIST     $8007 commands: HH@CLK[,HH@CLK...], byte in hex, sent when
//                  the reference has run CLK clk_arm clocks, in list order
//   +song=N        shorthand for one command $80|N ...
//   +songcyc=CLK   ... at clock CLK (default 0)
//
// arm7tdmi_core.sv is GPL-2.0-only. These testbenches only instantiate it and
// read its simulation-only state (rf, cpsr, trace_retire_*) as an oracle;
// nothing here is taken from it.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

	logic clk_sys = 0, clk_arm = 0;
	always #34920 clk_sys = ~clk_sys;
	always #6984  clk_arm = ~clk_arm;

	logic        reset_arm = 1;
	logic        load_start = 0, load_valid = 0, load_end = 0;
	logic [24:0] load_addr = 0;
	logic  [7:0] load_data = 0;
	logic        cmd_valid = 0;
	logic  [7:0] cmd_data = 0;
	wire         load_wait, arm_hold;
	wire  [24:0] asset_start;
	wire         mem_req, mem_write, mem_ready, mem_abort, mem_fetch, retire;
	wire  [31:0] mem_addr, mem_wdata, mem_rdata;
	wire   [3:0] mem_wstrb;
	wire   [1:0] mem_size;
	wire  [28:0] ddr_addr;
	wire  [63:0] ddr_din;
	wire   [7:0] ddr_be, ddr_len;
	wire         ddr_req, ddr_rnw;
	logic        ddr_ack = 0, ddr_rvalid = 0;
	logic [63:0] ddr_dout = 0;
	wire  [15:0] audio_l, audio_r;

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

	// DDR3 stand-in: 64-bit words, fixed read latency, ddr_len-beat bursts.
	int          ddr_lat = 20;
	logic [63:0] ddr [logic [28:0]];
	int          rd_left = 0, rd_wait = 0;
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
				rd_wait <= ddr_lat;
			end
		end
	end

	// Where r0-r14 of mode m live in the reference's flat register file (its
	// layout): 0-14 the user and system registers, 15-21 FIQ's r8-r14, then
	// r13-r14 of IRQ (22), SVC (24), ABT (26) and UND (28). tb_lockstep.sv's
	// shadow uses the same layout.
	function automatic int bank(input int k, input logic [4:0] m);
		if (k < 8 || m == 5'h10 || m == 5'h1f) return k;
		if (m == 5'h11) return k + 7;                             // FIQ r8-r14
		if (k < 13) return k;
		case (m)                                                  // banked r13/r14
			5'h12:   return 22 + k - 13;                          // IRQ
			5'h13:   return 24 + k - 13;                          // SVC
			5'h17:   return 26 + k - 13;                          // ABT
			default: return 28 + k - 13;                          // UND
		endcase
	endfunction

	// Architectural view of the reference: r0-r14 of the current mode (the
	// firmware runs in SVC mode throughout) and NZCV. Sampled on the edge where
	// `retire` is high, this is the state after the retired instruction: the
	// core writes every register and flag on or before the edge that raises
	// `retire`.
	function automatic logic [31:0] ref_reg(input int k);
		return cpu.arm_cpu.rf[bank(k, cpu.arm_cpu.cpsr[4:0])];
	endfunction
	wire  [3:0] ref_nzcv = cpu.arm_cpu.cpsr[31:28];
	wire [31:0] ref_rpc  = cpu.arm_cpu.trace_retire_pc;
	wire [31:0] ref_rins = cpu.arm_cpu.trace_retire_instruction;
	wire        ref_rexc = cpu.arm_cpu.trace_retire_exception;

	// Bus events of the reference, as seen at the answer.
	wire ref_dacc  = mem_req && mem_ready && !mem_fetch;
	wire ref_mmio  = mem_addr[31:8] == 24'he00090;
	wire ref_fault = ref_dacc && !mem_abort && mem_write && mem_addr == 32'he000901c;

	// The cartridge image and the clock count since the CPU was released.
	logic  [7:0] img [0:4194303];
	int          img_n = 0, asset_base = 0;
	string       rom_file = "game.a78", romhex_file = `ROMHEX;
	logic        ref_running = 0;
	longint      ref_cyc = 0;
	always @(posedge clk_arm) if (ref_running) ref_cyc <= ref_cyc + 1;

	// Load the image, stream it through the download port, wait for the
	// subsystem to release the CPU. Returns on the clk_arm edge after release.
	task automatic ref_boot();
		int fd;
		void'($value$plusargs("rom=%s", rom_file));
		void'($value$plusargs("lat=%d", ddr_lat));
		fd = $fopen(rom_file, "rb");
		if (fd == 0) $fatal(1, "cannot open %s", rom_file);
		img_n = $fread(img, fd);
		$fclose(fd);
		asset_base = 128 + {img[49], img[50], img[51], img[52]};
		repeat (20) @(posedge clk_sys);
		if ($value$plusargs("romhex=%s", romhex_file)) begin
			for (int i = 0; i < 4096; i++) bup.memory.firmware_rom.u_ram.mem_q[i] = 32'b0;
			$readmemh(romhex_file, bup.memory.firmware_rom.u_ram.mem_q);
		end
		reset_arm = 0;
		@(posedge clk_sys) load_start <= 1;
		@(posedge clk_sys) load_start <= 0;
		for (int i = 0; i < img_n; i++) begin
			@(posedge clk_sys);
			while (load_wait) begin load_valid <= 0; @(posedge clk_sys); end
			load_valid <= 1; load_addr <= 25'(i); load_data <= img[i];
			@(posedge clk_sys) load_valid <= 0;
		end
		@(posedge clk_sys) load_end <= 1;
		@(posedge clk_sys) load_end <= 0;
		wait (!arm_hold);
		@(posedge clk_arm);
		ref_running = 1;
		$display("image %s: %0d bytes, %0d bytes of assets after offset %0d; ROM %s",
			rom_file, img_n, (img_n > asset_base) ? img_n - asset_base : 0, asset_base, romhex_file);
	endtask

	// Command schedule from +cmds / +song, sent from clk_sys like cart.sv does.
	typedef struct { longint at; logic [7:0] b; } cmd_t;
	cmd_t cmd_list [$];
	initial begin : command_sender
		string s, item;
		int p, song, n;
		longint at;
		logic [7:0] b;
		if ($value$plusargs("cmds=%s", s))
			while (s.len() > 0) begin
				p = 0;
				while (p < s.len() && s.getc(p) != 8'h2c) p++;
				item = s.substr(0, p - 1);
				s = (p + 1 < s.len()) ? s.substr(p + 1, s.len() - 1) : "";
				n = $sscanf(item, "%h@%d", b, at);
				if (n != 2) $fatal(1, "bad +cmds item '%s' (want HH@CLOCK)", item);
				cmd_list.push_back('{at, b});
			end
		if ($value$plusargs("song=%d", song)) begin
			if (!$value$plusargs("songcyc=%d", at)) at = 0;
			cmd_list.push_back('{at, 8'h80 | 8'(song[4:0])});
		end
		wait (ref_running);
		foreach (cmd_list[i]) begin
			wait (ref_cyc >= cmd_list[i].at);
			@(posedge clk_sys) begin cmd_valid <= 1; cmd_data <= cmd_list[i].b; end
			@(posedge clk_sys) cmd_valid <= 0;
			$display("command $%02x at reference clock %0d", cmd_list[i].b, ref_cyc);
		end
	end
