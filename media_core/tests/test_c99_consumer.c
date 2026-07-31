#include "ebadge/media_core.h"

void ebadge_media_core_c99_compile_test(void)
{
    eb_buffer_t buffer = {NULL, 0u};
    eb_byte_view_t view = {NULL, 0u};
    const uint32_t fourcc = EB_MEDIA_FOURCC('R', 'G', 'B', 'A');
    const eb_status_t status = EB_STATUS_OK;

    (void)view;
    (void)fourcc;
    (void)status;
    eb_buffer_release(&buffer);
}
