// ir_sirc_tx.v
// Sony SIRC encoder. Outputs an envelope (1 = carrier on); gate a 40 kHz
// carrier with it. All timing is in units of T = 600 us:
//   header : 4T mark, 1T space
//   bit 1  : 2T mark, 1T space        bit 0 : 1T mark, 1T space
//   bits   : command[6:0] then address, LSB first
//            12-bit: 5-bit address, 15-bit: 8-bit, 20-bit: 13-bit
//   frames repeat every 75T (45 ms) start-to-start; Sony gear expects at
//   least 3 frames, so a tap sends MIN_FRAMES and holding the key keeps
//   repeating.
//
// key is a level (button held). Its rising edge latches nbits/address/command
// and starts sending; frames continue while key stays high.

module ir_sirc_tx #(
    parameter CLK_HZ     = 74_250_000,
    parameter T_US       = 600,
    parameter MIN_FRAMES = 3
) (
    input  wire        clk,
    input  wire        key,
    input  wire [4:0]  nbits,      // 12, 15 or 20
    input  wire [12:0] address,
    input  wire [6:0]  command,
    output reg         envelope = 1'b0,
    output wire        busy
);

localparam T_CYC       = CLK_HZ / 1_000_000 * T_US + (CLK_HZ % 1_000_000) * T_US / 1_000_000;
localparam FRAME_T     = 75;
localparam TW          = $clog2(T_CYC);

localparam S_IDLE      = 3'd0,
           S_HDR_MARK  = 3'd1,
           S_HDR_SPACE = 3'd2,
           S_BIT_MARK  = 3'd3,
           S_BIT_SPACE = 3'd4,
           S_GAP       = 3'd5;

reg [2:0]    state    = S_IDLE;
reg [TW-1:0] tcnt     = 0;       // cycles within the current T
reg [6:0]    frame_t  = 0;       // T units since frame start
reg [6:0]    seg_left = 0;       // T units left in current segment
reg [19:0]   frame_data = 0;     // latched {address, command}
reg [19:0]   shift    = 0;
reg [4:0]    nbits_l  = 0;
reg [4:0]    bit_idx  = 0;
reg [7:0]    frames   = 0;       // frames completed in this press
reg          key_r    = 1'b0;

assign busy = (state != S_IDLE);

wire tick = (tcnt == T_CYC - 1);

always @(posedge clk) begin
    key_r <= key;

    if (state == S_IDLE) begin
        envelope <= 1'b0;
        if (key && !key_r) begin
            frame_data <= ({7'd0, address} << 7) | {13'd0, command};
            shift      <= ({7'd0, address} << 7) | {13'd0, command};
            nbits_l    <= nbits;
            frames     <= 0;
            bit_idx    <= 0;
            tcnt       <= 0;
            frame_t    <= 0;
            seg_left   <= 7'd4;
            envelope   <= 1'b1;
            state      <= S_HDR_MARK;
        end
    end else if (!tick) begin
        tcnt <= tcnt + 1'b1;
    end else begin
        tcnt    <= 0;
        frame_t <= frame_t + 1'b1;
        if (seg_left != 1) begin
            seg_left <= seg_left - 1'b1;
        end else begin
            case (state)
                S_HDR_MARK: begin
                    state <= S_HDR_SPACE; seg_left <= 7'd1; envelope <= 1'b0;
                end
                S_HDR_SPACE: begin
                    state <= S_BIT_MARK; seg_left <= shift[0] ? 7'd2 : 7'd1; envelope <= 1'b1;
                end
                S_BIT_MARK: begin
                    state <= S_BIT_SPACE; seg_left <= 7'd1; envelope <= 1'b0;
                end
                S_BIT_SPACE: begin
                    if (bit_idx == nbits_l - 1) begin
                        state    <= S_GAP;
                        seg_left <= FRAME_T - (frame_t + 1'b1);
                    end else begin
                        shift    <= shift >> 1;
                        bit_idx  <= bit_idx + 1'b1;
                        state    <= S_BIT_MARK;
                        seg_left <= shift[1] ? 7'd2 : 7'd1;
                        envelope <= 1'b1;
                    end
                end
                S_GAP: begin
                    if (key || frames + 1 < MIN_FRAMES) begin
                        frames   <= frames + 1'b1;
                        shift    <= frame_data;
                        bit_idx  <= 0;
                        frame_t  <= 0;
                        seg_left <= 7'd4;
                        envelope <= 1'b1;
                        state    <= S_HDR_MARK;
                    end else begin
                        state    <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
end

endmodule
