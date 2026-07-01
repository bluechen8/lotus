/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

/* Simple Interface Protocol
 * 
 * SIP is a single-master, multi-slave protocol meant for communication
 * between a single host (master) and multiple endpoint components distributed
 * throughout the design (slaves).
 *
 * The motivation for SIP is to make it easy and simple for the host to
 * interface with entities spread across the design, like control and status
 * registers, or performance counters. This communication is already very low
 * bandwidth: the host sends one request at a time, and it is far away. So the
 * performance of this interconnect is in the noise, and protocols like
 * AXILite are both completely overkill for this purpose, and too hard to use.
 *
 * SIP is designed to (1) be extremely cheap, (2) support a variety of
 * components, e.g., streaming in configurations or reading performance
 * counters that may have variable size.
 *
 * 1. Protocol basics
 *
 * SIP is a request-response protocol. The master can issue a request at
 * a time, directed to one slave. Requests and responses are variable-sized.
 * Requests start with an address, followed by an operation and appropriate
 * data (e.g., for a write, the value to be written).
 *
 * All requests must have a response. This response can be a simple
 * acknowledgement.
 *
 * 2. Physical layer
 *
 * SIP requests and responses consist of one or more *flits*. A flit is
 * encodes a single byte of data, and is transmitted over one cycle. The flit
 * also includes a valid bit to denote data transmission. Multi-byte messages
 * are encoded using multiple flits, and must be sent through a channel in
 * successive, *contiguous* cycles (no breaks are allowed between flits).
 *
 * Communication channels have **no backpressure**. Because there is only one
 * request at a time from the master, the only requirement on slaves is that
 * they must be able to take one request without interruption, which is
 * trivial to implement. This means no valid-ready handshaking or interlocks.
 *
 * A full SIP interface consists of a request channel and a response channel,
 * each of which transfer one flit per cycle. Each channel is one-way, and can
 * be auto-pipelined trivially.
 * 
 * SIP is designed so that the valid signal can be ahead-pipelined. This
 * enables detecting and acting on message arrival and termination:
 *   lastFlit = req.valid && !reqNext.valid
 *   firstFlit = req.valid && !reqPrev.valid
 *
 * However, this ahead-pipelining should be done, if needed, to improve fmax
 * and reduce logic use, and not to increase performance, which isn't the goal.
 *
 * 3. Request format
 *
 * 3.1 Addressing
 *
 * Requests always start with an address, which determines the slave the
 * request is routed to. Each request has multiple 1-byte *components*. SIP
 * muxes work by peeling the first component, and using it to route to the
 * appropriate slave. Thus, addresses reflect the hierarchy in the system.
 *
 * 3.2 Data
 *
 * Requests may have data flits following the address flits. For example,
 * a write request would include the write address followed by the data to
 * write, whereas a read request needs no data. The data may also be
 * some other command.
 *
 * Data must be transmitted in little-endian order (the first flit encodes
 * the least-significant values). This facilitates writes to registers of
 * variable sizes.
 *
 * 4. Response format
 *
 * All requests must be followed by a response. For read requests, data must
 * be supplied in little-endian order. For write requests, or requests that
 * carry no data, it is sufficient to supply a one-cycle acknowledgement (ACK).
 * To simplify logic, this ACK can have don't cares in the data field.
 *
 * 5. No fixed size limits for requests and responses
 *
 * SIP does not impose a fixed limit on the size of requests or responses.
 * However, in practice each implementation will have a natural maximum size,
 * and some components (like the SIP master interface or clock-domain-crossing
 * FIFOs that implement store-and-forward) need to be designed with the
 * maximum size in mind.
 */

/* 1. BASIC COMPONENTS
 *
 * These components perform basic operations like serialization and
 * deserialization. These are building blocks of slave endpoints (and the
 * master endpoint too), and are NOT meant to be used directly by designs.
 *
 * These components always operate in SIPFlits (see SIPIfc below)
 */

`timescale 1ps/1ps

`include "sip.vh"

// Deserializes a SIP stream into a register value. Works with values of up to
// W bits, but with narrower values as well. This is useful to deserialize to
// control registers of multiple sizes.
module SIPDeserializer #(
    parameter W = 32 // value bits
) (
    input clk,
    input SIPFlit req,
    output SIPFlit resp,
    output [W-1:0] value,
    output valueUpdated // one-cycle pulse when val is updated
);

localparam BEATS = (W+7)/8;
localparam BW = (BEATS == 1)? 1 : $clog2(BEATS);

reg [BW:0] curBeat = 0;
reg [8*BEATS-1:0] valueReg;
reg prevValid = 0;

always_ff @(posedge clk) begin
    if (req.valid) begin
        valueReg[8*curBeat +: 8] <= req.data;
        curBeat <= curBeat + 1;
    end else if (prevValid) curBeat <= 0; // use reset input to avoid CLB use
    prevValid <= req.valid;
end

assign value = valueReg;
assign valueUpdated = prevValid && !req.valid;

// Send a 1-beat ACK after receiving message
assign resp.valid = valueUpdated;
assign resp.data = {4'h1, 4'(curBeat)}; //8'bxxxxxxxx;  // can be anything

endmodule


// Serializes a W-bit value to a SIP stream. This is not a full SIP component;
// it produces the response only
module SIPSerializer #(
    parameter W = 32,
    parameter SAMPLE = 1 // 0 to not sample, use only if val input is stable or you'll transmit garbage
) (
    input clk,
    input [W-1:0] value,
    input sendValue, // one-cycle pulse when value should be serialized through resp
    output SIPFlit resp
);

localparam BEATS = (W+7)/8;

reg [$clog2(BEATS)-1:0] curBeat = 0;
reg [8*BEATS-1:0] valueReg;

if (SAMPLE == 0) begin
    always_comb begin
        valueReg = value;
    end
end else begin
    always_ff @(posedge clk) begin
        if (sendValue) valueReg <= value;
    end
end

reg sending = 0;

always_ff @(posedge clk) begin
    if (sendValue) begin
        //$display("[%d] serializer: sending %x", $time, value);
        sending <= 1;
        curBeat <= 0;
    end else if (sending && curBeat == $clog2(BEATS)'(BEATS-1)) begin
        sending <= 0;
        curBeat <= {$clog2(BEATS){1'bx}};
    end else if (sending) begin
        curBeat <= curBeat + 1;
    end
end

assign resp.valid = sending;
assign resp.data = valueReg[8*curBeat +: 8];

endmodule


// Peel one address component off the SIP request
module SIPAddrPeeler #(
    parameter N = 256
) (
    input clk,
    input SIPFlit req,
    output SIPFlit peeledReq,
    output [$clog2(N)-1:0] addr
);

initial assert (N <= 256);

reg [$clog2(N)-1:0] addrReg;
reg prevValid = 0;

always_ff @(posedge clk) begin
    if (req.valid && !prevValid) begin
        assert({1'b0, req.data} < 9'(N)); // check addr is in bounds
        addrReg <= $clog2(N)'(req.data);
    end
    prevValid <= req.valid;
end

assign addr = addrReg;
assign peeledReq.data = req.data;
assign peeledReq.valid = req.valid && prevValid;

endmodule


/* 2. SLAVE ENDPOINTS
 *
 * These modules implement SIP slaves that take a request and produce a reply.
 * They are the components spread throughout the design that provide control
 * and status functionality to the master.
 *
 * Currently, these modules implement control registers (written by master),
 * status registers (read by master), and counters (incremented by the design
 * and read by master).
 * 
 * Implement other slave endpoints as needed. Ideas:
 *  - Generic interface to memories in the design
 *  - FIFOs
 *  - Cyclic logs (e.g., track last N events)
 */

// Control registers --- written by SIP master, read/used by design 
// NOTE: If you read these registers one by one, write a variant of this that
// uses LUTRAM. This will synthesize to flat registers.
module SIPControlRegs #(
    parameter N = 16,
    parameter W = 32
) (
    input clk,
    input SIPFlit req,
    output SIPFlit resp,
    output reg [W-1:0] regs [N-1:0],
    output reg [N-1:0] regsUpdated // one-cycle pulse when a register is updated
);

initial begin
    for (integer i = 0; i < N; i = i + 1) regs[i] = 0;
    regsUpdated = 0;
end

wire SIPFlit peeledReq;
wire [$clog2(N)-1:0] addr;

SIPAddrPeeler#(.N(N)) addrPeeler (
    .clk(clk),
    .req(req),
    .peeledReq(peeledReq),
    .addr(addr)
);

wire [W-1:0] writeValue;
wire writeEnable;
SIPFlit dResp;

SIPDeserializer #(.W(W)) deserializer (
    .clk(clk),
    .req(peeledReq),
    .resp(dResp),
    .value(writeValue),
    .valueUpdated(writeEnable)
);

always @(posedge clk) begin
    if (writeEnable) begin
        //$display("[%d] cReg[%d] <= %x", $time, addr, writeValue);
        regs[addr] <= writeValue;
        regsUpdated[addr] <= 1;
    end else regsUpdated <= 0;
end

reg prevValid = 0;
reg prevPrevValid = 0;
always @(posedge clk) begin
    prevValid <= req.valid;
    prevPrevValid <= prevValid;
end

SIPFlit errFlit;
assign errFlit.valid = 1;
assign errFlit.data = 8'hCC;

// Because we peel off a byte, we need to throw an error when the request is
// just that byte, as the deserializer sees nothing
wire tooShortReq = !req.valid && prevValid && !prevPrevValid;

assign resp = tooShortReq? errFlit : dResp;

endmodule


// Status registers --- set/given by circuit, read by SIP master
// You can use regs < W bits; simply set the extra bits to 0 or X
// NOTE: If you set these registers one by one, write a variant of this that
// uses LUTRAM. This will synthesize to flat registers.
module SIPStatusRegs #(
    parameter N = 16,
    parameter W = 32
) (
    input clk,
    input SIPFlit req,
    output SIPFlit resp,
    input wire [W-1:0] regs [N-1:0]
);

wire SIPFlit peeledReq; // unused, since read reqs are address only
wire [$clog2(N)-1:0] addr;

SIPAddrPeeler#(.N(N)) addrPeeler (
    .clk(clk),
    .req(req),
    .peeledReq(peeledReq),
    .addr(addr)
);

reg prevValid = 0;
always_ff @(posedge clk) prevValid <= req.valid;

// Serializer need not sample if data is a single beat
SIPSerializer #(.W(W), .SAMPLE(W > 8)) serializer (
    .clk(clk),
    .resp(resp),
    .value(regs[addr]),
    .sendValue(!req.valid && prevValid)
);

endmodule

// Performance/event counters: Incremented by circuit, read by SIP master
// This implementation leverages counter semantics to use LUTRAM, and it's
// much more efficient than exposing a bunch of separate counters as status
// registers.
module SIPCounters #(
    parameter N = 16,
    parameter W = 64
) (
    input clk,
    input SIPFlit req,
    output SIPFlit resp,
    input [N-1:0] inc // each counter can be incremented once per cycle
);

localparam B = $clog2(N);

// This implementation uses two levels of storage: preCounters enable
// gathering concurrent updates to all events; preCounters are cyclically
// appended to the wider counters regfile
reg [B-1:0] preCounters [N-1:0];

(* ram_style = "distributed" *) // if this is very large, it can be made BRAM
reg [W-1:0] counters [N-1:0];

initial begin
    // N should be a power of two---this eliminates out-of-bounds addresses.
    // If you want fewer counters, give a narrower inc and the synthesizer
    // should optimize out all the non-incremented preCounters.
    assert((N & (N-1)) == 0);

    for (int i = 0; i < N; i = i + 1) preCounters[i] = 0;
    for (int i = 0; i < N; i = i + 1) counters[i] = 0;
end

reg [B-1:0] incAddr = 0;
// Perform a narrow preCounter addition, then add that up to the read counter.
// vivado synthesizes counters[incAddr] + preCounters[incAddr] + inc[incAddr] as
// 2 W-bit adders in series and timing is much worse. You'd think this would be
// common enough...
// NOTE: B+1 bits so this doesn't wrap around even with power-of-2 counters
wire [B:0] newPreCounter = {1'b0, preCounters[incAddr]} + {{(B-1){1'b0}}, inc[incAddr]};
wire [W-1:0] newCounter = counters[incAddr] + {{(W-B-1){1'b0}}, newPreCounter};

always_ff @(posedge clk) begin
    counters[incAddr] <= newCounter;
    incAddr <= incAddr + 1;
end

for (genvar i = 0; i < N; i = i + 1) begin
    always_ff @(posedge clk) begin
        if (incAddr == i) preCounters[i] <= 0;
        else if (inc[i]) preCounters[i] <= preCounters[i] + 1;
    end
end

// SIP read logic: To avoid a second read port, we wait for incAddr to pass by
// our desired address
wire SIPFlit peeledReq; // unused, since read reqs are address only
wire [B-1:0] addr;

SIPAddrPeeler#(.N(N)) addrPeeler (
    .clk(clk),
    .req(req),
    .peeledReq(peeledReq),
    .addr(addr)
);

reg prevValid = 0;
reg pendingResp = 0;
always_ff @(posedge clk) begin
    prevValid <= req.valid;
    if (!pendingResp && !req.valid && prevValid) pendingResp <= 1;
    else if (pendingResp && (incAddr == addr)) pendingResp <= 0;
    
    //if (pendingResp) $display("pending resp on %x | incAddr=%x | newCounter = %x", addr, incAddr, newCounter);
end

// Serializer always needs to sample (this data changes every cycle)
SIPSerializer #(.W(W), .SAMPLE(1)) serializer (
    .clk(clk),
    .resp(resp),
    .value(newCounter), // use old value if this impacts timing closure!
    .sendValue(pendingResp && (incAddr == addr))
);

endmodule


/* 3. TRANSPORT LAYER
 *
 * These modules let you build a network that connects the (single) master to
 * all the slaves in the design:
 *  - SIPMux multiplexes multiple slaves into one. It consumes the first address
 *    component of the request when doing so.
 *  - SIPSplitter is similar to SIPMux, but does not consume the first address
 *    component of the request: it filters these requests by range.
 *    
 *  These modules are COMBINATIONAL by default; SIP*Pipe modules enable
 *  auto-pipelining the request and response channels.
 */

module SIPMux #(
    parameter N = 32
) (
    input clk,
    input SIPFlit mReq,
    output SIPFlit mResp,
    output SIPFlit sReq[N-1:0],
    input SIPFlit sResp[N-1:0]
);

reg [$clog2(N)-1:0] curAddr = 0;
reg [N-1:0] enable = 0;
reg prevValid = 0;
reg prevPrevValid = 0;

// Req first word sets right enable, sets curAddr
for (genvar i = 0; i < N; i = i + 1) begin
    assign sReq[i].data = mReq.data;
    assign sReq[i].valid = (mReq.valid && enable[i]);
end

always @(posedge clk) begin
    if (mReq.valid && !prevValid) begin
        assert(mReq.data < N);
        curAddr <= (mReq.data < N)? $clog2(N)'(mReq.data) : 0;
        enable[$clog2(N)'(mReq.data)] <= 1;
        //$display("[%d] mux req to %d", $time, mReq.data);
    end else if (prevValid && !mReq.valid) begin
        //$display("[%d] mux req done", $time);
        enable <= 0;
    end

    //if (mReq.valid)  $display("[%d] mux req %x", $time, mReq.data);
    //if (mResp.valid) $display("[%d] mux resp %x", $time, mResp.data);

    prevValid <= mReq.valid;
    prevPrevValid <= prevValid;
end

wire isInvalidAddr = mReq.valid && !prevValid && (mReq.data >= N);

// Because we peel off a byte, we need to throw an error when the request is
// just that byte, as the consumer sees nothing
wire tooShortReq = !mReq.valid && prevValid && !prevPrevValid;

SIPFlit errFlit;
assign errFlit.valid = 1;
assign errFlit.data = {6'b111111, isInvalidAddr, tooShortReq};

// Resp just muxes from curAddr
assign mResp = (isInvalidAddr || tooShortReq)? errFlit : sResp[curAddr];

endmodule

// Split requests by address range, without consuming the leading address
// component. Useful if you want to combine different endpoint types under the
// same address component.
module SIPSplitter #(
    parameter N = 32, // number of slave interfaces
    parameter K = 3  // bits of address per slave interface
) (
    input clk,
    input SIPFlit mReq,
    output SIPFlit mResp,
    output SIPFlit sReq[N-1:0],
    input SIPFlit sResp[N-1:0]
);

localparam M = 2 ** K;
localparam MAX = M*N;
initial assert(MAX <= 256);

reg [$clog2(N)-1:0] curAddr = 0;
reg [N-1:0] enable = 0;
reg prevValid = 0;

wire firstFlit = mReq.valid && !prevValid;

// Req first word sets right enable, sets curAddr
for (genvar i = 0; i < N; i = i + 1) begin
    assign sReq[i].data = firstFlit? {(8-K)'(0), mReq.data[K-1:0]} : mReq.data;
    assign sReq[i].valid = firstFlit? (mReq.data[7:K] == i) : (mReq.valid && enable[i]);
end

always_ff @(posedge clk) begin
    if (mReq.valid && !prevValid) begin
        assert(mReq.data < MAX);
        curAddr <= ((mReq.data >> K) < N)? $clog2(N)'(mReq.data >> K) : 0;
        enable[$clog2(N)'(mReq.data >> K)] <= 1;
        //$display("[%d] splitter req to %d", $time, mReq.data);
    end else if (prevValid && !mReq.valid) begin
        enable <= 0;
        //$display("[%d] splitter req done", $time);
    end

    //if (mResp.valid) $display("[%d] splitter resp %x", $time, mResp.data);
    
    //if (sReq[0].valid) $display("[%d] splitter req[0] %x", $time, sReq[0].data);
    //if (sResp[0].valid) $display("[%d] splitter resp[0] %x", $time, sResp[0].data);
    
    prevValid <= mReq.valid;
end

SIPFlit errFlit;
assign errFlit.valid = 1;
assign errFlit.data = 8'hEE;
wire isInvalidAddr = mReq.valid && !prevValid && (mReq.data >= MAX);

// Resp just muxes from curAddr
assign mResp = isInvalidAddr? errFlit : sResp[curAddr];

endmodule


// Pipelining; leverages vivado auto-pipelining
(* autopipeline_module = "yes" *)
module SIPFlitPipe (
    input clk,
    input SIPFlit flit,
    (* autopipeline_group = "flit", autopipeline_limit = 24 *)
    output SIPFlit pipedFlit
);
//assign pipedFlit = flit; // TODO: does having 0-cycle pipes by default work?
                           // If so, we could throw them everywhere!
always_ff @(posedge clk) pipedFlit <= flit;
endmodule

/* 4. VARIANTS WITH HIGHER-LEVEL SIPIfc INTERFACE
 * 
 * Wrappers for endpoints and transport layer using SIPIfc. SV interfaces ease
 * connections, so if your tool supports this, you should use these; however,
 * interfaces have issues with compatibility and testing (e.g., they can't be
 * used as top-level modules, vivado has some restrictions on use, etc.).
 * That's why the components are all implemented using SIPFlit inputs and
 * outputs, rather than by using SIPIfc directly.
 */

// Slave endpoints
module SIPIfcControlRegs #(
    parameter N = 16,
    parameter W = 32
) (
    input clk,
    SIPIfc.master m,
    output wire [W-1:0] regs [N-1:0],
    output wire [N-1:0] regsUpdated
);

SIPControlRegs #(.N(N), .W(W)) controlRegs (
    .clk(clk),
    .req(m.req),
    .resp(m.resp),
    .regs(regs),
    .regsUpdated(regsUpdated)
);

endmodule

module SIPIfcStatusRegs #(
    parameter N = 16,
    parameter W = 32
) (
    input clk,
    SIPIfc.master m,
    input wire [W-1:0] regs [N-1:0]
);

SIPStatusRegs #(.N(N), .W(W)) statusRegs (
    .clk(clk),
    .req(m.req),
    .resp(m.resp),
    .regs(regs)
);

endmodule

module SIPIfcCounters #(
    parameter N = 16,
    parameter W = 64
) (
    input clk,
    SIPIfc.master m,
    input [N-1:0] inc // each counter can be incremented once per cycle
);

SIPCounters #(.N(N), .W(W)) counters (
    .clk(clk),
    .req(m.req),
    .resp(m.resp),
    .inc(inc)
);

endmodule


// Transport layer
module SIPIfcMux #(
    parameter N = 32
) (
    input clk,
    SIPIfc.master  m,
    SIPIfc.slave  s[N-1:0]
);

wire SIPFlit mReq;
wire SIPFlit mResp;
wire SIPFlit sReq[N-1:0];
wire SIPFlit sResp[N-1:0];

SIPMux #(.N(N)) mux (
    .clk(clk),
    .mReq(mReq),
    .mResp(mResp),
    .sReq(sReq),
    .sResp(sResp)
);

assign mReq = m.req;
assign m.resp = mResp;

for (genvar i = 0; i < N; i = i + 1) begin
    assign s[i].req = sReq[i];
    assign sResp[i] = s[i].resp;
end

endmodule

// Copy-paste of SIPIfcMux (consider a macro if this is repeated further)
module SIPIfcSplitter #(
    parameter N = 32,
    parameter K = 3
) (
    input clk,
    SIPIfc.master  m,
    SIPIfc.slave  s[N-1:0]
);

wire SIPFlit mReq;
wire SIPFlit mResp;
wire SIPFlit sReq[N-1:0];
wire SIPFlit sResp[N-1:0];

SIPSplitter #(.N(N), .K(K)) splitter (
    .clk(clk),
    .mReq(mReq),
    .mResp(mResp),
    .sReq(sReq),
    .sResp(sResp)
);

assign mReq = m.req;
assign m.resp = mResp;

for (genvar i = 0; i < N; i = i + 1) begin
    assign s[i].req = sReq[i];
    assign sResp[i] = s[i].resp;
end

endmodule

module SIPIfcPipe (
    input clk,
    SIPIfc.master m,
    SIPIfc.slave s
);

SIPFlitPipe reqPipe(.clk(clk), .flit(m.req), .pipedFlit(s.req));
SIPFlitPipe respPipe(.clk(clk), .flit(s.resp), .pipedFlit(m.resp));

endmodule

module SIPIfcsPipe #(
    parameter N = 16
) (
    input clk,
    SIPIfc.master m[N-1:0],
    SIPIfc.slave s[N-1:0]
);

for (genvar i = 0; i < N; i = i + 1) begin
    SIPIfcPipe ifcPipe(.clk(clk), .m(m[i]), .s(s[i]));
end

endmodule


/* 5. AXILITE-TO-SIP HOST INTERFACE
 *
 * This module converts from AXI-Lite 4 to a SIP master interface, to let the
 * host communicate with the SIP network using a standard interface. It
 * targets the Xilinx XRT interface. Both XRT IPs (just registers but no
 * control) and XRT kernels with AP_CTRL_HS control (sequential execution
 * model) are supported.
 */

// To translate between protocols,
// - Write transactions initiate SIP requests
// - Read transactions receive responses
//
// AXI/Xilinx introduces two restrictions on addresses:
// - 0x0-0xc are reserved for AP_CTRL_HS registers
// - Addresses must be aligned
//
// We pack request data into the write channel as follows:
// - Address 0xD...DS0
// - Data    0xDD...DD
// Where:
// - D are data nibbles (both address and data flits)
// - S is a control nibble that denotes data size. S is a non-zero value (this
//   guarantees we never use control-reserved addresses) that denotes the number
//   of data bytes, or the max number of data bytes that fit in address + data
//   + 1 if this is a partial request. This allows long SIP requests to span
//   multiple AXI write requests.
//  
// Reads are simpler: we allocate a buffer of up to the maximum request size;
// 0x10 returns the number of bytes in the response; and reads to 0x20+ return
// the response in little-endian order. Reads are not returned until the SIP
// response is fully received, so no chance of partial reads. For writes where
// the read is just an ACK, the host need not issue a read to fetch the
// response.
//
// FIXME: Code needs cleanup
//

module AxiLiteToSIP #(
    parameter S_AXI_ADDR_WIDTH = 16, // NOTE: XRT max is 16!
    parameter S_AXI_DATA_WIDTH = 32, // NOTE: Protocol max is 64
    parameter AP_CTRL_HS = 1, // set to 0 for IP (saves logic)
    parameter SIP_MAX_REQ_BYTES = 16,
    parameter SIP_MAX_RESP_BYTES = 16
)(
    input clk,

    // AXILite 4 slave interface
    input  wire [S_AXI_ADDR_WIDTH-1:0] awaddr,
    input  wire awvalid,
    output wire awready,
    
    input  wire [S_AXI_DATA_WIDTH-1:0] wdata,
    input  wire [S_AXI_DATA_WIDTH/8-1:0] wstrb,
    input  wire wvalid,
    output wire wready,
    
    output wire [1:0] bresp,
    output wire bvalid,
    input  wire bready,

    input  wire [S_AXI_ADDR_WIDTH-1:0] araddr,
    input  wire arvalid,
    output wire arready,
    
    output wire [S_AXI_DATA_WIDTH-1:0] rdata,
    output wire [1:0] rresp,
    output wire rvalid,
    input  wire rready,

    // Used only with AP_CTRL_HS == 1
    output wire interrupt,
    output wire ap_start,
    input  wire ap_done,
    input  wire ap_ready,
    input  wire ap_idle,
 
    // SIP interface (to slaves)
    output SIPFlit sReq,
    input  SIPFlit sResp
);

// Address info for AP_CTRL_HS signals
// 0x00 : Control signals
//        bit 0  - ap_start (Read/Write/COH)
//        bit 1  - ap_done (Read/COR)
//        bit 2  - ap_idle (Read)
//        bit 3  - ap_ready (Read)
//        bit 7  - auto_restart (Read/Write)
//        others - reserved
// 0x04 : Global Interrupt Enable Register
//        bit 0  - Global Interrupt Enable (Read/Write)
//        others - reserved
// 0x08 : IP Interrupt Enable Register (Read/Write)
//        bit 0  - Channel 0 (ap_done)
//        bit 1  - Channel 1 (ap_ready)
//        others - reserved
// 0x0c : IP Interrupt Status Register (Read/TOW)
//        bit 0  - Channel 0 (ap_done)
//        bit 1  - Channel 1 (ap_ready)
//        others - reserved
// (SC = Self Clear, COR = Clear on Read, TOW = Toggle on Write, COH = Clear on Handshake)
localparam
    ADDR_AP_CTRL         = 'h00,
    ADDR_GIE             = 'h04,
    ADDR_IER             = 'h08,
    ADDR_ISR             = 'h0c;

typedef enum logic [2:0] {WAddr, WData, ReqLoad, RespWait, WResp} WState;
typedef enum logic {RAddr, RResp} RState;

WState wState = WAddr;
RState rState = RAddr;

// Handshaking is purely state-driven
assign awready = (wState == WAddr);
assign wready = (wState == WData);
assign bvalid = (wState == WResp);

assign arready = (rState == RAddr);
assign rvalid = (rState == RResp);

assign bresp = 0;
assign rresp = 0;

wire awHs = awready && awvalid;
wire wHs = wready && wvalid;
wire bHs = bready && bvalid;
wire arHs = arready && arvalid && !sResp.valid; // don't take in read reqs while we're receiving a SIP response
wire rHs = rready && rvalid;

// Write channel and SIP request forming
reg [S_AXI_ADDR_WIDTH-1:0] wAddr;
always_ff @(posedge clk) if (awHs) wAddr <= awaddr;
wire wAddrIsSip = wAddr[S_AXI_ADDR_WIDTH-1:4] != 0;

reg [S_AXI_DATA_WIDTH-1:0] wData;
always_ff @(posedge clk) if (wHs) wData <= wdata;

reg prevRespValid = 0;
always @(posedge clk) prevRespValid <= sResp.valid;

// FIXME: Reorg code
reg [$clog2((S_AXI_DATA_WIDTH+S_AXI_ADDR_WIDTH-8)/8)-1:0] reqEnqPos = 0;

localparam NumUseableBytesInReq   = 4'((S_AXI_ADDR_WIDTH+S_AXI_DATA_WIDTH)/8)-1; // 5 for (16b addr, 32b data)

wire reqIsFinal = (wAddr[7:4] != (NumUseableBytesInReq+1));
wire consLastReqByteIfReqIsFinal    = (reqEnqPos == $bits(reqEnqPos)'(wAddr[7:4]-4'd1));
wire consLastReqByteIfReqIsNotFinal = (reqEnqPos == $bits(reqEnqPos)'(NumUseableBytesInReq-1));

wire doneReqIsFinal    =  reqIsFinal && consLastReqByteIfReqIsFinal;
wire doneReqIsNotFinal = !reqIsFinal && consLastReqByteIfReqIsNotFinal;

always_ff @(posedge clk) begin
    if (awHs) wState <= WData;
    else if (wHs) wState <= wAddrIsSip? ReqLoad : WResp;
    else if ((wState == ReqLoad)) begin
        if (doneReqIsFinal) begin
            wState <= RespWait;
        end else if (doneReqIsNotFinal) begin
            wState <= WResp;
        end
    end else if ((wState == RespWait) && (!sResp.valid && prevRespValid)) wState <= WResp;
    else if (bHs) wState <= WAddr;
    //if (wState == RespWait) $display("wState = %s sResp = %d %x", wState.name(), sResp.valid, sResp.data);
end


// Use SRLs for the FIFO
reg [SIP_MAX_REQ_BYTES-1:0] reqFifo [7:0];
reg [$clog2(SIP_MAX_REQ_BYTES):0] reqFifoElems = 0; // note 1 more bit than needed for indexing

wire reqEnq = (wState == ReqLoad);
wire [S_AXI_DATA_WIDTH+S_AXI_ADDR_WIDTH-8-1:0] reqEnqData = {wData, wAddr[S_AXI_ADDR_WIDTH-1:8]};

initial sReq.valid = 0;

always @(posedge clk) begin
    if (wState == ReqLoad) begin
        for (integer b = 0; b < 8; b = b + 1) begin
            reqFifo[b] <= {reqFifo[b][SIP_MAX_REQ_BYTES-2:0], reqEnqData[8*reqEnqPos+b]};
        end
        reqFifoElems <= reqFifoElems + 1;
        if (doneReqIsNotFinal) begin
            reqEnqPos <= 0;
        end else begin
            // NOTE: We don't need to reset reqEnqPos here if it's 
            //       doneReqIsFinal because RespWait will do it
            reqEnqPos <= reqEnqPos + 1;
        end
    end else if (wState == RespWait) begin
        if ((reqFifoElems != 0) && !sResp.valid) begin
            sReq.valid <= 1;
            for (integer b = 0; b < 8; b = b + 1) begin
                sReq.data[b] <= reqFifo[b][reqFifoElems-1];
            end
            reqFifoElems <= reqFifoElems-1;
        end else begin
            sReq.valid <= 0;
            reqEnqPos <= 0;
            reqFifoElems <= 0;
        end
    end
end

// Read/response side
reg [S_AXI_DATA_WIDTH-1:0] rData;
assign rdata = rData;

always_ff @(posedge clk) begin
    if (arHs) rState <= RResp;
    else if (rHs) rState <= RAddr;
end

localparam BYTES_PER_WORD = S_AXI_DATA_WIDTH/8;
reg [S_AXI_DATA_WIDTH-1:0] respBuffer [(SIP_MAX_RESP_BYTES/BYTES_PER_WORD)-1:0];
reg [$clog2(SIP_MAX_RESP_BYTES):0] respBytes = 0;
wire [$clog2(SIP_MAX_RESP_BYTES):0] respPos = sResp.valid? (prevRespValid? respBytes : 0) : ($clog2(SIP_MAX_RESP_BYTES)+1)'(araddr);

always_ff @(posedge clk) begin
    if (sResp.valid) begin
        //$display("Writing sResp %x into %x | %x", sResp.data, respPos, respBytes);
        respBuffer[respPos[$clog2(SIP_MAX_RESP_BYTES)-1:$clog2(BYTES_PER_WORD)]][8*respPos[$clog2(BYTES_PER_WORD)-1:0] +: 8] <= sResp.data;
        respBytes <= respPos + 1;
    end
end

// AP_CTRL_HS logic
reg                           int_ap_idle = 1'b0;
reg                           int_ap_ready = 1'b0;
reg                           int_ap_done = 1'b0;
reg                           int_ap_start = 1'b0;
reg                           int_auto_restart = 1'b0;
reg                           int_gie = 1'b0;
reg  [1:0]                    int_ier = 2'b0;
reg  [1:0]                    int_isr = 2'b0;

assign interrupt = int_gie & (|int_isr);
assign ap_start  = int_ap_start;

if (AP_CTRL_HS) begin
    always_ff @(posedge clk) begin
        if (wHs && wAddr == ADDR_AP_CTRL && wstrb[0] && wdata[0])
            int_ap_start <= 1'b1;
        else if (ap_ready)
            int_ap_start <= int_auto_restart; // clear on handshake/auto restart

        if (ap_done)
            int_ap_done <= 1'b1;
        else if (arHs && araddr == ADDR_AP_CTRL)
            int_ap_done <= 1'b0; // clear on read

        int_ap_idle <= ap_idle;

        int_ap_ready <= ap_ready;

        if (wHs && wAddr == ADDR_AP_CTRL && wstrb[0])
            int_auto_restart <=  wdata[7];

        if (wHs && wAddr == ADDR_GIE && wstrb[0])
            int_gie <= wdata[0];

        if (wHs && wAddr == ADDR_IER && wstrb[0])
            int_ier <= wdata[1:0];

        if (int_ier[0] & ap_done)
            int_isr[0] <= 1'b1;
        else if (wHs && wAddr == ADDR_ISR && wstrb[0])
            int_isr[0] <= int_isr[0] ^ wdata[0]; // toggle on write

        if (int_ier[1] & ap_ready)
            int_isr[1] <= 1'b1;
        else if (wHs && wAddr == ADDR_ISR && wstrb[0])
            int_isr[1] <= int_isr[1] ^ wdata[1]; // toggle on write
    end
end

always_ff @(posedge clk) begin
    if (arHs) begin
        if (AP_CTRL_HS && (araddr >> 5 == 0)) begin
            rData <= 'b0;
            case (araddr[4:0])
                ADDR_AP_CTRL: begin
                    rData[0] <= int_ap_start;
                    rData[1] <= int_ap_done;
                    rData[2] <= int_ap_idle;
                    rData[3] <= int_ap_ready;
                    rData[7] <= int_auto_restart;
                end
                ADDR_GIE: begin
                    rData <= {31'b0, int_gie};
                end
                ADDR_IER: begin
                    rData <= {30'b0, int_ier};
                end
                ADDR_ISR: begin
                    rData <= {30'b0, int_isr};
                end
                5'h10: rData <= {(S_AXI_DATA_WIDTH-$clog2(SIP_MAX_RESP_BYTES)-1)'(0), respBytes};
                default: $error("invalid read address");
            endcase
        end else if (!AP_CTRL_HS && (araddr == 'h10)) begin
            rData <= {(S_AXI_DATA_WIDTH-$clog2(SIP_MAX_RESP_BYTES)-1)'(0), respBytes};
        end else rData <= respBuffer[respPos[$clog2(SIP_MAX_RESP_BYTES)-1:$clog2(BYTES_PER_WORD)]];

        //$display("reading address %x | %x", araddr, respPos[$clog2(SIP_MAX_RESP_BYTES)-1:$clog2(BYTES_PER_WORD)]);
    end
end

endmodule
