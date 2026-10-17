//------------------------------------------------------------------------------
// DARIA front end: the shared types and constants (docs/daria_fe/design.md
// 1.3; the interfaces as frozen at step 0 are docs/daria_fe/interfaces.md).
//
// dec_t is the decode of one 6507 cycle (daria_fe_dec), latched as the op
// (daria_fe_core, 2.2). opc_t is its one-hot op class: the DPC+ classes are
// the first twelve fields, the CDF classes the last six of the sixteen bits,
// and NONE is all zero.
//
// The step-0 additions below the TICK constants fix encodings that the bench
// taps (design 1.7, fe_taps.svh) read: the one-hot state bit of the audio and
// call FSMs, the F6 phase, the core's pending at-commit kind and the port
// owners in daria_fe_arb. They are part of the frozen interface.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

package daria_fe_pkg;
	// One-hot op class (NONE = all zero). The DPC+ classes are 0..11, the CDF classes 12..17.
	typedef struct packed {
		logic rom;   // read, not substituted (both schemes)
		logic rrnd;  // DPC+ fn 0, ix != 5 (random, 0s)
		logic amp;   // DPC+ fn 0 ix 5; CDF amplitude fetch
		logic rdat;  // DPC+ fn 1..3 (DATA, DATAW, FRACDATA)
		logic rflg;  // DPC+ fn 4
		logic dfld;  // DPC+ write g in {0,1,2,3,4,5,8} (field bytes)
		logic dpw;   // DPC+ write g in {7,10} (PUSH, WRITE)
		logic dpar;  // DPC+ $1059
		logic dcf;   // DPC+ $105A
		logic dmisc; // DPC+ g6 ix {0,5,6,7}, g9 (FASTFETCH, WAVEFORM, RRESET/RWRITE, NOTE)
		logic cfet;  // CDF fetch substitution, not amplitude, not jump
		logic cjmp;  // CDF jump substitution
		logic cdsw;  // CDF $1FF0 write
		logic cdsp;  // CDF $1FF1 write
		logic cmode; // CDF $1FF2 write
		logic ccall; // CDF $1FF3 write
	} opc_t;
	typedef struct packed {
		opc_t       c;
		logic       hot;     // hotspot attribute (read or write, not substituted)
		logic [2:0] ix;      // DPC+ register index
		logic [2:0] fn;      // DPC+ read function
		logic [3:0] g;       // DPC+ write group ((a - $028) >> 3)
		logic [5:0] idx;     // CDF table index (fetch: normalised operand; jump: stream)
		logic       arms;    // CDF arming byte ($A9, or $A2/$A0 on CDFJ+ with ldx/ldy)
		logic       b4c;     // romb == $4C
		logic       jok;     // jump lookahead (formed in k[1] by fe_core, 2.2)
		logic       romb0;   // romb[0] (CDFJ jump stream select)
		logic       a9;      // romb == $A9 (DPC+ arming)
	} dec_t;               // 16 + 22 = 38 bits (design 1.3 says 16 + 26 = 42; interfaces.md S0-3)
	localparam logic [23:0] TICK_TH   = 24'd14_298_182;   // CLK_RATE - AUDIO_RATE
	localparam logic [23:0] TICK_WRAP = 24'h25_D3BA;      // AUDIO_RATE - CLK_RATE mod 2^24
	localparam logic [23:0] TICK_STEP = 24'd20_000;

	// ---- step 0: frozen encodings (interfaces.md) --------------------------------
	// force_bs values (detect2600.sv's bss_type).
	localparam logic [5:0] SCHEME_DPCP = 6'd21;
	localparam logic [5:0] SCHEME_CDF  = 6'd23;

	// daria_fe_audio st (12, one-hot; design 5.4): the bit of each state.
	localparam int AS_IDLE   = 0;
	localparam int AS_NISS   = 1;
	localparam int AS_NCAP   = 2;
	localparam int AS_PISS   = 3;
	localparam int AS_PCAP   = 4;
	localparam int AS_SZISS  = 5;
	localparam int AS_SZCAP  = 6;
	localparam int AS_SMISS  = 7;
	localparam int AS_SMCAP  = 8;
	localparam int AS_DROUTE = 9;
	localparam int AS_RISS   = 10;
	localparam int AS_RWAIT  = 11;

	// daria_fe_call st (9, one-hot; design 6.1).
	localparam int CS_IDLE  = 0;
	localparam int CS_POST  = 1;
	localparam int CS_FLIP  = 2;
	localparam int CS_RUN   = 3;
	localparam int CS_RD    = 4;
	localparam int CS_RDW   = 5;
	localparam int CS_APPLY = 6;
	localparam int CS_HKW   = 7;
	localparam int CS_REL   = 8;

	// daria_fe_copy f6_ph (4, one-hot while f6_act; design 7.2).
	localparam int F6_CLR = 0;
	localparam int F6_P1  = 1;
	localparam int F6_P2  = 2;
	localparam int F6_END = 3;

	// daria_fe_core pend_c (design 2.4: the at-commit action not yet fired).
	localparam logic [1:0] PC_NONE = 2'd0;
	localparam logic [1:0] PC_DSW  = 2'd1;   // DSWRITE (cdsw)
	localparam logic [1:0] PC_DSP  = 2'd2;   // DSPTR (cdsp)
	localparam logic [1:0] PC_SVC  = 2'd3;   // CALLFUNCTION 1/2 service latch

	// daria_fe_arb owner taps (one-hot or zero per clock; design 3.1-3.3):
	// bit = the owner's priority.
	localparam int OR_F6   = 0;              // own_r[5:0]: F6 (cp_* while f6_act)
	localparam int OR_FIX  = 1;              //   core fixed (fix_eff)
	localparam int OR_AUD  = 2;              //   audio (aud_take)
	localparam int OR_P32  = 3;              //   core P32 read (p32_gnt)
	localparam int OR_WB   = 4;              //   core pointer write (wb_gnt)
	localparam int OR_COPY = 5;              //   copy/fill engine (cp_gnt, !f6_act)
	localparam int OS_CZ   = 0;              // own_s[2:0]: F6 clear
	localparam int OS_CORE = 1;              //   core (cs_req)
	localparam int OS_CALL = 2;              //   call port (cl_gnt)
	localparam int OA_F6   = 0;              // own_a[3:0]: F6 source (ca_req & f6_act)
	localparam int OA_LOOK = 1;              //   CDF lookahead (look_gnt)
	localparam int OA_AUD  = 2;              //   audio local sample (aud_a_gnt)
	localparam int OA_COPY = 3;              //   DPC+ copy source (ca_gnt, !f6_act)
endpackage

`default_nettype wire
