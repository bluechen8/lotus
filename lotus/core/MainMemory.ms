/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CoreTypes;
import CacheTypes;
import SRAM;
bsvimport Assert;

module WordMem;
    Integer memBytes = 1 << 14;  // 16 KB
    Integer memWords = memBytes / 4;
    Integer addrBits = log2(memWords);
    SRAMBELoad#(addrBits, Word, 4) ram("mem.vmh");

    input Maybe#(MemReq) req default = Invalid;
    method Maybe#(Word) data = ram.data;

    // This matches the cache interfaces, lets us use it as a stand-in in tests
    method Bool reqEnabled = True;

    rule tick;
        if (isValid(req)) begin
            let r = fromMaybe(?, req);
            ram.req = Valid(SRAMBEReq#(addrBits, Word, 4){
                addr: truncate(r.wordAddr), wrMask: r.wrMask, data: r.data
            });
        end
    endrule
endmodule

// To emulate DRAM technology, MainMemory uses a word-based memory and adds some delay
module MainMemory;
    WordMem wordMem;
    Integer latency = wordsPerLine + 16;

    Reg#(Bit#(log2(latency) + 1)) cyclesLeft(0);
    //RegU#(MemOp) curOp;
    RegU#(WordAddr) curAddr;
    Reg#(Bool) validOut(False);
    Reg#(Bit#(log2(wordsPerLine-1))) fillCounter(0);
    Vector#(wordsPerLine, RegU#(Word)) dataRegs;

    method Bool reqEnabled = (cyclesLeft == 0);
    input Maybe#(MemReq) req default = Invalid;

    method Maybe#(Bit#(64)) data;
        return validOut? Valid({dataRegs[{fillCounter, 1'b1}], dataRegs[{fillCounter, 1'b0}]}) : Invalid;
    endmethod

    rule tick;
        // dsm: Check that wordsPerLine is a reasonable value
        if (wordsPerLine != 4 && wordsPerLine != 8 && wordsPerLine != 16) begin
            $display("ERROR: MainMemory requires wordsPerLine to be 4, 8, or 16");
            $finish;
        end

        dynamicAssert(!((cyclesLeft != 0) && isValid(req)), "MainMemory received request while not ready!\n\n");
        if (cyclesLeft != 0) cyclesLeft <= cyclesLeft - 1;
        if (cyclesLeft == 0 && isValid(req)) begin
            let r = fromMaybe(?, req);
            if (r.wrMask == 0 /* load */) begin
                WordAddr lineStartAddr = r.wordAddr & ~(wordsPerLine-1);
                cyclesLeft <= latency;
                curAddr <= lineStartAddr;
                // curOp <= r.op;
                wordMem.req = Valid(MemReq{wordAddr: lineStartAddr, wrMask: 0, data: ?});
            end else begin
                // Perform store writebacks directly
                wordMem.req = req;
            end
        end else if (cyclesLeft > latency - wordsPerLine) begin
            Bit#(logWordsPerLine) idx = truncate(curAddr);
            curAddr <= curAddr + 1;
            dataRegs[idx] <= fromMaybe(?, wordMem.data);
            wordMem.req = Valid(MemReq{wordAddr: curAddr + 1, wrMask: 0, data: ?});
        end

        // Response FSM
        if (cyclesLeft == 1) validOut <= True;
        else if (validOut) begin
            if (fillCounter == ~0) validOut <= False;
            fillCounter <= fillCounter + 1;
        end
    endrule
endmodule

// Single-cycle word memory, used as ideal memory by the tests
module /*msc_pragma:nosynth*/ SingleCycleMemory;
    WordMem wordMem;

    Reg#(Bit#(64)) cycles(0);

    input Maybe#(MemReq) req default = Invalid;
    method Maybe#(Word) data = wordMem.data;

    // For detecting timeouts
    rule doCycle;
        cycles <= cycles + 1;
        if (cycles > 10000000) begin
            $display("FAILED: Your processor timed out");
            $finish;
        end
    endrule

    rule tick;
        if (isValid(req)) begin
            let r = fromMaybe(?, req);
            let addr = {r.wordAddr, 2'b0};

            // MMIO and program termination
            if (r.wrMask != 0) begin
                if (addr == 'h4000_0000) begin
                    // Write character to stdout
                    $write("%c", r.data[7:0]);
                end else if (addr == 'h4000_0004) begin
                    // Write integer to stdout
                    $write("%0d", r.data);
                end else if (addr == 'h4000_1000) begin
                    // Exit simulation
                    $display("Total Clock Cycles = %d\n", cycles);
                    if (r.data == 0) begin
                        $display("PASSED");
                    end else begin
                        $display("FAILED %0d", r.data);
                    end
                    $finish;
                end
            end
        end
        wordMem.req = req;
    endrule
endmodule
