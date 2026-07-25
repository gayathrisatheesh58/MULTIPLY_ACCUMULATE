
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 01 - Single MAC
// Module  : mac_tb
// Author  : Gayathri Satheesh
//
// Description:
// Testbench for the parameterized signed Multiply-Accumulate (MAC) Unit.
//
// Test Cases:
//  1. Reset behaviour           - ACC must clear to 0 on rst
//  2. Basic positive multiply   - small positive A × B
//  3. Positive accumulation     - multiple cycles accumulate correctly
//  4. Signed (negative) inputs  - negative × positive, negative × negative
//  5. Zero operand              - A=0 or B=0 keeps ACC unchanged
//  6. Max positive inputs       - check no overflow for expected range
//  7. Max negative inputs       - most-negative signed value
//  8. Mid-accumulation reset    - rst clears a running ACC
//
//////////////////////////////////////////////////////////////////////////////////

module mac_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = (2 * DATA_WIDTH) + 1;   // 17 bits for DATA_WIDTH=8

    // -------------------------------------------------------------------------
    // DUT I/O
    // -------------------------------------------------------------------------
    reg                        clk;
    reg                        rst;
    reg  signed [DATA_WIDTH-1:0] a;
    reg  signed [DATA_WIDTH-1:0] b;
    wire signed [ACC_WIDTH-1:0]  acc;

    // -------------------------------------------------------------------------
    // Reference accumulator (software model)
    // -------------------------------------------------------------------------
    integer expected_acc;
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk (clk),
        .rst (rst),
        .a   (a),
        .b   (b),
        .acc (acc)
    );

    // -------------------------------------------------------------------------
    // Clock generation  - 10 ns period (100 MHz)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Task : apply_inputs
    //   Sets a and b, waits one clock edge, checks ACC against expected_acc.
    // -------------------------------------------------------------------------
    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a;
        input signed [DATA_WIDTH-1:0] in_b;
        input [127:0]                 test_name;   // string label (up to 16 chars)
        begin
            a = in_a;
            b = in_b;
            // Update expected model (only if not in reset this cycle)
            expected_acc = expected_acc + ($signed(in_a) * $signed(in_b));
            @(posedge clk); #1;   // sample just after rising edge
            if (acc === expected_acc[ACC_WIDTH-1:0]) begin
                $display("  PASS | %-20s | a=%4d  b=%4d | acc=%8d (expected %8d)",
                         test_name, $signed(in_a), $signed(in_b),
                         $signed(acc), expected_acc);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL | %-20s | a=%4d  b=%4d | acc=%8d (expected %8d)  <<<",
                         test_name, $signed(in_a), $signed(in_b),
                         $signed(acc), expected_acc);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task : do_reset
    //   Pulses rst for one clock cycle, verifies ACC goes to 0.
    // -------------------------------------------------------------------------
    task do_reset;
        input [127:0] label;
        begin
            rst = 1;
            @(posedge clk); #1;
            if (acc === 0) begin
                $display("  PASS | %-20s | ACC correctly cleared to 0", label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL | %-20s | ACC = %0d after reset (expected 0)  <<<",
                         label, $signed(acc));
                fail_count = fail_count + 1;
            end
            rst = 0;
            expected_acc = 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Initialise
        a            = 0;
        b            = 0;
        rst          = 0;
        expected_acc = 0;
        pass_count   = 0;
        fail_count   = 0;

        $display("=============================================================");
        $display("  MAC Testbench  (DATA_WIDTH=%0d, ACC_WIDTH=%0d)", DATA_WIDTH, ACC_WIDTH);
        $display("=============================================================");

        // ------------------------------------------------------------------
        // TEST 1 : Initial reset
        // ------------------------------------------------------------------
        $display("\n--- TEST 1 : Initial reset ---");
        do_reset("initial_reset");

        // ------------------------------------------------------------------
        // TEST 2 : Basic positive multiply - single cycle
        // ------------------------------------------------------------------
        $display("\n--- TEST 2 : Basic positive multiply ---");
        apply_inputs(8'd3,  8'd4,  "3  x  4");
        apply_inputs(8'd10, 8'd7,  "10 x  7");

        // ------------------------------------------------------------------
        // TEST 3 : Positive accumulation - several cycles
        // ------------------------------------------------------------------
        $display("\n--- TEST 3 : Positive accumulation ---");
        apply_inputs(8'd5,  8'd5,  "5  x  5");
        apply_inputs(8'd2,  8'd8,  "2  x  8");
        apply_inputs(8'd1,  8'd1,  "1  x  1");

        // ------------------------------------------------------------------
        // TEST 4 : Signed (negative) inputs
        // ------------------------------------------------------------------
        $display("\n--- TEST 4 : Signed inputs ---");
        apply_inputs(-8'd6,  8'd3,  "-6 x  3");   // negative × positive
        apply_inputs(-8'd4, -8'd5,  "-4 x -5");   // negative × negative → positive product
        apply_inputs( 8'd7, -8'd2,  " 7 x -2");   // positive × negative

        // ------------------------------------------------------------------
        // TEST 5 : Zero operand - ACC must stay unchanged
        // ------------------------------------------------------------------
        $display("\n--- TEST 5 : Zero operand ---");
        apply_inputs(8'd0,  8'd99,  "0  x 99");
        apply_inputs(8'd15, 8'd0,   "15 x  0");

        // ------------------------------------------------------------------
        // TEST 6 : Maximum positive inputs (127 × 127 = 16 129)
        // ------------------------------------------------------------------
        $display("\n--- TEST 6 : Max positive inputs ---");
        do_reset("reset_before_max");
        apply_inputs(8'd127,  8'd127,  "127 x 127");

        // ------------------------------------------------------------------
        // TEST 7 : Maximum negative inputs (-128 × -128 = 16 384)
        // ------------------------------------------------------------------
        $display("\n--- TEST 7 : Max negative inputs ---");
        do_reset("reset_before_neg_max");
        apply_inputs(-8'd128, -8'd128, "-128 x -128");

        // ------------------------------------------------------------------
        // TEST 8 : Mixed extremes  (127 × -128 = -16 256)
        // ------------------------------------------------------------------
        $display("\n--- TEST 8 : Mixed extremes ---");
        do_reset("reset_before_mixed");
        apply_inputs(8'd127, -8'd128, "127 x -128");

        // ------------------------------------------------------------------
        // TEST 9 : Mid-accumulation reset
        // ------------------------------------------------------------------
        $display("\n--- TEST 9 : Mid-accumulation reset ---");
        apply_inputs(8'd10, 8'd10, "before_reset_1");
        apply_inputs(8'd20, 8'd3,  "before_reset_2");
        do_reset("mid_acc_reset");
        // After reset, ACC should restart from 0
        apply_inputs(8'd5, 8'd5, "after_reset");

        // ------------------------------------------------------------------
        // TEST 10 : Alternating sign accumulation
        // ------------------------------------------------------------------
        $display("\n--- TEST 10 : Alternating sign accumulation ---");
        do_reset("reset_before_alt");
        apply_inputs( 8'd50, 8'd2,  " 50 x  2");
        apply_inputs(-8'd50, 8'd2,  "-50 x  2");
        apply_inputs( 8'd50, 8'd2,  " 50 x  2");
        apply_inputs(-8'd50, 8'd2,  "-50 x  2");

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n=============================================================");
        $display("  Results : %0d PASS  |  %0d FAIL", pass_count, fail_count);
        $display("=============================================================");
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED - review FAIL lines above");
        $display("=============================================================\n");

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump (optional - comment out if not needed)
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("mac_tb.vcd");
        $dumpvars(0, mac_tb);
    end

endmodule


