`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 02 - Dual Parallel MAC
// Module  : dual_mac_tb (Self-Checking Testbench)
// Author  : Gayathri Satheesh
//
// Description:
// Self-checking testbench for the dual_mac module.
//
// Verification Strategy:
//   A software reference model (integer accumulators) runs in parallel with
//   the RTL. After every clock edge, the RTL output is compared against the
//   expected value. Any mismatch is flagged immediately with a timestamped
//   error message.
//
// Test Cases Covered:
//   TC1  - Synchronous reset clears both accumulators to zero
//   TC2  - Positive × Positive accumulation (MAC1 and MAC2 run independently)
//   TC3  - Positive × Negative accumulation
//   TC4  - Negative × Negative accumulation
//   TC5  - Zero input leaves accumulator unchanged
//   TC6  - Independence: MAC1 and MAC2 run different sequences simultaneously
//   TC7  - Maximum positive saturation boundary
//   TC8  - Minimum negative (most-negative) input
//   TC9  - Mid-run reset — both accumulators clear and restart
//   TC10 - Long accumulation run (N cycles, verified by reference model)
//
// Parameters (must match DUT):
//   DATA_WIDTH = 8
//   ACC_WIDTH  = (2*DATA_WIDTH)+1 = 17
//
// Pass / Fail:
//   Each check prints PASS or FAIL.
//   Final summary prints total errors. Simulation exits via $finish.
//
//////////////////////////////////////////////////////////////////////////////////

module dual_mac_tb;

    // -----------------------------------------------------------------------
    // Parameters — mirror the DUT
    // -----------------------------------------------------------------------
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = (2 * DATA_WIDTH) + 1;  // 17 bits

    localparam CLK_PERIOD = 10;  // 10 ns → 100 MHz

    // -----------------------------------------------------------------------
    // DUT Port Declarations
    // -----------------------------------------------------------------------
    reg                          clk;
    reg                          rst;

    reg  signed [DATA_WIDTH-1:0] a1, b1;
    reg  signed [DATA_WIDTH-1:0] a2, b2;

    wire signed [ACC_WIDTH-1:0]  acc1, acc2;

    // -----------------------------------------------------------------------
    // Reference Model (software golden model)
    // -----------------------------------------------------------------------
    // Use 64-bit signed integers to avoid overflow in the reference.
    // We check only against the truncated ACC_WIDTH bits.
    integer ref_acc1;
    integer ref_acc2;

    // -----------------------------------------------------------------------
    // Error counter
    // -----------------------------------------------------------------------
    integer error_count;
    integer test_num;

    // -----------------------------------------------------------------------
    // DUT Instantiation
    // -----------------------------------------------------------------------
    dual_mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk  (clk),
        .rst  (rst),
        .a1   (a1),
        .b1   (b1),
        .a2   (a2),
        .b2   (b2),
        .acc1 (acc1),
        .acc2 (acc2)
    );

    // -----------------------------------------------------------------------
    // Clock Generation
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: apply_inputs
    //   Drives a1,b1,a2,b2 and advances one clock cycle.
    //   Updates the reference model and checks DUT output.
    // -----------------------------------------------------------------------


    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a1, in_b1;
        input signed [DATA_WIDTH-1:0] in_a2, in_b2;
        begin
            // Drive inputs
            a1 = in_a1;  b1 = in_b1;
            a2 = in_a2;  b2 = in_b2;

            // Wait for rising edge (DUT captures inputs and updates ACC)
            @(posedge clk);
            #1; // small delta delay — sample after clk edge

            // Update reference model
            ref_acc1 = ref_acc1 + (in_a1 * in_b1);
            ref_acc2 = ref_acc2 + (in_a2 * in_b2);

            // Check MAC 1
            if (acc1 !== ref_acc1[ACC_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | ACC1: got %0d, expected %0d",
                         $time, test_num, $signed(acc1), ref_acc1);
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | ACC1 = %0d (a1=%0d, b1=%0d)",
                         $time, test_num, $signed(acc1), $signed(in_a1), $signed(in_b1));
            end

            // Check MAC 2
            if (acc2 !== ref_acc2[ACC_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | ACC2: got %0d, expected %0d",
                         $time, test_num, $signed(acc2), ref_acc2);
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | ACC2 = %0d (a2=%0d, b2=%0d)",
                         $time, test_num, $signed(acc2), $signed(in_a2), $signed(in_b2));
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: do_reset
    //   Applies synchronous reset for 2 cycles, then releases.
    //   Clears the reference model and checks DUT output.
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst = 1;
            @(posedge clk); #1;
            @(posedge clk); #1;

            // Reference model reset
            ref_acc1 = 0;
            ref_acc2 = 0;

            // Check both accumulators are zero
            if (acc1 !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | ACC1 not zero after reset: got %0d",
                         $time, $signed(acc1));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | RESET | ACC1 = 0 after reset", $time);
            end

            if (acc2 !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | ACC2 not zero after reset: got %0d",
                         $time, $signed(acc2));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | RESET | ACC2 = 0 after reset", $time);
            end

            rst = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: check_reset_independence
    //   Verifies that mid-run reset clears accumulators regardless of state.
    // -----------------------------------------------------------------------
    task check_mid_reset;
        begin
            $display("\n--- TC9: Mid-run Reset ---");
            test_num = 9;

            // Accumulate some values first
            apply_inputs(8'd5,  8'd4,  8'd3, 8'd2);
            apply_inputs(8'd10, 8'd10, 8'd7, 8'd7);

            // Apply reset mid-run
            rst = 1;
            @(posedge clk); #1;

            ref_acc1 = 0;
            ref_acc2 = 0;

            if (acc1 !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | TC9 | ACC1 not zero after mid-reset: got %0d",
                         $time, $signed(acc1));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC9 | ACC1 = 0 after mid-reset", $time);
            end

            if (acc2 !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | TC9 | ACC2 not zero after mid-reset: got %0d",
                         $time, $signed(acc2));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC9 | ACC2 = 0 after mid-reset", $time);
            end

            rst = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------------------------------
    integer i;

    initial begin
        // ----- Initialise -----
        error_count = 0;
        test_num    = 0;
        clk = 0; rst = 1;
        a1 = 0; b1 = 0;
        a2 = 0; b2 = 0;
        ref_acc1 = 0;
        ref_acc2 = 0;

        $display("============================================================");
        $display("  Self-Checking Testbench : dual_mac");
        $display("  DATA_WIDTH=%0d  ACC_WIDTH=%0d", DATA_WIDTH, ACC_WIDTH);
        $display("============================================================");

        // ===================================================================
        // TC1 — Synchronous Reset
        // ===================================================================
        $display("\n--- TC1: Synchronous Reset ---");
        test_num = 1;
        do_reset;

        // ===================================================================
        // TC2 — Positive × Positive (5 cycles)
        // ===================================================================
        $display("\n--- TC2: Positive x Positive ---");
        test_num = 2;
        apply_inputs( 8'd3,  8'd4,   8'd5,  8'd2 );  // ACC1 += 12, ACC2 += 10
        apply_inputs( 8'd7,  8'd6,   8'd3,  8'd3 );  // ACC1 += 42, ACC2 += 9
        apply_inputs( 8'd1,  8'd100, 8'd10, 8'd10);  // ACC1 += 100, ACC2 += 100
        apply_inputs( 8'd8,  8'd8,   8'd4,  8'd4 );  // ACC1 += 64, ACC2 += 16
        apply_inputs( 8'd2,  8'd2,   8'd6,  8'd6 );  // ACC1 += 4, ACC2 += 36

        // ===================================================================
        // TC3 — Positive × Negative (3 cycles)
        // ===================================================================
        $display("\n--- TC3: Positive x Negative ---");
        test_num = 3;
        apply_inputs( 8'd5,  -8'd3,  8'd7,  -8'd4 );  // ACC1 += -15, ACC2 += -28
        apply_inputs( 8'd10, -8'd2,  8'd1,  -8'd1 );
        apply_inputs( 8'd4,  -8'd5,  8'd9,  -8'd9 );

        // ===================================================================
        // TC4 — Negative × Negative (3 cycles)
        // ===================================================================
        $display("\n--- TC4: Negative x Negative ---");
        test_num = 4;
        apply_inputs( -8'd3, -8'd4,  -8'd6, -8'd7  );  // products are positive
        apply_inputs( -8'd5, -8'd5,  -8'd2, -8'd2  );
        apply_inputs( -8'd8, -8'd10, -8'd1, -8'd100);

        // ===================================================================
        // TC5 — Zero Inputs (accumulator must NOT change)
        // ===================================================================
        $display("\n--- TC5: Zero Inputs (ACC must stay unchanged) ---");
        test_num = 5;
        apply_inputs( 8'd0, 8'd0,  8'd0, 8'd0);  // ACC1 += 0, ACC2 += 0
        apply_inputs( 8'd0, 8'd99, 8'd99, 8'd0);  // still 0 (one operand = 0)

        // ===================================================================
        // TC6 — Independence: different sequences on MAC1 vs MAC2
        //        Expected: accumulators diverge over time
        // ===================================================================
        $display("\n--- TC6: Independence (MAC1 and MAC2 use different inputs) ---");
        test_num = 6;
        do_reset;  // fresh start

        apply_inputs( 8'd1,  8'd1,  8'd10,  8'd10);
        apply_inputs( 8'd2,  8'd2,  8'd20,  8'd20);
        apply_inputs( 8'd3,  8'd3,  8'd30,  8'd30);
        apply_inputs( 8'd4,  8'd4,  8'd40,  8'd40);
        apply_inputs( 8'd5,  8'd5,  8'd50,  8'd50);
        // Expected: ACC1 = 1+4+9+16+25 = 55; ACC2 = 100+400+900+1600+2500 = 5500

        // ===================================================================
        // TC7 — Maximum Positive Boundary (DATA_WIDTH-1 = 127)
        // ===================================================================
        $display("\n--- TC7: Max Positive Boundary (127 x 127) ---");
        test_num = 7;
        do_reset;

        apply_inputs( 8'd127, 8'd127, 8'd127, 8'd127);
        // product = 16129. ACC1 = ACC2 = 16129

        // ===================================================================
        // TC8 — Most-Negative Input (-128 × -128)
        // ===================================================================
        $display("\n--- TC8: Most-Negative Input (-128 x -128) ---");
        test_num = 8;
        do_reset;

        apply_inputs( -8'd128, -8'd128, -8'd128, 8'd127);
        // MAC1 product = 16384 (positive)  MAC2 product = -128*127 = -16256

        // ===================================================================
        // TC9 — Mid-run Reset
        // ===================================================================
        check_mid_reset;

        // ===================================================================
        // TC10 — Long Accumulation (50 cycles, reference model verified each step)
        // ===================================================================
        $display("\n--- TC10: Long Accumulation (50 cycles) ---");
        test_num = 10;
        do_reset;

        for (i = 0; i < 50; i = i + 1) begin
            // Use deterministic but varying values within signed 8-bit range
            apply_inputs(
                $signed(i[7:0] % 10),       $signed((i[7:0] + 1) % 10),
                $signed(-(i[7:0] % 8)),     $signed((i[7:0] + 3) % 12)
            );
        end

        // ===================================================================
        // Final Summary
        // ===================================================================
        $display("\n============================================================");
        if (error_count == 0) begin
            $display("  RESULT : ALL TESTS PASSED (0 errors)");
        end else begin
            $display("  RESULT : FAILED — %0d error(s) detected", error_count);
        end
        $display("============================================================\n");

        $finish;
    end

    // -----------------------------------------------------------------------
    // Timeout Watchdog — kill simulation if it hangs
    // -----------------------------------------------------------------------
    initial begin
        #100000;
        $display("[WATCHDOG] Simulation exceeded time limit. Terminating.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform Dump (for Vivado / ModelSim / iVerilog)
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("dual_mac_tb.vcd");
        $dumpvars(0, dual_mac_tb);
    end

endmodule
