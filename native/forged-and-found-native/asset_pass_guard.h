// Stops a game that started without its mods. When ShroudForge's asset pass fails, it restores the
// saved game data, logs the failure and lets the game start anyway; the only sign is a page in its
// own window. Loading a character or world on that data deletes items other mods added, and saves
// the loss on quit. ShroudForge writes the failure to its log before it loads mod DLLs, so reading
// the log while the DLL starts is enough. The log file holds one session, marked with the process id.
#pragma once

#include <windows.h>

#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

namespace asset_pass_guard {

// Plenty for the start of a session, where the failure is logged, even at DEBUG level.
constexpr DWORD kMaxLogBytes = 64 * 1024 * 1024;

inline bool is_dedicated_server() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    const wchar_t* slash = wcsrchr(path, L'\\');
    return slash && _wcsicmp(slash + 1, L"enshrouded_server.exe") == 0;
}

// No log, or a log of another session, counts as no failure: a false alarm would stop a working game.
inline bool failed() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return false;
    *slash = L'\0';
    wchar_t file[MAX_PATH];
    if (swprintf(file, MAX_PATH, L"%s\\shroudforge\\logs\\shroudforge-%s.log", path, is_dedicated_server() ? L"server" : L"client") <= 0) {
        return false;
    }
    HANDLE handle = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    std::string text;
    if (GetFileSizeEx(handle, &size)) {
        DWORD wanted = size.QuadPart < kMaxLogBytes ? static_cast<DWORD>(size.QuadPart) : kMaxLogBytes;
        text.resize(wanted);
        DWORD got = 0;
        if (!wanted || !ReadFile(handle, text.data(), wanted, &got, nullptr)) got = 0;
        text.resize(got);
    }
    CloseHandle(handle);

    char session[64];
    snprintf(session, sizeof session, "Log session started for game PID %lu.", GetCurrentProcessId());
    size_t at = text.find(session);
    return at != std::string::npos && text.find("pregame phase failed", at) != std::string::npos;
}

inline DWORD WINAPI ask_player(LPVOID message) {
    using MessageBoxFn = int(WINAPI*)(HWND, LPCWSTR, LPCWSTR, UINT);
    HMODULE user32 = LoadLibraryW(L"user32.dll");  // not linked: a dedicated server never needs it
    auto box = user32 ? reinterpret_cast<MessageBoxFn>(GetProcAddress(user32, "MessageBoxW")) : nullptr;
    if (box && box(nullptr, static_cast<const wchar_t*>(message), L"ShroudForge could not apply your mods",
                   MB_YESNO | MB_ICONERROR | MB_TOPMOST | MB_SETFOREGROUND) == IDYES) {
        TerminateProcess(GetCurrentProcess(), 1);
    }
    return 0;
}

// True when the pass failed: the caller then installs no hooks. A dedicated server has nobody to
// ask and would load its world seconds later, so it exits instead; a service manager that restarts
// it retries the pass. A client asks once per process, even with several mods using this guard.
inline bool stop_if_failed(const wchar_t* message, void (*log)(const char*)) {
    if (!failed()) return false;
    if (is_dedicated_server()) {
        log("inactive: ShroudForge's asset pass failed, exiting before the world loads without the mods");
        TerminateProcess(GetCurrentProcess(), 1);
    }
    log("inactive: ShroudForge's asset pass failed, no hooks installed, asking the player to restart");
    wchar_t name[64];
    swprintf(name, 64, L"Local\\shroudforge-mods-asset-pass-%lu", GetCurrentProcessId());
    HANDLE first = CreateMutexW(nullptr, FALSE, name);
    if (first && GetLastError() != ERROR_ALREADY_EXISTS) {
        HANDLE thread = CreateThread(nullptr, 0, ask_player, const_cast<wchar_t*>(message), 0, nullptr);
        if (thread) CloseHandle(thread);
    }
    return true;
}

}  // namespace asset_pass_guard
