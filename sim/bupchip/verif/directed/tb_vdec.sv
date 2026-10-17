//------------------------------------------------------------------------------
// Decode probe for the BupChip CPU (run_vfy.sh): every word of a list goes
// to bup_cpu's instruction input, and the core's decode-time halt decision
// (dec_bad, read hierarchically) must be clear for each. run_vfy.sh feeds it
// the firmware's 1,704 code words (../../model/inventory.py), so a decode
// change that would halt on an encoding CoreTone uses, even on a path no
// test reaches, fails here. The core is held frozen, so nothing executes;
// halts that depend on data (branch targets, MSR values, addresses) are the
// lockstep runs' business.
//
//   +list=FILE   lines of "<address> <word>" in hex (default code.txt)
//
// The last line is "decode probe: N code words, M decode as a halt".
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ns
module tb_vdec;
	logic        clk = 0, rst = 1;
	logic [31:0] q = 0;
	int          n = 0, n_bad = 0;

`ifdef BUP_THUMB
	bup_cpu #(.MODES(1'b1), .THUMB(1'b1)) cpu (
`else
	bup_cpu cpu (
`endif
		.clk, .rst, .freeze(1'b1), .w_wait(1'b0), .arm_only(1'b1),
		.prof26(1'b0), .img_size(20'd0), .ram32(1'b0), .call_go(1'b0), .clr_wd(32'd0), .clr_pc(32'd0),
		.clr_e(), .parked(), .returned(), .ro_valid(), .ro_idx(), .ro_data(),
		.rom_addr(), .rom_q(q),
		.d_addr(), .ram_we(), .ram_be(), .ram_wdata(), .rom_dq(32'd0), .ram_q(32'd0),
		.asset_size(24'd0), .asset_q(32'd0), .w_asset(), .w_addr(), .w_size(),
		.reg_sel(), .reg_addr(), .reg_write(), .reg_wdata(), .reg_rdata(32'd0),
		.halted(), .halt_code(), .halt_pc(),
		.rt_start(), .rt_valid(), .rt_pc(), .rt_insn(), .rt_nzcv(),
		.rt_e_we(), .rt_e_idx(), .rt_e_data(), .rt_w_we(), .rt_w_idx(), .rt_w_data());

	initial begin
		string f;
		int    fd, r;
		logic [31:0] a, w;
		if (!$value$plusargs("list=%s", f)) f = "code.txt";
		fd = $fopen(f, "r");
		if (fd == 0) $fatal(1, "cannot open %s", f);
		while (!$feof(fd)) begin
			r = $fscanf(fd, "%h %h\n", a, w);
			if (r != 2) break;
			q = w;
			#1;
			n++;
			if (cpu.dec_bad) begin
				n_bad++;
				$display("halts: %08x %08x, code %0d", a, w, cpu.dec_code);
			end
		end
		$fclose(fd);
		$display("decode probe: %0d code words, %0d decode as a halt", n, n_bad);
		$finish;
	end
endmodule
