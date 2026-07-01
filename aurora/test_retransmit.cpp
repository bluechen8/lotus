/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include "verilated.h"
#include "VTestRetransmit.h"

uint64_t g_cycle;

double sc_time_stamp() {
    return static_cast<double>(g_cycle);
}

int main(int argc, const char* argv[]) {
    Verilated::commandArgs(argc, argv);
    auto tb = new VTestRetransmit;

    tb->rstn = 0;
    for (uint64_t cycle = 0; cycle < 50000; cycle++) {
        g_cycle = cycle;
        tb->clk = 1;
        tb->eval();
        tb->clk = 0;
        tb->eval();
        if (cycle == 100) {
            tb->rstn = 1;
            tb->eval();
        }
    }

    delete tb;
    return 0;
}
