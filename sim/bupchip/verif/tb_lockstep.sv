//------------------------------------------------------------------------------
// Retire-level lockstep: the reference BupChip (ref_system.svh: arm_host and
// bupchip_subsystem with the real peripheral and asset path) against a core
// under test on its own memories. README.md defines the DUT's interface.
//
// The DUT is lockstep_dut_ref (a second arm7tdmi_core on a zero-wait bus,
// presented through the retire port) by default, or lockstep_dut_bup (the
// new core) when built with -DDUT_BUP.
//
// Peripheral reads are replayed: every read the reference makes of
// 0xE0009000-0xE00090FF is queued with its value, and the DUT's reads are
// answered from that queue in order (the DUT waits while it is empty). Both
// cores therefore see the same IDENT, command and FIFO-status values and run
// the same instruction stream, whatever their timing.
//
// The DUT's retire port is applied to a shadow register file, which starts
// at zero like the reference's; nothing is masked. Compared, in program
// order: every retire (PC, encoding, r0-r14, NZCV), every RAM store (word
// address, byte lanes, data), every peripheral write, and the address of
// every peripheral read. Either side may run ahead; heads are compared as
// they become available.
//
//   +maxret=N       stop after N compared retires (default 1,000,000)
//   +maxcyc=N       stop after N reference clocks (default: no limit)
//   +maxfail=N      stop after N mismatches (default 5)
//   +stall=N        fail if nothing is compared for N reference clocks
//                   (default 2,000,000)
//   +inject_mmio=N  flip bit 0 of the Nth replayed peripheral read (1-based),
//                   to show that a divergence is caught, with any DUT
//   +inject=N       the same for the DUT's Nth data load (lockstep_dut_ref)
//   +gap=P +seed=S  lockstep_dut_ref: idle clocks on the retire port, P%
//   +abort_ok=1     a reference data abort ends the run instead of failing
//                   it, provided the DUT halts too and everything before
//                   matched (random-content ARSC blocks)
//   and the plusargs of ref_system.svh (+rom, +romhex, +lat, +cmds, +song).
//
// A write to the FAULT register (0xE000901C) by the reference ends the run
// once the DUT has caught up: the firmware's fault path, or the end marker
// of the ISA tests and the mixer harness. The last line is LOCKSTEP PASS or
// LOCKSTEP FAIL.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_lockstep;
	`include "ref_system.svh"

	// ---- DUT ----------------------------------------------------------------
	logic        dut_rst = 1;
	logic        rt_start, rt_valid, rt_e_we, rt_w_we;
	logic [31:0] rt_pc, rt_insn, rt_e_data, rt_w_data;
	logic  [3:0] rt_nzcv, rt_e_idx, rt_w_idx;
	logic        st_valid, pw_valid, pr_valid, pr_wait, halted;
	logic [31:0] st_addr, st_data, pw_data, halt_pc;
	logic  [3:0] st_strb;
	logic  [7:0] pw_addr, pr_addr;
	logic        pr_avail = 0;
	logic [31:0] pr_data = 0;

`ifdef DUT_BUP
	lockstep_dut_bup dut (
`else
	lockstep_dut_ref dut (
`endif
		.clk(clk_arm), .rst(dut_rst),
		.rt_start, .rt_valid, .rt_pc, .rt_insn, .rt_nzcv,
		.rt_e_we, .rt_e_idx, .rt_e_data, .rt_w_we, .rt_w_idx, .rt_w_data,
		.st_valid, .st_addr, .st_strb, .st_data,
		.pw_valid, .pw_addr, .pw_data,
		.pr_valid, .pr_addr, .pr_wait, .pr_avail, .pr_data,
		.halted, .halt_pc);

	// ---- scoreboard -----------------------------------------------------------
	typedef struct { logic [31:0] pc, insn; logic [31:0] r [15]; logic [3:0] f; } rec_t;
	typedef struct { logic [31:0] a, d; logic [3:0] s; } st_t;
	typedef struct { logic [7:0] a; logic [31:0] d; } io_t;

	rec_t   refq [$], dutq [$];
	st_t    rstq [$], dstq [$];
	io_t    rpwq [$], dpwq [$], mmq [$];
	logic [31:0] shadow [15];
	rec_t   pend_rec;
	logic   in_flight = 0, pend = 0, halt_seen = 0;
	longint fails = 0, ncmp = 0, nst = 0, npw = 0, npr = 0, rret = 0, dret = 0;
	longint dcyc = 0, dwait = 0, ref_fault_ret = -1, ref_abort_ret = -1, progress_cyc = 0;
	logic   abort_ok = 0;
	longint inject_mmio = -1;
	int     maxfail = 5;

	function automatic logic [31:0] lanes(input logic [3:0] s);
		return {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
	endfunction

	function automatic void fail(input string msg);
		fails++;
		if (fails <= maxfail) $display("MISMATCH %s", msg);
	endfunction

	function automatic void compare_rec(input rec_t x, input rec_t y);
		string why;
		ncmp++;
		why = "";
		if (x.pc !== y.pc || x.insn !== y.insn)
			why = $sformatf(" pc/insn DUT %08x %08x", y.pc, y.insn);
		for (int k = 0; k < 15; k++)
			if (x.r[k] !== y.r[k]) why = {why, $sformatf(" r%0d DUT %08x ref %08x", k, y.r[k], x.r[k])};
		if (x.f !== y.f) why = {why, $sformatf(" NZCV DUT %1x ref %1x", y.f, x.f)};
		if (why != "")
			fail($sformatf("retire #%0d, reference pc %08x insn %08x:%s", ncmp, x.pc, x.insn, why));
		progress_cyc = ref_cyc;
	endfunction

	always @(posedge clk_arm) begin
		// Reference: retires, stores, peripheral writes and reads (to replay).
		if (ref_running) begin
			if (ref_dacc && mem_abort) begin
				if (!abort_ok) fail($sformatf("reference data abort at %08x (CoreTone never aborts)", mem_addr));
				else if (ref_abort_ret < 0) begin
					ref_abort_ret = rret;
					$display("reference data abort at %08x after %0d retires", mem_addr, rret);
				end
			end
			else if (ref_dacc && mem_write) begin
				if (ref_mmio) rpwq.push_back('{mem_addr[7:0], mem_wdata});
				else rstq.push_back('{mem_addr & ~32'h3, mem_wdata & lanes(mem_wstrb), mem_wstrb});
				if (ref_fault && ref_fault_ret < 0) ref_fault_ret = rret;
			end else if (ref_dacc && ref_mmio)
				mmq.push_back('{mem_addr[7:0], mem_rdata});
			if (retire) begin
				rec_t x;
				x.pc = ref_rpc;
				x.insn = ref_rins;
				for (int k = 0; k < 15; k++) x.r[k] = ref_reg(k);
				x.f = ref_nzcv;
				refq.push_back(x);
				rret++;
				if (ref_rexc) fail($sformatf("reference took an exception at %08x", ref_rpc));
			end
		end

		// DUT: bus streams, replay, and the retire port applied to the shadow.
		if (!dut_rst) begin
			dcyc++;
			if (pr_wait) dwait++;
			if (st_valid) dstq.push_back('{st_addr & ~32'h3, st_data & lanes(st_strb), st_strb});
			if (pw_valid) dpwq.push_back('{pw_addr, pw_data});
			if (pr_valid) begin
				if (mmq.size() == 0) fail($sformatf("DUT read peripheral %02x with no replay entry", pr_addr));
				else begin
					if (mmq[0].a !== pr_addr)
						fail($sformatf("peripheral read #%0d: DUT %02x, reference %02x", npr + 1, pr_addr, mmq[0].a));
					void'(mmq.pop_front());
					npr++;
				end
			end
			// 1. W writes belong to instructions older than any start this clock.
			if (rt_w_we) begin
				if (rt_w_idx == 4'd15) fail("retire port: W write to r15");
				else shadow[rt_w_idx] = rt_w_data;
			end
			// 2. A start completes the previous instruction's record.
			if (rt_start) begin
				if (in_flight) fail($sformatf("retire port: start at DUT clock %0d before the previous retire", dcyc));
				if (pend) begin
					rec_t y;
					y = pend_rec;
					for (int k = 0; k < 15; k++) y.r[k] = shadow[k];
					dutq.push_back(y);
					pend = 0;
				end
				in_flight = 1;
			end
			// 3. E writes belong to the instruction in flight.
			if (rt_e_we) begin
				if (!in_flight) fail($sformatf("retire port: E write at DUT clock %0d outside an instruction", dcyc));
				if (rt_e_idx == 4'd15) fail("retire port: E write to r15");
				else shadow[rt_e_idx] = rt_e_data;
			end
			// 4. The retire: its record waits for the next start (load data).
			if (rt_valid) begin
				if (!in_flight) fail($sformatf("retire port: retire at DUT clock %0d without a start", dcyc));
				pend_rec.pc = rt_pc;
				pend_rec.insn = rt_insn;
				pend_rec.f = rt_nzcv;
				pend = 1;
				in_flight = 0;
				dret++;
			end
			if (halted && !halt_seen) begin
				halt_seen = 1;
				if (abort_ok) $display("DUT halted (%08x) after %0d retires", halt_pc, dret);
				else fail($sformatf("DUT halted (%08x) after %0d retires", halt_pc, dret));
			end
		end

		while (refq.size() != 0 && dutq.size() != 0) compare_rec(refq.pop_front(), dutq.pop_front());
		while (rstq.size() != 0 && dstq.size() != 0) begin
			st_t e, g;
			e = rstq.pop_front();
			g = dstq.pop_front();
			nst++;
			if (e.a !== g.a || e.s !== g.s || e.d !== g.d) fail($sformatf("RAM store #%0d: DUT %08x/%1x=%08x, reference %08x/%1x=%08x",
				nst, g.a, g.s, g.d, e.a, e.s, e.d));
		end
		while (rpwq.size() != 0 && dpwq.size() != 0) begin
			io_t e, g;
			e = rpwq.pop_front();
			g = dpwq.pop_front();
			npw++;
			if (e.a !== g.a || e.d !== g.d) fail($sformatf("peripheral write #%0d: DUT %02x=%08x, reference %02x=%08x",
				npw, g.a, g.d, e.a, e.d));
		end

		// The replay head, for the DUT's next clock.
		pr_avail <= mmq.size() != 0;
		pr_data  <= mmq.size() == 0 ? 32'b0 : mmq[0].d ^ {31'b0, npr + 1 == inject_mmio};
	end

	initial begin
		longint maxret, maxcyc, stall, stop_at;
		string  why;
		if (!$value$plusargs("maxret=%d", maxret)) maxret = 1000000;
		if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = -1;
		void'($value$plusargs("abort_ok=%d", abort_ok));
		if (!$value$plusargs("stall=%d", stall)) stall = 2000000;
		void'($value$plusargs("maxfail=%d", maxfail));
		void'($value$plusargs("inject_mmio=%d", inject_mmio));
		for (int k = 0; k < 15; k++) shadow[k] = 32'b0;
`ifdef DUT_BUP
		$display("lockstep: reference against lockstep_dut_bup (the new core)");
`else
		$display("lockstep: reference against lockstep_dut_ref (a second arm7tdmi_core, zero-wait bus)");
`endif
		ref_boot();
		dut_rst = 0;
		why = "";
		stop_at = -1;
		while (why == "") begin
			@(posedge clk_arm);
			if (ncmp >= maxret) why = "instruction limit";
			else if (maxcyc >= 0 && ref_cyc >= maxcyc) why = "clock limit";
			else if (ref_abort_ret >= 0 && ncmp >= ref_abort_ret && halt_seen) why = "reference abort, DUT halted";
			else if (fails >= maxfail) why = "too many mismatches";
			else if (ref_cyc - progress_cyc > stall) begin
				why = "no progress";
				fail($sformatf("nothing compared for %0d clocks: DUT at %0d retires, reference at %0d",
					stall, dret, rret));
			end else if (ref_fault_ret >= 0 && ncmp > ref_fault_ret) begin
				// Let the DUT's own FAULT write arrive before stopping.
				if (stop_at < 0) stop_at = ref_cyc + 256;
				else if (ref_cyc >= stop_at) why = "FAULT write";
			end
		end
		if (abort_ok && halt_seen && ref_abort_ret < 0) fail("DUT halted, but the reference did not abort");
		if (why == "FAULT write" && rpwq.size() != 0)
			fail($sformatf("DUT is missing %0d peripheral write(s), the first %02x=%08x",
				rpwq.size(), rpwq[0].a, rpwq[0].d));
		$display("stop: %s", why);
		$display("compared: %0d retires, %0d RAM stores, %0d peripheral writes; %0d peripheral reads replayed",
			ncmp, nst, npw, npr);
		$display("reference: %0d retired in %0d clocks (%.2f per instruction)",
			rret, ref_cyc, ref_cyc * 1.0 / (rret > 0 ? rret : 1));
		$display("DUT: %0d retired in %0d clocks, %0d of them waiting for a replayed read (%.2f per instruction without those)",
			dret, dcyc, dwait, (dcyc - dwait) * 1.0 / (dret > 0 ? dret : 1));
		if (ref_fault_ret >= 0) $display("reference wrote FAULT = %02x", bup.fault_code);
		$display("mismatches: %0d", fails);
		$display("%s", fails == 0 ? "LOCKSTEP PASS" : "LOCKSTEP FAIL");
		$finish;
	end
endmodule
