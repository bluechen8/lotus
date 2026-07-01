/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// These are quick, non-exhaustive tests, mainly for the XRegFile *BSV modules*,
// not the the SystemVerilog core file (though by compiling with verilator, you
// can get equivalence of the Bluesim/BDPI and SV versions).
// These tests have no passing condition and are meant to be inspected by hand.
import XRegFile::*;

module mkTestXRegFile1(Empty);
    XRegFile#(Bit#(4), Bit#(8)) rf <- mkXRegFile(8'd42);
    
    Reg#(Bit#(32)) cycle <- mkReg(0);

    rule tick;
        cycle <= cycle + 1;
        if (cycle == 32) begin
            $display("DONE");
            $finish;
        end
    endrule

    rule read; //if (cycle % 2 == 0);
        Bit#(4) addr = truncate(cycle);
        $display("[", cycle, "] Read rf[", addr, "] = ", rf.read1(addr));
    endrule

    rule write; //if (cycle % 2 != 1);
        Bit#(4) addr = truncate(cycle);
        $display("[", cycle, "] Writing to ",  addr, " prev value = ", rf.read1(addr));
        rf.write(addr, truncate(cycle + 1));
    endrule
    
endmodule
