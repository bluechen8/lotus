/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import LotusGlobalConfig::*;
import CreditIfc::*;
import CreditFIFO::*;
import Assert::*;

import L2CacheBank::*;
import MainMemTypes::*;

//`define AXI_TRACE

typedef struct {
   Bit#(64) addr;
   Bit#(16) id;
   Bit#(8)  len;
} AxiAW deriving (Bits, FShow);

typedef struct {
   Bit#(ChunkBits)   data;
   Bit#(ChunkBEBits) strb;
   Bool              last;
   Bit#(16)          id;
} AxiW deriving (Bits, FShow);

typedef struct {
   Bit#(64) addr;
   Bit#(16) id;
   Bit#(8)  len;
} AxiAR deriving (Bits, FShow);

typedef struct {
   Bit#(ChunkBits)   data;
   Bool              last;
   Bit#(16)          id;
   Bit#(2)           resp;
} AxiR deriving (Bits, FShow);

typedef struct {
   Bit#(16)    id;
   Bit#(2)     resp;
} AxiB deriving (Bits, FShow);

interface Ifc_Axi;
    method ActionValue#(AxiAW) aw;
    method ActionValue#(AxiW)   w;
    method Action                 b(AxiB bResp);

    method ActionValue#(AxiAR) ar;
    method Action                 r(AxiR rdRsp);
endinterface

interface AxiAdaptor;
    interface RecvCredit#(ChannelLineReadReq, 1) readReq;
    interface RecvCredit#(ChannelLineOrChunkWriteReq, 1) writeReq;
    interface SendCredit#(ChannelChunkReadResp, MaxTileDecouplingStages) readResp;
    interface SendCredit#(ChannelLineWriteResp, MaxTileDecouplingStages) writeResp;
    interface Ifc_Axi axi;
endinterface

module mkAxiAdaptor(AxiAdaptor);
    TailCreditFIFO#(ChannelLineReadReq) readReqQ <- mkTailCreditFIFO(False);
    TailCreditFIFO#(ChannelLineOrChunkWriteReq) writeReqQ <- mkTailCreditFIFO(False);
    HeadCreditFIFO#(ChannelChunkReadResp, MaxTileDecouplingStages) readRespQ <- mkHeadCreditFIFO;
    HeadCreditFIFO#(ChannelLineWriteResp, MaxTileDecouplingStages) writeRespQ <- mkHeadCreditFIFO;

    function Bit#(64) lineAddrToByteAddr(BankLineAddr bla, BankSel bank);
        WordAddr wordAddr = WordAddr {tag: bla.tag, set: bla.set, bank: bank, cs: 0, ws: 0};
        Bit#(2) byteOffset = 0;
        Bit#(32) up = 0;
        return {up, pack(wordAddr), byteOffset};
    endfunction

   // Write req -> AW/W deserialization state
   Reg#(Maybe#(ChannelReqId)) curWriteReqId <- mkReg(Invalid);
   Reg#(ChunkSel) writeChunkIdx <- mkReg(0);

    interface Ifc_Axi axi;
        method ActionValue#(AxiAW) aw if (!isValid(curWriteReqId));
            ChannelLineWriteReq r = unpack(truncate(writeReqQ.first));
            writeReqQ.deq;
            curWriteReqId <= Valid(r.reqId);

            let awReq =  AxiAW {
                addr: lineAddrToByteAddr(r.bankLineAddr, r.reqId.tileReqId.bank),
                id  : extend(pack(r.reqId)),
                len : fromInteger(valueOf(FinalChunkId))
            };
`ifdef AXI_TRACE
            $display($time, ": [AxiAdaptor] AW Request: ", fshow(awReq));
`endif
            return awReq;
        endmethod

        method ActionValue#(AxiW) w if (curWriteReqId matches tagged Valid .reqId);
            Chunk r = writeReqQ.first;
            writeReqQ.deq;
            Bool last = writeChunkIdx == ~0;
            writeChunkIdx <= writeChunkIdx + 1;
            if (last) curWriteReqId <= Invalid;

            let wReq = AxiW {
                data: r,
                strb: -1,
                id  : extend(pack(reqId)),
                last: last
            };
`ifdef AXI_TRACE
            $display($time, ": [AxiAdaptor] W Request: ", fshow(wReq));
`endif
            return wReq;
        endmethod

        method Action b(AxiB bResp);
`ifdef AXI_TRACE
            $display($time, ": [AxiAdaptor] B Response: ", fshow(bResp));
`endif
            writeRespQ.enq(ChannelLineWriteResp {reqId: unpack(truncate(bResp.id))});
        endmethod

        method ActionValue#(AxiAR) ar;
            let r = readReqQ.first;
            readReqQ.deq;

            let arreq = AxiAR {
                addr: lineAddrToByteAddr(r.bankLineAddr, r.reqId.tileReqId.bank),
                id  : zeroExtend(pack(r.reqId)),
                len : fromInteger(valueOf(FinalChunkId))
            };
`ifdef AXI_TRACE
            $display($time, ": [AxiAdaptor] AR Request: ", fshow(arreq));
`endif
            return arreq;
        endmethod

        method Action r(AxiR rdRsp);
`ifdef AXI_TRACE
            $display($time, ": [AxiAdaptor] R Response: ", fshow(rdRsp));
`endif
            readRespQ.enq(ChunkReadResp {
                chunk: rdRsp.data,
                reqId: unpack(truncate(rdRsp.id))
            });
        endmethod
    endinterface

    interface readReq = readReqQ.recv;
    interface writeReq = writeReqQ.recv;
    interface readResp = readRespQ.send;
    interface writeResp = writeRespQ.send;
endmodule: mkAxiAdaptor
