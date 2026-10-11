// menu.v
// Device menu navigation (M7, M9). Turns button presses and identified remote
// buttons into dev_ctrl.v commands; the reference model is tools/ui/ui_menu.py
// (Menu.press / Menu.burst), checked by sim/tb_remote.v against
// build/ir_expected/menu_steps.txt.
//
// Levels: 0 home (RECENT DEVICES, LEARN FROM REMOTE, then the device types),
// 1 brand, 2 code set, 3 recent devices, 4 learn (listening), 5 matches.
//   Start + Select (chord)  open at level 0 (cursor on RECENT DEVICES) /
//                           close and reload the current device
//   up / down               move the cursor (held: auto-repeat)
//   left / right            brand list: A-Z jump; other lists: page of 9
//   OK                      home -> recent / learn / brands -> code sets;
//                           set, recent or match -> use it (LOAD, close)
//   BACK                    up a level (matches -> listen again); home: close
//   POWER (set, recent, match levels)  TEST: send the highlighted device's POWER
// At the set / recent / match levels every cursor change loads the highlighted
// device's codes (CODES; for lists dev_ctrl reads the entry and returns it on
// ent_*) so TEST sends the right POWER; closing reloads the current device.
// While learning (levels 4-5) the receiver is on (`listen`). Each burst
// ir_rx_marks.v finishes runs lib/ir_match.v: fresh at level 4, narrowing at
// level 5. Matches -> level 5 (cursor on the first); otherwise the result is
// shown (msg) and the list, if any, is kept.
//
// Timing: a cursor change first registers the new cursor (nv), then the next
// cycle stores it and scrolls (Q_SCROLL), so no cycle chains the bounds
// compare with the scroll compare.
//
// Buttons are the chord-filtered keys from ir_remote.v (`kf`), mapped by their
// position in the 180-degree grip, like the remote functions.

module menu #(
    parameter CLK_HZ    = 74_250_000,
    parameter REPEAT_MS = 400,            // auto-repeat delay
    parameter RATE_MS   = 120,            // auto-repeat interval
    parameter TEST_MS   = 10,             // TEST key pulse length
    parameter [7:0]  BOOT_T = 8'd0,       // device until the boot pulse
    parameter [15:0] BOOT_B = 16'd0,
    parameter [15:0] BOOT_S = 16'd0
) (
    input  wire        clk,
    input  wire        boot,              // pulse, any time: load this device (dev_save.v), close the menu
    input  wire [7:0]  boot_t,
    input  wire [15:0] boot_b,
    input  wire [15:0] boot_s,
    input  wire [15:0] kf,                // chord-filtered keys (ir_remote.v)
    input  wire        chord,             // pulse: Start + Select
    output reg         open = 1'b0,
    output wire        busy,
    output reg         test_key = 1'b0,   // to ir_remote: send POWER (menu open)
    output reg  [3:0]  bar_row = 4'd15,   // highlighted row 0..8 (15 = none)
    output reg  [3:0]  div_row = 4'd15,   // home list: divider above this row (15 = none)
    output reg  [7:0]  dev_t = BOOT_T,    // current device
    output reg  [15:0] dev_b = BOOT_B,
    output reg  [15:0] dev_s = BOOT_S,
    // dev_ctrl.v
    output reg         dc_start = 1'b0,
    output reg  [1:0]  dc_cmd = 2'd0,
    output reg  [2:0]  dc_level = 3'd0,
    output reg  [7:0]  dc_t = 8'd0,
    output reg  [15:0] dc_b = 16'd0,
    output reg  [15:0] dc_s = 16'd0,
    output reg  [15:0] dc_cur = 16'd0,
    output reg  [15:0] dc_top = 16'd0,
    output reg         dc_dir = 1'b0,
    output reg  [1:0]  dc_msg = 2'd0,     // learn / match page: last result
    output reg  [7:0]  dc_buttons = 8'd0, // match page: remote buttons in the list
    input  wire        dc_busy,
    input  wire [15:0] n_items,
    input  wire [15:0] jump_res,
    input  wire [7:0]  ent_t,             // list entry whose codes the last CODES loaded
    input  wire [15:0] ent_b,
    input  wire [15:0] ent_s,
    // M9: recent list (recent.v), remote identification (ir_rx_marks.v, ir_match.v)
    input  wire [4:0]  recent_n,
    output wire        listen,            // receiver on
    output wire        rx_hold,           // don't start a burst: the last one isn't matched yet
    input  wire        burst,             // pulse: ir_rx_marks finished a burst
    output reg         m_start = 1'b0,
    output reg         m_narrow = 1'b0,
    input  wire        m_done,
    input  wire [1:0]  m_result
);

localparam CMD_LOAD = 2'd0, CMD_CODES = 2'd1, CMD_PAGE = 2'd2, CMD_JUMP = 2'd3;
localparam L_HOME = 3'd0, L_BRAND = 3'd1, L_SET = 3'd2, L_RECENT = 3'd3, L_LEARN = 3'd4, L_MATCH = 3'd5;
localparam ROWS = 9, HOME_ROWS = 2;
localparam DLY = CLK_HZ / 1000 * REPEAT_MS, RATE = CLK_HZ / 1000 * RATE_MS, TPULSE = CLK_HZ / 1000 * TEST_MS;

// ------------------------------------------------------------------ keys -> function events
// grip mapping (same as ir_remote.v): Down=UP, Up=DOWN, Right=LEFT, Left=RIGHT, Y=OK, X=BACK, Start=POWER
wire [6:0] fk = {kf[15], kf[6], kf[7], kf[2], kf[3], kf[0], kf[1]};   // {POWER, BACK, OK, RIGHT, LEFT, DOWN, UP}
localparam F_UP = 0, F_DOWN = 1, F_LEFT = 2, F_RIGHT = 3, F_OK = 4, F_BACK = 5, F_POWER = 6;
reg  [6:0]  fk_r = 7'd0;
reg  [31:0] hold = 0;
reg  [6:0]  ev = 7'd0;                 // one-cycle events
always @(posedge clk) begin
    fk_r <= fk;
    ev <= fk & ~fk_r;                                        // new presses
    if (fk[3:0] != 4'd0 && fk[3:0] == fk_r[3:0]) begin       // held arrows auto-repeat
        hold <= hold + 1'b1;
        if (hold == DLY - 1) begin ev[3:0] <= fk[3:0]; hold <= DLY - RATE; end
    end else hold <= 0;
end

// ------------------------------------------------------------------ state
reg  [2:0]  level = L_HOME;
reg  [15:0] cur [0:5];
reg  [15:0] top [0:5];
integer     i;
initial for (i = 0; i < 6; i = i + 1) begin cur[i] = 16'd0; top[i] = 16'd0; end
reg  [7:0]  tsel = 8'd0;               // type of levels 1-2
reg  [15:0] n = 16'd1;                 // entries at the current level (from the last PAGE)
reg  [15:0] nv = 16'd0;                // new cursor of the current level, stored in Q_SCROLL
reg         pend = 1'b0;               // a finished burst waits for the matcher
wire [15:0] c  = cur[level];
wire [15:0] tp = top[level];
wire        lst_lv = (level == L_SET) || (level == L_RECENT) || (level == L_MATCH);   // CODES on moves

// command queue: up to two commands per action (CODES/JUMP, then PAGE), or LOAD
localparam Q_IDLE = 3'd0, Q_ISSUE = 3'd1, Q_WAIT = 3'd2, Q_JUMPED = 3'd3, Q_BOOT = 3'd4,
           Q_SCROLL = 3'd5, Q_MATCH = 3'd6;
reg  [2:0]  qs = Q_BOOT;
reg  [1:0]  q_cmd [0:1];
reg         q_n = 1'b0, q_i = 1'b0, q_dir = 1'b0;
reg  [31:0] tcount = 0;
assign busy    = (qs != Q_IDLE);
assign listen  = open && (level == L_LEARN || level == L_MATCH);
assign rx_hold = pend || (qs == Q_MATCH);

always @(posedge clk) begin
    dc_start <= 1'b0;
    m_start  <= 1'b0;
    if (test_key) begin
        tcount <= tcount + 1'b1;
        if (tcount == TPULSE - 1) test_key <= 1'b0;
    end
    if (burst && listen) pend <= 1'b1;
    if (!listen) pend <= 1'b0;
    case (qs)
        Q_BOOT: ;                                             // wait for the first boot pulse
        Q_IDLE: begin
            // a cursor change sets nv and goes through Q_SCROLL; entering a level
            // also clears its top, so Q_SCROLL scrolls it like a fresh list
            q_i <= 1'b0; q_n <= 1'b0; q_cmd[0] <= CMD_PAGE; q_cmd[1] <= CMD_PAGE;
            if (chord) begin
                qs <= Q_ISSUE;
                if (!open) begin
                    open <= 1'b1; level <= L_HOME; nv <= 16'd0; top[L_HOME] <= 16'd0; qs <= Q_SCROLL;
                end else begin
                    open <= 1'b0; q_cmd[0] <= CMD_LOAD;
                end
            end else if (pend && listen) begin                // identify the remote button
                pend <= 1'b0; m_start <= 1'b1; m_narrow <= (level == L_MATCH); qs <= Q_MATCH;
            end else if (open && ev != 7'd0) begin
                qs <= Q_ISSUE;
                if (level == L_LEARN) begin                   // only BACK while listening
                    if (ev[F_BACK]) level <= L_HOME;
                    else qs <= Q_IDLE;
                end else if (ev[F_UP] || ev[F_DOWN]) begin
                    if (ev[F_DOWN]) nv <= (c + 1 < n) ? c + 1'b1 : c;
                    else            nv <= (c != 0) ? c - 1'b1 : c;
                    qs <= Q_SCROLL;
                    if (lst_lv) begin q_cmd[0] <= CMD_CODES; q_n <= 1'b1; end
                end else if (ev[F_LEFT] || ev[F_RIGHT]) begin
                    if (level == L_BRAND) begin
                        q_cmd[0] <= CMD_JUMP; q_dir <= ev[F_RIGHT]; q_n <= 1'b1;
                    end else begin
                        if (ev[F_RIGHT]) nv <= (c + ROWS < n) ? c + ROWS : n - 1'b1;
                        else             nv <= (c >= ROWS) ? c - ROWS : 16'd0;
                        qs <= Q_SCROLL;
                        if (lst_lv) begin q_cmd[0] <= CMD_CODES; q_n <= 1'b1; end
                    end
                end else if (ev[F_OK]) begin
                    case (level)
                        L_HOME: if (c == 16'd0) begin                                    // recent devices
                                    level <= L_RECENT; top[L_RECENT] <= 16'd0; qs <= Q_SCROLL;
                                    nv <= (recent_n > 5'd1) ? 16'd1 : 16'd0;
                                    q_cmd[0] <= CMD_CODES; q_n <= 1'b1;
                                end else if (c == 16'd1) begin                           // learn
                                    level <= L_LEARN; dc_msg <= 2'd0; dc_buttons <= 8'd0;
                                end else begin                                           // a type
                                    tsel <= c[7:0] - HOME_ROWS;
                                    level <= L_BRAND; top[L_BRAND] <= 16'd0; qs <= Q_SCROLL;
                                    nv <= (c - HOME_ROWS == {8'd0, dev_t}) ? dev_b : 16'd0;
                                end
                        L_BRAND: begin
                                    level <= L_SET; top[L_SET] <= 16'd0; qs <= Q_SCROLL;
                                    nv <= (tsel == dev_t && cur[L_BRAND] == dev_b) ? dev_s : 16'd0;
                                    q_cmd[0] <= CMD_CODES; q_n <= 1'b1;
                                end
                        L_SET:   begin                                                   // choose this set
                                    dev_t <= tsel; dev_b <= cur[L_BRAND]; dev_s <= cur[L_SET];
                                    open <= 1'b0; q_cmd[0] <= CMD_LOAD;
                                end
                        default: begin                                                   // recent / match: use it
                                    dev_t <= ent_t; dev_b <= ent_b; dev_s <= ent_s;
                                    open <= 1'b0; q_cmd[0] <= CMD_LOAD;
                                end
                    endcase
                end else if (ev[F_BACK]) begin
                    case (level)
                        L_HOME:  begin open <= 1'b0; q_cmd[0] <= CMD_LOAD; end
                        L_BRAND: level <= L_HOME;
                        L_SET:   level <= L_BRAND;
                        L_MATCH: begin level <= L_LEARN; dc_msg <= 2'd0; dc_buttons <= 8'd0; end   // retry
                        default: level <= L_HOME;                                       // recent
                    endcase
                end else if (ev[F_POWER] && lst_lv) begin
                    test_key <= 1'b1; tcount <= 0; qs <= Q_IDLE;      // TEST: nothing to redraw
                end else qs <= Q_IDLE;                                   // key unused at this level
            end
        end
        Q_MATCH: if (m_done) begin
            q_i <= 1'b0;
            if (m_result == 2'd0) begin                       // matches: show the list, first entry
                dc_buttons <= (level == L_LEARN) ? 8'd1 : (dc_buttons == 8'hFF) ? 8'hFF : dc_buttons + 1'b1;
                dc_msg <= 2'd0;
                level <= L_MATCH; top[L_MATCH] <= 16'd0; nv <= 16'd0;
                q_cmd[0] <= CMD_CODES; q_cmd[1] <= CMD_PAGE; q_n <= 1'b1; qs <= Q_SCROLL;
            end else begin                                    // show why; any list stays
                dc_msg <= m_result;
                q_cmd[0] <= CMD_PAGE; q_n <= 1'b0; qs <= Q_ISSUE;
            end
        end
        Q_SCROLL: begin                                       // store nv, keep it visible
            cur[level] <= nv;
            if (nv < tp) top[level] <= nv;
            else if (nv >= tp + ROWS) top[level] <= nv - (ROWS - 1);
            qs <= Q_ISSUE;
        end
        Q_ISSUE: if (!dc_busy && !dc_start) begin
            dc_cmd   <= q_cmd[q_i];
            dc_level <= level;
            // LOAD uses the current device; CODES/PAGE/JUMP the menu cursors
            dc_t <= (q_cmd[q_i] == CMD_LOAD) ? dev_t : tsel;
            dc_b <= (q_cmd[q_i] == CMD_LOAD) ? dev_b : cur[L_BRAND];
            dc_s <= (q_cmd[q_i] == CMD_LOAD) ? dev_s : cur[L_SET];
            dc_cur <= c; dc_top <= tp; dc_dir <= q_dir;
            dc_start <= 1'b1;
            qs <= Q_WAIT;
        end
        Q_WAIT: if (!dc_start && !dc_busy) begin
            if (dc_cmd == CMD_PAGE) n <= n_items;
            if (dc_cmd == CMD_JUMP) qs <= Q_JUMPED;
            else if (q_i == q_n) qs <= Q_IDLE;
            else begin q_i <= 1'b1; qs <= Q_ISSUE; end
        end
        Q_JUMPED: begin nv <= jump_res; q_i <= 1'b1; qs <= Q_SCROLL; end    // then PAGE
        default: qs <= Q_IDLE;
    endcase
    if (boot) begin                    // (re)start: load the boot device, menu closed
        dev_t <= boot_t; dev_b <= boot_b; dev_s <= boot_s;
        open <= 1'b0; test_key <= 1'b0; pend <= 1'b0;
        q_cmd[0] <= CMD_LOAD; q_n <= 1'b0; q_i <= 1'b0; qs <= Q_ISSUE;
    end
    if (qs != Q_SCROLL) begin          // skip the half-updated cycle
        bar_row <= (open && level != L_LEARN) ? (c - tp) : 4'd15;
        div_row <= (open && level == L_HOME && tp < HOME_ROWS) ? HOME_ROWS - tp : 4'd15;
    end
end

endmodule
