// menu.v
// Device menu navigation (M7). Turns button presses into dev_ctrl.v commands;
// the reference model is tools/ui/ui_menu.py (Menu.press), checked by
// sim/tb_remote.v against build/ir_expected/menu_steps.txt.
//
//   Start + Select (chord)  open at level 0 (cursor on the current device's
//                           type) / close and reload the current device
//   up / down               move the cursor (held: auto-repeat)
//   left / right            brand list: A-Z jump; other levels: page of 9
//   OK                      type -> brands -> code sets -> choose (LOAD, close)
//   BACK                    up a level; at the top: close
//   POWER (code-set level)  TEST: send the highlighted set's POWER
// At the code-set level every cursor change loads that set's codes (CODES)
// so TEST sends the right POWER; closing reloads the chosen/current device.
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
    output reg  [7:0]  dev_t = BOOT_T,    // current device
    output reg  [15:0] dev_b = BOOT_B,
    output reg  [15:0] dev_s = BOOT_S,
    // dev_ctrl.v
    output reg         dc_start = 1'b0,
    output reg  [1:0]  dc_cmd = 2'd0,
    output reg  [1:0]  dc_level = 2'd0,
    output reg  [7:0]  dc_t = 8'd0,
    output reg  [15:0] dc_b = 16'd0,
    output reg  [15:0] dc_s = 16'd0,
    output reg  [15:0] dc_cur = 16'd0,
    output reg  [15:0] dc_top = 16'd0,
    output reg         dc_dir = 1'b0,
    input  wire        dc_busy,
    input  wire [15:0] n_items,
    input  wire [15:0] jump_res
);

localparam CMD_LOAD = 2'd0, CMD_CODES = 2'd1, CMD_PAGE = 2'd2, CMD_JUMP = 2'd3;
localparam ROWS = 9;
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
reg  [1:0]  level = 2'd0;
reg  [15:0] cur0 = 0, cur1 = 0, cur2 = 0, top0 = 0, top1 = 0, top2 = 0;
reg  [15:0] n = 16'd1;                 // entries at the current level (from the last PAGE)
wire [15:0] c   = (level == 2'd0) ? cur0 : (level == 2'd1) ? cur1 : cur2;
wire [15:0] tp  = (level == 2'd0) ? top0 : (level == 2'd1) ? top1 : top2;

// command queue: up to two commands per action (CODES/JUMP, then PAGE), or LOAD
localparam Q_IDLE = 3'd0, Q_ISSUE = 3'd1, Q_WAIT = 3'd2, Q_JUMPED = 3'd3, Q_BOOT = 3'd4;
reg  [2:0]  qs = Q_BOOT;
reg  [1:0]  q_cmd [0:1];
reg         q_n = 1'b0, q_i = 1'b0, q_dir = 1'b0;
reg  [31:0] tcount = 0;
assign busy = (qs != Q_IDLE);

task set_cur(input [15:0] v);          // cursor of the current level, then scroll to keep it visible
    begin
        case (level)
            2'd0: begin cur0 <= v; if (v < top0) top0 <= v; else if (v >= top0 + ROWS) top0 <= v - (ROWS - 1); end
            2'd1: begin cur1 <= v; if (v < top1) top1 <= v; else if (v >= top1 + ROWS) top1 <= v - (ROWS - 1); end
            default: begin cur2 <= v; if (v < top2) top2 <= v; else if (v >= top2 + ROWS) top2 <= v - (ROWS - 1); end
        endcase
    end
endtask

function [15:0] scrolled_top(input [15:0] v);   // top for a fresh level (top = 0, then scroll)
    scrolled_top = (v >= ROWS) ? v - (ROWS - 1) : 16'd0;
endfunction

always @(posedge clk) begin
    dc_start <= 1'b0;
    if (test_key) begin
        tcount <= tcount + 1'b1;
        if (tcount == TPULSE - 1) test_key <= 1'b0;
    end
    case (qs)
        Q_BOOT: ;                                             // wait for the first boot pulse
        Q_IDLE: begin
            if (chord) begin
                if (!open) begin
                    open <= 1'b1; level <= 2'd0;
                    cur0 <= {8'd0, dev_t}; top0 <= scrolled_top({8'd0, dev_t});
                    q_cmd[0] <= CMD_PAGE; q_n <= 1'b0;
                end else begin
                    open <= 1'b0; q_cmd[0] <= CMD_LOAD; q_n <= 1'b0;
                end
                q_i <= 1'b0; qs <= Q_ISSUE;
            end else if (open && ev != 7'd0) begin
                q_i <= 1'b0; q_n <= 1'b0; q_cmd[0] <= CMD_PAGE; q_cmd[1] <= CMD_PAGE;
                qs <= Q_ISSUE;
                if (ev[F_UP] || ev[F_DOWN]) begin
                    if (ev[F_DOWN]) set_cur((c + 1 < n) ? c + 1'b1 : c);
                    else            set_cur((c != 0) ? c - 1'b1 : c);
                    if (level == 2'd2) begin q_cmd[0] <= CMD_CODES; q_n <= 1'b1; end
                end else if (ev[F_LEFT] || ev[F_RIGHT]) begin
                    if (level == 2'd1) begin
                        q_cmd[0] <= CMD_JUMP; q_dir <= ev[F_RIGHT]; q_n <= 1'b1;
                    end else begin
                        if (ev[F_RIGHT]) set_cur((c + ROWS < n) ? c + ROWS : n - 1'b1);
                        else             set_cur((c >= ROWS) ? c - ROWS : 16'd0);
                        if (level == 2'd2) begin q_cmd[0] <= CMD_CODES; q_n <= 1'b1; end
                    end
                end else if (ev[F_OK]) begin
                    if (level == 2'd0) begin
                        level <= 2'd1;
                        cur1 <= (cur0 == {8'd0, dev_t}) ? dev_b : 16'd0;
                        top1 <= scrolled_top((cur0 == {8'd0, dev_t}) ? dev_b : 16'd0);
                    end else if (level == 2'd1) begin
                        level <= 2'd2;
                        cur2 <= (cur0 == {8'd0, dev_t} && cur1 == dev_b) ? dev_s : 16'd0;
                        top2 <= scrolled_top((cur0 == {8'd0, dev_t} && cur1 == dev_b) ? dev_s : 16'd0);
                        q_cmd[0] <= CMD_CODES; q_n <= 1'b1;
                    end else begin                            // choose this set
                        dev_t <= cur0[7:0]; dev_b <= cur1; dev_s <= cur2;
                        open <= 1'b0; q_cmd[0] <= CMD_LOAD;
                    end
                end else if (ev[F_BACK]) begin
                    if (level == 2'd0) begin open <= 1'b0; q_cmd[0] <= CMD_LOAD; end
                    else level <= level - 1'b1;
                end else if (ev[F_POWER] && level == 2'd2) begin
                    test_key <= 1'b1; tcount <= 0; qs <= Q_IDLE;      // TEST: nothing to redraw
                end else qs <= Q_IDLE;                                   // key unused at this level
            end
        end
        Q_ISSUE: if (!dc_busy && !dc_start) begin
            dc_cmd   <= q_cmd[q_i];
            dc_level <= level;
            // LOAD uses the current device; CODES/PAGE/JUMP the menu cursors
            dc_t <= (q_cmd[q_i] == CMD_LOAD) ? dev_t : cur0[7:0];
            dc_b <= (q_cmd[q_i] == CMD_LOAD) ? dev_b : cur1;
            dc_s <= (q_cmd[q_i] == CMD_LOAD) ? dev_s : cur2;
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
        Q_JUMPED: begin set_cur(jump_res); q_i <= 1'b1; qs <= Q_ISSUE; end    // then PAGE
        default: qs <= Q_IDLE;
    endcase
    if (boot) begin                    // (re)start: load the boot device, menu closed
        dev_t <= boot_t; dev_b <= boot_b; dev_s <= boot_s;
        open <= 1'b0; test_key <= 1'b0;
        q_cmd[0] <= CMD_LOAD; q_n <= 1'b0; q_i <= 1'b0; qs <= Q_ISSUE;
    end
    bar_row <= open ? (c - tp) : 4'd15;
end

endmodule
