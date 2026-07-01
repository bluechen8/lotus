/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Assert::*;
import Vector::*;
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import LotusGlobalConfig::*;
import Switch::*;
import GetPut::*;
import Connectable::*;
import DReg::*;
import Arbiter::*;
import CommitIfc::*;
import DebugWrappers::*;

import Core::*;
import TaskUnit::*;
import NonBlockingPipe::*;

import TokenSenderTypes::*;

import FIFOLevel::*;
import ShiftFIFO::*;

import XRegFile::*;

// Debugging
//`define CORE_BSV_DEBUG

Bool coreBsvDebug = False;

interface CoreBsvMemory;
    method ActionValue#(MemReq) memReq;
    (* always_ready *)
    method Action memRsp(Tuple2#(CoreRespId, Bit#(64)) value);
endinterface

interface CoreBsvTask;
    interface SendCommit#(Word) argEnq;
    interface SendCommit#(TokenSenderTaskMetadata) enqMetadata;
    
    interface RecvCommit#(Task) taskDeq;
    (* always_ready *)
    method Action argIn(Word arg);
endinterface

interface CoreBsv;
    interface CoreBsvMemory l1;
    interface CoreBsvTask   tasku;
    method Vector#(12, Bool) perfIncs; 
endinterface

function CoreBsvMemory getCoreL1(CoreBsv c) = c.l1;
function SendCommit#(Word) getCoreArgEnq(CoreBsv c) = c.tasku.argEnq;    
function SendCommit#(TokenSenderTaskMetadata) getCoreEnqMetadata(CoreBsv c) = c.tasku.enqMetadata;
function Vector#(12, Bool) getCorePerfIncs(CoreBsv c) = c.perfIncs;
function RecvCommit#(Task) getCoreTaskDeq(CoreBsv c) = c.tasku.taskDeq;

// Deq args load schedule: We always start w cycleId, then args, then stackPtr.
// For initialization, sp and coreiId are loaded as well. taskPc is loaded
// concurrently with args, so it's not an extra state anymore.
typedef union tagged {
   void WritingCycleId;
   void WritingArgs;
   Bool WritingStackPtr; // This state is also used when initializing core for the first time
   void WritingCoreId; // This state is ONLY used when initializizing core for the first time
} CoreTaskDeqState deriving (Bits, FShow, Eq);


// Buffers tasks and args sent from the task unit, and serves them to the core
// Also buffers stack pointer (must be first received arg)
// Interfaces are coupled/related as follows:
// - Task unit enqueues task and then sequence of args. Task cannot come after args.
// - Arg enqueues are nonblocking. The buffer guarantees it has enough space to
//   take all args supporting by the allowed number of tasks it holds (e.g., if
//   it holds up to 2 tasks, 2 * MAX_ARGS + 1 for stack pointer).
// - Core dequeues args and then task. Task becomes available when dequeuing
//   last arg. Arg dequeues can be done eagerly, e.g., while the previous task is
//   running (for example, pairing writes with enq instructions). Core should
//   take args whenever it can; then, take the task when it appears.
// - The core dequeuing the task makes its space available for the next task.
interface TaskBuffer;
    // Interface to task unit
    interface RecvCommit#(Task) taskIn;
    (* always_ready *)
    method Action argIn(Word arg);

    // Interface to core
    interface SendCommit#(TaskArgWrite) argOut;
    interface SendCommit#(Task) taskOut;
    method Bool canDeqTask;
endinterface

typedef enum {DeqArgs, DeqStackPtr, Done} ArgDeqState deriving(Bits, Eq, FShow);

// NOTE: This should be just 5 LUTs (2.5 packed :)
function RIndx argIdxToArgNum(ArgIdx argIdx) = case(argIdx)
    0:  10;  // a0
    1:  11;  // a1
    2:  12;  // a2
    3:  13;  // a3
    4:  14;  // a4
    5:  15;  // a5
    6:  16;  // a6
    7:  17;  // a7
    8:   1;  // ra
    9:   4;  // tp
    10:  5;  // t0
    11:  6;  // t1
    12:  7;  // t2
    13: 28;  // t3
    14: 29;  // t4
    default: ?;
endcase;

module mkTaskBuffer(TaskBuffer);
    Wire#(Bool) perf_taskQEnq <- mkDWire(False);
    Wire#(Bool) perf_taskQDeq <- mkDWire(False);

    FIFOF#(Task) taskQ_ <- mkFIFOF1;
    FIFOF#(Task) taskQ  <- mkDebugFIFOF(coreBsvDebug, $format("taskBuffer-taskQ"), taskQ_, asReg(perf_taskQEnq), asReg(perf_taskQDeq));

    XRegFile#(Bit#(5), Word) argBuffer <- mkXRegFile(0);
    Reg#(Bit#(5)) argHead <- mkReg(-1); // next to enq
    Reg#(Bit#(5)) argTail <- mkReg(0); // next to deq
    // empty = argHead == argTail, no extra bit needed since buffer can't fill

    Reg#(ArgDeqState) argDeqState <- mkReg(DeqStackPtr);
    Reg#(ArgIdx) curArgsDeq <- mkReg(0);

    FIFOF#(TaskArgWrite) nextArg <- mkPipelineFIFOF;

    RecvCommit#(Task) taskQ_recv <- mkRecvCommit(taskQ);
    SendCommit#(Task) taskQ_send <- mkSendCommit(taskQ);

    SendCommit#(TaskArgWrite) nextArg_send <- mkSendCommit(nextArg);

    rule deqArg;
        let readArg = argBuffer.read1(argDeqState == DeqStackPtr? 31 : argTail);
        if (argDeqState == DeqStackPtr) begin
            nextArg.enq(TaskArgWrite{argNum: 2, argData: readArg});
            argDeqState <= taskQ.first.numArgs == 0? Done : DeqArgs;
        end else if (argDeqState == DeqArgs && argTail != argHead) begin
            nextArg.enq(TaskArgWrite{argNum: argIdxToArgNum(curArgsDeq), argData: readArg});
            argTail <= (argTail == -2)? 0 : (argTail + 1);
            let incCurArgsDeq = curArgsDeq + 1;
            if (incCurArgsDeq == taskQ.first.numArgs) begin
                curArgsDeq <= 0;
                argDeqState <= Done;
            end else begin
                curArgsDeq <= incCurArgsDeq;
            end
        end else if (argDeqState == Done && !taskQ.notEmpty) begin
            argDeqState <= DeqStackPtr;
        end
    endrule

    method Action argIn(Word arg);
        argBuffer.write(argHead, arg);
        argHead <= (argHead == -2)? 0 : (argHead + 1);
    endmethod

    method Bool canDeqTask = (argDeqState == Done);

    interface taskOut = taskQ_send;
    interface taskIn = taskQ_recv;
    interface argOut = nextArg_send;
endmodule


`ifdef EXPOSE_MODULE_IDS_FOR_DEBUGGING

module mkCoreBsv#(Integer coreId)(CoreBsv);
    Fmt name = $format("core%0d", coreId);

`else // EXPOSE_MODULE_IDS_FOR_DEBUGGING

(* synthesize *)
module mkCoreBsv(CoreBsv);
    Fmt name = $format("core");

`endif // EXPOSE_MODULE_IDS_FOR_DEBUGGING

    Core core <- mkCore;

    Wire#(Bool) perf_hasTask <- mkBypassWire;

    Wire#(Bool) perf_taskDeqQDidEnq              <- mkDWire(False);
    Wire#(Bool) perf_taskDeqQDidDeq              <- mkDWire(False);
    Wire#(Bool) perf_memReqFIFODidEnq            <- mkDWire(False);
    Wire#(Bool) perf_memReqFIFODidDeq            <- mkDWire(False);
    Wire#(Bool) perf_coreArgPairEnqQDidEnq       <- mkDWire(False);
    Wire#(Bool) perf_coreArgPairEnqQDidDeq       <- mkDWire(False);
    Wire#(Bool) perf_numOutArgsQDidEnq           <- mkDWire(False);
    Wire#(Bool) perf_numOutArgsQDidDeq           <- mkDWire(False);
    Wire#(Bool) perf_argEnqQDidEnq               <- mkDWire(False);
    Wire#(Bool) perf_argEnqQDidDeq               <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataQDidEnq          <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataQDidDeq          <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataSendTokenQDidEnq <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataSendTokenQDidDeq <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataGuardQDidEnq     <- mkDWire(False);
    Wire#(Bool) perf_enqMetadataGuardQDidDeq     <- mkDWire(False);

    Vector#(16, Bool) fifoCounters = cons(perf_taskDeqQDidEnq, cons(perf_taskDeqQDidDeq,
                                     cons(perf_memReqFIFODidEnq, cons(perf_memReqFIFODidDeq,
                                     cons(perf_coreArgPairEnqQDidEnq, cons(perf_coreArgPairEnqQDidDeq,
                                     cons(perf_numOutArgsQDidEnq, cons(perf_numOutArgsQDidDeq,
                                     cons(perf_argEnqQDidEnq, cons(perf_argEnqQDidDeq,
                                     cons(perf_enqMetadataQDidEnq, cons(perf_enqMetadataQDidDeq,
                                     cons(perf_enqMetadataSendTokenQDidEnq, cons(perf_enqMetadataSendTokenQDidDeq,
                                     cons(perf_enqMetadataGuardQDidEnq, cons(perf_enqMetadataGuardQDidDeq, nil))))))))))))))));

    Vector#(12, Bool) perfInc = cons(perf_hasTask, core.perfInc);
    NonBlockingPipe#(Vector#(12, Bool)) perfIncPiped <- mkNonBlockingPipe(1, replicate(False));
    rule pipePerfInc; perfIncPiped <= perfInc; endrule

    // FIFO1 cuts max req throughput to 1 per 2 cycles, but memReq is already
    // core-buffered so we can take 2 back to back, and reqs are not that
    // common. If you need more throughput you could use a FIFO2. Don't use a
    // PipelineFIFO, however, because the critical path is in the backpressure.
    FIFOF#(MemReq) memReqFIFO_ <- mkFIFOF1;
    FIFOF#(MemReq) memReqFIFO <- mkDebugFIFOF(coreBsvDebug, $format("memReqFIFOF"), memReqFIFO_, asReg(perf_memReqFIFODidEnq), asReg(perf_memReqFIFODidDeq));

    Wire#(Bool) reqReadyM <- mkDWire(False);
    Wire#(Maybe#(Tuple2#(CoreRespId, Bit#(64)))) memRspM <- mkDWire(tagged Invalid);
    Wire#(Maybe#(TaskArgWrite)) taskArgWriteM <- mkDWire(tagged Invalid);
    Wire#(Maybe#(Word)) clearException <- mkDWire(tagged Invalid);

    // Interface with core (2:1 gearbox)
    FIFOF#(Vector#(2, Word)) coreArgPairEnqQ_ <- mkFIFOF1;
    FIFOF#(TaskOutRegIdx) numOutArgsQ_ <- mkGFIFOF1(True, False);
    FIFOCountIfc#(Word, 16) argEnqQ_ <- mkShiftFIFOCount;

    FIFOF#(Vector#(2, Word)) coreArgPairEnqQ <- mkDebugFIFOF(coreBsvDebug, $format("coreArgPairEnqQ"), coreArgPairEnqQ_, asReg(perf_coreArgPairEnqQDidEnq), asReg(perf_coreArgPairEnqQDidDeq));
    FIFOF#(TaskOutRegIdx) numOutArgsQ <- mkDebugFIFOF(coreBsvDebug, $format("numOutArgsQ"), numOutArgsQ_, perf_numOutArgsQDidEnq, perf_numOutArgsQDidDeq);
    FIFOCountIfc#(Word, 16) argEnqQ <- mkDebugFIFOCount(coreBsvDebug, $format("argEnqQ"), argEnqQ_, asReg(perf_argEnqQDidEnq), asReg(perf_argEnqQDidDeq));
    Reg#(TaskOutRegIdx) curOutArgIdx <- mkReg(0);
    let argEnqQ_send <- mkSendCommit(fifoCountToFifof(argEnqQ));
    
    // Metadata synchronization: this is non-trivial because metadata should be
    // released only upon the task's last store, and a naive solution (eg all
    // FIFOs guarded) adds to the critical path.
    // This queue has the data; deq_setPc -> enqMetadata.dataout. However, this
    // queue has unguarded dequeues, as the actual guard is carried through the
    // queues below.
    FIFOF#(TokenSenderTaskMetadata) enqMetadataQ_ <- mkGFIFOF1(True, True);
    FIFOF#(TokenSenderTaskMetadata) enqMetadataQ <- mkDebugFIFOF(coreBsvDebug, $format("enqMetadataQ"), enqMetadataQ_, asReg(perf_enqMetadataQDidEnq), asReg(perf_enqMetadataQDidDeq));
    // This queue is used to tell the end-of-task rules that this task's
    // enqMetadata needs to be sent. deq_setPc -> takeEnqArgPair. It's not
    // guarded on enq because if enqMetadata is empty, this must be empty; it's
    // not guarded on deq because the consumer rule is non-blocking (isEmpty is
    // always checked).
    FIFOF#(void) enqMetadataSendTokenQ_ <- mkGFIFOF1(True, True);
    FIFOF#(void) enqMetadataSendTokenQ <- mkDebugFIFOF(coreBsvDebug, $format("enqMetadataSendTokenQ"), enqMetadataSendTokenQ_, asReg(perf_enqMetadataSendTokenQDidEnq), asReg(perf_enqMetadataSendTokenQDidDeq));
    // This queue is used to release the enqMetadata guard once it's safe to
    // dequeue the metadata. takeEnqArgPair -> enqMetadata.dataout. It's
    // unguarded on enq because the consume rule is nonblocking.
    FIFOF#(void) enqMetadataGuardQ_ <- mkGFIFOF1(True, False);
    FIFOF#(void) enqMetadataGuardQ <- mkDebugFIFOF(coreBsvDebug, $format("enqMetadataGuardQ"), enqMetadataGuardQ_, asReg(perf_enqMetadataGuardQDidEnq), asReg(perf_enqMetadataGuardQDidDeq));

    rule tick_clearEx;
        core.clearException___input(clearException);
    endrule

    rule tick_taskArgWrite;
        core.taskArgWrite___input(taskArgWriteM);
    endrule

    rule tick_reqReady;
        core.memReqReady___input(reqReadyM);
    endrule

    rule tick_rsp;
        core.rdResp___input(memRspM);
    endrule

    rule set_perf_hasTask;
        perf_hasTask <= !isValid(core.getException);
    endrule

    TaskBuffer taskBuffer <- mkTaskBuffer;

    rule deq_arg if (isValid(core.getException));
        // $display($time, " [%m] CORE writing arg ", fshow(taskBuffer.argOut.dataout));
        taskArgWriteM <= Valid(taskBuffer.argOut.dataout);
        taskBuffer.argOut.ack();
    endrule

    rule deq_task if (isValid(core.getException) && taskBuffer.canDeqTask && enqMetadataQ.notFull && numOutArgsQ.notFull);
        let t = taskBuffer.taskOut.dataout;
        taskBuffer.taskOut.ack();
        // $display($time, " [%m] CORE Starting task ", fshow(t));

        clearException <= Valid(t.taskFn);
        if (t.enqInfo.numOutEdges != 0) begin
            enqMetadataQ.enq(t.enqInfo);
            enqMetadataSendTokenQ.enq(?);
        end else begin
            dynamicAssert(t.enqInfo.numOutArgs == 0, "If no packets, then no args");
        end
        numOutArgsQ.enq(t.enqInfo.numOutArgs);
    endrule

    // This may not fire every cycle, but does fire whenever we have a task queued
    rule deq_setPrefetchHint;
        core.nextTaskPrefetchHint___input(Valid(tuple2(taskBuffer.taskOut.dataout.taskFn, taskBuffer.taskOut.dataout.taskSize)));
    endrule

    rule acceptMemReq if (core.memReq matches tagged Valid .mr);
        memReqFIFO.enq(mr);
        reqReadyM <= True;
    endrule

    PulseWire hasStoreMemReqPending <- mkPulseWire;
    rule checkStoreMemReqPending;
        if (memReqFIFO.first.wrMask != 0) hasStoreMemReqPending.send;
    endrule

    rule setEnqArgPairReady;
        // This ready signal lets an Lotus enqueue instruction execute. Conditions:
        // 1. Must have space in the queue used to store these outputs.
        // 2. Since we release enq metadata on first enqueue, if we need to
        //    pass the release token for enq metadata, there's space in the
        //    guard queue.
        // 3. Since we release enq metadata here, must wait until all store
        //    write-throughs are sent to the L2. Checking that memReqFIFO has a
        //    store request partially achieves this. In addition, the pipeline
        //    also checks the DCache doesn't have a pending store.
        core.enqArgPairReady___input(coreArgPairEnqQ.notFull && 
            (!enqMetadataSendTokenQ.notEmpty || enqMetadataGuardQ.notFull) &&
            !hasStoreMemReqPending
        );
    endrule

    rule takeEnqArgPair if (core.enqArgPair matches tagged Valid .trc);
        coreArgPairEnqQ.enq(trc);
        // Release enq metadata
        if (enqMetadataSendTokenQ.notEmpty) begin
            dynamicAssert(enqMetadataGuardQ.notFull, "metadata guard q full when it shouldn't");
            enqMetadataSendTokenQ.deq;
            enqMetadataGuardQ.enq(?);
        end
    endrule

    rule drainArgPairQ;
        let argPair = coreArgPairEnqQ.first;
        let numOutArgs = numOutArgsQ.first;

        //$display($time, " %m Draining %d/%d args", curOutArgIdx, numOutArgs);

        // Special case: if numOutArgs is 0, one empty enq still fires. We use
        // this as our condition to release the metadata word
        if (numOutArgs == 0) begin
            coreArgPairEnqQ.deq;
            numOutArgsQ.deq;
        end else begin
            let arg = argPair[curOutArgIdx[0]];
            argEnqQ.enq(arg);
            Bool last = curOutArgIdx + 1 == numOutArgs;
            if (last) begin
                numOutArgsQ.deq;
                coreArgPairEnqQ.deq;
            end else if (curOutArgIdx[0] == 1) begin
                coreArgPairEnqQ.deq;
            end
            curOutArgIdx <= last? 0 : (curOutArgIdx + 1);
        end
    endrule

    PulseWire enqMetadataAcked <- mkPulseWire;
    rule deqMetadata if (enqMetadataGuardQ.notEmpty && enqMetadataAcked);
        dynamicAssert(enqMetadataQ.notEmpty, "enqMetadataQ mismanaged");
        enqMetadataQ.deq;
        enqMetadataGuardQ.deq;
    endrule

    interface CoreBsvTask tasku;
        interface argEnq = argEnqQ_send;
        interface enqMetadata = interface SendCommit#(TokenSenderTaskMetadata);
            method TokenSenderTaskMetadata dataout if (enqMetadataGuardQ.notEmpty) = enqMetadataQ.first;
            method Action ack = enqMetadataAcked.send;
        endinterface;
        interface taskDeq = taskBuffer.taskIn;
        method Action argIn(Word arg) = taskBuffer.argIn(arg);
    endinterface

    interface CoreBsvMemory l1;
        method ActionValue#(MemReq) memReq;
            memReqFIFO.deq;
            return memReqFIFO.first;
        endmethod

        method Action memRsp(Tuple2#(CoreRespId, Bit#(64)) value);
            memRspM <= tagged Valid value;
        endmethod
    endinterface

    method Vector#(12, Bool) perfIncs = perfIncPiped;
endmodule
