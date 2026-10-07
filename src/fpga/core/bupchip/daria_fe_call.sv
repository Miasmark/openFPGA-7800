//------------------------------------------------------------------------------
// DARIA front end: the call side (docs/daria_fe/design.md 6, D5). It posts
// the call block F0-F7 into the state RAM, flips call_tog, reads the
// returns F8-FD after the synchronised ret_tog change, drives the ring
// strobes of u_audio, and releases the stall (arm_call_busy) on rel_ok &
// cpu_ready. Reset: cart_reset (call_tog keeps its value).
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.4/1.7 (declared
// here so that the tap names exist). Lane C fills the body.
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
	input  wire  [31:0] cdfj_entry,
	input  wire  [31:0] cdfj_stack,
	input  wire         callfn,       // comb pulse at C, from u_core
	input  wire         cpu_ready,
	input  wire         ret_tog,      // clk_arm domain: two clk_sys flops inside (the first FORCED)
	input  wire         rel_ok,       // from u_seq
	input  wire  [31:0] ring0,        // from u_audio
	input  wire         hk_en,        // bench hook; tied 0 in synthesis
	input  wire         hk_stb,
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
	// ---- bench taps (design 1.4, 1.7; frozen names; daria_fe_pkg::CS_* for st) --
	logic  [8:0] st;                  // one-hot
	logic  [7:0] cnum;
	logic        pend2;
	logic        pend_up;
	logic        ret_seen;
	logic        call_busy;
	logic        ev_rmw_call;
	logic        ev_ret_unasked;

	assign st             = 9'd0;     // stub
	assign cnum           = 8'h00;    // stub
	assign pend2          = 1'b0;     // stub
	assign pend_up        = 1'b0;     // stub
	assign ret_seen       = 1'b0;     // stub
	assign call_busy      = 1'b0;     // stub
	assign ev_rmw_call    = 1'b0;     // stub
	assign ev_ret_unasked = 1'b0;     // stub

	assign cl_req         = 1'b0;     // stub
	assign cl_a           = 8'h00;    // stub
	assign cl_we          = 1'b0;     // stub
	assign cl_wd          = 32'd0;    // stub
	assign cp_cap         = 1'b0;     // stub
	assign cp_rot         = 1'b0;     // stub
	assign cp_shin        = 1'b0;     // stub
	assign cp_cmp         = 1'b0;     // stub
	assign cp_apply       = 1'b0;     // stub
	assign mwin           = 1'b0;     // stub
	assign call_tog       = 1'b0;     // stub
	assign arm_call_busy  = 1'b0;     // stub
	assign call_win       = 1'b0;     // stub
endmodule

`default_nettype wire
