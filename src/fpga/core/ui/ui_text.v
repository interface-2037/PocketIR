// ui_text.v
// Runtime text layer (M7). Draws up to 32 text slots into a line buffer one
// line ahead of the video beam; the video side blends the buffer over the
// picture. Reference model and data generator: tools/ui/ui_text.py (the
// mockups use the same code, so the output is pixel-exact).
//
// Clocks
//   clk_sys (74.25 MHz): slot/string RAMs, fonts, renderer, line-buffer write
//   clk_vid (pixel)    : line-buffer read; line requests arrive as a toggle
//
// Line protocol: at the start of every video line the video side flips
// vid_req_toggle and holds vid_req_line = the visible line it will show next.
// The renderer clears that line's buffer bank (line & 1) and draws every slot
// that covers it, finishing well inside one line time (~3300 sys clocks).
//
// Slot word (text_slots.hex / slot_wdata):
//   [8:0] y_top  [17:9] x  [19:18] align (0 left, 1 centre, 2 right)
//   [20] font (0 small, 1 big)  [23:21] colour id  [26:24] lit colour id
//   [30:27] lit region (0 = never lit)
// Slot text: 32 bytes per slot in the string RAM, NUL-terminated (empty = off).
// Line-buffer pixel: {colour id[2:0], alpha[4:0]} with alpha 0..16.

module ui_text #(
    parameter FONT_SMALL_FILE = "core/ui/font_small.bin",
    parameter FONT_BIG_FILE   = "core/ui/font_big.bin",
    parameter FONT_ADV_FILE   = "core/ui/font_adv.bin",
    parameter SLOTS_FILE      = "core/ui/text_slots.hex",
    parameter STR_FILE        = "core/ui/text_str.hex"
) (
    input  wire        clk_sys,
    input  wire [3:0]  active_region,     // clk_sys domain: which button is lit
    // future controller (menu / library): rewrite slots and strings
    input  wire        slot_we,
    input  wire [4:0]  slot_waddr,
    input  wire [31:0] slot_wdata,
    input  wire        str_we,
    input  wire [9:0]  str_waddr,
    input  wire [7:0]  str_wdata,

    input  wire        clk_vid,
    input  wire        vid_req_toggle,    // flips at every line start
    input  wire [9:0]  vid_req_line,      // visible line to prepare
    input  wire        vid_bank,          // bank of the line being shown (line & 1)
    input  wire [8:0]  vid_x,             // visible x being fetched
    output reg  [7:0]  vid_text = 8'd0    // {colour, alpha}, one clk_vid later
);

`include "ui_text.vh"

localparam W = 400, LINES = 360;

// ------------------------------------------------------------------ memories
reg [4:0]  font_s [0:64*TXT_H_SMALL*16-1];
reg [4:0]  font_b [0:64*TXT_H_BIG*16-1];
reg [4:0]  adv_rom [0:127];
reg [31:0] slots [0:31];
reg [7:0]  strs [0:1023];
reg [7:0]  lb [0:1023];                      // 2 banks x 512 (x < 400 used)
initial begin
    $readmemb(FONT_SMALL_FILE, font_s);           // 5-bit binary: matches the ROM width
    $readmemb(FONT_BIG_FILE, font_b);
    $readmemb(FONT_ADV_FILE, adv_rom);
    $readmemh(SLOTS_FILE, slots);
    $readmemh(STR_FILE, strs);
end

reg [13:0] fs_addr = 0;  reg [4:0] fs_q = 0;
reg [14:0] fb_addr = 0;  reg [4:0] fb_q = 0;
reg [6:0]  adv_addr = 0; reg [4:0] adv_q = 0;
reg [4:0]  slot_raddr = 0; reg [31:0] slot_q = 0;
reg [9:0]  str_raddr = 0;  reg [7:0]  str_q = 0;
reg        lb_we = 1'b0; reg [9:0] lb_waddr = 0; reg [7:0] lb_wdata = 0;

always @(posedge clk_sys) begin
    fs_q  <= font_s[fs_addr];
    fb_q  <= font_b[fb_addr];
    adv_q <= adv_rom[adv_addr];
    if (slot_we) slots[slot_waddr] <= slot_wdata;
    slot_q <= slots[slot_raddr];
    if (str_we) strs[str_waddr] <= str_wdata;
    str_q <= strs[str_raddr];
    if (lb_we) lb[lb_waddr] <= lb_wdata;
end

always @(posedge clk_vid) vid_text <= lb[{vid_bank, vid_x}];

// ------------------------------------------------------------------ line request sync
reg [2:0] tg = 3'd0;
always @(posedge clk_sys) tg <= {tg[1:0], vid_req_toggle};
wire req = tg[2] ^ tg[1];

// ------------------------------------------------------------------ renderer
// Every memory read takes one wait state (address registered, data next cycle).
localparam R_IDLE = 5'd0,  R_CLEAR = 5'd1, R_SLOT = 5'd2,  R_SLOTW = 5'd3, R_CHK = 5'd4,
           R_WCH = 5'd5,   R_WCHW = 5'd6,  R_WGOT = 5'd7,  R_WADVW = 5'd8, R_WADD = 5'd9,
           R_X0 = 5'd10,   R_DCH = 5'd11,  R_DCHW = 5'd12, R_DGOT = 5'd13, R_DADVW = 5'd14,
           R_DADV = 5'd15, R_PIX = 5'd16,  R_PIXW = 5'd17, R_PIXU = 5'd18, R_NEXT = 5'd19;
reg [4:0]  rs = R_IDLE;
reg [9:0]  line = 0;
reg [8:0]  cx = 0;                // clear counter
reg [4:0]  s = 0;                 // slot index
reg [8:0]  sx = 0;
reg [1:0]  align = 0;
reg        font = 0;
reg [2:0]  colour = 0;
reg [4:0]  row = 0;
reg [5:0]  i = 0;                 // char index in the slot string
reg [5:0]  g = 0;                 // glyph index
reg [9:0]  width = 0;
reg signed [10:0] px = 0;         // current pixel x (may start negative)
reg [4:0]  adv = 0, col = 0;
reg [10:0] rowbase = 0;           // glyph * height + row

wire [4:0] h_slot = slot_q[20] ? TXT_H_BIG[4:0] : TXT_H_SMALL[4:0];
wire [4:0] alpha  = font ? fb_q : fs_q;

always @(posedge clk_sys) begin
    lb_we <= 1'b0;
    if (req) begin                                   // a new line request restarts the renderer
        line <= vid_req_line;
        cx   <= 9'd0;
        rs   <= (vid_req_line < LINES) ? R_CLEAR : R_IDLE;
    end else case (rs)
        R_IDLE: ;
        R_CLEAR: begin                               // clear this line's bank
            lb_we <= 1'b1; lb_waddr <= {line[0], cx}; lb_wdata <= 8'd0;
            cx <= cx + 1'b1;
            if (cx == W - 1) begin s <= 5'd0; rs <= R_SLOT; end
        end
        R_SLOT:  begin slot_raddr <= s; rs <= R_SLOTW; end
        R_SLOTW: rs <= R_CHK;
        R_CHK: begin
            sx     <= slot_q[17:9];
            align  <= slot_q[19:18];
            font   <= slot_q[20];
            colour <= (slot_q[30:27] != 4'd0 && slot_q[30:27] == active_region) ? slot_q[26:24] : slot_q[23:21];
            row    <= line - slot_q[8:0];
            i      <= 6'd0;
            width  <= 10'd0;
            rs     <= (line >= slot_q[8:0] && line < slot_q[8:0] + h_slot) ? R_WCH : R_NEXT;
        end
        // ---- width pass: sum the string's advances
        R_WCH:   begin str_raddr <= {s, 5'd0} + i; rs <= R_WCHW; end
        R_WCHW:  rs <= R_WGOT;
        R_WGOT:  if (str_q == 8'd0 || i == 6'd32) rs <= R_X0;
                 else begin adv_addr <= {font, str_q[5:0] - 6'd32}; rs <= R_WADVW; end
        R_WADVW: rs <= R_WADD;
        R_WADD:  begin width <= width + adv_q; i <= i + 1'b1; rs <= R_WCH; end
        R_X0: begin
            case (align)
                2'd1:    px <= $signed({2'b00, sx}) - $signed({2'b00, width[9:1]});
                2'd2:    px <= $signed({2'b00, sx}) - $signed({1'b0, width});
                default: px <= $signed({2'b00, sx});
            endcase
            i  <= 6'd0;
            rs <= R_DCH;
        end
        // ---- draw pass
        R_DCH:   begin str_raddr <= {s, 5'd0} + i; rs <= R_DCHW; end
        R_DCHW:  rs <= R_DGOT;
        R_DGOT:  if (str_q == 8'd0 || i == 6'd32) rs <= R_NEXT;
                 else begin
                     g <= str_q[5:0] - 6'd32;
                     adv_addr <= {font, str_q[5:0] - 6'd32};
                     rs <= R_DADVW;
                 end
        R_DADVW: rs <= R_DADV;
        R_DADV: begin
            adv     <= adv_q;
            col     <= 5'd0;
            rowbase <= g * (font ? TXT_H_BIG[4:0] : TXT_H_SMALL[4:0]) + row;
            if (adv_q == 5'd0) begin i <= i + 1'b1; rs <= R_DCH; end
            else rs <= R_PIX;
        end
        R_PIX: begin
            fs_addr <= {rowbase[9:0], col[3:0]};
            fb_addr <= {rowbase, col[3:0]};
            rs <= R_PIXW;
        end
        R_PIXW: rs <= R_PIXU;
        R_PIXU: begin
            if (alpha != 5'd0 && px >= 0 && px < W) begin
                lb_we    <= 1'b1;
                lb_waddr <= {line[0], px[8:0]};
                lb_wdata <= {colour, alpha};
            end
            px  <= px + 1'b1;
            col <= col + 1'b1;
            if (col + 1'b1 == adv) begin i <= i + 1'b1; rs <= R_DCH; end
            else rs <= R_PIX;
        end
        R_NEXT: if (s == 5'd31) rs <= R_IDLE; else begin s <= s + 1'b1; rs <= R_SLOT; end
        default: rs <= R_IDLE;
    endcase
end

endmodule
