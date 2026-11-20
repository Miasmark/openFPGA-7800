// A FujiNet on the link, for tb_load.sv (docs/FUJINET_GAME_LOADING.md,
// step 4): the device's side of a game boot, as fujinet-firmware's
// lib/device/rs232/disk.cpp (push_image) and pico/common/src/fujimail.c
// make it, from the packet format of fujibus_model.py.
//
// It listens on rx (the core's TX) for SLIP-framed FujiBus packets. A
// MOUNT_IMAGE ($F8 to the FujiNet, $70) is answered by pushing FILE to
// device $FF: NET_OPEN $4F (a 2-byte parameter, the segment 0; payload
// stream 0 and the size, 32-bit LE), NET_WRITE $57 blocks of 512 bytes,
// NET_CLOSE $43, each sent only once the core has answered the one before;
// then the MOUNT_IMAGE's own reply, an ACK from $70. Anything else is
// answered with a bare ACK from its device. Every frame the core sends is
// logged with its device and command; a push frame answered with anything
// but an ACK ends the push, and the MOUNT_IMAGE is then answered with NAK.
//   FILE: the whole file is sent, header and all, as FujiNet sends a .a78.
//
// SPDX-License-Identifier: MIT
`timescale 1ps/1ps

module fn_model #(
	parameter int BIT = 124        // clk clocks per bit: 115,200 baud at clk_sys NTSC
) (
	input  logic clk,
	input  logic rx,
	output logic tx
);
	initial tx = 1'b1;

	string      path = "";
	logic [7:0] file [$];
	int         pushes = 0, push_bytes = 0, push_frames = 0, push_bad = 0, frames_in = 0;
	bit         on = 0;

	initial begin
		int fd, c;
		if ($value$plusargs("fnpush=%s", path)) begin
			fd = $fopen(path, "rb");
			if (fd == 0) $fatal(1, "fn_model: cannot open %s", path);
			while ((c = $fgetc(fd)) != -1) file.push_back(c[7:0]);
			$fclose(fd);
			on = 1;
			$display("FNMODEL on: will push %s, %0d bytes", path, file.size());
		end
	end

	// ---- the line ---------------------------------------------------------------------
	task automatic send_byte(input logic [7:0] b);
		tx <= 1'b0;
		repeat (BIT) @(posedge clk);
		for (int i = 0; i < 8; i++) begin
			tx <= b[i];
			repeat (BIT) @(posedge clk);
		end
		tx <= 1'b1;
		repeat (BIT) @(posedge clk);
	endtask

	function automatic logic [7:0] cks(input logic [7:0] p [$]);
		int c = 0;
		foreach (p[i]) begin
			c += p[i];
			c = (c >> 8) + (c & 8'hFF);
		end
		return 8'(c);
	endfunction

	// A packet: device, command, length LE, checksum, the first descriptor
	// (0 without parameters, 0x05 for one 2-byte one), its values, payload
	task automatic send_packet(input logic [7:0] dev, input logic [7:0] cmd, input bit seg_param,
	                           input logic [7:0] pl [$]);
		logic [7:0] p [$];
		int n;
		p = '{dev, cmd, 8'd0, 8'd0, 8'd0, seg_param ? 8'h05 : 8'h00};
		if (seg_param) begin p.push_back(8'h00); p.push_back(8'h00); end
		foreach (pl[i]) p.push_back(pl[i]);
		n = p.size();
		p[2] = 8'(n);
		p[3] = 8'(n >> 8);
		p[4] = cks(p);
		send_byte(8'hC0);
		foreach (p[i])
			if (p[i] == 8'hC0) begin send_byte(8'hDB); send_byte(8'hDC); end
			else if (p[i] == 8'hDB) begin send_byte(8'hDB); send_byte(8'hDD); end
			else send_byte(p[i]);
		send_byte(8'hC0);
	endtask

	// The core's frames, unescaped: a queue of packets
	logic [7:0] pk [$][$];
	initial begin : receiver
		logic [7:0] b, cur [$];
		bit inf = 0, esc = 0;
		forever begin
			@(negedge rx);
			repeat (BIT / 2) @(posedge clk);
			if (rx) continue;
			for (int i = 0; i < 8; i++) begin
				repeat (BIT) @(posedge clk);
				b[i] = rx;
			end
			repeat (BIT) @(posedge clk);
			if (b == 8'hC0) begin
				if (inf && cur.size() >= 6) begin
					pk.push_back(cur);
					frames_in++;
				end
				cur = {};
				inf = 1;
				esc = 0;
			end else if (inf) begin
				if (esc) begin cur.push_back(b == 8'hDC ? 8'hC0 : 8'hDB); esc = 0; end
				else if (b == 8'hDB) esc = 1;
				else cur.push_back(b);
			end
		end
	end

	task automatic next_packet(output logic [7:0] p [$]);
		while (pk.size() == 0) @(posedge clk);
		p = pk.pop_front();
	endtask

	// The device's answer to one push frame: an ACK from $FF, or the push ends
	task automatic push_answer(input string what, output bit ok);
		logic [7:0] a [$];
		next_packet(a);
		ok = a[0] == 8'hFF && a[1] == 8'h06;
		if (!ok) begin
			$display("FNMODEL %0d ms: %s answered with dev %02x cmd %02x, not an ACK", $time / 1000000000, what, a[0], a[1]);
			push_bad++;
		end
	endtask

	initial begin : device
		logic [7:0] p [$], pl [$];
		bit ok;
		forever begin
			next_packet(p);
			$display("FNMODEL %0d ms: request dev %02x cmd %02x, %0d bytes", $time / 1000000000, p[0], p[1], p.size());
			repeat (2000) @(posedge clk);       // the device thinking
			if (on && p[0] == 8'h70 && p[1] == 8'hF8) begin
				pushes++;
				pl = '{8'h00, 8'(file.size()), 8'(file.size() >> 8), 8'(file.size() >> 16), 8'(file.size() >> 24)};
				send_packet(8'hFF, 8'h4F, 1'b1, pl);
				push_frames++;
				push_answer("NET_OPEN", ok);
				for (int o = 0; ok && o < file.size(); o += 512) begin
					pl = {};
					for (int i = o; i < o + 512 && i < file.size(); i++) pl.push_back(file[i]);
					send_packet(8'hFF, 8'h57, 1'b0, pl);
					push_frames++;
					push_bytes += pl.size();
					push_answer("NET_WRITE", ok);
				end
				if (ok) begin
					pl = {};
					send_packet(8'hFF, 8'h43, 1'b0, pl);
					push_frames++;
					push_answer("NET_CLOSE", ok);
				end
				$display("FNMODEL %0d ms: pushed %0d bytes in %0d frames, %0s", $time / 1000000000, push_bytes, push_frames,
					ok ? "all ACKed" : "refused");
				pl = {};
				send_packet(8'h70, ok ? 8'h06 : 8'h15, 1'b0, pl);
			end else begin
				pl = {};
				send_packet(p[0], 8'h06, 1'b0, pl);
			end
		end
	end
endmodule
