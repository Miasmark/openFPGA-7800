//------------------------------------------------------------------------------
// The Pocket's SRAM (AS6C2016-55: 128K x 16, 55 ns, asynchronous) as the home
// of five memories that used to be block RAM:
//
//   word 0x00000-0x0FFFF  cartridge RAM        128 KiB (top.sv cartram_*)
//   word 0x10000-0x17FFF  2600 Flicker Blend    64 KiB (video_mux frame)
//   word 0x18000-0x1BFFF  SaveKey EEPROM        32 KiB (stored inverted)
//   word 0x1C000-0x1DFFF  7800 BIOS             16 KiB
//   word 0x1E000-0x1FFFF  unused                16 KiB
//
// Byte b of a region sits in word b >> 1, low byte when b is even.
//
// Runs on clk_sdram (4 x clk_sys, same PLL, edges aligned). Every access is
// five clk_sdram cycles (87 ns), comfortably over the part's 55 ns:
//
//   read:  address and OE at edge 0, DQ sampled by the input register at
//          edge 5, handed to the client at edge 6.
//   write: address, byte lanes and OE high at edge 0, DQ driven from edge 2
//          (the SRAM has released the bus by then), WE low from the falling
//          edge after 1 to the falling edge after 4 (52 ns), DQ released at 5.
//
// Who gets the SRAM:
//
//   7800 mode. Cartridge-RAM and BIOS reads come from MARIA's 7.16 MHz bus
//   strobe (mclk1), and the bus samples the byte two clk_sys later, the same
//   budget the SDRAM cartridge path has. The strobe is first seen one
//   clk_sdram after the clk_sys edge that raises mclk1 (call it A), and
//   arrives at most once every 8 clk_sdram. A cartridge access always starts
//   at A and finishes at A+5. Anything else may start only at an A that has
//   no cartridge access, and also finishes by A+5, so it can never be in the
//   way of the next strobe at A+8. If mclk1 stops (reset, pause), the slot
//   rule lapses and everything is served in order.
//
//   2600 mode. The 2600 mappers hold their RAM strobe for most of the 6507
//   cycle, so they have lots of slack. Flicker Blend prefetches the next
//   pixel. Order: cartridge, Flicker Blend, then the rest.
//
//   The rest, in order: the APF bridge (SaveKey save and load), the SaveKey
//   EEPROM model, the BIOS download, and the power-up clear.
//
// Power-up clear: the SaveKey region first (stored inverted, so cleared reads
// $FF, a blank EEPROM), then cartridge RAM and the Flicker Blend frame (zero,
// as the block RAMs were). A SaveKey file load stops the SaveKey part (the
// file covers the region anyway); a running game stops the rest.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module sram_ctrl (
	input  wire        clk,            // clk_sdram

	// From the clk_sys domain (same PLL, timed paths)
	input  wire        sys_reset,      // core held in reset (loading)
	input  wire        game_running,   // ~reset & a cartridge loaded: stop the clear
	input  wire        tia_mode,       // 2600 mode: no MARIA slots
	input  wire        mclk1,          // MARIA master enable, the slot reference

	// Cartridge RAM and BIOS (clk_sys). 7800: one strobe per mclk1.
	// 2600: a level, re-served whenever the address changes.
	input  wire        c_rd,
	input  wire        c_wr,
	input  wire        c_bios,         // this read is the BIOS, not cartridge RAM
	input  wire [16:0] c_addr,         // cartridge RAM byte, or BIOS byte in [13:0]
	input  wire  [7:0] c_wdata,
	output reg   [7:0] c_rdata = 8'hFF,

	// Flicker Blend frame (clk_sys), the spram it replaces: q follows address
	input  wire        fb_en,          // 2600 mode with Flicker Blend on
	input  wire [15:0] fb_addr,
	input  wire        fb_we,
	input  wire  [7:0] fb_wdata,
	output wire  [7:0] fb_q,

	// SaveKey EEPROM model (clk_sys): toggle request, toggle acknowledge
	input  wire        sk_req,
	input  wire        sk_we,
	input  wire [14:0] sk_addr,
	input  wire  [7:0] sk_wdata,
	output reg         sk_ack = 1'b0,
	output reg   [7:0] sk_rdata = 8'hFF,

	// BIOS download (clk_sys, one pulse per byte, at least ten clk_sdram apart)
	input  wire        dl_wr,
	input  wire [13:0] dl_addr,
	input  wire  [7:0] dl_data,

	// APF bridge, SaveKey region (clk_74a). Words are big endian: [31:24] is
	// the lowest byte. A read strobe latches the word for its address into
	// br_rdata, which the host samples during its next transaction.
	input  wire        clk_74a,
	input  wire        br_wr,
	input  wire        br_rd,
	input  wire [12:0] br_addr,
	input  wire [31:0] br_wdata,
	output reg  [31:0] br_rdata = 32'hFFFFFFFF,

	// Pins
	output reg  [16:0] sram_a = 17'd0,
	inout  wire [15:0] sram_dq,
	output reg         sram_oe_n = 1'b1,
	output reg         sram_we_n = 1'b1,
	output reg         sram_ub_n = 1'b1,
	output reg         sram_lb_n = 1'b1
);

localparam [16:0] FB_BASE   = 17'h10000;
localparam [16:0] SK_BASE   = 17'h18000;
localparam [16:0] BIOS_BASE = 17'h1C000;

// ---------------------------------------------------------------- pins ------
reg  [15:0] dq_out = 16'd0;
reg         dq_oe = 1'b0;
reg  [15:0] dq_in = 16'd0;
reg         we_want = 1'b0;
assign sram_dq = dq_oe ? dq_out : 16'hZZZZ;
always @(posedge clk) dq_in <= sram_dq;
always @(negedge clk) sram_we_n <= ~we_want;

// ------------------------------------------------------- input sampling -----
reg mclk1_q = 1'b0;
always @(posedge clk) mclk1_q <= mclk1;
wire slot_a = mclk1 & ~mclk1_q;

// Edges since the last slot; at 9 or more MARIA's clock has stopped.
reg [3:0] since_a = 4'd15;
always @(posedge clk) since_a <= slot_a ? 4'd0 : (since_a == 4'd15 ? 4'd15 : since_a + 4'd1);
wire maria_slots = ~tia_mode & ~sys_reset & (since_a < 4'd9 || slot_a);

// --------------------------------------------------------- the access -------
// Clients
localparam [2:0] CL_CART = 3'd0, CL_FB = 3'd1, CL_BR = 3'd2, CL_SK = 3'd3,
                 CL_DL = 3'd4, CL_CLR = 3'd5;

reg  [2:0] cnt = 3'd0;             // 0 idle, 1..5 in an access
wire       free = cnt == 3'd0 || cnt == 3'd5;

reg  [2:0] acc_cl = 3'd0;
reg        acc_lane = 1'b0;        // read: which byte the client wants
reg [16:0] acc_tag = 17'd0;        // read: client-specific tag
reg        acc_rd = 1'b0;

// The read result is in dq_in one edge after the access ends.
reg        done_v = 1'b0;
reg  [2:0] done_cl = 3'd0;
reg        done_lane = 1'b0;
reg [16:0] done_tag = 17'd0;
wire [7:0] done_byte = done_lane ? dq_in[15:8] : dq_in[7:0];

// One access request from the arbiter (combinational).
reg        go;
reg  [2:0] go_cl;
reg        go_we;
reg [16:0] go_word;
reg  [1:0] go_be;                   // {upper, lower}
reg [15:0] go_data;
reg        go_lane;
reg [16:0] go_tag;

always @(posedge clk) begin
	done_v <= 1'b0;
	if (cnt != 3'd0) cnt <= cnt + 3'd1;

	if (cnt == 3'd1 && !acc_rd) we_want <= 1'b1;
	if (cnt == 3'd2 && !acc_rd) dq_oe <= 1'b1;
	if (cnt == 3'd4) we_want <= 1'b0;

	if (cnt == 3'd5) begin
		cnt <= 3'd0;
		dq_oe <= 1'b0;
		sram_oe_n <= 1'b1;
		done_v <= acc_rd;
		done_cl <= acc_cl;
		done_lane <= acc_lane;
		done_tag <= acc_tag;
	end

	if (go && free) begin
		cnt <= 3'd1;
		sram_a <= go_word;
		acc_cl <= go_cl;
		acc_rd <= ~go_we;
		acc_lane <= go_lane;
		acc_tag <= go_tag;
		dq_oe <= 1'b0;
		dq_out <= go_data;
		sram_oe_n <= go_we;
		sram_ub_n <= go_we ? ~go_be[1] : 1'b0;
		sram_lb_n <= go_we ? ~go_be[0] : 1'b0;
	end
end

// ----------------------------------------------------- cartridge / BIOS -----
reg        c_rd_q = 1'b0, c_wr_q = 1'b0;
reg        cp_v = 1'b0, cp_we = 1'b0;     // pending cartridge access
reg [16:0] cp_word = 17'd0;
reg        cp_lane = 1'b0;
reg  [7:0] cp_data = 8'd0;
reg [18:0] c_key_last = 19'h7FFFF;        // {we, bios, addr} last requested

wire [16:0] c_word = c_bios ? (BIOS_BASE | {4'd0, c_addr[13:1]}) : {1'b0, c_addr[16:1]};
wire [18:0] c_key  = {c_wr, c_bios, c_addr};
wire        c_new  = (c_rd & ~c_rd_q) | (c_wr & ~c_wr_q) |
                     (tia_mode & (c_rd | c_wr) & (c_key != c_key_last));

always @(posedge clk) begin
	c_rd_q <= c_rd;
	c_wr_q <= c_wr;
	if (c_new) c_key_last <= c_key;
	if (!c_rd && !c_wr) c_key_last <= 19'h7FFFF;
end

// The request in force this edge: a new strobe beats an older pending one.
wire        cq_v    = c_new | cp_v;
wire        cq_we   = c_new ? c_wr : cp_we;
wire [16:0] cq_word = c_new ? c_word : cp_word;
wire        cq_lane = c_new ? c_addr[0] : cp_lane;
wire  [7:0] cq_data = c_new ? c_wdata : cp_data;

// ------------------------------------------------------- Flicker Blend ------
reg        fb_we_q = 1'b0;
reg [15:0] fb_cur = 16'd0;
reg  [7:0] fb_cur_d = 8'd0, fb_nxt_d = 8'd0;
reg        fb_cur_ok = 1'b0, fb_nxt_ok = 1'b0;
reg        fb_wq = 1'b0;                  // queued write
reg [15:0] fb_wq_a = 16'd0;
reg  [7:0] fb_wq_d = 8'd0;
reg        fb_rd_fly = 1'b0;              // a read is queued or in flight
reg [15:0] fb_rd_a = 16'd0;
assign fb_q = fb_cur_d;

wire [15:0] fb_nxt = fb_cur + 16'd1;
wire        fb_need_rd = fb_en & ~fb_rd_fly & (~fb_cur_ok | ~fb_nxt_ok);
wire [15:0] fb_need_a = fb_cur_ok ? fb_nxt : fb_cur;

// ------------------------------------------------------------- SaveKey ------
// Same PLL as clk_sys: the toggle is a timed path, used directly.
reg        sk_busy = 1'b0;
wire       sk_want = (sk_req != sk_ack) & ~sk_busy;

// ---------------------------------------------------------- BIOS download --
reg        dl_wr_q = 1'b0;
reg        dl_v = 1'b0;
reg [13:0] dl_a = 14'd0;
reg  [7:0] dl_d = 8'd0;

// ---------------------------------------------------------------- bridge ----
// clk_74a side: capture, then a toggle.
reg        br_tog = 1'b0, br_op_wr = 1'b0;
reg [12:0] br_a74 = 13'd0;
reg [31:0] br_d74 = 32'd0;
always @(posedge clk_74a) if (br_wr | br_rd) begin
	br_tog <= ~br_tog;
	br_op_wr <= br_wr;
	br_a74 <= br_addr;
	br_d74 <= br_wdata;
end

reg  [2:0] br_s = 3'd0;
always @(posedge clk) br_s <= {br_s[1:0], br_tog};
wire       br_ev = br_s[2] ^ br_s[1];
reg        br_pend = 1'b0;                // a strobe not yet taken up

// Bridge engine: a word is two SRAM accesses. Reads prefetch the next word,
// so a sequential save answers each strobe at once.
localparam [2:0] B_IDLE = 3'd0, B_WR0 = 3'd1, B_WR1 = 3'd2, B_RD0 = 3'd3, B_RD1 = 3'd4,
                 B_PF0 = 3'd5, B_PF1 = 3'd6;
reg  [2:0] b_st = B_IDLE;
reg [12:0] b_a = 13'd0;
reg [31:0] b_d = 32'd0;
reg        b_issued = 1'b0;               // the current step's access is out
reg [12:0] pf_a = 13'd0;
reg [31:0] pf_d = 32'd0;
reg        pf_ok = 1'b0;
reg        sk_written = 1'b0;             // a SaveKey file is being loaded

// ------------------------------------------------------------- clear --------
reg        clr_on = 1'b1;
reg        clr_sk = 1'b1;                 // still in the SaveKey part
reg [16:0] clr_a = SK_BASE;

// ------------------------------------------------------------ arbiter -------
wire cart_ok = 1'b1;
wire bg_ok   = maria_slots ? (slot_a & ~cq_v) : 1'b1;

reg        b_go;   reg b_go_we; reg [16:0] b_go_word; reg [15:0] b_go_data; reg b_go_lane;

always @(*) begin
	// Bridge step as an access
	b_go = 1'b0; b_go_we = 1'b0; b_go_word = SK_BASE; b_go_data = 16'd0; b_go_lane = 1'b0;
	case (b_st)
		B_WR0: begin b_go = ~b_issued; b_go_we = 1'b1; b_go_word = SK_BASE | {3'd0, b_a, 1'b0};
		             b_go_data = ~{b_d[23:16], b_d[31:24]}; end
		B_WR1: begin b_go = ~b_issued; b_go_we = 1'b1; b_go_word = SK_BASE | {3'd0, b_a, 1'b1};
		             b_go_data = ~{b_d[7:0], b_d[15:8]}; end
		B_RD0, B_PF0: begin b_go = ~b_issued; b_go_word = SK_BASE | {3'd0, b_a, 1'b0}; end
		B_RD1, B_PF1: begin b_go = ~b_issued; b_go_word = SK_BASE | {3'd0, b_a, 1'b1}; end
		default: ;
	endcase

	go = 1'b0; go_cl = CL_CLR; go_we = 1'b0; go_word = 17'd0; go_be = 2'b11;
	go_data = 16'd0; go_lane = 1'b0; go_tag = 17'd0;
	if (cq_v && cart_ok) begin
		go = 1'b1; go_cl = CL_CART; go_we = cq_we; go_word = cq_word;
		go_be = cq_lane ? 2'b10 : 2'b01; go_data = {cq_data, cq_data}; go_lane = cq_lane;
	end else if (tia_mode && fb_wq) begin
		go = 1'b1; go_cl = CL_FB; go_we = 1'b1; go_word = FB_BASE | {2'd0, fb_wq_a[15:1]};
		go_be = fb_wq_a[0] ? 2'b10 : 2'b01; go_data = {fb_wq_d, fb_wq_d};
	end else if (tia_mode && fb_need_rd) begin
		go = 1'b1; go_cl = CL_FB; go_word = FB_BASE | {2'd0, fb_need_a[15:1]};
		go_lane = fb_need_a[0]; go_tag = {1'b0, fb_need_a};
	end else if (bg_ok) begin
		if (b_go) begin
			go = 1'b1; go_cl = CL_BR; go_we = b_go_we; go_word = b_go_word;
			go_data = b_go_data; go_be = 2'b11;
		end else if (sk_want) begin
			go = 1'b1; go_cl = CL_SK; go_we = sk_we; go_word = SK_BASE | {3'd0, sk_addr[14:1]};
			go_be = sk_addr[0] ? 2'b10 : 2'b01; go_data = ~{sk_wdata, sk_wdata}; go_lane = sk_addr[0];
		end else if (dl_v) begin
			go = 1'b1; go_cl = CL_DL; go_we = 1'b1; go_word = BIOS_BASE | {4'd0, dl_a[13:1]};
			go_be = dl_a[0] ? 2'b10 : 2'b01; go_data = {dl_d, dl_d};
		end else if (clr_on) begin
			go = 1'b1; go_cl = CL_CLR; go_we = 1'b1; go_word = clr_a; go_data = 16'd0;
		end
	end
end

wire take = go & free;

// -------------------------------------------------------- client state ------
always @(posedge clk) begin
	// Cartridge: remember a strobe the SRAM could not take this edge.
	if (take && go_cl == CL_CART) cp_v <= 1'b0;
	else if (c_new) begin
		cp_v <= 1'b1; cp_we <= c_wr; cp_word <= c_word; cp_lane <= c_addr[0]; cp_data <= c_wdata;
	end
	if (done_v && done_cl == CL_CART) c_rdata <= done_byte;

	// Flicker Blend: follow the address, keep a byte for it and the next one.
	fb_we_q <= fb_we;
	if (fb_addr != fb_cur) begin
		fb_cur <= fb_addr;
		if (fb_nxt_ok && fb_addr == fb_nxt) begin
			fb_cur_d <= fb_nxt_d;
			fb_cur_ok <= 1'b1;
		end else
			fb_cur_ok <= 1'b0;
		fb_nxt_ok <= 1'b0;
	end
	if (fb_en && fb_we && !fb_we_q) begin
		fb_wq <= 1'b1; fb_wq_a <= fb_addr; fb_wq_d <= fb_wdata;
		// The byte just written is the byte to read back (new-data, as the
		// spram did); a read of it still in flight is stale and dropped.
		if (fb_addr == fb_cur) begin fb_cur_d <= fb_wdata; fb_cur_ok <= 1'b1; end
		if (fb_rd_fly && fb_addr == fb_rd_a) fb_rd_fly <= 1'b0;   // stale: fetch again
	end else if (take && go_cl == CL_FB && go_we)
		fb_wq <= 1'b0;
	if (take && go_cl == CL_FB && !go_we) begin
		fb_rd_fly <= 1'b1;
		fb_rd_a <= fb_need_a;
	end
	if (done_v && done_cl == CL_FB && fb_rd_fly && done_tag[15:0] == fb_rd_a) begin
		fb_rd_fly <= 1'b0;
		if (fb_addr == fb_cur) begin
			if (done_tag[15:0] == fb_cur && !fb_cur_ok) begin
				fb_cur_d <= done_byte; fb_cur_ok <= 1'b1;
			end else if (done_tag[15:0] == fb_nxt) begin
				fb_nxt_d <= done_byte; fb_nxt_ok <= 1'b1;
			end
		end
	end
	if (!fb_en) begin
		fb_cur_ok <= 1'b0; fb_nxt_ok <= 1'b0; fb_wq <= 1'b0; fb_rd_fly <= 1'b0;
	end

	// SaveKey
	if (take && go_cl == CL_SK) sk_busy <= 1'b1;
	if (sk_busy && cnt == 3'd5 && acc_cl == CL_SK && !acc_rd) begin
		sk_busy <= 1'b0; sk_ack <= ~sk_ack;
	end
	if (done_v && done_cl == CL_SK) begin
		sk_rdata <= ~done_byte; sk_busy <= 1'b0; sk_ack <= ~sk_ack;
	end

	// BIOS download
	dl_wr_q <= dl_wr;
	if (dl_wr && !dl_wr_q) begin dl_v <= 1'b1; dl_a <= dl_addr; dl_d <= dl_data; end
	else if (take && go_cl == CL_DL) dl_v <= 1'b0;

	// Clear
	if (take && go_cl == CL_CLR) begin
		if (clr_a == SK_BASE + 17'h3FFF) begin clr_sk <= 1'b0; clr_a <= 17'd0; end
		else if (!clr_sk && clr_a == FB_BASE + 17'h7FFF) clr_on <= 1'b0;
		else clr_a <= clr_a + 17'd1;
	end
	if (clr_sk && sk_written) begin clr_sk <= 1'b0; clr_a <= 17'd0; end
	if (game_running) clr_on <= 1'b0;

	// Bridge. A strobe waits in br_pend until the engine is idle; a prefetch
	// in progress finishes first (two accesses).
	if (br_ev) br_pend <= 1'b1;
	if (take && go_cl == CL_BR) b_issued <= 1'b1;
	case (b_st)
		B_IDLE: if (br_pend) begin
			br_pend <= br_ev;
			b_a <= br_a74;
			b_d <= br_d74;
			b_issued <= 1'b0;
			if (br_op_wr) begin
				sk_written <= 1'b1;
				if (pf_a == br_a74) pf_ok <= 1'b0;
				b_st <= B_WR0;
			end else if (pf_ok && pf_a == br_a74) begin
				br_rdata <= pf_d;
				b_a <= br_a74 + 13'd1;
				pf_ok <= 1'b0;
				b_st <= B_PF0;
			end else
				b_st <= B_RD0;
		end
		B_WR0: if (b_issued && cnt == 3'd5 && acc_cl == CL_BR) begin b_issued <= 1'b0; b_st <= B_WR1; end
		B_WR1: if (b_issued && cnt == 3'd5 && acc_cl == CL_BR) begin b_issued <= 1'b0; b_st <= B_IDLE; end
		B_RD0, B_PF0: if (done_v && done_cl == CL_BR) begin
			b_d[31:16] <= ~{dq_in[7:0], dq_in[15:8]};
			b_issued <= 1'b0;
			b_st <= b_st + 3'd1;
		end
		B_RD1: if (done_v && done_cl == CL_BR) begin
			br_rdata <= {b_d[31:16], ~{dq_in[7:0], dq_in[15:8]}};
			b_a <= b_a + 13'd1;
			b_issued <= 1'b0;
			b_st <= B_PF0;
		end
		B_PF1: if (done_v && done_cl == CL_BR) begin
			pf_d <= {b_d[31:16], ~{dq_in[7:0], dq_in[15:8]}};
			pf_a <= b_a;
			pf_ok <= 1'b1;
			b_issued <= 1'b0;
			b_st <= B_IDLE;
		end
		default: b_st <= B_IDLE;
	endcase
	// SaveKey writes from the game make a prefetched word stale.
	if (take && go_cl == CL_SK && sk_we && pf_a == sk_addr[14:2]) pf_ok <= 1'b0;
end

endmodule
