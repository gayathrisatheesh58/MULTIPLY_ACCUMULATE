`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 04 - Processing Element (PE)
// Module  : processing_element_tb (Self-Checking Testbench)
// Author  : Gayathri Satheesh
//
// Description:
// Self-checking testbench for the processing_element module.
//
// ─── Verification Strategy ───────────────────────────────────────────────────
//
// A software reference model mirrors ALL four registers of the PE simultaneously
// on every clock edge (just as the hardware does):
//
//   Register         │ What it models
//   ─────────────────┼───────────────────────────────────────────────────────
//   ref_w_reg        │ Local weight register inside PE
//   ref_a_out        │ Forwarding register (a_in delayed 1 cycle)
//   ref_stage1       │ product_reg inside pipelined_mac
//   ref_acc          │ Accumulator inside pipelined_mac
//
// Critical: all four update SIMULTANEOUSLY on each clock edge.
// The reference model must compute all "new_*" values using the OLD register
// states before writing any of them back. Failure to do this produces wrong
// expected values, especially for weight loading (w_reg update and its effect
// on product_reg happen 1 cycle apart).
//
// Reference model update sequence (mirrors hardware exactly):
//   new_w_reg   = load_weight ? weight_in : ref_w_reg
//   new_a_out   = a_in
//   new_stage1  = a_in * ref_w_reg        ← OLD w_reg (before load takes effect)
//   new_acc     = ref_acc + ref_stage1    ← OLD stage1 (Stage 2 of MAC)
//   ── then commit all at once ──
//   ref_w_reg   = new_w_reg
//   ref_a_out   = new_a_out
//   ref_stage1  = new_stage1
//   ref_acc     = new_acc
//
// ─── Weight Load Timing ───────────────────────────────────────────────────────
//
// load_weight=1 at edge N  →  w_reg = weight_in AFTER edge N
// w_reg first used by product_reg at edge N+1
// Effect first appears in acc at edge N+2
//
// Example (W=5, a_in=3 every cycle):
//   Cycle │ load_w │ w_in │ a_in │ w_reg │ product_reg │ acc
//   ──────┼────────┼──────┼──────┼───────┼─────────────┼────
//     1   │   1    │  5   │  3   │  0→5  │  3×0 = 0    │  0    ← load, old w_reg=0
//     2   │   0    │  —   │  3   │   5   │  3×5 = 15   │  0    ← first cycle using W
//     3   │   0    │  —   │  3   │   5   │  3×5 = 15   │  15   ← first acc update
//     4   │   0    │  —   │  3   │   5   │  3×5 = 15   │  30
//
// ─── Test Cases Covered ──────────────────────────────────────────────────────
//   TC1  - Synchronous reset (w_reg, product_reg, acc, a_out all clear)
//   TC2  - Weight load and basic accumulation (positive × positive)
//   TC3  - Weight hold — w_reg retains value after load_weight deasserts
//   TC4  - Weight load timing — new weight takes 1 cycle to reach product_reg
//   TC5  - Positive × Negative weight
//   TC6  - Negative × Negative weight (product is positive)
//   TC7  - Zero activation — acc must not change
//   TC8  - Zero weight (after load) — acc must not change regardless of a_in
//   TC9  - Data forwarding correctness — a_out = a_in delayed 1 cycle
//   TC10 - Mid-stream weight change — verify acc transitions to new weight
//   TC11 - Boundary values (127 × 127, -128 × -128)
//   TC12 - Mid-run reset — all registers including internal MAC pipeline clear
//   TC13 - Long accumulation with stable weight (50 cycles, reference model checks each)
//
// ─── Parameters ──────────────────────────────────────────────────────────────
//   DATA_WIDTH = 8
//   ACC_WIDTH  = (2*DATA_WIDTH)+1 = 17
//
//////////////////////////////////////////////////////////////////////////////////

module processing_element_tb;

    // -----------------------------------------------------------------------
    // Parameters — mirror the DUT
    // -----------------------------------------------------------------------
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = (2 * DATA_WIDTH) + 1;   // 17 bits

    localparam CLK_PERIOD = 10;   // 10 ns → 100 MHz

    // -----------------------------------------------------------------------
    // DUT Port Declarations
    // -----------------------------------------------------------------------
    reg                          clk;
    reg                          rst;
    reg                          load_weight;
    reg  signed [DATA_WIDTH-1:0] weight_in;
    reg  signed [DATA_WIDTH-1:0] a_in;

    wire signed [DATA_WIDTH-1:0] a_out;
    wire signed [ACC_WIDTH-1:0]  acc;

    // -----------------------------------------------------------------------
    // Reference Model — mirrors all four PE registers
    //
    // 64-bit integers avoid overflow; DUT is compared against truncated slices.
    // -----------------------------------------------------------------------
    integer ref_w_reg;     // mirrors w_reg
    integer ref_a_out;     // mirrors a_out (forwarding register)
    integer ref_stage1;    // mirrors product_reg inside pipelined_mac
    integer ref_acc;       // mirrors acc

    // Temporaries for simultaneous update (must compute with OLD values first)
    integer new_w_reg;
    integer new_a_out;
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
    processing_element #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .load_weight (load_weight),
        .weight_in   (weight_in),
        .a_in        (a_in),
        .a_out       (a_out),
        .acc         (acc)
    );

    // -----------------------------------------------------------------------
    // Clock Generation
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: apply_inputs
    //
    // Drives all PE inputs for one clock cycle and advances the full 4-register
    // reference model simultaneously — exactly as the hardware does.
    //
    // Weight load timing note:
    //   new_stage1 = in_a * ref_w_reg  ← uses OLD w_reg (before load takes effect)
    //   This correctly models that a new weight takes 1 cycle to reach product_reg.
    // -----------------------------------------------------------------------
    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a;
        input                         in_load_weight;
        input signed [DATA_WIDTH-1:0] in_weight_in;
        begin
            // Drive DUT inputs
            a_in        = in_a;
            load_weight = in_load_weight;
            weight_in   = in_weight_in;

            // Wait for rising clock edge
            @(posedge clk);
            #1;   // small delta — sample registered outputs after clk edge

            // ── Reference model: all registers update simultaneously ──────
            // Compute new values with OLD state before committing any.
            new_w_reg  = in_load_weight ? $signed(in_weight_in) : ref_w_reg;
            new_a_out  = $signed(in_a);
            new_stage1 = $signed(in_a) * ref_w_reg;    // OLD w_reg
            new_acc    = ref_acc + ref_stage1;          // OLD stage1 (Stage 2)

            // Commit
            ref_w_reg  = new_w_reg;
            ref_a_out  = new_a_out;
            ref_stage1 = new_stage1;
            ref_acc    = new_acc;
            // ─────────────────────────────────────────────────────────────

            // ── Check acc ────────────────────────────────────────────────
            if (acc !== ref_acc[ACC_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | acc: got %0d, expected %0d  (a=%0d, w_reg=%0d)",
                         $time, test_num, $signed(acc), ref_acc,
                         $signed(in_a), ref_w_reg);
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | acc=%0d  (a=%0d, w_reg=%0d, stg1=%0d)",
                         $time, test_num, $signed(acc),
                         $signed(in_a), ref_w_reg, ref_stage1);
            end

            // ── Check a_out ───────────────────────────────────────────────
            if (a_out !== ref_a_out[DATA_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | a_out: got %0d, expected %0d",
                         $time, test_num, $signed(a_out), ref_a_out);
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | a_out=%0d  (a_in was %0d)",
                         $time, test_num, $signed(a_out), $signed(in_a));
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: flush_pipeline
    //
    // Drives one extra zero cycle to drain the last product_reg into acc.
    // Required after the final real input to see the complete accumulated sum.
    // (Same architectural requirement as in pipelined_mac_tb.)
    // -----------------------------------------------------------------------
    task flush_pipeline;
        begin
            $display("  [FLUSH] Draining pipeline — 1 extra cycle with a_in=0, load_weight=0");
            apply_inputs(0, 0, 0);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: do_reset
    //   Applies synchronous reset for 2 cycles, releases, verifies all
    //   PE outputs (acc and a_out) are zero.
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            load_weight = 0;
            weight_in   = 0;
            a_in        = 0;
            rst = 1;
            @(posedge clk); #1;
            @(posedge clk); #1;

            // Clear entire reference model
            ref_w_reg  = 0;
            ref_a_out  = 0;
            ref_stage1 = 0;
            ref_acc    = 0;

            // Check acc
            if (acc !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | acc not zero: got %0d", $time, $signed(acc));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | RESET | acc = 0", $time);
            end

            // Check a_out
            if (a_out !== {DATA_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | a_out not zero: got %0d", $time, $signed(a_out));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | RESET | a_out = 0", $time);
            end

            rst = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------------------------------
    integer i;

    initial begin
        // ── Initialise ────────────────────────────────────────────────────
        error_count = 0;
        test_num    = 0;
        clk = 0; rst = 1;
        load_weight = 0;
        weight_in   = 0;
        a_in        = 0;
        ref_w_reg   = 0;
        ref_a_out   = 0;
        ref_stage1  = 0;
        ref_acc     = 0;

        $display("================================================================");
        $display("  Self-Checking Testbench : processing_element");
        $display("  DATA_WIDTH=%0d  ACC_WIDTH=%0d", DATA_WIDTH, ACC_WIDTH);
        $display("================================================================");

        // ===================================================================
        // TC1 — Synchronous Reset
        //
        // All four registers must clear: w_reg, a_out, product_reg, acc.
        // ===================================================================
        $display("\n--- TC1: Synchronous Reset ---");
        test_num = 1;
        do_reset;

        // ===================================================================
        // TC2 — Weight Load and Basic Accumulation
        //
        // Load W=4 then stream A=3 for 4 cycles.
        // Expected dot product after flush: 4 × (3×4) = 48
        //
        // Cycle-by-cycle (w_reg=0 at start):
        //   Cycle 1: load_w=1, a=3  → w_reg=4, product_reg=3×0=0, acc=0
        //   Cycle 2: load_w=0, a=3  → w_reg=4, product_reg=3×4=12, acc=0
        //   Cycle 3: load_w=0, a=3  → w_reg=4, product_reg=12,     acc=12
        //   Cycle 4: load_w=0, a=3  → w_reg=4, product_reg=12,     acc=24
        //   Cycle 5: load_w=0, a=3  → w_reg=4, product_reg=12,     acc=36
        //   Flush  : load_w=0, a=0  → product_reg=0,               acc=48
        // ===================================================================
        $display("\n--- TC2: Weight Load and Basic Accumulation (W=4, a=3, 4 cycles) ---");
        test_num = 2;
        apply_inputs( 8'd3, 1'b1, 8'd4 );   // load W=4
        apply_inputs( 8'd3, 1'b0, 8'd0 );   // stream
        apply_inputs( 8'd3, 1'b0, 8'd0 );
        apply_inputs( 8'd3, 1'b0, 8'd0 );
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC3 — Weight Hold
        //
        // Verify w_reg retains its value for many cycles after load_weight
        // deasserts. A PE without correct weight retention would produce
        // incorrect products.
        // ===================================================================
        $display("\n--- TC3: Weight Hold (load once, stream 5 cycles) ---");
        test_num = 3;
        apply_inputs( 8'd1, 1'b1, 8'd7 );   // load W=7
        apply_inputs( 8'd2, 1'b0, 8'd0 );   // a=2, w still 7, product=7
        apply_inputs( 8'd2, 1'b0, 8'd0 );   // a=2, w still 7, product=14
        apply_inputs( 8'd2, 1'b0, 8'd0 );
        apply_inputs( 8'd2, 1'b0, 8'd0 );
        apply_inputs( 8'd2, 1'b0, 8'd0 );
        flush_pipeline;
        $display("  [INFO] If weight had leaked to 0, acc would be wrong — confirms w_reg holds");
        do_reset;

        // ===================================================================
        // TC4 — Weight Load Timing (explicit 1-cycle delay)
        //
        // The new weight takes effect in product_reg 1 cycle AFTER the load.
        // At the cycle where load_weight=1, product_reg still uses the OLD weight.
        //
        // Here we load a known weight and verify the transition cycle-by-cycle.
        // ===================================================================
        $display("\n--- TC4: Weight Load Timing (1-cycle delay from load to product_reg) ---");
        test_num = 4;
        // Start: w_reg=0 (after reset)
        apply_inputs( 8'd5, 1'b1, 8'd3 );   // LOAD cycle: product_reg = 5×0=0 (OLD w=0)
        $display("  [INFO] Load cycle: product_reg uses OLD w_reg (0), not new weight (3)");
        apply_inputs( 8'd5, 1'b0, 8'd0 );   // product_reg = 5×3=15 (NEW weight active)
        $display("  [INFO] Next cycle: product_reg now uses new weight (3) → 5×3=15");
        apply_inputs( 8'd5, 1'b0, 8'd0 );   // acc = 0+0 = 0, product_reg=15
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC5 — Positive × Negative Weight
        // ===================================================================
        $display("\n--- TC5: Positive Activation x Negative Weight ---");
        test_num = 5;
        apply_inputs( 8'd6,  1'b1, -8'd5 );   // load W=-5
        apply_inputs( 8'd6,  1'b0,  8'd0 );   // product = 6×(-5) = -30
        apply_inputs( 8'd8,  1'b0,  8'd0 );   // product = 8×(-5) = -40
        apply_inputs( 8'd10, 1'b0,  8'd0 );   // product = 10×(-5) = -50
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC6 — Negative × Negative Weight (result is positive)
        // ===================================================================
        $display("\n--- TC6: Negative Activation x Negative Weight ---");
        test_num = 6;
        apply_inputs( -8'd4, 1'b1, -8'd3 );   // load W=-3
        apply_inputs( -8'd4, 1'b0,  8'd0 );   // product = (-4)×(-3) = 12
        apply_inputs( -8'd5, 1'b0,  8'd0 );   // product = (-5)×(-3) = 15
        apply_inputs( -8'd6, 1'b0,  8'd0 );   // product = (-6)×(-3) = 18
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC7 — Zero Activation (acc must not change)
        // ===================================================================
        $display("\n--- TC7: Zero Activation (acc must stay unchanged) ---");
        test_num = 7;
        apply_inputs( 8'd1,  1'b1, 8'd9 );    // load W=9, seed pipeline
        apply_inputs( 8'd5,  1'b0, 8'd0 );    // normal cycle, acc starts building
        apply_inputs( 8'd0,  1'b0, 8'd0 );    // a=0 → product = 0×9 = 0 → acc unchanged
        apply_inputs( 8'd0,  1'b0, 8'd0 );    // a=0 → product = 0 → acc still unchanged
        apply_inputs( 8'd5,  1'b0, 8'd0 );    // resume
        flush_pipeline;
        $display("  [INFO] Cycles with a=0 should NOT advance acc");
        do_reset;

        // ===================================================================
        // TC8 — Zero Weight (acc must not change regardless of a_in)
        // ===================================================================
        $display("\n--- TC8: Zero Weight (acc must stay at 0 regardless of a_in) ---");
        test_num = 8;
        // After reset, w_reg=0. Stream any a_in — products must all be 0.
        apply_inputs( 8'd99,  1'b0, 8'd0 );   // w_reg=0, product=0
        apply_inputs( 8'd100, 1'b0, 8'd0 );
        apply_inputs( 8'd127, 1'b0, 8'd0 );
        flush_pipeline;
        $display("  [INFO] w_reg=0 after reset; all products must be 0");
        do_reset;

        // ===================================================================
        // TC9 — Data Forwarding Correctness
        //
        // a_out must equal the a_in from the PREVIOUS cycle.
        // This is the systolic chaining register — the testbench verifies it
        // independently of acc.
        //
        // Sequence: a_in = 10, 20, 30, 40, 50
        // Expected a_out =   ?, 10, 20, 30, 40 (1-cycle delay, '?' = 0 after reset)
        // ===================================================================
        $display("\n--- TC9: Data Forwarding (a_out = a_in delayed 1 cycle) ---");
        test_num = 9;
        $display("  [INFO] Driving a_in = 10,20,30,40,50. a_out should follow 1 cycle later.");
        apply_inputs( 8'd10, 1'b0, 8'd0 );   // a_out should be 0 (reset state)
        apply_inputs( 8'd20, 1'b0, 8'd0 );   // a_out should be 10
        apply_inputs( 8'd30, 1'b0, 8'd0 );   // a_out should be 20
        apply_inputs( 8'd40, 1'b0, 8'd0 );   // a_out should be 30
        apply_inputs( 8'd50, 1'b0, 8'd0 );   // a_out should be 40
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC10 — Mid-stream Weight Change
        //
        // Accumulate with W1 for 3 cycles, then change to W2 for 3 more.
        // Reference model tracks the transition correctly.
        // This is important for implementing reconfigurable PEs.
        // ===================================================================
        $display("\n--- TC10: Mid-stream Weight Change (W1=5, then W2=2) ---");
        test_num = 10;
        apply_inputs( 8'd4, 1'b1, 8'd5 );   // load W=5
        apply_inputs( 8'd4, 1'b0, 8'd0 );   // product = 4×5 = 20
        apply_inputs( 8'd4, 1'b0, 8'd0 );   // product = 20
        apply_inputs( 8'd4, 1'b1, 8'd2 );   // CHANGE weight to W=2 (transition cycle)
        apply_inputs( 8'd4, 1'b0, 8'd0 );   // product = 4×2 = 8 (new weight active)
        apply_inputs( 8'd4, 1'b0, 8'd0 );   // product = 8
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC11 — Boundary Values
        //
        // a_in = 127 (max positive 8-bit signed), w = 127 → product = 16129
        // a_in = -128 (most negative),            w = -128 → product = 16384
        // ===================================================================
        $display("\n--- TC11: Boundary Values (127×127, -128×-128) ---");
        test_num = 11;
        apply_inputs(  8'd127, 1'b1,  8'd127 );   // load W=127
        apply_inputs(  8'd127, 1'b0,  8'd0   );   // product = 16129
        flush_pipeline;
        do_reset;

        apply_inputs( -8'd128, 1'b1, -8'd128 );   // load W=-128
        apply_inputs( -8'd128, 1'b0,  8'd0   );   // product = 16384
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC12 — Mid-run Reset
        //
        // Build up state in all four registers, then assert reset.
        // w_reg, a_out, product_reg, and acc must ALL clear simultaneously.
        // ===================================================================
        $display("\n--- TC12: Mid-run Reset (all PE registers must clear) ---");
        test_num = 12;
        apply_inputs( 8'd5, 1'b1, 8'd3 );   // load W=3, build state
        apply_inputs( 8'd5, 1'b0, 8'd0 );
        apply_inputs( 8'd5, 1'b0, 8'd0 );

        // Assert reset mid-run
        rst = 1;
        @(posedge clk); #1;

        ref_w_reg  = 0;
        ref_a_out  = 0;
        ref_stage1 = 0;
        ref_acc    = 0;

        if (acc !== {ACC_WIDTH{1'b0}}) begin
            $display("  [FAIL] t=%0t | TC12 | acc not zero after mid-reset: %0d",
                     $time, $signed(acc));
            error_count = error_count + 1;
        end else begin
            $display("  [PASS] t=%0t | TC12 | acc = 0 after mid-reset", $time);
        end

        if (a_out !== {DATA_WIDTH{1'b0}}) begin
            $display("  [FAIL] t=%0t | TC12 | a_out not zero after mid-reset: %0d",
                     $time, $signed(a_out));
            error_count = error_count + 1;
        end else begin
            $display("  [PASS] t=%0t | TC12 | a_out = 0 after mid-reset", $time);
        end

        rst = 0;

        // ===================================================================
        // TC13 — Long Accumulation with Stable Weight (50 cycles)
        //
        // Load W=6 once. Stream 50 deterministic activations.
        // Reference model verifies acc and a_out every cycle.
        // ===================================================================
        $display("\n--- TC13: Long Accumulation with Stable Weight (W=6, 50 cycles) ---");
        test_num = 13;
        // Load weight
        apply_inputs( 8'd1, 1'b1, 8'd6 );   // load W=6

        for (i = 0; i < 49; i = i + 1) begin
            // Activations cycle through -5..+4 deterministically
            apply_inputs(
                $signed(((i % 10) - 5)),   // range -5 to +4
                1'b0,
                8'd0
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
    // Timeout Watchdog
    // -----------------------------------------------------------------------
    initial begin
        #200000;
        $display("[WATCHDOG] Simulation exceeded time limit. Terminating.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform Dump (Vivado / ModelSim / iVerilog / VCS)
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("processing_element_tb.vcd");
        $dumpvars(0, processing_element_tb);
    end

endmodule
