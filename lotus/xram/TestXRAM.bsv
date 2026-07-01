/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// These are quick, non-exhaustive tests, mainly for the XRAM *BSV modules*,
// not the the SystemVerilog core file (though by compiling with verilator, you
// can get equivalence of the Bluesim/BDPI and SV versions).
// These tests have no passing condition and are meant to be inspected by hand.
import XRAM::*;
import FIFO::*;

module mkTestXRAM1(Empty);
    XRAM_PORT#(Bit#(8), Bit#(16)) ram <- mkXRAM1(42, READ_FIRST, "auto");

    Reg#(Bit#(32)) cycle <- mkReg(0);
    FIFO#(Bit#(8)) readAddrQ <- mkSizedFIFO(8);

    rule tick;
        cycle <= cycle + 1;
        if (cycle == 16) begin
            $display("DONE");
            $finish;
        end
    endrule

    rule writeReq if (cycle % 4 == 1);
        let addr = cycle[7:0];
        let data = cycle[15:0];
        $display("[", cycle, "] Writing bram[", addr, "] <=",  data);
        ram.put(True, addr, data);
    endrule

    rule readReq if (cycle % 2 == 0);
        Bit#(8) readAddr = truncate(cycle) - 1;
        ram.put(False, readAddr, ?);
        readAddrQ.enq(readAddr);
        $display("[", cycle, "] Issued read request, addr = ", readAddr);
    endrule

    rule readResp if (cycle % 2 == 1);
        $display("[", cycle, "] Read bram[", readAddrQ.first, "] = ",  ram.read);
        readAddrQ.deq;
    endrule

    rule readResp2 if (cycle % 2 != 1);
        $display("[", cycle, "] Read bram output is",  ram.read);
    endrule
endmodule

// Disabling test, since it's require importing all of the utils/ machinery and xram should be kept self-contained
`ifdef NOPE
import XRAMUtils::*;

module mkTestXRAMPort(Empty);
    XRAM_PIPED_PORT#(Bit#(8), Bit#(16), 4) iram <- mkXRAM1(42, NO_CHANGE, "auto");
    TaggedPortQueue#(Bit#(8), Bit#(16), 1) pq <- mkPortQueue(iram, NO_CHANGE);

    Reg#(Bit#(32)) cycle <- mkReg(0);
    FIFO#(Bit#(8)) readAddrQ <- mkSizedFIFO(8);

    rule tick;
        cycle <= cycle + 1;
        if (cycle == 32) begin
            $display("DONE");
            $finish;
        end
    endrule

    /*rule rawRead;
        $display("[", cycle, "] Raw bram output is", iram.read);
    endrule*/

    rule writeReq if (cycle % 4 == 1);
        let addr = cycle[7:0];
        let data = cycle[15:0];
        $display("[", cycle, "] Writing bram[", addr, "] <=",  data);
        pq.put(True, addr, data);
    endrule

    rule readReq if (cycle % 2 == 0);
        Bit#(8) readAddr = truncate(cycle) - 1;
        pq.put(False, readAddr, ?);
        readAddrQ.enq(readAddr);
        $display("[", cycle, "] Issued read request, addr = ", readAddr);
    endrule

    rule readResp;
        $display("[", cycle, "] Read bram[", readAddrQ.first, "] = ",  pq.first);
        readAddrQ.deq;
        pq.deq;
    endrule

    /*rule readResp2 if (cycle % 2 != 1);
        $display("[", cycle, "] Read bram output is",  ram.read);
    endrule*/
endmodule

`endif

module mkTestXRAM2(Empty);
    // Tests asymmetric dual-port version with latency == 2
    XRAM_PIPED_DUAL_PORT#(Bit#(8), Bit#(16), Bit#(7), Bit#(32), 2) ram <- mkXRAM2(42, READ_FIRST, WRITE_FIRST, "auto");

    Reg#(Bit#(32)) cycle <- mkReg(0);
    FIFO#(Bit#(8)) readAddrQ <- mkSizedFIFO(8);
    FIFO#(Bit#(8)) readAddrQ2 <- mkSizedFIFO(8); // add another cycle to match read latency
    rule pass;
        readAddrQ2.enq(readAddrQ.first);
        readAddrQ.deq;
    endrule

    rule tick;
        cycle <= cycle + 1;
        if (cycle == 16) begin
            $display("DONE");
            $finish;
        end
    endrule

    rule writeReq;
        let addr = cycle[6:0];
        let data = {4 + cycle[15:0], cycle[15:0]};
        $display("[", cycle, "] Writing bram[", addr, "] <=",  data);
        ram.b.put(True, addr, data);
    endrule

    rule readReq;
        Bit#(8) readAddr = truncate(cycle) - 2;
        ram.a.put(False, readAddr, ?);
        readAddrQ.enq(readAddr);
        $display("[", cycle, "] Issued read request, addr = ", readAddr);
    endrule

    rule readResp;
        $display("[", cycle, "] Read bram.a[", readAddrQ2.first, "] = ",  ram.a.read);
        readAddrQ2.deq;
    endrule
endmodule
