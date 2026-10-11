// tb_dev_save.v
// dev_save: the boot device comes from a valid save, else the default; reads
// return the live device; the size table gets 16 bytes. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_dev_save;

localparam [31:0] ADDR = 32'h1000_0000, LIB = 32'hFD097E4D, MAGIC = 32'h49525331;

reg         clk = 0;
always #5 clk = ~clk;
integer errors = 0;

// four instances, one per boot scenario, sharing the bridge
reg         reset_n = 0;
reg  [31:0] addr = 0, wdata = 0;
reg  [3:0]  wr = 0;                    // which instance receives writes
reg  [7:0]  cur_t = 8'd3;
reg  [15:0] cur_b = 16'd400, cur_s = 16'd17;
wire [3:0]  boot, dt_wren;
wire [31:0] rd [0:3];
wire [7:0]  bt [0:3];
wire [15:0] bb [0:3], bs [0:3];
wire [9:0]  dt_addr [0:3];
wire [31:0] dt_data [0:3];

genvar g;
generate for (g = 0; g < 4; g = g + 1) begin : inst
    dev_save #(.ADDR(ADDR), .LIB_ID(LIB), .BOOT_T(8'd1), .BOOT_B(16'd31), .BOOT_S(16'd0)) ds (
        .clk(clk), .reset_n(reset_n), .bridge_addr(addr), .bridge_wr(wr[g]), .bridge_wr_data(wdata),
        .rd_data(rd[g]), .cur_t(cur_t), .cur_b(cur_b), .cur_s(cur_s),
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
        if (dt_addr[k] !== 10'd1 || dt_data[k] !== 32'd16) begin $display("  inst %0d: table write %0d=%0d", k, dt_addr[k], dt_data[k]); errors = errors + 1; end
    end
end

task expect_boot(input integer i, input [7:0] t, input [15:0] b, input [15:0] s, input [8*16-1:0] what);
    begin
        if (bt[i] !== t || bb[i] !== b || bs[i] !== s || nboot[i] != 1 || ndt[i] != 1) begin
            $display("  %0s: boot %0d/%0d/%0d (%0d pulses, %0d table writes), exp %0d/%0d/%0d", what,
                     bt[i], bb[i], bs[i], nboot[i], ndt[i], t, b, s);
            errors = errors + 1;
        end
    end
endtask

task expect_read(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk); addr = a; @(negedge clk); @(negedge clk);
        if (rd[0] !== d) begin $display("  read %h: %h exp %h", a, rd[0], d); errors = errors + 1; end
    end
endtask

initial begin
    repeat (5) @(negedge clk);
    save(0, MAGIC, LIB, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd5});             // valid: Samsung TV set 5
    // 1: no file -> nothing written
    save(2, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF);    // new file filled with 0xFF
    save(3, MAGIC, LIB ^ 32'd1, {8'd0, 8'd0, 16'd77}, {16'd0, 16'd5});  // other library build
    write(0, ADDR + 32'h10, 32'h0);                                      // outside the slot: ignored
    repeat (10) @(negedge clk);
    if (boot != 0) begin $display("  boot before reset_n"); errors = errors + 1; end
    reset_n = 1;
    repeat (10) @(negedge clk);
    expect_boot(0, 8'd0, 16'd77, 16'd5, "valid save");
    expect_boot(1, 8'd1, 16'd31, 16'd0, "no file");
    expect_boot(2, 8'd1, 16'd31, 16'd0, "0xFF file");
    expect_boot(3, 8'd1, 16'd31, 16'd0, "other library");
    // reset again (core reset from the menu): no second boot
    reset_n = 0; repeat (5) @(negedge clk); reset_n = 1; repeat (5) @(negedge clk);
    if (nboot[0] != 1) begin $display("  second boot pulse"); errors = errors + 1; end
    // shutdown read-back: the live device
    expect_read(ADDR,      MAGIC);
    expect_read(ADDR + 4,  LIB);
    expect_read(ADDR + 8,  {8'd0, 8'd3, 16'd400});
    expect_read(ADDR + 12, {16'd0, 16'd17});
    cur_t = 8'd0; cur_b = 16'd77; cur_s = 16'd1;
    expect_read(ADDR + 8,  {8'd0, 8'd0, 16'd77});
    expect_read(ADDR + 12, {16'd0, 16'd1});

    if (errors == 0) $display("PASS tb_dev_save");
    else             $display("FAIL tb_dev_save (%0d errors)", errors);
    $finish;
end

endmodule
