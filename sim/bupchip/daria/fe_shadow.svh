//------------------------------------------------------------------------------
// The front-end shadow, stage 0 (DARIA step 6): included at the end of
// tb_daria.sv with -DFE_SHADOW (run_daria.sh with FE=1).
//
// Before DARIA's own front end (daria_fe) exists, a REFERENCE front end
// stands where it will stand: a second copy of upstream's mapper_dpcplus and
// mapper_cdf, with a second cdf_fastjump_table, driven only by continuous
// assigns from the DUT and never fed back. The reference is upstream's own
// code, so every count below must be 0: a difference is a tap or a
// timing-convention error in this bench, not in a front end. Once it is 0,
// the same taps and comparison points serve daria_fe.
//
// Taps. All are continuous assigns, so the reference samples them pre-edge,
// at the same edge as the DUT's own flops.
//   a_in, d_in, rw, access   dut.cart2600.{a_in, d_in, rw, arm_access}
//   reset                    dut.effective_reset, or-ed with "scheme is not
//                            mine", as cart2600.sv resets its own instances
//   scheme, revision, CDF    tb_daria's detect2600 outputs (force_bs,
//   options, entry, stack    mapper_revision, cdf_*, cdfj_*): cart2600's
//                            `mapper` is force_bs, since the tb ties
//                            .mapper(0)
//   rom_data                 tb_daria's 1-clock ROM rom[], through the
//                            reference's own read port at its own rom_a,
//                            addressed by top.sv's cart_addr_out rule (the
//                            2600 address while tia_en, else MARIA's), and
//                            the download byte while cart_download, as the
//                            tb's .cart_out. It must equal the tb's cart_q
//                            on every clock (rom).
//   ram_data / ram_rdata     dut.cart2600.cartram_data (cart RAM port A's
//                            byte, addressed by the DUT's arbitration)
//   table_pointer, increment dut.cart2600.table_pointer, table_increment
//                            (the stream tables' registered lookups)
//   fast_jump_valid          the reference's own cdf_fastjump_table, on the
//                            tb's load stream, queried at the reference's
//                            own rom_a; its map must equal the DUT's (jump)
//   amplitude                dut.cart2600.arm_audio_amplitude
//   call_ready               dut.cart2600.mapper_call_ready
//   service_ready            dut.cart2600.dpc_service_ready
//
// The RAM byte and the stream pointer are the DUT's, addressed by the DUT,
// so on their own they would make L1 compare upstream's RAM byte with itself.
// The bench therefore also reads, beside the reference, what upstream's ports
// would return at the REFERENCE's own addresses: cart RAM port A's byte at
// its ram_a (DPC+) or at $800 + its own pointer (CDF), and the pointer table
// at its own table_index, each with the port's one-clock registered timing
// and read-during-write rule (backdoor reads of the DUT's arrays). L1 checks
// every RAM byte the reference consumes against that independent byte, so a
// wrong RAM or table address fails L1 as it will with daria_fe's own memory.
// AMPLITUDE stays a tap (the reference has no audio engine; counted apart).
//
// Checks (fe_spec/bench.md 7.5). They run while "live": from a pclk1 with
// !effective_reset and tia_en until the next console reset, and again from
// the first such pclk1 after it. E0 is that pclk1 pulse itself.
//   L1  every pclk0 edge with RW, scheme 21 or 23: cart2600's (oe, d_out & oe)
//       against the reference's, put through cart2600's own output mux; and
//       any RAM byte the reference consumed there against the byte at its own
//       address. A hidden pclk0 (a held cycle's repeat, pclk0 && !mapper_phi2)
//       is counted apart as information (dout_hidden); the last one before a
//       release, whose byte the CPU's DL carries out of the stall, is counted
//       on its own as well (hidden_last).
//   C1  DPC+ registers at every pclk1 (what the previous cycle left)
//   C2  CDF registers at every pclk1
//   S1  E0 -> pclk0 and pclk0 -> E0 spacing, and E0 -> E0: histograms
//       before the checks, live with MARIA's and with the TIA's phases, and
//       in a console reset; also every handoff of the phases to the TIA,
//       every line-end reload of the TIA's divider that re-phases it
//       (pclk_div != 1 before it) and every console reset
//   commits (access && a_in[12]) and latches (pclk0 edges) are counted.
// Tap checks, which must be 0 too:
//   port  the reference's mapper outputs against upstream's, every clk_sys
//         from `running` (d_out, flags, oe, rom_a, the RAM port, the table
//         index and pointer update, call and service requests, NOTE, ...)
//   rom   the reference's ROM byte against the tb's cart_q, every clk_sys
//   ram   the independent RAM byte against cart RAM port A's, on every clock
//         whose two registered addresses are equal (the model's own check)
//   pointer  the independent pointer against table_pointer, on every clock
//         whose two lookup indices were equal or the port was written (CDF)
//   jump  the reference's jump map against the DUT's, once, after the load
//   L3    the CPU's latch (dp.dl) at the edge after a pclk0 against the
//         byte sampled at that pclk0 (read_DB on a read, write_DB on a
//         write): proves "pre-edge at pclk0 is what the 6507 latches"
//
// Outputs (in +out, i.e. sim/work):
//   fe.csv      one line per frame, at the VSYNC rise (as frames.csv)
//   fe_err.txt  the first +fe_stop failures; the first two with the last 64
//               clk_sys of the bus
//   run.log     "FE checks from ..." when the checks start and "FE handoff:"
//               for the phase handoffs, the re-phasing reloads and the first
//               RSYNC writes; "FE reset:" for console resets; "FE inject:"
//               for an injected fault; at the end "FE shadow: <scheme>
//               <latches> latches, <commits> commits; dout <n>, state <n>
//               bad; E0->latch <min>..<max>", then "FE detail:", "FE spacing
//               ...", "FE coverage:", "FE S1:", "FE reloads:" and "FE resets:"
// Plusargs: +fe_stop=N (default 20) lines in fe_err.txt; +fe_fatal=1 stops
// the run at the first failure. +hard_reset_at=F pulses the console reset
// (the tb's reset_in) at the VSYNC rise that starts frame F, for
// +hard_reset_len=N clk_sys (default 1000), so the re-init, the re-arming of
// the checks and the second MARIA -> TIA handoff are exercised.
// The bench's self-test, all off by default (stage0.md has the tables):
//   +fe_mut=N breaks one tap or convention: 1 the ROM byte +fe_lag clocks
//   late (default 1: a 2-clock ROM); 2 the RAM byte a clock late; 3 the table
//   lookups a clock late; 4 AMPLITUDE a clock late; 5 access from every pclk0
//   (a held cycle's repeats not hidden); 6 a_in a clock late; 7 reset from the
//   bench's reset register (before top.sv's reset_hold); 8 d_in from read_DB
//   on writes too; 9 the reference's slot output +fe_lag clocks late;
//   10 access one clock late (every commit at E0+7).
//   Single faults, injected into the reference's inputs or outputs:
//   +fe_flip=N       flip bit +fe_flip_bit (default 0) of the reference's slot
//                    byte for one clock, the clock ending at E0+6+fe_flip_ofs
//                    (default 0, the latch itself; -4..5) of the first cart
//                    read cycle (RW, A12, no stall) from checked cycle N on
//   +fe_flip_hidden=1  the same, but on a hidden pclk0 (a stall's repeat)
//   +fe_bank=N       at the N-th hotspot commit (+fe_bank_wr=1: the N-th
//                    hotspot write) the reference sees a_in[0] inverted on
//                    that clock: it switches to a wrong bank
//   +fe_bank_spur=N  from checked cycle N on, at E0+8 (no latch, no commit
//                    upstream) the reference alone sees a hotspot write to
//                    the bank after its current one: a wrong bank with no
//                    other effect (this image set makes no hotspot commits)
//   +fe_cnt=N        at the N-th DPC+ DFxLOW write commit ($1050-$1057) the
//                    reference sees d_in + 1: a fetcher counter off by one
//   +fe_fpstuck=1|2  the reference's CDF fast_pending forced to 0 (1) or 1
//                    (2) from the start of the checks (a stuck flop)
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

	// ---- fault injection controls (all 0: off) -------------------------------------
	int          fe_mut = 0, fe_lag = 1;
	int          fe_flip = 0, fe_flip_ofs = 0, fe_flip_bit = 0;
	int          fe_bank = 0, fe_bank_wr = 0, fe_cnt = 0, fe_fpstuck = 0, fe_flip_hidden = 0, fe_bank_spur = 0;
	logic        fe_spur_on = 0, fe_spur_done = 0;	// +fe_bank_spur: this clock is the spurious write
	logic [12:0] fe_spur_a = 0;
	// Hotspot / DFxLOW commits so far. The reference reads these through
	// fe_bank_inj / fe_cnt_inj at the same edge as they count, so they must
	// change only by NBA (a blocking update injected one commit early).
	int          fe_bank_n = 0, fe_cnt_n = 0, fe_hot_rd_n = 0, fe_hot_wr_n = 0;
	logic        fe_flip_done = 0, fe_fp_forced = 0;
	logic  [7:0] fe_flip_mask = 0;		// XOR on the reference's slot byte, this clock

	// ---- taps ----------------------------------------------------------------------
	// With every control off each tap is the plain continuous assign named in
	// the header.
	logic [12:0] fe_a_in_q = 0;
	logic  [7:0] fe_ram_q_q = 0, fe_amp_q = 0;
	logic [31:0] fe_tptr_q = 0, fe_tinc_q = 0;
	logic        fe_access_q = 0;
	always @(posedge clk_sys) begin			// one clock late, for fe_mut only
		fe_a_in_q <= dut.cart2600.a_in;
		fe_ram_q_q <= dut.cart2600.cartram_data;
		fe_amp_q <= dut.cart2600.arm_audio_amplitude;
		fe_tptr_q <= dut.cart2600.table_pointer;
		fe_tinc_q <= dut.cart2600.table_increment;
		fe_access_q <= dut.cart2600.arm_access;
	end
	wire  [5:0] fe_scheme   = force_bs;
	wire        fe_is_dpc   = fe_scheme == 6'd21;     // BANKDPCP
	wire        fe_is_cdf   = fe_scheme == 6'd23;     // BANKCDF
	wire [12:0] fe_up_a     = dut.cart2600.a_in;
	// +fe_bank / +fe_cnt: the commit they act on, from upstream's own decode
	// (the reference's would make a loop through its a_in / d_in).
	wire        fe_hot_all  = dut.cart2600.arm_access && fe_up_a[12] &&
		(fe_is_cdf ? (fe_up_a[11:0] >= 12'hFF4 && fe_up_a[11:0] <= 12'hFFB && !dut.cart2600.cdf.stream_substitute)
		           : (fe_up_a[11:0] >= 12'hFF6 && fe_up_a[11:0] <= 12'hFFB && !dut.cart2600.dpcplus.register_read));
	wire        fe_hot_now  = fe_hot_all && (fe_bank_wr == 0 || !dut.cart2600.rw);
	wire        fe_bank_inj = fe_bank != 0 && fe_hot_now && fe_bank_n == fe_bank - 1;
	wire        fe_dfl_now  = fe_is_dpc && dut.cart2600.arm_access && !dut.cart2600.rw && fe_up_a[12] &&
		fe_up_a[11:3] == 9'h00A;			// DFxLOW, $050-$057
	wire        fe_cnt_inj  = fe_cnt != 0 && fe_dfl_now && fe_cnt_n == fe_cnt - 1;
	wire        fe_cart_rst = fe_mut == 7 ? reset : dut.effective_reset;	// = dut.cart2600.reset
	wire [12:0] fe_a_in     = fe_spur_on ? fe_spur_a : fe_mut == 6 ? fe_a_in_q : fe_up_a ^ {12'd0, fe_bank_inj};
	wire  [7:0] fe_d_in     = fe_mut == 8 ? dut.read_DB : dut.cart2600.d_in + {7'd0, fe_cnt_inj};
	wire        fe_rw       = dut.cart2600.rw && !fe_spur_on;
	wire        fe_access   = fe_spur_on || (fe_mut == 5 ? dut.pclk0 && dut.cart2600.arm_driver_run :
		fe_mut == 10 ? fe_access_q : dut.cart2600.arm_access);
	wire  [7:0] fe_ram_q    = fe_mut == 2 ? fe_ram_q_q : dut.cart2600.cartram_data;
	wire  [7:0] fe_amp      = fe_mut == 4 ? fe_amp_q : dut.cart2600.arm_audio_amplitude;
	wire        fe_call_rdy = dut.cart2600.mapper_call_ready;
	wire        fe_svc_rdy  = dut.cart2600.dpc_service_ready;
	wire [31:0] fe_tptr     = fe_mut == 3 ? fe_tptr_q : dut.cart2600.table_pointer;
	wire [31:0] fe_tinc     = fe_mut == 3 ? fe_tinc_q : dut.cart2600.table_increment;

	// ---- the reference's ROM port ----------------------------------------------------
	wire [18:0] fe_dpc_rom_a, fe_cdf_rom_a;
	wire [18:0] fe_rom_a     = fe_is_cdf ? fe_cdf_rom_a : fe_dpc_rom_a;
	wire [24:0] fe_cart_addr = dut.tia_en ? {6'd0, fe_rom_a} : dut.cart_7800_addr_out;
	logic [7:0] fe_rom_q = 8'hFF;
	logic [7:0] fe_rom_lag [8];			// fe_mut 1 only: fe_rom_q 1..8 clocks late
	always @(posedge clk_sys) begin
		fe_rom_q <= rom[fe_cart_addr[18:0]];
		fe_rom_lag[0] <= fe_rom_q;
		for (int k = 1; k < 8; k++) fe_rom_lag[k] <= fe_rom_lag[k - 1];
	end
	wire  [7:0] fe_rom_data = cart_download ? ioctl_dout : (fe_mut == 1 ? fe_rom_lag[fe_lag - 1] : fe_rom_q);

	// ---- reference DPC+ ----------------------------------------------------------------
	wire  [7:0] fe_dpc_do, fe_dpc_oe, fe_dpc_note_value, fe_dpc_svc_count, fe_dpc_svc_value;
	wire [15:0] fe_dpc_flags;
	wire        fe_dpc_ram_sel, fe_dpc_ram_rw, fe_dpc_note_write, fe_dpc_call_req;
	wire        fe_dpc_svc_req, fe_dpc_svc_fill;
	wire [17:0] fe_dpc_ram_a;
	wire  [6:0] fe_dpc_wf0, fe_dpc_wf1, fe_dpc_wf2;
	wire  [1:0] fe_dpc_note_voice;
	wire [18:0] fe_dpc_svc_source;
	wire [14:0] fe_dpc_svc_dest;

	mapper_dpcplus fe_ref_dpc (
		.clk(clk_sys), .reset(fe_cart_rst || !fe_is_dpc), .access(fe_access), .rw(fe_rw),
		.a_in(fe_a_in), .d_in(fe_d_in), .rom_data(fe_rom_data), .stable_fractional(mapper_revision[0]),
		.d_out(fe_dpc_do), .flags_out(fe_dpc_flags), .oe(fe_dpc_oe), .rom_a(fe_dpc_rom_a),
		.ram_sel(fe_dpc_ram_sel), .ram_rw(fe_dpc_ram_rw), .ram_a(fe_dpc_ram_a), .ram_data(fe_ram_q),
		.amplitude(fe_amp),
		.audio_waveform0(fe_dpc_wf0), .audio_waveform1(fe_dpc_wf1), .audio_waveform2(fe_dpc_wf2),
		.audio_note_write(fe_dpc_note_write), .audio_note_voice(fe_dpc_note_voice),
		.audio_note_value(fe_dpc_note_value),
		.call_request(fe_dpc_call_req), .call_entry(), .call_stack(), .call_thumb(),
		.call_ready(fe_call_rdy),
		.service_request(fe_dpc_svc_req), .service_fill(fe_dpc_svc_fill),
		.service_source(fe_dpc_svc_source), .service_dest(fe_dpc_svc_dest),
		.service_count(fe_dpc_svc_count), .service_value(fe_dpc_svc_value),
		.service_ready(fe_svc_rdy));

	// ---- reference CDF, with its own fast-jump map -------------------------------------
	wire  [7:0] fe_cdf_do, fe_cdf_oe, fe_cdf_ram_wdata;
	wire [15:0] fe_cdf_flags;
	wire  [5:0] fe_cdf_tidx, fe_cdf_pu_index;
	wire        fe_cdf_pu, fe_cdf_ram_en, fe_cdf_ram_write, fe_cdf_digital, fe_cdf_call_req;
	wire        fe_cdf_call_thumb, fe_jump_valid;
	wire [31:0] fe_cdf_pu_value, fe_cdf_call_entry, fe_cdf_call_stack;
	wire [14:0] fe_cdf_ram_addr;

	cdf_fastjump_table fe_ref_jump (
		.clk_sys, .load_start(~old_cart_download && cart_download), .load_addr(ioctl_addr),
		.load_valid(ioctl_wr && cart_download), .load_data(ioctl_dout),
		.query_addr(fe_cdf_rom_a[14:0]), .query_valid(fe_jump_valid));

	mapper_cdf fe_ref_cdf (
		.clk(clk_sys), .reset(fe_cart_rst || !fe_is_cdf), .access(fe_access), .rw(fe_rw),
		.a_in(fe_a_in), .d_in(fe_d_in), .rom_data(fe_rom_data), .revision(mapper_revision[1:0]),
		.enable_ldx(cdf_ldx), .enable_ldy(cdf_ldy), .fetch_offset_enable(cdf_fetch_offset_enable),
		.fetch_offset(cdf_fetch_offset), .fast_jump_valid(fe_jump_valid),
		.d_out(fe_cdf_do), .flags_out(fe_cdf_flags), .oe(fe_cdf_oe), .rom_a(fe_cdf_rom_a),
		.table_index(fe_cdf_tidx), .table_pointer(fe_tptr), .table_increment(fe_tinc[15:0]),
		.pointer_update(fe_cdf_pu), .pointer_update_index(fe_cdf_pu_index),
		.pointer_update_value(fe_cdf_pu_value),
		.ram_en(fe_cdf_ram_en), .ram_write(fe_cdf_ram_write), .ram_addr(fe_cdf_ram_addr),
		.ram_wdata(fe_cdf_ram_wdata), .ram_rdata(fe_ram_q), .amplitude(fe_amp),
		.digital_audio(fe_cdf_digital),
		.call_request(fe_cdf_call_req), .call_entry(fe_cdf_call_entry), .call_stack(fe_cdf_call_stack),
		.call_thumb(fe_cdf_call_thumb), .call_ready(fe_call_rdy),
		.cdfj_entry, .cdfj_stack);

	// ---- what upstream's ports would return at the reference's own addresses ------------
	// Pointer table port A (arm_mapper_tables.sv:146-158; cache_ram.v:262-270):
	// q <= wren ? wdata : mem[addr], and a write takes the port's address. ARM
	// writes come on clk_arm port B at edges clk_sys never shares.
	logic [31:0] fe_own_ptr = 0;
	wire  [14:0] fe_own_cdf_ra = mapper_revision[1:0] == 2'd3 ? 15'd2048 + fe_own_ptr[30:16] :
		15'd2048 + {3'b0, fe_own_ptr[31:20]};		// mapper_cdf.sv:126-128, 15 bits
	// Cart RAM port A (cart_ram_tdp.sv:58-84): one address for the four lanes,
	// q <= wren ? wdata : mem[word], the lane picked by a registered select.
	wire  [16:0] fe_own_ra = fe_is_cdf ? {2'b0, fe_own_cdf_ra} : fe_dpc_ram_a[16:0];
	logic  [7:0] fe_own_rq = 0, fe_own_rq_q = 0;
	logic [16:0] fe_own_ra_q = 0, fe_up_ra_q = 0;
	logic        fe_up_men_q = 0, fe_ptr_cmp_q = 0;
	function automatic logic [7:0] fe_ram_byte(input logic [16:0] a);
		case (a[1:0])
			2'd0: return dut.cart_ram.ram_lane[0].lane_ram.mem_q[a[16:2]];
			2'd1: return dut.cart_ram.ram_lane[1].lane_ram.mem_q[a[16:2]];
			2'd2: return dut.cart_ram.ram_lane[2].lane_ram.mem_q[a[16:2]];
			default: return dut.cart_ram.ram_lane[3].lane_ram.mem_q[a[16:2]];
		endcase
	endfunction
	always @(posedge clk_sys) begin
		fe_own_rq <= (dut.cart_ram.mapper_en && dut.cart_ram.mapper_write && dut.cart_ram.mapper_addr == fe_own_ra) ?
			dut.cart_ram.mapper_wdata : fe_ram_byte(fe_own_ra);
		fe_own_rq_q <= fe_own_rq;			// fe_mut 2: the reference's RAM is a clock late
		fe_own_ra_q <= fe_own_ra;
		fe_up_ra_q <= dut.cart_ram.mapper_addr;
		fe_up_men_q <= dut.cart_ram.mapper_en;
		fe_own_ptr <= dut.cart2600.stream_tables.sys_pointer_write ? dut.cart2600.stream_tables.sys_pointer_wdata :
			dut.cart2600.stream_tables.pointer_ram.mem_q[fe_cdf_tidx];
		fe_ptr_cmp_q <= dut.cart2600.stream_tables.sys_pointer_write ||
			fe_cdf_tidx == dut.cart2600.stream_tables.pointer_lookup_index;
	end
	wire  [7:0] fe_own_byte = fe_mut == 2 ? fe_own_rq_q : fe_own_rq;
	// The RAM byte the reference's slot uses this clock, and which bits of it.
	wire        fe_ram_use  = fe_is_cdf ? fe_ref_cdf.stream_substitute && !fe_ref_cdf.amplitude_fetch :
		fe_ref_dpc.ram_register_read;
	wire  [7:0] fe_ram_mask = (!fe_is_cdf && fe_ref_dpc.read_function == 3'd2) ? fe_ref_dpc.window_flag : 8'hFF;
	wire        fe_amp_use  = fe_is_cdf ? fe_ref_cdf.amplitude_fetch :
		fe_ref_dpc.register_read && fe_ref_dpc.read_function == 3'd0 && fe_ref_dpc.read_index == 3'd5;

	// ---- the slot: cart2600.sv's output mux, applied to the reference --------------------
	// {oe, d}. The ARM schemes are never the bad game screen (no NO_ARM_MAPPER).
	function automatic logic [15:0] fe_slot(input logic [15:0] flags, input logic [7:0] direct,
		input logic [7:0] en, input logic ram_sel, input logic ram_rw, input logic [7:0] rom_do,
		input logic [7:0] cr_do);
		logic [7:0] d, o;
		d = 8'h00;
		o = 8'h00;
		if (|en) begin
			if (flags[0]) begin d = direct; o = en; end
			else if (flags[1]) begin d = direct & rom_do; o = en; end
			else if (ram_sel) begin
				if (ram_rw) begin d = cr_do; o = en; end
			end else begin d = rom_do; o = en; end
		end
		return {o, d};
	endfunction
	wire [15:0] fe_dpc_slot = fe_slot(fe_dpc_flags, fe_dpc_do, fe_dpc_oe, fe_dpc_ram_sel, fe_dpc_ram_rw,
		fe_rom_data, fe_ram_q);
	wire [15:0] fe_cdf_slot = fe_slot(fe_cdf_flags, fe_cdf_do, fe_cdf_oe, fe_cdf_ram_en, !fe_cdf_ram_write,
		fe_rom_data, fe_ram_q);
	wire  [7:0] fe_do_now = fe_is_cdf ? fe_cdf_slot[7:0] : fe_dpc_slot[7:0];
	wire  [7:0] fe_oe_now = fe_is_cdf ? fe_cdf_slot[15:8] : fe_dpc_slot[15:8];
	logic [7:0] fe_do_lag [8], fe_oe_lag [8];	// fe_mut 9 only: 1..8 clocks late
	always @(posedge clk_sys) begin
		fe_do_lag[0] <= fe_do_now;
		fe_oe_lag[0] <= fe_oe_now;
		for (int k = 1; k < 8; k++) begin
			fe_do_lag[k] <= fe_do_lag[k - 1];
			fe_oe_lag[k] <= fe_oe_lag[k - 1];
		end
	end
	wire  [7:0] fe_do = (fe_mut == 9 ? fe_do_lag[fe_lag - 1] : fe_do_now) ^ fe_flip_mask;
	wire  [7:0] fe_oe = fe_mut == 9 ? fe_oe_lag[fe_lag - 1] : fe_oe_now;
	wire  [7:0] fe_up_do = dut.cart2600.d_out;
	wire  [7:0] fe_up_oe = dut.cart2600.oe;
	wire  [2:0] fe_up_bank = fe_is_cdf ? dut.cart2600.cdf.bank : dut.cart2600.dpcplus.bank;
	wire  [2:0] fe_rf_bank = fe_is_cdf ? fe_ref_cdf.bank : fe_ref_dpc.bank;

	// ---- port equality, every clk_sys ------------------------------------------------------
	wire fe_dpc_port_eq =
		{fe_dpc_do, fe_dpc_flags, fe_dpc_oe, fe_dpc_rom_a, fe_dpc_ram_sel, fe_dpc_ram_rw, fe_dpc_ram_a,
		 fe_dpc_wf0, fe_dpc_wf1, fe_dpc_wf2, fe_dpc_note_write, fe_dpc_note_voice, fe_dpc_note_value,
		 fe_dpc_call_req, fe_dpc_svc_req, fe_dpc_svc_fill, fe_dpc_svc_source, fe_dpc_svc_dest,
		 fe_dpc_svc_count, fe_dpc_svc_value} ==
		{dut.cart2600.dpcplus.d_out, dut.cart2600.dpcplus.flags_out, dut.cart2600.dpcplus.oe,
		 dut.cart2600.dpcplus.rom_a, dut.cart2600.dpcplus.ram_sel, dut.cart2600.dpcplus.ram_rw,
		 dut.cart2600.dpcplus.ram_a, dut.cart2600.dpcplus.audio_waveform0,
		 dut.cart2600.dpcplus.audio_waveform1, dut.cart2600.dpcplus.audio_waveform2,
		 dut.cart2600.dpcplus.audio_note_write, dut.cart2600.dpcplus.audio_note_voice,
		 dut.cart2600.dpcplus.audio_note_value, dut.cart2600.dpcplus.call_request,
		 dut.cart2600.dpcplus.service_request, dut.cart2600.dpcplus.service_fill,
		 dut.cart2600.dpcplus.service_source, dut.cart2600.dpcplus.service_dest,
		 dut.cart2600.dpcplus.service_count, dut.cart2600.dpcplus.service_value};
	wire fe_cdf_port_eq =
		{fe_cdf_do, fe_cdf_flags, fe_cdf_oe, fe_cdf_rom_a, fe_cdf_tidx, fe_cdf_pu, fe_cdf_pu_index,
		 fe_cdf_pu_value, fe_cdf_ram_en, fe_cdf_ram_write, fe_cdf_ram_addr, fe_cdf_ram_wdata,
		 fe_cdf_digital, fe_cdf_call_req, fe_cdf_call_entry, fe_cdf_call_stack, fe_cdf_call_thumb,
		 fe_jump_valid} ==
		{dut.cart2600.cdf.d_out, dut.cart2600.cdf.flags_out, dut.cart2600.cdf.oe, dut.cart2600.cdf.rom_a,
		 dut.cart2600.cdf.table_index, dut.cart2600.cdf.pointer_update,
		 dut.cart2600.cdf.pointer_update_index, dut.cart2600.cdf.pointer_update_value,
		 dut.cart2600.cdf.ram_en, dut.cart2600.cdf.ram_write, dut.cart2600.cdf.ram_addr,
		 dut.cart2600.cdf.ram_wdata, dut.cart2600.cdf.digital_audio, dut.cart2600.cdf.call_request,
		 dut.cart2600.cdf.call_entry, dut.cart2600.cdf.call_stack, dut.cart2600.cdf.call_thumb,
		 dut.cart2600.fast_jump_valid};

	// First difference, by name: "" when equal.
`define FE_CMP(name, rf, up) if ((rf) != (up)) return $sformatf("%s %0h, upstream %0h", name, rf, up);
	function automatic string fe_port_dpc();
		`FE_CMP("d_out", fe_dpc_do, dut.cart2600.dpcplus.d_out)
		`FE_CMP("flags_out", fe_dpc_flags, dut.cart2600.dpcplus.flags_out)
		`FE_CMP("oe", fe_dpc_oe, dut.cart2600.dpcplus.oe)
		`FE_CMP("rom_a", fe_dpc_rom_a, dut.cart2600.dpcplus.rom_a)
		`FE_CMP("ram_sel", fe_dpc_ram_sel, dut.cart2600.dpcplus.ram_sel)
		`FE_CMP("ram_rw", fe_dpc_ram_rw, dut.cart2600.dpcplus.ram_rw)
		`FE_CMP("ram_a", fe_dpc_ram_a, dut.cart2600.dpcplus.ram_a)
		`FE_CMP("waveform0", fe_dpc_wf0, dut.cart2600.dpcplus.audio_waveform0)
		`FE_CMP("waveform1", fe_dpc_wf1, dut.cart2600.dpcplus.audio_waveform1)
		`FE_CMP("waveform2", fe_dpc_wf2, dut.cart2600.dpcplus.audio_waveform2)
		`FE_CMP("note_write", fe_dpc_note_write, dut.cart2600.dpcplus.audio_note_write)
		`FE_CMP("note_voice", fe_dpc_note_voice, dut.cart2600.dpcplus.audio_note_voice)
		`FE_CMP("note_value", fe_dpc_note_value, dut.cart2600.dpcplus.audio_note_value)
		`FE_CMP("call_request", fe_dpc_call_req, dut.cart2600.dpcplus.call_request)
		`FE_CMP("service_request", fe_dpc_svc_req, dut.cart2600.dpcplus.service_request)
		`FE_CMP("service_fill", fe_dpc_svc_fill, dut.cart2600.dpcplus.service_fill)
		`FE_CMP("service_source", fe_dpc_svc_source, dut.cart2600.dpcplus.service_source)
		`FE_CMP("service_dest", fe_dpc_svc_dest, dut.cart2600.dpcplus.service_dest)
		`FE_CMP("service_count", fe_dpc_svc_count, dut.cart2600.dpcplus.service_count)
		`FE_CMP("service_value", fe_dpc_svc_value, dut.cart2600.dpcplus.service_value)
		return "";
	endfunction
	function automatic string fe_port_cdf();
		`FE_CMP("d_out", fe_cdf_do, dut.cart2600.cdf.d_out)
		`FE_CMP("flags_out", fe_cdf_flags, dut.cart2600.cdf.flags_out)
		`FE_CMP("oe", fe_cdf_oe, dut.cart2600.cdf.oe)
		`FE_CMP("rom_a", fe_cdf_rom_a, dut.cart2600.cdf.rom_a)
		`FE_CMP("table_index", fe_cdf_tidx, dut.cart2600.cdf.table_index)
		`FE_CMP("pointer_update", fe_cdf_pu, dut.cart2600.cdf.pointer_update)
		`FE_CMP("pointer_update_index", fe_cdf_pu_index, dut.cart2600.cdf.pointer_update_index)
		`FE_CMP("pointer_update_value", fe_cdf_pu_value, dut.cart2600.cdf.pointer_update_value)
		`FE_CMP("ram_en", fe_cdf_ram_en, dut.cart2600.cdf.ram_en)
		`FE_CMP("ram_write", fe_cdf_ram_write, dut.cart2600.cdf.ram_write)
		`FE_CMP("ram_addr", fe_cdf_ram_addr, dut.cart2600.cdf.ram_addr)
		`FE_CMP("ram_wdata", fe_cdf_ram_wdata, dut.cart2600.cdf.ram_wdata)
		`FE_CMP("digital_audio", fe_cdf_digital, dut.cart2600.cdf.digital_audio)
		`FE_CMP("call_request", fe_cdf_call_req, dut.cart2600.cdf.call_request)
		`FE_CMP("call_entry", fe_cdf_call_entry, dut.cart2600.cdf.call_entry)
		`FE_CMP("call_stack", fe_cdf_call_stack, dut.cart2600.cdf.call_stack)
		`FE_CMP("call_thumb", fe_cdf_call_thumb, dut.cart2600.cdf.call_thumb)
		`FE_CMP("fast_jump_valid", fe_jump_valid, dut.cart2600.fast_jump_valid)
		return "";
	endfunction

	// C1: the DPC+ state the RTL makes observable (bench.md 7.3): the fetchers,
	// params 0-3 (4-7 are never read), min(parameter_pointer, 4), the random
	// number, bank, fast fetch, waveforms and the pending flags.
	function automatic string fe_c1();
		logic [3:0] pr, pu;
		for (int i = 0; i < 8; i++) begin
			`FE_CMP($sformatf("top[%0d]", i), fe_ref_dpc.top[i], dut.cart2600.dpcplus.top[i])
			`FE_CMP($sformatf("bottom[%0d]", i), fe_ref_dpc.bottom[i], dut.cart2600.dpcplus.bottom[i])
			`FE_CMP($sformatf("counter[%0d]", i), fe_ref_dpc.counter[i], dut.cart2600.dpcplus.counter[i])
			`FE_CMP($sformatf("fractional[%0d]", i), fe_ref_dpc.fractional[i], dut.cart2600.dpcplus.fractional[i])
			`FE_CMP($sformatf("increment[%0d]", i), fe_ref_dpc.increment[i], dut.cart2600.dpcplus.increment[i])
		end
		for (int i = 0; i < 4; i++)
			`FE_CMP($sformatf("params[%0d]", i), fe_ref_dpc.params[i], dut.cart2600.dpcplus.params[i])
		for (int i = 0; i < 3; i++)
			`FE_CMP($sformatf("waveform[%0d]", i), fe_ref_dpc.waveform[i], dut.cart2600.dpcplus.waveform[i])
		pr = fe_ref_dpc.parameter_pointer > 4 ? 4'd4 : fe_ref_dpc.parameter_pointer;
		pu = dut.cart2600.dpcplus.parameter_pointer > 4 ? 4'd4 : dut.cart2600.dpcplus.parameter_pointer;
		`FE_CMP("min(parameter_pointer, 4)", pr, pu)
		`FE_CMP("random_number", fe_ref_dpc.random_number, dut.cart2600.dpcplus.random_number)
		`FE_CMP("bank", fe_ref_dpc.bank, dut.cart2600.dpcplus.bank)
		`FE_CMP("fast_fetch", fe_ref_dpc.fast_fetch, dut.cart2600.dpcplus.fast_fetch)
		`FE_CMP("fast_pending", fe_ref_dpc.fast_pending, dut.cart2600.dpcplus.fast_pending)
		`FE_CMP("call_pending", fe_ref_dpc.call_pending, dut.cart2600.dpcplus.call_pending)
		`FE_CMP("service_pending", fe_ref_dpc.service_pending, dut.cart2600.dpcplus.service_pending)
		return "";
	endfunction

	// C2: the CDF state; the addresses only while they are read (bench.md 3.5).
	function automatic string fe_c2();
		`FE_CMP("bank", fe_ref_cdf.bank, dut.cart2600.cdf.bank)
		`FE_CMP("mode", fe_ref_cdf.mode, dut.cart2600.cdf.mode)
		`FE_CMP("fast_pending", fe_ref_cdf.fast_pending, dut.cart2600.cdf.fast_pending)
		if (dut.cart2600.cdf.fast_pending)
			`FE_CMP("fast_expected_address", fe_ref_cdf.fast_expected_address,
				dut.cart2600.cdf.fast_expected_address)
		`FE_CMP("jump_remaining", fe_ref_cdf.jump_remaining, dut.cart2600.cdf.jump_remaining)
		if (dut.cart2600.cdf.jump_remaining != 2'd0) begin
			`FE_CMP("expected_address", fe_ref_cdf.expected_address, dut.cart2600.cdf.expected_address)
			`FE_CMP("jump_stream", fe_ref_cdf.jump_stream, dut.cart2600.cdf.jump_stream)
		end
		`FE_CMP("call_pending", fe_ref_cdf.call_pending, dut.cart2600.cdf.call_pending)
		return "";
	endfunction
`undef FE_CMP

	// ---- counters ---------------------------------------------------------------------------
	typedef enum int {
		FC_LATCH,	// pclk0 edges under the checks (reads, writes, hidden)
		FC_COMMIT,	// access && a_in[12]
		FC_DOUT,	// L1 bad (taken read latches)
		FC_HID_BAD,	// L1 differs at a hidden pclk0 (information)
		FC_STATE,	// C1 / C2 bad
		FC_READ,	// L1 compared: taken read latches
		FC_WRITE,	// write latches
		FC_HIDDEN,	// hidden pclk0 edges
		FC_CYCLE,	// C1 / C2 compared: pclk1 edges
		FC_OE_WR,	// L2: oe differs on a write latch (information)
		FC_PORT,	// port bad
		FC_ROM,		// rom bad
		FC_L3,		// L3 bad
		FC_SHORT,	// E0 -> latch < 6 (live)
		FC_RAMTAP,	// ram bad: the independent RAM byte against port A's
		FC_PTRTAP,	// pointer bad: the independent pointer against table_pointer
		FC_RD_CART,	// L1 read latches the cartridge drives (upstream's oe != 0)
		FC_RD_RAM,	// ... whose byte is the reference's RAM byte, checked at its own address
		FC_RD_AMP,	// ... whose byte is the AMPLITUDE tap (not independent)
		FC_HID_LAST,	// hidden pclk0 that is the last before a release
		FC_HID_LBAD,	// ... and L1 differs there (information)
		FC_RAM_N,	// ram tap check: clocks compared
		FC_PTR_N,	// pointer tap check: clocks compared
		FC_N
	} fe_cnt_t;
	longint fe_tot [FC_N], fe_frm [FC_N];
	// C1/C2 coverage: at how many checked E0s upstream's state was off its
	// idle value, so a compare that only ever saw the idle value shows up.
	longint fe_cov [6];
	function automatic void fe_inc(input fe_cnt_t c);
		fe_tot[c]++;
		fe_frm[c]++;
	endfunction

	// S1 histograms: [0] running, before the checks; [1] live, MARIA's
	// phases; [2] live, the TIA's; [3] after the checks started, in a console
	// reset or before they resume. The last bin holds FE_HB-1 and more.
	localparam int FE_HB = 32;
	longint fe_h_e0p0 [4][FE_HB], fe_h_p0e0 [4][FE_HB], fe_h_cyc [4][FE_HB];
	function automatic int fe_bin(input longint d);
		return d >= FE_HB - 1 ? FE_HB - 1 : int'(d);
	endfunction

	// The bus ring: the last 64 clk_sys.
	typedef struct packed {
		logic [39:0] t;
		logic        p1, p0, phi2, acc, rw, stall, dma, tick;
		logic [12:0] a;
		logic  [7:0] din, up_do, up_oe, rf_do, rf_oe;
		logic  [2:0] up_bank, rf_bank;
`ifndef FE_STAGE0
		logic  [7:0] fu_do;		// stage 1: daria_fe's fe_do, fe_oe, bank, arm_call_busy, arm_dma_busy
		logic        fu_oe, fu_cb, fu_db;
		logic  [2:0] fu_bank;
`endif
	} fe_ring_t;
	fe_ring_t fe_ring [64];
	int       fe_ring_wp = 0;

	longint fe_clk = 0, fe_t_vs = 0, fe_t_e0 = -1, fe_t_p0 = -1, fe_t_arm = 0, fe_t_tia = -1, fe_t_live = 0;
	int     fe_reloads = 0, fe_reload_mis = 0, fe_rsyncs = 0, fe_handoffs = 0, fe_resets = 0, fe_nlive = 0;
	logic   fe_rsync_q = 0, fe_psrc_q = 0, fe_erst_q = 0;
	int     fe_frame = 0, fe_nfail = 0, fe_stop = 20, fe_fatal = 0, fe_jm_bad = 0, fe_jm_set = 0;
	int     fe_fmin = 99, fe_fmax = -1, fe_frame_arm = 0;
	logic   fe_old_vs = 0, fe_armed = 0, fe_live = 0, fe_l3_pend = 0, fe_jm_done = 0;
	logic   fe_hid_pend = 0, fe_hid_pend_bad = 0;
	logic   [7:0] fe_l3_exp = 0;
	int     fd_fe = 0, fd_fe_err = 0;
	int     fe_hr_at = 0, fe_hr_len = 1000, fe_hr_left = -1;

	function automatic string fe_scheme_name();
		if (fe_is_dpc) return "DPC+";
		if (fe_is_cdf)
			case (mapper_revision[1:0])
				2'd0: return "CDF0";
				2'd1: return "CDF1";
				2'd2: return "CDFJ";
				default: return "CDFJ+";
			endcase
		return $sformatf("scheme %0d", fe_scheme);
	endfunction

	function automatic string fe_src_name(input int s);
		if (s == 2) return "TIA";
		if (s == 1) return "MARIA";
		if (s == 3) return "reset";
		return "pre-check";
	endfunction

	task automatic fe_dump_ring();
`ifdef FE_STAGE0
		$fwrite(fd_fe_err, "  clk_sys    p1 p0 phi2 acc rw a_in d_in up_do/oe ref_do/oe up_bank ref_bank stall dma tick\n");
`else
		$fwrite(fd_fe_err, "  clk_sys    p1 p0 phi2 acc rw a_in d_in up_do/oe ref_do/oe up_bank ref_bank stall dma tick | fe_do/oe fe_bank fe_cbusy fe_dbusy\n");
`endif
		for (int k = 0; k < 64; k++) begin
			fe_ring_t r;
			r = fe_ring[(fe_ring_wp + k) % 64];
`ifdef FE_STAGE0
			$fwrite(fd_fe_err, "  %10d %0d  %0d  %0d    %0d   %0d  %04x %02x   %02x/%02x    %02x/%02x     %0d       %0d        %0d     %0d   %0d\n",
				r.t, r.p1, r.p0, r.phi2, r.acc, r.rw, r.a, r.din, r.up_do, r.up_oe, r.rf_do, r.rf_oe,
				r.up_bank, r.rf_bank, r.stall, r.dma, r.tick);
`else
			$fwrite(fd_fe_err, "  %10d %0d  %0d  %0d    %0d   %0d  %04x %02x   %02x/%02x    %02x/%02x     %0d       %0d        %0d     %0d   %0d    | %02x/%0d    %0d       %0d        %0d\n",
				r.t, r.p1, r.p0, r.phi2, r.acc, r.rw, r.a, r.din, r.up_do, r.up_oe, r.rf_do, r.rf_oe,
				r.up_bank, r.rf_bank, r.stall, r.dma, r.tick, r.fu_do, r.fu_oe, r.fu_bank, r.fu_cb, r.fu_db);
`endif
		end
	endtask

	task automatic fe_fail(input string cls, input string what);
		fe_nfail++;
		if (fe_nfail <= fe_stop) begin
			$fwrite(fd_fe_err, "%s at clk_sys %0d, frame %0d line %0d: pclk1 %0d pclk0 %0d phi2 %0d a_in %04x rw %0d d_in %02x, 6507 pc %04x: %s\n",
				cls, fe_clk, fe_frame, int'((fe_clk - fe_t_vs) / SYS_PER_LINE), dut.pclk1, dut.pclk0,
				dut.mapper_phi2, fe_a_in, fe_rw, fe_d_in, op_pc, what);
			if (fe_nfail <= 2) fe_dump_ring();
			if (fe_nfail == fe_stop) $fwrite(fd_fe_err, "(no more lines: +fe_stop=%0d)\n", fe_stop);
		end
		if (fe_fatal != 0) begin
			$display("FE stopped at the first failure (+fe_fatal): %s, %s", cls, what);
			$finish;
		end
	endtask

	task automatic fe_csv_line();
		$fwrite(fd_fe, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", fe_frame,
			fe_frm[FC_LATCH], fe_frm[FC_COMMIT], fe_frm[FC_DOUT], fe_frm[FC_HID_BAD], fe_frm[FC_STATE],
			fe_frm[FC_READ], fe_frm[FC_WRITE], fe_frm[FC_HIDDEN], fe_frm[FC_CYCLE], fe_frm[FC_PORT],
			fe_frm[FC_ROM], fe_frm[FC_L3], fe_fmax < 0 ? -1 : fe_fmin, fe_fmax, fe_frm[FC_SHORT],
			fe_frm[FC_RAMTAP], fe_frm[FC_PTRTAP], fe_frm[FC_RD_CART], fe_frm[FC_RD_RAM], fe_frm[FC_RD_AMP],
			fe_frm[FC_HID_LAST], fe_frm[FC_HID_LBAD]);
	endtask

	// ---- +hard_reset_at: a console reset pulse, timed in clk_sys --------------------------------
	// The frame counter stops while the TIA is in reset, so the length cannot
	// be counted in frames (bench.md 7.2).
	always @(posedge clk_sys) begin
		if (fe_hr_at != 0 && running && fe_hr_left < 0 && frame == fe_hr_at) begin
			reset_in = 1;
			fe_hr_left = fe_hr_len;
			$display("FE reset: +hard_reset_at drives the console reset from clk_sys %0d (frame %0d) for %0d clk_sys",
				now, frame, fe_hr_len);
		end else if (fe_hr_left > 0) begin
			fe_hr_left--;
			if (fe_hr_left == 0) reset_in = 0;
		end
	end

	// ---- the checks, on clk_sys ---------------------------------------------------------------
	always @(posedge clk_sys) begin
		int    src, d;
		logic  hidden, bad, ram_bad;
		string why;
		fe_clk++;

		// Frames: tb_daria's rule (the raw VSYNC bit's rising edge while running).
		// The clock that sees it belongs to the new frame.
		fe_old_vs <= vsync_raw;
		if (running && vsync_raw && !fe_old_vs) begin
			if (fe_frame > 0) fe_csv_line();
			fe_frame++;
			fe_t_vs = fe_clk;
			foreach (fe_frm[c]) fe_frm[c] = 0;
			fe_fmin = 99;
			fe_fmax = -1;
		end

		if (running) begin
			fe_ring[fe_ring_wp] = '{t: 40'(fe_clk), p1: dut.pclk1, p0: dut.pclk0, phi2: dut.mapper_phi2,
				acc: fe_access, rw: fe_rw, stall: dut.arm_call_stall, dma: dut.arm_dma_busy,
				tick: dut.cart2600.mapper_audio.audio_tick, a: fe_a_in, din: fe_d_in,
				up_do: fe_up_do, up_oe: fe_up_oe, rf_do: fe_do, rf_oe: fe_oe,
				up_bank: fe_up_bank, rf_bank: fe_rf_bank
`ifndef FE_STAGE0
				, fu_do: u_fe.fe_do, fu_oe: u_fe.fe_oe, fu_cb: u_fe.arm_call_busy, fu_db: u_fe.arm_dma_busy,
				fu_bank: u_fe.u_core.bank
`endif
				};
			fe_ring_wp = (fe_ring_wp + 1) % 64;
		end

		// The MARIA -> TIA phase handoffs (critic finding 15, bus.md B2), after the
		// first release and after every console reset. A line-end reload of the
		// TIA's divider (TIA.sv:565-567, hclk.edge_p2 && rsynd) changes the phase
		// only if pclk_div is not 1 just before it.
		if (running) begin
			fe_psrc_q <= dut.phase_source_tia;
			if (dut.phase_source_tia && !fe_psrc_q) begin
				fe_handoffs++;
				if (fe_t_tia < 0) fe_t_tia = fe_clk;
				if (fe_handoffs <= 5)
					$display("FE handoff: TIA phases from clk_sys %0d, %0d clk_sys after the checks %s (frame %0d)",
						fe_clk, fe_clk - fe_t_live, fe_nlive > 1 ? "resumed" : "started", fe_frame);
			end
			fe_rsync_q <= dut.tia_inst.rsync;
			if (dut.tia_inst.rsync && !fe_rsync_q) begin		// the 6507 wrote RSYNC
				fe_rsyncs++;
				if (fe_rsyncs <= 5)
					$display("FE handoff: RSYNC write at clk_sys %0d, frame %0d, %s phases on the bus, 6507 pc %04x",
						fe_clk, fe_frame, fe_src_name(dut.phase_source_tia ? 2 : 1), op_pc);
			end
			if (dut.tia_inst.clockgen.hclk.edge_p2 && dut.tia_inst.clockgen.rsynd) begin
				fe_reloads++;
				if (dut.tia_inst.clockgen.pclk_div != 3'd1) begin
					fe_reload_mis++;
					if (fe_reload_mis <= 5)
						$display("FE handoff: divider reload %0d with pclk_div %0d (re-phases the TIA divider) at clk_sys %0d, frame %0d, %s phases on the bus",
							fe_reloads, dut.tia_inst.clockgen.pclk_div, fe_clk, fe_frame,
							fe_src_name(dut.phase_source_tia ? 2 : 1));
				end
			end
			// A console reset after the checks started: they pause until the next
			// pclk1 with !effective_reset && tia_en.
			fe_erst_q <= dut.effective_reset;
			if (dut.effective_reset && !fe_erst_q && fe_nlive > 0) begin
				fe_resets++;
				if (fe_resets <= 5)
					$display("FE reset: console reset from clk_sys %0d (frame %0d); checks paused", fe_clk, fe_frame);
			end
		end
		if (dut.effective_reset) fe_live = 0;

		// The jump map, once the load is done: the reference's against the DUT's.
		if (running && !fe_jm_done) begin
			fe_jm_done = 1;
			for (int i = 0; i < 32768; i++) begin
				if (fe_ref_jump.map_ram.mem_q[i] != dut.cart2600.jump_table.map_ram.mem_q[i]) fe_jm_bad++;
				if (dut.cart2600.jump_table.map_ram.mem_q[i] != 0) fe_jm_set++;
			end
			if (fe_jm_bad != 0) fe_fail("jump", $sformatf("%0d map bits differ", fe_jm_bad));
		end

		if (running && (fe_is_dpc || fe_is_cdf)) begin
			// L3: the CPU latched, at the last pclk0, what was sampled there.
			if (fe_l3_pend) begin
				fe_l3_pend = 0;
				if (dut.cpu_inst.cpu.core.dp.dl != fe_l3_exp) begin
					fe_inc(FC_L3);
					fe_fail("L3", $sformatf("dp.dl %02x, sampled at pclk0 %02x", dut.cpu_inst.cpu.core.dp.dl, fe_l3_exp));
				end
			end

			// Tap checks, every clock.
			if (fe_is_dpc ? !fe_dpc_port_eq : !fe_cdf_port_eq) begin
				fe_inc(FC_PORT);
				fe_fail("port", fe_is_dpc ? fe_port_dpc() : fe_port_cdf());
			end
			if (fe_rom_q != cart_q) begin
				fe_inc(FC_ROM);
				fe_fail("rom", $sformatf("reference %02x, tb cart_q %02x", fe_rom_q, cart_q));
			end
			if (fe_up_men_q && fe_own_ra_q == fe_up_ra_q) begin
				fe_inc(FC_RAM_N);
				if (fe_own_rq != dut.cart2600.cartram_data) begin
					fe_inc(FC_RAMTAP);
					fe_fail("ram", $sformatf("independent byte %02x at $%05x, port A %02x", fe_own_rq,
						fe_own_ra_q, dut.cart2600.cartram_data));
				end
			end
			if (fe_is_cdf && fe_ptr_cmp_q) begin
				fe_inc(FC_PTR_N);
				if (fe_own_ptr != dut.cart2600.table_pointer) begin
					fe_inc(FC_PTRTAP);
					fe_fail("pointer", $sformatf("independent %08x, table_pointer %08x", fe_own_ptr,
						dut.cart2600.table_pointer));
				end
			end

			// S1, E0 from the pclk1 pulse. The interval that ends at an E0
			// belongs to the cycle before it, so it is binned before (re)arming.
			src = fe_live ? (dut.phase_source_tia ? 2 : 1) : (fe_nlive == 0 ? 0 : 3);
			if (dut.pclk1) begin
				if (fe_t_p0 >= 0) fe_h_p0e0[src][fe_bin(fe_clk - fe_t_p0)]++;
				if (fe_t_e0 >= 0) fe_h_cyc[src][fe_bin(fe_clk - fe_t_e0)]++;
				fe_t_e0 = fe_clk;
				if (!fe_live && !dut.effective_reset && dut.tia_en) begin
					fe_live = 1;
					fe_nlive++;
					fe_t_live = fe_clk;
					if (!fe_armed) begin
						fe_armed = 1;
						fe_t_arm = fe_clk;
						fe_frame_arm = fe_frame;
						$display("FE checks from clk_sys %0d (frame %0d), %s phases", fe_clk, fe_frame,
							fe_src_name(dut.phase_source_tia ? 2 : 1));
					end else if (fe_nlive <= 6)
						$display("FE reset: checks resume at clk_sys %0d (frame %0d), %s phases", fe_clk, fe_frame,
							fe_src_name(dut.phase_source_tia ? 2 : 1));
				end
				// The last hidden pclk0 of a stall: the next E0 reads RDY high, so
				// the core leaves the stall with that latch in DL (bus.md B7).
				if (fe_hid_pend && fe_live) begin
					if (dut.RDY) begin
						fe_inc(FC_HID_LAST);
						if (fe_hid_pend_bad) fe_inc(FC_HID_LBAD);
					end
				end
				fe_hid_pend = 0;
			end
			src = fe_live ? (dut.phase_source_tia ? 2 : 1) : (fe_nlive == 0 ? 0 : 3);
			if (dut.pclk0) begin
				if (fe_t_e0 >= 0) begin
					d = int'(fe_clk - fe_t_e0);
					fe_h_e0p0[src][fe_bin(d)]++;
					if (src == 1 || src == 2) begin
						if (d < fe_fmin) fe_fmin = d;
						if (d > fe_fmax) fe_fmax = d;
						if (d < 6) begin
							fe_inc(FC_SHORT);
							if (fe_tot[FC_SHORT] <= 10)
								$display("FE S1: E0->latch %0d at clk_sys %0d, frame %0d line %0d, %s phases", d,
									fe_clk, fe_frame, int'((fe_clk - fe_t_vs) / SYS_PER_LINE), fe_src_name(src));
						end
					end
				end
				fe_t_p0 = fe_clk;
			end

			if (fe_live) begin
				// L1 (and L2), at every pclk0.
				if (dut.pclk0) begin
					fe_inc(FC_LATCH);
					hidden = !dut.mapper_phi2;
					if (hidden) fe_inc(FC_HIDDEN);
					fe_hid_pend = 0;
					if (fe_rw) begin
						ram_bad = fe_ram_use && ((fe_own_byte ^ fe_ram_q) & fe_ram_mask) != 8'h00;
						bad = fe_oe != fe_up_oe || (fe_do & fe_oe) != (fe_up_do & fe_up_oe) || ram_bad;
						if (!hidden) begin
							fe_inc(FC_READ);
							if (fe_up_oe != 8'h00) fe_inc(FC_RD_CART);
							if (fe_ram_use) fe_inc(FC_RD_RAM);
							if (fe_amp_use) fe_inc(FC_RD_AMP);
							if (bad) begin
								fe_inc(FC_DOUT);
								fe_fail("L1 dout", ram_bad ?
									$sformatf("reference %02x/%02x, upstream %02x/%02x (d/oe); RAM byte at the reference's own address $%05x %02x, consumed %02x (mask %02x)",
										fe_do, fe_oe, fe_up_do, fe_up_oe, fe_own_ra_q, fe_own_byte, fe_ram_q, fe_ram_mask) :
									$sformatf("reference %02x/%02x, upstream %02x/%02x (d/oe)",
										fe_do, fe_oe, fe_up_do, fe_up_oe));
							end
						end else begin
							fe_hid_pend = 1;
							fe_hid_pend_bad = bad;
							if (bad) begin
								fe_inc(FC_HID_BAD);
								why = "";		// (a string ternary of literals pads with NULs)
								if (ram_bad) why = ", RAM byte at the reference's own address differs";
								fe_fail("L1 hidden (information)", $sformatf("reference %02x/%02x, upstream %02x/%02x (d/oe)%s",
									fe_do, fe_oe, fe_up_do, fe_up_oe, why));
							end
						end
					end else begin
						fe_inc(FC_WRITE);
						if (fe_oe != fe_up_oe) fe_inc(FC_OE_WR);
					end
					fe_l3_pend = 1;
					fe_l3_exp = dut.cpu_rwn ? dut.read_DB : dut.write_DB;
				end
				if (fe_access && fe_a_in[12]) fe_inc(FC_COMMIT);
				// C1 / C2, at every pclk1: the state the cycle before left.
				if (dut.pclk1) begin
					fe_inc(FC_CYCLE);
					if (fe_is_dpc) begin
						if (dut.cart2600.dpcplus.bank != 3'd5) fe_cov[0]++;
						if (dut.cart2600.dpcplus.fast_fetch) fe_cov[1]++;
						if (dut.cart2600.dpcplus.fast_pending) fe_cov[2]++;
						if (dut.cart2600.dpcplus.call_pending) fe_cov[3]++;
						if (dut.cart2600.dpcplus.service_pending) fe_cov[4]++;
						if (dut.cart2600.dpcplus.parameter_pointer != 4'd0) fe_cov[5]++;
					end else begin
						if (dut.cart2600.cdf.bank != (mapper_revision[1:0] == 2'd3 ? 3'd0 : 3'd6)) fe_cov[0]++;
						if (dut.cart2600.cdf.mode[3:0] == 4'd0) fe_cov[1]++;
						if (dut.cart2600.cdf.fast_pending) fe_cov[2]++;
						if (dut.cart2600.cdf.call_pending) fe_cov[3]++;
						if (dut.cart2600.cdf.jump_remaining != 2'd0) fe_cov[4]++;
						if (dut.cart2600.cdf.mode[7:4] == 4'd0) fe_cov[5]++;
					end
					why = fe_is_dpc ? fe_c1() : fe_c2();
					if (why != "") begin
						fe_inc(FC_STATE);
						fe_fail(fe_is_dpc ? "C1 state" : "C2 state", why);
					end
				end
			end

			// ---- injected faults (off by default) ----
			if (fe_bank_inj)
				$display("FE inject: a_in %04x seen as %04x at the hotspot %s commit %0d, clk_sys %0d (frame %0d): reference bank -> wrong",
					fe_up_a, fe_a_in, fe_rw ? "read" : "write", fe_bank_n + 1, fe_clk, fe_frame);
			if (fe_hot_now) fe_bank_n <= fe_bank_n + 1;
			if (fe_hot_all) begin
				if (fe_rw) fe_hot_rd_n <= fe_hot_rd_n + 1;
				else fe_hot_wr_n <= fe_hot_wr_n + 1;
			end
			if (fe_cnt_inj)
				$display("FE inject: DFxLOW write %0d to $%04x, d_in %02x seen as %02x, clk_sys %0d (frame %0d): counter %0d off by one",
					fe_cnt_n + 1, fe_up_a, dut.cart2600.d_in, fe_d_in, fe_clk, fe_frame, fe_up_a[2:0]);
			if (fe_dfl_now) fe_cnt_n <= fe_cnt_n + 1;
			if (fe_fpstuck != 0 && fe_live && !fe_fp_forced) begin
				fe_fp_forced = 1;
				if (fe_fpstuck == 1) force fe_ref_cdf.fast_pending = 1'b0;
				else force fe_ref_cdf.fast_pending = 1'b1;
				$display("FE inject: the reference's CDF fast_pending stuck at %0d from clk_sys %0d (frame %0d)",
					fe_fpstuck == 1 ? 0 : 1, fe_clk, fe_frame);
			end
			// +fe_flip: does the clock that ends at the next edge carry the flip?
			// A hidden latch is one inside a stall whose cycle was taken already.
			fe_flip_mask <= 8'h00;
			if (fe_flip != 0 && !fe_flip_done && fe_live && fe_tot[FC_CYCLE] >= fe_flip &&
				fe_clk > fe_t_e0 && fe_clk + 1 - fe_t_e0 == 6 + fe_flip_ofs &&
				dut.cart2600.rw && fe_up_a[12] &&
				(fe_flip_hidden != 0 ? dut.arm_call_stall && dut.stall_cycle_taken : !dut.arm_call_stall)) begin
				fe_flip_mask <= 8'(1 << fe_flip_bit);
				fe_flip_done = 1;
				why = "";
				if (fe_flip_hidden != 0) why = ", hidden";
				$display("FE inject: reference slot byte bit %0d flipped on the clock ending at clk_sys %0d (E0+%0d; the latch is E0+6%s), a_in %04x, frame %0d",
					fe_flip_bit, fe_clk + 1, 6 + fe_flip_ofs, why, fe_up_a, fe_frame);
			end
			// +fe_bank_spur: is the clock that ends at the next edge E0+8 of the cycle?
			fe_spur_on <= 1'b0;
			if (fe_bank_spur != 0 && !fe_spur_done && fe_live && fe_tot[FC_CYCLE] >= fe_bank_spur &&
				fe_clk > fe_t_e0 && fe_clk + 1 - fe_t_e0 == 8) begin
				logic [2:0] b;
				b = fe_rf_bank;
				fe_spur_on <= 1'b1;
				fe_spur_done = 1;
				// DPC+ $1FF6-$1FFB are banks 0-5; CDF $1FF5-$1FFA are 0-5 (CDFJ+ 1-6)
				if (fe_is_dpc) fe_spur_a <= 13'h1FF6 + 13'(b == 3'd5 ? 3'd0 : b + 3'd1);
				else fe_spur_a <= (b == (mapper_revision[1:0] == 2'd3 ? 3'd1 : 3'd0)) ? 13'h1FF6 : 13'h1FF5;
				$display("FE inject: a hotspot write only the reference sees, on the clock ending at clk_sys %0d (E0+8), frame %0d: its bank %0d -> wrong",
					fe_clk + 1, fe_frame, b);
			end
		end
	end

	initial begin
		foreach (fe_tot[c]) begin fe_tot[c] = 0; fe_frm[c] = 0; end
		foreach (fe_cov[c]) fe_cov[c] = 0;
		for (int s = 0; s < 4; s++)
			for (int b = 0; b < FE_HB; b++) begin
				fe_h_e0p0[s][b] = 0;
				fe_h_p0e0[s][b] = 0;
				fe_h_cyc[s][b] = 0;
			end
		void'($value$plusargs("fe_stop=%d", fe_stop));
		void'($value$plusargs("fe_fatal=%d", fe_fatal));
		void'($value$plusargs("fe_mut=%d", fe_mut));
		void'($value$plusargs("fe_lag=%d", fe_lag));
		void'($value$plusargs("fe_flip=%d", fe_flip));
		void'($value$plusargs("fe_flip_ofs=%d", fe_flip_ofs));
		void'($value$plusargs("fe_flip_bit=%d", fe_flip_bit));
		void'($value$plusargs("fe_bank=%d", fe_bank));
		void'($value$plusargs("fe_bank_wr=%d", fe_bank_wr));
		void'($value$plusargs("fe_cnt=%d", fe_cnt));
		void'($value$plusargs("fe_fpstuck=%d", fe_fpstuck));
		void'($value$plusargs("fe_flip_hidden=%d", fe_flip_hidden));
		void'($value$plusargs("fe_bank_spur=%d", fe_bank_spur));
		void'($value$plusargs("hard_reset_at=%d", fe_hr_at));
		void'($value$plusargs("hard_reset_len=%d", fe_hr_len));
		if (fe_lag < 1) fe_lag = 1;
		if (fe_lag > 8) fe_lag = 8;
		if (fe_flip_ofs < -4) fe_flip_ofs = -4;
		if (fe_flip_ofs > 5) fe_flip_ofs = 5;
		fe_flip_bit &= 7;
		if (fe_hr_len < 1) fe_hr_len = 1;
		for (int k = 0; k < 8; k++) begin fe_rom_lag[k] = 8'hFF; fe_do_lag[k] = 0; fe_oe_lag[k] = 0; end
		if (fe_mut != 0) $display("FE self-test: a tap broken on purpose, +fe_mut=%0d (+fe_lag=%0d)", fe_mut, fe_lag);
		if (fe_flip != 0 || fe_bank != 0 || fe_cnt != 0 || fe_fpstuck != 0 || fe_bank_spur != 0)
			$display("FE self-test: fault injection +fe_flip=%0d (ofs %0d, bit %0d, hidden %0d) +fe_bank=%0d (writes only %0d) +fe_bank_spur=%0d +fe_cnt=%0d +fe_fpstuck=%0d",
				fe_flip, fe_flip_ofs, fe_flip_bit, fe_flip_hidden, fe_bank, fe_bank_wr, fe_bank_spur, fe_cnt, fe_fpstuck);
		#1;
`ifdef FE_STAGE0
		fd_fe = $fopen({out, "fe.csv"}, "w");
`else
		fd_fe = $fopen({out, "fe_ref.csv"}, "w");	// stage 1: the reference's columns; fe.csv is daria_fe's
`endif
		$fwrite(fd_fe, "frame,latches,commits,dout_bad,dout_hidden,state_bad,reads,writes,hidden,cycles,port_bad,rom_bad,l3_bad,e0_latch_min,e0_latch_max,e0_short,ram_bad,pointer_bad,cart_reads,ram_reads,amp_reads,hidden_last,hidden_last_bad\n");
		fd_fe_err = $fopen({out, "fe_err.txt"}, "w");
	end

	function automatic string fe_hist(input int s, input int which);
		string h;
		longint n;
		h = "";
		for (int b = 0; b < FE_HB; b++) begin
			n = which == 0 ? fe_h_e0p0[s][b] : which == 1 ? fe_h_p0e0[s][b] : fe_h_cyc[s][b];
			if (n != 0) begin
				if (h.len() != 0) h = {h, " "};
				if (b == FE_HB - 1) h = {h, $sformatf("%0d+:%0d", b, n)};
				else h = {h, $sformatf("%0d:%0d", b, n)};
			end
		end
		if (h.len() == 0) h = "-";
		return h;
	endfunction

	final begin
		int lo, hi;
		string rng;
		lo = -1;
		hi = -1;
		for (int b = 0; b < FE_HB; b++)
			if (fe_h_e0p0[1][b] != 0 || fe_h_e0p0[2][b] != 0) begin
				if (lo < 0) lo = b;
				hi = b;
			end
		rng = lo < 0 ? "none" : $sformatf("%0d..%0d", lo, hi);
`ifndef FE_STAGE0
		f1_report();			// stage 1: daria_fe's lines first ("FE shadow:", ...)
`endif
		if (!fe_is_dpc && !fe_is_cdf)
`ifdef FE_STAGE0
			$display("FE shadow: %s not shadowed", fe_scheme_name());
`else
			$display("FE reference: %s not shadowed", fe_scheme_name());
`endif
		else begin
`ifdef FE_STAGE0
			$display("FE shadow: %s %0d latches, %0d commits; dout %0d, state %0d bad; E0->latch %s",
				fe_scheme_name(), fe_tot[FC_LATCH], fe_tot[FC_COMMIT], fe_tot[FC_DOUT], fe_tot[FC_STATE], rng);
`else
			// The stage-0 reference instance beside daria_fe (design 12.4): its own line.
			$display("FE reference: %s %0d latches, %0d commits; dout %0d, state %0d bad; E0->latch %s",
				fe_scheme_name(), fe_tot[FC_LATCH], fe_tot[FC_COMMIT], fe_tot[FC_DOUT], fe_tot[FC_STATE], rng);
`endif
			$display("FE detail: %0d read latches compared, %0d hidden pclk0 (%0d differ, information), %0d write latches (oe differs %0d, information); %0d cycles compared (%s); port %0d, rom %0d, ram %0d, pointer %0d, jump map %0d, L3 %0d bad; %0d failures logged; checks from clk_sys %0d (frame %0d)",
				fe_tot[FC_READ], fe_tot[FC_HIDDEN], fe_tot[FC_HID_BAD], fe_tot[FC_WRITE], fe_tot[FC_OE_WR],
				fe_tot[FC_CYCLE], fe_is_dpc ? "C1" : "C2", fe_tot[FC_PORT], fe_tot[FC_ROM], fe_tot[FC_RAMTAP],
				fe_tot[FC_PTRTAP], fe_jm_bad, fe_tot[FC_L3], fe_nfail, fe_t_arm, fe_frame_arm);
			$display("FE reads: of the %0d read latches, %0d driven by the cartridge, %0d with a RAM byte (checked at the reference's own address), %0d with the AMPLITUDE tap (not independent); %0d hidden pclk0 were the last of a stall (%0d differ, information); tap checks compared ram %0d, pointer %0d clocks; jump map %0d bits set; %0d hotspot commits (%0d reads, %0d writes), %0d DFxLOW writes",
				fe_tot[FC_READ], fe_tot[FC_RD_CART], fe_tot[FC_RD_RAM], fe_tot[FC_RD_AMP], fe_tot[FC_HID_LAST],
				fe_tot[FC_HID_LBAD], fe_tot[FC_RAM_N], fe_tot[FC_PTR_N], fe_jm_set,
				fe_hot_rd_n + fe_hot_wr_n, fe_hot_rd_n, fe_hot_wr_n, fe_cnt_n);
			if (fe_is_dpc)
				$display("FE coverage: of %0d checked E0s, upstream had bank != 5 at %0d, fast_fetch on %0d, fast_pending %0d, call_pending %0d, service_pending %0d, parameter_pointer != 0 %0d",
					fe_tot[FC_CYCLE], fe_cov[0], fe_cov[1], fe_cov[2], fe_cov[3], fe_cov[4], fe_cov[5]);
			else
				$display("FE coverage: of %0d checked E0s, upstream had bank != its reset value at %0d, fast mode %0d, fast_pending %0d, call_pending %0d, jump_remaining != 0 %0d, digital audio mode %0d",
					fe_tot[FC_CYCLE], fe_cov[0], fe_cov[1], fe_cov[2], fe_cov[3], fe_cov[4], fe_cov[5]);
			for (int s = 0; s < 4; s++) begin
				string lbl;
				if (s == 0) lbl = "before the checks";
				else if (s == 1) lbl = "checked, MARIA phases";
				else if (s == 2) lbl = "checked, TIA phases";
				else lbl = "in a console reset, until the checks resume";
				if (s < 3 || fe_resets != 0)
					$display("FE spacing, %s: E0->latch {%s}; latch->E0 {%s}; E0->E0 {%s}",
						lbl, fe_hist(s, 0), fe_hist(s, 1), fe_hist(s, 2));
			end
			$display("FE S1: %0d latches with E0->latch < 6", fe_tot[FC_SHORT]);
			$display("FE reloads: %0d reloads of the TIA divider (line ends and RSYNC) while running, %0d with pclk_div != 1 (re-phasing); %0d RSYNC writes",
				fe_reloads, fe_reload_mis, fe_rsyncs);
			$display("FE resets: %0d console resets after the checks started, %0d starts of the checks, %0d handoffs to the TIA's phases",
				fe_resets, fe_nlive, fe_handoffs);
		end
		if (fd_fe_err != 0) begin
`ifdef FE_STAGE0
			if (fe_nfail == 0) $fwrite(fd_fe_err, "no failures\n");
`else
			if (fe_nfail == 0 && f1_nfail == 0) $fwrite(fd_fe_err, "no failures\n");
`endif
			$fclose(fd_fe_err);
		end
		if (fd_fe != 0) $fclose(fd_fe);
	end
