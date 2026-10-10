// tb_ir_diag.v
// Checks every ir_diag mode: rx_disable value, duty while the envelope is on,
// LED off while the envelope is off, and the longest continuous LED on-time
// (must stay well below anything DC-like). BLINK_HZ is raised so it runs fast.
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_diag;

localparam CLK_HZ   = 74_250_000;
localparam BLINK_HZ = 200;
localparam MAX_ON   = 1400;            // cycles (~18.9 us); inverted 38 kHz is 1309

reg         clk  = 0;
reg  [31:0] keys = 0;
reg         rx   = 1;
always #6.734 clk = ~clk;

wire       tx, rxd, env, rx_act;
wire [2:0] mode;
ir_diag #(.CLK_HZ(CLK_HZ), .BLINK_HZ(BLINK_HZ)) dut (
    .clk(clk), .keys(keys), .ir_rx(rx), .ir_tx(tx), .ir_rx_disable(rxd), .mode(mode),
    .envelope(env), .rx_active(rx_act));

integer errors = 0;

task run_mode(input integer key_bit, input integer exp_mode, input integer exp_rxd,
              input integer duty_lo, input integer duty_hi);
    integer on_cycles, on_high, off_high, run, max_run;
    begin
        keys = 32'd1 << key_bit;
        repeat (4) @(negedge clk);
        keys = 0;
        // Start at a rising edge of the envelope.
        while (env)  @(negedge clk);
        while (!env) @(negedge clk);
        on_cycles = 0; on_high = 0; off_high = 0; run = 0; max_run = 0;
        while (env)  begin on_cycles = on_cycles + 1; on_high = on_high + tx;
                           run = tx ? run + 1 : 0; if (run > max_run) max_run = run; @(negedge clk); end
        repeat (3) @(negedge clk);              // allow the 1-2 cycle pipeline to drain
        while (!env) begin off_high = off_high + tx; @(negedge clk); end

        $display("  mode %0d: rx_disable=%0d duty=%0d%% longest_on=%0d cycles off_phase_high=%0d",
                 mode, rxd, (100 * on_high) / on_cycles, max_run, off_high);
        if (mode !== exp_mode)                 begin $display("    wrong mode"); errors = errors + 1; end
        if (rxd !== exp_rxd)                   begin $display("    wrong rx_disable"); errors = errors + 1; end
        if ((100 * on_high) / on_cycles < duty_lo || (100 * on_high) / on_cycles > duty_hi)
                                               begin $display("    duty out of range"); errors = errors + 1; end
        if (max_run > MAX_ON)                  begin $display("    LED on too long"); errors = errors + 1; end
        if (off_high != 0)                     begin $display("    LED on during off phase"); errors = errors + 1; end
    end
endtask

initial begin
    if (mode !== 0 || rxd !== 1) begin $display("  bad power-on state"); errors = errors + 1; end
    run_mode(3, 1, 0, 32, 34);   // right: 38k 33%, rx on
    run_mode(1, 2, 0, 49, 51);   // down:  38k 50%
    run_mode(2, 3, 0, 66, 68);   // left:  inverted
    run_mode(5, 4, 1,  0,  0);   // B:     off
    run_mode(0, 0, 1, 32, 34);   // up:    38k 33%, rx disabled
    run_mode(4, 5, 0,  0,  0);   // A:     off, rx enabled

    // Receiver activity: an edge on ir_rx lights rx_active while rx is enabled...
    if (rx_act) begin $display("  rx_active high with no rx edges"); errors = errors + 1; end
    rx = 0; repeat (6) @(negedge clk);
    if (!rx_act) begin $display("  rx_active did not respond to rx edge"); errors = errors + 1; end
    // ...and is held off while the receiver is disabled.
    keys = 32'd1 << 5; repeat (4) @(negedge clk); keys = 0;   // B: rx disabled
    repeat (4) @(negedge clk);
    rx = 1; repeat (6) @(negedge clk); rx = 0; repeat (6) @(negedge clk);
    if (rx_act) begin $display("  rx_active high while receiver disabled"); errors = errors + 1; end
    else $display("  rx_active: responds to edges, held off when disabled");

    if (errors == 0) $display("PASS tb_ir_diag");
    else             $display("FAIL tb_ir_diag (%0d errors)", errors);
    $finish;
end

endmodule
