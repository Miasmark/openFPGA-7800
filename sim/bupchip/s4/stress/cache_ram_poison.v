//------------------------------------------------------------------------------
// Simulation-only stand-in for src/fpga/mister/rtl/cache_ram.v for the step 4
// stress benches: the same four modules and ports (copied from cache_ram.v's
// simulation models, Copyright (c) 2026 Jamie Blanks, MIT), but a mixed-port
// read-during-write returns garbage instead of the old data.
//
// On the device the M10Ks are instantiated with two clock ports
// (cache_ram_tdp_dc, cache_ram_tdp_dc_be) or as BIDIR_DUAL_PORT
// (cache_ram_dp), and a read on one port registered on the same edge as a
// write to the same address on the other port is undefined: for a byte-enable
// write the whole word (docs/BUPCHIP_CORE.md, "Memory map and timing per
// region"). cache_ram.v's models return the old word there, which hides a
// client that relies on it. Here such a read returns the inverted old word
// (cache_ram_tdp_dc_be, cache_ram_dp), so any use of it shows up as wrong
// data; cache_ram_tdp_dc (tags, the PCM FIFO) returns the inverted old word,
// the old word or the new one at random (+poison_tdp), so a valid bit can
// come back either way and a testbench that watches the ports sees a client
// complete on it. Same-port read-during-write keeps cache_ram.v's new-data
// behaviour. Every poisoned read is counted in n_poison
// (read it hierarchically). Compile this file instead of cache_ram.v.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

module cache_ram
#(
	parameter ADDR_WIDTH = 7,
	parameter DATA_WIDTH = 32,
	/* verilator lint_off UNUSEDPARAM */
	parameter MEM_INIT_FILE = " ",
	parameter SIM_INIT_FILE = " ",
	parameter DEVICE_FAMILY = "Cyclone V",
	parameter LPM_HINT = "ENABLE_RUNTIME_MOD=NO"
	/* verilator lint_on UNUSEDPARAM */
)
(
	input  wire                  clk_i,
	input  wire [ADDR_WIDTH-1:0] addr_i,
	input  wire                  wren_i,
	input  wire [DATA_WIDTH-1:0] wdata_i,
	output wire [DATA_WIDTH-1:0] q_o
);
	localparam NUM_WORDS = (1 << ADDR_WIDTH);
	reg [DATA_WIDTH-1:0] q_out;
	reg [DATA_WIDTH-1:0] mem_q [0:NUM_WORDS-1];
	integer init_i;
	initial for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1) mem_q[init_i] = {DATA_WIDTH{1'b0}};
	always @(posedge clk_i) begin
		if (wren_i) mem_q[addr_i] <= wdata_i;
		q_out <= wren_i ? wdata_i : mem_q[addr_i];
	end
	assign q_o = q_out;
endmodule

module cache_ram_tdp_dc
#(
	parameter ADDR_WIDTH = 7,
	parameter DATA_WIDTH = 8,
	/* verilator lint_off UNUSEDPARAM */
	parameter MEM_INIT_FILE = " ",
	parameter DEVICE_FAMILY = "Cyclone V",
	parameter SIM_INIT_FILE = " "
	/* verilator lint_on UNUSEDPARAM */
)
(
	input  wire                  clk_a_i,
	input  wire [ADDR_WIDTH-1:0] addr_a_i,
	input  wire                  wren_a_i,
	input  wire [DATA_WIDTH-1:0] wdata_a_i,
	output wire [DATA_WIDTH-1:0] q_a_o,
	input  wire                  clk_b_i,
	input  wire [ADDR_WIDTH-1:0] addr_b_i,
	input  wire                  wren_b_i,
	input  wire [DATA_WIDTH-1:0] wdata_b_i,
	output wire [DATA_WIDTH-1:0] q_b_o
);
	localparam NUM_WORDS = (1 << ADDR_WIDTH);
	reg [DATA_WIDTH-1:0] q_a_out;
	reg [DATA_WIDTH-1:0] q_b_out;
	reg [DATA_WIDTH-1:0] mem_q [0:NUM_WORDS-1];
	integer init_i;
	integer n_poison = 0;
	// What a collided read returns (+poison_tdp=N): 0 the inverted old word,
	// 1 the old word (cache_ram.v's), 2 the new one, 3 (default) one of the
	// three at random each time. Only the inverted word is sure to be wrong;
	// the others let a client that completes on such a read go on, for a
	// testbench that watches the ports to catch.
	integer mode = 3;
	initial begin
		for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1) mem_q[init_i] = {DATA_WIDTH{1'b0}};
		if ($value$plusargs("poison_tdp=%d", mode)) ;
	end
	function [DATA_WIDTH-1:0] garbage(input [DATA_WIDTH-1:0] old_w, input [DATA_WIDTH-1:0] new_w);
		integer m;
		begin
			m = mode == 3 ? $urandom_range(2) : mode;
			garbage = m == 0 ? ~old_w : m == 1 ? old_w : new_w;
		end
	endfunction
	// Both clocks are one clock in every use; the other port's inputs are
	// read as they stand at this edge.
	wire col_a = !wren_a_i && wren_b_i && addr_b_i == addr_a_i;
	wire col_b = !wren_b_i && wren_a_i && addr_a_i == addr_b_i;
	always @(posedge clk_a_i) begin
		if (wren_a_i) mem_q[addr_a_i] <= wdata_a_i;
		q_a_out <= wren_a_i ? wdata_a_i : col_a ? garbage(mem_q[addr_a_i], wdata_b_i) : mem_q[addr_a_i];
		if (col_a) n_poison = n_poison + 1;
	end
	always @(posedge clk_b_i) begin
		if (wren_b_i) mem_q[addr_b_i] <= wdata_b_i;
		q_b_out <= wren_b_i ? wdata_b_i : col_b ? garbage(mem_q[addr_b_i], wdata_a_i) : mem_q[addr_b_i];
		if (col_b) n_poison = n_poison + 1;
	end
	assign q_a_o = q_a_out;
	assign q_b_o = q_b_out;
endmodule

module cache_ram_tdp_dc_be
#(
	parameter ADDR_WIDTH = 6,
	parameter DATA_WIDTH = 32,
	/* verilator lint_off UNUSEDPARAM */
	parameter DEVICE_FAMILY = "Cyclone V"
	/* verilator lint_on UNUSEDPARAM */
)
(
	input  wire                         clk_a_i,
	input  wire        [ADDR_WIDTH-1:0] addr_a_i,
	input  wire                         wren_a_i,
	input  wire [(DATA_WIDTH/8)-1:0]    byteena_a_i,
	input  wire        [DATA_WIDTH-1:0] wdata_a_i,
	output wire        [DATA_WIDTH-1:0] q_a_o,
	input  wire                         clk_b_i,
	input  wire        [ADDR_WIDTH-1:0] addr_b_i,
	input  wire                         wren_b_i,
	input  wire [(DATA_WIDTH/8)-1:0]    byteena_b_i,
	input  wire        [DATA_WIDTH-1:0] wdata_b_i,
	output wire        [DATA_WIDTH-1:0] q_b_o
);
	localparam NUM_WORDS = (1 << ADDR_WIDTH);
	localparam NUM_BYTES = DATA_WIDTH / 8;
	reg [DATA_WIDTH-1:0] q_a_out;
	reg [DATA_WIDTH-1:0] q_b_out;
	reg [DATA_WIDTH-1:0] mem_q [0:NUM_WORDS-1];
	integer init_i, byte_a, byte_b;
	integer n_poison = 0;
	initial for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1) mem_q[init_i] = {DATA_WIDTH{1'b0}};
	// A write with any byte enabled makes the whole word undefined for the
	// other port's read on that edge.
	wire col_a = !wren_a_i && wren_b_i && addr_b_i == addr_a_i;
	wire col_b = !wren_b_i && wren_a_i && addr_a_i == addr_b_i;
	always @(posedge clk_a_i) begin
		if (wren_a_i)
			for (byte_a = 0; byte_a < NUM_BYTES; byte_a = byte_a + 1)
				if (byteena_a_i[byte_a]) mem_q[addr_a_i][byte_a*8 +: 8] <= wdata_a_i[byte_a*8 +: 8];
		q_a_out <= wren_a_i ? wdata_a_i : col_a ? ~mem_q[addr_a_i] : mem_q[addr_a_i];
		if (col_a) n_poison = n_poison + 1;
	end
	always @(posedge clk_b_i) begin
		if (wren_b_i)
			for (byte_b = 0; byte_b < NUM_BYTES; byte_b = byte_b + 1)
				if (byteena_b_i[byte_b]) mem_q[addr_b_i][byte_b*8 +: 8] <= wdata_b_i[byte_b*8 +: 8];
		q_b_out <= wren_b_i ? wdata_b_i : col_b ? ~mem_q[addr_b_i] : mem_q[addr_b_i];
		if (col_b) n_poison = n_poison + 1;
	end
	assign q_a_o = q_a_out;
	assign q_b_o = q_b_out;
endmodule

module cache_ram_dp
#(
	parameter ADDR_WIDTH = 7,
	parameter DATA_WIDTH = 32,
	/* verilator lint_off UNUSEDPARAM */
	parameter MEM_INIT_FILE = " ",
	parameter DEVICE_FAMILY = "Cyclone V",
	parameter SIM_INIT_FILE = " "
	/* verilator lint_on UNUSEDPARAM */
)
(
	input  wire                  clk_i,
	input  wire [ADDR_WIDTH-1:0] addr_a_i,
	input  wire                  wren_a_i,
	input  wire [DATA_WIDTH-1:0] wdata_a_i,
	output wire [DATA_WIDTH-1:0] q_a_o,
	input  wire [ADDR_WIDTH-1:0] addr_b_i,
	input  wire                  wren_b_i,
	input  wire [DATA_WIDTH-1:0] wdata_b_i,
	output wire [DATA_WIDTH-1:0] q_b_o
);
	localparam NUM_WORDS = (1 << ADDR_WIDTH);
	reg [DATA_WIDTH-1:0] q_a_out;
	reg [DATA_WIDTH-1:0] q_b_out;
	reg [DATA_WIDTH-1:0] mem_q [0:NUM_WORDS-1];
	integer init_i;
	integer n_poison = 0;
	initial for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1) mem_q[init_i] = {DATA_WIDTH{1'b0}};
	wire col_a = !wren_a_i && wren_b_i && addr_b_i == addr_a_i;
	wire col_b = !wren_b_i && wren_a_i && addr_a_i == addr_b_i;
	always @(posedge clk_i) begin
		if (wren_a_i) mem_q[addr_a_i] <= wdata_a_i;
		q_a_out <= wren_a_i ? wdata_a_i : col_a ? ~mem_q[addr_a_i] : mem_q[addr_a_i];
		if (wren_b_i) mem_q[addr_b_i] <= wdata_b_i;
		q_b_out <= wren_b_i ? wdata_b_i : col_b ? ~mem_q[addr_b_i] : mem_q[addr_b_i];
		if (col_a || col_b) n_poison = n_poison + 1;
	end
	assign q_a_o = q_a_out;
	assign q_b_o = q_b_out;
endmodule
