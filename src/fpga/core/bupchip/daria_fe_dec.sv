//------------------------------------------------------------------------------
// DARIA front end: the combinational decode of one 6507 cycle
// (docs/daria_fe/design.md 2.2), instantiated as u_core.u_dec. It transcribes
// mapper_dpcplus.sv:226-254 and mapper_cdf.sv:79-157: the op class (dec_t,
// jok = 0 here; the core forms it in k[1]), the replica of upstream's
// sel_ram_sel (sel_up), and the image byte address of the mirror (rom_a).
// Every input is live: romb is the mirror's byte in this clock, the state is
// the core's registers.
//
// sel_up feeds only the audio grant (design 3.1); the unit bench compares it
// with upstream's sel_ram_sel on every clock (A2). The DPC+ classes are set
// only with is_dpc, the CDF classes only with is_cdf, so a non-ARM scheme
// decodes to no class at all.
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
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire   [7:0] mode,       // CDF SETMODE ([7:4], the digital flag, is the core's)
	/* verilator lint_on UNUSEDSIGNAL */
	// decode
	output daria_fe_pkg::dec_t dec, // comb, jok = 0
	output logic        sel_up,     // comb: (is_dpc & d_sel) | (is_cdf & c_sel)
	output logic [14:0] rom_a       // comb: image byte offset of the mirror (< $8000)
);
	wire [11:0] a   = a_in[11:0];
	wire        a12 = a_in[12];

	// ---- DPC+ (mapper_dpcplus.sv:112-181, 227-322) ------------------------------------
	wire        a_lo   = a < 12'h028;                                  // the register file $000-$027
	wire        d_reg  = rw & a12 & (a_lo | (ff_en & fpend & (romb < 8'h28)));   // register_read
	wire  [5:0] d_rn   = a_lo ? a[5:0] : romb[5:0];                     // 6 bits (DPC §14.12)
	wire  [2:0] d_ix   = d_rn[2:0];
	wire  [2:0] d_fn   = d_rn[5:3];
	wire        d_wreg = !rw & a12 & !a_lo & (a < 12'h080);             // the write groups $028-$07F
	/* verilator lint_off UNUSEDSIGNAL */
	wire [11:0] d_gw   = a - 12'h028;                                   // [6:3] is the group
	/* verilator lint_on UNUSEDSIGNAL */
	wire  [3:0] d_g    = d_gw[6:3];                                     // 0..10 inside d_wreg
	wire        d_f13  = (d_fn == 3'd1) | (d_fn == 3'd2) | (d_fn == 3'd3);
	wire        d_hot  = a12 & !d_reg & (a >= 12'hFF6) & (a <= 12'hFFB);
	wire        d_psh  = ((a >= 12'h060) & (a < 12'h068)) | ((a >= 12'h078) & (a < 12'h080));
	wire        d_sel  = (d_reg & d_f13) | (!rw & a12 & d_psh);        // ram_sel (:136-158)
	wire        g6     = d_g == 4'd6;
	wire        g9     = d_g == 4'd9;
	wire  [2:0] a3     = a[2:0];

	// ---- CDF family (mapper_cdf.sv:77-157) ---------------------------------------------
	wire        fast_mode = mode[3:0] == 4'h0;
	wire  [5:0] amp_s  = jrev ? 6'd35 : 6'd34;                          // amplitude_stream
	wire        arms   = (romb == 8'hA9) | (jplus & ldx & (romb == 8'hA2)) | (jplus & ldy & (romb == 8'hA0));
	wire  [8:0] flim   = {1'b0, foff} + {3'b0, amp_s};                  // fetch_limit
	wire        in_rng = foff_en ? ((romb >= foff) & ({1'b0, romb} <= flim)) : (romb <= {2'b0, amp_s});
	/* verilator lint_off UNUSEDSIGNAL */
	wire  [7:0] norm   = foff_en ? (romb - foff) : romb;                // normalized_operand ([5:0] used)
	/* verilator lint_on UNUSEDSIGNAL */
	wire  [5:0] amp_op = foff_en ? (amp_s + foff[5:0]) : amp_s;         // amplitude_operand (6-bit)
	wire        jvalid = ((jr == 2'd2) & (jrev ? (romb[7:1] == 7'd0) : (romb == 8'd0))) |
	                     ((jr == 2'd1) & (romb == 8'd0));
	wire        c_jmp  = rw & a12 & (jr != 2'd0) & (a_in == jexp) & jvalid;
	wire        c_fet  = rw & a12 & fast_mode & fpend & (a_in == fexp) & in_rng;
	wire        c_sub  = c_jmp | c_fet;
	wire        c_amp  = c_fet & !c_jmp & (romb[5:0] == amp_op);
	wire  [5:0] c_idx  = c_jmp ? (jstream + {5'd0, jrev & (jr == 2'd2) & romb[0]}) : norm[5:0];
	wire        c_hot  = a12 & !c_sub & (a >= 12'hFF4) & (a <= 12'hFFB);
	wire        c_dsw  = !rw & (a_in == 13'h1FF0);
	wire        c_sel  = (c_sub & !c_amp) | (access & c_dsw);           // ram_en (:140-156)

	// ---- the replica of upstream's sel_ram_sel (cart2600.sv:191, 965) -------------------
	assign sel_up = (is_dpc & d_sel) | (is_cdf & c_sel);

	// ---- the op class (one-hot; design 2.2's table) ------------------------------------
	always_comb begin
		dec          = '0;
		// DPC+
		dec.c.rom    = (is_dpc & rw & a12 & !d_reg) | (is_cdf & rw & a12 & !c_sub);
		dec.c.rrnd   = is_dpc & d_reg & (d_fn == 3'd0) & (d_ix != 3'd5);
		dec.c.amp    = (is_dpc & d_reg & (d_fn == 3'd0) & (d_ix == 3'd5)) | (is_cdf & c_amp);
		dec.c.rdat   = is_dpc & d_reg & d_f13;
		dec.c.rflg   = is_dpc & d_reg & (d_fn == 3'd4);
		dec.c.dfld   = is_dpc & d_wreg & ((d_g <= 4'd5) | (d_g == 4'd8));
		dec.c.dpw    = is_dpc & d_wreg & ((d_g == 4'd7) | (d_g == 4'd10));
		dec.c.dpar   = is_dpc & d_wreg & g6 & (a3 == 3'd1);
		dec.c.dcf    = is_dpc & d_wreg & g6 & (a3 == 3'd2);
		dec.c.dmisc  = is_dpc & d_wreg & ((g6 & ((a3 == 3'd0) | (a3 >= 3'd5))) | g9);
		// CDF
		dec.c.cfet   = is_cdf & c_fet & !c_jmp & !c_amp;
		dec.c.cjmp   = is_cdf & c_jmp;
		dec.c.cdsw   = is_cdf & c_dsw;
		dec.c.cdsp   = is_cdf & !rw & (a_in == 13'h1FF1);
		dec.c.cmode  = is_cdf & !rw & (a_in == 13'h1FF2);
		dec.c.ccall  = is_cdf & !rw & (a_in == 13'h1FF3);
		// attributes
		dec.hot      = (is_dpc & d_hot) | (is_cdf & c_hot);
		dec.ix       = d_ix;
		dec.fn       = d_fn;
		dec.g        = d_g;
		dec.idx      = c_idx;
		dec.arms     = arms;
		dec.b4c      = romb == 8'h4C;
		dec.jok      = 1'b0;                                            // formed in k[1] by the core
		dec.romb0    = romb[0];
		dec.a9       = romb == 8'hA9;
	end

	// ---- the mirror's image byte address (always < $8000) -------------------------------
	// DPC+ <= $6BFF, CDF <= $7FFF, CDFJ+ <= $77FF.
	assign rom_a = (is_dpc ? 15'h0C00 : (jplus ? 15'h0800 : 15'h1000)) + {bank, 12'h000} + {3'b000, a};
endmodule

`default_nettype wire
