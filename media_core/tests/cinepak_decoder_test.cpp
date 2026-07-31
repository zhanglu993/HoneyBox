#include "honey_media_core/media_core.h"

#include "cinepak_common.hpp"
#include "cinepak_decoder.hpp"
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
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>());
}

hmc_cinepak_decoder_config_t decoder_config(
    std::uint32_t width,
    std::uint32_t height)
{
    hmc_cinepak_decoder_config_t config{};
    HMC_EXPECT(hmc_cinepak_decoder_config_init(&config, sizeof(config)) ==
               HMC_STATUS_OK);
    config.width = width;
    config.height = height;
    return config;
}

std::vector<std::uint32_t> fixture_argb(const char *name)
{
    const std::vector<std::uint8_t> bytes = fixture_bytes(name);
    HMC_EXPECT((bytes.size() & 3u) == 0u);
    std::vector<std::uint32_t> pixels(bytes.size() / 4u);
    for (std::size_t i = 0u; i < pixels.size(); ++i) {
        const std::size_t p = i * 4u;
        pixels[i] =
            static_cast<std::uint32_t>(bytes[p]) |
            (static_cast<std::uint32_t>(bytes[p + 1u]) << 8u) |
            (static_cast<std::uint32_t>(bytes[p + 2u]) << 16u) |
            (static_cast<std::uint32_t>(bytes[p + 3u]) << 24u);
    }
    return pixels;
}

void append_be16(std::vector<std::uint8_t> &bytes, std::uint32_t value)
{
    bytes.push_back(static_cast<std::uint8_t>(value >> 8u));
    bytes.push_back(static_cast<std::uint8_t>(value));
}

void append_be24(std::vector<std::uint8_t> &bytes, std::size_t value)
{
    bytes.push_back(static_cast<std::uint8_t>(value >> 16u));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8u));
    bytes.push_back(static_cast<std::uint8_t>(value));
}

void append_be32(std::vector<std::uint8_t> &bytes, std::uint32_t value)
{
    bytes.push_back(static_cast<std::uint8_t>(value >> 24u));
    bytes.push_back(static_cast<std::uint8_t>(value >> 16u));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8u));
    bytes.push_back(static_cast<std::uint8_t>(value));
}

void write_be16(std::vector<std::uint8_t> &bytes, std::size_t offset, std::uint32_t value)
{
    bytes[offset] = static_cast<std::uint8_t>(value >> 8u);
    bytes[offset + 1u] = static_cast<std::uint8_t>(value);
}

void write_be24(std::vector<std::uint8_t> &bytes, std::size_t offset, std::size_t value)
{
    bytes[offset] = static_cast<std::uint8_t>(value >> 16u);
    bytes[offset + 1u] = static_cast<std::uint8_t>(value >> 8u);
    bytes[offset + 2u] = static_cast<std::uint8_t>(value);
}

using Entry = std::array<std::uint8_t, 6u>;

std::vector<std::uint8_t> codebook(const std::vector<Entry> &entries)
{
    std::vector<std::uint8_t> body;
    for (const Entry &entry : entries) {
        for (std::uint8_t value : entry) {
            body.push_back(value);
        }
    }
    return body;
}

std::vector<std::uint8_t> chunk(
    std::uint8_t id,
    const std::vector<std::uint8_t> &body)
{
    std::vector<std::uint8_t> result{id};
    append_be24(result, body.size() + 4u);
    for (std::uint8_t value : body) {
        result.push_back(value);
    }
    return result;
}

std::vector<std::uint8_t> strip(
    std::uint8_t id,
    std::uint32_t width,
    std::uint32_t band_height,
    const std::vector<std::vector<std::uint8_t>> &chunks)
{
    std::vector<std::uint8_t> result{id, 0u, 0u, 0u};
    append_be16(result, 0u);
    append_be16(result, 0u);
    append_be16(result, band_height);
    append_be16(result, width);
    for (const auto &value : chunks) {
        for (std::uint8_t byte : value) {
            result.push_back(byte);
        }
    }
    write_be24(result, 1u, result.size());
    return result;
}

std::vector<std::uint8_t> frame(
    std::uint8_t flags,
    std::uint32_t width,
    std::uint32_t height,
    const std::vector<std::vector<std::uint8_t>> &strips)
{
    std::vector<std::uint8_t> result{flags, 0u, 0u, 0u};
    append_be16(result, width);
    append_be16(result, height);
    append_be16(result, static_cast<std::uint32_t>(strips.size()));
    for (const auto &value : strips) {
        for (std::uint8_t byte : value) {
            result.push_back(byte);
        }
    }
    write_be24(result, 1u, result.size());
    return result;
}

std::vector<std::uint8_t> v1_frame(
    std::uint8_t frame_flags,
    std::uint32_t width,
    std::uint32_t height,
    const Entry &entry)
{
    std::vector<std::uint8_t> indexes(
        static_cast<std::size_t>(width / 4u) * (height / 4u), 0u);
    return frame(
        frame_flags,
        width,
        height,
        {strip(
            frame_flags == 0u ? 0x10u : 0x11u,
            width,
            height,
            {chunk(0x22u, codebook({entry})),
             chunk(frame_flags == 0u ? 0x32u : 0x31u, indexes)})});
}

bool decode(
    hmc_cinepak_decoder_t *decoder,
    const std::vector<std::uint8_t> &encoded,
    std::vector<std::uint32_t> *pixels)
{
    return hmc_cinepak_decoder_decode(
               decoder,
               encoded.data(),
               encoded.size(),
               pixels->data(),
               pixels->size()) == HMC_STATUS_OK;
}

std::vector<std::uint32_t> decode_fresh(
    std::uint32_t width,
    std::uint32_t height,
    const std::vector<std::uint8_t> &key)
{
    const hmc_cinepak_decoder_config_t config = decoder_config(width, height);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(
        static_cast<std::size_t>(width) * height, UINT32_C(0x12345678));
    HMC_EXPECT(decode(decoder, key, &pixels));
    hmc_cinepak_decoder_destroy(decoder);
    return pixels;
}

void expect_failure_preserves_state(
    hmc_cinepak_decoder_t *decoder,
    const std::vector<std::uint8_t> &bad,
    hmc_status_t expected_status,
    const std::vector<std::uint8_t> &valid_inter,
    const std::vector<std::uint32_t> &expected_inter)
{
    std::vector<std::uint32_t> pixels(expected_inter.size(), UINT32_C(0x10203040));
    const std::vector<std::uint32_t> before = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   bad.data(),
                   bad.size(),
                   pixels.data(),
                   pixels.size()) == expected_status);
    HMC_EXPECT(pixels == before);
    HMC_EXPECT(decode(decoder, valid_inter, &pixels));
    HMC_EXPECT(pixels == expected_inter);
}

} // namespace

HMC_TEST(cinepak_decoder_matches_reference_sequence)
{
    const hmc_cinepak_decoder_config_t config = decoder_config(8u, 8u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);

    const char *encoded_names[] = {
        "cinepak_key.bin", "cinepak_all_skip.bin", "cinepak_inter.bin"};
    const char *argb_names[] = {
        "cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb"};
    std::vector<std::uint32_t> pixels(65u, UINT32_C(0x10203040));
    for (std::size_t i = 0u; i < 3u; ++i) {
        const std::vector<std::uint8_t> encoded = fixture_bytes(encoded_names[i]);
        const std::vector<std::uint32_t> expected = fixture_argb(argb_names[i]);
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       encoded.data(),
                       encoded.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OK);
        HMC_EXPECT(std::memcmp(
                       pixels.data(),
                       expected.data(),
                       expected.size() * sizeof(std::uint32_t)) == 0);
        HMC_EXPECT(pixels[64u] == UINT32_C(0x10203040));
    }
    hmc_cinepak_decoder_destroy(decoder);
}

HMC_TEST(cinepak_decoder_config_handle_and_capacity_contracts)
{
    hmc_cinepak_decoder_config_t unchanged{
        UINT32_C(0xaabbccdd), 11u, 22u};
    const hmc_cinepak_decoder_config_t before = unchanged;
    HMC_EXPECT(hmc_cinepak_decoder_config_init(nullptr, sizeof(unchanged)) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_cinepak_decoder_config_init(
                   &unchanged, HMC_CINEPAK_DECODER_CONFIG_V1_SIZE - 1u) ==
               HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(std::memcmp(&unchanged, &before, sizeof(before)) == 0);

    struct ExtendedConfig {
        hmc_cinepak_decoder_config_t config;
        std::uint8_t tail[8];
    } extended_storage{};
    std::memset(&extended_storage, 0xa5, sizeof(extended_storage));
    auto *extended = &extended_storage.config;
    HMC_EXPECT(hmc_cinepak_decoder_config_init(
                   extended, sizeof(extended_storage)) == HMC_STATUS_OK);
    HMC_EXPECT(extended->struct_size == sizeof(extended_storage));
    HMC_EXPECT(std::all_of(
        extended_storage.tail,
        extended_storage.tail + sizeof(extended_storage.tail),
        [](std::uint8_t value) { return value == 0u; }));
    extended->width = 4u;
    extended->height = 4u;

    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(extended, &decoder) == HMC_STATUS_OK);
    hmc_cinepak_decoder_destroy(decoder);
    decoder = nullptr;
    extended_storage.tail[7u] = 1u;
    HMC_EXPECT(hmc_cinepak_decoder_create(extended, &decoder) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(decoder == nullptr);
    extended_storage.tail[7u] = 0u;

    auto *sentinel = reinterpret_cast<hmc_cinepak_decoder_t *>(
        static_cast<std::uintptr_t>(1u));
    HMC_EXPECT(hmc_cinepak_decoder_create(extended, &sentinel) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(sentinel == reinterpret_cast<hmc_cinepak_decoder_t *>(
                               static_cast<std::uintptr_t>(1u)));

    for (const auto &config : {
             decoder_config(0u, 4u),
             decoder_config(4u, 0u),
             decoder_config(2u, 4u),
             decoder_config(4u, 6u),
             decoder_config(65536u, 4u),
             decoder_config(4u, 65536u)}) {
        decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_INVALID_ARGUMENT);
        HMC_EXPECT(decoder == nullptr);
    }
    HMC_EXPECT(hmc_cinepak_decoder_create(nullptr, &decoder) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(decoder == nullptr);
    HMC_EXPECT(hmc_cinepak_decoder_create(extended, nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);
    hmc_cinepak_decoder_destroy(nullptr);
}

HMC_TEST(cinepak_v1_uses_signed_floor_shift_quadrants_clipping_and_top_down_argb)
{
    const Entry entry{0u, 20u, 240u, 255u, 0xfdu, 5u};
    const std::vector<std::uint8_t> encoded = v1_frame(0u, 4u, 4u, entry);
    const std::vector<std::uint32_t> pixels = decode_fresh(4u, 4u, encoded);
    const std::uint32_t expected[4] = {
        UINT32_C(0xff0a0000),
        UINT32_C(0xff1e110e),
        UINT32_C(0xfffaedea),
        UINT32_C(0xfffffcf9)};
    for (std::size_t y = 0u; y < 4u; ++y) {
        for (std::size_t x = 0u; x < 4u; ++x) {
            const std::size_t quadrant = (y / 2u) * 2u + x / 2u;
            HMC_EXPECT(pixels[y * 4u + x] == expected[quadrant]);
        }
    }
}

HMC_TEST(cinepak_signed_chroma_boundaries_are_portable_and_reconstruct_exactly)
{
    HMC_EXPECT(honey::media::decode_cinepak_signed_byte(0x80u) == -128);
    HMC_EXPECT(honey::media::decode_cinepak_signed_byte(0xffu) == -1);

    const Entry minimum_u_negative_one_v{
        128u, 128u, 128u, 128u, 0x80u, 0xffu};
    const std::vector<std::uint32_t> first = decode_fresh(
        4u, 4u, v1_frame(0u, 4u, 4u, minimum_u_negative_one_v));
    HMC_EXPECT(std::all_of(first.begin(), first.end(), [](std::uint32_t value) {
        return value == UINT32_C(0xff7ec100);
    }));

    const Entry negative_one_u_minimum_v{
        128u, 128u, 128u, 128u, 0xffu, 0x80u};
    const std::vector<std::uint32_t> second = decode_fresh(
        4u, 4u, v1_frame(0u, 4u, 4u, negative_one_u_minimum_v));
    HMC_EXPECT(std::all_of(second.begin(), second.end(), [](std::uint32_t value) {
        return value == UINT32_C(0xff00ff7e);
    }));
}

HMC_TEST(cinepak_v4_uses_quadrant_index_order_and_row_major_luma)
{
    const std::vector<Entry> entries{
        Entry{1u, 2u, 3u, 4u, 0u, 0u},
        Entry{5u, 6u, 7u, 8u, 0u, 0u},
        Entry{9u, 10u, 11u, 12u, 0u, 0u},
        Entry{13u, 14u, 15u, 16u, 0u, 0u}};
    std::vector<std::uint8_t> vectors;
    append_be32(vectors, UINT32_C(0x80000000));
    for (std::uint8_t value : std::array<std::uint8_t, 4u>{0u, 1u, 2u, 3u}) {
        vectors.push_back(value);
    }
    const std::vector<std::uint8_t> encoded = frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x20u, codebook(entries)), chunk(0x30u, vectors)})});
    const std::vector<std::uint32_t> pixels = decode_fresh(4u, 4u, encoded);
    const std::uint32_t expected_luma[16] = {
        1u, 2u, 5u, 6u,
        3u, 4u, 7u, 8u,
        9u, 10u, 13u, 14u,
        11u, 12u, 15u, 16u};
    for (std::size_t i = 0u; i < 16u; ++i) {
        const std::uint32_t y = expected_luma[i];
        HMC_EXPECT(pixels[i] ==
                   (UINT32_C(0xff000000) | (y << 16u) | (y << 8u) | y));
    }
}

HMC_TEST(cinepak_two_strips_accumulate_top_row)
{
    const Entry dark{10u, 10u, 10u, 10u, 0u, 0u};
    const Entry light{200u, 200u, 200u, 200u, 0u, 0u};
    const std::vector<std::uint8_t> encoded = frame(
        0u,
        4u,
        8u,
        {strip(
             0x10u,
             4u,
             4u,
             {chunk(0x22u, codebook({dark})), chunk(0x32u, {0u})}),
         strip(
             0x10u,
             4u,
             4u,
             {chunk(0x22u, codebook({light})), chunk(0x32u, {0u})})});
    const std::vector<std::uint32_t> pixels = decode_fresh(4u, 8u, encoded);
    HMC_EXPECT(std::all_of(
        pixels.begin(), pixels.begin() + 16, [](std::uint32_t value) {
            return value == UINT32_C(0xff0a0a0a);
        }));
    HMC_EXPECT(std::all_of(
        pixels.begin() + 16, pixels.end(), [](std::uint32_t value) {
            return value == UINT32_C(0xffc8c8c8);
        }));
}

HMC_TEST(cinepak_interleaves_flag_words_with_indexes_across_32_bits)
{
    const Entry dark{10u, 10u, 10u, 10u, 0u, 0u};
    const Entry light{220u, 220u, 220u, 220u, 0u, 0u};
    std::vector<std::uint8_t> key_vectors;
    append_be32(key_vectors, 0u);
    key_vectors.resize(key_vectors.size() + 32u, 0u);
    append_be32(key_vectors, 0u);
    key_vectors.push_back(1u);
    const std::vector<std::uint8_t> key = frame(
        0u,
        132u,
        4u,
        {strip(
            0x10u,
            132u,
            4u,
            {chunk(0x22u, codebook({dark, light})),
             chunk(0x30u, key_vectors)})});
    std::vector<std::uint32_t> pixels = decode_fresh(132u, 4u, key);
    HMC_EXPECT(pixels[0u] == UINT32_C(0xff0a0a0a));
    HMC_EXPECT(pixels[128u] == UINT32_C(0xffdcdcdc));

    std::vector<std::uint8_t> inter_vectors;
    append_be32(inter_vectors, UINT32_C(0xaaaaaaaa));
    inter_vectors.resize(inter_vectors.size() + 16u, 1u);
    append_be32(inter_vectors, UINT32_C(0xaaaaaaaa));
    inter_vectors.resize(inter_vectors.size() + 16u, 1u);
    append_be32(inter_vectors, UINT32_C(0x80000000));
    inter_vectors.push_back(0u);
    const std::vector<std::uint8_t> inter = frame(
        1u,
        132u,
        4u,
        {strip(
            0x11u,
            132u,
            4u,
            {chunk(0x22u, codebook({dark, light})),
             chunk(0x31u, inter_vectors)})});
    const hmc_cinepak_decoder_config_t config = decoder_config(132u, 4u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    HMC_EXPECT(decode(decoder, key, &pixels));
    HMC_EXPECT(decode(decoder, inter, &pixels));
    HMC_EXPECT(pixels[0u] == UINT32_C(0xffdcdcdc));
    HMC_EXPECT(pixels[128u] == UINT32_C(0xff0a0a0a));

    std::vector<std::uint8_t> missing_second_word = key;
    const std::size_t vector_body =
        10u + 12u + 4u + 12u + 4u;
    missing_second_word.resize(vector_body + 4u + 32u);
    write_be24(missing_second_word, 1u, missing_second_word.size());
    write_be24(
        missing_second_word,
        11u,
        missing_second_word.size() - 10u);
    write_be24(
        missing_second_word,
        vector_body - 3u,
        missing_second_word.size() - (vector_body - 4u));
    std::vector<std::uint32_t> unchanged(pixels.size(), UINT32_C(0xabcdef01));
    const auto unchanged_before = unchanged;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   missing_second_word.data(),
                   missing_second_word.size(),
                   unchanged.data(),
                   unchanged.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(unchanged == unchanged_before);
    hmc_cinepak_decoder_destroy(decoder);
}

HMC_TEST(cinepak_avi_reader_frames_decode_in_sequence)
{
    const std::vector<std::uint8_t> avi = fixture_bytes("cvid_sample.avi");
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(avi.data(), avi.size(), &reader) ==
               HMC_STATUS_OK);
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.width == 8u && info.height == 8u && info.frame_count == 3u);
    const auto config = decoder_config(info.width, info.height);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(64u, 0u);
    const char *expected_names[] = {
        "cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb"};
    for (std::uint32_t i = 0u; i < 3u; ++i) {
        hmc_bytes_view_t view{};
        HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, i, &view) ==
                   HMC_STATUS_OK);
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       view.data,
                       view.size,
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OK);
        HMC_EXPECT(pixels == fixture_argb(expected_names[i]));
    }
    hmc_cinepak_decoder_destroy(decoder);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(cinepak_inter_requires_reference_and_reset_matches_fresh)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto skip = fixture_bytes("cinepak_all_skip.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_key = fixture_argb("cinepak_key.argb");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    const auto config = decoder_config(8u, 8u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(64u, UINT32_C(0x10203040));
    const auto before = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   inter.data(),
                   inter.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(pixels == before);
    HMC_EXPECT(decode(decoder, key, &pixels));
    HMC_EXPECT(pixels == expected_key);
    HMC_EXPECT(decode(decoder, skip, &pixels));
    HMC_EXPECT(pixels == expected_key);
    HMC_EXPECT(decode(decoder, inter, &pixels));
    HMC_EXPECT(pixels == expected_inter);
    HMC_EXPECT(hmc_cinepak_decoder_reset(decoder) == HMC_STATUS_OK);
    pixels.assign(64u, UINT32_C(0x10203040));
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   skip.data(),
                   skip.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(decode(decoder, key, &pixels));
    HMC_EXPECT(pixels == expected_key);
    hmc_cinepak_decoder_destroy(decoder);
    HMC_EXPECT(hmc_cinepak_decoder_reset(nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);
}

HMC_TEST(cinepak_rejects_every_fixture_prefix_atomically)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    const auto config = decoder_config(8u, 8u);
    for (const auto *fixture_name : {
             "cinepak_key.bin",
             "cinepak_all_skip.bin",
             "cinepak_inter.bin"}) {
        const auto fixture = fixture_bytes(fixture_name);
        for (std::size_t prefix = 0u; prefix < fixture.size(); ++prefix) {
            hmc_cinepak_decoder_t *decoder = nullptr;
            HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                       HMC_STATUS_OK);
            std::vector<std::uint32_t> pixels(64u, UINT32_C(0x10203040));
            HMC_EXPECT(decode(decoder, key, &pixels));
            const auto before = pixels;
            HMC_EXPECT(hmc_cinepak_decoder_decode(
                           decoder,
                           fixture.data(),
                           prefix,
                           pixels.data(),
                           pixels.size()) == HMC_STATUS_MALFORMED_DATA);
            HMC_EXPECT(pixels == before);
            HMC_EXPECT(decode(decoder, inter, &pixels));
            HMC_EXPECT(pixels == expected_inter);
            hmc_cinepak_decoder_destroy(decoder);
        }
    }
}

HMC_TEST(cinepak_rejects_structural_mutations_and_unsupported_chunks_atomically)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    const auto config = decoder_config(8u, 8u);
    struct Mutation {
        std::size_t offset;
        std::uint8_t value;
        hmc_status_t status;
    };
    const Mutation mutations[] = {
        {0u, 2u, HMC_STATUS_MALFORMED_DATA},
        {3u, 0xc9u, HMC_STATUS_MALFORMED_DATA},
        {5u, 4u, HMC_STATUS_MALFORMED_DATA},
        {7u, 4u, HMC_STATUS_MALFORMED_DATA},
        {9u, 0u, HMC_STATUS_MALFORMED_DATA},
        {10u, 0x11u, HMC_STATUS_MALFORMED_DATA},
        {13u, 11u, HMC_STATUS_MALFORMED_DATA},
        {15u, 1u, HMC_STATUS_MALFORMED_DATA},
        {17u, 1u, HMC_STATUS_MALFORMED_DATA},
        {19u, 2u, HMC_STATUS_MALFORMED_DATA},
        {21u, 4u, HMC_STATUS_MALFORMED_DATA},
        {22u, 0x21u, HMC_STATUS_UNSUPPORTED},
        {25u, 15u, HMC_STATUS_MALFORMED_DATA},
        {90u, 0x33u, HMC_STATUS_UNSUPPORTED}};
    for (const Mutation &mutation : mutations) {
        std::vector<std::uint8_t> bad = key;
        bad[mutation.offset] = mutation.value;
        hmc_cinepak_decoder_t *decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_OK);
        std::vector<std::uint32_t> pixels(64u, 0u);
        HMC_EXPECT(decode(decoder, key, &pixels));
        expect_failure_preserves_state(
            decoder, bad, mutation.status, inter, expected_inter);
        hmc_cinepak_decoder_destroy(decoder);
    }

    std::vector<std::uint8_t> unused_flag_bits = key;
    unused_flag_bits[97u] = 3u;
    hmc_cinepak_decoder_t *unused_decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &unused_decoder) ==
               HMC_STATUS_OK);
    std::vector<std::uint32_t> unused_pixels(64u, 0u);
    HMC_EXPECT(decode(unused_decoder, unused_flag_bits, &unused_pixels));
    HMC_EXPECT(unused_pixels == fixture_argb("cinepak_key.argb"));
    hmc_cinepak_decoder_destroy(unused_decoder);

    const Entry entry{10u, 10u, 10u, 10u, 0u, 0u};
    const auto cb = chunk(0x22u, codebook({entry}));
    const std::vector<std::vector<std::uint8_t>> invalid_strips[] = {
        {chunk(0x32u, {0u})},
        {cb},
        {cb, chunk(0x32u, {0u}), chunk(0x32u, {0u})},
        {cb, chunk(0x32u, {0u}), cb},
        {cb, cb, chunk(0x32u, {0u})},
        {cb, chunk(0x32u, {1u})},
        {cb, chunk(0x32u, {0u, 0u})}};
    for (const auto &chunks : invalid_strips) {
        const auto bad = frame(
            0u, 4u, 4u, {strip(0x10u, 4u, 4u, chunks)});
        const auto small_config = decoder_config(4u, 4u);
        hmc_cinepak_decoder_t *decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&small_config, &decoder) ==
                   HMC_STATUS_OK);
        std::vector<std::uint32_t> pixels(16u, UINT32_C(0x10203040));
        const auto before = pixels;
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       bad.data(),
                       bad.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == before);
        hmc_cinepak_decoder_destroy(decoder);
    }
}

HMC_TEST(cinepak_codebooks_never_leak_across_strips_or_frames)
{
    const Entry dark{10u, 10u, 10u, 10u, 0u, 0u};
    const Entry light{200u, 200u, 200u, 200u, 0u, 0u};
    const auto good_key = v1_frame(0u, 4u, 4u, dark);
    const auto bad_second_strip = frame(
        0u,
        4u,
        8u,
        {strip(
             0x10u,
             4u,
             4u,
             {chunk(0x22u, codebook({dark})), chunk(0x32u, {0u})}),
         strip(0x10u, 4u, 4u, {chunk(0x32u, {0u})})});
    const auto bad_inter = frame(
        1u,
        4u,
        4u,
        {strip(
            0x11u,
            4u,
            4u,
            {chunk(0x31u, {0x80u, 0u, 0u, 0u, 0u})})});
    const auto good_inter = frame(
        1u,
        4u,
        4u,
        {strip(
            0x11u,
            4u,
            4u,
            {chunk(0x22u, codebook({light})),
             chunk(0x31u, {0x80u, 0u, 0u, 0u, 0u})})});

    auto config = decoder_config(4u, 8u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(32u, UINT32_C(0x10203040));
    const auto before = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   bad_second_strip.data(),
                   bad_second_strip.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(pixels == before);
    hmc_cinepak_decoder_destroy(decoder);

    config = decoder_config(4u, 4u);
    decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    pixels.assign(16u, 0u);
    HMC_EXPECT(decode(decoder, good_key, &pixels));
    const auto key_pixels = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   bad_inter.data(),
                   bad_inter.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(pixels == key_pixels);
    HMC_EXPECT(decode(decoder, good_inter, &pixels));
    HMC_EXPECT(std::all_of(pixels.begin(), pixels.end(), [](std::uint32_t value) {
        return value == UINT32_C(0xffc8c8c8);
    }));
    hmc_cinepak_decoder_destroy(decoder);
}

HMC_TEST(cinepak_v4_requires_a_local_codebook_and_all_four_valid_indexes)
{
    const Entry entry{1u, 2u, 3u, 4u, 0u, 0u};
    std::vector<std::uint8_t> vectors;
    append_be32(vectors, UINT32_C(0x80000000));
    vectors.resize(vectors.size() + 4u, 0u);
    const auto without_codebook = frame(
        0u,
        4u,
        4u,
        {strip(0x10u, 4u, 4u, {chunk(0x30u, vectors)})});
    const auto config = decoder_config(4u, 4u);

    auto expect_bad = [&config](const std::vector<std::uint8_t> &bad) {
        hmc_cinepak_decoder_t *decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_OK);
        std::vector<std::uint32_t> pixels(16u, UINT32_C(0x10203040));
        const auto before = pixels;
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       bad.data(),
                       bad.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == before);
        hmc_cinepak_decoder_destroy(decoder);
    };
    expect_bad(without_codebook);

    const auto valid = frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x20u, codebook({entry})), chunk(0x30u, vectors)})});
    for (std::size_t index_offset = 0u; index_offset < 4u; ++index_offset) {
        std::vector<std::uint8_t> bad = valid;
        bad[40u + index_offset] = 1u;
        expect_bad(bad);
    }
    for (std::size_t prefix = 0u; prefix < 4u; ++prefix) {
        std::vector<std::uint8_t> truncated_vectors = vectors;
        truncated_vectors.resize(4u + prefix);
        expect_bad(frame(
            0u,
            4u,
            4u,
            {strip(
                0x10u,
                4u,
                4u,
                {chunk(0x20u, codebook({entry})),
                 chunk(0x30u, truncated_vectors)})}));
    }
}

HMC_TEST(cinepak_strict_sizes_geometry_codebook_counts_and_trailing_bytes)
{
    const Entry entry{10u, 10u, 10u, 10u, 0u, 0u};
    const auto valid = v1_frame(0u, 4u, 4u, entry);
    const auto config = decoder_config(4u, 4u);
    auto expect_bad = [&config](const std::vector<std::uint8_t> &bad) {
        hmc_cinepak_decoder_t *decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_OK);
        std::vector<std::uint32_t> pixels(16u, UINT32_C(0x10203040));
        const auto before = pixels;
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       bad.data(),
                       bad.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == before);
        hmc_cinepak_decoder_destroy(decoder);
    };

    std::vector<std::uint8_t> bad = valid;
    write_be16(bad, 8u, 2u);
    expect_bad(bad);
    bad = valid;
    write_be24(bad, 11u, bad.size());
    expect_bad(bad);
    bad = valid;
    write_be24(bad, 23u, bad.size());
    expect_bad(bad);
    bad = valid;
    write_be24(bad, 23u, 0u);
    expect_bad(bad);
    bad = valid;
    write_be24(bad, 23u, 3u);
    expect_bad(bad);

    expect_bad(frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x22u, {}), chunk(0x32u, {0u})})}));
    std::vector<Entry> too_many(257u, entry);
    expect_bad(frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x22u, codebook(too_many)), chunk(0x32u, {0u})})}));

    std::vector<std::uint8_t> mixed;
    append_be32(mixed, 0u);
    mixed.push_back(0u);
    mixed.push_back(0xa5u);
    expect_bad(frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x22u, codebook({entry})), chunk(0x30u, mixed)})}));

    const auto wrong_accumulation = frame(
        0u,
        4u,
        8u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x22u, codebook({entry})), chunk(0x32u, {0u})})});
    const auto tall_config = decoder_config(4u, 8u);
    hmc_cinepak_decoder_t *tall_decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&tall_config, &tall_decoder) ==
               HMC_STATUS_OK);
    std::vector<std::uint32_t> tall_pixels(32u, UINT32_C(0x10203040));
    const auto tall_before = tall_pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   tall_decoder,
                   wrong_accumulation.data(),
                   wrong_accumulation.size(),
                   tall_pixels.data(),
                   tall_pixels.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(tall_pixels == tall_before);
    hmc_cinepak_decoder_destroy(tall_decoder);
}

HMC_TEST(cinepak_failed_key_does_not_publish_reference_and_decoders_are_independent)
{
    const Entry dark{20u, 20u, 20u, 20u, 0u, 0u};
    const Entry light{220u, 220u, 220u, 220u, 0u, 0u};
    const auto key = v1_frame(0u, 4u, 4u, dark);
    const auto bad_key = frame(
        0u,
        4u,
        4u,
        {strip(
            0x10u,
            4u,
            4u,
            {chunk(0x22u, codebook({dark})), chunk(0x32u, {1u})})});
    const auto inter = frame(
        1u,
        4u,
        4u,
        {strip(
            0x11u,
            4u,
            4u,
            {chunk(0x22u, codebook({light})),
             chunk(0x31u, {0x80u, 0u, 0u, 0u, 0u})})});
    const auto config = decoder_config(4u, 4u);
    hmc_cinepak_decoder_t *first = nullptr;
    hmc_cinepak_decoder_t *second = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &first) == HMC_STATUS_OK);
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &second) == HMC_STATUS_OK);
    std::vector<std::uint32_t> first_pixels(16u, UINT32_C(0x10203040));
    const auto before = first_pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   first,
                   bad_key.data(),
                   bad_key.size(),
                   first_pixels.data(),
                   first_pixels.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(first_pixels == before);
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   first,
                   inter.data(),
                   inter.size(),
                   first_pixels.data(),
                   first_pixels.size()) == HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(decode(first, key, &first_pixels));
    std::vector<std::uint32_t> second_pixels(16u, 0u);
    HMC_EXPECT(decode(second, key, &second_pixels));
    HMC_EXPECT(first_pixels == second_pixels);
    HMC_EXPECT(decode(first, inter, &first_pixels));
    HMC_EXPECT(second_pixels != first_pixels);
    HMC_EXPECT(decode(second, inter, &second_pixels));
    HMC_EXPECT(first_pixels == second_pixels);
    hmc_cinepak_decoder_destroy(first);
    hmc_cinepak_decoder_destroy(second);
}

HMC_TEST(cinepak_reset_is_allocation_free_and_overlapping_buffers_are_rejected)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    const auto config = decoder_config(8u, 8u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(64u, 0u);
    HMC_EXPECT(decode(decoder, key, &pixels));

    honey::media::cinepak_decoder_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_cinepak_decoder_reset(decoder) == HMC_STATUS_OK);
    HMC_EXPECT(honey::media::cinepak_decoder_test_allocation_count() == 0u);
    honey::media::cinepak_decoder_test_clear_allocation_failure();
    HMC_EXPECT(decode(decoder, key, &pixels));

    std::vector<std::uint32_t> overlapping(64u, UINT32_C(0x10203040));
    std::memcpy(overlapping.data(), key.data(), key.size());
    const auto overlapping_before = overlapping;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   reinterpret_cast<const std::uint8_t *>(overlapping.data()),
                   key.size(),
                   overlapping.data(),
                   overlapping.size()) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(overlapping == overlapping_before);
    HMC_EXPECT(decode(decoder, inter, &pixels));
    HMC_EXPECT(pixels == expected_inter);
    hmc_cinepak_decoder_destroy(decoder);
}

HMC_TEST(cinepak_public_argument_failures_preserve_output_and_state)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    auto config = decoder_config(8u, 8u);
    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(65u, UINT32_C(0x10203040));
    HMC_EXPECT(decode(decoder, key, &pixels));
    const auto before = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   nullptr,
                   key.data(),
                   key.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   nullptr,
                   key.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   key.data(),
                   key.size(),
                   nullptr,
                   pixels.size()) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   key.data(),
                   key.size(),
                   pixels.data(),
                   63u) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(pixels == before);
    HMC_EXPECT(decode(decoder, inter, &pixels));
    HMC_EXPECT(std::equal(expected_inter.begin(), expected_inter.end(), pixels.begin()));
    HMC_EXPECT(pixels[64u] == UINT32_C(0x10203040));
    hmc_cinepak_decoder_destroy(decoder);

    config.struct_size = HMC_CINEPAK_DECODER_CONFIG_V1_SIZE - 1u;
    decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
               HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(decoder == nullptr);
}

HMC_TEST(cinepak_create_and_decode_allocation_failures_are_atomic_and_retryable)
{
    const auto key = fixture_bytes("cinepak_key.bin");
    const auto inter = fixture_bytes("cinepak_inter.bin");
    const auto expected_inter = fixture_argb("cinepak_inter.argb");
    const auto config = decoder_config(8u, 8u);

    honey::media::cinepak_decoder_test_clear_allocation_failure();
    hmc_cinepak_decoder_t *baseline = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &baseline) == HMC_STATUS_OK);
    const std::size_t create_allocations =
        honey::media::cinepak_decoder_test_allocation_count();
    hmc_cinepak_decoder_destroy(baseline);
    HMC_EXPECT(create_allocations != 0u);
    for (std::size_t nth = 1u; nth <= create_allocations; ++nth) {
        honey::media::cinepak_decoder_test_fail_nth_allocation(nth);
        hmc_cinepak_decoder_t *decoder = nullptr;
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(decoder == nullptr);
        honey::media::cinepak_decoder_test_clear_allocation_failure();
        HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) ==
                   HMC_STATUS_OK);
        hmc_cinepak_decoder_destroy(decoder);
    }

    hmc_cinepak_decoder_t *decoder = nullptr;
    HMC_EXPECT(hmc_cinepak_decoder_create(&config, &decoder) == HMC_STATUS_OK);
    std::vector<std::uint32_t> pixels(64u, UINT32_C(0x10203040));
    HMC_EXPECT(decode(decoder, key, &pixels));
    honey::media::cinepak_decoder_test_clear_allocation_failure();
    HMC_EXPECT(decode(decoder, inter, &pixels));
    const std::size_t decode_allocations =
        honey::media::cinepak_decoder_test_allocation_count();
    HMC_EXPECT(decode_allocations != 0u);
    HMC_EXPECT(hmc_cinepak_decoder_reset(decoder) == HMC_STATUS_OK);
    HMC_EXPECT(decode(decoder, key, &pixels));
    for (std::size_t nth = 1u; nth <= decode_allocations; ++nth) {
        honey::media::cinepak_decoder_test_fail_nth_allocation(nth);
        pixels.assign(64u, UINT32_C(0x10203040));
        const auto before = pixels;
        HMC_EXPECT(hmc_cinepak_decoder_decode(
                       decoder,
                       inter.data(),
                       inter.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(pixels == before);
        honey::media::cinepak_decoder_test_clear_allocation_failure();
        HMC_EXPECT(decode(decoder, inter, &pixels));
        HMC_EXPECT(pixels == expected_inter);
        HMC_EXPECT(hmc_cinepak_decoder_reset(decoder) == HMC_STATUS_OK);
        HMC_EXPECT(decode(decoder, key, &pixels));
    }
    honey::media::cinepak_decoder_test_clear_allocation_failure();
    hmc_cinepak_decoder_destroy(decoder);
}
