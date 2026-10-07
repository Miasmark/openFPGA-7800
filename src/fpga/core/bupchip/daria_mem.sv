//------------------------------------------------------------------------------
// DARIA's memories (docs/DARIA_CORE.md, "The memory system", 1 and 2): the
// image window, the cart RAM, the front-end ROM and the state RAM, beside
// ARIA's firmware ROM (which stays in bupchip_pocket.sv).
//
//   window      WIN_KB / 32 RAMs of 8,192 x 32, rounded up: the image's
//               first WIN_KB (64 KB by the owner's decision 8: 2 RAMs, 64
//               M10K; other sizes up to 128 KB for test builds). Port A (clk_arm) fetches at rom_addr; port B
//               (clk_arm) serves the CPU's data reads at d_addr, or, while
//               img_ready is low, takes the receiver's image writes
//               (bup_asset_wr.sv) with their byte lanes; writes beyond the
//               window go nowhere (the PSRAM has the whole image). All the
//               RAMs read every clock, and a mux on the registered address bits
//               [14:13] picks one: no read-enable decode sits between rom_addr
//               and the slices (step 3, "Two more levers").
//   cart RAM    8,192 x 32 with byte lanes (32 KB, 32 M10K): port A (clk_arm)
//               the CPU's in both profiles (the BupChip sees the low 16 KB),
//               port B (clk_sys) the front ends'.
//   front-end   8,192 x 32 (32 KB, 32 M10K), clk_sys: the image's first 32 KB
//   ROM         for the 6507 side. Port A takes the cartridge's bytes as the
//               loader delivers them (cap_we, a byte lane each), and otherwise
//               reads for the front ends; port B reads.
//   state RAM   256 x 32 (2 M10K), port A clk_arm (the call port), port B
//               clk_sys (the front ends' fetchers, counters and call block).
//
// Every RAM is daria_ram below: true dual-port, a clock per port, byte
// enables, maximum_depth 8,192 so Quartus slices it 8K x 1 and needs no output
// decoder of its own. Mixed-port reads of a word written in the same clock are
// undefined on the device; the users order such accesses by toggles.
//
// SPDX-License-Identifier: MIT
//------------------------------------------------------------------------------

`default_nettype none

module daria_ram #(
	parameter int AW = 13,
	parameter int DW = 32,
	parameter int MAX_DEPTH = 8192
) (
	input  wire              clk_a,
	input  wire     [AW-1:0] addr_a,
	input  wire              we_a,
	input  wire   [DW/8-1:0] be_a,
	input  wire     [DW-1:0] wd_a,
	output wire     [DW-1:0] q_a,
	input  wire              clk_b,
	input  wire     [AW-1:0] addr_b,
	input  wire              we_b,
	input  wire   [DW/8-1:0] be_b,
	input  wire     [DW-1:0] wd_b,
	output wire     [DW-1:0] q_b
);
	localparam int WORDS = 1 << AW;
	localparam int NB = DW / 8;

`ifdef ALTERA_RESERVED_QIS
	altsyncram #(
		.intended_device_family        ("Cyclone V"),
		.lpm_type                      ("altsyncram"),
		.operation_mode                ("BIDIR_DUAL_PORT"),
		.numwords_a                    (WORDS),
		.numwords_b                    (WORDS),
		.widthad_a                     (AW),
		.widthad_b                     (AW),
		.width_a                       (DW),
		.width_b                       (DW),
		.width_byteena_a               (NB),
		.width_byteena_b               (NB),
		.maximum_depth                 (MAX_DEPTH),
		.address_reg_b                 ("CLOCK1"),
		.indata_reg_b                  ("CLOCK1"),
		.wrcontrol_wraddress_reg_b     ("CLOCK1"),
		.byteena_reg_b                 ("CLOCK1"),
		.outdata_reg_a                 ("UNREGISTERED"),
		.outdata_reg_b                 ("UNREGISTERED"),
		.outdata_aclr_a                ("NONE"),
		.outdata_aclr_b                ("NONE"),
		.power_up_uninitialized        ("FALSE"),
		.ram_block_type                ("M10K"),
		.read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
		.read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
	) u_ram (
		.clock0 (clk_a), .address_a (addr_a), .wren_a (we_a), .byteena_a (be_a), .data_a (wd_a), .q_a (q_a),
		.clock1 (clk_b), .address_b (addr_b), .wren_b (we_b), .byteena_b (be_b), .data_b (wd_b), .q_b (q_b));
`else
	logic [DW-1:0] mem_q [0:WORDS-1];
	logic [DW-1:0] qa = '0, qb = '0;
	initial for (int i = 0; i < WORDS; i++) mem_q[i] = '0;
	always @(posedge clk_a) begin
		logic [DW-1:0] w;
		w = mem_q[addr_a];
		if (we_a) begin
			for (int b = 0; b < NB; b++) if (be_a[b]) w[b*8 +: 8] = wd_a[b*8 +: 8];
			mem_q[addr_a] <= w;
		end
		qa <= w;
	end
	always @(posedge clk_b) begin
		logic [DW-1:0] w;
		w = mem_q[addr_b];
		if (we_b) begin
			for (int b = 0; b < NB; b++) if (be_b[b]) w[b*8 +: 8] = wd_b[b*8 +: 8];
			mem_q[addr_b] <= w;
		end
		qb <= w;
	end
	assign q_a = qa;
	assign q_b = qb;
`endif
endmodule

module daria_mem #(
	parameter int WIN_KB = 64           // 1 to 128; a multiple of 32 uses every word
) (
	input  wire         clk_arm,
	input  wire         clk_sys,

	// The CPU, clk_arm.
	input  wire  [14:0] rom_addr,       // fetch
	output wire  [31:0] win_qa,         // the window's word at last clock's rom_addr
	input  wire  [31:0] d_addr,         // data: window port B, cart RAM port A
	output wire  [31:0] win_qb,
	input  wire         ram_we,
	input  wire   [3:0] ram_be,
	input  wire  [31:0] ram_wdata,
	output wire  [31:0] ram_q,

	// The receiver's image writes, clk_arm; port B is theirs while img_ready
	// is low.
	input  wire         img_ready,
	input  wire         win_we,
	input  wire  [14:0] win_wa,
	input  wire  [31:0] win_wd,
	input  wire   [3:0] win_be,

	// State RAM port A, clk_arm: the call port (daria_call.sv).
	input  wire   [7:0] sta_addr,
	input  wire         sta_we,
	input  wire  [31:0] sta_wd,
	output wire  [31:0] sta_q,

	// clk_sys: the cartridge's bytes into the front-end ROM, and the front
	// ends' ports.
	input  wire         cap_we,         // a byte of file offset cap_addr (below 32 KB)
	input  wire  [14:0] cap_addr,
	input  wire   [7:0] cap_data,
	input  wire  [12:0] fea_addr,       // front-end ROM port A, while cap_we is low
	output wire  [31:0] fea_q,
	input  wire  [12:0] feb_addr,       // front-end ROM port B
	output wire  [31:0] feb_q,
	input  wire  [12:0] crb_addr,       // cart RAM port B
	input  wire         crb_we,
	input  wire   [3:0] crb_be,
	input  wire  [31:0] crb_wd,
	output wire  [31:0] crb_q,
	input  wire   [7:0] stb_addr,       // state RAM port B
	input  wire         stb_we,
	input  wire  [31:0] stb_wd,
	output wire  [31:0] stb_q
);
	// ---- the window -------------------------------------------------------------
	// The CPU fetches and reads ROM only below WIN_KB (bup_cpu's WIN_KB), so
	// the slice index never names a RAM that is not there.
	localparam int NW = (WIN_KB + 31) / 32;
	wire [14:0] wb_addr = img_ready ? d_addr[16:2] : win_wa;
	wire [31:0] qa [NW], qb [NW];
	logic [1:0] sel_a = 2'd0, sel_b = 2'd0;
	always_ff @(posedge clk_arm) begin
		sel_a <= rom_addr[14:13];
		sel_b <= wb_addr[14:13];
	end
	genvar i;
	generate for (i = 0; i < NW; i = i + 1) begin : g_win
		daria_ram #(.AW(13)) win (
			.clk_a(clk_arm), .addr_a(rom_addr[12:0]), .we_a(1'b0), .be_a(4'd0), .wd_a(32'd0), .q_a(qa[i]),
			.clk_b(clk_arm), .addr_b(wb_addr[12:0]),
			.we_b(!img_ready && win_we && wb_addr[14:13] == i), .be_b(win_be), .wd_b(win_wd), .q_b(qb[i]));
	end endgenerate
	generate if (NW == 1) begin : g_one
		assign win_qa = qa[0];
		assign win_qb = qb[0];
	end else begin : g_mux
		assign win_qa = qa[sel_a[$clog2(NW)-1:0]];
		assign win_qb = qb[sel_b[$clog2(NW)-1:0]];
	end endgenerate

	// ---- cart RAM -----------------------------------------------------------------
	daria_ram #(.AW(13)) cart_ram (
		.clk_a(clk_arm), .addr_a(d_addr[14:2]), .we_a(ram_we), .be_a(ram_be), .wd_a(ram_wdata), .q_a(ram_q),
		.clk_b(clk_sys), .addr_b(crb_addr), .we_b(crb_we), .be_b(crb_be), .wd_b(crb_wd), .q_b(crb_q));

	// ---- front-end ROM ---------------------------------------------------------------
	daria_ram #(.AW(13)) fe_rom (
		.clk_a(clk_sys), .addr_a(cap_we ? cap_addr[14:2] : fea_addr), .we_a(cap_we),
		.be_a(4'b0001 << cap_addr[1:0]), .wd_a({4{cap_data}}), .q_a(fea_q),
		.clk_b(clk_sys), .addr_b(feb_addr), .we_b(1'b0), .be_b(4'd0), .wd_b(32'd0), .q_b(feb_q));

	// ---- state RAM -----------------------------------------------------------------------
	daria_ram #(.AW(8), .MAX_DEPTH(256)) state_ram (
		.clk_a(clk_arm), .addr_a(sta_addr), .we_a(sta_we), .be_a(4'hF), .wd_a(sta_wd), .q_a(sta_q),
		.clk_b(clk_sys), .addr_b(stb_addr), .we_b(stb_we), .be_b(4'hF), .wd_b(stb_wd), .q_b(stb_q));
endmodule

`default_nettype wire
