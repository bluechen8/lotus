/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import TaskUnit::*;
import L2Cache::*;
import CoreBsv::*;
import Core::*;
import Switch::*;
import LotusGlobalConfig::*;
import Sip::*;
import TaskUnitConfig::*;
import AxiAdaptor::*;
import ArbiterSnooper::*;
import FunctionalUtils::*;
import TokenSender::*;
import TokenSenderTypes::*;

import CommitIfc::*;
import GetPut::*;
import Vector::*;
import Connectable::*;
import Arbiter::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import Assert::*;

import CreditIfc::*;
import CreditFIFO::*;

import FIFOLevel::*;
import ShiftFIFO::*;
import SkidFIFO::*;
import NonBlockingPipe::*;
import NonBlockingFIFO::*;

interface Ifc_Tile;
    interface Ifc_CacheMem mem;
    interface SendCredit#(SwitchReq#(TokenSwitchRadix, TokenLocalPacket), MaxTileDecouplingStages) outTokenPacket;
    interface RecvCredit#(Token, 1) inToken;
    interface SIP sip;
    method Bool tileEnablePerfCounters;
endinterface

typedef struct {
    DeviceId selfId;
    Vector#(NumDevices, DeviceId) idToPort;
} RoutingInfo deriving (Bits, Eq, FShow);

// Helper module -- decouple a CommitIfc using non-blocking pipes but DO NOT
// use intermediate state as storage. This is used to send tasks to cores;
// tasks are sent rarely and we do not care about the throughput of this
// interface, but we do care about not scheduling multiple tasks ahead. If this
// finds other uses, feel free to pull to its own file.
// NOTE: Requires destination to strictly adhere to RecvCommit, i.e.,
// VALID-READY-AND. We need accept to be asserted even without inputs!
module mkDecoupledRecvCommit#(Integer stages, RecvCommit#(data_t) consumer)(RecvCommit#(data_t)) provisos(Bits#(data_t, dataSz));
    NonBlockingPipe#(Maybe#(data_t)) dataPipe <- mkDNonBlockingPipe(stages, Invalid, Invalid);  //producer -> consumer
    NonBlockingPipe#(Bool) acceptPipe <- mkNonBlockingPipe(stages-1, False); // consumer -> producer
    Reg#(Bool) acceptIn <- mkReg(False); // producer side, used to capture whether consumer accepts
    Reg#(Bool) acceptMask <- mkReg(True); // consumer side, used to propagate only one accept per round

    Wire#(Bool) transferIn <- mkDWire(False);

    rule feedConsumer if (dataPipe matches tagged Valid .d);
        consumer.datain(d);
        dynamicAssert(consumer.accept, "decoupling pipe received data but consumer wasn't ready!?");
    endrule

    rule feedAcceptPipe;
        acceptPipe <= consumer.accept && acceptMask;
    endrule

    rule setAcceptIn;
        if (acceptPipe) begin
            dynamicAssert(!acceptIn, "should only propagate one accept per round");
            acceptIn <= True;
        end else if (transferIn) begin
            dynamicAssert(acceptIn, "??");
            dynamicAssert(!acceptPipe, "??");
            acceptIn <= False;
        end
    endrule

    rule setAcceptMask;
        if (isValid(dataPipe)) acceptMask <= True;
        else if (consumer.accept) acceptMask <= False;
    endrule

    method Action datain(data_t d);
        if (acceptIn) begin
            dataPipe <= Valid(d);
            transferIn <= True;
        end
    endmethod

    method Bool accept = acceptIn;
endmodule


`ifdef EXPOSE_MODULE_IDS_FOR_DEBUGGING

module mkTile#(Integer tileId)(Ifc_Tile);
    Vector#(NumCoresPerTile, CoreBsv) cores <- mapM(mkCoreBsv, map(\+ (tileId*valueOf(NumCoresPerTile)), genVector()));
    Fmt name = $format("Tile%0d", tileId);

`else // EXPOSE_MODULE_IDS_FOR_DEBUGGING

(* synthesize *)
module mkTile(Ifc_Tile);
    Vector#(NumCoresPerTile, CoreBsv) cores <- replicateM(mkCoreBsv);
    Fmt name = $format("Tile");

`endif // EXPOSE_MODULE_IDS_FOR_DEBUGGING

    L2Cache l2 <- mkL2Cache;
    TaskUnit taskUnit <- mkTaskUnit;
    TaskUnitConfig taskUnitConfig <- mkTaskUnitConfig;
    TokenSender tokenSender <- mkTokenSender;

    // Core Extracted interfaces
    Vector#(NumCoresPerTile, CoreBsvMemory) coreL1s = map(getCoreL1, cores);
    Vector#(NumCoresPerTile, SendCommit#(Word)) coreArgEnqs = map(getCoreArgEnq, cores);
    Vector#(NumCoresPerTile, SendCommit#(TokenSenderTaskMetadata)) coreEnqMetadata = map(getCoreEnqMetadata, cores);
    Vector#(NumCoresPerTile, RecvCommit#(Task)) rawCoreDeqs = map(getCoreTaskDeq, cores);
    Vector#(NumCoresPerTile, RecvCommit#(Task)) coreDeqs <- mapM(mkDecoupledRecvCommit(1), rawCoreDeqs);
    
    Vector#(NumCoresPerTile, FIFO#(Word)) coreArgQs <- replicateM(mkNonBlockingFIFO);
    for (Integer c = 0; c < valueOf(NumCoresPerTile); c = c + 1) begin
        rule connectArgQToCore;
            cores[c].tasku.argIn(coreArgQs[c].first);
            coreArgQs[c].deq;
        endrule
    end

    Reg#(Bool) tileEnablePerfCountersR <- mkReg(False);

    mkConnection(tokenSender.coreArgs, coreArgEnqs);
    mkConnection(tokenSender.coreEnqMetadata, coreEnqMetadata);
    mkConnection(tokenSender.skippedTaskEnqMetadata, taskUnit.skippedTaskMetadataDeq);
    mkConnection(tokenSender.tokenPacketOut, taskUnit.tokenPacketIn);

    rule notifyTokenSenderEndOfSim;
        tokenSender.tileEnablePerfCounters(taskUnit.tileEnablePerfCounters);
    endrule
    rule notifyL2EndOfSim;
        l2.tileEnablePerfCounters(taskUnit.tileEnablePerfCounters);
    endrule
    rule regTileEnablePerfCounter;
        tileEnablePerfCountersR <= taskUnit.tileEnablePerfCounters;
    endrule

    // Cores <-> Task Unit
    mkConnection(taskUnit.coreDeqs, coreDeqs);

    rule feedArgToCore;
        match {.coreId, .arg} = taskUnit.coreArgDeq;
        coreArgQs[coreId].enq(arg);
        //$display($time, " arg[", fshow(coreId), "] = ", fshow(arg));
    endrule

    Reg#(Bit#(TLog#(NumCoresPerTile))) stackCoreId <- mkReg(0);
    
    (* descending_urgency = "feedArgToCore, feedStackBaseToCore" *)
    rule feedStackBaseToCore;
        coreArgQs[stackCoreId].enq(taskUnitConfig.getStackBase);
        //$display("stackBase[", fshow(stackCoreId), "] = ", fshow(taskUnitConfig.getStackBase));
        stackCoreId <= stackCoreId + 1;
    endrule

    SIPPipe#(1) sipInPipe <- mkSIPPipe(name);
    SIPSplitter#(2, 7) sipSplitter <- mkSIPSplitter(name);
    SIPMux#(6) sipMux <- mkSIPMux(name);
    mkConnection(sipInPipe.sipOut, sipSplitter.sipFromSource);
    
    // The L2 has a SIP interface that comes from memory; connect that to our
    // tile-level SIP mux
    mkConnection(sipSplitter.sipToTargets[0], l2.memSip.tappedSip);
    mkConnection(l2.memSip.sipOut, sipMux.sipFromSource);
    mkConnection(sipSplitter.sipToTargets[1], l2.memSip.controlSip);

    SIPControlRegs#(1, Bit#(32)) routingInfoControlReg <- mkSIPControlRegs(name + $format("-routingInfoControlReg"));
    Reg#(RoutingInfo) routingInfo <- mkNonBlockingPipe(2, unpack(0));
    rule feedRoutingInfoPipe;
        routingInfo <= unpack(truncate(routingInfoControlReg.regs[0]));
    endrule
   
    Vector#(TMul#(NumCoresPerTile, 12), Bool) corePerfIncs = concat(map(getCorePerfIncs, cores));
    NonBlockingPipe#(Vector#(TMul#(NumCoresPerTile, 12), Bool)) corePerfIncsPiped <- mkNonBlockingPipe(1, replicate(False));
    rule feedPerfPipe; corePerfIncsPiped <= corePerfIncs; endrule
    NonBlockingPipe#(Bool)   coreEnablePerfCountersPiped <- mkNonBlockingPipe(3, False);
    rule feedPerfEnablePipe; coreEnablePerfCountersPiped <= taskUnit.tileEnablePerfCounters; endrule
    SIPCounters#(40) perfCounters <- mkSIPCounters(name+$format("-CoreCounters"), corePerfIncsPiped, coreEnablePerfCountersPiped);

    Vector#(6, SIP) sipTargets = cons(tokenSender.sip, cons(taskUnitConfig.sip, cons(taskUnit.sip, cons(l2.sip, cons(routingInfoControlReg.sip, cons(perfCounters, nil))))));
    Vector#(6, SIPPipe#(2)) sipPipedTargets <- replicateM(mkSIPPipe($format("tileSipPipes")));
    
    zipWithM_(mkConnection, sipPipedTargets, sipTargets);
    zipWithM_(mkConnection, sipMux.sipToTargets, sipPipedTargets);

    TailCreditFIFO#(Token) inTokenQ <- mkTailCreditFIFO(False);
    mkConnection(inTokenQ, taskUnit.fromNetToken);

    HeadCreditFIFO#(SwitchReq#(TokenSwitchRadix, TokenLocalPacket), MaxTileDecouplingStages) outTokenPacketQ <- mkHeadCreditFIFO;

    rule connectTaskUnitToNet;
        let gReq = taskUnit.toNetTokenPacket.dataout;
        // 0 == self, otherwise mappedDest index indicates cross-device dest port after the local ones
        // NOTE: With NumDevices == 1, routingInfo is 0 bits, and indexing
        // into it causes a compile-time evaluation error. Hence the ternary.
        // TODO: We probably want to skip the output port computation
        // by modifying routingInfo to have the output port directly.
        DeviceId nonSelfPort = routingInfo.idToPort[gReq.dest.device];
        outTokenPacketQ.enq(SwitchReq {
            dest: gReq.dest.device == routingInfo.selfId? 
                    // NOTE: {1'b0, ...} avoids out-of-bounds errors when we go down to 1 port (if NumTiles == NumTilesPerSwitchPort, the divisor is greater than gReq.dest.tile
                    castWidth({1'b0, gReq.dest.tile} / fromInteger(valueOf(NumTilesPerSwitchPort))) :
                    (fromInteger(valueOf(TDiv#(NumTiles, NumTilesPerSwitchPort))) + castWidth(nonSelfPort)),
            data: TokenLocalPacket{dest: gReq.dest.tile, data: gReq.data}
        });
        taskUnit.toNetTokenPacket.ack;
    endrule

    //// Core <-> L2
    zipWithM_(mkConnection, l2.cores, coreL1s);

    //// taskUnitConfig -> Task Unit
    rule taskUnitConfiging;
        let c <- taskUnitConfig.getConfigTask;
        taskUnit.configTask(c);
    endrule

    mkConnection(taskUnitConfig.getInitialArg, taskUnit.configInitialArg);

    // SIP
    interface SIP sip = sipInPipe.sipIn;

    // L2 <-> Memory
    interface Ifc_CacheMem mem = l2.mem;

    // Task Network <-> Task Unit
    interface inToken = inTokenQ.recv;
    interface outTokenPacket = outTokenPacketQ.send;

    method Bool tileEnablePerfCounters = tileEnablePerfCountersR;
endmodule
