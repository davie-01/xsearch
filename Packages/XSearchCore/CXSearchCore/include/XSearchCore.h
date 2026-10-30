#ifndef XSEARCH_CORE_H
#define XSEARCH_CORE_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
// Implemented by rust/xs-core (target/release/libxs_core.a). See rust/xs-core/src/ffi.rs.
char *xs_normalize_utf8(const uint8_t *input, size_t length, uint8_t mode);
void xs_string_free(char *value);
const char *xs_name_key_version(void);
ssize_t xs_name_key(const uint8_t *input, size_t length, uint8_t *out, size_t out_cap);
#endif
