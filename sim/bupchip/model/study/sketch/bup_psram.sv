// Asynchronous-mode PSRAM controller for the Pocket BupChip asset window
// (scratch sketch, NOT verified at pin level).  AS1C8M16PL-70 on the Pocket:
// A[21:16] on cram_a, A[15:0] multiplexed on DQ and latched by ADV#.
// One die (CE0#).  WIDE=1 drives cram0 and cram1 in lockstep (32 bits).
// At 28.636 MHz (34.92 ns):  read  = idle, ADV, ADV-high, OE, capture = 5 clk
//                             write = ADV, ADV-high, WE, WE, release   = 5 clk
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_psram #(
	parameter bit WIDE = 0
) (
	input  logic        clk,
	input  logic        rst,
	// read port (asset unit)
	input  logic        rd_req,
	input  logic [21:0] rd_addr,      // halfword address in the die
	output logic        rd_ready,
	output logic        rd_valid,
	output logic [31:0] rd_data,
	// write port (capture, while the CPU is held)
	input  logic        wr_req,
	input  logic [21:0] wr_addr,
	input  logic [31:0] wr_data,
	input  logic  [3:0] wr_be,
	output logic        wr_ready,
	// pins (both chips; cram1 unused when !WIDE)
	output logic [21:16] cram_a,
	output logic [31:0] dq_out,
	output logic        dq_oe,
	input  logic [31:0] dq_in,        // registered in the I/O cell (FAST_INPUT_REGISTER)
	output logic        cram_adv_n,
	output logic        cram_ce0_n,
	output logic        cram_oe_n,
	output logic        cram_we_n,
	output logic  [3:0] cram_be_n     // {ub1, lb1, ub0, lb0}
);
	typedef enum logic [2:0] {I, A0, A1, R0, R1, W0, W1, W2} st_t;
	st_t st;
	logic wr;
	assign rd_ready = st == I && !wr_req;
	assign wr_ready = st == I;
	always_ff @(posedge clk) begin
		rd_valid <= 1'b0;
		if (rst) begin
			st <= I; cram_ce0_n <= 1'b1; cram_adv_n <= 1'b1; cram_oe_n <= 1'b1; cram_we_n <= 1'b1;
			dq_oe <= 1'b0; cram_be_n <= 4'hF;
		end else case (st)
			I: if (wr_req || rd_req) begin
				wr <= wr_req;
				cram_a <= wr_req ? wr_addr[21:16] : rd_addr[21:16];
				dq_out <= {2{wr_req ? wr_addr[15:0] : rd_addr[15:0]}};
				dq_oe <= 1'b1; cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0;
				cram_be_n <= wr_req ? ~wr_be : 4'h0;
				if (wr_req) rd_data <= wr_data;    // park write data
				st <= A0;
			end
			A0: begin cram_adv_n <= 1'b1; st <= A1; end            // address latched, held on DQ
			A1: if (wr) begin dq_out <= rd_data; cram_we_n <= 1'b0; st <= W0; end
			    else begin dq_oe <= 1'b0; cram_oe_n <= 1'b0; st <= R0; end
			R0: st <= R1;                                           // DQ sampled into the I/O register here
			R1: begin                                               // (tAA 104.7 ns from ADV#, tOE 34.9 ns)
				rd_data <= WIDE ? dq_in : {16'b0, dq_in[15:0]};
				rd_valid <= 1'b1; cram_oe_n <= 1'b1; cram_ce0_n <= 1'b1; st <= I;
			end
			W0: st <= W1;                                           // WE# low 2 clk = 69.8 ns
			W1: begin cram_we_n <= 1'b1; st <= W2; end
			W2: begin dq_oe <= 1'b0; cram_ce0_n <= 1'b1; st <= I; end
			default: st <= I;
		endcase
	end
endmodule
