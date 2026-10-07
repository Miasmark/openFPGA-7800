//------------------------------------------------------------------------------
// DARIA front end: the 6507 side of DPC+ and of the CDF family
// (docs/daria_fe/design.md 2.2-2.6): the mirror address and the op latch, W
// and its adder, fe_do, the scheme state, the commit actions under the ready
// rule (2.3), the pointer buffer, the P32 read, the service latch, and the
// NOTE/waveform/mode outputs to the audio. It holds u_dec.
// Reset: rst_fe (1.5 rule 7).
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.7 (declared here
// so that the tap names exist). Lane A fills the body.
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
	input  wire   [7:0] k,
	input  wire   [3:0] c,
	input  wire         commit,
	input  wire         ph1_open,
	input  wire         ev_short,
	// M10K q
	input  wire  [31:0] fea_q,
	input  wire  [31:0] feb_q,
	input  wire  [31:0] crb_q,
	input  wire  [31:0] stb_q,
	// arb
	input  wire         aud_take,
	input  wire         look_gnt,
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
	input  wire         call_busy,    // u_call's arm_call_busy
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
	// ---- the decode -----------------------------------------------------------------
	daria_fe_pkg::dec_t dec;
	logic [14:0] rom_a;
	logic  [7:0] romb;

	// ---- bench taps (design 1.7; frozen names) --------------------------------------
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
	assign feb_addr = rom_a[14:2];      // stub (rom_a is the stub decode's 0)
	assign romb     = 8'h00;            // stub

	assign bank         = 3'd0;         // stub
	assign fpend        = 1'b0;         // stub
	assign W            = 32'd0;        // stub
	assign wb_a         = 9'd0;         // stub
	assign p32_in       = 1'b0;         // stub
	assign pend_s       = 1'b0;         // stub
	assign pend_r       = 1'b0;         // stub
	assign pend_c       = 2'd0;         // stub
	assign rdW          = 1'b0;         // stub
	assign rdS          = 1'b0;         // stub
	assign ff_en        = 1'b0;         // stub
	assign rnd          = 32'd0;        // stub
	assign pptr         = 4'd0;         // stub
	assign wave[0]      = 7'd0;         // stub
	assign wave[1]      = 7'd0;         // stub
	assign wave[2]      = 7'd0;         // stub
	assign mode         = 8'h00;        // stub
	assign fexp         = 13'd0;        // stub
	assign jr           = 2'd0;         // stub
	assign jexp         = 13'd0;        // stub
	assign jstream      = 6'd0;         // stub
	assign ev_tbl_alias = 1'b0;         // stub
	assign ev_rmw_svc   = 1'b0;         // stub
	assign a_fpjr       = 1'b0;         // stub
	assign a_pend_late  = 1'b0;         // stub

	assign fe_do        = 8'h00;        // stub
	assign cr_fix       = 1'b0;         // stub
	assign cr_fix_a     = 13'd0;        // stub
	assign cr_fix_we    = 1'b0;         // stub
	assign cr_fix_be    = 4'h0;         // stub
	assign cr_fix_wd    = 32'd0;        // stub
	assign cr_fix_use   = 1'b0;         // stub
	assign cr_p32       = 1'b0;         // stub
	assign cr_p32_a     = 13'd0;        // stub
	assign cr_wb        = 1'b0;         // stub
	assign cr_wb_a      = 13'd0;        // stub
	assign cr_wb_wd     = 32'd0;        // stub
	assign cs_req       = 1'b0;         // stub
	assign cs_a         = 8'h00;        // stub
	assign cs_we        = 1'b0;         // stub
	assign cs_be        = 4'h0;         // stub
	assign cs_wd        = 32'd0;        // stub
	assign look_req     = 1'b0;         // stub
	assign look_a       = 13'd0;        // stub
	assign wave0        = 7'd0;         // stub
	assign wave1        = 7'd0;         // stub
	assign wave2        = 7'd0;         // stub
	assign note_stb     = 1'b0;         // stub
	assign note_v       = 2'd0;         // stub
	assign note_val     = 8'h00;        // stub
	assign cdf_dig      = 1'b0;         // stub
	assign callfn       = 1'b0;         // stub
	assign svc_pend     = 1'b0;         // stub
	assign svc_hold     = 1'b0;         // stub
	assign svc_fill     = 1'b0;         // stub
	assign svc_src      = 17'd0;        // stub
	assign svc_dst      = 13'd0;        // stub
	assign svc_rem      = 8'h00;        // stub
	assign svc_val      = 8'h00;        // stub
	assign dma_set      = 1'b0;         // stub
	assign op           = '0;           // stub
	assign p32_q        = 1'b0;         // stub
	assign rdP          = 1'b0;         // stub
	assign wb_v         = 1'b0;         // stub
	assign ev_guard_sup = 1'b0;         // stub
endmodule

`default_nettype wire
