/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CommitIfc::*;
import Connectable::*;
import GetPut::*;
import Vector::*;
import LFSR::*;

import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;

typedef struct {
    Bit#(TLog#(numOuts)) dest;
    data_t data;
} SwitchReq#(numeric type numOuts, type data_t) deriving (Bits, FShow);

interface Switch#(numeric type numIns, numeric type numOuts, type data_t);
    interface Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in;
    interface Vector#(numOuts, SendCommit#(data_t)) out;
endinterface

/* 1. Combinational switch */

function Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) getIns(Switch#(numIns, numOuts, data_t) s) = s.in;
function Vector#(numOuts, SendCommit#(data_t)) getOuts(Switch#(numIns, numOuts, data_t) s) = s.out;

// mkBaseSwitch is non-synthesizable and has a prio argument; mkSwitch adds round-robin priorities
typeclass SwitchClass#(numeric type numIns, numeric type numOuts, type data_t);
    module mkBaseSwitch#(Bit#(TLog#(numIns)) prio)(Switch#(numIns, numOuts, data_t));
endtypeclass

/* Base cases */

// Used for low radixes, except 2x2 which is optimized separately
// We leverage the fact that in FPGAs with LUT6s, for low radixes, crossbars
// are more efficient than combinations of 2x2 switches while providing more
// throughput. For example, a 64-bit 4x4 switch  built out of 2x2 switches
// takes 354 LUTs, 69 CLBs (post-PnR), and has a 1.1ns pre-PnR critical path. A
// 4x4 crossbar takes 304 LUTs, 40 CLBs (post-PnR), and has a 0.91ns critical
// path (pre-PnR), as well as having full throughput.
module mkCrossbarSwitch#(Bit#(TLog#(numIns)) prio)(Switch#(numIns, numOuts,
        data_t)) provisos(Bits#(data_t, dataBits), Add#(__a, 1, numIns),
        Add#(__b, 1, numOuts));
    Vector#(numIns, Wire#(Maybe#(SwitchReq#(numOuts, data_t)))) dataIns <- replicateM(mkDWire(Invalid));
    Vector#(numOuts, Wire#(Maybe#(data_t))) dataOuts <- replicateM(mkDWire(Invalid));
    
    Vector#(numOuts, Wire#(Bool)) acks <- replicateM(mkDWire(False));
    Wire#(Vector#(numOuts, Maybe#(Bit#(TLog#(numIns))))) selects <- mkBypassWire;
    Vector#(numIns, Wire#(Bool)) accepts <- replicateM(mkBypassWire);

    Bool numInsIsPow2 = valueOf(TExp#(TLog#(numIns))) == valueOf(numIns);

    rule tick;
        Vector#(numOuts, Vector#(numIns, Bool)) reqMatrix = ?;
        for (Integer i = 0; i < valueOf(numOuts); i = i + 1) begin
            for (Integer j = 0; j < valueOf(numIns); j = j + 1) begin
                reqMatrix[i][j] = isValid(dataIns[j]) && fromMaybe(?, dataIns[j]).dest == fromInteger(i);
            end
        end

        Vector#(numOuts, Maybe#(Bit#(TLog#(numIns)))) sel = replicate(Invalid);
        for (Integer i = 0; i < valueOf(numOuts); i = i + 1) begin
            // Priority encoder starting at prio; this looks complex, but
            // compiles to a few LUTs. For example, witn numIns=4, prio is 2
            // bits and reqMatrix is 4 bits per row, so this is 3 LUT6s per
            // select signal (one per bit)
            for (Integer j = valueOf(numIns)-1; j >= 0; j = j - 1) begin
                Bit#(TLog#(numIns)) pos = (prio + fromInteger(j));
                // Modding is needed for correctness when numIns isn't a power
                // of 2, but we can't do it when it's a power of 2 because
                // in that case numIns is an out-of-range literal
                if (!numInsIsPow2) pos = pos % fromInteger(valueOf(numIns));
                if (reqMatrix[i][pos]) sel[i] = Valid(pos);
            end

            Bit#(TLog#(numIns)) s = fromMaybe(?, sel[i]);
            // Empirically, this reduces LUTs, e.g., with 3 inputs, each output
            // mux should be a LUT5 (3 ins + 2 selects), but without this
            // modding, vivado infers LUT6s instead. This is bad, because LUT5s
            // pack better.
            if (!numInsIsPow2) s = s % fromInteger(valueOf(numIns));

            dataOuts[i] <= isValid(sel[i])? Valid(fromMaybe(?, dataIns[fromMaybe(?, sel[i])]).data) : Invalid;
            dynamicAssert(!isValid(sel[i]) || isValid(dataIns[s]), "valid select with invalid dataIn!?");
        end

        selects <= sel;
    endrule
    
    rule setAccepts;
        Vector#(numOuts, Bool) transfers;
        for (Integer i = 0; i < valueOf(numOuts); i = i + 1) begin
            transfers[i] = isValid(selects[i]) && acks[i];
        end

        if (valueOf(numIns) == 1) begin
            // Specialization---with one input, we don't need to do the
            // rigmarole of the general case below.
            accepts[0] <= fold(\|| , transfers);
        end else begin
            for (Integer j = 0; j < valueOf(numIns); j = j + 1) begin
                // NOTE: This is the critical path, so I've simplified it as
                // much as I can. We don't need to check dataIns[j] is valid;
                // the only thing that matters is that we don't mis-propagate
                // an ack because an invalid selects[dest] happens to match,
                // but transfers[i] gates this because it includes the validity
                // of sel. This logic is centralized in a rule insted of done
                // per output to compute transfers[] once, which saves LUTs. 
                let dest = fromMaybe(?, dataIns[j]).dest;
                accepts[j] <= transfers[dest] && (fromMaybe(?, selects[dest]) == fromInteger(j));
            end
        end
    endrule

    Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in_;
    Vector#(numOuts, SendCommit#(data_t)) out_;

    for (Integer j = 0; j < valueOf(numIns); j = j + 1) begin
        in_[j] = interface RecvCommit#(SwitchReq#(numOuts, data_t));
            method Action datain (SwitchReq#(numOuts, data_t) din) = dataIns[j]._write(Valid(din));
            method Bool accept = accepts[j];
        endinterface;
    end

    for (Integer i = 0; i < valueOf(numOuts); i = i + 1) begin
        out_[i] = interface SendCommit#(data_t);
            method data_t dataout if (isValid(dataOuts[i])) = fromMaybe(?, dataOuts[i]);
            method Action ack = acks[i]._write(True);
        endinterface;
    end

    interface in = in_;
    interface out = out_;
endmodule

// NOTE(dsm): This implementation is optimized for performance on the FPGA. If
// you make any changes, make sure they don't hurt implementation quality via
// synthesis and PnR---this 2x2 switch is replicated *EVERYWHERE* in larger
// switches, so minor inefficiencies here compound quickly. For example, this
// used to be composed out of 1x2 and 2x1 switches... which was simpler, but
// added 10-25% LUTs.
instance SwitchClass#(2, 2, data_t) provisos(Bits#(data_t, dataBits));
    module mkBaseSwitch#(Bit#(1) prio)(Switch#(2, 2, data_t));
        // In priority order
        Vector#(2, Wire#(Maybe#(SwitchReq#(2, data_t)))) dataIns <- replicateM(mkDWire(Invalid));
        Vector#(2, Wire#(Maybe#(data_t))) dataOuts <- replicateM(mkBypassWire);
        Wire#(Vector#(2, Bool)) grants <- mkBypassWire;
        Vector#(2, Wire#(Bool)) acks <- replicateM(mkDWire(False));

        rule tick;
            Vector#(2, Bool) g = replicate(False);
            for (Integer o = 0; o < 2; o = o + 1) begin
                Integer p = (o == 0)? 1 : 0;
                Bool oMatches = isValid(dataIns[o]) && fromMaybe(?, dataIns[o]).dest == fromInteger(o);
                Bool pMatches = isValid(dataIns[p]) && fromMaybe(?, dataIns[p]).dest == fromInteger(o);
                Bool pHasPrio = pMatches && (prio == 1);
                if (oMatches && !pHasPrio) begin
                    dataOuts[o] <= Valid(fromMaybe(?, dataIns[o]).data);
                    g[o] = True;
                end else if (pMatches) begin
                    dataOuts[o] <= Valid(fromMaybe(?, dataIns[p]).data);
                    g[p] = True;
                end else dataOuts[o] <= Invalid;
            end
            grants <= g;
        endrule

        Vector#(2, RecvCommit#(SwitchReq#(2, data_t))) in_;
        Vector#(2, SendCommit#(data_t)) out_;

        for (Integer i = 0; i < 2; i = i + 1) begin
            in_[i] = interface RecvCommit#(SwitchReq#(2, data_t));
                method Action datain (SwitchReq#(2, data_t) din) = dataIns[i]._write(Valid(din));
                // NOTE(dsm): Equivalent to isValid(dataIns[i])? acks[fromMaybe(?, dataIns[i]).dest] && grants[i] : False;
                // but cheaper in synthesis; this is because when !isValid(dataIns[i]), grants[i] == False.
                method Bool accept = acks[fromMaybe(?, dataIns[i]).dest] && grants[i];
            endinterface;

            out_[i] = interface SendCommit#(data_t);
                method data_t dataout if (isValid(dataOuts[i])) = fromMaybe(?, dataOuts[i]);
                method Action ack = acks[i]._write(True);
            endinterface;
        end

        interface in = in_;
        interface out = out_;
    endmodule
endinstance

`define USE_CROSSBAR_FOR_INS(N) \
instance SwitchClass#(N, numOuts, data_t) provisos(Bits#(data_t, dataBits), Add#(__a, 1, numOuts)); \
    module mkBaseSwitch#(Bit#(TLog#(N)) prio)(Switch#(N, numOuts, data_t)); \
        Switch#(N, numOuts, data_t) cx <- mkCrossbarSwitch(prio); \
        return cx; \
    endmodule \
endinstance

// For how many numIns should we use a crossbar? Add more defines if needed
// NOTE: Haven't tested beyond 4x4; 5x5, 6x6, etc may make sense too. 8x8 is
// actually not too expensive, but it's slower... may be a good idea to mix and
// match, e.g., if we need more switching throughput.
`USE_CROSSBAR_FOR_INS(1)
`USE_CROSSBAR_FOR_INS(2)
`USE_CROSSBAR_FOR_INS(3)
`USE_CROSSBAR_FOR_INS(4)


// Like truncate, but works when widths are equal as well. This avoids a bunch
// of provisos due to mixing the swizzle and reduction stages
function Bit#(n) trimWidth(Bit#(m) v);
    Bit#(n) res = 0;
    // NOTE: This for loop works with Bit#(0); bit-slicing doesn't
    for (Integer i = 0; i < valueOf(n); i = i + 1) res[i] = v[i];
    return res;
endfunction

function Bit#(n) extendWidth(Bit#(m) v);
    Bit#(n) res = 0;
    // NOTE: This for loop works with Bit#(0); bit-slicing doesn't
    for (Integer i = 0; i < valueOf(m); i = i + 1) res[i] = v[i];
    return res;
endfunction

/* General case: Compose a switch from a first stage of (2x2, 2x1, 1x2)
 * switches, followed by one or two switches with fewer stages.
 */
// TODO: If we use larger radixes, use 4x4 switches in the first stage, which are now better!

// This single instance should be written as two totally different cases: 
// 1. If numOuts <= numIns/2, this is a REDUCTION instance. The first-stage
// switches are all x1 (2x1 or 1x1), and there's a single follow-on switch.
// 2. If numOuts > numIns/2, this is a SWIZZLE instance. The first-stage
// switches are all x2 (1x2 or 2x2), and there are two follow-on switches,
// lower and upper.
//
// The problem is that bluespec typeclasses are not letting me define two
// overlapping instances and disambiguate them with provisos. You can
// special-case numIns or numOuts, and that works, but the moment you have two
// instances that are generic on numIns and numOuts, bsc doesn't even look at
// the provisos. I've tried a bunch of things, including using an extra numeric
// type in the typeclass to be used as a disambiguating tag, but that requires
// leaking that tag to the Switch interface (terrible) or making it dependent
// on the other types (numIns and numOuts) with a dependencies clause. Problem
// is, that approach still results in instance conflicts *even when they have
// different tags!*.
//
// At this point, I'm at my wit's end, so what follows is a kludge: it combines
// BOTH the reduction and swizzle cases in a single instance, while being
// careful with provisos so that we don't drop any dimension down to 0 or get
// into infinite recursion.
instance SwitchClass#(numIns, numOuts, data_t)
    provisos(
        Bits#(data_t, dataBits), 
        Max#(numIns, numOuts, n), // max dimension; log2(n) is the number of stages
        Max#(n, 3, n), // leave out the base cases (2x2, 2x1, 1x2, 1x2)
        Add#(__a, 1, numIns), Add#(__b, 1, numOuts), // both dims must be at least 1

        // Number of first-stage switches: numIns = 2*num2x + num1x
        NumAlias#(TDiv#(TSub#(numIns, 1), 2), num2x),
        Add#(TMul#(num2x, 2), num1x, numIns),
        Add#(num2x, num1x, m),

        // Reduction-stage-specific provisos
        SwitchClass#(m, numOuts, data_t), // geometry of follow-on switch

        // Swizzle-stage-specific provisos
        
        // Option 1: Balanced case (e.g. 10x10 would result in lower, upper being 5x5)
        // NOTE(dsm): This option is *very likely wrong* due to addressing
        // issues: 10 outputs have range 0000-1010; a 5x5 + 5x5 division must
        // map [0000-0100] -> [0,[000-100]] + [0101-1010] -> [1,[000-100]],
        // but no such transformation is happening below! With bit-selection
        // addressing, lower must be the closest smaller power of two, and
        // upper must cover the remainder, i.e., the imbalanced option below.
        //NumAlias#(TDiv#(TSub#(numOuts, 1), 2), upperOuts_), // upperOuts_ == 0 when numOuts == 1
        //Max#(upperOuts_, 1, upperOuts), // so we make it nonzero to avoid recursing down to 0
        //Add#(lowerOuts, upperOuts_, numOuts), // lowerOuts may not be 0, note we use upperOuts_
        
        // Option 2: Imbalanced case (e.g. 10x10 would result in 8x8 lower, 2x2 upper)
        NumAlias#(TExp#(TSub#(TMax#(TLog#(numOuts), 1), 1)), lowerOuts), // closest power of 2 smaller than numOuts, or 1 if numOuts is 1
        Add#(lowerOuts, upperOuts_, numOuts), // upperOuts_ is 0 when numOuts is 1
        Max#(upperOuts_, 1, upperOuts), // so we make it nonzero to avoid recursing down to 0
        
        SwitchClass#(m, lowerOuts, data_t),
        SwitchClass#(m, upperOuts, data_t),
        Add#(numOuts, a__, TAdd#(lowerOuts, upperOuts)) // bsc babysitting
    );

    module mkBaseSwitch#(Bit#(TLog#(numIns)) prio)(Switch#(numIns, numOuts, data_t));
        module mkReductionSwitch#(Bit#(TLog#(numIns)) prio)(Switch#(numIns, numOuts, data_t));
            Switch#(m, numOuts, data_t) next <- mkBaseSwitch(trimWidth(prio));

            Vector#(num2x, Switch#(2, 1, SwitchReq#(numOuts, data_t))) s2x1 <- replicateM(mkBaseSwitch(prio[valueOf(TLog#(numIns))-1]));
            Vector#(num1x, Switch#(1, 1, SwitchReq#(numOuts, data_t))) s1x1 <- replicateM(mkBaseSwitch(0)); // 0 or 1

            // Flatten first-stage switch interfaces
            Vector#(numIns, RecvCommit#(SwitchReq#(1, SwitchReq#(numOuts, data_t)))) sIn_ =
                append(concat(map(getIns, s2x1)), concat(map(getIns, s1x1)));
            Vector#(m, SendCommit#(SwitchReq#(numOuts, data_t))) sOut_ =
                append(concat(map(getOuts, s2x1)), concat(map(getOuts, s1x1)));

            // Wrap first-stage inputs
            Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in_;
            for (Integer i = 0; i < valueOf(numIns); i = i + 1) begin
                in_[i] = interface RecvCommit#(SwitchReq#(numOuts, data_t));
                method Action datain (SwitchReq#(numOuts, data_t) din) = 
                        sIn_[i].datain(SwitchReq{dest: 0, data: SwitchReq{dest: trimWidth(din.dest), data: din.data}}); // note dest is 0 bits
                    method Bool accept = sIn_[i].accept;
                endinterface;
            end

            // Connect first-stage outputs with next
            zipWithM_(mkConnection, sOut_, next.in);

            interface in = in_;
            interface out = next.out;
        endmodule

        module mkSwizzleSwitch#(Bit#(TLog#(numIns)) prio)(Switch#(numIns, numOuts, data_t));
            Switch#(m, lowerOuts, data_t) lower <- mkBaseSwitch(trimWidth(prio));
            Switch#(m, upperOuts, data_t) upper <- mkBaseSwitch(trimWidth(prio));

            Vector#(num2x, Switch#(2, 2, SwitchReq#(TDiv#(numOuts, 2), data_t))) s2x2 <- replicateM(mkBaseSwitch(prio[valueOf(TLog#(numIns))-1]));
            Vector#(num1x, Switch#(1, 2, SwitchReq#(TDiv#(numOuts, 2), data_t))) s1x2 <- replicateM(mkBaseSwitch(0)); // 0 or 1

            // Flatten first-stage switch interfaces
            Vector#(numIns, RecvCommit#(SwitchReq#(2, SwitchReq#(TDiv#(numOuts, 2), data_t)))) sIn_ =
                append(concat(map(getIns, s2x2)), concat(map(getIns, s1x2)));
            Vector#(TMul#(m, 2), SendCommit#(SwitchReq#(TDiv#(numOuts, 2), data_t))) sOut_ =
                append(concat(map(getOuts, s2x2)), concat(map(getOuts, s1x2)));

            // Wrap first-stage inputs
            Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in_;
            for (Integer i = 0; i < valueOf(numIns); i = i + 1) begin
                in_[i] = interface RecvCommit#(SwitchReq#(numOuts, data_t));
                method Action datain(SwitchReq#(numOuts, data_t) din) = 
                        sIn_[i].datain(SwitchReq{dest: din.dest[valueOf(TLog#(numOuts))-1], 
                            data: SwitchReq{dest: trimWidth(din.dest), data: din.data}});
                    method Bool accept = sIn_[i].accept;
                endinterface;
            end

            // Connect first-stage outputs with follow-on switches. Note this
            // is not just a trivial mkConnection, because lower and upper may
            // take a different number of destination bits---so we truncate
            // differently for each!
            Vector#(m, RecvCommit#(SwitchReq#(TDiv#(numOuts, 2), data_t))) lIn_;
            for (Integer i = 0; i < valueOf(m); i = i + 1) begin
                lIn_[i] = interface RecvCommit#(SwitchReq#(TDiv#(numOuts, 2), data_t));
                    method Action datain(SwitchReq#(TDiv#(numOuts, 2), data_t) din) = 
                        lower.in[i].datain(SwitchReq{dest: trimWidth(din.dest), data: din.data});
                    method Bool accept = lower.in[i].accept;
                endinterface;
                mkConnection(sOut_[2*i], lIn_[i]);
            end

            Vector#(m, RecvCommit#(SwitchReq#(TDiv#(numOuts, 2), data_t))) uIn_;
            for (Integer i = 0; i < valueOf(m); i = i + 1) begin
                uIn_[i] = interface RecvCommit#(SwitchReq#(TDiv#(numOuts, 2), data_t));
                    method Action datain(SwitchReq#(TDiv#(numOuts, 2), data_t) din) = 
                        upper.in[i].datain(SwitchReq{dest: trimWidth(din.dest), data: din.data});
                    method Bool accept = upper.in[i].accept;
                endinterface;
                mkConnection(sOut_[2*i + 1], uIn_[i]);
            end

            interface in = in_;

            // NOTE: we need take() because when numOuts == 1, lowerOuts +
            // upperOuts > numOuts. This doesn't matter since when numOuts == 1
            // this is ALWAYS a reduction stage, but the compiler needs widths
            // to match in all cases.
            interface out = take(append(lower.out, upper.out));
        endmodule

        (* hide *)
        Switch#(numIns, numOuts, data_t) s <- (2*valueOf(numOuts) <= valueOf(numIns))? mkReductionSwitch(prio) : mkSwizzleSwitch(prio);
        return s;
    endmodule
endinstance

module mkSwitch(Switch#(numIns, numOuts, data_t)) provisos(Bits#(data_t, dataBits), SwitchClass#(numIns, numOuts, data_t));
    Reg#(Bit#(TLog#(numIns))) prio <- mkReg(0);
    Switch#(numIns, numOuts, data_t) s <- mkBaseSwitch(prio);

    LFSR#(Bit#(6)) lfsr <- mkFeedLFSR(6'b100101);
    rule tick;
        prio <= prio + extendWidth(lfsr.value()[0]);
        lfsr.next;
    endrule

    return s;
endmodule

module mkBackpressuredSwitch(Switch#(numIns, numOuts, data_t)) provisos(Bits#(data_t, dataBits), SwitchClass#(numIns, numOuts, data_t));
    Switch#(numIns, numOuts, data_t) s <- mkSwitch;

    Vector#(numIns, Wire#(Maybe#(SwitchReq#(numOuts, data_t)))) dataIns <- replicateM(mkDWire(Invalid));
    Vector#(numOuts, Wire#(Bool)) acks <- replicateM(mkDWire(False));
    Vector#(numIns, Wire#(Bool)) passedIns <- replicateM(mkDWire(False));

    Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in_;
    for (Integer i = 0; i < valueOf(numIns); i = i + 1) begin
        in_[i] = interface RecvCommit#(SwitchReq#(numOuts, data_t));
            method Action datain(SwitchReq#(numOuts, data_t) din) = dataIns[i]._write(Valid(din));
            method Bool accept = s.in[i].accept && passedIns[i];
        endinterface;

        rule feedSwitch if (dataIns[i] matches tagged Valid .din);
            if (acks[din.dest]) begin
                s.in[i].datain(din);
                passedIns[i] <= True;
            end
        endrule
    end

    Vector#(numOuts, SendCommit#(data_t)) out_;
    for (Integer o = 0; o < valueOf(numOuts); o = o + 1) begin
        out_[o] = interface SendCommit#(data_t);
            method data_t dataout = s.out[o].dataout;
            method Action ack = acks[o]._write(True);
        endinterface;

        rule feedSwitchAck; // if (acks[o]); // not needed, since we're gating inputs with acks anyway
            s.out[o].ack;
        endrule
    end

    interface in = in_;
    interface out = out_;
endmodule

/* Buffering adapters */ 

module mkInputBufferedSwitch#(Switch#(numIns, numOuts, data_t) s, function module#(FIFOF#(SwitchReq#(numOuts, data_t))) genBuf)
        (Switch#(numIns, numOuts, data_t)) provisos(Bits#(data_t, dataBits), SwitchClass#(numIns, numOuts, data_t));
    
    Vector#(numIns, FIFOF#(SwitchReq#(numOuts, data_t))) inQs <- replicateM(genBuf);
    Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) inQs_in <- mapM(mkRecvCommit, inQs);
    Vector#(numIns, SendCommit#(SwitchReq#(numOuts, data_t))) inQs_out <- mapM(mkSendCommit, inQs);
    
    zipWithM_(mkConnection, inQs_out, s.in);
    
    interface in = inQs_in;
    interface out = s.out;
endmodule

module mkOutputBufferedSwitch#(Switch#(numIns, numOuts, data_t) s, function module#(FIFOF#(data_t)) genBuf)
        (Switch#(numIns, numOuts, data_t)) provisos(Bits#(data_t, dataBits), SwitchClass#(numIns, numOuts, data_t));
    
    Vector#(numOuts, FIFOF#(data_t)) outQs <- replicateM(genBuf);
    Vector#(numOuts, RecvCommit#(data_t)) outQs_in <- mapM(mkRecvCommit, outQs);
    Vector#(numOuts, SendCommit#(data_t)) outQs_out <- mapM(mkSendCommit, outQs);
    
    zipWithM_(mkConnection, s.out, outQs_in);
    
    interface in = s.in;
    interface out = outQs_out;
endmodule

// Produces a 2-stage switch. In the FPGA, this is needed when going above
// 8--16 outputs, to close at 400MHz. Putting switches in the middle can also
// help increase throughput.
// This diverges over the prior mkXXXSwitch functions in that it doesn't take a
// base switch. In practice, we're not going to need >2 stages, we'd need 4
// different switch generator functions, and the parameters would get messy.
// This just takes a Bool to express whether we want a backpressured
// combinational switch or not.
// This buffers at middle or slightly over, i.e., it's heavier on the earlier stages
module mkMiddleBufferedSwitch#(Bool backpressureBeforeBuffer, function module#(FIFOF#(SwitchReq#(d1, data_t))) genBuf, Bool backpressureAfterBuffer)(Switch#(numIns, numOuts, data_t)) provisos(
        Bits#(data_t, dataBits),
        Max#(numIns, numOuts, n),
        NumAlias#(TLog#(n), k), // k =total number stages
        NumAlias#(TDiv#(k, 2), k1), // k1 = stages on the left side (early ones)
        Add#(k1, k2, k), // k2 = stages on the right side
        NumAlias#(TExp#(k1), f), // nominal left side INPUT radix
        NumAlias#(TExp#(k2), g), // nominal right side OUTPUT radix
        
        // We build the switch as (a x b) * c | b * (c * d) switches, i.e.,
        // c a-input b-output switches on the left side, and b c-input d-output
        // switches on the right side. Note how b and c are on both sides, this
        // is a basic principle of butterflies. The key parameter here is B: if
        // we have numOuts, we need b = ceil(numOuts / g), because we need to
        // leave k2 bits of the destination to the right stage. From this, all
        // other parameters follow.
        NumAlias#(TDiv#(numOuts, g), b),
        NumAlias#(TDiv#(numIns, f), c),

        // OK, now for a and d: These are not quite constant, but need some
        // slop to cover arbitrary numIns and numOuts. For example, 12x1 is 
        // (4x1)x3 | 1x(3x1); but for 10x1, we need (4x1)x2 + (2x1)x1 | 1x(3x1),
        // i.e., 2 4-input switches and 1 2-input switch. IN GENERAL, we have:
        // (a1 x b) * c1 + (a2 x b) * c2 | b1 * (c x d1) + b2 * (c x d2)
        NumAlias#(f, a1),
        NumAlias#(TSub#(TMul#(a1, c), numIns), xc2_), // 0 if c2 == 0, != 0 if c2 == 1
        Min#(xc2_, 1, c2),
        Add#(c1, c2, c),
        NumAlias#(TSub#(numIns, TMul#(a1, c1)), a2_),
        Max#(a2_, 1, a2), // since we don't want switch ins/outs to fall to 0; if a2_ is 0, c2 is 0

        NumAlias#(g, d1),
        NumAlias#(TSub#(TMul#(d1, b), numOuts), xb2_),
        Min#(xb2_, 1, b2),
        Add#(b1, b2, b),
        NumAlias#(TSub#(numOuts, TMul#(d1, b1)), d2_),
        Max#(d2_, 1, d2), // since we don't want switch ins/outs to fall to 0; if d2_ is 0, b2 is 0

        SwitchClass#(a1, b, SwitchReq#(d1, data_t)),
        SwitchClass#(a2, b, SwitchReq#(d1, data_t)),
        SwitchClass#(c, d1, data_t),
        SwitchClass#(c, d2, data_t)
    );

    Vector#(c1, Switch#(a1, b, SwitchReq#(d1, data_t))) left1unbuffered <- replicateM(backpressureBeforeBuffer? mkBackpressuredSwitch : mkSwitch);
    Vector#(c1, Switch#(a1, b, SwitchReq#(d1, data_t))) left1 <- zipWithM(mkOutputBufferedSwitch, left1unbuffered, replicate(genBuf));

    Vector#(c2, Switch#(a2, b, SwitchReq#(d1, data_t))) left2unbuffered <- replicateM(backpressureBeforeBuffer? mkBackpressuredSwitch : mkSwitch);
    Vector#(c2, Switch#(a2, b, SwitchReq#(d1, data_t))) left2 <- zipWithM(mkOutputBufferedSwitch, left2unbuffered, replicate(genBuf));

    Vector#(b1, Switch#(c, d1, data_t)) right1 <- replicateM(backpressureAfterBuffer? mkBackpressuredSwitch : mkSwitch);
    Vector#(b2, Switch#(c, d2, data_t)) right2 <- replicateM(backpressureAfterBuffer? mkBackpressuredSwitch : mkSwitch);

    // Wrap switch inputs, use them to drive left-stage inputs
    let leftIn = append(concat(map(getIns, left1)), concat(map(getIns, left2)));
    Vector#(numIns, RecvCommit#(SwitchReq#(numOuts, data_t))) in_;
    for (Integer i = 0; i < valueOf(numIns); i = i + 1) begin
        in_[i] = interface RecvCommit#(SwitchReq#(numOuts, data_t));
            method Action datain (SwitchReq#(numOuts, data_t) din) = leftIn[i].datain(SwitchReq{
                dest: trimWidth(din.dest >> valueOf(k2)), 
                data: SwitchReq{dest: trimWidth(din.dest), data: din.data}
            });
            method Bool accept = leftIn[i].accept;
        endinterface;
    end

    // Connect first-stage outputs to second-stage inputs
    Vector#(c, Vector#(b, SendCommit#(SwitchReq#(d1, data_t)))) leftOuts = append(map(getOuts, left1), map(getOuts, left2));
    for (Integer i = 0; i < valueOf(c); i = i + 1) begin
        for (Integer j = 0; j < valueOf(b1); j = j + 1)
            mkConnection(leftOuts[i][j], right1[j].in[i]);

        // The last output switch is not so easy, because it has d2 outputs,
        // not d1, so we may need to trim it. We do this in a for loop, since
        // b2 can be 0 or 1
        for (Integer j = 0; j < valueOf(b2); j = j + 1) begin
            let r2in_ = interface RecvCommit#(SwitchReq#(d1, data_t));
                method Action datain(SwitchReq#(d1, data_t) din) =
                    right2[j].in[i].datain(SwitchReq{dest: trimWidth(din.dest), data: din.data});
                method Bool accept = right2[j].in[i].accept;
            endinterface;
            mkConnection(leftOuts[i][j + valueOf(b1)], r2in_);
        end
    end

    interface in = in_;
    interface out = append(concat(map(getOuts, right1)), concat(map(getOuts, right2)));
endmodule

/* Test */

import Assert::*;
import Randomizable::*;

typedef 40 NI;
typedef 40 NO;
typedef TLog#(NI) KI;
typedef TLog#(NO) KO;

module mkTestSwitch();
    Reg#(Bit#(20)) cycle <- mkReg(0);
    //Switch#(NI, NO, Tuple2#(Bit#(KI), Bit#(KO))) switch <- mkSwitch;
    Switch#(NI, NO, Tuple2#(Bit#(KI), Bit#(KO))) switch <- mkMiddleBufferedSwitch(True, mkSizedFIFOF(16), True);

    Randomize#(Bit#(TMul#(NI, 16))) random <- mkGenericRandomizer;
    Wire#(Vector#(NI, Bit#(KO))) rndDests <- mkWire;
    
    rule initRnd if (cycle == 0);
        random.cntrl.init();
    endrule
    
    rule setRndDests;
        let rv <- random.next;
        Vector#(NI, Bit#(16)) rvv = unpack(rv);
        Vector#(NI, Bit#(KO)) rvd;
        for (Integer i = 0; i < valueOf(NI); i = i + 1)
            rvd[i] = truncate(rvv[i] % fromInteger(valueOf(NO)));
        rndDests <= rvd;
    endrule
    
    Vector#(NI, Reg#(Bit#(32))) srcSends <- replicateM(mkReg(0));
    Vector#(NI, Reg#(Bit#(32))) srcBlocks <- replicateM(mkReg(0));

    Vector#(NO, Vector#(NI, Reg#(Bit#(32)))) dstRecvs <- replicateM(replicateM(mkReg(0)));
 

    for (Integer i = 0; i < valueOf(NI); i = i + 1) begin
        // Send side
        Wire#(Bool) sent <- mkDWire(False);
        rule send if (cycle >= 1024 && (cycle + 128 > cycle)); //&& cycle % 8 == fromInteger(i));
            Bit#(KO) dest = rndDests[i];
            switch.in[i].datain(SwitchReq{dest: dest, data: tuple2(fromInteger(i), dest)});
            sent <= True;
        endrule

        rule countSend if (switch.in[i].accept && sent);
            srcSends[i] <= srcSends[i] + 1;
        endrule
    end
        
    for (Integer j = 0; j < valueOf(NO); j = j + 1) begin
        // Receive side
        rule ack;
            switch.out[j].ack;
        endrule

        rule receive;
            let data = switch.out[j].dataout;
            Bit#(KI) src = tpl_1(data);
            Bit#(KO) dest = tpl_2(data);
            if (dest != fromInteger(j)) begin
                $display("FAILED: Switch does not send data to the right destination, cycle=%d src=%d reqDest=%d actualDest=%d", cycle, src, dest, j);
                $finish;
            end
            dstRecvs[j][src] <= dstRecvs[j][src] + 1;
        endrule
    end

    rule tick;
        cycle <= cycle + 1;
    endrule

    rule last if (cycle == ~0);
        // If the switch is fair, you should see a reasonably uniform distribution of sends and receives by src/dst
        // The send vs send block tells you the injection rate that can be achieved at this radix
        // This should be close to the theoretical bound, e.g. 75/61/51/45% for radix 2/4/8/16
        $display("Simulation done");
        $display("Sends:        ", fshow(map(readReg, srcSends)));
        Bit#(40) recvs = 0;
        for (Integer j = 0; j < valueOf(NO); j = j + 1) begin
            $display("Recvs[%d]    :  ", j, fshow(map(readReg, dstRecvs[j])));
            recvs = recvs + zeroExtend(fold(add, map(readReg, dstRecvs[j])));
        end
        Bit#(40) sends = zeroExtend(fold(add, map(readReg, srcSends)));
        Bit#(40) blocks = fromInteger(((2 ** 20) - 1024 - 128) * valueOf(NI)) - sends;
        
        if (sends != recvs) begin
            $display("FAILED: sends (%1d) !=  recvs (%1d)", sends, recvs);
            $finish;
        end
        
        // Poor man's floating point :)
        $display("Injection rate: %3d.%1d %%", 100 * sends / (sends + blocks), (10 * sends / (sends + blocks)) % 10);
        $display("PASSED");
        $finish;
    endrule
endmodule
