#include "ebadge/media_core.h"

#include "core_types.hpp"

#include <cstdlib>

uint32_t eb_media_abi_version(void)
{
    return EB_MEDIA_ABI_VERSION;
}

const char *eb_status_message(eb_status_t status)
{
    switch (status) {
    case EB_STATUS_OK:
        return "ok";
    case EB_STATUS_INVALID_ARGUMENT:
        return "invalid argument";
    case EB_STATUS_OUT_OF_MEMORY:
        return "out of memory";
    case EB_STATUS_MALFORMED_DATA:
        return "malformed data";
    case EB_STATUS_OVERFLOW:
        return "overflow";
    case EB_STATUS_INTERNAL_ERROR:
        return "internal error";
    default:
        return "unknown status";
    }
}

void eb_buffer_release(eb_buffer_t *buffer)
{
    if (buffer == nullptr) {
        return;
    }

    std::free(buffer->data);
    buffer->data = nullptr;
    buffer->size = 0u;
}
