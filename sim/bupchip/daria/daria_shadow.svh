//------------------------------------------------------------------------------
// DARIA beside upstream (docs/DARIA_CORE.md, step 5): included in tb_daria.sv
// with -DDARIA_SHADOW (run_daria.sh with SHADOW=1). DARIA's clk_arm side runs
// the same calls as upstream's ARM and is compared with it call by call.
//
//   - DARIA: bup_cpu (THUMB 1, CODE_AW 15, the 2600 profile), daria_mem,
//     daria_call and daria_mmio on its own clk_arm, 38.18 MHz (VCO / 18).
//     The window (DARIA_WIN_KB, default 128) is loaded from the image when
//     the run starts (the capture path has its own bench, capture/); the
//     image beyond it answers on the asset port from the file, with w_wait
//     high on a random +d_await percent of clocks.
//   - Each call. When upstream's ARM starts running a call, its launch (entry,
//     T, stack, the three counters and frequencies) and its 32 KB of cart RAM
//     are taken. If DARIA is free the RAM is copied into DARIA's (a stand-in
//     for the front ends' shared RAM, step 6) and the launch is posted the
//     way the front ends will post it: the state RAM's call block through
//     port B on clk_sys, then call_tog. DARIA's return words are read back
//     through port B after ret_tog. A call that comes while DARIA is still
//     on the last one is skipped (counted).
//   - Compared, once both have returned: FIQ r8-r13 (DARIA's return words
//     against upstream's audio_*_result), every RAM write each CPU makes
//     (word address, byte lanes, data on those lanes), and every MMIO access
//     in order: writes and reads by value, except T1TC (0xE0008008) reads,
//     within +/- MMIO_TOL counts (open item 17; +mmio_tol=N, default 200);
//     the final report gives the range of DARIA's reading less upstream's.
//   - daria.csv, one line per compared call: call, frame, DARIA's clk_arm
//     from call_go to returned and the microseconds that is, the clk_sys from
//     the post to the last return word read (what a front end waits, less
//     its own share), upstream's clk_arm for the call, RAM writes and MMIO
//     accesses compared, and ok or the first difference. dynamic_tables.py
//     --only daria counts late calls with these times.
//
//   - Cart RAM collisions (open item 7): a read on the console side
//     (clk_sys: cartram_rd, audio and mapper reads) of a word one CPU writes
//     less than one clk_sys (69.84 ns) before or after. Counted for
//     upstream's ARM and for DARIA against the same console-side reads, a
//     stand-in for the front ends' (step 6). In a dual-clock M10K such a read
//     may return old or undefined data.
//
// Plusargs: +shadow_stop=N stops comparing after N bad calls (default 20);
// +d_await=P (default 0).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`ifndef DARIA_WIN_KB
`define DARIA_WIN_KB 64
`endif
`ifndef DARIA_PSRAM_CS
`define DARIA_PSRAM_CS 50.0
`endif

	// ---- DARIA's clock ---------------------------------------------------------
	logic clk_d = 0;
	always #13095 clk_d = ~clk_d;		// 26.19 ns, 8 per 3 clk_sys
	localparam real D_HZ = 687272727.0 / 18.0;

`ifdef DARIA_WRAPPER
	// ---- the wrapper as DARIA builds it, in the 2600 profile ----------------------------
	// bupchip_pocket.sv with POCKET_DARIA: the cartridge reaches it as the
	// loader delivers it (bup_capture: the window, the front-end ROM and the
	// PSRAM, at tb_daria's load_gap pace), and the image beyond the window
	// comes through the two-way cache from psram.sv (CLOCK_SPEED
	// DARIA_PSRAM_CS) on a psram_model.sv die. Calls go through the front
	// ends' ports: state RAM port B, call_tog, ret_tog, ready.
	logic clk_74a = 0;
	always #6734 clk_74a = ~clk_74a;
	wire         d_ram32 = dut.mapper_ram_size == 16'd32768;
	int          d_await = 0;		// +d_await has no effect here: the cache makes the waits
	logic  [7:0] d_stb_addr = 0;
	logic        d_stb_we = 0;
	logic [31:0] d_stb_wd = 0;
	wire  [31:0] d_stb_q;
	logic        d_call_tog = 0;
	wire         d_ret_tog, d_ready;
	wire         p_bank, p_we, p_hi, p_lo, p_re, p_avail, p_busy;
	wire  [21:0] p_addr;
	wire  [15:0] p_din, p_dout;

	bupchip_pocket #(.WIN_KB(`DARIA_WIN_KB)) dw (
		.clk_sys, .clk_arm(clk_d), .clk_74a,
		.pll_locked(1'b1), .pll_busy(1'b0), .souper_profile(1'b0), .pause(1'b0),
		.byte_valid(ioctl_wr && cart_download), .byte_hi(3'd0), .load_addr(ioctl_addr), .load_data(ioctl_dout),
		.load_start(cart_download && !old_cart_download), .load_end(!cart_download && old_cart_download),
		.fw_download(1'b0), .cmd_valid(1'b0), .cmd_data(8'd0), .audio_l(), .audio_r(),
		.psram_bank_sel(p_bank), .psram_addr(p_addr), .psram_write_en(p_we), .psram_data_in(p_din),
		.psram_write_high_byte(p_hi), .psram_write_low_byte(p_lo), .psram_read_en(p_re),
		.psram_read_avail(p_avail), .psram_data_out(p_dout), .psram_busy(p_busy),
		.daria_profile(1'b1), .daria_ram32(d_ram32), .daria_pal(1'b0), .daria_mreset(1'b0),
		.daria_call_tog(d_call_tog), .daria_ret_tog(d_ret_tog), .daria_ready(d_ready), .daria_halted(),
		.daria_stb_addr(d_stb_addr), .daria_stb_we(d_stb_we), .daria_stb_be(4'hF), .daria_stb_wd(d_stb_wd), .daria_stb_q(d_stb_q),
		.daria_crb_addr(13'd0), .daria_crb_we(1'b0), .daria_crb_be(4'd0), .daria_crb_wd(32'd0), .daria_crb_q(),
		.daria_fea_addr(13'd0), .daria_fea_q(), .daria_feb_addr(13'd0), .daria_feb_q());

	wire [21:16] cram_a;
	wire  [15:0] cram_dq;
	wire         cram_wait, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire         cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	psram #(.CLOCK_SPEED(`DARIA_PSRAM_CS)) dps (
		.clk(clk_d), .bank_sel(p_bank), .addr(p_addr), .write_en(p_we), .data_in(p_din),
		.write_high_byte(p_hi), .write_low_byte(p_lo), .read_en(p_re),
		.read_avail(p_avail), .data_out(p_dout), .busy(p_busy),
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);
	psram_model dchip (
		.cram_a, .cram_dq, .cram_wait, .cram_clk, .cram_adv_n, .cram_cre, .cram_ce0_n, .cram_ce1_n,
		.cram_oe_n, .cram_we_n, .cram_ub_n, .cram_lb_n);

	// What the comparison watches, inside the wrapper.
	wire        d_ram_we = dw.ram_we, d_reg_sel = dw.reg_sel, d_reg_write = dw.reg_write, d_halted = dw.halted;
	wire [31:0] d_d_addr = dw.d_addr, d_ram_wdata = dw.ram_wdata, d_w_addr = dw.w_addr;
	wire [31:0] d_reg_wdata = dw.reg_wdata, d_reg_rdata = dw.reg_rdata, d_halt_pc = dw.halt_pc;
	wire  [3:0] d_ram_be = dw.ram_be, d_halt_code = dw.halt_code;
	wire  [1:0] d_w_size = dw.w_size;
	wire        d_call_go = dw.call_go, d_returned = dw.returned;
	wire        d_not_ready = !d_ready;
	`define D_CART_RAM dw.mem.cart_ram

	// The cache beyond the window: demand misses and the clocks W waited.
	longint d_miss = 0, d_stall = 0, d_pf = 0;
	always @(posedge clk_d) begin
		if (dw.st_miss) d_miss++;
		if (dw.st_pf) d_pf++;
		if (dw.st_stall) d_stall++;
	end
	// The image as captured: the receiver's size, against upstream's.
	logic d_size_seen = 0;
	always @(posedge clk_sys) if (running && !d_size_seen && dw.img_ready) begin
		d_size_seen <= 1;
		if (dw.img_size != 20'(rom_size > 32'h80000 ? 32'h80000 : rom_size))
			$display("DARIA img_size %0d, upstream's rom_size %0d", dw.img_size, rom_size);
	end
`else
	// ---- the core and its memories --------------------------------------------------
	logic        d_rst = 1, d_rst_sys = 1;
	logic [19:0] d_img_size = 0;
	wire         d_ram32 = dut.mapper_ram_size == 16'd32768;
	wire  [14:0] d_rom_addr;
	wire  [31:0] d_rom_q, d_rom_dq, d_ram_q, d_d_addr, d_ram_wdata, d_w_addr, d_reg_wdata, d_halt_pc;
	wire   [3:0] d_ram_be, d_halt_code;
	wire   [1:0] d_w_size;
	wire   [7:0] d_reg_addr;
	wire         d_ram_we, d_w_asset, d_reg_sel, d_reg_write, d_halted;
	wire         d_call_go, d_parked, d_returned, d_ro_valid;
	wire   [4:0] d_clr_e;
	wire   [2:0] d_ro_idx;
	wire  [31:0] d_clr_wd, d_clr_pc, d_ro_data, d_reg_rdata;
	logic [31:0] d_asset_q;
	logic        d_wait_r = 0;
	wire         d_w_wait = d_w_asset && d_wait_r;
	int          d_await = 0;

	bup_cpu #(.MODES(1'b1), .THUMB(1'b1), .CODE_AW(15), .WIN_KB(`DARIA_WIN_KB)) dcpu (
		.clk(clk_d), .rst(d_rst), .freeze(1'b0), .w_wait(d_w_wait), .arm_only(1'b0),
		.prof26(1'b1), .img_size(d_img_size), .ram32(d_ram32), .call_go(d_call_go),
		.clr_wd(d_clr_wd), .clr_pc(d_clr_pc), .clr_e(d_clr_e), .parked(d_parked),
		.returned(d_returned), .ro_valid(d_ro_valid), .ro_idx(d_ro_idx), .ro_data(d_ro_data),
		.rom_addr(d_rom_addr), .rom_q(d_rom_q),
		.d_addr(d_d_addr), .ram_we(d_ram_we), .ram_be(d_ram_be), .ram_wdata(d_ram_wdata),
		.rom_dq(d_rom_dq), .ram_q(d_ram_q),
		.asset_size(24'd0), .asset_q(d_asset_q), .w_asset(d_w_asset), .w_addr(d_w_addr), .w_size(d_w_size),
		.reg_sel(d_reg_sel), .reg_addr(d_reg_addr), .reg_write(d_reg_write), .reg_wdata(d_reg_wdata),
		.reg_rdata(d_reg_rdata), .halted(d_halted), .halt_code(d_halt_code), .halt_pc(d_halt_pc),
		.rt_start(), .rt_valid(), .rt_pc(), .rt_insn(), .rt_nzcv(), .rt_mode(), .rt_t(), .rt_cunk(),
		.rt_e_we(), .rt_e_idx(), .rt_e_data(), .rt_w_we(), .rt_w_idx(), .rt_w_data());

	// The image beyond the window.
	function automatic logic [31:0] img_word(input int o);
		img_word = {img[o + 3], img[o + 2], img[o + 1], img[o]};
	endfunction
	always_comb d_asset_q = img_word(int'({d_w_addr[18:2], 2'b00}));
	always @(posedge clk_d) d_wait_r <= d_await > 0 && $urandom_range(99) < d_await;

	wire   [7:0] d_sta_addr;
	wire         d_sta_we;
	wire  [31:0] d_sta_wd, d_sta_q, d_stb_q;
	logic  [7:0] d_stb_addr = 0;
	logic        d_stb_we = 0;
	logic [31:0] d_stb_wd = 0;

	daria_mem #(.WIN_KB(`DARIA_WIN_KB)) dmem (
		.clk_arm(clk_d), .clk_sys,
		.rom_addr(d_rom_addr), .win_qa(d_rom_q), .d_addr(d_d_addr), .win_qb(d_rom_dq),
		.ram_we(d_ram_we), .ram_be(d_ram_be), .ram_wdata(d_ram_wdata), .ram_q(d_ram_q),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(d_sta_addr), .sta_we(d_sta_we), .sta_wd(d_sta_wd), .sta_q(d_sta_q),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0), .fea_addr(13'd0), .fea_q(),
		.feb_addr(13'd0), .feb_q(), .crb_addr(13'd0), .crb_we(1'b0), .crb_be(4'd0), .crb_wd(32'd0), .crb_q(),
		.stb_addr(d_stb_addr), .stb_we(d_stb_we), .stb_be(4'hF), .stb_wd(d_stb_wd), .stb_q(d_stb_q));

	logic d_call_tog = 0;
	wire  d_ret_tog;
	daria_call dcall (
		.clk(clk_d), .rst(d_rst), .call_tog(d_call_tog), .ret_tog(d_ret_tog),
		.parked(d_parked), .call_go(d_call_go), .clr_e(d_clr_e), .clr_wd(d_clr_wd), .clr_pc(d_clr_pc),
		.ro_valid(d_ro_valid), .ro_idx(d_ro_idx), .ro_data(d_ro_data), .returned(d_returned),
		.sta_addr(d_sta_addr), .sta_we(d_sta_we), .sta_wd(d_sta_wd), .sta_q(d_sta_q));

	daria_mmio dmmio (
		.clk_arm(clk_d), .rst_arm(d_rst), .sel(d_reg_sel), .write(d_reg_write), .addr(d_w_addr),
		.size(d_w_size), .wdata(d_reg_wdata), .rdata(d_reg_rdata),
		.clk_sys, .rst_sys(d_rst_sys), .pal(1'b0), .run(1'b1));

	wire        d_not_ready = d_rst_sys;
	`define D_CART_RAM dmem.cart_ram

	// ---- the image, when the run starts ---------------------------------------------------
	always @(posedge clk_sys) if (running && d_rst_sys) begin
		d_img_size <= 20'(rom_size > 32'h80000 ? 32'h80000 : rom_size);
		d_rst_sys <= 0;
	end
	// The window's RAMs, as many as daria_mem has.
	genvar d_w;
	generate for (d_w = 0; d_w < (`DARIA_WIN_KB + 31) / 32; d_w = d_w + 1) begin : g_d_load
		always @(posedge clk_sys) if (running && d_rst_sys)
			for (int i = 0; i < 8192; i++) dmem.g_win[d_w].win.mem_q[i] = img_word(32768 * d_w + 4 * i);
	end endgenerate
	logic [1:0] d_rst_s = 2'b11;
	always @(posedge clk_d) begin
		d_rst_s <= {d_rst_s[0], d_rst_sys};
		d_rst <= d_rst_s[1];
	end

`endif

	function automatic logic [3:0] lanes(input logic [1:0] size, input logic [1:0] a);
		lanes = size == 2'd0 ? 4'b0001 << a : size == 2'd1 ? 4'b0011 << {a[1], 1'b0} : 4'b1111;
	endfunction

	// ---- upstream's side of each call (its clk_arm) ------------------------------------------
	typedef struct packed { logic [31:0] addr; logic [3:0] be; logic [31:0] data; logic io; logic rd; } acc_t;
	acc_t         up_acc [$], d_acc [$];
	acc_t         up_acc_by [int][$];	// finished calls: their accesses, results and time
	logic [191:0] up_res_by [int];
	int           up_cyc_by [int];
	logic  [31:0] up_launch [0:7];		// entry|T, stack, counters, frequencies
	logic  [31:0] up_snap [0:8191];		// cart RAM as the call started
	logic         up_run_q = 0, up_post = 0, up_wait_res = 0;
	int           up_cyc = 0, up_call = 0;
	wire          up_running = ctl_state == CTRL_RUNNING;
	always @(posedge clk_arm) begin
		up_run_q <= up_running;
		if (up_running) up_cyc <= up_cyc + 1;
		if (up_running && !up_run_q) begin
			// The call starts: its launch, and the RAM it starts from.
			up_call <= up_call + 1;		// counts as tb_daria's call_id does
			up_cyc <= 1;
			up_launch[0] <= {dut.cart2600.arm_mappers.call_controller.active_entry[31:1],
				dut.cart2600.arm_mappers.call_controller.active_thumb};
			up_launch[1] <= dut.cart2600.arm_mappers.call_controller.active_stack;
			for (int v = 0; v < 3; v++) begin
				up_launch[2 + v] <= dut.cart2600.arm_mappers.call_controller.active_audio_counter[v];
				up_launch[5 + v] <= dut.cart2600.arm_mappers.call_controller.active_audio_frequency[v];
			end
			for (int i = 0; i < 8192; i++)
				up_snap[i] = {dut.cart_ram.ram_lane[3].lane_ram.mem_q[i],
					dut.cart_ram.ram_lane[2].lane_ram.mem_q[i], dut.cart_ram.ram_lane[1].lane_ram.mem_q[i],
					dut.cart_ram.ram_lane[0].lane_ram.mem_q[i]};
			up_acc.delete();
			up_post <= ~up_post;
		end
		// The ARM's own data accesses during the call: RAM writes, MMIO reads and writes.
		if (up_running && m_req && m_rdy && !m_fetch && arm_ce_run) begin
			if (m_wr && m_addr[31:28] == 4'h4)
				up_acc.push_back('{{m_addr[31:2], 2'b00}, dut.arm_mem_wstrb, dut.arm_mem_wdata, 1'b0, 1'b0});
			else if (m_addr[31:28] == 4'hE)
				up_acc.push_back('{m_addr, lanes(m_size, m_addr[1:0]),
					m_wr ? dut.arm_mem_wdata : dut.arm_mem_rdata, 1'b1, !m_wr});
		end
		// The controller reads FIQ r8-r13 out a few clocks after the return,
		// and is idle again once it has them.
		if (!up_running && up_run_q) up_wait_res <= 1;
		if (up_wait_res && ctl_state == 4'd0) begin	// CTRL_IDLE
			logic [191:0] r;
			for (int v = 0; v < 3; v++) begin
				r[32 * v +: 32] = dut.cart2600.arm_mappers.call_controller.audio_counter_result[v];
				r[32 * (3 + v) +: 32] = dut.cart2600.arm_mappers.call_controller.audio_frequency_result[v];
			end
			up_res_by[up_call] = r;
			up_cyc_by[up_call] = up_cyc;
			up_acc_by[up_call] = up_acc;
			up_wait_res <= 0;
		end
	end

	// ---- DARIA's side: post the call (clk_sys), time it and log its accesses ---------------
	logic  [2:0] d_post_s = 0, d_ret_s = 0;
	int          d_ph = 0, d_k = 0, d_call = 0;
	longint      d_t0 = 0, d_e2e = 0;
	logic        d_done = 0, d_acc_clear = 0, shadow_off = 0;
	logic [31:0] d_res [0:5];
	int          shadow_calls = 0, shadow_bad = 0, shadow_skip = 0, shadow_stop = 20, fd_dar = 0;
	longint      shadow_writes = 0, shadow_io = 0;
	int          MMIO_TOL = 200;
	int          tc_n = 0, tc_lo = 0, tc_hi = 0;     // T1TC reads compared, DARIA - upstream
	always @(posedge clk_sys) begin
		d_post_s <= {d_post_s[1:0], up_post};
		d_ret_s <= {d_ret_s[1:0], d_ret_tog};
		d_stb_we <= 0;
		case (d_ph)
			0: if (d_post_s[2] != d_post_s[1]) begin
				if (d_done || d_not_ready) shadow_skip++;
				else begin
					d_call <= up_call;
					d_t0 <= now;
					for (int i = 0; i < 8192; i++) `D_CART_RAM.mem_q[i] = up_snap[i];
					d_k <= 0;
					d_ph <= 1;
				end
			end
			1: begin					// the call block, one word a clock
				d_stb_we <= 1;
				d_stb_addr <= 8'hF0 + 8'(d_k);
				d_stb_wd <= up_launch[d_k];
				if (d_k == 7) d_ph <= 2;
				d_k <= d_k + 1;
			end
			2: begin
				d_call_tog <= ~d_call_tog;
				d_acc_clear <= ~d_acc_clear;
				d_ph <= 3;
			end
			3: if (d_ret_s[2] != d_ret_s[1]) begin	// the return words
				d_stb_addr <= 8'hF8;
				d_k <= 0;
				d_ph <= 4;
			end
			4: begin
				d_stb_addr <= 8'hF8 + 8'(d_k + 1);
				if (d_k > 0) d_res[d_k - 1] <= d_stb_q;
				if (d_k == 6) begin
					d_done <= 1;
					d_e2e <= now - d_t0;
					d_ph <= 0;
				end
				d_k <= d_k + 1;
			end
			default: d_ph <= 0;
		endcase
		if (d_halted && !shadow_off) begin
			$display("DARIA halted: code %0d at %08x (call %0d, frame %0d)", d_halt_code, d_halt_pc, d_call, frame);
			shadow_bad++;
			shadow_off = 1;
		end
		if (d_ph == 0 && d_done && up_res_by.exists(d_call)) begin
			shadow_compare();
			d_done <= 0;
		end
	end

	logic   d_acc_clear_q = 0;
	longint d_cyc = 0;
	logic   d_in_call = 0;
	always @(posedge clk_d) begin
		d_acc_clear_q <= d_acc_clear;
		if (d_acc_clear != d_acc_clear_q) d_acc.delete();
		if (d_call_go) begin d_in_call <= 1; d_cyc <= 0; end
		else if (d_in_call) d_cyc <= d_cyc + 1;
		if (d_returned) d_in_call <= 0;
		if (d_ram_we)
			d_acc.push_back('{{d_d_addr[31:2], 2'b00}, d_ram_be, d_ram_wdata, 1'b0, 1'b0});
		if (d_reg_sel)
			d_acc.push_back('{d_w_addr, lanes(d_w_size, d_w_addr[1:0]),
				d_reg_write ? d_reg_wdata : d_reg_rdata, 1'b1, !d_reg_write});
	end

	// ---- cart RAM collisions (open item 7) -------------------------------------------------
	localparam longint COLL_PS = 69840;
	longint up_wt [0:8191], d_wt [0:8191], fe_rt [0:8191];
	longint coll_up = 0, coll_d = 0, fe_reads = 0;
	initial for (int i = 0; i < 8192; i++) begin
		up_wt[i] = -COLL_PS;
		d_wt[i] = -COLL_PS;
		fe_rt[i] = -COLL_PS;
	end
	always @(posedge clk_sys) if (running && dut.cartram_rd && !dut.cartram_wr && dut.cartram_addr[17:15] == 3'd0) begin
		int w;
		w = int'(dut.cartram_addr[14:2]);
		fe_reads++;
		if ($time - up_wt[w] < COLL_PS) coll_up++;
		if ($time - d_wt[w] < COLL_PS) coll_d++;
		fe_rt[w] = $time;
	end
	always @(posedge clk_arm) if (up_running && m_req && m_rdy && !m_fetch && arm_ce_run && m_wr && m_addr[31:28] == 4'h4) begin
		if ($time - fe_rt[m_addr[14:2]] < COLL_PS) coll_up++;
		up_wt[m_addr[14:2]] = $time;
	end
	always @(posedge clk_d) if (d_ram_we) begin
		if ($time - fe_rt[d_d_addr[14:2]] < COLL_PS) coll_d++;
		d_wt[d_d_addr[14:2]] = $time;
	end

	// ---- compare, once both have returned ------------------------------------------------
	task automatic shadow_compare();
		string why;
		acc_t  a, b;
		int    nw, ni, done_keys [$];
		logic [191:0] r;
		r = up_res_by[d_call];
		why = "";
		nw = 0;
		ni = 0;
		for (int v = 0; v < 6 && why == ""; v++)
			if (d_res[v] != r[32 * v +: 32])
				why = $sformatf("return r%0d %08x, upstream %08x", 8 + v, d_res[v], r[32 * v +: 32]);
		for (int i = 0; i < d_acc.size() && i < up_acc_by[d_call].size() && why == ""; i++) begin
			logic [31:0] m;
			a = d_acc[i];
			b = up_acc_by[d_call][i];
			if (a.io) ni++; else nw++;
			m = {{8{a.be[3]}}, {8{a.be[2]}}, {8{a.be[1]}}, {8{a.be[0]}}};
			if (a.io != b.io || a.rd != b.rd || a.addr != b.addr || a.be != b.be)
				why = $sformatf("access %0d: %s %08x/%h, upstream %s %08x/%h", i,
					a.io ? (a.rd ? "io rd" : "io wr") : "ram wr", a.addr, a.be,
					b.io ? (b.rd ? "io rd" : "io wr") : "ram wr", b.addr, b.be);
			else if (a.io && a.rd && a.addr == 32'hE000_8008) begin
				int dt;
				dt = int'(a.data - b.data);
				tc_lo = (tc_n == 0 || dt < tc_lo) ? dt : tc_lo;
				tc_hi = (tc_n == 0 || dt > tc_hi) ? dt : tc_hi;
				tc_n++;
				if (dt > MMIO_TOL || -dt > MMIO_TOL)
					why = $sformatf("access %0d: T1TC %0d, upstream %0d", i, a.data, b.data);
			end else if ((a.data & m) != (b.data & m))
				why = $sformatf("access %0d, %s %08x: %08x, upstream %08x", i,
					a.io ? (a.rd ? "io rd" : "io wr") : "ram wr", a.addr, a.data & m, b.data & m);
		end
		if (why == "" && d_acc.size() != up_acc_by[d_call].size())
			why = $sformatf("%0d accesses, upstream %0d", d_acc.size(), up_acc_by[d_call].size());
		shadow_calls++;
		shadow_writes += nw;
		shadow_io += ni;
		$fwrite(fd_dar, "%0d,%0d,%0d,%.3f,%0d,%0d,%0d,%0d,%s\n", d_call, frame, d_cyc,
			real'(d_cyc) * 1.0e6 / D_HZ, d_e2e, up_cyc_by[d_call], nw, ni, why == "" ? "ok" : why);
		if (why != "") begin
			shadow_bad++;
			if (!shadow_off) $display("DARIA call %0d (frame %0d): %s", d_call, frame, why);
			if (shadow_bad >= shadow_stop) shadow_off = 1;
		end
		// Upstream's records up to this call are done with.
		foreach (up_res_by[c]) if (c <= d_call) done_keys.push_back(c);
		foreach (done_keys[j]) begin
			up_res_by.delete(done_keys[j]);
			up_cyc_by.delete(done_keys[j]);
			up_acc_by.delete(done_keys[j]);
		end
	endtask

	initial begin
		void'($value$plusargs("shadow_stop=%d", shadow_stop));
		void'($value$plusargs("d_await=%d", d_await));
		void'($value$plusargs("mmio_tol=%d", MMIO_TOL));
		#1;
		fd_dar = $fopen({out, "daria.csv"}, "w");
		$fwrite(fd_dar, "call,frame,daria_clk,daria_us,e2e_sys,up_clk,ram_writes,mmio,result\n");
	end
	final begin
		string stopped;
		stopped = "";
		if (shadow_off) stopped = ", stopped comparing";
		$display("DARIA shadow: %0d calls compared, %0d differ or halted, %0d skipped (DARIA busy)%s; %0d RAM writes and %0d MMIO accesses compared",
			shadow_calls, shadow_bad, shadow_skip, stopped, shadow_writes, shadow_io);
		$display("DARIA collisions: upstream %0d, DARIA %0d, in %0d console-side cart RAM reads", coll_up, coll_d, fe_reads);
		if (tc_n > 0)
			$display("DARIA T1TC: %0d reads compared, DARIA - upstream %0d to %0d counts (bound %0d)", tc_n, tc_lo, tc_hi, MMIO_TOL);
`ifdef DARIA_WRAPPER
		$display("DARIA cache: %0d demand misses, %0d prefetches, %0d clocks W waited; PSRAM model: %0d timing violations",
			d_miss, d_pf, d_stall, dchip.n_viol);
`endif
		$fclose(fd_dar);
	end
