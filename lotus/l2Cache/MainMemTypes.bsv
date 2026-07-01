/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import LotusGlobalConfig::*;

// Defines types used for addresses and requests

// Base parameters

typedef 32   WordBits;
typedef 512  ClBits;
typedef 64   ChunkBits;

typedef 32   AddrBits;

// Derived parameters

typedef TDiv#(ClBits, 8) ClBytes;

typedef TLog#(TDiv#(WordBits, 8)) ByteSelBits;
typedef Bit#(ByteSelBits)         ByteSel;

typedef TLog#(TDiv#(ChunkBits, WordBits)) WordSelBits;
typedef Bit#(WordSelBits)                 WordSel;

typedef Bit#(ChunkBits) Chunk;
typedef Bit#(WordBits)  Word;

typedef TDiv#(WordBits, 8) WordBEBits;
typedef Bit#(WordBEBits)   WordBE;

typedef TDiv#(ChunkBits, 8) ChunkBEBits;
typedef Bit#(ChunkBEBits)   ChunkBE;

typedef TDiv#(ClBits, WordBits) NumWordsPerLine;

// Cache geometry

typedef TDiv#(ClBits, ChunkBits)       NumChunksPerCacheLine;
typedef TSub#(NumChunksPerCacheLine,1) FinalChunkId;
typedef TLog#(NumChunksPerCacheLine)   ChunkSelBits;
typedef Bit#(ChunkSelBits)             ChunkSel;

typedef TLog#(L2NumBanks) BankSelBits;
typedef Bit#(BankSelBits) BankSel;

typedef TDiv#(L2CacheSizeBytes, L2NumBanks) BankSizeBytes;

typedef TDiv#(BankSizeBytes, TMul#(L2NumWays, ClBytes)) NumSets;
typedef TLog#(NumSets)                                 SetSelBits;
typedef Bit#(SetSelBits)                               SetSel;

typedef Bit#(TLog#(L2NumWays)) WaySel;

typedef TSub#(AddrBits, TAdd#(ByteSelBits, TAdd#(WordSelBits, TAdd#(ChunkSelBits, TAdd#(BankSelBits, SetSelBits))))) AddrTagBits;
typedef Bit#(AddrTagBits) AddrTag;

typedef TLog#(L2MissEntries) MissIdxBits;
typedef Bit#(MissIdxBits)  MissIdx;

// *Memory* addresses, with different granularities
typedef struct { AddrTag tag; SetSel set; BankSel bank; ChunkSel cs; WordSel ws; } WordAddr deriving (Bits, Eq, FShow);
typedef struct { AddrTag tag; SetSel set; } BankLineAddr deriving (Bits, Eq, FShow);
typedef struct { AddrTag tag; SetSel set; BankSel bank; } LineAddr deriving (Bits, Eq, FShow);

// *Cache array* indexes, i.e., local addresses to the tag and data arrays
// NOTE(dsm): These were called addresses, which is confusing since they're not memory addresses.
typedef struct { SetSel set; ChunkSel cs; WaySel ws; } DataArrayIdx deriving (Bits, Eq, FShow);
typedef struct { SetSel set; WaySel ws; } TagArrayIdx deriving (Bits, Eq, FShow);

// Memory requests: These are parametric on the reqId
// Main memory side mimics AXI, but we rely on some external glue to turn local ids to global, add wstrb for writes, etc.
// NOTE: These requests have bank line addresses, not full line addresses; the
// bank bits are on the request id once bank requests have been muxed

typedef struct {
    BankLineAddr bankLineAddr;
    reqId_t reqId;
} LineReadReq#(type reqId_t) deriving (Bits, Eq, FShow);

typedef LineReadReq#(reqId_t) LineWriteReq#(type reqId_t);

typedef struct {
    Chunk chunk;
    reqId_t reqId;
} ChunkReadResp#(type reqId_t) deriving (Bits, Eq, FShow);

// Write requests are serialized over the same channel, beginning with a
// LineReq and following with the needed number of beats of data.
typedef Bit#(TMax#(SizeOf#(LineWriteReq#(reqId_t)), SizeOf#(Chunk))) LineOrChunkWriteReq#(type reqId_t);

typedef struct {
    reqId_t reqId;
} LineWriteResp#(type reqId_t) deriving (Bits, Eq, FShow);


// Specializations
// 1. Banks
typedef LineReadReq#(MissIdx) BankLineReadReq;
typedef LineWriteReq#(MissIdx) BankLineWriteReq;
typedef LineOrChunkWriteReq#(MissIdx) BankLineOrChunkWriteReq;
typedef ChunkReadResp#(MissIdx) BankChunkReadResp;
typedef LineWriteResp#(MissIdx) BankLineWriteResp;

// 2. Tiles (each tile has 1+ banks)
typedef struct { BankSel bank; MissIdx missIdx; } TileReqId deriving (Bits, Eq, FShow);
typedef LineReadReq#(TileReqId) TileLineReadReq;
typedef LineWriteReq#(TileReqId) TileLineWriteReq;
typedef LineOrChunkWriteReq#(TileReqId) TileLineOrChunkWriteReq;
typedef ChunkReadResp#(TileReqId) TileChunkReadResp;
typedef LineWriteResp#(TileReqId) TileLineWriteResp;

// 3. Channels (each channel serves 1+ tiles)
typedef Bit#(TLog#(NumTilesPerMemChannel)) TileSel;
typedef struct { TileSel tileSel; TileReqId tileReqId; } ChannelReqId deriving (Bits, Eq, FShow);
typedef LineReadReq#(ChannelReqId) ChannelLineReadReq;
typedef LineWriteReq#(ChannelReqId) ChannelLineWriteReq;
typedef LineOrChunkWriteReq#(ChannelReqId) ChannelLineOrChunkWriteReq;
typedef ChunkReadResp#(ChannelReqId) ChannelChunkReadResp;
typedef LineWriteResp#(ChannelReqId) ChannelLineWriteResp;

