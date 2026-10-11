// tb_rx_marks.v
// ir_rx_marks (M9): raw receiver edges -> mark-start intervals, equal to the
// model (build/ir_expected/m9_marks.txt from tools/ir/test_match.py): the
// real hardware capture of a Sony remote (both buffers) and synthetic
// edge-only Samsung32 / RC6 bursts. Also: `done` once per burst with the
// interval count, nothing while disabled, no new burst while `hold`.
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_rx_marks;

localparam END_MS = 60;            // shorter than on hardware (200): every gap in the vectors is < 50 ms

reg clk = 0;
always #5 clk = ~clk;

reg        enable = 0, rx = 1, hold = 0;
wire       active, done;
wire [8:0] n_iv;
reg  [7:0] raddr = 0;
wire [15:0] rq;

ir_rx_marks #(.END_MS(END_MS)) dut (
    .clk(clk), .enable(enable), .rx(rx), .hold(hold), .active(active), .done(done),
    .n_iv(n_iv), .raddr(raddr), .rq(rq));

integer ndone = 0;
always @(posedge clk) if (done) ndone = ndone + 1;

integer fd, ncase, i, j, n, v, lvl, dl, errors, nexp, k;
integer exp_iv [0:255];
task idle(input integer clocks);              // from a falling edge to a falling edge
    begin #(clocks * 10); end
endtask

initial begin
    errors = 0;
    fd = $fopen("build/ir_expected/m9_marks.txt", "r");
    if (fd == 0) begin $display("FAIL tb_rx_marks (no vectors: run tools/ir/test_match.py)"); $finish; end
    // disabled: edges are ignored
    idle(30000); rx = 0; idle(200); rx = 1; idle(30000);
    if (active || ndone) begin $display("  recorded while disabled"); errors = errors + 1; end
    enable = 1;
    idle(30000);                                  // (the first edge of each case follows idle >> 250 us)
    v = $fscanf(fd, "%d", ncase);
    for (i = 0; i < ncase; i = i + 1) begin
        v = $fscanf(fd, "%d", n);
        k = ndone;
        for (j = 0; j < n; j = j + 1) begin
            v = $fscanf(fd, "%d %d", lvl, dl);
            if (j > 0) idle(dl);
            rx = lvl;
        end
        v = $fscanf(fd, "%d", nexp);
        for (j = 0; j < nexp; j = j + 1) v = $fscanf(fd, "%d", exp_iv[j]);
        idle(END_MS * 74_250 + 1000);                 // burst ends
        if (ndone != k + 1 || n_iv != nexp) begin
            $display("  case %0d: done %0d times, n_iv %0d, expected 1 and %0d", i, ndone - k, n_iv, nexp);
            errors = errors + 1;
        end
        for (j = 0; j < nexp; j = j + 1) begin
            @(negedge clk) raddr = j;
            @(negedge clk); @(negedge clk);
            if (rq != exp_iv[j]) begin
                if (errors < 10) $display("  case %0d: interval %0d = %0d, expected %0d", i, j, rq, exp_iv[j]);
                errors = errors + 1;
            end
        end
    end
    // hold: a burst arriving while held is ignored entirely
    hold = 1; k = ndone;
    for (j = 0; j < 6; j = j + 1) begin rx = 0; idle(500); rx = 1; idle(100_000); end
    hold = 0;
    idle(END_MS * 74_250 + 1000);
    if (ndone != k || active) begin $display("  burst recorded while held"); errors = errors + 1; end
    if (errors == 0) $display("PASS tb_rx_marks (%0d bursts incl. the hardware capture)", ncase);
    else             $display("FAIL tb_rx_marks (%0d errors)", errors);
    $finish;
end

endmodule
