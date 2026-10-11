// recent.v
// M9: the last N devices used, most recent first, kept in the save file.
// Whenever the current device (menu.v) differs from the front entry, it moves
// to the front: removed from where it was, or inserted with the oldest entry
// dropped when the list is full. That covers every way of changing device
// (menu, learn, recent list) and the device loaded at start.
//
// Save region at ADDR (big-endian words, after the receiver capture):
//   +0x00 MAGIC "IRL1"   +0x04 LIB_ID   +0x08 count   +0x0C 0
//   +0x10 entries 0..N-1: {type[7:0], brand[11:0], set[11:0]}
// APF loads the region while the core is in reset. At `boot` (dev_save.v) the
// list is kept if magic, library id and count are valid, else cleared (a list
// from another library build would name other devices). Reads are latched on
// bridge_rd and always return the live list (before the first boot, that is
// the loaded file, unchanged).

module recent #(
    parameter [31:0] ADDR   = 32'h1000_8040,
    parameter [31:0] LIB_ID = 32'd0,
    parameter        N      = 20
) (
    input  wire        clk,
    input  wire        boot,              // pulse (dev_save.v): validate, then track the device
    input  wire [7:0]  cur_t,             // current device (menu.v)
    input  wire [15:0] cur_b,
    input  wire [15:0] cur_s,
    output reg  [4:0]  count = 5'd0,
    input  wire [4:0]  idx,               // menu: entry idx ...
    output wire [31:0] entry,             // ... {type, brand, set} (combinational)
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_rd,
    output reg  [31:0] rd_data = 32'd0,
    output reg         rd_hit = 1'b0
);

localparam [31:0] MAGIC = 32'h49524C31;     // "IRL1"

reg [31:0] e [0:N-1];
reg [31:0] h_magic = 32'd0, h_lib = 32'd0;
reg [2:0]  settle = 3'd0;                   // cycles after boot before tracking starts
reg        tracking = 1'b0;
integer ji, jp, js;
initial for (ji = 0; ji < N; ji = ji + 1) e[ji] = 32'd0;

assign entry = (idx < N) ? e[idx] : 32'd0;

wire [31:0] off  = bridge_addr - ADDR;
wire        hit  = (off < 32'h10 + 4 * N);
wire [31:0] widx = (off - 32'h10) >> 2;

// the current device as an entry, and where it is in the list (N = absent)
wire [31:0] cur = {cur_t, cur_b[11:0], cur_s[11:0]};
reg  [4:0]  pos;
always @(*) begin
    pos = N;
    for (jp = N - 1; jp >= 0; jp = jp - 1)
        if (jp < count && e[jp] == cur) pos = jp;
end
wire push = tracking && (count == 0 || e[0] != cur);

always @(posedge clk) begin
    if (bridge_rd) begin
        rd_hit <= hit;
        rd_data <= (off == 0) ? h_magic : (off == 4) ? h_lib : (off == 8) ? {27'd0, count} :
                   (off < 32'h10) ? 32'd0 : e[widx[4:0]];
    end
    if (bridge_wr && hit) begin                     // APF loads the file (core in reset)
        if (off == 0) h_magic <= bridge_wr_data;
        else if (off == 4) h_lib <= bridge_wr_data;
        else if (off == 8) count <= (bridge_wr_data > N) ? 5'd31 : bridge_wr_data[4:0];   // 31: invalid
        else if (off >= 32'h10) e[widx[4:0]] <= bridge_wr_data;
    end

    if (boot) begin
        tracking <= 1'b0; settle <= 3'd4;
        if (h_magic != MAGIC || h_lib != LIB_ID || count > N) begin
            h_magic <= MAGIC; h_lib <= LIB_ID; count <= 5'd0;
        end
    end else if (settle != 3'd0) begin
        settle <= settle - 1'b1;
        if (settle == 3'd1) tracking <= 1'b1;
    end else if (push) begin
        // move to the front: entries before the old position (or all) shift down one
        for (js = N - 1; js > 0; js = js - 1)
            if (js <= pos) e[js] <= e[js - 1];
        e[0] <= cur;
        if (pos == N && count != N) count <= count + 1'b1;
    end
end

endmodule
