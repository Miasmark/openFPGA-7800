// Asset window read path for the proposed Pocket BupChip (scratch sketch), v2.
// Two 16-byte lines, direct-mapped by line address bit 0, so line L+1 always
// lands in the other slot: a demand miss fills critical-halfword-first, and
// the next line (forward only) is prefetched into the other slot after a
// demand fill or on any hit.  PSRAM port: one halfword (WIDE=0) or one
// 32-bit word from both chips (WIDE=1) per request.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_asset #(
	parameter bit WIDE = 0
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        ce,
	input  logic [21:0] asset_size,   // bytes captured; reads beyond return 0
	input  logic        req,
	input  logic [21:0] addr,         // byte offset into the ARSC block
	input  logic  [1:0] size,         // 0 byte, 1 half, 2 word
	output logic        ack,
	output logic [31:0] rdata,
	output logic        hw_req,
	output logic [20:0] hw_addr,      // halfword address
	input  logic        hw_ready,
	input  logic        hw_valid,
	input  logic [31:0] hw_data
);
	localparam logic [2:0] STEP = WIDE ? 3'd2 : 3'd1;
	logic [15:0] lo [0:7], hi [0:7];  // {slot, word}  (MLAB)
	logic [16:0] tag  [0:1];          // line[17:1]
	logic        tval [0:1];
	logic  [7:0] hval [0:1];

	wire [17:0] line = addr[21:4];
	wire        s    = line[0];
	wire  [1:0] wi   = addr[3:2];
	wire        hit  = tval[s] && tag[s] == line[17:1];
	wire  [7:0] hv   = hval[s];
	wire        have = size == 2'd2 ? (hv[{wi, 1'b0}] && hv[{wi, 1'b1}]) : hv[addr[3:1]];
	wire        oob  = addr >= asset_size;
	assign ack   = req && (oob || (hit && have));
	assign rdata = oob ? 32'b0 : {hi[{s, wi}], lo[{s, wi}]};

	// fill engine: one line at a time
	logic        f_act, f_infl, f_dem;   // f_dem: the line being filled is the CPU's own
	logic [17:0] f_line;
	logic  [2:0] f_hw, f_cnt;
	wire         miss   = req && !oob && !hit;
	wire  [17:0] nline  = (req ? line : f_line) + 18'd1;   // the line after the one in use
	wire         n_have = tval[nline[0]] && tag[nline[0]] == nline[17:1];
	assign hw_req  = f_act && !f_infl && !miss;
	assign hw_addr = {f_line, f_hw};

	always_ff @(posedge clk) begin
		if (rst) begin
			tval[0] <= 1'b0; tval[1] <= 1'b0; f_act <= 1'b0; f_infl <= 1'b0;
		end else if (ce) begin
			if (hw_req && hw_ready) f_infl <= 1'b1;
			if (hw_valid) begin
				f_infl <= 1'b0;
				if (WIDE) begin
					lo[{f_line[0], f_hw[2:1]}] <= hw_data[15:0];
					hi[{f_line[0], f_hw[2:1]}] <= hw_data[31:16];
					hval[f_line[0]][{f_hw[2:1], 1'b0}] <= 1'b1;
					hval[f_line[0]][{f_hw[2:1], 1'b1}] <= 1'b1;
				end else begin
					if (f_hw[0]) hi[{f_line[0], f_hw[2:1]}] <= hw_data[15:0];
					else         lo[{f_line[0], f_hw[2:1]}] <= hw_data[15:0];
					hval[f_line[0]][f_hw] <= 1'b1;
				end
				f_hw  <= f_hw + STEP;
				f_cnt <= f_cnt - STEP;
				if (f_cnt < STEP) begin                            // line complete
					f_act <= 1'b0;
					if (f_dem && !miss && !n_have) begin           // after a demand fill: prefetch the next line
						tag[nline[0]] <= nline[17:1]; tval[nline[0]] <= 1'b1; hval[nline[0]] <= '0;
						f_line <= nline; f_hw <= 3'd0; f_cnt <= 3'd7; f_act <= 1'b1; f_dem <= 1'b0;
					end
				end
			end
			if (miss && !(f_infl && !hw_valid)) begin              // demand: critical halfword first
				if (f_act && f_line[0] != s) tval[f_line[0]] <= 1'b0;   // drop an unfinished prefetch
				tag[s] <= line[17:1]; tval[s] <= 1'b1; hval[s] <= '0;
				f_line <= line; f_hw <= WIDE ? {addr[3:2], 1'b0} : addr[3:1]; f_cnt <= 3'd7; f_act <= 1'b1; f_dem <= 1'b1;
			end else if (req && hit && !f_act && !n_have) begin       // hit: prefetch the next line
				tag[nline[0]] <= nline[17:1]; tval[nline[0]] <= 1'b1; hval[nline[0]] <= '0;
				f_line <= nline; f_hw <= 3'd0; f_cnt <= 3'd7; f_act <= 1'b1; f_dem <= 1'b0;
			end
		end
	end
endmodule
