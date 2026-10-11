// dev_save.v
// Remembers the current device across sessions (M7 step 6) through an APF
// nonvolatile data slot (data.json: slot 0, "irremote.sav", 16 bytes at
// ADDR). APF writes the save file into the core over the bridge before
// releasing reset_n, and reads it back over the bridge when the core shuts
// down (quit, power off).
//
// Save file, four big-endian 32-bit words (bridge_endian_little = 0):
//   0  MAGIC "IRS1"
//   1  LIB_ID      CRC-32 of the library image (ir_lib.vh)
//   2  {8'd0, type[7:0], brand[15:0]}
//   3  {16'd0, code set[15:0]}
// When reset_n first rises, `boot` pulses with the saved device if magic and
// library id match, else with BOOT_* (no file, a 0xFF-filled new file, or a
// save from another library build whose indices would mean other devices).
// Reads (latched on the bridge_rd strobe: hardware v0.9.0 showed APF has
// already moved to the next address when it samples the data; following the
// address saved every word one place early) always return the live current device, so whatever is current when
// the core shuts down is what gets saved.

module dev_save #(
    parameter [31:0] ADDR   = 32'h1000_0000,
    parameter [31:0] LIB_ID = 32'd0,
    parameter [7:0]  BOOT_T = 8'd0,
    parameter [15:0] BOOT_B = 16'd0,
    parameter [15:0] BOOT_S = 16'd0
) (
    input  wire        clk,                 // clk_74a (bridge domain)
    input  wire        reset_n,             // core_bridge_cmd: high once data slots are loaded
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_rd,
    output reg  [31:0] rd_data = 32'd0,     // latched on bridge_rd (APF moves the address on before sampling)
    input  wire [7:0]  cur_t,               // current device (menu.v)
    input  wire [15:0] cur_b,
    input  wire [15:0] cur_s,
    output reg         boot = 1'b0,         // one-cycle pulse with the boot device
    output reg  [7:0]  boot_t = BOOT_T,
    output reg  [15:0] boot_b = BOOT_B,
    output reg  [15:0] boot_s = BOOT_S,
    // dataslot size table: write back 16 bytes on shutdown
    output reg  [9:0]  datatable_addr = 10'd0,
    output reg         datatable_wren = 1'b0,
    output reg  [31:0] datatable_data = 32'd0
);

localparam [31:0] MAGIC = 32'h49525331;      // "IRS1"
localparam [31:0] SIZE  = 32'd16;

wire       hit = (bridge_addr[31:4] == ADDR[31:4]);
reg [31:0] w0 = 32'd0, w1 = 32'd0, w2 = 32'd0, w3 = 32'd0;
reg        done = 1'b0, rst_r = 1'b0;

always @(posedge clk) begin
    if (bridge_wr && hit)
        case (bridge_addr[3:2])
            2'd0: w0 <= bridge_wr_data;
            2'd1: w1 <= bridge_wr_data;
            2'd2: w2 <= bridge_wr_data;
            2'd3: w3 <= bridge_wr_data;
        endcase

    if (bridge_rd)
    case (bridge_addr[3:2])
        2'd0: rd_data <= MAGIC;
        2'd1: rd_data <= LIB_ID;
        2'd2: rd_data <= {8'd0, cur_t, cur_b};
        2'd3: rd_data <= {16'd0, cur_s};
    endcase

    rst_r <= reset_n;
    boot <= 1'b0;
    datatable_wren <= 1'b0;
    if (reset_n && !rst_r && !done) begin
        done <= 1'b1;
        boot <= 1'b1;
        if (w0 == MAGIC && w1 == LIB_ID) begin
            boot_t <= w2[23:16]; boot_b <= w2[15:0]; boot_s <= w3[15:0];
        end
        // slot 0's size entry (id at 0, size at 1): save 16 bytes even if no file was loaded
        datatable_addr <= 10'd1; datatable_data <= SIZE; datatable_wren <= 1'b1;
    end
end

endmodule
