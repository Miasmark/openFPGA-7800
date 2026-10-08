// Area probe of daria_fe as the core will synthesise it: the bench-only
// merge hook (hk_en, hk_stb, hk_ret) tied to 0, every other port passed
// through. Used by daria_fe_map.sh with EXTRA_SRCS (docs/daria_fe/design.md
// 10.3); not part of the core.
// SPDX-License-Identifier: MIT
`default_nettype none
module daria_fe_probe (
	input  wire         clk_sys, clk_arm, cart_reset, pause,
	input  wire  [12:0] a_in,
	input  wire   [7:0] d_in,
	input  wire         rw, pclk1, pclk0, access,
	input  wire   [5:0] scheme,
	input  wire   [2:0] revision,
	input  wire         cdf_ldx, cdf_ldy, fetch_off_en,
	input  wire   [7:0] fetch_off,
	input  wire  [31:0] cdfj_entry, cdfj_stack,
	input  wire  [15:0] audio_size_addr,
	input  wire  [31:0] rom_size,
	input  wire         ram32, load_start, load_end, cart_win, cpu_ready, ret_tog,
	output wire         call_tog, smp_req,
	output wire  [18:0] smp_addr,
	input  wire         smp_ack,
	input  wire   [7:0] smp_data,
	output wire   [7:0] fe_do,
	output wire         fe_oe, arm_call_busy, arm_dma_busy, init_busy,
	output wire  [12:0] fea_addr,
	input  wire  [31:0] fea_q,
	output wire  [12:0] feb_addr,
	input  wire  [31:0] feb_q,
	output wire  [12:0] crb_addr,
	output wire         crb_we,
	output wire   [3:0] crb_be,
	output wire  [31:0] crb_wd,
	input  wire  [31:0] crb_q,
	output wire   [7:0] stb_addr,
	output wire         stb_we,
	output wire   [3:0] stb_be,
	output wire  [31:0] stb_wd,
	input  wire  [31:0] stb_q
);
	daria_fe u_fe (.*, .hk_en(1'b0), .hk_stb(1'b0), .hk_ret(192'd0));
endmodule
`default_nettype wire
