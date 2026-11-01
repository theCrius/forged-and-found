// perk-variants-native: the native half of the perk-variants mod.
//
// 0.1.0 ("hello"): proves that ShroudForge loads this DLL from the mod package
// (native-plugin.ini) and into which process. It hooks nothing; it appends one
// line per load/unload to <mod folder>/perk-variants-native.log, naming the host
// executable and the PE identity of its build (TimeDateStamp, SizeOfImage), which
// the loot hook will later check before touching anything.
//
// Only kernel32 and the static CRT are used from DllMain (loader lock held).

#include <windows.h>
#include <cstdio>
#include <cwchar>

namespace {

constexpr const char* kVersion = "0.1.0";

wchar_t g_log_path[MAX_PATH];

// <mod folder>/perk-variants-native.log, where this DLL sits in <mod folder>/bin/.
bool resolve_log_path(HMODULE self) {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    for (int strip = 0; strip < 2; ++strip) {  // file name, then "bin"
        wchar_t* slash = wcsrchr(path, L'\\');
        if (!slash) return false;
        *slash = L'\0';
    }
    return swprintf(g_log_path, MAX_PATH, L"%s\\perk-variants-native.log", path) > 0;
}

void log_line(const char* text) {
    if (!g_log_path[0]) return;
    HANDLE file = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[1024];
    int len = snprintf(line, sizeof line, "[%04u-%02u-%02u %02u:%02u:%02u.%03u] %s\r\n", t.wYear, t.wMonth, t.wDay,
                       t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, text);
    if (len > 0) {
        DWORD written = 0;
        WriteFile(file, line, static_cast<DWORD>(len < (int)sizeof line ? len : sizeof line - 1), &written, nullptr);
    }
    CloseHandle(file);
}

// Host executable name and the PE header fields that identify its build.
void log_host(const char* event) {
    char exe[MAX_PATH] = "?";
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    const char* name = strrchr(exe, '\\');
    name = name ? name + 1 : exe;

    auto base = reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);

    char text[512];
    snprintf(text, sizeof text,
             "perk-variants-native %s %s: host %s (pid %lu), image base %p, PE TimeDateStamp 0x%08lX, SizeOfImage 0x%lX",
             kVersion, event, name, GetCurrentProcessId(), static_cast<const void*>(base),
             static_cast<unsigned long>(nt->FileHeader.TimeDateStamp),
             static_cast<unsigned long>(nt->OptionalHeader.SizeOfImage));
    log_line(text);
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(module);
        if (resolve_log_path(module)) log_host("loaded");
        break;
    case DLL_PROCESS_DETACH:
        log_host("unloaded");
        break;
    }
    return TRUE;
}
