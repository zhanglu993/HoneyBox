#include "honey_media_core/media_core.h"

#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> fixture_bytes(const char *name)
{
    const std::string path = std::string(HMC_FIXTURE_DIRECTORY) + "/" + name;
    std::ifstream input(path, std::ios::binary);
    HMC_EXPECT(input.good());
    if (!input.good()) {
        return {};
    }
    return std::vector<std::uint8_t>(
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>());
}

std::vector<std::uint32_t> fixture_argb(const char *name)
{
    const std::vector<std::uint8_t> bytes = fixture_bytes(name);
    HMC_EXPECT((bytes.size() & 3u) == 0u);
    if (bytes.empty() || (bytes.size() & 3u) != 0u) {
        return {};
    }
    std::vector<std::uint32_t> pixels(bytes.size() / 4u);
    for (std::size_t index = 0u; index < pixels.size(); ++index) {
        const std::size_t offset = index * 4u;
        pixels[index] =
            static_cast<std::uint32_t>(bytes[offset]) |
            (static_cast<std::uint32_t>(bytes[offset + 1u]) << 8u) |
            (static_cast<std::uint32_t>(bytes[offset + 2u]) << 16u) |
            (static_cast<std::uint32_t>(bytes[offset + 3u]) << 24u);
    }
    return pixels;
}

bool contains_range(
    std::size_t size,
    std::size_t offset,
    std::size_t length)
{
    return offset <= size && length <= size - offset;
}

bool checked_add(
    std::size_t left,
    std::size_t right,
    std::size_t *result)
{
    if (result == nullptr ||
        right > std::numeric_limits<std::size_t>::max() - left) {
        return false;
    }
    *result = left + right;
    return true;
}

bool write_u32(
    std::vector<std::uint8_t> *bytes,
    std::size_t offset,
    std::uint32_t value)
{
    if (bytes == nullptr || !contains_range(bytes->size(), offset, 4u)) {
        return false;
    }
    (*bytes)[offset] = static_cast<std::uint8_t>(value);
    (*bytes)[offset + 1u] = static_cast<std::uint8_t>(value >> 8u);
    (*bytes)[offset + 2u] = static_cast<std::uint8_t>(value >> 16u);
    (*bytes)[offset + 3u] = static_cast<std::uint8_t>(value >> 24u);
    return true;
}

bool read_u32(
    const std::vector<std::uint8_t> &bytes,
    std::size_t offset,
    std::uint32_t *value)
{
    if (value == nullptr || !contains_range(bytes.size(), offset, 4u)) {
        return false;
    }
    *value = static_cast<std::uint32_t>(bytes[offset]) |
             (static_cast<std::uint32_t>(bytes[offset + 1u]) << 8u) |
             (static_cast<std::uint32_t>(bytes[offset + 2u]) << 16u) |
             (static_cast<std::uint32_t>(bytes[offset + 3u]) << 24u);
    return true;
}

bool write_be24(
    std::vector<std::uint8_t> *bytes,
    std::size_t offset,
    std::size_t value)
{
    if (bytes == nullptr || !contains_range(bytes->size(), offset, 3u)) {
        return false;
    }
    (*bytes)[offset] = static_cast<std::uint8_t>(value >> 16u);
    (*bytes)[offset + 1u] = static_cast<std::uint8_t>(value >> 8u);
    (*bytes)[offset + 2u] = static_cast<std::uint8_t>(value);
    return true;
}

hmc_msv1_decoder_config_t msv1_decoder_config()
{
    hmc_msv1_decoder_config_t config{};
    HMC_EXPECT(hmc_msv1_decoder_config_init(&config, sizeof(config)) ==
               HMC_STATUS_OK);
    config.width = 8u;
    config.height = 8u;
    return config;
}

hmc_cinepak_decoder_config_t cinepak_decoder_config()
{
    hmc_cinepak_decoder_config_t config{};
    HMC_EXPECT(hmc_cinepak_decoder_config_init(&config, sizeof(config)) ==
               HMC_STATUS_OK);
    config.width = 8u;
    config.height = 8u;
    return config;
}

void expect_msv1_prefixes_are_atomic(
    const char *frame_name,
    const char *expected_name)
{
    const std::vector<std::uint8_t> frame = fixture_bytes(frame_name);
    const std::vector<std::uint32_t> key = fixture_argb("msv1_key.argb");
    const std::vector<std::uint32_t> expected = fixture_argb(expected_name);
    const hmc_msv1_decoder_config_t config = msv1_decoder_config();
    const bool fixtures_valid =
        !frame.empty() && key.size() == 64u && expected.size() == 64u;
    HMC_EXPECT(fixtures_valid);
    if (!fixtures_valid) {
        return;
    }
    for (std::size_t prefix = 0u; prefix < frame.size(); ++prefix) {
        std::vector<std::uint32_t> pixels = key;
        HMC_EXPECT(hmc_msv1_decode(
                       &config,
                       frame.data(),
                       prefix,
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == key);
        HMC_EXPECT(hmc_msv1_decode(
                       &config,
                       frame.data(),
                       frame.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_OK);
        HMC_EXPECT(pixels == expected);
    }
}

void expect_cinepak_rejection_is_atomic(
    const std::uint8_t *malformed,
    std::size_t malformed_size)
{
    const hmc_cinepak_decoder_config_t config = cinepak_decoder_config();
    const std::vector<std::uint8_t> key = fixture_bytes("cinepak_key.bin");
    const std::vector<std::uint8_t> inter = fixture_bytes("cinepak_inter.bin");
    const std::vector<std::uint32_t> expected_key = fixture_argb("cinepak_key.argb");
    const std::vector<std::uint32_t> expected_inter = fixture_argb("cinepak_inter.argb");
    const bool fixtures_valid =
        !key.empty() && !inter.empty() &&
        expected_key.size() == 64u && expected_inter.size() == 64u &&
        (malformed != nullptr || malformed_size == 0u);
    HMC_EXPECT(fixtures_valid);
    if (!fixtures_valid) {
        return;
    }
    hmc_cinepak_decoder_t *decoder = nullptr;
    const hmc_status_t create_status =
        hmc_cinepak_decoder_create(&config, &decoder);
    HMC_EXPECT(create_status == HMC_STATUS_OK);
    HMC_EXPECT(decoder != nullptr);
    if (create_status != HMC_STATUS_OK || decoder == nullptr) {
        hmc_cinepak_decoder_destroy(decoder);
        return;
    }
    std::vector<std::uint32_t> pixels(64u, UINT32_C(0x10203040));
    const hmc_status_t key_status = hmc_cinepak_decoder_decode(
        decoder,
        key.data(),
        key.size(),
        pixels.data(),
        pixels.size());
    HMC_EXPECT(key_status == HMC_STATUS_OK);
    if (key_status != HMC_STATUS_OK) {
        hmc_cinepak_decoder_destroy(decoder);
        return;
    }
    HMC_EXPECT(pixels == expected_key);
    const std::vector<std::uint32_t> before = pixels;
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   malformed,
                   malformed_size,
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(pixels == before);
    HMC_EXPECT(hmc_cinepak_decoder_decode(
                   decoder,
                   inter.data(),
                   inter.size(),
                   pixels.data(),
                   pixels.size()) == HMC_STATUS_OK);
    HMC_EXPECT(pixels == expected_inter);
    hmc_cinepak_decoder_destroy(decoder);
}

void expect_cinepak_rejection_is_atomic(
    const std::vector<std::uint8_t> &malformed)
{
    expect_cinepak_rejection_is_atomic(malformed.data(), malformed.size());
}

void expect_cinepak_prefixes_are_atomic(const char *frame_name)
{
    const std::vector<std::uint8_t> frame = fixture_bytes(frame_name);
    HMC_EXPECT(!frame.empty());
    if (frame.empty()) {
        return;
    }
    for (std::size_t prefix = 0u; prefix < frame.size(); ++prefix) {
        expect_cinepak_rejection_is_atomic(frame.data(), prefix);
    }
}

void expect_avi_rejected(
    const std::uint8_t *bytes,
    std::size_t size,
    hmc_status_t expected = HMC_STATUS_MALFORMED_DATA)
{
    hmc_avi_reader_t *reader = nullptr;
    const hmc_status_t status = hmc_avi_reader_create_copy(bytes, size, &reader);
    HMC_EXPECT(status == expected);
    HMC_EXPECT(reader == nullptr);
    hmc_avi_reader_destroy(reader);
}

void expect_avi_rejected(
    const std::vector<std::uint8_t> &bytes,
    hmc_status_t expected = HMC_STATUS_MALFORMED_DATA)
{
    expect_avi_rejected(bytes.data(), bytes.size(), expected);
}

#if defined(_MSC_VER)
int conformance_lookup_result = 0;

void select_conformance_overload(int)
{
    conformance_lookup_result = 1;
}

#pragma warning(push)
#pragma warning(disable : 4244)
template <typename T>
void call_conformance_overload(T value)
{
    select_conformance_overload(value);
}
#pragma warning(pop)

void select_conformance_overload(double)
{
    conformance_lookup_result = 2;
}
#endif

} // namespace

HMC_TEST(windows_test_target_uses_strict_msvc_conformance)
{
#if defined(_MSC_VER)
    conformance_lookup_result = 0;
    call_conformance_overload(0.5);
    HMC_EXPECT(conformance_lookup_result == 1);
#else
    HMC_EXPECT(true);
#endif
}

HMC_TEST(malformed_corpus_rejects_all_six_frame_fixture_prefixes_atomically)
{
    expect_msv1_prefixes_are_atomic("msv1_key.bin", "msv1_key.argb");
    expect_msv1_prefixes_are_atomic("msv1_all_skip.bin", "msv1_all_skip.argb");
    expect_msv1_prefixes_are_atomic("msv1_inter.bin", "msv1_inter.argb");

    expect_cinepak_prefixes_are_atomic("cinepak_key.bin");
    expect_cinepak_prefixes_are_atomic("cinepak_all_skip.bin");
    expect_cinepak_prefixes_are_atomic("cinepak_inter.bin");
}

HMC_TEST(malformed_corpus_rejects_both_avi_fixture_prefixes_without_a_handle)
{
    for (const char *name : {"cvid_sample.avi", "msvc_sample.avi"}) {
        const std::vector<std::uint8_t> bytes = fixture_bytes(name);
        HMC_EXPECT(!bytes.empty());
        if (bytes.empty()) {
            continue;
        }
        for (std::size_t prefix = 0u; prefix < bytes.size(); ++prefix) {
            expect_avi_rejected(bytes.data(), prefix);
        }
    }
}

HMC_TEST(malformed_corpus_rejects_declared_sizes_fourccs_flags_and_terminators)
{
    for (const char *name : {
             "cinepak_key.bin", "cinepak_all_skip.bin", "cinepak_inter.bin"}) {
        const std::vector<std::uint8_t> original = fixture_bytes(name);
        const bool fixture_valid =
            contains_range(original.size(), 1u, 3u) &&
            original.size() < std::numeric_limits<std::size_t>::max();
        HMC_EXPECT(fixture_valid);
        if (!fixture_valid) {
            continue;
        }
        for (std::size_t declared : {
                 std::size_t{0u}, original.size() - 1u,
                 original.size() + 1u, std::size_t{0x00ffffffu}}) {
            std::vector<std::uint8_t> malformed = original;
            const bool wrote_size = write_be24(&malformed, 1u, declared);
            HMC_EXPECT(wrote_size);
            if (!wrote_size) {
                continue;
            }
            expect_cinepak_rejection_is_atomic(malformed);
        }
    }

    const hmc_msv1_decoder_config_t msv1_config = msv1_decoder_config();
    const std::vector<std::uint32_t> key_pixels = fixture_argb("msv1_key.argb");
    const std::vector<std::uint8_t> msv1_key = fixture_bytes("msv1_key.bin");
    std::array<std::vector<std::uint8_t>, 4u> malformed_msv1 = {
        msv1_key,
        msv1_key,
        std::vector<std::uint8_t>{0x00u, 0x84u, 0x00u, 0x00u},
        std::vector<std::uint8_t>{0x05u, 0x84u, 0x00u, 0x00u}};
    const bool msv1_fixtures_valid =
        !msv1_key.empty() && key_pixels.size() == 64u;
    HMC_EXPECT(msv1_fixtures_valid);
    if (!msv1_fixtures_valid) {
        return;
    }
    malformed_msv1[0].pop_back();
    malformed_msv1[1].push_back(0u);
    malformed_msv1[1].push_back(0u);
    for (const std::vector<std::uint8_t> &malformed : malformed_msv1) {
        std::vector<std::uint32_t> pixels = key_pixels;
        HMC_EXPECT(hmc_msv1_decode(
                       &msv1_config,
                       malformed.data(),
                       malformed.size(),
                       pixels.data(),
                       pixels.size()) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(pixels == key_pixels);
    }

    for (const char *name : {"cvid_sample.avi", "msvc_sample.avi"}) {
        const std::vector<std::uint8_t> original = fixture_bytes(name);
        std::uint32_t movi_size = 0u;
        std::size_t movi_end = 0u;
        std::size_t first_index = 0u;
        const bool offsets_valid =
            read_u32(original, 216u, &movi_size) &&
            checked_add(220u, static_cast<std::size_t>(movi_size), &movi_end) &&
            checked_add(movi_end, 8u, &first_index) &&
            contains_range(original.size(), 0u, 1u) &&
            contains_range(original.size(), 112u, 4u) &&
            contains_range(original.size(), first_index, 16u);
        HMC_EXPECT(offsets_valid);
        if (!offsets_valid) {
            continue;
        }

        std::size_t movi_size_offset = 0u;
        std::size_t index_flags_offset = 0u;
        std::size_t index_chunk_offset = 0u;
        std::size_t index_size_offset = 0u;
        const bool derived_offsets_valid =
            checked_add(movi_end, 4u, &movi_size_offset) &&
            checked_add(first_index, 4u, &index_flags_offset) &&
            checked_add(first_index, 8u, &index_chunk_offset) &&
            checked_add(first_index, 12u, &index_size_offset) &&
            contains_range(original.size(), movi_size_offset, 4u) &&
            contains_range(original.size(), index_flags_offset, 4u) &&
            contains_range(original.size(), index_chunk_offset, 4u) &&
            contains_range(original.size(), index_size_offset, 4u);
        HMC_EXPECT(derived_offsets_valid);
        if (!derived_offsets_valid) {
            continue;
        }
        for (const std::pair<std::size_t, std::uint32_t> mutation : {
                 std::pair<std::size_t, std::uint32_t>{4u, UINT32_MAX},
                 {16u, UINT32_MAX},
                 {216u, UINT32_MAX},
                 {228u, UINT32_MAX},
                 {movi_size_offset, UINT32_MAX},
                 {index_chunk_offset, UINT32_MAX},
                 {index_size_offset, UINT32_MAX}}) {
            std::vector<std::uint8_t> malformed = original;
            const bool wrote_value =
                write_u32(&malformed, mutation.first, mutation.second);
            HMC_EXPECT(wrote_value);
            if (!wrote_value) {
                continue;
            }
            expect_avi_rejected(malformed);
        }

        std::vector<std::uint8_t> bad_signature = original;
        bad_signature[0] = static_cast<std::uint8_t>('X');
        expect_avi_rejected(bad_signature);

        std::vector<std::uint8_t> bad_handler = original;
        const bool wrote_handler = write_u32(
            &bad_handler, 112u, HMC_MEDIA_FOURCC('x', 'x', 'x', 'x'));
        HMC_EXPECT(wrote_handler);
        if (!wrote_handler) {
            continue;
        }
        expect_avi_rejected(
            bad_handler,
            name[0] == 'c' ? HMC_STATUS_UNSUPPORTED : HMC_STATUS_MALFORMED_DATA);

        std::vector<std::uint8_t> bad_flags = original;
        const bool wrote_flags = write_u32(&bad_flags, index_flags_offset, 1u);
        HMC_EXPECT(wrote_flags);
        if (!wrote_flags) {
            continue;
        }
        expect_avi_rejected(bad_flags, HMC_STATUS_UNSUPPORTED);
    }
}

HMC_TEST(malformed_corpus_rejects_representative_option_boundaries_atomically)
{
    hmc_cinepak_encoder_config_t cinepak{};
    HMC_EXPECT(hmc_cinepak_encoder_config_init(&cinepak, sizeof(cinepak)) ==
               HMC_STATUS_OK);
    cinepak.width = 8u;
    cinepak.height = 8u;
    const hmc_cinepak_encoder_config_t valid_cinepak = cinepak;
    std::array<hmc_cinepak_encoder_config_t, 6u> invalid_cinepak{};
    invalid_cinepak.fill(valid_cinepak);
    invalid_cinepak[0].width = 6u;
    invalid_cinepak[1].quality = 101;
    invalid_cinepak[2].v1_size = 0;
    invalid_cinepak[3].refine_iterations = -1;
    invalid_cinepak[4].strips = 0;
    invalid_cinepak[5].key_interval = -1;
    for (const hmc_cinepak_encoder_config_t &config : invalid_cinepak) {
        hmc_cinepak_encoder_t *encoder = nullptr;
        const hmc_status_t status =
            hmc_cinepak_encoder_create(&config, &encoder);
        HMC_EXPECT(status == HMC_STATUS_INVALID_ARGUMENT);
        HMC_EXPECT(encoder == nullptr);
        hmc_cinepak_encoder_destroy(encoder);
    }

    hmc_avi_muxer_config_t avi{};
    HMC_EXPECT(hmc_avi_muxer_config_init(&avi, sizeof(avi)) == HMC_STATUS_OK);
    avi.width = 8u;
    avi.height = 8u;
    avi.frame_rate_num = 10u;
    avi.frame_rate_den = 1u;
    avi.handler_fourcc = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
    avi.compression_fourcc = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
    avi.bit_count = 24u;
    const hmc_avi_muxer_config_t valid_avi = avi;
    std::array<hmc_avi_muxer_config_t, 4u> invalid_avi{};
    invalid_avi.fill(valid_avi);
    invalid_avi[0].frame_rate_num = 0u;
    invalid_avi[1].frame_rate_den = 0u;
    invalid_avi[2].compression_fourcc = HMC_MEDIA_FOURCC('M', 'S', 'V', 'C');
    invalid_avi[3].bit_count = 16u;
    for (std::size_t index = 0u; index < invalid_avi.size(); ++index) {
        hmc_avi_muxer_t *muxer = nullptr;
        const hmc_status_t expected = index < 2u
            ? HMC_STATUS_INVALID_ARGUMENT
            : HMC_STATUS_UNSUPPORTED;
        const hmc_status_t status =
            hmc_avi_muxer_create(&invalid_avi[index], &muxer);
        HMC_EXPECT(status == expected);
        HMC_EXPECT(muxer == nullptr);
        hmc_avi_muxer_destroy(muxer);
    }

    hmc_msv1_encoder_config_t msv1{};
    HMC_EXPECT(hmc_msv1_encoder_config_init(&msv1, sizeof(msv1)) == HMC_STATUS_OK);
    msv1.width = 8u;
    msv1.height = 8u;
    const std::vector<std::uint8_t> rgba = fixture_bytes("input_8x8_a.rgba");
    HMC_EXPECT(!rgba.empty());
    if (rgba.empty()) {
        return;
    }
    hmc_owned_buffer_t output{};
    hmc_frame_flags_t frame_flags = UINT32_C(0x55667788);
    HMC_EXPECT(hmc_msv1_encode(
                   &msv1,
                   rgba.data(),
                   rgba.size() - 1u,
                   nullptr,
                   0u,
                   HMC_ENCODE_FLAG_NONE,
                   &output,
                   &frame_flags) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    hmc_owned_buffer_release(&output);
    output = {};
    HMC_EXPECT(hmc_msv1_encode(
                   &msv1,
                   rgba.data(),
                   rgba.size(),
                   nullptr,
                   0u,
                   UINT32_C(0x80000000),
                   &output,
                   &frame_flags) == HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(output.data == nullptr && output.size == 0u);
    HMC_EXPECT(frame_flags == UINT32_C(0x55667788));
    hmc_owned_buffer_release(&output);
}
