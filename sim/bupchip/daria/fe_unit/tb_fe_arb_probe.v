//------------------------------------------------------------------------------
// tb_fe_arb_probe: daria_fe_arb between two rows of clk_sys registers, for
// the timing probe of lane D (docs/daria_fe/lanes/D_arb_guard.md, "Area and
// timing"). Alone on virtual pins the block has no register-to-register path
// (its one register, crb_use, is fed from pins); here every input is a
// register and every output is registered, as in daria_fe, where the
// requests come from registers or M10K q and the outputs go to the M10K
// address and data registers. Only the setup slack is read from this probe;
// the area is daria_fe_arb's own probe (the wrapper's registers are not the
// block's).
//
//   EXTRA_SRCS=sim/bupchip/daria/fe_unit/tb_fe_arb_probe.v \
//     flock /tmp/daria_quartus.lock sim/bupchip/quartus_probe/daria_fe_map.sh tb_fe_arb_probe --fit
//
// Not a bench: run_unit.sh builds tb_fe_*.sv only.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module tb_fe_arb_probe (
	input  wire  clk_sys,
	input  wire  cr_fix,
	input  wire  [12:0] cr_fix_a,
	input  wire  cr_fix_we,
	input  wire  [3:0] cr_fix_be,
	input  wire  [31:0] cr_fix_wd,
	input  wire  cr_fix_use,
	input  wire  cr_p32,
	input  wire  [12:0] cr_p32_a,
	input  wire  cr_wb,
	input  wire  [12:0] cr_wb_a,
	input  wire  [31:0] cr_wb_wd,
	input  wire  cs_req,
	input  wire  [7:0] cs_a,
	input  wire  cs_we,
	input  wire  [3:0] cs_be,
	input  wire  [31:0] cs_wd,
	input  wire  look_req,
	input  wire  [12:0] look_a,
	input  wire  aud_issue,
	input  wire  [14:0] aud_addr,
	input  wire  aud_a_req,
	input  wire  [12:0] aud_a_a,
	input  wire  cl_req,
	input  wire  [7:0] cl_a,
	input  wire  cl_we,
	input  wire  [31:0] cl_wd,
	input  wire  cp_req,
	input  wire  [12:0] cp_a,
	input  wire  cp_we,
	input  wire  [3:0] cp_be,
	input  wire  [31:0] cp_wd,
	input  wire  cz_req,
	input  wire  [7:0] cz_a,
	input  wire  ca_req,
	input  wire  [12:0] ca_a,
	input  wire  sel_up,
	input  wire  guard_on,
	input  wire  phb_next,
	input  wire  f6_act,
	input  wire  ev_short,
	input  wire  [7:0] k,
	input  wire  commit,
	input  daria_fe_pkg::dec_t op,
	input  wire  p32_q,
	input  wire  rdP,
	input  wire  wb_v,
	input  wire  ev_guard_sup,
	output logic [12:0] fea_addr,
	output logic [12:0] crb_addr,
	output logic crb_we,
	output logic [3:0] crb_be,
	output logic [31:0] crb_wd,
	output logic [7:0] stb_addr,
	output logic stb_we,
	output logic [3:0] stb_be,
	output logic [31:0] stb_wd,
	output logic aud_take,
	output logic p32_gnt,
	output logic wb_gnt,
	output logic cp_gnt,
	output logic cl_gnt,
	output logic look_gnt,
	output logic aud_a_gnt,
	output logic ca_gnt,
	output logic crb_use
);
	// the input row
	logic  cr_fix_q;
	logic [12:0]  cr_fix_a_q;
	logic  cr_fix_we_q;
	logic [3:0]  cr_fix_be_q;
	logic [31:0]  cr_fix_wd_q;
	logic  cr_fix_use_q;
	logic  cr_p32_q;
	logic [12:0]  cr_p32_a_q;
	logic  cr_wb_q;
	logic [12:0]  cr_wb_a_q;
	logic [31:0]  cr_wb_wd_q;
	logic  cs_req_q;
	logic [7:0]  cs_a_q;
	logic  cs_we_q;
	logic [3:0]  cs_be_q;
	logic [31:0]  cs_wd_q;
	logic  look_req_q;
	logic [12:0]  look_a_q;
	logic  aud_issue_q;
	logic [14:0]  aud_addr_q;
	logic  aud_a_req_q;
	logic [12:0]  aud_a_a_q;
	logic  cl_req_q;
	logic [7:0]  cl_a_q;
	logic  cl_we_q;
	logic [31:0]  cl_wd_q;
	logic  cp_req_q;
	logic [12:0]  cp_a_q;
	logic  cp_we_q;
	logic [3:0]  cp_be_q;
	logic [31:0]  cp_wd_q;
	logic  cz_req_q;
	logic [7:0]  cz_a_q;
	logic  ca_req_q;
	logic [12:0]  ca_a_q;
	logic  sel_up_q;
	logic  guard_on_q;
	logic  phb_next_q;
	logic  f6_act_q;
	logic  ev_short_q;
	logic [7:0]  k_q;
	logic  commit_q;
	daria_fe_pkg::dec_t op_q;
	logic  p32_q_q;
	logic  rdP_q;
	logic  wb_v_q;
	logic  ev_guard_sup_q;
	always_ff @(posedge clk_sys) begin
		cr_fix_q <= cr_fix;
		cr_fix_a_q <= cr_fix_a;
		cr_fix_we_q <= cr_fix_we;
		cr_fix_be_q <= cr_fix_be;
		cr_fix_wd_q <= cr_fix_wd;
		cr_fix_use_q <= cr_fix_use;
		cr_p32_q <= cr_p32;
		cr_p32_a_q <= cr_p32_a;
		cr_wb_q <= cr_wb;
		cr_wb_a_q <= cr_wb_a;
		cr_wb_wd_q <= cr_wb_wd;
		cs_req_q <= cs_req;
		cs_a_q <= cs_a;
		cs_we_q <= cs_we;
		cs_be_q <= cs_be;
		cs_wd_q <= cs_wd;
		look_req_q <= look_req;
		look_a_q <= look_a;
		aud_issue_q <= aud_issue;
		aud_addr_q <= aud_addr;
		aud_a_req_q <= aud_a_req;
		aud_a_a_q <= aud_a_a;
		cl_req_q <= cl_req;
		cl_a_q <= cl_a;
		cl_we_q <= cl_we;
		cl_wd_q <= cl_wd;
		cp_req_q <= cp_req;
		cp_a_q <= cp_a;
		cp_we_q <= cp_we;
		cp_be_q <= cp_be;
		cp_wd_q <= cp_wd;
		cz_req_q <= cz_req;
		cz_a_q <= cz_a;
		ca_req_q <= ca_req;
		ca_a_q <= ca_a;
		sel_up_q <= sel_up;
		guard_on_q <= guard_on;
		phb_next_q <= phb_next;
		f6_act_q <= f6_act;
		ev_short_q <= ev_short;
		k_q <= k;
		commit_q <= commit;
		op_q <= op;
		p32_q_q <= p32_q;
		rdP_q <= rdP;
		wb_v_q <= wb_v;
		ev_guard_sup_q <= ev_guard_sup;
	end

	// the block
	logic [12:0] fea_addr_c;
	logic [12:0] crb_addr_c;
	logic crb_we_c;
	logic [3:0] crb_be_c;
	logic [31:0] crb_wd_c;
	logic [7:0] stb_addr_c;
	logic stb_we_c;
	logic [3:0] stb_be_c;
	logic [31:0] stb_wd_c;
	logic aud_take_c;
	logic p32_gnt_c;
	logic wb_gnt_c;
	logic cp_gnt_c;
	logic cl_gnt_c;
	logic look_gnt_c;
	logic aud_a_gnt_c;
	logic ca_gnt_c;
	logic crb_use_c;
	daria_fe_arb u_arb (
		.clk_sys(clk_sys),
		.cr_fix(cr_fix_q),
		.cr_fix_a(cr_fix_a_q),
		.cr_fix_we(cr_fix_we_q),
		.cr_fix_be(cr_fix_be_q),
		.cr_fix_wd(cr_fix_wd_q),
		.cr_fix_use(cr_fix_use_q),
		.cr_p32(cr_p32_q),
		.cr_p32_a(cr_p32_a_q),
		.cr_wb(cr_wb_q),
		.cr_wb_a(cr_wb_a_q),
		.cr_wb_wd(cr_wb_wd_q),
		.cs_req(cs_req_q),
		.cs_a(cs_a_q),
		.cs_we(cs_we_q),
		.cs_be(cs_be_q),
		.cs_wd(cs_wd_q),
		.look_req(look_req_q),
		.look_a(look_a_q),
		.aud_issue(aud_issue_q),
		.aud_addr(aud_addr_q),
		.aud_a_req(aud_a_req_q),
		.aud_a_a(aud_a_a_q),
		.cl_req(cl_req_q),
		.cl_a(cl_a_q),
		.cl_we(cl_we_q),
		.cl_wd(cl_wd_q),
		.cp_req(cp_req_q),
		.cp_a(cp_a_q),
		.cp_we(cp_we_q),
		.cp_be(cp_be_q),
		.cp_wd(cp_wd_q),
		.cz_req(cz_req_q),
		.cz_a(cz_a_q),
		.ca_req(ca_req_q),
		.ca_a(ca_a_q),
		.sel_up(sel_up_q),
		.guard_on(guard_on_q),
		.phb_next(phb_next_q),
		.f6_act(f6_act_q),
		.ev_short(ev_short_q),
		.k(k_q),
		.commit(commit_q),
		.op(op_q),
		.p32_q(p32_q_q),
		.rdP(rdP_q),
		.wb_v(wb_v_q),
		.ev_guard_sup(ev_guard_sup_q),
		.fea_addr(fea_addr_c),
		.crb_addr(crb_addr_c),
		.crb_we(crb_we_c),
		.crb_be(crb_be_c),
		.crb_wd(crb_wd_c),
		.stb_addr(stb_addr_c),
		.stb_we(stb_we_c),
		.stb_be(stb_be_c),
		.stb_wd(stb_wd_c),
		.aud_take(aud_take_c),
		.p32_gnt(p32_gnt_c),
		.wb_gnt(wb_gnt_c),
		.cp_gnt(cp_gnt_c),
		.cl_gnt(cl_gnt_c),
		.look_gnt(look_gnt_c),
		.aud_a_gnt(aud_a_gnt_c),
		.ca_gnt(ca_gnt_c),
		.crb_use(crb_use_c)
	);

	// the output row
	always_ff @(posedge clk_sys) begin
		fea_addr <= fea_addr_c;
		crb_addr <= crb_addr_c;
		crb_we <= crb_we_c;
		crb_be <= crb_be_c;
		crb_wd <= crb_wd_c;
		stb_addr <= stb_addr_c;
		stb_we <= stb_we_c;
		stb_be <= stb_be_c;
		stb_wd <= stb_wd_c;
		aud_take <= aud_take_c;
		p32_gnt <= p32_gnt_c;
		wb_gnt <= wb_gnt_c;
		cp_gnt <= cp_gnt_c;
		cl_gnt <= cl_gnt_c;
		look_gnt <= look_gnt_c;
		aud_a_gnt <= aud_a_gnt_c;
		ca_gnt <= ca_gnt_c;
		crb_use <= crb_use_c;
	end
endmodule

`default_nettype wire
