// ui_video.v
// M5: video for the remote UI. Resolution, totals and pixel clock come from
// ui_rle.vh, written by tools/ui/ui_rom.py (which also sets video.json and
// the PLL). On hardware, 800x720 corrupted; 640x480 was clean.
//
// Timing: UI_H_TOTAL x UI_V_TOTAL at UI_PIXEL_HZ with minimal blanking. Same
// structure as the core template: VS pulse at x=0,y=0, HS pulse at x=3, DE in
// the active window.
//
// Picture: run-length-encoded ROM made by tools/ui/ui_rom.py. Each word is
// {len-1[7:0], region[3:0], lit[7:0], idle[7:0]} covering len active pixels in
// raster order. A pixel shows its lit palette colour when its region is the
// active button (active_region) or the TX lamp while tx_on; otherwise idle.
// Colours come from a 256 x 24-bit palette ROM.
//
// Pipeline: counters (t) -> palette index (t+1) -> palette RGB (t+2) ->
// output registers (t+3); DE/HS/VS are delayed to match.
// The RLE stream restarts every frame on the line before active video and is
// prefetched through a 4-entry FIFO, so 1-pixel runs back to back are fine.

module ui_video #(
    parameter RLE_FILE = "core/ui/ui_rle.hex",
    parameter PAL_FILE = "core/ui/ui_palette.hex",
    parameter FONT_SMALL_FILE = "core/ui/font_small.bin",
    parameter FONT_BIG_FILE   = "core/ui/font_big.bin",
    parameter FONT_ADV_FILE   = "core/ui/font_adv.bin",
    parameter SLOTS_FILE      = "core/ui/text_slots.hex",
    parameter STR_FILE        = "core/ui/text_str.hex"
) (
    input  wire        clk,             // UI_PIXEL_HZ pixel clock
    input  wire        reset_n,
    input  wire [3:0]  active_region,   // 0 = none (already synchronised to clk)
    input  wire        tx_on,           // already synchronised to clk
    // text layer (ui_text.v), clk_sys domain
    input  wire        clk_sys,
    input  wire [3:0]  active_region_sys,
    input  wire        slot_we,
    input  wire [4:0]  slot_waddr,
    input  wire [31:0] slot_wdata,
    input  wire        str_we,
    input  wire [9:0]  str_waddr,
    input  wire [7:0]  str_wdata,
    // device menu (clk_sys domain; taken over once per frame)
    input  wire        menu_on_sys,
    input  wire [3:0]  menu_bar_sys,      // highlighted row 0..8, 15 = none
    input  wire        menu_scroll_sys,   // draw the scroll thumb
    input  wire [8:0]  menu_h0_sys,       // thumb rows [h0, h1)
    input  wire [8:0]  menu_h1_sys,
    output reg  [23:0] rgb = 24'd0,
    output reg         de  = 1'b0,
    output reg         hs  = 1'b0,
    output reg         vs  = 1'b0,
    output wire        skip,
    output reg         underflow = 1'b0 // sticky: stream ran dry (sim check)
);

`include "ui_rle.vh"

localparam H_TOTAL  = UI_H_TOTAL, H_BPORCH = UI_H_BPORCH, H_ACTIVE = UI_H_ACTIVE;
localparam V_TOTAL  = UI_V_TOTAL, V_BPORCH = UI_V_BPORCH, V_ACTIVE = UI_V_ACTIVE;
localparam TX_REGION = 4'd13;
localparam AW = $clog2(UI_RLE_WORDS);

assign skip = 1'b0;

// ------------------------------------------------------------- ROMs
reg [27:0] rle_rom [0:UI_RLE_WORDS-1];
reg [23:0] pal_rom [0:255];
initial begin
    $readmemh(RLE_FILE, rle_rom);
    $readmemh(PAL_FILE, pal_rom);
end

// ------------------------------------------------------------- timing
reg [9:0] x = 10'd0, y = 10'd0;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        x <= 10'd0; y <= 10'd0;
    end else if (x == H_TOTAL - 1) begin
        x <= 10'd0;
        y <= (y == V_TOTAL - 1) ? 10'd0 : y + 1'b1;
    end else begin
        x <= x + 1'b1;
    end
end

wire act0 = (x >= H_BPORCH) && (x < H_BPORCH + H_ACTIVE) &&
            (y >= V_BPORCH) && (y < V_BPORCH + V_ACTIVE);
wire vs0  = (x == 0) && (y == 0);
wire hs0  = (x == 3);
wire restart = (x == 0) && (y == V_BPORCH - 1);   // one line before active video

// ------------------------------------------------------------- RLE fetch
reg [AW:0]  rd_addr  = 0;
reg         rd_valid = 1'b0;       // a ROM read issued last cycle
reg [27:0]  rd_data;
reg [27:0]  fifo [0:3];
reg [2:0]   count = 3'd0;

always @(posedge clk) rd_data <= rle_rom[rd_addr[AW-1:0]];

// consumer state
reg [27:0]  cur = 28'd0;
reg [7:0]   cur_rem = 8'd0;
reg         cur_valid = 1'b0;

wire issue = !restart && (count + rd_valid < 3'd4) && (rd_addr < UI_RLE_WORDS);
wire pop   = !restart && (count != 0) && (!cur_valid || (act0 && cur_rem == 0));
wire push  = !restart && rd_valid;

integer i;
always @(posedge clk) begin
    if (restart) begin
        rd_addr   <= 0;
        rd_valid  <= 1'b0;
        count     <= 3'd0;
        cur_valid <= 1'b0;
    end else begin
        rd_valid <= issue;
        if (issue) rd_addr <= rd_addr + 1'b1;

        // FIFO: pop from the head, push at the tail (after the pop shift)
        if (pop)
            for (i = 0; i < 3; i = i + 1) fifo[i] <= fifo[i + 1];
        if (push)
            fifo[count - pop] <= rd_data;
        count <= count + push - pop;

        // current run
        if (pop) begin
            cur       <= fifo[0];
            cur_rem   <= fifo[0][27:20];
            cur_valid <= 1'b1;
        end else if (act0 && cur_valid) begin
            if (cur_rem == 0) cur_valid <= 1'b0;
            else              cur_rem <= cur_rem - 1'b1;
        end
        if (act0 && !cur_valid) underflow <= 1'b1;
    end
end

// ------------------------------------------------------------- pixel pipeline
wire [3:0] cur_region = cur[19:16];
wire       cur_lit    = (cur_region != 0) &&
                        ((cur_region == active_region) || (cur_region == TX_REGION && tx_on));

reg [7:0]  idx1 = 8'd0;
reg [23:0] rgb2 = 24'd0;

// ------------------------------------------------------------- text layer
// Line request: at x = 0 of every line, ask for the visible line shown next.
reg        req_toggle = 1'b0;
reg [9:0]  req_line = 10'd0;
always @(posedge clk) if (x == 0) begin
    req_toggle <= ~req_toggle;
    req_line   <= y - V_BPORCH + 1'b1;
end
wire [9:0] vy = y - V_BPORCH;
wire [8:0] vx = x - H_BPORCH;
wire [7:0] text1;                         // {colour, alpha}: pixel t, valid at t+1
reg  [7:0] text2 = 8'd0;                  // aligned with rgb2 (t+2)

ui_text #(
    .FONT_SMALL_FILE(FONT_SMALL_FILE), .FONT_BIG_FILE(FONT_BIG_FILE),
    .FONT_ADV_FILE(FONT_ADV_FILE), .SLOTS_FILE(SLOTS_FILE), .STR_FILE(STR_FILE)
) text (
    .clk_sys(clk_sys), .active_region(active_region_sys),
    .slot_we(slot_we), .slot_waddr(slot_waddr), .slot_wdata(slot_wdata),
    .str_we(str_we), .str_waddr(str_waddr), .str_wdata(str_wdata),
    .clk_vid(clk), .vid_req_toggle(req_toggle), .vid_req_line(req_line),
    .vid_bank(vy[0]), .vid_x(vx), .vid_text(text1));

`include "ui_text.vh"
reg [23:0] fg;
always @(*) case (text2[7:5])
    3'd0: fg = TXT_COL0; 3'd1: fg = TXT_COL1; 3'd2: fg = TXT_COL2;
    3'd3: fg = TXT_COL3; 3'd4: fg = TXT_COL4; default: fg = TXT_COL5;
endcase

// pixel = (background * (16 - a) + colour * a) >> 4  (a = 0..16), as ui_text.py
function [7:0] mix(input [7:0] b, input [7:0] c, input [4:0] a);
    reg [12:0] sum;
begin
    sum = b * (5'd16 - a) + c * a;
    mix = sum[11:4];
end
endfunction
reg        de1 = 1'b0, de2 = 1'b0, hs1 = 1'b0, hs2 = 1'b0, vs1 = 1'b0, vs2 = 1'b0;

always @(posedge clk) begin
    idx1 <= cur_lit ? cur[15:8] : cur[7:0];
    rgb2 <= pal_rom[idx1];
    de1 <= act0; de2 <= de1; de <= de2;
    hs1 <= hs0;  hs2 <= hs1; hs <= hs2;
    vs1 <= vs0;  vs2 <= vs1; vs <= vs2;
    text2 <= text1;
    menu1 <= menu_px; menu2 <= menu1;
    rgb <= de2 ? {mix(bg2[23:16], fg[23:16], text2[4:0]),
                  mix(bg2[15:8],  fg[15:8],  text2[4:0]),
                  mix(bg2[7:0],   fg[7:0],   text2[4:0])} : 24'd0;
end

// ------------------------------------------------------------- menu background
// Menu settings cross from clk_sys with a 2-flop synchroniser per bit and are
// taken over at the start of each frame, so a frame never mixes old and new.
`include "ui_menu.vh"
reg [23:0] ms1 = 0, ms2 = 0;              // {on, bar[3:0], scroll, h0[8:0], h1[8:0]}
reg        m_on = 1'b0, m_scroll = 1'b0;
reg [3:0]  m_bar = 4'd15;
reg [8:0]  m_h0 = 0, m_h1 = 0;
always @(posedge clk) begin
    ms1 <= {menu_on_sys, menu_bar_sys, menu_scroll_sys, menu_h0_sys, menu_h1_sys};
    ms2 <= ms1;
    if (vs0) {m_on, m_bar, m_scroll, m_h0, m_h1} <= ms2;
end

// colour of pixel t (vx, vy) in menu mode; aligned with the picture at t+2
wire in_x   = (vx >= MENU_BAR_X0) && (vx < MENU_BAR_X1);
wire [9:0] bar_y0 = MENU_ROW_Y0 - 10'd12 + m_bar * MENU_ROW_H;
wire on_bar = (m_bar != 4'd15) && in_x && (vy >= bar_y0) && (vy < bar_y0 + 10'd24);
wire on_sep = in_x && (vy == MENU_SEP_Y0 || vy == MENU_SEP_Y1);
wire on_thm = m_scroll && (vx == MENU_SCROLL_X || vx == MENU_SCROLL_X + 1) && (vy >= m_h0) && (vy < m_h1);
wire [24:0] menu_px = {m_on, on_bar ? TXT_COL4 : on_thm ? TXT_COL3 : on_sep ? MENU_BAR : MENU_BG};
reg  [24:0] menu1 = 0, menu2 = 0;
wire [23:0] bg2 = menu2[24] ? menu2[23:0] : rgb2;

endmodule
