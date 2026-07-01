/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


#include "lotus_task_api.h"

#include <tuple>
#include <stdio.h>
#include <algorithm>

#define NUM_CYCLES_CHECKED 1000

#ifdef __riscv
    #define ASSERT(x) if (!(x)) lotus::simFail();
#else
    #define ASSERT(x) assert(x);
#endif

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

TASK ntt2(ARG(IN, FULL, Word) i0, ARG(IN, FULL, Word) i1, ARG(IN, FULL, Word) twiddle,
          ARG(OUT, FULL, Word) o0, ARG(OUT, FULL, Word) o1) {
    o0 = modAdd(i0, i1, Q);
    Word diff = modSub(i0, i1, Q);
    o1 = modMultMontgomery(diff, twiddle, Q, Q_INV);
    //printf("[DEBUG][ntt2] inputs: (%x, %x) -- twiddle: %x -- outputs: (%x, %x)\n", i0, i1, twiddle, o0, o1);
}

TASK feedInputs(ARG(IN, FULL, Word) idx_in,
                ARG(IN, FULL, Word) unroll_factor,
                ARG(OUT, FULL, Word) idx_out,
                ARG(OUT, FULL, Word) o0, ARG(OUT, FULL, Word) o1) {
    //Word unroll_factor = 1;
    // o0 = modAdd(idx, idx, Q);
    // o1 = modAdd(idx, idx + 1, Q);
    o0 = idx_in;
    o1 = idx_in+1;
    idx_out = idx_in + (unroll_factor << 16);
    //printf("[DEBUG][feedInputs] idx: (%x -> %x) -- Outs: (%x, %x)\n", idx_in, idx_out, o0, o1);
}

// Check test outputs
typedef std::array<std::tuple<Word, Word>, NUM_CYCLES_CHECKED> RefTable_t;

TASK checkOutputs(
        ARG(IN, FULL, Word) nId,
        ARG(IN, FULL, Word) cycleId,
        ARG(IN, FULL, Word) numStages,
        ARG(IN, PARTIAL, RefTable_t) refTable,
        ARG(IN, FULL, Word) o0,  ARG(IN, FULL, Word) o1,
        ARG(OUT, FULL, Word) cycleId_out) {


    //printf("[checkOutputs] (nId, cycleId, numStages, NUM_CYCLES_CHECKED) = (%x, %x, %x, %x) -- inputs = (%x, %x)\n", nId, cycleId, numStages, NUM_CYCLES_CHECKED, o0, o1);
    if (cycleId < NUM_CYCLES_CHECKED) {
        if (cycleId >= numStages){
            Word useIdx = cycleId - numStages;

            const std::tuple<Word, Word>& refs = refTable[useIdx];
            bool pass = (o0 == std::get<0>(refs)) && (o1 == std::get<1>(refs));
            //printf("[DEBUG][%u @ %u] Comparing (%x, %x) vs (%x, %x)\n", nId, cycleId, o0, o1, std::get<0>(refs), std::get<1>(refs));
            //if (!pass) {
            //    printf("[DEBUG]==== FAIL!! refTable: \n");
            //    for (int i = 0; i < std::min( (unsigned)refTable.size(), (unsigned) cycleId+10); i++) {
            //        const auto& r = refTable[i];
            //        printf("  [DEBUG][%d] (%x, %x)\n", i, std::get<0>(r), std::get<1>(r));
            //    }
            //}
            ASSERT(pass);
        }

        cycleId_out = cycleId + 1;
    } else {
        cycleId_out = cycleId;
    }
}
