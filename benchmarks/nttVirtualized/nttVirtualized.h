/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


#include "lotus_task_api.h"

// Basic modular arithmetic
static __INLINE_ATTR__ Word modAdd(Word a, Word b, Word q) {
    Word s = a + b;
    return (s >= q)? (s - q)  : s;
}

static __INLINE_ATTR__ Word modSub(Word a, Word b, Word q) {
    Word s = a - b;
    return (s >= q)? (s - q)  : s;
}

// Montgomery multiplication
// See https://cp-algorithms.com/algebra/montgomery_multiplication.html; adapted to 32-bit words
constexpr Word computeInv(Word q) {
    Word inv = 1;
    for (int i = 0; i < 7; i++) {
        inv *= 2 - q * inv;
    }
    return inv;
}

static __INLINE_ATTR__ DWord intMult(Word a, Word b) { return ((DWord) a) * ((DWord) b); }

static __INLINE_ATTR__ Word modMultMontgomery(Word a, Word b, Word q, Word inv) {
    DWord prod = intMult(a, b);
    Word u = (((Word) prod)) * inv;
    Word y = ((Word) (prod >> WORD_BITS)) - ((Word) (intMult(u, q) >> WORD_BITS));
    return (y >= q)? (y - q) : y;
}

// We use a fixed modulus in this test
constexpr Word Q = 10223617;
static_assert(WORD_BITS == 32 && sizeof(Word) * 8 == WORD_BITS, "NTT Montgomery parameters assume 32-bit Word");
constexpr Word Q_INV = computeInv(Q);
static_assert(static_cast<Word>(Q * Q_INV) == 1, "Q_INV must be Q^-1 modulo 2^WORD_BITS");

/* Tasks */

TASK ntt2(
          ARG(IN, FULL, Word) i0, ARG(IN, FULL, Word) i1, ARG(IN, FULL, Word) twiddle,
          ARG(OUT, FULL, Word) o0, ARG(OUT, FULL, Word) o1) {
    o0 = modAdd(i0, i1, Q);
    Word diff = modSub(i0, i1, Q);
    o1 = modMultMontgomery(diff, twiddle, Q, Q_INV);
}

TASK nttTwo_helper(const Word& i0, const Word& i1, const Word& twiddle,
                       Word& o0, Word& o1) {
    o0 = modAdd(i0, i1, Q);
    Word diff = modSub(i0, i1, Q);
    o1 = modMultMontgomery(diff, twiddle, Q, Q_INV);
};

TASK twoNtt2(
             ARG(IN, FULL, Word) i0,
             ARG(IN, FULL, Word) i1,
             ARG(IN, FULL, Word) twiddle0,
             ARG(IN, FULL, Word) twiddle1,
             ARG(OUT, FULL, Word) o0,
             ARG(OUT, FULL, Word) o1) {


    Word reg_o0;
    Word reg_o1;
    nttTwo_helper(i0    , i1    , twiddle0, reg_o0, reg_o1);
    nttTwo_helper(reg_o0, reg_o1, twiddle1, o0    , o1    );
}
TASK fourNtt2(
             ARG(IN, FULL, Word) i0,
             ARG(IN, FULL, Word) i1,
             ARG(IN, FULL, Word) i2,
             ARG(IN, FULL, Word) i3,
             ARG(IN, FULL, Word) twiddle0,
             ARG(IN, FULL, Word) twiddle1,
             ARG(IN, FULL, Word) twiddle2,
             ARG(IN, FULL, Word) twiddle3,
             ARG(OUT, FULL, Word) o0,
             ARG(OUT, FULL, Word) o1,
             ARG(OUT, FULL, Word) o2,
             ARG(OUT, FULL, Word) o3
) {


    Word temp_o0;
    Word temp_o1;
    Word temp_o2;
    Word temp_o3;
    nttTwo_helper(i0      , i1      , twiddle0, temp_o0, temp_o1);
    nttTwo_helper(i2      , i3      , twiddle1, temp_o2, temp_o3);
    nttTwo_helper(temp_o0 , temp_o2 , twiddle2, o0, o1);
    nttTwo_helper(temp_o1 , temp_o3 , twiddle3, o2, o3);
}

TASK forwardReg(
                ARG(IN   , FULL, Word) a0_in,
                ARG(IN   , FULL, Word) a1_in,

                ARG(OUT  , FULL, Word) a0_out,
                ARG(OUT  , FULL, Word) a1_out
                ) {
    a0_out = a0_in;
    a1_out = a1_in;
}

TASK feedInputs(
                ARG(IN, FULL, Word) idx_in,
                ARG(OUT, FULL, Word) idx_out,
                ARG(OUT, FULL, Word) o0, ARG(OUT, FULL, Word) o1) {
    // o0 = modAdd(idx, idx, Q);
    // o1 = modAdd(idx, idx + 1, Q);
    o0 = idx_in;
    o1 = idx_in+1;
    idx_out = idx_in + (1 << 16);
}

// Check test outputs
TASK checkOutputs(
        ARG(IN, FULL, Word) o0,  ARG(IN, FULL, Word) o1,
        ARG(IN , FULL, Word) idx_in,
        ARG(OUT, FULL, Word) idx_out) {
    // TODO: Check values against a reference result in memory
    idx_out = idx_in + 16384;
}


