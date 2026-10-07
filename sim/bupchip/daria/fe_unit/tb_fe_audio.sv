//------------------------------------------------------------------------------
// tb_fe_audio: daria_fe_audio against upstream's arm_mapper_audio (lane B;
// docs/daria_fe/design.md 5, 9.3 and 12.3 "daria_fe_audio" items 1-4;
// docs/daria_fe/lanes/B_audio.md).
//
// Two engines on one stimulus, clk_arm = 5 x clk_sys edge-aligned (mode A):
//
//   upstream  arm_mapper_audio on upstream's cart RAM (cart_ram_tdp: the
//             byte lane register, pause_core's $FF bytes and mapper_en),
//             a model of arm_mapper_memory's sample port (hit at R+3, or a
//             miss), and upstream's call edges (call_launch at L, at M for
//             an RMW's second call; call_done in (X, X+1)).
//   ours      daria_fe_audio on daria_mem (cart RAM port B, state RAM port
//             B, front-end ROM port A; poisoned with POISON=1), the mode-A
//             grant aud_take = aud_issue & !sel_up, a k[0] lookahead on
//             port A, a model of u_call's strobe timing (design 6.1-6.4:
//             cp_cap at L, cp_rot while posting F2-F7, F8 read in (X-1, X),
//             cp_shin X+1..X+6, cp_cmp, mwin (X+1, X+7), cp_apply at X+7,
//             or the hook hk_stb in (X, X+1)), and the wrapper's side of the
//             sample port (answer after a random latency).
//
// Both see the same random image and cart RAM (written into both RAMs), the
// same random select stream (fe_phase_gen's cycles with per-cycle select
// patterns: phase-1 reads, until the commit, the whole cycle, random
// clocks; frozen from the last unpaused edge through a pause, as a frozen
// 6507 cycle's select is, AUD 12.5), the same 6507 byte stores (at C, under
// the select), the same clk_arm writes (non-shared edges, as upstream's port
// B arbitrates), the same NOTE strobes (at C+1, at random clocks, and at
// the grant edges g and g+1 of a NOTE read: AUD 9.4's overlap rows),
// waveforms, cdf_dig toggles, pause, live option changes (also the family
// in the middle of a refresh), resets mid-refresh and mid-sample, and the
// same calls. Both accumulators are sometimes moved together: a tick on a
// dispatch edge (AUD 9.3's re-queue), or the accumulator meeting TH exactly.
//
// Segments (+seg=N runs one): 0 cdf_hook (CDFJ+), 1 dpc_hook (NOTE), 2 live
// (option and family changes; starts on size_over32k), 3 cdf_own_sweep (the
// own merge path, tick at M-2 .. M_fe+3, launch at L-2 .. L+2), 4 sample
// (digital ROM/RAM, latencies to 2,000 clocks, orphans), 5 exact_cdf and
// 6 exact_dpc (no pause, no miss, no class allowed), 7 cdf_own_random,
// 8 cdf_hook_sweep (tick at M-1 .. M+1 under the hook), 9 dig_edges (the
// digital route's boundaries, rom_size above $4000_0000), 10 pause (many
// short pauses: grants on a pause's last clock).
//
// Checks (every clk_sys, at the falling edge):
//   A1  tick, accum, counters, frequencies, rc, st (one-hot against the
//       enum), voice, ssum, wsh, woff, dig_addr/low/ram/smp, rp, np, nv,
//       nval, amplitude, dispatch, aud_issue, aud_addr (when issuing),
//       ev_size_hi; amp_nx against the next amplitude on every clock,
//       resets included; tdef exactly for a tick in [M+1, M_fe] of an
//       own-path merge and never otherwise; a_tdef2 never.
//   ring the payload captured at L (and at M / M_fe for an RMW's second
//       call) equals upstream's launch values; each rotation posts the next
//       word; the ring is back in place after the post; the hook sees the
//       seeds; the own path's six returns and take[].
//   own merge path: counters and frequencies masked only in (M, M_fe+1].
//   sample client: the local read at R+1, or R+2 behind a k[0] lookahead,
//       its address, and AMPLITUDE at R+4 (A1 against upstream's hit); the
//       remote request (one toggle, smp_addr held while outstanding)
//       against upstream's sample_done placed where design 5.7's protocol
//       puts ours (R+6+latency); orphans across cart_reset meeting the next
//       refresh (rom_ready low in RISS on both sides).
//   the two cart RAMs are equal word for word at the end of each segment.
//
// Counted classes (design 9.5), each set only by its own condition, masking
// the replica's registers until both engines are IDLE with nothing pending,
// then resynchronised by a deposit of upstream's values (fe_deposit_audio's
// rule): merge_amp (own path, a dispatch in (M, M_fe+1]), dig_rom_lag (an
// upstream miss on a local sample), pause_lane (a grant edge in a pause
// whose last unpaused edge had the select high: never, with a frozen
// select), size_over32k (upstream reading its RAM above 32 KB) and rmw_call
// (own path, a tick on M under an RMW: the second payload carries that
// tick; checked, then upstream's seeds deposited). The "exact" segments
// allow no class at all. A run passes with no error and every coverage
// minimum met (at +scale >= 100 with all segments).
//
// Plusargs: +seed=N (also give +pg_seed=N), +scale=PCT (segment lengths,
// default 100: 3.4 M clk_sys, about 12 s), +seg=N, +maxerr=N, +verbose=1.
// Mutation test: tb_fe_audio_mut.py. Area probe wrapper: tb_fe_audio_probe.v.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_audio;
	localparam logic [23:0] TH   = 24'd14_298_182;
	localparam logic [23:0] STEP = 24'd20_000;
	localparam logic [23:0] WRAP = 24'h25_D3BA;
	localparam int NSEG = 11;
	localparam logic [31:0] F0W = 32'h0000_0809, F1W = 32'h4000_1FFC;

	// ---- clocks: clk_arm = 5 x clk_sys, every fifth edge shared --------------------
	logic clk_sys = 1'b0, clk_arm = 1'b0;
	always #34.92 clk_sys = ~clk_sys;
	always #6.984 clk_arm = ~clk_arm;

	// ---- knobs -------------------------------------------------------------------------
	int unsigned seed = 1;
	int scale = 100;
	int verbose = 0;
	int maxerr = 10;
	int only_seg = -1;

	// ---- random (xorshift32, the bench's own stream) ----------------------------------
	int unsigned rs = 32'h2545_F491;
	function automatic int unsigned rnd();
		rs = rs ^ (rs << 13);
		rs = rs ^ (rs >> 17);
		rs = rs ^ (rs << 5);
		return rs;
	endfunction
	function automatic bit pm(input int k);  return (rnd() % 1000) < k;    endfunction  // per mille
	function automatic bit pmm(input int k); return (rnd() % 1000000) < k; endfunction  // per million
	function automatic int unsigned rr(input int unsigned lo, input int unsigned hi);
		return lo + rnd() % (hi - lo + 1);
	endfunction

	// ---- edges: in a posedge block the edge being processed is cyc --------------------
	longint cyc = 0;
	always @(posedge clk_sys) cyc <= cyc + 1;

	// ---- results and coverage ----------------------------------------------------------
	int nerr = 0;
	int n_cmp = 0, n_exact_clk = 0, n_masked_clk = 0, n_cnt_masked = 0;
	int n_disp = 0, n_disp_dpc = 0, n_disp_cdf = 0, n_dig_ram = 0, n_dig_none = 0, n_woff_in = 0;
	int n_size_rd = 0, n_grant_wait = 0, n_pause_byte = 0, n_ncap = 0, n_nv3 = 0, n_orph_seen = 0;
	int n_tick_disp = 0, n_tick_eq = 0, n_coalesce = 0, n_accdep = 0, n_hk_tickm = 0, n_fam_mid = 0;
	int n_rom_edge = 0, n_orph_wait = 0, n_huge = 0, n_amp_nx = 0, n_pz_grant = 0;
	logic riss_w = 1'b0;
	int n_merge_amp = 0, n_dig_lag = 0, n_pause_lane = 0, n_size_hi = 0, n_size_ev = 0, n_resync = 0;
	int n_ring_cap = 0, n_ring_rot = 0, n_ring_back = 0, n_hk_seed = 0, n_own_ret = 0;
	int n_tdef = 0, n_late = 0, n_sweep_ok = 0;
	int sweep_cov [0:11][0:3];
	int capoff_cov [0:4];
	logic rst_q = 1'b0;
	bit m_rep = 0;                           // the replica's registers are masked (a class is active)
	string m_why = "";

	// ---- segment configuration (written by the sequencer at falling edges) -------------
	int    seg = -1;
	string seg_name = "";
	logic  seq_rst = 1'b1;
	int    rst_cnt = 0;                       // a reset pulse in progress (clocks left)
	wire   cart_reset = seq_rst | (rst_cnt != 0);
	logic  [1:0] fam = 2'd0, rev = 2'd0;
	logic        ram32 = 1'b0;
	logic [15:0] asz = 16'd0;
	logic [31:0] rom_size = 32'd32768;
	logic        hk_en = 1'b0;
	bit own = 0, sweep = 0, exact = 0, pause_on = 0, look_on = 0;
	int k_call = 0, k_rmw = 0, k_note = 0, k_note_rnd = 0, k_ov = 0, k_wave = 0, k_dig = 0;
	int k_hit = 1000, k_look = 0, k_rst = 0, k_orph = 0, k_cwr = 0, k_arm = 0, k_live = 0, k_lforce = 0;
	int slat_max = 0, k_slat_big = 0, k_slat_huge = 0, p_digptr = 300, k_modf = 0, dig_loc = 30;
	int k_accdep = 0, k_livefam = 0, live_mask = 31;  // live_mask: 1 rev, 2 ram32, 4 asz, 8 rom_size, 16 fam
	bit dig_edges = 0;                          // digital pointers on the route boundaries
	int sel_w [0:4] = '{1000, 0, 0, 0, 0};

	// ---- the 6507 phases, pause and bus ---------------------------------------------------
	logic cbusy = 1'b0;                       // the call model's arm_call_busy (the stall)
	wire        pclk1, pclk0, mapper_phi2, access, rw, pause_pg, load, stall_eff, ibusy, held;
	wire [12:0] a_in;
	wire  [7:0] d_in;
	wire  [5:0] len1, len2;
	fe_phase_gen #(.SEED(1), .MODE("mix")) u_pg (
		.clk_sys(clk_sys), .run(1'b1), .stall(cbusy), .driver_run(1'b1),
		.ext_a(13'd0), .ext_rw(1'b1), .ext_d(8'd0),
		.pclk1(pclk1), .pclk0(pclk0), .mapper_phi2(mapper_phi2), .access(access), .a_in(a_in), .rw(rw),
		.d_in(d_in), .pause(pause_pg), .load(load), .stall_eff(stall_eff), .ibusy(ibusy), .held(held),
		.len1(len1), .len2(len2));
	logic pause = 1'b0;                       // pause_core, as the engines see it
	always @(posedge clk_sys) pause <= pause_pg & pause_on;
	wire pause_g = pause_pg & pause_on;       // the generator's: the select freezes one clock earlier
	wire wcommit = access & a_in[12] & !rw;  // a cartridge write commits at this edge (C)

	// ---- the select stream (upstream's sel_ram_sel = our sel_up) ----------------------------
	localparam int P_NONE = 0, P_K13 = 1, P_TOC = 2, P_ALL = 3, P_RND = 4;
	logic  [5:0] kk = 6'd63;                  // clocks since E0, frozen in a pause
	logic        past_c = 1'b0;               // this cycle committed
	int          pat = P_NONE;
	logic        rsel = 1'b0;
	logic [14:0] core_a = 15'd0;              // the cycle's cart RAM byte address
	logic  [7:0] core_d = 8'd0;
	logic        cwr_cyc = 1'b0;              // the cycle stores its byte at C
	logic        k0 = 1'b0;                   // u_seq's k[0]: (E0, E0+1)
	logic        look_cyc = 1'b0;
	logic [12:0] look_a = 13'd0;
	logic        sel;
	always_comb begin
		case (pat)
			P_K13:   sel = (kk >= 6'd1) && (kk <= 6'd3);
			P_TOC:   sel = !past_c;
			P_ALL:   sel = 1'b1;
			P_RND:   sel = rsel;
			default: sel = 1'b0;
		endcase
	end
	wire cwr = sel & wcommit & cwr_cyc & !pause;   // a 6507 byte store into cart RAM at C

	function automatic int pick_pat();
		int t, r;
		t = sel_w[0] + sel_w[1] + sel_w[2] + sel_w[3] + sel_w[4];
		r = int'(rnd() % t);
		for (int i = 0; i < 5; i++) begin
			if (r < sel_w[i]) return i;
			r -= sel_w[i];
		end
		return P_NONE;
	endfunction

	// the cart RAM byte addresses the engine reads (pointer, size and table words, waveforms)
	function automatic logic [14:0] hot_addr();
		int r;
		r = int'(rnd() % 100);
		if (r < 20) begin
			int b;
			b = int'(rnd() % 3);
			return 15'((b == 0 ? 32'h7F0 : b == 1 ? 32'h1B0 : 32'h7F4) + 4 * (rnd() % 3) + rnd() % 4);
		end
		if (r < 35) return 15'(asz + 4 * (rnd() % 3) + rnd() % 4);
		if (r < 50) return 15'(32'h1C00 + rnd() % 1024);
		if (r < 65) return 15'(32'h0C00 + rnd() % 4096);
		if (r < 80) return 15'(32'h0800 + rnd() % 4096);
		return 15'(rnd());
	endfunction

	always @(posedge clk_sys) begin
		if (!pause_g) rsel <= pm(300);
		k0   <= pclk1;
		look_f  <= (k_lforce != 0) && u_aud.st[daria_fe_pkg::AS_RISS] && !u_aud.busy_l && !u_aud.busy_r
		           && (u_aud.dig_addr[31:15] == 17'd0) && pm(k_lforce);
		look_fq <= look_f;
		if (pclk1) begin
			kk       <= 6'd0;
			past_c   <= 1'b0;
			pat      <= pick_pat();
			core_a   <= pm(500) ? hot_addr() : 15'(rnd());
			core_d   <= 8'(rnd());
			cwr_cyc  <= pm(k_cwr);
			look_cyc <= look_on & pm(k_look);
			look_a   <= 13'(rnd());
		end else if (!pause_g) begin
			if (kk != 6'd63) kk <= kk + 6'd1;
			if (access) past_c <= 1'b1;
		end
	end

	// ---- NOTE strobes, waveforms, cdf_dig ------------------------------------------------
	logic       note_r = 1'b0;
	logic [1:0] nv_r = 2'd0;
	logic [7:0] nval_r = 8'h00;
	logic       ov_bit = 1'b0;                // s = g overlap (combinational strobe)
	logic [1:0] ov_v = 2'd0;
	logic [7:0] ov_val = 8'h00;
	logic [6:0] wave0 = 7'd0, wave1 = 7'd0, wave2 = 7'd0;
	logic       cdf_dig = 1'b0;
	wire        up_niss_g;                    // upstream's NOTE read is granted in this clock
	wire        note_ov = ov_bit & up_niss_g;
	wire        note_stb = note_r | note_ov;
	wire  [1:0] note_v   = note_ov ? ov_v : nv_r;
	wire  [7:0] note_val = note_ov ? ov_val : nval_r;
	function automatic logic [1:0] pick_nv();
		return pm(50) ? 2'd3 : 2'(rnd() % 3);
	endfunction
	int n_note_ov_g = 0, n_note_ov_g1 = 0, n_note_rnd = 0;
	always @(posedge clk_sys) begin
		note_r <= 1'b0;
		ov_bit <= (k_ov != 0) && pm(k_ov);
		ov_v   <= pick_nv();
		ov_val <= 8'(rnd());
		if (note_ov) n_note_ov_g++;
		if (wcommit && k_note != 0 && pm(k_note)) begin
			note_r <= 1'b1; nv_r <= pick_nv(); nval_r <= 8'(rnd());
		end else if (k_note_rnd != 0 && pmm(k_note_rnd)) begin
			note_r <= 1'b1; nv_r <= pick_nv(); nval_r <= 8'(rnd()); n_note_rnd++;
		end else if (up_niss_g && k_ov != 0 && pm(k_ov)) begin           // s = g+1
			note_r <= 1'b1; nv_r <= pick_nv(); nval_r <= 8'(rnd()); n_note_ov_g1++;
		end
		if ((wcommit && k_wave != 0 && pm(k_wave)) || pmm(200)) begin
			int w;
			w = int'(rnd() % 3);
			case (w)
				0: wave0 <= 7'(rnd());
				1: wave1 <= 7'(rnd());
				default: wave2 <= 7'(rnd());
			endcase
		end
		if ((wcommit && k_dig != 0 && pm(k_dig)) || (k_dig != 0 && pmm(100))) cdf_dig <= ~cdf_dig;
	end

	// ---- random resets mid-segment (a refresh, a call, a sample in flight) ------------------
	int n_rst = 0, n_orph = 0;
	bit orph_req = 0, plant_rom = 0;
	bit hold_ptr = 0;                        // the ARM leaves the pointer words alone until the next route
	always @(posedge clk_sys) begin
		if (rst_cnt != 0) rst_cnt <= rst_cnt - 1;
		else if (!seq_rst && k_rst != 0 && pmm(k_rst)) begin rst_cnt <= int'(rr(1, 20)); n_rst++; end
		else if (!seq_rst && orph_req && pm(200)) begin
			rst_cnt <= int'(rr(1, 4)); orph_req = 0; n_orph++; plant_rom = 1;
		end
		else if (!seq_rst && k_orph != 0 && u_aud.st[daria_fe_pkg::AS_RWAIT] && pm(k_orph)) begin
			rst_cnt <= int'(rr(1, 4)); n_orph++;
		end
	end

	// ---- live option changes ---------------------------------------------------------------
	int n_live = 0;
	logic cm_idle;
	function automatic logic [1:0] pick_fam();
		return (rnd() % 3 == 0) ? 2'd0 : (rnd() % 2 == 0) ? 2'd1 : 2'd3;
	endfunction
	always @(posedge clk_sys) begin
		if (!seq_rst && k_live != 0 && pmm(k_live)) begin
			int w;
			w = int'(rnd() % 5);
			if (live_mask[w]) begin
				n_live++;
				case (w)
					0: rev <= 2'(rnd());
					1: ram32 <= ~ram32;
					2: asz <= pm(250) ? 16'd0 : pm(350) ? 16'(rr(32'h7FF5, 32'h80FF)) : 16'(rnd() % 32'h7FF0);
					3: begin
						int r;
						r = int'(rnd() % 3);
						rom_size <= (r == 0) ? rr(1024, 32768) : (r == 1) ? rr(32768, 524288)
						          : (dig_edges ? 32'h4000_0000 + rr(0, 32'h9000) : rr(32768, 524288));
						if (r == 2 && dig_edges) n_huge++;
					end
					default: if (cm_idle && !m_rep) fam <= pick_fam();
				endcase
			end
		end else if (!seq_rst && k_livefam != 0 && cm_idle && !m_rep && int'(u_up.state) != daria_fe_pkg::AS_IDLE
		             && pm(k_livefam)) begin
			fam <= pick_fam();                     // the family changes in the middle of a refresh
			n_fam_mid++;
		end
	end

	// ---- the image (ROM) ----------------------------------------------------------------------
	logic [7:0] img [0:524287];

	// ---- upstream ------------------------------------------------------------------------------
	wire        up_ram_en;
	wire [16:0] up_ram_addr;
	wire        up_grant = up_ram_en & !sel;
	wire  [7:0] up_rdata;
	wire [31:0] up_word;
	wire        up_rom_req;
	wire [24:0] up_rom_addr;
	wire  [7:0] up_amp;
	wire [31:0] up_c0, up_c1, up_c2, up_f0, up_f1, up_f2;
	logic       up_launch = 1'b0, up_done = 1'b0;
	logic [31:0] up_ret [0:5] = '{32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0};
	logic       up_sbusy = 1'b0, up_sdone = 1'b0;
	logic [7:0] up_sdata = 8'h00;
	arm_mapper_audio u_up (
		.clk(clk_sys), .reset(cart_reset), .family(fam), .revision(rev), .rom_size(rom_size),
		.mapper_ram_size(ram32 ? 16'h8000 : 16'h2000), .audio_size_addr(asz),
		.bus_digital_audio(1'b0), .cdf_digital_audio(cdf_dig),
		.dpc_waveform0(wave0), .dpc_waveform1(wave1), .dpc_waveform2(wave2),
		.dpc_note_write(note_stb), .dpc_note_voice(note_v), .dpc_note_value(note_val),
		.call_launch(up_launch), .call_done(up_done),
		.counter0_return(up_ret[0]), .counter1_return(up_ret[1]), .counter2_return(up_ret[2]),
		.frequency0_return(up_ret[3]), .frequency1_return(up_ret[4]), .frequency2_return(up_ret[5]),
		.counter0(up_c0), .counter1(up_c1), .counter2(up_c2),
		.frequency0(up_f0), .frequency1(up_f1), .frequency2(up_f2),
		.ram_en(up_ram_en), .ram_addr(up_ram_addr), .ram_grant(up_grant),
		.ram_byte_data(pause ? 8'hFF : up_rdata), .ram_word_data(up_word),
		.rom_request(up_rom_req), .rom_addr(up_rom_addr), .rom_ready(!up_sbusy), .rom_done(up_sdone),
		.rom_data(up_sdata), .amplitude(up_amp));
	assign up_niss_g = (fam == 2'd1) && (int'(u_up.state) == daria_fe_pkg::AS_NISS) && up_grant;

	// the clk_arm writer (the ARM): one cart RAM word at a time, through upstream's port B
	// arbitration (never the shared edge); ours takes it on the same clk_arm edge.
	logic        arm_en = 1'b0;
	logic [14:0] arm_wa = 15'd0;
	logic [31:0] arm_wd = 32'd0;
	logic  [3:0] arm_be = 4'd0;
	wire         arm_acc;
	cart_ram_tdp u_upram (
		.clk_sys(clk_sys), .mapper_en(!pause), .mapper_write(cwr),
		.mapper_addr(sel ? {2'b00, core_a} : up_ram_addr), .mapper_wdata(core_d), .mapper_rdata(up_rdata),
		.clk_arm(clk_arm), .arm_en(arm_en), .arm_write(1'b1), .arm_addr(arm_wa), .arm_wdata(arm_wd),
		.arm_wstrb(arm_be), .arm_rdata(), .arm_accepted(arm_acc), .mapper_word_rdata(up_word));

	// ---- ours ----------------------------------------------------------------------------------
	wire        aud_issue, aud_a_req, smp_req;
	wire [14:0] aud_addr;
	wire [12:0] aud_a_a;
	wire [18:0] smp_addr;
	wire  [7:0] amp_nx;
	wire [31:0] ring0, crb_q, stb_q, fea_q;
	logic       smp_ack = 1'b0;
	logic [7:0] smp_data = 8'h00;
	wire        cp_cap, cp_rot, cp_shin, cp_cmp, cp_apply, mwin, hk_stb;
	wire [191:0] hk_ret = {up_ret[5], up_ret[4], up_ret[3], up_ret[2], up_ret[1], up_ret[0]};
	wire        aud_take = aud_issue & !sel;                 // design 3.1 in mode A
	logic       look_f = 1'b0, look_fq = 1'b0;           // a lookahead placed on (R, R+1): R = E0
	wire        look_req = (k0 & look_cyc & !look_fq) | look_f;   // u_core's k[0] lookahead (A priority 1)
	wire        aud_a_gnt = aud_a_req & !look_req;           // A priority 2
	wire [12:0] fea_addr = look_req ? look_a : aud_a_gnt ? aud_a_a : 13'd0;
	wire [12:0] crb_addr = aud_take ? aud_addr[14:2] : sel ? core_a[14:2] : 13'd0;
	wire        stb_we;
	wire  [7:0] stb_addr;
	wire [31:0] stb_wd;
	logic       sta_we = 1'b0;
	logic [7:0] sta_a = 8'd0;
	logic [31:0] sta_wd = 32'd0;

	daria_fe_audio u_aud (
		.clk_sys(clk_sys), .cart_reset(cart_reset), .pause(pause), .fam(fam), .rev(rev),
		.rom_size(rom_size), .ram32(ram32), .asz(asz), .cdf_dig(cdf_dig),
		.wave0(wave0), .wave1(wave1), .wave2(wave2),
		.note_stb(note_stb), .note_v(note_v), .note_val(note_val),
		.cp_cap(cp_cap), .cp_rot(cp_rot), .cp_shin(cp_shin), .cp_cmp(cp_cmp), .cp_apply(cp_apply),
		.mwin(mwin), .hk_en(hk_en), .hk_stb(hk_stb), .hk_ret(hk_ret),
		.aud_issue(aud_issue), .aud_addr(aud_addr), .aud_take(aud_take), .crb_q(crb_q), .stb_q(stb_q),
		.aud_a_req(aud_a_req), .aud_a_a(aud_a_a), .aud_a_gnt(aud_a_gnt), .fea_q(fea_q),
		.smp_req(smp_req), .smp_addr(smp_addr), .smp_ack(smp_ack), .smp_data(smp_data),
		.amp_nx(amp_nx), .ring0(ring0));

	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(clk_arm), .clk_sys(clk_sys),
		.rom_addr(15'd0), .win_qa(), .d_addr({17'd0, arm_wa[12:0], 2'b00}), .win_qb(),
		.ram_we(arm_en & arm_acc), .ram_be(arm_be), .ram_wdata(arm_wd), .ram_q(),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(sta_a), .sta_we(sta_we), .sta_wd(sta_wd), .sta_q(),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0),
		.fea_addr(fea_addr), .fea_q(fea_q), .feb_addr(13'd0), .feb_q(),
		.crb_addr(crb_addr), .crb_we(cwr), .crb_be(4'b0001 << core_a[1:0]), .crb_wd({4{core_d}}),
		.crb_q(crb_q),
		.stb_addr(stb_addr), .stb_we(stb_we), .stb_be(4'hF), .stb_wd(stb_wd), .stb_q(stb_q));

	// ---- the sample port: upstream's arm_mapper_memory and our wrapper -----------------------
	int  slat_cur = 0;                       // the wrapper's latency for the request made at R
	int  up_scnt = 0;
	logic [7:0] up_sval = 8'h00;
	bit  miss_now = 0;
	int  n_req_loc = 0, n_req_rem = 0, n_miss = 0, n_k0_conf = 0, n_k0_free = 0;
	always @(posedge clk_sys) begin
		up_sdone <= 1'b0;
		if (up_rom_req) begin                // R
			int lat, s;
			s = (k_slat_huge != 0 && pm(k_slat_huge)) ? int'(rr(800, 2000))
			  : (k_slat_big != 0 && pm(k_slat_big)) ? int'(rr(100, 300)) : int'(rr(0, slat_max));
			slat_cur <= s;
			if (u_up.digital_address[31:15] != 17'd0) begin
				if (k_slat_huge != 0 && n_req_rem % 12 == 11) s = int'(rr(800, 2000));   // at least one in twelve
				slat_cur <= s;
				lat = 6 + s;                 // design 5.7: rdone_q at R+6+latency
				n_req_rem++;
				if (s >= 800) orph_req = 1;  // orphan it: the next refresh meets a busy port
			end else if (pm(k_hit)) begin
				lat = 3;                     // a hit: sample_done at R+3 (AUD 8.3)
				n_req_loc++;
			end else begin
				lat = 3 + int'(rr(1, 40));   // a DDR miss: dig_rom_lag
				n_req_loc++;
				n_miss++;
				miss_now = 1;
			end
			up_sbusy <= 1'b1;
			up_scnt  <= lat - 1;
			up_sval  <= img[up_rom_addr[18:0]];
		end else if (up_sbusy) begin
			if (up_scnt == 0) begin up_sdata <= up_sval; up_sbusy <= 1'b0; up_sdone <= 1'b1; end
			else up_scnt <= up_scnt - 1;
		end
	end
	logic smp_seen = 1'b0, spend = 1'b0, aflip = 1'b0;
	int   scnt = 0;
	always @(posedge clk_sys) begin
		aflip <= 1'b0;
		if (smp_req != smp_seen) begin
			smp_seen <= smp_req; spend <= 1'b1; scnt <= slat_cur;
			smp_data <= 8'(rnd());           // undefined until the answer
		end else if (spend) begin
			if (scnt == 0) begin smp_data <= img[smp_addr]; spend <= 1'b0; aflip <= 1'b1; end
			else scnt <= scnt - 1;
		end
		if (aflip) smp_ack <= smp_seen;
	end

	// ---- the ARM: cart RAM words and the return words ---------------------------------------
	longint ak = 0;                          // clk_arm edges; edge k is shared iff k % 5 == 2
	always @(posedge clk_arm) ak <= ak + 1;
	logic [7:0]  sq_a [0:7];
	logic [31:0] sq_d [0:7];
	int sq_gen = 0;                          // clk_sys: a new set of six return words is queued
	int sq_seen = 0;                         // clk_arm: the set being written
	int sq_wr = 6;                           // ... and how many of it are written
	int n_armw = 0;

	function automatic logic [31:0] ptr_val(input bit dig);
		int r;
		logic [31:0] rsz;
		r = int'(rnd() % 100);
		rsz = ram32 ? 32'h8000 : 32'h2000;
		if (!dig) begin
			if (r < 40) return 32'h4000_0800 + rnd() % (rsz - 32'h800);
			if (r < 48) return 32'h4000_0800;
			if (r < 54) return 32'h4000_0000 + rsz - 1;
			if (r < 60) return 32'h4000_0000 + rsz;
			if (r < 65) return 32'h4000_07FF;
			if (r < 85) return rnd() % 32'h1_0000;
			return rnd();
		end
		if (dig_edges && r < 70) begin
			int b;
			b = int'(rnd() % 13);
			case (b)
				0: return rom_size - 1;
				1: return rom_size;
				2: return rom_size + 1;
				3: return 32'd32767;
				4: return 32'd32768;
				5: return 32'h3FFF_FFFF;
				6: return 32'h4000_0000;
				7: return 32'h4000_0000 + rsz - 1;
				8: return 32'h4000_0000 + rsz;
				9: return 32'h4000_0000 + rsz + 1;
				10: return 32'd0;
				11: return 32'hFFFF_FFFF;
				default: return 32'h0007_FFFF + (rnd() % 3);
			endcase
		end
		if (r < dig_loc) return rnd() % 32768;
		if (r < 25 + dig_loc) return 32768 + rnd() % (rom_size + 2048);
		if (r < 78) return 32'h4000_0000 + rnd() % (rsz + 256);
		if (r < 84) return rom_size - 1 - rnd() % 64;
		if (r < 88) return 32'h3FFF_FFF0 + rnd() % 32;
		if (r < 92) return 32'h4000_0000 + rsz - 2 + rnd() % 4;
		return rnd();
	endfunction

	// a word the ARM writes at byte address a (pointer, size, table or random)
	function automatic logic [31:0] arm_val(input logic [14:0] a);
		logic [14:0] w;
		w = {a[14:2], 2'b00};
		if ((w >= 15'h7F0 && w <= 15'h7FC) || (w >= 15'h1B0 && w <= 15'h1B8))
			return ptr_val(pm(p_digptr));
		if (w >= {asz[14:2], 2'b00} && w <= {asz[14:2], 2'b00} + 15'd8)
			return (rnd() & 32'hFFFF_F07F) | (32'(rnd() % 32) << 7);
		if (k_modf != 0 && w >= 15'h1C00) return rnd() % 32'h0010_0000;
		return rnd();
	endfunction

	always @(posedge clk_arm) begin
		sta_we <= 1'b0;
		if (arm_en && arm_acc) begin arm_en <= 1'b0; n_armw++; end
		if (ak % 5 != 1) begin              // the write lands at edge ak+1, not a shared edge
			if (sq_seen != sq_gen) begin
				sq_seen <= sq_gen;
				sta_we <= 1'b1; sta_a <= sq_a[0]; sta_wd <= sq_d[0]; sq_wr <= 1;
			end else if (sq_wr < 6) begin
				sta_we <= 1'b1; sta_a <= sq_a[sq_wr]; sta_wd <= sq_d[sq_wr]; sq_wr <= sq_wr + 1;
			end
		end
		if (!arm_en || arm_acc) begin
			if (!seq_rst && k_arm != 0 && pm(k_arm)) begin
				logic [14:0] a;
				a = pm(700) ? hot_addr() : 15'(rnd());
				a[14:13] = 2'b00;            // the 32 KB both RAMs have
				if (hold_ptr && ((a >= 15'h7F0 && a <= 15'h7FF) || (a >= 15'h1B0 && a <= 15'h1BF)))
					a = 15'h4000;            // not a pointer word
				arm_en <= 1'b1;
				arm_wa <= {2'b00, a[14:2]};
				arm_wd <= arm_val(a);
				arm_be <= pm(800) ? 4'hF : 4'(rr(1, 15));
			end
		end
	end

	// ---- the call model (u_call's strobe timing, design 6.1-6.4) -------------------------------
	typedef enum logic [2:0] {CM_IDLE, CM_POST, CM_RUN, CM_RD, CM_HKW, CM_REL} cm_t;
	cm_t        cm = CM_IDLE;
	logic       pend2 = 1'b0;
	logic [3:0] pidx = 4'd0;
	logic       pgnt = 1'b0;                 // the S port's grant to the post in this clock
	logic       cap1 = 1'b0;
	logic       rd8 = 1'b0;                  // the F8 read is presented in (X-1, X)
	int         xt = 0;                      // in (X+j, X+j+1): xt == j
	longint     x_due = 0;                   // X
	longint     cf_due = -1;                 // sweep: the edge C of the next CALLFN
	longint     p2_due = -1;                 // sweep: the RMW's second write
	longint     own_m = -1;                  // M of the own-path merge in progress (mask window)
	longint     m_edge = -1;                 // M of the last call
	int         rel_wait = 0;
	logic [31:0] pay [0:5];                  // upstream's words at the last launch (L or M)
	logic [31:0] payx [0:5];                 // what our ring must have captured
	logic [31:0] retw [0:5];                 // the returns of the call in flight
	logic [31:0] rseed [0:2];                // ... and the seeds they answer (an RMW's second launch moves pay)
	logic       launch_f3 = 1'b0;            // upstream took seeds at the launch (family >= 2)
	bit         rmw_arm = 0;
	bit         is_rmw2 = 0;                 // the call in flight is an RMW's second call
	int         sw_i = 0;                    // sweep index
	int         sw_offm = 0, sw_patn = 0;
	int         n_call = 0, n_rmw = 0, n_merge_own = 0, n_merge_hk = 0, n_rmw_tick = 0;
	int         n_chg_c = 0, n_unchg_c = 0, n_chg_f = 0, n_unchg_f = 0;
	int         n_rmw_hk = 0, n_rmw_own = 0, n_rmw_dpc = 0;
	assign cm_idle = (cm == CM_IDLE);
	assign cp_cap   = cap1 | ((cm == CM_RD) && xt == 6 && pend2) | ((cm == CM_HKW) && pend2);
	assign cp_rot   = (cm == CM_POST) & pgnt & (pidx >= 4'd2);
	assign cp_shin  = (cm == CM_RD) && xt <= 5;
	assign cp_cmp   = (cm == CM_RD) && xt <= 2;
	assign mwin     = (cm == CM_RD) && xt >= 1 && xt <= 6;
	assign cp_apply = (cm == CM_RD) && xt == 6;
	assign hk_stb   = (cm == CM_HKW);
	assign stb_we   = (cm == CM_POST) & pgnt;
	assign stb_addr = stb_we ? 8'(8'hF0 + pidx) : rd8 ? 8'hF8 : ((cm == CM_RD) && xt <= 4) ? 8'(8'hF9 + xt) : 8'h00;
	assign stb_wd   = (pidx == 4'd0) ? F0W : (pidx == 4'd1) ? F1W : ring0;

	// the next tick edge at or after want, from the accumulator a seen before edge e
	function automatic longint tick_from(input longint e, input logic [23:0] a, input longint want);
		logic [23:0] x;
		x = a;
		for (longint t = e; t < e + 4000; t++) begin
			if (x >= TH) begin
				if (t >= want) return t;
				x = x + WRAP;
			end else x = x + STEP;
		end
		return -1;
	endfunction

	// the returns: pattern 0 none changed, 1 all, 2 c0/c2/f0 changed, 3 c1 and the frequencies; 4 random
	function automatic logic [31:0] newval(input logic [31:0] old, input bit chg, input bit freq_w);
		if (!chg) return old;
		if (freq_w && k_modf != 0) return rnd() % 32'h0010_0000;
		return pm(100) ? old + 32'd1 : rnd();
	endfunction
	task automatic make_returns(input int patn);
		bit cc [0:5];
		for (int i = 0; i < 6; i++) begin
			case (patn)
				0: cc[i] = 0;
				1: cc[i] = 1;
				2: cc[i] = (i == 0 || i == 2 || i == 3);
				3: cc[i] = (i == 1 || i >= 3);
				default: cc[i] = pm(500);
			endcase
			retw[i] = newval(pay[i], cc[i], i >= 3);
			if (i < 3) rseed[i] = pay[i];
			if (i < 3) begin if (cc[i]) n_chg_c++; else n_unchg_c++; end
			else begin if (cc[i]) n_chg_f++; else n_unchg_f++; end
		end
	endtask

	always @(posedge clk_sys) begin
		longint E;
		bit cf;
		E = cyc;
		if (own_m >= 0 && E > own_m + 10) own_m <= -1;
		cap1 <= 1'b0;
		up_launch <= 1'b0;
		up_done <= 1'b0;
		rd8 <= 1'b0;
		pgnt <= pm(850);
		// upstream's launch edge (L, or M for a second call): its payload, pre-edge
		if (up_launch) begin
			pay[0] <= up_c0; pay[1] <= up_c1; pay[2] <= up_c2;
			pay[3] <= up_f0; pay[4] <= up_f1; pay[5] <= up_f2;
			payx[0] <= up_c0; payx[1] <= up_c1; payx[2] <= up_c2;
			payx[3] <= up_f0; payx[4] <= up_f1; payx[5] <= up_f2;
			launch_f3 <= fam[1];
			if (own && cm == CM_RD) begin    // own path, RMW: we capture at M_fe, with a tick at M
				if (u_up.audio_tick) begin
					payx[0] <= up_c0 + up_f0; payx[1] <= up_c1 + up_f1; payx[2] <= up_c2 + up_f2;
					n_rmw_tick++;
				end
			end
		end
		if (cart_reset) begin
			cm <= CM_IDLE; cbusy <= 1'b0; pend2 <= 1'b0; rmw_arm <= 0; own_m <= -1;
			cf_due <= -1; p2_due <= -1;
		end else begin
			// a CALLFN commits at this edge?
			cf = 0;
			if (fam != 2'd0) begin
				if (sweep) cf = (E == cf_due) || (E == p2_due);
				else if (wcommit) begin
					if (rmw_arm) begin rmw_arm <= 0; cf = 1; end
					else cf = (k_call != 0) && pm(k_call);
				end
			end
			if (cf) begin
				if (cm == CM_IDLE) begin
					cbusy <= 1'b1; cm <= CM_POST; pidx <= 4'd0; cap1 <= 1'b1; up_launch <= 1'b1;
					is_rmw2 <= 0; n_call++;
					if (!sweep) rmw_arm <= pm(k_rmw);
					else if (pm(k_rmw)) p2_due <= E + rr(8, 14);
					cf_due <= -1;
				end else if ((cm == CM_POST || cm == CM_RUN) && !pend2) begin
					pend2 <= 1'b1; n_rmw++;
				end
				if (E == p2_due) p2_due <= -1;
			end
			case (cm)
				CM_POST: if (pgnt) begin
					pidx <= pidx + 4'd1;
					if (pidx == 4'd7) begin  // F7 posted: the flip; schedule X and the returns
						longint X, T;
						int patn;
						cm <= CM_RUN;
						if (sweep && fam == 2'd3) begin
							sw_offm = hk_en ? (sw_i % 3) - 1 : (sw_i % 12) - 2;
							sw_patn = hk_en ? (sw_i / 3) % 4 : (sw_i / 12) % 4;
							patn = sw_patn;
							T = tick_from(E, u_up.tick_accum, E + 14 + sw_offm);
							X = T - sw_offm - 1;
							sw_i++;
						end else begin
							patn = 4;
							X = E + (pm(900) ? rr(14, 400) : rr(400, 3000));
						end
						x_due <= X;
						make_returns(patn);
						for (int i = 0; i < 6; i++) begin sq_a[i] = 8'(8'hF8 + i); sq_d[i] = retw[i]; end
						sq_gen = sq_gen + 1;
					end
				end
				CM_RUN: begin
					if (own && fam == 2'd3 && E == x_due - 1) rd8 <= 1'b1;
					if (E == x_due) begin
						for (int i = 0; i < 6; i++) up_ret[i] <= retw[i];
						up_done <= 1'b1;
						m_edge <= E + 1;
						if (pend2) begin                         // upstream's second launch at M
							up_launch <= 1'b1;
							if (fam == 2'd1) n_rmw_dpc++; else if (hk_en) n_rmw_hk++; else n_rmw_own++;
						end
						if (fam == 2'd1) begin
							if (pend2) begin pend2 <= 1'b0; cm <= CM_POST; pidx <= 4'd0; cap1 <= 1'b1; is_rmw2 <= 1; end
							else begin cm <= CM_REL; rel_wait <= int'(rr(0, 20)); end
						end else if (hk_en) begin
							cm <= CM_HKW; n_merge_hk++;
						end else begin
							cm <= CM_RD; xt <= 0; own_m <= E + 1; n_merge_own++;
						end
					end
				end
				CM_RD: begin
					xt <= xt + 1;
					if (xt == 6) begin
						if (pend2) begin pend2 <= 1'b0; cm <= CM_POST; pidx <= 4'd0; is_rmw2 <= 1; end
						else begin cm <= CM_REL; rel_wait <= int'(rr(0, 20)); end
					end
				end
				CM_HKW: begin
					if (pend2) begin pend2 <= 1'b0; cm <= CM_POST; pidx <= 4'd0; is_rmw2 <= 1; end
					else begin cm <= CM_REL; rel_wait <= int'(rr(0, 20)); end
				end
				CM_REL: begin
					if (rel_wait == 0) begin cm <= CM_IDLE; cbusy <= 1'b0; end
					else rel_wait <= rel_wait - 1;
				end
				default: begin               // CM_IDLE
					if (sweep && fam == 2'd3 && cf_due < 0 && !cf) begin   // the next launch L = a tick + (-2 .. 2)
						longint T;
						int offl;
						offl = (sw_i % 5) - 2;
						T = tick_from(E, u_up.tick_accum, E + 6 - offl);
						cf_due <= T + offl - 1;  // C = L - 1
					end
				end
			endcase
		end
	end

	// ---- class state, masks and the resync -----------------------------------------------------
	logic pz_g = 1'b0;                       // upstream's last grant edge had pause high
	logic sel_ld = 1'b0;                     // the select at upstream's last lane load (pause low)
	task automatic cls(input string why);
		if (!m_rep) m_why = why;
		m_rep = 1;
		if (exact) begin
			nerr++;
			$display("ERR %0t seg %0d (%s) edge %0d: class %s in an exact segment", $time, seg, seg_name, cyc, why);
		end
	endtask
	always @(posedge clk_sys) begin
		longint E;
		E = cyc;
		pz_g <= up_grant & pause;
		if (!pause) sel_ld <= sel;
		if (!cart_reset) begin
			if (miss_now) begin miss_now = 0; n_dig_lag++; cls("dig_rom_lag"); end
			// pause_lane: the capture clock after a paused grant edge reads a stale lane
			if (pz_g && !pause && int'(u_up.state) == daria_fe_pkg::AS_SMCAP && sel_ld) begin
				n_pause_lane++; cls("pause_lane");
			end
			// size_over32k: upstream's SIZE read above 32 KB
			if (up_grant && int'(u_up.state) == daria_fe_pkg::AS_SZISS && up_ram_addr[16:15] != 2'd0) begin
				n_size_hi++; cls("size_over32k");
			end
			// merge_amp: a dispatch in (M, M_fe+1] of an own-path merge
			if (own_m >= 0 && E >= own_m + 1 && E <= own_m + 7 && int'(u_up.state) == daria_fe_pkg::AS_IDLE
			    && !(u_up.note_pending && fam == 2'd1) && u_up.refresh_pending) begin
				n_merge_amp++; cls("merge_amp");
			end
		end
	end

	// ---- the checks (falling edge: everything registered at the last rising edge) ---------------
	logic [7:0] amp_nx_q = 8'h00;
	bit         amp_nx_v = 0;
	logic       capd = 1'b0, rotd = 1'b0;
	logic [3:0] pidx_q = 4'd0;
	longint last_tick = -100000;
	longint l_cap = -100;                    // our last launch capture (for the L - T coverage)
	bit back_pending = 0;
	always @(posedge clk_sys) begin
		capd <= cp_cap & !cart_reset;
		if (u_up.audio_tick) last_tick <= cyc;
	end

	`define CK(nm, a, b) \
		if ((a) !== (b)) begin \
			nerr++; \
			if (nerr <= maxerr) $display("ERR %0t seg %0d (%s) edge %0d: %s ours %h upstream %h%s", \
				$time, seg, seg_name, cyc - 1, nm, a, b, m_rep ? {" [mask ", m_why, "]"} : ""); \
		end

	function automatic logic [11:0] up_st1h();
		return 12'd1 << int'(u_up.state);
	endfunction

	task automatic deposit();
		for (int v = 0; v < 3; v++) u_aud.rc[v] = u_up.refresh_counter[v];
		u_aud.voice     = u_up.voice;
		u_aud.ssum      = u_up.sample_sum[7:0];
		u_aud.wsh       = u_up.waveform_shift;
		u_aud.woff      = u_up.waveform_offset;
		u_aud.dig_addr  = u_up.digital_address;
		u_aud.dig_low   = u_up.digital_low_nibble;
		u_aud.dig_ram   = u_up.digital_ram_addr;
		u_aud.dig_smp   = u_up.digital_sample;
		u_aud.amplitude = u_up.amplitude;
		u_aud.np        = u_up.note_pending;
	endtask

	always @(negedge clk_sys) begin
		longint e;
		bit mc, dep;
		dep = 0;
		e = cyc - 1;                     // the edge whose results are now visible
		mc = (own_m >= 0) && e >= own_m && e <= own_m + 6;     // (M, M_fe+1]
		if (!cart_reset && !seq_rst && seg >= 0) begin
			n_cmp++;
			if (m_rep) n_masked_clk++; else n_exact_clk++;
			if (mc) n_cnt_masked++;
			// the tick and the counters (exact on every clock but the own-path merge window)
			`CK("accum", u_aud.accum, u_up.tick_accum)
			`CK("tick", u_aud.tick, (u_up.tick_accum >= TH))
			`CK("a_tdef2", u_aud.a_tdef2, 1'b0)
			if (!mc) begin
				`CK("counter0", u_aud.counter[0], up_c0)
				`CK("counter1", u_aud.counter[1], up_c1)
				`CK("counter2", u_aud.counter[2], up_c2)
				`CK("freq0", u_aud.freq[0], up_f0)
				`CK("freq1", u_aud.freq[1], up_f1)
				`CK("freq2", u_aud.freq[2], up_f2)
			end
			`CK("nv", u_aud.nv, u_up.note_voice)
			`CK("nval", u_aud.nval, u_up.note_value)
			// the replica
			if (!m_rep) begin
				`CK("st", u_aud.st, up_st1h())
				`CK("rc0", u_aud.rc[0], u_up.refresh_counter[0])
				`CK("rc1", u_aud.rc[1], u_up.refresh_counter[1])
				`CK("rc2", u_aud.rc[2], u_up.refresh_counter[2])
				`CK("rp", u_aud.rp, u_up.refresh_pending)
				`CK("np", u_aud.np, u_up.note_pending)
				`CK("voice", u_aud.voice, u_up.voice)
				`CK("ssum", u_aud.ssum, u_up.sample_sum[7:0])
				`CK("wsh", u_aud.wsh, u_up.waveform_shift)
				`CK("woff", u_aud.woff, u_up.waveform_offset)
				`CK("dig_addr", u_aud.dig_addr, u_up.digital_address)
				`CK("dig_low", u_aud.dig_low, u_up.digital_low_nibble)
				`CK("dig_ram", u_aud.dig_ram, u_up.digital_ram_addr)
				`CK("dig_smp", u_aud.dig_smp, u_up.digital_sample)
				`CK("amplitude", u_aud.amplitude, up_amp)
				`CK("aud_issue", aud_issue, up_ram_en)
				if (up_ram_en) `CK("aud_addr", aud_addr, up_ram_addr[14:0])
				`CK("ev_size_hi", u_aud.ev_size_hi, up_ram_en && int'(u_up.state) == daria_fe_pkg::AS_SZISS && up_ram_addr[16:15] != 2'd0)
				`CK("dispatch", u_aud.dispatch, int'(u_up.state) == daria_fe_pkg::AS_IDLE && !(u_up.note_pending && fam == 2'd1) && u_up.refresh_pending)
			end
			if (u_aud.ev_size_hi) n_size_ev++;

			// the ring: capture, rotation, back in place, seeds, returns
			if (capd) begin
				for (int i = 0; i < 6; i++) begin
					if (u_aud.ring[i] !== payx[i]) begin
						nerr++;
						if (nerr <= maxerr) $display("ERR %0t seg %0d edge %0d: ring[%0d] after capture %h expected %h", $time, seg, e, i, u_aud.ring[i], payx[i]);
					end
				end
				n_ring_cap++;
				begin                       // own RMW with a tick on M (rmw_call): continue with upstream's seeds
					bit dif;
					dif = 0;
					for (int i = 0; i < 6; i++) if (payx[i] !== pay[i]) dif = 1;
					if (dif) for (int i = 0; i < 6; i++) u_aud.ring[i] = pay[i];
				end
				if (cm == CM_POST && !is_rmw2) l_cap = e;
			end
			if (e == l_cap + 3) begin           // L - T for a tick within two edges of L
				longint d;
				d = l_cap - last_tick;
				if (d >= -2 && d <= 2) capoff_cov[d + 2]++;
			end
			if (cp_rot) begin
				`CK("ring0 (post)", ring0, pay[pidx - 2])
				n_ring_rot++;
				if (pidx == 4'd7) back_pending = 1;
			end else if (back_pending && cm == CM_RUN) begin
				back_pending = 0;
				for (int i = 0; i < 6; i++) `CK("ring (after post)", u_aud.ring[i], pay[i])
				n_ring_back++;
			end
			if (hk_stb && launch_f3) begin
				for (int i = 0; i < 3; i++) `CK("ring seed (hook)", u_aud.ring[i], u_up.call_seed_counter[i])
				n_hk_seed++;
			end
			if (cp_apply) begin
				for (int i = 0; i < 6; i++) `CK("ring (returns)", u_aud.ring[i], retw[i])
				`CK("take", u_aud.take, {retw[2] != rseed[2], retw[1] != rseed[1], retw[0] != rseed[0]})
				n_own_ret++;
			end
			// the deferred tick: tdef exactly for a tick in [M+1, M_fe], added at M_fe+1
			begin
				bit tin;
				tin = (own_m >= 0) && (last_tick >= own_m + 1) && (last_tick <= own_m + 6) && (e <= own_m + 6);
				`CK("tdef", u_aud.tdef, tin)
				if (tin && e == last_tick) n_tdef++;
				if (own_m >= 0 && e == own_m + 7 && last_tick >= own_m + 1 && last_tick <= own_m + 6) n_late++;
				if (own_m >= 0 && e == own_m + 9 && sweep) begin   // M_fe+3; A1 compared from M_fe+1 on
					longint off;
					off = last_tick - own_m;
					if (off >= -2 && off <= 9) sweep_cov[off + 2][sw_patn]++;
					n_sweep_ok++;
				end
			end
			// the resync: both IDLE, nothing pending, no merge window, no sample in flight
			if (m_rep && !mc && int'(u_up.state) == daria_fe_pkg::AS_IDLE && u_aud.st[daria_fe_pkg::AS_IDLE]
			    && !u_up.refresh_pending && !u_aud.rp && !(fam == 2'd1 && (u_up.note_pending || u_aud.np))
			    && !u_aud.tdef && !mwin && !up_sbusy && !u_aud.busy_l && !u_aud.busy_r && cm != CM_RD) begin
				deposit();
				m_rep = 0;
				n_resync++;
				dep = 1;                    // amp_nx re-evaluates only after this block
			end
		end else begin
			if (cart_reset) begin m_rep = 0; back_pending = 0; end
		end
		// amp_nx (u_core's fe_do loads it) is the next amplitude, reset clocks included
		if (seg >= 0) begin
			if (amp_nx_v && !m_rep) `CK("amp_nx", amp_nx_q, up_amp)
			amp_nx_q = amp_nx;
			amp_nx_v = !m_rep && !dep;
			n_amp_nx++;
		end
		acc_deposit();
		if (nerr > maxerr) $fatal(1, "tb_fe_audio: %0d errors, stopping", nerr);
	end

	// both accumulators moved together: kind 0 puts a tick on the next edge, which is a
	// dispatch edge (AUD 9.3 "a tick at D re-queues"); kind 1 sets TH - 20,000 k, so the
	// accumulator meets TH exactly (the >= of AUD:76). Never with a call in flight.
	bit acc_arm = 0;
	task automatic acc_deposit();            // called last in the falling-edge check block
		if (cart_reset || seq_rst || cbusy || cf_due >= 0 || u_aud.tdef) acc_arm = 0;
		else begin
			if (!acc_arm && k_accdep != 0 && pmm(k_accdep)) acc_arm = 1;
			if (acc_arm) begin
				bit disp_next;
				disp_next = int'(u_up.state) == daria_fe_pkg::AS_IDLE && !(u_up.note_pending && fam == 2'd1)
				            && u_up.refresh_pending;
				if (disp_next || pm(2)) begin
					logic [23:0] v;
					v = disp_next ? TH : TH - 24'(20000 * rr(1, 700));
					u_up.tick_accum = v;
					u_aud.accum = v;
					acc_arm = 0;
					n_accdep++;
				end
			end
		end
	endtask

	always @(negedge clk_sys) if (plant_rom) begin   // both RAMs at one time step
		logic [31:0] a;
		plant_rom = 0;
		hold_ptr = 1;
		a = rnd() % (rom_size < 32'h8_0000 ? rom_size : 32'h8_0000);
		put_word(32'h7F0 >> 2, a);
		put_word(32'h1B0 >> 2, a);
	end

	// the sample client's own timing (design 5.7)
	longint r_edge = -1;
	bit     r_loc = 0;
	int     n_loc_r1 = 0, n_loc_r2 = 0, n_rem_hold = 0;
	logic   req_prev = 1'b0;
	logic [18:0] sa_rec = 19'd0;
	always @(posedge clk_sys) begin
		longint E;
		E = cyc;
		req_prev <= smp_req;
		if (u_aud.st[daria_fe_pkg::AS_RISS] && !u_aud.busy_l && !u_aud.busy_r) begin
			r_edge <= E;
			r_loc  <= (u_aud.dig_addr[31:15] == 17'd0);
		end
		if (r_edge >= 0 && r_loc) begin
			if (aud_a_gnt) begin
				if (E == r_edge + 1) n_loc_r1++;
				else if (E == r_edge + 2) n_loc_r2++;
				else begin nerr++; $display("ERR %0t: local A read granted at R+%0d", $time, E - r_edge); end
				if (fea_addr !== u_aud.dig_addr[14:2]) begin nerr++; $display("ERR %0t: local A address", $time); end
			end
			if (aud_a_req && look_req) n_k0_conf++;
			if (aud_a_req && !look_req && E == r_edge + 1) n_k0_free++;
		end
		if (smp_req !== req_prev) sa_rec <= smp_addr;
		else if (u_aud.busy_r && smp_addr !== sa_rec) begin
			nerr++; $display("ERR %0t: smp_addr changed with a request outstanding", $time);
		end
		if (r_edge >= 0 && !r_loc && u_aud.busy_r) begin
			if (E > r_edge + 1 && smp_req !== req_prev) begin nerr++; $display("ERR %0t: smp_req toggled with a request outstanding", $time); end
			n_rem_hold++;
		end
		if (E > r_edge + 4 && r_loc && u_aud.busy_l) begin nerr++; $display("ERR %0t: busy_l past R+4", $time); end
	end

	// ---- memories: a fresh image and cart RAM per segment, written into both sides -----------------
	task automatic put_word(input int w, input logic [31:0] d);
		u_mem.cart_ram.mem_q[w] = d;
		u_upram.ram_lane[0].lane_ram.mem_q[w] = d[7:0];
		u_upram.ram_lane[1].lane_ram.mem_q[w] = d[15:8];
		u_upram.ram_lane[2].lane_ram.mem_q[w] = d[23:16];
		u_upram.ram_lane[3].lane_ram.mem_q[w] = d[31:24];
	endtask
	task automatic init_mem();
		for (int i = 0; i < 524288; i++) img[i] = 8'(rnd());
		for (int i = 0; i < 8192; i++)
			u_mem.fe_rom.mem_q[i] = {img[4 * i + 3], img[4 * i + 2], img[4 * i + 1], img[4 * i]};
		for (int i = 0; i < 8192; i++) put_word(i, arm_val(15'(4 * i)));
		for (int i = 8192; i < 32768; i++) begin       // upstream's RAM above 32 KB
			u_upram.ram_lane[0].lane_ram.mem_q[i] = 8'h00;
			u_upram.ram_lane[1].lane_ram.mem_q[i] = 8'h00;
			u_upram.ram_lane[2].lane_ram.mem_q[i] = 8'h00;
			u_upram.ram_lane[3].lane_ram.mem_q[i] = 8'h00;
		end
	endtask
	task automatic check_ram();
		int bad;
		bad = 0;
		for (int i = 0; i < 8192; i++) begin
			logic [31:0] u;
			u = {u_upram.ram_lane[3].lane_ram.mem_q[i], u_upram.ram_lane[2].lane_ram.mem_q[i],
			     u_upram.ram_lane[1].lane_ram.mem_q[i], u_upram.ram_lane[0].lane_ram.mem_q[i]};
			if (u !== u_mem.cart_ram.mem_q[i]) bad++;
		end
		if (bad != 0) begin
			nerr++;
			$display("ERR seg %0d: the two cart RAMs differ in %0d words (bench mirror)", seg, bad);
		end
	endtask

	// ---- the segments -----------------------------------------------------------------------------
	task automatic defaults();
		hk_en = 1'b1; own = 0; sweep = 0; exact = 0; pause_on = 1; look_on = 1;
		k_call = 60; k_rmw = 150; k_note = 0; k_note_rnd = 0; k_ov = 0; k_wave = 100; k_dig = 0;
		k_hit = 850; k_look = 700; k_rst = 3; k_orph = 0; k_cwr = 500; k_arm = 30; k_live = 0;
		slat_max = 40; k_slat_big = 0; p_digptr = 300; k_modf = 0;
		sel_w = '{450, 200, 150, 120, 80};
		u_pg.k_pause1 = 5; u_pg.k_pause2 = 5; u_pg.max_pause = 40;
		k_slat_huge = 0; k_accdep = 0; k_livefam = 0; live_mask = 31; dig_edges = 0;
		fam = 2'd3; rev = 2'(rnd()); ram32 = (rev == 2'd3) ? pm(800) : pm(200);
		asz = pm(300) ? 16'd0 : (pm(100) ? 16'(rr(32'h7FF8, 32'hFFFF)) : 16'(rr(32'h100, 32'h7FF0)));
		rom_size = pm(200) ? rr(1024, 32768) : rr(32768, 524288);
		cdf_dig = pm(300);
	endtask
	task automatic config_seg(input int s);
		defaults();
		case (s)
			0: begin seg_name = "cdf_hook";
				rev = 2'd3; ram32 = pm(800); k_dig = 30; k_accdep = 300; end
			1: begin seg_name = "dpc_hook";
				fam = 2'd1; rev = 2'(rnd() % 2); k_note = 300; k_note_rnd = 300; k_ov = 150; k_wave = 300;
				k_call = 30; k_rmw = 350; cdf_dig = 1'b0; k_accdep = 300; end
			2: begin seg_name = "live";
				k_live = 2000; k_note = 200; k_ov = 100; k_dig = 30; k_call = 40; k_livefam = 20; k_accdep = 300;
				cdf_dig = 1'b0; asz = 16'(rr(32'h7FF8, 32'h80FF)); end   // starts on size_over32k
			3: begin seg_name = "cdf_own_sweep";
				hk_en = 1'b0; own = 1; sweep = 1; k_rmw = 200; k_dig = 20; k_rst = 0; pause_on = 0;
				k_hit = 1000; asz = pm(300) ? 16'd0 : 16'(rr(32'h100, 32'h7FF0)); end
			4: begin seg_name = "sample";
				k_dig = 5; cdf_dig = 1'b1; p_digptr = 800; k_hit = 700; slat_max = 60; k_slat_big = 30;
				dig_loc = 45; k_look = 1000; k_lforce = 300; k_slat_huge = 100; k_accdep = 300;
				k_orph = 60; k_modf = 1; rom_size = rr(40000, 524288);
				k_call = 80; k_arm = 60; end
			5: begin seg_name = "exact_cdf";
				exact = 1; pause_on = 0; k_hit = 1000; k_dig = 30; rev = 2'(rnd() % 3); k_accdep = 300;
				asz = pm(300) ? 16'd0 : 16'(rr(32'h100, 32'h7FF0)); end
			6: begin seg_name = "exact_dpc";
				exact = 1; pause_on = 0; fam = 2'd1; rev = 2'(rnd() % 2); k_note = 300; k_note_rnd = 300;
				k_ov = 150; k_wave = 300; k_call = 30; k_rmw = 350; cdf_dig = 1'b0; k_accdep = 300; end
			7: begin seg_name = "cdf_own_random";
				hk_en = 1'b0; own = 1; k_dig = 30; k_rmw = 200; p_digptr = 500; k_orph = 20; end
			8: begin seg_name = "cdf_hook_sweep";
				sweep = 1; k_rmw = 200; k_dig = 20; k_rst = 0; pause_on = 0; k_hit = 1000;
				asz = pm(300) ? 16'd0 : 16'(rr(32'h100, 32'h7FF0)); end
			10: begin seg_name = "pause";            // many short pauses: grants at a pause's last clock
				fam = pm(500) ? 2'd1 : 2'd3; rev = 2'(rnd()); k_note = 100; k_dig = 30;
				u_pg.k_pause1 = 200; u_pg.k_pause2 = 200; u_pg.max_pause = 4; end
			default: begin seg_name = "dig_edges";
				k_call = 0; cdf_dig = 1'b1; k_dig = 0; dig_edges = 1; p_digptr = 1000; k_arm = 100;
				k_live = 1000; live_mask = 2 | 8; k_hit = 1000; slat_max = 10; end
		endcase
	endtask
	function automatic int seg_len(input int s);
		int k;
		case (s)
			0: k = 400;
			1: k = 300;
			2: k = 200;
			3: k = 400;
			4: k = 600;
			5: k = 200;
			6: k = 150;
			7: k = 300;
			8: k = 250;
			9: k = 300;
			default: k = 300;
		endcase
		return k * 10 * scale;                   // k thousand clocks at scale 100
	endfunction

	int n_segs_run = 0;
	initial begin
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("scale=%d", scale));
		void'($value$plusargs("verbose=%d", verbose));
		void'($value$plusargs("maxerr=%d", maxerr));
		void'($value$plusargs("seg=%d", only_seg));
		rs = 32'h2545_F491 ^ (seed * 32'h9E37_79B9);
		if (rs == 0) rs = 1;
		for (int i = 0; i < 12; i++) for (int j = 0; j < 4; j++) sweep_cov[i][j] = 0;
		for (int i = 0; i < 5; i++) capoff_cov[i] = 0;
		$display("tb_fe_audio: seed %0d scale %0d%%", seed, scale);
		for (int s = 0; s < NSEG; s++) if (only_seg < 0 || s == only_seg) begin
			@(negedge clk_sys);
			seq_rst = 1'b1;
			seg = s;
			config_seg(s);
			init_mem();
			repeat (int'(rr(2, 20))) @(negedge clk_sys);
			if (verbose) $display("seg %0d %s: fam %0d rev %0d ram32 %0d asz %h rom_size %0d", s, seg_name, fam, rev, ram32, asz, rom_size);
			seq_rst = 1'b0;
			repeat (seg_len(s)) @(negedge clk_sys);
			check_ram();
			n_segs_run++;
			$display("seg %0d %-15s done: %0d clocks compared, %0d errors so far", s, seg_name, n_cmp, nerr);
		end
		report();
		if (nerr != 0) $fatal(1, "tb_fe_audio: FAIL, %0d errors", nerr);
		$display("tb_fe_audio: PASS");
		$finish;
	end

	task automatic need(input string what, input int got, input int min);
		$display("  %-46s %8d%s", what, got, (got < min) ? $sformatf("   < %0d: NOT COVERED", min) : "");
		if (got < min) nerr++;
	endtask
	task automatic report();
		bit full;
		int sw_min, cap_min;
		full = (only_seg < 0) && (scale >= 100);
		$display("tb_fe_audio: %0d clocks compared (%0d with every register, %0d with the replica masked by a class, %0d with the counters masked in (M, M_fe+1])",
			n_cmp, n_exact_clk, n_masked_clk, n_cnt_masked);
		$display("refreshes and the replica:");
		need("upstream refreshes (dispatches)", n_disp, full ? 1000 : 0);
		need("  DPC+ refreshes", n_disp_dpc, full ? 300 : 0);
		need("  CDF waveform refreshes", n_disp_cdf, full ? 300 : 0);
		need("  digital: ROM local / remote", n_req_loc + n_req_rem, full ? 150 : 0);
		need("  digital: RAM window samples", n_dig_ram, full ? 80 : 0);
		need("  digital: out of range (amplitude 0)", n_dig_none, full ? 50 : 0);
		need("  CDFJ+ waveform window in / out", n_woff_in, full ? 50 : 0);
		need("  size words read", n_size_rd, full ? 100 : 0);
		need("  grants delayed by the select", n_grant_wait, full ? 1000 : 0);
		need("  sample bytes read in a pause ($FF)", n_pause_byte, full ? 10 : 0);
		need("  sample grants on a pause's last clock (lane at the last unpaused edge)", n_pz_grant, full ? 10 : 0);
		need("  ticks on a dispatch edge (re-queued)", n_tick_disp, full ? 20 : 0);
		need("  ticks with a refresh already pending (coalesced)", n_coalesce, full ? 20 : 0);
		need("  accumulator at exactly TH", n_tick_eq, full ? 10 : 0);
		need("  accumulator deposits (both engines)", n_accdep, 0);
		need("  family changed in the middle of a refresh", n_fam_mid, full ? 10 : 0);
		need("  digital route at rom_size - 1 / rom_size", n_rom_edge, full ? 10 : 0);
		need("  rom_size above $4000_0000 (RAM window under ROM)", n_huge, full ? 2 : 0);
		need("  amp_nx checked (every clock, resets included)", n_amp_nx, 0);
		need("NOTE loads (NCAP)", n_ncap, full ? 200 : 0);
		need("  strobe at the NOTE grant edge g (s = g)", n_note_ov_g, full ? 3 : 0);
		need("  strobe at g+1", n_note_ov_g1, full ? 3 : 0);
		need("  NOTE voice 3 (writes frequency2)", n_nv3, full ? 5 : 0);
		need("calls", n_call, full ? 300 : 0);
		need("  RMW second calls", n_rmw, full ? 30 : 0);
		need("    swapped at M (hook, CDF)", n_rmw_hk, full ? 10 : 0);
		need("    swapped at M_fe (own path, CDF)", n_rmw_own, full ? 10 : 0);
		need("    swapped at M (DPC+)", n_rmw_dpc, full ? 10 : 0);
		need("  hook merges", n_merge_hk, full ? 100 : 0);
		need("  own-path merges (cp_apply)", n_own_ret, full ? 200 : 0);
		need("  counters returned changed / unchanged", n_chg_c, full ? 100 : 0);
		need("", n_unchg_c, full ? 100 : 0);
		need("  frequencies returned changed / unchanged", n_chg_f, full ? 100 : 0);
		need("", n_unchg_f, full ? 100 : 0);
		need("  ring captures checked", n_ring_cap, full ? 300 : 0);
		need("  ring rotations checked", n_ring_rot, full ? 1800 : 0);
		need("  ring back in place after the post", n_ring_back, full ? 300 : 0);
		need("  hook seeds checked", n_hk_seed, full ? 50 : 0);
		need("  deferred ticks (tdef) / late adds", n_tdef, full ? 50 : 0);
		need("", n_late, full ? 50 : 0);
		need("  rmw_call: a tick on M under an RMW (own path)", n_rmw_tick, 0);
		need("  hook merges with a tick on M and a changed counter", n_hk_tickm, full ? 5 : 0);
		sw_min = 1000; cap_min = 1000;
		for (int i = 0; i < 12; i++) for (int j = 0; j < 4; j++) if (sweep_cov[i][j] < sw_min) sw_min = sweep_cov[i][j];
		for (int i = 0; i < 5; i++) if (capoff_cov[i] < cap_min) cap_min = capoff_cov[i];
		$display("  tick sweep T - M = -2 .. +9 (rows) x pattern 0-3 (columns):");
		for (int i = 0; i < 12; i++) $display("    %3d: %4d %4d %4d %4d", i - 2, sweep_cov[i][0], sweep_cov[i][1], sweep_cov[i][2], sweep_cov[i][3]);
		need("  sweep: the least-covered (offset, pattern)", sw_min, full ? 1 : 0);
		$display("  launch L - T = -2 .. +2: %0d %0d %0d %0d %0d", capoff_cov[0], capoff_cov[1], capoff_cov[2], capoff_cov[3], capoff_cov[4]);
		need("  launch offsets: the least covered", cap_min, full ? 3 : 0);
		$display("sample client:");
		need("  local requests", n_req_loc, full ? 50 : 0);
		need("  local A read at R+1", n_loc_r1, full ? 30 : 0);
		need("  local A read at R+2 (k[0] conflict)", n_loc_r2, full ? 10 : 0);
		need("  remote requests", n_req_rem, full ? 50 : 0);
		need("  orphaned requests across cart_reset", n_orph_seen, full ? 3 : 0);
		need("  RISS waiting on a busy sample port", n_orph_wait, full ? 2 : 0);
		$display("classes (counted, masked, resynchronised):");
		need("  merge_amp", n_merge_amp, 0);
		need("  dig_rom_lag (upstream misses)", n_dig_lag, 0);
		need("  pause_lane", n_pause_lane, 0);
		need("  size_over32k (upstream SIZE reads above 32 KB)", n_size_hi, 0);
		need("  ev_size_hi pulses (checked against upstream's address)", n_size_ev, full ? 1 : 0);
		need("  resyncs", n_resync, 0);
		$display("other: %0d ARM words, %0d resets mid-segment, %0d live option changes", n_armw, n_rst, n_live);
	endtask

	// ---- coverage taps on upstream (what happened, not what was checked) -----------------------
	always @(posedge clk_sys) begin
		if (!cart_reset) begin
			if (u_up.audio_tick && int'(u_up.state) == daria_fe_pkg::AS_IDLE && !(u_up.note_pending && fam == 2'd1)
			    && u_up.refresh_pending) n_tick_disp++;
			if (u_up.tick_accum == TH) n_tick_eq++;
			if (u_up.audio_tick && u_up.refresh_pending && fam != 2'd0) n_coalesce++;
			if (hk_stb && u_up.audio_tick && launch_f3
			    && (up_ret[0] != u_up.call_seed_counter[0] || up_ret[1] != u_up.call_seed_counter[1]
			        || up_ret[2] != u_up.call_seed_counter[2])) n_hk_tickm++;
			if (int'(u_up.state) == daria_fe_pkg::AS_DROUTE
			    && (u_up.digital_address == rom_size || u_up.digital_address + 1 == rom_size)) n_rom_edge++;
			if (int'(u_up.state) == daria_fe_pkg::AS_RISS && up_sbusy && !riss_w) n_orph_wait++;
			if (int'(u_up.state) == daria_fe_pkg::AS_DROUTE) hold_ptr = 0;
			riss_w <= int'(u_up.state) == daria_fe_pkg::AS_RISS && up_sbusy;
			if (int'(u_up.state) == daria_fe_pkg::AS_IDLE && !(u_up.note_pending && fam == 2'd1) && u_up.refresh_pending) begin
				n_disp++;
				if (fam == 2'd1) n_disp_dpc++;
				else if (fam == 2'd3 && !cdf_dig) n_disp_cdf++;
			end
			if (int'(u_up.state) == daria_fe_pkg::AS_DROUTE && !(u_up.digital_address < rom_size)) begin
				if (u_up.digital_address >= 32'h4000_0000 && u_up.digital_address - 32'h4000_0000 < (ram32 ? 32'h8000 : 32'h2000))
					n_dig_ram++;
				else n_dig_none++;
			end
			if (int'(u_up.state) == daria_fe_pkg::AS_PCAP && !(fam == 2'd3 && cdf_dig) && rev == 2'd3
			    && up_word >= 32'h4000_0800 && up_word - 32'h4000_0800 < (ram32 ? 32'h7800 : 32'h1800)) n_woff_in++;
			if (int'(u_up.state) == daria_fe_pkg::AS_SZCAP) n_size_rd++;
			if (up_ram_en && sel) n_grant_wait++;
			if (int'(u_up.state) == daria_fe_pkg::AS_SMCAP && pause) n_pause_byte++;
			if (int'(u_up.state) == daria_fe_pkg::AS_SMCAP && !pause && pz_g) n_pz_grant++;
			if (int'(u_up.state) == daria_fe_pkg::AS_NCAP) begin n_ncap++; if (u_up.note_voice == 2'd3) n_nv3++; end
		end else if ((u_aud.busy_l || u_aud.busy_r) && !rst_q) n_orph_seen++;
	end
	always @(posedge clk_sys) rst_q <= cart_reset;
endmodule

`default_nettype wire
