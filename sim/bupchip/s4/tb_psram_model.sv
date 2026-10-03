//------------------------------------------------------------------------------
// Self-test of the PSRAM model (psram_model.sv), driven pin by pin: cycles
// with psram.sv's timing at 28.636 MHz must pass and return what was
// written; each check must fire, alone, on a cycle that breaks just its
// rule; and the backdoor must load, compare and dump a file. Runs in
// iverilog; under Verilator (two-state) the X and bus checks are left out.
//
//   +bin=FILE   bytes for the backdoor test: byte k = (7k + 3) mod 256, at
//               least 32 of them (run_psram_ctl.sh makes 1,001)
//   +dump=FILE  where bd_dump_bin writes them back (the script compares)
//
// The last line, "result: ...", is for run_psram_ctl.sh.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ps/1ps

module tb_psram_model;
	reg  [21:16] a = 0;
	reg  [15:0] dq_out = 0;
	reg         dq_oe = 0, host_oe = 0;
	reg  [15:0] host_val = 16'h0F0F;
	reg         clk = 0, adv_n = 1, cre = 0, ce0_n = 1, ce1_n = 1, oe_n = 1, we_n = 1, ub_n = 1, lb_n = 1;
	wire [15:0] dq;
	wire        wt;
	assign dq = dq_oe ? dq_out : 16'hzzzz;
	assign dq = host_oe ? host_val : 16'hzzzz;	// a second driver, for the BUS test

	psram_model m (.cram_a(a), .cram_dq(dq), .cram_wait(wt), .cram_clk(clk), .cram_adv_n(adv_n),
		.cram_cre(cre), .cram_ce0_n(ce0_n), .cram_ce1_n(ce1_n), .cram_oe_n(oe_n), .cram_we_n(we_n),
		.cram_ub_n(ub_n), .cram_lb_n(lb_n));

	int unsigned fails = 0, tests = 0;
	int unsigned prev_n [0:17];

	// One cycle; times in ns from its start, -1 = never. ctl_f is WE# (write)
	// or OE# (read) falling; everything ends at end_t. host_on/host_off
	// switch on the second DQ driver.
	task automatic cyc(input bit wr, input bit die, input logic [21:0] ad, input logic [15:0] d,
			input bit [1:0] be, input int ce_f, input int adv_f, input int adv_r, input int addr_on,
			input int addr_off, input int ctl_f, input int dat_on, input int end_t,
			input int host_on, input int host_off, input bit both, input logic oe_val,
			output logic [15:0] q);
		fork
			if (ce_f >= 0) begin
				#(ce_f * 1000);
				if (die || both) ce1_n = 0;
				if (!die || both) ce0_n = 0;
				ub_n = !be[1];
				lb_n = !be[0];
			end
			if (adv_f >= 0) begin #(adv_f * 1000); adv_n = 0; end
			if (adv_r >= 0) begin #(adv_r * 1000); adv_n = 1; end
			if (addr_on >= 0) begin #(addr_on * 1000); a = ad[21:16]; dq_out = ad[15:0]; dq_oe = 1; end
			if (addr_off >= 0) begin #(addr_off * 1000); dq_oe = 0; end
			if (ctl_f >= 0) begin
				#(ctl_f * 1000);
				if (wr) we_n = 0; else oe_n = oe_val;
			end
			if (dat_on >= 0) begin #(dat_on * 1000); dq_out = d; dq_oe = 1; end
			if (host_on >= 0) begin #(host_on * 1000); host_oe = 1; end
			if (host_off >= 0) begin #(host_off * 1000); host_oe = 0; end
			begin
				#(end_t * 1000);
				q = dq;
				we_n = 1; oe_n = 1; ce0_n = 1; ce1_n = 1; ub_n = 1; lb_n = 1; dq_oe = 0; adv_n = 1;
			end
		join
		#50000;
	endtask

	// psram.sv's timing at 28.636 MHz
	task automatic wr_ok(input bit die, input logic [21:0] ad, input logic [15:0] d, input bit [1:0] be);
		logic [15:0] q;
		cyc(1, die, ad, d, be, 0, 0, 35, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
	endtask
	task automatic rd_ok(input bit die, input logic [21:0] ad, output logic [15:0] q);
		cyc(0, die, ad, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, -1, -1, 0, 0, q);
	endtask

	function automatic void snap();
		for (int c = 0; c < 18; c++) prev_n[c] = m.viol_n[c];
	endfunction

	// exp_n > 0: exactly that many of code; exp_n < 0: at least one; nothing else
	function automatic void expect_viol(input string name, input int code, input int exp_n);
		int d;
		bit ok;
		string what;
		ok = 1;
		what = "nothing";
		if (code >= 0) what = m.vname(code);
		for (int c = 0; c < 18; c++) begin
			d = m.viol_n[c] - prev_n[c];
			if (c == code) begin
				if (exp_n > 0 ? d != exp_n : d < 1) ok = 0;
			end else if (d != 0) ok = 0;
		end
		tests++;
		if (!ok) begin
			fails++;
			$display("FAIL %s: expected %0s x %0d, got:", name, what, exp_n);
			for (int c = 0; c < 18; c++)
				if (m.viol_n[c] != prev_n[c]) $display("  %0d x %s", m.viol_n[c] - prev_n[c], m.vname(c));
		end else
			$display("ok   %s", name);
	endfunction

	function automatic void expect_eq(input string name, input logic [15:0] got, input logic [15:0] want);
		tests++;
		if (got !== want) begin
			fails++;
			$display("FAIL %s: %h, expected %h", name, got, want);
		end else
			$display("ok   %s (%h)", name, got);
	endfunction

	initial begin
		logic [15:0] q;
		string bin, dump;
		int unsigned n, bad;
		int first_bad;
		#100000;

		// Good cycles, both dies, partial writes, unwritten bytes
		snap();
		wr_ok(0, 22'h123456, 16'hBEEF, 2'b11);
		rd_ok(0, 22'h123456, q);
		expect_eq("write and read back, die 0", q, 16'hBEEF);
		wr_ok(1, 22'h123456, 16'hCAFE, 2'b11);
		rd_ok(1, 22'h123456, q);
		expect_eq("the same address on die 1", q, 16'hCAFE);
		rd_ok(0, 22'h123456, q);
		expect_eq("die 0 unchanged", q, 16'hBEEF);
		wr_ok(0, 22'h123456, 16'h1100, 2'b10);
		rd_ok(0, 22'h123456, q);
		expect_eq("high byte only", q, 16'h11EF);
		wr_ok(0, 22'h123456, 16'h0022, 2'b01);
		rd_ok(0, 22'h123456, q);
		expect_eq("low byte only", q, 16'h1122);
		wr_ok(0, 22'h123456, 16'h3333, 2'b00);
		rd_ok(0, 22'h123456, q);
		expect_eq("no byte enabled: nothing written", q, 16'h1122);
		wr_ok(0, 22'h3FFFFF, 16'h7E81, 2'b11);
		rd_ok(0, 22'h3FFFFF, q);
		expect_eq("top halfword", q, 16'h7E81);
		wr_ok(1, 22'h000777, 16'h5500, 2'b10);
		rd_ok(1, 22'h000777, q);
`ifdef VERILATOR
		expect_eq("half-written halfword", q, 16'h5500 | (m.unwritten_pattern(1, 22'h000777) & 16'h00FF));
`else
		expect_eq("half-written halfword: the other byte reads X", q, 16'h55xx);
`endif
		expect_viol("good cycles raise nothing", -1, 0);

		// One rule broken at a time
		snap(); cyc(1, 0, 22'h001000, 16'h1234, 2'b11, 0, 32, 35, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
		expect_viol("ADV# low 3 ns", m.V_T_VP, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 32, 70, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("address 3 ns before ADV# rises", m.V_T_AVS, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 36, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("address held 1 ns after ADV# rises", m.V_T_AVH, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 35, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("address released as ADV# rises", m.V_T_AVH, 1);
		snap(); cyc(1, 1, 22'h001000, 16'h1234, 2'b11, 30, 0, 35, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
		expect_viol("CE# low 5 ns before ADV# rises", m.V_T_CVS, 1);
		snap(); cyc(1, 0, 22'h001000, 16'h1234, 2'b11, 0, 0, 35, 0, 70, 100, 105, 140, -1, -1, 0, 0, q);
		expect_viol("WE# low 40 ns", m.V_T_WP, 1);
		snap(); cyc(1, 0, 22'h001000, 16'h1234, 2'b11, 0, 0, 10, 0, 15, 0, 30, 65, -1, -1, 0, 0, q);
		expect_viol("write ends 65 ns after ADV# falls", m.V_T_AW, 1);
		snap(); cyc(1, 0, 22'h001000, 16'h1234, 2'b01, 0, 0, 35, 0, 70, 0, 125, 140, -1, -1, 0, 0, q);
		expect_viol("data 15 ns before the write ends", m.V_T_DW, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 10, 0, 15, 20, -1, 60, -1, -1, 0, 0, q);
		expect_viol("read ends 60 ns after ADV# falls", m.V_T_AADV, 1);
`ifdef VERILATOR
		expect_eq("  and returns garbage", q, ~m.bd_read(0, 22'h001000));
`else
		expect_eq("  and returns X", q, 16'hxxxx);
`endif
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 125, -1, 140, -1, -1, 0, 0, q);
		expect_viol("read ends 15 ns after OE# falls", m.V_T_OE, 1);
`ifndef VERILATOR
		expect_eq("  and returns X", q, 16'hxxxx);
`endif
		snap(); cyc(1, 0, 22'h001000, 16'h1234, 2'b11, 0, -1, -1, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
		expect_viol("write with no ADV# pulse", m.V_NO_ADDR, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, -1, -1, 0, 70, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("read with no ADV# pulse", m.V_NO_ADDR, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, -1, -1, 1, 0, q);
		expect_viol("both dies selected", m.V_CE_BOTH, -1);
		snap(); cre = 1; cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, -1, -1, 0, 0, q); cre = 0;
		expect_viol("CRE high", m.V_CRE, -1);
		snap(); clk = 1; #10000; clk = 0; #10000;
		expect_viol("cram_clk toggles", m.V_CLK, 1);
		snap(); cyc(0, 1, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 5000, -1, -1, 0, 0, q);
		expect_viol("CE# low 5 us", m.V_T_CEM, 1);
`ifndef VERILATOR
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, -1, -1, 0, 1'bx, q);
		expect_viol("OE# X", m.V_CTRL_X, -1);
		snap(); cyc(0, 0, 22'h0010x0, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("X in the address", m.V_ADDR_X, 1);
		snap(); cyc(1, 0, 22'h001000, 16'hx234, 2'b10, 0, 0, 35, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
		expect_viol("X in a written byte", m.V_DATA_X, 1);
		snap(); cyc(1, 0, 22'h001000, 16'hx234, 2'b01, 0, 0, 35, 0, 70, 0, 105, 140, -1, -1, 0, 0, q);
		expect_viol("X in a byte not written", -1, 0);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 120, 105, -1, 140, -1, -1, 0, 0, q);
		expect_viol("host still drives DQ as OE# falls", m.V_BUS, 1);
		snap(); cyc(0, 0, 22'h001000, 0, 2'b11, 0, 0, 35, 0, 70, 105, -1, 140, 130, 135, 0, 0, q);
		expect_viol("host drives DQ while the die does", m.V_BUS, 1);
`endif

		// Backdoor
		snap();
		m.bd_write(1, 22'h2ABCDE, 16'hA55A, 2'b11);
		rd_ok(1, 22'h2ABCDE, q);
		expect_eq("bd_write, then a read", q, 16'hA55A);
		wr_ok(1, 22'h2ABCDF, 16'h6996, 2'b11);
		expect_eq("a write, then bd_read", m.bd_read(1, 22'h2ABCDF), 16'h6996);
		expect_eq("bd_written", {14'h0, m.bd_written(1, 22'h2ABCDF)}, 16'h0003);
		if ($value$plusargs("bin=%s", bin)) begin
			m.bd_load_bin(bin, 0, 22'h200003, n);	// an odd start byte
			m.bd_compare_bin(bin, 0, 22'h200003, n, bad, first_bad);
			tests++;
			if (n < 2 || bad != 0) begin fails++; $display("FAIL bd_load_bin/bd_compare_bin: %0d bytes, %0d differ", n, bad); end
			else $display("ok   bd_load_bin of %0d bytes at byte 0x200003, bd_compare_bin finds 0 differences", n);
			rd_ok(0, 22'h100002, q);	// bytes 0x200004-5 = file bytes 1-2
			expect_eq("  a read of file bytes 1 and 2", q, 16'h110A);
			m.bd_write(0, 22'h100010, 16'h0000, 2'b10);	// byte 0x200021 = file byte 30
			m.bd_compare_bin(bin, 0, 22'h200003, n, bad, first_bad);
			tests++;
			if (bad != 1 || first_bad != 30) begin fails++; $display("FAIL one byte changed: %0d differ, first %0d", bad, first_bad); end
			else $display("ok   one byte changed: bd_compare_bin finds it (file byte %0d)", first_bad);
			m.bd_load_bin(bin, 0, 22'h200003, n);
			if ($value$plusargs("dump=%s", dump)) m.bd_dump_bin(dump, 0, 22'h200003, n);
		end
		expect_viol("backdoor raises nothing", -1, 0);
		snap();
		m.bd_clear();
		tests++;
		if (m.bd_written(1, 22'h2ABCDE) != 0 || m.bd_written(0, 22'h3FFFFF) != 0) begin fails++; $display("FAIL bd_clear"); end
		else $display("ok   bd_clear");

		m.report();
		$display("result: tests=%0d fails=%0d", tests, fails);
		$finish;
	end
endmodule
