//------------------------------------------------------------------------------
// DARIA front end: load tracking, F6 (the RAM image and the state-RAM
// clear), init_busy, the DPC+ copy/fill engine and arm_dma_busy
// (docs/daria_fe/design.md 7, D6, D7). Reset: cart_reset and load_start for
// the engine; the load tracking is not reset by cart_reset.
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.7 (declared here
// so that the tap names exist). Lane C fills the body.
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
	input  wire         guard_on,     // from u_guard
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
	// ---- bench taps (design 1.7; frozen names; daria_fe_pkg::F6_* for f6_ph) ----
	logic  [3:0] f6_ph;               // one-hot while f6_act
	logic        run;
	logic        fill;
	logic [16:0] src;
	logic [12:0] dst;
	logic  [7:0] rem;
	logic  [7:0] val;
	logic        dma_busy;            // = arm_dma_busy
	logic        a_f6_live;

	assign f6_ph        = 4'd0;       // stub
	assign run          = 1'b0;       // stub
	assign fill         = 1'b0;       // stub
	assign src          = 17'd0;      // stub
	assign dst          = 13'd0;      // stub
	assign rem          = 8'h00;      // stub
	assign val          = 8'h00;      // stub
	assign dma_busy     = 1'b0;       // stub
	assign a_f6_live    = 1'b0;       // stub

	assign svc_take     = 1'b0;       // stub
	assign init_busy    = 1'b0;       // stub
	assign arm_dma_busy = 1'b0;       // stub
	assign f6_act       = 1'b0;       // stub
	assign rst_quiet    = 1'b0;       // stub
	assign cp_req       = 1'b0;       // stub
	assign cp_a         = 13'd0;      // stub
	assign cp_we        = 1'b0;       // stub
	assign cp_be        = 4'h0;       // stub
	assign cp_wd        = 32'd0;      // stub
	assign cz_req       = 1'b0;       // stub
	assign cz_a         = 8'h00;      // stub
	assign ca_req       = 1'b0;       // stub
	assign ca_a         = 13'd0;      // stub
endmodule

`default_nettype wire
