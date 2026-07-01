/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Memory Request (for cache's req input)
typedef enum { Ld, St } MemOp;

// Address types --- must be <= 32 bits
typedef Bit#(32) Addr;
typedef Bit#(30) WordAddr;

typedef enum {ICACHE, DCACHE} CacheType;

typedef struct {
    //CacheType cacheType;
    Bit#(4) wrMask; // all-zeros = load line; else store (TODO: Can be encoded in 3 bits, if this reduces logic: LdLine, Sw, ShL, ShU, Sb0, ..., Sb3) Example:
                    // 110 = LdLine, 001, 010, 100 = Sb0, Sb1, Sb2; 101 = Sb3, 110 = ShL, 000 = ShU, 111 = Sw... this leaves bitMask[1] raw, requiring 3 LUTs to decode
    WordAddr wordAddr;
    Word data; // for stores; for loads and ifetches, contains the CoreRespId as given below
} MemReq;

// NOTE: Tagged unions could be used for MemReq instead
// ICaches can issue up to 4 requests
typedef Bit#(2) ICacheRespId;

typedef struct {
    CacheType destCache;
    ICacheRespId icacheRespId;
} CoreRespId;

function CoreRespId getCoreRespId(MemReq req) = unpack(truncate(req.data));

// Somehow, this triggers a verilog compiler bug... produces a wire called Core.Core.dcacheRespIdToData
//Word dcacheRespIdToData = {?, pack(CoreRespId{destCache: DCACHE, icacheRespId: ?})};

function Word icacheRespIdToData(ICacheRespId id) = {?, pack(CoreRespId{destCache: ICACHE, icacheRespId: id})};

// Line size
Integer wordsPerLine = 16;  // must be a power of 2; 16 means 16*32 = 512-bit cache lines
Integer logWordsPerLine = log2(wordsPerLine);

// FIXME: Duplicated w task queue
typedef Bit#(5) TaskSize;

typedef struct {
    WordAddr wordAddr;
    TaskSize size;
} TaskPrefetchHint;
