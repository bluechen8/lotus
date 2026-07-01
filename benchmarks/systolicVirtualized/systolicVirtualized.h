/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#ifndef SYSTOLICVIRTUALIZED_H_
#define SYSTOLICVIRTUALIZED_H_

#include <bit>
#include "lotus_task_api.h"

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

TASK mac4x4(
            ARG(IN   , FULL, VAL_TYPE) a0_in,
            ARG(IN   , FULL, VAL_TYPE) a1_in,
            ARG(IN   , FULL, VAL_TYPE) a2_in,
            ARG(IN   , FULL, VAL_TYPE) a3_in,

            ARG(IN   , FULL, VAL_TYPE) b0_in,
            ARG(IN   , FULL, VAL_TYPE) b1_in,
            ARG(IN   , FULL, VAL_TYPE) b2_in,
            ARG(IN   , FULL, VAL_TYPE) b3_in,

            ARG(IN, FULL, ACCUM_TYPE) accum0_in,
            ARG(IN, FULL, ACCUM_TYPE) accum1_in,
            ARG(IN, FULL, ACCUM_TYPE) accum2_in,
            ARG(IN, FULL, ACCUM_TYPE) accum3_in,
            ARG(IN, FULL, ACCUM_TYPE) accum4_in,
            ARG(IN, FULL, ACCUM_TYPE) accum5_in,
            ARG(IN, FULL, ACCUM_TYPE) accum6_in,
            ARG(IN, FULL, ACCUM_TYPE) accum7_in,
            ARG(IN, FULL, ACCUM_TYPE) accum8_in,
            ARG(IN, FULL, ACCUM_TYPE) accum9_in,
            ARG(IN, FULL, ACCUM_TYPE) accum10_in,
            ARG(IN, FULL, ACCUM_TYPE) accum11_in,
            ARG(IN, FULL, ACCUM_TYPE) accum12_in,
            ARG(IN, FULL, ACCUM_TYPE) accum13_in,
            ARG(IN, FULL, ACCUM_TYPE) accum14_in,
            ARG(IN, FULL, ACCUM_TYPE) accum15_in,

            ARG(OUT, FULL, ACCUM_TYPE) accum0,
            ARG(OUT, FULL, ACCUM_TYPE) accum1,
            ARG(OUT, FULL, ACCUM_TYPE) accum2,
            ARG(OUT, FULL, ACCUM_TYPE) accum3,
            ARG(OUT, FULL, ACCUM_TYPE) accum4,
            ARG(OUT, FULL, ACCUM_TYPE) accum5,
            ARG(OUT, FULL, ACCUM_TYPE) accum6,
            ARG(OUT, FULL, ACCUM_TYPE) accum7,
            ARG(OUT, FULL, ACCUM_TYPE) accum8,
            ARG(OUT, FULL, ACCUM_TYPE) accum9,
            ARG(OUT, FULL, ACCUM_TYPE) accum10,
            ARG(OUT, FULL, ACCUM_TYPE) accum11,
            ARG(OUT, FULL, ACCUM_TYPE) accum12,
            ARG(OUT, FULL, ACCUM_TYPE) accum13,
            ARG(OUT, FULL, ACCUM_TYPE) accum14,
            ARG(OUT, FULL, ACCUM_TYPE) accum15,

            ARG(OUT  , FULL, VAL_TYPE) a0_out,
            ARG(OUT  , FULL, VAL_TYPE) a1_out,
            ARG(OUT  , FULL, VAL_TYPE) a2_out,
            ARG(OUT  , FULL, VAL_TYPE) a3_out,
            ARG(OUT  , FULL, VAL_TYPE) b0_out,
            ARG(OUT  , FULL, VAL_TYPE) b1_out,
            ARG(OUT  , FULL, VAL_TYPE) b2_out,
            ARG(OUT  , FULL, VAL_TYPE) b3_out
           ) {
    accum0   = accum0_in;
    accum1   = accum1_in;
    accum2   = accum2_in;
    accum3   = accum3_in;
    accum4   = accum4_in;
    accum5   = accum5_in;
    accum6   = accum6_in;
    accum7   = accum7_in;
    accum8   = accum8_in;
    accum9   = accum9_in;
    accum10  = accum10_in;
    accum11  = accum11_in;
    accum12  = accum12_in;
    accum13  = accum13_in;
    accum14  = accum14_in;
    accum15  = accum15_in;

    auto mac = [](const VAL_TYPE& a, const VAL_TYPE& b, ACCUM_TYPE& accum) {
        accum += MULT(a, b);
    };

    mac(a0_in, b0_in, accum0);
    mac(a0_in, b1_in, accum1);
    mac(a0_in, b2_in, accum2);
    mac(a0_in, b3_in, accum3);

    mac(a1_in, b0_in, accum4);
    mac(a1_in, b1_in, accum5);
    mac(a1_in, b2_in, accum6);
    mac(a1_in, b3_in, accum7);

    mac(a2_in, b0_in, accum8);
    mac(a2_in, b1_in, accum9);
    mac(a2_in, b2_in, accum10);
    mac(a2_in, b3_in, accum11);

    mac(a3_in, b0_in, accum12);
    mac(a3_in, b1_in, accum13);
    mac(a3_in, b2_in, accum14);
    mac(a3_in, b3_in, accum15);

    a0_out = a0_in;
    a1_out = a1_in;
    a2_out = a2_in;
    a3_out = a3_in;

    b0_out = b0_in;
    b1_out = b1_in;
    b2_out = b2_in;
    b3_out = b3_in;
}

TASK forwardReg(
                ARG(IN   , FULL, VAL_TYPE) a0_in,
                ARG(IN   , FULL, VAL_TYPE) a1_in,
                ARG(IN   , FULL, VAL_TYPE) a2_in,
                ARG(IN   , FULL, VAL_TYPE) a3_in,

                ARG(OUT  , FULL, VAL_TYPE) a0_out,
                ARG(OUT  , FULL, VAL_TYPE) a1_out,
                ARG(OUT  , FULL, VAL_TYPE) a2_out,
                ARG(OUT  , FULL, VAL_TYPE) a3_out
                ) {
    a0_out = a0_in;
    a1_out = a1_in;
    a2_out = a2_in;
    a3_out = a3_in;
}

TASK feedInput(
               ARG(IN, FULL, Word) idx_in,
               ARG(OUT, FULL, Word) idx_out,
               ARG(OUT, FULL, VAL_TYPE) idx_out0,
               ARG(OUT, FULL, VAL_TYPE) idx_out1,
               ARG(OUT, FULL, VAL_TYPE) idx_out2,
               ARG(OUT, FULL, VAL_TYPE) idx_out3
              ) {
    idx_out0 = (VAL_TYPE) idx_in;
    idx_out1 = (VAL_TYPE) idx_in+1;
    idx_out2 = (VAL_TYPE) idx_in+2;
    idx_out3 = (VAL_TYPE) idx_in+3;

    idx_out  = idx_in + 4;
}


#endif // SYSTOLICVIRTUALIZED_H_
