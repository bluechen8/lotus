/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

#include <stdint.h>

namespace network {

// Dancehall topology generator following the schema used in the 8-FPGA prototype
// NOTE: Ignores the extra cross-bisection connections, probably assumes
// numNodes is a power of 2.
//
// This wiring makes routing easy, and enforces that source and destination
// ports are ALWAYS connected to separate halves, i.e.,
// if srcPort < numNodes/2, then dstPort >= numNodes/2 and viceversa.

uint32_t getSrcPort(uint32_t srcId, uint32_t dstId);

uint32_t getDstId(uint32_t srcId, uint32_t srcPort);

void printTopology();

void setIdMap(uint32_t physicalStartId, uint32_t logicalStartId, uint32_t numNodes);

uint32_t getNumNodes();
uint32_t getNumPorts();
uint32_t getLog2NumPorts();

};
