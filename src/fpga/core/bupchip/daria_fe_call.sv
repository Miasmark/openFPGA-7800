//------------------------------------------------------------------------------
// DARIA front end: the call side (docs/daria_fe/design.md 6, D5). It posts
// the call block F0-F7 into the state RAM, flips call_tog, reads the
// returns F8-FD after the synchronised ret_tog change, drives the ring
// strobes of u_audio, and releases the stall (arm_call_busy) on rel_ok &
// cpu_ready. Reset: cart_reset (call_tog keeps its value).
//
// The FSM is one-hot (st, daria_fe_pkg::CS_*): IDLE, POST, FLIP, RUN, RD,
// RDW, APPLY, HKW, REL. Edges as design 6.2-6.4 (C the commit, L = C+1,
// X the edge RUN is left, M = X+1, M_fe = X+7):
//
//   C        callfn: call_busy, POST, cap1 (cp_cap in (C, C+1): the ring
//            takes the payload at L)
//   C+1..+8  F0, F1, then F2-F7 = ring0 while cp_rot rotates the ring; the
//            last write flips call_tog if cpu_ready, else FLIP waits for it
//   (S2, X)  CDF: F8 presented in the clock the synchronised ret_tog change
//            is first seen (ret_new); X is the edge that registers it
//   X+1..+5  F9-FD (six consecutive reads); cp_shin X+1..X+6, cp_cmp
//            X+1..X+3; mwin (X+1, X+2)..(X+6, X+7); cp_apply at X+7
//   then     REL: call_busy falls at the first edge with rel_ok & cpu_ready
//
// DPC+ reads nothing (it never merges): RUN goes to REL at X, or to POST
// for a pending second call (cp_cap at M = X+1). Hook (hk_en, bench only):
// RUN -> HKW for one clock, no reads, no mwin. A CALLFN committed while
// busy sets pend2 once (the RMW pair, 6.4). Upstream accepts that call at
// max(M, C2+1): a CALLFN committed by X (p2e) is posted with the payload
// at M (DPC+, hook) or at M_fe with cp_apply (CDF: the pre-merge values,
// 6.4). One committed after X (the RMW's second write held past X by a
// pause in its phase 1, which DARIA's CPU runs through) is upstream's new
// call after the merge: it waits for REL, which posts it like a fresh
// call (cap1), as it does a CALLFN committed in REL itself (C2+1 there:
// exact). Design 6.1's REL ignored pend2: such a call was lost and pend2
// left set for a phantom call after the next return.
//
// The returns are read only once the F8 read is granted (in CDF it always
// is: the core uses state RAM only in DPC+, and F6 never meets a call).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_call (
	input  wire         clk_sys,
	input  wire         cart_reset,
	input  wire         is_dpc,
	input  wire         is_cdf,
	input  wire         jplus,
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire  [31:0] cdfj_entry,   // bit 0 is the T bit, always set (detect2600 clears it)
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire  [31:0] cdfj_stack,
	input  wire         callfn,       // comb pulse at C, from u_core
	input  wire         cpu_ready,
	input  wire         ret_tog,      // clk_arm domain: two clk_sys flops inside (the first FORCED)
	input  wire         rel_ok,       // from u_seq
	input  wire  [31:0] ring0,        // from u_audio
	input  wire         hk_en,        // bench hook; tied 0 in synthesis
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire         hk_stb,       // no rule reads it (interfaces.md 10 item 3, L-3)
	/* verilator lint_on UNUSEDSIGNAL */
	// S
	output logic        cl_req,
	output logic  [7:0] cl_a,
	output logic        cl_we,
	output logic [31:0] cl_wd,        // be = F
	input  wire         cl_gnt,
	// audio
	output logic        cp_cap,       // pulse
	output logic        cp_rot,       // pulse
	output logic        cp_shin,      // pulse
	output logic        cp_cmp,       // pulse
	output logic        cp_apply,     // pulse
	output logic        mwin,         // level
	// out
	output logic        call_tog,     // reg
	output logic        arm_call_busy,// reg
	output logic        call_win      // comb from the state: RUN | RD | RDW | APPLY | HKW
);
	localparam int I_IDLE  = daria_fe_pkg::CS_IDLE;
	localparam int I_POST  = daria_fe_pkg::CS_POST;
	localparam int I_FLIP  = daria_fe_pkg::CS_FLIP;
	localparam int I_RUN   = daria_fe_pkg::CS_RUN;
	localparam int I_RD    = daria_fe_pkg::CS_RD;
	localparam int I_RDW   = daria_fe_pkg::CS_RDW;
	localparam int I_APPLY = daria_fe_pkg::CS_APPLY;
	localparam int I_HKW   = daria_fe_pkg::CS_HKW;
	localparam int I_REL   = daria_fe_pkg::CS_REL;

	// ---- registers (power-up values; the bench taps of 1.4/1.7 keep their names) ----
	/* verilator lint_off PROCASSINIT */          // the repository's power-up idiom
	logic  [8:0] st        = 9'd1 << I_IDLE;      // tap: one-hot, CS_*
	logic  [7:0] cnum      = 8'h00;               // tap: call_tog flips so far
	logic        pend2     = 1'b0;                // tap: a second CALLFN while busy (one deep)
	logic        pend_up   = 1'b0;                // tap: upstream's call_pending as it would read
	logic        ret_seen  = 1'b0;                // tap: the ret_tog value consumed
	logic        call_busy = 1'b0;                // tap: arm_call_busy is its port
	logic  [2:0] idx       = 3'd0;                // word index: F0+idx (POST), F8+idx (RD)
	logic        cap1      = 1'b0;                // cp_cap in the first clock of a POST
	logic        p2e       = 1'b0;                // pend2 was committed by X (upstream accepts it at M)
	logic        tog_q     = 1'b0;                // call_tog
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic        ret_s1    = 1'b0;
	logic        ret_s2    = 1'b0;
	logic        xq        = 1'b0;                // the clock after X (upstream accepts call 2 at X+1)
	logic        rd_q      = 1'b0;                // stb_q holds a return word in this clock
	/* verilator lint_on PROCASSINIT */

	// ---- bench-only events (1.7; one-clock pulses) -------------------------------
	/* verilator lint_off UNUSEDSIGNAL */
	logic        ev_rmw_call;                     // a CALLFN while call_busy (class rmw_call)
	logic        ev_ret_unasked;                  // a ret_tog change outside RUN, outside reset (must be 0)
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- next state ----------------------------------------------------------------
	wire s_idle  = st[I_IDLE];
	wire s_post  = st[I_POST];
	wire s_flip  = st[I_FLIP];
	wire s_run   = st[I_RUN];
	wire s_rd    = st[I_RD];
	wire s_rdw   = st[I_RDW];
	wire s_apply = st[I_APPLY];
	wire s_hkw   = st[I_HKW];
	wire s_rel   = st[I_REL];

	wire ret_new = ret_s2 ^ ret_seen;            // the synchronised change, first seen in this clock
	wire rd_need = is_cdf & !hk_en;              // a CDF call reads its returns
	wire f8_rd   = s_run & ret_new & rd_need;     // F8 presented in that very clock
	wire leave   = s_run & ret_new & (cl_gnt | !rd_need);   // this edge is X
	wire start   = callfn & !call_busy;          // at C (IDLE)
	wire p_last  = s_post & cl_gnt & (idx == 3'd7);
	wire flip    = (p_last | s_flip) & cpu_ready & !cart_reset;
	wire r_last  = s_rd & cl_gnt & (idx == 3'd5);
	wire nxt_dpc = leave & is_dpc;
	wire nxt_hk  = leave & !is_dpc & hk_en;
	wire nxt_rd  = leave & !is_dpc & !hk_en;
	wire in_x    = s_rd | s_rdw | s_apply | s_hkw; // after X, before REL
	wire p2_set  = callfn & call_busy & !pend2 & !pend_up & !s_rel;   // upstream ignores it while call_pending
	wire p2_now  = pend2 | p2_set;               // pending at X (DPC+ leaves RUN in this clock)
	wire rel_go  = s_rel & (pend2 | callfn);     // a call committed after X: post it now
	wire rel_end = s_rel & !pend2 & !callfn & rel_ok & cpu_ready;
	wire mrg_end = s_apply | s_hkw;              // M_fe (CDF) or M (hook)
	wire mrg_go  = mrg_end & pend2 & p2e;        // the second call's payload: pre-merge (6.4)
	wire again   = (nxt_dpc & p2_now) | mrg_go | rel_go;   // the pending call's POST starts
	wire ld_post = start | again;

	logic [8:0] st_n;
	always_comb begin
		st_n          = 9'd0;
		st_n[I_IDLE]  = (s_idle & !start) | rel_end;
		st_n[I_POST]  = ld_post | (s_post & !p_last);
		st_n[I_FLIP]  = (p_last | s_flip) & !cpu_ready;
		st_n[I_RUN]   = ((p_last | s_flip) & cpu_ready) | (s_run & !leave);
		st_n[I_RD]    = nxt_rd | (s_rd & !r_last);
		st_n[I_RDW]   = r_last;
		st_n[I_APPLY] = s_rdw;
		st_n[I_HKW]   = nxt_hk;
		st_n[I_REL]   = (nxt_dpc & !p2_now) | (mrg_end & !mrg_go) | (s_rel & !rel_go & !rel_end);
	end

	always_ff @(posedge clk_sys) begin
		ret_s1 <= ret_tog;
		ret_s2 <= ret_s1;
		xq     <= leave & !cart_reset;
		rd_q   <= cl_gnt & (s_rd | f8_rd) & !cart_reset;
		cap1   <= !cart_reset & (start | (nxt_dpc & p2_now) | rel_go);
		st     <= cart_reset ? (9'd1 << I_IDLE) : st_n;

		// idx: 0 at a POST's start, 1 after F8 (read in RUN), +1 per granted word
		if (ld_post)                       idx <= 3'd0;
		else if (nxt_rd)                   idx <= 3'd1;
		else if ((s_post | s_rd) & cl_gnt) idx <= idx + 3'd1;

		if (cart_reset)                    call_busy <= 1'b0;
		else if (start | rel_end)          call_busy <= start;

		if (cart_reset | again)            pend2 <= 1'b0;
		else if (p2_set)                   pend2 <= 1'b1;
		if (p2_set)                        p2e <= !in_x;

		// upstream's call_pending: set by a CALLFN while its call runs, cleared at X+1; one
		// committed after X it accepts at once (no pending clock after the cycle)
		if (cart_reset)                    pend_up <= 1'b0;
		else if (p2_set & !in_x)           pend_up <= 1'b1;
		else if (xq)                       pend_up <= 1'b0;

		if (cart_reset | (ret_new & (!s_run | leave)))
			ret_seen <= ret_s2;

		if (flip) begin
			tog_q <= ~tog_q;
			cnum  <= cnum + 8'd1;
		end
	end

	// ---- S port: posts F0-F7, return reads F8-FD (priority 2 on S, 3.2) -------------
	wire [31:0] f0 = ({32{is_dpc}}          & 32'h0000_0C09)
	               | ({32{!is_dpc & !jplus}} & 32'h0000_0809)
	               | ({32{jplus}}            & {cdfj_entry[31:1], 1'b1});
	wire [31:0] f1 = ({32{jplus}}  & cdfj_stack)
	               | ({32{!jplus}} & 32'h4000_1FFC);
	wire        w0 = idx == 3'd0;
	wire        w1 = idx == 3'd1;
	wire        wr = idx[2] | idx[1];             // F2-F7: ring[0], rotating

	assign cl_req = s_post | s_rd | f8_rd;
	assign cl_we  = s_post;
	assign cl_a   = {4'hF, !s_post, idx};          // F0+idx while posting, F8+idx while reading
	assign cl_wd  = ({32{w0}} & f0) | ({32{w1}} & f1) | ({32{wr}} & ring0);

	// ---- strobes to u_audio (5.6) ------------------------------------------------------
	assign cp_cap   = cap1 | mrg_go;
	assign cp_rot   = s_post & cl_gnt & wr;
	assign cp_shin  = rd_q;
	assign cp_cmp   = rd_q & !idx[2] & (idx[1] | idx[0]);  // F8-FA: ring[0] is the matching seed
	assign cp_apply = s_apply & is_cdf;
	assign mwin     = is_cdf & !hk_en & ((s_rd & (idx != 3'd1)) | s_rdw | s_apply);

	assign call_win      = s_run | s_rd | s_rdw | s_apply | s_hkw;
	assign call_tog      = tog_q;
	assign arm_call_busy = call_busy;

	assign ev_rmw_call    = callfn & call_busy;
	assign ev_ret_unasked = ret_new & !s_run & !cart_reset;
endmodule

`default_nettype wire
