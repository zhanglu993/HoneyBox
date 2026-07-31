#include "honey_media_core/media_core.h"

#include "core_types.hpp"

#include <cstdlib>

#if defined(_MSC_VER) && defined(_CPPUNWIND)
#error "honey_media_core must be compiled with C++ exceptions disabled"
#endif

uint32_t hmc_abi_version(void)
{
    return HMC_MEDIA_ABI_VERSION;
}

const char *hmc_status_message(hmc_status_t status)
{
    switch (status) {
    case HMC_STATUS_OK:
        return "ok";
    case HMC_STATUS_INVALID_ARGUMENT:
        return "invalid argument";
    case HMC_STATUS_OUT_OF_MEMORY:
        return "out of memory";
    case HMC_STATUS_MALFORMED_DATA:
        return "malformed data";
    case HMC_STATUS_OVERFLOW:
        return "overflow";
    case HMC_STATUS_INTERNAL_ERROR:
        return "internal error";
    default:
        return "unknown status";
    }
}

void hmc_owned_buffer_release(hmc_owned_buffer_t *buffer)
{
    if (buffer == nullptr) {
        return;
    }

    std::free(buffer->data);
    buffer->data = nullptr;
    buffer->size = 0u;
}
