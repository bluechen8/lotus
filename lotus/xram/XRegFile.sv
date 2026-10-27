/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Register file with asynchronous reads
`timescale 1ps/1ps

`ifdef BSV_POSITIVE_RESET
  `define BSV_RESET_VALUE 1'b1
  `define BSV_RESET_EDGE posedge
`else
  `define BSV_RESET_VALUE 1'b0
  `define BSV_RESET_EDGE negedge
`endif

module XRegFile #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 16,

    // Optional
    parameter INITIAL_VALUE = 0,
    parameter STYLE = "distributed",
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clk,
    // Needed because we don't want to write during reset; Bluespec can't gate
    // wrEn by reset, so allowing writes in reset can scribble over the
    // initial values.
    // NOTE: If needed, we could have a self-reset optional param that
    // sequentially overwrites the RegFile with INITIAL_VALUE.
    input rstn,

    input wrEn,
    input [ADDR_WIDTH-1:0] wrAddr,
    input [DATA_WIDTH-1:0] wrData,

    input [ADDR_WIDTH-1:0] rdAddr1,
    output [DATA_WIDTH-1:0] rdData1,
    input [ADDR_WIDTH-1:0] rdAddr2,
    output [DATA_WIDTH-1:0] rdData2,
    input [ADDR_WIDTH-1:0] rdAddr3,
    output [DATA_WIDTH-1:0] rdData3,
    input [ADDR_WIDTH-1:0] rdAddr4,
    output [DATA_WIDTH-1:0] rdData4,
    input [ADDR_WIDTH-1:0] rdAddr5,
    output [DATA_WIDTH-1:0] rdData5
);

(* RAM_STYLE = STYLE *)
reg [DATA_WIDTH-1:0] ram [0:NUM_WORDS-1];

// ASIC area synthesis disables FPGA power-up initialization explicitly.
`ifndef BSV_NO_INITIAL_BLOCKS
initial begin : init_block
    for (integer i = 0; i < NUM_WORDS; i = i + 1) begin
        ram[i] = INITIAL_VALUE;
    end
end
`endif

always_ff @(posedge clk) if (wrEn && (rstn != `BSV_RESET_VALUE)) ram[wrAddr] <= wrData;

assign rdData1 = ram[rdAddr1];
assign rdData2 = ram[rdAddr2];
assign rdData3 = ram[rdAddr3];
assign rdData4 = ram[rdAddr4];
assign rdData5 = ram[rdAddr5];

endmodule // XRegFile
