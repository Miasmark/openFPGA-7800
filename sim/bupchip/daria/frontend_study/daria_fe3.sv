// DARIA front-end sizing sketch (v3 in docs/DARIA_CORE.md): NOT functionally
// verified and not for the core; it exists only to be compiled for size
// (run_study.sh). SPDX-License-Identifier: MIT
// The architecture of DARIA_CORE.md, "The 6507 side", written for the core's synthesis
// settings (MUX_RESTRUCTURE OFF): one-hot slot enables, one load enable and a
// small data mux per register, and the word datapath (W + one adder) shared by
// the front end and the audio engine. Split into modules for attribution.
module daria_fe3 (
	input  logic        clk,
	input  logic        reset,
	input  logic  [1:0] scheme,          // 1 DPC+, 2 CDF, 3 BUS
	input  logic  [1:0] revision,
	input  logic        stable_fractional,
	input  logic        cdf_ldx,
	input  logic        cdf_ldy,
	input  logic        fetch_offset_enable,
	input  logic  [7:0] fetch_offset,
	input  logic [16:0] rom_size,
	input  logic [15:0] ram_size,
	input  logic [13:0] audio_size_addr,
	input  logic        phi1,
	input  logic        access,
	input  logic        rw,
	input  logic [12:0] a_in,
	input  logic  [7:0] d_in,
	output logic  [7:0] d_out,
	output logic        drive,
	output logic        stuff_valid,
	output logic  [7:0] stuff_data,
	output logic [14:0] rom_addr,
	input  logic [31:0] rom_q,
	output logic [11:0] ram_addr,
	output logic  [3:0] ram_be,
	output logic        ram_we,
	output logic [31:0] ram_wdata,
	input  logic [31:0] ram_q,
	output logic        call_request,
	input  logic        call_ready,
	input  logic        call_launch,
	input  logic        call_done,
	output logic        dma_busy,
	input  logic        load_end,
	output logic        init_busy,
	input  logic  [7:0] ctl_addr,
	input  logic        ctl_we,
	input  logic [31:0] ctl_wdata,
	output logic [31:0] ctl_rdata
);
	// one-hot slots: bit n = n clk_sys after the 6507's phase-1 edge
	logic [15:0] sl = 16'h8000;
	always_ff @(posedge clk) sl <= phi1 ? 16'h0001 : (sl[15] ? sl : {sl[14:0], 1'b0});
	wire fe_owns = |sl[7:1];

	wire is_dpc = scheme == 2'd1;
	wire is_cdf = scheme == 2'd2;
	wire is_bus = scheme == 2'd3;
	wire jplus  = is_cdf && revision == 2'd3;

	// state RAM: DPC+ fetchers, params, audio words; port A for the controller
	logic  [7:0] st_addr;
	logic        st_we;
	logic  [3:0] st_be;
	logic [31:0] st_wdata, st_q;
	cache_ram_tdp_dc_be #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) state_ram (
		.clk_a_i(clk), .addr_a_i(ctl_addr), .wren_a_i(ctl_we), .byteena_a_i(4'hF),
		.wdata_a_i(ctl_wdata), .q_a_o(ctl_rdata),
		.clk_b_i(clk), .addr_b_i(st_addr), .wren_b_i(st_we), .byteena_b_i(st_be),
		.wdata_b_i(st_wdata), .q_b_o(st_q));

	// ---------------------------------------------------------- word datapath
	logic [31:0] w, b, sum;
	logic        c_w_en, a_w_en;
	logic  [1:0] c_w_src, a_w_src;
	logic  [3:0] c_b_sel, a_b_sel;
	wire         w_en  = fe_owns ? c_w_en  : a_w_en;
	wire  [1:0]  w_src = fe_owns ? c_w_src : a_w_src;
	wire  [3:0]  b_sel = fe_owns ? c_b_sel : a_b_sel;
	// one-hot AND-OR: each bit only ORs the sources that can be non-zero there
	wire [9:0] bs = 10'b1 << b_sel;
	always_comb
		b = ({32{bs[0]}} & {4'b0, ram_q[15:0], 12'b0}) |
		    ({32{bs[1]}} & {8'b0, ram_q[15:0], 8'b0}) |
		    ({32{bs[2]}} & 32'h00100000) | ({32{bs[3]}} & 32'h00010000) |
		    ({32{bs[4]}} & 32'h00000001) | ({32{bs[5]}} & 32'h00000FFF) |
		    ({32{bs[6]}} & {24'b0, w[31:24]}) | ({32{bs[7]}} & st_q) |
		    ({32{bs[8]}} & {13'b0, st_q[31:13]}) | ({32{bs[9]}} & {21'b0, st_q[31:21]});
	assign sum = w + b;
	logic [31:0] shiftin;
	always_ff @(posedge clk)
		if (w_en)
			case (w_src)
				2'd0: w <= ram_q;
				2'd1: w <= st_q;
				2'd2: w <= sum;
				default: w <= shiftin;
			endcase

	// ---------------------------------------------------------- clients
	logic [14:0] c_rom_addr, cp_rom_addr, a_rom_addr;
	logic [11:0] c_ram_addr, cp_ram_addr, a_ram_addr;
	logic  [3:0] c_ram_be;
	logic        c_ram_we, cp_ram_we;
	logic [31:0] c_ram_wdata;
	logic  [7:0] cp_byte;
	logic  [3:0] cp_be;
	logic  [7:0] c_st_addr, cp_st_addr, a_st_addr;
	logic        c_st_we, a_st_we;
	logic  [3:0] c_st_be;
	logic [31:0] c_st_wdata;
	logic        cp_active, service_req, service_fill, note_pending, note_taken;
	logic  [1:0] note_voice;
	logic  [7:0] note_value;
	logic  [6:0] wave0, wave1, wave2;
	logic  [7:0] mode, amplitude;
	logic  [7:0] din;

	fe3_core core (.*);
	fe3_copy copy (.*);
	fe3_audio audio (.*);

	// ---------------------------------------------------------- port muxes
	always_comb begin
		rom_addr = (sl[0] || sl[2]) ? c_rom_addr : (cp_active ? cp_rom_addr : a_rom_addr);
		if (fe_owns) begin
			ram_addr = c_ram_addr; ram_be = c_ram_be; ram_we = c_ram_we; ram_wdata = c_ram_wdata;
			st_addr = c_st_addr; st_we = c_st_we; st_be = c_st_be; st_wdata = c_st_wdata;
		end else begin
			ram_addr = cp_active ? cp_ram_addr : a_ram_addr;
			ram_be = cp_be;
			ram_we = cp_ram_we;
			ram_wdata = {4{cp_byte}};  // folded below
			st_addr = cp_active ? cp_st_addr : a_st_addr;
			st_we = a_st_we && !cp_active;
			st_be = 4'hF;
			st_wdata = w;
		end
	end
endmodule

// ============================================================== front end
module fe3_core (
	input  logic        clk, reset,
	input  logic [15:0] sl,
	input  logic        is_dpc, is_cdf, is_bus, jplus,
	input  logic  [1:0] revision,
	input  logic        stable_fractional, cdf_ldx, cdf_ldy, fetch_offset_enable,
	input  logic  [7:0] fetch_offset,
	input  logic        access, rw,
	input  logic [12:0] a_in,
	input  logic  [7:0] d_in,
	output logic  [7:0] d_out,
	output logic        drive, stuff_valid,
	output logic  [7:0] stuff_data,
	input  logic [31:0] rom_q, ram_q, st_q, w, sum,
	output logic [31:0] shiftin,
	output logic        c_w_en,
	output logic  [1:0] c_w_src,
	output logic  [3:0] c_b_sel,
	output logic [14:0] c_rom_addr,
	output logic [11:0] c_ram_addr,
	output logic  [3:0] c_ram_be,
	output logic        c_ram_we,
	output logic [31:0] c_ram_wdata,
	output logic  [7:0] c_st_addr,
	output logic        c_st_we,
	output logic  [3:0] c_st_be,
	output logic [31:0] c_st_wdata,
	output logic        call_request,
	input  logic        call_ready,
	output logic        service_req, service_fill,
	input  logic        cp_active,
	output logic        note_pending,
	output logic  [1:0] note_voice,
	output logic  [7:0] note_value,
	input  logic        note_taken,
	output logic  [6:0] wave0, wave1, wave2,
	output logic  [7:0] mode,
	input  logic  [7:0] amplitude,
	output logic  [7:0] din
);
	wire jrev = is_cdf && revision[1];
	wire bus3 = is_bus && revision == 2'd3;

	// bank and ROM
	logic  [2:0] bank;
	logic [16:0] base;
	always_comb begin
		base = 17'd4096;
		if (is_dpc || (is_bus && revision == 2'd0)) base = 17'd3072;
		else if (jplus) base = 17'd2048;
	end
	wire [16:0] cur = base + {2'b0, bank, 12'b0} + {5'b0, a_in[11:0]};
	assign c_rom_addr = cur[16:2] + {14'b0, sl[2]};
	wire  [7:0] rom_b = rom_q[{cur[1:0], 3'b000} +: 8];

	// table bases (CDF/BUS)
	logic [11:0] ptr_base, inc_base, map_base;
	always_comb begin
		ptr_base = 12'h026; inc_base = 12'h049; map_base = 12'h1D8;
		if (is_cdf) begin
			if (revision == 2'd0) begin ptr_base = 12'h1B8; inc_base = 12'h1DA; end
			else if (revision == 2'd1) begin ptr_base = 12'h028; inc_base = 12'h04A; end
		end else if (revision == 2'd0) begin ptr_base = 12'h2B8; inc_base = 12'h2C8; map_base = 12'h2D9; end
		else if (revision == 2'd3) begin ptr_base = 12'h1B6; inc_base = 12'h1C8; end
		else begin ptr_base = 12'h1B8; inc_base = 12'h1C8; end
	end

	// registers
	logic        fast_fetch, pend, sub, jump_ok, flag, stuff_target_valid, stuff_go;
	logic [12:0] pend_addr, jump_addr;
	logic  [1:0] jump_remaining;
	logic        jump_odd;
	logic  [7:0] stuff_target, romb, dout, stuff_q;
	logic [31:0] xw, rnd;
	logic  [2:0] param_ptr;
	logic        call_pending;
	logic  [3:0] op, cop, fn;
	logic  [5:0] idx;
	logic  [2:0] fidx;
	logic        word1;
	logic [11:0] pa;
	logic [13:0] da;
	wire fast_mode = mode[3:0] == 4'b0;

	// ---------------- decode (s1)
	wire       dpc_direct = a_in[11:0] < 12'h028;
	wire       dpc_rreg = is_dpc && rw && a_in[12] &&
		(dpc_direct || (fast_fetch && pend && rom_b < 8'h28));
	wire [5:0] dpc_reg = dpc_direct ? a_in[5:0] : rom_b[5:0];
	wire       dpc_wr = is_dpc && !rw && a_in[12] && a_in[11:7] == 5'b0 && a_in[6:3] >= 4'd5;
	wire [3:0] dpc_wfn = a_in[6:3] - 4'd5;
	wire [5:0] amp_stream = jrev ? 6'd35 : 6'd34;
	wire [8:0] fetch_limit = {1'b0, fetch_offset} + {3'b0, amp_stream};
	wire [5:0] amp_operand = fetch_offset_enable ? amp_stream + fetch_offset[5:0] : amp_stream;
	wire       in_range = fetch_offset_enable ?
		(rom_b >= fetch_offset && {1'b0, rom_b} <= fetch_limit) : rom_b <= {2'b0, amp_stream};
	wire [7:0] norm = fetch_offset_enable ? rom_b - fetch_offset : rom_b;
	wire       jump_hit = rw && a_in[12] && jump_remaining != 0 && a_in == jump_addr;
	wire       cdf_jump = is_cdf && jump_hit && ((jump_remaining == 2'd2 &&
		(jrev ? rom_b[7:1] == 7'b0 : rom_b == 8'b0)) || (jump_remaining == 2'd1 && rom_b == 8'b0));
	wire       bus_jump = bus3 && jump_hit && rom_b == 8'b0;
	wire       cdf_fetch = is_cdf && rw && a_in[12] && fast_mode && pend && a_in == pend_addr && in_range;
	wire       cdf_amp = cdf_fetch && !cdf_jump && rom_b[5:0] == amp_operand;
	wire       hi = a_in[12] && a_in[11:4] == 8'hFF;          // $1FF0-$1FFF
	wire       lo = a_in[12] && a_in[11:5] == 7'b0;           // $1000-$101F
	wire       cdf_w = is_cdf && !rw && hi && a_in[3:2] == 2'b00;
	wire       bus_sread = is_bus && rw && (bus3 ? hi && a_in[3:0] == 4'hF : lo && !a_in[4]);
	wire       bus_amp = is_bus && rw && (bus3 ? hi && a_in[3:0] == 4'hE : lo && a_in[4:0] == 5'h18);
	wire       bus_w = is_bus && !rw && (bus3 ? hi && a_in[3:2] == 2'b00 : lo && a_in[4]);
	wire [2:0] bus_wfn = bus3 ? {1'b0, a_in[1:0]} : (a_in[3:2] == 2'b00 ? 3'd0 :
		(a_in[3:2] == 2'b01 ? 3'd1 : (a_in[3:0] == 4'h9 ? 3'd2 : (a_in[3:0] == 4'hA ? 3'd3 : 3'd4))));
	wire       stuff_cand = is_bus && !rw && !a_in[12] && stuff_target_valid &&
		a_in[11:0] == {4'b0, stuff_target} && a_in[6:0] <= 7'h24;
	wire [2:0] wfn = is_cdf ? {1'b0, a_in[1:0]} : bus_wfn;   // 0 stream write, 1 ptr, 2 mode, 3 call

	localparam logic [3:0] OP_ROM = 4'd1, OP_DREG = 4'd2, OP_DWR = 4'd3, OP_FETCH = 4'd4,
		OP_JUMP = 4'd5, OP_AMP = 4'd6, OP_SWRITE = 4'd7, OP_PWRITE = 4'd8, OP_STUFF = 4'd9,
		OP_REG = 4'd10, OP_NONE = 4'd0;
	logic [3:0] op_d;
	logic [5:0] idx_d;
	always_comb begin
		op_d = (rw && a_in[12]) ? OP_ROM : OP_NONE;
		idx_d = is_bus ? (bus3 ? 6'd16 : {2'b0, a_in[3:0]}) : 6'd32;
		if (dpc_rreg) op_d = OP_DREG;
		else if (dpc_wr) op_d = OP_DWR;
		else if (cdf_jump || bus_jump) begin
			op_d = OP_JUMP;
			idx_d = is_bus ? 6'd17 : 6'd33 + {5'b0, (jrev && jump_remaining == 2'd2) ? rom_b[0] : jump_odd};
		end else if (cdf_amp || bus_amp) op_d = OP_AMP;
		else if (cdf_fetch) begin op_d = OP_FETCH; idx_d = norm[5:0]; end
		else if (bus_sread) op_d = OP_FETCH;
		else if ((cdf_w || bus_w) && wfn == 3'd0) op_d = OP_SWRITE;
		else if ((cdf_w || bus_w) && wfn == 3'd1) begin
			op_d = OP_PWRITE;
			if (is_bus && !bus3) idx_d = {4'b0, a_in[1:0]};
		end else if (stuff_cand) op_d = OP_STUFF;
		else if (cdf_w || bus_w) op_d = OP_REG;
	end
	wire [3:0] fn_d = dpc_rreg ? {1'b0, dpc_reg[5:3]} : dpc_wfn;
	wire [2:0] fidx_d = dpc_rreg ? dpc_reg[2:0] : a_in[2:0];
	wire       word1_d = dpc_rreg ? dpc_reg[5:3] == 3'd3 : dpc_wfn <= 4'd2;

	// s1 loads
	always_ff @(posedge clk)
		if (sl[1]) begin
			op <= op_d; idx <= idx_d; fn <= fn_d; fidx <= fidx_d; word1 <= word1_d;
			romb <= rom_b;
			sub <= op_d == OP_DREG || op_d == OP_FETCH || op_d == OP_JUMP || op_d == OP_AMP;
		end

	// ---------------- addresses
	wire [11:0] ptr_sum = ptr_base + {6'b0, sl[2] ? {2'b0, ram_q[3:0]} : idx_d};
	wire [11:0] map_sum = map_base + {7'b0, a_in[4:0]};
	wire [11:0] inc_sum = inc_base + {6'b0, idx};
	wire [11:0] dpc_field = word1 ? st_q[19:8] : st_q[11:0];
	wire [13:0] da_next = is_dpc ? 14'h0C00 + {2'b0, sl[3] ? sum[11:0] : dpc_field} :
		(jplus ? 14'h0800 + ram_q[29:16] : 14'h0800 + {2'b0, ram_q[31:20]});
	wire stuff = op == OP_STUFF;
	always_ff @(posedge clk) begin
		if (sl[1] || (sl[2] && stuff)) pa <= c_ram_addr;
		if (sl[1] || (sl[2] && stuff)) xw <= sl[1] ? rom_q : ram_q;
		if (sl[2] || (sl[3] && (stuff || (is_dpc && fn == 4'd7)))) da <= da_next;
	end
	// store the stuffed stream's index where inc_sum finds it
	wire sa_map = (sl[1] && op_d == OP_STUFF) || (sl[7] && stuff);
	wire sa_ptr = (sl[1] && op_d != OP_STUFF) || (sl[2] && stuff);
	wire sa_dan = (sl[2] && !stuff) || (sl[3] && stuff);
	wire sa_inc = (sl[3] && !stuff) || sl[4];
	wire sa_da  = sl[7] && !stuff;
	wire sa_pa  = !(sa_map || sa_ptr || sa_dan || sa_inc || sa_da);
	assign c_ram_addr = ({12{sa_map}} & map_sum) | ({12{sa_ptr}} & ptr_sum) | ({12{sa_dan}} & da_next[13:2]) |
		({12{sa_inc}} & inc_sum) | ({12{sa_da}} & da[13:2]) | ({12{sa_pa}} & pa);
	// writes: s6 the word, s7 a byte or the BUS map
	wire word_op = cop == OP_FETCH || cop == OP_JUMP || cop == OP_SWRITE || cop == OP_PWRITE || cop == OP_STUFF;
	assign c_ram_we = !is_dpc ? ((sl[6] && word_op) || (sl[7] && (cop == OP_SWRITE || cop == OP_STUFF))) :
		(sl[7] && cop == OP_DWR && (fn == 4'd7 || fn == 4'd10));
	assign c_ram_be = (sl[7] && !(cop == OP_STUFF)) ? (4'b0001 << da[1:0]) : 4'hF;
	assign c_ram_wdata = ({32{sl[6]}} & w) | ({32{!sl[6] && cop == OP_STUFF}} & {xw[3:0], xw[31:4]}) |
		({32{!sl[6] && cop != OP_STUFF}} & {4{din}});

	// DPC+ state RAM
	wire dpc_rmw = (cop == OP_DREG && fn >= 4'd1 && fn <= 4'd3) ||
		(cop == OP_DWR && (fn == 4'd7 || fn == 4'd10));
	logic [3:0] fld_be;
	always_comb
		case (fn)
			4'd0: fld_be = stable_fractional ? 4'b0011 : 4'b0010;
			4'd1, 4'd3: fld_be = 4'b0100;
			4'd2: fld_be = 4'b1001;
			4'd4: fld_be = 4'b1000;
			4'd5: fld_be = 4'b0001;
			4'd8: fld_be = 4'b0010;
			default: fld_be = 4'b0000;
		endcase
	wire param_wr = cop == OP_DWR && fn == 4'd6 && fidx == 3'd1 && param_ptr < 3'd4;
	assign c_st_addr = sl[1] ? {4'b0, fidx_d, word1_d} : (param_wr ? 8'h10 : {4'b0, fidx, word1});
	assign c_st_we = is_dpc && ((sl[6] && (dpc_rmw || (cop == OP_DWR && fld_be != 4'b0))) || (sl[7] && param_wr));
	assign c_st_be = sl[7] ? (4'b0001 << param_ptr[1:0]) : (dpc_rmw ? (word1 ? 4'b0111 : 4'b0011) : fld_be);
	wire [7:0] nib = {4'b0, din[3:0]};
	assign c_st_wdata = (sl[6] && dpc_rmw) ? w :
		{din, (fn == 4'd1) ? nib : din, (fn == 4'd8) ? nib : din, (fn == 4'd0 || fn == 4'd2) && !(fn == 4'd0 && !stable_fractional) ? 8'b0 : din};

	// ---------------- word datapath control
	always_comb begin
		c_w_en = 1'b0; c_w_src = 2'd0; c_b_sel = 4'd2;
		if (sl[2] && !stuff) begin c_w_en = 1'b1; c_w_src = is_dpc ? 2'd1 : 2'd0; end
		if (sl[3]) begin
			c_b_sel = is_dpc ? (word1 ? 4'd6 : (fn == 4'd7 ? 4'd5 : 4'd4)) : (jplus ? 4'd3 : 4'd2);
			if (stuff) begin c_w_en = 1'b1; c_w_src = 2'd0; end
			else if (is_dpc || op == OP_JUMP || op == OP_SWRITE) begin c_w_en = 1'b1; c_w_src = 2'd2; end
		end
		if (sl[4] && op == OP_FETCH) begin c_w_en = 1'b1; c_w_src = 2'd2; c_b_sel = jplus ? 4'd1 : 4'd0; end
		if (sl[5] && stuff) begin c_w_en = 1'b1; c_w_src = 2'd2; c_b_sel = 4'd0; end
		if (sl[5] && access && op == OP_PWRITE) begin c_w_en = 1'b1; c_w_src = 2'd3; end
	end
	assign shiftin = jplus ? {w[23:16], d_in, 16'b0} : {w[23:20], d_in, 20'b0};

	// ---------------- read data
	wire  [7:0] ram_byte = ram_q[{da[1:0], 3'b000} +: 8];
	wire        win = (st_q[23:16] - st_q[7:0]) > (st_q[23:16] - st_q[31:24]);
	wire [31:0] rnd_next = {rnd[10:0], rnd[31:11]} ^ (rnd[10] ? 32'h10ADAB1E : 32'b0);
	wire [31:0] rnd_px = rnd[31] ? (rnd ^ 32'h10ADAB1E) : rnd;
	wire [31:0] rnd_prior = {rnd_px[20:0], rnd_px[31:21]};
	logic [7:0] reg_byte;
	always_comb
		case (dpc_reg[2:0])
			3'd0: reg_byte = rnd_next[7:0];
			3'd1: reg_byte = rnd_prior[7:0];
			3'd2: reg_byte = rnd[15:8];
			3'd3: reg_byte = rnd[23:16];
			3'd4: reg_byte = rnd[31:24];
			3'd5: reg_byte = amplitude;
			default: reg_byte = 8'b0;
		endcase
	always_ff @(posedge clk) begin
		if (dout_en) dout <= dout_d;
		if (sl[2]) flag <= win;
		if (sl[3]) jump_ok <= romb == 8'h4C && la1[7:1] == 7'b0 && la2 == 8'b0;
		if (sl[4]) stuff_q <= ram_byte;
		if (sl[3]) stuff_go <= stuff;
		else if (sl[6]) stuff_go <= 1'b0;
	end
	wire s1_amp = op_d == OP_AMP, s1_reg = op_d == OP_DREG && dpc_reg[5:3] == 3'd0;
	wire s2_flag = sl[2] && op == OP_DREG && fn == 4'd4;
	wire s3_data = sl[3] && (op == OP_FETCH || op == OP_JUMP || (op == OP_DREG && fn >= 4'd1 && fn <= 4'd3));
	wire dout_en = sl[1] || s2_flag || s3_data;
	wire [7:0] dout_d = ({8{sl[1] && s1_amp}} & amplitude) | ({8{sl[1] && s1_reg}} & reg_byte) |
		({8{sl[1] && !s1_amp && !s1_reg}} & rom_b) | ({8{!sl[1] && s2_flag && win && !fidx[2]}}) |
		({8{!sl[1] && !s2_flag}} & ram_byte & {8{flag || fn != 4'd2}});
	wire [63:0] la_win = {rom_q, xw};
	wire  [2:0] l1 = {1'b0, cur[1:0]} + 3'd1;
	wire  [2:0] l2 = {1'b0, cur[1:0]} + 3'd2;
	wire  [7:0] la1 = la_win[{l1, 3'b000} +: 8];
	wire  [7:0] la2 = la_win[{l2, 3'b000} +: 8];
	assign d_out = dout;
	assign drive = a_in[12];
	assign stuff_valid = stuff_go && (sl[4] || sl[5]);
	assign stuff_data = sl[4] ? ram_byte : stuff_q;

	// ---------------- commit (end of s5)
	wire commit = sl[5] && access;
	wire rd12 = rw && a_in[12];
	wire arms = romb == 8'hA9 || (jplus && cdf_ldx && romb == 8'hA2) || (jplus && cdf_ldy && romb == 8'hA0);
	always_ff @(posedge clk) begin
		if (commit) begin din <= d_in; cop <= op; end
		else if (sl[8]) cop <= OP_NONE;
	end
	// bank
	wire hot_dpc = is_dpc && a_in[11:3] == 9'h1FF && a_in[2:0] >= 3'd6;
	wire hot_cdf = is_cdf && a_in[11:3] == 9'h1FF && a_in[2:0] <= 3'd3 || is_cdf && a_in[11:2] == 10'h3FD;
	wire hot_bus = is_bus && a_in[11:3] == 9'h1FF && a_in[2:0] <= 3'd3 || is_bus && a_in[11:0] >= 12'hFF5 && a_in[11:0] <= 12'hFF7;
	always_ff @(posedge clk)
		if (reset) bank <= is_dpc ? 3'd5 : (jplus ? 3'd0 : 3'd6);
		else if (commit && a_in[12] && !sub && (hot_dpc || hot_cdf || hot_bus))
			bank <= a_in[2:0] - (is_dpc ? 3'd6 : (is_cdf ? (jplus ? 3'd4 : 3'd5) : 3'd5));
	// fast fetch / STY tracking (CDF and BUS share the pending register)
	always_ff @(posedge clk)
		if (reset) pend <= 1'b0;
		else if (commit && rd12) begin
			if (is_dpc) pend <= op == OP_DREG ? 1'b0 : fast_fetch && romb == 8'hA9;
			else if (is_cdf) pend <= !sub && fast_mode && arms;
			else pend <= !pend && fast_mode && romb == 8'h84;
		end
	always_ff @(posedge clk)
		if (commit && rd12 && !sub && (is_bus ? !pend : 1'b1)) pend_addr <= a_in + 13'd1;
	always_ff @(posedge clk)
		if (reset) stuff_target_valid <= 1'b0;
		else if (commit) begin
			if (rd12 && is_bus && pend && a_in == pend_addr) begin
				stuff_target <= romb;
				stuff_target_valid <= 1'b1;
			end else if (!rw && !a_in[12]) stuff_target_valid <= 1'b0;
		end
	// fast jump
	always_ff @(posedge clk)
		if (reset) jump_remaining <= 2'b0;
		else if (commit && rd12) begin
			if (op == OP_JUMP) jump_remaining <= jump_remaining - 2'd1;
			else if (sub) ;
			else if (jump_remaining != 0) jump_remaining <= 2'd0;
			else if ((is_cdf || bus3) && fast_mode && jump_ok) jump_remaining <= 2'd2;
		end
	always_ff @(posedge clk)
		if (commit && rd12 && (op == OP_JUMP || (!sub && jump_remaining == 0)))
			jump_addr <= op == OP_JUMP ? jump_addr + 13'd1 : a_in + 13'd1;
	always_ff @(posedge clk)
		if (commit && rd12 && (op == OP_JUMP || jump_remaining == 0))
			jump_odd <= op == OP_JUMP && jrev && jump_remaining == 2'd2 && romb[0];
	// DPC+ registers held in flip-flops
	wire dwr = commit && op == OP_DWR;
	always_ff @(posedge clk)
		if (reset) fast_fetch <= 1'b0;
		else if (dwr && fn == 4'd6 && fidx == 3'd0) fast_fetch <= d_in == 8'b0;
	always_ff @(posedge clk)
		if (reset) param_ptr <= 3'd0;
		else if (dwr && fn == 4'd6 && fidx == 3'd1 && param_ptr < 3'd4) param_ptr <= param_ptr + 3'd1;
		else if (dwr && fn == 4'd6 && fidx == 3'd2 && d_in <= 8'd2 && !service_req) param_ptr <= 3'd0;
	always_ff @(posedge clk)
		if (reset) service_req <= 1'b0;
		else if (dwr && fn == 4'd6 && fidx == 3'd2 && (d_in == 8'd1 || d_in == 8'd2) && !service_req) begin
			service_req <= 1'b1;
			service_fill <= d_in == 8'd2;
		end else if (cp_active) service_req <= 1'b0;
	always_ff @(posedge clk) begin
		if (dwr && fn == 4'd6 && fidx == 3'd5) wave0 <= d_in[6:0];
		if (dwr && fn == 4'd6 && fidx == 3'd6) wave1 <= d_in[6:0];
		if (dwr && fn == 4'd6 && fidx == 3'd7) wave2 <= d_in[6:0];
		if (reset) begin wave0 <= 7'b0; wave1 <= 7'b0; wave2 <= 7'b0; end
	end
	always_ff @(posedge clk)
		if (reset || (dwr && fn == 4'd9 && fidx == 3'd0)) rnd <= 32'h2B435044;
		else if (commit && op == OP_DREG && fn == 4'd0 && fidx <= 3'd1) rnd <= fidx[0] ? rnd_prior : rnd_next;
		else if (dwr && fn == 4'd9 && fidx >= 3'd1 && fidx <= 3'd4)
			case (fidx[1:0])
				2'd1: rnd[7:0] <= d_in;
				2'd2: rnd[15:8] <= d_in;
				2'd3: rnd[23:16] <= d_in;
				default: rnd[31:24] <= d_in;
			endcase
	always_ff @(posedge clk)
		if (reset) note_pending <= 1'b0;
		else if (dwr && fn == 4'd9 && fidx >= 3'd5) begin
			note_pending <= 1'b1;
			note_voice <= fidx[1:0] - 2'd1;
			note_value <= d_in;
		end else if (note_taken) note_pending <= 1'b0;
	// CDF/BUS mode and the call
	wire reg_w = commit && op == OP_REG;
	always_ff @(posedge clk)
		if (reset) mode <= 8'hFF;
		else if (reg_w && wfn == 3'd2) mode <= (is_bus && !bus3) ? {4'b0, {4{d_in != 8'b0}}} : d_in;
	always_ff @(posedge clk)
		if (reset) call_pending <= 1'b0;
		else if (call_pending && call_ready) call_pending <= 1'b0;
		else if ((d_in == 8'hFE || d_in == 8'hFF) &&
			((reg_w && wfn == 3'd3) || (dwr && fn == 4'd6 && fidx == 3'd2)))
			call_pending <= 1'b1;
	assign call_request = call_pending && call_ready;
endmodule

// ============================================================== copy engine
module fe3_copy (
	input  logic        clk, reset,
	input  logic [15:0] sl,
	input  logic        is_dpc,
	input  logic [15:0] ram_size,
	input  logic        load_end,
	output logic        init_busy, dma_busy,
	input  logic        service_req, service_fill,
	output logic        cp_active,
	input  logic [31:0] rom_q, st_q,
	output logic [14:0] cp_rom_addr,
	output logic [11:0] cp_ram_addr,
	output logic        cp_ram_we,
	output logic  [7:0] cp_byte,
	output logic  [7:0] cp_st_addr,
	output logic  [3:0] cp_be
);
	// one byte per two background slots; the bounds are tested as it runs
	wire go = |sl[15:8] || sl[0];
	logic [16:0] src;
	logic [13:0] dst;
	logic [15:0] cnt;
	logic        fill, rd;
	logic  [2:0] fetcher;
	logic  [2:0] phase;      // 0 idle, 1 params, 2 dest, 3 run, 4.. init steps
	logic  [1:0] init_step;
	initial init_busy = 1'b0;
	assign cp_active = phase != 3'd0;
	assign dma_busy = cp_active && !init_busy;
	assign cp_rom_addr = src[16:2];
	assign cp_ram_addr = dst[13:2];
	assign cp_be = 4'b0001 << dst[1:0];
	assign cp_st_addr = phase == 3'd1 ? {4'b0, st_q[18:16], 1'b0} : 8'h10;
	wire stop = cnt == 16'd0 || (!init_busy && (dst == 14'h1C00 || (!fill && src == 17'h7C00)));
	always_ff @(posedge clk) begin
		cp_ram_we <= 1'b0;
		if (load_end) begin
			init_busy <= 1'b1;
			init_step <= 2'd0;
			phase <= 3'd4;
		end else if (go) case (phase)
			3'd0: if (service_req) begin phase <= 3'd1; fill <= service_fill; end
			3'd1: begin
				src <= 17'd3072 + {1'b0, st_q[15:0]};
				cnt <= {8'b0, st_q[31:24]};
				cp_byte <= st_q[7:0];
				phase <= 3'd2;
			end
			3'd2: begin dst <= 14'h0C00 + {2'b0, st_q[11:0]}; phase <= 3'd3; rd <= 1'b1; end
			3'd3: begin
				rd <= !rd;
				if (rd) begin
					if (stop) phase <= init_busy ? 3'd4 : 3'd0;
				end else begin
					if (!fill) cp_byte <= rom_q[{src[1:0], 3'b000} +: 8];
					cp_ram_we <= 1'b1;
					cnt <= cnt - 16'd1;
					src <= src + 17'd1;
					dst <= dst + 14'd1;
				end
			end
			default: begin
				init_step <= init_step + 2'd1;
				rd <= 1'b1;
				phase <= 3'd3;
				cp_byte <= 8'b0;
				case (init_step)
					2'd0: begin fill <= is_dpc; src <= 17'd0; dst <= 14'd0; cnt <= is_dpc ? 16'h0C00 : 16'h0800; end
					2'd1: begin fill <= !is_dpc; src <= 17'h06C00; dst <= is_dpc ? 14'h0C00 : 14'h0800;
						cnt <= is_dpc ? 16'h1400 : ram_size - 16'h0800; end
					default: begin init_busy <= 1'b0; phase <= 3'd0; end
				endcase
			end
		endcase
	end
endmodule

// ============================================================== audio engine
module fe3_audio (
	input  logic        clk, reset,
	input  logic [15:0] sl,
	input  logic        is_dpc, is_cdf, is_bus, jplus,
	input  logic  [1:0] revision,
	input  logic [16:0] rom_size,
	input  logic [15:0] ram_size,
	input  logic [13:0] audio_size_addr,
	input  logic  [7:0] mode,
	input  logic  [6:0] wave0, wave1, wave2,
	input  logic        note_pending,
	input  logic  [1:0] note_voice,
	input  logic  [7:0] note_value,
	output logic        note_taken,
	input  logic        call_launch, call_done, cp_active,
	input  logic [31:0] w, rom_q, ram_q, st_q,
	output logic        a_w_en,
	output logic  [1:0] a_w_src,
	output logic  [3:0] a_b_sel,
	output logic [14:0] a_rom_addr,
	output logic [11:0] a_ram_addr,
	output logic  [7:0] a_st_addr,
	output logic        a_st_we,
	output logic  [7:0] amplitude
);
	localparam logic [23:0] CLK_RATE = 24'd14318182, AUDIO_RATE = 24'd20000;
	logic [23:0] acc;
	wire tick = acc >= CLK_RATE - AUDIO_RATE;
	always_ff @(posedge clk) acc <= acc + (tick ? AUDIO_RATE - CLK_RATE : AUDIO_RATE);

	// one job per 6507 cycle, run in s8-s11 and s0 with the shared W
	// jobs: 0 idle, 1 voice update + sample, 2 digital sample, 3 note,
	// 4 seed snapshot, 5 merge counter, 6 merge frequency
	logic [2:0] job, job_q;
	logic [1:0] voice;
	logic [2:0] ticks;
	logic       launch_p, done_p, digital_now;
	logic [14:0] ofs;
	logic  [4:0] sh;
	logic  [9:0] ssum;
	logic        nibble, dig_rom, dig_ram;
	wire digital_mode = (is_bus && revision == 2'd3 && mode[7:4] == 4'b0) || (is_cdf && mode[7:4] == 4'b0);
	always_ff @(posedge clk) begin
		if (reset) begin ticks <= 3'd0; launch_p <= 1'b0; done_p <= 1'b0; end
		else begin
			if (tick && !(sl[7] && job == 3'd0 && ticks != 0)) ticks <= ticks + 3'd1;
			else if (sl[7] && job == 3'd0 && ticks != 0 && !tick) ticks <= ticks - 3'd1;
			if (call_launch) launch_p <= 1'b1;
			if (call_done) done_p <= 1'b1;
			if (sl[7] && job == 3'd4 && voice == 2'd2) launch_p <= 1'b0;
			if (sl[7] && job == 3'd6 && voice == 2'd2) done_p <= 1'b0;
		end
	end
	// choose the next job at s7
	always_ff @(posedge clk)
		if (reset) begin job <= 3'd0; voice <= 2'd0; end
		else if (sl[7] && !cp_active) begin
			if (job != 3'd0) begin
				// continue the current job over the voices
				if (job == 3'd1 && voice == 2'd2) begin job <= digital_mode ? 3'd2 : 3'd0; voice <= 2'd0; end
				else if (job == 3'd5) job <= 3'd6;
				else if (job == 3'd6) begin job <= voice == 2'd2 ? 3'd0 : 3'd5; voice <= voice + 2'd1; end
				else if (job == 3'd2 || job == 3'd3 || voice == 2'd2) begin job <= 3'd0; voice <= 2'd0; end
				else voice <= voice + 2'd1;
			end else if (launch_p) job <= 3'd4;
			else if (done_p) job <= 3'd5;
			else if (note_pending && is_dpc) job <= 3'd3;
			else if (ticks != 0) job <= 3'd1;
		end
	assign note_taken = sl[7] && job == 3'd3;

	localparam logic [7:0] ST_C = 8'h20, ST_F = 8'h24, ST_SEED = 8'h28, ST_RC = 8'h2C, ST_RF = 8'h30;
	wire [6:0] wsel = voice == 2'd0 ? wave0 : (voice == 2'd1 ? wave1 : wave2);
	wire [11:0] wave_base = is_cdf ? (revision == 2'd0 ? 12'h1FC : 12'h06C) : 12'h1FD;
	// sample index: one barrel shift of the counter, 15 bits kept
	wire [31:0] shifted = w >> sh;
	wire [14:0] sidx = ofs + shifted[14:0];
	wire [14:0] saddr = jplus ? (15'h0800 + sidx) & (ram_size[14:0] - 15'd1) : 15'h0800 + {3'b0, sidx[11:0]};
	wire [15:0] p16 = ram_q[15:0];
	wire        ptr_ok = ram_q[31:16] == 16'h4000 && p16 >= 16'h0800 && (jplus ? p16 < ram_size : p16 < 16'h1800);
	wire  [1:0] slane = is_dpc ? w[28:27] : saddr[1:0];
	wire  [7:0] sbyte = ram_q[{slane, 3'b000} +: 8];
	wire [31:0] dq = dig_rom ? rom_q : ram_q;
	wire  [7:0] dbyte = dq[{w[1:0], 3'b000} +: 8];
	wire        in_rom = w[31:17] == 15'b0 && w[16:0] < rom_size;
	wire        in_ram = w[31:16] == 16'h4000 && w[15:0] < ram_size;

	always_comb begin
		a_w_en = 1'b0; a_w_src = 2'd1; a_b_sel = 4'd7;
		a_st_addr = ST_C + {6'b0, voice}; a_st_we = 1'b0;
		a_ram_addr = wave_base + {10'b0, voice};
		a_rom_addr = w[16:2];
		case (job)
			3'd1: begin   // c += f, then sample
				if (sl[9]) begin a_w_en = 1'b1; a_st_addr = ST_F + {6'b0, voice}; a_ram_addr = wave_base + {10'b0, voice}; end
				if (sl[10]) begin a_w_en = 1'b1; a_w_src = 2'd2; a_ram_addr = audio_size_addr[13:2] + {10'b0, voice}; end
				if (sl[11]) a_st_we = 1'b1;
				if (sl[0]) a_ram_addr = is_dpc ? 12'h300 + {2'b0, wsel, w[31:29]} : saddr[13:2];
			end
			3'd2: begin   // digital sample from ROM or RAM
				if (sl[9]) begin a_w_en = 1'b1; a_w_src = 2'd0; end
				if (sl[10]) begin a_w_en = 1'b1; a_w_src = 2'd2; a_b_sel = jplus ? 4'd8 : 4'd9; end
				if (sl[11]) a_ram_addr = w[13:2];
			end
			3'd3: begin   // note: frequency word to the state RAM
				a_ram_addr = 12'h700 + {4'b0, note_value};
				a_st_addr = ST_F + {6'b0, note_voice};
				if (sl[9]) begin a_w_en = 1'b1; a_w_src = 2'd0; end
				if (sl[10]) a_st_we = 1'b1;
			end
			3'd4: begin   // seed snapshot at launch
				if (sl[9]) a_w_en = 1'b1;
				if (sl[10]) begin a_st_addr = ST_SEED + {6'b0, voice}; a_st_we = 1'b1; end
			end
			3'd5: begin   // merge returned counter if the ARM changed it
				a_st_addr = sl[8] ? ST_RC + {6'b0, voice} : (sl[9] ? ST_SEED + {6'b0, voice} : ST_C + {6'b0, voice});
				if (sl[9]) a_w_en = 1'b1;
				if (sl[10]) a_st_we = w != st_q;
			end
			3'd6: begin   // returned frequency
				a_st_addr = sl[8] ? ST_RF + {6'b0, voice} : ST_F + {6'b0, voice};
				if (sl[9]) a_w_en = 1'b1;
				if (sl[10]) a_st_we = 1'b1;
			end
			default: ;
		endcase
	end

	always_ff @(posedge clk) begin
		if (reset) begin amplitude <= 8'b0; ssum <= 10'b0; end
		else begin
			if (job == 3'd1) begin
				if (sl[10]) ofs <= ptr_ok ? {ram_q[14:12], ram_q[11:0]} - 15'h0800 : 15'b0;
				if (sl[11]) sh <= is_dpc ? 5'd27 : (audio_size_addr == 14'b0 ? 5'd27 : ram_q[11:7]);
				if (sl[1]) begin
					if (voice == 2'd0) ssum <= {2'b0, sbyte};
					else ssum <= ssum + {2'b0, sbyte};
					if (voice == 2'd2 && !digital_mode) amplitude <= ssum[7:0] + sbyte;
				end
			end
			if (job == 3'd2) begin
				if (sl[10]) nibble <= jplus ? st_q[12] : st_q[20];
				if (sl[11]) begin dig_rom <= in_rom; dig_ram <= in_ram; end
				if (sl[0]) amplitude <= {4'b0, {4{dig_rom || dig_ram}} & (nibble ? dbyte[3:0] : dbyte[7:4])};
			end
		end
	end
endmodule
