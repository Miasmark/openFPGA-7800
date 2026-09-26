//
// Atari 7800 for Analogue Pocket - APF top level
//
// Instantiated by the real top-level: apf_top.
//
// Port list and APF plumbing come from Analogue's core template. The system
// itself is the MiSTer Atari7800 core, wrapped by atari7800_pocket.sv.
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;


assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;




////////////////////////////////////////////////////////////////////////////////
// Clocks
//
// clk_sys is the 7800's 14.318181 MHz master crystal. MARIA divides it for
// the CPU and hands the TIA a 7.16 MHz (2x colour clock) enable; that ratio
// is what puts TIA audio at the right pitch, so nothing here may run the
// system from any other clock.
////////////////////////////////////////////////////////////////////////////////

    wire    clk_sys;
    wire    clk_sdram;
    wire    clk_sys_90;
    wire    pll_core_locked;
    wire    pll_core_locked_s;

pll_core pll (
    .refclk     ( clk_74a ),
    .rst        ( 1'b0 ),
    .outclk_0   ( clk_sys ),
    .outclk_1   ( clk_sdram ),
    .outclk_2   ( clk_sys_90 ),
    .locked     ( pll_core_locked )
);

synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);


////////////////////////////////////////////////////////////////////////////////
// Bridge
////////////////////////////////////////////////////////////////////////////////

// Bridge address map
//   0x00000000  cartridge image (data slot 0)       -> SDRAM via the loader
//   0x02000000  7800 BIOS       (data slot 1)       -> BIOS block RAM
//   0x10000000  settings (interact.json)
//   0x20000000  high score cartridge RAM (save slot 2, 2 KiB)
//   0xF8000000  APF command interface

localparam [15:0] SLOT_CART = 16'h0100;
localparam [15:0] SLOT_BIOS = 16'h0103;

// Settings. Written by the host from interact.json, clk_74a.
    reg             set_swap      = 1'b0;
    reg             set_ldiff_b   = 1'b1;
    reg             set_rdiff_b   = 1'b1;
    reg     [1:0]   set_region    = 2'd0;
    reg     [1:0]   set_palette   = 2'd0;
    reg     [1:0]   set_hsc       = 2'd0;
    reg             set_overscan  = 1'b0;
    reg             set_border    = 1'b0;
    reg             set_stereo    = 1'b0;
    reg             set_skip_bios = 1'b1;
    reg             set_blend     = 1'b0;
    reg             set_pokey_irq = 1'b0;
    reg     [7:0]   menu_reset_cnt = 8'd0;

always @(posedge clk_74a) begin
    if (menu_reset_cnt != 0)
        menu_reset_cnt <= menu_reset_cnt - 1'b1;

    if (bridge_wr && bridge_addr[31:24] == 8'h10) begin
        case (bridge_addr[11:0])
            12'h200: menu_reset_cnt <= 8'hFF;
            12'h260: set_swap      <= bridge_wr_data[0];
            12'h264: set_ldiff_b   <= bridge_wr_data[0];
            12'h268: set_rdiff_b   <= bridge_wr_data[0];
            12'h26C: set_region    <= bridge_wr_data[1:0];
            12'h270: set_palette   <= bridge_wr_data[1:0];
            12'h274: set_hsc       <= bridge_wr_data[1:0];
            12'h278: set_overscan  <= bridge_wr_data[0];
            12'h27C: set_border    <= bridge_wr_data[0];
            12'h280: set_stereo    <= bridge_wr_data[0];
            12'h284: set_skip_bios <= bridge_wr_data[0];
            12'h288: set_blend     <= bridge_wr_data[0];
            12'h28C: set_pokey_irq <= bridge_wr_data[0];
            default: ;
        endcase
    end
end

// High score cartridge RAM, bridge side: 512 words of 32 bits at
// 0x20000000. Writes go straight in; reads come from the RAM's word port,
// one clk_74a after the address, well inside the bridge's read delay.
    wire    [31:0]  hsc_rd_word;
wire hsc_wr = bridge_wr && bridge_addr[31:24] == 8'h20;

// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h20xxxxxx: begin
        bridge_rd_data <= hsc_rd_word;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;

// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s;
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported = 1'b0;
    wire    [31:0]  savestate_addr = 32'd0;
    wire    [31:0]  savestate_size = 32'd0;
    wire    [31:0]  savestate_maxloadsize = 32'd0;

    wire            savestate_start;
    wire            savestate_start_ack = 1'b0;
    wire            savestate_start_busy = 1'b0;
    wire            savestate_start_ok = 1'b0;
    wire            savestate_start_err = 1'b0;

    wire            savestate_load;
    wire            savestate_load_ack = 1'b0;
    wire            savestate_load_busy = 1'b0;
    wire            savestate_load_ok = 1'b0;
    wire            savestate_load_err = 1'b0;

    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read = 1'b0;
    reg             target_dataslot_write = 1'b0;
    reg             target_dataslot_getfile = 1'b0;
    reg             target_dataslot_openfile = 1'b0;

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id = 16'd0;
    reg     [31:0]  target_dataslot_slotoffset = 32'd0;
    reg     [31:0]  target_dataslot_bridgeaddr = 32'd0;
    reg     [31:0]  target_dataslot_length = 32'd0;

    wire    [31:0]  target_buffer_param_struct;
    wire    [31:0]  target_buffer_resp_struct;

// bridge data slot access
// synchronous to clk_74a

    reg     [9:0]   datatable_addr = 10'd0;
    reg             datatable_wren = 1'b0;
    reg     [31:0]  datatable_data = 32'd0;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);


////////////////////////////////////////////////////////////////////////////////
// Loading
////////////////////////////////////////////////////////////////////////////////

// Which data slot is being written. The host announces each slot with
// requestwrite before streaming it, and signals allcomplete at the end.
    reg             is_downloading = 1'b0;
    reg     [15:0]  download_slot = 16'd0;

always @(posedge clk_74a) begin
    if (dataslot_requestwrite) begin
        is_downloading <= 1'b1;
        download_slot  <= dataslot_requestwrite_id;
    end else if (dataslot_allcomplete) begin
        is_downloading <= 1'b0;
    end
end

// Save slot size: 2 KiB for every 7800 cart (see hsc_active in
// atari7800_pocket.sv for why it does not follow the HSC setting).
    wire            hsc_active;
    reg             hsc_active_74a;
always @(posedge clk_74a) begin
    hsc_active_74a <= hsc_active;
    datatable_wren <= 1'b1;
    datatable_addr <= 10'd2 * 2 + 1;   // data slot index 2, size field
    datatable_data <= hsc_active_74a ? 32'd2048 : 32'd0;
end

// The loader runs on clk_sdram and holds each byte's write strobe for four
// cycles: clk_sdram is exactly 4 x clk_sys and edge aligned, so every
// clk_sys consumer (header parser, BIOS RAM) sees exactly one write per byte,
// and the SDRAM controller sees a single rising edge.
    wire            ioctl_wr;
    wire    [27:0]  ioctl_addr;
    wire    [7:0]   ioctl_dout;

data_loader #(
    .ADDRESS_MASK_UPPER_4       ( 4'h0 ),
    .ADDRESS_SIZE               ( 28 ),
    .WRITE_MEM_CLOCK_DELAY      ( 10 ),
    .WRITE_MEM_EN_CYCLE_LENGTH  ( 4 ),
    .OUTPUT_WORD_SIZE           ( 1 )
) loader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sdram ),
    .bridge_wr              ( bridge_wr ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_wr_data         ( bridge_wr_data ),
    .write_en               ( ioctl_wr ),
    .write_addr             ( ioctl_addr ),
    .write_data             ( ioctl_dout )
);

// Into clk_sys
    reg     [2:0]   dl_s, cart_s, bios_s, rst_s, mrst_s;
    reg             cart_download = 1'b0;
    reg             bios_download = 1'b0;
    reg             core_reset = 1'b1;

always @(posedge clk_sys) begin
    dl_s   <= {dl_s[1:0],   is_downloading};
    cart_s <= {cart_s[1:0], download_slot == SLOT_CART};
    bios_s <= {bios_s[1:0], download_slot == SLOT_BIOS};
    rst_s  <= {rst_s[1:0],  reset_n};
    mrst_s <= {mrst_s[1:0], menu_reset_cnt != 0};

    cart_download <= dl_s[2] & cart_s[2];
    bios_download <= dl_s[2] & bios_s[2];
    core_reset    <= ~rst_s[2] | mrst_s[2];
end

// Settings into clk_sys. They change rarely and only ever from the menu;
// a two stage synchroniser per bit is enough.
    reg     [17:0]  set_s1, set_s2;
always @(posedge clk_sys) begin
    set_s1 <= {set_swap, set_ldiff_b, set_rdiff_b, set_region, set_palette,
               set_hsc, set_overscan, set_border, set_stereo, set_skip_bios,
               set_blend, set_pokey_irq, 3'b000};
    set_s2 <= set_s1;
end


////////////////////////////////////////////////////////////////////////////////
// Controllers
////////////////////////////////////////////////////////////////////////////////

// Pocket key bitmap -> MiSTer joystick layout
//   0 R, 1 L, 2 D, 3 U, 4 Fire1, 5 Fire2, 6 Pause/B&W, 7 Select, 8 Reset
function [15:0] map_joy;
    input [31:0] k;
    begin
        map_joy = 16'd0;
        map_joy[0] = k[3];              // right
        map_joy[1] = k[2];              // left
        map_joy[2] = k[1];              // down
        map_joy[3] = k[0];              // up
        map_joy[4] = k[4] | k[7];       // A / Y: left button (fire 1)
        map_joy[5] = k[5] | k[6];       // B / X: right button (fire 2)
        map_joy[6] = k[8];              // L: pause (7800) / colour-B&W (2600)
        map_joy[7] = k[14];             // select
        map_joy[8] = k[15];             // start -> reset switch
    end
endfunction

    reg     [15:0]  joy0_s1, joy0_s2, joy1_s1, joy1_s2;
always @(posedge clk_sys) begin
    joy0_s1 <= map_joy(cont1_key);
    joy1_s1 <= map_joy(cont2_key);
    joy0_s2 <= joy0_s1;
    joy1_s2 <= joy1_s1;
end


////////////////////////////////////////////////////////////////////////////////
// System
////////////////////////////////////////////////////////////////////////////////

    wire    [7:0]   core_r, core_g, core_b;
    wire            core_hs, core_vs, core_hb, core_vb, core_ce;
    wire            core_tia_mode;
    wire            core_is_pal;
    wire    [15:0]  audio_l, audio_r;
    wire            dram_dqml, dram_dqmh;

atari7800_pocket atari (
    .clk_sys        ( clk_sys ),
    .clk_sdram      ( clk_sdram ),
    .pll_locked     ( pll_core_locked ),
    .reset_in       ( core_reset ),

    .cart_download  ( cart_download ),
    .bios_download  ( bios_download ),
    .ioctl_wr       ( ioctl_wr & (cart_download | bios_download) ),
    .ioctl_addr     ( ioctl_addr[24:0] ),
    .ioctl_dout     ( ioctl_dout ),

    .swap_joysticks ( set_s2[17] ),
    .diff_left_b    ( set_s2[16] ),
    .diff_right_b   ( set_s2[15] ),
    .region_setting ( set_s2[14:13] ),
    .palette_temp   ( set_s2[12:11] ),
    .hsc_setting    ( set_s2[10:9] ),
    .show_overscan  ( set_s2[8] ),
    .hide_border    ( set_s2[7] ),
    .stereo_tia     ( set_s2[6] ),
    .skip_bios      ( set_s2[5] ),
    .flicker_blend  ( set_s2[4] ),
    .pokey_irq      ( set_s2[3] ),
    .pause_core     ( 1'b0 ),

    .joy0           ( joy0_s2 ),
    .joy1           ( joy1_s2 ),

    .R              ( core_r ),
    .G              ( core_g ),
    .B              ( core_b ),
    .HSync          ( core_hs ),
    .VSync          ( core_vs ),
    .HBlank         ( core_hb ),
    .VBlank         ( core_vb ),
    .ce_pix         ( core_ce ),
    .tia_mode_o     ( core_tia_mode ),
    .is_pal_o       ( core_is_pal ),

    .AUDIO_L        ( audio_l ),
    .AUDIO_R        ( audio_r ),

    .clk_74a        ( clk_74a ),
    .hsc_bridge_addr( bridge_addr[10:2] ),
    .hsc_bridge_wr  ( hsc_wr ),
    .hsc_bridge_din ( bridge_wr_data ),
    .hsc_bridge_dout( hsc_rd_word ),
    .hsc_active     ( hsc_active ),

    .SDRAM_A        ( dram_a ),
    .SDRAM_BA       ( dram_ba ),
    .SDRAM_DQ       ( dram_dq ),
    .SDRAM_DQML     ( dram_dqml ),
    .SDRAM_DQMH     ( dram_dqmh ),
    .SDRAM_nWE      ( dram_we_n ),
    .SDRAM_nRAS     ( dram_ras_n ),
    .SDRAM_nCAS     ( dram_cas_n ),
    .SDRAM_CLK      ( dram_clk ),
    .SDRAM_CKE      ( dram_cke )
);

// MiSTer's SDRAM module routes DQM through A12/A11; the Pocket has real pins.
assign dram_dqm = {dram_dqmh, dram_dqml};


////////////////////////////////////////////////////////////////////////////////
// Video
//
// The core produces a pixel on each ce_pix of clk_sys: every other cycle for
// MARIA (7.16 MHz, 320 wide), every fourth for the TIA (3.58 MHz, 160 wide).
// The Pocket samples every clk_sys cycle and drops those marked skip.
//
// The scaler slot index is sent in rgb[23:13] on the first cycle after
// active video ends.
////////////////////////////////////////////////////////////////////////////////

    reg     [23:0]  vid_rgb;
    reg             vid_de, vid_skip, vid_vs, vid_hs;
    reg             de_prev, hs_prev, vs_prev;
    reg     [3:0]   hs_delay;

wire core_de = ~(core_hb | core_vb);

// Scaler slots (video.json): 0 = 7800 with border (372x224),
// 1 = 7800 without border (320x224), 2 = 2600 (160x240).
wire [1:0] video_slot = core_tia_mode ? 2'd2 : (set_s2[7] ? 2'd1 : 2'd0);

always @(posedge clk_sys) begin
    vid_de   <= 1'b0;
    vid_skip <= 1'b0;
    vid_hs   <= 1'b0;
    vid_rgb  <= 24'h0;

    if (core_de) begin
        vid_de   <= 1'b1;
        vid_skip <= ~core_ce;
        vid_rgb  <= {core_r, core_g, core_b};
    end else if (de_prev) begin
        vid_rgb  <= {9'd0, video_slot, 13'd0};
    end

    // HSync rising edge, delayed so it never lands on the VSync cycle.
    if (hs_delay != 0)
        hs_delay <= hs_delay - 1'b1;
    if (hs_delay == 4'd1)
        vid_hs <= 1'b1;
    if (~hs_prev && core_hs)
        hs_delay <= 4'd8;

    vid_vs  <= ~vs_prev && core_vs;
    hs_prev <= core_hs;
    vs_prev <= core_vs;
    de_prev <= core_de;
end

assign video_rgb_clock    = clk_sys;
assign video_rgb_clock_90 = clk_sys_90;
assign video_rgb  = vid_rgb;
assign video_de   = vid_de;
assign video_skip = vid_skip;
assign video_vs   = vid_vs;
assign video_hs   = vid_hs;


////////////////////////////////////////////////////////////////////////////////
// Audio
//
// The core's mix is 16 bit unsigned around a midpoint at clk_sys rate. It is
// box filtered down to ~48 kHz (298 clk_sys samples per output), the DC
// offset is removed, and the result goes to the I2S DAC.
////////////////////////////////////////////////////////////////////////////////

    wire    [15:0]  aud_l_f, aud_r_f;

audio_filter afilt (
    .clk        ( clk_sys ),
    .in_l       ( audio_l ),
    .in_r       ( audio_r ),
    .out_l      ( aud_l_f ),
    .out_r      ( aud_r_f )
);

sound_i2s #(
    .CHANNEL_WIDTH  ( 16 ),
    .SIGNED_INPUT   ( 1 )
) sound (
    .clk_74a    ( clk_74a ),
    .clk_audio  ( clk_sys ),
    .audio_l    ( aud_l_f ),
    .audio_r    ( aud_r_f ),
    .audio_mclk ( audio_mclk ),
    .audio_lrck ( audio_lrck ),
    .audio_dac  ( audio_dac )
);

endmodule
