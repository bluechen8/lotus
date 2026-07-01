/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include <stdint.h>

#define ARR_START 0x00000000u
#define ARR_LEN   1024u

static inline void swap_u32(uint32_t *a, uint32_t *b) {
    uint32_t t = *a; *a = *b; *b = t;
}

// Lomuto partition (pivot = a[high]) — simple and fine for embedded.
static inline int32_t partition_u32(uint32_t *a, int32_t low, int32_t high) {
    uint32_t pivot = a[high];
    int32_t i = low - 1;
    for (int32_t j = low; j < high; j++) {
        if (a[j] <= pivot) {
            i++;
            swap_u32(&a[i], &a[j]);
        }
    }
    swap_u32(&a[i + 1], &a[high]);
    return i + 1;
}

// Non-recursive quicksort with a tiny manual stack (no dynamic allocation).
static inline void quicksort_u32_nonrec(uint32_t *a, int32_t low, int32_t high) {
    // Enough for up to 2^32 elements (log2(n) <= 32). 32 * 8B ≈ 256B.
    enum { MAX_STACK = 32 };
    struct { int32_t lo, hi; } stack[MAX_STACK];
    int32_t top = -1;

    while (1) {
        // Process the current range until it collapses.
        while (low < high) {
            int32_t p = partition_u32(a, low, high);

            // Tail-eliminate: handle the smaller side first, push the larger.
            int32_t left_size  = p - 1 - low;
            int32_t right_size = high - (p + 1);

            if (left_size < right_size) {
                // Push right [p+1, high], shrink to left
                if (p + 1 < high) {
                    // Stack is sized for worst-case log2(n); assert is optional in freestanding.
                    if (top + 1 < MAX_STACK) stack[++top] = (typeof(stack[0])){ p + 1, high };
                }
                high = p - 1;
            } else {
                // Push left [low, p-1], shrink to right
                if (low < p - 1) {
                    if (top + 1 < MAX_STACK) stack[++top] = (typeof(stack[0])){ low, p - 1 };
                }
                low = p + 1;
            }
        }

        // Pop next range; if none, we’re done.
        if (top < 0) break;
        low  = stack[top].lo;
        high = stack[top].hi;
        top--;
    }
}

void inline rv32_quicksort(void) {
    uint32_t *arr = (uint32_t*)(ARR_START);
    uint32_t n = ARR_LEN;

    if (n > 1) {
        quicksort_u32_nonrec(arr, 0, (int32_t)n - 1);
    }

    // hang
    for (;;) {
        __asm__ __volatile__ ("" ::: "memory");
    }
}

extern "C"
__attribute__((section(".text.core_entry"), used))
void core_entry(void) {
    rv32_quicksort();
}
