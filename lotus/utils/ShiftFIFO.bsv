/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import FIFO::*;
import FIFOLevel::*;
import Vector::*;
import CommitIfc::*;

// Base shift register; implemented in SV for efficient inference
interface ShiftRegister#(type data_t, numeric type depth);
    (* always_ready *)
    method Action shiftIn(data_t val);
    (* always_ready *)
    method data_t read(Bit#(TLog#(depth)) addr);
endinterface

`ifndef WITH_BLUESIM
import "BVI" ShiftRegister =
module mkShiftRegister#(Vector#(initElems, data_t) initialValues)(ShiftRegister#(data_t, depth)) provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(initElems, __y, depth));
   default_clock clk(clk, (*unused*)CLK_GATE);
   default_reset rst();

   parameter WIDTH = valueOf(dataSz);
   parameter DEPTH = valueOf(depth);
   parameter INITIAL_VALUE  = Bit#(TMul#(dataSz, initElems)) ' (pack(initialValues));

   method shiftIn((* reg *)din) enable(shiftEn);
   method dout read(addr);

   schedule read  CF (shiftIn, read);
   schedule shiftIn C shiftIn;
endmodule

`else

module mkShiftRegister#(Vector#(initElems, data_t) initialValues)(ShiftRegister#(data_t, depth)) provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(initElems, __y, depth));
    // This implementation reliably infers to single-bit SRLs; I've tried
    // variants using vectors and concatenation, but vivado can't catch the
    // generated verilog is an SRL (the key issue is that bsc's verilog
    // expresses bit slicing or vector element selection using a case
    // statement; if you manually edit the verilog to change the implementation
    // of first(), it infers a multi-bit SRL)
    Vector#(dataSz, Bit#(depth)) initRegVals = unpack(0);
    for (Integer i = 0; i < valueOf(initElems); i = i + 1)
        for (Integer j = 0; j < valueOf(dataSz); j = j + 1)
            initRegVals[j][i] = pack(initialValues[i])[j];

    Vector#(dataSz, Reg#(Bit#(depth))) shiftRegs;
    for (Integer j = 0; j < valueOf(dataSz); j = j + 1)
        shiftRegs[j] <- mkReg(initRegVals[j]);

    Wire#(Maybe#(data_t)) shiftVal <- mkDWire(Invalid);

    rule tick;
        if (shiftVal matches tagged Valid .val) begin
            Bit#(dataSz) rawVal = pack(val);
            for (Integer i = 0; i < valueOf(dataSz); i = i + 1) begin
                shiftRegs[i] <= {truncate(shiftRegs[i]), rawVal[i]};
            end
        end
    endrule

    method Action shiftIn(data_t val) = shiftVal._write(Valid(val));

    method data_t read(Bit#(TLog#(depth)) addr);
        Bit#(dataSz) rawVal = ?; // all bits are initialized, but when dataSz == 1, bsc can't
                                 // deduce this and throws an error if rawVal is uninitalized
        for (Integer i = 0; i < valueOf(dataSz); i = i + 1) begin
            rawVal[i] = shiftRegs[i][addr];
        end
        return unpack(rawVal);
    endmethod
endmodule

`endif

// FIFO using shift registers; this is about the most LUT-efficient FIFO type
// on UltraScale FPGAs up to 16-32 elements. Larger FIFOs should use a LUTRAM
// based FIFO, e.g., mkSizedFIFO.
// NOTE: ugenq makes enq unguarded; ugdeq makes first and deq unguarded. This
// is the same as for GFIFOF.
module mkGShiftFIFOCountInit#(Bool ugenq, Bool ugdeq, Vector#(initElems, data_t) initialContents)(FIFOCountIfc#(data_t, depth))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(initElems,__y, depth), Add#(a__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));

    // Reverse initial contents to keep FIFO order (0 == first out)
    ShiftRegister#(data_t, depth) shiftReg <- mkShiftRegister(reverse(initialContents));

    // Points to first elem; ~0 when empty, so enqueues always increase
    Reg#(Bit#(TLog#(depth))) pos <- mkReg(fromInteger(valueOf(initElems)-1));
    Reg#(Bool) nonEmpty <- mkReg(valueOf(initElems) != 0);

    Wire#(Bool) doEnq <- mkDWire(False);
    Wire#(Bool) doDeq <- mkDWire(False);
    Wire#(Bool) doClear <- mkDWire(False);

    Wire#(Bool) nonFull <- mkBypassWire;
    rule setNonFull;
        // TODO: Specialize for non-power-of-2, which doesn't need the empty check
        nonFull <= !((pos == fromInteger(valueOf(depth)-1)) && nonEmpty);
    endrule

    rule tick;
        if (doClear) pos <= ~0;
        else pos <= pos + ((doEnq && !doDeq)? 1 : ((!doEnq && doDeq)? -1 : 0));

        if (doClear || ((pos == 0) && !doEnq && doDeq)) nonEmpty <= False;
        else if (doEnq) nonEmpty <= True;

        // Checks, needed only for unguarded variants
        if (ugenq && !nonFull && doEnq && !doClear) begin
            $display("ERROR: %m: enqueued to a full ShiftFIFO!");
            $finish;
        end
        if (ugdeq && !nonEmpty && doDeq) begin
            $display("ERROR: %m: dequeued from an empty ShiftFIFO!");
            $finish;
        end
    endrule

    method Action enq(data_t v) if (ugenq || nonFull);
        doEnq <= True;
        shiftReg.shiftIn(v);
    endmethod

    method Action deq() if (ugdeq || nonEmpty);
        doDeq <= True;
    endmethod

    method data_t first if (ugdeq || nonEmpty) = shiftReg.read(pos);

    method Bool notFull = nonFull;
    method Bool notEmpty = nonEmpty;

    method UInt#(TLog#(TAdd#(depth,1))) count = nonEmpty? unpack(truncate({2'b0, pos} + 1)) : 0;

    method Action clear;
        doClear <= True;
    endmethod
endmodule

module mkShiftFIFOCountInit#(Vector#(initElems, data_t) initialContents)(FIFOCountIfc#(data_t, depth))
    provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(initElems,__y, depth), Add#(a__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));
    (* hide *)
    FIFOCountIfc#(data_t, depth) x <- mkGShiftFIFOCountInit(False, False, initialContents);
    return x;
endmodule

module mkShiftFIFOCount(FIFOCountIfc#(data_t, depth)) provisos(Bits#(data_t, dataSz), Add#(__x, 1, depth), Add#(a__, TLog#(TAdd#(depth, 1)), TAdd#(2, TLog#(depth))));
    (* hide *)
    FIFOCountIfc#(data_t, depth) x <- mkShiftFIFOCountInit(nil);
    return x;
endmodule

// FIXME: This is more general than ShiftFIFO, move out if there are other uses
import FIFOF::*;
    
function FIFOF#(a) fifoCountToFifof(FIFOCountIfc#(a, _) f) = interface FIFOF#(a);
    method Action enq(a x) = f.enq(x);
    method Action deq = f.deq;
    method a first = f.first;
    method Action clear = f.clear;
    method Bool notFull = f.notFull;
    method Bool notEmpty = f.notEmpty;
endinterface;

module castFIFOCountToSendCommit#(FIFOCountIfc#(data_t, depth) fifo)(SendCommit#(data_t));

    Wire#(Bool) doDeq <- mkDWire(False);

    rule doDeqR;
        fifo.deq;
    endrule

    method data_t dataout = fifo.first;

    method Action ack;
        doDeq <= True;
    endmethod
endmodule

module castFIFOCountToRecvCommit#(FIFOCountIfc#(data_t, depth) fifo)(RecvCommit#(data_t)) provisos(Bits#(data_t, dataBits));

    Wire#(Maybe#(data_t)) dataToEnq <- mkDWire(tagged Invalid);

    rule enqData if (dataToEnq matches tagged Valid .d);
        fifo.enq(d);
    endrule

    method Action datain(data_t din) = dataToEnq._write(tagged Valid din);

    method Bool   accept             = fifo.notFull;


endmodule


