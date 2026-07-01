/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include "network.h"
#include "hw.h"

#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <assert.h>

namespace network {

// Dancehall topology generator following the schema used in the 8-FPGA prototype
// NOTE: Ignores the extra cross-bisection connections, probably assumes
// numNodes is a power of 2.
//
// This wiring makes routing easy, and enforces that source and destination
// ports are ALWAYS connected to separate halves, i.e.,
// if srcPort < numNodes/2, then dstPort >= numNodes/2 and viceversa.

static uint32_t physicalStartId = -1;
static uint32_t logicalStartId = -1;
static uint32_t numNodes = -1;

static const uint32_t log2NumPorts =
#if MULTI_DEVICE
#if defined(TARGET_hw) or defined(TARGET_hw_emu)
        // XRT builds always use 8 devices, so the routing table must reflect this
        3;
#else
        // Verilator builds use the number of cross-device ports matching LOG2_MAX_DEVICES
        LOG2_MAX_DEVICES;
#endif
#else
        // Single-device builds... nothing to do
        0;
#endif

static const uint32_t numPorts = (1 << log2NumPorts);

void setIdMap(uint32_t _physicalStartId, uint32_t _logicalStartId, uint32_t _numNodes) {
    physicalStartId = _physicalStartId;
    logicalStartId = _logicalStartId;
    numNodes = _numNodes;
    assert(physicalStartId >= logicalStartId);
    assert(physicalStartId < numPorts);
    assert(logicalStartId < numNodes);
}

static inline uint32_t toP(uint32_t lId) { return lId + physicalStartId - logicalStartId; }
static inline uint32_t toL(uint32_t pId) { return pId + logicalStartId - physicalStartId; }

uint32_t getNumNodes() { return numNodes; }
uint32_t getNumPorts() { return numPorts; }
uint32_t getLog2NumPorts() { return log2NumPorts; }

uint32_t getSrcPort(uint32_t srcId, uint32_t dstId) {
    assert(srcId < numNodes && dstId < numNodes);
    assert(toP(srcId) < numPorts && toP(dstId) < numPorts);
    assert(srcId != dstId);
    return (numPorts + toP(dstId) - toP(srcId) - ((toP(srcId) >= numPorts/2)? 0 : 1)) % numPorts;
}

uint32_t getDstId(uint32_t srcId, uint32_t srcPort) {
    assert(srcId < numNodes && srcPort < numPorts);
    assert(toP(srcId) < numPorts);
    uint32_t pDstId = (numPorts + srcPort + toP(srcId)  + ((toP(srcId) >= numPorts/2)? 0 : 1)) % numPorts;
    return pDstId == toP(srcId)? -1 : toL(pDstId);
}

void printTopology() {
    for (uint32_t srcId = 0; srcId < numNodes; srcId++) {
        for (uint32_t srcPort = 0; srcPort < numPorts; srcPort++) {
            uint32_t dstId = getDstId(srcId, srcPort);
            if (dstId >= numNodes) {
                printf("%d.%d <-> X\n", srcId, srcPort);
            } else {
                uint32_t dstPort = getSrcPort(dstId, srcId);
                printf("%d.%d <-> %d.%d\n", srcId, srcPort, dstId, dstPort);
                // Check symmetry
                assert(getDstId(dstId, dstPort) == srcId);
                assert(getSrcPort(srcId, dstId) == srcPort);
                // Check port-half invariant
                assert((srcPort < numPorts/2)? (dstPort >= numPorts/2) : (dstPort < numPorts/2));
            }
        }
    }
}

};
