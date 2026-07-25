`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Project : Project 01 - Single MAC
// Module  : mac
// Author  : Gayathri Satheesh
//
// Description:
// Parameterized signed Multiply-Accumulate (MAC) Unit.
//
// Operation:
//     ACC <= ACC + (A * B)
//
// Features:
// - Parameterized input width
// - Signed multiplication
// - Synchronous accumulator
// - Active-high synchronous reset
//
//////////////////////////////////////////////////////////////////////////////////

module mac #(
    parameter DATA_WIDTH = 8
)(
    input  wire                             clk,
    input  wire                             rst,
    input  wire signed [DATA_WIDTH-1:0]     a,
    input  wire signed [DATA_WIDTH-1:0]     b,

    output reg  signed [(2*DATA_WIDTH):0]   acc
);

    // Internal signal to hold multiplication result
    wire signed [(2*DATA_WIDTH)-1:0] product;

    // Combinational multiplier
    assign product = a * b;

    // Sequential accumulator
    always @(posedge clk) begin
        if (rst)
            acc <= 0;
        else
            acc <= acc + product;
    end

endmodule
