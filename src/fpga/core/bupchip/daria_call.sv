//------------------------------------------------------------------------------
// DARIA's call port, the clk_arm side (docs/DARIA_CORE.md, "The memory
// system", 5.2). The front ends (clk_sys) post a call in the state RAM's call
// block and flip call_tog; this launches it into bup_cpu, and when the core
// returns it writes FIQ r8-r13 back into the call block and flips ret_tog.
//
// The call block, state RAM words (the front ends own the rest of the RAM):
//
//   0xF0  entry, bit 0 the T bit      0xF8-0xFA  return counters (r8-r10)
//   0xF1  stack                       0xFB-0xFD  return frequencies (r11-r13)
//   0xF2-0xF4  counter seeds (r8-r10)
//   0xF5-0xF7  frequencies (r11-r13)
//
// Each side touches the block only between the two toggles: the front ends
// write the entry, stack, seeds and frequencies before they flip call_tog,
// and read the return words after they see ret_tog flip.
//
// Launch. call_tog crosses through two flops. A change seen while the core is
// parked reads the entry (one clock), then raises call_go for one clock; the
// core's S_CLEAR writes entries 0-21, one a clock, with clr_e the entry being
// written. clr_wd is a constant (0, or 0xF000_0000 for r14) or the state RAM's
// word, read one clock ahead at the address entry clr_e + 1 maps to. A change
// that comes while the core is not parked waits until it is.
//
// Return. During the readout (ro_valid) each register is written to its
// return word; with the last (returned) ret_tog flips on the next edge, so
// every return word is in the RAM before the front ends can see the flip.
//
// Reset (rst: the CPU held or a mapper reset): the pending launch is dropped
// (call_seen takes the synchronised toggle), so a call posted before the reset
// never runs; ret_tog keeps its value, and the front ends' side does the same
// with ret_tog (5.2, "Reset").
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_call (
	input  wire         clk,            // clk_arm
	input  wire         rst,            // the CPU held, or a mapper reset (clk_arm)
	input  wire         call_tog,       // from the front ends (clk_sys)
	output logic        ret_tog = 1'b0, // to the front ends

	// bup_cpu.
	input  wire         parked,
	output logic        call_go,
	input  wire   [4:0] clr_e,
	output logic [31:0] clr_wd,
	output logic [31:0] clr_pc = 32'd0,
	input  wire         ro_valid,
	input  wire   [2:0] ro_idx,
	input  wire  [31:0] ro_data,
	input  wire         returned,

	// State RAM port A (daria_mem.sv).
	output logic  [7:0] sta_addr,
	output logic        sta_we,
	output logic [31:0] sta_wd,
	input  wire  [31:0] sta_q
);
	localparam logic [7:0] CB = 8'hF0;	// the call block

	logic [1:0] tog_s = 2'b00;
	logic       call_seen = 1'b0;
	logic       loading = 1'b0;         // reading the entry: call_go next clock
	logic       launching = 1'b0;       // between call_go and the last entry
	wire        pending = tog_s[1] != call_seen;

	// The state RAM word that holds entry e of the launch (0: a constant).
	function automatic logic [7:0] word_of(input logic [4:0] e);
		case (e)
			5'd13:               word_of = CB + 8'd1;
			5'd16, 5'd17, 5'd18: word_of = CB + 8'd2 + 8'(e - 5'd16);
			5'd19, 5'd20, 5'd21: word_of = CB + 8'd5 + 8'(e - 5'd19);
			default:             word_of = 8'd0;
		endcase
	endfunction

	always_comb begin
		sta_we = 1'b0;
		sta_wd = ro_data;
		sta_addr = launching ? word_of(clr_e + 5'd1) : CB;
		if (call_go) sta_addr = word_of(5'd0);		// entry 1's word, read at entry 0
		if (ro_valid) begin
			sta_we = 1'b1;
			sta_addr = CB + 8'd8 + {5'd0, ro_idx};
		end
		case (clr_e)
			5'd14:   clr_wd = 32'hF000_0000;
			5'd13, 5'd16, 5'd17, 5'd18, 5'd19, 5'd20, 5'd21: clr_wd = sta_q;
			default: clr_wd = 32'd0;
		endcase
	end

	always_ff @(posedge clk) begin
		tog_s <= {tog_s[0], call_tog};
		call_go <= 1'b0;
		if (rst) begin
			call_seen <= tog_s[1];
			loading <= 1'b0;
			launching <= 1'b0;
		end else begin
			if (loading) begin
				clr_pc <= sta_q;			// the entry, read at CB last clock
				call_go <= 1'b1;
				loading <= 1'b0;
				launching <= 1'b1;
			end else if (parked && pending && !launching) begin
				call_seen <= tog_s[1];
				loading <= 1'b1;
			end
			if (launching && clr_e == 5'd21) launching <= 1'b0;
			if (returned) ret_tog <= ~ret_tog;
		end
	end
endmodule

`default_nettype wire
