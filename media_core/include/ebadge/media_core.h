#ifndef EBADGE_MEDIA_CORE_H
#define EBADGE_MEDIA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EB_MEDIA_ABI_VERSION 1u
#define EB_MEDIA_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8u) | \
     ((uint32_t)(uint8_t)(c) << 16u) | ((uint32_t)(uint8_t)(d) << 24u))

typedef enum eb_status {
    EB_STATUS_OK = 0,
    EB_STATUS_INVALID_ARGUMENT = 1,
    EB_STATUS_OUT_OF_MEMORY = 2,
    EB_STATUS_MALFORMED_DATA = 3,
    EB_STATUS_OVERFLOW = 4,
    EB_STATUS_INTERNAL_ERROR = 5
} eb_status_t;

typedef struct eb_buffer {
    uint8_t *data;
    size_t size;
} eb_buffer_t;

typedef struct eb_byte_view {
    const uint8_t *data;
    size_t size;
} eb_byte_view_t;

uint32_t eb_media_abi_version(void);
const char *eb_status_message(eb_status_t status);
void eb_buffer_release(eb_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
