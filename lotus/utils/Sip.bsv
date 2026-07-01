/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

/* BSV implementations of SIP components. See the documentation of these in sip.sv.
 *
 * NOTE(dsm): SIP is a serial protocol where timing matters (e.g., a dead cycle
 * ion the wire ends a flit), and Bluespec is all about latency-insensitive
 * design, so this code must obey some restrictions to ensure correctness an
 * our sanity.
 *
 * Specifically:
 *  - All SIP req/resp methods MUST be called every cycle.
 *  - All rules that deal with SIP req/resp MUST fire every cycle, and MUST be
 *    annotated to ensure so (no implicit conditions, fire when enabled, adn no
 *    explicit guard).
 *  - To avoid combinational cycles, all endpoints can use a single SIP rule
 *    and BypassWires for req and resp (so the order is req -> rule -> resp), and
 *    all transport layer components MUST handle the request and response paths
 *    in separate rules (so the order is srcReq -> reqRule -> dstReqs ->
 *    (other transport and endpoint rules) -> dstResps -> respRule -> srcResp)
 *  - If you follow these conventions, you get similar compositional guarantees
 *    as base Minispec: you can think of rules firing outside in through the SIP
 *    hierarchy, starting at the root req and ending a the root resp.
 */

import Assert::*;
import Connectable::*;
import Vector::*;

import FunctionalUtils::*;
import NonBlockingPipe::*;
import XRegFile::*;

// Uncomment to enable debugging
//`define SIP_TRACE
//`define SIP_DEBUG

/* 0. INTERFACE DEFINITIONS: For generic components, endpoints, and transport layer components */

//// Base SIP types and interfaces

typedef 8                 SIPDataBits;
typedef Bit#(SIPDataBits) SIPData;
typedef Maybe#(SIPData)   SIPFlit;

interface SIP;
    (* always_enabled, always_ready *)
    (* prefix = "" *) method Action  req((* port = "req" *) SIPFlit f);
    (* always_enabled, always_ready *)
    method SIPFlit resp;
endinterface

interface SIPSource;
    (* always_enabled, always_ready *)
    (* result = "sReq" *) method SIPFlit req;
    (* always_enabled, always_ready *)
    (* prefix = "" *) method Action  resp((* port = "sResp" *) SIPFlit f);
endinterface

instance Connectable#(SIPSource, SIP);
    module mkConnection#(SIPSource source, SIP target)(Empty);
        rule connectReq;
            target.req(source.req);
        endrule
        rule connectResp;
            source.resp(target.resp);
        endrule
    endmodule
endinstance

instance Connectable#(SIP, SIPSource);
    module mkConnection#(SIP target, SIPSource source)(Empty);
        mkConnection(source, target);
    endmodule
endinstance

//// Endpoints

// Control registers are written by SIP, and read by the design
interface SIPControlRegs#(numeric type numRegs, type data_t);
    interface SIP sip;

    method Vector#(numRegs, data_t) regs;
    method Vector#(numRegs, Bool) regsUpdated;
endinterface

// Status registers are written by the design, read by SIP. They do not have a
// separate interface; mkSIPStatusRegs is just SIP. 

// Counters take a vector of increment values, and implement counters read by SIP.
typedef SIP SIPCounters#(numeric type counterBits);

//// Transport layer

// NOTE: All of these components are minimally restricted in parameter ranges:
// numDests needs to be between 1 and 256, but that's about it. So, for
// example, it's possible to have a 1-to-1 mux or splitter, and it's possible
// to have a 256-output splitter with addrBits = 0.

// Mux peels the first address component, interprets it as a destination
interface SIPMux#(numeric type numDests);
    interface SIP                          sipFromSource;
    interface Vector#(numDests, SIPSource) sipToTargets;
endinterface

// Splitter takes the first address component, uses the bits past addrBits to
// select the destination, and passes an address with only the lower addrBits.
interface SIPSplitter#(numeric type numDests, numeric type addrBits);
    interface SIP                          sipFromSource;
    interface Vector#(numDests, SIPSource) sipToTargets;
endinterface

// n-stage pipeline on requests and responses
interface SIPPipe#(numeric type n);
    interface SIP       sipIn;
    interface SIPSource sipOut;
endinterface

interface SIPAutoPipe;
    interface SIP       sipIn;
    interface SIPSource sipOut;
endinterface

// Enable connecting pipes to sources and targets without grabbing sipIn/sipOut
instance Connectable#(SIPPipe#(n), SIPSource);
    module mkConnection#(SIPPipe#(n) target, SIPSource source)(Empty);
        mkConnection(source, target.sipIn);
    endmodule
endinstance

instance Connectable#(SIPPipe#(n), SIP);
    module mkConnection#(SIPPipe#(n) source, SIP target)(Empty);
        mkConnection(source.sipOut, target);
    endmodule
endinstance

instance Connectable#(SIPSource, SIPPipe#(n));
    module mkConnection#(SIPSource source, SIPPipe#(n) target)(Empty);
        mkConnection(source, target.sipIn);
    endmodule
endinstance

instance Connectable#(SIP, SIPPipe#(n));
    module mkConnection#(SIP target, SIPPipe#(n) source)(Empty);
        mkConnection(source.sipOut, target);
    endmodule
endinstance

//////////////////

// Cast a Bit#(m) to a Bit#(n), for arbitrary n, m values. This is equivalent
// to the SystemVerilog width-casting operator (n'(v)). It zeroExtends or
// truncates m-bit v as needed to get to n bits.
// 
// NOTE(dsm): Use this only when zeroExtend or truncate are cumbersome! For
// example, when using them complicates the provisos of a parametric module,
// and you end up writing cumbersome bit-slicing expressions instead..
function Bit#(n) castWidth(Bit#(m) v);
    Bit#(n) res = 0;
    // NOTE: This for loop works with Bit#(0); bit-slicing doesn't
    for (Integer i = 0; i < valueOf(TMin#(n, m)); i = i + 1) res[i] = v[i];
    return res;
endfunction


/* 1. BASIC COMPONENTS */

interface SIPDeserializer#(type value_t);
    interface SIP sip;
    method Maybe#(value_t) value;
endinterface

module mkSIPDeserializer(SIPDeserializer#(value_t))
    provisos(Bits#(value_t, valueBits), Div#(valueBits, SIPDataBits, numBeats), Log#(numBeats, numBeatsBits));

    Reg#(Bit#(numBeatsBits)) curBeat <- mkReg(0);
    Vector#(numBeats, Reg#(SIPData)) valueVec <- replicateM(mkRegU);
    Reg#(Bool) prevValid <- mkReg(False);

    Wire#(SIPFlit) curReq <- mkBypassWire;
    Wire#(SIPFlit) curResp <- mkBypassWire;

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick;
        if (curReq matches tagged Valid .r) begin
            //$display("Writing ", fshow(r), " in pos ", fshow(curBeat));
            valueVec[curBeat] <= r;
            curBeat <= curBeat + 1;
        end else if (prevValid) curBeat <= 0; // uses reset to reduce LUTs
        prevValid <= isValid(curReq);

        Bit#(4) ackVal = castWidth(curBeat);
        curResp <= (!isValid(curReq) && prevValid)? Valid({4'h1, ackVal}) : Invalid;
    endrule

    interface SIP sip;
        method Action req(SIPFlit fm) = curReq._write(fm);
        method SIPFlit resp = curResp;
    endinterface

    method Maybe#(value_t) value = (!isValid(curReq) && prevValid)? Valid(unpack(castWidth(pack(map(readReg, valueVec))))) : Invalid;
endmodule


interface SIPSerializer#(type value_t);
    method Action send(value_t v);
    method SIPFlit resp;
endinterface

module mkSIPSerializer(SIPSerializer#(value_t))
    provisos(Bits#(value_t, valueBits), Div#(valueBits, SIPDataBits, numBeats), Log#(numBeats, numBeatsBits));

    Reg#(value_t) captured <- mkRegU;
    Reg#(Maybe#(Bit#(numBeatsBits))) curBeatM <- mkReg(tagged Invalid);

    Wire#(Maybe#(value_t)) sendIn <- mkDWire(Invalid);
    Wire#(SIPFlit) curResp <- mkBypassWire;

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick;
        if (sendIn matches tagged Valid .v) begin
            captured <= v;
            curBeatM <= Valid(0);
        end else if (curBeatM matches tagged Valid .curBeat) begin
            curBeatM <= (curBeat == fromInteger(valueOf(numBeats)-1))? Invalid : Valid(curBeat + 1);
        end

        if (curBeatM matches tagged Valid .curBeat) begin
            Vector#(numBeats, SIPData) capturedVec = unpack(castWidth(pack(captured)));
            curResp <= Valid(capturedVec[curBeat]);
        end else curResp <= Invalid;
    endrule

    method Action send(value_t v) = sendIn._write(Valid(v));
    method SIPFlit resp = curResp;
endmodule


// Peels off the first flit of the request, interpreting it as an address.
// Checks for both too-short requests (address only, no data) and out-of-bounds
// addresses, and filters out the request in either case, replying with a NACK.
interface SIPAddrPeeler#(numeric type numAddrs);
    interface SIP sipIn;
    interface SIPSource sipOut;
    method Bit#(TLog#(numAddrs)) addr;
    method Bool addrUpdated;
endinterface

// We have two variants of this module:
// - MultiFlitReq expects requests to have multiple flits, so that when we
//   peel the address, there's still a req left downstream. These are used
//   either in the transport layer (e.g., muxes) or as endpoints for write
//   requests (where the write data follows the address). This mode checks
//   that more flits follow or throws an error.
// - SingleFlitReq expects requests to have a single flit, so no req is left
//   after peeling. These are used by read endpoints. This mode does not check
//   for too-short requests. Normally, addrUpdated should be useful mainly for
//   this case (since sipOut.req goes nowhere).
typedef enum {MultiFlitReq, SingleFlitReq} SIPAddrPeelerType deriving (Eq, FShow);

module mkSIPAddrPeeler#(SIPAddrPeelerType peelerType)(SIPAddrPeeler#(numAddrs))
    provisos (
        Add#(numAddrs, a__, 256), 
        Add#(b__, 1, numAddrs), 
        Alias#(Bit#(TLog#(numAddrs)), addr_t)
    );

    // NOTE: This address is often used as a select, and don't cares introduce
    // x-unsafe behavior in selects (e.g., output is x even if all choices are
    // Invalid). So, initialize it.
    // TODO: Check whether we can optimize this.
    Reg#(addr_t) addrReg <- mkReg(unpack(0));
    Reg#(Bool) prevValid <- mkReg(False);
    Reg#(Bool) prevPrevValid <- mkReg(False);
    Reg#(Bool) passReq <- mkReg(False);

    // Requests and responses in logical order
    Wire#(SIPFlit) srcReq <- mkBypassWire;
    Wire#(SIPFlit) dstReq <- mkBypassWire;
    Wire#(SIPFlit) dstResp <- mkBypassWire;
    Wire#(SIPFlit) srcResp <- mkBypassWire;

    (* no_implicit_conditions, fire_when_enabled *)
    rule processReq;
        dstReq <= passReq? srcReq : Invalid;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule processResp;
        prevValid <= isValid(srcReq);
        prevPrevValid <= prevValid;
        Bool tooShortReq = (peelerType == MultiFlitReq) && !isValid(srcReq) && prevValid && !prevPrevValid;
        Bool outOfBounds = isValid(srcReq) && !prevValid && (fromMaybe(?, srcReq) > fromInteger(valueOf(numAddrs)-1));
        // NOTE: tooShortReq and outOfBounds happen in separate cycles, but
        // they are in *consecutive* cycles, so if BOTH mistakes happen, we'll
        // return a 2-byte NACK. Still a single reply!
        srcResp <= tooShortReq? Valid(8'hCC /* error resp */) : outOfBounds? Valid(8'hFF /* error resp */) : dstResp;
        if (isValid(srcReq) && !prevValid) begin
            addrReg <= castWidth(fromMaybe(?, srcReq));
            // Nix out of bounds requests
            passReq <= !outOfBounds;
        end else if (!isValid(srcReq)) passReq <= False;
    endrule

    interface SIP sipIn;
        method Action req(SIPFlit f) = srcReq._write(f);
        method SIPFlit resp = srcResp;
    endinterface

    interface SIPSource sipOut;
        method SIPFlit req = dstReq;
        method Action resp(SIPFlit f) = dstResp._write(f);
    endinterface

    method addr_t addr = addrReg;
    method Bool addrUpdated = prevValid && !prevPrevValid && passReq;
endmodule


// NOTE(dsm): Not in SV version, but useful!
interface SIPEndpointWriter#(numeric type numAddrs, type value_t);
    interface SIP sip;
    method Maybe#(Tuple2#(Bit#(TLog#(numAddrs)), value_t)) writeReq;
endinterface

module mkSIPEndpointWriter(SIPEndpointWriter#(numAddrs, value_t))
    provisos(
        Bits#(value_t, valueBits),
        Add#(numAddrs, a__, 256),
        Add#(b__, 1, numAddrs),
        Alias#(Bit#(TLog#(numAddrs)), addr_t)   
    );

    SIPAddrPeeler#(numAddrs) addrPeeler <- mkSIPAddrPeeler(MultiFlitReq);
    SIPDeserializer#(value_t) deserializer <- mkSIPDeserializer;

    mkConnection(addrPeeler.sipOut, deserializer.sip);

    interface SIP sip = addrPeeler.sipIn;

    method Maybe#(Tuple2#(addr_t, value_t)) writeReq;
        if (deserializer.value matches tagged Valid .v) return Valid(tuple2(addrPeeler.addr, v));
        else return Invalid;
    endmethod
endmodule

// Debugging
interface SIPDebugger;
    interface SIP       sipIn;
    interface SIPSource sipOut;
endinterface

module mkSIPDebugger#(Fmt name)(SIPDebugger);

    Wire#(SIPFlit) reqWire <- mkDWire(tagged Invalid);
    Wire#(SIPFlit) rspWire <- mkDWire(tagged Invalid);

    interface SIP sipIn;
        method Action           req(SIPFlit f);
`ifdef SIP_TRACE
            if (f matches tagged Valid .ff) 
                $display($time, ":  [", name, "] SIP-Request <= ", fshow(ff));
`endif
            reqWire <= f;
        endmethod
        method SIPFlit  resp = rspWire;
    endinterface

    interface SIPSource sipOut;
        method SIPFlit  req = reqWire;
        method Action           resp(SIPFlit f);
`ifdef SIP_TRACE
            if (f matches tagged Valid .ff) 
                $display($time, ":  [", name, "] SIP-Response <= ", fshow(ff));
`endif
            rspWire <= f;
        endmethod
    endinterface

endmodule
module sipDebuggerExtractIn#(SIPDebugger d)(SIP);
    return d.sipIn;
endmodule
module sipDebuggerExtractOut#(SIPDebugger d)(SIPSource);
    return d.sipOut;
endmodule

/* 2. SLAVE ENDPOINTS */

module mkSIPControlRegs#(Fmt name)(SIPControlRegs#(numRegs, data_t))
    provisos(Add#(a__, 1, numRegs), Add#(numRegs, b__, 256), Bits#(data_t, dataBits));
    
    Fmt useName = name + $format("-SIPControlReg");
    SIPDebugger sipDebug <- mkSIPDebugger(useName);
    SIPEndpointWriter#(numRegs, data_t) point <- mkSIPEndpointWriter;
    mkConnection(sipDebug.sipOut, point.sip);
    
    Vector#(numRegs, Reg#(data_t)) regs_ <- replicateM(mkReg(unpack(0)));
    
    // NOTE(dsm): Produces better code than indexing...
    Reg#(Bit#(numRegs)) regsUpdated_ <- mkReg(0);

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick; 
        if (point.writeReq matches tagged Valid {.addr, .val}) begin
            dynamicAssert(addr <= fromInteger(valueOf(numRegs)-1), "readAddr has to be less than numRegs");
            regs_[addr] <= val;
            regsUpdated_ <= 1 << addr;
`ifdef SIP_DEBUG
            $display($time, ":  [", useName, "] UPDATE -- BEFORE=", fshow(map(pack, regs_)), " addr=", fshow(addr), " val=", fshow(pack(val)));
`endif
        end else begin
            regsUpdated_ <= 0;
        end
    endrule

    interface SIP sip = sipDebug.sipIn;

    method Vector#(numRegs, data_t) regs = map(readReg, regs_);
    method Vector#(numRegs, Bool) regsUpdated = unpack(regsUpdated_);
endmodule

module mkSIPStatusRegs#(Fmt name, Vector#(numRegs, data_t) statusRegs)(SIP)
    provisos(Add#(a__, 1, numRegs), Add#(numRegs, b__, 256), Bits#(data_t, dataBits));

    Fmt useName = name + $format("-SIPStatusReg");
    SIPDebugger sipDebug <- mkSIPDebugger(useName);

    SIPAddrPeeler#(numRegs) addrPeeler <- mkSIPAddrPeeler(SingleFlitReq);
    SIPSerializer#(data_t) serializer <- mkSIPSerializer;
    
    mkConnection(sipDebug.sipOut, addrPeeler.sipIn);
    mkConnection(serializer.resp, addrPeeler.sipOut.resp);

    (* no_implicit_conditions, fire_when_enabled *)
    rule feedSerializer if (addrPeeler.addrUpdated);
        serializer.send(statusRegs[addrPeeler.addr]);
    endrule

    return sipDebug.sipIn;
endmodule

interface CounterGroup#(numeric type numCounters, numeric type counterBits);
    method Tuple2#(Bit#(TLog#(numCounters)), Bit#(counterBits)) curOut;
endinterface

typeclass CounterGroupClass#(numeric type numCounters, numeric type counterBits);
    module mkCounterGroup#(Vector#(numCounters, Bool) inc)(CounterGroup#(numCounters, counterBits));
endtypeclass

// 1-counter special case
instance CounterGroupClass#(1, counterBits);

module mkCounterGroup#(Vector#(1, Bool) inc)(CounterGroup#(1, counterBits));
    Reg#(Bit#(counterBits)) counter <- mkReg(0);

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick;
        if (inc[0]) counter <= counter + 1;
    endrule

    method Tuple2#(Bit#(0), Bit#(counterBits)) curOut = tuple2(?, counter);
endmodule

endinstance

// General case (2+ counters)
instance CounterGroupClass#(numCounters, counterBits)
    provisos(
        Add#(a__, 1, numCounters),
        Add#(numCounters, b__, 32),
        Log#(numCounters, numCounterBits),
        Add#(c__, TAdd#(numCounterBits, 1), counterBits),
        Add#(d__, 1, numCounterBits)
    );

module mkCounterGroup#(Vector#(numCounters, Bool) inc)(CounterGroup#(numCounters, counterBits));
    Vector#(numCounters, Reg#(Bit#(numCounterBits))) preCounters <- replicateM(mkReg(0));
    XRegFile#(Bit#(numCounterBits), Bit#(counterBits)) counters <- mkXRegFile(0);
    Reg#(Bit#(numCounterBits)) incAddr <- mkReg(0);

    Wire#(Tuple2#(Bit#(numCounterBits), Bit#(counterBits))) outVal <- mkBypassWire;

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick;
        incAddr <= incAddr + 1;

        // Accumulate current preCounter into counter
        Bit#(TAdd#(numCounterBits, 1)) newPreCounter = {1'b0, preCounters[incAddr]} + zeroExtend(inc[incAddr]? 1'b1 : 1'b0);
        Bit#(counterBits) newCounter = counters.read1(incAddr) + zeroExtend(newPreCounter);
        counters.write(incAddr, newCounter);

        // Update all preCounters
        for (Integer i = 0; i < valueOf(numCounters); i = i + 1) begin
            if (incAddr == fromInteger(i)) preCounters[i] <= 0;
            else preCounters[i] <= preCounters[i] + zeroExtend(inc[i]? 1'b1 : 1'b0);
        end

        outVal <= tuple2(incAddr, newCounter);
    endrule

    method Tuple2#(Bit#(TLog#(numCounters)), Bit#(counterBits)) curOut = outVal;
endmodule

endinstance

module mkSIPCounters#(Fmt name, Vector#(numCounters, Bool) inc, Bool enableCounters)(SIPCounters#(counterBits))
    provisos(
        Add#(a__, 1, numCounters),
        Add#(numCounters, b__, 256),

        // Counter groups are most efficient with 32 elements. So structure
        // counters in k groups of 32, plus an extra counter with remainder.
        // NOTE: k can be 0, but numRemCounters > 0 always
        Div#(numCounters, 32, numGroups),
        Add#(k, 1, numGroups),
        Add#(TMul#(k, 32), numRemCounters, numCounters),

        CounterGroupClass#(numRemCounters, counterBits),
        CounterGroupClass#(32, counterBits)
    );

    Fmt useName = name + $format("-SIPStatusReg");
    SIPDebugger sipDebug <- mkSIPDebugger(useName);
    
    SIPAddrPeeler#(numCounters) addrPeeler <- mkSIPAddrPeeler(SingleFlitReq);
    SIPSerializer#(Bit#(counterBits)) serializer <- mkSIPSerializer;
    
    mkConnection(sipDebug.sipOut, addrPeeler.sipIn);
    mkConnection(addrPeeler.sipOut.resp, serializer.resp);



    Vector#(numCounters, Bool) enables = replicate(enableCounters);
    Vector#(numCounters, Bool) qualInc = zipWith(\&& , inc, enables);

    Vector#(k, Vector#(32, Bool)) kIncs = unpack(pack(take(qualInc)));
    Vector#(k, CounterGroup#(32, counterBits)) kGroups <- mapM(mkCounterGroup, kIncs);
    CounterGroup#(numRemCounters, counterBits) remGroup <- mkCounterGroup(takeTail(qualInc));
    
    Reg#(Bool) pendingResp <- mkReg(False);

    (* no_implicit_conditions, fire_when_enabled *)
    rule tick;
        // Match groups with address. k == 0 specialization preserves QoR when
        // numCounters is small. castWidth is used to avoid proviso madness.
        Maybe#(Bit#(counterBits)) res = Invalid;
        if (valueOf(k) == 0) begin
            match {.addr, .val} = remGroup.curOut;
            if (addrPeeler.addr == castWidth(addr)) res = Valid(val);
        end else begin
            Vector#(numGroups, Tuple2#(Bit#(5), Bit#(counterBits))) curOuts;
            for (Integer i = 0; i < valueOf(k); i = i + 1) curOuts[i] = kGroups[i].curOut;
            match {.remAddr, .remVal} = remGroup.curOut;
            curOuts[valueOf(numGroups)-1] = tuple2(castWidth(remAddr), remVal);

            Bit#(TLog#(numGroups)) sel = castWidth(addrPeeler.addr >> 5);
            match {.addr, .val} = curOuts[sel];
            if (addr == castWidth(addrPeeler.addr)) res = Valid(val);
        end

        // Detect and serve read requests
        if (!pendingResp && addrPeeler.addrUpdated) begin
            pendingResp <= True;
        end else if (pendingResp && isValid(res)) begin
            serializer.send(fromMaybe(?, res));
            pendingResp <= False;
        end
    endrule    

    return sipDebug.sipIn;
endmodule


/* 3. TRANSPORT LAYER */

module mkSIPMux#(Fmt name)(SIPMux#(numDests))
    provisos(Add#(a__, 1, numDests), Add#(numDests, b__, 256));

    Fmt useName = name + $format("-SIPMux");
    SIPDebugger sipDebug <- mkSIPDebugger(useName + $format("-sipFromSource"));
    module genTargetDebugger#(Integer i)(SIPDebugger);
        SIPDebugger d <- mkSIPDebugger(useName + $format("-sipToTarget(%d)", i));
        return d;
    endmodule
    Vector#(numDests, SIPDebugger) sipOutDebug <- genWithM(genTargetDebugger);

    SIPAddrPeeler#(numDests) addrPeeler <- mkSIPAddrPeeler(MultiFlitReq);
    mkConnection(sipDebug.sipOut, addrPeeler.sipIn);
   
    (* no_implicit_conditions, fire_when_enabled *)
    rule setReqs;
        for (Integer i = 0; i < valueOf(numDests); i = i + 1) begin
            Bool active = addrPeeler.addr == fromInteger(i);
            sipOutDebug[i].sipIn.req(active? addrPeeler.sipOut.req : Invalid);
        end
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule setResp;
        addrPeeler.sipOut.resp(sipOutDebug[addrPeeler.addr].sipIn.resp);
    endrule

    Vector#(numDests, SIPSource) sipToTargets_ <- mapM(sipDebuggerExtractOut, sipOutDebug);

    interface SIP sipFromSource = sipDebug.sipIn;
    interface Vector sipToTargets = sipToTargets_;
endmodule

module mkSIPSplitter#(Fmt name)(SIPSplitter#(numDests, addrBits))
    provisos(NumAlias#(numAddrs, TMul#(numDests, TExp#(addrBits))), Add#(a__, 1, numAddrs), Add#(numAddrs, b__, 256), Add#(addrBits, c__, 8));

    Fmt useName = name + $format("-SIPSplitter");
    SIPDebugger sipDebug <- mkSIPDebugger(useName + $format("-sipFromSource"));
    module genTargetDebugger#(Integer i)(SIPDebugger);
        SIPDebugger d <- mkSIPDebugger(useName + $format("-sipToTarget(%d)", i));
        return d;
    endmodule
    Vector#(numDests, SIPDebugger) sipOutDebug <- genWithM(genTargetDebugger);
  
    Reg#(Maybe#(Bit#(TLog#(numDests)))) curDestM <- mkReg(Invalid);
    Reg#(SIPFlit) bufferedReq <- mkReg(Invalid);

    Wire#(Bool) reqOutOfBounds <- mkBypassWire;
    Wire#(Bit#(TLog#(numDests))) respSel <- mkBypassWire;

    (* no_implicit_conditions, fire_when_enabled *)
    rule setReqs;
        // Stage 1: Buffer req by a cycle; on the first flit, compute dest and
        // dest-local address, compute out-of-bounds conditions, and derive
        // select signal for the destinations
        let curReq = sipDebug.sipOut.req;
        
        if (isValid(curReq) && !isValid(bufferedReq)) begin
            SIPData fullAddr = fromMaybe(?, curReq);
            Bit#(addrBits) destAddr = castWidth(fullAddr);
            Bit#(TLog#(numDests)) dest = castWidth(fullAddr >> valueOf(addrBits));
            Bool outOfBounds = fullAddr > fromInteger(valueOf(numAddrs)-1);
            curDestM <= outOfBounds? Invalid : Valid(dest);
            bufferedReq <= Valid(castWidth(destAddr));
            reqOutOfBounds <= outOfBounds;
        end else begin
            bufferedReq <= curReq;
            reqOutOfBounds <= False;
        end

        // NOTE: Use 0 instead of ? for X-safety in Verilog sim
        // TODO: See whether we can optimize this
        respSel <= fromMaybe(0, curDestM);

        // Stage 2: Demux the buffered req among destinations
        for (Integer i = 0; i < valueOf(numDests); i = i + 1) begin
            Bool active = isValid(curDestM) && fromMaybe(?, curDestM) == fromInteger(i);
            sipOutDebug[i].sipIn.req(active? bufferedReq : Invalid);
        end
    endrule
            
    (* no_implicit_conditions, fire_when_enabled *)
    rule setResp;
        SIPFlit resp = reqOutOfBounds? Valid(8'hFF /* error resp */) : sipOutDebug[respSel].sipIn.resp;
        sipDebug.sipOut.resp(resp);
    endrule

    Vector#(numDests, SIPSource) sipToTargets_ <- mapM(sipDebuggerExtractOut, sipOutDebug);

    interface SIP sipFromSource = sipDebug.sipIn;
    interface Vector sipToTargets = sipToTargets_;
endmodule

module mkSIPPipe#(Fmt name)(SIPPipe#(n));
    Fmt useName = name + $format("-SIPPipe");
    SIPDebugger sipInDebug  <- mkSIPDebugger(useName + $format("-sipIn"));
    SIPDebugger sipOutDebug <- mkSIPDebugger(useName + $format("-sipOut"));

    NonBlockingPipe#(SIPFlit) reqPipe <- mkNonBlockingPipe(valueOf(n), Invalid);
    NonBlockingPipe#(SIPFlit) respPipe <- mkNonBlockingPipe(valueOf(n), Invalid);

    mkConnection(sipInDebug.sipOut.req, reqPipe._write);
    mkConnection(reqPipe._read, sipOutDebug.sipIn.req);
    mkConnection(sipOutDebug.sipIn.resp, respPipe._write);
    mkConnection(respPipe._read, sipInDebug.sipOut.resp);

    interface SIP sipIn = sipInDebug.sipIn;
    interface SIPSource sipOut = sipOutDebug.sipOut;
endmodule

module mkSIPAutoPipe#(Fmt name)(SIPAutoPipe);
    Fmt useName = name + $format("-SIPPipe");
    SIPDebugger sipInDebug  <- mkSIPDebugger(useName + $format("-sipIn"));
    SIPDebugger sipOutDebug <- mkSIPDebugger(useName + $format("-sipOut"));

    // NOTE: We just use a high-enough default, since max stages has no effect
    // (e.g., on usable FIFO capacity), and we don't care about latency
    NonBlockingPipe#(SIPFlit) reqPipe <- mkNonBlockingAutoPipe(24, Invalid);
    NonBlockingPipe#(SIPFlit) respPipe <- mkNonBlockingAutoPipe(24, Invalid);

    mkConnection(sipInDebug.sipOut.req, reqPipe._write);
    mkConnection(reqPipe._read, sipOutDebug.sipIn.req);
    mkConnection(sipOutDebug.sipIn.resp, respPipe._write);
    mkConnection(respPipe._read, sipInDebug.sipOut.resp);

    interface SIP sipIn = sipInDebug.sipIn;
    interface SIPSource sipOut = sipOutDebug.sipOut;
endmodule



module mkTestSIPControlRegs(SIPControlRegs#(8, Bit#(32)));
    SIPControlRegs#(8, Bit#(32)) t <- mkSIPControlRegs($format("testing"));
    return t;
endmodule

module mkTestSIPStatusRegs(SIP);
    Vector#(8, Reg#(Bit#(32))) regs <- replicateM(mkRegU);
    SIP t <- mkSIPStatusRegs($format("testing"), map(readReg, regs));
    return t;
endmodule

interface TestSIPCounters;
    (* always_enabled *)
    method Action inc(Vector#(32, Bool) v);
    interface SIP sip;
endinterface

module mkTestSIPCounters(TestSIPCounters);
    Wire#(Vector#(32, Bool)) incs <- mkBypassWire;
    Wire#(Bool) enableCounters <- mkDWire(True);
    SIPCounters#(64) t <- mkSIPCounters($format("testing"), incs, enableCounters);
    method Action inc(Vector#(32, Bool) v) = incs._write(v);
    interface SIP sip = t;
endmodule

module mkTestSIPMux(SIPMux#(2));
    SIPMux#(2) t <- mkSIPMux($format("testing"));
    return t;
endmodule

module mkTestSIPSplitter(SIPSplitter#(4, 3));
    SIPSplitter#(4, 3) t <- mkSIPSplitter($format("testing"));
    return t;
endmodule

module mkTestSIPDeserializer(SIPDeserializer#(Bit#(32)));
    SIPDeserializer#(Bit#(32)) t <- mkSIPDeserializer;
    return t;
endmodule

module mkTestSIPEndpointWriter(SIPEndpointWriter#(255, Bit#(7)));
    SIPEndpointWriter#(255, Bit#(7)) t <- mkSIPEndpointWriter;
    return t;
endmodule

module mkTestSIPPipe(Empty);
    Reg#(Bit#(32)) cycle <- mkReg(0);

    SIPPipe#(2) pipe <- mkSIPPipe($format("testing"));

    rule putReq if (cycle == 4);
        SIPFlit x = tagged Valid 2;
        $display($time, ":  Putting request ", fshow(x));
        pipe.sipIn.req(x);
    endrule

    rule getReq;
        let r = pipe.sipOut.req;
        if (r matches tagged Valid .rr) begin
            $display($time, ":  Getting request ", fshow(rr));
        end
    endrule

    rule cycleTick;
        cycle <= cycle + 1;
        if (cycle == 20) $finish;
    endrule
endmodule

// The same SIP network as the test in sip.sv, so we can run its test.
module mkTestSIPNet(SIP);
    Reg#(Bit#(32)) cycle <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule

    SIPMux#(3) mux <- mkSIPMux($format("rootMux"));

    SIPControlRegs#(48, Bit#(16)) cRegs <- mkSIPControlRegs($format("cRegs"));
    mkConnection(mux.sipToTargets[0], cRegs.sip);

    SIP sRegs <- mkSIPStatusRegs($format("sRegs"), cRegs.regs);
    mkConnection(mux.sipToTargets[1], sRegs);

    SIPSplitter#(7, 3) splitter <- mkSIPSplitter($format("split"));
    mkConnection(mux.sipToTargets[2], splitter.sipFromSource);


    Wire#(Bool) enableCounters <- mkDWire(True);

    Vector#(7, SIPPipe#(1)) pipes <- replicateM(mkSIPPipe($format("split")));
    for (Integer i = 0; i < 7; i = i + 1) begin
        mkConnection(splitter.sipToTargets[i], pipes[i].sipIn);

        if (i < 6) begin
            Vector#(4, Bool) incs = takeAt(4*i, cRegs.regsUpdated);
            SIPCounters#(64) cRegCounters <- mkSIPCounters($format("cRegCounters-%d", i), incs, enableCounters);
            mkConnection(pipes[i].sipOut, cRegCounters);
        end else begin
            // Test counter increments at different rates
            Vector#(4, Bool) incs = unpack({cycle[3:1], 1'b1});
            SIPCounters#(40) rateCounters <- mkSIPCounters($format("rateCounters"), incs, enableCounters);
            mkConnection(pipes[i].sipOut, rateCounters);
        end
    end

    return mux.sipFromSource;
endmodule

