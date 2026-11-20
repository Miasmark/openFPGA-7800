// 8N1 UART for the FujiNet link (fujinet_mailbox.sv), on the link port.
//
// DIV is clk_sys clocks per bit: 124 at NTSC's 14.318 MHz (115,470 baud,
// +0.23% from 115,200) and 123 at PAL's 14.188 MHz (115,346 baud, +0.13%),
// picked by pal. The receiver samples each bit at its middle, timed from the
// start bit's falling edge, so it takes up to a few percent of error.
module fujinet_uart (
	input  logic       clk,
	input  logic       reset,
	input  logic       pal,

	input  logic [7:0] tx_data,
	input  logic       tx_valid,     // tx_data is taken when tx_ready
	output logic       tx_ready,
	output logic       txd,          // idle high

	input  logic       rxd,          // raw pin
	output logic [7:0] rx_data,
	output logic       rx_valid      // one clock per byte with a good stop bit
);

wire [7:0] div = pal ? 8'd123 : 8'd124;

/* verilator lint_off PROCASSINIT */

// Transmit: start bit, 8 data bits LSB first, stop bit
logic [9:0] tx_sh = '1;
logic [3:0] tx_n = 4'd0;
logic [7:0] tx_cnt = 8'd0;
assign tx_ready = tx_n == 4'd0;
assign txd = tx_sh[0];

always_ff @(posedge clk) begin
	if (reset) begin
		tx_sh <= '1;
		tx_n <= 4'd0;
		tx_cnt <= 8'd0;
	end else if (tx_n == 4'd0) begin
		if (tx_valid) begin
			tx_sh <= {1'b1, tx_data, 1'b0};
			tx_n <= 4'd10;
			tx_cnt <= div - 8'd1;
		end
	end else if (tx_cnt != 8'd0) begin
		tx_cnt <= tx_cnt - 8'd1;
	end else begin
		tx_sh <= {1'b1, tx_sh[9:1]};
		tx_n <= tx_n - 4'd1;
		tx_cnt <= div - 8'd1;
	end
end

// Receive
logic [2:0] rx_s = '1;
wire        rx = rx_s[2];
logic [3:0] rx_n = 4'd0;      // 0 idle, 10 start bit ... 1 stop bit
logic [7:0] rx_cnt = 8'd0;
logic [7:0] rx_sh = 8'd0;

always_ff @(posedge clk) begin
	rx_s <= {rx_s[1:0], rxd};
	rx_valid <= 1'b0;
	if (reset) begin
		rx_n <= 4'd0;
	end else if (rx_n == 4'd0) begin
		if (!rx) begin                       // start bit's edge: wait half a bit
			rx_n <= 4'd10;
			rx_cnt <= {1'b0, div[7:1]} - 8'd1;
		end
	end else if (rx_cnt != 8'd0) begin
		rx_cnt <= rx_cnt - 8'd1;
	end else begin
		rx_cnt <= div - 8'd1;
		rx_n <= rx_n - 4'd1;
		if (rx_n == 4'd10) begin
			if (rx) rx_n <= 4'd0;            // a glitch, not a start bit
		end else if (rx_n == 4'd1) begin
			if (rx) begin                    // good stop bit
				rx_data <= rx_sh;
				rx_valid <= 1'b1;
			end
		end else begin
			rx_sh <= {rx, rx_sh[7:1]};
		end
	end
end

/* verilator lint_on PROCASSINIT */

endmodule
