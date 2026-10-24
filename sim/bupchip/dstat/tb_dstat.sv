//------------------------------------------------------------------------------
// daria_dbg_status (src/fpga/core/bupchip/bup_status_osd.sv, BUP_DEBUG and
// POCKET_DARIA): the DARIA status overlay's counts, against the RIOT itself
// and against tb_frames' late-call rule, on random 6507 bus traffic.
//
// The DUT and upstream's RIOT (mister/rtl/RIOT/M6532.sv) see the same bus:
// the address, R/W and write byte held for a bus cycle of three clocks, with
// the RIOT's clock enable (pclk0 in the core) in the middle one, and the
// same reset. The RIOT's chip select is MARIA's 2600 decode (control.sv with
// maria_en 0): A12 = 0 and A7 = 1. Checked on every clock:
//   copy   the DUT's timer, prescaler, incr and rollover equal the RIOT's
//   late   the DUT's late calls equal this bench's count by tb_frames' rule
//          (sim/tb_frames.sv, "RIOT timer events", the same statements in
//          the same order, on the RIOT's own timer_wrap and chip select):
//          at the first timer read (INTIM or TIMINT) after a call's busy
//          falls, the timer was written at or before the call's request
//          clock, and it has wrapped since that write
//   calls  the DUT's calls equal the call_tog flips since the reset
//   guard  its unlocks equal the unlock pulses since time 0, and its lock
//          state the lock input, one clock later
// Traffic, per bus cycle while no call runs: timer reads (both registers,
// every mirror), timer writes (all four intervals, values biased small so
// that timers run out often), interrupt-control writes, RIOT port and RAM
// accesses, the timer's addresses with A12 = 1 (cartridge space, not the
// RIOT), TIA addresses and cartridge reads. A call (call_tog flips, then
// busy for 1-3,000 bus cycles, the bus parked on a cartridge address)
// starts now and then; a reset of 3-10 clocks now and then; lock and unlock
// pulses at random. Coverage counts end the run: late and on-time polls,
// timer writes on the clock the old timer wraps, INTIM reads during a
// rollover, and polls on the wrap's own clock.
//
// Plusargs: +seed=N (1), +cycles=N bus cycles (1,500,000).
// One line at the end: "result: ... errors=E" (E = 0 to pass), and the first
// few differences as ERROR lines.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_dstat;
	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic        rst = 1'b1, ce = 1'b0, rw = 1'b1, busy = 1'b0, tog = 1'b0, glk = 1'b0, gul = 1'b0;
	logic [15:0] ab = 16'h1000;
	logic  [7:0] db = 8'd0;

	// ---- upstream's RIOT, on MARIA's 2600 chip select ---------------------------------
	wire [7:0] r_dout, r_oe, pa_out, pb_out;
	wire       r_irq, r_irq_oe, r_pa_read;
	wire       cs_riot = ~ab[12] & ab[7];
	M6532 riot (
		.clk(clk), .ce(ce), .res_n(~rst), .ram_init(1'b0), .ram_init_7800(1'b0),
		.addr(ab[6:0]), .RW_n(rw), .d_in(db), .d_out(r_dout), .RS_n(ab[9]),
		.IRQ_n(r_irq), .IRQ_n_oe(r_irq_oe), .CS1(ab[7]), .CS2_n(~cs_riot),
		.PA_in(8'hFF), .PA_out(pa_out), .PB_in(8'hFF), .PB_out(pb_out), .oe(r_oe), .PA_read(r_pa_read));

	// ---- the DUT --------------------------------------------------------------------
	wire [48:0] dstat;
	daria_dbg_status dut (
		.clk(clk), .rst(rst), .ce(ce), .ab(ab), .rw(rw), .db_w(db),
		.call_busy(busy), .call_tog(tog), .g_locked(glk), .g_unlock(gul), .dstat(dstat));

	// ---- the reference: tb_frames' rule, on the RIOT's own signals -------------------
	wire r_sel = riot.CS1 && !riot.CS2_n && riot.RS_n && riot.addr[2];
	longint now = 0, t_w = -1, req_t = 0;
	bit     expired = 0, await_p = 0, sys_call = 0, tog_q = 0, ul_q = 0, lk_q = 0;
	int     ref_late = 0, ref_calls = 0, ref_unl = 0;
	int     errors = 0, n_copy = 0, n_late = 0, n_calls = 0, n_guard = 0;
	int     cov_late = 0, cov_ontime = 0, cov_wr_wrap = 0, cov_intim_roll = 0, cov_poll_wrap = 0, cov_calls = 0, cov_resets = 0;

	task automatic err(input string what);
		if (errors < 10) $display("ERROR clock %0d: %s", now, what);
		errors++;
	endtask

	bit     reset_seen = 0;         // the RIOT's registers have no power-up value: compared from its first reset
	always @(posedge clk) begin
		// the DUT's registers as the last edge left them, against the reference's
		if (reset_seen && (dut.t_timer !== riot.timer || dut.t_pre !== riot.prescaler || dut.t_incr !== riot.incr || dut.t_roll !== riot.rollover)) begin
			n_copy++;
			err($sformatf("copy: timer %02x/%02x prescaler %0d/%0d incr %0d/%0d rollover %0d/%0d (DUT/RIOT)",
				dut.t_timer, riot.timer, dut.t_pre, riot.prescaler, dut.t_incr, riot.incr, dut.t_roll, riot.rollover));
		end
		if (dstat[47:36] !== 12'(ref_late > 4095 ? 4095 : ref_late)) begin
			n_late++;
			err($sformatf("late calls: DUT %0d, tb_frames' rule %0d", dstat[47:36], ref_late));
		end
		if (dstat[23:0] !== 24'(ref_calls)) begin
			n_calls++;
			err($sformatf("calls: DUT %0d, flips %0d", dstat[23:0], ref_calls));
		end
		if (dstat[35:24] !== 12'(ref_unl > 4095 ? 4095 : ref_unl) || dstat[48] !== lk_q) begin
			n_guard++;
			err($sformatf("guard: DUT unlocks %0d locked %0d, bench %0d %0d", dstat[35:24], dstat[48], ref_unl, lk_q));
		end
		// the reference's update for this edge (tb_frames' statements, in its order)
		if (ce && !rst) begin
			if (r_sel && !riot.RW_n && riot.addr[4]) begin
				if (riot.timer_wrap) cov_wr_wrap++;
				t_w = now;
				expired = 0;
			end
			if (riot.timer_wrap && !expired && t_w >= 0)
				expired = 1;
			if (r_sel && riot.RW_n && !riot.addr[0] && riot.rollover) cov_intim_roll++;
			if (r_sel && riot.RW_n && await_p) begin
				await_p = 0;
				if (riot.timer_wrap) cov_poll_wrap++;
				if (t_w >= 0 && t_w <= req_t && expired) begin ref_late++; cov_late++; end
				else cov_ontime++;
			end
		end
		if (rst) begin
			t_w = -1;
			expired = 0;
			await_p = 0;
			ref_late = 0;
		end
		if (busy && !sys_call) begin
			sys_call = 1;
			req_t = now - 1;
			await_p = 0;
		end
		if (sys_call && !busy) begin
			sys_call = 0;
			if (!rst) await_p = 1;
		end
		if (tog !== tog_q) ref_calls++;
		if (rst) ref_calls = 0;
		tog_q = tog;
		if (ul_q) ref_unl++;
		ul_q = gul;
		lk_q = glk;
		if (rst) reset_seen = 1;
		now++;
	end

	// ---- stimulus ---------------------------------------------------------------------
	int unsigned seed = 1, cycles = 1500000;
	function automatic int unsigned rnd(input int unsigned n);
		return $urandom % n;
	endfunction
	// one bus cycle: the access held for three clocks, the clock enable in the middle
	task automatic bus(input logic [15:0] a, input logic r, input logic [7:0] d);
		@(negedge clk); ab = a; rw = r; db = d; ce = 1'b0;
		@(negedge clk); ce = 1'b1;
		@(negedge clk); ce = 1'b0;
	endtask
	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("cycles=%d", cycles));
		void'($urandom(seed));
		$display("tb_dstat: seed %0d, %0d bus cycles", seed, cycles);
		repeat (5) @(negedge clk);
		rst = 1'b0;
		for (int unsigned i = 0; i < cycles; i++) begin
			int unsigned k;
			logic [15:0] a;
			logic [7:0]  v;
			// the guard's inputs: a lock state that changes now and then, an
			// unlock pulse when it drops
			if (rnd(4000) == 0) begin
				@(negedge clk);
				if (glk) gul = 1'b1;
				glk = ~glk;
				@(negedge clk);
				gul = 1'b0;
			end
			// a reset now and then
			if (rnd(60000) == 0) begin
				@(negedge clk);
				rst = 1'b1;
				repeat (3 + rnd(8)) @(negedge clk);
				rst = 1'b0;
				cov_resets++;
			end
			// a call: call_tog flips, busy follows, the bus parked in cartridge space
			if (rnd(300) == 0) begin
				int unsigned len;
				len = rnd(10) == 0 ? 1 + rnd(3000) : 1 + rnd(300);
				@(negedge clk); tog = ~tog;
				@(negedge clk); busy = 1'b1;
				for (int unsigned j = 0; j < len; j++) bus(16'h1FF0 | 16'(rnd(16)), 1'b1, 8'd0);
				@(negedge clk); busy = 1'b0;
				cov_calls++;
			end
			k = rnd(100);
			v = rnd(4) != 0 ? 8'(rnd(4)) : 8'(rnd(256));
			if (k < 35) begin
				// timer read: INTIM or TIMINT, any mirror (A0 picks, A1 A3 A4 free)
				a = 16'h0284 | 16'(rnd(2)) | (16'(rnd(2)) << 1) | (16'(rnd(2)) << 3) | (16'(rnd(2)) << 4);
				bus(a, 1'b1, 8'd0);
			end else if (k < 47) begin
				// timer write: TIM1T, TIM8T (most), TIM64T, T1024T (few); A3 the interrupt enable
				int unsigned iv;
				iv = rnd(20);
				iv = iv < 9 ? 0 : iv < 17 ? 1 : iv < 19 ? 2 : 3;
				if (iv >= 2) v = 8'(rnd(3));
				a = 16'h0294 | 16'(iv) | (16'(rnd(2)) << 3);
				bus(a, 1'b0, v);
			end else if (k < 52) begin
				bus(16'h0284 | 16'(rnd(4)), 1'b0, v);                 // edge-detect control (A4 = 0)
			end else if (k < 60) begin
				bus(16'h0280 | 16'(rnd(4)), 1'(rnd(2)), v);           // ports A and B
			end else if (k < 66) begin
				bus(16'h0080 | 16'(rnd(128)), 1'(rnd(2)), v);         // RIOT RAM (A9 = 0)
			end else if (k < 74) begin
				bus(16'h1284 | 16'(rnd(32)), 1'(rnd(2)), v);          // the timer's addresses with A12 = 1
			end else if (k < 80) begin
				bus(16'h0200 | 16'(rnd(128)), 1'(rnd(2)), v);         // A7 = 0: the TIA
			end else begin
				bus(16'h1000 | 16'(rnd(4096)), 1'b1, 8'd0);           // cartridge reads
			end
		end
		repeat (4) @(negedge clk);
		$display("coverage: calls %0d, polls late %0d, on time %0d, timer writes on the old timer's wrap %0d, INTIM reads in a rollover %0d, polls on the wrap's clock %0d, resets %0d",
			cov_calls, cov_late, cov_ontime, cov_wr_wrap, cov_intim_roll, cov_poll_wrap, cov_resets);
		$display("result: clocks=%0d copy_bad=%0d late_bad=%0d calls_bad=%0d guard_bad=%0d late=%0d calls=%0d unlocks=%0d errors=%0d",
			now, n_copy, n_late, n_calls, n_guard, ref_late, ref_calls, ref_unl, errors);
		$finish;
	end
endmodule
