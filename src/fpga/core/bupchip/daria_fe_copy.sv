//------------------------------------------------------------------------------
// DARIA front end: load tracking, F6 (the RAM image and the state-RAM
// clear), init_busy, the DPC+ copy/fill engine and arm_dma_busy
// (docs/daria_fe/design.md 7, D6, D7). Reset: cart_reset and load_start for
// the engine; the load tracking is not reset by cart_reset.
//
// Load tracking (7.1). The family (DPC+, or CDF with ram32) is latched one
// clock after load_end, as upstream's ram_init latches it on load_end_d.
// F6 starts at the fall of cart_win (bup_capture's c_close: the capture
// takes no byte from then on), or 8 clocks after a rising cart_reset with
// an ARM image loaded and no init running (never on a falling one; a rise
// while init_busy is ignored). load_start aborts F6 and the engine.
// init_busy rises at load_start or at that reset rise and falls at F6's
// end, or one clock after load_end for an image that is not DPC+ or CDF
// (upstream's busy falls on that same edge).
//
// F6 (7.2): exclusive ports, one word per clock, a single counter f6_i:
//   CLR  state RAM words $00-$1F <- 0                 (f6_i 0..$1F)
//   P1   DPC+: fill cart RAM words $000-$2FF <- 0      (f6_i 0..$2FF)
//        CDF:  copy FE ROM words $000-$1FF -> cart RAM $000-$1FF
//   P2   DPC+: copy FE ROM words $1B00-$1FFF -> cart RAM $300-$7FF
//              (f6_i $300..$7FF, the ROM word f6_i | $1800)
//        CDF:  fill cart RAM $200-$7FF <- 0 ($200-$1FFF with ram32)
//   END  the last copy write, then f6_done: init_busy falls
// A copy reads FE ROM word f6_i in one clock and writes its q at the next
// (f6_v, f6_wa); a fill that follows a copy waits that one write.
// 2,082 clocks for DPC+ and CDF 8 KB, 8,226 for CDFJ+.
//
// The engine (7.3): a latched service is taken when the engine is idle and
// no init runs (svc_take, upstream's accept at C+1). The count is clamped
// at run time exactly as upstream's min(): it stops at rem = 0, at dst =
// $1C00 (dest_avail = $1000 - counter) and, for a copy, at src = $8000
// (src_avail = $7400 - offset, 0 if the offset >= $7400). A fill writes a
// word per granted clock with the byte lanes [dst, min(dst + rem, word
// end)); a copy writes one byte per granted clock from FE ROM port A
// (av_q: the word in fea_q is src's), with one bubble per word crossing.
// The requests reach u_arb raw: the engine yields to every other cart RAM
// user (priority 5) and writes nothing under guard_on, both by cp_gnt.
//
// arm_dma_busy (7.4): set at C by dma_set, held while a latch is pending
// (svc_hold) or the engine runs, falls only on rel_ok; 0 during init.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_copy (
	input  wire         clk_sys,
	input  wire         cart_reset,
	input  wire         load_start,   // one-clock pulse
	input  wire         load_end,     // one-clock pulse
	input  wire         cart_win,     // bup_capture's window; its fall is c_close
	input  wire         is_dpc,
	input  wire         is_cdf,
	input  wire         ram32,
	input  wire         rel_ok,       // from u_seq
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire         guard_on,     // no rule reads it: cp_gnt holds !guard_on (interfaces.md 10 item 3)
	/* verilator lint_on UNUSEDSIGNAL */
	// the latched service (u_core)
	input  wire         svc_pend,
	input  wire         svc_hold,
	input  wire         svc_fill,
	input  wire  [16:0] svc_src,
	input  wire  [12:0] svc_dst,
	input  wire   [7:0] svc_rem,
	input  wire   [7:0] svc_val,
	input  wire         dma_set,      // comb pulse at C
	// out
	output logic        svc_take,     // pulse
	output logic        init_busy,    // reg
	output logic        arm_dma_busy, // reg
	output logic        f6_act,       // reg
	output logic        rst_quiet,    // reg: cart_reset high for >= 8 clocks
	// R
	output logic        cp_req,
	output logic [12:0] cp_a,
	output logic        cp_we,
	output logic  [3:0] cp_be,
	output logic [31:0] cp_wd,
	input  wire         cp_gnt,
	// S (F6 clear: we = 1, be = F, data 0)
	output logic        cz_req,
	output logic  [7:0] cz_a,
	// A
	output logic        ca_req,
	output logic [12:0] ca_a,
	input  wire         ca_gnt,
	input  wire  [31:0] fea_q
);
	localparam int P_CLR = daria_fe_pkg::F6_CLR;
	localparam int P_P1  = daria_fe_pkg::F6_P1;
	localparam int P_P2  = daria_fe_pkg::F6_P2;
	localparam int P_END = daria_fe_pkg::F6_END;

	// ---- registers (power-up values; the bench taps of 1.7 keep their names) ----
	/* verilator lint_off PROCASSINIT */          // the repository's power-up idiom
	logic        loading   = 1'b0;                // a download is in progress
	logic        fe_loaded = 1'b0;                // the last image is DPC+ or CDF (upstream's image_loaded)
	logic        ld1       = 1'b0;                // load_end + 1: scheme and ram32 valid
	logic        f6_dpc    = 1'b0;                // the family latched at load
	logic        f6_r32    = 1'b0;                // and its RAM size (CDFJ+)
	logic        cw_q      = 1'b0;
	logic        rst_q     = 1'b0;
	logic  [2:0] qcnt      = 3'd0;                // cart_reset clocks, saturating at 7
	logic        quiet_q   = 1'b0;                // rst_quiet
	logic  [3:0] rdl       = 4'd0;                // the reset rise's delay, 8 down to 1
	logic        ib_q      = 1'b0;                // init_busy
	logic        f6_q      = 1'b0;                // f6_act
	logic  [3:0] f6_ph     = 4'd0;                // tap: one-hot while f6_act (F6_*), else 0
	logic [12:0] f6_i      = 13'd0;               // the phase's word (CLR, fill) or ROM read (copy)
	logic [10:0] f6_wa     = 11'd0;               // the copy word whose q is in fea_q
	logic        f6_v      = 1'b0;                // fea_q holds a copy word: write it in this clock
	logic        run       = 1'b0;                // tap: the engine runs a service
	logic        fill      = 1'b0;                // tap
	logic [16:0] src       = 17'd0;               // tap: image byte offset ($0C00 + {p1, p0})
	logic [12:0] dst       = 13'd0;               // tap: cart RAM byte address ($0C00 + counter)
	logic  [7:0] rem       = 8'h00;               // tap: bytes still requested (p3)
	logic  [7:0] val       = 8'h00;               // tap: the fill byte (p0)
	logic        av_q      = 1'b0;                // fea_q holds src's word in this clock
	logic        dma_busy  = 1'b0;                // tap: arm_dma_busy is its port
	/* verilator lint_on PROCASSINIT */

	/* verilator lint_off UNUSEDSIGNAL */
	logic        a_f6_live;                       // assertion: F6 runs only while rst_quiet (must be 0)
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- load tracking and triggers (7.1) ---------------------------------------------
	wire rst_rise = cart_reset & !rst_q & fe_loaded & !ib_q;    // never on a falling reset
	wire win_fall = cw_q & !cart_win & fe_loaded;                // c_close
	wire f6_go    = (win_fall | (rdl == 4'd1)) & !load_start;

	// ---- F6 sequencer (7.2) --------------------------------------------------------------
	wire ph_clr  = f6_ph[P_CLR];
	wire ph_p1   = f6_ph[P_P1];
	wire ph_p2   = f6_ph[P_P2];
	wire ph_end  = f6_ph[P_END];
	wire in_copy = (ph_p1 & !f6_dpc) | (ph_p2 & f6_dpc);         // a ROM word read in every clock
	wire in_fill = (ph_p1 & f6_dpc) | (ph_p2 & !f6_dpc);
	wire fw      = in_fill & !f6_v;                              // a zero word in this clock
	wire f6_adv  = ph_clr | in_copy | fw;
	wire clr_lst = ph_clr & (f6_i[4:0] == 5'h1F);
	wire p1_lst  = ph_p1 & f6_adv & (f6_i == (f6_dpc ? 13'h02FF : 13'h01FF));
	wire p2_lst  = ph_p2 & f6_adv & (f6_i == ((f6_r32 & !f6_dpc) ? 13'h1FFF : 13'h07FF));
	wire f6_done = ph_end & !f6_v;

	always_ff @(posedge clk_sys) begin
		if (load_start)    loading <= 1'b1;
		else if (load_end) loading <= 1'b0;
		ld1 <= load_end & loading;
		if (load_start)    fe_loaded <= 1'b0;
		else if (ld1)      fe_loaded <= is_dpc | is_cdf;
		if (ld1) begin
			f6_dpc <= is_dpc;
			f6_r32 <= ram32;
		end
		cw_q    <= cart_win;
		rst_q   <= cart_reset;
		qcnt    <= cart_reset ? (qcnt + {2'b00, qcnt != 3'd7}) : 3'd0;
		quiet_q <= cart_reset & (qcnt == 3'd7);

		if (load_start)        rdl <= 4'd0;
		else if (rst_rise)     rdl <= 4'd8;
		else if (rdl != 4'd0)  rdl <= rdl - 4'd1;

		// init_busy (D6): from load_start or the reset rise through F6's end, never dipping
		if (load_start | rst_rise)                         ib_q <= 1'b1;
		else if (f6_done | (ld1 & !(is_dpc | is_cdf)))     ib_q <= 1'b0;   // not an ARM image: no F6

		if (load_start | f6_done)  f6_q <= 1'b0;
		else if (f6_go)            f6_q <= 1'b1;

		if (load_start) f6_ph <= 4'd0;
		else begin
			if (f6_go | clr_lst)          f6_ph[P_CLR] <= f6_go;
			if (clr_lst | p1_lst)         f6_ph[P_P1]  <= clr_lst;
			if (p1_lst | p2_lst)          f6_ph[P_P2]  <= p1_lst;
			if (p2_lst | f6_done)         f6_ph[P_END] <= p2_lst;
		end

		if (f6_go | clr_lst)  f6_i <= 13'd0;
		else if (f6_adv)      f6_i <= f6_i + 13'd1;
		f6_wa <= f6_i[10:0];
		f6_v  <= in_copy & !load_start;
	end

	// ---- the engine (7.3) -----------------------------------------------------------------
	wire       take  = svc_pend & !run & !ib_q & !f6_q & !load_start & !cart_reset;
	wire       stop  = (rem == 8'd0) | (dst == 13'h1C00) | (!fill & (src[16:15] != 2'b00));
	wire       e_go  = run & !stop;
	wire [1:0] d     = dst[1:0];
	wire       r2    = rem > 8'd1;
	wire       r3    = rem > 8'd2;
	wire       r4    = rem > 8'd3;
	// the fill's byte lanes: from d to the word's end, at most rem of them (rem > 0 here)
	wire [3:0] fbe;
	assign fbe[0] = d == 2'd0;
	assign fbe[1] = (d == 2'd1) | ((d == 2'd0) & r2);
	assign fbe[2] = (d == 2'd2) | ((d == 2'd1) & r2) | ((d == 2'd0) & r3);
	assign fbe[3] = (d == 2'd3) | ((d == 2'd2) & r2) | ((d == 2'd1) & r3) | ((d == 2'd0) & r4);
	wire [2:0] fadv  = {2'b00, fbe[0]} + {2'b00, fbe[1]} + {2'b00, fbe[2]} + {2'b00, fbe[3]};
	wire [2:0] adv   = fill ? fadv : 3'd1;
	wire       e_fl  = e_go & fill;                  // a fill word
	wire       e_cr  = e_go & !fill;                 // a copy: the source word is read every clock
	wire       e_cp  = e_cr & av_q;                  // a copy byte, its word in fea_q
	wire       e_wr  = cp_gnt & (e_fl | e_cp);       // the engine's write registers at this edge
	wire [1:0] d_src = src[1:0];
	wire [7:0] cbyte = fea_q[{d_src, 3'b000} +: 8];

	always_ff @(posedge clk_sys) begin
		if (cart_reset | load_start)  run <= 1'b0;
		else if (take)                run <= 1'b1;
		else if (run & stop)          run <= 1'b0;
		if (take) begin
			fill <= svc_fill;
			val  <= svc_val;
		end
		if (take)                     src <= svc_src;
		else if (e_wr & !fill)        src <= src + 17'd1;
		if (take)                     dst <= svc_dst;
		else if (e_wr)                dst <= dst + {10'd0, adv};
		if (take)                     rem <= svc_rem;
		else if (e_wr)                rem <= rem - {5'd0, adv};
		av_q <= ca_gnt & e_cr & !(e_wr & (d_src == 2'b11));

		// arm_dma_busy (7.4, D3)
		if (cart_reset | ib_q)                              dma_busy <= 1'b0;   // forced 0 during init (R2)
		else if (dma_set)                                   dma_busy <= 1'b1;   // at C, a taken 1/2
		else if (dma_busy & !svc_hold & !run & rel_ok)      dma_busy <= 1'b0;   // only while in_phase2
	end

	// ---- ports (AND-OR on one-hot selects) ------------------------------------------------
	wire sel_cw = f6_v;                              // F6: the copied word
	wire sel_fw = fw;                                // F6: a zero word
	wire sel_eg = e_fl | e_cp;                       // the engine

	assign svc_take = take;
	assign cp_req   = sel_cw | sel_fw | sel_eg;
	assign cp_we    = 1'b1;                          // every request of this block is a write
	assign cp_a     = ({13{sel_cw}} & {2'b00, f6_wa})
	                | ({13{sel_fw}} & f6_i)
	                | ({13{sel_eg}} & {2'b00, dst[12:2]});
	assign cp_be    = ({4{sel_cw | sel_fw}} & 4'hF)
	                | ({4{e_fl}}            & fbe)
	                | ({4{e_cp}}            & (4'b0001 << d));
	assign cp_wd    = ({32{sel_cw}} & fea_q)
	                | ({32{e_fl}}   & {4{val}})
	                | ({32{e_cp}}   & {4{cbyte}});
	assign cz_req   = ph_clr;
	assign cz_a     = {3'b000, f6_i[4:0]};
	assign ca_req   = in_copy | e_cr;
	assign ca_a     = ({13{in_copy}} & (f6_i | {f6_dpc, f6_dpc, 11'd0}))
	                | ({13{e_cr}}    & src[14:2]);

	assign init_busy    = ib_q;
	assign f6_act       = f6_q;
	assign rst_quiet    = quiet_q;
	assign arm_dma_busy = dma_busy;
	assign a_f6_live    = f6_q & !quiet_q;
endmodule

`default_nettype wire
