`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 03 - Pipelined MAC
// Module  : pipelined_mac_tb (Self-Checking Testbench)
// Author  : Gayathri Satheesh
//
// Description:
// Self-checking testbench for the pipelined_mac module.
//
// Verification Strategy:
//   A software reference model that mirrors both pipeline stages runs in
//   parallel with the RTL. The reference model updates both stages on every
//   clock edge (just like the hardware does), so checking is cycle-accurate.
//   Any mismatch is flagged immediately with a timestamped error message.
//
//   Because the MAC is 2-stage pipelined, the reference model must track:
//     ref_stage1  — mirrors product_reg  (multiply result, 1 cycle old)
//     ref_acc     — mirrors acc          (accumulated sum,  2 cycles behind input)
//
//   After each posedge clk:
//     new_acc    = ref_acc + ref_stage1       (Stage 2 executes with OLD stage1)
//     new_stage1 = in_a * in_b               (Stage 1 executes with new inputs)
//     ref_acc    = new_acc
//     ref_stage1 = new_stage1
//
// Pipeline Latency Notes:
//   - First product appears in acc ONE cycle AFTER it is registered in stage 1.
//   - To drain the last input pair into acc, drive one extra "flush" cycle
//     with zero inputs (or any inputs you don't care about).
//   - Testbench task flush_pipeline() does exactly this.
//
// Test Cases Covered:
//   TC1  - Synchronous reset clears all pipeline registers (product_reg + acc)
//   TC2  - Positive × Positive accumulation
//   TC3  - Positive × Negative accumulation
//   TC4  - Negative × Negative accumulation (results are positive)
//   TC5  - Zero input — accumulator must not change
//   TC6  - Independence check: verify acc diverges from single-stage expectation
//   TC7  - Maximum positive boundary (127 × 127)
//   TC8  - Most-negative input (-128 × -128, -128 × 127)
//   TC9  - Mid-run reset — pipeline and acc both clear
//   TC10 - Pipeline latency demonstration (explicit cycle-by-cycle check)
//   TC11 - Pipeline flush — drain the last product after final input
//   TC12 - Long accumulation run (50 cycles, reference model verified each step)
//
// Parameters (must match DUT):
//   DATA_WIDTH     = 8
//   ACC_WIDTH      = (2*DATA_WIDTH)+1 = 17
//   PIPELINE_STAGES = 2
//
// Pass / Fail:
//   Each check prints PASS or FAIL with timestamp.
//   Final summary prints total error count. Simulation exits via $finish.
//
//////////////////////////////////////////////////////////////////////////////////

module pipelined_mac_tb;

    // -----------------------------------------------------------------------
    // Parameters — mirror the DUT
    // -----------------------------------------------------------------------
    localparam DATA_WIDTH      = 8;
    localparam ACC_WIDTH       = (2 * DATA_WIDTH) + 1;   // 17 bits
    localparam PROD_WIDTH      = (2 * DATA_WIDTH);        // 16 bits
    localparam PIPELINE_STAGES = 2;                       // documented for clarity

    localparam CLK_PERIOD = 10;   // 10 ns → 100 MHz

    // -----------------------------------------------------------------------
    // DUT Port Declarations
    // -----------------------------------------------------------------------
    reg                          clk;
    reg                          rst;
    reg  signed [DATA_WIDTH-1:0] a, b;
    wire signed [ACC_WIDTH-1:0]  acc;

    // -----------------------------------------------------------------------
    // Reference Model — 2-stage pipeline mirror
    //
    // Both are 64-bit to avoid integer overflow in the reference.
    // Comparison against DUT is done on the truncated ACC_WIDTH slice.
    // -----------------------------------------------------------------------
    integer ref_stage1;   // mirrors product_reg (current cycle's captured product)
    integer ref_acc;      // mirrors acc         (running accumulator)

    // Temporaries for simultaneous pipeline stage update
    integer new_stage1;
    integer new_acc;

    // -----------------------------------------------------------------------
    // Error counter and test label
    // -----------------------------------------------------------------------
    integer error_count;
    integer test_num;

    // -----------------------------------------------------------------------
    // DUT Instantiation
    // -----------------------------------------------------------------------
    pipelined_mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk (clk),
        .rst (rst),
        .a   (a),
        .b   (b),
        .acc (acc)
    );

    // -----------------------------------------------------------------------
    // Clock Generation
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: apply_inputs
    //
    // Drives a, b for one clock cycle and advances both stages of the
    // reference model simultaneously — exactly as the hardware does.
    //
    // Reference model update (mirrors two always blocks firing together):
    //   new_acc    = ref_acc + ref_stage1    (Stage 2: acc ← acc + old product)
    //   new_stage1 = in_a * in_b             (Stage 1: product_reg ← a * b)
    //
    // Sampling:
    //   DUT output is sampled 1 ns after the rising edge to let registered
    //   values settle before the comparison.
    // -----------------------------------------------------------------------
    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a, in_b;
        begin
            // Drive inputs (combinational, captured at the next rising edge)
            a = in_a;
            b = in_b;

            // Wait for rising clock edge (DUT captures inputs, updates pipeline)
            @(posedge clk);
            #1;  // small delta delay — sample registered outputs after clk edge

            // ---- Reference model: simultaneous stage update ----
            // Stage 2 uses the OLD ref_stage1 (before Stage 1 updates it)
            new_acc    = ref_acc + ref_stage1;
            new_stage1 = in_a * in_b;
            ref_acc    = new_acc;
            ref_stage1 = new_stage1;
            // ---------------------------------------------------

            // Check DUT output against reference model
            if (acc !== ref_acc[ACC_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | acc: got %0d, expected %0d  (a=%0d, b=%0d)",
                         $time, test_num, $signed(acc), ref_acc,
                         $signed(in_a), $signed(in_b));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | acc=%0d  (a=%0d, b=%0d, pipeline_stage1=%0d)",
                         $time, test_num, $signed(acc),
                         $signed(in_a), $signed(in_b), ref_stage1);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: flush_pipeline
    //
    // Drives one extra cycle with zero inputs to drain the last registered
    // product from product_reg into acc.
    //
    // Why this is needed:
    //   After the last real input pair, product_reg holds (a_last * b_last).
    //   That value has NOT yet been added to acc. One more clock edge pushes
    //   it through Stage 2 into acc.
    //
    //   This is a fundamental property of any pipelined accumulator and is
    //   architecturally important to understand: the pipeline always has
    //   PIPELINE_STAGES-1 products "in flight" that have not yet reached acc.
    // -----------------------------------------------------------------------
    task flush_pipeline;
        begin
            $display("  [FLUSH] Draining pipeline — 1 extra cycle with a=0, b=0");
            apply_inputs(0, 0);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: do_reset
    //   Applies synchronous reset for 2 cycles, then releases.
    //   Clears the reference model and checks DUT output.
    //   Both pipeline registers (product_reg AND acc) must be zero after reset.
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst = 1;
            @(posedge clk); #1;
            @(posedge clk); #1;

            // Clear reference model — both pipeline stages
            ref_stage1 = 0;
            ref_acc    = 0;

            // Check acc is zero
            if (acc !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | acc not zero after reset: got %0d",
                         $time, $signed(acc));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | RESET | acc = 0 after reset", $time);
            end

            rst = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: check_mid_reset
    //   Accumulates a few values, then asserts reset mid-run.
    //   Verifies that BOTH pipeline stages (product_reg and acc) are cleared.
    // -----------------------------------------------------------------------
    task check_mid_reset;
        begin
            $display("\n--- TC9: Mid-run Reset (both pipeline stages must clear) ---");
            test_num = 9;

            // Build up some state in both pipeline stages
            apply_inputs(8'd5,  8'd4);   // stage1 = 20
            apply_inputs(8'd10, 8'd10);  // acc gets 20, stage1 = 100
            apply_inputs(8'd3,  8'd3);   // acc gets 120, stage1 = 9

            // Assert reset mid-run
            rst = 1;
            @(posedge clk); #1;

            // Clear reference model
            ref_stage1 = 0;
            ref_acc    = 0;

            // Both registers must be zero
            if (acc !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | TC9 | acc not zero after mid-reset: got %0d",
                         $time, $signed(acc));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC9 | acc = 0 after mid-reset", $time);
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
        a = 0; b = 0;
        ref_stage1 = 0;
        ref_acc    = 0;

        $display("================================================================");
        $display("  Self-Checking Testbench : pipelined_mac");
        $display("  DATA_WIDTH=%0d  ACC_WIDTH=%0d  PIPELINE_STAGES=%0d",
                 DATA_WIDTH, ACC_WIDTH, PIPELINE_STAGES);
        $display("================================================================");

        // ===================================================================
        // TC1 — Synchronous Reset
        //
        // Both pipeline registers (product_reg and acc) must clear to zero.
        // ===================================================================
        $display("\n--- TC1: Synchronous Reset ---");
        test_num = 1;
        do_reset;

        // ===================================================================
        // TC2 — Positive × Positive (5 cycles)
        //
        // Because of pipeline latency, acc lags inputs by 1 cycle.
        // The reference model handles this automatically.
        // ===================================================================
        $display("\n--- TC2: Positive x Positive (5 cycles) ---");
        test_num = 2;
        apply_inputs( 8'd3,  8'd4 );   // Stage1=12,       acc= 0   (pipeline filling)
        apply_inputs( 8'd7,  8'd6 );   // Stage1=42,       acc=12
        apply_inputs( 8'd1,  8'd100);  // Stage1=100,      acc=12+42=54
        apply_inputs( 8'd8,  8'd8 );   // Stage1=64,       acc=54+100=154
        apply_inputs( 8'd2,  8'd2 );   // Stage1=4,        acc=154+64=218
        flush_pipeline;                // Stage1=0,        acc=218+4=222  ← final result
        do_reset;

        // ===================================================================
        // TC3 — Positive × Negative (3 cycles)
        // ===================================================================
        $display("\n--- TC3: Positive x Negative ---");
        test_num = 3;
        apply_inputs( 8'd5,  -8'd3  );  // product = -15
        apply_inputs( 8'd10, -8'd2  );  // product = -20
        apply_inputs( 8'd4,  -8'd5  );  // product = -20
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC4 — Negative × Negative (3 cycles)
        //
        // Products are positive; accumulator should grow positively.
        // ===================================================================
        $display("\n--- TC4: Negative x Negative ---");
        test_num = 4;
        apply_inputs( -8'd3,  -8'd4  );  // product = +12
        apply_inputs( -8'd5,  -8'd5  );  // product = +25
        apply_inputs( -8'd8,  -8'd10 );  // product = +80
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC5 — Zero Inputs (accumulator must NOT change)
        //
        // With a=0 or b=0, the product is zero, so acc must stay constant.
        // ===================================================================
        $display("\n--- TC5: Zero Inputs (acc must stay unchanged) ---");
        test_num = 5;
        // Seed a known value first
        apply_inputs( 8'd10, 8'd10 );   // stage1=100
        apply_inputs( 8'd0,  8'd0  );   // stage1=0, acc+=100
        apply_inputs( 8'd0,  8'd99 );   // stage1=0, acc+=0 (unchanged)
        apply_inputs( 8'd99, 8'd0  );   // stage1=0, acc+=0 (unchanged)
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC6 — Independence check
        //
        // Verify that acc matches exactly the pipelined reference
        // (NOT the single-MAC reference that is 1 product ahead).
        // This catches any implementation that accidentally registers
        // the output combinationally instead of sequentially.
        // ===================================================================
        $display("\n--- TC6: Pipeline Register Independence Check ---");
        test_num = 6;
        // After reset, drive exactly 1 pair and check that acc is still 0
        // (product is in stage1, not yet in acc — first acc update comes
        //  on the SECOND cycle)
        apply_inputs( 8'd5, 8'd5 );  // stage1=25, acc=0 (not 25!)
        $display("  [INFO] After 1 cycle: acc should be 0, not 25 (product still in stage1)");
        if (acc !== {ACC_WIDTH{1'b0}}) begin
            $display("  [FAIL] TC6 | acc should be 0 after first cycle, got %0d", $signed(acc));
            error_count = error_count + 1;
        end else begin
            $display("  [PASS] TC6 | acc = 0 correctly — product is in stage1, not acc yet");
        end
        apply_inputs( 8'd3, 8'd3 );  // stage1=9, acc=25 (stage1 drains into acc)
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC7 — Maximum Positive Boundary
        //
        // 8-bit signed max = 127.  127 × 127 = 16129.
        // ===================================================================
        $display("\n--- TC7: Maximum Positive Boundary (127 x 127) ---");
        test_num = 7;
        apply_inputs( 8'd127, 8'd127 );  // product = 16129
        flush_pipeline;                  // acc = 16129
        do_reset;

        // ===================================================================
        // TC8 — Most-Negative Inputs
        //
        // -128 × -128 = 16384 (positive, fits in 17-bit signed acc)
        // -128 × +127 = -16256
        // ===================================================================
        $display("\n--- TC8: Most-Negative Inputs ---");
        test_num = 8;
        apply_inputs( -8'd128, -8'd128 );  // product = +16384
        apply_inputs( -8'd128,  8'd127 );  // product = -16256
        flush_pipeline;                    // acc = 16384 + (-16256) = 128
        do_reset;

        // ===================================================================
        // TC9 — Mid-run Reset
        //
        // Both pipeline registers must clear, not just acc.
        // ===================================================================
        check_mid_reset;

        // ===================================================================
        // TC10 — Pipeline Latency Demonstration
        //
        // Explicit cycle-by-cycle trace to prove 1-cycle latency.
        // Shows that acc is always exactly 1 product behind the inputs.
        //
        // Expected behaviour:
        //   Cycle 1: Stage1=A0*B0=3  acc=0        (stage1 filling, acc still 0)
        //   Cycle 2: Stage1=A1*B1=8  acc=3         (A0*B0 drains into acc)
        //   Cycle 3: Stage1=A2*B2=15 acc=3+8=11    (A1*B1 drains into acc)
        //   flush:   Stage1=0        acc=11+15=26  (A2*B2 drains into acc)
        // ===================================================================
        $display("\n--- TC10: Pipeline Latency Demonstration ---");
        test_num = 10;
        $display("  [INFO] Driving 3 pairs: (1,3)=3  (2,4)=8  (3,5)=15");
        $display("  [INFO] Due to 1-cycle latency, acc lags by one product each cycle.");
        apply_inputs( 8'd1, 8'd3 );   // product=3,  acc=0  (not 3 yet)
        apply_inputs( 8'd2, 8'd4 );   // product=8,  acc=3
        apply_inputs( 8'd3, 8'd5 );   // product=15, acc=3+8=11
        flush_pipeline;               // product=0,  acc=11+15=26 ← complete
        $display("  [INFO] Final acc=26 = 3+8+15 (all three products accumulated after flush)");
        do_reset;

        // ===================================================================
        // TC11 — Pipeline Flush Correctness
        //
        // Verify that without a flush, the last product is NOT in acc,
        // and that after a flush it IS included. This is the key architectural
        // difference from a non-pipelined MAC.
        // ===================================================================
        $display("\n--- TC11: Pipeline Flush Correctness ---");
        test_num = 11;
        apply_inputs( 8'd4, 8'd4 );   // product=16, acc=0 (16 is in stage1)
        // At this point, 16 is in stage1 but NOT in acc.
        // Reference model confirms: acc should still be 0.
        $display("  [INFO] Without flush: acc=%0d (last product still in stage1)",
                 $signed(acc));
        flush_pipeline;               // acc = 0 + 16 = 16
        $display("  [INFO] After flush:   acc=%0d (last product now drained)", $signed(acc));
        do_reset;

        // ===================================================================
        // TC12 — Long Accumulation Run (50 cycles)
        //
        // Reference model is verified every cycle.
        // Inputs are deterministic but varying within signed 8-bit range.
        // ===================================================================
        $display("\n--- TC12: Long Accumulation Run (50 cycles) ---");
        test_num = 12;
        for (i = 0; i < 50; i = i + 1) begin
            apply_inputs(
                $signed(i[7:0] % 10),
                $signed((i[7:0] + 1) % 10)
            );
        end
        flush_pipeline;

        // ===================================================================
        // Final Summary
        // ===================================================================
        $display("\n================================================================");
        if (error_count == 0) begin
            $display("  RESULT : ALL TESTS PASSED (0 errors)");
        end else begin
            $display("  RESULT : FAILED — %0d error(s) detected", error_count);
        end
        $display("================================================================\n");

        $finish;
    end

    // -----------------------------------------------------------------------
    // Timeout Watchdog — kill simulation if it hangs
    // -----------------------------------------------------------------------
    initial begin
        #200000;
        $display("[WATCHDOG] Simulation exceeded time limit. Terminating.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform Dump (for Vivado / ModelSim / iVerilog / VCS)
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("pipelined_mac_tb.vcd");
        $dumpvars(0, pipelined_mac_tb);
    end

endmodule
