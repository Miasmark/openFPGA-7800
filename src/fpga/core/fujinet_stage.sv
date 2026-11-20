// FujiNet staging, the clk_sys side (docs/FUJINET_GAME_LOADING.md, 3.2).
//
// fujinet_mailbox.sv hands over a pushed image a byte at a time, in order
// from offset 0; this packs the bytes into halfwords and sends each to
// bup_asset_wr.sv on clk_arm as a WRITE, then a SYNC when asked. One message
// at a time: the payload is held from the toggle until s_ack (clk_arm, two
// flops here) answers, so the receiver can take it at its leisure. busy
// holds the mailbox's next byte while a WRITE is out. A file of odd length
// ends with a WRITE of its low byte lane alone, sent before the SYNC.
// synced pulses once the SYNC is answered: every byte is then in the PSRAM.
//
// SPDX-License-Identifier: MIT
module fujinet_stage (
	input  logic        clk,         // clk_sys
	input  logic        start,       // a new image: forget a half halfword
	input  logic        we,
	input  logic [19:0] addr,        // the byte's file offset
	input  logic  [7:0] data,
	input  logic        sync,
	output logic        busy,
	output logic        synced,

	// to bup_asset_wr (clk_arm)
	output logic        s_tog,
	output logic        s_sync,
	output logic  [1:0] s_lanes,
	output logic [18:0] s_haddr,
	output logic [15:0] s_data,
	input  logic        s_ack
);

/* verilator lint_off PROCASSINIT */
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
logic        a1 = 1'b0;
logic        a2 = 1'b0;
logic        out = 1'b0;          // a message is out, not yet answered
logic        have_lo = 1'b0;      // the even byte of a halfword waits
logic  [7:0] lo = 8'd0;
logic [18:0] lo_ha = 19'd0;
logic        sync_p = 1'b0;       // a SYNC to send once the tail is out
logic        sync_out = 1'b0;     // the message out is the SYNC
initial begin
	s_tog = 1'b0; s_sync = 1'b0; s_lanes = 2'd0; s_haddr = 19'd0; s_data = 16'd0;
end
/* verilator lint_on PROCASSINIT */

wire answered = out && a2 == s_tog;
assign busy = out || sync_p;

always_ff @(posedge clk) begin
	a1 <= s_ack;
	a2 <= a1;
	synced <= 1'b0;
	if (answered) begin
		out <= 1'b0;
		if (sync_out) begin
			sync_out <= 1'b0;
			synced <= 1'b1;
		end
	end
	if (start) begin
		have_lo <= 1'b0;
		sync_p <= 1'b0;
	end else if (we) begin
		if (!addr[0]) begin
			have_lo <= 1'b1;
			lo <= data;
			lo_ha <= addr[19:1];
		end else begin
			// a halfword: out now (busy kept the mailbox waiting until free)
			have_lo <= 1'b0;
			s_sync <= 1'b0;
			s_lanes <= {1'b1, have_lo};
			s_haddr <= addr[19:1];
			s_data <= {data, have_lo ? lo : 8'd0};
			s_tog <= ~s_tog;
			out <= 1'b1;
		end
	end
	if (sync)
		sync_p <= 1'b1;
	if (sync_p && !out && !answered && !start) begin
		if (have_lo) begin
			// the tail: the low byte alone
			have_lo <= 1'b0;
			s_sync <= 1'b0;
			s_lanes <= 2'b01;
			s_haddr <= lo_ha;
			s_data <= {8'd0, lo};
		end else begin
			sync_p <= 1'b0;
			sync_out <= 1'b1;
			s_sync <= 1'b1;
		end
		s_tog <= ~s_tog;
		out <= 1'b1;
	end
end

endmodule
