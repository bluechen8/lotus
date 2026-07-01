/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import FIFO::*;
import FIFOF::*;

// If you have a nonblocking pipeline, using mkPipelineFIFO has enqueue guards
// that order the producer after the consumer and sometimes wreck the critical
// path. This is a drop-in replcement that avoids these problems: enqueues are
// unguarded, all methods are unordered, and this will synthesize to a
// bog-standard register. Unlike unguarded FIFOs, this will cause an error if
// you drop an element because your dequeue side is not actually non-blocking.
module mkNonBlockingFIFOF(FIFOF#(data_t)) provisos(Bits#(data_t, dataSz));
    Reg#(Maybe#(data_t)) val <- mkReg(Invalid);
    Wire#(Maybe#(data_t)) enqVal <- mkDWire(Invalid);
    Wire#(Bool) deqDone <- mkDWire(False); // only for debugging, shouldn't exist in synthesis
    Wire#(Bool) doClear <- mkDWire(False);

    rule tick;
        val <= doClear? Invalid : enqVal;
        if (isValid(val) && !deqDone) begin
            $display($time, " %m ERROR: non-blocking FIFO had a value, but it was not dequeued");
            $finish;
        end
    endrule

    method data_t first if (val matches tagged Valid .x) = x;
    method Action deq if (isValid(val)) = deqDone._write(True);
    method Action enq(data_t x) = enqVal._write(Valid(x));
    method Action clear = doClear._write(True);
    method Bool notFull = True;
    method Bool notEmpty = isValid(val);
endmodule

module mkNonBlockingFIFO(FIFO#(data_t)) provisos(Bits#(data_t, dataSz));
    FIFOF#(data_t) fifof <- mkNonBlockingFIFOF;
    return fifofToFifo(fifof);
endmodule
