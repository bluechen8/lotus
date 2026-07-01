/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// This is a straight translation of the BSV implementation; having this as
// a parametric module helps improve synthesis quality, because (1) it
// prevents bsc from inlining these FIFOs everywhere, and makes synthesis
// boundaries clear to vivado, which improves placement quality, and (2) the
// keep_hierarchy pragma prevents vivado from creating a roundtrip critical
// path to save a couple LUTs, which doubles delay when FIFOs are far apart;
// instead, with this implementation, delays between two FIFOs are one-way.
(* keep_hierarchy = "true" *)
module CreditFIFO#(
    WIDTH = 1,
    MAX_CREDITS = 1,
    BYPASS_CREDIT = 0
) (
    input clk,

    input [WIDTH-1:0] recv_datain,
    input recv_datain_valid,
    output recv_creditout,

    output [WIDTH-1:0] send_dataout,
    output send_dataout_valid,
    input send_creditin
);

localparam CREDIT_BITS = (MAX_CREDITS > 0) ? $clog2(MAX_CREDITS+1) : 1;
localparam [CREDIT_BITS-1:0] MAX_CREDITS_VALUE = CREDIT_BITS'(MAX_CREDITS);

// state elements
reg [CREDIT_BITS-1:0] downstreamCredits;
reg creditOut;

reg val_valid;
reg [WIDTH-1:0] val;

initial begin
    downstreamCredits = 0;
    creditOut = 1;
    val_valid = 0;
end

// rule tick
wire deq = val_valid && ((downstreamCredits != 0) || send_creditin);
wire nonFull = !val_valid || (downstreamCredits != 0) || (BYPASS_CREDIT && send_creditin);

always @(posedge clk) begin
    if (nonFull) begin
        val_valid <= recv_datain_valid;
        val <= recv_datain;
    end else if (send_creditin) begin
        val_valid <= 0;
    end

    if (deq != send_creditin) begin
        downstreamCredits <= downstreamCredits + (deq? -1 : 1);
        if (send_creditin && downstreamCredits == MAX_CREDITS_VALUE) begin
            $display("CreditFIFO ERROR: %m received credit with credits already at max! downstreamCredits=%d", downstreamCredits);
            $finish;
        end
    end

    if (BYPASS_CREDIT) creditOut <= creditOut && send_creditin;
    else creditOut <= send_creditin;
end

// interfaces
assign recv_creditout = BYPASS_CREDIT? (creditOut || send_creditin) : creditOut;
assign send_dataout_valid = val_valid;
assign send_dataout = val;

endmodule
