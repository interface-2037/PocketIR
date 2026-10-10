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
    parameter PAL_FILE = "core/ui/ui_palette.hex"
) (
    input  wire        clk,             // UI_PIXEL_HZ pixel clock
    input  wire        reset_n,
    input  wire [3:0]  active_region,   // 0 = none (already synchronised to clk)
    input  wire        tx_on,           // already synchronised to clk
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
reg        de1 = 1'b0, de2 = 1'b0, hs1 = 1'b0, hs2 = 1'b0, vs1 = 1'b0, vs2 = 1'b0;

always @(posedge clk) begin
    idx1 <= cur_lit ? cur[15:8] : cur[7:0];
    rgb2 <= pal_rom[idx1];
    de1 <= act0; de2 <= de1; de <= de2;
    hs1 <= hs0;  hs2 <= hs1; hs <= hs2;
    vs1 <= vs0;  vs2 <= vs1; vs <= vs2;
    rgb <= de2 ? rgb2 : 24'd0;
end

endmodule
