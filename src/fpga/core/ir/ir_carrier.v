// ir_carrier.v
// IR carrier generator: square wave at CARRIER_HZ with DUTY_PCT high time,
// derived from CLK_HZ. Output is registered and is 0 whenever en = 0.
// Each time en rises the carrier restarts at the start of its high phase,
// so envelopes (NEC marks etc.) always begin with a full pulse.
//
// Analogue: the IR LED runs near its max rated current -- never drive it with
// DC. This module can never hold the output high for more than HIGH_CYCLES.

module ir_carrier #(
    parameter CLK_HZ     = 74_250_000,
    parameter CARRIER_HZ = 38_000,
    parameter DUTY_PCT   = 33
) (
    input  wire clk,
    input  wire en,
    output reg  out = 1'b0
);

localparam PERIOD      = (CLK_HZ + CARRIER_HZ / 2) / CARRIER_HZ;   // rounded
localparam HIGH_CYCLES = (PERIOD * DUTY_PCT + 50) / 100;           // rounded
localparam CW          = $clog2(PERIOD);

reg [CW-1:0] count = {CW{1'b0}};

always @(posedge clk) begin
    if (!en) begin
        count <= {CW{1'b0}};
        out   <= 1'b0;
    end else begin
        count <= (count == PERIOD - 1) ? {CW{1'b0}} : count + 1'b1;
        out   <= (count < HIGH_CYCLES);
    end
end

endmodule
