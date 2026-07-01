/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

/* BDPI routines to simulate a random-access memory in Bluesim. Used because
 * Bluespec's primitive types can't be feasibly used to model all XRAM
 * variants, and using vector or array types is super slow because Bluesim
 * flattens them.
 */

#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// Obey C conventions in interface
extern "C" {
  unsigned int allocMem(unsigned int , unsigned int , unsigned int *);
  void readMem(unsigned int *, unsigned int , unsigned int *);
  void writeMem(unsigned int , unsigned int *, unsigned int *);

  // Like readMem, but exported as a value method, so can't have assertions and must fail silently
  void readMemValue(unsigned int *, unsigned int , unsigned int *);
}

struct Mem {
    uint32_t addrSz;
    uint32_t dataSz;
    std::vector<uint32_t> data;
};

std::vector<Mem> mems;

static inline size_t numWords(size_t sz) {
    return ((sz - 1) / 32) + 1;
}

unsigned int allocMem(unsigned int addrSz, unsigned int dataSz, unsigned int* initialValuePtr) {
    uint32_t handle = mems.size();
    assert(addrSz < 32);  // can be extended to 64 easily, but in practice I don't see using >2B-word SRAMs...
    mems.push_back({addrSz, dataSz});
    mems[handle].data.resize((1 << addrSz) * numWords(dataSz));
    for (uint32_t addr = 0; addr < (1 << addrSz); addr++) {
        writeMem(handle, &addr, initialValuePtr);
    }
    //printf("Alloc handle %d, <%d, %d, %d...>\n", handle, addrSz, dataSz, *initialValuePtr);
    return handle;
}

void readMem(unsigned int* retPtr, unsigned int handle, unsigned int* addrPtr) {
    assert(handle < mems.size());
    Mem& mem = mems[handle];
    uint32_t addr = *addrPtr;
    assert(addr < (1 << mem.addrSz));
    size_t idx = ((size_t) addr) * numWords(mem.dataSz);
    memcpy(retPtr, &mem.data[idx], sizeof(uint32_t) * numWords(mem.dataSz));
}

void writeMem(unsigned int handle, unsigned int* addrPtr, unsigned int* dataPtr) {
    assert(handle < mems.size());
    Mem& mem = mems[handle];
    uint32_t addr = *addrPtr;
    assert(addr < (1 << mem.addrSz));
    size_t idx = ((size_t) addr) * numWords(mem.dataSz);
    memcpy(&mem.data[idx], dataPtr, sizeof(uint32_t) * numWords(mem.dataSz));
}

void readMemValue(unsigned int* retPtr, unsigned int handle, unsigned int* addrPtr) {
    if (handle < mems.size()) {
        Mem& mem = mems[handle];
        uint32_t addr = *addrPtr;
        if (addr < (1 << mem.addrSz)) {
            size_t idx = ((size_t) addr) * numWords(mem.dataSz);
            memcpy(retPtr, &mem.data[idx], sizeof(uint32_t) * numWords(mem.dataSz));
        } else {
            for (int n = 0; n < numWords(mem.dataSz); n++) retPtr[n] = 0xAAAAAAAA;
        }
    } else {
        *retPtr = 0xAAAAAAAA;
    }
}
