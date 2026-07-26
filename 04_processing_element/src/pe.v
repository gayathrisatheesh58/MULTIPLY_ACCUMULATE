`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 04 - Processing Element (PE)
// Module  : processing_element
// Author  : Gayathri Satheesh
//
// Description:
// A self-contained, reusable Processing Element (PE) that wraps a pipelined
// MAC with local weight storage and a data forwarding register.
//
// This is the fundamental building block for MAC arrays and systolic arrays.
//
// ─── Why a PE and not just a MAC? ───────────────────────────────────────────
//
// A bare MAC (Project 01/03) needs BOTH operands delivered externally every
// cycle. In a dot-product or convolution engine, one operand (the weight /
// filter coefficient) is FIXED across many activations — re-sending it every
// cycle wastes wiring and control logic.
//
// The PE solves this by keeping a local copy of the weight:
//   - Load the weight ONCE via load_weight / weight_in.
//   - Stream activations via a_in every subsequent cycle.
//   - The MAC sees a steady weight_in and a changing a_in — exactly the
//     access pattern needed for dot products, FIR filters, and convolution.
//
// ─── What the forwarding register (a_out) adds ──────────────────────────────
//
// For a systolic array, each PE passes its a_in to the next PE with a 1-cycle
// delay (a_out = a_in registered). This creates the "wave" of data flowing
// through the array and removes the need for a central distribution network.
//
// ─── Architecture ────────────────────────────────────────────────────────────
//
//                             load_weight
//                                  │
//            weight_in ────────────►[w_reg]─────────────────────────┐
//            (DATA_WIDTH)          FF                                 │
//                                                                     │ b
//            a_in ───────────────────────────────────────────────►[pipelined_mac]──► acc
//            (DATA_WIDTH)          │                                  │
//                                  │          Stage 1: product_reg ← a_in × w_reg
//                                  │          Stage 2: acc ← acc + product_reg
//                                  │
//                                  └──►[FF]──► a_out  (forwarding, 1-cycle delay)
//
// ─── Pipeline timing (DATA_WIDTH=8, after reset) ─────────────────────────────
//
//  Cycle | load_w | w_in | a_in | w_reg | product_reg | acc    | a_out
//  ------+--------+------+------+-------+-------------+--------+------
//    1   |   1    |  W   |  A0  |   0→W |      0      |   0    |  A0   ← weight loads
//    2   |   0    |  —   |  A1  |   W   |    A0×W     |   0    |  A1   ← stage1 fills
//    3   |   0    |  —   |  A2  |   W   |    A1×W     |  A0×W  |  A2   ← acc starts
//
// Note: At cycle 1, product_reg still uses the OLD w_reg (0 after reset)
//       because all registers update simultaneously on the same clock edge.
//       The new weight W is first used by product_reg at cycle 2.
//
// ─── PE vs Pipelined MAC comparison ──────────────────────────────────────────
//
//   ┌─────────────────────┬───────────────┬─────────────────────┐
//   │ Feature             │ Pipelined MAC │ Processing Element  │
//   ├─────────────────────┼───────────────┼─────────────────────┤
//   │ Inputs per cycle    │ a, b (2 ext.) │ a_in only (1 ext.)  │
//   │ Weight storage      │ None          │ w_reg (local)       │
//   │ Data forwarding     │ None          │ a_out (systolic)    │
//   │ Control signals     │ clk, rst      │ clk, rst, load_w    │
//   │ Pipeline stages     │ 2             │ 2 (MAC) + 1 (w_reg) │
//   │ Extra flip-flops    │ —             │ DATA_WIDTH + DATA_WIDTH│
//   │ Suitable for arrays │ No            │ Yes                 │
//   └─────────────────────┴───────────────┴─────────────────────┘
//
// ─── Parameters ──────────────────────────────────────────────────────────────
//   DATA_WIDTH : Bit-width of each signed operand (default = 8)
//
// ─── Port Widths (DATA_WIDTH = 8) ─────────────────────────────────────────────
//   weight_in : 8-bit signed
//   a_in      : 8-bit signed
//   a_out     : 8-bit signed  (a_in delayed by 1 cycle)
//   acc       : 17-bit signed (from pipelined_mac: (2*DATA_WIDTH)+1 bits)
//
//////////////////////////////////////////////////////////////////////////////////

module processing_element #(
    parameter DATA_WIDTH = 8
)(
    input  wire                             clk,
    input  wire                             rst,

    // ── Weight interface ──────────────────────────────────────────────────────
    // Assert load_weight for one cycle to capture weight_in into w_reg.
    // The new weight takes effect on the NEXT clock cycle (synchronous).
    // w_reg holds its value indefinitely until the next load_weight pulse.
    input  wire                             load_weight,
    input  wire signed [DATA_WIDTH-1:0]     weight_in,

    // ── Activation input ──────────────────────────────────────────────────────
    // New activation sample to be multiplied against the stored weight.
    input  wire signed [DATA_WIDTH-1:0]     a_in,

    // ── Data forwarding output ────────────────────────────────────────────────
    // a_in registered by 1 cycle — used to chain PEs in a systolic array.
    // PE[i].a_out → PE[i+1].a_in
    output reg  signed [DATA_WIDTH-1:0]     a_out,

    // ── Accumulated result ────────────────────────────────────────────────────
    // Running dot-product output from the internal pipelined MAC.
    // Width: (2*DATA_WIDTH)+1 bits.
    output wire signed [(2*DATA_WIDTH):0]   acc
);

    // -------------------------------------------------------------------------
    // Local Weight Register
    //
    // Stores the coefficient this PE is responsible for computing against.
    // Loaded synchronously when load_weight is asserted.
    // Retains its value across cycles — no need to re-send the weight.
    // -------------------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] w_reg;

    always @(posedge clk) begin
        if (rst)
            w_reg <= 0;
        else if (load_weight)
            w_reg <= weight_in;
        // else: w_reg holds its current value (implicit latch-free retention)
    end

    // -------------------------------------------------------------------------
    // Data Forwarding Register
    //
    // Delays a_in by exactly 1 clock cycle.
    //
    // Purpose: In a linear PE array (systolic architecture), each PE must pass
    // its activation to the next PE with a 1-cycle stagger so that A[0] arrives
    // at PE[0] at cycle 0, PE[1] at cycle 1, PE[2] at cycle 2, etc.
    //
    // The forwarded data is always a_in regardless of whether load_weight is
    // active — weight loading and data forwarding are independent.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            a_out <= 0;
        else
            a_out <= a_in;
    end

    // -------------------------------------------------------------------------
    // Pipelined MAC Instantiation
    //
    // The MAC receives:
    //   a = a_in   — the streaming activation
    //   b = w_reg  — the locally stored weight
    //
    // Because w_reg is a registered signal, the effective data path is:
    //   weight_in → [w_reg FF] → [product_reg FF] → [acc FF]
    //   a_in                  → [product_reg FF] → [acc FF]
    //
    // The MAC's rst input is wired to the PE's rst so that the entire
    // pipeline (product_reg + acc) clears along with w_reg and a_out.
    // -------------------------------------------------------------------------
    pipelined_mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) mac_inst (
        .clk (clk),
        .rst (rst),
        .a   (a_in),
        .b   (w_reg),
        .acc (acc)
    );

endmodule
