//------------------------------------------------------------------------------
// DARIA front end: the audio engine (docs/daria_fe/design.md 5, 9.3).
//
// Upstream's arm_mapper_audio (src/fpga/mister/rtl/arm_mapper_audio.sv, AUD)
// re-expressed clock for clock under D10, without BUS, waveform_pointer
// (never read) or sample_sum[9:8] (never used): every register below has
// one load enable and a data mux of at most four sources, written as its own
// row of design 5.3's table. The replica's grant is aud_take from u_arb
// (upstream's rule, with sel_up for sel_ram_sel), its words are cart RAM
// port B's q, and its next state is a function of its own registers and of
// design 5.2's inputs only, so st, voice, the grant edges, aud_addr and
// amplitude follow upstream's on every clock (5.9).
//
//   tick      the 20 kHz Bresenham, reset by cart_reset only (AUD:191-199)
//   counter,  each with one adder whose inputs fold the merge (a merge beats
//   freq      a tick on its edge, AUD:213-219), NOTE's frequency load and the
//             bench hook (hk_*, tied 0 in synthesis)
//   ring      six words: the payload captured at L (cp_cap), rotated while
//             u_call posts F2-F7 (cp_rot), the six returns shifted in from
//             state RAM (cp_shin) with take[] formed against the seeds
//             (cp_cmp); applied at M_fe (cp_apply)
//   tdef      a tick inside the merge window (mwin) is still counted for
//             the refresh (rp), but its add waits for M_fe+1 and then uses
//             the returned frequency (late; 5.6)
//   replica   IDLE, NISS/NCAP, PISS/PCAP, SZISS/SZCAP, SMISS/SMCAP,
//             DROUTE, RISS/RWAIT, one-hot (daria_fe_pkg::AS_*), AUD:225-363
//   sample    local (< 32 KB) from the front-end ROM's port A, amplitude at
//   client    R+4 (upstream's hit timing); remote through the sample port
//             (smp_req toggle, smp_addr, smp_ack toggle, smp_data held);
//             neither busy flag is reset by cart_reset (5.7, G7)
//
// Where design 5.3/5.5 restate an upstream condition more narrowly, the
// upstream condition is kept (docs/daria_fe/lanes/B_audio.md, 1.3): the
// pointer window of woff uses revision == 3 (AUD:281), the waveform base is
// $7F4 outside CDF (AUD:100-102), the RAM route of DIGITAL_ROUTE comes after
// the ROM compare (AUD:336-343), and the merge, the seeds and the hook use
// family >= 2 (AUD:207, 213). The byte lane al loads at every unpaused edge,
// as upstream's lane register does (B-1), not only on a grant.
//
// Reset: cart_reset only (never rst_fe); the sample client's busy flags,
// its toggle and address are not reset at all.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_fe_audio (
	input  wire          clk_sys,
	input  wire          cart_reset,
	input  wire          pause,        // pause_core
	input  wire    [1:0] fam,          // 1 DPC+, 3 CDF, 0 otherwise (live)
	input  wire    [1:0] rev,          // revision[1:0]
	input  wire   [31:0] rom_size,
	input  wire          ram32,        // ram_size = ram32 ? $8000 : $2000
	input  wire   [15:0] asz,          // audio_size_addr
	input  wire          cdf_dig,      // from u_core: mode[7:4] == 0
	input  wire    [6:0] wave0,        // from u_core
	input  wire    [6:0] wave1,
	input  wire    [6:0] wave2,
	input  wire          note_stb,     // pulse in (C, C+1)
	input  wire    [1:0] note_v,
	input  wire    [7:0] note_val,
	// call (from u_call, 6)
	input  wire          cp_cap,       // pulse: the ring captures counters and frequencies
	input  wire          cp_rot,       // pulse: the ring rotates (posting F2-F7)
	input  wire          cp_shin,      // pulse: stb_q shifts into the ring
	input  wire          cp_cmp,       // pulse: take[] compares a return with its seed
	input  wire          cp_apply,     // pulse: the merge at M_fe
	input  wire          mwin,         // level: tick adds deferred
	// hook (bench only; tied 0 in synthesis)
	input  wire          hk_en,
	input  wire          hk_stb,
	input  wire  [191:0] hk_ret,       // {f2, f1, f0, c2, c1, c0}
	// R
	output logic         aud_issue,    // comb
	output logic  [14:0] aud_addr,     // comb: byte address (u_arb uses [14:2])
	input  wire          aud_take,     // comb, from u_arb
	input  wire   [31:0] crb_q,
	// S
	input  wire   [31:0] stb_q,        // the return words F8-FD
	// A
	output logic         aud_a_req,
	output logic  [12:0] aud_a_a,
	input  wire          aud_a_gnt,
	input  wire   [31:0] fea_q,
	// sample port
	output logic         smp_req,      // reg: request toggle
	output logic  [18:0] smp_addr,     // reg
	input  wire          smp_ack,      // answer toggle (two clk_sys flops inside)
	input  wire    [7:0] smp_data,
	// out
	output logic   [7:0] amp_nx,       // comb: the value amplitude holds after this edge
	output logic  [31:0] ring0         // ring[0], to u_call
);
	localparam logic [23:0] TICK_TH   = daria_fe_pkg::TICK_TH;
	localparam logic [23:0] TICK_WRAP = daria_fe_pkg::TICK_WRAP;
	localparam logic [23:0] TICK_STEP = daria_fe_pkg::TICK_STEP;
	localparam int S_IDLE   = daria_fe_pkg::AS_IDLE;
	localparam int S_NISS   = daria_fe_pkg::AS_NISS;
	localparam int S_NCAP   = daria_fe_pkg::AS_NCAP;
	localparam int S_PISS   = daria_fe_pkg::AS_PISS;
	localparam int S_PCAP   = daria_fe_pkg::AS_PCAP;
	localparam int S_SZISS  = daria_fe_pkg::AS_SZISS;
	localparam int S_SZCAP  = daria_fe_pkg::AS_SZCAP;
	localparam int S_SMISS  = daria_fe_pkg::AS_SMISS;
	localparam int S_SMCAP  = daria_fe_pkg::AS_SMCAP;
	localparam int S_DROUTE = daria_fe_pkg::AS_DROUTE;
	localparam int S_RISS   = daria_fe_pkg::AS_RISS;
	localparam int S_RWAIT  = daria_fe_pkg::AS_RWAIT;
	localparam logic [4:0] WSH0 = 5'd27;           // waveform_shift's reset and refresh value

	// ---- registers (design 5.3; the bench taps of 1.7 keep these names) ----------
	// Power-up values equal the reset values (docs/DEVELOPING.md, "Power-up
	// values"). The 1.7 taps that fe_deposit_audio writes carry
	// public_flat_rw (a comment to synthesis).
	/* verilator lint_off PROCASSINIT */
	logic [23:0] accum      /* verilator public_flat_rw */ = 24'd0;
	logic [31:0] counter [0:2] /* verilator public_flat_rw */ = '{32'd0, 32'd0, 32'd0};
	logic [31:0] freq [0:2] /* verilator public_flat_rw */ = '{32'd0, 32'd0, 32'd0};
	logic [31:0] rc [0:2]   /* verilator public_flat_rw */ = '{32'd0, 32'd0, 32'd0};
	logic [31:0] ring [0:5] /* verilator public_flat_rw */ = '{32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0};
	logic  [2:0] take       /* verilator public_flat_rw */ = 3'd0;
	logic        tdef       /* verilator public_flat_rw */ = 1'b0;
	logic [11:0] st         /* verilator public_flat_rw */ = 12'd1;     // one-hot, AS_IDLE
	logic  [1:0] voice      /* verilator public_flat_rw */ = 2'd0;
	logic  [7:0] ssum       /* verilator public_flat_rw */ = 8'h00;
	logic  [4:0] wsh        /* verilator public_flat_rw */ = WSH0;
	logic [14:0] woff       /* verilator public_flat_rw */ = 15'd0;
	logic [31:0] dig_addr   /* verilator public_flat_rw */ = 32'd0;
	logic        dig_low    /* verilator public_flat_rw */ = 1'b0;
	logic [14:0] dig_ram    /* verilator public_flat_rw */ = 15'd0;
	logic        dig_smp    /* verilator public_flat_rw */ = 1'b0;
	logic        rp         /* verilator public_flat_rw */ = 1'b0;     // refresh pending
	logic        np         /* verilator public_flat_rw */ = 1'b0;     // note pending
	logic  [1:0] nv         /* verilator public_flat_rw */ = 2'd0;     // note voice
	logic  [7:0] nval       /* verilator public_flat_rw */ = 8'h00;    // note value
	logic  [7:0] amplitude  /* verilator public_flat_rw */ = 8'h00;
	logic  [1:0] al         /* verilator public_flat_rw */ = 2'd0;     // byte lane of the last grant
	// sample client (5.7): not reset by cart_reset
	logic        busy_l     /* verilator public_flat_rw */ = 1'b0;     // local request in flight
	logic        busy_r     /* verilator public_flat_rw */ = 1'b0;     // remote request in flight
	logic  [3:0] lcnt       = 4'd0;                // one-hot (R, R+1) .. (R+3, R+4)
	logic        a_done     = 1'b0;                // the local A read was granted
	logic        a_q        = 1'b0;                // fea_q holds the local word in this clock
	logic  [7:0] rdat       = 8'h00;               // the sample byte
	logic        req_q      = 1'b0;                // smp_req
	logic [18:0] saddr_q    = 19'd0;               // smp_addr
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	logic        ack_s1     = 1'b0;
	logic        ack_s2     = 1'b0;
	logic        rdone_q    = 1'b0;                // the remote byte is in rdat
	/* verilator lint_on PROCASSINIT */

	// ---- bench taps that are not registers (1.7) --------------------------------
	logic        tick;
	logic        dispatch;
	/* verilator lint_off UNUSEDSIGNAL */          // read by the bench only
	logic        ev_size_hi;                       // event: a SIZE read above 32 KB (size_over32k)
	logic        a_tdef2;                          // assertion: a second tick while one is deferred
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- live decodes (5.2, 5.3) ------------------------------------------------
	wire        f_dpc    = fam == 2'd1;            // upstream family == 1
	wire        f_cdf    = fam == 2'd3;            // upstream family == 3
	wire        f_mrg    = fam[1];                 // upstream family >= 2 (seeds, merge)
	wire        jplus_s  = f_cdf & (rev == 2'd3);  // AUD:111
	wire        rev3     = rev == 2'd3;            // AUD:281: the CDFJ+ pointer window
	wire        digital  = f_cdf & cdf_dig;        // AUD:107-108 without BUS
	wire        rom_ready = !(busy_l | busy_r);
	wire        rom_done;

	assign tick     = accum >= TICK_TH;
	assign dispatch = st[S_IDLE] & !(np & f_dpc) & rp;
	wire   v_inc    = st[S_SMCAP] & !dig_smp & (voice != 2'd2);
	wire   v_end    = st[S_SMCAP] & (dig_smp | (voice == 2'd2));
	wire   pc_wave  = st[S_PCAP] & !digital;       // a waveform pointer captured
	wire   pc_dig   = st[S_PCAP] & digital;        // a digital pointer captured
	wire   sz_zero  = asz == 16'd0;

	// ---- the byte and word the captures read (5.2) -------------------------------
	logic [7:0] lane_b;
	always_comb begin
		lane_b = ({8{al == 2'd0}} & crb_q[7:0])   | ({8{al == 2'd1}} & crb_q[15:8])
		       | ({8{al == 2'd2}} & crb_q[23:16]) | ({8{al == 2'd3}} & crb_q[31:24]);
	end
	wire  [7:0] byte_d = pause ? 8'hFF : lane_b;   // top.sv:936: bytes only are masked

	// ---- the digital route (AUD:335-347) -------------------------------------------
	// in_ram: dig_addr in [$4000_0000, $4000_0000 + ram_size), as AUD:338-340.
	wire        rom_lt  = dig_addr < rom_size;
	wire        in_ram  = (dig_addr[31:15] == 17'h0_8000) & (ram32 | (dig_addr[14:13] == 2'd0));
	wire        dr_rom  = st[S_DROUTE] & rom_lt;
	wire        dr_ram  = st[S_DROUTE] & !rom_lt & in_ram;
	wire        dr_none = st[S_DROUTE] & !rom_lt & !in_ram;

	// ---- the ticks around the merge (5.6) -----------------------------------------
	wire        late     = tdef & !mwin;
	wire        tick_eff = (tick & !mwin) | late;
	wire        own_apply = cp_apply & f_mrg;
	wire        hk_apply  = hk_en & hk_stb & f_mrg;
	assign      a_tdef2   = tick & tdef;

	// ---- accum ------------------------------------------------------------------
	always_ff @(posedge clk_sys) begin
		if (cart_reset) accum <= 24'd0;
		else            accum <= accum + (tick ? TICK_WRAP : TICK_STEP);
	end

	// ---- counters and frequencies ---------------------------------------------------
	wire  [1:0] nv_eff = (nv == 2'd3) ? 2'd2 : nv;    // AUD:249-253: default writes frequency2
	genvar v;
	generate for (v = 0; v < 3; v = v + 1) begin : g_voice
		localparam int VI = v;
		wire [31:0] hk_c = hk_ret[32*v +: 32];
		wire [31:0] hk_f = hk_ret[96 + 32*v +: 32];
		wire        hk_take  = hk_apply & (hk_c != ring[v]);
		wire        take_eff = (own_apply & take[v]) | hk_take;
		// one adder: A is the merged word or the counter, B the tick's step
		wire [31:0] c_a = ({32{take_eff & hk_apply}}  & hk_c)
		                | ({32{take_eff & !hk_apply}} & ring[v])
		                | ({32{!take_eff}}            & counter[v]);
		wire [31:0] c_b = {32{tick_eff & !take_eff}} & freq[v];
		always_ff @(posedge clk_sys) begin
			if (cart_reset)                 counter[v] <= 32'd0;
			else if (tick_eff | take_eff)   counter[v] <= c_a + c_b;
		end
		// NOTE's load wins over a merge on the same edge (AUD:213-252 order)
		wire        ncap = st[S_NCAP] & (nv_eff == VI[1:0]);
		wire [31:0] f_d  = ({32{ncap}}                          & crb_q)
		                 | ({32{!ncap & hk_apply}}              & hk_f)
		                 | ({32{!ncap & !hk_apply}}             & ring[3+v]);
		always_ff @(posedge clk_sys) begin
			if (cart_reset)                          freq[v] <= 32'd0;
			else if (ncap | own_apply | hk_apply)    freq[v] <= f_d;
		end
		// the refresh's snapshot (AUD:231-233)
		always_ff @(posedge clk_sys) begin
			if (cart_reset)    rc[v] <= 32'd0;
			else if (dispatch) rc[v] <= counter[v];
		end
	end endgenerate

	// ---- the ring (5.6): capture at L, rotate while posting, shift the returns in -------
	wire ring_en = cp_cap | cp_rot | cp_shin;
	wire [31:0] capv [0:4];                            // the payload: counters 0-2, frequencies 0-1
	assign capv[0] = counter[0];
	assign capv[1] = counter[1];
	assign capv[2] = counter[2];
	assign capv[3] = freq[0];
	assign capv[4] = freq[1];
	generate for (v = 0; v < 5; v = v + 1) begin : g_ring
		always_ff @(posedge clk_sys) begin
			if (cart_reset)   ring[v] <= 32'd0;
			else if (ring_en) ring[v] <= cp_cap ? capv[v] : ring[v + 1];
		end
	end endgenerate
	always_ff @(posedge clk_sys) begin
		if (cart_reset)   ring[5] <= 32'd0;
		else if (ring_en) ring[5] <= ({32{cp_cap}}                     & freq[2])
		                           | ({32{!cp_cap & cp_rot}}           & ring[0])
		                           | ({32{!cp_cap & !cp_rot}}          & stb_q);
	end
	assign ring0 = ring[0];
	always_ff @(posedge clk_sys) begin
		if (cart_reset)             take <= 3'd0;
		else if (cp_shin & cp_cmp)  take <= {stb_q != ring[0], take[2:1]};
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)                  tdef <= 1'b0;
		else if ((tick & mwin) | late)   tdef <= tick & mwin;
	end

	// ---- refresh and NOTE pending (AUD:191-205, 229, 254-255) ---------------------------
	always_ff @(posedge clk_sys) begin
		if (cart_reset)             rp <= 1'b0;
		else if (tick | dispatch)   rp <= dispatch ? tick : (fam != 2'd0);
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)                   np <= 1'b0;
		else if (note_stb | st[S_NCAP])   np <= note_stb;
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)    begin nv <= 2'd0; nval <= 8'h00; end
		else if (note_stb) begin nv <= note_v; nval <= note_val; end
	end

	// ---- the replica's state (5.4), one bit per state ---------------------------------
	logic [11:0] st_n;
	always_comb begin
		st_n = 12'd0;
		st_n[S_IDLE]   = (st[S_IDLE] & !(np & f_dpc) & !rp) | st[S_NCAP] | v_end | dr_none
		               | (st[S_RWAIT] & rom_done);
		st_n[S_NISS]   = (st[S_IDLE] & np & f_dpc) | (st[S_NISS] & !aud_take);
		st_n[S_NCAP]   = st[S_NISS] & aud_take;
		st_n[S_PISS]   = ((dispatch | v_inc) & !f_dpc) | (st[S_PISS] & !aud_take);
		st_n[S_PCAP]   = st[S_PISS] & aud_take;
		st_n[S_SZISS]  = (pc_wave & !sz_zero) | (st[S_SZISS] & !aud_take);
		st_n[S_SZCAP]  = st[S_SZISS] & aud_take;
		st_n[S_SMISS]  = ((dispatch | v_inc) & f_dpc) | (pc_wave & sz_zero) | st[S_SZCAP]
		               | dr_ram | (st[S_SMISS] & !aud_take);
		st_n[S_SMCAP]  = st[S_SMISS] & aud_take;
		st_n[S_DROUTE] = pc_dig;
		st_n[S_RISS]   = dr_rom | (st[S_RISS] & !rom_ready);
		st_n[S_RWAIT]  = (st[S_RISS] & rom_ready) | (st[S_RWAIT] & !rom_done);
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset) st <= 12'd1 << S_IDLE;
		else            st <= st_n;
	end

	// ---- the refresh's working registers (5.3) ------------------------------------------
	always_ff @(posedge clk_sys) begin
		if (cart_reset)             voice <= 2'd0;
		else if (dispatch | v_inc)  voice <= dispatch ? 2'd0 : voice + 2'd1;
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)             ssum <= 8'h00;
		else if (dispatch | v_inc)  ssum <= dispatch ? 8'h00 : ssum + byte_d;
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)                        dig_smp <= 1'b0;
		else if (dispatch | dr_ram)            dig_smp <= !dispatch;
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)                                            wsh <= WSH0;
		else if (dispatch | v_inc | (pc_wave & sz_zero) | st[S_SZCAP])
			wsh <= st[S_SZCAP] ? crb_q[11:7] : WSH0;
	end
	// woff (AUD:274-292 without BUS): the CDFJ+ window is [$4000_0800, $4000_0000 + ram_size)
	wire        w_win = (crb_q[31:15] == 17'h0_8000) & (crb_q[14:11] != 4'd0)
	                  & (ram32 | (crb_q[14:13] == 2'd0));
	wire [14:0] w_off = crb_q[14:0] - 15'h0800;    // its low 12 bits are word[11:0] - $800
	always_ff @(posedge clk_sys) begin
		if (cart_reset)   woff <= 15'd0;
		else if (pc_wave) woff <= ({15{rev3 & w_win}} & w_off) | ({15{!rev3}} & {3'b0, w_off[11:0]});
	end
	// the digital pointer (AUD:266-271)
	wire [31:0] rc0_sh = jplus_s ? {13'd0, rc[0][31:13]} : {21'd0, rc[0][31:21]};
	always_ff @(posedge clk_sys) begin
		if (cart_reset)  begin dig_addr <= 32'd0; dig_low <= 1'b0; end
		else if (pc_dig) begin
			dig_addr <= crb_q + rc0_sh;
			dig_low  <= jplus_s ? rc[0][12] : rc[0][20];
		end
	end
	always_ff @(posedge clk_sys) begin
		if (cart_reset)  dig_ram <= 15'd0;
		else if (dr_ram) dig_ram <= dig_addr[14:0];
	end

	// ---- AMPLITUDE (AUD:317-361) ------------------------------------------------
	wire       am_dig = st[S_SMCAP] & dig_smp;                 // a RAM-window sample
	wire       am_sum = st[S_SMCAP] & !dig_smp & (voice == 2'd2);
	wire       am_rom = st[S_RWAIT] & rom_done;
	wire       amp_we = am_dig | am_sum | dr_none | am_rom;
	wire [7:0] dig_b  = am_rom ? rdat : byte_d;
	wire [7:0] amp_d  = ({8{am_dig | am_rom}} & {4'h0, dig_low ? dig_b[3:0] : dig_b[7:4]})
	                  | ({8{am_sum}}          & (ssum + byte_d));   // dr_none: 0
	always_ff @(posedge clk_sys) begin
		if (cart_reset)  amplitude <= 8'h00;
		else if (amp_we) amplitude <= amp_d;
	end
	assign amp_nx = cart_reset ? 8'h00 : (amp_we ? amp_d : amplitude);

	// ---- the address and request (5.5) ------------------------------------------------
	logic [31:0] rc_sel;
	logic  [6:0] wsel;
	always_comb begin
		rc_sel = ({32{voice == 2'd0}} & rc[0]) | ({32{voice == 2'd1}} & rc[1])
		       | ({32{voice[1]}}      & rc[2]);
		wsel   = ({7{voice == 2'd0}} & wave0) | ({7{voice == 2'd1}} & wave1)
		       | ({7{voice[1]}}      & wave2);
	end
	/* verilator lint_off UNUSEDSIGNAL */          // [31:15]: upstream keeps [14:0] (AUD:128, 148)
	wire [31:0] idx  = rc_sel >> wsh;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [14:0] sos  = woff + idx[14:0];
	wire [14:0] pbase = f_cdf ? ((rev == 2'd0) ? 15'h07F0 : 15'h01B0) : 15'h07F4;
	wire [14:0] rmask = ram32 ? 15'h7FFF : 15'h1FFF;            // ram_size - 1
	wire [14:0] sm_wave = ({15{f_dpc}}            & (15'h0C00 + {3'b0, wsel, 5'b0} + {10'd0, idx[4:0]}))
	                    | ({15{!f_dpc & jplus_s}}  & ((15'h0800 + sos) & rmask))
	                    | ({15{!f_dpc & !jplus_s}} & (15'h0800 + {3'b0, sos[11:0]}));
	wire [16:0] sz_a  = {1'b0, asz} + {13'd0, voice, 2'b00};
	logic [14:0] a_d;
	always_comb begin
		a_d = ({15{st[S_NISS]}}             & (15'h1C00 + {5'd0, nval, 2'b00}))
		    | ({15{st[S_PISS]}}             & (pbase + {11'd0, voice, 2'b00}))
		    | ({15{st[S_SZISS]}}            & sz_a[14:0])
		    | ({15{st[S_SMISS] & dig_smp}}  & dig_ram)
		    | ({15{st[S_SMISS] & !dig_smp}} & sm_wave);
	end
	assign aud_issue  = st[S_NISS] | st[S_PISS] | st[S_SZISS] | st[S_SMISS];
	assign aud_addr   = a_d;
	assign ev_size_hi = st[S_SZISS] & (sz_a[16:15] != 2'd0);

	// The byte lane of the word a grant reads. Upstream's lane register
	// (cart_ram_tdp.sv mapper_read_lane) loads the port's address at every edge
	// with pause_core low, and the port's address is the engine's whenever the
	// select is low; a grant needs the select low, and a paused (frozen) cycle's
	// select is what it was at the last unpaused edge (AUD 12.5). So al loads
	// a_d[1:0] at every unpaused edge, not only on aud_take as design 5.3 has
	// it, and a capture after a grant in a pause reads upstream's lane
	// (docs/daria_fe/lanes/B_audio.md, "Deviations": pause_lane).
	always_ff @(posedge clk_sys) begin
		if (cart_reset)  al <= 2'd0;
		else if (!pause) al <= a_d[1:0];
	end

	// ---- the sample client (5.7) -------------------------------------------------------
	wire r_go  = st[S_RISS] & rom_ready;              // the edge R
	wire r_loc = dig_addr[31:15] == 17'd0;            // below 32 KB: the front-end ROM
	wire ack_hit = busy_r & (ack_s2 == req_q);
	always_ff @(posedge clk_sys) begin
		lcnt    <= {lcnt[2:0], r_go & r_loc};
		a_q     <= aud_a_gnt;
		ack_s1  <= smp_ack;
		ack_s2  <= ack_s1;
		rdone_q <= ack_hit;
		if (r_go & r_loc)       busy_l <= 1'b1;
		else if (lcnt[3])       busy_l <= 1'b0;
		if (r_go & r_loc)       a_done <= 1'b0;
		else if (aud_a_gnt)     a_done <= 1'b1;
		if (a_q | ack_hit)      rdat <= ({8{a_q & (dig_addr[1:0] == 2'd0)}} & fea_q[7:0])
		                              | ({8{a_q & (dig_addr[1:0] == 2'd1)}} & fea_q[15:8])
		                              | ({8{a_q & (dig_addr[1:0] == 2'd2)}} & fea_q[23:16])
		                              | ({8{a_q & (dig_addr[1:0] == 2'd3)}} & fea_q[31:24])
		                              | ({8{!a_q}}                          & smp_data);
		if (r_go & !r_loc)      busy_r <= 1'b1;
		else if (ack_hit)       busy_r <= 1'b0;
		if (r_go & !r_loc) begin
			req_q   <= ~req_q;
			saddr_q <= dig_addr[18:0];
		end
	end
	assign rom_done  = (lcnt[3] & busy_l) | rdone_q;
	assign aud_a_req = (lcnt[0] | lcnt[1]) & !a_done;
	assign aud_a_a   = dig_addr[14:2];
	assign smp_req   = req_q;
	assign smp_addr  = saddr_q;
endmodule

`default_nettype wire
