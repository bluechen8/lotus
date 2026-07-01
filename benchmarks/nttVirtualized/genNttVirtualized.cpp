/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

//#include "lotus_api.h"

#include <stdint.h>
#include <tuple>
#include <vector>
#include <bit>
#include <type_traits>
#include <assert.h>
#include <algorithm>

#include <iostream>
#include <string_view>
#include <array>
#include <cstddef>

#include "taskflow.h"
#include "nttVirtualized.h"

using namespace taskflow;

void implement_coarsened(size_t width) {
    size_t numStages = std::bit_width(width) - 1;

    std::vector<std::vector<Reg<Word>>> pipeRegs;
    pipeRegs.resize(numStages+1);
    for (uint32_t stage = 0; stage <= numStages; stage++)
        for (uint32_t n = 0; n < width; n++)
            pipeRegs[stage].emplace_back(0);

    std::vector<std::vector<Reg<Word>>> twiddles;
    twiddles.resize(numStages);
    for (uint32_t stage = 0; stage < numStages; stage++)
        for (uint32_t n = 0; n < width/2; n++)
            twiddles[stage].emplace_back(stage);

    for (uint32_t n = 0; n < width/2; n++) {
        Reg<Word> inIdx(n);
        task(feedInputs, inIdx, inIdx, pipeRegs[0][2*n], pipeRegs[0][2*n+1]);
    }

    size_t stride = width/2;
    for (uint32_t stage = 0; stage < numStages; stage+=2) {
        bool lastStage = (stage == numStages - 1);

        if (lastStage) {
            for (uint32_t n = 0; n < width/2; n++) {
                size_t outIdx0, outIdx1;
                if (n % stride < (stride/2)) {
                    outIdx0 = 2*n;
                    outIdx1 = 2*n + stride;
                } else {
                    outIdx0 = 2*n + 1 - stride;
                    outIdx1 = 2*n + 1;
                }
                task(ntt2,
                     pipeRegs[stage][2*n], pipeRegs[stage][2*n+1],
                     twiddles[stage][n],
                     pipeRegs[stage+1][outIdx0], pipeRegs[stage+1][outIdx1]);
            }
            stride /= 2;
        } else {
            size_t stride2 = stride/2;
            for (uint32_t block = 0; block < width/2; block += stride) {
                for (uint32_t n = block; n < block + stride/2; n++) {
                    size_t m = n + stride/2;

                    size_t outIdx0_n, outIdx1_n;
                    if (n % stride < (stride/2)) {
                        outIdx0_n = 2*n;
                        outIdx1_n = 2*n + stride;
                    } else {
                        outIdx0_n = 2*n + 1 - stride;
                        outIdx1_n = 2*n + 1;
                    }

                    size_t outIdx0_m, outIdx1_m;
                    if (m % stride < (stride/2)) {
                        outIdx0_m = 2*m;
                        outIdx1_m = 2*m + stride;
                    } else {
                        outIdx0_m = 2*m + 1 - stride;
                        outIdx1_m = 2*m + 1;
                    }

                    size_t p = std::min(outIdx0_n, outIdx0_m) / 2;
                    size_t q = std::min(outIdx1_n, outIdx1_m) / 2;

                    size_t finalIdx0_p, finalIdx1_p, finalIdx0_q, finalIdx1_q;
                    if (p % stride2 < (stride2/2)) {
                        finalIdx0_p = 2*p;
                        finalIdx1_p = 2*p + stride2;
                    } else {
                        finalIdx0_p = 2*p + 1 - stride2;
                        finalIdx1_p = 2*p + 1;
                    }
                    if (q % stride2 < (stride2/2)) {
                        finalIdx0_q = 2*q;
                        finalIdx1_q = 2*q + stride2;
                    } else {
                        finalIdx0_q = 2*q + 1 - stride2;
                        finalIdx1_q = 2*q + 1;
                    }

                    task(fourNtt2,
                         pipeRegs[stage][2*n],   pipeRegs[stage][2*n+1],
                         pipeRegs[stage][2*m],   pipeRegs[stage][2*m+1],
                         twiddles[stage][n],     twiddles[stage][m],
                         twiddles[stage+1][p],   twiddles[stage+1][q],
                         pipeRegs[stage+2][finalIdx0_p], pipeRegs[stage+2][finalIdx1_p],
                         pipeRegs[stage+2][finalIdx0_q], pipeRegs[stage+2][finalIdx1_q]);
                }
            }
            stride /= 4;
        }
    }
}

int main(int argc, char* argv[]) {
    assert(argc == 2);
    size_t width = std::stoi(argv[1]);
    assert(width > 0 && (width & (width - 1)) == 0);
    implement_coarsened(width);
    return 0;
}
