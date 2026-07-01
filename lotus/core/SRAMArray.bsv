/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// BSV glue code for single-ported, non-loaded/loaded BRAM memories
import BRAMCore::*;

typedef BRAM_PORT#(Bit#(addrSz), dataT) SRAMArray#(numeric type addrSz, type dataT);

module mkSRAMArray(SRAMArray#(addrSz, dataT) ) provisos (Bits#(dataT, dataSz));
    Integer memSz = valueOf(TExp#(addrSz));
    Bool hasOutputRegister = False;
    BRAM_PORT#(Bit#(addrSz), dataT) bram <- mkBRAMCore1(memSz, hasOutputRegister);
    return bram;
endmodule

typedef BRAM_PORT#(Bit#(addrSz), dataT) SRAMArrayLoad#(numeric type addrSz, type dataT);

module mkSRAMArrayLoad#(String file)(SRAMArrayLoad#(addrSz, dataT)) provisos (Bits#(dataT, dataSz));
    Integer memSz = valueOf(TExp#(addrSz));
    Bool hasOutputRegister = False;
    BRAM_PORT#(Bit#(addrSz), dataT) bram <- mkBRAMCore1Load(memSz, hasOutputRegister, file, False);
    return bram;
endmodule

// Byte-enabled variants
typedef BRAM_PORT_BE#(Bit#(addrSz), dataT, n) SRAMArrayBE#(numeric type addrSz, type dataT, numeric type n);

module mkSRAMArrayBE(SRAMArrayBE#(addrSz, dataT, n) ) provisos (Bits#(dataT, dataSz), Mul#(TDiv#(dataSz, n), n, dataSz));
    Integer memSz = valueOf(TExp#(addrSz));
    Bool hasOutputRegister = False;
    BRAM_PORT_BE#(Bit#(addrSz), dataT, n) bram <- mkBRAMCore1BE(memSz, hasOutputRegister);
    return bram;
endmodule

typedef BRAM_PORT_BE#(Bit#(addrSz), dataT, n) SRAMArrayBELoad#(numeric type addrSz, type dataT, numeric type n);

module mkSRAMArrayBELoad#(String file)(SRAMArrayBELoad#(addrSz, dataT, n)) provisos (Bits#(dataT, dataSz), Mul#(TDiv#(dataSz, n), n, dataSz));
    Integer memSz = valueOf(TExp#(addrSz));
    Bool hasOutputRegister = False;
    BRAM_PORT_BE#(Bit#(addrSz), dataT, n) bram <- mkBRAMCore1BELoad(memSz, hasOutputRegister, file, False);
    return bram;
endmodule


