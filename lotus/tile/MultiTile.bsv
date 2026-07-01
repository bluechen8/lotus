/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Vector::*;
import BuildVector :: * ;
import FIFO::*;
import FIFOF::*;
import FIFOLevel::*;
import SpecialFIFOs::*;
import CommitIfc::*;
import GetPut::*;
import Connectable::*;
import CommitIfcArb::*;
import DReg::*;

import CreditIfc::*;
import CreditFIFO::*;

import AxiAdaptor::*;
import Tile::*;
import MainMemTypes::*;
import L2Cache::*;
import SipGlobal::*;
import Switch::*;
import NonBlockingPipe::*;
import TaskUnit::*;
import CoreBsv::*;
import Sip::*;
import FunctionalUtils::*;
import LotusGlobalConfig::*;
import DebugWrappers::*;

`ifdef RUNTIME_ANALYSIS
typedef Bit#(192) CrossDeviceAxisData;
`else
typedef Bit#(96) CrossDeviceAxisData;
`endif // RUNTIME_ANALYSIS

interface Ifc_CrossDeviceAxis;
    interface SendCommit#(CrossDeviceAxisData) out;
    interface RecvCommit#(CrossDeviceAxisData) in;
endinterface

interface MultiTile;
    interface Vector#(NumMemChannels, Ifc_Axi) axis;
    interface Vector#(NumCrossDeviceLinks, Ifc_CrossDeviceAxis) crossDeviceAxis;
    interface SIP sip;
endinterface

typedef SwitchReq#(TokenSwitchRadix, TokenLocalPacket) TokenSwitchReq;

interface TokenSwitch;
    interface Vector#(TokenSwitchRadix, RecvCredit#(TokenSwitchReq, 1)) in;
    interface Vector#(TokenSwitchRadix, SendCredit#(TokenLocalPacket, MaxTileDecouplingStages)) out;
endinterface

function RecvCredit#(t, 1) getRecvIfc(TailCreditFIFO#(t) x) = x.recv;
function SendCredit#(t, n) getSendIfc(HeadCreditFIFO#(t, n) x) = x.send;

function RecvCredit#(t, TAdd#(n, s)) getPipeRecvIfc(CreditFIFOPipe#(t, n, s) x) = x.recv;
function SendCredit#(t, n) getPipeSendIfc(CreditFIFOPipe#(t, n, s) x) = x.send;

// Task switch: Use synthesis boundaries so we can place it separately; note
// this now includes the head/tail credit FIFOs (but NOT the decoupling pipes)
(* synthesize *)
module mkTokenSwitch(TokenSwitch);
    // TODO: Better buffering in the middle... for 8d32t (radix=40), pre-PnR crit path is about 3ns
    Switch#(TokenSwitchRadix, TokenSwitchRadix, TokenLocalPacket) s <- mkMiddleBufferedSwitch(False, mkPipelineFIFOF, False);

    Vector#(TokenSwitchRadix, TailCreditFIFO#(TokenSwitchReq)) inQs <- replicateM(mkTailCreditFIFO(False));
    Vector#(TokenSwitchRadix, HeadCreditFIFO#(TokenLocalPacket, MaxTileDecouplingStages)) outQs <- replicateM(mkHeadCreditFIFO);
    mkConnection(inQs, s.in);
    mkConnection(s.out, outQs);

    interface in = map(getRecvIfc, inQs);
    interface out = map(getSendIfc, outQs);
endmodule

interface TokenSwitchTileMux;
    interface Vector#(NumTilesPerSwitchPort, RecvCredit#(TokenSwitchReq, 1)) ins;
    interface SendCredit#(TokenSwitchReq, MaxTileDecouplingStages) out;
endinterface

module mkTokenSwitchTileMux(TokenSwitchTileMux);
    Vector#(NumTilesPerSwitchPort, TailCreditFIFO#(TokenSwitchReq)) inQs <- replicateM(mkTailCreditFIFO(False));
    HeadCreditFIFO#(TokenSwitchReq, MaxTileDecouplingStages) outQ <- mkHeadCreditFIFO;

    RoundRobinPrio#(NumTilesPerSwitchPort) roundRobin <- mkRoundRobinPrio;
    RecvCommitArb#(NumTilesPerSwitchPort, TokenSwitchReq) arb <- mkRecvCommitArb(roundRobin.getPrio);

    zipWithM_(mkConnection, inQs, arb.ins);
    mkConnection(arb.out, outQ);

    interface ins = map(getRecvIfc, inQs);
    interface out = outQ.send;
endmodule


interface TokenSwitchTileDemux;
    interface RecvCredit#(TokenLocalPacket, 1) in;
    interface Vector#(NumTilesPerSwitchPort, SendCredit#(TokenLocalPacket, MaxTileDecouplingStages)) outs;
endinterface

module mkTokenSwitchTileDemux(TokenSwitchTileDemux);
    TailCreditFIFO#(TokenLocalPacket) inQ <- mkTailCreditFIFO(False);
    Vector#(NumTilesPerSwitchPort, HeadCreditFIFO#(TokenLocalPacket, MaxTileDecouplingStages)) outQs <- replicateM(mkHeadCreditFIFO);

    PulseWire doInDeq <- mkPulseWireOR;

    for (Integer i = 0; i < valueOf(NumTilesPerSwitchPort); i = i + 1) begin
        rule enqOut if ({1'b0, inQ.first.dest} % fromInteger(valueOf(NumTilesPerSwitchPort)) == fromInteger(i));
            outQs[i].enq(inQ.first);
            doInDeq.send;
        endrule
    end

    rule deqIn if (doInDeq);
        inQ.deq;
    endrule

    interface in = inQ.recv;
    interface outs = map(getSendIfc, outQs);
endmodule

/* Tile mem to channel mem adapter */

interface Ifc_TileMemIn;
    interface RecvCredit#(TileLineReadReq, 1) readReq;
    interface RecvCredit#(TileLineOrChunkWriteReq, 1) writeReq;
    interface SendCredit#(TileChunkReadResp, MaxTileDecouplingStages) readResp;
    interface SendCredit#(TileLineWriteResp, MaxTileDecouplingStages) writeResp;
endinterface

interface Ifc_ChannelMemOut;
    interface SendCredit#(ChannelLineReadReq, MaxTileDecouplingStages) readReq;
    interface SendCredit#(ChannelLineOrChunkWriteReq, MaxTileDecouplingStages) writeReq;
    interface RecvCredit#(ChannelChunkReadResp, 1) readResp;
    interface RecvCredit#(ChannelLineWriteResp, 1) writeResp;
endinterface

// TODO: Dedup with L2 bank mux; right now that mux has some oddities (memToSIP, bank interface) that prevent reuse
interface TileToChannelMux;
    interface Vector#(NumTilesPerMemChannel, Ifc_TileMemIn) ins;
    interface Ifc_ChannelMemOut out;
endinterface

module mkTileToChannelMux(TileToChannelMux);
    if (valueOf(NumTilesPerMemChannel) > 1) begin
        Vector#(NumTilesPerMemChannel, TailCreditFIFO#(TileLineReadReq)) tRReqQs <- replicateM(mkTailCreditFIFO(False));
        Vector#(NumTilesPerMemChannel, TailCreditFIFO#(TileLineOrChunkWriteReq)) tWReqQs <- replicateM(mkTailCreditFIFO(False));
        Vector#(NumTilesPerMemChannel, HeadCreditFIFO#(TileChunkReadResp, MaxTileDecouplingStages)) tRRespQs <- replicateM(mkHeadCreditFIFO);
        Vector#(NumTilesPerMemChannel, HeadCreditFIFO#(TileLineWriteResp, MaxTileDecouplingStages)) tWRespQs <- replicateM(mkHeadCreditFIFO);

        HeadCreditFIFO#(ChannelLineReadReq, MaxTileDecouplingStages) cRReqQ <- mkHeadCreditFIFO;
        HeadCreditFIFO#(ChannelLineOrChunkWriteReq, MaxTileDecouplingStages) cWReqQ <- mkHeadCreditFIFO;
        TailCreditFIFO#(ChannelChunkReadResp) cRRespQ <- mkTailCreditFIFO(False);
        TailCreditFIFO#(ChannelLineWriteResp) cWRespQ <- mkTailCreditFIFO(False);

        // ReadReq is muxed round-robin
        RoundRobinPrio#(NumTilesPerMemChannel) roundRobinRReq <- mkRoundRobinPrio;
        RecvCommitArb#(NumTilesPerMemChannel, TileLineReadReq) arbRReq <- mkRecvCommitArb(roundRobinRReq.getPrio);
        zipWithM_(mkConnection, tRReqQs, arbRReq.ins);

        let cRReqIfc = interface SendCommit#(ChannelLineReadReq);
            method ChannelLineReadReq dataout;
                match {.tileSel, .req} = arbRReq.outWithIdx.dataout;
                return ChannelLineReadReq{bankLineAddr: req.bankLineAddr, reqId: ChannelReqId{tileSel: tileSel, tileReqId: req.reqId}};
            endmethod

            method Action ack = arbRReq.outWithIdx.ack;
        endinterface;
        mkConnection(cRReqIfc, cRReqQ);

        // WriteReq is muxed round-robin in chunks
        Reg#(Maybe#(TileSel)) writeSrc <- mkReg(Invalid);
        Reg#(ChunkSel) writeChunkIdx <- mkReg(0);
        RoundRobinPrio#(NumTilesPerMemChannel) roundRobinWReq <- mkRoundRobinPrio;

        Wire#(Bool) writeIsLineReq <- mkDWire(False);

        function ActionValue#(Maybe#(Idx#(NumTilesPerMemChannel))) getWritePrio(Vector#(NumTilesPerMemChannel, Bool) reqs) = actionvalue
            Maybe#(Idx#(NumTilesPerMemChannel)) res = Invalid;
            if (cWReqQ.notFull) begin // note the arbiter can call this whenever; advance state only when output is available
                if (writeSrc matches tagged Valid .src) begin
                    if (reqs[src]) begin
                        writeChunkIdx <= writeChunkIdx + 1;
                        if (writeChunkIdx == ~0) writeSrc <= Invalid;
                        res = Valid(unpack(src));
                    end
                end else begin
                    res <- roundRobinWReq.getPrio(reqs);
                    if (res matches tagged Valid .src) begin
                        writeSrc <= Valid(pack(src));
                        writeIsLineReq <= True;
                    end
                end
            end
            return res;
        endactionvalue;
       
        RecvCommitArb#(NumTilesPerMemChannel, ChannelLineOrChunkWriteReq) arbWReq <- mkRecvCommitArb(getWritePrio);
        zipWithM_(mkConnection, tWReqQs, arbWReq.ins);

        let cWReqIfc = interface SendCommit#(ChannelLineOrChunkWriteReq);
            method ChannelLineOrChunkWriteReq dataout;
                match {.tileSel, .req} = arbWReq.outWithIdx.dataout;
                if (writeIsLineReq) begin
                    TileLineWriteReq tlReq = unpack(truncate(req));
                    let clReq = ChannelLineWriteReq{bankLineAddr: tlReq.bankLineAddr, reqId: ChannelReqId{tileSel: tileSel, tileReqId: tlReq.reqId}};
                    return {?, pack(clReq)};
                end else begin
                    return req;
                end
            endmethod

            method Action ack = arbWReq.outWithIdx.ack;
        endinterface;
        mkConnection(cWReqIfc, cWReqQ);

        // ReadResp and WriteResp are demuxed to the right tile
        PulseWire doRRespDeq <- mkPulseWireOR;
        PulseWire doWRespDeq <- mkPulseWireOR;

        for (Integer i = 0; i < valueOf(NumTilesPerMemChannel); i = i + 1) begin
            rule enqRResp if (cRRespQ.first.reqId.tileSel == fromInteger(i));
                tRRespQs[i].enq(TileChunkReadResp{chunk: cRRespQ.first.chunk, reqId: cRRespQ.first.reqId.tileReqId});
                doRRespDeq.send;
            endrule

            rule enqWResp if (cWRespQ.first.reqId.tileSel == fromInteger(i));
                tWRespQs[i].enq(TileLineWriteResp{reqId: cWRespQ.first.reqId.tileReqId});
                doWRespDeq.send;
            endrule
        end

        rule deqRResp if (doRRespDeq);
            cRRespQ.deq;
        endrule

        rule deqWResp if (doWRespDeq);
            cWRespQ.deq;
        endrule

        Vector#(NumTilesPerMemChannel, Ifc_TileMemIn) ins_;
        for (Integer i = 0; i < valueOf(NumTilesPerMemChannel); i = i + 1) begin
            ins_[i].readReq = tRReqQs[i].recv;
            ins_[i].writeReq = tWReqQs[i].recv;
            ins_[i].readResp = tRRespQs[i].send;
            ins_[i].writeResp = tWRespQs[i].send;
        end

        interface ins = ins_;

        interface out = interface Ifc_ChannelMemOut;
            interface readReq = cRReqQ.send;
            interface writeReq = cWReqQ.send;
            interface readResp = cRRespQ.recv;
            interface writeResp = cWRespQ.recv;
        endinterface;
        
    end else begin
        // Just a bypass, transforming tile reqs to channel reqs
        // NOTE: unpack(castWidth(pack(r))) used below because at 1
        // tile/channel, tileSel is 0 bits and Tile/Channel formats are
        // identical; however, this needs to typecheck for any tiles/channel
        // value, even if it's never used, hence castWidth.
        Wire#(Maybe#(ChannelLineReadReq)) dataRReq <- mkDWire(Invalid);
        Wire#(Maybe#(ChannelLineOrChunkWriteReq)) dataWReq <- mkDWire(Invalid);
        Wire#(Maybe#(ChannelChunkReadResp)) dataRResp <- mkDWire(Invalid);
        Wire#(Maybe#(ChannelLineWriteResp)) dataWResp <- mkDWire(Invalid);

        Wire#(Bool) creditRReq <- mkDWire(False);
        Wire#(Bool) creditWReq <- mkDWire(False);
        Wire#(Bool) creditRResp <- mkDWire(False);
        Wire#(Bool) creditWResp <- mkDWire(False);

        let in = interface Ifc_TileMemIn;
            interface readReq = interface RecvCredit#(TileLineReadReq, 1);
                method Action datain(TileLineReadReq r) = dataRReq._write(Valid(unpack(castWidth(pack(r)))));
                method Bool creditout = creditRReq;
            endinterface;

            interface writeReq = interface RecvCredit#(TileLineOrChunkWriteReq, 1);
                method Action datain(TileLineOrChunkWriteReq r) = dataWReq._write(Valid(unpack(pack(r))));
                method Bool creditout = creditWReq;
            endinterface;

            interface readResp = interface SendCredit#(TileChunkReadResp, MaxTileDecouplingStages);
                method TileChunkReadResp dataout if (dataRResp matches tagged Valid .r) = unpack(castWidth(pack(r)));
                method Action creditin = creditRResp._write(True);
            endinterface;
            
            interface writeResp = interface SendCredit#(TileLineWriteResp, MaxTileDecouplingStages);
                method TileLineWriteResp dataout if (dataWResp matches tagged Valid .r) = unpack(castWidth(pack(r)));
                method Action creditin = creditWResp._write(True);
            endinterface;
        endinterface;

        interface ins = replicate(in);
            
        interface out = interface Ifc_ChannelMemOut;
            interface readReq = interface SendCredit#(ChannelLineReadReq, MaxTileDecouplingStages);
                method ChannelLineReadReq dataout if (dataRReq matches tagged Valid .r) = r;
                method Action creditin = creditRReq._write(True);
            endinterface;

            interface writeReq = interface SendCredit#(ChannelLineOrChunkWriteReq, MaxTileDecouplingStages);
                method ChannelLineOrChunkWriteReq dataout if (dataWReq matches tagged Valid .r) = r;
                method Action creditin = creditWReq._write(True);
            endinterface;

            interface readResp = interface RecvCredit#(ChannelChunkReadResp, 1);
                method Action datain(ChannelChunkReadResp r) = dataRResp._write(Valid(r));
                method Bool creditout = creditRResp;
            endinterface;

            interface writeResp = interface RecvCredit#(ChannelLineWriteResp, 1);
                method Action datain(ChannelLineWriteResp r) = dataWResp._write(Valid(r));
                method Bool creditout = creditWResp;
            endinterface;
        endinterface;
    end
endmodule

`ifdef TILE_PAIRS
interface Ifc_TilePair;
    interface Vector#(2, Ifc_Tile) t;
endinterface

(* synthesize *)
module mkTilePair(Ifc_TilePair);
    Vector#(2, Ifc_Tile) t_ <- replicateM(mkTile);
    interface t = t_;
endmodule
`endif // TILE_PAIRS

module mkMultiTile(MultiTile);
    TokenSwitch tokenSwitch <- mkTokenSwitch;
`ifdef TILE_PAIRS
    Vector#(TDiv#(NumTiles, 2), Ifc_TilePair) tilePairs <- replicateM(mkTilePair);
    Vector#(NumTiles, Ifc_Tile) tiles;
    for (Integer i = 0; i < valueOf(NumTiles); i = i + 1) tiles[i] = tilePairs[i / 2].t[i % 2];
`else // TILE_PAIRS
`ifdef EXPOSE_MODULE_IDS_FOR_DEBUGGING
    Vector#(NumTiles, Ifc_Tile) tiles <- genWithM(mkTile);
`else // EXPOSE_MODULE_IDS_FOR_DEBUGGING
    Vector#(NumTiles, Ifc_Tile) tiles <- replicateM(mkTile);
`endif // EXPOSE_MODULE_IDS_FOR_DEBUGGING
`endif // TILE_PAIRS 

    Vector#(NumTiles, Reg#(Bool)) tilesEnablePerfCountersPiped <- replicateM(mkNonBlockingPipe(8, False));

    for (Integer t = 0; t < valueOf(NumTiles); t = t + 1) begin
        rule feedEnablePerfCountersIntoPipe;
            tilesEnablePerfCountersPiped[t] <= tiles[t].tileEnablePerfCounters;
        endrule
    end

    Bool enablePerfCounters = fold(\|| , map(readReg, tilesEnablePerfCountersPiped));

    SIPGlobalIfc sipGlobalIfc <- mkSIPGlobal;

    rule notifySipGlobalTilesDone;
        sipGlobalIfc.enablePerfCounters(enablePerfCounters);
    endrule


    SIP sipGlobal = sipGlobalIfc.sip;

    Fmt name = $format("MultiTile");
    // NOTE(dsm): Used to be SIPAutoPipe, but autopipe doesn't work with fastflow / preimplemented modules
    SIPPipe#(10)                 sipPipe <- mkSIPPipe(name);
    SIPMux#(TAdd#(NumTiles, 1)) sipMux <- mkSIPMux(name);
    mkConnection(sipPipe.sipOut, sipMux.sipFromSource);

    // SIP Network
    module getTileSIP#(Ifc_Tile t)(SIP);
        Fmt name = $format("TilePipe");
        // NOTE(dsm): Used to be SIPAutoPipe, but autopipe doesn't work with fastflow / preimplemented modules
        SIPPipe#(10) pipe <- mkSIPPipe(name);
        mkConnection(pipe.sipOut, t.sip);
        return pipe.sipIn;
    endmodule
    Vector#(NumTiles, SIP)           tileSIPVec   <- mapM(getTileSIP, tiles);
    Vector#(TAdd#(NumTiles, 1), SIP) targetSIPVec  = cons(sipGlobal, tileSIPVec);
    zipWithM_(mkConnection, sipMux.sipToTargets, targetSIPVec);

    // Task Network
    module getOutEnq#(Ifc_Tile t)(SendCredit#(TokenSwitchReq, MaxTileDecouplingStages));
       return t.outTokenPacket;
    endmodule
    module getInEnq#(Ifc_Tile t)(RecvCredit#(TokenLocalPacket, 1));
        method Action datain (TokenLocalPacket din) = t.inToken.datain(din.data);
        method Bool creditout = t.inToken.creditout;
    endmodule

    Vector#(NumTiles, SendCredit#(TokenSwitchReq, MaxTileDecouplingStages)) tileOutEnqsVec <- mapM(getOutEnq, tiles);
    Vector#(NumTiles, RecvCredit#(TokenLocalPacket, 1)) tileInEnqsVec <- mapM(getInEnq, tiles);

    Vector#(NumLocalSwitchPorts, SendCredit#(TokenSwitchReq, MaxTileDecouplingStages)) switchInEnqsVec;
    Vector#(NumLocalSwitchPorts, RecvCredit#(TokenLocalPacket, 1)) switchOutEnqsVec;

    // Floorplanning of all pipe lengths
    // Mux to switch and mem (or tiles if no muxing)
    // These have conservative defaults; if specified through defines (though
    // fastflow, which places each tile exactly), the defines are used instead. 
    Vector#(NumLocalSwitchPorts, Integer) muxToSwitchStages = `ifdef MUX_TO_SWITCH_PIPE_LENGTHS `MUX_TO_SWITCH_PIPE_LENGTHS `else replicate(valueOf(MaxTileDecouplingStages)-1) `endif ;
    Vector#(NumMemChannels, Integer) muxToMemStages = `ifdef MUX_TO_MEM_PIPE_LENGTHS `MUX_TO_MEM_PIPE_LENGTHS `else replicate(valueOf(MaxTileDecouplingStages)-1) `endif ;
    // Tile to mux pipes
    // The default is no piping, which works when tiles are placed close
    // together. When tiles behind the same mux fall on different SLRs (e.g.,
    // as sometimes needed by fastflow), this needs some pipelining
    Vector#(NumTiles, Integer) tileToSwitchMuxStages = `ifdef TILE_TO_SWITCH_MUX_PIPE_LENGTHS `TILE_TO_SWITCH_MUX_PIPE_LENGTHS `else replicate(0) `endif ;
    Vector#(NumTiles, Integer) tileToMemMuxStages = `ifdef TILE_TO_MEM_MUX_PIPE_LENGTHS `TILE_TO_MEM_MUX_PIPE_LENGTHS `else replicate(0) `endif ;

    if (valueOf(NumLocalSwitchPorts) == valueOf(NumTiles)) begin
        for (Integer i = 0; i < valueOf(NumTiles); i = i + 1) begin
            switchInEnqsVec[i] = tileOutEnqsVec[i];
            switchOutEnqsVec[i] = tileInEnqsVec[i];
        end
    end else begin
        for (Integer p = 0; p < valueOf(NumLocalSwitchPorts); p = p + 1) begin
            TokenSwitchTileMux mux <- mkTokenSwitchTileMux;
            TokenSwitchTileDemux demux <- mkTokenSwitchTileDemux;

            switchInEnqsVec[p] = mux.out;
            switchOutEnqsVec[p] = demux.in;

            Integer startTile = p * valueOf(NumTilesPerSwitchPort);
            Integer endTile = (((p + 1) * valueOf(NumTilesPerSwitchPort)) < valueOf(NumTiles))? ((p + 1) * valueOf(NumTilesPerSwitchPort)) : valueOf(NumTiles);
            for (Integer i = startTile; i < endTile; i = i + 1) begin
                Integer numStages = tileToSwitchMuxStages[i];
                CreditFIFOPipe#(TokenSwitchReq, 1, TSub#(MaxTileDecouplingStages, 1)) tileOutEnqPipe <- mkNonBypassCreditFIFOPipe(numStages); 
                CreditFIFOPipe#(TokenLocalPacket, 1, TSub#(MaxTileDecouplingStages, 1)) tileInEnqPipe <- mkNonBypassCreditFIFOPipe(numStages); 
                    
                mkConnection(tileOutEnqsVec[i], tileOutEnqPipe.recv);
                mkConnection(tileOutEnqPipe.send, mux.ins[i - startTile]);
                mkConnection(demux.outs[i - startTile], tileInEnqPipe.recv);
                mkConnection(tileInEnqPipe.send, tileInEnqsVec[i]);
            end
        end
    end

    // Decoupling credit-based FIFOs
    Vector#(NumLocalSwitchPorts, CreditFIFOPipe#(TokenSwitchReq, 1, TSub#(MaxTileDecouplingStages, 1))) switchInEnqQs;
    Vector#(NumLocalSwitchPorts, CreditFIFOPipe#(TokenLocalPacket, 1, TSub#(MaxTileDecouplingStages, 1))) switchOutEnqQs;
    for (Integer p = 0; p < valueOf(NumLocalSwitchPorts); p = p + 1) begin
        switchInEnqQs[p] <- mkNonBypassCreditFIFOPipe(muxToSwitchStages[p]);
        switchOutEnqQs[p] <- mkNonBypassCreditFIFOPipe(muxToSwitchStages[p]);
    end

    zipWithM_(mkConnection, switchInEnqsVec, map(getPipeRecvIfc, switchInEnqQs));
    zipWithM_(mkConnection, map(getPipeSendIfc, switchInEnqQs), take(tokenSwitch.in));
    
    zipWithM_(mkConnection, switchOutEnqsVec, map(getPipeSendIfc, switchOutEnqQs));
    zipWithM_(mkConnection, map(getPipeRecvIfc, switchOutEnqQs),take(tokenSwitch.out));

    // Mux mem channels
    Vector#(NumMemChannels, TileToChannelMux) memMuxes <- replicateM(mkTileToChannelMux);

    for (Integer p = 0; p < valueOf(NumMemChannels); p = p + 1) begin
        Integer startTile = p * valueOf(NumTilesPerMemChannel);
        Integer endTile = (((p + 1) * valueOf(NumTilesPerMemChannel)) < valueOf(NumTiles))? ((p + 1) * valueOf(NumTilesPerMemChannel)) : valueOf(NumTiles);
        for (Integer i = startTile; i < endTile; i = i + 1) begin
            Integer q = i - startTile;

            Integer numStages = tileToMemMuxStages[i];
            CreditFIFOPipe#(TileLineReadReq, 1, TSub#(MaxTileDecouplingStages, 1)) tileReadReqPipe <- mkNonBypassCreditFIFOPipe(numStages);
            CreditFIFOPipe#(TileLineOrChunkWriteReq, 1, TSub#(MaxTileDecouplingStages, 1)) tileWriteReqPipe <- mkNonBypassCreditFIFOPipe(numStages);
            CreditFIFOPipe#(TileChunkReadResp, 1, TSub#(MaxTileDecouplingStages, 1)) tileReadRespPipe <- mkNonBypassCreditFIFOPipe(numStages);
            CreditFIFOPipe#(TileLineWriteResp, 1, TSub#(MaxTileDecouplingStages, 1)) tileWriteRespPipe <- mkNonBypassCreditFIFOPipe(numStages);

            mkConnection(tiles[i].mem.readReq, tileReadReqPipe.recv);
            mkConnection(tileReadReqPipe.send, memMuxes[p].ins[q].readReq);
            
            mkConnection(tiles[i].mem.writeReq, tileWriteReqPipe.recv);
            mkConnection(tileWriteReqPipe.send, memMuxes[p].ins[q].writeReq);
            
            mkConnection(memMuxes[p].ins[q].readResp, tileReadRespPipe.recv);
            mkConnection(tileReadRespPipe.send, tiles[i].mem.readResp);

            mkConnection(memMuxes[p].ins[q].writeResp, tileWriteRespPipe.recv);
            mkConnection(tileWriteRespPipe.send, tiles[i].mem.writeResp);
        end
    end

    // Axi Output
    module getAxiIfc#(TileToChannelMux m, Integer numStages)(Ifc_Axi);
        // Credit-based decoupling pipelines
        // NOTE(dsm): The reason for these pipes has changed over time. I first
        // added them to cover for the insufficient pipelining of the
        // Vitis-generated HBM pipes. But at this point, these pipes are more
        // wire-efficient than AXI, so they should go all the way to the bottom of SLR0.
        CreditFIFOPipe#(ChannelLineReadReq, 1, TSub#(MaxTileDecouplingStages, 1)) readReqPipe <- mkNonBypassCreditFIFOPipe(numStages);
        CreditFIFOPipe#(ChannelLineOrChunkWriteReq, 1, TSub#(MaxTileDecouplingStages, 1)) writeReqPipe <- mkNonBypassCreditFIFOPipe(numStages);
        CreditFIFOPipe#(ChannelChunkReadResp, 1, TSub#(MaxTileDecouplingStages, 1)) readRespPipe <- mkNonBypassCreditFIFOPipe(numStages);
        CreditFIFOPipe#(ChannelLineWriteResp, 1, TSub#(MaxTileDecouplingStages, 1)) writeRespPipe <- mkNonBypassCreditFIFOPipe(numStages);
        
        mkConnection(m.out.readReq, readReqPipe.recv);
        mkConnection(m.out.writeReq, writeReqPipe.recv);
        mkConnection(m.out.readResp, readRespPipe.send);
        mkConnection(m.out.writeResp, writeRespPipe.send);

        let memAxi <- mkAxiAdaptor;

        mkConnection(memAxi.readReq, readReqPipe.send);
        mkConnection(memAxi.writeReq, writeReqPipe.send);
        mkConnection(memAxi.readResp, readRespPipe.recv);
        mkConnection(memAxi.writeResp, writeRespPipe.recv);
        
        return memAxi.axi;
    endmodule
    Vector#(NumMemChannels, Ifc_Axi) axis_;
    for (Integer c = 0; c < valueOf(NumMemChannels); c = c + 1) begin
        axis_[c] <- getAxiIfc(memMuxes[c], muxToMemStages[c]); // TODO: Make configurable
    end


    module getCrossDeviceAxis#(RecvCredit#(TokenSwitchReq, 1) switchIn, SendCredit#(TokenLocalPacket, MaxTileDecouplingStages) switchOut)(Ifc_CrossDeviceAxis);
        // NOTE(dsm): It's unclear we need these; Vitis may be auto-piping
        // these interfaces and the task switch should be next to aurora. But,
        // these make the external interfaces valid-ready-and, which is the AXI
        // spec, whereas the switch is NOT valid-ready-and (it's
        // valid-then-ready for inputs, ready-then-valid for outputs). If
        // reducing latency, consider turning these into mkFIFOF2.
        // TODO(dsm): Update above comment when dust settles; for now, I'm
        // turning these into short credit pipes, because the task switch and
        // Aurora are placed next to each other. But yeah, if Vitis auto-pipes
        // axistream, we better disable that.
        HeadCreditFIFO#(TokenSwitchReq, 1) inQ <- mkHeadCreditFIFO;
        TailCreditFIFO#(TokenLocalPacket) outQ <- mkTailCreditFIFO(False);

        mkConnection(inQ.send, switchIn);
        mkConnection(switchOut, outQ.recv);

        RecvCommit#(TokenSwitchReq) inQ_recv <- mkRecvCommit(inQ);
        SendCommit#(TokenLocalPacket) outQ_send <- mkSendCommit(outQ);
        
        interface out = interface SendCommit#(CrossDeviceAxisData);
            method CrossDeviceAxisData dataout = zeroExtend(pack(outQ_send.dataout));
            method Action ack = outQ_send.ack;
        endinterface;
        interface in = interface RecvCommit#(CrossDeviceAxisData);
            method Action datain (CrossDeviceAxisData din);
                TokenLocalPacket lp = unpack(truncate(din));
                // NOTE: {1'b0, ...} avoids out-of-bounds errors when we go down to 1 port
                inQ_recv.datain(SwitchReq{dest: castWidth({1'b0, lp.dest} / fromInteger(valueOf(NumTilesPerSwitchPort))), data: lp});
            endmethod
            method Bool accept = inQ_recv.accept;
        endinterface;
    endmodule
    Vector#(NumCrossDeviceLinks, Ifc_CrossDeviceAxis) crossDeviceAxis_ <- zipWithM(getCrossDeviceAxis, takeTail(tokenSwitch.in), takeTail(tokenSwitch.out));

    interface SIP sip = sipPipe.sipIn;
    interface axis = axis_;
    interface crossDeviceAxis = crossDeviceAxis_;
endmodule
