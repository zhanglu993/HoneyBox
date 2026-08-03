#include "honey_media_core/media_core.h"

#include "cinepak_encoder.hpp"
#include "test_support.hpp"

#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {

std::vector<std::uint8_t> fixture_bytes(const char *name)
{
    const std::string path = std::string(HMC_FIXTURE_DIRECTORY) + "/" + name;
    std::ifstream input(path, std::ios::binary);
    return std::vector<std::uint8_t>(
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>());
}

hmc_cinepak_encoder_config_t config(std::uint32_t width = 8u, std::uint32_t height = 8u)
{
    hmc_cinepak_encoder_config_t value{};
    HMC_EXPECT(hmc_cinepak_encoder_config_init(&value, sizeof(value)) == HMC_STATUS_OK);
    value.width = width;
    value.height = height;
    return value;
}

std::vector<std::uint8_t> encode(
    hmc_cinepak_encoder_t *encoder,
    const std::vector<std::uint8_t> &rgba,
    hmc_encode_flags_t flags,
    hmc_frame_flags_t *frame_flags)
{
    hmc_owned_buffer_t output{};
    const hmc_status_t status = hmc_cinepak_encoder_encode(
        encoder, rgba.data(), rgba.size(), flags, &output, frame_flags);
    HMC_EXPECT(status == HMC_STATUS_OK);
    std::vector<std::uint8_t> result;
    if (status == HMC_STATUS_OK && output.data != nullptr) {
        result.assign(output.data, output.data + output.size);
    }
    hmc_owned_buffer_release(&output);
    return result;
}

std::uint32_t be24(const std::uint8_t *bytes)
{
    return (static_cast<std::uint32_t>(bytes[0]) << 16u) |
           (static_cast<std::uint32_t>(bytes[1]) << 8u) |
           static_cast<std::uint32_t>(bytes[2]);
}

std::vector<std::uint32_t> fixture_argb(const char *name)
{
    const auto bytes = fixture_bytes(name);
    HMC_EXPECT((bytes.size() & 3u) == 0u);
    std::vector<std::uint32_t> pixels(bytes.size() / 4u);
    for (std::size_t i = 0u; i < pixels.size(); ++i) {
        const std::size_t p = i * 4u;
        pixels[i] = static_cast<std::uint32_t>(bytes[p]) |
            (static_cast<std::uint32_t>(bytes[p + 1u]) << 8u) |
            (static_cast<std::uint32_t>(bytes[p + 2u]) << 16u) |
            (static_cast<std::uint32_t>(bytes[p + 3u]) << 24u);
    }
    return pixels;
}

std::size_t first_strip_chunk(const std::vector<std::uint8_t> &frame, std::uint8_t id)
{
    if (frame.size() < 22u) {
        return frame.size();
    }
    const std::size_t strip_end = 10u + be24(frame.data() + 11u);
    std::size_t cursor = 22u;
    while (cursor + 4u <= strip_end && strip_end <= frame.size()) {
        const std::size_t size = be24(frame.data() + cursor + 1u);
        if (frame[cursor] == id) {
            return cursor;
        }
        if (size < 4u || size > strip_end - cursor) {
            break;
        }
        cursor += size;
    }
    return frame.size();
}

std::vector<std::uint8_t> solid_rgba(
    std::uint32_t width,
    std::uint32_t height,
    std::uint8_t r,
    std::uint8_t g,
    std::uint8_t b)
{
    std::vector<std::uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u);
    for (std::size_t i = 0u; i < rgba.size(); i += 4u) {
        rgba[i] = r;
        rgba[i + 1u] = g;
        rgba[i + 2u] = b;
        rgba[i + 3u] = 0xffu;
    }
    return rgba;
}

std::vector<std::uint8_t> mixed_skip_v1_v4_rgba(std::uint32_t width)
{
    auto rgba = solid_rgba(width, 4u, 0u, 0u, 0u);
    const std::uint32_t macroblocks = width / 4u;
    for (std::uint32_t macroblock = 0u; macroblock < macroblocks; ++macroblock) {
        if (macroblock % 3u == 0u) {
            continue;
        }
        for (std::uint32_t y = 0u; y < 4u; ++y) {
            for (std::uint32_t x = 0u; x < 4u; ++x) {
                const std::size_t p =
                    (static_cast<std::size_t>(y) * width + macroblock * 4u + x) * 4u;
                const std::uint8_t gray = macroblock % 3u == 1u || ((x + y) & 1u) != 0u
                    ? 255u
                    : 0u;
                rgba[p] = gray;
                rgba[p + 1u] = gray;
                rgba[p + 2u] = gray;
            }
        }
    }
    return rgba;
}

std::size_t reference_nearest_codebook(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight,
    std::size_t *evaluated_terms = nullptr)
{
    constexpr std::size_t dimensions = 6u;
    if (evaluated_terms != nullptr) {
        *evaluated_terms = 0u;
    }
    std::size_t best = 0u;
    double best_distance = std::numeric_limits<double>::infinity();
    for (std::size_t c = 0u; c < codebook_count; ++c) {
        const std::size_t cb = c * dimensions;
        double distance = 0.0;
        for (std::size_t d = 0u; d < 4u; ++d) {
            const double delta = data[d] - centroids[cb + d];
            distance += delta * delta;
            if (evaluated_terms != nullptr) {
                ++*evaluated_terms;
            }
        }
        double delta = data[4] - centroids[cb + 4u];
        distance += static_cast<double>(chroma_weight) * delta * delta;
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
        delta = data[5] - centroids[cb + 5u];
        distance += static_cast<double>(chroma_weight) * delta * delta;
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
        if (distance < best_distance) {
            best_distance = distance;
            best = c;
        }
    }
    return best;
}

std::size_t reference_pruned_nearest_codebook(
    const std::int32_t *data,
    const double *centroids,
    std::size_t codebook_count,
    std::int32_t chroma_weight,
    std::size_t *evaluated_terms)
{
    constexpr std::size_t dimensions = 6u;
    if (evaluated_terms != nullptr) {
        *evaluated_terms = 0u;
    }
    if (codebook_count == 0u) {
        return 0u;
    }
    const double values[dimensions] = {
        static_cast<double>(data[0]),
        static_cast<double>(data[1]),
        static_cast<double>(data[2]),
        static_cast<double>(data[3]),
        static_cast<double>(data[4]),
        static_cast<double>(data[5]),
    };
    const double weight = static_cast<double>(chroma_weight);
    std::size_t best = 0u;
    double best_distance = std::numeric_limits<double>::infinity();
    for (std::size_t c = 0u; c < codebook_count; ++c) {
        const std::size_t cb = c * dimensions;
        double distance = 0.0;
        bool rejected = false;
        for (std::size_t d = 0u; d < 4u; ++d) {
            const double delta = values[d] - centroids[cb + d];
            distance += delta * delta;
            if (evaluated_terms != nullptr) {
                ++*evaluated_terms;
            }
            if (distance >= best_distance) {
                rejected = true;
                break;
            }
        }
        if (rejected) {
            continue;
        }
        double delta = values[4] - centroids[cb + 4u];
        distance += weight * delta * delta;
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
        if (distance >= best_distance) {
            continue;
        }
        delta = values[5] - centroids[cb + 5u];
        distance += weight * delta * delta;
        if (evaluated_terms != nullptr) {
            ++*evaluated_terms;
        }
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

} // namespace

HMC_TEST(cinepak_encoder_config_init_freezes_v1_defaults_and_tail_rules)
{
    struct ExtendedConfig {
        hmc_cinepak_encoder_config_t config;
        std::uint8_t tail[8];
    } extended;
    std::memset(&extended, 0xa5, sizeof(extended));
    HMC_EXPECT(hmc_cinepak_encoder_config_init(&extended.config, sizeof(extended)) ==
               HMC_STATUS_OK);
    const auto *value = &extended.config;
    HMC_EXPECT(value->struct_size == sizeof(extended));
    HMC_EXPECT(value->quality == 60);
    HMC_EXPECT(value->v1_size == 256);
    HMC_EXPECT(value->v4_size == 256);
    HMC_EXPECT(value->refine_iterations == 3);
    HMC_EXPECT(value->chroma_weight == 4);
    HMC_EXPECT(value->strips == 2);
    HMC_EXPECT(value->skip_threshold == 720);
    HMC_EXPECT(value->key_interval == 0);
    for (std::uint8_t byte : extended.tail) {
        HMC_EXPECT(byte == 0u);
    }

    hmc_cinepak_encoder_config_t small;
    std::memset(&small, 0x5a, sizeof(small));
    HMC_EXPECT(hmc_cinepak_encoder_config_init(
        &small, HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE - 1u) ==
        HMC_STATUS_BUFFER_TOO_SMALL);
    const auto *small_bytes = reinterpret_cast<const std::uint8_t *>(&small);
    for (std::size_t i = 0u; i < sizeof(small); ++i) {
        const std::uint8_t byte = small_bytes[i];
        HMC_EXPECT(byte == 0x5au);
    }
    HMC_EXPECT(hmc_cinepak_encoder_config_init(nullptr, sizeof(extended)) ==
               HMC_STATUS_INVALID_ARGUMENT);
}

HMC_TEST(cinepak_encoder_matches_kotlin_key_skip_inter_and_flags)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    const auto b = fixture_bytes("input_8x8_b.rgba");
    hmc_cinepak_encoder_config_t value = config();
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    HMC_EXPECT(encoder != nullptr);

    hmc_frame_flags_t flags = UINT32_C(0xfeedbeef);
    HMC_EXPECT(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags) ==
               fixture_bytes("cinepak_key.bin"));
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    HMC_EXPECT(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags) ==
               fixture_bytes("cinepak_all_skip.bin"));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
    HMC_EXPECT(encode(encoder, b, HMC_ENCODE_FLAG_NONE, &flags) ==
               fixture_bytes("cinepak_inter.bin"));
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);

    hmc_cinepak_encoder_destroy(encoder);
    hmc_cinepak_encoder_destroy(nullptr);
}

HMC_TEST(cinepak_encoder_outputs_decode_and_mux_to_all_kotlin_goldens)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    const auto b = fixture_bytes("input_8x8_b.rgba");
    const hmc_cinepak_encoder_config_t encoder_config = config();
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&encoder_config, &encoder) == HMC_STATUS_OK);
    hmc_frame_flags_t flags[3]{};
    std::vector<std::vector<std::uint8_t>> frames;
    frames.push_back(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags[0]));
    frames.push_back(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags[1]));
    frames.push_back(encode(encoder, b, HMC_ENCODE_FLAG_NONE, &flags[2]));

    hmc_cinepak_decoder_config_t decoder_config{};
    HMC_EXPECT(hmc_cinepak_decoder_config_init(&decoder_config, sizeof(decoder_config)) ==
               HMC_STATUS_OK);
    decoder_config.width = 8u;
    decoder_config.height = 8u;
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&decoder_config, &decoder) == HMC_STATUS_OK);
    const char *const argb_names[3] = {
        "cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb"};
    std::vector<std::uint32_t> pixels(64u);
    for (std::size_t i = 0u; i < frames.size(); ++i) {
        HMC_EXPECT(hmc_cinepak_decoder_decode(
            decoder, frames[i].data(), frames[i].size(), pixels.data(), pixels.size()) ==
            HMC_STATUS_OK);
        HMC_EXPECT(pixels == fixture_argb(argb_names[i]));
    }

    hmc_avi_muxer_config_t avi_config{};
    HMC_EXPECT(hmc_avi_muxer_config_init(&avi_config, sizeof(avi_config)) == HMC_STATUS_OK);
    avi_config.width = 8u;
    avi_config.height = 8u;
    avi_config.frame_rate_num = 10u;
    avi_config.frame_rate_den = 1u;
    avi_config.handler_fourcc = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
    avi_config.compression_fourcc = avi_config.handler_fourcc;
    avi_config.bit_count = 24u;
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&avi_config, &muxer) == HMC_STATUS_OK);
    for (std::size_t i = 0u; i < frames.size(); ++i) {
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            muxer, frames[i].data(), frames[i].size(), flags[i]) == HMC_STATUS_OK);
    }
    hmc_owned_buffer_t avi{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &avi) == HMC_STATUS_OK);
    const auto expected_avi = fixture_bytes("cvid_sample.avi");
    const bool exact_avi = avi.size == expected_avi.size() &&
        (avi.size == 0u || std::memcmp(avi.data, expected_avi.data(), expected_avi.size()) == 0);
    HMC_EXPECT(exact_avi);
    hmc_owned_buffer_release(&avi);
    hmc_avi_muxer_destroy(muxer);
    hmc_cinepak_decoder_destroy(decoder);
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_reset_force_key_and_key_interval_are_deterministic)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    hmc_cinepak_encoder_config_t value = config();
    value.key_interval = 2;
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    hmc_frame_flags_t flags = 0u;
    const auto first = encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    (void)encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
    const auto periodic = encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    HMC_EXPECT(periodic == first);
    (void)encode(encoder, a, HMC_ENCODE_FLAG_FORCE_KEY, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    (void)encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
    (void)encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    HMC_EXPECT(hmc_cinepak_encoder_reset(encoder) == HMC_STATUS_OK);
    HMC_EXPECT(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags) == first);
    HMC_EXPECT(hmc_cinepak_encoder_reset(nullptr) == HMC_STATUS_INVALID_ARGUMENT);
    hmc_cinepak_encoder_destroy(encoder);

    value.key_interval = 1;
    encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    (void)encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    (void)encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(flags == (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_validates_config_inputs_and_failures_are_atomic)
{
    hmc_cinepak_encoder_t *encoder = nullptr;
    hmc_cinepak_encoder_config_t value = config();
    const auto expect_create_failure = [&](hmc_status_t expected) {
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == expected);
        HMC_EXPECT(encoder == nullptr);
    };
    value.width = 6u;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.height = 0u;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.quality = 101;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.quality = -1;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.v1_size = 0;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.v1_size = 257;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.v4_size = 0;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.v4_size = 257;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.refine_iterations = -1;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.strips = 0;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.chroma_weight = -1;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.skip_threshold = -1;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.key_interval = -1;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.width = 65536u;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(); value.height = 65536u;
    expect_create_failure(HMC_STATUS_INVALID_ARGUMENT);
    value = config(65532u, 65532u);
    expect_create_failure(HMC_STATUS_OVERFLOW);

    struct ExtendedConfig {
        hmc_cinepak_encoder_config_t config;
        std::uint8_t tail[8];
    } extended{};
    HMC_EXPECT(hmc_cinepak_encoder_config_init(&extended.config, sizeof(extended)) ==
               HMC_STATUS_OK);
    extended.config.width = 8u;
    extended.config.height = 8u;
    HMC_EXPECT(hmc_cinepak_encoder_create(&extended.config, &encoder) == HMC_STATUS_OK);
    hmc_cinepak_encoder_destroy(encoder);
    encoder = nullptr;
    extended.tail[3] = 1u;
    HMC_EXPECT(hmc_cinepak_encoder_create(&extended.config, &encoder) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(encoder == nullptr);
    extended.tail[3] = 0u;
    extended.config.struct_size = HMC_CINEPAK_ENCODER_CONFIG_V1_SIZE - 1u;
    HMC_EXPECT(hmc_cinepak_encoder_create(&extended.config, &encoder) ==
               HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(encoder == nullptr);

    value = config();
    hmc_cinepak_encoder_t *occupied_handle = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &occupied_handle) == HMC_STATUS_OK);
    hmc_cinepak_encoder_t *const original_handle = occupied_handle;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &occupied_handle) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(occupied_handle == original_handle);
    hmc_cinepak_encoder_destroy(occupied_handle);
    occupied_handle = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(nullptr, &occupied_handle) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(occupied_handle == nullptr);
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);

    value = config();
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    const auto a = fixture_bytes("input_8x8_a.rgba");
    hmc_owned_buffer_t output{};
    hmc_frame_flags_t flags = UINT32_C(0xabcdef01);
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size() - 1u, HMC_ENCODE_FLAG_NONE, &output, &flags) ==
        HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size(), UINT32_C(0x80000000), &output, &flags) ==
        HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    std::uint8_t occupied_byte = 0u;
    output.data = &occupied_byte;
    output.size = 2u;
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &output, &flags) ==
        HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == &occupied_byte && output.size == 2u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    output.data = nullptr; output.size = 0u;
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &output, nullptr) ==
        HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, nullptr, a.size(), HMC_ENCODE_FLAG_NONE, &output, &flags) ==
        HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        nullptr, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &output, &flags) ==
        HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(flags == UINT32_C(0xabcdef01));
    HMC_EXPECT(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags) ==
               fixture_bytes("cinepak_key.bin"));
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_distributes_strip_rows_and_ignores_rgba_tail)
{
    hmc_cinepak_encoder_config_t value = config(4u, 20u);
    value.strips = 2;
    value.v1_size = 1;
    value.v4_size = 1;
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    std::vector<std::uint8_t> rgba(4u * 20u * 4u + 7u, 0u);
    hmc_frame_flags_t flags = 0u;
    const auto encoded = encode(encoder, rgba, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(encoded.size() >= 34u);
    if (encoded.size() >= 34u) {
        HMC_EXPECT(encoded[8] == 0u && encoded[9] == 2u);
        HMC_EXPECT(encoded[18] == 0u && encoded[19] == 8u);
        const std::size_t second = 10u + be24(encoded.data() + 11u);
        HMC_EXPECT(second + 10u < encoded.size());
        if (second + 10u < encoded.size()) {
            HMC_EXPECT(encoded[second + 8u] == 0u && encoded[second + 9u] == 12u);
        }
    }
    hmc_cinepak_encoder_destroy(encoder);
    encoder = nullptr;

    rgba.resize(4u * 20u * 4u);
    hmc_cinepak_encoder_t *exact_encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &exact_encoder) == HMC_STATUS_OK);
    HMC_EXPECT(encode(exact_encoder, rgba, HMC_ENCODE_FLAG_NONE, &flags) == encoded);
    hmc_cinepak_encoder_destroy(exact_encoder);

    value = config(4u, 4u);
    value.strips = 99;
    value.v1_size = 1;
    value.v4_size = 1;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    const auto clamped = encode(
        encoder, solid_rgba(4u, 4u, 0u, 0u, 0u), HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(clamped.size() >= 10u);
    if (clamped.size() >= 10u) {
        HMC_EXPECT(clamped[8] == 0u && clamped[9] == 1u);
    }
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_uses_kotlin_negative_math_and_fixed_point_yuv)
{
    HMC_EXPECT(honey::media::cinepak_encoder_test_floor_divide_power_of_two(-1) == -1);
    HMC_EXPECT(honey::media::cinepak_encoder_test_floor_divide_power_of_two(-8388608) == -1);
    HMC_EXPECT(honey::media::cinepak_encoder_test_floor_divide_power_of_two(-8388609) == -2);
    HMC_EXPECT(honey::media::cinepak_encoder_test_kotlin_round(-1.5) == -1);
    HMC_EXPECT(honey::media::cinepak_encoder_test_kotlin_round(-0.5) == 0);
    HMC_EXPECT(honey::media::cinepak_encoder_test_kotlin_round(0.5) == 1);

    const auto red = solid_rgba(2u, 2u, 255u, 0u, 0u);
    std::int32_t y[4]{};
    std::int32_t u[1]{};
    std::int32_t v[1]{};
    honey::media::cinepak_encoder_test_rgb_to_yuv(
        red.data(), 2u, 2u, y, u, v);
    for (std::int32_t value : y) {
        HMC_EXPECT(value == 72);
    }
    HMC_EXPECT(u[0] == -37);
    HMC_EXPECT(v[0] == 91);
}

HMC_TEST(cinepak_encoder_median_cut_preserves_dimension_sort_and_box_ties)
{
    const std::int32_t equal_range[] = {
        0, 10, 0, 0, 0, 0,
        10, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        10, 10, 0, 0, 0, 0,
    };
    std::int32_t codebook[18]{};
    std::uint32_t labels[5]{};
    std::size_t count = 0u;
    HMC_EXPECT(honey::media::cinepak_encoder_test_vector_quantize(
        equal_range, 4u, 2u, 0, 4, codebook, labels, &count) == HMC_STATUS_OK);
    HMC_EXPECT(count == 2u);
    HMC_EXPECT(codebook[0] == 0 && codebook[1] == 5);
    HMC_EXPECT(codebook[6] == 10 && codebook[7] == 5);
    HMC_EXPECT(labels[0] == 0u && labels[1] == 1u &&
               labels[2] == 0u && labels[3] == 1u);

    const std::int32_t stable_keys[] = {
        0, 4, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        0, 2, 0, 0, 0, 0,
        10, 1, 0, 0, 0, 0,
        10, 3, 0, 0, 0, 0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_vector_quantize(
        stable_keys, 5u, 2u, 0, 4, codebook, labels, &count) == HMC_STATUS_OK);
    HMC_EXPECT(labels[0] == 0u && labels[1] == 0u && labels[2] == 1u);

    const std::int32_t equal_box_ranges[] = {
        0, 0, 0, 0, 0, 0,
        4, 0, 0, 0, 0, 0,
        8, 0, 0, 0, 0, 0,
        12, 0, 0, 0, 0, 0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_vector_quantize(
        equal_box_ranges, 4u, 3u, 0, 4, codebook, labels, &count) == HMC_STATUS_OK);
    HMC_EXPECT(count == 3u);
    HMC_EXPECT(codebook[0] == 0 && codebook[6] == 10 && codebook[12] == 4);
    HMC_EXPECT(labels[0] == 0u && labels[1] == 2u &&
               labels[2] == 1u && labels[3] == 1u);

    const std::int32_t negative_half[] = {
        -1, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_vector_quantize(
        negative_half, 2u, 1u, 0, 4, codebook, labels, &count) == HMC_STATUS_OK);
    HMC_EXPECT(codebook[0] == 0);
    HMC_EXPECT(honey::media::cinepak_encoder_test_vector_quantize(
        negative_half, 2u, 1u, 1, 4, codebook, labels, &count) == HMC_STATUS_OK);
    HMC_EXPECT(codebook[0] == 0);
}

HMC_TEST(cinepak_encoder_lloyd_keeps_lower_tie_empty_cluster_and_final_labels)
{
    const std::int32_t tie_data[] = {5, 0, 0, 0, 0, 0};
    std::int32_t tie_codebook[] = {
        0, 0, 0, 0, 0, 0,
        10, 0, 0, 0, 0, 0,
    };
    std::uint32_t labels[3]{};
    HMC_EXPECT(honey::media::cinepak_encoder_test_lloyd_refine(
        tie_data, 1u, tie_codebook, 2u, 1, 4, labels) == HMC_STATUS_OK);
    HMC_EXPECT(labels[0] == 0u);
    HMC_EXPECT(tie_codebook[0] == 5);
    HMC_EXPECT(tie_codebook[6] == 10);

    const std::int32_t final_label_data[] = {
        4, 0, 0, 0, 0, 0,
        6, 0, 0, 0, 0, 0,
        100, 0, 0, 0, 0, 0,
    };
    std::int32_t final_codebook[] = {
        0, 0, 0, 0, 0, 0,
        10, 0, 0, 0, 0, 0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_lloyd_refine(
        final_label_data, 3u, final_codebook, 2u, 1, 4, labels) == HMC_STATUS_OK);
    HMC_EXPECT(final_codebook[0] == 4 && final_codebook[6] == 53);
    HMC_EXPECT(labels[0] == 0u && labels[1] == 1u && labels[2] == 1u);

    const std::int32_t chroma_data[] = {0, 0, 0, 0, 10, 10};
    const std::int32_t initial_codebook[] = {
        0, 0, 0, 0, 0, 0,
        10, 10, 10, 10, 10, 10,
    };
    std::int32_t low_weight_codebook[12];
    std::int32_t high_weight_codebook[12];
    std::memcpy(low_weight_codebook, initial_codebook, sizeof(initial_codebook));
    std::memcpy(high_weight_codebook, initial_codebook, sizeof(initial_codebook));
    HMC_EXPECT(honey::media::cinepak_encoder_test_lloyd_refine(
        chroma_data, 1u, low_weight_codebook, 2u, 1, 1, labels) == HMC_STATUS_OK);
    HMC_EXPECT(labels[0] == 0u);
    HMC_EXPECT(honey::media::cinepak_encoder_test_lloyd_refine(
        chroma_data, 1u, high_weight_codebook, 2u, 1, 3, labels) == HMC_STATUS_OK);
    HMC_EXPECT(labels[0] == 1u);
}

HMC_TEST(cinepak_encoder_lloyd_near_tie_uses_lower_index_without_contraction)
{
    const std::int32_t data[6]{};
    const double centroids[] = {
        0x1.ec39220f61c91p-7, 0x1.1354301b7d6c4p+0,
        0x1.c7b384c7b384cp+0, 0x1.bfcb517df12efp-4, 0.0, 0.0,
        0x1.1354301b7d6c4p+0, 0x1.bfcb517df12efp-4,
        0x1.ec39220f61c91p-7, 0x1.c7b384c7b384cp+0, 0.0, 0.0,
    };
    HMC_EXPECT(centroids[0] > 0.0 && centroids[0] < 1.0);
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook(
        data, centroids, 2u, 4) == 0u);
}

HMC_TEST(cinepak_nearest_codebook_counts_zero_match_and_first_term_rejection)
{
    const std::int32_t data[6]{};
    const double zero_first[] = {
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        10.0, 10.0, 10.0, 10.0, 10.0, 10.0,
        -10.0, -10.0, -10.0, -10.0, -10.0, -10.0,
    };
    std::size_t reference_terms = 0u;
    HMC_EXPECT(reference_nearest_codebook(
        data, zero_first, 3u, 4, &reference_terms) == 0u);
    HMC_EXPECT(reference_terms == 6u * 3u);
    std::size_t evaluated_terms = 0u;
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        data, zero_first, 3u, 4, &evaluated_terms) == 0u);
    HMC_EXPECT(evaluated_terms == 6u);

    const double rejected_after_first[] = {
        1.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        2.0, 50.0, 50.0, 50.0, 50.0, 50.0,
        -1.0, 50.0, 50.0, 50.0, 50.0, 50.0,
    };
    HMC_EXPECT(reference_nearest_codebook(
        data, rejected_after_first, 3u, 4, &reference_terms) == 0u);
    HMC_EXPECT(reference_terms == 6u * 3u);
    evaluated_terms = 0u;
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        data, rejected_after_first, 3u, 4, &evaluated_terms) == 0u);
    HMC_EXPECT(evaluated_terms == 8u);
    HMC_EXPECT(evaluated_terms < 6u * 3u);

    honey::media::cinepak_encoder_test_reset_nearest_conversion_diagnostics();
    evaluated_terms = 0u;
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        data, rejected_after_first, 3u, 4, &evaluated_terms) == 0u);
    auto conversions =
        honey::media::cinepak_encoder_test_nearest_conversion_diagnostics();
    HMC_EXPECT(conversions.data_conversions == 6u);
    HMC_EXPECT(conversions.weight_conversions == 1u);
    honey::media::cinepak_encoder_test_reset_nearest_conversion_diagnostics();
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        nullptr, nullptr, 0u, 4, &evaluated_terms) == 0u);
    conversions = honey::media::cinepak_encoder_test_nearest_conversion_diagnostics();
    HMC_EXPECT(conversions.data_conversions == 0u);
    HMC_EXPECT(conversions.weight_conversions == 1u);
}

HMC_TEST(cinepak_nearest_conversion_diagnostics_are_isolated_per_thread)
{
    std::atomic<bool> first_ready{false};
    std::atomic<bool> second_done{false};
    honey::media::CinepakNearestConversionDiagnostics first{};
    honey::media::CinepakNearestConversionDiagnostics second{};
    bool first_calls_ok = false;
    bool second_calls_ok = false;

    const auto exercise = [](
        std::size_t direct_nearest_calls,
        honey::media::CinepakNearestConversionDiagnostics *result,
        bool *calls_ok,
        std::atomic<bool> *ready,
        std::atomic<bool> *wait_for) {
        const std::int32_t data[6]{};
        const double centroid[6]{};
        std::size_t terms = 0u;
        bool ok = true;
        honey::media::cinepak_encoder_test_reset_nearest_conversion_diagnostics();
        for (std::size_t call = 0u; call < direct_nearest_calls; ++call) {
            const auto nearest =
                honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
                    data, centroid, 1u, 4, &terms);
            ok = nearest == 0u && ok;
        }
        std::int32_t codebook[6]{};
        std::uint32_t label = 0u;
        const auto status = honey::media::cinepak_encoder_test_lloyd_refine(
            data, 1u, codebook, 1u, 1, 4, &label);
        *calls_ok = ok && status == HMC_STATUS_OK;
        ready->store(true, std::memory_order_release);
        while (!wait_for->load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        *result =
            honey::media::cinepak_encoder_test_nearest_conversion_diagnostics();
    };

    honey::media::cinepak_encoder_test_reset_nearest_conversion_diagnostics();
    std::thread first_thread(
        exercise, 1u, &first, &first_calls_ok, &first_ready, &second_done);
    std::thread second_thread([&] {
        while (!first_ready.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        const std::int32_t data[6]{};
        const double centroid[6]{};
        std::size_t terms = 0u;
        bool ok = true;
        honey::media::cinepak_encoder_test_reset_nearest_conversion_diagnostics();
        for (std::size_t call = 0u; call < 2u; ++call) {
            const auto nearest =
                honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
                    data, centroid, 1u, 4, &terms);
            ok = nearest == 0u && ok;
        }
        std::int32_t codebook[6]{};
        std::uint32_t label = 0u;
        const auto status = honey::media::cinepak_encoder_test_lloyd_refine(
            data, 1u, codebook, 1u, 1, 4, &label);
        second_calls_ok = ok && status == HMC_STATUS_OK;
        second =
            honey::media::cinepak_encoder_test_nearest_conversion_diagnostics();
        second_done.store(true, std::memory_order_release);
    });
    first_thread.join();
    second_thread.join();

    const auto main =
        honey::media::cinepak_encoder_test_nearest_conversion_diagnostics();
    HMC_EXPECT(first_calls_ok);
    HMC_EXPECT(second_calls_ok);
    HMC_EXPECT(first.data_conversions == 12u && first.weight_conversions == 2u);
    HMC_EXPECT(second.data_conversions == 18u && second.weight_conversions == 3u);
    HMC_EXPECT(main.data_conversions == 0u && main.weight_conversions == 0u);
}

HMC_TEST(cinepak_nearest_codebook_matches_ordered_full_distance_corpus)
{
    constexpr std::size_t dimensions = 6u;
    const std::array<std::int32_t, dimensions> tie_data{{5, 0, 0, 0, 0, 0}};
    const double tie_centroids[] = {
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        10.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    };
    std::size_t terms = 0u;
    HMC_EXPECT(reference_nearest_codebook(
        tie_data.data(), tie_centroids, 2u, 4) == 0u);
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        tie_data.data(), tie_centroids, 2u, 4, &terms) == 0u);

    const std::array<std::int32_t, dimensions> later_data{{0, 0, 0, 0, 0, 0}};
    const double later_centroids[] = {
        0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        later_data.data(), later_centroids, 2u, 4, &terms) ==
        reference_nearest_codebook(later_data.data(), later_centroids, 2u, 4));

    const double near_tie_centroids[] = {
        0x1.ec39220f61c91p-7, 0x1.1354301b7d6c4p+0,
        0x1.c7b384c7b384cp+0, 0x1.bfcb517df12efp-4, 0.0, 0.0,
        0x1.1354301b7d6c4p+0, 0x1.bfcb517df12efp-4,
        0x1.ec39220f61c91p-7, 0x1.c7b384c7b384cp+0, 0.0, 0.0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        later_data.data(), near_tie_centroids, 2u, 4, &terms) ==
        reference_nearest_codebook(later_data.data(), near_tie_centroids, 2u, 4));

    const double infinity_centroids[] = {
        0.0, 0.0, 0.0, 0.0,
        std::numeric_limits<double>::infinity(),
        std::numeric_limits<double>::infinity(),
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    };
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        later_data.data(), infinity_centroids, 2u, 0, &terms) ==
        reference_nearest_codebook(later_data.data(), infinity_centroids, 2u, 0));

    const double finite_after_infinity[] = {
        std::numeric_limits<double>::infinity(),
        0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    };
    HMC_EXPECT(reference_nearest_codebook(
        later_data.data(), finite_after_infinity, 2u, 4) == 1u);
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        later_data.data(), finite_after_infinity, 2u, 4, &terms) == 1u);

    constexpr std::size_t codebooks = 7u;
    std::array<double, codebooks * dimensions> centroids{};
    for (std::size_t sample = 0u; sample < 41u; ++sample) {
        std::array<std::int32_t, dimensions> generated_data{};
        for (std::size_t d = 0u; d < dimensions; ++d) {
            generated_data[d] = static_cast<std::int32_t>(
                (sample * 37u + d * 11u) % 257u) - 128;
        }
        for (std::size_t c = 0u; c < codebooks; ++c) {
            for (std::size_t d = 0u; d < dimensions; ++d) {
                const std::int32_t whole = static_cast<std::int32_t>(
                    (sample * 7u + c * 53u + d * 29u) % 311u) - 155;
                centroids[c * dimensions + d] =
                    static_cast<double>(whole) + ((c + d) % 4u) * 0.25;
            }
        }
        for (const std::int32_t chroma_weight : {0, 1, 4}) {
            const std::size_t expected = reference_nearest_codebook(
                generated_data.data(), centroids.data(), codebooks, chroma_weight);
            HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
                generated_data.data(), centroids.data(), codebooks,
                chroma_weight, &terms) == expected);
        }
    }
}

HMC_TEST(cinepak_nearest_codebook_preserves_extremes_nan_signed_zero_and_each_prune)
{
    constexpr std::size_t dimensions = 6u;
    const auto expect_match = [](
        const std::int32_t *data,
        const double *centroids,
        std::size_t codebook_count,
        std::int32_t weight) {
        std::size_t expected_terms = 0u;
        std::size_t actual_terms = std::numeric_limits<std::size_t>::max();
        const std::size_t expected = reference_pruned_nearest_codebook(
            data, centroids, codebook_count, weight, &expected_terms);
        HMC_EXPECT(reference_nearest_codebook(
            data, centroids, codebook_count, weight) == expected);
        HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
            data, centroids, codebook_count, weight, &actual_terms) == expected);
        HMC_EXPECT(actual_terms == expected_terms);
    };

    const std::int32_t extremes[] = {
        std::numeric_limits<std::int32_t>::min(),
        std::numeric_limits<std::int32_t>::max(),
        std::numeric_limits<std::int32_t>::min(),
        std::numeric_limits<std::int32_t>::max(),
        std::numeric_limits<std::int32_t>::min(),
        std::numeric_limits<std::int32_t>::max(),
    };
    double extreme_centroids[2u * dimensions]{};
    for (std::size_t d = 0u; d < dimensions; ++d) {
        extreme_centroids[dimensions + d] = static_cast<double>(extremes[d]);
    }
    expect_match(extremes, extreme_centroids, 2u, 4);

    double nan_centroids[2u * dimensions]{};
    nan_centroids[0] = std::numeric_limits<double>::quiet_NaN();
    for (std::size_t d = 0u; d < dimensions; ++d) {
        nan_centroids[dimensions + d] = static_cast<double>(extremes[d]);
    }
    expect_match(extremes, nan_centroids, 2u, 4);

    const std::int32_t zeros[dimensions]{};
    const double signed_zero_centroid[] = {
        -0.0, +0.0, -0.0, +0.0, -0.0, +0.0,
    };
    expect_match(zeros, signed_zero_centroid, 1u, 4);

    const double prune_after_each_term[] = {
        0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
        2.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 2.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 2.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 2.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 2.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 2.0,
    };
    std::size_t expected_terms = 0u;
    HMC_EXPECT(reference_pruned_nearest_codebook(
        zeros, prune_after_each_term, 7u, 1, &expected_terms) == 0u);
    HMC_EXPECT(expected_terms == 27u);
    std::size_t actual_terms = 0u;
    HMC_EXPECT(honey::media::cinepak_encoder_test_nearest_codebook_with_term_count(
        zeros, prune_after_each_term, 7u, 1, &actual_terms) == 0u);
    HMC_EXPECT(actual_terms == expected_terms);

    expect_match(nullptr, nullptr, 0u, 4);
}

HMC_TEST(cinepak_encoder_quality_boundaries_control_v4_and_strict_zero_threshold)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    hmc_frame_flags_t flags = 0u;
    for (const int quality : {20, 21, 100}) {
        hmc_cinepak_encoder_config_t value = config();
        value.quality = quality;
        hmc_cinepak_encoder_t *encoder = nullptr;
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
        const auto frame = encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
        if (quality == 20) {
            HMC_EXPECT(first_strip_chunk(frame, 0x20u) == frame.size());
            HMC_EXPECT(first_strip_chunk(frame, 0x32u) != frame.size());
        } else {
            HMC_EXPECT(first_strip_chunk(frame, 0x20u) != frame.size());
            HMC_EXPECT(first_strip_chunk(frame, 0x30u) != frame.size());
        }
        hmc_cinepak_encoder_destroy(encoder);
    }

    hmc_cinepak_encoder_config_t uniform_config = config(4u, 4u);
    uniform_config.quality = 100;
    uniform_config.v1_size = 1;
    uniform_config.v4_size = 1;
    uniform_config.refine_iterations = 0;
    uniform_config.strips = 1;
    hmc_cinepak_encoder_t *uniform_encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&uniform_config, &uniform_encoder) == HMC_STATUS_OK);
    const auto uniform = encode(
        uniform_encoder,
        solid_rgba(4u, 4u, 40u, 40u, 40u),
        HMC_ENCODE_FLAG_NONE,
        &flags);
    HMC_EXPECT(first_strip_chunk(uniform, 0x20u) == uniform.size());
    HMC_EXPECT(first_strip_chunk(uniform, 0x32u) != uniform.size());
    hmc_cinepak_encoder_destroy(uniform_encoder);
}

HMC_TEST(cinepak_encoder_codebook_limits_emit_one_and_256_entries_with_index_255)
{
    hmc_frame_flags_t flags = 0u;
    hmc_cinepak_encoder_config_t one_config = config(4u, 4u);
    one_config.quality = 20;
    one_config.v1_size = 1;
    one_config.refine_iterations = 0;
    one_config.strips = 1;
    hmc_cinepak_encoder_t *one_encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&one_config, &one_encoder) == HMC_STATUS_OK);
    const auto one = encode(
        one_encoder, solid_rgba(4u, 4u, 9u, 9u, 9u), HMC_ENCODE_FLAG_NONE, &flags);
    const std::size_t one_codebook = first_strip_chunk(one, 0x22u);
    HMC_EXPECT(one_codebook != one.size());
    if (one_codebook != one.size() && one.size() >= one_codebook + 4u) {
        HMC_EXPECT(be24(one.data() + one_codebook + 1u) == 10u);
    }
    hmc_cinepak_encoder_destroy(one_encoder);

    constexpr std::uint32_t width = 1024u;
    hmc_cinepak_encoder_config_t full_config = config(width, 4u);
    full_config.quality = 20;
    full_config.v1_size = 256;
    full_config.refine_iterations = 0;
    full_config.strips = 1;
    std::vector<std::uint8_t> rgba(static_cast<std::size_t>(width) * 4u * 4u);
    for (std::uint32_t block = 0u; block < 256u; ++block) {
        for (std::uint32_t y = 0u; y < 4u; ++y) {
            for (std::uint32_t x = 0u; x < 4u; ++x) {
                const std::size_t p =
                    (static_cast<std::size_t>(y) * width + block * 4u + x) * 4u;
                rgba[p] = static_cast<std::uint8_t>(block);
                rgba[p + 1u] = static_cast<std::uint8_t>(block);
                rgba[p + 2u] = static_cast<std::uint8_t>(block);
                rgba[p + 3u] = 0xffu;
            }
        }
    }
    hmc_cinepak_encoder_t *full_encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&full_config, &full_encoder) == HMC_STATUS_OK);
    const auto full = encode(full_encoder, rgba, HMC_ENCODE_FLAG_NONE, &flags);
    const std::size_t full_codebook = first_strip_chunk(full, 0x22u);
    const std::size_t vectors = first_strip_chunk(full, 0x32u);
    HMC_EXPECT(full_codebook != full.size() && vectors != full.size());
    if (full_codebook != full.size() && vectors != full.size()) {
        HMC_EXPECT(be24(full.data() + full_codebook + 1u) == 1540u);
        HMC_EXPECT(be24(full.data() + vectors + 1u) == 260u);
        HMC_EXPECT(full.size() > vectors + 4u + 255u);
        if (full.size() > vectors + 4u + 255u) {
            HMC_EXPECT(full[vectors + 4u + 255u] == 255u);
        }
    }
    hmc_cinepak_encoder_destroy(full_encoder);
}

HMC_TEST(cinepak_encoder_skip_threshold_is_inclusive_and_uses_quantized_reference)
{
    auto encode_pair = [](std::int32_t threshold, const std::vector<std::uint8_t> &second) {
        hmc_cinepak_encoder_config_t value = config(4u, 4u);
        value.quality = 20;
        value.v1_size = 1;
        value.v4_size = 1;
        value.refine_iterations = 0;
        value.strips = 1;
        value.skip_threshold = threshold;
        hmc_cinepak_encoder_t *encoder = nullptr;
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
        hmc_frame_flags_t flags = 0u;
        (void)encode(
            encoder, solid_rgba(4u, 4u, 0u, 0u, 0u), HMC_ENCODE_FLAG_NONE, &flags);
        const auto frame = encode(encoder, second, HMC_ENCODE_FLAG_NONE, &flags);
        hmc_cinepak_encoder_destroy(encoder);
        return frame;
    };
    auto one_red = solid_rgba(4u, 4u, 0u, 0u, 0u);
    one_red[0] = 255u;
    const auto at_threshold = encode_pair(7520, one_red);
    const auto above_threshold = encode_pair(7519, one_red);
    const std::size_t at_vector = first_strip_chunk(at_threshold, 0x31u);
    const std::size_t above_vector = first_strip_chunk(above_threshold, 0x31u);
    HMC_EXPECT(at_vector != at_threshold.size() && above_vector != above_threshold.size());
    if (at_vector != at_threshold.size() && above_vector != above_threshold.size() &&
        at_threshold.size() >= at_vector + 8u &&
        above_threshold.size() >= above_vector + 9u) {
        HMC_EXPECT(be24(at_threshold.data() + at_vector + 1u) == 8u);
        HMC_EXPECT(at_threshold[at_vector + 4u] == 0u);
        HMC_EXPECT(be24(above_threshold.data() + above_vector + 1u) == 9u);
        HMC_EXPECT(above_threshold[above_vector + 4u] == 0x80u);
    }

    hmc_cinepak_encoder_config_t lossy_config = config();
    lossy_config.quality = 20;
    lossy_config.v1_size = 1;
    lossy_config.refine_iterations = 0;
    lossy_config.strips = 1;
    lossy_config.skip_threshold = 0;
    hmc_cinepak_encoder_t *lossy = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&lossy_config, &lossy) == HMC_STATUS_OK);
    const auto a = fixture_bytes("input_8x8_a.rgba");
    hmc_frame_flags_t flags = 0u;
    (void)encode(lossy, a, HMC_ENCODE_FLAG_NONE, &flags);
    const auto repeated = encode(lossy, a, HMC_ENCODE_FLAG_NONE, &flags);
    const std::size_t vector = first_strip_chunk(repeated, 0x31u);
    HMC_EXPECT(vector != repeated.size());
    if (vector != repeated.size()) {
        HMC_EXPECT(repeated[vector + 4u] != 0u);
    }
    hmc_cinepak_encoder_destroy(lossy);
}

HMC_TEST(cinepak_encoder_flag_words_are_inserted_at_the_live_vector_cursor)
{
    hmc_frame_flags_t flags = 0u;
    for (const std::uint32_t macroblocks : {31u, 32u, 33u}) {
        hmc_cinepak_encoder_config_t value = config(macroblocks * 4u, 4u);
        value.quality = 20;
        value.v1_size = 1;
        value.refine_iterations = 0;
        value.strips = 1;
        value.skip_threshold = 0;
        hmc_cinepak_encoder_t *encoder = nullptr;
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
        const auto black = solid_rgba(value.width, value.height, 0u, 0u, 0u);
        (void)encode(encoder, black, HMC_ENCODE_FLAG_NONE, &flags);
        const auto skipped = encode(encoder, black, HMC_ENCODE_FLAG_NONE, &flags);
        const std::size_t vector = first_strip_chunk(skipped, 0x31u);
        HMC_EXPECT(vector != skipped.size());
        const std::size_t required = macroblocks <= 32u ? 8u : 12u;
        if (vector != skipped.size() && skipped.size() >= vector + required) {
            HMC_EXPECT(be24(skipped.data() + vector + 1u) ==
                       (macroblocks <= 32u ? 8u : 12u));
            const std::size_t words = macroblocks <= 32u ? 4u : 8u;
            for (std::size_t i = 0u; i < words; ++i) {
                HMC_EXPECT(skipped[vector + 4u + i] == 0u);
            }
        }
        hmc_cinepak_encoder_destroy(encoder);
    }

    hmc_cinepak_encoder_config_t value = config(68u, 4u);
    value.quality = 20;
    value.v1_size = 1;
    value.refine_iterations = 0;
    value.strips = 1;
    value.skip_threshold = 0;
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    (void)encode(
        encoder, solid_rgba(68u, 4u, 0u, 0u, 0u), HMC_ENCODE_FLAG_NONE, &flags);
    const auto coded = encode(
        encoder, solid_rgba(68u, 4u, 255u, 255u, 255u), HMC_ENCODE_FLAG_NONE, &flags);
    const std::size_t vector = first_strip_chunk(coded, 0x31u);
    HMC_EXPECT(vector != coded.size());
    if (vector != coded.size() && coded.size() >= vector + 29u) {
        HMC_EXPECT(be24(coded.data() + vector + 1u) == 29u);
        HMC_EXPECT(coded[vector + 4u] == 0xaau && coded[vector + 5u] == 0xaau &&
                   coded[vector + 6u] == 0xaau && coded[vector + 7u] == 0xaau);
        for (std::size_t i = vector + 8u; i < vector + 24u; ++i) {
            HMC_EXPECT(coded[i] == 0u);
        }
        HMC_EXPECT(coded[vector + 24u] == 0x80u && coded[vector + 25u] == 0u &&
                   coded[vector + 26u] == 0u && coded[vector + 27u] == 0u &&
                   coded[vector + 28u] == 0u);
    } else {
        HMC_EXPECT(false);
    }
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_mixed_skip_v1_v4_inserts_next_word_before_live_index)
{
    constexpr std::uint32_t width = 80u;
    hmc_cinepak_encoder_config_t value = config(width, 4u);
    value.quality = 100;
    value.refine_iterations = 0;
    value.strips = 1;
    value.skip_threshold = 0;
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    hmc_frame_flags_t flags = 0u;
    const auto black = solid_rgba(width, 4u, 0u, 0u, 0u);
    (void)encode(encoder, black, HMC_ENCODE_FLAG_NONE, &flags);
    const auto mixed = mixed_skip_v1_v4_rgba(width);
    const auto frame = encode(encoder, mixed, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(first_strip_chunk(frame, 0x20u) != frame.size());
    const std::size_t vector = first_strip_chunk(frame, 0x31u);
    HMC_EXPECT(vector != frame.size());
    if (vector != frame.size() && frame.size() >= vector + 43u) {
        HMC_EXPECT(be24(frame.data() + vector + 1u) == 43u);
        HMC_EXPECT(frame[vector + 4u] == 0x5au && frame[vector + 5u] == 0xd6u &&
                   frame[vector + 6u] == 0xb5u && frame[vector + 7u] == 0xadu);
        HMC_EXPECT(frame[vector + 38u] == 0u && frame[vector + 39u] == 0u &&
                   frame[vector + 40u] == 0u && frame[vector + 41u] == 0u);
    } else {
        HMC_EXPECT(false);
    }
    hmc_cinepak_encoder_destroy(encoder);
}

HMC_TEST(cinepak_encoder_reuses_scratch_and_keeps_published_frames_independent)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    const auto b = fixture_bytes("input_8x8_b.rgba");
    const hmc_cinepak_encoder_config_t value = config();
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);

    hmc_owned_buffer_t first{};
    hmc_owned_buffer_t second{};
    hmc_owned_buffer_t after_reset{};
    hmc_frame_flags_t flags = 0u;

    honey::media::cinepak_encoder_test_clear_allocation_failure();
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &first, &flags) ==
        HMC_STATUS_OK);
    HMC_EXPECT(honey::media::cinepak_encoder_test_allocation_count() == 1u);
    const std::vector<std::uint8_t> first_snapshot(
        first.data, first.data + first.size);

    honey::media::cinepak_encoder_test_clear_allocation_failure();
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, b.data(), b.size(), HMC_ENCODE_FLAG_NONE, &second, &flags) ==
        HMC_STATUS_OK);
    HMC_EXPECT(honey::media::cinepak_encoder_test_allocation_count() == 1u);
    HMC_EXPECT(first.data != second.data);
    HMC_EXPECT(first.size == first_snapshot.size());
    if (first.size == first_snapshot.size()) {
        HMC_EXPECT(std::memcmp(
            first.data, first_snapshot.data(), first.size) == 0);
    }
    const std::vector<std::uint8_t> second_snapshot(
        second.data, second.data + second.size);

    HMC_EXPECT(hmc_cinepak_encoder_reset(encoder) == HMC_STATUS_OK);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
    HMC_EXPECT(hmc_cinepak_encoder_encode(
        encoder, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &after_reset, &flags) ==
        HMC_STATUS_OK);
    HMC_EXPECT(honey::media::cinepak_encoder_test_allocation_count() == 1u);
    HMC_EXPECT(first.data != after_reset.data && second.data != after_reset.data);
    HMC_EXPECT(std::memcmp(
        first.data, first_snapshot.data(), first_snapshot.size()) == 0);
    HMC_EXPECT(std::memcmp(
        second.data, second_snapshot.data(), second_snapshot.size()) == 0);

    hmc_owned_buffer_release(&after_reset);
    hmc_owned_buffer_release(&second);
    hmc_owned_buffer_release(&first);
    hmc_cinepak_encoder_destroy(encoder);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
}

HMC_TEST(cinepak_encoder_allocation_failures_preserve_state_and_retry)
{
    const auto a = fixture_bytes("input_8x8_a.rgba");
    const hmc_cinepak_encoder_config_t value = config();
    honey::media::cinepak_encoder_test_clear_allocation_failure();
    hmc_cinepak_encoder_t *probe = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &probe) == HMC_STATUS_OK);
    const std::size_t create_count = honey::media::cinepak_encoder_test_allocation_count();
    HMC_EXPECT(create_count != 0u);
    hmc_cinepak_encoder_destroy(probe);
    for (std::size_t nth = 1u; nth <= create_count; ++nth) {
        honey::media::cinepak_encoder_test_fail_nth_allocation(nth);
        hmc_cinepak_encoder_t *failed = nullptr;
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &failed) == HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(failed == nullptr);
    }
    honey::media::cinepak_encoder_test_clear_allocation_failure();

    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
    hmc_frame_flags_t flags = 0u;
    const auto expected = encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags);
    HMC_EXPECT(hmc_cinepak_encoder_reset(encoder) == HMC_STATUS_OK);
    const std::size_t allocations = honey::media::cinepak_encoder_test_allocation_count();
    HMC_EXPECT(allocations != 0u);
    for (std::size_t nth = 1u; nth <= allocations; ++nth) {
        honey::media::cinepak_encoder_test_fail_nth_allocation(nth);
        hmc_owned_buffer_t output{};
        flags = UINT32_C(0x12345678);
        HMC_EXPECT(hmc_cinepak_encoder_encode(
            encoder, a.data(), a.size(), HMC_ENCODE_FLAG_NONE, &output, &flags) ==
            HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(output.data == nullptr && output.size == 0u);
        HMC_EXPECT(flags == UINT32_C(0x12345678));
        honey::media::cinepak_encoder_test_clear_allocation_failure();
        HMC_EXPECT(encode(encoder, a, HMC_ENCODE_FLAG_NONE, &flags) == expected);
        HMC_EXPECT(hmc_cinepak_encoder_reset(encoder) == HMC_STATUS_OK);
    }
    hmc_cinepak_encoder_destroy(encoder);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
}

HMC_TEST(cinepak_encoder_independent_handles_and_mixed_inter_oom_are_deterministic)
{
    constexpr std::uint32_t width = 80u;
    hmc_cinepak_encoder_config_t value = config(width, 4u);
    value.quality = 100;
    value.refine_iterations = 0;
    value.strips = 1;
    value.skip_threshold = 0;
    const auto black = solid_rgba(width, 4u, 0u, 0u, 0u);
    const auto mixed = mixed_skip_v1_v4_rgba(width);

    hmc_cinepak_encoder_t *control = nullptr;
    hmc_cinepak_encoder_t *independent = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &control) == HMC_STATUS_OK);
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &independent) == HMC_STATUS_OK);
    hmc_frame_flags_t control_flags = 0u;
    hmc_frame_flags_t independent_flags = 0u;
    const auto key = encode(control, black, HMC_ENCODE_FLAG_NONE, &control_flags);
    HMC_EXPECT(encode(independent, black, HMC_ENCODE_FLAG_NONE, &independent_flags) == key);
    const auto expected = encode(control, mixed, HMC_ENCODE_FLAG_NONE, &control_flags);
    HMC_EXPECT(encode(independent, mixed, HMC_ENCODE_FLAG_NONE, &independent_flags) == expected);
    HMC_EXPECT(control_flags == HMC_FRAME_FLAG_KEY_KNOWN);
    HMC_EXPECT(independent_flags == HMC_FRAME_FLAG_KEY_KNOWN);
    hmc_cinepak_encoder_destroy(control);
    hmc_cinepak_encoder_destroy(independent);

    hmc_cinepak_encoder_t *probe = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &probe) == HMC_STATUS_OK);
    (void)encode(probe, black, HMC_ENCODE_FLAG_NONE, &control_flags);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
    (void)encode(probe, mixed, HMC_ENCODE_FLAG_NONE, &control_flags);
    const std::size_t allocations = honey::media::cinepak_encoder_test_allocation_count();
    HMC_EXPECT(allocations != 0u);
    hmc_cinepak_encoder_destroy(probe);

    for (std::size_t nth = 1u; nth <= allocations; ++nth) {
        hmc_cinepak_encoder_t *encoder = nullptr;
        honey::media::cinepak_encoder_test_clear_allocation_failure();
        HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
        (void)encode(encoder, black, HMC_ENCODE_FLAG_NONE, &control_flags);
        honey::media::cinepak_encoder_test_fail_nth_allocation(nth);
        hmc_owned_buffer_t output{};
        hmc_frame_flags_t flags = UINT32_C(0x76543210);
        HMC_EXPECT(hmc_cinepak_encoder_encode(
            encoder, mixed.data(), mixed.size(), HMC_ENCODE_FLAG_NONE, &output, &flags) ==
            HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(output.data == nullptr && output.size == 0u);
        HMC_EXPECT(flags == UINT32_C(0x76543210));
        honey::media::cinepak_encoder_test_clear_allocation_failure();
        HMC_EXPECT(encode(encoder, mixed, HMC_ENCODE_FLAG_NONE, &flags) == expected);
        HMC_EXPECT(flags == HMC_FRAME_FLAG_KEY_KNOWN);
        hmc_cinepak_encoder_destroy(encoder);
    }
    honey::media::cinepak_encoder_test_clear_allocation_failure();
}

HMC_TEST(cinepak_encoder_reset_is_allocation_free_under_fault_injection)
{
    hmc_cinepak_encoder_config_t value = config();
    hmc_cinepak_encoder_t *encoder = nullptr;
    HMC_EXPECT(hmc_cinepak_encoder_create(&value, &encoder) == HMC_STATUS_OK);
    honey::media::cinepak_encoder_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_cinepak_encoder_reset(encoder) == HMC_STATUS_OK);
    HMC_EXPECT(honey::media::cinepak_encoder_test_allocation_count() == 0u);
    honey::media::cinepak_encoder_test_clear_allocation_failure();
    hmc_cinepak_encoder_destroy(encoder);
}
