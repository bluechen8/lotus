/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CacheTypes;
import MainMemory;
bsvimport XRAM;
bsvimport XRAMms;  // defs for use within Minispec
bsvimport XRegFile;
bsvimport ShiftFIFOms;

// Instruction cache, specialized to a hilt to minimize delay of data output.

typedef enum { Idle, Fill, UpdateTag } IMissState;

typedef struct {
    Word pc;
    Word inst;
} ICacheData;

typedef Bit#(32 - logWordsPerLine - 2) LineAddr;

typedef struct {
    LineAddr first;
    LineAddr last;
} TaskLineRange;

function Bool inRangeFL(LineAddr l, LineAddr first, LineAddr last) = l >= first && l <= last;
function Bool inRangeR(LineAddr l, TaskLineRange r) = inRangeFL(l, r.first, r.last);
function Bool inRange(LineAddr l, Maybe#(TaskLineRange) r) = isValid(r) && inRangeR(l, fromMaybe(?, r));

function LineAddr lineAddr(WordAddr wa) = truncate(wa >> logWordsPerLine);

typedef enum { CUR, NEXT, IDLE } TaskPrefetcherState;

module ICache;
    // Configuration options (add some LUTs, but reduce stalls on misses)
    // Serve miss after chunk is filled in, without waiting for the whole line
    // to be written. This reduces serialization latency (and could reduce it
    // further in combination with a critical-word-first optimization)
    Bool serveMissEarly = True;
    // Prefetch the line following the current one, if it's missing. This
    // improves performance with sequential code, but may add misses with
    // branchy code that has a large footprint.
    Bool nextLinePrefetcher = False;

    // Prefetch current task or one ahead, using range information from the
    // task descriptor; can be used in combination with next-line prefetching,
    // in which case next-line prefetching is done only when the pc is out of
    // the range of the current task (e.g., in a function call)
    Bool taskDrivenPrefetcher = True;

    // Cache geometry and helpers
    Integer addressBits = 32;
    Integer wordOffsetBits = 2;
    Integer lineIndexBits = 6;
    Integer wordIndexBits = lineIndexBits + logWordsPerLine;
    Integer tagBits = addressBits - wordIndexBits - wordOffsetBits;
    
    function Bit#(tagBits) tag(WordAddr addr) = truncate(addr >> wordIndexBits);
    function Bit#(lineIndexBits) lineIndex(WordAddr addr) = truncate(addr >> logWordsPerLine);
    function Bit#(wordIndexBits) wordIndex(WordAddr addr) = truncate(addr);

    function Bit#(tagBits) lTag(LineAddr lAddr) = truncate(lAddr >> lineIndexBits);
    function Bit#(lineIndexBits) lLineIndex(LineAddr lAddr) = truncate(lAddr);

    // Cache arrays. Tag is per line and in LUTRAM, data is in BRAM
    // We use a dual-port RAM with a 32-bit read port, and a 64-bit write port for fills
    XRAM2#(Bit#(wordIndexBits), Word, Bit#(wordIndexBits-1), Bit#(64)) dataArray(0, READ_ONLY, WRITE_ONLY, "block");
    // NOTE: Initial tag value **matters**, since validArray is initialized
    // to 1 because that simplifies miss logic (valid == 0 implies in-flight
    // miss for the line). But noone puts code in the last page of the
    // system...
    XRegFile#(Bit#(lineIndexBits), Bit#(tagBits)) tagArray(~0);
    XRegFile#(Bit#(lineIndexBits), Bool) validArray(True);
    // Since LUTRAM is cheap, now that we support multiple misses, we use a
    // separate fillChunk array to track the miss status of each line and simplify
    // partial matches. This tracks the number of fills to the line.
    XRegFile#(Bit#(lineIndexBits), Bit#(logWordsPerLine-1)) fillChunkArray(0);


    // The request/fetch and miss logic are independent
    // Request side issues reads continuously from port a
    RegU#(WordAddr) pc;

    input Maybe#(WordAddr) redirectFetch default = Invalid; // for mispredictions and exception clears 
    input Bool popRead default = False;

    function Bool matchingFetchTag = tagArray.read1(lineIndex(pc)) == tag(pc);
    function Bool hit;
        let valid = validArray.read1(lineIndex(pc));
        let numFills = fillChunkArray.read1(lineIndex(pc));
        // To serve a miss early, we must wait two cycles after the data is written:
        // cycle N:   write chunk X
        // cycle N+1: issue read from chunk X
        // cycle N+2: filled value is at output of data array
        // To achieve this, fill status updates are delayed by one cycle, so
        // checking against numFills here is safe.
        let fetchChunk = pc[logWordsPerLine-1:1];
        Bool dataFilled = valid || (serveMissEarly && (fetchChunk < numFills));
        return matchingFetchTag && dataFilled;
    endfunction

    rule fetch;
        WordAddr reqPc = isValid(redirectFetch)? fromMaybe(?, redirectFetch) : (popRead? pc + 1 : pc);
        dataArray.a.put(False, wordIndex(reqPc), ?);
        pc <= reqPc;
    endrule

    method Maybe#(ICacheData) data = hit? Valid(ICacheData{pc: {pc, 2'b0}, inst: dataArray.a.read}) : Invalid;

    // Miss side reacts to non-hits, triggering memory requests and filling the cache
    Reg#(Bool) mayRequestMiss(False);
    
    // Prefetch state
    Reg#(Bit#(4)) cyclesUntilPrefetch(9);
    Reg#(Bool) taskPrefetchAllowed(False); // cycle time optimization
    
    Reg#(Maybe#(TaskLineRange)) curTaskRange(Invalid);
    Reg#(Maybe#(TaskLineRange)) nextTaskRange(Invalid);

    input Maybe#(TaskPrefetchHint) nextTaskPrefetchHint;

    Reg#(LineAddr) taskPrefetcherNextLine(0);
    Reg#(TaskPrefetcherState) taskPrefetcherState(IDLE);

    // We delay status updates on fills by one cycle, because the correct data
    // appears on data array 2 cycles after the fill (see hit timing above)
    Reg#(Maybe#(Tuple3#(Bit#(2), Bit#(lineIndexBits), Bit#(logWordsPerLine-1)))) pendingFillChunkUpdate(Invalid);
    Reg#(Bool) pendingValidUpdate(False);

    // Degenerate MSHRs: Because we keep tag in tagArray and fill count in
    // statusArray, all we need is a way to translate respId -> lineIdx
    Vector#(3, Bit#(2)) flInit = cons(0, cons(1, cons(2, nil)));
    ShiftFIFOInit#(Bit#(2), 3) respIdFreelist(flInit);
    // NOTE(dsm): These track Freelist contents, and are used for debugging ONLY.
    Reg#(Vector#(3, Bool)) validMissLineIdxs(replicate(False));
    XRegFile#(Bit#(2), Bit#(lineIndexBits)) missLineIdxs(0);

    // Fetch/prefetch issue logic (in function to avoid a dependency between rule and memReq method)
    function Tuple6#(Maybe#(MemReq), Bit#(2), Bool, Bool, Bool, Bool) missReqAndId;
        Bool shouldDemandFetch = !matchingFetchTag;

        // First, let's determine prefetch mode
        Bool pcWithinTask = inRange(lineAddr(pc), curTaskRange);
        Bool prefetchNextLine = nextLinePrefetcher && (!taskDrivenPrefetcher || !pcWithinTask);
        Bool prefetchTask = taskDrivenPrefetcher; //&& taskPrefetchAllowed;

        let pLineAddr = prefetchNextLine? (lineAddr(pc) + 1) : taskPrefetcherNextLine;
        Bool matchingPrefetchTag = tagArray.read2(lLineIndex(pLineAddr)) == lTag(pLineAddr);
        Bool conflictWithPc = lineIndex(pc) == lLineIndex(pLineAddr);
        Bool shouldPrefetch = (prefetchNextLine || (prefetchTask && taskPrefetchAllowed)) && !matchingPrefetchTag && !conflictWithPc;

        WordAddr missAddr = shouldDemandFetch? {tag(pc), lineIndex(pc), 0} : {pLineAddr, 0};
        Bit#(2) respId = fromMaybe(?, respIdFreelist.first);
        // Cycle-time optimization: Equivalent to validArray.read2(lineIndex(missAddr)),
        // but this makes this read late and smack in the critical path
        Bool noConflict = shouldDemandFetch? validArray.read2(lineIndex(pc)) : validArray.read3(lLineIndex(pLineAddr));
        Bool requestMiss = mayRequestMiss && (shouldDemandFetch || shouldPrefetch) && noConflict;
        return tuple6(requestMiss? Valid(MemReq{wordAddr: missAddr, wrMask: 0, data: icacheRespIdToData(respId)}) : Invalid, 
                        respId, shouldDemandFetch, prefetchNextLine, prefetchTask, matchingPrefetchTag);
    endfunction

    // Memory interface
    // NOTE(dsm): memReqReg is a cycle-time optimization; it may become
    // unnecessary if missReq's cycle time is optimized (some of the prefetch
    // address computation may be done in the previous cycle)
    Reg#(Maybe#(MemReq)) memReqReg(Invalid);
    method Maybe#(MemReq) memReq = memReqReg;
    input Bool memReqReady default = False;
    input Maybe#(Tuple2#(ICacheRespId, Bit#(64))) rdResp default = Invalid;

    input Bool inException default = False;
    
    rule miss;
        Bool nextPendingValidUpdate = False;
        // Fills have maximum priority
        if (isValid(rdResp)) begin
            let resp = fromMaybe(?, rdResp);
            let respId = tpl_1(resp);
            let respData = tpl_2(resp);
            if (!validMissLineIdxs[respId]) begin
                $display($time, " %m ERROR: Fill for Invalid respId=%d", respId);
                dynamicAssert(validMissLineIdxs[respId], "received fill to Invalid respId");
            end
            let missLineIdx = missLineIdxs.read1(respId);
            
            let fillCounter = fillChunkArray.read2(missLineIdx);
            // Bypass matching pending update (we save and match on respId bc matching on addr would be more logic)
            // TODO: This can be simplified further with separate valid-bit and data management.
            let bypassFillCounter = isValid(pendingFillChunkUpdate) && tpl_1(fromMaybe(?, pendingFillChunkUpdate)) == respId;
            if (bypassFillCounter) fillCounter = tpl_3(fromMaybe(?, pendingFillChunkUpdate));

            dataArray.b.put(True, {missLineIdx, truncate(fillCounter)}, respData);
            pendingFillChunkUpdate <= Valid(tuple3(respId, missLineIdx, fillCounter + 1));

            // Debugging
            //let missTag = tagArray.read3(missLineIdx);
            //Addr missAddr = {missTag, missLineIdx, 0};
            //$display($time, " %m FILL to %x: fillCounter=%d bypassed=%d respId=%d", missAddr, fillCounter, bypassFillCounter, respId);

            // Free miss entry on last fill
            if (fillCounter == ~0) begin
                //$display($time, " %m FILL to respId=%d done", respId);
                nextPendingValidUpdate = True;
            end
        end else begin
            pendingFillChunkUpdate <= Invalid;
        end
        pendingValidUpdate <= nextPendingValidUpdate;

        if (isValid(pendingFillChunkUpdate)) begin
            let upd = fromMaybe(?, pendingFillChunkUpdate);
            fillChunkArray.write(tpl_2(upd), tpl_3(upd));
        end

        // Status updates due to fills conflict with issuing miss and prefetch reqs
        let missReq = tpl_1(missReqAndId);
        let missRespId = tpl_2(missReqAndId);
        let shouldDemandFetch = tpl_3(missReqAndId);
        let prefetchNextLine = tpl_4(missReqAndId);
        let prefetchTask = tpl_5(missReqAndId);
        let matchingPrefetchTag = tpl_6(missReqAndId);

        // NOTE(dsm): Was || memReady to make it a pipeline FIFO, but this
        // hurts the critical path, and there's no way this helps; we don't
        // issue consecutive misses...
        Bool memReqReg_notFull = !isValid(memReqReg);
       
        // This write is in the critical path if done below, so do it eagerly
        if (isValid(respIdFreelist.first))
            missLineIdxs.write(fromMaybe(?, respIdFreelist.first), lineIndex(fromMaybe(?, missReq).wordAddr));

        if (isValid(missReq) && memReqReg_notFull) begin
            let ma = fromMaybe(?, missReq).wordAddr;
            tagArray.write(lineIndex(ma), tag(ma));
            validArray.write(lineIndex(ma), False);
            dynamicAssert(!validMissLineIdxs[missRespId], "allocated a still-valid respId");
            validMissLineIdxs[missRespId] <= True;
            dynamicAssert(respIdFreelist.first == Valid(missRespId), "freelist went out of sync");
            respIdFreelist.deq = True;
        end else if (pendingValidUpdate) begin
            dynamicAssert(!isValid(missReq), "Can't have a memory request with a pending status update");
            let upd = fromMaybe(?, pendingFillChunkUpdate);
            validArray.write(tpl_2(upd), True);
            validMissLineIdxs[tpl_1(upd)] <= False;
            dynamicAssert(respIdFreelist.notFull, "freelist went out of sync");
            respIdFreelist.enq = Valid(tpl_1(upd));
        end

        if (memReqReg_notFull) memReqReg <= missReq;
        else if (memReqReady) memReqReg <= Invalid;

        // Update task-driven prefetcher state
        TaskPrefetcherState nextTaskPrefetcherState = taskPrefetcherState;
        if (taskDrivenPrefetcher) begin
            if (isValid(nextTaskRange) && !isValid(nextTaskPrefetchHint)) begin
                curTaskRange <= nextTaskRange;
                nextTaskRange <= Invalid;
                // If we were at CUR, we were running behind, so need CUR; is
                // we were at NEXT, we move to CUR because the range has moved;
                // if we were IDLE, we've already prefetched this range, so stay
                if (taskPrefetcherState != IDLE) begin
                    nextTaskPrefetcherState = CUR;
                    //$display($time, " %m TDP moving NEXT -> CUR");
                end
                taskPrefetcherNextLine <= fromMaybe(?, nextTaskRange).first;
                //if (nextTaskPrefetcherState == CUR) $display($time, " %m moving prefetch line to next->new cur range start ", fshow(taskPrefetcherNextLine), " -> ", fshow(fromMaybe(?, nextTaskRange).first), " state ", fshow(taskPrefetcherState));
            end else if (!isValid(nextTaskRange) && isValid(nextTaskPrefetchHint)) begin
                let tph = fromMaybe(?, nextTaskPrefetchHint);
                let first = lineAddr(tph.wordAddr);
                let last = first + zeroExtend(tph.size);
                nextTaskRange <= Valid(TaskLineRange{first: first, last: last});
                if (taskPrefetcherState != CUR) begin
                    nextTaskPrefetcherState = NEXT;
                    taskPrefetcherNextLine <= first;
                end
                //$display($time, " %m TDP received new NEXT");
            end else if (taskPrefetcherState == CUR || taskPrefetcherState == NEXT) begin
                let range = taskPrefetcherState == NEXT? nextTaskRange : curTaskRange;
                dynamicAssert(isValid(range), "task-driven prefetcher: target range is invalid");
                Bool advance = !prefetchNextLine && prefetchTask && matchingPrefetchTag;
                Bool atEnd = taskPrefetcherNextLine == fromMaybe(?, range).last;
                if (advance && !atEnd) begin
                    //$display($time, " %m advancing prefetch line ", fshow(taskPrefetcherNextLine), " range ", fshow(range), " state ", fshow(taskPrefetcherState));
                    taskPrefetcherNextLine <= taskPrefetcherNextLine + 1;
                end else if (advance && atEnd) begin
                    taskPrefetcherNextLine <= fromMaybe(?, nextTaskRange).first;
                    if (taskPrefetcherState == CUR) begin
                        nextTaskPrefetcherState = isValid(nextTaskRange)? NEXT : IDLE;
                    end else begin 
                        nextTaskPrefetcherState = IDLE;
                    end
                    //if (nextTaskPrefetcherState == NEXT) $display($time, " %m moving prefetch line to next range ", fshow(taskPrefetcherNextLine), " -> ", fshow(fromMaybe(?, nextTaskRange).first), " state ", fshow(taskPrefetcherState));
                end

                //if (advance) begin
                //    $display($time, " %m TDP ", fshow(taskPrefetcherState), " [%x, %x], advancing 0x%x", 
                //        {fromMaybe(?, range).first, 6'b0},
                //        {fromMaybe(?, range).last, 6'b0},
                //        {taskPrefetcherNextLine, 6'b0});
                //end
            end
            taskPrefetcherState <= nextTaskPrefetcherState;
        end

        // Moderate prefetch rate
        if (isValid(missReq) && memReqReg_notFull) begin
            cyclesUntilPrefetch <= 9;
            taskPrefetchAllowed <= False;
        end else if (cyclesUntilPrefetch > 0) begin
            cyclesUntilPrefetch <= cyclesUntilPrefetch - 1;
        end else begin
            taskPrefetchAllowed <= (respIdFreelist.count > 1) && (nextTaskPrefetcherState != IDLE);
        end

        //if (isValid(missReq) && memReqReady) $display($time, " %m %s miss to 0x%x",
        //    shouldDemandFetch? "DEMAND" : prefetchNextLine? "NL PREFETCH" : "TASK PREFETCH", 
        //    {fromMaybe(?, missReq).wordAddr, 2'b0}
        //);

        mayRequestMiss <= !inException && !(isValid(missReq) && memReqReg_notFull) && respIdFreelist.notEmpty && !nextPendingValidUpdate;
    endrule
endmodule
