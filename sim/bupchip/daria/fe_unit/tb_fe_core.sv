//------------------------------------------------------------------------------
// tb_fe_core: unit bench of daria_fe_dec + daria_fe_core (docs/daria_fe/
// design.md 2.2-2.6, 12.3) against upstream's own front ends.
//
// Upstream side (src/fpga/mister/rtl, MIT): mapper_dpcplus, mapper_cdf,
// arm_mapper_tables and cdf_fastjump_table, wired as cart2600 wires them, on
// tb_daria's 1-clock ROM (rom_q <= img[rom_a] every clock, CR 9) and a model
// of cart2600's cart RAM port A (cart_ram_tdp: registered word and lane, $FF
// on pause; the write strobe sel & !rw & !phi1 & !address_change &
// !access_taken; the pointer writeback landing between C+1 and C+2, CDF
// §14.3).
// DARIA side: daria_fe_seq + daria_fe_core (+ u_dec) on daria_mem (poisoned
// with POISON=1), through a bench-local reduced daria_fe_arb (design 3.1-3.3
// without F6 and the copy engine; the audio, the call port and the sample
// client are random requesters). Both sides see one fe_phase_gen bus stream
// (EXT_BUS: a program-like stream from this bench), one amplitude and one
// audio requester.
//
// Epochs: a random scheme (DPC+ sf 0/1, CDF0, CDF1, CDFJ, CDFJ+), LDX/LDY,
// fetch offset; a random 32 KB image dense in $A9/$A2/$A0 + operand and $4C
// jump patterns (and $4C at bank ends); random cart RAM (pointer and
// increment tables included); the map built by cdf_fastjump_table from the
// image through its load port; the state RAM cleared (F6). Inside an epoch:
// a console reset (F6 emulated), a live scheme switch at an E0, a 7800-mode
// interval (driver_run 0), a non-ARM scheme interval. After them, one DPC+
// and one CDF release epoch: +rrel console resets, each released in the
// pclk0 clock of a cycle that commits a post action waiting for a read
// (DFxDATA/DATAW/FRACDATA, PUSH, WRITE; DSWRITE, DSPTR), so that the action
// is set with its ready flag at 0 (E3_rtl_issues.md issue 1). The release
// cycle's latch and words are classified (rrel) and the DPC+ fetchers
// resynced from upstream; the action must be dropped at pclk1 (pending
// before it, gone after it: every release must count one such pclk1, and
// none may leave an action pending), a_pend_late stay 0 there (rcyc) and
// nothing fire later (docs/daria_fe/lanes/F1_fixes.md).
//
// The checks (design 12.3, items 1-8):
//  1 a2       sel_up == sel_ram_sel on every clock; aud_take == upstream's
//             grant outside short-phase cycles (else grant_steal, counted)
//  2 dout     fe_do == upstream's byte at every pclk0 of a read with A12
//             (hidden ones too); cycles with C < E0+6 are counted
//             (short_phase1), not failed
//  3 state    every scheme register at every pclk1 (DPC+ fetchers, params,
//             pptr, waveforms, LFSR, bank, fast fetch, service pending; CDF
//             bank, mode, fast_pending/address, jump state), short phases
//             included; CDF Q26 (pu_val from the previous edge's index,
//             only with C = E0+2) is classified and repaired from upstream
//  4 ram      the cart RAM words written in each cycle (both sides) at the
//             next pclk1, and all 8 K words every 2,048 cycles and at each
//             epoch end; each pointer write lands at C+1 or C+2
//             (pointer_land); every DARIA audio read returns upstream's
//             word (aud_data, the wbuf proof of 3.4)
//  5 jok      u_core.jok == cdf_fastjump_table's bit in every CDF k[1];
//             the map against the formula over every address after each
//             load (jmap)
//  6 fix      no fixed R use outside sel_up in a cycle with C >= E0+6;
//             a_collide, a_wb_late, a_p32_late (the arb's, formed here),
//             a_pend_late, a_fpjr; one source per W, cr_fix, cs_req clock;
//             rcyc (bad class rcyc) against its meaning on every clock: 1
//             exactly when some edge since the last pclk1 edge had rst_fe;
//             "commit in a pclk1 clock", a sanity check of phase_gen only
//             (it emits pclk1 and pclk0 exclusively; the system's proof is
//             top.sv, checked by fe_shadow's commit_pclk1)
//  7 svc      the service latch against upstream's service_* (count via
//             min()); dma_set and callfn against upstream's pending rises;
//             NOTE, waveforms and cdf_dig every clock
//  8 rst      every register's reset value after each rst_fe clock (console
//             reset, scheme switch, non-ARM scheme), then the state compare
// Classified and repaired (counted, never failed): q26, tbl_alias (a CDFJ+
// DSWRITE into the tables: upstream's table cache is resynced from RAM),
// ram_wr_noaccess (an upstream PUSH/WRITE strobe in a cycle without a
// commit: DARIA's word is resynced), rrel (a release epoch's release cycle:
// its latch, its words, the DPC+ fetchers).
//
// Plusargs: +seed=N, +cycles=N (6507 cycles, default 200000), +epoch=N
// (cycles per epoch, default 40000), +only=all|dpc|cdf|cdf0|cdf1|cdfj|cdfjp,
// +stop=N (failures printed), +events=0 (no reset/switch/7800 events),
// +rrel=N (releases per release epoch, default 8; 0: no release epochs),
// +rrel_len=N (cycles per release epoch, default 10000), +rrel_log=1 (a line
// per release), +pg_* (phase_gen.svh). Passes iff every bad count is 0 and
// the coverage minimums are met; $fatal otherwise.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none
`include "phase_gen.svh"

module tb_fe_core;
	import daria_fe_pkg::*;

	logic clk = 1'b0;
	always #5 clk = ~clk;

	// ======================================================================================
	// knobs and the bench's random stream
	// ======================================================================================
	longint n_cycles  = 200000;
	int     epoch_len = 40000;
	int     seed      = 1;
	string  only      = "all";
	int     stop_n    = 20;
	int     events    = 1;
	int     formula   = 1;               // 0: skip the checks that restate an RTL formula (mutation runs)
	int     n_rrel    = 8;               // releases per release epoch (0: no release epochs)
	int     rrel_len  = 10000;           // cycles per release epoch
	int     rrel_mode = 0;               // the epoch being run: 0 normal, 1 DPC+ release, 2 CDF release
	int     rrel_log  = 0;               // +rrel_log=1: a line per release

	logic [31:0] rs = 32'h1234_5678;
	function automatic int unsigned rnd(input int unsigned n);
		rs = rs ^ (rs << 13);
		rs = rs ^ (rs >> 17);
		rs = rs ^ (rs << 5);
		return (n == 0) ? 0 : (rs % n);
	endfunction
	function automatic logic [7:0] rnd8();
		return 8'(rnd(256));
	endfunction
	function automatic logic [31:0] rnd32();
		return {rnd8(), rnd8(), rnd8(), rnd8()};
	endfunction

	// ======================================================================================
	// controls
	// ======================================================================================
	logic  [5:0] scheme     = 6'd0;
	logic  [2:0] revision   = 3'd0;
	logic        ldx        = 1'b0;
	logic        ldy        = 1'b0;
	logic        foff_en    = 1'b0;
	logic  [7:0] foff       = 8'h00;
	logic        cart_reset = 1'b1;
	logic        pg_run     = 1'b0;
	logic        driver_run = 1'b1;
	logic        checking   = 1'b0;      // the per-clock and per-cycle checks are on

	// ======================================================================================
	// the bus: fe_phase_gen with this bench's program-like stream
	// ======================================================================================
	logic [12:0] nx_a  = 13'h1000;
	logic        nx_rw = 1'b1;
	logic  [7:0] nx_d  = 8'h00;
	wire         pclk1, pclk0, mapper_phi2, access, pause, load, stall_eff, ibusy, held;
	wire  [12:0] a_in;
	wire         rw;
	wire   [7:0] d_in;
	wire   [5:0] len1, len2;
	fe_phase_gen #(.SEED(1), .EXT_BUS(1'b1)) pg (
		.clk_sys(clk), .run(pg_run), .stall(1'b0), .driver_run(driver_run),
		.ext_a(nx_a), .ext_rw(nx_rw), .ext_d(nx_d),
		.pclk1, .pclk0, .mapper_phi2, .access, .a_in, .rw, .d_in, .pause, .load,
		.stall_eff, .ibusy, .held, .len1, .len2);

	// ======================================================================================
	// DARIA: the scheme decode and rst_fe exactly as daria_fe.sv, u_seq, u_core
	// ======================================================================================
	wire is_dpc = scheme == SCHEME_DPCP;
	wire is_cdf = scheme == SCHEME_CDF;
	wire jplus  = is_cdf & (revision[1:0] == 2'd3);
	wire jrev   = is_cdf & revision[1];
	logic [5:0] scheme_q = 6'd0;
	always @(posedge clk) scheme_q <= scheme;
	wire rst_fe = cart_reset | !(is_dpc | is_cdf) | (scheme != scheme_q);

	wire [7:0] k;
	wire [3:0] c;
	wire       ph2, commit, ph1_open, rel_ok, ev_short;
	daria_fe_seq u_seq (
		.clk_sys(clk), .pclk1, .pclk0, .access, .a12(a_in[12]),
		.k, .c, .ph2, .commit, .ph1_open, .rel_ok, .ev_short);

	wire  [31:0] fea_q, feb_q, crb_q, stb_q;
	logic        aud_take, p32_gnt, wb_gnt, look_gnt;
	logic  [7:0] amp_reg  = 8'h00;       // upstream's amplitude
	logic  [7:0] amp_next = 8'h00;       // the value amplitude takes at the end of this clock (amp_nx)
	logic        svc_take = 1'b0;
	logic        up_svc_ready = 1'b0;
	logic        g_core   = 1'b0;        // the core's guard_on (random; the reduced arb's is 0)
	logic        dma_busy_m = 1'b0;      // random: only ev_rmw_svc reads it
	logic        call_busy_m = 1'b0;     // random: no rule reads it
	logic        aud_take_core = 1'b0;   // random into the unused input (proves it unused)
	logic        look_gnt_core = 1'b0;   // the same
	wire   [7:0] fe_do;
	wire         sel_up;
	wire  [12:0] feb_addr;
	wire         cr_fix, cr_fix_we, cr_fix_use;
	wire  [12:0] cr_fix_a;
	wire   [3:0] cr_fix_be;
	wire  [31:0] cr_fix_wd;
	wire         cr_p32, cr_wb;
	wire  [12:0] cr_p32_a, cr_wb_a;
	wire  [31:0] cr_wb_wd;
	wire         cs_req, cs_we;
	wire   [7:0] cs_a;
	wire   [3:0] cs_be;
	wire  [31:0] cs_wd;
	wire         look_req;
	wire  [12:0] look_a;
	wire   [6:0] wave0, wave1, wave2;
	wire         note_stb;
	wire   [1:0] note_v;
	wire   [7:0] note_val;
	wire         cdf_dig, callfn, svc_pend, svc_hold, svc_fill, dma_set;
	wire  [16:0] svc_src;
	wire  [12:0] svc_dst;
	wire   [7:0] svc_rem, svc_val;
	dec_t        op;
	wire         p32_q, rdP, wb_v, ev_guard_sup;

	daria_fe_core u_core (
		.clk_sys(clk), .rst_fe, .is_dpc, .is_cdf, .jplus, .jrev, .rev(revision[1:0]), .sf(revision[0]),
		.ldx, .ldy, .foff_en, .foff, .a_in, .d_in, .rw, .access,
		.pclk1, .k, .c, .commit, .ph1_open, .ev_short,
		.fea_q, .feb_q, .crb_q, .stb_q,
		.aud_take(aud_take_core), .look_gnt(look_gnt_core), .p32_gnt, .wb_gnt, .guard_on(g_core),
		.amp_nx(amp_next), .svc_take, .init_busy(1'b0), .dma_busy(dma_busy_m), .call_busy(call_busy_m),
		.fe_do, .sel_up, .feb_addr,
		.cr_fix, .cr_fix_a, .cr_fix_we, .cr_fix_be, .cr_fix_wd, .cr_fix_use,
		.cr_p32, .cr_p32_a, .cr_wb, .cr_wb_a, .cr_wb_wd,
		.cs_req, .cs_a, .cs_we, .cs_be, .cs_wd,
		.look_req, .look_a,
		.wave0, .wave1, .wave2, .note_stb, .note_v, .note_val, .cdf_dig,
		.callfn, .svc_pend, .svc_hold, .svc_fill, .svc_src, .svc_dst, .svc_rem, .svc_val, .dma_set,
		.op, .p32_q, .rdP, .wb_v, .ev_guard_sup);

	// ======================================================================================
	// the reduced daria_fe_arb (design 3.1-3.3): no F6, no copy engine, guard off
	// ======================================================================================
	logic        aud_issue = 1'b0;       // the audio stand-in: ISSUE until granted, then CAPTURE
	logic [14:0] aud_addr  = 15'd0;
	wire fix_eff = cr_fix;
	assign aud_take = aud_issue & !sel_up & !fix_eff;
	assign p32_gnt  = cr_p32 & !fix_eff & !aud_take;
	assign wb_gnt   = cr_wb & !fix_eff & !aud_take & !cr_p32;
	wire  [12:0] crb_addr = fix_eff ? cr_fix_a : (aud_take ? aud_addr[14:2] : (p32_gnt ? cr_p32_a : (wb_gnt ? cr_wb_a : 13'd0)));
	wire         crb_we   = (fix_eff & cr_fix_we) | wb_gnt;
	wire   [3:0] crb_be   = fix_eff ? cr_fix_be : (wb_gnt ? 4'hF : 4'h0);
	wire  [31:0] crb_wd   = fix_eff ? cr_fix_wd : cr_wb_wd;
	logic        cl_req = 1'b0, cl_we = 1'b0;   // the call-port stand-in on S
	logic  [7:0] cl_a = 8'hF0;
	logic [31:0] cl_wd = 32'd0;
	wire         cl_gnt   = cl_req & !cs_req;
	wire   [7:0] stb_addr = cs_req ? cs_a : (cl_gnt ? cl_a : 8'h00);
	wire         stb_we   = cs_req ? cs_we : (cl_gnt & cl_we);
	wire   [3:0] stb_be   = cs_req ? cs_be : 4'hF;
	wire  [31:0] stb_wd   = cs_req ? cs_wd : cl_wd;
	logic        aud_a_req = 1'b0;       // the sample-client stand-in on A
	logic [12:0] aud_a_a   = 13'd0;
	assign look_gnt = look_req;
	wire         aud_a_gnt = aud_a_req & !look_req;
	wire  [12:0] fea_addr  = look_gnt ? look_a : (aud_a_gnt ? aud_a_a : 13'd0);

	daria_mem #(.WIN_KB(32)) u_mem (
		.clk_arm(1'b0), .clk_sys(clk),
		.rom_addr(15'd0), .win_qa(), .d_addr(32'd0), .win_qb(), .ram_we(1'b0), .ram_be(4'd0),
		.ram_wdata(32'd0), .ram_q(),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(8'd0), .sta_we(1'b0), .sta_wd(32'd0), .sta_q(),
		.cap_we(1'b0), .cap_addr(15'd0), .cap_data(8'd0),
		.fea_addr, .fea_q, .feb_addr, .feb_q,
		.crb_addr, .crb_we, .crb_be, .crb_wd, .crb_q,
		.stb_addr, .stb_we, .stb_be, .stb_wd, .stb_q);

	// ======================================================================================
	// upstream: the two mappers, the stream tables, the jump map, the 1-clock ROM, cart RAM
	// ======================================================================================
	logic [7:0] img  [0:32767];          // the image (the tb ROM and the FE ROM)
	logic [7:0] xram [0:32767];          // upstream's cart RAM (bytes)
	logic [7:0] ram0 [0:32767];          // the epoch's initial cart RAM (for the F6 emulation)

	wire  [7:0] up_ram_byte;
	logic [7:0] up_rom_q = 8'hFF;

	wire  [7:0] dpc_do, dpc_oe;
	wire [15:0] dpc_flags;
	wire [18:0] dpc_rom_a;
	wire        dpc_ram_sel, dpc_ram_rw;
	wire [17:0] dpc_ram_a;
	wire  [6:0] dpc_w0, dpc_w1, dpc_w2;
	wire        dpc_nw;
	wire  [1:0] dpc_nv;
	wire  [7:0] dpc_nval;
	wire        dpc_sfill;
	wire [18:0] dpc_ssrc;
	wire [14:0] dpc_sdst;
	wire  [7:0] dpc_scnt, dpc_sval;
	mapper_dpcplus up_dpc (
		.clk(clk), .reset(cart_reset || scheme != SCHEME_DPCP), .access, .rw, .a_in, .d_in,
		.rom_data(up_rom_q), .stable_fractional(revision[0]),
		.d_out(dpc_do), .flags_out(dpc_flags), .oe(dpc_oe), .rom_a(dpc_rom_a),
		.ram_sel(dpc_ram_sel), .ram_rw(dpc_ram_rw), .ram_a(dpc_ram_a), .ram_data(up_ram_byte),
		.amplitude(amp_reg), .audio_waveform0(dpc_w0), .audio_waveform1(dpc_w1), .audio_waveform2(dpc_w2),
		.audio_note_write(dpc_nw), .audio_note_voice(dpc_nv), .audio_note_value(dpc_nval),
		.call_request(), .call_entry(), .call_stack(), .call_thumb(), .call_ready(1'b1),
		.service_request(), .service_fill(dpc_sfill), .service_source(dpc_ssrc), .service_dest(dpc_sdst),
		.service_count(dpc_scnt), .service_value(dpc_sval), .service_ready(up_svc_ready));

	wire  [7:0] cdf_do, cdf_oe;
	wire [15:0] cdf_flags;
	wire [18:0] cdf_rom_a;
	wire  [5:0] cdf_ti;
	wire [31:0] tab_ptr, tab_inc;
	wire        cdf_pu;
	wire  [5:0] cdf_pu_idx;
	wire [31:0] cdf_pu_val;
	wire        cdf_ram_en, cdf_ram_write;
	wire [14:0] cdf_ram_addr;
	wire        cdf_digital;
	wire        fj_valid;
	mapper_cdf up_cdf (
		.clk(clk), .reset(cart_reset || scheme != SCHEME_CDF), .access, .rw, .a_in, .d_in,
		.rom_data(up_rom_q), .revision(revision[1:0]), .enable_ldx(ldx), .enable_ldy(ldy),
		.fetch_offset_enable(foff_en), .fetch_offset(foff), .fast_jump_valid(fj_valid),
		.d_out(cdf_do), .flags_out(cdf_flags), .oe(cdf_oe), .rom_a(cdf_rom_a),
		.table_index(cdf_ti), .table_pointer(tab_ptr), .table_increment(tab_inc[15:0]),
		.pointer_update(cdf_pu), .pointer_update_index(cdf_pu_idx), .pointer_update_value(cdf_pu_val),
		.ram_en(cdf_ram_en), .ram_write(cdf_ram_write), .ram_addr(cdf_ram_addr), .ram_wdata(),
		.ram_rdata(up_ram_byte), .amplitude(amp_reg), .digital_audio(cdf_digital),
		.call_request(), .call_entry(), .call_stack(), .call_thumb(), .call_ready(1'b1),
		.cdfj_entry(32'd0), .cdfj_stack(32'd0));

	arm_mapper_tables up_tab (
		.clk_sys(clk), .family(is_cdf ? 2'd2 : 2'd0), .revision(revision),
		.pointer_lookup_index(cdf_ti), .increment_lookup_index(cdf_ti),
		.pointer(tab_ptr), .increment(tab_inc), .pointer_base(), .increment_base(), .map_base(),
		.stream_count(),
		.sys_pointer_write(cdf_pu && is_cdf), .sys_pointer_index(cdf_pu_idx), .sys_pointer_wdata(cdf_pu_val),
		.sys_increment_write(1'b0), .sys_increment_index(6'd0), .sys_increment_wdata(32'd0),
		.sys_map_write(1'b0), .sys_map_index(6'd0), .sys_map_wdata(32'd0),
		.clk_arm(1'b0), .arm_write(1'b0), .arm_accepted(1'b0), .arm_addr(15'd0), .arm_wdata(32'd0),
		.arm_wstrb(4'd0));

	logic        fj_ls = 1'b0, fj_lv = 1'b0;
	logic [24:0] fj_la = 25'd0;
	logic  [7:0] fj_ld = 8'h00;
	cdf_fastjump_table up_fj (
		.clk_sys(clk), .load_start(fj_ls), .load_addr(fj_la), .load_valid(fj_lv), .load_data(fj_ld),
		.query_addr(cdf_rom_a[14:0]), .query_valid(fj_valid));

	// tb_daria's 1-clock ROM (tb_daria.sv:124-129): cart_q <= rom[cart_addr]
	wire [18:0] up_rom_a = is_dpc ? dpc_rom_a : cdf_rom_a;
	always @(posedge clk) up_rom_q <= img[up_rom_a[14:0]];

	// cart2600's port-A mux and strobes (cart2600.sv:191, 255-265, 965-977) and
	// cart_ram_tdp's mapper port (registered word, lane on !pause; $FF on pause)
	wire        up_sel  = is_dpc ? dpc_ram_sel : (is_cdf ? cdf_ram_en : 1'b0);       // sel_ram_sel
	wire        up_srw  = is_dpc ? dpc_ram_rw : (is_cdf ? !cdf_ram_write : 1'b1);
	wire [14:0] up_sa   = is_dpc ? dpc_ram_a[14:0] : cdf_ram_addr;
	logic [12:0] old_ain = 13'd0;
	logic        acc_taken = 1'b0;
	wire         achg     = old_ain != a_in;
	always @(posedge clk) begin
		old_ain <= a_in;
		if (cart_reset || achg || pclk1) acc_taken <= 1'b0;
		else if (mapper_phi2) acc_taken <= 1'b1;
	end
	wire        up_grant = aud_issue & !up_sel;                                        // audio_ram_grant
	wire [14:0] cr_addr  = up_sel ? up_sa : aud_addr;
	// forwarded only while the 6507 runs (tia_en, not in reset) and the bench checks: a
	// stopped (or not yet restarted) bench bus would otherwise re-strobe the frozen
	// PUSH/WRITE address of an epoch's last cycle once access_taken clears at an E0
	wire        cr_wr    = up_sel & !up_srw & !pclk1 & !achg & !acc_taken & driver_run & pg_run & !cart_reset & checking;
	logic [31:0] up_word = 32'd0;
	logic  [1:0] up_lane = 2'd0;
	assign up_ram_byte = pause ? 8'hFF : up_word[8*up_lane +: 8];
	wire   [7:0] up_byte = (is_dpc ? dpc_flags[0] : cdf_flags[0]) ? (is_dpc ? dpc_do : cdf_do) : up_rom_q;

	function automatic logic [31:0] xword(input int w);
		return {xram[4*w+3], xram[4*w+2], xram[4*w+1], xram[4*w]};
	endfunction
	function automatic logic [31:0] dword(input int w);
		return u_mem.cart_ram.mem_q[w];
	endfunction

	// ======================================================================================
	// bookkeeping
	// ======================================================================================
	longint clk_n = 0;                   // edges since time 0
	longint cyc_n = 0;                   // E0s while checking
	int     epoch = 0;
	longint ep_cyc = 0;                  // E0s in this epoch
	int     e0n = 7;                     // edges since the last E0 (saturates at 15)
	bit     cyc_short = 1'b0;            // this cycle has C < E0+6 (or a phase 1 < 6 at its pclk0)
	bit     cyc_commit = 1'b0;
	longint c_edge = 0;                  // the last commit edge
	bit     wb_pending = 1'b0;           // a pointer write is due (set at C or the deferred act)
	longint wb_c = 0;
	bit     wb_short = 1'b0;
	logic [5:0] ti_prev = 6'd0;          // upstream table index registered at the last edge
	bit     cur_q26 = 1'b0;              // this cycle's pointer update used a stale index
	bit     cur_alias = 1'b0;
	bit     sw_pending = 1'b0;           // a scheme switch at the next pclk1 clock
	logic [5:0] sw_to = 6'd0;
	bit     rst_prev = 1'b0;             // rst_fe was high in the last clock
	logic [5:0] rst_sch = 6'd0;
	logic [2:0] rst_rev = 3'd0;
	bit     prev_dma = 1'b0, prev_call = 1'b0;
	bit     sp_prev = 1'b0, cp_prev = 1'b0;
	bit     svc_prev = 1'b0;
	int     touched [$];                 // cart RAM words written this cycle (either side)
	int     up_wr_words [$];             // words upstream's strobe wrote this cycle
	bit     repair_q = 1'b0;             // repairs to do at the next negedge
	int     repair_words [$];
	bit     tab_sync_q = 1'b0;
	logic [31:0] wbq_v = 0;              // upstream writeback due at the next edge
	int     wbq_w = 0;
	logic [31:0] wbq_d = 32'd0;
	bit     aud_cap = 1'b0;              // DARIA's audio read is on crb_q in this clock
	int     aud_cap_w = 0;
	bit     aud_cap_cls = 1'b0;
	bit     cyc_rst = 1'b0;              // cart_reset (or a non-ARM scheme) in this cycle: no state compare
	bit     cyc_rrel = 1'b0;             // cart_reset fell in this cycle's pclk0 clock (a release epoch)
	bit     rrel_bias = 1'b0;            // the bus stream: post-action registers and ROM reads, alternating
	bit     rrel_alt = 1'b0;
	bit     rrel_sync_q = 1'b0;          // copy upstream's DPC+ fetchers into the state RAM at the negedge
	bit     cur_dalias = 1'b0;           // DARIA's ev_tbl_alias in this cycle
	longint cls_clk = -100;              // the last classified event (q26, repair, short commit)

	// counts
	longint bad = 0;
	longint n_a2 = 0, n_grant = 0, n_dout = 0, n_dout_hidden = 0, n_state = 0, n_ram = 0, n_land = 0;
	longint n_aud = 0, n_jok = 0, n_jmap = 0, n_fix = 0, n_assert = 0, n_svc = 0, n_dma = 0, n_call = 0;
	longint n_note = 0, n_wave = 0, n_dig = 0, n_rst = 0, n_src = 0, n_misc = 0, n_alias_bad = 0;
	// classified (information)
	longint c_short = 0, c_dout_short = 0, c_steal = 0, c_q26 = 0, c_q26_rep = 0, c_alias = 0;
	longint c_noacc = 0, c_aud_cls = 0, c_switch = 0, c_reset = 0, c_7800 = 0, c_other = 0, c_rst_skip = 0;
	longint c_p32_rst = 0;
	longint c_rrel = 0, c_rrel_dout = 0, c_rrel_words = 0, v_rrel_drop = 0, v_rrel_kept = 0;
	// rcyc's meaning, modelled apart from the RTL (lanes/F1_fixes.md 1): 1 exactly when some
	// edge since the last pclk1 edge (that edge excluded) had rst_fe high, i.e. the last
	// edge with rst_fe is later than the last pclk1 edge
	longint t_rst_edge = -2, t_pclk1_edge = -1;
	longint n_rcyc = 0;
	bit     drop_chk = 1'b0;             // a pclk1 with rcyc left actions pending: are they gone after it?
	bit     drop_c = 1'b0, drop_s = 1'b0, drop_r = 1'b0;
	longint v_rrel_k [0:3] = '{0, 0, 0, 0};    // releases in DFxDATA-type reads, PUSH/WRITE, DSWRITE, DSPTR
	longint v_cmp_state = 0, n_hold = 0;
	bit     hold_on = 1'b0;              // fe_do must hold the latched byte (C ... the next E0+2)
	logic [7:0] hold_v = 8'h00;               // a_p32_late's formula true after a reset inside a DSWRITE cycle
	// coverage
	longint v_latch = 0, v_hidden = 0, v_commit = 0, v_rd = 0, v_wr = 0, v_held = 0, v_aud = 0, v_wbn = 0;
	longint v_land1 = 0, v_land2 = 0, v_land_s = 0, v_jok1 = 0, v_jokk = 0, v_full = 0, v_p32_k2 = 0;
	longint v_svc = 0, v_svc_def = 0, v_dsw_def = 0, v_pause = 0, v_stretch = 0, v_l1_2 = 0, v_l1_4 = 0;
	longint v_cls [0:15];                // commits per op class (opc_t bit order, MSB rom)
	longint v_hot = 0, v_c26 = 0, v_fexp = 0, v_held_cyc = 0, v_cjmp_end = 0, v_sub_hot = 0, v_jok_end = 0;
	longint v_sch [0:5];                 // E0s per scheme: DPC+ sf0, sf1, CDF0, CDF1, CDFJ, CDFJ+
	longint v_ldxy = 0, v_foff = 0, v_dig = 0, v_note = 0, v_rst_sw = 0, v_rst_cr = 0, v_rst_oth = 0;

	task automatic fail(input string cls, input string what, input longint got, input longint exp);
		bad++;
		if (bad <= stop_n)
			$display("FAIL %-6s %-24s got %h exp %h | t %0t clk %0d epoch %0d cyc %0d scheme %0d rev %0d e0n %0d k %b a_in %h rw %b d_in %h acc %b short %b",
				cls, what, got, exp, $time, clk_n, epoch, ep_cyc, scheme, revision, e0n, k, a_in, rw, d_in, access, cyc_short);
	endtask

	// ======================================================================================
	// the program-like bus stream (EXT_BUS)
	// ======================================================================================
	logic [12:0] pc = 13'h1000;
	logic [12:0] last_a = 13'h1000;
	int          fresh = 0;              // forced arming writes at an epoch's start
	int          burst = 0;              // writes left in a write burst (RMW, pushes)
	logic [11:0] arm_off [0:2][0:7];     // the planted arming opcode before each window's hotspots
	logic [12:0] burst_a = 13'h1000;

	task automatic gen_next();
		int r;
		logic [12:0] a;
		logic w;
		logic [7:0] d;
		d = rnd8();
		w = 1'b0;                            // 0: read
		if (rrel_bias) begin                 // a release epoch's reset: every other access is one whose
			rrel_alt = !rrel_alt;            // post action waits for a read (DFxDATA/DATAW/FRACDATA,
			if (!rrel_alt)                   // PUSH, WRITE; DSWRITE, DSPTR), the others plain ROM reads,
				a = {1'b1, 12'h100 + 12'(rnd(12'hE00))};       // so that a stranded action is not
			else if (is_dpc) begin                              // repeated by the next cycle (no CALLFN)
				if (rnd(2) == 0) a = 13'h1008 + 13'(rnd(24));
				else begin
					w = 1'b1;
					a = (rnd(2) == 0) ? (13'h1060 + 13'(rnd(8))) : (13'h1078 + 13'(rnd(8)));
				end
			end else begin
				w = 1'b1;
				a = 13'h1FF0 + 13'(rnd(2));
			end
		end else if (fresh > 0) begin
			fresh--;
			if (is_dpc) begin a = 13'h1058; w = 1'b1; d = 8'h00; end
			else begin a = 13'h1FF2; w = 1'b1; d = {rnd8() & 8'hF0}; end
		end else if (burst > 0) begin                  // a run of writes (RMW, stack pushes): the
			burst--;                                     // third write of a stall is hidden (top.sv)
			w = 1'b1;
			a = (rnd(2) == 0) ? burst_a : (is_dpc ? ((rnd(2) == 0) ? (13'h1060 + 13'(rnd(8))) : (13'h1078 + 13'(rnd(8))))
			                                       : (13'h1FF0 + 13'(rnd(4))));
		end else if (rnd(1000) < 15) begin
			burst = 2 + int'(rnd(3));
			burst_a = is_dpc ? (13'h1028 + 13'(rnd(88))) : (13'h1FF0 + 13'(rnd(4)));
			a = burst_a;                                 // the RMW's read
		end else begin
			r = int'(rnd(1000));
			if (r < 520) begin                           // the next byte of the program
				a = pc;
				pc = pc + 13'd1;
				if (!pc[12] && rnd(4) != 0) pc = {1'b1, 12'(rnd(4096))};
			end else if (r < 600) begin                  // TIA/RIOT: A12 = 0 (neither arms nor disarms)
				a = {1'b0, 12'(rnd(4096))};
				w = rnd(10) < 3;
			end else if (r < 720) begin                  // the scheme's registers
				if (is_dpc) begin
					if (rnd(100) < 45) a = 13'h1000 | 13'(rnd(40));
					else begin
						int g;
						w = 1'b1;
						g = int'(rnd(100));
						if (g < 45) begin                      // field writes, g 0-5, 8
							int gg;
							gg = int'(rnd(7));
							if (gg == 6) gg = 8;
							a = 13'h1028 + 13'(gg * 8) + 13'(rnd(8));
						end else if (g < 55) begin a = 13'h1058; d = (rnd(10) < 8) ? 8'h00 : rnd8(); end
						else if (g < 65) a = 13'h1059;
						else if (g < 73) begin
							int q;
							a = 13'h105A;
							q = int'(rnd(20));
							d = (q < 5) ? 8'd0 : (q < 10) ? 8'd1 : (q < 15) ? 8'd2 : (q < 18) ? (8'hFE | 8'(rnd(2))) : rnd8();
						end else if (g < 78) a = 13'h105D + 13'(rnd(3));
						else if (g < 90) a = (rnd(2) == 0) ? (13'h1060 + 13'(rnd(8))) : (13'h1078 + 13'(rnd(8)));
						else a = 13'h1070 + 13'(rnd(8));
					end
				end else begin
					int g;
					w = 1'b1;
					g = int'(rnd(100));
					if (g < 35) a = 13'h1FF0;
					else if (g < 60) a = 13'h1FF1;
					else if (g < 80) begin a = 13'h1FF2; d = (rnd(10) < 8) ? (rnd8() & 8'hF0) : rnd8(); end
					else begin a = 13'h1FF3; d = (rnd(10) < 7) ? (8'hFE | 8'(rnd(2))) : rnd8(); end
				end
			end else if (r < 760) begin                  // hotspots
				a = is_dpc ? (13'h1FF6 + 13'(rnd(6))) : (13'h1FF4 + 13'(rnd(8)));
				if (rnd(10) == 0) a = 13'h1FF0 + 13'(rnd(16));
				w = rnd(10) < 4;
			end else if (r < 840) begin                  // a jump: the next bytes come from elsewhere
				int q;
				pc = {1'b1, 12'(rnd(4096))};
				q = int'(rnd(10));
				if (q < 3) pc = {1'b1, 12'hFF0 | 12'(rnd(16))};
				else if (q == 3) pc = {1'b1, arm_off[is_dpc ? 0 : (jplus ? 2 : 1)][u_core.bank]};   // onto the hotspots
				a = pc;
				pc = pc + 13'd1;
			end else if (r < 870) begin                  // the same address again (RMW, dummy reads)
				a = last_a;
			end else begin                               // anywhere in the window
				a = {1'b1, 12'(rnd(4096))};
				w = rnd(4) == 0;
			end
		end
		last_a = a;
		nx_a  <= a;
		nx_rw <= !w;
		nx_d  <= d;
	endtask

	always @(posedge clk) if (load) gen_next();

	// ======================================================================================
	// the stand-ins: audio requester (R), sample client (A), call port (S), amplitude,
	// service taker, random unused inputs
	// ======================================================================================
	int  aud_wait = 0;
	bit  aud_capst = 1'b0;
	function automatic logic [14:0] aud_pick();
		int r;
		logic [8:0] pb;
		pb = pb_now();
		r = int'(rnd(100));
		if (r < 40) return {4'h0, pb + 9'(rnd(36)), 2'b00};          // a pointer word
		if (r < 50) return {4'h0, pb + 9'(36 + rnd(40)), 2'b00};     // the increments and beyond
		if (r < 60) return 15'h0C00 + 15'(rnd(4096));                // DPC+ display data
		return 15'(rnd(32768));
	endfunction
	always @(posedge clk) begin
		// audio: ISSUE holds until upstream's grant, one CAPTURE clock, then a gap of 0..6
		if (aud_issue) begin
			if (up_grant) begin
				aud_issue <= 1'b0;
				aud_capst = 1'b1;
				aud_wait = int'(rnd(7));
			end
		end else if (aud_capst) begin
			aud_capst = 1'b0;
			if (aud_wait == 0) begin aud_issue <= 1'b1; aud_addr <= aud_pick(); end
		end else if (aud_wait > 0) aud_wait--;
		else begin aud_issue <= 1'b1; aud_addr <= aud_pick(); end
		// sample client on A, call port on S
		aud_a_req <= rnd(8) == 0;
		aud_a_a   <= 13'(rnd(8192));
		cl_req    <= rnd(4) == 0;
		cl_we     <= rnd(2) == 0;
		cl_a      <= 8'hF0 | 8'(rnd(14));
		cl_wd     <= rnd32();
		// amplitude: upstream's register takes the value presented as amp_nx
		amp_reg <= amp_next;
		if (rnd(4) == 0) amp_next <= rnd8();
		// unused or formula-only inputs
		g_core        <= rnd(8) == 0;
		dma_busy_m    <= rnd(3) == 0;
		call_busy_m   <= rnd(2) == 0;
		aud_take_core <= rnd(2) == 0;
		look_gnt_core <= rnd(2) == 0;
		// the service taker: both sides' pending latch is taken in one clock
		svc_take     <= 1'b0;
		up_svc_ready <= 1'b0;
		if (svc_pend && up_dpc.service_pending && !svc_take && rnd(16) == 0) begin
			svc_take     <= 1'b1;
			up_svc_ready <= 1'b1;
		end
	end

	// ======================================================================================
	// the reference reset values (2.4) and the state compare (C1, C2)
	// ======================================================================================
	task automatic check_reset_values(input logic [5:0] sch, input logic [2:0] rv);
		logic dp, jp;
		logic [2:0] bk;
		dp = sch == SCHEME_DPCP;
		jp = (sch == SCHEME_CDF) && (rv[1:0] == 2'd3);
		bk = dp ? 3'd5 : (jp ? 3'd0 : 3'd6);
		if (u_core.bank !== bk) fail("rst", "bank", u_core.bank, bk);
		if (u_core.fpend !== 1'b0 || u_core.fexp !== 13'd0 || u_core.jr !== 2'd0 || u_core.jexp !== 13'd0)
			fail("rst", "fpend/fexp/jr/jexp", {u_core.fpend, u_core.fexp, u_core.jr, u_core.jexp}, 0);
		if (u_core.jstream !== 6'd33) fail("rst", "jstream", u_core.jstream, 33);
		if (u_core.mode !== 8'hFF) fail("rst", "mode", u_core.mode, 8'hFF);
		if (u_core.ff_en !== 1'b0 || u_core.pptr !== 4'd0) fail("rst", "ff_en/pptr", {u_core.ff_en, u_core.pptr}, 0);
		if (u_core.rnd !== 32'h2B43_5044) fail("rst", "rnd", u_core.rnd, 32'h2B43_5044);
		if (wave0 !== 0 || wave1 !== 0 || wave2 !== 0 || note_stb !== 0 || note_v !== 0 || note_val !== 0)
			fail("rst", "wave/note", {wave0, wave1, wave2, note_stb, note_v, note_val}, 0);
		if (svc_pend !== 0 || svc_fill !== 0 || svc_src !== 0 || svc_dst !== 0 || svc_rem !== 0 || svc_val !== 0)
			fail("rst", "svc", {svc_pend, svc_fill, svc_src, svc_dst, svc_rem, svc_val}, 0);
		if (u_core.pend_c !== PC_NONE || u_core.pend_s !== 0 || u_core.pend_r !== 0 || wb_v !== 0)
			fail("rst", "pend/wb_v", {u_core.pend_c, u_core.pend_s, u_core.pend_r, wb_v}, 0);
		if (u_core.rdW !== 0 || rdP !== 0 || u_core.rdS !== 0 || p32_q !== 0 || u_core.p32_got !== 0)
			fail("rst", "ready flags/p32", {u_core.rdW, rdP, u_core.rdS, p32_q, u_core.p32_got}, 0);
		if (fe_do !== 8'h00) fail("rst", "fe_do", fe_do, 0);
		n_rst++;
	endtask

	task automatic cmp_state(input logic [5:0] sch);
		if (sch == SCHEME_DPCP) begin
			for (int i = 0; i < 8; i++) begin
				logic [31:0] w0, w1;
				w0 = u_mem.state_ram.mem_q[2*i];
				w1 = u_mem.state_ram.mem_q[2*i+1];
				if (w0[11:0]  !== up_dpc.counter[i])    begin n_state++; fail("state", $sformatf("counter[%0d]", i), w0[11:0], up_dpc.counter[i]); end
				if (w0[23:16] !== up_dpc.top[i])        begin n_state++; fail("state", $sformatf("top[%0d]", i), w0[23:16], up_dpc.top[i]); end
				if (w0[31:24] !== up_dpc.bottom[i])     begin n_state++; fail("state", $sformatf("bottom[%0d]", i), w0[31:24], up_dpc.bottom[i]); end
				if (w1[19:0]  !== up_dpc.fractional[i]) begin n_state++; fail("state", $sformatf("fractional[%0d]", i), w1[19:0], up_dpc.fractional[i]); end
				if (w1[31:24] !== up_dpc.increment[i])  begin n_state++; fail("state", $sformatf("increment[%0d]", i), w1[31:24], up_dpc.increment[i]); end
			end
			for (int b = 0; b < 4; b++)
				if (u_mem.state_ram.mem_q[16][8*b +: 8] !== up_dpc.params[b]) begin
					n_state++; fail("state", $sformatf("params[%0d]", b), u_mem.state_ram.mem_q[16][8*b +: 8], up_dpc.params[b]);
				end
			if (u_core.pptr !== up_dpc.parameter_pointer) begin n_state++; fail("state", "pptr", u_core.pptr, up_dpc.parameter_pointer); end
			for (int v = 0; v < 3; v++)
				if (u_core.wave[v] !== up_dpc.waveform[v]) begin n_state++; fail("state", $sformatf("wave[%0d]", v), u_core.wave[v], up_dpc.waveform[v]); end
			if (u_core.rnd !== up_dpc.random_number) begin n_state++; fail("state", "rnd", u_core.rnd, up_dpc.random_number); end
			if (u_core.bank !== up_dpc.bank) begin n_state++; fail("state", "bank", u_core.bank, up_dpc.bank); end
			if (u_core.ff_en !== up_dpc.fast_fetch) begin n_state++; fail("state", "ff_en", u_core.ff_en, up_dpc.fast_fetch); end
			if (u_core.fpend !== up_dpc.fast_pending) begin n_state++; fail("state", "fpend", u_core.fpend, up_dpc.fast_pending); end
			if (svc_pend !== up_dpc.service_pending) begin n_state++; fail("state", "svc_pend", svc_pend, up_dpc.service_pending); end
		end else if (sch == SCHEME_CDF) begin
			if (u_core.bank !== up_cdf.bank) begin n_state++; fail("state", "bank", u_core.bank, up_cdf.bank); end
			if (u_core.mode !== up_cdf.mode) begin n_state++; fail("state", "mode", u_core.mode, up_cdf.mode); end
			if (u_core.fpend !== up_cdf.fast_pending) begin n_state++; fail("state", "fpend", u_core.fpend, up_cdf.fast_pending); end
			if (u_core.fexp !== up_cdf.fast_expected_address) begin n_state++; fail("state", "fexp", u_core.fexp, up_cdf.fast_expected_address); end
			if (u_core.jr !== up_cdf.jump_remaining) begin n_state++; fail("state", "jr", u_core.jr, up_cdf.jump_remaining); end
			if (u_core.jexp !== up_cdf.expected_address) begin n_state++; fail("state", "jexp", u_core.jexp, up_cdf.expected_address); end
			if (u_core.jstream !== up_cdf.jump_stream) begin n_state++; fail("state", "jstream", u_core.jstream, up_cdf.jump_stream); end
		end
	endtask

	// the cart RAM word compare; a classified mismatch is queued for repair
	task automatic cmp_word(input int w, input bit classified, input string why);
		if (dword(w) !== xword(w)) begin
			if (classified) begin
				repair_words.push_back(w);
				repair_q = 1'b1;
				cls_clk = clk_n;
			end else begin
				n_ram++;
				fail("ram", $sformatf("%s word %h", why, w), dword(w), xword(w));
			end
		end
	endtask

	// ======================================================================================
	// the per-clock checks and the upstream RAM model (one block: pre-edge values)
	// ======================================================================================
	// the pointer and increment table bases (word addresses; arm_mapper_tables' layout). A
	// function, not an always_comb: the epoch tasks read it right after setting revision.
	function automatic logic [8:0] pb_now();
		return (revision[1:0] == 2'd0) ? 9'h1B8 : ((revision[1:0] == 2'd1) ? 9'h028 : 9'h026);
	endfunction
	function automatic logic [8:0] ib_now();
		return (revision[1:0] == 2'd0) ? 9'h1DA : ((revision[1:0] == 2'd1) ? 9'h04A : 9'h049);
	endfunction

	always @(posedge clk) begin
		bit short_now;
		int cls;
		clk_n++;

		// ---------------- the per-clock checks ----------------
		if (checking) begin
			// 1: A2 and the grant
			if (sel_up !== up_sel) begin n_a2++; fail("a2", "sel_up", sel_up, up_sel); end
			if (aud_take !== up_grant) begin
				if (aud_issue && !sel_up && fix_eff && (cyc_short || cyc_rst)) c_steal++;
				else begin n_grant++; fail("a2", "aud_take", aud_take, up_grant); end
			end
			if (aud_take) v_aud++;
			if (p32_gnt && k[2]) v_p32_k2++;
			// 6: fixed R use only inside the select (C >= E0+6); the arb's assertions
			// (a reset inside the cycle clears the ready flags and the state: the 6507 is in
			// reset, and so is upstream's audio; a_p32_late would fire there, see the report)
			if (fix_eff && !sel_up && !cyc_short && !cyc_rst) begin n_fix++; fail("fix", "cr_fix outside sel_up", cr_fix_a, 0); end
			if (wb_v && k[1] && !cyc_rst) begin n_assert++; fail("assert", "a_wb_late", 1, 0); end
			if (k[3] && (op.c.cdsw | op.c.cdsp) && !(p32_q | rdP)) begin
				if (cyc_rst) c_p32_rst++;
				else begin n_assert++; fail("assert", "a_p32_late", 1, 0); end
			end
			if (u_core.a_pend_late) begin n_assert++; fail("assert", "a_pend_late", 1, 0); end
			// the post actions' set never meets their pclk1 clear (every set needs commit). A
			// sanity check of this bench's phase generator only: phase_gen emits pclk1 and pclk0
			// in exclusive branches, so it cannot fail here. The system's proof is top.sv
			// (phi1_en/phi2_en), checked by fe_shadow's commit_pclk1 (lanes/F1_fixes.md 1)
			if (commit && pclk1) begin n_assert++; fail("assert", "commit in a pclk1 clock", 1, 0); end
			// rcyc against its meaning, on every clock once a pclk1 edge was seen (not a formula
			// check: it stays on in mutation runs, since rcyc gates a_pend_late)
			if (t_pclk1_edge >= 0 && u_core.rcyc !== (t_rst_edge > t_pclk1_edge)) begin
				n_rcyc++; fail("rcyc", "rcyc", u_core.rcyc, t_rst_edge > t_pclk1_edge);
			end
			// a release cycle's actions dropped at pclk1: pending before a pclk1 with rcyc (which
			// masks a_pend_late there) and no longer pending after it (checked at the next clock)
			if (drop_chk) begin
				if ((drop_c && u_core.pend_c != PC_NONE) || (drop_s && u_core.pend_s) || (drop_r && u_core.pend_r))
					v_rrel_kept++;
				else v_rrel_drop++;
			end
			drop_chk = pclk1 && u_core.rcyc && !rst_fe && ((u_core.pend_c != PC_NONE) || u_core.pend_s || u_core.pend_r);
			drop_c = u_core.pend_c != PC_NONE;
			drop_s = u_core.pend_s;
			drop_r = u_core.pend_r;
			if (u_core.a_fpjr) begin n_assert++; fail("assert", "a_fpjr", 1, 0); end
			// the port formulas of 1.4/3.1 (restated; off in mutation runs)
			if (formula) begin
				if (ev_guard_sup !== (g_core & (cr_fix | cr_p32))) begin n_assert++; fail("assert", "ev_guard_sup", ev_guard_sup, g_core & (cr_fix | cr_p32)); end
				if (u_core.ev_rmw_svc !== (dma_set & dma_busy_m)) begin n_misc++; fail("misc", "ev_rmw_svc", u_core.ev_rmw_svc, dma_set & dma_busy_m); end
				if (svc_hold !== (svc_pend | (u_core.pend_c == PC_SVC))) begin n_misc++; fail("misc", "svc_hold", svc_hold, 0); end
				if (look_req !== (k[0] & is_cdf)) begin n_misc++; fail("misc", "look_req", look_req, k[0] & is_cdf); end
				if (cr_wb !== (wb_v & u_core.rdW)) begin n_misc++; fail("misc", "cr_wb", cr_wb, wb_v & u_core.rdW); end
				if (cr_fix_use !== (cr_fix & !cr_fix_we)) begin n_misc++; fail("misc", "cr_fix_use", cr_fix_use, cr_fix & !cr_fix_we); end
			end
			// one source per register and per request (D10's AND-OR selects)
			if ($countones({u_core.ld_crb, u_core.ld_stb, u_core.ld_add, u_core.ld_shf}) > 1) begin n_src++; fail("src", "W sources", {u_core.ld_crb, u_core.ld_stb, u_core.ld_add, u_core.ld_shf}, 0); end
			if ($countones({u_core.fx_ptr, u_core.fx_dat, u_core.fx_inc, u_core.fx_dsw, u_core.fx_pw}) > 1) begin n_src++; fail("src", "cr_fix sources", 0, 0); end
			if ($countones({u_core.cs_rd1, u_core.cs_rd2, u_core.s_fire}) > 1) begin n_src++; fail("src", "cs sources", 0, 0); end
			if ($countones({u_core.fd_k1, u_core.fd_flg, u_core.fd_ram, u_core.fd_amp}) > 1) begin n_src++; fail("src", "fe_do sources", 0, 0); end
			if ($countones({u_core.bv_fn, u_core.bv_fp, u_core.bv_j, u_core.bv_1, u_core.bv_f, u_core.bv_i}) > 1) begin n_src++; fail("src", "Bv sources", 0, 0); end
			// 5: jok against the map, in every CDF k[1]
			if (is_cdf && k[1]) begin
				if (u_core.jok !== fj_valid) begin n_jok++; fail("jok", "jok", u_core.jok, fj_valid); end
				v_jokk++;
				if (fj_valid) v_jok1++;
				if (fj_valid && u_core.rom_a[11:0] >= 12'hFFD) v_jok_end++;
			end
			// 7: NOTE, waveforms, cdf_dig
			if (note_stb !== (is_dpc & dpc_nw)) begin n_note++; fail("note", "note_stb", note_stb, dpc_nw); end
			else if (note_stb && (note_v !== dpc_nv || note_val !== dpc_nval)) begin n_note++; fail("note", "note_v/val", {note_v, note_val}, {dpc_nv, dpc_nval}); end
			if (note_stb) v_note++;
			if (is_dpc && (wave0 !== dpc_w0 || wave1 !== dpc_w1 || wave2 !== dpc_w2)) begin n_wave++; fail("wave", "wave", {wave0, wave1, wave2}, {dpc_w0, dpc_w1, dpc_w2}); end
			if (cdf_dig !== cdf_digital) begin n_dig++; fail("dig", "cdf_dig", cdf_dig, cdf_digital); end   // reset mode = $FF
			if (cdf_dig) v_dig++;
			// 7: dma_set and callfn one clock before upstream's pending rises
			if (is_dpc && ((up_dpc.service_pending && !sp_prev) !== prev_dma)) begin n_dma++; fail("svc", "dma_set", prev_dma, up_dpc.service_pending); end
			if ((is_dpc ? up_dpc.call_pending : (is_cdf ? up_cdf.call_pending : 1'b0)) !== prev_call) begin
				// call_ready is 1: upstream's call_pending is high exactly in (C, C+1)
				n_call++; fail("call", "callfn", prev_call, 0);
			end
			// 7: the service latch, when DARIA's pending rises
			if (svc_pend && !svc_prev) begin
				logic [15:0] off;
				logic [11:0] cnt;
				logic [12:0] davl;
				logic [16:0] savl;
				logic  [7:0] fillc, copyc, cntx;
				v_svc++;
				off   = 16'(svc_src - 17'h00C00);
				cnt   = 12'(svc_dst - 13'h0C00);
				davl  = 13'h1000 - {1'b0, cnt};
				fillc = (davl < {5'd0, svc_rem}) ? davl[7:0] : svc_rem;
				savl  = 17'h07400 - {1'b0, off};
				copyc = (off >= 16'h7400) ? 8'd0 : ((savl < {9'd0, fillc}) ? savl[7:0] : fillc);
				cntx  = svc_fill ? fillc : copyc;
				if (svc_fill !== dpc_sfill || {2'b00, svc_src} !== dpc_ssrc || {2'b00, svc_dst} !== dpc_sdst ||
				    cntx !== dpc_scnt || svc_val !== dpc_sval) begin
					n_svc++;
					fail("svc", "service fields", {svc_fill, svc_src, svc_dst, cntx, svc_val}, {dpc_sfill, dpc_ssrc[16:0], dpc_sdst[12:0], dpc_scnt, dpc_sval});
				end
			end
			// 2: fe_do at the latch (the pclk0 clock of a read with A12)
			if (pclk0 && rw && a_in[12] && driver_run && !cart_reset && (is_dpc | is_cdf)) begin
				short_now = cyc_short || (e0n < 5);
				v_latch++;
				if (!access) v_hidden++;
				if (fe_do !== up_byte) begin
					if (short_now) c_dout_short++;
					else if (cyc_rrel) c_rrel_dout++;      // the release cycle read under rst_fe
					else if (!access) begin n_dout_hidden++; fail("dout", "fe_do (hidden pclk0)", fe_do, up_byte); end
					else begin n_dout++; fail("dout", "fe_do", fe_do, up_byte); end
				end
			end
			if (pclk0 && e0n < 5) cyc_short = 1'b1;
			// fe_do holds the latched byte through phase 2 and k[0], k[1] (2.4: ph1_open)
			if (hold_on && !rst_fe && fe_do !== hold_v) begin n_hold++; fail("dout", "fe_do changed after the latch", fe_do, hold_v); end
			if (k[1] || rst_fe) hold_on = 1'b0;
			if (pclk0) begin hold_on = 1'b1; hold_v = fe_do; end
			// 4: DARIA's audio read returns upstream's word
			if (aud_cap) begin
				if (crb_q !== up_word) begin
					if (aud_cap_cls || (clk_n - cls_clk < 24)) c_aud_cls++;
					else begin n_aud++; fail("aud", $sformatf("audio read word %h", aud_cap_w), crb_q, up_word); end
				end
			end
			aud_cap = 1'b0;
			if (aud_take && up_grant) begin
				bit dirty;
				dirty = 1'b0;
				foreach (repair_words[i]) if (repair_words[i] == int'(aud_addr[14:2])) dirty = 1'b1;
				aud_cap     = 1'b1;
				aud_cap_w   = int'(aud_addr[14:2]);
				aud_cap_cls = cyc_short || dirty || repair_q || cur_q26 || (clk_n - cls_clk < 24);
			end
			// 4: the pointer write lands at C+1 or C+2
			if (wb_gnt) begin
				longint d;
				d = clk_n - wb_c;
				v_wbn++;
				if (wb_short) v_land_s++;
				else if (d == 1) v_land1++;
				else if (d == 2) v_land2++;
				else begin n_land++; fail("ram", "pointer_land", d, 1); end
				wb_pending = 1'b0;
			end
			if (crb_we) begin
				bit seen;
				seen = 1'b0;
				foreach (touched[i]) if (touched[i] == int'(crb_addr)) seen = 1'b1;
				if (!seen) touched.push_back(int'(crb_addr));
			end
			// 8: reset values one clock after an rst_fe clock
			if (rst_prev) check_reset_values(rst_sch, rst_rev);
			// commits
			if (commit) begin
				v_commit++;
				if (rw) v_rd++; else v_wr++;
				if (held) v_held++;
				if (ev_short) begin cyc_short = 1'b1; c_short++; cls_clk = clk_n; end
				if (ev_short !== (e0n < 5)) begin n_misc++; fail("misc", "ev_short", ev_short, e0n < 5); end
				cyc_commit = 1'b1;
				c_edge = clk_n;
				for (int b = 0; b < 16; b++) if (u_core.opc.c[b]) v_cls[b]++;
				if (u_core.opc.hot) v_hot++;
				if (u_core.opc.c.cjmp && a_in[11:0] >= 12'hFFE) v_cjmp_end++;
				if ((u_core.opc.c.cfet | u_core.opc.c.amp | u_core.opc.c.rdat | u_core.opc.c.rflg | u_core.opc.c.rrnd) &&
				    a_in[11:0] >= 12'hFF4 && a_in[11:0] <= 12'hFFB) v_sub_hot++;
				if (u_core.wb_set_f) begin wb_pending = 1'b1; wb_c = clk_n; wb_short = cyc_short; end
				if (u_core.at_svc && !u_core.rdS_r) v_svc_def++;
				if ((u_core.at_dsw || u_core.at_dsp) && !rdP) v_dsw_def++;
				// Q26: upstream's pointer update takes the word of the previous edge's index
				if (is_cdf && rw && up_cdf.stream_substitute &&
				    ((cdf_ti != up_cdf.amplitude_stream) || up_cdf.jump_substitute) && (cdf_ti != ti_prev)) begin
					cur_q26 = 1'b1;
					c_q26++;
					cls_clk = clk_n;
					if (!cyc_short) begin n_misc++; fail("misc", "Q26 outside a short phase", cdf_ti, ti_prev); end
				end
				// tbl_alias: a CDFJ+ DSWRITE into the tables (upstream's cache keeps the old word)
				if (jplus && !rw && a_in == 13'h1FF0 && cdf_ram_addr >= 15'h0098 && cdf_ram_addr < 15'h01B0) begin
					cur_alias = 1'b1;
					c_alias++;
				end
			end else if (ev_short) begin n_misc++; fail("misc", "ev_short without commit", 1, 0); end
			if (u_core.act_dsw | u_core.act_dsp) begin
				if (!commit) begin wb_pending = 1'b1; wb_c = clk_n; wb_short = 1'b1; end
				else begin wb_pending = 1'b1; wb_c = clk_n; wb_short = cyc_short; end
				if (formula && u_core.ev_tbl_alias !== (jplus && u_core.act_dsw && u_core.dsw_addr >= 15'h0098 && u_core.dsw_addr < 15'h01B0))
					begin n_alias_bad++; fail("misc", "ev_tbl_alias", u_core.ev_tbl_alias, 0); end
				if (u_core.ev_tbl_alias) cur_dalias = 1'b1;
			end
			if (pause) v_pause++;

			// ---------------- per cycle: at the pclk1 clock (the cycle ends at this edge) -------
			if (pclk1) begin
				// 3: the scheme state the cycle left (by the scheme it ran: a switch is in this clock)
				if (cyc_rst) c_rst_skip++;
				else begin cmp_state(scheme_q); v_cmp_state++; end
				if (cur_alias != cur_dalias && !cyc_short) begin n_alias_bad++; fail("misc", "tbl_alias: one side only", cur_dalias, cur_alias); end
				// 4: the words written in this cycle
				if (cur_alias) tab_sync_q = 1'b1;
				// a release cycle: upstream did the access, daria_fe dropped its post action
				// (lanes/F1_fixes.md 1): its words are repaired, the DPC+ fetchers resynced
				if (cyc_rrel) begin
					foreach (touched[i]) if (dword(touched[i]) !== xword(touched[i])) c_rrel_words++;
					foreach (up_wr_words[i]) if (dword(up_wr_words[i]) !== xword(up_wr_words[i])) c_rrel_words++;
					if (is_dpc) rrel_sync_q = 1'b1;
				end
				foreach (touched[i]) cmp_word(touched[i], cur_q26 || cyc_rrel, cur_q26 ? "q26" : "written");
				foreach (up_wr_words[i]) begin
					if (!cyc_commit && dword(up_wr_words[i]) !== xword(up_wr_words[i])) c_noacc++;
					cmp_word(up_wr_words[i], !cyc_commit || cyc_rrel, "upstream strobe");
				end
				if (wbq_v != 0) begin n_misc++; fail("misc", "writeback still due at E0", 1, 0); end
				if (cur_q26) c_q26_rep += repair_words.size();
				touched.delete();
				up_wr_words.delete();
				if (cyc_n % 2048 == 2047) begin
					v_full++;
					for (int w = 0; w < 8192; w++) begin
						bit q;
						q = 1'b0;
						foreach (repair_words[i]) if (repair_words[i] == w) q = 1'b1;   // repaired at the negedge
						if (!q) cmp_word(w, 1'b0, "full");
					end
				end
				cyc_n++;
				ep_cyc++;
				if (is_dpc) v_sch[revision[0]]++;
				else if (is_cdf) v_sch[2 + revision[1:0]]++;
				if (is_cdf && jplus && (ldx || ldy)) v_ldxy++;
				if (is_cdf && foff_en) v_foff++;
				if (len1 > 6) v_stretch++;
				cyc_short  = 1'b0;
				cyc_commit = 1'b0;
				cur_q26    = 1'b0;
				cur_alias  = 1'b0;
				cur_dalias = 1'b0;
				cyc_rst    = 1'b0;
				cyc_rrel   = 1'b0;
			end
			if (cart_reset || !(is_dpc | is_cdf) || scheme != scheme_q) cyc_rst = 1'b1;
		end

		// ---------------- bookkeeping for the next clock ----------------
		prev_dma  = dma_set;
		prev_call = callfn;
		sp_prev   = up_dpc.service_pending;
		svc_prev  = svc_pend;
		rst_prev  = rst_fe;
		rst_sch   = scheme;
		rst_rev   = revision;
		ti_prev   = cdf_ti;
		if (pclk1) e0n = 0;
		else if (e0n < 15) e0n++;
		if (rst_fe) t_rst_edge = clk_n;      // rcyc's model: the edges at this posedge
		if (pclk1)  t_pclk1_edge = clk_n;
		if (!checking) drop_chk = 1'b0;
		if (!checking) begin aud_cap = 1'b0; hold_on = 1'b0; end
		if (pclk1 && pg_run && checking && !load) v_held_cyc++;
		if (pclk1 && pg_run) begin
			if (len1 == 2) v_l1_2++;
			if (len1 == 4) v_l1_4++;
		end

		// ---------------- upstream's cart RAM (cart_ram_tdp port A) ----------------
		begin
			logic [31:0] wd;
			// the writeback lands between C+1 and C+2 (CDF §14.3): before this edge's read
			if (wbq_v != 0) begin
				for (int b = 0; b < 4; b++) xram[4*wbq_w + b] = wbq_d[8*b +: 8];
				if (checking) begin
					bit seen;
					seen = 1'b0;
					foreach (touched[i]) if (touched[i] == wbq_w) seen = 1'b1;
					if (!seen) touched.push_back(wbq_w);
				end
				wbq_v = 0;
			end
			if (cdf_pu && is_cdf) begin
				wbq_v = 1;
				wbq_w = int'(pb_now()) + int'(cdf_pu_idx);
				wbq_d = cdf_pu_val;
			end
			if (!pause && cr_wr) begin
				xram[cr_addr] = d_in;
				if (checking) up_wr_words.push_back(int'(cr_addr[14:2]));
			end
			wd = xword(int'(cr_addr[14:2]));
			up_word <= wd;
			if (!pause) up_lane <= cr_addr[1:0];
		end
	end

	// +trace_from=N +trace_to=M: one line per clock (debug)
	longint tr_from = -1, tr_to = -1;
	initial begin
		void'($value$plusargs("trace_from=%d", tr_from));
		void'($value$plusargs("trace_to=%d", tr_to));
	end
	always @(posedge clk) if (clk_n >= tr_from && clk_n <= tr_to)
		$display("T %0d p1 %b p0 %b acc %b k %b a %h rw %b d %h romb %h/%h sel %b/%b fix %b %h op.c %b opc.c %b W %h crb_a %h we %b crb_q %h up_ti %h tab_ptr %h cdf_ra %h upw %h fe_do %h up_byte %h fpend %b/%b fexp %h/%h wb %b rdW %b | aud %b/%b p32 %b/%b q %b got %b rdP %b pend_c %0d stall %b held %b",
			clk_n + 1, pclk1, pclk0, access, k, a_in, rw, d_in, u_core.romb, up_rom_q, sel_up, up_sel, cr_fix, cr_fix_a,
			op.c, u_core.opc.c, u_core.W, crb_addr, crb_we, crb_q, cdf_ti, tab_ptr, cdf_ram_addr, up_word, fe_do, up_byte,
			u_core.fpend, up_cdf.fast_pending, u_core.fexp, up_cdf.fast_expected_address, wb_v, u_core.rdW,
			aud_issue, aud_take, cr_p32, p32_gnt, p32_q, u_core.p32_got, rdP, u_core.pend_c, stall_eff, held);

	// repairs of classified differences, at the negedge after the cycle's end
	always @(negedge clk) begin
		if (repair_q) begin
			foreach (repair_words[i]) u_mem.cart_ram.mem_q[repair_words[i]] = xword(repair_words[i]);
			repair_words.delete();
			repair_q = 1'b0;
		end
		if (tab_sync_q) begin
			for (int i = 0; i < 64; i++) begin
				up_tab.pointer_ram.mem_q[i]   = xword(int'(pb_now()) + i);
				up_tab.increment_ram.mem_q[i] = xword(int'(ib_now()) + i);
			end
			tab_sync_q = 1'b0;
		end
		// after a DPC+ release cycle: upstream's fetchers and parameters into the state RAM
		// (the fields cmp_state compares; the other bits stay)
		if (rrel_sync_q) begin
			for (int i = 0; i < 8; i++) begin
				logic [31:0] w0, w1;
				w0 = u_mem.state_ram.mem_q[2*i];
				w1 = u_mem.state_ram.mem_q[2*i+1];
				w0[11:0]  = up_dpc.counter[i];
				w0[23:16] = up_dpc.top[i];
				w0[31:24] = up_dpc.bottom[i];
				w1[19:0]  = up_dpc.fractional[i];
				w1[31:24] = up_dpc.increment[i];
				u_mem.state_ram.mem_q[2*i]   = w0;
				u_mem.state_ram.mem_q[2*i+1] = w1;
			end
			for (int b = 0; b < 4; b++) u_mem.state_ram.mem_q[16][8*b +: 8] = up_dpc.params[b];
			rrel_sync_q = 1'b0;
		end
	end

	// ======================================================================================
	// epochs
	// ======================================================================================
	task automatic gen_image();
		int i;
		logic [5:0] amp_s;
		logic [11:0] base;
		amp_s = revision[1] ? 6'd35 : 6'd34;
		i = 0;
		while (i < 32768) begin
			int r;
			r = int'(rnd(1000));
			if (r < 200) begin                            // CDF LDA #: an operand in range
				img[i] = 8'hA9;
				img[(i + 1) & 32767] = (foff_en ? foff : 8'h00) + 8'(rnd(36));
				i += 2;
			end else if (r < 300) begin                   // DPC+ LDA #: a register number (or not)
				img[i] = 8'hA9;
				img[(i + 1) & 32767] = (rnd(10) < 8) ? 8'(rnd(42)) : rnd8();   // $00-$29: the $28 edge too
				i += 2;
			end else if (r < 340) begin                   // CDFJ+ LDX #/LDY #
				img[i] = (rnd(2) == 0) ? 8'hA2 : 8'hA0;
				img[(i + 1) & 32767] = (foff_en ? foff : 8'h00) + 8'(rnd(36));
				i += 2;
			end else if (r < 420) begin                   // JMP: operand 1 0/1/other, operand 2 0/other
				int q;
				img[i] = 8'h4C;
				q = int'(rnd(10));
				img[(i + 1) & 32767] = (q < 5) ? 8'h00 : (q < 8) ? 8'h01 : rnd8();
				img[(i + 2) & 32767] = (rnd(10) < 8) ? 8'h00 : rnd8();
				i += 3;
			end else begin
				img[i] = rnd8();
				i += 1;
			end
		end
		// arming opcodes right before the hotspots ($xFF3-$xFFA): the operand is then
		// read at a hotspot address (a substituted read does not switch, Q9, DPC §14.13)
		for (int lay = 0; lay < 3; lay++) begin
			base = (lay == 0) ? 12'hC00 : ((lay == 1) ? 12'h000 : 12'h800);
			for (int b = 0; b < 8; b++) begin
				int p;
				int q;
				arm_off[lay][b] = 12'hFF3 + 12'(rnd(8));
				p = (int'(base) + b * 4096 + int'(arm_off[lay][b])) & 32767;
				img[p] = (rnd(4) == 0) ? 8'hA2 : 8'hA9;
				q = int'(rnd(4));
				img[(p + 1) & 32767] = (q == 0) ? (8'h27 + 8'(rnd(2))) : (q == 1) ? 8'(rnd(42))
				                     : ((foff_en ? foff : 8'h00) + 8'(rnd(36)));
			end
		end
		// $4C at bank ends ($xFFD-$xFFF of every 4 KB window of every layout)
		for (int lay = 0; lay < 3; lay++) begin
			base = (lay == 0) ? 12'hC00 : ((lay == 1) ? 12'h000 : 12'h800);
			for (int b = 0; b < 8; b++) begin
				int p;
				if (rnd(2) == 0) continue;
				p = (int'(base) + b * 4096 + 'hFFD + int'(rnd(3))) & 32767;
				img[p] = 8'h4C;
				img[(p + 1) & 32767] = (rnd(4) == 0) ? 8'h01 : 8'h00;
				img[(p + 2) & 32767] = 8'h00;
			end
		end
	endtask

	task automatic load_memories(input bit new_image);
		// DARIA: the FE ROM (the capture), cart RAM and state RAM $00-$1F (F6)
		if (new_image)
			for (int w = 0; w < 8192; w++)
				u_mem.fe_rom.mem_q[w] = {img[4*w+3], img[4*w+2], img[4*w+1], img[4*w]};
		for (int b = 0; b < 32768; b++) xram[b] = ram0[b];
		for (int w = 0; w < 8192; w++) u_mem.cart_ram.mem_q[w] = xword(w);
		for (int w = 0; w < 32; w++) u_mem.state_ram.mem_q[w] = 32'd0;
		// upstream: the stream tables from RAM (arm_mapper_ram_init)
		for (int i = 0; i < 64; i++) begin
			up_tab.pointer_ram.mem_q[i]   = xword(int'(pb_now()) + i);
			up_tab.increment_ram.mem_q[i] = xword(int'(ib_now()) + i);
		end
	endtask

	task automatic build_map();
		// the image through cdf_fastjump_table's load port, a byte per clock
		@(negedge clk);
		fj_ls = 1'b1; fj_lv = 1'b1; fj_la = 25'd0; fj_ld = img[0];
		for (int i = 1; i < 32768; i++) begin
			@(negedge clk);
			fj_ls = 1'b0; fj_la = 25'(i); fj_ld = img[i];
		end
		@(negedge clk);
		fj_lv = 1'b0;
		@(negedge clk);
		// 5: the map against the formula, every address
		for (int a = 0; a < 32768; a++) begin
			logic exp;
			exp = (a < 32766) && img[a] == 8'h4C && img[a + 1][7:1] == 7'd0 && img[a + 2] == 8'h00;
			if (up_fj.map_ram.mem_q[a] !== exp) begin n_jmap++; fail("jok", $sformatf("map[%h]", a), up_fj.map_ram.mem_q[a], exp); end
		end
	endtask

	// "all" and "cdf" rotate through fixed configurations (seed-offset), so that any 10
	// (all) or 8 (cdf) consecutive epochs cover every scheme, revision and the offset;
	// a named scheme takes the offset at random.
	task automatic pick_scheme();
		int r;
		string o;
		int off;
		o = (rrel_mode == 1) ? "dpc" : ((rrel_mode == 2) ? "cdf" : only);
		off = -1;
		r = (epoch + seed) % 10;
		if (o == "all") begin
			case (r)
				0: begin o = "dpc0";  off = 0; end
				1: begin o = "cdf0";  off = 1; end
				2: begin o = "cdf1";  off = 0; end
				3: begin o = "dpc1";  off = 0; end
				4: begin o = "cdfj";  off = 1; end
				5: begin o = "cdfjp"; off = 0; end
				6: begin o = "cdf0";  off = 0; end
				7: begin o = "cdf1";  off = 1; end
				8: begin o = "cdfj";  off = 0; end
				default: begin o = "cdfjp"; off = 1; end
			endcase
		end else if (o == "cdf") begin
			r = r % 8;
			o = (r % 4 == 0) ? "cdf0" : (r % 4 == 1) ? "cdf1" : (r % 4 == 2) ? "cdfj" : "cdfjp";
			off = r / 4;
		end
		case (o)
			"dpc":   begin scheme = SCHEME_DPCP; revision = 3'(rnd(4)); end
			"dpc0":  begin scheme = SCHEME_DPCP; revision = {2'(rnd(4)), 1'b0}; end
			"dpc1":  begin scheme = SCHEME_DPCP; revision = {2'(rnd(4)), 1'b1}; end
			"cdf0":  begin scheme = SCHEME_CDF;  revision = 3'd0; end
			"cdf1":  begin scheme = SCHEME_CDF;  revision = 3'd1; end
			"cdfj":  begin scheme = SCHEME_CDF;  revision = 3'd2; end
			"cdfjp": begin scheme = SCHEME_CDF;  revision = 3'd3; end
			default: $fatal(1, "tb_fe_core: +only=%s is not all, dpc, cdf, cdf0, cdf1, cdfj or cdfjp", only);
		endcase
		ldx     = rnd(4) != 0;
		ldy     = rnd(4) != 0;
		foff_en = (off < 0) ? (rnd(10) < 4) : (off == 1);
		foff    = (rnd(4) == 0) ? rnd8() : 8'(rnd(200));
	endtask

	task automatic run_cycles(input longint n);
		longint target;
		target = ep_cyc + n;
		while (ep_cyc < target) @(posedge clk);
	endtask

	// A console reset released inside a cycle that commits a post action whose data needs
	// a read (E3_rtl_issues.md issue 1; lanes/F1_fixes.md 1). cart_reset rises at a k[2] with
	// driver_run 0 (as event 0), the stream turns to post-action registers, driver_run comes
	// back at a k[2], and cart_reset falls in the pclk0 clock of such a cycle at E0+5 or
	// later: its k[1]-k[4] reads ran under rst_fe, so the commit at C sets an action whose
	// ready flag stays 0. Upstream (out of reset at C) does the access. The cycle's latch
	// and words are classified (rrel), the DPC+ fetchers resynced from upstream at the next
	// negedge; a_pend_late must stay 0 (rcyc) and nothing may fire in a later cycle.
	task automatic rrel_event();
		int n;
		@(negedge clk);
		while (!k[2]) @(negedge clk);
		driver_run = 1'b0;
		cart_reset = 1'b1;
		rrel_bias  = 1'b1;
		repeat (10 + rnd(40)) @(negedge clk);
		load_memories(1'b0);
		repeat (2) @(negedge clk);
		while (!k[2]) @(negedge clk);
		driver_run = 1'b1;
		n = 0;
		forever begin
			@(negedge clk);
			if (pclk0 && access && a_in[12] && e0n >= 5 &&
			    (is_dpc ? (u_core.opc.c.rdat | u_core.opc.c.dpw) : (u_core.opc.c.cdsw | u_core.opc.c.cdsp))) break;
			n++;
			if (n > 20000) $fatal(1, "tb_fe_core: no post-action cycle to release in");
		end
		cart_reset = 1'b0;
		rrel_bias  = 1'b0;
		cyc_rrel   = 1'b1;
		cls_clk    = clk_n;
		c_rrel++;
		if (u_core.opc.c.rdat) v_rrel_k[0]++;
		if (u_core.opc.c.dpw)  v_rrel_k[1]++;
		if (u_core.opc.c.cdsw) v_rrel_k[2]++;
		if (u_core.opc.c.cdsp) v_rrel_k[3]++;
		if (rrel_log) $display("rrel: release at clk %0d, a_in %h rw %b e0n %0d", clk_n, a_in, rw, e0n);
		fresh = 2;
	endtask

	// one epoch: reset, a new image and RAM, run, events
	task automatic run_epoch(input longint n);
		longint done, ev_at, ev_len;
		int ev;
		epoch++;
		checking = 1'b0;
		pg_run   = 1'b0;
		@(negedge clk);
		cart_reset = 1'b1;
		pick_scheme();
		gen_image();
		for (int b = 0; b < 32768; b++) ram0[b] = rnd8();
		load_memories(1'b1);
		build_map();
		repeat (4) @(negedge clk);
		cart_reset = 1'b0;
		driver_run = 1'b1;
		fresh = 2;
		pc = {1'b1, 12'(rnd(4096))};
		@(negedge clk);
		pg_run = 1'b1;
		@(negedge clk);
		while (!pclk1) @(negedge clk);
		@(negedge clk);                              // k[0] of the first cycle
		cyc_short = 1'b0; cyc_commit = 1'b0; cur_q26 = 1'b0; cur_alias = 1'b0; cur_dalias = 1'b0;
		cyc_rst = 1'b0; touched.delete(); up_wr_words.delete(); wb_pending = 1'b0;
		checking = 1'b1;
		ep_cyc = 0;
		// events: one of reset, switch, 7800 mode, non-ARM scheme, somewhere in the epoch;
		// a release epoch runs only its releases
		ev = (rrel_mode != 0) ? 5 : (events ? ((epoch + seed) % 5) : 4);
		ev_at = longint'(rnd(32'(n / 2))) + n / 4;
		ev_len = 20 + longint'(rnd(200));
		run_cycles(ev_at);
		case (ev)
			0: begin                                     // a console reset (F6 emulated)
				@(negedge clk);
				while (!k[2]) @(negedge clk);
				driver_run = 1'b0;
				cart_reset = 1'b1;
				c_reset++;
				repeat (10 + rnd(40)) @(negedge clk);
				load_memories(1'b0);
				repeat (2) @(negedge clk);
				cart_reset = 1'b0;
				fresh = 2;
				run_cycles(4);
				@(negedge clk);
				while (!k[2]) @(negedge clk);
				driver_run = 1'b1;
			end
			1: begin                                     // a live switch in the pclk1 clock (rst_fe ends at E0)
				@(negedge clk);
				while (!pclk1) @(negedge clk);
				scheme = is_dpc ? SCHEME_CDF : SCHEME_DPCP;
				c_switch++;
				fresh = 2;
			end
			2: begin                                     // 7800 mode: driver_run 0
				@(negedge clk);
				while (!k[2]) @(negedge clk);
				driver_run = 1'b0;
				c_7800++;
				run_cycles(ev_len);
				@(negedge clk);
				while (!k[2]) @(negedge clk);
				driver_run = 1'b1;
			end
			5: begin                                     // releases inside a post-action cycle
				for (int i = 0; i < n_rrel; i++) begin
					rrel_event();
					run_cycles(200 + longint'(rnd(400)));
				end
			end
			3: begin                                     // a non-ARM scheme (CDF only: DPC+ fetchers would be live_override)
				if (is_cdf) begin
					@(negedge clk);
					while (!pclk1) @(negedge clk);
					scheme = 6'd0;
					c_other++;
					run_cycles(ev_len);
					@(negedge clk);
					while (!pclk1) @(negedge clk);
					scheme = SCHEME_CDF;
					fresh = 2;
				end
			end
			default: ;
		endcase
		done = ep_cyc;
		if (done < n) run_cycles(n - done);
		// the epoch's end: the last cycle's pclk1 checks run (and queue their repairs),
		// the bus stops in k[0] of the next cycle, then every word
		@(negedge clk);
		while (!pclk1) @(negedge clk);
		@(negedge clk);
		checking = 1'b0;
		pg_run   = 1'b0;
		repeat (16) @(negedge clk);
		for (int w = 0; w < 8192; w++)
			if (dword(w) !== xword(w)) begin n_ram++; fail("ram", $sformatf("epoch end word %h", w), dword(w), xword(w)); end
	endtask

	// ======================================================================================
	// main
	// ======================================================================================
	initial begin
		longint left;
		void'($value$plusargs("seed=%d", seed));
		void'($value$plusargs("cycles=%d", n_cycles));
		void'($value$plusargs("epoch=%d", epoch_len));
		void'($value$plusargs("only=%s", only));
		void'($value$plusargs("stop=%d", stop_n));
		void'($value$plusargs("events=%d", events));
		void'($value$plusargs("formula=%d", formula));
		void'($value$plusargs("rrel=%d", n_rrel));
		void'($value$plusargs("rrel_len=%d", rrel_len));
		void'($value$plusargs("rrel_log=%d", rrel_log));
		rs = 32'h9E37_79B9 ^ (32'(seed) * 32'h85EB_CA6B);
		if (rs == 0) rs = 32'd1;
		for (int i = 0; i < 16; i++) v_cls[i] = 0;
		for (int i = 0; i < 6; i++) v_sch[i] = 0;
		$display("tb_fe_core: seed %0d, %0d cycles, epochs of %0d, only %s, events %0d", seed, n_cycles, epoch_len, only, events);
		repeat (8) @(negedge clk);
		left = n_cycles;
		while (left > 0) begin
			longint n;
			n = (left < epoch_len) ? left : epoch_len;
			run_epoch(n);
			left -= n;
		end
		// after the rotation (so its streams are unchanged): one DPC+ and one CDF release epoch
		if (n_rrel > 0) begin
			rrel_mode = 1; run_epoch(rrel_len);
			rrel_mode = 2; run_epoch(rrel_len);
			rrel_mode = 0;
		end
		report();
	end

	// the counts (rst events) beside the epoch tasks
	always @(posedge clk) if (checking && rst_fe) begin
		if (cart_reset) v_rst_cr++;
		else if (!(is_dpc | is_cdf)) v_rst_oth++;
		else v_rst_sw++;
	end

	task automatic report();
		longint feat;
		$display("tb_fe_core: %0d epochs, %0d cycles: DPC+ sf0 %0d, sf1 %0d; CDF0 %0d, CDF1 %0d, CDFJ %0d, CDFJ+ %0d (LDX/LDY %0d, offset %0d)",
			epoch, cyc_n, v_sch[0], v_sch[1], v_sch[2], v_sch[3], v_sch[4], v_sch[5], v_ldxy, v_foff);
		$display("  bus: %0d commits (%0d reads, %0d writes), %0d held cycles (%0d commits in them), %0d latches (%0d hidden), %0d pause clocks, %0d stretched, phase 1 of 2: %0d, of 4: %0d",
			v_commit, v_rd, v_wr, v_held_cyc, v_held, v_latch, v_hidden, v_pause, v_stretch, v_l1_2, v_l1_4);
		$display("  ops: rom %0d rrnd %0d amp %0d rdat %0d rflg %0d dfld %0d dpw %0d dpar %0d dcf %0d dmisc %0d cfet %0d cjmp %0d cdsw %0d cdsp %0d cmode %0d ccall %0d; hot %0d; substituted reads at a hotspot address %0d; jump operands at $xFFE/F %0d, jok at $xFFD-F %0d",
			v_cls[15], v_cls[14], v_cls[13], v_cls[12], v_cls[11], v_cls[10], v_cls[9], v_cls[8], v_cls[7], v_cls[6],
			v_cls[5], v_cls[4], v_cls[3], v_cls[2], v_cls[1], v_cls[0], v_hot, v_sub_hot, v_cjmp_end, v_jok_end);
		$display("  paths: audio grants %0d; pointer writes %0d (C+1 %0d, C+2 %0d, short %0d); jok k[1] %0d (set %0d); services %0d (deferred %0d), DSW/DSP deferred %0d, P32 in k[2] %0d; notes %0d; digital %0d; full RAM compares %0d",
			v_aud, v_wbn, v_land1, v_land2, v_land_s, v_jokk, v_jok1, v_svc, v_svc_def, v_dsw_def, v_p32_k2, v_note, v_dig, v_full);
		$display("  rst_fe clocks: console reset %0d, scheme switch %0d, non-ARM %0d; reset-value checks %0d; events: reset %0d, switch %0d, 7800 %0d, non-ARM %0d; state compares skipped (reset in the cycle) %0d",
			v_rst_cr, v_rst_sw, v_rst_oth, n_rst, c_reset, c_switch, c_7800, c_other, c_rst_skip);
		$display("  classified: short_phase1 cycles %0d (dout %0d, grant_steal %0d, audio %0d), q26 %0d (words repaired %0d), tbl_alias %0d, ram_wr_noaccess %0d; a_p32_late's formula under a reset %0d",
			c_short, c_dout_short, c_steal, c_aud_cls, c_q26, c_q26_rep, c_alias, c_noacc, c_p32_rst);
		$display("  releases inside a post-action cycle (rrel) %0d (DFx reads %0d, PUSH/WRITE %0d, DSWRITE %0d, DSPTR %0d): pclk1s with rcyc whose pending actions were dropped there %0d, still pending after it %0d; latches classified %0d, words repaired %0d",
			c_rrel, v_rrel_k[0], v_rrel_k[1], v_rrel_k[2], v_rrel_k[3], v_rrel_drop, v_rrel_kept, c_rrel_dout, c_rrel_words);
		$display("  state compares %0d", v_cmp_state);
		$display("  bad: hold %0d a2 %0d grant %0d dout %0d dout_hidden %0d state %0d ram %0d land %0d aud %0d jok %0d jmap %0d fix %0d assert %0d rcyc %0d svc %0d dma %0d call %0d note %0d wave %0d dig %0d src %0d alias %0d misc %0d (total %0d)",
			n_hold, n_a2, n_grant, n_dout, n_dout_hidden, n_state, n_ram, n_land, n_aud, n_jok, n_jmap, n_fix, n_assert, n_rcyc, n_svc, n_dma,
			n_call, n_note, n_wave, n_dig, n_src, n_alias_bad, n_misc, bad);
		// coverage minimums, scaled to the run
		feat = 1;
		if (v_commit < cyc_n / 2 || v_latch < cyc_n / 2) feat = 0;
		if (n_cycles >= 100000) begin
			if (v_sch[0] + v_sch[1] > 0 && (v_cls[12] < 100 || v_cls[9] < 50 || v_cls[10] < 100 || v_cls[11] < 20 || v_cls[14] < 50 || v_cls[13] < 10)) feat = 0;
			if (v_sch[2] + v_sch[3] + v_sch[4] + v_sch[5] > 0 && (v_cls[5] < 100 || v_cls[4] < 20 || v_cls[3] < 50 || v_cls[2] < 50 || v_aud < 1000 || v_jok1 < 10)) feat = 0;
			if (pg.k_busy > 0 && (v_held_cyc < 100 || v_hidden < 100)) feat = 0;   // no stalls in "nominal"
		end
		if (n_rrel > 0 && (c_rrel != 2 * n_rrel || v_rrel_drop != c_rrel || v_rrel_kept != 0)) feat = 0;  // every release strands its action, dropped at pclk1
		if (feat == 0) $display("tb_fe_core: a coverage minimum was not met");
		if (bad != 0 || feat == 0) $fatal(1, "tb_fe_core: FAIL (%0d bad)", bad);
		$display("tb_fe_core: PASS");
		$finish;
	endtask
endmodule

`default_nettype wire
