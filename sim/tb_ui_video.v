// tb_ui_video.v
// Runs ui_video (picture + text layer) for two frames and compares every
// active pixel with the frames tools/ui/ui_rom.py + ui_text.py expect: idle, then ENTER pressed + TX lit.
// Also checks frame geometry (active and total sizes from ui_rle.vh) and that
// the RLE stream never runs dry. Writes the captured frames to sim/out/ for
// viewing (tools/ui/frame_to_png.py). Prints PASS or FAIL.
//
// Needs build/ui_expected/*.hex: run  python tools/ui/ui_rom.py  first.

`timescale 1ns/1ps

module tb_ui_video;

`include "ui_rle.vh"
localparam W = UI_H_ACTIVE, H = UI_V_ACTIVE, N = W * H;
localparam real HALF_NS = 1.0e9 / (2.0 * UI_PIXEL_HZ);
localparam REGION_ENTER = 4'd8;     // key bit 7 + 1
localparam REGION_TX    = 4'd13;

reg clk = 0;
always #(HALF_NS) clk = ~clk;
reg clk_sys = 0;
always #6.734 clk_sys = ~clk_sys;      // 74.25 MHz (text layer renderer)
reg [3:0] region_sys = 0;

reg  [3:0]  region = 0;
reg         tx     = 0;
wire [23:0] rgb;
wire        de, hs, vs, skip, underflow;

ui_video #(
    .RLE_FILE("src/fpga/core/ui/ui_rle.hex"),
    .PAL_FILE("src/fpga/core/ui/ui_palette.hex"),
    .FONT_SMALL_FILE("src/fpga/core/ui/font_small.bin"),
    .FONT_BIG_FILE("src/fpga/core/ui/font_big.bin"),
    .FONT_ADV_FILE("src/fpga/core/ui/font_adv.bin"),
    .SLOTS_FILE("src/fpga/core/ui/text_slots.hex"),
    .STR_FILE("src/fpga/core/ui/text_str.hex")
) dut (
    .clk(clk), .reset_n(1'b1), .active_region(region), .tx_on(tx),
    .clk_sys(clk_sys), .active_region_sys(region_sys),
    .slot_we(slot_we), .slot_waddr(slot_waddr), .slot_wdata(slot_wdata),
    .str_we(str_we), .str_waddr(str_waddr), .str_wdata(str_wdata),
    .menu_on_sys(menu_on), .menu_bar_sys(menu_bar), .menu_scroll_sys(menu_scroll),
    .menu_h0_sys(menu_h0), .menu_h1_sys(menu_h1),
    .rgb(rgb), .de(de), .hs(hs), .vs(vs), .skip(skip), .underflow(underflow));

reg [23:0] exp_idle  [0:N-1];
reg [23:0] exp_enter [0:N-1];
reg [23:0] exp_menu  [0:N-1];
// text-layer writes and menu inputs, driven on clk_sys like dev_ctrl.v does
reg        slot_we = 0, str_we = 0, menu_on = 0, menu_scroll = 0;
reg [4:0]  slot_waddr = 0;
reg [31:0] slot_wdata = 0;
reg [9:0]  str_waddr = 0;
reg [7:0]  str_wdata = 0;
reg [3:0]  menu_bar = 4'd15;
reg [8:0]  menu_h0 = 0, menu_h1 = 0;

task write_menu_page;                   // build/ui_expected/menu_page.txt -> slots + menu inputs
    integer fd, rc, k, i, w, len, c, bar, sc, h0, h1;
    begin
        fd = $fopen("build/ui_expected/menu_page.txt", "r");
        rc = $fscanf(fd, "%d %d %d %d", bar, sc, h0, h1);
        for (k = 0; k < 32; k = k + 1) begin
            rc = $fscanf(fd, "%h %d", w, len);
            @(negedge clk_sys); slot_we = 1; slot_waddr = k; slot_wdata = w;
            @(negedge clk_sys); slot_we = 0;
            for (i = 0; i <= len; i = i + 1) begin
                if (i < len) rc = $fscanf(fd, " %h", c); else c = 0;
                @(negedge clk_sys); str_we = 1; str_waddr = k * 32 + i; str_wdata = c;
                @(negedge clk_sys); str_we = 0;
            end
        end
        $fclose(fd);
        menu_bar = bar; menu_scroll = sc; menu_h0 = h0; menu_h1 = h1; menu_on = 1;
    end
endtask
integer errors = 0;

task run_frame(input integer which, input integer fd);
    integer k, bad, cycles, lines, line_px;
    reg     prev_de;
    reg [23:0] e;
    begin
        k = 0; bad = 0; cycles = 0; lines = 0; line_px = 0; prev_de = 0;
        @(posedge vs);
        @(negedge clk);
        while (!vs || cycles == 0) begin
            cycles = cycles + 1;
            if (de) begin
                e = (which == 2) ? exp_menu[k] : which ? exp_enter[k] : exp_idle[k];
                if (k < N && rgb !== e) begin
                    if (bad < 5) $display("  frame %0d pixel %0d (x %0d y %0d): got %h exp %h",
                                          which, k, k % W, k / W, rgb, e);
                    bad = bad + 1;
                end
                $fwrite(fd, "%h\n", rgb);
                k = k + 1; line_px = line_px + 1;
            end
            if (prev_de && !de) begin
                if (line_px != W) begin $display("  line %0d has %0d pixels", lines, line_px); errors = errors + 1; end
                lines = lines + 1; line_px = 0;
            end
            prev_de = de;
            @(negedge clk);
        end
        if (k != N || lines != H) begin
            $display("  frame %0d: %0d pixels in %0d lines (exp %0d in %0d)", which, k, lines, N, H);
            errors = errors + 1;
        end
        if (cycles != UI_H_TOTAL * UI_V_TOTAL) begin
            $display("  frame %0d: %0d clocks per frame (exp %0d)", which, cycles, UI_H_TOTAL * UI_V_TOTAL);
            errors = errors + 1;
        end
        $display("  frame %0d (%s): %0d mismatching pixels", which, which == 2 ? "menu" : which ? "ENTER + TX" : "idle", bad);
        errors = errors + bad;
    end
endtask

integer fd0, fd1, fd2;
initial begin
    fd0 = $fopen("build/ui_expected/idle.hex", "r");
    if (fd0 == 0) begin
        $display("FAIL tb_ui_video (missing build/ui_expected -- run python tools/ui/ui_rom.py)");
        $finish;
    end
    $fclose(fd0);
    $readmemh("build/ui_expected/idle.hex", exp_idle);
    $readmemh("build/ui_expected/enter.hex", exp_enter);
    $readmemh("build/ui_expected/menu.hex", exp_menu);

    fd0 = $fopen("sim/out/ui_frame_idle.hex", "w");
    fd1 = $fopen("sim/out/ui_frame_enter.hex", "w");

    @(posedge vs);                  // let the first partial frame pass
    run_frame(0, fd0);              // starts at the next VS
    region = REGION_ENTER; tx = 1;  // change during VS (blanking)
    region_sys = REGION_ENTER;       // text layer: ENTER label lit
    run_frame(1, fd1);
    // frame 2: device menu (TV brands, cursor on SAMSUNG): page written, menu mode on
    region = 0; tx = 0; region_sys = 0;
    write_menu_page;
    @(posedge vs);                  // let the page land and the menu inputs take effect
    fd2 = $fopen("sim/out/ui_frame_menu.hex", "w");
    run_frame(2, fd2);
    $fclose(fd0); $fclose(fd1); $fclose(fd2);

    if (underflow) begin $display("  RLE stream underflow"); errors = errors + 1; end
    if (errors == 0) $display("PASS tb_ui_video");
    else             $display("FAIL tb_ui_video (%0d errors)", errors);
    $finish;
end

endmodule
