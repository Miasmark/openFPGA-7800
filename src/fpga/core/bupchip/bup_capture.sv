//------------------------------------------------------------------------------
// BupChip capture, on clk_sys (docs/BUPCHIP_CORE.md, "Firmware load" and
// "Capture"; docs/DARIA_CORE.md, "Image capture"): what the loader delivers
// for the BupChip and for DARIA, turned into one ordered message stream for
// bup_asset_wr on clk_arm.
//
// Cartridge slot. Bytes 1-5 are compared with "ATARI", as atari7800_pocket.sv
// does for cart_is_7800, and pick one of two modes:
//
//   A78 (ARSC mode). The ARSC block starts at 128 + the ROM size the A78
//   header declares in bytes 49-52 (big-endian); that parse is copied from
//   upstream's bupchip_asset_ddr.sv (MIT, Copyright (c) 2026 Jamie Blanks).
//   Block byte b belongs to PSRAM halfword b >> 1, low byte when b is even.
//   Bytes past 8 MiB (the PSRAM die) are dropped; the cartridge slot holds
//   4 MiB, so none ever are.
//
//   Image mode, any other file (a 2600 image for DARIA). File byte b belongs
//   to PSRAM halfword b >> 1, from offset 0. Bytes at or past 512 KiB, DARIA's
//   largest image, are dropped (they still count in the size).
//
// In both, bytes are packed in pairs, and an odd tail is written with its low
// byte lane only. The mode is known at byte 5, so bytes 0-5 wait in head: in
// image mode they leave as three WRITEs (the head) once the mode is known; in
// A78 mode they are not sent (the ARSC block starts at 128 or later). A file
// that ends before byte 5 is in image mode, and its head leaves when the
// window closes.
//
// Firmware slot (bupchip.bin). Bytes are packed four to a little-endian word,
// word w holding bytes 4w..4w+3. A trailing partial word is zero-padded, and
// bytes past 16 KiB (the ROM window) are dropped.
//
// Which bytes are the BupChip's. Every byte carries its own bridge address,
// and the slots' addresses differ in bits 27:25 (data.json): the cartridge
// 0x00000000 is 0, bupchip.bin 0x0A000000 is 5. load_valid and fw_valid are
// the bytes carrying those (atari7800_pocket.sv), whatever slot flag is up,
// and each download takes them while its window is open: from load_start,
// or fw_download rising, until DRAIN clocks after load_end, or the flag
// falling. The flags change when the host's requestwrite or allcomplete
// reaches core_top, which can be before the loader has delivered the last
// word of the slot before: its FIFO and read machine hold up to four bytes
// for 40 clk_sdram (10 clk_sys) or so. Taking bytes by the slot flag gave
// those bytes to the wrong download (README.md in sim/bupchip/s4/stress,
// "Slot switches"); taking them by address and closing the window late
// gives each byte to its own. 64 clocks (4.5 us) is several times the
// loader's drain.
//
// Messages, in order (payload msg_pl):
//
//   START     at load_start
//   WRITE     one per halfword: [40] image mode (bup_asset_wr also writes
//             the image window), [39] upper byte lane, [38] lower byte lane,
//             [37:16] halfword address, [15:0] the halfword
//   END       when the cartridge window closes: [24] image (the file is not
//             an A78: is_a78 = ~[24]), [23:0] the size: for an A78 the bytes
//             of the ARSC block captured (asset_size), for an image the
//             file's bytes, all of them (16,777,215 at most)
//   FWSTART   when fw_download rises
//   FWWRITE   one per word: [43:32] word address, [31:0] the word
//   FWEND     when the firmware window closes: [14:0] the bytes captured
//             (<= 16,384)
//
// For an A78 file and for the firmware the stream is the BupChip's before
// DARIA, bit for bit: the image bits are 0, and the head is not sent.
//
// Each message is held in msg_type / msg_pl and announced by flipping msg_tog;
// the receiver copies it when it sees the change. Consecutive messages are at
// least 5 clk_sys clocks (349 ns) apart, which bup_asset_wr needs. The loader
// delivers a byte at most every 2.5 clk_sys (10 clk_sdram, data_loader.sv), so
// a pair completes at most every 5 clocks and a word every 10.
//
// Every message waits in a flag for the spacing, and they leave in this order
// of priority: WRITE, FWSTART, FWWRITE, START, the firmware's tail FWWRITE,
// the cartridge's head WRITEs, its tail WRITE, FWEND, END. WRITE and FWWRITE
// each wait with their payload in a register (write_pl, fwword_pl): a WRITE
// at most 4 clocks, as nothing goes before it, an FWWRITE at most 9. The head
// takes the slots the WRITEs leave free: none while the loader runs at full
// rate, so then it leaves after the file. A cartridge's last bytes can arrive
// after the firmware slot has started (the window above), so a WRITE can find
// another message just sent. A load_start drops the head, tail and END the
// previous cartridge download still had waiting, and a new firmware download
// what the previous firmware download had: the receiver's START or FWSTART
// withdraws the old contents anyway. A firmware byte may arrive in the clock
// fw_download rises; it starts the new download's first word.
//
// START leaves before the first WRITE of its download: the head waits behind
// it, and the first other WRITE completes with byte 7, at least 17 clocks
// after load_start. By then at most the previous cartridge's last WRITE, an
// FWSTART and one or two FWWRITEs from the firmware bytes the loader still
// held can have gone first (simulation flags a halfword that completes while
// START waits, start_sim).
//
// The download is sequential, as data_loader.sv delivers it. seq_err
// (sticky) flags a byte that breaks the pairing, and lost a halfword or word
// that completed while the one before still waited (the loader faster than
// its 2.5 clk_sys per byte); simulation checks both stay low.
// cart_win and fw_win are the windows, for BUP_DEBUG's probe.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_capture (
	input  wire        clk,             // clk_sys

	// Cartridge download (atari7800_pocket.sv's mapper_load_* expressions).
	input  wire        load_start,      // one clock as the download starts
	input  wire [24:0] load_addr,       // file offset, header included
	input  wire        load_valid,      // one clock per byte at the cartridge slot's address
	input  wire  [7:0] load_data,
	input  wire        load_end,        // one clock after the download ends

	// Firmware slot download: the slot's download flag, and one clock per
	// byte at its address, with load_addr / load_data.
	input  wire        fw_download,
	input  wire        fw_valid,

	// To bup_asset_wr: held message plus toggle.
	output logic  [2:0] msg_type,
	output logic [43:0] msg_pl,
	output logic        msg_tog,

	output logic        seq_err, // sticky: a byte out of order
	output logic        lost,    // sticky: the loader outran the message stream
	output wire         cart_win,       // the windows (BUP_DEBUG's probe)
	output wire         fw_win
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial msg_type = 3'd0;
	initial msg_pl = 44'd0;
	initial msg_tog = 1'b0;
	initial seq_err = 1'b0;
	initial lost = 1'b0;
	// Message types (bup_asset_wr.sv has the same list).
	localparam logic [2:0] M_START = 3'd1, M_WRITE = 3'd2, M_END = 3'd3;
	localparam logic [2:0] M_FWSTART = 3'd4, M_FWWRITE = 3'd5, M_FWEND = 3'd6;
	localparam logic [6:0] DRAIN = 7'd64;

	// ---- windows ----------------------------------------------------------------------
	// Open from the start until DRAIN clocks after the end; each closes in the
	// clock its count reaches 1, taking no byte then.
	logic       c_open = 1'b0, fw_q = 1'b0;
	logic [6:0] c_drain = 7'd0, f_drain = 7'd0;
	wire        fw_rise = fw_download && !fw_q;
	wire        fw_fall = !fw_download && fw_q;
	assign      cart_win = load_start || c_open || c_drain > 7'd1;
	assign      fw_win = fw_download || fw_q || f_drain > 7'd1;
	wire        c_close = c_drain == 7'd1;
	wire        f_close = f_drain == 7'd1 && !fw_rise;
	wire        c_valid = load_valid && cart_win;
	always_ff @(posedge clk) begin
		fw_q <= fw_download;
		if (load_start) begin
			c_open <= 1'b1;
			c_drain <= 7'd0;
		end else if (load_end && c_open) begin
			c_open <= 1'b0;
			c_drain <= DRAIN;
		end else if (c_drain != 7'd0)
			c_drain <= c_drain - 7'd1;
		if (fw_rise)
			f_drain <= 7'd0;
		else if (fw_fall)
			f_drain <= DRAIN;
		else if (f_drain != 7'd0)
			f_drain <= f_drain - 7'd1;
	end

	// ---- the A78 gate (atari7800_pocket.sv's cart_header) -----------------------------
	// h_match: bytes 1 up to the last one seen match "ATAR" so far. At byte 5
	// the mode is known (g_known), and g_a78 picks ARSC mode.
	logic        h_match = 1'b0, g_known = 1'b0, g_a78 = 1'b0;
	logic [47:0] head = 48'd0;	// bytes 0-5, little-endian
	wire         h_byte = c_valid && load_addr < 25'd6;
	wire         h_last = h_byte && load_addr[2:0] == 3'd5;
	wire         a78_now = h_match && load_data == "I";	// with h_last
	wire         img_on = g_known && !g_a78;
	always_ff @(posedge clk) begin
		if (load_start) begin
			h_match <= 1'b0;
			g_known <= 1'b0;
			g_a78 <= 1'b0;
		end else if (h_byte) begin
			case (load_addr[2:0])
				3'd0: head[7:0] <= load_data;
				3'd1: begin head[15:8] <= load_data; h_match <= load_data == "A"; end
				3'd2: begin head[23:16] <= load_data; h_match <= h_match && load_data == "T"; end
				3'd3: begin head[31:24] <= load_data; h_match <= h_match && load_data == "A"; end
				3'd4: begin head[39:32] <= load_data; h_match <= h_match && load_data == "R"; end
				default: begin
					head[47:40] <= load_data;
					g_known <= 1'b1;
					g_a78 <= a78_now;
				end
			endcase
		end
	end

	// ---- the A78 header's declared ROM size (bupchip_asset_ddr.sv:82-104) ----
	// It comes from the header bytes as they stream past: the core's own
	// cart_size is still counting while the download runs.
	logic [31:0] declared_size = 32'd0;
	always_ff @(posedge clk) begin
		if (load_start)
			declared_size <= 32'b0;
		else if (c_valid) begin
			case (load_addr)
				25'd49: declared_size[31:24] <= load_data;
				25'd50: declared_size[23:16] <= load_data;
				25'd51: declared_size[15:8]  <= load_data;
				25'd52: declared_size[7:0]   <= load_data;
				default: ;
			endcase
		end
	end
	wire [24:0] asset_start = declared_size[24:0] + 25'd128;
	wire        in_block = c_valid && g_a78 && |declared_size && load_addr >= asset_start;
	wire [24:0] off = load_addr - asset_start;
	wire        r_byte = in_block && off[24:23] == 2'd0;		// ARSC: within the 8 MiB die
	wire        i_byte = c_valid && img_on && load_addr[24:19] == 6'd0;	// image: below 512 KiB

	// A byte for the PSRAM in either mode, at offset a_off there.
	wire [22:0] a_off = g_a78 ? off[22:0] : load_addr[22:0];
	wire        a_byte = r_byte || i_byte;
	wire        a_pair = a_byte && a_off[0];				// a halfword completes
	// The file's size, for image mode's END (saturating).
	wire [23:0] f_size = load_addr[24] || &load_addr[23:0] ? 24'hFFFFFF : load_addr[23:0] + 24'd1;

	// Cartridge: the even byte waiting for its partner, and the size so far:
	// the block's bytes in A78 mode, the file's otherwise (and until byte 5).
	// The tail's halfword is size >> 1: the last byte was the even one.
	logic        have_lo = 1'b0;
	logic  [7:0] lo = 8'd0;
	logic [23:0] size = 24'd0;

	// Firmware: the word's first three bytes, and the byte count. The tail
	// word is (fw_count - 1) >> 2.
	logic        fw_have = 1'b0;
	logic [23:0] fw_word = 24'd0;
	logic [14:0] fw_count = 15'd0;
	wire         f_byte = fw_valid && fw_win && load_addr[24:14] == 11'd0;
	wire         f_word = f_byte && load_addr[1:0] == 2'd3;	// a word completes
	wire         f_have = fw_have && !fw_rise;	// a rise starts a new word
	logic [23:0] fw_next;
	always_comb begin
		fw_next = f_have ? fw_word : 24'd0;
		case (load_addr[1:0])
			2'd0: fw_next[7:0] = load_data;
			2'd1: fw_next[15:8] = load_data;
			2'd2: fw_next[23:16] = load_data;
			default: ;
		endcase
	end
	wire  [13:0] fw_last = fw_count[13:0] - 14'd1;

	// ---- messages ---------------------------------------------------------------------
	logic p_write = 1'b0, p_start = 1'b0, p_head = 1'b0, p_tail = 1'b0, p_end = 1'b0;
	logic p_fwstart = 1'b0, p_fwword = 1'b0, p_fwtail = 1'b0, p_fwend = 1'b0;
	logic [43:0] write_pl = 44'd0;	// the WRITE waiting in p_write
	logic [43:0] fwword_pl = 44'd0;	// the FWWRITE waiting in p_fwword
	logic [2:0] gap = 3'd4;			// clocks since the last message, up to 4
	wire  can_send = gap == 3'd4;

	// The head: halfword h_idx of bytes 0-5 waits in p_head. h_n is the
	// number of head bytes that came (6, or the size of a shorter file).
	logic  [1:0] h_idx = 2'd0;
	wire   [2:0] h_n = g_known ? 3'd6 : size[2:0];
	wire         h_hi = {h_idx, 1'b1} < h_n;	// its odd byte came
	logic [15:0] h_hw;
	always_comb begin
		case (h_idx)
			2'd0:    h_hw = head[15:0];
			2'd1:    h_hw = head[31:16];
			default: h_hw = head[47:32];
		endcase
	end

	logic [2:0] s_type;
	always_comb begin
		if      (p_write)   s_type = M_WRITE;
		else if (p_fwstart) s_type = M_FWSTART;
		else if (p_fwword)  s_type = M_FWWRITE;
		else if (p_start)   s_type = M_START;
		else if (p_fwtail)  s_type = M_FWWRITE;
		else if (p_head)    s_type = M_WRITE;
		else if (p_tail)    s_type = M_WRITE;
		else if (p_fwend)   s_type = M_FWEND;
		else if (p_end)     s_type = M_END;
		else                s_type = 3'd0;
	end
	wire queued = can_send && s_type != 3'd0;
	wire send_write = queued && p_write;
	wire send_fwword = queued && !p_write && !p_fwstart && p_fwword;

	always_ff @(posedge clk) begin
		gap <= queued ? 3'd0 : (can_send ? gap : gap + 3'd1);

		if (queued) begin
			msg_type <= s_type;
			msg_tog <= ~msg_tog;
			msg_pl <= 44'd0;
			if (p_write) begin
				p_write <= 1'b0;
				msg_pl <= write_pl;
			end else if (p_fwstart) p_fwstart <= 1'b0;
			else if (p_fwword) begin
				p_fwword <= 1'b0;
				msg_pl <= fwword_pl;
			end else if (p_start) p_start <= 1'b0;
			else if (p_fwtail) begin
				p_fwtail <= 1'b0;
				fw_have <= 1'b0;
				msg_pl <= {fw_last[13:2], 8'd0, fw_word};
			end else if (p_head) begin
				h_idx <= h_idx + 2'd1;
				p_head <= {h_idx + 2'd1, 1'b0} < h_n;	// the next halfword's even byte came
				msg_pl <= {4'd1, h_hi, 1'b1, 20'd0, h_idx, h_hi ? h_hw[15:8] : 8'd0, h_hw[7:0]};
			end else if (p_tail) begin
				p_tail <= 1'b0;
				have_lo <= 1'b0;
				msg_pl <= {3'd0, img_on, 2'b01, size[22:1], 8'd0, lo};
			end else if (p_fwend) begin
				p_fwend <= 1'b0;
				msg_pl <= {29'd0, fw_count};
			end else begin
				p_end <= 1'b0;
				msg_pl <= {19'd0, !g_a78, size};
			end
		end

		// Cartridge bytes (after the sends: a flag set in the clock it is
		// sent stays set).
		if (load_start) begin
			p_start <= 1'b1;
			p_head <= 1'b0;
			p_tail <= 1'b0;
			p_end <= 1'b0;
			have_lo <= 1'b0;
			size <= 24'd0;
		end else begin
			if (r_byte)
				size <= off[23:0] + 24'd1;
			else if (c_valid && !g_a78)	// image mode, or the mode not yet known
				size <= h_last && a78_now ? 24'd0 : f_size;
			if (a_byte) begin
				if (have_lo != a_off[0]) seq_err <= 1'b1;	// two even or two odd bytes running
				have_lo <= !a_off[0];
				lo <= load_data;
			end
			if (a_pair) begin
				if (p_write && !send_write) lost <= 1'b1;	// the last halfword still waits
				p_write <= 1'b1;
				write_pl <= {3'd0, img_on, 1'b1, have_lo, a_off[22:1], load_data, have_lo ? lo : 8'd0};
			end
			if (h_last && !a78_now) begin	// image mode: bytes 0-5 can go
				p_head <= 1'b1;
				h_idx <= 2'd0;
			end
			if (c_close) begin
				p_tail <= have_lo;
				p_end <= 1'b1;
				if (!g_known && size != 24'd0) begin	// a file shorter than 6 bytes
					p_head <= 1'b1;
					h_idx <= 2'd0;
				end
			end
		end

		// Firmware bytes (a byte in the clock fw_download rises belongs to the
		// new download).
		if (fw_rise) begin
			p_fwstart <= 1'b1;
			p_fwword <= 1'b0;
			p_fwtail <= 1'b0;
			p_fwend <= 1'b0;
			fw_have <= 1'b0;
			fw_count <= 15'd0;
		end
		if (f_byte) begin
			fw_count <= {1'b0, load_addr[13:0]} + 15'd1;
			if (f_have == (load_addr[1:0] == 2'd0)) seq_err <= 1'b1;
			fw_have <= !f_word;
			fw_word <= fw_next;
			if (f_word) begin
				if (p_fwword && !send_fwword && !fw_rise) lost <= 1'b1;	// the last word still waits
				p_fwword <= 1'b1;
				fwword_pl <= {load_addr[13:2], load_data, fw_next};
			end
		end
		if (f_close) begin
			p_fwtail <= fw_have;	// a partial word; the window took no byte this clock
			p_fwend <= 1'b1;
		end
	end

`ifndef ALTERA_RESERVED_QIS
	// Simulation: every byte must follow the one before it: the ARSC block's
	// bytes in A78 mode, and every byte of the file until the mode is known
	// and in image mode. start_sim: a halfword completed while its START
	// still waited.
	logic [24:0] exp_off = 25'd0, exp_fw = 25'd0, exp_img = 25'd0;
	logic        seq_sim = 1'b0, start_sim = 1'b0;
	always_ff @(posedge clk) begin
		if (load_start) begin
			exp_off <= 25'd0;
			exp_img <= 25'd0;
		end else begin
			if (r_byte) begin
				if (off != exp_off) seq_sim <= 1'b1;
				exp_off <= off + 25'd1;
			end
			if (c_valid && !g_a78) begin
				if (load_addr != exp_img) seq_sim <= 1'b1;
				exp_img <= load_addr + 25'd1;
			end
			if (a_pair && p_start) start_sim <= 1'b1;
		end
		if (fw_valid && fw_win) begin
			if (load_addr != (fw_rise ? 25'd0 : exp_fw)) seq_sim <= 1'b1;
			exp_fw <= load_addr + 25'd1;
		end else if (fw_rise) exp_fw <= 25'd0;
	end
`endif
endmodule

`default_nettype wire
