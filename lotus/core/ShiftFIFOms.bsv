/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import FIFOLevel::*;
import ShiftFIFO::*;
import Vector::*;

interface MsFIFOCountIfc#(type data_t, numeric type depth);
    method Action enq___input(Maybe#(data_t) x); // default = Invalid
    method Action deq___input(Bool x); // default == False
    method Action clear___input(Bool x); // default == False
    method Maybe#(data_t) first;
    method Bool notFull;
    method Bool notEmpty;
    method UInt#(TLog#(TAdd#(depth,1))) count;
endinterface

typedef MsFIFOCountIfc#(data_t, depth) ShiftFIFO#(type data_t, numeric type depth);
typedef MsFIFOCountIfc#(data_t, depth) ShiftFIFOInit#(type data_t, numeric type depth);

module mkShiftFIFOInit#(Vector#(initElems, data_t) initialContents)(MsFIFOCountIfc#(data_t, depth))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(initElems,__y, depth), Add#(a__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));

    FIFOCountIfc#(data_t, depth) q <- mkShiftFIFOCountInit(initialContents);

    Wire#(Maybe#(data_t)) firstElem <- mkDWire(Invalid);
    rule setFirstElem;
        firstElem <= Valid(q.first);
    endrule

    Wire#(Maybe#(data_t)) enqVal <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);
    Wire#(Bool) doClear <- mkDWire(False);

    rule passEnq if (enqVal matches tagged Valid .x); q.enq(x); endrule
    rule passDeq if (doDeq); q.deq; endrule
    rule passClear if (doClear); q.clear; endrule

    // Methods that obey Minispec semantics --- no guards
    method Action enq___input(Maybe#(data_t) x) = enqVal._write(x);
    method Action deq___input(Bool x) = doDeq._write(x);
    method Action clear___input(Bool x) = doClear._write(x);
    method Maybe#(data_t) first = firstElem;
    method Bool notFull = q.notFull;
    method Bool notEmpty = q.notEmpty;
    method UInt#(TLog#(TAdd#(depth,1))) count = q.count;
endmodule

module mkShiftFIFO(MsFIFOCountIfc#(data_t, depth))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(a__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));

    MsFIFOCountIfc#(data_t, depth) q <- mkShiftFIFOInit(nil);
    return q;
endmodule
