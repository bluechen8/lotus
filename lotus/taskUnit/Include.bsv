/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */



typedef Bit#(16) CycleOffset; // lowest bits within each timestamps are the offset within each cycle

// Basic types
typedef Bit#(32) Word;

// CycleId width determines the amount of overlap across cycles we can have; 2
// bits allows (-1,0,1) differences, i.e. a 2-cycle range. This runs into edge
// cases as tiles are occasionally 2 cycles off, so we use 3 bits, which allow
// differences in the (-3,3) range.
typedef 3       CycleIdBits;
typedef Bit#(CycleIdBits) CycleId;
typedef TExp#(CycleIdBits) NumCycles;

typedef 1 CycleIdDeltaBits;
typedef Bit#(CycleIdDeltaBits) CycleIdDelta;

typedef 2 ArgsPerToken;
typedef Bit#(TLog#(TAdd#(ArgsPerToken, 1))) TokenArgIdx;

typedef 63 MaxInEdges;
typedef Bit#(TLog#(TAdd#(MaxInEdges, 1))) NumInEdges;

// Task size is in number of cache lines, 0-based, i.e., 0 = 1 line ... 31 = 32
// lines. We support up to 32 lines, half the size of the L1I; normal tasks are
// much smaller, and if larger tasks are the norm, we may want to revert to
// next-line prefetching past the max task size.
typedef Bit#(5) TaskSize;

// 2. Task queue
typedef struct {
    Bit#(18) key; // Heap is sensitive to bitwidth, so just enough to store {1 bit, CycleId, CycleOffset}, and leverage 
    data_t data;
} HeapEntry#(type data_t) deriving(Bits, Eq, FShow);
instance Ord#(HeapEntry#(data_t));
    function Bool \< (HeapEntry#(data_t) a, HeapEntry#(data_t) b);
       return a.key < b.key;
        /*CycleOffset oa = truncate(a.key);
        CycleOffset ob = truncate(b.key);

        Bit#(2) ga = truncate(a.key >> 16);
        Bit#(2) gb = truncate(b.key >> 16);

        return case (gb - ga)
            2'b11: False;  // gb == ga - 1
            2'b00: (oa < ob); // gb == ga
            2'b01: True; // gb == ga + 1
            2'b10: ?; // should not happen: we're overlapping only 2 cycles, so gb - ga can only be (-1, 0, 1)
        endcase;*/
    endfunction
endinstance
