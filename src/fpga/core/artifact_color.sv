// Artifact colour without a composite decoder (the Palette setting's
// "Artifact" choices).
//
// In MARIA's 320 modes a pixel is half a cycle of the NTSC colour carrier, so
// a light/dark alternation of single pixels is a signal at the carrier's own
// frequency, and a TV decodes it as colour (Tower Toppler's tower, drawn as
// one-pixel stripes, is solid blue on a TV). Composite (composite_out and
// composite_decoder) reproduces the TV, blur included. This is the idealised
// version Apple II emulators offer beside their NTSC filter (AppleWin's RGB
// monitor rules; the trackstar-clone repository's colour table, notes
// atf1508/F6 2.2, uses the same rules): find the alternation in the RGB
// picture and colour only it, leaving everything else sharp.
//
// Per pixel c, with neighbours l, r and their luma (Y = 0.30R + 0.59G +
// 0.11B):
//   - brighter than both neighbours by more than TH (a lone lit pixel), or
//   - darker than both, where one of the two is itself a lone lit pixel (the
//     dark half of a stripe pattern; a one-pixel gap in a run stays a gap),
// becomes
//     (2c + l + r) / 4  +  s * (Yc - (Yl + Yr) / 2) * V
// with s = +1 / -1 by the pixel's column parity against the carrier. Both
// halves of a stripe pair give the same colour, so stripes fill solid; a lone
// lit pixel takes one hue on even columns and the complement on odd ones, as
// on an Apple II. V is one RGB vector, fitted to composite_decoder's picture
// of Tower Toppler (2026-11-07, hue 320 degrees, gain 0.25 in YIQ).
// Everything else is the RGB pixel unchanged.
//
// The window is five pixels (the dark rule looks two away), so the picture
// comes out two pixels late: the sync and blanking flags are delayed by the
// same 2 pixels (DELAY clk_sys at MARIA's 2 clk_sys per pixel). Pixels with
// keep_in set (the light gun's crosshair) pass unchanged.
module artifact_color #(
	parameter integer TH = 24,                // luma step that counts, of 255
	parameter signed [8:0] VR = 9'sd21,       // V in 256ths
	parameter signed [8:0] VG = 9'sd13,
	parameter signed [8:0] VB = -9'sd124,
	parameter bit EVEN_POS = 1'b1,            // s = +1 on the column parity that hs leaves at 0
	parameter integer DELAY = 5               // clk_sys: 2 pixels and the output register
)(
	input  logic       clk,
	input  logic       ce,         // one pixel (MARIA: every other clk)
	input  logic [7:0] r_in, g_in, b_in,
	input  logic       keep_in,
	input  logic       hs_in, vs_in, hb_in, vb_in,
	output logic [7:0] r_out, g_out, b_out,
	output logic       hs_out, vs_out, hb_out, vb_out, ce_out
);

// Luma of the incoming pixel, kept beside it in the window
wire [15:0] y_in16 = 16'd77 * r_in + 16'd150 * g_in + 16'd29 * b_in;
wire  [7:0] y_in   = y_in16[15:8];

// Window: [0] newest (x+2) ... [4] oldest (x-2); [2] is the pixel computed
logic [7:0] wr [4:1], wg [4:1], wb [4:1], wy [4:1];
logic       wk [4:1];
wire  [7:0] cr = wr[2], cg = wg[2], cb = wb[2];
wire  [7:0] lr = wr[3], lg = wg[3], lb = wb[3];
wire  [7:0] rr = wr[1], rg = wg[1], rb = wb[1];
wire signed [9:0] yc  = {2'd0, wy[2]};
wire signed [9:0] yl  = {2'd0, wy[3]};
wire signed [9:0] yr  = {2'd0, wy[1]};
wire signed [9:0] yll = {2'd0, wy[4]};
wire signed [9:0] yrr = {2'd0, y_in};

wire bright = (yc - yl > TH) && (yc - yr > TH);
wire dark   = (yl - yc > TH) && (yr - yc > TH) &&
              ((yl - yll > TH) || (yr - yrr > TH));

// Column parity of the newest pixel; the computed one is two before it, so
// the same parity
logic par = 1'b0;
logic hs_d = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire signed [10:0] d2 = {yc, 1'b0} - yl - yr;            // 2 (Yc - mean)
wire signed [10:0] dd = (par ^ EVEN_POS) ? d2 : -d2;     // s * 2 (Yc - mean)
wire signed [20:0] ar = dd * VR;                         // 512ths
wire signed [20:0] ag = dd * VG;
wire signed [20:0] ab = dd * VB;
/* verilator lint_on UNUSEDSIGNAL */

function automatic [7:0] mix(input [7:0] c, input [7:0] l, input [7:0] r,
                             input signed [20:0] a);
	logic signed [21:0] s;
	begin
		// (2c + l + r) / 4 in 512ths, plus a, rounded
		s = $signed({12'd0, c, 1'b0} + {12'd0, l} + {12'd0, r}) * 128 + a + 22'sd256;
		mix = (s < 0) ? 8'd0 : (s >= 22'sd130560) ? 8'd255 : s[16:9];
	end
endfunction

logic [DELAY-1:0] hs_p = '0, vs_p = '0, hb_p = '1, vb_p = '1, ce_p = '0;

always_ff @(posedge clk) begin
	hs_p <= {hs_p[DELAY-2:0], hs_in};
	vs_p <= {vs_p[DELAY-2:0], vs_in};
	hb_p <= {hb_p[DELAY-2:0], hb_in};
	vb_p <= {vb_p[DELAY-2:0], vb_in};
	ce_p <= {ce_p[DELAY-2:0], ce};
	hs_d <= hs_in;
	if (hs_in && !hs_d) par <= 1'b0;
	if (ce) begin
		{wr[4], wr[3], wr[2], wr[1]} <= {wr[3], wr[2], wr[1], r_in};
		{wg[4], wg[3], wg[2], wg[1]} <= {wg[3], wg[2], wg[1], g_in};
		{wb[4], wb[3], wb[2], wb[1]} <= {wb[3], wb[2], wb[1], b_in};
		{wy[4], wy[3], wy[2], wy[1]} <= {wy[3], wy[2], wy[1], y_in};
		{wk[4], wk[3], wk[2], wk[1]} <= {wk[3], wk[2], wk[1], keep_in};
		if (!(hs_in && !hs_d)) par <= ~par;
		if ((bright || dark) && !wk[2]) begin
			r_out <= mix(cr, lr, rr, ar);
			g_out <= mix(cg, lg, rg, ag);
			b_out <= mix(cb, lb, rb, ab);
		end else begin
			r_out <= cr; g_out <= cg; b_out <= cb;
		end
	end
end

assign hs_out = hs_p[DELAY-1];
assign vs_out = vs_p[DELAY-1];
assign hb_out = hb_p[DELAY-1];
assign vb_out = vb_p[DELAY-1];
assign ce_out = ce_p[DELAY-1];

endmodule
