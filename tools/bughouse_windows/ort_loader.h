// Hivemind's private ONNX Runtime. Included only by engine_ort.cc.
// Never initialize an Ort C++ object until the API pointer has been checked.
#pragma once

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

inline std::filesystem::path ort_module_path(HMODULE module) {
    std::vector<wchar_t> buffer(512);
    for (;;) {
        const DWORD count = GetModuleFileNameW(module, buffer.data(),
                                               static_cast<DWORD>(buffer.size()));
        if (!count) throw std::runtime_error("GetModuleFileNameW failed: " +
                                             std::to_string(GetLastError()));
        if (count < buffer.size()) return std::wstring(buffer.data(), count);
        if (buffer.size() >= 32768) throw std::runtime_error("Module path too long");
        buffer.resize(buffer.size() * 2);
    }
}

inline std::string ort_path_utf8(const std::filesystem::path& path) {
    const auto utf8 = path.u8string();
    return std::string(utf8.begin(), utf8.end());
}
#endif

inline void initialize_hivemind_ort() {
    // Thread-safe, once per process. Keep the DLL loaded until process exit:
    // Ort objects (including the global environment) use it during teardown.
    static const bool initialized = [] {
#ifdef _WIN32
        const auto expected = ort_module_path(nullptr).parent_path() / L"hivemind_ort.dll";
        std::cerr << "Hivemind ORT requested path: " << ort_path_utf8(expected) << '\n';
        SetErrorMode(GetErrorMode() | SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
        HMODULE module = LoadLibraryExW(expected.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) throw std::runtime_error("Cannot load private ONNX Runtime at " +
            ort_path_utf8(expected) + "; Windows error " + std::to_string(GetLastError()));
        // No basename lookup: resolve the export from this exact module handle.
        const auto loaded = ort_module_path(module);
        std::cerr << "Hivemind ORT loaded path: " << ort_path_utf8(loaded) << '\n';
        if (!std::filesystem::equivalent(expected, loaded)) {
            throw std::runtime_error("Windows loaded ONNX Runtime from an unexpected path");
        }
        const auto get_base = reinterpret_cast<decltype(&OrtGetApiBase)>(
            GetProcAddress(module, "OrtGetApiBase"));
        if (!get_base) throw std::runtime_error("Private runtime has no OrtGetApiBase export");
        const OrtApiBase* base = get_base();
#else
        const OrtApiBase* base = OrtGetApiBase();
#endif
        if (!base || !base->GetVersionString || !base->GetApi)
            throw std::runtime_error("ONNX Runtime returned an invalid API base");
        const char* version = base->GetVersionString();
        std::cerr << "Hivemind ORT version: " << (version ? version : "unknown")
                  << "; required API: " << ORT_API_VERSION << std::endl;
        const OrtApi* api = base->GetApi(ORT_API_VERSION);
        if (!api) throw std::runtime_error("Incompatible ONNX Runtime " +
            std::string(version ? version : "unknown") + "; required API " +
            std::to_string(ORT_API_VERSION) + ". Reinstall the bundled engine runtime.");
        Ort::InitApi(api);
        return true;
    }();
    (void)initialized;
}
