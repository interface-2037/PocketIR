// tb_remote.v
// dev_ctrl (library loader) + ir_remote (buttons, chord, engine) together.
//  1. Load the verified Sony set: code table and text slots must equal
//     build/ir_expected/dev_sony.txt (from tools/ir/test_library.py).
//  2. Every Sony button sends its hardware-verified SIRC code (table below,
//     independent of the library): 3 frames per tap, hold repeats, switching
//     buttons never repeats the old code.
//  3. Start + Select chord: pulses `chord`, sends nothing; Start alone (tap or
//     held) still sends POWER.
//  4. Load Samsung TV set 0: table and slots equal dev_samsung.txt; L1 sends
//     Samsung32 device 7 command 7 (volume +).
// CLK_HZ = 1 MHz (SIRC T = 600 cycles), chord window 20 ms. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_remote;

localparam T = 600;
localparam CHORD = 20_000;           // 20 ms at 1 MHz

reg         clk  = 0;
always #500 clk = ~clk;
reg  [15:0] keys = 0;
reg         load = 0;
reg  [7:0]  dev_t = 0;
reg  [15:0] dev_b = 0, dev_s = 0;
wire        tx, env, busy, chord, dbusy;
wire [3:0]  active_idx, func;
wire        cvalid;
wire [5:0]  cproto;
wire [31:0] cd, cf;
wire        slot_we, str_we;
wire [4:0]  slot_waddr;
wire [31:0] slot_wdata;
wire [9:0]  str_waddr;
wire [7:0]  str_wdata;

dev_ctrl #(.LIB_FILE("src/fpga/core/lib/ir_lib.hex")) dev (
    .clk(clk), .load(load), .dev_t(dev_t), .dev_b(dev_b), .dev_s(dev_s), .busy(dbusy),
    .func(func), .code_valid(cvalid), .code_proto(cproto), .code_d(cd), .code_f(cf),
    .slot_we(slot_we), .slot_waddr(slot_waddr), .slot_wdata(slot_wdata),
    .str_we(str_we), .str_waddr(str_waddr), .str_wdata(str_wdata));

ir_remote #(.PROG_FILE("build/ir_expected/ir_proto_sim.hex"), .CLK_HZ(1_000_000), .CHORD_MS(20)) rem (
    .clk(clk), .keys(keys), .ir_tx(tx), .envelope(env), .busy(busy), .active_idx(active_idx),
    .chord(chord), .code_func(func), .code_valid(cvalid), .code_proto(cproto),
    .code_d(cd), .code_f(cf));

integer errors = 0;

// ---------------- text-layer writes, captured
reg [31:0] slotw [0:31];
reg [7:0]  strm [0:1023];
always @(posedge clk) begin
    if (slot_we) slotw[slot_waddr] <= slot_wdata;
    if (str_we)  strm[str_waddr]  <= str_wdata;
end

// ---------------- chord pulses, counted
integer chords = 0;
always @(posedge clk) if (chord) chords = chords + 1;

// ---------------- SIRC decoder (frame length from the trailing gap)
integer run = 0;
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
            end
        end else if (in_frame && len != T) begin
            finish_frame;
        end
    end
endtask

reg sirc_decode = 1;
always @(negedge clk) begin
    if (env !== prev) begin
        if (sirc_decode) end_run(prev, run);
        run = 1; prev = env;
    end else begin
        run = run + 1;
        if (sirc_decode && !env && in_frame && run == 2 * T) finish_frame;
    end
end

// ---------------- hardware-verified Sony STR-DH790 codes, by Pocket key bit
function [24:0] code_of(input integer idx);   // {nbits, address, command}
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
        repeat (200) @(negedge clk);
        while (busy) @(negedge clk);
        repeat (3 * T) @(negedge clk);
    end
endtask

task tap(input integer idx);
    integer f;
    begin
        nframes = 0;
        keys = 16'd1 << idx; repeat (20) @(negedge clk); keys = 0;
        wait_idle;
        if (nframes != 3) begin $display("  button %0d: %0d frames (exp 3)", idx, nframes); errors = errors + 1; end
        for (f = 0; f < nframes && f < 64; f = f + 1)
            if (!frame_is(f, idx)) begin
                $display("  button %0d frame %0d: %0d bits data %h", idx, f, f_bits[f], f_data[f]);
                errors = errors + 1;
            end
    end
endtask

// ---------------- load a device and compare with its vector file
task load_and_check(input [8*48-1:0] fname);
    integer fd, rc, k, i, v, p, d, fx, w, len, c, bad;
    begin
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            $display("FAIL tb_remote (missing %0s -- run python tools/ir/test_library.py)", fname);
            $finish;
        end
        rc = $fscanf(fd, "%d %d %d\n", dev_t, dev_b, dev_s);
        @(negedge clk); load = 1; @(negedge clk); load = 0;
        repeat (5) @(negedge clk);
        while (dbusy) @(negedge clk);
        repeat (3) @(negedge clk);          // last text writes are registered: let them land
        bad = 0;
        for (k = 0; k < 12; k = k + 1) begin
            rc = $fscanf(fd, "%h %h %h %h\n", v, p, d, fx);
            if (dev.valid[k] !== v[0] || (v && (dev.t_proto[k] !== p || dev.t_d[k] !== d || dev.t_f[k] !== fx))) begin
                if (bad < 4) $display("  %0s func %0d: got %b %0d %h %h exp %0d %0d %h %h", fname, k,
                                      dev.valid[k], dev.t_proto[k], dev.t_d[k], dev.t_f[k], v, p, d, fx);
                bad = bad + 1;
            end
        end
        for (k = 0; k < 11; k = k + 1) begin
            rc = $fscanf(fd, "%h %d", w, len);
            if (slotw[k] !== w) begin $display("  %0s slot %0d word %h exp %h", fname, k, slotw[k], w); bad = bad + 1; end
            for (i = 0; i < len; i = i + 1) begin
                rc = $fscanf(fd, " %h", c);
                if (strm[k * 32 + i] !== c[7:0]) begin
                    if (bad < 8) $display("  %0s slot %0d char %0d: %h exp %h", fname, k, i, strm[k * 32 + i], c[7:0]);
                    bad = bad + 1;
                end
            end
            if (strm[k * 32 + len] !== 8'd0) begin $display("  %0s slot %0d not terminated", fname, k); bad = bad + 1; end
        end
        for (k = 11; k < 32; k = k + 1)
            if (strm[k * 32] !== 8'd0) begin $display("  slot %0d not blanked", k); bad = bad + 1; end
        $fclose(fd);
        errors = errors + bad;
        $display("  loaded %0s: %0d mismatches", fname, bad);
    end
endtask

integer k, f, n_up, n_down, switched, n_pow;
initial begin
    for (k = 0; k < 1024; k = k + 1) strm[k] = 8'hFF;      // so "blanked"/"terminated" checks mean something
    for (k = 0; k < 32; k = k + 1) slotw[k] = 32'hFFFFFFFF;
    repeat (50) @(negedge clk);

    // 1. Sony
    load_and_check("build/ir_expected/dev_sony.txt");

    // 2. every Sony button
    for (k = 0; k < 16; k = k + 1)
        if (k <= 9 || k == 14 || k == 15) tap(k);
    $display("  Sony: 12 buttons tapped");

    nframes = 0; keys = 16'd1 << 9; repeat (8 * 75 * T) @(negedge clk); keys = 0; wait_idle;
    if (nframes < 8) begin $display("  hold R1: only %0d frames", nframes); errors = errors + 1; end
    for (f = 0; f < nframes && f < 64; f = f + 1)
        if (!frame_is(f, 9)) begin $display("  hold R1 frame %0d wrong", f); errors = errors + 1; end

    nframes = 0;
    keys = 16'd1 << 0; repeat (75 * T + 100) @(negedge clk);
    keys = 16'd1 << 1; repeat (6 * 75 * T) @(negedge clk);
    keys = 0; wait_idle;
    n_up = 0; n_down = 0; switched = 0;
    for (f = 0; f < nframes && f < 64; f = f + 1) begin
        if (frame_is(f, 0)) begin
            n_up = n_up + 1;
            if (switched) begin $display("  Up frame after switching to Down"); errors = errors + 1; end
        end else if (frame_is(f, 1)) begin n_down = n_down + 1; switched = 1; end
        else begin $display("  switch test: unexpected frame %0d", f); errors = errors + 1; end
    end
    if (n_up < 3 || n_up > 4 || n_down < 3) begin $display("  switch: %0d Up, %0d Down", n_up, n_down); errors = errors + 1; end

    // 3. chord: both together, and Select then Start 5 ms later -> 2 chords, nothing sent
    nframes = 0; chords = 0;
    keys = 16'hC000; repeat (2 * CHORD) @(negedge clk); keys = 0; wait_idle;
    keys = 16'h4000; repeat (5000) @(negedge clk); keys = 16'hC000; repeat (2 * CHORD) @(negedge clk);
    keys = 0; wait_idle;
    if (chords != 2 || nframes != 0) begin
        $display("  chord: %0d pulses, %0d frames sent (exp 2, 0)", chords, nframes); errors = errors + 1;
    end
    // Start held past the window: POWER repeats while held
    nframes = 0;
    keys = 16'h8000; repeat (CHORD + 5 * 75 * T) @(negedge clk); keys = 0; wait_idle;
    n_pow = 0;
    for (f = 0; f < nframes && f < 64; f = f + 1) if (frame_is(f, 15)) n_pow = n_pow + 1;
    if (nframes < 5 || n_pow != nframes || chords != 2) begin
        $display("  held Start: %0d frames, %0d power", nframes, n_pow); errors = errors + 1;
    end
    $display("  chord: 2 chords sent nothing; held Start sent %0d POWER frames", n_pow);

    // 4. Samsung TV: load, then L1 must hand Samsung32 dev 7 cmd 7 to the engine
    sirc_decode = 0;
    load_and_check("build/ir_expected/dev_samsung.txt");
    keys = 16'd1 << 8; repeat (20) @(negedge clk);
    if (!busy || rem.engine.d_l !== 32'd7 || rem.engine.f_l !== 32'd7 || cproto !== 6'd5) begin
        $display("  Samsung L1: busy %b D %h F %h proto %0d", busy, rem.engine.d_l, rem.engine.f_l, cproto);
        errors = errors + 1;
    end
    keys = 0; wait_idle;

    if (errors == 0) $display("PASS tb_remote");
    else             $display("FAIL tb_remote (%0d errors)", errors);
    $finish;
end

endmodule
