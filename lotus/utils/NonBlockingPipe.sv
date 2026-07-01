/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

(* keep_hierarchy = "true" *)
module NonBlockingPipe #(
    parameter WIDTH = 1,
    parameter STAGES = 1,
    parameter INITIAL_VALUE = 0
) (
   input clk,
   input [WIDTH-1:0] in,
   output [WIDTH-1:0] out
);

(* shreg_extract = "no" *)
logic [WIDTH-1:0] regs [STAGES-1:0];

initial begin
    for (integer i = 0; i < STAGES; i = i + 1)
        regs[i] = INITIAL_VALUE;
end

always @(posedge clk) begin
    regs[0] <= in;
    for (integer i = 1; i < STAGES; i = i + 1)
        regs[i] <= regs[i-1];
end

assign out = regs[STAGES-1];

endmodule

(* keep_hierarchy = "true" *)
(* autopipeline_module = "yes" *)
module NonBlockingAutoPipe #(
    parameter WIDTH = 1,
    parameter MAX_STAGES = 9,
    parameter INITIAL_VALUE = 0
) (
    input clk,
    input wire [WIDTH-1:0] in,
    output wire [WIDTH-1:0] out
);

localparam AUTOPIPE_MAX_STAGES = MAX_STAGES - 2;

(* autopipeline_group = "autopipe", autopipeline_limit = AUTOPIPE_MAX_STAGES *) reg [WIDTH-1:0] pipe;
reg [WIDTH-1:0] dst;

initial begin
    assert (MAX_STAGES >= 2) else $error("NonBlockingAutoPipe needs MAX_STAGES to be at least 2");
    pipe = INITIAL_VALUE;
    dst = INITIAL_VALUE;
end

always @(posedge clk) begin
    pipe <= in;
    dst <= pipe;
end

assign out = dst;

endmodule
