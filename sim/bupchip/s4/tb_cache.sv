//------------------------------------------------------------------------------
// Directed and random load streams on the asset cache
// (src/fpga/core/bupchip/bup_asset_cache.sv), behind bup_asset_wr's PSRAM
// arbitration and psram.sv on psram_model.sv (or, with -DPSRAM_STANDIN,
// psram_standin.sv), at 28.636 MHz. Step 4 of docs/BUPCHIP_CORE.md.
//
// The driver behaves as bup_cpu S1 does at the asset port: an execute clock
// with the load's address on d_addr, then W (w_asset, w_addr, w_size) with
// d_addr held on the access for as long as w_wait is high, then the next
// instruction's execute clock. Between loads it runs other instructions, with
// unrelated addresses on d_addr. A hold (pre_run low) resets the "CPU" and
// the cache's fill and prefetch; the sweep then runs again.
//
// The PSRAM holds +size bytes (default 64 KiB) of a known pattern, and one
// line more for the prefetch past the end, loaded through the model's
// backdoor. Every completed load must return the pattern in each byte it
// touches: the byte, the aligned halfword, or the aligned word. Also, all the
// time: no load completes on an M10K read registered on the same edge as a
// port-B write to the same address (checked from the RAM instances' ports),
// no load waits 200 clocks, the cache starts no PSRAM read while held, and
// the data M10K is not written while the cache is held (a read in flight when
// the hold came may still land in the first held clock, into the line whose
// fill it was: its tag is invalid then).
//
// Directed phase first. Each scenario puts the line it tests in a known
// state: its index first holds another tag (whose bytes all differ from the
// new line's), so a stale read is a wrong byte.
//   A1  the boot's byte reads of a cold line (fw 0xac, 0xc0, 0xc8, 0xec: bytes
//       0-3 with 4, 1 and 2 instructions between) and its word loads at +4 and
//       +8 (fw 0xf8, 0xfc): one demand miss, every byte right
//   A2  the same bytes and words back to back: byte 2 waits for halfword 1,
//       written on the edge its first read was registered (the replay rule)
//   B   a word-load (LDR) miss, an unaligned LDR miss and an odd LDRH miss on
//       an idle cache: they complete after exactly 13, 13 and 8 W clocks
//   C   a hit on the line under fill (a byte in its last halfword): no new
//       fill, a late hit, right data
//   D1  a demand miss while the next-line prefetch runs (PREFETCH): with
//       PREEMPT it pre-empts the prefetch within 14 clocks and the
//       pre-empted line must miss again; without, it waits for the prefetch,
//       which then hits
//   D2  a demand miss while the previous demand fill runs: the same
//   E1  a hold while a fill has a read in flight, after its load completed:
//       the line misses again after the release
//   E2  a hold while W waits on a miss with a read in flight: the load is
//       dropped (the CPU is reset), and misses again after the release
//   E3  a hold while a prefetch has a read in flight (PREFETCH): the same
//   F   a load whose tag read is registered on the edge a prefetch writes
//       that line's tag invalid (PREFETCH): it must wait, not complete on
//       the collided read
//   G   the tag sweep: all 64 lines valid, a hold, and the PSRAM's contents
//       change behind them (every byte, as a reload with another block
//       would); when the cache runs again no tag may be valid, and every
//       line must return the new bytes
// After each scenario the lines it filled are read whole, word by word.
//
// Random phase. The loads, by weight:
//   voices    16 streams of byte loads (LDRSB), each with its own step,
//             as CoreTone's mixer reads samples (prefetch's case)
//   cold      the boot's pattern: byte loads of bytes 0-3 of a cold line,
//             back to back, then word loads of it
//   conflict  a line at the same index as a recent one, other tag
//   random    byte, halfword (odd ones too) and word (unaligned too) loads
//             anywhere
// with 0-40 clocks between loads and, now and then, a hold of 1-100 clocks
// wherever the cache is. The counters below must reach a minimum, so each
// case is known to have happened: demand misses, word-load misses, late hits
// (a load on the line under fill), prefetches, pre-emptions (PREEMPT), a
// demand miss on a line whose fill was pre-empted, holds during a fill.
//
//   +loads=N  (default 200,000)  +seed=S  +size=BYTES
// The last line, "result: ...", is for run_cache.sh.
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

module tb_cache;
	logic clk = 0;
	always #17460 clk = ~clk;

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

`ifdef PSRAM_STANDIN
	psram_standin ps (
		.clk, .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy));
	task automatic preload(input int hw, input logic [15:0] v);
		ps.mem[hw] = v;
	endtask
`else
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
	task automatic preload(input int hw, input logic [15:0] v);
		chip.bd_write(0, hw, v, 2'b11);
	endtask
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

	bup_asset_cache #(.PREEMPT(`PREEMPT), .PREFETCH(`PREFETCH)) dut (
		.clk, .pre_run, .run, .sweep_done,
		.d_addr, .w_asset, .w_addr, .w_size, .asset_q, .w_wait,
		.rd_req, .rd_addr, .rd_ack, .rd_avail(p_avail), .rd_data(p_dout),
		.st_miss, .st_pf, .st_preempt, .st_late, .st_stall);

	// ---- the pattern ---------------------------------------------------------------------------
	int size = 65536;
	int epoch = 0;                                  // scenario G changes every byte
	function automatic logic [7:0] pat(input int b);
		logic [31:0] x;
		x = b * 32'h9E3779B1;
		return x[23:16] ^ x[7:0] ^ 8'(b >> 8) ^ (epoch != 0 ? 8'hA5 : 8'h00);
	endfunction
	task automatic load_pattern();
		// one line more: a prefetch may read the line after the last
		for (int h = 0; h < size / 2 + 8; h++) preload(h, {pat(2 * h + 1), pat(2 * h)});
	endtask

	// ---- load generator ----------------------------------------------------------------------------
	typedef struct { int off; logic [1:0] sz; } ld_t;
	ld_t    queue[$];
	int     vptr[16], vstep[16];
	int     recent[8];
	int     nrecent = 0;

	function automatic int rnd(input int n);
		return $urandom_range(n - 1);
	endfunction

	task automatic refill();
		int r, v, b, o;
		r = rnd(100);
		if (r < 50) begin                          // voices
			v = rnd(16);
			vptr[v] = (vptr[v] + vstep[v]) % size;
			queue.push_back('{vptr[v], 2'd0});
		end else if (r < 58) begin                 // a cold line, the boot's way
			b = rnd(size / 16) * 16;
			for (int k = 0; k < 4; k++) queue.push_back('{b + k, 2'd0});
			queue.push_back('{b + 4, 2'd2});
			queue.push_back('{b + 8, 2'd2});
		end else if (r < 70) begin                 // conflict: same index, other tag
			o = recent[rnd(8)];
			o = ((o & 32'h3F0) | (rnd(size / 1024) << 10) | rnd(16)) % size;
			queue.push_back('{o, 2'(rnd(3))});
		end else begin                             // anything
			o = rnd(size);
			queue.push_back('{o, 2'(rnd(3))});
		end
	endtask

	// ---- driver ---------------------------------------------------------------------------------
	longint n_loads = 200000, done_loads = 0, bad = 0, cyc = 0, wait_clk = 0, max_wait = 0;
	longint c_miss = 0, c_wmiss = 0, c_pf = 0, c_pre = 0, c_late = 0, c_stall = 0, c_hold = 0, c_hold_fill = 0;
	longint c_remiss = 0, rdw_bad = 0, stuck = 0, held_wr = 0, held_wr1 = 0, rd_held = 0;
	logic   run_q = 0;
	int     state = 0;                              // 0 gap, 1 execute, 2 W, 3 W dropped by a hold
	int     gap = 0, hold_left = 0;
	ld_t    cur;
	logic   col_d = 0, col_t = 0;
	bit     preempted[int];                         // lines whose fill was pre-empted

	// Directed items, taken in order while `directed` is set. A load's gap is
	// the number of other instructions before its execute clock; hold_w > 0
	// drops pre_run for hold_w clocks once its W waits with a read in flight.
	localparam int K_LOAD = 0, K_HOLD = 1, K_IDLE = 2, K_PFRUN = 3, K_HOLDNOW = 4;
	typedef struct { int kind; int off; logic [1:0] sz; int gap; int len; } di_t;
	di_t    dq[$];
	bit     directed = 1;
	// One record per directed load: W clocks waited and the cache's events
	// during its W.
	typedef struct { int off; logic [1:0] sz; int waitc; int miss; int late; int pre; bit ok; bit dropped; } res_t;
	res_t   res[$];
	int     cur_miss = 0, cur_late = 0, cur_pre = 0, cur_hold_w = 0;
	bit     pf_running = 0;

	function automatic bit cache_idle();
		return !dut.f_act && !dut.pf_pend && !dut.probe_v && !p_busy;
	endfunction

	task automatic start_load(input int off, input logic [1:0] sz, input int hold_w);
		cur.off = off;
		cur.sz = sz;
		cur_hold_w = hold_w;
		d_addr <= 32'h0200_0000 | 32'(off);
		state = 1;
	endtask

	// After a W, or in a gap with nothing left to count: the next directed
	// item, if it is a load whose gap has run out.
	task automatic directed_next();
		if (dq.size() != 0 && dq[0].kind == K_LOAD && pre_run) begin
			if (dq[0].gap > 0) begin
				gap = dq[0].gap - 1;
				dq[0].gap = 0;
				d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
				state = 0;
			end else begin
				di_t it;
				it = dq.pop_front();
				start_load(it.off, it.sz, it.len);
			end
		end else begin
			d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
			state = 0;
		end
	endtask

	always @(posedge clk) begin
		cyc++;
		// The M10K rule, from the RAM instances' ports.
		if (w_asset && !w_wait && (col_d || col_t)) rdw_bad++;
		col_d = dut.data.wren_b_i && dut.data.addr_b_i == dut.data.addr_a_i;
		col_t = dut.tags.wren_b_i && dut.tags.addr_b_i == dut.tags.addr_a_i;
		// A read in flight when the hold came is discarded: in the first held
		// clock its halfword may still be written, but only into a line whose
		// tag is invalid (as its fill left it); after that, nothing.
		if (!run && dut.data.wren_b_i) begin
			if (run_q && !dut.tags.mem_q[dut.f_idx][13]) held_wr1++;
			else held_wr++;
		end
		// No PSRAM read starts while held.
		if (!run && rd_ack) begin
			if (rd_held < 5) $display("PSRAM read started while held (%0s held clock)", string'(run_q ? "the first" : "a later"));
			rd_held++;
		end
		run_q = run;

		if (st_miss) begin
			c_miss++;
			cur_miss++;
			pf_running = 0;
			if (w_size == 2'd2) c_wmiss++;
			if (preempted.exists(w_addr[22:4])) begin
				c_remiss++;
				preempted.delete(w_addr[22:4]);
			end
		end
		if (st_preempt) begin
			preempted[{dut.f_tag, dut.f_idx}] = 1;
			c_pre++;
			cur_pre++;
		end
		if (st_pf) begin
			c_pf++;
			pf_running = 1;
		end
		if (dut.fill_end || !run) pf_running = 0;
		if (st_late) begin
			c_late++;
			cur_late++;
		end
		if (st_stall) c_stall++;

		// The hold: now and then in the random phase, wherever the cache is.
		if (hold_left > 0) begin
			hold_left--;
			if (hold_left == 0) pre_run <= 1;
		end else if (!directed && run && rnd(20000) == 0) begin
			hold_left = 1 + rnd(100);
			pre_run <= 0;
			c_hold++;
			if (dut.f_act) c_hold_fill++;
		end

		if (!run) begin
			state = 0;
			gap = 0;
			w_asset <= 0;
			d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
		end else case (state)
			0: begin                               // other instructions
				w_asset <= 0;
				if (gap > 0) begin
					gap--;
					d_addr <= rnd(2) ? 32'h4000_0000 | 32'(rnd(1 << 14)) : 32'h0200_0000 | 32'(rnd(size));
				end else if (directed) begin
					d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
					// Nothing new while a hold is on its way (the CPU would be reset).
					if (dq.size() != 0 && pre_run)
						case (dq[0].kind)
							K_LOAD: directed_next();
							K_HOLD:
								if (dut.f_act && dut.f_fl && hold_left == 0) begin
									hold_left = dq[0].len;
									pre_run <= 0;
									c_hold++;
									c_hold_fill++;
									void'(dq.pop_front());
								end
							K_IDLE: if (cache_idle()) void'(dq.pop_front());
							K_HOLDNOW:
								if (hold_left == 0) begin
									hold_left = dq[0].len;
									pre_run <= 0;
									c_hold++;
									void'(dq.pop_front());
								end
							K_PFRUN:
								if (pf_running && dut.f_act && dut.f_fl && dut.f_rx_n >= 4'd4 && dut.f_rx_n <= 4'd6)
									void'(dq.pop_front());
							default: void'(dq.pop_front());
						endcase
				end else begin
					if (queue.size() == 0) refill();
					cur = queue.pop_front();
					d_addr <= 32'h0200_0000 | 32'(cur.off);
					cur_hold_w = 0;
					state = 1;
				end
			end
			1: begin                               // execute ends: W next
				w_asset <= 1;
				w_addr <= 32'h0200_0000 | 32'(cur.off);
				w_size <= cur.sz;
				d_addr <= 32'h0200_0000 | 32'(cur.off);
				wait_clk = 0;
				cur_miss = 0;
				cur_late = 0;
				cur_pre = 0;
				state = 2;
			end
			2: begin                               // W
				if (w_wait) begin
					wait_clk++;
					if (wait_clk == 200) begin
						stuck++;
						$display("load at %0d waits 200 clocks", cur.off);
					end
					if (cur_hold_w > 0 && dut.f_fl && hold_left == 0) begin
						// The hold comes while W waits: the CPU is reset and the load dropped.
						hold_left = cur_hold_w;
						pre_run <= 0;
						c_hold++;
						c_hold_fill++;
						if (directed) res.push_back('{cur.off, cur.sz, int'(wait_clk), cur_miss, cur_late, cur_pre, 1'b1, 1'b1});
						state = 3;
					end
				end else begin
					int a;
					bit ok;
					logic [31:0] e;
					logic  [3:0] m;
					a = cur.off & ~3;
					for (int k = 0; k < 4; k++) e[8 * k +: 8] = pat(a + k);
					m = cur.sz == 2'd2 ? 4'b1111 : cur.off[1] ? 4'b1100 : 4'b0011;
					ok = 1;
					for (int k = 0; k < 4; k++)
						if (m[k] && asset_q[8 * k +: 8] !== e[8 * k +: 8]) ok = 0;
					if (!ok) begin
						if (bad < 10) $display("load %0d at %0d size %0d: %08x, expected %08x (lanes %b)",
							done_loads, cur.off, cur.sz, asset_q, e, m);
						bad++;
					end
					if (wait_clk > max_wait) max_wait = wait_clk;
					done_loads++;
					recent[nrecent++ % 8] = cur.off;
					if (directed) res.push_back('{cur.off, cur.sz, int'(wait_clk), cur_miss, cur_late, cur_pre, ok, 1'b0});
					w_asset <= 0;
					if (directed)
						directed_next();
					else begin
						// the next instruction's execute clock
						gap = rnd(10) < 4 ? 0 : rnd(10) < 8 ? rnd(4) : rnd(41);
						if (gap == 0) begin
							if (queue.size() == 0) refill();
							cur = queue.pop_front();
							d_addr <= 32'h0200_0000 | 32'(cur.off);
							state = 1;
						end else begin
							gap--;
							d_addr <= 32'h4000_0000 | 32'(rnd(1 << 14));
							state = 0;
						end
					end
				end
			end
			default: ;                             // 3: dropped, until the hold resets it
		endcase
	end

	// ---- the directed scenarios -----------------------------------------------------------------
	int dir_checks = 0, dir_fail = 0;

	function automatic int line(input int tag, input int idx);
		return tag * 1024 + idx * 16;
	endfunction

	task automatic dload(input int off, input logic [1:0] sz, input int gap = 0, input int hold_w = 0);
		dq.push_back('{K_LOAD, off, sz, gap, hold_w});
	endtask
	task automatic ditem(input int kind, input int len = 0);
		dq.push_back('{kind, 0, 2'd0, 0, len});
	endtask

	// Run what is queued, then wait for the cache to go idle.
	task automatic drain();
		longint c0;
		ditem(K_IDLE);
		c0 = cyc;
		while ((dq.size() != 0 || state != 0 || gap != 0 || hold_left != 0 || !run) && stuck == 0) begin
			@(posedge clk);
			if (cyc - c0 > 5000) begin
				$display("  directed: the queue did not drain in 5,000 clocks (state %0d, %0d items, fill %0d)",
					state, dq.size(), dut.f_act);
				stuck++;
			end
		end
		repeat (2) @(posedge clk);
	endtask

	// Wait (at most 5,000 clocks; then stuck) for run low (what 0, v 0), psram.sv
	// idle (what 1), or run high (what 0, v 1).
	task automatic wait_for(input int what, input bit v);
		longint c0;
		c0 = cyc;
		while ((what == 0 ? run != v : p_busy) && stuck == 0) begin
			@(posedge clk);
			if (cyc - c0 > 5000) begin
				$display("  directed: waited 5,000 clocks for %s", what == 0 ? (v ? "the release" : "the hold") : "psram.sv");
				stuck++;
			end
		end
	endtask

	// Word loads of a whole line, after the cache has gone idle: every byte
	// a scenario's fills left there must be right.
	task automatic whole(input int ln);
		for (int k = 0; k < 16; k += 4) dload(ln + k, 2'd2, 2);
		drain();
	endtask

	// Put another tag's bytes in a line's index: word loads of tag + 1.
	task automatic stale(input int tag, input int idx);
		for (int k = 0; k < 16; k += 4) dload(line(tag + 1, idx) + k, 2'd2, k == 0 ? 2 : 0);
		drain();
	endtask

	task automatic expect_(input bit c, input string what);
		dir_checks++;
		if (!c) begin
			dir_fail++;
			$display("  DIRECTED FAIL: %s", what);
		end
	endtask

	function automatic string rs(input int i);
		return $sformatf("[%0d] off %0d size %0d: waited %0d, miss %0d, late %0d, pre-empt %0d, %s%s", i, res[i].off,
			res[i].sz, res[i].waitc, res[i].miss, res[i].late, res[i].pre, res[i].ok ? "data right" : "DATA WRONG",
			res[i].dropped ? ", dropped by the hold" : "");
	endfunction

	task automatic show(input string name, input int r0);
		$display("%s", name);
		for (int i = r0; i < res.size(); i++) $display("  %s", rs(i));
		for (int i = r0; i < res.size(); i++) if (!res[i].dropped) expect_(res[i].ok, {"data of ", rs(i)});
	endtask

	task automatic directed_tests();
		int r, b;
		bit pre;
		pre = `PREEMPT;

		// A1: the boot's sequence on a cold line.
		stale(8, 10);
		r = res.size();
		b = line(8, 10);
		dload(b + 0, 2'd0, 3); dload(b + 1, 2'd0, 4); dload(b + 2, 2'd0, 1); dload(b + 3, 2'd0, 2);
		dload(b + 4, 2'd2, 2); dload(b + 8, 2'd2, 0);
		drain();
		show("A1 boot sequence (fw 0xac-0xfc) on a cold line", r);
		expect_(res[r].miss == 1 && res[r].waitc == 8, "A1: the first byte misses and waits 8 clocks");
		for (int i = r + 1; i < r + 6; i++) expect_(res[i].miss == 0, "A1: no other load starts a fill");
		r = res.size();
		whole(b);
		show("A1 the whole line afterwards", r);

		// A2: the same, back to back.
		stale(10, 12);
		r = res.size();
		b = line(10, 12);
		dload(b + 0, 2'd0, 3);
		for (int k = 1; k < 4; k++) dload(b + k, 2'd0, 0);
		dload(b + 4, 2'd2, 0); dload(b + 8, 2'd2, 0);
		drain();
		show("A2 the same back to back", r);
		expect_(res[r].miss == 1 && res[r].waitc == 8, "A2: the first byte misses and waits 8 clocks");
		for (int i = r + 1; i < r + 6; i++) expect_(res[i].miss == 0, "A2: no other load starts a fill");
		expect_(res[r + 2].waitc >= 1, "A2: byte 2 waits for halfword 1 (read registered on its write's edge)");
		expect_(res[r + 4].late == 1 && res[r + 5].late == 1, "A2: both word loads are late hits");
		r = res.size();
		whole(b);
		show("A2 the whole line afterwards", r);

		// B: word, unaligned word and odd halfword misses on an idle cache.
		stale(12, 21);
		r = res.size();
		dload(line(12, 21) + 4, 2'd2, 2);
		drain();
		show("B1 word-load (LDR) miss", r);
		expect_(res[r].miss == 1 && res[r].waitc == 13, "B1: LDR miss waits 13 clocks");
		stale(14, 22);
		r = res.size();
		dload(line(14, 22) + 14, 2'd2, 2);
		drain();
		show("B2 unaligned LDR miss (+14: the word at +12, halfwords 6 and 7)", r);
		expect_(res[r].miss == 1 && res[r].waitc == 13, "B2: unaligned LDR miss waits 13 clocks");
		stale(16, 23);
		r = res.size();
		dload(line(16, 23) + 7, 2'd1, 2);
		drain();
		show("B3 odd LDRH miss (+7: halfword 3)", r);
		expect_(res[r].miss == 1 && res[r].waitc == 8, "B3: odd LDRH miss waits 8 clocks");

		// C: a hit on the line under fill.
		stale(18, 24);
		r = res.size();
		b = line(18, 24);
		dload(b + 0, 2'd0, 2); dload(b + 14, 2'd0, 0); dload(b + 6, 2'd1, 0);
		drain();
		show("C hit on the line under fill", r);
		expect_(res[r].miss == 1, "C: the first load misses");
		expect_(res[r + 1].miss == 0 && res[r + 1].late == 1 && res[r + 1].waitc > 0,
			"C: the byte in the last halfword is a late hit, waits, and starts no fill");
		expect_(res[r + 2].miss == 0, "C: the third load starts no fill");

		if (`PREFETCH) begin
		// D1: a demand miss while the prefetch of the next line runs.
		stale(20, 30);
		stale(21, 40);
		r = res.size();
		dload(line(20, 30), 2'd0, 2);
		ditem(K_PFRUN);
		dload(line(21, 40), 2'd0, 0);
		ditem(K_IDLE);
		dload(line(20, 31) + 14, 2'd0, 2);
		drain();
		show("D1 demand miss during the next-line prefetch", r);
		expect_(res[r + 1].miss == 1 && res[r + 1].pre == pre, "D1: the demand miss pre-empts the prefetch iff PREEMPT");
		expect_(pre ? res[r + 1].waitc <= 14 : res[r + 1].waitc > 14,
			"D1: with PREEMPT it waits at most the read in flight, the read issued with its arrival and 8 clocks; without, for the prefetch");
		expect_(res[r + 2].miss == pre, "D1: the pre-empted line misses again (a completed prefetch hits)");
		r = res.size();
		whole(line(21, 40));
		whole(line(20, 31));
		show("D1 the demand line and the prefetched line afterwards", r);
		end

		// D2: a demand miss while the previous demand fill runs.
		stale(26, 60);
		stale(27, 33);
		r = res.size();
		dload(line(26, 60), 2'd0, 2);
		dload(line(27, 33), 2'd0, 0);
		ditem(K_IDLE);
		dload(line(26, 60) + 14, 2'd0, 2);
		drain();
		show("D2 demand miss during a demand fill", r);
		expect_(res[r + 1].miss == 1 && res[r + 1].pre == pre, "D2: the demand miss pre-empts the fill iff PREEMPT");
		expect_(res[r + 2].miss == pre, "D2: the pre-empted line misses again (a completed fill hits)");
		r = res.size();
		whole(line(27, 33));
		whole(line(26, 60));
		show("D2 both lines afterwards", r);

		// E1: a hold while the fill has a read in flight, its load done.
		stale(22, 45);
		r = res.size();
		dload(line(22, 45), 2'd0, 2);
		ditem(K_HOLD, 30);
		dload(line(22, 45) + 14, 2'd0, 0);
		drain();
		show("E1 hold during a fill, after its load completed", r);
		expect_(res[r + 1].miss == 1, "E1: the line misses again after the hold");
		r = res.size();
		whole(line(22, 45));
		show("E1 the whole line afterwards", r);

		// E2: a hold while W waits on the miss.
		stale(23, 50);
		r = res.size();
		dload(line(23, 50), 2'd2, 2, 40);
		dload(line(23, 50), 2'd2, 0);
		drain();
		show("E2 hold while W waits on a miss", r);
		expect_(res[r].dropped, "E2: the load waiting in W is dropped by the hold");
		expect_(res[r + 1].miss == 1 && res[r + 1].waitc == 13, "E2: after the release it misses again and waits 13 clocks");
		r = res.size();
		whole(line(23, 50));
		show("E2 the whole line afterwards", r);

		if (`PREFETCH) begin
		// E3: a hold while a prefetch has a read in flight.
		stale(24, 55);
		r = res.size();
		dload(line(24, 55), 2'd0, 2);
		ditem(K_PFRUN);
		ditem(K_HOLD, 20);
		dload(line(24, 56) + 14, 2'd0, 0);
		drain();
		show("E3 hold during a prefetch", r);
		expect_(res[r + 1].miss == 1, "E3: the prefetched line misses after the hold");
		r = res.size();
		whole(line(24, 56));
		show("E3 the whole line afterwards", r);

		// F: a tag write on the edge a load's tag read is registered. Line
		// (29, 35) and line (28, 36) are valid. A hit on (29, 35) probes
		// (29, 36) two clocks later and starts its prefetch, writing index
		// 36's tag invalid on the edge that registers the tag read of a load
		// of (28, 36) one instruction after the hit. That read is a mixed-port
		// read-during-write: the load must not complete on it.
		dload(line(29, 35), 2'd2, 2);
		drain();
		dload(line(28, 36), 2'd2, 2);
		drain();
		r = res.size();
		dload(line(29, 35) + 1, 2'd0, 2);
		dload(line(28, 36) + 2, 2'd0, 1);
		drain();
		show("F a tag write on the edge the next load's tag read is registered", r);
		expect_(res[r].miss == 0 && res[r].waitc == 0, "F: the first load hits");
		expect_(res[r + 1].waitc >= 1, "F: the load whose tag read collided waits");
		expect_(rdw_bad == 0, "F: no load completed on a collided read");
		r = res.size();
		whole(line(28, 36));
		show("F the line afterwards", r);
		end
		// G: the tag sweep, with the PSRAM's contents changed behind every
		// valid line during the hold.
		begin
			int nv, wrong;
			// Each fill completes before the next load (no pre-emption), from
			// line 63 down, so the next-line prefetches find their lines valid
			// and the last one (line 63's, index 0) is replaced by line 0.
			for (int i = 63; i >= 0; i--) begin
				dload(line(40, i), 2'd2, 2);
				drain();
			end
			nv = 0;
			for (int i = 0; i < 64; i++) if (dut.tags.mem_q[i] == {1'b1, 13'd40}) nv++;
			$display("G tag sweep: %0d of 64 lines valid before the hold", nv);
			expect_(nv == 64, "G: every line valid before the hold");
			ditem(K_HOLDNOW, 100);
			wait_for(0, 0);                     // the hold
			wait_for(1, 0);                     // psram.sv idle
			epoch = 1;
			load_pattern();
			wait_for(0, 1);                     // running again
			nv = 0;
			for (int i = 0; i < 64; i++) if (dut.tags.mem_q[i][13]) nv++;
			$display("  %0d tags valid when the cache runs again", nv);
			expect_(nv == 0, "G: no tag valid after the sweep");
			r = res.size();
			for (int i = 0; i < 64; i++) for (int k = 0; k < 16; k += 4) dload(line(40, i) + k, 2'd2, k == 0 ? 2 : 0);
			drain();
			wrong = 0;
			for (int i = r; i < res.size(); i++) if (!res[i].ok) begin
				if (wrong < 5) $display("  %s", rs(i));
				wrong++;
			end
			$display("  %0d word loads of the 64 lines afterwards, %0d with old or wrong bytes", res.size() - r, wrong);
			expect_(wrong == 0 && res.size() - r == 256, "G: every line returns the new contents");
		end
		expect_(held_wr == 0, "no data M10K write while held, but a discarded read's into an invalid line");
		expect_(rd_held == 0, "no PSRAM read started while held");
		expect_(stuck == 0, "no load or drain stuck");
		$display("directed: %0d of %0d checks pass", dir_checks - dir_fail, dir_checks);
	endtask

	int seed = 1;
	initial begin
		void'($value$plusargs("loads=%d", n_loads));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("size=%d", size));
		void'($urandom(seed));
		load_pattern();
		for (int v = 0; v < 16; v++) begin
			vptr[v] = rnd(size);
			vstep[v] = 1 + rnd(3);
		end
		for (int k = 0; k < 8; k++) recent[k] = rnd(size);
		repeat (10) @(posedge clk);
		pre_run <= 1;
		directed_tests();
		directed = 0;
		while (done_loads < n_loads && stuck == 0) @(posedge clk);
		$display("cache, pre-emption %0d, prefetch %0d, %0d bytes: %0d loads in %0d clocks, %0d wrong; %0d stall clocks, longest wait %0d",
			`PREEMPT, `PREFETCH, size, done_loads, cyc, bad, c_stall, max_wait);
		$display("  %0d demand misses (%0d word loads), %0d prefetches, %0d pre-emptions, %0d misses on a pre-empted line, %0d late hits, %0d holds (%0d during a fill), %0d completed reads that collided with a write",
			c_miss, c_wmiss, c_pf, c_pre, c_remiss, c_late, c_hold, c_hold_fill, rdw_bad);
`ifndef PSRAM_STANDIN
		chip.report();
`endif
		$display("  %0d halfwords of a read in flight at a hold written in the first held clock, into an invalid line; %0d other writes while held; %0d PSRAM reads started while held",
			held_wr1, held_wr, rd_held);
		$display("result: loads=%0d bad=%0d rdw=%0d stuck=%0d heldwr=%0d rdheld=%0d dirfail=%0d dir=%0d miss=%0d wmiss=%0d pf=%0d pre=%0d remiss=%0d late=%0d holds=%0d holdfill=%0d",
			done_loads, bad, rdw_bad, stuck, held_wr, rd_held, dir_fail, dir_checks, c_miss, c_wmiss, c_pf, c_pre, c_remiss, c_late,
			c_hold, c_hold_fill);
		$finish;
	end
endmodule
