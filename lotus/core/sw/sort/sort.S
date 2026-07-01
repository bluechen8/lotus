#include "src/defines.h"
.section ".text.init"
    .globl sort

//  Inputs:
//  a0 = p (address of array)
//  a1 = start
//  a2 = end

// FIXME(dsm): This interface is bad... just give array pointer and end.
sort:
    // NOTE: By convention, all ranges are inclusive of endAddr
    slli a1, a1, 2
    add a0, a1, a0 // a0 = startAddr
    slli a2, a2, 2
    add a1, a0, a2  // a1 = endAddr, and a2 can be reused for whatever
    mv t6, sp  // t6 == original sp value, used to detect termination (we don't touch ra now)
    bgeu a0, a1, q_done
quicksort:  // args a0: startAddr, a1: endAddr | returns nothing
    // sp increased late to avoid E bypassing:
    sw a0, -4(sp)
    sw s1, -8(sp)  // s1 will become our pivot, so we need to save it
    addi sp, sp, -8
    // regMap: s1: endAddr
    mv s1, a1
q_tailrec:  // when we're tail-recursing, s1 == a1, so no need to include move above
    // Inlined partition routine -- Hoare variant
    // args a0: startAddr, a1: endAddr | returns t1: pivotAddr, does not change a1
    // regMap: t0: loAddr, t1: hiAddr, t2: pivotVal
    lw t2, 0(a0)
    addi t1, a1, 4
    mv t4, t2
#if 0
    j p_iterhi
p_iterlo:
    lw t4, 4(a0)
    addi a0, a0, 4
    blt t4, t2, p_iterlo
p_iterhi:
    lw t5, -4(t1)
    addi t1, t1, -4
    bgt t5, t2, p_iterhi
    bgeu a0, t1, p_done
    sw t4, 0(t1)
    sw t5, 0(a0)
    j p_iterlo
#else
p_iterhi:
    lw t5, -4(t1)
    addi t1, t1, -4
    bgt t5, t2, p_iterhi
    bgeu a0, t1, p_done
p_swap:
    sw t4, 0(t1)
    lw t4, 4(a0)
    sw t5, 0(a0)
    addi a0, a0, 4
    bge t4, t2, p_iterhi
p_iterlo:
    lw t4, 4(a0)
    addi a0, a0, 4
    blt t4, t2, p_iterlo
    // Replicated p_iterhi code; equivalent to j p_iterhi. Note how we fall through to p_done, so bgeu p_done -> bltu p_swap
    lw t5, -4(t1)
    addi t1, t1, -4
    bgt t5, t2, p_iterhi
    bltu a0, t1, p_swap
#endif
p_done:
    // End inlined partition routine
    addi a0, t1, 4
    mv s1, t1 // regMap change: s1: pivotAddr
    bltu a0, a1, quicksort
q_post:
    lw a0, 4(sp)  // recover old a0
    mv a1, s1     // recover old a1
q_post_repeat:
    // Tail call optimization: Avoid stack push/pops for half the calls. It's a
    // branch rather than a jump to incorporate the initial condition check
    // (a0 < a1) in the same instruction.
    // NOTE: using s1 instead of a1 to avoid tight dependence with a1
    bltu a0, s1, q_tailrec
    lw s1, 0(sp)  // a0 already loaded
    lw a0, 12(sp)  // recover old a0
    addi sp, sp, 8
    mv a1, s1     // compensates sp stall
    // NOTE: At this point, this is the only place where and E->D bypass helps.
    // (The dep is addi -> bne on sp). We could add compensation code to fix...
q_done:
    bne sp, t6, q_post_repeat
    ret
