//------------------------------------------------------------------------------
// tb_fe_rand: the random differential bench of docs/daria_fe/design.md 12.1
// (lane E3). Upstream's DPC+/CDF cluster (fe_rand_up.sv: mapper_dpcplus,
// mapper_cdf, arm_mapper_tables, arm_mapper_ram_init, arm_mapper_writeback,
// cdf_fastjump_table, arm_mapper_audio, cart_ram_tdp, wired as cart2600.sv and
// top.sv wire them, with the controller, the DMA and sample ports and the DDR
// as models) against side B:
//
//   default    daria_fe + daria_mem (#(.WIN_KB(32)); -DDARIA_RAM_POISON with
//              POISON=1), in mode A: clk_arm is upstream's (5 x clk_sys, fixed
//              phase: the guard never locks, lane D issue 3); ret_tog per call
//              number; the returns written into state RAM F8-FD on port A;
//              the ARM's cart RAM writes mirrored into port A on the edge
//              cart_ram_tdp takes them (writeback and DMA excluded); the
//              sample port answered after +slat_min..+slat_max clk_sys;
//              cart_win emulated (the download, then 64 clocks); the hook
//              (+hook) from upstream's call_done and returns
//   -DSELF     a second fe_rand_up: the upstream-vs-upstream self-check. Every
//              bad count must be 0.
//
// Both sides see one bus: fe_phase_gen (../fe_unit/phase_gen.svh, EXT_BUS)
// with this bench's program-like stream (tb_fe_core's, extended): phase 1 of
// 2/4/6/stretched, phase 2 of 6/10/stretched, pauses in either phase, held
// repeats (the stall), repeated addresses; the stall is top.sv's
// arm_call_stall with the hold of bench.md 7.4.2: tia_en && (upstream's
// call_busy || (!init_busy && (upstream's dma_busy || side B's dma_busy))).
//
// Epochs: a random scheme (DPC+ sf 0/1, CDF0/1/J/J+), revision, LDX/LDY,
// fetch offset, entry/stack, audio_size_addr, rom_size (32 KB, or up to 64
// KB: samples beyond the front-end ROM); a random image dense in
// $A9/$A2/$A0 + operand, $4C jump patterns, $4C at every bank end, arming
// opcodes before the hotspots, waveform pointer words for every digital
// route; streamed through the load port (both sides' init: upstream's DMA,
// daria_fe's F6), the console held in reset until both are done (the sticky
// hold). Inside an epoch: a console reset (anywhere: a call, a service, F6),
// a 7800-mode interval (tia_en and the driver off), a non-ARM scheme interval
// (CDF), and the calls and services the stream makes.
//
// The ARM agent (clk_arm) is the CPU behind upstream's controller: it halts,
// runs for a random time, writes cart RAM (random words: pointers,
// increments, waveform pointers, size words, NOTE tables, display data; never
// on the shared edge: cart_ram_tdp refuses it), and returns random counters
// and frequencies (each kept, new, or seed + 1). Each side gets its own seed
// back for a kept voice, as its own ARM would.
//
// Checks (design 12.1, 12.4; bench.md 7.5; design 9.5, 9.6):
//   L1    oe and d & oe at every shown pclk0 of a read (hidden: dout_hidden)
//   C1/C2 the scheme state at every pclk1 (DPC+ fetchers, params, pptr, LFSR,
//         bank, fast fetch, waveforms, call/service pending; CDF bank, mode,
//         fast/jump state, call pending)
//   C3    the pointer after every pointer_update; upstream's own cart RAM
//         word against its table copy (wb_lag)
//   C4    every word either side's 6507 side wrote in the cycle
//   K     the whole cart RAM (and the CDF tables) at each call's first quiet
//         point, every +full cycles and at the end of each epoch
//   R1    each call's payload, in order (posts against accepts)
//   R2    each service's fields (count by min()); R3 the destination ranges
//         once both sides are quiet
//   I1/I2 the cart RAM and the tables at the first edge both inits are done
//   T1/T2 the tick on the same edge; counters and frequencies every clock
//   A1    every audio register every clock, outside the class masks
//   A2    sel_up == sel_ram_sel every clock; A3 one owner per port, crb_use
//   the RTL assertions of 9.6 and the upstream-side ones (wb_drop, over32k,
//   ram_wr_noaccess), ret_unasked, commit_on_hidden, det_lock_a
// Classes (design 9.5), counted and resynced: short_phase1 (short_dout, q26
// repaired, grant_steal), merge_amp, ret_late / merge_race, dig_rom_lag,
// svc_audio_race, tbl_alias (upstream's table copy resynced from its RAM, as
// the ARM would rewrite it), rmw_call (rmw_seed, rmw_merge), rmw_svc,
// size_over32k, p32_reset (a_p32_late under a console reset: lane A O-1),
// pause_lane (a capture after a paused grant whose last unpaused edge had the select high).
//
// Plusargs: +seed=N +cycles=N (6507 cycles, default 400000) +epoch=N (50000)
// +only=all|dpc|cdf|dpc0|dpc1|cdf0|cdf1|cdfj|cdfjp +hook=0|1|2 (2: per epoch)
// +events=0/1 +stop=N (failures printed, 30) +maxfail=N (stop the run, 500)
// +full=N (whole-RAM compare every N cycles, 4096) +k_call +k_svc (per mille
// of register writes that are CALLFN FE/FF / CALLFUNCTION 1-2) +arm_wmax=N
// +slat_min/+slat_max (daria_fe's sample latency) +ddr_lat_min/max,
// +ddr_long, +ddr_long_max (upstream's DDR, fe_rand_up) +inj=K +inj_at=N
// (self-test faults) +strict=0/1 (no class masks; SELF's default) +self_ofs=N
// +rst_bus=1 (the CPU in reset reads anywhere, not only the stack page)
// (SELF: side B's DDR on another random stream) +trace_from=N +trace_to=M
// (+dbg_word=W: one cart RAM word's changes) +pg_* (phase_gen.svh).
// Passes iff every bad count is 0; $fatal otherwise.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_rand;
	import daria_fe_pkg::*;

	// ======================================================================================
	// clocks: clk_sys 70 ns, clk_arm 14 ns; every clk_sys rising edge is a clk_arm one
	// ======================================================================================
	logic clk_sys = 1'b0, clk_arm = 1'b0;
	always #35 clk_sys = ~clk_sys;
	always #7  clk_arm = ~clk_arm;

	// ======================================================================================
	// knobs and the bench's random stream
	// ======================================================================================
	longint n_cycles = 400000;
	longint epoch_len = 50000;
	int     seed = 1, stop_n = 30, maxfail = 500, events = 1, hook_mode = 2, full_every = 4096;
	int     k_call = 120, k_svc = 160, arm_wmax = 6, slat_min = 5, slat_max = 120;
	int     inj = 0, inj_at = 20000;
	int     rst_bus = 0;                 // 1: the CPU in reset reads anywhere (E3_rtl_issues.md issue 1)
	int     strict = 0;                  // no class may mask anything (the self-check's default)
	string  only = "all";
	longint tr_from = -1, tr_to = -1;

	logic [31:0] rs = 32'h1234_5678;
	function automatic int unsigned rnd(input int unsigned n);
		rs = rs ^ (rs << 13);
		rs = rs ^ (rs >> 17);
		rs = rs ^ (rs << 5);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	function automatic logic [7:0] rnd8();
		return 8'(rnd(256));
	endfunction
	function automatic logic [31:0] rnd32();
		return {rnd8(), rnd8(), rnd8(), rnd8()};
	endfunction
	function automatic bit pm(input int k);
		return rnd(1000) < k;
	endfunction

	// ======================================================================================
	// controls
	// ======================================================================================
	logic  [5:0] scheme = 6'd0;
	logic  [2:0] revision = 3'd0;
	logic        ldx = 1'b0, ldy = 1'b0, foff_en = 1'b0;
	logic  [7:0] foff = 8'h00;
	logic [31:0] cdfj_entry = 32'd0, cdfj_stack = 32'd0;
	logic [15:0] asz = 16'd0;
	logic [31:0] rom_size = 32'd32768;
	logic        tia_req = 1'b0;         // the bench's 2600 mode (7800-mode intervals: 0)
	logic        c1_svc_ok = 1'b1;       // C1 compares service_pending (no service burst in flight)
	logic        c1_call_ok = 1'b1;      // C1/C2 compare call_pending (no ret_late call: its X differs)
	logic        reset_in = 1'b1;
	logic        arm_reset = 1'b1;
	logic        pg_run = 1'b0;
	logic        cart_download = 1'b0, old_cart_download = 1'b0;
	logic        ld_wr = 1'b0;
	logic [24:0] ld_addr = 25'd0;
	logic  [7:0] ld_data = 8'h00;
	logic        hk_on = 1'b0;
	wire         is_dpc = scheme == SCHEME_DPCP;
	wire         is_cdf = scheme == SCHEME_CDF;
	wire         jplus  = is_cdf && revision[1:0] == 2'd3;
	wire         load_start = ~old_cart_download && cart_download;
	wire         load_end   = old_cart_download && ~cart_download;
	wire         load_valid = ld_wr && cart_download;

	logic [7:0] img [0:65535];           // the image (the tb ROM, the DDR, the FE ROM's first 32 KB)

	// ======================================================================================
	// the console reset: tb_daria's reset register, top.sv's reset_hold tail, the sticky hold
	// ======================================================================================
	logic reset_r = 1'b1, rhold = 1'b1, hold_reset = 1'b0;
	int   rtail = 0;
	wire  eff_reset = reset_r | rhold;
	// tia_en (and lock_ctrl): the 2600 driver. A console reset puts the 7800 back in its
	// own mode, so the 2600 path (access, the cart RAM strobes, the stall) is off in reset.
	wire  tia_en = tia_req && !eff_reset;
	wire  up_init_busy;
	wire  b_init_busy;
	always @(posedge clk_sys) begin
		old_cart_download <= cart_download;
		reset_r <= reset_in | cart_download | old_cart_download | up_init_busy | hold_reset;
		if (reset_r) begin
			rhold <= 1'b1;
			rtail <= 1 + int'(rnd(10));
		end else if (rtail > 0) rtail <= rtail - 1;
		else rhold <= 1'b0;
	end
	logic hd_seen = 1'b0, hd_rst_q = 1'b0, hd_loaded = 1'b0;
	int   hd_cnt = 0, hd_never = 0;
	always @(posedge clk_sys) begin
		hd_rst_q <= eff_reset;
		if (cart_download) hd_loaded <= 1'b1;
		if (load_start || (hd_loaded && eff_reset && !hd_rst_q)) begin
			hold_reset <= 1'b1;
			hd_seen <= 1'b0;
			hd_cnt <= 0;
		end else if (hold_reset) begin
			hd_cnt <= hd_cnt + 1;
			if (b_init_busy) hd_seen <= 1'b1;
			else if (hd_seen || hd_cnt >= (1 << 20)) begin
				hold_reset <= 1'b0;
				if (!hd_seen) hd_never <= hd_never + 1;
			end
		end
	end

	// ======================================================================================
	// the bus: fe_phase_gen with this bench's stream; the stall
	// ======================================================================================
	logic [12:0] nx_a = 13'h1000;
	logic        nx_rw = 1'b1;
	logic  [7:0] nx_d = 8'h00;
	wire         pclk1, pclk0, mapper_phi2, access, pause, load, stall_eff, ibusy, held;
	wire  [12:0] a_in;
	wire         rw;
	wire   [7:0] d_in;
	wire   [5:0] len1, len2;
	wire         up_call_busy, up_dma_busy, b_dma_busy;
	wire         stall6507 = tia_en && (up_call_busy || (!up_init_busy && (up_dma_busy || b_dma_busy)));
	fe_phase_gen #(.SEED(1), .EXT_BUS(1'b1)) pg (
		.clk_sys, .run(pg_run), .stall(stall6507), .driver_run(tia_en),
		.ext_a(nx_a), .ext_rw(nx_rw), .ext_d(nx_d),
		.pclk1, .pclk0, .mapper_phi2, .access, .a_in, .rw, .d_in, .pause, .load,
		.stall_eff, .ibusy, .held, .len1, .len2);

	// ======================================================================================
	// the ARM agent's CPU wires (both sides' controllers see the same CPU)
	// ======================================================================================
	logic        cpu_halted = 1'b1, return_fetch = 1'b0, state_ready = 1'b1;
	logic        cpu_en = 1'b0;
	logic [14:0] cpu_addr = 15'd0;
	logic [31:0] cpu_wdata = 32'd0;
	logic  [3:0] cpu_wstrb = 4'h0;
	logic [31:0] up_rdata, b_rdata;
	wire         up_cpu_acc, up_halt_req;
	wire   [7:0] up_do, up_oe;
	wire  [15:0] ram_size;

	// ======================================================================================
	// side U: upstream
	// ======================================================================================
	fe_rand_up u_up (
		.clk_sys, .clk_arm, .reset_arm(arm_reset), .reset(eff_reset), .pause, .mapper(scheme),
		.mapper_revision(revision), .cdf_ldx(ldx), .cdf_ldy(ldy), .cdf_fetch_offset_enable(foff_en),
		.cdf_fetch_offset(foff), .cdfj_entry, .cdfj_stack, .arm_audio_size_addr(asz), .rom_size,
		.a_in, .d_in, .rw, .phi1(pclk1), .phi2(mapper_phi2), .arm_driver_run(tia_en), .tia_en,
		.load_start, .load_addr(ld_addr), .load_valid, .load_data(ld_data), .load_end,
		.cpu_halted, .return_fetch, .state_ready, .state_rdata(up_rdata),
		.cpu_en, .cpu_write(1'b1), .cpu_addr, .cpu_wdata, .cpu_wstrb, .cpu_accepted(up_cpu_acc),
		.halt_req(up_halt_req), .lat_ofs(32'd0),
		.d_out(up_do), .oe(up_oe), .arm_call_busy(up_call_busy), .arm_dma_busy(up_dma_busy),
		.mapper_init_busy(up_init_busy), .mapper_ram_size(ram_size));

	function automatic logic [31:0] u_word(input int w);
		return {u_up.cart_ram.ram_lane[3].lane_ram.mem_q[w[14:0]], u_up.cart_ram.ram_lane[2].lane_ram.mem_q[w[14:0]],
			u_up.cart_ram.ram_lane[1].lane_ram.mem_q[w[14:0]], u_up.cart_ram.ram_lane[0].lane_ram.mem_q[w[14:0]]};
	endfunction
	function automatic logic [7:0] u_byte(input int a);
		logic [31:0] w;
		w = u_word(a >> 2);
		return w[8 * (a & 3) +: 8];
	endfunction
	// the CDF table layout (arm_mapper_tables.sv:104-121; design 2.4)
	function automatic int pb_now();
		return revision[1:0] == 2'd0 ? 'h1B8 : (revision[1:0] == 2'd1 ? 'h028 : 'h026);
	endfunction
	function automatic int ib_now();
		return revision[1:0] == 2'd0 ? 'h1DA : (revision[1:0] == 2'd1 ? 'h04A : 'h049);
	endfunction
	function automatic int ns_now();
		return revision[1] ? 35 : 34;
	endfunction
	function automatic int ram_words();
		return ram_size == 16'd32768 ? 8192 : 2048;
	endfunction

`define CMP(name, b, u) if ((b) != (u)) return $sformatf("%s %0h, upstream %0h", name, b, u);
`define UA u_up.mapper_audio

`ifdef SELF
	// ======================================================================================
	// side B: a second upstream cluster (the self-check)
	// ======================================================================================
	int self_ofs = 0;
	initial void'($value$plusargs("self_ofs=%d", self_ofs));
	wire   [7:0] b_do, b_oe8;
	wire         b_call_busy, b_cpu_acc, b_halt_req;
	fe_rand_up u_b (
		.clk_sys, .clk_arm, .reset_arm(arm_reset), .reset(eff_reset), .pause, .mapper(scheme),
		.mapper_revision(revision), .cdf_ldx(ldx), .cdf_ldy(ldy), .cdf_fetch_offset_enable(foff_en),
		.cdf_fetch_offset(foff), .cdfj_entry, .cdfj_stack, .arm_audio_size_addr(asz), .rom_size,
		.a_in, .d_in, .rw, .phi1(pclk1), .phi2(mapper_phi2), .arm_driver_run(tia_en), .tia_en,
		.load_start, .load_addr(ld_addr), .load_valid, .load_data(ld_data), .load_end,
		.cpu_halted, .return_fetch, .state_ready, .state_rdata(b_rdata),
		.cpu_en, .cpu_write(1'b1), .cpu_addr, .cpu_wdata, .cpu_wstrb, .cpu_accepted(b_cpu_acc),
		.halt_req(b_halt_req), .lat_ofs(32'(self_ofs)),
		.d_out(b_do), .oe(b_oe8), .arm_call_busy(b_call_busy), .arm_dma_busy(b_dma_busy),
		.mapper_init_busy(b_init_busy), .mapper_ram_size());
	wire         b_sel   = u_b.sel_ram_sel;
	wire         b_grant = u_b.audio_ram_grant;
	wire         b_tick  = u_b.mapper_audio.audio_tick;
	wire   [7:0] b_amp   = u_b.mapper_audio.amplitude;
	function automatic logic [31:0] b_word(input int w);
		return {u_b.cart_ram.ram_lane[3].lane_ram.mem_q[w[14:0]], u_b.cart_ram.ram_lane[2].lane_ram.mem_q[w[14:0]],
			u_b.cart_ram.ram_lane[1].lane_ram.mem_q[w[14:0]], u_b.cart_ram.ram_lane[0].lane_ram.mem_q[w[14:0]]};
	endfunction
	function automatic logic [31:0] b_ptr(input int i);
		return u_b.stream_tables.pointer_ram.mem_q[i];
	endfunction
	function automatic logic [31:0] b_inc(input int i);
		return u_b.stream_tables.increment_ram.mem_q[i];
	endfunction
	function automatic string b_c1();
		for (int i = 0; i < 8; i++) begin
			`CMP($sformatf("top[%0d]", i), u_b.dpcplus.top[i], u_up.dpcplus.top[i])
			`CMP($sformatf("bottom[%0d]", i), u_b.dpcplus.bottom[i], u_up.dpcplus.bottom[i])
			`CMP($sformatf("counter[%0d]", i), u_b.dpcplus.counter[i], u_up.dpcplus.counter[i])
			`CMP($sformatf("fractional[%0d]", i), u_b.dpcplus.fractional[i], u_up.dpcplus.fractional[i])
			`CMP($sformatf("increment[%0d]", i), u_b.dpcplus.increment[i], u_up.dpcplus.increment[i])
		end
		for (int i = 0; i < 4; i++) `CMP($sformatf("params[%0d]", i), u_b.dpcplus.params[i], u_up.dpcplus.params[i])
		`CMP("parameter_pointer", u_b.dpcplus.parameter_pointer, u_up.dpcplus.parameter_pointer)
		for (int i = 0; i < 3; i++) `CMP($sformatf("waveform[%0d]", i), u_b.dpcplus.waveform[i], u_up.dpcplus.waveform[i])
		`CMP("random_number", u_b.dpcplus.random_number, u_up.dpcplus.random_number)
		`CMP("bank", u_b.dpcplus.bank, u_up.dpcplus.bank)
		`CMP("fast_fetch", u_b.dpcplus.fast_fetch, u_up.dpcplus.fast_fetch)
		`CMP("fast_pending", u_b.dpcplus.fast_pending, u_up.dpcplus.fast_pending)
		`CMP("call_pending", u_b.dpcplus.call_pending, u_up.dpcplus.call_pending)
		// with other DDR latencies (+self_ofs) the pending flag is a timing detail during a
		// service burst, as for daria_fe (C1 below); strict: always compared
		if (strict != 0 || c1_svc_ok)
			`CMP("service_pending", u_b.dpcplus.service_pending, u_up.dpcplus.service_pending)
		return "";
	endfunction
	function automatic string b_c2();
		`CMP("bank", u_b.cdf.bank, u_up.cdf.bank)
		`CMP("mode", u_b.cdf.mode, u_up.cdf.mode)
		`CMP("fast_pending", u_b.cdf.fast_pending, u_up.cdf.fast_pending)
		if (u_up.cdf.fast_pending) `CMP("fast_expected_address", u_b.cdf.fast_expected_address, u_up.cdf.fast_expected_address)
		`CMP("jump_remaining", u_b.cdf.jump_remaining, u_up.cdf.jump_remaining)
		if (u_up.cdf.jump_remaining != 2'd0) begin
			`CMP("expected_address", u_b.cdf.expected_address, u_up.cdf.expected_address)
			`CMP("jump_stream", u_b.cdf.jump_stream, u_up.cdf.jump_stream)
		end
		`CMP("call_pending", u_b.cdf.call_pending, u_up.cdf.call_pending)
		return "";
	endfunction
	`define BA u_b.mapper_audio
	function automatic string b_a1_tick();
		`CMP("accum", `BA.tick_accum, `UA.tick_accum)
		`CMP("tick", `BA.audio_tick, `UA.audio_tick)
		`CMP("note_voice", `BA.note_voice, `UA.note_voice)
		`CMP("note_value", `BA.note_value, `UA.note_value)
		return "";
	endfunction
	function automatic string b_a1_cf();
		`CMP("counter0", `BA.counter0, `UA.counter0)
		`CMP("counter1", `BA.counter1, `UA.counter1)
		`CMP("counter2", `BA.counter2, `UA.counter2)
		`CMP("frequency0", `BA.frequency0, `UA.frequency0)
		`CMP("frequency1", `BA.frequency1, `UA.frequency1)
		`CMP("frequency2", `BA.frequency2, `UA.frequency2)
		return "";
	endfunction
	function automatic string b_a1_rep();
		`CMP("state", `BA.state, `UA.state)
		for (int v = 0; v < 3; v++) `CMP($sformatf("refresh_counter[%0d]", v), `BA.refresh_counter[v], `UA.refresh_counter[v])
		`CMP("refresh_pending", `BA.refresh_pending, `UA.refresh_pending)
		`CMP("note_pending", `BA.note_pending, `UA.note_pending)
		`CMP("voice", `BA.voice, `UA.voice)
		`CMP("sample_sum", `BA.sample_sum[7:0], `UA.sample_sum[7:0])
		`CMP("waveform_shift", `BA.waveform_shift, `UA.waveform_shift)
		`CMP("waveform_offset", `BA.waveform_offset, `UA.waveform_offset)
		`CMP("digital_address", `BA.digital_address, `UA.digital_address)
		`CMP("digital_low_nibble", `BA.digital_low_nibble, `UA.digital_low_nibble)
		`CMP("digital_ram_addr", `BA.digital_ram_addr, `UA.digital_ram_addr)
		`CMP("digital_sample", `BA.digital_sample, `UA.digital_sample)
		`CMP("amplitude", `BA.amplitude, `UA.amplitude)
		`CMP("ram_en", `BA.ram_en, `UA.ram_en)
		if (`UA.ram_en) `CMP("ram_addr", `BA.ram_addr, `UA.ram_addr)
		`CMP("grant", u_b.audio_ram_grant, u_up.audio_ram_grant)
		return "";
	endfunction
	function automatic logic b_aud_quiet();
		return `UA.state == 4'd0 && `BA.state == 4'd0 && !`UA.refresh_pending && !`BA.refresh_pending &&
			!`UA.note_pending && !`BA.note_pending && !u_up.arm_sample_busy && !u_b.arm_sample_busy;
	endfunction
	task automatic b_deposit(input logic cf);
		`BA.state = `UA.state;
		`BA.refresh_pending = `UA.refresh_pending;
		`BA.note_pending = `UA.note_pending;
		`BA.voice = `UA.voice;
		`BA.sample_sum = `UA.sample_sum;
		`BA.waveform_shift = `UA.waveform_shift;
		`BA.waveform_offset = `UA.waveform_offset;
		`BA.digital_address = `UA.digital_address;
		`BA.digital_low_nibble = `UA.digital_low_nibble;
		`BA.digital_ram_addr = `UA.digital_ram_addr;
		`BA.digital_sample = `UA.digital_sample;
		`BA.amplitude = `UA.amplitude;
		for (int v = 0; v < 3; v++) `BA.refresh_counter[v] = `UA.refresh_counter[v];
		if (cf) begin
			`BA.tick_accum = `UA.tick_accum;
			`BA.counter0 = `UA.counter0;
			`BA.counter1 = `UA.counter1;
			`BA.counter2 = `UA.counter2;
			`BA.frequency0 = `UA.frequency0;
			`BA.frequency1 = `UA.frequency1;
			`BA.frequency2 = `UA.frequency2;
		end
	endtask
	function automatic logic [255:0] b_payload();     // B's payload at its accept
		return {u_b.arm_audio_frequency2, u_b.arm_audio_frequency1, u_b.arm_audio_frequency0,
			u_b.arm_audio_counter2, u_b.arm_audio_counter1, u_b.arm_audio_counter0,
			u_b.arm_call_stack, u_b.arm_call_entry[31:1], u_b.arm_call_thumb};
	endfunction
	wire b_accept = u_b.arm_call_request && u_b.arm_call_ready;
	function automatic logic [51:0] b_svc();
		return {u_b.dpcplus.service_fill, u_b.dpcplus.service_source, u_b.dpcplus.service_dest,
			u_b.dpcplus.service_count, u_b.dpcplus.service_value};
	endfunction
	wire b_svc_pend = u_b.dpcplus.service_pending;
	wire b_svc_run  = u_b.arm_dma_busy && !u_b.mapper_init_busy;
	wire b_svc_hold = u_b.dpcplus.service_pending;
	`undef BA
`else
	// ======================================================================================
	// side B: daria_fe + daria_mem (mode A)
	// ======================================================================================
	// cart_win (bup_capture.sv:141-164): the download, then DRAIN = 64 clocks
	logic        c_open = 1'b0, cw_q = 1'b0;
	logic  [6:0] c_drain = 7'd0;
	always @(posedge clk_sys) begin
		if (cart_download && !cw_q) begin
			c_open <= 1'b1;
			c_drain <= 7'd0;
		end else if (!cart_download && cw_q && c_open) begin
			c_open <= 1'b0;
			c_drain <= 7'd64;
		end else if (c_drain != 7'd0)
			c_drain <= c_drain - 7'd1;
		cw_q <= cart_download;
	end
	wire         cart_win = cart_download || c_open || c_drain > 7'd1;
	// cpu_ready, design 6.6: upstream's call_ready without call_busy
	wire         cpu_ready = u_up.arm_online_sync2 && u_up.shadow_ready_sync2 && !eff_reset;
	// the ARM-write mirror (bench.md 7.4.3): the CPU's word, on the edge cart_ram_tdp takes it
	wire  [31:0] fe_d_addr = {15'd0, cpu_addr, 2'b00};
	wire         fe_ram_we = up_cpu_acc;
	// the returns (state RAM F8-FD, port A) and ret_tog: the agent below
	logic        fe_sta_we;
	logic  [7:0] fe_sta_a;
	logic [31:0] fe_sta_wd;
	logic        ret_tog = 1'b0;
	// the sample port: the wrapper's answer after a random latency
	logic        smp_ack = 1'b0;
	logic  [7:0] smp_data = 8'h00;
	// the hook
	wire [191:0] hk_ret = {u_up.arm_audio_frequency2_return, u_up.arm_audio_frequency1_return,
		u_up.arm_audio_frequency0_return, u_up.arm_audio_counter2_return,
		u_up.arm_audio_counter1_return, u_up.arm_audio_counter0_return};

	wire  [12:0] fu_fea_addr, fu_feb_addr, fu_crb_addr;
	wire  [31:0] fu_fea_q, fu_feb_q, fu_crb_q, fu_stb_q, fu_crb_wd, fu_stb_wd;
	wire         fu_crb_we, fu_stb_we;
	wire   [3:0] fu_crb_be, fu_stb_be;
	wire   [7:0] fu_stb_addr;
	wire         fe_cap_we = load_valid && ld_addr < 25'd32768;
	daria_mem #(.WIN_KB(32)) fe_mem (
		.clk_arm, .clk_sys,
		.rom_addr(15'd0), .win_qa(), .d_addr(fe_d_addr), .win_qb(),
		.ram_we(fe_ram_we), .ram_be(cpu_wstrb), .ram_wdata(cpu_wdata), .ram_q(),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(fe_sta_a), .sta_we(fe_sta_we), .sta_wd(fe_sta_wd), .sta_q(),
		.cap_we(fe_cap_we), .cap_addr(ld_addr[14:0]), .cap_data(ld_data),
		.fea_addr(fu_fea_addr), .fea_q(fu_fea_q), .feb_addr(fu_feb_addr), .feb_q(fu_feb_q),
		.crb_addr(fu_crb_addr), .crb_we(fu_crb_we), .crb_be(fu_crb_be), .crb_wd(fu_crb_wd), .crb_q(fu_crb_q),
		.stb_addr(fu_stb_addr), .stb_we(fu_stb_we), .stb_be(fu_stb_be), .stb_wd(fu_stb_wd), .stb_q(fu_stb_q));

	wire         fe_call_tog, fe_smp_req, fe_oe, fe_call_busy;
	wire  [18:0] fe_smp_addr;
	wire   [7:0] fe_do;
	daria_fe u_fe (
		.clk_sys, .clk_arm,
		.cart_reset(eff_reset), .pause, .a_in, .d_in, .rw, .pclk1, .pclk0, .access,
		.scheme, .revision, .cdf_ldx(ldx), .cdf_ldy(ldy), .fetch_off_en(foff_en), .fetch_off(foff),
		.cdfj_entry, .cdfj_stack, .audio_size_addr(asz), .rom_size, .ram32(ram_size == 16'd32768),
		.load_start, .load_end, .cart_win, .cpu_ready, .ret_tog, .call_tog(fe_call_tog),
		.smp_req(fe_smp_req), .smp_addr(fe_smp_addr), .smp_ack, .smp_data,
		.fe_do, .fe_oe, .arm_call_busy(fe_call_busy), .arm_dma_busy(b_dma_busy), .init_busy(b_init_busy),
		.fea_addr(fu_fea_addr), .fea_q(fu_fea_q), .feb_addr(fu_feb_addr), .feb_q(fu_feb_q),
		.crb_addr(fu_crb_addr), .crb_we(fu_crb_we), .crb_be(fu_crb_be), .crb_wd(fu_crb_wd), .crb_q(fu_crb_q),
		.stb_addr(fu_stb_addr), .stb_we(fu_stb_we), .stb_be(fu_stb_be), .stb_wd(fu_stb_wd), .stb_q(fu_stb_q),
		.hk_en(hk_on), .hk_stb(u_up.arm_call_done), .hk_ret);

	wire   [7:0] b_do    = fe_do;
	wire   [7:0] b_oe8   = {8{fe_oe}};
	wire         b_sel   = u_fe.sel_up;
	wire         b_grant = u_fe.aud_take;
	wire         b_tick  = u_fe.u_audio.tick;
	wire   [7:0] b_amp   = u_fe.u_audio.amplitude;
	function automatic logic [31:0] b_word(input int w);
		return fe_mem.cart_ram.mem_q[w[12:0]];
	endfunction
	function automatic logic [31:0] b_ptr(input int i);
		return b_word(pb_now() + i);
	endfunction
	function automatic logic [31:0] b_inc(input int i);
		return b_word(ib_now() + i);
	endfunction
	function automatic logic [31:0] b_sw(input int w);
		return fe_mem.state_ram.mem_q[w[7:0]];
	endfunction
	// C1 (fe_taps.svh's ft_c1): fetchers from the state RAM words (masks of 4.2)
	function automatic string b_c1();
		logic [31:0] w0, w1, wp;
		for (int i = 0; i < 8; i++) begin
			w0 = b_sw(2 * i);
			w1 = b_sw(2 * i + 1);
			`CMP($sformatf("top[%0d]", i), w0[23:16], u_up.dpcplus.top[i])
			`CMP($sformatf("bottom[%0d]", i), w0[31:24], u_up.dpcplus.bottom[i])
			`CMP($sformatf("counter[%0d]", i), w0[11:0], u_up.dpcplus.counter[i])
			`CMP($sformatf("fractional[%0d]", i), w1[19:0], u_up.dpcplus.fractional[i])
			`CMP($sformatf("increment[%0d]", i), w1[31:24], u_up.dpcplus.increment[i])
		end
		wp = b_sw(16);
		for (int i = 0; i < 4; i++) `CMP($sformatf("params[%0d]", i), wp[8 * i +: 8], u_up.dpcplus.params[i])
		`CMP("parameter_pointer (pptr)", u_fe.u_core.pptr, u_up.dpcplus.parameter_pointer)
		for (int i = 0; i < 3; i++) `CMP($sformatf("waveform[%0d]", i), u_fe.u_core.wave[i], u_up.dpcplus.waveform[i])
		`CMP("random_number (rnd)", u_fe.u_core.rnd, u_up.dpcplus.random_number)
		`CMP("bank", u_fe.u_core.bank, u_up.dpcplus.bank)
		`CMP("fast_fetch (ff_en)", u_fe.u_core.ff_en, u_up.dpcplus.fast_fetch)
		`CMP("fast_pending (fpend)", u_fe.u_core.fpend, u_up.dpcplus.fast_pending)
		if (c1_call_ok) `CMP("call_pending (pend_up)", u_fe.u_call.pend_up, u_up.dpcplus.call_pending)
		// the pending flag is a timing detail while a service burst is in flight on either
		// side (bench.md 7.5 C1: then the accepts are compared in order, R2): the two
		// engines run at different speeds, and a queued service is taken when each is free
		if (c1_svc_ok)
			`CMP("service_pending (svc_pend)", u_fe.u_core.svc_pend, u_up.dpcplus.service_pending)
		return "";
	endfunction
	function automatic string b_c2();
		`CMP("bank", u_fe.u_core.bank, u_up.cdf.bank)
		`CMP("mode", u_fe.u_core.mode, u_up.cdf.mode)
		`CMP("fast_pending (fpend)", u_fe.u_core.fpend, u_up.cdf.fast_pending)
		if (u_up.cdf.fast_pending) `CMP("fast_expected_address (fexp)", u_fe.u_core.fexp, u_up.cdf.fast_expected_address)
		`CMP("jump_remaining (jr)", u_fe.u_core.jr, u_up.cdf.jump_remaining)
		if (u_up.cdf.jump_remaining != 2'd0) begin
			`CMP("expected_address (jexp)", u_fe.u_core.jexp, u_up.cdf.expected_address)
			`CMP("jump_stream (jstream)", u_fe.u_core.jstream, u_up.cdf.jump_stream)
		end
		if (c1_call_ok) `CMP("call_pending (pend_up)", u_fe.u_call.pend_up, u_up.cdf.call_pending)
		return "";
	endfunction
	// A1 (fe_taps.svh's three groups)
	function automatic string b_a1_tick();
		`CMP("accum", u_fe.u_audio.accum, `UA.tick_accum)
		`CMP("tick", u_fe.u_audio.tick, `UA.audio_tick)
		`CMP("nv (note_voice)", u_fe.u_audio.nv, `UA.note_voice)
		`CMP("nval (note_value)", u_fe.u_audio.nval, `UA.note_value)
		return "";
	endfunction
	function automatic string b_a1_cf();
		`CMP("counter[0]", u_fe.u_audio.counter[0], `UA.counter0)
		`CMP("counter[1]", u_fe.u_audio.counter[1], `UA.counter1)
		`CMP("counter[2]", u_fe.u_audio.counter[2], `UA.counter2)
		`CMP("freq[0]", u_fe.u_audio.freq[0], `UA.frequency0)
		`CMP("freq[1]", u_fe.u_audio.freq[1], `UA.frequency1)
		`CMP("freq[2]", u_fe.u_audio.freq[2], `UA.frequency2)
		return "";
	endfunction
	function automatic string b_a1_rep();
		`CMP("st (one-hot; upstream's state as 1 << state)", u_fe.u_audio.st, 12'd1 << `UA.state)
		for (int v = 0; v < 3; v++)
			`CMP($sformatf("rc[%0d] (refresh_counter)", v), u_fe.u_audio.rc[v], `UA.refresh_counter[v])
		`CMP("rp (refresh_pending)", u_fe.u_audio.rp, `UA.refresh_pending)
		`CMP("np (note_pending)", u_fe.u_audio.np, `UA.note_pending)
		`CMP("voice", u_fe.u_audio.voice, `UA.voice)
		`CMP("ssum (sample_sum[7:0])", u_fe.u_audio.ssum, `UA.sample_sum[7:0])
		`CMP("wsh (waveform_shift)", u_fe.u_audio.wsh, `UA.waveform_shift)
		`CMP("woff (waveform_offset)", u_fe.u_audio.woff, `UA.waveform_offset)
		`CMP("dig_addr (digital_address)", u_fe.u_audio.dig_addr, `UA.digital_address)
		`CMP("dig_low (digital_low_nibble)", u_fe.u_audio.dig_low, `UA.digital_low_nibble)
		`CMP("dig_ram (digital_ram_addr)", u_fe.u_audio.dig_ram, `UA.digital_ram_addr)
		`CMP("dig_smp (digital_sample)", u_fe.u_audio.dig_smp, `UA.digital_sample)
		`CMP("amplitude", u_fe.u_audio.amplitude, `UA.amplitude)
		`CMP("aud_issue (ram_en)", u_fe.aud_issue, `UA.ram_en)
		if (`UA.ram_en) `CMP("aud_addr (ram_addr)", {2'b00, u_fe.aud_addr}, `UA.ram_addr)
		`CMP("aud_take (audio_ram_grant)", u_fe.aud_take, u_up.audio_ram_grant)
		return "";
	endfunction
	function automatic logic b_aud_quiet();
		return `UA.state == 4'd0 && u_fe.u_audio.st == 12'd1 && !`UA.refresh_pending && !u_fe.u_audio.rp &&
			!`UA.note_pending && !u_fe.u_audio.np && !u_fe.u_audio.tdef && !u_fe.mwin &&
			!u_fe.u_audio.busy_l && !u_fe.u_audio.busy_r && !u_up.arm_sample_busy;
	endfunction
	task automatic b_deposit(input logic cf);              // fe_taps.svh's fe_deposit_audio
		u_fe.u_audio.st = 12'd1 << `UA.state;
		u_fe.u_audio.rp = `UA.refresh_pending;
		u_fe.u_audio.np = `UA.note_pending;
		u_fe.u_audio.nv = `UA.note_voice;
		u_fe.u_audio.nval = `UA.note_value;
		u_fe.u_audio.voice = `UA.voice;
		u_fe.u_audio.ssum = `UA.sample_sum[7:0];
		u_fe.u_audio.wsh = `UA.waveform_shift;
		u_fe.u_audio.woff = `UA.waveform_offset;
		u_fe.u_audio.dig_addr = `UA.digital_address;
		u_fe.u_audio.dig_low = `UA.digital_low_nibble;
		u_fe.u_audio.dig_ram = `UA.digital_ram_addr;
		u_fe.u_audio.dig_smp = `UA.digital_sample;
		u_fe.u_audio.amplitude = `UA.amplitude;
		for (int v = 0; v < 3; v++) u_fe.u_audio.rc[v] = `UA.refresh_counter[v];
		if (cf) begin
			u_fe.u_audio.accum = `UA.tick_accum;
			u_fe.u_audio.counter[0] = `UA.counter0;
			u_fe.u_audio.counter[1] = `UA.counter1;
			u_fe.u_audio.counter[2] = `UA.counter2;
			u_fe.u_audio.freq[0] = `UA.frequency0;
			u_fe.u_audio.freq[1] = `UA.frequency1;
			u_fe.u_audio.freq[2] = `UA.frequency2;
		end
	endtask
	function automatic logic [255:0] b_posted();           // the call block F0-F7
		logic [255:0] p;
		for (int i = 0; i < 8; i++) p[32 * i +: 32] = b_sw('hF0 + i);
		return p;
	endfunction
	// R2: the latched service in upstream's terms (fe_taps.svh's ft_svc_fe; count by min())
	function automatic logic [51:0] b_svc();
		logic [12:0] dav;
		logic [16:0] off, sav;
		logic  [7:0] fc, cc;
		dav = 13'h1000 - (u_fe.u_core.svc_dst - 13'h0C00);
		off = u_fe.u_core.svc_src - 17'h00C00;
		sav = 17'h07400 - off;
		fc = (dav < {5'd0, u_fe.u_core.svc_rem}) ? dav[7:0] : u_fe.u_core.svc_rem;
		cc = (off >= 17'h07400) ? 8'd0 : ((sav < {9'd0, fc}) ? sav[7:0] : fc);
		return {u_fe.u_core.svc_fill, 2'b00, u_fe.u_core.svc_src, 2'b00, u_fe.u_core.svc_dst,
			u_fe.u_core.svc_fill ? fc : cc, u_fe.u_core.svc_val};
	endfunction
	wire b_svc_pend = u_fe.u_core.svc_pend;
	wire b_svc_run  = u_fe.u_copy.run;
	wire b_svc_hold = u_fe.u_core.svc_hold;
`endif
	function automatic logic [255:0] u_payload();          // upstream's payload at its accept
		return {u_up.arm_audio_frequency2, u_up.arm_audio_frequency1, u_up.arm_audio_frequency0,
			u_up.arm_audio_counter2, u_up.arm_audio_counter1, u_up.arm_audio_counter0,
			u_up.arm_call_stack, u_up.arm_call_entry[31:1], u_up.arm_call_thumb};
	endfunction
	function automatic logic [51:0] u_svc();
		return {u_up.dpcplus.service_fill, u_up.dpcplus.service_source, u_up.dpcplus.service_dest,
			u_up.dpcplus.service_count, u_up.dpcplus.service_value};
	endfunction
	function automatic logic u_dispatch();                  // a refresh starts at this edge (AUD:226-240)
		return `UA.state == 4'd0 && `UA.refresh_pending && !(`UA.note_pending && `UA.family == 2'd1);
	endfunction
	wire up_accept = u_up.arm_call_request && u_up.arm_call_ready;

	// ======================================================================================
	// the ARM agent: the CPU behind the controllers (clk_arm)
	// ======================================================================================
	localparam logic [3:0] CTRL_RUNNING = 4'd5, CTRL_READ_AUDIO = 4'd7, CTRL_CAPTURE = 4'd8;
	// a call's returns: per word (counters 0-2, frequencies 0-2) kept (0), new (1) or seed + 1 (2)
	logic [1:0]  sp_k [0:63][0:5];
	logic [31:0] sp_v [0:63][0:5];
	function automatic logic [31:0] ret_word(input logic [1:0] k, input logic [31:0] v, input logic [31:0] s);
		return k == 2'd0 ? s : (k == 2'd1 ? v : s + 32'd1);
	endfunction
	int          ag_ncall = 0;           // upstream calls started since the last reset (RUNNING entries)
	logic        ag_run = 1'b0, ag_ret = 1'b0;
	int          ag_left = 0, ag_wleft = 0, ag_gap = 0, ag_hcnt = 0;
	logic  [7:0] quiet_cnt = 8'd0;       // clk_sys: clocks since the 6507 side last committed or wrote
	longint      n_arm_wr = 0, n_arm_wr_tbl = 0, n_agent_calls = 0;
	int          ag_bad_acc = 0;
	always @(posedge clk_sys)
		if (access || (pclk0 && !rw && tia_en)) quiet_cnt <= 8'd0;
		else if (quiet_cnt != 8'hFF) quiet_cnt <= quiet_cnt + 8'd1;

	// the word an ARM write aims at, and its value
	function automatic logic [14:0] arm_target();
		int r, lim;
		logic [14:0] w;
		lim = ram_words();
		r = int'(rnd(100));
		if (is_cdf && r < 30) w = 15'(pb_now() + int'(rnd(ns_now())));
		else if (is_cdf && r < 40) w = 15'(ib_now() + int'(rnd(ns_now())));
		else if (is_cdf && r < 55) w = 15'((revision[1:0] == 2'd0 ? 'h1FC : 'h6C) + int'(rnd(3)));
		else if (is_cdf && r < 62 && asz != 16'd0) w = 15'((int'(asz) >> 2) + int'(rnd(3)));
		else if (is_dpc && r < 30) w = 15'h700 + 15'(rnd(256));       // NOTE frequency table ($1C00)
		else if (is_dpc && r < 60) w = 15'h300 + 15'(rnd(1024));      // waveform and display data ($C00)
		else w = 15'(rnd(lim));
		return w % 15'(lim);
	endfunction
	function automatic logic [31:0] pointer_value();
		int r;
		r = int'(rnd(100));
		if (r < 35) return rnd(rom_size > 32768 ? int'(rom_size) : 32768);                  // ROM (local / remote)
		if (r < 50) return 32'h4000_0000 + rnd(int'(ram_size));                           // the RAM window
		if (r < 60) return rnd32();                                                       // out of range
		if (r < 80) return 32'h4000_0800 + rnd(int'(ram_size));                           // a waveform in RAM
		return {20'h40000, 12'(rnd(4096))};
	endfunction

	always @(posedge clk_arm) begin
		state_ready <= pm(750);
		return_fetch <= 1'b0;
		// the CPU halts a few edges after halt_req; it runs while RUNNING
		if (up_halt_req) begin
			if (!cpu_halted) begin
				if (ag_hcnt > 0) ag_hcnt <= ag_hcnt - 1;
				else cpu_halted <= 1'b1;
			end
		end else begin
			cpu_halted <= 1'b0;
			ag_hcnt <= int'(rnd(5));
		end
`ifdef SELF
		if (up_cpu_acc != b_cpu_acc) ag_bad_acc <= ag_bad_acc + 1;
`endif
		if (arm_reset || u_up.mapper_reset_arm) begin
			ag_run <= 1'b0;
			ag_ret <= 1'b0;
			cpu_en <= 1'b0;
			ag_ncall <= 0;
		end else if (u_up.control_state == CTRL_RUNNING) begin
			if (!ag_run) begin                // the call starts: its length, writes and returns
				int n, r;
				ag_run <= 1'b1;
				ag_ret <= 1'b0;
				n = ag_ncall + 1;
				ag_ncall <= n;
				n_agent_calls++;
				r = int'(rnd(100));
				ag_left <= (r < 15) ? int'(rnd(40)) : ((r < 85) ? 40 + int'(rnd(600)) : 600 + int'(rnd(3500)));
				ag_wleft <= pm(300) ? 0 : int'(rnd(arm_wmax + 1));
				ag_gap <= int'(rnd(30));
				for (int i = 0; i < 6; i++) begin
					int q;
					q = int'(rnd(100));
					if (i < 3) sp_k[n % 64][i] = (q < 40) ? 2'd0 : ((q < 90) ? 2'd1 : 2'd2);
					else sp_k[n % 64][i] = (q < 30) ? 2'd0 : 2'd1;
					sp_v[n % 64][i] = (i >= 3 && pm(500)) ? 32'(rnd(32'h0010_0000)) : rnd32();
				end
			end else begin
				if (cpu_en) begin
					if (up_cpu_acc) begin
						cpu_en <= 1'b0;
						ag_wleft <= ag_wleft - 1;
						ag_gap <= int'(rnd(40));
						n_arm_wr++;
					end
				end else if (ag_wleft > 0 && ag_gap == 0 && stall6507 && pg.taken && quiet_cnt >= 8'd4) begin
					// the 6507 is held (every pclk0 hidden since the taken one) and the taken
					// cycle's post actions are done: as on the hardware, the ARM writes only then
					int w, wb;
					w = int'(arm_target());
					wb = revision[1:0] == 2'd0 ? 'h1FC : 'h6C;      // the waveform pointer words
					cpu_en <= 1'b1;
					cpu_addr <= 15'(w);
					cpu_wstrb <= pm(800) ? 4'hF : 4'(1 + rnd(15));
					if (is_cdf && w >= wb && w < wb + 3) cpu_wdata <= pointer_value();
					else cpu_wdata <= rnd32();
					if (is_cdf && ((w >= pb_now() && w < pb_now() + ns_now()) || (w >= ib_now() && w < ib_now() + ns_now()) ||
					               (w >= wb && w < wb + 3))) n_arm_wr_tbl++;
				end else if (ag_gap > 0) ag_gap <= ag_gap - 1;
				if (ag_left > 0) ag_left <= ag_left - 1;
				else if (ag_wleft == 0 && !cpu_en && !ag_ret) begin
					return_fetch <= 1'b1;
					ag_ret <= 1'b1;
				end
			end
		end else begin
			ag_run <= 1'b0;
			cpu_en <= 1'b0;
		end
	end
	// the returns the CPU presents (state_rdata: FIQ R8-R13 at audio_read_index)
	always_comb begin
		int n, i;
		n = ag_ncall % 64;
		i = int'(u_up.audio_read_index);
		if (i > 5) i = 5;
		up_rdata = ret_word(sp_k[n][i], sp_v[n][i],
			i < 3 ? u_up.active_audio_counter[i] : u_up.active_audio_frequency[i - 3]);
`ifdef SELF
		i = int'(u_b.audio_read_index);
		if (i > 5) i = 5;
		b_rdata = ret_word(sp_k[n][i], sp_v[n][i],
			i < 3 ? u_b.active_audio_counter[i] : u_b.active_audio_frequency[i - 3]);
`else
		b_rdata = 32'd0;
`endif
	end

`ifndef SELF
	// ---- daria_fe's call port in mode A (bench.md 7.4.4; design 6.6) ----------------------------
	// ret_tog per call number: it flips with upstream's complete_toggle, on the same
	// clk_arm edge, when u_fe flipped call_tog for that call before upstream's first
	// capture edge (the six returns are written into F8-FD on the six capture edges,
	// as the controller takes them); else at the sixth clk_arm edge after both have
	// happened, the six words written on those edges (ret_late). Each side gets its
	// own seed back for a kept voice, as its own ARM would.
	int          fe_flips = 0;           // clk_sys: u_fe's call_tog flips since the last reset
	logic        fe_tog_q = 1'b0;
	always @(posedge clk_sys) begin
		fe_tog_q <= fe_call_tog;
		if (eff_reset) fe_flips <= 0;
		else if (fe_call_tog != fe_tog_q) fe_flips <= fe_flips + 1;
	end
	int          up_done = 0, ret_n = 0, ret_late_n = 0, ret_sync_n = 0, late_i = 0;
	logic        late_on = 1'b0;
	logic        cap_sync = 1'b0;        // this capture run writes u_fe's F8-FD and flips ret_tog
	logic [31:0] rw_cap [0:5];
	logic [31:0] rw_late [0:5];
	assign fe_sta_we = (cap_sync && u_up.control_state == CTRL_CAPTURE) || late_on;
	assign fe_sta_a  = 8'hF8 + 8'(late_on ? late_i : int'(u_up.audio_read_index));
	assign fe_sta_wd = late_on ? rw_late[late_i] : rw_cap[u_up.audio_read_index > 3'd5 ? 5 : int'(u_up.audio_read_index)];
	always @(posedge clk_arm) begin
		if (eff_reset || u_up.mapper_reset_arm || arm_reset) begin
			up_done <= 0;                    // a call cut by a console reset is abandoned on both sides
			ret_n <= 0;
			late_on <= 1'b0;
			late_i <= 0;
			cap_sync <= 1'b0;
		end else begin
			// the controller enters its first capture state at this edge (READ_AUDIO, index 0,
			// state_ready): u_fe gets the returns on upstream's edges if it posted this call
			if (u_up.control_state == CTRL_READ_AUDIO && u_up.audio_read_index == 3'd0 && state_ready) begin
				logic ok;
				ok = (ret_n == up_done) && (fe_flips > up_done) && !late_on;
				cap_sync <= ok;
				if (ok)
					for (int i = 0; i < 6; i++)
						rw_cap[i] = ret_word(sp_k[(up_done + 1) % 64][i], sp_v[(up_done + 1) % 64][i], b_sw('hF2 + i));
			end
			if (u_up.control_state == CTRL_CAPTURE && u_up.audio_read_index == 3'd5) begin
				up_done <= up_done + 1;
				cap_sync <= 1'b0;
				if (cap_sync) begin
					ret_tog <= ~ret_tog;
					ret_n <= ret_n + 1;
					ret_sync_n <= ret_sync_n + 1;
				end
			end
			if (late_on) begin
				if (late_i == 5) begin
					ret_tog <= ~ret_tog;
					ret_n <= ret_n + 1;
					ret_late_n <= ret_late_n + 1;
					late_on <= 1'b0;
				end else late_i <= late_i + 1;
			end else if (!cap_sync && ret_n < up_done && ret_n < fe_flips) begin
				late_on <= 1'b1;
				late_i <= 0;
				for (int i = 0; i < 6; i++)
					rw_late[i] = ret_word(sp_k[(ret_n + 1) % 64][i], sp_v[(ret_n + 1) % 64][i], b_sw('hF2 + i));
			end
		end
	end

	// ---- the sample port (bench.md 7.4.5): img[smp_addr] after +slat_min..+slat_max clk_sys ----
	logic        smp_rq = 1'b0;
	logic [18:0] smp_a = 19'd0;
	int          smp_left = -1;
	always @(posedge clk_sys) begin
		smp_rq <= fe_smp_req;
		if (fe_smp_req != smp_rq) begin
			smp_a <= fe_smp_addr;
			smp_left <= slat_min + int'(rnd(slat_max - slat_min + 1));
		end else if (smp_left > 0) smp_left <= smp_left - 1;
		else if (smp_left == 0) begin
			smp_data <= img[smp_a[15:0]];
			smp_ack <= ~smp_ack;
			smp_left <= -1;
		end
	end
`endif

	// ======================================================================================
	// the program-like bus stream (tb_fe_core's, extended)
	// ======================================================================================
	logic [12:0] pc = 13'h1000;
	logic [12:0] last_a = 13'h1000;
	int          fresh = 0;
	int          burst = 0, burst_n = 0;
	logic  [7:0] burst_d = 8'h00;
	logic        prev_w = 1'b0;          // the last cycle was a write: the next is a read (6502)
	logic        burst_run = 1'b0;       // the last cycle was a write of a run that continues
	logic        fresh_now = 1'b0;
	int          rd_run = 0;             // reads since the last write
	logic [11:0] arm_off [0:2][0:7];
	logic [12:0] burst_a = 13'h1000;
	function automatic logic [2:0] up_bank();
		return is_dpc ? u_up.dpcplus.bank : u_up.cdf.bank;
	endfunction
	task automatic gen_next();
		int r;
		logic [12:0] a;
		logic w;
		logic [7:0] d;
		d = rnd8();
		w = 1'b0;
		fresh_now = 1'b0;
		if (fresh > 0) begin
			fresh--;
			fresh_now = 1'b1;
			if (is_dpc) begin a = 13'h1058; w = 1'b1; d = 8'h00; end
			else begin a = 13'h1FF2; w = 1'b1; d = pm(300) ? 8'h00 : (rnd8() & 8'hF0); end
		end else if (burst > 0) begin                   // a 6502 write run: an RMW's two writes (the old
			burst--;                                     // value, then the new) or a JSR/BRK push run
			burst_n++;                                   // (the stack: A12 = 0); a hidden write is
			w = 1'b1;                                    // never a cartridge's
			if (burst_n > 2 || burst_a[12] == 1'b0) a = {1'b0, 4'h1, 8'(rnd(256))};
			else begin
				a = burst_a;
				d = (burst_n == 1) ? burst_d : burst_d + 8'd1;
			end
		end else if (prev_w) begin                      // the opcode fetch after a store
			a = pc;
			pc = pc + 13'd1;
		end else if (rnd(1000) < 15) begin
			int q;
			burst = 2 + int'(rnd(3));
			burst_n = 0;
			q = int'(rnd(10));
			burst_a = is_dpc ? ((q < 3) ? 13'h105A : (13'h1028 + 13'(rnd(88)))) : ((q < 3) ? 13'h1FF3 : (13'h1FF0 + 13'(rnd(3))));
			if (q == 9) burst_a = {1'b0, 4'h1, 8'(rnd(256))};   // a push run
			q = int'(rnd(10));                           // the RMW's old value: CALLFN pairs, services
			burst_d = (q < 3) ? 8'hFE : ((q < 5) ? 8'hFD : ((q < 7 && is_dpc) ? (8'd0 + 8'(rnd(2))) : rnd8()));
			a = burst_a;                                 // the RMW's read
		end else begin
			r = int'(rnd(1000));
			if (r < 520) begin                           // the next byte of the program
				a = pc;
				pc = pc + 13'd1;
				if (!pc[12] && rnd(4) != 0) pc = {1'b1, 12'(rnd(4096))};
			end else if (r < 600) begin                  // TIA/RIOT: A12 = 0
				a = {1'b0, 12'(rnd(4096))};
				w = rnd(10) < 3;
			end else if (r < 720) begin                  // the scheme's registers
				if (is_dpc) begin
					if (rnd(100) < 45) a = 13'h1000 | 13'(rnd(40));
					else begin
						int g;
						w = 1'b1;
						g = int'(rnd(100));
						if (g < 45) begin
							int gg;
							gg = int'(rnd(7));
							if (gg == 6) gg = 8;
							a = 13'h1028 + 13'(gg * 8) + 13'(rnd(8));
						end else if (g < 55) begin a = 13'h1058; d = (rnd(10) < 8) ? 8'h00 : rnd8(); end
						else if (g < 65) a = 13'h1059;
						else if (g < 73) begin
							a = 13'h105A;
							if (pm(k_call)) d = 8'hFE | 8'(rnd(2));
							else if (pm(k_svc)) d = 8'd1 + 8'(rnd(2));
							else d = pm(500) ? 8'd0 : rnd8();
						end else if (g < 78) a = 13'h105D + 13'(rnd(3));
						else if (g < 90) a = (rnd(2) == 0) ? (13'h1060 + 13'(rnd(8))) : (13'h1078 + 13'(rnd(8)));
						else a = 13'h1070 + 13'(rnd(8));
					end
				end else begin
					int g;
					w = 1'b1;
					g = int'(rnd(100));
					if (g < 35) a = 13'h1FF0;
					else if (g < 60) a = 13'h1FF1;
					else if (g < 80) begin a = 13'h1FF2; d = pm(250) ? 8'h00 : (pm(750) ? (rnd8() & 8'hF0) : rnd8()); end
					else begin a = 13'h1FF3; d = pm(k_call * 4) ? (8'hFE | 8'(rnd(2))) : rnd8(); end
				end
			end else if (r < 760) begin                  // hotspots
				a = is_dpc ? (13'h1FF6 + 13'(rnd(6))) : (13'h1FF4 + 13'(rnd(8)));
				if (rnd(10) == 0) a = 13'h1FF0 + 13'(rnd(16));
				w = rnd(10) < 4;
			end else if (r < 840) begin                  // a jump
				int q;
				pc = {1'b1, 12'(rnd(4096))};
				q = int'(rnd(10));
				if (q < 3) pc = {1'b1, 12'hFF0 | 12'(rnd(16))};
				else if (q == 3) pc = {1'b1, arm_off[is_dpc ? 0 : (jplus ? 2 : 1)][up_bank()]};
				a = pc;
				pc = pc + 13'd1;
			end else if (r < 870) begin                  // the same address again
				a = last_a;
			end else begin
				a = {1'b1, 12'(rnd(4096))};
				w = rnd(4) == 0;
			end
		end
		// A store is the last cycle of an instruction whose opcode and address bytes the
		// CPU fetched first: a write that does not continue a run needs three reads since
		// the last write. (It also means the cycle a one-clock stall dip lets through, the
		// held fetch's successor, is never a write: lane C's "third CALLFN in (M, M_fe]"
		// stays as unreachable as on a real 6502.) Otherwise read the program instead.
		if (w && !(burst_n >= 2 && burst_run) && rd_run < 3) begin
			if (burst_n == 1) burst = 0;
			if (fresh_now) fresh++;
			a = pc;
			pc = pc + 13'd1;
			w = 1'b0;
		end
		// The CPU in reset only reads, and only the stack page: a cycle that starts in reset is
		// never a cartridge access, also when the reset ends inside it (a 6502 leaves reset
		// through its reset sequence: PC, the stack, the vector; and in DARIA's systems the 7800
		// BIOS runs first). +rst_bus=1 reads anywhere (E3_rtl_issues.md issue 1).
		if (eff_reset) begin
			w = 1'b0;
			if (rst_bus == 0) a = {1'b0, 4'h1, 8'(rnd(256))};
		end
		burst_run = w && burst > 0;
		rd_run = w ? 0 : (rd_run < 15 ? rd_run + 1 : rd_run);
		prev_w = w && burst == 0;
		last_a = a;
		nx_a  <= a;
		nx_rw <= !w;
		nx_d  <= d;
	endtask
	always @(posedge clk_sys) if (load) gen_next();

	// ======================================================================================
	// counters, failures, the ring
	// ======================================================================================
	typedef enum int {
		// failures (must be 0)
		B_DOUT, B_STATE, B_PTR, B_WBLAG, B_RAM, B_FULL, B_K1, B_CALL, B_SVC, B_SVC_RAM, B_INIT, B_TICK, B_AUDIO,
		B_A2, B_A3, B_ASSERT, B_A_P32, B_RET_UNASKED, B_COMMIT_HID, B_DET_LOCK, B_WB_DROP, B_OVER32K,
		B_NOACC, B_SEED_RACE, B_AMP, B_DIG, B_BENCH, B_INIT_NEVER, B_HID_LAST,
		// classes and information
		I_CYCLES, I_COMMITS, I_LATCH, I_HIDDEN, I_DOUT_HID, I_SHORT, I_SHORT_DOUT, I_Q26, I_STEAL, I_MERGE_AMP,
		I_RET_LATE, I_MERGE_RACE, I_DIG_LAG, I_SVC_RACE, I_TBL_ALIAS, I_RMW_CALL, I_RMW_SEED, I_RMW_MERGE,
		I_RMW_SVC, I_SIZE_HI, I_P32_RESET, I_RESYNC, I_DEP_CF, I_CALLS_UP, I_CALLS_B, I_SVCS_UP, I_SVCS_B,
		I_R3, I_INITS, I_FULL, I_K1, I_TICKS, I_MERGES, I_HK_MERGES, I_PTR_N, I_RAM_N, I_AMP_READS,
		I_AMP_CLASS, I_DROP_UP, I_DROP_B, I_GRANTS, I_PZ_GRANTS, I_DIG_LOCAL, I_DIG_REMOTE, I_DIG_RAM, I_DIG_NONE,
		I_NOTES, I_HELD, I_PAUSE_CLK, I_HOT, I_PU, I_CRB_USE, I_WB_P32, I_YIELD3, I_PAUSE_LANE, I_COLL_RST,
		C_N
	} cnt_t;
	string  nm [C_N];
	longint cnt [C_N];
	localparam int NBAD = int'(I_CYCLES);
	initial begin
		nm[B_DOUT] = "dout_bad"; nm[B_STATE] = "state_bad"; nm[B_PTR] = "ptr_bad"; nm[B_WBLAG] = "wb_lag_bad";
		nm[B_RAM] = "ram_bad"; nm[B_FULL] = "ram_full_bad"; nm[B_K1] = "ram_call_bad"; nm[B_CALL] = "call_bad";
		nm[B_SVC] = "svc_bad"; nm[B_SVC_RAM] = "svc_ram_bad"; nm[B_INIT] = "init_bad"; nm[B_TICK] = "tick_bad";
		nm[B_AUDIO] = "audio_bad"; nm[B_A2] = "a2_bad"; nm[B_A3] = "a3_bad"; nm[B_ASSERT] = "rtl_assert";
		nm[B_A_P32] = "a_p32_late"; nm[B_RET_UNASKED] = "ret_unasked"; nm[B_COMMIT_HID] = "commit_on_hidden";
		nm[B_DET_LOCK] = "det_lock_a"; nm[B_WB_DROP] = "wb_drop"; nm[B_OVER32K] = "over32k";
		nm[B_NOACC] = "ram_wr_noaccess"; nm[B_SEED_RACE] = "seed_race"; nm[B_AMP] = "amp_lag";
		nm[B_DIG] = "dig_bad"; nm[B_BENCH] = "bench_bad"; nm[B_INIT_NEVER] = "init_never_busy";
		nm[B_HID_LAST] = "hidden_last_bad";
		nm[I_CYCLES] = "cycles"; nm[I_COMMITS] = "commits"; nm[I_LATCH] = "latches"; nm[I_HIDDEN] = "hidden";
		nm[I_DOUT_HID] = "dout_hidden"; nm[I_SHORT] = "short_phase1"; nm[I_SHORT_DOUT] = "short_dout";
		nm[I_Q26] = "q26"; nm[I_STEAL] = "grant_steal"; nm[I_MERGE_AMP] = "merge_amp"; nm[I_RET_LATE] = "ret_late";
		nm[I_MERGE_RACE] = "merge_race"; nm[I_DIG_LAG] = "dig_rom_lag"; nm[I_SVC_RACE] = "svc_audio_race";
		nm[I_TBL_ALIAS] = "tbl_alias"; nm[I_RMW_CALL] = "rmw_call"; nm[I_RMW_SEED] = "rmw_seed";
		nm[I_RMW_MERGE] = "rmw_merge"; nm[I_RMW_SVC] = "rmw_svc"; nm[I_SIZE_HI] = "size_over32k";
		nm[I_P32_RESET] = "p32_reset"; nm[I_RESYNC] = "resync"; nm[I_DEP_CF] = "deposit_cf";
		nm[I_CALLS_UP] = "calls_up"; nm[I_CALLS_B] = "calls_b"; nm[I_SVCS_UP] = "svc_up"; nm[I_SVCS_B] = "svc_b";
		nm[I_R3] = "r3_compares"; nm[I_INITS] = "inits"; nm[I_FULL] = "full_compares"; nm[I_K1] = "k1_compares";
		nm[I_TICKS] = "ticks"; nm[I_MERGES] = "merges_own"; nm[I_HK_MERGES] = "merges_hook";
		nm[I_PTR_N] = "ptr_compares"; nm[I_RAM_N] = "ram_compares"; nm[I_AMP_READS] = "amp_reads";
		nm[I_AMP_CLASS] = "amp_class"; nm[I_DROP_UP] = "drop_up"; nm[I_DROP_B] = "drop_b";
		nm[I_GRANTS] = "grants"; nm[I_PZ_GRANTS] = "grants_paused"; nm[I_DIG_LOCAL] = "dig_local";
		nm[I_DIG_REMOTE] = "dig_remote"; nm[I_DIG_RAM] = "dig_ram"; nm[I_DIG_NONE] = "dig_none";
		nm[I_NOTES] = "notes"; nm[I_HELD] = "held_cycles"; nm[I_PAUSE_CLK] = "pause_clocks";
		nm[I_HOT] = "hotspot_switches"; nm[I_PU] = "pointer_updates";
		nm[I_WB_P32] = "wb_and_p32_requested"; nm[I_YIELD3] = "three_r_requests"; nm[I_PAUSE_LANE] = "pause_lane"; nm[I_COLL_RST] = "collide_reset";
		nm[I_CRB_USE] = "crb_use";
		for (int c = 0; c < C_N; c++) cnt[c] = 0;
	end

	longint clk_n = 0, cyc_n = 0;
	int     epoch = 0, nfail = 0;
	// the ring: one entry per clk_sys (raw; formatted only when dumped)
	localparam int RING = 48;
	longint      rg_clk [RING];
	logic [63:0] rg_v [RING];
	int          ring_i = 0;
	task automatic fail(input cnt_t c, input string what);
		cnt[c]++;
		nfail++;
		if (nfail <= stop_n) begin
			$display("FAIL %s at clk %0d (epoch %0d, cycle %0d, scheme %0d rev %0d): %s", nm[c], clk_n, epoch, cyc_n,
				scheme, revision, what);
			if (nfail <= 2) begin
				$display("  ring (oldest first): clk  p1 p0 phi2 acc rw a_in d_in | up do/oe | B do/oe | sel u/b | grant u/b | stall rst");
				for (int i = 0; i < RING; i++) begin
					logic [63:0] v;
					v = rg_v[(ring_i + i) % RING];
					$display("  %0d  %b %b %b %b %b %h %h | %h/%h | %h/%h | %b/%b | %b/%b | %b %b",
						rg_clk[(ring_i + i) % RING], v[0], v[1], v[2], v[3], v[4], v[17:5], v[25:18], v[33:26], v[41:34],
						v[49:42], v[57:50], v[58], v[59], v[60], v[61], v[62], v[63]);
				end
			end
		end
		if (nfail >= maxfail) begin
			report();
			$fatal(1, "tb_fe_rand: stopped after %0d failures", nfail);
		end
	endtask
`define CHK(cond, c, what) begin if (cond) fail(c, what); end
	always @(posedge clk_sys) begin
		rg_clk[ring_i] = clk_n;
		rg_v[ring_i] = {eff_reset, stall6507, b_grant, u_up.audio_ram_grant, b_sel, u_up.sel_ram_sel, b_oe8, b_do, up_oe, up_do,
			d_in, a_in, rw, access, mapper_phi2, pclk0, pclk1};
		ring_i = (ring_i + 1) % RING;
	end
	// the watchdog: the console must keep making cycles
	longint wd_cyc = 0, wd_clk = 0;
	always @(posedge clk_sys) begin
		if (cyc_n != wd_cyc || !pg_run) begin
			wd_cyc = cyc_n;
			wd_clk = clk_n;
		end else if (clk_n - wd_clk > 3000000) begin
			fail(B_BENCH, "watchdog: no 6507 cycle checked for 3,000,000 clk_sys");
			report();
			$fatal(1, "tb_fe_rand: hung (eff_reset %0d hold %0d up init %0d B init %0d stall %0d up call %0d up dma %0d B dma %0d)",
				eff_reset, hold_reset, up_init_busy, b_init_busy, stall6507, up_call_busy, up_dma_busy, b_dma_busy);
		end
	end

	// ======================================================================================
	// the audio classes' masks and the resync (design 9.5, 12.4; E1's rules)
	// ======================================================================================
	logic   m_rep = 1'b0, m_cf = 1'b0;
	logic   up_gr_pz = 1'b0;             // upstream's last audio grant edge was in a pause
	string  m_why = "";
	function automatic void mask(input logic cf, input string why);
		if (strict != 0) return;
		m_rep = 1'b1;
		if (cf) m_cf = 1'b1;
		m_why = why;
	endfunction
	int     mw = 0;                      // the own-path merge window: 1 after M up to M_fe, 2 at M_fe
	longint mw_m = 0, late_until = -1, late_from = -1, dig_chk = -1;
	logic   rmw_merge = 1'b0, mw_rmw = 1'b0, rmw_chk = 1'b0;
	int     rst_negs = 0;                // falling edges with the console reset high in a row
	task automatic neg_resync();
		rst_negs = eff_reset ? rst_negs + 1 : 0;
		if (m_rep || m_cf) begin
			// a reset clears the masks once both sides have taken it: eff_reset rises at a
			// rising edge, both engines reset at the next one, so from the second falling edge
			if (eff_reset) begin
				if (rst_negs >= 2) begin
					m_rep = 1'b0;
					m_cf = 1'b0;
				end
			end else if (mw == 0 && b_aud_quiet()) begin
				b_deposit(m_cf);
				if (m_cf) cnt[I_DEP_CF]++;
				cnt[I_RESYNC]++;
				m_rep = 1'b0;
				m_cf = 1'b0;
			end
		end
	endtask

	// ======================================================================================
	// per-cycle bookkeeping and the repairs (falling edge)
	// ======================================================================================
	logic        live = 1'b0, rst_seen = 1'b0, cyc_rst = 1'b0, cyc_short = 1'b0, cyc_commit = 1'b0;
	logic        cyc_access = 1'b0, cyc_upwr = 1'b0;
	int          e0n = 7;
	logic        pu_pend = 1'b0, pu_short = 1'b0;
	logic  [5:0] pu_idx = 6'd0;
	int          wr_words [$];           // words a 6507-side write touched this cycle (either side)
	function automatic void wr_add(input int w);
		foreach (wr_words[i]) if (wr_words[i] == w) return;
		wr_words.push_back(w);
	endfunction
	logic        a3_use = 1'b0, cwin_q = 1'b0, i_rq = 1'b0, never_seen = 1'b0, k1_due = 1'b0, k1_run_q = 1'b0;
	int          ret_late_q = 0;
	logic  [5:0] scheme_q = 6'd0;
	logic [63:0] alias_m = 64'd0;        // tbl_alias: pointers to resync at the next falling edge
	logic [63:0] alias_i = 64'd0;        // ... and increments
	logic        q26_rep = 1'b0;
	int          q26_idx = 0;
	logic        full_due = 1'b0;
	task automatic neg_repair();
		if (q26_rep) begin
`ifndef SELF
			fe_mem.cart_ram.mem_q[13'(pb_now() + q26_idx)] = u_up.stream_tables.pointer_ram.mem_q[q26_idx];
`endif
			q26_rep = 1'b0;
		end
		// tbl_alias: upstream's table copy resynced from its own RAM word, as the ARM would
		// rewrite it (the word now holds the DSWRITE byte, as daria_fe's does)
		if (alias_m != 64'd0 || alias_i != 64'd0) begin
			for (int i = 0; i < 64; i++) begin
				if (alias_m[i]) u_up.stream_tables.pointer_ram.mem_q[i] = u_word(pb_now() + i);
				if (alias_i[i]) u_up.stream_tables.increment_ram.mem_q[i] = u_word(ib_now() + i);
			end
			alias_m = 64'd0;
			alias_i = 64'd0;
		end
	endtask

	// R1, R2/R3, I1 state
	logic [255:0] q_up [$], q_b [$];
	longint       qt_up [$], qt_b [$];
	logic         qr_b [$];
	int           rmw_pend = 0;
	logic [51:0]  sq_up [$], sq_b [$];
	logic  [31:0] r3_d [$], r3_c [$];
	int           svc_up_done = 0, svc_b_done = 0, r3_n = 0;
	logic         sp_q = 1'b0, bsp_q = 1'b0, bdma_q = 1'b0, updma_q = 1'b0;
	logic  [14:0] up_rng_d = 15'd0, b_rng_d = 15'd0;
	logic   [7:0] up_rng_c = 8'd0, b_rng_c = 8'd0;
	logic         i_arm = 1'b0, i_up = 1'b0, i_b = 1'b0, erst_q = 1'b0, cd_q = 1'b0;
	logic         btog_q = 1'b0, hid_pend = 1'b0, hid_bad = 1'b0;
	longint       h_post [16];

	// RAM compares: words [0, n) and the CDF tables
	function automatic int ram_cmp(input string what, input int n);
		int bad;
		bad = 0;
		for (int w = 0; w < n; w++)
			if (u_word(w) != b_word(w)) begin
				bad++;
				if (bad <= 6 && nfail < stop_n)
					$display("  %s: cart RAM word $%04x: upstream %08x, side B %08x", what, w, u_word(w), b_word(w));
			end
		if (is_cdf)
			for (int i = 0; i < ns_now(); i++) begin
				if (u_up.stream_tables.pointer_ram.mem_q[i] != b_ptr(i)) begin
					bad++;
					if (bad <= 6 && nfail < stop_n)
						$display("  %s: pointer[%0d]: upstream's table %08x, side B %08x", what, i,
							u_up.stream_tables.pointer_ram.mem_q[i], b_ptr(i));
				end
				if (u_up.stream_tables.increment_ram.mem_q[i] != b_inc(i)) begin
					bad++;
					if (bad <= 6 && nfail < stop_n)
						$display("  %s: increment[%0d]: upstream's table %08x, side B %08x", what, i,
							u_up.stream_tables.increment_ram.mem_q[i], b_inc(i));
				end
			end
		return bad;
	endfunction
	// nothing of either side's own writes in flight: no service latched, pending or running,
	// the writeback idle, no init
	function automatic logic ram_quiet();
		logic q;
		q = !(up_dma_busy || b_svc_run || b_svc_hold || u_up.dpcplus.service_pending) &&
			u_up.mapper_wb_idle && !up_init_busy && !b_init_busy && !eff_reset;
`ifndef SELF
		q = q && !u_fe.u_core.wb_v && !u_fe.u_core.pend_r && !u_fe.u_core.pend_s;
`endif
		return q;
	endfunction

	// ======================================================================================
	// the checks (clk_sys; pre-edge values: the state the last edge left)
	// ======================================================================================
	always @(posedge clk_sys) begin
		string       why;
		logic        scheme_ok, hidden, bad, aread, up_disp, b_disp, gr;
		logic  [7:0] uo, ud, bo, bd;
		logic [12:0] wa;
		logic [255:0] pu, pb;
		logic [51:0] su, sb;
		longint      tu, tb;
		int          n;
		clk_n++;
		scheme_ok = is_dpc || is_cdf;
		if (pause) cnt[I_PAUSE_CLK]++;

		// ---- every clock: assertions, A2, A3, upstream-side assertions -------------------------
`ifndef SELF
		if (u_fe.rst_fe || eff_reset) cyc_rst = 1'b1;
		if (u_fe.u_seq.ev_short) cnt[I_SHORT]++;
		if (u_fe.u_arb.ev_grant_steal) begin
			cnt[I_STEAL]++;
			mask(1, "grant_steal");
		end
		if (u_fe.u_core.ev_rmw_svc) cnt[I_RMW_SVC]++;
		if (u_fe.u_audio.ev_size_hi) cnt[I_SIZE_HI]++;
		if (u_fe.u_arb.crb_use) cnt[I_CRB_USE]++;
		if (u_fe.cr_wb && u_fe.cr_p32) cnt[I_WB_P32]++;      // coverage of the arbiter's yield order
		if ($countones({u_fe.cr_wb, u_fe.cr_p32, u_fe.aud_issue, u_fe.cp_req, u_fe.cr_fix}) >= 3) cnt[I_YIELD3]++;
		if (u_fe.u_call.ev_rmw_call) begin
			cnt[I_RMW_CALL]++;
			rmw_pend++;
		end
		if (u_fe.u_core.ev_tbl_alias) begin
			// a CDFJ+ DSWRITE byte into a pointer or increment word: upstream's table copy
			// keeps the old word, daria_fe uses the word in place (design 9.5 tbl_alias)
			cnt[I_TBL_ALIAS]++;
			n = int'(u_fe.u_core.dsw_addr[14:2]) - pb_now();
			if (n >= 0 && n < ns_now()) alias_m[n] = 1'b1;
			n = int'(u_fe.u_core.dsw_addr[14:2]) - ib_now();
			if (n >= 0 && n < ns_now()) alias_i[n] = 1'b1;
		end
		if (u_fe.u_arb.a_collide) begin
			// in a clock with rst_fe high (a download's reset with the new scheme already set) the
			// core's fixed requests are not gated and may take upstream's last audio grant before
			// both reset: a reset artifact, as a_p32_late's (lane A O-1)
			if (u_fe.rst_fe) cnt[I_COLL_RST]++;
			else fail(B_ASSERT, "a_collide: grant_steal outside short_phase1");
		end
		`CHK(u_fe.u_arb.a_wb_late, B_ASSERT, "a_wb_late: the pointer buffer still full in k[1]")
		if (u_fe.u_arb.a_p32_late) begin
			if (cyc_rst) cnt[I_P32_RESET]++;            // lane A O-1, lane D issue 1: a reset artifact
			else fail(B_A_P32, "a_p32_late: DSWRITE/DSPTR without P32 in k[3]");
		end
		`CHK(u_fe.u_arb.a_guard_core, B_ASSERT, "a_guard_core")
		`CHK(u_fe.u_arb.a_guard_wr, B_ASSERT, "a_guard_wr")
		`CHK(u_fe.u_arb.a_owner, B_ASSERT, "a_owner: two owners on one port")
		`CHK(u_fe.u_core.a_fpjr, B_ASSERT, "a_fpjr: fpend with jr != 0")
		`CHK(u_fe.u_core.a_pend_late, B_ASSERT, "a_pend_late: a commit action pending at pclk1")
		`CHK(u_fe.u_audio.a_tdef2, B_ASSERT, "a_tdef2: a tick while one is deferred")
		`CHK(u_fe.u_copy.a_f6_live, B_ASSERT, "a_f6_live: F6 while the console runs")
		`CHK(u_fe.u_call.ev_ret_unasked, B_RET_UNASKED, "ret_unasked: a ret_tog change outside RUN")
		`CHK(u_fe.u_seq.commit && pclk0 && !mapper_phi2, B_COMMIT_HID, "commit_on_hidden")
		`CHK(u_fe.u_guard.locked, B_DET_LOCK, "det_lock_a: the guard locked on mode A's 5x clk_arm")
		// A3: one owner per port; crb_use marks exactly last clock's consumed read
		`CHK(!$onehot0(u_fe.u_arb.own_r) || !$onehot0(u_fe.u_arb.own_s) || !$onehot0(u_fe.u_arb.own_a) ||
			u_fe.u_arb.crb_use != a3_use, B_A3,
			$sformatf("A3: own_r %06b own_s %03b own_a %04b, crb_use %0d expected %0d", u_fe.u_arb.own_r,
				u_fe.u_arb.own_s, u_fe.u_arb.own_a, u_fe.u_arb.crb_use, a3_use))
		a3_use = (u_fe.u_arb.own_r[OR_FIX] && u_fe.cr_fix_use) || u_fe.u_arb.own_r[OR_P32] || u_fe.u_arb.own_r[OR_AUD];
`else
		if (eff_reset || !scheme_ok || scheme != scheme_q) cyc_rst = 1'b1;
`endif
		// A2: the replica of sel_ram_sel (not while the image streams in: the two ROMs are
		// written at different words, and a read of the word being written is undefined)
		if (scheme_ok && !cart_download && !old_cart_download && !cwin_q)
			`CHK(b_sel != u_up.sel_ram_sel, B_A2, $sformatf("A2: sel_up %0d, sel_ram_sel %0d", b_sel, u_up.sel_ram_sel))
		// W1: upstream's writeback never drops a payload
		`CHK(u_up.table_pointer_write && !eff_reset &&
			u_up.table_writeback.pointer_ack_sync2 != u_up.table_writeback.pointer_toggle,
			B_WB_DROP, "wb_drop: upstream's writeback dropped a pointer")
		`CHK(u_up.cartram_wr && u_up.cartram_addr[17:15] != 3'd0, B_OVER32K,
			$sformatf("over32k: a 6507-side cart RAM write at $%05x", u_up.cartram_addr))
		if (u_up.table_pointer_write) cnt[I_PU]++;
`ifdef SELF
		`CHK(ag_bad_acc != 0, B_BENCH, "the two sides accepted an ARM write on different edges")
`endif

		// size_over32k (this clock's SIZE address itself differs: masked before A1)
		if (`UA.state == 4'd5 && `UA.ram_addr[16:15] != 2'd0) begin
			if (`UA.ram_en && u_up.audio_ram_grant) cnt[I_SIZE_HI]++;
			mask(0, "size_over32k");
		end
`ifndef SELF
		if (u_fe.u_audio.ev_size_hi) mask(0, "size_over32k");
`endif

		// ---- A1 and T1/T2, every clock from the first reset (E1's rules) ----------------------
		if (rst_seen) begin
			why = b_a1_tick();
			if (why != "") begin
				fail(B_TICK, {"T1/A1 ", why});
				mask(1, "tick_bad");
			end
			if (`UA.audio_tick && !m_cf && mw == 0) cnt[I_TICKS]++;
			if (!m_cf && mw == 0) begin
				why = b_a1_cf();
				if (why != "") begin
					if (clk_n < late_until) cnt[I_MERGE_RACE]++;
					else if (rmw_chk && b_a1_freq_ok()) cnt[I_RMW_MERGE]++;
					else fail(B_AUDIO, {"A1 counters/frequencies: ", why});
					mask(1, "audio_bad");
				end
			end
			rmw_chk = 1'b0;
			if (!m_rep) begin
				why = b_a1_rep();
				if (why != "") begin
					fail(B_AUDIO, {"A1 replica: ", why});
					mask(0, "audio_bad");
				end
			end
		end

		// ---- the audio classes: their conditions at this edge set the masks -------------------
		up_disp = u_dispatch();
`ifndef SELF
		b_disp = u_fe.u_audio.dispatch;
		if (mw != 0 && (up_disp || b_disp)) begin       // merge_amp: a dispatch in (M, M_fe+1]
			cnt[I_MERGE_AMP]++;
			mask(0, "merge_amp");
		end
		if (mw == 0) begin
			if (u_up.arm_call_done && is_cdf) begin
				if (hk_on) cnt[I_HK_MERGES]++;
				else begin
					mw = 1;
					mw_m = clk_n;
					mw_rmw = rmw_merge;
					rmw_merge = 1'b0;
					cnt[I_MERGES]++;
				end
			end
		end else if (mw == 1) begin
			if (u_fe.cp_apply) mw = 2;
			else if (clk_n - mw_m > 64 || eff_reset) begin
				if (!eff_reset) fail(B_AUDIO, "merge: u_fe never applied the returns (cp_apply) within 64 clocks of M");
				mw = 0;
				mask(1, "audio_bad");
			end
		end else begin
			mw = 0;                              // this edge is M_fe+1: compared from the next clock
			rmw_chk = mw_rmw;
			mw_rmw = 1'b0;
		end
		// T4: u_fe's remote sample request against upstream's address
		if (u_fe.u_audio.r_go && !u_fe.u_audio.r_loc && !m_rep)
			`CHK(u_fe.u_audio.dig_addr != `UA.digital_address, B_DIG,
				$sformatf("T4: sample address %08x, upstream %08x", u_fe.u_audio.dig_addr, `UA.digital_address))
`endif
		// dig_rom_lag: upstream's ROM sample R; a hit has sample_done high pre-edge at R+4
		if (`UA.state == 4'd9) begin
			if (`UA.digital_address < `UA.rom_size) begin
				if (`UA.digital_address[31:15] == 17'd0) cnt[I_DIG_LOCAL]++;
				else cnt[I_DIG_REMOTE]++;
			end else if (`UA.digital_address[31:15] == 17'h0_8000) cnt[I_DIG_RAM]++;
			else cnt[I_DIG_NONE]++;
		end
		if (u_up.arm_sample_request) begin
			if (`UA.digital_address[31:15] != 17'd0) begin
				cnt[I_DIG_LAG]++;
				mask(0, "dig_rom_lag");
			end else dig_chk = clk_n + 4;
		end
		if (dig_chk == clk_n) begin
			dig_chk = -1;
			if (!u_up.arm_sample_done) begin
				cnt[I_DIG_LAG]++;
				mask(0, "dig_rom_lag");
			end
		end
		// grants: svc_audio_race; paused grants (counted: lane B's B-1 makes them exact)
		gr = u_up.audio_ram_grant || b_grant;
		if (gr) begin
			cnt[I_GRANTS]++;
			wa = u_up.audio_ram_grant ? u_up.audio_ram_addr[14:2] : u_up.audio_ram_addr[14:2];
`ifndef SELF
			if (!u_up.audio_ram_grant) wa = u_fe.aud_addr[14:2];
`endif
			if ((updma_q && {wa, 2'b11} >= up_rng_d && {wa, 2'b00} < up_rng_d + {7'd0, up_rng_c}) ||
				(b_svc_run && {wa, 2'b11} >= b_rng_d && {wa, 2'b00} < b_rng_d + {7'd0, b_rng_c})) begin
				cnt[I_SVC_RACE]++;
				mask(0, "svc_audio_race");
			end
			if (pause) cnt[I_PZ_GRANTS]++;
		end
`ifndef SELF
		// pause_lane (design 9.5): a byte capture on an unpaused edge after a grant edge in a
		// pause. cart_ram_tdp's read lane is frozen at what the port's address was at the last
		// unpaused edge; daria_fe's al (B-1) at the engine's a_d there. They differ iff the select
		// was high at that edge (lane B's B-1 takes that as unreachable; it is not: a pause can
		// start on the clock after a pclk1 that ended a RAM read cycle)
		if (u_up.audio_ram_grant) up_gr_pz = pause;
		if (`UA.state == 4'd8 && !pause && up_gr_pz && u_up.cart_ram.mapper_read_lane != u_fe.u_audio.al) begin
			cnt[I_PAUSE_LANE]++;
			mask(0, "pause_lane");
		end
`endif
		if (`UA.state == 4'd2) cnt[I_NOTES]++;

		// ---- E0 tracking and the 6507-side checks --------------------------------------------
		if (eff_reset) live = 1'b0;
		if (live && scheme_ok && tia_en) begin
			if (access && a_in[12]) begin
				cnt[I_COMMITS]++;
				cyc_commit = 1'b1;
				if (e0n < 5) cyc_short = 1'b1;
`ifndef SELF
				`CHK(u_fe.u_seq.ev_short != (e0n < 5), B_BENCH, $sformatf("ev_short %0d, phase 1 of %0d", u_fe.u_seq.ev_short, e0n + 1))
				if (u_fe.u_core.opc.hot) cnt[I_HOT]++;
`endif
			end
			if (is_cdf && u_up.cdf.pointer_update) begin
				pu_pend = 1'b1;
				pu_idx = u_up.cdf.pointer_update_index;
				pu_short = cyc_short;
			end
			if (u_up.cartram_wr) begin
				wr_add(int'(u_up.cartram_addr[14:2]));
				cyc_upwr = 1'b1;
			end
`ifdef SELF
			if (u_b.cartram_wr) wr_add(int'(u_b.cartram_addr[14:2]));
`else
			if (fu_crb_we && (u_fe.u_arb.own_r[OR_FIX] || u_fe.u_arb.own_r[OR_WB])) wr_add(int'(fu_crb_addr));
`endif
			// ---- L1 at every pclk0 of a read ----
			if (pclk0 && rw) begin
				hidden = !mapper_phi2;
				cnt[I_LATCH]++;
				uo = up_oe;
				ud = up_do;
				bo = b_oe8;
				bd = b_do;
				bad = bo != uo || (bd & bo) != (ud & uo);
				aread = is_dpc ? (u_up.dpcplus.register_read && u_up.dpcplus.read_function == 3'd0 &&
					u_up.dpcplus.read_index == 3'd5) : u_up.cdf.amplitude_fetch;
				if (!hidden) begin
					if (aread) cnt[I_AMP_READS]++;
					if (bad) begin
						if ((cyc_short || e0n < 5) && strict == 0) cnt[I_SHORT_DOUT]++;
						else if (aread && (m_rep || mw != 0)) cnt[I_AMP_CLASS]++;
						else if (aread) fail(B_AMP, $sformatf("amp_lag: AMPLITUDE read, side B %02x, upstream %02x, no class", bd, ud));
						else fail(B_DOUT, $sformatf("L1 dout: side B %02x/%02x, upstream %02x/%02x (d/oe), a_in %04x", bd, bo, ud, uo, a_in));
					end
				end else begin
					cnt[I_HIDDEN]++;
					hid_pend = 1'b1;
					hid_bad = bad && !(cyc_short || e0n < 5);
					if (bad) cnt[I_DOUT_HID]++;
				end
			end
			if (pclk0 && e0n < 5) cyc_short = 1'b1;
		end

		// ---- at every pclk1: what the cycle before left ----
		if (pclk1) begin
			if (live && !cyc_rst && scheme_ok && tia_en) begin
				cnt[I_CYCLES]++;
				cyc_n++;
				c1_svc_ok = !(up_dma_busy || b_svc_run || r3_d.size() != 0 || sq_up.size() != 0 || sq_b.size() != 0);
				// pend_up is upstream's call_pending when both see the return on one edge; after a
				// ret_late (the bench held ret_tog back) u_fe's X, and so its M, are later
				c1_call_ok = clk_n >= late_until;
				why = is_dpc ? b_c1() : b_c2();
				`CHK(why != "", B_STATE, {is_dpc ? "C1 state: " : "C2 state: ", why})
				if (pu_pend) begin
					cnt[I_PTR_N]++;
					if (b_ptr(int'(pu_idx)) != u_up.stream_tables.pointer_ram.mem_q[pu_idx]) begin
						if (pu_short && strict == 0) begin cnt[I_Q26]++; q26_rep = 1'b1; q26_idx = int'(pu_idx); end
						else if (alias_any(pu_idx)) cnt[I_TBL_ALIAS]++;
						else fail(B_PTR, $sformatf("C3 pointer[%0d]: side B %08x, upstream's table %08x", pu_idx,
							b_ptr(int'(pu_idx)), u_up.stream_tables.pointer_ram.mem_q[pu_idx]));
					end
					// upstream's own RAM word against its table (the writeback has landed)
					if (!alias_any(pu_idx))
						`CHK(u_word(pb_now() + int'(pu_idx)) != u_up.stream_tables.pointer_ram.mem_q[pu_idx], B_WBLAG,
							$sformatf("wb_lag: upstream's RAM word for pointer[%0d] %08x, its table %08x", pu_idx,
								u_word(pb_now() + int'(pu_idx)), u_up.stream_tables.pointer_ram.mem_q[pu_idx]))
				end
				if (wr_words.size() != 0 && !up_dma_busy && !b_svc_run) begin
					foreach (wr_words[i]) begin
						cnt[I_RAM_N]++;
						if (u_word(wr_words[i]) != b_word(wr_words[i])) begin
							// only the Q26 pointer word of a short cycle may differ (C3 repairs it)
							if (pu_pend && pu_short && strict == 0 && wr_words[i] == pb_now() + int'(pu_idx)) ;
							else fail(B_RAM, $sformatf("C4: cart RAM word $%04x: upstream %08x, side B %08x", wr_words[i],
								u_word(wr_words[i]), b_word(wr_words[i])));
						end
					end
				end
				`CHK(cyc_upwr && !cyc_access, B_NOACC, "ram_wr_noaccess: an upstream RAM strobe in a cycle with no commit")
				if (hid_pend && !stall6507) `CHK(hid_bad, B_HID_LAST, "hidden_last_bad: the last hidden latch of a stall differs")
				if (cyc_n % full_every == 0) full_due = 1'b1;
				if (held) cnt[I_HELD]++;
			end
			// a short cycle's Q26 pointer in a cycle the checks above skip (a console reset after
			// its commit): repaired all the same, or the two sides would part for good
			if (pu_pend && pu_short && strict == 0 && !(live && !cyc_rst && scheme_ok && tia_en) && is_cdf &&
					b_ptr(int'(pu_idx)) != u_up.stream_tables.pointer_ram.mem_q[pu_idx]) begin
				cnt[I_Q26]++;
				q26_rep = 1'b1;
				q26_idx = int'(pu_idx);
			end
			if (full_due && ram_quiet() && !alias_pending()) begin
				full_due = 1'b0;
				cnt[I_FULL]++;
				n = ram_cmp("full", ram_words());
				`CHK(n != 0, B_FULL, $sformatf("full compare: %0d cart RAM / table words differ", n))
			end
			pu_pend = 1'b0;
			wr_words.delete();
			cyc_upwr = 1'b0;
			cyc_access = 1'b0;
			cyc_commit = 1'b0;
			cyc_short = 1'b0;
			hid_pend = 1'b0;
			cyc_rst = 1'b0;
			if (!live && !eff_reset && tia_en) live = 1'b1;
		end
		if (access) cyc_access = 1'b1;
		if (pclk1) e0n = 0;
		else if (e0n < 15) e0n++;

		// ---- K1: the whole RAM at each call's first quiet point ----
		if (u_up.control_state == CTRL_RUNNING && !k1_run_q) k1_due = 1'b1;
		k1_run_q = u_up.control_state == CTRL_RUNNING;
		if (k1_due && stall6507 && pg.taken && quiet_cnt >= 8'd8 && ram_quiet() && !alias_pending()) begin
			k1_due = 1'b0;
			cnt[I_K1]++;
			n = ram_cmp("K1", ram_words());
			`CHK(n != 0, B_K1, $sformatf("K1: %0d cart RAM / table words differ at a call start", n))
		end else if (k1_due && !up_call_busy) k1_due = 1'b0;

		// ---- R1: posts against accepts, in order ----
		if (eff_reset && !erst_q) begin
			cnt[I_DROP_UP] += q_up.size();
			cnt[I_DROP_B] += q_b.size();
			q_up.delete();
			qt_up.delete();
			q_b.delete();
			qt_b.delete();
			qr_b.delete();
			rmw_pend = 0;
		end
		if (up_accept && !eff_reset) begin
			q_up.push_back(u_payload());
			qt_up.push_back(clk_n);
			cnt[I_CALLS_UP]++;
		end
`ifdef SELF
		if (b_accept && !eff_reset) begin
			q_b.push_back(b_payload());
			qt_b.push_back(clk_n);
			qr_b.push_back(1'b0);
			cnt[I_CALLS_B]++;
		end
`else
		if (fe_call_tog != btog_q && !eff_reset) begin  // flipped at the last edge: F0-F7 in place
			q_b.push_back(b_posted());
			qt_b.push_back(clk_n - 1);
			qr_b.push_back(rmw_pend > 0);
			if (rmw_pend > 0) rmw_pend--;
			cnt[I_CALLS_B]++;
		end
		btog_q = fe_call_tog;
`endif
		while (q_up.size() > 0 && q_b.size() > 0) begin
			logic rmw, one_tick;
			pu = q_up.pop_front();
			pb = q_b.pop_front();
			tu = qt_up.pop_front();
			tb = qt_b.pop_front();
			rmw = qr_b.pop_front();
			h_post[(tb - tu < 0) ? 0 : ((tb - tu > 15) ? 15 : int'(tb - tu))]++;
			if (pu != pb) begin
				one_tick = 1'b1;
				for (int v = 0; v < 3; v++)
					if (pb[64 + 32 * v +: 32] != pu[64 + 32 * v +: 32] &&
						pb[64 + 32 * v +: 32] != pu[64 + 32 * v +: 32] + pu[160 + 32 * v +: 32] &&
						pu[64 + 32 * v +: 32] != pb[64 + 32 * v +: 32] + pu[160 + 32 * v +: 32]) one_tick = 1'b0;
				if (pu[63:0] != pb[63:0])
					fail(B_CALL, $sformatf("R1: call posted %064x, upstream's payload %064x", pb, pu));
				else if (tb >= late_from && tb < late_until)
					// ret_late (design 9.5; mode A only): u_fe's X is after upstream's, so a call
					// pending at X is captured after the merge upstream's accept preceded (with the
					// hook: post-merge frequencies; without: seeds a tick apart): merge_race
					cnt[I_MERGE_RACE]++;
				else if (pu[255:160] != pb[255:160])
					fail(B_CALL, $sformatf("R1: call posted %064x, upstream's payload %064x", pb, pu));
				else if (rmw) begin
					// rmw_call: call 2's seeds (design 9.5; lane C C-3). A voice the ARM returns
					// as its seed + 1 (or, with the hook, as upstream's seed) then merges to
					// different counters: rmw_merge at the first compare after the window
					cnt[I_RMW_SEED]++;
					if (is_cdf) rmw_merge = 1'b1;
				end else if (one_tick) fail(B_SEED_RACE, $sformatf("seed_race: posted seeds %024x, upstream %024x", pb[159:64], pu[159:64]));
				else fail(B_CALL, $sformatf("R1: seeds %024x, upstream %024x", pb[159:64], pu[159:64]));
			end
		end
		erst_q = eff_reset;

		// ---- R2/R3: services ----
		if (u_up.dpcplus.service_pending && !sp_q && is_dpc) begin
			sq_up.push_back(u_svc());
			cnt[I_SVCS_UP]++;
		end
		sp_q = u_up.dpcplus.service_pending;
		if (b_svc_pend && !bsp_q) begin
			sq_b.push_back(b_svc());
			cnt[I_SVCS_B]++;
		end
		bsp_q = b_svc_pend;
		while (sq_up.size() > 0 && sq_b.size() > 0) begin
			su = sq_up.pop_front();
			sb = sq_b.pop_front();
			`CHK(su != sb, B_SVC, $sformatf("R2: service fill/src/dst/count/val %013x, upstream %013x", sb, su))
			r3_d.push_back({17'd0, su[30:16]});
			r3_c.push_back({24'd0, su[15:8]});
		end
		if (up_dma_busy && !up_init_busy && !updma_q) begin
			up_rng_d = u_up.dpcplus.service_dest;
			up_rng_c = u_up.dpcplus.service_count;
		end
		if (updma_q && !(up_dma_busy && !up_init_busy)) svc_up_done++;
		updma_q = up_dma_busy && !up_init_busy;
`ifdef SELF
		if (b_svc_run && !bdma_q) begin
			b_rng_d = u_b.dpcplus.service_dest;
			b_rng_c = u_b.dpcplus.service_count;
		end
`else
		if (u_fe.svc_take) begin
			sb = b_svc();
			b_rng_d = sb[30:16];
			b_rng_c = sb[15:8];
		end
`endif
		if (bdma_q && !b_svc_run) svc_b_done++;
		bdma_q = b_svc_run;
		if (r3_d.size() > 0 && !(up_dma_busy && !up_init_busy) && !u_up.dpcplus.service_pending &&
				!b_svc_run && !b_svc_hold && svc_up_done >= r3_n + r3_d.size() && svc_b_done >= r3_n + r3_d.size()) begin
			while (r3_d.size() > 0) begin
				int dd, cc;
				dd = int'(r3_d.pop_front());
				cc = int'(r3_c.pop_front());
				r3_n++;
				cnt[I_R3]++;
				n = 0;
				for (int a = dd; a < dd + cc; a++) if (u_byte(a) != b_byte(a)) n++;
				`CHK(n != 0, B_SVC_RAM, $sformatf("R3: %0d of the %0d bytes at $%04x differ", n, cc, dd))
			end
		end
		if (eff_reset) begin                 // a console reset abandons a service on both sides
			sq_up.delete();
			sq_b.delete();
			r3_d.delete();
			r3_c.delete();
			r3_n = 0;
			svc_up_done = 0;
			svc_b_done = 0;
		end

		// ---- I1/I2 at the first edge both inits are done ----
		if ((!cart_download && cd_q) || (hd_loaded && !cart_download && eff_reset && !i_rq)) begin
			i_arm = 1'b1;
			i_up = 1'b0;
			i_b = 1'b0;
		end
		i_rq = eff_reset;
		cd_q = cart_download;
		if (i_arm) begin
			if (up_init_busy) i_up = 1'b1;
			if (b_init_busy) i_b = 1'b1;
			if (i_up && i_b && !up_init_busy && !b_init_busy) begin
				i_arm = 1'b0;
				if (scheme_ok) begin
					cnt[I_INITS]++;
					n = ram_cmp("I1/I2", ram_words());
					`CHK(n != 0, B_INIT, $sformatf("I1/I2: %0d cart RAM / table words differ after init", n))
				end
			end
		end
		`CHK(hd_never != 0 && !never_seen, B_INIT_NEVER, "init_never_busy: the hold timed out")
		if (hd_never != 0) never_seen = 1'b1;
`ifndef SELF
		if (ret_late_n != ret_late_q) begin
			cnt[I_RET_LATE] += ret_late_n - ret_late_q;
			ret_late_q = ret_late_n;
			late_from = clk_n;
			late_until = clk_n + 2000;
		end
`endif
		scheme_q = scheme;
		if (eff_reset) rst_seen = 1'b1;        // A1 from the clock after the first reset edge
	end
`ifndef SELF
	always @(posedge clk_sys) cwin_q <= cart_win;
`else
	always @(posedge clk_sys) cwin_q <= cart_download;
`endif
	function automatic logic alias_any(input logic [5:0] i);
		return alias_m[i];
	endfunction
	// a repair still to come: a tbl_alias resync, or a Q26 pointer repair decided (q26_rep, done at
	// the falling edge) or still to be decided at this cycle's pclk1 (a short cycle's pointer
	// update): K1 and the full compare wait for it
	function automatic logic alias_pending();
		return alias_m != 64'd0 || alias_i != 64'd0 || q26_rep || (pu_pend && pu_short && strict == 0);
	endfunction
	function automatic logic [7:0] b_byte(input int a);
		logic [31:0] w;
		w = b_word(a >> 2);
		return w[8 * (a & 3) +: 8];
	endfunction
	function automatic logic b_a1_freq_ok();
`ifdef SELF
		return u_b.mapper_audio.frequency0 == `UA.frequency0 && u_b.mapper_audio.frequency1 == `UA.frequency1 &&
			u_b.mapper_audio.frequency2 == `UA.frequency2;
`else
		return u_fe.u_audio.freq[0] == `UA.frequency0 && u_fe.u_audio.freq[1] == `UA.frequency1 &&
			u_fe.u_audio.freq[2] == `UA.frequency2;
`endif
	endfunction

	// ======================================================================================
	// self-test faults (+inj=K at checked cycle +inj_at=N); each must be caught
	//   1 fe_do bit 0 flipped before a shown latch -> L1   2 counter[0] + 1 -> A1
	//   3 bank + 1 -> C1/C2   4 cart RAM word $100 inverted -> full/K1   5 a posted word -> R1
	// ======================================================================================
	logic inj_done = 1'b0;
	always @(negedge clk_sys) begin
		neg_resync();
		neg_repair();
`ifndef SELF
		if (inj != 0 && !inj_done && live && cyc_n >= inj_at) begin
			case (inj)
				1: if (pclk0 && rw && a_in[12] && mapper_phi2 && scheme != 0) begin
					u_fe.u_core.fe_do = u_fe.u_core.fe_do ^ 8'h01;
					inj_done = 1'b1;
				end
				2: if (!m_cf && mw == 0 && b_aud_quiet()) begin
					u_fe.u_audio.counter[0] = u_fe.u_audio.counter[0] + 32'd1;
					inj_done = 1'b1;
				end
				3: begin
					u_fe.u_core.bank = u_fe.u_core.bank + 3'd1;
					inj_done = 1'b1;
				end
				4: begin
					fe_mem.cart_ram.mem_q[13'h100] = ~fe_mem.cart_ram.mem_q[13'h100];
					inj_done = 1'b1;
				end
				5: if (fe_call_tog != btog_q) begin
					fe_mem.state_ram.mem_q[8'hF5] = fe_mem.state_ram.mem_q[8'hF5] ^ 32'h0000_0100;
					inj_done = 1'b1;
				end
				default: inj_done = 1'b1;
			endcase
			if (inj_done) $display("INJECT fault %0d at clk %0d (cycle %0d)", inj, clk_n, cyc_n);
		end
`endif
	end

	// +dbg_word=W (with +trace_from/+trace_to): every change of cart RAM word W on either
	// side, and of the CDF table copies' entries that alias it, on either clock
	int          dbg_word = -1;
	logic [31:0] dbg_u = 32'd0, dbg_b = 32'd0, dbg_t = 32'd0;
	initial void'($value$plusargs("dbg_word=%d", dbg_word));
	always @(clk_sys or clk_arm) if (dbg_word >= 0 && clk_n >= tr_from && clk_n <= tr_to) begin
		logic [31:0] t;
		t = (dbg_word >= pb_now() && dbg_word < pb_now() + 64) ? u_up.stream_tables.pointer_ram.mem_q[dbg_word - pb_now()] : 32'd0;
		if (u_word(dbg_word) != dbg_u || b_word(dbg_word) != dbg_b || t != dbg_t)
			$display("W %0t clk %0d word %04x: upstream %08x (table %08x), side B %08x | cpu_en %b acc %b a %04x d %08x be %h | wb_en %b %04x %08x",
				$time, clk_n, dbg_word, u_word(dbg_word), t, b_word(dbg_word), cpu_en, up_cpu_acc, cpu_addr, cpu_wdata,
				cpu_wstrb, u_up.mapper_wb_en, u_up.mapper_wb_addr, u_up.mapper_wb_wdata);
		dbg_u = u_word(dbg_word);
		dbg_b = b_word(dbg_word);
		dbg_t = t;
	end

	// +trace_from/+trace_to: one line per clk_sys
	always @(posedge clk_sys) if (clk_n >= tr_from && clk_n <= tr_to)
		$display("T %0d p1 %b p0 %b phi2 %b acc %b rw %b a %h d %h | up %h/%h b %h/%h | sel %b/%b gr %b/%b | aud st %0d | stall %b rst %b | svc %b/%b dma %b/%b run %b call %b",
			clk_n, pclk1, pclk0, mapper_phi2, access, rw, a_in, d_in, up_do, up_oe, b_do, b_oe8, u_up.sel_ram_sel, b_sel,
			u_up.audio_ram_grant, b_grant, `UA.state, stall6507, eff_reset, u_up.dpcplus.service_pending, b_svc_pend,
			up_dma_busy, b_dma_busy, b_svc_run, up_call_busy);
`ifndef SELF
	always @(posedge clk_sys) if (clk_n >= tr_from && clk_n <= tr_to)
		$display("TA %0d pause %b | up: st %0d v %0d sum %03x en %b a %05x gr %b byte %02x q %02x | fe: st %03x v %0d ssum %02x iss %b a %04x take %b al %0d crb %08x",
			clk_n, pause, `UA.state, `UA.voice, `UA.sample_sum, u_up.audio_ram_en, u_up.audio_ram_addr, u_up.audio_ram_grant,
			u_up.cartram_data, u_up.cartram_data_tdp, u_fe.u_audio.st, u_fe.u_audio.voice, u_fe.u_audio.ssum,
			u_fe.u_audio.aud_issue, u_fe.u_audio.aud_addr, u_fe.u_audio.aud_take, u_fe.u_audio.al, u_fe.u_audio.crb_q);
	always @(posedge clk_sys) if (clk_n >= tr_from && clk_n <= tr_to)
		$display("TC %0d up: cpend %b creq %b cready %b ctl %0d done %b | fe: pend_up %b pend2 %b st %b busy %b callfn %b tog %b ret_tog %b",
			clk_n, u_up.dpcplus.call_pending | u_up.cdf.call_pending, u_up.arm_call_request, u_up.arm_call_ready,
			u_up.control_state, u_up.arm_call_done, u_fe.u_call.pend_up, u_fe.u_call.pend2, u_fe.u_call.st,
			fe_call_busy, u_fe.callfn, fe_call_tog, ret_tog);
`endif

	// ======================================================================================
	// epochs: the scheme, the image, the load, the events
	// ======================================================================================
	task automatic pick_scheme();
		int r;
		string o;
		int off;
		o = only;
		off = -1;
		r = (epoch + seed) % 10;
		if (o == "all") begin
			case (r)
				0: begin o = "dpc0";  off = 0; end
				1: begin o = "cdf0";  off = 1; end
				2: begin o = "cdf1";  off = 0; end
				3: begin o = "dpc1";  off = 0; end
				4: begin o = "cdfj";  off = 1; end
				5: begin o = "cdfjp"; off = 0; end
				6: begin o = "cdf0";  off = 0; end
				7: begin o = "cdf1";  off = 1; end
				8: begin o = "cdfj";  off = 0; end
				default: begin o = "cdfjp"; off = 1; end
			endcase
		end else if (o == "cdf") begin
			r = r % 8;
			o = (r % 4 == 0) ? "cdf0" : (r % 4 == 1) ? "cdf1" : (r % 4 == 2) ? "cdfj" : "cdfjp";
			off = r / 4;
		end else if (o == "dpc") o = (r % 2 == 0) ? "dpc0" : "dpc1";
		case (o)
			"dpc0":  begin scheme = SCHEME_DPCP; revision = {2'(rnd(4)), 1'b0}; end
			"dpc1":  begin scheme = SCHEME_DPCP; revision = {2'(rnd(4)), 1'b1}; end
			"cdf0":  begin scheme = SCHEME_CDF;  revision = 3'd0; end
			"cdf1":  begin scheme = SCHEME_CDF;  revision = 3'd1; end
			"cdfj":  begin scheme = SCHEME_CDF;  revision = 3'd2; end
			"cdfjp": begin scheme = SCHEME_CDF;  revision = 3'd3; end
			default: $fatal(1, "tb_fe_rand: +only=%s is not all, dpc, cdf, dpc0, dpc1, cdf0, cdf1, cdfj or cdfjp", only);
		endcase
		ldx     = rnd(4) != 0;
		ldy     = rnd(4) != 0;
		foff_en = (off < 0) ? (rnd(10) < 4) : (off == 1);
		foff    = (rnd(4) == 0) ? rnd8() : 8'(rnd(200));
		cdfj_entry = rnd32();
		cdfj_stack = rnd32();
		rom_size = pm(700) ? 32'd32768 : 32'd32768 + 32'(rnd(32769));
		begin
			int q;
			q = int'(rnd(100));
			if (q < 25) asz = 16'd0;
			else if (q < 98) asz = 16'(rnd(scheme == SCHEME_CDF && revision[1:0] == 2'd3 ? 32700 : 8180)) & 16'hFFFC;
			else asz = 16'h7FF8 + 16'(rnd(8));     // size_over32k
		end
		hk_on = (hook_mode == 2) ? (rnd(2) == 1) : (hook_mode == 1);
	endtask

	task automatic put32(input int a, input logic [31:0] v);
		for (int b = 0; b < 4; b++) img[(a + b) & 65535] = v[8 * b +: 8];
	endtask
	task automatic gen_image();
		int i;
		logic [11:0] base;
		i = 0;
		while (i < 32768) begin
			int r;
			r = int'(rnd(1000));
			if (r < 200) begin
				img[i] = 8'hA9;
				img[(i + 1) & 32767] = (foff_en ? foff : 8'h00) + 8'(rnd(36));
				i += 2;
			end else if (r < 300) begin
				img[i] = 8'hA9;
				img[(i + 1) & 32767] = (rnd(10) < 8) ? 8'(rnd(42)) : rnd8();
				i += 2;
			end else if (r < 340) begin
				img[i] = (rnd(2) == 0) ? 8'hA2 : 8'hA0;
				img[(i + 1) & 32767] = (foff_en ? foff : 8'h00) + 8'(rnd(36));
				i += 2;
			end else if (r < 420) begin
				int q;
				img[i] = 8'h4C;
				q = int'(rnd(10));
				img[(i + 1) & 32767] = (q < 5) ? 8'h00 : (q < 8) ? 8'h01 : rnd8();
				img[(i + 2) & 32767] = (rnd(10) < 8) ? 8'h00 : rnd8();
				i += 3;
			end else begin
				img[i] = rnd8();
				i += 1;
			end
		end
		for (int lay = 0; lay < 3; lay++) begin
			base = (lay == 0) ? 12'hC00 : ((lay == 1) ? 12'h000 : 12'h800);
			for (int b = 0; b < 8; b++) begin
				int p, q;
				arm_off[lay][b] = 12'hFF3 + 12'(rnd(8));
				p = (int'(base) + b * 4096 + int'(arm_off[lay][b])) & 32767;
				img[p] = (rnd(4) == 0) ? 8'hA2 : 8'hA9;
				q = int'(rnd(4));
				img[(p + 1) & 32767] = (q == 0) ? (8'h27 + 8'(rnd(2))) : (q == 1) ? 8'(rnd(42))
				                     : ((foff_en ? foff : 8'h00) + 8'(rnd(36)));
			end
		end
		for (int lay = 0; lay < 3; lay++) begin
			base = (lay == 0) ? 12'hC00 : ((lay == 1) ? 12'h000 : 12'h800);
			for (int b = 0; b < 8; b++) begin
				int p;
				if (rnd(2) == 0) continue;
				p = (int'(base) + b * 4096 + 'hFFD + int'(rnd(3))) & 32767;
				img[p] = 8'h4C;
				img[(p + 1) & 32767] = (rnd(4) == 0) ? 8'h01 : 8'h00;
				img[(p + 2) & 32767] = 8'h00;
			end
		end
		// CDF: the waveform pointer words (copied to RAM [0, $800) by both inits)
		if (scheme == SCHEME_CDF)
			for (int v = 0; v < 3; v++) put32((revision[1:0] == 2'd0 ? 'h7F0 : 'h1B0) + 4 * v, pointer_value());
		// the size words (CDF: RAM [0, $800) comes from the image)
		if (scheme == SCHEME_CDF && asz != 16'd0 && asz < 16'h0800)
			for (int v = 0; v < 3; v++) put32(int'(asz) + 4 * v, {20'd0, 12'(rnd(4096))});
		for (int a = 32768; a < 65536; a++) img[a] = rnd8();
	endtask

	// the download: load_start (the console goes into reset), the new scheme and image,
	// a byte per clock (with gaps), load_end
	task automatic do_load();
		int nbytes;
		@(negedge clk_sys);
		cart_download = 1'b1;
		@(negedge clk_sys);
		pick_scheme();
		gen_image();
		$display("epoch %0d: scheme %0d rev %0d ldx %0d ldy %0d foff %0d/%02x rom_size %0d asz %04x hook %0d (cycle %0d, clk %0d)",
			epoch, scheme, revision, ldx, ldy, foff_en, foff, rom_size, asz, hk_on, cyc_n, clk_n);
		nbytes = int'(rom_size);
		for (int a = 0; a < nbytes; a++) begin
			ld_wr = 1'b1;
			ld_addr = 25'(a);
			ld_data = img[a];
			@(negedge clk_sys);
			ld_wr = 1'b0;
			if (pm(20)) repeat (1 + rnd(3)) @(negedge clk_sys);
		end
		cart_download = 1'b0;
		@(negedge clk_sys);
	endtask

	task automatic run_cycles(input longint n);
		longint target;
		target = cyc_n + n;
		while (cyc_n < target) @(posedge clk_sys);
	endtask
	task automatic wait_running();
		int guard;
		guard = 0;
		while ((eff_reset || !live) && guard < 400000) begin
			@(posedge clk_sys);
			guard++;
		end
		if (guard >= 400000) begin
			fail(B_BENCH, "the console never left reset after a load or reset");
		end
	endtask
	task automatic wait_idle(input int max);
		int g;
		g = 0;
		while ((up_call_busy || up_dma_busy || b_dma_busy || u_up.dpcplus.service_pending
`ifndef SELF
			|| fe_call_busy
`endif
			) && g < max) begin
			@(posedge clk_sys);
			g++;
		end
	endtask

	task automatic run_epoch(input longint n);
		longint done, ev_at;
		int ev;
		epoch++;
		tia_req = 1'b0;
		do_load();
		@(negedge clk_sys);
		tia_req = 1'b1;
		fresh = 2;
		pc = {1'b1, 12'(rnd(4096))};
		wait_running();
		// the events: a console reset, a 7800-mode interval, a non-ARM interval (CDF)
		ev = events ? int'((epoch + seed) % 4) : 3;
		ev_at = longint'(rnd(32'(n / 2))) + n / 4;
		done = cyc_n;
		run_cycles(ev_at);
		case (ev)
			0: begin                                    // a console reset: anywhere (a call, a service, F6)
				@(negedge clk_sys);
				repeat (rnd(12)) @(negedge clk_sys);
				reset_in = 1'b1;
				repeat (2 + rnd(200)) @(negedge clk_sys);
				reset_in = 1'b0;
				fresh = 2;
				wait_running();
			end
			1: begin                                    // 7800 mode: tia_en and the driver off (no call
				wait_idle(100000);                      // or service in flight: the 2600 is not running)
				@(negedge clk_sys);
				// as the scheme switch: not while a pointer check or repair is still to come
				while (pu_pend || u_up.cdf.pointer_update || alias_pending()) @(negedge clk_sys);
				tia_req = 1'b0;
				repeat (20 + rnd(3000)) @(negedge clk_sys);
				tia_req = 1'b1;
			end
			2: if (is_cdf) begin                        // a non-ARM scheme interval (CDF only, nothing in flight)
				wait_idle(100000);
				@(negedge clk_sys);
				// in the pclk1 clock (where a switch is exact for daria_fe, lane A O-3) of a cycle
				// with no pointer check or repair still to come: the switch skips that pclk1's checks
				while (!pclk1 || pu_pend || u_up.cdf.pointer_update || alias_pending()) @(negedge clk_sys);
				scheme = 6'd0;
				repeat (20 + rnd(2000)) @(negedge clk_sys);
				while (!pclk1 || alias_pending()) @(negedge clk_sys);
				scheme = SCHEME_CDF;
				fresh = 2;
			end
			default: ;
		endcase
		if (cyc_n - done < n) run_cycles(n - (cyc_n - done));
		// the epoch's end: let calls and services finish, then the whole RAM at a cycle's end
		wait_idle(200000);
		full_due = 1'b1;
		begin
			int g;
			g = 0;
			while (full_due && g < 100000) begin
				@(posedge clk_sys);
				g++;
			end
		end
	endtask

	// ======================================================================================
	// main
	// ======================================================================================
	initial begin
		longint left;
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("cycles=%d", n_cycles));
		void'($value$plusargs("epoch=%d", epoch_len));
		void'($value$plusargs("only=%s", only));
		void'($value$plusargs("stop=%d", stop_n));
		void'($value$plusargs("maxfail=%d", maxfail));
		void'($value$plusargs("events=%d", events));
		void'($value$plusargs("hook=%d", hook_mode));
		void'($value$plusargs("full=%d", full_every));
		void'($value$plusargs("k_call=%d", k_call));
		void'($value$plusargs("k_svc=%d", k_svc));
		void'($value$plusargs("arm_wmax=%d", arm_wmax));
		void'($value$plusargs("slat_min=%d", slat_min));
		void'($value$plusargs("slat_max=%d", slat_max));
		void'($value$plusargs("inj=%d", inj));
`ifdef SELF
		void'($value$plusargs("self_ofs=%d", self_ofs));
		strict = (self_ofs == 0) ? 1 : 0;
`endif
		void'($value$plusargs("strict=%d", strict));
		void'($value$plusargs("rst_bus=%d", rst_bus));
		void'($value$plusargs("inj_at=%d", inj_at));
		void'($value$plusargs("trace_from=%d", tr_from));
		void'($value$plusargs("trace_to=%d", tr_to));
		if (slat_max < slat_min) slat_max = slat_min;
		rs = 32'h9E37_79B9 ^ (32'(seed) * 32'h85EB_CA6B);
		if (rs == 0) rs = 32'd1;
		for (int i = 0; i < 16; i++) h_post[i] = 0;
		for (int i = 0; i < 65536; i++) img[i] = 8'h00;
`ifdef SELF
		$display("tb_fe_rand: SELF (upstream against upstream), seed %0d, %0d cycles, epochs of %0d, only %s, strict %0d, self_ofs %0d",
			seed, n_cycles, epoch_len, only, strict, self_ofs);
`else
		$display("tb_fe_rand: daria_fe against upstream, seed %0d, %0d cycles, epochs of %0d, only %s, hook %0d", seed, n_cycles,
			epoch_len, only, hook_mode);
`endif
		repeat (8) @(negedge clk_sys);
		arm_reset = 1'b0;
		reset_in = 1'b0;
		pg_run = 1'b1;
		left = n_cycles;
		while (left > 0) begin
			longint n, c0;
			n = (left < epoch_len) ? left : epoch_len;
			c0 = cyc_n;
			run_epoch(n);
			left -= (cyc_n - c0);
		end
		report();
		if (nfail != 0) $fatal(1, "tb_fe_rand: FAIL (%0d failures)", nfail);
		$display("tb_fe_rand: PASS");
		$finish;
	end

	task automatic report();
		string s;
		longint bad;
		bad = 0;
		for (int c = 0; c < NBAD; c++) bad += cnt[c];
		$display("tb_fe_rand: %0d epochs, %0d cycles, %0d clk_sys; %0d agent calls, %0d ARM writes (%0d to table/pointer words)",
			epoch, cyc_n, clk_n, n_agent_calls, n_arm_wr, n_arm_wr_tbl);
		s = "";
		for (int c = 0; c < NBAD; c++) s = {s, $sformatf(" %s %0d", nm[c], cnt[c])};
		$display("  bad:%s (total %0d)", s, bad);
		s = "";
		for (int c = NBAD; c < C_N; c++) s = {s, $sformatf(" %s %0d", nm[c], cnt[c])};
		$display("  info:%s", s);
		s = "";
		for (int i = 0; i < 16; i++) if (h_post[i] != 0) s = {s, $sformatf(" %0d:%0d", i, h_post[i])};
		$display("  R1 post - accept (clk_sys):%s", s);
`ifndef SELF
		$display("  ret_tog: %0d on upstream's edge, %0d late", ret_sync_n, ret_late_n);
`endif
		$display("  bus: held %0d, phase 1 of 2/4 seen in the generator's lengths; pause clocks %0d", cnt[I_HELD], cnt[I_PAUSE_CLK]);
	endtask

`undef CHK
`undef CMP
`undef UA
endmodule

`default_nettype wire
