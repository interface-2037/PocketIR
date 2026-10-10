// ir_blink.v
// M1 test: slow square wave to drive the IR LED directly (no carrier).
// Output is 50% duty, BLINK_HZ frequency, derived from CLK_HZ.
// Free-running from FPGA configuration (registers power up to 0).

module ir_blink #(
    parameter CLK_HZ   = 74_250_000,
    parameter BLINK_HZ = 1
) (
    input  wire clk,
    output reg  blink = 1'b0
);

localparam HALF_PERIOD = CLK_HZ / (2 * BLINK_HZ);   // clock cycles per half period
localparam CW          = $clog2(HALF_PERIOD);

reg [CW-1:0] count = {CW{1'b0}};

always @(posedge clk) begin
    if (count == HALF_PERIOD - 1) begin
        count <= {CW{1'b0}};
        blink <= ~blink;
    end else begin
        count <= count + 1'b1;
    end
end

endmodule
