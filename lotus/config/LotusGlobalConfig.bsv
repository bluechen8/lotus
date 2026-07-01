/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


typedef `NUM_TILES_DEFINE NumTiles;
typedef TMax#(TLog#(NumTiles), 1) TileIdBits;
typedef Bit#(TileIdBits) TileId;

typedef `NUM_DEVICES_DEFINE NumDevices;
typedef TLog#(NumDevices) DeviceIdBits;
typedef Bit#(DeviceIdBits) DeviceId;

// We have 0 cross-device links if NumDevices==1, otherwise we have NumDevices
// links (not NumDevices-1, this has to do with the topology of the real FPGA)
typedef TMul#(NumDevices, TMin#(1, TSub#(NumDevices, 1))) NumCrossDeviceLinks;

typedef struct {
    DeviceId device;
    TileId tile;
} GlobalTileId deriving(Bits, Eq, FShow);

typedef `NUM_TILES_PER_SWITCH_PORT NumTilesPerSwitchPort;
typedef TDiv#(NumTiles, NumTilesPerSwitchPort) NumLocalSwitchPorts;
typedef TAdd#(NumLocalSwitchPorts, NumCrossDeviceLinks) TokenSwitchRadix;

typedef `NUM_TILES_PER_MEM_CHANNEL NumTilesPerMemChannel;
typedef TDiv#(NumTiles, NumTilesPerMemChannel) NumMemChannels;

typedef `NUM_CORES_PER_TILE_DEFINE NumCoresPerTile;
typedef TLog#(NumCoresPerTile) CoreIdBits;
typedef Bit#(CoreIdBits) CoreId;

typedef `NUM_TASKS_PER_TILE_DEFINE TasksPerTile;
typedef TLog#(TasksPerTile) TaskIdBits;
typedef Bit#(TaskIdBits) TaskId;  // per-tile task id

/* L2 CONFIGURATION: Base parameters */
typedef `L2_CACHE_SIZE_KB               L2CacheSizeKB;
typedef TMul#(L2CacheSizeKB, TExp#(10)) L2CacheSizeBytes;
typedef 4                               L2NumWays;
typedef `L2_CACHE_BANKS                 L2NumBanks;
typedef 1                               L2MissEntries; // i.e., number of MSHRs, determines miss-level parallelism

// Tile decoupling buffers
typedef 7 MaxTileDecouplingStages;

// Other Configuration
typedef `AVG_ARGS_PER_TASK_DEFINE AvgArgsPerTask;
typedef `MAX_ARGS_PER_TASK_DEFINE MaxArgs;
typedef TLog#(TAdd#(MaxArgs, 1)) ArgBits;
typedef Bit#(ArgBits) ArgIdx;

typedef `AVG_OUT_EDGES_PER_TASK_DEFINE AvgOutEdgesPerTask;
typedef `MAX_OUT_EDGES_PER_TASK_DEFINE MaxOutEdgesPerTask;
typedef Bit#(TLog#(TAdd#(MaxOutEdgesPerTask, 1))) NumOutEdges;
