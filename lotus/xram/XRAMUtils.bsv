/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Assert::*;
import FIFOLevel::*;
import NonBlockingPipe::*;
import ShiftFIFO::*;
import SkidFIFO::*;
import Vector::*;
import XRAM::*;

// Port where reads are tagged with some metadata; useful to build pipelines
// where data consumers need some side infromation for each read
interface TaggedPortQueue#(type addr_t, type data_t, type tag_t, numeric type depth);
    method Action putRead(addr_t addr, tag_t tag);
    method Action putWrite(addr_t addr, data_t data);
    method Action putWriteRead(addr_t addr, data_t data, tag_t tag);
    method Action deq;
    method Tuple2#(tag_t, data_t) first;
endinterface

interface TaggedPortBEQueue#(type addr_t, type data_t, type we_t, type tag_t, numeric type depth);
    method Action putRead(addr_t addr, tag_t tag);
    method Action putWrite(addr_t addr, we_t we, data_t data);
    method Action putWriteRead(addr_t addr, we_t we, data_t data, tag_t tag);
    method Action deq;
    method Tuple2#(tag_t, data_t) first;
endinterface

module mkTaggedPortBEQueue#(XRAM_PIPED_PORT_BE#(addr_t, data_t, weSz, portLatency) p, XRAMMode mode)(TaggedPortBEQueue#(addr_t, data_t, we_t, tag_t, depth))
    provisos(Bits#(addr_t, addrSz), Bits#(data_t, dataSz), Bits#(we_t, weSz), Bits#(tag_t, tagSz), Mul#(weSz, __chunkSz, dataSz), Add#(a__, 1, portLatency), Add#(b__, 1, depth), Add#(c__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth)))); // FIXME: Is this babysitting induced by ShiftFIFO proviso crud?? If so, clean up ShiftFIFO provisos

    Reg#(Maybe#(tag_t)) readTagPipe <- mkDNonBlockingPipe(valueOf(portLatency), Invalid, Invalid);
    FIFOCountIfc#(Tuple2#(tag_t, data_t), depth) outBaseQueue <- mkGShiftFIFOCountInit(True, False, nil);
    SkidFIFO#(Tuple2#(tag_t, data_t)) outQueue <- mkSkidFIFO(outBaseQueue, valueOf(portLatency), 1 /* TODO: Make configurable? */);
 
    rule feedOutQueue if (readTagPipe matches tagged Valid .tag);
        outQueue.enq(tuple2(tag, p.read));
    endrule

    method Action putRead(addr_t addr, tag_t tag) if (outQueue.hasSkidSlot);
        p.put(0, addr, ?);
        readTagPipe <= Valid(tag);
    endmethod

    method Action putWrite(addr_t addr, we_t we, data_t data);
        // NOTE: If you want to support this behavior, just do nothing on we == 0
        dynamicAssert(pack(we) != 0, "putWrite cannot be called with a zero mask");
        p.put(pack(we), addr, data);
    endmethod

    method Action putWriteRead(addr_t addr, we_t we, data_t data, tag_t tag) if (outQueue.hasSkidSlot);
        dynamicAssert(pack(we) != 0, "putWriteRead cannot be called with a zero mask");
        dynamicAssert((mode == READ_FIRST || mode == WRITE_FIRST), "putWriteRead can only happen on XRAM modes where writes induce a read");
        p.put(pack(we), addr, data);
        readTagPipe <= Valid(tag);
    endmethod

    method Action deq = outQueue.deq;
    method Tuple2#(tag_t, data_t) first = outQueue.first;
endmodule

module mkTaggedPortQueue#(XRAM_PIPED_PORT#(addr_t, data_t, portLatency) p, XRAMMode mode)(TaggedPortQueue#(addr_t, data_t, tag_t, depth))
    provisos(Bits#(addr_t, addrSz), Bits#(data_t, dataSz), Bits#(tag_t, tagSz), Add#(a__, 1, portLatency), Add#(b__, 1, depth), Add#(c__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));
    let pbe <- mkPortToPortBE(p);
    TaggedPortBEQueue#(addr_t, data_t, Bit#(1), tag_t, depth) pqbe <- mkTaggedPortBEQueue(pbe, mode);

    // Single use, so not worth writing a PortBEQueue to PortQueue transformers; if more uses arise, split out.
    method Action putRead(addr_t addr, tag_t tag) = pqbe.putRead(addr, tag);
    method Action putWrite(addr_t addr, data_t data) = pqbe.putWrite(addr, 1, data);
    method Action putWriteRead(addr_t addr, data_t data, tag_t tag) = pqbe.putWriteRead(addr, 1, data, tag);

    method Action deq = pqbe.deq;
    method Tuple2#(tag_t, data_t) first = pqbe.first;
endmodule
