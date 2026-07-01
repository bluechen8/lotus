/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// BRAMCore wrapper for Minispec. Used in tests only; users not relying on
// BRAMLoad variants should use XRAM instead.

bsvimport SRAMArray;
bsvimport BRAMCore;

typedef struct {
    Bit#(addrSz) addr;
    Bool write;
    DataT data;
} SRAMReq#(Integer addrSz, type DataT);

typedef struct {
    Bit#(addrSz) addr;
    Bit#(weSz) wrMask;
    DataT data;
} SRAMBEReq#(Integer addrSz, type DataT, Integer weSz);

module SRAM#(Integer addrSz, type DataT);
    SRAMArray#(addrSz, DataT) array;  // BSV array
    Reg#(Bool) arrayHasData(False);

    input Maybe#(SRAMReq#(addrSz, DataT)) req default = Invalid;

    rule tick;
        if (isValid(req)) begin
            let r = fromMaybe(?, req);
            array.put(r.write, r.addr, r.data);
            arrayHasData <= !r.write;
        end else arrayHasData <= False;
    endrule

    method Maybe#(DataT) data = arrayHasData? Valid(array.read) : Invalid;
endmodule

module SRAMLoad#(Integer addrSz, type DataT)(String file);
    SRAMArrayLoad#(addrSz, DataT) array(file);  // BSV array
    Reg#(Bool) arrayHasData(False);

    input Maybe#(SRAMReq#(addrSz, DataT)) req default = Invalid;

    rule tick;
        if (isValid(req)) begin
            let r = fromMaybe(?, req);
            array.put(r.write, r.addr, r.data);
            arrayHasData <= !r.write;
        end else arrayHasData <= False;
    endrule

    method Maybe#(DataT) data = arrayHasData? Valid(array.read) : Invalid;
endmodule

module SRAMBELoad#(Integer addrSz, type DataT, Integer weSz)(String file);
    SRAMArrayBELoad#(addrSz, DataT, weSz) array(file);  // BSV array
    Reg#(Bool) arrayHasData(False);

    input Maybe#(SRAMBEReq#(addrSz, DataT, weSz)) req default = Invalid;

    rule tick;
        if (isValid(req)) begin
            let r = fromMaybe(?, req);
            array.put(r.wrMask, r.addr, r.data);
            arrayHasData <= r.wrMask == 0;
        end else arrayHasData <= False;
    endrule

    method Maybe#(DataT) data = arrayHasData? Valid(array.read) : Invalid;
endmodule

