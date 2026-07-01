/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Assert::*;
import CommitIfc::*;
import FIFO::*;
import FIFOF::*;
import FIFOLevel::*;
import NonBlockingPipe::*;
import ShiftFIFO::*;
import SkidFIFO::*;
import SpecialFIFOs::*;
import Vector::*;
import Cntrs::*;

import XRAM::*;
import XRegFile::*;
import XRAMUtils::*;
import LotusGlobalConfig::*;
import MainMemTypes::*;
import Switch::*;
import NonBlockingFIFO::*;
import DebugWrappers::*;

//`define L2_BANK_DEBUG

`ifdef L2_BANK_DEBUG
Bool l2BankDebug = True; // dsm: FIFO debug statements
`else
Bool l2BankDebug = False;
`endif

// Interface structs

// Core side
// FIXME: Duplicated from core---should import instead
typedef enum {ICACHE, DCACHE} CacheType deriving (Bits, Eq, FShow);
typedef Bit#(2) ICacheRespId;
typedef struct {
    CacheType destCache;
    ICacheRespId icacheRespId;
} CoreRespId deriving (Bits, Eq, FShow);
function CoreRespId getCoreRespId(MemReq req) = unpack(truncate(req.data));

typedef struct {
    Bit#(4) wrMask; // all-zeros = load line; else store
    WordAddr wordAddr;
    Word data; // for stores only
} MemReq deriving (Bits, Eq, FShow);

typedef struct {
    MemReq req;
    CoreId coreId;
} CoreReq deriving (Bits, Eq, FShow);

// Divide cores into even and odd, potentially with different id sizes
typedef TDiv#(NumCoresPerTile, 2) NumEvenCores; // note this is 1 if NumCoresPerTile=1; TDiv gives the ceiling
// To make this compile with 1 core, we need to special-case NumOddCores to not
// be 0; the Odd port will just be left unconnected in this case
typedef TMax#(1, TSub#(NumCoresPerTile, NumEvenCores)) NumOddCores;

typedef Bit#(TLog#(NumEvenCores)) EvenCoreId;
typedef Bit#(TLog#(NumOddCores)) OddCoreId;

typedef union tagged  {
   Tuple2#(EvenCoreId, CoreRespId) CoreCLRdEven;
   void EvictCLRd;
} CacheLineAccTagEven deriving (Bits, Eq, FShow);

// Odd port reads are used only for replies, not evictions
typedef union tagged  {
   Tuple2#(OddCoreId, CoreRespId) CoreCLRdOdd;
} CacheLineAccTagOdd deriving (Bits, Eq, FShow);

typedef SwitchReq#(NumEvenCores, Tuple2#(CoreRespId, Chunk)) CoreReadRespEven;
typedef SwitchReq#(NumOddCores, Tuple2#(CoreRespId, Chunk)) CoreReadRespOdd;

// NOTE: No CoreWriteResp, core write-throughs are unacknowledged


/* Request serialization is per-set; to reduce implementation cost, we group sets into buckets */ 

// Currently, up to 6 bits == 64 buckets
typedef Bit#(TMin#(SetSelBits, 6)) SetBucket;
function SetBucket setToBucket(SetSel set) = truncate(set);
function SetBucket wordAddrToBucket(WordAddr wa) = setToBucket(wa.set);

interface ReqSerializer;
    method Action lock(SetBucket v);
    method Action unlock(SetBucket v);
    method Bool isLocked(SetBucket v);
endinterface

// This implementation leverages LUTRAM instead of registers to track
// per-bucket lock state, because LUTRAM gives much higher density than
// registers and makes bucket indexing nearly free.
// 
// The challenge is that LUTRAM supports at most one write per cycle, so having
// a "locked" bit would make lock and unlock conflict, which is bad because we
// want a pipeline. To make them conflict-free, we use two memories, each
// toggled by lock or unlock, and an alternating-bit protocol.
//
// With 64 buckets, this takes a grand total of 9 LUTs :)
module mkReqSerializer(ReqSerializer);
    XRegFile#(SetBucket, Bool) acquirePhase <- mkXRegFile(False);
    XRegFile#(SetBucket, Bool) releasePhase <- mkXRegFile(False);

    method Action lock(SetBucket v) = acquirePhase.write(v, !acquirePhase.read1(v));
    method Action unlock(SetBucket v) = releasePhase.write(v, !releasePhase.read1(v));
    method Bool isLocked(SetBucket v) = acquirePhase.read2(v) != releasePhase.read2(v);
endmodule

/* Request queue: Avoids head-of-line blocking by serving requests out of
 * order; hovever, it ALWAYS serves same-bucket requests in FIFO order.
 */

interface ReqQueue;
    interface RecvCommit#(CoreReq) reqIn;
    method ActionValue#(CoreReq) next;
    method Action unlock(CoreReq r);
    method Bool notEmpty;
endinterface

typedef Bit#(3) ReqIdx; // 8 reqs should be more than enough
typedef Bit#(4) ReqPtr; 

module mkReqQueue(ReqQueue);
    XRegFile#(ReqIdx, CoreReq) reqs <- mkXRegFile(?);

    // head = next to alloc; tail = next to dealloc; cur = next to serve
    Reg#(ReqPtr) head <- mkReg(0);
    Reg#(ReqPtr) tail <- mkReg(0);
    Reg#(ReqPtr) cur <- mkReg(0);
    
    // When a request is served OOO, we put it here, so we can skip it next time
    XRegFile#(ReqIdx, Bool) alreadyServed <- mkXRegFile(False);

    ReqSerializer reqSerializer <- mkReqSerializer;

    Wire#(Bool) isEmpty <- mkBypassWire;
    Wire#(Bool) isFull <- mkBypassWire;
    Wire#(CoreReq) curReq <- mkBypassWire;
    Wire#(Bool) curIsAlreadyServed <- mkBypassWire;
    Wire#(Bool) curIsLocked <- mkBypassWire;
    rule curState;
        ReqPtr diff = head - tail;
        isEmpty <= diff == 0;
        isFull <= diff[valueOf(SizeOf#(ReqPtr))-1] == 1;
        let cr = reqs.read1(truncate(cur));
        curReq <= cr;
        curIsAlreadyServed <= alreadyServed.read1(truncate(cur));
        curIsLocked <= reqSerializer.isLocked(wordAddrToBucket(cr.req.wordAddr));
    endrule

    // Actions
    Wire#(Bool) curServed <- mkDWire(False);
    Wire#(Bool) unlocked <- mkDWire(False);

    // Manage tail and cur depending on actions
    rule tick;
`ifdef L2_BANK_DEBUG
        if (!isEmpty) $display($time, " %m: head=%d tail=%d elems=%d | cur=%d cs=%d cas=%d cl=%d", head, tail, head - tail, cur, curServed, curIsAlreadyServed, curIsLocked);
`endif
        if (!isEmpty && (curServed || curIsAlreadyServed) && cur == tail) begin
            // Dealloc sweep
            tail <= tail + 1;
            cur <= cur + 1;
            alreadyServed.write(truncate(cur), False);
        end else if (unlocked) begin
            // Rewind on unlocks to serve all same-lock reqs in FIFO order
            cur <= tail;
        end else if (!isEmpty && (curServed || curIsLocked) && (cur + 1) != head) begin
            // Move to next request, till the end of the queue
            cur <= cur + 1;
        end

        if (curServed && cur != tail) begin
            alreadyServed.write(truncate(cur), True);
        end
    endrule

    method ActionValue#(CoreReq) next if (!isEmpty && !curIsAlreadyServed && !curIsLocked);
        curServed <= True;
        reqSerializer.lock(wordAddrToBucket(curReq.req.wordAddr));
        return curReq;
    endmethod
    
    method Action unlock(CoreReq r);
        unlocked <= True;
        reqSerializer.unlock(wordAddrToBucket(r.req.wordAddr));
    endmethod

    interface reqIn = interface RecvCommit#(CoreReq);
        method Action datain (CoreReq din);
            if (!isFull) begin
                reqs.write(truncate(head), din);
                head <= head + 1;
            end
        endmethod

        method Bool accept = !isFull;
    endinterface;

    method Bool notEmpty = !isEmpty;
endmodule


/* Data array port - specialized to have burst requests and use decoupling through ShiftFIFOs */

interface DataPort#(type tag_t);
    // NOTE: Now supports read and write reqs through the same port; this causes less muxing
    // NOTE: For the URAM pipeline to be inferred, writes must happen to the
    // put method of the pipelined port; back when this was a read-only port,
    // this prevented pipelining for a while. 
    method Action putReq(Bool isWrite, ChunkBE chunkWe, DataArrayIdx addr, Chunk data, tag_t tag);
    method Action deq;
    method Tuple2#(tag_t, Chunk) first;

    method Bool conflict(TagArrayIdx addr);
endinterface

// Read port latency. The URAM feeds right into the outQueue, so not much
// pipelining is needed. These are chosen based on the bank size, to avoid
// becoming the critical path (~2ns; also, take into account URAMs are often
// far away, and not skimping on pipelining helps placement).
typedef TMin#(TSub#(TMax#(a, b), b), 1) IsGreaterThan#(numeric type a, numeric type b); // 1 if a > b, else 0
typedef IsGreaterThan#(1, x) IsNot#(numeric type x); // 0 if x == 1, 1 if x == 0
typedef TAdd#(TMul#(cond, a), TMul#(IsNot#(cond), b)) Choose#(numeric type cond, numeric type a, numeric type b); // (cond)? a : b, where cond must be 0 or 1
// 4 cycles if bank > 128KB, else 2 cycles
typedef Choose#(IsGreaterThan#(BankSizeBytes, TMul#(128, 1024)), 4, 2) DataPortLatency;

module mkDataPort#(XRAM_PIPED_PORT_BE#(DataArrayIdx, Chunk, ChunkBEBits, DataPortLatency) p)(DataPort#(tag_t))
    provisos(Bits#(tag_t, tagSz), FShow#(tag_t), FShow#(Tuple5#(Bool, ChunkBE, TagArrayIdx, Chunk, tag_t)));

    Integer readStages = valueOf(DataPortLatency);
    Integer feedbackStages = 2;

    Vector#(10, Wire#(Bool)) fifoCounters <- replicateM(mkDWire(False));

    FIFOF#(Tuple5#(Bool, ChunkBE, TagArrayIdx, Chunk, tag_t)) reqQueue_ <- mkPipelineFIFOF; //(False, True); // == PipelineFIFOF guarded on enq, unguarded on deq
    FIFOF#(Tuple5#(Bool, ChunkBE, TagArrayIdx, Chunk, tag_t)) reqQueue <- mkDebugFIFOF(l2BankDebug, $format("(%m)-reqQueue"), reqQueue_, fifoCounters[0], fifoCounters[1]);
    Reg#(ChunkSel) chunkIdx[2] <- mkCReg(2, ?);

    FIFOCountIfc#(Chunk, 16) outBaseQueue_ <- mkGShiftFIFOCountInit(True, True, nil);
    FIFOCountIfc#(Chunk, 16) outBaseQueue <- mkDebugFIFOCount(l2BankDebug, $format("(%m)-outBaseQueue"), outBaseQueue_, fifoCounters[2], fifoCounters[3]);

    SkidFIFO#(Chunk) outQueue_ <- mkSkidFIFO(outBaseQueue, readStages, feedbackStages);
    SkidFIFO#(Chunk) outQueue <- mkDebugSkidFIFO(l2BankDebug, $format("(%m)-outQueue"), outQueue_, fifoCounters[4], fifoCounters[5]);


    // Cycle optimization: the tag queue runs one cycle ahead of the data
    // queue, so the tags can be in registers
    FIFOCountIfc#(tag_t, 16) outTagBuffer_ <- mkGShiftFIFOCountInit(True, False, nil);
    FIFO#(tag_t) outTagQueue_ <- mkPipelineFIFO;

    FIFOCountIfc#(tag_t, 16) outTagBuffer <- mkDebugFIFOCount(l2BankDebug, $format("(%m)-outTagBuffer"), outTagBuffer_, fifoCounters[6], fifoCounters[7]);
    FIFO#(tag_t) outTagQueue <- mkDebugFIFO(l2BankDebug, $format("(%m)-outTagQueue"), outTagQueue_, fifoCounters[8], fifoCounters[9]);

    NonBlockingPipe#(Maybe#(tag_t)) readTagPipe <- mkDNonBlockingPipe(readStages-1, Invalid, Invalid);
    NonBlockingPipe#(Bool) readDataPipe <- mkDNonBlockingPipe(readStages, False, False);

    // Should fire early
    rule fillOutTagBuffer if (readTagPipe matches tagged Valid .readTag);
        outTagBuffer.enq(readTag);
    endrule

    rule feedOutTagQueue;
        outTagQueue.enq(outTagBuffer.first);
        outTagBuffer.deq;
    endrule

    rule fillOutQueue if (readDataPipe);
        outQueue.enq(p.read);
    endrule

    // NOTE: Guard enables writes to be served immediately, which is important to avoid races (see concurrency analysis in access rule)
    rule processReq if (reqQueue.first matches {.isWrite, .chunkWe, .lineIdx, .writeData, .readTag} &&& (isWrite || outQueue.hasSkidSlot));
        let dataArrayIdx = DataArrayIdx{set: lineIdx.set, cs: chunkIdx[0], ws: lineIdx.ws};
        p.put(chunkWe, dataArrayIdx, writeData);
        
        if (!isWrite) begin
            readTagPipe <= Valid(readTag);
            readDataPipe <= True;
            chunkIdx[0] <= chunkIdx[0] + 1;

            if (chunkIdx[0] == fromInteger(valueOf(FinalChunkId))) begin
                reqQueue.deq;
            end
        end else begin
            reqQueue.deq;
        end
    endrule
    
    // Conflict detection (FIXME: Remove after accesses are serialized properly, see FIXME in access rule)
    Wire#(Maybe#(TagArrayIdx)) conflictAddr <- mkDWire(Invalid);
    // Should fire early
    rule setConflictAddr;
        conflictAddr <= Valid(tpl_3(reqQueue.first));
    endrule


    method Action putReq(Bool isWrite, ChunkBE chunkWe, DataArrayIdx addr, Chunk data, tag_t tag);
        let tagArrayIdx = TagArrayIdx{set: addr.set, ws: addr.ws};
        reqQueue.enq(tuple5(isWrite, chunkWe, tagArrayIdx, data, tag));
        chunkIdx[1] <= isWrite? addr.cs : 0;
    endmethod

    method Action deq;
        outTagQueue.deq;
        outQueue.deq;
    endmethod

    method Tuple2#(tag_t, Chunk) first = tuple2(outTagQueue.first, outQueue.first);

    method Bool conflict(TagArrayIdx addr) = isValid(conflictAddr) && fromMaybe(?, conflictAddr) == addr;
endmodule

/* Replacement policy */

typedef Vector#(TSub#(L2NumWays, 1), WaySel) LRUInfo;

function LRUInfo initialLRUInfo;
    LRUInfo v;
    for (Integer i = 0; i < valueOf(L2NumWays)-1; i = i + 1) v[i] = fromInteger(i);
    return v;
endfunction

function WaySel getVictimWay(LRUInfo repl) = repl[0];

function LRUInfo updateLRUInfo(LRUInfo repl, WaySel accessedWay);
    // NOTE: This looks complex, but should be 2 LUT6s for 4 ways
    WaySel prevWay = ?;
    for (Integer i = 0; i < valueOf(L2NumWays); i = i + 1) begin
        if (findElem(fromInteger(i), repl) == Invalid) prevWay = fromInteger(i);
    end

    Vector#(L2NumWays, WaySel) fullRepl = append(repl, cons(prevWay, nil));

    LRUInfo newRepl = ?;
    Bool found = False;
    for (Integer i = 0; i < valueOf(L2NumWays)-1; i = i + 1) begin
        if (accessedWay == fullRepl[i]) found = True;
        newRepl[i] = found? fullRepl[i+1] : fullRepl[i];
    end

    return newRepl;
endfunction

typedef struct {
    Vector#(L2NumWays, Bool) dirty;
    LRUInfo replInfo;
} SetStatus deriving(Bits, Eq, FShow);


/* Helpers to compute even-odd core ids */

// FIXME: From Sip.bsv, dedup
function Bit#(n) castWidth(Bit#(m) v);
    Bit#(n) res = 0;
    // NOTE: This for loop works with Bit#(0); bit-slicing doesn't
    for (Integer i = 0; i < valueOf(TMin#(n, m)); i = i + 1) res[i] = v[i];
    return res;
endfunction

function Bool isEven(CoreId id);
    Bit#(1) lsb = castWidth(id); // note id can be 0 bits
    return lsb == 0;
endfunction

function EvenCoreId toEven(CoreId id) = castWidth(id >> 1);
function OddCoreId toOdd(CoreId id) = castWidth(id >> 1);


/* Cache interfaces */

interface Ifc_CoreCacheBank;
    interface RecvCommit#(CoreReq) req;
    interface SendCommit#(CoreReadRespEven) readRespEven;
    interface SendCommit#(CoreReadRespOdd) readRespOdd;
endinterface

interface Ifc_CacheBankMem;
    interface SendCommit#(BankLineReadReq) lineReadReq;
    interface RecvCommit#(BankChunkReadResp) chunkReadResp;
    interface SendCommit#(BankLineWriteReq) lineWriteReq;
    interface SendCommit#(Chunk) chunkWriteReq;
    interface RecvCommit#(BankLineWriteResp) lineWriteResp;
endinterface

interface L2CacheBank;
    interface Ifc_CoreCacheBank core;
    interface Ifc_CacheBankMem mem;
    method Vector#(5, Bool) perf_increments;
endinterface

typedef enum {HIT, MISS, REPLAY, WRITEBACKDONE} DataAccessType deriving(Bits, Eq, FShow);

// This cache design uses serial tag and data lookups, and follows a write-back
// design with write-through caches from the core side. It supports one
// inflight access per set and multiple inflight misses.
//
// All accesses first traverse the same 3-stage pipeline:
// 1. issueLookup starts tag+status array reads, and locks the set (multiple
//     accesses to the same set are serialized)
// 2. completeLookup reats tags and determines whether the access is a hit or a
//    miss, and to which way.
// 3. access handles data array accesses.
//
// Hits complete execution (and unlock their set) in access. Misses are
// started in access, but go through a few more rules as their fill and
// (potentially) writeback complete.
//
// Misses issue the writeback and fill requests to memory in parallel. If a
// writeback is needed, fills are held until the line has been sent for
// writeback. This requires the memory read and write channels to be
// independent: deadlock may result if read data stalls block write data
// progress. Writebacks are acknowledged, and the miss entry is released
// only when the write is acknowledged, to avoid multiple inflight misses to
// the same line.
(* synthesize *)
module mkL2CacheBank(L2CacheBank);
    // Performance Counters
    Wire#(Bool) perf_coreReq        <- mkDWire(False);
    Wire#(Bool) perf_serStall       <- mkDWire(False);
    Wire#(Bool) perf_coreReadMiss   <- mkDWire(False);
    Wire#(Bool) perf_coreWriteMiss  <- mkDWire(False);
    Wire#(Bool) perf_needsWriteback <- mkDWire(False);

    Vector#(5, Bool) perf_increments_ = cons(perf_coreReq, cons(perf_serStall,
                                             cons(perf_coreReadMiss, cons(perf_coreWriteMiss, cons(perf_needsWriteback, nil)))));

    Vector#(18, Wire#(Bool)) fifoCounters <- replicateM(mkDWire(False));

    // Ifc_CoreCacheBank queues
    // NOTE: To reduce read latency, there's no coreRespQ; core.readResp grabs
    // data off the data port
    ReqQueue coreReqQ <- mkReqQueue;

    // Ifc_CacheMem Fifos
    FIFOF#(BankLineReadReq) lineReadReqQ_ <- mkFIFOF1;
    FIFOF#(BankChunkReadResp) chunkReadRespQ <- mkGLFIFOF(False, True); // guarded enq, unguarded deq, input to access rule
    FIFOF#(BankLineWriteReq) lineWriteReqQ_ <- mkFIFOF1;
    FIFOF#(Chunk) chunkWriteReqQ_ <- mkPipelineFIFOF;
    FIFOF#(BankLineWriteResp) lineWriteRespQ_ <- mkFIFOF1;

    FIFOF#(BankLineReadReq) lineReadReqQ     <- mkDebugFIFOF(l2BankDebug, $format("(%m)-lineReadReqQ"), lineReadReqQ_, fifoCounters[0], fifoCounters[1]);
    FIFOF#(BankLineWriteReq) lineWriteReqQ   <- mkDebugFIFOF(l2BankDebug, $format("(%m)-lineWriteReqQ"), lineWriteReqQ_, fifoCounters[4], fifoCounters[5]);
    FIFOF#(Chunk) chunkWriteReqQ           <- mkDebugFIFOF(l2BankDebug, $format("(%m)-chunkWriteReqQ"), chunkWriteReqQ_, fifoCounters[6], fifoCounters[7]);
    FIFOF#(BankLineWriteResp) lineWriteRespQ <- mkDebugFIFOF(l2BankDebug, $format("(%m)-lineWriteRespQ"), lineWriteRespQ_, fifoCounters[8], fifoCounters[9]);

    let lineReadReqQ_send <- mkSendCommit(lineReadReqQ);
    let chunkReadRespQ_recv <- mkRecvCommit(chunkReadRespQ);
    let lineWriteReqQ_send <- mkSendCommit(lineWriteReqQ);
    let chunkWriteReqQ_send <- mkSendCommit(chunkWriteReqQ);
    let lineWriteRespQ_recv <- mkRecvCommit(lineWriteRespQ);

    // Main data structures

    // Tag array is dual-ported: narrow a for writes (tag updates), wide b for reads (all-way lookups)
    XRAM_DUAL_PORT#(TagArrayIdx, Maybe#(AddrTag), SetSel, Vector#(L2NumWays, Maybe#(AddrTag))) tagArray <-
        mkXRAM2(Invalid, WRITE_ONLY, READ_ONLY, "mixed");

    // Status array has the same geometry as the tag array, but just a few bits per set. Should be LUTRAM...
    XRAM_DUAL_PORT#(SetSel, SetStatus, SetSel, SetStatus) statusArray <-
        mkXRAM2(SetStatus{dirty: replicate(False), replInfo: initialLRUInfo}, WRITE_ONLY, READ_ONLY, "auto");

    // Data array is dual-ported; a is used for even cores and miss evictions/fills, b for odd cores
    XRAM_PIPED_DUAL_PORT_BE#(DataArrayIdx, Chunk, ChunkBEBits, DataPortLatency) dataArray <- mkXRAM2BE(0, NO_CHANGE, NO_CHANGE, "ultra");
    DataPort#(CacheLineAccTagEven) dataPortEven <- mkDataPort(dataArray.a);
    DataPort#(CacheLineAccTagOdd) dataPortOdd <- mkDataPort(dataArray.b);

    // Inter-stage queues: issueLookup->completeLookup and completeLookup->access
    // NOTE(dsm): Making this a FIFO2 isn't worth the LUTs, and a PipelineFIFO
    // adds to the critical path because deqs happen very late in the cycle
    FIFOF#(CoreReq) lookupQueue_ <- mkFIFOF1;
    FIFOF#(CoreReq) lookupQueue <- mkDebugFIFOF(l2BankDebug, $format("(%m)-lookupQueue"), lookupQueue_, fifoCounters[10], fifoCounters[11]);
    
    // Rather than a FIFO, we store access information in a RegFile, which
    // allows the access rule to handle hits, misses, and replays; even with
    // only 2 entries (one for hits, one for misses), a Vector#(2, Reg#(...))
    // is ~50 more LUTs.
    XRegFile#(Bit#(1), Tuple3#(CoreReq, WaySel, Bool)) accessInfo <- mkXRegFile(?);
    
    // access has four input queues: chunkReadRespQ (above, for fills), and the
    // three queues below. ALL THESE QUEUES MUST HAVE UNGUARDED DEQUEUES,
    // because access chooses among them (we used to have all events go through
    // a single queue, and that was a mess)
    FIFOF#(Bool) lookup2access <- mkGLFIFOF(False, True); // guarded enq, unguarded deq
    FIFOF#(void) fillDone2access <- mkUGFIFOF1;
    FIFOF#(void) writebackDone2access <- mkUGFIFOF1;

    // Miss-only state. This is simply regs because there's at most one miss
    // active at a time, but we could support multiple parallel misses (or
    // queue misses) by making these RegFiles too, or folding them in
    // accessInfo.
    // 1. Miss metadata, completeTagLookup W -> access R
    Reg#(AddrTag) oldTag <- mkRegU;
    Reg#(Bool) needsWriteback <- mkRegU;
    // 2. Miss progress, owned by access
    Reg#(Bool) writebackPending <- mkReg(False);
    Reg#(Bool) replayPending <- mkReg(False);
    // Fill state
    Reg#(TagArrayIdx) missLineIdx <- mkRegU;
    Reg#(ChunkSel) fillChunkIdx <- mkReg(0);

    // Debug / print config
`ifdef L2_BANK_DEBUG
    Reg#(Bool) printConfigPending <- mkReg(True);
    rule printConfig;
        if (printConfigPending) begin
            // Uses $display to print all paramters
            $display("l2cacheSizeBytes = %0d", valueOf(L2CacheSizeBytes));
            $display("l2numWays = %0d", valueOf(L2NumWays));
            $display("l2numBanks = %0d", valueOf(L2NumBanks));
            $display("wordBits = %0d", valueOf(WordBits));
            $display("addrBits = %0d", valueOf(AddrBits));
            $display("coreIdBits = %0d", valueOf(CoreIdBits));
            $display("clBits = %0d", valueOf(ClBits));
            $display("========================");
            $display("NumSets=", valueOf(NumSets));
            $display("SetSelBits=", valueOf(SetSelBits));
            $display("BankSelBits=", valueOf(BankSelBits));
            $display("ChunkSelBits=", valueOf(ChunkSelBits));
            $display("WaySelBits=", valueOf(TLog#(L2NumWays)));
            printConfigPending <= False;
        end
    endrule
`endif

    /* Stage 1: Issue lookup to tag and status arrays */
    rule issueTagLookup;
        let r <- coreReqQ.next;
        tagArray.b.put(False, r.req.wordAddr.set, ?);
        statusArray.b.put(False, r.req.wordAddr.set, ?);
        lookupQueue.enq(r);
        perf_coreReq <= True;
`ifdef L2_BANK_DEBUG
        $display($time, " %m req in: ", fshow(r));
`endif
    endrule
  
    // NOTE: Serialization stalls don't make much sense now that we're serving
    // OOO; this mostly captures transient cycles where we can't serve a
    // an already blocked req, or the req queue is deallocating
    /*
    rule profileInputBlocks if (perf_coreReq == False && coreReqQ.notEmpty && lookupQueue.notFull);
        $display($time, " %m blocked");
        perf_serStall <= True;
    endrule
    */

    /* Stage 2: Find whether we have a hit or miss, and to which way */

    // lookup -> access queues
    FIFOF#(void) missEntryUsed_ <- mkUGFIFOF1; // NOTE: unguarded! always check full/empty; used to block
                                               // completeTagLookup on miss if another miss is still active
    FIFOF#(void) missEntryUsed <- mkDebugFIFOF(l2BankDebug, $format("(%m)-missEntryUsed"), missEntryUsed_, fifoCounters[14], fifoCounters[15]);
    // Unguarded on enqueue, guarded on dequeue; the destination is
    // non-blocking and the source is the critical path, so we drop the enq guard
    FIFOF#(Tuple5#(SetSel, WaySel, SetStatus, Bool, Bool)) updateStatusQueue_ <- mkNonBlockingFIFOF;
    FIFOF#(Tuple5#(SetSel, WaySel, SetStatus, Bool, Bool)) updateStatusQueue <- mkDebugFIFOF(l2BankDebug, $format("(%m)-updateStatusQueue"), updateStatusQueue_, fifoCounters[16], fifoCounters[17]);

    // Aggressive implicit conditions are unnecessary here---the guard
    // includes the whole hit logic, which adds ~20 LUTs, adds to the critical
    // path, and achieves zero throughput gain
    (* conservative_implicit_conditions *)
    rule completeTagLookup if (lookup2access.notFull);
        let coreReq = lookupQueue.first;

        let tagSet = tagArray.b.read;
        let setStatus = statusArray.b.read;

        function Bool isHit(Maybe#(AddrTag) foundTag, AddrTag incomingTag) provisos(Eq#(AddrTag));
            if (foundTag matches tagged Valid .foundT) begin
                return foundT == incomingTag;
            end else begin
                return False;
            end
        endfunction

        let validAndHit = zipWith(isHit, tagSet, replicate(coreReq.req.wordAddr.tag));
        let hitWayM = findElem(True, validAndHit);

        let victimWay = getVictimWay(setStatus.replInfo);

        Bool hit = isValid(hitWayM);
        WaySel way = hit? pack(fromMaybe(?, hitWayM)) : victimWay;
        
        // Optimization: Compute isWrite here, and carry this bit throughout
        // the pipeline. This simplifies rule predicates, especially for
        // access, and saves logic in recomputing this.
        Bool isWrite = coreReq.req.wrMask != 0;
        
        // Cycle time optimization: The write-enable input of accessInfo is in
        // the critical path, so write unconditionally, using the hit entry
        // (which is non-blocking) as a scratch entry. If this is a miss and
        // missEntryUsed IS full, then we write to entry 0, which is unused
        // (because lookup2access is not full).
        // NOTE: The lookup2access.notFull guard is imprtant to keep this
        // correct; with aggressive contitions and no guard, this would
        // overwrite an ongoing hit
        Bit#(1) accessIdx = (hit || !missEntryUsed.notFull)? 0 : 1;
        accessInfo.write(accessIdx, tuple3(coreReq, way, isWrite));
        
        if (hit || missEntryUsed.notFull) begin
            lookup2access.enq(hit);
            lookupQueue.deq;
            if (!hit) begin
                missEntryUsed.enq(?);
                needsWriteback <= setStatus.dirty[way];
                oldTag <= fromMaybe(?, tagSet[way]);
            end
        end

        // NOTE: Sufficient to enq once; this may enq multiple times, but it's fine, those writes are idempotent
        updateStatusQueue.enq(tuple5(coreReq.req.wordAddr.set, way, setStatus, hit, isWrite));
    endrule

    rule updateStatus;
        match {.set, .way, .setStatus, .hit, .isWrite} = updateStatusQueue.first;
        updateStatusQueue.deq;
        if (hit) begin
            if (isWrite) setStatus.dirty[way] = True;
        end else begin
            setStatus.dirty[way] = isWrite;
        end
        setStatus.replInfo = updateLRUInfo(setStatus.replInfo, way);
        statusArray.a.put(True, set, setStatus);
    endrule

    /* Stage 3: Perform data array accesses for hits, or memory accesses for misses */

    // CONCURRENCY ANALYSIS - please keep up to date, errors here cause tricky bugs!!
    //
    // access unlocks the set for hits or misses that are done; however,
    // accesses to data arrays happen AFTER the unlock, creating potential
    // problems. In particular, reads can stall for a long time if the data
    // port's output queue is empty, creating the opportunity for future fills
    // or writes to step over them.
    //
    // Originally, data ports would block both reads or writes on a full output
    // queue. This meant that reads AND writes could be outstanding for a long
    // time. The patch solution was to conflict-check against both ports in the
    // access stage: a new access targeting the same line (set+way) as accesses
    // outstanding in either the even or odd data port was not issued. However,
    // this was expensive.
    //
    // I tried a mid-point solution before: conflict-checking on fills only.
    // But this still allowed writes to race, e.g., a write could stay stuck at
    // the head fo a port long enough for a different write to the same word
    // (and from a diferent task) to sweep in and cause a WAW hazard.
    //
    // The current solution is that:
    // 1. Writes DO NOT BLOCK in ports. If a port takes a write, it is
    //    performed the following cycle. This does away with all write
    //    reordering issues: writes are processed in order, period.
    // 2. Fills conflict-check with outstanding accesses; because fills always
    //    write to the even port, they check only with the odd port (if the even
    //    port has a conflict, the write can't happen anyway).
    //
    // This disallows read-fill races, where a read stays pending on the even
    // port, its own line is evicted by a later request to the same set, and
    // the fill overwrites it.
    //
    // FYI, Alex Krastev suggested changing the ports to take in a read request
    // only if there's enough buffer space that the read wouldn't stall. That
    // should also work, but would take a bit more coding.
    rule access if (lookup2access.notEmpty || fillDone2access.notEmpty || writebackDone2access.notEmpty || chunkReadRespQ.notEmpty);
        Bit#(1) accessIdx = (chunkReadRespQ.notEmpty || fillDone2access.notEmpty || writebackDone2access.notEmpty || !lookup2access.first)? 1 : 0;
        match {.coreReq, .way, .isWrite} = accessInfo.read1(accessIdx);

        if (chunkReadRespQ.notEmpty) begin
            let resp = chunkReadRespQ.first;
            
            // NOTE: Uses a missLineIdx and not accessInfo, because this is in the critical path otherwise
            let tAddr = TagArrayIdx{set: missLineIdx.set, ws: missLineIdx.ws};
            dynamicAssert(missLineIdx.set == coreReq.req.wordAddr.set && missLineIdx.ws == way, "missLineIdx and accessInfo are inconsistent!!");

            if (!dataPortOdd.conflict(tAddr)) begin
                chunkReadRespQ.deq;

                // NOTE: Uses accessInfo to reduce muxing on port inputs
                let dataArrayIdx = DataArrayIdx{set: coreReq.req.wordAddr.set, ws: way, cs: fillChunkIdx};
                dataPortEven.putReq(True, ~0, dataArrayIdx, resp.chunk, ?);
               
                fillChunkIdx <= fillChunkIdx + 1;
                if (fillChunkIdx == ~0) begin
        `ifdef L2_BANK_DEBUG
                    $display($time, " %m miss fill done");
        `endif
                    fillDone2access.enq(?);
                end
            end
        end else begin
            DataAccessType accessType = fillDone2access.notEmpty? REPLAY :
                                            writebackDone2access.notEmpty? WRITEBACKDONE :
                                                lookup2access.first? HIT : MISS;
`ifdef L2_BANK_DEBUG
            $display($time, " %m access: ", fshow(accessType), " ", fshow(coreReq));
`endif 
            if (accessType == HIT || accessType == REPLAY) begin
                ChunkBE chunkWe = zeroExtend(coreReq.req.wrMask) << {coreReq.req.wordAddr.ws, (Bit#(ByteSelBits))'(0)};
                DataArrayIdx dataArrayIdx = DataArrayIdx{set: coreReq.req.wordAddr.set, cs: coreReq.req.wordAddr.cs, ws: way};
                if (isWrite) dynamicAssert(coreReq.req.wrMask != 0, "write bit set, but wrMask=0");
                Vector#(TDiv#(ChunkBits, WordBits), Word) chunkData = replicate(coreReq.req.data);
                if (isEven(coreReq.coreId))
                    dataPortEven.putReq(isWrite, chunkWe, dataArrayIdx, unpack(pack(chunkData)), tagged CoreCLRdEven tuple2(toEven(coreReq.coreId), getCoreRespId(coreReq.req)));
                else
                    dataPortOdd.putReq(isWrite, chunkWe, dataArrayIdx, unpack(pack(chunkData)), tagged CoreCLRdOdd tuple2(toOdd(coreReq.coreId), getCoreRespId(coreReq.req)));

                if (accessType == REPLAY) begin
                    dynamicAssert(replayPending, "spurious REPLAY access");
                    replayPending <= False;
                    fillDone2access.deq;
                end else begin
                    lookup2access.deq;
                end
            end else if (accessType == MISS) begin
                perf_coreReadMiss   <= !isWrite;
                perf_coreWriteMiss  <= isWrite;
                perf_needsWriteback <= needsWriteback;

                MissIdx missIdx = 0;
                let lineAddr = BankLineAddr{tag: coreReq.req.wordAddr.tag, set: coreReq.req.wordAddr.set};
                lineReadReqQ.enq(BankLineReadReq{bankLineAddr: lineAddr, reqId: missIdx});

                let lineIdx = TagArrayIdx{set: coreReq.req.wordAddr.set, ws: way};
                tagArray.a.put(True, lineIdx, Valid(coreReq.req.wordAddr.tag));

                missLineIdx <= lineIdx;

                if (needsWriteback) begin
                    let victimTag = oldTag;
                    let victimLineAddr = BankLineAddr{tag: victimTag, set: lineAddr.set};
                    lineWriteReqQ.enq(BankLineWriteReq{bankLineAddr: victimLineAddr, reqId: missIdx});
                    DataArrayIdx dataArrayIdx = DataArrayIdx{set: coreReq.req.wordAddr.set, cs: coreReq.req.wordAddr.cs, ws: way};
                    dataPortEven.putReq(False, 0, dataArrayIdx, ?, tagged EvictCLRd);
                end
                replayPending <= True;
                writebackPending <= needsWriteback;
                lookup2access.deq;
            end else begin
                dynamicAssert(writebackPending, "spurious WRITEBACKDONE access");
                writebackPending <= False;
                writebackDone2access.deq;
            end

            // End-of-access actions
            if (accessType == HIT || (accessType == REPLAY && !writebackPending) || (accessType == WRITEBACKDONE && !replayPending)) begin
                coreReqQ.unlock(coreReq);
                if (accessType != HIT) begin
                    dynamicAssert(missEntryUsed.notEmpty, "miss entry used!");
                    missEntryUsed.deq;
                end
            end
        end
    endrule

    /* Miss rules: These fire in response to writeback events */

    rule writebackChunk if (dataPortEven.first matches {tagged EvictCLRd, .chunk});
        dataPortEven.deq;
        chunkWriteReqQ.enq(chunk);
    endrule

    rule writebackDone;
        let missIdx = lineWriteRespQ.first.reqId;
        lineWriteRespQ.deq;
        writebackDone2access.enq(?);
    endrule

    Wire#(Bool) readRespAckedEven <- mkDWire(False);
    rule deqReadChunkEven if (dataPortEven.first matches {tagged CoreCLRdEven {.coreId, .coreRespId}, .chunk});
        if (readRespAckedEven) dataPortEven.deq;
    endrule

    Wire#(Bool) readRespAckedOdd <- mkDWire(False);
    rule deqReadChunkOdd if (dataPortOdd.first matches {tagged CoreCLRdOdd {.coreId, .coreRespId}, .chunk});
        if (readRespAckedOdd) dataPortOdd.deq;
    endrule

    interface Ifc_CoreCacheBank core;
        interface req = coreReqQ.reqIn;
       
        // Grab responses directly off dataPort to reduce read latency
        interface readRespEven = interface SendCommit#(CoreReadRespEven);
            method CoreReadRespEven dataout if (dataPortEven.first matches {tagged CoreCLRdEven {.coreId, .coreRespId}, .chunk}) = 
                CoreReadRespEven{dest: coreId, data: tuple2(coreRespId, chunk)};
            // Note that ack may be called even if dataout is not valid (this is valid-and-ready)
            method Action ack = readRespAckedEven._write(True);
        endinterface;

        interface readRespOdd = interface SendCommit#(CoreReadRespOdd);
            method CoreReadRespOdd dataout if (dataPortOdd.first matches {tagged CoreCLRdOdd {.coreId, .coreRespId}, .chunk}) = 
                CoreReadRespOdd{dest: coreId, data: tuple2(coreRespId, chunk)};
            // Note that ack may be called even if dataout is not valid (this is valid-and-ready)
            method Action ack = readRespAckedOdd._write(True);
        endinterface;
    endinterface: core

    interface Ifc_CacheBankMem mem;
        interface lineReadReq = lineReadReqQ_send;
        interface chunkReadResp = chunkReadRespQ_recv;
        interface lineWriteReq = lineWriteReqQ_send;
        interface chunkWriteReq = chunkWriteReqQ_send;
        interface lineWriteResp = lineWriteRespQ_recv;
    endinterface

    method Vector#(5, Bool) perf_increments = perf_increments_;
endmodule: mkL2CacheBank
