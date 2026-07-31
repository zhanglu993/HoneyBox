#ifndef HONEY_MEDIA_CORE_MEDIA_CORE_H
#define HONEY_MEDIA_CORE_MEDIA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HMC_MEDIA_ABI_VERSION 1u
#define HMC_MEDIA_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8u) | \
     ((uint32_t)(uint8_t)(c) << 16u) | ((uint32_t)(uint8_t)(d) << 24u))

typedef enum hmc_status {
    HMC_STATUS_OK = 0,
    HMC_STATUS_INVALID_ARGUMENT = 1,
    HMC_STATUS_OUT_OF_MEMORY = 2,
    HMC_STATUS_MALFORMED_DATA = 3,
    HMC_STATUS_OVERFLOW = 4,
    HMC_STATUS_INTERNAL_ERROR = 5
} hmc_status_t;

typedef struct hmc_owned_buffer {
    uint8_t *data;
    size_t size;
} hmc_owned_buffer_t;

typedef struct hmc_bytes_view {
    const uint8_t *data;
    size_t size;
} hmc_bytes_view_t;

uint32_t hmc_abi_version(void);
const char *hmc_status_message(hmc_status_t status);
void hmc_owned_buffer_release(hmc_owned_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
