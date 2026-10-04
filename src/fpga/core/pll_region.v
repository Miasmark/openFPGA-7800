//------------------------------------------------------------------------------
// PAL / NTSC master clock: retunes pll_core through altera_pll_reconfig
//
// NTSC and PAL differ only in the PLL's fractional multiplier (pll_core.v), so
// every output keeps its ratio and phase. On a region change this writes the
// new fraction (register 7) and starts a reconfiguration (register 2).
//
// - Runs on a clock the PLL does not generate (clk_74a).
// - Never starts while a data slot is loading: the region comes from the A78
//   header, which is parsed partway through the cart download, and stopping
//   clk_sdram then would drop bytes.
// - busy is raised 256 clocks (~3.4 us, ~50 clk_sys cycles) before the
//   reconfiguration starts, so the core, whose reset is a clk_sys register,
//   is in reset before clk_sys stops; and it stays up 256 clocks after the
//   PLL has locked again, so the core sees its reset with clk_sys running.
// - The PLL powers up as NTSC (its built-in fraction), so nothing is written
//   until the region is PAL.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module pll_region
(
	input  wire        clk,
	input  wire        is_pal,           // asynchronous (clk_sys)
	input  wire        loading,
	input  wire        pll_locked,       // synchronised to clk
	output reg         busy,

	input  wire        cfg_waitrequest,
	output reg         cfg_write,
	output reg  [5:0]  cfg_address,
	output reg  [31:0] cfg_writedata
);
	// Power-up values. Quartus ignores an initializer on an output port
	// declaration and, with Power-Up Don't Care, may pick either level.
	initial busy = 1'b0;
	initial cfg_write = 1'b0;
	initial cfg_address = 6'd0;
	initial cfg_writedata = 32'd0;
	// clk_sys = 74.25 * (9 + K/2^32) / 48 MHz
	localparam [31:0] FRAC_NTSC = 32'd1100363522;   // 14.3181818 MHz
	localparam [31:0] FRAC_PAL  = 32'd737741760;    // 14.1875800 MHz

	reg  [1:0] pal_s = 2'b00;
	reg        pll_pal = 1'b0;           // what the PLL is set to
	reg        target = 1'b0;
	reg  [2:0] step = 3'd0;
	reg  [7:0] wait_cnt = 8'd0;

	always @(posedge clk) begin
		pal_s     <= {pal_s[0], is_pal};
		cfg_write <= 1'b0;

		if (!busy) begin
			if (!loading && pal_s[1] != pll_pal) begin
				busy     <= 1'b1;
				target   <= pal_s[1];
				step     <= 3'd0;
				wait_cnt <= 8'd0;
			end
		end else begin
			case (step)
			3'd0: begin                          // let the core see its reset
				wait_cnt <= wait_cnt + 1'd1;
				if (&wait_cnt) step <= 3'd1;
			end
			3'd1: if (!cfg_waitrequest) begin    // fractional M
				cfg_address   <= 6'd7;
				cfg_writedata <= target ? FRAC_PAL : FRAC_NTSC;
				cfg_write     <= 1'b1;
				step          <= 3'd2;
			end
			3'd2: if (!cfg_waitrequest && !cfg_write) begin  // start
				cfg_address   <= 6'd2;
				cfg_writedata <= 32'd0;
				cfg_write     <= 1'b1;
				step          <= 3'd3;
				wait_cnt      <= 8'd0;
			end
			3'd3: begin                          // reconfigured and locked again
				if (!(&wait_cnt))
					wait_cnt <= wait_cnt + 1'd1;
				else if (!cfg_waitrequest && !cfg_write && pll_locked) begin
					step     <= 3'd4;
					wait_cnt <= 8'd0;
				end
			end
			default: begin                       // clk_sys runs, core still in reset
				wait_cnt <= wait_cnt + 1'd1;
				if (&wait_cnt) begin
					pll_pal <= target;
					busy    <= 1'b0;
				end
			end
			endcase
		end
	end

endmodule
