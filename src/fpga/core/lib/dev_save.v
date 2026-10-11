// dev_save.v
// Remembers the current device across sessions (M7 step 6) through an APF
// nonvolatile data slot (data.json: slot 0, "irremote.sav" at ADDR). APF
// writes the save file into the core over the bridge while the core is in
// reset, and reads it back over the bridge when the core shuts down (quit,
// power off).
//
// Save file, big-endian 32-bit words (bridge_endian_little = 0):
//   0  MAGIC "IRS1"
//   1  LIB_ID      CRC-32 of the library image (ir_lib.vh)
//   2  {8'd0, type[7:0], brand[15:0]}
//   3  {16'd0, code set[15:0]}
//   4..7 diagnostics: the start-up sequence as the core saw it (see the read mux)
// (M9: the file continues with the receiver capture, ir/ir_rx_cap.v; SIZE
// covers both, so APF reads the whole file back.)
//
// Boot: on every reset_n rise (APF "reset exit"), and on a
// dataslot_allcomplete that arrives while already running, `boot` pulses with
//   - the saved device, if the slot was written since the last boot and its
//     magic and library id match (a save from another library build would
//     name other devices);
//   - else the current device after the first boot (a reset without a fresh
//     load keeps it), or BOOT_* before it (no file, a 0xFF-filled new file).
// Reads are latched on the bridge_rd strobe (hardware v0.9.0: APF has already
// moved to the next address when it samples the data). Before the first boot
// they return the words as loaded, so a session that never started cannot
// overwrite the save; after it, the live current device.

module dev_save #(
    parameter [31:0] ADDR   = 32'h1000_0000,
    parameter [31:0] LIB_ID = 32'd0,
    parameter [7:0]  BOOT_T = 8'd0,
    parameter [15:0] BOOT_B = 16'd0,
    parameter [15:0] BOOT_S = 16'd0,
    parameter [31:0] SIZE   = 32'd32        // whole save file (M9: + ir_rx_cap region)
) (
    input  wire        clk,                 // clk_74a (bridge domain)
    input  wire        reset_n,             // core_bridge_cmd: reset exit / enter
    input  wire        allcomplete,         // core_bridge_cmd: data slot access all complete
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_rd,
    output reg  [31:0] rd_data = 32'd0,
    input  wire [7:0]  cur_t,               // current device (menu.v)
    input  wire [15:0] cur_b,
    input  wire [15:0] cur_s,
    output reg         boot = 1'b0,         // one-cycle pulse with the boot device
    output reg  [7:0]  boot_t = BOOT_T,
    output reg  [15:0] boot_b = BOOT_B,
    output reg  [15:0] boot_s = BOOT_S,
    // dataslot size table: write back SIZE bytes on shutdown
    output reg  [9:0]  datatable_addr = 10'd0,
    output reg         datatable_wren = 1'b0,
    output reg  [31:0] datatable_data = 32'd0
);

localparam [31:0] MAGIC = 32'h49525331;      // "IRS1"

wire       hit = (bridge_addr[31:5] == ADDR[31:5]);
reg [31:0] w0 = 32'd0, w1 = 32'd0, w2 = 32'd0, w3 = 32'd0;
reg        booted = 1'b0, fresh = 1'b0, rst_r = 1'b0, ac_r = 1'b0, ac_boot = 1'b0;
wire       valid = (w0 == MAGIC && w1 == LIB_ID);

// diagnostics
reg [7:0]  n_rise = 0, n_fall = 0, n_ac = 0, n_boot = 0;
reg [15:0] n_wr = 0, n_wr_run = 0, n_rd = 0;
reg [31:0] w2_at_boot = 32'hFFFFFFFF;
reg        valid_at_boot = 1'b0, fresh_at_boot = 1'b0;

wire rise  = reset_n && !rst_r;
wire ac_go = allcomplete && !ac_r && reset_n && !ac_boot;   // slots finished while already running
wire go    = rise || ac_go;

always @(posedge clk) begin
    rst_r <= reset_n;
    ac_r  <= allcomplete;
    if (rise)                 n_rise <= n_rise + 1'b1;
    if (!reset_n && rst_r)    n_fall <= n_fall + 1'b1;
    if (allcomplete && !ac_r) n_ac   <= n_ac + 1'b1;

    if (bridge_wr && hit) begin
        n_wr <= n_wr + 1'b1;
        if (reset_n) n_wr_run <= n_wr_run + 1'b1;
        fresh <= 1'b1;
        case (bridge_addr[4:2])
            3'd0: w0 <= bridge_wr_data;
            3'd1: w1 <= bridge_wr_data;
            3'd2: w2 <= bridge_wr_data;
            3'd3: w3 <= bridge_wr_data;
            default: ;
        endcase
    end

    if (bridge_rd) begin
        if (hit) n_rd <= n_rd + 1'b1;
        case (bridge_addr[4:2])
            3'd0: rd_data <= booted ? MAGIC : w0;
            3'd1: rd_data <= booted ? LIB_ID : w1;
            3'd2: rd_data <= booted ? {8'd0, cur_t, cur_b} : w2;
            3'd3: rd_data <= booted ? {16'd0, cur_s} : w3;
            3'd4: rd_data <= {n_rise, n_fall, n_ac, n_boot};          // reset exits, enters, all-completes, boots
            3'd5: rd_data <= {n_wr, n_wr_run};                        // slot writes: all, while running
            3'd6: rd_data <= w2_at_boot;                              // word 2 as loaded, at the last boot
            3'd7: rd_data <= {n_rd, 13'd0, valid_at_boot, fresh_at_boot, booted};
        endcase
    end

    boot <= 1'b0;
    datatable_wren <= 1'b0;
    if (go) begin
        boot <= 1'b1;
        booted <= 1'b1;
        fresh <= 1'b0;
        n_boot <= n_boot + 1'b1;
        if (ac_go) ac_boot <= 1'b1;
        w2_at_boot <= w2; valid_at_boot <= valid; fresh_at_boot <= fresh;
        if (fresh && valid) begin
            boot_t <= w2[23:16]; boot_b <= w2[15:0]; boot_s <= w3[15:0];
        end else if (booted) begin
            boot_t <= cur_t; boot_b <= cur_b; boot_s <= cur_s;
        end
        // slot 0's size entry (id at 0, size at 1)
        datatable_addr <= 10'd1; datatable_data <= SIZE; datatable_wren <= 1'b1;
    end
    if (!reset_n) ac_boot <= 1'b0;
end

endmodule
