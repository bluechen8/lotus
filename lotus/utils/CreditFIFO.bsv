/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CreditIfc::*;
import Connectable::*;
import Vector::*;

// CreditFIFO implements FIFOs with credit-based flow control. This is cheaper
// than skid buffers (mkFIFO2), enables higher throughput than mkFIFO1 (which
// is capped at 50%), and avoids the long feedback paths of using
// mkPipelineFIFO.
//
// Consider the following pipeline:
//
//      |    |        |    |                |    |
// s0 ->| f1 |-> s1 ->| f2 |->  s2 -> ... ->| fN |-> sN
//      |    |        |    |                |    |
//          <---|  |----- credit pipe ---------
//
// Here, f1..fN are FIFOs and s0...sN are rules. f1 is the HEAD Credit FIFO, fN
// is the TAIL FIFO, and all other fi are MIDDLE FIFOs. s0 is the PRODUCER rule,
// sN is the CONSUMER rule, and all other si are INTERMEDIATE rules.
// 
// In this credit-based pipe, each FIFO keeps track of a credit counter that
// (conservatively) tracks pipeline occupancy. If the credit counter is
// nonzero, the FIFO locally knows that it can simultaneously enqueue and
// dequeue without a skid buffer (like a PipelineFIFO).
//
// The tail FIFO generates a new credit on each dequeue from sN, which is
// passed back. The key is that the credit path is pipelined, so credits can
// take multiple cycles to propagate back to f1. Roughly speaking, the max
// throughput of a credit pipe is N/(N+X), where X is the number of stages of
// the credit pipe (see detailed analsysis below for the exact throughput of
// the current implementation).
//
// For this to work, the contract is that **intermediate rules must fire if
// they have an input available**. The implementation checks for violations of
// this contract. Producer (s0) and consumer (sN) rules have no restrictions.

/* Interfaces */

// Generic, but you probably want pipes to start/end in head and tail interfaces
interface CreditFIFO#(type data_t, numeric type maxCredits);
    interface RecvCredit#(data_t, TAdd#(maxCredits, 1)) recv;
    interface SendCredit#(data_t, maxCredits) send;
endinterface

interface HeadCreditFIFO#(type data_t, numeric type maxCredits);
    interface SendCredit#(data_t, maxCredits) send;

    // FIFOF on the enq side
    method Action enq(data_t x);
    (* always_ready *)
    method Bool notFull;

    // In case user wants to use an approximation of occupancy to load-balance
    // across queues
    (* always_ready *)
    method Bit#(TLog#(TAdd#(maxCredits, 2))) slotsLeft;
endinterface

interface TailCreditFIFO#(type data_t);
    interface RecvCredit#(data_t, 1) recv;

    // FIFOF on the deq side
    method data_t first;
    method Action deq;
    (* always_ready *)
    method Bool notEmpty;
endinterface

// Convenience
interface CreditFIFOPipe#(type data_t, numeric type maxCredits, numeric type stages);
    interface RecvCredit#(data_t, TAdd#(maxCredits, stages)) recv;
    interface SendCredit#(data_t, maxCredits) send;
endinterface

`ifndef WITH_BLUESIM
// We map CreditFIFOs directly to a parameterized Verilog module purely for QoR reasons
import "BVI" CreditFIFO =
module mkCreditFIFO#(Bool bypassCredit)(CreditFIFO#(data_t, maxCredits)) provisos (Bits#(data_t, dataBits));
   default_clock clk(clk, (*unused*)CLK_GATE);
   default_reset rst();

   parameter WIDTH = valueOf(dataBits);
   parameter MAX_CREDITS  = valueOf(maxCredits);
   parameter BYPASS_CREDIT = Bit#(1)'(pack(bypassCredit));

   interface SendCredit send;
       method send_dataout dataout ready(send_dataout_valid);
       method creditin() enable(send_creditin);
   endinterface

   interface RecvCredit recv;
       method datain((* reg *) recv_datain) enable(recv_datain_valid);
       method recv_creditout creditout;
   endinterface
   
   schedule (send_dataout, recv_creditout) CF (send_dataout, send_creditin, recv_datain, recv_creditout);
   schedule send_creditin CF (send_dataout, recv_datain, recv_creditout);
   schedule recv_datain CF (send_dataout, send_creditin, recv_creditout);
   schedule send_creditin C send_creditin;
   schedule recv_datain C recv_datain;
endmodule

`else

module mkCreditFIFO#(Bool bypassCredit)(CreditFIFO#(data_t, maxCredits)) provisos (Bits#(data_t, dataBits));
    // Denotes available slots DOWNSTREAM, i.e., not including ours
    Reg#(Bit#(TLog#(TAdd#(maxCredits, 1)))) downstreamCredits <- mkReg(0);
    Reg#(Bool) creditOut <- mkReg(True); // initial credit for our slot
    Reg#(Maybe#(data_t)) val <- mkReg(Invalid);

    Wire#(Bool) creditIn <- mkDWire(False);
    Wire#(Maybe#(data_t)) dataIn <- mkDWire(Invalid);

    rule tick;
        Bool deq = isValid(val) && ((downstreamCredits != 0) || creditIn);

        Bool nonFull = !isValid(val) || (downstreamCredits != 0) || (bypassCredit && creditIn);
        if (nonFull) val <= dataIn;
        else if (creditIn) val <= Invalid;

        if (deq != creditIn) begin
            downstreamCredits <= downstreamCredits + (deq? -1 : 1);
            if (creditIn && downstreamCredits == fromInteger(valueOf(maxCredits))) begin
                $display("CreditFIFO ERROR: %m received credit with credits already at max! downstreamCredits=", fshow(downstreamCredits));
                $finish;
            end
        end

        if (bypassCredit) creditOut <= creditOut && creditIn;
        else creditOut <= creditIn;
    endrule

    interface send = interface SendCredit#(data_t, maxCredits);
        method data_t dataout if (val matches tagged Valid .x) = x;
        method Action creditin = creditIn._write(True);
    endinterface;

    interface recv = interface RecvCredit#(data_t, TAdd#(maxCredits, 1));
        method Action datain(data_t din) = dataIn._write(Valid(din));
        method Bool creditout = bypassCredit? (creditOut || creditIn) : creditOut;
    endinterface;
endmodule

`endif

module mkTailCreditFIFO#(Bool bypassCredit)(TailCreditFIFO#(data_t)) provisos (Bits#(data_t, dataBits));
    CreditFIFO#(data_t, 0) q <- mkCreditFIFO(bypassCredit);

    // This is a wayward way of recovering dataout's guard
    Wire#(Maybe#(data_t)) dummy <- mkDWire(Invalid);
    Wire#(Bool) nonEmpty <- mkDWire(False);
    rule setNonEmpty;
        dummy <= Valid(q.send.dataout);
        nonEmpty <= True;
    endrule

    interface recv = q.recv;
    method data_t first = q.send.dataout;
    method Action deq if (nonEmpty) = q.send.creditin;
    method Bool notEmpty = nonEmpty;
endmodule

module mkHeadCreditFIFO(HeadCreditFIFO#(data_t, maxCredits)) provisos (Bits#(data_t, dataBits), Add#(a__, TLog#(TAdd#(maxCredits, 2)), TAdd#(2, TLog#(TAdd#(maxCredits, 1)))));
    Reg#(Bit#(TLog#(TAdd#(maxCredits, 1)))) downstreamCredits <- mkReg(0);
    Reg#(Maybe#(data_t)) val <- mkReg(Invalid);
    Bool nonFull = !isValid(val) || (downstreamCredits != 0);

    Wire#(Bool) creditIn <- mkDWire(False);
    Wire#(Maybe#(data_t)) dataIn <- mkDWire(Invalid);

    rule tick;
        Bool deq = isValid(val) && ((downstreamCredits != 0) || creditIn);
        if (nonFull) val <= dataIn;
        else if (creditIn) val <= Invalid;

        if (deq != creditIn) begin
            downstreamCredits <= downstreamCredits + (deq? -1 : 1);
            if (creditIn && downstreamCredits == fromInteger(valueOf(maxCredits))) begin
                $display("MiddleCreditFIFO ERROR: %m received credit with numCredits already at max! numCredits=", fshow(downstreamCredits));
                $finish;
            end
        end
    endrule

    interface send = interface SendCredit#(data_t, maxCredits);
        method data_t dataout if (val matches tagged Valid .x) = x;
        method Action creditin = creditIn._write(True);
    endinterface;

    method Action enq(data_t x) if (nonFull) = dataIn._write(Valid(x));
    method Bool notFull = nonFull;
    method Bit#(TLog#(TAdd#(maxCredits, 2))) slotsLeft = truncate({2'b0, downstreamCredits} + (!isValid(val)? 1 : 0));
endmodule

// Build longer pipes of credit FIFOs in one shot
typeclass CreditFIFOPipeClass#(type data_t, numeric type maxCredits, numeric type numStages);
    module mkCreditFIFOPipe#(Vector#(numStages, Bool) bypassCreditVec)(CreditFIFOPipe#(data_t, maxCredits, numStages));
endtypeclass

instance CreditFIFOPipeClass#(data_t, maxCredits, 1) provisos(Bits#(data_t, dataBits));
    module mkCreditFIFOPipe#(Vector#(1, Bool) bypassCreditVec)(CreditFIFOPipe#(data_t, maxCredits, 1));
        CreditFIFO#(data_t, maxCredits) x <- mkCreditFIFO(bypassCreditVec[0]);
        interface recv = x.recv;
        interface send = x.send;
    endmodule
endinstance

instance CreditFIFOPipeClass#(data_t, maxCredits, numStages)
    provisos(Bits#(data_t, dataBits), Add#(a__, 2, numStages), CreditFIFO::CreditFIFOPipeClass#(data_t, maxCredits, TSub#(numStages, 1)));
    module mkCreditFIFOPipe#(Vector#(numStages, Bool) bypassCreditVec)(CreditFIFOPipe#(data_t, maxCredits, numStages));
        CreditFIFO#(data_t, TAdd#(maxCredits, TSub#(numStages, 1))) f <- mkCreditFIFO(bypassCreditVec[0]);
        CreditFIFOPipe#(data_t, maxCredits, TSub#(numStages, 1)) r <- mkCreditFIFOPipe(takeTail(bypassCreditVec));
        mkConnection(f.send, r.recv);
        interface recv = f.recv;
        interface send = r.send;
    endmodule
endinstance

// For convenience, also support a 0-elem pipe; this just flips the interface
instance CreditFIFOPipeClass#(data_t, maxCredits, 0) provisos(Bits#(data_t, dataBits));
    module mkCreditFIFOPipe#(Vector#(0, Bool) bypassCreditVec)(CreditFIFOPipe#(data_t, maxCredits, 0));
        Wire#(Bool) creditIn <- mkDWire(False);
        Wire#(Maybe#(data_t)) dataIn <- mkDWire(Invalid);

        interface recv = interface RecvCredit#(data_t, maxCredits);
            method Action datain(data_t din) = dataIn._write(Valid(din));
            method Bool creditout = creditIn;
        endinterface;
        
        interface send = interface SendCredit#(data_t, maxCredits);
            method data_t dataout if (dataIn matches tagged Valid .x) = x;
            method Action creditin = creditIn._write(True);
        endinterface;
    endmodule
endinstance

// Variant where numStages is an Integer, enabling different sizes (down to 0) during static elaboration
// NOTE: This allows using Integers while preserving the type guarantees of
// Send/RecvCredit connections; if you specify numStages > maxStages, static
// elaboration will blow up when maxStages in the recursion goes below 0 (which
// numeric types don't support). You'll get a compiler error like:
//    "Cannot take valueOf `Prelude.TSub 0 1' (symbol might not be in scope)"
module mkNonBypassCreditFIFOPipe#(Integer numStages)(CreditFIFOPipe#(data_t, maxCredits, maxStages)) provisos(Bits#(data_t, dataBits));
    if (numStages == 0) begin
        Wire#(Bool) creditIn <- mkDWire(False);
        Wire#(Maybe#(data_t)) dataIn <- mkDWire(Invalid);

        interface recv = interface RecvCredit#(data_t, maxCredits);
            method Action datain(data_t din) = dataIn._write(Valid(din));
            method Bool creditout = creditIn;
        endinterface;

        // Type punning happens here --- we go up to whatever credit count the other side assumes, which is safe
        interface send = interface SendCredit#(data_t, TAdd#(maxCredits, maxStages));
            method data_t dataout if (dataIn matches tagged Valid .x) = x;
            method Action creditin = creditIn._write(True);
        endinterface;
    end else begin
        CreditFIFO#(data_t, maxCredits) l <- mkCreditFIFO(False);
        CreditFIFOPipe#(data_t, TAdd#(maxCredits, 1), TSub#(maxStages, 1)) n <- mkNonBypassCreditFIFOPipe(numStages - 1);
        mkConnection(n.send, l.recv);

        interface recv = n.recv;
        interface send = l.send;
    end
endmodule

// Connection helpers
module mkCreditStageConnection#(SendCredit#(t, maxSendCredits) send, RecvCredit#(u, maxRecvCredits) recv, function u stageFn(t x))(Empty)
    provisos (Add#(maxRecvCredits, __a, maxSendCredits));
    rule connectData;
        recv.datain(stageFn(send.dataout));
    endrule
    rule connectCredit if (recv.creditout);
        send.creditin;
    endrule
endmodule

import CommitIfc::*;


instance ToRecvCommit#(HeadCreditFIFO#(t, n), t) provisos(Bits#(t, tBits));
    module mkRecvCommit#(HeadCreditFIFO#(t, n) q)(RecvCommit#(t));
        Wire#(Maybe#(t)) enqVal <- mkDWire(Invalid);
        rule doEnq if (enqVal matches tagged Valid .x);
            q.enq(x);
        endrule
        
        // Can't call enq directly, as it's always_ready
        method Action datain (t din) = enqVal._write(Valid(din));
        method Bool accept = q.notFull;
    endmodule
endinstance

instance ToSendCommit#(TailCreditFIFO#(t), t);
    module mkSendCommit#(TailCreditFIFO#(t) q)(SendCommit#(t));
        Wire#(Bool) acked <- mkDWire(False);
        rule doDeq if (q.notEmpty && acked);
            q.deq;
        endrule
        
        method t dataout = q.first;
        method Action ack = acked._write(True);
    endmodule
endinstance

instance Connectable#(HeadCreditFIFO#(t, n), SendCommit#(t)) provisos(Bits#(t, tBits));
    module mkConnection#(HeadCreditFIFO#(t, n) q, SendCommit#(t) send)(Empty);
        RecvCommit#(t) q_recv <- mkRecvCommit(q);
        mkConnection(q_recv, send);
    endmodule
endinstance

instance Connectable#(SendCommit#(t), HeadCreditFIFO#(t, n)) provisos(Bits#(t, tBits));
    module mkConnection#(SendCommit#(t) send, HeadCreditFIFO#(t, n) q)(Empty);
        mkConnection(q, send);
    endmodule
endinstance
 
instance Connectable#(TailCreditFIFO#(t), RecvCommit#(t));
    module mkConnection#(TailCreditFIFO#(t) q, RecvCommit#(t) recv)(Empty);
        SendCommit#(t) q_send <- mkSendCommit(q);
        mkConnection(q_send, recv);
    endmodule
endinstance

instance Connectable#(RecvCommit#(t), TailCreditFIFO#(t));
    module mkConnection#(RecvCommit#(t) recv, TailCreditFIFO#(t) q)(Empty);
        mkConnection(q, recv);
    endmodule
endinstance

// Throughput/correctness test
//
// Thoughput characteristics are interesting. For a 4-stage pipe, where the 3
// letters denote whether the credit is pipelined between stages (e.g., F F F
// denotes fully combinational credit path, T F F a reg between f1 and f2):
// F F F -> 100% (4/4)
//
// T F F -> 80% (4/5)
// F T F -> 75% (3/4)
// F F T -> 66% (2/3)
//
// T T F -> 66% (2/3)
// T F T -> 66% (2/3)
// F T T -> 60% (3/5)
//
// T T T -> 57% (4/7) 
//
// What's a systematic way to derive/optimize this?
// - With a single N-stage pipeline, we have N cycles forward, X cycles back,
//   where X is the number of pipeline stages for the credit signal. We can put
//   N/(N+X); so, e.g., F F F is X = 0, hence 4/4, T T T is X=3, hence 4/7.
// - But you can't just look at the entire pipeline, because the tail end of
//   the pipeline can dominate. For example, in T F F we do have 4/5 because
//   only the first stage incurs the extra delay, but F T F is tailed by a
//   3-stage pipeline with T F, so N=3, X=1, hence 3/4.
// - In short, throughput is min(n/(n+x)) for n=1...N and x is whatever number
//   of credit stages you have in that pipe. For example,
//   + T T F has min(4/(4+2), 3/(3+1), 2/2, 1/1) = 3/6 = 2/3
//   + T F T has min(4/(4+2), 3/(3+1), 2/(2+1), 1/1) = 3/6 = 2/3 (with 2 matches)
//   + F T T has min(4/(4+2), 3/(3+2), 2/(2+1), 1/1) = 3/5
// - To get max throughput for a given clock frequency, have the latest credit
//   pipe as far as you can, and then stick to that ratio. For example, if you
//   can have the last 2 stages of the pipeline be F F, then ...TFFTFFTFF
//   suffices (and gets 3/4 throughput).
module mkTestCreditFIFO(Empty);
    HeadCreditFIFO#(Bit#(32), 7) cf0 <- mkHeadCreditFIFO;
    CreditFIFO#(Bit#(32), 1) cf1 <- mkCreditFIFO(False);
    TailCreditFIFO#(Bit#(32)) cf2 <- mkTailCreditFIFO(False);
    mkConnection(cf0.send, cf1.recv);
    mkConnection(cf1.send, cf2.recv);

    Reg#(Bit#(32)) cycle <- mkReg(0);
    Reg#(Bit#(32)) deqs <- mkReg(0);
    rule incCycle;
        cycle <= cycle + 1;
    endrule

    rule enq;
        $display("cycle=%d enq=%d", cycle, cycle);
        cf0.enq(cycle);
    endrule

    rule deq; //if (cycle % 4 == 0);
        $display("cycle=%d deq=%d lat=%d", cycle, cf2.first, cycle-cf2.first);
        cf2.deq;
        deqs <= deqs + 1;

        if (cycle >= 10000) begin
            $display("Throughput: %d%%", (100 * (deqs+1) / (cycle-3)));
            $finish;
        end
    endrule
endmodule
