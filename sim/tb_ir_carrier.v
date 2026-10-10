// tb_ir_carrier.v
// Checks ir_carrier at 36/38/40 kHz from 74.25 MHz: period, high time,
// output low while disabled, restart on enable, and never high longer than
// HIGH_CYCLES (LED must never see DC). Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_carrier;

localparam CLK_HZ = 74_250_000;

reg clk = 0;
reg en  = 0;
always #6.734 clk = ~clk;   // ~74.25 MHz

wire out36, out38, out40, out40_25, out40_50;
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(36_000), .DUTY_PCT(33)) c36 (.clk(clk), .en(en), .out(out36));
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(38_000), .DUTY_PCT(33)) c38 (.clk(clk), .en(en), .out(out38));
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(40_000), .DUTY_PCT(33)) c40 (.clk(clk), .en(en), .out(out40));
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(40_000), .DUTY_PCT(25)) c40_25 (.clk(clk), .en(en), .out(out40_25));
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(40_000), .DUTY_PCT(50)) c40_50 (.clk(clk), .en(en), .out(out40_50));

integer errors = 0;

// Measure one output: expected period / high cycles over N full periods.
task check(input integer which, input integer exp_period, input integer exp_high, input integer n);
    integer i, hi, lo, cyc;
    reg     o;
    begin
        // Align to a rising edge of the chosen output (wait for low, then high).
        o = 1;
        while (o == 1) begin @(negedge clk); o = (which == 36) ? out36 : (which == 38) ? out38 : (which == 25) ? out40_25 : (which == 50) ? out40_50 : out40; end
        while (o == 0) begin @(negedge clk); o = (which == 36) ? out36 : (which == 38) ? out38 : (which == 25) ? out40_25 : (which == 50) ? out40_50 : out40; end
        for (i = 0; i < n; i = i + 1) begin
            hi = 0; lo = 0;
            while (o == 1) begin hi = hi + 1; @(negedge clk); o = (which == 36) ? out36 : (which == 38) ? out38 : (which == 25) ? out40_25 : (which == 50) ? out40_50 : out40; end
            while (o == 0) begin lo = lo + 1; @(negedge clk); o = (which == 36) ? out36 : (which == 38) ? out38 : (which == 25) ? out40_25 : (which == 50) ? out40_50 : out40; end
            cyc = hi + lo;
            if (hi != exp_high || cyc != exp_period) begin
                $display("  %0d kHz period %0d: high %0d (exp %0d), period %0d (exp %0d)",
                         which, i, hi, exp_high, cyc, exp_period);
                errors = errors + 1;
            end
        end
        $display("  %0d kHz: period %0d cycles (%0.1f Hz), high %0d cycles (%0.1f%%)",
                 which, cyc, CLK_HZ * 1.0 / cyc, hi, 100.0 * hi / cyc);
    end
endtask

// Safety monitor: no output may stay high longer than its HIGH_CYCLES.
integer run36 = 0, run38 = 0, run40 = 0;
always @(negedge clk) begin
    run36 = out36 ? run36 + 1 : 0;
    run38 = out38 ? run38 + 1 : 0;
    run40 = out40 ? run40 + 1 : 0;
    if (run36 > c36.HIGH_CYCLES || run38 > c38.HIGH_CYCLES || run40 > c40.HIGH_CYCLES) begin
        $display("  SAFETY: output high longer than HIGH_CYCLES");
        errors = errors + 1;
        run36 = 0; run38 = 0; run40 = 0;
    end
end

integer k;
initial begin
    // Disabled: outputs must stay low.
    repeat (5000) begin
        @(negedge clk);
        if (out36 | out38 | out40) begin $display("  output high while disabled"); errors = errors + 1; end
    end

    en = 1;
    // First pulse after enable must be a full high phase starting within 2 cycles.
    k = 0;
    while (!out38) begin @(negedge clk); k = k + 1; end
    if (k > 2) begin $display("  38 kHz first pulse late by %0d cycles", k); errors = errors + 1; end

    check(38, 1954, 645, 5);
    check(36, 2063, 681, 5);
    check(40, 1856, 612, 5);
    check(25, 1856, 464, 5);   // 40 kHz 25%
    check(50, 1856, 928, 5);   // 40 kHz 50%

    // Disable mid-pulse: output must drop within 2 cycles and stay low.
    en = 0;
    repeat (2) @(negedge clk);
    repeat (5000) begin
        @(negedge clk);
        if (out36 | out38 | out40 | out40_25 | out40_50) begin $display("  output high after disable"); errors = errors + 1; end
    end

    if (errors == 0) $display("PASS tb_ir_carrier");
    else             $display("FAIL tb_ir_carrier (%0d errors)", errors);
    $finish;
end

endmodule
