/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// BSV glue for Xilinx RegFile (XRegFile) module
// dsm: I'm sure there's a beautiful solution that uses the number of ports as a
// numeric type, and manages to do things with a single interface. But I looked
// at the Bluespec source for RegFile and it's in bs, not bsv, so I'm not sure
// it can translate. Instead, just have a few interfaces, one offr each number
// of read ports.
package XRegFile;

export XRegFile(..);
export mkXRegFile;

interface XRegFile#(type addr, type data);
    method Action write(addr a, data d);
    method data read1(addr a);
    method data read2(addr a);
    method data read3(addr a);
    method data read4(addr a);
    method data read5(addr a);
endinterface

`ifndef WITH_BLUESIM
// Synthesis variants, map directly to the Verilog module
import "BVI" XRegFile =
module mkXRegFile#(data initialValue)(XRegFile#(addr, data))
   provisos(Bits#(addr, addrSz), Bits#(data, dataSz));

   default_clock   clk(clk, (*unused*)CLK_GATE);
   default_reset   rstn(rstn);

   parameter ADDR_WIDTH = valueOf(addrSz);
   parameter DATA_WIDTH = valueOf(dataSz);
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initialValue));

   method write(wrAddr, (* reg *)wrData) enable(wrEn);
   method rdData1 read1(rdAddr1);
   method rdData2 read2(rdAddr2);
   method rdData3 read3(rdAddr3);
   method rdData4 read4(rdAddr4);
   method rdData5 read5(rdAddr5);

   schedule (write, read1, read2, read3, read4, read5) CF (read1, read2, read3, read4, read5);
   schedule write C write;
endmodule

`else

// This follows the same conventions and design as XRAM simulation variants,
// using bdpiMem. See XRAM.sv for reference.

// NOTE(dsm): Though reads are side-effect-free, not making them ActionValues
// causes them to be called all over the place: before other writes, before the
// memory handle is allocated, etc. So we use readMeValue, which does not
// assert to allow this use.
import "BDPI" function ActionValue#(Bit#(32)) allocMem(Bit#(32) addrSz, Bit#(32) dataSz, Bit#(n) initialValue);
import "BDPI" function Bit#(n) readMemValue(Bit#(32) memHandle, Bit#(k) addr);
import "BDPI" function Action writeMem(Bit#(32) memHandle, Bit#(k) addr, Bit#(n) value);

module mkXRegFile#(data initialValue)(XRegFile#(addr, data))
    provisos(Bits#(addr, addrSz), Bits#(data, dataSz));

    Reg#(Bit#(32)) memHandle <- mkReg(-1);

    Wire#(Maybe#(Tuple2#(Bit#(addrSz), Bit#(dataSz)))) wrReq <- mkDWire(Invalid);
   
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

        if (isValid(wrReq)) begin
            match {.wrAddr, .wrData} = fromMaybe(?, wrReq);
            writeMem(mem, wrAddr, wrData);
        end
    endrule

    function data read(addr a);
        if (memHandle == -1) return initialValue;
        else begin
            Bit#(addrSz) p = pack(a);
            Bit#(dataSz) d = readMemValue(memHandle, p);
            return unpack(d);
        end
    endfunction

    method Action write(addr address, data din);
        wrReq <= Valid(tuple2(pack(address), pack(din)));
    endmethod

    method data read1(addr a) = read(a);
    method data read2(addr a) = read(a);
    method data read3(addr a) = read(a);
    method data read4(addr a) = read(a);
    method data read5(addr a) = read(a);
endmodule
`endif

endpackage
