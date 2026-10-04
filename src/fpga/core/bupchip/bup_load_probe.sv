//------------------------------------------------------------------------------
// BupChip load probe, for BUP_DEBUG builds only (bup_status_osd.sv shows its
// counts; docs/BUPCHIP_CORE.md, "Macros and parameters"). On clk_sys, it
// watches every byte the loader delivers, with bits 27:25 of its bridge
// address (0 the cartridge slot, 5 bupchip.bin), and the capture's windows
// (bup_capture.sv, "Which bytes are the BupChip's"), and records what the
// host did around the slot switches. Every count saturates; all are kept
// from power-up, the times are the latest download's.
//
//   foreign    bytes carrying another slot's address while the cartridge or
//              firmware flag was up (the bytes the slot flags used to hand
//              to the wrong download)
//   cart_late  cartridge bytes taken after its flag fell (up to load_end)
//   fw_late    firmware bytes taken after fw_download fell
//   dropped    cartridge or firmware bytes outside their windows: lost
//   t_pre      clk_sys clocks from the last byte before fw_download rose
//              to the rise
//   fw_tail    clk_sys clocks from fw_download falling to its last byte
//              (0: none came after)
//   cart_tail  the same for the cartridge, from load_end
//   word_min   fewest clk_sys clocks between two words of bupchip.bin
//   err_at     the first byte that set seq_err: bits 27:25 of its address,
//              then bits 8:0
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_load_probe (
	input  wire        clk,             // clk_sys
	input  wire        byte_wr,         // every byte the loader delivers
	input  wire  [2:0] byte_hi,         // bits 27:25 of its bridge address
	input  wire [24:0] byte_addr,       // bits 24:0
	input  wire        load_start,
	input  wire        load_end,
	input  wire        fw_download,
	input  wire        cart_win,        // bup_capture's windows
	input  wire        fw_win,
	input  wire        seq_err,

	output logic  [7:0] foreign,
	output logic  [5:0] cart_late,
	output logic  [5:0] fw_late,
	output logic [11:0] dropped,
	output logic [11:0] t_pre,
	output logic [11:0] fw_tail,
	output logic [11:0] cart_tail,
	output logic [11:0] word_min,
	output logic [11:0] err_at
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial foreign = 8'd0;
	initial cart_late = 6'd0;
	initial fw_late = 6'd0;
	initial dropped = 12'd0;
	initial t_pre = 12'd0;
	initial fw_tail = 12'd0;
	initial cart_tail = 12'd0;
	initial word_min = 12'hFFF;
	initial err_at = 12'd0;
	logic        c_flag = 1'b0, fw_q = 1'b0, seq_q = 1'b0;
	logic [11:0] since_byte = 12'hFFF, since_ffall = 12'd0, since_cend = 12'd0, since_word = 12'hFFF;
	logic  [2:0] last_hi = 3'd0;
	logic  [8:0] last_lo = 9'd0;
	logic        first_word = 1'b0;

	wire is_cart = byte_wr && byte_hi == 3'd0;
	wire is_fw   = byte_wr && byte_hi == 3'd5;
	wire fw_rise = fw_download && !fw_q;

	function automatic logic [11:0] inc12(input logic [11:0] v);
		return &v ? v : v + 12'd1;
	endfunction

	always_ff @(posedge clk) begin
		fw_q <= fw_download;
		seq_q <= seq_err;
		if (load_start) c_flag <= 1'b1;
		else if (load_end) c_flag <= 1'b0;

		since_byte  <= byte_wr ? 12'd0 : inc12(since_byte);
		since_ffall <= fw_download ? 12'd0 : inc12(since_ffall);
		since_cend  <= c_flag ? 12'd0 : inc12(since_cend);
		since_word  <= inc12(since_word);

		if (byte_wr && ((c_flag && byte_hi != 3'd0) || (fw_download && byte_hi != 3'd5)) && !(&foreign))
			foreign <= foreign + 8'd1;
		if (is_cart && cart_win && !c_flag) begin
			if (!(&cart_late)) cart_late <= cart_late + 6'd1;
			cart_tail <= since_cend;
		end
		if (is_fw && fw_win && !fw_download) begin
			if (!(&fw_late)) fw_late <= fw_late + 6'd1;
			fw_tail <= since_ffall;
		end
		if (((is_cart && !cart_win) || (is_fw && (!fw_win || byte_addr[24:14] != 11'd0))) && !(&dropped))
			dropped <= dropped + 12'd1;

		if (load_start) cart_tail <= 12'd0;
		if (fw_rise) begin
			t_pre <= since_byte;
			fw_tail <= 12'd0;
			word_min <= 12'hFFF;
			first_word <= 1'b1;
		end
		if (is_fw && fw_download && byte_addr[1:0] == 2'd0) begin
			since_word <= 12'd0;
			first_word <= 1'b0;
			if (!first_word && !fw_rise && since_word < word_min) word_min <= since_word;
		end

		if (byte_wr) begin
			last_hi <= byte_hi;
			last_lo <= byte_addr[8:0];
		end
		if (seq_err && !seq_q) err_at <= {last_hi, last_lo};
	end
endmodule

`default_nettype wire
