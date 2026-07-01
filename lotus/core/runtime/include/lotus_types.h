/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

#include <cinttypes>

namespace lotus {
    // Used in both API and initialization code
    using Arg_t = uint32_t;

    // Used only for initialization/task unit config
    using TileId_t = uint16_t;
    using TaskId_t = uint16_t;
    using CycleDelta_t = uint8_t;
    using ArgIdx_t = uint8_t;
    using NEdges_t = uint16_t;
    using NOutArg_t = uint8_t;
    using EdgeTableIdx_t = uint32_t;

#define PARGS "%" PRIu32
#define PU8 "%" PRIu8
#define PU16 "%" PRIu16

} // namespace lotus
