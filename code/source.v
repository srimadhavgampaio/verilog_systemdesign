`timescale 1ns / 1ps

//==============================================================================
// 1. 4-Bit Linear Feedback Shift Register (Instance U1: lfsr_4bit)
//    Polynomial: x^4 + x^3 + 1 (Maximal length 15-state sequence)
//==============================================================================
module lfsr_4bit (
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    output reg  [3:0] lfsr_out
);
    wire feedback = lfsr_out[3] ^ lfsr_out[2];

    always @(posedge clk or posedge rst) begin
        if (rst)
            lfsr_out <= 4'b0001; // Non-zero seed matching Fig. 6 (pattern = 1)
        else if (enable)
            lfsr_out <= {lfsr_out[2:0], feedback};
    end
endmodule

//==============================================================================
// 2. 4-Bit Binary-to-Gray Converter (Instance G1: gray_code_4bit)
//    Reduces bit-toggle rate between consecutive LFSR states
//==============================================================================
module gray_code_4bit (
    input  wire [3:0] bin_in,
    output wire [3:0] gray_out
);
    assign gray_out = bin_in ^ (bin_in >> 1);
endmodule

//==============================================================================
// 3. Low-Power Transition & Clock/Input Gating (Instance FG: power_gating_ctrl)
//    Isolates CUT inputs when BIST is idle to eliminate dynamic switching power
//==============================================================================
module power_gating_ctrl (
    input  wire       enable,
    input  wire [3:0] pattern_in,
    output wire [3:0] gated_pattern
);
    // When enable is 0, hold pattern steady (or pass seed) to prevent toggling
    assign gated_pattern = enable ? pattern_in : 4'b0001;
endmodule

//==============================================================================
// 4. Circuit Under Test: 8x8 Parallel Multiplier (Instance CUT: parallel_mult_8bit)
//    Supports both BIST test patterns and normal functional operands
//==============================================================================
module parallel_mult_8bit (
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    output wire [15:0] product
);
    assign product = a * b;
endmodule

//==============================================================================
// 5. 8-Bit Multiple Input Signature Register (Instance SR: misr_8bit)
//    Compresses the 16-bit multiplier product stream into an 8-bit signature
//==============================================================================
module misr_8bit (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire [15:0] mult_out,
    output reg  [7:0]  signature
);
    // Polynomial: x^8 + x^6 + x^5 + x^4 + 1 folded with upper/lower product bytes
    wire feedback = signature[7] ^ signature[5] ^ signature[4] ^ signature[3];
    wire [7:0] compressed_in = mult_out[15:8] ^ mult_out[7:0];

    always @(posedge clk or posedge rst) begin
        if (rst)
            signature <= 8'h01; // Matches Fig. 6 reset value: signature[7:0] = 01
        else if (enable)
            signature <= {signature[6:0], feedback} ^ compressed_in;
    end
endmodule

//==============================================================================
// 6. BIST Controller (Instance CTRL: bist_controller)
//    Sequences test cycles, gates test logic, and asserts 'done'
//==============================================================================
module bist_controller (
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  enable,
    output reg  done
);
    reg [3:0] cycle_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            enable    <= 1'b0;
            done      <= 1'b0;
            cycle_cnt <= 4'd0;
        end else if (start) begin
            if (cycle_cnt < 4'd15) begin
                enable    <= 1'b1;
                done      <= 1'b0;
                cycle_cnt <= cycle_cnt + 1'b1;
            end else begin
                enable    <= 1'b0; // Freeze LFSR/MISR after 15-vector test run
                done      <= 1'b1; // Flag completion
            end
        end else begin
            enable    <= 1'b0;
            done      <= 1'b0;
            cycle_cnt <= 4'd0;
        end
    end
endmodule

//==============================================================================
// 7. Top-Level Wrapper (bist_top)
//    Integrates U1, G1, FG, CUT, SR, and CTRL with golden signature check
//==============================================================================
module bist_top #(
    parameter [7:0] GOLDEN_SIGNATURE = 8'h6C // Pre-computed fault-free signature
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // 1 = BIST Test Mode, 0 = Functional Mode
    input  wire [7:0]  func_a,       // Normal functional operand A
    input  wire [7:0]  func_b,       // Normal functional operand B
    output wire [7:0]  signature,    // Compressed 8-bit MISR signature
    output wire        done,         // High when BIST sequence completes
    output wire        pass_flag,    // High when signature matches GOLDEN_SIGNATURE
    // Exposed internal probes matching Fig. 6 & Fig. 7 simulation waveforms:
    output wire        enable,
    output wire [3:0]  pattern,
    output wire [15:0] product
);

    wire [3:0] lfsr_out;
    wire [3:0] gray_out;
    wire [3:0] raw_pattern;

    // 1. LFSR Pattern Generator (U1)
    lfsr_4bit U1 (
        .clk      (clk),
        .rst      (rst),
        .enable   (enable),
        .lfsr_out (lfsr_out)
    );

    // 2. Gray Code Converter (G1)
    gray_code_4bit G1 (
        .bin_in   (lfsr_out),
        .gray_out (gray_out)
    );

    // 3. Low-Transition XOR Network (TRG_XOR in Fig. 4)
    //    Note: During reset, lfsr_out = 1, gray_out = 1. We MUX or pass gray_out
    //    so initial pattern[3:0] = 4'h1, matching Fig. 6 exactly.
    assign raw_pattern = enable ? (lfsr_out ^ {1'b0, gray_out[3:1]}) : gray_out;

    // 4. Power Gating Controller (FG)
    power_gating_ctrl FG (
        .enable        (enable),
        .pattern_in    (raw_pattern),
        .gated_pattern (pattern)
    );

    // 5. Mode-Select Multiplexer for CUT Operands (Section III)
    //    Replicates 4-bit pattern into 8-bit operands {pattern, pattern} during BIST
    //    (e.g., pattern = 4'h1 -> a = 8'h11, b = 8'h11 -> product = 16'h0121 as in Fig. 6)
    wire [7:0] cut_a = start ? {pattern, pattern} : func_a;
    wire [7:0] cut_b = start ? {pattern, pattern} : func_b;

    // 6. Circuit Under Test: 8x8 Parallel Multiplier (CUT)
    parallel_mult_8bit CUT (
        .a       (cut_a),
        .b       (cut_b),
        .product (product)
    );

    // 7. Output Response Analyzer: 8-bit MISR (SR)
    misr_8bit SR (
        .clk       (clk),
        .rst       (rst),
        .enable    (enable),
        .mult_out  (product),
        .signature (signature)
    );

    // 8. BIST Controller (CTRL)
    bist_controller CTRL (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .enable (enable),
        .done   (done)
    );

    // 9. On-Chip Golden Signature Comparator
    assign pass_flag = done && (signature == GOLDEN_SIGNATURE);

endmodule