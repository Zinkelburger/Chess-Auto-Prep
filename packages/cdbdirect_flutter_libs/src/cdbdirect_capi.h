/**
 * cdbdirect C ABI — four functions used by tree_builder and Flutter FFI.
 *
 * Implemented in cdbdirect_capi.cpp and linked into libcdbdirect.{so,dll,dylib}.
 */
#ifndef CDBDIRECT_CAPI_H
#define CDBDIRECT_CAPI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *cdbdirect_initialize(const char *path);
void cdbdirect_finalize(void *handle);
size_t cdbdirect_size(void *handle);
const char *cdbdirect_get(void *handle, const char *fen);

#ifdef __cplusplus
}
#endif

#endif /* CDBDIRECT_CAPI_H */
