/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include "hw.h"
#include "network.h"

#include "experimental/xrt_device.h"
#include "experimental/xrt_ip.h"
#include "experimental/xrt_bo.h"

#include <cassert>
#include <array>
#include <bitset>

#include <cstdio>
#include <omp.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace hw {

// The U250 and U55C FPGAs have different memory layouts; these constants
// capture their features:
// - NUM_CTRLS reflects the number of memory controllers the *user logic* sees.
//   This is the number of AXI memory ports out of the top-level module.
//   64-byte cache lines are striped across controllers.
// - Each controller can have multiple banks, reflected by NUM_BANKS_PER_CTRL.
//   Memory is mapped sequentially across banks.
// - User-logic addresses always start at 0 and are contiguous, but banks may
//   have different address ranges, even non-contiguous. BANK_MEM_START and
//   BANK_MEM_OFFSET reflect these.
#if defined(PLATFORM_u250)
static const size_t NUM_CTRLS = 1;
static const size_t NUM_BANKS_PER_CTRL = 4;
static const size_t BANK_BITS = 34; // 16 GB
static const size_t BANK_MEM_START = 0x4000000000;
static const size_t BANK_MEM_OFFSET = 0x1000000000;
#elif defined(PLATFORM_u55c)
static const size_t NUM_CTRLS = 1;
static const size_t NUM_BANKS_PER_CTRL = 8;
static const size_t BANK_BITS = 29; // 512MB
static const size_t BANK_MEM_START = 0x0;
static const size_t BANK_MEM_OFFSET = 0x1ul << BANK_BITS;
#else
#error "Need platform define"
#endif

static const size_t NUM_BANKS = NUM_CTRLS * NUM_BANKS_PER_CTRL;
static const size_t BANK_SZ = (1ul << (BANK_BITS));

static const char* targetStr =
#if defined(TARGET_hw_emu)
"hw_emu"
#elif defined(TARGET_hw)
"hw"
#else
#error "Unknown TARGET defined"
#endif
;

// Aurora SIP address map: addresses are all 2 bytes, 0xLLNN
// LL: 0=quad0, 1=quad1, 2=control/status
// For quads:
// NN: 0-7=AXI-side counters, 32-55=user-side counters [8 bytes]
// For control:
// 0x200: init_rstn|quad_rstn [1 byte]
// 0x201: lane_enables [1 byte]
// 0x204: aurora_status[0] [4 bytes]
// 0x205: aurora_status[1] [4 bytes]
// 0x206: 22'b0|lane_enables(8 bits)|init_rstn|quad_rstn [4 bytes]

template <typename T>
void sip_write(xrt::ip& ip, uint16_t address, T data) {
    constexpr size_t totalBytes = 2+sizeof(T);
    uint8_t buf[totalBytes];
    //memcpy(buf, &address, 2); // flip the address bytes
    buf[0] = address >> 8;
    buf[1] = address & 0x00ff;
    memcpy(buf+2, &data, sizeof(T));

    for (size_t curBytes = 0; curBytes < totalBytes; curBytes += 5) {
        size_t xferSize = std::min(totalBytes-curBytes, 5ul);
        uint16_t sipAddr = (((uint16_t)buf[curBytes]) << 8) + (xferSize << 4);
        uint32_t sipData = 0;
        memcpy(&sipData, &buf[curBytes+1], xferSize-1);
        //printf("Sending sipReq: addr %x data %x\n", sipAddr, sipData);
        ip.write_register(sipAddr, sipData);
    }

    // Check request ack/nack (for debugging)
    //uint32_t ackBytes = ip.read_register(0x10);
    //uint32_t ackVal = ip.read_register(0x200);
    //printf("Read sipResp: bytes %d data %x (only valid up to bytes!)\n", ackBytes, ackVal);
}

template <typename T>
T sip_read(xrt::ip& ip, uint16_t address) {
    uint16_t sipAddr = (address & 0xff00) + (2 << 4);
    uint16_t sipData = (address & 0x00ff);
    ip.write_register(sipAddr, sipData);

    uint32_t respBytes = ip.read_register(0x10);
    uint8_t buf[sizeof(T)];
    memset(buf, 0, sizeof(T));
    for (size_t curBytes = 0; curBytes < respBytes; curBytes += 4) {
        size_t xferSize = std::min(respBytes-curBytes, 4ul);
        uint32_t data = ip.read_register(0x200 + curBytes);
        memcpy(&buf[curBytes], &data, xferSize);
    }

    T res;
    memcpy(&res, buf, sizeof(T));
    return res;
}

class XrtDevice : public Device {
  private:
    const uint32_t id;
    // Top-level kernel (actually unmanaged, so an IP)
    xrt::ip kernel;
    // Per-bank memory buffers; we need to perform the striping manually
    xrt::bo kernelBo[NUM_BANKS];
#if MULTI_DEVICE
    xrt::ip aurora;
#endif

  public:
    XrtDevice(uint32_t id, std::string bdf, const char* xclbinFileName) : id(id) {
#if defined(TARGET_hw)
        printf("[xrt][%d] Resetting FPGA card %s\n", id, bdf.c_str());
        std::string resetCmd = "xbutil reset --force -d " + bdf;
        int ret = system(resetCmd.c_str());
        if (ret != 0) {
            printf("[xrt][%d] FPGA reset failed, return code %d\n", id, ret);
            exit(-1);
        }
        printf("[xrt][%d] FPGA reset complete\n", id);

        // NOTE(dsm): This is now run in parallel, but load_xclbin does not
        // work from threads other than the main one, specifically when it
        // actually loads and xclbin (when it just checks the xclbin it wants
        // is loaded, that's OK). So use xbutil program to do the actual
        // programming; load_xclbin below is only used to get the UUID.
        std::string programCmd = "xbutil program -d " + bdf + " -u " + xclbinFileName;
        ret = system(programCmd.c_str());
        if (ret != 0) {
            printf("[xrt][%d] FPGA programming failed, return code %d\n", id, ret);
            exit(-1);
        }
#endif

        auto device = xrt::device(bdf);
        auto uuid = device.load_xclbin(xclbinFileName);
        printf("[xrt][%d] Loaded %s in FPGA card %s\n", id, xclbinFileName, bdf.c_str());
        kernel = xrt::ip(device, uuid.get(), "lotus");
        printf("[xrt][%d] Loaded kernel\n", id);

#if MULTI_DEVICE
        aurora = xrt::ip(device, uuid.get(), "aurora:{aurora_0}");
        printf("[xrt][%d] Loaded aurora IP\n", id);
#endif

        for (uint32_t i = 0; i < NUM_BANKS; i++) {
            kernelBo[i] = xrt::bo(device, BANK_SZ, i /*dsm: these are simply the bank ids*/);
            printf("[xrt][%d] Bank %d BO allocated, address 0x%lx\n", id, i, kernelBo[i].address());
            size_t expectedAddr = BANK_MEM_START + BANK_MEM_OFFSET*i;
            if (kernelBo[i].address() != expectedAddr) {
                printf("[xrt] fatal: Bank address mismatch, should be 0x%lx for target %s. Please keep this in sync with the HDL, which hardcodes these offsets.\n", expectedAddr, targetStr);
            }
        }
    }

  private:
    struct AddrCtrl {
        uint64_t addr;
        uint32_t ctrl;
    };

    static inline AddrCtrl toAddrCtrl(size_t address) {
        const size_t ctrlMask = (NUM_CTRLS-1) << 6;
        const size_t ctrlBits = (NUM_CTRLS == 1)? 0 :
                                (NUM_CTRLS == 2)? 1 :
                                (NUM_CTRLS == 4)? 2 :
                                (NUM_CTRLS == 8)? 3 :
                                (NUM_CTRLS == 16)? 4 :
                                -1; // fail badly, so we catch it
        uint32_t ctrl = (address & ctrlMask) >> 6;
        uint64_t addr = ((address >> (ctrlBits + 6)) << 6) | (address & 0b00111111);
        return {addr, ctrl};
    }

    template <bool isWrite>
    void transfer_mem(uint8_t* buffer, size_t xfer_sz, size_t address) {
        printf("[xrt][%d] %s %ld bytes at 0x%lx %s FPGA\n", id, isWrite? "Writing" : "Reading",
                xfer_sz, address, isWrite? "to" : "from");
        fflush(stdout);

        // Translate to ctrl addresses and sizes
        uint64_t ctrlStart[NUM_CTRLS];
        uint64_t ctrlEnd[NUM_CTRLS];
        uint64_t ctrlSz[NUM_CTRLS];

        uint64_t curAddr = address;
        for (uint32_t i = 0; i < NUM_CTRLS; i++) {
            auto s = toAddrCtrl(curAddr);
            ctrlStart[s.ctrl] = s.addr;
            curAddr = (curAddr & ~63) + 64; // next line
        }

        curAddr = address + xfer_sz;
        for (uint32_t i = 0; i < NUM_CTRLS; i++) {
            auto s = toAddrCtrl(curAddr);
            ctrlEnd[s.ctrl] = s.addr;
            curAddr = (curAddr & ~63) + 64;  // NEXT line, note end is non-inclusive so we're pointing to the beginning of the next line in range.
        }

        for (uint32_t b = 0; b < NUM_CTRLS; b++) {
            assert(ctrlStart[b] <= ctrlEnd[b]);
            ctrlSz[b] = ctrlEnd[b] - ctrlStart[b];
            //printf("ctrl %d start %lx end %lx sz %ld\n", b, ctrlStart[b], ctrlEnd[b], ctrlSz[b]);
        }

        uint64_t totalSz = 0;
        for (uint32_t b = 0; b < NUM_CTRLS; b++) totalSz += ctrlSz[b];
        assert(totalSz == xfer_sz);

        // Allocate sub-buffers, and read them if needed
        xrt::bo bo[NUM_BANKS];
        uint8_t* bmap[NUM_BANKS];
        uint64_t bsize[NUM_BANKS];
        for (uint32_t b = 0; b < NUM_BANKS; b++) {
            uint64_t bankBase = BANK_SZ*(b % NUM_BANKS_PER_CTRL);
            uint64_t bStart = std::max(ctrlStart[b/NUM_BANKS_PER_CTRL], bankBase);
            uint64_t bEnd = std::min(ctrlEnd[b/NUM_BANKS_PER_CTRL], bankBase + BANK_SZ);

            //printf("xfer: %2d | %12lx %12lx %12lx\n", b, bankBase, bStart, bEnd);
            if (bStart < bEnd) {
                bo[b] = xrt::bo(kernelBo[b], bEnd - bStart, bStart - bankBase);
                bmap[b] = bo[b].map<uint8_t*>();
                bsize[b] = bEnd - bStart;
                if (!isWrite) bo[b].sync(XCL_BO_SYNC_BO_FROM_DEVICE, ctrlSz[b], 0);
            } else {
                bmap[b] = nullptr;
                bsize[b] = 0;
            }
        }

        // Copy strided (simple byte-level copy for now... optimize if needed)
        for (size_t p = address; p < address + xfer_sz; p++) {
            auto cur = toAddrCtrl(p);
            size_t offset = cur.addr - ctrlStart[cur.ctrl];
            assert(offset < ctrlSz[cur.ctrl]);

            uint64_t ctrlBank = cur.addr >> BANK_BITS;
            assert(ctrlBank < NUM_BANKS_PER_CTRL);
            uint64_t bank = (cur.ctrl * NUM_BANKS_PER_CTRL) + ctrlBank;
            assert(bank < NUM_BANKS);
            uint64_t bStart = std::max(ctrlStart[cur.ctrl], ctrlBank * BANK_SZ);
            uint64_t bankOffset = cur.addr - bStart;

            //printf("copy: %lx | %u %lx | %lu %lx\n", p, cur.ctrl, offset, bank, bankOffset);
            assert(bmap[bank]);

            if (isWrite) {
                bmap[bank][bankOffset] = buffer[p - address];
            } else {
                buffer[p - address] = bmap[bank][bankOffset];
            }
        }

        if (isWrite) {
            for (uint32_t b = 0; b < NUM_BANKS; b++) {
                if (bsize[b]) bo[b].sync(XCL_BO_SYNC_BO_TO_DEVICE, bsize[b], 0);
            }
        }
    }

  public:

#if MULTI_DEVICE
    void print_aurora_status() {
        for (int i = 0; i < 2; i++) {
            uint32_t reg_read_data = sip_read<uint32_t>(aurora, 0x204 + i);
            printf("[xrt][%d] ", id);
            std::cout << "Aurora qsfp" << i << " startup status is: " << std::bitset<29>(reg_read_data) << std::endl;
            std::cout << "tx ready=" << std::bitset<4>(reg_read_data >> 24 & 0xf)
                << ", channel up=" << std::bitset<4>(reg_read_data >> 20 & 0xf)
                << ", lane up="    << std::bitset<4>(reg_read_data >> 16 & 0xf)
                << ", soft error=" << std::bitset<4>(reg_read_data >> 12 & 0xf)
                << ", hard error=" << std::bitset<4>(reg_read_data >> 8 & 0xf)
                << ", power good=" << std::bitset<4>(reg_read_data >> 4 & 0xf)
                << ", pll locked=" << std::bitset<4>(reg_read_data & 0xf)
                 << ", mcmm locked=" << std::bitset<1>(~reg_read_data >> 28 & 0x1)
                << std::endl;
        }
        printf("[xrt][%d] Global status register:", id);
        uint32_t gsr = sip_read<uint32_t>(aurora, 0x206);
        std::cout << std::bitset<32>(gsr) << std::endl;
    }

    uint32_t laneMask;

    void enable_cross_device_links(const std::vector<uint32_t>& srcPorts) {
        laneMask = 0;
        for (uint32_t sp : srcPorts) {
            assert(sp < 8);
            laneMask |= (1 << sp);
        }

        // dsm: Deassert init reset, but keep quads in reset and all lanes off
        sip_write<uint16_t>(aurora, 0x200, 0b001);
    }

    void print_aurora_counters() {
        for (int i = 0; i < 2; i++) {
            std::vector<uint64_t> counters;
            for (int c = 0; c < 32; c++) {
                uint32_t counterId = (c < 8)? c : (c + 24); // 0-7 or 32-55
                uint64_t counter = sip_read<uint64_t>(aurora, 256*i + counterId);
                counters.push_back(counter);
            }
            printf("[xrt][%d] Aurora qsfp%d counters (lanes %d-%d):\n", id, i, 4*i, 4*i+3);
            for (int c = 0; c < 32; c += 4) {
                const char* names [] = {"axi tx", "axi rx", "lane rx", "overflows", "bad crc", "bad seq", "soft err", "channel down"};
                printf("%16s: ", names[c/4]);
                for (int l = 0; l < 4; l++) printf(" %16ld", counters[c+l]);
                printf("\n");
            }
        }
    }

    void wait_for_aurora_init() {
        printf("[xrt][%d] Checking aurora initialization\n", id);
        fflush(stdout);
        uint32_t auroraMask[2] = {laneMask & 0xf, (laneMask >> 4) & 0xf};
        for (int i = 0; i < 2; i++) {
            while (true) {
                uint32_t status = sip_read<uint32_t>(aurora, 0x204 + i);
                assert(status != 0xFF);
                uint32_t channel_up = (status >> 20) & 0xf;
                uint32_t lane_up = (status >> 16) & 0xf;
                // Check that all enabled lane (rx) and channel (tx) lanes are up
                bool ready = ((lane_up & channel_up & auroraMask[i]) == auroraMask[i]);
                if (ready) break;
                usleep(10000);
            }
        }
        print_aurora_status();
    }

    void enable_aurora_lanes() {
        // Take quads out of reset, and enable only the lanes that are used
        sip_write<uint16_t>(aurora, 0x0200, (laneMask << 2) | 0b011);
    }
#endif

    void read_mem(uint8_t* buffer, size_t xfer_sz, size_t address) {
        transfer_mem<false>(buffer, xfer_sz, address);
    }

    void write_mem(uint8_t* buffer, size_t xfer_sz, size_t address) {
        // Break writes > 64MB in chunks. On a ~100MB transfer in stg3, I see:
        // [xrt][0] Writing 104917084 bytes at 0x80000000 to FPGA
        // terminate called after throwing an instance of 'xrt_core::system_error'
        //     what():  unable to sync BO: Input/output error
        // Unclear why; XRT docs say buffers of up to 4GB should be OK, maybe
        // it's a bug, maybe the host can't do DMAs this large, who knows.
        // Sticking to 64MB buffers fixes this, though.
        size_t max_sz = (1 << 24);
        if (xfer_sz > max_sz) {
            transfer_mem<true>(buffer, max_sz, address);
            write_mem(buffer + max_sz, xfer_sz - max_sz, address + max_sz);
        } else {
            transfer_mem<true>(buffer, xfer_sz, address);
        }
    }

    uint32_t read_reg(uint16_t addr) {
        return kernel.read_register(addr);
    }

    void write_reg(uint16_t addr, uint32_t data) {
        kernel.write_register(addr, data);
        usleep(100);
    }

    uint32_t get_id() const { return id; }
};

std::vector<XrtDevice*> devices;

FILE* remoteInputStream = nullptr;

std::vector<Device*> init(int argc, const char* argv[]) {
    const char* xclbinFileName = nullptr;
    std::vector<uint32_t> ids;
    std::vector<std::string> bdfs;

    const bool selectiveExecution = [&](){
        bool se = false;
        for (int i = 1; i < argc; i++) if (strcmp(argv[i], "-s") == 0) se = true;
        return se;
    }();

    uint32_t physicalStartId = 0;
    uint32_t logicalStartId = 0;


    // The remote-host path currently supports a single remote host.
    std::string remoteHost = "";
    uint32_t remoteIdx = -1;

    for (int i = 0; i < argc; i++) {
        if (strstr(argv[i], ".xclbin") != nullptr) {
            xclbinFileName = argv[i];
        }

        if (strstr(argv[i], "idMap=") != nullptr) {
            // Relies on these being a single digit in our case... e.g.,
            // idMap=4:0 means these are physical FPGAs 4+ in the network, but
            // that for simulation purposes, they must be treated as devices
            // 0-3.
            // This allows two cases:
            // - idMap=4:0 + 2 or 4 BDFs uses the port mappings of the second
            //   half of the network (i.e., the 4 FPGAs in stg4), but treats them
            //   as FPGAs 0-3. This allows setting the right port connections in
            //   stg4.
            // - idMap=4:4 + some BDFs uses the port mapping of the second
            //   half, but treats these FPGAs as 4+. This is useful when
            //   running with multiple FPGAs across machines.
            // - This supports many other mixes, e.g.,
            //     stg3: idMap=3:0 c1:00.1 + slave idMap=4:1 01:00.1
            //   would allow a 2-FPGA run with FPGAs 3 (last in stg3) and 4
            //   (first in stg4)
            assert(strlen(argv[i]) == 9);
            assert(bdfs.size() == 0);  // idMap must appear before any BDF
            physicalStartId = argv[i][6] - '0';
            logicalStartId = argv[i][8] - '0';
        }

        if (strstr(argv[i], ":00.1") != nullptr) {
            // Normalize BDF string by dropping optional prefix
            const char* bdf = argv[i];
            if (strstr(bdf, "0000:") == bdf) bdf = bdf + 5;
            bdfs.push_back(bdf);
            uint32_t id = ids.size() + logicalStartId;
            ids.push_back(id);
        }

        if (strstr(argv[i], "remote=") != nullptr) {
            remoteHost = (argv[i] + 7);
            remoteIdx = bdfs.size();
        }
    }
    if (!xclbinFileName) {
        printf("[xrt] fatal: xclbin not given in arguments (file name needs to contain .xclbin)\n");
        exit(-1);
    }

#if defined(TARGET_hw_emu)
    assert(bdfs.size() == 0);
    bdfs.push_back("0");
    ids.push_back(logicalStartId);
#endif

    if (!bdfs.size()) {
        printf("[xrt] fatal: device BDF(s) not given in arguments (e.g., 0000:01:00.1 or 01:00.1)\n");
        exit(-1);
    }

    network::setIdMap(physicalStartId, logicalStartId, MAX_DEVICES);
    //network::printTopology();

    if (remoteIdx != -1) {
        std::string remoteCmd = argv[0];
        if (selectiveExecution) {
            remoteCmd += " -s ";
        }
        remoteCmd += " " + std::string(xclbinFileName);
        remoteCmd += " idMap=" + std::to_string(remoteIdx) + ":" + std::to_string(ids[remoteIdx]);
        for (uint32_t i = remoteIdx; i < bdfs.size(); i++) {
            remoteCmd += " " + bdfs[i];
        }
        ids.resize(remoteIdx);
        bdfs.resize(remoteIdx);
        char curDir[4096];
        memset(curDir, sizeof(curDir)-1, 0);
        {
            auto res = getcwd(curDir, sizeof(curDir)-1);
            assert(res == curDir);
        }
        // remoteCmd = "cd " + std::string(curDir) + " && " + remoteCmd;

        // Wrap around ssh; this is very zsh-specific, but I need some way to replicate env vars, since this uses xbutil...
        remoteCmd = "ssh " + remoteHost + " -t 'zsh -l -c \"source ~/.zshrc && " + remoteCmd + "\"'";

        printf("REMOTE CMD: %s\n", remoteCmd.c_str());
        //exit(0);
        remoteInputStream = popen(remoteCmd.c_str(), "w");
        usleep(5 * 1000 * 1000); // give the remote enough lead to start; FIXME: janky, we should have RPCs...
    }

#if defined(TARGET_hw_emu)
    setenv("XCL_EMULATION_MODE", "hw_emu", 1 /*overwrite*/);
#else
    unsetenv("XCL_EMULATION_MODE");

    // First, grab permissions for all FPGAs
    // We keep FPGA locks under a folder inside tmp; this needs to be a
    // subfolder because we want world-writable files, and /tmp security
    // restrictions prevent this.
    struct stat lockDirStat = {0};
    if (stat("/tmp/fpga_locks", &lockDirStat) == -1) {
        int ret = mkdir("/tmp/fpga_locks", 0777);
        if (ret != 0) {
            printf("[xrt] ERROR: Cannot create lock directory\n");
            exit(-2);
        }
        // For some reason, mask is 0755 even if we specify 0777
        ret = chmod("/tmp/fpga_locks", 0777);
        assert(ret == 0);
    } else if ((lockDirStat.st_mode & 0777) != 0777) {
        printf("[xrt] ERROR: FPGA lock directory has wrong permissions %o\n", lockDirStat.st_mode);
        exit(-2);
    }

    for (auto bdf: bdfs) {
        std::string statusFile = "/tmp/fpga_locks/fpga." + bdf + ".lock";
        int fd = open(statusFile.c_str(), O_CREAT | O_RDWR, S_IRWXU | S_IRWXG | S_IRWXO);
        assert(fd > 0);  // dsm: This should not fail...
        int ret = flock(fd, LOCK_EX);
        assert(ret == 0);  // dsm; flock may block, but should eventually succed the way we're using it
        // Like the directory, chmod explicitly
        ret = fchmod(fd, 0777);
        //assert(ret == 0); // this may fail if the file was created by a different user, that's OK
        // First, read contents of file. These may either be empty, or point to a pid
        char buf[1024];
        memset(buf, 0, 1024);
        ssize_t bytes = read(fd, buf, sizeof(buf)-1);
        if (bytes) {
            int otherPid = atoi(buf);
            std::string psCmd = "ps -u -p " + std::to_string(otherPid);
            FILE* psf = popen(psCmd.c_str(), "r");
            size_t psOutBytes = fread(buf, sizeof(char), sizeof(buf)-1, psf);
            int psRet = pclose(psf);
            if (psRet != 0) {
                printf("[xrt] Acquiring FPGA %s (it was last used by pid %d, but it's not running anymore)\n", bdf.c_str(), otherPid);
            } else {
                printf("[xrt] ERROR: Cannot acquire FPGA %s, it's used by running pid %d:\n%s", bdf.c_str(), otherPid, buf);
                exit(-2);
            }
        } else {
            printf("[xrt] Acquiring FPGA %s (unused by a prior process)\n", bdf.c_str());
        }
        lseek(fd, 0, SEEK_SET);
        dprintf(fd, "%d\n", getpid());
        ret = flock(fd, LOCK_UN);
        assert(ret == 0);
        close(fd);
    }
#endif

    devices.resize(ids.size());

    omp_set_num_threads(ids.size());

    #pragma omp parallel for
    for (uint32_t i = 0; i < ids.size(); i++) {
        XrtDevice* d = new XrtDevice(ids[i], bdfs[i], xclbinFileName);
        devices[i] = d;
    }

    std::vector<Device*> res;
    for (auto d : devices) res.push_back(d);
    return res;
}

void wait_for_cross_device_links() {
#if MULTI_DEVICE
    printf("\n[xrt] Aurora wait_for_aurora_init\n");
    fflush(stdout);
    for (auto d: devices) {
        d->wait_for_aurora_init();
    }
    printf("\n[xrt] Aurora global status\n");
    fflush(stdout);
    for (auto d: devices) {
        d->print_aurora_status();
        d->print_aurora_counters();
    }
    usleep(1*1000*1000);
    printf("\n[xrt] Enabling Aurora RX lanes\n");
    fflush(stdout);
    for (auto d: devices) {
        d->enable_aurora_lanes();
    }
    fflush(stdout);
    usleep(3*1000*1000);
    for (auto d: devices) {
        d->print_aurora_counters();
        d->print_aurora_status();
    }

#endif
}

void fini() {
#if MULTI_DEVICE
    for (auto d: devices) {
        d->print_aurora_counters();
    }
#endif

    if (remoteInputStream) {
        fprintf(remoteInputStream, "\n\n\n");
        fflush(remoteInputStream);
        usleep(1000 * 1000);
        pclose(remoteInputStream);
    }

    fflush(stdout);
}
};
