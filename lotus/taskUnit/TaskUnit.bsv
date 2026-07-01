/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

//import BRAMCore::*;
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

import ArbiterSnooper::*;
import Sip::*;
import LotusGlobalConfig::*;
import FunctionalUtils::*;
import XRAM::*;
import PrioQueue::*;
import XRAMUtils::*;
import Switch::*;
import ShiftFIFO::*;
import CommitIfcArb::*;
import SkidFIFO::*;
import DebugWrappers::*;
import TokenSenderTypes::*;

// Debugging
//`define TASK_UNIT_DEBUG

`ifdef TASK_UNIT_DEBUG
    Bool taskUnitDebug = True;
`else // TASK_UNIT_DEBUG
    Bool taskUnitDebug = False;
`endif // TASK_UNIT_DEBUG

// Args mem size
typedef Vector#(2, Word) ArgPair;
typedef TDiv#(AvgArgsPerTask, 2) ArgPairsPerTask;
typedef TLog#(TMul#(ArgPairsPerTask, TExp#(SizeOf#(TaskId)))) ArgMemIdxBits;
typedef Bit#(ArgMemIdxBits) ArgMemIdx;

// NOTE: CycleId must be in the higher bits of this
//       otherwise the HeapSorting will be wrong
typedef struct {
   CycleId cycleId;
   t taskId; // NOTE: Retaining name to avoid conversion boilerplate; in general, these are a subset of taskId bits.
} CycledIdx#(type t) deriving (Bits, Eq, FShow);

typedef CycledIdx#(TaskId) CycledTaskIdx;

instance Ord#(CycledIdx#(t)) provisos (Bits#(t, tBits), Ord#(t));
    function Bool \< (CycledIdx#(t) a, CycledIdx#(t) b);
        let cDiff = a.cycleId - b.cycleId;
        return (cDiff == 0)? a.taskId < b.taskId : cDiff[valueOf(SizeOf#(CycleId))-1] == 1;
    endfunction

    function Bool \<= (CycledIdx#(t) a, CycledIdx#(t) b);
        let cDiff = a.cycleId - b.cycleId;
        return (cDiff == 0)? a.taskId <= b.taskId : cDiff[valueOf(SizeOf#(CycleId))-1] == 1;
    endfunction
endinstance

// CycledTaskIdx lets us preserve order using 2 bits, but with 2 cycles active
// at any given time, we only need double buffering on storage structures.
typedef 2 NumSubCycles;
typedef Bit#(TLog#(NumSubCycles)) SubCycleId;
typedef struct {
   SubCycleId subCycleId;
   TaskId taskId;
} SubCycledTaskIdx deriving (Bits, Eq, FShow);

// Interface types

// It's important to keep Token small, as its width affects a whole bunch of logic. So:
// numArgs == 3 => isNull; in this case, args[0][1:0] has real numArgs
typedef struct {
    CycleId       cycleId;
    TaskId        taskId;
    ArgIdx        firstArg;
    TokenArgIdx  numArgs;
    // If set, this edge encodes a true data dependence through memory (producer writes, consumer reads)
    // This is used for selective execution: if the producer runs, the consumer
    // must run too, even if args match old ones.
    // TODO: It'd be good to have a better encoding that avoids the extra bit
    // (we can trim off a bit by leveraging fisrtArg[0] == 0 if numArgs == 0,
    // e.g., store fisrtArg[0] in args[1][0]).
    Bool          hasMemDataDep;
`ifdef RUNTIME_ANALYSIS
    Bit#(64)      cycleCreated;
`endif // RUNTIME_ANALYSIS
    Vector#(ArgsPerToken, Word) args;
} Token deriving(Bits, Eq, FShow);

// Packet tagged with a global id --- cores produce these
typedef struct {
    GlobalTileId dest;
    Token data;
} TokenPacket deriving(Bits, Eq, FShow);

// Packet tagged with a local id --- the task switch carries these as *data*.
// Note that the local tile id needs to be included because of cross-device
// links; the destination device needs to route the packet to their local tile.
typedef struct {
    TileId dest;
    Token data;
} TokenLocalPacket deriving(Bits, Eq, FShow);

typedef struct {
    TaskId taskId;
    Word taskFn;
    TaskSize taskSize;
    ArgMemIdx firstArgIdx;
    ArgIdx numArgs;
    NumInEdges numInEdges;
    NumOutEdges numOutEdges;
    TaskOutRegIdx numOutArgs;
    EdgeTableIdx firstEdgeIdxStart;
    NumInEdges numInEdgesReceivedFirstCycle;
    Bool firstCycleForce;
    Bool canSkip;
} TaskConfig deriving(Bits, Eq, FShow);
  
typedef struct {
    CycleId cycleId;
`ifdef RUNTIME_ANALYSIS
    TaskId  taskId;
`endif // RUNTIME_ANALYSIS
    Word taskFn;
    TaskSize taskSize; 
    ArgIdx numArgs;
    TokenSenderTaskMetadata enqInfo;
} Task deriving(Bits, Eq, FShow);

interface TaskUnit;
    method Action configTask(TaskConfig cfg);
    method Action configInitialArg(Word arg);
    method Bool tileEnablePerfCounters;

    // Communication with Core
    interface Vector#(NumCoresPerTile, SendCommit#(Task)) coreDeqs;
    method Tuple2#(CoreId, Word) coreArgDeq; // non-blocking

    // Communicattion of skipped tasks to TokenSender
    interface SendCommit#(TokenSenderTaskMetadata) skippedTaskMetadataDeq;

    // Enqueue
    // Communication with Core
    interface RecvCommit#(TokenPacket) tokenPacketIn;

    // Communication with Task Network
    interface SendCommit#(TokenPacket) toNetTokenPacket;
    interface RecvCommit#(Token) fromNetToken;

    // Sip
    interface SIP sip;
endinterface

// Implementation types
// 1. Task memory
// - Static information (to be read on dequeue)
typedef struct {
    Word taskFn;
    TaskSize taskSize;
    ArgIdx numArgs;
    NumOutEdges numOutEdges;
    TaskOutRegIdx numOutArgs;
    EdgeTableIdx firstEdgeIdxStart;
    Bool canSkip;
} TaskInfo deriving(Bits, Eq, FShow);

typedef struct {
    GlobalTileId configTileId;
    Bool hostFinishedConfig;
    Bool selfBarriers;
    // Number of tasks in this tile. Used is selfBarriers == True.
    // NOTE: ZERO-BASED, so value encodes num - 1. 1 task -> val is 0, etc.
    TaskId zbNumTasks;
    Bit#(32) maxSimCycle;
} SipControlReg deriving (Bits, FShow);


interface EnqueueArb;
    // Communication with Task Unit
    method Token token_first;
    method Action token_deq;

    // Communication with Core
    interface RecvCommit#(TokenPacket) tokenPacketIn;

    // Communication with Task Network
    interface SendCommit#(TokenPacket) toNetTokenPacket;
    interface RecvCommit#(Token) fromNetToken;
endinterface

module mkEnqueueArbiter#(Fmt name, SipControlReg controlReg, Wire#(Bool) perf_localEnq, Wire#(Bool) perf_networkEnq,
                         Wire#(Bool) perf_localTileEnqFifoDidEnq, Wire#(Bool) perf_localTileEnqFifoDidDeq,
                         Wire#(Bool) perf_outEnqsFifoDidEnq, Wire#(Bool) perf_outEnqsFifoDidDeq,
                         Wire#(Bool) perf_outEnqBaseQueueDidEnq, Wire#(Bool) perf_outEnqBaseQueueDidDeq,
                         Wire#(Bool) perf_outEnqPipeDidEnq, Wire#(Bool) perf_outEnqPipeDidDeq,
                         Wire#(Bool) perf_inEnqBaseQueueDidEnq, Wire#(Bool) perf_inEnqBaseQueueDidDeq,
                         Wire#(Bool) perf_inEnqPipeDidEnq, Wire#(Bool) perf_inEnqPipeDidDeq)
                         (EnqueueArb);

    // Accepting Core Enqs
    Integer localTileOutId = 0;
    Integer networkOutId = 1;

    Integer numTokenSenderPorts = 1;

    Switch#(1, 2, TokenPacket) taskCoresToNetwork <- mkSwitch;

    // Wrap core enqueue inputs
    RecvCommit#(TokenPacket) edgeEnqs_0 = interface RecvCommit#(TokenPacket);
        method Action datain (TokenPacket din) =
            taskCoresToNetwork.in[0].datain(SwitchReq{
                dest: (din.dest == controlReg.configTileId) ? fromInteger(localTileOutId) : fromInteger(networkOutId),
                data: din
            });
        method Bool accept = taskCoresToNetwork.in[0].accept;
    endinterface;

    // FIFO for local enqueues
    FIFOCountIfc#(Token, 16) localTileEnqFifo_ <- mkShiftFIFOCount;
    FIFOCountIfc#(Token, 16) localTileEnqFifo <- mkDebugFIFOCount(taskUnitDebug, name + $format("-localTileEnqFifo"), localTileEnqFifo_, asReg(perf_localTileEnqFifoDidEnq), asReg(perf_localTileEnqFifoDidDeq));
    // FIFO for enqs to task-unit
    FIFOF#(Token) outEnqsFifo_ <- mkPipelineFIFOF;
    FIFOF#(Token) outEnqsFifo <- mkDebugFIFOF(taskUnitDebug, name + $format("-outEnqsFifo"),  outEnqsFifo_, asReg(perf_outEnqsFifoDidEnq), asReg(perf_outEnqsFifoDidDeq));

    // Unwrap local enqueue output
    SendCommit#(Token) localTileEnq = interface SendCommit#(Token);
        method Token dataout 
            = taskCoresToNetwork.out[localTileOutId].dataout.data;
        method Action ack = taskCoresToNetwork.out[localTileOutId].ack;
    endinterface;
    
    mkConnection(localTileEnq, toPut(localTileEnqFifo));

    // Pipeline the task interfaces to improve timing.
    // NOTE: 2 decoupling stages seems to give the lowest WNS with a 300MHz
    // target; no decoupling gives -2.16ns, 1/2/3 stages are -0.745/498/609ns.
    // NOTE: A clear problem is that without this decoupling, Vivado doesn't
    // auto-pipeline the task swith interfaces sufficiently for some tiles;
    // this may be causing the high WNS. Revisit when we switch to a fully
    // contained interface!
    Integer decouplingStages = 2;
    FIFOCountIfc#(TokenPacket, 16) outEnqBaseQueue_ <- mkShiftFIFOCount;
    FIFOCountIfc#(TokenPacket, 16) outEnqBaseQueue <- mkDebugFIFOCount(taskUnitDebug, name + $format("-outEnqBaseQueue"), outEnqBaseQueue_, asReg(perf_outEnqBaseQueueDidEnq), asReg(perf_outEnqBaseQueueDidDeq));
    FIFOF#(TokenPacket) outEnqPipe_ <- mkPipedSkidFIFOF(outEnqBaseQueue, decouplingStages, decouplingStages);
    FIFOF#(TokenPacket) outEnqPipe <- mkDebugFIFOF(taskUnitDebug, $format("outEnqPipe"), outEnqPipe_, asReg(perf_outEnqPipeDidEnq), asReg(perf_outEnqPipeDidDeq));

    FIFOCountIfc#(Token, 16) inEnqBaseQueue_ <- mkShiftFIFOCount;
    FIFOCountIfc#(Token, 16) inEnqBaseQueue <- mkDebugFIFOCount(taskUnitDebug, name + $format("-inEnqBaseQueue"), inEnqBaseQueue_, asReg(perf_inEnqBaseQueueDidEnq), asReg(perf_inEnqBaseQueueDidDeq));
    FIFOF#(Token) inEnqPipe_ <- mkPipedSkidFIFOF(inEnqBaseQueue, decouplingStages, decouplingStages);
    FIFOF#(Token) inEnqPipe <- mkDebugFIFOF(taskUnitDebug, name + $format("-inEnqPipe"), inEnqPipe_, asReg(perf_inEnqPipeDidEnq), asReg(perf_inEnqPipeDidDeq));

    RecvCommit#(Token) fromNetToken_ <- mkRecvCommit(inEnqPipe);

    mkConnection(toGet(taskCoresToNetwork.out[networkOutId]), toPut(outEnqPipe));

    SendCommit#(TokenPacket) toNetTokenPacket_ <- mkSendCommit(outEnqPipe);

    (* descending_urgency = "enqSwitch, enqLocal" *)
    rule enqSwitch;
        outEnqsFifo.enq(inEnqPipe.first);
        inEnqPipe.deq;
        perf_networkEnq <= True;
    endrule
    rule enqLocal;
        //$display($time, " taking enq, load=", fshow(localTileEnqFifo.count));
        let e = localTileEnqFifo.first;
        localTileEnqFifo.deq;
        outEnqsFifo.enq(e);
        perf_localEnq <= True;
    endrule

    method Token token_first = outEnqsFifo.first;
    method Action token_deq = outEnqsFifo.deq;

    interface RecvCommit tokenPacketIn = edgeEnqs_0;

    interface SendCommit toNetTokenPacket   = toNetTokenPacket_;

    interface RecvCommit fromNetToken = fromNetToken_;
endmodule

(* synthesize *)
module mkTaskPrioQueue(PrioQueue#(CycledTaskIdx));
    // NOTE: This will work OK 4K-16K, but smaller and larger amounts won't
    // work well; we need to parameterize the number of levels.
    
    // This (or a 3-bit variant) MUST be the base queue; FlatBitmap does not
    // order accrording to the custom ordering function.
    PrioQueue#(CycledIdx#(Bit#(0))) l4 <- mkSmallPrioQueue;
    PrioQueue#(CycledIdx#(Bit#(TSub#(TaskIdBits, 8)))) l3 <- mkHierarchicalBitmapPrioQueue(l4, 1);
    PrioQueue#(CycledIdx#(Bit#(TSub#(TaskIdBits, 4)))) l2 <- mkHierarchicalBitmapPrioQueue(l3, 1);
    PrioQueue#(CycledTaskIdx) l1 <- mkHierarchicalBitmapPrioQueue(l2, 2);
    return l1;
endmodule

typedef struct {
   CycleId cycleId;
   t taskId; // NOTE: Retaining name to avoid conversion boilerplate; in general, these are a subset of taskId bits.
} CycledIdxFullyOrdered#(type t) deriving (Bits, Eq, FShow);

instance Ord#(CycledIdxFullyOrdered#(t)) provisos (Bits#(t, tBits), Ord#(t));
    function Bool \< (CycledIdxFullyOrdered#(t) a, CycledIdxFullyOrdered#(t) b);
        Bit#(TAdd#(CycleIdBits, 1)) aCycleId = extend(a.cycleId);
        Bit#(TAdd#(CycleIdBits, 1)) bCycleId = extend(b.cycleId);
        let cDiff = aCycleId - bCycleId;
        return (cDiff == 0)? a.taskId < b.taskId : cDiff[valueOf(CycleIdBits)] == 1;
    endfunction

    function Bool \<= (CycledIdxFullyOrdered#(t) a, CycledIdxFullyOrdered#(t) b);
        Bit#(TAdd#(CycleIdBits, 1)) aCycleId = extend(a.cycleId);
        Bit#(TAdd#(CycleIdBits, 1)) bCycleId = extend(b.cycleId);
        let cDiff = aCycleId - bCycleId;
        return (cDiff == 0)? a.taskId <= b.taskId : cDiff[valueOf(CycleIdBits)] == 1;
    endfunction
endinstance
interface DumpDeqState;

    method Action scheduledTask(CycledTaskIdx t);

    interface SIP hostCommandsSip;
    interface SIP sipSendSip;
endinterface

module mkDumpDeqState(DumpDeqState);

`ifdef FPGA_DEBUGGING
    PrioQueue#(CycledIdxFullyOrdered#(Bit#(0))) l4 <- mkSmallPrioQueue;
    PrioQueue#(CycledIdxFullyOrdered#(Bit#(TSub#(TaskIdBits, 8)))) l3 <- mkHierarchicalBitmapPrioQueue(l4, 1);
    PrioQueue#(CycledIdxFullyOrdered#(Bit#(TSub#(TaskIdBits, 4)))) l2 <- mkHierarchicalBitmapPrioQueue(l3, 1);
    PrioQueue#(CycledIdxFullyOrdered#(TaskId)) taskPQ <- mkHierarchicalBitmapPrioQueue(l2, 2);
`endif

    FIFOCountIfc#(CycledIdxFullyOrdered#(TaskId), 16) bufferFIFO <- mkShiftFIFOCount;

    SIPControlRegs#(2, Bit#(8)) hostCommands <- mkSIPControlRegs($format("%m-hostCommands"));

    Wire#(Bit#(32)) dataToSend <- mkDWire(420);
    Wire#(Bit#(32)) noTasksLeft <- mkDWire(0);
    SIP sipSend  <- mkSIPStatusRegs($format("%m-dataSend"), cons(dataToSend, cons(noTasksLeft, nil)));

    Reg#(Bool) start <- mkReg(False);


    rule kickStart if (!start && hostCommands.regsUpdated[0]);
        $display($time, "[%m-mkDumpDeqState] Started");
        start <= True;
    endrule

    rule consume if (start && hostCommands.regsUpdated[1]);
        $display($time, "[%m-mkDumpDeqState] Popping");
        bufferFIFO.deq;
    endrule

`ifdef FPGA_DEBUGGING
    rule putInBuffer;
        bufferFIFO.enq(taskPQ.min);
        taskPQ.popMin;
    endrule
`endif

    rule updateHead;
        dataToSend <= extend(pack(bufferFIFO.first));
    endrule
    rule updateEmpty;
        noTasksLeft <= extend(pack(bufferFIFO.notEmpty));
    endrule

    method Action scheduledTask(CycledTaskIdx idx);
`ifdef FPGA_DEBUGGING
        if (!start) begin
            taskPQ.push(CycledIdxFullyOrdered {cycleId: idx.cycleId, taskId: idx.taskId});
        end
`endif
    endmethod

    interface SIP hostCommandsSip = hostCommands.sip;
    interface SIP sipSendSip = sipSend;
endmodule

typedef 2 ArgsMemLatency;

(* synthesize *)
module mkTaskUnit(TaskUnit);
    // Task memories
    (* doc = "verilog_pragma: keep_hierarchy = 'true'" *)
    XRAM_PIPED_PORT#(TaskId, TaskInfo, 2) taskInfoMemXram <- mkXRAM1(unpack(0), NO_CHANGE, "auto");
    TaggedPortQueue#(TaskId, TaskInfo, Tuple2#(TaskId, CycleId), 16) taskInfoMemIX <- mkTaggedPortQueue(taskInfoMemXram, NO_CHANGE);

    XRAM_PIPED_DUAL_PORT#(TaskId, ArgMemIdx, TaskId, ArgMemIdx, 2) firstArgIdxMem <- mkXRAM2(0, READ_ONLY, NO_CHANGE, "block");
    TaggedPortQueue#(TaskId, ArgMemIdx, void, 16) firstArgIdxMemIX <- mkTaggedPortQueue(firstArgIdxMem.b, NO_CHANGE);

    XRAM_DUAL_PORT#(TaskId, NumInEdges, TaskId, NumInEdges) numInEdgesMinusOneMem <- mkXRAM2(0, READ_ONLY, WRITE_ONLY, "auto");
    XRAM_DUAL_PORT#(SubCycledTaskIdx, NumInEdges, SubCycledTaskIdx, NumInEdges) inEdgesArrivedMem <- mkXRAM2(0, READ_ONLY, WRITE_ONLY, "auto");
    
    XRAM_PIPED_DUAL_PORT#(SubCycledTaskIdx, Bool, SubCycledTaskIdx, Bool, 2) taskIsSkippableMem <-  mkXRAM2(False, READ_FIRST, WRITE_ONLY, "auto");
    TaggedPortQueue#(SubCycledTaskIdx, Bool, void, 16) taskIsSkippableMemIX <- mkTaggedPortQueue(taskIsSkippableMem.a, READ_FIRST);

    Vector#(2, XRAM_PIPED_DUAL_PORT_BE#(ArgMemIdx, ArgPair, 2, ArgsMemLatency)) argsMemXram <- replicateM(mkXRAM2BE(unpack(0), READ_ONLY, NO_CHANGE, "ultra"));

    // TODO: Make levels parameterizable (end up at a 32/64-bit base case)
    PrioQueue#(CycledTaskIdx) taskPQ <- mkTaskPrioQueue;

    // Performance
    Wire#(Bool) perf_token    <- mkDWire(False);
    Wire#(Bool) perf_localEnq     <- mkDWire(False);
    Wire#(Bool) perf_networkEnq   <- mkDWire(False);
    Wire#(Bool) perf_taskRunnable <- mkDWire(False);
    Wire#(Bool) perf_deqTask      <- mkDWire(False);
    Wire#(Bool) perf_skipTask     <- mkDWire(False);
    Wire#(Bool) perf_configTask   <- mkDWire(False);
    Wire#(Bool) perf_deqCoreStall <- mkDWire(False);
    Wire#(Bool) perf_deqTUStall   <- mkDWire(False);

    Vector#(10, Bool) perfInc = cons(perf_token,
                                    cons(perf_localEnq,
                                        cons(perf_networkEnq,
                                            cons(perf_taskRunnable,
                                                cons(perf_deqTask,
                                                    cons(perf_skipTask,
                                                        cons(perf_configTask,
                                                            cons(perf_deqCoreStall,
                                                                cons(perf_deqTUStall,
                                                                   cons(False,
                                                                        nil))))))))));

    Wire#(Bool) perf_localTileEnqFifoDidEnq       <- mkDWire(False);
    Wire#(Bool) perf_localTileEnqFifoDidDeq       <- mkDWire(False);
    Wire#(Bool) perf_outEnqsFifoDidEnq            <- mkDWire(False);
    Wire#(Bool) perf_outEnqsFifoDidDeq            <- mkDWire(False);
    Wire#(Bool) perf_outEnqBaseQueueDidEnq        <- mkDWire(False);
    Wire#(Bool) perf_outEnqBaseQueueDidDeq        <- mkDWire(False);
    Wire#(Bool) perf_outEnqPipeDidEnq             <- mkDWire(False);
    Wire#(Bool) perf_outEnqPipeDidDeq             <- mkDWire(False);
    Wire#(Bool) perf_inEnqBaseQueueDidEnq         <- mkDWire(False);
    Wire#(Bool) perf_inEnqBaseQueueDidDeq         <- mkDWire(False);
    Wire#(Bool) perf_inEnqPipeDidEnq              <- mkDWire(False);
    Wire#(Bool) perf_inEnqPipeDidDeq              <- mkDWire(False);

    Vector#(12, Bool) fifoInc = cons(perf_localTileEnqFifoDidEnq, cons(perf_localTileEnqFifoDidDeq,
                                cons(perf_outEnqsFifoDidEnq, cons(perf_outEnqsFifoDidDeq,
                                cons(perf_outEnqBaseQueueDidEnq, cons(perf_outEnqBaseQueueDidDeq,
                                cons(perf_outEnqPipeDidEnq, cons(perf_outEnqPipeDidDeq,
                                cons(perf_inEnqBaseQueueDidEnq, cons(perf_inEnqBaseQueueDidDeq,
                                cons(perf_inEnqPipeDidEnq, cons(perf_inEnqPipeDidDeq, nil))))))))))));


    // SIP
    SIPMux#(4) sipMux <- mkSIPMux($format("TaskUnit-Mux"));
    SIPControlRegs#(4, Bit#(16)) controlReg <- mkSIPControlRegs($format("TaskUnit-ControlReg"));
    SipControlReg controlRegTyped = SipControlReg {
        hostFinishedConfig: controlReg.regs[0][0] == 1,
        selfBarriers: controlReg.regs[0][1] == 1,
        zbNumTasks: truncate(controlReg.regs[0] >> 2),
        configTileId: unpack(truncate(pack(controlReg.regs[1]))),
        maxSimCycle: {controlReg.regs[3], controlReg.regs[2]}
    };

    Reg#(Bit#(32)) currSimCycle <- mkReg(0);
    Reg#(Bool) reachedMaxCycles <- mkReg(False);
    Reg#(Bool) enablePerfCounters <- mkReg(False);

    NonBlockingPipe#(Vector#(TAdd#(10, 12), Bool)) perfIncPiped <- mkNonBlockingPipe(2, replicate(False));
    rule pipePerfInc; perfIncPiped <= append(perfInc, fifoInc); endrule
    SIPCounters#(40) perfCounters <- mkSIPCounters($format("TaskUnitCounters"), perfIncPiped, enablePerfCounters);

    DumpDeqState dumpDeqState <- mkDumpDeqState;

    Fmt name = $format("TaskUnitDebug(%m)");

    Vector#(4, SIP) sipTargets = cons(controlReg.sip, cons(perfCounters, cons(dumpDeqState.hostCommandsSip, cons(dumpDeqState.sipSendSip, nil))));
    zipWithM_(mkConnection, sipMux.sipToTargets, sipTargets);

    Wire#(Maybe#(Task)) deqTaskM <- mkDWire(Invalid);
    Wire#(Bool) deqTaskAck <- mkDWire(False);

    Wire#(Maybe#(TokenSenderTaskMetadata)) deqSkippedTaskM <- mkDWire(Invalid);
    Wire#(Bool) deqSkippedTaskAck <- mkDWire(False);

    // Dequeue tasks to cores in round-robin order for load balance
    RoundRobinPrio#(NumCoresPerTile) roundRobin <- mkRoundRobinPrio;
    SendCommitArb#(NumCoresPerTile, Task) deqArb <- mkSendCommitArb(roundRobin.getPrio);

    // Enqueue Arbiter
    EnqueueArb enqArb <- mkEnqueueArbiter(name, controlRegTyped, asReg(perf_localEnq), asReg(perf_networkEnq),
                                            asReg(perf_localTileEnqFifoDidEnq), asReg(perf_localTileEnqFifoDidDeq),
                                            asReg(perf_outEnqsFifoDidEnq), asReg(perf_outEnqsFifoDidDeq),
                                            asReg(perf_outEnqBaseQueueDidEnq), asReg(perf_outEnqBaseQueueDidDeq),
                                            asReg(perf_outEnqPipeDidEnq), asReg(perf_outEnqPipeDidDeq),
                                            asReg(perf_inEnqBaseQueueDidEnq), asReg(perf_inEnqBaseQueueDidDeq),
                                            asReg(perf_inEnqPipeDidEnq), asReg(perf_inEnqPipeDidDeq));

`ifdef RUNTIME_ANALYSIS
    Reg#(Bit#(64)) currCycle <- mkReg(0);
    rule icc;
        currCycle <= currCycle + 1;
    endrule
`endif // RUNTIME_ANALYSIS

    rule watchControlReg if (controlReg.regsUpdated[0]);
        $display($time, ":  [", name, "-watchControlReg] Control Regs = ", fshow(controlRegTyped));
    endrule

    rule stopSimChecker if (controlRegTyped.hostFinishedConfig);
        Bool rmc = currSimCycle >= controlRegTyped.maxSimCycle;
        if (!enablePerfCounters && !rmc && (currSimCycle[3] == 1)) begin
            // Start after warmup
            enablePerfCounters <= True;
        end else if (enablePerfCounters) begin
            // Stop after max
            enablePerfCounters <= !rmc;
        end
        reachedMaxCycles <= rmc;
    endrule

    // Barrier control
    Reg#(CycleId) barrierEpoch <- mkReg(0);
    Reg#(TaskId) barrierTaskCount <- mkReg(0);
    PulseWire countTaskDequeued <- mkPulseWire;
    rule incBarrier if (countTaskDequeued);
        if (barrierTaskCount == controlRegTyped.zbNumTasks) begin
            barrierTaskCount <= 0;
            barrierEpoch <= barrierEpoch + 1;
            currSimCycle <= currSimCycle + 1;
            if (controlRegTyped.selfBarriers) $display($time, ": [", name, "] Self-barrier done", fshow(barrierTaskCount), " epoch" , fshow(barrierEpoch));
        end else begin
            barrierTaskCount <= barrierTaskCount + 1;
            //$display("NBBC up ", fshow(barrierTaskCount));
        end
    endrule

    // FIXME: This should go away once requestTask is non-blocking; popMin
    // delay is too tight to carry these conditions
    FIFO#(CycledTaskIdx) readyTask <- mkFIFO;

    rule deqTask if (controlRegTyped.hostFinishedConfig && (!controlRegTyped.selfBarriers || taskPQ.min.cycleId == barrierEpoch));
        readyTask.enq(taskPQ.min);
        taskPQ.popMin;
        countTaskDequeued.send;
        //$display($time, ": [", name, "] Deq Task: ", fshow(taskPQ.min), " epoch ", fshow(barrierEpoch));
    endrule

    rule requestTask if (controlRegTyped.hostFinishedConfig && (!reachedMaxCycles));
        // Put in the memory requests here
        CycledTaskIdx  addr = readyTask.first;
        readyTask.deq;
        taskInfoMemIX.putRead(addr.taskId, tuple2(addr.taskId, addr.cycleId));
        firstArgIdxMemIX.putRead(addr.taskId, ?);
        taskIsSkippableMemIX.putWriteRead(unpack(truncate(pack(addr))), True, ?); // mark next gen skippable, enq will unmark if needed
`ifdef TASK_UNIT_DEBUG
        $display($time, ": [", name, "] Preparing Runnable Task: ", fshow(addr));
`endif // TASK_UNIT_DEBUG
    endrule

    FIFOCountIfc#(Tuple4#(CycleId, ArgMemIdx, ArgIdx, CoreId), 16) argReadReqQ <- mkShiftFIFOCount;

    rule stageTaskDeq if (argReadReqQ.notFull);
        match {{.taskId, .cycleId}, .taskInfo} = taskInfoMemIX.first;
        match {._, .isSkippable} = taskIsSkippableMemIX.first;

        let enqInfo = TokenSenderTaskMetadata {
`ifdef RUNTIME_ANALYSIS
            taskFn            : taskInfo.taskFn,
`endif // RUNTIME_ANALYSIS
            numOutArgs        : taskInfo.numOutArgs,
            firstEdgeIdxStart : taskInfo.firstEdgeIdxStart,
            numOutEdges     : taskInfo.numOutEdges,
            cycleId           : cycleId
        };
      
        Bool skipTask = isSkippable && taskInfo.canSkip;

        Task t = Task{cycleId: cycleId,
`ifdef RUNTIME_ANALYSIS
                      taskId : taskId,
`endif // RUNTIME_ANALYSIS
                      taskFn: taskInfo.taskFn, taskSize: taskInfo.taskSize,
                      numArgs: taskInfo.numArgs, enqInfo: enqInfo};

        if (!skipTask) deqTaskM <= tagged Valid t;
        else deqSkippedTaskM <= tagged Valid enqInfo;
    endrule

    rule ackTaskDeq if ((isValid(deqTaskM) && deqTaskAck) || (isValid(deqSkippedTaskM) && deqSkippedTaskAck));
        taskInfoMemIX.deq;
        firstArgIdxMemIX.deq;
        taskIsSkippableMemIX.deq;
        if (isValid(deqTaskM)) perf_deqTask <= True;
        else perf_skipTask <= True;

        match {{.taskId, .cycleId}, .taskInfo} = taskInfoMemIX.first;
        match {._, .firstArgIdx} = firstArgIdxMemIX.first;
        match {.__, .isSkippable} = taskIsSkippableMemIX.first;

        if (isValid(deqTaskM)) begin
            let destCore = deqArb.destIdx;
            dynamicAssert(isValid(destCore), "if deqArb takes task, it should have a valid destIdx");

            if (taskInfo.numArgs != 0) begin
                argReadReqQ.enq(tuple4(cycleId, firstArgIdx, taskInfo.numArgs, pack(fromMaybe(?, destCore))));
            end
        end

        let cycledTaskIdx = CycledTaskIdx{cycleId: cycleId, taskId: taskId};
        dumpDeqState.scheduledTask(cycledTaskIdx);
    endrule

    // Decouple skippedTaskMetadata output. TODO(dsm): In theory this should be
    // important to performance, because TokenSender is mediating core requests
    // as well, and takes multiple enqs per edge. In practice though, I've
    // seen negligible perf difference in tests. So revisit this decoupling
    // once we have more selective execution tests.
    FIFOCountIfc#(TokenSenderTaskMetadata, 16) skippedTaskMetadataQ <- mkShiftFIFOCount;
    let skippedTaskMetadataQ_send <- mkSendCommit(fifoCountToFifof(skippedTaskMetadataQ));
    let skippedTaskMetadataQ_recv <- mkRecvCommit(fifoCountToFifof(skippedTaskMetadataQ));

    let skippedTaskMetadataQ_deq = interface SendCommit#(TokenSenderTaskMetadata);
        method TokenSenderTaskMetadata dataout if (deqSkippedTaskM matches tagged Valid .e) = e;
        method Action ack = deqSkippedTaskAck._write(True);
    endinterface;

    mkConnection(skippedTaskMetadataQ_deq, skippedTaskMetadataQ_recv);

`ifdef TASK_UNIT_DEBUG
    rule debugPrintScheduleTask;
        case (tuple2(deqTaskM, deqTaskAck)) matches
            {tagged Valid .deqT, True}: begin
                                            $display($time, ": [", name, "] Dequeuing Task: ", fshow(deqT));
            end
            default: noAction;
        endcase
    endrule
`endif // TASK_UNIT_DEBUG

    rule deqCoreStallTick;
        perf_deqCoreStall <= isValid(deqTaskM) && !deqTaskAck;
    endrule
    rule deqTUStallTick;
        perf_deqTUStall <= !isValid(deqTaskM) && deqTaskAck;
    endrule

`ifdef RUNTIME_ANALYSIS
    rule deqTaskFire if (deqTaskAck);
        if (deqTaskM matches tagged Valid .dt) begin
            $display($time, "-##-%m-##-TASK_UNIT_TRACE_SEND-##-taskId=", fshow(dt.taskId), "-##-cycleId=", fshow(dt.cycleId));
        end
    endrule
`endif // RUNTIME_ANALYSIS

    mkConnection(deqArb.in, interface SendCommit;
        method Task dataout if (deqTaskM matches tagged Valid .dt) = dt;
        method Action ack = deqTaskAck._write(True);
    endinterface);

    // Arg read and enqueue pipe; leverage that cores have non-blocking arg enqueues
    Reg#(ArgIdx) curArgIdx <- mkReg(0);
    NonBlockingPipe#(Maybe#(Tuple3#(SubCycleId, Bit#(1), CoreId))) readPipe <- mkDNonBlockingPipe(valueOf(ArgsMemLatency), Invalid, Invalid);

    rule readArg;
        match {.cycleId, .firstArgIdx, .numArgs, .coreId} = argReadReqQ.first;
        let argMemIdx = firstArgIdx + zeroExtend(curArgIdx >> 1);
        // $display($time, " [TaskUnit-readArg] firstArgIdx = ", fshow(firstArgIdx), " -- currArgIdx = ", fshow(curArgIdx), " -- cycleId = ", fshow(cycleId));
        argsMemXram[cycleId[0]].a.put(0 /* read */, argMemIdx, ?);
        readPipe <= Valid(tuple3(cycleId[0], curArgIdx[0], coreId));
        if (curArgIdx + 1 == numArgs) begin
            argReadReqQ.deq;
            curArgIdx <= 0;
        end else begin
            curArgIdx <= curArgIdx + 1;
        end
    endrule

    // NOTE: method coreArgDeq consumes readPipe + read arg, closes the pipe


    // Edge enqueue pipeline
    // 1. F Stage - fetch firstArgIdx, inEdge info, stall on conflict
    // 3. C stage - count remaining in edges
    // 2. R Stage - read previous arg, dispatch task if all edges received
    // 3. W stage - write current arg, compare with previous to detect
    //              ineffectual enqueues
    //
    // This pipeline is non-blocking after F; to enforce this, F detects
    // conflicts that would happen between R and W. R and W conflict when both
    // want to access the same argsMem XRAM, i.e., when the task ArgsMemLatency
    // cycles ahead has a different sub-cycle id.
    //
    // For simplicity, all enqueued edges follow this pipeline (even those that
    // do not have arguments)

    NonBlockingPipe#(Maybe#(SubCycleId)) conflictDetectionPipe <- mkDNonBlockingPipe(valueOf(ArgsMemLatency), Invalid, Invalid);
    NonBlockingPipe#(Maybe#(Token)) enqF2C <- mkDNonBlockingPipe(1, Invalid, Invalid);
    NonBlockingPipe#(Maybe#(Tuple3#(Token, NumInEdges, Bool))) enqC2R <- mkDNonBlockingPipe(1, Invalid, Invalid);
    NonBlockingPipe#(Maybe#(Tuple3#(Token, ArgMemIdx, Bool))) enqR2W <- mkDNonBlockingPipe(valueOf(ArgsMemLatency), Invalid, Invalid);

    // Requests for argsMem banks. Instead of valid bits, the first element is a mask on the cycleId used (this simplifies request issue logic)
    Wire#(Tuple2#(Bit#(2), ArgMemIdx)) argsMemRReq <- mkDWire(tuple2(0, ?));
    Wire#(Tuple4#(Bit#(2), Bit#(2), ArgMemIdx, ArgPair)) argsMemWReq <- mkDWire(tuple4(0, ?, ?, ?));
    NonBlockingPipe#(Tuple4#(Bit#(2), Bit#(2), ArgMemIdx, Word)) argsMemConfigReq <- mkDNonBlockingPipe(1, tuple4(0, ?, ?, ?), tuple4(0, ?, ?, ?));

    rule enqStage1F if (controlRegTyped.hostFinishedConfig);
        Token argsPacket = enqArb.token_first;
        SubCycleId subCycleId = truncate(argsPacket.cycleId);

        if (!isValid(conflictDetectionPipe) || fromMaybe(?, conflictDetectionPipe) == subCycleId) begin
            perf_token <= True;
            enqArb.token_deq;

`ifdef RUNTIME_ANALYSIS
            // Total cycles:
            Bit#(64) tookCycles = currCycle - argsPacket.cycleCreated;
            $display("EDGE_TIME,cycles=", fshow(tookCycles));
`endif // RUNTIME_ANALYSIS

            firstArgIdxMem.a.put(False, argsPacket.taskId, ?);
            enqF2C <= Valid(argsPacket);
            conflictDetectionPipe <= Valid(subCycleId);

            // Read edge count info
            numInEdgesMinusOneMem.a.put(False, argsPacket.taskId, ?);
            SubCycledTaskIdx scAddr = SubCycledTaskIdx{subCycleId: truncate(argsPacket.cycleId), taskId: argsPacket.taskId};
            inEdgesArrivedMem.a.put(False, scAddr, ?);
        end

        // else this is a stall due to conflict
    endrule

    // Bypass paths for in edges count in C stage
    Wire#(Maybe#(Tuple2#(SubCycledTaskIdx, NumInEdges))) curInEdgesArrivedUpdate <- mkDWire(Invalid);
    Reg#(Maybe#(Tuple2#(SubCycledTaskIdx, NumInEdges))) lastInEdgesArrivedUpdate <- mkReg(Invalid);
    // Runs late
    (* no_implicit_conditions, fire_when_enabled *)
    rule updateBypassReg;
        lastInEdgesArrivedUpdate <= curInEdgesArrivedUpdate;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule enqStage2C if (enqF2C matches tagged Valid .argsPacket);
        // Compute new in edge count
        let scAddr = SubCycledTaskIdx{subCycleId: truncate(argsPacket.cycleId), taskId: argsPacket.taskId};

        // Bypass in priority order
        NumInEdges inEdgesArrived;
        if (isValid(curInEdgesArrivedUpdate) && tpl_1(fromMaybe(?, curInEdgesArrivedUpdate)) == scAddr) begin
            inEdgesArrived = tpl_2(fromMaybe(?, curInEdgesArrivedUpdate));
        end else if (isValid(lastInEdgesArrivedUpdate) && tpl_1(fromMaybe(?, lastInEdgesArrivedUpdate)) == scAddr) begin
            inEdgesArrived = tpl_2(fromMaybe(?, lastInEdgesArrivedUpdate));
        end else begin
            inEdgesArrived = inEdgesArrivedMem.a.read;
        end

        let numInEdgesMinusOne = numInEdgesMinusOneMem.a.read;
        Bool lastArrival = inEdgesArrived == numInEdgesMinusOne;

        enqC2R <= Valid(tuple3(argsPacket, inEdgesArrived, lastArrival));

`ifdef RUNTIME_ANALYSIS
        $display($time, "-##-%m-##-TASK_UNIT_TRACE_ARRIVAL-##-taskId=", fshow(scAddr.taskId), "-##-cycleId=", fshow(scAddr.cycleId), "-##-arrivedInEdges=", fshow(inEdgesArrived+1), "-##-totalInEdges=", fshow(numInEdgesMinusOne+1), "-##-lastArrival=", fshow(lastArrival));
`endif // RUNTIME_ANALYSIS

`ifdef TASK_UNIT_DEBUG
        let fullAddr = CycledTaskIdx{cycleId: argsPacket.cycleId, taskId: argsPacket.taskId};
        $display($time, ": [", name, "] Parent Arrival -- Task: ", fshow(fullAddr), " count=%d arrived=%d", numInEdgesMinusOne+1, inEdgesArrived+1);
`endif // TASK_UNIT_DEBUG
    endrule

    // NOTE(dsm): Tasks are pushed to taskPQ in stage 3 (R), but the last arg
    // writes happen in stage 4 (W). Given the current latencies, this is a
    // benign race: there is NO WAY that dispatched tasks have a shot at
    // reading stale data, because taskPQ takes time and dispatched tasks need
    // to fetch firstArgIdx before reading args. So I'm leaving early to reduce
    // latency, but if ArgsMemLatency grows beyond ~3 cycles, this could become
    // a problem. Hence, let's ensure this:
    staticAssert(valueOf(ArgsMemLatency) <= 3, "ArgsMemLatency is high, check for race in enq pipeline");

    (* no_implicit_conditions, fire_when_enabled *)
    rule enqStage3R if (enqC2R matches tagged Valid {.argsPacket, .inEdgesArrived, .lastArrival});
        let scAddr = SubCycledTaskIdx{subCycleId: truncate(argsPacket.cycleId), taskId: argsPacket.taskId};

        let nextInEdgesArrived = lastArrival? 0 : (inEdgesArrived + 1);
        inEdgesArrivedMem.b.put(True, scAddr, nextInEdgesArrived);
        curInEdgesArrivedUpdate <= Valid(tuple2(scAddr, nextInEdgesArrived));

        // Read value from PREVIOUS generation
        let firstArgIdx = firstArgIdxMem.a.read;
        let argMemIdx = firstArgIdx + zeroExtend(argsPacket.firstArg >> 1);
        argsMemRReq <= tuple2({~argsPacket.cycleId[0], argsPacket.cycleId[0]}, argMemIdx);

        enqR2W <= Valid(tuple3(argsPacket, argMemIdx, lastArrival));
    endrule

    //(* conflict_free = "enqStage2R, enqStage4W" *)
    (* descending_urgency = "enqStage4W, configTask" *)
    (* no_implicit_conditions, fire_when_enabled *)
    rule enqStage4W if (enqR2W matches tagged Valid {.argsPacket,.argMemIdx, .lastArrival});
        let scAddr = SubCycledTaskIdx{subCycleId: truncate(argsPacket.cycleId), taskId: argsPacket.taskId};
        if (lastArrival) begin
            // NOTE(farese): dsm note was when this was happening in enqStage3R
            // NOTE(dsm): Done here because doing it in previous stage affected
            // the critical path, but this should be revisited once we have
            // better tile-level placement

            // NOTE(farese): Moved to enqStage4W because of a race condition:
            //               if taskPQ is empty, then as soon as we push it'll be deq'ed.
            //               I was observing cases with SE where we deq before we write to taskIsSkippableMem,
            //               Thus we assume that we can skip even though we can't
            let addr = CycledTaskIdx{cycleId: argsPacket.cycleId, taskId: argsPacket.taskId};
            //$display($time, " [enqStage3R] pushing to taskPQ: addr = ", fshow(addr), " -- scAddr = ", fshow(scAddr), " -- argsPacket = ", fshow(argsPacket));
            taskPQ.push(addr);
            perf_taskRunnable <= True;
        end

        // Write new arg
        Bool isNullMessage = argsPacket.numArgs == 3;
        Bit#(2) numArgs = isNullMessage? argsPacket.args[0][1:0] : argsPacket.numArgs;

        // FIXME(dsm): It'd be more space-efficient to encode the mask in the packet
        Bit#(2) mask;
        mask[0] = ~argsPacket.firstArg[0];
        mask[1] = argsPacket.firstArg[0] | numArgs[1];
        if (numArgs == 0) mask = 0;

        // Check two-arg writes are aligned
        dynamicAssert(argsPacket.firstArg[0] == 0 || numArgs == 1, "unaligned write (or numArgs out of bounds)");

        // FIXME(dsm): For now, 1-arg packets are not aligned, so just replicate first arg
        let wrArgs = argsPacket.args;
        if (argsPacket.numArgs == 1) wrArgs[1] = wrArgs[0]; // NOTE: Using argsPacket.numArgs instead of numArgs is OK & cheaper (with null messages, wrArgs is overriden anyway)

        // Detect if enqueue is ineffectual
        let prevArgs = argsMemXram[~argsPacket.cycleId[0]].b.read;
        if (isNullMessage) wrArgs = prevArgs;

        argsMemWReq <= tuple4({argsPacket.cycleId[0], ~argsPacket.cycleId[0]}, mask, argMemIdx, wrArgs);

        Bool sameArgs = ((mask[0] == 0) || (wrArgs[0] == prevArgs[0])) && ((mask[1] == 0) || (wrArgs[1] == prevArgs[1]));
        Bool cantSkip = !sameArgs || argsPacket.hasMemDataDep;

        dynamicAssert(!isNullMessage || sameArgs, "null messages can't differ in args!");
        //if (isNullMessage) $display("Null message ", fshow(argsPacket), " | prev = ", fshow(prevArgs), " | mask = ", mask);
        //if (cantSkip) $display("Effectual message ", fshow(argsPacket), " | prev = ", fshow(prevArgs), " | mask = ", mask);

        if (cantSkip) taskIsSkippableMem.b.put(True, scAddr, False);
    endrule


    (* no_implicit_conditions, fire_when_enabled *)
    rule issueArgsMemBPortReqs;
        for (Integer bank = 0; bank < 2; bank = bank + 1) begin
            if (argsMemWReq matches {.b, .mask, .addr, .wdata} &&& b[bank] == 1) begin
// `ifdef TASK_UNIT_DEBUG
//                 $display($time, " [issueArgsMemBPortReqs-WrReg] bank = ", bank, " -- addr = ", fshow(addr), " -- mask = ", fshow(mask), " -- data: ", fshow(wdata));
// `endif // TASK_UNIT_DEBUG
                argsMemXram[bank].b.put(mask, addr, wdata);
            end else if (argsMemConfigReq matches {.b, .mask, .addr, .arg} &&& b[bank] == 1) begin
// `ifdef TASK_UNIT_DEBUG
//                 $display($time, " [issueArgsMemBPortReqs-CONFIG] bank = ", bank, " -- addr = ", fshow(addr), " -- mask = ", fshow(mask), " -- data: ", fshow(arg));
// `endif // TASK_UNIT_DEBUG
                argsMemXram[bank].b.put(mask, addr, replicate(arg));
            end else begin
                argsMemXram[bank].b.put(0, tpl_2(argsMemRReq), ?);
            end

            Bit#(2) totalReqs = {1'b0, tpl_1(argsMemRReq)[bank]} + {1'b0, tpl_1(argsMemWReq)[bank]} + {1'b0, tpl_1(argsMemConfigReq)[bank]};
            dynamicAssert(totalReqs <= 1, "conflicting requests for argsMemi!");
        end
    endrule

    // Configuration

    // Initial arguments are written one at a time, interleaved by subCycleId,
    // then sequential (e.g., arg idx=0 subCycleId=0, then idx=0 subCycleId=1,
    // then idx=1 subCycleId=0, etc.)
    Reg#(Bit#(TAdd#(SizeOf#(ArgMemIdx), 2))) initialArgIdx <- mkReg(0);
    FIFO#(Word) initialArgQ <- mkFIFO1;

    rule configInitialArgs;
        Bit#(2) wmask = initialArgIdx[1] == 1? 2'b10 : 2'b01;
        ArgMemIdx waddr = truncate(initialArgIdx >> 2);
        argsMemConfigReq <= tuple4({initialArgIdx[0], ~initialArgIdx[0]}, wmask, waddr, initialArgQ.first);
        initialArgQ.deq;
        initialArgIdx <= initialArgIdx + 1;
        //$display("init arg[", fshow(waddr), fshow(wmask), "] = ", fshow(initialArgQ.first));
    endrule

    // rule debugCoreArgDeq if (readPipe matches tagged Valid .rp);
    //     match {.subCycleId, .wordSel, .coreId} = rp;
    //     $display($time, " [coreArgDeq] subCycleId = ", fshow(subCycleId), " -- wordSel =", fshow(wordSel), " -- all data = ", fshow(argsMemXram[subCycleId].a.read()), " -- selectedWord = ", fshow(argsMemXram[subCycleId].a.read()[wordSel]));
    // endrule

    interface SIP sip = sipMux.sipFromSource;

    // FIXME(dsm): Added enqC2R guard to avoid conflict with enqStage3R... rework conflicts
    method Action configTask(TaskConfig cfg) if (!controlRegTyped.hostFinishedConfig && !isValid(enqC2R));
        perf_configTask <= True;
        let info = TaskInfo {
            taskFn            : cfg.taskFn,
            taskSize          : cfg.taskSize,
            numArgs           : cfg.numArgs,
            numOutEdges       : cfg.numOutEdges,
            numOutArgs        : cfg.numOutArgs,
            firstEdgeIdxStart : cfg.firstEdgeIdxStart,
            canSkip           : cfg.canSkip
        };
        taskInfoMemIX.putWrite(cfg.taskId, info);
        numInEdgesMinusOneMem.b.put(True, cfg.taskId, cfg.numInEdges - 1);
        firstArgIdxMemIX.putWrite(cfg.taskId, cfg.firstArgIdx);

        let scAddr = SubCycledTaskIdx {taskId: cfg.taskId, subCycleId: 0};
        inEdgesArrivedMem.b.put(True, scAddr, cfg.numInEdgesReceivedFirstCycle);

        if (cfg.firstCycleForce) begin
            let taskAddr = CycledTaskIdx {taskId: cfg.taskId, cycleId: 0};
            taskPQ.push(taskAddr);
`ifdef RUNTIME_ANALYSIS
            $display($time, "-##-%m-##-TASK_UNIT_TRACE_ARRIVAL-##-taskId=", fshow(cfg.taskId), "-##-cycleId=", fshow(0), "-##-arrivedInEdges=", fshow(cfg.numInEdges), "-##-totalInEdges=", fshow(cfg.numInEdges), "-##-lastArrival=", fshow(True));
`endif // RUNTIME_ANALYSIS
        end

`ifdef TASK_UNIT_DEBUG
        $display($time, ": [", name, "] Config Task: ", fshow(cfg));
`endif // TASK_UNIT_DEBUG
    endmethod


    method Bool tileEnablePerfCounters = enablePerfCounters;

    method Action configInitialArg(Word arg) = initialArgQ.enq(arg);

    interface Vector coreDeqs = deqArb.outs;

    interface skippedTaskMetadataDeq = skippedTaskMetadataQ_send;

    method Tuple2#(CoreId, Word) coreArgDeq if (readPipe matches tagged Valid .rp);
        match {.subCycleId, .wordSel, .coreId} = rp;
        return tuple2(coreId, argsMemXram[subCycleId].a.read()[wordSel]);
    endmethod

    interface RecvCommit tokenPacketIn          = enqArb.tokenPacketIn;
    interface SendCommit toNetTokenPacket   = enqArb.toNetTokenPacket;
    interface RecvCommit fromNetToken = enqArb.fromNetToken;
endmodule


