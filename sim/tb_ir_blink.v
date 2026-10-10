// tb_ir_blink.v
// Checks ir_blink half-period length and 50% duty using a small CLK_HZ so the
// sim runs fast. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_blink;

localparam CLK_HZ   = 1000;
localparam BLINK_HZ = 1;
localparam HALF     = CLK_HZ / (2 * BLINK_HZ);   // expected cycles per half period
localparam EDGES    = 8;                          // toggles to measure

reg  clk = 0;
wire blink;

always #5 clk = ~clk;

ir_blink #(.CLK_HZ(CLK_HZ), .BLINK_HZ(BLINK_HZ)) dut (.clk(clk), .blink(blink));

integer cycles = 0;
integer edges  = 0;
integer errors = 0;
reg     prev   = 0;

always @(negedge clk) begin   // sample away from the DUT's posedge updates
    cycles = cycles + 1;
    if (blink !== prev) begin
        // First toggle comes HALF cycles after start; every later one HALF after the previous.
        if (cycles != HALF) begin
            $display("  edge %0d: expected %0d cycles, got %0d", edges, HALF, cycles);
            errors = errors + 1;
        end
        edges  = edges + 1;
        cycles = 0;
        prev   = blink;
    end
end

initial begin
    repeat (HALF * EDGES + HALF / 2) @(negedge clk);
    if (edges != EDGES) begin
        $display("  expected %0d toggles, saw %0d", EDGES, edges);
        errors = errors + 1;
    end
    if (errors == 0) $display("PASS tb_ir_blink (%0d toggles, %0d cycles each)", edges, HALF);
    else             $display("FAIL tb_ir_blink (%0d errors)", errors);
    $finish;
end

endmodule
