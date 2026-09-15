// Test-only DLL: faithfully models a runtime that cannot supply API 29.
#include <stdint.h>
#include <stddef.h>
static const void* get_api(uint32_t version) { (void)version; return NULL; }
static const char* get_version(void) { return "1.17.1-test"; }
static const struct {
    const void* (*GetApi)(uint32_t);
    const char* (*GetVersionString)(void);
} base = {get_api, get_version};
__declspec(dllexport) const void* OrtGetApiBase(void) { return &base; }
