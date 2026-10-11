// tb_sleep.v
// Sleep / wake (sleep_state + dev_save + recent, wired like core_top):
//   0: a running core changes device a few times, then goes to sleep: the
//      start handshake (ack, busy, ok) and the 0x80-byte save state read from
//      the window (device block + recent list, live values).
//   1: wake with the save state written while running, then the load
//      handshake: boots the saved device, the recent list is the saved one
//      (no tracking while it is written), diagnostics say "restore, running";
//      then sleep again.
//   2: wake with the save state written and loaded in reset: the reset exit
//      boots it (one boot), diagnostics say "restore, in reset".
//   3: a save state from another library build: the device and list stay /
//      reset as for a bad save file.
// Bridge reads are latched on bridge_rd like APF (address already moved on).
// The menu is modelled as "current device = boot device, 2 cycles later".
// Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_sleep;

localparam [31:0] DEV = 32'h1000_0000, REC = 32'h1000_8040, SS = 32'h2000_0000;
localparam [31:0] LIB = 32'hFD097E4D, MAGIC = 32'h49525331, RMAGIC = 32'h49524C31;
localparam NI = 4;

reg clk = 0;
always #5 clk = ~clk;
integer errors = 0;

reg  [NI-1:0] reset_n = 0, ac = 0, wr = 0, rdq = 0, ss_start = 0, ss_load = 0;
reg  [31:0]   addr = 0, wdata = 0;
wire [NI-1:0] st_ack, st_busy, st_ok, st_err, ld_ack, ld_busy, ld_ok, ld_err, saved, restore;
wire [NI-1:0] boot, rec_hit, supported;
wire [31:0]   sv_addr [0:NI-1], save_rd [0:NI-1], rec_rd [0:NI-1], ss_addr [0:NI-1], ss_size [0:NI-1];
wire [7:0]    bt [0:NI-1];
wire [15:0]   bb [0:NI-1], bs [0:NI-1];
wire [4:0]    rcount [0:NI-1];
reg  [7:0]    cur_t [0:NI-1];
reg  [15:0]   cur_b [0:NI-1], cur_s [0:NI-1];

genvar g;
generate for (g = 0; g < NI; g = g + 1) begin : inst
    sleep_state #(.ADDR(SS), .SIZE(32'h80), .DEV_ADDR(DEV), .REC_ADDR(REC)) ss (
        .clk(clk), .bridge_addr(addr), .sv_addr(sv_addr[g]),
        .supported(supported[g]), .addr(ss_addr[g]), .size(ss_size[g]), .maxloadsize(),
        .start(ss_start[g]), .start_ack(st_ack[g]), .start_busy(st_busy[g]), .start_ok(st_ok[g]), .start_err(st_err[g]),
        .load(ss_load[g]), .load_ack(ld_ack[g]), .load_busy(ld_busy[g]), .load_ok(ld_ok[g]), .load_err(ld_err[g]),
        .saved(saved[g]), .restore(restore[g]));
    dev_save #(.ADDR(DEV), .LIB_ID(LIB), .BOOT_T(8'd1), .BOOT_B(16'd31), .BOOT_S(16'd0), .SIZE(32'h80A0)) ds (
        .clk(clk), .reset_n(reset_n[g]), .allcomplete(ac[g]), .saved(saved[g]), .restore(restore[g]),
        .bridge_addr(sv_addr[g]), .bridge_wr(wr[g]), .bridge_wr_data(wdata), .bridge_rd(rdq[g]),
        .rd_data(save_rd[g]), .cur_t(cur_t[g]), .cur_b(cur_b[g]), .cur_s(cur_s[g]),
        .boot(boot[g]), .boot_t(bt[g]), .boot_b(bb[g]), .boot_s(bs[g]),
        .datatable_addr(), .datatable_wren(), .datatable_data());
    recent #(.ADDR(REC), .LIB_ID(LIB)) rc (
        .clk(clk), .boot(boot[g]), .cur_t(cur_t[g]), .cur_b(cur_b[g]), .cur_s(cur_s[g]),
        .count(rcount[g]), .idx(5'd0), .entry(),
        .bridge_addr(sv_addr[g]), .bridge_wr(wr[g]), .bridge_wr_data(wdata), .bridge_rd(rdq[g]),
        .rd_data(rec_rd[g]), .rd_hit(rec_hit[g]));
end endgenerate

// menu model: the current device follows the boot device; boots counted
integer nboot [0:NI-1];
integer k;
reg [NI-1:0] boot_d1 = 0, boot_d2 = 0;
initial for (k = 0; k < NI; k = k + 1) begin nboot[k] = 0; cur_t[k] = 8'd1; cur_b[k] = 16'd31; cur_s[k] = 16'd0; end
always @(posedge clk) begin
    boot_d1 <= boot; boot_d2 <= boot_d1;
    for (k = 0; k < NI; k = k + 1) begin
        if (boot[k]) nboot[k] = nboot[k] + 1;
        if (boot_d2[k]) begin cur_t[k] <= bt[k]; cur_b[k] <= bb[k]; cur_s[k] <= bs[k]; end
    end
end

function [31:0] ent(input [7:0] t, input [15:0] b, input [15:0] s);
    ent = {t, b[11:0], s[11:0]};
endfunction

task write(input integer i, input [31:0] a, input [31:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; wr = 1 << i;
        @(negedge clk); wr = 0; addr = 32'h0;
    end
endtask

// core_top's read mux: the window returns the recent list or the device block
reg [31:0] got;
task read(input integer i, input [31:0] a);
    begin
        @(negedge clk); addr = a; rdq = 1 << i;
        @(negedge clk); rdq = 0; addr = a + 4;
        repeat (3) @(negedge clk);
        got = (addr[31:24] == 8'h20) ? (rec_hit[i] ? rec_rd[i] : save_rd[i])
            : (addr[31:24] == 8'h10) ? (rec_hit[i] ? rec_rd[i] : save_rd[i]) : 32'h0;
    end
endtask

// a .sav as APF loads it at start, in reset: device block + recent list
task load_sav(input integer i, input [7:0] t, input [15:0] b, input [15:0] s);
    begin
        write(i, DEV, MAGIC); write(i, DEV + 4, LIB); write(i, DEV + 8, {8'd0, t, b}); write(i, DEV + 12, {16'd0, s});
        write(i, REC, RMAGIC); write(i, REC + 4, LIB); write(i, REC + 8, 32'd1); write(i, REC + 12, 32'd0);
        write(i, REC + 16, ent(t, b, s));
    end
endtask

task start_up(input integer i);
    begin
        @(negedge clk); ac[i] = 1; repeat (3) @(negedge clk); reset_n[i] = 1; repeat (12) @(negedge clk);
    end
endtask

task set_cur(input integer i, input [7:0] t, input [15:0] b, input [15:0] s);
    begin
        @(negedge clk); cur_t[i] = t; cur_b[i] = b; cur_s[i] = s; repeat (8) @(negedge clk);
    end
endtask

// like core_bridge_cmd: hold the request until ack, then drop it; check busy -> ok
task handshake(input integer i, input is_load);
    integer n;
    begin
        @(negedge clk);
        if (is_load) ss_load[i] = 1; else ss_start[i] = 1;
        n = 0;
        while (!(is_load ? ld_ack[i] : st_ack[i]) && n < 20) begin @(negedge clk); n = n + 1; end
        if (n >= 20) begin $display("  inst %0d: no ack (load %0d)", i, is_load); errors = errors + 1; end
        if (!(is_load ? ld_busy[i] : st_busy[i]) || (is_load ? ld_ok[i] : st_ok[i])) begin
            $display("  inst %0d: not busy at ack (load %0d)", i, is_load); errors = errors + 1;
        end
        ss_load[i] = 0; ss_start[i] = 0;
        repeat (3) @(negedge clk);
        if (!(is_load ? ld_ok[i] : st_ok[i]) || ld_busy[i] || st_busy[i] || ld_err[i] || st_err[i]) begin
            $display("  inst %0d: not ok after (load %0d)", i, is_load); errors = errors + 1;
        end
        if (is_load ? st_ok[i] : ld_ok[i]) begin $display("  inst %0d: other ok still set", i); errors = errors + 1; end
        repeat (12) @(negedge clk);
    end
endtask

task expect_dev(input integer i, input integer n, input [7:0] t, input [15:0] b, input [15:0] s, input [8*24-1:0] what);
    begin
        if (cur_t[i] !== t || cur_b[i] !== b || cur_s[i] !== s || nboot[i] != n) begin
            $display("  %0s: device %0d/%0d/%0d after %0d boots, exp %0d/%0d/%0d after %0d", what,
                     cur_t[i], cur_b[i], cur_s[i], nboot[i], t, b, s, n);
            errors = errors + 1;
        end
    end
endtask

reg [31:0] blob [0:31];
reg [31:0] exp_list [0:3];
task expect_list(input integer i, input integer n, input [8*24-1:0] what);
    integer j;
    begin
        read(i, REC + 8);
        if (got !== n || rcount[i] !== n) begin $display("  %0s: count %0d / %0d, exp %0d", what, got, rcount[i], n); errors = errors + 1; end
        for (j = 0; j < n; j = j + 1) begin
            read(i, REC + 16 + 4 * j);
            if (got !== exp_list[j]) begin $display("  %0s: entry %0d = %h, exp %h", what, j, got, exp_list[j]); errors = errors + 1; end
        end
    end
endtask

integer j;
initial begin
    repeat (5) @(negedge clk);
    if (supported !== {NI{1'b1}} || ss_addr[0] !== SS || ss_size[0] !== 32'h80) begin
        $display("  query: supported %b addr %h size %h", supported, ss_addr[0], ss_size[0]); errors = errors + 1;
    end

    // ---- 0. run: start on Samsung 0/77/5, use three more devices, sleep
    load_sav(0, 8'd0, 16'd77, 16'd5);
    start_up(0);
    expect_dev(0, 1, 8'd0, 16'd77, 16'd5, "0: start");
    set_cur(0, 8'd2, 16'd9, 16'd4);
    set_cur(0, 8'd4, 16'd120, 16'd1);
    set_cur(0, 8'd3, 16'd400, 16'd17);
    handshake(0, 0);
    for (j = 0; j < 32; j = j + 1) begin read(0, SS + 4 * j); blob[j] = got; end
    exp_list[0] = ent(8'd3, 16'd400, 16'd17); exp_list[1] = ent(8'd4, 16'd120, 16'd1);
    exp_list[2] = ent(8'd2, 16'd9, 16'd4);    exp_list[3] = ent(8'd0, 16'd77, 16'd5);
    if (blob[0] !== MAGIC || blob[1] !== LIB || blob[2] !== {8'd0, 8'd3, 16'd400} || blob[3] !== {16'd0, 16'd17}) begin
        $display("  0: device block %h %h %h %h", blob[0], blob[1], blob[2], blob[3]); errors = errors + 1;
    end
    if (blob[7][15:12] !== 4'd1 || blob[7][11:8] !== 4'd0) begin $display("  0: diag word 7 %h", blob[7]); errors = errors + 1; end
    if (blob[8] !== RMAGIC || blob[9] !== LIB || blob[10] !== 32'd4 || blob[11] !== 32'd0) begin
        $display("  0: recent header %h %h %h %h", blob[8], blob[9], blob[10], blob[11]); errors = errors + 1;
    end
    for (j = 0; j < 4; j = j + 1)
        if (blob[12 + j] !== exp_list[j]) begin $display("  0: blob entry %0d = %h", j, blob[12 + j]); errors = errors + 1; end
    for (j = 16; j < 32; j = j + 1)
        if (blob[j] !== 32'd0) begin $display("  0: blob word %0d = %h", j, blob[j]); errors = errors + 1; end
    // the window aliases the save file: same words at the save-file addresses
    read(0, DEV + 8);  if (got !== blob[2])  begin $display("  0: alias dev %h", got); errors = errors + 1; end
    read(0, REC + 16); if (got !== blob[12]) begin $display("  0: alias rec %h", got); errors = errors + 1; end

    // ---- 1. wake, save state written while running (the .sav still names Samsung)
    load_sav(1, 8'd0, 16'd77, 16'd5);
    start_up(1);
    expect_dev(1, 1, 8'd0, 16'd77, 16'd5, "1: start");
    for (j = 0; j < 32; j = j + 1) write(1, SS + 4 * j, blob[j]);
    repeat (10) @(negedge clk);
    expect_dev(1, 1, 8'd0, 16'd77, 16'd5, "1: before load");
    handshake(1, 1);
    expect_dev(1, 2, 8'd3, 16'd400, 16'd17, "1: restored");
    expect_list(1, 4, "1: list");
    read(1, DEV + 28);
    if (got[11:8] !== 4'd1 || got[7] !== 1'b0 || got[6] !== 1'b1) begin $display("  1: diag word 7 %h", got); errors = errors + 1; end
    set_cur(1, 8'd5, 16'd6, 16'd7);                       // tracking resumed
    read(1, REC + 16); if (got !== ent(8'd5, 16'd6, 16'd7)) begin $display("  1: not tracking after wake"); errors = errors + 1; end
    handshake(1, 0);                                      // sleep again: load ok cleared, new device saved
    read(1, SS + 8); if (got !== {8'd0, 8'd5, 16'd6}) begin $display("  1: second sleep %h", got); errors = errors + 1; end

    // ---- 2. wake, save state written and loaded in reset
    load_sav(2, 8'd0, 16'd77, 16'd5);
    @(negedge clk); ac[2] = 1;
    for (j = 0; j < 32; j = j + 1) write(2, SS + 4 * j, blob[j]);
    handshake(2, 1);
    if (nboot[2] != 0) begin $display("  2: boot in reset"); errors = errors + 1; end
    @(negedge clk); reset_n[2] = 1; repeat (12) @(negedge clk);
    expect_dev(2, 1, 8'd3, 16'd400, 16'd17, "2: restored");
    expect_list(2, 4, "2: list");
    read(2, DEV + 28);
    if (got[11:8] !== 4'd1 || got[7] !== 1'b1 || got[6] !== 1'b1) begin $display("  2: diag word 7 %h", got); errors = errors + 1; end

    // ---- 3. save state from another library build, written while running
    load_sav(3, 8'd0, 16'd77, 16'd5);
    start_up(3);
    blob[1] = LIB ^ 32'd1; blob[9] = LIB ^ 32'd1;
    for (j = 0; j < 32; j = j + 1) write(3, SS + 4 * j, blob[j]);
    handshake(3, 1);
    expect_dev(3, 2, 8'd0, 16'd77, 16'd5, "3: other library");
    exp_list[0] = ent(8'd0, 16'd77, 16'd5);
    expect_list(3, 1, "3: list cleared");

    if (errors == 0) $display("PASS tb_sleep");
    else             $display("FAIL tb_sleep (%0d errors)", errors);
    $finish;
end

endmodule
