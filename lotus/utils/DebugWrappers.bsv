/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;
import FIFOLevel::*;
import SkidFIFO::*;
import CreditIfc::*;
import CreditFIFO::*;


module mkDebugFIFO#(Bool dbg, Fmt name, FIFO#(data_t) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(FIFO#(data_t)) provisos(Bits#(data_t, dataBits), FShow#(data_t));

    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    rule ddqd;
        deqData <= fifo.first;
    endrule

    method Action enq (data_t x);
        doEnq <= tagged Valid x;
        fifo.enq(x);
    endmethod
    method Action deq;
        doDeq <= True;
        fifo.deq;
    endmethod
    method data_t first = fifo.first;
    method Action clear = fifo.clear;

endmodule

module mkDebugFIFOF#(Bool dbg, Fmt name, FIFOF#(data_t) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(FIFOF#(data_t)) provisos(Bits#(data_t, dataBits), FShow#(data_t));

    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    rule ddqd;
        deqData <= fifo.first;
    endrule

    method Action enq (data_t x);
        doEnq <= tagged Valid x;
        fifo.enq(x);
    endmethod
    method Action deq;
        doDeq <= True;
        fifo.deq;
    endmethod
    method data_t first = fifo.first;


    method Bool notFull          = fifo.notFull;
    method Bool notEmpty         = fifo.notEmpty;
    method Action clear          = fifo.clear;
endmodule

module mkDebugSkidFIFO#(Bool dbg, Fmt name, SkidFIFO#(data_t) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(SkidFIFO#(data_t)) provisos(Bits#(data_t, dataBits), FShow#(data_t));

    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    rule ddqd;
        deqData <= fifo.first;
    endrule

    method Action enq (data_t x);
        doEnq <= tagged Valid x;
        fifo.enq(x);
    endmethod
    method Action deq;
        doDeq <= True;
        fifo.deq;
    endmethod
    method data_t first = fifo.first;


    method Bool hasSkidSlot = fifo.hasSkidSlot;
    method Bool notEmpty = fifo.notEmpty;
endmodule


module mkDebugFIFOCount#(Bool dbg, Fmt name, FIFOCountIfc#(data_t, elems) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(FIFOCountIfc#(data_t, elems)) provisos(Bits#(data_t, dataBits), FShow#(data_t));

    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    rule ddqd;
        deqData <= fifo.first;
    endrule

    method Action enq (data_t x);
        doEnq <= tagged Valid x;
        fifo.enq(x);
    endmethod
    method Action deq;
        doDeq <= True;
        fifo.deq;
    endmethod
    method data_t first = fifo.first;

    method Bool notFull                       = fifo.notFull;
    method Bool notEmpty                      = fifo.notEmpty;
    method UInt#(TLog#(TAdd#(elems,1))) count = fifo.count;
    method Action clear                       = fifo.clear;
endmodule

module mkDebugHeadCreditFIFO#(Bool dbg, Fmt name, HeadCreditFIFO#(data_t, maxCredits) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(HeadCreditFIFO#(data_t, maxCredits))
              provisos (Bits#(data_t, dataBits), Add#(a__, TLog#(TAdd#(maxCredits, 2)), TAdd#(2, TLog#(TAdd#(maxCredits, 1)))), FShow#(data_t));
    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    Wire#(Bool) send_creditin <- mkDWire(False);
    rule doDeqRule if (send_creditin);
        doDeq <= True;
        deqData <= fifo.send.dataout;
    endrule

    method Action enq (data_t x);
        doEnq <= tagged Valid x;
        fifo.enq(x);
    endmethod
    method Bool notFull          = fifo.notFull;
    method Bit#(TLog#(TAdd#(maxCredits, 2))) slotsLeft = fifo.slotsLeft;


    interface send = interface SendCredit#(data_t, maxCredits);
        method data_t dataout = fifo.send.dataout;
        method Action creditin;
            send_creditin <= True;
            fifo.send.creditin;
        endmethod
    endinterface;
endmodule

module mkDebugTailCreditFIFO#(Bool dbg, Fmt name, TailCreditFIFO#(data_t) fifo, Wire#(Bool) didEnq, Wire#(Bool) didDeq)(TailCreditFIFO#(data_t))
         provisos (Bits#(data_t, dataBits), FShow#(data_t));

    Wire#(Maybe#(data_t)) doEnq <- mkDWire(Invalid);
    Wire#(Bool) doDeq <- mkDWire(False);

    Wire#(data_t) deqData <- mkDWire(?);

    Reg#(Bit#(64)) numElems <- mkReg(0);

    rule updatePerfStatus;
`ifdef FPGA_DEBUGGING
        didEnq <= isValid(doEnq);
        didDeq <= doDeq;
`else
        didEnq <= False;
        didDeq <= False;
`endif
    endrule

    rule tick;
        case (tuple2(doEnq, doDeq)) matches
            {tagged Valid .enq, True}: begin
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ-DEQ  ")
                                + $format(" %0d => %0d", numElems, numElems)
                                + $format(" +++ ENQ = ") + fshow(enq)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
            end
            {tagged Invalid, True}: begin
                let nv = numElems-1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("    DEQ  ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" --- DEQ = ") + fshow(deqData);
                if (dbg) $display($time, toWrite);
                numElems <= nv;

            end
            {tagged Valid .enq, False}: begin
                let nv = numElems+1;
                let toWrite = $format(": [%m]")
                                + $format("[") + name + $format("]")
                                + $format("ENQ      ")
                                + $format(" %0d => %0d", numElems, nv)
                                + $format(" +++ ENQ = ") + fshow(enq);
                if (dbg) $display($time, toWrite);
                numElems <= nv;
            end
        endcase
    endrule

    rule ddqd;
        deqData <= fifo.first;
    endrule

    Wire#(Maybe#(data_t)) currentEnq <- mkDWire(tagged Invalid);
    rule enqRule if (fifo.recv.creditout);
        doEnq <= currentEnq;
    endrule

    method data_t first = fifo.first;
    method Action deq;
        doDeq <= True;
        fifo.deq;
    endmethod
    method Bool notEmpty         = fifo.notEmpty;

    interface recv = interface RecvCredit#(data_t, TAdd#(maxCredits, 1));
        method Action datain(data_t din);
            currentEnq <= tagged Valid din;
            fifo.recv.datain(din);
        endmethod
        method Bool creditout = fifo.recv.creditout;
    endinterface;

endmodule

// Count total enqueues and dequeues of an underlying FIFOF
interface ProfileFIFOF#(type data_t);
    interface FIFOF#(data_t) fifof;
    method Bit#(64) totalEnqs;
    method Bit#(64) totalDeqs;
endinterface

module mkProfileFIFOF#(FIFOF#(data_t) q)(ProfileFIFOF#(data_t));
    Reg#(Bit#(64)) enqs <- mkReg(0);
    Reg#(Bit#(64)) deqs <- mkReg(0);

    PulseWire countEnq <- mkPulseWire;
    PulseWire countDeq <- mkPulseWire;

    rule count;
        if (countEnq) enqs <= enqs + 1;
        if (countDeq) deqs <= deqs + 1;
    endrule
    
    interface fifof = interface FIFOF#(data_t);
        method Action enq(data_t x);
            countEnq.send;
            q.enq(x);
        endmethod

        method Action deq;
            countDeq.send;
            q.deq;
        endmethod

        method first = q.first;
        method notFull = q.notFull;
        method notEmpty = q.notEmpty;
        method clear = q.clear;
    endinterface;

    method totalEnqs = enqs._read;
    method totalDeqs = deqs._read;
endmodule
