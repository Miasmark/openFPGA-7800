//------------------------------------------------------------------------------
// tb_fe_call: daria_fe_call's unit bench (docs/daria_fe/design.md 12.3, 6;
// lane C: docs/daria_fe/lanes/C_call_copy.md).
//
// The module with the real daria_call (clk_arm side of the call port) on
// daria_mem's state RAM, and a scripted stand-in for bup_cpu's call
// interface (parked, call_go/clr_e/clr_wd/clr_pc, ro_*, returned). clk_sys
// and clk_arm are on DARIA's PLL lattice (48 and 18 VCO steps, shared edges
// every third clk_sys; +arm_div=5: mode A's 5x clk_arm). A fe_phase_gen
// stream carries the 6507 bus: reads, CALLFN writes (single, and the RMW
// pairs FE->FF, FF->FE, FD->FE, FF->00), other writes. The stall is the
// DUT's arm_call_busy (hardware, mode B), or with +stall_up=1 the bench's
// model of upstream's busy (mode A).
//
// Models (all bench-side, written from the design and upstream's RTL):
//   ref   design 6.1's FSM at the event level: the state, busy, pend2, every
//         state RAM request and every strobe expected in each clock;
//   X     the bench's own two flops on ret_tog: X is the edge at which the
//         change is first sampled (glue.md 7.3), independent of the DUT;
//   U     upstream: arm_mapper_audio's counters/frequencies with a tick, the
//         seeds and the merge at M = X+1 (AUD:191-223), the controller's
//         call_pending/accept/busy (arm_mapper_controller.sv:149-177);
//   D     u_audio's side of the contract (design 5.6): the ring (cp_cap,
//         cp_rot, cp_shin + stb_q, cp_cmp -> take), cp_apply, the tick
//         deferral in mwin and the late add, and the hook merge.
// Ticks are placed by a sweep at L-2..L+2 of each fresh call and at
// M-2..M_fe+3 of each return (design 11.1 risk 5).
//
// Checks (counters in the summary; any error fails the run):
//   12.3 item 1  F0-F7 words and edges (C+1..C+8 when granted), the flip
//                edge, FLIP waiting for cpu_ready, the payload against U's
//                at the accept, the stand-in's launch registers
//   item 2       F8 in the clock the change is first seen, F9-FD in the
//                next five, cp_shin/cp_cmp/cp_apply/mwin at their edges,
//                D == U at every edge outside [M, M_fe]
//   item 3       arm_call_busy falls only at, and at the first, edge with
//                REL & rel_ok & cpu_ready
//   item 4       pend2 (both schemes, hook), pend_up against U's
//                call_pending, the second call's payload
//   item 5       cart_reset aimed at every state: IDLE, busy 0, pend2 0,
//                call_tog kept, ret_seen re-synced; a late ret_tog
//                (a stand-in that keeps running through the reset) gives
//                exactly one ev_ret_unasked and is ignored
//   item 6       hook epochs (+hook=1 or random): HKW, no reads, no mwin
//
// Plusargs: +seed +clocks +epoch +arm_div (18|5) +arm_ofs (VCO steps, or
// ps with 5) +stall_up +gap (filler reads after a CALLFN instruction) +only
// (0 all, 1 DPC+, 2 CDF) +hook (-1 random per epoch) +ready (-1 random,
// 0 hardware: parked & img_ready, 1 mode A: steady) +k_cs +k_rst +k_drop
// +fault_k +k_short (per mille of calls that run 0-23 clk_arm) +max_err
// +trace=N (print N clocks) and the fe_phase_gen ones.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ps/1ps
`default_nettype none

`include "phase_gen.svh"

module tb_fe_call;
	localparam int VCO = 1455;               // ps: one step of DARIA's PLL (clk_sys 48, clk_arm 18)

	// ---- knobs -------------------------------------------------------------------------
	int unsigned seed    = 1;
	longint      n_clk   = 1_000_000;
	int          epoch   = 100_000;
	int          arm_div = 18;
	int          arm_ofs = 0;
	int          stall_up = 0;
	int          gap     = 3;
	int          only    = 0;
	int          hook_m  = -1;
	int          ready_m = -1;
	int          k_cs    = 150;              // per mille per clock: the core's S use (DPC+)
	int          k_rst   = 80;               // per mille per fresh call: a reset aimed at a state
	int          k_drop  = 3;                // per mille per clock: the ready source drops
	int          k_dep   = 4;                // per mille per quiet clock: counters/frequencies deposited
	int          fault_k = 250;              // per mille of resets aimed at RUN that keep the CPU running
	int          k_short = 150;              // per mille of calls that run 0-23 clk_arm (X close to an RMW's 2nd write)
	int          max_err = 20;
	longint      trace   = 0;
	int          hs_sys, hs_arm, ofs_arm;

	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("clocks=%d", n_clk));
		void'($value$plusargs("epoch=%d", epoch));
		void'($value$plusargs("arm_div=%d", arm_div));
		void'($value$plusargs("arm_ofs=%d", arm_ofs));
		void'($value$plusargs("stall_up=%d", stall_up));
		void'($value$plusargs("gap=%d", gap));
		void'($value$plusargs("only=%d", only));
		void'($value$plusargs("hook=%d", hook_m));
		void'($value$plusargs("ready=%d", ready_m));
		void'($value$plusargs("k_cs=%d", k_cs));
		void'($value$plusargs("k_rst=%d", k_rst));
		void'($value$plusargs("k_drop=%d", k_drop));
		void'($value$plusargs("k_dep=%d", k_dep));
		void'($value$plusargs("fault_k=%d", fault_k));
		void'($value$plusargs("k_short=%d", k_short));
		void'($value$plusargs("max_err=%d", max_err));
		void'($value$plusargs("trace=%d", trace));
		hs_sys  = 24 * VCO;
		hs_arm  = (arm_div == 5) ? 6984 : 9 * VCO;
		ofs_arm = (arm_div == 5) ? arm_ofs : arm_ofs * VCO;
		$display("tb_fe_call: seed %0d clocks %0d epoch %0d arm_div %0d arm_ofs %0d stall_up %0d gap %0d only %0d hook %0d ready %0d",
			seed, n_clk, epoch, arm_div, arm_ofs, stall_up, gap, only, hook_m, ready_m);
	end

	// ---- clocks ------------------------------------------------------------------------
	logic clk_sys = 1'b0, clk_arm = 1'b0;
	initial begin
		#(100000);
		forever begin clk_sys = 1'b1; #(hs_sys); clk_sys = 1'b0; #(hs_sys); end
	end
	initial begin
		#(100000 + ofs_arm);
		forever begin clk_arm = 1'b1; #(hs_arm); clk_arm = 1'b0; #(hs_arm); end
	end

	// ---- random streams (xorshift32), one per clock domain --------------------------------
	logic [31:0] rs = 32'h1, ra = 32'h2;
	initial begin
		rs = 32'h9E37_79B9 ^ (seed * 32'h85EB_CA6B);
		ra = 32'h7F4A_7C15 ^ (seed * 32'hC2B2_AE35);
		if (rs == 0) rs = 1;
		if (ra == 0) ra = 1;
	end
	function automatic logic [31:0] xs(input logic [31:0] s);
		logic [31:0] x;
		x = s;
		x = x ^ (x << 13);
		x = x ^ (x >> 17);
		x = x ^ (x << 5);
		return x;
	endfunction
	function automatic int unsigned rnd(input int unsigned n);
		rs = xs(rs);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	function automatic logic [31:0] rnd32();
		rs = xs(rs);
		return rs;
	endfunction
	function automatic int unsigned rnda(input int unsigned n);
		ra = xs(ra);
		return (n == 0) ? 0 : (ra % n);
	endfunction
	function automatic logic [31:0] rnda32();
		ra = xs(ra);
		return ra;
	endfunction

	// ---- errors ---------------------------------------------------------------------------
	longint e = 0;                           // clk_sys edges so far
	int     nerr = 0;
	int     err_c [string];
	task automatic fail(input string what, input string msg);
		nerr++;
		if (err_c.exists(what)) err_c[what]++; else err_c[what] = 1;
		if (nerr <= max_err) $display("ERROR %s @%0d: %s", what, e, msg);
	endtask
	longint cnt [string];
	function automatic void inc(input string k);
		if (cnt.exists(k)) cnt[k]++; else cnt[k] = 1;
	endfunction

	// ---- epoch configuration ----------------------------------------------------------------
	logic        is_dpc = 1'b0, is_cdf = 1'b1, jplus = 1'b0, hk_en = 1'b0;
	logic [31:0] cdfj_entry = 32'h0, cdfj_stack = 32'h0;
	int          ready_a = 0;               // this epoch: 1 = mode A's cpu_ready
	logic [11:0] cf_lo = 12'hFF3;           // CALLFN's address (low 12 bits)

	// ---- reset ---------------------------------------------------------------------------------
	logic rst_r = 1'b1;
	logic rst_hit;                           // comb: the aimed state is reached (one-clock states included)
	wire  cart_reset = rst_r | rst_hit;
	int   rst_left = 40;
	logic fault_pick = 1'b0;
	int   rst_tgt = -1, rst_dly = 0, rst_len = 0, rst_to = 0;
	logic fault_req = 1'b0;                 // the stand-in keeps running through this reset
	int   faults_armed = 0;

	// ---- phase generator and the bus stream ----------------------------------------------------
	wire        pclk1, pclk0, mapper_phi2, access, pause, load, stall_eff, ibusy, held;
	wire [12:0] a_in;
	wire        rw;
	wire  [7:0] d_in;
	wire  [5:0] len1, len2;
	logic       up_busy;                     // U: upstream's arm_call_busy
	wire        arm_call_busy;
	wire        stall = stall_up ? up_busy : arm_call_busy;

	localparam int QN = 64;
	logic [21:0] bq [0:QN-1];               // {a[12:0], rw, d[7:0]}
	int          bq_h = 0, bq_n = 0;
	wire  [21:0] bq_head = bq[bq_h];
	fe_phase_gen #(.SEED(1), .EXT_BUS(1'b1)) pg (
		.clk_sys(clk_sys), .run(1'b1), .stall(stall), .driver_run(!cart_reset),
		.ext_a(bq_head[21:9]), .ext_rw(bq_head[8]), .ext_d(bq_head[7:0]),
		.pclk1(pclk1), .pclk0(pclk0), .mapper_phi2(mapper_phi2), .access(access),
		.a_in(a_in), .rw(rw), .d_in(d_in), .pause(pause), .load(load),
		.stall_eff(stall_eff), .ibusy(ibusy), .held(held), .len1(len1), .len2(len2));

	function automatic void bq_push(input logic [12:0] a, input logic w, input logic [7:0] d);
		bq[(bq_h + bq_n) % QN] = {a, !w, d};
		bq_n++;
	endfunction
	function automatic logic [12:0] rd_addr();
		int r;
		r = rnd(100);
		if (r < 10) return {1'b0, 12'(rnd(4096))};
		return {1'b1, 12'(rnd(4096))};
	endfunction
	task automatic gen_instr();
		int r;
		logic [12:0] ca;
		ca = {1'b1, cf_lo};
		r = rnd(1000);
		if (r < 70) begin                                    // a CALLFN write
			bq_push(ca, 1'b1, rnd(2) ? 8'hFF : 8'hFE);
			repeat (gap) bq_push(rd_addr(), 1'b0, 8'(rnd(256)));
			inc("prog_callfn");
		end else if (r < 110) begin                          // INC/DEC on the register: an RMW pair
			int k;
			logic [7:0] d1, d2;
			k = rnd(4);
			case (k)
				0: begin d1 = 8'hFE; d2 = 8'hFF; end         // INC FE: two CALLFNs (pend2)
				1: begin d1 = 8'hFF; d2 = 8'hFE; end         // DEC FF: two CALLFNs
				2: begin d1 = 8'hFD; d2 = 8'hFE; end         // INC FD: the second only
				default: begin d1 = 8'hFF; d2 = 8'h00; end   // INC FF: the first only
			endcase
			bq_push(ca, 1'b0, 8'(rnd(256)));                // the operand read
			bq_push(ca, 1'b1, d1);                           // the dummy write (old value)
			bq_push(ca, 1'b1, d2);                           // the new value (not held: it follows a write)
			repeat (gap) bq_push(rd_addr(), 1'b0, 8'(rnd(256)));
			inc("prog_rmw");
		end else if (r < 220) begin                          // another write
			logic [12:0] a;
			logic [7:0] d;
			a = rd_addr();
			d = 8'(rnd(256));
			if (a[11:0] == cf_lo && d[7:1] == 7'h7F) d = 8'h00;
			bq_push(a, 1'b1, d);
		end else
			bq_push(rd_addr(), 1'b0, 8'(rnd(256)));
	endtask
	always @(posedge clk_sys) begin
		if (load) begin
			bq_h = (bq_h + 1) % QN;
			bq_n = bq_n - 1;
		end
		while (bq_n < 8) gen_instr();
	end
	initial begin
		bq_h = 0; bq_n = 0;
		for (int i = 0; i < 8; i++) bq_push(13'h1000, 1'b0, 8'h00);
	end

	// the core's CALLFN (comb at C, as u_core's callfn: a $105A/$1FF3 commit of FE/FF)
	wire cf = access & a_in[12] & !rw & (a_in[11:0] == cf_lo) & (d_in[7:1] == 7'h7F);

	// in_phase2 and rel_ok (design 2.1), from the phases
	logic ph2 = 1'b0;
	always @(posedge clk_sys) ph2 <= pclk1 ? 1'b0 : (pclk0 ? 1'b1 : ph2);
	wire rel_ok = (ph2 | pclk0) & !pclk1;

	// ---- the DUT ---------------------------------------------------------------------------------
	wire        cl_req, cl_we, cl_gnt;
	wire  [7:0] cl_a;
	wire [31:0] cl_wd;
	wire        cp_cap, cp_rot, cp_shin, cp_cmp, cp_apply, mwin;
	wire        call_tog, call_win, ret_tog;
	logic       cpu_ready;
	logic [31:0] ring [0:5];
	logic       u_cd;                         // U: call_done, high in (X, X+1)
	logic [31:0] hret [0:5];                  // the stand-in's last returns

	daria_fe_call u_call (
		.clk_sys(clk_sys), .cart_reset(cart_reset), .is_dpc(is_dpc), .is_cdf(is_cdf), .jplus(jplus),
		.cdfj_entry(cdfj_entry), .cdfj_stack(cdfj_stack), .callfn(cf), .cpu_ready(cpu_ready),
		.ret_tog(ret_tog), .rel_ok(rel_ok), .ring0(ring[0]), .hk_en(hk_en), .hk_stb(u_cd & hk_en),
		.cl_req(cl_req), .cl_a(cl_a), .cl_we(cl_we), .cl_wd(cl_wd), .cl_gnt(cl_gnt),
		.cp_cap(cp_cap), .cp_rot(cp_rot), .cp_shin(cp_shin), .cp_cmp(cp_cmp), .cp_apply(cp_apply),
		.mwin(mwin), .call_tog(call_tog), .arm_call_busy(arm_call_busy), .call_win(call_win));

	// ---- state RAM port B: the core (DPC+, random, priority 1) and the call port (2) ------------------
	logic        cs_req = 1'b0, cs_we = 1'b0;
	logic  [7:0] cs_a = 8'h00;
	logic [31:0] cs_wd = 32'h0;
	always @(posedge clk_sys) begin
		cs_req <= is_dpc & !cart_reset & (rnd(1000) < k_cs);
		cs_a   <= 8'(rnd(17));
		cs_we  <= rnd(2) == 1;
		cs_wd  <= rnd32();
	end
	assign cl_gnt = cl_req & !cs_req;
	wire  [7:0] stb_addr = cs_req ? cs_a : (cl_gnt ? cl_a : 8'h00);
	wire        stb_we   = cs_req ? cs_we : (cl_gnt & cl_we);
	wire [31:0] stb_wd   = cs_req ? cs_wd : cl_wd;
	wire [31:0] stb_q;

	// ---- the clk_arm side: daria_call and the stand-in for bup_cpu --------------------------------
	wire  [7:0] sta_addr;
	wire        sta_we;
	wire [31:0] sta_wd, sta_q;
	wire        call_go;
	wire [31:0] clr_wd, clr_pc;
	logic [4:0] clr_e;
	logic       parked, returned, ro_valid;
	logic [2:0] ro_idx;
	logic [31:0] ro_data;
	logic [1:0] mres = 2'b11;
	logic       cpu_run = 1'b0;
	always @(posedge clk_arm) begin
		mres    <= {mres[0], cart_reset};
		cpu_run <= !mres[1];
	end
	wire arm_rst = !cpu_run;

	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(clk_arm), .clk_sys(clk_sys),
		.rom_addr(15'd0), .win_qa(), .d_addr(32'd0), .win_qb(), .ram_we(1'b0), .ram_be(4'd0),
		.ram_wdata(32'd0), .ram_q(), .img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0),
		.win_be(4'd0), .sta_addr(sta_addr), .sta_we(sta_we), .sta_wd(sta_wd), .sta_q(sta_q),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0), .fea_addr(13'd0), .fea_q(),
		.feb_addr(13'd0), .feb_q(), .crb_addr(13'd0), .crb_we(1'b0), .crb_be(4'd0), .crb_wd(32'd0),
		.crb_q(), .stb_addr(stb_addr), .stb_we(stb_we), .stb_be(4'hF), .stb_wd(stb_wd), .stb_q(stb_q));

	daria_call u_dcall (
		.clk(clk_arm), .rst(arm_rst), .call_tog(call_tog), .ret_tog(ret_tog),
		.parked(parked), .call_go(call_go), .clr_e(clr_e), .clr_wd(clr_wd), .clr_pc(clr_pc),
		.ro_valid(ro_valid), .ro_idx(ro_idx), .ro_data(ro_data), .returned(returned),
		.sta_addr(sta_addr), .sta_we(sta_we), .sta_wd(sta_wd), .sta_q(sta_q));

	// the stand-in: parked; call_go -> 22 clear clocks (entries from clr_wd); run T clocks;
	// read FIQ r8-r13 out (ro_*), returned with the last; parked. A reset (arm_rst) abandons
	// the call and re-clears (22 clocks), unless the bench armed a fault (keeps running).
	localparam int C_RST = 0, C_IDLE = 1, C_CLR = 2, C_RUN = 3, C_RO = 4;
	int          cst = C_RST, ccnt = 22;
	logic  [2:0] rocnt = 3'd0;
	logic [31:0] cap_w [0:21];
	logic        fault_keep = 1'b0;
	int          stale_set = 0, stale_used = 0;  // the next ret_tog change returns an abandoned call
	wire         stale_ret = stale_set != stale_used;
	logic [31:0] exp_blk [0:7];                // the block of the last flip (bench, clk_sys)
	logic [31:0] lch_blk [0:7];                // snapshot at call_go
	longint      n_launch = 0, n_ret = 0;
	always @(posedge clk_arm) begin
		if (arm_rst && !(fault_keep || (fault_req && cst == C_RUN))) begin
			cst  <= C_RST;
			ccnt <= 22;
		end else begin
			if (arm_rst && fault_req && cst == C_RUN && !fault_keep) begin
				fault_keep <= 1'b1;
				faults_armed++;
			end
			case (cst)
				C_RST:  if (ccnt == 0) cst <= C_IDLE; else ccnt <= ccnt - 1;
				C_IDLE: if (call_go) begin
					cst   <= C_CLR;
					clr_e <= 5'd0;
					for (int i = 0; i < 8; i++) lch_blk[i] = exp_blk[i];
				end
				C_CLR: begin
					cap_w[clr_e] <= clr_wd;
					clr_e <= clr_e + 5'd1;
					if (clr_e == 5'd21) begin
						cst  <= C_RUN;
						ccnt <= (rnda(1000) < k_short) ? int'(rnda(24)) :
						        (rnda(10) == 0) ? int'(rnda(1500)) : int'(rnda(260));
						n_launch++;
						// the launch registers (P1) against the block posted for the last flip
						if (clr_pc != lch_blk[0]) fail("launch", $sformatf("entry %08x, posted %08x", clr_pc, lch_blk[0]));
						if (cap_w[13] != lch_blk[1]) fail("launch", $sformatf("stack %08x, posted %08x", cap_w[13], lch_blk[1]));
						if (cap_w[14] != 32'hF000_0000) fail("launch", "r14 not F0000000");
						for (int v = 0; v < 5; v++)
							if (cap_w[16 + v] != lch_blk[2 + v])
								fail("launch", $sformatf("entry %0d %08x, posted %08x", 16 + v, cap_w[16 + v], lch_blk[2 + v]));
						if (clr_wd != lch_blk[7]) fail("launch", $sformatf("entry 21 %08x, posted %08x", clr_wd, lch_blk[7]));
						for (int i = 0; i < 13; i++) if (cap_w[i] != 32'd0) fail("launch", $sformatf("r%0d not 0", i));
					end
				end
				C_RUN: begin
					if (ccnt != 0) begin
						if (!(fault_keep && arm_rst)) ccnt <= ccnt - 1;
					end else if (!(fault_keep && arm_rst)) begin
						cst   <= C_RO;
						rocnt <= 3'd0;
						for (int v = 0; v < 3; v++) hret[v] <= rnda(2) ? cap_w[16 + v] : rnda32();
						for (int v = 0; v < 3; v++) hret[3 + v] <= (rnda(8) == 0) ? cap_w[19 + v] : rnda32();
					end
				end
				default: begin                          // C_RO
					// a CPU kept running through a reset waits it out here too: daria_call
					// flips ret_tog only for a `returned` outside its reset
					if (fault_keep && arm_rst) inc("ro_held_in_reset");
					else begin
						rocnt <= rocnt + 3'd1;
						if (rocnt == 3'd5) begin
							cst <= C_IDLE;
							if (fault_keep) stale_set <= stale_set + 1;
							fault_keep <= 1'b0;
							n_ret++;
						end
					end
				end
			endcase
		end
	end
	assign parked   = cst == C_IDLE;
	assign ro_valid = cst == C_RO;
	assign ro_idx   = rocnt;
	assign ro_data  = hret[rocnt];
	assign returned = (cst == C_RO) && (rocnt == 3'd5);

	// cpu_ready: hardware/mode B = daria_ready (parked & img_ready, two clk_sys flops);
	// mode A (6.6) = online & shadow ready & !effective_reset, steady
	logic       img_rdy = 1'b1;
	int         drop_left = 0;
	logic [1:0] rdy_s = 2'b00;
	always @(posedge clk_sys) begin
		if (drop_left > 0) drop_left <= drop_left - 1;
		else if (rnd(1000) < k_drop) drop_left <= 1 + rnd(150);
		img_rdy <= drop_left == 0;
		rdy_s   <= {rdy_s[0], parked & img_rdy};
	end
	assign cpu_ready = ready_a ? (img_rdy & !cart_reset) : rdy_s[1];

	// ---- X: the bench's own synchroniser on ret_tog (glue.md 7.3) -------------------------------
	logic b1 = 1'b0, b2 = 1'b0, bseen = 1'b0;
	wire  bnew = b2 ^ bseen;                     // in (S2, X): X is the edge that ends this clock
	always @(posedge clk_sys) begin
		b1 <= ret_tog;
		b2 <= b1;
		if (cart_reset | bnew) bseen <= b2;
		if (bnew && stale_ret) stale_used <= stale_used + 1;
	end

	// ---- ticks: the sweep -------------------------------------------------------------------------------
	logic [15:0] tsch = 16'd0;                   // tsch[0]: a scheduled tick in this clock
	logic        tick_c;                         // a tick in this clock decided in this clock
	wire         tick = tsch[0] | tick_c;
	int          lo_next = -2, mo_next = 0;      // the next offsets to place
	int          lo_rot = 0, mo_rot = 0;
	logic        bbusy;                          // ref: arm_call_busy expected
	logic        outst;                          // ref: flipped, no return yet
	// the commit of a fresh CALLFN comes in the next clock (the generator's pclk0 is registered)
	wire pred_cf = (pg.phase == 2'd1) && (pg.cnt == 6'd1) && (pg.pz_left == 8'd0) && !held &&
	               a_in[12] && !rw && (a_in[11:0] == cf_lo) && (d_in[7:1] == 7'h7F) && !cart_reset &&
	               !bbusy;
	wire fresh = cf & !bbusy & !cart_reset;
	wire yclk  = (b1 ^ b2) & outst & !cart_reset;  // the clock (S1, S1+1): M = S1 + 3
	always_comb begin
		tick_c = 1'b0;
		if (pred_cf && lo_next == -2) tick_c = 1'b1;
		if (fresh && lo_next == -1) tick_c = 1'b1;
		if (yclk && mo_next == 0) tick_c = 1'b1;
	end
	always @(posedge clk_sys) begin
		logic [15:0] t;
		t = tsch >> 1;
		if (fresh) begin
			if (lo_next >= 0) t[lo_next] = 1'b1;
			lo_rot = (lo_rot + 1) % 6;
			lo_next = lo_rot - 2;                    // -2 .. 2, 3 = none
		end
		if (yclk) begin
			if (mo_next >= 1 && mo_next <= 11) t[mo_next - 1] = 1'b1;
			mo_rot = (mo_rot + 1) % 13;
			mo_next = mo_rot;                        // 0 .. 11, 12 = none
		end
		tsch <= t;
	end

	// A third CALLFN in (M, M_fe] of a CDF RMW: upstream accepted call 2 at M and queues it; the
	// one-deep pend2 still holds call 2 and drops it. Only a stream without the instruction's
	// opcode and operand cycles (+gap=0) can commit it there; the U model drops it too (counted).
	logic drop3;
	// ---- U: upstream's audio counters and call controller ---------------------------------------------
	logic [31:0] uc [0:2], uf [0:2], useed [0:2];
	logic        up_pend = 1'b0;
	logic        up_fresh = 1'b0;                 // the pending call came while upstream was idle
	logic [31:0] u_pay [0:5];
	longint      u_acc = 0;
	logic        dep = 1'b0;                      // deposit (both models), a pulse
	logic [31:0] dep_v [0:5];
	logic        rsync = 1'b0;                    // D := U
	initial begin
		up_busy = 1'b0; u_cd = 1'b0;
		for (int v = 0; v < 3; v++) begin uc[v] = 0; uf[v] = 0; useed[v] = 0; end
	end
	always @(posedge clk_sys) begin
		if (cart_reset) begin
			for (int v = 0; v < 3; v++) begin uc[v] <= 0; uf[v] <= 0; end
			up_pend <= 1'b0;
			up_busy <= 1'b0;
			u_cd    <= 1'b0;
		end else begin
			for (int v = 0; v < 3; v++) begin
				logic [31:0] c;
				c = tick ? uc[v] + uf[v] : uc[v];
				if (u_cd && is_cdf) begin
					if (hret[v] != useed[v]) c = hret[v];
					uf[v] <= hret[3 + v];
				end
				uc[v] <= c;
				if (dep) begin uc[v] <= dep_v[v]; uf[v] <= dep_v[3 + v]; end
			end
			if (up_pend && !up_busy) begin             // the accept (call_request & call_ready)
				up_busy <= 1'b1;
				up_pend <= 1'b0;
				for (int v = 0; v < 3; v++) begin
					useed[v]   <= uc[v];
					u_pay[v]   <= uc[v];
					u_pay[3+v] <= uf[v];
				end
				u_acc++;
			end
			if (cf && !up_pend && !drop3) begin
				up_pend  <= 1'b1;
				up_fresh <= !up_busy;
			end
			// a stale return (the stand-in kept running through a reset) is not this call's:
			// upstream's completion token rejects it (arm_mapper_controller.sv:163-177)
			u_cd <= bnew & up_busy & !stale_ret;
			if (bnew && up_busy && !stale_ret) up_busy <= 1'b0;
		end
	end

	// ---- D: u_audio's side of the strobe contract (design 5.6) -----------------------------------------
	logic [31:0] dc [0:2], df [0:2];
	logic  [2:0] take = 3'd0;
	logic        tdef = 1'b0;
	logic [31:0] d_cap [0:5];
	initial for (int v = 0; v < 6; v++) begin ring[v] = 0; d_cap[v] = 0; end
	initial for (int v = 0; v < 3; v++) begin dc[v] = 0; df[v] = 0; end
	always @(posedge clk_sys) begin
		logic late, tick_eff, own, hka, te;
		logic [31:0] a, b;
		if (cart_reset) begin
			for (int v = 0; v < 3; v++) begin dc[v] <= 0; df[v] <= 0; end
			for (int v = 0; v < 6; v++) ring[v] <= 0;
			take <= 3'd0;
			tdef <= 1'b0;
		end else if (dep | rsync) begin
			for (int v = 0; v < 3; v++) begin
				dc[v] <= dep ? dep_v[v] : (tick ? uc[v] + uf[v] : uc[v]);
				df[v] <= dep ? dep_v[3 + v] : uf[v];
			end
			tdef <= 1'b0;
		end else begin
			late     = tdef & !mwin;
			tick_eff = (tick & !mwin) | late;
			own      = cp_apply & is_cdf;
			hka      = hk_en & u_cd & is_cdf;
			for (int v = 0; v < 3; v++) begin
				te = (own & take[v]) | (hka & (hret[v] != ring[v]));
				a  = te ? (hka ? hret[v] : ring[v]) : dc[v];
				b  = (tick_eff & !te) ? df[v] : 32'd0;
				if (tick_eff | te) dc[v] <= a + b;
				if (own | hka) df[v] <= hka ? hret[3 + v] : ring[3 + v];
			end
			if (cp_cap) begin
				for (int v = 0; v < 3; v++) begin
					ring[v] <= dc[v];  ring[3 + v] <= df[v];
					d_cap[v] <= dc[v]; d_cap[3 + v] <= df[v];
				end
			end else if (cp_rot) begin
				for (int v = 0; v < 5; v++) ring[v] <= ring[v + 1];
				ring[5] <= ring[0];
			end else if (cp_shin) begin
				for (int v = 0; v < 5; v++) ring[v] <= ring[v + 1];
				ring[5] <= stb_q;
			end
			if (cp_shin & cp_cmp) take <= {stb_q != ring[0], take[2:1]};
			if ((tick & mwin) | late) tdef <= tick & mwin;
			if (tick & mwin) inc("tick_deferred");
			if (late) inc("tick_late_add");
		end
	end

	// ---- ref: design 6.1 at the event level, and every check ---------------------------------------------
	logic        b_post = 1'b0, b_pfirst = 1'b0, b_pcap = 1'b0, b_wflip = 1'b0, b_rel = 1'b0;
	logic        bp2 = 1'b0, bp2e = 1'b0, post_late = 1'b0, post_tm = 1'b0;
	int          pk = 0, jx = -1;
	logic        k_dpc = 1'b0, k_hk = 1'b0;    // the returning call's kind
	logic        flip_q = 1'b0, tog_q1 = 1'b0, rst_q1 = 1'b0, rs2_q1 = 1'b0;
	int          acc_diff = 0;                  // upstream's accepts less DARIA's POST entries
	logic        post_q1 = 1'b0, acc_mark = 1'b0;
	logic  [7:0] cnum_q1 = 8'h00;
	logic        need_rs = 1'b0;                 // D and U compared again only after a resync
	longint      x_last = -100, l_last = -100, tick_e1 = -100;
	logic        tick_at_m = 1'b0;               // a tick at M of the current return
	logic [31:0] blk [0:7];                       // the block being posted
	longint      flips = 0, rd_calls = 0;
	initial begin bbusy = 1'b0; outst = 1'b0; end

	assign drop3 = cf & !cart_reset & bp2 & bp2e & (jx >= 1) & (jx <= 6) & !k_dpc & !k_hk;

	function automatic logic [31:0] f0w();
		if (is_dpc) return 32'h0000_0C09;
		if (jplus) return {cdfj_entry[31:1], 1'b1};
		return 32'h0000_0809;
	endfunction
	function automatic logic [31:0] f1w();
		return jplus ? cdfj_stack : 32'h4000_1FFC;
	endfunction
	function automatic string ofs(input string p, input longint d);
		return (d < 0) ? $sformatf("%s-%0d", p, -d) : $sformatf("%s+%0d", p, d);
	endfunction

	always @(posedge clk_sys) begin
		logic        start, set_p2, p_last, flip_now, xev, a_dpc, a_apply, a_hkw, rel_go, rel_end, again;
		logic        p2_now, in_xb, k_rd, e_cap, e_rot, e_shin, e_cmp, e_apply, e_mwin, e_req, e_we, cdf_rd;
		logic  [7:0] e_a;
		logic  [8:0] e_st;
		if (drop3) inc("callfn_dropped_m_mfe");
		if (cf & up_pend & !up_busy & !up_fresh) inc("callfn_while_upstream_pending_at_m");

		if (e < trace)
			$display("@%0d p1 %b p0 %b acc %b held %b stl %b a %04x rw %b d %02x | rst %b cf %b st %03x busy %b p2 %b pu %b req %b we %b a %02x gnt %b wd %08x cap %b rot %b shin %b cmp %b app %b mw %b tog %b rdy %b rel %b bnew %b tick %b | post %b pk %0d wf %b out %b jx %0d rel %b bbusy %b bp2 %b | dc0 %08x uc0 %08x df0 %08x uf0 %08x tdef %b dep %b rs %b",
				e, pclk1, pclk0, access, held, stall_eff, a_in, rw, d_in, cart_reset, cf, u_call.st, arm_call_busy, u_call.pend2, u_call.pend_up, cl_req, cl_we, cl_a,
				cl_gnt, cl_wd, cp_cap, cp_rot, cp_shin, cp_cmp, cp_apply, mwin, call_tog, cpu_ready, rel_ok,
				bnew, tick, b_post, pk, b_wflip, outst, jx, b_rel, bbusy, bp2, dc[0], uc[0], df[0], uf[0], tdef, dep, rsync);

		// -- the previous edge's results ------------------------------------------------------
		if (rst_q1) begin                         // a reset edge just passed (6.5)
			if (u_call.st != 9'd1 || arm_call_busy || u_call.pend2 || u_call.pend_up)
				fail("reset", $sformatf("after a reset clock: st %03x busy %b pend2 %b pend_up %b", u_call.st, arm_call_busy, u_call.pend2, u_call.pend_up));
			if (u_call.ret_seen != rs2_q1) fail("reset", "ret_seen not re-synced");
			if (call_tog != tog_q1) fail("reset", "call_tog changed in a reset clock");
			inc("reset_clocks_checked");
		end
		if ((call_tog != tog_q1) != flip_q)
			fail("flip", $sformatf("call_tog %s at the last edge", flip_q ? "did not flip" : "flipped"));
		if (u_call.cnum != 8'(cnum_q1 + {7'd0, flip_q})) fail("flip", "cnum");
		if (flip_q) flips++;

		// -- ref: the state expected in this clock ---------------------------------------------
		cdf_rd = !k_dpc & !k_hk;
		k_rd   = jx >= 0 && cdf_rd;
		e_st = 9'd0;
		if (!bbusy) e_st[0] = 1'b1;
		if (b_post) e_st[1] = 1'b1;
		if (b_wflip) e_st[2] = 1'b1;
		if (outst) e_st[3] = 1'b1;
		if (k_rd && jx <= 4) e_st[4] = 1'b1;
		if (k_rd && jx == 5) e_st[5] = 1'b1;
		if (k_rd && jx == 6) e_st[6] = 1'b1;
		if (jx == 0 && k_hk && !k_dpc) e_st[7] = 1'b1;
		if (b_rel) e_st[8] = 1'b1;
		if (u_call.st !== e_st) fail("state", $sformatf("st %03x, expected %03x (jx %0d)", u_call.st, e_st, jx));
		if (arm_call_busy !== bbusy) fail("busy", $sformatf("arm_call_busy %b, expected %b", arm_call_busy, bbusy));
		if (u_call.pend2 !== bp2) fail("pend2", $sformatf("pend2 %b, expected %b", u_call.pend2, bp2));
		if (call_win !== (outst | (k_rd && jx <= 6) | (jx == 0 && k_hk && !k_dpc)))
			fail("call_win", "call_win");
		if (u_call.st[0] != !u_call.call_busy) fail("busy", "call_busy is not !IDLE");

		// the state RAM requests and the strobes expected in this clock
		xev     = bnew & outst & !cart_reset;     // this edge is X (glue.md 7.3), seen by the bench alone
		e_req   = b_post | (bnew & outst & is_cdf & !hk_en) | (k_rd && jx <= 4);
		e_we    = b_post;
		e_a     = b_post ? 8'hF0 + 8'(pk) : (k_rd && jx <= 4) ? 8'hF9 + 8'(jx) : 8'hF8;
		e_cap   = (b_pfirst & b_pcap) | (k_rd && jx == 6 && bp2 && bp2e) | (jx == 0 && k_hk && !k_dpc && bp2 && bp2e);
		e_rot   = b_post & cl_gnt & (pk >= 2);
		e_shin  = k_rd && jx <= 5;
		e_cmp   = k_rd && jx <= 2;
		e_apply = k_rd && jx == 6;
		e_mwin  = k_rd && jx >= 1 && jx <= 6;
		if (cl_req !== e_req) fail("s_req", $sformatf("cl_req %b, expected %b (jx %0d)", cl_req, e_req, jx));
		if (e_req && (cl_we !== e_we || cl_a !== e_a))
			fail("s_req", $sformatf("cl_we %b cl_a %02x, expected %b %02x", cl_we, cl_a, e_we, e_a));
		if (e_req && !e_we && is_cdf && !cl_gnt) fail("s_req", "a CDF read not granted");
		if (cp_cap !== e_cap) fail("cp_cap", $sformatf("cp_cap %b, expected %b", cp_cap, e_cap));
		if (cp_rot !== e_rot) fail("cp_rot", $sformatf("cp_rot %b, expected %b", cp_rot, e_rot));
		if (cp_shin !== e_shin) fail("cp_shin", $sformatf("cp_shin %b, expected %b (jx %0d)", cp_shin, e_shin, jx));
		if (cp_cmp !== e_cmp) fail("cp_cmp", $sformatf("cp_cmp %b, expected %b", cp_cmp, e_cmp));
		if (cp_apply !== e_apply) fail("cp_apply", $sformatf("cp_apply %b, expected %b", cp_apply, e_apply));
		if (mwin !== e_mwin) fail("mwin", $sformatf("mwin %b, expected %b (jx %0d)", mwin, e_mwin, jx));
		if (e_shin) inc("return_reads");
		if (e_apply) inc("applies");
		// the posted words: F0, F1, then upstream's payload at its accept (6.2, 6.4)
		if (b_post && cl_gnt) begin
			logic [31:0] w;
			w = (pk == 0) ? f0w() : (pk == 1) ? f1w() : 32'd0;
			if (pk >= 2) begin
				if (post_late) w = d_cap[pk - 2];
				else if (post_tm && pk < 5) w = u_pay[pk - 2] + u_pay[pk + 1];
				else w = u_pay[pk - 2];
			end
			blk[pk] = w;
			if (cl_wd !== w) fail("post", $sformatf("F%0x %08x, expected %08x", pk, cl_wd, w));
			inc("post_words");
		end
		if (b_post && !cl_gnt) inc("post_denied");
		if (xev && is_cdf && !hk_en) inc("f8_in_first_clock");

		// ev taps
		if (u_call.ev_rmw_call !== (cf & arm_call_busy)) fail("ev", "ev_rmw_call");
		if (u_call.ev_ret_unasked !== (bnew & !outst & !cart_reset))
			fail("ev", $sformatf("ev_ret_unasked %b (bnew %b outst %b)", u_call.ev_ret_unasked, bnew, outst));
		if (u_call.ev_ret_unasked) inc("ret_unasked");
		if (cf & arm_call_busy) inc("rmw_call_events");

		// one DARIA call per upstream accept: every call upstream accepts is posted (POST
		// entered), and no other; compared at quiet points (both idle, nothing pending),
		// since the two start at different edges (C and C+1, X and M, M_fe and M)
		if (cart_reset) acc_diff <= 0;
		else begin
			if (u_call.st[0] && !up_pend && !up_busy && !cf) begin
				if (acc_diff != 0) fail("accepts", $sformatf("upstream accepted %0d more calls than DARIA posted", acc_diff));
				else if (acc_mark) inc("accept_balance_checks");
			end
			acc_diff <= acc_diff + ((up_pend && !up_busy) ? 1 : 0) - ((u_call.st[1] && !post_q1) ? 1 : 0);
		end
		acc_mark <= (u_call.st[0] && !up_pend && !up_busy && !cf) ? 1'b0 : 1'b1;
		post_q1  <= u_call.st[1];

		// pend_up against upstream's call_pending (masked in the accept clock and after a late CALLFN)
		if (!(up_pend & !up_busy & up_fresh) && !cart_reset) begin
			if (u_call.pend_up !== up_pend)
				fail("pend_up", $sformatf("pend_up %b, upstream's call_pending %b", u_call.pend_up, up_pend));
			if (up_pend) inc("pend_up_compares_set");
		end

		// D against U: every edge outside [M, M_fe] of a CDF call without the hook
		if (!need_rs && !rsync && !dep && !cart_reset && !rst_q1 && !((e - 1) - x_last >= 1 && (e - 1) - x_last <= 7 && cdf_rd)) begin
			for (int v = 0; v < 3; v++) begin
				if (dc[v] !== uc[v]) fail("counter", $sformatf("v%0d counter %08x, upstream %08x (edge - X = %0d)", v, dc[v], uc[v], (e - 1) - x_last));
				if (df[v] !== uf[v]) fail("freq", $sformatf("v%0d frequency %08x, upstream %08x", v, df[v], uf[v]));
			end
			inc("du_compares");
		end
		if (tick && e - l_last >= 0 && e - l_last <= 2) inc(ofs("tick_L", e - l_last));
		if (tick) tick_e1 <= e;
		if (fresh && tick) inc("tick_L-1");
		if (fresh && !tick && tick_e1 == e - 1) inc("tick_L-2");
		if (xev && tick) inc("tick_M-1");
		if (xev && !tick && tick_e1 == e - 1) inc("tick_M-2");
		if (tick && e - (x_last + 1) >= 0 && e - (x_last + 1) <= 9) inc(ofs("tick_M", e - (x_last + 1)));

		// -- ref: the next state -----------------------------------------------------------------
		start    = cf & !bbusy;
		set_p2   = cf & bbusy & !bp2 & !b_rel & !up_pend;   // upstream ignores a CALLFN while call_pending
		in_xb    = (k_rd && jx <= 6) || (jx == 0 && k_hk && !k_dpc);   // RD, RDW, APPLY, HKW
		p2_now   = bp2 | set_p2;
		p_last   = b_post & cl_gnt & (pk == 7);
		flip_now = (p_last | b_wflip) & cpu_ready & !cart_reset;
		a_dpc    = xev & is_dpc & p2_now;
		a_apply  = k_rd && jx == 6 && bp2 && bp2e;
		a_hkw    = jx == 0 && k_hk && !k_dpc && bp2 && bp2e;
		rel_go   = b_rel & (bp2 | cf);
		rel_end  = b_rel & !bp2 & !cf & rel_ok & cpu_ready;
		again    = a_dpc | a_apply | a_hkw | rel_go;

		if (cart_reset) begin
			if (!rst_q1) inc($sformatf("reset_in_%0d", $clog2(int'(u_call.st))));
			b_post <= 1'b0; b_pfirst <= 1'b0; b_pcap <= 1'b0; b_wflip <= 1'b0; b_rel <= 1'b0;
			bbusy <= 1'b0; bp2 <= 1'b0; outst <= 1'b0; jx <= -1; pk <= 0;
			flip_q <= 1'b0;
		end else begin
			if (set_p2 & in_xb) begin                  // committed after X: upstream's new call after the merge
				inc("late_pend2");
				if (cnt["late_pend2"] <= 3) $display("INFO a CALLFN after X @%0d (st %03x, jx %0d)", e, u_call.st, jx);
			end
			if (set_p2 & !in_xb & xev) inc("pend2_at_x");
			if (start | again) begin
				b_pfirst  <= 1'b1;
				b_pcap    <= start | a_dpc | rel_go;
				pk        <= 0;
				post_late <= (rel_go & bp2 & !bp2e) | need_rs;   // (C2+1, capture] may hold a tick; or D != U
				if (rel_go & bp2 & !bp2e) need_rs <= 1'b1;
				post_tm   <= a_apply & tick_at_m;
				if (start) begin
					l_last <= e + 1;
					inc(is_dpc ? "calls_dpc" : (hk_en ? "calls_cdf_hook" : "calls_cdf"));
				end else if (!rel_go) inc(is_dpc ? "rmw_dpc" : (hk_en ? "rmw_cdf_hook" : "rmw_cdf"));
				else inc(bp2 ? "rel_go_late_pend2" : "rel_go_callfn");
				if (a_apply && tick_at_m) begin
					inc("rmw_call_value");             // design 6.4: call 2's payload has the tick at M
					need_rs <= 1'b1;
				end
			end else begin
				b_pfirst <= 1'b0;
				if (b_post && cl_gnt) pk <= pk + 1;
			end
			b_post  <= start | again | (b_post & !p_last);
			b_wflip <= (p_last | b_wflip) & !cpu_ready;
			if ((p_last | b_wflip) & !cpu_ready) inc("flip_wait_clocks");
			flip_q  <= flip_now;
			if (flip_now) for (int i = 0; i < 8; i++) exp_blk[i] = blk[i];
			outst   <= flip_now | (outst & !xev);
			if (xev) begin
				jx     <= 0;
				k_dpc  <= is_dpc;
				k_hk   <= hk_en;
				x_last <= e;
				tick_at_m <= 1'b0;
				if (is_cdf & !hk_en) rd_calls++;
			end else if (jx >= 0) jx <= (jx == 10) ? -1 : jx + 1;
			if (x_last == e - 1 && tick) tick_at_m <= 1'b1;   // this edge is M
			b_rel <= (xev & is_dpc & !p2_now) | (k_rd && jx == 6 && !a_apply) |
			         (jx == 0 && k_hk && !k_dpc && !a_hkw) | (b_rel & !rel_go & !rel_end);
			if (rel_end) inc("releases");
			if (b_rel & !rel_end & !rel_go) inc("rel_wait_clocks");
			bbusy <= start | (bbusy & !rel_end);
			bp2   <= again ? 1'b0 : (set_p2 | bp2);
			if (set_p2) bp2e <= !in_xb;
		end

		// the resync point: everything quiet
		rsync <= 1'b0;
		dep   <= 1'b0;
		if (!cart_reset && !bbusy && !outst && jx < 0 && !up_busy && !up_pend && !b_rel && !b_post && !cf) begin
			if (need_rs) begin
				rsync    <= 1'b1;
				need_rs  <= 1'b0;
				inc("resyncs");
			end else if (rnd(1000) < k_dep) begin
				dep <= 1'b1;
				for (int v = 0; v < 6; v++) dep_v[v] <= rnd32();
				inc("deposits");
			end
		end

		tog_q1  <= call_tog;
		cnum_q1 <= u_call.cnum;
		rst_q1  <= cart_reset;
		rs2_q1  <= u_call.ret_s2;
		e <= e + 1;
	end

	// ---- resets: epochs, and aimed at states ------------------------------------------------------------
	assign rst_hit = (rst_tgt >= 0) && (rst_left == 0) && (rst_dly == 0) && u_call.st[rst_tgt] &&
	                 (!fault_pick || cst == C_RUN);
	always @(posedge clk_sys) begin
		// a new epoch: the reset rises first; the scheme and the rest change in its second
		// clock (as a load changes force_bs only while the console is held in reset)
		if (e > 1 && (e % epoch) == 1) begin
			int k;
			k = (only == 1) ? 0 : (only == 2) ? 1 : int'(rnd(2));
			is_dpc <= k == 0;
			is_cdf <= k == 1;
			jplus  <= (k == 1) && (rnd(3) == 0);
			cf_lo  <= (k == 0) ? 12'h05A : 12'hFF3;
			hk_en  <= (k == 1) && ((hook_m >= 0) ? hook_m[0] : (rnd(3) == 0));
			ready_a <= (ready_m >= 0) ? ready_m : int'(rnd(2));
			cdfj_entry <= rnd32() & 32'hFFFF_FFFE;
			cdfj_stack <= rnd32();
			inc("epochs");
		end
		if (e > 0 && (e % epoch) == 0) begin
			rst_left <= 40 + int'(rnd(40));
			rst_tgt <= -1;
		end else if (rst_hit) begin
			rst_left  <= rst_len - 1;
			rst_tgt   <= -1;
			fault_req <= fault_pick;
			fault_pick <= 1'b0;
			if (fault_pick) inc("fault_resets");
		end else if (rst_left > 0) begin
			rst_left <= rst_left - 1;
		end else if (rst_tgt >= 0) begin
			if (rst_to == 0) begin
				rst_tgt <= -1;
				fault_pick <= 1'b0;
			end else rst_to <= rst_to - 1;
			if (u_call.st[rst_tgt] && rst_dly != 0) rst_dly <= rst_dly - 1;
		end else if (cf & !arm_call_busy & (rnd(1000) < k_rst)) begin
			int t;
			t = int'(rnd(9));
			rst_tgt    <= t;
			rst_len    <= 1 + int'(rnd(30));
			rst_to     <= 3000;
			fault_pick <= (t == 3) && !ready_a && (rnd(1000) < fault_k);
			rst_dly    <= (t == 3 || t == 2 || t == 8) ? int'(rnd(30)) : (t == 1) ? int'(rnd(8)) : 0;
		end
		if (rst_left == 0 && !cart_reset && fault_req && !fault_keep && cst != C_RUN) fault_req <= 1'b0;
		rst_r <= (e < 40) || (e > 0 && (e % epoch) == 0) || (rst_hit ? (rst_len > 1) : (rst_left > 1));
	end

	// the first epoch's configuration
	initial begin
		int k;
		@(posedge clk_sys);
		k = (only == 1) ? 0 : (only == 2) ? 1 : 1;
		is_dpc = k == 0;
		is_cdf = k == 1;
		cf_lo  = (k == 0) ? 12'h05A : 12'hFF3;
		hk_en  = (k == 1) && (hook_m == 1);
		ready_a = (ready_m >= 0) ? ready_m : 0;
	end

	// ---- end ---------------------------------------------------------------------------------------------
	always @(posedge clk_sys) begin
		if (e == n_clk) begin
			string ks;
			$display("tb_fe_call: %0d clocks, %0d flips, %0d launches, %0d returns, %0d CDF returns read, U accepts %0d, faults %0d",
				e, flips, n_launch, n_ret, rd_calls, u_acc, faults_armed);
			if (cnt.first(ks)) do $display("  %-22s %0d", ks, cnt[ks]); while (cnt.next(ks));
			if (err_c.first(ks)) do $display("  ERRORS %-15s %0d", ks, err_c[ks]); while (err_c.next(ks));
			if (nerr != 0) $fatal(1, "tb_fe_call: %0d errors", nerr);
			$display("tb_fe_call: PASS");
			$finish;
		end
	end
endmodule

`default_nettype wire
