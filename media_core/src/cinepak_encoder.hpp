#pragma once

#include "honey_media_core/media_core.h"

#include <cstddef>
#include <cstdint>

struct hmc_cinepak_encoder {
    hmc_cinepak_encoder_config_t config;
    std::size_t pixel_count;
    std::size_t uv_pixel_count;
    std::size_t rgba_size;
    std::size_t maximum_strip_macroblocks;
    std::size_t maximum_frame_size;
    std::int16_t *reconstruction;
    void *scratch;
    std::uint64_t frame_index;
    std::int64_t last_key;
    std::uint32_t effective_strips;
};

namespace honey::media {

hmc_status_t cinepak_encoder_config_init(
    hmc_cinepak_encoder_config_t *config,
    std::uint32_t config_size) noexcept;
hmc_status_t cinepak_encoder_create(
    const hmc_cinepak_encoder_config_t *config,
    hmc_cinepak_encoder_t **encoder) noexcept;
hmc_status_t cinepak_encoder_reset(hmc_cinepak_encoder_t *encoder) noexcept;
void cinepak_encoder_destroy(hmc_cinepak_encoder_t *encoder) noexcept;
hmc_status_t cinepak_encoder_encode(
    hmc_cinepak_encoder_t *encoder,
    const std::uint8_t *rgba,
    std::size_t rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags) noexcept;

#if defined(HMC_ENABLE_TEST_HOOKS)
struct CinepakNearestConversionDiagnostics {
    std::size_t data_conversions;
    std::size_t weight_conversions;
};

HMC_API void cinepak_encoder_test_reset_nearest_conversion_diagnostics() noexcept;
HMC_API CinepakNearestConversionDiagnostics
cinepak_encoder_test_nearest_conversion_diagnostics() noexcept;
HMC_API std::int32_t cinepak_encoder_test_floor_divide_power_of_two(
    std::int64_t value) noexcept;
HMC_API std::int32_t cinepak_encoder_test_kotlin_round(double value) noexcept;
HMC_API void cinepak_encoder_test_rgb_to_yuv(
    const std::uint8_t *rgba,
    std::uint32_t width,
    std::uint32_t height,
    std::int32_t *y,
    std::int32_t *u,
    std::int32_t *v) noexcept;
HMC_API hmc_status_t cinepak_encoder_test_vector_quantize(
    const std::int32_t *data,
    std::size_t count,
    std::size_t maximum_codebook,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::int32_t *codebook,
    std::uint32_t *labels,
    std::size_t *codebook_count) noexcept;
HMC_API hmc_status_t cinepak_encoder_test_lloyd_refine(
    const std::int32_t *data,
    std::size_t count,
    std::int32_t *codebook,
    std::size_t codebook_count,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::uint32_t *labels) noexcept;
HMC_API std::size_t cinepak_encoder_test_nearest_codebook(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight) noexcept;
HMC_API std::size_t cinepak_encoder_test_nearest_codebook_with_term_count(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight,
    std::size_t *evaluated_terms) noexcept;
HMC_API void cinepak_encoder_test_fail_nth_allocation(
    std::size_t allocation_number) noexcept;
HMC_API void cinepak_encoder_test_clear_allocation_failure() noexcept;
HMC_API std::size_t cinepak_encoder_test_allocation_count() noexcept;
#endif

} // namespace honey::media
