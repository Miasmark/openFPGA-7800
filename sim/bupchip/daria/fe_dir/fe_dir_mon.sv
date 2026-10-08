//------------------------------------------------------------------------------
// fe_dir_mon: the event monitor of the daria_fe directed tests (fe_dir/).
//
// Bound into tb_daria (`bind` at the end of this file) by run_dir.sh, which
// adds this file to run_daria.sh's Verilator command through a VERILATOR
// wrapper (fe_dir/vwrap.sh). tb_daria, fe_shadow.svh and run_daria.sh are not
// changed. It only reads the DUT (upstream's front ends, which every build
// has), so its counts are the ground truth of what a test exercised, in the
// stage-0 and in the stage-1 build alike.
//
// Counts (coverage bins): every bin is a name and a count, written to
// <out>dir_cov.txt and summarised in run.log ("DIR: ..."). run_dir.sh compares
// them with each test's required minima: a test whose feature never fires
// fails. Bins are taken at upstream's commit edges (access && a_in[12],
// pre-edge values, so the decode and the state are what upstream used), at
// its audio, call and DMA events, and at the phases.
//
// Injections (all off by default), for the hard_reset and pause tests:
//   +dir_rst=M      a console reset (tb_daria's reset_in) of +dir_rst_len
//                   clk_sys (default 1000), +dir_rst_dly clk_sys (default 20)
//                   after: M=1 the +dir_rst_n-th (default 1) call accept;
//                   M=2 the n-th DPC+ service (DMA) start; M=3 load_end (the
//                   console is in reset there: upstream's init and F6 run);
//                   M=4 the n-th release of the console reset (right after
//                   init: the next F6 starts on that reset's rise)
//   +dir_pause=M    pause (a force on dut.pause) for +dir_pause_len clk_sys
//                   (default 200), starting +dir_pause_dly clk_sys after: M=1
//                   the n-th E0 (+dir_pause_n, default 2000; dly 1..5 puts it
//                   in phase 1, 6..11 in phase 2); M=2 the n-th call accept;
//                   M=3 the n-th service start. +dir_pause_rep=K repeats it
//                   at every K-th further E0 / call / service.
// The 6507 programs keep a marker in RIOT RAM: $FF counts completed test
// bodies, $FE counts the program's own self-check failures. Both are
// reported (dir_marker, dir_selfcheck_err).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module fe_dir_mon;
	longint cov [string];
	task automatic inc(input string k);
		if (cov.exists(k)) cov[k]++;
		else cov[k] = 1;
	endtask

	wire        clk      = tb_daria.clk_sys;
	wire        running  = tb_daria.running;
	wire  [5:0] mapper   = tb_daria.dut.cart2600.mapper;
	wire        e_rst    = tb_daria.dut.effective_reset;
	wire        pclk1    = tb_daria.dut.pclk1;
	wire        pclk0    = tb_daria.dut.pclk0;
	wire        access   = tb_daria.dut.cart2600.arm_access;
	wire [12:0] a_in     = tb_daria.dut.cart2600.a_in;
	wire        rw       = tb_daria.dut.cart2600.rw;
	wire  [7:0] d_in     = tb_daria.dut.cart2600.d_in;
	wire        sync     = tb_daria.dut.cpu_inst.cpu.sync;
	wire        commit   = access && a_in[12];
	wire        call_acc = tb_daria.dut.cart2600.arm_call_request && tb_daria.dut.cart2600.arm_call_ready;
	wire        call_done = tb_daria.dut.cart2600.arm_call_done;
	wire        call_busy = tb_daria.dut.arm_call_busy;
	wire        dma_busy = tb_daria.dut.arm_dma_busy;
	wire        init_busy = tb_daria.mapper_init_busy;
	wire        tick     = tb_daria.dut.cart2600.mapper_audio.audio_tick;
	wire  [3:0] ast      = tb_daria.dut.cart2600.mapper_audio.state;
	wire  [3:0] ctl      = tb_daria.ctl_state;
	wire        load_end = tb_daria.old_cart_download && !tb_daria.cart_download;

	// ---- plusargs
	int rst_mode = 0, rst_n = 1, rst_dly = 20, rst_len = 1000;
	int pz_mode = 0, pz_n = 2000, pz_dly = 3, pz_len = 200, pz_rep = 0;
	longint tr_from = -1, tr_n = 0;   // +dir_trace=N [+dir_trace_from=CLK]: print N commits
	string out = "./";
	initial begin
		void'($value$plusargs("out=%s", out));
		void'($value$plusargs("dir_rst=%d", rst_mode));
		void'($value$plusargs("dir_rst_n=%d", rst_n));
		void'($value$plusargs("dir_rst_dly=%d", rst_dly));
		void'($value$plusargs("dir_rst_len=%d", rst_len));
		void'($value$plusargs("dir_pause=%d", pz_mode));
		void'($value$plusargs("dir_pause_n=%d", pz_n));
		void'($value$plusargs("dir_pause_dly=%d", pz_dly));
		void'($value$plusargs("dir_pause_len=%d", pz_len));
		void'($value$plusargs("dir_pause_rep=%d", pz_rep));
		void'($value$plusargs("dir_trace=%d", tr_n));
		void'($value$plusargs("dir_trace_from=%d", tr_from));
	end

	// ---- clocks since things, phase tracking
	longint clk_n = 0;
	longint t_e0 = -100, t_p0 = -100, t_note = -1000, t_tick = -1000, t_call = -1000;
	longint t_cf = -1000;            // last CALLFN commit
	int     note_cnt_since = 0;
	logic   old_rst = 1, old_dma = 0, old_busy = 0, old_init = 0, old_tick_note = 0;
	logic   live = 0;                // checks-style window: from a pclk1 with !effective_reset && tia_en
	logic   [7:0] last_arm_byte = 0; // CDF: the opcode byte that armed the last fast fetch
	logic   [14:0] svc_lo = 0, svc_hi = 0;
	logic   svc_win = 0;
	int     ev_calls = 0, ev_svcs = 0, ev_e0 = 0, ev_rels = 0;

	// injections
	longint rst_at = -1, rst_end = -1, pz_at = -1, pz_end = -1;
	logic   pz_on = 0;

	function automatic string hx3(input logic [11:0] a);
		return $sformatf("%03x", a);
	endfunction

	always @(posedge clk) begin
		clk_n++;
		// ---------------------------------------------------------- injections
		if (rst_at >= 0 && clk_n == rst_at) begin
			tb_daria.reset_in = 1;
			rst_end = clk_n + rst_len;
			$display("DIR inject: console reset at clk_sys %0d for %0d (mode %0d): call_busy %0d ctl %0d dma_busy %0d init_busy %0d",
				clk_n, rst_len, rst_mode, call_busy, ctl, dma_busy, init_busy);
			if (call_busy || ctl != 0) inc("inj_rst_in_call");
			if (dma_busy && !init_busy) inc("inj_rst_in_svc");
			if (init_busy) inc("inj_rst_in_init");
			inc("inj_rst");
			rst_at = -1;
		end
		if (rst_end >= 0 && clk_n == rst_end) begin
			tb_daria.reset_in = 0;
			rst_end = -1;
		end
		if (pz_at >= 0 && clk_n == pz_at) begin
			force tb_daria.dut.pause = 1'b1;
			pz_on = 1;
			pz_end = clk_n + pz_len;
			pz_at = -1;
			inc("inj_pause");
			if (clk_n - t_e0 < 6) inc("inj_pause_ph1"); else inc("inj_pause_ph2");
			if (call_busy || ctl != 0) inc("inj_pause_in_call");
			if (dma_busy && !init_busy) inc("inj_pause_in_svc");
		end
		if (pz_end >= 0 && clk_n == pz_end) begin
			release tb_daria.dut.pause;
			pz_on = 0;
			pz_end = -1;
		end
		if (pz_on) begin
			inc("pause_clk");
			if (tb_daria.dut.pause) inc("pause_seen");
		end

		if (load_end) begin
			inc("load_end");
			if (rst_mode == 3) rst_at = clk_n + rst_dly;
		end
		if (init_busy && !old_init) inc("init_rise");
		old_init <= init_busy;

		// ---------------------------------------------------------- resets
		if (e_rst && !old_rst && running) begin
			inc("console_reset");
			if (call_busy || ctl != 0) inc("reset_in_call");
			if (dma_busy && !init_busy) inc("reset_in_svc");
			if (init_busy) inc("reset_in_init");
		end
		if (!e_rst && old_rst && running) begin
			ev_rels++;
			inc("reset_release");
			if (rst_mode == 4 && ev_rels == rst_n) rst_at = clk_n + rst_dly;
		end
		old_rst <= e_rst;
		if (tb_daria.dut.cart2600.ram_init.state != 0 && running && e_rst) inc("init_clk_in_reset");

		if (running && !e_rst) begin
			// ------------------------------------------------------ phases
			if (pclk1) begin
				if (t_p0 > t_e0 && t_e0 >= 0) inc($sformatf("sp_p0e0_%0d", clk_n - t_p0));
				t_e0 = clk_n;
				ev_e0++;
				if (pz_mode == 1 && (ev_e0 == pz_n || (pz_rep > 0 && ev_e0 > pz_n && (ev_e0 - pz_n) % pz_rep == 0)))
					pz_at = clk_n + pz_dly;
			end
			if (pclk0) begin
				if (t_e0 > t_p0) inc($sformatf("sp_e0p0_%0d", clk_n - t_e0));
				t_p0 = clk_n;
			end
			if (commit && clk_n - t_e0 < 6) inc($sformatf("commit_short_%0d", clk_n - t_e0));
			if (commit && tr_n > 0 && clk_n >= tr_from) begin
				tr_n--;
				$display("DIR trace %0d: E0+%0d a %04x %s d_in %02x d_out %02x oe %02x sync %0d pc %04x | dpc cnt %03x frac %05x ffp %0d | cdf fp %0d jr %0d ti %0d bank %0d/%0d",
					clk_n, clk_n - t_e0, a_in, rw ? "rd" : "WR", d_in, tb_daria.dut.cart2600.d_out, tb_daria.dut.cart2600.oe,
					sync, tb_daria.op_pc,
					tb_daria.dut.cart2600.dpcplus.counter[a_in[2:0]], tb_daria.dut.cart2600.dpcplus.fractional[a_in[2:0]],
					tb_daria.dut.cart2600.dpcplus.fast_pending,
					tb_daria.dut.cart2600.cdf.fast_pending, tb_daria.dut.cart2600.cdf.jump_remaining,
					tb_daria.dut.cart2600.cdf.table_index, tb_daria.dut.cart2600.dpcplus.bank, tb_daria.dut.cart2600.cdf.bank);
			end
			if (tb_daria.dut.tia_inst.rsync) inc("tia_rsync_clk");

			// ------------------------------------------------------ calls, DMA, audio
			if (call_acc) begin
				inc("call_accept");
				ev_calls++;
				t_call = clk_n;
				if (rst_mode == 1 && ev_calls == rst_n) rst_at = clk_n + rst_dly;
				if (pz_mode == 2 && (ev_calls == pz_n || (pz_rep > 0 && ev_calls > pz_n && (ev_calls - pz_n) % pz_rep == 0)))
					pz_at = clk_n + pz_dly;
			end
			if (call_done) begin
				inc("call_done");
				if (mapper == 6'd23) begin
					if (tb_daria.dut.cart2600.mapper_audio.counter0_return != tb_daria.dut.cart2600.mapper_audio.call_seed_counter[0]) inc("merge_counter_set");
					if (tb_daria.dut.cart2600.mapper_audio.counter1_return != tb_daria.dut.cart2600.mapper_audio.call_seed_counter[1]) inc("merge_counter_set");
					if (tb_daria.dut.cart2600.mapper_audio.counter2_return != tb_daria.dut.cart2600.mapper_audio.call_seed_counter[2]) inc("merge_counter_set");
					if (tb_daria.dut.cart2600.mapper_audio.counter0_return == tb_daria.dut.cart2600.mapper_audio.call_seed_counter[0]) inc("merge_counter_kept");
					if (tb_daria.dut.cart2600.mapper_audio.frequency0_return != tb_daria.dut.cart2600.mapper_audio.frequency0 ||
						tb_daria.dut.cart2600.mapper_audio.frequency1_return != tb_daria.dut.cart2600.mapper_audio.frequency1 ||
						tb_daria.dut.cart2600.mapper_audio.frequency2_return != tb_daria.dut.cart2600.mapper_audio.frequency2)
						inc("merge_freq_change");
				end
			end
			// a tick on the merge edge (M = call_done + 1) or inside (M, M+6]
			if (tick && t_call >= 0) begin
				t_tick = clk_n;
			end
			if (dma_busy && !old_dma && !init_busy) begin
				inc("svc_dma");
				ev_svcs++;
				if (rst_mode == 2 && ev_svcs == rst_n) rst_at = clk_n + rst_dly;
				if (pz_mode == 3 && (ev_svcs == pz_n || (pz_rep > 0 && ev_svcs > pz_n && (ev_svcs - pz_n) % pz_rep == 0)))
					pz_at = clk_n + pz_dly;
			end
			if (dma_busy && !init_busy) inc("svc_dma_clk");
			if (tick) inc("aud_tick");
			if (tb_daria.dut.cart2600.audio_ram_grant && dma_busy && !init_busy) begin
				inc("svc_aud_grant");
				if (svc_win && tb_daria.dut.cart2600.audio_ram_addr[14:0] >= svc_lo &&
					tb_daria.dut.cart2600.audio_ram_addr[14:0] < svc_hi)
					inc("svc_aud_overlap");
			end
			if (!dma_busy && old_dma) svc_win = 0;
			if (ast == 4'd9) begin	// AUDIO_DIGITAL_ROUTE
				logic [31:0] da;
				da = tb_daria.dut.cart2600.mapper_audio.digital_address;
				if (da < tb_daria.dut.cart2600.rom_size) inc(da < 32'h8000 ? "aud_dig_rom_lo" : "aud_dig_rom_hi");
				else if (da >= 32'h40000000 && da - 32'h40000000 < {16'b0, tb_daria.dut.mapper_ram_size}) inc("aud_dig_ram");
				else inc("aud_dig_none");
			end
			if (ast == 4'd4) begin	// AUDIO_POINTER_CAPTURE
				logic [31:0] wp;
				wp = tb_daria.dut.cart2600.mapper_audio.ram_word_data;
				inc("aud_ptr_capture");
				if (wp < 32'h40000800 || wp >= 32'h40000000 + {16'b0, tb_daria.dut.mapper_ram_size}) inc("aud_ptr_outside");
			end
			if (ast == 4'd6) inc("aud_size_capture");
			if (ast == 4'd2) begin	// AUDIO_NOTE_CAPTURE
				inc("aud_note_capture");
				if (clk_n - t_note <= 15) inc($sformatf("aud_note_cap_c+%0d", clk_n - t_note));
			end
			if (tick && clk_n - t_note >= 0 && clk_n - t_note <= 15)
				inc($sformatf("dpc_note_tick_c+%0d", clk_n - t_note));

			// ------------------------------------------------------ DPC+
			if (mapper == 6'd21 && commit) begin : dpc
				logic       rr;
				logic [2:0] fn, ix;
				logic [11:0] a;
				a  = a_in[11:0];
				rr = tb_daria.dut.cart2600.dpcplus.register_read;
				fn = tb_daria.dut.cart2600.dpcplus.read_function;
				ix = tb_daria.dut.cart2600.dpcplus.read_index;
				inc("dpc_commit");
				if (rw && rr) begin
					if (a < 12'h028) inc($sformatf("dpc_rd_f%0d_i%0d", fn, ix));
					else begin
						inc($sformatf("dpc_ffsub_f%0d_i%0d", fn, ix));
						inc("dpc_ffsub");
						if (sync) inc("dpc_ffsub_opcode");
						if (a >= 12'hFF6 && a <= 12'hFFB) inc("dpc_hot_sub");
					end
					if ((fn == 1 || fn == 2) && tb_daria.dut.cart2600.dpcplus.counter[ix] == 12'hFFF) inc("dpc_data_wrap");
					if (fn == 3 && {1'b0, tb_daria.dut.cart2600.dpcplus.fractional[ix]} +
						{13'b0, tb_daria.dut.cart2600.dpcplus.increment[ix]} > 21'hFFFFF) inc("dpc_frac_wrap");
					if (fn == 4) inc(tb_daria.dut.cart2600.dpcplus.window_flag != 0 ? "dpc_flag_ff" : "dpc_flag_00");
					if (fn == 2) inc(tb_daria.dut.cart2600.dpcplus.window_flag != 0 ? "dpc_dataw_ff" : "dpc_dataw_00");
				end
				if (rw && !rr) begin
					if (tb_daria.dut.cart2600.dpcplus.fast_fetch && tb_daria.dut.cart2600.rom_do == 8'hA9)
						inc(sync ? "dpc_arm_opcode" : "dpc_arm_data");
					if (tb_daria.dut.cart2600.dpcplus.fast_pending) inc("dpc_ff_disarm");
				end
				if (!rr && a >= 12'hFF6 && a <= 12'hFFB) begin
					inc(rw ? "dpc_hot_rd" : "dpc_hot_wr");
					if (tb_daria.dut.cart2600.dpcplus.bank != a[2:0] - 3'd6) inc(rw ? "dpc_bank_change_rd" : "dpc_bank_change_wr");
				end
				if (!rw && a >= 12'h028 && a < 12'h080) begin : wr
					logic [3:0] g;
					logic [2:0] wi;
					g  = 4'((a - 12'h028) >> 3);
					wi = a[2:0];
					inc($sformatf("dpc_wr_g%0d_i%0d", g, wi));
					if (g == 0) inc(tb_daria.dut.cart2600.dpcplus.stable_fractional ? "dpc_fraclow_sf1" : "dpc_fraclow_sf0");
					if (g == 7 && tb_daria.dut.cart2600.dpcplus.counter[wi] == 12'h000) inc("dpc_push_wrap");
					if (g == 10 && tb_daria.dut.cart2600.dpcplus.counter[wi] == 12'hFFF) inc("dpc_write_wrap");
					if (g == 6 && wi == 1) inc($sformatf("dpc_param_ptr%0d", tb_daria.dut.cart2600.dpcplus.parameter_pointer));
					if (g == 9 && wi >= 5) begin
						inc("dpc_note");
						t_note = clk_n;
						if (ast != 0) inc("dpc_note_busy");
					end
					if (g == 6 && wi == 2) begin
						t_cf = clk_n;
						if (call_busy) inc("dpc_cf_while_call_busy");
						if (d_in == 8'd0) inc("dpc_cf_0");
						else if (d_in == 8'd1 || d_in == 8'd2) begin
							if (tb_daria.dut.cart2600.dpcplus.service_pending) inc("dpc_cf_svc_ignored");
							else begin : svc
								logic [7:0] p3;
								logic [12:0] dav;
								logic [16:0] sav;
								logic [15:0] off;
								logic [7:0] cnt;
								p3  = tb_daria.dut.cart2600.dpcplus.params[3];
								dav = tb_daria.dut.cart2600.dpcplus.service_dest_available;
								sav = tb_daria.dut.cart2600.dpcplus.service_source_available;
								off = tb_daria.dut.cart2600.dpcplus.service_rom_offset;
								cnt = d_in == 8'd2 ? tb_daria.dut.cart2600.dpcplus.service_fill_count :
									tb_daria.dut.cart2600.dpcplus.service_copy_count;
								inc(d_in == 8'd2 ? "dpc_svc_fill" : "dpc_svc_copy");
								if (p3 == 0) inc("dpc_svc_req0");
								if ({3'b0, dav} < {8'b0, p3}) inc("dpc_svc_dstclamp");
								if (d_in == 8'd1 && off >= 16'h7400) inc("dpc_svc_offclamp");
								if (d_in == 8'd1 && off < 16'h7400 && sav < {9'b0, tb_daria.dut.cart2600.dpcplus.service_fill_count})
									inc("dpc_svc_srcclamp");
								if (cnt == 0) inc("dpc_svc_cnt0");
								if (dma_busy) inc("dpc_svc_while_dma");
								if (clk_n - t_cf <= 12 && clk_n != t_cf) inc("dpc_svc_rmw");
								svc_lo = 15'd3072 + {3'b0, tb_daria.dut.cart2600.dpcplus.counter[tb_daria.dut.cart2600.dpcplus.params[2][2:0]]};
								svc_hi = svc_lo + {7'b0, cnt};
								svc_win = 1;
							end
						end else if (d_in == 8'hFE || d_in == 8'hFF) begin
							if (tb_daria.dut.cart2600.dpcplus.call_pending) inc("dpc_cf_call_ignored");
							else inc("dpc_cf_call");
						end else inc("dpc_cf_other");
					end
				end
			end

			// ------------------------------------------------------ CDF
			if (mapper == 6'd23 && commit) begin : cdf
				logic [11:0] a;
				logic ss, fs, js, af;
				a  = a_in[11:0];
				ss = tb_daria.dut.cart2600.cdf.stream_substitute;
				fs = tb_daria.dut.cart2600.cdf.fetch_substitute;
				js = tb_daria.dut.cart2600.cdf.jump_substitute;
				af = tb_daria.dut.cart2600.cdf.amplitude_fetch;
				inc("cdf_commit");
				if (rw) begin
					if (fs && !js) begin
						if (af) inc("cdf_amp");
						else inc($sformatf("cdf_fetch_s%0d", tb_daria.dut.cart2600.cdf.table_index));
						inc($sformatf("cdf_fetch_by_%02x", last_arm_byte));
						if (tb_daria.dut.cart2600.cdf.fetch_offset_enable) inc("cdf_fetch_offset");
					end
					if (js) begin
						inc($sformatf("cdf_jsub_r%0d_s%0d", tb_daria.dut.cart2600.cdf.jump_remaining, tb_daria.dut.cart2600.cdf.table_index));
						if (a >= 12'hFFE) inc($sformatf("cdf_jsub_at_%s", hx3(a)));
					end
					if (ss && a >= 12'hFF4 && a <= 12'hFFB) inc("cdf_hot_sub");
					if (!ss) begin
						if (tb_daria.dut.cart2600.cdf.fast_mode && tb_daria.dut.cart2600.cdf.opcode_arms_fetch) begin
							inc($sformatf("cdf_arm_%02x", tb_daria.dut.cart2600.cdf.rom_data));
							last_arm_byte <= tb_daria.dut.cart2600.cdf.rom_data;
						end
						if (!tb_daria.dut.cart2600.cdf.fast_mode && tb_daria.dut.cart2600.cdf.opcode_arms_fetch)
							inc("cdf_arm_byte_not_fast");
						if (tb_daria.dut.cart2600.cdf.fast_pending) begin
							if (a_in == tb_daria.dut.cart2600.cdf.fast_expected_address) inc("cdf_ff_outrange");
							else inc("cdf_ff_elsewhere");
						end
						if (tb_daria.dut.cart2600.cdf.jump_remaining != 0) begin
							if (a_in == tb_daria.dut.cart2600.cdf.expected_address) inc("cdf_jop_invalid");
							else inc("cdf_jcancel");
						end
						if (tb_daria.dut.cart2600.cdf.fast_mode && tb_daria.dut.cart2600.cdf.rom_data == 8'h4C) begin
							if (tb_daria.dut.cart2600.cdf.fast_jump_valid &&
								!(tb_daria.dut.cart2600.cdf.jump_remaining != 0 && a_in == tb_daria.dut.cart2600.cdf.expected_address)) begin
								inc("cdf_jarm");
								if (a >= 12'hFFD) inc($sformatf("cdf_jarm_at_%s", hx3(a)));
								if (!sync) inc("cdf_jarm_data");
							end else if (!tb_daria.dut.cart2600.cdf.fast_jump_valid) begin
								inc("cdf_4c_nomap");
								if (tb_daria.dut.cart2600.cdf.rom_a >= 19'h7FFE) inc("cdf_4c_nomap_7ffe");
							end
						end
					end
				end else begin
					case (a)
						12'hFF0: begin : dsw
							logic [14:0] ra;
							logic [31:0] tp;
							tp = tb_daria.dut.cart2600.cdf.table_pointer;
							ra = tb_daria.dut.cart2600.cdf.ram_addr;
							inc("cdf_dsw");
							if (tb_daria.dut.cart2600.cdf.jplus && ra >= 15'h098 && ra < 15'h1B0) inc("cdf_dsw_tbl");
							if (tb_daria.dut.cart2600.cdf.jplus && {1'b0, tp[30:16]} + 16'd2048 > 16'h7FFF) inc("cdf_dsw_wrap");
							if (ra < 15'h800) inc("cdf_dsw_below800");
						end
						12'hFF1: inc("cdf_dsp");
						12'hFF2: begin
							inc("cdf_setmode");
							inc(d_in[3:0] == 0 ? "cdf_setmode_fast" : "cdf_setmode_slow");
							if (d_in[7:4] == 0) inc("cdf_setmode_digital");
						end
						12'hFF3: begin
							if (d_in == 8'hFE || d_in == 8'hFF) begin
								if (tb_daria.dut.cart2600.cdf.call_pending) inc("cdf_cf_ignored");
								else inc("cdf_cf_call");
								if (call_busy) inc("cdf_cf_while_call_busy");
								if (clk_n - t_cf <= 12) inc("cdf_cf_rmw");
								t_cf = clk_n;
							end else inc("cdf_cf_other");
						end
						default: ;
					endcase
				end
				if (!ss && a >= 12'hFF4 && a <= 12'hFFB) begin : hot
					logic [2:0] nb;
					if (tb_daria.dut.cart2600.cdf.jplus)
						nb = (a == 12'hFF4 || a == 12'hFFB) ? 3'd0 : a[2:0] - 3'd4;
					else
						nb = (a == 12'hFF4 || a == 12'hFFB) ? 3'd6 : a[2:0] - 3'd5;
					inc(rw ? "cdf_hot_rd" : "cdf_hot_wr");
					if (nb != tb_daria.dut.cart2600.cdf.bank) inc(rw ? "cdf_bank_change_rd" : "cdf_bank_change_wr");
				end
			end
			if (mapper == 6'd23 && tb_daria.dut.cart2600.cdf.digital_audio) inc("cdf_digital_clk");
		end
		old_dma <= dma_busy;
	end

	final begin
		int fd, marker, err;
		string s;
		marker = tb_daria.dut.riot_inst.riot_ram.mem_q[127];
		err    = tb_daria.dut.riot_inst.riot_ram.mem_q[126];
		cov["dir_marker"] = marker;
		cov["dir_selfcheck_err"] = err;
		for (int i = 0; i < 8; i++) cov[$sformatf("dir_res%0d", i)] = tb_daria.dut.riot_inst.riot_ram.mem_q[112 + i];
		fd = $fopen({out, "dir_cov.txt"}, "w");
		s = "";
		foreach (cov[k]) begin
			$fwrite(fd, "%s %0d\n", k, cov[k]);
		end
		$fclose(fd);
		$display("DIR: marker %0d, self-check errors %0d, %0d bins (dir_cov.txt)", marker, err, cov.size());
	end
endmodule

bind tb_daria fe_dir_mon u_fe_dir_mon();
