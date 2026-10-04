//------------------------------------------------------------------------------
// The Pocket's data slot sequence into the BupChip capture (README.md,
// "Slot switches"): the real data_loader with a dcfifo whose pointers cross
// through synchroniser stages, core_top's slot flags (is_downloading stays
// high from the first requestwrite to allcomplete, download_slot changes at
// each requestwrite, three flops into clk_sys), its clk_sys register of the
// loader's output with the address cut to 25 bits and bits 27:25 kept
// beside it, bupchip_pocket's strobes (each byte by its address), then
// bup_capture, bup_asset_wr, psram.sv and psram_model.sv, and the BUP_DEBUG
// load probe.
//
// Slots go in data.json order: cartridge 0x100 at 0x00000000, the optional
// firmware slots 0x103 / 0x106 / 0x107 / 0x108 at 0x02 / 0x04 / 0x06 /
// 0x08000000, the save slots 0x104 / 0x105 (above 0x0FFFFFFF, which the
// loader ignores), and bupchip.bin 0x109 at 0x0A000000. Their contents are
// made up here: no game data, no firmware.
//
// Plusargs:
//   +gap=N      clk_74a clocks from a slot's last bridge write to the next
//               requestwrite (or allcomplete) reaching core_top; default 400
//   +pre=N      from a requestwrite to the slot's first word; default 400
//   +word=N     clk_74a clocks per bridge word; default 75
//   +sync=N     dcfifo synchroniser stages each way; default 3
//   +nomusic    the cartridge without its ARSC block
//   +slots=HEX  which optional slots are present: bit 0 BIOS, 1 hsc.sav,
//               2 savekey.sav, 3 highscor.rom, 4 supercharger.bin,
//               5 hsc.a78; default 3F
//   +fwfirst    bupchip.bin before the cartridge
//   +flags      bytes by slot flag, as before the fix: the cartridge's while
//               cart_download is up, the firmware's while bupfw_download is
//
// With +flags and a short gap, a slot's last bytes go to the next slot's
// download: seq_err rises when the firmware slot follows a firmware-type
// slot (its bytes at offsets below 16 KiB), and the firmware loses its own
// last bytes before allcomplete.
//
// Prints one "result:" line: the capture's seq_err and lost, the receiver's
// overrun, ROM words wrong, PSRAM bytes wrong, asset_size and fw_loaded, the
// FIFO's highest fill, and the probe's counts (bup_load_probe.sv).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ps/1ps

// The loader's dual clock FIFO, with the write and read pointers crossing
// through SYNC flops each way as Quartus' dcfifo does (rdsync_delaypipe /
// wrsync_delaypipe): rdempty clears SYNC rdclk clocks after a write.
module dcfifo #(
	parameter clocks_are_synchronized = "FALSE",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_numwords = 4,
	parameter lpm_showahead = "OFF",
	parameter lpm_type = "dcfifo",
	parameter lpm_width = 8,
	parameter lpm_widthu = 2,
	parameter overflow_checking = "OFF",
	parameter rdsync_delaypipe = 5,
	parameter underflow_checking = "OFF",
	parameter use_eab = "OFF",
	parameter wrsync_delaypipe = 5
) (
	input  wire [lpm_width-1:0] data,
	input  wire rdclk, rdreq, wrclk, wrreq,
	output reg  [lpm_width-1:0] q,
	output wire rdempty
);
	int sync = 3;
	initial void'($value$plusargs("sync=%d", sync));
	logic [lpm_width-1:0] mem [0:255];
	int wp = 0, rp = 0;		// free-running pointers
	int wp_s [0:15];		// wp through the read side's flops
	int maxfill = 0;
	initial for (int i = 0; i < 16; i++) wp_s[i] = 0;
	always @(posedge wrclk) if (wrreq) begin
		mem[wp & 255] <= data;
		wp <= wp + 1;
		if (wp + 1 - rp > maxfill) maxfill <= wp + 1 - rp;
	end
	always @(posedge rdclk) begin
		wp_s[0] <= wp;
		for (int i = 1; i < 16; i++) wp_s[i] <= wp_s[i - 1];
		if (rdreq && rp != wp_s[sync - 1]) begin
			q <= mem[rp & 255];
			rp <= rp + 1;
		end
	end
	assign rdempty = rp == wp_s[sync - 1];
endmodule

module tb_slotswitch;
	// ---- clocks: clk_sdram, clk_arm = /2 and clk_sys = /4, edge aligned (NTSC) --
	logic clk_sdram = 0, clk_arm = 0, clk_sys = 0, clk_74a = 0;
	initial forever #8730 clk_sdram = ~clk_sdram;
	initial forever #17460 clk_arm = ~clk_arm;
	initial forever #34920 clk_sys = ~clk_sys;
	initial begin #1234; forever #6734 clk_74a = ~clk_74a; end

	int gap = 400, pre = 400, word = 75, slots = 'h3F;
	bit nomusic = 0, fwfirst = 0, flags = 0;

	// ---- bridge and core_top's slot flags (clk_74a) -------------------------------
	logic        bridge_wr = 0;
	logic [31:0] bridge_addr = 0, bridge_wr_data = 0;
	logic        requestwrite = 0, allcomplete = 0;
	logic [15:0] requestwrite_id = 0;
	logic        is_downloading = 0;
	logic [15:0] download_slot = 0;
	always @(posedge clk_74a)
		if (requestwrite) begin
			is_downloading <= 1;
			download_slot <= requestwrite_id;
		end else if (allcomplete)
			is_downloading <= 0;

	wire        ioctl_wr;
	wire [27:0] ioctl_addr;
	wire  [7:0] ioctl_dout;
	data_loader #(.ADDRESS_MASK_UPPER_4(4'h0), .ADDRESS_SIZE(28), .WRITE_MEM_CLOCK_DELAY(10),
		.WRITE_MEM_EN_CYCLE_LENGTH(4), .OUTPUT_WORD_SIZE(1)) loader (
		.clk_74a, .clk_memory(clk_sdram), .bridge_wr, .bridge_endian_little(1'b0),
		.bridge_addr, .bridge_wr_data, .write_en(ioctl_wr), .write_addr(ioctl_addr),
		.write_data(ioctl_dout));

	// core_top: the loader's output registered on clk_sys, the flags synchronised
	logic        ioctl_wr_r = 0;
	logic [24:0] ioctl_addr_r = 0;
	logic  [2:0] ioctl_hi_r = 0;	// bits 27:25: which slot's address the byte carries
	logic  [7:0] ioctl_dout_r = 0;
	logic  [2:0] dl_s = 0, cart_s = 0, bios_s = 0, hscfw_s = 0, arfw_s = 0, bupfw_s = 0;
	logic        cart_download = 0, bios_download = 0, hscfw_download = 0, arfw_download = 0;
	logic        bupfw_download = 0;
	always @(posedge clk_sys) begin
		ioctl_wr_r   <= ioctl_wr;
		ioctl_addr_r <= ioctl_addr[24:0];
		ioctl_hi_r   <= ioctl_addr[27:25];
		ioctl_dout_r <= ioctl_dout;
		dl_s    <= {dl_s[1:0], is_downloading};
		cart_s  <= {cart_s[1:0], download_slot == 16'h0100};
		bios_s  <= {bios_s[1:0], download_slot == 16'h0103};
		hscfw_s <= {hscfw_s[1:0], download_slot == 16'h0106 || download_slot == 16'h0108};
		arfw_s  <= {arfw_s[1:0], download_slot == 16'h0107};
		bupfw_s <= {bupfw_s[1:0], download_slot == 16'h0109};
		cart_download  <= dl_s[2] & cart_s[2];
		bios_download  <= dl_s[2] & bios_s[2];
		hscfw_download <= dl_s[2] & hscfw_s[2];
		arfw_download  <= dl_s[2] & arfw_s[2];
		bupfw_download <= dl_s[2] & bupfw_s[2];
	end

	// atari7800_pocket, and bupchip_pocket's strobes
	wire ioctl_wr_g = ioctl_wr_r & (cart_download | bios_download | hscfw_download | arfw_download | bupfw_download);
	logic old_cart_download = 0;
	always @(posedge clk_sys) old_cart_download <= cart_download;
	wire load_valid = flags ? ioctl_wr_g && cart_download : ioctl_wr_r && ioctl_hi_r == 3'd0;
	wire fw_valid   = flags ? ioctl_wr_g && bupfw_download : ioctl_wr_r && ioctl_hi_r == 3'd5;
	wire load_start = ~old_cart_download && cart_download;
	wire load_end   = old_cart_download && ~cart_download;

	// ---- the BupChip --------------------------------------------------------------
	wire  [2:0] msg_type;
	wire [43:0] msg_pl;
	wire        msg_tog, seq_err, lost, cart_win, fw_win;
	bup_capture cap (
		.clk(clk_sys),
		.load_start, .load_addr(ioctl_addr_r), .load_valid, .load_data(ioctl_dout_r), .load_end,
		.fw_download(bupfw_download), .fw_valid,
		.msg_type, .msg_pl, .msg_tog, .seq_err, .lost, .cart_win, .fw_win);

	wire        asset_ready, fw_loaded, rom_we, overrun, rd_ack;
	wire [23:0] asset_size;
	wire [11:0] rom_wa;
	wire [31:0] rom_wd;
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	bup_asset_wr wr (
		.clk(clk_arm), .msg_type, .msg_pl, .msg_tog,
		.asset_ready, .asset_size, .fw_loaded, .rom_we, .rom_wa, .rom_wd,
		.rd_req(1'b0), .rd_addr(22'd0), .rd_ack,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun, .fw_start());

	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(28.636364)) ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);

	logic [31:0] rom [0:4095];
	initial for (int i = 0; i < 4096; i++) rom[i] = 32'hDEAD0000 | i;
	always @(posedge clk_arm) if (rom_we) rom[rom_wa] <= rom_wd;

	// ---- the probe ------------------------------------------------------------------
	wire  [7:0] foreign;
	wire  [5:0] cart_late, fw_late;
	wire [11:0] dropped, t_pre, fw_tail, cart_tail, word_min, err_at;
	bup_load_probe probe (
		.clk(clk_sys), .byte_wr(ioctl_wr_r), .byte_hi(ioctl_hi_r), .byte_addr(ioctl_addr_r),
		.load_start, .load_end, .fw_download(bupfw_download), .cart_win, .fw_win, .seq_err,
		.foreign, .cart_late, .fw_late, .dropped, .t_pre, .fw_tail, .cart_tail, .word_min, .err_at);

	// ---- slot contents (made up) ----------------------------------------------------
	localparam int ROMSZ = 4096, ARSCSZ = 1500, FWSZ = 7824;
	function automatic logic [7:0] fw_byte(input int i);
		logic [31:0] h;
		h = (i * 32'h9E3779B1) ^ 32'h5A5A1234;
		h ^= h >> 13;
		return h[7:0];
	endfunction
	function automatic logic [7:0] cart_byte(input int i);
		logic [31:0] h;
		if (i >= 49 && i <= 52) return 8'((ROMSZ >> (8 * (52 - i))));
		h = (i * 32'h85EBCA6B) ^ 32'h1234ABCD;
		h ^= h >> 15;
		return h[7:0];
	endfunction
	function automatic logic [7:0] other_byte(input int slot, input int i);
		return 8'(slot * 37 + i * 7 + (i >> 8));
	endfunction

	task automatic send_slot(input logic [15:0] id, input logic [31:0] base, input int size);
		@(posedge clk_74a);
		requestwrite <= 1;
		requestwrite_id <= id;
		@(posedge clk_74a);
		requestwrite <= 0;
		repeat (pre) @(posedge clk_74a);
		for (int w = 0; w < size; w += 4) begin
			logic [7:0] b [4];
			for (int k = 0; k < 4; k++)
				b[k] = id == 16'h0109 ? fw_byte(w + k) : id == 16'h0100 ? cart_byte(w + k) : other_byte(id, w + k);
			bridge_wr <= 1;
			bridge_addr <= base + w;
			bridge_wr_data <= {b[0], b[1], b[2], b[3]};	// big-endian, as the bridge sends files
			@(posedge clk_74a);
			bridge_wr <= 0;
			if (w + 4 < size) repeat (word - 1) @(posedge clk_74a);
		end
		repeat (gap) @(posedge clk_74a);
	endtask

	int rom_bad, ps_bad;
	initial begin
		void'($value$plusargs("gap=%d", gap));
		void'($value$plusargs("pre=%d", pre));
		void'($value$plusargs("word=%d", word));
		void'($value$plusargs("slots=%h", slots));
		nomusic = $test$plusargs("nomusic");
		fwfirst = $test$plusargs("fwfirst");
		flags = $test$plusargs("flags");
		repeat (2000) @(posedge clk_74a);	// psram.sv's power-up wait
		if (fwfirst) send_slot(16'h0109, 32'h0A000000, FWSZ);
		send_slot(16'h0100, 32'h00000000, 128 + ROMSZ + (nomusic ? 0 : ARSCSZ));
		if (slots[0]) send_slot(16'h0103, 32'h02000000, 4096);
		if (slots[1]) send_slot(16'h0104, 32'h20000000, 2048);
		if (slots[2]) send_slot(16'h0105, 32'h30000000, 1024);
		if (slots[3]) send_slot(16'h0106, 32'h04000000, 4096);
		if (slots[4]) send_slot(16'h0107, 32'h06000000, 2048);
		if (slots[5]) send_slot(16'h0108, 32'h08000000, 4224);
		if (!fwfirst) send_slot(16'h0109, 32'h0A000000, FWSZ);
		@(posedge clk_74a);
		allcomplete <= 1;
		@(posedge clk_74a);
		allcomplete <= 0;
		repeat (4000) @(posedge clk_74a);

		rom_bad = 0;
		for (int i = 0; i < FWSZ / 4; i++)
			if (rom[i] !== {fw_byte(4 * i + 3), fw_byte(4 * i + 2), fw_byte(4 * i + 1), fw_byte(4 * i)}) rom_bad++;
		ps_bad = 0;
		if (!nomusic)
			for (int i = 0; i < ARSCSZ; i += 2) begin
				logic [15:0] h;
				h = chip.bd_read(0, i >> 1);
				if (h !== {cart_byte(128 + ROMSZ + i + 1), cart_byte(128 + ROMSZ + i)}) ps_bad++;
			end
		$display("result: seq_err=%0d lost=%0d overrun=%0d rom_bad=%0d ps_bad=%0d asset_size=%0d asset_ready=%0d fw_loaded=%0d fifo_max=%0d",
			seq_err, lost, overrun, rom_bad, ps_bad, asset_size, asset_ready, fw_loaded,
			loader.dcfifo_component.maxfill);
		$display("probe: foreign=%0d cart_late=%0d fw_late=%0d dropped=%0d t_pre=%0d fw_tail=%0d cart_tail=%0d word_min=%0d err_at=%03x",
			foreign, cart_late, fw_late, dropped, t_pre, fw_tail, cart_tail, word_min, err_at);
		$finish;
	end
endmodule
