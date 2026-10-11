// tb_dev_save.v
// dev_save: boot device from a valid save, else the default / current one;
// re-boot on every reset exit and on a late all-complete; reads latched on
// bridge_rd like APF (address already moved on when sampled), returning the
// loaded words before the first boot and the live device after it; size
// table = 32 bytes; diagnostic words; a save with the older library id
// (LIB_ID_V1) is still used. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_dev_save;

localparam [31:0] ADDR = 32'h1000_0000, LIB = 32'hFD097E4D, MAGIC = 32'h49525331, V1 = 32'h0BADF00D;

reg         clk = 0;
always #5 clk = ~clk;
integer errors = 0;

// four instances, one per scenario, sharing the bridge
reg  [3:0]  reset_n = 0, ac = 0, wr = 0, rdq = 0;
reg  [31:0] addr = 0, wdata = 0;
reg  [7:0]  cur_t = 8'd3;
reg  [15:0] cur_b = 16'd400, cur_s = 16'd17;
wire [3:0]  boot, dt_wren;
wire [31:0] rdata [0:3];
wire [7:0]  bt [0:3];
wire [15:0] bb [0:3], bs [0:3];
wire [9:0]  dt_addr [0:3];
wire [31:0] dt_data [0:3];

genvar g;
generate for (g = 0; g < 4; g = g + 1) begin : inst
    dev_save #(.ADDR(ADDR), .LIB_ID(LIB), .LIB_ID_V1(V1), .BOOT_T(8'd1), .BOOT_B(16'd31), .BOOT_S(16'd0)) ds (
        .clk(clk), .reset_n(reset_n[g]), .allcomplete(ac[g]),
        .bridge_addr(addr), .bridge_wr(wr[g]), .bridge_wr_data(wdata), .bridge_rd(rdq[g]),
        .rd_data(rdata[g]), .cur_t(cur_t), .cur_b(cur_b), .cur_s(cur_s),
        .boot(boot[g]), .boot_t(bt[g]), .boot_b(bb[g]), .boot_s(bs[g]),
        .datatable_addr(dt_addr[g]), .datatable_wren(dt_wren[g]), .datatable_data(dt_data[g]));
end endgenerate

task write(input integer i, input [31:0] a, input [31:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; wr = 4'd1 << i;
        @(negedge clk); wr = 0; addr = 32'h0;
    end
endtask

task save(input integer i, input [31:0] w0, input [31:0] w1, input [31:0] w2, input [31:0] w3);
    begin
        write(i, ADDR, w0); write(i, ADDR + 4, w1); write(i, ADDR + 8, w2); write(i, ADDR + 12, w3);
    end
endtask

// boot pulses and size-table writes, counted per instance
integer nboot [0:3], ndt [0:3];
integer k;
initial for (k = 0; k < 4; k = k + 1) begin nboot[k] = 0; ndt[k] = 0; end
always @(posedge clk) for (k = 0; k < 4; k = k + 1) begin
    if (boot[k]) nboot[k] = nboot[k] + 1;
    if (dt_wren[k]) begin
        ndt[k] = ndt[k] + 1;
        if (dt_addr[k] !== 10'd1 || dt_data[k] !== 32'd32) begin $display("  inst %0d: table write %0d=%0d", k, dt_addr[k], dt_data[k]); errors = errors + 1; end
    end
end

task expect_boot(input integer i, input integer n, input [7:0] t, input [15:0] b, input [15:0] s, input [8*24-1:0] what);
    begin
        if (bt[i] !== t || bb[i] !== b || bs[i] !== s || nboot[i] != n || ndt[i] != n) begin
            $display("  %0s: boot %0d/%0d/%0d (%0d pulses, %0d table writes), exp %0d/%0d/%0d (%0d)", what,
                     bt[i], bb[i], bs[i], nboot[i], ndt[i], t, b, s, n);
            errors = errors + 1;
        end
    end
endtask

// like APF: strobe bridge_rd, move the address on to the next word, sample later
task expect_read(input integer i, input [31:0] a, input [31:0] d);
    begin
        @(negedge clk); addr = a; rdq = 4'd1 << i;
        @(negedge clk); rdq = 0; addr = a + 4;
        repeat (3) @(negedge clk);
        if (rdata[i] !== d) begin $display("  inst %0d read %h: %h exp %h", i, a, rdata[i], d); errors = errors + 1; end
    end
endtask

task pulse_reset(input integer i);
    begin
        @(negedge clk); reset_n[i] = 0; repeat (5) @(negedge clk); reset_n[i] = 1; repeat (5) @(negedge clk);
    end
endtask

initial begin
    repeat (5) @(negedge clk);
    // APF order: load the slot in reset, all complete, reset exit
    save(0, MAGIC, LIB, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd5});             // valid: Samsung TV set 5
    // 1: no file -> nothing written
    save(2, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF);    // new file filled with 0xFF
    save(3, MAGIC, LIB ^ 32'd1, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd5});  // other library build
    write(0, ADDR + 32'h20, 32'h0);                                      // outside the slot: ignored
    // before the first boot, reads return the file as loaded
    expect_read(2, ADDR + 8, 32'hFFFFFFFF);
    expect_read(0, ADDR + 12, {16'd0, 16'd5});
    expect_read(1, ADDR, 32'd0);
    ac = 4'hF;
    repeat (10) @(negedge clk);
    if (boot != 0) begin $display("  boot before reset_n"); errors = errors + 1; end
    reset_n = 4'hF;
    repeat (10) @(negedge clk);
    expect_boot(0, 1, 8'd0, 16'd77, 16'd5, "valid save");
    expect_boot(1, 1, 8'd1, 16'd31, 16'd0, "no file");
    expect_boot(2, 1, 8'd1, 16'd31, 16'd0, "0xFF file");
    expect_boot(3, 1, 8'd1, 16'd31, 16'd0, "other library");

    // reset without a new load: boots again, keeps the current device
    pulse_reset(0);
    expect_boot(0, 2, 8'd3, 16'd400, 16'd17, "reset, no load");
    // reset with a fresh valid load: boots the saved device
    @(negedge clk); reset_n[0] = 0;
    save(0, MAGIC, LIB, {8'd0, 8'd2, 16'd9}, {16'd0, 16'd4});
    repeat (5) @(negedge clk); reset_n[0] = 1; repeat (5) @(negedge clk);
    expect_boot(0, 3, 8'd2, 16'd9, 16'd4, "reset, new load");

    // slots loaded while already running: the all-complete edge boots the save
    ac[1] = 0;
    save(1, MAGIC, LIB, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd1});
    @(negedge clk); ac[1] = 1; repeat (5) @(negedge clk);
    expect_boot(1, 2, 8'd0, 16'd77, 16'd1, "late all-complete");

    // a save from an older build (LIB_ID_V1, same device data) is still used
    @(negedge clk); reset_n[3] = 0;
    save(3, MAGIC, V1, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd5});
    repeat (5) @(negedge clk); reset_n[3] = 1; repeat (5) @(negedge clk);
    expect_boot(3, 2, 8'd0, 16'd77, 16'd5, "older library id");

    // shutdown read-back: the live device, then diagnostics
    expect_read(0, ADDR,      MAGIC);
    expect_read(0, ADDR + 4,  LIB);
    expect_read(0, ADDR + 8,  {8'd0, 8'd3, 16'd400});
    expect_read(0, ADDR + 12, {16'd0, 16'd17});
    cur_t = 8'd0; cur_b = 16'd77; cur_s = 16'd1;
    expect_read(0, ADDR + 8,  {8'd0, 8'd0, 16'd77});
    expect_read(0, ADDR + 12, {16'd0, 16'd1});
    expect_read(0, ADDR + 16, {8'd3, 8'd2, 8'd1, 8'd3});      // 3 exits, 2 enters, 1 all-complete, 3 boots
    expect_read(0, ADDR + 20, {16'd8, 16'd0});                // 8 slot writes (the out-of-slot one ignored), none running
    expect_read(0, ADDR + 24, {8'd0, 8'd2, 16'd9});           // word 2 at the last boot
    expect_read(0, ADDR + 28, {16'd10, 13'd0, 1'b1, 1'b1, 1'b1}); // 10 earlier reads (1 before boot), valid, fresh, booted
    expect_read(1, ADDR + 20, {16'd4, 16'd4});                // instance 1: 4 writes, all while running

    if (errors == 0) $display("PASS tb_dev_save");
    else             $display("FAIL tb_dev_save (%0d errors)", errors);
    $finish;
end

endmodule
