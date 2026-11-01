// perk-variants-native: the native half of the perk-variants mod.
//
// 0.2.0 (log-only hook): hooks the function that creates loot items into an
// inventory, enshrouded.exe+0x40B4F0 (research/loot-item-creation.md), and logs
// every call (item, count, level, rarity, caller, thread). It changes nothing: the
// original runs with the exact arguments it was called with.
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
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>

namespace {

constexpr const char* kVersion = "0.2.1";

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

wchar_t g_log_path[MAX_PATH];
HANDLE g_log = INVALID_HANDLE_VALUE;
SRWLOCK g_log_lock = SRWLOCK_INIT;
uintptr_t g_image_base = 0;
CreateItemFn g_create_item_original = nullptr;  // trampoline: saved prologue + jump back

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

uint64_t create_item_hook(uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t item_id, uint64_t count,
                          uint64_t level_ptr, uint64_t rarity_ptr, uint64_t a9) {
    uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - g_image_base;
    uint32_t lv = 0;
    uint8_t ra = 0;
    bool has_lv = read_u32(reinterpret_cast<const uint32_t*>(level_ptr), &lv);
    bool has_ra = read_u8(reinterpret_cast<const uint8_t*>(rarity_ptr), &ra);
    char text[256];
    snprintf(text, sizeof text, "create item=%u count=%u level=%s%u rarity=%s%u caller=+0x%llX thread=%lu",
             static_cast<uint32_t>(item_id), static_cast<uint32_t>(count), has_lv ? "" : "?", lv, has_ra ? "" : "?",
             ra, static_cast<unsigned long long>(caller), GetCurrentThreadId());
    log_line(text);
    return g_create_item_original(a1, a2, a3, a4, item_id, count, level_ptr, rarity_ptr, a9);
}

// Replaces the 15-byte prologue at `target` with `jmp [rip+0]; dq hook; nop` after
// copying it into an executable trampoline that ends with a jump back to target+15.
bool install_hook(unsigned char* target, void* hook) {
    unsigned char* tramp = static_cast<unsigned char*>(
        VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!tramp) return false;
    memcpy(tramp, kCreateItemPrologue, sizeof kCreateItemPrologue);
    unsigned char* back = tramp + sizeof kCreateItemPrologue;
    back[0] = 0xFF; back[1] = 0x25; memset(back + 2, 0, 4);  // jmp qword ptr [rip+0]
    uintptr_t resume = reinterpret_cast<uintptr_t>(target) + sizeof kCreateItemPrologue;
    memcpy(back + 6, &resume, 8);
    FlushInstructionCache(GetCurrentProcess(), tramp, 64);

    DWORD old = 0;
    if (!VirtualProtect(target, sizeof kCreateItemPrologue, PAGE_EXECUTE_READWRITE, &old)) return false;
    unsigned char patch[sizeof kCreateItemPrologue];
    patch[0] = 0xFF; patch[1] = 0x25; memset(patch + 2, 0, 4);
    uintptr_t dest = reinterpret_cast<uintptr_t>(hook);
    memcpy(patch + 6, &dest, 8);
    patch[14] = 0x90;
    memcpy(target, patch, sizeof patch);
    VirtualProtect(target, sizeof kCreateItemPrologue, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof kCreateItemPrologue);

    g_create_item_original = reinterpret_cast<CreateItemFn>(tramp);
    return true;
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
    auto target = reinterpret_cast<unsigned char*>(g_image_base + kCreateItemRva);
    if (memcmp(target, kCreateItemPrologue, sizeof kCreateItemPrologue) != 0) {
        log_line("inactive: create-item prologue differs (patched by something else?), no hook installed");
        return;
    }
    if (!install_hook(target, reinterpret_cast<void*>(&create_item_hook))) {
        log_line("inactive: could not install the create-item hook");
        return;
    }
    log_line("hook installed at +0x40B4F0 (log only)");
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
        log_line("unloaded");
        AcquireSRWLockExclusive(&g_log_lock);
        if (g_log != INVALID_HANDLE_VALUE) CloseHandle(g_log);
        g_log = INVALID_HANDLE_VALUE;
        ReleaseSRWLockExclusive(&g_log_lock);
        break;
    }
    return TRUE;
}
