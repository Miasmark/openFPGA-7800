//------------------------------------------------------------------------------
// daria_mmio.sv (src/fpga/core/bupchip/) against a reference model: MAMCR,
// timer 1's TCR and TC, step 5 of docs/DARIA_CORE.md ("Timer 1 and MAMCR";
// M3, M4, P4).
//
// Clocks (+clk=sync, the default, or +clk=async; +pal):
//   sync   one VCO, 687.27 MHz (NTSC) or 681.0 MHz (PAL): clk_sys VCO / 48
//          (14.318182 or 14.1875 MHz), clk_arm VCO / 18 (38.181818 or
//          37.833 MHz), rising together every 3 clk_sys
//   async  clk_arm at a random rate in 24-45 MHz and a random phase; its
//          edges never fall on clk_sys's
// Reset: one level, rst_src, through 1-3 clk_sys flops (rst_sys) and 1-8
// clk_arm flops (rst_arm), the depths drawn again for every reset.
//
// The bus is driven as bup_cpu's W drives it: sel for one clk_arm clock,
// wdata on every lane (st_lanes), rdata read in that clock. Accesses are at
// least one clock apart (bup_cpu's are at least two).
//
// The model. MAMCR and TCR are clk_arm registers with upstream's decode and
// strobes. The counter runs on clk_sys as upstream's does on its 5 x clk_sys
// ARM clock: five ticks a clk_sys on a phase mod 45 (NTSC) or 76 (PAL) that
// skips phase 0, while run is high and TCR bit 0 has come through two clk_sys
// flops. A TC write lands on the third clk_sys edge after its clk_arm edge
// (two flops and the merging clock) and replaces that edge's increment.
// Checked against the DUT:
//   - every clk_sys edge, the DUT's counter equals the model's, except during
//     the back-to-back phase (queued writes land later) and while a reset is
//     under way (the two sides clear at different times);
//   - every read of MAMCR and TCR equals the model's register, and every read
//     anywhere else in the window, +1 to +3 included, is 0;
//   - every read of TC equals the model's counter at some clk_sys edge at or
//     before the read, with every TC write the CPU made after that edge laid
//     over it. The mirror takes written bytes at once, so this is also "never
//     older than the CPU's last write". The age of the newest matching edge is
//     the read's staleness: at most 8 clk_sys, or 16 within 20 clk_sys of a
//     byte or halfword write to TC (the lanes it did not write keep an older
//     snapshot while it is in flight);
//   - every sample of a held bus (the TC write where clk_sys merges it, the
//     snapshot where clk_arm takes it) comes at least one destination clock
//     after the bus last changed (the SDC's bound is 20 ns).
//
// Phases:
//   regs      MAMCR and TCR by byte, halfword and word, read back at every
//             size; +1 to +3 and every other window address (random ones, and
//             each register's address with one of bits 0-20 flipped) read 0
//             and drop their writes
//   rates     the TCR start and stop latency; a 68,400-clock window (9 x 76 x
//             100) with the counter running, which must add exactly 44 / 9
//             (NTSC) or 375 / 76 (PAL) a clock; run low for 1,000 clocks;
//             then +long clk_sys of random reads, TCR switches, isolated TC
//             writes and pauses (run low for 1-2,000 clocks at random)
//   writes    300 isolated TC writes of every size, the counter running or
//             not, each followed by reads every 1-3 clk_arm; a running counter
//             overwritten with 0 and read every clock ("never older"); a wrap
//   b2b       TC writes 0-3 clk_arm apart (a queue): with the counter stopped
//             every read must equal all the writes so far, in order, and the
//             counter must too once they land; with it running, word writes
//             only, every read must be at or after the last write
//   resets    160 resets of 4-30 clk_sys: during a TC write's flight (the
//             reset from the write's own clock on), with a write queued
//             behind another, at random phases, and just after a snapshot's
//             toggle; afterwards every register and toggle is 0 and
//             consistent, and the block works
//   draconian Draconian's measurement: T1TC = 0, TCR bit 0 set two clocks
//             later, one NTSC frame (262 x 912 clk_sys) of CPU time, TCR bit 0
//             cleared, T1TC read three instructions on. Once from a reset and
//             once over a running counter. The reading must be within 55
//             counts of the counter rate times the interval
//
//   +clk=sync|async  +pal  +seed=S  +long=N (clk_sys clocks of the random
//   phase; 400,000)
// The last line, "result: ...", is for run_mmio.sh. Built with -DTB_DEBUG, the
// first counter mismatch also prints the model's last writes and edges.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1fs/1fs
`default_nettype none

module tb_mmio;
	localparam logic [31:0] A_MAMCR = 32'hE01F_C000, A_TCR = 32'hE000_8004, A_TC = 32'hE000_8008;
	localparam longint FRAME = 262 * 912;           // clk_sys clocks in an NTSC frame
	localparam longint DRAC_LIMIT = 1171987;        // what Draconian compares its reading with

	// ---- configuration and clocks ---------------------------------------------------------
	bit     async_clk = 0, pal = 0;
	int     seed = 1;
	longint long_cyc = 400000;
	longint u_vco, t_sys, t_arm, arm_off = 1;       // fs
	logic   clk_sys = 0, clk_arm = 0;
	bit     go = 0;
	string  clk_name = "sync";

	initial begin
		string s;
		longint h;
		if ($value$plusargs("clk=%s", s)) async_clk = s == "async";
		if (async_clk) clk_name = "async";
		pal = $test$plusargs("pal");
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("long=%d", long_cyc));
		void'($urandom(seed));
		u_vco = pal ? 64'd1468429 : 64'd1455026;
		t_sys = 48 * u_vco;
		if (!async_clk) t_arm = 18 * u_vco;
		else begin
			// clk_sys's edges fall on 0 mod 4 fs, clk_arm's on 1 mod 4: never
			// together, and 2 fs after any edge is no edge (the bus monitors)
			h = 4 * (longint'($urandom_range(20833333, 11111111)) / 4);
			t_arm = 2 * h;
			arm_off = 4 * longint'($urandom_range(32'(h / 4), 0)) + 1;
		end
		go = 1;
	end

	initial begin
		int k;
		wait (go);
		if (!async_clk) begin
			k = 0;
			clk_sys = 1;
			clk_arm = 1;
			forever begin
				#(3 * u_vco);
				k += 3;
				if (k % 24 == 0) clk_sys = ~clk_sys;
				if (k % 9 == 0) clk_arm = ~clk_arm;
				if (k == 144) k = 0;
			end
		end
	end
	initial begin
		wait (go);
		if (async_clk) forever begin
			#(t_sys / 2);
			clk_sys = ~clk_sys;
		end
	end
	initial begin
		wait (go);
		if (async_clk) begin
			#(arm_off);
			forever begin
				clk_arm = ~clk_arm;
				#(t_arm / 2);
			end
		end
	end

	// ---- resets and the DUT -----------------------------------------------------------------
	logic       rst_src = 1;
	logic [2:0] rsh_sys = 3'b111;
	logic [7:0] rsh_arm = 8'hFF;
	int         d_sys = 2, d_arm = 2;
	always @(posedge clk_sys) rsh_sys <= {rsh_sys[1:0], rst_src};
	always @(posedge clk_arm) rsh_arm <= {rsh_arm[6:0], rst_src};
	wire rst_sys = rsh_sys[d_sys - 1];
	wire rst_arm = rsh_arm[d_arm - 1];

	logic        sel = 0, wr = 0, run = 1;
	logic [31:0] addr = 0, wdata = 0;
	logic  [1:0] size = 0;
	wire  [31:0] rdata;

	daria_mmio dut (
		.clk_arm, .rst_arm, .sel, .write(wr), .addr, .size, .wdata, .rdata,
		.clk_sys, .rst_sys, .pal, .run);

	// ---- helpers ----------------------------------------------------------------------------
	function automatic logic [31:0] lanes(input logic [31:0] old, input logic [31:0] v,
			input logic [3:0] be);
		logic [31:0] r;
		for (int i = 0; i < 4; i++) r[8 * i +: 8] = be[i] ? v[8 * i +: 8] : old[8 * i +: 8];
		return r;
	endfunction
	function automatic logic [3:0] be_of(input logic [1:0] sz);
		return sz == 2'd0 ? 4'b0001 : sz == 2'd1 ? 4'b0011 : 4'b1111;
	endfunction
	function automatic logic [31:0] st_lanes(input logic [31:0] v, input logic [1:0] sz);
		return sz == 2'd0 ? {4{v[7:0]}} : sz == 2'd1 ? {2{v[15:0]}} : v;
	endfunction
	function automatic int urand(input int lo, input int hi);
		return lo + int'($urandom_range(32'(hi - lo)));
	endfunction
	function automatic logic [1:0] rsize();
		return 2'(urand(0, 2));
	endfunction

	longint n_err = 0, n_chk = 0;
	string  phase = "init";
	function automatic void fail(input string m);
		n_err++;
		if (n_err <= 40) $display("ERROR [%s] %0d ns: %s", phase, $time / 1000000, m);
	endfunction

	// ---- the model: clk_arm registers and the TC writes ---------------------------------------
	logic [31:0] m_mamcr = 0, m_tcr = 0;
	localparam int WR = 256;                        // TC writes, a ring by sequence number
	longint      w_t[WR];                           // its clk_arm edge
	logic [31:0] w_d[WR];
	logic  [3:0] w_be[WR];
	int          w_edges[WR];                       // clk_sys edges after it
	longint      w_midx[WR];                        // model edge it merged on; -1 not yet, -2 dropped
	longint      w_n = 0, w_first = 0, w_from = 0;  // next; first not merged; first since rst_arm
	longint      t_partial = -1;                    // the last byte or halfword TC write
	longint      t_lastw = -1;

	always @(posedge clk_arm) begin
		int i;
		if (rst_arm) begin
			m_mamcr <= 32'd0;
			m_tcr <= 32'd0;
			w_from = w_n;
		end else if (sel && wr) begin
			if (addr == A_MAMCR) m_mamcr <= lanes(m_mamcr, wdata, be_of(size));
			if (addr == A_TCR) m_tcr <= lanes(m_tcr, wdata, be_of(size));
			if (addr == A_TC) begin
				i = int'(w_n % WR);
				w_t[i] = $time;
				w_d[i] = wdata;
				w_be[i] = be_of(size);
				w_edges[i] = 0;
				w_midx[i] = -1;
				w_n++;
				if (size != 2'd2) t_partial = $time;
				t_lastw = $time;
			end
		end
	end

	// ---- the model: the counter on clk_sys ---------------------------------------------------------
	logic [31:0] m_tc = 0;
	logic  [1:0] m_en = 2'b00;
	int          m_up = 0;                          // upstream's phase in ARM ticks
	longint      m_idx = 0;                         // clk_sys edges
	localparam int HN = 1024;
	longint      h_t[HN];
	logic [31:0] h_v[HN];
	longint      n_merge = 0, n_merge_inc = 0, n_pause_en = 0;

	always @(posedge clk_sys) begin
		logic [31:0] v;
		bit merged;
		int P, inc, k;
		v = m_tc;
		merged = 0;
		P = pal ? 76 : 45;
		m_idx++;
		if (rst_sys) begin
			v = 32'd0;
			m_up = 0;
			m_en <= 2'b00;
			for (longint i = w_first; i < w_n; i++) w_midx[int'(i % WR)] = -2;
			w_first = w_n;
		end else begin
			for (longint i = w_first; i < w_n; i++) begin
				k = int'(i % WR);
				if (w_midx[k] == -1 && w_t[k] < $time) begin
					w_edges[k]++;
					if (w_edges[k] == 3) begin
						v = lanes(v, w_d[k], w_be[k]);
						w_midx[k] = m_idx;
						merged = 1;
					end
				end
			end
			while (w_first < w_n && w_midx[int'(w_first % WR)] != -1) w_first++;
			if (run) begin
				inc = 0;
				for (int j = 0; j < 5; j++) if ((m_up + j) % P != 0) inc++;
				m_up = (m_up + 5) % P;
				if (m_en[1]) begin
					if (merged) n_merge_inc++;
					else v = v + 32'(inc);
				end
			end else if (m_en[1]) n_pause_en++;
			if (merged) n_merge++;
			m_en <= {m_en[0], m_tcr[0]};
		end
		m_tc = v;
		h_t[int'(m_idx % HN)] = $time;
		h_v[int'(m_idx % HN)] = v;
	end

	bit          exact_on = 0, model_ok = 0;
	longint      n_exact = 0;
	logic [31:0] h_dut[HN];                         // the DUT's counter after each edge
	always @(negedge clk_sys) begin
		h_dut[int'(m_idx % HN)] = dut.tc;
		if (exact_on) begin
			n_exact++;
			if (dut.tc !== m_tc) begin
				fail($sformatf("counter %h, model %h", dut.tc, m_tc));
`ifdef TB_DEBUG
				if (n_err == 1) begin
					$display("  t_rs %0d t_ra %0d now %0d m_idx %0d d_sys %0d d_arm %0d", t_rs / 1000000, t_ra / 1000000, $time / 1000000, m_idx, d_sys, d_arm);
					for (longint i = w_n - 6; i < w_n; i++)
						$display("  write %0d: t %0d d %h be %b edges %0d midx %0d", i, w_t[int'(i % WR)] / 1000000, w_d[int'(i % WR)], w_be[int'(i % WR)], w_edges[int'(i % WR)], w_midx[int'(i % WR)]);
					for (longint j = m_idx - 12; j <= m_idx; j++)
						$display("  edge %0d t %0d model %h dut %h", j, h_t[int'(j % HN)] / 1000000, h_v[int'(j % HN)], h_dut[int'(j % HN)]);
				end
`endif
			end
		end
	end
	// Edges after time t at which the DUT's counter changed, among the first n.
	function automatic longint first_after(input longint t);
		longint j;
		j = m_idx;
		while (j > 1 && h_t[int'((j - 1) % HN)] > t) j--;
		return j;
	endfunction

	// ---- TC reads: the newest model edge that explains the value --------------------------------------
	function automatic int tc_age(input logic [31:0] r, input longint t0, input int amax);
		longint j, e, lo;
		logic [31:0] v;
		int k;
		j = m_idx;
		while (j > 0 && h_t[int'(j % HN)] > t0) j--;
		lo = w_n - 64;
		if (lo < w_from) lo = w_from;
		for (int a = 0; a <= amax && j - a > 0; a++) begin
			e = j - a;
			v = h_v[int'(e % HN)];
			for (longint i = lo; i < w_n; i++) begin
				k = int'(i % WR);
				if (w_t[k] <= t0 && (w_midx[k] == -1 || w_midx[k] > e)) v = lanes(v, w_d[k], w_be[k]);
			end
			if (v == r) return a;
		end
		return -1;
	endfunction

	longint n_rd_tc = 0, n_rd_part = 0, age_plain_max = 0, age_part_max = 0;
	longint age_hist[17];
	task automatic check_tc(input logic [31:0] r, input longint t0);
		int a, lim;
		bit part;
		if (model_ok) begin
			n_rd_tc++;
			part = t_partial >= 0 && t0 - t_partial < 20 * t_sys;
			lim = part ? 16 : 8;
			a = tc_age(r, t0, 40);
			if (a < 0 || a > lim)
				fail($sformatf("TC read %h: no model value within %0d clk_sys (age %0d; model now %h)",
					r, lim, a, m_tc));
			else if (part) begin
				n_rd_part++;
				if (a > age_part_max) age_part_max = a;
			end else begin
				if (a > age_plain_max) age_plain_max = a;
				age_hist[a]++;
			end
		end
	endtask

	// ---- the bus ----------------------------------------------------------------------------------
	// Called at a clk_arm rising edge; returns at the edge that ends the access.
	longint t_p0 = 0, t_commit = 0;
	task automatic acc(input bit w, input logic [31:0] a, input logic [1:0] sz, input logic [31:0] v,
			output logic [31:0] r);
		t_p0 = $time;
		sel <= 1'b1;
		wr <= w;
		addr <= a;
		size <= sz;
		wdata <= st_lanes(v, sz);
		@(negedge clk_arm);
		r = rdata;
		@(posedge clk_arm);
		t_commit = $time;
		sel <= 1'b0;
		wr <= 1'b0;
	endtask
	task automatic idle(input longint n);
		repeat (n) @(posedge clk_arm);
	endtask
	task automatic sys_wait(input int n);
		repeat (n) @(posedge clk_sys);
		@(posedge clk_arm);
	endtask
	task automatic wreg(input logic [31:0] a, input logic [1:0] sz, input logic [31:0] v);
		logic [31:0] r;
		acc(1'b1, a, sz, v, r);
	endtask
	task automatic rd(input logic [31:0] a, input logic [1:0] sz, output logic [31:0] r);
		acc(1'b0, a, sz, 32'd0, r);
		n_chk++;
		if (a == A_MAMCR) begin
			if (r !== m_mamcr) fail($sformatf("MAMCR read %h, model %h", r, m_mamcr));
		end else if (a == A_TCR) begin
			if (r !== m_tcr) fail($sformatf("TCR read %h, model %h", r, m_tcr));
		end else if (a == A_TC)
			check_tc(r, t_p0);
		else if (r !== 32'd0)
			fail($sformatf("read of %h (size %0d) gave %h", a, sz, r));
	endtask
	// A TC write with no other in flight: the model's three-edge landing holds.
	task automatic tc_write_iso(input logic [1:0] sz, input logic [31:0] v);
		while (t_lastw >= 0 && $time - t_lastw < 24 * t_sys) @(posedge clk_arm);
		wreg(A_TC, sz, v);
	endtask

	// ---- run: held, or random pauses ---------------------------------------------------------------
	int run_mode = 0;                               // 0 high, 1 low, 2 random
	initial begin
		wait (go);
		forever begin
			@(posedge clk_sys);
			case (run_mode)
				0: run <= 1'b1;
				1: run <= 1'b0;
				default:
					if (run && urand(0, 2999) == 0) run <= 1'b0;
					else if (!run && urand(0, 299) == 0) run <= 1'b1;
			endcase
		end
	end

	// ---- held buses: sampled at least one destination clock after they change ------------------------------
	longint t_wbus = 0, t_hbus = 0, n_wsamp = 0, n_hsamp = 0;
	longint w_gap_min = 64'h7FFF_FFFF_FFFF_FFFF, h_gap_min = 64'h7FFF_FFFF_FFFF_FFFF;
	// Each bus changes only on its own clock's rising edge; 2 fs later is no edge.
	logic [35:0] wbus_q = 0;
	logic [32:0] hbus_q = 0;
	always @(posedge clk_arm) begin
		#2;
		if ({dut.w_data, dut.w_strb} !== wbus_q) begin
			wbus_q = {dut.w_data, dut.w_strb};
			t_wbus = $time - 2;
		end
	end
	always @(posedge clk_sys) begin
		#2;
		if ({dut.hold, dut.hold_tok} !== hbus_q) begin
			hbus_q = {dut.hold, dut.hold_tok};
			t_hbus = $time - 2;
		end
	end
	always @(posedge clk_sys) if (dut.merge_now && !rst_sys) begin
		n_wsamp++;
		if ($time - t_wbus < w_gap_min) w_gap_min = $time - t_wbus;
		if ($time - t_wbus < t_sys)
			fail($sformatf("write bus changed %0d ps before clk_sys took it", ($time - t_wbus) / 1000));
	end
	always @(posedge clk_arm) if (dut.snap_new && !rst_arm) begin
		n_hsamp++;
		if ($time - t_hbus < h_gap_min) h_gap_min = $time - t_hbus;
		if ($time - t_hbus < t_arm)
			fail($sformatf("snapshot bus changed %0d ps before clk_arm took it", ($time - t_hbus) / 1000));
	end

	// ---- coverage ------------------------------------------------------------------------------------
	longint n_launch = 0, n_qlaunch = 0, n_queued = 0, t_launch = 0, flight_max = 0;
	always @(posedge clk_arm) if (!rst_arm) begin
		if (dut.busy && dut.snap_ok && $time - t_launch > flight_max) flight_max = $time - t_launch;
		if (dut.launch) t_launch = $time;
		if (dut.launch) begin
			n_launch++;
			if (dut.q_strb != 4'd0) n_qlaunch++;
		end
		if (dut.wr_tc && dut.busy && !dut.snap_ok) n_queued++;
	end
	// What each reset found in flight, on the first edge each side applies it.
	logic   rs_q = 0, ra_q = 0;
	longint t_rs = 0, t_ra = 0, n_rst = 0, n_rst_wfl = 0, n_rst_busy = 0, n_rst_q = 0, n_rst_sfl = 0;
	longint n_sys_first = 0, n_arm_first = 0;
	always @(posedge clk_sys) begin
		if (rst_sys && !rs_q) begin
			t_rs = $time;
			if (dut.w_tog != dut.w_seen) n_rst_wfl++;
			if (dut.sn_tog != dut.sn_seen) n_rst_sfl++;
		end
		rs_q <= rst_sys;
	end
	always @(posedge clk_arm) begin
		if (rst_arm && !ra_q) begin
			t_ra = $time;
			if (dut.busy) n_rst_busy++;
			if (dut.q_strb != 4'd0) n_rst_q++;
			if (dut.sn_tog != dut.sn_seen) n_rst_sfl++;
		end
		ra_q <= rst_arm;
	end

	// ---- phases ------------------------------------------------------------------------------------
	task automatic do_reset(input int len);
		d_sys = urand(1, 3);
		d_arm = urand(1, 8);
		exact_on = 0;
		model_ok = 0;
		rst_src <= 1'b1;
		repeat (len) @(posedge clk_sys);
		rst_src <= 1'b0;
		while (rsh_sys != 3'd0 || rsh_arm != 8'd0) @(posedge clk_arm);
		n_rst++;
		if (t_rs < t_ra) n_sys_first++; else n_arm_first++;
		sys_wait(8);                                // the first snapshot after the reset is in
	endtask

	task automatic after_reset();
		logic [31:0] r, x;
		if (dut.tc !== 0 || dut.mirror !== 0 || dut.mamcr !== 0 || dut.tcr !== 0 || dut.busy !== 0 ||
				dut.q_strb !== 0 || dut.w_tog !== dut.w_seen || dut.w_s[1] !== dut.w_tog || dut.hold !== 0)
			fail($sformatf("after reset: tc %h mirror %h mamcr %h tcr %h busy %b q %b tog %b seen %b hold %h",
				dut.tc, dut.mirror, dut.mamcr, dut.tcr, dut.busy, dut.q_strb, dut.w_tog, dut.w_seen, dut.hold));
		if (m_tc !== 0 || m_mamcr !== 0 || m_tcr !== 0) fail("after reset: model not clear");
		exact_on = 1;
		model_ok = 1;
		rd(A_MAMCR, 2'd2, r);
		rd(A_TCR, 2'd2, r);
		rd(A_TC, 2'd2, r);
		if (r !== 0) fail($sformatf("after reset: TC read %h", r));
		// and it works
		x = $urandom();
		tc_write_iso(2'd2, x);
		rd(A_TC, 2'd2, r);
		if (r !== x) fail($sformatf("after reset: TC write %h read back %h", x, r));
		wreg(A_TCR, 2'd0, 32'd1);
		repeat (20) begin
			idle(urand(0, 2));
			rd(A_TC, rsize(), r);
		end
		wreg(A_TCR, 2'd0, 32'd0);
		sys_wait(8);
		rd(A_TC, 2'd2, r);
		if (r !== m_tc) fail($sformatf("after reset: stopped TC read %h, model %h", r, m_tc));
	endtask

	task automatic t_regs();
		logic [31:0] r, a, k;
		logic [31:0] regs[3];
		phase = "regs";
		regs[0] = A_MAMCR;
		regs[1] = A_TCR;
		regs[2] = A_TC;
		// The strobes, by value.
		wreg(A_MAMCR, 2'd2, 32'h1122_3344);
		wreg(A_MAMCR, 2'd0, 32'h0000_00AB);
		rd(A_MAMCR, 2'd2, r);
		if (r !== 32'h1122_33AB) fail($sformatf("MAMCR byte: %h", r));
		wreg(A_MAMCR, 2'd1, 32'h0000_CDEF);
		rd(A_MAMCR, 2'd0, r);
		if (r !== 32'h1122_CDEF) fail($sformatf("MAMCR halfword: %h", r));
		wreg(A_TCR, 2'd2, 32'hA5A5_5A5A);
		wreg(A_TCR, 2'd1, 32'h0000_1234);
		rd(A_TCR, 2'd1, r);
		if (r !== 32'hA5A5_1234) fail($sformatf("TCR halfword: %h", r));
		wreg(A_TCR, 2'd0, 32'h0000_0000);
		rd(A_TCR, 2'd2, r);
		if (r !== 32'hA5A5_1200) fail($sformatf("TCR byte: %h", r));
		// Random sizes and values, read back at every size (TCR bit 0 runs the counter).
		for (int n = 0; n < 300; n++) begin
			a = n % 2 ? A_TCR : A_MAMCR;
			wreg(a, rsize(), $urandom());
			idle(urand(0, 3));
			rd(a, rsize(), r);
			idle(urand(0, 3));
		end
		wreg(A_TCR, 2'd2, 32'd0);
		sys_wait(6);
		tc_write_iso(2'd2, 32'h89AB_CDEF);
		sys_wait(24);
		// +1 to +3: reads 0, writes dropped.
		for (int g = 0; g < 3; g++) begin
			k = $urandom();
			if (g == 1) k[0] = 1'b0;
			if (g < 2) wreg(regs[g], 2'd2, k);
			else tc_write_iso(2'd2, k);
			sys_wait(24);
			for (int off = 1; off < 4; off++) begin
				wreg(regs[g] + off, 2'd0, $urandom());
				idle(urand(0, 2));
				wreg(regs[g] + off, 2'd2, $urandom());
				idle(urand(0, 2));
				if (off == 2) wreg(regs[g] + off, 2'd1, $urandom());
				for (int sz = 0; sz < 3; sz++) rd(regs[g] + off, 2'(sz), r);
			end
			sys_wait(24);
			rd(regs[g], 2'd2, r);
			if (r !== k) fail($sformatf("register %h holds %h after +1..+3 writes, not %h", regs[g], r, k));
		end
		// Every other address in the window: random ones, then each register with one bit flipped.
		for (int n = 0; n < 600; n++) begin
			a = 32'hE000_0000 | ($urandom() & 32'h001F_FFFF);
			if (n % 3 == 0) a = 32'hE000_8000 | ($urandom() & 32'h0000_003F);
			if (n % 3 == 1) a = 32'hE01F_C000 | ($urandom() & 32'h0000_003F);
			if (a == A_MAMCR || a == A_TCR || a == A_TC) continue;
			if (urand(0, 1)) wreg(a, rsize(), $urandom());
			else rd(a, rsize(), r);
			idle(urand(0, 2));
		end
		for (int g = 0; g < 3; g++)
			for (int b = 0; b < 21; b++) begin
				a = regs[g] ^ (32'd1 << b);
				wreg(a, rsize(), $urandom());
				rd(a, rsize(), r);
			end
		sys_wait(24);
		rd(A_MAMCR, 2'd2, r);
		rd(A_TCR, 2'd2, r);
		rd(A_TC, 2'd2, r);
		if (r !== dut.tc || r !== m_tc) fail($sformatf("TC after the window sweep: %h", r));
	endtask

	longint lat_start = -1, lat_stop = -1, rate_win = 0, rate_ok = 0;
	task automatic t_rates();
		logic [31:0] r, v0, v1;
		longint tc0, n, t_end;
		int act;
		phase = "rates";
		wreg(A_TCR, 2'd2, 32'd0);
		sys_wait(6);
		tc_write_iso(2'd2, 32'd0);
		sys_wait(24);
		// Start: the first edge after TCR's clk_arm edge that adds; stop: the last.
		wreg(A_TCR, 2'd0, 32'd1);
		tc0 = t_commit;
		sys_wait(16);
		n = first_after(tc0);
		for (int e = 0; e < 12; e++)
			if (h_dut[int'((n + e) % HN)] !== h_dut[int'((n + e - 1) % HN)]) begin
				lat_start = e + 1;
				break;
			end
		sys_wait(50);
		wreg(A_TCR, 2'd0, 32'd0);
		tc0 = t_commit;
		sys_wait(16);
		n = first_after(tc0);
		lat_stop = 0;
		for (int e = 0; e < 12; e++)
			if (h_dut[int'((n + e) % HN)] !== h_dut[int'((n + e - 1) % HN)]) lat_stop = e + 1;
		// The rate, white box: 9 x 76 x 100 clocks.
		wreg(A_TCR, 2'd0, 32'd1);
		sys_wait(8);
		@(negedge clk_sys);
		v0 = dut.tc;
		repeat (68400) @(negedge clk_sys);
		v1 = dut.tc;
		rate_win = longint'(v1 - v0);
		rate_ok = rate_win == (pal ? 64'd337500 : 64'd334400);
		if (!rate_ok) fail($sformatf("68,400 clocks added %0d", rate_win));
		// Run low.
		@(posedge clk_arm);
		run_mode = 1;
		repeat (3) @(posedge clk_sys);
		@(negedge clk_sys);
		v0 = dut.tc;
		repeat (1000) begin
			@(negedge clk_sys);
			if (dut.tc !== v0) fail("the counter moved while run was low");
		end
		@(posedge clk_arm);
		rd(A_TC, 2'd2, r);
		if (r !== v0) fail($sformatf("paused TC read %h, counter %h", r, v0));
		run_mode = 0;
		// Random: reads, TCR switches, isolated writes, pauses.
		run_mode = 2;
		t_end = $time + long_cyc * t_sys;
		while ($time < t_end) begin
			act = urand(0, 99);
			if (act < 70) begin
				idle(urand(0, 300));
				rd(A_TC, rsize(), r);
			end else if (act < 80) begin
				wreg(A_TCR, 2'd0, 32'(urand(0, 3) != 0));
			end else if (act < 84) begin
				tc_write_iso(rsize(), $urandom());
				repeat (10) begin
					idle(urand(0, 2));
					rd(A_TC, rsize(), r);
				end
			end else
				idle(urand(1, 3000));
		end
		run_mode = 0;
		wreg(A_TCR, 2'd2, 32'd0);
		sys_wait(12);
		rd(A_TC, 2'd2, r);
		if (r !== m_tc || r !== dut.tc) fail($sformatf("stopped TC read %h, model %h", r, m_tc));
	endtask

	longint n_never = 0;
	task automatic t_writes();
		logic [31:0] r, v;
		logic [1:0] sz;
		longint edges;
		phase = "writes";
		wreg(A_TCR, 2'd0, 32'd1);
		for (int n = 0; n < 300; n++) begin
			sz = rsize();
			v = $urandom();
			case (urand(0, 3))
				0: v[23:0] = 24'hFFFF_F0 | 24'(urand(0, 15));
				1: v[7:0] = 8'hF0 | 8'(urand(0, 15));
				default: ;
			endcase
			if (n % 8 == 5) wreg(A_TCR, 2'd0, 32'd0);
			if (n % 8 == 7) wreg(A_TCR, 2'd0, 32'd1);
			tc_write_iso(sz, v);
			repeat (15) begin
				idle(urand(0, 2));
				rd(A_TC, rsize(), r);
			end
		end
		// Never older than the CPU's last write: a high count overwritten with 0, read every clock.
		wreg(A_TCR, 2'd0, 32'd1);
		for (int n = 0; n < 40; n++) begin
			tc_write_iso(2'd2, 32'hC000_0000 | $urandom());
			sys_wait(urand(10, 40));
			tc_write_iso(2'd2, 32'd0);
			repeat (40) begin
				rd(A_TC, 2'd2, r);
				edges = ($time - t_lastw) / t_sys + 1;
				n_never++;
				if (longint'(r) > 5 * edges + 5)
					fail($sformatf("TC read %h after writing 0, %0d clk_sys before", r, edges));
			end
		end
		// The wrap.
		tc_write_iso(2'd2, 32'hFFFF_FF00);
		repeat (40) begin
			idle(urand(0, 4));
			rd(A_TC, rsize(), r);
		end
		sys_wait(100);
		rd(A_TC, 2'd2, r);
		wreg(A_TCR, 2'd0, 32'd0);
		sys_wait(8);
	endtask

	task automatic t_b2b();
		logic [31:0] e, r, v, last;
		logic [1:0] sz;
		longint tv, edges;
		phase = "b2b";
		wreg(A_TCR, 2'd2, 32'd0);
		sys_wait(8);
		e = $urandom();
		tc_write_iso(2'd2, e);
		sys_wait(24);
		exact_on = 0;
		model_ok = 0;
		// Stopped: exact, every read and the final value.
		for (int n = 0; n < 400; n++) begin
			for (int j = urand(2, 7); j > 0; j--) begin
				if (urand(0, 99) < 65) begin
					sz = rsize();
					v = $urandom();
					acc(1'b1, A_TC, sz, v, r);
					e = lanes(e, st_lanes(v, sz), be_of(sz));
				end else begin
					acc(1'b0, A_TC, rsize(), 32'd0, r);
					n_chk++;
					if (r !== e) fail($sformatf("queued writes: TC read %h, expected %h", r, e));
				end
				idle(urand(0, 3));
			end
			if (n % 8 == 7) begin
				sys_wait(24);
				if (dut.tc !== e) fail($sformatf("queued writes landed as %h, expected %h", dut.tc, e));
				acc(1'b0, A_TC, 2'd2, 32'd0, r);
				if (r !== e) fail($sformatf("queued writes: settled read %h, expected %h", r, e));
			end else
				idle(urand(0, 30));
		end
		sys_wait(24);
		if (dut.tc !== e) fail($sformatf("queued writes landed as %h, expected %h", dut.tc, e));
		// Running, word writes: every read at or after the last one.
		wreg(A_TCR, 2'd0, 32'd1);
		sys_wait(6);
		for (int n = 0; n < 150; n++) begin
			for (int j = urand(2, 4); j > 0; j--) begin
				v = $urandom();
				v[31:30] = 2'(j);                   // the writes of a round lie far apart
				acc(1'b1, A_TC, 2'd2, v, r);
				last = v;
				tv = t_commit;
				idle(urand(0, 3));
			end
			repeat (20) begin
				acc(1'b0, A_TC, 2'd2, 32'd0, r);
				n_chk++;
				edges = (t_p0 - tv) / t_sys + 1;
				if (longint'(r - last) > 5 * edges + 5)
					fail($sformatf("running queued writes: TC read %h, last write %h, %0d clk_sys before",
						r, last, edges));
				idle(urand(0, 2));
			end
			sys_wait(urand(0, 30));
			edges = ($time - tv) / t_sys + 1;
			if (longint'(dut.tc - last) > 5 * edges + 5)
				fail($sformatf("running queued writes: counter %h, last write %h", dut.tc, last));
		end
		// Back to the exact model: stop, and one isolated write both sides land on the same edge.
		wreg(A_TCR, 2'd2, 32'd0);
		sys_wait(30);
		v = $urandom();
		tc_write_iso(2'd2, v);
		sys_wait(30);
		if (dut.tc !== v || m_tc !== v) fail($sformatf("resync: counter %h, model %h, written %h", dut.tc, m_tc, v));
		exact_on = 1;
		model_ok = 1;
	endtask

	task automatic t_resets();
		logic [31:0] r, v;
		bit t;
		phase = "resets";
		for (int n = 0; n < 160; n++) begin
			wreg(A_MAMCR, 2'd2, $urandom());
			wreg(A_TCR, 2'd2, $urandom() | 32'd1);
			tc_write_iso(2'd2, $urandom());
			sys_wait(urand(5, 60));
			case (n % 4)
				0: begin                            // a write in flight
					tc_write_iso(rsize(), $urandom());
					idle(urand(0, 12));
				end
				1: begin                            // one queued behind another
					exact_on = 0;                   // queued writes land later than the model's
					model_ok = 0;
					acc(1'b1, A_TC, 2'd2, $urandom(), r);
					idle(urand(0, 1));
					acc(1'b1, A_TC, rsize(), $urandom(), r);
					idle(urand(0, 8));
				end
				2: idle(urand(0, 40));              // anywhere
				default: begin                      // just after a snapshot's toggle
					t = dut.sn_tog;
					do @(negedge clk_sys); while (dut.sn_tog == t);
					@(posedge clk_arm);
					idle(urand(0, 2));
				end
			endcase
			do_reset(urand(4, 30));
			after_reset();
		end
	endtask

	longint drac_r[2], drac_model[2];
	real    drac_ideal[2];
	string  drac_name[2] = '{"from reset", "over a running counter"};
	task automatic t_draconian(input int which);
		logic [31:0] r;
		longint t_tc, t_set, t_clr, t_from, n;
		phase = {"draconian, ", drac_name[which]};
		if (which == 0) begin
			do_reset(8);
			after_reset();
		end else begin
			wreg(A_TCR, 2'd2, 32'd1);
			tc_write_iso(2'd2, 32'h0123_4567);
			sys_wait(500);
		end
		while ($time - t_lastw < 24 * t_sys) @(posedge clk_arm);
		acc(1'b1, A_TC, 2'd2, 32'd0, r);            // T1TC = 0
		t_tc = t_commit;
		idle(1);
		acc(1'b1, A_TCR, 2'd2, 32'd1, r);           // TCR = 1
		t_set = t_commit;
		// One NTSC frame of CPU time: the clear lands FRAME clk_sys after the set.
		if (!async_clk) idle(FRAME * 8 / 3 - 1);
		else while ($time + t_arm < t_set + FRAME * t_sys) @(posedge clk_arm);
		acc(1'b1, A_TCR, 2'd2, 32'd0, r);           // TCR = 0
		t_clr = t_commit;
		idle(3);                                    // three instructions on
		acc(1'b0, A_TC, 2'd2, 32'd0, r);
		check_tc(r, t_p0);
		t_from = which == 0 ? t_set : t_tc;         // already counting: from the write
		drac_r[which] = longint'(r);
		drac_ideal[which] = real'(t_clr - t_from) / real'(t_sys) * (pal ? 375.0 / 76.0 : 44.0 / 9.0);
		sys_wait(10);
		drac_model[which] = longint'(m_tc);
		if (dut.tc !== m_tc) fail("draconian: counter and model differ after the stop");
		if (real'(drac_r[which]) - drac_ideal[which] > 55.0 || drac_ideal[which] - real'(drac_r[which]) > 55.0)
			fail($sformatf("draconian: read %0d, ideal %.1f", drac_r[which], drac_ideal[which]));
		$display("draconian (%s): read %0d, ideal %.2f (%.3f us of CPU time), diff %.2f; counter when stopped %0d%s",
			drac_name[which], drac_r[which], drac_ideal[which], real'(t_clr - t_from) / 1.0e9,
			real'(drac_r[which]) - drac_ideal[which], drac_model[which],
			pal ? "" : $sformatf("; Draconian's limit %0d, margin %0d", DRAC_LIMIT, DRAC_LIMIT - drac_r[which]));
	endtask

	// ---- main ----------------------------------------------------------------------------------------
	initial begin
		wait (go);
		repeat (10) @(posedge clk_sys);
		rst_src <= 1'b0;
		while (rsh_sys != 3'd0 || rsh_arm != 8'd0) @(posedge clk_arm);
		sys_wait(3);
		exact_on = 1;
		model_ok = 1;
		$display("clocks: clk_sys %.6f MHz, clk_arm %.6f MHz (%s), %s; seed %0d",
			1.0e9 / real'(t_sys), 1.0e9 / real'(t_arm), clk_name,
			pal ? "PAL" : "NTSC", seed);
		t_regs();
		t_rates();
		t_writes();
		t_b2b();
		t_resets();
		t_draconian(0);
		t_draconian(1);
		$display("age histogram (plain TC reads, clk_sys): %0d %0d %0d %0d %0d %0d %0d %0d %0d",
			age_hist[0], age_hist[1], age_hist[2], age_hist[3], age_hist[4], age_hist[5],
			age_hist[6], age_hist[7], age_hist[8]);
		$display("result: clk=%s pal=%0d seed=%0d errors=%0d checks=%0d exact=%0d tcreads=%0d age=%0d partreads=%0d partage=%0d lat_start=%0d lat_stop=%0d rate=%0d merges=%0d merge_inc=%0d pause_en=%0d never=%0d launches=%0d queued=%0d qlaunch=%0d flight_ns=%0d wsamp=%0d wgap_ps=%0d hsamp=%0d hgap_ps=%0d resets=%0d rst_wfl=%0d rst_busy=%0d rst_q=%0d rst_sfl=%0d sys_first=%0d arm_first=%0d drac0=%0d drac0_ideal=%.2f drac0_diff=%.2f drac1=%0d drac1_ideal=%.2f drac1_diff=%.2f",
			clk_name, pal, seed, n_err, n_chk, n_exact, n_rd_tc, age_plain_max,
			n_rd_part, age_part_max, lat_start, lat_stop, rate_win, n_merge, n_merge_inc, n_pause_en,
			n_never, n_launch, n_queued, n_qlaunch, flight_max / 1000000, n_wsamp, w_gap_min / 1000, n_hsamp, h_gap_min / 1000,
			n_rst, n_rst_wfl, n_rst_busy, n_rst_q, n_rst_sfl, n_sys_first, n_arm_first,
			drac_r[0], drac_ideal[0], real'(drac_r[0]) - drac_ideal[0],
			drac_r[1], drac_ideal[1], real'(drac_r[1]) - drac_ideal[1]);
		$finish;
	end
endmodule

`default_nettype wire
