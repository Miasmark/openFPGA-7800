// The AtariVox speech engine (docs/ATARIVOX.md, "The engine"): a small
// processor that runs tools/atarivox/voxprog.py's program, which both
// interprets SpeakJet codes and synthesizes the voice. Its reference is
// tools/atarivox/voxeng.py, which this matches clock for clock.
//
// Every instruction takes 4 clocks:
//   0  the instruction ROM latches pc
//   1  the instruction is out; the register file latches a and b
//   2  a and b are out: the ALU and multiplier work; the data ROM latches
//      its address, register file copy A the ldm address
//   3  write back, I/O, next pc
// Registers r0-r63 and data words 64-255 share two block RAM copies (one per
// read port; both written). r0 is never written, so reads 0.
//
// MIT licence, as the rest of the Pocket port's own code.

module avox_engine (
	input  logic        clk,
	input  logic        reset,

	// status (in 0): set pulses; cleared when read
	input  logic        tick,
	input  logic        abort_set,
	input  logic        ready_set,

	// FIFO (in 1 pops, in 3 tests)
	input  logic  [7:0] fifo_q,
	input  logic        fifo_nonempty,
	output logic        fifo_pop,

	output logic signed [15:0] sample,     // out 0
	output logic        sample_strobe
);

	localparam [4:0] OP_ADD = 5'd0, OP_SUB = 5'd1, OP_AND = 5'd2, OP_OR = 5'd3, OP_XOR = 5'd4,
		OP_ADDI = 5'd5, OP_ANDI = 5'd6, OP_ORI = 5'd7, OP_LUI = 5'd8, OP_MUL = 5'd9,
		OP_HI12 = 5'd10, OP_SIN = 5'd11, OP_LDR = 5'd12, OP_LDRS = 5'd13, OP_LDM = 5'd14,
		OP_STM = 5'd15, OP_BEQ = 5'd16, OP_BNE = 5'd17, OP_BLT = 5'd18, OP_BGE = 5'd19,
		OP_BLTU = 5'd20, OP_JAL = 5'd21, OP_JR = 5'd22, OP_IN = 5'd23, OP_OUT = 5'd24;

	/* verilator lint_off PROCASSINIT */  // power-up values (DEVELOPING.md, "Power-up values")
	logic [1:0] st = 2'd0;
	logic [9:0] pc = 10'd0;
	/* verilator lint_on PROCASSINIT */

	// ---------------------------------------------------------------- ROMs
	/* verilator lint_off UNUSEDSIGNAL */
	logic [39:0] ir;                  // ir[16] is a spare bit of the encoding
	/* verilator lint_on UNUSEDSIGNAL */
	cache_ram #(
		.ADDR_WIDTH    (10),
		.DATA_WIDTH    (40),
		.MEM_INIT_FILE ("core/atarivox/vox_irom.mif"),
		.SIM_INIT_FILE ("rtl/vox_irom.hex")
	) irom (
		.clk_i   (clk),
		.addr_i  (pc),
		.wren_i  (1'b0),
		.wdata_i (40'd0),
		.q_o     (ir)
	);

	wire  [4:0] op   = ir[39:35];
	wire  [5:0] f_d  = ir[34:29];
	wire  [5:0] f_a  = ir[28:23];
	wire  [5:0] f_b  = ir[22:17];
	wire [15:0] imm  = ir[15:0];
	wire [31:0] simm = {{16{imm[15]}}, imm};

	logic [31:0] ra, rb;              // register file copies A and B
	wire  [31:0] a_plus_imm = ra + simm;

	logic [11:0] drom_addr;
	logic [19:0] drom_q;
	always_comb
		drom_addr = (op == OP_SIN) ? {3'd0, ra[30:22]} : a_plus_imm[11:0];
	cache_ram #(
		.ADDR_WIDTH    (12),
		.DATA_WIDTH    (20),
		.MEM_INIT_FILE ("core/atarivox/vox_drom.mif"),
		.SIM_INIT_FILE ("rtl/vox_drom.hex")
	) drom (
		.clk_i   (clk),
		.addr_i  (drom_addr),
		.wren_i  (1'b0),
		.wdata_i (20'd0),
		.q_o     (drom_q)
	);

	// ---------------------------------------------------------------- registers
	logic  [7:0] wr_addr;
	logic [31:0] wr_data;
	logic        wr_en;
	logic  [7:0] maddr;               // ldm / stm address, from cycle 2

	wire  [7:0] rfa_addr = (st == 2'd3) ? wr_addr : (st == 2'd2) ? a_plus_imm[7:0] : {2'b00, f_a};
	wire  [7:0] rfb_addr = (st == 2'd3) ? wr_addr : {2'b00, f_b};
	wire        rf_we    = (st == 2'd3) && wr_en;

	cache_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) rf_a (
		.clk_i(clk), .addr_i(rfa_addr), .wren_i(rf_we), .wdata_i(wr_data), .q_o(ra));
	cache_ram #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) rf_b (
		.clk_i(clk), .addr_i(rfb_addr), .wren_i(rf_we), .wdata_i(wr_data), .q_o(rb));

	// ---------------------------------------------------------------- ALU (cycle 2)
	/* verilator lint_off UNUSEDSIGNAL */
	wire signed [53:0] prod = $signed(ra[26:0]) * $signed(rb[26:0]);  // no shift selects [53:48]
	/* verilator lint_on UNUSEDSIGNAL */
	logic [31:0] alu;
	always_comb begin
		case (op)
			OP_ADD:  alu = ra + rb;
			OP_SUB:  alu = ra - rb;
			OP_AND:  alu = ra & rb;
			OP_OR:   alu = ra | rb;
			OP_XOR:  alu = ra ^ rb;
			OP_ADDI: alu = a_plus_imm;
			OP_ANDI: alu = ra & {16'd0, imm};
			OP_ORI:  alu = ra | {16'd0, imm};
			OP_LUI:  alu = {imm, 16'd0};
			OP_MUL:  case (imm[1:0])
			             2'd0: alu = prod[31:0];
			             2'd1: alu = prod[38:7];
			             2'd2: alu = prod[43:12];
			             default: alu = prod[47:16];
			         endcase
			OP_HI12: alu = {20'd0, ra[31:20]};
			OP_JAL:  alu = {22'd0, pc + 10'd1};
			OP_OUT:  alu = ra;
			default: alu = 32'd0;
		endcase
	end

	wire eq  = (ra == rb);
	wire lt  = ($signed(ra) < $signed(rb));
	wire ltu = (ra < rb);
	logic take;
	always_comb begin
		case (op)
			OP_BEQ:  take = eq;
			OP_BNE:  take = ~eq;
			OP_BLT:  take = lt;
			OP_BGE:  take = ~lt;
			OP_BLTU: take = ltu;
			OP_JAL:  take = 1'b1;
			default: take = 1'b0;
		endcase
	end

	logic [31:0] res;
	logic  [9:0] npc;
	logic [31:0] b_hold;               // stm data

	// ---------------------------------------------------------------- I/O
	/* verilator lint_off PROCASSINIT */
	logic        f_tick = 1'b0, f_abort = 1'b0, f_ready = 1'b0;
	logic [15:0] lfsr = 16'hACE1;
	/* verilator lint_on PROCASSINIT */
	wire         is_in  = (st == 2'd3) && (op == OP_IN);
	wire         rd_st  = is_in && (imm[1:0] == 2'd0);
	wire         rd_lf  = is_in && (imm[1:0] == 2'd2);
	assign fifo_pop     = is_in && (imm[1:0] == 2'd1) && fifo_nonempty;

	logic [31:0] in_data;
	always_comb begin
		case (imm[1:0])
			2'd0:    in_data = {28'd0, f_ready, f_abort, 1'b0, f_tick};
			2'd1:    in_data = {24'd0, fifo_nonempty ? fifo_q : 8'd0};
			2'd2:    in_data = {16'd0, lfsr};
			default: in_data = {31'd0, fifo_nonempty};
		endcase
	end

	// ---------------------------------------------------------------- write back (cycle 3)
	always_comb begin
		wr_en   = 1'b0;
		wr_addr = {2'b00, f_d};
		wr_data = res;
		case (op)
			OP_STM: begin wr_en = (maddr != 8'd0); wr_addr = maddr; wr_data = b_hold; end
			OP_LDM: begin wr_en = (f_d != 6'd0); wr_data = ra; end
			OP_SIN, OP_LDR: begin wr_en = (f_d != 6'd0); wr_data = {12'd0, drom_q}; end
			OP_LDRS: begin wr_en = (f_d != 6'd0); wr_data = {{12{drom_q[19]}}, drom_q}; end
			OP_IN:   begin wr_en = (f_d != 6'd0); wr_data = in_data; end
			OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_JR, OP_OUT: wr_en = 1'b0;
			default: wr_en = (f_d != 6'd0);
		endcase
	end

	always_ff @(posedge clk) begin
		sample_strobe <= 1'b0;
		if (reset) begin
			st      <= 2'd0;
			pc      <= 10'd0;
			f_tick  <= 1'b0;
			f_abort <= 1'b0;
			f_ready <= 1'b0;
			lfsr    <= 16'hACE1;
			sample  <= 16'sd0;
		end else begin
			st <= st + 2'd1;
			if (st == 2'd2) begin
				res    <= alu;
				maddr  <= a_plus_imm[7:0];
				b_hold <= rb;
				npc    <= (op == OP_JR) ? ra[9:0] : take ? imm[9:0] : pc + 10'd1;
			end
			if (st == 2'd3) begin
				pc <= npc;
				if (op == OP_OUT) begin
					sample        <= res[15:0];
					sample_strobe <= 1'b1;
				end
				if (rd_lf)
					lfsr <= {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
			end
			// flags: a read clears them; a set on the same edge wins
			f_tick  <= (f_tick  & ~rd_st) | tick;
			f_abort <= (f_abort & ~rd_st) | abort_set;
			f_ready <= (f_ready & ~rd_st) | ready_set;
		end
	end

endmodule
