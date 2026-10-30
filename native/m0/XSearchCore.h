#ifndef XSEARCH_CORE_H
#define XSEARCH_CORE_H
#include <stdint.h>
#include <stddef.h>
char *xs_normalize_utf8(const uint8_t *input, size_t length, uint8_t mode);
void xs_string_free(char *value);
#endif
