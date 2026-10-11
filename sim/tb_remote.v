// tb_remote.v
// menu (navigation) + dev_ctrl (library) + ir_remote (buttons, chord, engine).
//  1. Boot loads the verified Sony set: code table and text slots equal
//     build/ir_expected/dev_sony.txt (tools/ir/test_library.py).
//  2. Every Sony button sends its hardware-verified SIRC code (table below,
//     independent of the library): 3 frames per tap, hold repeats, switching
//     buttons never repeats the old code.
//  3. Chord: opens / closes the menu and sends nothing; Start alone (held)
//     still sends POWER.
//  4. The menu script build/ir_expected/menu_steps.txt (tools/ui/test_menu.py,
//     from the Python model ui_menu.Menu): after every key or remote button,
//     open/level, the LOAD/CODES commands issued, TEST sends, and the whole
//     page (32 text slots, highlight row, scroll thumb, divider) must match.
//     M9: the home rows, the recent list (recent.v) and learning, where each
//     remote button's captured intervals go to the real lib/ir_match.v over
//     the library ROM (as ir_rx_marks.v would deliver them).
//  5. The script chooses Samsung TV set 1: table and slots equal
//     dev_samsung.txt, and L1 sends Samsung32 device 7 command 7.
//  6. The save slot (dev_save.v) boots Sony when empty and reads back Samsung.
// CLK_HZ = 1 MHz (SIRC T = 600 cycles), chord window 20 ms. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_remote;

`include "ir_lib.vh"
localparam T = 600;
localparam CHORD = 20_000;           // 20 ms at 1 MHz

reg         clk  = 0;
always #500 clk = ~clk;
reg  [15:0] keys = 0;
wire        tx, env, busy, chord, dbusy, mbusy, open, test_key;
wire [3:0]  active_idx, func, bar_row;
wire [15:0] kf;
wire        cvalid;
wire [5:0]  cproto;
wire [31:0] cd, cf;
wire        slot_we, str_we;
wire [4:0]  slot_waddr;
wire [31:0] slot_wdata;
wire [9:0]  str_waddr;
wire [7:0]  str_wdata;
wire        dc_start, dc_dir, scroll_on;
wire [1:0]  dc_cmd;
wire [2:0]  dc_level;
wire [3:0]  div_row;
wire [1:0]  dc_msg, m_result;
wire [7:0]  dc_buttons, ent_t;
wire [15:0] ent_b, ent_s, match_n;
wire [4:0]  recent_n;
wire        listen, rx_hold, m_start, m_narrow, m_done, mt_busy, dl_match;
wire [9:0]  dl_idx;
wire [31:0] dl_recent, dl_mq;
wire [15:0] lib2_addr;
wire [7:0]  lib2_q, iv_addr;
reg         burst = 0;
reg  [8:0]  n_iv = 0;
reg  [15:0] ivmem [0:255];
reg  [15:0] iv_q = 0;
always @(posedge clk) iv_q <= ivmem[iv_addr];
wire [7:0]  dc_t;
wire [15:0] dc_b, dc_s, dc_cur, dc_top, n_items, jump_res;
wire [8:0]  h0, h1;

// save slot: no file was loaded, so it boots the default (Sony)
reg         reset_n = 0;
reg  [31:0] baddr = 0;
reg         brd = 0;
wire [31:0] save_rd;
wire        boot;
wire [7:0]  boot_t, cur_t;
wire [15:0] boot_b, boot_s, cur_b, cur_s;
dev_save #(.LIB_ID(IR_LIB_ID), .LIB_ID_V1(IR_LIB_ID_V1), .BOOT_T(DEV_SONY_T), .BOOT_B(DEV_SONY_B), .BOOT_S(DEV_SONY_S)) sav (
    .clk(clk), .reset_n(reset_n), .allcomplete(1'b1), .bridge_addr(baddr), .bridge_wr(1'b0), .bridge_wr_data(32'd0), .bridge_rd(brd),
    .rd_data(save_rd), .cur_t(cur_t), .cur_b(cur_b), .cur_s(cur_s),
    .boot(boot), .boot_t(boot_t), .boot_b(boot_b), .boot_s(boot_s),
    .datatable_addr(), .datatable_wren(), .datatable_data());

menu #(.CLK_HZ(1_000_000), .BOOT_T(DEV_SONY_T), .BOOT_B(DEV_SONY_B), .BOOT_S(DEV_SONY_S)) mnu (
    .clk(clk), .boot(boot), .boot_t(boot_t), .boot_b(boot_b), .boot_s(boot_s),
    .kf(kf), .chord(chord), .open(open), .busy(mbusy), .test_key(test_key),
    .bar_row(bar_row), .div_row(div_row), .dev_t(cur_t), .dev_b(cur_b), .dev_s(cur_s),
    .dc_start(dc_start), .dc_cmd(dc_cmd), .dc_level(dc_level), .dc_t(dc_t), .dc_b(dc_b), .dc_s(dc_s),
    .dc_cur(dc_cur), .dc_top(dc_top), .dc_dir(dc_dir), .dc_msg(dc_msg), .dc_buttons(dc_buttons),
    .dc_busy(dbusy), .n_items(n_items), .jump_res(jump_res), .ent_t(ent_t), .ent_b(ent_b), .ent_s(ent_s),
    .recent_n(recent_n), .listen(listen), .rx_hold(rx_hold), .burst(burst),
    .m_start(m_start), .m_narrow(m_narrow), .m_done(m_done), .m_result(m_result));

recent #(.LIB_ID(IR_LIB_ID)) rec (
    .clk(clk), .boot(boot), .cur_t(cur_t), .cur_b(cur_b), .cur_s(cur_s), .count(recent_n),
    .idx(dl_idx[4:0]), .entry(dl_recent), .bridge_addr(32'd0), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
    .bridge_rd(1'b0), .rd_data(), .rd_hit());

ir_match #(.PROG_FILE("src/fpga/core/ir/ir_proto.hex")) mtch (
    .clk(clk), .start(m_start), .narrow(m_narrow), .n_iv(n_iv), .iv_addr(iv_addr), .iv_q(iv_q),
    .lib_addr(lib2_addr), .lib_q(lib2_q), .busy(mt_busy), .done(m_done), .result(m_result),
    .n_match(match_n), .list_raddr(dl_idx), .list_q(dl_mq));

dev_ctrl #(.LIB_FILE("src/fpga/core/lib/ir_lib.hex")) dev (
    .clk(clk), .start(dc_start), .cmd(dc_cmd), .level(dc_level), .dev_t(dc_t), .dev_b(dc_b),
    .dev_s(dc_s), .cur(dc_cur), .top(dc_top), .dir(dc_dir), .msg(dc_msg), .buttons(dc_buttons),
    .recent_n(recent_n), .match_n(match_n), .busy(dbusy), .n_items(n_items),
    .dl_idx(dl_idx), .dl_match(dl_match), .dl_q(dl_match ? dl_mq : dl_recent),
    .ent_t(ent_t), .ent_b(ent_b), .ent_s(ent_s), .lib2_addr(lib2_addr), .lib2_q(lib2_q),
    .scroll_on(scroll_on), .scroll_h0(h0), .scroll_h1(h1), .jump_res(jump_res),
    .func(func), .code_valid(cvalid), .code_proto(cproto), .code_d(cd), .code_f(cf),
    .slot_we(slot_we), .slot_waddr(slot_waddr), .slot_wdata(slot_wdata),
    .str_we(str_we), .str_waddr(str_waddr), .str_wdata(str_wdata));

ir_remote #(.PROG_FILE("build/ir_expected/ir_proto_sim.hex"), .CLK_HZ(1_000_000), .CHORD_MS(20)) rem (
    .clk(clk), .keys(keys), .ir_tx(tx), .envelope(env), .busy(busy), .active_idx(active_idx),
    .chord(chord), .keys_filtered(kf), .inhibit(open), .test_key(test_key),
    .code_func(func), .code_valid(cvalid), .code_proto(cproto), .code_d(cd), .code_f(cf));

integer errors = 0;

// ---------------- text-layer writes, dev_ctrl commands, chords, engine starts
reg [31:0] slotw [0:31];
reg [7:0]  strm [0:1023];
reg        saw_load = 0, saw_codes = 0;
integer    last_t = 0, last_b = 0, last_s = 0, chords = 0, sends = 0;
reg        busy_r = 0;
always @(posedge clk) begin
    if (slot_we) slotw[slot_waddr] <= slot_wdata;
    if (str_we)  strm[str_waddr]  <= str_wdata;
    if (dc_start && dc_cmd == 2'd0) begin saw_load = 1;  last_t = dc_t; last_b = dc_b; last_s = dc_s; end
    if (dc_start && dc_cmd == 2'd1) begin saw_codes = 1; last_t = dc_t; last_b = dc_b; last_s = dc_s; end
    if (chord) chords = chords + 1;
    busy_r <= busy;
    if (busy && !busy_r) sends = sends + 1;
end

// ---------------- SIRC decoder (frame length from the trailing gap)
integer run = 0;
reg     prev = 0;
integer nb = 0;
reg [19:0] data = 0;
reg     in_frame = 0;
integer nframes = 0;
reg [19:0] f_data [0:63];
integer    f_bits [0:63];
reg     sirc_decode = 1;

task finish_frame;
    begin
        if (nframes < 64) begin f_data[nframes] = data; f_bits[nframes] = nb; end
        nframes = nframes + 1;
        in_frame = 0;
    end
endtask

always @(negedge clk) begin
    if (env !== prev) begin
        if (sirc_decode) begin
            if (prev) begin
                if (run == 4 * T) begin if (in_frame) finish_frame; in_frame = 1; nb = 0; data = 0; end
                else if (in_frame && (run == T || run == 2 * T)) begin data = data | ((run == 2 * T) << nb); nb = nb + 1; end
            end else if (in_frame && run != T) finish_frame;
        end
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

task settle;                       // until menu, library and engine are all idle
    begin
        repeat (200) @(negedge clk);
        while (mbusy || dbusy || busy || mt_busy || rem.cs != 3'd0) @(negedge clk);
        repeat (3 * T) @(negedge clk);
    end
endtask

task tap(input integer idx);
    integer f;
    begin
        nframes = 0;
        keys = 16'd1 << idx; repeat (20) @(negedge clk); keys = 0;
        settle;
        if (nframes != 3) begin $display("  button %0d: %0d frames (exp 3)", idx, nframes); errors = errors + 1; end
        for (f = 0; f < nframes && f < 64; f = f + 1)
            if (!frame_is(f, idx)) begin $display("  button %0d frame %0d: %0d bits data %h", idx, f, f_bits[f], f_data[f]); errors = errors + 1; end
    end
endtask

// ---------------- compare text slots with a vector block: n lines "word len chars..."
task check_slots(input integer fd, input integer nslots, input [8*16-1:0] what, output integer bad);
    integer rc, k, i, w, len, c;
    begin
        bad = 0;
        for (k = 0; k < nslots; k = k + 1) begin
            rc = $fscanf(fd, "%h %d", w, len);
            if (len != 0 && slotw[k] !== w) begin           // an empty slot draws nothing: word irrelevant
                if (bad < 6) $display("  %0s slot %0d word %h exp %h", what, k, slotw[k], w);
                bad = bad + 1;
            end
            for (i = 0; i < len; i = i + 1) begin
                rc = $fscanf(fd, " %h", c);
                if (strm[k * 32 + i] !== c[7:0]) begin
                    if (bad < 6) $display("  %0s slot %0d char %0d: %h exp %h", what, k, i, strm[k * 32 + i], c[7:0]);
                    bad = bad + 1;
                end
            end
            if (strm[k * 32 + len] !== 8'd0) begin
                if (bad < 6) $display("  %0s slot %0d not terminated", what, k);
                bad = bad + 1;
            end
        end
    end
endtask

task check_device(input [8*48-1:0] fname);
    integer fd, rc, k, v, p, d, fx, bad, b2, dt, db, ds;
    begin
        fd = $fopen(fname, "r");
        if (fd == 0) begin $display("FAIL tb_remote (missing %0s -- run the tools/ tests)", fname); $finish; end
        rc = $fscanf(fd, "%d %d %d\n", dt, db, ds);
        bad = 0;
        for (k = 0; k < 12; k = k + 1) begin
            rc = $fscanf(fd, "%h %h %h %h\n", v, p, d, fx);
            if (dev.valid[k] !== v[0] || (v && (dev.t_proto[k] !== p || dev.t_d[k] !== d || dev.t_f[k] !== fx))) begin
                if (bad < 4) $display("  %0s func %0d: got %b %0d %h %h exp %0d %0d %h %h", fname, k,
                                      dev.valid[k], dev.t_proto[k], dev.t_d[k], dev.t_f[k], v, p, d, fx);
                bad = bad + 1;
            end
        end
        check_slots(fd, 11, "device", b2);
        bad = bad + b2;
        for (k = 11; k < 32; k = k + 1)
            if (strm[k * 32] !== 8'd0) begin $display("  slot %0d not blanked", k); bad = bad + 1; end
        $fclose(fd);
        errors = errors + bad;
        $display("  %0s: %0d mismatches", fname, bad);
    end
endtask

// ---------------- press a menu function (names as in ui_menu.Menu.press)
task press(input [8*8-1:0] key);
    begin
        if (key == "BURST") begin                   // a remote button: intervals already in ivmem
            @(negedge clk) burst = 1; @(negedge clk) burst = 0;
            repeat (20) @(negedge clk);
        end
        else if (key == "CHORD") begin keys = 16'hC000; repeat (100) @(negedge clk); keys = 0; end
        else begin
            keys = (key == "UP")    ? 16'h0002 : (key == "DOWN")  ? 16'h0001 :
                   (key == "LEFT")  ? 16'h0008 : (key == "RIGHT") ? 16'h0004 :
                   (key == "OK")    ? 16'h0080 : (key == "BACK")  ? 16'h0040 :
                   (key == "POWER") ? 16'h8000 : 16'h0000;
            repeat (20) @(negedge clk); keys = 0;
        end
        repeat (CHORD + 15_000) @(negedge clk);      // chord window + TEST pulse
        settle;
    end
endtask

integer fd, rc, nsteps, st, bt, bb, bs, e_open, e_level, e_test, e_load, e_codes, e_t, e_b, e_s;
integer bar, sc, eh0, eh1, ediv, bad, s0, k, f, n_up, n_down, switched, n_pow, niv, x;
reg [8*8-1:0] key;
initial begin
    for (k = 0; k < 1024; k = k + 1) strm[k] = 8'hFF;
    for (k = 0; k < 32; k = k + 1) slotw[k] = 32'hFFFFFFFF;

    // 1. boot: Sony (nothing loads before reset_n)
    repeat (500) @(negedge clk);
    if (saw_load) begin $display("  LOAD before reset_n"); errors = errors + 1; end
    reset_n = 1;
    settle;
    check_device("build/ir_expected/dev_sony.txt");

    // 2. every Sony button, hold, switch
    for (k = 0; k < 16; k = k + 1)
        if (k <= 9 || k == 14 || k == 15) tap(k);
    nframes = 0; keys = 16'd1 << 9; repeat (8 * 75 * T) @(negedge clk); keys = 0; settle;
    if (nframes < 8) begin $display("  hold R1: only %0d frames", nframes); errors = errors + 1; end
    for (f = 0; f < nframes && f < 64; f = f + 1)
        if (!frame_is(f, 9)) begin $display("  hold R1 frame %0d wrong", f); errors = errors + 1; end
    nframes = 0;
    keys = 16'd1 << 0; repeat (75 * T + 100) @(negedge clk);
    keys = 16'd1 << 1; repeat (6 * 75 * T) @(negedge clk);
    keys = 0; settle;
    n_up = 0; n_down = 0; switched = 0;
    for (f = 0; f < nframes && f < 64; f = f + 1) begin
        if (frame_is(f, 0)) begin n_up = n_up + 1; if (switched) errors = errors + 1; end
        else if (frame_is(f, 1)) begin n_down = n_down + 1; switched = 1; end
        else errors = errors + 1;
    end
    if (n_up < 3 || n_up > 4 || n_down < 3) begin $display("  switch: %0d Up, %0d Down", n_up, n_down); errors = errors + 1; end
    $display("  Sony: 12 buttons, hold and switch checked");

    // 3. chord: together -> opens the menu; Select then Start 5 ms later -> closes it; nothing sent
    nframes = 0; chords = 0; sends = 0;
    keys = 16'hC000; repeat (2 * CHORD) @(negedge clk); keys = 0; settle;
    if (!open) begin $display("  chord did not open the menu"); errors = errors + 1; end
    keys = 16'h4000; repeat (5000) @(negedge clk); keys = 16'hC000; repeat (2 * CHORD) @(negedge clk);
    keys = 0; settle;
    if (open || chords != 2 || sends != 0) begin
        $display("  chord: open=%b, %0d pulses, %0d sends (exp 0, 2, 0)", open, chords, sends); errors = errors + 1;
    end
    nframes = 0;
    keys = 16'h8000; repeat (CHORD + 5 * 75 * T) @(negedge clk); keys = 0; settle;
    n_pow = 0;
    for (f = 0; f < nframes && f < 64; f = f + 1) if (frame_is(f, 15)) n_pow = n_pow + 1;
    if (nframes < 5 || n_pow != nframes) begin $display("  held Start: %0d frames, %0d power", nframes, n_pow); errors = errors + 1; end
    $display("  chord: menu opened and closed, nothing sent; held Start sent %0d POWER frames", n_pow);

    // 4. menu script
    sirc_decode = 0;
    fd = $fopen("build/ir_expected/menu_steps.txt", "r");
    if (fd == 0) begin $display("FAIL tb_remote (missing menu_steps.txt -- run python tools/ui/test_menu.py)"); $finish; end
    rc = $fscanf(fd, "%d %d %d %d\n", nsteps, bt, bb, bs);
    for (st = 0; st < nsteps; st = st + 1) begin
        rc = $fscanf(fd, "%s %d %d %d %d %d %d %d %d\n", key, e_open, e_level, e_test, e_load, e_codes, e_t, e_b, e_s);
        if (key == "BURST") begin
            rc = $fscanf(fd, "%d", niv);
            for (k = 0; k < niv; k = k + 1) begin rc = $fscanf(fd, "%d", x); ivmem[k] = x; end
            n_iv = niv;
        end
        saw_load = 0; saw_codes = 0; sends = 0;
        press(key);
        bad = 0;
        if (open !== e_open[0] || (e_open && mnu.level !== e_level)) begin
            $display("  step %0d (%0s): open %b level %0d, exp %0d %0d", st, key, open, mnu.level, e_open, e_level); bad = bad + 1;
        end
        if (saw_codes) begin last_t = ent_t; last_b = ent_b; last_s = ent_s; end   // the device CODES loaded
        if (saw_load !== e_load[0] || saw_codes !== e_codes[0] ||
            ((e_load || e_codes) && (last_t !== e_t || last_b !== e_b || last_s !== e_s))) begin
            $display("  step %0d (%0s): load %b codes %b (%0d %0d %0d), exp %0d %0d (%0d %0d %0d)", st, key,
                     saw_load, saw_codes, last_t, last_b, last_s, e_load, e_codes, e_t, e_b, e_s); bad = bad + 1;
        end
        if (e_open && e_test && sends != 1) begin $display("  step %0d: TEST sent %0d times", st, sends); bad = bad + 1; end
        if (e_open && !e_test && sends != 0) begin $display("  step %0d: menu sent IR without TEST", st); bad = bad + 1; end
        if (e_open) begin
            rc = $fscanf(fd, "%d %d %d %d %d\n", bar, sc, eh0, eh1, ediv);
            if (bar_row !== bar || div_row !== ediv || scroll_on !== sc[0] || (sc && (h0 !== eh0 || h1 !== eh1))) begin
                $display("  step %0d (%0s): bar %0d div %0d scroll %b %0d-%0d, exp %0d %0d %0d %0d-%0d", st, key,
                         bar_row, div_row, scroll_on, h0, h1, bar, ediv, sc, eh0, eh1); bad = bad + 1;
            end
            check_slots(fd, 32, "menu", s0);
            if (s0) $display("  step %0d (%0s): %0d page mismatches", st, key, s0);
            bad = bad + s0;
        end
        errors = errors + bad;
    end
    $fclose(fd);
    $display("  menu: %0d scripted steps checked", nsteps);

    // 5. the script chose Samsung TV set 1
    check_device("build/ir_expected/dev_samsung.txt");
    keys = 16'd1 << 8; repeat (20) @(negedge clk);
    if (!busy || rem.engine.d_l !== 32'd7 || rem.engine.f_l !== 32'd7 || cproto !== 6'd5) begin
        $display("  Samsung L1: busy %b D %h F %h proto %0d", busy, rem.engine.d_l, rem.engine.f_l, cproto);
        errors = errors + 1;
    end
    keys = 0; settle;

    // 6a. core reset (reset exit, no new load) with the menu open: menu closes, Samsung reloads
    keys = 16'hC000; repeat (2 * CHORD) @(negedge clk); keys = 0; settle;
    if (!open) begin $display("  chord did not open the menu before the reset"); errors = errors + 1; end
    saw_load = 0;
    reset_n = 0; repeat (20) @(negedge clk); reset_n = 1; settle;
    if (open || !saw_load || last_t !== DEV_SAMSUNG_T || last_b !== DEV_SAMSUNG_B || last_s !== 1) begin
        $display("  reset: open %b load %b (%0d %0d %0d)", open, saw_load, last_t, last_b, last_s); errors = errors + 1;
    end
    check_device("build/ir_expected/dev_samsung.txt");

    // 6. shutdown read-back of the save slot: Samsung TV set 1
    baddr = 32'h1000_0008; brd = 1; @(negedge clk); brd = 0; baddr = 32'h1000_000C; repeat (3) @(negedge clk);
    if (save_rd !== {8'd0, DEV_SAMSUNG_T, DEV_SAMSUNG_B}) begin
        $display("  save word 2 %h", save_rd); errors = errors + 1;
    end
    baddr = 32'h1000_000C; brd = 1; @(negedge clk); brd = 0; baddr = 32'h1000_0010; repeat (3) @(negedge clk);
    if (save_rd !== 32'd1) begin $display("  save word 3 %h", save_rd); errors = errors + 1; end
    $display("  save slot reads back the chosen device");

    if (errors == 0) $display("PASS tb_remote");
    else             $display("FAIL tb_remote (%0d errors)", errors);
    $finish;
end

endmodule
