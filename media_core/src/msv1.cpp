#include "msv1.hpp"

#include "allocator.hpp"
#include "core_types.hpp"

#include <cstdlib>
#include <cstring>
#include <limits>

namespace honey::media {
namespace {

constexpr std::uint8_t kScan[16] = {
    12u, 13u, 14u, 15u, 8u, 9u, 10u, 11u,
    4u, 5u, 6u, 7u, 0u, 1u, 2u, 3u};

bool span_is_zero(const void *data, std::size_t begin, std::size_t end) noexcept
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
    const void *config,
    std::uint32_t struct_size,
    std::uint32_t v1_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (struct_size < v1_size) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (!span_is_zero(config, v1_size, struct_size)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    return HMC_STATUS_OK;
}

hmc_status_t validate_dimensions(
    std::uint32_t width,
    std::uint32_t height,
    std::size_t *pixel_count,
    std::size_t *rgba_bytes,
    std::size_t *block_count) noexcept
{
    if (width == 0u || height == 0u ||
        (width & 3u) != 0u || (height & 3u) != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    std::size_t pixels = 0u;
    std::size_t bytes = 0u;
    std::size_t blocks = 0u;
    if (!checked_multiply_size(width, height, &pixels) ||
        !checked_multiply_size(pixels, 4u, &bytes) ||
        !checked_multiply_size(width / 4u, height / 4u, &blocks)) {
        return HMC_STATUS_OVERFLOW;
    }
    *pixel_count = pixels;
    *rgba_bytes = bytes;
    *block_count = blocks;
    return HMC_STATUS_OK;
}

std::uint16_t rgb555(std::uint8_t r, std::uint8_t g, std::uint8_t b) noexcept
{
    return static_cast<std::uint16_t>(
        ((static_cast<std::uint16_t>(r) >> 3u) << 10u) |
        ((static_cast<std::uint16_t>(g) >> 3u) << 5u) |
        (static_cast<std::uint16_t>(b) >> 3u));
}

bool is_skip_color(std::uint16_t word) noexcept
{
    return ((word >> 8u) & 0xfcu) == 0x84u;
}

void write_word(std::uint8_t *bytes, std::size_t *size, std::uint16_t word) noexcept
{
    bytes[*size] = static_cast<std::uint8_t>(word);
    bytes[*size + 1u] = static_cast<std::uint8_t>(word >> 8u);
    *size += 2u;
}

std::uint16_t read_word(const std::uint8_t *bytes, std::size_t *offset) noexcept
{
    const std::uint16_t word = static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(bytes[*offset]) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(bytes[*offset + 1u]) << 8u));
    *offset += 2u;
    return word;
}

bool block_skippable(
    const std::uint8_t *rgba,
    const std::uint8_t *previous,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    std::uint32_t threshold) noexcept
{
    for (std::uint32_t py = 0u; py < 4u; ++py) {
        for (std::uint32_t px = 0u; px < 4u; ++px) {
            const std::size_t index =
                (static_cast<std::size_t>(y0 + py) * width + x0 + px) * 4u;
            const int dr =
                static_cast<int>(rgba[index] >> 3u) -
                static_cast<int>(previous[index] >> 3u);
            const int dg =
                static_cast<int>(rgba[index + 1u] >> 3u) -
                static_cast<int>(previous[index + 1u] >> 3u);
            const int db =
                static_cast<int>(rgba[index + 2u] >> 3u) -
                static_cast<int>(previous[index + 2u] >> 3u);
            const std::uint32_t delta = static_cast<std::uint32_t>(
                std::abs(dr) + std::abs(dg) + std::abs(db));
            if (delta > threshold) {
                return false;
            }
        }
    }
    return true;
}

void flush_skip(
    std::uint8_t *bytes,
    std::size_t *size,
    std::size_t count) noexcept
{
    while (count != 0u) {
        const std::uint16_t current =
            static_cast<std::uint16_t>(count > 0x3ffu ? 0x3ffu : count);
        const std::uint16_t word = static_cast<std::uint16_t>(
            (static_cast<std::uint16_t>(
                 0x84u | ((current >> 8u) & 3u)) << 8u) |
            (current & 0xffu));
        write_word(bytes, size, word);
        count -= current;
    }
}

void write_solid(
    std::uint8_t *bytes,
    std::size_t *size,
    std::uint16_t color) noexcept
{
    const std::uint16_t word = static_cast<std::uint16_t>(0x8000u | color);
    if (is_skip_color(word)) {
        write_word(bytes, size, 0u);
        write_word(bytes, size, 0u);
        write_word(bytes, size, color);
    } else {
        write_word(bytes, size, word);
    }
}

void encode_block(
    const std::uint8_t *rgba,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    std::uint8_t *bytes,
    std::size_t *size) noexcept
{
    std::uint8_t red[16]{};
    std::uint8_t green[16]{};
    std::uint8_t blue[16]{};
    std::uint16_t colors[16]{};
    for (std::uint32_t py = 0u; py < 4u; ++py) {
        for (std::uint32_t px = 0u; px < 4u; ++px) {
            const std::size_t input =
                (static_cast<std::size_t>(y0 + py) * width + x0 + px) * 4u;
            const std::size_t index = py * 4u + px;
            red[index] = rgba[input];
            green[index] = rgba[input + 1u];
            blue[index] = rgba[input + 2u];
            colors[index] = rgb555(red[index], green[index], blue[index]);
        }
    }
    bool solid = true;
    for (std::size_t i = 1u; i < 16u; ++i) {
        if (colors[i] != colors[0]) {
            solid = false;
            break;
        }
    }
    if (solid) {
        write_solid(bytes, size, colors[0]);
        return;
    }

    int low = std::numeric_limits<int>::max();
    int high = std::numeric_limits<int>::min();
    std::size_t low_index = 0u;
    std::size_t high_index = 0u;
    for (std::size_t i = 0u; i < 16u; ++i) {
        const int luminance =
            static_cast<int>(red[i]) * 299 +
            static_cast<int>(green[i]) * 587 +
            static_cast<int>(blue[i]) * 114;
        if (luminance < low) {
            low = luminance;
            low_index = i;
        }
        if (luminance > high) {
            high = luminance;
            high_index = i;
        }
    }

    const int seed_ar = red[high_index];
    const int seed_ag = green[high_index];
    const int seed_ab = blue[high_index];
    const int seed_br = red[low_index];
    const int seed_bg = green[low_index];
    const int seed_bb = blue[low_index];
    std::uint8_t group[16]{};
    int ar = 0;
    int ag = 0;
    int ab = 0;
    int br = 0;
    int bg = 0;
    int bb = 0;
    int count_a = 0;
    int count_b = 0;
    for (std::size_t i = 0u; i < 16u; ++i) {
        const int dra = static_cast<int>(red[i]) - seed_ar;
        const int dga = static_cast<int>(green[i]) - seed_ag;
        const int dba = static_cast<int>(blue[i]) - seed_ab;
        const int drb = static_cast<int>(red[i]) - seed_br;
        const int dgb = static_cast<int>(green[i]) - seed_bg;
        const int dbb = static_cast<int>(blue[i]) - seed_bb;
        const int distance_a = dra * dra + dga * dga + dba * dba;
        const int distance_b = drb * drb + dgb * dgb + dbb * dbb;
        if (distance_a <= distance_b) {
            group[i] = 1u;
            ar += red[i];
            ag += green[i];
            ab += blue[i];
            ++count_a;
        } else {
            br += red[i];
            bg += green[i];
            bb += blue[i];
            ++count_b;
        }
    }
    if (count_a == 0 || count_b == 0) {
        write_solid(bytes, size, colors[0]);
        return;
    }

    std::uint16_t color_a = rgb555(
        static_cast<std::uint8_t>(ar / count_a),
        static_cast<std::uint8_t>(ag / count_a),
        static_cast<std::uint8_t>(ab / count_a));
    std::uint16_t color_b = rgb555(
        static_cast<std::uint8_t>(br / count_b),
        static_cast<std::uint8_t>(bg / count_b),
        static_cast<std::uint8_t>(bb / count_b));
    std::uint16_t mask = 0u;
    for (std::size_t i = 0u; i < 16u; ++i) {
        if (group[kScan[i]] != 0u) {
            mask = static_cast<std::uint16_t>(mask | (UINT16_C(1) << i));
        }
    }
    if ((mask & 0x8000u) != 0u) {
        mask = static_cast<std::uint16_t>(mask ^ 0xffffu);
        const std::uint16_t temporary = color_a;
        color_a = color_b;
        color_b = temporary;
    }
    write_word(bytes, size, mask);
    write_word(bytes, size, color_a);
    write_word(bytes, size, color_b);
}

std::uint32_t expand_color(std::uint16_t color) noexcept
{
    const std::uint32_t r = (color >> 10u) & 31u;
    const std::uint32_t g = (color >> 5u) & 31u;
    const std::uint32_t b = color & 31u;
    return UINT32_C(0xff000000) |
           (((r << 3u) | (r >> 2u)) << 16u) |
           (((g << 3u) | (g >> 2u)) << 8u) |
           ((b << 3u) | (b >> 2u));
}

void decode_two_color(
    std::uint32_t *pixels,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    std::uint16_t flags,
    std::uint16_t color0,
    std::uint16_t color1) noexcept
{
    for (std::uint32_t py = 0u; py < 4u; ++py) {
        for (std::uint32_t px = 0u; px < 4u; ++px) {
            const std::uint16_t color =
                (flags & 1u) != 0u ? color0 : color1;
            pixels[
                static_cast<std::size_t>(y0 + 3u - py) * width + x0 + px] =
                expand_color(color);
            flags = static_cast<std::uint16_t>(flags >> 1u);
        }
    }
}

void decode_eight_color(
    std::uint32_t *pixels,
    std::uint32_t width,
    std::uint32_t x0,
    std::uint32_t y0,
    std::uint16_t flags,
    const std::uint16_t *colors) noexcept
{
    for (std::uint32_t py = 0u; py < 4u; ++py) {
        for (std::uint32_t px = 0u; px < 4u; ++px) {
            const std::uint32_t color_index =
                ((py & 2u) << 1u) + (px & 2u) + ((flags & 1u) ^ 1u);
            pixels[
                static_cast<std::size_t>(y0 + 3u - py) * width + x0 + px] =
                expand_color(colors[color_index]);
            flags = static_cast<std::uint16_t>(flags >> 1u);
        }
    }
}

} // namespace

hmc_status_t msv1_encoder_config_init(
    hmc_msv1_encoder_config_t *config,
    std::uint32_t config_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config_size < HMC_MSV1_ENCODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    std::memset(config, 0, config_size);
    config->struct_size = config_size;
    return HMC_STATUS_OK;
}

hmc_status_t msv1_decoder_config_init(
    hmc_msv1_decoder_config_t *config,
    std::uint32_t config_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config_size < HMC_MSV1_DECODER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    std::memset(config, 0, config_size);
    config->struct_size = config_size;
    return HMC_STATUS_OK;
}

hmc_status_t msv1_encode(
    const hmc_msv1_encoder_config_t *config,
    const std::uint8_t *rgba,
    std::size_t rgba_size,
    const std::uint8_t *previous_rgba,
    std::size_t previous_rgba_size,
    hmc_encode_flags_t encode_flags,
    hmc_owned_buffer_t *output,
    hmc_frame_flags_t *output_frame_flags) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const hmc_status_t config_status = validate_config(
        config, config->struct_size, HMC_MSV1_ENCODER_CONFIG_V1_SIZE);
    if (config_status != HMC_STATUS_OK) {
        return config_status;
    }
    if ((encode_flags & ~HMC_ENCODE_FLAG_FORCE_KEY) != 0u) {
        return HMC_STATUS_UNSUPPORTED;
    }
    if (output == nullptr || output->data != nullptr || output->size != 0u ||
        output_frame_flags == nullptr || rgba == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    std::size_t pixel_count = 0u;
    std::size_t required_rgba = 0u;
    std::size_t block_count = 0u;
    const hmc_status_t dimension_status = validate_dimensions(
        config->width, config->height, &pixel_count, &required_rgba, &block_count);
    if (dimension_status != HMC_STATUS_OK) {
        return dimension_status;
    }
    (void)pixel_count;
    if (rgba_size < required_rgba) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (previous_rgba == nullptr) {
        if (previous_rgba_size != 0u) {
            return HMC_STATUS_INVALID_ARGUMENT;
        }
    } else if (previous_rgba_size < required_rgba) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }

    std::size_t maximum_size = 0u;
    if (!checked_multiply_size(block_count, 6u, &maximum_size) ||
        !checked_add_size(maximum_size, 2u, &maximum_size)) {
        return HMC_STATUS_OVERFLOW;
    }
    auto *scratch = static_cast<std::uint8_t *>(allocate(maximum_size));
    if (scratch == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }

    const bool key =
        previous_rgba == nullptr ||
        (encode_flags & HMC_ENCODE_FLAG_FORCE_KEY) != 0u;
    const std::uint32_t block_width = config->width / 4u;
    const std::uint32_t block_height = config->height / 4u;
    std::size_t size = 0u;
    std::size_t skip_run = 0u;
    for (std::uint32_t row = block_height; row != 0u; --row) {
        const std::uint32_t by = row - 1u;
        for (std::uint32_t bx = 0u; bx < block_width; ++bx) {
            if (!key && block_skippable(
                            rgba,
                            previous_rgba,
                            config->width,
                            bx * 4u,
                            by * 4u,
                            config->skip_threshold)) {
                ++skip_run;
            } else {
                if (skip_run != 0u) {
                    flush_skip(scratch, &size, skip_run);
                    skip_run = 0u;
                }
                encode_block(
                    rgba, config->width, bx * 4u, by * 4u, scratch, &size);
            }
        }
    }
    if (skip_run != 0u) {
        flush_skip(scratch, &size, skip_run);
    }
    write_word(scratch, &size, 0u);

    output->data = scratch;
    output->size = size;
    *output_frame_flags = key
        ? HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN
        : HMC_FRAME_FLAG_KEY_KNOWN;
    return HMC_STATUS_OK;
}

hmc_status_t msv1_decode(
    const hmc_msv1_decoder_config_t *config,
    const std::uint8_t *encoded,
    std::size_t encoded_size,
    std::uint32_t *argb,
    std::size_t argb_pixel_count) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const hmc_status_t config_status = validate_config(
        config, config->struct_size, HMC_MSV1_DECODER_CONFIG_V1_SIZE);
    if (config_status != HMC_STATUS_OK) {
        return config_status;
    }
    if (encoded == nullptr || argb == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    std::size_t pixel_count = 0u;
    std::size_t rgba_bytes = 0u;
    std::size_t block_count = 0u;
    const hmc_status_t dimension_status = validate_dimensions(
        config->width, config->height, &pixel_count, &rgba_bytes, &block_count);
    if (dimension_status != HMC_STATUS_OK) {
        return dimension_status;
    }
    (void)rgba_bytes;
    if (argb_pixel_count < pixel_count) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if ((encoded_size & 1u) != 0u || encoded_size < 4u) {
        return HMC_STATUS_MALFORMED_DATA;
    }
    std::size_t scratch_size = 0u;
    if (!checked_multiply_size(pixel_count, sizeof(std::uint32_t), &scratch_size)) {
        return HMC_STATUS_OVERFLOW;
    }
    auto *scratch = static_cast<std::uint32_t *>(allocate(scratch_size));
    if (scratch == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    std::memcpy(scratch, argb, scratch_size);

    std::size_t offset = 0u;
    std::size_t block = 0u;
    hmc_status_t status = HMC_STATUS_OK;
    const std::uint32_t block_width = config->width / 4u;
    while (block < block_count) {
        if (encoded_size - offset < 2u) {
            status = HMC_STATUS_MALFORMED_DATA;
            break;
        }
        const std::uint16_t first = read_word(encoded, &offset);
        const std::uint8_t high = static_cast<std::uint8_t>(first >> 8u);
        if ((high & 0xfcu) == 0x84u) {
            const std::size_t skip =
                (static_cast<std::size_t>(high - 0x84u) << 8u) |
                static_cast<std::size_t>(first & 0xffu);
            if (skip == 0u || skip > block_count - block) {
                status = HMC_STATUS_MALFORMED_DATA;
                break;
            }
            block += skip;
            continue;
        }

        const std::uint32_t bx =
            static_cast<std::uint32_t>(block % block_width);
        const std::uint32_t from_bottom =
            static_cast<std::uint32_t>(block / block_width);
        const std::uint32_t by =
            config->height / 4u - 1u - from_bottom;
        const std::uint32_t x0 = bx * 4u;
        const std::uint32_t y0 = by * 4u;
        if (high < 0x80u) {
            if (encoded_size - offset < 4u) {
                status = HMC_STATUS_MALFORMED_DATA;
                break;
            }
            const std::uint16_t color0 = read_word(encoded, &offset);
            const std::uint16_t color1 = read_word(encoded, &offset);
            if ((color0 & 0x8000u) != 0u) {
                if (encoded_size - offset < 12u) {
                    status = HMC_STATUS_MALFORMED_DATA;
                    break;
                }
                std::uint16_t colors[8] = {color0, color1, 0u, 0u, 0u, 0u, 0u, 0u};
                for (std::size_t i = 2u; i < 8u; ++i) {
                    colors[i] = read_word(encoded, &offset);
                }
                decode_eight_color(
                    scratch, config->width, x0, y0, first, colors);
            } else {
                decode_two_color(
                    scratch, config->width, x0, y0, first, color0, color1);
            }
        } else {
            const std::uint16_t color =
                static_cast<std::uint16_t>(first & 0x7fffu);
            for (std::uint32_t py = 0u; py < 4u; ++py) {
                for (std::uint32_t px = 0u; px < 4u; ++px) {
                    scratch[
                        static_cast<std::size_t>(y0 + py) * config->width + x0 + px] =
                        expand_color(color);
                }
            }
        }
        ++block;
    }
    if (status == HMC_STATUS_OK) {
        if (encoded_size - offset != 2u || read_word(encoded, &offset) != 0u) {
            status = HMC_STATUS_MALFORMED_DATA;
        }
    }
    if (status == HMC_STATUS_OK) {
        std::memcpy(argb, scratch, scratch_size);
    }
    deallocate(scratch);
    return status;
}

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void msv1_test_fail_nth_allocation(std::size_t allocation_number) noexcept
{
    allocation_test_fail_nth(allocation_number);
}

HMC_API void msv1_test_clear_allocation_failure() noexcept
{
    allocation_test_clear_failure();
}

HMC_API std::size_t msv1_test_allocation_count() noexcept
{
    return allocation_test_count();
}
#endif

} // namespace honey::media
