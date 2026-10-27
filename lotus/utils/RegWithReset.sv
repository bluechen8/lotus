/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// FPGA regs have a reset/set signal (for FDRE/FDSE) that overrides the clock
// enable. But Bluespec produces registers that rarely/never use set/reset
// (esp. if you don't use a circuit-level reset signal, as we do). This
// sometimes produces more logic than needed, and hurts the critical path.
// This module synthesizes directly to FDREs/FDSEs (depending on the initial
// value).
module RegWithReset#(
    parameter WIDTH = 1,

    // Optional
    parameter INITIAL_VALUE = 0
) (
    input clk,
    // These pragmas force inferring this reg to FDREs/FDSEs only; with narrow
    // regs, vivado sometimes folds this into the datapath to reduce control
    // sets. But if you want this behavior, use normal regs...
    (* direct_reset = "true" *) input reset,
    (* direct_enable = "true" *) input wrEn,
    input [WIDTH-1:0] wrData,
    output [WIDTH-1:0] data
);

reg [WIDTH-1:0] val;

// ASIC area synthesis disables FPGA power-up initialization explicitly.
`ifndef BSV_NO_INITIAL_BLOCKS
initial val = INITIAL_VALUE;
`endif

always @(posedge clk) begin
    if (reset) val <= INITIAL_VALUE;
    else if (wrEn) val <= wrData;
end

assign data = val;

endmodule

// Equivalent to the BSV test
/*
module RegWithResetTest (
    input clk,
    input [4:0] in,
    input [3:0] ctrl,
    output [4:0] out
);

reg [3:0] creg = 0;
always @(posedge clk) creg <= ctrl;

wire [4:0] x;
wire [4:0] y;

RegWithReset#(
    .WIDTH(5),
    .INITIAL_VALUE(10)
) s1 (
    .clk(clk),
    .reset(creg[3]),
    .wrEn(creg[2]),
    .wrData(in),
    .data(x)
);

RegWithReset#(
    .WIDTH(5),
    .INITIAL_VALUE(12)
) s2 (
    .clk(clk),
    .reset(creg[0]),
    .wrEn(creg[1]),
    .wrData(x),
    .data(y)
);

assign out = y;

endmodule*/
