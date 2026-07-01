/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Vector::*;
import CommitIfc::*;

function Maybe#(b_type) mapMaybeFail(function Maybe#(b_type) f(a_type x), Maybe#(a_type) am);
    return case (am) matches
               tagged Valid .a: return f(a);
               tagged Invalid: return tagged Invalid;
           endcase;
endfunction

function Maybe#(b_type) mapMaybe(function b_type f(a_type x), Maybe#(a_type) am);
    return case (am) matches
               tagged Valid .a: return tagged Valid f(a);
               tagged Invalid: return tagged Invalid;
           endcase;
endfunction

function Bool testMaybe(function Bool f(a_type x), Maybe#(a_type) am);
    return case (am) matches
               tagged Valid .a: return f(a);
               tagged Invalid: return False;
           endcase;
endfunction

function c_type invertArgs2(function c_type f(a_type aa, b_type bb), b_type b, a_type a);
    return f(a, b);
endfunction

function Vector#(2, some_type) createVec2(some_type a, some_type b);
    return cons(a, cons(b, nil));
endfunction

function a_type boolSel(Bool sel, a_type a, a_type b) = sel ? a : b;

function Maybe#(a_type) makeMaybe(a_type a) = tagged Valid a;

function a_type readWire(Wire#(a_type) a) = a;


function Maybe#(a_type) maybeOr(Maybe#(a_type) a, Maybe#(a_type) aa);
    if (a matches tagged Valid .z)
        return a;
    else if (aa matches tagged Valid .z)
        return aa;
    else
        return tagged Invalid;
endfunction

function Maybe#(c_type) maybeAnd2(function c_type f(a_type z, b_type zz), Maybe#(a_type) a, Maybe#(b_type) b);
    if (a matches tagged Valid .aa &&& b matches tagged Valid .bb)
        return tagged Valid f(aa, bb);
    else
        return tagged Invalid;
endfunction

function Maybe#(c_type) maybeAndFail2(function Maybe#(c_type) f(a_type z, b_type zz), Maybe#(a_type) a, Maybe#(b_type) b);
    if (a matches tagged Valid .aa &&& b matches tagged Valid .bb)
        return f(aa, bb);
    else
        return tagged Invalid;
endfunction

function Bit#(m) expandX(Bit#(n) i) provisos(Add#(n, x, m));
    return {?, i};
endfunction

function Bit#(n) toBit(UInt#(n) i);
    return unpack(pack(i));
endfunction

function Maybe#(data_t) toMaybe(data_t din);
    return Valid(din);
endfunction



// NOTE: Needed before "or" isn't working
function Bool isTrue(Bool x) = x;

import GetPut::*;
module mkBroadcastSingle#(Bit#(m) id, Maybe#(t) inM, Integer myId) (Get#(t));
    Bool m = (fromInteger(myId) == id);
    method ActionValue#(t) get if (m &&& inM matches tagged Valid .in);
        return in;
    endmethod
endmodule

module mkBroadcast#(Bit#(m) id, Maybe#(t) inM)(Vector#(count, Get#(t)));
    Vector#(count, Get#(t)) b <- genWithM(mkBroadcastSingle(id, inM));
    return b;
endmodule


// Map Get
module mapGet#(function b_type doF(a_type a), Get#(a_type) aGet)(Get#(b_type));
    method ActionValue#(b_type) get;
        let a <- aGet.get;
        b_type b = doF(a);
        return b;
    endmethod
endmodule


