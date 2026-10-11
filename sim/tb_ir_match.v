// tb_ir_match.v
// ir_match (M9) over the real library ROM and protocol microcode: a sequence
// of identify runs, fresh and narrowing (build/ir_expected/m9_match.txt from
// tools/ir/test_match.py: the hardware Sony capture, leaders only, Samsung
// VOL+ then POWER, a code not in the library, unreadable while narrowing, and
// one library code per protocol). Result, count and every {type, brand, set}
// of the list must equal the model's. Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_ir_match;

reg clk = 0;
always #5 clk = ~clk;

// library ROM and interval RAM, one-cycle reads (dev_ctrl.v / ir_rx_marks.v)
reg  [7:0]  lib [0:65535];
reg  [15:0] ivmem [0:255];
wire [15:0] lib_addr;
wire [7:0]  iv_addr;
reg  [7:0]  lib_q = 0;
reg  [15:0] iv_q = 0;
always @(posedge clk) begin lib_q <= lib[lib_addr]; iv_q <= ivmem[iv_addr]; end

reg         start = 0, narrow = 0;
reg  [8:0]  n_iv = 0;
reg  [9:0]  list_raddr = 0;
wire        busy, done;
wire [1:0]  result;
wire [15:0] n_match;
wire [31:0] list_q;

ir_match #(.PROG_FILE("src/fpga/core/ir/ir_proto.hex")) dut (
    .clk(clk), .start(start), .narrow(narrow), .n_iv(n_iv),
    .iv_addr(iv_addr), .iv_q(iv_q), .lib_addr(lib_addr), .lib_q(lib_q),
    .busy(busy), .done(done), .result(result), .n_match(n_match),
    .list_raddr(list_raddr), .list_q(list_q));

integer fd, nrun, r, j, v, x, errors, er, nexp, cycles, maxcyc, tt, bb, ss;
initial begin
    errors = 0; maxcyc = 0;
    $readmemh("src/fpga/core/lib/ir_lib.hex", lib);
    fd = $fopen("build/ir_expected/m9_match.txt", "r");
    if (fd == 0) begin $display("FAIL tb_ir_match (no vectors: run tools/ir/test_match.py)"); $finish; end
    v = $fscanf(fd, "%d", nrun);
    for (r = 0; r < nrun; r = r + 1) begin
        v = $fscanf(fd, "%d %d", x, j);
        narrow = x; n_iv = j;
        for (j = 0; j < n_iv; j = j + 1) begin v = $fscanf(fd, "%d", x); ivmem[j] = x; end
        v = $fscanf(fd, "%d %d", er, nexp);
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        cycles = 0;
        while (!done && cycles < 20_000_000) begin @(negedge clk); cycles = cycles + 1; end
        if (cycles > maxcyc) maxcyc = cycles;
        if (result !== er || n_match !== nexp) begin
            $display("  run %0d: result %0d, %0d matches; expected %0d, %0d", r, result, n_match, er, nexp);
            errors = errors + 1;
        end
        for (j = 0; j < nexp; j = j + 1) begin
            v = $fscanf(fd, "%d %d %d", tt, bb, ss);
            @(negedge clk) list_raddr = j;
            @(negedge clk);
            @(negedge clk);
            if (list_q !== {tt[7:0], bb[11:0], ss[11:0]}) begin
                if (errors < 12) $display("  run %0d: entry %0d = %0d/%0d/%0d, expected %0d/%0d/%0d", r, j,
                                          list_q[31:24], list_q[23:12], list_q[11:0], tt, bb, ss);
                errors = errors + 1;
            end
        end
    end
    if (errors == 0) $display("PASS tb_ir_match (%0d runs, longest scan %0d cycles = %0d ms at 74.25 MHz)",
                              nrun, maxcyc, maxcyc / 74250);
    else             $display("FAIL tb_ir_match (%0d errors)", errors);
    $finish;
end

endmodule
