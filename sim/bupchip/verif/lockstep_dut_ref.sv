//------------------------------------------------------------------------------
// Lockstep DUT shell, reference against reference: a second arm7tdmi_core
// (MUL_RETIRE_STAGE off, so its multiplies are timed differently) on a
// zero-wait bus with its own ROM, RAM and asset bytes, presented to
// tb_lockstep.sv through the same ports as the new core (README.md).
//
// The core has no register-file ports to show, so its retires are turned
// into a retire-port stream that behaves like the planned pipeline: one beat
// per clock; loaded registers on port W one clock after the beat that loads
// them; LDM/STM over n beats with the base write-back in the first; UMULL
// and shift-by-register over two; everything else on port E. With +gap=P,
// P% of clocks are idle, and an owed W write may land in one of them or
// with the next instruction's first clock, as a frozen execute stage would
// do. This exercises the testbench's shadow-state rules before the new core
// exists. A register is reported when its entry in the core's flat file
// (every bank) changed, under the mode after the instruction, and each beat
// carries the mode before it on rt_mode.
//
//   +romhex=FILE  firmware ROM (default: the ROMHEX define)
//   +rom=FILE     .a78 image; the bytes after the cartridge are the assets
//   +inject=N     flip bit 0 of the Nth data load (1-based)
//   +gap=P        idle retire-port clocks, percent (default 0)
//   +seed=S       for +gap
//
// arm7tdmi_core.sv is GPL-2.0-only and is used here only as a simulation
// oracle, through its ports and simulation-only state.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
module lockstep_dut_ref (
	input  logic        clk,
	input  logic        rst,
	output logic        rt_start,
	output logic        rt_valid,
	output logic [31:0] rt_pc,
	output logic [31:0] rt_insn,
	output logic  [3:0] rt_nzcv,
	output logic  [4:0] rt_mode,
	output logic        rt_t,			// T after the instruction
	output logic        rt_cunk,		// always 0: the reference's C is always known
	output logic        rt_e_we,
	output logic  [3:0] rt_e_idx,
	output logic [31:0] rt_e_data,
	output logic        rt_w_we,
	output logic  [3:0] rt_w_idx,
	output logic [31:0] rt_w_data,
	output logic        st_valid,
	output logic [31:0] st_addr,
	output logic  [3:0] st_strb,
	output logic [31:0] st_data,
	output logic        pw_valid,
	output logic  [7:0] pw_addr,
	output logic [31:0] pw_data,
	output logic        pr_valid,
	output logic  [7:0] pr_addr,
	output logic        pr_wait,
	input  logic        pr_avail,
	input  logic [31:0] pr_data,
	output logic        halted,
	output logic [31:0] halt_pc
);
	// ---- memories ---------------------------------------------------------
	logic [31:0] rom [0:4095];
	logic [31:0] ram [0:4095];
	logic  [7:0] img [0:4194303];
	int          img_n = 0, a_base = 0, a_size = 0, gap_pct = 0, seed = 1;
	longint      inject = -1, nloads = 0;

	initial begin
		string f;
		int fd;
		if (!$value$plusargs("romhex=%s", f)) f = `ROMHEX;
		foreach (rom[i]) rom[i] = 32'b0;
		$readmemh(f, rom);
		foreach (ram[i]) ram[i] = 32'b0;
		if (!$value$plusargs("rom=%s", f)) f = "game.a78";
		fd = $fopen(f, "rb");
		if (fd == 0) $fatal(1, "cannot open %s", f);
		img_n = $fread(img, fd);
		$fclose(fd);
		a_base = 128 + {img[49], img[50], img[51], img[52]};
		a_size = img_n > a_base ? img_n - a_base : 0;
		void'($value$plusargs("inject=%d", inject));
		void'($value$plusargs("gap=%d", gap_pct));
		void'($value$plusargs("seed=%d", seed));
		void'($urandom(seed));
	end

	// ---- the core on a zero-wait bus ----------------------------------------
	wire         d_req, d_write, d_fetch, d_retire;
	wire  [31:0] d_addr, d_wdata;
	wire   [3:0] d_wstrb;
	wire   [1:0] d_size;
	logic        d_ready, d_abort;
	logic [31:0] d_rdata;

	arm7tdmi_core #(.MUL_RETIRE_STAGE(1'b0)) core (.clk, .reset(rst),
		.ce(1'b1), .irq_n(1'b1), .fiq_n(1'b1), .halt_req(1'b0), .halted(),
		.mem_req(d_req), .mem_ready(d_ready), .mem_abort(d_abort), .mem_addr(d_addr),
		.mem_write(d_write), .mem_wdata(d_wdata), .mem_rdata(d_rdata), .mem_size(d_size),
		.mem_wstrb(d_wstrb), .mem_seq(), .mem_fetch(d_fetch), .mem_privileged(),
		.mem_lock(), .retire(d_retire), .state_req(1'b0), .state_write(1'b0),
		.state_index(6'd0), .state_wdata(32'd0), .state_rdata(), .state_ready(),
		.state_commit(1'b0));

	// The same map as bupchip_memory.sv: anything else, or a write to ROM or
	// assets, aborts.
	wire [31:0] a_off    = d_addr - 32'h02000000;
	wire        is_rom   = d_addr < 32'h4000;
	wire        is_ram   = d_addr[31:14] == 18'h10000;
	wire        is_asset = d_addr[31:24] == 8'h02 && a_off < 32'(a_size);
	wire        is_mmio  = d_addr[31:8] == 24'he00090;
	wire        bad      = d_size == 2'b11 || (d_write && (is_rom || is_asset)) ||
	                       !(is_rom || is_ram || is_asset || is_mmio);
	wire        dload    = d_req && !d_fetch && !d_write;

	assign pr_wait  = dload && is_mmio && !pr_avail;
	assign d_ready  = d_req && !pr_wait;
	assign d_abort  = d_req && bad;
	assign pr_valid = dload && d_ready && is_mmio;
	assign pr_addr  = d_addr[7:0];
	assign st_valid = d_req && d_ready && d_write && is_ram && !bad;
	assign st_addr  = {d_addr[31:2], 2'b00};
	assign st_strb  = d_wstrb;
	assign st_data  = d_wdata;
	assign pw_valid = d_req && d_ready && d_write && is_mmio && !bad;
	assign pw_addr  = d_addr[7:0];
	assign pw_data  = d_wdata;

	always_comb begin
		int o;
		o = a_base + int'({a_off[23:2], 2'b00});
		d_rdata = 32'b0;
		if (is_rom) d_rdata = rom[d_addr[13:2]];
		else if (is_ram) d_rdata = ram[d_addr[13:2]];
		else if (is_asset) d_rdata = {img[o + 3], img[o + 2], img[o + 1], img[o]};
		else if (is_mmio) d_rdata = pr_data;
		if (dload && nloads + 1 == inject) d_rdata = d_rdata ^ 32'h1;
	end

	// Instructions the core has retired before this clock. tb_lockstep.sv tags
	// this shell's bus events with it, because the retire port below runs
	// behind the bus.
	longint nret = 0;
	always @(posedge clk) if (!rst && d_retire) nret <= nret + 1;

	always @(posedge clk)
		if (rst) begin
			halted <= 1'b0;
			halt_pc <= 32'b0;
		end else if (d_req && d_ready) begin
			if (dload) nloads++;
			if (st_valid)
				for (int b = 0; b < 4; b++) if (d_wstrb[b]) ram[d_addr[13:2]][b*8 +: 8] <= d_wdata[b*8 +: 8];
			if (bad && !halted) begin halted <= 1'b1; halt_pc <= d_addr; end
		end

	// ---- retire port ----------------------------------------------------------
	typedef struct {
		logic        start, v;
		logic [31:0] pc, insn;
		logic  [3:0] f;
		logic        t;			// T after the instruction
		logic  [4:0] mode;			// the mode before the instruction
		logic        e_we;			// port E this beat
		logic  [3:0] e_idx;
		logic [31:0] e_d;
		logic        wn_we;			// port W on the following beat
		logic  [3:0] wn_idx;
		logic [31:0] wn_d;
	} beat_t;
	beat_t       bq [$];
	assign rt_cunk = 1'b0;
	logic [31:0] snap [30];		// the flat register file, every bank
	logic  [3:0] snap_f;
	logic  [4:0] snap_m;
	logic        owe_we;
	logic  [3:0] owe_idx;
	logic [31:0] owe_d;

	// As bank and ref_reg in ref_system.svh.
	function automatic int bank(input int k, input logic [4:0] m);
		if (k < 8 || m == 5'h10 || m == 5'h1f) return k;
		if (m == 5'h11) return k + 7;
		if (k < 13) return k;
		case (m)
			5'h12:   return 22 + k - 13;
			5'h13:   return 24 + k - 13;
			5'h17:   return 26 + k - 13;
			default: return 28 + k - 13;
		endcase
	endfunction
	function automatic logic [31:0] dreg(input int k);
		return core.rf[bank(k, core.cpsr[4:0])];
	endfunction

	// ARM condition codes on {N, Z, C, V}.
	function automatic logic cond_pass(input logic [3:0] c, input logic [3:0] f);
		logic n, z, cy, v;
		{n, z, cy, v} = f;
		case (c)
			4'h0: return z;          4'h1: return !z;
			4'h2: return cy;         4'h3: return !cy;
			4'h4: return n;          4'h5: return !n;
			4'h6: return v;          4'h7: return !v;
			4'h8: return cy && !z;   4'h9: return !cy || z;
			4'ha: return n == v;     4'hb: return n != v;
			4'hc: return !z && n == v;
			4'hd: return z || n != v;
			4'he: return 1'b1;
			default: return 1'b0;
		endcase
	endfunction

	// Turn one retire of the core into beats.
	task automatic add_record();
		logic [31:0] i, post [15];
		logic  [3:0] f, rn, rd;
		logic [15:0] covered;
		beat_t z, b [$];
		i = core.trace_retire_instruction;
		f = core.cpsr[31:28];
		for (int k = 0; k < 15; k++) post[k] = dreg(k);
		rn = i[19:16];
		rd = i[15:12];
		covered = 16'b0;
		z = '{default: '0};
		z.pc = core.trace_retire_pc;
		z.insn = i;
		z.f = f;
		z.t = core.cpsr[5];
		z.mode = snap_m;
		// A Thumb retire (encoding {16'h0, halfword}) is one beat with every
		// register it changed on port E, by the catch-all below.
		if (!core.trace_retire_thumb && cond_pass(i[31:28], snap_f)) begin
			if (i[27:25] == 3'b100) begin                                   // LDM / STM
				for (int k = 0; k < 16; k++) if (i[k]) begin
					beat_t x;
					x = z;
					if (b.size() == 0 && i[21]) begin
						x.e_we = 1; x.e_idx = rn; x.e_d = post[rn]; covered[rn] = 1;
					end
					if (i[20] && k != 15) begin
						x.wn_we = 1; x.wn_idx = 4'(k); x.wn_d = post[k]; covered[k] = 1;
					end
					b.push_back(x);
				end
			end else if ((i[27:26] == 2'b01 && i[20]) ||                       // LDR, LDRB
			             (i[27:25] == 3'b000 && i[7] && i[4] && i[6:5] != 2'b00 && i[20])) begin
				beat_t x;                                                    // LDRH, LDRSB, LDRSH
				x = z;
				if ((!i[24] || i[21]) && rn != rd) begin
					x.e_we = 1; x.e_idx = rn; x.e_d = post[rn]; covered[rn] = 1;
				end
				if (rd != 4'd15) begin
					x.wn_we = 1; x.wn_idx = rd; x.wn_d = post[rd]; covered[rd] = 1;
				end
				b.push_back(x);
			end else if ((i & 32'h0f8000f0) == 32'h00800090) begin            // UMULL family
				beat_t x;
				x = z; x.e_we = 1; x.e_idx = rd; x.e_d = post[rd]; b.push_back(x);
				x = z; x.e_we = 1; x.e_idx = rn; x.e_d = post[rn]; b.push_back(x);
				covered[rd] = 1;
				covered[rn] = 1;
			end else if (i[27:25] == 3'b000 && i[4] && !i[7] &&                // shift by register
			             !(i[24:23] == 2'b10 && !i[20])) begin                 // (not BX)
				b.push_back(z);
				b.push_back(z);
			end
		end
		// Whatever else changed (data processing, BL, MRS, store write-back):
		// port E, the last one in the retire beat.
		if (b.size() == 0) b.push_back(z);
		for (int k = 14; k >= 0; k--)
			if (post[k] !== snap[bank(k, core.cpsr[4:0])] && !covered[k]) begin
				if (!b[b.size() - 1].e_we) begin
					b[b.size() - 1].e_we = 1; b[b.size() - 1].e_idx = 4'(k); b[b.size() - 1].e_d = post[k];
				end else begin
					beat_t x;
					x = z; x.e_we = 1; x.e_idx = 4'(k); x.e_d = post[k];
					b.insert(b.size() - 1, x);
				end
			end
		b[0].start = 1;
		b[b.size() - 1].v = 1;
		foreach (b[n]) bq.push_back(b[n]);
		for (int k = 0; k < 30; k++) snap[k] = core.rf[k];
		snap_f = f;
		snap_m = core.cpsr[4:0];
	endtask

	always @(posedge clk) begin
		rt_start <= 0;
		rt_valid <= 0;
		rt_e_we <= 0;
		rt_w_we <= 0;
		if (rst) begin
			bq.delete();
			for (int k = 0; k < 30; k++) snap[k] = 32'b0;
			snap_f = 4'b0;
			snap_m = 5'h13;			// SVC, as the core leaves reset
			rt_mode <= 5'h13;
			rt_t <= 1'b0;
			owe_we = 0;
		end else begin
			if (d_retire) add_record();
			if (gap_pct > 0 && $urandom_range(99) < gap_pct) begin
				// An idle clock: at most the owed W write.
				if (owe_we && $urandom_range(1) == 1) begin
					rt_w_we <= 1; rt_w_idx <= owe_idx; rt_w_data <= owe_d; owe_we = 0;
				end
			end else if (bq.size() == 0) begin
				if (owe_we) begin rt_w_we <= 1; rt_w_idx <= owe_idx; rt_w_data <= owe_d; owe_we = 0; end
			end else begin
				beat_t x;
				x = bq.pop_front();
				if (owe_we) begin rt_w_we <= 1; rt_w_idx <= owe_idx; rt_w_data <= owe_d; owe_we = 0; end
				rt_start <= x.start;
				rt_valid <= x.v;
				rt_pc <= x.pc;
				rt_insn <= x.insn;
				rt_nzcv <= x.f;
				rt_t <= x.t;
				rt_mode <= x.mode;
				rt_e_we <= x.e_we;
				rt_e_idx <= x.e_idx;
				rt_e_data <= x.e_d;
				if (x.wn_we) begin owe_we = 1; owe_idx = x.wn_idx; owe_d = x.wn_d; end
			end
		end
	end
endmodule
