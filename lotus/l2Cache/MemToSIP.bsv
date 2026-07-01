/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Assert::*;
import Sip::*;
import L2CacheBank::*;
import MainMemTypes::*;
import FIFOLevel::*;
import ShiftFIFO::*;
import CommitIfc::*;
import DReg::*;
import RegWithReset::*;
import Vector::*;
import Connectable::*;

// SIP latency to the FPGA is high, so configuring everything through SIP takes
// too long. This module allows reading a stream of SIP requests from a
// "tapped" memory interface, and pass them to a "tapped" SIP interface. When
// the module is not active, tapped interfaces are transparent. When the module
// is active, it takes over the tapped interfaces. This is meant to be used
// during configuration, so it's assumed the tapped interfaces won't be used.
// The memory interface input is just ignored, and the SIP interface replies
// with an error code to avoid a protocol deadlock.
//
// MEMORY FORMAT: Requests are placed in a contiguous range of **cache lines**.
// The stream is a sequence of (size, req) pairs, where size is 1 byte and req
// has size bytes. The stream must be terminated by a size = 128 (8'b100...0)
// byte, e.g., [(size1, req1bytes...), (size2, req2bytes...), ...., 128].
// size == 0 is valid and causes a skip to the next byte. zeroes could also be
// used to space out requests, but this should not be needed to begin with! 
//
// SIP control interface: Enables starting a request by writing the starting line
// to the SIP control interface, and checking for completion asynchronously by
// issuing a 1-beat request to the SIP interface. Status indicates whether the
// module is still active, and whether all issued requests (interpreted as
// write requests) have received an ACK.
//
// Note that the user only specifies the starting line, but not the end. The
// end is found via the termination byte, and the implementation is allowed to
// overfetch lines to achieve high memory bandwidth.
interface MemToSIP;
    // Tapped read memory interface
    interface SendCommit#(TileLineReadReq) readReq;
    interface RecvCommit#(TileChunkReadResp) readResp;

    interface RecvCommit#(TileLineReadReq) tappedReadReq;
    interface SendCommit#(TileChunkReadResp) tappedReadResp;

    // Tapped SIP interface
    interface SIPSource sipOut;
    interface SIP tappedSip;

    // Control SIP interface---this should be driven from outside the tapped
    // SIP interface, or you'll lose connectivity and will be unable to poll
    // for completion
    interface SIP sip;
endinterface

// TODO: Make these global?
typedef TSub#(AddrBits, TLog#(ClBytes)) CacheLineBits;
typedef 15 MaxFlitsPerSIPReq;

// NOTE(dsm): This implementation is optimized for efficiency, so that we can
// use it in every tile; an initial design using standard SIP elements, guarded
// FIFOs, etc., took ~220 LUTs and 325 regs. This is about 100 LUTs and 60 regs.
(* synthesize *)
module mkMemToSIP(MemToSIP);
    // Control state:
    // - active denotes whether we're processing a stream. A >1-beat SIP req
    //   when inactive makes us active.
    // - fetchDone denotes that we've fetched the last SIP request of the
    //   stream. It's used to stop line fetches and detect termination.
    // - reqInFlight denotes that we have a SIP request (streamed from memory)
    //   in flight. It's used to moderate requests and dedetect termination.
    RegWithReset#(Bool) active <- mkRegWithReset(False); 
    RegWithReset#(Bool) fetchDone <- mkRegWithReset(True);
    RegWithReset#(Bool) reqInFlight <- mkRegWithReset(False);
    RegWithReset#(Bool) nonAckResps <- mkRegWithReset(False);

    // Current line being fetched
    Reg#(Bit#(CacheLineBits)) curLine <- mkRegU;

    // Tracks how many bytes have been requested from memory but not read. This
    // is used to synchronize the memory reuqest and responses. Uses a format
    // (-1-based, fetch can only be 3 lines ahead) that simplifies logic.
    Reg#(Bit#(8)) memBytesPending <- mkReg(-1);
    Bool noMemBytesPending = memBytesPending[7:6] == 2'b11;
    Bool canFetchLine = memBytesPending[7:6] != 2'b10;
    Bool lastByteInChunk = memBytesPending[2:0] == 0;
    PulseWire addLineToMemBytesPending <- mkPulseWire;

    // Buffers bytes read from memory to be issued as SIP requests. Unguarded
    // dequeues, which are self-pacing: to issue the entire request in
    // contiguous cycles, we start dequeueing only when the whole req is in the
    // FIFO. Thus, this FIFO must hold the max number of flits per req, plus
    // one for the size byte.
    // Format: isDataByte, data
    FIFOCountIfc#(Tuple2#(Bool, Bit#(8)), TAdd#(MaxFlitsPerSIPReq, 1)) sipReqQ <- mkGShiftFIFOCountInit(True, True, nil);

    // For efficiency, this uses a custom SIP endpoint instead of control and
    // status regs. All requests reply with activity status, and startLine is
    // streamed in.
    Reg#(SIPFlit) controlSipReq <- mkReg(Invalid);
    Reg#(SIPFlit) controlSipResp <- mkReg(Invalid);
    Reg#(Bool) prevCReqValid <- mkReg(False);
    Reg#(Bool) prevPrevCReqValid <- mkReg(False);

    rule controlState;
        prevCReqValid <= isValid(controlSipReq);
        prevPrevCReqValid <= prevCReqValid;

        if (!isValid(controlSipReq) && prevCReqValid) controlSipResp <= Valid({6'b0, pack(active), pack(nonAckResps)});
        else controlSipResp <= Invalid;

        if (!isValid(controlSipReq) && prevCReqValid && prevPrevCReqValid) begin
            dynamicAssert(!active, "Received new stream req while active!! This will break.");
            active <= True;
            fetchDone <= False;
            nonAckResps.reset;
            //$display($time, " %m: Starting stream at address ", fshow({curLine, 6'b0}));
        end else if (active && fetchDone && noMemBytesPending && !sipReqQ.notEmpty && !reqInFlight) begin
            //$display($time, " %m: Stream done");
            active.reset;
        end
    endrule

    // Stage 1: Drive readReq, issuing read requests until fetchDone
    Wire#(Maybe#(TileLineReadReq)) readReqDataIn <- mkDWire(Invalid);
    Wire#(Maybe#(TileLineReadReq)) readReqDataOut <- mkBypassWire;

    Wire#(Bool) readReqAckIn <- mkDWire(False);
    Wire#(Bool) readReqAckOut <- mkBypassWire;

    rule feedMemReadReqData;
        LineAddr lineAddr = unpack(curLine);
        let bankLineAddr = BankLineAddr{tag: lineAddr.tag, set: lineAddr.set};
        let req = TileLineReadReq{bankLineAddr: bankLineAddr, reqId: TileReqId{bank: lineAddr.bank, missIdx: ?}};
        readReqDataOut <= fetchDone? readReqDataIn : canFetchLine? Valid(req) : Invalid;
    endrule

    rule feedMemReadReqAck;
        readReqAckOut <= fetchDone && readReqAckIn;
    endrule

    rule setCurLine;
        if (fetchDone && isValid(controlSipReq)) begin
            curLine <= {fromMaybe(?, controlSipReq), truncate(curLine >> 8)};
        end else if (!fetchDone && canFetchLine && readReqAckIn) begin
            //$display($time, " %m: Requested ", fshow({curLine, 6'b0}), ", advancing fetch");
            curLine <= curLine + 1;
            addLineToMemBytesPending.send;
        end
    endrule

    // Stage 2: Drive readResp, consuming data byte by byte 
    Wire#(Maybe#(TileChunkReadResp)) readRespDataIn <- mkDWire(Invalid);
    Wire#(Maybe#(TileChunkReadResp)) readRespDataOut <- mkBypassWire;

    Wire#(Bool) readRespAckIn <- mkDWire(False);
    Wire#(Bool) readRespAckOut <- mkBypassWire;
    Wire#(Bool) consumeResp <- mkDWire(False);

    rule feedMemReadRespData;
        readRespDataOut <= (!active)? readRespDataIn : Invalid;
    endrule

    rule feedMemReadRespAck;
        readRespAckOut <= (!active)? readRespAckIn : consumeResp;
    endrule

    Reg#(Bit#(TLog#(TAdd#(MaxFlitsPerSIPReq, 1)))) curReqBytesLeft <- mkReg(0);

    (* no_implicit_conditions *)
    rule processMemResp;
        Bool decMemBytesPending = False;
        if (active &&& readRespDataIn matches tagged Valid .resp &&& sipReqQ.notFull) begin
            //$display($time, " %m: Processing resp chunk ", fshow(resp.chunk), ", pending ", fshow(memBytesPending));
            dynamicAssert(!noMemBytesPending, "valid mem resp with no bytes pending");
            decMemBytesPending = True;

            // Select byte from chunk. Due to how memBytesPending is managed,
            // the lower bits go through sequence [-1,-2,...,1,0] for indices
            // [0,1,...,-1], so negating these bits yields the right index.
            Vector#(TDiv#(ChunkBits, 8), Bit#(8)) chunkBytes = unpack(resp.chunk);
            Bit#(TLog#(TDiv#(ChunkBits, 8))) byteIdx = ~truncate(memBytesPending);
            let curByte = chunkBytes[byteIdx];

            // Push byte to next stage, tagging it with whether it's data or size
            Bool isDataByte = curReqBytesLeft != 0;
            curReqBytesLeft <= isDataByte? curReqBytesLeft - 1 : truncate(curByte);
            if (!fetchDone) sipReqQ.enq(tuple2(isDataByte, curByte));

            //$display($time, " %m: Processing idx ", fshow(byteIdx), ", byte ", fshow(curByte), ", isDataByte=", fshow(isDataByte), " lastByteInChunk=", fshow(lastByteInChunk));

            // Detect termination
            if (!isDataByte) begin
                if (curByte[7] == 1) begin
                    //$display($time, " %m fetch done");
		    fetchDone.reset; // sets to True (initial value)
                end else dynamicAssert(curByte <= fromInteger(valueOf(MaxFlitsPerSIPReq)), "SIP request in stream exceeds the maximum size supported");
            end

            consumeResp <= lastByteInChunk;
        end

        memBytesPending <= memBytesPending + (addLineToMemBytesPending? fromInteger(valueOf(ClBytes)) : 0) - (decMemBytesPending? 1 : 0);
    endrule

    // Stage 3: Drive the tapped SIP req

    Wire#(SIPFlit) sipReqIn <- mkBypassWire;
    Wire#(SIPFlit) sipReqOut <- mkBypassWire;

    Reg#(Bool) prevWasDataByte <- mkReg(False);
    
    rule feedSipReq;
        if (!active) begin
            sipReqOut <= sipReqIn;
        end else if (sipReqQ.notEmpty) begin
            match {.isDataByte, .data} = sipReqQ.first;
            sipReqOut <= isDataByte? Valid(data) : Invalid;
            if (isDataByte && !prevWasDataByte) reqInFlight <= True;
            if (isDataByte || (!reqInFlight && pack(sipReqQ.count) >= truncate(data + 1))) sipReqQ.deq;
            prevWasDataByte <= isDataByte;
        end else begin
            sipReqOut <= Invalid;
        end
    endrule

    // Stage 4: Drive the tapped SIP resp
    Wire#(SIPFlit) sipRespIn <- mkBypassWire;
    Wire#(SIPFlit) sipRespOut <- mkBypassWire;

    Reg#(Bool) prevSipRespValid <- mkReg(False);

    rule feedSipResp;
        if (!active) begin
            sipRespOut <= sipRespIn;
        end else begin
            sipRespOut <= Invalid; // TODO: resp error on req
            
            if (!prevSipRespValid &&& sipRespIn matches tagged Valid .data &&& data != 8'h10) begin
                nonAckResps <= True;
            end

            if (!isValid(sipRespIn) && prevSipRespValid) begin
                dynamicAssert(reqInFlight, "received sip resp without a req in flight");
                reqInFlight.reset;
            end
        end

        prevSipRespValid <= isValid(sipRespIn);
    endrule

    interface readReq = interface SendCommit#(TileLineReadReq);
        method TileLineReadReq dataout if (readReqDataOut matches tagged Valid .dout) = dout;
        method Action ack = readReqAckIn._write(True);
    endinterface;

    interface tappedReadReq = interface RecvCommit#(TileLineReadReq);
        method Action datain(TileLineReadReq din) = readReqDataIn._write(Valid(din));
        method Bool accept = readReqAckOut;
    endinterface;

    interface tappedReadResp = interface SendCommit#(TileChunkReadResp);
        method TileChunkReadResp dataout if (readRespDataOut matches tagged Valid .dout) = dout;
        method Action ack = readRespAckIn._write(True);
    endinterface;

    interface readResp = interface RecvCommit#(TileChunkReadResp);
        method Action datain(TileChunkReadResp din) = readRespDataIn._write(Valid(din));
        method Bool accept = readRespAckOut;
    endinterface;

    interface sipOut = interface SIPSource;
        method SIPFlit req = sipReqOut;
        method Action resp(SIPFlit f) = sipRespIn._write(f);
    endinterface;

    interface tappedSip = interface SIP;
        method Action req(SIPFlit f) = sipReqIn._write(f);
        method SIPFlit resp = sipRespOut;
    endinterface;

    interface sip = interface SIP;
        method Action req(SIPFlit f) = controlSipReq._write(f);
        method SIPFlit resp = controlSipResp;
    endinterface;
endmodule
