// XXH3-64, seed 0, default secret: the chunk checksum of Enshrouded's save container
// (client +0xF830A0 -> +0x737C00, build 1273043). Scalar port of the reference algorithm
// (xxHash 0.8, BSD-2-Clause, Yann Collet); the same code as research/scripts/xxh3.ps1,
// which matches all 39 chunk checksums of four real saves. zstd's bundled xxhash.h cannot
// be used: its local adaptation switches XXH3 off unconditionally.
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <intrin.h>

namespace xxh3 {

// The game's secret (client RVA 0x1697A40); identical to the reference kSecret.
inline constexpr uint8_t kSecret[192] = {
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
};

namespace detail {
constexpr uint64_t P32_1 = 0x9E3779B1ull, P32_2 = 0x85EBCA77ull, P32_3 = 0xC2B2AE3Dull;
constexpr uint64_t P64_1 = 0x9E3779B185EBCA87ull, P64_2 = 0xC2B2AE3D27D4EB4Full, P64_3 = 0x165667B19E3779F9ull,
                   P64_4 = 0x85EBCA77C2B2AE63ull, P64_5 = 0x27D4EB2F165667C5ull;
constexpr uint64_t MX1 = 0x165667919E3779F9ull, MX2 = 0x9FB21C651E98DF25ull;

inline uint64_t r64(const uint8_t* p) { uint64_t v; std::memcpy(&v, p, 8); return v; }
inline uint32_t r32(const uint8_t* p) { uint32_t v; std::memcpy(&v, p, 4); return v; }
inline uint64_t rotl(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
inline uint64_t fold(uint64_t a, uint64_t b) { uint64_t hi; uint64_t lo = _umul128(a, b, &hi); return lo ^ hi; }
inline uint64_t avalanche(uint64_t h) { h ^= h >> 37; h *= MX1; h ^= h >> 32; return h; }
inline uint64_t xxh64_avalanche(uint64_t h) { h ^= h >> 33; h *= P64_2; h ^= h >> 29; h *= P64_3; h ^= h >> 32; return h; }
inline uint64_t rrmxmx(uint64_t h, uint64_t len) {
    h ^= rotl(h, 49) ^ rotl(h, 24); h *= MX2; h ^= (h >> 35) + len; h *= MX2; h ^= h >> 28; return h;
}
inline uint64_t mix16(const uint8_t* in, const uint8_t* s) { return fold(r64(in) ^ r64(s), r64(in + 8) ^ r64(s + 8)); }
inline void acc512(uint64_t* acc, const uint8_t* in, const uint8_t* s) {
    for (int k = 0; k < 8; ++k) {
        uint64_t v = r64(in + 8 * k), key = v ^ r64(s + 8 * k);
        acc[k ^ 1] += v;
        acc[k] += (key & 0xFFFFFFFFull) * (key >> 32);
    }
}
inline void scramble(uint64_t* acc, const uint8_t* s) {
    for (int k = 0; k < 8; ++k) { uint64_t a = acc[k]; a ^= a >> 47; a ^= r64(s + 8 * k); a *= P32_1; acc[k] = a; }
}
}  // namespace detail

inline uint64_t hash64(const void* data, size_t len) {
    using namespace detail;
    const uint8_t* in = static_cast<const uint8_t*>(data);
    const uint8_t* s = kSecret;
    const uint64_t L = len;
    if (len <= 16) {
        if (len > 8) {
            uint64_t lo = r64(in) ^ (r64(s + 24) ^ r64(s + 32));
            uint64_t hi = r64(in + len - 8) ^ (r64(s + 40) ^ r64(s + 48));
            return avalanche(L + _byteswap_uint64(lo) + hi + fold(lo, hi));
        }
        if (len >= 4) {
            uint64_t v = static_cast<uint64_t>(r32(in + len - 4)) + (static_cast<uint64_t>(r32(in)) << 32);
            return rrmxmx(v ^ (r64(s + 8) ^ r64(s + 16)), L);
        }
        if (len > 0) {
            uint32_t c = (static_cast<uint32_t>(in[0]) << 16) | (static_cast<uint32_t>(in[len >> 1]) << 24) |
                         in[len - 1] | (static_cast<uint32_t>(len) << 8);
            return xxh64_avalanche(static_cast<uint64_t>(c ^ (r32(s) ^ r32(s + 4))));
        }
        return xxh64_avalanche(r64(s + 56) ^ r64(s + 64));
    }
    if (len <= 128) {
        uint64_t acc = L * P64_1;
        if (len > 32) {
            if (len > 64) {
                if (len > 96) { acc += mix16(in + 48, s + 96); acc += mix16(in + len - 64, s + 112); }
                acc += mix16(in + 32, s + 64); acc += mix16(in + len - 48, s + 80);
            }
            acc += mix16(in + 16, s + 32); acc += mix16(in + len - 32, s + 48);
        }
        acc += mix16(in, s); acc += mix16(in + len - 16, s + 16);
        return avalanche(acc);
    }
    if (len <= 240) {
        uint64_t acc = L * P64_1;
        size_t rounds = len / 16;
        for (size_t i = 0; i < 8; ++i) acc += mix16(in + 16 * i, s + 16 * i);
        acc = avalanche(acc);
        for (size_t i = 8; i < rounds; ++i) acc += mix16(in + 16 * i, s + 16 * (i - 8) + 3);
        acc += mix16(in + len - 16, s + 136 - 17);
        return avalanche(acc);
    }
    uint64_t acc[8] = {P32_3, P64_1, P64_2, P64_3, P64_4, P32_2, P64_5, P32_1};
    constexpr size_t kSecretSize = sizeof(kSecret), kStripes = (kSecretSize - 64) / 8, kBlock = 64 * kStripes;
    size_t blocks = (len - 1) / kBlock;
    for (size_t n = 0; n < blocks; ++n) {
        for (size_t st = 0; st < kStripes; ++st) acc512(acc, in + n * kBlock + st * 64, s + st * 8);
        scramble(acc, s + kSecretSize - 64);
    }
    size_t stripes = ((len - 1) - kBlock * blocks) / 64;
    for (size_t st = 0; st < stripes; ++st) acc512(acc, in + blocks * kBlock + st * 64, s + st * 8);
    acc512(acc, in + len - 64, s + kSecretSize - 64 - 7);
    uint64_t r = L * P64_1;
    for (int i = 0; i < 4; ++i) r += fold(acc[2 * i] ^ r64(s + 11 + 16 * i), acc[2 * i + 1] ^ r64(s + 11 + 16 * i + 8));
    return avalanche(r);
}

}  // namespace xxh3
