// tb_rx_cap.v
// ir_rx_cap (M9 step 1): a loaded save region reads back unchanged; a burst
// is recorded edge for edge into the inactive buffer and becomes active; a
// short (noise) burst is rejected and leaves the active buffer alone; buffer
// overflow, the MAX_MS limit, the TX flag and a stop mid-burst are flagged in
// the header. Reads are checked the way APF does them (strobe, move on,
// sample later). Prints PASS or FAIL.

`timescale 1ns/1ps

module tb_rx_cap;

localparam [31:0] ADDR = 32'h1000_0020, MAGIC = 32'h49524331;
localparam        CLK_HZ = 100_000;               // 1 clock = 10 us: GAP 20000, MAX 300000 clocks
localparam        DL = 6, DEPTH = 1 << DL;
localparam        GAP = CLK_HZ / 1000 * 200, MAX = CLK_HZ / 1000 * 3000;
localparam [30:0] SAT = 31'h7FFF_FFFF;

reg         clk = 0;
always #5 clk = ~clk;
integer errors = 0;

reg         run = 0, rx = 1, tx_busy = 0;
reg         wr = 0, rd = 0;
reg  [31:0] addr = 0, wdata = 0;
wire        active, rd_hit;
wire [31:0] rd_data;

ir_rx_cap #(.ADDR(ADDR), .CLK_HZ(CLK_HZ), .DEPTH_LOG2(DL), .GAP_MS(200), .MAX_MS(3000), .MIN_EDGES(20)) dut (
    .clk(clk), .run(run), .rx(rx), .tx_busy(tx_busy), .active(active),
    .bridge_addr(addr), .bridge_wr(wr), .bridge_wr_data(wdata), .bridge_rd(rd),
    .rd_data(rd_data), .rd_hit(rd_hit));

function [31:0] buf_addr(input integer b, input integer i);
    buf_addr = ADDR + 32 + 4 * (b * DEPTH + i);
endfunction

task write(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; wr = 1;
        @(negedge clk); wr = 0; addr = 0;
    end
endtask

reg [31:0] got;
task read(input [31:0] a);
    begin
        @(negedge clk); addr = a; rd = 1;
        @(negedge clk); rd = 0; addr = a + 4;
        repeat (3) @(negedge clk);
        got = rd_data;
    end
endtask

task chk(input [31:0] a, input [31:0] d, input [8*28-1:0] what);
    begin
        read(a);
        if (got !== d || rd_hit !== 1'b1) begin
            $display("  %0s: [%08h] = %08h (hit %b), expected %08h", what, a, got, rd_hit, d);
            errors = errors + 1;
        end
    end
endtask

function [31:0] info(input k, input lvl, input tx, input full, input maxed, input integer n);
    info = {k, lvl, tx, full, maxed, 11'd0, n[15:0]};
endfunction

function [31:0] h1(input act, input [7:0] kept, input [7:0] rej);
    h1 = {act, 3'd0, DL[3:0], 8'd0, kept, rej};
endfunction

// edge times of a burst: delta of edge i (clocks since the previous edge)
function integer delta(input integer seed, input integer i);
    delta = 3 + ((i * 7 + seed * 13) % 23);
endfunction

// Toggle rx `n` times; edge i comes delta(seed, i) clocks after edge i-1.
integer i, k, sum;
task burst(input integer seed, input integer n);
    begin
        sum = 0;
        for (i = 0; i < n; i = i + 1) begin
            if (i > 0) begin repeat (delta(seed, i)) @(negedge clk); sum = sum + delta(seed, i); end
            else @(negedge clk);
            rx = ~rx;
        end
    end
endtask

task wait_idle;
    begin
        k = 0;
        while (active && k < MAX + GAP + 100) begin @(negedge clk); k = k + 1; end
        if (active) begin $display("  burst never ended"); errors = errors + 1; end
    end
endtask

// check a recorded burst: entries 1.. hold the deltas, levels alternate from !lvl0
task check_buf(input integer b, input integer seed, input integer n, input lvl0, input [8*28-1:0] what);
    integer j, nerr;
    begin
        nerr = 0;
        for (j = 1; j < n && j < DEPTH; j = j + 1) begin
            read(buf_addr(b, j));
            if (got !== {(j % 2 == 0) ? ~lvl0 : lvl0, 31'd0} + delta(seed, j)) nerr = nerr + 1;
        end
        read(buf_addr(b, 0));
        if (got[31] !== ~lvl0) nerr = nerr + 1;
        if (nerr) begin $display("  %0s: %0d wrong entries", what, nerr); errors = errors + 1; end
    end
endtask

integer dur;
initial begin
    // ---- 1. APF loads the region from the save file (core in reset)
    write(ADDR + 0,  MAGIC);
    write(ADDR + 4,  32'h8000_0000);          // active = buffer 1
    write(ADDR + 8,  32'd0);
    write(ADDR + 12, 32'd0);
    write(ADDR + 16, 32'd0);
    write(ADDR + 20, info(1, 1, 0, 0, 0, 3));
    write(ADDR + 24, 32'd3);
    write(ADDR + 28, 32'd99);
    write(buf_addr(1, 0), 32'h1111_1111);
    write(buf_addr(1, 1), 32'h2222_2222);
    write(buf_addr(1, 2), 32'h3333_3333);
    chk(ADDR + 0,  MAGIC, "loaded magic");
    chk(ADDR + 4,  h1(1, 0, 0), "loaded H1");
    chk(ADDR + 20, info(1, 1, 0, 0, 0, 3), "loaded info1");
    chk(ADDR + 28, 32'd99, "loaded dur1");
    chk(buf_addr(1, 1), 32'h2222_2222, "loaded entry");
    // edges while not running are ignored
    rx = 0; repeat (5) @(negedge clk); rx = 1; repeat (5) @(negedge clk);
    if (active) begin $display("  captured while not running"); errors = errors + 1; end
    read(32'h1000_0000);
    if (rd_hit !== 1'b0) begin $display("  device block read claimed by capture"); errors = errors + 1; end

    // ---- 2. a good burst (idle high) goes into buffer 0 and becomes active
    run = 1; repeat (10) @(negedge clk);
    burst(1, 30);
    dur = sum;
    if (!active) begin $display("  not active during a burst"); errors = errors + 1; end
    wait_idle;
    chk(ADDR + 4,  h1(0, 1, 0), "H1 after burst A");
    chk(ADDR + 8,  info(1, 1, 0, 0, 0, 30), "info0 burst A");
    chk(ADDR + 12, 32'd30, "total0 burst A");
    chk(ADDR + 16, dur, "dur0 burst A");
    check_buf(0, 1, 30, 1'b1, "burst A");
    chk(buf_addr(1, 1), 32'h2222_2222, "buffer 1 kept");

    // ---- 3. noise: 5 edges, rejected, buffer 0 stays active
    burst(2, 5);
    wait_idle;
    chk(ADDR + 4,  h1(0, 1, 1), "H1 after noise");
    chk(ADDR + 20, info(0, 1, 0, 0, 0, 5), "info1 noise");
    chk(ADDR + 8,  info(1, 1, 0, 0, 0, 30), "info0 after noise");
    check_buf(0, 1, 30, 1'b1, "burst A after noise");

    // ---- 4. overflow + TX busy during the burst: buffer 1, full, tx flag
    fork
        burst(3, DEPTH + 11);
        begin repeat (40) @(negedge clk); tx_busy = 1; repeat (3) @(negedge clk); tx_busy = 0; end
    join
    dur = sum;
    wait_idle;
    chk(ADDR + 4,  h1(1, 2, 1), "H1 after overflow");
    chk(ADDR + 20, info(1, 0, 1, 1, 0, DEPTH), "info1 overflow");
    chk(ADDR + 24, DEPTH + 11, "total1 overflow");
    chk(ADDR + 28, dur, "dur1 overflow");
    check_buf(1, 3, DEPTH, 1'b0, "overflow burst");

    // ---- 5. continuous edges: the burst ends at MAX_MS
    fork
        begin : noise
            forever begin repeat (500) @(negedge clk); rx = ~rx; end
        end
        begin
            @(posedge active);
            k = 0;
            while (active && k < MAX + 100) begin @(negedge clk); k = k + 1; end
            disable noise;
        end
    join
    if (k < MAX - 2 || k > MAX + 2) begin $display("  MAX burst lasted %0d clocks", k); errors = errors + 1; end
    chk(ADDR + 8,  info(1, 1, 0, 1, 1, DEPTH), "info0 maxed");
    chk(ADDR + 12, MAX / 500 + 1, "total0 maxed");
    wait_idle;

    // ---- 6. the core stops mid-burst: the burst ends at once
    burst(4, 25);
    repeat (5) @(negedge clk);                // last edge through the synchroniser
    run = 0;
    @(negedge clk); @(negedge clk);
    if (active) begin $display("  still active after run fell"); errors = errors + 1; end
    read(ADDR + 4);
    k = got[31];                              // buffer the burst went into is now active
    chk(ADDR + 8 + 12 * k, info(1, 0, 0, 0, 0, 25), "info after stop");

    // ---- 7. restart: kept/rejected counters clear, active buffer stays
    run = 1; repeat (3) @(negedge clk);
    chk(ADDR + 4, h1(k[0], 0, 0), "H1 after restart");

    if (errors == 0) $display("PASS tb_rx_cap");
    else             $display("FAIL tb_rx_cap (%0d errors)", errors);
    $finish;
end

endmodule
