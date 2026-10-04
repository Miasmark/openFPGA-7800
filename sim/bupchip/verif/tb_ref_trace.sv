//------------------------------------------------------------------------------
// Runs a program on the reference BupChip (ref_system.svh) and reports what it
// did; optionally writes a retire trace and dumps a signature from RAM. Used
// by the ISA suite, the mixer harness and the synthetic-ARSC checks, and its
// trace feeds iss_fw_replay.py.
//
//   +maxcyc=N      stop after N clk_arm clocks (default 2,000,000)
//   +trace=FILE    one line per retired instruction:
//                    <n> <pc> <insn> [rK=v ...] [f=NZCV] [Waddr/strb=data ...]
//                    [Maddr=data ...] [ABORTaddr] [EXC]  # <clock>
//                  registers and flags are listed when they change; W is a
//                  store, M a peripheral read, both since the last retire
//   +sig=FILE      after the stop, dump +signum=N words (default 2048) from
//                  RAM 0x40000000 (the ISA tests' signature)
//   and the plusargs of ref_system.svh (+rom, +romhex, +lat, +cmds, +song).
//
// The run stops at the first write to the FAULT register (0xE000901C: the
// firmware's fault path, and the end marker of the ISA tests and the mixer
// harness), at a branch-to-self retired 8 times running, or at +maxcyc. The
// last line, "result: ...", is for scripts.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_ref_trace;
	`include "ref_system.svh"

	logic [31:0] prev [0:14];
	logic  [3:0] prev_f;
	string       pend = "";
	integer      tfd = 0;
	longint      nret = 0, fault_cyc = -1, fault_ret = -1, spin = 0;
	longint      nloads = 0, nstores = 0, npcm = 0, npcm_nz = 0, naborts = 0, nexc = 0;
	logic  [7:0] fault_val = 0;
	logic [31:0] last_pc = 32'hffffffff;

	always @(posedge clk_arm) if (ref_running) begin
		if (ref_dacc && mem_abort) begin
			naborts++;
			pend = {pend, $sformatf(" ABORT%08x", mem_addr)};
		end else if (ref_dacc) begin
			if (mem_write) begin
				nstores++;
				pend = {pend, $sformatf(" W%08x/%1x=%08x", mem_addr & ~32'h3, mem_wstrb,
					mem_wdata & {{8{mem_wstrb[3]}}, {8{mem_wstrb[2]}}, {8{mem_wstrb[1]}}, {8{mem_wstrb[0]}}})};
				if (mem_addr == 32'he0009010) begin npcm++; if (mem_wdata != 0) npcm_nz++; end
				if (ref_fault && fault_cyc < 0) begin
					fault_cyc = ref_cyc; fault_ret = nret; fault_val = mem_wdata[7:0];
				end
			end else begin
				nloads++;
				if (ref_mmio) pend = {pend, $sformatf(" M%08x=%08x", mem_addr, mem_rdata)};
			end
		end
		if (retire) begin
			string s;
			nret++;
			s = $sformatf("%0d %08x %08x", nret, ref_rpc, ref_rins);
			for (int k = 0; k < 15; k++)
				if (ref_reg(k) !== prev[k]) begin
					s = {s, $sformatf(" r%0d=%08x", k, ref_reg(k))};
					prev[k] = ref_reg(k);
				end
			if (ref_nzcv !== prev_f) begin
				s = {s, $sformatf(" f=%1x", ref_nzcv)};
				prev_f = ref_nzcv;
			end
			if (ref_rexc) begin s = {s, " EXC"}; nexc++; end
			s = {s, pend};
			pend = "";
			if (tfd != 0) $fdisplay(tfd, "%s  # %0d", s, ref_cyc);
			if (ref_rins[27:0] == 28'hafffffe && ref_rpc == last_pc) spin++;
			else spin = 0;
			last_pc = ref_rpc;
		end
	end

	initial begin
		string trace, sigf, why;
		longint maxcyc;
		int nsig;
		if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 2000000;
		if ($value$plusargs("trace=%s", trace)) tfd = $fopen(trace, "w");
		// Registers start at zero (arm7tdmi_core.sv resets them), so the trace
		// lists only what changes; NZCV comes up clear.
		for (int k = 0; k < 15; k++) prev[k] = 32'b0;
		prev_f = 4'b0;
		ref_boot();
		while (ref_cyc < maxcyc && fault_cyc < 0 && spin < 8) @(posedge clk_arm);
		repeat (16) @(posedge clk_arm);
		if (fault_cyc >= 0) why = "FAULT write";
		else if (spin >= 8) why = "branch to self";
		else why = "clock limit";
		$display("stop: %s at clock %0d, %0d retired, last pc %08x", why, ref_cyc, nret, last_pc);
		if (fault_cyc >= 0)
			$display("FAULT register written with %02x at clock %0d, after %0d retires", fault_val, fault_cyc, fault_ret);
		$display("bus: %0d data loads, %0d stores, %0d aborts; %0d exceptions; %.2f clocks per instruction",
			nloads, nstores, naborts, nexc, ref_cyc * 1.0 / (nret > 0 ? nret : 1));
		$display("pcm: %0d frames pushed, %0d of them nonzero; PCM enabled %0d",
			npcm, npcm_nz, bup.pcm_enabled);
		$display("result: fault=%02x retired=%0d clocks=%0d pushes=%0d nonzero=%0d aborts=%0d exceptions=%0d spin=%0d",
			fault_cyc >= 0 ? fault_val : 8'h00, fault_cyc >= 0 ? fault_ret + 1 : nret, ref_cyc,
			npcm, npcm_nz, naborts, nexc, spin >= 8);
		if (tfd != 0) $fclose(tfd);
		if ($value$plusargs("sig=%s", sigf)) begin
			int sfd;
			if (!$value$plusargs("signum=%d", nsig)) nsig = 2048;
			sfd = $fopen(sigf, "w");
			for (int i = 0; i < nsig; i++)
				$fdisplay(sfd, "%08x", bup.memory.private_ram.mem_q[i]);
			$fclose(sfd);
		end
		$finish;
	end
endmodule
