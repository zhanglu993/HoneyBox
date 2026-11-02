#pragma once

#include "honey_media_core/media_core.h"

#include <cstddef>
#include <cstdint>

struct hmc_avi_frame_record {
    std::size_t payload_offset;
    std::size_t payload_size;
    std::uint32_t avi_index_flags;
    hmc_frame_flags_t frame_flags;
};

struct hmc_avi_muxer {
    hmc_avi_muxer_config_t config;
    std::uint32_t usec_per_frame;
    std::uint32_t frame_count;
    std::uint32_t movi_size;
    std::uint8_t *payloads;
    std::size_t payloads_size;
    std::size_t payloads_capacity;
    hmc_avi_frame_record *frames;
    std::size_t frames_capacity;
    bool sealed;
};

struct hmc_avi_reader {
    std::uint8_t *bytes;
    std::size_t bytes_size;
    hmc_avi_info_t info;
    hmc_avi_frame_record *frames;
};

namespace honey::media {

hmc_status_t avi_muxer_config_init(
    hmc_avi_muxer_config_t *config,
    std::uint32_t config_size) noexcept;
hmc_status_t avi_muxer_create(
    const hmc_avi_muxer_config_t *config,
    hmc_avi_muxer_t **muxer) noexcept;
hmc_status_t avi_muxer_add_frame(
    hmc_avi_muxer_t *muxer,
    const std::uint8_t *data,
    std::size_t size,
    hmc_frame_flags_t frame_flags) noexcept;
hmc_status_t avi_muxer_finish(
    hmc_avi_muxer_t *muxer,
    hmc_owned_buffer_t *output) noexcept;
void avi_muxer_destroy(hmc_avi_muxer_t *muxer) noexcept;

hmc_status_t avi_reader_create_copy(
    const std::uint8_t *data,
    std::size_t size,
    hmc_avi_reader_t **reader) noexcept;
hmc_status_t avi_reader_get_info(
    const hmc_avi_reader_t *reader,
    hmc_avi_info_t *info) noexcept;
hmc_status_t avi_reader_get_frame_info(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_avi_frame_info_t *frame_info) noexcept;
hmc_status_t avi_reader_get_frame_view(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_bytes_view_t *frame) noexcept;
hmc_status_t avi_reader_copy_frame(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_owned_buffer_t *frame) noexcept;
void avi_reader_destroy(hmc_avi_reader_t *reader) noexcept;

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void avi_test_fail_nth_allocation(std::size_t allocation_number) noexcept;
HMC_API void avi_test_clear_allocation_failure() noexcept;
HMC_API std::size_t avi_test_allocation_count() noexcept;
#endif

} // namespace honey::media
