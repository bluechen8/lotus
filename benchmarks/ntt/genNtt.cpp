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
#include <sstream>

#include "taskflow.h"
#include "ntt.h"

using namespace taskflow;
using std::set;
using std::tuple;


std::vector<std::vector<Word>> simulateNTTPipeline(size_t width, size_t numCycles);

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
            twiddles[stage].emplace_back(stage+1);
        }
    }

    for (uint32_t n = 0; n < width/2; n++) {
        Reg<Word> inIdx(n);
        next_var_is_unroll();
        Reg<Word> unrollFactor(1);
        {
            std::ostringstream oss;
            oss << "feedInputs[" << n << "]";
            next_task_label(oss.str());
        }
        task(feedInputs, inIdx, unrollFactor, inIdx, pipeRegs[0][2*n], pipeRegs[0][2*n+1]);
    }

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

            {
                std::ostringstream oss;
                oss << "ntt2[" << stage << ", " << n << "]";
                next_task_label(oss.str());
            }
            task(ntt2, pipeRegs[stage][2*n], pipeRegs[stage][2*n+1], twiddles[stage][n],
                       pipeRegs[stage+1][outIdx0], pipeRegs[stage+1][outIdx1]);
        }
        stride = stride/2;
    }

#ifdef CHECK_OUTPUTS
    std::vector<std::vector<Word>> outputs = simulateNTTPipeline(width, NUM_CYCLES_CHECKED);

    std::vector<RefTable_t> refTable(width / 2);
    {
        size_t validIdx = 0;
        for (size_t cycle = 0; cycle < outputs.size(); cycle++) {
            if (outputs[cycle].empty()) continue;
            for (uint32_t n = 0; n < width / 2; n++) {
                refTable[n][validIdx] = { outputs[cycle][2*n], outputs[cycle][2*n+1] };
            }
            validIdx++;
        }
    }

    for (uint32_t n = 0; n < width/2; n++) {
        Reg<Word> cycleId(0);
        Reg<Word> numStages_r(numStages+1); // +1 for checkOutputs registers
        Reg<Word> nId(n);
        Reg<RefTable_t> refTable_n(refTable[n]);
        task(checkOutputs, nId, cycleId, numStages_r, refTable_n, pipeRegs[numStages][2*n], pipeRegs[numStages][2*n+1], cycleId);
    }

#endif

    return 0;
}

// Simulate N cycles of the NTT pipeline and collect outputs.
// Returns a 2D array: result[cycle] = vector of output Words for that cycle.
// Output rows are only populated once the pipeline has filled (cycle >= numStages+1).
//
// feedInputs and ntt2 are called with the same signatures as in your dataflow graph,
// but here they operate on plain Word values (no Reg<> indirection).
std::vector<std::vector<Word>> simulateNTTPipeline(size_t width, size_t numCycles) {
    assert(width > 0 && (width & (width - 1)) == 0);
    size_t numStages = std::bit_width(width) - 1;

    // pipeRegs[stage][n] — plain values, updated each cycle via double-buffering
    std::vector<std::vector<Word>> pipeRegs(numStages + 1, std::vector<Word>(width, 0));
    std::vector<std::vector<Word>> nextRegs(numStages + 1, std::vector<Word>(width, 0));

    // Twiddle factors — precomputed exactly as in your graph (constant, stage-indexed)
    std::vector<std::vector<Word>> twiddles(numStages, std::vector<Word>(width / 2));
    for (uint32_t stage = 0; stage < numStages; stage++)
        for (uint32_t n = 0; n < width / 2; n++)
            twiddles[stage][n] = Word(stage+1);  // matches: twiddles[stage].emplace_back(stage+1)

    // Precompute butterfly routing: outIdx0/outIdx1 for each (stage, n)
    // This mirrors the graph's index calculation exactly.
    struct Route { size_t outIdx0, outIdx1; };
    std::vector<std::vector<Route>> routes(numStages, std::vector<Route>(width / 2));
    {
        size_t stride = width / 2;
        for (uint32_t stage = 0; stage < numStages; stage++) {
            for (uint32_t n = 0; n < width / 2; n++) {
                if (n % stride < (stride / 2)) {
                    routes[stage][n].outIdx0 = 2 * n;
                    routes[stage][n].outIdx1 = 2 * n + stride;
                } else {
                    routes[stage][n].outIdx0 = 2 * n + 1 - stride;
                    routes[stage][n].outIdx1 = 2 * n + 1;
                }
            }
            stride /= 2;
        }
    }

    numCycles = numCycles + numStages;
    std::vector<std::vector<Word>> result(numCycles);

    std::vector<Word> feedState(width / 2);
    for (uint32_t n = 0; n < width / 2; n++)
        feedState[n] = n;  // initial value is the butterfly index

    for (size_t cycle = 0; cycle < numCycles; cycle++) {
        // Copy current regs to next (so unwritten slots keep their old value;
        // in practice every slot is written every cycle, but this is safe either way)
        nextRegs = pipeRegs;

        // --- Stage 0: feedInputs writes into pipeRegs[0] ---
        // feedInputs(idx_in, idx_out, o0, o1)
        // idx_in is the loop variable n (as a Word), idx_out mirrors it back.
        for (uint32_t n = 0; n < width / 2; n++) {
            Word idxOut, o0, o1;
            feedInputs(feedState[n], 1, idxOut, o0, o1);
            feedState[n] = idxOut;
            nextRegs[0][2 * n]     = o0;
            nextRegs[0][2 * n + 1] = o1;
        }

        // --- Butterfly stages: ntt2 reads pipeRegs[stage], writes nextRegs[stage+1] ---
        // Each ntt2 is a pure function of its inputs (the current register state),
        // so reading from pipeRegs[stage] (not nextRegs) gives the correct 1-cycle delay.
        for (uint32_t stage = 0; stage < numStages; stage++) {
            for (uint32_t n = 0; n < width / 2; n++) {
                Word o0, o1;
                ntt2(pipeRegs[stage][2 * n],
                     pipeRegs[stage][2 * n + 1],
                     twiddles[stage][n],
                     o0, o1);
                //printf("[DEBUG][cycle=%lu] inputs: (%x, %x) -- twiddle: %x -- outputs: (%x, %x)\n",
                //       cycle, pipeRegs[stage][2 * n], pipeRegs[stage][2 * n + 1], twiddles[stage][n], o0, o1);
                nextRegs[stage + 1][routes[stage][n].outIdx0] = o0;
                nextRegs[stage + 1][routes[stage][n].outIdx1] = o1;
            }
        }

        // Commit: advance pipeline by one cycle
        pipeRegs = nextRegs;

        // --- Collect outputs (mirrors the commented-out checkOutputs loop) ---
        // Output is valid once the pipeline has filled: cycle >= numStages + 1
        // (cycle 0 fills stage 0, cycle numStages fills stage numStages)
        if (cycle >= numStages) {
            result[cycle].resize(width);
            for (uint32_t n = 0; n < width / 2; n++) {
                result[cycle][2 * n]     = pipeRegs[numStages][2 * n];
                result[cycle][2 * n + 1] = pipeRegs[numStages][2 * n + 1];
            }
        }
    }

    return result;  // result[cycle] is empty for cycle < numStages, populated thereafter
}
