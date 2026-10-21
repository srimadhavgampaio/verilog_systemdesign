`timescale 1ns / 1ps

module tb_bist_top;

    reg         clk;
    reg         rst;
    reg         start;
    reg  [7:0]  func_a;
    reg  [7:0]  func_b;

    wire [7:0]  signature;
    wire        done;
    wire        pass_flag;
    wire        enable;
    wire [3:0]  pattern;
    wire [15:0] product;

    // Instantiate the BIST Top Wrapper
    bist_top uut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .func_a    (func_a),
        .func_b    (func_b),
        .signature (signature),
        .done      (done),
        .pass_flag (pass_flag),
        .enable    (enable),
        .pattern   (pattern),
        .product   (product)
    );

    // 100 MHz Clock Generation (10 ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        // Dump waveforms for GTKWave
        $dumpfile("bist_sim.vcd");
        $dumpvars(0, tb_bist_top);

        $display("-------------------------------------------------------------------------");
        $display("Time(ns) | rst start en done | pattern | product(hex/dec) | sig(hex/dec) | pass");
        $display("-------------------------------------------------------------------------");
        $monitor("%8t |  %b    %b    %b   %b  |   %2d    |  %04h (%5d)    |   %02h (%3d)   |  %b",
                 $time, rst, start, enable, done, pattern, product, product, signature, signature, pass_flag);

        // Phase 1: Reset condition (Matches Fig. 6: signature=01, pattern=1, product=0121)
        rst    = 1'b1;
        start  = 1'b0;
        func_a = 8'h11;
        func_b = 8'h11;
        #20;

        // Phase 2: Release reset and start BIST self-test (Matches Fig. 7)
        rst   = 1'b0;
        start = 1'b1;

        // Wait for BIST controller to assert done (15 test vectors)
        wait (done == 1'b1);
        #20;

        $display("-------------------------------------------------------------------------");
        if (pass_flag)
            $display("BIST RESULT: PASS (Final Signature 0x%02h matches Golden Reference)", signature);
        else
            $display("BIST RESULT: FAIL (Final Signature 0x%02h != Golden Reference)", signature);
        $display("-------------------------------------------------------------------------");

        $finish;
    end

endmodule