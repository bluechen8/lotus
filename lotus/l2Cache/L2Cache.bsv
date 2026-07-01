/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import L2CacheBank::*;
import MainMemTypes::*;
import Switch::*;
import LotusGlobalConfig::*;

import Connectable::*;
import CommitIfc::*;
import CreditIfc::*;
import CreditFIFO::*;
import GetPut::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import Vector::*;

import NonBlockingPipe::*;
import NonBlockingFIFO::*;
import Sip::*;
import MemToSIP::*;
import DebugWrappers::*;
import CoreBsv::*;

Bool l2CacheDebug = False;

interface MemSIP;
    interface SIP tappedSip;
    interface SIPSource sipOut;
    interface SIP controlSip;
endinterface

interface Ifc_CacheMem;
    interface SendCredit#(TileLineReadReq, MaxTileDecouplingStages) readReq;
    interface SendCredit#(TileLineOrChunkWriteReq, MaxTileDecouplingStages) writeReq;
    interface RecvCredit#(TileChunkReadResp, 1) readResp;
    interface RecvCredit#(TileLineWriteResp, 1) writeResp;
endinterface

interface MemBankMux;
    interface Ifc_CacheMem mem;
    interface MemSIP memSip;
endinterface

module mkMemBankMux#(Vector#(L2NumBanks, Ifc_CacheBankMem) bankMems)(MemBankMux);
    Vector#(8, Wire#(Bool)) fifoCounters <- replicateM(mkDWire(False));

    HeadCreditFIFO#(TileLineReadReq, MaxTileDecouplingStages)         readReqQ_   <- mkHeadCreditFIFO;
    HeadCreditFIFO#(TileLineOrChunkWriteReq, MaxTileDecouplingStages) writeReqQ_  <- mkHeadCreditFIFO;
    TailCreditFIFO#(TileChunkReadResp)                                readRespQ_  <- mkTailCreditFIFO(False);
    TailCreditFIFO#(TileLineWriteResp)                                writeRespQ_ <- mkTailCreditFIFO(False);

    HeadCreditFIFO#(TileLineReadReq, MaxTileDecouplingStages)         readReqQ   <- mkDebugHeadCreditFIFO(l2CacheDebug, $format("(%m)-readReqQ"), readReqQ_, fifoCounters[0], fifoCounters[1]);
    HeadCreditFIFO#(TileLineOrChunkWriteReq, MaxTileDecouplingStages) writeReqQ  <- mkDebugHeadCreditFIFO(l2CacheDebug, $format("(%m)-writeReqQ"), writeReqQ_, fifoCounters[2], fifoCounters[3]);
    TailCreditFIFO#(TileChunkReadResp)                                readRespQ  <- mkDebugTailCreditFIFO(l2CacheDebug, $format("(%m)-readRespQ"), readRespQ_, fifoCounters[4], fifoCounters[5]);
    TailCreditFIFO#(TileLineWriteResp)                                writeRespQ <- mkDebugTailCreditFIFO(l2CacheDebug, $format("(%m)-writeRespQ"), writeRespQ_, fifoCounters[6], fifoCounters[7]);

    // Used to feed SIP req to the tile from memory instea dof the host; here
    // because this is the right point to tap into the main memory interface
    MemToSIP memToSip <- mkMemToSIP;

    // Read reqs are simply muxed
    Switch#(L2NumBanks, 1, TileLineReadReq) readReqMux <- mkSwitch;
    Vector#(L2NumBanks, RecvCommit#(BankLineReadReq)) readReqIn;
    for (Integer src = 0; src < valueOf(L2NumBanks); src =  src + 1) begin
        readReqIn[src] = interface RecvCommit#(BankLineReadReq);
            method Action datain(BankLineReadReq req);
                let lineReq = TileLineReadReq{bankLineAddr: req.bankLineAddr, reqId: TileReqId{bank: fromInteger(src), missIdx: req.reqId}};
                readReqMux.in[src].datain(SwitchReq{dest: 0, data: lineReq});
            endmethod
            method Bool accept = readReqMux.in[src].accept;
        endinterface;
        mkConnection(readReqIn[src], bankMems[src].lineReadReq);
    end
    mkConnection(readReqMux.out[0], memToSip.tappedReadReq);
    mkConnection(memToSip.readReq, readReqQ);

    // Write reqs are muxed and serialized
    Reg#(Maybe#(BankSel)) writeSrc <- mkReg(Invalid);
    Reg#(ChunkSel) writeChunkIdx <- mkReg(0);

    Switch#(L2NumBanks, 1, TileLineWriteReq) writeLineReqMux <- mkSwitch;
    Vector#(L2NumBanks, RecvCommit#(BankLineWriteReq)) writeLineReqIn;
    for (Integer src = 0; src < valueOf(L2NumBanks); src =  src + 1) begin
        writeLineReqIn[src] = interface RecvCommit#(BankLineWriteReq);
            method Action datain(BankLineWriteReq req);
                let lineReq = TileLineWriteReq{bankLineAddr: req.bankLineAddr, reqId: TileReqId{bank: fromInteger(src), missIdx: req.reqId}};
                writeLineReqMux.in[src].datain(SwitchReq{dest: 0, data: lineReq});
            endmethod
            method Bool accept = writeLineReqMux.in[src].accept;
        endinterface;
        mkConnection(writeLineReqIn[src], bankMems[src].lineWriteReq);
    end

    rule enqLineWriteReq if (!isValid(writeSrc));
        let req = writeLineReqMux.out[0].dataout;
        writeReqQ.enq({?, pack(req)});
        writeSrc <= Valid(req.reqId.bank);
        writeLineReqMux.out[0].ack;
    endrule

    rule enqChunkWriteReq if (writeSrc matches tagged Valid .src);
        writeReqQ.enq(bankMems[src].chunkWriteReq.dataout);
        bankMems[src].chunkWriteReq.ack;
        writeChunkIdx <= writeChunkIdx + 1;
        if (writeChunkIdx == ~0) writeSrc <= Invalid;
    endrule

    // Resps are demuxed
    Switch#(1, L2NumBanks, BankChunkReadResp) readRespDemux <- mkSwitch;
    let readRespDemuxIn = interface RecvCommit#(TileChunkReadResp);
        method Action datain(TileChunkReadResp r) = readRespDemux.in[0].datain(
            SwitchReq{dest: r.reqId.bank, data: BankChunkReadResp{chunk: r.chunk, reqId: r.reqId.missIdx}});
        method Bool accept = readRespDemux.in[0].accept;
    endinterface;
    mkConnection(readRespQ, memToSip.readResp);
    mkConnection(memToSip.tappedReadResp, readRespDemuxIn);

    Switch#(1, L2NumBanks, BankLineWriteResp) writeRespDemux <- mkSwitch;
    let writeRespDemuxIn = interface RecvCommit#(TileLineWriteResp);
        method Action datain(TileLineWriteResp r) = writeRespDemux.in[0].datain(
            SwitchReq{dest: r.reqId.bank, data: BankLineWriteResp{reqId: r.reqId.missIdx}});
        method Bool accept = writeRespDemux.in[0].accept;
    endinterface;
    mkConnection(writeRespQ, writeRespDemuxIn);

    for (Integer i = 0; i < valueOf(L2NumBanks); i =  i + 1) begin
        mkConnection(readRespDemux.out[i], bankMems[i].chunkReadResp);
        mkConnection(writeRespDemux.out[i], bankMems[i].lineWriteResp);
    end

    interface Ifc_CacheMem mem;
        interface readReq = readReqQ.send;
        interface writeReq = writeReqQ.send;
        interface readResp = readRespQ.recv;
        interface writeResp = writeRespQ.recv;
    endinterface

    interface MemSIP memSip;
        interface tappedSip = memToSip.tappedSip;
        interface sipOut = memToSip.sipOut;
        interface controlSip = memToSip.sip;
    endinterface
endmodule

interface Ifc_CoreCache;
    method Action req(MemReq r);
    method ActionValue#(Tuple2#(CoreRespId, Chunk)) readResp;
endinterface

instance Connectable#(Ifc_CoreCache, CoreBsvMemory);
    module mkConnection#(Ifc_CoreCache l2Core, CoreBsvMemory coreL1)(Empty);
        rule handleCoreL2Req;
            let memReq <- coreL1.memReq;
            // FIXME: Remove unpack/pack once we only have one type
            MemReq req = unpack(pack(memReq));
            l2Core.req(req);
        endrule
        rule handleL2CoreRsp;
            match {.cacheType, .chunk} <- l2Core.readResp;
            // FIXME(farese): pack/unpack due to the different "type" even though it's the same
            coreL1.memRsp(tuple2(unpack(pack(cacheType)), chunk));
        endrule
    endmodule
endinstance

interface L2Cache;
    interface Vector#(NumCoresPerTile, Ifc_CoreCache) cores;
    interface Ifc_CacheMem mem;
    interface MemSIP memSip;
    interface SIP sip;
    (* always_ready, always_enabled *)
    method Action tileEnablePerfCounters(Bool td);
endinterface


// Switches are large, so help the synthesis tool
`define SYNTH_WRAPPER(ifc, modName, wrapperModName) \
    (* synthesize *) \
    module wrapperModName(ifc); \
        (* hide *) \
        ifc x <- modName; \
        return x; \
    endmodule

`SYNTH_WRAPPER(Switch#(NumCoresPerTile, L2NumBanks, CoreReq), mkSwitch, mkCoreReqSwitch)
`SYNTH_WRAPPER(Switch#(L2NumBanks, NumEvenCores, Tuple2#(CoreRespId, Chunk)), mkSwitch, mkCoreRespSwitchEven)
`SYNTH_WRAPPER(Switch#(L2NumBanks, NumOddCores, Tuple2#(CoreRespId, Chunk)), mkSwitch, mkCoreRespSwitchOdd)

(* synthesize *)
module mkL2Cache(L2Cache);
    Vector#(L2NumBanks, L2CacheBank) banks <- replicateM(mkL2CacheBank);
    // NOTE: req switch is not backpressured because banks have deep queues;
    // resp switches are not backpressured because cores always take replies. 
    Switch#(NumCoresPerTile, L2NumBanks, CoreReq) coreReqSwitch <- mkCoreReqSwitch;
    Switch#(L2NumBanks, NumEvenCores, Tuple2#(CoreRespId, Chunk)) coreRespSwitchEven <- mkCoreRespSwitchEven;
    Switch#(L2NumBanks, NumOddCores, Tuple2#(CoreRespId, Chunk)) coreRespSwitchOdd <- mkCoreRespSwitchOdd;

    Vector#(NumCoresPerTile, Vector#(4, Wire#(Bool))) fifoCounters <- replicateM(replicateM(mkDWire(False)));

    Vector#(NumCoresPerTile, FIFOF#(SwitchReq#(L2NumBanks, CoreReq))) coreReqQs_ <- replicateM(mkPipelineFIFOF);
    Vector#(NumCoresPerTile, FIFOF#(Tuple2#(CoreRespId, Chunk))) coreRespQs_ <- replicateM(mkNonBlockingFIFOF);

    module getDebugCoreReqFIFO#(Integer coreId)(FIFOF#(SwitchReq#(L2NumBanks, CoreReq)));
        FIFOF#(SwitchReq#(L2NumBanks, CoreReq)) f <- mkDebugFIFOF(l2CacheDebug, $format("(%m)(coreId=%0d)-coreReqQ", coreId), coreReqQs_[coreId], fifoCounters[coreId][0], fifoCounters[coreId][1]);
        return f;
    endmodule
    module getDebugCoreRespFIFO#(Integer coreId)(FIFOF#(Tuple2#(CoreRespId, Chunk)));
        FIFOF#(Tuple2#(CoreRespId, Chunk)) f <- mkDebugFIFOF(l2CacheDebug, $format("(%m)(coreId=%0d)-coreRespQ", coreId), coreRespQs_[coreId], fifoCounters[coreId][2], fifoCounters[coreId][3]);
        return f;
    endmodule

    Vector#(NumCoresPerTile, FIFOF#(SwitchReq#(L2NumBanks, CoreReq))) coreReqQs <- genWithM(getDebugCoreReqFIFO);
    Vector#(NumCoresPerTile, FIFOF#(Tuple2#(CoreRespId, Chunk))) coreRespQs <- genWithM(getDebugCoreRespFIFO);

    zipWithM_(mkConnection, coreReqQs, coreReqSwitch.in);

    // Performance
    Vector#(L2NumBanks, Vector#(6, Bool)) perf_incrementsPerBank;
    for (Integer i = 0; i < valueOf(L2NumBanks); i = i + 1) begin
         perf_incrementsPerBank[i] = append(banks[i].perf_increments, cons(False /* TODO: Reserved for switch stalls */, nil));
    end
    NonBlockingPipe#(Vector#(TMul#(L2NumBanks, 6), Bool)) perfIncPiped <- mkNonBlockingPipe(2, replicate(False));
    rule pipePerfInc; perfIncPiped <= concat(perf_incrementsPerBank); endrule
    Wire#(Bool) tileEnablePerfCountersIn <- mkBypassWire;
    NonBlockingPipe#(Bool) tileEnablePerfCountersPiped <- mkNonBlockingPipe(3, False);
    rule feedPerfEnablePipe; tileEnablePerfCountersPiped <= tileEnablePerfCountersIn; endrule
    SIPCounters#(40) perfCounters <- mkSIPCounters($format("BankCounters"), perfIncPiped, tileEnablePerfCountersPiped);

    // SIP
    SIPMux#(1) sipMux <- mkSIPMux($format("L2Mux"));
    zipWithM_(mkConnection, sipMux.sipToTargets, cons(perfCounters, nil));

    Vector#(NumCoresPerTile, Ifc_CoreCache) cores_;
    for (Integer i = 0; i < valueOf(NumCoresPerTile); i = i + 1) begin
        cores_[i] = interface Ifc_CoreCache;
            method Action req(MemReq r) = coreReqQs[i].enq(SwitchReq{dest: r.wordAddr.bank, data: CoreReq{coreId: fromInteger(i), req: r}});
            method ActionValue#(Tuple2#(CoreRespId, Chunk)) readResp;
                coreRespQs[i].deq;
                return coreRespQs[i].first;
            endmethod
        endinterface;

        if (i % 2 == 0) mkConnection(coreRespSwitchEven.out[i/2], coreRespQs[i]);
        else mkConnection(coreRespSwitchOdd.out[i/2], coreRespQs[i]);
    end

    Vector#(L2NumBanks, Ifc_CacheBankMem) mems_;
    for (Integer i = 0; i < valueOf(L2NumBanks); i = i + 1) begin
        mkConnection(coreReqSwitch.out[i], banks[i].core.req);
        mkConnection(banks[i].core.readRespEven, coreRespSwitchEven.in[i]);
        mkConnection(banks[i].core.readRespOdd, coreRespSwitchOdd.in[i]);
        mems_[i] = banks[i].mem;
    end

    MemBankMux mux <- mkMemBankMux(mems_);

    interface cores = cores_;
    interface mem = mux.mem;
    interface memSip = mux.memSip;
    interface sip = sipMux.sipFromSource;
    method Action tileEnablePerfCounters(Bool td); tileEnablePerfCountersIn <= td; endmethod
endmodule
