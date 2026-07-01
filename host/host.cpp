/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include <fstream>
#include <stdint.h>
#include <string>
#include <sstream>
#include <cmath>

#include "hw.h"
#include "network.h"
#include "stats.h"

#include <algorithm>
#include <math.h>
#include <numeric>
#include <optional>
#include <chrono>
#include <signal.h>

#include <termios.h>
#include <unistd.h>
#include <fcntl.h>

#define MEASUREMENT_UNIT_T std::chrono::microseconds
#define MEASUREMENT_UNIT_N "micro_s"

#define HOST_PREFIX "HOST_PRINT:: "

#define HOST_PRINT(args...) printf(HOST_PREFIX args); std::cout << std::flush;

// Per-benchmark information
// TODO: Link to this rather than including it. This way, large benchmark init
// data can be compiled into one or more independent object files.
// Defines taskInfo, edgeInfo, scopeInfo arrays
#include "hostInit.h"

// One entry per task, in the same order as taskInfo, initialize in main() and used in register_tasks()
std::vector<lotus::NEdges_t> taskInEdges;
std::vector<lotus::NEdges_t> taskCrossCycleInEdges;

// Initialization
static inline uint32_t bits_needed_for_count(uint32_t count) {
    if (count <= 1) return 1;

    uint32_t x = count - 1;
    uint32_t bits = 0;
    while (x) {
        ++bits;
        x >>= 1;
    }
    return bits;
}
lotus::TileId_t global_tileId(const uint32_t deviceId, const lotus::TileId_t local_tileId, const uint32_t N_TILES) {
    uint32_t tile_bits = bits_needed_for_count(N_TILES);
    lotus::TileId_t gtid = (deviceId << tile_bits) | local_tileId;
    return gtid;
}

void register_tasks(hw::Device* d, SIPNode_t* sipTree, lotus::TileId_t globalDestTile, lotus::TileId_t localDestTile, bool selectiveExecution) {
    auto tilePtr = sipTree->filterByName(SIPNode_t::createIdentifier("tile", localDestTile));
    auto getNode = [&tilePtr](const std::string& name) -> SIPNode_t* {
        return tilePtr->filterByName(name)->consumeFilter();
    };

    auto lowerBound = [](lotus::TileId_t gtid) {
        return std::lower_bound(&taskInfo[0], &taskInfo[sizeof(taskInfo)/sizeof(lotus::TaskInfo_t)], gtid,
            [](const lotus::TaskInfo_t& info, lotus::TileId_t tileId) { return info.tileId < tileId; });
    };

    // NOTE: filterByName is expensive, so avoid calling it in the inner loop
    // TODO: Make filterByName cheap instead? A hash table could memoize matches
    auto nTaskId = getNode("tuc-taskId");
    auto nTaskFn = getNode("tuc-taskFn");
    auto nTaskSize = getNode("tuc-taskSize");
    auto nFirstArgIdx = getNode("tuc-firstArgIdx");
    auto nNumArgs = getNode("tuc-numArgs");
    auto nNumInEdges = getNode("tuc-numInEdges");
    auto nNumOutEdges = getNode("tuc-numOutEdges");
    auto nNumOutArgs = getNode("tuc-numOutArgs");
    auto nFirstEdgeIdxStart = getNode("tuc-firstEdgeIdxStart");
    auto nTaskFlags = getNode("tuc-taskFlags");
    auto nNumInEdgesReceivedFirstCycle = getNode("tuc-numInEdgesReceivedFirstCycle");
    auto nDispatch = getNode("tuc-dispatch");
    auto nInitialArgs = getNode("tuc-initialArgs");

    uint32_t totalArgWrites = 0;

    for (const lotus::TaskInfo_t* t = lowerBound(globalDestTile); t < lowerBound(globalDestTile+1); t++) {
        nTaskId->writeNode<uint32_t>(d, t->taskId);
        nTaskFn->writeNode<uint32_t>(d, t->taskFn);
        nTaskSize->writeNodeCached<uint32_t>(d, std::min(31u, t->taskCacheLines - 1));
        nFirstArgIdx->writeNodeCached<uint32_t>(d, totalArgWrites / 2);
        nNumArgs->writeNodeCached<uint32_t>(d, t->numArgs);

        auto numInEdges = taskInEdges[t - &taskInfo[0]];
        auto numCrossCycleInEdges = taskCrossCycleInEdges[t - &taskInfo[0]];
        nNumInEdges->writeNodeCached<uint32_t>(d, numInEdges);

        nNumOutEdges->writeNodeCached<uint32_t>(d, t->numOutEdges);
        nNumOutArgs->writeNodeCached<uint32_t>(d, t->numOutArgs);
        nFirstEdgeIdxStart->writeNode<uint32_t>(d, t->firstEdgeIdxStart);

        uint32_t taskFlags = (selectiveExecution && t->canSkip)? 0x2 : 0x0;

        if (numCrossCycleInEdges == numInEdges) {
            // If a task only has cross-cycle incoming edges, then it must run on the first cycle
            taskFlags |= 0x1; // force task to run on first cycle
            nNumInEdgesReceivedFirstCycle->writeNodeCached<uint32_t>(d, 0);
        } else {
            // Otherwise, count all the cross-cycle edges as received (so
            // receiving only the same-cycle ones gets it going)
            nNumInEdgesReceivedFirstCycle->writeNodeCached<uint32_t>(d, numCrossCycleInEdges);
        }

        nTaskFlags->writeNodeCached<uint32_t>(d, taskFlags);

        // Initialize args. Internally, these are copied to all the versions (in case there are constants)
        for (size_t idx = 0; idx < t->numArgs; idx++) {
            for (uint32_t s = 0; s < 2; s++) nInitialArgs->writeNode<uint32_t>(d, t->initialArgs[s][idx]);
            totalArgWrites++;
        }
        // pad to even
        if (t->numArgs % 2 != 0) {
            for (uint32_t s = 0; s < 2; s++) nInitialArgs->writeNode<uint32_t>(d, 0xdeadcafe);
            totalArgWrites++;
        }
        assert(totalArgWrites % 2 == 0);

        nDispatch->writeNode<uint8_t>(d, 1);
    }
}

void register_recipes(hw::Device* d, SIPNode_t* sipTree, lotus::TileId_t globalDestTile, lotus::TileId_t localDestTile) {
    auto tilePtr = sipTree->filterByName(SIPNode_t::createIdentifier("tile", localDestTile));
    auto getNode = [&tilePtr](const std::string& name) -> SIPNode_t* {
        return tilePtr->filterByName(name)->consumeFilter();
    };

    auto lowerBound = [](lotus::TileId_t gtid) {
        return std::lower_bound(&edgeInfo[0], &edgeInfo[sizeof(edgeInfo)/sizeof(lotus::EdgeInfo_t)], gtid,
            [](const lotus::EdgeInfo_t& info, lotus::TileId_t tileId) { return info.sourceTileId < tileId; });
    };

    auto nTileId = getNode("esc-tileId");
    auto nTaskId = getNode("esc-taskId");
    auto nFirstArg = getNode("esc-firstArg");
    auto nFlags = getNode("esc-flags");
    auto nDispatch = getNode("esc-dispatch");

    std::vector<SIPNode_t*> nOutRegIdx;
    for (uint16_t idx = 0; idx < 2; idx++)
        nOutRegIdx.push_back(getNode(SIPNode_t::createIdentifier("esc-outRegIdx", idx)));

    for (const lotus::EdgeInfo_t* e = lowerBound(globalDestTile); e < lowerBound(globalDestTile+1); e++) {
        nTileId->writeNodeCached<uint32_t>(d, e->targetTileId);
        nTaskId->writeNodeCached<uint32_t>(d, e->targetTaskId);
        nFirstArg->writeNodeCached<uint32_t>(d, e->firstArg);

        uint32_t flags = 0;
        if (e->cycleDelta) flags |= 0x1;
        if (e->hasMemDataDep) flags |= 0x2;
        nFlags->writeNodeCached<uint32_t>(d, flags);

        for (size_t idx = 0; idx < e->args.size(); idx++) {
            nOutRegIdx[idx]->writeNodeCached<uint32_t>(d, e->args[idx]);
        }

        nDispatch->writeNode<uint8_t>(d, 1);
    }
}

void register_scopes(hw::Device* d, lotus::TileId_t globalDestTile, lotus::TileId_t localDestTile) {
    auto lowerBound = [](lotus::TileId_t gtid) {
        return std::lower_bound(&scopeInfo[0], &scopeInfo[sizeof(scopeInfo)/sizeof(lotus::ScopeInfo_t)], gtid,
            [](const lotus::ScopeInfo_t& info, lotus::TileId_t tileId) { return info.scopeId < tileId; });
    };

    const lotus::ScopeInfo_t* s = lowerBound(globalDestTile);
    if (s == &scopeInfo[sizeof(scopeInfo)/sizeof(lotus::ScopeInfo_t)]) return;
    assert(s < &scopeInfo[sizeof(scopeInfo)/sizeof(lotus::ScopeInfo_t)]);
    d->write_mem(s->bytes, s->numBytes, s->startAddr);
}

size_t get_num_tasks(lotus::TileId_t globalDestTile) {
    auto lowerBound = [](lotus::TileId_t gtid) {
        return std::lower_bound(&taskInfo[0], &taskInfo[sizeof(taskInfo)/sizeof(lotus::TaskInfo_t)], gtid,
            [](const lotus::TaskInfo_t& info, lotus::TileId_t tileId) { return info.tileId < tileId; });
    };
    return std::distance(lowerBound(globalDestTile), lowerBound(globalDestTile+1));
}

void signalHandler(int sig) {
    HOST_PRINT("Exiting on signal %d\n", sig);
    hw::fini();
    exit(-1);
}

#include <iostream>
#include <vector>

// The program hex file is embedded in the binary
extern "C" {
extern char _binary_program_hex_start;
extern char _binary_program_hex_end;
};

// NOTE: Unlike previous load_code impl, this doesn't make any assumptions
// on where each segment should be and doesn't manually insert instructions.
// This code depends on the linker file to put the _start function at
// address 0x80000000.
void load_code(hw::Device* d) {
    HOST_PRINT("load_code();\n");
    auto hti = [&](char c)->uint32_t {
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        return c - '0';
    };

    auto hToI = [&](const char *c, uint32_t size)->uint32_t {
        uint32_t value = 0;
        for (uint32_t i = 0; i < size; i++) {
            value += hti(c[i]) << ((size - i - 1) * 4);
        }
        return value;
    };

    int offset = 0;
    char* line = (char*)&_binary_program_hex_start;
    size_t size = &_binary_program_hex_end - &_binary_program_hex_start;

    // dsm: Buffer writes in contiguous chunks. Written to be agnostic from the
    // code below; will buffer as lons as the writes are contiguous. Just
    // remember to flushBuf() at the end.
    uint32_t bufAddr = 0;
    std::vector<uint8_t> buf;
    auto flushBuf = [&]() {
        if (buf.size()) {
            d->write_mem(&buf[0], buf.size(), bufAddr);
            buf.clear();
        }
    };
    auto writeByte = [&](uint8_t byte, uint32_t addr) {
        if (bufAddr + buf.size() != addr) {
            flushBuf();
            bufAddr = addr;
        }
        buf.push_back(byte);
    };


    while (true) {
        if (line[0] == ':') {
            int ind = 0;
            while (line[ind] != '\n'){
                ++ind;
            }
            uint32_t byteCount = hToI(line + 1, 2);
            uint32_t nextAddr = hToI(line + 3, 4) + offset;
            uint32_t key = hToI(line + 7, 2);
            switch (key) {
                case 0:
                    for (uint32_t i = 0; i < byteCount; i++)
                        writeByte(hToI(line + 9 + i * 2, 2), nextAddr + i);
                    break;
                case 2:
                    offset = hToI(line + 9, 4) << 4;
                    break;
                case 4:
                    offset = hToI(line + 9, 4) << 16;
                    break;
                default:
                    break;
            }
        }
        while (*line != '\n' && size != 0) {
            ++line;
            --size;
        }
        if (size <= 1)
            break;
        ++line;
        --size;
    }
    flushBuf();
}


uint64_t read_cycle(hw::Device* d, SIPNode_t* sipTree) {
    return sipTree->filterByName("cycles")->readNode<uint64_t>(d);
}

class HeartbeatManager {
private:
    typedef struct {
        uint64_t                                           numHeartbeats;
        uint64_t                                           cycles; // When numHeartbeats was collected
        std::chrono::time_point<std::chrono::system_clock> time; // When numHeartbeats was collected
    } HeartbeatCapture_t;
    std::vector<HeartbeatCapture_t> heartbeats;
    std::vector<HeartbeatCapture_t> firstCapturedState;
    bool changedCycles = true;
    bool changedHbs = true;

    hw::Device* m_savedDevice;
    SIPNode_t* m_savedSipTree;
    uint8_t m_savedTile;

    HeartbeatCapture_t captureHeartbeatState(std::vector<hw::Device*> devices, std::vector<SIPNode_t*> sipTrees, const uint32_t N_TILES, const uint32_t N_CORES) {
        // Get number of heartbeats

        uint64_t numHbs = 0;
        if (m_savedDevice == nullptr) {
            // Figure out which device/tile the heartbeater runs on
            for (uint32_t dId = 0; dId < devices.size(); dId++) {
                hw::Device* d = devices[dId];
                SIPNode_t* sipTree = sipTrees[dId];
                for (uint8_t tileId = 0; tileId < N_TILES; tileId++) {
                    auto tilePtr = sipTree->filterByName(SIPNode_t::createIdentifier("tile", tileId));
                    for (uint8_t coreId = 0; coreId < N_CORES; coreId++) {
                        uint64_t currHbs = tilePtr->filterByName(SIPNode_t::createIdentifier("core", coreId) + ".coreSimNumHbReg")->readNode<uint64_t>(d);
                        numHbs += currHbs;
                        if (currHbs != 0) {
                            m_savedDevice = d;
                            m_savedSipTree = sipTree;
                            m_savedTile = tileId;
                        }
                    }
                }
            }
        } else {
            // Saves having to go through different many devices/tiles that'll always be 0
            auto tilePtr = m_savedSipTree->filterByName(SIPNode_t::createIdentifier("tile", m_savedTile));
            for (uint8_t coreId = 0; coreId < N_CORES; coreId++) {
                numHbs += tilePtr->filterByName(SIPNode_t::createIdentifier("core", coreId) + ".coreSimNumHbReg")->readNode<uint64_t>(m_savedDevice);
            }
        }

        // Get cyles
        uint64_t cycles = read_cycle(devices[0], sipTrees[0]);

        // Get time
        std::chrono::time_point<std::chrono::system_clock> now = std::chrono::system_clock::now();

        return {.numHeartbeats = numHbs, .cycles = cycles, .time = now};
    }

public:

    HeartbeatManager() : heartbeats({}), firstCapturedState({}), m_savedDevice(nullptr), m_savedSipTree(nullptr), m_savedTile(0) {}

    bool handleHeartbeat(std::vector<hw::Device*> devices, std::vector<SIPNode_t*> sipTrees, const uint32_t N_TILES, const uint32_t N_CORES) {
        HeartbeatCapture_t newState = captureHeartbeatState(devices, sipTrees, N_TILES, N_CORES);

        auto checkInitialDeadlock = [&]() -> bool {
            if (this->firstCapturedState.size() == 0) {
                this->firstCapturedState.push_back(newState);
                return false;
            }
            if (newState.numHeartbeats > firstCapturedState[0].numHeartbeats) {
                firstCapturedState[0] = newState;
                return false;
            }
            auto duration = std::chrono::duration_cast<std::chrono::minutes>(newState.time - firstCapturedState[0].time).count();
#ifdef TARGET_hw  // default values
            // 2 mins on FPGA with no heartbeats is sus
            return duration > 1;
#else
             // 20 mins on Verilator with no heartbeats is kinda sus (but might need to increase this value)
            return duration > 3;
#endif
        };

        // NOTE(farese): This determines warmup heartbeats
        if (newState.numHeartbeats > 3) {
            fflush(stdout);
            if (heartbeats.size() == 0) {
                //assert(newState.numHeartbeats == 1 && "Should start by capturing the first heartbeat");
                HOST_PRINT("CAPTURED HEARTBEATS=%lu Cycles=%lu\n", newState.numHeartbeats, newState.cycles);
                heartbeats.push_back(newState);
            } else if (heartbeats.size() == 1) {
                if (newState.numHeartbeats > heartbeats[0].numHeartbeats) {
                    HOST_PRINT("CAPTURED HEARTBEATS=%lu Cycles=%lu\n", newState.numHeartbeats, newState.cycles);
                    heartbeats.push_back(newState);
                } else {
                    return false;
                }
            } else if (heartbeats.size() >= 2) {
                if ((newState.numHeartbeats >= heartbeats[1].numHeartbeats) || (newState.cycles == heartbeats[1].cycles)) {
                    HOST_PRINT("CAPTURED HEARTBEATS=%lu Cycles=%lu\n", newState.numHeartbeats, newState.cycles);
                    changedCycles = heartbeats[heartbeats.size()-1].cycles != newState.cycles;
                    changedHbs = heartbeats[heartbeats.size()-1].numHeartbeats != newState.numHeartbeats;
                    heartbeats[heartbeats.size()-1] = newState;
                } else {
                    // Detect deadlock if we spend 5x the average cycles per heartbeat without one
                    assert(newState.numHeartbeats == heartbeats[1].numHeartbeats);
                    auto cyclesSinceLastHeartbeat = newState.cycles - heartbeats[1].cycles;
                    auto avgCyclesPerHeartbeat = (heartbeats[1].cycles - heartbeats[0].cycles) / (heartbeats[1].numHeartbeats - heartbeats[0].numHeartbeats);
                    assert(heartbeats.size() == 2);
                    if (cyclesSinceLastHeartbeat > 5 * avgCyclesPerHeartbeat) {
                        HOST_PRINT("heartbeats.size()=%lu -- heartbeats[-1] = {.numHeartbeats=%lu, cycles=%lu} -- newState = {.numHeartbeats=%lu, cycles=%lu}",
                                   heartbeats.size(), heartbeats[1].numHeartbeats, heartbeats[1].cycles, newState.numHeartbeats, newState.cycles);
                        HOST_PRINT("DEADLOCK DETECTED Cycles=%lu (%lu without a heartbeat)\n", newState.cycles, cyclesSinceLastHeartbeat);
                        return true;
                    }
                }
            } else {
                printf("Heartbeats size: %lu\n", heartbeats.size());
                assert(false && "Should only be two");
            }
        } else {
            return checkInitialDeadlock();
        }

        return false;
    }

    bool capturedEnoughHeartbeats(uint64_t maxHeartbeats) {
        // if (heartbeats.size() < 2) {
        //     return false;
        // }
        return !changedCycles;
    }

    void printHeartbeatStats(uint64_t maxHeartbeats) {
        if (!capturedEnoughHeartbeats(maxHeartbeats)) {
            HOST_PRINT("ERROR: Not enough Heartbeats\n");
        }
        if (heartbeats.size() < 2) {
            return;
        }
        assert(heartbeats.size() >= 2);
        HeartbeatCapture_t last  = heartbeats[heartbeats.size() - 1];

        MEASUREMENT_UNIT_T time_diff = std::chrono::duration_cast<MEASUREMENT_UNIT_T>(last.time - heartbeats[0].time);

        std::cout << HOST_PREFIX;
        std::cout << "[SimulationStats] ";
        std::cout << "Total Hearbeats=" << last.numHeartbeats << ", ";
        std::cout << "Total Cycles=" << last.cycles << ", ";
        std::cout << "Time took=" << time_diff.count() << " " << MEASUREMENT_UNIT_N;
        std::cout << "\n";

        HOST_PRINT("[SimulationStats] cyclesPerHeartbeat=%lu\n", last.cycles / last.numHeartbeats);
    }

};

bool handleFailSimulation(hw::Device* d, SIPNode_t* sipTree, const uint32_t N_CORES) {
    uint64_t esim = 0;
    for (uint8_t coreId = 0; coreId < N_CORES; coreId++) {
        auto tilePtr  = sipTree->filterByName(SIPNode_t::createIdentifier("tile", 0));
        esim += tilePtr->filterByName(SIPNode_t::createIdentifier("core", coreId) + ".coreSimFailReg")->readNode<uint64_t>(d);
    }
    return esim != 0;
}

uint64_t getSimulationTimeout() {
    const char* envCycles = getenv("LOTUS_SIM_TIMEOUT_CYCLES");
    return envCycles? strtoul(envCycles, nullptr, 10) : -1ul;
}

uint64_t getMaxHeartbeats() {
    const char* envHbs = getenv("LOTUS_SIM_HEARTBEATS");
    return envHbs? strtoul(envHbs, nullptr, 10) :
#ifdef TARGET_hw  // default values
        10000000;
#else
        100;
#endif
}

SIPNode_t* createSIPGlobal() {
    return SIPNode_t::createMux("SipGlobal",
            {
                SIPNode_t::createTable("glob-cycleTable", SIPType_t::SIPCounter, 5,
                        {"cycles"}),
                SIPNode_t::createTable("glob-mainTable" , SIPType_t::SIPStatus, 2,
                        {"N_TILES", "N_CORES", "N_ARGS", "N_L2BANKS", "N_TASKS_PER_TILE", "API_VERSION_HI", "API_VERSION_LO"}),
            }
            );
}

std::vector<std::string> convertToFIFONames(std::string prefix, std::vector<std::string> originalNames) {
    std::vector<std::string> fifoNames;
    for (const std::string& name : originalNames) {
        fifoNames.push_back(prefix + "-" + name + "-numEnqs");
        fifoNames.push_back(prefix + "-" + name + "-numDeqs");
    }
    return fifoNames;
}

std::vector<std::string> mergeVectors(const std::vector<std::string>& a, const std::vector<std::string>& b) {
    std::vector<std::string> out;
    for (const std::string& s : a) out.push_back(s);
    for (const std::string& s : b) out.push_back(s);
    return out;
}

SIPNode_t* createSIPTile(const uint16_t tileId, const uint16_t N_CORES, const uint16_t N_ARGS, const uint16_t N_L2BANKS) {

    const std::vector<std::string> configRegNames = [N_ARGS](){
        std::vector<std::string> names = {};
        names.push_back("tuc-taskId");
        names.push_back("tuc-taskFn");
        names.push_back("tuc-taskSize");
        names.push_back("tuc-firstArgIdx");
        names.push_back("tuc-numArgs");
        names.push_back("tuc-numInEdges");
        names.push_back("tuc-numOutEdges");
        names.push_back("tuc-firstEdgeIdxStart");
        names.push_back("tuc-numOutArgs");
        names.push_back("tuc-taskFlags");
        names.push_back("tuc-numInEdgesReceivedFirstCycle");

        // Writes send stackPtr to cores sequentially (first write to core0, then to core1, etc)
        names.push_back("tuc-stackBase");

        // Writes apply to argsMem sequentially (first write to idx 0, then idx 1, etc.)
        names.push_back("tuc-initialArgs");
        return names;
    }();

    const std::vector<std::string> l2PerfNames = [N_L2BANKS]() {
        std::vector<std::string> names = {};
        for (uint16_t bank_id = 0; bank_id < N_L2BANKS; bank_id++) {

            std::string base_name = SIPNode_t::createIdentifier("l2bank", bank_id);
            std::vector<const char*> counter_names = {"l2CoreReq", "l2SerializerStall", "l2ReadMiss", "l2WriteMiss", "l2NeedsWriteback", "l2BankSwitchStall"};

            for (auto& counter_name : counter_names) {
                names.push_back(base_name + "." + counter_name);
            }
        }
        return names;
    }();

    const std::vector<std::string> edgeSenderConfigRegNames = [](){
        std::vector<std::string> names = {};
        names.push_back("esc-taskId");
        names.push_back("esc-tileId" );
        names.push_back("esc-firstArg");
        names.push_back("esc-flags" );
        for (uint32_t i = 0; i < 2; i++)
            names.push_back(SIPNode_t::createIdentifier("esc-outRegIdx", i));
        return names;
    }();

    const std::vector<std::string> corePerfCounterNames = {"coreHasTask", "coreInstrsCommit",
        "coreIcacheStall", "coreDcacheStall", "coreDcacheReadReq", "coreDcacheWriteReq",
        "coreIL2Req", "coreDL2ReadReq", "coreDL2WriteReq", "coreL2Stall",
        "coreSimNumHbReg", "coreSimFailReg"};

    std::vector<std::string> corePerfCounters;
    for (uint16_t coreId = 0; coreId < N_CORES; coreId++) {
        auto prefix = SIPNode_t::createIdentifier("core", coreId) + ".";
        for (auto c : corePerfCounterNames) corePerfCounters.push_back(prefix + c);
    }

    std::vector<SIPNode_t*> tileChildren = {
                SIPNode_t::createMux("edgeSenderConfig",
                        {
                            SIPNode_t::createTable("esc-configReg", SIPType_t::SIPControl, 4,
                                    edgeSenderConfigRegNames),
                            SIPNode_t::createTable("esc-dispatchReg", SIPType_t::SIPControl, 1,
                                    {"esc-dispatch"}),
                            SIPNode_t::createTable("esc-perf", SIPType_t::SIPCounter, 5,
                                                   convertToFIFONames("edgeSender", {"outBaseQueue", "outQueue", "enqMetadataQ", "argInfoQ", "reqMetadata", "edgeReqQ", "tokenPacketOutQ_"})),
                        }),
                SIPNode_t::createMux("taskUnitConfig",
                        {
                            SIPNode_t::createTable("tuc-configReg", SIPType_t::SIPControl, 4,
                                    configRegNames),
                            SIPNode_t::createTable("tuc-dispatchReg", SIPType_t::SIPControl, 1,
                                    {"tuc-dispatch"}),
                        }),
                SIPNode_t::createMux("taskUnit",
                        {
                            SIPNode_t::createTable("tu-controlReg", SIPType_t::SIPControl, 2,
                                    {"tuExecControl", "configTileId", "simCyclesLo", "simCyclesHi"}),
                            SIPNode_t::createTable("tu-perf", SIPType_t::SIPCounter, 5,
                                                   mergeVectors({"totalEnq", "localEnq", "networkEnq", "taskRunnable", "deqTask", "skipTask", "configTask", "deqCoreStall", "deqTUStall", "PqBypass"},
                                                                convertToFIFONames("taskUnit", {"localTileEnqFifo", "outEnqsFifo", "outEnqBaseQueue", "outEnqPipe", "inEnqBaseQueue", "inEnqPipe"})
                                                                )),
                            SIPNode_t::createTable("tuc-dump-controls", SIPType_t::SIPControl, 1,
                                    {"tuc-dump-start", "tuc-dump-consumed"}),
                            SIPNode_t::createTable("glob-dump-status" , SIPType_t::SIPStatus, 4,
                                    {"tuc-dump-first", "tuc-dump-notEmpty"})
                        }),
                SIPNode_t::createMux("l2",
                        {
                            SIPNode_t::createTable("l2-perf", SIPType_t::SIPCounter, 5,
                                    l2PerfNames)
                        }),
                SIPNode_t::createTable("tile-controlRegs", SIPType_t::SIPControl, 4,
                        {"routingInfo"}),
                SIPNode_t::createTable("tile-perf", SIPType_t::SIPCounter, 5,
                        corePerfCounters),
    };

    // The tile has a splitter that works on the top-level bit, so stuff
    // tileChildren with dummy entries to get the indexing right
    while (tileChildren.size() < 128) {
        std::string name = "tile-dummy" + std::to_string(tileChildren.size());
        tileChildren.push_back(SIPNode_t::createTable(name, SIPType_t::SIPControl, 4, {"dummy"}));
    }
    // The actual memToSip endpoints; these could be a single one (the address doesn't matter so long it's >=128)
    tileChildren.push_back(new SIPNode_t("mts-start", SIPType_t::SIPControl, 4));
    tileChildren.push_back(new SIPNode_t("mts-reqStatus", SIPType_t::SIPStatus, 1));

    return SIPNode_t::createMux(SIPNode_t::createIdentifier("tile", tileId), tileChildren);
}

std::string prettyPrintApiVersion(uint32_t v) {
    char buf[128];
    snprintf(buf, sizeof(buf), "%04d/%02d/%02d.%02d",
            (v / 1'00'00'00), (v / 1'00'00) % 100,
            (v / 1'00) % 100, v % 100);
    std::string res(buf);
    return res;
}

SIPNode_t* createSIPTree(hw::Device* lead) {
    SIPNode_t* root = (new SIPNode_t("Multile", SIPType_t::SIPMux, -1))
                        ->addChild(createSIPGlobal());

    const uint16_t N_TILES   = root->filterByName("N_TILES")->readNode<uint16_t>(lead);
    const uint16_t N_CORES   = root->filterByName("N_CORES")->readNode<uint16_t>(lead);
    const uint16_t N_ARGS    = root->filterByName("N_ARGS") ->readNode<uint16_t>(lead);
    const uint16_t N_L2BANKS = root->filterByName("N_L2BANKS")->readNode<uint16_t>(lead);
    const uint16_t N_TASKS_PER_TILE = root->filterByName("N_TASKS_PER_TILE")->readNode<uint16_t>(lead);

    // dsm: Rest of counters are 16 bits, didn't want to add a 32-bit one just for this
    const uint16_t hwApiVersionHi = root->filterByName("API_VERSION_HI")->readNode<uint16_t>(lead);
    const uint16_t hwApiVersionLo = root->filterByName("API_VERSION_LO")->readNode<uint16_t>(lead);
    const uint32_t hwApiVersion = (((uint32_t)hwApiVersionHi) << 16) | hwApiVersionLo;

    HOST_PRINT("N_TILES_   from ocl_reg: %u\n", N_TILES);
    HOST_PRINT("N_CORES_   from ocl_reg: %u\n", N_CORES);
    HOST_PRINT("N_ARGS_    from ocl_reg: %u\n", N_ARGS);
    HOST_PRINT("N_TASKS_PER_TILE_ from ocl_reg: %u\n", N_TASKS_PER_TILE);

    if (hwApiVersion == LOTUS_API_VERSION) {
        HOST_PRINT("API version  (matching): %s\n", prettyPrintApiVersion(hwApiVersion).c_str());
    } else {
        HOST_PRINT("ERROR: API version mismatch: HW: %s != SW: %s\n", prettyPrintApiVersion(hwApiVersion).c_str(),
                prettyPrintApiVersion(LOTUS_API_VERSION).c_str());
        exit(-1);
    }

    for (uint16_t tileId = 0; tileId < N_TILES; tileId++) {
        root->addChild(createSIPTile(tileId, N_CORES, N_ARGS, N_L2BANKS));
    }

    return root;
}

void dumpTileStats(std::vector<hw::Device*> devices, std::vector<SIPNode_t*> sipTrees) {

    uint16_t N_TILES = sipTrees[0]->filterByName("N_TILES")->readNode<uint16_t>(devices[0]);
    uint16_t tasksPerTile = sipTrees[0]->filterByName("N_TASKS_PER_TILE")->readNode<uint16_t>(devices[0]);
    unsigned bitsForTaskId = static_cast<unsigned>(std::ceil(std::log2(tasksPerTile)));
    uint16_t mask = (1 << bitsForTaskId) - 1;


    std::cout << "=============== START dumpTileStats" << std::endl;

    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];
        auto delay = [&d, &dSip](int delayCycles) {
            uint64_t startCycle = read_cycle(d, dSip);
            uint64_t endCycle =  startCycle + static_cast<uint64_t>(delayCycles);
            while (read_cycle(d, dSip) < endCycle) { /* wait */ }
        };
        for (lotus::TileId_t localTileId = 0; localTileId < N_TILES; localTileId++) {
            auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", localTileId));

            auto dumpStart    = tilePtr->filterByName("tuc-dump-start")->consumeFilter();
            auto dumpConsumed = tilePtr->filterByName("tuc-dump-consumed")->consumeFilter();
            auto dumpFirst    = tilePtr->filterByName("tuc-dump-first")->consumeFilter();
            auto dumpNotEmpty = tilePtr->filterByName("tuc-dump-notEmpty")->consumeFilter();

            dumpStart->writeNode<uint8_t>(d, 1);

            delay(100);

            while (dumpNotEmpty->readNode<uint32_t>(d)) {
                uint32_t value = dumpFirst->readNode<uint32_t>(d);
                uint32_t taskId = value & mask;
                uint32_t cycleId = value >> bitsForTaskId;
                printf("DumpEntry: deviceId=%lu, tileId=%u, taskId=%u, cycleId=%u, taskIdInHex=0x%x, rawValue=%x\n", d_id, localTileId, taskId, cycleId, taskId, value);
                dumpConsumed->writeNode<uint8_t>(d, 1);
            }

        }
        HOST_PRINT("[%ld] Task configuration for device %lu completed\n", read_cycle(d, dSip), d_id);
    }
    std::cout << "=============== END dumpTileStats" << std::endl;
}

int main(int argc, const char* argv[]) {
    auto devices = hw::init(argc, argv);
    std::vector<SIPNode_t*> sipTrees;
    for (auto& device: devices) {
        sipTrees.push_back(createSIPTree(device));
    }

    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    // TODO: Make synchronization configurable at finer grain (from no to full
    // overlap, which is effectively disabling barriers)
    bool selfBarriers = true;
    bool selectiveExecution = false;
    for (int i = 1; i < argc; i++) if (strcmp(argv[i], "-s") == 0) selectiveExecution = true;

    HOST_PRINT("selfBarriers=%d, selectiveExecution=%d\n", selfBarriers, selectiveExecution);

    auto dump_perf_counters = [&](const std::string& postFix ) {
        vector<tuple<string, string>> enteries;
        for (size_t d_id = 0; d_id < devices.size(); d_id++) {
            auto& d = devices[d_id];
            auto& dSip = sipTrees[d_id];
            dSip->filterByType(SIPType_t::SIPCounter)->dump(d, enteries, d_id);
        }
        std::ostringstream oss;
        oss << "{\n";
        auto last_i = enteries.size()-1;
        for (size_t i = 0; i < enteries.size(); i++) {
            auto& ent = enteries[i];

            oss << "\"" << std::get<0>(ent) << "\": " << std::get<1>(ent);
            if (i != last_i) oss << ",";
            oss << "\n";
        }
        oss << "}\n";
        std::string se = selectiveExecution ? ".SE" : ".DF";
        std::ofstream outfile(std::string{argv[0]} + se + ".perf_counters." + postFix);
        outfile << oss.str();
    };


    auto lead    = devices[0];
    auto leadSip = sipTrees[0];

    const uint16_t N_TILES   = leadSip->filterByName("N_TILES")->readNode<uint16_t>(lead);
    const uint16_t N_CORES   = leadSip->filterByName("N_CORES")->readNode<uint16_t>(lead);
    const uint16_t N_ARGS    = leadSip->filterByName("N_ARGS")->readNode<uint16_t>(lead);

    HOST_PRINT("N_TILES   from ocl_reg: %u\n", N_TILES);
    HOST_PRINT("N_CORES   from ocl_reg: %u\n", N_CORES);
    HOST_PRINT("N_ARGS    from ocl_reg: %u\n", N_ARGS);

    // Compute per-task data needed for configuration but not provided by
    // hostInit.h (since hostInit data is produced in multiple places, we want
    // it to be a narrow interface)
    std::map<std::tuple<lotus::TileId_t, lotus::TaskId_t>, lotus::NEdges_t> taskToInEdges;
    std::map<std::tuple<lotus::TileId_t, lotus::TaskId_t>, lotus::NEdges_t> taskToCrossCycleInEdges;
    for (const lotus::EdgeInfo_t& e : edgeInfo) {
        auto key = std::make_tuple(e.targetTileId, e.targetTaskId);
        if (taskToInEdges.count(key) == 0) {
            taskToInEdges[key] = 0;
            taskToCrossCycleInEdges[key] = 0;
        }
        taskToInEdges[key] += 1;
        if (e.cycleDelta != 0) taskToCrossCycleInEdges[key] += 1;
    }

    for (const lotus::TaskInfo_t& t : taskInfo) {
        auto key = std::make_tuple(t.tileId, t.taskId);
        auto numInEdges = taskToInEdges[key];
        auto numCrossCycleInEdges = taskToCrossCycleInEdges[key];
        taskInEdges.push_back(numInEdges);
        taskCrossCycleInEdges.push_back(numCrossCycleInEdges);
    }

    // Configure each device
    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];

        HOST_PRINT("[%ld] Initializing device %d\n", read_cycle(d, dSip), d->get_id());

        if (d->get_id() != lead->get_id()) {
            const uint16_t N_TILES_D = dSip->filterByName("N_TILES")->readNode<uint16_t>(d);
            const uint16_t N_CORES_D = dSip->filterByName("N_CORES")->readNode<uint16_t>(d);
            const uint16_t N_ARGS_D  = dSip->filterByName("N_ARGS")->readNode<uint16_t>(d);
            assert(N_TILES_D == N_TILES);
            assert(N_CORES_D == N_CORES);
            assert(N_ARGS_D == N_ARGS);
        }

        uint32_t routingInfo = d->get_id();
#if MULTI_DEVICE
        uint32_t numNodes = network::getNumNodes();
        uint32_t numPorts = network::getNumPorts();
        uint32_t log2NumPorts = network::getLog2NumPorts();
        assert(numNodes <= numPorts);
        assert(d->get_id() < numNodes);
        HOST_PRINT("[%ld] Configuring routing info for %d nodes and %d ports\n", read_cycle(d, dSip), numNodes, numPorts);
        std::vector<uint32_t> srcPorts;
        routingInfo = routingInfo << (log2NumPorts * (numPorts - numNodes));
        for (int dst = numNodes-1; dst >= 0; dst--) {
            bool nonSelf = dst != d->get_id();
            uint32_t srcPort = nonSelf? network::getSrcPort(d->get_id(), dst) : 0;
            assert(srcPort < network::getNumPorts());
            if (nonSelf) {
                srcPorts.push_back(srcPort);
            } else {
                srcPort = 0;
            }
            routingInfo = (routingInfo << log2NumPorts) | srcPort;
        }
        //HOST_PRINT("[%d] port0 = %d | %ld | %x\n", d->get_id(), srcPorts[0], srcPorts.size(), routingInfo);
        d->enable_cross_device_links(srcPorts);
#endif

        for (uint16_t local_tile_id = 0; local_tile_id < N_TILES; local_tile_id++) {
            uint16_t chip_id = d->get_id();
            uint16_t global_tile_id = global_tileId(chip_id, local_tile_id, N_TILES);
            auto tilePtr  = dSip->filterByName(SIPNode_t::createIdentifier("tile", local_tile_id));
            tilePtr->filterByName("configTileId")->writeNode(d, global_tile_id);
            tilePtr->filterByName("routingInfo")->writeNode(d, routingInfo);
        }

        load_code(d);
        uint8_t chip_id = (uint8_t) d->get_id();
        // Device ID scratch location used by the runtime.
        d->write_mem(&chip_id, 1, 0x60000000);

        uint32_t sipStreamAddr = 0x70000000;
        HOST_PRINT("[%ld] Registering scopes and tasks\n", read_cycle(d, dSip));
        for (lotus::TileId_t localTileId = 0; localTileId < N_TILES; localTileId++) {
            lotus::TileId_t globalTileId = global_tileId(d->get_id(), localTileId, N_TILES);
            HOST_PRINT("[%ld]     Registering scope and tasks for localTileId=%u and globalTileId=%u\n", read_cycle(d, dSip), localTileId, globalTileId);
            register_scopes(d, globalTileId, localTileId);

            // Use memToSIP to configure from memory
            auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", localTileId));
            // FIXME(dsm): Rework stats code to avoid FilterNode/consumeFilter.
            // filterNode(...)->getNodeAddr() returns an empty address because
            // there's a special type of node that wraps around a normal node,
            // and this node has no addr... and consumeFilter()... consumes it?
            // Why not just return the actual node??
            auto tileAddr = tilePtr->filterByName("mts-start")->consumeFilter()->getNodeAddr();
            tileAddr.pop_back(); // we want the addr of the tile, and this is one level below (FIXME, see above)
            d->start_sip_stream(tileAddr);
            register_tasks(d, dSip, globalTileId, localTileId, selectiveExecution);
            register_recipes(d, dSip, globalTileId, localTileId);
            auto stream = d->end_sip_stream();

            uint32_t sipStreamEndAddr = sipStreamAddr + stream.size();
            HOST_PRINT("[%ld]     Stream Size: %lx -- startAddr: %x -- endAddr: %x\n", read_cycle(d, dSip), stream.size(), sipStreamAddr, sipStreamEndAddr);
            assert(sipStreamEndAddr < 0x80000000 && "Need to to not overwrite program data");
            d->write_mem(&stream[0], stream.size(), sipStreamAddr);

            // Start config request
            tilePtr->filterByName("mts-start")->writeNode<uint32_t>(d, sipStreamAddr);

            // Keep address cache-aligned
            sipStreamAddr += stream.size() + (64 - (stream.size() % 64));
        }
    }

    // Check all tiles have finished configuration
    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];
        for (lotus::TileId_t localTileId = 0; localTileId < N_TILES; localTileId++) {
            auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", localTileId));
            uint8_t status;
            while (true) {
                status = tilePtr->filterByName("mts-reqStatus")->readNode<uint8_t>(d);
                if ((status & 0x2) == 0) break;
            }
            if (status != 0) {
                // If this triggers, you're probably messing up the configuration stream...
                HOST_PRINT("[%ld] WARNING: Device %lu tile %u received non-ACK responses during configuration; status=%u\n", read_cycle(d, dSip), d_id, localTileId, status);
            }
        }
        HOST_PRINT("[%ld] Task configuration for device %lu completed\n", read_cycle(d, dSip), d_id);
    }

    // Core initialization
    auto calculateStackPtrBase = [](uint32_t coreId, uint32_t numBanks, uint32_t clBits, uint32_t chunkBits, uint32_t wordBits, uint32_t stackPtrBaseAddr) {
        uint32_t byteSelBits = std::log2(wordBits / 8);
        uint32_t wordSelBits = std::log2(chunkBits / wordBits);
        uint32_t chunkSelBits = std::log2(clBits / chunkBits);

        uint32_t bankSelBits = std::log2(numBanks);
        uint32_t bankShift = byteSelBits + wordSelBits + chunkSelBits;

        uint32_t coreBankId = coreId << bankShift;
        uint32_t stackPtrBase = stackPtrBaseAddr - coreBankId;

        return stackPtrBase;
    };
    HOST_PRINT("[%ld] Configuring stackPtr for each core\n", read_cycle(lead, leadSip));
    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];
        for (uint8_t tileId = 0; tileId < N_TILES; tileId++) {
            for (uint8_t coreId = 0; coreId < N_CORES; coreId++) {
                uint32_t useCoreId = coreId + (tileId*N_CORES);
                uint32_t stackPtrBase = 0xFF000000 - (2*(useCoreId << 20));
                stackPtrBase = calculateStackPtrBase(coreId, 4, 512, 64, 32, stackPtrBase);
                auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", tileId));
                auto nStackBase = tilePtr->filterByName("tuc-stackBase")->consumeFilter();
                nStackBase->writeNode<uint32_t>(d, stackPtrBase);
            }
        }
    }

    HOST_PRINT("[%ld] Waiting for cross-device links\n", read_cycle(lead, leadSip));
    hw::wait_for_cross_device_links();

    if (lead->get_id() == 0 && network::getNumNodes() > devices.size()) {
        HOST_PRINT("[%ld] Waiting for slave group to start\n", read_cycle(lead, leadSip));
        usleep(20 * 1000 * 1000);
    }

    HOST_PRINT("All benchmarks do a hearbeat every cycle now.\n");
    HOST_PRINT("[%ld] Starting execution\n", read_cycle(lead, leadSip));

    const uint64_t MAX_HEARTBEATS = getMaxHeartbeats();
    uint32_t simCycles   = static_cast<uint32_t>(MAX_HEARTBEATS) + 8;
    uint16_t simCyclesLo = static_cast<uint16_t>(simCycles);
    uint16_t simCyclesHi = static_cast<uint16_t>(simCycles >> 16);
    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];
        for (int tile_id = 0; tile_id < N_TILES; tile_id++) {
            auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", tile_id));
            tilePtr->filterByName("simCyclesLo")->writeNode(d, simCyclesLo);
            tilePtr->filterByName("simCyclesHi")->writeNode(d, simCyclesHi);
        }
    }
    for (size_t d_id = 0; d_id < devices.size(); d_id++) {
        auto& d = devices[d_id];
        auto& dSip = sipTrees[d_id];
        for (int tile_id = 0; tile_id < N_TILES; tile_id++) {
            auto tilePtr = dSip->filterByName(SIPNode_t::createIdentifier("tile", tile_id));
            // lotus::TileId_t globalTileId = N_TILES*d->get_id() + tile_id;
            lotus::TileId_t globalTileId = global_tileId(d->get_id(), tile_id, N_TILES);
            auto tileTasks = get_num_tasks(globalTileId);
            uint16_t tuExecControl = ((tileTasks-1) << 2) | ((selfBarriers? 1 : 0) << 1) | 1;
            HOST_PRINT("Tile gtid=%d has %ld tasks\n", globalTileId, tileTasks);
            tilePtr->filterByName("tuExecControl")->writeNode(d, tuExecControl);
        }
    }

    if (lead->get_id() == 0) {
        auto master = lead;
        auto masterSip = leadSip;
        const uint64_t TIMEOUT_CYCLES = getSimulationTimeout();

        HOST_PRINT("[%ld] Waiting until completion -- %lu heartbeats or %lu cycles\n",
                read_cycle(master, masterSip), MAX_HEARTBEATS, TIMEOUT_CYCLES);

        bool simTimeout = false;
        bool deadlocked = false;
        HeartbeatManager hbManager;
        while(!simTimeout && !hbManager.capturedEnoughHeartbeats(MAX_HEARTBEATS)) {
            deadlocked = hbManager.handleHeartbeat(devices, sipTrees, N_TILES, N_CORES);
            if (deadlocked) break;

            for (size_t d_id = 0; d_id < devices.size(); d_id++) {
                auto& d = devices[d_id];
                auto& dSip = sipTrees[d_id];
                dSip->filterByType(SIPType_t::SIPCounter)->capture(d);
            }

            simTimeout = read_cycle(master, masterSip) > TIMEOUT_CYCLES;

            // FIXME(dsm): XRT has a memory leak on reg reads, so we need to
            // throttle them. This should be using some version of
            // wait_for_ocl_reg, instead of just pounding on reg reads...
#ifdef TARGET_hw
            usleep(100);
#endif
        }
        HOST_PRINT("[%ld] Execution completed (done=%d, timeout=%d, deadlocked=%d)\n", read_cycle(master, masterSip), !simTimeout && !deadlocked, simTimeout, deadlocked);
        hbManager.printHeartbeatStats(MAX_HEARTBEATS);
        for (size_t d_id = 0; d_id < devices.size(); d_id++) {
            auto& d = devices[d_id];
            auto& dSip = sipTrees[d_id];
            dSip->filterByType(SIPType_t::SIPCounter)->capture(d);
        }
        dump_perf_counters("parent");
        //dumpTileStats(devices, sipTrees);
    } else {
        char hostname[1024];
        memset(hostname, sizeof(hostname), 0);
        gethostname(hostname, sizeof(hostname)-1);
        HOST_PRINT("[%ld] Slave FPGA group in %s ready for use\n", read_cycle(lead, leadSip), hostname);

        fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
        int ch;
        while ((ch = getchar()) == EOF) {
            for (size_t d_id = 0; d_id < devices.size(); d_id++) {
                auto& d = devices[d_id];
                auto& dSip = sipTrees[d_id];
                dSip->filterByType(SIPType_t::SIPCounter)->capture(d);
            }
#ifdef TARGET_hw
            usleep(100);
#endif
        }

        for (size_t d_id = 0; d_id < devices.size(); d_id++) {
            auto& d = devices[d_id];
            auto& dSip = sipTrees[d_id];
            dSip->filterByType(SIPType_t::SIPCounter)->capture(d);
        }
        dump_perf_counters("child");
        HOST_PRINT("[%ld] Slave FPGA group in %s done, exiting\n", read_cycle(lead, leadSip), hostname);
    }

    hw::fini();
    return 0;
}
