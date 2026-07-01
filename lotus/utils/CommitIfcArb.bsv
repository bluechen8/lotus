/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import CommitIfc::*;
import Vector::*;
import Assert::*;
import FunctionalUtils::*;
import Sip::*; // for castWidth (FIXME: move to a reasonable place)

interface SendCommitArb#(numeric type numElems, type data_t);
    interface Vector#(numElems, SendCommit#(data_t)) outs;
    interface RecvCommit#(data_t) in;
    method Maybe#(UInt#(TLog#(numElems))) destIdx;
endinterface

interface RecvCommitArb#(numeric type numElems, type data_t);
    interface Vector#(numElems, RecvCommit#(data_t)) ins;
    interface SendCommit#(data_t) out;
    interface SendCommit#(Tuple2#(Bit#(TLog#(numElems)), data_t)) outWithIdx;
endinterface

// Arbiter policies
typedef UInt#(TLog#(numElems)) Idx#(numeric type numElems);

// Prioritize first set. Simple, but unfair.
function ActionValue#(Maybe#(Idx#(numElems))) priorityArbiter(Vector#(numElems, Bool) ins) = actionvalue
     return findIndex(isTrue, ins);
endactionvalue;

// Round-robin: pick first request starting from the one following the last grant. This requires state.
interface RoundRobinPrio#(numeric type n);
    method ActionValue#(Maybe#(Idx#(n))) getPrio(Vector#(n, Bool) reqs);
endinterface

typeclass RoundRobinPrioClass#(numeric type n);
function Maybe#(Bit#(TLog#(n))) getRoundRobinPrio(Bit#(TLog#(n)) start, Bit#(n) reqs);
endtypeclass

instance RoundRobinPrioClass#(1);
function Maybe#(Bit#(0)) getRoundRobinPrio(Bit#(0) start, Bit#(1) reqs) = (reqs[0] == 1)? Valid(?) : Invalid;
endinstance

instance RoundRobinPrioClass#(n)
    provisos(
        Add#(a__, 2, n),
        NumAlias#(TExp#(TSub#(TLog#(n), 1)), nLo),
        Add#(nLo, nHi, n),
        RoundRobinPrioClass#(nLo),
        RoundRobinPrioClass#(nHi)
    );
function Maybe#(Bit#(TLog#(n))) getRoundRobinPrio(Bit#(TLog#(n)) start, Bit#(n) reqs);
    Bit#(nLo) loReqs = castWidth(reqs);
    Bit#(nHi) hiReqs = castWidth(reqs >> valueOf(nLo));
    let loRes = getRoundRobinPrio(castWidth(start), loReqs);
    let hiRes = getRoundRobinPrio(castWidth(start), hiReqs);

    Bool loPrio = start[valueOf(TLog#(n))-1] == 1'b0;

    if (!isValid(loRes) && !isValid(hiRes)) return Invalid;
    else if (loPrio) return Valid(isValid(loRes)? {1'b0, fromMaybe(?, loRes)} : {1'b1, castWidth(fromMaybe(?, hiRes))});
    else return Valid(isValid(hiRes)? {1'b1, castWidth(fromMaybe(?, hiRes))} : {1'b0, fromMaybe(?, loRes)});
endfunction
endinstance

module mkRoundRobinPrio(RoundRobinPrio#(n)) provisos(RoundRobinPrioClass#(n));
    Reg#(Bit#(TLog#(n))) start <- mkReg(0);

    method ActionValue#(Maybe#(Idx#(n))) getPrio(Vector#(n, Bool) reqs);
        let res = getRoundRobinPrio(start, pack(reqs));
        if (isValid(res)) begin
            let nextStart = fromMaybe(?, res) + 1;
            // When n is not a power of 2, adjust n-1 -> 0
            if (valueOf(TExp#(TLog#(n))) != valueOf(n) && fromMaybe(?, res) == fromInteger(valueOf(n)-1)) nextStart = 0;
            start <= nextStart;
        end
        return isValid(res)? Valid(unpack(fromMaybe(?, res))) : Invalid;
    endmethod
endmodule

module mkSendCommitArb#(function ActionValue#(Maybe#(Idx#(numElems))) arbFunc(Vector#(numElems, Bool) z))
                        (SendCommitArb#(numElems, data_t)) provisos(Bits#(Maybe#(data_t), a__));

    Vector#(numElems, Wire#(Bool)) outsCanSendTo <- replicateM(mkDWire(False));

    Wire#(Maybe#(Idx#(numElems))) sendTo <- mkBypassWire;
    Wire#(Maybe#(data_t)) sendValue <- mkDWire(Invalid);

    rule setSendTo;
        let v <- arbFunc(map(readReg, outsCanSendTo));
        sendTo <= v;
    endrule

    module createSendCommit#(Integer outId)(SendCommit#(data_t));
        Wire#(Maybe#(data_t)) dataToSend <- mkDWire(Invalid);

        rule calc;
            function Maybe#(data_t) matchId(Idx#(numElems) idx, data_t value);
                return (idx == fromInteger(outId)) ? Valid(value) : Invalid;
            endfunction
            dataToSend <= maybeAndFail2(matchId, sendTo, sendValue);
        endrule

        method data_t dataout if (dataToSend matches tagged Valid .dts) = dts;
        method Action ack = outsCanSendTo[outId]._write(True);
    endmodule
    Vector#(numElems, SendCommit#(data_t)) outs_ <- genWithM(createSendCommit);


    interface Vector outs = outs_;

    interface RecvCommit in;
        method Action datain (data_t din) = sendValue._write(Valid(din));
        method Bool accept = isValid(sendTo);
    endinterface

    method Maybe#(UInt#(TLog#(numElems))) destIdx = sendTo;

endmodule

module mkRecvCommitArb#(function ActionValue#(Maybe#(Idx#(numElems))) arbFunc(Vector#(numElems, Bool) z))
        (RecvCommitArb#(numElems, data_t)) provisos(Bits#(Maybe#(data_t), a__), Add#(1, x__, numElems), FShow#(data_t));

    Vector#(numElems, Wire#(Maybe#(data_t))) sendValues <- replicateM(mkDWire(Invalid));
    Vector#(numElems, Wire#(Bool))           accepts    <- replicateM(mkDWire(False));

    Wire#(Maybe#(Bit#(TLog#(numElems)))) takeFrom <- mkDWire(tagged Invalid);

    Wire#(Bool) doAccept <- mkDWire(False);

    rule setTakeFrom;
        Vector#(numElems, Bool) availValues = map(isValid, map(readReg, sendValues));
        Maybe#(Idx#(numElems)) takeFromI <- arbFunc(availValues);
        Maybe#(Bit#(TLog#(numElems))) takeFromB  = mapMaybe(pack, takeFromI);

        takeFrom <= takeFromB;
        dynamicAssert(!isValid(takeFromB) || availValues[fromMaybe(?, takeFromB)],
            "mkRecvCommitArb: arbFunc result cannot be valid if the selected input is not valid");
    endrule

    rule setAccepts;
        if (takeFrom matches tagged Valid .takeFromIdx) begin
            accepts[takeFromIdx] <= doAccept;
        end
    endrule

    module createRecvCommit#(Integer inId)(RecvCommit#(data_t));
        method Action datain (data_t din) = sendValues[inId]._write(Valid(din));
        method Bool accept = readReg(accepts[inId]);
    endmodule
    Vector#(numElems, RecvCommit#(data_t)) ins_ <- genWithM(createRecvCommit);
    interface Vector ins = ins_;

    interface SendCommit out;
        method data_t dataout if (isValid(takeFrom)) = fromMaybe(?, sendValues[fromMaybe(?, takeFrom)]);
        method Action ack = doAccept._write(True);
    endinterface

    interface SendCommit outWithIdx;
        method Tuple2#(Bit#(TLog#(numElems)), data_t) dataout if (isValid(takeFrom)) = tuple2(fromMaybe(?, takeFrom), fromMaybe(?, sendValues[fromMaybe(?, takeFrom)]));
        method Action ack = doAccept._write(True);
    endinterface
endmodule

