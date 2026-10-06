//------------------------------------------------------------------------------
// BupChip asset cache, on clk_arm (docs/BUPCHIP_CORE.md, "Memory map and timing
// per region", "Cache", "Miss and prefetch"; docs/DARIA_CORE.md, "Bytes beyond
// 128 KB: the asset cache over PSRAM"), in front of the PSRAM. 16-byte lines,
// in one of two organisations (WAYS):
//
//   WAYS 1 (ARIA)   64 lines, direct-mapped, 1 KB
//                   offset [22:10] tag, [9:4] line, [3:1] halfword, [0] byte
//   WAYS 2 (DARIA)  128 sets of 2 ways, FIFO replacement, 4 KB
//                   offset [22:11] tag, [10:4] set, [3:1] halfword, [0] byte
//
// The offset is w_addr[22:0] in both of DARIA's profiles, so the cache needs
// no profile input. The BupChip's assets sit at 0x0200_0000 + offset, and
// bup_cpu completes an asset load only below asset_size, at most 8 MiB (the
// capture drops bytes past the PSRAM die), so bit 23 is 0 and the bits above
// it are the region's. A 2600 image's bytes beyond the 128 KB window sit at
// 0x0002_0000-0x0007_FFFF, offset = address, so tag bits [22:19] are 0 there.
// Both are read from the PSRAM at halfword offset >> 1 (rd_addr).
//
// Data: one RAM per way, 2^(set bits + 2) x 32 (cache_ram_tdp_dc_be). Port A is
// read by the CPU at d_addr; port B is written a halfword at a time from the
// PSRAM, through its byte enables. cache_ram.v builds it as a true dual-port
// altsyncram, and an M10K in that mode is at most 20 bits wide, so each takes
// 2 M10K (a simple dual-port RAM would hold WAYS 1's 256 x 32 in one, but
// needs its own wrapper; 512 x 32 takes 2 either way): 2 for WAYS 1, 4 for
// WAYS 2. Tags: one RAM per way, one word per set (cache_ram_tdp_dc), 14 bits:
//
//   WAYS 1   {valid, tag[12:0]}
//   WAYS 2   {valid, p, tag[11:0]}
//
// Port A is the CPU's lookup; port B does the prefetch probe and every tag
// write. Each tag RAM is one M10K. WAYS 2 keeps the two ways' tags in two
// RAMs, not one 128 x 27 word: that word would take 2 M10K anyway (wider than
// 20 bits), and two RAMs let a fill write its own way's word without
// rewriting the other's. So the cache takes 3 M10K with WAYS 1 and 6 with
// WAYS 2 (one tag word of 2 x 9 + 1 bits would fit one M10K, but 8-bit tags
// cannot tell apart the BupChip's assets, up to 8 MiB, in the same
// instance). Every RAM takes d_addr at the end of execute, as ROM port B and
// the RAM do, so they answer in W; while w_wait holds W the CPU keeps d_addr
// on the access and they read it again every clock.
//
// Replacement (WAYS 2). A set's FIFO bit is p0 ^ p1, the way its next fill
// goes to. A fill writes its way's tag invalid with that way's p unchanged as
// it starts, and valid with p flipped as it ends, so the FIFO bit flips when a
// fill completes, not when it starts. A fill that is pre-empted or held
// leaves the FIFO bit on its own way, now invalid, so that way is refilled
// next; with the sweep's p = 0 in both ways, a valid line is therefore never
// replaced while the other way of its set is invalid. A line is filled only
// when neither way holds it valid and it is not under fill, and only one
// fill runs, so a line never sits in both ways, nor valid in one while it is
// being filled into the other.
//
// W (bup_cpu S1: w_asset, w_addr, w_size). The load completes once every
// halfword it touches is there: one for a byte or halfword load (odd LDRH
// included), both halfwords of the aligned word for LDR. A line is there when
// its tag is valid in a way, or, for the line under fill, halfword by
// halfword from the arrival bits. Both ways' tags and data words are read in
// parallel; asset_q is the way whose tag matches, or for the line under fill
// the way it fills. No M10K is trusted on a clock whose read was registered
// on the same edge as a port-B write of the same word (data) or set (tags):
// that is a mixed-port read-during-write, undefined on the device. The check
// takes a write to either way, so the way select stays out of it (a hit can
// wait a clock for a write to the other way). Such a clock waits and the read
// is simply repeated, which gives the design's rule that the replay read
// comes one clock after the write of the last halfword it needs.
//
// Fill. One at a time: line, tag, way, demand or prefetch, 8 arrival bits. A
// demand fill goes to the set's FIFO way. It writes the line's tag invalid as
// it starts, reads the 8 halfwords from the critical one (the one holding the
// access's lowest byte) round the line, and writes the tag valid with the
// last. A miss costs 8 clocks over a hit (13 for LDR) with psram.sv's 5
// clocks per halfword. A load on the line under fill waits for its halfwords
// without starting anything.
//
// Prefetch (PREFETCH). After every asset access the next line is probed (both
// ways' tags) on tag port B once no fill is running (the latest access's next
// line waits for that); if it is neither valid in a way nor under fill it is
// fetched from halfword 0, into its set's FIFO way.
//
// Pre-emption (PREEMPT). A demand miss stops a running fill from issuing more
// reads, waits for the halfword in flight (psram.sv cannot abort a read), and
// starts its own fill. The pre-empted line keeps the invalid tag its fill
// started with. With PREEMPT = 0 a miss waits for the whole fill.
//
// Sweep. Whenever pre_run (not held, firmware and assets ready) is low the
// sweep restarts; once it is high, one clock per set (64 or 128) writes every
// way's tag invalid, with p = 0, then sweep_done lets the CPU run. The fill
// and prefetch machines are held while run (cpu_run) is low and issue no read
// then; a read already in flight finishes in psram.sv (at most 5 clocks into
// the hold) and is dropped: its halfword can land only in the first held
// clock, in the line and way it was filling, whose tag is invalid.
//
// Timing. With WAYS 2 the way select adds a 2:1 mux after the tag compare on
// asset_q, the path into bup_cpu's W source mux; w_wait gains an OR of the two
// compares. start_dem drives the tag RAMs' port-B write enables from the tag
// M10Ks' outputs (the compare, and the victim from the p bits) within the
// clock, as it already did with one way.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_asset_cache #(
	parameter bit PREEMPT  = 1'b1,      // a demand miss pre-empts a running fill
	parameter bit PREFETCH = 1'b1,      // next-line prefetch
	parameter int WAYS     = 1          // 1: 64 lines direct-mapped (ARIA); 2: 128 sets x 2 ways (DARIA)
) (
	input  wire         clk,            // clk_arm
	input  wire         pre_run,        // ~hold & fw_loaded & asset_ready
	input  wire         run,            // cpu_run = pre_run & sweep_done, registered
	output logic        sweep_done,

	// bup_cpu (S1).
	input  wire  [31:0] d_addr,         // this clock's access address
	input  wire         w_asset,        // W holds an asset load
	input  wire  [31:0] w_addr,         // its address
	input  wire   [1:0] w_size,         // 0 byte, 1 halfword, 2 word
	output wire  [31:0] asset_q,        // the aligned word at w_addr
	output logic        w_wait,         // the halfwords it touches are not all there

	// PSRAM reads, through bup_asset_wr; read_avail and data_out of psram.sv.
	output logic        rd_req,
	output logic [21:0] rd_addr,        // halfword address
	input  wire         rd_ack,         // taken this clock
	input  wire         rd_avail,
	input  wire  [15:0] rd_data,

	// One clock per event, for the testbench and BUP_DEBUG.
	output logic        st_miss,        // a demand fill starts
	output logic        st_pf,          // a prefetch starts
	output logic        st_preempt,     // a demand fill pre-empts a running fill
	output logic        st_late,        // an access finds its line under fill and waits
	output logic        st_stall        // W waits this clock
);
	localparam bit TWO = WAYS == 2;
	localparam int IW = TWO ? 7 : 6;    // set index: offset[IW+3:4]
	localparam int TW = 19 - IW;        // tag: offset[22:IW+4]
	localparam logic [IW-1:0] SW_LAST = {IW{1'b1}};

	// A tag word: {valid, tag} with one way, {valid, p, tag} with two.
	function automatic logic [13:0] tword(input logic v, input logic p, input logic [TW-1:0] t);
		tword = {v, 13'(t)};
		if (TWO) tword[12] = p;
	endfunction

	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial sweep_done = 1'b0;
	// ---- fill state -------------------------------------------------------------
	logic          f_act = 1'b0;        // a fill is running
	logic          f_fl = 1'b0;         // one of its reads is in flight
	logic          stop = 1'b0;         // a demand miss waits to pre-empt: issue no more
	logic [IW-1:0] f_idx = '0;
	logic [TW-1:0] f_tag = '0;
	logic          f_way = 1'b0;        // the way it fills (0 with one way)
	logic          f_p = 1'b0;          // that way's p at its start (two ways)
	logic    [7:0] f_arr = 8'd0;        // halfwords arrived
	logic    [2:0] f_rq_hw = 3'd0;      // next halfword to read
	logic    [2:0] f_fl_hw = 3'd0;      // the halfword in flight
	logic    [3:0] f_rq_n = 4'd0;       // reads left to issue
	logic    [3:0] f_rx_n = 4'd0;       // halfwords left to arrive

	// ---- memories -------------------------------------------------------------------
	// Way 0 is tags and data, way 1 way1.tags and way1.data.
	logic    [1:0] tb_we;               // tag port-B write, per way
	logic [IW-1:0] tb_addr;
	logic   [13:0] tb_wd;
	wire    [13:0] tq_a0, tq_b0, tq_a1, tq_b1;
	wire    [31:0] dq_a0, dq_a1;
	cache_ram_tdp_dc #(.ADDR_WIDTH(IW), .DATA_WIDTH(14)) tags (
		.clk_a_i(clk), .addr_a_i(d_addr[IW+3:4]), .wren_a_i(1'b0), .wdata_a_i(14'd0), .q_a_o(tq_a0),
		.clk_b_i(clk), .addr_b_i(tb_addr), .wren_b_i(tb_we[0]), .wdata_b_i(tb_wd), .q_b_o(tq_b0));

	wire rx = rd_avail && f_fl;         // the halfword in flight arrives
	cache_ram_tdp_dc_be #(.ADDR_WIDTH(IW + 2), .DATA_WIDTH(32)) data (
		.clk_a_i(clk), .addr_a_i(d_addr[IW+3:2]), .wren_a_i(1'b0), .byteena_a_i(4'd0),
		.wdata_a_i(32'd0), .q_a_o(dq_a0),
		.clk_b_i(clk), .addr_b_i({f_idx, f_fl_hw[2:1]}), .wren_b_i(rx && !f_way),
		.byteena_b_i(f_fl_hw[0] ? 4'b1100 : 4'b0011), .wdata_b_i({rd_data, rd_data}), .q_b_o());

	// Quartus 21.1 wants the generate region spelled out.
	generate
	if (TWO) begin : way1
		cache_ram_tdp_dc #(.ADDR_WIDTH(IW), .DATA_WIDTH(14)) tags (
			.clk_a_i(clk), .addr_a_i(d_addr[IW+3:4]), .wren_a_i(1'b0), .wdata_a_i(14'd0), .q_a_o(tq_a1),
			.clk_b_i(clk), .addr_b_i(tb_addr), .wren_b_i(tb_we[1]), .wdata_b_i(tb_wd), .q_b_o(tq_b1));
		cache_ram_tdp_dc_be #(.ADDR_WIDTH(IW + 2), .DATA_WIDTH(32)) data (
			.clk_a_i(clk), .addr_a_i(d_addr[IW+3:2]), .wren_a_i(1'b0), .byteena_a_i(4'd0),
			.wdata_a_i(32'd0), .q_a_o(dq_a1),
			.clk_b_i(clk), .addr_b_i({f_idx, f_fl_hw[2:1]}), .wren_b_i(rx && f_way),
			.byteena_b_i(f_fl_hw[0] ? 4'b1100 : 4'b0011), .wdata_b_i({rd_data, rd_data}), .q_b_o());
	end else begin : one_way
		assign tq_a1 = 14'd0;
		assign tq_b1 = 14'd0;
		assign dq_a1 = 32'd0;
	end
	endgenerate

	// Port-B writes of last clock: a port-A read registered on the same edge
	// is not used.
	logic            tw_q = 1'b0, dw_q = 1'b0;
	logic   [IW-1:0] tw_idx_q = '0;
	logic [IW+1:0]   dw_a_q = '0;

	// ---- W --------------------------------------------------------------------------
	wire [IW-1:0] idx  = w_addr[IW+3:4];
	wire [TW-1:0] tag  = w_addr[22:IW+4];
	wire    [7:0] need = w_size == 2'd2 ? 8'b11 << {w_addr[3:2], 1'b0} : 8'b1 << w_addr[3:1];
	wire    [2:0] crit = w_size == 2'd2 ? {w_addr[3:2], 1'b0} : w_addr[3:1];
	wire in_fill = f_act && f_idx == idx && f_tag == tag;
	wire tcol    = tw_q && tw_idx_q == idx;
	wire dcol    = dw_q && dw_a_q == w_addr[IW+3:2];
	wire thit0   = tq_a0[13] && tq_a0[TW-1:0] == tag;
	wire thit1   = TWO && tq_a1[13] && tq_a1[TW-1:0] == tag;
	wire thit    = thit0 || thit1;
	wire have    = in_fill ? (f_arr & need) == need : thit;
	assign w_wait = w_asset && !(have && !tcol && !dcol);
	assign asset_q = (in_fill ? f_way : thit1) ? dq_a1 : dq_a0;
	wire miss    = w_asset && !in_fill && !thit && !tcol;
	wire acc_done = w_asset && !w_wait;
	// The set's FIFO way, and its p (which the fill's start keeps).
	wire vic_a   = TWO && (tq_a0[12] ^ tq_a1[12]);
	wire p_a     = vic_a ? tq_a1[12] : tq_a0[12];

	wire start_dem = run && miss && (!f_act || (PREEMPT && !f_fl && !rd_ack));

	// ---- prefetch probe ------------------------------------------------------------
	logic        pf_pend = 1'b0, probe_v = 1'b0;
	logic [18:0] pf_line = 19'd0, probe_line = 19'd0;	// {tag, set}
	wire [IW-1:0] p_idx = probe_line[IW-1:0];
	wire [TW-1:0] p_tag = probe_line[18:IW];
	wire pf_have  = (tq_b0[13] && tq_b0[TW-1:0] == p_tag) || (TWO && tq_b1[13] && tq_b1[TW-1:0] == p_tag)
		|| (f_act && {f_tag, f_idx} == probe_line);
	wire vic_b    = TWO && (tq_b0[12] ^ tq_b1[12]);
	wire p_b      = vic_b ? tq_b1[12] : tq_b0[12];
	wire start_pf = PREFETCH && run && probe_v && !pf_have && !f_act && !start_dem;
	wire probe_go = PREFETCH && run && pf_pend && !f_act && !start_dem && !start_pf;
	wire fill_end = rx && f_rx_n == 4'd1;

	// Tag port B: the sweep (every way), a fill's start (invalid, p kept) and
	// end (valid, p flipped) in its way, or a probe read of both ways. At most
	// one of the writes can want it in any clock.
	logic [IW-1:0] sw_cnt = '0;
	always_comb begin
		tb_we = 2'b00;
		tb_addr = pf_line[IW-1:0];
		tb_wd = 14'd0;
		if (!sweep_done) begin
			tb_we = {2{pre_run}};
			tb_addr = sw_cnt;
		end else if (start_dem) begin
			tb_we = vic_a ? 2'b10 : 2'b01;
			tb_addr = idx;
			tb_wd = tword(1'b0, p_a, '0);
		end else if (start_pf) begin
			tb_we = vic_b ? 2'b10 : 2'b01;
			tb_addr = p_idx;
			tb_wd = tword(1'b0, p_b, '0);
		end else if (fill_end) begin
			tb_we = f_way ? 2'b10 : 2'b01;
			tb_addr = f_idx;
			tb_wd = tword(1'b1, !f_p, f_tag);
		end
	end

	// Not while held: in the first held clock f_act is still set, and a read
	// issued then would keep psram.sv busy into the hold for nothing.
	assign rd_req  = run && f_act && f_rq_n != 4'd0 && !stop && (!f_fl || rx);
	assign rd_addr = {f_tag, f_idx, f_rq_hw};

	always_ff @(posedge clk) begin
		tw_q <= |tb_we;
		tw_idx_q <= tb_addr;
		dw_q <= rx;
		dw_a_q <= {f_idx, f_fl_hw[2:1]};

		if (!pre_run) begin
			sw_cnt <= '0;
			sweep_done <= 1'b0;
		end else if (!sweep_done) begin
			sw_cnt <= sw_cnt + 1'b1;
			if (sw_cnt == SW_LAST) sweep_done <= 1'b1;
		end

		if (!run) begin
			f_act <= 1'b0;
			f_fl <= 1'b0;
			stop <= 1'b0;
			pf_pend <= 1'b0;
			probe_v <= 1'b0;
		end else begin
			probe_v <= probe_go;
			if (probe_go) begin
				probe_line <= pf_line;
				pf_pend <= 1'b0;
			end
			if (PREFETCH && acc_done) begin			// the newest access wins
				pf_pend <= 1'b1;
				pf_line <= w_addr[22:4] + 19'd1;
			end

			if (rd_ack) begin
				f_fl <= 1'b1;
				f_fl_hw <= f_rq_hw;
				f_rq_hw <= f_rq_hw + 3'd1;
				f_rq_n <= f_rq_n - 4'd1;
			end else if (rx)
				f_fl <= 1'b0;
			if (rx) begin
				f_arr[f_fl_hw] <= 1'b1;
				f_rx_n <= f_rx_n - 4'd1;
				if (f_rx_n == 4'd1) f_act <= 1'b0;
			end

			if (PREEMPT && miss && f_act) stop <= 1'b1;
			if (start_dem || start_pf) begin
				f_act <= 1'b1;
				f_idx <= start_dem ? idx : p_idx;
				f_tag <= start_dem ? tag : p_tag;
				f_way <= start_dem ? vic_a : vic_b;
				f_p <= start_dem ? p_a : p_b;
				f_arr <= 8'd0;
				f_rq_hw <= start_dem ? crit : 3'd0;
				f_rq_n <= 4'd8;
				f_rx_n <= 4'd8;
				stop <= 1'b0;
			end
		end
	end

	// ---- statistics -----------------------------------------------------------------
	logic w_was = 1'b0;                 // last clock was a W that waited
	always_ff @(posedge clk) w_was <= w_asset && w_wait;
	assign st_miss    = start_dem;
	assign st_pf      = start_pf;
	assign st_preempt = start_dem && f_act;
	assign st_late    = w_asset && !w_was && in_fill && !have;
	assign st_stall   = w_asset && w_wait;
endmodule

`default_nettype wire
