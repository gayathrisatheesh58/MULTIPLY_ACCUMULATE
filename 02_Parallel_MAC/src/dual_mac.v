`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 02 - Dual Parallel MAC
// Module  : dual_mac
// Author  : Gayathri Satheesh
//
// Description:
// Dual parallel signed Multiply-Accumulate (MAC) unit.
// Instantiates two independent mac modules that operate simultaneously
// on separate data streams, sharing only clock and reset.
//
// Operation:
//     ACC1 <= ACC1 + (A1 * B1)   -- MAC 1
//     ACC2 <= ACC2 + (A2 * B2)   -- MAC 2
//
// Architecture:
//
//              +--------------------------------------+
//              |              Dual MAC                |
//              |                                      |
//              |   +-----------+   +-----------+      |
// A1 --------->|   |           |   |           |<--------- A2
// B1 --------->|   |   MAC 1   |   |   MAC 2   |<--------- B2
//              |   |           |   |           |      |
//              |   +-----------+   +-----------+      |
//              |        |                |            |
//              |      ACC1            ACC2           |
//              +--------------------------------------+
//
// Note: MAC1 and MAC2 are completely independent — no shared data paths.
//
// Parameters:
//   DATA_WIDTH : Bit-width of each signed input (a1, b1, a2, b2). Default = 8.
//
// Accumulator width is derived automatically from the mac module:
//   ACC_WIDTH = (2 * DATA_WIDTH) + 1  (matches mac.v output width)
//
// Important:
//   The mac submodule only has a DATA_WIDTH parameter.
//   ACC_WIDTH is NOT passed to mac — it is used here only for port declaration.
//
//////////////////////////////////////////////////////////////////////////////////

module dual_mac #(
    parameter DATA_WIDTH = 8
)(
    input  wire                             clk,
    input  wire                             rst,

    // --- MAC 1 Inputs ---
    input  wire signed [DATA_WIDTH-1:0]     a1,
    input  wire signed [DATA_WIDTH-1:0]     b1,

    // --- MAC 2 Inputs ---
    input  wire signed [DATA_WIDTH-1:0]     a2,
    input  wire signed [DATA_WIDTH-1:0]     b2,

    // --- MAC 1 Output ---
    output wire signed [(2*DATA_WIDTH):0]   acc1,

    // --- MAC 2 Output ---
    output wire signed [(2*DATA_WIDTH):0]   acc2
);

    //------------------------------------------------------------------
    // MAC Instance 1
    // Computes: ACC1 <= ACC1 + (A1 * B1)
    //------------------------------------------------------------------
    mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) mac_inst1 (
        .clk (clk),
        .rst (rst),
        .a   (a1),
        .b   (b1),
        .acc (acc1)
    );

    //------------------------------------------------------------------
    // MAC Instance 2
    // Computes: ACC2 <= ACC2 + (A2 * B2)
    //------------------------------------------------------------------
    mac #(
        .DATA_WIDTH(DATA_WIDTH)
    ) mac_inst2 (
        .clk (clk),
        .rst (rst),
        .a   (a2),
        .b   (b2),
        .acc (acc2)
    );

endmodule
