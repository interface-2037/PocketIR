// dev_ctrl.v
// Library controller (M7, M9). Walks the on-chip code library (format:
// docs/codes-format.md, built by tools/ir/library.py) for four commands:
//
//   LOAD  (0) device {dev_t, dev_b, dev_s}: fill the 12-entry code table and
//             write the main-screen text slots 0..10 (title, remote model,
//             labels; missing functions dimmed); blank slots 11..31
//   CODES (1) a device's code table only (menu TEST: send its POWER without
//             changing the screen). Level 2: {dev_t, dev_b, dev_s}; levels 3
//             (recent) and 5 (matches): list entry `cur`, read through the
//             dl_* port and returned on ent_*
//   PAGE  (2) menu page for {level, dev_t, dev_b, cur, top} (levels in
//             menu.v): text slots 0..26 (title, breadcrumb, counter, 9 rows of
//             name + detail, footer hint) or the learn screen, blank the rest;
//             outputs n_items and the scroll thumb
//   JUMP  (3) brand list A-Z jump from brand `cur` of type dev_t in direction
//             `dir` (0 back, 1 forward) -> jump_res
//
// References: library.read_library(), ui_text.main_slots(), ui_menu.Menu
// (page() and the LEFT/RIGHT rules). Checked by sim/tb_remote.v.
// The ROM is read one byte per two cycles; any command takes well under 1 ms.
// A second ROM read port (lib2_*) serves lib/ir_match.v.

module dev_ctrl #(
    parameter LIB_FILE = "core/lib/ir_lib.hex"
) (
    input  wire        clk,
    input  wire        start,             // pulse: run `cmd`
    input  wire [1:0]  cmd,
    input  wire [2:0]  level,             // PAGE, CODES
    input  wire [7:0]  dev_t,
    input  wire [15:0] dev_b,
    input  wire [15:0] dev_s,             // LOAD / CODES: code set
    input  wire [15:0] cur,               // PAGE: cursor; JUMP: current brand; list CODES: entry
    input  wire [15:0] top,               // PAGE: first visible row
    input  wire        dir,               // JUMP
    input  wire [1:0]  msg,               // PAGE (learn / match): last result (menu.v)
    input  wire [7:0]  buttons,           // PAGE (match): remote buttons in the list
    input  wire [4:0]  recent_n,          // recent.v
    input  wire [15:0] match_n,           // ir_match.v
    output wire        busy,
    output reg  [15:0] n_items = 16'd0,   // PAGE: entries at this level
    output reg         scroll_on = 1'b0,
    output reg  [8:0]  scroll_h0 = 9'd0,
    output reg  [8:0]  scroll_h1 = 9'd0,
    output reg  [15:0] jump_res = 16'd0,
    // device lists: entry dl_idx of the recent list (dl_match = 0) or the match
    // list (1) appears on dl_q within two cycles; {type[7:0], brand[11:0], set[11:0]}
    output reg  [9:0]  dl_idx = 10'd0,
    output wire        dl_match,
    input  wire [31:0] dl_q,
    output reg  [7:0]  ent_t = 8'd0,      // device of the last LOAD / CODES
    output reg  [15:0] ent_b = 16'd0,
    output reg  [15:0] ent_s = 16'd0,
    // code table, read by function index (0 POWER .. 11 INPUT, library order)
    input  wire [3:0]  func,
    output wire        code_valid,
    output wire [5:0]  code_proto,
    output wire [31:0] code_d,
    output wire [31:0] code_f,
    // text layer writes (ui_text.v)
    output reg         slot_we = 1'b0,
    output reg  [4:0]  slot_waddr = 5'd0,
    output reg  [31:0] slot_wdata = 32'd0,
    output reg         str_we = 1'b0,
    output reg  [9:0]  str_waddr = 10'd0,
    output reg  [7:0]  str_wdata = 8'd0,
    // second library read port (M9: lib/ir_match.v scans the library), one-cycle latency
    input  wire [15:0] lib2_addr,
    output reg  [7:0]  lib2_q = 8'd0
);

`include "ir_lib.vh"
`include "ui_text.vh"
`include "ui_menu.vh"

localparam CMD_LOAD = 2'd0, CMD_CODES = 2'd1, CMD_PAGE = 2'd2, CMD_JUMP = 2'd3;
localparam L_HOME = 3'd0, L_BRAND = 3'd1, L_SET = 3'd2, L_RECENT = 3'd3, L_LEARN = 3'd4, L_MATCH = 3'd5;
// library.CONSTS indices (M9 ones: ir_lib.vh M9_C_*)
localparam C_REMOTE = 0, C_NAV = 3, C_SPACE = 10, C_CHOOSE_DEV = 11, C_DEV_TYPE = 12, C_BRAND = 13,
           C_SETS = 14, C_SET = 15, C_KEYS = 16, C_AMP = 17, C_MORE = 18, C_SLASH = 19, C_GT = 20;

// ------------------------------------------------------------------ library ROM
reg [7:0]  lib [0:IR_LIB_BYTES-1];
initial $readmemh(LIB_FILE, lib);
reg [15:0] la = 16'd0;
reg [7:0]  lq = 8'd0;
always @(posedge clk) lq <= lib[la];
always @(posedge clk) lib2_q <= lib[lib2_addr];

// ------------------------------------------------------------------ code table
reg [11:0] valid = 12'd0;
reg [5:0]  t_proto [0:11];
reg [31:0] t_d [0:11];
reg [31:0] t_f [0:11];
assign code_valid = (func < 4'd12) ? valid[func] : 1'b0;
assign code_proto = t_proto[func];
assign code_d     = t_d[func];
assign code_f     = t_f[func];

// ------------------------------------------------------------------ tables
function [3:0] fslot(input [3:0] f);          // function -> main-screen label slot (0 = none)
    case (f)
        4'd0: fslot = 4'd2;  4'd3: fslot = 4'd3;  4'd10: fslot = 4'd4; 4'd11: fslot = 4'd5;
        4'd8: fslot = 4'd6;  4'd9: fslot = 4'd7;  4'd2:  fslot = 4'd8; 4'd1:  fslot = 4'd9;
        default: fslot = 4'd0;
    endcase
endfunction
function [5:0] fword(input [3:0] f);          // CONSTS index of the function's default word
    case (f)
        4'd0: fword = 6'd8;  4'd3: fword = 6'd9;  4'd10: fword = 6'd4; 4'd11: fword = 6'd5;
        4'd8: fword = 6'd6;  4'd9: fword = 6'd7;  4'd2:  fword = 6'd1; 4'd1:  fword = 6'd2;
        default: fword = 6'd0;
    endcase
endfunction
function lib_label(input [3:0] f);            // label from the library (VOL keys: fixed words)
    lib_label = (f == 4'd0) || (f == 4'd3) || (f >= 4'd8 && f <= 4'd11);
endfunction
function [31:0] main_slot(input [3:0] n);
    case (n)
        4'd0: main_slot = MAIN_SLOT_0;  4'd1: main_slot = MAIN_SLOT_1;  4'd2: main_slot = MAIN_SLOT_2;
        4'd3: main_slot = MAIN_SLOT_3;  4'd4: main_slot = MAIN_SLOT_4;  4'd5: main_slot = MAIN_SLOT_5;
        4'd6: main_slot = MAIN_SLOT_6;  4'd7: main_slot = MAIN_SLOT_7;  4'd8: main_slot = MAIN_SLOT_8;
        4'd9: main_slot = MAIN_SLOT_9;  default: main_slot = MAIN_SLOT_10;
    endcase
endfunction
function [31:0] menu_slot(input [4:0] n);
    case (n)
        5'd0:  menu_slot = MENU_SLOT_0;  5'd1:  menu_slot = MENU_SLOT_1;  5'd2:  menu_slot = MENU_SLOT_2;
        5'd3:  menu_slot = MENU_SLOT_3;  5'd4:  menu_slot = MENU_SLOT_4;  5'd5:  menu_slot = MENU_SLOT_5;
        5'd6:  menu_slot = MENU_SLOT_6;  5'd7:  menu_slot = MENU_SLOT_7;  5'd8:  menu_slot = MENU_SLOT_8;
        5'd9:  menu_slot = MENU_SLOT_9;  5'd10: menu_slot = MENU_SLOT_10; 5'd11: menu_slot = MENU_SLOT_11;
        5'd12: menu_slot = MENU_SLOT_12; 5'd13: menu_slot = MENU_SLOT_13; 5'd14: menu_slot = MENU_SLOT_14;
        5'd15: menu_slot = MENU_SLOT_15; 5'd16: menu_slot = MENU_SLOT_16; 5'd17: menu_slot = MENU_SLOT_17;
        5'd18: menu_slot = MENU_SLOT_18; 5'd19: menu_slot = MENU_SLOT_19; default: menu_slot = MENU_SLOT_20;
    endcase
endfunction
function [31:0] learn_slot(input [2:0] n);
    case (n)
        3'd0: learn_slot = LEARN_SLOT_0; 3'd1: learn_slot = LEARN_SLOT_1; 3'd2: learn_slot = LEARN_SLOT_2;
        3'd3: learn_slot = LEARN_SLOT_3; 3'd4: learn_slot = LEARN_SLOT_4; default: learn_slot = LEARN_SLOT_5;
    endcase
endfunction
function [31:0] recolour(input [31:0] w, input [2:0] c);   // replace the colour field [23:21]
    recolour = {w[31:24], c, w[20:0]};
endfunction

// ------------------------------------------------------------------ sequencer state
reg [7:0]  st = 8'd0;
// subroutines (each has its own return register, so CC/LET may call RD/CP)
localparam S_RD0 = 8'd200, S_RD1 = 8'd201, S_RD2 = 8'd202;    // read rd_n bytes LE -> val
localparam S_CP0 = 8'd205, S_CP1 = 8'd206, S_CP2 = 8'd207;    // append string at cp_a
localparam S_CC0 = 8'd210, S_CC1 = 8'd211;                    // append CONSTS[cc_k]
localparam S_NUM0 = 8'd215, S_NUM1 = 8'd216, S_NUM2 = 8'd217, S_NUM3 = 8'd218;  // append decimal
localparam S_END = 8'd220;                                    // NUL + slot word
localparam S_LET0 = 8'd225, S_LET1 = 8'd226, S_LET2 = 8'd227; // first letter of brand let_k
localparam S_DIV0 = 8'd230, S_DIV1 = 8'd231;                  // dv / ds -> dq
reg [7:0]  ret_rd = 0, ret_cp = 0, ret_cc = 0, ret_num = 0, ret_end = 0, ret_let = 0, ret_div = 0;
reg [15:0] rd_a = 0;  reg [2:0] rd_n = 0, rd_k = 0;  reg [31:0] val = 0;
reg [15:0] cp_a = 0;  reg [4:0] cp_slot = 0, pos = 0;
reg [5:0]  cc_k = 0;
reg [15:0] nv = 0;    reg [1:0] pw = 0;  reg [3:0] dgt = 0;  reg lead = 0;
reg [31:0] end_word = 0;
reg [15:0] let_k = 0; reg [7:0] let_c = 0;
reg [23:0] dv = 0, dq = 0;  reg [15:0] ds = 0;  reg [24:0] rem = 0;  reg [4:0] di = 0;

// command latches
reg [1:0]  c_cmd = 0, c_msg = 0;
reg [2:0]  c_lv = 0;
reg        c_dir = 0;
reg [7:0]  c_t = 0, c_buttons = 0;
reg [15:0] c_b = 0, c_s = 0, c_cur = 0, c_top = 0, c_match_n = 0;
reg [4:0]  c_recent_n = 0;
// library walk
reg [15:0] ntypes = 0, type_off = 0, label_off = 0, const_off = 0;
reg [15:0] tname = 0, btab = 0, bname = 0, lst = 0, cs = 0, model = 0, tnb = 0, ttot = 0, bns = 0;
reg [15:0] p = 0, mask = 0, n = 0, kk = 0, ptr = 0, more = 0, j = 0;
reg [31:0] dflt_d = 0, cmdw = 0, o_d = 0;
reg [5:0]  dflt_p = 0, o_p = 0;
reg [7:0]  lab = 0, lc = 0, lp = 0;
reg [3:0]  f = 0;
reg [4:0]  k = 0, r = 0;
reg [2:0]  hi = 0, li = 0;
reg        on = 0;
// device-list rows
reg [7:0]  e_t = 0;
reg [15:0] e_b = 0, e_s = 0, e_tname = 0, e_btab = 0, e_bname = 0, e_lst = 0;

assign busy = (st != 8'd0);
assign dl_match = (c_lv == L_MATCH);
wire [5:0]  h_ix  = c_lv * 6 + hi;                         // footer hint entry
wire [2:0]  h_n   = HINT_NS[c_lv * 3 +: 3];
wire [31:0] h_slot = HINT_SLOTS[h_ix * 32 +: 32];
wire [5:0]  hstr  = HINT_STRS[h_ix * 8 +: 6];
wire [15:0] row   = c_top + r;                             // list index of row r
wire        dev_lv = (c_lv == L_RECENT) || (c_lv == L_MATCH);

`define RD(addr, nb, next)  begin rd_a <= (addr); rd_n <= (nb); ret_rd <= (next); st <= S_RD0; end
`define CP(addr, next)      begin cp_a <= (addr); ret_cp <= (next); st <= S_CP0; end
`define CC(idx, next)       begin cc_k <= (idx); ret_cc <= (next); st <= S_CC0; end
`define NUM(v, next)        begin nv <= (v); ret_num <= (next); st <= S_NUM0; end
`define ENDS(w, next)       begin end_word <= (w); ret_end <= (next); st <= S_END; end
`define LET(kv, next)       begin let_k <= (kv); ret_let <= (next); st <= S_LET0; end
`define DIV(a, b, next)     begin dv <= (a); ds <= (b); ret_div <= (next); st <= S_DIV0; end
`define ROWWORD(sl)         (on ? recolour(menu_slot(sl), TXT_ACC_DARK) : menu_slot(sl))

always @(posedge clk) begin
    slot_we <= 1'b0;
    str_we  <= 1'b0;
    case (st)
    // ================================================================ subroutines
    S_RD0: begin la <= rd_a; rd_k <= 3'd0; val <= 32'd0; st <= S_RD1; end
    S_RD1: st <= S_RD2;
    S_RD2: begin
        val <= val | ({24'd0, lq} << (8 * rd_k));
        if (rd_k + 1'b1 == rd_n) st <= ret_rd;
        else begin rd_k <= rd_k + 1'b1; la <= la + 1'b1; st <= S_RD1; end
    end
    S_CP0: begin la <= cp_a; st <= S_CP1; end
    S_CP1: st <= S_CP2;
    S_CP2: if (lq == 8'd0 || pos == 5'd31) st <= ret_cp;
           else begin
               str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= lq;
               pos <= pos + 1'b1; la <= la + 1'b1; st <= S_CP1;
           end
    S_CC0: `RD(const_off + {8'd0, cc_k, 2'd0}, 3'd4, S_CC1)
    S_CC1: begin cp_a <= val[15:0]; ret_cp <= ret_cc; st <= S_CP0; end
    S_NUM0: begin pw <= 2'd3; lead <= 1'b0; st <= S_NUM1; end
    S_NUM1: begin dgt <= 4'd0; st <= S_NUM2; end
    S_NUM2: begin
        case (pw)
            2'd3: if (nv >= 16'd1000) begin nv <= nv - 16'd1000; dgt <= dgt + 1'b1; end else st <= S_NUM3;
            2'd2: if (nv >= 16'd100)  begin nv <= nv - 16'd100;  dgt <= dgt + 1'b1; end else st <= S_NUM3;
            2'd1: if (nv >= 16'd10)   begin nv <= nv - 16'd10;   dgt <= dgt + 1'b1; end else st <= S_NUM3;
            default: begin dgt <= nv[3:0]; st <= S_NUM3; end
        endcase
    end
    S_NUM3: begin
        if ((dgt != 0 || lead || pw == 2'd0) && pos != 5'd31) begin
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'h30 + dgt;
            pos <= pos + 1'b1; lead <= 1'b1;
        end
        if (pw == 2'd0) st <= ret_num;
        else begin pw <= pw - 1'b1; st <= S_NUM1; end
    end
    S_END: begin
        str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
        slot_we <= 1'b1; slot_waddr <= cp_slot; slot_wdata <= end_word;
        st <= ret_end;
    end
    S_LET0: `RD(btab + 16'd12 * let_k, 3'd4, S_LET1)
    S_LET1: `RD(val[15:0], 3'd1, S_LET2)
    S_LET2: begin let_c <= val[7:0]; st <= ret_let; end
    S_DIV0: begin rem <= 25'd0; dq <= dv; di <= 5'd0; st <= S_DIV1; end      // restoring division
    S_DIV1: begin
        if ({rem[23:0], dq[23]} >= {9'd0, ds}) begin
            rem <= {rem[23:0], dq[23]} - {9'd0, ds}; dq <= {dq[22:0], 1'b1};
        end else begin
            rem <= {rem[23:0], dq[23]}; dq <= {dq[22:0], 1'b0};
        end
        di <= di + 1'b1;
        if (di == 5'd23) st <= ret_div;
    end

    // ================================================================ command start + header
    8'd0: if (start) begin
        c_cmd <= cmd; c_lv <= level; c_t <= dev_t; c_b <= dev_b; c_s <= dev_s;
        c_cur <= cur; c_top <= top; c_dir <= dir;
        c_msg <= msg; c_buttons <= buttons; c_recent_n <= recent_n; c_match_n <= match_n;
        `RD(16'd4, 3'd2, 8'd1)
    end
    8'd1: begin ntypes <= val[15:0];  `RD(16'd8, 3'd4, 8'd2) end
    8'd2: begin type_off <= val[15:0]; `RD(16'd12, 3'd4, 8'd3) end
    8'd3: begin label_off <= val[15:0]; `RD(16'd24, 3'd4, 8'd4) end
    8'd4: begin
        const_off <= val[15:0];
        st <= (c_cmd == CMD_PAGE) ? 8'd60 : (c_cmd == CMD_JUMP) ? 8'd120 :
              (c_cmd == CMD_CODES && (c_lv == L_RECENT || c_lv == L_MATCH)) ? 8'd5 : 8'd10;
    end
    // list CODES: the device is entry `cur` of the recent / match list
    8'd5: begin dl_idx <= c_cur[9:0]; st <= 8'd6; end
    8'd6: st <= 8'd7;
    8'd7: begin c_t <= dl_q[31:24]; c_b <= {4'd0, dl_q[23:12]}; c_s <= {4'd0, dl_q[11:0]}; st <= 8'd10; end

    // ================================================================ LOAD / CODES
    8'd10: begin
        ent_t <= c_t; ent_b <= c_b; ent_s <= c_s;
        `RD(type_off + 16'd12 * c_t, 3'd4, 8'd11)
    end
    8'd11: begin tname <= val[15:0]; `RD(type_off + 16'd12 * c_t + 16'd4, 3'd4, 8'd12) end
    8'd12: begin btab <= val[15:0];  `RD(val[15:0] + 16'd12 * c_b, 3'd4, 8'd13) end
    8'd13: begin bname <= val[15:0]; `RD(btab + 16'd12 * c_b + 16'd4, 3'd4, 8'd14) end
    8'd14: begin lst <= val[15:0];   `RD(val[15:0] + {c_s[12:0], 3'd0}, 3'd4, 8'd15) end
    8'd15: begin cs <= val[15:0];    `RD(lst + {c_s[12:0], 3'd0} + 16'd4, 3'd2, 8'd16) end
    8'd16: begin
        model <= val[15:0];
        if (c_cmd == CMD_LOAD) begin cp_slot <= 5'd0; pos <= 5'd0; `CP(bname, 8'd17) end
        else st <= 8'd22;
    end
    8'd17: `CC(C_SPACE, 8'd18)
    8'd18: `CP(tname, 8'd19)
    8'd19: `ENDS(MAIN_SLOT_0, 8'd20)
    8'd20: begin cp_slot <= 5'd1; pos <= 5'd0; `CC(C_REMOTE, 8'd21) end
    8'd21: `CP(model, 8'd23)
    8'd23: `ENDS(MAIN_SLOT_1, 8'd22)
    8'd22: `RD(cs, 3'd1, 8'd24)
    8'd24: begin dflt_p <= val[5:0]; `RD(cs + 16'd2, 3'd2, 8'd25) end
    8'd25: begin mask <= val[15:0];  `RD(cs + 16'd4, 3'd4, 8'd26) end
    8'd26: begin dflt_d <= val; p <= cs + 16'd8; f <= 4'd0; valid <= 12'd0; st <= 8'd27; end
    8'd27: if (f == 4'd12) st <= (c_cmd == CMD_LOAD) ? 8'd40 : 8'd0;
           else if (!mask[f]) st <= 8'd35;
           else `RD(p, 3'd2, 8'd28)
    8'd28: begin cmdw <= val; `RD(p + 16'd2, 3'd1, 8'd29) end
    8'd29: begin lab <= val[7:0]; `RD(p + 16'd3, 3'd1, 8'd30) end
    8'd30: begin
        p <= p + 16'd4;
        if (val[0]) `RD(p + 16'd4, 3'd1, 8'd31)
        else begin
            t_proto[f] <= dflt_p; t_d[f] <= dflt_d; t_f[f] <= cmdw; valid[f] <= 1'b1;
            st <= 8'd34;
        end
    end
    8'd31: begin o_p <= val[5:0]; `RD(p + 16'd4, 3'd4, 8'd32) end          // override record
    8'd32: begin o_d <= val;      `RD(p + 16'd8, 3'd4, 8'd33) end
    8'd33: begin
        t_proto[f] <= o_p; t_d[f] <= o_d; t_f[f] <= val; valid[f] <= 1'b1;
        p <= p + 16'd12; st <= 8'd34;
    end
    8'd34: if (c_cmd != CMD_LOAD || fslot(f) == 4'd0) begin f <= f + 1'b1; st <= 8'd27; end
           else begin
               cp_slot <= {1'b0, fslot(f)}; pos <= 5'd0;
               if (lib_label(f)) `RD(label_off + {6'd0, lab, 2'd0}, 3'd4, 8'd36)
               else `CC(fword(f), 8'd37)
           end
    8'd36: `CP(val[15:0], 8'd37)
    8'd37: begin f <= f + 1'b1; `ENDS(main_slot(fslot(f)), 8'd27) end           // present
    8'd35: if (c_cmd != CMD_LOAD || fslot(f) == 4'd0) begin f <= f + 1'b1; st <= 8'd27; end
           else begin cp_slot <= {1'b0, fslot(f)}; pos <= 5'd0; `CC(fword(f), 8'd38) end
    8'd38: begin f <= f + 1'b1; `ENDS(recolour(main_slot(fslot(f)), TXT_DIM), 8'd27) end   // missing
    8'd40: begin cp_slot <= 5'd10; pos <= 5'd0; `CC(C_NAV, 8'd41) end
    8'd41: `ENDS((valid[7:4] == 4'hF) ? MAIN_SLOT_10 : recolour(MAIN_SLOT_10, TXT_DIM), 8'd42)
    8'd42: begin k <= 5'd11; st <= 8'd43; end
    8'd43: begin                                                               // blank 11..31
        str_we <= 1'b1; str_waddr <= {k, 5'd0}; str_wdata <= 8'd0;
        if (k == 5'd31) st <= 8'd0; else k <= k + 1'b1;
    end

    // ================================================================ PAGE
    8'd60: `RD(type_off + 16'd12 * c_t, 3'd4, 8'd61)
    8'd61: begin tname <= val[15:0]; `RD(type_off + 16'd12 * c_t + 16'd4, 3'd4, 8'd62) end
    8'd62: begin btab <= val[15:0];  `RD(type_off + 16'd12 * c_t + 16'd8, 3'd2, 8'd63) end
    8'd63: begin
        tnb <= val[15:0];
        case (c_lv)
            L_BRAND, L_SET: `RD(btab + 16'd12 * c_b, 3'd4, 8'd64)
            L_HOME:   begin n <= ntypes + MENU_HOME_ROWS; st <= 8'd70; end
            L_RECENT: begin n <= {11'd0, c_recent_n}; st <= 8'd70; end
            L_MATCH:  begin n <= c_match_n; st <= 8'd70; end
            default:  begin n <= 16'd0; st <= 8'd140; end                   // learn screen
        endcase
    end
    8'd64: begin bname <= val[15:0]; `RD(btab + 16'd12 * c_b + 16'd4, 3'd4, 8'd65) end
    8'd65: begin lst <= val[15:0];   `RD(btab + 16'd12 * c_b + 16'd8, 3'd2, 8'd66) end
    8'd66: begin bns <= val[15:0]; n <= (c_lv == L_BRAND) ? tnb : val[15:0]; st <= 8'd70; end
    // slot 0: title
    8'd70: begin
        cp_slot <= 5'd0; pos <= 5'd0;
        case (c_lv)
            L_HOME:   `CC(C_CHOOSE_DEV, 8'd74)
            L_BRAND:  `CP(tname, 8'd71)
            L_SET:    `CP(bname, 8'd72)
            L_RECENT: `CC(M9_C_RECENT, 8'd74)
            default:  `NUM(n, 8'd150)                                       // "<n> MATCH(ES)"
        endcase
    end
    8'd71: `CC(C_BRAND, 8'd74)
    8'd72: `CC(C_SPACE, 8'd73)
    8'd73: `CP(tname, 8'd74)
    8'd150: `CC((n == 16'd1) ? M9_C_MATCH : M9_C_MATCHES, 8'd74)
    8'd74: `ENDS(MENU_SLOT_0, 8'd75)
    // slot 1: breadcrumb
    8'd75: begin
        cp_slot <= 5'd1; pos <= 5'd0;
        case (c_lv)
            L_HOME:   `CC(M9_C_HOME_CRUMB, 8'd78)
            L_BRAND:  `CP(tname, 8'd78)
            L_SET:    `CP(tname, 8'd76)
            L_RECENT: `CC(M9_C_RECENT_CRUMB, 8'd78)
            default:  if (c_msg == 2'd0) `NUM({8'd0, c_buttons}, 8'd151)
                      else if (c_msg == 2'd3) `CC(M9_C_NONE, 8'd78)
                      else `CC(M9_C_UNREAD_BTN, 8'd78)
        endcase
    end
    8'd76: `CC(C_GT, 8'd77)
    8'd77: `CP(bname, 8'd78)
    8'd151: `CC((c_buttons == 8'd1) ? M9_C_BUTTON : M9_C_BUTTONS, 8'd78)
    8'd78: `ENDS(MENU_SLOT_1, 8'd79)
    // slot 2: "cur+1 / n"
    8'd79: begin cp_slot <= 5'd2; pos <= 5'd0; `NUM(c_cur + 16'd1, 8'd80) end
    8'd80: `CC(C_SLASH, 8'd81)
    8'd81: `NUM(n, 8'd82)
    8'd82: begin r <= 5'd0; `ENDS(MENU_SLOT_2, 8'd83) end
    // rows: name in slot 3+r, detail in slot 12+r
    8'd83: if (r == 5'd9) begin hi <= 3'd0; st <= 8'd100; end
           else begin
               kk <= (c_lv == L_HOME) ? row - MENU_HOME_ROWS : row; on <= (row == c_cur);
               cp_slot <= 5'd3 + r; pos <= 5'd0;
               if (row >= n) st <= 8'd84;
               else case (c_lv)
                   L_HOME:  if (row == 16'd0)      `CC(M9_C_RECENT, 8'd152)
                            else if (row == 16'd1) `CC(M9_C_LEARN, 8'd154)
                            else `RD(type_off + 16'd12 * (row - MENU_HOME_ROWS), 3'd4, 8'd86)
                   L_BRAND: `RD(btab + 16'd12 * row, 3'd4, 8'd86)
                   L_SET:   `RD(lst + {row[12:0], 3'd0}, 3'd4, 8'd90)
                   default: begin dl_idx <= row[9:0]; st <= 8'd160; end      // recent / match entry
               endcase
           end
    8'd84: `ENDS(menu_slot(5'd3 + r), 8'd85)                                      // empty row
    8'd85: begin cp_slot <= 5'd12 + r; pos <= 5'd0; r <= r + 1'b1; `ENDS(menu_slot(5'd12 + r), 8'd83) end
    // type / brand row: name, then "<N> SETS" (type: total at +10, brand: count at +8)
    8'd86: `CP(val[15:0], 8'd87)
    8'd87: `ENDS(`ROWWORD(5'd3 + r), 8'd88)
    8'd88: begin
        cp_slot <= 5'd12 + r; pos <= 5'd0;
        if (c_lv == L_HOME) `RD(type_off + 16'd12 * kk + 16'd10, 3'd2, 8'd89)
        else                `RD(btab + 16'd12 * kk + 16'd8, 3'd2, 8'd89)
    end
    8'd89: begin ptr <= val[15:0]; `NUM(val[15:0], 8'd95) end
    8'd95: `CC((ptr == 16'd1) ? C_SET : C_SETS, 8'd96)
    8'd96: begin r <= r + 1'b1; `ENDS(`ROWWORD(5'd12 + r), 8'd83) end
    // home rows: RECENT DEVICES "<n> DEVICE(S)", LEARN FROM REMOTE (no detail)
    8'd152: `ENDS(`ROWWORD(5'd3 + r), 8'd153)
    8'd153: begin cp_slot <= 5'd12 + r; pos <= 5'd0; `NUM({11'd0, c_recent_n}, 8'd155) end
    8'd155: `CC((c_recent_n == 5'd1) ? M9_C_DEVICE : M9_C_DEVICES, 8'd96)
    8'd154: `ENDS(`ROWWORD(5'd3 + r), 8'd85)
    // code-set row: "<model>[ & N MORE]", then "<k> KEYS" unless all 12
    8'd90: begin cs <= val[15:0]; `RD(lst + {kk[12:0], 3'd0} + 16'd4, 3'd2, 8'd91) end
    8'd91: begin model <= val[15:0]; `RD(lst + {kk[12:0], 3'd0} + 16'd6, 3'd2, 8'd92) end
    8'd92: begin more <= val[15:0]; `CP(model, 8'd93) end
    8'd93: if (more == 16'd0) st <= 8'd97; else `CC(C_AMP, 8'd94)
    8'd94: `NUM(more, 8'd98)
    8'd98: `CC(C_MORE, 8'd97)
    8'd97: `ENDS(`ROWWORD(5'd3 + r), 8'd99)
    8'd99: begin
        cp_slot <= 5'd12 + r; pos <= 5'd0;
        if (dev_lv) `CP(e_tname, 8'd96)                                       // device row: type name
        else `RD(cs + 16'd1, 3'd1, 8'd101)
    end
    8'd101: begin ptr <= val[15:0];
                  if (val[7:0] == 8'd12) st <= 8'd96; else `NUM({8'd0, val[7:0]}, 8'd102) end
    8'd102: `CC(C_KEYS, 8'd96)
    // device row (recent / match): "<BRAND> <model>[ & N MORE]", then the type name
    8'd160: st <= 8'd161;                                                      // list read latency
    8'd161: st <= 8'd162;
    8'd162: begin
        e_t <= dl_q[31:24]; e_b <= {4'd0, dl_q[23:12]}; e_s <= {4'd0, dl_q[11:0]};
        `RD(type_off + 16'd12 * dl_q[31:24], 3'd4, 8'd163)
    end
    8'd163: begin e_tname <= val[15:0]; `RD(type_off + 16'd12 * e_t + 16'd4, 3'd4, 8'd164) end
    8'd164: begin e_btab <= val[15:0];  `RD(val[15:0] + 16'd12 * e_b, 3'd4, 8'd165) end
    8'd165: begin e_bname <= val[15:0]; `RD(e_btab + 16'd12 * e_b + 16'd4, 3'd4, 8'd166) end
    8'd166: begin e_lst <= val[15:0];   `RD(val[15:0] + {e_s[12:0], 3'd0} + 16'd4, 3'd2, 8'd167) end
    8'd167: begin model <= val[15:0];   `RD(e_lst + {e_s[12:0], 3'd0} + 16'd6, 3'd2, 8'd168) end
    8'd168: begin more <= val[15:0]; `CP(e_bname, 8'd169) end
    8'd169: `CC(C_SPACE, 8'd170)
    8'd170: `CP(model, 8'd93)                                                 // then as a set row

    // footer hint: slots 21..(21+N-1), then blank to 31
    8'd100: if (hi == h_n) begin k <= 5'd21 + h_n; st <= 8'd103; end
            else begin cp_slot <= 5'd21 + hi; pos <= 5'd0; `CC(hstr, 8'd104) end
    8'd104: begin hi <= hi + 1'b1; `ENDS(h_slot, 8'd100) end
    8'd103: begin
        str_we <= 1'b1; str_waddr <= {k, 5'd0}; str_wdata <= 8'd0;
        if (k == 5'd31) st <= 8'd105; else k <= k + 1'b1;
    end
    // scroll thumb: rows [66 + 250*top/n, 66 + 250*min(n, top+9)/n)
    8'd105: begin
        n_items <= n;
        scroll_on <= (n > 16'd9);
        if (n > 16'd9) `DIV(24'd250 * c_top, n, 8'd106)
        else st <= 8'd0;
    end
    8'd106: begin scroll_h0 <= 9'd66 + dq[8:0];
                  `DIV(24'd250 * ((c_top + 16'd9 < n) ? c_top + 16'd9 : n), n, 8'd107) end
    8'd107: begin scroll_h1 <= 9'd66 + dq[8:0]; st <= 8'd0; end

    // ================================================================ learn screen (level 4)
    8'd140: begin cp_slot <= 5'd0; pos <= 5'd0; `CC(M9_C_LEARN, 8'd141) end
    8'd141: `ENDS(MENU_SLOT_0, 8'd142)
    8'd142: begin cp_slot <= 5'd1; pos <= 5'd0; `CC(M9_C_LEARN_CRUMB, 8'd143) end
    8'd143: `ENDS(MENU_SLOT_1, 8'd144)
    8'd144: begin cp_slot <= 5'd2; pos <= 5'd0; li <= 3'd0; `ENDS(MENU_SLOT_2, 8'd145) end   // no counter
    8'd145: if (li == 3'd6) begin k <= 5'd9; st <= 8'd147; end
            else begin
                cp_slot <= 5'd3 + li; pos <= 5'd0;
                case (li)
                    3'd0: `CC(M9_C_AIM1, 8'd146)
                    3'd1: `CC(M9_C_AIM2, 8'd146)
                    3'd2: `CC(M9_C_AIM3, 8'd146)
                    3'd3: `CC(M9_C_LISTENING, 8'd146)
                    3'd4: if (c_msg == 2'd1) `CC(M9_C_NOMATCH, 8'd146)
                          else if (c_msg == 2'd2) `CC(M9_C_UNREAD, 8'd146)
                          else st <= 8'd146;
                    default: if (c_msg == 2'd1) `CC(M9_C_ANOTHER, 8'd146)
                             else if (c_msg == 2'd2) `CC(M9_C_CLOSER, 8'd146)
                             else st <= 8'd146;
                endcase
            end
    8'd146: begin li <= li + 1'b1; `ENDS(learn_slot(li), 8'd145) end
    8'd147: begin                                                              // blank 9..20
        str_we <= 1'b1; str_waddr <= {k, 5'd0}; str_wdata <= 8'd0;
        if (k == 5'd20) begin hi <= 3'd0; st <= 8'd100; end else k <= k + 1'b1;
    end

    // ================================================================ JUMP (brand list A-Z)
    8'd120: `RD(type_off + 16'd12 * c_t + 16'd4, 3'd4, 8'd121)
    8'd121: begin btab <= val[15:0]; `RD(type_off + 16'd12 * c_t + 16'd8, 3'd2, 8'd122) end
    8'd122: begin tnb <= val[15:0]; `LET(c_cur, 8'd123) end
    8'd123: begin
        lc <= let_c;
        if (c_dir) begin j <= c_cur + 16'd1; st <= 8'd124; end
        else begin j <= c_cur; st <= 8'd130; end
    end
    // forward: first brand after the current letter block
    8'd124: if (j >= tnb) begin jump_res <= c_cur; st <= 8'd0; end
            else `LET(j, 8'd125)
    8'd125: if (let_c != lc) begin jump_res <= j; st <= 8'd0; end
            else begin j <= j + 16'd1; st <= 8'd124; end
    // back: start of this letter block, or else of the previous one (j = s0)
    8'd130: if (j == 16'd0) st <= 8'd133; else `LET(j - 16'd1, 8'd131)
    8'd131: if (let_c == lc) begin j <= j - 16'd1; st <= 8'd130; end
            else begin lp <= let_c; st <= 8'd133; end
    8'd133: if (j < c_cur) begin jump_res <= j; st <= 8'd0; end
            else if (j == 16'd0) begin jump_res <= c_cur; st <= 8'd0; end
            else begin j <= j - 16'd1; st <= 8'd134; end                       // j = s0 - 1, letter lp
    8'd134: if (j == 16'd0) begin jump_res <= 16'd0; st <= 8'd0; end
            else `LET(j - 16'd1, 8'd135)
    8'd135: if (let_c == lp) begin j <= j - 16'd1; st <= 8'd134; end
            else begin jump_res <= j; st <= 8'd0; end

    default: st <= 8'd0;
    endcase
end

`undef RD
`undef CP
`undef CC
`undef NUM
`undef ENDS
`undef LET
`undef DIV
`undef ROWWORD

endmodule
