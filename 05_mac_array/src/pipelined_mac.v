`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 03 - Pipelined MAC
// Module  : pipelined_mac
// Author  : Gayathri Satheesh
//
// Description:
// 2-stage pipelined signed Multiply-Accumulate (MAC) unit.
//
// Architecture improvement over single MAC:
//   The single MAC (Project 01) computes (a * b) combinationally and then
//   adds it to the accumulator in one clock cycle. The multiply-then-add
//   path is the critical path that limits Fmax.
//
//   This design splits that work across two pipeline stages, halving the
//   combinational depth per stage and allowing a significantly higher
//   maximum clock frequency at the cost of 1 cycle of pipeline latency.
//
// Pipeline Stages:
//   Stage 1 (Multiply) :  product_reg  <=  a * b
//   Stage 2 (Accumulate): acc          <=  acc + product_reg
//
// Timing diagram (inputs applied before each rising edge):
//
//   Cycle |  a  b   | product_reg (after clk) | acc (after clk)
//   ------+---------+-------------------------+------------------
//     1   | A0  B0  | A0*B0                   |  0              <- pipeline fills
//     2   | A1  B1  | A1*B1                   |  A0*B0
//     3   | A2  B2  | A2*B2                   |  A0*B0 + A1*B1
//     4   |  0   0  |  0                      |  A0*B0 + A1*B1 + A2*B2  <- flush
//
// Pipeline Latency : 1 cycle  (acc reflects input pair [N] after cycle N+1)
// Throughput       : 1 MAC/cycle (after the pipeline is filled)
//
// Block Diagram:
//
//        a ──┐
//             ├──[combinational ×]──┬──[FF]──► product_reg
//        b ──┘           Stage 1   │  (clk1)
//                                  │
//                          ┌───────┘
//                          │
//              acc ──[+]◄──┘
//              ↑    [FF]──► acc
//              │    (clk2)
//              └────────────┘  Stage 2
//
// Features:
//   - Parameterized input width (DATA_WIDTH)
//   - Signed multiplication
//   - 2-stage synchronous pipeline
//   - Active-high synchronous reset (clears both pipeline registers)
//   - Accumulator width automatically derived: (2*DATA_WIDTH)+1 bits
//
// Parameters:
//   DATA_WIDTH : Bit-width of each signed input (default = 8)
//
// Port Widths (DATA_WIDTH = 8):
//   a, b        : 8-bit signed inputs
//   product_reg : 16-bit signed (internal pipeline register)
//   acc         : 17-bit signed output  (same as Project 01 MAC)
//
// Comparison with Single MAC (Project 01):
//   ┌───────────────────┬──────────────┬────────────────┐
//   │ Metric            │  Single MAC  │  Pipelined MAC │
//   ├───────────────────┼──────────────┼────────────────┤
//   │ Pipeline stages   │      1       │       2        │
//   │ Latency (cycles)  │      1       │       2        │
//   │ Throughput        │  1 MAC/clk   │  1 MAC/clk     │
//   │ Critical path     │  mul + add   │  mul  OR  add  │
//   │ Flip-flops        │    lower     │     higher     │
//   │ Max frequency     │    lower     │     higher     │
//   └───────────────────┴──────────────┴────────────────┘
//
//////////////////////////////////////////////////////////////////////////////////

module pipelined_mac #(
    parameter DATA_WIDTH = 8
)(
    input  wire                             clk,
    input  wire                             rst,
    input  wire signed [DATA_WIDTH-1:0]     a,
    input  wire signed [DATA_WIDTH-1:0]     b,

    output reg  signed [(2*DATA_WIDTH):0]   acc
);

    // -------------------------------------------------------------------------
    // Pipeline Stage 1 Register - holds the registered multiply result
    //
    // Width: (2*DATA_WIDTH) bits - full-precision product of two DATA_WIDTH
    // signed values. No truncation at this stage; precision is preserved.
    // -------------------------------------------------------------------------
    reg signed [(2*DATA_WIDTH)-1:0] product_reg;

    // -------------------------------------------------------------------------
    // Stage 1 : Multiply
    //
    // On every rising clock edge, compute a*b combinationally and register
    // the result in product_reg. This stage breaks the critical path at
    // exactly the multiply-register boundary.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            product_reg <= 0;
        else
            product_reg <= a * b;
    end

    // -------------------------------------------------------------------------
    // Stage 2 : Accumulate
    //
    // On every rising clock edge, add the previously registered product into
    // the running accumulator. Because product_reg is already a register,
    // this stage only needs to implement the add-then-register path - a much
    // shorter critical path than multiply-add-register.
    //
    // The accumulator is (2*DATA_WIDTH)+1 bits wide (one extra bit vs the
    // product register) to guard against overflow when adding the sign-extended
    // product to the running sum.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            acc <= 0;
        else
            acc <= acc + product_reg;
    end

endmodule