//------------------------------------------------------------------------------
// fe_rand_up: upstream's DPC+/CDF front-end cluster for the random
// differential bench (tb_fe_rand.sv; docs/daria_fe/design.md 12.1), wired as
// cart2600.sv and top.sv wire it (src/fpga/mister/rtl, MIT; read, not
// changed):
//
//   mapper_dpcplus, mapper_cdf          reset = reset || mapper != X; access =
//                                       phi2 && arm_driver_run (cart2600.sv:247)
//   arm_mapper_tables                   family CDF 2; lookups from table_index;
//                                       sys writes from init and pointer_update;
//                                       clk_arm writes from the ARM port
//   arm_mapper_ram_init                 load_end_d (load_end + 1, cleared by
//                                       load_start); the DMA through the mux
//   arm_mapper_writeback                pointer writes to the ARM port, priority
//   cdf_fastjump_table                  the load stream; query rom_a[14:0]
//   arm_mapper_audio                    family = init_family; grant
//   cart_ram_tdp                        top.sv:918-936: mapper_en = init_busy ?
//                                       (wr | rd) : !pause; $FF on pause
//   the port-A mux and the strobes      cart2600.sv:965-978, top.sv:752-757 (the
//                                       2600 path only); access_taken,
//                                       address_change (cart2600.sv:241-265)
//   the d_out / oe mux                  cart2600.sv:211-233 (DPC+ and CDF only)
//   tb_daria's ROM                      rom_do <= rom[rom_a] every clk_sys
//
// Beside them, three models of what arm_mapper_subsystem holds:
//
//   the controller   arm_mapper_controller.sv, both halves, statement for
//                    statement (without arm7tdmi_pkg: state_index/state_wdata
//                    and the WRITE_STATE data are not modelled, nothing reads
//                    them). The CPU is the bench's agent: cpu_halted,
//                    return_fetch, state_ready, state_rdata.
//   the memory       arm_mapper_memory.sv's clk_sys halves of the DMA and
//                    sample ports exactly; its clk_arm DMA and sample state
//                    machines exactly; the DDR3 channel as one server with a
//                    random latency per access (+ddr_lat_min/max, +ddr_long);
//                    the load path as shadow_ready (cleared at load_start,
//                    set after load_end) and an instant DDR image; the CPU's
//                    cart RAM port as the agent's cpu_* (one word, held until
//                    accepted, below the DMA: ram_phase = ram_target &&
//                    !dma_ram_en).
//   the subsystem    mapper_reset_arm: two clk_arm flops of the console reset.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module fe_rand_up (
	input  wire         clk_sys,
	input  wire         clk_arm,
	input  wire         reset_arm,          // tb_daria's arm_reset (power-up)
	input  wire         reset,              // effective_reset
	input  wire         pause,              // pause_core
	input  wire   [5:0] mapper,             // force_bs
	input  wire   [2:0] mapper_revision,
	input  wire         cdf_ldx,
	input  wire         cdf_ldy,
	input  wire         cdf_fetch_offset_enable,
	input  wire   [7:0] cdf_fetch_offset,
	input  wire  [31:0] cdfj_entry,
	input  wire  [31:0] cdfj_stack,
	input  wire  [15:0] arm_audio_size_addr,
	input  wire  [31:0] rom_size,           // cart_size
	input  wire  [12:0] a_in,
	input  wire   [7:0] d_in,               // write_DB: equal to cart2600's d_in on writes,
	                                        // and no read path reads it
	input  wire         rw,
	input  wire         phi1,               // pclk1
	input  wire         phi2,               // mapper_phi2
	input  wire         arm_driver_run,     // lock_ctrl && tia_en
	input  wire         tia_en,             // top.sv:752-757: the 2600 path owns the cart RAM port
	input  wire         load_start,
	input  wire  [24:0] load_addr,
	input  wire         load_valid,
	input  wire   [7:0] load_data,
	input  wire         load_end,
	// the CPU, played by the bench's agent (clk_arm)
	input  wire         cpu_halted,
	input  wire         return_fetch,
	input  wire         state_ready,
	input  wire  [31:0] state_rdata,
	input  wire         cpu_en,
	input  wire         cpu_write,
	input  wire  [14:0] cpu_addr,
	input  wire  [31:0] cpu_wdata,
	input  wire   [3:0] cpu_wstrb,
	output logic        cpu_accepted,
	output logic        halt_req,
	// the DDR model's random stream (an offset on +seed)
	input  wire  [31:0] lat_ofs,
	// to the 6507 and the stall
	output logic  [7:0] d_out,
	output logic  [7:0] oe,
	output logic        arm_call_busy,
	output logic        arm_dma_busy,
	output logic        mapper_init_busy,
	output logic [15:0] mapper_ram_size
);
	localparam logic [5:0] BANKDPCP = 6'd21;
	localparam logic [5:0] BANKCDF  = 6'd23;
	wire is_dpc = mapper == BANKDPCP;
	wire is_cdf = mapper == BANKCDF;

	// top.sv:778-783
	always_comb mapper_ram_size = (is_cdf && mapper_revision == 3'd3) ? 16'd32768 : 16'd8192;

	// ---- tb_daria's ROM and the DDR3 image (one array; the load stream fills both) ----
	logic [7:0] rom [0:65535];
	initial for (int i = 0; i < 65536; i++) rom[i] = 8'h00;
	always @(posedge clk_sys)
		if (load_valid && load_addr < 25'd65536) rom[load_addr[15:0]] <= load_data;
	function automatic logic [63:0] ddr_word(input logic [24:0] a);    // the 8-byte word holding a
		logic [63:0] w;
		for (int b = 0; b < 8; b++) w[8 * b +: 8] = rom[{a[15:3], 3'(b)}];
		return w;
	endfunction
	function automatic logic [7:0] get_byte(input logic [63:0] w, input logic [2:0] i);
		return w[8 * i +: 8];
	endfunction

	// ---- cart2600: access, access_taken, address_change, load_end_d -------------------------
	wire        arm_access = phi2 && arm_driver_run;
	logic [12:0] old_ain = 13'd0;
	wire        address_change = old_ain != a_in;
	logic       access_taken = 1'b0;
	always @(posedge clk_sys) begin
		if (reset || address_change || phi1) access_taken <= 1'b0;
		else if (phi2) access_taken <= 1'b1;
		old_ain <= a_in;
	end
	logic       load_end_d = 1'b0;
	always_ff @(posedge clk_sys) load_end_d <= load_start ? 1'b0 : load_end;

	// ---- the mappers ---------------------------------------------------------------------------
	logic  [7:0] rom_do = 8'h00;
	logic  [7:0] cartram_data;
	logic [31:0] cartram_word_data;
	logic  [7:0] arm_audio_amplitude;
	logic        mapper_call_ready;

	logic  [7:0] dpc_do, dpc_oe;
	logic [15:0] dpc_flags;
	logic [18:0] dpc_rom_a;
	logic        dpc_ram_sel, dpc_ram_rw;
	logic [17:0] dpc_ram_a;
	logic  [6:0] dpc_audio_waveform0, dpc_audio_waveform1, dpc_audio_waveform2;
	logic        dpc_audio_note_write;
	logic  [1:0] dpc_audio_note_voice;
	logic  [7:0] dpc_audio_note_value;
	logic        dpc_call_request, dpc_call_thumb;
	logic [31:0] dpc_call_entry, dpc_call_stack;
	logic        dpc_service_request_raw, dpc_service_fill;
	logic [18:0] dpc_service_source;
	logic [14:0] dpc_service_dest;
	logic  [7:0] dpc_service_count, dpc_service_value;
	logic        dpc_service_ready;
	mapper_dpcplus dpcplus (
		.clk(clk_sys), .reset(reset || mapper != BANKDPCP), .access(arm_access), .rw, .a_in, .d_in,
		.rom_data(rom_do), .stable_fractional(mapper_revision[0]),
		.d_out(dpc_do), .flags_out(dpc_flags), .oe(dpc_oe), .rom_a(dpc_rom_a),
		.ram_sel(dpc_ram_sel), .ram_rw(dpc_ram_rw), .ram_a(dpc_ram_a), .ram_data(cartram_data),
		.amplitude(arm_audio_amplitude),
		.audio_waveform0(dpc_audio_waveform0), .audio_waveform1(dpc_audio_waveform1),
		.audio_waveform2(dpc_audio_waveform2), .audio_note_write(dpc_audio_note_write),
		.audio_note_voice(dpc_audio_note_voice), .audio_note_value(dpc_audio_note_value),
		.call_request(dpc_call_request), .call_entry(dpc_call_entry), .call_stack(dpc_call_stack),
		.call_thumb(dpc_call_thumb), .call_ready(mapper_call_ready),
		.service_request(dpc_service_request_raw), .service_fill(dpc_service_fill),
		.service_source(dpc_service_source), .service_dest(dpc_service_dest),
		.service_count(dpc_service_count), .service_value(dpc_service_value),
		.service_ready(dpc_service_ready));

	logic  [7:0] cdf_do, cdf_oe;
	logic [15:0] cdf_flags;
	logic [18:0] cdf_rom_a;
	logic  [5:0] cdf_table_index;
	logic [31:0] table_pointer, table_increment;
	logic        cdf_pointer_update;
	logic  [5:0] cdf_pointer_update_index;
	logic [31:0] cdf_pointer_update_value;
	logic        cdf_ram_en, cdf_ram_write;
	logic [14:0] cdf_ram_addr;
	logic        cdf_digital_audio;
	logic        cdf_call_request, cdf_call_thumb;
	logic [31:0] cdf_call_entry, cdf_call_stack;
	logic        fast_jump_valid;
	mapper_cdf cdf (
		.clk(clk_sys), .reset(reset || mapper != BANKCDF), .access(arm_access), .rw, .a_in, .d_in,
		.rom_data(rom_do), .revision(mapper_revision[1:0]), .enable_ldx(cdf_ldx), .enable_ldy(cdf_ldy),
		.fetch_offset_enable(cdf_fetch_offset_enable), .fetch_offset(cdf_fetch_offset),
		.fast_jump_valid(fast_jump_valid),
		.d_out(cdf_do), .flags_out(cdf_flags), .oe(cdf_oe), .rom_a(cdf_rom_a),
		.table_index(cdf_table_index), .table_pointer(table_pointer), .table_increment(table_increment[15:0]),
		.pointer_update(cdf_pointer_update), .pointer_update_index(cdf_pointer_update_index),
		.pointer_update_value(cdf_pointer_update_value),
		.ram_en(cdf_ram_en), .ram_write(cdf_ram_write), .ram_addr(cdf_ram_addr), .ram_wdata(),
		.ram_rdata(cartram_data), .amplitude(arm_audio_amplitude), .digital_audio(cdf_digital_audio),
		.call_request(cdf_call_request), .call_entry(cdf_call_entry), .call_stack(cdf_call_stack),
		.call_thumb(cdf_call_thumb), .call_ready(mapper_call_ready),
		.cdfj_entry, .cdfj_stack);

	// the selected mapper (cart2600.sv:184-191; mapper 0 here is "no ARM scheme")
	wire  [7:0] sel_direct_do = is_dpc ? dpc_do : cdf_do;
	wire [15:0] sel_flags_out = is_dpc ? dpc_flags : (is_cdf ? cdf_flags : 16'd0);
	wire  [7:0] sel_out_en    = is_dpc ? dpc_oe : (is_cdf ? cdf_oe : 8'd0);
	wire        sel_ram_rw    = is_dpc ? dpc_ram_rw : (is_cdf ? !cdf_ram_write : 1'b1);
	wire        sel_ram_sel   = is_dpc ? dpc_ram_sel : (is_cdf ? cdf_ram_en : 1'b0);
	wire [17:0] sel_ram_a     = is_dpc ? dpc_ram_a : (is_cdf ? {3'b0, cdf_ram_addr} : 18'd0);
	wire [18:0] rom_a         = is_dpc ? dpc_rom_a : (is_cdf ? cdf_rom_a : 19'd0);
	always @(posedge clk_sys) rom_do <= rom[rom_a[15:0]];
	wire  [7:0] cr_do = cartram_data;
	always_comb begin
		d_out = 8'h00;
		oe = 8'h00;
		if (|sel_out_en) begin
			if (sel_flags_out[0]) begin
				d_out = sel_direct_do;
				oe = sel_out_en;
			end else if (sel_flags_out[1]) begin
				d_out = sel_direct_do & rom_do;
				oe = sel_out_en;
			end else if (sel_ram_sel) begin
				if (sel_ram_rw) begin
					d_out = cr_do;
					oe = sel_out_en;
				end
			end else begin
				d_out = rom_do;
				oe = sel_out_en;
			end
		end
	end

	// ---- families, calls, the tables, init, writeback, audio, jump map (cart2600.sv:648-893) ----
	wire  [1:0] table_family = is_cdf ? 2'd2 : 2'd0;
	wire  [1:0] init_family  = is_dpc ? 2'd1 : (is_cdf ? 2'd3 : 2'd0);
	logic       arm_call_ready, mapper_wb_idle;
	assign mapper_call_ready = arm_call_ready && mapper_wb_idle && !mapper_init_busy;
	wire        dpc_service_request = dpc_service_request_raw && is_dpc;
	wire        table_pointer_write = is_cdf && cdf_pointer_update;
	wire        arm_call_request = is_dpc ? dpc_call_request : (is_cdf ? cdf_call_request : 1'b0);
	wire [31:0] arm_call_entry   = is_dpc ? dpc_call_entry : cdf_call_entry;
	wire [31:0] arm_call_stack   = is_dpc ? dpc_call_stack : cdf_call_stack;
	wire        arm_call_thumb   = is_dpc ? dpc_call_thumb : cdf_call_thumb;

	logic [14:0] table_pointer_base;
	logic        init_ram_en;
	logic [16:0] init_ram_addr;
	logic        init_table_pointer_write, init_table_increment_write, init_table_map_write;
	logic  [5:0] init_table_pointer_index, init_table_increment_index, init_table_map_index;
	logic [31:0] init_table_pointer_wdata, init_table_increment_wdata, init_table_map_wdata;
	logic        mapper_dma_request, mapper_dma_fill;
	logic [24:0] mapper_dma_source;
	logic [16:0] mapper_dma_dest;
	logic [17:0] mapper_dma_count;
	logic  [7:0] mapper_dma_value;
	logic        arm_dma_ready, arm_dma_done;
	wire         mapper_dma_ready = mapper_init_busy && arm_dma_ready;
	wire         mapper_dma_done  = mapper_init_busy && arm_dma_done;
	assign dpc_service_ready = !mapper_init_busy && arm_dma_ready;

	// the ARM port of the cart RAM: the writeback wins (cart2600.sv:430-439)
	logic        arm_cartram_en, arm_cartram_write, arm_cartram_accepted;
	logic [14:0] arm_cartram_addr;
	logic [31:0] arm_cartram_wdata;
	logic  [3:0] arm_cartram_wstrb;
	logic        mapper_wb_en, mapper_wb_write;
	logic [14:0] mapper_wb_addr;
	logic [31:0] mapper_wb_wdata;
	logic  [3:0] mapper_wb_wstrb;
	logic        arm_ram_accepted;
	wire         arm_ram_en    = mapper_wb_en || arm_cartram_en;
	wire         arm_ram_write = mapper_wb_en ? mapper_wb_write : arm_cartram_write;
	wire  [14:0] arm_ram_addr  = mapper_wb_en ? mapper_wb_addr : arm_cartram_addr;
	wire  [31:0] arm_ram_wdata = mapper_wb_en ? mapper_wb_wdata : arm_cartram_wdata;
	wire   [3:0] arm_ram_wstrb = mapper_wb_en ? mapper_wb_wstrb : arm_cartram_wstrb;
	assign arm_cartram_accepted = arm_cartram_en && !mapper_wb_en && arm_ram_accepted;
	wire         mapper_wb_accepted = mapper_wb_en && arm_ram_accepted;

	arm_mapper_tables stream_tables (
		.clk_sys(clk_sys), .family(table_family), .revision(mapper_revision),
		.pointer_lookup_index(cdf_table_index), .increment_lookup_index(cdf_table_index),
		.pointer(table_pointer), .increment(table_increment),
		.pointer_base(table_pointer_base), .increment_base(), .map_base(), .stream_count(),
		.sys_pointer_write(init_table_pointer_write || table_pointer_write),
		.sys_pointer_index(init_table_pointer_write ? init_table_pointer_index : cdf_pointer_update_index),
		.sys_pointer_wdata(init_table_pointer_write ? init_table_pointer_wdata : cdf_pointer_update_value),
		.sys_increment_write(init_table_increment_write), .sys_increment_index(init_table_increment_index),
		.sys_increment_wdata(init_table_increment_wdata),
		.sys_map_write(init_table_map_write), .sys_map_index(init_table_map_index),
		.sys_map_wdata(init_table_map_wdata),
		.clk_arm(clk_arm), .arm_write(arm_cartram_en && arm_cartram_write), .arm_accepted(arm_cartram_accepted),
		.arm_addr(arm_cartram_addr), .arm_wdata(arm_cartram_wdata), .arm_wstrb(arm_cartram_wstrb));

	arm_mapper_ram_init ram_init (
		.clk_sys(clk_sys), .mapper_reset(reset), .load_start, .load_end(load_end_d),
		.family(init_family), .revision(mapper_revision), .mapper_ram_size,
		.busy(mapper_init_busy),
		.dma_request(mapper_dma_request), .dma_fill(mapper_dma_fill), .dma_source(mapper_dma_source),
		.dma_dest(mapper_dma_dest), .dma_count(mapper_dma_count), .dma_value(mapper_dma_value),
		.dma_ready(mapper_dma_ready), .dma_done(mapper_dma_done),
		.ram_en(init_ram_en), .ram_addr(init_ram_addr), .ram_word_rdata(cartram_word_data),
		.table_pointer_write(init_table_pointer_write), .table_pointer_index(init_table_pointer_index),
		.table_pointer_wdata(init_table_pointer_wdata),
		.table_increment_write(init_table_increment_write), .table_increment_index(init_table_increment_index),
		.table_increment_wdata(init_table_increment_wdata),
		.table_map_write(init_table_map_write), .table_map_index(init_table_map_index),
		.table_map_wdata(init_table_map_wdata));

	arm_mapper_writeback table_writeback (
		.clk_sys(clk_sys), .reset_sys(reset),
		.pointer_write(table_pointer_write),
		.pointer_addr(table_pointer_base + {9'b0, cdf_pointer_update_index}),
		.pointer_wdata(cdf_pointer_update_value),
		.map_write(1'b0), .map_addr(15'd0), .map_wdata(32'd0),
		.idle(mapper_wb_idle),
		.clk_arm(clk_arm), .reset_arm(reset),
		.ram_en(mapper_wb_en), .ram_write(mapper_wb_write), .ram_addr(mapper_wb_addr),
		.ram_wdata(mapper_wb_wdata), .ram_wstrb(mapper_wb_wstrb), .ram_accepted(mapper_wb_accepted));

	logic        arm_call_done;
	logic [31:0] arm_audio_counter0, arm_audio_counter1, arm_audio_counter2;
	logic [31:0] arm_audio_frequency0, arm_audio_frequency1, arm_audio_frequency2;
	logic [31:0] arm_audio_counter0_return, arm_audio_counter1_return, arm_audio_counter2_return;
	logic [31:0] arm_audio_frequency0_return, arm_audio_frequency1_return, arm_audio_frequency2_return;
	logic        audio_ram_en;
	logic [16:0] audio_ram_addr;
	logic        arm_sample_request, arm_sample_ready, arm_sample_busy, arm_sample_done;
	logic [24:0] arm_sample_addr;
	logic  [7:0] arm_sample_data;
	wire         audio_ram_grant = audio_ram_en && !init_ram_en && !sel_ram_sel;
	arm_mapper_audio mapper_audio (
		.clk(clk_sys), .reset(reset), .family(init_family), .revision(mapper_revision[1:0]),
		.rom_size, .mapper_ram_size, .audio_size_addr(arm_audio_size_addr),
		.bus_digital_audio(1'b0), .cdf_digital_audio(cdf_digital_audio),
		.dpc_waveform0(dpc_audio_waveform0), .dpc_waveform1(dpc_audio_waveform1),
		.dpc_waveform2(dpc_audio_waveform2), .dpc_note_write(dpc_audio_note_write),
		.dpc_note_voice(dpc_audio_note_voice), .dpc_note_value(dpc_audio_note_value),
		.call_launch(arm_call_request), .call_done(arm_call_done),
		.counter0_return(arm_audio_counter0_return), .counter1_return(arm_audio_counter1_return),
		.counter2_return(arm_audio_counter2_return), .frequency0_return(arm_audio_frequency0_return),
		.frequency1_return(arm_audio_frequency1_return), .frequency2_return(arm_audio_frequency2_return),
		.counter0(arm_audio_counter0), .counter1(arm_audio_counter1), .counter2(arm_audio_counter2),
		.frequency0(arm_audio_frequency0), .frequency1(arm_audio_frequency1), .frequency2(arm_audio_frequency2),
		.ram_en(audio_ram_en), .ram_addr(audio_ram_addr), .ram_grant(audio_ram_grant),
		.ram_byte_data(cartram_data), .ram_word_data(cartram_word_data),
		.rom_request(arm_sample_request), .rom_addr(arm_sample_addr), .rom_ready(arm_sample_ready),
		.rom_done(arm_sample_done), .rom_data(arm_sample_data), .amplitude(arm_audio_amplitude));

	cdf_fastjump_table jump_table (
		.clk_sys(clk_sys), .load_start, .load_addr, .load_valid, .load_data,
		.query_addr(cdf_rom_a[14:0]), .query_valid(fast_jump_valid));

	// ---- port A of the cart RAM (cart2600.sv:965-978; top.sv:918-936) ----------------------------
	wire  [17:0] cartram_addr = init_ram_en ? {1'b0, init_ram_addr} : (sel_ram_sel ? sel_ram_a : {1'b0, audio_ram_addr});
	wire         cartram_wr26 = !init_ram_en && sel_ram_sel && ~sel_ram_rw && ~phi1 && ~address_change && ~access_taken;
	// top.sv:752-753: without tia_en the port is the 7800 path's (not modelled: no write)
	wire         cartram_wr   = mapper_init_busy ? cartram_wr26 : (tia_en ? cartram_wr26 : 1'b0);
	wire         cartram_rd   = init_ram_en || audio_ram_grant || (sel_ram_sel && sel_ram_rw && ~phi1 && ~address_change);
	logic  [7:0] cartram_data_tdp;
	cart_ram_tdp cart_ram (
		.clk_sys(clk_sys),
		.mapper_en(mapper_init_busy ? (cartram_wr || cartram_rd) : !pause),
		.mapper_write(cartram_wr), .mapper_addr(cartram_addr[16:0]), .mapper_wdata(d_in),
		.mapper_rdata(cartram_data_tdp),
		.clk_arm(clk_arm), .arm_en(arm_ram_en), .arm_write(arm_ram_write), .arm_addr(arm_ram_addr),
		.arm_wdata(arm_ram_wdata), .arm_wstrb(arm_ram_wstrb), .arm_rdata(), .arm_accepted(arm_ram_accepted),
		.mapper_word_rdata(cartram_word_data));
	assign cartram_data = pause ? 8'hFF : cartram_data_tdp;

	// =========================================================================================
	// arm_mapper_subsystem: mapper_reset_arm (arm_mapper_subsystem.sv:104-116)
	// =========================================================================================
	logic mapper_reset_sync1 = 1'b1, mapper_reset_arm = 1'b1;
	always @(posedge clk_arm) begin
		if (reset_arm) begin
			mapper_reset_sync1 <= 1'b1;
			mapper_reset_arm <= 1'b1;
		end else begin
			mapper_reset_sync1 <= reset;
			mapper_reset_arm <= mapper_reset_sync1;
		end
	end

	// =========================================================================================
	// arm_mapper_controller, both halves (arm_mapper_controller.sv:51-361)
	// =========================================================================================
	logic [31:0] call_entry_payload, call_stack_payload;
	logic        call_thumb_payload;
	logic [31:0] audio_counter_payload [0:2];
	logic [31:0] audio_frequency_payload [0:2];
	logic        call_toggle, call_ack_arm, call_ack_sync1, call_ack_sync2;
	logic        complete_toggle, complete_token, complete_sync1, complete_sync2, complete_seen;
	logic        complete_token_sync1, complete_token_sync2;
	logic        complete_ack_sys, complete_ack_sync1, complete_ack_sync2;
	logic [31:0] audio_counter_result [0:2];
	logic [31:0] audio_frequency_result [0:2];
	logic [31:0] audio_counter_sync1 [0:2];
	logic [31:0] audio_counter_sync2 [0:2];
	logic [31:0] audio_frequency_sync1 [0:2];
	logic [31:0] audio_frequency_sync2 [0:2];
	logic        arm_online_sync1, arm_online_sync2, shadow_ready_sync1, shadow_ready_sync2;
	logic        sys_online_sync1, sys_online_sync2;
	logic        shadow_ready;
	logic        call_busy, call_done;
	assign arm_call_busy = call_busy;
	assign arm_call_done = call_done;
	assign arm_call_ready = arm_online_sync2 && shadow_ready_sync2 && !reset && !call_busy;

	always @(posedge clk_sys) begin
		if (reset_arm) begin
			call_entry_payload <= '0;
			call_stack_payload <= '0;
			call_thumb_payload <= 1'b0;
			for (int i = 0; i < 3; i++) begin
				audio_counter_payload[i] <= 32'b0;
				audio_frequency_payload[i] <= 32'b0;
				audio_counter_sync1[i] <= 32'b0;
				audio_counter_sync2[i] <= 32'b0;
				audio_frequency_sync1[i] <= 32'b0;
				audio_frequency_sync2[i] <= 32'b0;
			end
			arm_audio_counter0_return <= 32'b0;
			arm_audio_counter1_return <= 32'b0;
			arm_audio_counter2_return <= 32'b0;
			arm_audio_frequency0_return <= 32'b0;
			arm_audio_frequency1_return <= 32'b0;
			arm_audio_frequency2_return <= 32'b0;
			call_toggle <= 1'b0;
			call_ack_sync1 <= 1'b0;
			call_ack_sync2 <= 1'b0;
			complete_sync1 <= 1'b0;
			complete_sync2 <= 1'b0;
			complete_seen <= 1'b0;
			complete_token_sync1 <= 1'b0;
			complete_token_sync2 <= 1'b0;
			complete_ack_sys <= 1'b0;
			arm_online_sync1 <= 1'b0;
			arm_online_sync2 <= 1'b0;
			shadow_ready_sync1 <= 1'b0;
			shadow_ready_sync2 <= 1'b0;
			call_busy <= 1'b0;
			call_done <= 1'b0;
		end else begin
			for (int i = 0; i < 3; i++) begin
				audio_counter_sync1[i] <= audio_counter_result[i];
				audio_counter_sync2[i] <= audio_counter_sync1[i];
				audio_frequency_sync1[i] <= audio_frequency_result[i];
				audio_frequency_sync2[i] <= audio_frequency_sync1[i];
			end
			call_ack_sync1 <= call_ack_arm;
			call_ack_sync2 <= call_ack_sync1;
			complete_sync1 <= complete_toggle;
			complete_sync2 <= complete_sync1;
			complete_token_sync1 <= complete_token;
			complete_token_sync2 <= complete_token_sync1;
			arm_online_sync1 <= !reset_arm;
			arm_online_sync2 <= arm_online_sync1;
			shadow_ready_sync1 <= shadow_ready;
			shadow_ready_sync2 <= shadow_ready_sync1;
			call_done <= 1'b0;
			if (reset) begin
				complete_seen <= complete_sync2;
				complete_ack_sys <= complete_sync2;
				call_busy <= 1'b0;
			end else begin
				if (arm_call_request && arm_call_ready) begin
					call_entry_payload <= arm_call_entry;
					call_stack_payload <= arm_call_stack;
					call_thumb_payload <= arm_call_thumb;
					audio_counter_payload[0] <= arm_audio_counter0;
					audio_counter_payload[1] <= arm_audio_counter1;
					audio_counter_payload[2] <= arm_audio_counter2;
					audio_frequency_payload[0] <= arm_audio_frequency0;
					audio_frequency_payload[1] <= arm_audio_frequency1;
					audio_frequency_payload[2] <= arm_audio_frequency2;
					call_toggle <= ~call_toggle;
					call_busy <= 1'b1;
				end
				if (complete_sync2 != complete_seen) begin
					complete_seen <= complete_sync2;
					complete_ack_sys <= complete_sync2;
					if (call_busy && call_ack_sync2 == call_toggle && complete_token_sync2 == call_toggle) begin
						arm_audio_counter0_return <= audio_counter_sync2[0];
						arm_audio_counter1_return <= audio_counter_sync2[1];
						arm_audio_counter2_return <= audio_counter_sync2[2];
						arm_audio_frequency0_return <= audio_frequency_sync2[0];
						arm_audio_frequency1_return <= audio_frequency_sync2[1];
						arm_audio_frequency2_return <= audio_frequency_sync2[2];
						call_busy <= 1'b0;
						call_done <= 1'b1;
					end
				end
			end
		end
	end

	localparam logic [3:0] CTRL_IDLE = 4'd0, CTRL_WAIT_HALT = 4'd1, CTRL_WRITE_STATE = 4'd2, CTRL_COMMIT = 4'd3,
		CTRL_RELEASE = 4'd4, CTRL_RUNNING = 4'd5, CTRL_RETURN_HALT = 4'd6, CTRL_READ_AUDIO = 4'd7,
		CTRL_CAPTURE_AUDIO = 4'd8;
	logic [3:0]  control_state;
	logic        call_sync1, call_sync2, call_seen, active_token;
	logic [31:0] active_entry, active_stack;
	logic        active_thumb;
	logic [31:0] active_audio_counter [0:2];
	logic [31:0] active_audio_frequency [0:2];
	logic  [4:0] write_index;
	logic  [2:0] audio_read_index;
	assign halt_req = control_state != CTRL_RUNNING;

	always @(posedge clk_arm) begin
		if (reset_arm) begin
			call_sync1 <= 1'b0;
			call_sync2 <= 1'b0;
			call_seen <= 1'b0;
			call_ack_arm <= 1'b0;
			complete_toggle <= 1'b0;
			complete_token <= 1'b0;
			complete_ack_sync1 <= 1'b0;
			complete_ack_sync2 <= 1'b0;
			sys_online_sync1 <= 1'b0;
			sys_online_sync2 <= 1'b0;
			active_token <= 1'b0;
			active_entry <= '0;
			active_stack <= '0;
			active_thumb <= 1'b0;
			for (int i = 0; i < 3; i++) begin
				active_audio_counter[i] <= 32'b0;
				active_audio_frequency[i] <= 32'b0;
				audio_counter_result[i] <= 32'b0;
				audio_frequency_result[i] <= 32'b0;
			end
			write_index <= '0;
			audio_read_index <= '0;
			control_state <= CTRL_WAIT_HALT;
		end else begin
			call_sync1 <= call_toggle;
			call_sync2 <= call_sync1;
			complete_ack_sync1 <= complete_ack_sys;
			complete_ack_sync2 <= complete_ack_sync1;
			sys_online_sync1 <= !reset_arm;
			sys_online_sync2 <= sys_online_sync1;
			if (mapper_reset_arm) begin
				call_seen <= call_sync2;
				call_ack_arm <= call_sync2;
				complete_toggle <= complete_ack_sync2;
				complete_token <= 1'b0;
				control_state <= CTRL_WAIT_HALT;
			end else begin
				case (control_state)
					CTRL_WAIT_HALT: if (cpu_halted) control_state <= CTRL_IDLE;
					CTRL_IDLE: begin
						if (sys_online_sync2 && shadow_ready && cpu_halted &&
							complete_ack_sync2 == complete_toggle && call_sync2 != call_seen) begin
							active_token <= call_sync2;
							active_entry <= call_entry_payload;
							active_stack <= call_stack_payload;
							active_thumb <= call_thumb_payload;
							for (int i = 0; i < 3; i++) begin
								active_audio_counter[i] <= audio_counter_payload[i];
								active_audio_frequency[i] <= audio_frequency_payload[i];
							end
							call_seen <= call_sync2;
							call_ack_arm <= call_sync2;
							write_index <= 5'd0;
							control_state <= CTRL_WRITE_STATE;
						end
					end
					CTRL_WRITE_STATE: begin
						if (state_ready) begin
							if (write_index == 5'd22) control_state <= CTRL_COMMIT;
							else write_index <= write_index + 5'd1;
						end
					end
					CTRL_COMMIT: control_state <= CTRL_RELEASE;
					CTRL_RELEASE: control_state <= CTRL_RUNNING;
					CTRL_RUNNING: if (return_fetch) control_state <= CTRL_RETURN_HALT;
					CTRL_RETURN_HALT: begin
						if (cpu_halted) begin
							audio_read_index <= 3'd0;
							control_state <= CTRL_READ_AUDIO;
						end
					end
					CTRL_READ_AUDIO: if (state_ready) control_state <= CTRL_CAPTURE_AUDIO;
					default: begin // CTRL_CAPTURE_AUDIO
						if (audio_read_index < 3'd3) audio_counter_result[audio_read_index[1:0]] <= state_rdata;
						else audio_frequency_result[audio_read_index[1:0] - 2'd3] <= state_rdata;
						if (audio_read_index == 3'd5) begin
							complete_token <= active_token;
							complete_toggle <= ~complete_toggle;
							control_state <= CTRL_IDLE;
						end else begin
							audio_read_index <= audio_read_index + 3'd1;
							control_state <= CTRL_READ_AUDIO;
						end
					end
				endcase
			end
		end
	end

	// =========================================================================================
	// arm_mapper_memory: the load path (shadow_ready), the DMA and sample ports
	// =========================================================================================
	logic        dma_toggle, dma_complete_toggle, dma_complete_sync1, dma_complete_sync2;
	logic        dma_fill_payload;
	logic [24:0] dma_source_payload;
	logic [16:0] dma_dest_payload;
	logic [17:0] dma_count_payload;
	logic  [7:0] dma_value_payload;
	logic        sample_toggle, sample_complete_toggle, sample_complete_sync1, sample_complete_sync2;
	logic [24:0] sample_addr_payload;
	logic  [7:0] sample_result, sample_result_sync1, sample_result_sync2;
	logic        epoch_toggle, end_toggle;
	logic  [1:0] end_wait;                    // the last DDR word drains (the bench: two clocks)
	logic        dma_busy, dma_done, sample_busy, sample_done;
	logic  [7:0] sample_data;
	assign arm_dma_busy     = dma_busy;
	assign arm_dma_done     = dma_done;
	assign arm_sample_busy  = sample_busy;
	assign arm_sample_done  = sample_done;
	assign arm_sample_data  = sample_data;
	assign arm_dma_ready    = shadow_ready_sync2 && !dma_busy;
	assign arm_sample_ready = shadow_ready_sync2 && !sample_busy;

	// the DMA request mux (cart2600.sv:410-425)
	wire        arm_dma_request = mapper_init_busy ? mapper_dma_request : dpc_service_request;
	wire        arm_dma_fill    = mapper_init_busy ? mapper_dma_fill : dpc_service_fill;
	wire [24:0] arm_dma_source  = mapper_init_busy ? mapper_dma_source : {6'b0, dpc_service_source};
	wire [16:0] arm_dma_dest    = mapper_init_busy ? mapper_dma_dest : {2'b0, dpc_service_dest};
	wire [17:0] arm_dma_count   = mapper_init_busy ? mapper_dma_count : {10'b0, dpc_service_count};
	wire  [7:0] arm_dma_value   = mapper_init_busy ? mapper_dma_value : dpc_service_value;

	always @(posedge clk_sys) begin
		if (reset_arm) begin
			dma_toggle <= 1'b0;
			dma_complete_sync1 <= 1'b0;
			dma_complete_sync2 <= 1'b0;
			dma_fill_payload <= 1'b0;
			dma_source_payload <= '0;
			dma_dest_payload <= '0;
			dma_count_payload <= '0;
			dma_value_payload <= '0;
			sample_toggle <= 1'b0;
			sample_addr_payload <= '0;
			sample_complete_sync1 <= 1'b0;
			sample_complete_sync2 <= 1'b0;
			sample_result_sync1 <= 8'b0;
			sample_result_sync2 <= 8'b0;
			sample_busy <= 1'b0;
			sample_done <= 1'b0;
			sample_data <= 8'b0;
			dma_busy <= 1'b0;
			dma_done <= 1'b0;
			epoch_toggle <= 1'b0;
			end_toggle <= 1'b0;
			end_wait <= 2'd0;
		end else begin
			dma_complete_sync1 <= dma_complete_toggle;
			dma_complete_sync2 <= dma_complete_sync1;
			sample_complete_sync1 <= sample_complete_toggle;
			sample_complete_sync2 <= sample_complete_sync1;
			sample_result_sync1 <= sample_result;
			sample_result_sync2 <= sample_result_sync1;
			dma_done <= 1'b0;
			sample_done <= 1'b0;
			if (load_start) begin
				epoch_toggle <= ~epoch_toggle;
				end_wait <= 2'd0;
			end
			if (load_end) end_wait <= 2'd2;
			else if (end_wait == 2'd1) begin
				end_toggle <= ~end_toggle;
				end_wait <= 2'd0;
			end else if (end_wait != 2'd0) end_wait <= end_wait - 2'd1;
			if (arm_dma_request && arm_dma_ready) begin
				dma_fill_payload <= arm_dma_fill;
				dma_source_payload <= arm_dma_source;
				dma_dest_payload <= arm_dma_dest;
				dma_count_payload <= arm_dma_count;
				dma_value_payload <= arm_dma_value;
				dma_toggle <= ~dma_toggle;
				dma_busy <= 1'b1;
			end
			if (dma_busy && dma_complete_sync2 == dma_toggle) begin
				dma_busy <= 1'b0;
				dma_done <= 1'b1;
			end
			if (arm_sample_request && arm_sample_ready) begin
				sample_addr_payload <= arm_sample_addr;
				sample_toggle <= ~sample_toggle;
				sample_busy <= 1'b1;
			end
			if (sample_busy && sample_complete_sync2 == sample_toggle) begin
				sample_data <= sample_result_sync2;
				sample_busy <= 1'b0;
				sample_done <= 1'b1;
			end
		end
	end

	// clk_arm: the load epoch, the DMA and sample machines, the DDR server
	localparam logic [1:0] DMA_IDLE = 2'd0, DMA_COPY_COMMAND = 2'd1, DMA_COPY_WAIT = 2'd2, DMA_RAM_WRITE = 2'd3;
	localparam logic [1:0] SAMPLE_IDLE = 2'd0, SAMPLE_CHECK = 2'd1, SAMPLE_COMMAND = 2'd2, SAMPLE_WAIT = 2'd3;
	logic  [1:0] dma_state, sample_state;
	logic        dma_sync1, dma_sync2, dma_seen, dma_active_token, dma_active_fill;
	logic [24:0] dma_active_source;
	logic [16:0] dma_active_dest;
	logic [17:0] dma_remaining;
	logic  [7:0] dma_active_value;
	logic [63:0] dma_read_data;
	logic        sample_sync1, sample_sync2, sample_seen, sample_active_token;
	logic [24:0] sample_active_addr;
	logic        sample_cache_valid;
	logic        inj_smp = 1'b0;              // tb_fe_rand's self-test fault 8: a DDR sample byte ^ $11
	logic [21:0] sample_cache_tag;
	logic [63:0] sample_cache_data;
	logic        epoch_sync1, epoch_sync2, epoch_seen, end_sync1, end_sync2, end_seen;
	logic [31:0] mem_rom_size;
	logic        ddr_busy, ddr_dma;           // an access in flight, and whose
	int          ddr_left;
	wire         dma_ram_en = dma_state == DMA_RAM_WRITE;
	wire   [7:0] dma_write_byte = dma_active_fill ? dma_active_value : get_byte(dma_read_data, dma_active_source[2:0]);
	// the CPU's word below the DMA (arm_mapper_memory.sv:600-644)
	assign arm_cartram_en    = dma_ram_en || cpu_en;
	assign arm_cartram_write = dma_ram_en || cpu_write;
	assign arm_cartram_addr  = dma_ram_en ? dma_active_dest[16:2] : cpu_addr;
	assign arm_cartram_wdata = dma_ram_en ? {4{dma_write_byte}} : cpu_wdata;
	assign arm_cartram_wstrb = dma_ram_en ? (4'b0001 << dma_active_dest[1:0]) : cpu_wstrb;
	assign cpu_accepted      = cpu_en && !dma_ram_en && arm_cartram_accepted;

	// the DDR latency: +ddr_lat_min..+ddr_lat_max clk_arm edges, +ddr_long per mille up to +ddr_long_max
	int unsigned lat_min = 4, lat_max = 24, lat_long = 20, lat_long_max = 300;
	int          lat_seed = 1;
	logic [31:0] lrs = 32'h0;                 // 0: not seeded yet (xorshift never returns to 0)
	initial begin
		void'($value$plusargs("seed=%d", lat_seed));
		void'($value$plusargs("ddr_lat_min=%d", lat_min));
		void'($value$plusargs("ddr_lat_max=%d", lat_max));
		void'($value$plusargs("ddr_long=%d", lat_long));
		void'($value$plusargs("ddr_long_max=%d", lat_long_max));
		if (lat_max < lat_min) lat_max = lat_min;
	end
	function automatic int lat_next();
		if (lrs == 32'h0) begin
			lrs = 32'h2545_F491 ^ ((32'(lat_seed) + lat_ofs) * 32'h9E37_79B9);
			if (lrs == 32'h0) lrs = 32'h1;
		end
		lrs = lrs ^ (lrs << 13);
		lrs = lrs ^ (lrs >> 17);
		lrs = lrs ^ (lrs << 5);
		if ((lrs % 1000) < lat_long) return int'(lat_max + 1 + (lrs >> 10) % (lat_long_max + 1));
		return int'(lat_min + (lrs >> 10) % (lat_max - lat_min + 1));
	endfunction

	always @(posedge clk_arm) begin
		if (reset_arm) begin
			dma_sync1 <= 1'b0;
			dma_sync2 <= 1'b0;
			dma_seen <= 1'b0;
			dma_active_token <= 1'b0;
			dma_complete_toggle <= 1'b0;
			dma_active_fill <= 1'b0;
			dma_active_source <= '0;
			dma_active_dest <= '0;
			dma_remaining <= '0;
			dma_active_value <= '0;
			dma_read_data <= '0;
			dma_state <= DMA_IDLE;
			sample_sync1 <= 1'b0;
			sample_sync2 <= 1'b0;
			sample_seen <= 1'b0;
			sample_active_token <= 1'b0;
			sample_active_addr <= '0;
			sample_complete_toggle <= 1'b0;
			sample_result <= 8'b0;
			sample_state <= SAMPLE_IDLE;
			sample_cache_valid <= 1'b0;
			sample_cache_tag <= '0;
			sample_cache_data <= '0;
			epoch_sync1 <= 1'b0;
			epoch_sync2 <= 1'b0;
			epoch_seen <= 1'b0;
			end_sync1 <= 1'b0;
			end_sync2 <= 1'b0;
			end_seen <= 1'b0;
			shadow_ready <= 1'b0;
			mem_rom_size <= '0;
			ddr_busy <= 1'b0;
			ddr_dma <= 1'b0;
			ddr_left <= 0;
		end else begin
			epoch_sync1 <= epoch_toggle;
			epoch_sync2 <= epoch_sync1;
			end_sync1 <= end_toggle;
			end_sync2 <= end_sync1;
			dma_sync1 <= dma_toggle;
			dma_sync2 <= dma_sync1;
			sample_sync1 <= sample_toggle;
			sample_sync2 <= sample_sync1;
			if (epoch_sync2 != epoch_seen) begin
				epoch_seen <= epoch_sync2;
				shadow_ready <= 1'b0;
				sample_cache_valid <= 1'b0;
			end
			// the DDR server (DDR_IDLE's order: the load's end, then the DMA, then a sample)
			if (!ddr_busy) begin
				if (end_sync2 != end_seen) begin
					end_seen <= end_sync2;
					mem_rom_size <= rom_size;
					shadow_ready <= 1'b1;
				end else if (dma_state == DMA_COPY_COMMAND) begin
					ddr_busy <= 1'b1;
					ddr_dma <= 1'b1;
					ddr_left <= lat_next();
					dma_state <= DMA_COPY_WAIT;
				end else if (sample_state == SAMPLE_COMMAND) begin
					ddr_busy <= 1'b1;
					ddr_dma <= 1'b0;
					ddr_left <= lat_next();
					sample_state <= SAMPLE_WAIT;
				end
			end else if (ddr_left > 0) ddr_left <= ddr_left - 1;
			else begin
				ddr_busy <= 1'b0;
				if (ddr_dma) begin
					dma_read_data <= ddr_word(dma_active_source);
					dma_state <= DMA_RAM_WRITE;
				end else begin
					sample_cache_data <= ddr_word(sample_active_addr);
					sample_cache_tag <= sample_active_addr[24:3];
					sample_cache_valid <= 1'b1;
					sample_result <= get_byte(ddr_word(sample_active_addr), sample_active_addr[2:0]) ^ (inj_smp ? 8'h11 : 8'h00);
					sample_complete_toggle <= sample_active_token;
					sample_state <= SAMPLE_IDLE;
				end
			end
			case (dma_state)
				DMA_IDLE: begin
					if (dma_sync2 != dma_seen) begin
						dma_seen <= dma_sync2;
						dma_active_token <= dma_sync2;
						dma_active_fill <= dma_fill_payload;
						dma_active_source <= dma_source_payload;
						dma_active_dest <= dma_dest_payload;
						dma_remaining <= dma_count_payload;
						dma_active_value <= dma_value_payload;
						if (dma_count_payload == 18'b0) dma_complete_toggle <= dma_sync2;
						else if (dma_fill_payload) dma_state <= DMA_RAM_WRITE;
						else dma_state <= DMA_COPY_COMMAND;
					end
				end
				DMA_RAM_WRITE: begin
					if (arm_cartram_accepted) begin
						if (dma_remaining == 18'd1) begin
							dma_complete_toggle <= dma_active_token;
							dma_state <= DMA_IDLE;
						end else begin
							dma_active_dest <= dma_active_dest + 17'd1;
							dma_remaining <= dma_remaining - 18'd1;
							if (!dma_active_fill) begin
								dma_active_source <= dma_active_source + 25'd1;
								if (dma_active_source[2:0] == 3'd7) dma_state <= DMA_COPY_COMMAND;
							end
						end
					end
				end
				default: ;
			endcase
			case (sample_state)
				SAMPLE_IDLE: begin
					if (sample_sync2 != sample_seen) begin
						sample_seen <= sample_sync2;
						sample_active_token <= sample_sync2;
						sample_active_addr <= sample_addr_payload;
						sample_state <= SAMPLE_CHECK;
					end
				end
				SAMPLE_CHECK: begin
					if ({7'b0, sample_active_addr} >= mem_rom_size) begin
						sample_result <= 8'b0;
						sample_complete_toggle <= sample_active_token;
						sample_state <= SAMPLE_IDLE;
					end else if (sample_cache_valid && sample_cache_tag == sample_active_addr[24:3]) begin
						sample_result <= get_byte(sample_cache_data, sample_active_addr[2:0]);
						sample_complete_toggle <= sample_active_token;
						sample_state <= SAMPLE_IDLE;
					end else sample_state <= SAMPLE_COMMAND;
				end
				default: ;
			endcase
		end
	end
endmodule

`default_nettype wire
