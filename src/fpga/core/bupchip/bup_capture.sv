//------------------------------------------------------------------------------
// BupChip capture, on clk_sys (docs/BUPCHIP_CORE.md, "Firmware load" and
// "Capture"): what the loader delivers for the BupChip, turned into one
// ordered message stream for bup_asset_wr on clk_arm.
//
// Cartridge slot. The ARSC block starts at 128 + the ROM size the A78 header
// declares in bytes 49-52 (big-endian); that parse is copied from upstream's
// bupchip_asset_ddr.sv (MIT, Copyright (c) 2026 Jamie Blanks). Block byte b
// belongs to PSRAM halfword b >> 1, low byte when b is even. Bytes are packed
// in pairs; an odd tail is written with its low byte lane only. Bytes past
// 8 MiB (the PSRAM die) are dropped; the cartridge slot holds 4 MiB, so none
// ever are.
//
// Firmware slot (bupchip.bin). Bytes are packed four to a little-endian word,
// word w holding bytes 4w..4w+3. A trailing partial word is zero-padded, and
// bytes past 16 KiB (the ROM window) are dropped.
//
// Messages, in order (payload msg_pl):
//
//   START     at load_start
//   WRITE     one per halfword: [39] upper byte lane, [38] lower byte lane,
//             [37:16] halfword address, [15:0] the halfword
//   END       after load_end: [23:0] asset_size, the bytes captured
//   FWSTART   when fw_download rises
//   FWWRITE   one per word: [43:32] word address, [31:0] the word
//   FWEND     when fw_download falls: [14:0] the bytes captured (<= 16,384)
//
// Each message is held in msg_type / msg_pl and announced by flipping msg_tog;
// the receiver copies it when it sees the change. Consecutive messages are at
// least 5 clk_sys clocks (349 ns) apart, which bup_asset_wr needs. The loader
// delivers a byte at most every 2.5 clk_sys (10 clk_sdram, data_loader.sv), so
// a pair completes at most every 5 clocks and a word every 10.
//
// A WRITE goes out in the clock its last byte arrives. Nothing else is
// waiting then: the block's first byte comes at least 129 bytes (320 clocks)
// after load_start, long after START and anything a firmware download just
// before had left waiting. Every other message waits in a flag for the
// spacing, and they leave in this order of priority: FWSTART, FWWRITE, START,
// the firmware's tail FWWRITE, the cartridge's tail WRITE, FWEND, END. An
// FWWRITE's word waits in fwword_pl, at most 9 clocks: the firmware slot can
// start straight after a cartridge, while that cartridge's tail WRITE and END
// still wait, so sending FWWRITE at once could break the spacing. A load_start drops what
// the previous cartridge download still had waiting, and a new firmware
// download what the previous firmware download had: the receiver's START or
// FWSTART withdraws the old contents anyway. A firmware byte may arrive in the
// clock fw_download rises; it starts the new download's first word.
//
// The download is sequential, as data_loader.sv delivers it. seq_err
// (sticky) flags a byte that breaks the pairing, and lost a WRITE that had to
// go out less than 5 clocks after the message before it, or a firmware word
// that completed while the one before still waited (either is the loader
// faster than its 2.5 clk_sys per byte); simulation checks both stay low.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_capture (
	input  wire        clk,             // clk_sys

	// Cartridge download (atari7800_pocket.sv's mapper_load_* expressions).
	input  wire        load_start,      // one clock as the download starts
	input  wire [24:0] load_addr,       // file offset, header included
	input  wire        load_valid,      // one clock per cartridge byte
	input  wire  [7:0] load_data,
	input  wire        load_end,        // one clock after the download ends

	// Firmware slot download: the slot's download flag, and one clock per
	// byte at load_addr / load_data.
	input  wire        fw_download,
	input  wire        fw_valid,

	// To bup_asset_wr: held message plus toggle.
	output logic  [2:0] msg_type = 3'd0,
	output logic [43:0] msg_pl = 44'd0,
	output logic        msg_tog = 1'b0,

	output logic        seq_err = 1'b0, // sticky: a byte out of order
	output logic        lost = 1'b0     // sticky: the loader outran the message stream
);
	// Message types (bup_asset_wr.sv has the same list).
	localparam logic [2:0] M_START = 3'd1, M_WRITE = 3'd2, M_END = 3'd3;
	localparam logic [2:0] M_FWSTART = 3'd4, M_FWWRITE = 3'd5, M_FWEND = 3'd6;

	// ---- the A78 header's declared ROM size (bupchip_asset_ddr.sv:82-104) ----
	// It comes from the header bytes as they stream past: the core's own
	// cart_size is still counting while the download runs.
	logic [31:0] declared_size = 32'd0;
	always_ff @(posedge clk) begin
		if (load_start)
			declared_size <= 32'b0;
		else if (load_valid) begin
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
	wire        in_block = load_valid && |declared_size && load_addr >= asset_start;
	wire [24:0] off = load_addr - asset_start;
	wire        a_byte = in_block && off[24:23] == 2'd0;	// within the 8 MiB die
	wire        a_pair = a_byte && off[0];				// a halfword completes

	// Cartridge: the even byte waiting for its partner, and the size so far.
	// The tail's halfword is size >> 1: the last byte was the even one.
	logic        have_lo = 1'b0;
	logic  [7:0] lo = 8'd0;
	logic [23:0] size = 24'd0;

	// Firmware: the word's first three bytes, and the byte count. The tail
	// word is (fw_count - 1) >> 2.
	logic        fw_q = 1'b0;
	logic        fw_have = 1'b0;
	logic [23:0] fw_word = 24'd0;
	logic [14:0] fw_count = 15'd0;
	wire         fw_rise = fw_download && !fw_q;
	wire         fw_fall = !fw_download && fw_q;
	wire         f_byte = fw_valid && load_addr[24:14] == 11'd0;
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
	// Flags for the ones that wait; WRITE goes out as it completes.
	logic p_start = 1'b0, p_tail = 1'b0, p_end = 1'b0;
	logic p_fwstart = 1'b0, p_fwword = 1'b0, p_fwtail = 1'b0, p_fwend = 1'b0;
	logic [43:0] fwword_pl = 44'd0;	// the FWWRITE waiting in p_fwword
	logic [2:0] gap = 3'd4;			// clocks since the last message, up to 4
	wire  can_send = gap == 3'd4;
	wire  direct = a_pair;
	logic [2:0] s_type;
	always_comb begin
		if      (p_fwstart) s_type = M_FWSTART;
		else if (p_fwword)  s_type = M_FWWRITE;
		else if (p_start)   s_type = M_START;
		else if (p_fwtail)  s_type = M_FWWRITE;
		else if (p_tail)    s_type = M_WRITE;
		else if (p_fwend)   s_type = M_FWEND;
		else if (p_end)     s_type = M_END;
		else                s_type = 3'd0;
	end
	wire queued = can_send && !direct && s_type != 3'd0;
	wire send_fwword = queued && !p_fwstart && p_fwword;

	always_ff @(posedge clk) begin
		fw_q <= fw_download;
		gap <= (direct || queued) ? 3'd0 : (can_send ? gap : gap + 3'd1);

		if (direct) begin
			if (!can_send) lost <= 1'b1;
			msg_tog <= ~msg_tog;
			msg_type <= M_WRITE;
			msg_pl <= {4'd0, 1'b1, have_lo, off[22:1], load_data, have_lo ? lo : 8'd0};
		end else if (queued) begin
			msg_type <= s_type;
			msg_tog <= ~msg_tog;
			msg_pl <= 44'd0;
			if (p_fwstart) p_fwstart <= 1'b0;
			else if (p_fwword) begin
				p_fwword <= 1'b0;
				msg_pl <= fwword_pl;
			end else if (p_start) p_start <= 1'b0;
			else if (p_fwtail) begin
				p_fwtail <= 1'b0;
				fw_have <= 1'b0;
				msg_pl <= {fw_last[13:2], 8'd0, fw_word};
			end else if (p_tail) begin
				p_tail <= 1'b0;
				have_lo <= 1'b0;
				msg_pl <= {4'd0, 2'b01, size[22:1], 8'd0, lo};
			end else if (p_fwend) begin
				p_fwend <= 1'b0;
				msg_pl <= {29'd0, fw_count};
			end else begin
				p_end <= 1'b0;
				msg_pl <= {20'd0, size};
			end
		end

		// Cartridge bytes (after the sends: a flag set in the clock it is
		// sent stays set).
		if (load_start) begin
			p_start <= 1'b1;
			p_tail <= 1'b0;
			p_end <= 1'b0;
			have_lo <= 1'b0;
			size <= 24'd0;
		end else begin
			if (a_byte) begin
				size <= off[23:0] + 24'd1;
				if (have_lo != off[0]) seq_err <= 1'b1;	// two even or two odd bytes running
				have_lo <= !off[0];
				lo <= load_data;
			end
			if (load_end) begin
				p_tail <= have_lo;
				p_end <= 1'b1;
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
		if (fw_fall) begin
			// A byte in the falling clock counts: it either completed a word
			// (sent above, no tail) or left a partial one.
			p_fwtail <= f_byte ? !f_word : fw_have;
			p_fwend <= 1'b1;
		end
	end

`ifndef ALTERA_RESERVED_QIS
	// Simulation: every byte must follow the one before it.
	logic [24:0] exp_off = 25'd0, exp_fw = 25'd0;
	logic        seq_sim = 1'b0;
	always_ff @(posedge clk) begin
		if (load_start) exp_off <= 25'd0;
		else if (a_byte) begin
			if (off != exp_off) seq_sim <= 1'b1;
			exp_off <= off + 25'd1;
		end
		if (fw_valid) begin
			if (load_addr != (fw_rise ? 25'd0 : exp_fw)) seq_sim <= 1'b1;
			exp_fw <= load_addr + 25'd1;
		end else if (fw_rise) exp_fw <= 25'd0;
	end
`endif
endmodule

`default_nettype wire
