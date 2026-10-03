//------------------------------------------------------------------------------
// Random and directed load streams on the asset cache
// (src/fpga/core/bupchip/bup_asset_cache.sv), behind bup_asset_wr's PSRAM
// arbitration and psram.sv on psram_model.sv (or, with -DPSRAM_STANDIN,
// psram_standin.sv), at 28.636 MHz. Step 4 of docs/BUPCHIP_CORE.md.
//
// The driver behaves as bup_cpu S1 does at the asset port: an execute clock
// with the load's address on d_addr, then W (w_asset, w_addr, w_size) with
// d_addr held on the access for as long as w_wait is high, then the next
// instruction's execute clock. Between loads it runs 0-40 clocks of other
// instructions, with unrelated addresses on d_addr. Now and then the hold
// rises for 1-100 clocks (pre_run low), wherever the cache is, which also
// drops a fill in flight; the sweep then runs again.
//
// The PSRAM holds +size bytes (default 64 KiB) of a known pattern, and one
// line more for the prefetch past the end, loaded through the model's
// backdoor. The loads, by weight:
//   voices    16 streams of byte loads (LDRSB), each with its own step,
//             as CoreTone's mixer reads samples (prefetch's case)
//   cold      the boot's pattern (fw 0xac-0xec): byte loads of bytes 0-3 of
//             a cold line, back to back, then word loads of it
//   conflict  a line at the same index as a recent one, other tag
//   random    byte, halfword (odd ones too) and word (unaligned too) loads
//             anywhere
// For every completed load each byte it touches must equal the pattern: the
// byte, the aligned halfword, or the aligned word. Also: no load completes
// on an M10K read registered on the same edge as a port-B write to the same
// address (checked from the RAM instances' ports), no load waits more than
// 200 clocks, and the counters below reach a minimum so each case is known
// to have happened: demand misses, word-load misses, late hits (a load on
// the line under fill), prefetches, pre-emptions (PREEMPT), a demand miss on
// a line whose fill was pre-empted, holds during a fill.
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
	function automatic logic [7:0] pat(input int b);
		logic [31:0] x;
		x = b * 32'h9E3779B1;
		return x[23:16] ^ x[7:0] ^ 8'(b >> 8);
	endfunction

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
	longint c_remiss = 0, rdw_bad = 0, stuck = 0;
	int     state = 0;                              // 0 gap, 1 execute, 2 W
	int     gap = 0, hold_left = 0;
	ld_t    cur;
	logic   col_d = 0, col_t = 0;
	bit     preempted[int];                         // lines whose fill was pre-empted

	always @(posedge clk) begin
		cyc++;
		// The M10K rule, from the RAM instances' ports.
		if (w_asset && !w_wait && (col_d || col_t)) rdw_bad++;
		col_d = dut.data.wren_b_i && dut.data.addr_b_i == dut.data.addr_a_i;
		col_t = dut.tags.wren_b_i && dut.tags.addr_b_i == dut.tags.addr_a_i;

		if (st_miss) begin
			c_miss++;
			if (w_size == 2'd2) c_wmiss++;
			if (preempted.exists(w_addr[22:4])) begin
				c_remiss++;
				preempted.delete(w_addr[22:4]);
			end
		end
		if (st_preempt) preempted[{dut.f_tag, dut.f_idx}] = 1;
		if (st_pf) c_pf++;
		if (st_preempt) c_pre++;
		if (st_late) c_late++;
		if (st_stall) c_stall++;

		// The hold: now and then, wherever the cache is.
		if (hold_left > 0) begin
			hold_left--;
			if (hold_left == 0) pre_run <= 1;
		end else if (run && rnd(20000) == 0) begin
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
				end else begin
					if (queue.size() == 0) refill();
					cur = queue.pop_front();
					d_addr <= 32'h0200_0000 | 32'(cur.off);
					state = 1;
				end
			end
			1: begin                               // execute ends: W next
				w_asset <= 1;
				w_addr <= 32'h0200_0000 | 32'(cur.off);
				w_size <= cur.sz;
				d_addr <= 32'h0200_0000 | 32'(cur.off);
				wait_clk = 0;
				state = 2;
			end
			2: begin                               // W
				if (w_wait) begin
					wait_clk++;
					if (wait_clk == 200) begin
						stuck++;
						$display("load at %0d waits 200 clocks", cur.off);
					end
				end else begin
					int a;
					logic [31:0] e;
					logic  [3:0] m;
					a = cur.off & ~3;
					for (int k = 0; k < 4; k++) e[8 * k +: 8] = pat(a + k);
					m = cur.sz == 2'd2 ? 4'b1111 : cur.off[1] ? 4'b1100 : 4'b0011;
					for (int k = 0; k < 4; k++)
						if (m[k] && asset_q[8 * k +: 8] !== e[8 * k +: 8]) begin
							if (bad < 10) $display("load %0d at %0d size %0d: %08x, expected %08x (lanes %b)",
								done_loads, cur.off, cur.sz, asset_q, e, m);
							bad++;
							break;
						end
					if (wait_clk > max_wait) max_wait = wait_clk;
					done_loads++;
					recent[nrecent++ % 8] = cur.off;
					// the next instruction's execute clock
					gap = rnd(10) < 4 ? 0 : rnd(10) < 8 ? rnd(4) : rnd(41);
					w_asset <= 0;
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
		endcase
	end

	int seed = 1;
	initial begin
		void'($value$plusargs("loads=%d", n_loads));
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("size=%d", size));
		void'($urandom(seed));
		// one line more: a prefetch may read the line after the last
		for (int h = 0; h < size / 2 + 8; h++) preload(h, {pat(2 * h + 1), pat(2 * h)});
		for (int v = 0; v < 16; v++) begin
			vptr[v] = rnd(size);
			vstep[v] = 1 + rnd(3);
		end
		for (int k = 0; k < 8; k++) recent[k] = rnd(size);
		repeat (10) @(posedge clk);
		pre_run <= 1;
		while (done_loads < n_loads && stuck == 0) @(posedge clk);
		$display("cache, pre-emption %0d, prefetch %0d, %0d bytes: %0d loads in %0d clocks, %0d wrong; %0d stall clocks, longest wait %0d",
			`PREEMPT, `PREFETCH, size, done_loads, cyc, bad, c_stall, max_wait);
		$display("  %0d demand misses (%0d word loads), %0d prefetches, %0d pre-emptions, %0d misses on a pre-empted line, %0d late hits, %0d holds (%0d during a fill), %0d completed reads that collided with a write",
			c_miss, c_wmiss, c_pf, c_pre, c_remiss, c_late, c_hold, c_hold_fill, rdw_bad);
`ifndef PSRAM_STANDIN
		chip.report();
`endif
		$display("result: loads=%0d bad=%0d rdw=%0d stuck=%0d miss=%0d wmiss=%0d pf=%0d pre=%0d remiss=%0d late=%0d holds=%0d holdfill=%0d",
			done_loads, bad, rdw_bad, stuck, c_miss, c_wmiss, c_pf, c_pre, c_remiss, c_late, c_hold, c_hold_fill);
		$finish;
	end
endmodule
