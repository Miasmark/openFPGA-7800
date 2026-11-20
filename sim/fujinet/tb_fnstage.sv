// FujiNet staging (docs/FUJINET_GAME_LOADING.md, 3.2): fujinet_stage.sv on
// clk_sys, bup_asset_wr.sv on clk_arm (asynchronous, VCO/18 = 38.18 MHz, as
// the DARIA build), psram.sv (CLOCK_SPEED 50.0, as that build) on
// psram_model.sv.
//
// Each run stages files of random length (odd and even) a byte at a time,
// as fujinet_mailbox.sv hands them over (in order from 0, at most every 4
// clk_sys, holding while busy), then SYNC, and waits for synced. Meanwhile,
// as the hardware never does but the arbitration must survive:
//   - capture WRITE messages to die 0 below 4 MiB, at random (they go first);
//   - cache reads (rd_req) of halfwords the backdoor filled beforehand,
//     each checked against what it holds.
// After synced, the PSRAM must hold every staged byte at 4 MiB + offset,
// nothing past the file's end written there, the capture's writes where
// they went, and bup_asset_wr's overrun must be low.
//
// Then fujinet_loader.sv replays the file through fujinet_rd.sv (ahead of
// the cache-style reads, as in bupchip_pocket.sv), once as an A78 (hdr) and
// once without a header: every byte must come out in order at its address,
// a generated header first in the second case, one wr each at least SPACE
// clk_sys apart, dout changing only with addr (the header parser reads by
// address), with dl high throughout and addr all ones before the first. Last, a replay ended by host_dl and a restart pulse.
//   +seed=N +files=N     (defaults 1 and 6)
// Prints "FNSTAGE ... fails N".
//
// SPDX-License-Identifier: MIT
`timescale 1ps/1ps

module tb_fnstage;
	logic clk_sys = 0, clk_arm = 0;
	initial forever #34920 clk_sys = ~clk_sys;      // 14.318 MHz
	initial begin
		#7000;
		forever #13095 clk_arm = ~clk_arm;          // 38.18 MHz, unrelated phase
	end

	int seed = 1, files = 6, fails = 0;
	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("files=%d", files));
		void'($urandom(seed));
	end

	// ---- clk_sys: the stager, driven as the mailbox does --------------------------
	logic        start = 0, we = 0, sync = 0;
	logic [19:0] addr = 0;
	logic  [7:0] data = 0;
	wire         busy, synced;
	wire         s_tog, s_sync, s_ack;
	wire  [1:0]  s_lanes;
	wire [18:0]  s_haddr;
	wire [15:0]  s_data;
	fujinet_stage stg (
		.clk(clk_sys), .start, .we, .addr, .data, .sync, .busy, .synced,
		.s_tog, .s_sync, .s_lanes, .s_haddr, .s_data, .s_ack);

	// ---- clk_arm: the capture's messages, the writer, the PSRAM --------------------
	logic  [2:0] msg_type = 0;
	logic [43:0] msg_pl = 0;
	logic        msg_tog = 0;
	logic        rd_req = 0;
	logic [21:0] rd_addr = 0;
	wire         rd_ack;                        // the bench's reads, through fujinet_rd
	wire         w_rd_req, w_rd_ack;            // the writer's read port
	wire [21:0]  w_rd_addr;
	wire         p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy, overrun;
	wire [21:0]  p_addr;
	wire [15:0]  p_din, p_dout;
	/* verilator lint_off PINCONNECTEMPTY */
	bup_asset_wr wr (
		.clk(clk_arm), .msg_type, .msg_pl, .msg_tog,
		.asset_ready(), .asset_size(), .fw_loaded(), .img_ready(), .img_size(),
		.rom_we(), .rom_wa(), .rom_wd(), .win_we(), .win_wa(), .win_wd(), .win_be(),
		.rd_req(w_rd_req), .rd_addr(w_rd_addr), .rd_ack(w_rd_ack),
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun, .fw_start(),
		.s_tog, .s_sync, .s_lanes, .s_haddr, .s_data, .s_ack);
	/* verilator lint_on PINCONNECTEMPTY */
	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(50.0)) ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);

	// ---- the swap: fujinet_loader (clk_sys) and fujinet_rd (clk_arm) --------------
	logic        ld_go = 0, ld_rgo = 0, ld_hdr = 0, host_dl = 0;
	logic [19:0] ld_size = 0;
	wire         ld_dl, ld_wr, ld_restart, l_req, l_ack;
	wire [24:0]  ld_addr;
	wire  [7:0]  ld_dout;
	wire [18:0]  l_haddr;
	wire [15:0]  l_data;
	fujinet_loader ld (
		.clk(clk_sys), .go(ld_go), .restart_go(ld_rgo), .size(ld_size), .hdr(ld_hdr), .host_dl,
		.dl(ld_dl), .wr(ld_wr), .addr(ld_addr), .dout(ld_dout), .restart(ld_restart),
		.l_req, .l_haddr, .l_ack, .l_data);
	fujinet_rd frd (
		.clk(clk_arm), .l_req, .l_haddr, .l_ack, .l_data,
		.u_rd_req(rd_req), .u_rd_addr(rd_addr), .u_rd_ack(rd_ack),
		.rd_req(w_rd_req), .rd_addr(w_rd_addr), .rd_ack(w_rd_ack),
		.rd_avail(p_avail), .rd_data(p_dout));

	localparam int unsigned BASE = 32'h200000;      // the staging area's first halfword
	localparam int unsigned RD_LO = 32'h100000;     // reads: pre-filled halfwords from here
	localparam int unsigned RD_N = 4096;

	// ---- the capture's WRITEs (clk_sys toggles, as bup_capture: 5+ clocks apart) ---
	logic [15:0] cap_val [0:1023];                  // the last value each capture halfword got
	bit          cap_set [0:1023];                  // (Verilator is 2-state: no x for "none")
	bit          cap_done = 0, stage_on = 0;
	int          cap_n = 0;
	initial begin
		for (int i = 0; i < 1024; i++) cap_set[i] = 0;
		@(posedge stage_on);
		while (!cap_done) begin
			repeat ($urandom_range(5, 300)) @(posedge clk_sys);
			begin
				automatic int a = $urandom_range(0, 1023);
				automatic logic [15:0] v = 16'($urandom);
				msg_type <= 3'd2;                    // M_WRITE, both lanes, halfword a
				msg_pl <= {3'd0, 1'b0, 2'b11, 22'(a), v};
				msg_tog <= ~msg_tog;
				cap_val[a] = v;
				cap_set[a] = 1;
				cap_n++;
			end
		end
	end

	// ---- the cache's reads (clk_arm), of halfwords the backdoor filled ------------
	// A clocked requester, as bup_asset_cache: rd_req until rd_ack, then the
	// data on read_avail.
	int rd_n = 0, rd_bad = 0, rd_wait = 0;
	logic [1:0] rs = 0;
	logic [21:0] rd_exp = 0;
	always @(posedge clk_arm) begin
		case (rs)
			0: if (stage_on && !cap_done) begin
				if (rd_wait == 0) begin
					rd_addr <= 22'(RD_LO + $urandom_range(0, RD_N - 1));
					rd_req <= 1;
					rs <= 1;
					rd_wait <= $urandom_range(1, 40);
				end else rd_wait <= rd_wait - 1;
			end
			1: if (rd_ack) begin rd_req <= 0; rd_exp <= rd_addr; rs <= 2; end
			2: if (p_avail) begin
				if (p_dout !== 16'(rd_exp * 7 + 3)) begin
					if (rd_bad < 5) $display("FNSTAGE read %06x: got %04x expected %04x", rd_exp, p_dout, 16'(rd_exp * 7 + 3));
					rd_bad++;
				end
				rd_n++;
				rs <= 0;
			end
			default: rs <= 0;
		endcase
	end

	// ---- stage a file -------------------------------------------------------------
	logic [7:0] file [0:65535];
	task automatic stage_file(input int n);
		for (int i = 0; i < n; i++) file[i] = 8'($urandom);
		@(posedge clk_sys);
		start <= 1;
		@(posedge clk_sys);
		start <= 0;
		for (int i = 0; i < n; i++) begin
			repeat (3) @(posedge clk_sys);
			while (busy) @(posedge clk_sys);
			we <= 1; addr <= 20'(i); data <= file[i];
			@(posedge clk_sys);
			we <= 0;
		end
		sync <= 1;
		@(posedge clk_sys);
		sync <= 0;
		fork
			begin @(posedge synced); end
			begin repeat (200000) @(posedge clk_sys); $display("FNSTAGE FAIL: no synced"); fails++; end
		join_any
		disable fork;
	endtask

	// The loader's output, as the core's load path sees it
	logic [7:0] got_b [0:65535 + 128];
	int got_n = 0, ord_bad = 0, sp_bad = 0, dl_bad = 0, hold_bad = 0, last_wr = -100, clk_n = 0;
	logic [24:0] p_ad = '1;
	logic  [7:0] p_do = 8'd0;
	bit pre_ok = 1, watching = 0;
	always @(posedge clk_sys) begin
		clk_n++;
		if (watching) begin
			if (!ld_dl && ld_wr) dl_bad++;
			if (ld_dl && got_n == 0 && !ld_wr && ld_addr !== '1) pre_ok = 0;
			// the header parser reads by address: dout moves only with addr
			if (ld_dl && ld_addr == p_ad && ld_dout != p_do) hold_bad++;
			p_ad = ld_addr;
			p_do = ld_dout;
			if (ld_wr) begin
				if (ld_addr != 25'(got_n)) ord_bad++;
				if (clk_n - last_wr < 4) sp_bad++;
				last_wr = clk_n;
				got_b[got_n] = ld_dout;
				got_n++;
			end
		end
	end

	function automatic logic [7:0] ghdr(input int a, input int n);
		case (a)
			0: return 8'd3;
			1: return "A"; 2: return "T"; 3: return "A"; 4: return "R"; 5: return "I";
			6: return "7"; 7: return "8"; 8: return "0"; 9: return "0";
			50: return 8'(n >> 16); 51: return 8'(n >> 8); 52: return 8'(n);
			54: return n > 'hC000 ? 8'h02 : 8'h00;
			55, 56: return 8'd1;
			default: return 8'd0;
		endcase
	endfunction

	task automatic replay(input int n, input bit hdr, output int bad);
		int exp_n, to;
		bad = 0;
		got_n = 0; ord_bad = 0; sp_bad = 0; dl_bad = 0; hold_bad = 0; pre_ok = 1; last_wr = -100;
		watching = 1;
		@(posedge clk_sys);
		ld_size <= 20'(n); ld_hdr <= hdr; ld_go <= 1;
		@(posedge clk_sys);
		ld_go <= 0;
		to = 0;
		do begin @(posedge clk_sys); to++; end while (!ld_dl && to < 100);
		while (ld_dl && to < 4000000) begin @(posedge clk_sys); to++; end
		repeat (4) @(posedge clk_sys);
		watching = 0;
		exp_n = hdr ? n : n + 128;
		if (got_n != exp_n) begin $display("FNSTAGE replay: %0d bytes, expected %0d", got_n, exp_n); bad++; end
		for (int i = 0; i < got_n && i < exp_n; i++) begin
			logic [7:0] e;
			e = (!hdr && i < 128) ? ghdr(i, n) : file[hdr ? i : i - 128];
			if (got_b[i] !== e) begin
				if (bad < 5) $display("FNSTAGE replay byte %0d: got %02x expected %02x", i, got_b[i], e);
				bad++;
			end
		end
		if (ord_bad || sp_bad || dl_bad || hold_bad || !pre_ok) begin
			$display("FNSTAGE replay: out of order %0d, too close %0d, wr without dl %0d, dout without addr %0d, addr before %0d",
				ord_bad, sp_bad, dl_bad, hold_bad, pre_ok);
			bad++;
		end
	endtask

	function automatic int check_file(input int n);
		int bad = 0;
		for (int i = 0; i < n; i++) begin
			logic [15:0] h;
			logic  [1:0] w;
			h = chip.bd_read(0, BASE + i / 2);
			w = chip.bd_written(0, BASE + i / 2);
			if (!(i[0] ? w[1] : w[0]) || (i[0] ? h[15:8] : h[7:0]) !== file[i]) begin
				if (bad < 5) $display("FNSTAGE byte %0d: got %02x expected %02x", i, i[0] ? h[15:8] : h[7:0], file[i]);
				bad++;
			end
		end
		return bad;
	endfunction

	initial begin
		int n, bad;
		for (int i = 0; i < RD_N; i++) chip.bd_write(0, RD_LO + i, 16'(i * 7 + 3), 2'b11);
		repeat (20) @(posedge clk_sys);
		stage_on = 1;
		for (int f = 0; f < files; f++) begin
			chip.bd_clear();
			for (int i = 0; i < RD_N; i++) chip.bd_write(0, RD_LO + i, 16'(i * 7 + 3), 2'b11);
			for (int i = 0; i < 1024; i++) cap_set[i] = 0;
			n = (f == 0) ? 1 : (f == 1) ? 2 : $urandom_range(3, 20000);
			stage_file(n);
			bad = check_file(n);
			// nothing written past the file's end in the staging area
			for (int i = n; i < n + 64; i++) begin
				logic [1:0] w = chip.bd_written(0, BASE + i / 2);
				if (i[0] ? w[1] : w[0]) bad++;
			end
			$display("FNSTAGE file %0d: %0d bytes, %0d wrong", f, n, bad);
			if (bad != 0) fails++;
			for (int h = 0; h < 2; h++) begin
				int rb;
				replay(n, h[0], rb);
				$display("FNSTAGE file %0d replayed %s: %0d wrong", f, h[0] ? "as an A78" : "with a generated header", rb);
				if (rb != 0) fails++;
			end
		end
		// host_dl ends a replay at once; the loader is idle and works again after
		begin
			int to = 0, rb;
			@(posedge clk_sys);
			ld_size <= 20'd5000; ld_hdr <= 1; ld_go <= 1;
			@(posedge clk_sys);
			ld_go <= 0;
			repeat (3000) @(posedge clk_sys);
			host_dl <= 1;
			repeat (2) @(posedge clk_sys);
			if (ld_dl) begin $display("FNSTAGE FAIL: dl still high 2 clocks after host_dl"); fails++; end
			@(posedge clk_sys);
			ld_go <= 1;                     // refused while host_dl
			@(posedge clk_sys);
			ld_go <= 0;
			repeat (50) @(posedge clk_sys);
			if (ld_dl) begin $display("FNSTAGE FAIL: a replay started under host_dl"); fails++; end
			host_dl <= 0;
			repeat (200) @(posedge clk_sys);
			// the restart: RESTART clocks of restart
			ld_rgo <= 1;
			@(posedge clk_sys);
			ld_rgo <= 0;
			while (!ld_restart && to < 10) begin @(posedge clk_sys); to++; end
			to = 0;
			while (ld_restart && to < 1000) begin @(posedge clk_sys); to++; end
			$display("FNSTAGE abort and restart: restart held %0d clocks", to);
			if (to < 60 || to > 70) fails++;
			// and a replay after the abort is whole (the last file staged is the 5000+ one? restage)
			stage_file(300);
			replay(300, 1'b1, rb);
			$display("FNSTAGE replay after the abort: %0d wrong", rb);
			if (rb != 0) fails++;
		end
		cap_done = 1;
		repeat (2000) @(posedge clk_arm);
		begin
			int cbad = 0;
			for (int i = 0; i < 1024; i++)
				if (cap_set[i] && chip.bd_read(0, i) !== cap_val[i]) begin
					if (cbad < 5) $display("FNSTAGE capture %03x: got %04x expected %04x", i, chip.bd_read(0, i), cap_val[i]);
					cbad++;
				end
			$display("FNSTAGE capture writes %0d (last values checked, %0d wrong), cache reads %0d (%0d wrong), overrun %0d",
				cap_n, cbad, rd_n, rd_bad, overrun);
			if (cbad != 0 || rd_bad != 0 || overrun || rd_n < 100 || cap_n < 20) fails++;
		end
		$display("FNSTAGE seed %0d files %0d fails %0d", seed, files, fails);
		$finish;
	end
endmodule
