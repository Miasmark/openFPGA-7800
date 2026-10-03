//------------------------------------------------------------------------------
// agg23's psram.sv (src/fpga/pocket_utils/, vendored unmodified) driving the
// PSRAM model (psram_model.sv) with random reads and writes on both dies:
// CLOCK_SPEED = 28.636364 on a clock of CLK_MHZ (docs/BUPCHIP_CORE.md,
// "Controller", and the verification plan's PSRAM row). Runs in iverilog
// and Verilator; run_psram_ctl.sh drives it.
//
//   tb_psram_ctl.CLOCK_SPEED  psram.sv's parameter, MHz (28.636364)
//   tb_psram_ctl.CLK_MHZ      the clock it runs on
//   tb_psram_ctl.OPS          accesses (default 20,000)
//   tb_psram_ctl.SEED         the request stream (and the model's jitter)
//   tb_psram_ctl.EXTRA_NS, JITTER_NS   the model's stress knob
//
// The client is a synchronous state machine as the wrapper's would be. It
// raises read_en or write_en and holds it until an edge where busy was low
// (that edge accepts it), then drops it or raises the next request at once;
// 40% of requests follow the previous one back to back, the rest after 1-7
// idle clocks (so some are raised while busy, some while idle). Addresses:
// 64 per die (corners included) for read-after-write checks, plus reads of
// random unwritten addresses; byte enables both, high, low or none.
//
// For an access accepted at edge e it checks, at every edge e+1..e+5:
// busy high before e+1..e+4 and low before e+5; read_avail low except
// before e+5 for a read; data_out before e+5 equal to the testbench's own
// shadow of what was written (unwritten bytes as the model returns them:
// X in iverilog); after a write, the model's contents (backdoor) equal the
// shadow. At the end every pool word must equal the shadow, and the model
// must hold no written halfword outside the pool. Also: the controller and
// the die never drive DQ at once (data_out_en against the model's
// out_act), the model's timing checks raise nothing, and psram.sv's state
// numbers are distinct.
//
// The last line, "result: ...", is for run_psram_ctl.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_psram_ctl;
	parameter real CLOCK_SPEED = 28.636364;
	parameter real CLK_MHZ = 28.636364;
	parameter int  OPS = 20000;
	parameter int  SEED = 1;
	parameter real EXTRA_NS = 0.0;
	parameter real JITTER_NS = 0.0;

	localparam real HALF_PS = 500000.0 / CLK_MHZ;
	localparam int POOL = 64;

	reg clk = 0;
	always #(HALF_PS) clk = ~clk;

	// psram.sv's client port
	reg        bank_sel = 0, write_en = 0, read_en = 0, wr_hi = 0, wr_lo = 0;
	reg [21:0] addr = 0;
	reg [15:0] data_in = 0;
	wire       read_avail, busy;
	wire [15:0] data_out;

	// The chip's pins
	wire [21:16] cram_a;
	wire [15:0] cram_dq;
	wire cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	psram #(.CLOCK_SPEED(CLOCK_SPEED)) p (
		.clk(clk), .bank_sel(bank_sel), .addr(addr),
		.write_en(write_en), .data_in(data_in), .write_high_byte(wr_hi), .write_low_byte(wr_lo),
		.read_en(read_en), .read_avail(read_avail), .data_out(data_out), .busy(busy),
		.cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(cram_wait), .cram_clk(cram_clk),
		.cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
		.cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n));

	psram_model #(.EXTRA_NS(EXTRA_NS), .JITTER_NS(JITTER_NS), .SEED(SEED)) m (
		.cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(cram_wait), .cram_clk(cram_clk),
		.cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
		.cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n));

	// The controller and the die must never drive DQ together
	int unsigned bus_errors = 0;
	always @(p.data_out_en or m.out_act)
		if (p.data_out_en === 1'b1 && m.out_act) begin
			bus_errors++;
			if (bus_errors <= 10) $display("ERROR at %0t ps: psram.sv and the die both drive DQ", $time);
		end

	// xorshift32: the same stream in every simulator
	bit [31:0] rs = (SEED == 0) ? 32'd7 : SEED * 32'd2654435761;
	function automatic int unsigned rnd(input int unsigned n);
		rs = rs ^ (rs << 13);
		rs = rs ^ (rs >> 17);
		rs = rs ^ (rs << 5);
		return rs % n;
	endfunction

	// Address pool and the testbench's shadow of it: index {die, k}
	logic [21:0] pool [0:2*POOL-1];
	logic [15:0] sh [0:2*POOL-1];
	bit  [1:0] sh_w [0:2*POOL-1];

	function automatic int pool_find(input int die, input logic [21:0] a);
		for (int k = 0; k < POOL; k++) if (pool[die * POOL + k] == a) return die * POOL + k;
		return -1;
	endfunction

	initial begin
		logic [21:0] corners [0:9];
		logic [21:0] a;
		corners[0] = 22'h000000; corners[1] = 22'h000001; corners[2] = 22'h3FFFFF; corners[3] = 22'h3FFFFE;
		corners[4] = 22'h00FFFF; corners[5] = 22'h010000; corners[6] = 22'h01FFFF; corners[7] = 22'h020000;
		corners[8] = 22'h2AAAAA; corners[9] = 22'h155555;
		for (int d = 0; d < 2; d++)
			for (int k = 0; k < POOL; k++) begin
				pool[d * POOL + k] = 22'h3FFFFF;	// placeholder, replaced below
				sh_w[d * POOL + k] = 0;
				sh[d * POOL + k] = 0;
			end
		for (int d = 0; d < 2; d++)
			for (int k = 0; k < POOL; k++) begin
				if (k < 10) a = corners[k];
				else if (k < 20) a = pool[d * POOL + k - 10] ^ 22'h000001 ^ (22'h100 << (k - 10));
				else a = rnd(1 << 22);
				while (k >= 10 && pool_find(d, a) >= 0 && pool_find(d, a) < d * POOL + k) a = rnd(1 << 22);
				pool[d * POOL + k] = a;
			end
		gap = 3;	// psram.sv's busy is X until its first clock edge
	end

	// The request presented, and the access in flight
	typedef struct packed {
		bit        wr;
		bit        die;
		bit [21:0] addr;
		bit [15:0] data;
		bit  [1:0] be;
		int        idx;		// pool index, or -1
	} op_t;
	op_t cur, fl;
	bit req = 0, inflight = 0;
	int unsigned gap = 0;
	longint cyc = 0, e = 0, last_acc = -1, req_since = 0;
	logic [15:0] exp_q;

	// Results
	int unsigned accepted = 0, n_rd = 0, n_wr = 0, n_unwr = 0, data_errors = 0, timing_errors = 0;
	int unsigned b2b = 0, done_min = 999, done_max = 0, rlat_min = 999, rlat_max = 0, cpa_min = 999, cpa_max = 0;
	int unsigned gap_min = 999;
	longint t_first = -1, t_last = 0;

	function automatic op_t new_op();
		op_t o;
		int unsigned r;
		o.die = rnd(2);
		r = rnd(100);
		if (r < 90) begin
			o.idx = o.die * POOL + rnd(POOL);
			o.addr = pool[o.idx];
			o.wr = r < 45;
		end else begin
			o.wr = 0;
			o.addr = rnd(1 << 22);
			while (pool_find(o.die, o.addr) >= 0) o.addr = rnd(1 << 22);
			o.idx = -1;
		end
		o.data = rnd(1 << 16);
		r = rnd(100);
		o.be = r < 70 ? 2'b11 : r < 84 ? 2'b10 : r < 98 ? 2'b01 : 2'b00;
		return o;
	endfunction

	task automatic present(input op_t o);
		cur = o;
		req = 1;
		req_since = cyc;
		bank_sel <= o.die;
		addr <= o.addr;
		data_in <= o.data;
		wr_hi <= o.be[1];
		wr_lo <= o.be[0];
		write_en <= o.wr;
		read_en <= !o.wr;
	endtask

	function automatic void terr(input string s);
		timing_errors++;
		if (timing_errors <= 10) $display("ERROR at %0t ps, edge %0d: %s", $time, cyc, s);
	endfunction

	function automatic void derr(input string s);
		data_errors++;
		if (data_errors <= 10) $display("ERROR at %0t ps, edge %0d: %s", $time, cyc, s);
	endfunction

	// The expected read data: the shadow's written bytes, the model's
	// unwritten value for the others
	function automatic logic [15:0] expect_rd(input op_t o);
		logic [15:0] v;
		v = m.bd_read(o.die, o.addr);
		if (o.idx >= 0) begin
			if (sh_w[o.idx][1]) v[15:8] = sh[o.idx][15:8];
			if (sh_w[o.idx][0]) v[7:0] = sh[o.idx][7:0];
		end
		return v;
	endfunction

	always @(posedge clk) begin
		longint k;
		cyc++;
		// 1. Outputs as the previous edge left them
		if (inflight) begin
			k = cyc - e;
			if (k <= 4) begin
				if (busy !== 1'b1) terr($sformatf("busy = %b %0d clocks after the accept", busy, k));
				if (read_avail !== 1'b0) terr($sformatf("read_avail = %b %0d clocks after the accept", read_avail, k));
				if (busy === 1'b0 && k < done_min) done_min = k;
			end else begin
				if (busy !== 1'b0) terr($sformatf("busy still %b 5 clocks after the accept", busy));
				else begin
					if (k < done_min) done_min = k;
					if (k > done_max) done_max = k;
				end
				if (fl.wr) begin
					logic [15:0] got;
					bit bad;
					if (read_avail !== 1'b0) terr("read_avail after a write");
					got = m.bd_read(fl.die, fl.addr);
					bad = m.bd_written(fl.die, fl.addr) !== sh_w[fl.idx];
					if (sh_w[fl.idx][1] && got[15:8] !== sh[fl.idx][15:8]) bad = 1;
					if (sh_w[fl.idx][0] && got[7:0] !== sh[fl.idx][7:0]) bad = 1;
					if (bad)
						derr($sformatf("die %0d word %h holds %h (written %b), expected %h (written %b)",
							fl.die, fl.addr, got, m.bd_written(fl.die, fl.addr), sh[fl.idx], sh_w[fl.idx]));
				end else begin
					if (read_avail !== 1'b1) terr($sformatf("read_avail = %b 5 clocks after a read's accept", read_avail));
					else begin
						if (k < rlat_min) rlat_min = k;
						if (k > rlat_max) rlat_max = k;
					end
					if (data_out !== exp_q)
						derr($sformatf("die %0d word %h read %h, expected %h", fl.die, fl.addr, data_out, exp_q));
				end
				inflight = 0;
			end
		end else if (read_avail !== 1'b0 && accepted != 0)
			terr($sformatf("read_avail = %b with nothing in flight", read_avail));

		// 2. An accept at this edge
		if (req && (read_en || write_en) && busy === 1'b0) begin
			if (inflight) terr("accepted while an access was in flight");
			fl = cur;
			e = cyc;
			inflight = 1;
			accepted++;
			if (t_first < 0) t_first = $time;
			t_last = $time;
			// The first edge with busy low after the request was raised
			k = req_since + 1;
			if (last_acc >= 0 && last_acc + 5 > k) k = last_acc + 5;
			if (cyc != k) terr($sformatf("accepted at edge %0d, expected %0d", cyc, k));
			if (last_acc >= 0) begin
				if (cyc - last_acc < gap_min) gap_min = cyc - last_acc;
				if (req_since + 1 < last_acc + 5) begin	// waiting when the controller came free
					b2b++;
					if (cyc - last_acc < cpa_min) cpa_min = cyc - last_acc;
					if (cyc - last_acc > cpa_max) cpa_max = cyc - last_acc;
				end
			end
			last_acc = cyc;
			if (fl.wr) begin
				n_wr++;
				if (fl.idx >= 0) begin
					if (fl.be[1]) begin sh[fl.idx][15:8] = fl.data[15:8]; sh_w[fl.idx][1] = 1; end
					if (fl.be[0]) begin sh[fl.idx][7:0] = fl.data[7:0]; sh_w[fl.idx][0] = 1; end
				end
			end else begin
				n_rd++;
				exp_q = expect_rd(fl);
				if (fl.idx < 0 || sh_w[fl.idx] != 2'b11) n_unwr++;
			end
			req = 0;
			read_en <= 0;
			write_en <= 0;
			if (accepted < OPS) begin
				if (rnd(100) < 40) present(new_op());
				else
					gap = 1 + rnd(7);
			end
		end else if (!req && gap != 0) begin
			gap--;
			if (gap == 0) present(new_op());
		end

		// 3. Done
		if (accepted >= OPS && !inflight && !req) finish();
		if (cyc > 64'd20 * OPS + 2000) begin
			terr("ran out of clocks");
			finish();
		end
	end

	task automatic finish();
		int distinct;
		int unsigned pw;
		logic [15:0] got;
		// Every pool word as the shadow has it, and no halfword written elsewhere
		pw = 0;
		for (int i = 0; i < 2 * POOL; i++) begin
			got = m.bd_read(i / POOL, pool[i]);
			if (sh_w[i] != 0) pw++;
			if (m.bd_written(i / POOL, pool[i]) !== sh_w[i] || (sh_w[i][1] && got[15:8] !== sh[i][15:8]) ||
					(sh_w[i][0] && got[7:0] !== sh[i][7:0]))
				derr($sformatf("at the end, die %0d word %h holds %h (written %b), expected %h (written %b)",
					i / POOL, pool[i], got, m.bd_written(i / POOL, pool[i]), sh[i], sh_w[i]));
		end
		if (m.n_written != pw) derr($sformatf("%0d halfwords written in the model, %0d in the pool", m.n_written, pw));
		distinct = p.STATE_WRITE_ADV_END < p.STATE_WRITE_ADDR_LATCH_END &&
			p.STATE_WRITE_ADDR_LATCH_END < p.STATE_WRITE_DATA_START &&
			p.STATE_WRITE_DATA_START < p.STATE_WRITE_DATA_END &&
			p.STATE_READ_ADV_END < p.STATE_READ_ADDR_LATCH_END &&
			p.STATE_READ_ADDR_LATCH_END < p.STATE_READ_DATA_ENABLE &&
			p.STATE_READ_DATA_ENABLE < p.STATE_READ_DATA_RECEIVED;
		m.report();
		$display("CLOCK_SPEED %.6f on a %.6f MHz clock (period %0d ps): write states %0d %0d %0d %0d, read states %0d %0d %0d %0d",
			CLOCK_SPEED, CLK_MHZ, 2 * $rtoi(HALF_PS + 0.5),
			p.STATE_WRITE_ADV_END, p.STATE_WRITE_ADDR_LATCH_END, p.STATE_WRITE_DATA_START, p.STATE_WRITE_DATA_END,
			p.STATE_READ_ADV_END, p.STATE_READ_ADDR_LATCH_END, p.STATE_READ_DATA_ENABLE, p.STATE_READ_DATA_RECEIVED);
		$display("  %0d accesses (%0d reads, %0d of them of unwritten bytes; %0d writes) in %0d clocks; %0d back to back",
			accepted, n_rd, n_unwr, n_wr, cyc, b2b);
		$display("result: ops=%0d reads=%0d writes=%0d data_errors=%0d timing_errors=%0d violations=%0d late_reads=%0d bus_errors=%0d distinct=%0d done=%0d..%0d read_avail=%0d..%0d back_to_back=%0d clocks_per_access=%0d..%0d min_gap=%0d",
			accepted, n_rd, n_wr, data_errors, timing_errors, m.n_viol, m.late_reads, bus_errors, distinct,
			done_min, done_max, rlat_min, rlat_max, b2b, cpa_min, cpa_max, gap_min);
		$finish;
	endtask

endmodule
