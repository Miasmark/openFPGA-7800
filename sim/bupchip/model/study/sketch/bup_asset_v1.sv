// Asset window read path for the proposed Pocket BupChip (scratch sketch).
// Two 16-byte stream-buffer slots, critical-halfword-first demand fills,
// next-line prefetch in the direction of travel.  Behind it: one halfword
// read port to the PSRAM controller (hw_req/hw_addr -> hw_valid/hw_data).
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_asset #(
	parameter bit WIDE = 0          // 1: both PSRAM chips in lockstep, 32 bits per access
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        ce,
	input  logic [21:0] asset_size,   // bytes captured; reads beyond return 0
	// CPU side (bup_cpu eb_* while eb_addr is in the asset window)
	input  logic        req,
	input  logic [21:0] addr,         // byte offset into the ARSC block
	input  logic  [1:0] size,         // 0 byte, 1 half, 2 word
	output logic        ack,
	output logic [31:0] rdata,        // aligned word, lane-correct
	// PSRAM side
	output logic        hw_req,       // level; accepted when hw_ready
	output logic [20:0] hw_addr,      // halfword address
	input  logic        hw_ready,
	input  logic        hw_valid,     // one pulse per completed read
	input  logic [31:0] hw_data
);
	// ---------------------------------------------------------------- storage
	logic [15:0] lo [0:7], hi [0:7];  // [slot*4 + word]  (MLAB, async read)
	logic [17:0] tag   [0:1];
	logic  [7:0] hval  [0:1];
	logic        tval  [0:1];
	logic        mru;
	logic        dir_up;
	logic [21:0] last_addr;
	logic [17:0] last_line;

	wire [17:0] line = addr[21:4];
	wire  [2:0] hwi  = addr[3:1];
	wire  [1:0] wi   = addr[3:2];
	wire hit0 = tval[0] && tag[0] == line;
	wire hit1 = tval[1] && tag[1] == line;
	wire hs   = hit1;                      // slot holding the line
	wire hit  = hit0 || hit1;              // (added for tb_cpu.sv's statistics)
	wire [7:0] hv = hs ? hval[1] : hval[0];
	wire need_lo = hv[{wi, 1'b0}], need_hi = hv[{wi, 1'b1}];
	// only the halfword(s) the access touches must have arrived
	wire ready_now = (hit0 || hit1) && (size == 2'd2 ? (need_lo && need_hi) : addr[1] ? need_hi : need_lo);
	wire oob = addr >= asset_size;

	assign ack   = req && (oob || ready_now);
	assign rdata = oob ? 32'b0 : {hi[{hs, wi}], lo[{hs, wi}]};

	// ---------------------------------------------------------------- fill engine
	logic        f_act, f_inflight, f_up;
	logic        f_slot;
	logic [17:0] f_line;
	logic  [2:0] f_hw, f_left;
	localparam logic [2:0] STEP = WIDE ? 3'd2 : 3'd1, LAST = WIDE ? 3'd1 : 3'd0, TOP = WIDE ? 3'd6 : 3'd7;
	wire         want_demand = req && !oob && !(hit0 || hit1);
	wire  [17:0] f_next = f_up ? f_line + 18'd1 : f_line - 18'd1;
	wire         mru_n = (req && !oob && (hit0 || hit1)) ? hs : mru;
	wire  [17:0] pf_line = dir_up ? line + 18'd1 : line - 18'd1;
	wire         other = !hs;
	wire         pf_have = tval[other] && tag[other] == pf_line;

	assign hw_req  = f_act && !f_inflight && !want_demand;   // never launch under a retarget
	assign hw_addr = {f_line, f_hw};

	always_ff @(posedge clk) begin
		if (rst) begin
			tval[0] <= 1'b0; tval[1] <= 1'b0; hval[0] <= '0; hval[1] <= '0; last_line <= '0;
			f_act <= 1'b0; f_inflight <= 1'b0; mru <= 1'b0; dir_up <= 1'b1; last_addr <= '0;
		end else if (ce) begin
			if (hw_req && hw_ready) f_inflight <= 1'b1;
			if (hw_valid) begin
				f_inflight <= 1'b0;
				if (tval[f_slot] && tag[f_slot] == f_line) begin
					if (WIDE) begin
						lo[{f_slot, f_hw[2:1]}] <= hw_data[15:0];
						hi[{f_slot, f_hw[2:1]}] <= hw_data[31:16];
						hval[f_slot][{f_hw[2:1], 1'b0}] <= 1'b1;
						hval[f_slot][{f_hw[2:1], 1'b1}] <= 1'b1;
					end else begin
						if (f_hw[0]) hi[{f_slot, f_hw[2:1]}] <= hw_data[15:0];
						else         lo[{f_slot, f_hw[2:1]}] <= hw_data[15:0];
						hval[f_slot][f_hw] <= 1'b1;
					end
				end
				f_hw   <= f_up ? f_hw + STEP : f_hw - STEP;
				f_left <= f_left - STEP;
				if (f_left == LAST) begin
					f_act <= 1'b0;
					// keep streaming: fetch the following line into the other slot
					if (!(tval[!f_slot] && tag[!f_slot] == f_next) && f_slot == mru_n) begin
						tag[!f_slot] <= f_next; tval[!f_slot] <= 1'b1; hval[!f_slot] <= '0;
						f_slot <= !f_slot; f_line <= f_next; f_hw <= f_up ? 3'd0 : TOP;
						f_left <= 3'd7; f_act <= 1'b1;
					end
				end
			end
			// a demand miss retargets the engine once nothing is in flight
			if (want_demand && !(f_inflight && !hw_valid)) begin
				if (f_act && f_slot == mru) tval[mru] <= 1'b0;   // never leave a partial line behind
				tag[!mru] <= line; tval[!mru] <= 1'b1; hval[!mru] <= '0;
				f_slot <= !mru; f_line <= line; f_hw <= WIDE ? {hwi[2:1], 1'b0} : hwi; f_left <= 3'd7; f_act <= 1'b1; f_up <= dir_up;
			end else if (req && !oob && (hit0 || hit1)) begin
				mru <= hs;
				// prefetch the next line into the other slot when the engine is free
				if (!pf_have && !f_act && !want_demand) begin
					tag[other] <= pf_line; tval[other] <= 1'b1; hval[other] <= '0;
					f_slot <= other; f_line <= pf_line; f_hw <= dir_up ? 3'd0 : TOP;
					f_left <= 3'd7; f_act <= 1'b1; f_up <= dir_up;
				end
			end
			if (ack && !oob) begin
				last_line <= line;
				// direction only from moves to an adjacent line (not voice switches)
				if (line == last_line + 18'd1) dir_up <= 1'b1;
				else if (line == last_line - 18'd1) dir_up <= 1'b0;
			end
		end
	end
endmodule
