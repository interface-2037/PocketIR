// ir_rx_marks.v
// M9: receiver front end for remote identification. The Pocket's receiver
// (port_ir_rx: idle high, raw carrier, but only the first ~50-300 us of each
// mark; hardware v0.10.0) loses mark lengths but times mark starts well, so
// this records start-to-start intervals:
//   - a mark start is an active edge after >= IDLE_MIN_US of idle (carrier
//     pulses and edge chatter inside a mark don't count);
//   - intervals are counted in engine ticks (TICK_CLK clocks) with the tick
//     prescaler restarted at every mark start; 16-bit, saturating;
//   - a burst ends END_MS after its last mark start; if it had >= MIN_MARKS
//     marks, `done` pulses and the intervals stay readable until the next
//     burst. No burst starts while `hold` is high (the matcher is reading).
// Bit-exact model: tools/ir/rxcap.py (mark_starts, cap_intervals).

module ir_rx_marks #(
    parameter CLK_HZ      = 74_250_000,
    parameter TICK_CLK    = 297,          // 4 us (irproto.TICK_US)
    parameter ACTIVE      = 1'b0,         // receiver output level during a mark
    parameter IDLE_MIN_US = 250,
    parameter END_MS      = 200,
    parameter MIN_MARKS   = 4,
    parameter DEPTH_LOG2  = 8
) (
    input  wire        clk,
    input  wire        enable,            // learning: receiver powered
    input  wire        rx,                // port_ir_rx (asynchronous)
    input  wire        hold,
    output reg         active = 1'b0,     // a burst is being recorded
    output reg         done = 1'b0,       // pulse: a burst ended with >= MIN_MARKS marks
    output reg  [DEPTH_LOG2:0] n_iv = 0,  // intervals in the last finished burst
    input  wire [DEPTH_LOG2-1:0] raddr,
    output reg  [15:0] rq = 16'd0         // interval[raddr], one cycle later
);

localparam [31:0] IDLE_MIN = CLK_HZ / 1_000_000 * IDLE_MIN_US;
localparam [15:0] END_TICKS = END_MS * 1000 / 4;
localparam        DEPTH = 1 << DEPTH_LOG2;

reg [15:0] mem [0:DEPTH-1];
reg        we = 1'b0;
reg [DEPTH_LOG2-1:0] waddr = 0;
reg [15:0] wdata = 16'd0;
always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    rq <= mem[raddr];
end

reg        rx1 = 1'b0, rx2 = 1'b0, rx3 = 1'b0;
reg [31:0] idle_cnt = 32'hFFFF_FFFF;      // clocks since the receiver was last active
reg [8:0]  pre = 9'd0;
reg [15:0] iv = 16'd0;                    // ticks since the last mark start
reg [DEPTH_LOG2:0] n = 0;                 // intervals recorded in this burst

wire act_now    = (rx2 == ACTIVE);
wire mark_start = act_now && (rx3 != ACTIVE) && (idle_cnt >= IDLE_MIN);

always @(posedge clk) begin
    rx1 <= rx; rx2 <= rx1; rx3 <= rx2;
    idle_cnt <= act_now ? 32'd0 : (idle_cnt == 32'hFFFF_FFFF ? idle_cnt : idle_cnt + 1'b1);
    we   <= 1'b0;
    done <= 1'b0;

    if (mark_start) begin
        pre <= 9'd1; iv <= 16'd0;
    end else if (pre == TICK_CLK - 1) begin
        pre <= 9'd0; if (iv != 16'hFFFF) iv <= iv + 1'b1;
    end else pre <= pre + 1'b1;

    if (!enable) active <= 1'b0;
    else if (active) begin
        if (mark_start) begin
            if (n != DEPTH) begin
                we <= 1'b1; waddr <= n[DEPTH_LOG2-1:0]; wdata <= iv;
                n <= n + 1'b1;
            end
        end else if (iv >= END_TICKS) begin
            active <= 1'b0;
            if (n + 1'b1 >= MIN_MARKS) begin done <= 1'b1; n_iv <= n; end
        end
    end else if (mark_start && !hold) begin
        active <= 1'b1; n <= 0;
    end
end

endmodule
