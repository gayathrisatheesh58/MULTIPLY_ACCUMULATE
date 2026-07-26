`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 06 - Systolic Array
// Module  : systolic_array_tb (Self-Checking Testbench)
// Author  : Gayathri Satheesh
//
// Description:
// Self-checking testbench for the systolic_array module.
//
// ─── Verification Strategy ────────────────────────────────────────────────────
//
// The reference model maintains four state arrays (one entry per PE):
//
//   ref_chain [0:NUM_PES-1]  — what each PE is currently seeing as a_in
//   ref_w     [0:NUM_PES-1]  — each PE's local weight register
//   ref_stage1[0:NUM_PES-1]  — each PE's product_reg (inside pipelined_mac)
//   ref_acc   [0:NUM_PES-1]  — each PE's accumulator
//
// ref_chain[] is the key addition vs mac_array_tb.
//   ref_chain[0]   = current a_in (combinational, set before each clock edge)
//   ref_chain[i≥1] = value registered from PE[i-1].a_out one cycle ago
//
// Reference model update per clock edge (all simultaneous):
//   // Stage 1: uses OLD ref_chain[] and OLD ref_w[]
//   new_stage1[i] = ref_chain[i] × ref_w[i]
//
//   // Stage 2: uses OLD ref_stage1[]
//   new_acc[i]    = ref_acc[i] + ref_stage1[i]
//
//   // Weight latch
//   new_w[i]      = load_weight ? W[i] : ref_w[i]
//
//   // Chain shift (a_out registers propagate the wave)
//   new_chain[i]  = old ref_chain[i-1]   for i = NUM_PES-1 downto 1
//   new_chain[0]  = next call's in_a     (set at start of next apply_inputs)
//
// a_out check value:
//   a_out after edge = what was ref_chain[NUM_PES-1] BEFORE the shift.
//   This is saved before the chain shift and compared against the DUT.
//
// ─── Pipeline fill and drain ─────────────────────────────────────────────────
//
// Fill period  : NUM_PES-1 cycles for the wave to reach PE[NUM_PES-1]
// Drain period : NUM_PES+1 zero cycles to flush all chain and MAC stages
//
//   Total cycles for complete dot product:
//     N (input)  +  NUM_PES+1 (flush)  cycles
//     where N = length of activation vector
//
// ─── Test Cases Covered ───────────────────────────────────────────────────────
//   TC1  - Synchronous reset
//   TC2  - Single activation pulse (wave propagation through chain)
//   TC3  - Stagger demonstration (cycle-by-cycle proof of systolic timing)
//   TC4  - Full dot product (A·W computed correctly across all PEs)
//   TC5  - Weight hold
//   TC6  - Negative activations
//   TC7  - Mixed positive/negative weights
//   TC8  - Boundary values (127×127, -128×-128)
//   TC9  - Mid-run reset
//   TC10 - MAC Array vs Systolic comparison (same inputs, different acc timing)
//   TC11 - Long accumulation (50 cycles, reference model verified every cycle)
//
//////////////////////////////////////////////////////////////////////////////////

module systolic_array_tb;

    // -----------------------------------------------------------------------
    // Parameters — mirror the DUT
    // -----------------------------------------------------------------------
    localparam NUM_PES    = 4;
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = (2 * DATA_WIDTH) + 1;   // 17 bits

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
    // Reference Model — per-PE state arrays
    // -----------------------------------------------------------------------
    integer ref_chain  [0:NUM_PES-1]; // what each PE sees as a_in (before edge)
    integer ref_w      [0:NUM_PES-1]; // each PE's w_reg
    integer ref_stage1 [0:NUM_PES-1]; // each PE's product_reg
    integer ref_acc    [0:NUM_PES-1]; // each PE's accumulator

    // Temporaries for simultaneous update
    integer new_stage1 [0:NUM_PES-1];
    integer new_acc    [0:NUM_PES-1];
    integer new_w      [0:NUM_PES-1];

    // -----------------------------------------------------------------------
    // Error counter and test label
    // -----------------------------------------------------------------------
    integer error_count;
    integer test_num;

    // -----------------------------------------------------------------------
    // DUT Instantiation
    // -----------------------------------------------------------------------
    systolic_array #(
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
    // Task: set_weights — pack 4 weights into the weight_in bus
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
    // Drives one clock cycle and advances the full reference model.
    //
    // CRITICAL — ref_chain handling:
    //   Step 1 (before edge): ref_chain[0] = in_a (combinational at chain[0])
    //   Step 2 (after edge):  compute new values using OLD ref_chain[]
    //   Step 3:               shift chain right (i = NUM_PES-1 downto 1):
    //                           ref_chain[i] = old ref_chain[i-1]
    //   ref_chain[0] is NOT updated here — it will be set to the next
    //   apply_inputs's in_a at the start of that call.
    //
    // a_out check:
    //   After the edge, a_out = PE[NUM_PES-1]'s forwarding register =
    //   what was at chain[NUM_PES-1] BEFORE the edge = old ref_chain[NUM_PES-1].
    //   This is saved before the chain shift.
    // -----------------------------------------------------------------------
    integer k;
    integer saved_last_chain;  // for a_out verification

    task apply_inputs;
        input signed [DATA_WIDTH-1:0] in_a;
        input                         in_load;
        input signed [DATA_WIDTH-1:0] w0, w1, w2, w3;
        begin
            // ── Step 1: set chain[0] = current a_in (combinational) ──────
            ref_chain[0] = $signed(in_a);

            // Drive DUT inputs
            a_in        = in_a;
            load_weight = in_load;
            set_weights(w0, w1, w2, w3);

            // Wait for rising clock edge
            @(posedge clk);
            #1;

            // ── Step 2: save a_out check value (old chain[NUM_PES-1]) ────
            saved_last_chain = ref_chain[NUM_PES-1];

            // ── Step 3: compute new values with OLD state ─────────────────
            for (k = 0; k < NUM_PES; k = k + 1) begin
                new_acc[k]    = ref_acc[k] + ref_stage1[k]; // Stage 2: old stage1
                new_stage1[k] = ref_chain[k] * ref_w[k];   // Stage 1: old chain + w
            end
            new_w[0] = in_load ? $signed(w0) : ref_w[0];
            new_w[1] = in_load ? $signed(w1) : ref_w[1];
            new_w[2] = in_load ? $signed(w2) : ref_w[2];
            new_w[3] = in_load ? $signed(w3) : ref_w[3];

            // ── Step 4: shift chain right (i = NUM_PES-1 downto 1) ───────
            // Go right-to-left so we read old values before overwriting
            for (k = NUM_PES-1; k >= 1; k = k - 1)
                ref_chain[k] = ref_chain[k-1];
            // ref_chain[0] is left as-is; next apply_inputs will overwrite it

            // ── Step 5: commit ─────────────────────────────────────────────
            for (k = 0; k < NUM_PES; k = k + 1) begin
                ref_acc[k]    = new_acc[k];
                ref_stage1[k] = new_stage1[k];
                ref_w[k]      = new_w[k];
            end

            // ── Step 6: check all PE accs ──────────────────────────────────
            for (k = 0; k < NUM_PES; k = k + 1) begin
                if ($signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]) !==
                    ref_acc[k][ACC_WIDTH-1:0]) begin
                    $display("  [FAIL] t=%0t | TC%0d | PE[%0d] acc: got %0d, exp %0d  (chain=%0d, w=%0d)",
                             $time, test_num, k,
                             $signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]),
                             ref_acc[k], ref_chain[k], ref_w[k]);
                    error_count = error_count + 1;
                end else begin
                    $display("  [PASS] t=%0t | TC%0d | PE[%0d] acc=%0d  (saw a=%0d, w=%0d, stg1=%0d)",
                             $time, test_num, k,
                             $signed(acc_out[((k+1)*ACC_WIDTH)-1 -: ACC_WIDTH]),
                             ref_chain[k], ref_w[k], ref_stage1[k]);
                end
            end

            // ── Step 7: check a_out (last PE's forwarding output) ─────────
            if ($signed(a_out) !== saved_last_chain[DATA_WIDTH-1:0]) begin
                $display("  [FAIL] t=%0t | TC%0d | a_out: got %0d, exp %0d",
                         $time, test_num, $signed(a_out), saved_last_chain);
                error_count = error_count + 1;
            end else begin
                $display("  [PASS] t=%0t | TC%0d | a_out=%0d",
                         $time, test_num, $signed(a_out));
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: flush_pipeline
    //
    // Drives NUM_PES+1 zero cycles to fully drain the systolic array.
    //
    // Drain analysis for NUM_PES=4:
    //   - Last real activation is in ref_chain[0] when the last apply_inputs ran.
    //   - It takes NUM_PES-1 chain hops to reach PE[NUM_PES-1].
    //   - Then 1 more cycle for stage1, 1 more for stage2 (acc).
    //   - Total: (NUM_PES-1) + 2 = NUM_PES+1 flush cycles.
    //
    // Compare to mac_array_tb which needed only 1 flush cycle (no chain).
    // This is a direct, measurable consequence of the systolic architecture.
    // -----------------------------------------------------------------------
    integer f;

    task flush_pipeline;
        begin
            $display("  [FLUSH] Draining systolic array — %0d zero cycles needed", NUM_PES+1);
            for (f = 0; f < NUM_PES+1; f = f + 1)
                apply_inputs(0, 0, 0, 0, 0, 0);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: do_reset
    // -----------------------------------------------------------------------
    task do_reset;
        integer j;
        begin
            load_weight = 0; weight_in = 0; a_in = 0;
            rst = 1;
            @(posedge clk); #1;
            @(posedge clk); #1;

            for (j = 0; j < NUM_PES; j = j + 1) begin
                ref_chain[j]  = 0;
                ref_w[j]      = 0;
                ref_stage1[j] = 0;
                ref_acc[j]    = 0;
            end

            for (j = 0; j < NUM_PES; j = j + 1) begin
                if (acc_out[((j+1)*ACC_WIDTH)-1 -: ACC_WIDTH] !== {ACC_WIDTH{1'b0}}) begin
                    $display("  [FAIL] t=%0t | RESET | PE[%0d] acc not zero: %0d",
                             $time, j,
                             $signed(acc_out[((j+1)*ACC_WIDTH)-1 -: ACC_WIDTH]));
                    error_count = error_count + 1;
                end else
                    $display("  [PASS] t=%0t | RESET | PE[%0d] acc = 0", $time, j);
            end

            if (a_out !== {DATA_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | RESET | a_out not zero: %0d",
                         $time, $signed(a_out));
                error_count = error_count + 1;
            end else
                $display("  [PASS] t=%0t | RESET | a_out = 0", $time);

            rst = 0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------------------------------
    integer i;

    initial begin
        error_count = 0; test_num = 0;
        clk = 0; rst = 1;
        a_in = 0; load_weight = 0; weight_in = 0;
        for (i = 0; i < NUM_PES; i = i + 1) begin
            ref_chain[i] = 0; ref_w[i] = 0; ref_stage1[i] = 0; ref_acc[i] = 0;
        end

        $display("================================================================");
        $display("  Self-Checking Testbench : systolic_array");
        $display("  NUM_PES=%0d  DATA_WIDTH=%0d  ACC_WIDTH=%0d",
                 NUM_PES, DATA_WIDTH, ACC_WIDTH);
        $display("  Flush cycles required = NUM_PES+1 = %0d", NUM_PES+1);
        $display("================================================================");

        // ===================================================================
        // TC1 — Synchronous Reset
        // ===================================================================
        $display("\n--- TC1: Synchronous Reset ---");
        test_num = 1;
        do_reset;

        // ===================================================================
        // TC2 — Single Activation Pulse: Wave Propagation
        //
        // Feed A0=10 for ONE cycle then zeros. Load W={1,1,1,1} so product
        // and acc values equal the activation, making the stagger visible.
        //
        // Expected (stage1 follows the wave through the chain):
        //   Cycle 1 (A0 enters):
        //     PE[0] stage1 ← 10×1=10     PE[1..3] stage1 ← 0
        //   Cycle 2 (a_in=0, A0 at chain[1]):
        //     PE[0] stage1 ← 0,  acc ← 10    PE[1] stage1 ← 10×1=10  PE[2..3] ← 0
        //   Cycle 3: PE[2] stage1 ← 10, PE[0..1] acc settled
        //   Cycle 4: PE[3] stage1 ← 10
        //   ... flush ... PE[3] acc ← 10
        //
        // At the end: acc[0]=acc[1]=acc[2]=acc[3]=10  (same product, staggered arrival)
        // ===================================================================
        $display("\n--- TC2: Single Pulse — Wave Propagation (W={1,1,1,1}, A0=10) ---");
        test_num = 2;
        apply_inputs(8'd10, 1'b1, 8'd1, 8'd1, 8'd1, 8'd1);  // load + first activation
        apply_inputs(8'd0,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd0,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd0,  1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] All PE accs should equal 10 — same product, different arrival time");
        do_reset;

        // ===================================================================
        // TC3 — Stagger Demonstration (cycle-by-cycle proof)
        //
        // Feed 4 DISTINCT activations A={10,20,30,40} with W={1,1,1,1}.
        //
        //   Cycle 1: a_in=10  chain = [10,  0,  0,  0]  → stage1 = [10, 0, 0, 0]
        //   Cycle 2: a_in=20  chain = [20, 10,  0,  0]  → stage1 = [20,10, 0, 0]
        //   Cycle 3: a_in=30  chain = [30, 20, 10,  0]  → stage1 = [30,20,10, 0]
        //   Cycle 4: a_in=40  chain = [40, 30, 20, 10]  → stage1 = [40,30,20,10]
        //                                                 ← array is FULL here
        //   ...flush...
        //   Final acc: PE[0]=10+20+30+40=100, PE[1]=10+20+30+40=100, etc.
        //   (All PEs see all 4 activations, just at different cycles)
        //
        // This test verifies the reference model's chain shift is correct.
        // ===================================================================
        $display("\n--- TC3: Stagger Demonstration (A={10,20,30,40}, W={1,1,1,1}) ---");
        test_num = 3;
        $display("  [INFO] Watch PE[i] acc grow: PE[0] fills fastest, PE[3] slowest.");
        apply_inputs(8'd10, 1'b1, 8'd1, 8'd1, 8'd1, 8'd1);  // load + A0=10
        apply_inputs(8'd20, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // A1=20
        apply_inputs(8'd30, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // A2=30
        apply_inputs(8'd40, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // A3=40 — array full
        flush_pipeline;
        $display("  [INFO] Final: all PE accs = 100 (10+20+30+40), but reached at diff cycles");
        do_reset;

        // ===================================================================
        // TC4 — Full Dot Product A·W
        //
        // This is the canonical use case for a 1-D systolic array:
        // compute N independent weighted sums in one activation stream pass.
        //
        // W = {2, 3, 5, 7} (different per PE)
        // A = {4, 4, 4, 4} (same activation, 4 cycles)
        //
        // Expected after full drain:
        //   acc[0] = 4×4×2 = 32  (4 activations × W[0]=2)
        //   acc[1] = 4×4×3 = 48
        //   acc[2] = 4×4×5 = 80
        //   acc[3] = 4×4×7 = 112
        //
        // Note: on the load cycle (cycle 1), product uses OLD w=0 (same
        // timing rule as all previous projects).
        // ===================================================================
        $display("\n--- TC4: Full Weighted Sum (W={2,3,5,7}, a=4 for 4 cycles) ---");
        test_num = 4;
        apply_inputs(8'd4, 1'b1, 8'd2, 8'd3, 8'd5, 8'd7);
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd4, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        $display("  [INFO] Expected acc: PE[0]=32, PE[1]=48, PE[2]=80, PE[3]=112");
        do_reset;

        // ===================================================================
        // TC5 — Weight Hold
        //
        // Same as MAC array: weights persist without reload.
        // ===================================================================
        $display("\n--- TC5: Weight Hold (load once, stream 6 cycles) ---");
        test_num = 5;
        apply_inputs(8'd1, 1'b1, 8'd4, 8'd4, 8'd4, 8'd4);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC6 — Negative Activations
        // ===================================================================
        $display("\n--- TC6: Negative Activations (a=-5, W={2,3,4,5}) ---");
        test_num = 6;
        apply_inputs(-8'd5, 1'b1, 8'd2, 8'd3, 8'd4, 8'd5);
        apply_inputs(-8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(-8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(-8'd5, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC7 — Mixed Positive/Negative Weights
        //
        // Positive activations × mixed weights.
        // PE[0] and PE[2] accumulate positively, PE[1] and PE[3] negatively.
        // ===================================================================
        $display("\n--- TC7: Mixed Weights (W={3,-3,5,-5}, a=4) ---");
        test_num = 7;
        apply_inputs(8'd4, 1'b1,  8'd3, -8'd3,  8'd5, -8'd5);
        apply_inputs(8'd4, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        apply_inputs(8'd4, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        apply_inputs(8'd4, 1'b0,  8'd0,  8'd0,  8'd0,  8'd0);
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC8 — Boundary Values
        // ===================================================================
        $display("\n--- TC8: Boundary Values (127x127, -128x-128) ---");
        test_num = 8;
        apply_inputs( 8'd127, 1'b1,  8'd127,  8'd127, -8'd128, -8'd128);
        apply_inputs( 8'd127, 1'b0,  8'd0,    8'd0,    8'd0,    8'd0  );
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC9 — Mid-run Reset
        //
        // Build the wave partway, then reset. All chain registers,
        // product_regs, and accs inside every PE must clear.
        // ===================================================================
        $display("\n--- TC9: Mid-run Reset ---");
        test_num = 9;
        apply_inputs(8'd8, 1'b1, 8'd2, 8'd3, 8'd4, 8'd5);
        apply_inputs(8'd8, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);
        apply_inputs(8'd8, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);

        rst = 1;
        @(posedge clk); #1;

        for (i = 0; i < NUM_PES; i = i + 1) begin
            ref_chain[i] = 0; ref_w[i] = 0; ref_stage1[i] = 0; ref_acc[i] = 0;
        end

        for (i = 0; i < NUM_PES; i = i + 1) begin
            if (acc_out[((i+1)*ACC_WIDTH)-1 -: ACC_WIDTH] !== {ACC_WIDTH{1'b0}}) begin
                $display("  [FAIL] t=%0t | TC9 | PE[%0d] acc not zero: %0d",
                         $time, i,
                         $signed(acc_out[((i+1)*ACC_WIDTH)-1 -: ACC_WIDTH]));
                error_count = error_count + 1;
            end else
                $display("  [PASS] t=%0t | TC9 | PE[%0d] acc = 0 after mid-reset", $time, i);
        end
        rst = 0;

        // ===================================================================
        // TC10 — MAC Array vs Systolic Comparison
        //
        // This test demonstrates the key architectural difference:
        //
        //   MAC Array  : PE[0] acc sees products from cycle 2 onwards.
        //                All PEs start accumulating the same cycle.
        //
        //   Systolic   : PE[0] leads. PE[i] starts accumulating i cycles later.
        //                After 1 cycle, only PE[0] has a non-zero acc.
        //                After 2 cycles, only PE[0] and PE[1] are accumulating.
        //                ...
        //
        // Drive 3 cycles of a=10 with W={1,1,1,1}, then check cycle-by-cycle.
        // The reference model will show the staggered growth of each PE's acc.
        // ===================================================================
        $display("\n--- TC10: Systolic Stagger vs MAC Broadcast (W={1,1,1,1}, a=10) ---");
        test_num = 10;
        $display("  [INFO] In MAC Array, all PE accs would grow at the same rate.");
        $display("  [INFO] Here, PE[0] leads by i cycles over PE[i].");
        apply_inputs(8'd10, 1'b1, 8'd1, 8'd1, 8'd1, 8'd1);  // cycle 1: only PE[0] computing
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // cycle 2: PE[0],PE[1]
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // cycle 3: PE[0..2]
        apply_inputs(8'd10, 1'b0, 8'd0, 8'd0, 8'd0, 8'd0);  // cycle 4: all PE computing
        flush_pipeline;
        do_reset;

        // ===================================================================
        // TC11 — Long Accumulation (50 activations, reference checked every cycle)
        //
        // W = {1, 2, 3, 4} — different weights to verify independence.
        // Activations cycle through -5..+4 deterministically.
        // The reference model tracks the staggered chain and all PE states.
        // ===================================================================
        $display("\n--- TC11: Long Accumulation (W={1,2,3,4}, 50 cycles) ---");
        test_num = 11;
        apply_inputs(8'd1, 1'b1, 8'd1, 8'd2, 8'd3, 8'd4);   // load weights

        for (i = 0; i < 49; i = i + 1) begin
            apply_inputs(
                $signed(((i % 10) - 5)),
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
        #500000;
        $display("[WATCHDOG] Simulation exceeded time limit. Terminating.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform Dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("systolic_array_tb.vcd");
        $dumpvars(0, systolic_array_tb);
    end

endmodule
