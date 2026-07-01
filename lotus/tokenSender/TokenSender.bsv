/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import FIFO::*;
import FIFOF::*;
import Include::*;
import GetPut::*;
import Vector::*;
import Connectable::*;
import Arbiter::*;
import Assert::*;
import SpecialFIFOs::*;
import NonBlockingPipe::*;
import CommitIfc::*;
import FIFOLevel::*;
import DReg::*;
import DebugWrappers::*;

import LotusGlobalConfig::*;
import Sip::*;
import XRAM::*;
import XRAMUtils::*;
import Switch::*;
import CommitIfcArb::*;
import ShiftFIFO::*;
import SkidFIFO::*;
import FunctionalUtils::*;

import TaskUnit::*;

import TokenSenderTypes::*;

//`define TOKEN_SENDER_DEBUG

import XRegFile::*;

`ifdef TOKEN_SENDER_DEBUG
Bool tokenSenderDebug = True;
`else
Bool tokenSenderDebug = False;
`endif

// Read-only table for edge information
interface EdgeTable;
    // SIP for configuration
    interface SIP sip;

    // Read (range) Request
    method Action edgeReq(Tuple2#(EdgeTableIdx, NumOutEdges) req);

    method Edge first;
    method Action deq;
endinterface

interface EdgeTableConfig;
    interface SIP sip;
    method ActionValue#(Tuple2#(EdgePairTableIdx, EdgePair)) getConfigEdge;
endinterface

typedef struct {
    Vector#(ArgsPerToken, Word) outRegIdxs;
    Word flags;
    Word firstArg;
    Word globalTileId;
    Word taskId;
} EdgeWorded deriving(Bits, Eq, FShow);

module mkEdgeTableConfig#(Vector#(TAdd#(4, 10), Wire#(Bool)) perfIncs, Wire#(Bool) tileEnablePerfCounters)(EdgeTableConfig);
    Fmt name = $format("EdgeTableConfig");

    SIPControlRegs#(1, Bool) dispatchReg <- mkSIPControlRegs(name + $format("-DispatchReg"));
    SIPControlRegs#(TAdd#(4, ArgsPerToken), Word) configReg <- mkSIPControlRegs(name + $format("-ConfigReg"));

    NonBlockingPipe#(Vector#(TAdd#(4, 10), Bool)) perfIncPiped <- mkNonBlockingPipe(2, replicate(False));
    rule pipePerfInc; perfIncPiped <= map(readReg, perfIncs); endrule

    NonBlockingPipe#(Bool) tileEnablePerfCountersPiped <- mkNonBlockingPipe(3, False);
    rule feedPerfEnablePipe; tileEnablePerfCountersPiped <= tileEnablePerfCounters; endrule
    SIPCounters#(40) perfCounters <- mkSIPCounters(name+$format("-TokenSenderIncs"), perfIncPiped, tileEnablePerfCountersPiped);

    SIPMux#(3) sipMux <- mkSIPMux(name);
    Vector#(3, SIP) sipTargets = cons(configReg.sip, cons(dispatchReg.sip, cons(perfCounters, nil)));
    zipWithM_(mkConnection, sipMux.sipToTargets, sipTargets);

    Reg#(EdgeTableIdx) currIndex <- mkReg(0);

    Reg#(Maybe#(Edge)) firstEdgeSaved <- mkReg(tagged Invalid);

    FIFO#(Tuple2#(EdgePairTableIdx, EdgePair)) outConfigFIFO <- mkFIFO1;

    rule sendConfig if (dispatchReg.regsUpdated[0]);
        EdgeWorded e = unpack(pack(configReg.regs));

        let newEdge =  Edge {
                             globalTileId  : unpack(truncate(e.globalTileId)),
                             taskId        : truncate(e.taskId),
                             cycleIdDelta  : e.flags[0],
                             firstArg      : truncate(e.firstArg),
                             hasMemDataDep : unpack(e.flags[1]),
                             outRegIdxs    : map(truncate, e.outRegIdxs)
                         };

        EdgePairTableIdx pairIdx = truncate(currIndex >> 1);

        if (firstEdgeSaved matches tagged Valid .oldEdge) begin
            outConfigFIFO.enq(tuple2(pairIdx, cons(oldEdge, cons(newEdge, nil))));
            firstEdgeSaved <= tagged Invalid;
        end else begin
            outConfigFIFO.enq(tuple2(pairIdx, cons(newEdge, cons(?, nil))));
            firstEdgeSaved <= tagged Valid newEdge;
        end

        currIndex <= currIndex + 1;
    endrule: sendConfig

    interface SIP sip = sipMux.sipFromSource;

    method ActionValue#(Tuple2#(EdgePairTableIdx, EdgePair)) getConfigEdge;
        outConfigFIFO.deq;
`ifdef TOKEN_SENDER_DEBUG
        //$display($time, "%m Edge Edge Configuration: ", fshow(outConfigFIFO.first));
`endif // TOKEN_SENDER_DEBUG
        return outConfigFIFO.first;
    endmethod
endmodule

typedef 2 EdgeTableLatency;

module mkEdgeTable#(Vector#(10, Wire#(Bool)) perf_argsEnqFifos, Wire#(Bool) tileEnablePerfCounters)(EdgeTable);
    XRAM_PIPED_DUAL_PORT#(
        EdgePairTableIdx, 
        EdgePair, 
        EdgePairTableIdx, 
        EdgePair,
        EdgeTableLatency
    ) edgeTable <- mkXRAM2(unpack(0), READ_ONLY, WRITE_ONLY, "ultra");
    let readPort = edgeTable.a;
    let configPort = edgeTable.b;

    NonBlockingPipe#(Maybe#(Bit#(1))) readPipe <- mkDNonBlockingPipe(valueOf(EdgeTableLatency), Invalid, Invalid);
    
    Wire#(Bool) perf_outBaseQueueDidEnq <- mkDWire(False);
    Wire#(Bool) perf_outBaseQueueDidDeq <- mkDWire(False);
    Wire#(Bool) perf_outQueueDidEnq     <- mkDWire(False);
    Wire#(Bool) perf_outQueueDidDeq     <- mkDWire(False);

    Vector#(TAdd#(4, 10), Wire#(Bool)) perfIncs = cons(asReg(perf_outBaseQueueDidEnq), cons(asReg(perf_outBaseQueueDidDeq),
                                                  cons(asReg(perf_outQueueDidEnq), cons(asReg(perf_outQueueDidDeq),
                                                  perf_argsEnqFifos))));


    FIFOCountIfc#(Edge, 16) outBaseQueue_ <- mkGShiftFIFOCountInit(True, False, nil);
    FIFOCountIfc#(Edge, 16) outBaseQueue <- mkDebugFIFOCount(tokenSenderDebug, $format("%m-outBaseQueue"), outBaseQueue_, asReg(perf_outBaseQueueDidEnq), asReg(perf_outBaseQueueDidDeq));
    SkidFIFO#(Edge) outQueue_ <- mkSkidFIFO(outBaseQueue, valueOf(EdgeTableLatency), 1);
    SkidFIFO#(Edge) outQueue <- mkDebugSkidFIFO(tokenSenderDebug, $format("%m-outQueue"), outQueue_, asReg(perf_outQueueDidEnq), asReg(perf_outQueueDidDeq));

    rule feedOutQueue if (readPipe matches tagged Valid .sel);
        outQueue.enq(readPort.read[sel]);
    endrule

    // dsm: Use CRegs to allow full throughput (avoid dead cycle when left == 0)
    Reg#(EdgeTableIdx) cur[2] <- mkCReg(2, ?);
    Reg#(NumOutEdges) left[2] <- mkCReg(2, 0);

    rule read if (left[0] != 0 && outQueue.hasSkidSlot);
`ifdef TOKEN_SENDER_DEBUG
        //$display($time, ": [%m] Doing read on: (curr, left) = ", fshow(tuple3(cur[0], readEdgeSelect[0], left[0])));
`endif // TOKEN_SENDER_DEBUG
        readPort.put(False, truncate(cur[0] >> 1), ?);
        readPipe <= Valid(cur[0][0]);
        cur[0] <= cur[0] + 1;
        left[0] <= left[0] - 1;
    endrule

    EdgeTableConfig edgeConfig <- mkEdgeTableConfig(perfIncs, tileEnablePerfCounters);

    rule configRule;
        match {.idx, .edges} <- edgeConfig.getConfigEdge;
        configPort.put(True, idx, edges);
    endrule

    method Action edgeReq(Tuple2#(EdgeTableIdx, NumOutEdges) req) if (left[1] == 0);
        match {.idx, .numOutEdges} = req;
`ifdef TOKEN_SENDER_DEBUG
        $display($time, ": [%m] edgeReq ", fshow(req));
`endif // TOKEN_SENDER_DEBUG
        cur[1] <= idx;
        left[1] <= numOutEdges;
    endmethod

    method Edge first = outQueue.first;
    method Action deq;
        outQueue.deq;
`ifdef TOKEN_SENDER_DEBUG
        $display($time, ": [%m] Edge Instruction: ", fshow(outQueue.first));
`endif // TOKEN_SENDER_DEBUG
    endmethod

    interface SIP sip = edgeConfig.sip;
endmodule


typedef struct {
    // Epoch acts as a valid bit, but for circular buffers managed with the +1
    // bit pointer trick. The epoch is simply the enq pointer's MSB, and
    // validity is checked by matching the deq pointer's MSB
    Bit#(1) epoch;
    Word val;
} PhasedArg deriving (Bits, Eq, FShow);

// 0..NumCoresPerTile-1 are cores; last one is skipped tasks
typedef Bit#(TLog#(TAdd#(NumCoresPerTile, 1))) MetadataInIdx;

interface ArgsToTokens;
    interface RecvCommit#(Tuple2#(MetadataInIdx, TokenSenderTaskMetadata)) enqMetadataIn;
    interface RecvCommit#(Tuple2#(CoreId, Word)) argIn;

    interface SendCommit#(TokenPacket) tokenPacketOut;

    // Used to arbitrate on input queues
    method ActionValue#(Maybe#(Idx#(NumCoresPerTile))) argArbiter(Vector#(NumCoresPerTile, Bool) v);
endinterface

module mkArgsToTokens#(EdgeTable edgeTable, Vector#(10, Wire#(Bool)) perfIncs)(ArgsToTokens);
    // Metadata inputs
    // NOTE: A PipelineFIFO here worsens the critical path bc deq is late in
    // the cycle; ShiftFIFO adds a bit to the critical path, and with ~3 enqs
    // per task, a 50% throughput for metadata is enough.
    //FIFOCountIfc#(Tuple2#(CoreId, TokenSenderTaskMetadata), 16) enqMetadataQ <- mkShiftFIFOCount;
    //let enqMetadataQ_recv <- mkRecvCommit(fifoCountToFifof(enqMetadataQ));

    FIFOF#(Tuple2#(MetadataInIdx, TokenSenderTaskMetadata)) enqMetadataQ_ <- mkFIFOF1;
    FIFOF#(Tuple2#(MetadataInIdx, TokenSenderTaskMetadata)) enqMetadataQ <- mkDebugFIFOF(tokenSenderDebug, $format("%m-enqMetadataQ"), enqMetadataQ_, perfIncs[0], perfIncs[1]);
    let enqMetadataQ_recv <- mkRecvCommit(enqMetadataQ);

    // Arg inputs (unpipelined but short delay, taking args is simple; could be piped if needed)
    Wire#(Maybe#(Tuple2#(CoreId, Word))) argInData <- mkDWire(Invalid);
    Wire#(Bool) acceptArgIn <- mkDWire(False);

    // NOTE: Unguarded dequeues because this is needed for argCore (arbitration)
    FIFOCountIfc#(Tuple3#(CoreId, Bit#(TAdd#(TaskOutRegIdxBits, 2)) /* enqPtr */, TaskOutRegIdx /* numArgs */), 16) argInfoQ_ <-
        mkGShiftFIFOCountInit(False, True, nil);

    FIFOCountIfc#(Tuple3#(CoreId, Bit#(TAdd#(TaskOutRegIdxBits, 2)) /* enqPtr */, TaskOutRegIdx /* numArgs */), 16) argInfoQ <-
        mkDebugFIFOCount(tokenSenderDebug, $format("%m-argInfoQ"), argInfoQ_, perfIncs[2], perfIncs[3]);

    // Args circular buffer
    XRegFile#(Bit#(TAdd#(TaskOutRegIdxBits, 1)), PhasedArg) argBuffer <- mkXRegFile(PhasedArg{epoch: 1, val: ?});
    Reg#(Bit#(TAdd#(TaskOutRegIdxBits, 2))) head <- mkReg(0); // next to enq
    Reg#(Bit#(TAdd#(TaskOutRegIdxBits, 2))) tail <- mkReg(0); // next to deq

    // takeEnqMetadata -> pushEnq out FIFO
    // NOTE(farese): We don't need to send the whole TokenSenderTaskMetadata here, but it's very useful for debugging
    //               and I hope that it can be optimized at synthesis. 
    //               Original: Tuple3#(NumOutEdges, TaskOutRegIdx /* numArgs in this req, to free them */, CycleId)
    // NOTE(dsm): Yep, synthesis leaves only the used bits
    FIFOCountIfc#(Tuple2#(TokenSenderTaskMetadata, Bool), 16) reqMetadata_ <- mkShiftFIFOCount;
    FIFOCountIfc#(Tuple2#(TokenSenderTaskMetadata, Bool), 16) reqMetadata <- mkDebugFIFOCount(tokenSenderDebug, $format("%m-reqMetadata"), reqMetadata_, perfIncs[4], perfIncs[5]);
    Reg#(NumOutEdges) curProcessedEdges <- mkReg(0);

    // Interface FIFOFs
    FIFOCountIfc#(Tuple2#(EdgeTableIdx, NumOutEdges), 16) edgeReqQ_ <- mkShiftFIFOCount;
    FIFOCountIfc#(Tuple2#(EdgeTableIdx, NumOutEdges), 16) edgeReqQ <- mkDebugFIFOCount(tokenSenderDebug, $format("%m-edgeReqQ"), edgeReqQ_, perfIncs[6], perfIncs[7]);
    FIFOF#(TokenPacket) tokenPacketOutQ__ <- mkPipelineFIFOF;
    FIFOF#(TokenPacket) tokenPacketOutQ_ <- mkDebugFIFOF(tokenSenderDebug, $format("%m-tokenPacketOutQ_"), tokenPacketOutQ__, perfIncs[8], perfIncs[9]);

    let tokenPacketOutQ__send <- mkSendCommit(tokenPacketOutQ_);

`ifdef RUNTIME_ANALYSIS
    Reg#(Bit#(64)) currCycle <- mkReg(0);
    rule icc;
        currCycle <= currCycle + 1;
    endrule

    Reg#(Maybe#(Tuple2#(Word, Bit#(32)))) traceCurrCycles <- mkReg(Invalid);
    Wire#(Maybe#(TokenSenderTaskMetadata)) reqMetadataCurrTrace <- mkDWire(Invalid);
    rule assignCurr;
        reqMetadataCurrTrace <= tagged Valid reqMetadata.first;
    endrule
    rule updateTrace;
        case (tuple2(reqMetadataCurrTrace, traceCurrCycles)) matches
            {tagged Invalid     , tagged Invalid}: begin
                // Do nothing
            end
            {tagged Invalid     , tagged Valid {.taskFn, .cycles}}: begin
                $display("EDGE_PROFILE,pc=", fshow(taskFn), ",cycles=", fshow(cycles));
                traceCurrCycles <= tagged Invalid;
            end
            {tagged Valid .meta , tagged Invalid}: begin
                traceCurrCycles <= tagged Valid tuple2(meta.taskFn, 1);
            end
            {tagged Valid .meta, tagged Valid {.taskFn, .cycles}}: begin
                if (meta.taskFn == taskFn) begin
                    traceCurrCycles <= tagged Valid tuple2(taskFn, cycles+1);
                end else begin
                    $display("EDGE_PROFILE,pc=", fshow(taskFn), ",cycles=", fshow(cycles));
                    traceCurrCycles <= tagged Valid tuple2(meta.taskFn, 1);
                end
            end
        endcase
    endrule
`endif // RUNTIME_ANALYSIS

    (* conservative_implicit_conditions *) // slightly reduces LUTs, improves timing, zero perf impact
    rule takeEnqMetadata;
        match {.inIdx, .enqMetadata} = enqMetadataQ.first;

        // TODO: Double-check edge cases here; does this work for all 4 head/tail MSB combos?
        Bit#(TAdd#(TaskOutRegIdxBits, 2)) buffElems = head - tail; // [0, 128]
        Bit#(TAdd#(TaskOutRegIdxBits, 2)) buffAvail = (1 << (valueOf(TaskOutRegIdxBits)+1)) - buffElems;
        
        Bool isSkippedTask = (inIdx >= fromInteger(valueOf(NumCoresPerTile))); // >= should be cheaper for power of 2 cores/tile
        let numOutArgs = isSkippedTask? 0 : enqMetadata.numOutArgs;

        // We also have the req FIFOs, but those have implicit conditions :)
        Bool enoughSpace = zeroExtend(numOutArgs) <= buffAvail;
        
        if (enoughSpace) begin
`ifdef TOKEN_SENDER_DEBUG
            $display($time, ": [TokenSender] mkArgsToTokens::takeEnqMetadata (coreIdx, enqMetadata) = ", fshow(enqMetadataQ.first));
`endif // TOKEN_SENDER_DEBUG
            //$display($time, " %m taking enq ", fshow(tuple2(coreIdx, enqMetadata)));
            let nextHead = head + zeroExtend(numOutArgs);
            head <= nextHead;

            edgeReqQ.enq(tuple2(enqMetadata.firstEdgeIdxStart, enqMetadata.numOutEdges));
            reqMetadata.enq(tuple2(enqMetadata, isSkippedTask));

            if (numOutArgs != 0) begin
                let coreIdx = truncate(inIdx);
                argInfoQ.enq(tuple3(coreIdx, head, enqMetadata.numOutArgs));
            end

            enqMetadataQ.deq;
        end else begin
`ifdef TOKEN_SENDER_DEBUG
            //$display($time, " %m not taking enq as no space ", fshow(tuple2(coreIdx, enqMetadata)), " -- buffAvail=", fshow(buffAvail));
`endif // TOKEN_SENDER_DEBUG
        end
    endrule

    rule reqEdges;
        edgeTable.edgeReq(edgeReqQ.first);
        edgeReqQ.deq;
    endrule

    Reg#(TaskOutRegIdx) curArgIdx <- mkReg(0);

    rule takeArg if (argInData matches tagged Valid {.arbCoreIdx, .arg});
        match {.coreIdx, .basePtr, .numOutArgs} = argInfoQ.first;
        dynamicAssert(argInfoQ.notEmpty && coreIdx == arbCoreIdx, "argInfoQ out of sync");
        acceptArgIn <= True;

        let enqPtr = basePtr + zeroExtend(curArgIdx);
`ifdef TOKEN_SENDER_DEBUG
        $display($time, ": [TokenSender] mkArgsToTokens::takeArg (enqPtr, coreIdx, arg) = ", fshow(tuple3(enqPtr, coreIdx, arg)));
`endif // TOKEN_SENDER_DEBUG
        argBuffer.write(truncate(enqPtr), PhasedArg{epoch: enqPtr[valueOf(TaskOutRegIdxBits)+1], val : arg});
        if (curArgIdx + 1 == numOutArgs) begin
            argInfoQ.deq;
            curArgIdx <= 0;
        end else begin
            curArgIdx <= curArgIdx + 1;
        end
    endrule

    // Output side
    (* conservative_implicit_conditions *) // slightly reduces LUTs, zero perf impact
    rule pushToken;
        let edgeInfo = edgeTable.first;
        match {.meta, .isSkippedTask} = reqMetadata.first;

        // If an arg isn't used, it's set to all 1s
        Bool noArg1 = edgeInfo.outRegIdxs[0] == unpack(-1);
        Bool noArg2 = edgeInfo.outRegIdxs[1] == unpack(-1);

        // TODO: If this is slow, tag enqs by deqPtr epoch, so we can epoch-match immediately
        let argPtr1 = tail + zeroExtend(edgeInfo.outRegIdxs[0]);
        let argPtr2 = tail + zeroExtend(edgeInfo.outRegIdxs[1]);

        let arg1 = argBuffer.read1(truncate(argPtr1));
        let arg2 = argBuffer.read2(truncate(argPtr2));

        Bool ready1 = noArg1 || arg1.epoch == argPtr1[valueOf(TaskOutRegIdxBits)+1];
        Bool ready2 = noArg2 || arg2.epoch == argPtr2[valueOf(TaskOutRegIdxBits)+1];

        Bit#(2) numArgs = case (tuple2(noArg1, noArg2)) matches
                              {False, False}: fromInteger(2);
                              {False, True }: fromInteger(1);
                              {True , False}: fromInteger(1);
                              {True , True }: fromInteger(0);
                          endcase;

        //$display($time, ": %m candidate enq (meta, enq) ", fshow(tuple2(meta, enq)), " -- numArgs=%d ready1=%d ready2=%d curProcessedEdges=%d", enqNumArgs, ready1, ready2, curProcessedEdges);

        // Skipped tasks generate null messages
        if (isSkippedTask) begin
            arg1.val[1:0] = numArgs;
            numArgs = 3; // denotes null message; no data, arg count stashed in arg1's lower bits
        end

        if ((ready1 && ready2) || isSkippedTask) begin
            tokenPacketOutQ_.enq(TokenPacket {
                    dest: edgeInfo.globalTileId,
                    data: Token {
                        cycleId    : meta.cycleId + zeroExtend(edgeInfo.cycleIdDelta),
                        taskId     : edgeInfo.taskId,
                        firstArg   : edgeInfo.firstArg,
                        numArgs    : numArgs,
                        hasMemDataDep : edgeInfo.hasMemDataDep,
`ifdef RUNTIME_ANALYSIS
                        cycleCreated : currCycle,
`endif // RUNTIME_ANALYSIS
                        args       : cons(arg1.val, cons(arg2.val, nil))
                    }
                });

            edgeTable.deq;
`ifdef TOKEN_SENDER_DEBUG
            $display($time, ": [TokenSender] mkArgsToTokens::pushEnqOut processedEdges=", fshow(curProcessedEdges), " edgeInfo=", fshow(edgeInfo), " -- reqMetadata: ", fshow(reqMetadata.first));
`endif // TOKEN_SENDER_DEBUG

            // TODO: Align to make counts 0-based; 0 edges isn't an option here...
            // NOTE(farese): Apparently 0-based edges is an option..
            //               These are usually empty useless tasks that handle $display and flushes in verilog
            //               So they basically turn into empty tasks for us.
            dynamicAssert(meta.numOutEdges != 0, "numOutEdges shouldn't be zero");
            if (meta.numOutEdges == curProcessedEdges + 1) begin
                reqMetadata.deq;
                if (!isSkippedTask) tail <= tail + zeroExtend(meta.numOutArgs);
                curProcessedEdges <= 0;
            end else begin
                curProcessedEdges <= curProcessedEdges + 1;
            end
        end else begin
`ifdef TOKEN_SENDER_DEBUG
            //$display($time, ": [TokenSender] mkArgsToTokens::pushEnqOut edge not ready ", fshow(tuple2(ready1, ready2)), " enq=", fshow(enq), " -- reqMetadata: ", fshow(reqMetadata.first));
`endif // TOKEN_SENDER_DEBUG
        end
    endrule

    interface enqMetadataIn = enqMetadataQ_recv;
    
    interface argIn = interface RecvCommit#(Tuple2#(CoreId, Word));
        method Action datain(Tuple2#(CoreId, Word) din) = argInData._write(Valid(din));
        method Bool accept = acceptArgIn;
    endinterface;
    
    interface tokenPacketOut = tokenPacketOutQ__send;

    // NOTE: No side effects, but needs to be ActionValue to conform to arbitrer interface
    method ActionValue#(Maybe#(Idx#(NumCoresPerTile))) argArbiter(Vector#(NumCoresPerTile, Bool) v) = actionvalue
        return (argInfoQ.notEmpty && v[tpl_1(argInfoQ.first)])? Valid(unpack(tpl_1(argInfoQ.first))) : Invalid;
    endactionvalue;
endmodule

interface TokenSender;
    interface SIP sip;

    interface Vector#(NumCoresPerTile, RecvCommit#(Word)) coreArgs;
    interface Vector#(NumCoresPerTile, RecvCommit#(TokenSenderTaskMetadata)) coreEnqMetadata;
    interface RecvCommit#(TokenSenderTaskMetadata) skippedTaskEnqMetadata;

    interface SendCommit#(TokenPacket) tokenPacketOut;
    (* always_ready, always_enabled *)
    method Action tileEnablePerfCounters(Bool td);
endinterface

(* synthesize *)
module mkTokenSender(TokenSender);
    Vector#(10, Wire#(Bool)) perf_argsToTokens <- replicateM(mkDWire(False));
    Wire#(Bool) tileEnablePerfCountersIn <- mkBypassWire;
    EdgeTable edgeTable <- mkEdgeTable(perf_argsToTokens, tileEnablePerfCountersIn);

    ArgsToTokens argsToTokens <- mkArgsToTokens(edgeTable, perf_argsToTokens);

    // Dequeue tasks from cores in round-robin order for fairness (otherwise, some cores can starve)
    RoundRobinPrio#(TAdd#(NumCoresPerTile, 1)) roundRobin <- mkRoundRobinPrio;
    RecvCommitArb#(TAdd#(NumCoresPerTile, 1), TokenSenderTaskMetadata) enqMetadataArb <- mkRecvCommitArb(roundRobin.getPrio);
    mkConnection(enqMetadataArb.outWithIdx, argsToTokens.enqMetadataIn);

    RecvCommitArb#(NumCoresPerTile, Word) coreArgsArb <- mkRecvCommitArb(argsToTokens.argArbiter);
    mkConnection(coreArgsArb.outWithIdx, argsToTokens.argIn);

    interface Vector coreEnqMetadata = take(enqMetadataArb.ins);
    interface skippedTaskEnqMetadata = enqMetadataArb.ins[valueOf(NumCoresPerTile)];
    interface Vector coreArgs = coreArgsArb.ins;
    interface tokenPacketOut = argsToTokens.tokenPacketOut;
    interface SIP sip = edgeTable.sip;
    method Action tileEnablePerfCounters(Bool td); tileEnablePerfCountersIn <= td; endmethod
endmodule
