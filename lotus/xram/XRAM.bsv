/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// BSV glue for Xilinx RAM (XRAM) modules
package XRAM;

// The basics
// TODO: Async versions, for now we're focused on single-clock designs
export XRAMMode(..);
export mkXRAM1, mkXRAM2, mkXRAM1BE, mkXRAM2BE;
export XRAM_PIPED_PORT(..), XRAM_PIPED_PORT_BE(..), XRAM_PIPED_DUAL_PORT(..), XRAM_PIPED_DUAL_PORT_BE(..);
export XRAM_PORT(..), XRAM_PORT_BE(..), XRAM_DUAL_PORT(..), XRAM_DUAL_PORT_BE(..);

// Simple port transformers
export mkPortBEToPort, mkPortToPortBE;

import Vector::*;

typedef enum {
    NO_CHANGE = 0,
    WRITE_FIRST = 1,
    READ_FIRST = 2,
    WRITE_ONLY = 3,
    READ_ONLY = 4
} XRAMMode deriving(Bits, Eq, FShow);

// Interfaces: Port interfaces come in two variants: XRAM_PIPED_PORTs are the
// generic ones. They match the interface of BRAM ports, but specify the read
// latency as a numeric type. XRAM_PORTs are then defined as a specialization
// of XRAM_PIPED ports with latency = 1.
// NOTE: Before, XRAM_PORTs were just typedef'd to BRAM_PORTs. This cannot be
// done anymore, because that creates ambiguity on the latency. We don't need
// this compatibility, but other users may need minor tweaks. 
// TODO: Now that we've broken with BRAM_PORT, we should probably include the
// mode as part of the port type as well, and align the BE ports to match the
// hardware better (separate write-enable and mask; we=1 and mask=0 is just a
// silent write, and deriving we from mask costs LUTs).
interface XRAM_PIPED_PORT#(type addr, type data, numeric type latency);
    (* always_ready *)
    method Action put(Bool write, addr address, data datain);
    (* always_ready *)
    method data read;
endinterface

interface XRAM_PIPED_PORT_BE#(type addr, type data, numeric type n, numeric type latency);
    (* always_ready *)
    method Action put(Bit#(n) writeen, addr address, data datain);
    (* always_ready *)
    method data read;
endinterface

interface XRAM_PIPED_DUAL_PORT#(type addrA, type dataA, type addrB, type dataB, numeric type latency);
   interface XRAM_PIPED_PORT#(addrA, dataA, latency) a;
   interface XRAM_PIPED_PORT#(addrB, dataB, latency) b;
endinterface

interface XRAM_PIPED_DUAL_PORT_BE#(type addr, type data, numeric type n, numeric type latency);
   interface XRAM_PIPED_PORT_BE#(addr, data, n, latency) a;
   interface XRAM_PIPED_PORT_BE#(addr, data, n, latency) b;
endinterface

typedef XRAM_PIPED_PORT#(addr, data, 1) XRAM_PORT#(type addr, type data);
typedef XRAM_PIPED_PORT_BE#(addr, data, n, 1) XRAM_PORT_BE#(type addr, type data, numeric type n);
typedef XRAM_PIPED_DUAL_PORT#(addrA, dataA, addrB, dataB, 1) XRAM_DUAL_PORT#(type addrA, type dataA, type addrB, type dataB);
typedef XRAM_PIPED_DUAL_PORT_BE#(addr, data, n, 1) XRAM_DUAL_PORT_BE#(type addr, type data, numeric type n);


// Transforms a PORT_BE interface into a non-BE port. Useful if you need a
// memory where only one port is BE, or for internal implementation
// purposes
module mkPortBEToPort#(XRAM_PIPED_PORT_BE#(addr_t, data_t, weSz, latency) portBE)(XRAM_PIPED_PORT#(addr_t, data_t, latency));
    method Action put(Bool we, addr_t addr, data_t din) = portBE.put(we? -1 : 0, addr, din);
    method data_t read = portBE.read;
endmodule

// Transforms a PORT interface into a PORT_BE interface with a single enable
// bit. This allows writing port transformers with less code: just write the BE
// variant, and the non-BE variant can be done by transforming to BE and back.
module mkPortToPortBE#(XRAM_PIPED_PORT#(addr_t, data_t, latency) portNBE)(XRAM_PIPED_PORT_BE#(addr_t, data_t, 1, latency));
    method Action put(Bit#(1) we, addr_t addr, data_t din) = portNBE.put(we == 1? True : False, addr, din);
    method data_t read = portNBE.read;
endmodule

`ifndef WITH_BLUESIM
// Synthesis variants; these map directly to the Verilog XRAM modules, and use
// maximally conflict-free schedules
import "BVI" XRAM1 =
module mkXRAM1#(data initialValue, XRAMMode mode, String style)(XRAM_PIPED_PORT#(addr, data, latency))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz));

   default_clock   clk(clk, (*unused*)CLK_GATE);
   default_reset   rst();

   parameter ADDR_WIDTH = valueOf(addrSz);
   parameter DATA_WIDTH = valueOf(dataSz);
   parameter READ_LATENCY = valueOf(latency);
   parameter MODE = mode;
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initialValue));
   parameter STYLE = style;

   method put(we, (* reg *)addr, (* reg *)din) enable(en) clocked_by(clk) reset_by(rst);
   method dout read() clocked_by(clk) reset_by(rst);

   schedule (put, read) CF (read);
   schedule put C put;
endmodule

import "BVI" XRAM1BE =
module mkXRAM1BE#(data initialValue, XRAMMode mode, String style)(XRAM_PIPED_PORT_BE#(addr, data, weSz, latency))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz));

   default_clock   clk(clk, (*unused*)CLK_GATE);
   default_reset   rst();

   parameter ADDR_WIDTH = valueOf(addrSz);
   parameter DATA_WIDTH = valueOf(dataSz);
   parameter CHUNK_SIZE = valueOf(TDiv#(dataSz, weSz));
   parameter READ_LATENCY = valueOf(latency);
   parameter MODE = mode;
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initialValue));
   parameter STYLE = style;

   method put(we, (* reg *)addr, (* reg *)din) enable(en) clocked_by(clk) reset_by(rst);
   method dout read() clocked_by(clk) reset_by(rst);

   schedule (put, read) CF (read);
   schedule put C put;
endmodule

import "BVI" XRAM2 =
module mkXRAM2#(dataA_t initialValue, XRAMMode modeA, XRAMMode modeB, String style)(XRAM_PIPED_DUAL_PORT#(addrA_t, dataA_t, addrB_t, dataB_t, latency))
   provisos(Bits#(addrA_t, addrASz), Bits#(dataA_t, dataASz), Bits#(addrB_t, addrBSz), Bits#(dataB_t, dataBSz),
            Add#(addrBSz, logRatioB, addrASz), Log#(ratioB, logRatioB), Mul#(dataASz, ratioB, dataBSz));

   default_clock   clk(clk, (*unused*)CLK_GATE);
   default_reset   rst();

   parameter ADDR_WIDTH = valueOf(addrASz);
   parameter DATA_WIDTH = valueof(dataASz);
   parameter READ_LATENCY = valueOf(latency);
   parameter MODEA = modeA;
   parameter MODEB = modeB;
   parameter NUM_WORDS = Bit#(TAdd#(1, addrASz)) ' (fromInteger(2 ** valueOf(addrASz)));
   parameter INITIAL_VALUE  = Bit#(dataASz) ' (pack(initialValue));
   parameter STYLE = style;
   parameter LOG_RATIOB = valueOf(logRatioB);

   interface XRAM_PORT a;
      method put(weA, (* reg *)addrA, (* reg *)dinA) enable(enA);
      method doutA read();
   endinterface: a

   interface XRAM_PORT b;
      method put(weB, (* reg *)addrB, (* reg *)dinB) enable(enB);
      method doutB read();
   endinterface: b
   
   schedule (a_read) CF (a_put, a_read, b_put, b_read);
   schedule a_put C a_put;
   schedule (b_read) CF (a_put, a_read, b_put, b_read);
   schedule b_put C b_put;
   schedule a_put CF b_put;
endmodule

import "BVI" XRAM2BE =
module mkXRAM2BE#(data initialValue, XRAMMode modeA, XRAMMode modeB, String style)(XRAM_PIPED_DUAL_PORT_BE#(addr, data, weSz, latency))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz));

   default_clock   clk(clk, (*unused*)CLK_GATE);
   default_reset   rst();

   parameter ADDR_WIDTH = valueOf(addrSz);
   parameter DATA_WIDTH = valueOf(dataSz);
   parameter CHUNK_SIZE = valueOf(TDiv#(dataSz, weSz));
   parameter READ_LATENCY = valueOf(latency);
   parameter MODEA = modeA;
   parameter MODEB = modeB;
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initialValue));
   parameter STYLE = style;


   interface XRAM_PORT_BE a;
      method put(weA, (* reg *)addrA, (* reg *)dinA) enable(enA);
      method doutA read();
   endinterface: a

   interface XRAM_PORT_BE b;
      method put(weB, (* reg *)addrB, (* reg *)dinB) enable(enB);
      method doutB read();
   endinterface: b
   
   schedule (a_read) CF (a_put, a_read, b_put, b_read);
   schedule a_put C a_put;
   schedule (b_read) CF (a_put, a_read, b_put, b_read);
   schedule b_put C b_put;
   schedule a_put CF b_put;
endmodule

`else

// Simulation variants: Because these need not be synthesized, they are ALL
// based on a single class, XRAM2BE. This is implemented using BDPI functions,
// because it's nigh-impossible to implement these modules using the
// existing BRAM ones (e.g., a dual-port READ_FIRST XRAM would require 4 BRAM
// ports), and using vectors of registers generates unwieldy bluesim code (the
// vectors get expanded).

// NOTE(dsm): Though reads are side-effect-free, not making them ActionValues
// causes them to be called all over the place: before other writes, before the
// memory handle is allocated, etc.
import "BDPI" function ActionValue#(Bit#(32)) allocMem(Bit#(32) addrSz, Bit#(32) dataSz, Bit#(n) initialValue);
import "BDPI" function ActionValue#(Bit#(n)) readMem(Bit#(32) memHandle, Bit#(k) addr);
import "BDPI" function Action writeMem(Bit#(32) memHandle, Bit#(k) addr, Bit#(n) value);

module mkXRAM2BE#(data initialValue, XRAMMode modeA, XRAMMode modeB, String style)(XRAM_PIPED_DUAL_PORT_BE#(addr, data, weSz, latency))
    provisos(Bits#(addr, addrSz), Bits#(data, dataSz), Mul#(chunkSz, weSz, dataSz), Add#(a__, 1, latency));

    Reg#(Bit#(32)) memHandle <- mkReg(-1);

    Reg#(Bit#(dataSz)) doutA[valueOf(latency)];
    Reg#(Bit#(dataSz)) doutB[valueOf(latency)];
    for (Integer i = 0; i < valueOf(latency); i = i + 1) begin
        doutA[i] <- mkReg(pack(initialValue));
        doutB[i] <- mkReg(pack(initialValue));
    end
    for (Integer i = 1; i < valueOf(latency); i = i + 1) begin
        rule moveA; doutA[i] <= doutA[i-1]; endrule
        rule moveB; doutB[i] <= doutB[i-1]; endrule
    end

    Wire#(Maybe#(Tuple3#(Bit#(weSz), Bit#(addrSz), Bit#(dataSz)))) reqA <- mkDWire(Invalid);
    Wire#(Maybe#(Tuple3#(Bit#(weSz), Bit#(addrSz), Bit#(dataSz)))) reqB <- mkDWire(Invalid);

    function Bit#(dataSz) newVal(Bit#(weSz) we, Bit#(dataSz) prevVal, Bit#(dataSz) din);
        Bit#(dataSz) mask;
        for (Integer i = 0; i < valueOf(dataSz); i = i + 1) mask[i] = we[i/valueOf(chunkSz)];
        return (din & mask) | (prevVal & ~mask);
    endfunction
    
    rule tick;
        // Mem initialization; needs to happen in a rule because apparently you
        // can't have an ActionValue call within the module context (so
        // let mem <- allocMem() doesn't work)
        Bit#(32) mem;
        if (memHandle == -1) begin
            mem <- allocMem(fromInteger(valueOf(addrSz)), fromInteger(valueOf(dataSz)), pack(initialValue));
            memHandle <= mem;
        end else begin
            mem = memHandle;
        end

        Bool conflict = False;
        if (isValid(reqA) && isValid(reqB)) begin
            match {.weA, .addrA, .dinA} = fromMaybe(?, reqA);
            match {.weB, .addrB, .dinB} = fromMaybe(?, reqB);
            let addr = addrA;
            if (addrA == addrB && ((weA != 0) || (weB != 0))) begin
                conflict = True;
                Bit#(dataSz) undef = ?;
                Bit#(dataSz) curVal <- readMem(mem, addr);
                // Model exactly the behavior described in UG573
                // NOTE: These conditions don't explicitly cover READ_ONLY and WRITE_ONLY modes... UG573 is silent on them.
                // I take WRITE_ONLY to be line NO_CHANGE on writes (dout isn't driven), which seems unambiguous. 
                // The key question is... if a port is READ_ONLY and another port is WRITE_ONLY, does that behave as if the
                // READ_ONLY port was READ_FIRST? (i.e., the read port gets the old value), or like NO_CHANGE/WRITE_FIRST?
                // (i.e., undefined output). This models the second case, which is more conservative.
                if ((weA != 0) && (weB != 0)) begin
                    // Double-write, all bets are off in ALL MODES
                    $display("XRAM2: Double-write on addr", addr, ", memory corrupted, a.read and b.read will return unknown data");
                    writeMem(mem, addr, undef);
                    doutA[0] <= ?;
                    doutB[0] <= ?;
                end else if (weA != 0) begin
                    let nextVal = newVal(weA, curVal, dinA);
                    if (modeA == READ_FIRST) begin
                        doutA[0] <= curVal;
                        doutB[0] <= curVal;
                    end else begin
                        if (modeA == WRITE_FIRST) doutA[0] <= nextVal;
                        doutB[0] <= ?;
                        // This isn's bad enough to throw a $display, we can have external bypass logic
                    end
                    writeMem(mem, addr, nextVal);
                end else begin // weB != 0, i.e., B writes
                    let nextVal = newVal(weB, curVal, dinB);
                    if (modeB == READ_FIRST) begin
                        doutB[0] <= curVal;
                        doutA[0] <= curVal;
                    end else begin
                        if (modeB == WRITE_FIRST) doutB[0] <= nextVal;
                        doutA[0] <= ?;
                    end
                    writeMem(mem, addr, nextVal);
                end
            end
        end

        if (!conflict && isValid(reqA)) begin
            match {.we, .addr, .din} = fromMaybe(?, reqA);
            Bit#(dataSz) curVal <- readMem(mem, addr);
            if (we == 0) begin
                if (modeA != WRITE_ONLY) doutA[0] <= curVal;
                else begin
                    $display("XRAM2: Read on write-only port A! Output is unknown.");
                    doutA[0] <= ?;
                end
            end else begin
                let nextVal = newVal(we, curVal, din);
                if (modeA == READ_FIRST) doutA[0] <= curVal;
                else if (modeA == WRITE_FIRST) doutA[0] <= nextVal;
                else if (modeA == READ_ONLY) begin
                    $display("XRAM2: Write on read-only port A! Output is unknown.");
                    doutA[0] <= ?;
                end
                writeMem(mem, addr, nextVal);
            end
        end

        if (!conflict && isValid(reqB)) begin
            match {.we, .addr, .din} = fromMaybe(?, reqB);
            Bit#(dataSz) curVal <- readMem(mem, addr);
            if (we == 0) begin
                if (modeB != WRITE_ONLY) doutB[0] <= curVal;
                else begin
                    $display("XRAM2: Read on write-only port B! Output is unknown.");
                    doutB[0] <= ?;
                end
            end else begin
                let nextVal = newVal(we, curVal, din);
                if (modeB == READ_FIRST) doutB[0] <= curVal;
                else if (modeB == WRITE_FIRST) doutB[0] <= nextVal;
                else if (modeB == READ_ONLY) begin
                    $display("XRAM2: Write on read-only port B! Output is unknown.");
                    doutB[0] <= ?;
                end
                writeMem(mem, addr, nextVal);
            end
        end
    endrule

    interface XRAM_PORT_BE a;
        method Action put(Bit#(weSz) we, addr address, data din);
            reqA <= Valid(tuple3(we, pack(address), pack(din)));
        endmethod

        method data read() = unpack(doutA[valueOf(latency)-1]);
    endinterface : a

    interface XRAM_PORT_BE b;
        method Action put(Bit#(weSz) we, addr address, data din);
            reqB <= Valid(tuple3(we, pack(address), pack(din)));
        endmethod

        method data read() = unpack(doutB[valueOf(latency)-1]);
    endinterface : b
endmodule

module mkXRAM2#(dataA_t initialValue, XRAMMode modeA, XRAMMode modeB, String style)(XRAM_PIPED_DUAL_PORT#(addrA_t, dataA_t, addrB_t, dataB_t, latency))
    provisos(Bits#(addrA_t, addrASz), Bits#(dataA_t, dataASz), Bits#(addrB_t, addrBSz), Bits#(dataB_t, dataBSz),
             Add#(addrBSz, logRatioB, addrASz), Log#(ratioB, logRatioB), Mul#(dataASz, ratioB, dataBSz), Add#(a__, 1, latency));

    // We implement asymmetric ports the opposite way than in the Xilinx
    // templates: the underlying memory uses the WIDER port, B, and port A is
    // implemented using enables. This would be inefficient with SV, but it's
    // fine in simulation.
    Vector#(ratioB, dataA_t) initialValueB = replicate(initialValue);
    XRAM_PIPED_DUAL_PORT_BE#(addrB_t, dataB_t, ratioB, latency) ram <- mkXRAM2BE(unpack(pack(initialValueB)), modeA, modeB, style);
    Reg#(Bit#(logRatioB)) readOffsetA[valueOf(latency)];
    for (Integer i = 0; i < valueOf(latency); i = i + 1) begin
        readOffsetA[i] <- mkReg(?);
    end
    for (Integer i = 1; i < valueOf(latency); i = i + 1) begin
        rule moveReadOffsetA; readOffsetA[i] <= readOffsetA[i-1]; endrule
    end
    
    XRAM_PIPED_PORT#(addrB_t, dataB_t, latency) portB <- mkPortBEToPort(ram.b);

    interface XRAM_PIPED_PORT a;
        method Action put(Bool we, addrA_t address, dataA_t din);
            Bit#(addrBSz) addr;
            Bit#(logRatioB) offset;
            {addr, offset} = unpack(pack(address));
            Vector#(ratioB, dataA_t) dinWide = unpack(0);
            dinWide[offset] = din;
            Bit#(ratioB) weWide = 0;
            if (we) weWide[offset] = 1'b1;
            ram.a.put(weWide, unpack(addr), unpack(pack(dinWide)));
            if (!we || modeA != NO_CHANGE) readOffsetA[0] <= offset;
        endmethod

        method dataA_t read;
            Vector#(ratioB, dataA_t) dataWide = unpack(pack(ram.a.read));
            return dataWide[readOffsetA[valueOf(latency)-1]];
        endmethod
    endinterface

    interface XRAM_PIPED_PORT b = portB;
endmodule

module mkXRAM1BE#(data initialValue, XRAMMode mode, String style)(XRAM_PIPED_PORT_BE#(addr, data, weSz, latency))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz), Mul#(chunkSz, weSz, dataSz), Add#(a__, 1, latency));
   XRAM_PIPED_DUAL_PORT_BE#(addr, data, weSz, latency) ram <- mkXRAM2BE(initialValue, mode, NO_CHANGE, style);
   return ram.a;
endmodule

module mkXRAM1#(data initialValue, XRAMMode mode, String style)(XRAM_PIPED_PORT#(addr, data, latency))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz), Add#(a__, 1, latency));
   XRAM_PIPED_DUAL_PORT_BE#(addr, data, 1, latency) ram <- mkXRAM2BE(initialValue, mode, NO_CHANGE, style);
   XRAM_PIPED_PORT#(addr, data, latency) nonBEPort <- mkPortBEToPort(ram.a);
   return nonBEPort;
endmodule

`endif

endpackage
