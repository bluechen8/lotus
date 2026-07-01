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
#include <sstream>

#include "taskflow.h"
#include "systolic.h"

using namespace taskflow;

std::vector<std::vector<ACCUM_TYPE>> simulateSystolic(uint32_t N, uint32_t cycles);

int main(int argc, char* argv[]) {
    assert(argc == 2);
    uint32_t N = std::stoi(argv[1]);
    assert(N > 0 && (N & (N - 1)) == 0);

    std::vector<Reg<VAL_TYPE>> a_ins; // N
    std::vector<Reg<VAL_TYPE>> b_ins; // N

    std::vector<Reg<VAL_TYPE>> a_outs; // N
    std::vector<Reg<VAL_TYPE>> b_outs; // N

    std::vector<std::vector<Reg<VAL_TYPE>>> a_feeders; // N x (N-1)
    std::vector<std::vector<Reg<VAL_TYPE>>> b_feeders; // N x (N-1)

    std::vector<std::vector<Reg<ACCUM_TYPE>>> mac_accums; // N x N

    // ins + outs
    for (uint32_t i = 0; i < N; i++) {
        a_ins.emplace_back(0);
        b_ins.emplace_back(0);
        a_outs.emplace_back(0);
        b_outs.emplace_back(0);
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
    for (uint32_t i = 0; i < N; i++) {
        {
            Reg<Word> inIdx(i);
            {
                std::ostringstream oss;
                oss << "a_feedInputs[" << i << "]";
                next_task_label(oss.str());
            }
            task(feedInput, inIdx, inIdx, a_ins[i]);

        }
        {
            Reg<Word> inIdx(i);
            {
                std::ostringstream oss;
                oss << "b_feedInputs[" << i << "]";
                next_task_label(oss.str());
            }
            task(feedInput, inIdx, inIdx, b_ins[i]);
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
    for (uint32_t i = 0; i < N; i++) {
        for (uint32_t j = 0; j < N; j++) {
            // Reg<Word> ir(i);
            // Reg<Word> jr(j);
            {
                std::ostringstream oss;
                oss << "mac[" << i << ", " << j << "]";
                next_task_label(oss.str());
            }
            task(mac,
                 // ir, jr,
                 get_a_in(i, j), get_b_in(i, j),
                 mac_accums[i][j],
                 mac_accums[i][j],
                 get_a_out(i, j), get_b_out(i, j));
        }
    }


#ifdef CHECK_OUTPUTS
    std::vector<std::vector<ACCUM_TYPE>> refs = simulateSystolic(N, CHECK_AFTER_N_CYCLES);
    // checkOutputs
    for (uint32_t i = 0; i < N; i++) {
        for (uint32_t j = 0; j < N; j++) {
            Reg<Word> cycleId(0);
            Reg<ACCUM_TYPE> ref(refs[i][j]);
            // Reg<Word> ir(i);
            // Reg<Word> jr(j);
            {
                std::ostringstream oss;
                oss << "checkOutputs[" << i << ", " << j << "]";
                next_task_label(oss.str());
            }
            task(checkOutputs,
                 // ir, jr,
                 cycleId,
                 ref,
                 mac_accums[i][j],
                 cycleId);
        }
    }
#endif


    return 0;
}

std::vector<std::vector<ACCUM_TYPE>> simulateSystolic(uint32_t N, uint32_t cycles) {
    // Current register state
    std::vector<VAL_TYPE>   a_ins(N, 0), b_ins(N, 0);
    std::vector<std::vector<VAL_TYPE>> a_feeders(N, std::vector<VAL_TYPE>(N-1, 0));
    std::vector<std::vector<VAL_TYPE>> b_feeders(N, std::vector<VAL_TYPE>(N-1, 0));
    std::vector<std::vector<ACCUM_TYPE>> mac_accums(N, std::vector<ACCUM_TYPE>(N, 0));
    std::vector<Word> a_idx(N), b_idx(N);
    for (uint32_t i = 0; i < N; i++) {
        a_ins[i] = (VAL_TYPE)i;
        b_ins[i] = (VAL_TYPE)i;
        a_idx[i] = i + 1;
        b_idx[i] = i + 1;
    }

    std::vector<std::vector<ACCUM_TYPE>> prev_mac_accums = mac_accums;
    for (uint32_t cycle = 0; cycle < cycles; cycle++) {
        prev_mac_accums = mac_accums;
        // Next register state
        std::vector<VAL_TYPE>   next_a_ins(N, 0), next_b_ins(N, 0);
        std::vector<std::vector<VAL_TYPE>> next_a_feeders(N, std::vector<VAL_TYPE>(N-1, 0));
        std::vector<std::vector<VAL_TYPE>> next_b_feeders(N, std::vector<VAL_TYPE>(N-1, 0));
        std::vector<std::vector<ACCUM_TYPE>> next_mac_accums(N, std::vector<ACCUM_TYPE>(N, 0));
        std::vector<Word> next_a_idx(N), next_b_idx(N);

        // feedInput for each row -> a_ins[i]
        for (uint32_t i = 0; i < N; i++)
            feedInput(a_idx[i], next_a_idx[i], next_a_ins[i]);

        // feedInput for each col -> b_ins[j]
        for (uint32_t j = 0; j < N; j++)
            feedInput(b_idx[j], next_b_idx[j], next_b_ins[j]);

        // MAC grid
        for (uint32_t i = 0; i < N; i++) {
            for (uint32_t j = 0; j < N; j++) {
                VAL_TYPE a_in  = (j == 0) ? a_ins[i] : a_feeders[i][j-1];
                VAL_TYPE b_in  = (i == 0) ? b_ins[j] : b_feeders[j][i-1];

                VAL_TYPE a_out, b_out;
                ACCUM_TYPE sum_out;
                mac(
                    //i, j,
                    a_in, b_in, mac_accums[i][j], sum_out, a_out, b_out
                   );

                next_mac_accums[i][j] = sum_out;

                // a_out goes to next feeder, or is discarded at the edge
                if (j < N-1) next_a_feeders[i][j] = a_out;
                // b_out goes to next feeder, or is discarded at the edge
                if (i < N-1) next_b_feeders[j][i] = b_out;
            }
        }

        // Commit
        a_ins      = next_a_ins;
        b_ins      = next_b_ins;
        a_feeders  = next_a_feeders;
        b_feeders  = next_b_feeders;
        mac_accums = next_mac_accums;
        a_idx      = next_a_idx;
        b_idx      = next_b_idx;
    }

    return prev_mac_accums;
}
