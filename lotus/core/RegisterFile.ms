/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CoreTypes;
bsvimport XRegFile;

module RegisterFile;
    XRegFile#(Bit#(5), Word) regs(0);

    // Purely for debugging/testing, gets optimized out on synthesis
    Vector#(32, Reg#(Bit#(32))) printRegs(0);

    method Word rd1(RIndx rindx) = regs.read1(rindx);
    method Word rd2(RIndx rindx) = regs.read2(rindx);
    method Word rd3(RIndx rindx) = regs.read3(rindx);

    input Maybe#(RegWriteArgs) wr default = Invalid;

    rule rfWrite;
        if (isValid(wr)) begin
            RegWriteArgs rwd = fromMaybe(?, wr);
            if (rwd.index != 0) begin
                regs.write(rwd.index, rwd.data);
                printRegs[rwd.index] <= rwd.data;
            end
        end
    endrule

    // Simulation-only debugging method
    // IMPORTANT: Do not modify this code! The microtests depend on this.
    method Fmt fshow;
        Fmt f = $format;
        for (Integer i = 0; i < 32; i = i+1) begin
            f = f + $format("x%0d = 0x%x", i, (i == 0)? 0 : printRegs[i]);
            if (i < 31) f = f + $format("\n");
        end
        return f;
    endmethod
endmodule
