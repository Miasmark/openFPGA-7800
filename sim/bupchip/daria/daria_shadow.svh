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
// MODE B (-DFE_MODE_B, run_daria.sh MODE_B=1, with the front-end shadow;
// docs/daria_fe/spec/bench.md 6.3, 6.4, 7.1; design.md 12.2 step 8). daria_fe
// (u_fe, fe_shadow.svh) posts the calls to dcall itself and shares dmem: its
// front-end ROM (the cartridge's first 32 KB through cap_we, as the wrapper),
// its cart RAM port B and its state RAM port B are u_fe's, call_tog comes from
// u_fe and ret_tog goes to it. Step 5's poster and its per-call snapshot copy
// are gone. What stays here:
//   - clk_d on the PLL's lattice: it starts high and toggles every 13,095 ps
//     from +d_ofs=PS (default 0), so it rises at d_ofs + 26,190 n (n >= 1).
//     0, 8,730 and 17,460 put the shared edge (one clk_sys in three) on
//     clk_sys edges k = 1, 0, 2 (mod 3); 13,095 is step 5's phase (none shared).
//   - DARIA's reset follows the console reset (daria_mreset, design 6.5).
//   - DARIA's record of each call (its accesses from call_go, FIQ r8-r13 from
//     the readout), compared in order with upstream's by shadow_compare, as in
//     step 5; daria.csv's e2e_sys is daria_fe's C (busy rise) to X+1.
//   - K1d: DARIA's cart RAM at each call_go against up_snap (upstream's at the
//     start of the same call): DARIA starts from the RAM upstream started from.
//   - The coincidences on dmem's cart RAM (bench.md 6.4), exact to the ps:
//     coll_d_same (a DARIA store and a consumed daria_fe read of one word at one
//     time step), coll_d_ld_same (a daria_fe write and a DARIA load), coll_ww_same
//     (two writes); d_shared_stores / d_shared_loads (DARIA's on shared edges,
//     information). The 69.84 ns window (coll_d) uses daria_fe's consumed reads.
//     fe_shadow.svh turns them into must-be-0 checks.
//   - The self-tests' clock: +mb_inj=2 feeds u_fe's clk_arm from a copy of clk_d
//     +mb_det_ofs=PS (default 8,730) later (fe_shadow.svh has the others), and
//     the coincidence counters' positive controls: +mb_inj=4 adds, on each
//     shared edge with a DARIA store, a consumed daria_fe read of the word it
//     writes (coll_d_same); +mb_inj=5, on each shared edge, a daria_fe write of
//     the cart RAM word DARIA's port A is at (coll_d_ld_same for its loads,
//     coll_ww_same for its stores). Only the counters see these accesses.
//     +mb_inj=8 keeps mb_hist, each word's values in a call's flight, for its
//     stale read (fe_shadow.svh).
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
`ifdef FE_MODE_B
`ifdef DARIA_WRAPPER
	initial begin
		$display("mode B (FE_MODE_B) runs on dcall and dmem, not the wrapper");
		$finish;
	end
`endif
	// On the PLL's lattice (bench.md 6.3): high from time 0, toggling from +d_ofs
	// on, so the rising edges fall at d_ofs + 26,190 n (n >= 1), 8 per 3 clk_sys.
	logic clk_d = 1'b1;
	int   d_ofs = 0;
	initial begin
		void'($value$plusargs("d_ofs=%d", d_ofs));
		#(d_ofs);
		forever #13095 clk_d = ~clk_d;
	end
	// The self-tests (+mb_inj=K, fe_shadow.svh). K = 2: u_fe's clk_arm is a copy
	// of clk_d +mb_det_ofs ps later, so the phase detector locks on another
	// clk_sys class than the one DARIA's edges share (det_bad).
	int   mb_inj = 0, mb_det_ofs = 8730;
	logic clk_d_inj = 1'b1;
	initial begin
		int o;
		o = 0;
		void'($value$plusargs("d_ofs=%d", o));		// (this block may run before clk_d's)
		void'($value$plusargs("mb_inj=%d", mb_inj));
		void'($value$plusargs("mb_det_ofs=%d", mb_det_ofs));
		if (mb_inj == 2) begin
			#(o + mb_det_ofs);
			forever #13095 clk_d_inj = ~clk_d_inj;
		end
	end
	wire  fb_clk_arm = mb_inj == 2 ? clk_d_inj : clk_d;
`else
	logic clk_d = 0;
	always #13095 clk_d = ~clk_d;		// 26.19 ns, 8 per 3 clk_sys
`endif
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
`ifdef FE_MODE_B
	// Mode B: DARIA is held until the window is loaded, and then whenever the console
	// is in reset, as daria_mreset holds it on the Pocket (design 6.5): a console
	// reset abandons a call on both sides.
	logic        d_rst = 1, d_loaded = 0;
	wire         d_rst_sys = !d_loaded || dut.effective_reset;
`else
	logic        d_rst = 1, d_rst_sys = 1;
`endif
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

`ifdef FE_MODE_B
	// Mode B: dmem's front-end ports are u_fe's (fe_shadow.svh instantiates u_fe on
	// these wires; mode A's fe_mem and the step-5 poster's port B are not built).
	// The front-end ROM takes the cartridge's bytes as the wrapper does
	// (bupchip_pocket.sv: load_valid in the cartridge window, below 32 KB).
	wire  [12:0] fu_fea_addr, fu_feb_addr, fu_crb_addr;
	wire  [31:0] fu_fea_q, fu_feb_q, fu_crb_q, fu_stb_q, fu_crb_wd, fu_stb_wd;
	wire         fu_crb_we, fu_stb_we;
	wire   [3:0] fu_crb_be, fu_stb_be;
	wire   [7:0] fu_stb_addr;
	daria_mem #(.WIN_KB(`DARIA_WIN_KB)) dmem (
		.clk_arm(clk_d), .clk_sys,
		.rom_addr(d_rom_addr), .win_qa(d_rom_q), .d_addr(d_d_addr), .win_qb(d_rom_dq),
		.ram_we(d_ram_we), .ram_be(d_ram_be), .ram_wdata(d_ram_wdata), .ram_q(d_ram_q),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(d_sta_addr), .sta_we(d_sta_we), .sta_wd(d_sta_wd), .sta_q(d_sta_q),
		.cap_we(ioctl_wr && cart_download && ioctl_addr[24:15] == 10'd0), .cap_addr(ioctl_addr[14:0]),
		.cap_data(ioctl_dout), .fea_addr(fu_fea_addr), .fea_q(fu_fea_q), .feb_addr(fu_feb_addr), .feb_q(fu_feb_q),
		.crb_addr(fu_crb_addr), .crb_we(fu_crb_we), .crb_be(fu_crb_be), .crb_wd(fu_crb_wd), .crb_q(fu_crb_q),
		.stb_addr(fu_stb_addr), .stb_we(fu_stb_we), .stb_be(fu_stb_be), .stb_wd(fu_stb_wd), .stb_q(fu_stb_q));
	assign d_stb_q = fu_stb_q;

	wire  d_call_tog;			// u_fe's call_tog (fe_shadow.svh)
	wire  d_ret_tog;
`else
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
`endif
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
`ifdef FE_MODE_B
	always @(posedge clk_sys) if (running && !d_loaded) begin
		d_img_size <= 20'(rom_size > 32'h80000 ? 32'h80000 : rom_size);
		d_loaded <= 1;
	end
	// The window's RAMs, as many as daria_mem has.
	genvar d_w;
	generate for (d_w = 0; d_w < (`DARIA_WIN_KB + 31) / 32; d_w = d_w + 1) begin : g_d_load
		always @(posedge clk_sys) if (running && !d_loaded)
			for (int i = 0; i < 8192; i++) dmem.g_win[d_w].win.mem_q[i] = img_word(32768 * d_w + 4 * i);
	end endgenerate
	// daria_ready (bupchip_pocket.sv: parked & img_ready through two clk_sys flops), u_fe's
	// cpu_ready in mode B (design 1.2)
	logic [1:0] d_ready_s = 2'b00;
	always @(posedge clk_sys) d_ready_s <= {d_ready_s[0], d_parked};
	wire        d_ready_b = d_ready_s[1];
`else
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
`endif
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
`ifndef FE_MODE_B
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
`endif

	logic   d_acc_clear_q = 0;
	longint d_cyc = 0;
	logic   d_in_call = 0;
`ifndef FE_MODE_B
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
`endif

	// ---- cart RAM collisions (open item 7) -------------------------------------------------
	localparam longint COLL_PS = 69840;
	longint up_wt [0:8191], d_wt [0:8191], fe_rt [0:8191];
	longint coll_up = 0, coll_d = 0, fe_reads = 0;
	initial for (int i = 0; i < 8192; i++) begin
		up_wt[i] = -COLL_PS;
		d_wt[i] = -COLL_PS;
		fe_rt[i] = -COLL_PS;
	end
`ifndef FE_MODE_B
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
`else
	// ---- mode B: dmem's cart RAM, DARIA's port A (clk_d) against daria_fe's port B (clk_sys)
	// The reads that matter are daria_fe's own (bench.md 6.4): a port-B read whose q u_fe
	// consumes, i.e. the clock before crb_use (design 3.1: the core's fixed read with
	// cr_fix_use, the P32 read, the audio). fe_rt holds their times; upstream's console-side
	// reads (cartram_rd) keep their own array, so coll_up is step 5's count. Times are ps:
	// a clk_d edge t is shared iff ((t - 34,920) % 69,840) == 0, exactly. Each coincidence
	// is counted once, by whichever of the two blocks runs second in the time step.
	longint mb_up_rt [0:8191], fe_wt [0:8191];
	longint coll_d_same = 0, coll_d_ld_same = 0, coll_ww_same = 0;
	longint d_stores = 0, d_shared_stores = 0, d_loads = 0, d_shared_loads = 0, fe_rd_n = 0, fe_wr_n = 0;
	longint mb_d_prev_t = -1;		// the last clk_d rising edge (ps)
	longint mb_pc_n = 0;			// the positive controls' injected accesses (+mb_inj=4/5)
	// The values each word of this RAM held during a call's flight, for fe_shadow.svh's
	// self-test 8 (+mb_inj=8, a stale read: the word as the flight found it); kept only then.
	// At the first store to a word, its value before it, then its value after each store,
	// DARIA's and daria_fe's (the latter while a call is in flight). Emptied at the clk_sys edge
	// that first sees a call in flight (either side's busy), as fe_shadow.svh's mb_fl_t0. (The
	// refresh compare no longer reads it: each read is checked against the RAM at the read.)
	logic [31:0] mb_hist [int][$];
	logic        mb_hist_fl = 0;
	function automatic void mb_hist_add(input int w, input logic [3:0] be, input logic [31:0] wd);
		logic [31:0] v;
		v = `D_CART_RAM.mem_q[w];
		if (!mb_hist.exists(w)) mb_hist[w].push_back(v);
		for (int b = 0; b < 4; b++) if (be[b]) v[8 * b +: 8] = wd[8 * b +: 8];
		mb_hist[w].push_back(v);
	endfunction
	initial for (int i = 0; i < 8192; i++) begin
		mb_up_rt[i] = -COLL_PS;
		fe_wt[i] = -COLL_PS;
	end
	wire        mb_fe_rd = (u_fe.u_arb.own_r[daria_fe_pkg::OR_FIX] && u_fe.cr_fix_use) ||
		u_fe.u_arb.own_r[daria_fe_pkg::OR_P32] || u_fe.u_arb.own_r[daria_fe_pkg::OR_AUD];
	wire        mb_fe_wr = fu_crb_we;
	wire [12:0] mb_fe_a  = fu_crb_addr;
	function automatic logic mb_shared_d(input longint t);	// a clk_d edge that is a clk_sys edge
		return t >= 34920 && (t - 34920) % 69840 == 0;
	endfunction
	always @(posedge clk_sys) begin
		if (running && dut.cartram_rd && !dut.cartram_wr && dut.cartram_addr[17:15] == 3'd0) begin
			int w;
			w = int'(dut.cartram_addr[14:2]);
			fe_reads++;
			if ($time - up_wt[w] < COLL_PS) coll_up++;
			mb_up_rt[w] = $time;
		end
		if ((dut.arm_call_busy || u_fe.arm_call_busy) && !mb_hist_fl) mb_hist.delete();
		mb_hist_fl = dut.arm_call_busy || u_fe.arm_call_busy;
		if (mb_fe_rd) begin
			int w;
			w = int'(mb_fe_a);
			fe_rd_n++;
			if ($time - d_wt[w] < COLL_PS) coll_d++;
			if (d_wt[w] == $time) coll_d_same++;
			fe_rt[w] = $time;
		end
		if (mb_fe_wr) begin
			int w;
			w = int'(mb_fe_a);
			fe_wr_n++;
			if (mb_inj == 8 && (dut.arm_call_busy || u_fe.arm_call_busy)) mb_hist_add(w, fu_crb_be, fu_crb_wd);
			if (d_wt[w] == $time) coll_ww_same++;
			fe_wt[w] = $time;
		end
		// The positive controls (+mb_inj=4/5), on a shared edge (this clk_sys edge is a clk_d
		// edge) where DARIA's port A is in cart RAM: the access is counted here exactly as a
		// real one, and the clk_d block below pairs it with DARIA's store or (one clk_d later)
		// load of the same edge.
		if ((mb_inj == 4 || mb_inj == 5) && $time >= longint'(d_ofs) + 26190 && ($time - longint'(d_ofs)) % 26190 == 0 &&
				d_d_addr[31:15] == 17'h08000) begin
			int w;
			w = int'(d_d_addr[14:2]);
			if (mb_inj == 4 && d_ram_we) begin	// a consumed read of the word the store writes
				mb_pc_n++;
				if (d_wt[w] == $time) coll_d_same++;
				fe_rt[w] = $time;
			end
			if (mb_inj == 5) begin			// a write of the word port A registers
				mb_pc_n++;
				if (d_wt[w] == $time) coll_ww_same++;
				fe_wt[w] = $time;
			end
		end
	end
	always @(posedge clk_arm) if (up_running && m_req && m_rdy && !m_fetch && arm_ce_run && m_wr && m_addr[31:28] == 4'h4) begin
		if ($time - mb_up_rt[m_addr[14:2]] < COLL_PS) coll_up++;
		up_wt[m_addr[14:2]] = $time;
	end
	always @(posedge clk_d) begin
		if (d_ram_we) begin
			int w;
			w = int'(d_d_addr[14:2]);
			d_stores++;
			if (mb_inj == 8) mb_hist_add(w, d_ram_be, d_ram_wdata);
			if (mb_shared_d($time)) d_shared_stores++;
			if ($time - fe_rt[w] < COLL_PS) coll_d++;
			if (fe_rt[w] == $time) coll_d_same++;
			if (fe_wt[w] == $time) coll_ww_same++;
			d_wt[w] = $time;
		end
		// A cart RAM load: port A registered its address at the last edge, and the core
		// takes the word in W now (bup_cpu: chk_v, acc_load, acc_addr in the 2600 map's
		// cart RAM, 0x4000_0000-0x4000_7FFF). Seen one clk_d late, so only this block counts
		// it; a daria_fe write is at a clk_sys edge, never in between.
		if (dcpu.chk_v && dcpu.acc_load && dcpu.acc_addr[31:15] == 17'h08000 && mb_d_prev_t >= 0) begin
			int w;
			w = int'(dcpu.acc_addr[14:2]);
			d_loads++;
			if (mb_shared_d(mb_d_prev_t)) d_shared_loads++;
			if (fe_wt[w] == mb_d_prev_t) coll_d_ld_same++;
		end
		mb_d_prev_t = $time;
	end

	// ---- mode B: DARIA's record of each call, compared with upstream's (shadow_compare) ------
	// DARIA's calls are numbered from 1 in the order they start (call_go), as up_call numbers
	// upstream's; DARIA's call n is upstream's call n + mb_up_ofs (0, re-aligned while the
	// console is in reset: a reset abandons a call on both sides). The record is complete one
	// clk_d after `returned` (FIQ r13 is written at that edge).
	logic [191:0] mb_res_by [int];
	longint       mb_cyc_by [int];
	acc_t         mb_acc_by [int][$];
	int           mb_dn = 0, mb_dk = 1, mb_up_ofs = 0, mb_drop = 0;
	logic         mb_fin = 0;
	longint       mb_e2e_q [$], mb_c_t = -1;
	logic         mb_cb_q = 0;
	// what shadow_compare reads in mode B (`D_RES etc. below)
	logic  [31:0] mb_cmp_res [0:5];
	acc_t         mb_cmp_acc [$];
	longint       mb_cmp_cyc = 0, mb_cmp_e2e = 0;
	// K1d: DARIA's cart RAM at each call_go against upstream's when its call started (up_snap)
	longint       mb_k1d = 0, mb_k1d_bad = 0, mb_k1d_skip = 0;
	always @(posedge clk_d) begin
		if (d_call_go) begin
			d_acc.delete();
			d_in_call <= 1;
			d_cyc <= 0;
			mb_dn = mb_dn + 1;
			if (up_call == mb_dn + mb_up_ofs) begin
				int bad, nw;
				bad = 0;
				nw = d_ram32 ? 8192 : 2048;
				for (int i = 0; i < nw; i++) if (`D_CART_RAM.mem_q[i] != up_snap[i]) bad++;
				mb_k1d++;
				if (bad != 0) begin
					mb_k1d_bad++;
					if (mb_k1d_bad <= 5)
						$display("DARIA mode B: call %0d (frame %0d) starts on a cart RAM with %0d words unlike upstream's at the start of its call",
							mb_dn + mb_up_ofs, frame, bad);
				end
			end else
				mb_k1d_skip++;			// upstream's call has not started yet: up_snap is the last one's
		end else if (d_in_call) d_cyc <= d_cyc + 1;
		if (d_returned) d_in_call <= 0;
		if (d_ram_we)
			d_acc.push_back('{{d_d_addr[31:2], 2'b00}, d_ram_be, d_ram_wdata, 1'b0, 1'b0});
		if (d_reg_sel)
			d_acc.push_back('{d_w_addr, lanes(d_w_size, d_w_addr[1:0]),
				d_reg_write ? d_reg_wdata : d_reg_rdata, 1'b1, !d_reg_write});
		if (d_ro_valid) d_res[d_ro_idx] <= d_ro_data;
		mb_fin <= d_returned;
		if (mb_fin) begin
			mb_res_by[mb_dn] = {d_res[5], d_res[4], d_res[3], d_res[2], d_res[1], d_res[0]};
			mb_cyc_by[mb_dn] = d_cyc;
			mb_acc_by[mb_dn] = d_acc;
		end
	end
	always @(posedge clk_sys) begin
		// e2e_sys: daria_fe's busy rise (the CALLFN commit, C) to X+1 (xq: u_call saw ret_tog)
		if (u_fe.arm_call_busy && !mb_cb_q) mb_c_t = now;
		mb_cb_q = u_fe.arm_call_busy;
		if (u_fe.u_call.xq && mb_c_t >= 0) begin
			mb_e2e_q.push_back(now - mb_c_t);
			mb_c_t = -1;
		end
		if (dut.effective_reset) begin			// re-align; calls in flight are dropped
			foreach (mb_res_by[k]) mb_drop++;
			mb_res_by.delete();
			mb_cyc_by.delete();
			mb_acc_by.delete();
			mb_e2e_q.delete();
			mb_c_t = -1;
			mb_up_ofs = up_call - mb_dn;
			mb_dk = mb_dn + 1;
		end
		if (d_halted && !shadow_off) begin
			$display("DARIA halted: code %0d at %08x (call %0d, frame %0d)", d_halt_code, d_halt_pc, d_call, frame);
			shadow_bad++;
			shadow_off = 1;
		end
		if (mb_res_by.exists(mb_dk) && up_res_by.exists(mb_dk + mb_up_ofs) && mb_e2e_q.size() > 0) begin
			d_call = mb_dk + mb_up_ofs;
			for (int v = 0; v < 6; v++) mb_cmp_res[v] = mb_res_by[mb_dk][32 * v +: 32];
			mb_cmp_acc = mb_acc_by[mb_dk];
			mb_cmp_cyc = mb_cyc_by[mb_dk];
			mb_cmp_e2e = mb_e2e_q.pop_front();
			shadow_compare();
			mb_res_by.delete(mb_dk);
			mb_cyc_by.delete(mb_dk);
			mb_acc_by.delete(mb_dk);
			mb_dk++;
		end
	end
`endif
`ifdef FE_MODE_B
	`define D_RES mb_cmp_res
	`define D_ACC mb_cmp_acc
	`define D_CYC mb_cmp_cyc
	`define D_E2E mb_cmp_e2e
`else
	`define D_RES d_res
	`define D_ACC d_acc
	`define D_CYC d_cyc
	`define D_E2E d_e2e
`endif

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
			if (`D_RES[v] != r[32 * v +: 32])
				why = $sformatf("return r%0d %08x, upstream %08x", 8 + v, `D_RES[v], r[32 * v +: 32]);
		for (int i = 0; i < `D_ACC.size() && i < up_acc_by[d_call].size() && why == ""; i++) begin
			logic [31:0] m;
			a = `D_ACC[i];
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
		if (why == "" && `D_ACC.size() != up_acc_by[d_call].size())
			why = $sformatf("%0d accesses, upstream %0d", `D_ACC.size(), up_acc_by[d_call].size());
		shadow_calls++;
		shadow_writes += nw;
		shadow_io += ni;
		$fwrite(fd_dar, "%0d,%0d,%0d,%.3f,%0d,%0d,%0d,%0d,%s\n", d_call, frame, `D_CYC,
			real'(`D_CYC) * 1.0e6 / D_HZ, `D_E2E, up_cyc_by[d_call], nw, ni, why == "" ? "ok" : why);
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
`ifdef FE_MODE_B
		$display("DARIA collisions: upstream %0d in %0d console-side cart RAM reads; DARIA %0d in %0d daria_fe port-B reads consumed (within 69.84 ns, either order)",
			coll_up, fe_reads, coll_d, fe_rd_n);
		$display("DARIA mode B: clk_d +d_ofs=%0d ps; coincidences (same time step, same word): coll_d_same %0d, coll_d_ld_same %0d, coll_ww_same %0d; DARIA stores %0d (%0d on a shared edge), cart RAM loads %0d (%0d on a shared edge); daria_fe port-B writes %0d, consumed reads %0d; K1d %0d call starts compared, %0d differ, %0d not compared (upstream's call not started); %0d DARIA records dropped by a reset",
			d_ofs, coll_d_same, coll_d_ld_same, coll_ww_same, d_stores, d_shared_stores, d_loads, d_shared_loads,
			fe_wr_n, fe_rd_n, mb_k1d, mb_k1d_bad, mb_k1d_skip, mb_drop);
`else
		$display("DARIA collisions: upstream %0d, DARIA %0d, in %0d console-side cart RAM reads", coll_up, coll_d, fe_reads);
`endif
		if (tc_n > 0)
			$display("DARIA T1TC: %0d reads compared, DARIA - upstream %0d to %0d counts (bound %0d)", tc_n, tc_lo, tc_hi, MMIO_TOL);
`ifdef DARIA_WRAPPER
		$display("DARIA cache: %0d demand misses, %0d prefetches, %0d clocks W waited; PSRAM model: %0d timing violations",
			d_miss, d_pf, d_stall, dchip.n_viol);
`endif
		$fclose(fd_dar);
	end
