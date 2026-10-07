//------------------------------------------------------------------------------
// DARIA front end: the combinational decode of one 6507 cycle
// (docs/daria_fe/design.md 2.2), instantiated as u_core.u_dec. It transcribes
// mapper_dpcplus.sv:226-254 and mapper_cdf.sv:79-157: the op class (dec_t,
// jok = 0 here; the core forms it in k[1]), the replica of upstream's
// sel_ram_sel (sel_up), and the image byte address of the mirror (rom_a).
// Every input is live: romb is the mirror's byte in this clock, the state is
// the core's registers.
//
// STEP 0 HEADER: the ports are frozen (docs/daria_fe/interfaces.md); every
// output is tied off. Lane A fills the body.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_dec (
	// bus
	input  wire  [12:0] a_in,
	input  wire         rw,
	input  wire         access,
	input  wire   [7:0] romb,       // feb_q[8*lane_q +: 8]: upstream's rom_do in every clock
	// scheme
	input  wire         is_dpc,
	input  wire         is_cdf,
	input  wire         jplus,      // CDFJ+ (is_cdf & revision == 3)
	input  wire         jrev,       // CDFJ or CDFJ+ (is_cdf & revision >= 2)
	input  wire         ldx,        // detect2600 cdf_ldx
	input  wire         ldy,        // detect2600 cdf_ldy
	input  wire         foff_en,    // fetch offset enable
	input  wire   [7:0] foff,       // fetch offset
	// state (the core's registers)
	input  wire   [2:0] bank,       // step 0 (interfaces.md S0-5): rom_a needs it
	input  wire         ff_en,      // DPC+ fast fetch enabled
	input  wire         fpend,      // fast fetch pending (both schemes)
	input  wire  [12:0] fexp,       // CDF expected fetch address
	input  wire   [1:0] jr,         // CDF jump operands to go
	input  wire  [12:0] jexp,       // CDF expected jump operand address
	input  wire   [5:0] jstream,    // CDF jump stream
	input  wire   [7:0] mode,       // CDF SETMODE
	// decode
	output daria_fe_pkg::dec_t dec, // comb, jok = 0
	output logic        sel_up,     // comb: (is_dpc & d_sel) | (is_cdf & c_sel)
	output logic [14:0] rom_a       // comb: image byte offset of the mirror (< $8000)
);
	assign dec    = '0;             // stub
	assign sel_up = 1'b0;           // stub
	assign rom_a  = 15'h0000;       // stub
endmodule

`default_nettype wire
