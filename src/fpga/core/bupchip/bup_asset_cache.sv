//------------------------------------------------------------------------------
// BupChip asset cache, on clk_arm (docs/BUPCHIP_CORE.md, "Memory map and timing
// per region", "Cache", "Miss and prefetch"): 64 lines of 16 bytes,
// direct-mapped, in front of the PSRAM that holds the ARSC block.
//
//   asset offset [22:10] tag, [9:4] line, [3:1] halfword, [0] byte
//
// Data: 256 x 32 (cache_ram_tdp_dc_be). Port A is read by the CPU at d_addr;
// port B is written a halfword at a time from the PSRAM, through its byte
// enables. cache_ram.v builds it as a true dual-port altsyncram, and an M10K
// in that mode is at most 20 bits wide, so it takes 2 M10K (a simple
// dual-port RAM would hold 256 x 32 in one, but needs its own wrapper). Tags:
// one M10K, 64 x {valid, tag} (cache_ram_tdp_dc). Port A is the CPU's
// lookup; port B does the prefetch probe and every tag write. Both RAMs take
// d_addr at the end of execute, as ROM port B and the RAM do, so they answer
// in W; while w_wait holds W the CPU keeps d_addr on the access and they read
// it again every clock.
//
// W (bup_cpu S1: w_asset, w_addr, w_size). The load completes once every
// halfword it touches is there: one for a byte or halfword load (odd LDRH
// included), both halfwords of the aligned word for LDR. A line is there when
// its tag is valid, or, for the line under fill, halfword by halfword from
// the arrival bits. Neither M10K is trusted on a clock whose read was
// registered on the same edge as a port-B write of the same word (data) or
// line (tags): that is a mixed-port read-during-write, undefined on the
// device. Such a clock waits and the read is simply repeated, which gives the
// design's rule that the replay read comes one clock after the write of the
// last halfword it needs.
//
// Fill. One at a time: line, tag, demand or prefetch, 8 arrival bits. It
// writes the line's tag invalid as it starts, reads the 8 halfwords from the
// critical one (the one holding the access's lowest byte) round the line, and
// writes the tag valid with the last. A miss costs 8 clocks over a hit (13
// for LDR) with psram.sv's 5 clocks per halfword. A load on the line under
// fill waits for its halfwords without starting anything.
//
// Prefetch (PREFETCH). After every asset access the next line is probed on
// tag port B once no fill is running (the latest access's next line waits
// for that); if it is neither valid nor under fill it is fetched from
// halfword 0.
//
// Pre-emption (PREEMPT). A demand miss stops a running fill from issuing more
// reads, waits for the halfword in flight (psram.sv cannot abort a read), and
// starts its own fill. The pre-empted line keeps the invalid tag its fill
// started with. With PREEMPT = 0 a miss waits for the whole fill.
//
// Sweep. Whenever pre_run (not held, firmware and assets ready) is low the
// sweep restarts; once it is high, 64 clocks write every tag invalid, then
// sweep_done lets the CPU run. The fill and prefetch machines are held while
// run (cpu_run) is low and issue no read then; a read already in flight
// finishes in psram.sv (at most 5 clocks into the hold) and is dropped: its
// halfword can land only in the first held clock, in the line it was filling,
// whose tag is invalid.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_asset_cache #(
	parameter bit PREEMPT  = 1'b1,      // a demand miss pre-empts a running fill
	parameter bit PREFETCH = 1'b1       // next-line prefetch
) (
	input  wire         clk,            // clk_arm
	input  wire         pre_run,        // ~hold & fw_loaded & asset_ready
	input  wire         run,            // cpu_run = pre_run & sweep_done, registered
	output logic        sweep_done = 1'b0,

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
	// ---- fill state -------------------------------------------------------------
	logic        f_act = 1'b0;          // a fill is running
	logic        f_fl = 1'b0;           // one of its reads is in flight
	logic        stop = 1'b0;           // a demand miss waits to pre-empt: issue no more
	logic  [5:0] f_idx = 6'd0;
	logic [12:0] f_tag = 13'd0;
	logic  [7:0] f_arr = 8'd0;          // halfwords arrived
	logic  [2:0] f_rq_hw = 3'd0;        // next halfword to read
	logic  [2:0] f_fl_hw = 3'd0;        // the halfword in flight
	logic  [3:0] f_rq_n = 4'd0;         // reads left to issue
	logic  [3:0] f_rx_n = 4'd0;         // halfwords left to arrive

	// ---- memories -------------------------------------------------------------------
	logic        tb_we;
	logic  [5:0] tb_addr;
	logic [13:0] tb_wd;
	wire  [13:0] tq_a, tq_b;
	cache_ram_tdp_dc #(.ADDR_WIDTH(6), .DATA_WIDTH(14)) tags (
		.clk_a_i(clk), .addr_a_i(d_addr[9:4]), .wren_a_i(1'b0), .wdata_a_i(14'd0), .q_a_o(tq_a),
		.clk_b_i(clk), .addr_b_i(tb_addr), .wren_b_i(tb_we), .wdata_b_i(tb_wd), .q_b_o(tq_b));

	wire rx = rd_avail && f_fl;         // the halfword in flight arrives
	cache_ram_tdp_dc_be #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) data (
		.clk_a_i(clk), .addr_a_i(d_addr[9:2]), .wren_a_i(1'b0), .byteena_a_i(4'd0),
		.wdata_a_i(32'd0), .q_a_o(asset_q),
		.clk_b_i(clk), .addr_b_i({f_idx, f_fl_hw[2:1]}), .wren_b_i(rx),
		.byteena_b_i(f_fl_hw[0] ? 4'b1100 : 4'b0011), .wdata_b_i({rd_data, rd_data}), .q_b_o());

	// Port-B writes of last clock: a port-A read registered on the same edge
	// is not used.
	logic       tw_q = 1'b0, dw_q = 1'b0;
	logic [5:0] tw_idx_q = 6'd0;
	logic [7:0] dw_a_q = 8'd0;

	// ---- W --------------------------------------------------------------------------
	wire  [5:0] idx  = w_addr[9:4];
	wire [12:0] tag  = w_addr[22:10];
	wire  [7:0] need = w_size == 2'd2 ? 8'b11 << {w_addr[3:2], 1'b0} : 8'b1 << w_addr[3:1];
	wire  [2:0] crit = w_size == 2'd2 ? {w_addr[3:2], 1'b0} : w_addr[3:1];
	wire in_fill = f_act && f_idx == idx && f_tag == tag;
	wire tcol    = tw_q && tw_idx_q == idx;
	wire dcol    = dw_q && dw_a_q == w_addr[9:2];
	wire thit    = tq_a[13] && tq_a[12:0] == tag;
	wire have    = in_fill ? (f_arr & need) == need : thit;
	assign w_wait = w_asset && !(have && !tcol && !dcol);
	wire miss    = w_asset && !in_fill && !thit && !tcol;
	wire acc_done = w_asset && !w_wait;

	wire start_dem = run && miss && (!f_act || (PREEMPT && !f_fl && !rd_ack));

	// ---- prefetch probe ------------------------------------------------------------
	logic        pf_pend = 1'b0, probe_v = 1'b0;
	logic [18:0] pf_line = 19'd0, probe_line = 19'd0;	// {tag, line}
	wire pf_have  = (tq_b[13] && tq_b[12:0] == probe_line[18:6]) || (f_act && {f_tag, f_idx} == probe_line);
	wire start_pf = PREFETCH && run && probe_v && !pf_have && !f_act && !start_dem;
	wire probe_go = PREFETCH && run && pf_pend && !f_act && !start_dem && !start_pf;
	wire fill_end = rx && f_rx_n == 4'd1;

	// Tag port B: the sweep, a fill's start (invalid) and end (valid), or a
	// probe read. At most one of the writes can want it in any clock.
	logic [5:0] sw_cnt = 6'd0;
	always_comb begin
		tb_we = 1'b0;
		tb_addr = pf_line[5:0];
		tb_wd = 14'd0;
		if (!sweep_done) begin
			tb_we = pre_run;
			tb_addr = sw_cnt;
		end else if (start_dem) begin
			tb_we = 1'b1;
			tb_addr = idx;
		end else if (start_pf) begin
			tb_we = 1'b1;
			tb_addr = probe_line[5:0];
		end else if (fill_end) begin
			tb_we = 1'b1;
			tb_addr = f_idx;
			tb_wd = {1'b1, f_tag};
		end
	end

	// Not while held: in the first held clock f_act is still set, and a read
	// issued then would keep psram.sv busy into the hold for nothing.
	assign rd_req  = run && f_act && f_rq_n != 4'd0 && !stop && (!f_fl || rx);
	assign rd_addr = {f_tag, f_idx, f_rq_hw};

	always_ff @(posedge clk) begin
		tw_q <= tb_we;
		tw_idx_q <= tb_addr;
		dw_q <= rx;
		dw_a_q <= {f_idx, f_fl_hw[2:1]};

		if (!pre_run) begin
			sw_cnt <= 6'd0;
			sweep_done <= 1'b0;
		end else if (!sweep_done) begin
			sw_cnt <= sw_cnt + 6'd1;
			if (sw_cnt == 6'd63) sweep_done <= 1'b1;
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
				f_idx <= start_dem ? idx : probe_line[5:0];
				f_tag <= start_dem ? tag : probe_line[18:6];
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
