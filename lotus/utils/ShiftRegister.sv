/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Synthesizes to SLR16/SRL32C primitives, in a way that lets the synthesizer
// pack two SRL16s per LUT (which a Bluespec implementation doesn't allow)
module ShiftRegister #(
    WIDTH = 64,
    DEPTH = 16,
    INITIAL_VALUE = (WIDTH*DEPTH)'(0) // data packed in big-endian order
) (
    input clk,
    input [WIDTH-1:0] din,
    input shiftEn,
    input [$clog2(DEPTH)-1:0] addr,
    output [WIDTH-1:0] dout
);

reg [WIDTH-1:0] shiftReg [DEPTH-1:0];
// ASIC area synthesis disables FPGA power-up initialization explicitly.
`ifndef BSV_NO_INITIAL_BLOCKS
initial for (int i = 0; i < DEPTH; i = i + 1) shiftReg[i] = INITIAL_VALUE[i*WIDTH +: WIDTH];
`endif

always @(posedge clk) begin
    if (shiftEn) begin
        shiftReg[0] <= din;
        for (int i = 1; i < DEPTH; i = i + 1) shiftReg[i] <= shiftReg[i-1];
    end
end

assign dout = shiftReg[addr];

endmodule
