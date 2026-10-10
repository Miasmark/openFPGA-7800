//------------------------------------------------------------------------------
// The Pocket's SRAM (AS6C2016-55: 128K x 16, 55 ns, asynchronous) as the home
// of five memories that used to be block RAM:
//
//   word 0x00000-0x0FFFF  cartridge RAM        128 KiB (top.sv cartram_*,
//                                                       cartram_*26_out)
//   word 0x10000-0x17FFF  2600 Flicker Blend    64 KiB (video_mux frame)
//   word 0x18000-0x1BFFF  SaveKey EEPROM        32 KiB (stored inverted)
//   word 0x1C000-0x1DFFF  7800 BIOS             16 KiB
//   word 0x1E000-0x1FFFF  unused                16 KiB
//
// Byte b of a region sits in word b >> 1, low byte when b is even.
//
// Runs on clk_sdram (4 x clk_sys, same PLL, edges aligned), apart from the
// 2600 request register on clk_sys (below). Every access is five clk_sdram
// cycles (87 ns), comfortably over the part's 55 ns:
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
//   cycle. Their request comes on its own port (t_*) and is registered here
//   on clk_sys (t_*_q), so the mappers' decode is timed against clk_sys and
//   stays out of clk_sdram's cone (Fix B, docs/DARIA_CORE.md). An access
//   starts when the registered strobe rises, and again whenever the
//   registered address or direction changes while it is held. Flicker Blend
//   prefetches the next pixel. Order: cartridge, Flicker Blend, then the
//   rest.
//
//   The 2600 read budget, in clk_sdram edges sN counted from E0, the clk_sys
//   edge where pclk1 loads the 6507's address (E1 = s4, E2 = s8). The
//   mapper's strobe is valid at E1 (at E0 if the address repeats), t_*_q
//   loads at E2 = s8, the access starts at s9 and c_rdata is written at
//   s15 (s11 for a repeated address). At worst another client's access
//   started at s8 and the cartridge starts when it ends, at s13: c_rdata at
//   s19. The 6507 latches at E6 = s24, and c_rdata into clk_sys is a
//   two-clk_sys multicycle (core_constraints.sdc), so s19 is the last edge
//   allowed and there is no spare. A second register stage, sending every
//   2600 request through cp before the arbiter sees it (one clk_sdram more;
//   the s19 case above waits in cp only because the SRAM is busy), a longer
//   access, or another client ahead of the cartridge would each break the
//   budget without any functional failure in simulation.
//
//   One read is a clk_sys later: the 6507's first bus cycle after a console
//   reset, a dummy read of its reset sequence. The cartridge's a_in[12]
//   (AB[12] & bios_en_b, top.sv) follows the reset's release by one
//   clk_sys, so a RAM strobe for that address is valid at E2, t_*_q loads
//   at E3 = s12, and c_rdata lands at s19 with nothing in the way. Another
//   client's access starting at s9 to s12 would put it at s20 to s23, past
//   the multicycle (Flicker Blend's accesses, locked to the 6507 cycle,
//   rarely start there; the SaveKey model's and the bridge's can start at
//   any phase), but the 6507 discards that byte: reset forces BRK into its
//   instruction register.
//
//   The two requests. top.sv drives its 7800 request (c_*, with the BIOS
//   read beside it) only while its 2600 select (mapper_init_busy | tia_en)
//   is low, and t_* only while it is high, but t_*_q lags the select by one
//   clk_sys. In 2600 mode the select falls only at a console reset, from
//   any source of the wrapper's reset register (the Pocket's Reset, a load,
//   a PLL retune): ctrl_reg clears tia_en and bios_en_b on one edge, and
//   from it bios_sel = AB[15]. If that edge is also where t_*_q loads a new
//   2600 strobe (the reset register rose at E1 of a cycle the mapper
//   decodes as cart RAM, so the select falls at E2), the 6507 reads at
//   A15 = 1 and mclk1 is high from E2, the BIOS read (mclk1 & bios_sel &
//   RW, atari7800_pocket.sv) rises there too: m_new and t_new in the same
//   clk_sdram cycle, s9. Code at $F000-$FFFF meets this with a RAM read, a
//   Superchip write port's dummy read or a Supercharger RAM write, all
//   6507 reads. It is the only way the two meet, and m_new yields to
//   t_new: the 2600 access goes ahead as in any cycle (s9, c_rdata at s15,
//   s19 behind another client), and that BIOS read, one clk_sys wide like
//   mclk1, is not served (a 7800 cartridge-RAM strobe would yield the same
//   way). The core is in reset, nothing uses that byte, and the BIOS reads
//   after it are served as before. So m_new and t_new are never high
//   together, and the testbenches stop if they are. Rejected: a retry
//   (t_last not loaded when m_new wins) puts the 2600 access behind the
//   BIOS read, c_rdata at s20; gating the BIOS read with the wrapper's
//   tia_mode misses a load, which clears tia_mode on the edge where the
//   reset register rises.
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
	input  wire        clk_sys,        // the 2600 request register

	// From the clk_sys domain (same PLL, timed paths)
	input  wire        sys_reset,      // core held in reset (loading)
	input  wire        game_running,   // ~reset & a cartridge loaded: stop the clear
	input  wire        tia_mode,       // 2600 mode: no MARIA slots
	input  wire        mclk1,          // MARIA master enable, the slot reference

	// 7800 cartridge RAM and BIOS (clk_sys): one strobe per mclk1, served
	// at A.
	input  wire        c_rd,
	input  wire        c_wr,
	input  wire        c_bios,         // this read is the BIOS, not cartridge RAM
	input  wire [16:0] c_addr,         // cartridge RAM byte, or BIOS byte in [13:0]
	input  wire  [7:0] c_wdata,
	// 2600 cartridge RAM (clk_sys): a level, registered here for one
	// clk_sys, re-served whenever the registered address or direction
	// changes.
	input  wire        t_rd,
	input  wire        t_wr,
	input  wire [16:0] t_addr,
	input  wire  [7:0] t_wdata,
	output reg   [7:0] c_rdata,        // both ports

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
	output reg         sk_ack,
	output reg   [7:0] sk_rdata,

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
	output reg  [31:0] br_rdata,

	// Pins
	output reg  [16:0] sram_a,
	inout  wire [15:0] sram_dq,
	output reg         sram_oe_n,
	output reg         sram_we_n,
	output reg         sram_ub_n,
	output reg         sram_lb_n
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial c_rdata = 8'hFF;
	initial sk_ack = 1'b0;
	initial sk_rdata = 8'hFF;
	initial br_rdata = 32'hFFFFFFFF;
	initial sram_a = 17'd0;
	initial sram_we_n = 1'b1;
	// sram_oe_n, sram_ub_n and sram_lb_n have no power-up value on purpose.
	// They are the pins' fast output registers, at the end of clk_sdram's
	// worst path (the cartridge request through the arbiter), and powering
	// them up high makes Quartus invert them there: the 2.1.1 builds lost
	// their margin to it (+0.05 to +0.11 ns). Low at power-up with WE# high is
	// a read of address 0, with the FPGA not driving DQ: harmless, and what
	// 2.0.21 shipped.

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

// 2600: one clk_sys register, so the mappers' decode ends there. Address,
// strobes and data are sampled on the same edge.
reg        t_rd_q, t_wr_q;
reg [16:0] t_addr_q;
reg  [7:0] t_wdata_q;
initial begin t_rd_q = 1'b0; t_wr_q = 1'b0; t_addr_q = 17'd0; t_wdata_q = 8'd0; end
always @(posedge clk_sys) begin
	t_rd_q    <= t_rd;
	t_wr_q    <= t_wr;
	t_addr_q  <= t_addr;
	t_wdata_q <= t_wdata;
end

// A new 2600 request: the registered strobe with a key not yet served. The
// compare sees registers only. The registered strobe is low for at least
// one clk_sys between 6507 cycles, so today the compare only repeats the
// rising edge; it is kept as a guard for a mapper that moves its address
// inside a held strobe. t_last_v marks t_last as valid (every 18-bit key is
// a real request).
reg        t_last_v;
reg [17:0] t_last;                        // {we, addr} last served
initial begin t_last_v = 1'b0; t_last = 18'd0; end
wire [17:0] t_key = {t_wr_q, t_addr_q};
wire        t_new = (t_rd_q | t_wr_q) & (~t_last_v | (t_key != t_last));

// 7800 and BIOS: the rising strobe only (MARIA's slot timing, served at A),
// unless a new 2600 request arrives in the same clk_sdram cycle. That
// happens only in the clk_sys after a console reset clears the 2600 select
// (header, "The two requests"): the 2600 request is served, and the BIOS
// read beside it, one clk_sys wide like mclk1, is not. So m_new and t_new
// are never high together. t_new comes from registers only.
wire [16:0] c_word = c_bios ? (BIOS_BASE | {4'd0, c_addr[13:1]}) : {1'b0, c_addr[16:1]};
wire        m_new  = ((c_rd & ~c_rd_q) | (c_wr & ~c_wr_q)) & ~t_new;

always @(posedge clk) begin
	c_rd_q <= c_rd;
	c_wr_q <= c_wr;
	if (t_new) begin t_last_v <= 1'b1; t_last <= t_key; end
	if (!t_rd_q && !t_wr_q) t_last_v <= 1'b0;
end

// The request in force this edge: a new strobe beats an older pending one.
// The 7800 strobe selects last, so its cone sees one mux here.
wire        c_new   = m_new | t_new;
wire        cq_v    = c_new | cp_v;
wire        cq_we   = m_new ? c_wr      : (t_new ? t_wr_q                 : cp_we);
wire [16:0] cq_word = m_new ? c_word    : (t_new ? {1'b0, t_addr_q[16:1]} : cp_word);
wire        cq_lane = m_new ? c_addr[0] : (t_new ? t_addr_q[0]            : cp_lane);
wire  [7:0] cq_data = m_new ? c_wdata   : (t_new ? t_wdata_q              : cp_data);

// ------------------------------------------------------- Flicker Blend ------
// Taken on the falling edge, half a clk_sdram after the clk_sys edge that
// changes them. Sampled on the coincident rising edge, the frame pointer's
// short route failed hold by 0.13 ns (clk_sys to clk_sdram skew).
reg [15:0] fbn_addr = 16'd0;
reg  [7:0] fbn_wdata = 8'd0;
reg        fbn_we = 1'b0, fbn_en = 1'b0;
always @(negedge clk) begin
	fbn_addr  <= fb_addr;
	fbn_wdata <= fb_wdata;
	fbn_we    <= fb_we;
	fbn_en    <= fb_en;
end
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
wire        fb_need_rd = fbn_en & ~fb_rd_fly & (~fb_cur_ok | ~fb_nxt_ok);
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
		cp_v <= 1'b1; cp_we <= cq_we; cp_word <= cq_word; cp_lane <= cq_lane; cp_data <= cq_data;
	end
	if (done_v && done_cl == CL_CART) c_rdata <= done_byte;

	// Flicker Blend: follow the address, keep a byte for it and the next one.
	fb_we_q <= fbn_we;
	if (fbn_addr != fb_cur) begin
		fb_cur <= fbn_addr;
		if (fb_nxt_ok && fbn_addr == fb_nxt) begin
			fb_cur_d <= fb_nxt_d;
			fb_cur_ok <= 1'b1;
		end else
			fb_cur_ok <= 1'b0;
		fb_nxt_ok <= 1'b0;
	end
	if (fbn_en && fbn_we && !fb_we_q) begin
		fb_wq <= 1'b1; fb_wq_a <= fbn_addr; fb_wq_d <= fbn_wdata;
		// The byte just written is the byte to read back (new-data, as the
		// spram did); a read of it still in flight is stale and dropped.
		if (fbn_addr == fb_cur) begin fb_cur_d <= fbn_wdata; fb_cur_ok <= 1'b1; end
		if (fb_rd_fly && fbn_addr == fb_rd_a) fb_rd_fly <= 1'b0;   // stale: fetch again
	end else if (take && go_cl == CL_FB && go_we)
		fb_wq <= 1'b0;
	if (take && go_cl == CL_FB && !go_we) begin
		fb_rd_fly <= 1'b1;
		fb_rd_a <= fb_need_a;
	end
	if (done_v && done_cl == CL_FB && fb_rd_fly && done_tag[15:0] == fb_rd_a) begin
		fb_rd_fly <= 1'b0;
		if (fbn_addr == fb_cur) begin
			if (done_tag[15:0] == fb_cur && !fb_cur_ok) begin
				fb_cur_d <= done_byte; fb_cur_ok <= 1'b1;
			end else if (done_tag[15:0] == fb_nxt) begin
				fb_nxt_d <= done_byte; fb_nxt_ok <= 1'b1;
			end
		end
	end
	if (!fbn_en) begin
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
