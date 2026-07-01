/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#ifndef SYSTOLIC_H_
#define SYSTOLIC_H_

#include <cstdint>
#include <tuple>
#include <bit>
#include <cstdio>

#include "lotus_task_api.h"

#define CHECK_AFTER_N_CYCLES 1000

#ifdef __riscv
    #define ASSERT(x) if (!(x)) lotus::simFail();
#else
    #define ASSERT(x) assert(x);
#endif

// #define DO_FLOAT

#ifdef DO_FLOAT

    #define VAL_TYPE uint16_t
    #define ACCUM_TYPE float

    inline float convert_bf16_to_float(VAL_TYPE bf16) {
        return std::bit_cast<ACCUM_TYPE>(static_cast<uint32_t>(bf16) << 16);
    }

    #define MULT(a, b) (convert_bf16_to_float(a) * convert_bf16_to_float(b))

#else

    #define VAL_TYPE int8_t
    #define ACCUM_TYPE int32_t

    #define MULT(a, b) ((a) * (b))

#endif

TASK mac(
         //ARG(IN , FULL, Word)       i,
         //ARG(IN , FULL, Word)       j,
         ARG(IN, FULL, VAL_TYPE) a_in, ARG(IN, FULL, VAL_TYPE) b_in,
         ARG(IN, FULL, ACCUM_TYPE) sum_in,
         ARG(OUT, FULL, ACCUM_TYPE) sum_out,
         ARG(OUT, FULL, VAL_TYPE) a_out, ARG(OUT, FULL, VAL_TYPE) b_out) {
    sum_out = sum_in + MULT(a_in, b_in);
    //printf("[DEBUG] [mac %u, %u] a_in: %d, b_in: %d, sum_in: %d, sum_out: %d\n", i, j, a_in, b_in, sum_in, sum_out);
    a_out = a_in;
    b_out = b_in;
}

TASK feedInput(ARG(IN, FULL, Word) idx_in, ARG(OUT, FULL, Word) idx_out, ARG(OUT, FULL, VAL_TYPE) output) {
    output = (VAL_TYPE) idx_in;
    idx_out  = idx_in + 1;
}

TASK checkOutputs(
    //ARG(IN , FULL, Word)       i,
    //ARG(IN , FULL, Word)       j,
    ARG(IN , FULL, Word)       cycleId,
    ARG(IN , FULL, ACCUM_TYPE) ref_accum,
    ARG(IN , FULL, ACCUM_TYPE) real_accum,
    ARG(OUT, FULL, Word)       cycleId_out

) {

    if (cycleId == CHECK_AFTER_N_CYCLES) {
        bool pass = ref_accum == real_accum;
        //printf("[DEBUG] [checkOutputs %u, %u] comparing: ref=%d with accum=%d\n", i, j, ref_accum, real_accum);
        ASSERT(pass);
    }
    //else if (cycleId > CHECK_AFTER_N_CYCLES) {
    //    ASSERT(false && "PASS");
    //}

    cycleId_out = cycleId + 1;
}

#endif // SYSTOLIC_H_
