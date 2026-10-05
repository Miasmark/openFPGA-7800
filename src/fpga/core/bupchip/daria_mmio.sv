//------------------------------------------------------------------------------
// DARIA's MMIO in the 2600 profile (docs/DARIA_CORE.md, M3, M4 and P4; "The
// memory system", 4 and 6): MAMCR, and timer 1's TCR and TC, the registers of
// the LPC2103's peripheral window that upstream (arm_mapper_memory.sv, Jamie
// Blanks, MIT) reads back.
//
// Decode, as upstream's. bup_cpu raises sel for the one clk_arm clock of W, and
// only inside the window (addr[31:21] == 0x700). A register answers only when
// addr is its byte address exactly:
//
//   0xE01FC000  MAMCR  clk_arm, 32 bits
//   0xE0008004  T1TCR  clk_arm, 32 bits; bit 0 runs the counter
//   0xE0008008  T1TC   a counter on clk_sys; the CPU reads a clk_arm mirror
//
// So a byte or halfword access at +1 to +3 reads 0 and drops its write, and so
// does every other address in the window. Writes are byte-strobed: a byte at a
// register's address writes lane 0, a halfword lanes 0-1, a word all four
// (wdata has the value on every lane, as bup_cpu's st_lanes gives it). rdata is
// the aligned word, combinational in sel's clock, and 0 unless sel hits a
// register; bup_cpu rotates and extends it.
//
// The counter. The LPC2103 counts at 70 MHz. Upstream divides its 5 x clk_sys
// ARM clock, skipping 1 tick in 45 (NTSC) or 76 (PAL). DARIA's clk_arm is no
// multiple of clk_sys, so the counter runs on clk_sys and adds 5, or 4 in the
// clocks that hold upstream's skipped ticks:
//
//   NTSC  4 at phase 0 of 9:              44 per 9 clocks,
//         14.318182 MHz x 44 / 9  = 70.000000 MHz
//   PAL   4 at phases 0, 15, 30, 45, 60:  375 per 76 clocks,
//         14.187580 MHz x 375 / 76 = 70.004500 MHz
//
// The phase moves while run is high (upstream's mem_ce, the console's run
// enable), and the counter adds while run is high and TCR bit 0 has reached
// clk_sys. A pause stops both, as upstream, so it does not show in a frame
// timed with the timer (Draconian's).
//
// Crossings. Nothing else crosses between the clocks:
//
//   TCR bit 0    clk_arm -> clk_sys  two flops
//   TC write     clk_arm -> clk_sys  w_data and w_strb held, toggle w_tog
//                                    through two flops; clk_sys merges the
//                                    strobed lanes into the counter in the
//                                    clock after the second flop changes.
//                                    That clock's increment is lost: the write
//                                    wins, as upstream's later assignment does.
//   TC snapshot  clk_sys -> clk_arm  every 4 clocks the counter, and w_seen,
//                                    the toggle of the last write merged into
//                                    it, are copied into hold and hold_tok;
//                                    toggle sn_tog through two flops, and
//                                    clk_arm takes them in the clock after the
//                                    second flop changes.
//
// Each held bus is stable from its toggle until the far side has taken it:
// a write stays in flight until a snapshot shows it merged, and a snapshot
// is held 4 clk_sys, which covers 3 clk_arm down to about 12 MHz. The SDC
// bounds both buses (set_max_delay 20 / set_min_delay -20).
//
// Writes and the mirror. One write is in flight at a time, and its toggle is
// its token. The mirror takes a snapshot only when hold_tok equals w_tog, that
// is when the snapshot was taken after every write launched had merged; that
// snapshot also ends the flight. A write that comes during a flight is kept in
// the mirror, its lanes marked in q_strb, and launched (with any others that
// come meanwhile) when the flight ends: the writes then land together, later.
// The mirror takes every written byte at once, and a snapshot replaces only
// the lanes not in q_strb, so a read never returns a value older than the
// CPU's last write.
//
// Staleness. With no write in flight a read shows the counter as it was at
// most 5 clk_sys earlier (6 with clk_arm below 28.6 MHz), about 24 counts: a
// snapshot every 4 clocks, of the counter as it was the clock before, taken 2
// to 3 clk_arm later. A flight lasts at most 7 clk_sys and 3 clk_arm, about
// 570 ns at 38.18 MHz (3 clocks to merge, up to 4 to the next snapshot, and
// its crossing). A word write rewrites the whole mirror; after a byte or
// halfword the other lanes keep the older snapshot until the flight ends.
//
// Reset. rst_arm and rst_sys are one level (a mapper reset, or a new image's
// START) through two flops on each side, and each clears its own side:
// rst_arm MAMCR, TCR, the mirror, w_tog, the flight, q_strb and the snapshot
// synchronisers; rst_sys the counter, its phase, the enable and write
// synchronisers, w_seen, and the snapshot's toggle and divider. Every toggle
// pair is then 0 and 0. The held buses (w_data, w_strb, hold, hold_tok) are
// not reset: a toggle may still be crossing when the reset comes, and its bus
// must not change under the far side. They are rewritten before they are next
// used. The two resets must overlap, so the level must last at least 4
// clk_sys (a mapper reset and START last far longer). Then whatever a toggle
// flipped by one side's reset makes the other side take (a write merged
// again, an old snapshot) is cleared by the other side's own reset, which
// comes later or is still on; and after both, the first snapshot carries the
// cleared counter.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_mmio (
	// clk_arm: bup_cpu's W, one clock per access.
	input  wire         clk_arm,
	input  wire         rst_arm,        // level, through two clk_arm flops
	input  wire         sel,            // an access inside the window, 2600 profile
	input  wire         write,          // 1 store, 0 load
	input  wire  [31:0] addr,           // the byte address
	input  wire   [1:0] size,           // 0 byte, 1 halfword, 2 word
	input  wire  [31:0] wdata,          // the value on every lane (st_lanes)
	output logic [31:0] rdata,          // the aligned word; 0 unless sel hits a register

	// clk_sys: the counter.
	input  wire         clk_sys,
	input  wire         rst_sys,        // the same level, through two clk_sys flops
	input  wire         pal,            // the region's clk_sys; static
	input  wire         run             // the console's run enable (upstream's mem_ce)
);
	localparam logic [31:0] A_MAMCR = 32'hE01F_C000;
	localparam logic [31:0] A_T1TCR = 32'hE000_8004;
	localparam logic [31:0] A_T1TC  = 32'hE000_8008;

	// old with the lanes in be taken from v
	function automatic logic [31:0] lanes(input logic [31:0] old, input logic [31:0] v,
			input logic [3:0] be);
		lanes = {be[3] ? v[31:24] : old[31:24], be[2] ? v[23:16] : old[23:16],
			be[1] ? v[15:8] : old[15:8], be[0] ? v[7:0] : old[7:0]};
	endfunction

	// ---- clk_sys registers the clk_arm side reads: the snapshot and its toggle --------------
	logic [31:0] hold = 32'd0;              // the counter, every 4 clk_sys
	logic        hold_tok = 1'b0;           // w_seen with it
	logic        sn_tog = 1'b0;

	// ---- clk_arm: decode, MAMCR, TCR, the mirror, the write ---------------------------------
	wire       hit_mam = sel && addr == A_MAMCR;
	wire       hit_tcr = sel && addr == A_T1TCR;
	wire       hit_tc  = sel && addr == A_T1TC;
	wire [3:0] be      = size == 2'd0 ? 4'b0001 : size == 2'd1 ? 4'b0011 : 4'b1111;
	wire       wr_tc   = hit_tc && write;

	logic [31:0] mamcr = 32'd0, tcr = 32'd0, mirror = 32'd0;
	logic [31:0] w_data = 32'd0;            // held while in flight
	logic  [3:0] w_strb = 4'd0;
	logic        w_tog = 1'b0;              // flips at each launch: the write's token
	logic        busy = 1'b0;               // a write in flight
	logic  [3:0] q_strb = 4'd0;             // mirror lanes written during the flight
	logic  [1:0] sn_a = 2'b00;
	logic        sn_seen = 1'b0;

	assign rdata = ({32{hit_mam}} & mamcr) | ({32{hit_tcr}} & tcr) | ({32{hit_tc}} & mirror);

	wire        snap_new = sn_a[1] != sn_seen;
	wire        snap_ok  = snap_new && hold_tok == w_tog;  // every launched write is in it
	wire [31:0] mir_base = snap_ok ? lanes(hold, mirror, q_strb) : mirror;
	wire [31:0] mir_next = wr_tc ? lanes(mir_base, wdata, be) : mir_base;
	wire  [3:0] pend     = q_strb | (wr_tc ? be : 4'd0);
	wire        launch   = pend != 4'd0 && (!busy || snap_ok);

	always_ff @(posedge clk_arm) begin
		sn_a <= {sn_a[0], sn_tog};
		if (snap_new) sn_seen <= sn_a[1];
		mirror <= mir_next;
		if (hit_mam && write) mamcr <= lanes(mamcr, wdata, be);
		if (hit_tcr && write) tcr <= lanes(tcr, wdata, be);
		if (launch) begin
			w_data <= mir_next;
			w_strb <= pend;
			w_tog <= ~w_tog;
			busy <= 1'b1;
			q_strb <= 4'd0;
		end else begin
			q_strb <= pend;
			if (snap_ok) busy <= 1'b0;
		end
		if (rst_arm) begin
			sn_a <= 2'b00;
			sn_seen <= 1'b0;
			mirror <= 32'd0;
			mamcr <= 32'd0;
			tcr <= 32'd0;
			w_tog <= 1'b0;
			busy <= 1'b0;
			q_strb <= 4'd0;
		end
	end

	// ---- clk_sys: the counter and the snapshot -----------------------------------------------
	logic  [1:0] en_s = 2'b00;              // TCR bit 0
	logic  [1:0] w_s = 2'b00;               // w_tog
	logic        w_seen = 1'b0;
	logic [31:0] tc = 32'd0;
	logic  [6:0] ph = 7'd0;
	logic  [1:0] sn_div = 2'd0;

	wire       merge_now = w_s[1] != w_seen;
	wire       four_pal = ph == 7'd0 || ph == 7'd15 || ph == 7'd30 || ph == 7'd45 || ph == 7'd60;
	wire       four = pal ? four_pal : ph == 7'd0;
	wire [6:0] ph_last = pal ? 7'd75 : 7'd8;

	always_ff @(posedge clk_sys) begin
		en_s <= {en_s[0], tcr[0]};
		w_s <= {w_s[0], w_tog};
		if (run) ph <= ph >= ph_last ? 7'd0 : ph + 7'd1;
		if (merge_now) begin
			w_seen <= w_s[1];
			tc <= lanes(tc, w_data, w_strb);
		end else if (run && en_s[1])
			tc <= tc + (four ? 32'd4 : 32'd5);
		sn_div <= sn_div + 2'd1;
		if (sn_div == 2'd3) begin
			hold <= tc;
			hold_tok <= w_seen;
			sn_tog <= ~sn_tog;
		end
		if (rst_sys) begin
			en_s <= 2'b00;
			w_s <= 2'b00;
			w_seen <= 1'b0;
			tc <= 32'd0;
			ph <= 7'd0;
			sn_div <= 2'd0;
			sn_tog <= 1'b0;
		end
	end
endmodule

`default_nettype wire
