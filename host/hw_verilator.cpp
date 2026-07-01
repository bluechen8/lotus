/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include "hw.h"
#include "network.h"

#ifdef VM_TRACE
#if VM_TRACE
#define VERILATOR_HW_TRACE
#endif
#endif

#include "Vxrt_top.h"
#include "verilated.h"

#ifdef VERILATOR_HW_TRACE
#include "verilated_vcd_c.h"
#endif

#include <sys/mman.h>
#include <sys/time.h>
#include <stdarg.h>
#include <random>

#define DEBUG_MEM(args...) //printf(args)
#define DEBUG_CONTROL(args...) //printf(args)

// DPI trace enable Start
static bool trace_enabled = false;
bool sim_trace_enabled() {
    return true;
  return trace_enabled;
}

void sim_trace_enable(bool enable) {
  trace_enabled = enable;
}
// DPI trace enable End

namespace hw {

// NOTE(dsm): The FPGA platform is necessary even in Verilator because
// different platforms have different amounts of memory, and offset bits are
// immediately after. We must mask off those offset bits.
#if defined(PLATFORM_u250)
const size_t memBytes = 4ul*1024*1024*1024;
#elif defined(PLATFORM_u55c)
const size_t memBytes = 4ul*1024*1024*1024;
#else
#error "Need platform define"
#endif
const size_t memMask = memBytes - 1;

// Simulates one cycle for the whole system
void tick(bool skip_mem=false);

static inline uint64_t curCycle();

// Used by memory controllers; not using rand() / srand() since it seems
// Verilator uses it as well in some modes, e.g., with random initialization
std::mt19937 randInt(42);


struct MemChannel {
    // Ports - copied verbatim from Verilator, all refs
    VL_OUT8(&awvalid,0,0);
    VL_IN8(&awready,0,0);
    VL_OUT64(&awaddr,63,0);
    VL_OUT8(&awlen,7,0);
    VL_OUT16(&awid,15,0);
    VL_OUT8(&wvalid,0,0);
    VL_IN8(&wready,0,0);
    VL_OUT64((&wdata),63, 0);
    VL_OUT8(&wstrb,7,0);
    VL_OUT8(&wlast,0,0);
    VL_OUT16(&wid,15,0);
    VL_IN8(&bvalid,0,0);
    VL_IN16(&bid,15,0);
    VL_OUT8(&bready,0,0);
    VL_IN8(&bresp,1,0);
    VL_OUT8(&arvalid,0,0);
    VL_IN8(&arready,0,0);
    VL_OUT64(&araddr,63,0);
    VL_OUT8(&arlen,7,0);
    VL_OUT16(&arid,15,0);
    VL_IN8(&rvalid,0,0);
    VL_OUT8(&rready,0,0);
    VL_IN64((&rdata),63, 0);
    VL_IN8(&rresp,1,0);
    VL_IN8(&rlast,0,0);
    VL_IN16(&rid,15,0);

    // NOTE(dsm): Members below are logically private, but to make
    // initialization easy we want this to be a POD type, so left public
    struct MemReq {
        uint64_t addr;
        uint16_t id;
        uint8_t len;
    };

    uint8_t chunkBytes        = 8;
    uint8_t chunksInCacheLine = (512/8)/chunkBytes;

    std::deque<MemReq> wrReqs = {};
    std::deque<MemReq> bResps = {};
    std::deque<MemReq> rdResps = {};

    const uint32_t channelId;
    uint8_t* const mem;
    // dsm: Make configurable once we model timing correctly
    const uint32_t maxRdReqs = 4;
    const uint32_t maxWrReqs = 4;

    uint64_t nextAWCycle, nextWCycle, nextARCycle;

  private:
    void wdataToMem(uint64_t channelAddr) {
        assert((channelAddr & 0b111) == 0);
        auto memAddr = channelAddr & memMask;
        auto byteMask = wstrb;
        uint8_t* memStart   = (uint8_t*) &mem[memAddr];
        uint8_t* wdataStart = (uint8_t*)&wdata;
        for (uint32_t b = 0; b < 8; b++) {
            if (byteMask & 1) memStart[b] = wdataStart[b];
            byteMask >>= 1;
        }
    }

    void rdataFromMem(uint64_t channelAddr) {
        assert((channelAddr & 0b111) == 0);
        auto memAddr = channelAddr & memMask;
        memcpy(&rdata, &mem[memAddr], 8);
    }

  public:
    void init() {
        awready = 1;
        wready = 0;
        bvalid = 0;
        arready = 1;
        rvalid = 0;
        bresp = 0;
        rresp = 0;

        nextAWCycle = 0;
        nextWCycle = 0;
        nextARCycle = 0;
    }

    // Call this every cycle, at the END of the cycle
    void eval() {
        // Write side is served aw, w, b
        if (awready && awvalid) {
            wrReqs.emplace_back(MemReq{awaddr, awid, awlen});
            DEBUG_MEM("[%ld][%d] Got awaddr 0x%lx awid %x awlen %d\n", curCycle(), channelId, awaddr, awid, awlen);
            nextAWCycle = curCycle() + (randInt() % 20);
        }

        if (wready && wvalid) {
            bool found = false;
            for (auto r = wrReqs.begin(); r != wrReqs.end(); r++) {
                if (r->id == wid) {
                    const uint16_t chunkIdx   = (chunksInCacheLine-1) - r->len;
                    const uint16_t byteOffset = chunkIdx * chunkBytes;
                    DEBUG_MEM("[%ld][%d] Got write for 0x%lx (0x%x) id %x len %d\n", curCycle(), channelId, r->addr, byteOffset, r->id, r->len);
                    found = true;
                    wdataToMem(r->addr + byteOffset);
                    if (r->len == 0) {
                        bResps.push_back(*r);
                        wrReqs.erase(r);
                    } else {
                        r->len -= 1;
                    }
                    break;
                }
            }
            if (!found) {
                printf("[%ld][%d] ERROR: Got unmatched write for wid %x!!\n", curCycle(), channelId, wid);
                exit(-1);
            }
            assert(found);
            nextWCycle = curCycle() + (randInt() % 16);
        }

        if (bvalid && bready) {
            assert(!bResps.empty());
            DEBUG_MEM("[%d] Finished write 0x%lx id %x\n", channelId, bResps.front().addr, bResps.front().id);
            bResps.pop_front();
            bvalid = 0;
        } else {
            if (bResps.empty()) {
                bvalid = 0;
            } else {
                bvalid = 1;
                bid = bResps.front().id;
                DEBUG_MEM("[%d] Serving resp for write 0x%lx id %x\n", channelId, bResps.front().addr, bResps.front().id);
            }
        }

        // Admission control
        if (wrReqs.size() + bResps.size() >= maxWrReqs) {
            awready = 0;
            wready = 0;
        } else {
            awready = (curCycle() >= nextAWCycle);
            wready = !wrReqs.empty() && (curCycle() >= nextWCycle);
        }

        // Read side is simpler, one shot
        if (arready && arvalid) {
           rdResps.emplace_back(MemReq{araddr, arid, arlen});
           DEBUG_MEM("[%d] Got araddr 0x%lx arid %x arlen %d\n", channelId, araddr, arid, arlen);
           nextARCycle = curCycle() + (randInt() % 10);
        }

        if (rvalid && rready) {
            assert(!rdResps.empty());
            MemReq& rdResp = rdResps.front();
            DEBUG_MEM("[%d] Finished read 0x%lx id %x len %d\n", channelId, rdResp.addr, rdResp.id, rdResp.len);
            if (rdResp.len == 0) {
                rdResps.pop_front();
            } else {
                rdResp.len -= 1;
            }
            rvalid = 0;
        } else {
            if (rdResps.empty()) {
                rvalid = 0;
            } else {
                rvalid = 1;
                rid = rdResps.front().id;
                const uint16_t chunkIdx   = (chunksInCacheLine-1) - rdResps.front().len;
                const uint16_t byteOffset = chunkIdx * chunkBytes;
                rdataFromMem(rdResps.front().addr+byteOffset);
                DEBUG_MEM("[%d] Serving read 0x%lx+0x%x (chunkIdx=%d) id %x len %d\n", channelId, rdResps.front().addr, byteOffset, chunkIdx, rid, rdResps.front().len);
            }
        }

        if (rdResps.size() >= maxRdReqs) {
            arready = 0;
        } else {
            arready = (curCycle() >= nextARCycle);
        }
    }
};

struct ControlInterface {
    // Ports - copied verbatim from Verilator, all refs
    VL_IN8(&awvalid,0,0);
    VL_OUT8(&awready,0,0);
    VL_IN16(&awaddr,15,0);
    VL_IN8(&wvalid,0,0);
    VL_OUT8(&wready,0,0);
    VL_IN(&wdata,31,0);
    VL_IN8(&wstrb,3,0);
    VL_IN8(&arvalid,0,0);
    VL_OUT8(&arready,0,0);
    VL_IN16(&araddr,15,0);
    VL_OUT8(&rvalid,0,0);
    VL_IN8(&rready,0,0);
    VL_OUT(&rdata,31,0);
    VL_OUT8(&rresp,1,0);
    VL_OUT8(&bvalid,0,0);
    VL_IN8(&bready,0,0);
    VL_OUT8(&bresp,1,0);

    void init() {
       awvalid = 0;
       wvalid = 0;
       bready = 0;
       arvalid = 0;
       rready = 0;
    }

    uint32_t read_reg(uint32_t addr) {
        araddr = (uint16_t) addr;
        arvalid = 1;
        rready = 1;
        DEBUG_CONTROL("read_reg 0x%x start\n", addr);
        tick();
        while (!arready) {
            DEBUG_CONTROL("read_reg waiting for arready\n");
            tick();
        }
        arvalid = 0;
        while (!rvalid) {
            DEBUG_CONTROL("read_reg waiting for arvalid\n");
            tick();
        }
        rready = 0;
        DEBUG_CONTROL("read_reg 0x%x -> data 0x%x\n", addr, rdata);
        return rdata;
    }

    void write_reg(uint32_t addr, uint32_t data) {
        awaddr = (uint16_t) addr;
        awvalid = 1;
        wdata = data;
        wstrb = 0b1111;
        wvalid = 1;
        bready = 1;
        DEBUG_CONTROL("write_reg addr 0x%x data 0x%x start\n", addr, data);
        bool aw_done = false;
        bool w_done = false;
        bool b_done = false;
        while (!(aw_done && w_done && b_done)) {
            tick();
            DEBUG_CONTROL("write_reg status %d %d %d | %d %d\n",
                    aw_done, w_done, b_done, bvalid, bready);
            if (awvalid && awready) {
                assert(!aw_done);
                aw_done = true;
                awvalid = 0;
            }
            if (wvalid && wready) {
                assert(!w_done);
                w_done = true;
                wvalid = 0;
            }
            if (bvalid && bready) {
                assert(!b_done);
                b_done = true;
                bready = 0;
            }
        }
        DEBUG_CONTROL("write_reg done\n");
    }
};

struct CrossDeviceInterface {
    VL_OUTW((&tx_axis_tdata),95,0,3);
    VL_OUT8(&tx_axis_tvalid,0,0);
    VL_IN8(&tx_axis_tready,0,0);
    VL_INW((&rx_axis_tdata),95,0,3);
    VL_IN8(&rx_axis_tvalid,0,0);
    VL_OUT8(&rx_axis_tready,0,0);

    uint8_t prev_rx_axis_tready = 0;
};



struct CrossDeviceConnection {
    CrossDeviceInterface* ifc0;
    CrossDeviceInterface* ifc1;

    void init() {
        ifc0->rx_axis_tvalid = 0;
        ifc0->tx_axis_tready = 0;
        ifc1->rx_axis_tvalid = 0;
        ifc1->tx_axis_tready = 0;
    }

    // NOTE(dsm): OK, this is weird. This is called once per cycle, right
    // before the positive clock edge. Devices sample on positive clock edges,
    // but do so based on the ready values of the PREVIOUS cycle. For example,
    // dst->rx_axis_tvalid && dst->rx_axis_tready is NOT a valid handshake condition
    // for the LAST positive clock edge, because dst->rx_axis_tready is under
    // the control of the logic, and it may already have changed, even though
    // on the LAST positive clock edge, rx_axis_tready was 1.
    // So, just sample previous tready/valid OUTPUTS, and use them to infer conditions.
    void eval() {
        auto evalOneSide = [](CrossDeviceInterface* src, CrossDeviceInterface* dst) {
            // 1. If rx transfer happened, invalidate current element
            if (dst->rx_axis_tvalid && dst->prev_rx_axis_tready) {
                //printf("RX xfer complete\n");
                dst->rx_axis_tvalid = 0;
                // dsm: This shouldn't be true in general... but it is??
                //assert(dst->prev_rx_axis_tready == dst->rx_axis_tready);
            }

            // 2. If tx has a valid output NOW and we have space, sample it and ack the transfer
            if (src->tx_axis_tvalid && !dst->rx_axis_tvalid) {
                //printf("TX->RX xfer\n");
                // FIXME: Hardcoded loop bound based on VL_INW def... verilator must have a better way to do wide assigns, no?
                for (uint32_t i = 0; i < 3; i++) {
                    dst->rx_axis_tdata[i] = src->tx_axis_tdata[i];
                }
                dst->rx_axis_tvalid = 1;
                src->tx_axis_tready = 1;
            } else {
                src->tx_axis_tready = 0;
            }

            // 3. This will be used to evaluate whether dst took the data on the next eval()
            dst->prev_rx_axis_tready = dst->rx_axis_tready;
        };

        evalOneSide(ifc0, ifc1);
        evalOneSide(ifc1, ifc0);
    }
};

// Port-tying macros -- avoid boilerplace, esp. with MemChannels
#define CONCAT(a, b) a##b
#define SET_PORT(name, prefix) .name = CONCAT(prefix, name)

#define SET_MEMCHANNEL_PORTS(prefix) \
    SET_PORT(awvalid, prefix), \
    SET_PORT(awready, prefix), \
    SET_PORT(awaddr, prefix), \
    SET_PORT(awlen, prefix), \
    SET_PORT(awid, prefix), \
    SET_PORT(wvalid, prefix), \
    SET_PORT(wready, prefix), \
    SET_PORT(wdata, prefix), \
    SET_PORT(wstrb, prefix), \
    SET_PORT(wlast, prefix), \
    SET_PORT(wid, prefix), \
    SET_PORT(bvalid, prefix), \
    SET_PORT(bid, prefix), \
    SET_PORT(bready, prefix), \
    SET_PORT(bresp, prefix), \
    SET_PORT(arvalid, prefix), \
    SET_PORT(arready, prefix), \
    SET_PORT(araddr, prefix), \
    SET_PORT(arlen, prefix), \
    SET_PORT(arid, prefix), \
    SET_PORT(rvalid, prefix), \
    SET_PORT(rready, prefix), \
    SET_PORT(rdata, prefix), \
    SET_PORT(rresp, prefix), \
    SET_PORT(rlast, prefix), \
    SET_PORT(rid, prefix)

#define SET_CONTROL_PORTS(prefix) \
    SET_PORT(awvalid, prefix), \
    SET_PORT(awready, prefix), \
    SET_PORT(awaddr, prefix), \
    SET_PORT(wvalid, prefix), \
    SET_PORT(wready, prefix), \
    SET_PORT(wdata, prefix), \
    SET_PORT(wstrb, prefix), \
    SET_PORT(arvalid, prefix), \
    SET_PORT(arready, prefix), \
    SET_PORT(araddr, prefix), \
    SET_PORT(rvalid, prefix), \
    SET_PORT(rready, prefix), \
    SET_PORT(rdata, prefix), \
    SET_PORT(rresp, prefix), \
    SET_PORT(bvalid, prefix), \
    SET_PORT(bready, prefix), \
    SET_PORT(bresp, prefix)

#define SET_CD_PORT(prefix, idx, suffix) .CONCAT(prefix,_axis_##suffix) = CONCAT(top.prefix##idx,_axis_##suffix)
#define SET_CROSSDEVICE_PORTS(idx) \
    SET_CD_PORT(tx, idx, tdata), \
    SET_CD_PORT(tx, idx, tvalid), \
    SET_CD_PORT(tx, idx, tready), \
    SET_CD_PORT(rx, idx, tdata), \
    SET_CD_PORT(rx, idx, tvalid), \
    SET_CD_PORT(rx, idx, tready)

class VlDevice : public Device {
  public:  // visible to tick() etc, but all external interactions are through Device
    const uint32_t id;

    // Physical memory --- we allocate all space, and rely on lazy demand paging to
    // avoid undue memory consumption
    uint8_t* mem;

    // Model elems
    Vxrt_top top;
#ifdef VERILATOR_HW_TRACE
    VerilatedVcdC tfp;
#endif
    std::array<MemChannel*, NUM_MEM_CHANNELS> memChannels;
    ControlInterface* controlIfc;
    std::array<CrossDeviceInterface*, MAX_DEVICES> crossDeviceIfcs;

    VlDevice(uint32_t id) : id(id) {
        mem = (uint8_t*) mmap(nullptr, memBytes, PROT_READ | PROT_WRITE,
                MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
        if (mem == MAP_FAILED) {
            printf("[vhw] fatal: could not mmap memory for device %d, %s\n",
                    id, strerror(errno));
            exit(-1);
        }

#ifdef VERILATOR_HW_TRACE
        if (id == 0) printf("[vhw] Tracing is enabled\n");
        top.trace(&tfp, 99);
        std::string vcdName = "verilator_dump_";
        vcdName += std::to_string(id);
        vcdName += ".vcd";
        tfp.open(vcdName.c_str());
#else
        if (id == 0) printf("[vhw] Tracing is not enabled\n");
#endif

        controlIfc = new ControlInterface{SET_CONTROL_PORTS(top.s_axi_control_)};

        // Has mem-channel init, e.g., memChannels[0] = new MemChannel{SET_MEMCHANNEL_PORTS(top.m00_axi_), .channelId = 0, .mem = mem};
        #include "auto_create_mem_channels.cpp.inc"


        for (uint64_t i = 0; i < memChannels.size(); i++) {
            memChannels[i]->init();
        }
        controlIfc->init();

#if LOG2_MAX_DEVICES > 0
        crossDeviceIfcs[0] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(0)};
        crossDeviceIfcs[1] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(1)};
#if LOG2_MAX_DEVICES > 1
        crossDeviceIfcs[2] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(2)};
        crossDeviceIfcs[3] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(3)};
#if LOG2_MAX_DEVICES > 2
        crossDeviceIfcs[4] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(4)};
        crossDeviceIfcs[5] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(5)};
        crossDeviceIfcs[6] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(6)};
        crossDeviceIfcs[7] = new CrossDeviceInterface{SET_CROSSDEVICE_PORTS(7)};
#if LOG2_MAX_DEVICES > 3
#error "Only up to 8 devices supported for now (do you really have the patience to simulate more? :)"
#endif
#endif
#endif
#endif
    }

    void read_mem(uint8_t* buffer, size_t bytes, size_t address) {
        printf("[vhw] Reading %ld bytes at 0x%lx from FPGA %d\n", bytes, address, id);
        memcpy(buffer, &mem[address], bytes);
    }

    void write_mem(uint8_t* buffer, size_t bytes, size_t address) {
        printf("[vhw] Writing %ld bytes at 0x%lx to FPGA %d\n", bytes, address, id);
        memcpy(&mem[address], buffer, bytes);
    }

    uint32_t read_reg(uint16_t addr) {
        return controlIfc->read_reg(addr);
    }

    void write_reg(uint16_t addr, uint32_t data) {
        controlIfc->write_reg(addr, data);
    }

    uint32_t get_id() const { return id; }
};

// Global state
uint64_t g_cycle;
std::vector<VlDevice*> devices;
std::vector<CrossDeviceConnection*> crossDeviceConnections;

VlDevice* curDevice = nullptr;  // for vl_printf

#ifdef VERILATOR_HW_TRACE
bool doTrace() {
    return true;
    auto in_range = [](uint32_t ts,
            uint32_t target,
              uint32_t bwindow, uint32_t awindow) -> bool {
        uint32_t start = target - bwindow;
        uint32_t end   = target + awindow;
        return (ts >= start) && (ts < end);
    };
    return in_range(curCycle(), 1321358, 10000, 10000);
}
#endif

void tick(bool skip_mem) {
    for (auto d : devices) {
        curDevice = d;
        d->top.ap_clk = 1;
        d->top.eval();
    }
    curDevice = nullptr;
    ++g_cycle;
#ifdef VERILATOR_HW_TRACE
    if (doTrace()) {
        for (auto d : devices) d->tfp.dump(g_cycle);
    }
#endif

    for (auto d : devices) {
        curDevice = d;
        d->top.ap_clk = 0;
        d->top.eval();
    }
    curDevice = nullptr;

#if LOG2_MAX_DEVICES != 0
    for (auto c : crossDeviceConnections) {
        c->eval();
    }

    // NOTE(dsm): Per Verilator manual, "Note combinatorial logic is not
    // computed before sequential always blocks are computed (for speed
    // reasons). Therefore it is best to set any non-clock inputs up with a
    // separate eval() call before changing clocks.
    //
    // Alternatively, if all always_ff statements use only the posedge of
    // clocks, or all inputs go directly to always_ff statements, as is
    // typical, then you can change non-clock inputs on the negative edge of
    // the input clock, which will be faster as there will be fewer eval()
    // calls.
    // "
    //
    // https://verilator.org/guide/latest/connecting.html#evaluation-loop
    //
    // This actually matters here, as if signals are not propagated, I see
    // "shadow" behavior on tvalid that causes multiple transmissions of the
    // same item. Basically, we set tready BUT THE MODEL DOESN'T SEE IT till
    // the next cycle unless we call eval() again BEFORE raising ap_clk!
    //

    // FIXME(dsm): This is likely affecting the memory controllers below, and
    // they should be pushed up before this eval().
    // NOTE(dsm): If you do move the memory controllers before this eval, note
    // that memory controller code will need to be modified, because they're
    // relying on changes to outputs not being visible until the next cycle.
    for (auto d : devices) {
        curDevice = d;
        d->top.eval();
    }
#endif

    if (skip_mem) return;

    for (auto d : devices) {
        for (MemChannel* m : d->memChannels) {
            m->eval();
        }
    }
}

static inline uint64_t curCycle() { return g_cycle; }

void reset() {
    // Reset (note we don't eval memChannels on reset, as signals may be garbage)
    for (auto d : devices) d->top.ap_rst_n = 0;
    printf("[vhw] Setting ap_rst_n to 0 at cycle: %ld\n", g_cycle);
    for (uint32_t c = 0; c < 100; c++) {
        tick(true);
    }
    for (auto d : devices) d->top.ap_rst_n = 1;
    printf("[vhw] Setting ap_rst_n to 1 at cycle: %ld\n", g_cycle);
    // Reset is pipelined, so give some time for the circuit to leave reset
    for (uint32_t c = 0; c < 100; c++) {
        tick(true);
    }
    tick();
}

// TODO: Port to use VlDevice
std::vector<Device*> init(int argc, const char* argv[]) {
    Verilated::commandArgs(argc, argv);
#ifdef VERILATOR_HW_TRACE
    Verilated::traceEverOn(true);
#endif

    const char* envSeed = getenv("LOTUS_VL_RAND_SEED");
    if (envSeed) {
        uint32_t seed = atoi(envSeed);
        printf("[vhw] Using random seed = %d\n", seed);
        randInt.seed(seed);
    }

    // TODO: Maybe make runtime flag-configurable? e.g., we may want to
    // simulate 2 FPGAs even if the FPGA image has 8 cross-device connections
    uint32_t numDevices = MAX_DEVICES;
    for (uint32_t i = 0; i < numDevices; i++) {
        devices.push_back(new VlDevice(i));
    }

    network::setIdMap(0, 0, numDevices);

    // This gets all the connections once, because all connections are between
    // top-half and bottom-half ports. Note how we're only iterating over the
    // top-half ports of each source.
    for (uint32_t srcId = 0; srcId < numDevices; srcId++) {
        for (uint32_t srcPort = 0; srcPort < numDevices/2; srcPort++) {
            uint32_t dstId = network::getDstId(srcId, srcPort);
            // dstId == -1 denotes disconnected/don't-use; one port/device is like this
            if (dstId != -1) {
                uint32_t dstPort = network::getSrcPort(dstId, srcId);
                CrossDeviceConnection* c = new CrossDeviceConnection{devices[srcId]->crossDeviceIfcs[srcPort], devices[dstId]->crossDeviceIfcs[dstPort]};
                crossDeviceConnections.push_back(c);
            }
        }
    }

    g_cycle = 0;
    reset();

    std::vector<Device*> res;
    for (auto d : devices) res.push_back(d);
    return res;
}

void wait_for_cross_device_links() {
    // Nothing to do in VL, this is for XRT
}

void fini() {
#ifdef VERILATOR_HW_TRACE
    printf("[vhw] Flushing trace files\n");
    for (auto d : devices) {
        d->tfp.flush();
        d->tfp.close();
    }
#endif
}

};

static bool atLineStart = true;

int vl_printf(const char *format, ...) {
    va_list args;
    int done;
    if ((LOG2_MAX_DEVICES == 0) || !hw::curDevice) {
        va_start(args, format);
        done = vprintf(format, args);
        va_end(args);
    } else {
        char* buf;
        va_start(args, format);
        done = vasprintf(&buf, format, args);
        va_end(args);
        if (done < 0) return done;

        char* curLine = buf;

        auto printLine = [&curLine](bool closeLine) {
            if (atLineStart) printf("[d%d] %s%s", hw::curDevice->id, curLine, closeLine? "\n" : "");
            else printf("%s%s", curLine, closeLine? "\n" : "");
        };

        for (int i = 0; i < done; i++) {
            if (buf[i] == '\n') {
                buf[i] = '\0';
                printLine(true);
                curLine = &buf[i+1];
                atLineStart = true;
            }
        }
        if (curLine != &buf[done]) {
            printLine(false);
            atLineStart = false;
        }
        free(buf);
    }
    return done;
}

double sc_time_stamp() {
    return static_cast<double>(hw::g_cycle);
}

