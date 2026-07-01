/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

#include "lotus_types.h"

#include <cstddef>
#include <array>

// Structs using during init/configuration. These are needed by host code, but
// not Lotus programs, so they're kept separate.

// This define should always be >= the app's N_ARGS; we have it because it's
// more efficient (faster compiles + smaller binaries) to have fixed-size
// std::arrays than dynamically allocated std::vectors for args.
// If we start having many args (e.g., 16), just increase this, and if binary
// size becomes too big, move to a flattened list of args with start pointers
// in TaskInfo_t.
#define MAX_N_ARGS (15)

namespace lotus {
    struct TaskInfo_t {
        TileId_t tileId;
        TaskId_t taskId;
        Arg_t taskFn;
        Arg_t taskCacheLines;
        ArgIdx_t numArgs;
        NEdges_t numOutEdges;
        NEdges_t numOutArgs;
        EdgeTableIdx_t firstEdgeIdxStart;
        bool canSkip;
        // One set per subCycleId
        std::array<std::array<Arg_t, MAX_N_ARGS>, 2> initialArgs;
    };

    struct EdgeInfo_t {
        TileId_t sourceTileId;
        EdgeTableIdx_t entryIdx;
        // NOTE(dsm): Using target, not dest, because destTile is overused elsewhere
        TileId_t targetTileId;
        TaskId_t targetTaskId;
        CycleDelta_t cycleDelta;
        ArgIdx_t firstArg;
        bool hasMemDataDep;
        std::array<ArgIdx_t, 2> args;
    };

    struct ScopeInfo_t {
        uint32_t scopeId;
        Arg_t startAddr;
        uint8_t* bytes;
        size_t numBytes;
    };
};

