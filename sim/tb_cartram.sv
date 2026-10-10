//------------------------------------------------------------------------------
// tb_cartram: tb_load with the 2600 cartridge-RAM monitor (+cartram) and the
// directed s19 run (+inject). DARIA step 7 (docs/daria_step7/plan.md 3.6,
// 1.2 row 6); the design is docs/DARIA_CORE.md, "Fix B", section 4.
// cartram2600_test.py builds the test images and runs the matrix.
//
// +cartram watches every 2600 cartridge-RAM access in the whole core:
//   - every CPU read of cart RAM (cart2600 answering from cr_do at pclk0):
//     the byte the CPU latches against the SRAM model's; that sram_ctrl
//     handed a cartridge read to c_rdata since E0 (the clk_sys edge where
//     pclk1 loads the 6507's address); the clk_sdram edge of that hand-over
//     counted from E0 (s0 = E0), as a histogram; the margin to the latch;
//   - every 2600 write strobe at the mapper boundary (top.sv cartram_*26):
//     against the cartridge writes sram_ctrl issues, and a shadow of the
//     bytes written, compared with the SRAM model at the end;
//   - the strobe's rise after E0, and any address, direction or data change
//     while it is held.
// At the end it prints the CARTRAM lines cartram2600_test.py checks.
//
// +inject places another client's SRAM access at a chosen clk_sdram edge of
// the 6507 cycle: a BIOS download write (sram_ctrl's dl client, bench-forced
// on its dl_wr input, which is idle in these runs), so that dl_v is set at
// s(d-1) and the access starts at s(d) if the SRAM is free and no cartridge
// or Flicker Blend access is waiting. +inject=D places it at s(D) of every
// cycle (2 <= D <= 47); +inject=sweep moves it one edge further each time,
// over all 48 edges of the cycle. The CARTRAM inject lines give, per phase
// of the injected access relative to the cycle's E0, the reads and their
// latest hand-over. With Fix B an access starting at s8 makes the
// cartridge read wait until s13, so its byte lands at s19, the limit of the
// c_rdata multicycle (DARIA_CORE.md, Fix B 2).
//
// The taps (sram_ctrl's take, go_cl, go_we, done_v, done_cl, dl_wr; top.sv's
// cartram_*26, pclk0/pclk1, tia_en, cs_cart; cart2600's is_bad_game, sel_*,
// cartram_data) are read-only, except the dl_wr force of +inject.
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_cartram;
	tb_load tb ();

	localparam real TSD = 17.46;   // clk_sdram period
	`define CR_M tb.dut.main
	`define CR_C tb.dut.main.cart2600
	`define CR_S tb.dut.sram

	bit  on = 1'b0;
	initial on = $test$plusargs("cartram");

	real t_e0 = 0, t_done = -1e9;
	int  rd_n = 0, rd_bad = 0, rd_stale = 0, rd_late_sdc = 0;
	int  lat_hist [0:40];
	int  lat_min = 99, lat_max = -1, mar_min = 99;
	int  p1p2_min = 99, p1p2_max = -1;
	int  wr_strobes = 0, wr_issued = 0, rd_issued = 0, fb_issued = 0, other_issued = 0;
	int  mid_changes = 0, wr_data_changes = 0, rise_min = 99, rise_max = -1;
	int  shown = 0;
	byte shadow [int];
	logic s_on_q = 0, s_wr_q = 0; logic [17:0] s_a_q = 0; logic [7:0] s_d_q = 0;
	int  sys_since_e0 = 0;

	initial for (int i = 0; i <= 40; i++) lat_hist[i] = 0;

	initial if (on)
`ifdef SIM_FIXB
		$display("CARTRAM sram_ctrl: Fix B (the 2600 request registered on clk_sys, t_new)");
`else
		$display("CARTRAM sram_ctrl: the merged request (before Fix B)");
`endif

	// clk_sdram side: accesses started and read results handed over
	always @(posedge tb.clk_sdram) if (on) begin
		if (`CR_S.take) begin
			if (`CR_S.go_cl == 3'd0) begin
				if (`CR_S.go_we) wr_issued++; else rd_issued++;
			end else if (`CR_S.go_cl == 3'd1) fb_issued++;
			else other_issued++;
		end
		if (`CR_S.done_v && `CR_S.done_cl == 3'd0) t_done = $realtime;
	end

	wire tia = `CR_M.tia_en;
	wire cpu_reads_ram = tia && `CR_M.RW && `CR_M.cs_cart && !`CR_C.is_bad_game &&
		`CR_C.sel_ram_sel && `CR_C.sel_ram_rw && |`CR_C.sel_out_en &&
		!`CR_C.sel_flags_out[0] && !`CR_C.sel_flags_out[1];

	// ---- +inject: phase of the latest injected access, per read
	int  inj_mode = -1;            // -1 off, 0..47 fixed, 48 sweep
	int  inj_d = 2, inj_n = 0;
	real t_inj = -1e9, inj_target = -1e9, inj_last_target = -1e9;
	bit  inj_set = 1'b0;
	int  ph_reads [0:47], ph_max [0:47], ph_min [0:47];
	initial begin
		string m;
		for (int i = 0; i < 48; i++) begin ph_reads[i] = 0; ph_max[i] = -1; ph_min[i] = 99; end
		if ($value$plusargs("inject=%s", m)) begin
			if (m == "sweep") begin inj_mode = 48; inj_d = 0; end
			else begin
				inj_mode = m.atoi();
				inj_d = inj_mode;
				if (inj_mode < 2 || inj_mode > 47) $fatal(1, "+inject=%s: sweep, or 2..47", m);
			end
		end
	end
	// Between edges (on the falling edge of clk_sdram) so nothing races E0:
	// k is the clk_sdram rising edge just past, counted from E0.
	always @(negedge tb.clk_sdram) if (on && inj_mode >= 0 && tia) begin
		automatic int k = $rtoi(($realtime - t_e0) / TSD);
		automatic int set_k = (inj_d + 46) % 48;          // s(d-2)
		automatic real target = inj_d >= 2 ? t_e0 : t_e0 + 48 * TSD;
		if (inj_set) begin
			release `CR_S.dl_wr;
			inj_set = 1'b0;
			t_inj = $realtime + TSD / 2;                   // the access may start at the next edge
			inj_last_target = inj_target;
			inj_n++;
			if (inj_mode == 48) inj_d = (inj_d + 1) % 48;
		end else if (k == set_k && target > inj_last_target + TSD) begin
			force `CR_S.dl_wr = 1'b1;
			inj_set = 1'b1;
			inj_target = target;
		end
	end

	always @(posedge tb.clk_sys) if (on) begin
		automatic logic s_on = tia && (`CR_M.cartram_rd26 || `CR_M.cartram_wr26);
		sys_since_e0 = sys_since_e0 + 1;
		if (`CR_M.pclk1) begin t_e0 = $realtime; sys_since_e0 = 0; end
		// The CPU's latch edge
		if (`CR_M.pclk0 && tia) begin
			automatic int p = $rtoi(($realtime - t_e0) / 69.84 + 0.5);
			if (p < p1p2_min) p1p2_min = p; if (p > p1p2_max) p1p2_max = p;
		end
		if (`CR_M.pclk0 && cpu_reads_ram) begin
			automatic logic [17:0] a = `CR_M.cartram_addr26;
			automatic logic [15:0] w = tb.sram_chip.mem[a[16:1]];
			automatic logic [7:0] exp = a[0] ? w[15:8] : w[7:0];
			automatic logic [7:0] got = `CR_C.cartram_data;
			automatic int lat = $rtoi((t_done - t_e0) / TSD + 0.5);
			automatic int mar = $rtoi(($realtime - t_done) / TSD + 0.5);
			rd_n++;
			if (t_done < t_e0) begin
				rd_stale++;
				if (shown < 10) begin shown++;
					$display("CARTRAM %0d us: read $%05x latched with no access since E0", int'($realtime / 1000), a); end
			end else begin
				if (lat < lat_min) lat_min = lat; if (lat > lat_max) lat_max = lat;
				if (mar < mar_min) mar_min = mar;
				if (lat >= 0 && lat <= 40) lat_hist[lat]++;
				if (lat > 19) rd_late_sdc++;
				if (inj_mode >= 0 && t_inj >= t_e0) begin
					automatic int d = $rtoi((t_inj - t_e0) / TSD + 0.5);
					if (d >= 0 && d < 48) begin
						ph_reads[d]++;
						if (lat > ph_max[d]) ph_max[d] = lat;
						if (lat < ph_min[d]) ph_min[d] = lat;
					end
				end
			end
			if (got !== exp) begin
				rd_bad++;
				if (shown < 10) begin shown++;
					$display("CARTRAM %0d us: read $%05x got %02x, SRAM holds %02x", int'($realtime / 1000), a, got, exp); end
			end
		end
		// The mapper-side strobe
		if (s_on && !s_on_q) begin
			if (sys_since_e0 < rise_min) rise_min = sys_since_e0;
			if (sys_since_e0 > rise_max) rise_max = sys_since_e0;
		end
		if (s_on && s_on_q && (`CR_M.cartram_addr26 != s_a_q || `CR_M.cartram_wr26 != s_wr_q)) mid_changes++;
		if (tia && `CR_M.cartram_wr26) begin
			if (!(s_on_q && s_wr_q && `CR_M.cartram_addr26 == s_a_q)) begin
				wr_strobes++;
				shadow[int'(`CR_M.cartram_addr26)] = `CR_M.cartram_wrdata26;
			end else if (`CR_M.cartram_wrdata26 != s_d_q) wr_data_changes++;
		end
		s_on_q <= s_on; s_wr_q <= `CR_M.cartram_wr26; s_a_q <= `CR_M.cartram_addr26; s_d_q <= `CR_M.cartram_wrdata26;
	end

	final if (on) begin
		automatic int sh_bad = 0, sh_n = 0;
		foreach (shadow[k]) begin
			automatic logic [15:0] w = tb.sram_chip.mem[k[16:1]];
			sh_n++;
			if ((k[0] ? w[15:8] : w[7:0]) !== shadow[k]) begin
				sh_bad++;
				if (sh_bad <= 5) $display("CARTRAM shadow $%05x: wrote %02x, SRAM holds %02x", k, shadow[k], k[0] ? w[15:8] : w[7:0]);
			end
		end
		$display("CARTRAM phases: pclk1->pclk0 %0d..%0d clk_sys; strobe rises %0d..%0d clk_sys after E0",
			p1p2_min, p1p2_max, rise_min, rise_max);
		$display("CARTRAM reads: %0d CPU reads of cart RAM, %0d wrong byte, %0d without a fresh access, c_rdata at E0+%0d..%0d clk_sdram, min margin to the latch %0d clk_sdram, %0d past E0+19 (SDC window)",
			rd_n, rd_bad, rd_stale, lat_min, lat_max, mar_min, rd_late_sdc);
		$write("CARTRAM latency histogram (clk_sdram from E0: count):");
		for (int i = 0; i <= 40; i++) if (lat_hist[i]) $write(" %0d:%0d", i, lat_hist[i]);
		$display("");
		$display("CARTRAM writes: %0d strobes at the mappers, %0d cart writes issued, %0d bytes in the shadow, %0d differ from the SRAM; %0d data changes inside a strobe",
			wr_strobes, wr_issued, sh_n, sh_bad, wr_data_changes);
		$display("CARTRAM traffic: cart reads issued %0d, Flicker Blend %0d, other %0d; address or direction changes inside a held strobe %0d",
			rd_issued, fb_issued, other_issued, mid_changes);
		if (inj_mode >= 0) begin
			automatic int wmax = -1, wd = -1;
			$display("CARTRAM inject: %0d accesses placed (%0s)", inj_n, inj_mode == 48 ? "sweep over s0..s47" : $sformatf("at s%0d", inj_mode));
			for (int d = 0; d < 48; d++) if (ph_reads[d]) begin
				$display("CARTRAM inject phase s%0d: %0d reads, c_rdata at E0+%0d..%0d", d, ph_reads[d], ph_min[d], ph_max[d]);
				if (ph_max[d] > wmax) begin wmax = ph_max[d]; wd = d; end
			end
			$display("CARTRAM inject worst: c_rdata at E0+%0d with the access at s%0d", wmax, wd);
		end
	end
endmodule
