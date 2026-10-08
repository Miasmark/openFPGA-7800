//------------------------------------------------------------------------------
// The front-end shadow's tap map (DARIA step 6, stage 1): included by
// fe_shadow.svh (tb_daria.sv with -DFE_SHADOW, not with -DFE_STAGE0).
//
// One place that knows where daria_fe (u_fe) and its memories (fe_mem) keep
// the state upstream's front ends keep in flip-flops (docs/daria_fe/design.md
// 1.7 and 4; docs/daria_fe/interfaces.md 4-5 for the frozen names, widths and
// one-hot encodings). Every read here is hierarchical and read-only, except
// fe_deposit_audio, the resync of design 12.4 / bench.md 7.6. When daria_fe
// moves a register or a state RAM word, only this file changes.
//
//   state RAM   fe_mem.state_ram.mem_q[w]: DPC+ fetcher i in w0 = word 2i
//               {bottom, top, x:counter[11:8], counter[7:0]} (mask FFFF0FFF)
//               and w1 = word 2i+1 {increment, x:fraction[19:16],
//               fraction[15:0]} (mask FF0FFFFF); params 0-3 in word $10,
//               lanes 0-3; the call block F0-FD (posts F0-F7, returns F8-FD)
//   cart RAM    fe_mem.cart_ram.mem_q[w]: the image F6 builds, the CDF
//               pointers and increments in place at pb + i and ib + i (word
//               addresses; pb/ib by revision, design 2.4)
//   flip-flops  u_fe.u_core (scheme state), u_fe.u_audio (the replica),
//               u_fe.u_call, u_fe.u_copy, u_fe.u_arb, u_fe.u_guard (1.7)
//
// Upstream (the oracle): dut.cart2600.{dpcplus, cdf, mapper_audio,
// stream_tables}, and dut.cart_ram (cart_ram_tdp's four byte lanes).
//
// The comparison functions return "" when equal, else the first field that
// differs, both values. They read pre-edge values when called from a
// posedge block (the state the last edge left).
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`define FT_CMP(name, fe, up) if ((fe) != (up)) return $sformatf("%s %0h, upstream %0h", name, fe, up);

	// ---- memories --------------------------------------------------------------------
	function automatic logic [31:0] ft_sw(input int w);           // fe_mem state RAM word
		return fe_mem.state_ram.mem_q[w[7:0]];
	endfunction
	function automatic logic [31:0] ft_cw(input int w);           // fe_mem cart RAM word
		return fe_mem.cart_ram.mem_q[w[12:0]];
	endfunction
	function automatic logic [7:0] ft_cb(input int a);            // fe_mem cart RAM byte
		logic [31:0] w;
		w = fe_mem.cart_ram.mem_q[a[14:2]];
		return w[8 * a[1:0] +: 8];
	endfunction
	function automatic logic [31:0] ft_uw(input int w);           // upstream cart RAM word (cart_ram_tdp)
		return {dut.cart_ram.ram_lane[3].lane_ram.mem_q[w[14:0]], dut.cart_ram.ram_lane[2].lane_ram.mem_q[w[14:0]],
			dut.cart_ram.ram_lane[1].lane_ram.mem_q[w[14:0]], dut.cart_ram.ram_lane[0].lane_ram.mem_q[w[14:0]]};
	endfunction
	function automatic logic [31:0] ft_rom(input int w);          // fe_mem front-end ROM word
		return fe_mem.fe_rom.mem_q[w[12:0]];
	endfunction

	// ---- CDF table layout (design 2.4, 4.3; arm_mapper_tables.sv:104-121) --------------
	function automatic int ft_pb();
		return mapper_revision[1:0] == 2'd0 ? 'h1B8 : (mapper_revision[1:0] == 2'd1 ? 'h028 : 'h026);
	endfunction
	function automatic int ft_ib();
		return mapper_revision[1:0] == 2'd0 ? 'h1DA : (mapper_revision[1:0] == 2'd1 ? 'h04A : 'h049);
	endfunction
	function automatic int ft_streams();
		return mapper_revision[1] ? 35 : 34;
	endfunction

	// ---- C1: DPC+ (bench.md 7.3's floor) ---------------------------------------------
	// Fetchers from the state RAM words (masked), params 0-3 from word $10, pptr
	// against parameter_pointer directly (design 1.7: both count to 8), the LFSR,
	// bank, fast fetch, waveforms; call_pending from u_call's pend_up (design 6.4),
	// service_pending from the core's svc_pend.
	function automatic string ft_c1();
		logic [31:0] w0, w1, wp;
		for (int i = 0; i < 8; i++) begin
			w0 = ft_sw(2 * i);
			w1 = ft_sw(2 * i + 1);
			`FT_CMP($sformatf("top[%0d]", i), w0[23:16], dut.cart2600.dpcplus.top[i])
			`FT_CMP($sformatf("bottom[%0d]", i), w0[31:24], dut.cart2600.dpcplus.bottom[i])
			`FT_CMP($sformatf("counter[%0d]", i), w0[11:0], dut.cart2600.dpcplus.counter[i])
			`FT_CMP($sformatf("fractional[%0d]", i), w1[19:0], dut.cart2600.dpcplus.fractional[i])
			`FT_CMP($sformatf("increment[%0d]", i), w1[31:24], dut.cart2600.dpcplus.increment[i])
		end
		wp = ft_sw(16);
		for (int i = 0; i < 4; i++)
			`FT_CMP($sformatf("params[%0d]", i), wp[8 * i +: 8], dut.cart2600.dpcplus.params[i])
		`FT_CMP("parameter_pointer (pptr)", u_fe.u_core.pptr, dut.cart2600.dpcplus.parameter_pointer)
		for (int i = 0; i < 3; i++)
			`FT_CMP($sformatf("waveform[%0d]", i), u_fe.u_core.wave[i], dut.cart2600.dpcplus.waveform[i])
		`FT_CMP("random_number (rnd)", u_fe.u_core.rnd, dut.cart2600.dpcplus.random_number)
		`FT_CMP("bank", u_fe.u_core.bank, dut.cart2600.dpcplus.bank)
		`FT_CMP("fast_fetch (ff_en)", u_fe.u_core.ff_en, dut.cart2600.dpcplus.fast_fetch)
		`FT_CMP("fast_pending (fpend)", u_fe.u_core.fpend, dut.cart2600.dpcplus.fast_pending)
		`FT_CMP("call_pending (pend_up)", u_fe.u_call.pend_up, dut.cart2600.dpcplus.call_pending)
		`FT_CMP("service_pending (svc_pend)", u_fe.u_core.svc_pend, dut.cart2600.dpcplus.service_pending)
		return "";
	endfunction

	// ---- C2: CDF; the addresses only while upstream reads them (bench.md 3.5) ---------
	function automatic string ft_c2();
		`FT_CMP("bank", u_fe.u_core.bank, dut.cart2600.cdf.bank)
		`FT_CMP("mode", u_fe.u_core.mode, dut.cart2600.cdf.mode)
		`FT_CMP("fast_pending (fpend)", u_fe.u_core.fpend, dut.cart2600.cdf.fast_pending)
		if (dut.cart2600.cdf.fast_pending)
			`FT_CMP("fast_expected_address (fexp)", u_fe.u_core.fexp, dut.cart2600.cdf.fast_expected_address)
		`FT_CMP("jump_remaining (jr)", u_fe.u_core.jr, dut.cart2600.cdf.jump_remaining)
		if (dut.cart2600.cdf.jump_remaining != 2'd0) begin
			`FT_CMP("expected_address (jexp)", u_fe.u_core.jexp, dut.cart2600.cdf.expected_address)
			`FT_CMP("jump_stream (jstream)", u_fe.u_core.jstream, dut.cart2600.cdf.jump_stream)
		end
		`FT_CMP("call_pending (pend_up)", u_fe.u_call.pend_up, dut.cart2600.cdf.call_pending)
		return "";
	endfunction

	// ---- C3: a stream's pointer, upstream's table copy against the word in place ------
	function automatic string ft_c3(input int idx);
		`FT_CMP($sformatf("pointer[%0d] (cart RAM word $%03x)", idx, ft_pb() + idx), ft_cw(ft_pb() + idx),
			dut.cart2600.stream_tables.pointer_ram.mem_q[idx])
		return "";
	endfunction

	// ---- A1: the audio registers against arm_mapper_audio, every clock -----------------
	// Three groups (the masks of the counted classes act per group):
	//   tick   accum, the tick strobe, the NOTE latch (nv, nval): never masked
	//   cf     counters and frequencies: masked in the merge window (M, M_fe] of
	//          a CDF call without the hook, and by a grant offset (grant_steal)
	//   rep    the replica: state (one-hot against the enum: the AS_* bit of
	//          each state is its enum value), the refresh snapshot rc, refresh
	//          and NOTE pending, voice, the sum, shift, offset, the digital
	//          registers, AMPLITUDE, the request and its address, the grant;
	//          ft_a1_rep(1) leaves out the two registers a sample byte writes
	//          (the sum and AMPLITUDE), which pause_lane masks alone
	`define FT_AUD dut.cart2600.mapper_audio
	function automatic string ft_a1_tick();
		`FT_CMP("accum", u_fe.u_audio.accum, `FT_AUD.tick_accum)
		`FT_CMP("tick", u_fe.u_audio.tick, `FT_AUD.audio_tick)
		`FT_CMP("nv (note_voice)", u_fe.u_audio.nv, `FT_AUD.note_voice)
		`FT_CMP("nval (note_value)", u_fe.u_audio.nval, `FT_AUD.note_value)
		return "";
	endfunction
	function automatic string ft_a1_cf();
		`FT_CMP("counter[0]", u_fe.u_audio.counter[0], `FT_AUD.counter0)
		`FT_CMP("counter[1]", u_fe.u_audio.counter[1], `FT_AUD.counter1)
		`FT_CMP("counter[2]", u_fe.u_audio.counter[2], `FT_AUD.counter2)
		`FT_CMP("freq[0]", u_fe.u_audio.freq[0], `FT_AUD.frequency0)
		`FT_CMP("freq[1]", u_fe.u_audio.freq[1], `FT_AUD.frequency1)
		`FT_CMP("freq[2]", u_fe.u_audio.freq[2], `FT_AUD.frequency2)
		return "";
	endfunction
	function automatic string ft_a1_rep(input logic no_byte);
		`FT_CMP("st (one-hot; upstream's state as 1 << state)", u_fe.u_audio.st, 12'd1 << `FT_AUD.state)
		for (int v = 0; v < 3; v++)
			`FT_CMP($sformatf("rc[%0d] (refresh_counter)", v), u_fe.u_audio.rc[v], `FT_AUD.refresh_counter[v])
		`FT_CMP("rp (refresh_pending)", u_fe.u_audio.rp, `FT_AUD.refresh_pending)
		`FT_CMP("np (note_pending)", u_fe.u_audio.np, `FT_AUD.note_pending)
		`FT_CMP("voice", u_fe.u_audio.voice, `FT_AUD.voice)
		if (!no_byte) `FT_CMP("ssum (sample_sum[7:0])", u_fe.u_audio.ssum, `FT_AUD.sample_sum[7:0])
		`FT_CMP("wsh (waveform_shift)", u_fe.u_audio.wsh, `FT_AUD.waveform_shift)
		`FT_CMP("woff (waveform_offset)", u_fe.u_audio.woff, `FT_AUD.waveform_offset)
		`FT_CMP("dig_addr (digital_address)", u_fe.u_audio.dig_addr, `FT_AUD.digital_address)
		`FT_CMP("dig_low (digital_low_nibble)", u_fe.u_audio.dig_low, `FT_AUD.digital_low_nibble)
		`FT_CMP("dig_ram (digital_ram_addr)", u_fe.u_audio.dig_ram, `FT_AUD.digital_ram_addr)
		`FT_CMP("dig_smp (digital_sample)", u_fe.u_audio.dig_smp, `FT_AUD.digital_sample)
		if (!no_byte) `FT_CMP("amplitude", u_fe.u_audio.amplitude, `FT_AUD.amplitude)
		`FT_CMP("aud_issue (ram_en)", u_fe.aud_issue, `FT_AUD.ram_en)
		if (`FT_AUD.ram_en)
			`FT_CMP("aud_addr (ram_addr)", {2'b00, u_fe.aud_addr}, `FT_AUD.ram_addr)
		`FT_CMP("aud_take (audio_ram_grant)", u_fe.aud_take, dut.cart2600.audio_ram_grant)
		return "";
	endfunction

	// Both engines quiet: the deposit's condition (design 12.1: both IDLE with
	// !tdef & !mwin & !rp & !np), and no sample in flight on either side.
	function automatic logic ft_aud_quiet();
		return `FT_AUD.state == 4'd0 && u_fe.u_audio.st == 12'd1 && !`FT_AUD.refresh_pending &&
			!u_fe.u_audio.rp && !`FT_AUD.note_pending && !u_fe.u_audio.np && !u_fe.u_audio.tdef &&
			!u_fe.mwin && !u_fe.u_audio.busy_l && !u_fe.u_audio.busy_r && !dut.cart2600.arm_sample_busy;
	endfunction

	// The resync (bench.md 7.6, design 12.1): upstream's replica state into
	// u_audio, at a falling clk_sys edge, only while ft_aud_quiet(). cf = 1 also
	// deposits the counters, the frequencies and the accumulator. These are the
	// registers that carry public_flat_rw (1.7).
	task automatic fe_deposit_audio(input logic cf);
		u_fe.u_audio.st = 12'd1 << `FT_AUD.state;
		u_fe.u_audio.rp = `FT_AUD.refresh_pending;
		u_fe.u_audio.np = `FT_AUD.note_pending;
		u_fe.u_audio.nv = `FT_AUD.note_voice;
		u_fe.u_audio.nval = `FT_AUD.note_value;
		u_fe.u_audio.voice = `FT_AUD.voice;
		u_fe.u_audio.ssum = `FT_AUD.sample_sum[7:0];
		u_fe.u_audio.wsh = `FT_AUD.waveform_shift;
		u_fe.u_audio.woff = `FT_AUD.waveform_offset;
		u_fe.u_audio.dig_addr = `FT_AUD.digital_address;
		u_fe.u_audio.dig_low = `FT_AUD.digital_low_nibble;
		u_fe.u_audio.dig_ram = `FT_AUD.digital_ram_addr;
		u_fe.u_audio.dig_smp = `FT_AUD.digital_sample;
		u_fe.u_audio.amplitude = `FT_AUD.amplitude;
		for (int v = 0; v < 3; v++) u_fe.u_audio.rc[v] = `FT_AUD.refresh_counter[v];
		if (cf) begin
			u_fe.u_audio.accum = `FT_AUD.tick_accum;
			u_fe.u_audio.counter[0] = `FT_AUD.counter0;
			u_fe.u_audio.counter[1] = `FT_AUD.counter1;
			u_fe.u_audio.counter[2] = `FT_AUD.counter2;
			u_fe.u_audio.freq[0] = `FT_AUD.frequency0;
			u_fe.u_audio.freq[1] = `FT_AUD.frequency1;
			u_fe.u_audio.freq[2] = `FT_AUD.frequency2;
		end
	endtask
	`undef FT_AUD

	// ---- the upstream refresh about to start at this edge (AUD:226-240) -----------------
	function automatic logic ft_up_dispatch();
		return dut.cart2600.mapper_audio.state == 4'd0 && dut.cart2600.mapper_audio.refresh_pending &&
			!(dut.cart2600.mapper_audio.note_pending && dut.cart2600.mapper_audio.family == 2'd1);
	endfunction

	// ---- R1: the call block u_call posted (F0-F7), as one 256-bit word -----------------
	function automatic logic [255:0] ft_posted();
		logic [255:0] p;
		for (int i = 0; i < 8; i++) p[32 * i +: 32] = ft_sw('hF0 + i);
		return p;
	endfunction
	// Upstream's payload at its accept edge (arm_mapper_controller.sv:149-161), in
	// daria_call's layout (F0 entry | T, F1 stack, F2-F4 counters, F5-F7 frequencies).
	function automatic logic [255:0] ft_payload();
		return {dut.cart2600.arm_audio_frequency2, dut.cart2600.arm_audio_frequency1,
			dut.cart2600.arm_audio_frequency0, dut.cart2600.arm_audio_counter2,
			dut.cart2600.arm_audio_counter1, dut.cart2600.arm_audio_counter0,
			dut.cart2600.arm_call_stack, dut.cart2600.arm_call_entry[31:1], dut.cart2600.arm_call_thumb};
	endfunction

	// ---- R2: a latched service, in upstream's terms {fill, source, dest, count, value} ---
	// u_core latches the requested p3 (svc_rem); upstream's count is min() of the
	// two clamps (mapper_dpcplus.sv:85-101): fill min(p3, $1000 - counter), copy
	// also 0 for an offset >= $7400, else min(that, $7400 - offset).
	function automatic logic [51:0] ft_svc_fe();
		logic [12:0] dav;
		logic [16:0] off, sav;
		logic  [7:0] fc, cc;
		dav = 13'h1000 - (u_fe.u_core.svc_dst - 13'h0C00);
		off = u_fe.u_core.svc_src - 17'h00C00;
		sav = 17'h07400 - off;
		fc = (dav < {5'd0, u_fe.u_core.svc_rem}) ? dav[7:0] : u_fe.u_core.svc_rem;
		cc = (off >= 17'h07400) ? 8'd0 : ((sav < {9'd0, fc}) ? sav[7:0] : fc);
		return {u_fe.u_core.svc_fill, 2'b00, u_fe.u_core.svc_src, 2'b00, u_fe.u_core.svc_dst,
			u_fe.u_core.svc_fill ? fc : cc, u_fe.u_core.svc_val};
	endfunction
	function automatic logic [51:0] ft_svc_up();
		return {dut.cart2600.dpcplus.service_fill, dut.cart2600.dpcplus.service_source,
			dut.cart2600.dpcplus.service_dest, dut.cart2600.dpcplus.service_count,
			dut.cart2600.dpcplus.service_value};
	endfunction

`undef FT_CMP
