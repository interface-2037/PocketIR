// ir_engine.v
// Microcoded IR protocol engine (M6). Sends {protocol, address, command} using
// the protocol programs compiled by tools/ir/ircompile.py (format documented
// there). One engine covers every protocol; nothing here is protocol-specific.
//
// Structure
//   producer: walks the microcode and turns it into segments (level, units),
//             queued in a 2-entry FIFO well ahead of time; an END op queues a
//             frame-boundary marker and speculatively continues with the
//             repeat frame.
//   consumer: plays segments on exact unit ticks (unit = N clock cycles from
//             the protocol header). At a frame boundary it repeats while the
//             key is held or fewer than min frames were sent, else stops and
//             flushes the speculative work. Timing matches ir_sirc_tx.v.
//   carrier:  period/high from the protocol header, restarted on every mark.
//
// key is a level (button held). A press starts on its rising edge while idle;
// the toggle bit T flips once per press (RC5/RC6).

module ir_engine #(
    parameter PROG_FILE = "core/ir/ir_proto.hex"
) (
    input  wire        clk,
    input  wire        key,
    input  wire [5:0]  proto,
    input  wire [31:0] address,
    input  wire [31:0] command,
    output wire        envelope,
    output reg         ir_tx    = 1'b0,
    output wire        busy,
    output reg         underrun = 1'b0      // sticky: a segment was not ready (sim check)
);

`include "ir_proto.vh"

localparam OP_MARK = 4'd2, OP_SPACE = 4'd3, OP_SEND = 4'd4, OP_GAPTO = 4'd5, OP_END = 4'd6;

// ------------------------------------------------------------------ ROM
reg [31:0] rom [0:IR_PROTO_WORDS-1];
initial $readmemh(PROG_FILE, rom);
reg [15:0] raddr = 16'd0;
reg [31:0] rd = 32'd0;
always @(posedge clk) rd <= rom[raddr];

// ------------------------------------------------------------------ press state
reg [31:0] d_l = 0, f_l = 0;
reg        tgl = 1'b0;
reg [3:0]  kind = 0;                 // 0 pulse code, 1 biphase RC5, 2 biphase RC6
reg [7:0]  minf = 0;
reg [23:0] unit = 24'd1;
reg [15:0] car_period = 16'd1, car_high = 16'd0;
reg [7:0]  m0 = 0, s0 = 0, m1 = 0, s1 = 0;
reg [15:0] rep_addr = 0, hdr = 0;

// ------------------------------------------------------------------ segment FIFO
// entry: {end_marker, level, units[23:0]}
reg [25:0] q0 = 0, q1 = 0;
reg [1:0]  cnt = 2'd0;

// ------------------------------------------------------------------ consumer state
reg        running = 1'b0;
reg        cur_level = 1'b0;
reg [23:0] cur_left = 24'd0;
reg [23:0] tcnt = 24'd0;
reg [7:0]  frames_done = 8'd0;
reg        key_r = 1'b0;

// ------------------------------------------------------------------ producer state
localparam P_IDLE = 4'd0, P_W1 = 4'd1, P_ENT = 4'd2, P_H0 = 4'd3, P_H1 = 4'd4, P_H2 = 4'd5,
           P_H3 = 4'd6, P_H4 = 4'd7, P_FETCH = 4'd8, P_DEC = 4'd9, P_BIT = 4'd10;
reg [3:0]  ps = P_IDLE, wnext = P_IDLE;
reg [15:0] pc = 0;
reg [23:0] sched = 0;                // units scheduled since the frame started
reg [1:0]  src = 0;
reg        msbf = 0, inv = 0;
reg [7:0]  b_lsb = 0, b_cnt = 0, b_i = 0, b_const = 0;
reg        half = 1'b0;

assign busy     = running || (ps != P_IDLE);
assign envelope = running & cur_level;

// ------------------------------------------------------------------ consumer decisions
wire tick      = running && (tcnt == unit - 1'b1);
wire seg_end   = tick && (cur_left == 24'd1);
wire head_end  = (cnt != 0) && q0[25];
wire cont      = key || (frames_done + 8'd1 < minf);
wire stop_now  = seg_end && head_end && !cont;
wire start_now = !running && (ps != P_IDLE) && (cnt != 0) && !q0[25];
// segments popped this cycle (0, 1, or 2 = END marker + next frame's first)
wire [1:0] pops = start_now ? 2'd1 :
                  (seg_end && !head_end && cnt != 0) ? 2'd1 :
                  (seg_end && head_end && cont && cnt == 2) ? 2'd2 : 2'd0;
wire [25:0] next_seg = (pops == 2'd2) ? q1 : q0;

// ------------------------------------------------------------------ producer: current bit
wire [31:0] fval    = (src == 2'd0) ? d_l : (src == 2'd1) ? f_l : (src == 2'd2) ? {31'd0, tgl} : {24'd0, b_const};
wire [7:0]  bidx    = msbf ? (b_lsb + b_cnt - 8'd1 - b_i) : (b_lsb + b_i);
wire        bitv    = fval[bidx[4:0]] ^ inv;
wire        bp_first = (kind == 4'd2) ? bitv : ~bitv;   // RC6: 1 = mark first; RC5: 1 = space first

// producer wants to push this segment (only when there is room)
reg        push;
reg [25:0] push_seg;
always @(*) begin
    push = 1'b0;
    push_seg = 26'd0;
    if (ps == P_DEC) begin
        case (rd[31:28])
            OP_MARK:  begin push = 1'b1; push_seg = {1'b0, 1'b1, rd[23:0]}; end
            OP_SPACE: begin push = 1'b1; push_seg = {1'b0, 1'b0, rd[23:0]}; end
            OP_GAPTO: if (rd[23:0] > sched) begin push = 1'b1; push_seg = {1'b0, 1'b0, rd[23:0] - sched}; end
            OP_END:   begin push = 1'b1; push_seg = {1'b1, 1'b0, 24'd0}; end
            default:  ;
        endcase
    end else if (ps == P_BIT) begin
        push = 1'b1;
        if (kind == 4'd0)
            push_seg = half ? {1'b0, 1'b0, 16'd0, bitv ? s1 : s0}
                            : {1'b0, 1'b1, 16'd0, bitv ? m1 : m0};
        else
            push_seg = {1'b0, half ? ~bp_first : bp_first, 16'd0, m0};
    end
end
wire room   = (cnt < 2'd2);
wire do_push = push && room && !stop_now;

always @(posedge clk) begin
    key_r <= key;

    // ---------------- FIFO update
    if (stop_now) begin
        cnt <= 2'd0;
    end else begin
        case (pops)
            2'd1: begin q0 <= q1; end
            2'd2: ;
            default: ;
        endcase
        if (do_push) begin
            if (cnt - pops == 2'd0) q0 <= push_seg;
            else                    q1 <= push_seg;
        end
        cnt <= cnt - pops + (do_push ? 2'd1 : 2'd0);
    end

    // ---------------- consumer
    if (start_now) begin
        running     <= 1'b1;
        cur_level   <= next_seg[24];
        cur_left    <= next_seg[23:0];
        tcnt        <= 24'd0;
        frames_done <= 8'd0;
    end else if (running) begin
        tcnt <= tick ? 24'd0 : tcnt + 1'b1;
        if (tick && !seg_end) cur_left <= cur_left - 1'b1;
        if (seg_end) begin
            if (stop_now) begin
                running   <= 1'b0;
                cur_level <= 1'b0;
            end else if (pops != 0) begin
                cur_level <= next_seg[24];
                cur_left  <= next_seg[23:0];
                if (head_end) frames_done <= frames_done + 1'b1;
            end else begin
                underrun  <= 1'b1;        // next segment not ready in time
                running   <= 1'b0;
                cur_level <= 1'b0;
            end
        end
    end
    // ---------------- producer
    if (stop_now) begin
        ps <= P_IDLE;
    end else case (ps)
        P_IDLE: if (key && !key_r && !running) begin
            d_l <= address; f_l <= command; tgl <= ~tgl;
            raddr <= {10'd0, proto}; wnext <= P_ENT; ps <= P_W1;
        end
        P_W1:  ps <= wnext;                                    // ROM read latency
        P_ENT: begin hdr <= rd[15:0]; raddr <= rd[15:0];        wnext <= P_H0; ps <= P_W1; end
        P_H0:  begin kind <= rd[27:24]; minf <= rd[23:16]; raddr <= hdr + 16'd1; wnext <= P_H1; ps <= P_W1; end
        P_H1:  begin unit <= rd[23:0];                        raddr <= hdr + 16'd2; wnext <= P_H2; ps <= P_W1; end
        P_H2:  begin car_high <= rd[31:16]; car_period <= rd[15:0]; raddr <= hdr + 16'd3; wnext <= P_H3; ps <= P_W1; end
        P_H3:  begin {s1, m1, s0, m0} <= rd;                  raddr <= hdr + 16'd4; wnext <= P_H4; ps <= P_W1; end
        P_H4:  begin rep_addr <= rd[15:0]; pc <= hdr + 16'd5; sched <= 24'd0; ps <= P_FETCH; end
        P_FETCH: begin raddr <= pc; wnext <= P_DEC; ps <= P_W1; end
        P_DEC: case (rd[31:28])
            OP_MARK, OP_SPACE: if (do_push) begin sched <= sched + rd[23:0]; pc <= pc + 1'b1; ps <= P_FETCH; end
            OP_GAPTO: if (!push || do_push) begin
                          if (rd[23:0] > sched) sched <= rd[23:0];
                          pc <= pc + 1'b1; ps <= P_FETCH;
                      end
            OP_END:   if (do_push) begin sched <= 24'd0; pc <= rep_addr; ps <= P_FETCH; end
            OP_SEND:  begin
                          src <= rd[27:26]; msbf <= rd[25]; inv <= rd[24];
                          b_lsb <= rd[23:16]; b_cnt <= rd[15:8]; b_const <= rd[7:0];
                          b_i <= 8'd0; half <= 1'b0;
                          ps <= (rd[15:8] == 8'd0) ? P_FETCH : P_BIT;
                          if (rd[15:8] == 8'd0) pc <= pc + 1'b1;
                      end
            default:  ps <= P_IDLE;                          // bad opcode: give up
        endcase
        P_BIT: if (do_push) begin
            sched <= sched + push_seg[23:0];
            if (half) begin
                half <= 1'b0;
                if (b_i + 8'd1 == b_cnt) begin pc <= pc + 1'b1; ps <= P_FETCH; end
                b_i <= b_i + 1'b1;
            end else begin
                half <= 1'b1;
            end
        end
        default: ps <= P_IDLE;
    endcase

end

// carrier generator (separate block for clarity)
reg [15:0] car_cnt = 16'd0;
always @(posedge clk) begin
    if (!envelope) begin
        car_cnt <= 16'd0;
        ir_tx   <= 1'b0;
    end else begin
        car_cnt <= (car_cnt == car_period - 1'b1) ? 16'd0 : car_cnt + 1'b1;
        ir_tx   <= (car_cnt < car_high);
    end
end

endmodule
