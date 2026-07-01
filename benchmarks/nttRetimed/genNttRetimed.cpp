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

#include <iostream>
#include <string_view>
#include <array>
#include <set>
#include <cstddef>

#include "taskflow.h"
#include "nttRetimed.h"

using namespace taskflow;
using namespace std;
using std::set;
using std::tuple;

int main(int argc, char* argv[]) {
    assert(argc == 2);
    size_t width = std::stoi(argv[1]);
    assert(width > 0 && (width & (width - 1)) == 0);

    size_t numStages = std::bit_width(width) - 1;

    std::vector<std::vector<Reg<Word>>> pipeRegs;
    pipeRegs.resize(numStages+1);
    for (uint32_t stage = 0; stage <= numStages; stage++) {
        for (uint32_t n = 0; n < width; n++) {
            pipeRegs[stage].emplace_back(0);
        }
    }

    std::vector<std::vector<Reg<Word>>> twiddles;
    twiddles.resize(numStages);
    for (uint32_t stage = 0; stage < numStages; stage++) {
        for (uint32_t n = 0; n < width/2; n++) {
            twiddles[stage].emplace_back(stage);
        }
    }

    for (uint32_t n = 0; n < width/2; n++) {
        Reg<Word> inIdx(n);
        task(feedInputs, inIdx, pipeRegs[0][2*n], pipeRegs[0][2*n+1]);
    }

    // auto print_visualization = [](uint32_t numStages, uint32_t N, const set<tuple<uint32_t, uint32_t>>& inputs, const set<tuple<uint32_t, uint32_t>>& outputs) {

    //     vector<vector<string>> matrix;
    //     for (uint32_t stage = 0; stage < numStages; stage++) {
    //         vector<string> row;
    //         row.resize(N);
    //         for (uint32_t n = 0; n < N; n++) {
    //             if (inputs.find(make_tuple(stage, n)) != inputs.end()) {
    //                 row[n] = "I";
    //             } else if (outputs.find(make_tuple(stage, n)) != outputs.end()) {
    //                 row[n] = "O";
    //             } else {
    //                 row[n] = "-";
    //             }
    //         }
    //         matrix.push_back(row);
    //     }

    //     for (const auto& row : matrix) {
    //         for (const auto& v : row) {
    //             std::cout << v << " ";
    //         }
    //         std::cout << "\n";
    //     }

    //     std::cout << std::endl;

    // };

    size_t stride = width/2;
    for (uint32_t stage = 0; stage < numStages; stage++) {
        for (uint32_t n = 0; n < width/2; n++) {
            size_t outIdx0, outIdx1;
            if (n % stride < (stride/2)) {
                outIdx0 = 2*n;
                outIdx1 = 2*n + stride;
            } else {
                outIdx0 = 2*n + 1 - stride;
                outIdx1 = 2*n + 1;
            }

            if (stage == (numStages-1)) {
                task(ntt2,
                     pipeRegs[stage][2*n],
                     pipeRegs[stage][2*n+1],

                     twiddles[stage][n],

                     pipeRegs[stage+1][outIdx0],
                     pipeRegs[stage+1][outIdx1]);

            } else if ((stage&0x1) == 0) {
                // printf("===== twoNtt2 (%u, %u)\n", stage, n);
                // print_visualization(numStages+1, width, {{stage, 2*n}, {stage, 2*n+1}}, {{stage+1, outIdx0}, {stage+1, outIdx1}});
                task(twoNtt2,
                     pipeRegs[stage][2*n],
                     pipeRegs[stage][2*n+1],

                     twiddles[stage][n],
                     twiddles[stage+1][n],

                     pipeRegs[stage+1][outIdx0],
                     pipeRegs[stage+1][outIdx1]);
            } else {
                // printf("===== forwardReg (%u, %u)\n", stage, n);
                // print_visualization(numStages+1, width, {{stage, 2*n}, {stage, 2*n+1}}, {{stage+1, outIdx0}, {stage+1, outIdx1}});
                task(forwardReg,
                     pipeRegs[stage][2*n],
                     pipeRegs[stage][2*n+1],

                     pipeRegs[stage+1][outIdx0],
                     pipeRegs[stage+1][outIdx1]);

            }
        }
        stride = stride/2;
    }

    // for (uint32_t n = 0; n < width/2; n++) {
    //     Reg outIdx(n);
    //     task(checkOutputs, pipeRegs[numStages][2*n], pipeRegs[numStages][2*n+1], outIdx);
    // }

    return 0;
}
