//------------------------------------------------------------------------------
// tb_fe_audio_probe: daria_fe_audio as the core synthesises it, for the area
// probe of design 10.3 (lane B; docs/daria_fe/lanes/B_audio.md, "Area"). The
// bench merge hook (hk_en, hk_stb, hk_ret) is tied 0, as daria_fe's instance
// in atari7800_pocket will tie it (design 1.2: "Tied 0 in synthesis; constant
// propagation removes the hook paths"); every other port passes through. A
// probe of daria_fe_audio alone keeps the hook (192 + 2 free inputs); this
// one is the block's cost inside the core.
//
//   EXTRA_SRCS=sim/bupchip/daria/fe_unit/tb_fe_audio_probe.v \
//     flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh tb_fe_audio_probe --fit
//
// Not a bench: run_unit.sh builds tb_fe_*.sv only.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module tb_fe_audio_probe (
	input  wire          clk_sys,
	input  wire          cart_reset,
	input  wire          pause,
	input  wire    [1:0] fam,
	input  wire    [1:0] rev,
	input  wire   [31:0] rom_size,
	input  wire          ram32,
	input  wire   [15:0] asz,
	input  wire          cdf_dig,
	input  wire    [6:0] wave0,
	input  wire    [6:0] wave1,
	input  wire    [6:0] wave2,
	input  wire          note_stb,
	input  wire    [1:0] note_v,
	input  wire    [7:0] note_val,
	input  wire          cp_cap,
	input  wire          cp_rot,
	input  wire          cp_shin,
	input  wire          cp_cmp,
	input  wire          cp_apply,
	input  wire          mwin,
	output wire          aud_issue,
	output wire   [14:0] aud_addr,
	input  wire          aud_take,
	input  wire   [31:0] crb_q,
	input  wire   [31:0] stb_q,
	output wire          aud_a_req,
	output wire   [12:0] aud_a_a,
	input  wire          aud_a_gnt,
	input  wire   [31:0] fea_q,
	output wire          smp_req,
	output wire   [18:0] smp_addr,
	input  wire          smp_ack,
	input  wire    [7:0] smp_data,
	output wire    [7:0] amp_nx,
	output wire   [31:0] ring0
);
	daria_fe_audio u_audio (
		.clk_sys(clk_sys), .cart_reset(cart_reset), .pause(pause), .fam(fam), .rev(rev),
		.rom_size(rom_size), .ram32(ram32), .asz(asz), .cdf_dig(cdf_dig),
		.wave0(wave0), .wave1(wave1), .wave2(wave2),
		.note_stb(note_stb), .note_v(note_v), .note_val(note_val),
		.cp_cap(cp_cap), .cp_rot(cp_rot), .cp_shin(cp_shin), .cp_cmp(cp_cmp), .cp_apply(cp_apply),
		.mwin(mwin), .hk_en(1'b0), .hk_stb(1'b0), .hk_ret(192'd0),
		.aud_issue(aud_issue), .aud_addr(aud_addr), .aud_take(aud_take), .crb_q(crb_q), .stb_q(stb_q),
		.aud_a_req(aud_a_req), .aud_a_a(aud_a_a), .aud_a_gnt(aud_a_gnt), .fea_q(fea_q),
		.smp_req(smp_req), .smp_addr(smp_addr), .smp_ack(smp_ack), .smp_data(smp_data),
		.amp_nx(amp_nx), .ring0(ring0));
endmodule

`default_nettype wire
