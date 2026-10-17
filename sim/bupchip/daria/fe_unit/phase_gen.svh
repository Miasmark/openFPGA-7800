//------------------------------------------------------------------------------
// fe_phase_gen: the shared random 6507 phase and bus generator of the
// daria_fe unit benches (docs/daria_fe/design.md 12.1, 12.3; the interfaces
// are docs/daria_fe/interfaces.md). Include it once per bench, at file
// scope: `include "phase_gen.svh" (run_unit.sh puts this directory on the
// include path).
//
// Everything is clk_sys. It produces what daria_fe sees from top.sv:
//
//   pclk1, pclk0  one-clock pulses that strictly alternate (top.sv's paired
//                 phi1_ce/phi2_ce), registered. E0 is the edge at which
//                 pclk1 is sampled high; the phase-1 length L1 is the
//                 distance from that pulse to pclk0's, L2 from pclk0's to
//                 the next pclk1's, in clocks.
//                 L1: 6; 2 or 4 (RSYNC, bus.md B2); 6+s, s = 1..max_str
//                     (stretched, as at the MARIA->TIA handoff after reset).
//                 L2: 6; 10 (RSYNC); 6+s; 4 only while driver_run is 0
//                     (MARIA's phases during reset and the BIOS, where
//                     access is 0; design 2.8).
//                 A pause (D9) can fall anywhere inside either phase: no
//                 pulse while pause is high, and the phase lasts L + the
//                 pause's length. The bus is frozen through it.
//   a_in, rw,     load at E0 (the CPU's address, R/W and DOR registers load
//   d_in          at phi1; bus.md section 2), so they change only at an E0.
//                 d_in is write_DB: a new byte at every E0, read or write.
//   held          RDY (= !stall_eff) is read in the pclk1 clock; a cycle is
//                 held iff RDY is low there and the previous cycle was a
//                 read (mos6502_ctl.sv:874; bus.md B7). A held cycle
//                 re-presents the previous address with rw = 1.
//   mapper_phi2,  exactly top.sv:316-327: stall_cycle_taken is set at the
//   access        first pclk0 while the stall is high and cleared while it
//                 is low; mapper_phi2 = pclk0 && (!stall_eff || !taken),
//                 access = mapper_phi2 && driver_run. So in a stall the first
//                 pclk0 is shown and every later one hidden.
//   stall_eff     stall (the bench's: e.g. the DUT's arm_call_busy |
//                 arm_dma_busy) | ibusy. ibusy is the generator's own stall,
//                 for benches without a busy source: it rises at a write
//                 commit (access & a_in[12] & !rw) with probability pg_busy,
//                 lasts busy_min..busy_max cycles (E0s), and falls only at an
//                 edge where rel_ok = (ph2 | pclk0) & !pclk1 (design 2.1).
//
// The bus comes from the generator's own random stream, or with EXT_BUS = 1
// from ext_a/ext_rw/ext_d: in a clock where load is high, a new (not held)
// cycle loads them at the edge that ends it; the bench advances its own
// stream at that same edge (always @(posedge clk_sys) if (load) ...).
//
// Knobs. Parameters give the defaults; with USE_PLUSARGS (default) these
// plusargs override them (probabilities in per mille):
//   +pg_seed=N        seed (SEED_OFS is added: several generators, one seed)
//   +pg_mode=M        preset: nominal | mix (default) | short | stretch |
//                     pause | held | all; the knobs below override it
//   +pg_ph1_2=, +pg_ph1_4=, +pg_str1=   phase 1 of 2, of 4, stretched (per cycle)
//   +pg_ph2_10=, +pg_str2=, +pg_ph2_4=  phase 2 of 10, stretched, of 4 (!driver_run only)
//   +pg_max_str=N     stretch 1..N clocks (default 6)
//   +pg_pause1=, +pg_pause2=            a pause inside phase 1 / phase 2 (per phase)
//   +pg_max_pause=N   pause length 1..N clocks (default 40)
//   +pg_busy=         ibusy at a write commit; +pg_busy_min=, +pg_busy_max= (cycles)
//   +pg_wr=           a write cycle; +pg_a12= A12 set
//   +pg_lo=, +pg_hi=  the low 12 bits in $000-$07F / $FF0-$FFF
//   +pg_rep=          repeat the previous address
//   +pg_verbose=1     print the knobs
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`ifndef FE_PHASE_GEN_SVH
`define FE_PHASE_GEN_SVH

module fe_phase_gen #(
	parameter int    SEED         = 1,
	parameter int    SEED_OFS     = 0,
	parameter string MODE         = "mix",
	parameter bit    EXT_BUS      = 1'b0,
	parameter bit    USE_PLUSARGS = 1'b1
) (
	input  wire         clk_sys,
	input  wire         run,          // 0: no phases (the bus holds); on 1 a phase-2 remainder, then pclk1
	input  wire         stall,        // the bench's RDY low (arm_call_stall)
	input  wire         driver_run,   // arm_driver_run
	input  wire  [12:0] ext_a,        // EXT_BUS: the next cycle's bus
	input  wire         ext_rw,
	input  wire   [7:0] ext_d,
	output logic        pclk1,
	output logic        pclk0,
	output logic        mapper_phi2,  // comb
	output logic        access,       // comb
	output logic [12:0] a_in,
	output logic        rw,
	output logic  [7:0] d_in,
	output logic        pause,
	output logic        load,         // comb: a new cycle's bus loads at the end of this clock
	output logic        stall_eff,    // comb: stall | ibusy
	output logic        ibusy,
	output logic        held,         // the current cycle (from its E0) is a held repeat
	output logic  [5:0] len1,         // L1 of the cycle whose pclk1 was emitted last
	output logic  [5:0] len2          // L2 of the cycle whose pclk0 was emitted last
);
	// ---- knobs -----------------------------------------------------------------------
	int unsigned seed;
	string       mode;
	int k_ph1_2, k_ph1_4, k_str1, k_ph2_10, k_str2, k_ph2_4, max_str;
	int k_pause1, k_pause2, max_pause, k_busy, busy_min, busy_max;
	int k_wr, k_a12, k_lo, k_hi, k_rep;
	int verbose;

	task automatic preset(input string m);
		k_ph1_2 = 0; k_ph1_4 = 0; k_str1 = 0; k_ph2_10 = 0; k_str2 = 0; k_ph2_4 = 0;
		k_pause1 = 0; k_pause2 = 0; k_busy = 0;
		max_str = 6; max_pause = 40; busy_min = 1; busy_max = 8;
		k_wr = 250; k_a12 = 900; k_lo = 150; k_hi = 50; k_rep = 30;
		case (m)
			"nominal": ;
			"mix":     begin k_ph1_2 = 15; k_ph1_4 = 15; k_str1 = 20; k_ph2_10 = 20; k_str2 = 20;
			                 k_pause1 = 5; k_pause2 = 5; k_busy = 40; end
			"short":   begin k_ph1_2 = 200; k_ph1_4 = 200; k_ph2_10 = 50; k_busy = 40; end
			"stretch": begin k_str1 = 200; k_str2 = 200; k_ph2_10 = 50; k_busy = 40; end
			"pause":   begin k_pause1 = 100; k_pause2 = 100; k_busy = 40; end
			"held":    begin k_busy = 300; busy_max = 12; k_wr = 350; end
			"all":     begin k_ph1_2 = 60; k_ph1_4 = 60; k_str1 = 60; k_ph2_10 = 60; k_str2 = 60;
			                 k_ph2_4 = 200; k_pause1 = 30; k_pause2 = 30; k_busy = 100; end
			default:   $fatal(1, "fe_phase_gen: unknown mode %s", m);
		endcase
	endtask

	logic [31:0] rs;              // the random stream's state

	initial begin
		seed = SEED;
		mode = MODE;
		verbose = 0;
		if (USE_PLUSARGS) begin
			void'($value$plusargs("pg_seed=%d", seed));
			void'($value$plusargs("pg_mode=%s", mode));
		end
		preset(mode);
		if (USE_PLUSARGS) begin
			void'($value$plusargs("pg_ph1_2=%d", k_ph1_2));
			void'($value$plusargs("pg_ph1_4=%d", k_ph1_4));
			void'($value$plusargs("pg_str1=%d", k_str1));
			void'($value$plusargs("pg_ph2_10=%d", k_ph2_10));
			void'($value$plusargs("pg_str2=%d", k_str2));
			void'($value$plusargs("pg_ph2_4=%d", k_ph2_4));
			void'($value$plusargs("pg_max_str=%d", max_str));
			void'($value$plusargs("pg_pause1=%d", k_pause1));
			void'($value$plusargs("pg_pause2=%d", k_pause2));
			void'($value$plusargs("pg_max_pause=%d", max_pause));
			void'($value$plusargs("pg_busy=%d", k_busy));
			void'($value$plusargs("pg_busy_min=%d", busy_min));
			void'($value$plusargs("pg_busy_max=%d", busy_max));
			void'($value$plusargs("pg_wr=%d", k_wr));
			void'($value$plusargs("pg_a12=%d", k_a12));
			void'($value$plusargs("pg_lo=%d", k_lo));
			void'($value$plusargs("pg_hi=%d", k_hi));
			void'($value$plusargs("pg_rep=%d", k_rep));
			void'($value$plusargs("pg_verbose=%d", verbose));
		end
		if (max_str < 1 || max_str > 25) $fatal(1, "fe_phase_gen: pg_max_str must be 1..25");
		if (max_pause < 1 || max_pause > 255) $fatal(1, "fe_phase_gen: pg_max_pause must be 1..255");
		if (busy_min < 0 || busy_max < busy_min) $fatal(1, "fe_phase_gen: bad pg_busy_min/max");
		rs = 32'h9E37_79B9 ^ ((seed + SEED_OFS) * 32'h85EB_CA6B);
		if (rs == 0) rs = 32'h1;
		if (verbose)
			$display("fe_phase_gen %m: seed %0d+%0d mode %s ph1_2 %0d ph1_4 %0d str1 %0d ph2_10 %0d str2 %0d ph2_4 %0d max_str %0d pause %0d/%0d max %0d busy %0d (%0d..%0d) wr %0d a12 %0d lo %0d hi %0d rep %0d",
				seed, SEED_OFS, mode, k_ph1_2, k_ph1_4, k_str1, k_ph2_10, k_str2, k_ph2_4, max_str,
				k_pause1, k_pause2, max_pause, k_busy, busy_min, busy_max, k_wr, k_a12, k_lo, k_hi, k_rep);
	end

	// ---- the random stream (xorshift32; independent of $urandom) ------------------------
	function automatic logic [31:0] xs(input logic [31:0] s);
		logic [31:0] x;
		x = s;
		x = x ^ (x << 13);
		x = x ^ (x >> 17);
		x = x ^ (x << 5);
		return x;
	endfunction
	function int unsigned rnd(input int unsigned n);   // 0 .. n-1 (0 if n is 0); advances rs
		rs = xs(rs);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	function bit pm(input int k);                       // true with probability k / 1000
		return rnd(1000) < k;
	endfunction

	// ---- state -----------------------------------------------------------------------
	logic [1:0] phase;            // 1: the next pulse is pclk0; 2: pclk1
	logic [5:0] cnt;              // clocks (not paused) to the next pulse
	logic       pz_arm;           // a pause is planned in this phase
	logic [5:0] pz_at;            // it starts at the edge where cnt == pz_at (2..L)
	logic [7:0] pz_len, pz_left;
	logic       taken;            // top.sv's stall_cycle_taken
	logic       ph2m;             // D3's in_phase2, for the ibusy release
	int         ib_cyc;           // E0s left before ibusy may fall

	initial begin
		pclk1 = 1'b0; pclk0 = 1'b0; a_in = '0; rw = 1'b1; d_in = '0; pause = 1'b0;
		ibusy = 1'b0; held = 1'b0; len1 = 6'd6; len2 = 6'd6;
		phase = 2'd2; cnt = 6'd3; pz_arm = 1'b0; pz_at = '0; pz_len = '0; pz_left = '0;
		taken = 1'b0; ph2m = 1'b0; ib_cyc = 0;
	end

	assign stall_eff   = stall | ibusy;
	assign mapper_phi2 = pclk0 && (!stall_eff || !taken);
	assign access      = mapper_phi2 && driver_run;
	assign load        = run && pclk1 && !(stall_eff && rw);
	wire   rel_ok_m    = (ph2m | pclk0) & !pclk1;

	function automatic logic [5:0] pick1();
		int r;
		r = rnd(1000);
		if (r < k_ph1_2) return 6'd2;
		if (r < k_ph1_2 + k_ph1_4) return 6'd4;
		if (r < k_ph1_2 + k_ph1_4 + k_str1) return 6'(6 + 1 + rnd(max_str));
		return 6'd6;
	endfunction
	function automatic logic [5:0] pick2();
		int r;
		r = rnd(1000);
		if (r < k_ph2_10) return 6'd10;
		if (r < k_ph2_10 + k_str2) return 6'(6 + 1 + rnd(max_str));
		if (!driver_run && r < k_ph2_10 + k_str2 + k_ph2_4) return 6'd4;
		return 6'd6;
	endfunction

	always @(posedge clk_sys) begin
		logic [5:0] L;
		logic [11:0] lo;
		logic [12:0] na;
		// stall_cycle_taken (top.sv:320-326) and in_phase2
		if (!stall_eff) taken <= 1'b0;
		else if (pclk0) taken <= 1'b1;
		ph2m <= pclk1 ? 1'b0 : (pclk0 ? 1'b1 : ph2m);

		// ibusy: rises at a write commit, falls on rel_ok after its cycles
		if (!ibusy) begin
			if (access && a_in[12] && !rw && pm(k_busy)) begin
				ibusy  <= 1'b1;
				ib_cyc <= busy_min + int'(rnd(busy_max - busy_min + 1));
			end
		end else begin
			if (pclk1 && ib_cyc != 0) ib_cyc <= ib_cyc - 1;
			if (ib_cyc == 0 && rel_ok_m) ibusy <= 1'b0;
		end

		// the bus, at E0
		if (pclk1 && run) begin
			if (stall_eff && rw) begin
				held <= 1'b1;                  // re-present the last address, rw = 1
				d_in <= 8'(rnd(256));
			end else begin
				held <= 1'b0;
				if (EXT_BUS) begin
					a_in <= ext_a;
					rw   <= ext_rw;
					d_in <= ext_d;
				end else begin
					if (pm(k_rep)) na = a_in;
					else begin
						int r;
						r = rnd(1000);
						if (r < k_lo) lo = 12'(rnd(128));
						else if (r < k_lo + k_hi) lo = 12'hFF0 | 12'(rnd(16));
						else lo = 12'(rnd(4096));
						na = {pm(k_a12), lo};
					end
					a_in <= na;
					rw   <= !pm(k_wr);
					d_in <= 8'(rnd(256));
				end
			end
		end

		// the phases
		pclk1 <= 1'b0;
		pclk0 <= 1'b0;
		if (!run) begin
			phase   <= 2'd2;
			cnt     <= 6'(1 + rnd(6));
			pause   <= 1'b0;
			pz_arm  <= 1'b0;
			pz_left <= '0;
		end else if (pz_left != 0) begin       // a paused clock ends here: nothing counts
			pz_left <= pz_left - 8'd1;
			pause   <= (pz_left != 8'd1);
		end else begin
			if (pz_arm && cnt == pz_at) begin  // the next pz_len clocks are paused
				pz_arm  <= 1'b0;
				pz_left <= pz_len;
				pause   <= 1'b1;
			end
			if (cnt > 6'd1) cnt <= cnt - 6'd1;
			else if (phase == 2'd2) begin      // phase 2 ends: pclk1
				L = pick1();
				pclk1  <= 1'b1;
				phase  <= 2'd1;
				cnt    <= L;
				len1   <= L;
				pz_arm <= pm(k_pause1);
				pz_at  <= 6'(2 + rnd(L - 1));     // 2..L: the pause never meets a pulse
				pz_len <= 8'(1 + rnd(max_pause));
			end else begin                     // phase 1 ends: pclk0
				L = pick2();
				pclk0  <= 1'b1;
				phase  <= 2'd2;
				cnt    <= L;
				len2   <= L;
				pz_arm <= pm(k_pause2);
				pz_at  <= 6'(2 + rnd(L - 1));
				pz_len <= 8'(1 + rnd(max_pause));
			end
		end
	end
endmodule

`endif
