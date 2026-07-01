/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Cache torture test. Works by issuing random requests to (1) the cache under
// test backed by a memory, and (2) an ideal single-cycle memory, and checking
// that responses from the cache and the ideal, reference memory are the same.
//
// NOTE: This test is good at exposing subtle bugs in caches, but it may be
// hard to isolate these bugs, because the point at which the test fails may be
// much higher than the bug. Once you've surfaced a bug, if you're having a
// hard time pinpointing it, you can try testing smaller caches (which may fail
// on a much shorter trace), filtering the trace by set, or just writing a
// custom micro-test to reproduce the problem.

import L2CacheBank::*;
import L2Cache::*;

import Assert::*;
import FIFO::*;
import LFSR::*;
import Vector::*;
import XRAM::*;
import XRAMUtils::*;
import XRegFile::*;

/* Auxiliary memories */

//typedef struct { LineAddr lineAddr; ChunkSel chunkIdx; } BankChunkAddr deriving (Bits, Eq, FShow);
typedef struct { LineAddr lineAddr; ChunkSel chunkIdx; } ChunkAddr deriving (Bits, Eq, FShow);

// This memory is used in combination with the cache. It's written to respect
// AXI3 (e.g., there's delay between chunkWrite/W and writeResp/B), with the
// additional restriction that it allows no interleaving on the lineWrite/AW
// and chunkWrite/W channels. This is like AXI4, and I think for simplicity we
// should stick to it.
//
// This implementation does not maximally test AXI though (e.g., it does not
// skew channels or reorder responses on purpose). This may be worth adding,
// especially if we end up going with concurrent misses.
module mkTestMem#(Ifc_CacheMem cache)(Empty);
    XRegFile#(ChunkAddr, Chunk) mem <- mkXRegFile(0);

    Reg#(ChunkSel) readChunkIdx <- mkReg(0);
    Reg#(ChunkSel) writeChunkIdx <- mkReg(0);

    FIFO#(LineReadReq) readReqQ <- mkFIFO;
    FIFO#(LineWriteReq) writeReqQ <- mkFIFO;
    FIFO#(LineWriteResp) writeRespQ <- mkFIFO;

    rule readReq;
        let r <- cache.lineReadReq;
        readReqQ.enq(r);
    endrule

    rule readResp;
        let chunkAddr = ChunkAddr{lineAddr: readReqQ.first.lineAddr, chunkIdx: readChunkIdx};
        cache.chunkReadResp(ChunkReadResp{chunk: mem.read1(chunkAddr), reqId: readReqQ.first.reqId});
        
        if (readChunkIdx == ~0) readReqQ.deq;
        readChunkIdx <= readChunkIdx + 1;
    endrule

    rule lineWriteReq;
        let r <- cache.lineWriteReq;
        writeReqQ.enq(r);
    endrule

    rule chunkWriteReq;
        let r <- cache.chunkWriteReq;
        let chunkAddr = ChunkAddr{lineAddr: writeReqQ.first.lineAddr, chunkIdx: writeChunkIdx};
        dynamicAssert(writeReqQ.first.reqId == r.reqId, "write channels are out of sync");
        mem.write(chunkAddr, r.chunk);

        if (writeChunkIdx == ~0) begin
            writeReqQ.deq;
            writeRespQ.enq(LineWriteResp{reqId: writeReqQ.first.reqId});
        end
        writeChunkIdx <= writeChunkIdx + 1;
    endrule

    rule lineWriteResp;
        cache.lineWriteResp(writeRespQ.first);
        writeRespQ.deq;
    endrule
endmodule

// This is the reference memory. It preserves full ordering of requests, and
// has a 1-cycle latency + a large output queue so that the test can issue many
// read requests in parallel to the cache and memory, without this memory
// limiting concurrency.
module mkReferenceMem(Ifc_CoreCacheBank);
    XRAM_DUAL_PORT_BE#(ChunkAddr, Chunk, ChunkBEBits) mem <- mkXRAM2BE(0, NO_CHANGE, NO_CHANGE, "auto");
    ImpPortBEQueue#(ChunkAddr, Chunk, ChunkBE, CoreId) readPort <-
        mkImpPortBEQueue(mem.b, NO_CHANGE, 0, 128); // i.e., up to 16 chunks ahead.

    Reg#(ChunkSel) readChunkIdx <- mkReg(0);
    FIFO#(CoreReq) reqQ <- mkFIFO;

    rule processReq;
        let r = reqQ.first;
        if (r.req.wrMask == 0) begin
            let chunkAddr = ChunkAddr{lineAddr: LineAddr{tag: r.req.wordAddr.tag, set: r.req.wordAddr.set, bank: r.req.wordAddr.bank}, chunkIdx: readChunkIdx};
            readPort.putRead(chunkAddr, r.coreId);
            if (readChunkIdx == ~0) reqQ.deq;
            readChunkIdx <= readChunkIdx + 1;
        end else begin
            let chunkAddr = ChunkAddr{lineAddr: LineAddr{tag: r.req.wordAddr.tag, set: r.req.wordAddr.set, bank: r.req.wordAddr.bank}, chunkIdx: r.req.wordAddr.cs};
            ChunkBE chunkWrMask = zeroExtend(r.req.wrMask) << {r.req.wordAddr.ws, (Bit#(ByteSelBits))'(0)};
            Vector#(TDiv#(ChunkBits, WordBits), Word) chunkData = replicate(r.req.data);
            mem.a.put(chunkWrMask, chunkAddr, unpack(pack(chunkData)));
            reqQ.deq;
        end
    endrule

    method Action req(CoreReq r) = reqQ.enq(r);

    method ActionValue#(CoreReadResp) readResp;
        match {.coreId, .chunk} = readPort.first;
        readPort.deq;
        return CoreReadResp{chunk: chunk, coreId: coreId};
    endmethod
endmodule


module mkTestL2CacheBank(Empty);
    L2CacheBank cache <- mkL2CacheBank;
    
    // FIXME: Kludgy
    Vector#(NumBanks, Ifc_CacheBankMem) mems_;
    for (Integer i = 0; i < valueOf(NumBanks); i = i + 1) mems_[i] = cache.mem;
    let muxedMem <- mkMemBankMux(mems_);

    let testMem <- mkTestMem(muxedMem);

    Ifc_CoreCacheBank refMem <- mkReferenceMem;

    Reg#(Bit#(64)) cycle <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule

    // FIXME: Find a larger polynomial and initialize the LFSR better
    Bit#(65) feed = 0;
    feed[64] = 1;
    feed[46] = 1;
    feed[0] = 1;
    LFSR#(Bit#(65)) randomMem <- mkFeedLFSR(feed);

    Reg#(Bit#(64)) readReqsIssued <- mkReg(0);
    Reg#(Bit#(64)) writeReqsIssued <- mkReg(0);
    Reg#(Bit#(64)) readRespsReceived <- mkReg(0);

    // NOTE: For now, issue at most one read at a time. The concurrency model
    // is that multiple cores can issue one read each, and the cache can reply
    // to them out of order, which breaks order with the reference mem but is
    // not a bug. We may want to have one rule per core and split responses per
    // core for comparison.
    rule issueReq if (fromInteger(valueOf(NumChunksPerCacheLine))*readReqsIssued == readRespsReceived);
        let newrand = randomMem.value;
        randomMem.next;
        CoreReq req = unpack(zeroExtend(newrand));

        req.req.wordAddr = unpack(zeroExtend(pack(req.req.wordAddr)[15:0]) % truncate(readReqsIssued + 1));
        req.req.wordAddr.bank = 0; // until we have multibank, restrict reqs to the same bank
        //req.req.data = zeroExtend(cycle + 1); // useful to find some bugs, since data shows cycle of write
        req.req.wrMask = truncate(cycle);

        if (req.req.wrMask == 0) readReqsIssued <= readReqsIssued + 1;
        else writeReqsIssued <= writeReqsIssued + 1;

        cache.core.req(req);
        refMem.req(req);
        //$display("[%d] Issuing ", cycle, fshow(req));
    endrule

    rule checkResp;
        let actual <- cache.core.readResp;
        let expected <- refMem.readResp;

        readRespsReceived <= readRespsReceived + 1;

        //$display("[%d] Received ", cycle, fshow(actual), fshow(readRespsReceived));
        if (actual != expected) begin
            $display("[%d] ERROR: Received resp ", cycle, fshow(actual));
            $display("[%d] ERROR: Expected resp ", cycle, fshow(expected));
            $finish;
        end
    endrule

    // If the cache is sending responses when it shouldn't, this rule makes the
    // test fail rather than deadlock
    (* descending_urgency = "checkResp, drainSpuriousResp" *)
    rule drainSpuriousResp;
        let actual <- cache.core.readResp;
        $display("[%d] ERROR: Received spurious read! (refMem didn't give anything) ", cycle, fshow(actual));
        $finish;
    endrule

    rule endSim;
        if (readRespsReceived == 1 << 20) begin
            $display("[%d] PASSED after %d read requests, %d write requests, %d read chunks",
                cycle, readReqsIssued, writeReqsIssued, readRespsReceived);
            $finish;
        end
    endrule
endmodule


module mkTestL2Cache(Empty);
    L2Cache cache <- mkL2Cache;
    let testMem <- mkTestMem(cache.mem);

    Ifc_CoreCacheBank refMem <- mkReferenceMem;

    Reg#(Bit#(64)) cycle <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule

    // FIXME: Find a larger polynomial and initialize the LFSR better
    Bit#(65) feed = 0;
    feed[64] = 1;
    feed[46] = 1;
    feed[0] = 1;
    LFSR#(Bit#(65)) randomMem <- mkFeedLFSR(feed);

    Reg#(Bit#(64)) readReqsIssued <- mkReg(0);
    Reg#(Bit#(64)) writeReqsIssued <- mkReg(0);
    Reg#(Bit#(64)) readRespsReceived <- mkReg(0);

    // NOTE: For now, issue at most one read at a time. The concurrency model
    // is that multiple cores can issue one read each, and the cache can reply
    // to them out of order, which breaks order with the reference mem but is
    // not a bug. We may want to have one rule per core and split responses per
    // core for comparison.
    rule issueReq if (fromInteger(valueOf(NumChunksPerCacheLine))*readReqsIssued == readRespsReceived && cycle % 100 == 0);
        let newrand = randomMem.value;
        randomMem.next;
        CoreReq req = unpack(zeroExtend(newrand));

        req.req.wordAddr = unpack(zeroExtend(pack(req.req.wordAddr)[15:0]) % truncate(readReqsIssued + 1));
        //req.req.data = zeroExtend(cycle + 1); // useful to find some bugs, since data shows cycle of write
        req.req.wrMask = truncate(cycle);

        if (req.req.wrMask == 0) readReqsIssued <= readReqsIssued + 1;
        else writeReqsIssued <= writeReqsIssued + 1;

        cache.cores[req.coreId].req(req.req);
        refMem.req(req);
        $display("[%d] Issuing ", cycle, fshow(req));
    endrule

    for (Integer i = 0; i < valueOf(NumCoresPerTile); i = i + 1) begin
        rule checkResp;
            let actual <- cache.cores[i].readResp;
            let expected <- refMem.readResp;

            readRespsReceived <= readRespsReceived + 1;

            $display("[%d] Received ", cycle, fshow(actual), fshow(readRespsReceived));
            if (actual != expected.chunk) begin
                $display("[%d:%d] ERROR: Received resp ", cycle, i, fshow(actual));
                $display("[%d:%d] ERROR: Expected resp ", cycle, i, fshow(expected));
                $finish;
            end
        endrule

        // If the cache is sending responses when it shouldn't, this rule makes the
        // test fail rather than deadlock
        /*(* descending_urgency = "checkResp, drainSpuriousResp" *)
        rule drainSpuriousResp;
            let actual <- cache.core.readResp;
            $display("[%d:%d] ERROR: Received spurious read! (refMem didn't give anything) ", cycle, i, fshow(actual));
            $finish;
        endrule*/
    end

    rule endSim;
        if (readRespsReceived == 1 << 20) begin
            $display("[%d] PASSED after %d read requests, %d write requests, %d read chunks",
                cycle, readReqsIssued, writeReqsIssued, readRespsReceived);
            $finish;
        end
    endrule
endmodule
