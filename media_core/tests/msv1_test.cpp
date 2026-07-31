#include "honey_media_core/media_core.h"

#include "msv1.hpp"
#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> fixture_bytes(const char *name)
{
    const std::string path = std::string(HMC_FIXTURE_DIRECTORY) + "/" + name;
    std::ifstream input(path, std::ios::binary);
    return std::vector<std::uint8_t>(
        std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

std::vector<std::uint32_t> fixture_argb(const char *name)
{
    const std::vector<std::uint8_t> bytes = fixture_bytes(name);
    std::vector<std::uint32_t> pixels(bytes.size() / 4u);
    for (std::size_t i = 0u; i < pixels.size(); ++i) {
        pixels[i] = static_cast<std::uint32_t>(bytes[i * 4u]) |
                    (static_cast<std::uint32_t>(bytes[i * 4u + 1u]) << 8u) |
                    (static_cast<std::uint32_t>(bytes[i * 4u + 2u]) << 16u) |
                    (static_cast<std::uint32_t>(bytes[i * 4u + 3u]) << 24u);
    }
    return pixels;
}

hmc_msv1_encoder_config_t encoder_config(
    std::uint32_t width, std::uint32_t height, std::uint32_t threshold = 0u)
{
    hmc_msv1_encoder_config_t config{};
    HMC_EXPECT(
        hmc_msv1_encoder_config_init(&config, sizeof(config)) == HMC_STATUS_OK);
    config.width = width;
    config.height = height;
    config.skip_threshold = threshold;
    return config;
}

hmc_msv1_decoder_config_t decoder_config(std::uint32_t width, std::uint32_t height)
{
    hmc_msv1_decoder_config_t config{};
    HMC_EXPECT(
        hmc_msv1_decoder_config_init(&config, sizeof(config)) == HMC_STATUS_OK);
    config.width = width;
    config.height = height;
    return config;
}

std::vector<std::uint8_t> solid_rgba(
    std::uint32_t width,
    std::uint32_t height,
    std::uint8_t red,
    std::uint8_t green,
    std::uint8_t blue,
    std::uint8_t alpha = 0xffu)
{
    std::vector<std::uint8_t> rgba(
        static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 4u);
    for (std::size_t i = 0u; i < rgba.size(); i += 4u) {
        rgba[i] = red;
        rgba[i + 1u] = green;
        rgba[i + 2u] = blue;
        rgba[i + 3u] = alpha;
    }
    return rgba;
}

hmc_status_t encode(
    const hmc_msv1_encoder_config_t &config,
    const std::vector<std::uint8_t> &rgba,
    const std::vector<std::uint8_t> *previous,
    hmc_encode_flags_t flags,
    std::vector<std::uint8_t> *bytes,
    hmc_frame_flags_t *frame_flags)
{
    hmc_owned_buffer_t output{nullptr, 0u};
    const hmc_status_t status = hmc_msv1_encode(
        &config,
        rgba.data(),
        rgba.size(),
        previous == nullptr ? nullptr : previous->data(),
        previous == nullptr ? 0u : previous->size(),
        flags,
        &output,
        frame_flags);
    if (status == HMC_STATUS_OK) {
        bytes->assign(output.data, output.data + output.size);
    }
    hmc_owned_buffer_release(&output);
    return status;
}

std::uint32_t expanded(std::uint16_t color)
{
    const std::uint32_t r = (color >> 10u) & 31u;
    const std::uint32_t g = (color >> 5u) & 31u;
    const std::uint32_t b = color & 31u;
    return UINT32_C(0xff000000) |
           (((r << 3u) | (r >> 2u)) << 16u) |
           (((g << 3u) | (g >> 2u)) << 8u) |
           ((b << 3u) | (b >> 2u));
}

HMC_TEST(msv1_config_init_obeys_v1_and_tail_contracts)
{
    struct ExtendedEncoder {
        hmc_msv1_encoder_config_t config;
        std::uint32_t tail;
    };
    struct ExtendedDecoder {
        hmc_msv1_decoder_config_t config;
        std::uint32_t tail;
    };

    HMC_EXPECT(sizeof(hmc_msv1_encoder_config_t) == HMC_MSV1_ENCODER_CONFIG_V1_SIZE);
    HMC_EXPECT(sizeof(hmc_msv1_decoder_config_t) == HMC_MSV1_DECODER_CONFIG_V1_SIZE);
    HMC_EXPECT(
        hmc_msv1_encoder_config_init(nullptr, HMC_MSV1_ENCODER_CONFIG_V1_SIZE) ==
        HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(
        hmc_msv1_decoder_config_init(nullptr, HMC_MSV1_DECODER_CONFIG_V1_SIZE) ==
        HMC_STATUS_INVALID_ARGUMENT);

    hmc_msv1_encoder_config_t short_encoder{};
    std::memset(&short_encoder, 0xa5, sizeof(short_encoder));
    const auto short_encoder_before = short_encoder;
    HMC_EXPECT(
        hmc_msv1_encoder_config_init(
            &short_encoder,
            HMC_MSV1_ENCODER_CONFIG_V1_SIZE - 1u) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(std::memcmp(
                   &short_encoder, &short_encoder_before, sizeof(short_encoder)) == 0);

    ExtendedEncoder encoder{};
    std::memset(&encoder, 0xa5, sizeof(encoder));
    HMC_EXPECT(
        hmc_msv1_encoder_config_init(&encoder.config, sizeof(encoder)) ==
        HMC_STATUS_OK);
    HMC_EXPECT(encoder.config.struct_size == sizeof(encoder));
    HMC_EXPECT(encoder.config.width == 0u);
    HMC_EXPECT(encoder.config.height == 0u);
    HMC_EXPECT(encoder.config.skip_threshold == 0u);
    HMC_EXPECT(encoder.tail == 0u);

    ExtendedDecoder decoder{};
    std::memset(&decoder, 0xa5, sizeof(decoder));
    HMC_EXPECT(
        hmc_msv1_decoder_config_init(&decoder.config, sizeof(decoder)) ==
        HMC_STATUS_OK);
    HMC_EXPECT(decoder.config.struct_size == sizeof(decoder));
    HMC_EXPECT(decoder.config.width == 0u);
    HMC_EXPECT(decoder.config.height == 0u);
    HMC_EXPECT(decoder.tail == 0u);

    hmc_msv1_decoder_config_t short_decoder{};
    std::memset(&short_decoder, 0x5a, sizeof(short_decoder));
    const auto short_decoder_before = short_decoder;
    HMC_EXPECT(
        hmc_msv1_decoder_config_init(
            &short_decoder,
            HMC_MSV1_DECODER_CONFIG_V1_SIZE - 1u) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(std::memcmp(
                   &short_decoder, &short_decoder_before, sizeof(short_decoder)) == 0);
}

HMC_TEST(msv1_encoder_matches_kotlin_fixtures_and_flags)
{
    const std::vector<std::uint8_t> a = fixture_bytes("input_8x8_a.rgba");
    const std::vector<std::uint8_t> b = fixture_bytes("input_8x8_b.rgba");
    const hmc_msv1_encoder_config_t config = encoder_config(8u, 8u);
    std::vector<std::uint8_t> actual;
    hmc_frame_flags_t flags = UINT32_C(0xdeadbeef);

    HMC_EXPECT(encode(config, a, nullptr, HMC_ENCODE_FLAG_NONE, &actual, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(actual == fixture_bytes("msv1_key.bin"));
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));

    actual.clear();
    HMC_EXPECT(encode(config, a, &a, HMC_ENCODE_FLAG_NONE, &actual, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(actual == fixture_bytes("msv1_all_skip.bin"));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);

    actual.clear();
    HMC_EXPECT(encode(config, b, &a, HMC_ENCODE_FLAG_NONE, &actual, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(actual == fixture_bytes("msv1_inter.bin"));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
}

HMC_TEST(msv1_solid_collision_and_quantized_skip_bytes_are_exact)
{
    const hmc_msv1_encoder_config_t config = encoder_config(4u, 4u);
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = 0u;

    const auto black = solid_rgba(4u, 4u, 0u, 0u, 0u);
    HMC_EXPECT(encode(config, black, nullptr, 0u, &bytes, &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x00u, 0x80u, 0x00u, 0x00u}));

    const auto collision = solid_rgba(4u, 4u, 8u, 0u, 0u);
    HMC_EXPECT(encode(config, collision, nullptr, 0u, &bytes, &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x04u, 0x00u, 0x00u}));

    const auto low_bits = solid_rgba(4u, 4u, 7u, 7u, 7u, 1u);
    HMC_EXPECT(encode(config, low_bits, nullptr, 0u, &bytes, &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x00u, 0x80u, 0x00u, 0x00u}));
    HMC_EXPECT(encode(config, low_bits, &black, 0u, &bytes, &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x01u, 0x84u, 0x00u, 0x00u}));
}

HMC_TEST(msv1_block_order_mask_and_threshold_boundaries_are_exact)
{
    std::vector<std::uint8_t> quadrants = solid_rgba(8u, 8u, 0u, 0u, 0u);
    const std::array<std::array<std::uint8_t, 3u>, 4u> colors = {{
        {{8u, 0u, 0u}}, {{0u, 8u, 0u}}, {{0u, 0u, 8u}}, {{8u, 8u, 0u}},
    }};
    for (std::uint32_t y = 0u; y < 8u; ++y) {
        for (std::uint32_t x = 0u; x < 8u; ++x) {
            const std::size_t q = (y >= 4u ? 2u : 0u) + (x >= 4u ? 1u : 0u);
            const std::size_t p = (static_cast<std::size_t>(y) * 8u + x) * 4u;
            quadrants[p] = colors[q][0];
            quadrants[p + 1u] = colors[q][1];
            quadrants[p + 2u] = colors[q][2];
        }
    }
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = 0u;
    HMC_EXPECT(encode(encoder_config(8u, 8u), quadrants, nullptr, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({
                            0x01u, 0x80u,
                            0x00u, 0x00u, 0x00u, 0x00u, 0x20u, 0x04u,
                            0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x04u,
                            0x20u, 0x80u,
                            0x00u, 0x00u}));

    auto mask_input = solid_rgba(4u, 4u, 0u, 0u, 0u);
    mask_input[0] = mask_input[1] = mask_input[2] = 0xffu;
    mask_input[12] = mask_input[13] = mask_input[14] = 0xffu;
    HMC_EXPECT(encode(encoder_config(4u, 4u), mask_input, nullptr, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0xffu, 0x6fu, 0x00u, 0x00u, 0xffu, 0x7fu, 0x00u, 0x00u}));

    const auto black = solid_rgba(4u, 4u, 0u, 0u, 0u);
    auto delta = black;
    delta[0] = delta[1] = delta[2] = 8u;
    HMC_EXPECT(encode(encoder_config(4u, 4u, 3u), delta, &black, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x01u, 0x84u, 0x00u, 0x00u}));
    HMC_EXPECT(encode(encoder_config(4u, 4u, 2u), delta, &black, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x00u, 0x10u, 0x21u, 0x04u,
                             0x00u, 0x00u, 0x00u, 0x00u}));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
}

HMC_TEST(msv1_skip_threshold_checks_the_sixteenth_pixel)
{
    const auto previous = solid_rgba(4u, 4u, 0u, 0u, 0u);
    auto changed = previous;
    const std::size_t last = 15u * 4u;
    changed[last] = 8u;
    changed[last + 1u] = 8u;
    changed[last + 2u] = 8u;
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = UINT32_C(0xdeadbeef);

    HMC_EXPECT(encode(
                   encoder_config(4u, 4u, 3u),
                   changed,
                   &previous,
                   HMC_ENCODE_FLAG_NONE,
                   &bytes,
                   &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x01u, 0x84u, 0x00u, 0x00u}));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);

    flags = UINT32_C(0xdeadbeef);
    HMC_EXPECT(encode(
                   encoder_config(4u, 4u, 2u),
                   changed,
                   &previous,
                   HMC_ENCODE_FLAG_NONE,
                   &bytes,
                   &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x08u, 0x00u, 0x21u, 0x04u,
                             0x00u, 0x00u, 0x00u, 0x00u}));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
}

HMC_TEST(msv1_skip_runs_split_at_1023_blocks)
{
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = 0u;
    const auto a1023 = solid_rgba(4092u, 4u, 0u, 0u, 0u);
    HMC_EXPECT(encode(encoder_config(4092u, 4u), a1023, &a1023, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0xffu, 0x87u, 0x00u, 0x00u}));

    const auto a1024 = solid_rgba(4096u, 4u, 0u, 0u, 0u);
    HMC_EXPECT(encode(encoder_config(4096u, 4u), a1024, &a1024, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0xffu, 0x87u, 0x01u, 0x84u, 0x00u, 0x00u}));
}

HMC_TEST(msv1_clustering_freezes_first_wins_ties_and_integer_truncation)
{
    auto set_rgb = [](std::vector<std::uint8_t> *rgba,
                      std::size_t pixel,
                      std::uint8_t red,
                      std::uint8_t green,
                      std::uint8_t blue) {
        (*rgba)[pixel * 4u] = red;
        (*rgba)[pixel * 4u + 1u] = green;
        (*rgba)[pixel * 4u + 2u] = blue;
    };
    const auto config = encoder_config(4u, 4u);
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = 0u;

    auto equal_luminance = solid_rgba(4u, 4u, 0u, 0u, 0u);
    set_rgb(&equal_luminance, 0u, 0u, 10u, 0u);
    set_rgb(&equal_luminance, 1u, 4u, 0u, 41u);
    HMC_EXPECT(encode(
                   config, equal_luminance, nullptr, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x00u, 0x10u, 0x20u, 0x00u,
                             0x00u, 0x00u, 0x00u, 0x00u}));

    auto distance_tie = solid_rgba(4u, 4u, 0u, 0u, 0u);
    set_rgb(&distance_tie, 0u, 16u, 0u, 0u);
    set_rgb(&distance_tie, 2u, 8u, 0u, 0u);
    HMC_EXPECT(encode(config, distance_tie, nullptr, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x00u, 0x50u, 0x00u, 0x04u,
                             0x00u, 0x00u, 0x00u, 0x00u}));

    auto truncated_average = solid_rgba(4u, 4u, 0u, 0u, 0u);
    set_rgb(&truncated_average, 0u, 16u, 0u, 0u);
    set_rgb(&truncated_average, 2u, 15u, 0u, 0u);
    HMC_EXPECT(encode(
                   config, truncated_average, nullptr, 0u, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>(
                            {0x00u, 0x50u, 0x00u, 0x04u,
                             0x00u, 0x00u, 0x00u, 0x00u}));
}

HMC_TEST(msv1_force_key_validates_previous_then_disables_skip)
{
    const auto black = solid_rgba(4u, 4u, 0u, 0u, 0u);
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = UINT32_C(0x12345678);
    const auto config = encoder_config(4u, 4u);
    HMC_EXPECT(encode(config, black, &black, 0u, &bytes, &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x01u, 0x84u, 0x00u, 0x00u}));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
    HMC_EXPECT(encode(
                   config, black, &black, HMC_ENCODE_FLAG_FORCE_KEY, &bytes, &flags) ==
               HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x00u, 0x80u, 0x00u, 0x00u}));
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));

    hmc_owned_buffer_t output{nullptr, 0u};
    const hmc_frame_flags_t before = flags;
    HMC_EXPECT(
        hmc_msv1_encode(
            &config,
            black.data(),
            black.size(),
            black.data(),
            black.size() - 1u,
            HMC_ENCODE_FLAG_FORCE_KEY,
            &output,
            &flags) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == before);
}

HMC_TEST(msv1_sequential_decode_matches_kotlin_fixtures)
{
    const auto config = decoder_config(8u, 8u);
    std::vector<std::uint32_t> pixels(64u, UINT32_C(0x11223344));
    const auto key = fixture_bytes("msv1_key.bin");
    const auto all_skip = fixture_bytes("msv1_all_skip.bin");
    const auto inter = fixture_bytes("msv1_inter.bin");

    HMC_EXPECT(hmc_msv1_decode(&config, key.data(), key.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels == fixture_argb("msv1_key.argb"));
    HMC_EXPECT(hmc_msv1_decode(
                   &config, all_skip.data(), all_skip.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels == fixture_argb("msv1_all_skip.argb"));
    HMC_EXPECT(hmc_msv1_decode(
                   &config, inter.data(), inter.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels == fixture_argb("msv1_inter.argb"));
}

HMC_TEST(msv1_decoder_supports_two_color_eight_color_solid_and_skip)
{
    const auto config = decoder_config(4u, 4u);
    std::vector<std::uint32_t> pixels(16u, UINT32_C(0x11223344));

    const std::array<std::uint8_t, 8u> two_color = {
        0x01u, 0x00u, 0x00u, 0x7cu, 0x1fu, 0x00u, 0x00u, 0x00u};
    HMC_EXPECT(hmc_msv1_decode(
                   &config, two_color.data(), two_color.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels[12] == expanded(0x7c00u));
    HMC_EXPECT(pixels[13] == expanded(0x001fu));

    const std::array<std::uint8_t, 20u> eight_color = {
        0x00u, 0x00u, 0x00u, 0x80u, 0x01u, 0x00u, 0x02u, 0x00u, 0x03u, 0x00u,
        0x04u, 0x00u, 0x05u, 0x00u, 0x06u, 0x00u, 0x07u, 0x00u, 0x00u, 0x00u};
    HMC_EXPECT(hmc_msv1_decode(
                   &config, eight_color.data(), eight_color.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels[0] == expanded(5u));
    HMC_EXPECT(pixels[3] == expanded(7u));
    HMC_EXPECT(pixels[12] == expanded(1u));
    HMC_EXPECT(pixels[15] == expanded(3u));

    auto eight_color_even = eight_color;
    eight_color_even[0] = 0xffu;
    eight_color_even[1] = 0x7fu;
    HMC_EXPECT(hmc_msv1_decode(
                   &config,
                   eight_color_even.data(),
                   eight_color_even.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_OK);
    HMC_EXPECT(pixels[0] == expanded(4u));
    HMC_EXPECT(pixels[3] == expanded(7u));
    HMC_EXPECT(pixels[12] == expanded(0x8000u));
    HMC_EXPECT(pixels[15] == expanded(2u));

    const std::array<std::uint8_t, 4u> solid = {0x01u, 0x80u, 0x00u, 0x00u};
    HMC_EXPECT(hmc_msv1_decode(
                   &config, solid.data(), solid.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(std::all_of(
        pixels.begin(), pixels.end(), [](std::uint32_t value) { return value == expanded(1u); }));

    std::fill(pixels.begin(), pixels.end(), UINT32_C(0x11223344));
    const std::array<std::uint8_t, 4u> skip = {0x01u, 0x84u, 0x00u, 0x00u};
    HMC_EXPECT(hmc_msv1_decode(
                   &config, skip.data(), skip.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(std::all_of(pixels.begin(), pixels.end(), [](std::uint32_t value) {
        return value == UINT32_C(0x11223344);
    }));
}

HMC_TEST(msv1_eight_color_rejects_every_short_prefix_atomically)
{
    const auto config = decoder_config(4u, 4u);
    const std::array<std::uint8_t, 20u> eight_color = {
        0x00u, 0x00u, 0x00u, 0x80u, 0x01u, 0x00u, 0x02u, 0x00u, 0x03u, 0x00u,
        0x04u, 0x00u, 0x05u, 0x00u, 0x06u, 0x00u, 0x07u, 0x00u, 0x00u, 0x00u};
    const std::vector<std::uint32_t> sentinel(16u, UINT32_C(0x10203040));

    for (std::size_t size = 0u; size < eight_color.size(); ++size) {
        std::vector<std::uint32_t> pixels = sentinel;
        HMC_EXPECT(hmc_msv1_decode(
                       &config,
                       eight_color.data(),
                       size,
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == sentinel);
    }

    std::vector<std::uint32_t> pixels = sentinel;
    HMC_EXPECT(hmc_msv1_decode(
                   &config,
                   eight_color.data(),
                   eight_color.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_OK);
    HMC_EXPECT(pixels != sentinel);
}

HMC_TEST(msv1_rgb555_expansion_covers_zero_one_and_thirty_one)
{
    const auto config = decoder_config(4u, 4u);
    const std::array<std::uint8_t, 8u> encoded = {
        0x01u, 0x00u, 0x00u, 0x00u, 0xffu, 0x7fu, 0x00u, 0x00u};
    std::vector<std::uint32_t> pixels(16u, 0u);
    HMC_EXPECT(hmc_msv1_decode(
                   &config, encoded.data(), encoded.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels[12] == UINT32_C(0xff000000));
    HMC_EXPECT(pixels[13] == UINT32_C(0xffffffff));

    const std::array<std::uint8_t, 8u> one = {
        0x00u, 0x00u, 0x00u, 0x00u, 0x21u, 0x04u, 0x00u, 0x00u};
    HMC_EXPECT(hmc_msv1_decode(
                   &config, one.data(), one.size(), pixels.data(), pixels.size()) ==
               HMC_STATUS_OK);
    HMC_EXPECT(pixels[0] == expanded(0x0421u));
}

HMC_TEST(msv1_rejects_malformed_streams_atomically)
{
    const auto config = decoder_config(8u, 8u);
    const auto valid = fixture_bytes("msv1_key.bin");
    const std::vector<std::uint32_t> sentinel(64u, UINT32_C(0x10203040));

    for (std::size_t size = 0u; size < valid.size(); ++size) {
        std::vector<std::uint32_t> pixels = sentinel;
        HMC_EXPECT(hmc_msv1_decode(
                       &config, valid.data(), size, pixels.data(), pixels.size()) ==
                   HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == sentinel);
    }

    const std::array<std::vector<std::uint8_t>, 6u> malformed = {{
        {0x00u, 0x84u, 0x00u, 0x00u},
        {0x05u, 0x84u, 0x00u, 0x00u},
        {0x00u, 0x00u},
        {0x00u, 0x00u, 0x00u},
        {0x01u, 0x80u, 0x00u, 0x00u, 0x01u},
        {0x01u, 0x80u, 0x00u, 0x00u, 0x01u, 0x00u},
    }};
    const auto one_block = decoder_config(4u, 4u);
    for (const auto &bytes : malformed) {
        std::vector<std::uint32_t> pixels(16u, UINT32_C(0x10203040));
        const auto before = pixels;
        HMC_EXPECT(hmc_msv1_decode(
                       &one_block, bytes.data(), bytes.size(), pixels.data(), pixels.size()) ==
                   HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == before);
    }
}

HMC_TEST(msv1_validates_dimensions_spans_struct_tails_and_flags)
{
    const auto pixels = solid_rgba(4u, 4u, 0u, 0u, 0u);
    hmc_owned_buffer_t output{nullptr, 0u};
    hmc_frame_flags_t frame_flags = UINT32_C(0x55667788);
    HMC_EXPECT(hmc_msv1_encode(
                   nullptr, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    for (const auto &config : {
             encoder_config(0u, 4u), encoder_config(4u, 0u),
             encoder_config(2u, 4u), encoder_config(4u, 6u)}) {
        HMC_EXPECT(hmc_msv1_encode(
                       &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                       &output, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
        HMC_EXPECT(output.data == nullptr && output.size == 0u);
        HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    }

    auto config = encoder_config(4u, 4u);
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size() - 1u, nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 1u, 0u,
                   &output, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, UINT32_C(0x80000000),
                   &output, &frame_flags) == HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, nullptr, pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), pixels.data(), 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   nullptr, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, nullptr) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    hmc_owned_buffer_t occupied{
        reinterpret_cast<std::uint8_t *>(static_cast<std::uintptr_t>(1u)), 1u};
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &occupied, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(
        occupied.data ==
            reinterpret_cast<std::uint8_t *>(static_cast<std::uintptr_t>(1u)) &&
        occupied.size == 1u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));

    struct Extended {
        hmc_msv1_encoder_config_t config;
        std::uint32_t tail;
    } extended{{sizeof(Extended), 4u, 4u, 0u}, 1u};
    HMC_EXPECT(hmc_msv1_encode(
                   &extended.config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    extended.tail = 0u;
    HMC_EXPECT(hmc_msv1_encode(
                   &extended.config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_OK);
    hmc_owned_buffer_release(&output);
    config.struct_size = HMC_MSV1_ENCODER_CONFIG_V1_SIZE - 1u;
    frame_flags = UINT32_C(0x55667788);
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));

    config = encoder_config(4u, 4u);
    config.width = UINT32_MAX - 3u;
    config.height = UINT32_MAX - 3u;
    frame_flags = UINT32_C(0x55667788);
    HMC_EXPECT(hmc_msv1_encode(
                   &config, pixels.data(), pixels.size(), nullptr, 0u, 0u,
                   &output, &frame_flags) == HMC_STATUS_OVERFLOW);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));

    const auto decode_config = decoder_config(4u, 4u);
    const std::array<std::uint8_t, 4u> solid = {0x00u, 0x80u, 0x00u, 0x00u};
    std::vector<std::uint32_t> argb(16u, UINT32_C(0x12345678));
    const auto before = argb;
    HMC_EXPECT(hmc_msv1_decode(
                   nullptr, solid.data(), solid.size(), argb.data(), argb.size()) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(argb == before);
    HMC_EXPECT(hmc_msv1_decode(
                   &decode_config, solid.data(), solid.size(), argb.data(), argb.size() - 1u) ==
               HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(argb == before);

    for (const auto &invalid : {
             decoder_config(0u, 4u), decoder_config(4u, 0u),
             decoder_config(2u, 4u), decoder_config(4u, 6u)}) {
        HMC_EXPECT(hmc_msv1_decode(
                       &invalid,
                       solid.data(),
                       solid.size(),
                       argb.data(),
                       argb.size()) == HMC_STATUS_INVALID_ARGUMENT);
        HMC_EXPECT(argb == before);
    }
    HMC_EXPECT(hmc_msv1_decode(
                   &decode_config, nullptr, solid.size(), argb.data(), argb.size()) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(argb == before);
    HMC_EXPECT(hmc_msv1_decode(
                   &decode_config, solid.data(), solid.size(), nullptr, argb.size()) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(argb == before);

    struct ExtendedDecoder {
        hmc_msv1_decoder_config_t config;
        std::uint32_t tail;
    } extended_decoder{{sizeof(ExtendedDecoder), 4u, 4u}, 1u};
    HMC_EXPECT(hmc_msv1_decode(
                   &extended_decoder.config,
                   solid.data(),
                   solid.size(),
                   argb.data(),
                   argb.size()) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(argb == before);
    extended_decoder.tail = 0u;
    HMC_EXPECT(hmc_msv1_decode(
                   &extended_decoder.config,
                   solid.data(),
                   solid.size(),
                   argb.data(),
                   argb.size()) == HMC_STATUS_OK);
    argb = before;

    auto small_decoder = decoder_config(4u, 4u);
    small_decoder.struct_size = HMC_MSV1_DECODER_CONFIG_V1_SIZE - 1u;
    HMC_EXPECT(hmc_msv1_decode(
                   &small_decoder,
                   solid.data(),
                   solid.size(),
                   argb.data(),
                   argb.size()) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(argb == before);

    auto overflow_decoder = decoder_config(UINT32_MAX - 3u, UINT32_MAX - 3u);
    HMC_EXPECT(hmc_msv1_decode(
                   &overflow_decoder,
                   solid.data(),
                   solid.size(),
                   argb.data(),
                   argb.size()) == HMC_STATUS_OVERFLOW);
    HMC_EXPECT(argb == before);
}

HMC_TEST(msv1_accepts_minimum_or_larger_buffer_capacities)
{
    auto rgba = solid_rgba(4u, 4u, 0u, 0u, 0u);
    rgba.push_back(0xa5u);
    auto previous = rgba;
    std::vector<std::uint8_t> bytes;
    hmc_frame_flags_t flags = 0u;
    HMC_EXPECT(encode(
                   encoder_config(4u, 4u),
                   rgba,
                   &previous,
                   HMC_ENCODE_FLAG_NONE,
                   &bytes,
                   &flags) == HMC_STATUS_OK);
    HMC_EXPECT(bytes == std::vector<std::uint8_t>({0x01u, 0x84u, 0x00u, 0x00u}));

    std::vector<std::uint32_t> argb(17u, UINT32_C(0x12345678));
    const auto config = decoder_config(4u, 4u);
    HMC_EXPECT(hmc_msv1_decode(
                   &config,
                   bytes.data(),
                   bytes.size(),
                   argb.data(),
                   argb.size()) == HMC_STATUS_OK);
    HMC_EXPECT(argb[16] == UINT32_C(0x12345678));
}

HMC_TEST(msv1_allocation_failures_are_atomic_and_retryable)
{
    const auto rgba = fixture_bytes("input_8x8_a.rgba");
    const auto encode_config = encoder_config(8u, 8u);
    honey::media::msv1_test_clear_allocation_failure();
    hmc_owned_buffer_t baseline_output{nullptr, 0u};
    hmc_frame_flags_t baseline_flags = 0u;
    HMC_EXPECT(hmc_msv1_encode(
                   &encode_config, rgba.data(), rgba.size(), nullptr, 0u, 0u,
                   &baseline_output, &baseline_flags) == HMC_STATUS_OK);
    const std::size_t encode_allocations =
        honey::media::msv1_test_allocation_count();
    hmc_owned_buffer_release(&baseline_output);
    HMC_EXPECT(encode_allocations != 0u);
    for (std::size_t nth = 1u; nth <= encode_allocations; ++nth) {
        honey::media::msv1_test_fail_nth_allocation(nth);
        hmc_owned_buffer_t output{nullptr, 0u};
        hmc_frame_flags_t flags = UINT32_C(0xaabbccdd);
        HMC_EXPECT(hmc_msv1_encode(
                       &encode_config, rgba.data(), rgba.size(), nullptr, 0u, 0u,
                       &output, &flags) == HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(output.data == nullptr && output.size == 0u);
        HMC_EXPECT(flags == UINT32_C(0xaabbccdd));
        honey::media::msv1_test_clear_allocation_failure();
        HMC_EXPECT(hmc_msv1_encode(
                       &encode_config, rgba.data(), rgba.size(), nullptr, 0u, 0u,
                       &output, &flags) == HMC_STATUS_OK);
        hmc_owned_buffer_release(&output);
    }

    const auto encoded = fixture_bytes("msv1_key.bin");
    const auto decode_config = decoder_config(8u, 8u);
    honey::media::msv1_test_clear_allocation_failure();
    std::vector<std::uint32_t> baseline_pixels(64u, UINT32_C(0x12345678));
    HMC_EXPECT(hmc_msv1_decode(
                   &decode_config,
                   encoded.data(),
                   encoded.size(),
                   baseline_pixels.data(),
                   baseline_pixels.size()) ==
               HMC_STATUS_OK);
    const std::size_t decode_allocations =
        honey::media::msv1_test_allocation_count();
    HMC_EXPECT(decode_allocations != 0u);
    for (std::size_t nth = 1u; nth <= decode_allocations; ++nth) {
        honey::media::msv1_test_fail_nth_allocation(nth);
        std::vector<std::uint32_t> pixels(64u, UINT32_C(0x12345678));
        const auto before = pixels;
        HMC_EXPECT(hmc_msv1_decode(
                       &decode_config,
                       encoded.data(),
                       encoded.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(pixels == before);
        honey::media::msv1_test_clear_allocation_failure();
        HMC_EXPECT(hmc_msv1_decode(
                       &decode_config,
                       encoded.data(),
                       encoded.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OK);
    }
    honey::media::msv1_test_clear_allocation_failure();
}

} // namespace
