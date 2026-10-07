//------------------------------------------------------------------------------
// DARIA front end: the audio engine (docs/daria_fe/design.md 5), upstream's
// arm_mapper_audio re-expressed under D10 clock for clock, without BUS: the
// tick, counters, frequencies, the six-word payload ring, the replica FSM
// and its grant (aud_take, from u_arb), AMPLITUDE and the sample client.
// Reset: cart_reset only (the sample client's busy flags not even by that).
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off, and so is every bench tap of design 1.7 (declared here
// so that the tap names exist). Lane B fills the body.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_audio (
	input  wire          clk_sys,
	input  wire          cart_reset,
	input  wire          pause,        // pause_core
	input  wire    [1:0] fam,          // 1 DPC+, 3 CDF, 0 otherwise (live)
	input  wire    [1:0] rev,          // revision[1:0]
	input  wire   [31:0] rom_size,
	input  wire          ram32,        // ram_size = ram32 ? $8000 : $2000
	input  wire   [15:0] asz,          // audio_size_addr
	input  wire          cdf_dig,      // from u_core: mode[7:4] == 0
	input  wire    [6:0] wave0,        // from u_core
	input  wire    [6:0] wave1,
	input  wire    [6:0] wave2,
	input  wire          note_stb,     // pulse in (C, C+1)
	input  wire    [1:0] note_v,
	input  wire    [7:0] note_val,
	// call (from u_call, 6)
	input  wire          cp_cap,       // pulse: the ring captures counters and frequencies
	input  wire          cp_rot,       // pulse: the ring rotates (posting F2-F7)
	input  wire          cp_shin,      // pulse: stb_q shifts into the ring
	input  wire          cp_cmp,       // pulse: take[] compares a return with its seed
	input  wire          cp_apply,     // pulse: the merge at M_fe
	input  wire          mwin,         // level: tick adds deferred
	// hook (bench only; tied 0 in synthesis)
	input  wire          hk_en,
	input  wire          hk_stb,
	input  wire  [191:0] hk_ret,       // {f2, f1, f0, c2, c1, c0}
	// R
	output logic         aud_issue,    // comb
	output logic  [14:0] aud_addr,     // comb: byte address (u_arb uses [14:2])
	input  wire          aud_take,     // comb, from u_arb
	input  wire   [31:0] crb_q,
	// S
	input  wire   [31:0] stb_q,        // the return words F8-FD
	// A
	output logic         aud_a_req,
	output logic  [12:0] aud_a_a,
	input  wire          aud_a_gnt,
	input  wire   [31:0] fea_q,
	// sample port
	output logic         smp_req,      // reg: request toggle
	output logic  [18:0] smp_addr,     // reg
	input  wire          smp_ack,      // answer toggle (two clk_sys flops inside)
	input  wire    [7:0] smp_data,
	// out
	output logic   [7:0] amp_nx,       // comb: the value amplitude holds after this edge
	output logic  [31:0] ring0         // ring[0], to u_call
);
	// ---- bench taps (design 1.7; frozen names; daria_fe_pkg::AS_* for st) -------
	logic        tick;
	logic [23:0] accum;
	logic [31:0] counter [0:2];
	logic [31:0] freq [0:2];
	logic [31:0] rc [0:2];
	logic [31:0] ring [0:5];
	logic  [2:0] take;
	logic        tdef;
	logic [11:0] st;                   // one-hot
	logic  [1:0] voice;
	logic  [7:0] ssum;
	logic  [4:0] wsh;
	logic [14:0] woff;
	logic [31:0] dig_addr;
	logic        dig_low;
	logic [14:0] dig_ram;
	logic        dig_smp;
	logic        rp;
	logic        np;
	logic  [7:0] amplitude;
	logic        dispatch;
	logic  [1:0] al;
	logic        busy_l;
	logic        busy_r;
	logic        ev_size_hi;
	logic        a_tdef2;

	assign tick       = 1'b0;          // stub
	assign accum      = 24'd0;         // stub
	assign counter[0] = 32'd0;         // stub
	assign counter[1] = 32'd0;         // stub
	assign counter[2] = 32'd0;         // stub
	assign freq[0]    = 32'd0;         // stub
	assign freq[1]    = 32'd0;         // stub
	assign freq[2]    = 32'd0;         // stub
	assign rc[0]      = 32'd0;         // stub
	assign rc[1]      = 32'd0;         // stub
	assign rc[2]      = 32'd0;         // stub
	assign ring[0]    = 32'd0;         // stub
	assign ring[1]    = 32'd0;         // stub
	assign ring[2]    = 32'd0;         // stub
	assign ring[3]    = 32'd0;         // stub
	assign ring[4]    = 32'd0;         // stub
	assign ring[5]    = 32'd0;         // stub
	assign take       = 3'd0;          // stub
	assign tdef       = 1'b0;          // stub
	assign st         = 12'd0;         // stub
	assign voice      = 2'd0;          // stub
	assign ssum       = 8'h00;         // stub
	assign wsh        = 5'd0;          // stub
	assign woff       = 15'd0;         // stub
	assign dig_addr   = 32'd0;         // stub
	assign dig_low    = 1'b0;          // stub
	assign dig_ram    = 15'd0;         // stub
	assign dig_smp    = 1'b0;          // stub
	assign rp         = 1'b0;          // stub
	assign np         = 1'b0;          // stub
	assign amplitude  = 8'h00;         // stub
	assign dispatch   = 1'b0;          // stub
	assign al         = 2'd0;          // stub
	assign busy_l     = 1'b0;          // stub
	assign busy_r     = 1'b0;          // stub
	assign ev_size_hi = 1'b0;          // stub
	assign a_tdef2    = 1'b0;          // stub

	assign aud_issue  = 1'b0;          // stub
	assign aud_addr   = 15'd0;         // stub
	assign aud_a_req  = 1'b0;          // stub
	assign aud_a_a    = 13'd0;         // stub
	assign smp_req    = 1'b0;          // stub
	assign smp_addr   = 19'd0;         // stub
	assign amp_nx     = 8'h00;         // stub
	assign ring0      = 32'd0;         // stub
endmodule

`default_nettype wire
