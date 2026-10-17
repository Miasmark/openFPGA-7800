//------------------------------------------------------------------------------
// DARIA's sample requester, on clk_arm (docs/daria_step7/plan.md 2.2, P7).
// The front end's digital samples beyond its 32 KB ROM (daria_fe_audio.sv,
// "the sample client") read the image byte by byte through this port: one
// halfword read each, straight from the PSRAM at bup_asset_wr's read port,
// ahead of the asset cache (not through it).
//
// The front end's side is clk_sys registers: smp_req flips to post a
// request, smp_addr (the image byte offset) is set on the same edge and held
// until the answer, and the next request comes only after the answer. This
// side answers every request once: smp_data takes the byte, and smp_ack
// flips one clk_arm later. The front end samples smp_data two clk_sys flops
// after smp_ack changes, so the byte is a held bus, as smp_addr is.
//
//   asked   req_s1 != ack: two flops on smp_req against this side's toggle
//   start   asked and idle. If the image is readable (readable: the 2600
//           profile, img_ready and no hold) the address is latched and a
//           read wanted (pend); otherwise the answer is $FF at once
//   issue   while pend the read port is this side's: its request goes to
//           bup_asset_wr, which takes it (rd_ack) as soon as the PSRAM
//           controller is idle, so a cache read already in flight finishes
//           first. From pend until the halfword arrives (fl) the cache's
//           rd_req is masked and it sees no rd_ack. The cache takes only the
//           rd_avail of its own reads (bup_asset_cache.sv: rx = rd_avail &&
//           f_fl), and only one read is ever in flight
//   answer  on rd_avail with fl: the byte addr[0] picks (the low byte for
//           an even offset, as bup_capture packs the image into halfwords),
//           then ack flips on the next clock
//
// The read is at halfword {4'b0, addr[18:1]}: the image starts at halfword 0
// of die 0, as the cache addresses it. No reset of any kind (P7): not the
// hold, cpu_run, the mapper reset or the PLL's. The front end's side is not
// reset either (daria_fe_audio.sv), and resetting one side of the toggle
// pair would lose, repeat or mistake an answer. A read already wanted when
// readable falls still completes: the PSRAM controller is never held, and
// bup_asset_wr lets a download's writes go first.
//
// Worst-case answer time: a cache read in flight, this read (each 5 or 6
// clk_arm with psram.sv at CLOCK_SPEED 50.0), and two clk_sys plus two
// clk_arm of synchronisation, under 1 us against one request per 20 kHz
// tick. Every decision comes from registers (req_s1, ack, pend, fl, done);
// the cache's combinational chain psram_read_avail -> rx -> rd_req ->
// psram_read_en -> rd_ack gains the mask only.
//
// req_s0 is the synchroniser's first flop: a scalar of its own, marked
// FORCED here (P8). smp_addr and smp_data are held buses (the clk_sys <->
// clk_arm max/min delay pair of the SDC).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_smp (
	input  wire        clk,          // clk_arm

	// The front end's sample port (daria_fe smp_*).
	input  wire        smp_req,      // request toggle (clk_sys register)
	input  wire [18:0] smp_addr,     // image byte offset, held while a request is open
	output wire        smp_ack,      // answer toggle
	output wire  [7:0] smp_data,     // the answer, set one clock before smp_ack flips
	input  wire        readable,     // the 2600 profile, img_ready and no hold (clk_arm)

	// The asset cache's read port.
	input  wire        c_rd_req,
	input  wire [21:0] c_rd_addr,
	output wire        c_rd_ack,

	// bup_asset_wr's read port, and psram.sv's read_avail and data_out.
	output wire        rd_req,
	output wire [21:0] rd_addr,
	input  wire        rd_ack,
	input  wire        rd_avail,
	input  wire [15:0] rd_data
);
	// Power-up values are the repository's idiom (docs/DEVELOPING.md,
	// "Power-up values"); nothing here is ever reset.
	/* verilator lint_off PROCASSINIT */
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic        req_s0 = 1'b0;
	logic        req_s1 = 1'b0;
	logic        ack    = 1'b0;      // the answer toggle
	logic        pend   = 1'b0;      // a read wanted, not yet taken
	logic        fl     = 1'b0;      // that read is in flight
	logic        done   = 1'b0;      // data holds the answer: flip ack
	logic [18:0] addr   = 19'd0;
	logic  [7:0] data   = 8'hFF;
	/* verilator lint_on PROCASSINIT */

	wire asked = req_s1 != ack;
	wire start = asked && !pend && !fl && !done;
	wire own   = pend || fl;         // the read port is this side's
	wire take  = pend && rd_ack;     // its read is taken
	wire rx    = fl && rd_avail;     // its halfword arrives

	always_ff @(posedge clk) begin
		req_s0 <= smp_req;
		req_s1 <= req_s0;
		if (start && readable) begin
			pend <= 1'b1;
			addr <= smp_addr;
		end
		if (take) begin
			pend <= 1'b0;
			fl <= 1'b1;
		end
		if (start && !readable) begin
			data <= 8'hFF;
			done <= 1'b1;
		end
		if (rx) begin
			fl <= 1'b0;
			data <= addr[0] ? rd_data[15:8] : rd_data[7:0];
			done <= 1'b1;
		end
		if (done) begin
			done <= 1'b0;
			ack <= ~ack;
		end
	end

	assign rd_req   = pend || (c_rd_req && !own);
	assign rd_addr  = pend ? {4'd0, addr[18:1]} : c_rd_addr;
	assign c_rd_ack = rd_ack && !own;
	assign smp_ack  = ack;
	assign smp_data = data;
endmodule

`default_nettype wire
