// tb_ir_engine.v
// Replays build/ir_expected/engine_cases.txt through ir_engine (microcode
// compiled for a 1 MHz clock) and checks every envelope run against the
// Python reference cycle for cycle, from the first mark until the engine goes
// idle. Also checks the engine never under-runs and that the carrier runs at
// the protocol's frequency during marks.
// Needs:  python tools/ir/test_irproto.py   (writes the vectors + sim ROM)
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_engine;

reg clk = 0;
always #500 clk = ~clk;                // 1 MHz

reg         key = 0;
reg  [5:0]  proto = 0;
reg  [31:0] address = 0, command = 0;
wire        env, busy, tx, underrun;

ir_engine #(.PROG_FILE("build/ir_expected/ir_proto_sim.hex")) dut (
    .clk(clk), .key(key), .proto(proto), .address(address), .command(command),
    .envelope(env), .ir_tx(tx), .busy(busy), .underrun(underrun));

integer fd, rc, ncase = 0, errors = 0;
integer pid, ad, cm, hold, nruns, i, level, len, run, got, mism, held, txe;
reg     tx_prev;

// release the key after `hold` cycles, independently of run measurement
always @(negedge clk) begin
    if (key) begin
        held = held + 1;
        if (held >= hold) key = 0;
    end
end

initial begin
    fd = $fopen("build/ir_expected/engine_cases.txt", "r");
    if (fd == 0) begin
        $display("FAIL tb_ir_engine (missing build/ir_expected -- run python tools/ir/test_irproto.py)");
        $finish;
    end
    repeat (10) @(negedge clk);
    while (!$feof(fd)) begin
        rc = $fscanf(fd, "%d %d %d %d %d\n", pid, ad, cm, hold, nruns);
        if (rc == 5) begin
            proto = pid; address = ad; command = cm;
            held = 0; key = 1;
            while (!env) @(negedge clk);
            mism = 0;
            for (i = 0; i < nruns; i = i + 1) begin
                rc = $fscanf(fd, "%d %d\n", level, len);
                got = env; run = 0; txe = 0; tx_prev = tx;
                while (env == got && (busy || env)) begin
                    if (tx && !tx_prev) txe = txe + 1;
                    tx_prev = tx;
                    run = run + 1; @(negedge clk);
                end
                if (got != level || run != len) begin
                    if (mism < 3) $display("  case %0d (proto %0d addr %0d cmd %0d) run %0d: got (%0d, %0d) exp (%0d, %0d)",
                                           ncase, pid, ad, cm, i, got, run, level, len);
                    mism = mism + 1;
                end
                // carrier: 40 kHz at 1 MHz = 25-cycle period -> len/25 pulses (+/-1)
                if (i == 0 && (txe < len / 25 - 1 || txe > len / 25 + 1)) begin
                    $display("  case %0d: %0d carrier pulses in a %0d-cycle mark", ncase, txe, len);
                    mism = mism + 1;
                end
            end
            if (busy || env) begin $display("  case %0d: still sending after the last run", ncase); mism = mism + 1; end
            errors = errors + mism;
            ncase = ncase + 1;
            repeat (20) @(negedge clk);
        end
    end
    $fclose(fd);
    if (underrun) begin $display("  engine under-ran (segment not ready in time)"); errors = errors + 1; end
    if (ncase < 20) begin $display("  only %0d cases", ncase); errors = errors + 1; end
    if (errors == 0) $display("PASS tb_ir_engine (%0d cases match the reference cycle for cycle)", ncase);
    else             $display("FAIL tb_ir_engine (%0d errors)", errors);
    $finish;
end

endmodule
