// Area / logic-depth sketch of the proposed Pocket BupChip core ("P2"):
// 2-stage pipeline (the ROM's address register is the IF/EX register),
// single-cycle EX, W stage for load data with forwarding, flop or LVT/MLAB
// register file. NOT functionally verified - written only so Yosys can count
// cells and logic levels for the proposal. Uses the MIT arm7tdmi_pkg helpers.
//
// From the design study behind docs/BUPCHIP_CORE.md, kept as the study left
// it apart from the changes listed in ../README.md. It is not the core
// (src/fpga/core/bupchip/bup_cpu.sv).
//
// SPDX-License-Identifier: MIT
import arm7tdmi_pkg::*;

module rf_bank (                       // 16x32, 1 write, 1 async read
	input  logic        clk,
	input  logic        we,
	input  logic [3:0]  wa,
	input  logic [31:0] wd,
	input  logic [3:0]  ra,
	output logic [31:0] rd
);
	logic [31:0] m [0:15];
	always_ff @(posedge clk) if (we) m[wa] <= wd;
	assign rd = m[ra];
endmodule

module bup_core_sketch #(
	parameter bit RF_LVT = 1'b0
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        run,              // ~pause && enabled && asset_ready
	output logic [11:0] rom_a_addr,       // word address into the 16 KiB window
	input  logic [31:0] rom_a_q,
	output logic [31:0] d_addr,
	output logic [1:0]  d_region,         // 0 ROM, 1 RAM, 2 asset, 3 MMIO
	output logic        d_load,
	output logic        d_ram_we,
	output logic        d_mmio_sel,
	output logic        d_mmio_wr,
	output logic [3:0]  d_be,
	output logic [31:0] d_wdata,
	input  logic [31:0] rom_b_q,
	input  logic [31:0] ram_q,
	input  logic [31:0] asset_q,
	input  logic [31:0] mmio_q,
	input  logic        w_asset_miss,
	output logic        halted,
	output logic [13:0] dbg_pc
);
	// ------------------------------------------------------------ state
	logic [13:0] pc;                      // byte address of the instruction in EX
	logic        ex_valid;
	logic [3:0]  nzcv;
	logic        seq_busy;                // LDM/STM beats after the first
	logic [15:0] seq_list;
	logic [31:0] seq_addr;
	logic        mull_hi;                 // UMULL second cycle
	logic        shreg_go;                // shift-by-register second cycle
	logic [7:0]  shreg_amt;
	// W stage
	logic        w_valid, w_pcload, w_signed;
	logic [3:0]  w_rd;
	logic [1:0]  w_size, w_lane, w_src;
	logic        w_dppc;
	logic [13:0] w_pcval;

	wire [31:0] ir = rom_a_q;

	// ------------------------------------------------------------ decode
	wire c_bx   = ir[27:4] == 24'h12FFF1;
	wire c_mul  = ir[27:22] == 6'b0 && ir[7:4] == 4'b1001;
	wire c_mull = ir[27:23] == 5'b00001 && ir[7:4] == 4'b1001;
	wire c_hx   = ir[27:25] == 3'b000 && ir[7] && ir[4] && ir[6:5] != 2'b00;
	wire c_mrs  = ir[27:23] == 5'b00010 && ir[21:16] == 6'b001111;
	wire c_msr  = ir[27:26] == 2'b00 && ir[24:23] == 2'b10 && ir[21:20] == 2'b10;
	wire c_dp   = ir[27:26] == 2'b00 && !c_bx && !c_mul && !c_mull && !c_hx && !c_mrs && !c_msr
	              && !(!ir[25] && ir[7] && ir[4]);
	wire c_sdt  = ir[27:26] == 2'b01 && !(ir[25] && ir[4]);
	wire c_bdt  = ir[27:25] == 3'b100;
	wire c_b    = ir[27:25] == 3'b101;
	wire c_undef = !(c_bx || c_mul || c_mull || c_hx || c_mrs || c_msr || c_dp || c_sdt || c_bdt || c_b)
	              || (c_mull && (ir[22] || ir[21])) || (c_bdt && (ir[22] || ir[15:0] == 0));
	wire dp_shreg = c_dp && !ir[25] && ir[4];
	wire [3:0] dpop = ir[24:21];
	wire dp_cmp  = dpop[3:2] == 2'b10;          // TST TEQ CMP CMN
		wire is_load  = ((c_sdt || c_hx) && ir[20]) || (c_bdt && ir[20]);
	wire is_store = ((c_sdt || c_hx) && !ir[20]) || (c_bdt && !ir[20]);
	wire xfer_wb  = (c_sdt || c_hx) && (ir[21] || !ir[24]);

	wire cond_ok  = ex_valid && arm7tdmi_pkg::condition_pass(ir[31:28], nzcv) && !w_pcload;

	// ------------------------------------------------------------ LDM/STM
	wire [15:0] cur_list = seq_busy ? seq_list : ir[15:0];
	logic [3:0] cur_reg;
	always_comb begin
		cur_reg = 4'd0;
		for (int i = 15; i >= 0; i--) if (cur_list[i]) cur_reg = 4'(i);
	end
	wire [15:0] rest_list = cur_list & (cur_list - 16'd1);
	logic [4:0] popc;
	always_comb begin
		popc = 5'd0;
		for (int i = 0; i < 16; i++) popc = popc + 5'(ir[i]);
	end

	// ------------------------------------------------------------ register file
	wire [3:0] i1 = c_mul ? ir[15:12] : ir[19:16];
	wire [3:0] i2 = ir[3:0];
	wire st_data = (c_sdt || c_hx) && !ir[20];
	wire [3:0] i3 = c_bdt ? cur_reg : (st_data ? ir[15:12] : ir[11:8]);

	logic        we_e, we_w;
	logic [3:0]  wa_e;
	logic [31:0] wd_e, w_data;
	logic [31:0] r1, r2, r3;

	generate if (!RF_LVT) begin : g_flops
		logic [31:0] rf [0:14];
		always_ff @(posedge clk) begin
			if (we_w && w_rd != 4'd15) rf[w_rd] <= w_data;
			if (we_e && wa_e != 4'd15) rf[wa_e] <= wd_e;   // EX (younger) wins
		end
		assign r1 = rf[i1];
		assign r2 = rf[i2];
		assign r3 = rf[i3];
	end else begin : g_lvt
		logic [15:0] lvt;                   // 1 = W bank holds the newest value
		logic [31:0] e1, e2, e3, x1, x2, x3;
		rf_bank be1 (.clk, .we(we_e), .wa(wa_e), .wd(wd_e), .ra(i1), .rd(e1));
		rf_bank be2 (.clk, .we(we_e), .wa(wa_e), .wd(wd_e), .ra(i2), .rd(e2));
		rf_bank be3 (.clk, .we(we_e), .wa(wa_e), .wd(wd_e), .ra(i3), .rd(e3));
		rf_bank bw1 (.clk, .we(we_w), .wa(w_rd), .wd(w_data), .ra(i1), .rd(x1));
		rf_bank bw2 (.clk, .we(we_w), .wa(w_rd), .wd(w_data), .ra(i2), .rd(x2));
		rf_bank bw3 (.clk, .we(we_w), .wa(w_rd), .wd(w_data), .ra(i3), .rd(x3));
		always_ff @(posedge clk) begin
			if (we_w) lvt[w_rd] <= 1'b1;
			if (we_e) lvt[wa_e] <= 1'b0;
		end
		assign r1 = lvt[i1] ? x1 : e1;
		assign r2 = lvt[i2] ? x2 : e2;
		assign r3 = lvt[i3] ? x3 : e3;
	end endgenerate

	wire [31:0] pc8 = {18'b0, pc} + 32'd8;
	wire fw1 = w_valid && !w_pcload && w_rd == i1;
	wire fw2 = w_valid && !w_pcload && w_rd == i2;
	wire fw3 = w_valid && !w_pcload && w_rd == i3;
	wire [31:0] p1 = i1 == 4'd15 ? pc8 : (fw1 ? w_data : r1);
	wire [31:0] p2 = i2 == 4'd15 ? pc8 : (fw2 ? w_data : r2);
	wire [31:0] p3 = i3 == 4'd15 ? pc8 + 32'd4 : (fw3 ? w_data : r3);

	// ------------------------------------------------------------ W stage data
	logic [31:0] w_raw, w_rot;
	always_comb begin
		case (w_src)
			2'd0: w_raw = rom_b_q;
			2'd1: w_raw = ram_q;
			2'd2: w_raw = asset_q;
			default: w_raw = mmio_q;
		endcase
		w_rot = arm7tdmi_pkg::ror32(w_raw, {w_lane, 3'b000});
		case (w_size)
			2'd0: w_data = {{24{w_signed & w_rot[7]}}, w_rot[7:0]};
			2'd1: w_data = (w_signed && w_lane[0]) ? {{24{w_rot[7]}}, w_rot[7:0]}
			                                       : {{16{w_signed & w_rot[15]}}, w_rot[15:0]};
			default: w_data = w_rot;
		endcase
		if (w_dppc) w_data = {18'b0, w_pcval};
	end

	// ------------------------------------------------------------ shifter
	logic [31:0] sh_in;
	logic [1:0]  sh_t;
	logic [7:0]  sh_a;
	logic        rrx;
	arm7tdmi_pkg::arm_shift_t sh;
	always_comb begin
		rrx = 1'b0;
		if (c_dp && ir[25]) begin
			sh_in = {24'b0, ir[7:0]};
			sh_t = 2'b11;
			sh_a = {3'b0, ir[11:8], 1'b0};
		end else begin
			sh_in = p2;
			sh_t = ir[6:5];
			if (dp_shreg) sh_a = shreg_amt;
			else begin
				sh_a = {3'b0, ir[11:7]};
				if (ir[11:7] == 5'd0 && (ir[6:5] == 2'b01 || ir[6:5] == 2'b10)) sh_a = 8'd32;
				if (ir[11:7] == 5'd0 && ir[6:5] == 2'b11) rrx = 1'b1;
			end
		end
		sh = arm7tdmi_pkg::shift_register(sh_in, sh_t, sh_a, nzcv[1]);
		if (rrx) begin
			sh.value = {nzcv[1], p2[31:1]};
			sh.carry = p2[0];
		end
	end

	// ------------------------------------------------------------ ALU
	logic [31:0] opb, alu, x, y;
	logic [3:0]  op;
	logic        cin, cout, vflag, arith;
	logic [32:0] sum;
	always_comb begin
		if (c_dp) opb = sh.value;
		else if (c_sdt) opb = ir[25] ? sh.value : {20'b0, ir[11:0]};
		else opb = ir[22] ? {24'b0, ir[11:8], ir[3:0]} : p2;
		op = c_dp ? dpop : (ir[23] ? 4'h4 : 4'h2);
		arith = !(op == 4'h0 || op == 4'h1 || op == 4'h8 || op == 4'h9 || op[3:2] == 2'b11);
		x = (op == 4'h3 || op == 4'h7) ? opb : p1;
		y = (op == 4'h3 || op == 4'h7) ? p1 : opb;
		case (op)
			4'h2, 4'h3, 4'hA: begin y = ~y; cin = 1'b1; end
			4'h6, 4'h7:       begin y = ~y; cin = nzcv[1]; end
			4'h5:             cin = nzcv[1];
			default:          cin = 1'b0;
		endcase
		sum = {1'b0, x} + {1'b0, y} + {32'b0, cin};
		cout = sum[32];
		vflag = (x[31] == y[31]) && (sum[31] != x[31]);
		case (op)
			4'h0, 4'h8: alu = p1 & opb;
			4'h1, 4'h9: alu = p1 ^ opb;
			4'hC:       alu = p1 | opb;
			4'hD:       alu = opb;
			4'hE:       alu = p1 & ~opb;
			4'hF:       alu = ~opb;
			default:    alu = sum[31:0];
		endcase
	end

	// ------------------------------------------------------------ multiplier
	wire [63:0] prod = p2 * p3;                       // Rm * Rs, unsigned
	wire [31:0] mul_lo = prod[31:0] + (ir[21] ? p1 : 32'd0);

	// ------------------------------------------------------------ data side
	wire [31:0] base = p1;
	wire [31:0] bdt_start = ir[23] ? (ir[24] ? base + 32'd4 : base)
	                               : (base - {25'b0, popc, 2'b00} + (ir[24] ? 32'd0 : 32'd4));
	wire [31:0] bdt_wb = ir[23] ? base + {25'b0, popc, 2'b00} : base - {25'b0, popc, 2'b00};
	wire [31:0] ea = c_bdt ? (seq_busy ? seq_addr : bdt_start) : (ir[24] ? alu : p1);
	logic [1:0] region;
	logic       dabort;
	always_comb begin
		dabort = 1'b0;
		region = 2'd0;
		if (ea[31:24] == 8'h00 && ea[23:14] == 10'd0) region = 2'd0;
		else if (ea[31:24] == 8'h40 && ea[23:14] == 10'd0) region = 2'd1;
		else if (ea[31:24] == 8'h02) region = 2'd2;
		else if (ea[31:8] == 24'hE00090) region = 2'd3;
		else dabort = 1'b1;
	end
	logic [1:0] msize;   // 0 byte 1 half 2 word
	always_comb begin
		if (c_hx) msize = ir[6:5] == 2'b10 ? 2'd0 : 2'd1;
		else if (c_sdt) msize = ir[22] ? 2'd0 : 2'd2;
		else msize = 2'd2;
	end
	wire mem_op = cond_ok && (is_load || is_store);
	wire bad_store = is_store && (region == 2'd0 || region == 2'd2);

	// ------------------------------------------------------------ control
	wire multi_more = (c_bdt && cond_ok && rest_list != 16'd0)
	                  || (c_mull && cond_ok && !mull_hi)
	                  || (dp_shreg && cond_ok && !shreg_go);
	wire fault = ex_valid && !w_pcload && !halted &&
	             ((cond_ok && c_undef) || (mem_op && (dabort || bad_store)) ||
	              (cond_ok && c_bx && p2[0]));
	wire advance = run && !w_asset_miss && !halted;
	wire commit = advance && cond_ok && !fault;

	assign d_addr = ea;
	assign d_region = region;
	assign d_load = mem_op && is_load && !(dp_shreg && !shreg_go);
	assign d_ram_we = commit && is_store && region == 2'd1;
	assign d_mmio_sel = commit && (is_load || is_store) && region == 2'd3;
	assign d_mmio_wr = is_store;
	assign d_be = msize == 2'd0 ? (4'b0001 << ea[1:0]) : msize == 2'd1 ? (ea[1] ? 4'b1100 : 4'b0011) : 4'b1111;
	assign d_wdata = msize == 2'd0 ? {4{p3[7:0]}} : msize == 2'd1 ? {2{p3[15:0]}} : p3;

	// EX write port
	always_comb begin
		we_e = 1'b0; wa_e = ir[15:12]; wd_e = alu;
		if (commit) begin
			if (c_dp && !dp_cmp && !(dp_shreg && !shreg_go)) begin we_e = ir[15:12] != 4'd15; wd_e = alu; end
			else if (c_mul) begin we_e = 1'b1; wa_e = ir[19:16]; wd_e = mul_lo; end
			else if (c_mull) begin we_e = 1'b1; wa_e = mull_hi ? ir[19:16] : ir[15:12]; wd_e = mull_hi ? prod[63:32] : prod[31:0]; end
			else if (c_b && ir[24]) begin we_e = 1'b1; wa_e = 4'd14; wd_e = {18'b0, pc} + 32'd4; end
			else if ((c_sdt || c_hx) && xfer_wb) begin we_e = 1'b1; wa_e = ir[19:16]; wd_e = alu; end
			else if (c_bdt && ir[21] && !seq_busy) begin we_e = 1'b1; wa_e = ir[19:16]; wd_e = bdt_wb; end
			else if (c_mrs) begin we_e = 1'b1; wd_e = {nzcv, 20'b0, 8'hD3}; end
		end
	end
	assign we_w = w_valid && !w_asset_miss && !w_pcload;

	// next PC (word address into the ROM)
	wire take_b  = cond_ok && c_b;
	wire take_bx = cond_ok && c_bx;
	wire [13:0] br_tgt = pc + 14'd8 + {ir[11:0], 2'b00};
	logic [13:0] npc;
	always_comb begin
		if (w_pcload && !w_asset_miss) npc = w_dppc ? w_pcval : w_data[13:0];
		else if (!advance || multi_more || fault) npc = pc;
		else if (take_b) npc = br_tgt;
		else if (take_bx) npc = p2[13:0];
		else npc = pc + 14'd4;
	end
	assign rom_a_addr = npc[13:2];
	assign dbg_pc = pc;

	always_ff @(posedge clk) begin
		if (rst) begin
			pc <= 14'd0; ex_valid <= 1'b0; nzcv <= 4'd0; seq_busy <= 1'b0; mull_hi <= 1'b0;
			shreg_go <= 1'b0; w_valid <= 1'b0; w_pcload <= 1'b0; halted <= 1'b0; w_dppc <= 1'b0;
		end else begin
			if (fault) halted <= 1'b1;
			if (!w_asset_miss) begin
				w_valid <= 1'b0; w_pcload <= 1'b0; w_dppc <= 1'b0;
			end
			if (advance) begin
				pc <= npc;
				ex_valid <= 1'b1;
				if (commit && is_load) begin
					w_valid <= 1'b1;
					w_rd <= c_bdt ? cur_reg : ir[15:12];
					w_pcload <= c_sdt && ir[15:12] == 4'd15;
					w_src <= region;
					w_lane <= ea[1:0];
					w_size <= msize;
					w_signed <= c_hx && ir[6];
				end
				if (commit && c_dp && !dp_cmp && ir[15:12] == 4'd15) begin
					w_pcload <= 1'b1; w_dppc <= 1'b1; w_pcval <= alu[13:0];
				end
				// flags
				if (commit && c_dp && ir[20] && !(dp_shreg && !shreg_go))
					nzcv <= {alu[31], alu == 32'd0, arith ? cout : sh.carry, arith ? vflag : nzcv[0]};
				else if (commit && c_mul && ir[20])
					nzcv <= {mul_lo[31], mul_lo == 32'd0, nzcv[1:0]};
				else if (commit && c_msr && ir[19])
					nzcv <= ir[25] ? sh.value[31:28] : p2[31:28];
				// sequencing
				if (c_bdt && cond_ok) begin
					seq_busy <= rest_list != 16'd0;
					seq_list <= rest_list;
					seq_addr <= ea + 32'd4;
				end
				mull_hi <= c_mull && cond_ok && !mull_hi;
				shreg_go <= dp_shreg && cond_ok && !shreg_go;
				if (dp_shreg && !shreg_go) shreg_amt <= p3[7:0];
			end
		end
	end
endmodule
