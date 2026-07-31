#include "honey_media_core/media_core.h"

#ifndef HMC_MEDIA_CORE_H
#error "media_core.h must expose the HMC_MEDIA_CORE_H include guard"
#endif

void honey_media_core_c99_compile_test(void)
{
    hmc_owned_buffer_t buffer = {NULL, 0u};
    hmc_bytes_view_t view = {NULL, 0u};
    const uint32_t fourcc = HMC_MEDIA_FOURCC('R', 'G', 'B', 'A');
    const hmc_status_t status = HMC_STATUS_OK;

    (void)view;
    (void)fourcc;
    (void)status;
    hmc_owned_buffer_release(&buffer);
}
