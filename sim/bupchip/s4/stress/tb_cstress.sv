//------------------------------------------------------------------------------
// Corner-case stress of the asset cache (src/fpga/core/bupchip/
// bup_asset_cache.sv) behind bup_asset_wr's arbiter, for step 4 of
// docs/BUPCHIP_CORE.md. It complements ../tb_cache.sv: where that one runs
// directed scenarios and random streams on psram.sv's fixed 5 clocks, this one
// sweeps the corners exhaustively, on a PSRAM whose latency can vary
// (psram_var.sv, the default) or on psram.sv with psram_model.sv
// (-DPSRAM_REAL), and with M10K models that return garbage on a mixed-port
// read-during-write (cache_ram_poison.v), so a load that completes on such a
// read gives wrong data instead of quietly the old word. Built with -DWAYS2
// the cache has WAYS = 2 (DARIA's 128 sets of 2 ways), otherwise WAYS = 1
// (64 lines, direct-mapped, as in step 4); "index" below is the set, and
// every check covers both ways.
//
// The driver behaves as bup_cpu S1 does at the asset port (as tb_cache.sv's):
// an execute clock with the address on d_addr, then W (w_asset, w_addr,
// w_size) with d_addr held while w_wait is high; a hold (pre_run low) resets
// it, dropping a load still in W.
//
// Modes (+mode=, default all):
//   pairs   every pair of loads: the first (every size 0-2 at every offset
//           0-15 of a cold line), then d = 0..DMAX other instructions, then
//           the second (every size at every offset) on the same line, the
//           next line (the prefetch's), a line at the same index (other tag),
//           a line at the next line's index (other tag), or an unrelated cold
//           line. With the fixed latency, d walks the second load across every
//           position of the first line's fill and of the prefetch after it.
//           +pstep=N takes every Nth pair (default 1: all 518,400).
//   holds   a hold of 1, 2, 3, 9 or 70 clocks dropped h = 0..60 clocks after
//           a miss's W starts, or after a prefetch starts, with four other
//           lines valid; during the hold the PSRAM's contents change (a
//           reload), so after the release every line must miss and return
//           the new contents.
//   random  +loads=N (default 300,000) loads as tb_cache.sv mixes them, with
//           a hold (and new contents) of 1-100 clocks at a random point every
//           few thousand loads.
//
// Checked on every clock:
//   - every completed load returns the contents in effect (each byte it
//     touches), and none completes on a read registered on the same edge as
//     a port-B write to the same data word or tag line (from the RAM ports);
//   - every data M10K write goes to a line whose tag is invalid at that edge;
//     while held only in the first held clock;
//   - at the first clock the cache runs after a hold, all tags are invalid;
//   - with two ways, no line valid in both ways, nor valid in either while
//     it is under fill ("dup");
//   - each time a tag is written valid, and every 2,048 clocks for all valid
//     lines, the line's data in the M10K equals the PSRAM's;
//   - no load waits more than 60 + 20 x the longest latency clocks.
// It also records how long each load waited beyond the earliest clock the
// rule allows (the last needed halfword written two edges before, in the way
// that holds the line, no write to the same word of either way on the edge
// its read was registered): "excess" histogram.
//
//   +seed=S  +plmin=N +plmax=N (psram_var.sv)  +dmax=N (pairs, default 44)
// The last line, "result: ...", is for run_cstress.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
`ifndef PREEMPT
`define PREEMPT 1
`endif
`ifndef PREFETCH
`define PREFETCH 1
`endif
`ifdef WAYS2
`define WAYS 2
`else
`define WAYS 1
`endif

module tb_cstress;
	logic clk = 0;
	always #17460 clk = ~clk;

	// The cache's geometry: line(tag, set) = tag * WB + set * 16.
	localparam int WAYS = `WAYS;
	localparam int SB = WAYS == 2 ? 7 : 6;          // set bits
	localparam int NS = 1 << SB;                    // sets
	localparam int TWB = 19 - SB;                   // tag bits
	localparam int WB = NS * 16;                    // bytes per way

	// ---- PSRAM and the arbiter -------------------------------------------------------------
	wire        p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire [21:0] p_addr;
	wire [15:0] p_din, p_dout;
	wire        rd_req, rd_ack;
	wire [21:0] rd_addr;

	bup_asset_wr wr (
		.clk, .msg_type(3'd0), .msg_pl(44'd0), .msg_tog(1'b0),
		.asset_ready(), .asset_size(), .fw_loaded(), .rom_we(), .rom_wa(), .rom_wd(),
		.rd_req, .rd_addr, .rd_ack,
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun());

	int epoch = 0;
	function automatic logic [7:0] pat(input int ep, input int b);	// = psram_var.sv's
		logic [31:0] x;
		x = (b ^ (ep * 32'h5BD1E995)) * 32'h9E3779B1;
		return x[23:16] ^ x[7:0] ^ 8'(b >> 8) ^ 8'(ep * 77);
	endfunction

	int size = 1 << 23;                             // bytes of asset space in use
`ifdef PSRAM_REAL
	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(28.636364)) ps (
		.clk, .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	localparam int LMAX_ALL = 5;
	task automatic set_epoch(input int ep);
		epoch = ep;
		// one line more: a prefetch may read the line after the last
		for (int h = 0; h < size / 2 + 8; h++) chip.bd_write(0, h, {pat(ep, 2 * h + 1), pat(ep, 2 * h)}, 2'b11);
	endtask
	function automatic int lat_max();
		return 5;
	endfunction
`else
	psram_var ps (
		.clk, .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy));
	task automatic set_epoch(input int ep);
		epoch = ep;
		ps.epoch = ep;
	endtask
	function automatic int lat_max();
		return ps.lmax;
	endfunction
`endif

	// ---- the cache -----------------------------------------------------------------------------
	logic        pre_run = 0, run = 0;
	wire         sweep_done;
	logic [31:0] d_addr = 0, w_addr = 0;
	logic        w_asset = 0;
	logic  [1:0] w_size = 0;
	wire  [31:0] asset_q;
	wire         w_wait, st_miss, st_pf, st_preempt, st_late, st_stall;
	always @(posedge clk) run <= pre_run && sweep_done;

	bup_asset_cache #(.PREEMPT(`PREEMPT), .PREFETCH(`PREFETCH), .WAYS(`WAYS)) dut (
		.clk, .pre_run, .run, .sweep_done,
		.d_addr, .w_asset, .w_addr, .w_size, .asset_q, .w_wait,
		.rd_req, .rd_addr, .rd_ack, .rd_avail(p_avail), .rd_data(p_dout),
		.st_miss, .st_pf, .st_preempt, .st_late, .st_stall);

	// Way 1's RAMs (WAYS = 2).
`ifdef WAYS2
	wire       dwe1 = dut.way1.data.wren_b_i;
	wire [8:0] dwa1 = dut.way1.data.addr_b_i;
	wire [3:0] dbe1 = dut.way1.data.byteena_b_i;
	wire       twe1 = dut.way1.tags.wren_b_i;
	wire       dcol1 = dut.way1.data.wren_b_i && dut.way1.data.addr_b_i == dut.way1.data.addr_a_i;
	wire       tcol1 = dut.way1.tags.wren_b_i && dut.way1.tags.addr_b_i == dut.way1.tags.addr_a_i;
	function automatic longint pois1_d();
		return dut.way1.data.n_poison;
	endfunction
	function automatic longint pois1_t();
		return dut.way1.tags.n_poison;
	endfunction
`else
	wire       dwe1 = 1'b0, twe1 = 1'b0, dcol1 = 1'b0, tcol1 = 1'b0;
	wire [8:0] dwa1 = 9'd0;
	wire [3:0] dbe1 = 4'd0;
	function automatic longint pois1_d();
		return 0;
	endfunction
	function automatic longint pois1_t();
		return 0;
	endfunction
`endif
	// A way's tag word for a set ([13] valid, [TWB-1:0] tag) and data word.
	function automatic logic [13:0] tagw(input int w, input int s);
`ifdef WAYS2
		if (w != 0) return dut.way1.tags.mem_q[s];
`endif
		return dut.tags.mem_q[s];
	endfunction
	function automatic logic [31:0] dataw(input int w, input int a);
`ifdef WAYS2
		if (w != 0) return dut.way1.data.mem_q[a];
`endif
		return dut.data.mem_q[a];
	endfunction
	function automatic bit holds(input int w, input int s, input int t);
		logic [13:0] q;
		q = tagw(w, s);
		return q[13] && int'(q[TWB-1:0]) == t;
	endfunction

	// ---- commands --------------------------------------------------------------------------------
	localparam int K_LOAD = 0, K_IDLE = 1, K_WAITIDLE = 2, K_ARM = 3;
	typedef struct { int kind; int a; int b; int c; } cmd_t;
	cmd_t q[$];

	function automatic int rnd(input int n);
		return n <= 1 ? 0 : $urandom_range(n - 1);
	endfunction

	function automatic bit cache_idle();
		return !dut.f_act && !dut.pf_pend && !dut.probe_v && !p_busy && !p_avail;
	endfunction

	task automatic c_load(input int off, input int sz);
		q.push_back('{K_LOAD, off, sz, 0});
	endtask
	task automatic c_idle(input int n);
		if (n > 0) q.push_back('{K_IDLE, n, 0, 0});
	endtask
	task automatic c_waitidle();
		q.push_back('{K_WAITIDLE, 0, 0, 0});
	endtask
	task automatic c_arm(input int h, input int len, input int trig);
		q.push_back('{K_ARM, h, len, trig});
	endtask

	// ---- counters ----------------------------------------------------------------------------------
	longint cyc = 0, n_loads = 0, bad = 0, rdw_bad = 0, stuck = 0, held_wr = 0, held_wr1 = 0, wr_valid = 0;
	longint sweep_bad = 0, line_bad = 0, line_checks = 0, n_holds = 0, n_holds_fill = 0, n_holds_fl = 0, n_dropped = 0, dup = 0;
	longint c_miss = 0, c_pf = 0, c_pre = 0, c_late = 0, c_stall = 0, max_wait = 0, n_arm = 0, n_fired = 0;
	longint exc_hist [0:11];
	longint pairs_done = 0, holds_done = 0;
	initial for (int i = 0; i < 12; i++) exc_hist[i] = 0;

	// ---- data M10K write history (for the excess measure) ----------------------------------------------
	// Way y's halfword h is entry y * NS * 8 + h, its word w y * NS * 4 + w.
	longint lastw [0:WAYS * NS * 8 - 1];        // per halfword of the data M10Ks: edge of its last write
	longint wr_hist [0:WAYS * NS * 4 - 1][0:3]; // per word: its last four write edges
	initial begin
		for (int i = 0; i < WAYS * NS * 8; i++) lastw[i] = -100;
		for (int i = 0; i < WAYS * NS * 4; i++) for (int k = 0; k < 4; k++) wr_hist[i][k] = -100;
	end
	// Word w of either way written on edge e.
	function automatic bit word_written_at(input int w, input longint e);
		for (int y = 0; y < WAYS; y++)
			for (int k = 0; k < 4; k++) if (wr_hist[y * NS * 4 + w][k] == e) return 1;
		return 0;
	endfunction

	// A line's 16 bytes in a way's data M10K against the contents in effect.
	function automatic bit line_ok(input int y, input int idx, input int tag);
		for (int w = 0; w < 4; w++) begin
			logic [31:0] v;
			v = dataw(y, idx * 4 + w);
			for (int k = 0; k < 4; k++)
				if (v[8 * k +: 8] !== pat(epoch, tag * WB + (idx << 4) + 4 * w + k)) return 0;
		end
		return 1;
	endfunction

	// ---- driver ------------------------------------------------------------------------------------
	int     st = 0;                             // 0 next command, 1 execute, 2 W, 3 idle, 4 wait idle, 5 held
	int     idle_left = 0, idle_wait = 0;
	int     cur_off = 0, cur_sz = 0, cur_ep = 0;
	longint x_edge = 0, wait_clk = 0;
	logic   run_q = 0;
	logic   col_d = 0, col_t = 0;
	int     limit;
	// the hold trigger
	bit     armed = 0, counting = 0, first_held = 0;
	int     arm_h = 0, arm_len = 0, arm_trig = 0, hold_left = 0;
	longint arm_cnt = 0;
	int     chk_line_idx = -1, chk_line_tag = 0, chk_line_way = 0;
	bit     gen_done = 0;
	logic   tick_fill_end = 0;

	// A data M10K write seen at this edge.
	task automatic data_write(input int y, input int a, input logic [3:0] be);
		int h, i;
		h = be == 4'b1100 ? 1 : 0;
		if (be != 4'b1100 && be != 4'b0011) begin
			$display("data M10K write with byte enables %b", be);
			bad++;
		end
		lastw[y * NS * 8 + a * 2 + h] = cyc;
		i = y * NS * 4 + a;
		for (int k = 3; k > 0; k--) wr_hist[i][k] = wr_hist[i][k - 1];
		wr_hist[i][0] = cyc;
		if (tagw(y, a >> 2)[13]) begin
			if (wr_valid < 5) $display("clock %0d: data M10K write into line %0d, whose tag is valid", cyc, a >> 2);
			wr_valid++;
		end
		if (!run) begin
			if (run_q) held_wr1++;
			else held_wr++;
		end
	endtask

	task automatic fire_hold();
		pre_run <= 0;
		hold_left = arm_len;
		armed = 0;
		counting = 0;
		n_fired++;
		n_holds++;
		if (dut.f_act) n_holds_fill++;
		if (dut.f_act && dut.f_fl) n_holds_fl++;
		first_held = 1;
	endtask

	// Start the next command in this clock (st 0).
	task automatic next_cmd();
		cmd_t c;
		forever begin
			if (q.size() == 0) refill();
			if (q.size() == 0) begin
				gen_done = 1;
				w_asset <= 0;
				d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
				st = 0;
				return;
			end
			c = q.pop_front();
			case (c.kind)
				K_LOAD: begin
					cur_off = c.a;
					cur_sz = c.b;
					w_asset <= 0;
					d_addr <= 32'h0200_0000 | 32'(c.a);
					st = 1;
					return;
				end
				K_IDLE: begin                  // this clock is the first of c.a
					w_asset <= 0;
					d_addr <= rnd(2) ? 32'h4000_0000 | 32'(rnd(1 << 14)) : 32'h0200_0000 | 32'(rnd(size));
					idle_left = c.a - 1;
					st = 3;
					return;
				end
				K_WAITIDLE: begin
					w_asset <= 0;
					d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
					idle_wait = 0;
					st = 4;
					return;
				end
				K_ARM: begin
					armed = 1;
					counting = 0;
					arm_h = c.a;
					arm_len = c.b;
					arm_trig = c.c;
					n_arm++;
				end
				default: ;
			endcase
		end
	endtask

	always @(posedge clk) begin
		cyc++;
		limit = 60 + 20 * lat_max();

		// ---- observations of the clock that ends at this edge ----
		// data M10K writes
		if (dut.data.wren_b_i) data_write(0, int'(dut.data.addr_b_i), dut.data.byteena_b_i);
		if (dwe1) data_write(1, int'(dwa1), dbe1);
		// a tag written valid: check that line's data next clock (after its last halfword)
		if (chk_line_idx >= 0) begin
			line_checks++;
			if (!line_ok(chk_line_way, chk_line_idx, chk_line_tag)) begin
				if (line_bad < 5) $display("clock %0d: line idx %0d tag %0d written valid with wrong data", cyc, chk_line_idx, chk_line_tag);
				line_bad++;
			end
			chk_line_idx = -1;
		end
		if ((dut.tags.wren_b_i || twe1) && dut.tags.wdata_b_i[13]) begin
			chk_line_idx = int'(dut.tags.addr_b_i);
			chk_line_tag = int'(dut.tags.wdata_b_i[TWB-1:0]);
			chk_line_way = dut.tags.wren_b_i ? 0 : 1;
		end
		// every 2,048 clocks while running: every valid line
		if (run && cyc % 2048 == 0) begin
			for (int y = 0; y < WAYS; y++)
				for (int i = 0; i < NS; i++)
					if (tagw(y, i)[13]) begin
						line_checks++;
						if (!line_ok(y, i, int'(tagw(y, i)[TWB-1:0]))) begin
							if (line_bad < 5) $display("clock %0d: valid line idx %0d tag %0d holds wrong data", cyc, i, tagw(y, i)[TWB-1:0]);
							line_bad++;
						end
					end
		end
		// two ways: the line under fill valid in neither way, no line in both
		// (the fill's set every clock, all sets every 1,024 clocks)
		if (WAYS == 2) begin
			if (dut.f_act && (holds(0, int'(dut.f_idx), int'(dut.f_tag)) || holds(1, int'(dut.f_idx), int'(dut.f_tag)))) begin
				if (dup < 5) $display("clock %0d: the line under fill (set %0d, tag %0d) is valid in a way", cyc, dut.f_idx, dut.f_tag);
				dup++;
			end
			for (int i = cyc % 1024 == 0 ? 0 : int'(dut.f_idx); i < (cyc % 1024 == 0 ? NS : int'(dut.f_idx) + 1); i++)
				if (tagw(0, i)[13] && tagw(1, i)[13] && tagw(0, i)[TWB-1:0] == tagw(1, i)[TWB-1:0]) begin
					if (dup < 5) $display("clock %0d: set %0d holds tag %0d in both ways", cyc, i, tagw(0, i)[TWB-1:0]);
					dup++;
				end
		end
		// statistics
		if (run) begin
			if (st_miss) c_miss++;
			if (st_pf) c_pf++;
			if (st_preempt) c_pre++;
			if (st_late) c_late++;
			if (st_stall) c_stall++;
		end
		// completion on a collided read (from the RAM ports, as tb_cache.sv)
		if (w_asset && !w_wait && run && (col_d || col_t)) rdw_bad++;
		col_d = dut.data.wren_b_i && dut.data.addr_b_i == dut.data.addr_a_i || dcol1;
		col_t = dut.tags.wren_b_i && dut.tags.addr_b_i == dut.tags.addr_a_i || tcol1;

		// ---- the hold trigger ----
		if (hold_left > 0) begin
			hold_left--;
			if (hold_left == 0) pre_run <= 1;
		end
		if (armed && counting) begin
			arm_cnt++;
			if (arm_cnt >= arm_h) fire_hold();
		end
		if (armed && !counting && arm_trig == 1 && st_pf && run) begin
			counting = 1;
			arm_cnt = 0;
			if (arm_h == 0) fire_hold();
		end
		// first held clock: the PSRAM's contents change (a reload)
		if (!run && first_held) begin
			first_held = 0;
			set_epoch(epoch + 1);
		end
		// first clock running after a hold: every tag invalid
		if (run && !run_q && cyc > 1) begin
			int nv;
			nv = 0;
			for (int y = 0; y < WAYS; y++) for (int i = 0; i < NS; i++) if (tagw(y, i)[13]) nv++;
			if (nv != 0) begin
				if (sweep_bad < 5) $display("clock %0d: %0d tags valid at the first clock after a hold", cyc, nv);
				sweep_bad++;
			end
		end
		run_q = run;

		// ---- the driver ----
		if (!run) begin
			if (st == 1 || st == 2) n_dropped++;
			if (st != 0 || gen_done == 0) st = 5;
			w_asset <= 0;
			d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
		end else case (st)
			5: next_cmd();
			0: next_cmd();
			1: begin                               // execute ends: W next
				w_asset <= 1;
				w_addr <= 32'h0200_0000 | 32'(cur_off);
				w_size <= 2'(cur_sz);
				d_addr <= 32'h0200_0000 | 32'(cur_off);
				x_edge = cyc;
				wait_clk = 0;
				cur_ep = epoch;
				st = 2;
				if (armed && arm_trig == 0) begin
					counting = 1;
					arm_cnt = 0;
					if (arm_h == 0) fire_hold();
				end
			end
			2: begin                               // W
				if (w_wait) begin
					wait_clk++;
					if (wait_clk == limit) begin
						stuck++;
						$display("clock %0d: load at %0d size %0d waits %0d clocks", cyc, cur_off, cur_sz, limit);
					end
				end else begin
					int a, line, idx, need, lo, hi, t, wy;
					logic [31:0] e;
					logic  [3:0] m;
					bit ok;
					longint maxe, c;
					a = cur_off & ~3;
					for (int k = 0; k < 4; k++) e[8 * k +: 8] = pat(cur_ep, a + k);
					m = cur_sz == 2 ? 4'b1111 : cur_off[1] ? 4'b1100 : 4'b0011;
					ok = 1;
					for (int k = 0; k < 4; k++)
						if (m[k] && asset_q[8 * k +: 8] !== e[8 * k +: 8]) ok = 0;
					if (!ok) begin
						if (bad < 10) $display("clock %0d: load %0d at %0d size %0d: %08x, expected %08x (lanes %b, epoch %0d)",
							cyc, n_loads, cur_off, cur_sz, asset_q, e, m, cur_ep);
						bad++;
					end
					// excess over the earliest clock the rule allows, in the
					// way that holds the line (or fills it)
					idx = (cur_off >> 4) & (NS - 1);
					t = cur_off / WB;
					wy = holds(0, idx, t) ? 0 : holds(1, idx, t) ? 1
						: dut.f_act && int'(dut.f_idx) == idx && int'(dut.f_tag) == t ? int'(dut.f_way) : 0;
					lo = cur_sz == 2 ? ((cur_off >> 1) & 6) : ((cur_off >> 1) & 7);
					hi = cur_sz == 2 ? lo + 1 : lo;
					maxe = -100;
					for (int h = lo; h <= hi; h++) if (lastw[(wy * NS + idx) * 8 + h] > maxe) maxe = lastw[(wy * NS + idx) * 8 + h];
					c = x_edge + 1;
					if (maxe + 2 > c) c = maxe + 2;
					while (word_written_at((cur_off >> 2) & (NS * 4 - 1), c - 1)) c++;
					exc_hist[cyc - c < 0 ? 11 : cyc - c > 10 ? 10 : cyc - c]++;
					if (wait_clk > max_wait) max_wait = wait_clk;
					n_loads++;
					next_cmd();
				end
			end
			3: begin                               // other instructions
				if (idle_left <= 0) next_cmd();
				else begin
					idle_left--;
					w_asset <= 0;
					d_addr <= rnd(2) ? 32'h4000_0000 | 32'(rnd(1 << 14)) : 32'h0200_0000 | 32'(rnd(size));
				end
			end
			4: begin                               // wait for the cache to go idle
				w_asset <= 0;
				d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
				idle_wait++;
				if (idle_wait == 20000) begin
					stuck++;
					$display("clock %0d: the cache did not go idle in 20,000 clocks (fill %0d, prefetch pending %0d)",
						cyc, dut.f_act, dut.pf_pend);
				end
				if (cache_idle()) next_cmd();
			end
			default: ;
		endcase
	end

	// ---- generators -------------------------------------------------------------------------------
	string mode = "all";
	int    phase = 0;                           // all: 0 pairs, 1 holds, 2 random
	int    pstep = 1, dmax = 44;
	longint pi = 0, ptotal = 0, hi_ = 0, htotal = 0, rleft = 300000, rtotal = 0;
	int    nlines, hb, qb, base = 0;
	int    vptr[16], vstep[16], recent[8], nrecent = 0;
	localparam int HMAX = 60;
	int    hlens[5] = '{1, 2, 3, 9, 70};

	function automatic int fresh();
		base = (base + 2) % qb;
		return base;
	endfunction

	task automatic gen_pair();
		longint i;
		int c_sz, c_off, kind, s_sz, s_off, d, b, l2;
		i = pi;
		d = int'(i % (dmax + 1)); i /= (dmax + 1);
		s_off = int'(i % 16); i /= 16;
		s_sz = int'(i % 3); i /= 3;
		kind = int'(i % 5); i /= 5;
		c_off = int'(i % 16); i /= 16;
		c_sz = int'(i % 3);
		b = fresh();
		case (kind)
			0: l2 = b;                         // the same line (under fill)
			1: l2 = b + 1;                     // the next line (the prefetch's)
			2: l2 = b + hb;                    // same index, other tag
			3: l2 = b + 1 + hb;                // the prefetch's index, other tag
			default: l2 = ((b + qb) ^ 21);     // unrelated, cold
		endcase
		c_waitidle();
		c_load(b * 16 + c_off, c_sz);
		c_idle(d);
		c_load(l2 * 16 + s_off, s_sz);
		pi += pstep;
		pairs_done++;
	endtask

	task automatic gen_hold();
		longint i;
		int trig, h, li, s[4], m;
		i = hi_;
		h = int'(i % (HMAX + 1)); i /= (HMAX + 1);
		li = int'(i % 5); i /= 5;
		trig = int'(i % 2);
		c_waitidle();
		for (int k = 0; k < 4; k++) begin
			s[k] = fresh();
			c_load(s[k] * 16 + 4 * rnd(4), 2);
		end
		c_waitidle();
		c_arm(h, hlens[li], trig);
		m = fresh();
		if (trig == 0) c_load(m * 16 + rnd(16), rnd(3));
		else c_load(s[0] * 16 + rnd(16), 0);   // a hit: the prefetch of s[0] + 1 follows
		c_idle(HMAX + 200);                     // the hold lands in here (or in the load)
		for (int k = 0; k < 4; k++) for (int w = 0; w < 16; w += 4) c_load(s[k] * 16 + w, 2);
		for (int w = 0; w < 16; w += 4) c_load(m * 16 + w, 2);
		for (int w = 0; w < 16; w += 4) c_load((s[0] + 1) * 16 + w, 2);
		hi_++;
		holds_done++;
	endtask

	task automatic gen_random();
		int r, v, b, o;
		r = rnd(100);
		if (rnd(3000) == 0) c_arm(rnd(61), 1 + rnd(100), rnd(2));
		if (r < 50) begin                          // voices
			v = rnd(16);
			vptr[v] = (vptr[v] + vstep[v]) % size;
			c_load(vptr[v], 0);
		end else if (r < 58) begin                 // a cold line, the boot's way
			b = rnd(size / 16) * 16;
			for (int k = 0; k < 4; k++) c_load(b + k, 0);
			c_load(b + 4, 2);
			c_load(b + 8, 2);
		end else if (r < 70) begin                 // conflict: same index, other tag
			o = recent[rnd(8)];
			o = ((o & (WB - 16)) | (rnd(size / WB) * WB) | rnd(16)) % size;
			c_load(o, rnd(3));
		end else begin                             // anything
			o = rnd(size);
			c_load(o, rnd(3));
			recent[nrecent++ % 8] = o;
		end
		r = rnd(10);
		c_idle(r < 4 ? 0 : r < 8 ? rnd(4) : rnd(41));
		rleft--;
		rtotal++;
	endtask

	task automatic refill();
		while (q.size() == 0) begin
			if (phase == 0) begin
				if ((mode == "all" || mode == "pairs") && pi < ptotal) gen_pair();
				else phase = 1;
			end else if (phase == 1) begin
				if ((mode == "all" || mode == "holds") && hi_ < htotal) gen_hold();
				else phase = 2;
			end else if (phase == 2) begin
				if ((mode == "all" || mode == "random") && rleft > 0) gen_random();
				else return;
			end
		end
	endtask

	int seed = 1;
	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("mode=%s", mode));
		void'($value$plusargs("pstep=%d", pstep));
		void'($value$plusargs("dmax=%d", dmax));
		void'($value$plusargs("loads=%d", rleft));
		void'($value$plusargs("size=%d", size));
		void'($urandom(seed));
		nlines = size / 16;
		hb = nlines / 2;
		qb = nlines / 4;
		ptotal = longint'(3) * 16 * 5 * 3 * 16 * (dmax + 1);
		htotal = 2 * 5 * (HMAX + 1);
		for (int v = 0; v < 16; v++) begin
			vptr[v] = rnd(size);
			vstep[v] = 1 + rnd(3);
		end
		for (int k = 0; k < 8; k++) recent[k] = rnd(size);
		set_epoch(seed * 1000);
		repeat (10) @(posedge clk);
		pre_run <= 1;
		while (!gen_done && stuck == 0) @(posedge clk);
		repeat (200) @(posedge clk);
		$display("cache stress, %s, pre-emption %0d, prefetch %0d, PSRAM latency %0d..%0d, %0d bytes: %0d loads (%0d pairs, %0d hold items, %0d random) in %0d clocks",
			WAYS == 2 ? "2 ways" : "1 way", `PREEMPT, `PREFETCH,
`ifdef PSRAM_REAL
			5, 5,
`else
			ps.lmin, ps.lmax,
`endif
			size, n_loads, pairs_done, holds_done, rtotal, cyc);
		$display("  %0d wrong, %0d completed on a collided read, %0d stuck (longest wait %0d)", bad, rdw_bad, stuck, max_wait);
		$display("  %0d demand misses, %0d prefetches, %0d pre-emptions, %0d late hits, %0d stall clocks",
			c_miss, c_pf, c_pre, c_late, c_stall);
		$display("  holds: %0d armed, %0d fired, %0d during a fill (%0d with a read in flight), %0d loads dropped by them",
			n_arm, n_fired, n_holds_fill, n_holds_fl, n_dropped);
		$display("  data M10K: %0d writes into a valid line, %0d in the first held clock, %0d later while held; poisoned reads: data %0d, tags %0d",
			wr_valid, held_wr1, held_wr, dut.data.n_poison + pois1_d(), dut.tags.n_poison + pois1_t());
		$display("  sweep: %0d releases with a valid tag; lines: %0d checks, %0d wrong", sweep_bad, line_checks, line_bad);
		if (WAYS == 2) $display("  ways: %0d clocks with a line in both ways or valid while under fill", dup);
		$display("  excess wait over the rule's earliest clock: 0:%0d 1:%0d 2:%0d 3:%0d 4:%0d 5-9:%0d >=10:%0d early(<0):%0d",
			exc_hist[0], exc_hist[1], exc_hist[2], exc_hist[3], exc_hist[4],
			exc_hist[5] + exc_hist[6] + exc_hist[7] + exc_hist[8] + exc_hist[9], exc_hist[10], exc_hist[11]);
`ifdef PSRAM_REAL
		chip.report();
		$display("result: loads=%0d bad=%0d rdw=%0d stuck=%0d wrvalid=%0d heldwr=%0d sweep=%0d linebad=%0d viol=%0d fired=%0d armed=%0d bank1=0 early=%0d dup=%0d",
			n_loads, bad, rdw_bad, stuck, wr_valid, held_wr, sweep_bad, line_bad, chip.n_viol, n_fired, n_arm, exc_hist[11], dup);
`else
		$display("  PSRAM latency histogram: %0d at %0d .. %0d at %0d", ps.lat_hist[ps.lmin], ps.lmin, ps.lat_hist[ps.lmax], ps.lmax);
		$display("result: loads=%0d bad=%0d rdw=%0d stuck=%0d wrvalid=%0d heldwr=%0d sweep=%0d linebad=%0d viol=0 fired=%0d armed=%0d bank1=%0d early=%0d dup=%0d",
			n_loads, bad, rdw_bad, stuck, wr_valid, held_wr, sweep_bad, line_bad, n_fired, n_arm, ps.n_bank1, exc_hist[11], dup);
`endif
		$finish;
	end
endmodule
