//------------------------------------------------------------------------------
// The step-7 report's smoke design (run_smoke.sh; docs/daria_step7/plan.md
// 3.5, 5.4 (c), (f), (k), (k')). NOT the core: a few hundred registers whose
// modules and instances carry the core's entity and instance names, four
// levels deep as in the core (core_top:ic|atari7800_pocket:atari|
// bupchip_pocket:bupchip|...), so that core/daria.qip's instance assignments
// and step7_report.tcl's patterns meet the names they meet in a real fit.
// Each clk_sys <-> clk_arm crossing of plan 2.7 is here as a synchroniser or a
// held bus under its RTL name; the logic around them is filler that keeps
// every register alive: each clock's registers reach an output of their own
// (o from clk_sys, oa from clk_arm), so that no other path crosses.
//
// The guard (daria_fe_guard.sv) and the snapshot (bup_dbg_snap.sv) are the
// real files. FujiNet's two channels (fujinet_stage -> bup_asset_wr's
// staging, fujinet_loader -> fujinet_rd) are stand-ins under their RTL
// names, as the rest.
//
// Variants (macros):
//   SMOKE_Q5     BUP_DEBUG's chains (the snapshot's rq_s0/ak_s0): a Q5
//                build, whose expected crossings f3_crossings.txt lists
//   SMOKE_MUT    planted faults, each of which (k') must report:
//                prof_a[0]  samples an XOR of two clk_sys registers (a
//                           two-register cone)
//                ready_s[0] samples parked & img_ready, not ready_a (the
//                           Q-mut bypass of plan 4.3)
//                run_s[0]   samples cpu_run AND a clk_sys register (logic of
//                           its own clock on a first flop without a reset)
//                raw        a clk_sys register sampling frame_arm[3] (an
//                           endpoint plan F3 does not list)
// Not faults, and (k') must pass them: mres_a powers up as 2'b11 from a
// register that powers up as 0 (Quartus inverts the register and puts a NOT
// before it); ram32_a samples an inverted copy through an explicit NOT; the
// "reset" class (sn_a, en_s, w_s) has a synchronous reset of its own clock.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module bup_capture (
	input  wire        clk,                // clk_sys
	input  wire  [7:0] a,
	output logic       msg_tog = 1'b0,
	output logic [3:0] msg_type = 4'd0,
	output logic [7:0] msg_pl = 8'd0
);
	always_ff @(posedge clk)
		if (a[7]) begin
			msg_type <= a[3:0];
			msg_pl <= a;
			msg_tog <= ~msg_tog;
		end
endmodule

module bup_asset_wr (
	input  wire        clk,                // clk_arm
	input  wire        msg_tog,
	input  wire  [3:0] msg_type,
	input  wire  [7:0] msg_pl,
	// FujiNet staging (fujinet_stage, clk_sys): a toggle, the payload held
	input  wire        s_tog,
	input  wire        s_sync,
	input  wire  [1:0] s_lanes,
	input  wire  [7:0] s_haddr,
	input  wire  [7:0] s_data,
	output logic       s_ack = 1'b0,
	output wire  [7:0] q
);
	logic t1 = 1'b0, t2 = 1'b0, seen = 1'b0;
	logic [3:0] m_type = 4'd0;
	logic [7:0] m_pl = 8'd0;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic st1 = 1'b0;
	logic st2 = 1'b0, s_seen = 1'b0, s_t = 1'b0;
	logic [1:0] s_l = 2'd0;
	logic [7:0] s_a = 8'd0, s_d = 8'd0;
	always_ff @(posedge clk) begin
		t1 <= msg_tog;
		t2 <= t1;
		if (t2 != seen) begin
			seen <= t2;
			m_type <= msg_type;
			m_pl <= msg_pl;
		end
		st1 <= s_tog;
		st2 <= st1;
		if (st2 != s_seen) begin
			s_seen <= st2;
			s_t <= s_sync;
			s_l <= s_lanes;
			s_a <= s_haddr;
			s_d <= s_data;
			s_ack <= ~s_ack;
		end
	end
	assign q = m_pl ^ {4'd0, m_type} ^ s_a ^ s_d ^ {5'd0, s_t, s_l};
endmodule

// FujiNet: the swap's reader (core/fujinet_rd.sv, clk_arm): a request
// toggle, the address held; the answer held and a toggle back
module fujinet_rd (
	input  wire        clk,                // clk_arm
	input  wire        l_req,
	input  wire  [7:0] l_haddr,
	output logic       ack = 1'b0,
	output logic [7:0] data = 8'd0
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic req_s0 = 1'b0;
	logic req_s1 = 1'b0;
	logic [7:0] addr = 8'd0;
	always_ff @(posedge clk) begin
		req_s0 <= l_req;
		req_s1 <= req_s0;
		if (req_s1 != ack) begin
			addr <= l_haddr;
			ack <= req_s1;
		end
		data <= addr + 8'd5;
	end
endmodule

// FujiNet staging, the clk_sys side (core/fujinet_stage.sv)
module fujinet_stage (
	input  wire        clk,                // clk_sys
	input  wire  [7:0] a,
	input  wire        s_ack,
	output logic       s_tog = 1'b0,
	output logic       s_sync = 1'b0,
	output logic [1:0] s_lanes = 2'd0,
	output logic [7:0] s_haddr = 8'd0,
	output logic [7:0] s_data = 8'd0,
	output wire        q
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic a1 = 1'b0;
	logic a2 = 1'b0;
	always_ff @(posedge clk) begin
		a1 <= s_ack;
		a2 <= a1;
		if (a2 == s_tog && a[4]) begin
			s_haddr <= a;
			s_data <= ~a;
			s_lanes <= a[1:0];
			s_sync <= a[2];
			s_tog <= ~s_tog;
		end
	end
	assign q = a2;
endmodule

// FujiNet swap, the clk_sys side (core/fujinet_loader.sv)
module fujinet_loader (
	input  wire        clk,                // clk_sys
	input  wire  [7:0] a,
	input  wire        l_ack,
	input  wire  [7:0] l_data,
	output logic       l_req = 1'b0,
	output logic [7:0] l_haddr = 8'd0,
	output wire  [7:0] q
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic ack_s0 = 1'b0;
	logic ack_s1 = 1'b0;
	logic [7:0] hb = 8'd0, nb = 8'd0;
	always_ff @(posedge clk) begin
		ack_s0 <= l_ack;
		ack_s1 <= ack_s0;
		if (ack_s1 == l_req) begin
			hb <= l_data;
			nb <= l_data ^ 8'h3C;
			if (a[3]) begin
				l_haddr <= a;
				l_req <= ~l_req;
			end
		end
	end
	assign q = hb ^ nb;
endmodule

module daria_call (
	input  wire        clk,                // clk_arm
	input  wire        call_tog,           // clk_sys
	output logic       ret_q = 1'b0,
	output wire        q
);
	logic [1:0] tog_s = 2'b00;
	logic call_seen = 1'b0;
	always_ff @(posedge clk) begin
		tog_s <= {tog_s[0], call_tog};
		if (tog_s[1] != call_seen) begin
			call_seen <= tog_s[1];
			ret_q <= ~ret_q;
		end
	end
	assign q = call_seen;
endmodule

module daria_mmio (
	input  wire        clk_arm,
	input  wire        rst_arm,
	input  wire  [7:0] a,
	input  wire        clk_sys,
	input  wire        rst_sys,
	output wire  [7:0] q_sys,
	output wire  [7:0] q_arm
);
	// clk_sys -> clk_arm: the snapshot toggle and its held word
	logic       sn_tog = 1'b0;
	logic [7:0] hold = 8'd0;
	always_ff @(posedge clk_sys)
		if (a[6]) begin
			hold <= a;
			sn_tog <= ~sn_tog;
		end
	logic [1:0] sn_a = 2'b00;
	logic       sn_seen = 1'b0;
	logic [7:0] mirror = 8'd0;
	always_ff @(posedge clk_arm) begin
		sn_a <= {sn_a[0], sn_tog};
		if (sn_a[1] != sn_seen) begin
			sn_seen <= sn_a[1];
			mirror <= hold;
		end
		if (rst_arm) sn_a <= 2'b00;
	end
	// clk_arm -> clk_sys: TCR bit 0, and the write toggle with its held word
	logic [1:0] tcr = 2'b00;
	logic       w_tog = 1'b0;
	logic [7:0] w_data = 8'd0;
	always_ff @(posedge clk_arm) begin
		tcr <= {tcr[0] ^ mirror[0], mirror[1]};
		if (mirror[2]) begin
			w_data <= mirror;
			w_tog <= ~w_tog;
		end
	end
	logic [1:0] en_s = 2'b00, w_s = 2'b00;
	logic       w_seen = 1'b0;
	logic [7:0] tc = 8'd0;
	always_ff @(posedge clk_sys) begin
		en_s <= {en_s[0], tcr[0]};
		w_s <= {w_s[0], w_tog};
		if (w_s[1] != w_seen) begin
			w_seen <= w_s[1];
			tc <= w_data;
		end else if (en_s[1])
			tc <= tc + 8'd1;
		if (rst_sys) begin
			en_s <= 2'b00;
			w_s <= 2'b00;
		end
	end
	assign q_sys = tc;
	assign q_arm = mirror ^ {6'd0, tcr};
endmodule

module daria_smp (
	input  wire        clk,                // clk_arm
	input  wire        smp_req,            // clk_sys toggle
	input  wire  [7:0] smp_addr,           // clk_sys, held
	output logic       ack = 1'b0,
	output logic [7:0] data = 8'd0
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic req_s0 = 1'b0;
	logic req_s1 = 1'b0;
	logic [7:0] addr = 8'd0;
	always_ff @(posedge clk) begin
		req_s0 <= smp_req;
		req_s1 <= req_s0;
		if (req_s1 != ack) begin
			addr <= smp_addr;
			ack <= req_s1;
		end
		data <= addr + 8'd3;
	end
endmodule

module daria_fe_call (
	input  wire        clk_sys,
	input  wire        go,
	input  wire        ret_tog,            // clk_arm
	output logic       tog_q = 1'b0,
	output wire        q
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic ret_s1 = 1'b0;
	logic ret_s2 = 1'b0;
	always_ff @(posedge clk_sys) begin
		ret_s1 <= ret_tog;
		ret_s2 <= ret_s1;
		if (go) tog_q <= ~tog_q;
	end
	assign q = ret_s2;
endmodule

module daria_fe_audio (
	input  wire        clk_sys,
	input  wire        go,
	input  wire  [7:0] a,
	input  wire        smp_ack,            // clk_arm
	input  wire  [7:0] smp_data,           // clk_arm, held
	output logic       req_q = 1'b0,
	output logic [7:0] saddr_q = 8'd0,
	output wire  [7:0] q
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic ack_s1 = 1'b0;
	logic ack_s2 = 1'b0;
	logic [7:0] rdat = 8'd0;
	always_ff @(posedge clk_sys) begin
		ack_s1 <= smp_ack;
		ack_s2 <= ack_s1;
		if (ack_s2 == req_q) begin
			rdat <= smp_data;
			if (go) begin
				saddr_q <= a;
				req_q <= ~req_q;
			end
		end
	end
	assign q = rdat;
endmodule

module daria_fe (
	input  wire        clk_sys,
	input  wire        clk_arm,
	input  wire  [7:0] a,
	input  wire        ret_tog,
	input  wire        smp_ack,
	input  wire  [7:0] smp_data,
	output wire        call_tog,
	output wire        smp_req,
	output wire  [7:0] smp_addr,
	output wire  [7:0] q
);
	wire c_q, locked, phb_next, guard_on;
	wire [7:0] a_q;
	daria_fe_call u_call (.clk_sys, .go(a[0]), .ret_tog, .tog_q(call_tog), .q(c_q));
	daria_fe_audio u_audio (.clk_sys, .go(a[1]), .a, .smp_ack, .smp_data, .req_q(smp_req), .saddr_q(smp_addr), .q(a_q));
	daria_fe_guard u_guard (.clk_sys, .clk_arm, .call_win(a[2]), .cpu_ready(a[3]), .locked, .phb_next, .guard_on);
	assign q = a_q ^ {4'd0, c_q, locked, phb_next, guard_on};
endmodule

module bupchip_pocket (
	input  wire        clk_sys,
	input  wire        clk_arm,
	input  wire  [7:0] a,
	input  wire        daria_profile,      // atari7800_pocket's registers (P21)
	input  wire        daria_ram32_n,
	input  wire        daria_mreset,
	input  wire        daria_gate,
	input  wire        call_tog,
	input  wire        smp_req,
	input  wire  [7:0] smp_addr,
	input  wire        fn_s_tog,           // FujiNet staging and swap (clk_sys)
	input  wire        fn_s_sync,
	input  wire  [1:0] fn_s_lanes,
	input  wire  [7:0] fn_s_haddr,
	input  wire  [7:0] fn_s_data,
	input  wire        fn_l_req,
	input  wire  [7:0] fn_l_haddr,
	output wire        ret_tog,
	output wire        smp_ack,
	output wire  [7:0] smp_data,
	output wire        fn_s_ack,
	output wire        fn_l_ack,
	output wire  [7:0] fn_l_data,
	output wire  [7:0] q_sys,
	output wire  [7:0] q_arm
);
	// ---- clk_sys -> clk_arm levels ----------------------------------------------------------
	logic hold_sys = 1'b1;
	always_ff @(posedge clk_sys) hold_sys <= a[0];
	logic [1:0] hold_a = 2'b11, prof_a = 2'b00, ram32_a = 2'b00, mres_a = 2'b11;
	always_ff @(posedge clk_arm) begin
		hold_a <= {hold_a[0], hold_sys};
`ifdef SMOKE_MUT
		prof_a <= {prof_a[0], daria_profile ^ daria_gate};
`else
		prof_a <= {prof_a[0], daria_profile};
`endif
		ram32_a <= {ram32_a[0], ~daria_ram32_n};
		mres_a <= {mres_a[0], daria_mreset};
	end
	// No pause_a and no halted_s (below): pause_core is tied 0 and
	// daria_halted is left open in every build, so no build has those
	// chains, and daria_sync.tcl does not mark them (plan 2.7)
	wire paused = 1'b0;

	// ---- the $8007 command toggle and its held byte -----------------------------------------------
	logic       cmd_tog = 1'b0;
	logic [7:0] cmd_byte = 8'd0;
	always_ff @(posedge clk_sys)
		if (a[5]) begin
			cmd_byte <= a;
			cmd_tog <= ~cmd_tog;
		end
	logic [2:0] cmd_s = 3'd0;
	logic [7:0] cmd_data_arm = 8'd0;
	always_ff @(posedge clk_arm) begin
		cmd_s <= {cmd_s[1:0], cmd_tog};
		if (cmd_s[2] ^ cmd_s[1]) cmd_data_arm <= cmd_byte;
	end

	// ---- the CPU stand-in (clk_arm) -----------------------------------------------------------------
	logic [2:0] cpu_state = 3'd0;
	logic       img_ready = 1'b0, cpu_run = 1'b0, halted = 1'b0;
	always_ff @(posedge clk_arm) begin
		cpu_state <= cpu_state + {2'd0, ~hold_a[1] & ~paused};
		img_ready <= cmd_data_arm[0] ^ prof_a[1];
		cpu_run <= ~mres_a[1] & ram32_a[1];
		halted <= cmd_data_arm[1];
	end
	wire parked = cpu_state == 3'd5;
	logic ready_a = 1'b0;
	always_ff @(posedge clk_arm) ready_a <= parked & img_ready;

	// ---- clk_arm -> clk_sys levels --------------------------------------------------------------------
	logic gate_sys = 1'b0;
	always_ff @(posedge clk_sys) gate_sys <= a[2];
	logic [1:0] ready_s = 2'b00, run_s = 2'b00;
	always_ff @(posedge clk_sys) begin
`ifdef SMOKE_MUT
		ready_s <= {ready_s[0], parked & img_ready};
		run_s <= {run_s[0], cpu_run & gate_sys};
`else
		ready_s <= {ready_s[0], ready_a};
		run_s <= {run_s[0], cpu_run};
`endif
	end
	wire halt_seen = 1'b0;

	// ---- the audio frame toggle and its held frame -----------------------------------------------------
	logic        frame_tog = 1'b0;
	logic [15:0] frame_arm = 16'd0;
	always_ff @(posedge clk_arm)
		if (cpu_state == 3'd2) begin
			frame_arm <= {cmd_data_arm, cpu_state, img_ready, cpu_run, halted, ready_a, ret_tog};
			frame_tog <= ~frame_tog;
		end
	logic [2:0] ftog_s = 3'd0;
	logic [7:0] audio_l = 8'd0, audio_r = 8'd0;
	always_ff @(posedge clk_sys) begin
		ftog_s <= {ftog_s[1:0], frame_tog};
		if (ftog_s[2] ^ ftog_s[1]) begin
			audio_l <= frame_arm[7:0];
			audio_r <= frame_arm[15:8];
		end
	end
`ifdef SMOKE_MUT
	logic raw = 1'b0;
	always_ff @(posedge clk_sys) raw <= frame_arm[3];
`else
	wire raw = 1'b0;
`endif

	// ---- BUP_DEBUG: the status word's snapshot -------------------------------------------------------------
	// No cap_err_a: the core's has no load in any build (bup_status_osd.sv
	// does not show the status word's bit 11), so no build has that chain
	// and daria_sync.tcl does not mark it (plan 2.7)
	wire [7:0] dbg;
`ifdef SMOKE_Q5
	bup_dbg_snap #(.N(8)) dbg_snap (.clk_sys, .clk_arm, .d_arm(frame_arm[7:0]), .q_sys(dbg));
`else
	assign dbg = 8'd0;
`endif

	// ---- the DARIA blocks -------------------------------------------------------------------------------
	wire [7:0] w_q, m_q_sys, m_q_arm;
	wire       c_q;
	wire       msg_tog;
	wire [3:0] msg_type;
	wire [7:0] msg_pl;
	bup_capture capture (.clk(clk_sys), .a, .msg_tog, .msg_type, .msg_pl);
	bup_asset_wr writer (.clk(clk_arm), .msg_tog, .msg_type, .msg_pl,
		.s_tog(fn_s_tog), .s_sync(fn_s_sync), .s_lanes(fn_s_lanes), .s_haddr(fn_s_haddr), .s_data(fn_s_data),
		.s_ack(fn_s_ack), .q(w_q));
	fujinet_rd fn_rd (.clk(clk_arm), .l_req(fn_l_req), .l_haddr(fn_l_haddr), .ack(fn_l_ack), .data(fn_l_data));
	daria_call call (.clk(clk_arm), .call_tog, .ret_q(ret_tog), .q(c_q));
	daria_mmio mmio (.clk_arm, .rst_arm(~cpu_run), .a, .clk_sys, .rst_sys(~run_s[1]), .q_sys(m_q_sys), .q_arm(m_q_arm));
	daria_smp smp (.clk(clk_arm), .smp_req, .smp_addr, .ack(smp_ack), .data(smp_data));

	assign q_sys = audio_l ^ audio_r ^ dbg ^ m_q_sys ^ {raw, halt_seen, ready_s[1], run_s[1], gate_sys ^ daria_gate, 3'd0};
	assign q_arm = w_q ^ m_q_arm ^ {c_q, cmd_data_arm[7], halted, 5'd0};
endmodule

module atari7800_pocket (
	input  wire        clk_sys,
	input  wire        clk_arm,
	input  wire  [7:0] a,
	output wire  [7:0] q_sys,
	output wire  [7:0] q_arm
);
	// P21's registers
	logic daria_profile = 1'b0, daria_ram32_n = 1'b0, daria_mres_r = 1'b0, daria_gate = 1'b0;
	always_ff @(posedge clk_sys) begin
		daria_profile <= a[3];
		daria_ram32_n <= a[4];
		daria_mres_r <= a[5] | a[6];
		daria_gate <= a[7];
	end
	wire       call_tog, smp_req, ret_tog, smp_ack;
	wire [7:0] smp_addr, smp_data, b_q, f_q;
	// FujiNet game loading (docs/FUJINET_GAME_LOADING.md 3.2, 3.4)
	wire       fn_s_tog, fn_s_sync, fn_s_ack, fn_l_req, fn_l_ack, st_q;
	wire [1:0] fn_s_lanes;
	wire [7:0] fn_s_haddr, fn_s_data, fn_l_haddr, fn_l_data, ld_q;
	fujinet_stage fn_stage (.clk(clk_sys), .a, .s_ack(fn_s_ack), .s_tog(fn_s_tog), .s_sync(fn_s_sync),
		.s_lanes(fn_s_lanes), .s_haddr(fn_s_haddr), .s_data(fn_s_data), .q(st_q));
	fujinet_loader fn_loader (.clk(clk_sys), .a, .l_ack(fn_l_ack), .l_data(fn_l_data), .l_req(fn_l_req),
		.l_haddr(fn_l_haddr), .q(ld_q));
	bupchip_pocket bupchip (.clk_sys, .clk_arm, .a, .daria_profile, .daria_ram32_n, .daria_mreset(daria_mres_r),
		.daria_gate, .call_tog, .smp_req, .smp_addr,
		.fn_s_tog, .fn_s_sync, .fn_s_lanes, .fn_s_haddr, .fn_s_data, .fn_l_req, .fn_l_haddr,
		.ret_tog, .smp_ack, .smp_data, .fn_s_ack, .fn_l_ack, .fn_l_data, .q_sys(b_q), .q_arm);
	daria_fe daria (.clk_sys, .clk_arm, .a, .ret_tog, .smp_ack, .smp_data, .call_tog, .smp_req, .smp_addr, .q(f_q));
	assign q_sys = b_q ^ f_q ^ ld_q ^ {7'd0, st_q};
endmodule

module core_top (
	input  wire        clk_sys,
	input  wire        clk_arm,
	input  wire  [7:0] a,
	output wire  [7:0] q_sys,
	output wire  [7:0] q_arm
);
	atari7800_pocket atari (.clk_sys, .clk_arm, .a, .q_sys, .q_arm);
endmodule

module ap_core (
	input  wire        clk_sys,            // the PLL's clocks, by their SDC names (clocks.sdc)
	input  wire        clk_sdram,
	input  wire        clk_sys_90,
	input  wire        clk_arm,
	input  wire  [7:0] a,
	output logic [7:0] o = 8'd0,           // clk_sys
	output logic [7:0] oa = 8'd0,          // clk_arm
	output logic       s = 1'b0
);
	logic [7:0] a_q = 8'd0;
	wire  [7:0] q_sys, q_arm;
	always_ff @(posedge clk_sys) a_q <= a;
	core_top ic (.clk_sys, .clk_arm, .a(a_q), .q_sys, .q_arm);
	always_ff @(posedge clk_sys) o <= q_sys;
	always_ff @(posedge clk_arm) oa <= q_arm;
	logic s0 = 1'b0;
	always_ff @(posedge clk_sdram) s0 <= a[0];
	always_ff @(posedge clk_sys_90) s <= s0;
endmodule

`default_nettype wire
