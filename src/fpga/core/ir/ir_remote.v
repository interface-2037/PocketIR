// ir_remote.v
// Pocket buttons -> codes from ir_code_rom -> ir_engine (M6) -> IR LED.
// The lowest-numbered pressed button with a code is sent. A tap sends 3
// frames; holding repeats. If a different button is pressed while a code is
// still going out, the old code finishes its minimum frames, then the new
// button starts -- a held button never repeats another button's code.
// Carrier frequency and duty come from the protocol (SIRC: 40 kHz, 50%: best
// range on hardware in the M3 test, 10.5 in).

module ir_remote #(
    parameter PROG_FILE = "core/ir/ir_proto.hex"     // protocol microcode (ircompile.py)
) (
    input  wire        clk,
    input  wire [15:0] keys,          // cont1_key[15:0]
    output wire        ir_tx,
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
wire [5:0]  rom_proto;
wire [12:0] rom_address;
wire [6:0]  rom_command;
ir_code_rom rom (
    .idx(busy ? active_idx : sel_idx), .valid(rom_valid),
    .proto(rom_proto), .address(rom_address), .command(rom_command));

always @(posedge clk)
    if (!busy) active_idx <= sel_idx;

// Key to the encoder: only "held" while the same button is still the one
// selected, so repeats stop when the user switches buttons.
wire enc_key = sel_any && rom_valid && (!busy || sel_idx == active_idx);

ir_engine #(.PROG_FILE(PROG_FILE)) engine (
    .clk(clk), .key(enc_key), .proto(rom_proto),
    .address({19'd0, rom_address}), .command({25'd0, rom_command}),
    .envelope(envelope), .ir_tx(ir_tx), .busy(busy), .underrun());

endmodule
