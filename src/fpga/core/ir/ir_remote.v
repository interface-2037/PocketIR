// ir_remote.v
// M4: Pocket buttons -> Sony SIRC codes -> IR LED.
// The lowest-numbered pressed button with a code is sent. A tap sends 3
// frames; holding repeats. If a different button is pressed while a code is
// still going out, the old code finishes its minimum frames, then the new
// button starts -- a held button never repeats another button's code.
// Carrier: 40 kHz, 50% duty (best range on hardware, M3 test: 10.5 in).

module ir_remote #(
    parameter CLK_HZ   = 74_250_000,
    parameter DUTY_PCT = 50
) (
    input  wire        clk,
    input  wire [15:0] keys,          // cont1_key[15:0]
    output reg         ir_tx = 1'b0,
    output wire        envelope,
    output wire        busy,
    output reg  [3:0]  active_idx = 4'd0
);

// Two register stages on the buttons (cont1_key is already in clk's domain;
// this just keeps the logic tidy and registered).
reg [15:0] keys_r1 = 16'd0, keys_r2 = 16'd0;
always @(posedge clk) begin
    keys_r1 <= keys;
    keys_r2 <= keys_r1;
end

// Priority encoder over buttons that have a code: lowest bit number wins.
// Function + continuous assign so simulation also evaluates it at time zero.
function [4:0] pick(input [15:0] k);     // {any, idx[3:0]}
    integer i;
begin
    pick = 5'd0;
    for (i = 15; i >= 0; i = i - 1)
        if (k[i] && (i <= 9 || i == 14 || i == 15))
            pick = {1'b1, i[3:0]};
end
endfunction

wire       sel_any;
wire [3:0] sel_idx;
assign {sel_any, sel_idx} = pick(keys_r2);

wire        rom_valid;
wire [4:0]  rom_nbits;
wire [12:0] rom_address;
wire [6:0]  rom_command;
ir_code_rom rom (
    .idx(busy ? active_idx : sel_idx), .valid(rom_valid),
    .nbits(rom_nbits), .address(rom_address), .command(rom_command));

always @(posedge clk)
    if (!busy) active_idx <= sel_idx;

// Key to the encoder: only "held" while the same button is still the one
// selected, so repeats stop when the user switches buttons.
wire enc_key = sel_any && rom_valid && (!busy || sel_idx == active_idx);

ir_sirc_tx #(.CLK_HZ(CLK_HZ)) sirc (
    .clk(clk), .key(enc_key),
    .nbits(rom_nbits), .address(rom_address), .command(rom_command),
    .envelope(envelope), .busy(busy));

wire carrier;
ir_carrier #(.CLK_HZ(CLK_HZ), .CARRIER_HZ(40_000), .DUTY_PCT(DUTY_PCT)) car (
    .clk(clk), .en(envelope), .out(carrier));

always @(posedge clk) ir_tx <= carrier;

endmodule
