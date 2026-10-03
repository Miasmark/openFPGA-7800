// Whole Pocket BupChip, for area estimation (scratch sketch).
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
module bup_pocket #(
	parameter ROM_HEX = "bupchip.hex",
	parameter bit WIDE = 0
) (
	input  logic        clk_sys,
	input  logic        clk_arm,      // 2 x clk_sys (pll_core counter[3], C=24)
	input  logic        clk_74a,
	input  logic        enabled,      // souper_profile (clk_sys)
	input  logic        pause,        // pause_core (clk_sys)
	input  logic        load_start, load_valid, load_end,
	input  logic [24:0] load_addr,
	input  logic  [7:0] load_data,
	input  logic        cmd_valid_sys,
	input  logic  [7:0] cmd_data_sys,
	output logic [15:0] audio_l, audio_r,
	output logic        dbg_underflow, dbg_halted,
	output logic [21:16] cram_a,
	output logic [31:0] dq_out,
	output logic        dq_oe,
	input  logic [31:0] dq_in,
	output logic        cram_adv_n, cram_ce0_n, cram_oe_n, cram_we_n,
	output logic  [3:0] cram_be_n
);
	localparam int PCM_DEPTH = 1024;
	// ------------------------------------------------ capture and levels into clk_arm
	logic [21:0] asset_size;
	logic        asset_ready;
	logic        cwr_req, cwr_ready; logic [21:0] cwr_addr; logic [31:0] cwr_data; logic [3:0] cwr_be;
	bup_capture cap (.clk_sys, .load_start, .load_addr, .load_valid, .load_data, .load_end,
		.asset_size, .asset_ready, .clk_arm, .wr_req(cwr_req), .wr_addr(cwr_addr), .wr_data(cwr_data),
		.wr_be(cwr_be), .wr_ready(cwr_ready));
	logic [1:0] rdy_s, en_s, pz_s;
	always_ff @(posedge clk_arm) begin
		rdy_s <= {rdy_s[0], asset_ready}; en_s <= {en_s[0], enabled}; pz_s <= {pz_s[0], pause};
	end
	wire rst_arm = !(rdy_s[1] && en_s[1]);
	wire run     = !pz_s[1];

	// ------------------------------------------------ CPU
	logic eb_valid, eb_we, eb_ack, halted; logic [31:0] eb_addr, eb_wdata, eb_rdata; logic [1:0] eb_size;
	bup_cpu #(.ROM_HEX(ROM_HEX)) cpu (.clk(clk_arm), .rst(rst_arm), .ce(run), .eb_valid, .eb_addr, .eb_we,
		.eb_wdata, .eb_size, .eb_ack, .eb_rdata, .halted);
	assign dbg_halted = halted;
	wire is_mmio  = eb_addr[31:28] == 4'hE;

	// ------------------------------------------------ assets
	logic a_ack; logic [31:0] a_rdata;
	logic hreq, hready, hvalid; logic [20:0] haddr; logic [31:0] hdata;
	bup_asset #(.WIDE(WIDE)) ast (.clk(clk_arm), .rst(rst_arm), .ce(run), .asset_size,
		.req(eb_valid && !is_mmio), .addr(eb_addr[21:0]), .size(eb_size), .ack(a_ack), .rdata(a_rdata),
		.hw_req(hreq), .hw_addr(haddr), .hw_ready(hready), .hw_valid(hvalid), .hw_data(hdata));
	bup_psram #(.WIDE(WIDE)) ps (.clk(clk_arm), .rst(1'b0),
		.rd_req(hreq), .rd_addr({1'b0, haddr}), .rd_ready(hready), .rd_valid(hvalid), .rd_data(hdata),
		.wr_req(cwr_req), .wr_addr(cwr_addr), .wr_data(cwr_data), .wr_be(cwr_be), .wr_ready(cwr_ready),
		.cram_a, .dq_out, .dq_oe, .dq_in, .cram_adv_n, .cram_ce0_n, .cram_oe_n, .cram_we_n, .cram_be_n);

	// ------------------------------------------------ command crossing (toggle)
	logic ctog; logic [7:0] cbyte; logic [2:0] cs;
	always_ff @(posedge clk_sys) if (cmd_valid_sys) begin ctog <= !ctog; cbyte <= cmd_data_sys; end
	always_ff @(posedge clk_arm) cs <= {cs[1:0], ctog};
	wire cmd_valid = cs[2] != cs[1];

	// ------------------------------------------------ 48 kHz tick from clk_74a (exact: 74.25 MHz * 8 / 12375)
	logic [13:0] acc; logic ttog; logic [2:0] ts;
	always_ff @(posedge clk_74a) begin
		if (acc >= 14'd12367) begin acc <= acc - 14'd12367; ttog <= !ttog; end
		else acc <= acc + 14'd8;
	end
	always_ff @(posedge clk_arm) ts <= {ts[1:0], ttog};
	wire tick = ts[2] != ts[1];

	// ------------------------------------------------ peripheral (reused unmodified) + watermark remap
	logic [31:0] reg_rdata, wd_eff, pcm_frame; logic pcm_avail, pcm_en, muted; logic [7:0] fault;
	always_comb begin
		wd_eff = eb_wdata;
		if (eb_addr[7:0] == 8'h18)
			wd_eff[28:16] = (eb_wdata[28:16] > 13'(4096 - PCM_DEPTH)) ? eb_wdata[28:16] - 13'(4096 - PCM_DEPTH) : 13'd0;
	end
	wire pop = tick && run && pcm_en;
	bupchip_peripheral #(.CMD_DEPTH(8), .PCM_DEPTH(PCM_DEPTH)) per (.clk(clk_arm), .reset(rst_arm),
		.cmd_valid, .cmd_data(cbyte), .reg_sel(eb_valid && is_mmio && run), .reg_addr(eb_addr[7:0]),
		.reg_write(eb_we), .reg_wdata(wd_eff), .reg_rdata, .pcm_pop(pop), .pcm_frame,
		.pcm_available(pcm_avail), .pcm_enabled(pcm_en), .muted, .fault_code(fault));
	assign eb_ack   = eb_valid && (is_mmio || a_ack);
	assign eb_rdata = is_mmio ? reg_rdata : a_rdata;
	always_ff @(posedge clk_arm) if (pop && !pcm_avail) dbg_underflow <= 1'b1;

	// ------------------------------------------------ frame back to clk_sys
	logic [31:0] frame_arm; logic ftog; logic [2:0] fs;
	always_ff @(posedge clk_arm) if (tick) begin
		frame_arm <= (pcm_avail && !muted && !rst_arm) ? pcm_frame : 32'b0; ftog <= !ftog;
	end
	always_ff @(posedge clk_sys) begin
		fs <= {fs[1:0], ftog};
		if (fs[2] != fs[1]) begin audio_l <= frame_arm[15:0]; audio_r <= frame_arm[31:16]; end
	end
endmodule
