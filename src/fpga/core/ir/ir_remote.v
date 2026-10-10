// ir_remote.v
// Pocket buttons -> the selected device's codes (dev_ctrl.v code table) ->
// ir_engine (M6) -> IR LED.
//
// Buttons map to functions by their position in the 180-degree grip (see
// CLAUDE.md): Start POWER, Select MUTE, L1 VOL_UP, R1 VOL_DOWN, d-pad
// Down/Up/Right/Left = UP/DOWN/LEFT/RIGHT, Y OK, X BACK, B MENU, A INPUT.
// A function the device lacks does nothing.
//
// The lowest-numbered pressed button with a code is sent. A tap sends the
// protocol's minimum frames; holding repeats. If a different button is pressed
// while a code is still going out, the old code finishes its minimum frames,
// then the new button starts -- a held button never repeats another's code.
//
// Start + Select chord (M7): a press of Start or Select waits up to CHORD_MS
// for the other. Both -> `chord` pulses once and nothing is sent. One alone ->
// it is passed through after the wait (held: sent while held; released
// early: sent as a tap).

module ir_remote #(
    parameter PROG_FILE = "core/ir/ir_proto.hex",     // protocol microcode (ircompile.py)
    parameter CLK_HZ    = 74_250_000,
    parameter CHORD_MS  = 150
) (
    input  wire        clk,
    input  wire [15:0] keys,          // cont1_key[15:0]
    output wire        ir_tx,
    output wire        envelope,
    output wire        busy,
    output reg  [3:0]  active_idx = 4'd0,
    output reg         chord = 1'b0,  // one-cycle pulse: Start + Select pressed together
    // code table (dev_ctrl.v)
    output wire [3:0]  code_func,
    input  wire        code_valid,
    input  wire [5:0]  code_proto,
    input  wire [31:0] code_d,
    input  wire [31:0] code_f
);

// Two register stages on the buttons (cont1_key is already in clk's domain).
reg [15:0] keys_r1 = 16'd0, keys_r2 = 16'd0;
always @(posedge clk) begin
    keys_r1 <= keys;
    keys_r2 <= keys_r1;
end

// ------------------------------------------------------------------ Start/Select chord filter
localparam WIN = CLK_HZ / 1000 * CHORD_MS;
localparam TAP = CLK_HZ / 1000 * 10;                   // synthetic press for an early release
localparam C_IDLE = 3'd0, C_WAIT = 3'd1, C_PASS = 3'd2, C_TAP = 3'd3, C_CHORD = 3'd4;
reg [2:0]  cs = C_IDLE;
reg [31:0] ct = 0;
reg        first = 1'b0;          // 1 = Start (bit 15) came first, 0 = Select (bit 14)
wire       st_k = keys_r2[15], se_k = keys_r2[14];
reg  [1:0] ss_out;                // filtered {Start, Select}

always @(posedge clk) begin
    chord <= 1'b0;
    case (cs)
        C_IDLE: if (st_k || se_k) begin first <= st_k; ct <= 0; cs <= C_WAIT; end
        C_WAIT: begin
            ct <= ct + 1'b1;
            if (st_k && se_k)          begin chord <= 1'b1; cs <= C_CHORD; end
            else if (!st_k && !se_k)   begin ct <= 0; cs <= C_TAP; end      // quick tap
            else if (ct == WIN - 1)    cs <= C_PASS;
        end
        C_PASS:  if (!st_k && !se_k) cs <= C_IDLE;
        C_TAP:   begin ct <= ct + 1'b1; if (ct == TAP - 1) cs <= C_IDLE; end
        C_CHORD: if (!st_k && !se_k) cs <= C_IDLE;
        default: cs <= C_IDLE;
    endcase
end
always @(*) case (cs)
    C_PASS:  ss_out = {st_k, se_k};
    C_TAP:   ss_out = first ? 2'b10 : 2'b01;
    default: ss_out = 2'b00;                            // waiting or chord: hold back
endcase
wire [15:0] kf = {ss_out, keys_r2[13:0]};

// ------------------------------------------------------------------ button -> function
function [4:0] pick(input [15:0] k);     // {any, idx[3:0]}: lowest mapped bit wins
    integer i;
begin
    pick = 5'd0;
    for (i = 15; i >= 0; i = i - 1)
        if (k[i] && (i <= 9 || i == 14 || i == 15))
            pick = {1'b1, i[3:0]};
end
endfunction

function [3:0] key2func(input [3:0] k);  // library function index (library.FUNCS)
    case (k)
        4'd15: key2func = 4'd0;   // Start  -> POWER
        4'd8:  key2func = 4'd1;   // L1     -> VOL_UP   (right shoulder in the grip)
        4'd9:  key2func = 4'd2;   // R1     -> VOL_DOWN
        4'd14: key2func = 4'd3;   // Select -> MUTE
        4'd1:  key2func = 4'd4;   // Down   -> UP       (top of the d-pad in the grip)
        4'd0:  key2func = 4'd5;   // Up     -> DOWN
        4'd3:  key2func = 4'd6;   // Right  -> LEFT
        4'd2:  key2func = 4'd7;   // Left   -> RIGHT
        4'd7:  key2func = 4'd8;   // Y      -> OK
        4'd6:  key2func = 4'd9;   // X      -> BACK
        4'd5:  key2func = 4'd10;  // B      -> MENU
        4'd4:  key2func = 4'd11;  // A      -> INPUT
        default: key2func = 4'd15;
    endcase
endfunction

wire       sel_any;
wire [3:0] sel_idx;
assign {sel_any, sel_idx} = pick(kf);

assign code_func = key2func(busy ? active_idx : sel_idx);

always @(posedge clk)
    if (!busy) active_idx <= sel_idx;

// Key to the encoder: only "held" while the same button is still the one
// selected, so repeats stop when the user switches buttons.
wire enc_key = sel_any && code_valid && (!busy || sel_idx == active_idx);

ir_engine #(.PROG_FILE(PROG_FILE)) engine (
    .clk(clk), .key(enc_key), .proto(code_proto),
    .address(code_d), .command(code_f),
    .envelope(envelope), .ir_tx(ir_tx), .busy(busy), .underrun());

endmodule
