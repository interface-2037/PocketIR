// sleep_state.v
// Sleep / wake through APF save states (host commands 0xA0 Savestate
// Start/Query and 0xA4 Savestate Load/Query; core.json "sleep_supported").
//
// The save state is a window of ADDR..ADDR+SIZE-1 on the bridge, aliased onto
// the save file's device block and recent list, so it needs no storage of its
// own. `sv_addr` is the bridge address with the window translated; dev_save.v
// and recent.v decode it instead of bridge_addr:
//   ADDR + 0x00..0x1F -> DEV_ADDR + 0x00..   (dev_save: 8 words)
//   ADDR + 0x20..     -> REC_ADDR + 0x00..   (recent: header + entries)
// The receiver capture (ir_rx_cap.v) keeps the raw address, so it is left out.
// Handshake:
//   - Sleep: APF raises `savestate_start`; we ack, report busy for one cycle,
//     then ok. APF then reads SIZE bytes from ADDR (the live registers).
//   - Wake: APF writes the blob to ADDR first (agg23 openfpga-NES
//     save_state_controller.sv: "data is already copied"), then raises
//     `savestate_load`; we ack, pulse `restore` (dev_save boots the blob's
//     device, recent.v re-validates the list), report busy, then ok.
// core_bridge_cmd holds the request high until it sees the ack, so we act on
// the rising edge. ok stays up until the next request (bridge-cmd comments).

module sleep_state #(
    parameter [31:0] ADDR     = 32'h2000_0000,  // aligned to SIZE
    parameter [31:0] SIZE     = 32'h80,         // power of two: 0x20 + recent region
    parameter [31:0] DEV_ADDR = 32'h1000_0000,  // dev_save block (0x20 aligned)
    parameter [31:0] REC_ADDR = 32'h1000_8040   // recent region
) (
    input  wire        clk,                 // clk_74a (bridge domain)
    input  wire [31:0] bridge_addr,
    output wire [31:0] sv_addr,             // bridge_addr with the window aliased
    output wire        supported,
    output wire [31:0] addr,
    output wire [31:0] size,
    output wire [31:0] maxloadsize,
    input  wire        start,               // core_bridge_cmd savestate_start
    output reg         start_ack  = 1'b0,
    output reg         start_busy = 1'b0,
    output reg         start_ok   = 1'b0,
    output wire        start_err,
    input  wire        load,                // core_bridge_cmd savestate_load
    output reg         load_ack   = 1'b0,
    output reg         load_busy  = 1'b0,
    output reg         load_ok    = 1'b0,
    output wire        load_err,
    output reg         saved      = 1'b0,   // pulse: a save state was handed out (diagnostics)
    output reg         restore    = 1'b0    // pulse: the blob at ADDR is loaded, boot from it
);

wire        in_win = ((bridge_addr & ~(SIZE - 1)) == ADDR);
wire [31:0] off    = bridge_addr & (SIZE - 1);
assign sv_addr = !in_win      ? bridge_addr
               : (off < 32'h20) ? (DEV_ADDR | off)
               :                  (REC_ADDR + (off - 32'h20));

assign supported   = 1'b1;
assign addr        = ADDR;
assign size        = SIZE;
assign maxloadsize = SIZE;
assign start_err   = 1'b0;
assign load_err    = 1'b0;

reg start_r = 1'b0, load_r = 1'b0;

always @(posedge clk) begin
    start_r <= start;
    load_r  <= load;
    start_ack <= 1'b0; load_ack <= 1'b0;
    saved <= 1'b0; restore <= 1'b0;

    // busy lasts one cycle after the ack
    if (start_busy) begin start_busy <= 1'b0; start_ok <= 1'b1; end
    if (load_busy)  begin load_busy  <= 1'b0; load_ok  <= 1'b1; end

    if (start && !start_r) begin
        start_ack <= 1'b1; start_busy <= 1'b1; saved <= 1'b1;
        start_ok <= 1'b0; load_ok <= 1'b0;
    end
    if (load && !load_r) begin
        load_ack <= 1'b1; load_busy <= 1'b1; restore <= 1'b1;
        start_ok <= 1'b0; load_ok <= 1'b0;
    end
end

endmodule
