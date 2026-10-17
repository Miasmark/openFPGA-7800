//------------------------------------------------------------------------------
// tb_fe_stub: the whole daria_fe tree with daria_mem, so that every file
// elaborates together in Verilator (docs/daria_fe/design.md 12.2 step 0;
// docs/daria_fe/interfaces.md). daria_fe sits on daria_mem's clk_sys ports
// as atari7800_pocket will wire it (1.6), fe_phase_gen drives the bus, and
// the bench runs +clocks (default 1,000) clk_sys. It checks only what holds
// for the stubs and for the finished design alike: fe_oe = a_in[12] on
// every clock, and that every bench tap of design 1.7 (and the guard's and
// call's 1.4 taps) exists under its frozen hierarchical name with its frozen
// width (step-0 review R-3, docs/daria_fe/interfaces.md): a lane that
// renames or resizes a tap breaks this build. It stays a smoke test after
// the lanes fill the bodies.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_stub;
	logic clk_sys = 1'b0, clk_arm = 1'b0;
	always #34.92 clk_sys = ~clk_sys;          // 14.318 MHz
	always #13.095 clk_arm = ~clk_arm;         // DARIA's /18 (38.18 MHz)
	int clocks = 1000;
	logic cart_reset = 1'b1;

	// ---- the bus ------------------------------------------------------------------
	wire        pclk1, pclk0, mapper_phi2, access, rw, pause, load, stall_eff, ibusy, held;
	wire [12:0] a_in;
	wire  [7:0] d_in;
	wire  [5:0] len1, len2;
	wire        arm_call_busy, arm_dma_busy;
	fe_phase_gen #(.MODE("mix")) u_pg (
		.clk_sys(clk_sys), .run(1'b1), .stall(arm_call_busy | arm_dma_busy), .driver_run(!cart_reset),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(pclk1), .pclk0(pclk0), .mapper_phi2(mapper_phi2), .access(access), .a_in(a_in), .rw(rw),
		.d_in(d_in), .pause(pause), .load(load), .stall_eff(stall_eff), .ibusy(ibusy), .held(held),
		.len1(len1), .len2(len2));

	// ---- daria_fe on daria_mem ----------------------------------------------------
	wire [12:0] fea_addr, feb_addr, crb_addr;
	wire [31:0] fea_q, feb_q, crb_q, stb_q, crb_wd, stb_wd;
	wire        crb_we, stb_we;
	wire  [3:0] crb_be, stb_be;
	wire  [7:0] stb_addr;
	wire        call_tog, smp_req, fe_oe, init_busy;
	wire [18:0] smp_addr;
	wire  [7:0] fe_do;

	daria_fe u_fe (
		.clk_sys(clk_sys), .clk_arm(clk_arm), .cart_reset(cart_reset), .pause(pause),
		.a_in(a_in), .d_in(d_in), .rw(rw), .pclk1(pclk1), .pclk0(pclk0), .access(access),
		.scheme(6'd23), .revision(3'd2), .cdf_ldx(1'b0), .cdf_ldy(1'b0),
		.fetch_off_en(1'b0), .fetch_off(8'd0), .cdfj_entry(32'd0), .cdfj_stack(32'd0),
		.audio_size_addr(16'd0), .rom_size(32'd32768), .ram32(1'b0),
		.load_start(1'b0), .load_end(1'b0), .cart_win(1'b0), .cpu_ready(1'b1), .ret_tog(1'b0),
		.call_tog(call_tog), .smp_req(smp_req), .smp_addr(smp_addr), .smp_ack(1'b0), .smp_data(8'd0),
		.fe_do(fe_do), .fe_oe(fe_oe), .arm_call_busy(arm_call_busy), .arm_dma_busy(arm_dma_busy),
		.init_busy(init_busy),
		.fea_addr(fea_addr), .fea_q(fea_q), .feb_addr(feb_addr), .feb_q(feb_q),
		.crb_addr(crb_addr), .crb_we(crb_we), .crb_be(crb_be), .crb_wd(crb_wd), .crb_q(crb_q),
		.stb_addr(stb_addr), .stb_we(stb_we), .stb_be(stb_be), .stb_wd(stb_wd), .stb_q(stb_q),
		.hk_en(1'b0), .hk_stb(1'b0), .hk_ret(192'd0));

	wire [31:0] win_qa, win_qb, ram_q, sta_q;
	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(clk_arm), .clk_sys(clk_sys),
		.rom_addr(15'd0), .win_qa(win_qa), .d_addr(32'd0), .win_qb(win_qb),
		.ram_we(1'b0), .ram_be(4'd0), .ram_wdata(32'd0), .ram_q(ram_q),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(8'd0), .sta_we(1'b0), .sta_wd(32'd0), .sta_q(sta_q),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0),
		.fea_addr(fea_addr), .fea_q(fea_q), .feb_addr(feb_addr), .feb_q(feb_q),
		.crb_addr(crb_addr), .crb_we(crb_we), .crb_be(crb_be), .crb_wd(crb_wd), .crb_q(crb_q),
		.stb_addr(stb_addr), .stb_we(stb_we), .stb_be(stb_be), .stb_wd(stb_wd), .stb_q(stb_q));

	// ---- the frozen taps (design 1.7; interfaces.md sections 4 and 5) ---------------
	int tap_bad = 0;
	`define TAP(sig, w) if ($bits(u_fe.sig) != (w)) begin \
		$display("tb_fe_stub: tap u_fe.%s is %0d bits, frozen %0d", `"sig`", $bits(u_fe.sig), (w)); tap_bad++; end
	initial begin
		// seq
		`TAP(u_seq.k, 8) `TAP(u_seq.c, 4) `TAP(u_seq.ph2, 1) `TAP(u_seq.ev_short, 1)
		// core, both schemes
		`TAP(u_core.op, $bits(daria_fe_pkg::dec_t)) `TAP(u_core.op, 38) `TAP(u_core.bank, 3) `TAP(u_core.fpend, 1)
		`TAP(u_core.W, 32) `TAP(u_core.wb_v, 1) `TAP(u_core.wb_a, 9) `TAP(u_core.p32_in, 1) `TAP(u_core.sel_up, 1)
		`TAP(u_core.pend_s, 1) `TAP(u_core.pend_r, 1) `TAP(u_core.pend_c, 2)
		`TAP(u_core.rdW, 1) `TAP(u_core.rdP, 1) `TAP(u_core.rdS, 1)
		// core, DPC+
		`TAP(u_core.ff_en, 1) `TAP(u_core.rnd, 32) `TAP(u_core.pptr, 4)
		`TAP(u_core.wave[0], 7) `TAP(u_core.wave[1], 7) `TAP(u_core.wave[2], 7)
		`TAP(u_core.svc_pend, 1) `TAP(u_core.svc_fill, 1) `TAP(u_core.svc_src, 17) `TAP(u_core.svc_dst, 13)
		`TAP(u_core.svc_rem, 8) `TAP(u_core.svc_val, 8)
		`TAP(u_core.note_stb, 1) `TAP(u_core.note_v, 2) `TAP(u_core.note_val, 8)
		// core, CDF
		`TAP(u_core.mode, 8) `TAP(u_core.fexp, 13) `TAP(u_core.jr, 2) `TAP(u_core.jexp, 13) `TAP(u_core.jstream, 6)
		// audio
		`TAP(u_audio.tick, 1) `TAP(u_audio.accum, 24)
		`TAP(u_audio.counter[0], 32) `TAP(u_audio.counter[1], 32) `TAP(u_audio.counter[2], 32)
		`TAP(u_audio.freq[0], 32) `TAP(u_audio.freq[1], 32) `TAP(u_audio.freq[2], 32)
		`TAP(u_audio.rc[0], 32) `TAP(u_audio.rc[1], 32) `TAP(u_audio.rc[2], 32)
		`TAP(u_audio.ring[0], 32) `TAP(u_audio.ring[1], 32) `TAP(u_audio.ring[2], 32)
		`TAP(u_audio.ring[3], 32) `TAP(u_audio.ring[4], 32) `TAP(u_audio.ring[5], 32)
		`TAP(u_audio.take, 3) `TAP(u_audio.tdef, 1) `TAP(u_audio.st, 12) `TAP(u_audio.voice, 2)
		`TAP(u_audio.ssum, 8) `TAP(u_audio.wsh, 5) `TAP(u_audio.woff, 15) `TAP(u_audio.dig_addr, 32)
		`TAP(u_audio.dig_low, 1) `TAP(u_audio.dig_ram, 15) `TAP(u_audio.dig_smp, 1) `TAP(u_audio.rp, 1)
		`TAP(u_audio.np, 1) `TAP(u_audio.amplitude, 8) `TAP(u_audio.dispatch, 1) `TAP(u_audio.al, 2)
		`TAP(u_audio.busy_l, 1) `TAP(u_audio.busy_r, 1)
		// call
		`TAP(u_call.st, 9) `TAP(u_call.cnum, 8) `TAP(u_call.pend2, 1) `TAP(u_call.pend_up, 1)
		`TAP(u_call.ret_seen, 1) `TAP(u_call.call_busy, 1)
		// copy
		`TAP(u_copy.f6_act, 1) `TAP(u_copy.f6_ph, 4) `TAP(u_copy.run, 1) `TAP(u_copy.fill, 1)
		`TAP(u_copy.src, 17) `TAP(u_copy.dst, 13) `TAP(u_copy.rem, 8) `TAP(u_copy.val, 8)
		`TAP(u_copy.init_busy, 1) `TAP(u_copy.dma_busy, 1)
		// ports
		`TAP(u_arb.crb_use, 1) `TAP(u_arb.own_r, 6) `TAP(u_arb.own_s, 3) `TAP(u_arb.own_a, 4)
		// guard (1.7, and 1.4's and 8.1's)
		`TAP(u_guard.locked, 1) `TAP(u_guard.pd_same, 1) `TAP(u_guard.ph, 2) `TAP(u_guard.phb_next, 1)
		`TAP(u_guard.guard_on, 1) `TAP(u_guard.good, 4) `TAP(u_guard.ev_unlock, 1)
		`TAP(u_guard.pd_tog, 1) `TAP(u_guard.pd_rx, 1) `TAP(u_guard.pd_rx1, 1)
		// events
		`TAP(u_seq.ev_short, 1) `TAP(u_core.ev_tbl_alias, 1) `TAP(u_core.ev_guard_sup, 1)
		`TAP(u_core.ev_rmw_svc, 1) `TAP(u_call.ev_rmw_call, 1) `TAP(u_call.ev_ret_unasked, 1)
		`TAP(u_audio.ev_size_hi, 1) `TAP(u_arb.ev_grant_steal, 1)
		// assertions
		`TAP(u_arb.a_collide, 1) `TAP(u_arb.a_wb_late, 1) `TAP(u_arb.a_p32_late, 1)
		`TAP(u_arb.a_guard_core, 1) `TAP(u_arb.a_guard_wr, 1) `TAP(u_core.a_fpjr, 1)
		`TAP(u_core.a_pend_late, 1) `TAP(u_audio.a_tdef2, 1) `TAP(u_copy.a_f6_live, 1)
	end
	`undef TAP

	int bad = 0, cyc = 0;
	always @(posedge clk_sys) begin
		if (fe_oe != a_in[12]) bad++;
		if (pclk1) cyc++;
	end

	initial begin
		void'($value$plusargs("clocks=%d", clocks));
		repeat (20) @(posedge clk_sys);
		cart_reset <= 1'b0;
		repeat (clocks - 20) @(posedge clk_sys);
		#1;
		$display("tb_fe_stub: %0d clocks, %0d 6507 cycles, fe_oe wrong in %0d; %0d taps missized",
			clocks, cyc, bad, tap_bad);
		if (bad != 0 || cyc == 0 || tap_bad != 0) $fatal(1, "tb_fe_stub: FAIL");
		$display("tb_fe_stub: PASS");
		$finish;
	end
endmodule

`default_nettype wire
