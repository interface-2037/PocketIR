// ir_synth.v
// M9: walks the protocol microcode (the same ROM ir_engine.v plays, format in
// tools/ir/ircompile.py) for {protocol, D, F, T} and emits the first frame as
// segments (level, ticks), one per cycle at most, with no real-time playback.
// lib/ir_match.v turns them into mark-start intervals to compare with a
// capture. The microcode semantics are ir_engine's producer's: MARK / SPACE,
// GAPTO (space up to a frame time, if any left), SEND (pulse code: mark +
// space per bit; biphase: two half-bits), END (frame done).
// Segments may repeat a level (e.g. a bit's space then GAPTO); consumers merge.
// Checked against tools/ir/irproto.py by sim/tb_ir_synth.v.

module ir_synth #(
    parameter PROG_FILE = "core/ir/ir_proto.hex"
) (
    input  wire        clk,
    input  wire        start,             // pulse (while idle): walk {proto, d, f, t}
    input  wire [5:0]  proto,
    input  wire [31:0] d,
    input  wire [31:0] f,
    input  wire        t,
    output reg         seg = 1'b0,        // pulse: one segment
    output reg         seg_level = 1'b0,
    output reg  [23:0] seg_ticks = 24'd0,
    output reg         done = 1'b0,       // pulse: the frame is complete
    output wire        busy,
    output reg  [3:0]  kind = 4'd0        // from the header: 0 pulse code, 1 RC5, 2 RC6
);

`include "ir_proto.vh"

localparam OP_MARK = 4'd2, OP_SPACE = 4'd3, OP_SEND = 4'd4, OP_GAPTO = 4'd5, OP_END = 4'd6;

reg [31:0] rom [0:IR_PROTO_WORDS-1];
initial $readmemh(PROG_FILE, rom);
reg [15:0] raddr = 16'd0;
reg [31:0] rd = 32'd0;
always @(posedge clk) rd <= rom[raddr];

localparam P_IDLE = 3'd0, P_W1 = 3'd1, P_ENT = 3'd2, P_H0 = 3'd3, P_H3 = 3'd4, P_H4 = 3'd5,
           P_DEC = 3'd6, P_BIT = 3'd7;
reg [2:0]  ps = P_IDLE, wnext = P_IDLE;
reg [31:0] d_l = 0, f_l = 0;
reg        t_l = 1'b0;
reg [15:0] hdr = 0, pc = 0;
reg [15:0] m0 = 0, s0 = 0, m1 = 0, s1 = 0;
reg [23:0] sched = 0;
reg [1:0]  src = 0, b_sh = 0;
reg        msbf = 0, inv = 0, half = 1'b0;
reg [7:0]  b_lsb = 0, b_cnt = 0, b_i = 0, b_const = 0;

assign busy = (ps != P_IDLE);

// current bit (as ir_engine.v)
wire [31:0] fval     = (src == 2'd0) ? d_l : (src == 2'd1) ? f_l : (src == 2'd2) ? {31'd0, t_l} : {24'd0, b_const};
wire [7:0]  bidx     = msbf ? (b_lsb + b_cnt - 8'd1 - b_i) : (b_lsb + b_i);
wire        bitv     = fval[bidx[4:0]] ^ inv;
wire        bp_first = (kind == 4'd2) ? bitv : ~bitv;   // RC6: 1 = mark first; RC5: 1 = space first
wire [23:0] bit_len  = (kind == 4'd0) ? {8'd0, half ? (bitv ? s1 : s0) : (bitv ? m1 : m0)} << b_sh
                                      : {8'd0, m0} << b_sh;
wire        bit_lvl  = (kind == 4'd0) ? ~half : (half ? ~bp_first : bp_first);

always @(posedge clk) begin
    seg  <= 1'b0;
    done <= 1'b0;
    case (ps)
        P_IDLE: if (start) begin
            d_l <= d; f_l <= f; t_l <= t;
            raddr <= {10'd0, proto}; wnext <= P_ENT; ps <= P_W1;
        end
        P_W1:  ps <= wnext;                                      // ROM read latency
        P_ENT: begin hdr <= rd[15:0]; raddr <= rd[15:0]; wnext <= P_H0; ps <= P_W1; end
        P_H0:  begin kind <= rd[27:24]; raddr <= hdr + 16'd3; wnext <= P_H3; ps <= P_W1; end
        P_H3:  begin {m1, m0} <= rd;    raddr <= hdr + 16'd4; wnext <= P_H4; ps <= P_W1; end
        P_H4:  begin
            {s1, s0} <= rd; sched <= 24'd0;
            pc <= hdr + 16'd7; raddr <= hdr + 16'd6; wnext <= P_DEC; ps <= P_W1;   // first frame op
        end
        P_DEC: begin
            pc <= pc + 1'b1; raddr <= pc; wnext <= P_DEC; ps <= P_W1;              // fetch the next op
            case (rd[31:28])
                OP_MARK, OP_SPACE: begin
                    seg <= 1'b1; seg_level <= (rd[31:28] == OP_MARK); seg_ticks <= rd[23:0];
                    sched <= sched + rd[23:0];
                end
                OP_GAPTO: if (rd[23:0] > sched) begin
                    seg <= 1'b1; seg_level <= 1'b0; seg_ticks <= rd[23:0] - sched;
                    sched <= rd[23:0];
                end
                OP_SEND: begin
                    src <= rd[27:26]; msbf <= rd[25]; inv <= rd[24]; b_sh <= rd[23:22];
                    b_lsb <= {2'd0, rd[21:16]}; b_cnt <= {2'd0, rd[13:8]}; b_const <= rd[7:0];
                    b_i <= 8'd0; half <= 1'b0;
                    if (rd[13:8] != 6'd0) ps <= P_BIT;                // fetch already issued: rd holds
                end                                                   // the next op when P_BIT ends
                OP_END:  begin done <= 1'b1; ps <= P_IDLE; end
                default: begin done <= 1'b1; ps <= P_IDLE; end         // bad opcode: stop
            endcase
        end
        P_BIT: begin
            seg <= 1'b1; seg_level <= bit_lvl; seg_ticks <= bit_len;
            sched <= sched + bit_len;
            half <= ~half;
            if (half) begin
                b_i <= b_i + 1'b1;
                if (b_i + 8'd1 == b_cnt) ps <= P_DEC;                // rd = next op (fetched before)
            end
        end
        default: ps <= P_IDLE;
    endcase
end

endmodule
