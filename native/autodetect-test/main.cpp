// autodetect-test: runs the DLL's auto-detection rules (forged-and-found-native/autodetect.h)
// against a game executable on disk, mapped as an image (no code runs), and prints what it
// finds. Used to check the rules against stored copies of each game build.
// Usage: autodetect-test <enshrouded.exe or enshrouded_server.exe> [expected creator swap entry text, hex]
#include "../forged-and-found-native/autodetect.h"

#include <cstdio>
#include <cstdlib>

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        std::fwprintf(stderr, L"usage: autodetect-test <exe> [creator swap entry text]\n");
        return 2;
    }
    HMODULE h = LoadLibraryExW(argv[1], nullptr, LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    if (!h) {
        std::fwprintf(stderr, L"cannot map %s (error %lu)\n", argv[1], GetLastError());
        return 1;
    }
    // A module loaded as an image resource has flag bits in the low bits of its handle.
    auto base = reinterpret_cast<const uint8_t*>(reinterpret_cast<uintptr_t>(h) & ~static_cast<uintptr_t>(3));
    autodetect::Image im;
    if (!autodetect::open(base, im)) {
        std::fprintf(stderr, "not a 64-bit executable with code and unwind data\n");
        return 1;
    }
    autodetect::Found f;
    std::vector<std::string> notes;
    DWORD t0 = GetTickCount();
    bool ok = autodetect::detect(im, f, notes);
    DWORD ms = GetTickCount() - t0;
    for (const std::string& n : notes) std::printf("%s\n", n.c_str());
    std::printf("result: loot %s, text %s (%lu ms)\n", f.loot ? "found" : "NOT found", f.text ? "found" : "not found", ms);

    int rc = ok ? 0 : 3;
    if (argc >= 6) {
        uintptr_t want[4];
        for (int i = 0; i < 4; ++i) want[i] = static_cast<uintptr_t>(wcstoull(argv[2 + i], nullptr, 16));
        uintptr_t got[4] = {f.create_item, f.swap_caller, f.find_entry, f.text_lookup};
        const char* names[4] = {"creator", "swap caller", "entry lookup", "text lookup"};
        for (int i = 0; i < 4; ++i) {
            bool same = want[i] == got[i];
            std::printf("  %-13s expected +0x%llX, found +0x%llX: %s\n", names[i], static_cast<unsigned long long>(want[i]),
                        static_cast<unsigned long long>(got[i]), same ? "match" : "MISMATCH");
            if (!same) rc = 4;
        }
    }
    FreeLibrary(h);
    return rc;
}
