// ir_rx_cap.v
// M9 step 1: raw IR receiver capture, read out through the save file.
//
// Records every edge of port_ir_rx (2-flop synchronised, no filtering) at
// clock resolution, so the PC can work out the receiver's polarity, whether
// it is raw (carrier pulses) or demodulated, and how it distorts timing
// (docs/m9-plan.md). tools/ir/read_save.py decodes the result.
//
// Burst: starts at the first edge, ends after GAP_MS without an edge, after
// MAX_MS (continuous noise), or when the core stops running. A burst goes into
// the buffer that isn't the active one; if it has >= MIN_EDGES edges it
// becomes the active buffer, so noise can't overwrite the last good capture.
//
// Entry: {level after the edge, clocks since the previous edge (saturating;
// the first entry holds the idle time before the burst)}. Edges beyond the
// buffer are only counted.
//
// Bridge region at ADDR (big-endian words, as in the save file):
//   +0x00  H0  MAGIC "IRC1" (written at the first burst)
//   +0x04  H1  {active buffer, 3'd0, DEPTH_LOG2[3:0], 8'd0, kept[7:0], rejected[7:0]}
//              (kept / rejected bursts count from the last start of the core)
//   +0x08  H2..H4  buffer 0: info, total edges, burst length (clocks, first to last edge)
//   +0x14  H5..H7  buffer 1: same
//          info = {kept, idle level before the burst, TX busy during it, buffer full,
//                  ended by MAX_MS, 11'd0, entries[15:0]}  (0 = empty / being written)
//   +0x20  buffer 0: 2^DEPTH_LOG2 entries, then buffer 1
// APF writes the region from the file while the core is in reset and reads it
// back on Quit, so the last capture survives a restart of the core. Reads are
// latched on the bridge_rd strobe (see lib/dev_save.v).

module ir_rx_cap #(
    parameter [31:0] ADDR       = 32'h1000_0020,
    parameter        CLK_HZ     = 74_250_000,
    parameter        DEPTH_LOG2 = 12,          // entries per buffer = 2^DEPTH_LOG2
    parameter        GAP_MS     = 200,
    parameter        MAX_MS     = 3000,
    parameter        MIN_EDGES  = 20
) (
    input  wire        clk,                    // clk_74a (bridge domain)
    input  wire        run,                    // capture only while the core runs (reset_n)
    input  wire        rx,                     // port_ir_rx (asynchronous)
    input  wire        tx_busy,                // our own IR transmitter is sending
    output reg         active = 1'b0,          // a burst is being recorded
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_rd,
    output reg  [31:0] rd_data = 32'd0,
    output reg         rd_hit = 1'b0           // the last bridge read was in this region
);

localparam [31:0] MAGIC    = 32'h49524331;     // "IRC1"
localparam        DEPTH    = 1 << DEPTH_LOG2;
localparam        AW       = DEPTH_LOG2 + 1;   // both buffers
localparam [31:0] GAP_CLKS = CLK_HZ / 1000 * GAP_MS;
localparam [31:0] MAX_CLKS = CLK_HZ / 1000 * MAX_MS;
localparam [30:0] SAT      = 31'h7FFF_FFFF;

// ------------------------------------------------------------------ bridge decode
wire [31:0] off     = bridge_addr - ADDR;
wire        hdr_hit = (off < 32'd32);
wire        ram_hit = (off >= 32'd32) && (off < 32'd32 + 8 * DEPTH);
wire [31:0] roff    = off - 32'd32;
wire [AW-1:0] ram_idx = roff[AW+1:2];

// ------------------------------------------------------------------ capture RAM
// One write port (bridge while loading, capture while running; never both),
// one read port (bridge).
reg [31:0]   ram [0:2*DEPTH-1];
reg          cap_we = 1'b0;
reg [AW-1:0] cap_waddr = 0;
reg [31:0]   cap_wdata = 32'd0;
wire         br_we  = bridge_wr && ram_hit;
wire         we     = br_we || cap_we;
wire [AW-1:0] waddr = br_we ? ram_idx : cap_waddr;
wire [31:0]  wdata  = br_we ? bridge_wr_data : cap_wdata;
reg [AW-1:0] raddr = 0;
reg [31:0]   q = 32'd0;
always @(posedge clk) begin
    if (we) ram[waddr] <= wdata;
    q <= ram[raddr];
end

// ------------------------------------------------------------------ header
reg [31:0] h_magic = 32'd0;
reg        h_act = 1'b0;
reg [7:0]  n_kept = 8'd0, n_rej = 8'd0;
reg [31:0] info [0:1], total [0:1], dur [0:1];
initial begin info[0] = 0; info[1] = 0; total[0] = 0; total[1] = 0; dur[0] = 0; dur[1] = 0; end

function [31:0] hdr_word(input [2:0] i);
    case (i)
        3'd0: hdr_word = h_magic;
        3'd1: hdr_word = {h_act, 3'd0, DEPTH_LOG2[3:0], 8'd0, n_kept, n_rej};
        3'd2: hdr_word = info[0];
        3'd3: hdr_word = total[0];
        3'd4: hdr_word = dur[0];
        3'd5: hdr_word = info[1];
        3'd6: hdr_word = total[1];
        default: hdr_word = dur[1];
    endcase
endfunction

// ------------------------------------------------------------------ bridge reads
reg       rd_p1 = 1'b0, rd_p2 = 1'b0, rd_is_hdr = 1'b0;
reg [2:0] rd_hw = 3'd0;
always @(posedge clk) begin
    rd_p1 <= bridge_rd;
    rd_p2 <= rd_p1;
    if (bridge_rd) begin
        raddr     <= ram_idx;
        rd_hit    <= hdr_hit || ram_hit;
        rd_is_hdr <= hdr_hit;
        rd_hw     <= off[4:2];
    end
    if (rd_p2) rd_data <= rd_is_hdr ? hdr_word(rd_hw) : q;   // q is ram[raddr] by now
end

// ------------------------------------------------------------------ capture
reg        rx1 = 1'b0, rx2 = 1'b0, rx3 = 1'b0;
reg        run_r = 1'b0;
reg [30:0] since = SAT;                  // clocks since the last edge
reg [31:0] t_burst = 32'd0, t_last = 32'd0;
reg        wbuf = 1'b0;                  // buffer being written
reg [15:0] n = 16'd0;
reg [31:0] tot = 32'd0;
reg        lvl0 = 1'b0, txs = 1'b0, maxed = 1'b0;

wire edge_now = (rx2 != rx3);
wire full     = (n == DEPTH);
wire end_now  = active && (!run || (!edge_now && since >= GAP_CLKS[30:0]) || t_burst >= MAX_CLKS);
wire keep     = (tot >= MIN_EDGES);

always @(posedge clk) begin
    rx1 <= rx; rx2 <= rx1; rx3 <= rx2;
    run_r <= run;
    cap_we <= 1'b0;
    since <= edge_now ? 31'd1 : (since == SAT ? SAT : since + 1'b1);

    if (run && !run_r) begin n_kept <= 8'd0; n_rej <= 8'd0; end

    if (end_now) begin
        active <= 1'b0;
        info[wbuf]  <= {keep, lvl0, txs, full, t_burst >= MAX_CLKS, 11'd0, n};
        total[wbuf] <= tot;
        dur[wbuf]   <= t_last;
        if (keep) begin
            h_act <= wbuf;
            if (n_kept != 8'hFF) n_kept <= n_kept + 1'b1;
        end else if (n_rej != 8'hFF) n_rej <= n_rej + 1'b1;
    end else if (active) begin
        t_burst <= t_burst + 1'b1;
        if (tx_busy) txs <= 1'b1;
        if (edge_now) begin
            tot    <= tot + 1'b1;
            t_last <= t_burst + 1'b1;
            if (!full) begin
                cap_we <= 1'b1; cap_waddr <= {wbuf, n[DEPTH_LOG2-1:0]}; cap_wdata <= {rx2, since};
                n <= n + 1'b1;
            end
        end
    end else if (run && edge_now) begin
        // first edge: the burst goes into the inactive buffer
        active  <= 1'b1;
        wbuf    <= ~h_act;
        cap_we  <= 1'b1; cap_waddr <= {~h_act, {DEPTH_LOG2{1'b0}}}; cap_wdata <= {rx2, since};
        n       <= 16'd1;
        tot     <= 32'd1;
        t_burst <= 32'd0;
        t_last  <= 32'd0;
        lvl0    <= rx3;
        txs     <= tx_busy;
        info[~h_act] <= 32'd0;                   // being overwritten
        if (h_magic != MAGIC) begin              // first capture in this file
            h_magic <= MAGIC;
            info[h_act] <= 32'd0;
            total[0] <= 0; total[1] <= 0; dur[0] <= 0; dur[1] <= 0;
        end
    end

    // APF loads the header from the save file (only while the core is in reset)
    if (bridge_wr && hdr_hit) case (off[4:2])
        3'd0: h_magic  <= bridge_wr_data;
        3'd1: h_act    <= bridge_wr_data[31];
        3'd2: info[0]  <= bridge_wr_data;
        3'd3: total[0] <= bridge_wr_data;
        3'd4: dur[0]   <= bridge_wr_data;
        3'd5: info[1]  <= bridge_wr_data;
        3'd6: total[1] <= bridge_wr_data;
        default: dur[1] <= bridge_wr_data;
    endcase
end

endmodule
