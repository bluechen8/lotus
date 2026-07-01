/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

////////////////////////// PACK/UNPACK UTIL

#include <bit>
#include <array>
#include <cstdint>
#include <type_traits>
#include <cassert>
#include <cstddef>
#include <utility>
#include <cstring>
#include <tuple>

template<class T>
constexpr T unpack_from_u32(std::uint32_t v, unsigned byte_off = 0) noexcept {
    static_assert(std::is_trivially_copyable_v<T>, "T must be trivially copyable");
    constexpr std::size_t N = sizeof(T);
    static_assert(N >= 1 && N <= 4, "T must be 1..4 bytes");
    assert(byte_off + N <= 4);

    if constexpr (N == 1) {
        std::uint8_t part = static_cast<std::uint8_t>(v >> (byte_off * 8));
        return std::bit_cast<T>(part);
    } else if constexpr (N == 2) {
        std::uint16_t part = static_cast<std::uint16_t>(v >> (byte_off * 8));
        return std::bit_cast<T>(part);
    } else if constexpr (N == 4) {
        // must be byte_off == 0 due to the assert above
        return std::bit_cast<T>(v);
    } else { // N == 3 (or odd sizes up to 4)
        std::array<std::byte, N> b{};
        for (std::size_t i = 0; i < N; ++i)
            b[i] = std::byte((v >> ((byte_off + i) * 8)) & 0xFFu);
        return std::bit_cast<T>(b);
    }
}

template<class T>
constexpr void pack_into_u32(std::uint32_t& v, const T& obj, unsigned byte_off = 0) noexcept {
    static_assert(std::is_trivially_copyable_v<T>, "T must be trivially copyable");
    constexpr std::size_t N = sizeof(T);
    static_assert(N >= 1 && N <= 4, "T must be 1..4 bytes");
    assert(byte_off + N <= 4);

    std::uint32_t bits = 0, mask = 0;
    if constexpr (N == 1) {
        std::uint8_t part = std::bit_cast<std::uint8_t>(obj);
        bits = (std::uint32_t)part << (byte_off * 8);
        mask = 0xFFu << (byte_off * 8);
    } else if constexpr (N == 2) {
        std::uint16_t part = std::bit_cast<std::uint16_t>(obj);
        bits = (std::uint32_t)part << (byte_off * 8);
        mask = 0xFFFFu << (byte_off * 8);
    } else if constexpr (N == 4) {
        std::uint32_t part = std::bit_cast<std::uint32_t>(obj);
        bits = part; mask = 0xFFFFFFFFu; // byte_off==0 due to assert
    } else { // N == 3 etc.
        auto bytes = std::bit_cast<std::array<std::byte, N>>(obj);
        for (std::size_t i = 0; i < N; ++i) {
            bits |= (std::uint32_t)std::to_integer<std::uint8_t>(bytes[i]) << ((byte_off + i) * 8);
            mask |= 0xFFu << ((byte_off + i) * 8);
        }
    }
    v = (v & ~mask) | bits;
}

template <std::size_t DST_OFF, std::size_t SRC_OFF, std::size_t LEN, class Dst>
constexpr inline void move_bytes(Dst& dst, uint32_t src) noexcept {
    static_assert(LEN >= 1 && LEN <= 4, "LEN 1..4");
    static_assert(SRC_OFF + LEN <= 4,   "src range OOB");
    static_assert(DST_OFF + LEN <= sizeof(Dst), "dst range OOB");
    static_assert(std::is_trivially_copyable_v<Dst>, "Dst must be trivially copyable");

    auto* p = reinterpret_cast<unsigned char*>(std::addressof(dst)) + DST_OFF;
    uint32_t slice = (src >> (8 * SRC_OFF));
    if constexpr (LEN < 4) slice &= (uint32_t(1) << (8 * LEN)) - 1u;

    // Fast paths when the TYPE is known aligned
    if constexpr (LEN == 4 && (DST_OFF % 4 == 0) && (alignof(Dst) >= 4)) {
        std::memcpy(p, &slice, 4);                  // -> sw
    } else if constexpr (LEN == 2 && (DST_OFF % 2 == 0) && (alignof(Dst) >= 2)) {
        uint16_t v16 = static_cast<uint16_t>(slice);
        std::memcpy(p, &v16, 2);                    // -> sh
    } else if constexpr (LEN == 3 && (DST_OFF % 4 == 0) && (alignof(Dst) >= 4)) {
        uint32_t word;
        std::memcpy(&word, p, 4);                   // -> lw
        word = (word & 0xFF000000u) | slice;
        std::memcpy(p, &word, 4);                   // -> sw
    } else if constexpr (LEN == 3 && (DST_OFF % 2 == 0) && (alignof(Dst) >= 2)) {
        uint16_t lo16 = static_cast<uint16_t>(slice);
        uint8_t  hi8  = static_cast<uint8_t>(slice >> 16);
        std::memcpy(p, &lo16, 2);                   // -> sh
        std::memcpy(p + 2, &hi8, 1);                // -> sb
    } else {
        // Fallback: byte stores (safe for any alignment)
        if constexpr (LEN >= 1) p[0] = static_cast<uint8_t>(slice);
        if constexpr (LEN >= 2) p[1] = static_cast<uint8_t>(slice >> 8);
        if constexpr (LEN >= 3) p[2] = static_cast<uint8_t>(slice >> 16);
        if constexpr (LEN >= 4) p[3] = static_cast<uint8_t>(slice >> 24);
    }
}

template <std::size_t DST_OFF, std::size_t SRC_OFF, std::size_t LEN, class Src>
constexpr inline void move_bytes_to_u32(uint32_t& dst /* zeroed, no overlap */, const Src& src) noexcept {
    static_assert(LEN >= 1 && LEN <= 4, "LEN 1..4");
    static_assert(DST_OFF + LEN <= 4,   "dst range OOB");
    static_assert(SRC_OFF + LEN <= sizeof(Src), "src range OOB");
    static_assert(std::is_trivially_copyable_v<Src>, "Src must be trivially copyable");

    const auto* p = reinterpret_cast<const unsigned char*>(std::addressof(src)) + SRC_OFF;

    uint32_t v = 0;
    if constexpr (LEN == 4 && (SRC_OFF % 4 == 0) && (alignof(Src) >= 4)) {
        std::memcpy(&v, p, 4);                      // -> lw
    } else if constexpr (LEN == 3 && (SRC_OFF % 4 == 0) && (alignof(Src) >= 4)) {
        std::memcpy(&v, p, 4); v &= 0x00FFFFFFu;    // -> lw + mask
    } else if constexpr (LEN == 2 && (SRC_OFF % 2 == 0) && (alignof(Src) >= 2)) {
        uint16_t t; std::memcpy(&t, p, 2); v = t;   // -> lh
    } else if constexpr (LEN == 3 && (SRC_OFF % 2 == 0) && (alignof(Src) >= 2)) {
        uint16_t lo; uint8_t hi;
        std::memcpy(&lo, p, 2); std::memcpy(&hi, p+2, 1);
        v = static_cast<uint32_t>(lo) | (uint32_t(hi) << 16);
    } else {
        // Fallback: byte loads
        if constexpr (LEN >= 1) v |= uint32_t(p[0]);
        if constexpr (LEN >= 2) v |= uint32_t(p[1]) << 8;
        if constexpr (LEN >= 3) v |= uint32_t(p[2]) << 16;
        if constexpr (LEN >= 4) v |= uint32_t(p[3]) << 24;
    }

    if constexpr (LEN == 4 && DST_OFF == 0) {
        dst = v;                                    // dst was zeroed
    } else {
        if constexpr (LEN < 4) v &= (uint32_t(1) << (8 * LEN)) - 1u;
        dst |= (v << (8 * DST_OFF));
    }
}


////////////////////////// LOTUS

namespace lotus {
    inline void simFail() {
#ifdef __riscv
        asm volatile("addi x0, x0, 3\n\t");
#else
        assert(false && "simFail");
#endif
    }
};

#define ARG_QUAL_IN    const
#define ARG_QUAL_OUT
#define ARG_QUAL_INOUT

#define ARG(ARG_TYPE, ACCESS_TYPE, TYPE) ARG_QUAL_##ARG_TYPE TYPE&

#define ARG_UNPAREN_HELPER(...) __VA_ARGS__

#define ARG_UNPAREN(ARG_TYPE, ACCESS_TYPE, TYPE) ARG_QUAL_##ARG_TYPE ARG_UNPAREN_HELPER TYPE&


// Args are 32-bit inputs
typedef unsigned int Word;
typedef unsigned long long DWord;

#define WORD_BITS (32)

// dsm: Same kludge as in verilated_funcs.h: For riscv, neither clang nor gcc
// inline, which produces terrible code when calling these due to the use of
// pointers. So force inlining!
#define __INLINE_ATTR__ inline __attribute__((always_inline))

#define TASK __INLINE_ATTR__ void
