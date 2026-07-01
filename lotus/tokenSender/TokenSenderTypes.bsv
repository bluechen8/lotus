/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import Vector::*;

import LotusGlobalConfig::*;
import Include::*;

// NOTE: 31 because an unused arg will have index of 31 (all 1s)
typedef 63 TaskMaxOutRegs;
typedef TLog#(TaskMaxOutRegs) TaskOutRegIdxBits;
typedef Bit#(TaskOutRegIdxBits) TaskOutRegIdx;

typedef TDiv#(TaskMaxOutRegs, 2) TaskMaxOutRegPairs;
typedef TLog#(TaskMaxOutRegPairs) TaskOutRegPairsIdxBits;
typedef Bit#(TaskOutRegPairsIdxBits) TaskOutRegPairIdx;

typedef TMul#(TaskMaxOutRegs, NumCoresPerTile) OutArgTableNumElems;
typedef TLog#(OutArgTableNumElems) OutArgTableIdxBits;
typedef Bit#(OutArgTableIdxBits) OutArgTableIdx;

typedef TMul#(AvgOutEdgesPerTask, TasksPerTile) EdgeTableNumElems;
typedef Bit#(TLog#(EdgeTableNumElems)) EdgeTableIdx;
typedef Bit#(TLog#(TDiv#(EdgeTableNumElems, 2))) EdgePairTableIdx;

typedef Vector#(2, Word) TaskCommitRegPacket;

// What the task-unit sends to TokenSender when it dispatches a task to a core
typedef struct {
`ifdef RUNTIME_ANALYSIS
    Word taskFn;
`endif // RUNTIME_ANALYSIS
    TaskOutRegIdx numOutArgs;  // 5-6
    EdgeTableIdx firstEdgeIdxStart; // ~14
    NumOutEdges numOutEdges; // ~5
    CycleId cycleId; // ~3
} TokenSenderTaskMetadata deriving(Bits, Eq, FShow);

// FIXME(farese): When numTilesPerDevice > 16, we overflow.
//                Not sure what would be a good solution...
// dsm: If this goes slightly past the URAM width, setting style to hybrid
// should do the trick (it'll use one BRAM18 in parallel with the URAM)
typedef struct {
    GlobalTileId                    globalTileId;      // 3 + 4 = 7
    TaskId                            taskId;            // 12
    CycleIdDelta                    cycleIdDelta;      // 1
    ArgIdx                            firstArg;          // 3
    Bool                              hasMemDataDep;     // 1
    Vector#(ArgsPerToken, TaskOutRegIdx) outRegIdxs;  // 2 * 6 = 12
} Edge deriving(Bits, Eq, FShow);

typedef Vector#(2, Edge) EdgePair;

