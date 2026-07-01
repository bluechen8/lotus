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
#include <cstring>

#include "taskflow.h"

#include "unit.h"


using namespace taskflow;


/////////////////// basic_*_fib
void unit_basic_reg_fib(int argc, char* argv[]) {
    Reg<Word> i0(0);
    Reg<Word> i1(1);

    task(basic_reg_fib, i0, i1, i0, i1);

    {
        Reg<Word> iter(0);
        task(basic_reg_fib_checker, iter, i1, iter);
    }
}

void unit_basic_mem_fib(int argc, char* argv[]) {

    Reg<BasicMemFib> fibToCheck(BasicMemFib{});

    Reg<BasicMemFib> fibReference([](){
        BasicMemFib fibRef{};

        Word i0 = 0;
        Word i1 = 1;
        for (Word i = 0; i < MaxBasicMemFibIters; i++) {
            Word o1 = i0 + i1;
            fibRef[i] = o1;
            i0 = i1;
            i1 = o1;
        }
        return fibRef;
    }());

    {
        Reg<Word> iter(0);
        Reg<Word> i0(0);
        Reg<Word> i1(1);
        task(basic_mem_fib, iter, i0, i1, fibToCheck);
    }

    {
        Reg<Word> iter(0);
        task(basic_mem_fib_checker, iter, fibToCheck, fibReference);
    }

}

/////////////////// custom_type_*
void unit_custom_type_0(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Word> val(CustomType0InitVal);
    task(custom_type_0, iter, val);
}
void unit_custom_type_1(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<uint16_t> val(CustomType1InitVal);
    task(custom_type_1, iter, val);
}
void unit_custom_type_2(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<CustomType2Mem> mem([](){
        CustomType2Mem mem;
        for (Word i = 0; i < CustomType2MaxIters; i++) {
            mem[i] = CustomType2InitVal + i;
        }
        return mem;
    }());
    task(custom_type_2, iter, mem);
}
void unit_custom_type_3(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<CustomType3> point(CustomType3{.x=CustomType3XInitVal, .y=CustomType3YInitVal});
    task(custom_type_3, iter, point);
}
void unit_custom_type_4(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<CustomType4> point(CustomType4{.x=CustomType4XInitVal, .y=CustomType4YInitVal});
    task(custom_type_4, iter, point);
}

/////////////////// unit_packing_*
void unit_packing_0(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Word> arg0(0);
    Reg<Word> arg1(1);
    Reg<Word> arg2(0);
    Reg<Word> arg3(0);
    Reg<uint8_t> arg50(0);
    Reg<uint8_t> arg51(1);
    Reg<uint8_t> arg52(0);
    Reg<uint8_t> arg53(0);
    task(packing_0, iter, arg0, arg1, arg2, arg3, arg50, arg51, arg52, arg53);
}

void unit_packing_1(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Packing1> maybe(Packing1{.x=0, .valid=false});
    task(packing_1, iter, maybe);
}

void unit_packing_2(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Packing2> maybe(Packing2{.incA=true, .incB=false, .incC=false, .a=0, .b=0, .c=0});
    task(packing_2, iter, maybe);
}

void unit_packing_3(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Word> arg0(0);
    Reg<Word> arg1(0);
    Reg<Word> arg2(0);
    Reg<Packing2> arg3(Packing2{.incA=true, .incB=false, .incC=false, .a=0, .b=0, .c=0});
    Reg<bool> b(false);
    task(packing_3, iter, arg0, arg1, arg2, arg3, b);
}

/////////////////// overflow_*
void unit_overflow_0(int argc, char* argv[]) {
    Reg<Word> iter(0);
    Reg<Overflow0> arg0(Overflow0{});
    task(overflow_0, iter, arg0);
}


/////////////////// same_cycle_*
void unit_same_cycle_0(int argc, char* argv[]) {

    Reg<SameCycle0Mem> fibReference([](){
        SameCycle0Mem fibRef{};

        Word i0 = 0;
        Word i1 = 1;
        for (Word i = 0; i < MaxSameCycle0Iters; i++) {
            Word o1 = i0 + i1;
            fibRef[i] = o1;
            i0 = i1;
            i1 = o1;
        }
        return fibRef;
    }());

    Wire<Word> fib_at_iter;
    {
        Reg<Word> i0(0);
        Reg<Word> i1(1);
        task(same_cycle_0, i0, i1, fib_at_iter);
    }

    {
        Reg<Word> iter(0);
        task(same_cycle_0_checker, iter, fib_at_iter, fibReference);
    }

}

//////////////////////// selective_*

void unit_selective_0(int argc, char* argv[]) {
    Reg<Word> changes(0);

    {
        Reg<Word> cnst(0);
        task(selective_0, cnst, changes);
    }

    {
        Reg<Word> iter(0);
        task(selective_0_helper, iter, changes);
    }
}


//////////////////////// pipeline_*

void unit_pipeline_0(int argc, char* argv[]) {
    Reg<Option<uint8_t>> regA{Option<uint8_t>{}};
    Reg<Option<uint8_t>> regB{Option<uint8_t>{}};

    Wire<bool> stall;

    {
        Reg<uint8_t> iter(0);
        task(pipeline_0_stage_0, iter, stall, regA);
    }

    {
        task(pipeline_0_stage_1, regA, stall, regB);
    }

    {
        Reg<uint8_t> regBChecker(0);
        Reg<Counter<5>> counter(Counter<5>{false});
        task(pipeline_0_stage_2, regBChecker, regB, counter, stall);
    }
}

void unit_pipeline_1(int argc, char* argv[]) {
    Reg<Option<uint8_t>> regA{Option<uint8_t>{}};
    Reg<Option<uint8_t>> regB{Option<uint8_t>{}};

    Wire<bool> stall;

    {
        Reg<uint8_t> iter(0);
        task(pipeline_1_stage_0, iter, stall, regA);
    }

    {
        Reg<Option<uint8_t>> savedRegA{Option<uint8_t>{}};
        task(pipeline_1_stage_1, regA, savedRegA, stall, regB);
    }

    {
        Reg<uint8_t> regBChecker(0);
        Reg<Counter<5>> counter(Counter<5>{false});
        task(pipeline_1_stage_2, regBChecker, regB, counter, stall);
    }
}

void unit_pipeline_2(int argc, char* argv[]) {
    Reg<uint8_t> pc(0);
    Reg<uint8_t> data_01(0);
    Reg<uint8_t> data_12(0);
    Reg<uint8_t> data_23(0);

    task(pipeline_2_stage_0, pc, data_01, pc);
    task(pipeline_2_stage_1, data_01, data_12);
    task(pipeline_2_stage_2, data_12, data_23);
    task(pipeline_2_stage_3, data_23);
}

int main(int argc, char* argv[]) {
    assert(argc >= 2);
    if (strcmp(argv[1], "basic_reg_fib") == 0) {
        unit_basic_reg_fib(argc, argv);
    } else if (strcmp(argv[1], "basic_mem_fib") == 0) {
        unit_basic_mem_fib(argc, argv);
    } else if (strcmp(argv[1], "custom_type_0") == 0) {
        unit_custom_type_0(argc, argv);
    } else if (strcmp(argv[1], "custom_type_1") == 0) {
        unit_custom_type_1(argc, argv);
    } else if (strcmp(argv[1], "custom_type_2") == 0) {
        unit_custom_type_2(argc, argv);
    } else if (strcmp(argv[1], "custom_type_3") == 0) {
        unit_custom_type_3(argc, argv);
    } else if (strcmp(argv[1], "custom_type_4") == 0) {
        unit_custom_type_4(argc, argv);
    } else if (strcmp(argv[1], "packing_0") == 0) {
        unit_packing_0(argc, argv);
    } else if (strcmp(argv[1], "packing_1") == 0) {
        unit_packing_1(argc, argv);
    } else if (strcmp(argv[1], "packing_2") == 0) {
        unit_packing_2(argc, argv);
    } else if (strcmp(argv[1], "packing_3") == 0) {
        unit_packing_3(argc, argv);
    } else if (strcmp(argv[1], "overflow_0") == 0) {
        unit_overflow_0(argc, argv);
    } else if (strcmp(argv[1], "same_cycle_0") == 0) {
        unit_same_cycle_0(argc, argv);
    } else if (strcmp(argv[1], "selective_0") == 0) {
        unit_selective_0(argc, argv);
    } else if (strcmp(argv[1], "pipeline_0") == 0) {
        unit_pipeline_0(argc, argv);
    } else if (strcmp(argv[1], "pipeline_1") == 0) {
        unit_pipeline_1(argc, argv);
    } else if (strcmp(argv[1], "pipeline_2") == 0) {
        unit_pipeline_2(argc, argv);
    } else {
        printf("Unit Test Case: %s", argv[1]);
        assert(false && "Unknown unit test case");
    }

}
