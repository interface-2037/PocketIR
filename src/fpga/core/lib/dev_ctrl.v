// dev_ctrl.v
// Device loader (M7). On `load`, walks the on-chip code library (format:
// docs/codes-format.md, built by tools/ir/library.py) for device
// {dev_t type, dev_b brand, dev_s code set} and
//   * fills the 12-entry code table that ir_remote.v sends from, and
//   * rewrites the main-screen text slots 0..10 (title, remote model, button
//     labels; missing functions dimmed) and blanks slots 11..31.
// Reference: library.read_library() + ui_text.main_slots(); checked by
// sim/tb_remote.v against vectors from tools/ir/test_library.py.
//
// The library ROM is read one byte per two cycles; a whole load takes a few
// thousand clk cycles (tens of microseconds).

module dev_ctrl #(
    parameter LIB_FILE = "core/lib/ir_lib.hex"
) (
    input  wire        clk,
    input  wire        load,              // pulse: (re)load the device below
    input  wire [7:0]  dev_t,
    input  wire [15:0] dev_b,
    input  wire [15:0] dev_s,
    output wire        busy,
    // code table, read by function index (0 POWER .. 11 INPUT, library order)
    input  wire [3:0]  func,
    output wire        code_valid,
    output wire [5:0]  code_proto,
    output wire [31:0] code_d,
    output wire [31:0] code_f,
    // text layer writes (ui_text.v)
    output reg         slot_we = 1'b0,
    output reg  [4:0]  slot_waddr = 5'd0,
    output reg  [31:0] slot_wdata = 32'd0,
    output reg         str_we = 1'b0,
    output reg  [9:0]  str_waddr = 10'd0,
    output reg  [7:0]  str_wdata = 8'd0
);

`include "ir_lib.vh"
`include "ui_text.vh"

// ------------------------------------------------------------------ library ROM
reg [7:0]  lib [0:IR_LIB_BYTES-1];
initial $readmemh(LIB_FILE, lib);
reg [15:0] la = 16'd0;
reg [7:0]  lq = 8'd0;
always @(posedge clk) lq <= lib[la];

// ------------------------------------------------------------------ code table
reg [11:0] valid = 12'd0;
reg [5:0]  t_proto [0:11];
reg [31:0] t_d [0:11];
reg [31:0] t_f [0:11];
assign code_valid = (func < 4'd12) ? valid[func] : 1'b0;
assign code_proto = t_proto[func];
assign code_d     = t_d[func];
assign code_f     = t_f[func];

// function -> main-screen text slot (0 = none); constant-string index of its default word
function [3:0] fslot(input [3:0] f);
    case (f)
        4'd0: fslot = 4'd2;  4'd3: fslot = 4'd3;  4'd10: fslot = 4'd4; 4'd11: fslot = 4'd5;
        4'd8: fslot = 4'd6;  4'd9: fslot = 4'd7;  4'd2:  fslot = 4'd8; 4'd1:  fslot = 4'd9;
        default: fslot = 4'd0;
    endcase
endfunction
function [3:0] fword(input [3:0] f);        // CONSTS index (library.CONSTS)
    case (f)
        4'd0: fword = 4'd8;  4'd3: fword = 4'd9;  4'd10: fword = 4'd4; 4'd11: fword = 4'd5;
        4'd8: fword = 4'd6;  4'd9: fword = 4'd7;  4'd2:  fword = 4'd1; 4'd1:  fword = 4'd2;
        default: fword = 4'd0;
    endcase
endfunction
function [31:0] main_slot(input [3:0] n);
    case (n)
        4'd0: main_slot = MAIN_SLOT_0;  4'd1: main_slot = MAIN_SLOT_1;  4'd2: main_slot = MAIN_SLOT_2;
        4'd3: main_slot = MAIN_SLOT_3;  4'd4: main_slot = MAIN_SLOT_4;  4'd5: main_slot = MAIN_SLOT_5;
        4'd6: main_slot = MAIN_SLOT_6;  4'd7: main_slot = MAIN_SLOT_7;  4'd8: main_slot = MAIN_SLOT_8;
        4'd9: main_slot = MAIN_SLOT_9;  default: main_slot = MAIN_SLOT_10;
    endcase
endfunction
// labels are taken from the library for these functions (VOL keys always say VOLUME UP/DOWN)
function lib_label(input [3:0] f);
    lib_label = (f == 4'd0) || (f == 4'd3) || (f >= 4'd8 && f <= 4'd11);
endfunction

// ------------------------------------------------------------------ sequencer
// st: main steps; S_RD* / S_CP* are subroutines returning to `ret`.
localparam S_IDLE = 8'd0;
localparam S_RD0 = 8'd200, S_RD1 = 8'd201, S_RD2 = 8'd202;          // read n bytes LE -> val
localparam S_CP0 = 8'd210, S_CP1 = 8'd211, S_CP2 = 8'd212;          // copy string -> slot text
reg [7:0]  st = S_IDLE, ret = S_IDLE;
reg [15:0] rd_a = 0;  reg [2:0] rd_n = 0, rd_k = 0;  reg [31:0] val = 0;
reg [15:0] cp_a = 0;  reg [4:0] cp_slot = 0;  reg [4:0] pos = 0;      // pos: chars written in slot

reg [31:0] label_off = 0, const_off = 0, type_off = 0, tname = 0, btab = 0, bname = 0,
           lst = 0, cs = 0, model = 0, dflt_d = 0, cmd = 0, o_d = 0, lab_p = 0;
reg [5:0]  dflt_p = 0, o_p = 0;
reg [15:0] mask = 0, cp_next = 0, p = 0;   // p: walking pointer through the code set
reg [7:0]  lab = 0, flags = 0;
reg [3:0]  f = 0;                          // function being loaded
reg [4:0]  k = 0;                          // misc counter

assign busy = (st != S_IDLE);
wire [31:0] ms = main_slot(fslot(f));     // slot word of the current function's label

// subroutine entry helpers (used as "call" in the step list below)
`define RD(addr, n, next)  begin rd_a <= (addr); rd_n <= (n); ret <= (next); st <= S_RD0; end
`define CP(addr, next)     begin cp_a <= (addr); ret <= (next); st <= S_CP0; end

always @(posedge clk) begin
    slot_we <= 1'b0;
    str_we  <= 1'b0;
    case (st)
        // ---------------- subroutine: read rd_n bytes little-endian from rd_a into val
        S_RD0: begin la <= rd_a; rd_k <= 3'd0; val <= 32'd0; st <= S_RD1; end
        S_RD1: st <= S_RD2;                                         // ROM latency
        S_RD2: begin
            val <= val | ({24'd0, lq} << (8 * rd_k));
            if (rd_k + 1'b1 == rd_n) st <= ret;
            else begin rd_k <= rd_k + 1'b1; la <= la + 1'b1; st <= S_RD1; end
        end
        // ---------------- subroutine: append NUL-terminated string at cp_a to slot cp_slot
        S_CP0: begin la <= cp_a; st <= S_CP1; end
        S_CP1: st <= S_CP2;
        S_CP2: if (lq == 8'd0 || pos == 5'd31) st <= ret;
               else begin
                   str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= lq;
                   pos <= pos + 1'b1; la <= la + 1'b1; st <= S_CP1;
               end

        // ---------------- main sequence
        S_IDLE: if (load) `RD(16'd12, 3'd4, 8'd1)
        8'd1:  begin label_off <= val; `RD(16'd24, 3'd4, 8'd2) end
        8'd2:  begin const_off <= val; `RD(16'd8, 3'd4, 8'd3) end
        8'd3:  begin type_off <= val;  `RD(val[15:0] + 16'd12 * dev_t, 3'd4, 8'd4) end
        8'd4:  begin tname <= val;     `RD(type_off[15:0] + 16'd12 * dev_t + 16'd4, 3'd4, 8'd5) end
        8'd5:  begin btab <= val;      `RD(val[15:0] + 16'd12 * dev_b, 3'd4, 8'd6) end
        8'd6:  begin bname <= val;     `RD(btab[15:0] + 16'd12 * dev_b + 16'd4, 3'd4, 8'd7) end
        8'd7:  begin lst <= val;       `RD(val[15:0] + {dev_s[12:0], 3'd0}, 3'd4, 8'd8) end
        8'd8:  begin cs <= val;        `RD(lst[15:0] + {dev_s[12:0], 3'd0} + 16'd4, 3'd2, 8'd9) end
        // slot 0: "<BRAND> <TYPE>"
        8'd9:  begin model <= val; cp_slot <= 5'd0; pos <= 5'd0; `CP(bname[15:0], 8'd10) end
        8'd10: `RD(const_off[15:0] + 16'd40, 3'd4, 8'd11)             // CONSTS[10] = " "
        8'd11: `CP(val[15:0], 8'd12)
        8'd12: `CP(tname[15:0], 8'd13)
        8'd13: begin                                                  // terminate, slot word
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
            slot_we <= 1'b1; slot_waddr <= 5'd0; slot_wdata <= MAIN_SLOT_0;
            cp_slot <= 5'd1; pos <= 5'd0;
            `RD(const_off[15:0], 3'd4, 8'd14)                          // CONSTS[0] = "REMOTE "
        end
        // slot 1: "REMOTE <model>"
        8'd14: `CP(val[15:0], 8'd15)
        8'd15: `CP(model[15:0], 8'd16)
        8'd16: begin
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
            slot_we <= 1'b1; slot_waddr <= 5'd1; slot_wdata <= MAIN_SLOT_1;
            `RD(cs[15:0], 3'd1, 8'd17)
        end
        // code set header
        8'd17: begin dflt_p <= val[5:0]; `RD(cs[15:0] + 16'd2, 3'd2, 8'd18) end
        8'd18: begin mask <= val[15:0];  `RD(cs[15:0] + 16'd4, 3'd4, 8'd19) end
        8'd19: begin dflt_d <= val; p <= cs[15:0] + 16'd8; f <= 4'd0; valid <= 12'd0; st <= 8'd20; end
        // per function
        8'd20: if (f == 4'd12) st <= 8'd40;
               else if (!mask[f]) st <= 8'd30;                         // missing
               else `RD(p, 3'd2, 8'd21)
        8'd21: begin cmd <= val; `RD(p + 16'd2, 3'd1, 8'd22) end
        8'd22: begin lab <= val[7:0]; `RD(p + 16'd3, 3'd1, 8'd23) end
        8'd23: begin
            flags <= val[7:0];
            p <= p + 16'd4;
            if (val[0]) `RD(p + 16'd4, 3'd1, 8'd24)
            else begin
                t_proto[f] <= dflt_p; t_d[f] <= dflt_d; t_f[f] <= cmd;
                valid[f] <= 1'b1;
                st <= 8'd27;
            end
        end
        8'd24: begin o_p <= val[5:0]; `RD(p + 16'd4, 3'd4, 8'd25) end    // override record
        8'd25: begin o_d <= val;      `RD(p + 16'd8, 3'd4, 8'd26) end
        8'd26: begin
            t_proto[f] <= o_p; t_d[f] <= o_d; t_f[f] <= val;
            valid[f] <= 1'b1; p <= p + 16'd12; st <= 8'd27;
        end
        8'd27: if (fslot(f) == 4'd0) begin f <= f + 1'b1; st <= 8'd20; end   // no label slot
               else begin
                   cp_slot <= {1'b0, fslot(f)}; pos <= 5'd0;
                   if (lib_label(f)) `RD(label_off[15:0] + {6'd0, lab, 2'd0}, 3'd4, 8'd28)
                   else `RD(const_off[15:0] + {10'd0, fword(f), 2'd0}, 3'd4, 8'd28)
               end
        8'd28: `CP(val[15:0], 8'd29)
        8'd29: begin                                                   // present: normal colour
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
            slot_we <= 1'b1; slot_waddr <= cp_slot; slot_wdata <= main_slot(fslot(f));
            f <= f + 1'b1; st <= 8'd20;
        end
        8'd30: if (fslot(f) == 4'd0) begin f <= f + 1'b1; st <= 8'd20; end
               else begin
                   cp_slot <= {1'b0, fslot(f)}; pos <= 5'd0;
                   `RD(const_off[15:0] + {10'd0, fword(f), 2'd0}, 3'd4, 8'd31)
               end
        8'd31: `CP(val[15:0], 8'd32)
        8'd32: begin                                                   // missing: dimmed
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
            slot_we <= 1'b1; slot_waddr <= cp_slot;
            slot_wdata <= {ms[31:24], TXT_DIM, ms[20:0]};
            f <= f + 1'b1; st <= 8'd20;
        end
        // slot 10: NAVIGATE (dimmed unless all four arrows exist)
        8'd40: begin cp_slot <= 5'd10; pos <= 5'd0; `RD(const_off[15:0] + 16'd12, 3'd4, 8'd41) end
        8'd41: `CP(val[15:0], 8'd42)
        8'd42: begin
            str_we <= 1'b1; str_waddr <= {cp_slot, pos}; str_wdata <= 8'd0;
            slot_we <= 1'b1; slot_waddr <= 5'd10;
            slot_wdata <= (valid[7:4] == 4'hF) ? MAIN_SLOT_10 : {MAIN_SLOT_10[31:24], TXT_DIM, MAIN_SLOT_10[20:0]};
            k <= 5'd11; st <= 8'd43;
        end
        // blank slots 11..31 (menu leftovers)
        8'd43: begin
            str_we <= 1'b1; str_waddr <= {k, 5'd0}; str_wdata <= 8'd0;
            if (k == 5'd31) st <= S_IDLE; else k <= k + 1'b1;
        end
        default: st <= S_IDLE;
    endcase
end

`undef RD
`undef CP

endmodule
