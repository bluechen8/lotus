/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Vector::*;
import XRegFile::*;
import XRAM::*;
import DReg::*;
import Assert::*;

import FIFO::*;
import SpecialFIFOs::*;

interface PrioQueue#(type t);
    // These are guarded
    method t min;
    method Action popMin;
    
    // You can call these any time
    (* always_ready *)
    method Action push(t x);
    
    (* always_ready *)
    method Bool canPopMin;
endinterface

/* Helper class: A small queue used to buffer min values, decouple pushes, and
 * preserve full order with pushed values
 */
interface OrderedQueue#(type t);
    // These are guarded
    method t min;
    method Action popMin;
    method Action pushToMinPipe(t x);

    // NOTE: push path is non-blocking; popPushed **must** be called every time
    // it's enabled
    (* always_ready *)
    method Action push(t x);
    
    (* always_enabled *)
    method ActionValue#(t) popPushed;

    (* always_ready *)
    method Bool canPopMin;
endinterface

// The min pipe holds values that are similar to Maybe types, with a key
// difference: when the value is not valid, it acts as a lower bound in
// comparisons. This is key to preserve the invariant in the ordered queue that
// pushed values don't overtake lower values in the backing structure. You can
// think of bubbles as leaving a "trail" in the min pipeline that prevents them
// from being substituted with higher pushed values.
typedef struct {
    Bool valid;
    t valueOrLowerBound;
} MinPipeEntry#(type t) deriving (Bits, Eq, FShow);

function Bool lessThan(Maybe#(t) x, MinPipeEntry#(t) y) provisos (Ord#(t));
    Bool lt = fromMaybe(?, x) < y.valueOrLowerBound;
    return isValid(x) && lt;
endfunction

function Bool equal(Maybe#(t) x, MinPipeEntry#(t) y) provisos (Eq#(t));
    Bool eq = fromMaybe(?, x) == y.valueOrLowerBound;
    return isValid(x) && y.valid && eq;
endfunction

module mkOrderedQueue#(Integer stages, Bool useLowerBound)(OrderedQueue#(t)) provisos (Bits#(t, dataBits), Ord#(t), Eq#(t), FShow#(t));
    Reg#(MinPipeEntry#(t)) minPipe[stages];
    for (Integer i = 0; i < stages; i = i + 1) begin
        minPipe[i] <- mkReg(MinPipeEntry{valid: False, valueOrLowerBound: unpack(-1)});
    end

    // This acts as a 1-element non-blocking pipe
    Reg#(Maybe#(t)) pushedElem <- mkReg(Invalid);

    Wire#(Bool) doPopMin <- mkDWire(False);
    Wire#(Maybe#(t)) doPushToMinPipe <- mkDWire(Invalid);
    Wire#(Maybe#(t)) doPush <- mkDWire(Invalid);
    Wire#(Bool) doPopPushed <- mkDWire(False);

    rule tick;
        // 1. Construct based on whether we move forward; make it a collapsing pipe
        MinPipeEntry#(t) newPipe[stages];
        Bool advance = doPopMin;
        for (Integer i = 0; i < stages-1; i = i + 1) begin
            advance = advance || !minPipe[i].valid;
            newPipe[i] = advance? minPipe[i+1] : minPipe[i];
        end
        newPipe[stages-1] = isValid(doPushToMinPipe)? MinPipeEntry{valid: True, valueOrLowerBound: fromMaybe(?, doPushToMinPipe)} :
            advance? MinPipeEntry{valid: False, valueOrLowerBound: minPipe[stages-1].valueOrLowerBound} : minPipe[stages-1];
      
        // 2. Compare pushed elem with minPipe elems
        Bool lt[stages+1];
        lt[0] = False; // needed to not special-case minPipe[0]
        Bool anyMatch = False;
        for (Integer i = 0; i < stages; i = i + 1) begin
            lt[i+1] = lessThan(doPush, newPipe[i]);
            if (!useLowerBound && isValid(doPush) && !newPipe[i].valid) lt[i+1] = True;
            anyMatch = anyMatch || equal(doPush, newPipe[i]);
        end

        // 3. Insert elem at the right place
        MinPipeEntry#(t) newElem = MinPipeEntry{valid: True, valueOrLowerBound: fromMaybe(?, doPush)};
        MinPipeEntry#(t) newMinPipe[stages];
        for (Integer i = 0; i < stages; i = i + 1) begin
            Bool insertHere = lt[i+1] && !lt[i] && !anyMatch;
            Bool insertedBefore = lt[i+1] && lt[i] && !anyMatch;
            newMinPipe[i] = insertHere? newElem : (i != 0 && insertedBefore)? newPipe[i-1] : newPipe[i];
        end

        for (Integer i = 0; i < stages; i = i + 1) begin
            minPipe[i] <= newMinPipe[i];
        end

        // 4. Set pushedElem
        if (anyMatch) pushedElem <= Invalid;
        else pushedElem <= !lt[stages]? (!anyMatch? doPush : Invalid) : (newPipe[stages-1].valid? Valid(newPipe[stages-1].valueOrLowerBound) : Invalid);

        //if (isValid(pushedElem) || isValid(doPush) || isValid(doPushToMinPipe) || doPopMin) begin
        //    $write($time,  " PrioQueueDebug (%m) mp: ");
        //    for (Integer i = 0; i < stages; i = i + 1) $write(minPipe[i].valid? "V" : "L", fshow(minPipe[i].valueOrLowerBound), " | newMinPipe: ");
        //    for (Integer i = 0; i < stages; i = i + 1) $write(newMinPipe[i].valid? "V" : "L", fshow(newMinPipe[i].valueOrLowerBound), " ");
        //    $display(" | pe: ", fshow(pushedElem), " | dp: ", fshow(doPush), " | dpm: ", fshow(doPushToMinPipe), " | pop: ", fshow(doPopMin));
        //end
    endrule

    rule checkPopPushed if (pushedElem matches tagged Valid .x);
        if (!doPopPushed) begin
            $display($time, " ERROR: outstanding pushElem ", fshow(x));
            for (Integer i = 0; i < stages; i = i + 1) $write(minPipe[i].valid? "V" : "L", fshow(minPipe[i].valueOrLowerBound), " ");
            $display();
        end
        dynamicAssert(doPopPushed, "ERROR: pushedElem in %m was not consumed; a value was dropped!");
    endrule

    method t min if (minPipe[0].valid) = minPipe[0].valueOrLowerBound;
    method Action popMin if (minPipe[0].valid) = doPopMin._write(True);
    method Bool canPopMin = minPipe[0].valid;
    method Action pushToMinPipe(t x) if (!minPipe[stages-1].valid || doPopMin) = doPushToMinPipe._write(Valid(x));

    method Action push(t x) = doPush._write(Valid(x));

    // NOTE: Don't be fooled by this interface, this is NON-BLOCKING. It is an
    // error not to call this when it's callable (and the whole purpose of
    // doPopPushed is to check this).
    method ActionValue#(t) popPushed if (pushedElem matches tagged Valid .x);
        doPopPushed <= True;
        return x;
    endmethod

endmodule

// This implementation uses a smaller PrioQueue to hold its indices
typedef enum { Fetch, Process } PullState deriving (Bits, Eq, FShow);

module mkHierarchicalBitmapPrioQueue#(PrioQueue#(u) idxQueue, Integer orderedQueueSize)(PrioQueue#(t)) provisos (
        Bits#(t, dataBits), Ord#(t), Eq#(t), FShow#(t),
        Bits#(u, uBits), Ord#(u), Eq#(u), FShow#(u),
        Add#(lBits, uBits, dataBits),
        Add#(1, lBits, a__), // lBits should be at least 1, i.e., uBits < dataBits
        Alias#(Vector#(TExp#(lBits), Bool), bWord)
    );

    XRAM_DUAL_PORT#(t, Bool, u, bWord) bitmap <- mkXRAM2(False, WRITE_ONLY, NO_CHANGE, "auto");
   
    Reg#(PullState) pullState <- mkReg(Fetch);
    // pullState can be moved from 3 places; pulling the transition logic to a
    // late rule avoids spurious conflicts, and it's better than using an EHR
    PulseWire movePullStateToFetch <- mkPulseWireOR;
    PulseWire movePullStateToProcess <- mkPulseWire;
    rule movePullState;
        if (movePullStateToFetch) pullState <= Fetch;
        else if (movePullStateToProcess) pullState <= Process;
    endrule
    OrderedQueue#(t) outQueue <- mkOrderedQueue(orderedQueueSize, True);
    
    Wire#(Maybe#(u)) pushedBlockIdx <- mkDWire(Invalid);

    rule consumePush;
        let x <- outQueue.popPushed;
        bitmap.a.put(True, x, True);
        // TODO: OK for our use case, but may be worth having a function to
        // derive u from t; this is the only case the bit pattern is exposed
        u idxVal = unpack(truncate(pack(x) >> valueOf(lBits)));
        idxQueue.push(idxVal);
        pushedBlockIdx <= Valid(idxVal);
        //$display($time, " PrioQueueDebug (%m) H", fromInteger(valueOf(SizeOf#(t))), ": Pushed ", fshow(x));
    endrule

    // This is logically done every time consumePush fires, but idxQueue.min is
    // guarded, so it can't be in the same rule: when the idxQueue is empty,
    // this would block consumePush and drop pushed elements.
    // NOTE: Shadows fetchBlock, which is intended, ignore the warning
    rule invBlockOnPush if (pushedBlockIdx matches tagged Valid .idxVal &&& idxVal <= idxQueue.min);
        // Invalidate current iteration
        movePullStateToFetch.send();
        //$display($time, " PrioQueueDebug (%m) H", fromInteger(valueOf(SizeOf#(t))), ": Pushed elem idx ", fshow(idxVal), " invalidates current traversal, curIdx = ", fshow(idxQueue.min));
    endrule

    // Block -> outQueue.pushToMinPipe pipeline
    Reg#(bWord) block <- mkRegU;
    Reg#(Bool) blockReadDone <- mkReg(False);
    FIFO#(Maybe#(Bit#(lBits))) nextBlockElem <- mkPipelineFIFO;

    rule fetchBlock if (pullState == Fetch);
        bitmap.b.put(False, idxQueue.min, ?);
        movePullStateToProcess.send();
        blockReadDone <= False;
        nextBlockElem.clear;
    endrule

    rule readBlock if (pullState == Process && !blockReadDone);
        block <= bitmap.b.read;
        blockReadDone <= True;
    endrule

    rule peelBlock if (pullState == Process && blockReadDone);
        let pos = findElem(True, block);
        if (pos matches tagged Valid .li) begin
            Bit#(lBits) l = pack(li);
            block[l] <= False;
            // NOTE(dsm): If this is ever a bottleneck, you can reduce the time
            // per block by a cycle easily by enqueuing the termination flag
            // here; there's plenty of time to compare curBlock == 0
            nextBlockElem.enq(Valid(l));
        end else begin
            nextBlockElem.enq(Invalid);
        end
    endrule

    // NOTE: consumeBlockElem does not run on consumePush even though they have
    // no structural conflicts, to avoid data races. This is imprecise, the
    // precise way would be to preempt on invBlockOnPush. But that has too long
    // a critical path.
    (* preempts = "consumePush, consumeBlockElem" *)
    (* conservative_implicit_conditions *)
    rule consumeBlockElem if (pullState == Process);
        let e = nextBlockElem.first;
        nextBlockElem.deq;
        if (e matches tagged Valid .l) begin
            t elem = unpack({pack(idxQueue.min), l});
            outQueue.pushToMinPipe(elem);
            // NOTE: Cheaper than using port A, even if no concurrency w/ consumePush
            bitmap.b.put(True, idxQueue.min, block);
            //bitmap.a.put(True, elem, False);
            //$display($time, " PrioQueueDebug (%m) H", fromInteger(valueOf(SizeOf#(t))), ": Pulling ", fshow(elem), " to outQueue, curIdx = ", fshow(idxQueue.min), "block = %b", pack(block));
        end else begin
            // NOTE: Needs to happen early in cycle
            idxQueue.popMin;
            movePullStateToFetch.send();
            //$display("H: PrioQueueDebug (%m) Block consumed, moving to next idx");
        end
    endrule

    method t min = outQueue.min;
    method Action popMin = outQueue.popMin;
    method Bool canPopMin = outQueue.canPopMin;
    method Action push(t x) = outQueue.push(x);
endmodule

// This implementation uses a vector of values as a register; it is meant for
// small (2-3 bit) queues. You should use this as the base of a hierarchical
// priority queue whenever you use a custom comparison function that does not
// match normal Bit#(n) order (e.g., cycled task idxs), because the flatmap
// implementation just uses a rotating Bit#(n) curIdx.
/*
module mkSmallPrioQueue(PrioQueue#(t)) provisos (Bits#(t, dataBits), Ord#(t), Eq#(t), FShow#(t));
    // NOTE: We use this queue sized to hold all possible elements, and without
    // lowerBound behavior. So this queue cannot overflow; if it does due to a
    // bug, an assertion within it will fail.
    OrderedQueue#(t) queue <- mkOrderedQueue(valueOf(TExp#(dataBits)), False);

    method t min = queue.min;
    method Action popMin = queue.popMin;
    method Bool canPopMin = queue.canPopMin;
    method Action push(t x) = queue.push(x);
endmodule
*/

// More optimized implementation---the one above shows up in the critical path
module mkSmallPrioQueue(PrioQueue#(t)) provisos (Bits#(t, dataBits), Ord#(t), Eq#(t), FShow#(t));
    Reg#(Vector#(TExp#(dataBits), Bool)) present <- mkReg(replicate(False));
    Reg#(Maybe#(t)) curMin <- mkReg(Invalid);

    Wire#(Bool) doPopMin <- mkDWire(False);
    Wire#(Maybe#(t)) doPush <- mkDWire(Invalid);

    rule tick;
        let nextPresent = present;
        if (doPopMin) nextPresent[pack(fromMaybe(?, curMin))] = False;
        if (doPush matches tagged Valid .x) nextPresent[pack(x)] = True;
            
        Maybe#(t) nextMin = Invalid;
        for (Integer i = 0; i < valueOf(TExp#(dataBits)); i = i + 1) begin
            t it = unpack(fromInteger(i));
            if (nextPresent[i] && (!isValid(nextMin) || it < fromMaybe(?, nextMin))) nextMin = Valid(it);
        end
        curMin <= nextMin;
        present <= nextPresent;
        
        //if (doPopMin || isValid(doPush)) $display($time, " PrioQueueDebug (%m) Q: present = ", fshow(present), " curMin = ", fshow(curMin),
        //    " doPopMin = ", fshow(doPopMin), " doPush = ", fshow(doPush), " nextPresent = ", fshow(nextPresent));
    endrule

    method t min if (curMin matches tagged Valid .x) = x;
    method Action popMin if (isValid(curMin)) = doPopMin._write(True);
    method Bool canPopMin = isValid(curMin);
    method Action push (t x) = doPush._write(Valid(x));
endmodule

module mkTestHPQ(PrioQueue#(Bit#(13)));
    PrioQueue#(Bit#(2)) bbq <- mkSmallPrioQueue;
    PrioQueue#(Bit#(9)) bq <- mkHierarchicalBitmapPrioQueue(bbq, 2);
    PrioQueue#(Bit#(13)) q <- mkHierarchicalBitmapPrioQueue(bq, 2);
    return q;
endmodule

