/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


#include <array>
#include <tuple>
#include <cstdint>

#include "lotus_task_api.h"

/////////////////////////////////////////////// unit_basic_reg_fib
TASK basic_reg_fib(ARG(IN , FULL, Word) i0,
                   ARG(IN , FULL, Word) i1,
                   ARG(OUT, FULL, Word) o0,
                   ARG(OUT, FULL, Word) o1) {
    o0 = i1;
    o1 = i0 + i1;
}

TASK basic_reg_fib_checker(ARG(IN , FULL, Word) iter_in,
                           ARG(IN , FULL, Word) fib_at_iter,
                           ARG(OUT, FULL, Word) iter_out
                          ) {
    if (iter_in < 50) {
        Word i0 = 0;
        Word i1 = 1;
        for (Word i = 0; i < iter_in; i++) {
            Word o1 = i0 + i1;
            i0 = i1;
            i1 = o1;
        }
        if (i1 != fib_at_iter) {
            lotus::simFail();
        }
    }
    iter_out = iter_in + 1;
}

/////////////////////////////////////////////// unit_basic_mem_fib
constexpr int MaxBasicMemFibIters = 128;
using BasicMemFib = std::array<Word, MaxBasicMemFibIters>;
TASK basic_mem_fib(
                   ARG(INOUT, FULL, Word) iter,
                   ARG(INOUT, FULL, Word) i0, ARG(INOUT, FULL, Word) i1,
                   ARG(OUT, PARTIAL, BasicMemFib) outFib) {
    Word fib_at_iter = i0 + i1;
    i0 = i1;
    i1 = fib_at_iter;
    outFib[iter] = fib_at_iter;
    iter++;
}

TASK basic_mem_fib_checker(
                           ARG(INOUT, FULL, Word) iter,
                           ARG(IN, PARTIAL, BasicMemFib) fibToCheck,
                           ARG(IN, PARTIAL, BasicMemFib) fibReference) {
    if (iter > 0 && iter < MaxBasicMemFibIters) {
        if (fibToCheck[iter-1] != fibReference[iter-1]) {
            lotus::simFail();
        }
    }
    iter++;
}
/////////////////////////////////////////////// custom_type_0

// Goal: Correctly Initalize a Word

constexpr Word CustomType0InitVal = 0xdeadbeef;

TASK custom_type_0(ARG(INOUT, FULL, Word) iter, ARG(INOUT, FULL, Word) val) {
    if (iter < 50) {
        if ((CustomType0InitVal + iter) != val) lotus::simFail();
        val++;
    }
    iter++;
}

/////////////////////////////////////////////// custom_type_1

// Goal: Correctly initalize a uint16_t

constexpr uint16_t CustomType1InitVal = 0xdead;

TASK custom_type_1(ARG(INOUT, FULL, Word) iter, ARG(INOUT, FULL, uint16_t) val) {
    if (iter < 50) {
        if ((CustomType1InitVal + iter) != val) lotus::simFail();
        val++;
    }
    iter++;
}

/////////////////////////////////////////////// custom_type_2

// Goal: Correctly initalize a std::array

constexpr Word CustomType2InitVal = 0xdeadbeef;
constexpr int CustomType2MaxIters = 10;
using CustomType2Mem = std::array<Word, CustomType2MaxIters>;

TASK custom_type_2(ARG(INOUT, FULL, Word) iter, ARG(IN, PARTIAL, CustomType2Mem) mem) {
    if (iter < CustomType2MaxIters) {
        if ((CustomType2InitVal + iter) != mem[iter]) lotus::simFail();
    }
    iter++;
}


/////////////////////////////////////////////// custom_type_3

// Goal: Correctly pass a custom type

constexpr uint16_t CustomType3XInitVal = 10;
constexpr uint16_t CustomType3YInitVal = 3;

typedef struct {
    uint16_t x;
    uint16_t y;
} CustomType3;

TASK custom_type_3(
                   ARG(INOUT, FULL, Word) iter,
                   ARG(INOUT, FULL, CustomType3) point) {
    if (iter < 50) {

        Word base = iter + CustomType3XInitVal + CustomType3YInitVal;
        if (base != (point.x+point.y)) lotus::simFail();

        bool even = (iter&0x1) == 0;
        if (even) {
            point.x++;
        } else {
            point.y++;
        }
    }
    iter++;
}

/////////////////////////////////////////////// custom_type_4

// Goal: Correctly pass a custom type

constexpr uint8_t CustomType4XInitVal = 10;
constexpr uint8_t CustomType4YInitVal = 3;

typedef struct {
    uint8_t x;
    uint8_t y;
} CustomType4;

TASK custom_type_4(ARG(INOUT, FULL, Word) iter, ARG(INOUT, FULL, CustomType4) point) {
    if (iter < 50) {

        Word base = iter + CustomType4XInitVal + CustomType4YInitVal;
        if (base != (point.x+point.y)) lotus::simFail();

        bool even = (iter&0x1) == 0;
        if (even) {
            point.x++;
        } else {
            point.y++;
        }
    }
    iter++;
}


/////////////////////////////////////////////// packing_0

// Goal: Small things that can be packed into the same register

TASK packing_0(ARG(INOUT, FULL, Word) iter, ARG(INOUT, FULL, Word) arg0,
               ARG(INOUT, FULL, Word) arg1, ARG(INOUT, FULL, Word) arg2,
               ARG(INOUT, FULL, Word) arg3,
               ARG(INOUT, FULL, uint8_t) arg50, ARG(INOUT, FULL, uint8_t) arg51, ARG(INOUT, FULL, uint8_t) arg52, ARG(INOUT, FULL, uint8_t) arg53) {
    if (iter < 50) {

        auto update = [](Word& w, uint8_t& b, uint8_t inc) {
            if (w != b) lotus::simFail();
            w += inc;
            b += inc;
        };

        update(arg0, arg50, 1);
        update(arg1, arg51, 2);
        update(arg2, arg52, 3);
        update(arg3, arg53, 4);
    }
    iter++;
}

/////////////////////////////////////////////// packing_1

// Goal: Packing large things into multiple regs

typedef struct {
    Word x;
    bool valid;
} Packing1;

TASK packing_1(ARG(INOUT, FULL, Word) iter,
               ARG(INOUT, FULL, Packing1) maybe) {

    if (iter < 50) {
        bool even = (iter & 0x1) == 0;
        if (even) {
            if (maybe.valid) lotus::simFail();
            maybe.valid = true;
            maybe.x     = iter+1;
        } else {
            if (!maybe.valid) lotus::simFail();
            if (iter != maybe.x) lotus::simFail();
            maybe.valid = false;
        }
    }
    iter++;
}

/////////////////////////////////////////////// packing_2

// Goal: Packing large things into multiple regs

typedef struct {
    bool    incA;
    bool    incB;
    bool    incC;
    uint8_t a;
    uint8_t b;
    uint8_t c;
} Packing2;

TASK packing_2(ARG(INOUT, FULL, Word) iter,
               ARG(INOUT, FULL, Packing2) s) {

    if (iter < 50) {
        if (iter != (s.a + s.b + s.c)) lotus::simFail();
        if (s.incA) {
            s.incA = false;
            s.incB = true;
            s.a++;
        } else if (s.incB) {
            s.incB = false;
            s.incC = true;
            s.b++;
        } else if (s.incC) {
            s.incC = false;
            s.incA = true;
            s.c++;
        } else {
            lotus::simFail();
        }
    }
    iter++;
}

/////////////////////////////////////////////// packing_3

// Goal: Packing lefover of large things + small thing

TASK packing_3(
               ARG(INOUT, FULL, Word) iter,
               ARG(INOUT, FULL, Word) arg0,
               ARG(INOUT, FULL, Word) arg1,
               ARG(INOUT, FULL, Word) arg2,
               ARG(INOUT, FULL, Packing2) arg3, ARG(INOUT, FULL, bool) b) {

    if (iter < 50) {
    }
    iter++;
}


/////////////////////////////////////////////// overflow_N

// Goal: normal overflow

typedef struct {
    std::array<Word, 18> words;
} Overflow0;
TASK overflow_0(
                ARG(INOUT, FULL, Word) iter,
                ARG(INOUT, FULL, Overflow0) arg0) {

    if (iter < 50) {
        if (arg0.words[0] != iter) lotus::simFail();
        arg0.words[0]++;
    }
    iter++;
}



/////////////////////////////////////////////// overflow_N

// Goal: prioritize const overflow
typedef struct {
    std::array<Word, 5> words;
} Overflow1;
TASK overflow_1(ARG(INOUT, PARTIAL, Word) iter,
                ARG(INOUT, FULL, Overflow0) arg0) {

    if (iter < 50) {
        if (arg0.words[0] != iter) lotus::simFail();
        arg0.words[0]++;
    }
    iter++;
}


/////////////////////////////////////////////// overflow_N

// Goal: small things but multiple producers

/////////////////////////////////////////////// overflow_N

// Goal: Can't pack because producer has two consumers


/////////////////////////////////////////////// same_cycle_0

constexpr int MaxSameCycle0Iters = 128;
using SameCycle0Mem = std::array<Word, MaxSameCycle0Iters>;
TASK same_cycle_0(ARG(INOUT, FULL, Word) i0, ARG(INOUT, FULL, Word) i1, ARG(OUT, FULL, Word) fib_at_iter) {
    fib_at_iter = i0 + i1;
    i0 = i1;
    i1 = fib_at_iter;
}

TASK same_cycle_0_checker(ARG(INOUT, FULL, Word) iter,
                          ARG(IN, FULL, Word) fib_at_iter,
                          ARG(IN, PARTIAL, SameCycle0Mem) fibReference) {
    if (iter < MaxBasicMemFibIters) {
        if (fib_at_iter != fibReference[iter]) {
            lotus::simFail();
        }
    }
    iter++;
}


///////////////////////////////////////////// selective_0

TASK selective_0(ARG(INOUT, FULL, Word) cnst, ARG(IN, FULL, Word) changes) {
    (void)cnst;
    (void)changes;
}

TASK selective_0_helper(ARG(INOUT, FULL, Word) iter, ARG(OUT, FULL, Word) changes) {

    if ((iter&0x1) == 0) {
        // only change on evens
        changes = iter;
    } else {
        changes = iter-1;
        // No change
    }

    iter++;

}

///////////////////////////////////////////// pipeline_0

template <uint8_t N>
class Counter {
private:
    uint8_t m_curr;
public:
    Counter(bool enabled): m_curr(enabled ? 0 : 255) {}

    Counter(): Counter(true) {}

    bool enabled() { return m_curr != 255; }

    bool update() {
        if (m_curr == 255) return false;

        m_curr += 1;
        return m_curr > N;
    }
    void disable() {
        m_curr = 255;
    }

    void enable() {
        m_curr = 0;
    }
    void reset() {
        m_curr = 0;
    }

};

template <class T>
struct Option {
    bool has;
    T    val;

    // Constructors
    constexpr Option() : has(false), val() {}
    constexpr Option(T v) : has(true), val(v) {}

    // State
    constexpr bool has_value() const { return has; }
    constexpr explicit operator bool() const { return has; }
    constexpr void reset() { has = false; val = T{}; }

    // Set
    constexpr void set(T v) { val = v; has = true; }

    // Access (precondition: has == true)
    constexpr T&       value()       { return val; }
    constexpr const T& value() const { return val; }

    // Fallback
    constexpr T value_or(T def) const { return has ? val : def; }

    // Convenience assignment from T
    constexpr Option& operator=(T v) { set(v); return *this; }
};

TASK pipeline_0_stage_0(ARG(INOUT, FULL, uint8_t) iter,
                        ARG(IN, FULL, bool) stall,
                        ARG(OUT, FULL, Option<uint8_t>) regA
                        )
{
    if (stall) {
        regA = Option<uint8_t>(); // Overwrites regA with garbage
        return;
    }
    regA = Option<uint8_t>(iter);
    iter++;
}
TASK pipeline_0_stage_1(ARG(IN, FULL, Option<uint8_t>) regA,
                        ARG(IN, FULL, bool) stall,
                        ARG(OUT, FULL, Option<uint8_t>) regB
                        )
{
    if (stall) {
        regB = Option<uint8_t>(); // Overwrites regB with garbage
        return;
    }
    regB = regA;
}

TASK pipeline_0_stage_2(ARG(INOUT, FULL, uint8_t) regBChecker,
                        ARG(IN, FULL, Option<uint8_t>) regB,
                        ARG(INOUT, FULL, Counter<5>) counter,
                        ARG(OUT, FULL, bool) stall
                        )
{
    if (regB.has_value()) {
        if (regBChecker != regB.value()) lotus::simFail();
        regBChecker += 1;
        // printf("[stage_2] regB=%u\n",regB.value());
    }
    if (regB.has_value() && !counter.enabled()) {
        counter.enable();
    }
    if (counter.enabled()) {
        if (counter.update()) {
            counter.disable();
        } else {
            stall = true;
        }
    } else {
        stall = false;
    }
}

TASK pipeline_1_stage_0(ARG(INOUT, FULL, uint8_t) iter,
                        ARG(IN, FULL, bool) stall,
                        ARG(OUT, FULL, Option<uint8_t>) regA
                        )
{
    if (stall) {
        regA = Option<uint8_t>(); // Overwrites regA with garbage
        // stage_0 doesn't require anything because it's in control of its own input (iter)
        return;
    }
    regA = Option<uint8_t>(iter);
    iter++;
}
TASK pipeline_1_stage_1(ARG(IN, FULL, Option<uint8_t>) regA,
                        ARG(INOUT, FULL, Option<uint8_t>) savedRegA,
                        ARG(IN, FULL, bool) stall,
                        ARG(OUT, FULL, Option<uint8_t>) regB
                        )
{
    Option<uint8_t> useRegA = regA;
    if (savedRegA.has_value()) {
        useRegA = savedRegA;
    }
    if (stall) {
        savedRegA = useRegA;
        regB = Option<uint8_t>(); // Overwrites regB with garbage
        return;
    }
    savedRegA = Option<uint8_t>(); // Clear saved
    regB = useRegA;
}

TASK pipeline_1_stage_2(ARG(INOUT, FULL, uint8_t) regBChecker,
                        ARG(IN, FULL, Option<uint8_t>) regB,
                        ARG(INOUT, FULL, Counter<5>) counter,
                        ARG(OUT, FULL, bool) stall
                        )
{
    if (regB.has_value()) {
        // printf("[stage_2] useRegB = %u\n",regB.value());
        if (regBChecker != regB.value()) lotus::simFail();
        regBChecker += 1;
    }
    if (regB.has_value() && !counter.enabled()) {
        counter.enable();
    }
    if (counter.enabled()) {
        if (counter.update()) {
            counter.disable();
        } else {
            stall = true;
        }
    } else {
        stall = false;
    }
}


TASK pipeline_2_stage_0(
        ARG(IN , FULL, uint8_t) pc_in,
        ARG(OUT, FULL, uint8_t) data_out,
        ARG(OUT, FULL, uint8_t) pc_out
        ) {
    data_out = pc_in + 10;
    pc_out = pc_in + 1;
}

TASK pipeline_2_stage_1(
        ARG(IN , FULL, uint8_t) data_in,
        ARG(OUT, FULL, uint8_t) data_out
        ) {
    data_out = data_in + 1;
}

TASK pipeline_2_stage_2(
        ARG(IN , FULL, uint8_t) data_in,
        ARG(OUT, FULL, uint8_t) data_out
        ) {
    data_out = data_in + 1;
}

TASK pipeline_2_stage_3(
        ARG(IN , FULL, uint8_t) data_in
        ) {
    (void)data_in;
}




