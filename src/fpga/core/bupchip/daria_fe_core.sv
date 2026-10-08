//------------------------------------------------------------------------------
// DARIA front end: the 6507 side of DPC+ and of the CDF family
// (docs/daria_fe/design.md 2.2-2.6): the mirror address and the op latch, W
// and its adder, fe_do, the scheme state, the commit actions under the ready
// rule (2.3), the pointer buffer, the P32 read, the service latch, and the
// NOTE/waveform/mode outputs to the audio. It holds u_dec.
// Reset: rst_fe (1.5 rule 7).
//
// The schedule (E0 = the pclk1 edge, C = the commit edge, k/c from u_seq):
//   k[0]  B: the mirror reads rom_a (every clock); A: the CDF lookahead word.
//   k[1]  jok from {fea_q, feb_q}; op <- {dec, jok} @2. Fixed reads: CDF
//         pointer R (pb + idx); DPC+ fetcher S (w0/w1[ix], or word $10).
//         P32 R for DSWRITE/DSPTR (yielding; retried in k[2]).
//   k[2]  W <- the pointer (CDF) or the fetcher word (DPC+) @3; CDF/DPC+
//         data R at the data address; DPC+ CALLFUNCTION S w0[p2 & 7].
//   k[3]  fe_do <- the RAM byte @4; DPC+ W + step @4 (rdW), ba, cnt_st
//         (rdS); CDF increment R.
//   k[4]  CDF W <- P + increment (or the jump step) @5 (rdW).
//   C     kind 1 (flip-flop state) always; kind 2 (DSWRITE, DSPTR, the
//         service latch) if its data is ready, else in the first clock it
//         is (pend_c); kind 3 (S and R post writes) from the clock after C
//         once ready (pend_s, pend_r). The pointer buffer drains on wb_gnt
//         once rdW. A deferred action still pending at the next pclk1 is
//         dropped there (only a cycle in which rst_fe falls can leave one).
// Every rule is the design's 2.3/2.4; the register reference of 2.4 is the
// table each always_ff block below follows (D10: one load enable and at most
// four data sources per register, AND-OR one-hot selects).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_core (
	input  wire         clk_sys,
	input  wire         rst_fe,       // cart_reset | !(is_dpc | is_cdf) | scheme != scheme_q
	// scheme
	input  wire         is_dpc,
	input  wire         is_cdf,
	input  wire         jplus,        // CDFJ+ (is_cdf & revision[1:0] == 3)
	input  wire         jrev,         // CDFJ, CDFJ+ (is_cdf & revision[1:0] >= 2)
	input  wire   [1:0] rev,          // step 0 (S0-6): revision[1:0], for pb/ib (2.4)
	input  wire         sf,           // revision[0]: DPC+ stable_fractional
	input  wire         ldx,
	input  wire         ldy,
	input  wire         foff_en,
	input  wire   [7:0] foff,
	// bus
	input  wire  [12:0] a_in,
	input  wire   [7:0] d_in,         // write_DB
	input  wire         rw,
	input  wire         access,
	// seq
	input  wire         pclk1,        // step 0 (S0-7): the ready flags clear at every pclk1 (2.3)
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire   [7:0] k,            // k[7:5]: no rule reads them here
	/* verilator lint_on UNUSEDSIGNAL */
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire   [3:0] c,            // no rule reads it (interfaces.md 10 item 3, L-3)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire         commit,
	input  wire         ph1_open,
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire         ev_short,     // counted by the bench from u_seq; no rule reads it
	/* verilator lint_on UNUSEDSIGNAL */
	// M10K q
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire  [31:0] fea_q,        // [31:16]: the lookahead needs bytes 4 and 5 only
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire  [31:0] feb_q,
	input  wire  [31:0] crb_q,
	input  wire  [31:0] stb_q,
	// arb
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire         aud_take,     // no rule reads it (p32_gnt/wb_gnt already contain !aud_take)
	input  wire         look_gnt,     // no rule reads it (the lookahead is always granted, 3.3)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire         p32_gnt,
	input  wire         wb_gnt,
	// guard
	input  wire         guard_on,
	// audio
	input  wire   [7:0] amp_nx,       // the value amplitude holds after this edge
	// copy
	input  wire         svc_take,     // pulse: the engine took the latched service
	input  wire         init_busy,
	input  wire         dma_busy,     // step-0 review (R-2): u_copy's arm_dma_busy, for ev_rmw_svc
	// call
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire         call_busy,    // u_call's arm_call_busy; no rule reads it
	/* verilator lint_on UNUSEDSIGNAL */
	// out, 6507
	output logic  [7:0] fe_do,        // reg
	// out, decode
	output logic        sel_up,       // comb (u_dec)
	output logic [12:0] feb_addr,     // comb: rom_a[14:2]
	// out, R fixed
	output logic        cr_fix,       // comb
	output logic [12:0] cr_fix_a,
	output logic        cr_fix_we,
	output logic  [3:0] cr_fix_be,
	output logic [31:0] cr_fix_wd,
	output logic        cr_fix_use,   // a consumed read
	// out, R yield
	output logic        cr_p32,       // comb
	output logic [12:0] cr_p32_a,
	output logic        cr_wb,        // wb_v & rdW (3.1; S0-8)
	output logic [12:0] cr_wb_a,      // {4'b0, wb_a}
	output logic [31:0] cr_wb_wd,     // W
	// out, S (DPC+ only; always granted, 3.2)
	output logic        cs_req,
	output logic  [7:0] cs_a,
	output logic        cs_we,
	output logic  [3:0] cs_be,
	output logic [31:0] cs_wd,
	// out, A
	output logic        look_req,     // k[0] & is_cdf & !init_busy
	output logic [12:0] look_a,       // rom_a[14:2] + 1
	// out, audio
	output logic  [6:0] wave0,        // reg
	output logic  [6:0] wave1,        // reg
	output logic  [6:0] wave2,        // reg
	output logic        note_stb,     // reg pulse in (C, C+1)
	output logic  [1:0] note_v,       // reg
	output logic  [7:0] note_val,     // reg
	output logic        cdf_dig,      // mode[7:4] == 0
	// out, call
	output logic        callfn,       // comb pulse at C: $105A / $1FF3 commit, d_in in {FE, FF}
	// out, copy
	output logic        svc_pend,     // reg
	output logic        svc_hold,     // svc_pend | (pend_c == PC_SVC)
	output logic        svc_fill,     // reg
	output logic [16:0] svc_src,      // reg
	output logic [12:0] svc_dst,      // reg
	output logic  [7:0] svc_rem,      // reg: the requested p3
	output logic  [7:0] svc_val,      // reg
	output logic        dma_set,      // comb pulse at C: a taken CALLFUNCTION 1/2
	// out, to u_arb's assertions (step 0, S0-9; all are 1.7 taps)
	output daria_fe_pkg::dec_t op,    // reg: the op latched @2
	output logic        p32_q,        // reg: the P32 read registered at this edge
	output logic        rdP,          // reg: W holds P32
	output logic        wb_v,         // reg: the pointer buffer is full
	output logic        ev_guard_sup  // pulse: a fixed R or P32 request suppressed by guard_on
);
	import daria_fe_pkg::*;

	// ---- the decode -----------------------------------------------------------------
	dec_t        dec;
	logic [14:0] rom_a;
	logic  [7:0] romb;

	// ---- bench taps (design 1.7; frozen names) --------------------------------------
	// p32_in, rdS, ev_tbl_alias, ev_rmw_svc, a_fpjr and a_pend_late are read only
	// by the bench (fe_taps.svh); the others are also state.
	/* verilator lint_off UNUSEDSIGNAL */
	logic  [2:0] bank;
	logic        fpend;
	logic [31:0] W;
	logic  [8:0] wb_a;
	logic        p32_in;              // = p32_q (S0-10)
	logic        pend_s;
	logic        pend_r;
	logic  [1:0] pend_c;              // daria_fe_pkg::PC_*
	logic        rdW;
	logic        rdS;
	logic        ff_en;
	logic [31:0] rnd;
	logic  [3:0] pptr;
	logic  [6:0] wave [0:2];
	logic  [7:0] mode;
	logic [12:0] fexp;
	logic  [1:0] jr;
	logic [12:0] jexp;
	logic  [5:0] jstream;
	logic        ev_tbl_alias;
	logic        ev_rmw_svc;
	logic        a_fpjr;
	logic        a_pend_late;
	/* verilator lint_on UNUSEDSIGNAL */

	daria_fe_dec u_dec (
		.a_in    (a_in),
		.rw      (rw),
		.access  (access),
		.romb    (romb),
		.is_dpc  (is_dpc),
		.is_cdf  (is_cdf),
		.jplus   (jplus),
		.jrev    (jrev),
		.ldx     (ldx),
		.ldy     (ldy),
		.foff_en (foff_en),
		.foff    (foff),
		.bank    (bank),
		.ff_en   (ff_en),
		.fpend   (fpend),
		.fexp    (fexp),
		.jr      (jr),
		.jexp    (jexp),
		.jstream (jstream),
		.mode    (mode),
		.dec     (dec),
		.sel_up  (sel_up),
		.rom_a   (rom_a)
	);

	// ---- the mirror (2.2): tb_daria's cart_q <= rom[cart_addr], word-wide ---------------
	logic [1:0] lane_q;                  // rom_a[1:0] of the clock before (no reset)
	always_ff @(posedge clk_sys) lane_q <= rom_a[1:0];
	assign feb_addr = rom_a[14:2];
	assign romb     = feb_q[8*lane_q +: 8];

	// ---- the jump lookahead (2.2): cdf_fastjump_table's bit for rom_a, in k[1] --------
	// {fea_q, feb_q} are the image bytes rom_a & ~3 ... + 7 (A@1 read rom_a[14:2] + 1).
	/* verilator lint_off UNUSEDSIGNAL */
	logic [7:0] lb1;                     // the byte at rom_a + 1 (bit 0 is the CDFJ stream select)
	/* verilator lint_on UNUSEDSIGNAL */
	logic [7:0] lb2;                     // the byte at rom_a + 2
	always_comb begin
		case (lane_q)
			2'd0:    begin lb1 = feb_q[15:8];  lb2 = feb_q[23:16]; end
			2'd1:    begin lb1 = feb_q[23:16]; lb2 = feb_q[31:24]; end
			2'd2:    begin lb1 = feb_q[31:24]; lb2 = fea_q[7:0];   end
			default: begin lb1 = fea_q[7:0];   lb2 = fea_q[15:8];  end
		endcase
	end
	wire jok = dec.b4c & (lb1[7:1] == 7'd0) & (lb2 == 8'd0) & (rom_a[14:1] != 14'h3FFF);

	// ---- the op latch (2.2): constant from (E0+1, E0+2) up to C ----------------------------
	dec_t op_r;                          // no reset
	dec_t dj;
	always_comb begin
		dj     = dec;
		dj.jok = jok;
	end
	dec_t opc;                           // the op at a commit edge (dec if C = E0+2)
	always_ff @(posedge clk_sys) if (k[1]) op_r <= dj;            // latched @2
	always_comb opc = k[1] ? dj : op_r;
	assign op = op_r;

	// ---- common terms ---------------------------------------------------------------------
	wire        rdC       = commit & rw;
	wire        fast_mode = mode[3:0] == 4'h0;
	wire        o_rdat    = op_r.c.rdat;
	wire        o_rflg    = op_r.c.rflg;
	wire        o_dpw     = op_r.c.dpw;
	wire        o_dcf     = op_r.c.dcf;
	wire        o_cfet    = op_r.c.cfet;
	wire        o_cjmp    = op_r.c.cjmp;
	wire        o_ds      = op_r.c.cdsw | op_r.c.cdsp;
	wire        o_push    = op_r.g == 4'd7;                        // DFxPUSH (g 7) vs DFxWRITE (g 10)
	wire        c_sub     = opc.c.cfet | opc.c.cjmp | (is_cdf & opc.c.amp);   // CDF stream_substitute
	wire        d_regc    = opc.c.rrnd | opc.c.amp | opc.c.rdat | opc.c.rflg; // DPC+ register_read
	wire  [2:0] a3        = a_in[2:0];
	wire        d1or2     = (d_in == 8'd1) | (d_in == 8'd2);

	// pointer and increment table bases (word addresses; 4.3)
	wire  [8:0] pb = (rev == 2'd0) ? 9'h1B8 : ((rev == 2'd1) ? 9'h028 : 9'h026);
	wire  [8:0] ib = (rev == 2'd0) ? 9'h1DA : ((rev == 2'd1) ? 9'h04A : 9'h049);

	// data address of the k[2] read (byte address; from the word read @2)
	wire [11:0] d_cnt     = (op_r.fn == 3'd3) ? stb_q[19:8] : stb_q[11:0];
	wire [14:0] data_addr = is_dpc ? (15'h0C00 + {3'b000, d_cnt})
	                      : (jplus ? (15'h0800 + crb_q[30:16]) : (15'h0800 + {3'b000, crb_q[31:20]}));
	// DSWRITE's display address (15 bits: wraps mod $8000, D8)
	wire [14:0] dsw_addr  = jplus ? (15'h0800 + W[30:16]) : (15'h0800 + {3'b000, W[31:20]});

	// the window flag: (top - counter[7:0]) > (top - bottom), 8-bit (DPC §14.6)
	wire  [7:0] wtc = stb_q[23:16] - stb_q[7:0];
	wire  [7:0] wtb = stb_q[23:16] - stb_q[31:24];
	wire        win = wtc > wtb;

	// the LFSR (mapper_dpcplus.sv:79-84)
	wire [31:0] rnd_next  = ((rnd >> 11) | (rnd << 21)) ^ (rnd[10] ? 32'h10ADAB1E : 32'h0);
	wire [31:0] rnd_pxor  = rnd[31] ? (rnd ^ 32'h10ADAB1E) : rnd;
	wire [31:0] rnd_prior = (rnd_pxor << 11) | (rnd_pxor >> 21);

	// ---- kind 2: the at-commit actions and their ready flags (2.3) ------------------------
	logic        rdS_r;
	logic [7:0]  din;                    // d_in at the commit (no reset)
	wire at_dsw = commit & opc.c.cdsw;
	wire at_dsp = commit & opc.c.cdsp;
	wire at_svc = commit & opc.c.dcf & d1or2 & !svc_pend;        // a taken CALLFUNCTION 1/2
	wire act_dsw = (at_dsw | (pend_c == PC_DSW)) & rdP;
	wire act_dsp = (at_dsp | (pend_c == PC_DSP)) & rdP;
	wire act_svc = (at_svc | (pend_c == PC_SVC)) & rdS_r;
	wire [7:0] d_act = commit ? d_in : din;                       // din once deferred
	assign rdS = rdS_r;

	// The post actions (pend_c here, pend_s and pend_r below): reset first, then
	// the set at C, then the clear when the action fires or at pclk1. Every set
	// needs commit, and commit (a pclk0 clock) never shares a clock with pclk1,
	// so the set's priority over the pclk1 clear never decides anything. Outside
	// a reset every action has fired before pclk1 (a_pend_late), so the pclk1
	// clear only drops an action whose cycle ran its reads under rst_fe, which
	// would otherwise fire in a later cycle with that cycle's W
	// (docs/daria_fe/lanes/F1_fixes.md, 1).
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			pend_c <= PC_NONE;
		else if (at_dsw & !rdP)
			pend_c <= PC_DSW;
		else if (at_dsp & !rdP)
			pend_c <= PC_DSP;
		else if (at_svc & !rdS_r)
			pend_c <= PC_SVC;
		else if (act_dsw | act_dsp | act_svc | pclk1)
			pend_c <= PC_NONE;
	end

	// ---- P32 (3.1): DSWRITE/DSPTR's stream-32 pointer, yielding --------------------------
	logic p32_got;
	always_ff @(posedge clk_sys) begin
		if (rst_fe) begin
			p32_q   <= 1'b0;
			p32_got <= 1'b0;
		end else begin
			p32_q <= p32_gnt;                                      // W <- crb_q at the next edge
			if (k[1]) p32_got <= p32_gnt;
		end
	end
	assign cr_p32   = (k[1] & (dec.c.cdsw | dec.c.cdsp)) | (k[2] & o_ds & !p32_got);
	assign cr_p32_a = {4'h0, pb + 9'd32};
	assign p32_in   = p32_q;

	// ---- W and its adder (2.4) --------------------------------------------------------------
	wire ld_crb = (k[2] & (o_cfet | o_cjmp)) | p32_q;
	wire ld_stb = k[2] & (o_rdat | o_dpw | o_dcf);
	wire ld_add = (k[3] & (o_rdat | o_dpw)) | (k[4] & (o_cfet | o_cjmp)) | act_dsw;
	wire ld_shf = act_dsp;

	wire bv_fn = k[4] & o_cfet & !jplus;                           // P + inc << 12
	wire bv_fp = k[4] & o_cfet & jplus;                            // P + inc << 8
	wire bv_j  = (k[4] & o_cjmp) | act_dsw;                        // the jump / DSWRITE step
	wire bv_1  = k[3] & ((o_rdat & (op_r.fn != 3'd3)) | (o_dpw & !o_push));
	wire bv_f  = k[3] & o_dpw & o_push;                            // counter - 1 (12 bits)
	wire bv_i  = k[3] & o_rdat & (op_r.fn == 3'd3);                // fraction + increment
	wire [31:0] Bv = ({32{bv_fn}}         & {4'h0, crb_q[15:0], 12'h000})
	               | ({32{bv_fp}}         & {8'h0, crb_q[15:0], 8'h00})
	               | ({32{bv_j & !jplus}} & 32'h0010_0000)
	               | ({32{bv_j & jplus}}  & 32'h0001_0000)
	               | ({32{bv_1}}          & 32'h0000_0001)
	               | ({32{bv_f}}          & 32'h0000_0FFF)
	               | ({32{bv_i}}          & {24'h0, W[31:24]});
	wire [31:0] Wsum = W + Bv;
	wire [31:0] shf  = jplus ? {W[23:16], d_act, 16'h0000} : {W[23:20], d_act, 20'h00000};

	always_ff @(posedge clk_sys)
		if (ld_crb | ld_stb | ld_add | ld_shf)
			W <= ({32{ld_crb}} & crb_q) | ({32{ld_stb}} & stb_q) | ({32{ld_add}} & Wsum) | ({32{ld_shf}} & shf);

	// ---- the phase-1 staging registers (no reset) -----------------------------------------
	logic  [1:0] cl;                     // the data byte's lane
	logic        wf;                     // the window flag of the fetcher read @2
	logic [12:0] ba;                     // PUSH/WRITE byte address
	logic [11:0] cnt_st;                 // CALLFUNCTION: counter[p2 & 7]
	always_ff @(posedge clk_sys) begin
		if (k[2] & (o_rdat | o_cfet | o_cjmp)) cl <= data_addr[1:0];
		if (k[2]) wf <= win;
		if (k[3] & o_dpw) ba <= 13'h0C00 + {1'b0, (o_push ? Wsum[11:0] : W[11:0])};
		if (k[3] & o_dcf) cnt_st <= stb_q[11:0];
		if (commit) din <= d_in;
	end

	// ---- the ready flags (2.3): cleared at every pclk1 ------------------------------------
	always_ff @(posedge clk_sys) begin
		if (rst_fe | pclk1) begin
			rdW   <= 1'b0;
			rdP   <= 1'b0;
			rdS_r <= 1'b0;
		end else begin
			if ((k[3] & (o_rdat | o_dpw)) | (k[4] & (o_cfet | o_cjmp)) | act_dsw | act_dsp) rdW <= 1'b1;
			if (p32_q) rdP <= 1'b1;
			if (k[3] & o_dcf) rdS_r <= 1'b1;
		end
	end

	// ---- kind 1: the scheme state at C (2.4) ----------------------------------------------
	wire        hot_end  = (a_in[11:0] == 12'hFF4) | (a_in[11:0] == 12'hFFB);
	wire  [2:0] bank_rst = is_dpc ? 3'd5 : (jplus ? 3'd0 : 3'd6);
	wire  [2:0] bank_d   = is_dpc ? (a3 - 3'd6)
	                     : (hot_end ? (jplus ? 3'd0 : 3'd6) : (a3 - (jplus ? 3'd4 : 3'd5)));
	wire        fp_d     = is_dpc ? (!d_regc & ff_en & opc.a9) : (!c_sub & fast_mode & opc.arms);
	wire        jr_hit   = (jr != 2'd0) & (a_in == jexp);
	wire        arm_j    = !c_sub & !jr_hit & fast_mode & opc.b4c & opc.jok;
	wire        cdf_rd   = is_cdf & rdC;
	wire        g6c      = opc.g == 4'd6;
	wire        g9c      = opc.g == 4'd9;
	wire        mis6     = commit & opc.c.dmisc & g6c;             // $058, $05D-$05F
	wire        mis9     = commit & opc.c.dmisc & g9c;             // $070-$077

	always_ff @(posedge clk_sys) begin
		if (rst_fe) begin
			bank    <= bank_rst;
			fpend   <= 1'b0;
			fexp    <= 13'd0;
			jr      <= 2'd0;
			jexp    <= 13'd0;
			jstream <= 6'd33;
			mode    <= 8'hFF;
			ff_en   <= 1'b0;
			pptr    <= 4'd0;
		end else begin
			if (commit & opc.hot) bank <= bank_d;
			if (rdC) fpend <= fp_d;
			if (cdf_rd & !c_sub & fast_mode & opc.arms) fexp <= a_in + 13'd1;
			if (cdf_rd & (opc.c.cjmp | !c_sub)) jr <= opc.c.cjmp ? (jr - 2'd1) : (arm_j ? 2'd2 : 2'd0);
			if (cdf_rd & (opc.c.cjmp | arm_j)) jexp <= opc.c.cjmp ? (jexp + 13'd1) : (a_in + 13'd1);
			if (cdf_rd & ((opc.c.cjmp & jrev & (jr == 2'd2)) | arm_j))
				jstream <= opc.c.cjmp ? (6'd33 + {5'd0, opc.romb0}) : 6'd33;
			if (commit & opc.c.cmode) mode <= d_in;
			if (mis6 & (a3 == 3'd0)) ff_en <= d_in == 8'd0;
			if (commit & opc.c.dpar & (pptr < 4'd8)) pptr <= pptr + 4'd1;
			else if (commit & opc.c.dcf & ((d_in == 8'd0) | (d1or2 & !svc_pend))) pptr <= 4'd0;
		end
	end

	// the LFSR, a byte at a time
	wire       rnd_nx = rdC & opc.c.rrnd & (opc.ix == 3'd0);       // RANDOM0NEXT
	wire       rnd_pr = rdC & opc.c.rrnd & (opc.ix == 3'd1);       // RANDOM0PRIOR
	wire       rnd_rs = mis9 & (a3 == 3'd0);                       // RRESET
	wire [3:0] rnd_wb = {mis9 & (a3 == 3'd4), mis9 & (a3 == 3'd3),   // RWRITE0-3: byte b
	                     mis9 & (a3 == 3'd2), mis9 & (a3 == 3'd1)};
	localparam logic [31:0] RND0 = 32'h2B43_5044;
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			rnd <= RND0;
		else
			for (int b = 0; b < 4; b++)
				if (rnd_nx | rnd_pr | rnd_rs | rnd_wb[b])
					rnd[8*b +: 8] <= ({8{rnd_nx}} & rnd_next[8*b +: 8]) | ({8{rnd_pr}} & rnd_prior[8*b +: 8])
					               | ({8{rnd_rs}} & RND0[8*b +: 8]) | ({8{rnd_wb[b]}} & d_in);
	end

	// waveforms and NOTE (the audio's inputs)
	always_ff @(posedge clk_sys) begin
		if (rst_fe) begin
			wave[0]  <= 7'd0;
			wave[1]  <= 7'd0;
			wave[2]  <= 7'd0;
			note_stb <= 1'b0;
			note_v   <= 2'd0;
			note_val <= 8'h00;
		end else begin
			for (int v = 0; v < 3; v++)
				if (mis6 & (a3 == 3'(v + 5))) wave[v] <= d_in[6:0];
			note_stb <= mis9 & (a3 >= 3'd5);
			if (mis9 & (a3 >= 3'd5)) begin
				note_v   <= a_in[1:0] - 2'd1;
				note_val <= d_in;
			end
		end
	end
	assign wave0   = wave[0];
	assign wave1   = wave[1];
	assign wave2   = wave[2];
	assign cdf_dig = mode[7:4] == 4'h0;

	// call and DMA strobes (comb pulses at C)
	assign callfn  = commit & (opc.c.dcf | opc.c.ccall) & (d_in[7:1] == 7'h7F);
	assign dma_set = at_svc;

	// ---- the service latch (kind 2; 2.3, 7.3) ------------------------------------------------
	always_ff @(posedge clk_sys) begin
		if (rst_fe) begin
			svc_pend <= 1'b0;
			svc_fill <= 1'b0;
			svc_src  <= 17'd0;
			svc_dst  <= 13'd0;
			svc_rem  <= 8'h00;
			svc_val  <= 8'h00;
		end else if (act_svc) begin
			svc_pend <= 1'b1;
			svc_fill <= d_act == 8'd2;
			svc_src  <= 17'h00C00 + {1'b0, W[15:0]};             // $0C00 + {p1, p0}
			svc_dst  <= 13'h0C00 + {1'b0, cnt_st};               // $0C00 + counter[p2 & 7]
			svc_rem  <= W[31:24];                                 // p3, the requested count
			svc_val  <= W[7:0];                                   // p0
		end else if (svc_take)
			svc_pend <= 1'b0;
	end
	assign svc_hold = svc_pend | (pend_c == PC_SVC);

	// ---- kind 3: the S post write (2.3, 2.5's field rows) ------------------------------------
	logic [4:0] sw_a;                    // word $00-$10
	logic [3:0] sw_be;
	logic       sw_d;                    // 1: W; 0: din's lanes
	wire        s_par = opc.c.dpar & (pptr < 4'd4);              // a param 0-3 byte (4-7 never read)
	wire        s_set = commit & (opc.c.rdat | opc.c.dpw | opc.c.dfld | s_par);
	wire        s_w1  = opc.c.dfld & (opc.g <= 4'd2);              // FRACLOW, FRACHI, FRACINC: w1
	logic [3:0] be_fld;
	always_comb begin
		case (opc.g)
			4'd0:    be_fld = sf ? 4'b0011 : 4'b0010;                   // FRACLOW
			4'd1:    be_fld = 4'b0100;                                  // FRACHI
			4'd2:    be_fld = 4'b1001;                                  // FRACINC
			4'd3:    be_fld = 4'b0100;                                  // TOP
			4'd4:    be_fld = 4'b1000;                                  // BOTTOM
			4'd5:    be_fld = 4'b0001;                                  // LOW
			default: be_fld = 4'b0010;                                  // HI (g 8)
		endcase
	end
	wire        s_fire = pend_s & (!sw_d | rdW);
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			pend_s <= 1'b0;
		else if (s_set)
			pend_s <= 1'b1;
		else if (s_fire | pclk1)
			pend_s <= 1'b0;
		if (s_set) begin
			sw_a  <= ({5{opc.c.rdat}} & {1'b0, opc.ix, opc.fn == 3'd3})
			       | ({5{opc.c.dpw | opc.c.dfld}} & {1'b0, a3, s_w1})
			       | ({5{s_par}} & 5'h10);
			sw_be <= ({4{opc.c.rdat}} & ((opc.fn == 3'd3) ? 4'b0111 : 4'b0011))
			       | ({4{opc.c.dpw}} & 4'b0011)
			       | ({4{opc.c.dfld}} & be_fld)
			       | ({4{s_par}} & (4'b0001 << pptr[1:0]));
			sw_d  <= opc.c.rdat | opc.c.dpw;
		end
	end
	// din's lanes: lane 0 is $00 on w1 (FRACLOW with sf, FRACINC); lanes 1/2 take
	// d[3:0] on HI (w0) / FRACHI (w1); word $10 (params) takes din in every lane.
	wire        s_odd  = sw_a[0];
	wire        s_w10  = sw_a[4];
	wire [31:0] s_lane = {din, (s_odd ? {4'h0, din[3:0]} : din),
	                      ((!s_odd & !s_w10) ? {4'h0, din[3:0]} : din), (s_odd ? 8'h00 : din)};

	// ---- kind 3: the R post write (PUSH/WRITE's byte) ------------------------------------
	wire r_fire = pend_r & rdW;
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			pend_r <= 1'b0;
		else if (commit & opc.c.dpw)
			pend_r <= 1'b1;
		else if (r_fire | pclk1)
			pend_r <= 1'b0;
	end

	// ---- the pointer buffer (kind 2 for CDF fetch/jump; 3.4) -------------------------------
	wire wb_set_f = commit & (opc.c.cfet | opc.c.cjmp);
	wire wb_set_d = act_dsw | act_dsp;
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			wb_v <= 1'b0;
		else if (wb_set_f | wb_set_d)
			wb_v <= 1'b1;
		else if (wb_gnt)
			wb_v <= 1'b0;
		if (wb_set_f | wb_set_d)
			wb_a <= pb + (wb_set_f ? {3'b000, opc.idx} : 9'd32);
	end
	assign cr_wb    = wb_v & rdW;
	assign cr_wb_a  = {4'h0, wb_a};
	assign cr_wb_wd = W;

	// ---- R fixed (3.1, priority 1): reads in k[1..3], DSWRITE's byte, PUSH/WRITE's byte ------
	wire fx_ptr = k[1] & (dec.c.cfet | dec.c.cjmp);                 // pointer, pb + idx
	wire fx_dat = k[2] & (o_cfet | o_cjmp | o_rdat);                // data byte's word
	wire fx_inc = k[3] & o_cfet;                                    // increment, ib + idx
	wire fx_dsw = act_dsw;                                          // DSWRITE byte (C, or deferred)
	wire fx_pw  = r_fire;                                           // PUSH/WRITE byte
	assign cr_fix     = fx_ptr | fx_dat | fx_inc | fx_dsw | fx_pw;
	assign cr_fix_a   = ({13{fx_ptr}} & {4'h0, pb + {3'b000, dec.idx}})
	                  | ({13{fx_dat}} & data_addr[14:2])
	                  | ({13{fx_inc}} & {4'h0, ib + {3'b000, op_r.idx}})
	                  | ({13{fx_dsw}} & dsw_addr[14:2])
	                  | ({13{fx_pw}}  & {2'b00, ba[12:2]});
	assign cr_fix_we  = fx_dsw | fx_pw;
	assign cr_fix_be  = ({4{fx_dsw}} & (4'b0001 << dsw_addr[1:0])) | ({4{fx_pw}} & (4'b0001 << ba[1:0]));
	assign cr_fix_wd  = {4{d_act}};                                 // DSWRITE: d (din if deferred); PUSH/WRITE: din
	assign cr_fix_use = fx_ptr | fx_dat | fx_inc;

	// ---- S (3.2, DPC+ only): fetcher reads in k[1]/k[2], the post write --------------------
	wire       cs_rd1 = k[1] & (dec.c.rdat | dec.c.rflg | dec.c.dpw | dec.c.dcf);
	wire       cs_rd2 = k[2] & o_dcf;
	wire [2:0] cs_fx  = dec.c.dpw ? a3 : dec.ix;                    // writes index the fetcher by a_in[2:0]
	assign cs_req = cs_rd1 | cs_rd2 | s_fire;
	assign cs_a   = ({8{cs_rd1}}  & (dec.c.dcf ? 8'h10 : {4'h0, cs_fx, dec.c.rdat & (dec.fn == 3'd3)}))
	              | ({8{cs_rd2}}  & {4'h0, stb_q[18:16], 1'b0})     // w0[p2 & 7]
	              | ({8{s_fire}}  & {3'b000, sw_a});
	assign cs_we  = s_fire;
	assign cs_be  = s_fire ? sw_be : 4'hF;
	assign cs_wd  = sw_d ? W : s_lane;

	// ---- A: the CDF lookahead in k[0] (3.3) -----------------------------------------------------
	assign look_req = k[0] & is_cdf & !init_busy;
	assign look_a   = rom_a[14:2] + 13'd1;

	// ---- fe_do (2.4; D10: a register) ------------------------------------------------------------
	wire       fd_k1   = k[1] & ph1_open;                                   // @2
	wire       fd_flg  = k[2] & o_rflg & ph1_open;                          // @3
	wire       fd_ram  = k[3] & (o_rdat | o_cfet | o_cjmp) & ph1_open;      // @4
	wire       fd_amp  = op_r.c.amp & ph1_open & !k[0] & !k[1];             // @3 ... C-1, every edge
	wire       use_amp = (fd_k1 & dec.c.amp) | fd_amp;
	logic [7:0] rbyte;                                                      // rnd_byte(dec.ix)
	always_comb begin
		case (dec.ix)
			3'd0:    rbyte = rnd_next[7:0];
			3'd1:    rbyte = rnd_prior[7:0];
			3'd2:    rbyte = rnd[15:8];
			3'd3:    rbyte = rnd[23:16];
			3'd4:    rbyte = rnd[31:24];
			default: rbyte = 8'h00;
		endcase
	end
	wire [7:0] k1b  = dec.c.rrnd ? rbyte : romb;
	wire [7:0] flg  = {8{(op_r.ix < 3'd4) & win}};
	wire [7:0] ramb = crb_q[8*cl +: 8] & ((is_dpc & (op_r.fn == 3'd2)) ? {8{wf}} : 8'hFF);
	always_ff @(posedge clk_sys) begin
		if (rst_fe)
			fe_do <= 8'h00;
		else if (fd_k1 | fd_flg | fd_ram | fd_amp)
			fe_do <= ({8{fd_k1 & !dec.c.amp}} & k1b) | ({8{fd_flg}} & flg) | ({8{fd_ram}} & ramb)
			       | ({8{use_amp}} & amp_nx);
	end

	// ---- events and assertions (1.7, 9.6) --------------------------------------------------------
	// rcyc: this 6507 cycle ran some of its k reads under rst_fe, i.e. some edge
	// since the last pclk1 (that pclk1's own edge excluded) had rst_fe high.
	// Cleared at every pclk1 edge, whatever rst_fe is (the edge that starts a
	// cycle), set at any other edge with rst_fe high. Only a_pend_late reads it
	// (synthesis removes both): the cycle in which rst_fe falls may commit an
	// action whose ready flag was held at 0, and that action is dropped at
	// pclk1 (docs/daria_fe/lanes/F1_fixes.md, 1).
	logic       rcyc;
	always_ff @(posedge clk_sys) begin
		if (pclk1)       rcyc <= 1'b0;
		else if (rst_fe) rcyc <= 1'b1;
	end
	assign ev_guard_sup = guard_on & (cr_fix | cr_p32);
	assign ev_tbl_alias = act_dsw & jplus & (dsw_addr >= 15'h0098) & (dsw_addr < 15'h01B0);
	assign ev_rmw_svc   = dma_set & dma_busy;
	assign a_fpjr       = is_cdf & fpend & (jr != 2'd0);
	assign a_pend_late  = pclk1 & !rcyc & ((pend_c != PC_NONE) | pend_s | pend_r);
endmodule

`default_nettype wire
