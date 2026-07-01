/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

#include <array>
#include <cstdint>
#include <cstdio>

#include "lotus_task_api.h"

#include <optional>
#include <tuple>
#include <bit>

using std::optional;
using std::tuple;
using std::array;

// #define PRINTF(fmt, ...) \
//     do { \
//         printf(fmt, ##__VA_ARGS__); \
//         fflush(stdout); \
//     } while (0)

// #define CORE_PRINTF(fmt, ...) PRINTF(fmt, ##__VA_ARGS__)


#define PRINTF(fmt, ...)
#define CORE_PRINTF(fmt, ...)

#ifdef __riscv
    #define ASSERT(x) if (!(x)) lotus::simFail();
#else
    #define ASSERT(x) assert(x);
#endif

///////////////////////////////////////////////// HELPERS

// MUST DEFINE NUM_CORES

#define NETWORK_LATENCY 250

constexpr uint32_t NUM_CORES_PER_NODE = 4;

constexpr uint32_t CORES_PER_NODE = NUM_CORES_PER_NODE;
constexpr uint32_t NUM_NODES =
    (NUM_CORES + CORES_PER_NODE - 1) / CORES_PER_NODE;  // ceil
static_assert(NUM_NODES >= 1, "There must be at least one node.");
static_assert((NUM_NODES & (NUM_NODES - 1)) == 0,
              "This wiring expects NUM_NODES to be a power of two.");

// Keep your original bit math
constexpr uint32_t NODE_BITS = std::countr_zero(NUM_NODES);
constexpr uint32_t ROW_BITS  = NODE_BITS / 2;           // floor(k/2)
constexpr uint32_t COL_BITS  = NODE_BITS - ROW_BITS;    // ceil(k/2)

constexpr uint32_t NUM_ROWS = 1u << ROW_BITS;
constexpr uint32_t NUM_COLS = 1u << COL_BITS;

// Safe array sizes (no zero-length arrays for global/static arrays)
constexpr uint32_t SAFE_ROWS   = (NUM_ROWS == 0) ? 1u : NUM_ROWS;
constexpr uint32_t SAFE_COLS   = (NUM_COLS == 0) ? 1u : NUM_COLS;
constexpr uint32_t H_GAPS      = (NUM_COLS > 0) ? (NUM_COLS - 1) : 0u; // real gaps
constexpr uint32_t V_GAPS      = (NUM_ROWS > 0) ? (NUM_ROWS - 1) : 0u;
constexpr uint32_t SAFE_HGAPS  = (H_GAPS == 0) ? 1u : H_GAPS;          // for arrays only
constexpr uint32_t SAFE_VGAPS  = (V_GAPS == 0) ? 1u : V_GAPS;

__attribute__((used))
static uint32_t node_id(uint32_t x, uint32_t y) {
    return y * NUM_COLS + x;
}


template <uint8_t N>
class Counter {
private:
    uint8_t m_curr;
public:
    Counter(bool enabled): m_curr(enabled ? 0 : 255) {}

    Counter(): Counter(true) {}

    bool enabled() { return m_curr != 255; }

    bool update() {
        if (m_curr == 255) return false;

        m_curr += 1;
        return m_curr > N;
    }
    void disable() {
        m_curr = 255;
    }


    void enable() {
        m_curr = 0;
    }

    void reset() {
        m_curr = 0;
    }

};


///////////////////////////////////////////////// CORES TO NODE


struct Coord {
    uint8_t x;
    uint8_t y;
};

//enum : uint8_t { DIR_UP = 0, DIR_RIGHT = 1, DIR_DOWN = 2, DIR_LEFT = 3, DIR_RSP = 4 };
enum : uint8_t { DIR_RIGHT = 0, DIR_LEFT = 1, DIR_DOWN = 2, DIR_UP = 3, DIR_RSP = 4 };

// auto get_dir = [&self_coord](const Coord& dst) -> uint8_t {
//     if      (dst.x > self_coord.x) return DIR_RIGHT;
//     else if (dst.x < self_coord.x) return DIR_LEFT;
//     else if (dst.y < self_coord.y) return DIR_UP;
//     else if (dst.y > self_coord.y) return DIR_DOWN;
//     else                            return DIR_RSP; // reached destination
// };

static inline __attribute__((always_inline))
uint8_t get_dir(const Coord& self, const Coord& dst) {
    int32_t dx = (int32_t)dst.x - (int32_t)self.x;   // [-64,64]
    int32_t dy = (int32_t)dst.y - (int32_t)self.y;

    uint32_t anyx = (uint32_t)(dx != 0);
    uint32_t anyy = (uint32_t)(dy != 0);

    // Prefer X if present; otherwise Y.
    uint32_t usey = (uint32_t)(!anyx) & anyy;

    // sign bit: 1 for LEFT/UP (negative), 0 for RIGHT/DOWN (positive)
    uint32_t sign = (uint32_t)(dx < 0) | ((uint32_t)(dy < 0) & usey);

    // axis bit: 1 for Y, 0 for X
    uint32_t axis = usey;

    uint32_t moving = anyx | anyy;
    uint32_t code2 = (axis << 1) | sign;             // 0..3

    // Branchless choose: moving ? code2 : RSP
    uint32_t mask = 0u - moving;                     // 0xFFFFFFFF if moving else 0
    return (uint8_t)((code2 & mask) | (DIR_RSP & ~mask));
}

struct ReqToNode {
    Coord dst_node;
    uint8_t src_core;
};

struct RspFromNode {
    uint8_t dst_core;
};

struct MeshReq {
    ReqToNode req;
    Coord     src_node;
};

struct MeshRsp {
    Coord     dst_node;
    uint8_t   dst_core;
};

enum class PortState : uint8_t { IDLE, BLOCK};


using NodeReq_SendBuffer_t = array<optional<MeshReq>,5>;
using NodeReq_PortState_t  = array<PortState,5>;

TASK node_req(
    ARG(IN,    FULL,    Coord)                           self_coord,
    ARG(IN,    FULL,    optional<ReqToNode>)             core_req,
    ARG(IN,    PARTIAL_UNTRACKED, NodeReq_SendBuffer_t)  _sendBuffer,
    ARG(IN,    PARTIAL_UNTRACKED, NodeReq_PortState_t)   _portStates,
    ARG(IN,    FULL,    Counter<NETWORK_LATENCY>)                    memLatCounter_in,

    ARG(IN,    FULL,    optional<MeshReq>)          mesh_from_up,
    ARG(IN,    FULL,    optional<MeshReq>)          mesh_from_right,
    ARG(IN,    FULL,    optional<MeshReq>)          mesh_from_down,
    ARG(IN,    FULL,    optional<MeshReq>)          mesh_from_left,

    ARG(IN,    FULL,    bool)                       mesh_to_up_ack,
    ARG(IN,    FULL,    bool)                       mesh_to_right_ack,
    ARG(IN,    FULL,    bool)                       mesh_to_down_ack,
    ARG(IN,    FULL,    bool)                       mesh_to_left_ack,

    ARG(IN,    FULL,    bool)                       mesh_rsp_ack,

    ARG(IN,    FULL,    uint8_t)                    version_number_in,

    ARG(OUT,   FULL,    uint8_t)                    version_number,

    ARG(OUT, PARTIAL_UNTRACKED, NodeReq_SendBuffer_t)  sendBuffer,
    ARG(OUT, PARTIAL_UNTRACKED, NodeReq_PortState_t)   portStates,
    ARG(OUT, FULL,    Counter<NETWORK_LATENCY>)                    memLatCounter,

    ARG(OUT,   FULL,    optional<MeshReq>)          mesh_to_up,
    ARG(OUT,   FULL,    optional<MeshReq>)          mesh_to_right,
    ARG(OUT,   FULL,    optional<MeshReq>)          mesh_to_down,
    ARG(OUT,   FULL,    optional<MeshReq>)          mesh_to_left,

    ARG(OUT,   FULL,    bool)                       mesh_from_up_ack,
    ARG(OUT,   FULL,    bool)                       mesh_from_right_ack,
    ARG(OUT,   FULL,    bool)                       mesh_from_down_ack,
    ARG(OUT,   FULL,    bool)                       mesh_from_left_ack,

    ARG(OUT,   FULL,    optional<RspFromNode>)      core_ack,

    ARG(OUT,   FULL,    optional<MeshRsp>)          mesh_rsp
) {
    core_ack            = std::nullopt;

    mesh_to_up          = std::nullopt;
    mesh_to_right       = std::nullopt;
    mesh_to_down        = std::nullopt;
    mesh_to_left        = std::nullopt;

    mesh_from_up_ack    = false;
    mesh_from_right_ack = false;
    mesh_from_down_ack  = false;
    mesh_from_left_ack  = false;

    memLatCounter = memLatCounter_in;

    auto successful_send = [&sendBuffer](uint8_t i, bool ack) {
        if (ack) {
            sendBuffer[i].reset();
        }
    };
    successful_send(DIR_UP,    mesh_to_up_ack);
    successful_send(DIR_RIGHT, mesh_to_right_ack);
    successful_send(DIR_DOWN,  mesh_to_down_ack);
    successful_send(DIR_LEFT,  mesh_to_left_ack);
    successful_send(DIR_RSP,   mesh_rsp_ack);
    if (mesh_rsp_ack) {
        memLatCounter.disable();
    }

    version_number = version_number_in + (mesh_to_up_ack || mesh_to_right_ack || mesh_to_down_ack || mesh_to_left_ack || mesh_rsp_ack);

    // auto get_dir = [&self_coord](const Coord& dst) -> uint8_t {
    //     if      (dst.x > self_coord.x) return DIR_RIGHT;
    //     else if (dst.x < self_coord.x) return DIR_LEFT;
    //     else if (dst.y < self_coord.y) return DIR_UP;
    //     else if (dst.y > self_coord.y) return DIR_DOWN;
    //     else                            return DIR_RSP; // reached destination
    // };

    auto put_in_send_buffer = [&sendBuffer, &version_number, &memLatCounter](uint8_t dir, const MeshReq& m) {
        version_number += 1;
        sendBuffer[dir] = m;
        if (dir == DIR_RSP) {
            ASSERT(!memLatCounter.enabled());
            memLatCounter.enable();
        }
    };

    auto try_accept_req = [&sendBuffer, &self_coord, &put_in_send_buffer]
        (const optional<MeshReq>& in, bool& ack) {
        ack = false;
        if (in.has_value()) {
            const uint8_t dir = get_dir(self_coord, in->req.dst_node);
            if (!sendBuffer[dir].has_value()) {
                put_in_send_buffer(dir, *in);
                ack = true;
            }
        }
    };


    // uint8_t prio_offset = (self_coord.x ^ (self_coord.y << 1)) & 3;
    // const auto try_accept_in_order = [&](uint8_t i) {
    //     switch ((i + prio_offset) & 3) {
    //         case 0: try_accept_req(mesh_from_up,    mesh_from_up_ack);    break;
    //         case 1: try_accept_req(mesh_from_right, mesh_from_right_ack); break;
    //         case 2: try_accept_req(mesh_from_down,  mesh_from_down_ack);  break;
    //         case 3: try_accept_req(mesh_from_left,  mesh_from_left_ack);  break;
    //     }
    // };
    // try_accept_in_order(0);
    // try_accept_in_order(1);
    // try_accept_in_order(2);
    // try_accept_in_order(3);
    // if (core_req.has_value()) {
    //     uint8_t dir = get_dir(self_coord, core_req->dst_node);
    //     if (!sendBuffer[dir].has_value()) {
    //         put_in_send_buffer(dir, MeshReq{ .req = *core_req, .src_node = self_coord });
    //         core_ack = RspFromNode{.dst_core = core_req->src_core};
    //     }
    // }

    // self_coord.x and self_coord.y
    try_accept_req(mesh_from_up,    mesh_from_up_ack);
    try_accept_req(mesh_from_right, mesh_from_right_ack);
    try_accept_req(mesh_from_down,  mesh_from_down_ack);
    try_accept_req(mesh_from_left,  mesh_from_left_ack);
    if (core_req.has_value()) {
        uint8_t dir = get_dir(self_coord, core_req->dst_node);
        if (!sendBuffer[dir].has_value()) {
            put_in_send_buffer(dir, MeshReq{ .req = *core_req, .src_node = self_coord });
            core_ack = RspFromNode{.dst_core = core_req->src_core};
        }
    }

    array<bool,5> maintainState{};
    maintainState.fill(false);

    auto try_send_req = [&sendBuffer, &portStates, &maintainState, &version_number](uint8_t i, optional<MeshReq>& out) {
        if (portStates[i] == PortState::IDLE && sendBuffer[i].has_value()) {
            version_number += 1;
            out = sendBuffer[i];
            portStates[i] = PortState::BLOCK;
            maintainState[i] = true;
        }
    };

    try_send_req(DIR_UP,    mesh_to_up);
    try_send_req(DIR_RIGHT, mesh_to_right);
    try_send_req(DIR_DOWN,  mesh_to_down);
    try_send_req(DIR_LEFT,  mesh_to_left);

    if (portStates[DIR_RSP] == PortState::IDLE && sendBuffer[DIR_RSP].has_value() && memLatCounter.update()) {
        const auto& m = *sendBuffer[DIR_RSP];
        mesh_rsp = MeshRsp{
            .dst_node = m.src_node,
            .dst_core = m.req.src_core
        };
        version_number += 1;
        portStates[DIR_RSP] = PortState::BLOCK;
        maintainState[DIR_RSP] = true;
    } else {
        mesh_rsp = std::nullopt;
    }

    for (uint8_t i = 0; i < 5; ++i) {
        if (!maintainState[i] && portStates[i] == PortState::BLOCK) {
            version_number += 1;
            portStates[i] = PortState::IDLE;
        }
    }
}

enum : uint8_t {
    RDIR_UP   = 0,
    RDIR_RIGHT= 1,
    RDIR_DOWN = 2,
    RDIR_LEFT = 3,
    RDIR_CORE = 4
};

using NodeRsp_SendBuffer_t = array<optional<MeshRsp>,5>;
using NodeRsp_PortState_t  = array<PortState,5>;

TASK node_rsp(
    ARG(IN,    FULL,    Coord)                              self_coord,
    ARG(IN,    PARTIAL_UNTRACKED, NodeRsp_SendBuffer_t)     _sendBuffer,
    ARG(IN,    PARTIAL_UNTRACKED, NodeRsp_PortState_t)      _portStates,

    ARG(IN,    FULL,    optional<MeshRsp>)                  mesh_rsp,
    ARG(OUT,   FULL,    bool)                               mesh_rsp_ack,

    ARG(IN,    FULL,    optional<MeshRsp>)                  rmesh_from_up,
    ARG(IN,    FULL,    optional<MeshRsp>)                  rmesh_from_right,
    ARG(IN,    FULL,    optional<MeshRsp>)                  rmesh_from_down,
    ARG(IN,    FULL,    optional<MeshRsp>)                  rmesh_from_left,

    ARG(IN,    FULL,    bool)                               rmesh_to_up_ack,
    ARG(IN,    FULL,    bool)                               rmesh_to_right_ack,
    ARG(IN,    FULL,    bool)                               rmesh_to_down_ack,
    ARG(IN,    FULL,    bool)                               rmesh_to_left_ack,

    ARG(IN   , FULL,    uint8_t)                            version_number_in,
    ARG(OUT  , FULL,    uint8_t)                            version_number,

    ARG(OUT,   PARTIAL_UNTRACKED, NodeRsp_SendBuffer_t)     sendBuffer,
    ARG(OUT,   PARTIAL_UNTRACKED, NodeRsp_PortState_t)      portStates,

    ARG(OUT,   FULL,    optional<MeshRsp>)                  rmesh_to_up,
    ARG(OUT,   FULL,    optional<MeshRsp>)                  rmesh_to_right,
    ARG(OUT,   FULL,    optional<MeshRsp>)                  rmesh_to_down,
    ARG(OUT,   FULL,    optional<MeshRsp>)                  rmesh_to_left,

    ARG(OUT,   FULL,    bool)                               rmesh_from_up_ack,
    ARG(OUT,   FULL,    bool)                               rmesh_from_right_ack,
    ARG(OUT,   FULL,    bool)                               rmesh_from_down_ack,
    ARG(OUT,   FULL,    bool)                               rmesh_from_left_ack,

    ARG(OUT,   FULL,    optional<RspFromNode>)              core_rsp
) {
    mesh_rsp_ack          = false;

    rmesh_to_up           = std::nullopt;
    rmesh_to_right        = std::nullopt;
    rmesh_to_down         = std::nullopt;
    rmesh_to_left         = std::nullopt;

    rmesh_from_up_ack     = false;
    rmesh_from_right_ack  = false;
    rmesh_from_down_ack   = false;
    rmesh_from_left_ack   = false;

    core_rsp              = std::nullopt;

    auto successful_send = [&sendBuffer](uint8_t i, bool ack) {
        if (ack) {
            sendBuffer[i].reset();
        }
    };
    successful_send(RDIR_UP,    rmesh_to_up_ack);
    successful_send(RDIR_RIGHT, rmesh_to_right_ack);
    successful_send(RDIR_DOWN,  rmesh_to_down_ack);
    successful_send(RDIR_LEFT,  rmesh_to_left_ack);

    version_number = version_number_in + (rmesh_to_up_ack || rmesh_to_right_ack || rmesh_to_down_ack || rmesh_to_left_ack);

    // auto get_dir = [&self_coord](const Coord& dst) -> uint8_t {
    //     if      (dst.x > self_coord.x) return RDIR_RIGHT;
    //     else if (dst.x < self_coord.x) return RDIR_LEFT;
    //     else if (dst.y < self_coord.y) return RDIR_UP;
    //     else if (dst.y > self_coord.y) return RDIR_DOWN;
    //     else                           return RDIR_CORE;
    // };

    auto try_accept_rsp = [&sendBuffer, &self_coord, &version_number](const optional<MeshRsp>& in, bool& ack) {
        ack = false;
        if (in.has_value()) {
            const uint8_t dir = get_dir(self_coord, in->dst_node);
            if (!sendBuffer[dir].has_value()) {
                version_number += 1;
                sendBuffer[dir] = *in;
                ack = true;
            }
        }
    };

    try_accept_rsp(rmesh_from_up,    rmesh_from_up_ack);
    try_accept_rsp(rmesh_from_right, rmesh_from_right_ack);
    try_accept_rsp(rmesh_from_down,  rmesh_from_down_ack);
    try_accept_rsp(rmesh_from_left,  rmesh_from_left_ack);

    try_accept_rsp(mesh_rsp, mesh_rsp_ack);

    array<bool, 5> maintainState{};
    maintainState.fill(false);

    // Drive neighbor ports when idle and slot has a message
    auto try_send_rsp = [&sendBuffer, &portStates, &maintainState, &version_number](uint8_t i, optional<MeshRsp>& out) {
        if (portStates[i] == PortState::IDLE && sendBuffer[i].has_value()) {
            version_number += 1;
            out = sendBuffer[i];
            portStates[i] = PortState::BLOCK;
            maintainState[i] = true;
        }
    };

    try_send_rsp(RDIR_UP,    rmesh_to_up);
    try_send_rsp(RDIR_RIGHT, rmesh_to_right);
    try_send_rsp(RDIR_DOWN,  rmesh_to_down);
    try_send_rsp(RDIR_LEFT,  rmesh_to_left);

    if (portStates[RDIR_CORE] == PortState::IDLE && sendBuffer[RDIR_CORE].has_value()) {
        const auto& m = *sendBuffer[RDIR_CORE];
        core_rsp = RspFromNode{
            .dst_core = m.dst_core
        };
        version_number += 1;
        // NOTE(farese): Core always accepts
        sendBuffer[RDIR_CORE].reset();
        // portStates[RDIR_CORE] = PortState::BLOCK;
        // maintainState[RDIR_CORE] = true;
    } else {
    }

    for (uint8_t i = 0; i < 5; ++i) {
        if (!maintainState[i] && portStates[i] == PortState::BLOCK) {
            version_number += 1;
            portStates[i] = PortState::IDLE;
        }
    }
}

using NodeSwitch_ReqBuffer_t = array<optional<ReqToNode>, 4>;

TASK node_switch(
    ARG(IN,  FULL, optional<Coord>) r0, // mem_req of core
    ARG(IN,  FULL, optional<Coord>) r1, // mem_req of core
    ARG(IN,  FULL, optional<Coord>) r2, // mem_req of core
    ARG(IN,  FULL, optional<Coord>) r3, // mem_req of core
    ARG(IN , FULL, NodeSwitch_ReqBuffer_t) reqBuffer_in,
    ARG(IN , FULL, uint8_t               ) prio_in,
    ARG(IN , FULL, PortState             ) portState_in,
    ARG(OUT, FULL, NodeSwitch_ReqBuffer_t) reqBuffer,
    ARG(OUT, FULL, uint8_t               ) prio,
    ARG(OUT, FULL, PortState             ) portState,
    ARG(OUT, FULL, optional<ReqToNode>) nodeReq, // to node req
    ARG(IN,  FULL, optional<RspFromNode>) nodeAck, // from node req
    ARG(IN,  FULL, optional<RspFromNode>) nodeRsp, // from node rsp
    ARG(OUT, FULL, bool) r0_done, // mem_rsp of core
    ARG(OUT, FULL, bool) r1_done, // mem_rsp of core
    ARG(OUT, FULL, bool) r2_done, // mem_rsp of core
    ARG(OUT, FULL, bool) r3_done // mem_rsp of core
) {
    nodeReq = std::nullopt;

    r0_done = false;
    r1_done = false;
    r2_done = false;
    r3_done = false;

    reqBuffer = reqBuffer_in;
    prio      = prio_in;
    portState = portState_in;

    // Deliver response to correct core
    if (nodeRsp.has_value()) {
        uint8_t core = nodeRsp->dst_core;
        if (core < 4) {
            if (core == 0) r0_done = true;
            if (core == 1) r1_done = true;
            if (core == 2) r2_done = true;
            if (core == 3) r3_done = true;
        }
    }

    // Ack clears request buffer
    if (nodeAck.has_value()) {
        uint8_t core = nodeAck->dst_core;
        ASSERT(core < 4);
        ASSERT(reqBuffer[core].has_value());
        reqBuffer[core].reset();
    }

    // Accept new requests from cores
    if (r0.has_value()) {
        ASSERT(!reqBuffer[0].has_value());
        reqBuffer[0] = ReqToNode{.dst_node = *r0, .src_core = 0};
    }
    if (r1.has_value()) {
        ASSERT(!reqBuffer[1].has_value());
        reqBuffer[1] = ReqToNode{.dst_node = *r1, .src_core = 1};
    }
    if (r2.has_value()) {
        ASSERT(!reqBuffer[2].has_value());
        reqBuffer[2] = ReqToNode{.dst_node = *r2, .src_core = 2};
    }
    if (r3.has_value()) {
        ASSERT(!reqBuffer[3].has_value());
        reqBuffer[3] = ReqToNode{.dst_node = *r3, .src_core = 3};
    }

    // Simple round-robin arbitration
    if (portState == PortState::IDLE) {
        for (uint32_t i = 0; i < 4; i++) {
            uint32_t j = (prio + i);
            if (j >= 4) j -= 4;
            if (reqBuffer[j].has_value()) {
                nodeReq = reqBuffer[j];
                prio = (j + 1); // next starting core
                if (prio >= 4) prio = prio - 4;
                portState = PortState::BLOCK;
                break;
            }
        }
    } else {
        ASSERT(portState == PortState::BLOCK);
        portState = PortState::IDLE;
    }
}



//////////////////////////////////////////////// CACHE

struct DCacheReq {
    Word wordAddr;
};

struct DCacheRsp {

};

class CacheImpl {
  private:
    constexpr static uint32_t N_LINES = 128;           // 2 << 6
    constexpr static uint32_t N_WORDS_PER_LINE = 4;    // words per line

    using LineIdx_t = uint8_t;   // 7 bits needed for 128 lines
    using Tag_t     = uint16_t;  // plenty for remaining address bits

    std::array<Tag_t, N_LINES> m_tags{};
    std::array<bool,  N_LINES> m_valids{};

  public:
    CacheImpl() { m_valids.fill(false); }

    inline std::tuple<Tag_t, LineIdx_t> process_wordAddr(uint32_t wordAddr) {
        // wordAddr = [ tag | lineIdx | wordOffset ]
        constexpr uint32_t WORD_OFFSET_BITS = 2; // log2(4)
        constexpr uint32_t LINE_INDEX_BITS  = 7; // log2(128)
        constexpr uint32_t LINE_INDEX_MASK  = (1u << LINE_INDEX_BITS) - 1;

        LineIdx_t lineIdx = (wordAddr >> WORD_OFFSET_BITS) & LINE_INDEX_MASK;
        Tag_t tag = wordAddr >> (WORD_OFFSET_BITS + LINE_INDEX_BITS);
        return {tag, lineIdx};
    }

    inline uint32_t block_addr(uint32_t wordAddr) {
        constexpr uint32_t WORD_OFFSET_BITS = 2; // log2(4)
        return wordAddr >> WORD_OFFSET_BITS;
    }

    bool access(uint32_t wordAddr) {
        const auto [tag, lineIdx] = process_wordAddr(wordAddr);
        if (!m_valids[lineIdx]) return false;
        return m_tags[lineIdx] == tag;
    }

    void put(uint32_t wordAddr) {
        const auto [tag, lineIdx] = process_wordAddr(wordAddr);
        m_tags[lineIdx] = tag;
        m_valids[lineIdx] = true;
    }
};

enum class CacheState : uint8_t { IDLE, WAITING_FOR_MISS};


TASK dcache(ARG(IN, FULL, optional<DCacheReq>)        core_req,
            ARG(IN, FULL, bool)                       mem_rsp,
            ARG(IN, FULL, CacheState)                 cacheState_in,
            ARG(IN, PARTIAL_UNTRACKED, CacheImpl)     _cache,
            ARG(OUT, FULL, CacheState)                cacheState,
            ARG(OUT, FULL, optional<Coord>)           mem_req,
            ARG(OUT, FULL, optional<DCacheRsp>)       core_rsp,
            // NOTE: doesn't need version number because a change in cache doesn't require re-run
            ARG(OUT, PARTIAL_UNTRACKED, CacheImpl)    cache
            )
{

    core_rsp = std::nullopt;
    mem_req = std::nullopt;

    cacheState = cacheState_in;


    if (cacheState == CacheState::WAITING_FOR_MISS) {
        if (mem_rsp) {
            core_rsp = DCacheRsp{};
            cacheState = CacheState::IDLE;
        }
        return;
    } else {
        ASSERT(cacheState == CacheState::IDLE);
        // static size_t numReqs   = 0;
        // static size_t numMisses = 0;


        if (core_req.has_value()) {
            // numReqs++;
            if (cache.access(core_req->wordAddr)) {
                core_rsp = DCacheRsp{};
            } else {
                // MISS
                // numMisses++;
                cache.put(core_req->wordAddr);
                mem_req = Coord{};

                uint32_t blockAddr = cache.block_addr(core_req->wordAddr);
                mem_req->x = blockAddr & (NUM_COLS-1);
                mem_req->y = (blockAddr >> COL_BITS) & (NUM_ROWS-1);
                cacheState = CacheState::WAITING_FOR_MISS;
            }
            PRINTF("[dcache] numReqs: %lu -- numMisses: %lu\n", numReqs, numMisses);
        }

    }

}



////////////////////////////////////////////// CORE

// ---- Opaque-ish ops and branch kinds (internal) -----------------------------
enum class AluOp : uint8_t {
    ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU, ADDI, LUI, AUIPC, NOP
};
enum class BranchKind : uint8_t { NONE, BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL, JALR };

enum class MemOperation : uint8_t { NONE, READ, WRITE };

static inline const char* to_cstr(AluOp op) {
    switch (op) {
        case AluOp::ADD:   return "ADD";
        case AluOp::SUB:   return "SUB";
        case AluOp::AND:   return "AND";
        case AluOp::OR:    return "OR";
        case AluOp::XOR:   return "XOR";
        case AluOp::SLL:   return "SLL";
        case AluOp::SRL:   return "SRL";
        case AluOp::SRA:   return "SRA";
        case AluOp::SLT:   return "SLT";
        case AluOp::SLTU:  return "SLTU";
        case AluOp::ADDI:  return "ADDI";
        case AluOp::LUI:   return "LUI";
        case AluOp::AUIPC: return "AUIPC";
        case AluOp::NOP:   return "NOP";
    }
    return "?";
}

static inline const char* to_cstr(BranchKind b) {
    switch (b) {
        case BranchKind::NONE: return "NONE";
        case BranchKind::BEQ:  return "BEQ";
        case BranchKind::BNE:  return "BNE";
        case BranchKind::BLT:  return "BLT";
        case BranchKind::BGE:  return "BGE";
        case BranchKind::BLTU:  return "BLTU";
        case BranchKind::BGEU:  return "BGEU";
        case BranchKind::JAL:  return "JAL";
        case BranchKind::JALR: return "JALR";
    }
    return "?";
}

static inline const char* to_cstr(MemOperation m) {
    switch (m) {
        case MemOperation::NONE:  return "NONE";
        case MemOperation::READ:  return "READ";
        case MemOperation::WRITE: return "WRITE";
    }
    return "?";
}

// ---- optional printers ------------------------------------------------------

// For optionals whose T has a .print()
template <typename T>
inline void print_optional(const optional<T> op) {
    if (op) {
        op->print();
    } else {
        CORE_PRINTF("(none)");
    }
}

// For scalar optionals (e.g., uint8_t, Word)
template <typename T>
static inline void print_opt_scalar(const char* name, const optional<T>& v) {
    if (v) {
        // uint32_t cast to print as unsigned
        CORE_PRINTF("%s=%u", name, static_cast<unsigned>(*v));
    } else {
        CORE_PRINTF("%s=none", name);
    }
}

template <>
inline void print_opt_scalar<Word>(const char* name, const optional<Word>& v) {
    if (v) {
        CORE_PRINTF("%s=0x%08x", name, *v);
    } else {
        CORE_PRINTF("%s=none", name);
    }
}

// ---- structs ---------------------------------------------------------------

struct FetchToDecode {
    Word instr;
    Word pc;

    void print() const {
        CORE_PRINTF("FetchToDecode{instr=0x%08x, pc=0x%08x}", instr, pc);
    }
};

struct DecodeToExec {
    optional<uint8_t> rd  = std::nullopt;
    AluOp       op        = AluOp::NOP;
    BranchKind  br        = BranchKind::NONE; // BEQ/BNE/JAL/JALR detection
    MemOperation mem      = MemOperation::NONE;
    optional<Word> imm    = std::nullopt;
    Word          rs1_val = 0;
    Word          rs2_val = 0;
    Word          pc      = 0;

    void print() const {
        CORE_PRINTF("DecodeToExec{");
        print_opt_scalar("rd", rd);
        CORE_PRINTF(", op=%s, br=%s, mem=%s", to_cstr(op), to_cstr(br), to_cstr(mem));
        CORE_PRINTF(", ");
        print_opt_scalar<Word>("imm", imm);
        CORE_PRINTF(", rs1=0x%08x, rs2=0x%08x, pc=0x%08x", rs1_val, rs2_val, pc);
        CORE_PRINTF("}");
    }
};

struct ExecToMem {
    Word addr_or_alu     = 0;
    Word store_data      = 0;
    Word wb_data_nonload = 0;
    MemOperation mem     = MemOperation::NONE;
    optional<uint8_t> rd = std::nullopt;

    void print() const {
        CORE_PRINTF("ExecToMem{addr_or_alu=0x%08x, store_data=0x%08x, wb_data_nonload=0x%08x",
                    addr_or_alu, store_data, wb_data_nonload);
        CORE_PRINTF(", mem=%s, ", to_cstr(mem));
        print_opt_scalar("rd", rd);
        CORE_PRINTF("}");
    }
};

struct MemToWb {
    Word              wb_data = 0;
    optional<uint8_t> rd      = std::nullopt;

    void print() const {
        CORE_PRINTF("MemToWb{wb_data=0x%08x, ", wb_data);
        print_opt_scalar("rd", rd);
        CORE_PRINTF("}");
    }
};

constexpr int IMemSize = 1024;
constexpr int DMemSize = 2048;

// Memories
using RegFile = std::array<Word, 32>;
using IMem    = std::array<Word, IMemSize>;
using DMem    = std::array<Word, DMemSize>;

// Helpers
static inline Word sext32(Word x, int bits) {
    const uint32_t m = 1u << (bits - 1);
    return (x ^ m) - m;
}


// ===================== IF (Instruction Fetch) =====================
// Inputs:
// - pc_in .................. from IF.pc_out (self-feedback)
// - imem ................... memory object (not an edge)
// - stall_if ............... from ID.stall_request  (single source: ID)
// - redirect_pc ............ from EX.redirect_pc    (single source: EX)
//
// Outputs (consumers):
// - instr_out .............. → ID.instr_in
// - pc_out ................. → IF.pc_in (self-feedback), → ID.pc_for_id
// - valid_out .............. → ID.valid_in
TASK
fetch_stage(ARG(IN, FULL, Word)    pc_in,
            ARG(IN, PARTIAL, IMem) imem,
            ARG(IN, FULL, bool) stall_if,
            ARG(IN, FULL, optional<Word>) redirect_pc,
            ARG(IN, FULL, bool) stall_from_mem,
            ARG(OUT, FULL, Word) pc,
            ARG(OUT, FULL, optional<FetchToDecode>) fetch_to_decode
            )
{
    fetch_to_decode = std::nullopt;

    pc = pc_in;

    CORE_PRINTF("[fetch_stage] pc=0x%x, stall_if=%d, stall_from_mem=%d, ", pc, stall_if, stall_from_mem);
    print_opt_scalar<Word>("redirect_pc", redirect_pc);
    CORE_PRINTF("\n");

    if (stall_from_mem) {
        // NOTE(farese): We don't need save state here because
        // 1. We produce pc, so we can just not update it
        // 2. stall_if, redirect_pc are same-cycle edges, thus they will be sent again next cycle because these stages also stall
        // Hold PC and emit bubble.
        // pc = pc;
    } else if (redirect_pc.has_value()) {
        // Resolve to target and insert a bubble this cycle.
        pc = *redirect_pc;
    } else if (stall_if) {
        // Hold PC and emit bubble.
        // pc = pc;
    } else {
        // Normal fetch
        ASSERT(pc < imem.size() && "PC out of imem bounds (demo array)");
        Word instr_out = imem[pc>>2];
        PRINTF("fetch_stage: imem[%x] = %x\n", pc, instr_out);
        fetch_to_decode = FetchToDecode{.instr=instr_out, .pc=pc};
        pc        = pc + 4;
    }
}

class DataHazardManager {
    private:
        // dsm: One bit per register
        uint32_t scoreboard;

    public:
        DataHazardManager() {}

        void print() {
            printf("DataHazardManager [");
            for (uint32_t i = 0; i < 32; i++) {
                if ((scoreboard >> i) & 0x1) {
                    printf(" %u ", i);
                }
            }
            printf("]");
        }

        bool is_locked(uint8_t r) {
            // printf("DatahazardManger::is_locked(rd=%u) -- ", r); this->print(); printf("\n");
            return (scoreboard >> r) & 0x1;
        }

        void lock_reg(uint8_t r) {
            // printf("DatahazardManger::lock_reg(rd=%u) -- ", r); this->print(); printf("\n");
            //ASSERT(!is_locked(r));
            scoreboard |= (0x1 << r);
        }

        void release_reg(uint8_t r) {
            // printf("DatahazardManger::release_reg(rd=%u) -- ", r); this->print(); printf("\n");
            //ASSERT(is_locked(r));
            scoreboard ^= (0x1 << r);
        }
};

// ===================== ID (Decode / Reg Read) =====================
// Inputs:
// - instr_in ................ from IF.instr_out
// - pc_for_id .............. from IF.pc_out
// - valid_in ............... from IF.valid_out
// - regfile ................ memory object (not an edge)
//
// Outputs (consumers):
// - dec_out ................. → EX.dec_in
// - rs1_val ................. → EX.rs1_val
// - rs2_val ................. → EX.rs2_val
// - pc_to_ex ................ → EX.pc_ex
// - valid_out ............... → EX.valid_in
// - stall_request ........... → IF.stall_if  (assert when a branch/jump is detected)
// NOTE: single-source rule: stall_request is *the* source of IF.stall_if
TASK
decode_stage(ARG(IN, FULL, optional<FetchToDecode>) fetch_to_decode_in,
             ARG(IN, FULL, optional<FetchToDecode>) saved_fetch_to_decode_in,
             ARG(IN, FULL, DataHazardManager)       hazardManager_in,
             ARG(IN, FULL, optional<uint8_t>)          wb_finished,
             ARG(IN,  FULL, bool)    stall_from_mem,
             // NOTE: doesn't need version_number as wb_finished handles changes in regfile
             ARG(IN,  PARTIAL_UNTRACKED, RegFile) regfile,
             ARG(OUT, FULL, optional<FetchToDecode>) saved_fetch_to_decode,
             ARG(OUT, FULL, DataHazardManager)       hazardManager,
             ARG(OUT, FULL, optional<DecodeToExec>) decode_to_exec,
             ARG(OUT, FULL, bool)    stall_request)
{
    // Output defaults
    stall_request = false;
    decode_to_exec = std::nullopt;

    saved_fetch_to_decode = saved_fetch_to_decode_in;
    hazardManager         = hazardManager_in;

    if (wb_finished.has_value()) hazardManager.release_reg(*wb_finished);

    optional<FetchToDecode> fetch_to_decode = fetch_to_decode_in;
    if (saved_fetch_to_decode.has_value()) {
        fetch_to_decode = saved_fetch_to_decode;
    }
    saved_fetch_to_decode.reset();

    CORE_PRINTF("[decode_stage] stall_from_mem=%d, fetch_to_decode = ", stall_from_mem);
    print_optional(fetch_to_decode);
    CORE_PRINTF("\n");

    if (stall_from_mem) {
        saved_fetch_to_decode = fetch_to_decode;
    }
    if (!fetch_to_decode.has_value() || stall_from_mem) return;


    const uint32_t instr  = fetch_to_decode->instr;
    const uint32_t opcode = instr & 0x7f;
    const uint32_t rd     = (instr >> 7)  & 0x1f;
    const uint32_t funct3 = (instr >> 12) & 0x7;
    const uint32_t rs1    = (instr >> 15) & 0x1f;
    const uint32_t rs2    = (instr >> 20) & 0x1f;
    const uint32_t funct7 = (instr >> 25) & 0x7f;

    if (hazardManager.is_locked(rs1) || hazardManager.is_locked(rs2)) {
        saved_fetch_to_decode = fetch_to_decode;
        stall_request = true;
        return;
    }


    decode_to_exec.emplace();

    decode_to_exec->pc      = fetch_to_decode->pc;

    auto imm_i = [&]{ return (Word)sext32(instr >> 20, 12); };
    auto imm_s = [&]{
        uint32_t v = ((instr >> 7) & 0x1f) | (((instr >> 25) & 0x7f) << 5);
        return (Word)sext32(v, 12);
    };
    auto imm_b = [&]{
        uint32_t v = (((instr >> 8)  & 0x0f) << 1)  |   // imm[4:1]
                     (((instr >> 25) & 0x3f) << 5)  |   // imm[10:5]
                     (((instr >> 7)  & 0x01) << 11) |   // imm[11]
                     (((instr >> 31) & 0x01) << 12);    // imm[12]
        return (Word)sext32(v, 13);
    };
    auto imm_u = [&]{ return (Word)(instr & 0xfffff000u); };
    auto imm_j = [&]{
        uint32_t v = (((instr >> 21) & 0x3ff) << 1)  |  // imm[10:1]
                     (((instr >> 20) & 0x001) << 11) |  // imm[11]
                     (((instr >> 12) & 0x0ff) << 12) |  // imm[19:12]
                     (((instr >> 31) & 0x001) << 20);   // imm[20]
        return (Word)sext32(v, 21);
    };

    // Operand reads (harmless if unused later)
    decode_to_exec->rs1_val = regfile[rs1];
    decode_to_exec->rs2_val = regfile[rs2];

    // --- Decode subset: R/I-ALU, LW, SW, BEQ/BNE, LUI, AUIPC, JAL/JALR ---
    switch (opcode) {
        case 0x33: { // R-type
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            switch ((funct7 << 3) | funct3) {
                case (0x00<<3)|0x0: decode_to_exec->op = AluOp::ADD; break;
                case (0x20<<3)|0x0: decode_to_exec->op = AluOp::SUB; break;
                case (0x00<<3)|0x7: decode_to_exec->op = AluOp::AND; break;
                case (0x00<<3)|0x6: decode_to_exec->op = AluOp::OR;  break;
                case (0x00<<3)|0x4: decode_to_exec->op = AluOp::XOR; break;
                case (0x00<<3)|0x1: decode_to_exec->op = AluOp::SLL; break;
                case (0x00<<3)|0x5: decode_to_exec->op = AluOp::SRL; break;
                case (0x20<<3)|0x5: decode_to_exec->op = AluOp::SRA; break;
                case (0x00<<3)|0x2: decode_to_exec->op = AluOp::SLT; break;
                case (0x00<<3)|0x3: decode_to_exec->op = AluOp::SLTU;break;
                default:            decode_to_exec->op = AluOp::NOP; decode_to_exec->rd = std::nullopt; break;
            }
            break;
        }

        case 0x13: { // I-type ALU (ADDI/SLTI/SLTIU/SLLI/SRLI/SRAI/ANDI/ORI/XORI)
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->imm     = imm_i();
            switch (funct3) {
                case 0x0: decode_to_exec->op = AluOp::ADDI; break; // ADDI
                case 0x2: decode_to_exec->op = AluOp::SLT;  break; // SLTI
                case 0x3: decode_to_exec->op = AluOp::SLTU; break; // SLTIU
                case 0x4: decode_to_exec->op = AluOp::XOR;  break;
                case 0x6: decode_to_exec->op = AluOp::OR;   break;
                case 0x7: decode_to_exec->op = AluOp::AND;  break;
                case 0x1: // SLLI (funct7 must be 0x00)
                    if ((funct7 & 0x7f) == 0x00) decode_to_exec->op = AluOp::SLL;
                    else { decode_to_exec->op = AluOp::NOP; decode_to_exec->rd = std::nullopt; decode_to_exec->imm = std::nullopt; }
                    break;
                case 0x5: // SRLI/SRAI distinguished by bit 30
                    if ((funct7 & 0x20) == 0x20) decode_to_exec->op = AluOp::SRA; else decode_to_exec->op = AluOp::SRL;
                    break;
                default:
                    decode_to_exec->op = AluOp::NOP; decode_to_exec->rd = std::nullopt; decode_to_exec->imm = std::nullopt; break;
            }
            break;
        }

        case 0x03: { // Loads (treat as LW for now)
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->imm       = imm_i();
            decode_to_exec->mem       = MemOperation::READ;
            decode_to_exec->op        = AluOp::ADD; // addr = rs1 + imm
            break;
        }

        case 0x23: { // Stores (treat as SW for now)
            decode_to_exec->imm       = imm_s();
            decode_to_exec->mem       = MemOperation::WRITE;
            decode_to_exec->op        = AluOp::ADD; // addr = rs1 + imm
            break;
        }

        case 0x63: { // Branches
            // imm first (used regardless of kind)
            decode_to_exec->imm = imm_b();

            switch (funct3) {
                case 0x0: decode_to_exec->br = BranchKind::BEQ;  break;
                case 0x1: decode_to_exec->br = BranchKind::BNE;  break;
                case 0x4: decode_to_exec->br = BranchKind::BLT;  break;
                case 0x5: decode_to_exec->br = BranchKind::BGE;  break;
                case 0x6: decode_to_exec->br = BranchKind::BLTU; break;
                case 0x7: decode_to_exec->br = BranchKind::BGEU; break;
                default:  decode_to_exec->br = BranchKind::NONE; break; // (reserved/illegal)
            }
            break;
        }

        case 0x37: { // LUI
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->op    = AluOp::LUI;
            decode_to_exec->imm   = imm_u();
            break;
        }

        case 0x17: { // AUIPC
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->op    = AluOp::AUIPC;
            decode_to_exec->imm   = imm_u();
            break;
        }

        case 0x6f: { // JAL
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->br    = BranchKind::JAL;
            decode_to_exec->imm   = imm_j();
            break;
        }

        case 0x67: { // JALR
            if (rd != 0) {
                decode_to_exec->rd = rd;
            }
            decode_to_exec->br    = BranchKind::JALR;
            decode_to_exec->imm   = imm_i();   // rs1 + imm in EX
            break;
        }

        default:
            // keep defaults (NOP)
            break;
    }

    // Control hazard policy:
    // - Stall earlier stages when a control-flow instr is in the pipe,
    //   but DO NOT block ID->EX for the current instruction.
    stall_request = (decode_to_exec->br != BranchKind::NONE);  // freeze IF (and ID input)

    if (decode_to_exec->rd.has_value()) {
        hazardManager.lock_reg(decode_to_exec->rd.value());
    }

}


// ===================== EX (Execute / Branch Resolve) =====================
// Inputs:
// - dec_in .................. from ID.dec_out
// - rs1_val ................. from ID.rs1_val
// - rs2_val ................. from ID.rs2_val
// - pc_ex ................... from ID.pc_to_ex
// - valid_in ................ from ID.valid_out
//
// Outputs (consumers):
// - alu_result .............. → MEM.addr_or_alu
// - store_data .............. → MEM.store_data
// - mem_read ................ → MEM.mem_read
// - mem_write ............... → MEM.mem_write
// - rd_out .................. → MEM.rd_in
// - wb_en_out ............... → MEM.wb_en_in
// - wb_data_nonload ......... → MEM.pass_through_wb_data
// - valid_out ............... → MEM.valid_in
// - redirect_valid .......... → IF.redirect_valid
// - redirect_pc ............. → IF.redirect_pc
TASK
execute_stage(ARG(IN, FULL, optional<DecodeToExec>) decode_to_exec_in,
              // NOTE: Doesn't need a version number because stall_from_mem would trigger the task again
              ARG(IN, PARTIAL_UNTRACKED, optional<DecodeToExec>) saved_decode_to_exec_in,
              ARG(IN, FULL, bool) stall_from_mem,
              ARG(OUT, PARTIAL_UNTRACKED, optional<DecodeToExec>) saved_decode_to_exec,
              ARG(OUT, FULL, optional<ExecToMem>) exec_to_mem,
              ARG(OUT, FULL, optional<Word>) redirect_pc)
{
    redirect_pc = {};
    exec_to_mem = std::nullopt;
    saved_decode_to_exec = saved_decode_to_exec_in;

    optional<DecodeToExec> decode_to_exec = decode_to_exec_in;
    if (saved_decode_to_exec.has_value()) {
        decode_to_exec = saved_decode_to_exec;
    }
    saved_decode_to_exec.reset();

    CORE_PRINTF("[execute_stage] stall_from_mem=%d, decode_to_exec = ", stall_from_mem);
    print_optional(decode_to_exec);
    CORE_PRINTF("\n");

    if (!decode_to_exec.has_value() || stall_from_mem) {
        if (stall_from_mem) {
            saved_decode_to_exec = decode_to_exec;
        }
        return;
    }

    exec_to_mem.emplace();

    // Control + dest
    exec_to_mem->mem = decode_to_exec->mem;
    exec_to_mem->rd  = decode_to_exec->rd;

    Word rs1_val = decode_to_exec->rs1_val;
    Word rs2_val = decode_to_exec->rs2_val;

    // Operand selection
    const Word op2 = decode_to_exec->imm.has_value() ? decode_to_exec->imm.value() : rs2_val;

    // Shift amount: handle both reg and imm shift forms
    const uint32_t shamt5 = static_cast<uint32_t>(decode_to_exec->imm.has_value() ? (decode_to_exec->imm.value() & 31u) : (rs2_val & 31u));

    // ALU
    Word alu = 0;
    auto do_slt  = [](int32_t a, int32_t b) -> Word { return (a < b) ? 1u : 0u; };
    auto do_sltu = [](uint32_t a, uint32_t b) -> Word { return (a < b) ? 1u : 0u; };

    switch (decode_to_exec->op) {
        case AluOp::ADD:
        case AluOp::ADDI:  alu = rs1_val + op2; break;
        case AluOp::SUB:   alu = rs1_val - rs2_val; break;  // SUBI doesn't exist
        case AluOp::AND:   alu = rs1_val & op2; break;
        case AluOp::OR:    alu = rs1_val | op2; break;
        case AluOp::XOR:   alu = rs1_val ^ op2; break;
        case AluOp::SLL:   alu = rs1_val << shamt5; break;                  // SLL/SLLI
        case AluOp::SRL:   alu = rs1_val >> shamt5; break;                  // SRL/SRLI
        case AluOp::SRA:   alu = (Word)((int32_t)rs1_val >> shamt5); break; // SRA/SRAI
        case AluOp::SLT:   alu = do_slt ((int32_t)rs1_val, (int32_t)op2); break;  // uses op2
        case AluOp::SLTU:  alu = do_sltu(rs1_val, op2); break;                    // uses op2
        case AluOp::LUI:   alu = decode_to_exec->imm.value_or(0); break;
        case AluOp::AUIPC: alu = decode_to_exec->pc + decode_to_exec->imm.value_or(0); break;  // PC of instr + imm
        case AluOp::NOP:
        default:           alu = 0; break;
    }

    // Branch / jump resolution
    Word link_val = 0;

    auto branch_target = [&]() -> Word {
        // imm is already sign-extended in decode; value_or(0) is safe
        return decode_to_exec->pc + decode_to_exec->imm.value_or(0);
    };

    switch (decode_to_exec->br) {
        case BranchKind::BEQ:
            if (rs1_val == rs2_val) { redirect_pc = branch_target(); }
            break;

        case BranchKind::BNE:
            if (rs1_val != rs2_val) { redirect_pc = branch_target(); }
            break;

        // NEW: signed compares
        case BranchKind::BLT:
            if (static_cast<int32_t>(rs1_val) < static_cast<int32_t>(rs2_val)) {
                redirect_pc = branch_target();
            }
            break;

        case BranchKind::BGE:
            if (static_cast<int32_t>(rs1_val) >= static_cast<int32_t>(rs2_val)) {
                redirect_pc = branch_target();
            }
            break;

        // NEW: unsigned compares
        case BranchKind::BLTU:
            if (rs1_val < rs2_val) {  // both are Word (uint32_t)
                redirect_pc = branch_target();
            }
            break;

        case BranchKind::BGEU:
            if (rs1_val >= rs2_val) {
                redirect_pc = branch_target();
            }
            break;

        case BranchKind::JAL:
            redirect_pc = branch_target();               // target = PC + imm
            link_val    = decode_to_exec->pc + 4;        // rd gets link in WB
            break;

        case BranchKind::JALR:
            redirect_pc = (rs1_val + decode_to_exec->imm.value_or(0)) & ~1u; // LSB = 0
            link_val    = decode_to_exec->pc + 4;
            break;

        case BranchKind::NONE:
        default:
            break;
    }

    // MEM / WB data
    exec_to_mem->wb_data_nonload = (decode_to_exec->br == BranchKind::JAL || decode_to_exec->br == BranchKind::JALR) ? link_val : alu;
    exec_to_mem->addr_or_alu     = alu;         // used as address on loads/stores; ALU result otherwise
    exec_to_mem->store_data      = rs2_val;     // store value

}


// ===================== MEM (Data Memory) =====================
// Inputs:
// - valid_in ................ from EX.valid_out
// - addr_or_alu ............ from EX.alu_result
// - store_data .............. from EX.store_data
// - mem_read ................ from EX.mem_read
// - mem_write ............... from EX.mem_write
// - dmem .................... memory object (not an edge)
// - rd_in ................... from EX.rd_out
// - wb_en_in ................ from EX.wb_en_out
// - pass_through_wb_data .... from EX.wb_data_nonload
//
// Outputs (consumers):
// - wb_data ................. → WB.wb_data
// - rd_out .................. → WB.rd
// - wb_en_out ............... → WB.wb_en
// - valid_out ............... → WB.valid_in

enum class MemState : uint8_t { IDLE, WAITING_FOR_DCACHE };

TASK
mem_stage(ARG(IN, FULL, optional<ExecToMem>) exec_to_mem_in,
          ARG(IN, FULL, optional<ExecToMem>) saved_exec_to_mem_in,
          // NOTE: Doesn't need version_number as a change in dmem doesn't require re-running task
          ARG(IN, PARTIAL_UNTRACKED, DMem) _dmem,
          ARG(IN, FULL, MemState) mem_state_in,
          ARG(IN, FULL, optional<DCacheRsp>) dcache_rsp,

          ARG(OUT, FULL, optional<ExecToMem>) saved_exec_to_mem,
          // NOTE: Doesn't need version_number as a change in dmem doesn't require re-running task
          ARG(OUT, PARTIAL_UNTRACKED, DMem) dmem,
          ARG(OUT, FULL, MemState) mem_state,

          ARG(OUT, FULL, optional<DCacheReq>) dcache_req,
          ARG(OUT, FULL, optional<MemToWb>) mem_to_wb,
          ARG(OUT, FULL, bool) stall_from_mem
          )
{

    mem_to_wb      = std::nullopt;
    stall_from_mem = false;
    dcache_req     = std::nullopt;

    mem_state = mem_state_in;
    saved_exec_to_mem = saved_exec_to_mem_in;

    optional<ExecToMem> exec_to_mem = exec_to_mem_in;

    if (saved_exec_to_mem.has_value()) {
        exec_to_mem = saved_exec_to_mem;
    }
    saved_exec_to_mem.reset();

    CORE_PRINTF("[mem_stage] exec_to_mem = ");
    print_optional(exec_to_mem);
    CORE_PRINTF("\n");

    if (!exec_to_mem.has_value()) {
        ASSERT(mem_state == MemState::IDLE);
        return;
    }

    if (mem_state == MemState::WAITING_FOR_DCACHE) {
        if (dcache_rsp.has_value()) {
            mem_state = MemState::IDLE;
            // continues to actual task
        } else {
            stall_from_mem = true;
            saved_exec_to_mem = exec_to_mem;
            return;
        }
    }


    if (exec_to_mem->mem != MemOperation::NONE && !dcache_rsp.has_value()) {
        dcache_req = DCacheReq{.wordAddr= exec_to_mem->addr_or_alu >> 2};
        mem_state = MemState::WAITING_FOR_DCACHE;
        stall_from_mem = true;
        saved_exec_to_mem = exec_to_mem;
        return;
    }

    mem_to_wb.emplace();

    mem_to_wb->rd = exec_to_mem->rd;

    mem_to_wb->wb_data = exec_to_mem->wb_data_nonload;

    if (exec_to_mem->mem == MemOperation::READ) {
        Word addr = exec_to_mem->addr_or_alu >> 2; /*Divide by 4*/
        ASSERT(addr < dmem.size() && "DMEM read OOB (demo array)");
        mem_to_wb->wb_data = dmem[addr]; // LW
    }
    if (exec_to_mem->mem == MemOperation::WRITE) {
        Word addr = exec_to_mem->addr_or_alu >> 2; /*Divide by 4*/
        ASSERT(addr < dmem.size() && "DMEM write OOB (demo array)");
        dmem[addr] = exec_to_mem->store_data; // SW
    }
}


// ===================== WB (Write Back) =====================
// Inputs:
// - valid_in ................ from MEM.valid_out
// - wb_data ................. from MEM.wb_data
// - rd ...................... from MEM.rd_out
// - wb_en ................... from MEM.wb_en_out
// - regfile ................. memory object (not an edge)
//
TASK
wb_stage(ARG(IN, FULL, optional<MemToWb>) mem_to_wb,
         // NOTE: Doesn't need version_number because wb_finished would trigger decode
         ARG(OUT, PARTIAL_UNTRACKED, RegFile) regfile,
         ARG(OUT, FULL, optional<uint8_t>) wb_finished
         )
{

    wb_finished = std::nullopt;

    CORE_PRINTF("[wb_stage] mem_to_wb = ");
    print_optional(mem_to_wb);
    CORE_PRINTF("\n");

    if (!mem_to_wb.has_value()) return;

    if (!mem_to_wb->rd.has_value()) return;

    if (mem_to_wb->rd.value() != 0) {
        wb_finished = mem_to_wb->rd.value();
        regfile[mem_to_wb->rd.value()] = mem_to_wb->wb_data;
    }
}
