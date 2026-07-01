/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


#include <stdint.h>
#include <tuple>
#include <vector>
#include <bit>
#include <type_traits>
#include <assert.h>

#include <iostream>
#include <string_view>
#include <array>
#include <cstddef>

#include "taskflow.h"
#include "systolicVirtualized.h"

using namespace taskflow;

void generate_virtual_cycle(uint32_t N) {
    std::vector<Reg<VAL_TYPE>> a_ins; // N
    std::vector<Reg<VAL_TYPE>> b_ins; // N

    std::vector<Reg<VAL_TYPE>> a_outs; // N
    std::vector<Reg<VAL_TYPE>> b_outs; // N


    std::vector<std::vector<Reg<VAL_TYPE>>> a_feeders; // N x (N-1)
    std::vector<std::vector<Reg<VAL_TYPE>>> b_feeders; // N x (N-1)

    std::vector<std::vector<Reg<ACCUM_TYPE>>> mac_accums; // N x N

    // ins + outs
    for (uint32_t i = 0; i < N; i++) {
        a_ins.emplace_back(i);
        b_ins.emplace_back(i);
        a_outs.emplace_back(i);
        b_outs.emplace_back(i);
    }

    // feeders
    a_feeders.resize(N);
    b_feeders.resize(N);
    for (uint32_t i = 0; i < N; i++) {
        for (uint32_t j = 0; j < N-1; j++) {
            a_feeders[i].emplace_back(0);
            b_feeders[i].emplace_back(0);
        }
    }

    // accums
    mac_accums.resize(N);
    for (uint32_t i = 0; i < N; i++) {
        for (uint32_t j = 0; j < N; j++) {
            mac_accums[i].emplace_back(0);
        }
    }


    // feedInput
    for (uint32_t i = 0; i < N; i+=4) {
        new_part_group();
        {
            new_coarse_group();
            Reg<Word> inIdx(i);
            task(feedInput, inIdx, inIdx, a_ins[i], a_ins[i+1], a_ins[i+2], a_ins[i+3]);

        }
        {
            new_coarse_group();
            Reg<Word> inIdx(i);
            task(feedInput, inIdx, inIdx, b_ins[i], b_ins[i+1], b_ins[i+2], b_ins[i+3]);
        }
    }

    // Left to right
    auto get_a_in = [&](uint32_t i, uint32_t j) -> Reg<VAL_TYPE>& {
        if (j == 0) return a_ins[i];
        j = j - 1;
        return a_feeders[i][j];
    };
    auto get_a_out = [&](uint32_t i, uint32_t j) -> Reg<VAL_TYPE>& {
        if (j == (N-1)) return a_outs[i];
        return a_feeders[i][j];
    };
    // Top to down
    auto get_b_in = [&](uint32_t i, uint32_t j) -> Reg<VAL_TYPE>& {
        if (i == 0) return b_ins[j];
        i = i - 1;
        return b_feeders[j][i];
    };
    auto get_b_out = [&](uint32_t i, uint32_t j) -> Reg<VAL_TYPE>& {
        if (i == (N-1)) return b_outs[j];
        return b_feeders[j][i];
    };

    // macs
    uint32_t nTasks = 0;
    for (uint32_t i = 0; i < N; i += 4) {
        for (uint32_t j = 0; j < N; j += 4) {
            if ((nTasks % 4) == 0) {
                new_coarse_group();
                new_part_group();
            }
            nTasks += 1;
            task(mac4x4,
                // A inputs (left edge of this 4x4 tile)
                get_a_in(i+0, j+0),
                get_a_in(i+1, j+0),
                get_a_in(i+2, j+0),
                get_a_in(i+3, j+0),

                // B inputs (top edge of this 4x4 tile)
                get_b_in(i+0, j+0),
                get_b_in(i+0, j+1),
                get_b_in(i+0, j+2),
                get_b_in(i+0, j+3),

                // 16 accumulators (row-major over the 4x4 block)
                // Inputs
                mac_accums[i+0][j+0], mac_accums[i+0][j+1], mac_accums[i+0][j+2], mac_accums[i+0][j+3],
                mac_accums[i+1][j+0], mac_accums[i+1][j+1], mac_accums[i+1][j+2], mac_accums[i+1][j+3],
                mac_accums[i+2][j+0], mac_accums[i+2][j+1], mac_accums[i+2][j+2], mac_accums[i+2][j+3],
                mac_accums[i+3][j+0], mac_accums[i+3][j+1], mac_accums[i+3][j+2], mac_accums[i+3][j+3],
                // Outputs
                mac_accums[i+0][j+0], mac_accums[i+0][j+1], mac_accums[i+0][j+2], mac_accums[i+0][j+3],
                mac_accums[i+1][j+0], mac_accums[i+1][j+1], mac_accums[i+1][j+2], mac_accums[i+1][j+3],
                mac_accums[i+2][j+0], mac_accums[i+2][j+1], mac_accums[i+2][j+2], mac_accums[i+2][j+3],
                mac_accums[i+3][j+0], mac_accums[i+3][j+1], mac_accums[i+3][j+2], mac_accums[i+3][j+3],

                // A outputs (right edge of this 4x4 tile -> feeds next tile's left edge at j+4)
                get_a_out(i+0, j+3),
                get_a_out(i+1, j+3),
                get_a_out(i+2, j+3),
                get_a_out(i+3, j+3),

                // B outputs (bottom edge of this 4x4 tile -> feeds next tile's top edge at i+4)
                get_b_out(i+3, j+0),
                get_b_out(i+3, j+1),
                get_b_out(i+3, j+2),
                get_b_out(i+3, j+3)
            );
        }
        new_part_group();
        new_coarse_group();
    }

    // Verify output
    // for (uint32_t i = 0; i < N; i++) {
    //     for (uint32_t j = 0; j < N; j++) {
    //         Reg<Word> macIdx((i*N)+j);
    //         task(checkOutput, mac_accums[i][j], macIdx);
    //     }
    // }

}

int main(int argc, char* argv[]) {
    assert(argc == 2);
    uint32_t N = std::stoi(argv[1]);
    assert(N >= 4 && (N & (N - 1)) == 0);


    generate_virtual_cycle(N);
    generate_virtual_cycle(N);
    generate_virtual_cycle(N);
    generate_virtual_cycle(N);

    return 0;


}
