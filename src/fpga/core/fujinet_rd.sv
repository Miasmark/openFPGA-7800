//------------------------------------------------------------------------------
// FujiNet swap: the staged image's reader, on clk_arm
// (docs/FUJINET_GAME_LOADING.md, 3.4).
//
// fujinet_loader.sv (clk_sys) reads the staged file a halfword at a time
// through this port, which sits in front of bup_asset_wr's read port, ahead
// of everything else that reads there (daria_smp.sv's samples, the asset
// cache's fills): their requests pass through untouched while this side is
// idle, which is always unless a swap runs.
//
// The loader's side is clk_sys registers: l_req flips to post a request,
// l_haddr (the halfword in the staging area) is set on the same edge and
// held until the answer, and the next request comes only after the answer.
// This side answers every request once: l_data takes the halfword, and
// l_ack flips one clk_arm later. The loader samples l_data two clk_sys
// flops after l_ack changes, so it is a held bus, as l_haddr is.
//
// While a read is wanted (pend) or in flight (fl), the port is this side's:
// the upstream's request is masked and it sees no rd_ack, so it never has a
// read in flight then and ignores rd_avail (daria_smp takes it only with its
// fl, the cache only with its f_fl). A read of the upstream's already in
// flight when this side asks finishes first: bup_asset_wr takes this side's
// request (rd_ack) only once the controller is idle. The read is at halfword
// {3'b100, l_haddr}: the staging area, die 0 from byte 4 MiB.
//
// No reset: resetting one side of the toggle pair would lose, repeat or
// mistake an answer (as daria_smp.sv). req_s0 is the synchroniser's first
// flop, a scalar of its own, marked FORCED here.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module fujinet_rd (
	input  wire        clk,          // clk_arm

	// fujinet_loader.sv's port (clk_sys)
	input  wire        l_req,        // request toggle
	input  wire [18:0] l_haddr,      // halfword in the staging area, held while open
	output wire        l_ack,        // answer toggle
	output wire [15:0] l_data,       // the answer, set one clock before l_ack flips

	// The upstream read port (daria_smp.sv or the asset cache)
	input  wire        u_rd_req,
	input  wire [21:0] u_rd_addr,
	output wire        u_rd_ack,

	// bup_asset_wr's read port, and psram.sv's read_avail and data_out
	output wire        rd_req,
	output wire [21:0] rd_addr,
	input  wire        rd_ack,
	input  wire        rd_avail,
	input  wire [15:0] rd_data
);
	/* verilator lint_off PROCASSINIT */
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic        req_s0 = 1'b0;
	logic        req_s1 = 1'b0;
	logic        ack    = 1'b0;
	logic        pend   = 1'b0;
	logic        fl     = 1'b0;
	logic        done   = 1'b0;
	logic [18:0] addr   = 19'd0;
	logic [15:0] data   = 16'd0;
	/* verilator lint_on PROCASSINIT */

	wire start = req_s1 != ack && !pend && !fl && !done;
	wire own   = pend || fl;

	always_ff @(posedge clk) begin
		req_s0 <= l_req;
		req_s1 <= req_s0;
		if (start) begin
			pend <= 1'b1;
			addr <= l_haddr;
		end
		if (pend && rd_ack) begin
			pend <= 1'b0;
			fl <= 1'b1;
		end
		if (fl && rd_avail) begin
			fl <= 1'b0;
			data <= rd_data;
			done <= 1'b1;
		end
		if (done) begin
			done <= 1'b0;
			ack <= ~ack;
		end
	end

	assign rd_req   = pend || (u_rd_req && !own);
	assign rd_addr  = pend ? {3'b100, addr} : u_rd_addr;
	assign u_rd_ack = rd_ack && !own;
	assign l_ack    = ack;
	assign l_data   = data;
endmodule

`default_nettype wire
