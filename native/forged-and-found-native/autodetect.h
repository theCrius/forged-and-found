// Finds the DLL's hook targets in a game build it has no addresses for, using rules that
// held for game versions 1273043 and 1283531 (research/game-update-1283531.md):
//   1. item creator: the only function starting with its 15 entry bytes that has >= 15
//      direct callers (26 in both versions);
//   2. swap caller: calls to the item creator directly followed by the rarity read
//      `movzx eax, byte ptr [rbp-70h]` (0F B6 45 90) must be exactly two, inside the same
//      function (the container picker: fixed items first, then the random part); the later
//      one is the random-loot call, and its return address is the swap caller;
//   3. entry lookup: the only match of its 14 entry bytes (none on a dedicated server);
//   4. text lookup: the only match of its 15 entry bytes plus its first table read, within
//      0x1000 bytes of the entry lookup.
// Any rule that finds nothing or more than one candidate fails, and the caller stays
// inactive. Works on any image mapped with its sections at their RVAs (the game itself,
// or a file loaded as an image resource by the test tool).
#pragma once
#include <windows.h>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace autodetect {

struct Found {
    uintptr_t create_item = 0, swap_caller = 0, find_entry = 0, text_lookup = 0;
    bool loot = false;  // rules 1 and 2 passed
    bool text = false;  // rules 3 and 4 passed
};

struct Image {
    const uint8_t* base = nullptr;
    uint32_t text_rva = 0, text_size = 0;
    const IMAGE_RUNTIME_FUNCTION_ENTRY* pdata = nullptr;
    size_t pdata_count = 0;
};

inline bool open(const uint8_t* base, Image& im) {
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return false;
    const IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) {
            im.text_rva = sec[i].VirtualAddress;
            im.text_size = sec[i].Misc.VirtualSize;
            break;
        }
    }
    const IMAGE_DATA_DIRECTORY& ex = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    im.base = base;
    im.pdata = reinterpret_cast<const IMAGE_RUNTIME_FUNCTION_ENTRY*>(base + ex.VirtualAddress);
    im.pdata_count = ex.Size / sizeof(IMAGE_RUNTIME_FUNCTION_ENTRY);
    return im.text_rva != 0 && im.text_size > 16 && im.pdata_count > 0;
}

// RVAs of every place in the code section where the bytes start.
inline std::vector<uint32_t> find_all(const Image& im, const uint8_t* pattern, size_t len) {
    std::vector<uint32_t> hits;
    const uint8_t* p = im.base + im.text_rva;
    const uint8_t* end = p + im.text_size - len;
    while (p <= end) {
        p = static_cast<const uint8_t*>(memchr(p, pattern[0], static_cast<size_t>(end - p) + 1));
        if (!p) break;
        if (memcmp(p, pattern, len) == 0) hits.push_back(static_cast<uint32_t>(p - im.base));
        ++p;
    }
    return hits;
}

// Direct calls (E8 rel32) into any of the targets: target RVA -> call-site RVAs.
inline std::unordered_map<uint32_t, std::vector<uint32_t>> calls_into(const Image& im, const std::vector<uint32_t>& targets) {
    std::unordered_map<uint32_t, std::vector<uint32_t>> out;
    for (uint32_t t : targets) out[t];
    const uint8_t* p = im.base + im.text_rva;
    for (uint32_t i = 0; i + 5 <= im.text_size; ++i) {
        if (p[i] != 0xE8) continue;
        int32_t rel;
        memcpy(&rel, p + i + 1, 4);
        uint32_t site = im.text_rva + i;
        uint32_t target = site + 5 + static_cast<uint32_t>(rel);
        auto it = out.find(target);
        if (it != out.end()) it->second.push_back(site);
    }
    return out;
}

// Start of the function containing rva, following chained unwind entries to the primary one.
inline uint32_t function_start(const Image& im, uint32_t rva) {
    size_t lo = 0, hi = im.pdata_count;
    const IMAGE_RUNTIME_FUNCTION_ENTRY* f = nullptr;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (rva < im.pdata[mid].BeginAddress) hi = mid;
        else if (rva >= im.pdata[mid].EndAddress) lo = mid + 1;
        else { f = &im.pdata[mid]; break; }
    }
    for (int depth = 0; f && depth < 32; ++depth) {
        const uint8_t* info = im.base + f->UnwindData;
        uint8_t flags = info[0] >> 3;
        if (!(flags & UNW_FLAG_CHAININFO)) return f->BeginAddress;
        uint8_t codes = info[2];
        f = reinterpret_cast<const IMAGE_RUNTIME_FUNCTION_ENTRY*>(info + 4 + ((codes + 1) & ~1) * 2);
    }
    return f ? f->BeginAddress : 0;
}

inline void note(std::vector<std::string>& notes, const char* fmt, ...) {
    char text[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof text, fmt, args);
    va_end(args);
    notes.emplace_back(text);
}

inline bool detect(const Image& im, Found& f, std::vector<std::string>& notes) {
    static const uint8_t kCreator[] = {0x4C, 0x89, 0x4C, 0x24, 0x20, 0x48, 0x89, 0x54, 0x24, 0x10, 0x48, 0x89, 0x4C, 0x24, 0x08};
    static const uint8_t kRarityRead[] = {0x0F, 0xB6, 0x45, 0x90};
    static const uint8_t kEntry[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x7C, 0x24, 0x10, 0x48, 0x8B, 0x42, 0x20};
    static const uint8_t kText[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10,
                                    0x48, 0x89, 0x7C, 0x24, 0x18, 0x48, 0x8B, 0x42, 0x20};

    // Rule 1: item creator.
    std::vector<uint32_t> starts = find_all(im, kCreator, sizeof kCreator);
    auto calls = calls_into(im, starts);
    uint32_t creator = 0;
    int candidates = 0;
    for (uint32_t s : starts) {
        if (calls[s].size() >= 15) { creator = s; ++candidates; }
    }
    if (candidates != 1) {
        note(notes, "auto-detect rule 1 failed: %d item-creator candidates with >= 15 callers (%zu entry-byte matches)",
             candidates, starts.size());
    } else {
        note(notes, "auto-detect rule 1: item creator +0x%X (%zu callers)", creator, calls[creator].size());
        // Rule 2: the two rarity-reading calls in the container picker; the later one is random loot.
        std::vector<uint32_t> reads;
        for (uint32_t site : calls[creator]) {
            uint32_t after = site + 5;
            if (after + sizeof kRarityRead <= im.text_rva + im.text_size &&
                memcmp(im.base + after, kRarityRead, sizeof kRarityRead) == 0)
                reads.push_back(site);
        }
        if (reads.size() != 2) {
            note(notes, "auto-detect rule 2 failed: %zu creator calls followed by the rarity read (expected 2)", reads.size());
        } else {
            uint32_t a = reads[0] < reads[1] ? reads[0] : reads[1], b = reads[0] < reads[1] ? reads[1] : reads[0];
            uint32_t fa = function_start(im, a), fb = function_start(im, b);
            if (fa == 0 || fa != fb) {
                note(notes, "auto-detect rule 2 failed: the two rarity-reading calls (+0x%X, +0x%X) are not in one function", a, b);
            } else {
                f.create_item = creator;
                f.swap_caller = b + 5;
                f.loot = true;
                note(notes, "auto-detect rule 2: picker +0x%X, fixed-item call +0x%X, random-loot call +0x%X (+0x%X apart), swap caller +0x%X",
                     fa, a, b, b - a, b + 5);
            }
        }
    }

    // Rules 3 and 4: text lookups for the marker (absent on a dedicated server).
    std::vector<uint32_t> entry = find_all(im, kEntry, sizeof kEntry);
    std::vector<uint32_t> text = find_all(im, kText, sizeof kText);
    if (entry.size() == 1 && text.size() == 1) {
        uint32_t d = entry[0] > text[0] ? entry[0] - text[0] : text[0] - entry[0];
        if (d <= 0x1000) {
            f.find_entry = entry[0];
            f.text_lookup = text[0];
            f.text = true;
            note(notes, "auto-detect rules 3-4: entry lookup +0x%X, text lookup +0x%X", entry[0], text[0]);
        } else {
            note(notes, "auto-detect rule 4 failed: text lookup +0x%X is 0x%X bytes from the entry lookup", text[0], d);
        }
    } else {
        note(notes, "auto-detect rules 3-4: %zu entry-lookup and %zu text-lookup matches (expected 1 each; none on a dedicated server)",
             entry.size(), text.size());
    }
    return f.loot;
}

}  // namespace autodetect
