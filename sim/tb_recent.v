// tb_recent.v
// recent (M9): a valid loaded list reads back unchanged before boot and is
// kept at boot; the current device moves to the front (from the middle, from
// the end of a full list, or new with the oldest dropped); an invalid file
// (wrong library id) or no file gives a list of just the current device.
// Checked against a model kept here, through both the menu port and bridge
// reads (latched on bridge_rd, like APF). Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_recent;

localparam [31:0] ADDR = 32'h1000_8040, LIB = 32'hFD097E4D, MAGIC = 32'h49524C31;
localparam N = 20;

reg clk = 0;
always #5 clk = ~clk;
integer errors = 0;

reg         boot = 0, wr = 0, rd = 0;
reg  [7:0]  cur_t = 0;
reg  [15:0] cur_b = 0, cur_s = 0;
reg  [31:0] addr = 0, wdata = 0;
reg  [4:0]  idx = 0;
wire [4:0]  count;
wire [31:0] entry, rd_data;
wire        rd_hit;

recent #(.ADDR(ADDR), .LIB_ID(LIB), .N(N)) dut (
    .clk(clk), .boot(boot), .cur_t(cur_t), .cur_b(cur_b), .cur_s(cur_s),
    .count(count), .idx(idx), .entry(entry),
    .bridge_addr(addr), .bridge_wr(wr), .bridge_wr_data(wdata), .bridge_rd(rd),
    .rd_data(rd_data), .rd_hit(rd_hit));

// ---- model
reg [31:0] m [0:N-1];
integer mc = 0, i, p;
function [31:0] dev(input integer t, input integer b, input integer s);
    dev = {t[7:0], b[11:0], s[11:0]};
endfunction
task mpush(input [31:0] d);
    begin
        p = mc;
        for (i = 0; i < mc; i = i + 1) if (m[i] == d && p == mc) p = i;
        if (p == mc && mc == N) p = N - 1;                  // full: the oldest goes
        else if (p == mc) mc = mc + 1;
        for (i = p; i > 0; i = i - 1) m[i] = m[i - 1];
        m[0] = d;
    end
endtask

task set_cur(input [31:0] d);                               // change device, let it settle
    begin
        @(negedge clk); cur_t = d[31:24]; cur_b = d[23:12]; cur_s = d[11:0];
        repeat (3) @(negedge clk);
    end
endtask
task do_boot;
    begin @(negedge clk) boot = 1; @(negedge clk) boot = 0; repeat (8) @(negedge clk); end
endtask
task write(input [31:0] a, input [31:0] d);
    begin @(negedge clk); addr = a; wdata = d; wr = 1; @(negedge clk); wr = 0; addr = 0; end
endtask
reg [31:0] got;
task read(input [31:0] a);
    begin
        @(negedge clk); addr = a; rd = 1;
        @(negedge clk); rd = 0; addr = a + 4;
        repeat (3) @(negedge clk);
        got = rd_data;
    end
endtask

task check_list(input [8*24-1:0] what);
    begin
        if (count !== mc) begin $display("  %0s: count %0d, expected %0d", what, count, mc); errors = errors + 1; end
        for (i = 0; i < mc; i = i + 1) begin
            idx = i; #1;
            if (entry !== m[i]) begin
                $display("  %0s: entry %0d = %h, expected %h", what, i, entry, m[i]); errors = errors + 1;
            end
        end
        read(ADDR + 8);
        if (got !== mc || !rd_hit) begin $display("  %0s: bridge count %0d", what, got); errors = errors + 1; end
        for (i = 0; i < mc; i = i + 1) begin
            read(ADDR + 16 + 4 * i);
            if (got !== m[i]) begin $display("  %0s: bridge entry %0d = %h", what, i, got); errors = errors + 1; end
        end
    end
endtask

integer k;
initial begin
    // ---- 1. valid file: A B C, read back unchanged before boot
    set_cur(dev(1, 31, 0));
    write(ADDR, MAGIC); write(ADDR + 4, LIB); write(ADDR + 8, 3);
    write(ADDR + 16, dev(0, 77, 0)); write(ADDR + 20, dev(1, 31, 0)); write(ADDR + 24, dev(4, 2, 1));
    m[0] = dev(0, 77, 0); m[1] = dev(1, 31, 0); m[2] = dev(4, 2, 1); mc = 3;
    check_list("loaded, before boot");
    read(ADDR); if (got !== MAGIC) begin $display("  magic %h", got); errors = errors + 1; end
    read(32'h1000_0000); if (rd_hit) begin $display("  device block claimed"); errors = errors + 1; end
    // ---- 2. boot with the current device in the middle: it moves to the front
    do_boot; mpush(dev(1, 31, 0));
    check_list("boot, B to the front");
    // ---- 3. a new device, then 20 more: the oldest drop off
    set_cur(dev(2, 5, 3)); mpush(dev(2, 5, 3));
    check_list("new device");
    for (k = 0; k < 20; k = k + 1) begin set_cur(dev(3, k, k + 1)); mpush(dev(3, k, k + 1)); end
    check_list("full list");
    // ---- 4. the last entry of a full list comes back to the front; then the front again
    set_cur(m[N - 1]); mpush(m[N - 1]);
    check_list("last to front");
    set_cur(m[0]);
    check_list("front again (no change)");
    // ---- 5. restart without a new file: the live list is kept
    do_boot;
    check_list("reset, no reload");
    // ---- 6. file from another library: cleared to the current device
    write(ADDR + 4, 32'h12345678);
    do_boot; mc = 0; mpush({cur_t, cur_b[11:0], cur_s[11:0]});
    check_list("other library");
    // ---- 7. count out of range: cleared
    write(ADDR + 4, LIB); write(ADDR + 8, 25);
    do_boot; mc = 0; mpush({cur_t, cur_b[11:0], cur_s[11:0]});
    check_list("bad count");

    if (errors == 0) $display("PASS tb_recent");
    else             $display("FAIL tb_recent (%0d errors)", errors);
    $finish;
end

endmodule
