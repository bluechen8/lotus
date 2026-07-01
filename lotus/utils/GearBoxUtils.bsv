/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import Vector::*;

interface GearBoxL2S#(type large_t, type small_t, type smallIdx_t);
    method Action enq(large_t l);
    method Action deq();
    method Tuple3#(Bool, smallIdx_t, small_t) first;
endinterface


typedef union tagged {
    void                                IDLE;
    struct {word_t data; idx_t idx; }   FILLING;
} GBState#(type word_t, type idx_t) deriving (Bits, Eq, FShow);

module mkGearBoxL2S(GearBoxL2S#(large_t, small_t, smallIdx_t))
    provisos (Bits#(large_t   , largeBits),
              Bits#(small_t   , smallBits),
              Bits#(smallIdx_t, smallIdxBits),
              Div#(largeBits, smallBits, largeToSmallRatio),
              Log#(largeToSmallRatio, ratioIdxBits),
              Add#(ratioIdxBits, 0, smallIdxBits)
              );

    Reg#(GBState#(Vector#(largeToSmallRatio, small_t), smallIdx_t)) state <- mkReg(IDLE);

    Wire#(Bool) lastIdx <- mkDWire(False);

    rule doLastIdx;
        lastIdx <= case (state) matches
                       tagged IDLE: return False;
                       tagged FILLING {data: .*, idx: .idx}: return idx == (valueOf(largeToSmallRatio)-1);
                   endcase;
    endrule

    method Action enq(large_t i) if (state matches IDLE);
        state <= FILLING {data: unpack(pack(i)), idx: 0};
    endmethod

    method Action deq if (state matches FILLING {data: .d, idx: .idx});
        state <= case (lastIdx) matches
                     True : return IDLE;
                     False: return FILLING {data: d, idx: (idx+1)};
                 endcase;
    endmethod

    method Tuple3#(Bool, smallIdx_t, small_t) first if (state matches FILLING {data: .d, idx: .idx});
        return tuple3(lateIdx, idx, d[idx]);
    endmethod

endmodule
