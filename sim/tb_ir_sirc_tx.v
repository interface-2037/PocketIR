// tb_ir_sirc_tx.v
// Decodes ir_sirc_tx's envelope back into frames and checks: exact mark/space
// lengths in T units, address/command, 45 ms (75T) frame spacing, 3 frames on
// a tap, repeats while held, and the Sony STR-DH790 power code packing to
// 0x540C. Uses CLK_HZ = 1 MHz so T = 600 cycles. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_sirc_tx;

localparam CLK_HZ = 1_000_000;
localparam T      = 600;              // cycles per 600 us at 1 MHz

reg         clk = 0;
always #500 clk = ~clk;

reg         key     = 0;
reg  [4:0]  nbits   = 15;
reg  [12:0] address = 0;
reg  [6:0]  command = 0;
wire        env, busy;

ir_sirc_tx #(.CLK_HZ(CLK_HZ)) dut (
    .clk(clk), .key(key), .nbits(nbits), .address(address), .command(command),
    .envelope(env), .busy(busy));

integer errors = 0;

// ---------------- decoder ----------------
integer cyc = 0, run = 0;
reg     prev = 0;
integer exp_bits = 15;
integer nb = 0;                 // bits received in current frame
reg [19:0] data = 0;            // LSB-first data
reg [19:0] word = 0;            // bits in send order (first bit = MSB)
integer frames = 0;
integer last_start = -1;
reg [19:0] last_data = 0, last_word = 0;
reg     in_frame = 0;

task end_run(input reg level, input integer len);
    begin
        if (level) begin
            if (len == 4 * T) begin
                if (in_frame) begin $display("  header inside frame"); errors = errors + 1; end
                if (last_start >= 0 && (cyc - len) - last_start != 75 * T) begin
                    $display("  frame spacing %0d cycles (exp %0d)", (cyc - len) - last_start, 75 * T);
                    errors = errors + 1;
                end
                last_start = cyc - len;
                in_frame = 1; nb = 0; data = 0; word = 0;
            end else if (in_frame && (len == T || len == 2 * T)) begin
                data = data | ((len == 2 * T) << nb);
                word = (word << 1) | (len == 2 * T);
                nb = nb + 1;
                if (nb == exp_bits) begin
                    in_frame = 0; frames = frames + 1; last_data = data; last_word = word;
                end
            end else begin
                $display("  bad mark length %0d cycles", len); errors = errors + 1;
            end
        end else if (in_frame && len != T) begin
            $display("  bad space length %0d cycles inside frame", len); errors = errors + 1;
        end
    end
endtask

always @(negedge clk) begin
    cyc = cyc + 1;
    if (env !== prev) begin
        end_run(prev, run);
        run = 1; prev = env;
    end else begin
        run = run + 1;
    end
end

// ---------------- scenarios ----------------
task send(input integer bits, input integer addr, input integer cmd, input integer hold_cycles,
          input integer exp_min_frames, input integer exp_max_frames);
    integer f0;
    begin
        nbits = bits; address = addr; command = cmd; exp_bits = bits;
        frames = 0; last_start = -1; in_frame = 0;
        @(negedge clk); key = 1;
        repeat (hold_cycles) @(negedge clk);
        key = 0;
        while (busy) @(negedge clk);
        repeat (10) @(negedge clk);
        if (env !== 0) begin $display("  envelope high while idle"); errors = errors + 1; end
        if (frames < exp_min_frames || frames > exp_max_frames) begin
            $display("  %0d-bit: %0d frames (exp %0d..%0d)", bits, frames, exp_min_frames, exp_max_frames);
            errors = errors + 1;
        end
        if (last_data != ((addr << 7) | cmd)) begin
            $display("  %0d-bit: decoded data %h (exp %h)", bits, last_data, (addr << 7) | cmd);
            errors = errors + 1;
        end
        $display("  %0d-bit addr %0d cmd %0d: %0d frames, word sent 0x%h", bits, addr, cmd, frames, last_word);
    end
endtask

initial begin
    repeat (20) @(negedge clk);
    if (env !== 0 || busy !== 0) begin $display("  not idle at start"); errors = errors + 1; end

    // Sony STR-DH790 power: SIRC-15, device 48, command 21. Tap -> 3 frames.
    send(15, 48, 21, 10, 3, 3);
    if (last_word[14:0] != 15'h540C) begin
        $display("  15-bit power word 0x%h (exp 0x540C)", last_word[14:0]); errors = errors + 1;
    end

    // Older Sony amp power: SIRC-12, device 16, command 21. Hold ~6 frames.
    send(12, 16, 21, 6 * 75 * T, 6, 8);

    // 20-bit with all-ones-ish pattern, tap.
    send(20, 13'h1ABC, 7'h55, 10, 3, 3);

    if (errors == 0) $display("PASS tb_ir_sirc_tx");
    else             $display("FAIL tb_ir_sirc_tx (%0d errors)", errors);
    $finish;
end

endmodule
