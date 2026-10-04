//------------------------------------------------------------------------------
// Behavioural model of one of the Pocket's two PSRAM chips (cram0 or cram1:
// AS1C8M16PL-70, two dies of 4M x 16, selected by ce0_n and ce1_n), in the
// asynchronous mode agg23's psram.sv (src/fpga/pocket_utils/) drives it in.
// Simulation only (docs/BUPCHIP_CORE.md, implementation step 4).
//
// The pins are core_top.v's cram0_* (and psram.sv's port names):
//   A[21:16] on cram_a; A[15:0] multiplexed on cram_dq. The address is
//   latched on the rising edge of cram_adv_n while one die's CE# is low.
//   Read:  OE# low, WE# high. The die drives the byte lanes that UB#/LB#
//          enable, from OE# low until OE#/CE# high (or WE# low).
//   Write: WE# low. The lanes UB#/LB# enable are written when the write
//          ends: WE# or CE# high, whichever is first. DQ, UB# and LB# are
//          taken as they were just before that edge (hold time 0).
//   cram_clk must stay 0 and cram_cre low (no synchronous mode, no
//   configuration register); cram_wait is driven 0.
//
// Timing checks, each an $error (counted in n_viol and viol_n[]; MAX_MSGS
// messages per check are printed). The values are the datasheet values
// psram.sv's header lists, in ns:
//   T_VP   5   ADV# low pulse                          (psram.sv t_vp)
//   T_AVS  5   address stable before ADV# high         (t_avs)
//   T_AVH  2   address held after ADV# high            (t_avh)
//   T_CVS  7   CE# low before ADV# high                (t_cvs)
//   T_DW  20   write data stable before the write ends (t_dw)
//   T_WP  45   WE# and CE# both low, start to end      (t_wp)
//   T_AW  70   ADV# low to the end of a write          (MIN_WRITE_TIME_FROM_ADV)
//   T_AADV 70  ADV# low to valid read data             (MAX_ACCESS_TIME_FROM_ADV)
//   T_OE  20   OE# low to valid read data              (MAX_OE_TO_VALID_DATA,
//                                                       commented out there)
// The two read times are checked where the read ends (OE# or CE# high):
// the model assumes, as psram.sv does, that the controller samples DQ on
// the edge that ends the read. psram.sv's two guessed values (8 ns data
// and 3 ns OE# after the address is released) are not datasheet values;
// the bus turnaround is checked structurally instead (BUS below).
// T_CEM (4,000 ns, CE# low at most) is not in psram.sv's list: it is the
// CellularRAM family's refresh limit, unverified for this part (risk 3 in
// docs/BUPCHIP_CORE.md); 0 turns it off.
// Further checks: CE_BOTH (both dies selected), CTRL_X (X/Z on a control
// pin while a die is selected; four-state simulators only), CRE, CLK,
// ADDR_X (X/Z in the latched address), DATA_X (X/Z on a written lane),
// NO_ADDR (a read or write with no address latched in this CE# cycle; OE#
// must fall after the ADV# pulse, as psram.sv does), BUS (four-state
// simulators only: DQ not released by the host when the die's outputs turn
// on, or a host driving DQ while the die drives it).
//
// Read data. While the die drives DQ before the data is valid, it drives X
// (under Verilator, which has no X: the bit inverse of the data). Data is
// valid at max(ADV# fall + T_AADV, OE# fall + T_OE) plus the stress knob:
// EXTRA_NS plus a random 0..JITTER_NS for each read (xorshift32 from SEED,
// so a run repeats). Plusargs override them: +psram_extra_ps=N,
// +psram_jitter_ps=N, +psram_seed=N. A read that ends after the datasheet
// time but before the stressed time is not a violation; it returns the
// garbage and counts in late_reads, and the testbench's data check fails.
//
// Contents. Byte b of a die (the asset layout: halfword b >> 1, the low
// byte when b is even) is "unwritten" until a write or the backdoor sets
// it. Unwritten bytes read as X in four-state simulators (UNWRITTEN_X = 1),
// and as a fixed pattern of the address (unwritten_pattern()) with
// UNWRITTEN_X = 0 or under Verilator; reads that touch one count in
// unwritten_reads.
//
// Under Verilator the first $error stops the simulation (its default
// +verilator+error+limit is 1), which suits a system test; pass
// +verilator+error+limit+N to count past it. The model needs --timing.
//
// Backdoor (call hierarchically; die 0 or 1, addr = halfword address):
//   bd_write(die, addr, data, be)   be[1] = high byte, be[0] = low byte
//   bd_read(die, addr)              unwritten bytes as a read returns them
//   bd_written(die, addr)           {high, low} written
//   bd_clear()                      everything unwritten (8M halfwords: slow)
//   n_written                       halfwords with a byte written (a counter)
//   bd_load_bin(file, die, byte_addr, n)            bytes of a binary file
//   bd_dump_bin(file, die, byte_addr, nbytes)       unwritten bytes as 0
//   bd_compare_bin(file, die, byte_addr, n, bad, first_bad)
//                                   n = file bytes; a byte differs if it is
//                                   unwritten or not equal; first_bad = its
//                                   file offset, or -1
//   report()                        counts, violations, smallest margins
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module psram_model #(
	parameter real T_VP      = 5.0,
	parameter real T_AVS     = 5.0,
	parameter real T_AVH     = 2.0,
	parameter real T_CVS     = 7.0,
	parameter real T_DW      = 20.0,
	parameter real T_WP      = 45.0,
	parameter real T_AW      = 70.0,
	parameter real T_AADV    = 70.0,
	parameter real T_OE      = 20.0,
	parameter real T_CEM     = 4000.0,
	parameter real EXTRA_NS  = 0.0,
	parameter real JITTER_NS = 0.0,
	parameter int  SEED      = 1,
	parameter bit  UNWRITTEN_X = 1,
	parameter int  MAX_MSGS  = 10
) (
	input  wire [21:16] cram_a,
	inout  wire  [15:0] cram_dq,
	output wire         cram_wait,
	input  wire         cram_clk,
	input  wire         cram_adv_n,
	input  wire         cram_cre,
	input  wire         cram_ce0_n,
	input  wire         cram_ce1_n,
	input  wire         cram_oe_n,
	input  wire         cram_we_n,
	input  wire         cram_ub_n,
	input  wire         cram_lb_n
);
	// Check codes
	localparam int V_CE_BOTH = 0, V_CTRL_X = 1, V_CRE = 2, V_CLK = 3, V_T_VP = 4,
		V_T_AVS = 5, V_T_AVH = 6, V_T_CVS = 7, V_ADDR_X = 8, V_NO_ADDR = 9,
		V_T_WP = 10, V_T_AW = 11, V_T_DW = 12, V_DATA_X = 13, V_T_AADV = 14,
		V_T_OE = 15, V_BUS = 16, V_T_CEM = 17, NV = 18;
	localparam longint NEVER = 64'sh3fff_ffff_ffff_ffff;

	function automatic string vname(input int c);
		case (c)
			V_CE_BOTH: return "CE_BOTH";  V_CTRL_X: return "CTRL_X";
			V_CRE:     return "CRE";      V_CLK:    return "CLK";
			V_T_VP:    return "T_VP";     V_T_AVS:  return "T_AVS";
			V_T_AVH:   return "T_AVH";    V_T_CVS:  return "T_CVS";
			V_ADDR_X:  return "ADDR_X";   V_NO_ADDR: return "NO_ADDR";
			V_T_WP:    return "T_WP";     V_T_AW:   return "T_AW";
			V_T_DW:    return "T_DW";     V_DATA_X: return "DATA_X";
			V_T_AADV:  return "T_AADV";   V_T_OE:   return "T_OE";
			V_BUS:     return "BUS";      V_T_CEM:  return "T_CEM";
			default:   return "?";
		endcase
	endfunction

	// Limits in ps
	longint p_vp = longint'($rtoi(T_VP * 1000.0 + 0.5));
	longint p_avs = longint'($rtoi(T_AVS * 1000.0 + 0.5));
	longint p_avh = longint'($rtoi(T_AVH * 1000.0 + 0.5));
	longint p_cvs = longint'($rtoi(T_CVS * 1000.0 + 0.5));
	longint p_dw = longint'($rtoi(T_DW * 1000.0 + 0.5));
	longint p_wp = longint'($rtoi(T_WP * 1000.0 + 0.5));
	longint p_aw = longint'($rtoi(T_AW * 1000.0 + 0.5));
	longint p_aadv = longint'($rtoi(T_AADV * 1000.0 + 0.5));
	longint p_oe = longint'($rtoi(T_OE * 1000.0 + 0.5));
	longint p_cem = longint'($rtoi(T_CEM * 1000.0 + 0.5));
	longint p_extra = longint'($rtoi(EXTRA_NS * 1000.0 + 0.5));
	longint p_jitter = longint'($rtoi(JITTER_NS * 1000.0 + 0.5));
	longint p_step = (T_OE >= 0.001) ? longint'($rtoi(T_OE * 1000.0 + 0.5)) : 64'd1;
	bit [31:0] rng = (SEED == 0) ? 32'd1 : SEED;

	initial begin
		int v;
		if ($value$plusargs("psram_extra_ps=%d", v)) p_extra = v;
		if ($value$plusargs("psram_jitter_ps=%d", v)) p_jitter = v;
		if ($value$plusargs("psram_seed=%d", v)) rng = (v == 0) ? 32'd1 : v;
	end

	// Storage: {die, halfword address}; wmap = {high, low} byte written
	bit [15:0] mem [0:(1 << 23) - 1];
	bit  [1:0] wmap [0:(1 << 23) - 1];

	// Counters (read them hierarchically, or call report())
	int unsigned n_viol = 0, viol_n [0:NV-1];
	int unsigned n_rd = 0, n_wr = 0, n_rd_die [0:1], n_wr_die [0:1];
	int unsigned late_reads = 0, unwritten_reads = 0, empty_writes = 0;
	int unsigned n_written = 0;	// halfwords with at least one byte written
	longint min_vp = NEVER, min_avs = NEVER, min_avh = NEVER, min_cvs = NEVER;
	longint min_wp = NEVER, min_aw = NEVER, min_dw = NEVER, min_rd_adv = NEVER, min_rd_oe = NEVER;
	longint max_ce = 0;
	initial begin
		for (int i = 0; i < NV; i++) viol_n[i] = 0;
		n_rd_die[0] = 0; n_rd_die[1] = 0; n_wr_die[0] = 0; n_wr_die[1] = 0;
	end

	function automatic void viol(input int c, input string msg);
		viol_n[c]++;
		n_viol++;
		if (viol_n[c] <= MAX_MSGS)
			$error("psram_model %m: %s: %s (at %0d ps)", vname(c), msg, $time);
	endfunction

	function automatic real ns(input longint ps);
		return ps / 1000.0;
	endfunction

	function automatic string ns_s(input longint ps);
		string r;
		if (ps == NEVER) r = "-";
		else r = $sformatf("%.3f", ps / 1000.0);
		return r;
	endfunction

	function automatic logic [15:0] unwritten_pattern(input int die, input int unsigned addr);
		return addr[15:0] ^ {addr[21:16], die[0], 9'h0A5};
	endfunction

	function automatic logic [15:0] word_out(input int die, input int unsigned addr);
		bit [22:0] i;
		logic [15:0] w;
		i = {die[0], addr[21:0]};
		w = mem[i];
		if (wmap[i] != 2'b11) begin
`ifdef VERILATOR
			w = unwritten_pattern(die, addr);
`else
			if (!UNWRITTEN_X) w = unwritten_pattern(die, addr);
			else begin
				if (!wmap[i][1]) w[15:8] = 8'hxx;
				if (!wmap[i][0]) w[7:0] = 8'hxx;
			end
`endif
			if (wmap[i][1]) w[15:8] = mem[i][15:8];
			if (wmap[i][0]) w[7:0] = mem[i][7:0];
		end
		return w;
	endfunction

	// Pin trackers: the value last seen (_c), when it took effect (_tc), and
	// the value before the current time step (_p, from _tp). pre/since give
	// a pin as it was just before now.
	logic [1:0] sel_c = 2'bxx;	// {~ce1_n, ~ce0_n}
	logic adv_c = 1'bx, oe_c = 1'bx, we_c = 1'bx, ub_c = 1'bx, lb_c = 1'bx, ub_p, lb_p;
	logic [21:16] a_c = 'x, a_p;
	logic [7:0] dqh_c = 'x, dql_c = 'x, dqh_p, dql_p;
	longint a_tc = -1, a_tp = -1, dqh_tc = -1, dqh_tp = -1, dql_tc = -1, dql_tp = -1;
	longint ub_tc = -1, ub_tp = -1, lb_tc = -1, lb_tp = -1;

`define PSM_TRK(SIG, C, P, TC, TP) \
	if ((SIG) !== C) begin \
		if (TC != now) begin P = C; TP = TC; end \
		C = (SIG); TC = now; \
	end
`define PSM_PRE(C, P, TC) ((TC == now) ? P : C)
`define PSM_SINCE(TC, TP) ((TC == now) ? TP : TC)
// Any X or Z bit (iverilog 12's $isunknown is wrong on concatenations of nets)
`define PSM_UNK(V) ((^(V)) === 1'bx)

	// Cycle state
	bit ce_act = 0, ce_die = 0, wr_act = 0, out_act = 0, addr_ok = 0, lat_die = 0, avh_watch = 0;
	logic [21:0] lat_addr;
	longint t_ce = 0, t_adv_fall = 0, t_lat_adv_fall = 0, t_adv_rise = 0, t_wr = 0, t_out = 0;

	// Read output
	logic [15:0] rd_word = 0;
	bit rd_valid = 0;
	longint rd_valid_t = 0;
	logic [15:0] drv;
`ifdef VERILATOR
	assign drv = rd_valid ? rd_word : ~rd_word;
`else
	assign drv = rd_valid ? rd_word : 16'hxxxx;
`endif
	assign cram_dq[15:8] = (out_act && cram_ub_n === 1'b0) ? drv[15:8] : 8'hzz;
	assign cram_dq[7:0]  = (out_act && cram_lb_n === 1'b0) ? drv[7:0]  : 8'hzz;
	assign cram_wait = 1'b0;

	function automatic longint next_jitter();
		if (p_jitter <= 0) return 0;
		rng = rng ^ (rng << 13);
		rng = rng ^ (rng >> 17);
		rng = rng ^ (rng << 5);
		return longint'(rng % (p_jitter + 1));
	endfunction

	// Raise rd_valid at rd_valid_t. The sleep is cut into steps of at most
	// T_OE: any read's data comes at least T_OE after it starts, so a read
	// that starts during a step (after one that ended early) is never missed.
	// (Verilator runs "x <= #d v" as a blocking delay, so no NBA scheduling.)
	always begin
		wait (out_act && !rd_valid);
		if ($time >= rd_valid_t) rd_valid = 1;
		else if (rd_valid_t - $time < p_step) #(rd_valid_t - $time);
		else #(p_step);
	end

	function automatic void end_read(input longint now);
		longint d_adv, d_oe;
		bit bad;
		d_adv = now - t_lat_adv_fall;
		d_oe = now - t_out;
		bad = 0;
		if (addr_ok) begin
			if (d_adv < min_rd_adv) min_rd_adv = d_adv;
			if (d_oe < min_rd_oe) min_rd_oe = d_oe;
			if (d_adv < p_aadv) begin
				bad = 1;
				viol(V_T_AADV, $sformatf("read ended %.3f ns after ADV# fell (data valid after %.3f)", ns(d_adv), ns(p_aadv)));
			end
			if (d_oe < p_oe) begin
				bad = 1;
				viol(V_T_OE, $sformatf("read ended %.3f ns after OE# fell (data valid after %.3f)", ns(d_oe), ns(p_oe)));
			end
			if (!rd_valid && !bad) late_reads++;
		end
		n_rd++;
		n_rd_die[ce_die]++;
		out_act = 0;
		rd_valid = 0;
	endfunction

	function automatic void end_write(input longint now);
		logic ub, lb;
		logic [7:0] dh, dl;
		longint d;
		bit [22:0] i;
		ub = `PSM_PRE(ub_c, ub_p, ub_tc);
		lb = `PSM_PRE(lb_c, lb_p, lb_tc);
		dh = `PSM_PRE(dqh_c, dqh_p, dqh_tc);
		dl = `PSM_PRE(dql_c, dql_p, dql_tc);
		wr_act = 0;
		if (!addr_ok) begin
			viol(V_NO_ADDR, "write with no address latched in this CE# cycle");
			return;
		end
		d = now - t_wr;
		if (d < min_wp) min_wp = d;
		if (d < p_wp) viol(V_T_WP, $sformatf("WE# and CE# low for %.3f ns (min %.3f)", ns(d), ns(p_wp)));
		d = now - t_lat_adv_fall;
		if (d < min_aw) min_aw = d;
		if (d < p_aw) viol(V_T_AW, $sformatf("write ended %.3f ns after ADV# fell (min %.3f)", ns(d), ns(p_aw)));
		if (ub === 1'bx || ub === 1'bz || lb === 1'bx || lb === 1'bz)
			viol(V_CTRL_X, "UB#/LB# unknown at the end of a write");
		i = {lat_die, lat_addr};
		if (wmap[i] == 0 && (ub === 1'b0 || lb === 1'b0)) n_written++;
		if (ub === 1'b0) begin
			d = now - `PSM_SINCE(dqh_tc, dqh_tp);
			if (d < min_dw) min_dw = d;
			if (d < p_dw) viol(V_T_DW, $sformatf("DQ[15:8] stable %.3f ns before the write ended (min %.3f)", ns(d), ns(p_dw)));
			if (`PSM_UNK(dh)) viol(V_DATA_X, $sformatf("DQ[15:8] = %b written", dh));
			mem[i][15:8] = dh;
			wmap[i][1] = 1;
		end
		if (lb === 1'b0) begin
			d = now - `PSM_SINCE(dql_tc, dql_tp);
			if (d < min_dw) min_dw = d;
			if (d < p_dw) viol(V_T_DW, $sformatf("DQ[7:0] stable %.3f ns before the write ended (min %.3f)", ns(d), ns(p_dw)));
			if (`PSM_UNK(dl)) viol(V_DATA_X, $sformatf("DQ[7:0] = %b written", dl));
			mem[i][7:0] = dl;
			wmap[i][0] = 1;
		end
		if (ub !== 1'b0 && lb !== 1'b0) empty_writes++;
		n_wr++;
		n_wr_die[lat_die]++;
	endfunction

	function automatic void end_cycle(input longint now);
		longint d;
		d = now - t_ce;
		if (d > max_ce) max_ce = d;
		if (p_cem > 0 && d > p_cem)
			viol(V_T_CEM, $sformatf("CE# low for %.3f ns (max %.3f)", ns(d), ns(p_cem)));
		ce_act = 0;
		addr_ok = 0;
	endfunction

	function automatic void latch(input longint now);
		logic [21:0] a;
		longint d, s;
		a = {`PSM_PRE(a_c, a_p, a_tc), `PSM_PRE(dqh_c, dqh_p, dqh_tc), `PSM_PRE(dql_c, dql_p, dql_tc)};
		d = now - t_adv_fall;
		if (d < min_vp) min_vp = d;
		if (d < p_vp) viol(V_T_VP, $sformatf("ADV# low for %.3f ns (min %.3f)", ns(d), ns(p_vp)));
		s = `PSM_SINCE(a_tc, a_tp);
		if (`PSM_SINCE(dqh_tc, dqh_tp) > s) s = `PSM_SINCE(dqh_tc, dqh_tp);
		if (`PSM_SINCE(dql_tc, dql_tp) > s) s = `PSM_SINCE(dql_tc, dql_tp);
		d = now - s;
		if (d < min_avs) min_avs = d;
		if (d < p_avs) viol(V_T_AVS, $sformatf("address stable %.3f ns before ADV# rose (min %.3f)", ns(d), ns(p_avs)));
		d = now - t_ce;
		if (d < min_cvs) min_cvs = d;
		if (d < p_cvs) viol(V_T_CVS, $sformatf("CE# low %.3f ns before ADV# rose (min %.3f)", ns(d), ns(p_cvs)));
		if (`PSM_UNK(a)) viol(V_ADDR_X, $sformatf("address %b latched", a));
		// An address pin that changed in this very time step breaks t_avh
		if (a_tc == now || dqh_tc == now || dql_tc == now) begin
			min_avh = 0;
			if (p_avh > 0) viol(V_T_AVH, "address changed as ADV# rose (held 0 ns)");
			avh_watch = 0;
		end else
			avh_watch = 1;
		lat_addr = a;
		lat_die = ce_die;
		addr_ok = 1;
		t_lat_adv_fall = t_adv_fall;
		t_adv_rise = now;
	endfunction

	function automatic void start_read(input longint now);
		logic [7:0] dh, dl;
		t_out = now;
		rd_valid = 0;
		out_act = 1;
		if (!addr_ok) begin
			viol(V_NO_ADDR, "read (OE# low) with no address latched in this CE# cycle");
			rd_word = 'x;
			rd_valid_t = NEVER;
			return;
		end
		rd_word = word_out(lat_die, lat_addr);
		if (wmap[{lat_die, lat_addr}] != 2'b11) unwritten_reads++;
		rd_valid_t = t_lat_adv_fall + p_aadv;
		if (now + p_oe > rd_valid_t) rd_valid_t = now + p_oe;
		rd_valid_t = rd_valid_t + p_extra + next_jitter();
`ifndef VERILATOR
		// The host must have released DQ before the die drives it
		dh = `PSM_PRE(dqh_c, dqh_p, dqh_tc);
		dl = `PSM_PRE(dql_c, dql_p, dql_tc);
		if ((cram_ub_n === 1'b0 && dh !== 8'hzz) || (cram_lb_n === 1'b0 && dl !== 8'hzz))
			viol(V_BUS, $sformatf("DQ = %b_%b, not released, when the die's outputs turned on", dh, dl));
`endif
	endfunction

	// Every pin change
	always @(cram_a or cram_dq or cram_clk or cram_adv_n or cram_cre or cram_ce0_n or
			cram_ce1_n or cram_oe_n or cram_we_n or cram_ub_n or cram_lb_n) begin : pins
		longint now;
		logic [1:0] sel;
		bit adv_rise, ce_on, die, wr_on, out_on;
		now = $time;
		sel = {~cram_ce1_n, ~cram_ce0_n};

		adv_rise = (adv_c === 1'b0) && (cram_adv_n === 1'b1);
		if (adv_c !== 1'b0 && cram_adv_n === 1'b0) t_adv_fall = now;

		// t_avh: the first address change after a latch
		if (avh_watch && (cram_a !== a_c || cram_dq[15:8] !== dqh_c || cram_dq[7:0] !== dql_c)) begin
			if (now - t_adv_rise < min_avh) min_avh = now - t_adv_rise;
			if (now - t_adv_rise < p_avh)
				viol(V_T_AVH, $sformatf("address changed %.3f ns after ADV# rose (min %.3f)", ns(now - t_adv_rise), ns(p_avh)));
			avh_watch = 0;
		end

		`PSM_TRK(cram_a, a_c, a_p, a_tc, a_tp)
		`PSM_TRK(cram_dq[15:8], dqh_c, dqh_p, dqh_tc, dqh_tp)
		`PSM_TRK(cram_dq[7:0], dql_c, dql_p, dql_tc, dql_tp)
		`PSM_TRK(cram_ub_n, ub_c, ub_p, ub_tc, ub_tp)
		`PSM_TRK(cram_lb_n, lb_c, lb_p, lb_tc, lb_tp)
		adv_c = cram_adv_n;
		oe_c = cram_oe_n;
		we_c = cram_we_n;

		if (sel === 2'b11) viol(V_CE_BOTH, "ce0_n and ce1_n both low");
		if (now > 0 && `PSM_UNK(sel)) viol(V_CTRL_X, $sformatf("ce1_n, ce0_n = %b", ~sel));
		sel_c = sel;
		ce_on = (sel === 2'b01) || (sel === 2'b10);
		die = (sel === 2'b10);
		wr_on = ce_on && cram_we_n === 1'b0;
		out_on = ce_on && cram_we_n === 1'b1 && cram_oe_n === 1'b0;

		// Ends, then starts (a die change ends one cycle and starts another)
		if (out_act && !(out_on && die == ce_die)) end_read(now);
		if (wr_act && !(wr_on && die == ce_die)) end_write(now);
		if (ce_act && !(ce_on && die == ce_die)) end_cycle(now);
		if (!ce_act && ce_on) begin
			ce_act = 1;
			ce_die = die;
			t_ce = now;
			addr_ok = 0;
		end
		if (adv_rise && ce_act) latch(now);
		if (!wr_act && wr_on) begin
			wr_act = 1;
			t_wr = now;
		end
		if (!out_act && out_on) start_read(now);

		if (ce_act) begin
			if (`PSM_UNK({cram_adv_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n}))
				viol(V_CTRL_X, $sformatf("adv_n oe_n we_n ub_n lb_n = %b", {cram_adv_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n}));
			if (cram_cre !== 1'b0) viol(V_CRE, "cram_cre not low while a die is selected");
		end
		if (now > 0 && cram_clk !== 1'b0) viol(V_CLK, "cram_clk not low (synchronous mode is not modelled)");
	end

`ifndef VERILATOR
	// A host driving DQ while the die drives it
	always @(cram_dq) begin
		if (out_act && ((cram_ub_n === 1'b0 && cram_dq[15:8] !== drv[15:8]) ||
				(cram_lb_n === 1'b0 && cram_dq[7:0] !== drv[7:0])))
			viol(V_BUS, $sformatf("DQ = %h while the die drives %h", cram_dq, drv));
	end
`endif

	// ---- Backdoor ----
	function automatic void bd_write(input int die, input int unsigned addr, input logic [15:0] d, input logic [1:0] be);
		bit [22:0] i;
		i = {die[0], addr[21:0]};
		if (wmap[i] == 0 && be != 0) n_written++;
		if (be[1]) begin mem[i][15:8] = d[15:8]; wmap[i][1] = 1; end
		if (be[0]) begin mem[i][7:0] = d[7:0]; wmap[i][0] = 1; end
	endfunction

	function automatic logic [15:0] bd_read(input int die, input int unsigned addr);
		return word_out(die, addr);
	endfunction

	function automatic logic [1:0] bd_written(input int die, input int unsigned addr);
		return wmap[{die[0], addr[21:0]}];
	endfunction

	function automatic void bd_clear();
		for (int i = 0; i < (1 << 23); i++) begin
			mem[i] = 0;
			wmap[i] = 0;
		end
		n_written = 0;
	endfunction

	task automatic bd_load_bin(input string file, input int die, input int unsigned byte_addr, output int unsigned n);
		int fd, c;
		int unsigned b;
		n = 0;
		fd = $fopen(file, "rb");
		if (fd == 0) $error("psram_model %m: cannot open %s", file);
		else begin
			c = $fgetc(fd);
			while (c != -1) begin
				b = byte_addr + n;
				bd_write(die, b >> 1, {c[7:0], c[7:0]}, b[0] ? 2'b10 : 2'b01);
				n++;
				c = $fgetc(fd);
			end
			$fclose(fd);
		end
	endtask

	task automatic bd_dump_bin(input string file, input int die, input int unsigned byte_addr, input int unsigned nbytes);
		int fd;
		int unsigned b;
		bit [22:0] i;
		logic [7:0] v;
		fd = $fopen(file, "wb");
		if (fd == 0) $error("psram_model %m: cannot write %s", file);
		else begin
			for (int unsigned k = 0; k < nbytes; k++) begin
				b = byte_addr + k;
				i = {die[0], b[22:1]};
				v = b[0] ? mem[i][15:8] : mem[i][7:0];
				if (!wmap[i][b[0]]) v = 0;
				$fwrite(fd, "%c", v);
			end
			$fclose(fd);
		end
	endtask

	task automatic bd_compare_bin(input string file, input int die, input int unsigned byte_addr,
			output int unsigned n, output int unsigned bad, output int first_bad);
		int fd, c;
		int unsigned b;
		bit [22:0] i;
		n = 0;
		bad = 0;
		first_bad = -1;
		fd = $fopen(file, "rb");
		if (fd == 0) begin
			$error("psram_model %m: cannot open %s", file);
			bad = 1;
		end else begin
			c = $fgetc(fd);
			while (c != -1) begin
				b = byte_addr + n;
				i = {die[0], b[22:1]};
				if (!wmap[i][b[0]] || (b[0] ? mem[i][15:8] : mem[i][7:0]) != c[7:0]) begin
					if (bad == 0) first_bad = n;
					bad++;
				end
				n++;
				c = $fgetc(fd);
			end
			$fclose(fd);
		end
	endtask

	function automatic void report();
		int c;
		$display("psram_model %m: %0d reads (die 0 %0d, die 1 %0d), %0d writes (die 0 %0d, die 1 %0d; %0d with no byte enabled), %0d violations, %0d late reads (stress), %0d reads of unwritten bytes",
			n_rd, n_rd_die[0], n_rd_die[1], n_wr, n_wr_die[0], n_wr_die[1], empty_writes,
			n_viol, late_reads, unwritten_reads);
		$display("psram_model %m: smallest ns: t_vp %s, t_avs %s, t_avh %s, t_cvs %s, t_wp %s, t_aw %s, t_dw %s, read after ADV# %s, after OE# %s; longest CE# low %s",
			ns_s(min_vp), ns_s(min_avs), ns_s(min_avh), ns_s(min_cvs), ns_s(min_wp), ns_s(min_aw), ns_s(min_dw),
			ns_s(min_rd_adv), ns_s(min_rd_oe), ns_s(max_ce));
		$display("psram_model %m: stress: extra %.3f ns, jitter 0..%.3f ns", ns(p_extra), ns(p_jitter));
		for (c = 0; c < NV; c++)
			if (viol_n[c] != 0) $display("psram_model %m: %0d x %s", viol_n[c], vname(c));
	endfunction

`undef PSM_TRK
`undef PSM_PRE
`undef PSM_SINCE
`undef PSM_UNK
endmodule
