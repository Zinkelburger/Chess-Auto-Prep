/**
 * cdbdirect_capi.cpp - C ABI wrapper for vondele/cdbdirect (C++ core).
 *
 * Exposes the four functions expected by tree_builder and Flutter FFI:
 *   cdbdirect_initialize, cdbdirect_get, cdbdirect_size, cdbdirect_finalize
 *
 * Built and linked into libcdbdirect.a / libcdbdirect.so by setup_cdbdirect.sh.
 */

#include "cdbdirect.h"

#include <cstdint>
#include <sstream>
#include <string>

extern "C" {

void *cdbdirect_initialize(const char *path) {
    if (!path || !path[0]) return nullptr;
    try {
        auto handle = ::cdbdirect_initialize(std::string(path));
        return reinterpret_cast<void *>(handle);
    } catch (...) {
        return nullptr;
    }
}

void cdbdirect_finalize(void *handle) {
    if (!handle) return;
    ::cdbdirect_finalize(reinterpret_cast<std::uintptr_t>(handle));
}

size_t cdbdirect_size(void *handle) {
    if (!handle) return 0;
    return static_cast<size_t>(
        ::cdbdirect_size(reinterpret_cast<std::uintptr_t>(handle)));
}

static thread_local std::string g_tls_response;

const char *cdbdirect_get(void *handle, const char *fen) {
    g_tls_response.clear();
    if (!handle || !fen || !fen[0]) return nullptr;

    try {
        auto results = ::cdbdirect_get(reinterpret_cast<std::uintptr_t>(handle),
                                       std::string(fen));
        if (results.empty()) return nullptr;

        for (const auto &entry : results) {
            if (entry.first == "a0a0" && entry.second == -2) return nullptr;
        }

        std::ostringstream oss;
        bool first = true;
        int rank = 0;
        for (const auto &entry : results) {
            if (entry.first == "a0a0") continue;
            if (!first) oss << '|';
            first = false;
            oss << "move:" << entry.first << ",score:" << entry.second
                << ",rank:" << rank++;
        }

        g_tls_response = oss.str();
        return g_tls_response.empty() ? nullptr : g_tls_response.c_str();
    } catch (...) {
        return nullptr;
    }
}

} /* extern "C" */
