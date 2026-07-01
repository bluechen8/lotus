/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

module SIPNet (
        input clk,
        input SIPFlit mReq,
        output SIPFlit mResp
);

SIPIfc m();
assign m.req = mReq;
assign mResp = m.resp;

// First, mux with 3 outputs
SIPIfc muxed[2:0]();
SIPIfcMux #(.N(3)) mux (.clk(clk), .m(m), .s(muxed));

// Then, split output 2 in 6 components with 3 local address bits each
SIPIfc split[6:0]();
SIPIfcSplitter #(.N(7), .K(3)) splitter(.clk(clk), .m(muxed[2]), .s(split));

// Pipeline these split outputs
SIPIfc piped[6:0]();
SIPIfcsPipe #(.N(7)) pipes (.clk(clk), .m(split), .s(piped));

// Endpoints
localparam WL = 16;
localparam NL = 48;
wire [WL-1:0] localRegs [NL-1:0];
wire [NL-1:0] localRegsUpdated;
SIPIfcControlRegs #(.N(NL), .W(WL)) cRegs (.clk(clk),
    .m(muxed[0]), .regs(localRegs), .regsUpdated(localRegsUpdated));

SIPIfcStatusRegs #(.N(NL), .W(WL)) sRegs (.clk(clk),
    .m(muxed[1]), .regs(localRegs));

for (genvar i = 0; i < 6; i = i + 1) begin
    SIPIfcCounters #(.N(8), .W(64)) counters (.clk(clk),
        .m(piped[i]), .inc(localRegsUpdated[8*i +: 8]));
end


// Test counter increments at different rates
reg [31:0] cycle = 0;
always @(posedge clk) cycle <= cycle + 1;
SIPIfcCounters #(.N(4), .W(40)) cycleCounters (.clk(clk),
    .m(piped[6]), .inc({cycle[3:1], 1'b1}));

// OK, what can we do with this?
// address range is (a0 = [0-2], a1 = [0-47]), all addresses are 2 bytes
// a0 = 0 -> write request to reg a1
// a0 = 1 -> read reg a1
// a0 = 2 -> retrieve number of updates to reg a1

endmodule

module TestSIP;

reg clk;
reg rstn;
SIPFlit mReq;
SIPFlit mResp;

`ifdef TEST_SIP_BSV
mkTestSIPNet dut(.CLK(clk), .RST_N(rstn), .req(mReq), .resp(mResp));
`else
SIPNet dut(.clk(clk), .mReq(mReq), .mResp(mResp));
`endif

initial begin
    clk = 0;
    rstn = 0;
    #15 rstn = 1;
end

always #10 clk = ~clk;

reg [31:0] cycle = 0;
always @(posedge clk) begin
    cycle <= cycle + 1;
end

// We could write a low-level FSM to access mReq/mResp directly, but...
localparam S_AXI_ADDR_WIDTH = 16;
localparam S_AXI_DATA_WIDTH = 32;
reg [39:0] req;
reg [3:0] reqSize;
wire [31:0] rdata;
reg [15:0] araddr;
reg awvalid = 0;
reg wvalid = 0;
reg arvalid = 0;
reg rready = 0;
wire awready, bvalid, wready, arready, rvalid;
AxiLiteToSIP#(
    .S_AXI_ADDR_WIDTH(S_AXI_ADDR_WIDTH),
    .S_AXI_DATA_WIDTH(S_AXI_DATA_WIDTH)
) adapter (
    .clk(clk),

    .awaddr({req[7:0], reqSize, 4'b0}),
    .awvalid(awvalid),
    .awready(awready),

    .wdata(req[39:8]),
    .wstrb(4'b1111),
    .wvalid(wvalid),
    .wready(wready),

    .bresp(),
    .bvalid(bvalid),
    .bready(1'b1),

    .araddr(araddr),
    .arvalid(arvalid),
    .arready(arready),

    .rdata(rdata),
    .rresp(),
    .rvalid(rvalid),
    .rready(rready),

    .interrupt(),
    .ap_start(),
    .ap_done(1'b0),
    .ap_ready(1'b0),
    .ap_idle(1'b0),

    .sReq(mReq),
    .sResp(mResp)
);

enum reg [3:0] {DeqReq, FeedWAddr, FeedWData, WaitForResp, ReadHi, ReadLo, ReadSz, Next} xs = DeqReq;

reg [7:0] a1 = 0;
reg [7:0] reqType = 0;

typedef struct {
    logic [39:0] data;
    logic [7:0] reqSize;
    logic [3:0] reqType;
    string msg;
} Req;
Req extraReqs[$];

initial begin
    extraReqs.push_back('{{24'b0, 8'b0, 8'b1}, 0, 0, "length-zero request"});
    extraReqs.push_back('{{24'b0, 8'b0, 8'b1}, 15, 0, "request with length out of bounds"});
    extraReqs.push_back('{{24'b0, 8'b0, 8'b1}, 1, 0, "too-short request (all address, no data for mux)"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'b1}, 2, 1, "read of control reg modified by later reqs"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'b0}, 2, 0, "too-short control reg write (address only)"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'b1}, 4, 1, "too-long read of prev control reg write"});
    extraReqs.push_back('{{24'h012345, 8'b1, 8'b0}, 3, 0, "too-short control reg write (1 byte)"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'b1}, 3, 1, "too-long read of prev control reg write"});
    extraReqs.push_back('{{24'h89abcd, 8'b1, 8'b0}, 5, 0, "too-long control reg write (3 bytes)"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'b1}, 2, 1, "read of prev control reg write"});
    extraReqs.push_back('{{24'habcdef, 8'b1, 8'd2}, 5, 2, "too-long read of counter register"});
    extraReqs.push_back('{{24'b0, 8'd48, 8'd2}, 2, 2, "request to counter incremented every cycle"});
    extraReqs.push_back('{{24'b0, 8'd49, 8'd2}, 2, 2, "request to counter incremented on cycle[1]"});
    extraReqs.push_back('{{24'b0, 8'd50, 8'd2}, 2, 2, "request to counter incremented on cycle[2]"});
    extraReqs.push_back('{{24'b0, 8'd51, 8'd2}, 2, 2, "request to counter incremented on cycle[3]"});
    extraReqs.push_back('{{24'b0, 8'd52, 8'd2}, 2, 2, "request to out-of-bounds counter"});
    extraReqs.push_back('{{24'b0, 8'd51, 8'd2}, 6, 0, "multi-write request, part 1 (AXILiteToSIP test)"});
    extraReqs.push_back('{{24'b0, 8'd51, 8'd2}, 6, 0, "multi-write request, part 2 (AXILiteToSIP test)"});
    extraReqs.push_back('{{24'b0, 8'd51, 8'd3}, 2, 2, "multi-write request, part 3 (AXILiteToSIP test)"});
end

always @(posedge clk) begin
    if (xs == DeqReq) begin
        //$display("[%d] Setting req %x", cycle, req);
        if (a1 <= 48) begin
            // First, test all components
            req <= {cycle[23:0], a1, reqType};
            reqSize <= (reqType == 0)? 4'd4 : 4'd2;
        end else begin
            // Test extra requests
            req <= extraReqs[0].data;
            reqSize <= extraReqs[0].reqSize;
            reqType <= extraReqs[0].reqType;
            $write("[%d] Starting test: ", cycle);
            $display(extraReqs[0].msg);
            extraReqs.pop_front();
        end
        awvalid <= 1;
        xs <= FeedWAddr;
    end else if ((xs == FeedWAddr) && awready) begin
        $display("[%d] Feeding req %x (%d bytes)", cycle, req, reqSize);
        awvalid <= 0;
        wvalid <= 1;
        xs <= FeedWData;
    end else if (xs == FeedWData && wready) begin
        //$display("[%d] Feeding req data", cycle);
        wvalid <= 0;
        xs <= WaitForResp;
    end else if ((xs == WaitForResp) && bvalid) begin
        $display("[%d] Req done", cycle);
        xs <= (reqType == 0)? Next : ((reqType == 1)? ReadLo : ReadHi);
        araddr <= (reqType == 1)? 'h200 : 'h204;
        arvalid <= (reqType != 0);
        rready <= (reqType != 0);
    end else if (xs == ReadHi || xs == ReadLo || xs == ReadSz) begin
        if (arready) arvalid <= 0;
        if (rvalid) begin
            $display("[%d] Data[%x]: %x", cycle, araddr, rdata);
            if (xs == ReadHi) begin
                araddr <= araddr - 4;
                arvalid <= 1;
                xs <= ReadLo;
            end else if (xs == ReadLo) begin
                araddr <= 'h10;
                arvalid <= 1;
                xs <= ReadSz;
            end else xs <= Next;
        end
    end else if (xs == Next) begin
        reqType <= (reqType + 1) % 3;
        if (reqType == 2 && a1 <= 48) a1 <= a1 + 1;
        if (extraReqs.size() == 0) $finish;
        xs <= DeqReq;
    end
end
endmodule
