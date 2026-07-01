/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// BSV glue for RegWithReset module
package RegWithReset;

export RegWithReset(..);
export mkRegWithReset;

interface RegWithReset#(type data);
    // Like mkReg
    method Action _write(data d);
    method data _read;

    // Resets to initial value; overrides _write
    method Action reset;
endinterface

`ifndef WITH_BLUESIM
// Synthesis variants, map directly to the Verilog module
import "BVI" RegWithReset =
module mkRegWithReset#(data initialValue)(RegWithReset#(data)) provisos(Bits#(data, dataSz));
   default_clock clk(clk, (*unused*)CLK_GATE);
   default_reset rst();

   parameter WIDTH = valueOf(dataSz);
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initialValue));

   method _write((* reg *)wrData) enable(wrEn);
   method data _read;
   method reset() enable(reset);

   schedule _read  CF (_write, _read, reset);
   schedule _write CF (_read, reset);
   schedule reset CF (_write, _read);
   schedule _write C _write;
   schedule reset C reset;
endmodule

`else

module mkRegWithReset#(data initialValue)(RegWithReset#(data)) provisos(Bits#(data, dataSz));
    Reg#(data) val <- mkReg(initialValue);

    Wire#(Maybe#(data)) doWrite <- mkDWire(Invalid);
    Wire#(Bool) doReset <- mkDWire(False);

    rule tick;
        if (doReset) val <= initialValue;
        else if (doWrite matches tagged Valid .x) val <= x;
    endrule

    method Action _write(data x) = doWrite._write(Valid(x));
    method data _read = val;
    method Action reset = doReset._write(True);
endmodule

`endif

/*
//typedef 5 W; // infers to regs only with both the SV and BSV native implementations
//typedef 1 W; // infers to regs only with the SV version, but has LUTs with BSV impl
typedef 2 W; // infers to regs only with the SV version, but has LUTs with BSV impl

interface RegWithResetTest;
    (* always_enabled, always_ready *)
    method Action in(Bit#(4) c, Bit#(W) v);
    method Bit#(W) out;
endinterface

module mkTestRegWithReset(TestRegWithReset);
    Reg#(Vector#(4, Bool)) creg <- mkReg(unpack(0));
    RegWithReset#(Bit#(W)) s1 <- mkRegWithReset(0);
    RegWithReset#(Bit#(W)) s2 <- mkRegWithReset(1);

    rule tick;
        if (creg[2]) s1.reset;
        if (creg[1]) s2 <= s1;
        if (creg[0]) s2.reset;
    endrule

    method Action in(Bit#(4) c, Bit#(W) v);
        creg <= unpack(c);
        if (creg[3]) s1 <= v;
    endmethod

    method Bit#(W) out = s2;
endmodule
*/

endpackage
