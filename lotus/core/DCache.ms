/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CacheTypes;
import CoreTypes;
bsvimport XRAM;
bsvimport XRAMms;  // defs for use within Minispec
bsvimport XRegFile;
bsvimport Assert;

typedef struct {
    MemOp op;
    Bit#(3) funct3;
    Word addr;
    Word data;
} DCacheReq;

// Data cache
typedef enum { Ready, Lookup, WriteThrough, Fill } DReqState;

// Shared memory needs an extra set of tracking bits, which must be
// flash-cleared. The naive way of doing this is with 64 registers, one per
// line, which we can flash-clear. But the setting and selection logic takes 86
// LUTs, and adds F7 and F8 muxes which complicate placement.
//
// Instead, we can just use LUTRAM: have a regfile with one entry per bit, and
// have each entry store a phase. Each flash-clear simply advances the phase;
// setting an element is done by writing the current phase; and an element is
// set if its entry matches the current phase. To make this non-blocking, we
// just make phases **big**, larger than the number of entries, so we can
// reset only one entry per flash-clear and never wrap around.
//
// This takes 21 LUTs to track 64 entries, and is fully non-blocking, you can
// flash-clear every cycle. I also experimented with blockign variants that
// clear a few entries per flash-clear (e.g., using 3-bitr phases), but they're
// not worth it: the extra logic to clear multiple entries adds more LUTs than
// those saved by  having longer phases, e.g., 3-bit phases take 33 LUTs, plus
// you'd need control logic to stop flash-clears...
module ValidSet#(Integer idBits);
    XRegFile#(Bit#(idBits), Bit#(idBits+1)) phaseFile(0);
    Reg#(Bit#(idBits+1)) curPhase(1);

    input Bool flashClear default = False;
    input Maybe#(Bit#(idBits)) readAndSet default = Invalid;

    // NOTE: In general, you could use an unsafe wire to get this in the same
    // rule that sets readAndSet; but since the user module needs this
    // registered anyway, using a reg is simpler
    Reg#(Bool) readVal(False);

    rule tick;
        dynamicAssert(!(flashClear && isValid(readAndSet)), "can't clear and set on the same cycle!");
        if (flashClear) begin
            curPhase <= curPhase + 1;
            phaseFile.write(truncate(curPhase), curPhase);
        end else if (isValid(readAndSet)) begin
            let id = fromMaybe(?, readAndSet);
            phaseFile.write(id, curPhase);
            readVal <= phaseFile.read1(id) == curPhase;
        end
    endrule

    method Bool curRead = readVal;
endmodule


module DCache;
    // Cache geometry and helpers
    Integer addressBits = 32;
    Integer wordOffsetBits = 2;
    Integer lineIndexBits = 6;
    Integer wordIndexBits = lineIndexBits + logWordsPerLine;
    Integer tagBits = addressBits - wordIndexBits - wordOffsetBits;

    function Bit#(tagBits) tag(WordAddr addr) = truncate(addr >> wordIndexBits);
    function Bit#(lineIndexBits) lineIndex(WordAddr addr) = truncate(addr >> logWordsPerLine);
    function Bit#(wordIndexBits) wordIndex(WordAddr addr) = truncate(addr);

    function Bool isSMAddr(WordAddr addr) = addr[addressBits-wordOffsetBits-1:addressBits-wordOffsetBits-3] != 3'b111;

    // Cache arrays. Tag is per line and in LUTRAM, data is per word to use few BRAMs
    // We use a dual-port RAM with 32-bit ports so that we can do fills at 64 bits/cycle, using both ports
    XRAM2BE#(Bit#(wordIndexBits), Word, 4) dataArray(0, WRITE_FIRST, WRITE_FIRST, "block");
    XRegFile#(Bit#(lineIndexBits), Maybe#(Bit#(tagBits))) tagArray(Invalid);
    
    ValidSet#(lineIndexBits) smValid;

    // Registers for holding the current state of the cache and how far along
    // it is in processing a request.
    Reg#(DReqState) state(Ready);
    Reg#(Maybe#(Bit#(tagBits))) curTag(Invalid);
    RegU#(MemReq) curReq; // holds current request
    RegU#(Bit#(2)) curWordOffset;
    RegU#(Bit#(3)) curFunct3;
    Reg#(Bool) servingMiss(False); // if True, we're serving a word that was just filled.
    Reg#(Bit#(logWordsPerLine-1)) fillCounter(0);

    // Memory interface
    method Maybe#(MemReq) memReq = ((state == Lookup && !hit) || (state == WriteThrough))? Valid(curReq) : Invalid;
    input Bool memReqReady default = False;
    input Maybe#(Bit#(64)) rdResp default = Invalid;

    function Bool hit = (isValid(curTag) && (!isSMAddr(curReq.wordAddr) || smValid.curRead))
                            && (fromMaybe(?, curTag) == tag(curReq.wordAddr));

    // Flushing Shared Memory on Deq
    input Bool flushSMAddr default = False;

    input Maybe#(DCacheReq) req default = Invalid;
    method Bool reqEnabled = ((state == Ready) || (state == Lookup && hit)); // WriteThrough is not pipelined.

    rule tick;
        Bool nextServingMiss = False;
        smValid.flashClear = flushSMAddr;
        
        if ((state == Ready || (state == Lookup && hit)) && isValid(req)) begin
            let r = fromMaybe(?, req);
            
            Bit#(4) wrMask = r.op == Ld? 0 : case (r.funct3[1:0])
                fnSW[1:0]: 4'b1111;
                fnSH[1:0]: 4'b0011 << {r.addr[1], 1'b0};
                fnSB[1:0]: 4'b0001 << r.addr[1:0];
                default: ?;
            endcase;

            // The data to be written is the full word with fnSW, the replicated lower half-word with SH, and the replicated lower
            // byte with SB. The write mask will control which of the replicas is written.
            // Expand with a barrel-shifter-like structure. This is 16 LUTs; the standard case(r.funct3) statement is 25 LUTs
            Bool isNotSW = r.funct3[1:0] != fnSW[1:0];
            Bool isSB = r.funct3[1:0] == fnSB[1:0];
            Word w0 = {isNotSW? r.data[15:0] : r.data[31:16], r.data[15:0]};
            Word wrData = {isSB? w0[23:16] : w0[31:24], w0[23:16], isSB? w0[7:0] : w0[15:8], w0[7:0]};

            WordAddr wordAddr = truncate(r.addr >> 2);

            let w = wordIndex(wordAddr);

            dataArray.a.put(wrMask, w, wrData);
            
            let l = lineIndex(wordAddr);
            curTag <= tagArray.read1(l);
            smValid.readAndSet = Valid(l);
            Word dcacheRespIdData = {?, pack(CoreRespId{destCache: DCACHE, icacheRespId: ?})};
            curReq <= MemReq{wrMask: wrMask, wordAddr: wordAddr, data: r.op == St? wrData : dcacheRespIdData};
            curWordOffset <= truncate(r.addr);
            curFunct3 <= r.funct3;
            state <= r.op == St? WriteThrough : Lookup;
        end else if (state == Lookup) begin
            if (hit) begin
                state <= Ready;
            end else if (memReqReady) begin
                state <= Fill;
            end
        end else if (state == Fill && isValid(rdResp)) begin
            // We fill 2 words at a time, and mux words so that the requested
            // word is always writtn through port A. Since the memory is
            // WRITE_FIRST, this lets us serve the word in the next cycle
            let curAddr = curReq.wordAddr;
            Bit#(1) wordIndexLsb = truncate(wordIndex(curAddr));
            dataArray.a.put(4'b1111, {lineIndex(curAddr), fillCounter, wordIndexLsb},
                            (wordIndexLsb == 1)? fromMaybe(?, rdResp)[63:32] : fromMaybe(?, rdResp)[31:0]);
            dataArray.b.put(4'b1111, {lineIndex(curAddr), fillCounter, ~wordIndexLsb},
                            (wordIndexLsb == 0)? fromMaybe(?, rdResp)[63:32] : fromMaybe(?, rdResp)[31:0]);
            fillCounter <= fillCounter + 1;
            // Since this is WRITE_FIRST, the next cycle we'll have the value at the output
            if (fillCounter == truncate(wordIndex(curAddr) >> 1)) nextServingMiss = True;
            if (fillCounter == ~0) begin
                // Last word received
                tagArray.write(lineIndex(curAddr), Valid(tag(curAddr)));
                state <= Ready;
                curTag <= Invalid;
            end
        end else if (state == WriteThrough) begin
            // Note how we speculatively overwrite the data on a store. So on a
            // miss, invalidate the line. Things we can do with a WT cache :)
            if (!hit) begin
                tagArray.write(lineIndex(curReq.wordAddr), Invalid);
                // NOTE: We're invalidating the line here, there's no need to change smValidArr
                //           as it'll miss on next access anyways
            end
            if (memReqReady) state <= Ready;
        end

        servingMiss <= nextServingMiss;
    endrule

    method Bool isLastFill = (fillCounter == ~0);

    method Maybe#(Word) data;
        if ((state == Lookup && hit) || servingMiss) begin
            // We leverage funct3 encoding and expand with a barrel-shifter
            // like structure that both zero/sign-extends and aligns the data
            // NOTE: This takes 35 LUTs; separate shift + masking takes 50
            Bit#(1) signedMask = ~curFunct3[2];
            Bool isNotLW = curFunct3[1:0] != fnLW[1:0];
            Bool isLByte = curFunct3[1:0] == fnLB[1:0]; // LB or LBU
            Bool s1 = curWordOffset[1] == 1;
            Bool s2 = curWordOffset[0] == 1;
            
            let d0 = dataArray.a.read;
            let d1 = {isNotLW? signExtend((s1? d0[31] : d0[15]) & signedMask) : d0[31:16], s1? d0[31:16] : d0[15:0]};
            let d2 = {isLByte? signExtend((s2? d1[15] : d1[7]) & signedMask) : d1[31:8], s2? d1[15:8] : d1[7:0]};
            return Valid(d2);
        end else begin
            return Invalid;
        end
    endmethod
endmodule
