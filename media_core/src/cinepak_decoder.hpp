#pragma once

#include "honey_media_core/media_core.h"

#include <cstddef>
#include <cstdint>

struct hmc_cinepak_decoder {
    hmc_cinepak_decoder_config_t config;
    std::size_t pixel_count;
    std::size_t uv_pixel_count;
    std::size_t plane_element_count;
    std::size_t plane_bytes;
    std::int16_t *planes;
    bool has_reference;
};

namespace honey::media {

hmc_status_t cinepak_decoder_config_init(
    hmc_cinepak_decoder_config_t *config,
    std::uint32_t config_size) noexcept;
hmc_status_t cinepak_decoder_create(
    const hmc_cinepak_decoder_config_t *config,
    hmc_cinepak_decoder_t **decoder) noexcept;
hmc_status_t cinepak_decoder_reset(
    hmc_cinepak_decoder_t *decoder) noexcept;
void cinepak_decoder_destroy(
    hmc_cinepak_decoder_t *decoder) noexcept;
hmc_status_t cinepak_decoder_decode(
    hmc_cinepak_decoder_t *decoder,
    const std::uint8_t *encoded,
    std::size_t encoded_size,
    std::uint32_t *argb,
    std::size_t argb_pixel_count) noexcept;

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void cinepak_decoder_test_fail_nth_allocation(
    std::size_t allocation_number) noexcept;
HMC_API void cinepak_decoder_test_clear_allocation_failure() noexcept;
HMC_API std::size_t cinepak_decoder_test_allocation_count() noexcept;
#endif

} // namespace honey::media
