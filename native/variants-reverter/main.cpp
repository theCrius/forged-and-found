// variants-reverter: turns Forged & Found items in an Enshrouded save back into the
// vanilla items they were made from, so the mod can be switched off without the game
// deleting them (an unknown ItemId is dropped silently on load).
//
// Save format (game build 1273043, research/save-format.md): an "SV2C" container of
// "S2BH" chunks plus a directory whose per-chunk checksum is the low 32 bits of XXH3-64
// over the chunk's stored bytes. Changed chunks keep their compression flag (the chunk
// readers do not all honour the compression flag, so a compressed chunk is rewritten as a
// zstd frame of stored blocks); every other chunk is copied byte for byte.
//
// Usage: variants-reverter <save.ksd> [--map <variant-map.txt>] [--out <file>]
// Without --out it only reports. The input file is never modified.
//
// Third-party code: zstd (BSD, Meta Platforms) for decompression, license in
// native/third_party/zstd/LICENSE; XXH3 ported from xxHash (BSD-2-Clause) in xxh3.h.

#include "../third_party/zstd/zstd.h"
#include "../third_party/zstd/zstd_errors.h"
#include "xxh3.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr const char* kVersion = "0.2.1";

using Bytes = std::vector<uint8_t>;

uint32_t rd32(const uint8_t* p) { uint32_t v; std::memcpy(&v, p, 4); return v; }
uint16_t rd16(const uint8_t* p) { uint16_t v; std::memcpy(&v, p, 2); return v; }
void wr32(uint8_t* p, uint32_t v) { std::memcpy(p, &v, 4); }

uint32_t checksum(const uint8_t* p, size_t n) { return static_cast<uint32_t>(xxh3::hash64(p, n)); }

struct Entry {
    std::string name;
    uint32_t offset, size, hash;
    size_t at;  // file offset of the directory entry
};

struct Container {
    Bytes data;
    std::vector<Entry> entries;
    size_t dir;  // file offset of the directory (entries, then names, up to the end)
};

bool fail(const std::string& why) { std::fprintf(stderr, "error: %s\n", why.c_str()); return false; }

// The same checks as the game's validator (+0x102B750, "[savedata2] ...").
bool parse(Container& c) {
    const Bytes& d = c.data;
    if (d.size() < 0x30) return fail("file smaller than the 0x30-byte header");
    if (std::memcmp(d.data(), "SV2C", 4) != 0) return fail("not a save container (magic is not SV2C)");
    if (rd16(&d[4]) != 2) return fail("container version is not 2");
    if (rd16(&d[6]) != 0x30) return fail("header size is not 0x30");
    if (rd32(&d[8]) != d.size()) return fail("stored file size does not match the file");
    int32_t rel = static_cast<int32_t>(rd32(&d[0x28]));
    uint32_t count = rd32(&d[0x2C]);
    if (count == 0 || count > 0x100) return fail("implausible chunk count");
    c.dir = static_cast<size_t>(0x28 + static_cast<int64_t>(rel));
    if (c.dir + count * 20ull > d.size()) return fail("directory outside the file");
    for (uint32_t i = 0; i < count; ++i) {
        size_t at = c.dir + i * 20ull;
        Entry e;
        e.at = at;
        int32_t nrel = static_cast<int32_t>(rd32(&d[at]));
        uint32_t nlen = rd32(&d[at + 4]);
        size_t nat = static_cast<size_t>(static_cast<int64_t>(at) + nrel);
        if (nlen > 0x1F || nat + nlen > d.size()) return fail("bad chunk name in directory");
        e.name.assign(reinterpret_cast<const char*>(&d[nat]), nlen);
        e.offset = rd32(&d[at + 8]);
        e.size = rd32(&d[at + 12]);
        e.hash = rd32(&d[at + 16]);
        if (e.offset < 0x30 || static_cast<uint64_t>(e.offset) + e.size > c.dir) return fail("chunk outside the data area: " + e.name);
        if (checksum(&d[e.offset], e.size) != e.hash) return fail("checksum mismatch in chunk " + e.name + " (file damaged or not from this game version)");
        if (e.size < 14 || std::memcmp(&d[e.offset], "S2BH", 4) != 0) return fail("chunk " + e.name + " does not start with S2BH");
        c.entries.push_back(e);
    }
    for (size_t i = 1; i < c.entries.size(); ++i)
        if (c.entries[i].offset != c.entries[i - 1].offset + c.entries[i - 1].size)
            return fail("chunks are not stored back to back (layout not seen before)");
    return true;
}

// Chunk header: "S2BH", u32 version, u8 kind, u8 compression, u32 content version.
bool payload(const Container& c, const Entry& e, Bytes& out) {
    const uint8_t* p = &c.data[e.offset];
    uint8_t comp = p[9];
    if (rd32(p + 4) != 2) return fail("chunk " + e.name + ": header version is not 2");
    const uint8_t* body = p + 14;
    size_t n = e.size - 14;
    if (comp == 0) { out.assign(body, body + n); return true; }
    if (comp != 1) return fail("chunk " + e.name + ": unknown compression");
    size_t frame = ZSTD_findFrameCompressedSize(body, n);
    if (ZSTD_isError(frame) || frame != n) return fail("chunk " + e.name + ": not exactly one zstd frame");
    size_t cap = n * 8 + 4096;
    for (;;) {
        out.resize(cap);
        size_t r = ZSTD_decompress(out.data(), cap, body, n);
        if (!ZSTD_isError(r)) { out.resize(r); return true; }
        if (ZSTD_getErrorCode(r) != ZSTD_error_dstSize_tooSmall || cap > (512u << 20)) return fail("chunk " + e.name + ": zstd error");
        cap *= 4;
    }
}

// A zstd frame that stores the data uncompressed (raw blocks), in the game's own frame
// style: single segment with the content size in the header, no checksum, no dictionary
// (descriptor 0x60 for 256..65791 bytes). Changed chunks keep their compression flag,
// because not every reader honours it: the entity-chunk reader always decompresses
// (a raw entity_chunk00 failed with "Unknown frame descriptor", 2026-11-01).
Bytes zstd_store(const Bytes& data) {
    Bytes f = {0x28, 0xB5, 0x2F, 0xFD};
    size_t n = data.size();
    if (n < 256) {
        f.push_back(0x20);  // FCS flag 0 + single segment: 1-byte content size
        f.push_back(static_cast<uint8_t>(n));
    } else if (n <= 65535 + 256) {
        f.push_back(0x60);  // FCS flag 1: 2-byte content size minus 256
        uint16_t v = static_cast<uint16_t>(n - 256);
        f.push_back(static_cast<uint8_t>(v));
        f.push_back(static_cast<uint8_t>(v >> 8));
    } else {
        f.push_back(0xA0);  // FCS flag 2: 4-byte content size
        uint8_t v[4];
        wr32(v, static_cast<uint32_t>(n));
        f.insert(f.end(), v, v + 4);
    }
    constexpr size_t kMaxBlock = 128 * 1024;
    size_t pos = 0;
    do {
        size_t len = n - pos < kMaxBlock ? n - pos : kMaxBlock;
        bool last = pos + len == n;
        uint32_t hdr = (static_cast<uint32_t>(len) << 3) | (0u << 1) | (last ? 1u : 0u);  // block type 0 = raw
        f.push_back(static_cast<uint8_t>(hdr));
        f.push_back(static_cast<uint8_t>(hdr >> 8));
        f.push_back(static_cast<uint8_t>(hdr >> 16));
        f.insert(f.end(), data.begin() + pos, data.begin() + pos + len);
        pos += len;
    } while (pos < n);
    return f;
}

// player_character item record: [u8 slot][u32 itemId][u16 count][u8 flags] + optional
// fields per flag bit: 0x01 level (1), 0x02 durability cur/max (8), 0x10 rarity+1 and one
// byte (2), 0x20 gem socket (5). Other bits were never seen, so they are refused.
struct Record { size_t start, end; uint8_t slot, flags, level, rarity; uint16_t count; uint32_t dur, dur_max; };

bool record_at(const Bytes& b, size_t id_at, Record& r) {
    if (id_at < 1 || id_at + 7 > b.size()) return false;
    r.start = id_at - 1;
    r.slot = b[r.start];
    r.count = rd16(&b[id_at + 4]);
    r.flags = b[id_at + 6];
    if (r.flags & ~0x33u) return false;
    if (r.count == 0 && r.flags != 0) return false;
    size_t p = id_at + 7;
    r.level = r.rarity = 0;
    r.dur = r.dur_max = 0;
    if (r.flags & 0x01) { if (p + 1 > b.size()) return false; r.level = b[p]; p += 1; }
    if (r.flags & 0x02) {
        if (p + 8 > b.size()) return false;
        r.dur = rd32(&b[p]); r.dur_max = rd32(&b[p + 4]); p += 8;
        if (r.dur_max == 0 || r.dur > r.dur_max || r.dur_max > 100000) return false;
    }
    if (r.flags & 0x10) { if (p + 2 > b.size()) return false; r.rarity = b[p]; p += 2; if (r.rarity < 1 || r.rarity > 5) return false; }
    if (r.flags & 0x20) { if (p + 5 > b.size()) return false; p += 5; }
    r.end = p;
    return true;
}

const char* rarity_name(uint8_t stored) {
    static const char* names[] = {"?", "Common", "Uncommon", "Rare", "Epic", "Legendary"};
    return stored <= 5 ? names[stored] : "?";
}

std::vector<size_t> find_ids(const Bytes& b, const std::unordered_map<uint32_t, uint32_t>& map) {
    std::vector<size_t> at;
    for (size_t i = 0; i + 4 <= b.size(); ++i)
        if (map.count(rd32(&b[i]))) at.push_back(i);
    return at;
}

bool load_map(const std::string& path, std::unordered_map<uint32_t, uint32_t>& map, std::map<uint32_t, std::string>& names) {
    std::ifstream f(path);
    if (!f) return fail("cannot open variant map " + path);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        uint32_t variant = 0, original = 0;
        std::string name;
        if (!(s >> variant >> original)) return fail("bad line in variant map: " + line);
        std::getline(s >> std::ws, name);
        map[variant] = original;
        names[variant] = name;
    }
    if (map.empty()) return fail("variant map is empty");
    return true;
}

std::string exe_dir(const char* argv0) {
    std::string p(argv0);
    size_t s = p.find_last_of("\\/");
    return s == std::string::npos ? std::string(".") : p.substr(0, s);
}

}  // namespace

int main(int argc, char** argv) {
    std::printf("variants-reverter %s\n", kVersion);
    std::string in, out, map_path = exe_dir(argv[0]) + "\\variant-map.txt";
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--out" && i + 1 < argc) out = argv[++i];
        else if (a == "--map" && i + 1 < argc) map_path = argv[++i];
        else if (in.empty() && a[0] != '-') in = a;
        else { std::fprintf(stderr, "usage: variants-reverter <save.ksd> [--map <variant-map.txt>] [--out <file>]\n"); return 2; }
    }
    if (in.empty()) { std::fprintf(stderr, "usage: variants-reverter <save.ksd> [--map <variant-map.txt>] [--out <file>]\n"); return 2; }

    std::unordered_map<uint32_t, uint32_t> map;
    std::map<uint32_t, std::string> names;
    if (!load_map(map_path, map, names)) return 1;
    std::printf("variant map: %zu variants (%s)\n", map.size(), map_path.c_str());

    Container c;
    {
        std::ifstream f(in, std::ios::binary);
        if (!f) { std::fprintf(stderr, "error: cannot open %s\n", in.c_str()); return 1; }
        c.data.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    if (!parse(c)) return 1;
    std::printf("%s: %zu bytes, %zu chunks, all checksums valid\n", in.c_str(), c.data.size(), c.entries.size());

    // Chunks whose item records are converted, with the content version they were decoded
    // from: the character's own items, and world entities (storage chests, pedestals and
    // mannequins are inventories of entities in entity_chunkNN). Knowledge chunks are left
    // alone: the game drops unknown ids from them on its next save (tested 2026-11-01).
    const std::set<std::string> knowledge = {"player_knowledge", "world_knowledge"};
    auto convertible = [](const std::string& name, uint32_t& version) {
        if (name == "player_character") { version = 5; return true; }
        if (name.rfind("entity_chunk", 0) == 0) { version = 21; return true; }
        return false;
    };
    std::map<size_t, Bytes> rewritten;  // entry index -> new stored chunk bytes
    int converted = 0, blocked = 0;
    for (size_t i = 0; i < c.entries.size(); ++i) {
        const Entry& e = c.entries[i];
        Bytes body;
        if (!payload(c, e, body)) return 1;
        std::vector<size_t> hits = find_ids(body, map);
        if (hits.empty()) continue;
        if (knowledge.count(e.name)) {
            std::printf("  %-22s %zu variant id(s) in knowledge: left as is\n", e.name.c_str(), hits.size());
            continue;
        }
        uint32_t expected = 0;
        if (!convertible(e.name, expected)) {
            // Elsewhere a variant id is only a coincidence if it cannot be read as an item
            // record (e.g. 576628404 inside base03's terrain data, present before the mod).
            for (size_t at : hits) {
                Record r;
                if (record_at(body, at, r)) {
                    std::printf("  %-22s variant %u at 0x%zX looks like an item record in a chunk this version does not convert\n",
                                e.name.c_str(), rd32(&body[at]), at);
                    ++blocked;
                } else {
                    std::printf("  %-22s value at 0x%zX equals a variant id but is not an item record: left as is\n", e.name.c_str(), at);
                }
            }
            continue;
        }
        uint32_t content_version = rd32(&c.data[e.offset + 10]);
        if (content_version != expected) {
            std::printf("  %-22s content version %u was never seen (expected %u): not converting\n", e.name.c_str(), content_version, expected);
            blocked += static_cast<int>(hits.size());
            continue;
        }
        for (size_t at : hits) {
            Record r;
            uint32_t variant = rd32(&body[at]);
            if (!record_at(body, at, r)) {
                std::printf("  %-22s variant %u at 0x%zX is not inside a valid item record: not converting\n", e.name.c_str(), variant, at);
                ++blocked;
                continue;
            }
            uint32_t original = map.at(variant);
            wr32(&body[at], original);
            ++converted;
            std::printf("  %-22s slot 0x%02X: %u -> %u  %s  (count %u", e.name.c_str(), r.slot, variant, original, names[variant].c_str(), r.count);
            if (r.flags & 0x01) std::printf(", level %u", r.level);
            if (r.flags & 0x02) std::printf(", durability %u/%u", r.dur, r.dur_max);
            if (r.flags & 0x10) std::printf(", %s", rarity_name(r.rarity));
            std::printf(")\n");
        }
        // Same chunk header (compression flag included); a compressed chunk gets a stored
        // zstd frame, which must decode back to exactly the patched payload.
        Bytes chunk(c.data.begin() + e.offset, c.data.begin() + e.offset + 14);
        if (chunk[9] == 1) {
            Bytes frame = zstd_store(body);
            Bytes check(body.size() + 1);
            size_t r = ZSTD_decompress(check.data(), check.size(), frame.data(), frame.size());
            if (ZSTD_isError(r) || r != body.size() || std::memcmp(check.data(), body.data(), r) != 0)
                return fail("internal error: stored zstd frame does not decode to the patched chunk"), 1;
            chunk.insert(chunk.end(), frame.begin(), frame.end());
        } else {
            chunk.insert(chunk.end(), body.begin(), body.end());
        }
        rewritten[i] = std::move(chunk);
    }
    std::printf("%d item(s) to convert, %d variant id(s) blocked\n", converted, blocked);
    if (blocked) { std::printf("not writing: this file has variant items this version cannot convert safely\n"); return 3; }
    if (out.empty()) { std::printf("report only (use --out <file> to write a converted copy)\n"); return 0; }
    if (!converted) { std::printf("nothing to convert, no file written\n"); return 0; }

    // Rebuild: header, chunks back to back, zero padding to 16, then the original
    // directory block (entries + names) with offsets, sizes and checksums updated.
    Bytes o(c.data.begin(), c.data.begin() + 0x30);
    std::vector<std::pair<uint32_t, uint32_t>> placed;  // offset, size per entry
    for (size_t i = 0; i < c.entries.size(); ++i) {
        const Entry& e = c.entries[i];
        uint32_t off = static_cast<uint32_t>(o.size());
        auto it = rewritten.find(i);
        if (it != rewritten.end()) o.insert(o.end(), it->second.begin(), it->second.end());
        else o.insert(o.end(), c.data.begin() + e.offset, c.data.begin() + e.offset + e.size);
        placed.emplace_back(off, static_cast<uint32_t>(o.size()) - off);
    }
    while (o.size() % 16) o.push_back(0);
    size_t dir = o.size();
    o.insert(o.end(), c.data.begin() + c.dir, c.data.end());
    for (size_t i = 0; i < c.entries.size(); ++i) {
        size_t at = dir + i * 20;
        wr32(&o[at + 8], placed[i].first);
        wr32(&o[at + 12], placed[i].second);
        wr32(&o[at + 16], checksum(&o[placed[i].first], placed[i].second));
    }
    wr32(&o[8], static_cast<uint32_t>(o.size()));
    wr32(&o[0x28], static_cast<uint32_t>(dir - 0x28));

    // Verify the result the way the game does, and that no variant item is left.
    Container v;
    v.data = o;
    if (!parse(v)) { std::fprintf(stderr, "error: the converted file failed its own check, nothing written\n"); return 1; }
    for (size_t i = 0; i < v.entries.size(); ++i) {
        uint32_t expected = 0;
        if (!convertible(v.entries[i].name, expected)) continue;
        Bytes body;
        if (!payload(v, v.entries[i], body)) return 1;
        for (size_t at : find_ids(body, map)) {
            Record r;
            if (record_at(body, at, r)) { std::fprintf(stderr, "error: a variant item is still present after conversion, nothing written\n"); return 1; }
        }
    }
    std::ofstream f(out, std::ios::binary | std::ios::trunc);
    if (!f) { std::fprintf(stderr, "error: cannot write %s\n", out.c_str()); return 1; }
    f.write(reinterpret_cast<const char*>(o.data()), static_cast<std::streamsize>(o.size()));
    if (!f) { std::fprintf(stderr, "error: writing %s failed\n", out.c_str()); return 1; }
    std::printf("written %s (%zu bytes), verified\n", out.c_str(), o.size());
    return 0;
}
