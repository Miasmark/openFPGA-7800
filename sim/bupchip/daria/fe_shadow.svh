//------------------------------------------------------------------------------
// The front-end shadow (DARIA step 6): included at the end of tb_daria.sv
// with -DFE_SHADOW (run_daria.sh with FE=1).
//
// Two stages share this file.
//
// STAGE 1 (the default; docs/daria_fe/design.md 12.4, bench.md 7.4-7.7):
// daria_fe itself (u_fe) on its own daria_mem (fe_mem), in mode A (upstream's
// ARM runs the calls), beside the stage-0 reference below, which stays as a
// check of the taps. Every input of u_fe is a continuous assign of a DUT
// signal or NBA-updated bench state: cart_win emulated from the download
// (bup_capture's window), cpu_ready as design 6.6, upstream's CPU writes
// mirrored into fe_mem's cart RAM port A (writeback and DMA left out), the
// returns written into state RAM F8-FD at the clk_arm edges upstream's
// controller captures them, ret_tog flipped with upstream's complete_toggle
// once u_fe has posted that call (per call number), the sample port answered
// after +fe_slat clk_sys, the merge hook (+fe_merge_hook=1), the sticky hold
// (fe_hold_reset, tb_daria's reset term) and the forced arm_call_stall that
// covers u_fe's arm_dma_busy (H1 checks it). fe_taps.svh maps u_fe's state
// to upstream's. The checks of design 12.4 (L1, commit_on_hidden,
// hidden_last_bad, C1-C4, R1-R3, I1/I2, K1/K2, T1-T4, A1-A3, O1, H1, the RTL
// assertions) and the counted classes of 9.5 are in the stage-1 section
// (f1_*). Outputs: fe.csv (daria_fe's, one line a frame), fe_ref.csv (the
// reference's), fe_err.txt (both; the first two daria_fe failures with the
// 64-clock ring), and the run.log lines "FE stage 1:", "FE load:", "FE
// init:", "FE service ...", then "FE shadow:" (bench.md 7.7's line), "FE
// bad:", "FE classes:", "FE counts:", "FE inputs:", "FE latency:", "FE
// result:", and the reference's "FE reference:" and stage-0 lines below.
// Plusargs: +fe_merge_hook=1, +fe_slat=N (40), +fe_hold=0/1 (1),
// +fe_resync=0/1 (1), +fe_full=N (K2 every N frames, 1), +fe_ticks=1
// (fe_ticks.csv), +fe_pcm=1 (amp_up.pcm, amp_fe.pcm), +fe_mask_max=N (20000:
// mask_stuck), and the self-test +fe1_inj=K +fe1_inj_at=N (one fault in u_fe
// or fe_mem; see there). Added by the lane's verification (E1_shadow.md,
// "Verification"): T5 (ROM-sample amplitudes paired in order), merge_late,
// dma_cover, mask_stuck, the "FE masks:" line; pause_lane narrowed to lane
// B's condition; rmw_seed/rmw_merge bounded to one tick / k ticks.
//
// STAGE 0 (alone with -DFE_STAGE0, run_daria.sh FE_STAGE0=1, as built before
// daria_fe existed; the text below):
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

`ifndef FE_STAGE0
	// =================================================================================
	// Stage 1 (design 12.4; bench.md 7.4-7.7): daria_fe as u_fe, on its own
	// daria_mem (fe_mem), beside the reference above. Mode A: upstream's ARM runs
	// the calls; u_fe's stall outputs never drive the 6507, except through the
	// forced arm_call_stall of the hold (7.4.2).
	// =================================================================================
	int          fe_slat = 40, fe_merge_hook = 0, fe_hold = 1, fe_resync = 1, fe_full = 1;
	int          fe_ticks = 0, fe_pcm = 0;

	// ---- u_fe's inputs: continuous assigns of DUT signals, or NBA-updated bench state ----
	wire         f1_load_start = ~old_cart_download && cart_download;
	wire         f1_load_end   = old_cart_download && ~cart_download;
	// cart_win: bup_capture's window (bup_capture.sv:141-164): open from the
	// download's start until DRAIN = 64 clocks after its end. The bench's own
	// blocks take the download's edges from the cart_download level through a
	// private copy, not from the load_start/load_end pulses: tb_daria writes
	// cart_download with a blocking assignment in an initial block at a clock
	// edge, and a block that runs before that write in the time step, while
	// tb_daria's old_cart_download flop runs after it, would never see the
	// pulse (seen in a build of this file: I1 never armed). The edge seen here
	// can be one clock off the DUT's; the window's fall only starts F6
	// (bounded by the hold). u_fe's own load_start/load_end stay the DUT's
	// expressions, as bench.md 1.3 asks.
	logic        f1_c_open = 1'b0, f1_cw_q = 1'b0;
	logic  [6:0] f1_c_drain = 7'd0;
	always @(posedge clk_sys) begin
		if (cart_download && !f1_cw_q) begin
			f1_c_open <= 1'b1;
			f1_c_drain <= 7'd0;
		end else if (!cart_download && f1_cw_q && f1_c_open) begin
			f1_c_open <= 1'b0;
			f1_c_drain <= 7'd64;
		end else if (f1_c_drain != 7'd0)
			f1_c_drain <= f1_c_drain - 7'd1;
		f1_cw_q = cart_download;
	end
	wire         f1_cart_win = cart_download || f1_c_open || f1_c_drain > 7'd1;
	// cpu_ready, design 6.6 (critic 8): upstream's call_ready without call_busy
	wire         f1_cpu_ready = dut.cart2600.arm_mappers.call_controller.arm_online_sync2 &&
		dut.cart2600.arm_mappers.call_controller.shadow_ready_sync2 && !dut.effective_reset;
	// The ARM-write mirror (7.4.3): upstream's CPU writes into fe_mem's cart RAM
	// port A at the clk_arm edge cart_ram_tdp takes them; the writeback and DMA
	// writes (init, DPC+ service) are left out: daria_fe makes those itself.
	wire  [31:0] f1_d_addr = {15'd0, dut.arm_ram_addr, 2'b00};
	wire         f1_ram_we = dut.cart_ram.arm_allow && dut.arm_ram_write && !dut.cart2600.mapper_wb_en &&
		!dut.cart2600.arm_mappers.memory.dma_ram_en;
	// The returns (7.4.4): state RAM F8-FD at the clk_arm edges upstream's
	// controller captures them (CTRL_CAPTURE_AUDIO = 8, arm_mapper_controller.sv:338-345).
	wire         f1_cap_audio = ctl_state == 4'd8 && !dut.cart2600.arm_mappers.mapper_reset_arm && !arm_reset;
	wire   [2:0] f1_rd_idx = dut.cart2600.arm_mappers.call_controller.audio_read_index;
	wire   [7:0] f1_sta_addr = 8'hF8 + {5'd0, f1_rd_idx};
	wire  [31:0] f1_sta_wd = dut.cart2600.arm_mappers.call_controller.state_rdata;
	wire         f1_up_cmp = f1_cap_audio && f1_rd_idx == 3'd5;	// complete_toggle flips at this clk_arm edge
	// The front-end ROM takes the cartridge's bytes as the wrapper does (bupchip_pocket.sv:354)
	wire         f1_cap_we = ioctl_wr && cart_download && ioctl_addr[24:15] == 10'd0;
	// The merge hook (+fe_merge_hook=1; design 6.6): upstream's call_done and returns
	wire         f1_hk_en = fe_merge_hook != 0;
	wire         f1_hk_stb = dut.cart2600.arm_call_done;
	wire [191:0] f1_hk_ret = {dut.cart2600.arm_audio_frequency2_return, dut.cart2600.arm_audio_frequency1_return,
		dut.cart2600.arm_audio_frequency0_return, dut.cart2600.arm_audio_counter2_return,
		dut.cart2600.arm_audio_counter1_return, dut.cart2600.arm_audio_counter0_return};

	// ret_tog per call number (6.6): it flips with upstream's complete_toggle, on
	// the same clk_arm edge, once u_fe has flipped call_tog for that call; if
	// u_fe's flip comes later, at the first clk_arm edge after it (ret_late).
	// Upstream's flip is predicted from the controller's own condition, so the
	// two toggles change on one edge; f1_ctog_model checks the prediction.
	logic        f1_ret_tog = 1'b0, f1_tog_q = 1'b0, f1_ctog_model = 1'b0;
	int          f1_up_done = 0, f1_ret_n = 0, f1_fe_flips = 0, f1_ret_late_n = 0, f1_ctog_bad = 0;
	always @(posedge clk_sys) begin
		f1_tog_q <= u_fe.call_tog;
		if (dut.effective_reset) f1_fe_flips <= 0;
		else if (u_fe.call_tog != f1_tog_q) f1_fe_flips <= f1_fe_flips + 1;
	end
	always @(posedge clk_arm) begin
		int done, flipped;
		if (dut.cart2600.arm_mappers.call_controller.complete_toggle != f1_ctog_model) f1_ctog_bad <= f1_ctog_bad + 1;
		if (arm_reset) f1_ctog_model <= 1'b0;
		else if (dut.cart2600.arm_mappers.mapper_reset_arm)
			f1_ctog_model <= dut.cart2600.arm_mappers.call_controller.complete_ack_sync2;
		else if (f1_up_cmp) f1_ctog_model <= ~f1_ctog_model;
		if (dut.effective_reset || dut.cart2600.arm_mappers.mapper_reset_arm) begin
			f1_up_done <= 0;			// a call cut by a console reset is abandoned on both sides
			f1_ret_n <= 0;
		end else begin
			done = f1_up_done + (f1_up_cmp ? 1 : 0);
			flipped = f1_fe_flips + ((u_fe.call_tog != f1_tog_q) ? 1 : 0);
			f1_up_done <= done;
			if (f1_ret_n < done && f1_ret_n < flipped) begin
				f1_ret_tog <= ~f1_ret_tog;
				f1_ret_n <= f1_ret_n + 1;
				if (!(f1_up_cmp && f1_ret_n + 1 == done)) f1_ret_late_n <= f1_ret_late_n + 1;
			end
		end
	end

	// The digital-sample port (7.4.5): answer smp_req with img[smp_addr] after
	// +fe_slat clk_sys, the byte held from the answer on.
	logic        f1_smp_ack = 1'b0, f1_smp_rq = 1'b0;
	logic  [7:0] f1_smp_data = 8'h00;
	logic [18:0] f1_smp_a = 19'd0;
	int          f1_smp_left = -1;
	always @(posedge clk_sys) begin
		f1_smp_rq <= u_fe.smp_req;
		if (u_fe.smp_req != f1_smp_rq) begin
			f1_smp_a <= u_fe.smp_addr;
			f1_smp_left <= fe_slat;
		end else if (f1_smp_left > 0)
			f1_smp_left <= f1_smp_left - 1;
		else if (f1_smp_left == 0) begin
			f1_smp_data <= img[f1_smp_a];
			f1_smp_ack <= ~f1_smp_ack;
			f1_smp_left <= -1;
		end
	end

	// ---- fe_mem and u_fe ----------------------------------------------------------------
	wire  [12:0] fu_fea_addr, fu_feb_addr, fu_crb_addr;
	wire  [31:0] fu_fea_q, fu_feb_q, fu_crb_q, fu_stb_q, fu_crb_wd, fu_stb_wd;
	wire         fu_crb_we, fu_stb_we;
	wire   [3:0] fu_crb_be, fu_stb_be;
	wire   [7:0] fu_stb_addr;

	daria_mem #(.WIN_KB(32)) fe_mem (
		.clk_arm(clk_arm), .clk_sys(clk_sys),
		.rom_addr(15'd0), .win_qa(), .d_addr(f1_d_addr), .win_qb(),
		.ram_we(f1_ram_we), .ram_be(dut.arm_ram_wstrb), .ram_wdata(dut.arm_ram_wdata), .ram_q(),
		.img_ready(1'b1), .win_we(1'b0), .win_wa(15'd0), .win_wd(32'd0), .win_be(4'd0),
		.sta_addr(f1_sta_addr), .sta_we(f1_cap_audio), .sta_wd(f1_sta_wd), .sta_q(),
		.cap_we(f1_cap_we), .cap_addr(ioctl_addr[14:0]), .cap_data(ioctl_dout),
		.fea_addr(fu_fea_addr), .fea_q(fu_fea_q), .feb_addr(fu_feb_addr), .feb_q(fu_feb_q),
		.crb_addr(fu_crb_addr), .crb_we(fu_crb_we), .crb_be(fu_crb_be), .crb_wd(fu_crb_wd), .crb_q(fu_crb_q),
		.stb_addr(fu_stb_addr), .stb_we(fu_stb_we), .stb_be(fu_stb_be), .stb_wd(fu_stb_wd), .stb_q(fu_stb_q));

	daria_fe u_fe (
		.clk_sys, .clk_arm,
		.cart_reset(dut.effective_reset), .pause(dut.pause),
		.a_in(dut.cart2600.a_in), .d_in(dut.write_DB), .rw(dut.RW),
		.pclk1(dut.pclk1), .pclk0(dut.pclk0), .access(dut.cart2600.arm_access),
		.scheme(force_bs), .revision(mapper_revision), .cdf_ldx, .cdf_ldy,
		.fetch_off_en(cdf_fetch_offset_enable), .fetch_off(cdf_fetch_offset), .cdfj_entry, .cdfj_stack,
		.audio_size_addr(arm_audio_size_addr), .rom_size(cart_size), .ram32(dut.mapper_ram_size == 16'd32768),
		.load_start(f1_load_start), .load_end(f1_load_end), .cart_win(f1_cart_win),
		.cpu_ready(f1_cpu_ready), .ret_tog(f1_ret_tog), .call_tog(),
		.smp_req(), .smp_addr(), .smp_ack(f1_smp_ack), .smp_data(f1_smp_data),
		.fe_do(), .fe_oe(), .arm_call_busy(), .arm_dma_busy(), .init_busy(),
		.fea_addr(fu_fea_addr), .fea_q(fu_fea_q), .feb_addr(fu_feb_addr), .feb_q(fu_feb_q),
		.crb_addr(fu_crb_addr), .crb_we(fu_crb_we), .crb_be(fu_crb_be), .crb_wd(fu_crb_wd), .crb_q(fu_crb_q),
		.stb_addr(fu_stb_addr), .stb_we(fu_stb_we), .stb_be(fu_stb_be), .stb_wd(fu_stb_wd), .stb_q(fu_stb_q),
		.hk_en(f1_hk_en), .hk_stb(f1_hk_stb), .hk_ret(f1_hk_ret));

`include "fe_taps.svh"

	// ---- the hold (7.4.2): the console stays in reset until both inits are done ----------
	// Sticky, so the reset never drops between upstream's init and daria_fe's F6:
	// set at load_start and at a console reset edge, released once u_fe.init_busy
	// was seen high and has fallen (or after 2^20 clk_sys: fe_init_never_busy).
	logic        f1_seen_busy = 1'b0, f1_rst_q = 1'b0, f1_loaded = 1'b0;
	int          f1_hold_cnt = 0, f1_never_busy = 0;
	always @(posedge clk_sys) begin
		f1_rst_q <= dut.effective_reset;
		if (cart_download) f1_loaded <= 1'b1;			// (the level: see cart_win above)
		if (cart_download || (f1_loaded && dut.effective_reset && !f1_rst_q)) begin
			fe_hold_reset <= fe_hold != 0;
			f1_seen_busy <= 1'b0;
			f1_hold_cnt <= 0;
		end else if (fe_hold_reset) begin
			f1_hold_cnt <= f1_hold_cnt + 1;
			if (u_fe.init_busy) f1_seen_busy <= 1'b1;
			else if (f1_seen_busy || f1_hold_cnt >= (1 << 20)) begin
				fe_hold_reset <= 1'b0;
				if (!f1_seen_busy) f1_never_busy <= f1_never_busy + 1;
			end
		end
	end
	// The forced stall, constant right-hand side, at the falling edge (7.4.2,
	// question 3): top.sv's own assign covers upstream's busys; the force adds
	// u_fe's DPC+ copy/fill (arm_dma_busy) while upstream's has fallen.
	logic        f1_forced = 1'b0;
	always @(negedge clk_sys) begin
		if (fe_hold != 0 && dut.tia_en && !dut.mapper_init_busy && u_fe.arm_dma_busy) begin
			if (!f1_forced) begin
				force dut.arm_call_stall = 1'b1;
				f1_forced = 1'b1;
			end
		end else if (f1_forced) begin
			release dut.arm_call_stall;
			f1_forced = 1'b0;
		end
	end

	// ---- counters ---------------------------------------------------------------------
	typedef enum int {
		// bench.md 7.7's fe.csv columns, in its order
		G_LATCH, G_COMMIT, G_DOUT, G_DOUT_HID, G_STATE, G_PTR, G_RAM, G_CALLS_UP, G_CALLS_FE, G_CALL_BAD,
		G_SVC, G_SVC_BAD, G_TICKS, G_TICK_BAD, G_AUDIO_BAD, G_AMP_LAG, G_NOTE_RACE, G_MERGE_RACE,
		G_SEED_RACE, G_RESYNC, G_DRIFT_UP, G_DRIFT_FE, G_OBUS, G_OVER32K, G_HOLD_BAD,
		// design 12.4's additions
		G_MERGE_AMP, G_RET_LATE, G_DIG_ROM_LAG, G_SVC_AUDIO_RACE, G_PAUSE_LANE, G_PRE_LOCK, G_TBL_ALIAS,
		G_RMW_CALL, G_RMW_SVC, G_SHORT_PHASE1, G_GRANT_STEAL,
		G_A_COLLIDE, G_A_WB_LATE, G_A_P32_LATE, G_A_GUARD_CORE, G_A_GUARD_WR, G_A_OWNER, G_A_FPJR,
		G_A_PEND_LATE, G_A_TDEF2, G_A_F6_LIVE, G_CRB_USE,
		// the rest of 9.5 / 9.6, the tap checks, and information
		G_SVC_RAM_BAD, G_INIT_BAD, G_RAM_CALL_BAD, G_RAM_FRAME_BAD, G_HID_LAST, G_HID_LAST_BAD,
		G_COMMIT_HIDDEN, G_RET_UNASKED, G_A2_BAD, G_A3_BAD, G_SIZE_OVER32K, G_P32_RESET, G_WB_DROP,
		G_RAM_WR_NOACC, G_DET_LOCK_A, G_DIG_BAD, G_ROM_BAD, G_DIN_BAD, G_RET_MODEL_BAD, G_INIT_NEVER,
		G_READS, G_HIDDEN, G_CYCLES, G_PTR_N, G_RAM_N, G_K1, G_K2, G_INIT_N, G_SVC_FE, G_MERGES, G_HK_MERGES,
		G_AMP_READS, G_AMP_CLASS, G_SHORT_DOUT, G_Q26, G_SHORT_IMAGE, G_RMW_SEED, G_DEPOSIT_CF,
		G_DROP_UP, G_DROP_FE, G_R3_N, G_FORCED, G_RMW_MERGE,
		G_DIG_LOCAL, G_DIG_REMOTE, G_DIG_RAM, G_DIG_NONE,
		// added by the lane's verification (E1_shadow.md, "Verification")
		G_MERGE_LATE, G_DMA_COVER, G_MASK_STUCK, G_MASKED, G_DIG_VAL_BAD, G_DIG_VAL_N, G_DIG_VAL_MRG,
		G_N
	} f1_cnt_t;
	string       f1_nm [G_N];
	logic        f1_bad [G_N];		// must be 0 (9.5's failures, 9.6)
	longint      f1_tot [G_N], f1_frm [G_N];
	function automatic void f1_inc(input f1_cnt_t c);
		f1_tot[c]++;
		f1_frm[c]++;
	endfunction

	longint      f1_clk = 0, f1_t_vs = 0, f1_t_e0 = -1;
	int          f1_frame = 0, f1_nfail = 0, f1_emin = 99, f1_emax = -1;
	logic        f1_old_vs = 0, f1_live = 0, f1_rst_seen = 0, f1_short = 0, f1_rst_cyc = 0;
	int          fd_f1 = 0, fd_f1_ticks = 0, fd_amp_up = 0, fd_amp_fe = 0;

	task automatic f1_fail(input string cls, input string what);
		f1_nfail++;
		if (f1_nfail <= fe_stop && fd_fe_err != 0) begin
			$fwrite(fd_fe_err, "daria_fe %s at clk_sys %0d, frame %0d line %0d: pclk1 %0d pclk0 %0d phi2 %0d a_in %04x rw %0d d_in %02x, 6507 pc %04x: %s\n",
				cls, f1_clk, f1_frame, int'((f1_clk - f1_t_vs) / SYS_PER_LINE), dut.pclk1, dut.pclk0,
				dut.mapper_phi2, dut.cart2600.a_in, dut.RW, dut.write_DB, op_pc, what);
			if (f1_nfail <= 2) fe_dump_ring();
			if (f1_nfail == fe_stop) $fwrite(fd_fe_err, "(no more daria_fe lines: +fe_stop=%0d)\n", fe_stop);
		end
		if (fe_fatal != 0) begin
			$display("FE stopped at the first daria_fe failure (+fe_fatal): %s, %s", cls, what);
			$finish;
		end
	endtask
	// A must-be-0 event: counted, the first five of each kind logged. A macro, so
	// the message is formatted only when the condition holds.
`define F1_CHK(cond, c, what) begin if (cond) begin f1_inc(c); if (f1_tot[c] <= 5) f1_fail(f1_nm[c], what); end end

	// Histograms (FE latency lines): R1 post - accept; M_fe - M; busy fall fe - up;
	// refresh length (dispatch to IDLE) up and fe; NOTE capture fe - up.
	localparam int F1_HB = 64;
	longint      f1_h_post [F1_HB], f1_h_merge [F1_HB], f1_h_busy [F1_HB], f1_h_rup [F1_HB], f1_h_rfe [F1_HB];
	longint      f1_h_note [F1_HB], f1_h_slat [F1_HB];
	longint      f1_smp_t = -1;
	function automatic int f1_bin(input longint d);
		return d < 0 ? 0 : (d >= F1_HB - 1 ? F1_HB - 1 : int'(d));
	endfunction
	function automatic string f1_hist(input longint h [F1_HB]);
		string s;
		s = "";
		for (int b = 0; b < F1_HB; b++)
			if (h[b] != 0) begin
				if (s.len() != 0) s = {s, " "};
				if (b == F1_HB - 1) s = {s, $sformatf("%0d+:%0d", b, h[b])};
				else s = {s, $sformatf("%0d:%0d", b, h[b])};
			end
		if (s.len() == 0) s = "-";
		return s;
	endfunction

	// ---- the audio classes' masks (bench.md 7.6; design 9.5, 12.4) ------------------------
	// rep: the replica's registers; cf: counters and frequencies. Set by a
	// class's own condition (or an audio_bad), cleared by fe_deposit_audio at the
	// next falling edge where both engines are quiet (resync).
	logic        f1_m_rep = 0, f1_m_cf = 0;
	string       f1_m_why = "";
	// The merge window of a CDF call without the hook: f1_w 1 after M (upstream's
	// merge, call_done in (X, X+1)) up to M_fe (cp_apply), 2 after M_fe, 0 after
	// M_fe+1. Counters and frequencies are compared from M_fe+1 on (5.6).
	int          f1_w = 0;
	longint      f1_w_m = 0, f1_late_until = -1;
	logic        f1_rmw_merge = 0, f1_w_rmw = 0, f1_rmw_chk = 0;
	longint      f1_dig_chk = -1, f1_up_disp_t = -1, f1_fe_disp_t = -1, f1_up_ncap_t = -1;
	logic        f1_up_busy_q = 0, f1_fe_busy_q = 0;
	longint      f1_up_busy_fall = -1;
	int          f1_ret_late_seen = 0, f1_ctog_seen = 0;
	function automatic void f1_mask(input logic cf, input string why);
		f1_m_rep = 1;
		if (cf) f1_m_cf = 1;
		f1_m_why = why;
	endfunction
	// How long the masks stay set: a mask that never meets a quiet point would
	// leave A1 blind for the rest of the run (mask_stuck, +fe_mask_max clk_sys).
	int          fe_mask_max = 20000;
	logic        f1_sel_unp = 0, f1_up_inw = 0, f1_fe_inw = 0;	// pause_lane; T5's merge-window flags
	logic [40:0] f1_rq_up [$], f1_rq_fe [$];			// T5: ROM-sample amplitudes in order
	longint      f1_mask_t0 = -1, f1_mask_long = 0;
	logic        f1_mask_stk = 0;
	// The merge after an rmw_seed (rmw_merge): in mode A call 2's returns are
	// upstream's, so a voice the ARM left alone returns upstream's seed, which
	// u_fe takes (its own seed differs by the tick at M) while upstream keeps
	// its counter: upstream's counter is then u_fe's plus k ticks of that
	// voice's frequency during call 2 (its payload's, f1_rmw_f), k the ticks
	// since call 2's accept. Anything else is audio_bad.
	logic [95:0] f1_rmw_f = 0;
	function automatic logic f1_rmw_cnt_ok();
		logic [31:0] u, f, fr, acc;
		logic        ok;
		for (int v = 0; v < 3; v++) begin
			u  = v == 0 ? dut.cart2600.mapper_audio.counter0 : (v == 1 ? dut.cart2600.mapper_audio.counter1 :
				dut.cart2600.mapper_audio.counter2);
			f  = u_fe.u_audio.counter[v];
			fr = f1_rmw_f[32 * v +: 32];
			ok = 0;
			acc = f;
			for (int k = 0; k <= 4096 && !ok; k++) begin
				if (acc == u) ok = 1;
				acc = acc + fr;
			end
			if (!ok) return 0;
		end
		return 1;
	endfunction

	// ---- per-cycle bookkeeping ------------------------------------------------------------
	logic        f1_pu_pend = 0, f1_pu_short = 0, f1_wr_pend = 0, f1_cyc_commit = 0, f1_hid_pend = 0;
	logic        f1_hid_pend_bad = 0, f1_o1_pend = 0, f1_k2_arm = 0, f1_use_exp = 0, f1_rom_cmp = 0;
	logic  [5:0] f1_pu_idx = 0;
	logic [17:0] f1_wr_a = 0;
	logic  [7:0] f1_o1_up = 0, f1_o1_fe = 0, f1_obus = 0;
	logic [63:0] f1_alias = 0;		// CDFJ+ streams whose pointer word a DSWRITE hit (tbl_alias)

	// R1: upstream's accepts and u_fe's posts, paired in order
	logic [255:0] f1_upq [$], f1_feq [$];
	longint       f1_upt [$], f1_fet [$];
	logic         f1_fer [$];
	int           f1_rmw_pend = 0;
	logic         f1_tog2 = 0;
	// R2/R3: services
	logic  [51:0] f1_sq_up [$], f1_sq_fe [$];
	logic  [31:0] f1_r3_d [$], f1_r3_c [$];
	int           f1_svc_up_done = 0, f1_svc_fe_done = 0, f1_r3_n = 0;
	logic         f1_sp_q = 0, f1_fsp_q = 0, f1_run_q = 0, f1_updma_q = 0;
	longint       f1_up_dma_t = 0, f1_fe_run_t = 0;
	logic  [14:0] f1_up_rng_d = 0, f1_fe_rng_d = 0;
	logic   [7:0] f1_up_rng_c = 0, f1_fe_rng_c = 0;
	// I1/I2
	logic         f1_i_arm = 0, f1_i_up = 0, f1_i_fe = 0, f1_erst_q = 0, f1_rom_done = 0, f1_cd_q = 0;
	logic         f1_f6_q = 0, f1_ib_q = 0;
	longint       f1_t_ld1 = -1, f1_t_f6 = -1;
	int           f1_nf6 = 0;

	// ---- RAM compares (I1, K1, K2, R3) ---------------------------------------------------------
	// Words [0, n) of upstream's cart RAM against fe_mem's (aliased CDFJ+ pointer
	// words skipped); returns the number that differ and logs the first ones.
	function automatic int f1_ram_cmp(input string what, input int n);
		int bad;
		logic [31:0] u, f;
		bad = 0;
		for (int w = 0; w < n; w++) begin
			u = ft_uw(w);
			f = ft_cw(w);
			if (u != f && !(fe_is_cdf && w >= ft_pb() && w < ft_pb() + 64 && f1_alias[w - ft_pb()])) begin
				bad++;
				if (bad <= 16 && f1_nfail < fe_stop && fd_fe_err != 0)
					$fwrite(fd_fe_err, "  %s: cart RAM word $%04x (byte $%05x): upstream %08x, daria_fe %08x\n",
						what, w, 4 * w, u, f);
			end
		end
		return bad;
	endfunction
	// The CDF tables: upstream's copies against the words in place
	function automatic int f1_tbl_cmp(input string what);
		int bad;
		bad = 0;
		if (!fe_is_cdf) return 0;
		for (int i = 0; i < ft_streams(); i++) begin
			if (dut.cart2600.stream_tables.pointer_ram.mem_q[i] != ft_cw(ft_pb() + i) && !f1_alias[i]) begin
				bad++;
				if (bad <= 8 && fd_fe_err != 0)
					$fwrite(fd_fe_err, "  %s: pointer[%0d]: upstream's table %08x, daria_fe's word %08x\n", what, i,
						dut.cart2600.stream_tables.pointer_ram.mem_q[i], ft_cw(ft_pb() + i));
			end
			if (dut.cart2600.stream_tables.increment_ram.mem_q[i] != ft_cw(ft_ib() + i)) begin
				bad++;
				if (bad <= 8 && fd_fe_err != 0)
					$fwrite(fd_fe_err, "  %s: increment[%0d]: upstream's table %08x, daria_fe's word %08x\n", what, i,
						dut.cart2600.stream_tables.increment_ram.mem_q[i], ft_cw(ft_ib() + i));
			end
		end
		return bad;
	endfunction
	function automatic int f1_ram_words();
		return dut.mapper_ram_size == 16'd32768 ? 8192 : 2048;
	endfunction

	// ---- O1: top.sv's read_DB (top.sv:379-395) with open_bus replaced by the
	// shadow f1_obus and the cartridge's byte by u_fe's (obus_exposed) ----------------------
	function automatic logic [7:0] f1_read_db();
		logic [7:0] r, cd, co;
		if (dut.tia_en) begin
			cd = (fe_is_dpc || fe_is_cdf) ? u_fe.fe_do : dut.cart_2600_DB_out;
			co = (fe_is_dpc || fe_is_cdf) ? {8{u_fe.fe_oe}} : dut.cart_2600_DB_oe;
		end else begin
			cd = dut.cart_7800_DB_out;
			co = dut.cart_7800_DB_oe;
		end
		r = f1_obus;
		if (dut.RW) begin
			if (dut.cs_ram0)  r = dut.ram0_DB_out;
			if (dut.cs_ram1)  r = dut.ram1_DB_out;
			if (dut.cs_tia)   r = (dut.tia_DB_out & dut.tia_DB_oe) | (f1_obus & ~dut.tia_DB_oe);
			if (dut.cs_riot)  r = (dut.riot_DB_out & dut.riot_DB_oe) | (f1_obus & ~dut.riot_DB_oe);
			if (dut.cs_maria) r = (dut.maria_DB_out & dut.maria_DB_oe) | (f1_obus & ~dut.maria_DB_oe);
			if (dut.cs_cart && (dut.cart_present || dut.bios_sel))
				r = dut.bios_sel ? dut.bios_out : ((cd & co) | (f1_obus & ~co));
		end
		return r;
	endfunction

	// ---- the per-frame line of fe.csv ---------------------------------------------------------
	task automatic f1_csv_line();
		$fwrite(fd_f1, "%0d", f1_frame);
		for (int c = 0; c < G_N; c++) $fwrite(fd_f1, ",%0d", f1_frm[c]);
		$fwrite(fd_f1, "\n");
	endtask

	// ==== the checks, on clk_sys ==============================================================
	always @(posedge clk_sys) begin
		string       why;
		logic        hidden, bad, scheme_ok, aread, up_disp, fe_disp, gr;
		logic  [7:0] fo, fd, uo, ud;
		logic [12:0] wa;
		logic [255:0] pu, pf;
		logic [51:0] su, sf;
		longint      tu, tf;
		int          d, n;
		f1_clk++;
		scheme_ok = fe_is_dpc || fe_is_cdf;

		// ---- frames: tb_daria's rule; the clock that sees the VSYNC rise is the new frame's
		if (running && vsync_raw && !f1_old_vs) begin
			if (f1_frame > 0) f1_csv_line();
			f1_frame++;
			f1_t_vs = f1_clk;
			foreach (f1_frm[c]) f1_frm[c] = 0;
			if (fe_full > 0 && f1_frame % fe_full == 0) f1_k2_arm = 1;
		end
		f1_old_vs = vsync_raw;
		if (f1_ctog_bad != f1_ctog_seen) begin			// the bench's own completion predictor
			`F1_CHK(1, G_RET_MODEL_BAD, "complete_toggle differs from the bench's prediction (ret_tog emulation)")
			f1_ctog_seen = f1_ctog_bad;
		end
		if (f1_ret_late_n != f1_ret_late_seen) begin
			f1_inc(G_RET_LATE);
			f1_ret_late_seen = f1_ret_late_n;
			f1_late_until = f1_clk + 2000;		// merge_race is allowed only for that call
		end

		// ---- events, assertions, every-clock oracles (from time 0) --------------------------
		if (u_fe.rst_fe) f1_rst_cyc = 1;
		if (u_fe.u_seq.ev_short) f1_inc(G_SHORT_PHASE1);
		if (u_fe.u_arb.ev_grant_steal) f1_inc(G_GRANT_STEAL);
		if (u_fe.u_core.ev_rmw_svc) f1_inc(G_RMW_SVC);
		if (u_fe.u_audio.ev_size_hi) f1_inc(G_SIZE_OVER32K);
		if (u_fe.u_arb.crb_use) f1_inc(G_CRB_USE);
		if (u_fe.u_call.ev_rmw_call) begin
			f1_inc(G_RMW_CALL);
			f1_rmw_pend++;
		end
		if (u_fe.u_core.ev_tbl_alias) begin
			// the stream whose pointer word the DSWRITE byte hit (CDFJ+: pb = $026)
			f1_inc(G_TBL_ALIAS);
			n = int'(u_fe.u_core.dsw_addr[14:2]) - ft_pb();
			if (n >= 0 && n < 64) f1_alias[n] = 1'b1;
		end
		`F1_CHK(u_fe.u_arb.a_collide, G_A_COLLIDE, "a_collide: grant_steal outside short_phase1")
		`F1_CHK(u_fe.u_arb.a_wb_late, G_A_WB_LATE, "a_wb_late: the pointer buffer still full in k[1]")
		if (u_fe.u_arb.a_p32_late) begin
			// lane A O-1 / lane D O-1: rdP/p32_q cleared by rst_fe inside the cycle
			if (f1_rst_cyc) f1_inc(G_P32_RESET);
			else `F1_CHK(1, G_A_P32_LATE, "a_p32_late: DSWRITE/DSPTR without P32 in k[3]")
		end
		`F1_CHK(u_fe.u_arb.a_guard_core, G_A_GUARD_CORE, "a_guard_core")
		`F1_CHK(u_fe.u_arb.a_guard_wr, G_A_GUARD_WR, "a_guard_wr")
		`F1_CHK(u_fe.u_arb.a_owner, G_A_OWNER, "a_owner: two owners on one port")
		`F1_CHK(u_fe.u_core.a_fpjr, G_A_FPJR, "a_fpjr: fpend with jr != 0")
		`F1_CHK(u_fe.u_core.a_pend_late, G_A_PEND_LATE, "a_pend_late: a commit action pending at pclk1")
		`F1_CHK(u_fe.u_audio.a_tdef2, G_A_TDEF2, "a_tdef2: a tick while one is deferred")
		`F1_CHK(u_fe.u_copy.a_f6_live, G_A_F6_LIVE, "a_f6_live: F6 while the console runs")
		`F1_CHK(u_fe.u_call.ev_ret_unasked, G_RET_UNASKED, "ret_unasked: a ret_tog change outside RUN")
		`F1_CHK(u_fe.u_seq.commit && dut.pclk0 && !dut.mapper_phi2, G_COMMIT_HIDDEN, "commit_on_hidden")
		if (u_fe.u_guard.locked) `F1_CHK(1, G_DET_LOCK_A, "det_lock_a: the guard locked on mode A's 5x clk_arm")
		// A2: the replica of sel_ram_sel, every clock
		if (scheme_ok)
			`F1_CHK(u_fe.sel_up != dut.cart2600.sel_ram_sel, G_A2_BAD,
				$sformatf("A2: sel_up %0d, sel_ram_sel %0d", u_fe.sel_up, dut.cart2600.sel_ram_sel))
		// A3: one owner per port; crb_use marks exactly last clock's consumed read
		`F1_CHK(!$onehot0(u_fe.u_arb.own_r) || !$onehot0(u_fe.u_arb.own_s) || !$onehot0(u_fe.u_arb.own_a) ||
			u_fe.u_arb.crb_use != f1_use_exp, G_A3_BAD,
			$sformatf("A3: own_r %06b own_s %03b own_a %04b, crb_use %0d expected %0d", u_fe.u_arb.own_r,
				u_fe.u_arb.own_s, u_fe.u_arb.own_a, u_fe.u_arb.crb_use, f1_use_exp))
		f1_use_exp = (u_fe.u_arb.own_r[1] && u_fe.cr_fix_use) || u_fe.u_arb.own_r[3] || u_fe.u_arb.own_r[2];
		// W1: upstream's writeback never drops a payload (glue.md 9)
		`F1_CHK(dut.cart2600.table_pointer_write && !dut.effective_reset &&
			dut.cart2600.table_writeback.pointer_ack_sync2 != dut.cart2600.table_writeback.pointer_toggle,
			G_WB_DROP, "wb_drop: upstream's writeback dropped a pointer")
		// the mirror's ROM byte against the tb's cart_q, whenever both read the same byte
		if (f1_rom_cmp)
			`F1_CHK(u_fe.u_core.romb != cart_q, G_ROM_BAD,
				$sformatf("rom: daria_fe's mirror byte %02x, tb cart_q %02x", u_fe.u_core.romb, cart_q))
		f1_rom_cmp = running && dut.tia_en && cart_addr[18:15] == 4'd0 && cart_addr[14:0] == u_fe.u_core.rom_a;
		// d_in = write_DB equals cart2600's d_in on every write latch
		if (dut.pclk0 && !dut.RW)
			`F1_CHK(dut.write_DB != dut.cart2600.d_in, G_DIN_BAD, "d_in: write_DB differs from cart2600.d_in")

		// ---- H1, the hold's self-check (7.4.2), while running ---------------------------------
		if (running) begin
			logic exp;
			exp = dut.tia_en && (dut.arm_call_busy || (!dut.mapper_init_busy && (dut.arm_dma_busy || u_fe.arm_dma_busy)));
			`F1_CHK(dut.arm_call_stall != exp || (exp && dut.RDY) ||
				dut.mapper_phi2 != (dut.pclk0 && (!exp || !dut.stall_cycle_taken)), G_HOLD_BAD,
				$sformatf("H1: arm_call_stall %0d, expected %0d, RDY %0d, mapper_phi2 %0d", dut.arm_call_stall, exp,
					dut.RDY, dut.mapper_phi2))
		end
		// dma_cover (design 7.4): u_fe's arm_dma_busy covers a latched or running
		// service. H1 checks that the hold follows the busy; this checks that the
		// busy covers the engine (in mode A upstream's longer stall hides a
		// short one).
		`F1_CHK((u_fe.u_copy.run || u_fe.u_core.svc_hold) && !u_fe.arm_dma_busy && !u_fe.init_busy &&
			!dut.effective_reset, G_DMA_COVER,
			$sformatf("dma_cover: arm_dma_busy 0 with run %0d, svc_hold %0d", u_fe.u_copy.run, u_fe.u_core.svc_hold))

		// ---- A1 and T1/T2 (every clock from the first reset): the state the last edge left ----
		if (f1_rst_seen) begin
			why = ft_a1_tick();
			if (why != "") begin
				`F1_CHK(1, G_TICK_BAD, {"T1/A1 ", why})
				f1_mask(1, "tick_bad");
			end
			if (dut.cart2600.mapper_audio.audio_tick && !f1_m_cf && f1_w == 0) f1_inc(G_TICKS);
			if (!f1_m_cf && f1_w == 0) begin
				why = ft_a1_cf();
				if (why != "") begin
					if (f1_clk < f1_late_until) f1_inc(G_MERGE_RACE);	// only after a ret_late (7.6)
					else if (f1_rmw_chk && u_fe.u_audio.freq[0] == dut.cart2600.mapper_audio.frequency0 &&
							u_fe.u_audio.freq[1] == dut.cart2600.mapper_audio.frequency1 &&
							u_fe.u_audio.freq[2] == dut.cart2600.mapper_audio.frequency2 && f1_rmw_cnt_ok())
						f1_inc(G_RMW_MERGE);			// the merge after an rmw_seed: counters only, k ticks
					else `F1_CHK(1, G_AUDIO_BAD, {"A1 counters/frequencies: ", why, f1_rmw_chk ?
						$sformatf(" (after an rmw_seed: call 2's frequencies %024x, now %08x %08x %08x)", f1_rmw_f,
							u_fe.u_audio.freq[2], u_fe.u_audio.freq[1], u_fe.u_audio.freq[0]) : ""})
					f1_mask(1, "audio_bad");
				end
			end
			f1_rmw_chk = 0;
			if (!f1_m_rep) begin
				why = ft_a1_rep();
				if (why != "") begin
					`F1_CHK(1, G_AUDIO_BAD, {"A1 replica: ", why})
					f1_mask(0, "audio_bad");
				end
			end
		end
		if (dut.effective_reset) f1_rst_seen = 1;
		// how long A1 is masked (the resync clears a mask at a falling edge)
		if (f1_m_rep || f1_m_cf) begin
			f1_inc(G_MASKED);
			if (f1_mask_t0 < 0) f1_mask_t0 = f1_clk;
			else if (fe_resync != 0 && !f1_mask_stk && f1_clk - f1_mask_t0 > fe_mask_max) begin
				f1_mask_stk = 1;
				`F1_CHK(1, G_MASK_STUCK, $sformatf("mask_stuck: A1 masked for %0d clk_sys (%s) with no quiet point",
					f1_clk - f1_mask_t0, f1_m_why))
			end
		end else if (f1_mask_t0 >= 0) begin
			if (f1_clk - f1_mask_t0 > f1_mask_long) f1_mask_long = f1_clk - f1_mask_t0;
			f1_mask_t0 = -1;
			f1_mask_stk = 0;
		end

		// ---- the audio classes: their conditions at this edge set the masks -------------------
		up_disp = ft_up_dispatch();
		fe_disp = u_fe.u_audio.dispatch;
		// T5: every amplitude written from a ROM sample (both routes), upstream's
		// (AUDIO_ROM_WAIT & rom_done) and u_fe's (am_rom), paired in order, value
		// and sample address. dig_rom_lag masks the replica's timing and resyncs,
		// so without this the >= 32 KB route's data (sample port, nibble) would
		// never be compared. A refresh either side dispatched in (M, M_fe+1]
		// (merge_amp) or before tia_en (pre_lock) is counted, not compared.
		if (up_disp) f1_up_inw = f1_w != 0 || !dut.tia_en;
		if (fe_disp) f1_fe_inw = f1_w != 0 || !dut.tia_en;
		if (dut.effective_reset) begin
			f1_rq_up.delete();
			f1_rq_fe.delete();
		end else begin
			if (dut.cart2600.mapper_audio.state == 4'd11 && dut.cart2600.mapper_audio.rom_done)
				f1_rq_up.push_back({f1_up_inw, dut.cart2600.mapper_audio.digital_address, 4'h0,
					dut.cart2600.mapper_audio.digital_low_nibble ? dut.cart2600.mapper_audio.rom_data[3:0] :
					dut.cart2600.mapper_audio.rom_data[7:4]});
			if (u_fe.u_audio.am_rom)
				f1_rq_fe.push_back({f1_fe_inw, u_fe.u_audio.dig_addr, u_fe.u_audio.amp_d});
			while (f1_rq_up.size() > 0 && f1_rq_fe.size() > 0) begin
				logic [40:0] qu, qf;
				qu = f1_rq_up.pop_front();
				qf = f1_rq_fe.pop_front();
				if (qu[40] || qf[40]) f1_inc(G_DIG_VAL_MRG);
				else begin
					f1_inc(G_DIG_VAL_N);
					`F1_CHK(qu[39:0] != qf[39:0], G_DIG_VAL_BAD,
						$sformatf("T5: ROM sample address %08x amplitude %02x, upstream %08x %02x", qf[39:8], qf[7:0],
							qu[39:8], qu[7:0]))
				end
			end
		end
		// merge_amp: a refresh dispatched at D in (M, M_fe+1] of a CDF call, no hook
		if (f1_w != 0 && (up_disp || fe_disp)) begin
			f1_inc(G_MERGE_AMP);
			f1_mask(0, "merge_amp");
		end
		// the merge window
		if (f1_w == 0) begin
			if (dut.cart2600.arm_call_done && fe_is_cdf) begin
				if (f1_hk_en) f1_inc(G_HK_MERGES);
				else begin
					f1_w = 1;
					f1_w_m = f1_clk;
					f1_w_rmw = f1_rmw_merge;
					f1_rmw_merge = 0;
					f1_inc(G_MERGES);
				end
			end
		end else if (f1_w == 1) begin
			if (u_fe.cp_apply) begin
				f1_w = 2;
				f1_h_merge[f1_bin(f1_clk - f1_w_m)]++;
				// The window this bench masks is u_fe's own (M, M_fe]: its length is
				// design 5.6's M_fe = M+6 (F5), longer only after a ret_late.
				`F1_CHK(f1_clk - f1_w_m != 6 && f1_clk >= f1_late_until, G_MERGE_LATE,
					$sformatf("merge_late: M_fe - M = %0d clk_sys, design 5.6: 6", f1_clk - f1_w_m))
			end else if (f1_clk - f1_w_m > 64) begin
				`F1_CHK(1, G_AUDIO_BAD, "merge: u_fe never applied the returns (cp_apply) within 64 clocks of M")
				f1_w = 0;
				f1_mask(1, "audio_bad");
			end
		end else begin
			f1_w = 0;					// this edge is M_fe+1: compared from the next clock
			f1_rmw_chk = f1_w_rmw;
			f1_w_rmw = 0;
		end
		if (f1_hk_en && dut.cart2600.arm_call_done && fe_is_cdf) f1_h_merge[0]++;
		// grant_steal (short_phase1): the replica is a clock behind; NOTE loads may move
		if (u_fe.u_arb.ev_grant_steal) f1_mask(1, "grant_steal");
		// coverage: upstream's digital routes (AUD:335-347) and its ROM sample latency
		if (dut.cart2600.mapper_audio.state == 4'd9) begin		// AUDIO_DIGITAL_ROUTE
			if (dut.cart2600.mapper_audio.digital_address < dut.cart2600.mapper_audio.rom_size) begin
				if (dut.cart2600.mapper_audio.digital_address[31:15] == 17'd0) f1_inc(G_DIG_LOCAL);
				else f1_inc(G_DIG_REMOTE);
			end else if (dut.cart2600.mapper_audio.digital_address[31:15] == 17'h0_8000) f1_inc(G_DIG_RAM);
			else f1_inc(G_DIG_NONE);
		end
		if (dut.cart2600.arm_sample_request) f1_smp_t = f1_clk;
		if (dut.cart2600.arm_sample_done && f1_smp_t >= 0) begin
			f1_h_slat[f1_bin(f1_clk - f1_smp_t)]++;
			f1_smp_t = -1;
		end
		// dig_rom_lag: upstream's ROM sample request R (rom_request includes rom_ready)
		if (dut.cart2600.arm_sample_request) begin
			if (dut.cart2600.mapper_audio.digital_address[31:15] != 17'd0) begin
				f1_inc(G_DIG_ROM_LAG);			// beyond 32 KB: u_fe's port, +fe_slat
				f1_mask(0, "dig_rom_lag");
			end else
				f1_dig_chk = f1_clk + 4;		// a hit: sample_done high pre-edge at R+4
		end
		if (f1_dig_chk == f1_clk) begin
			f1_dig_chk = -1;
			if (!dut.cart2600.arm_sample_done) begin
				f1_inc(G_DIG_ROM_LAG);
				f1_mask(0, "dig_rom_lag");
			end
		end
		// T4: u_fe's remote sample request against upstream's address
		if (u_fe.u_audio.r_go && !u_fe.u_audio.r_loc && !f1_m_rep)
			`F1_CHK(u_fe.u_audio.dig_addr != dut.cart2600.mapper_audio.digital_address, G_DIG_BAD,
				$sformatf("T4: sample address %08x, upstream %08x", u_fe.u_audio.dig_addr,
					dut.cart2600.mapper_audio.digital_address))
		// grants: svc_audio_race, pre_lock, pause_lane
		gr = dut.cart2600.audio_ram_grant || u_fe.aud_take;
		if (gr) begin
			wa = dut.cart2600.audio_ram_grant ? dut.cart2600.audio_ram_addr[14:2] : u_fe.aud_addr[14:2];
			if ((f1_updma_q && {wa, 2'b11} >= f1_up_rng_d && {wa, 2'b00} < f1_up_rng_d + {7'd0, f1_up_rng_c}) ||
				(u_fe.u_copy.run && {wa, 2'b11} >= f1_fe_rng_d && {wa, 2'b00} < f1_fe_rng_d + {7'd0, f1_fe_rng_c})) begin
				f1_inc(G_SVC_AUDIO_RACE);
				f1_mask(0, "svc_audio_race");
			end
			if (!dut.tia_en && !dut.effective_reset) begin
				f1_inc(G_PRE_LOCK);
				f1_mask(0, "pre_lock");
			end
			// pause_lane (lane B, B-1): only a paused grant whose last unpaused edge
			// had sel_ram_sel high, so upstream's lane register holds the 6507
			// port's lane. Any other paused grant reads the engine's lane on both
			// sides and stays compared.
			if (dut.pause && f1_sel_unp) begin
				f1_inc(G_PAUSE_LANE);
				f1_mask(0, "pause_lane");
			end
		end
		if (!dut.pause) f1_sel_unp = dut.cart2600.sel_ram_sel;
		if (u_fe.u_audio.ev_size_hi || (dut.cart2600.mapper_audio.state == 4'd5 &&
				dut.cart2600.mapper_audio.ram_addr[16:15] != 2'd0))
			f1_mask(0, "size_over32k");
		// T3 and the NOTE-capture offset (histograms)
		if (f1_up_disp_t >= 0 && dut.cart2600.mapper_audio.state == 4'd0) begin
			f1_h_rup[f1_bin(f1_clk - f1_up_disp_t)]++;
			f1_up_disp_t = -1;
		end
		if (f1_fe_disp_t >= 0 && u_fe.u_audio.st == 12'd1) begin
			f1_h_rfe[f1_bin(f1_clk - f1_fe_disp_t)]++;
			f1_fe_disp_t = -1;
		end
		if (up_disp) f1_up_disp_t = f1_clk;
		if (fe_disp) f1_fe_disp_t = f1_clk;
		if (dut.cart2600.mapper_audio.state == 4'd2) f1_up_ncap_t = f1_clk;	// AUDIO_NOTE_CAPTURE
		if (u_fe.u_audio.st[2] && f1_up_ncap_t >= 0) begin
			f1_h_note[f1_bin(f1_clk - f1_up_ncap_t)]++;
			f1_up_ncap_t = -1;
		end
		if (fe_ticks != 0 && dut.cart2600.mapper_audio.audio_tick && fd_f1_ticks != 0)
			$fwrite(fd_f1_ticks, "%0d,%0d,%0d,%0d,%s\n", f1_clk, dut.cart2600.mapper_audio.amplitude,
				u_fe.u_audio.amplitude, f1_m_rep || f1_m_cf || f1_w != 0, f1_m_why);
		if (fe_pcm != 0 && dut.cart2600.mapper_audio.audio_tick && fd_amp_up != 0) begin
			$fwrite(fd_amp_up, "%c", dut.cart2600.mapper_audio.amplitude);
			$fwrite(fd_amp_fe, "%c", u_fe.u_audio.amplitude);
		end

		// ---- E0 tracking and the checks while live ---------------------------------------------
		if (dut.effective_reset) f1_live = 0;
		if (dut.pclk0 && f1_t_e0 >= 0) begin
			d = int'(f1_clk - f1_t_e0);
			f1_short = d < 6;
			if (f1_live) begin
				if (d < f1_emin) f1_emin = d;
				if (d > f1_emax) f1_emax = d;
			end
		end
		if (f1_live && scheme_ok) begin
			if (u_fe.u_seq.commit) f1_inc(G_COMMIT);
			// C3/C4 bookkeeping inside the cycle
			if (fe_is_cdf && dut.cart2600.cdf.pointer_update) begin
				f1_pu_pend = 1;
				f1_pu_idx = dut.cart2600.cdf.pointer_update_index;
				f1_pu_short = f1_short;
			end
			if (dut.cartram_wr) begin
				f1_wr_pend = 1;
				f1_wr_a = dut.cartram_addr;
				`F1_CHK(dut.cartram_addr[17:15] != 3'd0, G_OVER32K,
					$sformatf("over32k: a 6507-side cart RAM write at $%05x", dut.cartram_addr))
			end
			if (dut.cart2600.arm_access && dut.cart2600.a_in[12]) f1_cyc_commit = 1;

			// ---- L1 (and O1, obus), at every pclk0 ----
			if (dut.pclk0) begin
				f1_inc(G_LATCH);
				hidden = !dut.mapper_phi2;
				if (dut.RW) begin
					uo = dut.cart2600.oe;
					ud = dut.cart2600.d_out;
					fo = {8{u_fe.fe_oe}};
					fd = u_fe.fe_do;
					bad = fo != uo || (fd & fo) != (ud & uo);
					aread = fe_is_dpc ? (dut.cart2600.dpcplus.register_read && dut.cart2600.dpcplus.read_function == 3'd0 &&
						dut.cart2600.dpcplus.read_index == 3'd5) : dut.cart2600.cdf.amplitude_fetch;
					if (!hidden) begin
						f1_inc(G_READS);
						if (aread) f1_inc(G_AMP_READS);
						if (bad) begin
							if (f1_short) f1_inc(G_SHORT_DOUT);			// short_phase1: that cycle's fe_do
							else if (aread && f1_m_rep) f1_inc(G_AMP_CLASS);	// under an audio class
							else if (aread) `F1_CHK(1, G_AMP_LAG, $sformatf("amp_lag: AMPLITUDE read, daria_fe %02x, upstream %02x, no class",
								fd, ud))
							else if (fe_is_cdf && dut.cart2600.cdf.stream_substitute && f1_alias[dut.cart2600.cdf.table_index])
								f1_inc(G_TBL_ALIAS);
							else `F1_CHK(1, G_DOUT, $sformatf("L1 dout: daria_fe %02x/%02x, upstream %02x/%02x (d/oe)", fd, fo, ud, uo))
						end
						// obus_exposed: the open-bus leak reaching the CPU through a partial driver
						if (!bad && f1_read_db() != dut.read_DB)
							`F1_CHK(1, G_OBUS, $sformatf("obus_exposed: read_DB %02x, with daria_fe's bus %02x", dut.read_DB,
								f1_read_db()))
						if (dut.cart2600.a_in[12]) begin
							f1_o1_pend = 1;
							f1_o1_up = ud;
							f1_o1_fe = fd;
						end
					end else begin
						f1_inc(G_HIDDEN);
						f1_hid_pend = 1;
						f1_hid_pend_bad = bad;
						if (bad) f1_inc(G_DOUT_HID);
					end
				end
			end

			// ---- at every pclk1: what the cycle before left ----
			if (dut.pclk1) begin
				f1_inc(G_CYCLES);
				if (fe_is_dpc) why = ft_c1();
				else why = ft_c2();
				if (why != "") begin
					if (fe_is_dpc) why = {"C1 state: ", why};
					else why = {"C2 state: ", why};
				end
				`F1_CHK(why != "", G_STATE, why)
				if (f1_pu_pend) begin
					f1_inc(G_PTR_N);
					why = ft_c3(f1_pu_idx);
					if (why != "") begin
						if (f1_pu_short) f1_inc(G_Q26);				// short_phase1: CDF Q26
						else if (f1_alias[f1_pu_idx]) f1_inc(G_TBL_ALIAS);
						else `F1_CHK(1, G_PTR, {"C3 ", why})
					end
				end
				if (f1_wr_pend) begin
					f1_inc(G_RAM_N);
					`F1_CHK(fe_ram_byte(f1_wr_a[16:0]) != ft_cb(int'(f1_wr_a[14:0])), G_RAM,
						$sformatf("C4: cart RAM byte $%05x: upstream %02x, daria_fe %02x", f1_wr_a,
							fe_ram_byte(f1_wr_a[16:0]), ft_cb(int'(f1_wr_a[14:0]))))
					`F1_CHK(!f1_cyc_commit, G_RAM_WR_NOACC, "ram_wr_noaccess: an upstream RAM strobe in a cycle with no commit")
				end
				if (f1_o1_pend) begin
					if (dut.cart2600.d_out != f1_o1_up) f1_inc(G_DRIFT_UP);
					if (u_fe.fe_do != f1_o1_fe) f1_inc(G_DRIFT_FE);
				end
				if (f1_hid_pend) begin
					if (dut.RDY) begin
						f1_inc(G_HID_LAST);
						`F1_CHK(f1_hid_pend_bad, G_HID_LAST_BAD, "hidden_last_bad: the last hidden latch of a stall differs")
					end
				end
				// K2: the whole cart RAM once a frame, at an E0 with the writeback idle
				// and nothing of daria_fe's in flight
				if (f1_k2_arm && dut.cart2600.mapper_wb_idle && !u_fe.u_core.wb_v && !u_fe.u_copy.run &&
						!u_fe.u_core.svc_pend && !(dut.arm_dma_busy && !dut.mapper_init_busy)) begin
					f1_k2_arm = 0;
					f1_inc(G_K2);
					n = f1_ram_cmp("K2", f1_ram_words()) + f1_tbl_cmp("K2");
					`F1_CHK(n != 0, G_RAM_FRAME_BAD, $sformatf("K2: %0d cart RAM / table words differ", n))
				end
			end
		end
		if (dut.pclk1) begin
			f1_pu_pend = 0;
			f1_wr_pend = 0;
			f1_cyc_commit = 0;
			f1_o1_pend = 0;
			f1_hid_pend = 0;
			f1_t_e0 = f1_clk;
			f1_short = 0;
			if (!f1_live && !dut.effective_reset && dut.tia_en) f1_live = 1;
		end
		if (dut.pclk1) f1_rst_cyc = 0;			// the next clock starts a new 6507 cycle
		f1_obus = dut.cpu_DB_oe ? dut.physical_write_DB : f1_read_db();

		// ---- R1: posts against accepts, in order ----------------------------------------------
		// A console reset abandons a call on both sides: an accept or a post left
		// unpaired at its rising edge is dropped (counted, information).
		if (dut.effective_reset && !f1_erst_q) begin
			f1_frm[G_DROP_UP] += f1_upq.size();
			f1_tot[G_DROP_UP] += f1_upq.size();
			f1_frm[G_DROP_FE] += f1_feq.size();
			f1_tot[G_DROP_FE] += f1_feq.size();
			f1_upq.delete();
			f1_upt.delete();
			f1_feq.delete();
			f1_fet.delete();
			f1_fer.delete();
			f1_rmw_pend = 0;
		end
		if (call_req) begin
			f1_upq.push_back(ft_payload());
			f1_upt.push_back(f1_clk);
			f1_inc(G_CALLS_UP);
		end
		if (u_fe.call_tog != f1_tog2) begin			// flipped at the last edge: F0-F7 are in place
			f1_feq.push_back(ft_posted());
			f1_fet.push_back(f1_clk - 1);
			f1_fer.push_back(f1_rmw_pend > 0);
			if (f1_rmw_pend > 0) f1_rmw_pend--;
			f1_inc(G_CALLS_FE);
		end
		f1_tog2 = u_fe.call_tog;
		while (f1_upq.size() > 0 && f1_feq.size() > 0) begin
			logic rmw;
			pu = f1_upq.pop_front();
			pf = f1_feq.pop_front();
			tu = f1_upt.pop_front();
			tf = f1_fet.pop_front();
			rmw = f1_fer.pop_front();
			f1_h_post[f1_bin(tf - tu)]++;
			if (pu != pf) begin
				logic one_tick;
				one_tick = 1;
				for (int v = 0; v < 3; v++)
					if (pf[64 + 32 * v +: 32] != pu[64 + 32 * v +: 32] &&
						pf[64 + 32 * v +: 32] != pu[64 + 32 * v +: 32] + pu[160 + 32 * v +: 32] &&
						pu[64 + 32 * v +: 32] != pf[64 + 32 * v +: 32] + pu[160 + 32 * v +: 32]) one_tick = 0;
				if (pu[63:0] != pf[63:0] || pu[255:160] != pf[255:160])
					`F1_CHK(1, G_CALL_BAD, $sformatf("R1: call %0d posted %064x, upstream's payload %064x",
						f1_tot[G_CALLS_FE] - f1_feq.size(), pf, pu))
				else if (rmw && one_tick) begin		// design 9.5: one tick's add, no more
					f1_inc(G_RMW_SEED);			// rmw_call: call 2's seeds (design 6.4, lane C C-3)
					// In mode A call 2's returns come from upstream's ARM, which got
					// upstream's seeds: a voice it leaves alone returns upstream's seed,
					// which u_fe compares with its own and takes. Call 2's merge may
					// then leave counters that differ: classed, resynced (E2 6.3).
					if (fe_is_cdf && !f1_hk_en) f1_rmw_merge = 1;
					f1_rmw_f = pu[255:160];			// call 2's frequencies (upstream's payload)
				end
				else if (one_tick) `F1_CHK(1, G_SEED_RACE, $sformatf("seed_race: posted seeds %024x, upstream %024x", pf[159:64], pu[159:64]))
				else `F1_CHK(1, G_CALL_BAD, $sformatf("R1: seeds %024x, upstream %024x", pf[159:64], pu[159:64]))
			end
		end
		// busy fall offset (u_fe - upstream) for the latency line
		if (f1_up_busy_q && !dut.arm_call_busy) f1_up_busy_fall = f1_clk;
		if (f1_fe_busy_q && !u_fe.arm_call_busy && f1_up_busy_fall >= 0) begin
			f1_h_busy[f1_bin(f1_clk - f1_up_busy_fall)]++;
			f1_up_busy_fall = -1;
		end
		f1_up_busy_q = dut.arm_call_busy;
		f1_fe_busy_q = u_fe.arm_call_busy;

		// ---- R2/R3: services ------------------------------------------------------------------
		if (dut.cart2600.dpcplus.service_pending && !f1_sp_q && fe_is_dpc) begin
			f1_sq_up.push_back(ft_svc_up());
			f1_inc(G_SVC);
		end
		f1_sp_q = dut.cart2600.dpcplus.service_pending;
		if (u_fe.u_core.svc_pend && !f1_fsp_q) begin
			f1_sq_fe.push_back(ft_svc_fe());
			f1_inc(G_SVC_FE);
		end
		f1_fsp_q = u_fe.u_core.svc_pend;
		while (f1_sq_up.size() > 0 && f1_sq_fe.size() > 0) begin
			su = f1_sq_up.pop_front();
			sf = f1_sq_fe.pop_front();
			if (f1_tot[G_SVC_FE] <= 10)
				$display("FE service %0d at clk_sys %0d (frame %0d): %s src $%05x dst $%04x count %0d value $%02x; daria_fe %s src $%05x dst $%04x count %0d value $%02x",
					f1_tot[G_SVC_FE], f1_clk, f1_frame, su[50] ? "fill" : "copy", su[49:31], su[30:16], su[15:8], su[7:0],
					sf[50] ? "fill" : "copy", sf[49:31], sf[30:16], sf[15:8], sf[7:0]);
			`F1_CHK(su != sf, G_SVC_BAD, $sformatf("R2: service fill/src/dst/count/val %013x, upstream %013x", sf, su))
			f1_r3_d.push_back({17'd0, su[30:16]});
			f1_r3_c.push_back({24'd0, su[15:8]});
		end
		if (dut.arm_dma_busy && !dut.mapper_init_busy && !f1_updma_q) begin
			f1_up_rng_d = dut.cart2600.dpcplus.service_dest;
			f1_up_rng_c = dut.cart2600.dpcplus.service_count;
		end
		if (dut.arm_dma_busy && !dut.mapper_init_busy && !f1_updma_q) f1_up_dma_t = f1_clk;
		if (f1_updma_q && !(dut.arm_dma_busy && !dut.mapper_init_busy)) begin
			f1_svc_up_done++;
			if (f1_svc_up_done <= 10)
				$display("FE service %0d: upstream's DMA busy for %0d clk_sys", f1_svc_up_done, f1_clk - f1_up_dma_t);
		end
		f1_updma_q = dut.arm_dma_busy && !dut.mapper_init_busy;
		if (u_fe.svc_take) begin
			sf = ft_svc_fe();
			f1_fe_rng_d = sf[30:16];
			f1_fe_rng_c = sf[15:8];
		end
		if (!f1_run_q && u_fe.u_copy.run) f1_fe_run_t = f1_clk;
		if (f1_run_q && !u_fe.u_copy.run) begin
			f1_svc_fe_done++;
			if (f1_svc_fe_done <= 10)
				$display("FE service %0d: daria_fe's engine ran %0d clk_sys", f1_svc_fe_done, f1_clk - f1_fe_run_t);
		end
		if (f1_forced) f1_inc(G_FORCED);
		f1_run_q = u_fe.u_copy.run;
		// R3 once both sides are quiet: no service latched, pending or running on
		// either side. A burst (an RMW pair, or a service latched while one runs)
		// is compared at its end, every range of it: the two engines finish the
		// services of a burst at different times, and a later one may overwrite an
		// earlier one's range (E2's dpc_svc).
		if (f1_r3_d.size() > 0 && !(dut.arm_dma_busy && !dut.mapper_init_busy) &&
				!dut.cart2600.dpcplus.service_pending && !u_fe.u_copy.run && !u_fe.u_core.svc_hold &&
				f1_svc_up_done >= f1_r3_n + f1_r3_d.size() && f1_svc_fe_done >= f1_r3_n + f1_r3_d.size()) begin
			while (f1_r3_d.size() > 0) begin
				int dd, cc;
				dd = int'(f1_r3_d.pop_front());
				cc = int'(f1_r3_c.pop_front());
				f1_r3_n++;
				f1_inc(G_R3_N);
				n = 0;
				for (int a = dd; a < dd + cc; a++) if (fe_ram_byte(17'(a)) != ft_cb(a)) n++;
				`F1_CHK(n != 0, G_SVC_RAM_BAD, $sformatf("R3: %0d of the %0d bytes at $%04x differ", n, cc, dd))
			end
		end

		// ---- I1/I2 at the first edge both inits are done; the ROM check after the load --------
		// (the download's end from the cart_download level, as cart_win above)
		if ((!cart_download && f1_cd_q) || (f1_loaded && !cart_download && dut.effective_reset && !f1_erst_q)) begin
			f1_i_arm = 1;
			f1_i_up = 0;
			f1_i_fe = 0;
			if (f1_tot[G_INIT_N] == 0)
				$display("FE load: the download ends at clk_sys %0d (the bench's view); u_fe's F6 window falls %0d clk_sys later",
					f1_clk, 63);
		end
		f1_erst_q = dut.effective_reset;
		f1_cd_q = cart_download;
		// the inits' edges, for the log (first load and each console reset)
		if (u_fe.u_copy.ld1) f1_t_ld1 = f1_clk;
		if (u_fe.f6_act && !f1_f6_q) f1_t_f6 = f1_clk;
		if (!u_fe.f6_act && f1_f6_q && f1_nf6 < 4) begin
			f1_nf6++;
			$display("FE init: u_fe saw load_end at clk_sys %0d; F6 ran from clk_sys %0d for %0d clk_sys (scheme %0d, ram32 %0d); upstream's init busy %0d",
				f1_t_ld1, f1_t_f6, f1_clk - f1_t_f6, force_bs, dut.mapper_ram_size == 16'd32768, dut.mapper_init_busy);
		end
		if (!dut.mapper_init_busy && f1_ib_q && f1_nf6 < 4)
			$display("FE init: upstream's init done at clk_sys %0d", f1_clk);
		f1_f6_q = u_fe.f6_act;
		f1_ib_q = dut.mapper_init_busy;
		if (f1_i_arm) begin
			if (dut.mapper_init_busy) f1_i_up = 1;
			if (u_fe.init_busy) f1_i_fe = 1;
			if (f1_i_up && f1_i_fe && !dut.mapper_init_busy && !u_fe.init_busy) begin
				f1_i_arm = 0;
				if (scheme_ok) begin
					f1_inc(G_INIT_N);
					n = f1_ram_cmp("I1", f1_ram_words()) + f1_tbl_cmp("I2");
					`F1_CHK(n != 0, G_INIT_BAD, $sformatf("I1/I2: %0d cart RAM / table words differ after init", n))
				end
			end
		end
		if (running && !f1_rom_done) begin
			f1_rom_done = 1;
			n = 0;
			for (int w = 0; w < (cart_size > 32768 ? 32768 : int'(cart_size)) / 4; w++)
				if (ft_rom(w) != {img[4 * w + 3], img[4 * w + 2], img[4 * w + 1], img[4 * w]}) n++;
			`F1_CHK(n != 0, G_ROM_BAD, $sformatf("the front-end ROM after the load: %0d words differ from the image", n))
			if (fe_is_dpc && cart_size < 32768) f1_inc(G_SHORT_IMAGE);
			if (f1_never_busy != 0) `F1_CHK(1, G_INIT_NEVER, "fe_init_never_busy: the hold timed out")
		end
	end

	// ---- self-test: one fault injected into u_fe or fe_mem (+fe1_inj=K at checked
	// cycle +fe1_inj_at=N, default 20000; off by default). Each must be caught:
	//   1 fe_do bit 0 flipped in the clock before a shown cartridge read latch -> L1 dout
	//   2 counter[0] + 1 (a quiet clock)                         -> A1 audio_bad, resync
	//   3 u_core.fpend inverted in phase 2                       -> C1/C2 state
	//   4 cart RAM word $100 of fe_mem inverted                  -> K2 (or K1) RAM
	//   5 DPC+: fetcher 0's w0 counter + 1 / CDF: pointer of stream 0 + $100000 -> C1 / C3, L1
	//   6 AMPLITUDE inverted in u_audio (a quiet clock)           -> A1 audio_bad (replica)
	//   7 u_core.bank + 1                                         -> C1/C2 state, L1
	//   8 u_copy.dma_busy forced 1 for 200 clk_sys (a DPC+ service only daria_fe
	//     sees): the hold must stall the 6507 (forced arm_call_stall) and every
	//     check must stay 0, H1 included
	//   9 a posted word (F5, frequency 0) changed after the post         -> R1 call_bad
	//  10 CDF: a return word (FB, frequency 0) changed while u_call reads them -> A1 audio_bad
	int     fe1_inj = 0, fe1_inj_at = 20000;
	logic   f1_inj_done = 0;
	longint f1_inj_rel = -1;
	always @(negedge clk_sys) begin
		if (f1_inj_rel >= 0 && f1_clk >= f1_inj_rel) begin
			release u_fe.u_copy.dma_busy;			// holds 1 until its next rel_ok (7.4)
			f1_inj_rel = -1;
			$display("FE inject: arm_dma_busy released at clk_sys %0d", f1_clk);
		end
		if (fe1_inj != 0 && !f1_inj_done && f1_live && f1_tot[G_CYCLES] >= fe1_inj_at) begin
			case (fe1_inj)
				1: if (dut.pclk0 && dut.RW && dut.cart2600.a_in[12] && dut.mapper_phi2) begin
					u_fe.u_core.fe_do = u_fe.u_core.fe_do ^ 8'h01;
					f1_inj_done = 1;
				end
				2: if (!f1_m_cf && f1_w == 0 && ft_aud_quiet()) begin
					u_fe.u_audio.counter[0] = u_fe.u_audio.counter[0] + 32'd1;
					f1_inj_done = 1;
				end
				3: if (u_fe.u_seq.ph2 && !dut.pclk1) begin	// after the commit: the next E0 sees it
					u_fe.u_core.fpend = !u_fe.u_core.fpend;
					f1_inj_done = 1;
				end
				4: begin
					fe_mem.cart_ram.mem_q[13'h100] = ~fe_mem.cart_ram.mem_q[13'h100];
					f1_inj_done = 1;
				end
				5: begin
					if (fe_is_dpc) fe_mem.state_ram.mem_q[0] = fe_mem.state_ram.mem_q[0] + 32'd1;
					else fe_mem.cart_ram.mem_q[13'(ft_pb())] = fe_mem.cart_ram.mem_q[13'(ft_pb())] + 32'h0010_0000;
					f1_inj_done = 1;
				end
				6: if (!f1_m_rep && ft_aud_quiet()) begin
					u_fe.u_audio.amplitude = ~u_fe.u_audio.amplitude;
					f1_inj_done = 1;
				end
				7: begin
					u_fe.u_core.bank = u_fe.u_core.bank + 3'd1;
					f1_inj_done = 1;
				end
				9: if (u_fe.call_tog != f1_tog2) begin		// the post is complete, R1 reads it next edge
					fe_mem.state_ram.mem_q[8'hF5] = fe_mem.state_ram.mem_q[8'hF5] ^ 32'h0000_0100;
					f1_inj_done = 1;
				end
				10: if (u_fe.u_call.st[4] && fe_is_cdf) begin	// RD: F8 was read, F9-FD follow
					fe_mem.state_ram.mem_q[8'hFB] = fe_mem.state_ram.mem_q[8'hFB] + 32'd1;
					f1_inj_done = 1;
				end
				8: if (dut.tia_en && !dut.arm_call_busy && !dut.arm_dma_busy) begin
					force u_fe.u_copy.dma_busy = 1'b1;		// released 200 clk_sys later
					f1_inj_rel = f1_clk + 200;
					f1_inj_done = 1;
					// The hold's own negedge block may have run before this one in this
					// time step (it saw arm_dma_busy low): apply its force here too, as it
					// would for a busy that rose at the last posedge.
					if (fe_hold != 0 && !dut.mapper_init_busy && !f1_forced) begin
						force dut.arm_call_stall = 1'b1;
						f1_forced = 1'b1;
					end
				end
				default: f1_inj_done = 1;
			endcase
			if (f1_inj_done)
				$display("FE inject: daria_fe fault %0d at clk_sys %0d (frame %0d, checked cycle %0d)", fe1_inj, f1_clk,
					f1_frame, f1_tot[G_CYCLES]);
		end
	end

	// ---- the resync (falling edge): upstream's audio state into u_fe at a quiet point -------
	always @(negedge clk_sys) begin
		if (f1_m_rep || f1_m_cf) begin
			if (dut.effective_reset) begin
				f1_m_rep = 0;				// both engines are in reset
				f1_m_cf = 0;
			end else if (fe_resync != 0 && f1_w == 0 && ft_aud_quiet()) begin
				fe_deposit_audio(f1_m_cf);
				if (f1_m_cf) f1_inc(G_DEPOSIT_CF);
				f1_inc(G_RESYNC);
				f1_m_rep = 0;
				f1_m_cf = 0;
			end
		end
	end

	// ---- K1: the whole cart RAM at each upstream call start (clk_arm) ---------------------------
	logic f1_run_arm_q = 0;
	always @(posedge clk_arm) begin
		int n;
		f1_run_arm_q <= ctl_state == CTRL_RUNNING;
		if (ctl_state == CTRL_RUNNING && !f1_run_arm_q && (fe_is_dpc || fe_is_cdf) && running) begin
			f1_inc(G_K1);
			n = f1_ram_cmp("K1", f1_ram_words());
			`F1_CHK(n != 0, G_RAM_CALL_BAD, $sformatf("K1: %0d cart RAM words differ at a call start", n))
		end
	end

	// ---- the report -------------------------------------------------------------------------
	task automatic f1_report();
		longint nbad, ram;
		string s, cl, sep, rng, res, cn;
		nbad = 0;
		s = "";
		for (int c = 0; c < G_N; c++)
			if (f1_bad[c]) begin
				nbad += f1_tot[c];
				sep = ", ";
				if (s.len() == 0) sep = "";
				s = {s, sep, $sformatf("%s %0d", f1_nm[c], f1_tot[c])};
			end
		// posts and accepts that never found their pair
		if (f1_tot[G_CALLS_UP] - f1_tot[G_DROP_UP] != f1_tot[G_CALLS_FE] - f1_tot[G_DROP_FE]) nbad++;
		if (f1_tot[G_SVC] != f1_tot[G_SVC_FE]) nbad++;
		ram = f1_tot[G_PTR] + f1_tot[G_RAM] + f1_tot[G_INIT_BAD] + f1_tot[G_RAM_CALL_BAD] + f1_tot[G_RAM_FRAME_BAD] +
			f1_tot[G_SVC_RAM_BAD];
		if (!fe_is_dpc && !fe_is_cdf) begin
			$display("FE shadow: %s not shadowed", fe_scheme_name());
			return;
		end
		rng = "none";
		if (f1_emax >= 0) rng = $sformatf("%0d..%0d", f1_emin, f1_emax);
		cn = "C2";
		if (fe_is_dpc) cn = "C1";
		res = "FAIL";
		if (nbad == 0) res = "PASS";
		$display("FE shadow: %s %0d latches, %0d commits, %0d calls, %0d services, %0d ticks compared; dout %0d, state %0d, ram %0d, call %0d, svc %0d, tick %0d, audio %0d bad; amp_lag %0d, races %0d/%0d/%0d, resync %0d, obus_exposed %0d, over32k %0d, wb_drop %0d, hold %0d; E0->latch %s",
			fe_scheme_name(), f1_tot[G_LATCH], f1_tot[G_COMMIT], f1_tot[G_CALLS_UP], f1_tot[G_SVC], f1_tot[G_TICKS],
			f1_tot[G_DOUT], f1_tot[G_STATE], ram, f1_tot[G_CALL_BAD], f1_tot[G_SVC_BAD], f1_tot[G_TICK_BAD],
			f1_tot[G_AUDIO_BAD], f1_tot[G_AMP_LAG], f1_tot[G_NOTE_RACE], f1_tot[G_MERGE_RACE], f1_tot[G_SEED_RACE],
			f1_tot[G_RESYNC], f1_tot[G_OBUS], f1_tot[G_OVER32K], f1_tot[G_WB_DROP], f1_tot[G_HOLD_BAD],
			rng);
		$display("FE bad: %s; calls up %0d / fe %0d, services up %0d / fe %0d; total %0d",
			s, f1_tot[G_CALLS_UP], f1_tot[G_CALLS_FE], f1_tot[G_SVC], f1_tot[G_SVC_FE], nbad);
		cl = "";
		foreach (f1_nm[c])
			if (c >= G_MERGE_AMP && c <= G_GRANT_STEAL || c == G_MERGE_RACE || c == G_SIZE_OVER32K ||
				c == G_P32_RESET || c == G_SHORT_IMAGE || c == G_Q26 || c == G_SHORT_DOUT || c == G_AMP_CLASS ||
				c == G_RMW_SEED || c == G_RMW_MERGE || c == G_DRIFT_UP || c == G_DRIFT_FE || c == G_RESYNC ||
				c == G_DEPOSIT_CF)
				begin
					sep = ", ";
					if (cl.len() == 0) sep = "";
					cl = {cl, sep, $sformatf("%s %0d", f1_nm[c], f1_tot[c])};
				end
		$display("FE classes: %s", cl);
		$display("FE counts: %0d read latches compared (%0d AMPLITUDE), %0d hidden pclk0 (%0d differ, information; %0d the last of a stall), %0d cycles compared (%s), %0d pointer writes (C3), %0d 6507 RAM writes (C4), %0d inits (I1/I2), %0d call starts (K1), %0d frames (K2), %0d CDF merges own path / %0d through the hook, %0d crb_use clocks, mode A guard locked %0d clocks; %0d services' RAM compared (R3), %0d clocks of the stall forced by the hold",
			f1_tot[G_READS], f1_tot[G_AMP_READS], f1_tot[G_HIDDEN], f1_tot[G_DOUT_HID], f1_tot[G_HID_LAST],
			f1_tot[G_CYCLES], cn, f1_tot[G_PTR_N], f1_tot[G_RAM_N], f1_tot[G_INIT_N],
			f1_tot[G_K1], f1_tot[G_K2], f1_tot[G_MERGES], f1_tot[G_HK_MERGES], f1_tot[G_CRB_USE], f1_tot[G_DET_LOCK_A],
			f1_tot[G_R3_N], f1_tot[G_FORCED]);
		if (f1_mask_t0 >= 0 && f1_clk - f1_mask_t0 > f1_mask_long) f1_mask_long = f1_clk - f1_mask_t0;
		$display("FE masks: A1 masked by a class or a failure on %0d clk_sys, the longest mask %0d clk_sys (mask_stuck above %0d); %0d merges M_fe - M not 6 (merge_late)",
			f1_tot[G_MASKED], f1_mask_long, fe_mask_max, f1_tot[G_MERGE_LATE]);
		$display("FE inputs: hook %0d, slat %0d, hold %0d, resync %0d, K2 every %0d frames; %0d daria_fe failures logged",
			fe_merge_hook, fe_slat, fe_hold, fe_resync, fe_full, f1_nfail);
		$display("FE latency: post - accept {%s}; merge M_fe - M {%s}; busy fall fe - up {%s}; refresh up {%s}; refresh fe {%s}; NOTE capture fe - up {%s}; upstream ROM sample R -> sample_done {%s}",
			f1_hist(f1_h_post), f1_hist(f1_h_merge), f1_hist(f1_h_busy), f1_hist(f1_h_rup), f1_hist(f1_h_rfe),
			f1_hist(f1_h_note), f1_hist(f1_h_slat));
		$display("FE digital: upstream's digital refreshes by route: ROM below 32 KB %0d, ROM above (u_fe's sample port) %0d, cart RAM window %0d, out of range %0d; T5: %0d ROM-sample amplitudes compared (%0d differ), %0d in a merge window",
			f1_tot[G_DIG_LOCAL], f1_tot[G_DIG_REMOTE], f1_tot[G_DIG_RAM], f1_tot[G_DIG_NONE], f1_tot[G_DIG_VAL_N],
			f1_tot[G_DIG_VAL_BAD], f1_tot[G_DIG_VAL_MRG]);
		$display("FE result: %s (%0d bad)", res, nbad);
		if (fd_f1 != 0) $fclose(fd_f1);
		if (fd_f1_ticks != 0) $fclose(fd_f1_ticks);
		if (fd_amp_up != 0) begin
			$fclose(fd_amp_up);
			$fclose(fd_amp_fe);
		end
	endtask

	initial begin
		// names (fe.csv's header) and which counters must stay 0
		f1_nm[G_LATCH] = "latches";             f1_nm[G_COMMIT] = "commits";           f1_nm[G_DOUT] = "dout_bad";
		f1_nm[G_DOUT_HID] = "dout_hidden";      f1_nm[G_STATE] = "state_bad";          f1_nm[G_PTR] = "ptr_bad";
		f1_nm[G_RAM] = "ram_bad";               f1_nm[G_CALLS_UP] = "calls_up";        f1_nm[G_CALLS_FE] = "calls_fe";
		f1_nm[G_CALL_BAD] = "call_bad";         f1_nm[G_SVC] = "svc";                  f1_nm[G_SVC_BAD] = "svc_bad";
		f1_nm[G_TICKS] = "ticks";               f1_nm[G_TICK_BAD] = "tick_bad";        f1_nm[G_AUDIO_BAD] = "audio_bad";
		f1_nm[G_AMP_LAG] = "amp_lag";           f1_nm[G_NOTE_RACE] = "note_race";      f1_nm[G_MERGE_RACE] = "merge_race";
		f1_nm[G_SEED_RACE] = "seed_race";       f1_nm[G_RESYNC] = "resync";            f1_nm[G_DRIFT_UP] = "drift_up";
		f1_nm[G_DRIFT_FE] = "drift_fe";         f1_nm[G_OBUS] = "obus_exposed";        f1_nm[G_OVER32K] = "over32k";
		f1_nm[G_HOLD_BAD] = "hold_bad";         f1_nm[G_MERGE_AMP] = "merge_amp";      f1_nm[G_RET_LATE] = "ret_late";
		f1_nm[G_DIG_ROM_LAG] = "dig_rom_lag";   f1_nm[G_SVC_AUDIO_RACE] = "svc_audio_race";
		f1_nm[G_PAUSE_LANE] = "pause_lane";     f1_nm[G_PRE_LOCK] = "pre_lock";        f1_nm[G_TBL_ALIAS] = "tbl_alias";
		f1_nm[G_RMW_CALL] = "rmw_call";         f1_nm[G_RMW_SVC] = "rmw_svc";          f1_nm[G_SHORT_PHASE1] = "short_phase1";
		f1_nm[G_GRANT_STEAL] = "grant_steal";   f1_nm[G_A_COLLIDE] = "a_collide";      f1_nm[G_A_WB_LATE] = "a_wb_late";
		f1_nm[G_A_P32_LATE] = "a_p32_late";     f1_nm[G_A_GUARD_CORE] = "a_guard_core"; f1_nm[G_A_GUARD_WR] = "a_guard_wr";
		f1_nm[G_A_OWNER] = "a_owner";           f1_nm[G_A_FPJR] = "a_fpjr";            f1_nm[G_A_PEND_LATE] = "a_pend_late";
		f1_nm[G_A_TDEF2] = "a_tdef2";           f1_nm[G_A_F6_LIVE] = "a_f6_live";      f1_nm[G_CRB_USE] = "crb_use";
		f1_nm[G_SVC_RAM_BAD] = "svc_ram_bad";   f1_nm[G_INIT_BAD] = "init_bad";        f1_nm[G_RAM_CALL_BAD] = "ram_call_bad";
		f1_nm[G_RAM_FRAME_BAD] = "ram_frame_bad"; f1_nm[G_HID_LAST] = "hidden_last";   f1_nm[G_HID_LAST_BAD] = "hidden_last_bad";
		f1_nm[G_COMMIT_HIDDEN] = "commit_on_hidden"; f1_nm[G_RET_UNASKED] = "ret_unasked"; f1_nm[G_A2_BAD] = "a2_bad";
		f1_nm[G_A3_BAD] = "a3_bad";             f1_nm[G_SIZE_OVER32K] = "size_over32k"; f1_nm[G_P32_RESET] = "p32_reset";
		f1_nm[G_WB_DROP] = "wb_drop";           f1_nm[G_RAM_WR_NOACC] = "ram_wr_noaccess"; f1_nm[G_DET_LOCK_A] = "det_lock_a";
		f1_nm[G_DIG_BAD] = "dig_bad";           f1_nm[G_ROM_BAD] = "rom_bad";          f1_nm[G_DIN_BAD] = "din_bad";
		f1_nm[G_RET_MODEL_BAD] = "ret_model_bad"; f1_nm[G_INIT_NEVER] = "init_never_busy"; f1_nm[G_READS] = "reads";
		f1_nm[G_HIDDEN] = "hidden";             f1_nm[G_CYCLES] = "cycles";            f1_nm[G_PTR_N] = "ptr_writes";
		f1_nm[G_RAM_N] = "ram_writes";          f1_nm[G_K1] = "k1_calls";              f1_nm[G_K2] = "k2_frames";
		f1_nm[G_INIT_N] = "inits";              f1_nm[G_SVC_FE] = "svc_fe";            f1_nm[G_MERGES] = "merges";
		f1_nm[G_HK_MERGES] = "hook_merges";     f1_nm[G_AMP_READS] = "amp_reads";      f1_nm[G_AMP_CLASS] = "amp_class";
		f1_nm[G_SHORT_DOUT] = "short_dout";     f1_nm[G_Q26] = "q26";                  f1_nm[G_SHORT_IMAGE] = "short_image";
		f1_nm[G_RMW_SEED] = "rmw_seed";         f1_nm[G_DEPOSIT_CF] = "deposit_cf";
		f1_nm[G_DROP_UP] = "drop_up";           f1_nm[G_DROP_FE] = "drop_fe";
		f1_nm[G_R3_N] = "svc_ram_compares";     f1_nm[G_FORCED] = "stall_forced";
		f1_nm[G_RMW_MERGE] = "rmw_merge";
		f1_nm[G_DIG_LOCAL] = "dig_rom_local";   f1_nm[G_DIG_REMOTE] = "dig_rom_remote";
		f1_nm[G_DIG_RAM] = "dig_ram_window";    f1_nm[G_DIG_NONE] = "dig_out_of_range";
		f1_nm[G_MERGE_LATE] = "merge_late";     f1_nm[G_DMA_COVER] = "dma_cover";
		f1_nm[G_MASK_STUCK] = "mask_stuck";     f1_nm[G_MASKED] = "masked_clocks";
		f1_nm[G_DIG_VAL_BAD] = "dig_val_bad";   f1_nm[G_DIG_VAL_N] = "dig_val_n";      f1_nm[G_DIG_VAL_MRG] = "dig_val_merge";
		foreach (f1_bad[c]) f1_bad[c] = 0;
		foreach (f1_tot[c]) begin f1_tot[c] = 0; f1_frm[c] = 0; end
		foreach (f1_h_post[b]) begin
			f1_h_post[b] = 0; f1_h_merge[b] = 0; f1_h_busy[b] = 0; f1_h_rup[b] = 0; f1_h_rfe[b] = 0; f1_h_note[b] = 0;
			f1_h_slat[b] = 0;
		end
		foreach (f1_bad[c])
			case (c)
				G_DOUT, G_STATE, G_PTR, G_RAM, G_CALL_BAD, G_SVC_BAD, G_TICK_BAD, G_AUDIO_BAD, G_AMP_LAG,
				G_NOTE_RACE, G_SEED_RACE, G_OBUS, G_OVER32K, G_HOLD_BAD, G_A_COLLIDE, G_A_WB_LATE, G_A_P32_LATE,
				G_A_GUARD_CORE, G_A_GUARD_WR, G_A_OWNER, G_A_FPJR, G_A_PEND_LATE, G_A_TDEF2, G_A_F6_LIVE,
				G_SVC_RAM_BAD, G_INIT_BAD, G_RAM_CALL_BAD, G_RAM_FRAME_BAD, G_HID_LAST_BAD, G_COMMIT_HIDDEN,
				G_RET_UNASKED, G_A2_BAD, G_A3_BAD, G_WB_DROP, G_RAM_WR_NOACC, G_DET_LOCK_A, G_DIG_BAD, G_ROM_BAD,
				G_DIN_BAD, G_RET_MODEL_BAD, G_INIT_NEVER, G_MERGE_LATE, G_DMA_COVER, G_MASK_STUCK,
				G_DIG_VAL_BAD: f1_bad[c] = 1;
				default: ;
			endcase
		void'($value$plusargs("fe_slat=%d", fe_slat));
		void'($value$plusargs("fe_merge_hook=%d", fe_merge_hook));
		void'($value$plusargs("fe_hold=%d", fe_hold));
		void'($value$plusargs("fe_resync=%d", fe_resync));
		void'($value$plusargs("fe_full=%d", fe_full));
		void'($value$plusargs("fe_ticks=%d", fe_ticks));
		void'($value$plusargs("fe_pcm=%d", fe_pcm));
		void'($value$plusargs("fe1_inj=%d", fe1_inj));
		void'($value$plusargs("fe1_inj_at=%d", fe1_inj_at));
		void'($value$plusargs("fe_mask_max=%d", fe_mask_max));
		if (fe_slat < 0) fe_slat = 0;
		$display("FE stage 1: daria_fe on fe_mem, mode A; +fe_merge_hook=%0d +fe_slat=%0d +fe_hold=%0d +fe_resync=%0d +fe_full=%0d",
			fe_merge_hook, fe_slat, fe_hold, fe_resync, fe_full);
		#1;
		fd_f1 = $fopen({out, "fe.csv"}, "w");
		$fwrite(fd_f1, "frame");
		for (int c = 0; c < G_N; c++) $fwrite(fd_f1, ",%s", f1_nm[c]);
		$fwrite(fd_f1, "\n");
		if (fe_ticks != 0) begin
			fd_f1_ticks = $fopen({out, "fe_ticks.csv"}, "w");
			$fwrite(fd_f1_ticks, "clk_sys,amp_up,amp_fe,masked,class\n");
		end
		if (fe_pcm != 0) begin
			fd_amp_up = $fopen({out, "amp_up.pcm"}, "wb");
			fd_amp_fe = $fopen({out, "amp_fe.pcm"}, "wb");
		end
	end
`undef F1_CHK
`endif

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
