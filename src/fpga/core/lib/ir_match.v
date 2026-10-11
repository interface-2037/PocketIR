// ir_match.v
// M9: identify a remote. Scans every menu entry of the code library (format:
// docs/codes-format.md) and keeps those with a code whose first frame appears
// in the captured mark-start intervals (ir/ir_rx_marks.v). Each code's
// intervals come from ir_synth.v walking the protocol microcode, so the
// comparison follows the transmitter's own timing for every protocol.
//
// Rules (bit-exact model: tools/ir/rxcap.py match_library / readable):
//   - frame starts ("candidates"): the first mark, and every mark after an
//     interval >= FRAME_GAP (first MAX_CAND only);
//   - a code matches at a candidate if each of its intervals is within
//     max(TOL_MIN, interval / 16) of the capture's, and the frame is followed
//     by an interval >= FRAME_GAP or the end of the capture;
//   - biphase protocols (RC5/RC6) are tried with toggle 0, then 1;
//   - an entry matches if any of its codes does.
//
// Results: the matching entries in library order as {type, brand, set} words
// (list RAM, read by the menu), and a bitmap by entry index for narrowing.
// `narrow` keeps only entries that matched last time; if none would remain,
// the previous list is rebuilt and kept (result 3, or 2 if unreadable).
//   result: 0 matches, 1 no match (a frame-like burst was read),
//           2 couldn't read (no run of MIN_FRAME_MARKS marks), 3 narrowing found none
// A full scan is ~2M cycles (~30 ms).

module ir_match #(
    parameter PROG_FILE       = "core/ir/ir_proto.hex",
    parameter IV_LOG2         = 8,
    parameter MAX_CAND        = 32,
    parameter [15:0] FRAME_GAP = 16'd1000,   // ticks (4 ms)
    parameter [15:0] TOL_MIN   = 16'd40,     // ticks (160 us)
    parameter MIN_FRAME_MARKS = 8
) (
    input  wire        clk,
    input  wire        start,               // pulse
    input  wire        narrow,
    input  wire [IV_LOG2:0] n_iv,           // captured intervals (ir_rx_marks.v)
    output reg  [IV_LOG2-1:0] iv_addr = 0,
    input  wire [15:0] iv_q,                // interval[iv_addr], one cycle later
    output reg  [15:0] lib_addr = 16'd0,    // library ROM (dev_ctrl.v second port)
    input  wire [7:0]  lib_q,
    output wire        busy,
    output reg         done = 1'b0,         // pulse
    output reg  [1:0]  result = 2'd0,
    output reg  [15:0] n_match = 16'd0,
    input  wire [9:0]  list_raddr,
    output reg  [31:0] list_q = 32'd0       // {type[7:0], brand[11:0], set[11:0]}
);

localparam CW = IV_LOG2 + 1;

// ------------------------------------------------------------------ RAMs
reg [31:0] list [0:1023];
reg        list_we = 1'b0;
reg [9:0]  list_wa = 10'd0;
reg [31:0] list_wd = 32'd0;
always @(posedge clk) begin
    if (list_we) list[list_wa] <= list_wd;
    list_q <= list[list_raddr];
end

reg        bm [0:2047];                 // two banks of entry bits: {bank, entry}
reg        bm_we = 1'b0, bm_wd = 1'b0, bm_q = 1'b0;
reg [10:0] bm_wa = 11'd0, bm_ra = 11'd0;
always @(posedge clk) begin
    if (bm_we) bm[bm_wa] <= bm_wd;
    bm_q <= bm[bm_ra];
end

reg [15:0]   ref_iv [0:63];             // the code's first-frame intervals
reg [CW-1:0] cand [0:MAX_CAND-1];

// ------------------------------------------------------------------ synth
reg        sy_start = 1'b0, sy_t = 1'b0;
reg [5:0]  sy_p = 6'd0;
reg [31:0] sy_d = 32'd0, sy_f = 32'd0;
wire       sy_seg, sy_lvl, sy_done, sy_busy;
wire [23:0] sy_ticks;
wire [3:0] sy_kind;
ir_synth #(.PROG_FILE(PROG_FILE)) synth (
    .clk(clk), .start(sy_start), .proto(sy_p), .d(sy_d), .f(sy_f), .t(sy_t),
    .seg(sy_seg), .seg_level(sy_lvl), .seg_ticks(sy_ticks), .done(sy_done),
    .busy(sy_busy), .kind(sy_kind));

// ------------------------------------------------------------------ state
reg [5:0]  st = 6'd0;
localparam S_IDLE = 6'd0, S_RD0 = 6'd1, S_RD1 = 6'd2, S_RD2 = 6'd3,
           S_PRE0 = 6'd4, S_PRE1 = 6'd5, S_PRE2 = 6'd6,
           S_HDR0 = 6'd7, S_HDR1 = 6'd8, S_HDR2 = 6'd9,
           S_T0 = 6'd10, S_T1 = 6'd11, S_T2 = 6'd12,
           S_B0 = 6'd13, S_B1 = 6'd14, S_B2 = 6'd15,
           S_E0 = 6'd16, S_E1 = 6'd17, S_E2 = 6'd18, S_E3 = 6'd19, S_E4 = 6'd20, S_E5 = 6'd21,
           S_F0 = 6'd22, S_F1 = 6'd23, S_F2 = 6'd24, S_F3 = 6'd25, S_F4 = 6'd26, S_F5 = 6'd27,
           S_TEST0 = 6'd28, S_TEST1 = 6'd29, S_C0 = 6'd30, S_C1 = 6'd31, S_C2 = 6'd32, S_C3 = 6'd33,
           S_ENT = 6'd34, S_END = 6'd35, S_BMR = 6'd36;
reg [5:0]  ret = 6'd0;
reg [15:0] rd_a = 16'd0;
reg [2:0]  rd_n = 3'd0, rd_k = 3'd0;
reg [31:0] val = 32'd0;

reg        nar = 1'b0, rebuild = 1'b0, sel = 1'b0, readable = 1'b0;
reg [15:0] ntypes = 0, type_off = 0, btab = 0, nb = 0, lst = 0, ns = 0, cs = 0, ptr = 0, mask = 0;
reg [7:0]  t = 0;
reg [11:0] b = 0, s = 0;
reg [9:0]  g = 0;
reg [10:0] nm = 0;
reg [3:0]  fn = 0;
reg [5:0]  dp = 0, cp = 0;
reg [31:0] dd = 0, cd = 0, cf = 0;
reg        matched = 1'b0, endchk = 1'b0;
reg [CW-1:0] k = 0, ncand = 0, c = 0, sc = 0;
reg [7:0]  run = 0;
// synth collection
reg [23:0] tt = 0, last = 0;
reg        prev = 1'b0, any = 1'b0;
reg [6:0]  nref = 0;

assign busy = (st != S_IDLE);

wire [15:0] rk   = ref_iv[k[5:0]];
wire [15:0] tolk = (rk[15:4] > TOL_MIN) ? {4'd0, rk[15:4]} : TOL_MIN;
wire [15:0] diff = (iv_q > rk) ? iv_q - rk : rk - iv_q;
wire [23:0] gap  = tt - last;

`define RD(addr, nbytes, next) begin rd_a <= (addr); rd_n <= (nbytes); ret <= (next); st <= S_RD0; end

always @(posedge clk) begin
    done     <= 1'b0;
    sy_start <= 1'b0;
    list_we  <= 1'b0;
    bm_we    <= 1'b0;

    // collect the synth's mark starts as intervals (runs alongside S_TEST1)
    if (sy_seg) begin
        if (sy_lvl && !prev) begin
            if (any && nref != 7'd64) begin
                ref_iv[nref[5:0]] <= (gap > 24'hFFFF) ? 16'hFFFF : gap[15:0];
                nref <= nref + 1'b1;
            end
            any <= 1'b1; last <= tt;
        end
        tt <= tt + sy_ticks; prev <= sy_lvl;
    end

    case (st)
    // ---------------------------------------------------------------- byte reads (LE)
    S_RD0: begin lib_addr <= rd_a; rd_k <= 3'd0; val <= 32'd0; st <= S_RD1; end
    S_RD1: st <= S_RD2;
    S_RD2: begin
        val <= val | ({24'd0, lib_q} << (8 * rd_k));
        if (rd_k + 1'b1 == rd_n) st <= ret;
        else begin rd_k <= rd_k + 1'b1; lib_addr <= lib_addr + 1'b1; st <= S_RD1; end
    end

    // ---------------------------------------------------------------- start: candidates
    S_IDLE: if (start) begin
        nar <= narrow; rebuild <= 1'b0;
        cand[0] <= {CW{1'b0}}; ncand <= 1; run <= 8'd1; readable <= 1'b0; k <= 0;
        st <= S_PRE0;
    end
    S_PRE0: if (k == n_iv) st <= S_HDR0;
            else begin iv_addr <= k[IV_LOG2-1:0]; st <= S_PRE1; end
    S_PRE1: st <= S_PRE2;
    S_PRE2: begin
        if (iv_q >= FRAME_GAP) begin
            run <= 8'd1;
            if (ncand != MAX_CAND) begin cand[ncand] <= k + 1'b1; ncand <= ncand + 1'b1; end
        end else begin
            if (run + 1'b1 >= MIN_FRAME_MARKS) readable <= 1'b1;
            if (run != 8'hFF) run <= run + 1'b1;
        end
        k <= k + 1'b1; st <= S_PRE0;
    end

    // ---------------------------------------------------------------- library walk
    S_HDR0: `RD(16'd4, 3'd2, S_HDR1)
    S_HDR1: begin ntypes <= val[15:0]; `RD(16'd8, 3'd2, S_HDR2) end
    S_HDR2: begin type_off <= val[15:0]; t <= 8'd0; g <= 10'd0; nm <= 11'd0; st <= S_T0; end
    S_T0: if ({8'd0, t} == ntypes) st <= S_END;
          else `RD(type_off + 16'd12 * t + 16'd4, 3'd2, S_T1)
    S_T1: begin btab <= val[15:0]; `RD(type_off + 16'd12 * t + 16'd8, 3'd2, S_T2) end
    S_T2: begin nb <= val[15:0]; b <= 12'd0; st <= S_B0; end
    S_B0: if ({4'd0, b} == nb) begin t <= t + 1'b1; st <= S_T0; end
          else `RD(btab + 16'd12 * b + 16'd4, 3'd2, S_B1)
    S_B1: begin lst <= val[15:0]; `RD(btab + 16'd12 * b + 16'd8, 3'd2, S_B2) end
    S_B2: begin ns <= val[15:0]; s <= 12'd0; st <= S_E0; end
    // entry (t, b, s): its previous bit, then its codes
    S_E0: if ({4'd0, s} == ns) begin b <= b + 1'b1; st <= S_B0; end
          else begin bm_ra <= {sel, g}; matched <= 1'b0; st <= S_BMR; end
    S_BMR: st <= S_E1;                                        // bitmap read latency
    S_E1: if ((nar || rebuild) && !bm_q) st <= S_ENT;         // not in the previous list
          else if (rebuild) begin matched <= 1'b1; st <= S_ENT; end
          else `RD(lst + {1'b0, s, 3'd0}, 3'd2, S_E2)
    S_E2: begin cs <= val[15:0]; `RD(val[15:0], 3'd1, S_E3) end
    S_E3: begin dp <= val[5:0]; `RD(cs + 16'd2, 3'd2, S_E4) end
    S_E4: begin mask <= val[15:0]; `RD(cs + 16'd4, 3'd4, S_E5) end
    S_E5: begin dd <= val; ptr <= cs + 16'd8; fn <= 4'd0; st <= S_F0; end
    // functions
    S_F0: if (fn == 4'd12 || matched) st <= S_ENT;
          else if (!mask[fn]) fn <= fn + 1'b1;
          else `RD(ptr, 3'd2, S_F1)
    S_F1: begin cf <= val; `RD(ptr + 16'd3, 3'd1, S_F2) end
    S_F2: if (val[0]) `RD(ptr + 16'd4, 3'd1, S_F3)           // override record
          else begin cp <= dp; cd <= dd; ptr <= ptr + 16'd4; sy_t <= 1'b0; st <= S_TEST0; end
    S_F3: begin cp <= val[5:0]; `RD(ptr + 16'd8, 3'd4, S_F4) end
    S_F4: begin cd <= val; `RD(ptr + 16'd12, 3'd4, S_F5) end
    S_F5: begin cf <= val; ptr <= ptr + 16'd16; sy_t <= 1'b0; st <= S_TEST0; end
    // test code {cp, cd, cf} with toggle sy_t
    S_TEST0: begin
        sy_p <= cp; sy_d <= cd; sy_f <= cf; sy_start <= 1'b1;
        tt <= 24'd0; prev <= 1'b0; any <= 1'b0; nref <= 7'd0;
        st <= S_TEST1;
    end
    S_TEST1: if (sy_done) begin c <= 0; st <= S_C0; end
    S_C0: if (c == ncand || cand[c[4:0]] + nref > n_iv) begin
              if (sy_kind != 4'd0 && !sy_t) begin sy_t <= 1'b1; st <= S_TEST0; end   // biphase: toggle 1
              else begin fn <= fn + 1'b1; st <= S_F0; end                              // no match
          end else begin sc <= cand[c[4:0]]; k <= 0; st <= S_C1; end
    S_C1: if (k == nref) begin                                                       // whole frame fits
              if (sc + nref == n_iv) begin matched <= 1'b1; st <= S_F0; end             // ends the capture
              else begin iv_addr <= sc + nref; endchk <= 1'b1; st <= S_C2; end          // gap after it?
          end else begin iv_addr <= sc + k; endchk <= 1'b0; st <= S_C2; end
    S_C2: st <= S_C3;                                                                   // interval read latency
    S_C3: if (endchk) begin
              if (iv_q >= FRAME_GAP) begin matched <= 1'b1; st <= S_F0; end
              else begin c <= c + 1'b1; st <= S_C0; end
          end else if (diff <= tolk) begin k <= k + 1'b1; st <= S_C1; end
          else begin c <= c + 1'b1; st <= S_C0; end
    S_ENT: begin
        if (!rebuild) begin bm_we <= 1'b1; bm_wa <= {~sel, g}; bm_wd <= matched; end
        if (matched) begin list_we <= 1'b1; list_wa <= nm[9:0]; list_wd <= {t, b, s}; nm <= nm + 1'b1; end
        g <= g + 1'b1; s <= s + 1'b1; st <= S_E0;
    end
    S_END: begin
        if (rebuild) begin
            result <= readable ? 2'd3 : 2'd2; n_match <= {5'd0, nm}; done <= 1'b1; st <= S_IDLE;
        end else if (nm != 0) begin
            sel <= ~sel; result <= 2'd0; n_match <= {5'd0, nm}; done <= 1'b1; st <= S_IDLE;
        end else if (nar) begin
            rebuild <= 1'b1; t <= 8'd0; g <= 10'd0; nm <= 11'd0; st <= S_T0;          // keep the old list
        end else begin
            result <= readable ? 2'd1 : 2'd2; n_match <= 16'd0; done <= 1'b1; st <= S_IDLE;
        end
    end
    default: st <= S_IDLE;
    endcase
end

`undef RD

endmodule
