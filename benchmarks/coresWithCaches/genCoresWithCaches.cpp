/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


#include <stdint.h>
#include <tuple>
#include <vector>
#include <bit>
#include <type_traits>
#include <assert.h>

#include <iostream>
#include <string_view>
#include <array>
#include <cstddef>
#include <cstring>

#include "taskflow.h"

#include "coresWithCaches.h"


using namespace taskflow;

#include <array>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <iomanip>
#include <algorithm>

namespace detail {
    inline uint8_t hexByte(const char* p) {
        auto hex = [](char c)->int {
            if ('0' <= c && c <= '9') return c - '0';
            if ('a' <= c && c <= 'f') return 10 + (c - 'a');
            if ('A' <= c && c <= 'F') return 10 + (c - 'A');
            return -1;
        };
        int hi = hex(p[0]), lo = hex(p[1]);
        if (hi < 0 || lo < 0) throw std::runtime_error("Invalid hex digit");
        return static_cast<uint8_t>((hi << 4) | lo);
    }
}

/// Load an Intel HEX file into a little-endian array of 32-bit words.
/// - Data (type 00) records are written byte-wise at absolute addresses
///   (taking into account type 02/04 base), packed into 32-bit words as
///   little-endian: byte at addr k goes to (addr/4) word, byte lane (addr%4).
/// - Throws on malformed lines, checksum mismatch, or out-of-bounds writes.
/// - Uninitialized bytes remain 0.
template <int Size>
std::array<uint32_t, Size> load_hex(std::string name) {
    static_assert(Size > 0, "Size must be positive");

    std::array<uint32_t, Size> mem{};
    // zero-initialized already due to {}.

    std::ifstream in(name);
    if (!in) {
        throw std::runtime_error("Failed to open HEX file: " + name);
    }

    uint32_t base = 0; // upper address base (from type 02/04)
    bool saw_eof = false;

    std::string line;
    for (size_t lineno = 1; std::getline(in, line); ++lineno) {
        // Trim whitespace
        line.erase(std::remove_if(line.begin(), line.end(), [](unsigned char c){ return c=='\r' || c=='\n' || c==' ' || c=='\t'; }), line.end());
        if (line.empty()) continue;

        if (line[0] != ':') {
            throw std::runtime_error("Line " + std::to_string(lineno) + ": missing ':'");
        }
        const char* p = line.c_str() + 1;
        const size_t n = line.size();

        auto need = [&](size_t chars){
            if (1 + chars > n) throw std::runtime_error("Line " + std::to_string(lineno) + ": truncated");
        };

        need(2);  uint8_t byteCount = detail::hexByte(p); p += 2;
        need(4);  uint16_t addrHiLo = (static_cast<uint16_t>(detail::hexByte(p)) << 8) | detail::hexByte(p+2); p += 4;
        need(2);  uint8_t recType = detail::hexByte(p); p += 2;

        // Read data bytes
        std::vector<uint8_t> data;
        data.reserve(byteCount);
        need(static_cast<size_t>(byteCount) * 2 + 2); // +2 for checksum at end
        for (int i = 0; i < byteCount; ++i) {
            data.push_back(detail::hexByte(p));
            p += 2;
        }
        // Checksum
        uint8_t checksum = detail::hexByte(p); p += 2;

        // Verify checksum: sum of (count, addr_hi, addr_lo, type, data...) + checksum == 0x00 mod 256
        uint32_t sum = byteCount + (addrHiLo >> 8) + (addrHiLo & 0xFF) + recType;
        for (uint8_t b : data) sum += b;
        sum = (sum + checksum) & 0xFF;
        if (sum != 0) {
            throw std::runtime_error("Line " + std::to_string(lineno) + ": checksum mismatch");
        }

        switch (recType) {
            case 0x00: { // data
                uint32_t addr = (base + static_cast<uint32_t>(addrHiLo));
                for (size_t i = 0; i < data.size(); ++i) {
                    uint32_t a = addr + static_cast<uint32_t>(i);
                    uint32_t wordIndex = a >> 2;      // a / 4
                    uint32_t byteLane  = a & 0x3;     // a % 4
                    if (wordIndex >= static_cast<uint32_t>(Size)) {
                        throw std::runtime_error("Line " + std::to_string(lineno) + ": write address out of range (0x" +
                                                  [&](){ std::ostringstream os; os<<std::hex<<std::uppercase<<a; return os.str(); }() + ")");
                    }
                    uint32_t v = mem[wordIndex];
                    // little-endian pack: lane 0 is LSB
                    v &= ~(0xFFu << (byteLane * 8));
                    v |= (static_cast<uint32_t>(data[i]) << (byteLane * 8));
                    mem[wordIndex] = v;
                }
                break;
            }
            case 0x01: { // EOF
                saw_eof = true;
                // Per spec, should be last; we can stop parsing further lines.
                // But keep reading to catch trailing junk if you prefer strictness.
                break;
            }
            case 0x02: { // Extended Segment Address (bits 4–19)
                if (byteCount != 2) throw std::runtime_error("Line " + std::to_string(lineno) + ": ESA length must be 2");
                uint16_t seg = (static_cast<uint16_t>(data[0]) << 8) | data[1];
                base = static_cast<uint32_t>(seg) << 4; // segment * 16
                break;
            }
            case 0x04: { // Extended Linear Address (upper 16 bits of 32-bit address)
                if (byteCount != 2) throw std::runtime_error("Line " + std::to_string(lineno) + ": ELA length must be 2");
                uint16_t upper = (static_cast<uint16_t>(data[0]) << 8) | data[1];
                base = static_cast<uint32_t>(upper) << 16;
                break;
            }
            case 0x03: // Start Segment Address (ignored here)
            case 0x05: // Start Linear Address (ignored here)
                // Valid records; ignore for raw memory load.
                break;
            default:
                throw std::runtime_error("Line " + std::to_string(lineno) + ": unknown record type " + std::to_string(recType));
        }

        if (saw_eof) break;
    }

    if (!saw_eof) {
        throw std::runtime_error("HEX file missing EOF record (type 01)");
    }

    return mem;
}

void rv32i_5stage(Reg<optional<Coord>>& mem_req, Reg<bool>& mem_rsp) {
    // Memory Objects
    Reg<IMem> imem(load_hex<IMemSize>("quicksort.hex"));
    const uint32_t ARR_LEN = 1024;
    Reg<DMem> dmem([&ARR_LEN](){
        DMem dmem;
        assert(DMemSize >= (ARR_LEN*2)); // Space for stack
        for (uint32_t i = 0; i < ARR_LEN; i++) {
            dmem[i] = ARR_LEN-i;
        }
        return dmem;
    }());
    Reg<RegFile> regfile([&ARR_LEN](){
        RegFile regfile;
        regfile[2 /*sp*/] = DMemSize-4;
        return regfile;
    }());

    Reg<optional<FetchToDecode>> if_id_reg(std::nullopt);

    Reg<optional<DecodeToExec>> id_ex_reg(std::nullopt);

    Reg<optional<ExecToMem>>    ex_mem_reg(std::nullopt);

    Reg<optional<MemToWb>>      mem_wb_reg(std::nullopt);

    // ---------------- Single-cycle control wires --------
    Wire<bool> stall_if;                // ID.stall_request → IF.stall_if
    Wire<optional<Word>> redirect_pc;   // EX.redirect_pc → IF.redirect_pc

    Wire<bool> stall_from_mem;

    //////
    Reg<optional<uint8_t>> wb_finished(std::nullopt);

    // ================== IF ==================
    {
        Reg<Word> pc(0);
        task(fetch_stage,
             pc,          // 
             imem,              // imem
             stall_if,          // from ID
             redirect_pc,       // from EX
             stall_from_mem,
             pc,          // self-feedback
             if_id_reg);      // to ID

    }

    // ================== ID ==================
    {
        Reg<optional<FetchToDecode>> saved_if_id(std::nullopt);
        Reg<DataHazardManager> hazardManager(DataHazardManager{});
        task(decode_stage,
             if_id_reg,
             saved_if_id,
             hazardManager,
             wb_finished,
             stall_from_mem,
             regfile,      // memory object
             saved_if_id,
             hazardManager,
             id_ex_reg,
             stall_if      // → IF.stall_if (same cycle)
             );
    }

    // ================== EX ==================
    {
        Reg<optional<DecodeToExec>> saved_id_ex(std::nullopt);
        task(execute_stage,
             id_ex_reg,
             saved_id_ex,
             stall_from_mem,
             saved_id_ex,
             ex_mem_reg,
             redirect_pc        // → IF.redirect_pc    (same cycle)
             );

    }

    // ================== MEM ==================

    {

        Reg<optional<DCacheReq>> dcache_req(std::nullopt);
        Reg<optional<DCacheRsp>> dcache_rsp(std::nullopt);

        {
            Reg<CacheState>          dcache_state(CacheState{});
            Reg<CacheImpl>           dcache_cache(CacheImpl{});

            task(dcache,
                 dcache_req,
                 mem_rsp,
                 dcache_state,
                 dcache_cache,
                 dcache_state,
                 mem_req,
                 dcache_rsp,
                 dcache_cache
                 );

        }

        {
            Reg<optional<ExecToMem>> saved_ex_mem(std::nullopt);
            Reg<MemState> mem_state(MemState::IDLE);
            task(mem_stage,
                ex_mem_reg,
                saved_ex_mem,
                dmem,              // memory object
                mem_state,
                dcache_rsp,
                saved_ex_mem,
                dmem,              // memory object
                mem_state,
                dcache_req,
                mem_wb_reg,
                stall_from_mem
                );
        }

    }

    // ================== WB ==================
    {
        task(wb_stage,
             mem_wb_reg,
             regfile,
             wb_finished);
    }
}
template <class T>
static std::vector<Reg<T>> make_reg_vec(size_t n, const T& init) {
    std::vector<Reg<T>> v;
    v.reserve(n);
    for (size_t i = 0; i < n; ++i) v.emplace_back(init); // construct with init
    return v;
}
static inline size_t idx2(size_t dim1, size_t i, size_t j) { return i * dim1 + j; }

// =========================================
// Mesh link storage (constructed with inits)
// =========================================
// Request plane (MeshReq)
struct ReqLinks {
    // horizontal gaps: per row, between columns
    std::vector<Reg<optional<MeshReq>>> to_east;    // [NUM_ROWS * H_GAPS]
    std::vector<Reg<bool>>              ack_from_east;
    std::vector<Reg<optional<MeshReq>>> to_west;    // [NUM_ROWS * H_GAPS]
    std::vector<Reg<bool>>              ack_from_west;

    // vertical gaps: per column, between rows
    std::vector<Reg<optional<MeshReq>>> to_south;   // [V_GAPS * NUM_COLS]
    std::vector<Reg<bool>>              ack_from_south;
    std::vector<Reg<optional<MeshReq>>> to_north;   // [V_GAPS * NUM_COLS]
    std::vector<Reg<bool>>              ack_from_north;

    ReqLinks()
      : to_east        (make_reg_vec<optional<MeshReq>>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), std::nullopt)),
        ack_from_east  (make_reg_vec<bool>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), false)),
        to_west        (make_reg_vec<optional<MeshReq>>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), std::nullopt)),
        ack_from_west  (make_reg_vec<bool>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), false)),
        to_south       (make_reg_vec<optional<MeshReq>>((V_GAPS ? V_GAPS : 1) * NUM_COLS, std::nullopt)),
        ack_from_south (make_reg_vec<bool>((V_GAPS ? V_GAPS : 1) * NUM_COLS, false)),
        to_north       (make_reg_vec<optional<MeshReq>>((V_GAPS ? V_GAPS : 1) * NUM_COLS, std::nullopt)),
        ack_from_north (make_reg_vec<bool>((V_GAPS ? V_GAPS : 1) * NUM_COLS, false)) {}
} req_links;

// Response plane (MeshRsp)
struct RspLinks {
    std::vector<Reg<optional<MeshRsp>>> to_east;
    std::vector<Reg<bool>>              ack_from_east;
    std::vector<Reg<optional<MeshRsp>>> to_west;
    std::vector<Reg<bool>>              ack_from_west;

    std::vector<Reg<optional<MeshRsp>>> to_south;
    std::vector<Reg<bool>>              ack_from_south;
    std::vector<Reg<optional<MeshRsp>>> to_north;
    std::vector<Reg<bool>>              ack_from_north;

    RspLinks()
      : to_east        (make_reg_vec<optional<MeshRsp>>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), std::nullopt)),
        ack_from_east  (make_reg_vec<bool>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), false)),
        to_west        (make_reg_vec<optional<MeshRsp>>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), std::nullopt)),
        ack_from_west  (make_reg_vec<bool>(NUM_ROWS * (H_GAPS ? H_GAPS : 1), false)),
        to_south       (make_reg_vec<optional<MeshRsp>>((V_GAPS ? V_GAPS : 1) * NUM_COLS, std::nullopt)),
        ack_from_south (make_reg_vec<bool>((V_GAPS ? V_GAPS : 1) * NUM_COLS, false)),
        to_north       (make_reg_vec<optional<MeshRsp>>((V_GAPS ? V_GAPS : 1) * NUM_COLS, std::nullopt)),
        ack_from_north (make_reg_vec<bool>((V_GAPS ? V_GAPS : 1) * NUM_COLS, false)) {}
} rsp_links;

static inline Reg<optional<MeshReq>>&  RE_to_east (uint32_t y, uint32_t cg) { return req_links.to_east [idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<bool>&               RA_from_east(uint32_t y, uint32_t cg) { return req_links.ack_from_east[idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<optional<MeshReq>>&  RE_to_west (uint32_t y, uint32_t cg) { return req_links.to_west [idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<bool>&               RA_from_west(uint32_t y, uint32_t cg) { return req_links.ack_from_west[idx2((H_GAPS?H_GAPS:1), y, cg)]; }

static inline Reg<optional<MeshReq>>&  RE_to_south(uint32_t rg, uint32_t x) { return req_links.to_south[idx2(NUM_COLS, rg, x)]; }
static inline Reg<bool>&               RA_from_south(uint32_t rg, uint32_t x) { return req_links.ack_from_south[idx2(NUM_COLS, rg, x)]; }
static inline Reg<optional<MeshReq>>&  RE_to_north(uint32_t rg, uint32_t x) { return req_links.to_north[idx2(NUM_COLS, rg, x)]; }
static inline Reg<bool>&               RA_from_north(uint32_t rg, uint32_t x) { return req_links.ack_from_north[idx2(NUM_COLS, rg, x)]; }

// Same for Rsp
static inline Reg<optional<MeshRsp>>&  RS_to_east (uint32_t y, uint32_t cg) { return rsp_links.to_east [idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<bool>&               RAe_from_east(uint32_t y, uint32_t cg) { return rsp_links.ack_from_east[idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<optional<MeshRsp>>&  RS_to_west (uint32_t y, uint32_t cg) { return rsp_links.to_west [idx2((H_GAPS?H_GAPS:1), y, cg)]; }
static inline Reg<bool>&               RAe_from_west(uint32_t y, uint32_t cg) { return rsp_links.ack_from_west[idx2((H_GAPS?H_GAPS:1), y, cg)]; }

static inline Reg<optional<MeshRsp>>&  RS_to_south(uint32_t rg, uint32_t x) { return rsp_links.to_south[idx2(NUM_COLS, rg, x)]; }
static inline Reg<bool>&               RAe_from_south(uint32_t rg, uint32_t x) { return rsp_links.ack_from_south[idx2(NUM_COLS, rg, x)]; }
static inline Reg<optional<MeshRsp>>&  RS_to_north(uint32_t rg, uint32_t x) { return rsp_links.to_north[idx2(NUM_COLS, rg, x)]; }
static inline Reg<bool>&               RAe_from_north(uint32_t rg, uint32_t x) { return rsp_links.ack_from_north[idx2(NUM_COLS, rg, x)]; }

// =========================================
// Per-node state (all Reg<T> constructed in ctor)
// =========================================
struct NodeLocal {
    // Identity (distinct req/rsp)
    Reg<Coord> self_coord_req;
    Reg<Coord> self_coord_rsp;

    // Core <-> switch
    std::array<Reg<optional<Coord>>, CORES_PER_NODE> core_mem_req;
    std::array<Reg<bool>,            CORES_PER_NODE> core_mem_rsp;

    // Switch internals
    Reg<array<optional<ReqToNode>, CORES_PER_NODE>> switch_req_buf;
    Reg<uint8_t>                                    switch_prio;
    Reg<PortState>                                  switch_port_state;

    // Switch <-> node
    Reg<optional<ReqToNode>>   nodeReq_from_switch; // switch -> node_req
    Reg<optional<RspFromNode>> nodeAck_to_switch;   // node_req -> switch
    Reg<optional<RspFromNode>> nodeRsp_to_switch;   // node_rsp -> switch

    // node_req internals
    Reg<array<optional<MeshReq>,5>>  req_send_buf;
    Reg<array<PortState,5>>          req_port_states;

    // node_rsp internals
    Reg<array<optional<MeshRsp>,5>>   rsp_send_buf;
    Reg<array<PortState,5>>          rsp_port_states;

    // Local req<->rsp
    Reg<optional<MeshRsp>> local_mesh_rsp;
    Reg<bool>              local_mesh_rsp_ack;

    // Per-node, per-use dummies (unique lifetime; never shared)
    // Index order: 0=up, 1=right, 2=down, 3=left
    std::array<Reg<optional<MeshReq>>,4> dummy_req_in   ;
    std::array<Reg<bool>             ,4> dummy_req_ack_to;
    std::array<Reg<optional<MeshReq>>,4> dummy_req_out  ;
    std::array<Reg<bool>             ,4> dummy_req_ack_from;

    std::array<Reg<optional<MeshRsp>>,4> dummy_rsp_in   ;
    std::array<Reg<bool>             ,4> dummy_rsp_ack_to;
    std::array<Reg<optional<MeshRsp>>,4> dummy_rsp_out  ;
    std::array<Reg<bool>             ,4> dummy_rsp_ack_from;

    NodeLocal(uint8_t x, uint8_t y)
    : self_coord_req(Coord{ x, y })
    , self_coord_rsp(Coord{ x, y })
    , core_mem_req   { Reg<optional<Coord>>(std::nullopt),
                       Reg<optional<Coord>>(std::nullopt),
                       Reg<optional<Coord>>(std::nullopt),
                       Reg<optional<Coord>>(std::nullopt) }
    , core_mem_rsp   { Reg<bool>(false), Reg<bool>(false), Reg<bool>(false), Reg<bool>(false) }
    , switch_req_buf (array<optional<ReqToNode>, CORES_PER_NODE>{})
    , switch_prio    (0)
    , switch_port_state(PortState{})
    , nodeReq_from_switch(std::nullopt)
    , nodeAck_to_switch (std::nullopt)
    , nodeRsp_to_switch (std::nullopt)
    , req_send_buf   (array<optional<MeshReq> , 5>{})
    , req_port_states(array<PortState,5>{})
    , rsp_send_buf   (array<optional<MeshRsp> , 5>{})
    , rsp_port_states(array<PortState,5>{})
    , local_mesh_rsp (std::nullopt)
    , local_mesh_rsp_ack(false)
    , dummy_req_in   { Reg<optional<MeshReq>>(std::nullopt), Reg<optional<MeshReq>>(std::nullopt),
                       Reg<optional<MeshReq>>(std::nullopt), Reg<optional<MeshReq>>(std::nullopt) }
    , dummy_req_ack_to { Reg<bool>(false), Reg<bool>(false), Reg<bool>(false), Reg<bool>(false) }
    , dummy_req_out  { Reg<optional<MeshReq>>(std::nullopt), Reg<optional<MeshReq>>(std::nullopt),
                       Reg<optional<MeshReq>>(std::nullopt), Reg<optional<MeshReq>>(std::nullopt) }
    , dummy_req_ack_from { Reg<bool>(false), Reg<bool>(false), Reg<bool>(false), Reg<bool>(false) }
    , dummy_rsp_in   { Reg<optional<MeshRsp>>(std::nullopt), Reg<optional<MeshRsp>>(std::nullopt),
                       Reg<optional<MeshRsp>>(std::nullopt), Reg<optional<MeshRsp>>(std::nullopt) }
    , dummy_rsp_ack_to { Reg<bool>(false), Reg<bool>(false), Reg<bool>(false), Reg<bool>(false) }
    , dummy_rsp_out  { Reg<optional<MeshRsp>>(std::nullopt), Reg<optional<MeshRsp>>(std::nullopt),
                       Reg<optional<MeshRsp>>(std::nullopt), Reg<optional<MeshRsp>>(std::nullopt) }
    , dummy_rsp_ack_from { Reg<bool>(false), Reg<bool>(false), Reg<bool>(false), Reg<bool>(false) }
    {}
};

// Build all nodes with correct coords (Regs constructed with inits)
static std::vector<NodeLocal> nodes = []{
    std::vector<NodeLocal> v;
    v.reserve(NUM_ROWS * NUM_COLS);
    for (uint32_t y = 0; y < NUM_ROWS; ++y)
        for (uint32_t x = 0; x < NUM_COLS; ++x)
            v.emplace_back(static_cast<uint8_t>(x), static_cast<uint8_t>(y));
    return v;
}();

// Helper to get node by (x,y)
static inline NodeLocal& N(uint32_t x, uint32_t y) { return nodes[node_id(x,y)]; }


void implement_mesh() {
    // =========================================
    // Instantiate topology
    // =========================================
    for (uint32_t y = 0; y < NUM_ROWS; ++y) {
        for (uint32_t x = 0; x < NUM_COLS; ++x) {
            auto& Nd = N(x,y);

            // ----- Partial core fill at this node -----
            const uint32_t node_lin   = node_id(x, y);
            const uint32_t core_start = node_lin * CORES_PER_NODE;
            const uint32_t cores_left = (NUM_CORES > core_start) ? (NUM_CORES - core_start) : 0u;
            const uint32_t present    = (cores_left < CORES_PER_NODE) ? cores_left : CORES_PER_NODE;

            new_part_group();

            for (uint32_t c = 0; c < CORES_PER_NODE; ++c) {
                if (c < present) {
                    // Core wires were already constructed (nullopt / false). Just instantiate the core.
                    new_coarse_group();
                    rv32i_5stage(Nd.core_mem_req[c], Nd.core_mem_rsp[c]);
                }
            }
            new_coarse_group();

            // ----- Neighbor selection (choose real links or per-node dummies) -----
            // Direction order: 0=up, 1=right, 2=down, 3=left
            // Request plane inputs
            Reg<optional<MeshReq>> &from_up_req    = (y > 0)             ? RE_to_south(y-1, x)
                                                                    : Nd.dummy_req_in[0];
            Reg<optional<MeshReq>> &from_right_req = (x+1 < NUM_COLS && H_GAPS)
                                                    ? RE_to_west(y, x) : Nd.dummy_req_in[1];
            Reg<optional<MeshReq>> &from_down_req  = (y+1 < NUM_ROWS && V_GAPS)
                                                    ? RE_to_north(y, x) : Nd.dummy_req_in[2];
            Reg<optional<MeshReq>> &from_left_req  = (x > 0)
                                                    ? RE_to_east(y, x-1) : Nd.dummy_req_in[3];

            // Acks we assert back for the above inputs
            Reg<bool> &ack_to_up_req    = (y > 0)             ? RA_from_south(y-1, x)
                                                            : Nd.dummy_req_ack_to[0];
            Reg<bool> &ack_to_right_req = (x+1 < NUM_COLS && H_GAPS)
                                        ? RA_from_west(y, x) : Nd.dummy_req_ack_to[1];
            Reg<bool> &ack_to_down_req  = (y+1 < NUM_ROWS && V_GAPS)
                                        ? RA_from_north(y, x) : Nd.dummy_req_ack_to[2];
            Reg<bool> &ack_to_left_req  = (x > 0)
                                        ? RA_from_east(y, x-1) : Nd.dummy_req_ack_to[3];

            // Request plane outputs
            Reg<optional<MeshReq>> &to_up_req    = (y > 0)             ? RE_to_north(y-1, x)
                                                                    : Nd.dummy_req_out[0];
            Reg<optional<MeshReq>> &to_right_req = (x+1 < NUM_COLS && H_GAPS)
                                                ? RE_to_east(y, x) : Nd.dummy_req_out[1];
            Reg<optional<MeshReq>> &to_down_req  = (y+1 < NUM_ROWS && V_GAPS)
                                                ? RE_to_south(y, x) : Nd.dummy_req_out[2];
            Reg<optional<MeshReq>> &to_left_req  = (x > 0)
                                                ? RE_to_west(y, x-1) : Nd.dummy_req_out[3];

            // Acks arriving for our outputs
            Reg<bool> &ack_from_up_req    = (y > 0)             ? RA_from_north(y-1, x)
                                                                : Nd.dummy_req_ack_from[0];
            Reg<bool> &ack_from_right_req = (x+1 < NUM_COLS && H_GAPS)
                                            ? RA_from_east(y, x) : Nd.dummy_req_ack_from[1];
            Reg<bool> &ack_from_down_req  = (y+1 < NUM_ROWS && V_GAPS)
                                            ? RA_from_south(y, x) : Nd.dummy_req_ack_from[2];
            Reg<bool> &ack_from_left_req  = (x > 0)
                                            ? RA_from_west(y, x-1) : Nd.dummy_req_ack_from[3];

            // Response plane inputs
            Reg<optional<MeshRsp>> &rfrom_up_rsp    = (y > 0)             ? RS_to_south(y-1, x)
                                                                        : Nd.dummy_rsp_in[0];
            Reg<optional<MeshRsp>> &rfrom_right_rsp = (x+1 < NUM_COLS && H_GAPS)
                                                    ? RS_to_west(y, x) : Nd.dummy_rsp_in[1];
            Reg<optional<MeshRsp>> &rfrom_down_rsp  = (y+1 < NUM_ROWS && V_GAPS)
                                                    ? RS_to_north(y, x) : Nd.dummy_rsp_in[2];
            Reg<optional<MeshRsp>> &rfrom_left_rsp  = (x > 0)
                                                    ? RS_to_east(y, x-1) : Nd.dummy_rsp_in[3];

            // Acks we assert back for the above response inputs
            Reg<bool> &rack_to_up_rsp    = (y > 0)             ? RAe_from_south(y-1, x)
                                                            : Nd.dummy_rsp_ack_to[0];
            Reg<bool> &rack_to_right_rsp = (x+1 < NUM_COLS && H_GAPS)
                                        ? RAe_from_west(y, x) : Nd.dummy_rsp_ack_to[1];
            Reg<bool> &rack_to_down_rsp  = (y+1 < NUM_ROWS && V_GAPS)
                                        ? RAe_from_north(y, x) : Nd.dummy_rsp_ack_to[2];
            Reg<bool> &rack_to_left_rsp  = (x > 0)
                                        ? RAe_from_east(y, x-1) : Nd.dummy_rsp_ack_to[3];

            // Response plane outputs
            Reg<optional<MeshRsp>> &rto_up_rsp    = (y > 0)             ? RS_to_north(y-1, x)
                                                                    : Nd.dummy_rsp_out[0];
            Reg<optional<MeshRsp>> &rto_right_rsp = (x+1 < NUM_COLS && H_GAPS)
                                                ? RS_to_east(y, x) : Nd.dummy_rsp_out[1];
            Reg<optional<MeshRsp>> &rto_down_rsp  = (y+1 < NUM_ROWS && V_GAPS)
                                                ? RS_to_south(y, x) : Nd.dummy_rsp_out[2];
            Reg<optional<MeshRsp>> &rto_left_rsp  = (x > 0)
                                                ? RS_to_west(y, x-1) : Nd.dummy_rsp_out[3];

            // Acks arriving for our response outputs
            Reg<bool> &rack_from_up_rsp    = (y > 0)             ? RAe_from_north(y-1, x)
                                                                : Nd.dummy_rsp_ack_from[0];
            Reg<bool> &rack_from_right_rsp = (x+1 < NUM_COLS && H_GAPS)
                                            ? RAe_from_east(y, x) : Nd.dummy_rsp_ack_from[1];
            Reg<bool> &rack_from_down_rsp  = (y+1 < NUM_ROWS && V_GAPS)
                                            ? RAe_from_south(y, x) : Nd.dummy_rsp_ack_from[2];
            Reg<bool> &rack_from_left_rsp  = (x > 0)
                                            ? RAe_from_west(y, x-1) : Nd.dummy_rsp_ack_from[3];

            // ----- Switch -----
            task(node_switch,
                Nd.core_mem_req[0], Nd.core_mem_req[1], Nd.core_mem_req[2], Nd.core_mem_req[3],
                Nd.switch_req_buf, Nd.switch_prio, Nd.switch_port_state,
                Nd.switch_req_buf, Nd.switch_prio, Nd.switch_port_state,
                Nd.nodeReq_from_switch,      // to node_req
                Nd.nodeAck_to_switch,        // from node_req
                Nd.nodeRsp_to_switch,        // from node_rsp
                Nd.core_mem_rsp[0], Nd.core_mem_rsp[1], Nd.core_mem_rsp[2], Nd.core_mem_rsp[3]);

            // ----- node_req -----
            Reg<uint8_t>  nreq_version(0);
            Reg<Counter<NETWORK_LATENCY>> memLatCounter(Counter<NETWORK_LATENCY>(false));
            task(node_req,
                Nd.self_coord_req,
                Nd.nodeReq_from_switch,
                Nd.req_send_buf, Nd.req_port_states, memLatCounter,
                from_up_req, from_right_req, from_down_req, from_left_req,
                ack_from_up_req, ack_from_right_req, ack_from_down_req, ack_from_left_req,
                Nd.local_mesh_rsp_ack,
                nreq_version, nreq_version,
                Nd.req_send_buf, Nd.req_port_states, memLatCounter,
                to_up_req, to_right_req, to_down_req, to_left_req,
                ack_to_up_req, ack_to_right_req, ack_to_down_req, ack_to_left_req,
                Nd.nodeAck_to_switch,
                Nd.local_mesh_rsp);

            // ----- node_rsp -----
            Reg<uint8_t>  nrsp_version(0);
            task(node_rsp,
                Nd.self_coord_rsp,
                Nd.rsp_send_buf, Nd.rsp_port_states,
                Nd.local_mesh_rsp, Nd.local_mesh_rsp_ack,
                rfrom_up_rsp, rfrom_right_rsp, rfrom_down_rsp, rfrom_left_rsp,
                rack_from_up_rsp, rack_from_right_rsp, rack_from_down_rsp, rack_from_left_rsp,
                nrsp_version, nrsp_version,
                Nd.rsp_send_buf, Nd.rsp_port_states,
                rto_up_rsp, rto_right_rsp, rto_down_rsp, rto_left_rsp,
                rack_to_up_rsp, rack_to_right_rsp, rack_to_down_rsp, rack_to_left_rsp,
                Nd.nodeRsp_to_switch);
        }

    }
}

int main(int argc, char* argv[]) {
    assert(argc == 2);
    uint32_t NCores = std::stoi(argv[1]);
    assert(NCores > 0);
    implement_mesh();
    // for (uint32_t coreId = 0; coreId < NCores; coreId++) {
    //     rv32i_5stage();
    // }
}
