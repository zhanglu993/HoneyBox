#pragma once

#include "honey_media_core/media_core.h"

#include <cstddef>
#include <cstdint>

namespace honey::media {

hmc_status_t msv1_encoder_config_init(
    hmc_msv1_encoder_config_t *config,
    std::uint32_t config_size) noexcept;
hmc_status_t msv1_decoder_config_init(
    hmc_msv1_decoder_config_t *config,
    std::uint32_t config_size) noexcept;
hmc_status_t msv1_encode(
    const hmc_msv1_encoder_config_t *config,
    const std::uint8_t *rgba,
    std::size_t rgba_size,
    const std::uint8_t *previous_rgba,
    std::size_t previous_rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags) noexcept;
hmc_status_t msv1_decode(
    const hmc_msv1_decoder_config_t *config,
    const std::uint8_t *encoded,
    std::size_t encoded_size,
    std::uint32_t *argb,
    std::size_t argb_pixel_count) noexcept;

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void msv1_test_fail_nth_allocation(std::size_t allocation_number) noexcept;
HMC_API void msv1_test_clear_allocation_failure() noexcept;
HMC_API std::size_t msv1_test_allocation_count() noexcept;
#endif

} // namespace honey::media
