// ir_code_rom.v
// Hard-coded button -> IR code table (M4): Sony STR-DH790 AV receiver.
// idx is the cont1_key bit number. valid = 0 for buttons with no code.
//
// Grip: the Pocket is held rotated 180 deg (screen toward the user, upside
// down, bottom edge pointing at the receiver), so d-pad, face buttons and
// shoulders are mapped by *position in that grip*; Start/Select by label.
// Names follow the DH790 remote (AMP MENU, BACK).
//
// Sources (cross-checked against each other):
//   IRDB codes/Sony/Receiver/48,-1.csv  - power 21, vol 18/19, mute 20
//   idcrook/homespun_lirc_codes RM-AAU190 (STR-DH550/750 remote) - menu keys
// SIRC address field: 15-bit = 8-bit device; 20-bit = 5-bit device | ext << 5.

module ir_code_rom (
    input  wire [3:0]  idx,
    output wire        valid,
    output wire [4:0]  nbits,
    output wire [12:0] address,
    output wire [6:0]  command
);

// Function + continuous assign (rather than always @*) so simulation also
// evaluates the table at time zero.
assign {valid, nbits, address, command} = lookup(idx);

function [25:0] lookup(input [3:0] idx);
    reg        valid;
    reg [4:0]  nbits;
    reg [12:0] address;
    reg [6:0]  command;
begin
    valid = 1'b1;
    case (idx)
        4'd15: begin nbits = 5'd15; address = 13'd48;  command = 7'd21;  end  // Start : power
        4'd14: begin nbits = 5'd15; address = 13'd48;  command = 7'd20;  end  // Select: mute
        4'd8:  begin nbits = 5'd15; address = 13'd48;  command = 7'd18;  end  // L1 (right in grip): volume +
        4'd9:  begin nbits = 5'd15; address = 13'd48;  command = 7'd19;  end  // R1 (left in grip) : volume -
        4'd1:  begin nbits = 5'd15; address = 13'd176; command = 7'd120; end  // Down  (top)   : menu up
        4'd0:  begin nbits = 5'd15; address = 13'd176; command = 7'd121; end  // Up    (bottom): menu down
        4'd3:  begin nbits = 5'd15; address = 13'd176; command = 7'd122; end  // Right (left)  : menu left
        4'd2:  begin nbits = 5'd15; address = 13'd176; command = 7'd123; end  // Left  (right) : menu right
        4'd7:  begin nbits = 5'd15; address = 13'd48;  command = 7'd12;  end  // Y (right face) : enter
        4'd6:  begin nbits = 5'd20; address = 13'd272; command = 7'd125; end  // X (bottom face): BACK
        4'd5:  begin nbits = 5'd15; address = 13'd48;  command = 7'd83;  end  // B (top face)   : AMP MENU
        4'd4:  begin nbits = 5'd20; address = 13'd272; command = 7'd115; end  // A (left face)  : options
        default: begin valid = 1'b0; nbits = 5'd15; address = 13'd0; command = 7'd0; end
    endcase
    lookup = {valid, nbits, address, command};
end
endfunction

endmodule
