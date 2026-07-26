`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 05 - MAC Array
// Module  : mac_array_tb (Self-Checking Testbench)
// Author  : Gayathri Satheesh
//
// Description:
// Self-checking testbench for the mac_array module.
//
// ─── Verification Strategy ───────────────────────────────────────────────────
//
// A software reference model runs NUM_PES independent 2-stage pipeline
// mirrors in parallel — one per PE. All PE models update simultaneously on
// every clock edge, exactly as the hardware does.
//
// Per-PE reference state:
//   ref_stage1[i]  — mirrors PE[i]'s product_reg inside pipelined_mac
//   ref_acc[i]     — mirrors PE[i]'s accumulator
//   ref_w[i]       — mirrors PE[i]'s w_reg
//
// Reference model update (all PEs, simultaneously each clock edge):
//   new_acc[i]    = ref_acc[i] + ref_stage1[i]         // Stage 2
//   new_stage1[i] = a_in × ref_w[i]                    // Stage 1, OLD w_reg
//   new_w[i]      = load_weight ? weight[i] : ref_w[i] // weight latch
//   commit all
//
// ─── Extracting individual PE acc from the packed bus ─────────────────────────
//
//   acc_out[(i+1)*ACC_WIDTH-1 : i*ACC_WIDTH]  →  PE[i] accumulator
//
// ─── Test Cases Covered ──────────────────────────────────────────────────────
//   TC1  - Synchronous reset (all PE accs and a_out clear)
//   TC2  - Parallel weight load (all PEs loaded simultaneously)
//   TC3  - Independent accumulation (each PE has a different weight →
//           acc values must diverge correctly over time)
//   TC4  - Weight hold (weights persist across many cycles without reload)
//   TC5  - Weight load timing (new weight takes 1 cycle to reach product_reg)
//   TC6  - Zero activation (no PE acc should change)
//   TC7  - Zero weight on one PE (that PE's acc must stay at 0)
//   TC8  - Negative weights (mixed positive and negative products)
//   TC9  - Boundary values (127×127, -128×-128 on selected PEs)
//   TC10 - Mid-stream weight change on all PEs simultaneously
//   TC11 - Mid-run reset (all PE pipeline registers clear)
//   TC12 - a_out forwarding (equals a_in delayed 1 cycle from last PE)
//   TC13 - Long accumulation (50 cycles, reference model checked every cycle)
//
// ─── Parameters ──────────────────────────────────────────────────────────────
//   NUM_PES    = 4
//   DATA_WIDTH = 8
//   ACC_WIDTH  = (2*DATA_WIDTH)+1 = 17
//
//////////////////////////////////////////////////////////////////////////////////

module mac_array_tb;

    // -----------------------------------------------------------------------
    // Parameters — mirror the DUT
    // -----------------------------------------------------------------------
    localparam NUM_PES    = 4;
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = (2 * DATA_WIDTH) + 1;   // 17 bits per PE

    localparam CLK_PERIOD = 10;   // 10 ns → 100 MHz

    // -----------------------------------------------------------------------
    // DUT Port Declarations
    // -----------------------------------------------------------------------
    reg                                       clk;
    reg                                       rst;
    reg  signed [DATA_WIDTH-1:0]              a_in;
    reg                                       load_weight;
    reg  signed [NUM_PES*DATA_WIDTH-1:0]      weight_in;

    wire signed [NUM_PES*ACC_WIDTH-1:0]       acc_out;
    wire signed [DATA_WIDTH-1:0]              a_out;

    // -----------------------------------------------------------------------
    // Reference Model — NUM_PES independent 2-stage pipeline mirrors
    // -----------------------------------------------------------------------
    integer ref_w      [0:NUM_PES-1];    // mirrors w_reg in each PE
    integer ref_stage1 [0:NUM_PES-1];    // mirrors product_reg in each PE's MAC
    integer ref_acc    [0:NUM_PES-1];    // mirrors acc in each PE's MAC
    integer ref_a_out;                   // mirrors array a_out (last PE forwarding)

    // Temporaries for simultaneous update
    integer new_w      [0:NUM_PES-1];
    integer new_stage1 [0:NUM_PES-1];
    integer new_acc    [0:NUM_PES-1];

    // -----------------------------------------------------------------------
    // Helpers — extract individual PE acc and weight slices
    // -----------------------------------------------------------------------
    // acc_out[(i+1)*ACC_WIDTH-1 : i*ACC_WIDTH]  for PE[i]
    // These functions are replaced with inline expressions in the tasks below.

    // -----------------------------------------------------------------------
    // Error counter and test label
    // -----------------------------------------------------------------------
    integer error_count;
    integer test_num;

    // -----------------------------------------------------------------------
    // DUT Instantiation
    // -----------------------------------------------------------------------
    mac_array #(
        .NUM_PES    (NUM_PES),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .a_in        (a_in),
        .load_weight (load_weight),
        .weight_in   (weight_in),
        .acc_out     (acc_out),
        .a_out       (a_out)
    );

    // -----------------------------------------------------------------------
    // Clock Generation
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: set_weights
    //
    // Helper to pack 4 individual signed weight values into the weight_in bus.
    // weight_in[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH] = W[i]
    // -----------------------------------------------------------------------
    task set_weights;
        input signed [DATA_WIDTH-1:0] w0, w1, w2, w3;
        begin
            weight_in[1*DATA_WIDTH-1 : 0*DATA_WIDTH] = w0;
            weight_in[2*DATA_WIDTH-1 : 1*DATA_WIDTH] = w1;
            weight_in[3*DATA_WIDTH-1 : 2*DATA_WIDTH] = w2;
            weight_in[4*DATA_WIDTH-1 : 3*DATA_WIDTH] = w3;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: apply_inputs
    //
    // Drives a_in and load_weight/weight_in for one clock cycle.
    // Updates all NUM_PES reference model lanes simultaneously, then checks
    // every PE's acc_out slice and the array a_out.
    //
    // Simultaneous update rule (same as processing_element_tb):
    //   new_acc[i]    = ref_acc[i] + ref_stage1[i]   // Stage 2: OLD stage1
    //   new_stage1[i] = a_in × ref_w[i]              // Stage 1: OLD w_reg
    //   new_w[i]      = load_weight ? W[i] : ref_w[i]
    //   new_a_out     = a_in
    // -----------------------------------------------------------------------
    integer k;   // loop variable for apply_inputs

    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a;
        input                         in_load;
        input signed [DATA_WIDTH-1:0] w0, w1, w2, w3;
        begin
            // Drive DUT
            a_in        = in_a;
            load_weight = in_load;
            set_weights(w0, w1, w2, w3);

            @(posedge clk);
            #1;

            // ── Reference model: compute all new values with OLD state ──
            for (k = 0; k < NUM_PES; k = k + 1) begin
                new_acc[k]    = ref_acc[k] + ref_stage1[k];
                new_stage1[k] = $signed(in_a) * ref_w[k];
            end
            new_w[0] = in_load ? $signed(w0) : ref_w[0];
            new_w[1] = in_load ? $signed(w1) : ref_w[1];
            new_w[2] = in_load ? $signed(w2) : ref_w[2];
            new_w[3] = in_load ? $signed(w3) : ref_w[3];

            // Commit
            for (k = 0; k < NUM_PES; k = k + 1) begin
                ref_acc[k]    = new_acc[k];
                ref_stage1[k] = new_stage1[k];
                ref_w[k]      = new_w[k];
            end
            ref_a_out = $signed(in_a);
            // ────────────────────────────────────────────────────────────

            // ── Check every PE's acc ─────────────────────────────────────
            for (k = 0; k < NUM_PES; k = k + 1) begin
                if ($signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]) !==
                    ref_acc[k][ACC_WIDTH-1:0]) begin
                    $display("  [FAIL] t=%0t | TC%0d | PE[%0d] acc: got %0d, expected %0d  (a=%0d, w=%0d)",
                             $time, test_num, k,
                             $signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]),
                             ref_acc[k],
                             $signed(in_a), ref_w[k]);
                    error_count = error_count + 1;
                end else begin
                    $display("  [PASS] t=%0t | TC%0d | PE[%0d] acc=%0d  (a=%0d, w_reg=%0d, stg1=%0d)",
                             $time, test_num, k,
                             $signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]),
                             $signed(in_a), ref_w[k], ref_stage1[k]);
                end
            end

            // ── Check array a_out (last PE forwarding) ───────────────────
            if ($signed(a_out) !== ref_a_out[DATA_WIDTH-1:0]) begin
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
    // One extra zero-activation cycle to drain the last product_reg values
    // from all PEs into their accumulators. Same architectural requirement
    // as pipelined_mac_tb and processing_element_tb.
    // -----------------------------------------------------------------------
    task flush_pipeline;
        begin
            $display("  [FLUSH] Draining pipeline (a_in=0, load_weight=0)");
            apply_inputs(0, 0, 0, 0, 0, 0);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: do_reset
    // -----------------------------------------------------------------------
    task do_reset;
        integer j;
        begin
            load_weight = 0;
            weight_in   = 0;
            a_in        = 0;
            rst = 1;
            @(posedge clk); #1;
            @(posedge clk); #1;

            for (j = 0; j < NUM_PES; j = j + 1) begin
                ref_w[j]      = 0;
                ref_stage1[j] = 0;
                ref_acc[j]    = 0;
            end
            ref_a_out = 0;

            // Check all PE accs are zero
            for (j = 0; j < NUM_PES; j = j + 1) begin
                if (acc_out[((j+1)*ACC_WIDTH)-1 -: ACC_WIDTH] !== {ACC_WIDTH{1'b0}}) begin
                    $display("  [FAIL] t=%0t | RESET | PE[%0d] acc not zero: %0d",
                             $time, j,
                             $signed(acc_out[((j+1)*ACC_WIDTH)-1 -: ACC_WIDTH]));
                    error_count = error_count + 1;
                end else begin
                    $display("  [PASS] t=%0t | RESET | PE[%0d] acc = 0", $time, j);
                end
            end

            // Check a_out is zero
            if (a_out !== {DATA_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | a_out not zero: %0d",
                         $time, $signed(a_out));
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
        a_in = 0; load_weight = 0; weight_in = 0;
        for (i = 0; i < NUM_PES; i = i + 1) begin
            ref_w[i] = 0; ref_stage1[i] = 0; ref_acc[i] = 0;
        end
        ref_a_out = 0;

        $display("================================================================");
        $display("  Self-Checking Testbench : mac_array");
        $display("  NUM_PES=%0d  DATA_WIDTH=%0d  ACC_WIDTH=%0d",
                 NUM_PES, DATA_WIDTH, ACC_WIDTH);
        $display("================================================================");

        // ===================================================================
        // TC1 — Synchronous Reset
        //
        // All PE accumulators and the array a_out must clear to zero.
        // ===================================================================
        $display("\n--- TC1: Synchronous Reset ---");
        test_num = 1;
        do_reset;

        // ===================================================================
        // TC2 — Parallel Weight Load
        //
        // Load W = {1, 2, 3, 4} to PE[0..3] simultaneously.
        // Verify the load takes effect (checked via acc evolution in TC3).
        // ===================================================================
        $display("\n--- TC2: Parallel Weight Load (W = {1,2,3,4}) ---");
        test_num = 2;
        apply_inputs(8'd0, 1'b1, 8'd1, 8'd2, 8'd3, 8'd4);   // load cycle
        $display("  [INFO] Weights loaded: PE0=1 PE1=2 PE2=3 PE3=4");
        do_reset;

        // ===================================================================
        // TC3 — Independent Accumulation
        //
        // Load different weights, stream the same activation every cycle.
        // Each PE accumulates a different running total. After N cycles:
        //   acc[i] = N × (a × W[i])
        //
        // Weights: W = {2, 3, 5, 7}  (prime weights for easy manual check)
        // Activation: a = 4 every cycle, 4 cycles + flush
        //
        //   PE[0]: 4×2=8  per cycle  → total = 32
        //   PE[1]: 4×3=12 per cycle  → total = 48
        //   PE[2]: 4×5=20 per cycle  → total = 80
        //   PE[3]: 4×7=28 per cycle  → total = 112
        // (cycle 1 product is zero due to load-timing, so actual total shown
        //  by reference model will differ by one cycle — see TC5 for detail)
        // ===================================================================
        $display("\n--- TC3: Independent Accumulation (W={2,3,5,7}, a=4, 4 cycles) ---");
        test_num = 3;
        apply_inputs(8'd4, 1'b1, 8'd2, 8'd3, 8'd5, 8'd7);   // load + stream
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] PE accs should diverge: each PE has different weight");
        do_reset;

        // ===================================================================
        // TC4 — Weight Hold
        //
        // Verify all PEs hold their weights for many cycles without reload.
        // A PE that loses its weight would produce zeros after a few cycles.
        // ===================================================================
        $display("\n--- TC4: Weight Hold (load once, stream 6 cycles) ---");
        test_num = 4;
        apply_inputs(8'd1, 1'b1, 8'd3, 8'd6, 8'd9, 8'd12);   // load
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] Weights held for 6 cycles without reload");
        do_reset;

        // ===================================================================
        // TC5 — Weight Load Timing (explicit 1-cycle delay)
        //
        // At the load cycle, product_reg still uses OLD w_reg (= 0 after reset).
        // New weight only reaches product_reg on the NEXT cycle.
        // This test makes the timing explicit and verifies the reference model.
        // ===================================================================
        $display("\n--- TC5: Weight Load Timing (1-cycle delay from load to product_reg) ---");
        test_num = 5;
        apply_inputs(8'd10, 1'b1, 8'd2, 8'd2, 8'd2, 8'd2);  // LOAD: product uses OLD w=0
        $display("  [INFO] Load cycle: all product_regs = 10×0 = 0 (OLD weight)");
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // product = 10×2=20
        $display("  [INFO] Next cycle: product_regs = 10×2 = 20 (NEW weight active)");
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // acc = 0 + 0 = 0 (first to drain is 0)
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC6 — Zero Activation
        //
        // a_in = 0: all products must be zero, no PE acc should change.
        // ===================================================================
        $display("\n--- TC6: Zero Activation (no PE acc should change) ---");
        test_num = 6;
        apply_inputs(8'd5,  1'b1, 8'd4, 8'd4, 8'd4, 8'd4);  // load W=4, seed pipeline
        apply_inputs(8'd5,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // real cycle
        apply_inputs(8'd0,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // a=0, products=0
        apply_inputs(8'd0,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // a=0, products=0
        apply_inputs(8'd5,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // resume
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC7 — Zero Weight on One PE
        //
        // PE[0] loaded with W=0, others with W=3.
        // PE[0] acc must remain 0 regardless of a_in.
        // ===================================================================
        $display("\n--- TC7: Zero Weight on PE[0] (PE[0] acc must stay 0) ---");
        test_num = 7;
        apply_inputs(8'd9, 1'b1, 8'd0, 8'd3, 8'd3, 8'd3);   // PE[0] W=0, others W=3
        apply_inputs(8'd9, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd9, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd9, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] PE[0] acc must be 0; PE[1..3] accs must be non-zero");
        do_reset;

        // ===================================================================
        // TC8 — Negative Weights (mixed products)
        //
        // W = {2, -2, 3, -3}
        // Positive activations → PE[0] and PE[2] accumulate positively,
        //                        PE[1] and PE[3] accumulate negatively.
        // ===================================================================
        $display("\n--- TC8: Negative Weights (W={2,-2,3,-3}, a=5) ---");
        test_num = 8;
        apply_inputs(8'd5, 1'b1,  8'd2, -8'd2,  8'd3, -8'd3);
        apply_inputs(8'd5, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        apply_inputs(8'd5, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        apply_inputs(8'd5, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        flush_pipeline;
        $display("  [INFO] PE[0] and PE[2] should be positive, PE[1] and PE[3] negative");
        do_reset;

        // ===================================================================
        // TC9 — Boundary Values
        //
        // PE[0]: a=127, W=127   → product = 16129 (max positive)
        // PE[1]: a=-128, W=-128 → product = 16384 (most-negative × most-negative)
        // PE[2]: a=127, W=-128  → product = -16256
        // PE[3]: a=-128, W=127  → product = -16256
        // ===================================================================
        $display("\n--- TC9: Boundary Values ---");
        test_num = 9;
        apply_inputs( 8'd127, 1'b1,  8'd127, -8'd128,  8'd127, -8'd128);  // load
        apply_inputs(-8'd128, 1'b0,  8'd0,    8'd0,    8'd0,    8'd0  );  // use boundary a
        // Note: each PE sees same a_in, so adjust expectations accordingly
        // PE[0]: 127×127, PE[1]: 127×(-128), PE[2]: (-128)×127, PE[3]: (-128)×(-128)
        // (load cycle used 127 for a_in, so product_reg uses 127×W[i])
        // second cycle uses -128 for a_in
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC10 — Mid-stream Weight Change on All PEs
        //
        // Accumulate 3 cycles with W={1,2,3,4}, then change to W={5,6,7,8}.
        // Reference model handles the transition correctly.
        // ===================================================================
        $display("\n--- TC10: Mid-stream Weight Change ---");
        test_num = 10;
        apply_inputs(8'd3, 1'b1, 8'd1, 8'd2, 8'd3, 8'd4);   // load W1
        apply_inputs(8'd3, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd3, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd3, 1'b1, 8'd5, 8'd6, 8'd7, 8'd8);   // CHANGE to W2
        apply_inputs(8'd3, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd3, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] acc values reflect mix of products from W1 and W2 phases");
        do_reset;

        // ===================================================================
        // TC11 — Mid-run Reset
        //
        // Build up state in all PEs, then assert reset mid-run.
        // All pipeline registers in all PEs must clear simultaneously.
        // ===================================================================
        $display("\n--- TC11: Mid-run Reset (all PE pipeline registers must clear) ---");
        test_num = 11;
        apply_inputs(8'd6, 1'b1, 8'd2, 8'd3, 8'd4, 8'd5);
        apply_inputs(8'd6, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd6, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);

        rst = 1;
        @(posedge clk); #1;

        for (i = 0; i < NUM_PES; i = i + 1) begin
            ref_w[i] = 0; ref_stage1[i] = 0; ref_acc[i] = 0;
        end
        ref_a_out = 0;

        for (i = 0; i < NUM_PES; i = i + 1) begin
            if (acc_out[((i+1)*ACC_WIDTH)-1 -: ACC_WIDTH] !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | TC11 | PE[%0d] acc not zero after mid-reset: %0d",
                         $time, i,
                         $signed(acc_out[((i+1)*ACC_WIDTH)-1 -: ACC_WIDTH]));
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC11 | PE[%0d] acc = 0 after mid-reset", $time, i);
            end
        end

        rst = 0;

        // ===================================================================
        // TC12 — a_out Forwarding (array-level)
        //
        // a_out of the array is the last PE's forwarding register.
        // In broadcast mode it equals a_in delayed by exactly 1 cycle.
        // ===================================================================
        $display("\n--- TC12: Array a_out Forwarding (last PE, 1-cycle delay) ---");
        test_num = 12;
        $display("  [INFO] Driving a_in = 10,20,30,40. a_out should follow 1 cycle later.");
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);   // a_out = 0 (reset)
        apply_inputs(8'd20, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);   // a_out = 10
        apply_inputs(8'd30, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);   // a_out = 20
        apply_inputs(8'd40, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);   // a_out = 30
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC13 — Long Accumulation with Stable Weights (50 cycles)
        //
        // Load W={1,2,4,8} once. Stream 50 signed activations.
        // Reference model checks all 4 PE accs every cycle.
        // ===================================================================
        $display("\n--- TC13: Long Accumulation (W={1,2,4,8}, 50 cycles) ---");
        test_num = 13;
        apply_inputs(8'd1, 1'b1, 8'd1, 8'd2, 8'd4, 8'd8);   // load weights

        for (i = 0; i < 49; i = i + 1) begin
            apply_inputs(
                $signed(((i % 10) - 5)),   // activations cycle -5 to +4
                1'b0,
                8'd0, 8'd0, 8'd0, 8'd0
            );
        end
        flush_pipeline;

        // ===================================================================
        // Final Summary
        // ===================================================================
        $display("\n================================================================");
        if (error_count == 0)
            $display("  RESULT : ALL TESTS PASSED (0 errors)");
        else
            $display("  RESULT : FAILED — %0d error(s) detected", error_count);
        $display("================================================================\n");

        $finish;
    end

    // -----------------------------------------------------------------------
    // Timeout Watchdog
    // -----------------------------------------------------------------------
    initial begin
        #300000;
        $display("[WATCHDOG] Simulation exceeded time limit. Terminating.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform Dump (Vivado XSim / ModelSim / iVerilog / VCS)
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("mac_array_tb.vcd");
        $dumpvars(0, mac_array_tb);
    end

endmodule
