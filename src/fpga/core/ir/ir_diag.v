// ir_diag.v
// M1 diagnostic: button-selected IR LED drive modes, to find out why the LED
// stays dark. Every mode gates a PWM carrier with a BLINK_HZ envelope, so the
// LED is never driven with DC (Analogue: LED runs near max rated current).
//
//   key    mode  carrier               rx_disable   screen colour
//   up     0     38 kHz 33%            1            blue    (power-on default)
//   right  1     38 kHz 33%            0            green
//   down   2     38 kHz 50%            0            yellow
//   left   3     38 kHz inverted (67%) 0            magenta
//   B      4     LED off               1            red
//
// Longest LED on-time in any mode is < 18 us (one inverted 38 kHz pulse).

module ir_diag #(
    parameter CLK_HZ   = 74_250_000,
    parameter BLINK_HZ = 1
) (
    input  wire        clk,
    input  wire [31:0] keys,          // cont1_key
    output reg         ir_tx = 1'b0,
    output reg         ir_rx_disable = 1'b1,
    output reg  [2:0]  mode = 3'd0,
    output wire        envelope
);

reg [7:0] keys_r = 8'd0;
always @(posedge clk) begin
    keys_r <= keys[7:0];
    if      (keys_r[0]) mode <= 3'd0;   // up
    else if (keys_r[3]) mode <= 3'd1;   // right
    else if (keys_r[1]) mode <= 3'd2;   // down
    else if (keys_r[2]) mode <= 3'd3;   // left
    else if (keys_r[5]) mode <= 3'd4;   // B
end

ir_blink #(.CLK_HZ(CLK_HZ), .BLINK_HZ(BLINK_HZ)) blink (.clk(clk), .blink(envelope));

wire c38_33, c38_50;
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(38_000), .DUTY_PCT(33)) car38_33 (.clk(clk), .en(envelope), .out(c38_33));
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(38_000), .DUTY_PCT(50)) car38_50 (.clk(clk), .en(envelope), .out(c38_50));

always @(posedge clk) begin
    case (mode)
        3'd0:    ir_tx <= c38_33;
        3'd1:    ir_tx <= c38_33;
        3'd2:    ir_tx <= c38_50;
        3'd3:    ir_tx <= envelope & ~c38_33;
        default: ir_tx <= 1'b0;
    endcase
    ir_rx_disable <= (mode == 3'd0) || (mode == 3'd4);
end

endmodule
