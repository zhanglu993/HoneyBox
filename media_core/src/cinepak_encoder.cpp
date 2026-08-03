#include "cinepak_encoder.hpp"

#include "allocator.hpp"
#include "core_types.hpp"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>

#if defined(_MSC_VER) && !defined(_M_FP_STRICT)
#error "Cinepak deterministic floating-point code requires MSVC /fp:strict"
#endif

#if defined(__FAST_MATH__)
#error "Cinepak deterministic floating-point code forbids fast-math"
#endif

namespace honey::media {
namespace {

constexpr std::size_t kCodebookMaximum = 256u;
constexpr std::size_t kVectorDimensions = 6u;
constexpr std::size_t kBe24Maximum = UINT32_C(0x00ffffff);
constexpr std::uint32_t kKnownEncodeFlags = HMC_ENCODE_FLAG_FORCE_KEY;
constexpr int kQuadX[4] = {0, 2, 0, 2};
constexpr int kQuadY[4] = {0, 0, 2, 2};

#if defined(HMC_ENABLE_TEST_HOOKS)
// Conversion diagnostics belong to the calling test thread so concurrent
// encoder handles cannot race or reset one another's observations.
thread_local CinepakNearestConversionDiagnostics g_nearest_conversion_diagnostics{};
#endif

template <typename T>
hmc_status_t allocate_array(std::size_t count, T **output) noexcept
{
    std::size_t bytes = 0u;
    if (output == nullptr || !checked_multiply_size(count, sizeof(T), &bytes)) {
        return HMC_STATUS_OVERFLOW;
    }
    void *const memory = allocate(bytes);
    if (memory == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    *output = static_cast<T *>(memory);
    return HMC_STATUS_OK;
}

bool add_size(std::size_t left, std::size_t right, std::size_t *result) noexcept
{
    return checked_add_size(left, right, result);
}

bool multiply_size(std::size_t left, std::size_t right, std::size_t *result) noexcept
{
    return checked_multiply_size(left, right, result);
}

std::int32_t floor_divide_power_of_two(std::int64_t value, unsigned shift) noexcept
{
    const std::int64_t divisor = INT64_C(1) << shift;
    if (value >= 0) {
        return static_cast<std::int32_t>(value / divisor);
    }
    return static_cast<std::int32_t>(-((-value + divisor - 1) / divisor));
}

std::int32_t kotlin_round(double value) noexcept
{
    return static_cast<std::int32_t>(std::floor(value + 0.5));
}

std::int32_t clamp(std::int32_t value, std::int32_t low, std::int32_t high) noexcept
{
    if (value < low) {
        return low;
    }
    return value > high ? high : value;
}

std::int32_t kotlin_int_from_bits(std::uint32_t bits) noexcept
{
    if (bits <= static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
        return static_cast<std::int32_t>(bits);
    }
    return -1 - static_cast<std::int32_t>(UINT32_MAX - bits);
}

bool tail_is_zero(const void *structure, std::uint32_t size, std::uint32_t known) noexcept
{
    const auto *const bytes = static_cast<const std::uint8_t *>(structure);
    for (std::uint32_t i = known; i < size; ++i) {
        if (bytes[i] != 0u) {
            return false;
        }
    }
    return true;
}

struct EncoderLimits {
    std::size_t pixel_count;
    std::size_t uv_pixel_count;
    std::size_t rgba_size;
    std::size_t maximum_strip_macroblocks;
    std::size_t maximum_frame_size;
    std::uint32_t effective_strips;
};

hmc_status_t calculate_limits(
    const hmc_cinepak_encoder_config_t &config,
    EncoderLimits *limits) noexcept
{
    if (limits == nullptr || config.width == 0u || config.height == 0u ||
        config.width > 65532u || config.height > 65532u ||
        (config.width & 3u) != 0u || (config.height & 3u) != 0u ||
        config.quality < 0 || config.quality > 100 ||
        config.v1_size < 1 || config.v1_size > 256 ||
        config.v4_size < 1 || config.v4_size > 256 ||
        config.refine_iterations < 0 || config.chroma_weight < 0 ||
        config.strips <= 0 || config.skip_threshold < 0 ||
        config.key_interval < 0) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    EncoderLimits candidate{};
    if (!multiply_size(config.width, config.height, &candidate.pixel_count) ||
        !multiply_size(config.width / 2u, config.height / 2u, &candidate.uv_pixel_count) ||
        !multiply_size(candidate.pixel_count, 4u, &candidate.rgba_size)) {
        return HMC_STATUS_OVERFLOW;
    }

    const std::size_t mb_x = config.width / 4u;
    const std::size_t mb_y = config.height / 4u;
    candidate.effective_strips = static_cast<std::uint32_t>(
        config.strips < static_cast<std::int32_t>(mb_y) ? config.strips : mb_y);
    if (candidate.effective_strips == 0u) {
        candidate.effective_strips = 1u;
    }

    std::size_t frame_size = 10u;
    std::size_t row_start = 0u;
    const bool mixed = config.quality > 20;
    for (std::size_t strip = 0u; strip < candidate.effective_strips; ++strip) {
        const std::size_t rows =
            (mb_y - row_start) / (candidate.effective_strips - strip);
        std::size_t macroblocks = 0u;
        if (!multiply_size(mb_x, rows, &macroblocks)) {
            return HMC_STATUS_OVERFLOW;
        }
        if (macroblocks > candidate.maximum_strip_macroblocks) {
            candidate.maximum_strip_macroblocks = macroblocks;
        }

        const std::size_t v1_entries = macroblocks < static_cast<std::size_t>(config.v1_size)
            ? macroblocks
            : static_cast<std::size_t>(config.v1_size);
        std::size_t four_macroblocks = 0u;
        if (!multiply_size(macroblocks, 4u, &four_macroblocks)) {
            return HMC_STATUS_OVERFLOW;
        }
        const std::size_t v4_entries = four_macroblocks < static_cast<std::size_t>(config.v4_size)
            ? four_macroblocks
            : static_cast<std::size_t>(config.v4_size);
        std::size_t consumed_bits = 0u;
        if (!multiply_size(macroblocks, 2u, &consumed_bits)) {
            return HMC_STATUS_OVERFLOW;
        }
        const std::size_t flag_words = (consumed_bits + 31u) / 32u;
        std::size_t flag_bytes = 0u;
        std::size_t index_bytes = macroblocks;
        if (!multiply_size(flag_words, 4u, &flag_bytes) ||
            (mixed && !multiply_size(macroblocks, 4u, &index_bytes))) {
            return HMC_STATUS_OVERFLOW;
        }
        std::size_t vector_body = 0u;
        std::size_t vector_chunk = 0u;
        if (!add_size(index_bytes, flag_bytes, &vector_body) ||
            !add_size(4u, vector_body, &vector_chunk) || vector_chunk > kBe24Maximum) {
            return HMC_STATUS_OVERFLOW;
        }
        std::size_t v1_bytes = 0u;
        std::size_t v4_bytes = 0u;
        if (!multiply_size(v1_entries, 6u, &v1_bytes) ||
            !add_size(v1_bytes, 4u, &v1_bytes) ||
            (mixed && (!multiply_size(v4_entries, 6u, &v4_bytes) ||
                       !add_size(v4_bytes, 4u, &v4_bytes)))) {
            return HMC_STATUS_OVERFLOW;
        }
        std::size_t strip_size = 12u;
        if (!add_size(strip_size, v1_bytes, &strip_size) ||
            !add_size(strip_size, v4_bytes, &strip_size) ||
            !add_size(strip_size, vector_chunk, &strip_size) ||
            strip_size > kBe24Maximum ||
            !add_size(frame_size, strip_size, &frame_size) ||
            frame_size > kBe24Maximum) {
            return HMC_STATUS_OVERFLOW;
        }
        row_start += rows;
    }
    candidate.maximum_frame_size = frame_size;
    *limits = candidate;
    return HMC_STATUS_OK;
}

struct Writer {
    std::uint8_t *data;
    std::size_t capacity;
    std::size_t size;

    bool byte(std::uint32_t value) noexcept
    {
        if (size >= capacity) {
            return false;
        }
        data[size++] = static_cast<std::uint8_t>(value);
        return true;
    }

    bool be16(std::uint32_t value) noexcept
    {
        return byte(value >> 8u) && byte(value);
    }

    bool be24(std::size_t value) noexcept
    {
        return value <= kBe24Maximum &&
               byte(static_cast<std::uint32_t>(value >> 16u)) &&
               byte(static_cast<std::uint32_t>(value >> 8u)) &&
               byte(static_cast<std::uint32_t>(value));
    }

    bool reserve_word(std::size_t *offset) noexcept
    {
        if (offset == nullptr || capacity - size < 4u) {
            return false;
        }
        *offset = size;
        data[size++] = 0u;
        data[size++] = 0u;
        data[size++] = 0u;
        data[size++] = 0u;
        return true;
    }

    bool patch_be24(std::size_t offset, std::size_t value) noexcept
    {
        if (value > kBe24Maximum || offset > size || size - offset < 3u) {
            return false;
        }
        data[offset] = static_cast<std::uint8_t>(value >> 16u);
        data[offset + 1u] = static_cast<std::uint8_t>(value >> 8u);
        data[offset + 2u] = static_cast<std::uint8_t>(value);
        return true;
    }
};

struct Scratch {
    std::int32_t *y = nullptr;
    std::int32_t *u = nullptr;
    std::int32_t *v = nullptr;
    std::int16_t *reconstruction = nullptr;
    std::int32_t *v1_vectors = nullptr;
    std::int32_t *v4_vectors = nullptr;
    std::int32_t *v1_codebook = nullptr;
    std::int32_t *v4_codebook = nullptr;
    std::uint32_t *v1_labels = nullptr;
    std::uint32_t *v4_labels = nullptr;
    std::uint32_t *indices = nullptr;
    std::uint32_t *temporary_indices = nullptr;
    double *centroids = nullptr;
    double *sums = nullptr;
    std::uint32_t *counts = nullptr;
    std::uint8_t *v4_decisions = nullptr;
    std::uint8_t *skip = nullptr;

    ~Scratch()
    {
        deallocate(y);
        deallocate(u);
        deallocate(v);
        deallocate(reconstruction);
        deallocate(v1_vectors);
        deallocate(v4_vectors);
        deallocate(v1_codebook);
        deallocate(v4_codebook);
        deallocate(v1_labels);
        deallocate(v4_labels);
        deallocate(indices);
        deallocate(temporary_indices);
        deallocate(centroids);
        deallocate(sums);
        deallocate(counts);
        deallocate(v4_decisions);
        deallocate(skip);
    }
};

struct OwnedFrame {
    std::uint8_t *data = nullptr;

    ~OwnedFrame()
    {
        deallocate(data);
    }

    std::uint8_t *release() noexcept
    {
        std::uint8_t *const released = data;
        data = nullptr;
        return released;
    }
};

hmc_status_t allocate_scratch(const hmc_cinepak_encoder_t &encoder, Scratch *scratch) noexcept
{
    if (scratch == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    std::size_t recon_count = 0u;
    std::size_t v1_vector_count = 0u;
    std::size_t four_macroblocks = 0u;
    std::size_t v4_vector_count = 0u;
    if (!multiply_size(encoder.uv_pixel_count, 2u, &recon_count) ||
        !add_size(recon_count, encoder.pixel_count, &recon_count) ||
        !multiply_size(encoder.maximum_strip_macroblocks, 6u, &v1_vector_count) ||
        !multiply_size(encoder.maximum_strip_macroblocks, 4u, &four_macroblocks) ||
        !multiply_size(four_macroblocks, 6u, &v4_vector_count)) {
        return HMC_STATUS_OVERFLOW;
    }

#define HMC_ALLOCATE_SCRATCH(count, member) \
    do { \
        const hmc_status_t status = allocate_array((count), &scratch->member); \
        if (status != HMC_STATUS_OK) { \
            return status; \
        } \
    } while (false)

    HMC_ALLOCATE_SCRATCH(encoder.pixel_count, y);
    HMC_ALLOCATE_SCRATCH(encoder.uv_pixel_count, u);
    HMC_ALLOCATE_SCRATCH(encoder.uv_pixel_count, v);
    HMC_ALLOCATE_SCRATCH(recon_count, reconstruction);
    HMC_ALLOCATE_SCRATCH(v1_vector_count, v1_vectors);
    HMC_ALLOCATE_SCRATCH(v4_vector_count, v4_vectors);
    HMC_ALLOCATE_SCRATCH(kCodebookMaximum * kVectorDimensions, v1_codebook);
    HMC_ALLOCATE_SCRATCH(kCodebookMaximum * kVectorDimensions, v4_codebook);
    HMC_ALLOCATE_SCRATCH(encoder.maximum_strip_macroblocks, v1_labels);
    HMC_ALLOCATE_SCRATCH(four_macroblocks, v4_labels);
    HMC_ALLOCATE_SCRATCH(four_macroblocks, indices);
    HMC_ALLOCATE_SCRATCH(four_macroblocks, temporary_indices);
    HMC_ALLOCATE_SCRATCH(kCodebookMaximum * kVectorDimensions, centroids);
    HMC_ALLOCATE_SCRATCH(kCodebookMaximum * kVectorDimensions, sums);
    HMC_ALLOCATE_SCRATCH(kCodebookMaximum, counts);
    HMC_ALLOCATE_SCRATCH(encoder.maximum_strip_macroblocks, v4_decisions);
    HMC_ALLOCATE_SCRATCH(encoder.maximum_strip_macroblocks, skip);
#undef HMC_ALLOCATE_SCRATCH
    return HMC_STATUS_OK;
}

void rgb_to_yuv(
    const std::uint8_t *rgba,
    std::uint32_t width,
    std::uint32_t height,
    std::int32_t *y_plane,
    std::int32_t *u_plane,
    std::int32_t *v_plane) noexcept
{
    for (std::uint32_t py = 0u; py < height; ++py) {
        for (std::uint32_t px = 0u; px < width; ++px) {
            const std::size_t i =
                (static_cast<std::size_t>(py) * width + px) * 4u;
            const std::int64_t r = rgba[i];
            const std::int64_t g = rgba[i + 1u];
            const std::int64_t b = rgba[i + 2u];
            const std::int64_t value =
                INT64_C(2396625) * r + INT64_C(4793251) * g + INT64_C(1198732) * b;
            y_plane[static_cast<std::size_t>(py) * width + px] =
                clamp(floor_divide_power_of_two(value, 23u), 0, 255);
        }
    }

    const std::uint32_t uv_width = width / 2u;
    const std::uint32_t uv_height = height / 2u;
    for (std::uint32_t by = 0u; by < uv_height; ++by) {
        for (std::uint32_t bx = 0u; bx < uv_width; ++bx) {
            const std::uint32_t x = bx * 2u;
            const std::uint32_t y = by * 2u;
            std::int64_t sum_r = 0;
            std::int64_t sum_g = 0;
            std::int64_t sum_b = 0;
            for (std::uint32_t dy = 0u; dy < 2u; ++dy) {
                std::size_t i =
                    (static_cast<std::size_t>(y + dy) * width + x) * 4u;
                for (std::uint32_t dx = 0u; dx < 2u; ++dx) {
                    sum_r += rgba[i];
                    sum_g += rgba[i + 1u];
                    sum_b += rgba[i + 2u];
                    i += 4u;
                }
            }
            const std::int64_t u =
                -INT64_C(299683) * sum_r - INT64_C(599156) * sum_g + INT64_C(898839) * sum_b;
            const std::int64_t v =
                INT64_C(748893) * sum_r - INT64_C(599156) * sum_g - INT64_C(149737) * sum_b;
            const std::size_t uv_index = static_cast<std::size_t>(by) * uv_width + bx;
            u_plane[uv_index] = clamp(floor_divide_power_of_two(u, 23u), -128, 127);
            v_plane[uv_index] = clamp(floor_divide_power_of_two(v, 23u), -128, 127);
        }
    }
}

struct Box {
    std::size_t offset;
    std::size_t count;
    std::int32_t range;
    std::size_t dimension;
};

void range_of(
    const std::int32_t *data,
    const std::uint32_t *indices,
    std::size_t offset,
    std::size_t count,
    std::int32_t *range,
    std::size_t *dimension) noexcept
{
    std::int32_t best_range = -1;
    std::size_t best_dimension = 0u;
    for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
        std::int32_t minimum = std::numeric_limits<std::int32_t>::max();
        std::int32_t maximum = std::numeric_limits<std::int32_t>::min();
        for (std::size_t i = 0u; i < count; ++i) {
            const std::int32_t value = data[indices[offset + i] * kVectorDimensions + d];
            if (value < minimum) {
                minimum = value;
            }
            if (value > maximum) {
                maximum = value;
            }
        }
        const std::int32_t candidate = maximum - minimum;
        if (candidate > best_range) {
            best_range = candidate;
            best_dimension = d;
        }
    }
    *range = best_range;
    *dimension = best_dimension;
}

void stable_sort_indices(
    std::uint32_t *indices,
    std::uint32_t *temporary,
    std::size_t offset,
    std::size_t count,
    const std::int32_t *data,
    std::size_t dimension) noexcept
{
    if (count < 2u) {
        return;
    }
    const std::size_t left_count = count / 2u;
    stable_sort_indices(indices, temporary, offset, left_count, data, dimension);
    stable_sort_indices(indices, temporary, offset + left_count, count - left_count, data, dimension);
    std::size_t left = offset;
    std::size_t right = offset + left_count;
    const std::size_t left_end = right;
    const std::size_t right_end = offset + count;
    std::size_t output = offset;
    while (left < left_end && right < right_end) {
        const std::int32_t left_value = data[indices[left] * kVectorDimensions + dimension];
        const std::int32_t right_value = data[indices[right] * kVectorDimensions + dimension];
        temporary[output++] = left_value <= right_value ? indices[left++] : indices[right++];
    }
    while (left < left_end) {
        temporary[output++] = indices[left++];
    }
    while (right < right_end) {
        temporary[output++] = indices[right++];
    }
    std::memcpy(indices + offset, temporary + offset, count * sizeof(*indices));
}

std::size_t nearest_codebook(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    double chroma_weight
#if defined(HMC_ENABLE_TEST_HOOKS)
    , std::size_t *evaluated_terms = nullptr
#endif
    ) noexcept
{
#if defined(HMC_ENABLE_TEST_HOOKS)
    if (evaluated_terms != nullptr) {
        *evaluated_terms = 0u;
    }
#endif
    if (codebook_count == 0u) {
        return 0u;
    }
    const double data0 = static_cast<double>(data[0]);
    const double data1 = static_cast<double>(data[1]);
    const double data2 = static_cast<double>(data[2]);
    const double data3 = static_cast<double>(data[3]);
    const double data4 = static_cast<double>(data[4]);
    const double data5 = static_cast<double>(data[5]);
#if defined(HMC_ENABLE_TEST_HOOKS)
    g_nearest_conversion_diagnostics.data_conversions += 6u;
#endif
    std::size_t best = 0u;
    double best_distance = std::numeric_limits<double>::infinity();
    for (std::size_t c = 0u; c < codebook_count; ++c) {
        const std::size_t cb = c * kVectorDimensions;
        double distance = 0.0;
        double delta = data0 - centroids[cb];
        distance += delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        delta = data1 - centroids[cb + 1u];
        distance += delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        delta = data2 - centroids[cb + 2u];
        distance += delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        delta = data3 - centroids[cb + 3u];
        distance += delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        delta = data4 - centroids[cb + 4u];
        distance += chroma_weight * delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        delta = data5 - centroids[cb + 5u];
        distance += chroma_weight * delta * delta;
#if defined(HMC_ENABLE_TEST_HOOKS)
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
#endif
        if (distance >= best_distance) {
            continue;
        }

        if (distance < best_distance) {
            best_distance = distance;
            best = c;
            if (best_distance == 0.0) {
                return best;
            }
        }
    }
    return best;
}

void lloyd_refine(
    const std::int32_t *data,
    std::size_t count,
    std::size_t codebook_count,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::int32_t *codebook,
    std::uint32_t *labels,
    Scratch *scratch) noexcept
{
    if (refine_iterations <= 0 || codebook_count == 0u || count == 0u) {
        return;
    }
    const double weight = static_cast<double>(chroma_weight);
#if defined(HMC_ENABLE_TEST_HOOKS)
    ++g_nearest_conversion_diagnostics.weight_conversions;
#endif
    for (std::size_t i = 0u; i < codebook_count * kVectorDimensions; ++i) {
        scratch->centroids[i] = static_cast<double>(codebook[i]);
    }
    for (std::int32_t iteration = 0; iteration < refine_iterations; ++iteration) {
        std::memset(
            scratch->sums,
            0,
            codebook_count * kVectorDimensions * sizeof(*scratch->sums));
        std::memset(
            scratch->counts,
            0,
            codebook_count * sizeof(*scratch->counts));
        for (std::size_t i = 0u; i < count; ++i) {
            const std::size_t base = i * kVectorDimensions;
            const std::size_t best = nearest_codebook(
                data + base,
                scratch->centroids,
                codebook_count,
                weight);
            labels[i] = static_cast<std::uint32_t>(best);
            ++scratch->counts[best];
            const std::size_t sum_base = best * kVectorDimensions;
            for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
                scratch->sums[sum_base + d] += data[base + d];
            }
        }
        for (std::size_t c = 0u; c < codebook_count; ++c) {
            if (scratch->counts[c] != 0u) {
                const std::size_t base = c * kVectorDimensions;
                for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
                    scratch->centroids[base + d] =
                        scratch->sums[base + d] / scratch->counts[c];
                }
            }
        }
    }
    for (std::size_t i = 0u; i < codebook_count * kVectorDimensions; ++i) {
        codebook[i] = kotlin_round(scratch->centroids[i]);
    }
}

std::size_t vector_quantize(
    const std::int32_t *data,
    std::size_t count,
    std::size_t maximum_codebook,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::int32_t *codebook,
    std::uint32_t *labels,
    Scratch *scratch) noexcept
{
    for (std::size_t i = 0u; i < count; ++i) {
        scratch->indices[i] = static_cast<std::uint32_t>(i);
    }
    Box boxes[kCodebookMaximum]{};
    range_of(data, scratch->indices, 0u, count, &boxes[0].range, &boxes[0].dimension);
    boxes[0].offset = 0u;
    boxes[0].count = count;
    std::size_t box_count = 1u;
    while (box_count < maximum_codebook) {
        std::size_t selected = kCodebookMaximum;
        std::int32_t best_range = 0;
        for (std::size_t i = 0u; i < box_count; ++i) {
            if (boxes[i].count > 1u && boxes[i].range > best_range) {
                selected = i;
                best_range = boxes[i].range;
            }
        }
        if (selected == kCodebookMaximum || best_range <= 0) {
            break;
        }
        Box &box = boxes[selected];
        stable_sort_indices(
            scratch->indices,
            scratch->temporary_indices,
            box.offset,
            box.count,
            data,
            box.dimension);
        const std::size_t left_count = box.count / 2u;
        Box right{};
        right.offset = box.offset + left_count;
        right.count = box.count - left_count;
        box.count = left_count;
        range_of(data, scratch->indices, box.offset, box.count, &box.range, &box.dimension);
        range_of(data, scratch->indices, right.offset, right.count, &right.range, &right.dimension);
        boxes[box_count++] = right;
    }

    for (std::size_t i = 0u; i < box_count; ++i) {
        std::uint32_t sums[kVectorDimensions]{};
        for (std::size_t k = 0u; k < boxes[i].count; ++k) {
            const std::size_t member = scratch->indices[boxes[i].offset + k];
            for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
                sums[d] += static_cast<std::uint32_t>(
                    data[member * kVectorDimensions + d]);
            }
            labels[member] = static_cast<std::uint32_t>(i);
        }
        for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
            codebook[i * kVectorDimensions + d] = kotlin_round(
                static_cast<double>(kotlin_int_from_bits(sums[d])) /
                static_cast<double>(boxes[i].count));
        }
    }

    lloyd_refine(
        data,
        count,
        box_count,
        refine_iterations,
        chroma_weight,
        codebook,
        labels,
        scratch);
    return box_count;
}

void paint_v1(
    std::int16_t *reconstruction,
    std::size_t pixel_count,
    std::size_t uv_pixel_count,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    const std::int32_t *entry) noexcept
{
    std::int16_t *const y = reconstruction;
    std::int16_t *const u = reconstruction + pixel_count;
    std::int16_t *const v = u + uv_pixel_count;
    for (std::size_t q = 0u; q < 4u; ++q) {
        const std::uint32_t x = x0 + static_cast<std::uint32_t>(kQuadX[q]);
        const std::uint32_t row = y0 + static_cast<std::uint32_t>(kQuadY[q]);
        y[static_cast<std::size_t>(row) * width + x] = static_cast<std::int16_t>(entry[q]);
        y[static_cast<std::size_t>(row) * width + x + 1u] = static_cast<std::int16_t>(entry[q]);
        y[static_cast<std::size_t>(row + 1u) * width + x] = static_cast<std::int16_t>(entry[q]);
        y[static_cast<std::size_t>(row + 1u) * width + x + 1u] = static_cast<std::int16_t>(entry[q]);
    }
    const std::uint32_t uv_width = width / 2u;
    const std::uint32_t ux = x0 / 2u;
    const std::uint32_t uy = y0 / 2u;
    for (std::uint32_t dy = 0u; dy < 2u; ++dy) {
        for (std::uint32_t dx = 0u; dx < 2u; ++dx) {
            const std::size_t index = static_cast<std::size_t>(uy + dy) * uv_width + ux + dx;
            u[index] = static_cast<std::int16_t>(entry[4]);
            v[index] = static_cast<std::int16_t>(entry[5]);
        }
    }
}

void paint_v4(
    std::int16_t *reconstruction,
    std::size_t pixel_count,
    std::size_t uv_pixel_count,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    const std::int32_t *entries[4]) noexcept
{
    std::int16_t *const y = reconstruction;
    std::int16_t *const u = reconstruction + pixel_count;
    std::int16_t *const v = u + uv_pixel_count;
    for (std::size_t q = 0u; q < 4u; ++q) {
        const std::uint32_t x = x0 + static_cast<std::uint32_t>(kQuadX[q]);
        const std::uint32_t row = y0 + static_cast<std::uint32_t>(kQuadY[q]);
        const std::int32_t *const entry = entries[q];
        y[static_cast<std::size_t>(row) * width + x] = static_cast<std::int16_t>(entry[0]);
        y[static_cast<std::size_t>(row) * width + x + 1u] = static_cast<std::int16_t>(entry[1]);
        y[static_cast<std::size_t>(row + 1u) * width + x] = static_cast<std::int16_t>(entry[2]);
        y[static_cast<std::size_t>(row + 1u) * width + x + 1u] = static_cast<std::int16_t>(entry[3]);
    }
    const std::uint32_t uv_width = width / 2u;
    const std::uint32_t ux = x0 / 2u;
    const std::uint32_t uy = y0 / 2u;
    for (std::size_t q = 0u; q < 4u; ++q) {
        const std::size_t index =
            static_cast<std::size_t>(uy + static_cast<std::uint32_t>(kQuadY[q] / 2)) * uv_width +
            ux + static_cast<std::uint32_t>(kQuadX[q] / 2);
        u[index] = static_cast<std::int16_t>(entries[q][4]);
        v[index] = static_cast<std::int16_t>(entries[q][5]);
    }
}

bool write_codebook(
    Writer *writer,
    std::uint8_t id,
    const std::int32_t *codebook,
    std::size_t count) noexcept
{
    const std::size_t chunk_size = 4u + count * kVectorDimensions;
    if (!writer->byte(id) || !writer->be24(chunk_size)) {
        return false;
    }
    for (std::size_t i = 0u; i < count; ++i) {
        for (std::size_t d = 0u; d < kVectorDimensions; ++d) {
            if (!writer->byte(static_cast<std::uint32_t>(
                    codebook[i * kVectorDimensions + d]))) {
                return false;
            }
        }
    }
    return true;
}

struct BitEmitter {
    Writer *writer;
    std::size_t bit_index;
    std::size_t word_offset;

    bool emit(bool value) noexcept
    {
        if ((bit_index & 31u) == 0u) {
            if (!writer->reserve_word(&word_offset)) {
                return false;
            }
        }
        const std::size_t within = bit_index & 31u;
        if (value) {
            writer->data[word_offset + within / 8u] |=
                static_cast<std::uint8_t>(0x80u >> (within & 7u));
        }
        ++bit_index;
        return true;
    }
};

hmc_status_t encode_strip(
    const hmc_cinepak_encoder_t &encoder,
    Scratch *scratch,
    Writer *writer,
    std::size_t top_macroblock_row,
    std::size_t macroblock_rows,
    bool inter) noexcept
{
    const std::uint32_t width = encoder.config.width;
    const std::uint32_t uv_width = width / 2u;
    const std::size_t macroblocks_x = width / 4u;
    const std::size_t macroblock_count = macroblocks_x * macroblock_rows;
    const std::uint32_t top_row = static_cast<std::uint32_t>(top_macroblock_row * 4u);
    for (std::size_t local_y = 0u; local_y < macroblock_rows; ++local_y) {
        for (std::size_t mx = 0u; mx < macroblocks_x; ++mx) {
            const std::size_t macroblock = local_y * macroblocks_x + mx;
            const std::uint32_t x0 = static_cast<std::uint32_t>(mx * 4u);
            const std::uint32_t y0 = top_row + static_cast<std::uint32_t>(local_y * 4u);
            std::int32_t u_sum = 0;
            std::int32_t v_sum = 0;
            std::int32_t *const v1 = scratch->v1_vectors + macroblock * kVectorDimensions;
            for (std::size_t q = 0u; q < 4u; ++q) {
                const std::uint32_t x = x0 + static_cast<std::uint32_t>(kQuadX[q]);
                const std::uint32_t y = y0 + static_cast<std::uint32_t>(kQuadY[q]);
                const std::size_t y_index = static_cast<std::size_t>(y) * width + x;
                const std::size_t uv_index = static_cast<std::size_t>(y / 2u) * uv_width + x / 2u;
                std::int32_t *const v4 =
                    scratch->v4_vectors + (macroblock * 4u + q) * kVectorDimensions;
                v4[0] = scratch->y[y_index];
                v4[1] = scratch->y[y_index + 1u];
                v4[2] = scratch->y[y_index + width];
                v4[3] = scratch->y[y_index + width + 1u];
                v4[4] = scratch->u[uv_index];
                v4[5] = scratch->v[uv_index];
                v1[q] = (v4[0] + v4[1] + v4[2] + v4[3] + 2) >> 2;
                u_sum += v4[4];
                v_sum += v4[5];
            }
            v1[4] = kotlin_round(static_cast<double>(u_sum) / 4.0);
            v1[5] = kotlin_round(static_cast<double>(v_sum) / 4.0);
        }
    }

    const std::size_t v1_count = vector_quantize(
        scratch->v1_vectors,
        macroblock_count,
        static_cast<std::size_t>(encoder.config.v1_size),
        encoder.config.refine_iterations,
        encoder.config.chroma_weight,
        scratch->v1_codebook,
        scratch->v1_labels,
        scratch);
    const bool mixed = encoder.config.quality > 20;
    std::size_t v4_count = 0u;
    if (mixed) {
        v4_count = vector_quantize(
            scratch->v4_vectors,
            macroblock_count * 4u,
            static_cast<std::size_t>(encoder.config.v4_size),
            encoder.config.refine_iterations,
            encoder.config.chroma_weight,
            scratch->v4_codebook,
            scratch->v4_labels,
            scratch);
    }
    std::memset(scratch->v4_decisions, 0, macroblock_count);
    const double threshold = mixed
        ? (2000.0 * (100 - encoder.config.quality) / 80.0)
        : std::numeric_limits<double>::infinity();
    if (mixed) {
        for (std::size_t local_y = 0u; local_y < macroblock_rows; ++local_y) {
            for (std::size_t mx = 0u; mx < macroblocks_x; ++mx) {
                const std::size_t macroblock = local_y * macroblocks_x + mx;
                const std::uint32_t x0 = static_cast<std::uint32_t>(mx * 4u);
                const std::uint32_t y0 = top_row + static_cast<std::uint32_t>(local_y * 4u);
                const std::int32_t *const v1 = scratch->v1_codebook +
                    scratch->v1_labels[macroblock] * kVectorDimensions;
                std::int64_t error_v1 = 0;
                std::int64_t error_v4 = 0;
                for (std::size_t q = 0u; q < 4u; ++q) {
                    const std::uint32_t x = x0 + static_cast<std::uint32_t>(kQuadX[q]);
                    const std::uint32_t y = y0 + static_cast<std::uint32_t>(kQuadY[q]);
                    const std::size_t y_index = static_cast<std::size_t>(y) * width + x;
                    const std::size_t uv_index = static_cast<std::size_t>(y / 2u) * uv_width + x / 2u;
                    const std::int32_t *const v4 = scratch->v4_codebook +
                        scratch->v4_labels[macroblock * 4u + q] * kVectorDimensions;
                    for (std::size_t d = 0u; d < 4u; ++d) {
                        const std::size_t source = y_index + (d / 2u) * width + (d & 1u);
                        const std::int32_t delta_v1 = scratch->y[source] - v1[q];
                        const std::int32_t delta_v4 = scratch->y[source] - v4[d];
                        error_v1 += static_cast<std::int64_t>(delta_v1) * delta_v1;
                        error_v4 += static_cast<std::int64_t>(delta_v4) * delta_v4;
                    }
                    const std::int32_t du1 = scratch->u[uv_index] - v1[4];
                    const std::int32_t dv1 = scratch->v[uv_index] - v1[5];
                    const std::int32_t du4 = scratch->u[uv_index] - v4[4];
                    const std::int32_t dv4 = scratch->v[uv_index] - v4[5];
                    error_v1 += static_cast<std::int64_t>(encoder.config.chroma_weight) *
                        (static_cast<std::int64_t>(du1) * du1 + static_cast<std::int64_t>(dv1) * dv1);
                    error_v4 += static_cast<std::int64_t>(encoder.config.chroma_weight) *
                        (static_cast<std::int64_t>(du4) * du4 + static_cast<std::int64_t>(dv4) * dv4);
                }
                if (static_cast<double>(error_v1 - error_v4) > threshold) {
                    scratch->v4_decisions[macroblock] = 1u;
                }
            }
        }
    }

    std::memset(scratch->skip, 0, macroblock_count);
    std::size_t coded_v4 = 0u;
    std::int16_t *const recon_y = scratch->reconstruction;
    std::int16_t *const recon_u = recon_y + encoder.pixel_count;
    std::int16_t *const recon_v = recon_u + encoder.uv_pixel_count;
    for (std::size_t local_y = 0u; local_y < macroblock_rows; ++local_y) {
        for (std::size_t mx = 0u; mx < macroblocks_x; ++mx) {
            const std::size_t macroblock = local_y * macroblocks_x + mx;
            const std::uint32_t x0 = static_cast<std::uint32_t>(mx * 4u);
            const std::uint32_t y0 = top_row + static_cast<std::uint32_t>(local_y * 4u);
            if (inter) {
                std::int64_t error = 0;
                for (std::size_t q = 0u; q < 4u; ++q) {
                    const std::uint32_t x = x0 + static_cast<std::uint32_t>(kQuadX[q]);
                    const std::uint32_t y = y0 + static_cast<std::uint32_t>(kQuadY[q]);
                    const std::size_t y_index = static_cast<std::size_t>(y) * width + x;
                    const std::size_t uv_index = static_cast<std::size_t>(y / 2u) * uv_width + x / 2u;
                    for (std::size_t d = 0u; d < 4u; ++d) {
                        const std::size_t source = y_index + (d / 2u) * width + (d & 1u);
                        const std::int32_t delta = scratch->y[source] - recon_y[source];
                        error += static_cast<std::int64_t>(delta) * delta;
                    }
                    const std::int32_t du = scratch->u[uv_index] - recon_u[uv_index];
                    const std::int32_t dv = scratch->v[uv_index] - recon_v[uv_index];
                    error += static_cast<std::int64_t>(encoder.config.chroma_weight) *
                        (static_cast<std::int64_t>(du) * du + static_cast<std::int64_t>(dv) * dv);
                }
                if (error <= encoder.config.skip_threshold) {
                    scratch->skip[macroblock] = 1u;
                    continue;
                }
            }
            const bool use_v4 = mixed && scratch->v4_decisions[macroblock] != 0u;
            if (use_v4) {
                ++coded_v4;
                const std::int32_t *entries[4]{};
                for (std::size_t q = 0u; q < 4u; ++q) {
                    entries[q] = scratch->v4_codebook +
                        scratch->v4_labels[macroblock * 4u + q] * kVectorDimensions;
                }
                paint_v4(
                    scratch->reconstruction,
                    encoder.pixel_count,
                    encoder.uv_pixel_count,
                    width,
                    x0,
                    y0,
                    entries);
            } else {
                paint_v1(
                    scratch->reconstruction,
                    encoder.pixel_count,
                    encoder.uv_pixel_count,
                    width,
                    x0,
                    y0,
                    scratch->v1_codebook +
                        scratch->v1_labels[macroblock] * kVectorDimensions);
            }
        }
    }
    const bool use_v4_chunk = mixed && coded_v4 != 0u;

    const std::size_t strip_start = writer->size;
    if (!writer->byte(inter ? 0x11u : 0x10u) || !writer->be24(0u) ||
        !writer->be16(0u) || !writer->be16(0u) ||
        !writer->be16(static_cast<std::uint32_t>(macroblock_rows * 4u)) ||
        !writer->be16(width) ||
        !write_codebook(writer, 0x22u, scratch->v1_codebook, v1_count) ||
        (use_v4_chunk && !write_codebook(writer, 0x20u, scratch->v4_codebook, v4_count))) {
        return HMC_STATUS_OVERFLOW;
    }

    const std::uint8_t vector_id = !inter && !use_v4_chunk
        ? 0x32u
        : static_cast<std::uint8_t>(inter ? 0x31u : 0x30u);
    const std::size_t vector_start = writer->size;
    if (!writer->byte(vector_id) || !writer->be24(0u)) {
        return HMC_STATUS_OVERFLOW;
    }
    if (vector_id == 0x32u) {
        for (std::size_t macroblock = 0u; macroblock < macroblock_count; ++macroblock) {
            if (!writer->byte(scratch->v1_labels[macroblock])) {
                return HMC_STATUS_OVERFLOW;
            }
        }
    } else {
        BitEmitter bits{writer, 0u, 0u};
        for (std::size_t macroblock = 0u; macroblock < macroblock_count; ++macroblock) {
            if (inter) {
                if (scratch->skip[macroblock] != 0u) {
                    if (!bits.emit(false)) {
                        return HMC_STATUS_OVERFLOW;
                    }
                    continue;
                }
                if (!bits.emit(true)) {
                    return HMC_STATUS_OVERFLOW;
                }
            }
            if (use_v4_chunk && scratch->v4_decisions[macroblock] != 0u) {
                if (!bits.emit(true)) {
                    return HMC_STATUS_OVERFLOW;
                }
                for (std::size_t q = 0u; q < 4u; ++q) {
                    if (!writer->byte(scratch->v4_labels[macroblock * 4u + q])) {
                        return HMC_STATUS_OVERFLOW;
                    }
                }
            } else {
                if (!bits.emit(false) || !writer->byte(scratch->v1_labels[macroblock])) {
                    return HMC_STATUS_OVERFLOW;
                }
            }
        }
    }
    const std::size_t vector_size = writer->size - vector_start;
    const std::size_t strip_size = writer->size - strip_start;
    if (!writer->patch_be24(vector_start + 1u, vector_size) ||
        !writer->patch_be24(strip_start + 1u, strip_size)) {
        return HMC_STATUS_OVERFLOW;
    }
    return HMC_STATUS_OK;
}

} // namespace

hmc_status_t cinepak_encoder_config_init(
    hmc_cinepak_encoder_config_t *config,
    std::uint32_t config_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config_size < HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    std::memset(config, 0, config_size);
    config->struct_size = config_size;
    config->quality = 60;
    config->v1_size = 256;
    config->v4_size = 256;
    config->refine_iterations = 3;
    config->chroma_weight = 4;
    config->strips = 2;
    config->skip_threshold = 720;
    config->key_interval = 0;
    return HMC_STATUS_OK;
}

hmc_status_t cinepak_encoder_create(
    const hmc_cinepak_encoder_config_t *config,
    hmc_cinepak_encoder_t **encoder) noexcept
{
    if (config == nullptr || encoder == nullptr || *encoder != nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config->struct_size < HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (!tail_is_zero(config, config->struct_size, HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    EncoderLimits limits{};
    const hmc_status_t validation = calculate_limits(*config, &limits);
    if (validation != HMC_STATUS_OK) {
        return validation;
    }
    auto *const candidate = static_cast<hmc_cinepak_encoder_t *>(
        allocate(sizeof(hmc_cinepak_encoder_t)));
    if (candidate == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    std::memset(candidate, 0, sizeof(*candidate));
    std::memcpy(&candidate->config, config, HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE);
    candidate->config.struct_size = HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE;
    candidate->pixel_count = limits.pixel_count;
    candidate->uv_pixel_count = limits.uv_pixel_count;
    candidate->rgba_size = limits.rgba_size;
    candidate->maximum_strip_macroblocks = limits.maximum_strip_macroblocks;
    candidate->maximum_frame_size = limits.maximum_frame_size;
    candidate->effective_strips = limits.effective_strips;
    candidate->last_key = -1;
    std::size_t reconstruction_count = 0u;
    if (!multiply_size(candidate->uv_pixel_count, 2u, &reconstruction_count) ||
        !add_size(reconstruction_count, candidate->pixel_count, &reconstruction_count)) {
        deallocate(candidate);
        return HMC_STATUS_OVERFLOW;
    }
    const hmc_status_t allocation = allocate_array(reconstruction_count, &candidate->reconstruction);
    if (allocation != HMC_STATUS_OK) {
        deallocate(candidate);
        return allocation;
    }
    void *const scratch_memory = allocate(sizeof(Scratch));
    if (scratch_memory == nullptr) {
        deallocate(candidate->reconstruction);
        deallocate(candidate);
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    auto *const scratch = ::new (scratch_memory) Scratch{};
    candidate->scratch = scratch;
    const hmc_status_t scratch_allocation = allocate_scratch(*candidate, scratch);
    if (scratch_allocation != HMC_STATUS_OK) {
        scratch->~Scratch();
        deallocate(scratch_memory);
        deallocate(candidate->reconstruction);
        deallocate(candidate);
        return scratch_allocation;
    }
    std::memset(candidate->reconstruction, 0, reconstruction_count * sizeof(*candidate->reconstruction));
    *encoder = candidate;
    return HMC_STATUS_OK;
}

hmc_status_t cinepak_encoder_reset(hmc_cinepak_encoder_t *encoder) noexcept
{
    if (encoder == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    std::size_t reconstruction_count = encoder->pixel_count + encoder->uv_pixel_count * 2u;
    std::memset(encoder->reconstruction, 0, reconstruction_count * sizeof(*encoder->reconstruction));
    encoder->frame_index = 0u;
    encoder->last_key = -1;
    return HMC_STATUS_OK;
}

void cinepak_encoder_destroy(hmc_cinepak_encoder_t *encoder) noexcept
{
    if (encoder == nullptr) {
        return;
    }
    auto *const scratch = static_cast<Scratch *>(encoder->scratch);
    if (scratch != nullptr) {
        scratch->~Scratch();
        deallocate(scratch);
    }
    deallocate(encoder->reconstruction);
    deallocate(encoder);
}

hmc_status_t cinepak_encoder_encode(
    hmc_cinepak_encoder_t *encoder,
    const std::uint8_t *rgba,
    std::size_t rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags) noexcept
{
    if (encoder == nullptr || rgba == nullptr || output == nullptr ||
        output_frame_flags == nullptr || output->data != nullptr || output->size != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if ((encode_flags & ~kKnownEncodeFlags) != 0u) {
        return HMC_STATUS_UNSUPPORTED;
    }
    if (rgba_size < encoder->rgba_size) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }

    auto *const scratch = static_cast<Scratch *>(encoder->scratch);
    OwnedFrame frame;
    const hmc_status_t frame_status = allocate_array(encoder->maximum_frame_size, &frame.data);
    if (frame_status != HMC_STATUS_OK) {
        return frame_status;
    }
    std::size_t reconstruction_count = encoder->pixel_count + encoder->uv_pixel_count * 2u;
    std::memcpy(
        scratch->reconstruction,
        encoder->reconstruction,
        reconstruction_count * sizeof(*scratch->reconstruction));
    rgb_to_yuv(
        rgba,
        encoder->config.width,
        encoder->config.height,
        scratch->y,
        scratch->u,
        scratch->v);

    bool key = (encode_flags & HMC_ENCODE_FLAG_FORCE_KEY) != 0u || encoder->frame_index == 0u;
    if (!key && encoder->config.key_interval > 0) {
        const std::uint64_t last = static_cast<std::uint64_t>(encoder->last_key);
        key = encoder->frame_index - last >= static_cast<std::uint64_t>(encoder->config.key_interval);
    }
    Writer writer{frame.data, encoder->maximum_frame_size, 0u};
    if (!writer.byte(key ? 0u : 1u) || !writer.be24(0u) ||
        !writer.be16(encoder->config.width) || !writer.be16(encoder->config.height) ||
        !writer.be16(encoder->effective_strips)) {
        return HMC_STATUS_OVERFLOW;
    }
    const std::size_t macroblock_rows = encoder->config.height / 4u;
    std::size_t row_start = 0u;
    for (std::size_t strip = 0u; strip < encoder->effective_strips; ++strip) {
        const std::size_t rows =
            (macroblock_rows - row_start) / (encoder->effective_strips - strip);
        const hmc_status_t status = encode_strip(
            *encoder, scratch, &writer, row_start, rows, !key);
        if (status != HMC_STATUS_OK) {
            return status;
        }
        row_start += rows;
    }
    if (!writer.patch_be24(1u, writer.size)) {
        return HMC_STATUS_OVERFLOW;
    }

    std::uint8_t *const published = frame.release();
    std::memcpy(
        encoder->reconstruction,
        scratch->reconstruction,
        reconstruction_count * sizeof(*scratch->reconstruction));
    if (key) {
        encoder->last_key = static_cast<std::int64_t>(encoder->frame_index);
    }
    ++encoder->frame_index;
    output->data = published;
    output->size = writer.size;
    *output_frame_flags = key
        ? HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN
        : HMC_FRAME_FLAG_KEY_KNOWN;
    return HMC_STATUS_OK;
}

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void cinepak_encoder_test_reset_nearest_conversion_diagnostics() noexcept
{
    g_nearest_conversion_diagnostics = {};
}

HMC_API CinepakNearestConversionDiagnostics
cinepak_encoder_test_nearest_conversion_diagnostics() noexcept
{
    return g_nearest_conversion_diagnostics;
}

HMC_API std::int32_t cinepak_encoder_test_floor_divide_power_of_two(
    std::int64_t value) noexcept
{
    return floor_divide_power_of_two(value, 23u);
}

HMC_API std::int32_t cinepak_encoder_test_kotlin_round(double value) noexcept
{
    return kotlin_round(value);
}

HMC_API void cinepak_encoder_test_rgb_to_yuv(
    const std::uint8_t *rgba,
    std::uint32_t width,
    std::uint32_t height,
    std::int32_t *y,
    std::int32_t *u,
    std::int32_t *v) noexcept
{
    rgb_to_yuv(rgba, width, height, y, u, v);
}

HMC_API hmc_status_t cinepak_encoder_test_vector_quantize(
    const std::int32_t *data,
    std::size_t count,
    std::size_t maximum_codebook,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::int32_t *codebook,
    std::uint32_t *labels,
    std::size_t *codebook_count) noexcept
{
    if (data == nullptr || count == 0u || maximum_codebook == 0u ||
        maximum_codebook > kCodebookMaximum || refine_iterations < 0 ||
        chroma_weight < 0 || codebook == nullptr || labels == nullptr ||
        codebook_count == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    Scratch scratch;
    hmc_status_t status = allocate_array(count, &scratch.indices);
    if (status == HMC_STATUS_OK) {
        status = allocate_array(count, &scratch.temporary_indices);
    }
    if (status == HMC_STATUS_OK) {
        status = allocate_array(kCodebookMaximum * kVectorDimensions, &scratch.centroids);
    }
    if (status == HMC_STATUS_OK) {
        status = allocate_array(kCodebookMaximum * kVectorDimensions, &scratch.sums);
    }
    if (status == HMC_STATUS_OK) {
        status = allocate_array(kCodebookMaximum, &scratch.counts);
    }
    if (status != HMC_STATUS_OK) {
        return status;
    }
    *codebook_count = vector_quantize(
        data,
        count,
        maximum_codebook,
        refine_iterations,
        chroma_weight,
        codebook,
        labels,
        &scratch);
    return HMC_STATUS_OK;
}

HMC_API hmc_status_t cinepak_encoder_test_lloyd_refine(
    const std::int32_t *data,
    std::size_t count,
    std::int32_t *codebook,
    std::size_t codebook_count,
    std::int32_t refine_iterations,
    std::int32_t chroma_weight,
    std::uint32_t *labels) noexcept
{
    if (data == nullptr || count == 0u || codebook == nullptr ||
        codebook_count == 0u || codebook_count > kCodebookMaximum ||
        refine_iterations < 0 || chroma_weight < 0 || labels == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    Scratch scratch;
    hmc_status_t status =
        allocate_array(kCodebookMaximum * kVectorDimensions, &scratch.centroids);
    if (status == HMC_STATUS_OK) {
        status = allocate_array(kCodebookMaximum * kVectorDimensions, &scratch.sums);
    }
    if (status == HMC_STATUS_OK) {
        status = allocate_array(kCodebookMaximum, &scratch.counts);
    }
    if (status != HMC_STATUS_OK) {
        return status;
    }
    lloyd_refine(
        data,
        count,
        codebook_count,
        refine_iterations,
        chroma_weight,
        codebook,
        labels,
        &scratch);
    return HMC_STATUS_OK;
}

HMC_API std::size_t cinepak_encoder_test_nearest_codebook(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight) noexcept
{
    const double weight = static_cast<double>(chroma_weight);
    ++g_nearest_conversion_diagnostics.weight_conversions;
    return nearest_codebook(
        data, centroids, codebook_count, weight);
}

HMC_API std::size_t cinepak_encoder_test_nearest_codebook_with_term_count(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight,
    std::size_t *evaluated_terms) noexcept
{
    const double weight = static_cast<double>(chroma_weight);
    ++g_nearest_conversion_diagnostics.weight_conversions;
    return nearest_codebook(
        data, centroids, codebook_count, weight, evaluated_terms);
}

HMC_API void cinepak_encoder_test_fail_nth_allocation(
    std::size_t allocation_number) noexcept
{
    allocation_test_fail_nth(allocation_number);
}

HMC_API void cinepak_encoder_test_clear_allocation_failure() noexcept
{
    allocation_test_clear_failure();
}

HMC_API std::size_t cinepak_encoder_test_allocation_count() noexcept
{
    return allocation_test_count();
}
#endif

} // namespace honey::media
