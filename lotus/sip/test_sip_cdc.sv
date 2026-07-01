/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`timescale 1ps/1ps

module TestSIPCDC;

reg clk;
reg sClk;
initial begin
    clk = 0;
    sClk = 0;
end

always #10 clk = ~clk;
always #3 sClk = ~sClk;

SIPIfc m(); // on clk
SIPIfc s(); // on sClk
SIPIfcCDC #(.MAX_BYTES(16)) dut(.mClk(clk), .m(m), .sClk(sClk), .s(s));

// Loopback response
assign s.resp = s.req;

// All logic below is in clk clock domain
reg [31:0] cycle = 0;
always @(posedge clk) cycle <= cycle + 1;


reg [4:0] toSend = 1;
reg sendPending = 1;
SIPFlit mReq;
SIPFlit mResp;
assign mResp = m.resp;
assign m.req = mReq;

initial mReq.valid = 0;

reg prevRespValid = 0;
always @(posedge clk) prevRespValid <= mResp.valid;

always @(posedge clk) begin
    // NOTE: xpm_fifo_async has a reset sequence that, at least in simulation,
    // takes a bit over 5000 cycles. Watch out wr_rst_busy in SIPFlitCDC's
    // FIFO if this test starts misbehaving...
    if (sendPending && cycle > 10000) begin
        mReq.valid <= 1;
        mReq.data <= toSend;
        toSend <= toSend - 1;
        sendPending <= 0;
    end else if (mReq.valid) begin
        mReq.valid <= (toSend != 0);
        mReq.data <= toSend;
        toSend <= toSend - 1;
    end else if (mResp.valid && !prevRespValid) begin
        toSend <= ($bits(toSend))'(mResp.data + 1);
    end else if (!mResp.valid && prevRespValid) begin
        sendPending <= 1;
    end
end

always @(posedge clk) begin
    if (mReq.valid) $display("[%d] sending %x", cycle, mReq.data);
    if (mResp.valid) $display("[%d] received %x", cycle, mResp.data);
    if (!mResp.valid && prevRespValid) $display("[%d] round %d done", cycle, toSend-1);

    // Note this tests overflows; actual write depth is MAX_BYTES+1 in fwft
    // mode... at least in theory, this is dependent on the ratio between
    // frequencies!?!?
    if (toSend >= 19 && sendPending) $finish;
    if (cycle > 12000) begin
        $display("[%d] hit cycle limit---deadlocked?", cycle);
        $finish;
    end
end

always @(posedge sClk) if (s.req.valid) $display("[%d] loopback %x", cycle, s.req.data);

endmodule
