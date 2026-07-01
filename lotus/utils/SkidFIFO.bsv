/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import FIFOLevel::*;
import NonBlockingPipe::*;
import FIFO::*;
import FIFOF::*;

// A skid FIFO generalizes a skid buffer: it reserves some capacity as "skid
// slots", landing space that allows a fixed pipeline on the enqueue side to
// write its outputs.
//
// The key difference with a normal FIFO interface is hasSkidSlot, which tells
// the *upstream pipeline* feeding enq that there will be a skid slot for it
// this cycle. This lets the upstream pipeline gate its input safely, without
// having any backpressure mechanism afterwards.
//
// For example, a 4-stage rigid pipeline can use an 8-element SkidFIFO with 4
// skid slots reserved. hasSkidSlot would be true as long as there are 4 skid
// slots left. This lets the pipeline start a computation that cycle, with the
// guarantee that there will be sufficient space in all cases.
//
// In FPGAs, skid FIFOs + fixed pipelines are cheaper than pipelines with
// distributed skid buffers, because LUTRAM enables a large FIFO (32-64
// entries) at the same or lower cost as a single skid buffer.
//
// Internally, hasSkidSlot may also be pipelined, which requires more skid
// slots for safety.
interface SkidFIFO#(type data_t);
    method Action enq(data_t x);
    method Action deq;
    method data_t first;
    method Bool hasSkidSlot;
    method Bool notEmpty;
endinterface

module mkSkidFIFO#(FIFOCountIfc#(data_t, depth) baseFifo, Integer skidSlots, Integer backpressureStages)(SkidFIFO#(data_t))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth));

    // Level at which the SkidFIFO must start flagging that it doesn't have slots.
    // We may have up to skidSlots values in flight when initiating
    // backpressure, plus it takes backpressureStages cycles for the producer
    // to see this, so we need to reserve skidSlots + backpressureStages. Note
    // that with no skidSlots = backpressureStages = 0, this devolves to a
    // normal FIFO where hasSkidSlots = notFull = count < depth.
    Integer maxLevel = valueOf(depth) - skidSlots - backpressureStages;

    NonBlockingPipe#(Bool) hasSkidSlotPipe <- mkNonBlockingPipe(backpressureStages, True);
    rule backpressure;
        hasSkidSlotPipe <= (baseFifo.count < fromInteger(maxLevel));
    endrule

    // Though enq could just call baseFifo.enq, this would inherit baseFifo's
    // guard and introduce stall logic upstream, which goes against the use of
    // the SkidFIFO. Instead, enq is *non-blocking*, and we check when we drop
    // an enqueued value on the floor.
    Wire#(Maybe#(data_t)) enqVal <- mkDWire(Invalid);

    // Keep the overflow check explicit so the diagnostic rule remains reachable.
    rule enqueue if (/*baseFifo.notFull &&&*/ enqVal matches tagged Valid .x);
        baseFifo.enq(x);
    endrule

    rule checkNoDrop if (!baseFifo.notFull &&& enqVal matches tagged Valid .x);
        $display($time, " ERROR: SkidFIFO in %m dropped an enqueued value!! Value was enqueued upstream without sufficient skid slots. Either you're not guarding upstream with hasSkidSlot properly, or the number of skid slots is incorrect, or the SkidFIFO implementation is incorrect.");
        $finish;
    endrule

    method Action enq(data_t x) = enqVal._write(Valid(x));
    method Action deq;
        baseFifo.deq;
    endmethod
    method data_t first = baseFifo.first;
    method Bool hasSkidSlot = hasSkidSlotPipe;
    method Bool notEmpty = baseFifo.notEmpty;
endmodule

// Variant with both forward and backward pipelines. Use to decouple long-latency paths.
module mkPipedSkidFIFOF#(FIFOCountIfc#(data_t, depth) baseFifo, Integer forwardStages, Integer backpressureStages)(FIFOF#(data_t))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth));

    SkidFIFO#(data_t) skidFifo <- mkSkidFIFO(baseFifo, forwardStages, backpressureStages);
    NonBlockingPipe#(Maybe#(data_t)) dataPipe <- mkNonBlockingPipe(forwardStages, Invalid);

    Wire#(Maybe#(data_t)) enqVal <- mkDWire(Invalid);
    rule enqIn;
        dataPipe <= enqVal;
    endrule

    rule enqOut if (dataPipe matches tagged Valid .x);
        skidFifo.enq(x);
    endrule

    method Action enq(data_t x) if (skidFifo.hasSkidSlot) = enqVal._write(Valid(x));
    method Action deq = skidFifo.deq;
    method data_t first = skidFifo.first;

    method Bool notFull = skidFifo.hasSkidSlot;
    method Bool notEmpty = skidFifo.notEmpty;

    // NOTE: We could clear the base FIFO, but the stuff in skid slots is not
    // accounted for. Prefer failing explicit if someone calls clear()
    method Action clear;
        $display($time, " ERROR: clear() called, but underlying SkidFIFO in %m does not support clear()");
        $finish;
    endmethod
endmodule

// Variant with auto-pipelined forward path (backward path is just one bit,
// setting it to a fixed value seems OK since the FIFO's max depth needs to
// account for the max anyway)
module mkAutoPipedSkidFIFOF#(FIFOCountIfc#(data_t, depth) baseFifo, Integer maxForwardStages, Integer backpressureStages)(FIFOF#(data_t))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth));

    SkidFIFO#(data_t) skidFifo <- mkSkidFIFO(baseFifo, maxForwardStages, backpressureStages);
    NonBlockingPipe#(Maybe#(data_t)) dataPipe <- mkNonBlockingAutoPipe(maxForwardStages, Invalid);

    Wire#(Maybe#(data_t)) enqVal <- mkDWire(Invalid);
    rule enqIn;
        dataPipe <= enqVal;
    endrule

    rule enqOut if (dataPipe matches tagged Valid .x);
        skidFifo.enq(x);
    endrule

    method Action enq(data_t x) if (skidFifo.hasSkidSlot) = enqVal._write(Valid(x));
    method Action deq = skidFifo.deq;
    method data_t first = skidFifo.first;

    method Bool notFull = skidFifo.hasSkidSlot;
    method Bool notEmpty = skidFifo.notEmpty;

    method Action clear;
        $display($time, " ERROR: clear() called, but underlying SkidFIFO in %m does not support clear()");
        $finish;
    endmethod
endmodule

// FIFOF -> FIFO adapters
module mkPipedSkidFIFO#(FIFOCountIfc#(data_t, depth) baseFifo, Integer forwardStages, Integer backpressureStages)(FIFO#(data_t))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth));
    (* hide *)
    FIFOF#(data_t) f <- mkPipedSkidFIFOF(baseFifo, forwardStages, backpressureStages);
    return fifofToFifo(f);
endmodule

module mkAutoPipedSkidFIFO#(FIFOCountIfc#(data_t, depth) baseFifo, Integer maxForwardStages, Integer maxBackpressureStages)(FIFO#(data_t))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth));
    (* hide *)
    FIFOF#(data_t) f <- mkAutoPipedSkidFIFOF(baseFifo, maxForwardStages, maxBackpressureStages);
    return fifofToFifo(f);
endmodule
