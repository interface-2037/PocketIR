// tb_ir_synth.v
// ir_synth (M9): for random codes in every protocol, both toggle values, the
// mark-start intervals of the walked first frame equal the reference
// encoder's (build/ir_expected/m9_synth.txt from tools/ir/test_match.py).
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_synth;

reg clk = 0;
always #5 clk = ~clk;

reg         start = 0, t = 0;
reg  [5:0]  proto = 0;
reg  [31:0] d = 0, f = 0;
wire        seg, lvl, done, busy;
wire [23:0] ticks;
wire [3:0]  kind;

ir_synth #(.PROG_FILE("src/fpga/core/ir/ir_proto.hex")) dut (
    .clk(clk), .start(start), .proto(proto), .d(d), .f(f), .t(t),
    .seg(seg), .seg_level(lvl), .seg_ticks(ticks), .done(done), .busy(busy), .kind(kind));

// mark-start intervals, collected like lib/ir_match.v
integer got [0:127];
integer ngot, tt, last, any, prev;
always @(posedge clk) if (seg) begin
    if (lvl && !prev) begin
        if (any) begin got[ngot] = tt - last; ngot = ngot + 1; end
        any = 1; last = tt;
    end
    tt = tt + ticks; prev = lvl;
end

integer fd, ncase, i, j, n, v, ti, errors, cycles;
reg [31:0] hd, hf;
integer exp_iv [0:127];
initial begin
    errors = 0;
    fd = $fopen("build/ir_expected/m9_synth.txt", "r");
    if (fd == 0) begin $display("FAIL tb_ir_synth (no vectors: run tools/ir/test_match.py)"); $finish; end
    v = $fscanf(fd, "%d", ncase);
    for (i = 0; i < ncase; i = i + 1) begin
        v = $fscanf(fd, "%d %h %h %d %d", n, hd, hf, ti, j);
        proto = n; d = hd; f = hf; t = ti; n = j;
        for (j = 0; j < n; j = j + 1) v = $fscanf(fd, "%d", exp_iv[j]);
        ngot = 0; tt = 0; last = 0; any = 0; prev = 0;
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        cycles = 0;
        while (!done && cycles < 100000) begin @(negedge clk); cycles = cycles + 1; end
        @(negedge clk);
        if (ngot != n) begin
            $display("  proto %0d d %h f %h t %0d: %0d intervals, expected %0d", proto, d, f, t, ngot, n);
            errors = errors + 1;
        end else for (j = 0; j < n; j = j + 1)
            if (got[j] != exp_iv[j]) begin
                if (errors < 10) $display("  proto %0d d %h f %h t %0d: interval %0d = %0d, expected %0d",
                                          proto, d, f, t, j, got[j], exp_iv[j]);
                errors = errors + 1;
            end
        if (busy) begin $display("  still busy after done"); errors = errors + 1; end
    end
    if (errors == 0) $display("PASS tb_ir_synth (%0d codes, all protocols, both toggles)", ncase);
    else             $display("FAIL tb_ir_synth (%0d errors)", errors);
    $finish;
end

endmodule
