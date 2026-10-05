//------------------------------------------------------------------------------
// BupChip write receiver, on clk_arm (docs/BUPCHIP_CORE.md, "Firmware load",
// "Capture" and "Reset and hold"; docs/DARIA_CORE.md, "Image capture"). Not
// held: downloads happen exactly while the CPU is held, so this keeps running
// whatever the hold is doing.
//
// bup_capture (clk_sys) holds each message in a register and flips a toggle.
// Two flops and a change detect see the toggle, and the message is copied at
// once into a one-entry buffer: the capture may replace its register 5 clk_sys
// clocks (10 clk_arm at 28.636 MHz) later, before a PSRAM write started from
// it would be done. Messages are handled in order:
//
//   START     clears asset_ready and img_ready, which hold the CPU (in the
//             BupChip's profile and in DARIA's) from the next clock
//   WRITE     goes to psram.sv as soon as the controller is idle. An image
//             mode WRITE below 128 KiB (halfword address < 65,536) also
//             writes the image window, in the same clock (win_we)
//   END       waits until the controller is idle after the last write. For
//             an A78 it then latches asset_size and sets asset_ready if it
//             is at least 4; for any other file it latches img_size =
//             min(size, 512 KiB) and sets img_ready if size is at least 8
//   FWSTART   clears fw_loaded, which holds the CPU, so ROM port B carries no
//             CPU reads while the firmware is written
//   FWWRITE   writes the word into the ROM through port B
//   FWEND     sets fw_loaded if at least 8 bytes arrived
//
// A released CPU can therefore never read a halfword or a word that has not
// been written. asset_ready, asset_size, img_ready, img_size, fw_loaded, the
// ROM and the window survive holds, console resets and PAL retunes: only a
// new download changes them. An image END leaves asset_size as it was, and an
// A78's END img_size; START has cleared both ready flags.
//
// The image window (32,768 x 32, the image's first 128 KiB) takes the
// halfword on both halves of win_wd, with win_be enabling its byte lanes in
// the half that halfword address bit 0 picks. Window port B belongs to the
// receiver while img_ready is low, as ROM port B does while fw_loaded is low;
// win_we is never high while img_ready is.
//
// The PSRAM is psram.sv (agg23, MIT) on die 0 of cram0, shared between these
// writes and the asset cache's fills. Writes win; the cache never fills while
// a download runs anyway, because START holds the CPU and with it the cache.
// A cache read still in flight when the hold came finishes on its own first.
// overrun (sticky) flags a message that arrived before the last was done;
// at the loader's rate the controller is busy 5 of every 10 or more clocks
// between writes, so simulation checks it stays low.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_asset_wr (
	input  wire         clk,            // clk_arm

	// From bup_capture (clk_sys): held message plus toggle.
	input  wire   [2:0] msg_type,
	input  wire  [43:0] msg_pl,         // layout: bup_capture.sv
	input  wire         msg_tog,

	output logic        asset_ready,
	output logic [23:0] asset_size,
	output logic        fw_loaded,
	output logic        img_ready,      // DARIA: an image of at least 8 bytes is in
	output logic [19:0] img_size,       // its bytes, at most 512 KiB

	// ROM port B (cache_ram_dp), the firmware's words; used while fw_loaded
	// is low.
	output logic        rom_we,
	output logic [11:0] rom_wa,
	output logic [31:0] rom_wd,

	// Image window port B, the image's halfwords below 128 KiB; high only
	// while img_ready is low.
	output logic        win_we,
	output logic [14:0] win_wa,         // word address
	output logic [31:0] win_wd,         // the halfword on both halves
	output logic  [3:0] win_be,

	// Fills from bup_asset_cache: one halfword read, taken on rd_ack.
	input  wire         rd_req,
	input  wire  [21:0] rd_addr,
	output logic        rd_ack,

	// psram.sv's user side. read_avail and data_out go to the cache.
	output logic        psram_bank_sel,
	output logic [21:0] psram_addr,
	output logic        psram_write_en,
	output logic [15:0] psram_data_in,
	output logic        psram_write_high_byte,
	output logic        psram_write_low_byte,
	output logic        psram_read_en,
	input  wire         psram_busy,

	output logic        overrun, // sticky: a message arrived before the last was done
	output wire         fw_start        // FWSTART handled (BUP_DEBUG's firmware check)
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial asset_ready = 1'b0;
	initial asset_size = 24'd0;
	initial fw_loaded = 1'b0;
	initial img_ready = 1'b0;
	initial img_size = 20'd0;
	initial overrun = 1'b0;
	// Message types (bup_capture.sv has the same list).
	localparam logic [2:0] M_START = 3'd1, M_WRITE = 3'd2, M_END = 3'd3;
	localparam logic [2:0] M_FWSTART = 3'd4, M_FWWRITE = 3'd5, M_FWEND = 3'd6;

	logic        t1 = 1'b0, t2 = 1'b0, seen = 1'b0;
	logic        m_v = 1'b0;
	logic  [2:0] m_type = 3'd0;
	logic [43:0] m_pl = 44'd0;

	wire new_msg = t2 != seen;
	wire m_wr    = m_v && m_type == M_WRITE;
	// A write, or END, needs the controller idle; everything else takes one clock.
	wire done    = m_v && (!(m_type == M_WRITE || m_type == M_END) || !psram_busy);

	always_ff @(posedge clk) begin
		t1 <= msg_tog;
		t2 <= t1;
		if (done) begin
			m_v <= 1'b0;
			case (m_type)
				M_START: begin
					asset_ready <= 1'b0;
					img_ready <= 1'b0;
				end
				M_END:
					if (m_pl[24]) begin	// an image
						img_size <= m_pl[23:19] != 5'd0 ? 20'h80000 : {1'b0, m_pl[18:0]};
						img_ready <= m_pl[23:0] >= 24'd8;
					end else begin	// an A78
						asset_size <= m_pl[23:0];
						asset_ready <= m_pl[23:0] >= 24'd4;
					end
				M_FWSTART: fw_loaded <= 1'b0;
				M_FWEND:   fw_loaded <= m_pl[14:0] >= 15'd8;
				default: ;
			endcase
		end
		if (new_msg) begin
			seen <= t2;
			if (m_v && !done) overrun <= 1'b1;
			m_v <= 1'b1;
			m_type <= msg_type;
			m_pl <= msg_pl;
		end
	end

	assign fw_start = done && m_type == M_FWSTART;
	assign rom_we = m_v && m_type == M_FWWRITE;
	assign rom_wa = m_pl[43:32];
	assign rom_wd = m_pl[31:0];

	// The window: with the PSRAM write, for an image mode WRITE below 128 KiB.
	assign win_we = psram_write_en && m_pl[40] && m_pl[37:32] == 6'd0 && !img_ready;
	assign win_wa = m_pl[31:17];
	assign win_wd = {m_pl[15:0], m_pl[15:0]};
	assign win_be = m_pl[16] ? {m_pl[39:38], 2'b00} : {2'b00, m_pl[39:38]};

	assign psram_bank_sel        = 1'b0;		// die 0 (ce0_n)
	assign psram_write_en        = m_wr && !psram_busy;
	assign psram_read_en         = rd_req && !psram_busy && !m_wr;
	assign rd_ack                = psram_read_en;
	assign psram_addr            = m_wr ? m_pl[37:16] : rd_addr;
	assign psram_data_in         = m_pl[15:0];
	assign psram_write_high_byte = m_pl[39];
	assign psram_write_low_byte  = m_pl[38];
endmodule

`default_nettype wire
