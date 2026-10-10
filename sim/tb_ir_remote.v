// tb_ir_remote.v
// Presses every mapped Pocket button on ir_remote and decodes the SIRC
// envelope (frame length found from the trailing gap, so 15- and 20-bit
// frames mix). Checks each button sends its table code 3 times on a tap,
// holding R1 repeats, and switching buttons mid-send never repeats the old
// code under the new button. Also checks ir_tx only pulses inside marks.
// CLK_HZ = 1 MHz so T = 600 cycles. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_remote;

localparam CLK_HZ = 1_000_000;
localparam T      = 600;

reg         clk  = 0;
always #500 clk = ~clk;
reg  [15:0] keys = 0;
wire        tx, env, busy;
wire [3:0]  active_idx;

ir_remote #(.PROG_FILE("build/ir_expected/ir_proto_sim.hex")) dut (
    .clk(clk), .keys(keys), .ir_tx(tx), .envelope(env), .busy(busy), .active_idx(active_idx));

integer errors = 0;

// ---------------- decoder ----------------
integer cyc = 0, run = 0;
reg     prev = 0;
integer nb = 0;
reg [19:0] data = 0;
reg     in_frame = 0;
integer nframes = 0;
reg [19:0] f_data [0:63];
integer    f_bits [0:63];

task finish_frame;
    begin
        if (nframes < 64) begin f_data[nframes] = data; f_bits[nframes] = nb; end
        nframes = nframes + 1;
        in_frame = 0;
    end
endtask

task end_run(input reg level, input integer len);
    begin
        if (level) begin
            if (len == 4 * T) begin
                if (in_frame) finish_frame;
                in_frame = 1; nb = 0; data = 0;
            end else if (in_frame && (len == T || len == 2 * T)) begin
                data = data | ((len == 2 * T) << nb);
                nb = nb + 1;
            end else begin
                $display("  bad mark %0d cycles", len); errors = errors + 1;
            end
        end else if (in_frame && len != T) begin
            finish_frame;                        // long space = end of frame
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
        if (!env && in_frame && run == 2 * T) finish_frame;   // trailing gap
    end
    if (tx && !env) begin
        // carrier output lags envelope by 2 registers; allow that
        if (run > 3) begin $display("  ir_tx high outside a mark"); errors = errors + 1; end
    end
end

// ---------------- expected table (mirror of ir_code_rom.v) ----------------
// Packed as {nbits[4:0], address[12:0], command[6:0]}.
function [24:0] code_of(input integer idx);
    begin
        case (idx)
            15: code_of = {5'd15, 13'd48,  7'd21};    // power
            14: code_of = {5'd15, 13'd48,  7'd20};    // mute
            8:  code_of = {5'd15, 13'd48,  7'd18};    // volume +
            9:  code_of = {5'd15, 13'd48,  7'd19};    // volume -
            1:  code_of = {5'd15, 13'd176, 7'd120};   // menu up
            0:  code_of = {5'd15, 13'd176, 7'd121};   // menu down
            3:  code_of = {5'd15, 13'd176, 7'd122};   // menu left
            2:  code_of = {5'd15, 13'd176, 7'd123};   // menu right
            7:  code_of = {5'd15, 13'd48,  7'd12};    // enter
            6:  code_of = {5'd20, 13'd272, 7'd125};   // BACK
            5:  code_of = {5'd15, 13'd48,  7'd83};    // AMP MENU
            4:  code_of = {5'd20, 13'd272, 7'd115};   // options
            default: code_of = 25'd0;
        endcase
    end
endfunction

function frame_is(input integer f, input integer idx);
    reg [24:0] c;
    begin
        c = code_of(idx);
        frame_is = (f_bits[f] == c[24:20]) && (f_data[f] == {c[19:7], c[6:0]});
    end
endfunction

task wait_idle;
    begin
        while (busy) @(negedge clk);
        repeat (3 * T) @(negedge clk);
    end
endtask

task tap(input integer idx);
    integer f, b, a, c;
    reg [24:0] code;
    begin
        nframes = 0;
        keys = 16'd1 << idx; repeat (20) @(negedge clk); keys = 0;
        wait_idle;
        code = code_of(idx); b = code[24:20]; a = code[19:7]; c = code[6:0];
        if (nframes != 3) begin $display("  button %0d: %0d frames (exp 3)", idx, nframes); errors = errors + 1; end
        for (f = 0; f < nframes && f < 64; f = f + 1)
            if (!frame_is(f, idx)) begin
                $display("  button %0d frame %0d: %0d bits data %h (exp %0d bits %h)",
                         idx, f, f_bits[f], f_data[f], b, (a << 7) | c);
                errors = errors + 1;
            end
        $display("  button %2d -> %0d-bit addr %0d cmd %0d x%0d", idx, b, a, c, nframes);
    end
endtask

integer k, f, n_up, n_down, switched;
initial begin
    repeat (50) @(negedge clk);
    if (env || busy || tx) begin $display("  not idle at start"); errors = errors + 1; end

    for (k = 0; k < 16; k = k + 1)
        if (k <= 9 || k == 14 || k == 15) tap(k);

    // Unmapped button: nothing sent.
    nframes = 0; keys = 16'd1 << 11; repeat (5 * T) @(negedge clk); keys = 0; wait_idle;
    if (nframes != 0) begin $display("  unmapped button sent %0d frames", nframes); errors = errors + 1; end

    // Hold R1 (volume -) for ~8 frames: repeats.
    nframes = 0; keys = 16'd1 << 9; repeat (8 * 75 * T) @(negedge clk); keys = 0; wait_idle;
    if (nframes < 8) begin $display("  hold R1: only %0d frames", nframes); errors = errors + 1; end
    for (f = 0; f < nframes && f < 64; f = f + 1)
        if (!frame_is(f, 9)) begin $display("  hold R1 frame %0d wrong", f); errors = errors + 1; end
    $display("  hold R1: %0d frames of volume -", nframes);

    // Hold Up, then switch to Down while frames are still going out.
    nframes = 0;
    keys = 16'd1 << 0; repeat (75 * T + 100) @(negedge clk);
    keys = 16'd1 << 1; repeat (6 * 75 * T) @(negedge clk);
    keys = 0; wait_idle;
    n_up = 0; n_down = 0; switched = 0;
    for (f = 0; f < nframes && f < 64; f = f + 1) begin
        if (frame_is(f, 0)) begin
            n_up = n_up + 1;
            if (switched) begin $display("  Up frame after switching to Down"); errors = errors + 1; end
        end else if (frame_is(f, 1)) begin
            n_down = n_down + 1; switched = 1;
        end else begin
            $display("  switch test: unexpected frame %0d", f); errors = errors + 1;
        end
    end
    if (n_up < 3 || n_up > 4 || n_down < 3) begin
        $display("  switch test: %0d Up then %0d Down", n_up, n_down); errors = errors + 1;
    end
    $display("  switch Up->Down: %0d Up frames then %0d Down frames", n_up, n_down);

    if (errors == 0) $display("PASS tb_ir_remote");
    else             $display("FAIL tb_ir_remote (%0d errors)", errors);
    $finish;
end

endmodule
