/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#pragma once

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <vector>
#include <array>
#include <tuple>
#include <cassert>
#include <map>

// Interface to Lotus hardware
// Allows for different implementations (e.g., XRT, verilator, AWS)
namespace hw {

#ifndef LOG2_MAX_DEVICES
#define LOG2_MAX_DEVICES (0)
#endif
#define MAX_DEVICES (1<<LOG2_MAX_DEVICES)

#define MULTI_DEVICE (LOG2_MAX_DEVICES > 0)

#define DEBUG(args...) // printf(args)
#define TRACE(args...) // printf(args)

// An FPGA device (possibly emulated)
class Device {
  public:
    // General/base interfaces
    virtual void read_mem(uint8_t* buffer, size_t bytes, size_t address) = 0;
    virtual void write_mem(uint8_t* buffer, size_t bytes, size_t address) = 0;

    virtual uint32_t read_reg(uint16_t addr) = 0;
    virtual void write_reg(uint16_t addr, uint32_t data) = 0;

  private:
    bool feedSipToStream = false;
    std::vector<uint8_t> sipStream;
    std::vector<uint8_t> sipStreamPrefix;

    inline uint32_t sip_feeder_single(const std::vector<uint8_t>& bytes, uint32_t currI) {

      DEBUG("sip_feeder_single<N=%d>(currI=%d)\n", N, currI);

      const uint32_t bytesLeft = bytes.size() - currI;
      const uint32_t bytesSend = std::min(bytesLeft, static_cast<uint32_t>(5));
      assert(bytesSend > 0);

      // +1 if not the last message
      uint32_t protoSize = bytesSend + (bytesSend != bytesLeft);

      auto take_byte = [&bytes](uint32_t ci, uint32_t bytesSendLeft) -> std::tuple<bool, uint32_t, uint32_t, uint8_t> {
        if (bytesSendLeft > 0) {
          DEBUG("take_byte, ci=%d\tbytesSendLeft=%d, byte=%d\n", ci, bytesSendLeft, bytes[ci]);
          assert(ci < bytes.size());
          return std::make_tuple(true, ci+1, bytesSendLeft-1, bytes[ci]);
        } else {
          DEBUG("take_byte, ci=%d\tbytesSendLeft=%d, byte=XX\n", ci, bytesSendLeft);
          assert(ci == bytes.size());
          return std::make_tuple(false, ci, 0, 0);
        }
      };

      DEBUG("bytesLeft=%d\tbytesSend=%d\tprotoSize=%d\n", bytesLeft, bytesSend, protoSize);

      auto state = take_byte(currI, bytesSend);
      assert(std::get<0>(state) == true);
      uint16_t addrSend = ((std::get<3>(state) & 0xff) << 8) | ((protoSize & 0xf) << 4) | (0);

      uint32_t dataSend = 0;
      for (uint32_t currDataByte = 0; currDataByte < 4; currDataByte++) {
        state = take_byte(std::get<1>(state), std::get<2>(state));
        if (std::get<0>(state)) {
          uint8_t byteToSend = std::get<3>(state);
          dataSend = dataSend | (byteToSend << (currDataByte*8));
        }
      }
      write_reg(addrSend, dataSend);
      return std::get<1>(state);
    }

    inline void sip_feeder(const std::vector<uint8_t>& bytes) {
      assert(bytes.size() > 0);
      assert(bytes.size() <= 8);

      if (!feedSipToStream) {
        uint32_t currI = 0;
        while (currI != bytes.size()) {
          currI = sip_feeder_single(bytes, currI);
        }
      } else {
        assert(bytes.size() > sipStreamPrefix.size());
        for (size_t n = 0; n < sipStreamPrefix.size(); n++) {
            // If this fails, the prefix does not match the packet you're
            // feeding; all reqs in a stream must have the prefix
            assert(sipStreamPrefix[n] == bytes[n]);
        }
        sipStream.push_back((uint8_t) (bytes.size() - sipStreamPrefix.size()));
        for (size_t n = sipStreamPrefix.size(); n < bytes.size(); n++) {
            sipStream.push_back(bytes[n]);
        }
      }
    }
    template<typename T>
    inline T sip_getter() {
      assert(sizeof(T) > 0);
      assert(sizeof(T) <= 8);

      uint32_t respBytes = read_reg(0x10);

      // NOTE(farese): We don't give warnings if it's less than
      //               since that's a common thing for like 40-bit reads
      if (respBytes > sizeof(T)) {
          printf("ERROR: respBytes (%d, 0x%x) != respSize (%ld)\n", respBytes, respBytes, sizeof(T));
          respBytes = sizeof(T);
          assert(false);
      }

      uint8_t buf[sizeof(T)];
      memset(buf, 0, sizeof(T));
      for (size_t curBytes = 0; curBytes < respBytes; curBytes += 4) {
          size_t xferSize = std::min(respBytes-curBytes, 4ul);
          uint32_t data = read_reg(0x200 + curBytes);
          memcpy(&buf[curBytes], &data, xferSize);
      }
      T res;
      memcpy(&res, buf, sizeof(T));
      return res;
    }

    // Maintains <addr, value> pairs with the last write
    std::map<std::vector<uint8_t>, std::vector<uint8_t>> writeCache;
  public:

    template<typename T>
    inline void write_sip_reg(std::vector<uint8_t> addrs, T data) {
        TRACE("write_sip_reg addrs= {");
        for (const auto& a : addrs) TRACE("%d, ", a);
        TRACE("} data=%lu\n", static_cast<uint64_t>(data));
        constexpr uint32_t dataBytes  = sizeof(data);
        uint32_t totalBytes = addrs.size() + sizeof(data);

        std::array<uint8_t, dataBytes> dataVec;
        for (int b = 0; b < dataBytes; b++) {
          dataVec[b] = (data >> (b*8)) & 0xff;
        }

        std::vector<uint8_t> allBytes;
        allBytes.resize(totalBytes);
        std::copy(addrs.begin()  , addrs.end(), allBytes.begin());
        std::copy(dataVec.begin(), dataVec.end(), allBytes.begin() + addrs.size());

        sip_feeder(allBytes);
    }

    // Locally caches writes, and skips every write to the same register that
    // has the same value. Useful when a control register often uses the same
    // value over and over again (e.g., during configuration).
    template<typename T>
    inline void write_sip_reg_cached(std::vector<uint8_t> addrs, T data) {
        std::vector<uint8_t> dataVec;
        for (int b = 0; b < sizeof(data); b++) {
            dataVec.push_back((data >> (b*8)) & 0xff);
        }
        auto it = writeCache.find(addrs);
        if (it == writeCache.end() || it->second != dataVec) {
            // Miss, actually do the write
            write_sip_reg(addrs, data);
            writeCache[addrs] = dataVec;
        } // else hit, nothing to do
    }

    template<typename T>
    inline T read_sip_reg(const std::vector<uint8_t>& addrs) {
        TRACE("read_sip_reg addrs= {");
        for (const auto& a : addrs) TRACE("%d, ", a);
        TRACE("}\n");
        sip_feeder(addrs);
        return sip_getter<T>();
    }

    inline void start_sip_stream(const std::vector<uint8_t>& prefix) {
        assert(!feedSipToStream);
        feedSipToStream = true;
        sipStream.clear();
        sipStreamPrefix.clear();
        for (auto b: prefix) sipStreamPrefix.push_back(b);
    }

    inline std::vector<uint8_t> end_sip_stream() {
        assert(feedSipToStream);
        feedSipToStream = false;
        sipStream.push_back(128); // termination byte
        return std::move(sipStream);
    }

    virtual void enable_cross_device_links(const std::vector<uint32_t>& srcPorts) {}

    virtual uint32_t get_id() const = 0;
};


// Initializes internal state and interface; must be called before any other
// function in this namespace
std::vector<Device*> init(int argc, const char* argv[]);

// Waits for cross-device links, if needed; call before starting execution
void wait_for_cross_device_links();

// Finalizes use of interface/devices; call before finishing execution
void fini(void);

};
