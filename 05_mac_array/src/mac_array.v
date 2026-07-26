`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 05 - MAC Array
// Module  : mac_array
// Author  : Gayathri Satheesh
//
// Description:
// Parameterized array of Processing Elements (PEs) operating in parallel.
// Each PE holds its own weight and accumulates its own dot-product result.
// All PEs share the same activation input (broadcast architecture).
//
// ─── Why a MAC Array and not just more PEs? ──────────────────────────────────
//
// A single PE computes one multiply-accumulate per cycle. To compute an
// N-element dot product in one pass — or one row of a matrix-vector product —
// you need N PEs running simultaneously, each holding one weight and seeing
// the same activation stream. That is exactly what this module provides.
//
//   Single PE:   acc[0] = sum_t( a[t] × W[0] )          (1 dot product)
//   MAC Array:   acc[i] = sum_t( a[t] × W[i] )  ∀ i     (N dot products in parallel)
//
// ─── Architecture ────────────────────────────────────────────────────────────
//
//                         a_in (broadcast to all PEs)
//                              │
//         ┌────────────────────┼────────────────────┐
//         │                   │                    │
//     [PE_0]              [PE_1]          ...  [PE_N-1]
//      w_reg=W[0]          w_reg=W[1]            w_reg=W[N-1]
//      acc[0]              acc[1]                acc[N-1]
//         │                                         │
//      (a_out not used                          a_out ──► array a_out
//       in broadcast mode)                      (last PE, for chaining)
//
// ─── Weight Loading ───────────────────────────────────────────────────────────
//
// All PE weights are loaded simultaneously when load_weight is asserted.
// weight_in is a packed bus: { W[N-1], ..., W[1], W[0] }
//
//   weight_in[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]  →  PE[i].weight_in
//
// Assert load_weight for one cycle. The new weights take effect 1 cycle
// later in product_reg (same timing as a single PE — see PE documentation).
//
// ─── Data Flow ────────────────────────────────────────────────────────────────
//
//   Cycle  │  Event
//   ───────┼──────────────────────────────────────────────────────────────────
//     1    │  load_weight=1 : all PE w_regs loaded with W[0]..W[N-1]
//     2    │  Stream A[0] : product_reg[i] ← A[0] × W[i]  for all i
//     3    │  Stream A[1] : product_reg[i] ← A[1] × W[i]; acc[i] += A[0]×W[i]
//     4+   │  Continue streaming; acc[i] accumulates A[t]×W[i] each cycle
//   flush  │  One zero cycle to drain last product into acc
//
// ─── Comparison with Single PE ────────────────────────────────────────────────
//
//   ┌─────────────────────┬────────────────┬──────────────────────────────────┐
//   │ Metric              │   Single PE    │   MAC Array (N PEs)              │
//   ├─────────────────────┼────────────────┼──────────────────────────────────┤
//   │ Dot products/cycle  │       1        │  N (fully parallel)              │
//   │ Weights stored      │       1        │  N (one per PE)                  │
//   │ Accumulators        │       1        │  N                               │
//   │ Pipeline stages     │       2        │  2 (same — PEs are independent)  │
//   │ Resource scaling    │  1×            │  ~N× LUTs, FFs, DSPs             │
//   │ Critical path       │  unchanged     │  unchanged (no inter-PE paths)   │
//   └─────────────────────┴────────────────┴──────────────────────────────────┘
//
// ─── Module Hierarchy ─────────────────────────────────────────────────────────
//
//   mac_array
//   └── processing_element  [NUM_PES instances, generated]
//       └── pipelined_mac   [1 instance per PE]
//
// ─── Parameters ──────────────────────────────────────────────────────────────
//   NUM_PES    : Number of parallel PEs (default = 4)
//   DATA_WIDTH : Bit-width of each signed operand (default = 8)
//
// ─── Derived widths ──────────────────────────────────────────────────────────
//   ACC_WIDTH    = (2*DATA_WIDTH) + 1  = 17 bits per PE
//   weight_in    = NUM_PES * DATA_WIDTH bits  (packed, PE[0] in LSBs)
//   acc_out      = NUM_PES * ACC_WIDTH  bits  (packed, PE[0] in LSBs)
//
//////////////////////////////////////////////////////////////////////////////////

module mac_array #(
    parameter NUM_PES    = 4,
    parameter DATA_WIDTH = 8
)(
    input  wire                                         clk,
    input  wire                                         rst,

    // ── Shared activation input (broadcast to all PEs) ───────────────────────
    input  wire signed [DATA_WIDTH-1:0]                 a_in,

    // ── Weight interface ──────────────────────────────────────────────────────
    // Assert load_weight for one cycle to latch all weights simultaneously.
    // weight_in is packed: PE[0] weight in bits [DATA_WIDTH-1:0],
    //                      PE[1] weight in bits [2*DATA_WIDTH-1:DATA_WIDTH], etc.
    input  wire                                         load_weight,
    input  wire signed [NUM_PES*DATA_WIDTH-1:0]         weight_in,

    // ── Accumulated results (one per PE, packed) ──────────────────────────────
    // acc_out is packed: PE[0] acc in bits [ACC_WIDTH-1:0],
    //                    PE[1] acc in bits [2*ACC_WIDTH-1:ACC_WIDTH], etc.
    // where ACC_WIDTH = (2*DATA_WIDTH)+1
    output wire signed [NUM_PES*(2*DATA_WIDTH+1)-1:0]   acc_out,

    // ── Forwarding output from the last PE ────────────────────────────────────
    // a_in delayed by 1 cycle — useful for chaining multiple MAC arrays or
    // as the first step toward a systolic array.
    output wire signed [DATA_WIDTH-1:0]                 a_out
);

    // -------------------------------------------------------------------------
    // Derived parameter
    // -------------------------------------------------------------------------
    localparam ACC_WIDTH = (2 * DATA_WIDTH) + 1;  // 17 bits for DATA_WIDTH=8

    // -------------------------------------------------------------------------
    // Internal forwarding wires — one a_out per PE
    // In broadcast mode all PE a_outs are identical (all see the same a_in),
    // but they are wired individually so the generate loop is self-contained.
    // PE[NUM_PES-1].a_out is exposed as the array's a_out port.
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] pe_a_out [0:NUM_PES-1];

    // -------------------------------------------------------------------------
    // PE Array — generate NUM_PES instances
    //
    // Each PE:
    //   - receives the broadcast a_in
    //   - gets its own weight slice from the packed weight_in bus
    //   - outputs its acc into the packed acc_out bus
    //   - outputs a forwarding a_out (collected in pe_a_out[])
    //
    // Weight slice for PE[i]: weight_in[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]
    // Acc   slice for PE[i]: acc_out  [(i+1)*ACC_WIDTH-1   : i*ACC_WIDTH  ]
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_PES; i = i + 1) begin : pe_gen

            processing_element #(
                .DATA_WIDTH(DATA_WIDTH)
            ) pe_inst (
                .clk         (clk),
                .rst         (rst),
                .load_weight (load_weight),
                .weight_in   (weight_in  [((i+1)*DATA_WIDTH)-1  : i*DATA_WIDTH ]),
                .a_in        (a_in),
                .a_out       (pe_a_out[i]),
                .acc         (acc_out    [((i+1)*ACC_WIDTH)-1   : i*ACC_WIDTH  ])
            );

        end
    endgenerate

    // -------------------------------------------------------------------------
    // Expose the last PE's forwarding output as the array's a_out port.
    // This allows mac_array instances to be chained in the future:
    //   array[0].a_out → array[1].a_in
    // -------------------------------------------------------------------------
    assign a_out = pe_a_out[NUM_PES-1];

endmodule

