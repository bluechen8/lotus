/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

/* API for Lotus tasks */

#include <lotus_types.h>

// Tag task function definitions with this define; this lets us control taskfn
// flags from here.
// NOTE: These flags are for performance, and subject to change. For example,
// flags *can* use alignment restrictions to improve icache footprint, but the
// design should not *assume* all tasks are aligned. Basically, assume you may
// have tasks that don't use this define.
//#define __LOTUS_TASKFN_ATTRS__
// Cache-align every task. This grows code size (by up to 2x), but reduces
// lines per task, which reduces L2 traffic when cores run non-contiguous
// tasks. It also reduces task cold-start because the first instruction is
// available earlier.
#define __LOTUS_TASKFN_ATTRS__ __attribute__((aligned(64)))

namespace lotus {
    // stream_outputs() lets the task produce output values. Each call can
    // produce up to two outputs. Internally, these map to a single R-type
    // instruction; variants with fewer args use x0 (zero) to denote this.
    static inline __attribute__((always_inline)) void stream_outputs(Arg_t arg0, Arg_t arg1) {
        asm volatile(".insn r 0x0B, 4, 0, x0, %0, %1\n\t" : : "r"(arg0), "r"(arg1));
    }

    static inline __attribute__((always_inline)) void stream_outputs(Arg_t arg) {
        asm volatile(".insn r 0x0B, 4, 0, x0, %0, x0\n\t" : : "r"(arg));
    }

    static inline __attribute__((always_inline)) void stream_outputs() {
        asm volatile(".insn r 0x0B, 4, 0, x0, x0, x0\n\t");
    }

    // finish_task() ends the task, and lets the core move on to a different
    // ready task.
    static inline __attribute__((always_inline)) void finish_task() {
        // any unsupported instructions ends the task
        asm volatile("   unimp\n\t");
        __builtin_unreachable();
    }

    /*
    static inline __attribute__((always_inline)) void run() {
        dequeueTask();
    }*/

    inline void print_str(const char* str) {
        // FIXME: Implement for latest core version; just use MMIOs to support write(), and therefore arbitrary printfs
        //for (uint32_t i = 0; i < 500000; i++) {
        //    char c = str[i];
        //    if (!c) break;
        //    print_char(c);
        //}
    }

    // dsm: These now use NOPs that are never emitted by the compiler (addi x0,
    // x0 + a non-zero immediate), and not store MMIOs, which were expensive.
    inline void heartbeat() {
        asm volatile("addi x0, x0, 2\n\t");
    }

    // FIXME: Update for latest core version
    #define LOTUS_PRINT(...)

/*
    #define LOTUS_PRINT(...) do {                            \
                                char str_temp[2048];       \
                                sprintf(str_temp, __VA_ARGS__);    \
                                lotus::print_str(str_temp);  \
                           } while(false)
*/
} // namespace lotus
