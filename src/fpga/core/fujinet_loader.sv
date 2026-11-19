//------------------------------------------------------------------------------
// FujiNet swap: replay the staged image through the core's cartridge load
// path (docs/FUJINET_GAME_LOADING.md, 3.4), on clk_sys.
//
// go (fujinet_mailbox.sv's swap_go: the armed hot swap) starts it. dl is
// then the second source of cart_download, and wr / addr / dout of the
// loader's bytes; core_top.v muxes them in ahead of the bridge's, and with
// dl low they are the bridge's alone. The replay reads the staged file in
// order through fujinet_rd.sv (clk_arm, a halfword per request) and
// presents each byte as one wr pulse at least SPACE clk_sys after the last
// (the bridge's data_loader manages one every 2.5 clk_sys; bup_capture.sv
// and the SDRAM writes rely on no faster). addr and dout are held from one
// pulse to the next, as the bridge's are: the header parser reads them by
// address, not by strobe. Before the first byte addr is all ones, which no
// parser takes for a header byte.
//
// A file without an A78 header (hdr low: bytes 1-5 are not "ATARI") is
// given one, so the core takes it for a 7800 cartridge: version 3,
// "ATARI7800", its size (bytes 49-52), the SuperGame flag above 48 KiB, two
// joysticks, NTSC; the file follows from byte 128. FujiNet pushes a
// headerless image only in whole 16K banks (Atari7800ROM.cpp).
//
// host_dl (the bridge's load sequence starting, two clk_sys ahead of its
// cart_download) ends a replay at once, leaving cart_download low for a
// clock between the two loads, so that every consumer sees this one end and
// the bridge's begin; a replay never starts while it is high. A request
// still open then is answered later and ignored.
//
// restart (fujinet_mailbox.sv's swap_restart: the hot swap unarmed) holds
// the console in reset for RESTART clk_sys (core_top.v ORs it into
// reset_in), so the running program starts again, as a menu reset does.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module fujinet_loader #(
	parameter int SPACE   = 4,
	parameter int RESTART = 64
) (
	input  wire        clk,          // clk_sys
	input  wire        go,
	input  wire        restart_go,
	input  wire [19:0] size,         // the staged file's bytes
	input  wire        hdr,          // it starts with an A78 header
	input  wire        host_dl,

	output logic       dl,
	output logic       wr,
	output logic [24:0] addr,
	output logic [7:0] dout,
	output logic       restart,

	// fujinet_rd.sv (clk_arm)
	output logic       l_req,
	output logic [18:0] l_haddr,
	input  wire        l_ack,
	input  wire [15:0] l_data
);
	typedef enum logic [2:0] { S_IDLE, S_LEAD, S_NEXT, S_READ, S_EMIT, S_GAP, S_TAIL } st_t;

	/* verilator lint_off PROCASSINIT */
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic        ack_s0 = 1'b0;
	logic        ack_s1 = 1'b0;
	st_t         st = S_IDLE;
	logic [19:0] n = 20'd0;          // the file's bytes
	logic        gen = 1'b0;         // a generated header comes first
	logic [20:0] i = 21'd0;          // the next byte out
	logic  [7:0] hb = 8'd0;          // the halfword's high byte, for the odd offset
	logic  [6:0] cnt = 7'd0;
	logic  [6:0] rcnt = 7'd0;
	initial begin
		dl = 1'b0; wr = 1'b0; addr = '1; dout = 8'd0; restart = 1'b0;
		l_req = 1'b0; l_haddr = 19'd0;
	end
	/* verilator lint_on PROCASSINIT */

	wire        open_rq = l_req != ack_s1;
	wire [20:0] src = gen ? i - 21'd128 : i;        // the byte's offset in the file

	// The generated header's byte i (i < 128)
	function automatic logic [7:0] ghdr(input logic [6:0] a, input logic [19:0] sz);
		case (a)
			7'd0:  ghdr = 8'd3;
			7'd1:  ghdr = "A";
			7'd2:  ghdr = "T";
			7'd3:  ghdr = "A";
			7'd4:  ghdr = "R";
			7'd5:  ghdr = "I";
			7'd6:  ghdr = "7";
			7'd7:  ghdr = "8";
			7'd8:  ghdr = "0";
			7'd9:  ghdr = "0";
			7'd50: ghdr = {4'd0, sz[19:16]};
			7'd51: ghdr = sz[15:8];
			7'd52: ghdr = sz[7:0];
			7'd54: ghdr = sz > 20'h0C000 ? 8'h02 : 8'h00;   // SuperGame
			7'd55: ghdr = 8'd1;
			7'd56: ghdr = 8'd1;
			default: ghdr = 8'd0;
		endcase
	endfunction

	always_ff @(posedge clk) begin
		ack_s0 <= l_ack;
		ack_s1 <= ack_s0;
		wr <= 1'b0;

		if (rcnt != 7'd0) rcnt <= rcnt - 7'd1;
		else restart <= 1'b0;
		if (restart_go) begin
			restart <= 1'b1;
			rcnt <= 7'(RESTART - 1);
		end

		case (st)
			S_IDLE:
				if (go && !host_dl && !open_rq && size != 20'd0) begin
					n <= size;
					gen <= !hdr;
					i <= 21'd0;
					dl <= 1'b1;
					addr <= '1;
					cnt <= 7'd15;
					st <= S_LEAD;
				end
			S_LEAD:                  // a few clocks of cart_download before the first byte
				if (cnt == 7'd0) st <= S_NEXT;
				else cnt <= cnt - 7'd1;
			S_NEXT:
				if (gen && i < 21'd128) begin
					dout <= ghdr(i[6:0], n);
					st <= S_EMIT;
				end else if (src >= {1'b0, n}) begin
					cnt <= 7'd15;
					st <= S_TAIL;
				end else if (!src[0]) begin
					l_haddr <= src[19:1];
					l_req <= ~l_req;
					st <= S_READ;
				end else begin
					dout <= hb;
					st <= S_EMIT;
				end
			S_READ:
				if (!open_rq) begin
					hb <= l_data[15:8];
					dout <= l_data[7:0];
					st <= S_EMIT;
				end
			S_EMIT: begin
				addr <= {4'd0, i};
				wr <= 1'b1;
				i <= i + 21'd1;
				cnt <= 7'(SPACE - 2);
				st <= S_GAP;
			end
			S_GAP:
				if (cnt == 7'd0) st <= S_NEXT;
				else cnt <= cnt - 7'd1;
			S_TAIL:                  // and a few after the last
				if (cnt == 7'd0) begin
					dl <= 1'b0;
					st <= S_IDLE;
				end else cnt <= cnt - 7'd1;
			default: st <= S_IDLE;
		endcase

		if (host_dl && st != S_IDLE) begin
			dl <= 1'b0;
			wr <= 1'b0;
			st <= S_IDLE;
		end
	end
endmodule

`default_nettype wire
