// Bench for fujinet_mailbox.sv: a 6502 bus model drives the mailbox as a
// FujiNet program does (fujinet-firmware testrom/fujilib.s), and a FujiNet
// model on the far end of the serial line receives each request frame and
// answers with frames run_fujinet.py made (replies.txt, one frame a line:
// its length, then its bytes in hex). Every frame the core sends is printed
// as "TXFRAME n hex..."; run_fujinet.py checks them against its FujiBus model.
// The mailbox checks are here: "CHECK ok/FAIL name got expected".
//
// SPDX-License-Identifier: MIT
`default_nettype none

module tb_fujinet;

logic clk = 1'b0;
always #5 clk = ~clk;

localparam int BIT = 124;          // the core's NTSC divider
localparam int BIT_FN = 125;       // the FujiNet model sends 0.8% slow
localparam int MS = 1000;          // clocks per "ms" (the core's MS_DIV here)

logic        reset = 1'b1;
logic [15:0] addr = 16'h0000;
logic  [7:0] wdata = 8'h00;
logic        rw = 1'b1, phi2 = 1'b0, cs = 1'b0;
logic        bus_oe, txd, tx_en, busy;
logic  [7:0] bus_do;
logic        rxd = 1'b1;          // the FujiNet model's TX, to the link port
logic        rxd_c = 1'b0;        // cartridge pin 31: undriven (low) until case 13
bit          on_cart = 0;         // case 13: the FujiNet model is in the cartridge slot
bit          loop = 0;          // SO wired to SI

fujinet_mailbox #(.MS_DIV(MS)) dut (
	.clk (clk), .reset (reset), .app (1'b1), .pal (1'b0), .tv_pal (1'b0),
	.claim_kind (8'd0), .hsc_rom (1'b0), .hsc_on (1'b0), .bios_skipped (1'b0),
	.addr (addr), .wdata (wdata), .rw (rw), .phi2 (phi2), .cs (cs),
	.bus_oe (bus_oe), .bus_do (bus_do),
	.txd (txd), .tx_en (tx_en), .rxd_link (loop ? txd : (on_cart ? 1'b0 : rxd)), .rxd_cart (on_cart ? rxd : rxd_c), .busy (busy),
	.stg_start (stg_start), .stg_we (stg_we), .stg_addr (stg_addr), .stg_data (stg_data),
	.stg_sync (stg_sync), .stg_synced (stg_synced), .stg_busy (stg_busy), .stg_size (stg_size), .stg_ready (stg_ready),
	.swap_go (swap_go), .swap_restart (swap_restart)
);

// The stager: a memory, busy for 0-12 clocks after each byte (as
// fujinet_stage.sv while a halfword crosses), and SYNC answered 20 clocks later
logic        stg_start, stg_we, stg_sync, stg_ready, swap_go, swap_restart;
logic        stg_synced = 1'b0;
int          stg_hold = 0;
wire         stg_busy = stg_hold != 0;
int          stg_busy_we = 0;
logic [19:0] stg_addr, stg_size;
logic  [7:0] stg_data;
logic  [7:0] stage_mem [0:8191];
int stg_starts = 0, stg_wes = 0, stg_bad = 0, swaps = 0, restarts = 0;
logic [19:0] stg_next = 20'd0;
always @(posedge clk) begin
	if (stg_start) begin stg_starts++; stg_next = 20'd0; end
	if (stg_hold != 0) stg_hold--;
	if (stg_we) begin
		if (stg_busy) stg_busy_we++;             // a byte while busy would be lost
		stg_hold = $urandom_range(0, 12);
		if (stg_addr != stg_next) stg_bad++;     // in order, from 0
		stg_next = stg_addr + 20'd1;
		stage_mem[stg_addr[12:0]] <= stg_data;
		stg_wes++;
	end
	if (swap_go) swaps++;
	if (swap_restart) restarts++;
end
initial forever begin
	@(posedge clk);
	if (stg_sync) begin
		repeat (20) @(posedge clk);
		stg_synced <= 1'b1;
		@(posedge clk);
		stg_synced <= 1'b0;
	end
end
logic [7:0] image [0:4223];
initial $readmemh("image.hex", image);

int fails = 0;

task automatic check(input string name, input int got, input int exp);
	if (got == exp) $display("CHECK ok %s %0d", name, got);
	else begin
		$display("CHECK FAIL %s got %0d expected %0d", name, got, exp);
		fails++;
	end
endtask

// One CPU cycle: 8 clk_sys, the write taken on the phi2 clock
task automatic cpu_write(input logic [15:0] a, input logic [7:0] d);
	@(posedge clk); addr <= a; wdata <= d; rw <= 1'b0; cs <= 1'b1;
	repeat (6) @(posedge clk);
	phi2 <= 1'b1;
	@(posedge clk); phi2 <= 1'b0;
	@(posedge clk); rw <= 1'b1; cs <= 1'b0;
endtask

task automatic cpu_read(input logic [15:0] a, output logic [7:0] d);
	@(posedge clk); addr <= a; rw <= 1'b1; cs <= 1'b1;
	repeat (6) @(posedge clk);
	if (!bus_oe) $display("NOTE no drive at %h", a);
	d = bus_do;
	@(posedge clk); cs <= 1'b0;
endtask

task automatic reg_w(input logic [6:0] n, input logic [7:0] v);
	cpu_write(16'h0D00 + {9'd0, n}, v);
endtask

function automatic logic [15:0] st(input logic [7:0] off);
	return 16'h0C00 + {8'd0, off};
endfunction

// fujilib.s fn_go: SEQ = ACKSEQ + 1, then wait for the echo
task automatic go(output logic [7:0] s);
	logic [7:0] a;
	cpu_read(st(8'h00), a);
	s = (a == 8'hFF) ? 8'd1 : a + 8'd1;
	reg_w(7'h10, s);
endtask

task automatic wait_ack(input logic [7:0] s, input longint limit);
	logic [7:0] a;
	longint n = 0;
	do begin
		cpu_read(st(8'h00), a);
		n++;
	end while (a != s && n < limit);
	if (a != s) begin
		$display("CHECK FAIL ackseq never echoed %0d", s);
		fails++;
	end
endtask

task automatic begin_txn(input logic [7:0] dev, input logic [7:0] cmd, input logic [7:0] np);
	reg_w(7'h00, dev);
	reg_w(7'h01, cmd);
	reg_w(7'h02, np);
	reg_w(7'h05, 8'h00);
endtask

task automatic tx(input logic [7:0] b);
	cpu_write(16'h0F00 + {8'd0, b ^ 8'h5A}, b);   // any address in the page
endtask

// The FujiNet model: a receiver on txd
int ntx = 0;
logic [7:0] fr[$];
event got_frame;
initial begin : fn_rx
	logic [7:0] b;
	bit inframe = 0;
	forever begin
		@(negedge txd);
		repeat (BIT / 2) @(posedge clk);
		if (txd) continue;
		for (int i = 0; i < 8; i++) begin
			repeat (BIT) @(posedge clk);
			b[i] = txd;
		end
		repeat (BIT) @(posedge clk);
		if (!txd) $display("NOTE framing error");
		if (b == 8'hC0) begin
			if (inframe && fr.size() > 1) begin
				fr.push_back(b);
				begin
					string s = "";
					foreach (fr[k]) s = {s, $sformatf(" %02x", fr[k])};
					$display("TXFRAME %0d%s", ntx, s);
				end
				ntx++;
				inframe = 0;
				fr.delete();
				-> got_frame;
				continue;
			end
			fr.delete();
			inframe = 1;
		end
		fr.push_back(b);
	end
end

// Replies from run_fujinet.py
logic [7:0] rep[64][$];
int nrep = 0;
initial begin
	int f, n, v;
	f = $fopen("replies.txt", "r");
	if (f == 0) $fatal(1, "no replies.txt");
	while ($fscanf(f, "%d", n) == 1) begin
		for (int i = 0; i < n; i++) begin
			void'($fscanf(f, "%h", v));
			rep[nrep].push_back(v[7:0]);
		end
		nrep++;
	end
	$fclose(f);
end

task automatic send(input int k);
	foreach (rep[k][i]) begin
		rxd <= 1'b0;
		repeat (BIT_FN) @(posedge clk);
		for (int j = 0; j < 8; j++) begin
			rxd <= rep[k][i][j];
			repeat (BIT_FN) @(posedge clk);
		end
		rxd <= 1'b1;
		repeat (BIT_FN) @(posedge clk);
	end
endtask

task automatic expect_frame(input int timeout_clks);
	fork
		begin @(got_frame); end
		begin repeat (timeout_clks) @(posedge clk); $display("CHECK FAIL no TX frame"); fails++; end
	join_any
	disable fork;
endtask

task automatic rd(input logic [15:0] a, output int v);
	logic [7:0] d;
	cpu_read(a, d);
	v = d;
endtask

initial begin
	logic [7:0] s, d;
	int v, len, bad, starts0;
	repeat (10) @(posedge clk);
	reset <= 1'b0;
	repeat (10) @(posedge clk);

	rd(st(8'h09), v); check("magic F", v, "F");
	rd(st(8'h0A), v); check("magic N", v, "N");
	rd(st(8'h0B), v); check("proto", v, 1);
	rd(st(8'h12), v); check("mode APP", v, 3);
	rd(st(8'h01), v); check("status at power-on", v, 0);
	rd(st(8'h00), v); check("ackseq at power-on", v, 0);

	// 1: nothing on the line: GET_ADAPTERCONFIG_EXTENDED ends "no link"
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("1 err no link", v, 1);
	rd(st(8'h01), v); check("1 status", v, 0);
	rd(st(8'h04), v); check("1 rxlen", v, 0);

	// 2: three params and a payload with END and ESC in it; the reply has
	// junk before its frame, two fields, and 300 bytes
	begin_txn(8'h70, 8'hE2, 8'd3);
	tx(8'd1); tx(8'h03);
	tx(8'd2); tx(8'hDB); tx(8'hC0);
	tx(8'd4); tx(8'hDB); tx(8'hC0); tx(8'hAD); tx(8'hDE);
	for (int i = 0; i < 40; i++) tx(8'((i * 37 + 'hC0) & 255));
	go(s);
	expect_frame(2000000);
	send(0);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("2 err", v, 0);
	rd(st(8'h03), v); check("2 reply cmd", v, 6);
	rd(st(8'h04), v); len = v; rd(st(8'h05), v); len += v * 256;
	check("2 rxlen", len, 300);
	rd(st(8'h01), v); check("2 status link", v, 1);
	rd(st(8'h15), v); check("2 link seen", v, 1);
	bad = 0;
	for (int i = 0; i < 300; i++) begin
		rd(16'h0800 + 16'(i), v);
		if (v != ((i * 7 + 3) & 255)) bad++;
	end
	check("2 reply bytes wrong", bad, 0);
	rd(16'h0800 + 16'd300, v); check("2 past rxlen", v, 0);
	rd(16'h0BFF, v); check("2 end of window", v, 0);

	// 3: the same SEQ again is a no-op
	reg_w(7'h10, s);
	repeat (20000) @(posedge clk);
	check("3 no frame for a repeated seq", ntx, 2);
	rd(st(8'h00), v); check("3 ackseq", v, s);

	// 4: a reply with a bad checksum
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	send(1);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("4 err bad frame", v, 3);
	rd(st(8'h04), v); check("4 rxlen", v, 0);
	rd(16'h0800, v); check("4 reply hidden", v, 0);

	// 5: MOUNT_IMAGE: the FujiNet opens a push to device $FF (the cart
	// ACKs the OPEN), then refuses the mount itself (a NAK): the push never
	// finished, so the state stays transferring
	begin_txn(8'h70, 8'hF8, 8'd2);
	tx(8'd1); tx(8'd0);
	tx(8'd1); tx(8'd1);
	go(s);
	expect_frame(200000);
	send(2);
	expect_frame(200000);         // the cart's NAK to the push
	send(3);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("5 err", v, 0);
	rd(st(8'h03), v); check("5 reply cmd NAK", v, 8'h15);
	rd(st(8'h06), v); check("5 boot state transferring (the mount refused mid-push)", v, 1);
	rd(st(8'h08), v); check("5 boot err", v, 0);

	// 6: a reply longer than the 1K window
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	send(4);
	wait_ack(s, 8000000);
	rd(st(8'h02), v); check("6 err", v, 0);
	rd(st(8'h04), v); len = v; rd(st(8'h05), v); len += v * 256;
	check("6 rxlen clamped", len, 1024);
	rd(16'h0BFF, v); check("6 last byte", v, (1023 * 11) & 255);

	// 7: NPARAM says 2, the stream has one: refused before anything is sent
	begin_txn(8'h70, 8'hC4, 8'd2);
	tx(8'd1); tx(8'h05);
	go(s);
	wait_ack(s, 100000);
	rd(st(8'h02), v); check("7 err bad frame", v, 3);
	check("7 nothing sent", ntx, 6);

	// 8: a size byte that is not 1, 2 or 4
	begin_txn(8'h70, 8'hC4, 8'd1);
	tx(8'd3); tx(8'h05); tx(8'h05); tx(8'h05);
	go(s);
	wait_ack(s, 100000);
	rd(st(8'h02), v); check("8 err bad frame", v, 3);

	// 9: TV register
	reg_w(7'h15, 8'd1);
	rd(st(8'h1E), v); check("9 tv", v, 1);

	// 10: the link is up, the FujiNet says nothing: 5 s, then a timeout,
	// and the link is down again
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	wait_ack(s, 8000000);
	rd(st(8'h02), v); check("10 err timeout", v, 2);
	rd(st(8'h01), v); check("10 link dropped", v, 0);

	// 11: an empty payload, one 4-byte param, and the reply NAK with no data
	begin_txn(8'h71, 8'h4F, 8'd1);
	tx(8'd4); tx(8'h01); tx(8'h02); tx(8'h03); tx(8'h04);
	go(s);
	expect_frame(200000);
	send(5);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("11 err", v, 0);
	rd(st(8'h03), v); check("11 nak", v, 8'h15);
	rd(st(8'h04), v); check("11 rxlen", v, 0);

	// 12: SO wired to SI: the cart hears its own request, a good frame
	// (one param, skipped as a field, and a payload "AB" that is the reply)
	loop = 1;
	begin_txn(8'h70, 8'hC4, 8'd1);
	tx(8'd1); tx(8'h07);
	tx("A"); tx("B");
	go(s);
	expect_frame(200000);
	wait_ack(s, 400000);
	rd(st(8'h02), v); check("12 loopback err", v, 0);
	rd(st(8'h03), v); check("12 loopback reply cmd", v, 8'hC4);
	rd(st(8'h04), v); check("12 loopback rxlen", v, 2);
	rd(16'h0800, v); check("12 loopback data 0", v, "A");
	rd(16'h0801, v); check("12 loopback data 1", v, "B");
	loop = 0;

	rd(st(8'h30), v); check("12 port link", v, 1);

	// 13: the FujiNet moves to the cartridge slot. The link line goes low
	// (unplugged); the lock is on the link port, so the first request hears
	// nothing, times out and drops the link; the next one finds the
	// cartridge port and locks to it.
	on_cart = 1;
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	wait_ack(s, 8000000);
	rd(st(8'h02), v); check("13 the link port is silent", v, 2);
	rd(st(8'h30), v); check("13 unlocked", v, 0);
	begin_txn(8'h70, 8'hC4, 8'd0);
	go(s);
	expect_frame(200000);
	send(6);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("13 cartridge err", v, 0);
	rd(st(8'h03), v); check("13 cartridge reply cmd", v, 6);
	rd(st(8'h04), v); check("13 cartridge rxlen", v, 4);
	rd(16'h0803, v); check("13 cartridge data 3", v, 8'hC0);
	rd(st(8'h30), v); check("13 port cartridge", v, 2);

	starts0 = stg_starts;
	// 14: MOUNT_IMAGE, and the FujiNet pushes a 4,224-byte A78 (a FUJI claim
	// in its last 4K block) to device $FF: OPEN, nine WRITEs, CLOSE, each
	// ACKed; then the mount's own ACK. READY, the counts, every byte staged.
	begin_txn(8'h70, 8'hF8, 8'd2);
	tx(8'd1); tx(8'd0);
	tx(8'd1); tx(8'd1);
	go(s);
	expect_frame(200000);
	for (int k = 7; k <= 17; k++) begin
		send(k);
		expect_frame(2000000);       // the cart's ACK
	end
	rd(st(8'h06), v); check("14 boot state READY", v, 2);
	rd(st(8'h07), v); check("14 boot pct", v, 100);
	rd(st(8'h16), v); len = v; rd(st(8'h17), v); len += v * 256;
	check("14 got", len, 4224);
	rd(st(8'h19), v); len = v; rd(st(8'h1A), v); len += v * 256;
	check("14 tot", len, 4224);
	rd(st(8'h1F), v); check("14 staged: ready, claim, bios ok", v, 7);
	check("14 stager starts", stg_starts - starts0, 1);
	check("14 stager bytes", stg_wes, 4224);
	check("14 stager out of order", stg_bad, 0);
	check("14 stager bytes while busy", stg_busy_we, 0);
	bad = 0;
	for (int i = 0; i < 4224; i++) if (stage_mem[i] !== image[i]) bad++;
	check("14 staged bytes wrong", bad, 0);
	check("14 stg_size", int'(stg_size), 4224);
	send(18);
	wait_ack(s, 4000000);
	rd(st(8'h02), v); check("14 mount err", v, 0);
	rd(st(8'h03), v); check("14 mount ACK", v, 6);
	rd(st(8'h06), v); check("14 still READY", v, 2);
	// the loader, and the swap: without BOOTLOCK a restart, with it the image
	rd(16'h0600, v); check("14 loader $0600 JMP", v, 8'h4C);
	rd(16'h0604, v); check("14 loader $0604", v, 8'hFC);
	cpu_write(16'h0DFE, 8'h00);
	repeat (10) @(posedge clk);
	check("14 hot swap unarmed: restart", restarts, 1);
	check("14 hot swap unarmed: no swap", swaps, 0);
	reg_w(7'h11, 8'hB5);
	cpu_write(16'h0DFE, 8'h00);
	repeat (10) @(posedge clk);
	check("14 hot swap armed: swap", swaps, 1);

	// 15: an image too big: the OPEN is NAKed, FAILED, error 1
	begin_txn(8'h70, 8'hF8, 8'd2);
	tx(8'd1); tx(8'd0);
	tx(8'd1); tx(8'd1);
	go(s);
	expect_frame(200000);
	send(19);
	expect_frame(2000000);           // the cart's NAK
	send(20);
	wait_ack(s, 4000000);
	rd(st(8'h06), v); check("15 boot state FAILED", v, 8'h80);
	rd(st(8'h08), v); check("15 boot err too big", v, 1);
	rd(st(8'h1F), v); check("15 nothing staged", v, 0);

	// 16: fewer bytes than declared: FAILED, error 2 (truncated)
	begin_txn(8'h70, 8'hF8, 8'd2);
	tx(8'd1); tx(8'd0);
	tx(8'd1); tx(8'd1);
	go(s);
	expect_frame(200000);
	for (int k = 21; k <= 23; k++) begin
		send(k);
		expect_frame(2000000);
	end
	send(24);
	wait_ack(s, 4000000);
	rd(st(8'h06), v); check("16 boot state FAILED", v, 8'h80);
	rd(st(8'h08), v); check("16 boot err truncated", v, 2);

	$display("TB_FUJINET frames %0d fails %0d", ntx, fails);
	$finish;
end

initial begin
	#2000000000;
	$display("TB_FUJINET timeout");
	$finish;
end

endmodule
