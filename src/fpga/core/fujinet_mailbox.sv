// FujiNet cartridge mailbox for the 7800, with its FujiBus link on the
// Pocket's link port.
//
// A FujiNet program talks to its cartridge through a mailbox below $1000
// (fujinet-firmware pico/atari-7800/firmware/include/fuji_mailbox.h; the
// FujiNet 7800 programmer's handbook, section 19). The cartridge passes each
// request to a FujiNet device as one FujiBus packet, a SLIP frame at 115,200
// baud (lib/bus/rs232 on the ESP32; pico/common/src/fujibus.c is the
// reference this follows byte for byte), and shows the reply in the mailbox.
// Here the core is the cartridge, and the link port is the serial line:
// link SO (pin 2) carries the core's TX, link SI (pin 3) its RX.
//
// The mailbox is live only for an image that claims it ("FUJI" at $FF70,
// APP mode); fujinet_claim in atari7800_pocket.sv finds the claim while the
// image loads. Then:
//
//   $0800-$0BFF  reply, read in place; bytes past RXLEN read 0
//   $0C00-$0CFF  status page (FN_R_*)
//   $0D00-$0D7F  write V to $0D00+n: register n = V (FN_REG_*)
//   $0F00-$0FFF  write: append the byte to the TX stream (320 bytes at most)
//
// A transaction: DEVICE, CMD, NPARAM, DATA_RST, the TX stream (NPARAM x
// {size 1|2|4, value little endian}, then payload), then SEQ = ACKSEQ + 1.
// When ACKSEQ echoes SEQ, ERR, REPLY_CMD, RXLEN and the reply are in place.
//
// What the RP2354B cartridge does and this does not: the loader at $0600
// (and so MOUNT_IMAGE's image push: an image the FujiNet sends is refused,
// BOOT_STATE FAILED, BOOT_ERR NOMAP), the High Score Cart's SD saves
// (FN_REG_HSC is ignored), and the hot operations at $0D80-$0DFF.
//
// "No link": a USB serial adapter gives no sign it is there, so the link
// counts as up once a good frame has arrived. Until then a transaction waits
// 1.5 s for a reply instead of 5 s (slow commands still get their full time),
// and one that hears no byte at all ends with ERR 1, no link. A transaction
// that hears nothing for its whole time drops the link again.
module fujinet_mailbox #(
	parameter int MS_DIV = 14318   // clk_sys clocks per ms (NTSC's; PAL's is 1% slower)
) (
	input  logic        clk,
	input  logic        reset,        // a new image: everything back to power-on
	input  logic        app,          // the image claims the mailbox
	input  logic        pal,          // clk_sys is PAL's (the UART's divider)
	input  logic        tv_pal,       // the console's region, for FN_R_TV
	input  logic  [7:0] claim_kind,   // the claim's kind byte (A78MAP_* + 1, 0 auto)
	input  logic        hsc_rom,      // FN_R_HSC bits
	input  logic        hsc_on,
	input  logic        bios_skipped, // FN_R_HANDOVER: 2 (direct) rather than 1 (BIOS)

	// The 7800's bus, as the cartridge sees it
	input  logic [15:0] addr,
	input  logic  [7:0] wdata,
	input  logic        rw,
	input  logic        phi2,         // one clock per CPU cycle, as cart.sv takes writes
	input  logic        cs,           // cartridge space
	output logic        bus_oe,
	output logic  [7:0] bus_do,

	// The link port
	output logic        txd,
	output logic        tx_en,        // drive SO (APP mode only)
	input  logic        rxd,
	output logic        busy
);

localparam [7:0] SLIP_END = 8'hC0, SLIP_ESC = 8'hDB, SLIP_ESC_END = 8'hDC, SLIP_ESC_ESC = 8'hDD;
localparam [2:0] ERR_OK = 3'd0, ERR_NOLINK = 3'd1, ERR_TIMEOUT = 3'd2, ERR_BADFRAME = 3'd3, ERR_TOOBIG = 3'd4;

//////////////////////////////  bus side  /////////////////////////////////

// Power-up values here, a new image's values in the reset branches
/* verilator lint_off PROCASSINIT */

wire wr_cyc = app && phi2 && !rw && cs;
wire reg_wr = wr_cyc && addr[15:7] == 9'b0000_1101_0;      // $0D00-$0D7F
wire tx_wr  = wr_cyc && addr[15:8] == 8'h0F;               // $0F00-$0FFF
wire [6:0] reg_n = addr[6:0];

logic [7:0] mb_device = 8'd0, mb_cmd = 8'd0, mb_nparam = 8'd0;
logic [8:0] txptr = 9'd0;
logic [7:0] lastseq = 8'd0, seq = 8'd0, ackseq = 8'd0;
logic [2:0] err = 3'd0;
logic [7:0] reply_cmd = 8'd0;
logic [10:0] rxlen = 11'd0;
logic [7:0] boot_state = 8'd0, boot_err = 8'd0;
logic       tv_set = 1'b0, tv_reg = 1'b0;
logic       link_seen = 1'b0, link_ever = 1'b0;
logic       start = 1'b0;

// TX stream: written by the bus, read by the engine
logic [7:0] txbuf [0:511];
logic [8:0] tx_raddr;
logic [7:0] tx_q;
always_ff @(posedge clk) begin
	if (tx_wr && txptr < 9'd320 && !busy)
		txbuf[txptr] <= wdata;
	tx_q <= txbuf[tx_raddr];
end

// Reply: written by the engine, read by the bus
logic [7:0] rxbuf [0:1023];
logic [9:0] rx_waddr;
logic [7:0] rx_wdata;
logic       rx_we;
logic [7:0] rx_q;
logic       rd_in_len = 1'b0;
always_ff @(posedge clk) begin
	if (rx_we)
		rxbuf[rx_waddr] <= rx_wdata;
	rx_q <= rxbuf[addr[9:0]];
	rd_in_len <= {1'b0, addr[9:0]} < rxlen;
end

// Status page
logic [7:0] status_b;
always_comb begin
	status_b = 8'd0;
	case (addr[7:0])
		8'h00: status_b = ackseq;
		8'h01: status_b = {6'd0, busy, link_seen};
		8'h02: status_b = {5'd0, err};
		8'h03: status_b = reply_cmd;
		8'h04: status_b = rxlen[7:0];
		8'h05: status_b = {5'd0, rxlen[10:8]};
		8'h06: status_b = boot_state;
		8'h08: status_b = boot_err;
		8'h09: status_b = "F";
		8'h0A: status_b = "N";
		8'h0B: status_b = 8'd1;                       // FN_PROTO_VER
		8'h12: status_b = 8'd3;                       // FN_MODE_APP
		8'h14: status_b = |claim_kind ? claim_kind - 8'd1 : 8'd0;
		8'h15: status_b = {7'd0, link_ever};
		8'h1E: status_b = {7'd0, tv_set ? tv_reg : tv_pal};
		8'h25: status_b = bios_skipped ? 8'd2 : 8'd1;
		8'h26: status_b = {6'd0, hsc_on, hsc_rom};
		default: ;
	endcase
end

wire rd_reply  = addr[15:10] == 6'b0000_10;                // $0800-$0BFF
wire rd_status = addr[15:8] == 8'h0C;
assign bus_oe = app && rw && cs && (rd_reply || rd_status);
assign bus_do = rd_status ? status_b : (rd_in_len ? rx_q : 8'd0);

always_ff @(posedge clk) begin
	start <= 1'b0;
	if (reset) begin
		mb_device <= 8'd0;
		mb_cmd <= 8'd0;
		mb_nparam <= 8'd0;
		txptr <= 9'd0;
		lastseq <= 8'd0;
		tv_set <= 1'b0;
	end else begin
		if (tx_wr && txptr < 9'd320 && !busy)
			txptr <= txptr + 9'd1;
		if (reg_wr && !busy) case (reg_n)
			7'h00: mb_device <= wdata;
			7'h01: mb_cmd <= wdata;
			7'h02: mb_nparam <= wdata;
			7'h05: txptr <= 9'd0;
			7'h10: if (wdata != 8'd0 && wdata != lastseq) begin
				// 0 is reserved and a repeat is a no-op, so a retry never
				// replays a command
				lastseq <= wdata;
				seq <= wdata;
				start <= 1'b1;
			end
			7'h15: begin tv_set <= 1'b1; tv_reg <= wdata[0]; end
			default: ;
		endcase
	end
end

//////////////////////////////  the link  //////////////////////////////////

logic [7:0] u_tx_data;
logic       u_tx_valid, u_tx_ready;
logic [7:0] u_rx_data;
logic       u_rx_valid;

fujinet_uart uart (
	.clk        (clk),
	.reset      (reset || !app),
	.pal        (pal),
	.tx_data    (u_tx_data),
	.tx_valid   (u_tx_valid),
	.tx_ready   (u_tx_ready),
	.txd        (txd),
	.rxd        (rxd),
	.rx_data    (u_rx_data),
	.rx_valid   (u_rx_valid)
);
assign tx_en = app;

// SLIP encoder: the engine offers one byte (raw: an END delimiter) when
// enc_free; an END or ESC in the data goes out as two bytes.
logic       enc_have = 1'b0;
logic [7:0] enc_byte;
logic       enc_second = 1'b0;
logic [7:0] enc_next;
wire        enc_free = !enc_have && !enc_second;
logic       emit;
logic [7:0] emit_byte;
logic       emit_raw;
logic       emit_raw_l = 1'b0;

always_ff @(posedge clk) begin
	if (reset || !app) begin
		enc_have <= 1'b0;
		enc_second <= 1'b0;
	end else begin
		if (u_tx_valid && u_tx_ready) begin
			if (enc_second) begin
				enc_second <= 1'b0;
			end else begin
				enc_have <= 1'b0;
				if (!emit_raw_l && (enc_byte == SLIP_END || enc_byte == SLIP_ESC))
					enc_second <= 1'b1;
			end
		end
		if (emit && enc_free) begin
			enc_have <= 1'b1;
			enc_byte <= emit_byte;
			emit_raw_l <= emit_raw;
			enc_next <= (emit_byte == SLIP_END) ? SLIP_ESC_END : SLIP_ESC_ESC;
		end
	end
end
assign u_tx_valid = enc_have || enc_second;
assign u_tx_data  = enc_second ? enc_next :
                    (!emit_raw_l && (enc_byte == SLIP_END || enc_byte == SLIP_ESC)) ? SLIP_ESC : enc_byte;

/* verilator lint_on PROCASSINIT */

//////////////////////////////  the engine  ////////////////////////////////

typedef enum logic [3:0] {
	E_IDLE, E_P1A, E_P1B, E_CK, E_SEND, E_FETCH, E_WAIT, E_DONE
} estate_t;
/* verilator lint_off PROCASSINIT */
estate_t st = E_IDLE;
/* verilator lint_on PROCASSINIT */

// end-around carry sum, the FujiBus checksum
function automatic [7:0] cks(input [7:0] c, input [7:0] b);
	logic [8:0] t;
	begin
		t = {1'b0, c} + {1'b0, b};
		cks = t[7:0] + {7'd0, t[8]};
	end
endfunction

function automatic [7:0] descr(input [2:0] size, input more);
	descr = {more, 4'd0, size == 3'd1 ? 3'd1 : size == 3'd2 ? 3'd5 : 3'd7};
endfunction

// The TX stream's walk: param i, its value bytes left k, payload after
logic [8:0] p;
logic [3:0] pi;            // params seen
logic [2:0] pk;
logic       pval;          // in a value
logic [3:0] np;            // NPARAM, at most 8
logic [2:0] psize [0:7];
logic [3:0] cnt;           // params parsed
logic [7:0] sum;
logic [15:0] plen;
logic [4:0] step;
logic [3:0] j;
logic       bare;          // a bare ACK / NAK to device $FF
logic [7:0] s_dev, s_cmd;
logic       fw;            // waiting for tx_q to follow tx_raddr

// Timeout
logic [13:0] ms_pre;
logic [16:0] ms;
logic [16:0] ms_lim;

// Reply parser
logic        hunting, esc;
logic [11:0] pos, raw_cnt;
logic [7:0]  rsum, r_dev, r_cmd, r_ck, r_d0;
logic [15:0] r_len;
logic [1:0]  dstate;       // 0 header, 1 descriptors, 2 fields, 3 data
logic [4:0]  ndescr;
logic [7:0]  skip;
logic [10:0] dptr;
logic        rbad, rx_any;
logic        rx_byte;      // a decoded byte this clock
logic [7:0]  rb;

function automatic [3:0] fbytes(input [2:0] d);   // count * size, fujibus.c's tables
	case (d)
		3'd0: fbytes = 4'd0;
		3'd1: fbytes = 4'd1;
		3'd2: fbytes = 4'd2;
		3'd3: fbytes = 4'd3;
		3'd4: fbytes = 4'd4;
		3'd5: fbytes = 4'd2;
		3'd6: fbytes = 4'd4;
		default: fbytes = 4'd4;
	endcase
endfunction

wire slow_cmd = (mb_cmd == 8'hF8 || mb_cmd == 8'hD8);
wire net_cmd  = (mb_device >= 8'h71 && mb_device <= 8'h78) &&
                (mb_cmd == 8'h4F || mb_cmd == 8'h43 || mb_cmd == 8'h53 || mb_cmd == 8'h52);

assign busy = st != E_IDLE;

always_comb begin
	emit = 1'b0;
	emit_byte = 8'd0;
	emit_raw = 1'b0;
	if (st == E_SEND) begin
		emit = 1'b1;
		case (step)
			5'd0, 5'd9: begin emit_byte = SLIP_END; emit_raw = 1'b1; end
			5'd1: emit_byte = s_dev;
			5'd2: emit_byte = s_cmd;
			5'd3: emit_byte = plen[7:0];
			5'd4: emit_byte = plen[15:8];
			5'd5: emit_byte = sum;
			5'd6: emit_byte = (!bare && cnt != 4'd0) ? descr(psize[0], cnt > 4'd1) : 8'd0;
			5'd7: emit_byte = descr(psize[j[2:0]], j + 4'd1 < cnt);
			5'd8: emit_byte = tx_q;
			default: emit = 1'b0;
		endcase
	end
end

always_ff @(posedge clk) begin
	rx_we <= 1'b0;
	if (reset || !app) begin
		st <= E_IDLE;
		ackseq <= 8'd0;
		err <= ERR_OK;
		reply_cmd <= 8'd0;
		rxlen <= 11'd0;
		boot_state <= 8'd0;
		boot_err <= 8'd0;
		if (reset) begin
			link_seen <= 1'b0;
			link_ever <= 1'b0;
		end
	end else case (st)
	E_IDLE: if (start) begin
		p <= 9'd0;
		pi <= 4'd0;
		pval <= 1'b0;
		np <= mb_nparam > 8'd8 ? 4'd8 : mb_nparam[3:0];
		sum <= 8'd0;
		bare <= 1'b0;
		s_dev <= mb_device;
		s_cmd <= mb_cmd;
		if (mb_cmd == 8'hF8) begin    // a MOUNT_IMAGE: an earlier verdict must not read as this one's
			boot_state <= 8'd0;
			boot_err <= 8'd0;
		end
		st <= E_P1A;
	end

	// Pass 1: check the TX stream, count its params, sum its bytes
	E_P1A: begin
		if (p == txptr) begin
			if (pval || pi != np) begin
				err <= ERR_BADFRAME;
				st <= E_DONE;
			end else begin
				cnt <= pi;
				j <= 4'd0;
				st <= E_CK;
			end
		end else begin
			tx_raddr <= p;
			fw <= 1'b1;
			st <= E_P1B;
		end
	end
	E_P1B: if (fw)
		fw <= 1'b0;
	else begin
		// tx_q is txbuf[p]
		st <= E_P1A;
		p <= p + 9'd1;
		if (!pval && pi < np) begin
			if (tx_q != 8'd1 && tx_q != 8'd2 && tx_q != 8'd4) begin
				err <= ERR_BADFRAME;
				st <= E_DONE;
			end else begin
				psize[pi[2:0]] <= tx_q[2:0];
				pk <= tx_q[2:0];
				pval <= 1'b1;
			end
		end else begin
			sum <= cks(sum, tx_q);
			if (pval) begin
				pk <= pk - 3'd1;
				if (pk == 3'd1) begin
					pval <= 1'b0;
					pi <= pi + 4'd1;
				end
			end
		end
	end

	// The rest of the checksum: the descriptors, then device, command, length
	E_CK: begin
		j <= j + 4'd1;
		if (j < cnt)
			sum <= cks(sum, descr(psize[j[2:0]], j + 4'd1 < cnt));
		else case (j - cnt)
			4'd0: begin
				plen <= {7'd0, txptr} + 16'd6 - ((cnt != 4'd0) ? 16'd1 : 16'd0);
				sum <= cks(sum, s_dev);
			end
			4'd1: sum <= cks(sum, s_cmd);
			4'd2: sum <= cks(sum, plen[7:0]);
			4'd3: begin
				sum <= cks(sum, plen[15:8]);
				step <= 5'd0;
				st <= E_SEND;
			end
			default: ;
		endcase
	end

	// Pass 2: the frame, through the SLIP encoder. Steps: 0 END, 1-5 the
	// header, 6 the first descriptor, 7 the others, 8 a TX stream byte, 9 END.
	E_SEND: if (enc_free) begin
		case (step)
			5'd6, 5'd7: begin
				j <= (step == 5'd6) ? 4'd1 : j + 4'd1;
				if (!bare && ((step == 5'd6) ? cnt > 4'd1 : j + 4'd1 < cnt))
					step <= 5'd7;
				else if (!bare && txptr != 9'd0) begin
					step <= 5'd8;
					p <= 9'd0;
					pi <= 4'd0;
					pval <= 1'b0;
					tx_raddr <= 9'd0;
					fw <= 1'b1;
					st <= E_FETCH;
				end else
					step <= 5'd9;
			end
			5'd8: begin
				p <= p + 9'd1;
				tx_raddr <= p + 9'd1;
				fw <= 1'b1;
				st <= E_FETCH;
			end
			5'd9: begin
				// sent: wait for the reply
				hunting <= 1'b1;
				esc <= 1'b0;
				raw_cnt <= 12'd0;
				if (!bare) rx_any <= 1'b0;
				ms_pre <= 14'd0;
				ms <= 17'd0;
				if (!bare)
					ms_lim <= slow_cmd ? 17'd60000 : net_cmd ? 17'd90000 :
					          link_seen ? 17'd5000 : 17'd1500;
				st <= E_WAIT;
			end
			default: step <= step + 5'd1;
		endcase
	end

	// The next TX stream byte: size bytes are skipped, the rest go out
	E_FETCH: if (fw)
		fw <= 1'b0;
	else if (p == txptr) begin
		step <= 5'd9;
		st <= E_SEND;
	end else if (!pval && pi < cnt) begin
		pk <= tx_q[2:0];
		pval <= 1'b1;
		p <= p + 9'd1;
		tx_raddr <= p + 9'd1;
		fw <= 1'b1;
	end else begin
		if (pval) begin
			pk <= pk - 3'd1;
			if (pk == 3'd1) begin
				pval <= 1'b0;
				pi <= pi + 4'd1;
			end
		end
		st <= E_SEND;          // step 8: tx_q goes out
	end

	E_WAIT: begin
		// the time limit, in ms
		if (ms_pre == 14'(MS_DIV - 1)) begin
			ms_pre <= 14'd0;
			ms <= ms + 17'd1;
		end else
			ms_pre <= ms_pre + 14'd1;
		if (ms >= ms_lim) begin
			err <= (rx_any || link_seen) ? ERR_TIMEOUT : ERR_NOLINK;
			if (!rx_any) link_seen <= 1'b0;
			st <= E_DONE;
		end

		if (u_rx_valid) begin
			rx_any <= 1'b1;
			raw_cnt <= raw_cnt + 12'd1;
			if (raw_cnt >= 12'd2061) begin
				err <= ERR_TOOBIG;
				st <= E_DONE;
			end
			if (u_rx_data == SLIP_END) begin
				if (hunting) begin
					hunting <= 1'b0;
					pos <= 12'd0;
				end else if (pos != 12'd0) begin
					// a whole frame
					pos <= 12'd0;
					if (pos < 12'd6 || r_len != {4'd0, pos} || r_ck != rsum || rbad || dstate != 2'd3) begin
						err <= ERR_BADFRAME;
						st <= E_DONE;
					end else if (r_dev == 8'hFF && (r_cmd == 8'h4F || r_cmd == 8'h57 || r_cmd == 8'h43)) begin
						// the FujiNet pushing an image (MOUNT_IMAGE): refused at
						// its OPEN, as a cart with no room for it; the others
						// are ACKed. The wait starts again, as fujibus_usb.c's.
						if (r_cmd == 8'h4F) begin
							boot_state <= 8'h80;   // FN_BOOT_FAILED
							boot_err <= 8'd3;      // FN_BOOT_ERR_NOMAP
						end
						if (r_cmd == 8'h43 && dptr != 11'd0 && r_d0 == 8'h01) begin
							boot_state <= 8'h80;
							boot_err <= 8'd2;      // FN_BOOT_ERR_TRUNCATED
						end
						link_seen <= 1'b1;
						link_ever <= 1'b1;
						bare <= 1'b1;
						s_dev <= 8'hFF;
						s_cmd <= (r_cmd == 8'h4F) ? 8'h15 : 8'h06;
						plen <= 16'd6;
						sum <= cks(cks(8'hFF, (r_cmd == 8'h4F) ? 8'h15 : 8'h06), 8'h06);
						step <= 5'd0;
						st <= E_SEND;
					end else begin
						reply_cmd <= r_cmd;
						rxlen <= dptr > 11'd1024 ? 11'd1024 : dptr;
						err <= ERR_OK;
						link_seen <= 1'b1;
						link_ever <= 1'b1;
						st <= E_DONE;
					end
				end
				esc <= 1'b0;
				rsum <= 8'd0;
				dstate <= 2'd0;
				ndescr <= 5'd0;
				skip <= 8'd0;
				dptr <= 11'd0;
				rbad <= 1'b0;
			end else if (!hunting) begin
				if (esc) begin
					esc <= 1'b0;
				end else if (u_rx_data == SLIP_ESC)
					esc <= 1'b1;
			end
		end

		// one decoded byte
		if (rx_byte) begin
			pos <= pos + 12'd1;
			if (pos != 12'd4)
				rsum <= cks(rsum, rb);
			case (pos)
				12'd0: r_dev <= rb;
				12'd1: r_cmd <= rb;
				12'd2: r_len[7:0] <= rb;
				12'd3: r_len[15:8] <= rb;
				12'd4: r_ck <= rb;
				default: ;
			endcase
			if (pos == 12'd5 || dstate == 2'd1) begin
				ndescr <= ndescr + 5'd1;
				if (ndescr == 5'd16) rbad <= 1'b1;
				if (rb[7])
					dstate <= 2'd1;
				else if (skip + {4'd0, fbytes(rb[2:0])} != 8'd0)
					dstate <= 2'd2;
				else
					dstate <= 2'd3;
				skip <= skip + {4'd0, fbytes(rb[2:0])};
			end else if (dstate == 2'd2) begin
				skip <= skip - 8'd1;
				if (skip == 8'd1) dstate <= 2'd3;
			end else if (dstate == 2'd3) begin
				if (dptr == 11'd0) r_d0 <= rb;
				if (dptr < 11'd1024) begin
					rx_we <= 1'b1;
					rx_waddr <= dptr[9:0];
					rx_wdata <= rb;
				end
				dptr <= dptr + 11'd1;
			end
		end
	end

	E_DONE: begin
		if (err != ERR_OK) begin
			reply_cmd <= 8'd0;
			rxlen <= 11'd0;
		end
		// last: the interlock (the client sees the echo only once all is in place)
		ackseq <= seq;
		st <= E_IDLE;
	end

	default: st <= E_IDLE;
	endcase
end

// The decoded byte stream, ahead of the parser above
always_comb begin
	rx_byte = 1'b0;
	rb = u_rx_data;
	if (st == E_WAIT && u_rx_valid && !hunting && u_rx_data != SLIP_END) begin
		if (esc) begin
			// a malformed escape is dropped, as the ESP32 does
			rx_byte = u_rx_data == SLIP_ESC_END || u_rx_data == SLIP_ESC_ESC;
			rb = (u_rx_data == SLIP_ESC_END) ? SLIP_END : SLIP_ESC;
		end else
			rx_byte = u_rx_data != SLIP_ESC;
	end
end

endmodule
