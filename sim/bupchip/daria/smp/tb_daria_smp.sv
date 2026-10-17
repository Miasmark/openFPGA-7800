//------------------------------------------------------------------------------
// tb_daria_smp: DARIA's sample requester (src/fpga/core/bupchip/daria_smp.sv)
// between the asset cache and bup_asset_wr, wired as bupchip_pocket.sv wires
// it with POCKET_DARIA, on psram.sv at CLOCK_SPEED 50.0 and psram_model.sv
// (docs/daria_step7/plan.md 2.2, P7, and 3.3 gate item 3). No game data: the
// image is a pattern of its byte offsets.
//
// Clocks on the PLL's lattice: clk_sys toggles every 34,920 ps (VCO/48);
// clk_arm (VCO/18) starts high and toggles every 13,095 ps from +phase=PS, so
// it rises at phase + 26,190 n: 8 clk_arm per 3 clk_sys. 0, 8,730 and 17,460
// put the shared edge on each of the three clk_sys classes; 13,095 shares
// none; +phase=-1 draws a phase from the seed.
//
// What runs, in order:
//   1. a power-up hold (300 clk_sys), then 200 clk_sys with no image;
//   2. the image load: START, one image-mode WRITE per halfword (one message
//      every 4 clk_sys, as bup_capture paces them) and END, into bup_asset_wr
//      and through it into psram_model (+imgkb, default 512);
//   3. the CPU side: +loads byte, halfword and word loads through the asset
//      cache (bup_cpu S1's protocol at the asset port, as tb_cache drives
//      it: an execute clock, then W held while w_wait), with episodes between
//      loads: a hold (the cache held and the sampler not readable), a mapper
//      reset (the cache held, the sampler readable) and the Souper profile
//      (the cache running, the sampler not readable);
//   4. a second load of another image (+img2kb, default 160) and +loads / 4
//      more loads on it;
//   5. with samples, +reloads more images of 40 to 72 KB, each loaded over
//      the last while the CPU and the sample client run, with the START
//      timed on the sampler, in turn: on the clk_sys edge that posts a
//      request while a cache fill runs, one clk_sys after that edge, and on
//      the first clk_sys edge after the sampler's start, after its read
//      waits behind a cache read, and after its read is taken. A CPU load
//      the START holds is dropped, not checked: it would finish on the next
//      image.
// All the time (unless +nosmp), a model of the front end's sample client on
// clk_sys (daria_fe_audio.sv: req_q toggle, saddr_q, ack_s1/ack_s2, ack_hit,
// rdat) posts requests 0 to +gap clk_sys after each answer, at random image
// offsets (mostly above 32 KB, some below, some near the CPU's recent loads).
//
// Checks (each must be 0):
//   data     an answer is not what the requester owed: the image byte, or
//            $FF when it was not readable at its first chance to start (the
//            first clock daria_smp's start is high for the request). At or
//            beyond the readable image's size (img_size at that start: a
//            request drawn for the last image and started once the next one
//            is ready, which the real front end never makes) the byte owed
//            is the one psram_model holds there at that start. A request
//            raced by a load (readable at its start, then a START before its
//            halfword arrived) is owed that byte or the new image's
//   sync     a request started fewer than three clk_arm edges after its
//            toggle: smp_req's synchroniser is two flops
//   image    a halfword of a loaded image that psram_model does not hold,
//            checked over the whole image as each load's img_ready rises
//   check    an answered image byte, read again as a byte load through the
//            cache, differs from the cache's own asset_q
//   load     a CPU load returns other than the image bytes
//   spur     an answer toggle with no request open; at the end the answers
//            seen, the answers taken and the requests must be equal
//   lost     a request open for 2,000 clk_sys
//   proto    smp_data changes on the edge smp_ack flips, or while no answer
//            is owed (as many toggles as requests): the held-bus contract,
//            the byte first and the toggle a clock later
//   both_fl  the cache's read and the sampler's read in flight together
//   own_ack  the cache sees rd_ack while the sampler owns the read port
//   ff_slow  a $FF answer later than 450 ns after its request
//   psram    psram_model's violations and late reads, bup_asset_wr's overrun
//   stuck    a CPU load waiting 400 clocks
// and the coverage counters must each reach their minimum (unless +nosmp):
// $FF answers in a hold, in a load and in the Souper profile, image bytes,
// a sampler read wanted while the cache asks for the port, and while a cache
// read is in flight, the sampler's read taken on the clock a cache read
// arrives, sampler reads while the cache is held; and with +reloads, a START
// while the sampler's read is wanted (pend) and while it is in flight (fl),
// and raced answers. The maximum answer times are reported.
//
// +stream=FILE writes one line per CPU load of the two main streams (index,
// offset, size, the bytes it returned). run_smp.sh compares the file of a run
// with samples against the same seed's +nosmp run: the cache's asset_q stream
// must not change.
//
// Plusargs: +seed=N (1) +phase=PS (0; -1 random) +loads=N (40000) +imgkb=K
// (512) +img2kb=K (160) +reloads=N (16; 0 for none) +gap=N (60) +nosmp
// +stream=FILE. The last line is "result: PASS ..." or "result: FAIL ...";
// a failure also ends in $fatal.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_daria_smp;
	// ---- configuration and random streams --------------------------------------------
	int unsigned seed = 1;
	int          phase = 0;
	int          n_loads = 40000;
	int          img_kb = 512, img2_kb = 160;
	int          smp_gap = 60;
	int          n_reloads = 16;
	int          max_ms = 3000;                   // watchdog, simulated ms
	bit          nosmp = 0;
	int          fd_stream = 0;
	// Separate streams, so that the CPU's loads and the episodes are the same
	// with and without samples: rs_load the loads and their gaps, rs_ep the
	// episodes, rs_smp the requests, rs_misc the rest; rs_rl the reloads
	// (stage 5), so that stages 1-4 are the same with and without them.
	int unsigned rs_load = 1, rs_ep = 1, rs_smp = 1, rs_misc = 1, rs_rl = 1;
	function automatic int unsigned xs(input int unsigned s);
		s ^= s << 13;
		s ^= s >> 17;
		s ^= s << 5;
		return s;
	endfunction
	function automatic int r_load(input int n);
		rs_load = xs(rs_load);
		return int'(rs_load % n);
	endfunction
	function automatic int r_ep(input int n);
		rs_ep = xs(rs_ep);
		return int'(rs_ep % n);
	endfunction
	function automatic int r_smp(input int n);
		rs_smp = xs(rs_smp);
		return int'(rs_smp % n);
	endfunction
	function automatic int r_misc(input int n);
		rs_misc = xs(rs_misc);
		return int'(rs_misc % n);
	endfunction
	function automatic int r_rl(input int n);
		rs_rl = xs(rs_rl);
		return int'(rs_rl % n);
	endfunction

	// ---- clocks ------------------------------------------------------------------------
	logic clk_sys = 1'b0;
	logic clk_arm = 1'b1;
	always #34920 clk_sys = ~clk_sys;
	initial begin
		string f;
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("loads=%d", n_loads));
		void'($value$plusargs("imgkb=%d", img_kb));
		void'($value$plusargs("img2kb=%d", img2_kb));
		void'($value$plusargs("gap=%d", smp_gap));
		void'($value$plusargs("reloads=%d", n_reloads));
		void'($value$plusargs("maxms=%d", max_ms));
		nosmp = $test$plusargs("nosmp");
		if ($value$plusargs("stream=%s", f)) fd_stream = $fopen(f, "w");
		void'($value$plusargs("phase=%d", phase));
		rs_load = xs(seed * 32'h9E3779B1 + 32'h0000_1001);
		rs_ep   = xs(seed * 32'h85EBCA6B + 32'h0000_2002);
		rs_smp  = xs(seed * 32'hC2B2AE35 + 32'h0000_3003);
		rs_misc = xs(seed * 32'h27D4EB2F + 32'h0000_4004);
		rs_rl   = xs(seed * 32'h165667B1 + 32'h0000_5005);
		if (phase < 0) phase = r_misc(26190);
		if (img_kb < 64 || img_kb > 512 || img2_kb < 64 || img2_kb > 512) $fatal(1, "imgkb and img2kb: 64 to 512");
		$display("tb_daria_smp: seed %0d phase %0d ps loads %0d image %0d KB then %0d KB, %0d reloads, gap %0d%s",
			seed, phase, n_loads, img_kb, img2_kb, nosmp ? 0 : n_reloads, smp_gap, nosmp ? " (no samples)" : "");
		#(phase);
		forever #13095 clk_arm = ~clk_arm;
	end

	// ---- the image ------------------------------------------------------------------------
	int epoch = 0;                                    // 0 the first image, 1 the second: counts
	                                                  // img_ready's falls (clk_arm)
	int img_bytes = 0;
	function automatic logic [7:0] pat(input int b, input int e);
		logic [31:0] x;
		x = (32'(b) ^ (e != 0 ? 32'h5A5A_0000 : 32'h0)) * 32'h9E3779B1;
		return x[23:16] ^ x[7:0] ^ 8'(b >> 8) ^ 8'(e * 8'h3C);
	endfunction

	// ---- the wrapper's levels: hold, profile, mapper reset (clk_sys, two clk_arm flops) ----
	logic       hold_sys = 1'b1, prof_sys = 1'b1, mres_sys = 1'b0;
	logic [1:0] hold_a = 2'b11, prof_a = 2'b00, mres_a = 2'b11;
	always @(posedge clk_arm) begin
		hold_a <= {hold_a[0], hold_sys};
		prof_a <= {prof_a[0], prof_sys};
		mres_a <= {mres_a[0], mres_sys};
	end
	wire        img_ready;
	wire [19:0] img_size;
	wire        sweep_done;
	wire        pre_run = ~hold_a[1] & ~mres_a[1] & img_ready;
	logic       run = 1'b0;
	always @(posedge clk_arm) run <= pre_run & sweep_done;
	wire        readable = prof_a[1] & img_ready & ~hold_a[1];

	// ---- bup_asset_wr, psram.sv, psram_model ---------------------------------------------
	logic  [2:0] msg_type = 3'd0;
	logic [43:0] msg_pl = 44'd0;
	logic        msg_tog = 1'b0;
	wire         w_rd_req, w_rd_ack, overrun;
	wire  [21:0] w_rd_addr;
	wire         p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire  [21:0] p_addr;
	wire  [15:0] p_din, p_dout;

	bup_asset_wr wr (
		.clk(clk_arm), .msg_type, .msg_pl, .msg_tog,
		.asset_ready(), .asset_size(), .fw_loaded(), .img_ready, .img_size,
		.rom_we(), .rom_wa(), .rom_wd(), .win_we(), .win_wa(), .win_wd(), .win_be(),
		.rd_req(w_rd_req), .rd_addr(w_rd_addr), .rd_ack(w_rd_ack),
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_busy(p_busy), .overrun, .fw_start());

	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(50.0)) ps (
		.clk(clk_arm), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model chip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);

	// ---- the cache and the requester, as bupchip_pocket.sv wires them ----------------------
	logic [31:0] d_addr = 32'd0, w_addr = 32'd0;
	logic        w_asset = 1'b0;
	logic  [1:0] w_size = 2'd0;
	wire  [31:0] asset_q;
	wire         w_wait, st_miss, st_pf, st_preempt, st_late, st_stall;
	wire         c_rd_req, c_rd_ack;
	wire  [21:0] c_rd_addr;
	bup_asset_cache #(.PREEMPT(1'b1), .PREFETCH(1'b1), .WAYS(2)) cache (
		.clk(clk_arm), .pre_run, .run, .sweep_done,
		.d_addr, .w_asset, .w_addr, .w_size, .asset_q, .w_wait,
		.rd_req(c_rd_req), .rd_addr(c_rd_addr), .rd_ack(c_rd_ack), .rd_avail(p_avail), .rd_data(p_dout),
		.st_miss, .st_pf, .st_preempt, .st_late, .st_stall);

	logic        req_q = 1'b0;                   // the front end's request toggle
	logic [18:0] saddr_q = 19'd0;                // and its address
	wire         smp_ack;
	wire   [7:0] smp_data;
	daria_smp dut (
		.clk(clk_arm),
		.smp_req(req_q), .smp_addr(saddr_q), .smp_ack, .smp_data, .readable,
		.c_rd_req, .c_rd_addr, .c_rd_ack,
		.rd_req(w_rd_req), .rd_addr(w_rd_addr), .rd_ack(w_rd_ack), .rd_avail(p_avail), .rd_data(p_dout));

	// ---- counters ---------------------------------------------------------------------------
	longint e_data = 0, e_check = 0, e_load = 0, e_spur = 0, e_lost = 0, e_proto = 0;
	longint e_bothfl = 0, e_ownack = 0, e_ffslow = 0, e_stuck = 0;
	longint n_go = 0, n_ans = 0, n_ack_seen = 0, n_ackflip = 0, n_byte = 0, n_ff = 0, n_ff_hold = 0, n_ff_load = 0;
	longint n_ff_souper = 0, n_race = 0, n_check = 0, n_chk_drop = 0, n_loads_done = 0;
	longint c_coinc = 0, c_wait_fl = 0, c_take_rx = 0, c_held_rd = 0, c_mres_rd = 0, c_odd = 0;
	longint t_byte_max = 0, t_ff_max = 0, t_byte_sum = 0;
	longint c_miss = 0, c_pf = 0, c_pre = 0;
	longint e_sync = 0, e_img = 0, n_img_hw = 0, n_beyond = 0, n_race_old = 0, n_race_new = 0;
	longint c_rl_pend = 0, c_rl_fl = 0, n_rl = 0, n_rl_to = 0, n_rl_loads = 0, n_abandon = 0;
	longint n_rl_mode [5] = '{0, 0, 0, 0, 0};
	int     sync_min = 1 << 30;

	// ---- the image loads (clk_sys) ---------------------------------------------------------
	localparam logic [2:0] M_START = 3'd1, M_WRITE = 3'd2, M_END = 3'd3;
	task automatic send(input logic [2:0] t, input logic [43:0] pl);
		@(posedge clk_sys);
		msg_type <= t;
		msg_pl <= pl;
		msg_tog <= ~msg_tog;
		repeat (3) @(posedge clk_sys);
	endtask
	// The writes and END of an image; load_image sends its START first.
	task automatic load_body(input int kb, input int e);
		int n;
		n = kb * 1024;
		for (int h = 0; h < n / 2; h++)
			send(M_WRITE, {3'd0, 1'b1, 2'b11, 22'(h), pat(2 * h + 1, e), pat(2 * h, e)});
		send(M_END, {19'd0, 1'b1, 24'(n)});
	endtask
	task automatic load_image(input int kb, input int e);
		send(M_START, 44'd0);
		load_body(kb, e);
	endtask
	// Every halfword of the image just loaded, in psram_model.
	task automatic check_image(input int kb, input int e);
		int bad;
		bad = 0;
		for (int h = 0; h < kb * 512; h++) begin
			logic [15:0] w, x;
			w = chip.bd_read(0, h);
			x = {pat(2 * h + 1, e), pat(2 * h, e)};
			if (chip.bd_written(0, h) != 2'b11 || w !== x) begin
				if (bad < 3) $display("%0t: image %0d (%0d KB): halfword %05x is %04x (written %b), expected %04x",
					$time, e, kb, h, w, chip.bd_written(0, h), x);
				bad++;
			end
		end
		n_img_hw += kb * 512;
		e_img += bad;
	endtask

	// ---- episodes (requested by the CPU driver, applied on clk_sys) ----------------------------
	localparam int EP_HOLD = 0, EP_MRES = 1, EP_SOUPER = 2;
	int ep_kind = 0, ep_len = 0, ep_req_n = 0, ep_done_n = 0, ep_left = 0;
	bit ep_act = 0;
	longint n_ep [3] = '{0, 0, 0};
	always @(posedge clk_sys) begin
		if (!ep_act && ep_done_n != ep_req_n) begin
			ep_act = 1;
			ep_left = ep_len;
			n_ep[ep_kind]++;
			case (ep_kind)
				EP_HOLD: hold_sys <= 1'b1;
				EP_MRES: mres_sys <= 1'b1;
				default: prof_sys <= 1'b0;
			endcase
		end else if (ep_act) begin
			ep_left--;
			if (ep_left == 0) begin
				hold_sys <= 1'b0;
				mres_sys <= 1'b0;
				prof_sys <= 1'b1;
				ep_act = 0;
				ep_done_n++;
			end
		end
	end

	// ---- the front end's sample client (clk_sys), as daria_fe_audio.sv ------------------------
	logic        busy_r = 1'b0, ack_s1 = 1'b0, ack_s2 = 1'b0, ack_s2q = 1'b0;
	logic  [7:0] rdat = 8'h00;
	wire         ack_hit = busy_r && (ack_s2 == req_q);
	bit          smp_on = 0;
	bit          force_post = 0;                   // stage 5: post on the next clk_sys edge
	int          smp_wait = 0, open_clk = 0;
	int          arm_since = 0;                    // clk_arm edges since the open request's toggle
	longint      t_go = 0;
	int          recent [8] = '{0, 0, 0, 0, 0, 0, 0, 0};
	// What the requester owes the open request, from its first start (clk_arm).
	bit          seen_start = 0, exp_ff = 0, cls_hold = 0, cls_load = 0, cls_souper = 0, cls_race = 0;
	bit          cls_beyond = 0;
	int          exp_epoch = 0;
	logic  [7:0] exp_byte = 8'h00;                 // the byte owed, if readable at the first start
	typedef struct { int off; logic [7:0] v; int e; } chk_t;
	chk_t        chkq [$];

	function automatic logic [18:0] smp_pick();
		int r, o;
		r = r_smp(100);
		if (r < 70) o = 32768 + r_smp(img_bytes - 32768);
		else if (r < 85) o = r_smp(img_bytes);
		else begin
			o = recent[r_smp(8)] + r_smp(64) - 32;
			if (o < 0) o = 0;
			if (o >= img_bytes) o = img_bytes - 1;
		end
		return 19'(o);
	endfunction

	always @(posedge clk_sys) begin
		if (ack_s2 != ack_s2q) begin
			n_ack_seen++;
			if (!busy_r) begin
				if (e_spur < 10) $display("%0t: an answer toggle with no request open", $time);
				e_spur++;
			end
		end
		ack_s2q <= ack_s2;
		ack_s1 <= smp_ack;
		ack_s2 <= ack_s1;
		if (ack_hit) begin
			longint t;
			logic [7:0] want, alt;
			t = $time - t_go;
			rdat <= smp_data;
			busy_r <= 1'b0;
			n_ans++;
			smp_wait = r_smp(10) < 3 ? 0 : r_smp(smp_gap + 1);
			want = exp_ff ? 8'hFF : exp_byte;
			alt = pat(int'(saddr_q), epoch);           // a raced answer may be the new image's byte
			if (!seen_start) begin
				if (e_data < 10) $display("%0t: an answer before daria_smp started the request", $time);
				e_data++;
			end else if (cls_race) begin
				n_race++;                          // readable at the start, a START before the halfword
				if (smp_data === want) n_race_old++;
				else if (smp_data === alt) n_race_new++;
				else begin
					if (e_data < 10) $display("%0t: request at %05x raced by a load answered %02x, expected %02x or the new image's %02x",
						$time, saddr_q, smp_data, want, alt);
					e_data++;
				end
			end else if (smp_data !== want) begin
				if (e_data < 10) $display("%0t: request at %05x answered %02x, expected %02x (%0s)", $time,
					saddr_q, smp_data, want, exp_ff ? "not readable" : "the image byte");
				e_data++;
			end
			if (exp_ff) begin
				n_ff++;
				if (cls_hold) n_ff_hold++;
				else if (cls_load) n_ff_load++;
				else if (cls_souper) n_ff_souper++;
				if (t > t_ff_max) t_ff_max = t;
				if (t > 450000) begin
					if (e_ffslow < 10) $display("%0t: $FF answer after %0d ps", $time, t);
					e_ffslow++;
				end
			end else if (!cls_race) begin
				n_byte++;
				if (cls_beyond) n_beyond++;
				if (saddr_q[0]) c_odd++;
				t_byte_sum += t;
				if (t > t_byte_max) t_byte_max = t;
				chkq.push_back('{int'(saddr_q), smp_data, exp_epoch});
			end
		end else if (busy_r) begin
			open_clk++;
			if (open_clk == 2000) begin
				$display("%0t: request at %05x open for 2,000 clk_sys", $time, saddr_q);
				e_lost++;
				busy_r <= 1'b0;                    // give up on it, so that the run ends
			end
		end else if (smp_on && img_bytes > 32768) begin
			if (smp_wait > 0 && !force_post) smp_wait--;
			else begin
				req_q <= ~req_q;
				saddr_q <= smp_pick();
				busy_r <= 1'b1;
				open_clk = 0;
				t_go = $time;
				arm_since = 0;
				seen_start = 0;
				n_go++;
				force_post = 0;
			end
		end
	end

	// ---- the requester's side, every clk_arm ----------------------------------------------------
	logic       ack_m = 1'b0;
	logic [7:0] data_m = 8'hFF;
	logic       ir_q = 1'b0;
	int         rl_trig = 0, rl_wait = 0;      // stage 5's trigger, armed by the sequence
	bit         rl_hit = 0;
	always @(posedge clk_arm) begin
		if (ir_q && !img_ready) begin              // a new image's START
			epoch++;
			if (dut.pend) c_rl_pend++;
			else if (dut.fl) c_rl_fl++;
		end
		ir_q = img_ready;
		// Edges after the toggle's clk_sys edge (an edge shared with it does
		// not count: the first flop takes the old level there).
		if ($time > t_go) arm_since++;
		// The first start of the open request decides what it is owed.
		if (busy_r && !seen_start && dut.start) begin
			seen_start = 1;
			if (arm_since < sync_min) sync_min = arm_since;
			if (arm_since < 3) begin
				if (e_sync < 10) $display("%0t: request at %05x started %0d clk_arm edges after its toggle", $time,
					saddr_q, arm_since);
				e_sync++;
			end
			exp_ff = !readable;
			exp_epoch = epoch;
			exp_byte = pat(int'(saddr_q), epoch);
			cls_beyond = 0;
			if (readable && 20'(saddr_q) >= img_size) begin
				// Past the readable image: the byte the PSRAM holds there now.
				logic [15:0] w;
				logic  [1:0] m;
				w = chip.bd_read(0, int'(saddr_q) >> 1);
				m = chip.bd_written(0, int'(saddr_q) >> 1);
				exp_byte = saddr_q[0] ? w[15:8] : w[7:0];
				cls_beyond = 1;
				if (!m[saddr_q[0]]) begin
					if (e_data < 10) $display("%0t: request at %05x, past the image, for a byte never written", $time, saddr_q);
					e_data++;
				end
			end
			cls_hold = hold_a[1];
			cls_load = !hold_a[1] && !img_ready;
			cls_souper = !hold_a[1] && img_ready && !prof_a[1];
			cls_race = 0;
		end
		// Readable at the start, but a new image started before the read: the
		// PSRAM may hold either image's byte (the front end is reset by the load).
		if (busy_r && seen_start && !exp_ff && (dut.pend || dut.fl) && !img_ready) cls_race = 1;
		// Stage 5's trigger.
		if (rl_trig != 0 && !rl_hit) begin
			rl_wait++;
			case (rl_trig)
				2: rl_hit = busy_r && dut.start && readable;
				3: rl_hit = dut.pend && cache.f_fl;
				4: rl_hit = dut.take;
				default: ;
			endcase
			if (!rl_hit && rl_wait >= 50000) begin
				rl_hit = 1;
				n_rl_to++;
			end
		end
		// The held-bus contract, from the values each edge leaves: the byte may
		// change only while an answer is owed (fewer toggles than requests),
		// and never on the edge the toggle flips.
		if (smp_ack !== ack_m) begin
			n_ackflip++;
			if (smp_data !== data_m) begin
				if (e_proto < 10) $display("%0t: smp_data changed on the edge smp_ack flipped", $time);
				e_proto++;
			end
		end else if (smp_data !== data_m && n_ackflip >= n_go) begin
			if (e_proto < 10) $display("%0t: smp_data changed with no answer owed", $time);
			e_proto++;
		end
		ack_m = smp_ack;
		data_m = smp_data;
		// One read in flight, and the port's owner.
		if (cache.f_fl && dut.fl) begin
			if (e_bothfl < 10) $display("%0t: the cache's read and the sampler's in flight together", $time);
			e_bothfl++;
		end
		if (c_rd_ack && (dut.pend || dut.fl)) begin
			if (e_ownack < 10) $display("%0t: the cache took rd_ack while the sampler owns the port", $time);
			e_ownack++;
		end
		// Coverage.
		if (dut.pend && c_rd_req) c_coinc++;
		if (dut.pend && cache.f_fl) c_wait_fl++;
		if (dut.take && cache.rx) c_take_rx++;
		if (dut.take && !run) c_held_rd++;
		if (dut.take && mres_a[1]) c_mres_rd++;
		if (st_miss) c_miss++;
		if (st_pf) c_pf++;
		if (st_preempt) c_pre++;
	end

	// ---- the CPU's asset port, as bup_cpu S1 drives it (tb_cache's driver) -----------------------
	typedef struct { int off; logic [1:0] sz; bit chk; logic [7:0] want; int e; } ld_t;
	ld_t    cur;
	int     st = 0, gap = 0, wait_clk = 0;
	int     main_i = 0, main_n = 0, next_ep = 0;
	bit     main_on = 0, ep_wait = 0, chk_pause = 0;
	bit     rl_on = 0;                             // stage 5
	int     vptr [16], vstep [16];
	ld_t    lq [$];

	task automatic gen_load();
		int r, v, b, o;
		r = r_load(100);
		if (r < 45) begin                          // voices: byte streams, CoreTone's mixer
			v = r_load(16);
			vptr[v] = (vptr[v] + vstep[v]) % img_bytes;
			lq.push_back('{vptr[v], 2'd0, 1'b0, 8'd0, epoch});
		end else if (r < 55) begin                 // a cold line: bytes 0-3, then two words
			b = r_load(img_bytes / 16) * 16;
			for (int k = 0; k < 4; k++) lq.push_back('{b + k, 2'd0, 1'b0, 8'd0, epoch});
			lq.push_back('{b + 4, 2'd2, 1'b0, 8'd0, epoch});
			lq.push_back('{b + 8, 2'd2, 1'b0, 8'd0, epoch});
		end else if (r < 67) begin                 // another tag in a recent line's set (2 KB a way)
			o = (recent[r_load(8)] & 2032) | (r_load(img_bytes / 2048) * 2048) | r_load(16);
			lq.push_back('{o % img_bytes, 2'(r_load(3)), 1'b0, 8'd0, epoch});
		end else begin                             // anything: byte, halfword, word
			o = r_load(img_bytes);
			lq.push_back('{o, 2'(r_load(3)), 1'b0, 8'd0, epoch});
		end
	endtask

	function automatic logic [31:0] other_addr();
		return r_misc(2) != 0 ? 32'h4000_0000 | 32'(r_misc(1 << 14)) : 32'(r_misc(img_bytes));
	endfunction

	// Take the next load, if any: a check load first (an answered byte, read
	// back through the cache), then the main stream's.
	task automatic next_load();
		if (chkq.size() != 0 && !chk_pause) begin
			chk_t c;
			c = chkq.pop_front();
			if (c.e != epoch) begin
				n_chk_drop++;                      // an answer from the last image: dropped
				st = 0;
				return;
			end
			cur = '{c.off, 2'd0, 1'b1, c.v, c.e};
		end else if (main_i < main_n) begin
			if (main_i == next_ep) begin
				int k;
				k = r_ep(3);
				ep_kind = k;
				ep_len = k == EP_SOUPER ? 50 + r_ep(400) : 20 + r_ep(300);
				ep_req_n++;
				next_ep = main_i + 300 + r_ep(1500);
				if (k != EP_SOUPER) begin
					ep_wait = 1;
					st = 0;
					return;
				end
			end
			if (lq.size() == 0) gen_load();
			cur = lq.pop_front();
			main_i++;
		end else begin
			st = 0;
			return;
		end
		d_addr <= 32'(cur.off);
		st = 1;
	endtask

	always @(posedge clk_arm) begin
		if (!main_on) begin
			w_asset <= 1'b0;
			d_addr <= other_addr();
			st = 0;
		end else if (ep_wait) begin
			w_asset <= 1'b0;
			d_addr <= other_addr();
			if (ep_done_n == ep_req_n && !ep_act && run) begin
				ep_wait = 0;
				gap = 2;
			end
		end else if (!run) begin
			if (st == 2 && rl_on) n_abandon++;      // a reload's START: dropped
			else if (st == 2) begin
				$display("%0t: the cache was held during a load", $time);
				e_stuck++;
			end
			if (st != 0 && rl_on && cur.chk) n_chk_drop++;
			w_asset <= 1'b0;
			d_addr <= other_addr();
			st = 0;
		end else case (st)
			0: begin
				w_asset <= 1'b0;
				if (gap > 0) begin
					gap--;
					d_addr <= other_addr();
				end else begin
					d_addr <= other_addr();
					next_load();
				end
			end
			1: begin                               // execute ends: W next
				w_asset <= 1'b1;
				w_addr <= 32'(cur.off);
				w_size <= cur.sz;
				d_addr <= 32'(cur.off);
				wait_clk = 0;
				st = 2;
			end
			2: if (w_wait) begin
				wait_clk++;
				if (wait_clk == 400) begin
					$display("%0t: load at %05x waits 400 clocks", $time, cur.off);
					e_stuck++;
				end
			end else begin
				int a;
				logic [31:0] e;
				logic  [3:0] m;
				a = cur.off & ~3;
				for (int k = 0; k < 4; k++) e[8 * k +: 8] = pat(a + k, cur.e);
				m = cur.sz == 2'd2 ? 4'b1111 : cur.sz == 2'd1 ? (cur.off[1] ? 4'b1100 : 4'b0011)
					: 4'b0001 << cur.off[1:0];
				if (cur.chk) begin
					n_check++;
					if (asset_q[8 * cur.off[1:0] +: 8] !== cur.want) begin
						if (e_check < 10) $display("%0t: answer %02x at %05x, the cache reads %02x", $time,
							cur.want, cur.off, asset_q[8 * cur.off[1:0] +: 8]);
						e_check++;
					end
				end else begin
					logic [31:0] got;
					if (rl_on) n_rl_loads++;
					else n_loads_done++;
					for (int k = 0; k < 4; k++) got[8 * k +: 8] = m[k] ? asset_q[8 * k +: 8] : 8'h00;
					for (int k = 0; k < 4; k++)
						if (m[k] && asset_q[8 * k +: 8] !== e[8 * k +: 8]) begin
							if (e_load < 10) $display("%0t: load at %05x size %0d: %08x, expected %08x (lanes %b)",
								$time, cur.off, cur.sz, asset_q, e, m);
							e_load++;
							break;
						end
					if (fd_stream != 0 && !rl_on) $fdisplay(fd_stream, "%0d %0d %0d %08x", n_loads_done, cur.off, cur.sz, got);
					recent[(n_loads_done + n_rl_loads) % 8] = cur.off;
				end
				w_asset <= 1'b0;
				gap = cur.chk ? r_misc(4) : (r_load(10) < 4 ? 0 : r_load(10) < 8 ? r_load(4) : r_load(41));
				if (gap == 0) next_load();
				else begin
					gap--;
					d_addr <= other_addr();
					st = 0;
				end
			end
			default: ;
		endcase
	end

	// ---- the sequence -------------------------------------------------------------------------
	initial begin
		#1;
		repeat (max_ms) #1_000_000_000;
		$fatal(1, "tb_daria_smp: %0d ms of simulated time, stopped (result: FAIL watchdog)", max_ms);
	end
	initial begin
		bit fail;
		for (int v = 0; v < 16; v++) begin
			vptr[v] = 0;
			vstep[v] = 0;
		end
		@(posedge clk_sys);
		for (int v = 0; v < 16; v++) begin
			vptr[v] = 32768 + r_load(img_kb * 1024 - 32768);
			vstep[v] = 1 + r_load(7);
		end
		img_bytes = img_kb * 1024;
		smp_on = !nosmp;
		repeat (300) @(posedge clk_sys);           // power-up: held
		hold_sys <= 1'b0;
		repeat (200) @(posedge clk_sys);           // no image yet
		load_image(img_kb, 0);
		wait (img_ready);
		check_image(img_kb, 0);
		next_ep = 200 + r_ep(800);
		main_i = 0;
		main_n = n_loads;
		main_on = 1;
		wait (main_i == main_n && st == 0 && !ep_wait && !ep_act);
		chk_pause = 1;
		repeat (20) @(posedge clk_sys);
		wait (st == 0);
		// The second image, with the requests still coming.
		main_on = 0;
		repeat (4) @(posedge clk_sys);
		load_image(img2_kb, 1);
		wait (img_ready);
		check_image(img2_kb, 1);
		img_bytes = img2_kb * 1024;
		for (int v = 0; v < 16; v++) vptr[v] = vptr[v] % img_bytes;
		lq.delete();
		main_i = 0;
		main_n = n_loads / 4;
		next_ep = 100 + r_ep(400);
		chk_pause = 0;
		main_on = 1;
		wait (main_i == main_n && st == 0 && !ep_wait && !ep_act);
		// 5. Reloads, each START timed on the sampler (with samples only): the
		// CPU's loads and the requests go on throughout, with no episodes.
		if (!nosmp && n_reloads > 0) begin
			rl_on = 1;
			next_ep = -1;
			main_i = 0;
			main_n = 1 << 30;
			for (int k = 0; k < n_reloads; k++) begin
				int kb, mode, w, e;
				mode = k % 5;
				kb = 40 + r_rl(33);
				repeat (200 + r_rl(1200)) @(posedge clk_sys);
				#1;                                // after the edge, so that the choices below see its values
				if (mode <= 1) begin
					// While a cache fill has reads to issue and no request is
					// open: a request posted on the START's clk_sys edge (mode
					// 0) or on the edge before it (mode 1).
					w = 0;
					while ((busy_r || !(cache.f_act && cache.f_rq_n > 4'd2)) && w < 20000) begin
						@(posedge clk_sys);
						#1;
						w++;
					end
					if (w == 20000) n_rl_to++;
					force_post = 1;
					if (mode == 1) begin
						@(posedge clk_sys);
						#1;
					end
				end else begin
					// On the first clk_sys edge after the sampler's start (2),
					// its read waiting behind a cache read (3), its read taken (4).
					rl_wait = 0;
					rl_hit = 0;
					rl_trig = mode;
					wait (rl_hit);
					rl_trig = 0;
					#1;
				end
				n_rl_mode[mode]++;
				e = epoch + 1;
				send(M_START, 44'd0);
				force_post = 0;
				load_body(kb, e);
				wait (img_ready);
				if (epoch != e) $fatal(1, "tb_daria_smp: reload %0d: epoch %0d, expected %0d", k, epoch, e);
				img_bytes = kb * 1024;
				for (int v = 0; v < 16; v++) vptr[v] = vptr[v] % img_bytes;
				lq.delete();
				check_image(kb, e);
				n_rl++;
			end
			main_n = main_i;
			wait (st == 0);
			rl_on = 0;
		end
		// Drain: no new requests; the open one answered; its check load done.
		smp_on = 0;
		wait (!busy_r);
		repeat (10) @(posedge clk_sys);
		wait (chkq.size() == 0 && st == 0);
		repeat (20) @(posedge clk_sys);
		main_on = 0;
		if (fd_stream != 0) $fclose(fd_stream);

		if (n_ack_seen != n_go || n_ans != n_go || n_ackflip != n_go) begin
			$display("requests %0d, answer toggles %0d (seen on clk_sys %0d), answers taken %0d", n_go, n_ackflip,
				n_ack_seen, n_ans);
			e_spur++;
		end
		chip.report();
		$display("cache: demand misses %0d, prefetches %0d, pre-emptions %0d; episodes: hold %0d, mapper reset %0d, Souper %0d",
			c_miss, c_pf, c_pre, n_ep[EP_HOLD], n_ep[EP_MRES], n_ep[EP_SOUPER]);
		$display("requests %0d: image bytes %0d (odd offsets %0d, past the image %0d), $FF %0d (hold %0d, load %0d, Souper %0d), load races %0d (the old byte %0d, the new image's %0d)",
			n_go, n_byte, c_odd, n_beyond, n_ff, n_ff_hold, n_ff_load, n_ff_souper, n_race, n_race_old, n_race_new);
		$display("answer time: image byte max %0d ps, mean %0d ps; $FF max %0d ps",
			t_byte_max, n_byte != 0 ? t_byte_sum / n_byte : 0, t_ff_max);
		$display("coverage: wanted while the cache asks %0d, while a cache read is in flight %0d, taken on a cache read's arrival %0d, reads while the cache is held %0d (mapper reset %0d)",
			c_coinc, c_wait_fl, c_take_rx, c_held_rd, c_mres_rd);
		$display("loads %0d, check loads %0d (dropped with an earlier image %0d)", n_loads_done, n_check, n_chk_drop);
		$display("sync: fewest clk_arm edges from a request's toggle to its start %0d; images checked: %0d halfwords",
			sync_min, n_img_hw);
		$display("reloads %0d (START on a request's post %0d, a clk_sys after it %0d, after the start %0d, the read behind a cache read %0d, the read taken %0d; timeouts %0d): START while the sampler's read is wanted %0d, in flight %0d; loads %0d, dropped by a START %0d",
			n_rl, n_rl_mode[0], n_rl_mode[1], n_rl_mode[2], n_rl_mode[3], n_rl_mode[4], n_rl_to, c_rl_pend, c_rl_fl,
			n_rl_loads, n_abandon);
		fail = e_data != 0 || e_check != 0 || e_load != 0 || e_spur != 0 || e_lost != 0 || e_proto != 0 ||
			e_bothfl != 0 || e_ownack != 0 || e_ffslow != 0 || e_stuck != 0 || e_sync != 0 || e_img != 0 ||
			chip.n_viol != 0 || chip.late_reads != 0 || overrun ||
			n_loads_done != longint'(n_loads + n_loads / 4);
		if (!nosmp)
			fail = fail || n_ff_hold == 0 || n_ff_load == 0 || n_ff_souper == 0 || n_byte < 1000 ||
				c_coinc == 0 || c_wait_fl == 0 || c_take_rx == 0 || c_held_rd == 0 || n_check + n_chk_drop != n_byte;
		if (!nosmp && n_reloads > 0)
			fail = fail || n_rl != n_reloads || c_rl_pend == 0 || c_rl_fl == 0 || n_race == 0;
		$display("result: %0s data %0d check %0d load %0d spur %0d lost %0d proto %0d both_fl %0d own_ack %0d ff_slow %0d stuck %0d sync %0d image %0d psram_viol %0d late %0d overrun %0d byte_max_ps %0d ff_max_ps %0d",
			fail ? "FAIL" : "PASS", e_data, e_check, e_load, e_spur, e_lost, e_proto, e_bothfl, e_ownack,
			e_ffslow, e_stuck, e_sync, e_img, chip.n_viol, chip.late_reads, overrun, t_byte_max, t_ff_max);
		if (fail) $fatal(1, "tb_daria_smp failed");
		$finish;
	end
endmodule
