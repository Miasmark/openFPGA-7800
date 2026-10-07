//------------------------------------------------------------------------------
// tb_fe_copy: daria_fe_copy's unit bench (docs/daria_fe/design.md 12.3, 7;
// lane C: docs/daria_fe/lanes/C_call_copy.md).
//
// The module on daria_mem (run it with POISON=1 too), against:
//   - upstream's arm_mapper_ram_init (MIT RTL) driving a behavioural DMA
//     executor on a reference copy of the cart RAM: the image upstream
//     builds at load end and on a console reset (I1/I2), from the bench's
//     mirror of the front-end ROM;
//   - mapper_dpcplus's service arithmetic (service_fill_count,
//     service_copy_count: mapper_dpcplus.sv:85-101, 288-301), transcribed
//     here, applied to that reference when the engine takes a service.
// The bus around it is emulated: the download (cart_download, load_start,
// load_end, bytes into the front-end ROM by cap_we, some after load_end),
// bup_capture's window (cart_win falls at load_end + 63), the wrapper's
// reset register (cart_download | old | init_busy | the console reset, plus
// a reset_hold tail), a fe_phase_gen stream with DPC+ service writes
// ($105A with 1/2, RMW pairs) stalled on arm_dma_busy, a model of u_core's
// latch (taken only with !svc_pend; deferred to E0+5 in a short phase 1:
// svc_hold), and an arbiter written from design 3.1-3.3 with random
// competitors on R (core fixed, audio, P32, pointer writes), A (lookahead,
// sample) and S, and a random guard_on.
//
// Checks (12.3 items; counters in the summary; any error fails the run):
//   1  every F6 clock against the schedule of design 7.2 (CLR, P1, P2,
//      END: each state RAM, cart RAM and front-end ROM request, address,
//      byte enables and data), its length (2,082 / 8,226 clocks), and the
//      whole cart RAM (8,192 words) and state RAM against upstream's image
//      once both inits are done
//   2  F6 starts exactly at the cart_win fall (+1) or 8 clocks after a
//      rising cart_reset with an ARM image and no init; never on a fall, a
//      rise while init_busy (cart_reset dipped and risen inside F6), a
//      non-ARM image; load_start aborts F6 and a running service
//   3  init_busy: rises at load_start and at an accepted rise (upstream's
//      edges), never dips until F6's end, falls at L+1 for a non-ARM image
//      (upstream's edge)
//   4  each service: every engine byte inside [dst, dst + count), written
//      once, equal to upstream's result, all count bytes written; count by
//      upstream's min(), the source bound $8000, count 0 (run for one clock:
//      the service ends at C+2), the RMW queue (a second service latched
//      while the first runs), no engine write in a clock another R user or
//      guard_on holds the port; the whole RAM after every service
//   5  arm_dma_busy: set at C, falls only at a rel_ok edge, held while
//      svc_hold or run, 0 in the clock after any init_busy clock
//
// Plusargs: +seed +loads +run_clk +only (0 any, 1 DPC+, 2 CDF) +k_svc +k_rst
// +k_abort +k_glitch +k_guard +k_aud +k_fix +k_p32 +k_wb +k_look +k_auda
// +max_err +trace_from +trace_to, and fe_phase_gen's.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ps/1ps
`default_nettype none

`include "phase_gen.svh"

module tb_fe_copy;
	localparam int VCO = 1455;

	// ---- knobs -------------------------------------------------------------------------
	int unsigned seed     = 1;
	int          loads    = 30;
	int          run_clk  = 40000;
	int          only     = 0;
	int          k_svc    = 150;              // per mille of instructions (DPC+): a service write
	int          k_rst    = 3;                // console resets per run phase (mean)
	int          k_abort  = 120;              // per mille of loads: a new load_start inside F6 or a service
	int          k_glitch = 150;              // per mille of F6 runs: cart_reset dips inside F6
	int          k_guard  = 250;
	int          k_aud    = 250;
	int          k_fix    = 100;
	int          k_p32    = 60;
	int          k_wb     = 60;
	int          k_look   = 150;
	int          k_auda   = 100;
	int          k_takeab = 6;                // per mille per 100 run clocks (DPC+): load_start in a take clock
	int          max_err  = 20;
	longint      trace_from = 0, trace_to = 0;

	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("loads=%d", loads));
		void'($value$plusargs("run_clk=%d", run_clk));
		void'($value$plusargs("only=%d", only));
		void'($value$plusargs("k_svc=%d", k_svc));
		void'($value$plusargs("k_rst=%d", k_rst));
		void'($value$plusargs("k_abort=%d", k_abort));
		void'($value$plusargs("k_glitch=%d", k_glitch));
		void'($value$plusargs("k_guard=%d", k_guard));
		void'($value$plusargs("k_aud=%d", k_aud));
		void'($value$plusargs("k_fix=%d", k_fix));
		void'($value$plusargs("k_p32=%d", k_p32));
		void'($value$plusargs("k_wb=%d", k_wb));
		void'($value$plusargs("k_look=%d", k_look));
		void'($value$plusargs("k_auda=%d", k_auda));
		void'($value$plusargs("k_takeab=%d", k_takeab));
		void'($value$plusargs("max_err=%d", max_err));
		void'($value$plusargs("trace_from=%d", trace_from));
		void'($value$plusargs("trace_to=%d", trace_to));
		$display("tb_fe_copy: seed %0d loads %0d run_clk %0d only %0d svc %0d rst %0d abort %0d glitch %0d guard %0d",
			seed, loads, run_clk, only, k_svc, k_rst, k_abort, k_glitch, k_guard);
	end

	// ---- clocks (DARIA's lattice; clk_arm only clocks daria_mem's idle A ports) ---------------
	logic clk_sys = 1'b0, clk_arm = 1'b0;
	initial begin
		#(100000);
		forever begin clk_sys = 1'b1; #(24 * VCO); clk_sys = 1'b0; #(24 * VCO); end
	end
	initial begin
		#(100000);
		forever begin clk_arm = 1'b1; #(9 * VCO); clk_arm = 1'b0; #(9 * VCO); end
	end

	// ---- random (xorshift32) ------------------------------------------------------------------
	logic [31:0] rs = 32'h1, rq = 32'h3;
	initial begin
		rs = 32'h9E37_79B9 ^ (seed * 32'h85EB_CA6B);
		rq = 32'h5851_F42D ^ (seed * 32'h4C95_7F2D);
		if (rs == 0) rs = 1;
		if (rq == 0) rq = 1;
	end
	function automatic logic [31:0] xs(input logic [31:0] s);
		logic [31:0] x;
		x = s;
		x = x ^ (x << 13);
		x = x ^ (x >> 17);
		x = x ^ (x << 5);
		return x;
	endfunction
	function automatic int unsigned rnd(input int unsigned n);   // the sequencer's stream
		rs = xs(rs);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	function automatic int unsigned rndq(input int unsigned n);  // the per-clock stream
		rq = xs(rq);
		return (n == 0) ? 0 : (rq % n);
	endfunction

	// ---- errors and counters ----------------------------------------------------------------------
	longint e = 0;
	int     nerr = 0;
	int     err_c [string];
	longint cnt [string];
	task automatic fail(input string what, input string msg);
		nerr++;
		if (err_c.exists(what)) err_c[what]++; else err_c[what] = 1;
		if (nerr <= max_err) $display("ERROR %s @%0d: %s", what, e, msg);
	endtask
	function automatic void inc(input string k);
		if (cnt.exists(k)) cnt[k]++; else cnt[k] = 1;
	endfunction
	function automatic void add(input string k, input longint n);
		if (cnt.exists(k)) cnt[k] += n; else cnt[k] = n;
	endfunction

	// ---- the load, the scheme, the wrapper's reset -------------------------------------------------
	logic        cart_download = 1'b0, old_dl = 1'b0;
	wire         load_start = cart_download & !old_dl;
	wire         load_end   = old_dl & !cart_download;
	logic        load_valid = 1'b0;
	logic [24:0] load_addr = 25'd0;
	logic  [7:0] load_data = 8'h00;
	logic        is_dpc = 1'b0, is_cdf = 1'b0, ram32 = 1'b0;
	logic  [2:0] rev = 3'd0;
	logic        button = 1'b0, glitch = 1'b0;
	logic        rst_wr = 1'b1;
	int          hold_left = 0;
	wire         init_busy;
	wire         cart_reset = (rst_wr | (hold_left > 0)) & !glitch;
	always @(posedge clk_sys) begin
		old_dl <= cart_download;
		rst_wr <= cart_download | old_dl | init_busy | button;      // atari7800_pocket.sv:166-172
		if (rst_wr) hold_left <= 1 + int'(rndq(8));                   // top.sv's reset_hold tail (>= 1: set
		                                                              // at the edge reset is seen, top.sv:266-269)
		else if (hold_left > 0) hold_left <= hold_left - 1;
	end

	// bup_capture's window (bup_capture.sv:146-164) and the capture into the front-end ROM
	logic       c_open = 1'b0;
	logic [6:0] c_drain = 7'd0;
	wire        cart_win = load_start | c_open | (c_drain > 7'd1);
	always @(posedge clk_sys) begin
		if (load_start) begin
			c_open  <= 1'b1;
			c_drain <= 7'd0;
		end else if (load_end && c_open) begin
			c_open  <= 1'b0;
			c_drain <= 7'd64;
		end else if (c_drain != 7'd0)
			c_drain <= c_drain - 7'd1;
	end
	wire cap_we = load_valid & cart_win & (load_addr[24:15] == 10'd0);

	// ---- the bench's memories: the front-end ROM mirror, the cart RAM and state RAM reference -----
	logic [7:0]  img  [0:32767];
	logic [7:0]  rref [0:32767];
	logic [31:0] sref [0:255];
	always @(posedge clk_sys) if (cap_we) img[load_addr[14:0]] = load_data;
	function automatic logic [31:0] imgw(input int w);
		return {img[4 * w + 3], img[4 * w + 2], img[4 * w + 1], img[4 * w]};
	endfunction

	// ---- the 6507 bus: a fe_phase_gen stream with service writes (DPC+) ----------------------------
	wire        pclk1, pclk0, mapper_phi2, access, pause, load, stall_eff, ibusy, held;
	wire [12:0] a_in;
	wire        rw;
	wire  [7:0] d_in;
	wire  [5:0] len1, len2;
	wire        arm_dma_busy;
	localparam int QN = 64;
	logic [21:0] bq [0:QN-1];
	int          bq_h = 0, bq_n = 0;
	wire  [21:0] bq_head = bq[bq_h];
	fe_phase_gen #(.SEED(3), .EXT_BUS(1'b1)) pg (
		.clk_sys(clk_sys), .run(1'b1), .stall(arm_dma_busy), .driver_run(!cart_reset),
		.ext_a(bq_head[21:9]), .ext_rw(bq_head[8]), .ext_d(bq_head[7:0]),
		.pclk1(pclk1), .pclk0(pclk0), .mapper_phi2(mapper_phi2), .access(access),
		.a_in(a_in), .rw(rw), .d_in(d_in), .pause(pause), .load(load),
		.stall_eff(stall_eff), .ibusy(ibusy), .held(held), .len1(len1), .len2(len2));
	function automatic void bq_push(input logic [12:0] a, input logic w, input logic [7:0] d);
		bq[(bq_h + bq_n) % QN] = {a, !w, d};
		bq_n++;
	endfunction
	logic svc_off = 1'b0;                     // the sequencer's quiet time: no service writes generated
	function automatic bit bq_has_svc();
		for (int i = 0; i < bq_n; i++)
			if (bq[(bq_h + i) % QN][21:9] == 13'h105A && !bq[(bq_h + i) % QN][8]) return 1'b1;
		return 1'b0;
	endfunction
	task automatic gen_instr();
		int r;
		r = int'(rndq(1000));
		if (svc_off) r = 1000;                                       // quiet: reads only
		if (r < k_svc) begin
			bq_push(13'h105A, 1'b1, 8'(1 + rndq(2)));                // CALLFUNCTION 1 (copy) / 2 (fill)
			repeat (3) bq_push({1'b1, 12'(rndq(4096))}, 1'b0, 8'(rndq(256)));
			inc("prog_svc");
		end else if (r < k_svc + 30) begin                           // INC/DEC $105A: an RMW pair
			logic [7:0] d1, d2;
			case (rndq(4))
				0: begin d1 = 8'd1; d2 = 8'd2; end
				1: begin d1 = 8'd2; d2 = 8'd1; end
				2: begin d1 = 8'd0; d2 = 8'd1; end
				default: begin d1 = 8'd2; d2 = 8'd3; end
			endcase
			bq_push(13'h105A, 1'b0, 8'(rndq(256)));
			bq_push(13'h105A, 1'b1, d1);
			bq_push(13'h105A, 1'b1, d2);
			repeat (3) bq_push({1'b1, 12'(rndq(4096))}, 1'b0, 8'(rndq(256)));
			inc("prog_rmw");
		end else if (r < k_svc + 80)
			bq_push({1'b1, 12'(rndq(4096))}, 1'b1, 8'(rndq(256)));     // another write
		else
			bq_push({rndq(10) != 0, 12'(rndq(4096))}, 1'b0, 8'(rndq(256)));
	endtask
	always @(posedge clk_sys) begin
		if (load) begin
			bq_h = (bq_h + 1) % QN;
			bq_n = bq_n - 1;
		end
		while (bq_n < 8) gen_instr();
	end
	initial for (int i = 0; i < 8; i++) bq_push(13'h1000, 1'b0, 8'h00);

	logic ph2 = 1'b0;
	always @(posedge clk_sys) ph2 <= pclk1 ? 1'b0 : (pclk0 ? 1'b1 : ph2);
	wire rel_ok = (ph2 | pclk0) & !pclk1;

	// ---- u_core's service latch (2.3 kind 2; 7.3), a model ---------------------------------------------
	wire         svc_take;
	logic        svc_pend = 1'b0, defer = 1'b0, svc_fill = 1'b0;
	logic [16:0] svc_src = 17'd0;
	logic [12:0] svc_dst = 13'd0;
	logic  [7:0] svc_rem = 8'd0, svc_val = 8'd0;
	logic        n_fill;
	logic  [7:0] n_p0, n_p1, n_p3;
	logic [11:0] n_cnt;
	int          kc = 0;                      // clocks since the pclk1 clock (that clock is 0)
	wire  [5:0]  kidx = pclk1 ? 6'd0 : 6'(kc);
	wire         svc_cm = access & a_in[12] & !rw & (a_in[11:0] == 12'h05A) & ((d_in == 8'd1) | (d_in == 8'd2)) & is_dpc;
	wire         dma_set = svc_cm & !svc_pend & !defer & !cart_reset;   // a taken CALLFUNCTION 1/2, at C
	wire         svc_hold = svc_pend | defer;
	function automatic void pick_params(input logic fill);
		int r;
		n_fill = fill;
		r = int'(rndq(100));
		n_cnt = (r < 25) ? 12'hFFF - 12'(rndq(300)) : (r < 32) ? 12'hFFF : 12'(rndq(4096));
		r = int'(rndq(100));
		if (r < 20) {n_p1, n_p0} = 16'h7400 + 16'(rndq(16'h8C00));
		else if (r < 40) {n_p1, n_p0} = 16'h7400 - 16'(1 + rndq(300));
		else {n_p1, n_p0} = 16'(rndq(16'h7400));
		r = int'(rndq(100));
		n_p3 = (r < 10) ? 8'd0 : (r < 30) ? 8'd255 : 8'(rndq(256));
	endfunction
	always @(posedge clk_sys) begin
		kc <= pclk1 ? 1 : kc + 1;
		if (cart_reset) begin
			svc_pend <= 1'b0;
			defer    <= 1'b0;
		end else begin
			if (svc_take) svc_pend <= 1'b0;
			if (dma_set) begin
				pick_params(d_in == 8'd2);
				inc("dma_set");
			end
			// the latch: at C if C >= E0+5, else at E0+5 (lane A's reading A-4 of 2.3)
			if ((dma_set && kidx >= 6'd5) || (defer && kidx == 6'd5)) begin
				svc_pend <= 1'b1;
				svc_fill <= n_fill;
				svc_src  <= 17'd3072 + {1'b0, n_p1, n_p0};
				svc_dst  <= 13'd3072 + {1'b0, n_cnt};
				svc_rem  <= n_p3;
				svc_val  <= n_p0;
				defer    <= 1'b0;
				if (defer) inc("svc_deferred");
			end else if (dma_set) defer <= 1'b1;
		end
	end

	// ---- the DUT, the arbiter (design 3.1-3.3) and daria_mem --------------------------------------------
	wire        f6_act, rst_quiet, cp_req, cp_we, cz_req, ca_req;
	wire [12:0] cp_a, ca_a;
	wire  [3:0] cp_be;
	wire [31:0] cp_wd, fea_q, crb_q, stb_q;
	wire  [7:0] cz_a;
	logic       guard_on = 1'b0;
	logic       fix_req = 1'b0, aud_req = 1'b0, p32_req = 1'b0, wb_req = 1'b0;
	logic       look_req = 1'b0, auda_req = 1'b0, cs_req = 1'b0;
	logic [12:0] fix_a = 13'd0, aud_a = 13'd0, p32_a = 13'd0, wb_a = 13'd0, look_a = 13'd0, auda_a = 13'd0;
	logic  [7:0] cs_a = 8'h00;
	logic [31:0] wb_wd = 32'h0;
	int          guard_left = 0;
	always @(posedge clk_sys) begin
		logic run6;
		run6 = !cart_reset;                     // the 6507, the audio and the core run
		if (guard_left > 0) guard_left <= guard_left - 1;
		else begin
			guard_on   <= rndq(1000) < k_guard;
			guard_left <= int'(rndq(40));
		end
		fix_req  <= run6 & (rndq(1000) < k_fix);
		aud_req  <= run6 & (rndq(1000) < k_aud);
		p32_req  <= run6 & (rndq(1000) < k_p32);
		wb_req   <= run6 & (rndq(1000) < k_wb);
		look_req <= run6 & (rndq(1000) < k_look);
		auda_req <= run6 & (rndq(1000) < k_auda);
		cs_req   <= run6 & (rndq(1000) < 100);
		fix_a  <= 13'(rndq(8192));
		aud_a  <= 13'(rndq(8192));
		p32_a  <= 13'(rndq(8192));
		wb_a   <= 13'(rndq(13'h300));            // pointer-style words below the display data
		wb_wd  <= {rndq(65536), 16'(rndq(65536))};
		look_a <= 13'(rndq(8192));
		auda_a <= 13'(rndq(8192));
		cs_a   <= 8'(rndq(256));
	end
	wire fix_eff  = fix_req & !guard_on & !f6_act;
	wire aud_take = aud_req & !fix_eff & !f6_act & !guard_on;
	wire p32_gnt  = p32_req & !fix_eff & !aud_take & !guard_on & !f6_act;
	wire wb_gnt   = wb_req & !fix_eff & !aud_take & !p32_req & !guard_on & !f6_act;
	wire cp_gnt   = cp_req & (f6_act | (!fix_eff & !aud_take & !p32_req & !wb_req & !guard_on));
	wire look_gnt = look_req & !f6_act;
	wire auda_gnt = auda_req & !f6_act & !look_req;
	wire ca_gnt   = ca_req & (f6_act | (!look_req & !auda_req));

	wire [12:0] crb_addr = cp_gnt ? cp_a : fix_eff ? fix_a : aud_take ? aud_a : p32_gnt ? p32_a : wb_gnt ? wb_a : 13'd0;
	wire        crb_we   = (cp_gnt & cp_we) | wb_gnt;
	wire  [3:0] crb_be   = cp_gnt ? cp_be : 4'hF;
	wire [31:0] crb_wd   = cp_gnt ? cp_wd : wb_wd;
	wire [12:0] fea_addr = ca_gnt ? ca_a : look_gnt ? look_a : auda_gnt ? auda_a : 13'd0;
	wire  [7:0] stb_addr = cz_req ? cz_a : cs_req ? cs_a : 8'h00;
	wire        stb_we   = cz_req;

	daria_fe_copy u_copy (
		.clk_sys(clk_sys), .cart_reset(cart_reset), .load_start(load_start), .load_end(load_end),
		.cart_win(cart_win), .is_dpc(is_dpc), .is_cdf(is_cdf), .ram32(ram32), .rel_ok(rel_ok),
		.guard_on(guard_on), .svc_pend(svc_pend), .svc_hold(svc_hold), .svc_fill(svc_fill),
		.svc_src(svc_src), .svc_dst(svc_dst), .svc_rem(svc_rem), .svc_val(svc_val), .dma_set(dma_set),
		.svc_take(svc_take), .init_busy(init_busy), .arm_dma_busy(arm_dma_busy), .f6_act(f6_act),
		.rst_quiet(rst_quiet), .cp_req(cp_req), .cp_a(cp_a), .cp_we(cp_we), .cp_be(cp_be),
		.cp_wd(cp_wd), .cp_gnt(cp_gnt), .cz_req(cz_req), .cz_a(cz_a), .ca_req(ca_req), .ca_a(ca_a),
		.ca_gnt(ca_gnt), .fea_q(fea_q));

	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(clk_arm), .clk_sys(clk_sys),
		.rom_addr(15'd0), .win_qa(), .d_addr(32'd0), .win_qb(), .ram_we(1'b0), .ram_be(4'd0),
		.ram_wdata(32'd0), .ram_q(), .img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0),
		.win_be(4'd0), .sta_addr(8'd0), .sta_we(1'b0), .sta_wd(32'd0), .sta_q(),
		.cap_we(cap_we), .cap_addr(load_addr[14:0]), .cap_data(load_data), .fea_addr(fea_addr), .fea_q(fea_q),
		.feb_addr(13'd0), .feb_q(), .crb_addr(crb_addr), .crb_we(crb_we), .crb_be(crb_be), .crb_wd(crb_wd),
		.crb_q(crb_q), .stb_addr(stb_addr), .stb_we(stb_we), .stb_be(4'hF), .stb_wd(32'd0), .stb_q(stb_q));

	// the competitors' pointer writes go into the reference too
	int watch = -1;
	initial void'($value$plusargs("watch=%h", watch));
	always @(posedge clk_sys) begin
		if (watch >= 0 && crb_we && int'(crb_addr) == watch)
			$display("WATCH @%0d write %04x be %b wd %08x (cp %b wb %b f6 %b rst %b)", e, crb_addr, crb_be, crb_wd, cp_gnt, wb_gnt, f6_act, cart_reset);
		if (watch >= 0 && dma_request && !dbusy) $display("WATCH @%0d upstream DMA fill %b src %05x dst %05x n %0d", e, dma_fill, dma_source, dma_dest, dma_count);
	end

	// ---- upstream's ram_init with a behavioural DMA executor (the image reference) --------------------
	wire  [1:0] fam_u = is_dpc ? 2'd1 : is_cdf ? 2'd3 : 2'd0;     // cart2600.sv:658-660
	logic       load_end_d = 1'b0;
	always @(posedge clk_sys) load_end_d <= load_end & !load_start; // cart2600.sv:572-577
	wire        ri_busy, dma_request, dma_fill;
	wire [24:0] dma_source;
	wire [16:0] dma_dest;
	wire [17:0] dma_count;
	wire  [7:0] dma_value;
	logic       dbusy = 1'b0, dma_done = 1'b0;
	int         dleft = 0;
	arm_mapper_ram_init u_ri (
		.clk_sys(clk_sys), .mapper_reset(cart_reset), .load_start(load_start), .load_end(load_end_d),
		.family(fam_u), .revision(rev), .mapper_ram_size(ram32 ? 16'd32768 : 16'd8192), .busy(ri_busy),
		.dma_request(dma_request), .dma_fill(dma_fill), .dma_source(dma_source), .dma_dest(dma_dest),
		.dma_count(dma_count), .dma_value(dma_value), .dma_ready(!dbusy), .dma_done(dma_done),
		.ram_en(), .ram_addr(), .ram_word_rdata(32'd0),
		.table_pointer_write(), .table_pointer_index(), .table_pointer_wdata(),
		.table_increment_write(), .table_increment_index(), .table_increment_wdata(),
		.table_map_write(), .table_map_index(), .table_map_wdata());
	longint ri_dmas = 0;
	always @(posedge clk_sys) begin
		dma_done <= 1'b0;
		if (dma_request && !dbusy) begin
			dbusy <= 1'b1;
			dleft <= 2 + int'(rndq(12));
			for (int i = 0; i < int'(dma_count); i++)
				rref[(int'(dma_dest) + i) & 32'h7FFF] = dma_fill ? dma_value : img[(int'(dma_source) + i) & 32'h7FFF];
			ri_dmas++;
		end else if (dbusy) begin
			if (dleft == 0) begin
				dbusy    <= 1'b0;
				dma_done <= 1'b1;
			end else dleft <= dleft - 1;
		end
	end

	// ---- the service reference (mapper_dpcplus.sv:85-101, 288-301) --------------------------------------
	int          s_dest = 0, s_count = 0, s_left = 0;
	logic        s_act = 1'b0, s_fill = 1'b0;
	logic [255:0] s_done;
	longint      s_take_e = 0;
	function automatic int up_count(input logic fill, input logic [7:0] p0, input logic [7:0] p1,
	                                input logic [7:0] p3, input logic [11:0] counter);
		logic [15:0] off;
		logic [12:0] dest_avail;
		logic [16:0] src_avail;
		logic  [7:0] fill_count, copy_count;
		off        = {p1, p0};
		dest_avail = 13'h1000 - {1'b0, counter};
		src_avail  = 17'h07400 - {1'b0, off};
		fill_count = p3;
		if (dest_avail < {5'b0, p3}) fill_count = dest_avail[7:0];
		copy_count = fill_count;
		if (off >= 16'h7400) copy_count = 8'b0;
		else if (src_avail < {9'b0, fill_count}) copy_count = src_avail[7:0];
		return fill ? int'(fill_count) : int'(copy_count);
	endfunction

	// ---- checks, every clock ---------------------------------------------------------------------------
	// the bench's own F6 prediction
	logic        arm_ld = 1'b0, arm_dpc = 1'b0, arm_r32 = 1'b0;   // the last load: ARM image, family
	logic        ld1_b = 1'b0, cw_b = 1'b0, rq_b = 1'b0;
	logic        ib_b = 1'b0;                     // init_busy expected
	int          rdl_b = 0;
	longint      f6_t = -1;                       // the F6 clock index, -1 idle
	logic        f6_fam_dpc = 1'b0, f6_fam_r32 = 1'b0;
	longint      f6_len_b = 0;
	logic        dmab = 1'b0;                     // arm_dma_busy expected
	logic        run_q = 1'b0, ib_q = 1'b0;
	logic        rel_ok_q = 1'b0;
	longint      run_rise = 0;
	logic        glitch_q = 1'b0;
	int          gl_age = 100;                   // clocks since cart_reset was last forced low
	logic        ld1_q = 1'b0, rise_q = 1'b0;
	logic        ls_q = 1'b0;                    // load_start in the last clock
	int          rlen = 0;                       // clocks cart_reset has been high before this one
	logic        q_exp = 1'b0;                   // rst_quiet expected: cart_reset high in the last 8 clocks

	always @(posedge clk_sys) begin
		logic        rise, f6_go_b, exp_cz, exp_cp, exp_ca, w_ok;
		logic [12:0] exp_cpa, exp_caa;
		logic  [7:0] exp_cza;
		logic [31:0] exp_wd;
		logic  [3:0] exp_ph;
		longint      t, d;

		if (e >= trace_from && e < trace_to)
			$display("@%0d dl %b ls %b le %b win %b rst %b gl %b ib %b f6 %b ph %b t %0d | cz %b %02x cp %b %04x %b %08x gnt %b ca %b %04x g %b | run %b fill %b src %05x dst %04x rem %0d take %b pend %b hold %b dset %b dma %b rel %b | g %b aud %b fix %b",
				e, cart_download, load_start, load_end, cart_win, cart_reset, glitch, init_busy, f6_act, u_copy.f6_ph, f6_t,
				cz_req, cz_a, cp_req, cp_a, cp_be, cp_wd, cp_gnt, ca_req, ca_a, ca_gnt,
				u_copy.run, u_copy.fill, u_copy.src, u_copy.dst, u_copy.rem, svc_take, svc_pend, svc_hold, dma_set,
				arm_dma_busy, rel_ok, guard_on, aud_take, fix_eff);

		// -- F6's start, as the bench predicts it (7.1) -------------------------------------------------
		rise    = cart_reset & !rq_b;
		f6_go_b = !load_start && ((cw_b && !cart_win && arm_ld) || rdl_b == 1);
		if (rise && arm_ld && !ib_b && !load_start) inc("reset_rise_accepted");
		if (rise && !(arm_ld && !ib_b)) inc(ib_b ? "reset_rise_ignored_busy" : "reset_rise_ignored_noarm");

		// -- F6, every clock against design 7.2 -----------------------------------------------------------
		exp_cz = 1'b0; exp_cza = 8'h00; exp_cp = 1'b0; exp_cpa = 13'd0; exp_wd = 32'd0; exp_ca = 1'b0; exp_caa = 13'd0;
		exp_ph = 4'd0;
		t = f6_t;
		if (t >= 0) begin
			if (t < 32) begin
				exp_ph = 4'b0001; exp_cz = 1'b1; exp_cza = 8'(t);
			end else if (f6_fam_dpc) begin
				if (t < 800) begin
					exp_ph = 4'b0010; exp_cp = 1'b1; exp_cpa = 13'(t - 32);
				end else if (t < 2080) begin
					exp_ph = 4'b0100; exp_ca = 1'b1; exp_caa = 13'(13'h1B00 + (t - 800));
					if (t > 800) begin exp_cp = 1'b1; exp_cpa = 13'(13'h300 + (t - 801)); exp_wd = imgw(32'h1B00 + int'(t - 801)); end
				end else begin
					exp_ph = 4'b1000;
					if (t == 2080) begin exp_cp = 1'b1; exp_cpa = 13'h7FF; exp_wd = imgw(32'h1FFF); end
				end
			end else begin
				if (t < 544) begin
					exp_ph = 4'b0010; exp_ca = 1'b1; exp_caa = 13'(t - 32);
					if (t > 32) begin exp_cp = 1'b1; exp_cpa = 13'(t - 33); exp_wd = imgw(int'(t - 33)); end
				end else if (t == 544) begin
					exp_ph = 4'b0100; exp_cp = 1'b1; exp_cpa = 13'h1FF; exp_wd = imgw(32'h1FF);
				end else if (t < 545 + (f6_fam_r32 ? 7680 : 1536)) begin
					exp_ph = 4'b0100; exp_cp = 1'b1; exp_cpa = 13'(13'h200 + (t - 545));
				end else exp_ph = 4'b1000;
			end
			if (!f6_act) fail("f6", $sformatf("f6_act low at F6 clock %0d", t));
			if (u_copy.f6_ph !== exp_ph) fail("f6", $sformatf("f6_ph %b at clock %0d, expected %b", u_copy.f6_ph, t, exp_ph));
			if (cz_req !== exp_cz || (exp_cz && cz_a !== exp_cza)) fail("f6", $sformatf("cz %b %02x at clock %0d, expected %b %02x", cz_req, cz_a, t, exp_cz, exp_cza));
			if (cp_req !== exp_cp || (exp_cp && (cp_a !== exp_cpa || cp_be !== 4'hF || cp_wd !== exp_wd || !cp_we)))
				fail("f6", $sformatf("cp %b %04x %b %08x at clock %0d, expected %b %04x F %08x", cp_req, cp_a, cp_be, cp_wd, t, exp_cp, exp_cpa, exp_wd));
			if (ca_req !== exp_ca || (exp_ca && ca_a !== exp_caa)) fail("f6", $sformatf("ca %b %04x at clock %0d, expected %b %04x", ca_req, ca_a, t, exp_ca, exp_caa));
			if (u_copy.run) fail("f6", "the engine runs during F6");
			if (!init_busy) fail("init_busy", "low during F6");
			if (u_copy.a_f6_live !== !rst_quiet) fail("a_f6_live", "formula");
			if (u_copy.a_f6_live) begin
				if (gl_age < 12) inc("a_f6_live_glitch"); else fail("a_f6_live", "F6 without rst_quiet");
			end
			inc("f6_clocks");
		end else begin
			if (f6_act) fail("f6", "f6_act high outside the predicted F6");
			if (cz_req || u_copy.f6_ph != 4'd0) fail("f6", "F6 requests outside F6");
		end

		// -- rst_quiet: cart_reset high in each of the last 8 clocks -----------------------------------
		if (rst_quiet !== q_exp) fail("rst_quiet", $sformatf("rst_quiet %b, expected %b (reset high for %0d clocks)", rst_quiet, q_exp, rlen));
		q_exp <= cart_reset && (rlen + 1 >= 8);
		rlen  <= cart_reset ? rlen + 1 : 0;

		// -- init_busy (D6) ---------------------------------------------------------------------------
		if (init_busy !== ib_b) fail("init_busy", $sformatf("init_busy %b, expected %b", init_busy, ib_b));
		// upstream's busy: high whenever its loading flag is, and on the edges ours rises
		if (u_ri.loading && !init_busy) fail("init_busy", "low while upstream's ram_init is loading");
		if (ld1_q && !arm_ld && (init_busy || ri_busy)) fail("init_busy", "a non-ARM image: init_busy or upstream's busy still high at L+1");
		if (rise_q && (init_busy !== ri_busy)) fail("init_busy", $sformatf("after an accepted reset rise: init_busy %b, upstream %b", init_busy, ri_busy));
		if (rise_q) inc("rise_vs_upstream");

		// -- the engine ---------------------------------------------------------------------------------
		if (svc_take !== (svc_pend & !u_copy.run & !init_busy & !f6_act & !load_start & !cart_reset))
			fail("svc_take", "svc_take formula");
		if (cp_gnt && !f6_act && cp_req) begin                        // an engine write registers here
			if (!u_copy.run) fail("engine", "a write with run low");
			if (guard_on || aud_take || fix_eff || p32_req || wb_req) fail("engine", "a write in a clock another user or the guard holds");
			if (!s_act) fail("engine", "a write without a taken service");
			for (int b = 0; b < 4; b++) if (cp_be[b]) begin
				int a;
				a = 4 * int'(cp_a) + b;
				if (a < s_dest || a >= s_dest + s_count) fail("engine", $sformatf("byte %04x outside [%04x, +%0d)", a, s_dest, s_count));
				else begin
					if (s_done[a - s_dest]) fail("engine", $sformatf("byte %04x written twice", a));
					s_done[a - s_dest] = 1'b1;
					s_left--;
					if (cp_wd[8 * b +: 8] !== rref[a]) fail("engine", $sformatf("byte %04x %02x, upstream %02x", a, cp_wd[8 * b +: 8], rref[a]));
				end
			end
			inc(u_copy.fill ? "fill_word_writes" : "copy_byte_writes");
			if (u_copy.fill && $countones(cp_be) < 4) inc("fill_partial_words");
		end
		if (cp_req && !cp_gnt && !f6_act) inc("engine_denied");
		if (cp_req && !cp_gnt && !f6_act && guard_on) inc("engine_denied_guard");
		if (ca_req && !ca_gnt && !f6_act) inc("copy_src_denied");
		// load_start aborts the engine: no run after it, and a latched service is not taken in its
		// clock (interfaces.md 10 item 5)
		if (ls_q && u_copy.run) fail("engine", "run high in the clock after load_start");
		if (load_start && svc_pend && !u_copy.run && !init_busy && !f6_act && !cart_reset) inc("load_start_in_take_clock");
		if (run_q && !u_copy.run) begin                              // the engine stopped
			if (cart_reset || load_start || rq_b) inc("svc_abandoned");
			else begin
				if (s_left != 0) fail("engine", $sformatf("service ended with %0d of %0d bytes unwritten", s_left, s_count));
				if (s_count == 0 && e - run_rise != 1) fail("engine", $sformatf("count 0 ran %0d clocks", e - run_rise));
				for (int w = 0; w < 8192; w++)
					if (u_mem.cart_ram.mem_q[w] !== {rref[4*w+3], rref[4*w+2], rref[4*w+1], rref[4*w]})
						fail("svc_ram", $sformatf("word %04x %08x, upstream %08x", w, u_mem.cart_ram.mem_q[w], {rref[4*w+3], rref[4*w+2], rref[4*w+1], rref[4*w]}));
				inc("svc_checked");
				add(s_fill ? "svc_fill_clocks" : "svc_copy_clocks", e - run_rise);
				add(s_fill ? "svc_fill_bytes" : "svc_copy_bytes", s_count);
			end
			s_act = 1'b0;
		end
		if (svc_take) begin
			int c;
			c = up_count(svc_fill, svc_val, 8'((svc_src - 17'd3072) >> 8), svc_rem, 12'(svc_dst - 13'd3072));
			if (s_act) fail("engine", "a service taken while the last is still checked");
			s_act    = 1'b1;
			s_fill   = svc_fill;
			s_dest   = int'(svc_dst);
			s_count  = c;
			s_left   = c;
			s_done   = '0;
			s_take_e = e;
			for (int i = 0; i < c; i++)
				rref[int'(svc_dst) + i] = svc_fill ? svc_val : img[int'(svc_src) + i];
			inc(svc_fill ? "svc_fill" : "svc_copy");
			if (c == 0) inc("svc_count0");
			if (c < int'(svc_rem)) inc("svc_clamped");
			if (!svc_fill && int'(svc_src) + int'(svc_rem) > 32'h8000) inc("svc_src_bound");
			if (int'(svc_dst) + int'(svc_rem) > 32'h1C00) inc("svc_dst_bound");
			if (arm_dma_busy) inc("svc_taken_while_busy");
		end
		if (!run_q && u_copy.run) run_rise <= e;
		if (svc_take && run_q) inc("svc_queued_rmw");

		// -- arm_dma_busy (7.4, D3) --------------------------------------------------------------------
		if (arm_dma_busy !== dmab) fail("dma_busy", $sformatf("arm_dma_busy %b, expected %b", arm_dma_busy, dmab));
		if (ib_q && arm_dma_busy) fail("dma_busy", "high in the clock after an init_busy clock");

		// -- next ------------------------------------------------------------------------------------------
		// the bench's F6 and init_busy model
		if (load_start) begin
			f6_t  <= -1;
			rdl_b <= 0;
			ib_b  <= 1'b1;
			if (f6_t >= 0) inc("f6_aborted_by_load");
		end else begin
			if (rise && arm_ld && !ib_b) begin
				rdl_b <= 8;
				ib_b  <= 1'b1;
			end else if (rdl_b > 0) rdl_b <= rdl_b - 1;
			if (f6_go_b) begin
				f6_t       <= 0;
				f6_fam_dpc <= arm_dpc;
				f6_fam_r32 <= arm_r32;
				f6_len_b   <= arm_dpc ? 2082 : (arm_r32 ? 8226 : 2082);
				inc(rdl_b == 1 ? "f6_by_reset" : "f6_by_window");
				if (rdl_b == 1 && (cw_b && !cart_win && arm_ld)) fail("f6", "both triggers in one clock");
			end else if (f6_t >= 0) begin
				if (f6_t + 1 == f6_len_b) begin
					f6_t <= -1;
					ib_b <= 1'b0;
					for (int w = 0; w < 32; w++) sref[w] = 32'd0;     // the state-RAM clear (CLR)
					inc(f6_fam_dpc ? "f6_dpc" : f6_fam_r32 ? "f6_cdfj_plus" : "f6_cdf8k");
				end else f6_t <= f6_t + 1;
			end
			if (ld1_b && !(is_dpc | is_cdf)) ib_b <= 1'b0;
		end
		if (load_start) arm_ld <= 1'b0;
		else if (ld1_b) begin
			arm_ld  <= is_dpc | is_cdf;
			arm_dpc <= is_dpc;
			arm_r32 <= ram32;
		end
		ld1_b <= load_end;
		cw_b  <= cart_win;
		rq_b  <= cart_reset;

		// arm_dma_busy expected
		if (cart_reset | init_busy) dmab <= 1'b0;
		else if (dma_set) dmab <= 1'b1;
		else if (dmab & !svc_hold & !u_copy.run & rel_ok) dmab <= 1'b0;
		if (dmab && !(cart_reset | init_busy) && !dma_set && !svc_hold && !u_copy.run && rel_ok) inc("dma_busy_falls");
		if (dmab && !(cart_reset | init_busy) && !svc_hold && !u_copy.run && !rel_ok) inc("dma_busy_tail_clocks");

		// the competitors' pointer writes into the reference, after this edge's compares
		if (wb_gnt) for (int b = 0; b < 4; b++) rref[4 * int'(wb_a) + b] = wb_wd[8 * b +: 8];
		run_q    <= u_copy.run;
		ib_q     <= init_busy;
		glitch_q <= glitch;
		gl_age   <= glitch ? 0 : (gl_age < 100 ? gl_age + 1 : 100);
		ld1_q    <= ld1_b & !load_start;
		ls_q     <= load_start;
		rise_q   <= rise && arm_ld && !ib_b && !load_start && !ri_busy && gl_age >= 100;
		e <= e + 1;
	end

	// ---- the sequencer ---------------------------------------------------------------------------------------
	task automatic wait_clk(input int n);
		repeat (n) @(posedge clk_sys);
	endtask
	task automatic compare_image(input string why);
		int bad;
		bad = 0;
		for (int w = 0; w < 8192; w++)
			if (u_mem.cart_ram.mem_q[w] !== {rref[4*w+3], rref[4*w+2], rref[4*w+1], rref[4*w]}) begin
				bad++;
				if (bad <= 4) fail("image", $sformatf("%s: word %04x %08x, upstream %08x", why, w, u_mem.cart_ram.mem_q[w],
					{rref[4*w+3], rref[4*w+2], rref[4*w+1], rref[4*w]}));
			end
		for (int w = 0; w < 256; w++)
			if (u_mem.state_ram.mem_q[w] !== sref[w]) begin
				bad++;
				if (bad <= 8) fail("state_ram", $sformatf("%s: word %02x %08x", why, w, u_mem.state_ram.mem_q[w]));
			end
		if (bad == 0) inc("images_equal");
	endtask
	// the engine and the latch go idle within 100,000 clocks
	task automatic drain_engine(input int ld);
		int to;
		to = 0;
		while ((u_copy.run || svc_pend || defer) && to < 100000) begin
			@(posedge clk_sys);
			to++;
		end
		if (to >= 100000) begin
			fail("timeout", $sformatf("load %0d: the engine never finished", ld));
			$fatal(1, "tb_fe_copy: the engine never finished");
		end
	endtask
	// F6 starts within 100,000 clocks
	task automatic wait_for_f6(input string why);
		int to;
		to = 0;
		do begin
			@(posedge clk_sys);
			to++;
		end while (!f6_act && to < 100000);
		if (!f6_act) begin
			fail("timeout", $sformatf("%s: F6 never started", why));
			$fatal(1, "tb_fe_copy: F6 never started");
		end
	endtask
	// both inits done; a cart_reset dip inside F6 at random
	task automatic wait_inits(input string why);
		int to;
		bit glitched;
		to = 0;
		glitched = 0;
		do begin
			@(posedge clk_sys);
			if (f6_act && !glitched && f6_t > 100 && rnd(1000) < k_glitch) begin
				glitched = 1;
				glitch <= 1'b1;
				wait_clk(1 + rnd(3));
				glitch <= 1'b0;
				inc("glitches");
			end
			to++;
		end while ((init_busy || ri_busy || dbusy) && to < 200000);
		if (to >= 200000) begin
			fail("timeout", $sformatf("%s: init never ended", why));
			$fatal(1, "tb_fe_copy: init never ended");
		end
		@(posedge clk_sys);
		compare_image(why);
	endtask
	// a download of `size` bytes; `late` of them come after load_end
	task automatic download(input int size, input int late, input int sch, input logic [2:0] r);
		cart_download <= 1'b1;
		@(posedge clk_sys);                         // load_start is high in this clock
		is_dpc <= 1'b0; is_cdf <= 1'b0; ram32 <= 1'b0; rev <= 3'd0;
		for (int a = 0; a < size - late; a++) begin
			load_valid <= 1'b1;
			load_addr  <= 25'(a);
			load_data  <= 8'(rnd(256));
			@(posedge clk_sys);
			if (rnd(8) == 0) begin load_valid <= 1'b0; @(posedge clk_sys); end
		end
		load_valid <= 1'b0;
		cart_download <= 1'b0;
		@(posedge clk_sys);                         // load_end is high in this clock
		is_dpc <= sch == 1;
		is_cdf <= sch == 2;
		rev    <= r;
		ram32  <= (sch == 2) && (r == 3'd3);
		for (int a = size - late; a < size; a++) begin
			wait_clk(rnd(3));
			load_valid <= 1'b1;
			load_addr  <= 25'(a);
			load_data  <= 8'(rnd(256));
			@(posedge clk_sys);
			load_valid <= 1'b0;
		end
	endtask

	initial begin
		// power-up contents: a stale image in the front-end ROM, random cart RAM and state RAM
		#(1000);
		for (int i = 0; i < 32768; i++) begin
			img[i]  = 8'(rnd(256));
			rref[i] = 8'(rnd(256));
		end
		for (int w = 0; w < 8192; w++) begin
			u_mem.fe_rom.mem_q[w]   = imgw(w);
			u_mem.cart_ram.mem_q[w] = {rref[4*w+3], rref[4*w+2], rref[4*w+1], rref[4*w]};
		end
		for (int w = 0; w < 256; w++) begin
			sref[w] = {rnd(65536), 16'(rnd(65536))};
			u_mem.state_ram.mem_q[w] = sref[w];
		end
		wait_clk(20);
		for (int ld = 0; ld < loads; ld++) begin
			int sch, size, late;
			logic [2:0] r;
			bit abort;
			sch  = (only == 1) ? 1 : (only == 2) ? 2 : ((rnd(10) == 0) ? 0 : 1 + int'(rnd(2)));
			r    = (sch == 2) ? 3'(rnd(4)) : 3'(rnd(2));
			size = (sch == 1 && rnd(6) == 0) ? 29696 : (sch == 2 && rnd(3) == 0) ? 32768 + int'(rnd(4096)) : 32768;
			late = int'(rnd(5));
			abort = rnd(1000) < k_abort;
			inc(sch == 1 ? "loads_dpc" : sch == 2 ? ((r == 3) ? "loads_cdfj_plus" : "loads_cdf") : "loads_other");
			if (size == 29696) inc("loads_dpc_29k");
			download(size, late, sch, r);
			if (abort && sch != 0) begin
				// a new download while F6 runs: load_start aborts it
				wait_for_f6($sformatf("abort in load %0d", ld));
				wait_clk(int'(rnd(1500)));
				inc("abort_loads");
				download(32768, 0, sch, r);
			end
			wait_inits($sformatf("load %0d", ld));
			// the 6507 runs: services (DPC+), console resets, an aborting download
			for (int c = 0; c < run_clk; c += 100) begin
				wait_clk(100);
				if (rnd(run_clk / 100) < k_rst) begin
					// a console reset: the bench presses it for a while; F6 re-runs at the rise + 8
					button <= 1'b1;
					wait_clk(1 + rnd(40));
					button <= 1'b0;
					inc("console_resets");
					wait_inits($sformatf("reset in load %0d", ld));
				end
				if (sch == 1 && rnd(1000) < k_takeab) begin
					// a download whose load_start falls in the clock a latched service would be taken
					// (the latch is up, the engine idle): load_start wins, nothing runs
					int to;
					to = 0;
					do begin
						@(negedge clk_sys);
						to++;
					end while (!(svc_pend && !u_copy.run && !init_busy && !f6_act && !cart_reset && !cart_download) && to < 20000);
					if (to < 20000) begin
						inc("abort_on_take");
						download(32768, int'(rnd(5)), sch, r);
						wait_inits($sformatf("take-clock reload in load %0d", ld));
					end
				end
				if (sch == 1 && u_copy.run && rnd(1000) < 3) begin
					inc("abort_service_load");
					download(32768, int'(rnd(5)), sch, r);
					wait_inits($sformatf("reload in load %0d", ld));
				end
			end
			// stop generating services, let the queued ones and the engine finish, then compare
			svc_off = 1'b1;
			for (int pass = 0; pass < 2; pass++)
				do begin
					wait_clk(400);
					drain_engine(ld);
				end while (bq_has_svc());
			wait_clk(5);
			compare_image($sformatf("end of load %0d", ld));
			svc_off = 1'b0;
		end
		wait_clk(10);
		$display("tb_fe_copy: %0d clocks, %0d upstream DMAs", e, ri_dmas);
		begin
			string ks;
			if (cnt.first(ks)) do $display("  %-26s %0d", ks, cnt[ks]); while (cnt.next(ks));
			if (err_c.first(ks)) do $display("  ERRORS %-19s %0d", ks, err_c[ks]); while (err_c.next(ks));
		end
		if (nerr != 0) $fatal(1, "tb_fe_copy: %0d errors", nerr);
		$display("tb_fe_copy: PASS");
		$finish;
	end
endmodule

`default_nettype wire
