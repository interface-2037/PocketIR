// tb_ir_sirc_ref.v
// Proves the Python reference encoder (tools/ir/irproto.py) against the SIRC
// encoder that works on hardware (ir_sirc_tx.v): for all 12 STR-DH790 codes,
// a tap's envelope must match the reference runs cycle for cycle, from the
// first mark to the end of the last frame (busy low).
// Needs build/ir_expected/sirc_ref.txt: run  python tools/ir/test_irproto.py
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_sirc_ref;

reg clk = 0;
always #500 clk = ~clk;                // 1 MHz, matches SIM_CLK in test_irproto.py

reg         key = 0;
reg  [4:0]  nbits = 15;
reg  [12:0] address = 0;
reg  [6:0]  command = 0;
wire        env, busy;

ir_sirc_tx #(.CLK_HZ(1_000_000)) dut (
    .clk(clk), .key(key), .nbits(nbits), .address(address), .command(command),
    .envelope(env), .busy(busy));

integer fd, rc, codes = 0, errors = 0;
integer nb, ad, cm, nruns, i, level, len, run, got_level, mism;

initial begin
    fd = $fopen("build/ir_expected/sirc_ref.txt", "r");
    if (fd == 0) begin
        $display("FAIL tb_ir_sirc_ref (missing build/ir_expected -- run python tools/ir/test_irproto.py)");
        $finish;
    end
    repeat (10) @(negedge clk);
    while (!$feof(fd)) begin
        rc = $fscanf(fd, "%d %d %d %d\n", nb, ad, cm, nruns);
        if (rc == 4) begin
            nbits = nb; address = ad; command = cm;
            @(negedge clk); key = 1; @(negedge clk); key = 0;     // tap
            while (!env) @(negedge clk);                          // first mark
            mism = 0;
            for (i = 0; i < nruns; i = i + 1) begin
                rc = $fscanf(fd, "%d %d\n", level, len);
                got_level = env; run = 0;
                // measure this run: until the level changes or the encoder goes idle
                while (env == got_level && (busy || env)) begin run = run + 1; @(negedge clk); end
                if (got_level != level || run != len) begin
                    if (mism < 3) $display("  %0d-bit addr %0d cmd %0d run %0d: got (%0d, %0d) exp (%0d, %0d)",
                                           nb, ad, cm, i, got_level, run, level, len);
                    mism = mism + 1;
                end
            end
            if (busy || env) begin $display("  %0d-bit addr %0d cmd %0d: still sending after last run", nb, ad, cm); mism = mism + 1; end
            errors = errors + mism;
            codes = codes + 1;
            repeat (20) @(negedge clk);
        end
    end
    $fclose(fd);
    if (codes != 12) begin $display("  only %0d codes in vector file", codes); errors = errors + 1; end
    if (errors == 0) $display("PASS tb_ir_sirc_ref (%0d codes match the Python reference cycle for cycle)", codes);
    else             $display("FAIL tb_ir_sirc_ref (%0d errors)", errors);
    $finish;
end

endmodule
