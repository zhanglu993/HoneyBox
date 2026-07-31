#include "cinepak_decoder.hpp"

#include "allocator.hpp"
#include "cinepak_common.hpp"
#include "core_types.hpp"

#include <cstdint>
#include <cstring>
#include <limits>

namespace honey::media {
namespace {

constexpr std::uint8_t kKeyFrame = 0u;
constexpr std::uint8_t kInterFrame = 1u;
constexpr std::uint8_t kKeyStrip = 0x10u;
constexpr std::uint8_t kInterStrip = 0x11u;
constexpr std::uint8_t kV4Codebook = 0x20u;
constexpr std::uint8_t kV1Codebook = 0x22u;
constexpr std::uint8_t kKeyMixedVectors = 0x30u;
constexpr std::uint8_t kInterVectors = 0x31u;
constexpr std::uint8_t kAllV1Vectors = 0x32u;

std::uint16_t read_be16(const std::uint8_t *bytes) noexcept
{
    return static_cast<std::uint16_t>(
        (static_cast<std::uint16_t>(bytes[0]) << 8u) |
        static_cast<std::uint16_t>(bytes[1]));
}

std::uint32_t read_be24(const std::uint8_t *bytes) noexcept
{
    return (static_cast<std::uint32_t>(bytes[0]) << 16u) |
           (static_cast<std::uint32_t>(bytes[1]) << 8u) |
           static_cast<std::uint32_t>(bytes[2]);
}

std::uint32_t read_be32(const std::uint8_t *bytes) noexcept
{
    return (static_cast<std::uint32_t>(bytes[0]) << 24u) |
           (static_cast<std::uint32_t>(bytes[1]) << 16u) |
           (static_cast<std::uint32_t>(bytes[2]) << 8u) |
           static_cast<std::uint32_t>(bytes[3]);
}

bool span_is_zero(
    const void *data,
    std::size_t begin,
    std::size_t end) noexcept
{
    const auto *bytes = static_cast<const std::uint8_t *>(data);
    for (std::size_t i = begin; i < end; ++i) {
        if (bytes[i] != 0u) {
            return false;
        }
    }
    return true;
}

hmc_status_t validate_config(
    const hmc_cinepak_decoder_config_t *config) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config->struct_size < HMC_CINEPAK_DECODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (!span_is_zero(
            config,
            HMC_CINEPAK_DECODER_CONFIG_V1_SIZE,
            config->struct_size)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    return HMC_STATUS_OK;
}

hmc_status_t validate_dimensions(
    std::uint32_t width,
    std::uint32_t height,
    std::size_t *pixel_count,
    std::size_t *uv_pixel_count,
    std::size_t *plane_element_count,
    std::size_t *plane_bytes,
    std::size_t *argb_bytes) noexcept
{
    if (width == 0u || height == 0u ||
        width > UINT16_MAX || height > UINT16_MAX ||
        (width & 3u) != 0u || (height & 3u) != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    std::size_t pixels = 0u;
    std::size_t uv_pixels = 0u;
    std::size_t twice_uv = 0u;
    std::size_t plane_elements = 0u;
    std::size_t plane_size = 0u;
    std::size_t output_size = 0u;
    if (!checked_multiply_size(width, height, &pixels) ||
        !checked_multiply_size(width / 2u, height / 2u, &uv_pixels) ||
        !checked_multiply_size(uv_pixels, 2u, &twice_uv) ||
        !checked_add_size(pixels, twice_uv, &plane_elements) ||
        !checked_multiply_size(
            plane_elements, sizeof(std::int16_t), &plane_size) ||
        !checked_multiply_size(
            pixels, sizeof(std::uint32_t), &output_size)) {
        return HMC_STATUS_OVERFLOW;
    }

    *pixel_count = pixels;
    *uv_pixel_count = uv_pixels;
    *plane_element_count = plane_elements;
    *plane_bytes = plane_size;
    *argb_bytes = output_size;
    return HMC_STATUS_OK;
}

bool ranges_overlap(
    const void *left,
    std::size_t left_size,
    const void *right,
    std::size_t right_size) noexcept
{
    if (left_size == 0u || right_size == 0u) {
        return false;
    }
    const std::uintptr_t left_begin =
        reinterpret_cast<std::uintptr_t>(left);
    const std::uintptr_t right_begin =
        reinterpret_cast<std::uintptr_t>(right);
    if (left_size > std::numeric_limits<std::uintptr_t>::max() - left_begin ||
        right_size > std::numeric_limits<std::uintptr_t>::max() - right_begin) {
        return true;
    }
    const std::uintptr_t left_end = left_begin + left_size;
    const std::uintptr_t right_end = right_begin + right_size;
    return left_begin < right_end && right_begin < left_end;
}

struct Planes {
    std::int16_t *y;
    std::int16_t *u;
    std::int16_t *v;
};

Planes split_planes(
    std::int16_t *planes,
    std::size_t pixel_count,
    std::size_t uv_pixel_count) noexcept
{
    return Planes{
        planes,
        planes + pixel_count,
        planes + pixel_count + uv_pixel_count};
}

void read_codebook_entry(
    const std::uint8_t *bytes,
    CinepakCodebookEntry *entry) noexcept
{
    for (std::size_t i = 0u; i < 4u; ++i) {
        entry->y[i] = bytes[i];
    }
    entry->u = decode_cinepak_signed_byte(bytes[4u]);
    entry->v = decode_cinepak_signed_byte(bytes[5u]);
}

void paint_v1(
    const hmc_cinepak_decoder_t *decoder,
    Planes planes,
    std::uint32_t x0,
    std::uint32_t y0,
    const CinepakCodebookEntry &entry) noexcept
{
    constexpr std::uint32_t quad_x[4] = {0u, 2u, 0u, 2u};
    constexpr std::uint32_t quad_y[4] = {0u, 0u, 2u, 2u};
    for (std::size_t quadrant = 0u; quadrant < 4u; ++quadrant) {
        const std::uint32_t x = x0 + quad_x[quadrant];
        const std::uint32_t y = y0 + quad_y[quadrant];
        const std::size_t top =
            static_cast<std::size_t>(y) * decoder->config.width + x;
        const std::size_t bottom = top + decoder->config.width;
        planes.y[top] = entry.y[quadrant];
        planes.y[top + 1u] = entry.y[quadrant];
        planes.y[bottom] = entry.y[quadrant];
        planes.y[bottom + 1u] = entry.y[quadrant];
    }

    const std::uint32_t uv_width = decoder->config.width / 2u;
    const std::size_t uv_top =
        static_cast<std::size_t>(y0 / 2u) * uv_width + x0 / 2u;
    const std::size_t uv_bottom = uv_top + uv_width;
    planes.u[uv_top] = entry.u;
    planes.u[uv_top + 1u] = entry.u;
    planes.u[uv_bottom] = entry.u;
    planes.u[uv_bottom + 1u] = entry.u;
    planes.v[uv_top] = entry.v;
    planes.v[uv_top + 1u] = entry.v;
    planes.v[uv_bottom] = entry.v;
    planes.v[uv_bottom + 1u] = entry.v;
}

void paint_v4(
    const hmc_cinepak_decoder_t *decoder,
    Planes planes,
    std::uint32_t x0,
    std::uint32_t y0,
    const CinepakCodebookEntry *const entries[4]) noexcept
{
    constexpr std::uint32_t quad_x[4] = {0u, 2u, 0u, 2u};
    constexpr std::uint32_t quad_y[4] = {0u, 0u, 2u, 2u};
    for (std::size_t quadrant = 0u; quadrant < 4u; ++quadrant) {
        const std::uint32_t x = x0 + quad_x[quadrant];
        const std::uint32_t y = y0 + quad_y[quadrant];
        const std::size_t top =
            static_cast<std::size_t>(y) * decoder->config.width + x;
        const std::size_t bottom = top + decoder->config.width;
        planes.y[top] = entries[quadrant]->y[0u];
        planes.y[top + 1u] = entries[quadrant]->y[1u];
        planes.y[bottom] = entries[quadrant]->y[2u];
        planes.y[bottom + 1u] = entries[quadrant]->y[3u];
    }

    const std::uint32_t uv_width = decoder->config.width / 2u;
    const std::size_t uv_top =
        static_cast<std::size_t>(y0 / 2u) * uv_width + x0 / 2u;
    const std::size_t uv_bottom = uv_top + uv_width;
    planes.u[uv_top] = entries[0u]->u;
    planes.u[uv_top + 1u] = entries[1u]->u;
    planes.u[uv_bottom] = entries[2u]->u;
    planes.u[uv_bottom + 1u] = entries[3u]->u;
    planes.v[uv_top] = entries[0u]->v;
    planes.v[uv_top + 1u] = entries[1u]->v;
    planes.v[uv_bottom] = entries[2u]->v;
    planes.v[uv_bottom + 1u] = entries[3u]->v;
}

class InterleavedBitReader {
public:
    InterleavedBitReader(
        const std::uint8_t *bytes,
        std::size_t size) noexcept
        : bytes_(bytes), size_(size), cursor_(0u), word_(0u), mask_(0u)
    {
    }

    bool read_bit(bool *value) noexcept
    {
        if (mask_ == 0u) {
            if (size_ - cursor_ < 4u) {
                return false;
            }
            word_ = read_be32(bytes_ + cursor_);
            cursor_ += 4u;
            mask_ = UINT32_C(0x80000000);
        }
        *value = (word_ & mask_) != 0u;
        mask_ >>= 1u;
        return true;
    }

    bool read_byte(std::uint8_t *value) noexcept
    {
        if (cursor_ == size_) {
            return false;
        }
        *value = bytes_[cursor_++];
        return true;
    }

    bool consumed_all() const noexcept
    {
        return cursor_ == size_;
    }

private:
    const std::uint8_t *bytes_;
    std::size_t size_;
    std::size_t cursor_;
    std::uint32_t word_;
    std::uint32_t mask_;
};

hmc_status_t decode_vector_chunk(
    const hmc_cinepak_decoder_t *decoder,
    Planes planes,
    std::uint8_t frame_flags,
    std::uint8_t vector_id,
    const std::uint8_t *body,
    std::size_t body_size,
    std::uint32_t top_row,
    std::uint32_t macroblock_rows,
    const CinepakCodebookEntry *v1,
    std::size_t v1_count,
    const CinepakCodebookEntry *v4,
    std::size_t v4_count) noexcept
{
    const std::size_t macroblock_columns = decoder->config.width / 4u;
    std::size_t macroblock_count = 0u;
    if (!checked_multiply_size(
            macroblock_columns, macroblock_rows, &macroblock_count)) {
        return HMC_STATUS_OVERFLOW;
    }
    if ((frame_flags == kKeyFrame &&
         vector_id != kAllV1Vectors &&
         vector_id != kKeyMixedVectors) ||
        (frame_flags == kInterFrame && vector_id != kInterVectors)) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    if (vector_id == kAllV1Vectors) {
        if (body_size != macroblock_count) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        if (v1_count == 0u) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        for (std::size_t block = 0u; block < macroblock_count; ++block) {
            const std::size_t index = body[block];
            if (index >= v1_count) {
                return HMC_STATUS_MALFORMED_DATA;
            }
            const std::uint32_t x =
                static_cast<std::uint32_t>(block % macroblock_columns) * 4u;
            const std::uint32_t y =
                top_row +
                static_cast<std::uint32_t>(block / macroblock_columns) * 4u;
            paint_v1(decoder, planes, x, y, v1[index]);
        }
        return HMC_STATUS_OK;
    }

    InterleavedBitReader reader(body, body_size);
    for (std::size_t block = 0u; block < macroblock_count; ++block) {
        bool coded = true;
        if (vector_id == kInterVectors &&
            (!reader.read_bit(&coded))) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        if (!coded) {
            continue;
        }

        bool use_v4 = false;
        if (!reader.read_bit(&use_v4)) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        const std::uint32_t x =
            static_cast<std::uint32_t>(block % macroblock_columns) * 4u;
        const std::uint32_t y =
            top_row +
            static_cast<std::uint32_t>(block / macroblock_columns) * 4u;
        if (use_v4) {
            std::uint8_t indexes[4]{};
            const CinepakCodebookEntry *entries[4]{};
            for (std::size_t i = 0u; i < 4u; ++i) {
                if (!reader.read_byte(&indexes[i]) ||
                    indexes[i] >= v4_count) {
                    return HMC_STATUS_MALFORMED_DATA;
                }
                entries[i] = &v4[indexes[i]];
            }
            paint_v4(decoder, planes, x, y, entries);
        } else {
            std::uint8_t index = 0u;
            if (!reader.read_byte(&index) || index >= v1_count) {
                return HMC_STATUS_MALFORMED_DATA;
            }
            paint_v1(decoder, planes, x, y, v1[index]);
        }
    }
    return reader.consumed_all()
        ? HMC_STATUS_OK
        : HMC_STATUS_MALFORMED_DATA;
}

bool is_unsupported_codebook(std::uint8_t id) noexcept
{
    return id == 0x21u || id == 0x23u ||
           (id >= 0x24u && id <= 0x27u);
}

hmc_status_t decode_strip(
    const hmc_cinepak_decoder_t *decoder,
    Planes planes,
    std::uint8_t frame_flags,
    const std::uint8_t *strip,
    std::size_t strip_size,
    std::uint32_t top_row,
    std::uint32_t macroblock_rows) noexcept
{
    CinepakCodebookEntry v1[256]{};
    CinepakCodebookEntry v4[256]{};
    std::size_t v1_count = 0u;
    std::size_t v4_count = 0u;
    bool has_v1 = false;
    bool has_v4 = false;
    bool has_vector = false;
    std::size_t cursor = 12u;
    while (cursor < strip_size) {
        if (strip_size - cursor < 4u) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        const std::uint8_t id = strip[cursor];
        const std::size_t chunk_size = read_be24(strip + cursor + 1u);
        if (chunk_size < 4u || chunk_size > strip_size - cursor) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        if (is_unsupported_codebook(id)) {
            return HMC_STATUS_UNSUPPORTED;
        }
        if (id != kV1Codebook && id != kV4Codebook &&
            id != kAllV1Vectors && id != kKeyMixedVectors &&
            id != kInterVectors) {
            return HMC_STATUS_UNSUPPORTED;
        }
        if (has_vector) {
            return HMC_STATUS_MALFORMED_DATA;
        }

        const std::uint8_t *body = strip + cursor + 4u;
        const std::size_t body_size = chunk_size - 4u;
        if (id == kV1Codebook || id == kV4Codebook) {
            bool *has_codebook =
                id == kV1Codebook ? &has_v1 : &has_v4;
            std::size_t *entry_count =
                id == kV1Codebook ? &v1_count : &v4_count;
            CinepakCodebookEntry *entries =
                id == kV1Codebook ? v1 : v4;
            if (*has_codebook || body_size == 0u ||
                (body_size % 6u) != 0u || body_size / 6u > 256u) {
                return HMC_STATUS_MALFORMED_DATA;
            }
            *has_codebook = true;
            *entry_count = body_size / 6u;
            for (std::size_t i = 0u; i < *entry_count; ++i) {
                read_codebook_entry(body + i * 6u, &entries[i]);
            }
        } else {
            has_vector = true;
            const hmc_status_t status = decode_vector_chunk(
                decoder,
                planes,
                frame_flags,
                id,
                body,
                body_size,
                top_row,
                macroblock_rows,
                v1,
                v1_count,
                v4,
                v4_count);
            if (status != HMC_STATUS_OK) {
                return status;
            }
        }
        cursor += chunk_size;
    }
    return has_vector ? HMC_STATUS_OK : HMC_STATUS_MALFORMED_DATA;
}

int floor_divide_two(int value) noexcept
{
    return value >= 0 ? value / 2 : -((-value + 1) / 2);
}

std::uint8_t clip_byte(int value) noexcept
{
    if (value < 0) {
        return 0u;
    }
    if (value > 255) {
        return 255u;
    }
    return static_cast<std::uint8_t>(value);
}

void convert_to_argb(
    const hmc_cinepak_decoder_t *decoder,
    Planes planes,
    std::uint32_t *argb) noexcept
{
    const std::uint32_t width = decoder->config.width;
    const std::uint32_t height = decoder->config.height;
    const std::uint32_t uv_width = width / 2u;
    for (std::uint32_t y = 0u; y < height; ++y) {
        for (std::uint32_t x = 0u; x < width; ++x) {
            const std::size_t pixel =
                static_cast<std::size_t>(y) * width + x;
            const std::size_t chroma =
                static_cast<std::size_t>(y / 2u) * uv_width + x / 2u;
            const int luma = planes.y[pixel];
            const int u = planes.u[chroma];
            const int v = planes.v[chroma];
            const std::uint32_t red = clip_byte(luma + 2 * v);
            const std::uint32_t green =
                clip_byte(luma - floor_divide_two(u) - v);
            const std::uint32_t blue = clip_byte(luma + 2 * u);
            argb[pixel] = UINT32_C(0xff000000) |
                          (red << 16u) |
                          (green << 8u) |
                          blue;
        }
    }
}

} // namespace

hmc_status_t cinepak_decoder_config_init(
    hmc_cinepak_decoder_config_t *config,
    std::uint32_t config_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config_size < HMC_CINEPAK_DECODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    std::memset(config, 0, config_size);
    config->struct_size = config_size;
    return HMC_STATUS_OK;
}

hmc_status_t cinepak_decoder_create(
    const hmc_cinepak_decoder_config_t *config,
    hmc_cinepak_decoder_t **decoder) noexcept
{
    if (decoder == nullptr || *decoder != nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const hmc_status_t config_status = validate_config(config);
    if (config_status != HMC_STATUS_OK) {
        return config_status;
    }

    std::size_t pixel_count = 0u;
    std::size_t uv_pixel_count = 0u;
    std::size_t plane_element_count = 0u;
    std::size_t plane_bytes = 0u;
    std::size_t argb_bytes = 0u;
    const hmc_status_t dimension_status = validate_dimensions(
        config->width,
        config->height,
        &pixel_count,
        &uv_pixel_count,
        &plane_element_count,
        &plane_bytes,
        &argb_bytes);
    if (dimension_status != HMC_STATUS_OK) {
        return dimension_status;
    }
    (void)argb_bytes;

    auto *candidate =
        static_cast<hmc_cinepak_decoder_t *>(
            allocate(sizeof(hmc_cinepak_decoder_t)));
    if (candidate == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    candidate->planes =
        static_cast<std::int16_t *>(allocate(plane_bytes));
    if (candidate->planes == nullptr) {
        deallocate(candidate);
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    candidate->config = *config;
    candidate->pixel_count = pixel_count;
    candidate->uv_pixel_count = uv_pixel_count;
    candidate->plane_element_count = plane_element_count;
    candidate->plane_bytes = plane_bytes;
    candidate->has_reference = false;
    std::memset(candidate->planes, 0, plane_bytes);
    *decoder = candidate;
    return HMC_STATUS_OK;
}

hmc_status_t cinepak_decoder_reset(
    hmc_cinepak_decoder_t *decoder) noexcept
{
    if (decoder == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    std::memset(decoder->planes, 0, decoder->plane_bytes);
    decoder->has_reference = false;
    return HMC_STATUS_OK;
}

void cinepak_decoder_destroy(
    hmc_cinepak_decoder_t *decoder) noexcept
{
    if (decoder == nullptr) {
        return;
    }
    deallocate(decoder->planes);
    deallocate(decoder);
}

hmc_status_t cinepak_decoder_decode(
    hmc_cinepak_decoder_t *decoder,
    const std::uint8_t *encoded,
    std::size_t encoded_size,
    std::uint32_t *argb,
    std::size_t argb_pixel_count) noexcept
{
    if (decoder == nullptr || encoded == nullptr || argb == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (argb_pixel_count < decoder->pixel_count) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (encoded_size < 10u) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    std::size_t argb_bytes = 0u;
    std::size_t argb_capacity_bytes = 0u;
    if (!checked_multiply_size(
            decoder->pixel_count, sizeof(std::uint32_t), &argb_bytes) ||
        !checked_multiply_size(
            argb_pixel_count,
            sizeof(std::uint32_t),
            &argb_capacity_bytes)) {
        return HMC_STATUS_OVERFLOW;
    }
    if (ranges_overlap(
            encoded, encoded_size, argb, argb_capacity_bytes) ||
        ranges_overlap(
            encoded, encoded_size, decoder, sizeof(*decoder)) ||
        ranges_overlap(
            encoded, encoded_size, decoder->planes, decoder->plane_bytes) ||
        ranges_overlap(
            argb, argb_capacity_bytes, decoder, sizeof(*decoder)) ||
        ranges_overlap(
            argb,
            argb_capacity_bytes,
            decoder->planes,
            decoder->plane_bytes)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    const std::uint8_t frame_flags = encoded[0u];
    const std::size_t declared_size = read_be24(encoded + 1u);
    const std::uint32_t width = read_be16(encoded + 4u);
    const std::uint32_t height = read_be16(encoded + 6u);
    const std::uint32_t strip_count = read_be16(encoded + 8u);
    if ((frame_flags != kKeyFrame && frame_flags != kInterFrame) ||
        declared_size != encoded_size ||
        width != decoder->config.width ||
        height != decoder->config.height ||
        strip_count == 0u ||
        strip_count > height / 4u) {
        return HMC_STATUS_MALFORMED_DATA;
    }
    if (frame_flags == kInterFrame && !decoder->has_reference) {
        return HMC_STATUS_INVALID_STATE;
    }

    std::size_t scratch_size = 0u;
    if (!checked_add_size(
            decoder->plane_bytes, argb_bytes, &scratch_size)) {
        return HMC_STATUS_OVERFLOW;
    }
    auto *scratch = static_cast<std::uint8_t *>(allocate(scratch_size));
    if (scratch == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    auto *candidate_planes =
        reinterpret_cast<std::int16_t *>(scratch);
    auto *candidate_argb =
        reinterpret_cast<std::uint32_t *>(
            scratch + decoder->plane_bytes);
    std::memcpy(
        candidate_planes, decoder->planes, decoder->plane_bytes);
    const Planes planes = split_planes(
        candidate_planes,
        decoder->pixel_count,
        decoder->uv_pixel_count);

    hmc_status_t status = HMC_STATUS_OK;
    std::size_t cursor = 10u;
    std::uint32_t top_row = 0u;
    for (std::uint32_t strip_index = 0u;
         strip_index < strip_count;
         ++strip_index) {
        if (encoded_size - cursor < 12u) {
            status = HMC_STATUS_MALFORMED_DATA;
            break;
        }
        const std::uint8_t expected_strip =
            frame_flags == kKeyFrame ? kKeyStrip : kInterStrip;
        const std::size_t strip_size =
            read_be24(encoded + cursor + 1u);
        const std::uint32_t strip_top =
            read_be16(encoded + cursor + 4u);
        const std::uint32_t strip_left =
            read_be16(encoded + cursor + 6u);
        const std::uint32_t band_height =
            read_be16(encoded + cursor + 8u);
        const std::uint32_t strip_right =
            read_be16(encoded + cursor + 10u);
        if (encoded[cursor] != expected_strip ||
            strip_size < 12u ||
            strip_size > encoded_size - cursor ||
            strip_top != 0u ||
            strip_left != 0u ||
            strip_right != width ||
            band_height == 0u ||
            (band_height & 3u) != 0u ||
            band_height > height - top_row) {
            status = HMC_STATUS_MALFORMED_DATA;
            break;
        }
        status = decode_strip(
            decoder,
            planes,
            frame_flags,
            encoded + cursor,
            strip_size,
            top_row,
            band_height / 4u);
        if (status != HMC_STATUS_OK) {
            break;
        }
        top_row += band_height;
        cursor += strip_size;
    }
    if (status == HMC_STATUS_OK &&
        (top_row != height || cursor != encoded_size)) {
        status = HMC_STATUS_MALFORMED_DATA;
    }
    if (status == HMC_STATUS_OK) {
        convert_to_argb(decoder, planes, candidate_argb);
        std::memcpy(
            decoder->planes, candidate_planes, decoder->plane_bytes);
        decoder->has_reference = true;
        std::memcpy(argb, candidate_argb, argb_bytes);
    }
    deallocate(scratch);
    return status;
}

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void cinepak_decoder_test_fail_nth_allocation(
    std::size_t allocation_number) noexcept
{
    allocation_test_fail_nth(allocation_number);
}

HMC_API void cinepak_decoder_test_clear_allocation_failure() noexcept
{
    allocation_test_clear_failure();
}

HMC_API std::size_t cinepak_decoder_test_allocation_count() noexcept
{
    return allocation_test_count();
}
#endif

} // namespace honey::media
