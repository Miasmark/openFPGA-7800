#!/usr/bin/env python3
"""Turn a copy of src/fpga into DARIA's step 3 full-build probe
(docs/DARIA_CORE.md, step 3; run_full.sh makes the copy and compiles it).

The shipped core (POCKET_BUPCHIP, 2.1.2) gets, in the copy only:

  - bupchip_pocket.sv: DARIA's CPU (bup_cpu THUMB 1, CODE_AW 15, arm_only
    low in the 2600 profile) and its memories at full size, as "The memory
    system", 1.1 and 1.2 give them: the 16 KB firmware ROM and the 128 KB
    image window (altsyncram, maximum_depth 8192) behind the profile mux on
    fetch and data, the cart RAM at 32 KB with port B on clk_sys, and the
    32 KB front-end ROM on clk_sys. The profile, prof26, is tia_en through
    two clk_arm flops. The image and front-end writes take the loader's
    stream; the front-end ROM's second port reads at a counter; the clk_sys
    read data reach a pin through audio_l[0] in the 2600 profile, so nothing
    is optimised away. Not modelled: the front ends' logic, the call port,
    the MMIO and timer, the state RAM (2 M10K) and the cache's second way
    (2 M10K).
  - pll_core.v: counter 3 (clk_arm) at VCO / D: 21 (32.73 MHz) by default,
    17 (40.43 MHz) with --div 17.
  - core_constraints.sdc: the form of DARIA_CORE.md's 7.3 (open item 9). The
    clock groups stay as they are (Quartus would not apply set_max_delay to
    paths a clock group cuts), and the clk_sys <-> clk_arm paths get
    set_max_delay 20 and set_min_delay -20 (--mind; the first builds used 0)
    instead of the edge relation.
    clk_arm <-> clk_sdram and <-> clk_sys_90 keep their real relationship as
    a tripwire: no path should exist there. --all-clocks bounds those too
    (the first seed-2 build's form).

Usage: daria_probe.py FPGA_DIR [--div N] [--maxd NS]
"""
import argparse
import os
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("fpga")
ap.add_argument("--div", type=int, default=21)
ap.add_argument("--maxd", type=float, default=20.0,
                help="set_max_delay between clk_arm and clk_sys (ns)")
ap.add_argument("--mind", type=float, default=-20.0,
                help="set_min_delay between clk_arm and clk_sys (ns); 7.3's -20 leaves the held buses no hold check")
ap.add_argument("--win4", action="store_true",
                help="the window as four 8K-deep altsyncrams and a registered 4:1 mux, so no per-slice read-enable decode")
ap.add_argument("--all-clocks", action="store_true",
                help="bound clk_arm against all three other core counters, not only clk_sys")
args = ap.parse_args()

core = os.path.join(args.fpga, "core")


def edit(path, pairs):
    with open(path) as f:
        s = f.read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f"daria_probe.py: {path}: expected one match, found {n}:\n{old}")
        s = s.replace(old, new)
    with open(path, "w") as f:
        f.write(s)


# ---- bupchip_pocket.sv ------------------------------------------------------------
wrap = os.path.join(core, "bupchip", "bupchip_pocket.sv")
with open(wrap) as f:
    w = f.read()
start = w.index("\t// ---- the CPU and its memories")
end = w.index("\twire st_miss, st_pf, st_preempt, st_late, st_stall;")
ifn = w.index("`ifndef ALTERA_RESERVED_QIS", start)
block = r"""	// ---- the CPU and its memories: DARIA's step 3 probe ---------------------------------
	localparam int CODE_AW = 15;
	logic  [1:0] prof_s = 2'b00;
	logic        prof26 = 1'b0;
	always_ff @(posedge clk_arm) begin
		prof_s <= {prof_s[0], prof26_sys};
		prof26 <= prof_s[1];
	end

	wire  [CODE_AW-1:0] rom_addr;
	wire  [31:0] rom_q, rom_dq, ram_q, d_addr, ram_wdata, w_addr, reg_wdata, reg_rdata, asset_q;
	wire  [31:0] fw_qa, fw_qb, win_qa, win_qb;
	wire   [3:0] ram_be;
	wire   [1:0] w_size;
	wire   [7:0] reg_addr;
	wire         ram_we, w_asset, w_wait, reg_sel, reg_write;
	wire         halted;
	wire   [3:0] halt_code;
	wire  [31:0] halt_pc;
	wire         freeze;

	bup_cpu #(.THUMB(1'b1), .CODE_AW(CODE_AW)) cpu (
		.clk(clk_arm), .rst(~cpu_run), .freeze, .w_wait, .arm_only(!prof26),
		.rom_addr, .rom_q,
		.d_addr, .ram_we, .ram_be, .ram_wdata, .rom_dq, .ram_q,
		.asset_size, .asset_q, .w_asset, .w_addr, .w_size,
		.reg_sel, .reg_addr, .reg_write, .reg_wdata, .reg_rdata,
		.halted, .halt_code, .halt_pc);

	cache_ram_dp #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) rom (
		.clk_i(clk_arm),
		.addr_a_i(rom_addr[11:0]), .wren_a_i(1'b0), .wdata_a_i(32'd0), .q_a_o(fw_qa),
		.addr_b_i(fw_loaded ? d_addr[13:2] : rom_wa), .wren_b_i(rom_we && !fw_loaded && !prof26),
		.wdata_b_i(rom_wd), .q_b_o(fw_qb));

	// The image window. Its writes stand for the receiver's image words: the
	// write stream's words, paged by a counter.
	logic [2:0] win_page = 3'd0;
	always_ff @(posedge clk_arm)
		if (wr_fw_start) win_page <= 3'd0;
		else if (rom_we && rom_wa == 12'hFFF) win_page <= win_page + 3'd1;
@WINDOW@	assign rom_q  = prof26 ? win_qa : fw_qa;
	assign rom_dq = prof26 ? win_qb : fw_qb;

	// Cart RAM, 32 KB: port A the CPU's, port B (clk_sys) the front ends'.
	// The probe's port B takes the loader's bytes in the 2600 profile.
	wire        img_we = load_valid && prof26_sys;
	wire  [3:0] img_be = 4'b0001 << load_addr[1:0];
	wire [31:0] crb_q, fe_qa, fe_qb;
	cache_ram_tdp_dc_be #(.ADDR_WIDTH(13), .DATA_WIDTH(32)) ram (
		.clk_a_i(clk_arm), .addr_a_i(d_addr[14:2]), .wren_a_i(ram_we), .byteena_a_i(ram_be),
		.wdata_a_i(ram_wdata), .q_a_o(ram_q),
		.clk_b_i(clk_sys), .addr_b_i(load_addr[14:2]), .wren_b_i(img_we), .byteena_b_i(img_be),
		.wdata_b_i({4{load_data}}), .q_b_o(crb_q));

	// The front-end ROM, 32 KB on clk_sys: capture writes on port A, reads
	// at a counter on port B.
	logic [12:0] fe_ra = 13'd0;
	always_ff @(posedge clk_sys) fe_ra <= fe_ra + 13'd1;
	cache_ram_tdp_dc_be #(.ADDR_WIDTH(13), .DATA_WIDTH(32)) fe_rom (
		.clk_a_i(clk_sys), .addr_a_i(load_addr[14:2]), .wren_a_i(img_we), .byteena_a_i(img_be),
		.wdata_a_i({4{load_data}}), .q_a_o(fe_qa),
		.clk_b_i(clk_sys), .addr_b_i(fe_ra), .wren_b_i(1'b0), .byteena_b_i(4'd0),
		.wdata_b_i(32'd0), .q_b_o(fe_qb));
	logic probe_par = 1'b0;
	always_ff @(posedge clk_sys) probe_par <= ^{crb_q, fe_qa, fe_qb};

"""
WIN1 = r"""	altsyncram #(
		.intended_device_family        ("Cyclone V"),
		.lpm_type                      ("altsyncram"),
		.operation_mode                ("BIDIR_DUAL_PORT"),
		.numwords_a                    (32768),
		.numwords_b                    (32768),
		.widthad_a                     (15),
		.widthad_b                     (15),
		.width_a                       (32),
		.width_b                       (32),
		.width_byteena_a               (1),
		.width_byteena_b               (1),
		.maximum_depth                 (8192),
		.address_reg_b                 ("CLOCK0"),
		.indata_reg_b                  ("CLOCK0"),
		.wrcontrol_wraddress_reg_b     ("CLOCK0"),
		.outdata_reg_a                 ("UNREGISTERED"),
		.outdata_reg_b                 ("UNREGISTERED"),
		.outdata_aclr_a                ("NONE"),
		.outdata_aclr_b                ("NONE"),
		.power_up_uninitialized        ("FALSE"),
		.ram_block_type                ("M10K"),
		.read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
		.read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
	) window (
		.clock0    (clk_arm),
		.address_a (rom_addr[14:0]),
		.wren_a    (1'b0),
		.data_a    (32'd0),
		.q_a       (win_qa),
		.address_b (fw_loaded ? d_addr[16:2] : {win_page, rom_wa}),
		.wren_b    (rom_we && !fw_loaded && prof26),
		.data_b    (rom_wd),
		.q_b       (win_qb));

"""
WIN4 = r"""	// The window as four 8K-deep RAMs read every clock, and a 4:1 mux on the
	// registered address bits: no read-enable decode on rom_addr's path.
	wire [14:0] win_ab = fw_loaded ? d_addr[16:2] : {win_page, rom_wa};
	wire [31:0] win_qa_s [4], win_qb_s [4];
	logic [1:0] win_sa = 2'd0, win_sb = 2'd0;
	always_ff @(posedge clk_arm) begin
		win_sa <= rom_addr[14:13];
		win_sb <= win_ab[14:13];
	end
	genvar wi;
	generate for (wi = 0; wi < 4; wi = wi + 1) begin : g_win
		altsyncram #(
			.intended_device_family        ("Cyclone V"),
			.lpm_type                      ("altsyncram"),
			.operation_mode                ("BIDIR_DUAL_PORT"),
			.numwords_a                    (8192),
			.numwords_b                    (8192),
			.widthad_a                     (13),
			.widthad_b                     (13),
			.width_a                       (32),
			.width_b                       (32),
			.width_byteena_a               (1),
			.width_byteena_b               (1),
			.maximum_depth                 (8192),
			.address_reg_b                 ("CLOCK0"),
			.indata_reg_b                  ("CLOCK0"),
			.wrcontrol_wraddress_reg_b     ("CLOCK0"),
			.outdata_reg_a                 ("UNREGISTERED"),
			.outdata_reg_b                 ("UNREGISTERED"),
			.outdata_aclr_a                ("NONE"),
			.outdata_aclr_b                ("NONE"),
			.power_up_uninitialized        ("FALSE"),
			.ram_block_type                ("M10K"),
			.read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
			.read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
		) window (
			.clock0    (clk_arm),
			.address_a (rom_addr[12:0]),
			.wren_a    (1'b0),
			.data_a    (32'd0),
			.q_a       (win_qa_s[wi]),
			.address_b (win_ab[12:0]),
			.wren_b    (rom_we && !fw_loaded && prof26 && win_ab[14:13] == wi),
			.data_b    (rom_wd),
			.q_b       (win_qb_s[wi]));
	end endgenerate
	assign win_qa = win_qa_s[win_sa];
	assign win_qb = win_qb_s[win_sb];

"""
win1 = WIN1
win4 = WIN4
block = block.replace("@WINDOW@", win4 if args.win4 else win1)
w = w[:start] + block + w[end:]
with open(wrap, "w") as f:
    f.write(w)
edit(wrap, [
    ("\tinput  wire        pause,           // clk_sys (pause_core)\n",
     "\tinput  wire        pause,           // clk_sys (pause_core)\n"
     "\tinput  wire        prof26_sys,      // DARIA probe: the 2600 profile (tia_en), clk_sys\n"),
    ("\t\tif (!souper_profile) begin\n\t\t\taudio_l <= 16'd0;\n\t\t\taudio_r <= 16'd0;\n\t\tend\n",
     "\t\tif (!souper_profile) begin\n\t\t\taudio_l <= 16'd0;\n\t\t\taudio_r <= 16'd0;\n\t\tend\n"
     "\t\tif (prof26_sys) audio_l[0] <= probe_par;\n"),
])
assert "ALTERA_RESERVED_QIS" not in w[start:start + len(block)]

# ---- atari7800_pocket.sv ------------------------------------------------------------
edit(os.path.join(core, "atari7800_pocket.sv"), [
    ("\t.pause         (pause_core),\n",
     "\t.pause         (pause_core),\n\t.prof26_sys    (tia_en),\n"),
])

# ---- pll_core.v: counter 3 --------------------------------------------------------------
div = args.div
hi, lo = (div + 1) // 2, div // 2
mhz = 687.272727 / div
edit(os.path.join(core, "pll", "pll_core.v"), [
    ('.output_clock_frequency3("28.636362 MHz")', f'.output_clock_frequency3("{mhz:.6f} MHz")'),
    (".c_cnt_hi_div3(12)", f".c_cnt_hi_div3({hi})"),
    (".c_cnt_lo_div3(12)", f".c_cnt_lo_div3({lo})"),
    ('.c_cnt_odd_div_duty_en3("false")', '.c_cnt_odd_div_duty_en3("%s")' % ("true" if div % 2 else "false")),
])

# ---- core_constraints.sdc ------------------------------------------------------------------
sdc = os.path.join(core, "core_constraints.sdc")
with open(sdc) as f:
    s = f.read()
others = ["0", "1", "2"] if args.all_clocks else ["0"]
pll = "ic|pll|altera_pll_i|cyclonev_pll|counter[%s].output_counter|divclk"
s += f"""
# DARIA step 3 probe: clk_arm at VCO / {div}, no longer 2 x clk_sys. Every
# crossing between it and clk_sys is a synchroniser with held data
# (bupchip_pocket.sv, "Clocks"), so the edge-derived requirement (as little
# as one VCO period) does not apply. Bounded instead: at most {args.maxd} ns of
# data delay. The buses are held for at least two destination clocks before
# they are used, so set_min_delay {args.mind} leaves them no hold check.
set clk_arm  {{{pll % "3"}}}
set not_arm  [get_clocks {{{" ".join(pll % n for n in others)}}}]
set_max_delay -from [get_clocks $clk_arm] -to $not_arm {args.maxd}
set_max_delay -from $not_arm -to [get_clocks $clk_arm] {args.maxd}
set_min_delay -from [get_clocks $clk_arm] -to $not_arm {args.mind}
set_min_delay -from $not_arm -to [get_clocks $clk_arm] {args.mind}
"""
with open(sdc, "w") as f:
    f.write(s)

print(f"daria_probe.py: {args.fpga}: DARIA CPU and memories, clk_arm = VCO / {div} ({mhz:.3f} MHz), "
      f"crossings with {'all core clocks' if args.all_clocks else 'clk_sys'} bounded at {args.maxd} ns")
