// FujiNet cartridge mailbox for the 7800, with its FujiBus link on the
// Pocket's link port or cartridge slot.
//
// A FujiNet program talks to its cartridge through a mailbox below $1000
// (fujinet-firmware pico/atari-7800/firmware/include/fuji_mailbox.h; the
// FujiNet 7800 programmer's handbook, section 19). The cartridge passes each
// request to a FujiNet device as one FujiBus packet, a SLIP frame at 115,200
// baud (lib/bus/rs232 on the ESP32; pico/common/src/fujibus.c is the
// reference this follows byte for byte), and shows the reply in the mailbox.
// Here the core is the cartridge, and the serial line is on the link port
// (TX on SO, pin 2; RX on SI, pin 3) or in the cartridge slot (TX on pin 5,
// GBA /CS; RX on pin 31, GBA /REQ), whichever answers ("Two ports", below).
//
// The mailbox is live only for an image that claims it ("FUJI" at $FF70,
// APP mode); fujinet_claim in atari7800_pocket.sv finds the claim while the
// image loads. Then:
//
//   $0800-$0BFF  reply, read in place; bytes past RXLEN read 0
//   $0C00-$0CFF  status page (FN_R_*)
//   $0D00-$0D7F  write V to $0D00+n: register n = V (FN_REG_*)
//   $0F00-$0FFF  write: append the byte to the TX stream (320 bytes at most)
//   $0C30        (this core's own) the port in use: 0 none yet, 1 link, 2 cartridge
//
// A transaction: DEVICE, CMD, NPARAM, DATA_RST, the TX stream (NPARAM x
// {size 1|2|4, value little endian}, then payload), then SEQ = ACKSEQ + 1.
// When ACKSEQ echoes SEQ, ERR, REPLY_CMD, RXLEN and the reply are in place.
//
// MOUNT_IMAGE's image push (docs/FUJINET_GAME_LOADING.md): the frames to
// device $FF are answered here, the bytes go to the stager (stg_*:
// fujinet_stage.sv, into the PSRAM), and the loader at $0600 ends in the hot
// swap ($0DFE), which fujinet_loader.sv carries out. What the RP2354B
// cartridge does and this does not: the High Score Cart's SD saves
// (FN_REG_HSC is ignored), and the hot operations at $0D80-$0DFF other than
// the swap.
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
	output logic        txd,          // sent on both ports (see "Two ports")
	output logic        tx_en,        // drive TX (APP mode only)
	input  logic        rxd_link,     // link port SI
	input  logic        rxd_cart,     // cartridge pin 31
	output logic        busy,

	// The stager (docs/FUJINET_GAME_LOADING.md, 3.2): a MOUNT_IMAGE's pushed
	// image, a byte at a time at its file offset; stg_sync asks for every
	// byte so far to be stored, stg_synced (a pulse) says they are
	output logic        stg_start,
	output logic        stg_we,
	output logic [19:0] stg_addr,
	output logic  [7:0] stg_data,
	output logic        stg_sync,
	input  logic        stg_synced,
	input  logic        stg_busy,     // hold the next byte
	output logic [19:0] stg_size,     // the staged file's bytes, once READY
	output logic        stg_ready,
	output logic        stg_hdr,      // it starts with an A78 header ("ATARI" at bytes 1-5)

	// The loader at $0600 wrote the hot swap ($0DFE): start the staged image
	// (armed: READY and BOOTLOCK), or else restart this one
	output logic        swap_go,
	output logic        swap_restart
);

localparam [7:0] SLIP_END = 8'hC0, SLIP_ESC = 8'hDB, SLIP_ESC_END = 8'hDC, SLIP_ESC_ESC = 8'hDD;
localparam [2:0] ERR_OK = 3'd0, ERR_NOLINK = 3'd1, ERR_TIMEOUT = 3'd2, ERR_BADFRAME = 3'd3, ERR_TOOBIG = 3'd4;

//////////////////////////////  bus side  /////////////////////////////////

// Power-up values here, a new image's values in the reset branches
/* verilator lint_off PROCASSINIT */

wire wr_cyc = app && phi2 && !rw && cs;
wire reg_wr = wr_cyc && addr[15:7] == 9'b0000_1101_0;      // $0D00-$0D7F
wire tx_wr  = wr_cyc && addr[15:8] == 8'h0F;               // $0F00-$0FFF
wire hot_wr = wr_cyc && addr[15:7] == 9'b0000_1101_1;      // $0D80-$0DFF, one-shot operations
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
logic       bootlock_w = 1'b0, hotswap_w = 1'b0;     // pulses to the engine
// The push (3.1)
logic  [7:0] boot_pct = 8'd0;
logic [19:0] got = 20'd0, tot = 20'd0;
logic  [7:0] staged = 8'd0;

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
		8'h07: status_b = boot_pct;
		8'h08: status_b = boot_err;
		8'h09: status_b = "F";
		8'h0A: status_b = "N";
		8'h0B: status_b = 8'd1;                       // FN_PROTO_VER
		8'h12: status_b = 8'd3;                       // FN_MODE_APP
		8'h14: status_b = |claim_kind ? claim_kind - 8'd1 : 8'd0;
		8'h15: status_b = {7'd0, link_ever};
		8'h16: status_b = got[7:0];                   // FN_R_BOOT_GOT0, 24-bit LE
		8'h17: status_b = got[15:8];
		8'h18: status_b = {4'd0, got[19:16]};
		8'h19: status_b = tot[7:0];                   // FN_R_BOOT_TOT0
		8'h1A: status_b = tot[15:8];
		8'h1B: status_b = {4'd0, tot[19:16]};
		8'h1F: status_b = staged;                     // FN_R_STAGED
		8'h1E: status_b = {7'd0, tv_set ? tv_reg : tv_pal};
		8'h25: status_b = bios_skipped ? 8'd2 : 8'd1;
		8'h26: status_b = {6'd0, hsc_on, hsc_rom};
		8'h30: status_b = {6'd0, lock_cart, lock_link};   // Pocket: the port in use (1 link, 2 cartridge)
		default: ;
	endcase
end

// The loader (3.3), $0600-$060B:
//   $0600 JMP $0606 (FN_LOADER_BOOT), $0603 JMP ($FFFC) (FN_LOADER_CONFIG:
//   no CONFIG here, so this program again), $0606 STA $0DFE (the hot swap),
//   $0609 JMP $0609 (the core takes the console from there)
logic [7:0] loader_b;
always_comb begin
	case (addr[3:0])
		4'h0: loader_b = 8'h4C; 4'h1: loader_b = 8'h06; 4'h2: loader_b = 8'h06;
		4'h3: loader_b = 8'h6C; 4'h4: loader_b = 8'hFC; 4'h5: loader_b = 8'hFF;
		4'h6: loader_b = 8'h8D; 4'h7: loader_b = 8'hFE; 4'h8: loader_b = 8'h0D;
		4'h9: loader_b = 8'h4C; 4'hA: loader_b = 8'h09; 4'hB: loader_b = 8'h06;
		default: loader_b = 8'h00;
	endcase
end

// The bus side is registers, a clock behind the address, as the reply
// buffer's rx_q always was (and as the BIOS's block RAM is): the CPU, and
// MARIA, take a cartridge byte at the bus cycle's closing enable, several
// clk_sys later. Decoding the address combinationally into bus_oe and
// bus_do put the mailbox's whole decode in front of top.sv's read_DB, and
// the fitter then retimed the CPU's address registers through read_DB's
// mux onto the cart RAM's request into the SRAM, which step 7's check (g)
// forbids (docs/FUJINET_GAME_LOADING.md, 4).
wire rd_reply  = addr[15:10] == 6'b0000_10;                // $0800-$0BFF
wire rd_status = addr[15:8] == 8'h0C;
wire rd_loader = addr[15:4] == 12'h060 && addr[3:0] < 4'hC;
logic       oe_q = 1'b0, rx_sel = 1'b0;
logic [7:0] do_q = 8'd0;
always_ff @(posedge clk) begin
	oe_q   <= app && rw && cs && (rd_reply || rd_status || rd_loader);
	rx_sel <= !rd_status && !rd_loader;
	do_q   <= rd_status ? status_b : rd_loader ? loader_b : 8'd0;
end
assign bus_oe = oe_q;
assign bus_do = rx_sel ? (rd_in_len ? rx_q : 8'd0) : do_q;

always_ff @(posedge clk) begin
	start <= 1'b0;
	bootlock_w <= reg_wr && reg_n == 7'h11 && wdata == 8'hB5;   // FN_REG_BOOTLOCK = FN_BOOTLOCK_MAGIC
	hotswap_w <= hot_wr && addr[6:0] == 7'h7E;                 // FN_HOT_SWAP ($0DFE)
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

// Two ports: the FujiNet can be on the link port (TX on SO, RX on SI) or in
// the cartridge slot (TX on pin 5, RX on pin 31). The core sends on both and
// listens to the ones that are alive: a line is alive once it has idled
// high for 1 ms (something drives it, as a UART's TX idles high) and dead
// again after 2 ms low (unplugged), so an undriven pin is never heard. The
// alive lines are ANDed. A good frame locks the port its last byte came in
// on (the one with the latest falling edge); a request that hears nothing
// at all (the link dropped) unlocks it.
logic [1:0]  rs_l = 2'b11, rs_c = 2'b11;
wire         r_l = rs_l[1], r_c = rs_c[1];
logic [15:0] run_l = 16'd0, run_c = 16'd0;   // clocks at the current level
logic        alive_l = 1'b0, alive_c = 1'b0;
logic        lock_link = 1'b0, lock_cart = 1'b0;
logic        last_cart = 1'b0;      // the latest falling edge was the cartridge's
localparam [15:0] T_ALIVE = 16'(MS_DIV), T_DEAD = 16'(2 * MS_DIV < 65535 ? 2 * MS_DIV : 65535);
wire         rxd_m = lock_link ? r_l : lock_cart ? r_c :
                     ((r_l | !alive_l) & (r_c | !alive_c));
always_ff @(posedge clk) begin
	rs_l <= {rs_l[0], rxd_link};
	rs_c <= {rs_c[0], rxd_cart};
	run_l <= (rs_l[0] != r_l) ? 16'd0 : (run_l == 16'hFFFF ? run_l : run_l + 16'd1);
	run_c <= (rs_c[0] != r_c) ? 16'd0 : (run_c == 16'hFFFF ? run_c : run_c + 16'd1);
	if (r_l && run_l >= T_ALIVE) alive_l <= 1'b1;
	if (!r_l && run_l >= T_DEAD) alive_l <= 1'b0;
	if (r_c && run_c >= T_ALIVE) alive_c <= 1'b1;
	if (!r_c && run_c >= T_DEAD) alive_c <= 1'b0;
	if (rs_l[1] && !rs_l[0]) last_cart <= 1'b0;
	if (rs_c[1] && !rs_c[0]) last_cart <= 1'b1;
end


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
	.rxd        (rxd_m),
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
	E_IDLE, E_P1A, E_P1B, E_CK, E_SEND, E_FETCH, E_WAIT, E_DONE,
	E_DBC, E_COPY, E_SYNC, E_BARE
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
logic [7:0]  rsum, r_dev, r_cmd, r_ck, r_d0, r_d1, r_d2, r_d3, r_d4;
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

// The push: a device $FF frame's data is kept here, apart from the reply
// window, and copied to the stager once the frame has proved good
logic [7:0]  sbuf [0:511];
logic        sb_we;
logic [8:0]  sb_wa, sb_ra;
logic [7:0]  sb_wd, sb_q;
always_ff @(posedge clk) begin
	if (sb_we) sbuf[sb_wa] <= sb_wd;
	sb_q <= sbuf[sb_ra];
end
localparam [19:0] STG_MAX = 20'd524416;      // 512 KiB of ROM and a 128-byte header
logic        stg_open, bare_nak, armed;
logic [7:0]  dbc_cmd;
logic [9:0]  cn, ci;                          // bytes to copy, copied
logic [1:0]  cw;                              // the copy's pacing
logic [19:0] pct_acc;
logic [15:0] sync_t;
// The FUJI claim in the pushed image: bytes $F70-$F75 of each 4K block of
// the ROM (past the header), the last block's counting (as fujinet_claim)
logic        h_ok;                            // bytes 1 to got-1 (up to 5) read "ATARI" so far
logic [7:0]  csig [0:5];
logic        c_ok;
logic [7:0]  c_end;                           // that block's end, in 4K blocks
wire         hdr = h_ok && got > 20'd5;               // the image has an A78 header
wire  [19:0] po = got - (hdr ? 20'd128 : 20'd0);       // the byte's offset in the ROM

wire slow_cmd = (mb_cmd == 8'hF8 || mb_cmd == 8'hD8);
wire net_cmd  = (mb_device >= 8'h71 && mb_device <= 8'h78) &&
                (mb_cmd == 8'h4F || mb_cmd == 8'h43 || mb_cmd == 8'h53 || mb_cmd == 8'h52);

assign busy = st != E_IDLE;
assign stg_size = tot;
assign stg_ready = boot_state == 8'd2;
assign stg_hdr = hdr;
wire rx_act = st == E_SEND || st == E_FETCH || st == E_WAIT;
wire frame_end = u_rx_valid && u_rx_data == SLIP_END && !hunting && pos != 12'd0;

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
	sb_we <= 1'b0;
	stg_start <= 1'b0;
	stg_we <= 1'b0;
	stg_sync <= 1'b0;
	swap_go <= 1'b0;
	swap_restart <= 1'b0;
	// BOOTLOCK arms the swap only on a READY image; the hot swap starts it,
	// or else restarts this program
	if (bootlock_w && boot_state == 8'd2) armed <= 1'b1;
	if (hotswap_w) begin
		swap_go <= armed;
		swap_restart <= !armed;
	end
	if (reset || !app) begin
		st <= E_IDLE;
		ackseq <= 8'd0;
		err <= ERR_OK;
		reply_cmd <= 8'd0;
		rxlen <= 11'd0;
		boot_state <= 8'd0;
		boot_err <= 8'd0;
		boot_pct <= 8'd0;
		got <= 20'd0;
		tot <= 20'd0;
		staged <= 8'd0;
		stg_open <= 1'b0;
		armed <= 1'b0;
		if (reset) begin
			link_seen <= 1'b0;
			link_ever <= 1'b0;
			lock_link <= 1'b0;
			lock_cart <= 1'b0;
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
			boot_pct <= 8'd0;
			got <= 20'd0;
			tot <= 20'd0;
			staged <= 8'd0;
			stg_open <= 1'b0;
			armed <= 1'b0;
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
				hunting <= 1'b1;
				esc <= 1'b0;
				raw_cnt <= 12'd0;
				rx_any <= 1'b0;
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
				if (bare) raw_cnt <= 12'd0;
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
			if (!rx_any) begin
				link_seen <= 1'b0;
				lock_link <= 1'b0;
				lock_cart <= 1'b0;
			end
			st <= E_DONE;
		end

		if (u_rx_valid && raw_cnt >= 12'd2061) begin
			err <= ERR_TOOBIG;
			st <= E_DONE;
		end
		if (frame_end) begin
			// a whole frame
			if (pos < 12'd6 || r_len != {4'd0, pos} || r_ck != rsum || rbad || dstate != 2'd3) begin
				err <= ERR_BADFRAME;
				st <= E_DONE;
			end else if (r_dev == 8'hFF && (r_cmd == 8'h4F || r_cmd == 8'h57 || r_cmd == 8'h43)) begin
				// the FujiNet pushing an image (MOUNT_IMAGE): handled in
				// E_DBC, answered with a bare ACK or NAK; the wait then starts
				// again, as fujibus_usb.c's
				link_seen <= 1'b1;
				link_ever <= 1'b1;
				if (!lock_link && !lock_cart) begin
					lock_link <= !last_cart;
					lock_cart <= last_cart;
				end
				dbc_cmd <= r_cmd;
				cn <= dptr > 11'd512 ? 10'd512 : dptr[9:0];
				st <= E_DBC;
			end else begin
				reply_cmd <= r_cmd;
				rxlen <= dptr > 11'd1024 ? 11'd1024 : dptr;
				err <= ERR_OK;
				link_seen <= 1'b1;
				link_ever <= 1'b1;
				if (!lock_link && !lock_cart) begin
					lock_link <= !last_cart;
					lock_cart <= last_cart;
				end
				st <= E_DONE;
			end
		end
	end

	// A push frame (3.1)
	E_DBC: begin
		bare_nak <= 1'b0;
		st <= E_BARE;
		case (dbc_cmd)
			8'h4F: if (r_d0 == 8'd0) begin          // OPEN, the image
				if ({r_d4, r_d3, r_d2, r_d1} == 32'd0 || {r_d4, r_d3, r_d2, r_d1} > {12'd0, STG_MAX}) begin
					bare_nak <= 1'b1;
					boot_state <= 8'h80;            // FN_BOOT_FAILED
					boot_err <= 8'd1;               // FN_BOOT_ERR_TOOBIG
					stg_open <= 1'b0;
				end else begin
					tot <= {r_d3[3:0], r_d2, r_d1};
					got <= 20'd0;
					boot_pct <= 8'd0;
					pct_acc <= 20'd0;
					boot_state <= 8'd1;             // FN_BOOT_XFER
					boot_err <= 8'd0;
					staged <= 8'd0;
					armed <= 1'b0;
					h_ok <= 1'b0;
					c_ok <= 1'b0;
					c_end <= 8'd0;
					stg_open <= 1'b1;
					stg_start <= 1'b1;
				end
			end                                     // OPEN, the .cfg: ACKed and ignored
			8'h57: if (stg_open && cn != 10'd0) begin   // WRITE
				ci <= 10'd0;
				cw <= 2'd0;
				sb_ra <= 9'd0;
				st <= E_COPY;
			end
			default: begin                          // CLOSE
				if (stg_open) begin
					stg_open <= 1'b0;
					if ((cn != 10'd0 && r_d0 == 8'h01) || got != tot) begin
						boot_state <= 8'h80;
						boot_err <= 8'd2;           // FN_BOOT_ERR_TRUNCATED
					end else begin
						stg_sync <= 1'b1;
						sync_t <= 16'd0;
						st <= E_SYNC;
					end
				end
			end
		endcase
	end

	// The frame's data to the stager, a byte every 4 clocks
	E_COPY: begin
		// sb_q follows sb_ra a clock later: byte ci is there from cw 1; a
		// busy stager holds it at cw 3
		if (!(cw == 2'd3 && stg_busy)) cw <= cw + 2'd1;
		if (cw == 2'd3 && !stg_busy) begin
			sb_ra <= ci[8:0] + 9'd1;
			if (got < tot) begin
				stg_we <= 1'b1;
				stg_addr <= got;
				stg_data <= sb_q;
				got <= got + 20'd1;
				if (pct_acc + 20'd100 >= tot) begin
					pct_acc <= pct_acc + 20'd100 - tot;
					if (boot_pct < 8'd100) boot_pct <= boot_pct + 8'd1;
				end else
					pct_acc <= pct_acc + 20'd100;
				// "ATARI" at bytes 1-5: an A78 header
				if (got >= 20'd1 && got <= 20'd5)
					h_ok <= (got == 20'd1 || h_ok) && sb_q ==
					         (got == 20'd1 ? "A" : got == 20'd2 ? "T" : got == 20'd3 ? "A" : got == 20'd4 ? "R" : "I");
				if (!(hdr && got < 20'd128)) begin
					if (po[11:0] >= 12'hF70 && po[11:0] <= 12'hF75)
						csig[po[2:0]] <= sb_q;
					if (po[11:0] == 12'hF76) begin
						c_ok <= {csig[0], csig[1], csig[2], csig[3]} == "FUJI";
						c_end <= po[19:12] + 8'd1;
					end
				end
			end
			ci <= ci + 10'd1;
			if (ci + 10'd1 == cn) st <= E_BARE;
		end
	end

	// The last byte stored: the image is READY
	E_SYNC: begin
		sync_t <= sync_t + 16'd1;
		if (stg_synced) begin
			boot_state <= 8'd2;                     // FN_BOOT_READY
			boot_pct <= 8'd100;
			// READY, the claim (its last 4K block ends where the ROM does),
			// BIOS OK (the core boots any image)
			staged <= {5'd0, 1'b1,
			           c_ok && {c_end, 12'h000} == (tot - (hdr ? 20'd128 : 20'd0)), 1'b1};
			st <= E_BARE;
		end else if (sync_t == 16'hFFFF) begin
			boot_state <= 8'h80;
			boot_err <= 8'd4;                       // FN_BOOT_ERR_STOREBUSY
			st <= E_BARE;
		end
	end

	E_BARE: begin
		bare <= 1'b1;
		s_dev <= 8'hFF;
		s_cmd <= bare_nak ? 8'h15 : 8'h06;
		plen <= 16'd6;
		sum <= cks(cks(8'hFF, bare_nak ? 8'h15 : 8'h06), 8'h06);
		step <= 5'd0;
		st <= E_SEND;
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

	// The receiver runs from the start of a request's frame, so a reply that
	// starts early is not lost, and a wire from SO to SI (loopback) brings the
	// cart's own frame back as a good frame. Only E_WAIT acts on a frame.
	if (rx_act) begin
		if (u_rx_valid) begin
			rx_any <= 1'b1;
			raw_cnt <= raw_cnt + 12'd1;
			if (u_rx_data == SLIP_END) begin
				hunting <= 1'b0;       // a frame's start; at its end E_WAIT above takes it
				pos <= 12'd0;
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
				case (dptr)
					11'd0: r_d0 <= rb;
					11'd1: r_d1 <= rb;
					11'd2: r_d2 <= rb;
					11'd3: r_d3 <= rb;
					11'd4: r_d4 <= rb;
					default: ;
				endcase
				if (r_dev == 8'hFF) begin
					// a push frame: the stage buffer, not the reply window
					if (dptr < 11'd512) begin
						sb_we <= 1'b1;
						sb_wa <= dptr[8:0];
						sb_wd <= rb;
					end
				end else if (dptr < 11'd1024) begin
					rx_we <= 1'b1;
					rx_waddr <= dptr[9:0];
					rx_wdata <= rb;
				end
				dptr <= dptr + 11'd1;
			end
		end
	end
end

// The decoded byte stream, ahead of the parser above
always_comb begin
	rx_byte = 1'b0;
	rb = u_rx_data;
	if (rx_act && u_rx_valid && !hunting && u_rx_data != SLIP_END) begin
		if (esc) begin
			// a malformed escape is dropped, as the ESP32 does
			rx_byte = u_rx_data == SLIP_ESC_END || u_rx_data == SLIP_ESC_ESC;
			rb = (u_rx_data == SLIP_ESC_END) ? SLIP_END : SLIP_ESC;
		end else
			rx_byte = u_rx_data != SLIP_ESC;
	end
end

endmodule
