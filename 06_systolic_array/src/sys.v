`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 06 - Systolic Array
// Module  : systolic_array
// Author  : Gayathri Satheesh
//
// Description:
// 1-D systolic array of Processing Elements (PEs) where activation data
// propagates as a wave through the chain instead of being broadcast to all
// PEs simultaneously.
//
// ─── The one change from MAC Array ───────────────────────────────────────────
//
// MAC Array  : a_in is broadcast — every PE sees A[t] at the SAME cycle.
// Systolic   : a_in is chained  — PE[i] sees A[t] exactly i cycles LATER
//              than PE[0] because it travels through i forwarding registers.
//
//   MAC Array data flow:
//       a_in ──┬──► PE[0]
//              ├──► PE[1]         (all PEs see A[t] at cycle t)
//              ├──► PE[2]
//              └──► PE[3]
//
//   Systolic Array data flow:
//       a_in ──► PE[0] ──a_out──► PE[1] ──a_out──► PE[2] ──a_out──► PE[3] ──► a_out
//                                                                         (array port)
//
// The a_out port already existed on processing_element from Project 04 for
// exactly this purpose. Nothing in processing_element.v needs to change.
//
// ─── Why the stagger matters ─────────────────────────────────────────────────
//
// With the stagger, when you stream activations A[0], A[1], A[2], A[3] into
// PE[0] on consecutive cycles, after NUM_PES cycles:
//
//   PE[0] is computing  A[3] × W[0]   (sees A[3])
//   PE[1] is computing  A[2] × W[1]   (sees A[2], 1 cycle behind)
//   PE[2] is computing  A[1] × W[2]   (sees A[1], 2 cycles behind)
//   PE[3] is computing  A[0] × W[3]   (sees A[0], 3 cycles behind)
//
// At that instant, all PEs are working simultaneously on different elements
// of the same input vector — this is data-parallel computation with no
// central distribution network.
//
// ─── Timing diagram (NUM_PES=4, after weights loaded) ────────────────────────
//
//  Cycle │ a_in │ PE[0] sees │ PE[1] sees │ PE[2] sees │ PE[3] sees
//  ──────┼──────┼────────────┼────────────┼────────────┼────────────
//    1   │  A0  │     A0     │     0      │     0      │     0     ← wave enters
//    2   │  A1  │     A1     │     A0     │     0      │     0
//    3   │  A2  │     A2     │     A1     │     A0     │     0
//    4   │  A3  │     A3     │     A2     │     A1     │     A0    ← array full
//    5   │   0  │      0     │     A3     │     A2     │     A1
//    6   │   0  │      0     │      0     │     A3     │     A2
//    7   │   0  │      0     │      0     │      0     │     A3    ← last product in stage1
//  flush │   0  │      0     │      0     │      0     │      0    ← last product → acc
//
// After cycle 8 (flush), acc[i] = sum of all A[t]×W[i] products received.
//
// ─── Comparison: Systolic vs MAC Array ───────────────────────────────────────
//
//   ┌────────────────────────┬──────────────────────┬────────────────────────┐
//   │ Metric                 │     MAC Array        │    Systolic Array      │
//   ├────────────────────────┼──────────────────────┼────────────────────────┤
//   │ Data distribution      │ Broadcast (fanout N) │ Chain (fanout 1 each)  │
//   │ Wiring complexity      │ O(N) from one source │ O(1) per hop           │
//   │ Fill latency           │ 0 extra cycles       │ NUM_PES-1 extra cycles │
//   │ Drain latency          │ 1 flush cycle        │ NUM_PES+1 flush cycles │
//   │ Critical path          │ unchanged            │ unchanged (same PE)    │
//   │ Scalability            │ fanout degrades Fmax │ scales to large N      │
//   │ Hardware change vs MAC │ —                    │ route a_out→a_in only  │
//   └────────────────────────┴──────────────────────┴────────────────────────┘
//
// ─── Module Hierarchy ─────────────────────────────────────────────────────────
//
//   systolic_array
//   └── processing_element  [NUM_PES instances, generated, chained]
//       └── pipelined_mac   [1 instance per PE]
//
// ─── Parameters ──────────────────────────────────────────────────────────────
//   NUM_PES    : Number of chained PEs (default = 4)
//   DATA_WIDTH : Bit-width of each signed operand (default = 8)
//
// ─── Port Widths ─────────────────────────────────────────────────────────────
//   a_in       : DATA_WIDTH bits (enters PE[0])
//   weight_in  : NUM_PES × DATA_WIDTH bits (packed, PE[0] in LSBs)
//   acc_out    : NUM_PES × ACC_WIDTH bits  (packed, PE[0] in LSBs)
//   a_out      : DATA_WIDTH bits (exits PE[NUM_PES-1], for chaining arrays)
//
//   where ACC_WIDTH = (2*DATA_WIDTH)+1
//
//////////////////////////////////////////////////////////////////////////////////

module systolic_array #(
    parameter NUM_PES    = 4,
    parameter DATA_WIDTH = 8
)(
    input  wire                                         clk,
    input  wire                                         rst,

    // ── Activation input — enters at PE[0], propagates right through chain ───
    input  wire signed [DATA_WIDTH-1:0]                 a_in,

    // ── Weight interface — all PEs loaded simultaneously ─────────────────────
    // weight_in[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH] → PE[i].weight_in
    input  wire                                         load_weight,
    input  wire signed [NUM_PES*DATA_WIDTH-1:0]         weight_in,

    // ── Accumulated results — one per PE (packed) ─────────────────────────────
    // acc_out[(i+1)*ACC_WIDTH-1 : i*ACC_WIDTH] ← PE[i].acc
    output wire signed [NUM_PES*(2*DATA_WIDTH+1)-1:0]   acc_out,

    // ── Forwarding output from last PE — for chaining multiple arrays ─────────
    output wire signed [DATA_WIDTH-1:0]                 a_out
);

    // -------------------------------------------------------------------------
    // Derived parameter
    // -------------------------------------------------------------------------
    localparam ACC_WIDTH = (2 * DATA_WIDTH) + 1;

    // -------------------------------------------------------------------------
    // Activation chain
    //
    // chain[i] is the wire feeding PE[i].a_in.
    // chain[0]        = external a_in port (combinational, no register)
    // chain[i] (i≥1)  = PE[i-1].a_out     (registered, 1 cycle of delay per hop)
    //
    // This is the only structural difference between systolic_array and
    // mac_array: in mac_array every PE's a_in was tied to the same a_in port.
    // Here each PE gets its own chain element.
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] chain [0:NUM_PES];

    assign chain[0] = a_in;              // PE[0] receives the external input directly
    assign a_out    = chain[NUM_PES];    // last PE's forwarding output exits the array

    // -------------------------------------------------------------------------
    // PE Chain — generate NUM_PES instances
    //
    //   PE[i].a_in  = chain[i]     (comes from PE[i-1].a_out, or a_in for i=0)
    //   PE[i].a_out = chain[i+1]   (feeds PE[i+1].a_in, or exits for i=NUM_PES-1)
    //
    // Weight and acc slicing is identical to mac_array.
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_PES; i = i + 1) begin : pe_chain

            processing_element #(
                .DATA_WIDTH(DATA_WIDTH)
            ) pe_inst (
                .clk         (clk),
                .rst         (rst),
                .load_weight (load_weight),
                .weight_in   (weight_in [((i+1)*DATA_WIDTH)-1 : i*DATA_WIDTH ]),
                .a_in        (chain[i]),
                .a_out       (chain[i+1]),
                .acc         (acc_out   [((i+1)*ACC_WIDTH)-1  : i*ACC_WIDTH  ])
            );

        end
    endgenerate

endmodule
