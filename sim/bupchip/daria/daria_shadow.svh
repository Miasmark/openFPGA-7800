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
//     within +/- MMIO_TOL counts (open item 17).
//   - daria.csv, one line per compared call: call, frame, DARIA's clk_arm
//     from call_go to returned, the microseconds that is, upstream's clk_arm
//     for the call, RAM writes and MMIO accesses compared, and ok or the
//     first difference. dynamic_tables.py --only daria counts late calls
//     with these times.
//
// Plusargs: +shadow_stop=N stops comparing after N bad calls (default 20);
// +d_await=P (default 0).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`ifndef DARIA_WIN_KB
`define DARIA_WIN_KB 128
`endif

	// ---- DARIA's clock ---------------------------------------------------------
	logic clk_d = 0;
	always #13095 clk_d = ~clk_d;		// 26.19 ns, 8 per 3 clk_sys
	localparam real D_HZ = 687272727.0 / 18.0;

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

	daria_mem dmem (
		.clk_arm(clk_d), .clk_sys,
		.rom_addr(d_rom_addr), .win_qa(d_rom_q), .d_addr(d_d_addr), .win_qb(d_rom_dq),
		.ram_we(d_ram_we), .ram_be(d_ram_be), .ram_wdata(d_ram_wdata), .ram_q(d_ram_q),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(d_sta_addr), .sta_we(d_sta_we), .sta_wd(d_sta_wd), .sta_q(d_sta_q),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0), .fea_addr(13'd0), .fea_q(),
		.feb_addr(13'd0), .feb_q(), .crb_addr(13'd0), .crb_we(1'b0), .crb_be(4'd0), .crb_wd(32'd0), .crb_q(),
		.stb_addr(d_stb_addr), .stb_we(d_stb_we), .stb_wd(d_stb_wd), .stb_q(d_stb_q));

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

	// ---- the image, when the run starts ---------------------------------------------------
	always @(posedge clk_sys) if (running && d_rst_sys) begin
		d_img_size <= 20'(rom_size > 32'h80000 ? 32'h80000 : rom_size);
		for (int i = 0; i < 8192; i++) begin
			dmem.g_win[0].win.mem_q[i] = img_word(4 * i);
			dmem.g_win[1].win.mem_q[i] = img_word(32768 + 4 * i);
			dmem.g_win[2].win.mem_q[i] = img_word(65536 + 4 * i);
			dmem.g_win[3].win.mem_q[i] = img_word(98304 + 4 * i);
		end
		d_rst_sys <= 0;
	end
	logic [1:0] d_rst_s = 2'b11;
	always @(posedge clk_d) begin
		d_rst_s <= {d_rst_s[0], d_rst_sys};
		d_rst <= d_rst_s[1];
	end

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
	logic        d_done = 0, d_acc_clear = 0, shadow_off = 0;
	logic [31:0] d_res [0:5];
	int          shadow_calls = 0, shadow_bad = 0, shadow_skip = 0, shadow_stop = 20, fd_dar = 0;
	longint      shadow_writes = 0, shadow_io = 0;
	int          MMIO_TOL = 200;
	always @(posedge clk_sys) begin
		d_post_s <= {d_post_s[1:0], up_post};
		d_ret_s <= {d_ret_s[1:0], d_ret_tog};
		d_stb_we <= 0;
		case (d_ph)
			0: if (d_post_s[2] != d_post_s[1]) begin
				if (d_done || d_rst_sys) shadow_skip++;
				else begin
					d_call <= up_call;
					for (int i = 0; i < 8192; i++) dmem.cart_ram.mem_q[i] = up_snap[i];
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
				if (int'(a.data - b.data) > MMIO_TOL || int'(b.data - a.data) > MMIO_TOL)
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
		$fwrite(fd_dar, "%0d,%0d,%0d,%.3f,%0d,%0d,%0d,%s\n", d_call, frame, d_cyc,
			real'(d_cyc) * 1.0e6 / D_HZ, up_cyc_by[d_call], nw, ni, why == "" ? "ok" : why);
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
		#1;
		fd_dar = $fopen({out, "daria.csv"}, "w");
		$fwrite(fd_dar, "call,frame,daria_clk,daria_us,up_clk,ram_writes,mmio,result\n");
	end
	final begin
		string stopped;
		stopped = "";
		if (shadow_off) stopped = ", stopped comparing";
		$display("DARIA shadow: %0d calls compared, %0d differ or halted, %0d skipped (DARIA busy)%s; %0d RAM writes and %0d MMIO accesses compared",
			shadow_calls, shadow_bad, shadow_skip, stopped, shadow_writes, shadow_io);
		$fclose(fd_dar);
	end
