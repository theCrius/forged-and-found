// perk-variants-native: the native half of the perk-variants mod.
//
// Hooks the function that creates new items into an inventory, enshrouded.exe+0x40B4F0
// (research/loot-item-creation.md). It runs for new loot only (chests, enemy remains,
// enemy loot, world pickups, gathering), not for moving items and not for crafting.
//
// 0.4.0 (marker): when the data mod's marker is on (manifest has markerId/nameId),
// also hooks the text lookup enshrouded.exe+0x11FA0D0 and renders each variant's
// marker name as "§ <original name>" in the current language. Nothing is written to
// text tables or archives, so uninstalling the mod leaves nothing behind.
//
// 0.3.0 (swap): when a verified loot caller creates an Epic or Legendary item that has
// variants, the item is rolled uniformly among {vanilla, variant 1..n} and the chosen
// ItemId is passed on instead (developer's design, CLAUDE.md "Delivery design"). The
// variant table comes from the data mod's export (shroudforge/exports/perk-variants/
// manifest.json, written in the asset pass before this DLL loads); lore items never
// have variants. Callers whose rarity argument is not verified (world pickups, the
// fixed-item loop) are only logged, and the crafting UI's simulated adds are skipped.
//
// Safety: the hook is installed only when the host is the exact client build it was
// written for (PE TimeDateStamp + SizeOfImage) and the target's first 15 bytes are
// the expected ones; anything else (other build, dedicated server, another mod's
// hook) leaves the game untouched and logs why. ShroudForge loads this DLL before
// the game entrypoint, so no game thread runs the target while it is patched.
//
// Log: <game>/shroudforge/logs/perk-variants-native.log. Nothing is written into the
// mod folder: ShroudForge fingerprints the package ("restart required" otherwise).

#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr const char* kVersion = "0.4.2";

// Callers (return addresses) whose 8th argument is proven to be the item's rarity:
// +0x3C0C7B chest/enemy-remains picker (Sleek Daggers, Shivs: Epic as in the tooltip),
// +0x3F9E2F enemy loot (Scrap Shield: Rare as in the tooltip).
constexpr uintptr_t kSwapCallers[] = {0x3C0C7B, 0x3F9E2F};
// The crafting UI's simulated adds (~3700 calls/s, main thread): never swapped or logged.
constexpr uintptr_t kCraftingUiCaller = 0x3F2258;
constexpr uint8_t kEpic = 3, kLegendary = 4;

// Build 1273043 client, enshrouded.exe SHA-256 d64966e2... (ShroudForge profile 26082781).
constexpr DWORD kTimeDateStamp = 0x6AD77F0C;
constexpr DWORD kSizeOfImage = 0x2A1E000;

// Creates `count` of `itemId` at *level / *rarity into an inventory. 9 arguments:
// every known caller passes 5 on the stack ([rsp+20h]..[rsp+40h]). Verified live
// (2026-11-01): Sleek Daggers -> level 15, rarity 3 (Epic); Scrap Shield -> 18, 2 (Rare).
constexpr uintptr_t kCreateItemRva = 0x40B4F0;
constexpr unsigned char kCreateItemPrologue[15] = {
    0x4C, 0x89, 0x4C, 0x24, 0x20,  // mov [rsp+20h], r9
    0x48, 0x89, 0x54, 0x24, 0x10,  // mov [rsp+10h], rdx
    0x48, 0x89, 0x4C, 0x24, 0x08,  // mov [rsp+8], rcx
};
// Every argument is forwarded as a raw 64-bit slot and only interpreted for logging:
// 0.2.0 declared `count` as uint16_t, MSVC then wrote only 16 bits into the 8-byte
// stack slot, and the game reads 32 (`mov esi,[rbp+108h]`): counts got garbage high
// bits (chests full of 1000-stacks, "backpack full" everywhere).
using CreateItemFn = uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t item_id, uint64_t count,
                                  uint64_t level_ptr, uint64_t rarity_ptr, uint64_t);

// Text lookup: bool lookup(TextView* out, TableHolder* holder, LocaTagId id). Binary
// search over the 24-byte LocaTagResource entries of the table at [holder+20h]; on a
// hit writes out = {const char* utf8, uint64 length} and returns 1. The resolver
// (+0x11FA7C0) tries several holders in turn (+0xE0, +0x40, +0x90) until one hits.
constexpr uintptr_t kTextLookupRva = 0x11FA0D0;
constexpr unsigned char kTextLookupPrologue[15] = {
    0x48, 0x89, 0x5C, 0x24, 0x08,  // mov [rsp+8], rbx
    0x48, 0x89, 0x74, 0x24, 0x10,  // mov [rsp+10h], rsi
    0x48, 0x89, 0x7C, 0x24, 0x18,  // mov [rsp+18h], rdi
};
using TextLookupFn = uint8_t (*)(uint64_t out, uint64_t holder, uint64_t id);
struct TextView { const char* text; uint64_t length; };
// Entry lookup: bool find(const LocaEntry** out, TableHolder* holder, LocaTagId id). The
// same binary search, but returns the table entry itself; the resolver +0x11FA4F0
// (holders +0xE0, +0x90, +0x40) uses it, and the UI reads names through that path.
constexpr uintptr_t kFindEntryRva = 0x11FA020;
constexpr unsigned char kFindEntryPrologue[14] = {
    0x48, 0x89, 0x5C, 0x24, 0x08,  // mov [rsp+8], rbx
    0x48, 0x89, 0x7C, 0x24, 0x10,  // mov [rsp+10h], rdi
    0x48, 0x8B, 0x42, 0x20,        // mov rax, [rdx+20h]
};
// keen::LocaTagResource (24 bytes): blob offsets are relative to their own field.
struct LocaEntry {
    uint32_t id;
    int32_t text_offset;
    uint32_t text_length;
    int32_t args_offset;   // BlobArray<LocaTagArgument>, 8-byte elements
    uint32_t args_count;
    uint32_t generic_args;
};
static_assert(sizeof(LocaEntry) == 24, "keen::LocaTagResource is 24 bytes");
constexpr char kMarkerPrefix[] = "\xC2\xA7 ";  // "§ " in UTF-8 (the tables are UTF-8)

wchar_t g_log_path[MAX_PATH];
HANDLE g_log = INVALID_HANDLE_VALUE;
SRWLOCK g_log_lock = SRWLOCK_INIT;
uintptr_t g_image_base = 0;
CreateItemFn g_create_item_original = nullptr;  // trampoline: saved prologue + jump back
TextLookupFn g_text_lookup_original = nullptr;
TextLookupFn g_find_entry_original = nullptr;
TextLookupFn g_find_entry = nullptr;  // the trampoline when hooked, else the game function itself

// Original ItemId -> its variants' ItemIds. Filled once in DllMain, read-only afterwards.
std::unordered_map<uint32_t, std::vector<uint32_t>>* g_variants = nullptr;
std::atomic<uint64_t> g_roll_counter{0};

// Marker name LocaTagId -> the original name's LocaTagId (from the manifest; present only
// when the data mod's marker is on). Read-only after DllMain.
std::unordered_map<uint32_t, uint32_t>* g_markers = nullptr;
// Fake marker entries per (table, marker id); never freed, so pointers handed to the UI
// stay valid for the process lifetime (at most 704 short blocks per language).
std::unordered_map<uint64_t, std::unordered_map<uint32_t, const LocaEntry*>>* g_marker_entries = nullptr;
SRWLOCK g_marker_lock = SRWLOCK_INIT;

// <game>/shroudforge/logs/perk-variants-native.log; <game> is the host exe's folder.
bool resolve_log_path() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return false;
    *slash = L'\0';
    return swprintf(g_log_path, MAX_PATH, L"%s\\shroudforge\\logs\\perk-variants-native.log", path) > 0;
}

void log_line(const char* text) {
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[512];
    int len = snprintf(line, sizeof line, "[%04u-%02u-%02u %02u:%02u:%02u.%03u] %s\r\n", t.wYear, t.wMonth, t.wDay,
                       t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, text);
    if (len <= 0) return;
    if (len >= (int)sizeof line) len = sizeof line - 1;
    AcquireSRWLockExclusive(&g_log_lock);
    DWORD written = 0;
    if (g_log != INVALID_HANDLE_VALUE) WriteFile(g_log, line, static_cast<DWORD>(len), &written, nullptr);
    ReleaseSRWLockExclusive(&g_log_lock);
}

// Reads through a pointer argument without trusting it (SEH, no C++ objects here).
bool read_u32(const uint32_t* p, uint32_t* out) {
    if (!p) return false;
    __try { *out = *p; return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_u8(const uint8_t* p, uint8_t* out) {
    if (!p) return false;
    __try { *out = *p; return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Per-caller call counts. The crafting UI calls the creator ~3700 times a second on
// the main thread (caller +0x3F2258, simulated adds for every recipe), so only the
// first kFullLines calls of each caller are logged in full; after that a line each
// time a caller reaches 100, 1000, 10000, ... calls, and a summary at unload.
constexpr int kMaxCallers = 64;
constexpr uint64_t kFullLines = 20;
struct CallerStat { uintptr_t caller; uint64_t calls; };
CallerStat g_callers[kMaxCallers];
int g_caller_count = 0;
SRWLOCK g_stats_lock = SRWLOCK_INIT;

// Counts the call and returns the caller's new total (0 if the table is full).
uint64_t count_call(uintptr_t caller) {
    AcquireSRWLockExclusive(&g_stats_lock);
    uint64_t calls = 0;
    int i = 0;
    while (i < g_caller_count && g_callers[i].caller != caller) ++i;
    if (i == g_caller_count && g_caller_count < kMaxCallers) g_callers[g_caller_count++] = {caller, 0};
    if (i < g_caller_count) calls = ++g_callers[i].calls;
    ReleaseSRWLockExclusive(&g_stats_lock);
    return calls;
}

bool is_power_of_ten(uint64_t n) {
    if (n < 100) return false;
    while (n % 10 == 0) n /= 10;
    return n == 1;
}

void log_caller_summary() {
    AcquireSRWLockShared(&g_stats_lock);
    for (int i = 0; i < g_caller_count; ++i) {
        char text[128];
        snprintf(text, sizeof text, "summary: caller +0x%llX %llu calls",
                 static_cast<unsigned long long>(g_callers[i].caller), static_cast<unsigned long long>(g_callers[i].calls));
        log_line(text);
    }
    ReleaseSRWLockShared(&g_stats_lock);
}

uint64_t splitmix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}

bool is_swap_caller(uintptr_t caller) {
    for (uintptr_t c : kSwapCallers) {
        if (c == caller) return true;
    }
    return false;
}

// Decides which ItemId to forward for an item that has variants. Returns the
// (possibly unchanged) 64-bit slot; only its low 32 bits are the ItemId.
uint64_t roll_item(uint64_t item_id, uint64_t rarity_ptr, uintptr_t caller, const std::vector<uint32_t>& variants) {
    uint32_t item = static_cast<uint32_t>(item_id);
    uint8_t ra = 0;
    bool has_ra = read_u8(reinterpret_cast<const uint8_t*>(rarity_ptr), &ra);
    char text[256];
    if (!is_swap_caller(caller)) {
        snprintf(text, sizeof text, "not swapped (unverified caller +0x%llX): item=%u rarity byte=%s%u",
                 static_cast<unsigned long long>(caller), item, has_ra ? "" : "?", ra);
        log_line(text);
        return item_id;
    }
    if (!has_ra || (ra != kEpic && ra != kLegendary)) {
        snprintf(text, sizeof text, "kept vanilla (rarity %s%u, below Epic): item=%u caller=+0x%llX", has_ra ? "" : "?",
                 ra, item, static_cast<unsigned long long>(caller));
        log_line(text);
        return item_id;
    }
    uint64_t seed = __rdtsc() ^ (g_roll_counter.fetch_add(1, std::memory_order_relaxed) << 32) ^ item;
    uint64_t pick = splitmix64(seed) % (variants.size() + 1);  // 0 = vanilla, k = variant k
    uint32_t chosen = pick == 0 ? item : variants[pick - 1];
    snprintf(text, sizeof text, "roll %s: item=%u -> %u (%s %llu of %zu) caller=+0x%llX",
             ra == kEpic ? "Epic" : "Legendary", item, chosen, pick == 0 ? "vanilla," : "variant",
             static_cast<unsigned long long>(pick), variants.size(), static_cast<unsigned long long>(caller));
    log_line(text);
    return (item_id & 0xFFFFFFFF00000000ull) | chosen;
}

uint64_t create_item_hook(uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t item_id, uint64_t count,
                          uint64_t level_ptr, uint64_t rarity_ptr, uint64_t a9) {
    uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - g_image_base;
    uint64_t calls = count_call(caller);
    uint64_t forward_id = item_id;
    if (caller != kCraftingUiCaller && g_variants) {
        auto it = g_variants->find(static_cast<uint32_t>(item_id));
        if (it != g_variants->end()) forward_id = roll_item(item_id, rarity_ptr, caller, it->second);
    }
    if (calls > kFullLines) {
        if (is_power_of_ten(calls)) {
            char text[128];
            snprintf(text, sizeof text, "caller +0x%llX reached %llu calls", static_cast<unsigned long long>(caller),
                     static_cast<unsigned long long>(calls));
            log_line(text);
        }
    } else {
        uint32_t lv = 0;
        uint8_t ra = 0;
        bool has_lv = read_u32(reinterpret_cast<const uint32_t*>(level_ptr), &lv);
        bool has_ra = read_u8(reinterpret_cast<const uint8_t*>(rarity_ptr), &ra);
        char text[256];
        snprintf(text, sizeof text, "create item=%u count=%u level=%s%u rarity=%s%u caller=+0x%llX thread=%lu",
                 static_cast<uint32_t>(forward_id), static_cast<uint32_t>(count), has_lv ? "" : "?", lv,
                 has_ra ? "" : "?", ra, static_cast<unsigned long long>(caller), GetCurrentThreadId());
        log_line(text);
    }
    return g_create_item_original(a1, a2, a3, a4, forward_id, count, level_ptr, rarity_ptr, a9);
}

// Reads the data mod's export: one variant per line, with "originalId":N and "itemId":N.
// <game>/shroudforge/exports/perk-variants/manifest.json, written by the asset pass of
// this launch (or the last launch that patched, when the pass was skipped as unchanged).
bool load_variant_table(char* text, size_t text_size) {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return false;
    *slash = L'\0';
    wchar_t file[MAX_PATH];
    swprintf(file, MAX_PATH, L"%s\\shroudforge\\exports\\perk-variants\\manifest.json", path);

    HANDLE h = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        snprintf(text, text_size, "no variant table (shroudforge/exports/perk-variants/manifest.json missing)");
        return false;
    }
    LARGE_INTEGER size{};
    GetFileSizeEx(h, &size);
    std::vector<char> data(static_cast<size_t>(size.QuadPart) + 1, '\0');
    DWORD read = 0;
    BOOL ok = ReadFile(h, data.data(), static_cast<DWORD>(size.QuadPart), &read, nullptr);
    CloseHandle(h);
    if (!ok || read != size.QuadPart) {
        snprintf(text, text_size, "variant table unreadable");
        return false;
    }

    auto* table = new std::unordered_map<uint32_t, std::vector<uint32_t>>();
    auto* markers = new std::unordered_map<uint32_t, uint32_t>();
    size_t variants = 0, bad = 0;
    for (char* line = data.data(); *line;) {
        char* end = strchr(line, '\n');
        if (end) *end = '\0';
        const char* o = strstr(line, "\"originalId\":");
        const char* v = strstr(line, "\"itemId\":");
        if (o && v) {
            unsigned long original = strtoul(o + 13, nullptr, 10), variant = strtoul(v + 9, nullptr, 10);
            if (original == 0 || variant == 0 || original == variant) {
                ++bad;
            } else {
                (*table)[static_cast<uint32_t>(original)].push_back(static_cast<uint32_t>(variant));
                ++variants;
            }
            // Marker pair (only with the marker on): all variants of an item share it.
            const char* m = strstr(line, "\"markerId\":");
            const char* nm = strstr(line, "\"nameId\":");
            if (m && nm) {
                unsigned long marker = strtoul(m + 11, nullptr, 10), name = strtoul(nm + 9, nullptr, 10);
                if (marker == 0 || name == 0 || marker == name) ++bad;
                else (*markers)[static_cast<uint32_t>(marker)] = static_cast<uint32_t>(name);
            }
        }
        if (!end) break;
        line = end + 1;
    }
    if (variants == 0 || bad > 0) {
        snprintf(text, text_size, "variant table rejected (%zu variants, %zu bad lines)", variants, bad);
        delete table;
        delete markers;
        return false;
    }
    g_variants = table;
    if (!markers->empty()) {
        g_markers = markers;
        g_marker_entries = new std::unordered_map<uint64_t, std::unordered_map<uint32_t, const LocaEntry*>>();
    } else {
        delete markers;
    }
    snprintf(text, text_size, "variant table: %zu items with %zu variants; %zu marker names", table->size(), variants,
             g_markers ? g_markers->size() : 0);
    return true;
}

// Replaces a position-independent prologue of N >= 14 bytes (whole instructions) at
// `target` with `jmp [rip+0]; dq hook` plus nops after copying it into an executable
// trampoline that ends with a jump back to target+N. Stores the trampoline (call it
// to run the original) in *original BEFORE the jump is written, so the hook can never
// run without it. Returns false when the bytes differ (other build, or hooked by
// something else) or memory could not be prepared; then nothing was changed.
template <size_t N, typename Fn>
bool install_hook(uintptr_t rva, const unsigned char (&prologue)[N], void* hook, Fn* original) {
    static_assert(N >= 14 && N <= 32, "the patch is a 14-byte jump; the trampoline holds 64 bytes");
    auto target = reinterpret_cast<unsigned char*>(g_image_base + rva);
    if (memcmp(target, prologue, sizeof prologue) != 0) return false;
    unsigned char* tramp = static_cast<unsigned char*>(
        VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!tramp) return false;
    memcpy(tramp, prologue, sizeof prologue);
    unsigned char* back = tramp + sizeof prologue;
    back[0] = 0xFF; back[1] = 0x25; memset(back + 2, 0, 4);  // jmp qword ptr [rip+0]
    uintptr_t resume = reinterpret_cast<uintptr_t>(target) + sizeof prologue;
    memcpy(back + 6, &resume, 8);
    FlushInstructionCache(GetCurrentProcess(), tramp, 64);

    DWORD old = 0;
    if (!VirtualProtect(target, sizeof prologue, PAGE_EXECUTE_READWRITE, &old)) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        return false;
    }
    *original = reinterpret_cast<Fn>(tramp);
    unsigned char patch[sizeof prologue];
    patch[0] = 0xFF; patch[1] = 0x25; memset(patch + 2, 0, 4);
    uintptr_t dest = reinterpret_cast<uintptr_t>(hook);
    memcpy(patch + 6, &dest, 8);
    memset(patch + 14, 0x90, sizeof patch - 14);
    memcpy(target, patch, sizeof patch);
    VirtualProtect(target, sizeof prologue, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof prologue);
    return true;
}

// Diagnostics: call counts per hook (1, 100, 1000, ...) and the first marker lookups
// in full, so a test shows which path the UI takes (0.4.0 hooked only the text path,
// and 0.4.1's log proved item names never go through it).
std::atomic<uint64_t> g_text_calls{0};
std::atomic<uint64_t> g_entry_calls{0};
std::atomic<uint64_t> g_marker_calls{0};
constexpr uint64_t kMarkerLines = 40;

void count_lookup(std::atomic<uint64_t>& counter, const char* via, uint64_t id, uintptr_t caller) {
    uint64_t calls = ++counter;
    if (calls != 1 && !is_power_of_ten(calls)) return;
    char text[128];
    snprintf(text, sizeof text, "%s lookup reached %llu calls (this one id=%u caller=+0x%llX)", via,
             static_cast<unsigned long long>(calls), static_cast<uint32_t>(id), static_cast<unsigned long long>(caller));
    log_line(text);
}

// The fake entry for `marker` in the table of `holder`, built from the original name's
// entry on first use and cached per table (never freed: the UI keeps pointers into it).
// nullptr when the original name is not in this table, so the resolver moves on to its
// next table exactly as for any unknown id.
const LocaEntry* marker_entry(uint64_t holder, uint32_t marker_id, uint32_t name_id, const char* via, uintptr_t caller) {
    uint64_t table = *reinterpret_cast<const uint64_t*>(holder + 0x20);  // one table per language
    uint64_t n = ++g_marker_calls;
    const LocaEntry* entry = nullptr;
    AcquireSRWLockShared(&g_marker_lock);
    auto per_table = g_marker_entries->find(table);
    if (per_table != g_marker_entries->end()) {
        auto cached = per_table->second.find(marker_id);
        if (cached != per_table->second.end()) entry = cached->second;
    }
    ReleaseSRWLockShared(&g_marker_lock);

    char outcome[160] = "cached";
    if (!entry) {
        const LocaEntry* name = nullptr;
        if (!g_find_entry(reinterpret_cast<uint64_t>(&name), holder, name_id)) {
            snprintf(outcome, sizeof outcome, "name missing here");
        } else {
            // Layout: entry, then the original's arguments (8-byte {id, type}, no pointers),
            // then the text. Blob offsets are relative to their own field; 0 = empty.
            const char* name_text = name->text_offset ? reinterpret_cast<const char*>(&name->text_offset) + name->text_offset : "";
            size_t prefix = sizeof kMarkerPrefix - 1;
            size_t args = name->args_offset ? name->args_count : 0;
            size_t text_at = sizeof(LocaEntry) + args * 8;
            char* block = new char[text_at + prefix + name->text_length + 1];
            auto made = reinterpret_cast<LocaEntry*>(block);
            made->id = marker_id;
            made->text_offset = static_cast<int32_t>(text_at - offsetof(LocaEntry, text_offset));
            made->text_length = static_cast<uint32_t>(prefix + name->text_length);
            made->args_offset = args ? static_cast<int32_t>(sizeof(LocaEntry) - offsetof(LocaEntry, args_offset)) : 0;
            made->args_count = static_cast<uint32_t>(args);
            made->generic_args = name->generic_args;
            if (args) memcpy(block + sizeof(LocaEntry), reinterpret_cast<const char*>(&name->args_offset) + name->args_offset, args * 8);
            memcpy(block + text_at, kMarkerPrefix, prefix);
            memcpy(block + text_at + prefix, name_text, name->text_length);
            block[text_at + made->text_length] = '\0';
            snprintf(outcome, sizeof outcome, "built (%zu args, %u generic: %.100s)", args, name->generic_args,
                     block + text_at);
            AcquireSRWLockExclusive(&g_marker_lock);
            auto placed = (*g_marker_entries)[table].emplace(marker_id, made);  // first wins a race
            ReleaseSRWLockExclusive(&g_marker_lock);
            if (!placed.second) {
                delete[] block;  // another thread built it first; nobody saw this copy
                snprintf(outcome, sizeof outcome, "built by another thread");
            }
            entry = placed.first->second;
        }
    }
    if (n <= kMarkerLines) {
        char text[320];
        snprintf(text, sizeof text, "marker lookup #%llu via %s: id=%u name=%u caller=+0x%llX table=%p -> %s",
                 static_cast<unsigned long long>(n), via, marker_id, name_id, static_cast<unsigned long long>(caller),
                 reinterpret_cast<void*>(table), outcome);
        log_line(text);
    }
    return entry;
}

// Text path (+0x11FA0D0): on a miss for a marker id, answer with the fake entry's text.
uint8_t text_lookup_hook(uint64_t out, uint64_t holder, uint64_t id) {
    uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - g_image_base;
    count_lookup(g_text_calls, "text", id, caller);
    uint8_t found = g_text_lookup_original(out, holder, id);
    if (found) return found;
    auto marker = g_markers->find(static_cast<uint32_t>(id));
    if (marker == g_markers->end()) return found;
    const LocaEntry* entry = marker_entry(holder, marker->first, marker->second, "text", caller);
    if (!entry) return 0;
    auto view = reinterpret_cast<TextView*>(out);
    view->text = reinterpret_cast<const char*>(&entry->text_offset) + entry->text_offset;
    view->length = entry->text_length;
    return 1;
}

// Entry path (+0x11FA020, used by the resolver +0x11FA4F0): on a miss for a marker id,
// answer with a pointer to the fake entry.
uint8_t find_entry_hook(uint64_t out, uint64_t holder, uint64_t id) {
    uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - g_image_base;
    count_lookup(g_entry_calls, "entry", id, caller);
    uint8_t found = g_find_entry_original(out, holder, id);
    if (found) return found;
    auto marker = g_markers->find(static_cast<uint32_t>(id));
    if (marker == g_markers->end()) return found;
    const LocaEntry* entry = marker_entry(holder, marker->first, marker->second, "entry", caller);
    if (!entry) return 0;
    *reinterpret_cast<const LocaEntry**>(out) = entry;
    return 1;
}

void start() {
    char exe[MAX_PATH] = "?";
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    const char* name = strrchr(exe, '\\');
    name = name ? name + 1 : exe;
    g_image_base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(g_image_base);
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(g_image_base + dos->e_lfanew);
    DWORD stamp = nt->FileHeader.TimeDateStamp, size = nt->OptionalHeader.SizeOfImage;

    char text[512];
    snprintf(text, sizeof text, "perk-variants-native %s loaded: host %s (pid %lu), PE TimeDateStamp 0x%08lX, SizeOfImage 0x%lX",
             kVersion, name, GetCurrentProcessId(), static_cast<unsigned long>(stamp), static_cast<unsigned long>(size));
    log_line(text);

    if (stamp != kTimeDateStamp || size != kSizeOfImage) {
        log_line("inactive: not the client build this DLL was written for (no hook installed)");
        return;
    }
    // Without a valid table the loot hook still installs, but only logs (g_variants stays null).
    bool swapping = load_variant_table(text, sizeof text);
    log_line(text);
    if (!install_hook(kCreateItemRva, kCreateItemPrologue, reinterpret_cast<void*>(&create_item_hook),
                      &g_create_item_original)) {
        log_line("loot hook NOT installed: create-item prologue differs (patched by something else?)");
    } else {
        log_line(swapping ? "loot hook installed at +0x40B4F0 (swapping Epic/Legendary loot for variants)"
                          : "loot hook installed at +0x40B4F0 (log only: no variant table)");
    }
    // Both text lookups are hooked only when the data mod's marker is on. The entry hook
    // goes first: g_find_entry must be set before either hook can build a marker.
    if (g_markers) {
        bool entry = install_hook(kFindEntryRva, kFindEntryPrologue, reinterpret_cast<void*>(&find_entry_hook),
                                  &g_find_entry_original);
        g_find_entry = entry ? g_find_entry_original : reinterpret_cast<TextLookupFn>(g_image_base + kFindEntryRva);
        log_line(entry ? "marker entry hook installed at +0x11FA020 (variant names rendered as \"\xC2\xA7 <name>\")"
                       : "marker entry hook NOT installed: entry-lookup prologue differs; variant names show as missing text");
        bool text_path = install_hook(kTextLookupRva, kTextLookupPrologue, reinterpret_cast<void*>(&text_lookup_hook),
                                      &g_text_lookup_original);
        log_line(text_path ? "marker text hook installed at +0x11FA0D0"
                      : "marker text hook NOT installed: text-lookup prologue differs");
    } else {
        log_line("marker off (no marker names in the variant table): text lookup untouched");
    }
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(module);
        if (resolve_log_path()) {
            g_log = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
        }
        start();
        break;
    case DLL_PROCESS_DETACH:
        // The hook stays: the process is ending, and game threads may still be inside it.
        log_caller_summary();
        if (g_markers) {
            char text[128];
            snprintf(text, sizeof text, "lookups: %llu text, %llu entry, %llu for marker ids",
                     static_cast<unsigned long long>(g_text_calls.load()),
                     static_cast<unsigned long long>(g_entry_calls.load()),
                     static_cast<unsigned long long>(g_marker_calls.load()));
            log_line(text);
        }
        log_line("unloaded");
        AcquireSRWLockExclusive(&g_log_lock);
        if (g_log != INVALID_HANDLE_VALUE) CloseHandle(g_log);
        g_log = INVALID_HANDLE_VALUE;
        ReleaseSRWLockExclusive(&g_log_lock);
        break;
    }
    return TRUE;
}
