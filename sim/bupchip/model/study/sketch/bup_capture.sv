// ARSC capture for the Pocket BupChip (scratch sketch, not simulated):
// watches the cartridge download in clk_sys, finds the block after the
// declared ROM size (header bytes 49-52, as bupchip_asset_ddr.sv:82-104 does),
// packs bytes into halfwords and hands them to the PSRAM writer in clk_arm
// (2x clk_sys, same PLL, so the toggle handshake is a timed path).
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_capture (
	input  logic        clk_sys,
	input  logic        load_start,
	input  logic [24:0] load_addr,
	input  logic        load_valid,
	input  logic  [7:0] load_data,
	input  logic        load_end,
	output logic [21:0] asset_size,   // clk_sys level, stable while ready
	output logic        asset_ready,  // clk_sys level: set at load_end, cleared at load_start
	// clk_arm side
	input  logic        clk_arm,
	output logic        wr_req,
	output logic [21:0] wr_addr,      // halfword address
	output logic [31:0] wr_data,
	output logic  [3:0] wr_be,
	input  logic        wr_ready
);
	logic [31:0] declared;
	logic [24:0] start;
	logic [15:0] pend;
	logic  [1:0] pbe;
	logic [21:0] paddr;
	logic        tog;
	wire  [24:0] off = load_addr - start;
	wire         in_block = declared != 0 && load_addr >= start;
	always_ff @(posedge clk_sys) begin
		if (load_start) begin asset_ready <= 1'b0; asset_size <= '0; declared <= '0; pbe <= 2'b00; end
		if (load_valid) begin
			if (load_addr == 25'd49) declared[31:24] <= load_data;
			if (load_addr == 25'd50) declared[23:16] <= load_data;
			if (load_addr == 25'd51) declared[15:8]  <= load_data;
			if (load_addr == 25'd52) begin declared[7:0] <= load_data; start <= 25'd128 + {declared[24:8], load_data}; end
			if (in_block) begin
				if (off[0]) begin pend[15:8] <= load_data; pbe[1] <= 1'b1; end
				else        begin pend[7:0]  <= load_data; pbe[0] <= 1'b1; end
				paddr <= off[22:1];
				asset_size <= off[21:0] + 22'd1;
				if (off[0]) begin tog <= !tog; pbe <= 2'b00; end   // halfword complete
			end
		end
		if (load_end) begin
			asset_ready <= 1'b1;
			if (pbe != 2'b00) begin tog <= !tog; pbe <= 2'b00; end // odd tail byte
		end
	end
	// clk_arm: one PSRAM write per toggle (bytes arrive >= 175 ns apart, so
	// a halfword every >= 350 ns; a write takes 5 x 34.9 ns)
	logic t1, t2;
	logic [1:0] be_hold;
	always_ff @(posedge clk_sys) if (load_valid && in_block) be_hold <= off[0] ? {1'b1, pbe[0]} : 2'b01;
	always_ff @(posedge clk_arm) begin
		t1 <= tog; t2 <= t1;
		if (t1 != t2) begin
			wr_req <= 1'b1; wr_addr <= paddr; wr_data <= {2{pend}}; wr_be <= {be_hold, be_hold};
		end else if (wr_ready) wr_req <= 1'b0;
	end
endmodule
