#include "honey_media_core/media_core.h"

#include "avi.hpp"
#include "test_support.hpp"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr std::uint32_t kCvid = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
constexpr std::uint32_t kMsvc = HMC_MEDIA_FOURCC('M', 'S', 'V', 'C');
constexpr std::uint32_t kMjpg = HMC_MEDIA_FOURCC('M', 'J', 'P', 'G');
constexpr std::uint32_t k00dc = HMC_MEDIA_FOURCC('0', '0', 'd', 'c');
constexpr std::uint32_t kAvih = HMC_MEDIA_FOURCC('a', 'v', 'i', 'h');
constexpr std::uint32_t kStrh = HMC_MEDIA_FOURCC('s', 't', 'r', 'h');
constexpr std::uint32_t kStrf = HMC_MEDIA_FOURCC('s', 't', 'r', 'f');
constexpr std::uint32_t kIdx1 = HMC_MEDIA_FOURCC('i', 'd', 'x', '1');

std::vector<std::uint8_t> load_fixture(const char *name)
{
    const std::string path = std::string(HMC_FIXTURE_DIRECTORY) + "/" + name;
    std::FILE *file = std::fopen(path.c_str(), "rb");
    HMC_EXPECT(file != nullptr);
    if (file == nullptr) {
        return {};
    }
    (void)std::fseek(file, 0, SEEK_END);
    const long length = std::ftell(file);
    (void)std::fseek(file, 0, SEEK_SET);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    if (!bytes.empty()) {
        HMC_EXPECT(std::fread(bytes.data(), 1u, bytes.size(), file) == bytes.size());
    }
    (void)std::fclose(file);
    return bytes;
}

std::uint32_t read_u32(const std::uint8_t *data)
{
    return static_cast<std::uint32_t>(data[0]) |
           (static_cast<std::uint32_t>(data[1]) << 8u) |
           (static_cast<std::uint32_t>(data[2]) << 16u) |
           (static_cast<std::uint32_t>(data[3]) << 24u);
}

std::uint16_t read_u16(const std::uint8_t *data)
{
    return static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(data[0]) |
        static_cast<std::uint16_t>(static_cast<std::uint16_t>(data[1]) << 8u));
}

void write_u32(std::vector<std::uint8_t> &bytes, std::size_t offset, std::uint32_t value)
{
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1u] = static_cast<std::uint8_t>(value >> 8u);
    bytes[offset + 2u] = static_cast<std::uint8_t>(value >> 16u);
    bytes[offset + 3u] = static_cast<std::uint8_t>(value >> 24u);
}

hmc_avi_muxer_config_t make_config(
    std::uint32_t fourcc,
    std::uint32_t bit_count,
    std::uint32_t width = 8u,
    std::uint32_t height = 8u)
{
    hmc_avi_muxer_config_t config{};
    HMC_EXPECT(hmc_avi_muxer_config_init(&config, sizeof(config)) == HMC_STATUS_OK);
    config.width = width;
    config.height = height;
    config.frame_rate_num = 10u;
    config.frame_rate_den = 1u;
    config.handler_fourcc = fourcc;
    config.compression_fourcc = fourcc;
    config.bit_count = bit_count;
    return config;
}

std::vector<std::uint8_t> mux(
    const hmc_avi_muxer_config_t &config,
    const std::vector<std::vector<std::uint8_t>> &frames,
    const std::vector<hmc_frame_flags_t> &flags)
{
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    if (muxer == nullptr) {
        return {};
    }
    for (std::size_t i = 0u; i < frames.size(); ++i) {
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            muxer, frames[i].data(), frames[i].size(), flags[i]) == HMC_STATUS_OK);
    }
    hmc_owned_buffer_t output{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &output) == HMC_STATUS_OK);
    std::vector<std::uint8_t> result(output.data, output.data + output.size);
    hmc_owned_buffer_release(&output);
    hmc_avi_muxer_destroy(muxer);
    return result;
}

void expect_reader_rejects(const std::vector<std::uint8_t> &bytes)
{
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) ==
               HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(reader == nullptr);
}

} // namespace

HMC_TEST(avi_config_init_obeys_extensible_struct_contract)
{
    std::uint8_t bytes[40];
    std::memset(bytes, 0xa5, sizeof(bytes));
    HMC_EXPECT(hmc_avi_muxer_config_init(
        reinterpret_cast<hmc_avi_muxer_config_t *>(bytes), sizeof(bytes)) == HMC_STATUS_OK);
    HMC_EXPECT(read_u32(bytes) == sizeof(bytes));
    for (std::size_t i = 4u; i < sizeof(bytes); ++i) {
        HMC_EXPECT(bytes[i] == 0u);
    }

    std::uint8_t small[31];
    std::memset(small, 0x5a, sizeof(small));
    HMC_EXPECT(hmc_avi_muxer_config_init(
        reinterpret_cast<hmc_avi_muxer_config_t *>(small), sizeof(small)) ==
               HMC_STATUS_BUFFER_TOO_SMALL);
    for (std::uint8_t byte : small) {
        HMC_EXPECT(byte == 0x5au);
    }
    HMC_EXPECT(hmc_avi_muxer_config_init(nullptr, 32u) == HMC_STATUS_INVALID_ARGUMENT);
}

HMC_TEST(avi_muxer_matches_kotlin_cvid_and_msvc_goldens)
{
    const std::vector<std::uint8_t> cvid_key = load_fixture("cinepak_key.bin");
    const std::vector<std::uint8_t> cvid_skip = load_fixture("cinepak_all_skip.bin");
    const std::vector<std::uint8_t> cvid_inter = load_fixture("cinepak_inter.bin");
    const std::vector<std::uint8_t> cvid = mux(
        make_config(kCvid, 24u),
        {cvid_key, cvid_skip, cvid_inter},
        {HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY_KNOWN});
    HMC_EXPECT(cvid == load_fixture("cvid_sample.avi"));

    const std::vector<std::uint8_t> msv1_key = load_fixture("msv1_key.bin");
    const std::vector<std::uint8_t> msv1_skip = load_fixture("msv1_all_skip.bin");
    const std::vector<std::uint8_t> msv1_inter = load_fixture("msv1_inter.bin");
    const std::vector<std::uint8_t> msvc = mux(
        make_config(kMsvc, 16u),
        {msv1_key, msv1_skip, msv1_inter},
        {HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY_KNOWN});
    HMC_EXPECT(msvc == load_fixture("msvc_sample.avi"));
}

HMC_TEST(avi_muxer_writes_padding_offsets_and_empty_profile_defaults)
{
    const std::vector<std::uint8_t> bytes = mux(
        make_config(kCvid, 24u),
        {{0x11u}, {0x22u, 0x33u}, {0x44u, 0x55u, 0x66u}},
        {HMC_FRAME_FLAG_KEY_KNOWN, HMC_FRAME_FLAG_KEY_KNOWN, HMC_FRAME_FLAG_KEY_KNOWN});
    const std::size_t idx = bytes.size() - 8u - 48u;
    HMC_EXPECT(read_u32(bytes.data() + 216u) == 36u);
    HMC_EXPECT(read_u32(bytes.data() + idx + 16u) == 4u);
    HMC_EXPECT(read_u32(bytes.data() + idx + 32u) == 14u);
    HMC_EXPECT(read_u32(bytes.data() + idx + 48u) == 24u);

    const std::vector<std::uint8_t> empty_cvid = mux(make_config(kCvid, 24u), {}, {});
    HMC_EXPECT(empty_cvid.size() == 232u);
    HMC_EXPECT(read_u32(empty_cvid.data() + 60u) == 0u);
    HMC_EXPECT(read_u32(empty_cvid.data() + 140u) == 0u);
    HMC_EXPECT(read_u32(empty_cvid.data() + 144u) == 0u);

    const std::vector<std::uint8_t> empty_msvc = mux(make_config(kMsvc, 16u), {}, {});
    HMC_EXPECT(read_u32(empty_msvc.data() + 60u) == 1u);
    HMC_EXPECT(read_u32(empty_msvc.data() + 140u) == 0u);
    HMC_EXPECT(read_u32(empty_msvc.data() + 144u) == 1u);
}

HMC_TEST(avi_muxer_validates_profiles_dimensions_rates_flags_and_state)
{
    hmc_avi_muxer_t *muxer = nullptr;
    hmc_avi_muxer_config_t config = make_config(kCvid, 24u);

    config.frame_rate_num = 0u;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(muxer == nullptr);
    config = make_config(kCvid, 24u);
    config.frame_rate_den = 0u;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_INVALID_ARGUMENT);

    config = make_config(kCvid, 24u, 0u, 8u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_INVALID_ARGUMENT);
    config = make_config(kCvid, 24u, 65536u, 8u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_INVALID_ARGUMENT);
    config = make_config(kCvid, 24u, 65535u, 65535u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OVERFLOW);

    config = make_config(kMsvc, 24u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_UNSUPPORTED);
    config = make_config(kMjpg, 24u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    HMC_EXPECT(muxer != nullptr);

    const std::uint8_t payload = 0x11u;
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, &payload, 0u, HMC_FRAME_FLAG_KEY_KNOWN) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, &payload, 1u, HMC_FRAME_FLAG_NONE) ==
               HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, &payload, 1u, HMC_FRAME_FLAG_KEY) ==
               HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, &payload, 1u, UINT32_C(0x80000002)) ==
               HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, &payload, 1u, HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN) ==
               HMC_STATUS_OK);

    hmc_owned_buffer_t output{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &output) == HMC_STATUS_OK);
    hmc_owned_buffer_t second{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &second) == HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(second.data == nullptr && second.size == 0u);
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, &payload, 1u, HMC_FRAME_FLAG_KEY_KNOWN) ==
               HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(hmc_avi_muxer_add_frame(muxer, nullptr, 0u, HMC_FRAME_FLAG_NONE) ==
               HMC_STATUS_INVALID_STATE);
    hmc_owned_buffer_t occupied_after_seal{reinterpret_cast<std::uint8_t *>(1), 1u};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &occupied_after_seal) ==
               HMC_STATUS_INVALID_STATE);
    HMC_EXPECT(occupied_after_seal.data == reinterpret_cast<std::uint8_t *>(1) &&
               occupied_after_seal.size == 1u);
    hmc_owned_buffer_release(&output);
    hmc_avi_muxer_destroy(muxer);
    hmc_avi_muxer_destroy(nullptr);
}

HMC_TEST(avi_reader_round_trips_metadata_flags_views_and_copies)
{
    const std::vector<std::uint8_t> bytes = load_fixture("msvc_sample.avi");
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) == HMC_STATUS_OK);
    HMC_EXPECT(reader != nullptr);

    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.width == 8u && info.height == 8u && info.usec_per_frame == 100000u);
    HMC_EXPECT(info.frame_rate_num == 10u && info.frame_rate_den == 1u);
    HMC_EXPECT(info.handler_fourcc == kMsvc && info.compression_fourcc == kMsvc);
    HMC_EXPECT(info.bit_count == 16u && info.frame_count == 3u);

    for (std::uint32_t i = 0u; i < 3u; ++i) {
        hmc_avi_frame_info_t frame_info{};
        frame_info.struct_size = sizeof(frame_info);
        HMC_EXPECT(hmc_avi_reader_get_frame_info(reader, i, &frame_info) == HMC_STATUS_OK);
        HMC_EXPECT(frame_info.chunk_fourcc == k00dc);
        HMC_EXPECT(frame_info.avi_index_flags == (i == 0u ? 0x10u : 0u));
        HMC_EXPECT(frame_info.frame_flags ==
                   (i == 0u ? HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN
                            : HMC_FRAME_FLAG_KEY_KNOWN));

        hmc_bytes_view_t view{};
        HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, i, &view) == HMC_STATUS_OK);
        hmc_owned_buffer_t copy{};
        HMC_EXPECT(hmc_avi_reader_copy_frame(reader, i, &copy) == HMC_STATUS_OK);
        HMC_EXPECT(view.size == copy.size);
        HMC_EXPECT(std::memcmp(view.data, copy.data, view.size) == 0);
        HMC_EXPECT(view.data != copy.data);
        hmc_owned_buffer_release(&copy);
    }

    hmc_bytes_view_t bad_view{};
    HMC_EXPECT(hmc_avi_reader_get_frame_view(
        reader, std::numeric_limits<std::uint32_t>::max(), &bad_view) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(bad_view.data == nullptr && bad_view.size == 0u);

    std::atomic<int> concurrent_failures{0};
    auto query = [&reader, &concurrent_failures]() {
        for (int i = 0; i < 100; ++i) {
            hmc_avi_info_t concurrent_info{};
            concurrent_info.struct_size = sizeof(concurrent_info);
            if (hmc_avi_reader_get_info(reader, &concurrent_info) != HMC_STATUS_OK ||
                concurrent_info.frame_count != 3u) {
                ++concurrent_failures;
            }
        }
    };
    std::thread first(query);
    std::thread second(query);
    first.join();
    second.join();
    HMC_EXPECT(concurrent_failures == 0);

    hmc_avi_reader_destroy(reader);
    hmc_avi_reader_destroy(nullptr);
}

HMC_TEST(avi_reader_rejects_structural_and_index_corruption)
{
    const std::vector<std::uint8_t> original = load_fixture("cvid_sample.avi");
    const std::size_t idx = original.size() - 8u - 48u;
    const std::size_t first_entry = idx + 8u;

    const std::size_t cuts[] = {8u, 12u, 211u, original.size() - 1u};
    for (std::size_t cut : cuts) {
        std::vector<std::uint8_t> truncated(original.begin(), original.begin() + cut);
        expect_reader_rejects(truncated);
    }
    const std::size_t structural_offsets[] = {
        0u, 8u, 12u, 20u, 24u, 88u, 96u, 100u, 164u, 212u, 220u, idx};
    for (std::size_t offset : structural_offsets) {
        std::vector<std::uint8_t> corrupted = original;
        corrupted[offset] ^= 0x20u;
        expect_reader_rejects(corrupted);
    }

    std::vector<std::uint8_t> bad_length = original;
    write_u32(bad_length, 4u, UINT32_MAX);
    expect_reader_rejects(bad_length);

    std::vector<std::uint8_t> bad_idx_size = original;
    write_u32(bad_idx_size, idx + 4u, 47u);
    expect_reader_rejects(bad_idx_size);

    for (std::size_t field : {0u, 8u, 12u}) {
        std::vector<std::uint8_t> bad_entry = original;
        write_u32(bad_entry, first_entry + field, UINT32_C(0x7fffffff));
        expect_reader_rejects(bad_entry);
    }

    std::vector<std::uint8_t> unsupported_flags = original;
    write_u32(unsupported_flags, first_entry + 4u, 1u);
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(
        unsupported_flags.data(), unsupported_flags.size(), &reader) == HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(reader == nullptr);
}

HMC_TEST(avi_reader_bounds_output_and_tail_validation_are_failure_atomic)
{
    const std::vector<std::uint8_t> bytes = load_fixture("cvid_sample.avi");
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) == HMC_STATUS_OK);

    std::uint8_t info_bytes[48]{};
    auto *info = reinterpret_cast<hmc_avi_info_t *>(info_bytes);
    info->struct_size = sizeof(info_bytes);
    info_bytes[47] = 1u;
    std::uint8_t before[48];
    std::memcpy(before, info_bytes, sizeof(before));
    HMC_EXPECT(hmc_avi_reader_get_info(reader, info) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(std::memcmp(before, info_bytes, sizeof(before)) == 0);

    hmc_owned_buffer_t occupied{reinterpret_cast<std::uint8_t *>(1), 1u};
    HMC_EXPECT(hmc_avi_reader_copy_frame(reader, 0u, &occupied) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(occupied.data == reinterpret_cast<std::uint8_t *>(1) && occupied.size == 1u);

    hmc_bytes_view_t occupied_view{reinterpret_cast<const std::uint8_t *>(1), 1u};
    HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, 0u, &occupied_view) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(occupied_view.data == reinterpret_cast<const std::uint8_t *>(1) &&
               occupied_view.size == 1u);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(avi_legacy_strl_exception_requires_every_discriminator)
{
    const std::vector<std::uint8_t> original = load_fixture("msvc_sample.avi");
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(original.data(), original.size(), &reader) ==
               HMC_STATUS_OK);
    hmc_avi_reader_destroy(reader);

    struct Mutation {
        std::size_t offset;
        std::uint32_t value;
    };
    const Mutation mutations[] = {
        {16u, 191u},             // hdrl.size
        {24u, kStrh},            // avih first child
        {88u, kAvih},            // LIST strl
        {92u, 123u},             // exact legacy overstatement
        {100u, kStrf},           // exact strh child
        {104u, 55u},             // strh body
        {164u, kStrh},           // exact strf child
        {168u, 39u},             // strf body
        {212u, kIdx1},           // LIST at physical hdrl end
        {220u, kIdx1},           // movi type
        {112u, kCvid},           // supported but wrong profile
        {148u, 0u},              // quality
        {184u, 2u},              // planes + bit count low half
        {188u, kCvid},           // compression
        {192u, 127u},            // image size
        {64u, 9u},               // avih width mismatch
        {132u, 11u},             // rational timing mismatch
    };
    for (const Mutation &mutation : mutations) {
        std::vector<std::uint8_t> changed = original;
        write_u32(changed, mutation.offset, mutation.value);
        hmc_avi_reader_t *candidate = nullptr;
        HMC_EXPECT(hmc_avi_reader_create_copy(
            changed.data(), changed.size(), &candidate) == HMC_STATUS_MALFORMED_DATA);
        HMC_EXPECT(candidate == nullptr);
    }

    std::vector<std::uint8_t> fake_cvid = load_fixture("cvid_sample.avi");
    write_u32(fake_cvid, 92u, 124u);
    expect_reader_rejects(fake_cvid);
}

HMC_TEST(avi_mjpg_uses_the_audited_synthetic_layout)
{
    const std::vector<std::uint8_t> bytes = mux(
        make_config(kMjpg, 24u),
        {{0xffu, 0xd8u, 0xffu, 0xd9u}},
        {HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN});
    HMC_EXPECT(read_u32(bytes.data() + 92u) == 124u);
    HMC_EXPECT(read_u32(bytes.data() + 112u) == kMjpg);
    HMC_EXPECT(read_u32(bytes.data() + 144u) == 4u);
    HMC_EXPECT(read_u32(bytes.data() + 148u) == UINT32_MAX);
    HMC_EXPECT(read_u32(bytes.data() + 188u) == kMjpg);
    HMC_EXPECT(read_u16(bytes.data() + 186u) == 24u);
    HMC_EXPECT(read_u32(bytes.data() + 192u) == 128u);

    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) == HMC_STATUS_OK);
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.handler_fourcc == kMjpg && info.compression_fourcc == kMjpg);
    HMC_EXPECT(info.bit_count == 24u && info.frame_count == 1u);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(avi_allocation_failures_are_atomic_and_retryable)
{
    hmc_avi_muxer_config_t config = make_config(kCvid, 24u);
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    const std::uint8_t first[] = {1u, 2u, 3u};

    for (std::size_t nth = 1u; nth <= 2u; ++nth) {
        honey::media::avi_test_fail_nth_allocation(nth);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            muxer, first, sizeof(first), HMC_FRAME_FLAG_KEY_KNOWN) ==
                   HMC_STATUS_OUT_OF_MEMORY);
        honey::media::avi_test_clear_allocation_failure();
    }
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, first, sizeof(first), HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);

    hmc_owned_buffer_t failed_finish{};
    honey::media::avi_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &failed_finish) == HMC_STATUS_OUT_OF_MEMORY);
    HMC_EXPECT(failed_finish.data == nullptr && failed_finish.size == 0u);
    honey::media::avi_test_clear_allocation_failure();
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &failed_finish) == HMC_STATUS_OK);
    const std::vector<std::uint8_t> valid(
        failed_finish.data, failed_finish.data + failed_finish.size);
    hmc_owned_buffer_release(&failed_finish);
    hmc_avi_muxer_destroy(muxer);

    for (std::size_t nth = 1u; nth <= 3u; ++nth) {
        hmc_avi_reader_t *failed_reader = nullptr;
        honey::media::avi_test_fail_nth_allocation(nth);
        HMC_EXPECT(hmc_avi_reader_create_copy(
            valid.data(), valid.size(), &failed_reader) == HMC_STATUS_OUT_OF_MEMORY);
        HMC_EXPECT(failed_reader == nullptr);
        honey::media::avi_test_clear_allocation_failure();
    }
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(valid.data(), valid.size(), &reader) == HMC_STATUS_OK);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(avi_rejects_serialized_sizes_before_reading_the_caller_span)
{
    hmc_avi_muxer_t *muxer = nullptr;
    hmc_avi_muxer_config_t config = make_config(kMsvc, 16u, 65535u, 1u);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    const std::uint8_t byte = 1u;
    if constexpr (sizeof(std::size_t) > sizeof(std::uint32_t)) {
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            muxer,
            &byte,
            static_cast<std::size_t>(UINT32_MAX) + 1u,
            HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OVERFLOW);
        hmc_avi_reader_t *reader = nullptr;
        HMC_EXPECT(hmc_avi_reader_create_copy(
            &byte,
            static_cast<std::size_t>(UINT32_MAX) + 9u,
            &reader) == HMC_STATUS_OVERFLOW);
        HMC_EXPECT(reader == nullptr);
    }
    honey::media::avi_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer,
        &byte,
        static_cast<std::size_t>(UINT32_MAX),
        HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OVERFLOW);
    HMC_EXPECT(honey::media::avi_test_allocation_count() == 0u);
    honey::media::avi_test_clear_allocation_failure();
    hmc_avi_muxer_destroy(muxer);
}

HMC_TEST(avi_idx1_entries_match_every_movi_chunk_and_padding_byte)
{
    const std::vector<std::uint8_t> original = mux(
        make_config(kCvid, 24u),
        {{0x11u}, {0x22u, 0x33u}, {0x44u, 0x55u, 0x66u}},
        {HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN,
         HMC_FRAME_FLAG_KEY_KNOWN});
    const std::size_t idx = original.size() - 56u;

    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(original.data(), original.size(), &reader) ==
               HMC_STATUS_OK);
    hmc_avi_frame_info_t second{};
    second.struct_size = sizeof(second);
    HMC_EXPECT(hmc_avi_reader_get_frame_info(reader, 1u, &second) == HMC_STATUS_OK);
    HMC_EXPECT(second.avi_index_flags == 0x10u);
    HMC_EXPECT(second.frame_flags ==
               (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN));
    hmc_avi_reader_destroy(reader);

    struct Mutation {
        std::size_t offset;
        std::uint32_t value;
    };
    const Mutation mutations[] = {
        {48u, 2u},              // avih count
        {140u, 2u},             // strh count
        {216u, 26u},            // movi excludes a chunk
        {238u, 3u},             // second movi payload size
        {idx + 24u, kAvih},     // second idx chunk id
        {idx + 32u, 4u},        // second idx overlaps first
        {idx + 36u, 3u},        // second idx payload size mismatch
        {idx + 48u, 14u},       // third idx points backward
    };
    for (const Mutation &mutation : mutations) {
        std::vector<std::uint8_t> changed = original;
        write_u32(changed, mutation.offset, mutation.value);
        expect_reader_rejects(changed);
    }

    std::vector<std::uint8_t> nonzero_padding = original;
    nonzero_padding[233u] = 0x7fu;
    expect_reader_rejects(nonzero_padding);

    std::vector<std::uint8_t> unknown_flags = original;
    write_u32(unknown_flags, idx + 28u, 0x20u);
    hmc_avi_reader_t *bad_flags_reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(
        unknown_flags.data(), unknown_flags.size(), &bad_flags_reader) ==
               HMC_STATUS_UNSUPPORTED);
    HMC_EXPECT(bad_flags_reader == nullptr);
}

HMC_TEST(avi_reader_owns_input_and_accepts_zero_frame_files)
{
    std::vector<std::uint8_t> bytes = mux(
        make_config(kCvid, 24u),
        {{0x11u, 0x22u, 0x33u}},
        {HMC_FRAME_FLAG_KEY_KNOWN});
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) == HMC_STATUS_OK);
    hmc_bytes_view_t view{};
    HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, 0u, &view) == HMC_STATUS_OK);
    HMC_EXPECT(view.size == 3u && view.data[0] == 0x11u);
    bytes[232u] = 0xffu;
    HMC_EXPECT(view.data[0] == 0x11u);
    hmc_avi_reader_destroy(reader);

    const std::vector<std::uint8_t> empty = mux(make_config(kMsvc, 16u), {}, {});
    reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(empty.data(), empty.size(), &reader) == HMC_STATUS_OK);
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.frame_count == 0u);
    hmc_bytes_view_t empty_view{};
    HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, 0u, &empty_view) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(empty_view.data == nullptr && empty_view.size == 0u);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(avi_extensible_config_and_rational_rate_contracts_are_enforced)
{
    alignas(hmc_avi_muxer_config_t) std::uint8_t extended_bytes[40];
    auto *extended = reinterpret_cast<hmc_avi_muxer_config_t *>(extended_bytes);
    HMC_EXPECT(hmc_avi_muxer_config_init(extended, sizeof(extended_bytes)) == HMC_STATUS_OK);
    extended->width = 8u;
    extended->height = 8u;
    extended->frame_rate_num = 30000u;
    extended->frame_rate_den = 1001u;
    extended->handler_fourcc = kCvid;
    extended->compression_fourcc = kCvid;
    extended->bit_count = 24u;
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(extended, &muxer) == HMC_STATUS_OK);
    hmc_owned_buffer_t output{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &output) == HMC_STATUS_OK);
    HMC_EXPECT(read_u32(output.data + 32u) == 33367u);
    HMC_EXPECT(read_u32(output.data + 128u) == 1001u);
    HMC_EXPECT(read_u32(output.data + 132u) == 30000u);
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(output.data, output.size, &reader) == HMC_STATUS_OK);
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.usec_per_frame == 33367u);
    HMC_EXPECT(info.frame_rate_num == 30000u && info.frame_rate_den == 1001u);
    hmc_avi_reader_destroy(reader);
    hmc_owned_buffer_release(&output);
    hmc_avi_muxer_destroy(muxer);

    extended_bytes[39] = 1u;
    muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(extended, &muxer) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(muxer == nullptr);
    extended_bytes[39] = 0u;
    extended->struct_size = 31u;
    HMC_EXPECT(hmc_avi_muxer_create(extended, &muxer) == HMC_STATUS_BUFFER_TOO_SMALL);

    hmc_avi_muxer_config_t invalid_rate = make_config(kCvid, 24u);
    invalid_rate.frame_rate_num = UINT32_MAX;
    HMC_EXPECT(hmc_avi_muxer_create(&invalid_rate, &muxer) == HMC_STATUS_INVALID_ARGUMENT);

    hmc_avi_muxer_config_t mismatched = make_config(kCvid, 24u);
    mismatched.compression_fourcc = kMsvc;
    HMC_EXPECT(hmc_avi_muxer_create(&mismatched, &muxer) == HMC_STATUS_UNSUPPORTED);
    mismatched = make_config(kMjpg, 16u);
    HMC_EXPECT(hmc_avi_muxer_create(&mismatched, &muxer) == HMC_STATUS_UNSUPPORTED);
}

HMC_TEST(avi_all_public_failures_preserve_handles_outputs_and_muxer_state)
{
    hmc_avi_muxer_config_t config = make_config(kCvid, 24u);
    auto *sentinel_muxer = reinterpret_cast<hmc_avi_muxer_t *>(1);
    HMC_EXPECT(hmc_avi_muxer_create(&config, &sentinel_muxer) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(sentinel_muxer == reinterpret_cast<hmc_avi_muxer_t *>(1));

    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    const std::uint8_t payload[] = {0x11u, 0x22u};
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, payload, sizeof(payload), HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);
    hmc_owned_buffer_t occupied{reinterpret_cast<std::uint8_t *>(1), 9u};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &occupied) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(occupied.data == reinterpret_cast<std::uint8_t *>(1) && occupied.size == 9u);
    hmc_owned_buffer_t output{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &output) == HMC_STATUS_OK);
    hmc_avi_muxer_destroy(muxer);

    auto *sentinel_reader = reinterpret_cast<hmc_avi_reader_t *>(1);
    HMC_EXPECT(hmc_avi_reader_create_copy(
        output.data, output.size, &sentinel_reader) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(sentinel_reader == reinterpret_cast<hmc_avi_reader_t *>(1));
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(output.data, output.size, &reader) == HMC_STATUS_OK);

    hmc_avi_frame_info_t frame_info{};
    frame_info.struct_size = sizeof(frame_info);
    std::uint8_t frame_info_before[sizeof(frame_info)];
    std::memcpy(frame_info_before, &frame_info, sizeof(frame_info));
    HMC_EXPECT(hmc_avi_reader_get_frame_info(reader, 1u, &frame_info) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(std::memcmp(frame_info_before, &frame_info, sizeof(frame_info)) == 0);

    hmc_owned_buffer_t copy{};
    honey::media::avi_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_avi_reader_copy_frame(reader, 0u, &copy) == HMC_STATUS_OUT_OF_MEMORY);
    HMC_EXPECT(copy.data == nullptr && copy.size == 0u);
    honey::media::avi_test_clear_allocation_failure();
    HMC_EXPECT(hmc_avi_reader_copy_frame(reader, 0u, &copy) == HMC_STATUS_OK);
    hmc_owned_buffer_release(&copy);
    hmc_avi_reader_destroy(reader);
    hmc_owned_buffer_release(&output);

    const std::uint8_t bad[] = {'N', 'O', 'P', 'E', 0, 0, 0, 0, 0, 0, 0, 0};
    reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bad, sizeof(bad), &reader) ==
               HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(reader == nullptr);
    HMC_EXPECT(hmc_avi_reader_create_copy(nullptr, 0u, &reader) ==
               HMC_STATUS_INVALID_ARGUMENT);
}

HMC_TEST(avi_null_and_small_output_arguments_return_without_partial_results)
{
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(nullptr, &muxer) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_muxer_create(nullptr, nullptr) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        nullptr, nullptr, 0u, HMC_FRAME_FLAG_NONE) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_muxer_finish(nullptr, nullptr) == HMC_STATUS_INVALID_ARGUMENT);

    const std::vector<std::uint8_t> bytes = load_fixture("cvid_sample.avi");
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), 0u, &reader) ==
               HMC_STATUS_MALFORMED_DATA);
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_reader_create_copy(bytes.data(), bytes.size(), &reader) == HMC_STATUS_OK);

    HMC_EXPECT(hmc_avi_reader_get_info(nullptr, nullptr) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, nullptr) == HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_reader_get_frame_info(reader, 0u, nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, 0u, nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(hmc_avi_reader_copy_frame(reader, 0u, nullptr) ==
               HMC_STATUS_INVALID_ARGUMENT);

    alignas(hmc_avi_info_t) std::uint8_t small_info[36]{};
    auto *small = reinterpret_cast<hmc_avi_info_t *>(small_info);
    small->struct_size = sizeof(small_info);
    std::uint8_t small_before[sizeof(small_info)];
    std::memcpy(small_before, small_info, sizeof(small_info));
    HMC_EXPECT(hmc_avi_reader_get_info(reader, small) == HMC_STATUS_BUFFER_TOO_SMALL);
    HMC_EXPECT(std::memcmp(small_before, small_info, sizeof(small_info)) == 0);

    alignas(hmc_avi_frame_info_t) std::uint8_t tailed_frame_info[20]{};
    auto *tailed = reinterpret_cast<hmc_avi_frame_info_t *>(tailed_frame_info);
    tailed->struct_size = sizeof(tailed_frame_info);
    tailed_frame_info[19] = 1u;
    std::uint8_t tailed_before[sizeof(tailed_frame_info)];
    std::memcpy(tailed_before, tailed_frame_info, sizeof(tailed_frame_info));
    HMC_EXPECT(hmc_avi_reader_get_frame_info(reader, 0u, tailed) ==
               HMC_STATUS_INVALID_ARGUMENT);
    HMC_EXPECT(std::memcmp(tailed_before, tailed_frame_info, sizeof(tailed_frame_info)) == 0);
    hmc_avi_reader_destroy(reader);
}

HMC_TEST(avi_growth_failure_keeps_single_frame_and_can_retry_second_frame)
{
    const hmc_avi_muxer_config_t config = make_config(kCvid, 24u);
    std::vector<std::uint8_t> first(64u);
    for (std::size_t i = 0u; i < first.size(); ++i) {
        first[i] = static_cast<std::uint8_t>(i);
    }
    const std::vector<std::uint8_t> second{0xfeu};
    const hmc_frame_flags_t first_flags =
        HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN;
    const hmc_frame_flags_t second_flags = HMC_FRAME_FLAG_KEY_KNOWN;
    const std::vector<std::uint8_t> single_baseline =
        mux(config, {first}, {first_flags});
    const std::vector<std::uint8_t> two_frame_baseline =
        mux(config, {first, second}, {first_flags, second_flags});

    for (std::size_t nth = 1u; nth <= 2u; ++nth) {
        hmc_avi_muxer_t *finish_after_failure = nullptr;
        HMC_EXPECT(hmc_avi_muxer_create(&config, &finish_after_failure) == HMC_STATUS_OK);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            finish_after_failure,
            first.data(),
            first.size(),
            first_flags) == HMC_STATUS_OK);
        honey::media::avi_test_fail_nth_allocation(nth);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            finish_after_failure,
            second.data(),
            second.size(),
            second_flags) == HMC_STATUS_OUT_OF_MEMORY);
        honey::media::avi_test_clear_allocation_failure();
        hmc_owned_buffer_t single_output{};
        HMC_EXPECT(hmc_avi_muxer_finish(finish_after_failure, &single_output) ==
                   HMC_STATUS_OK);
        HMC_EXPECT(single_output.size == single_baseline.size());
        HMC_EXPECT(std::memcmp(
            single_output.data, single_baseline.data(), single_baseline.size()) == 0);
        hmc_owned_buffer_release(&single_output);
        hmc_avi_muxer_destroy(finish_after_failure);

        hmc_avi_muxer_t *retry_after_failure = nullptr;
        HMC_EXPECT(hmc_avi_muxer_create(&config, &retry_after_failure) == HMC_STATUS_OK);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            retry_after_failure,
            first.data(),
            first.size(),
            first_flags) == HMC_STATUS_OK);
        honey::media::avi_test_fail_nth_allocation(nth);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            retry_after_failure,
            second.data(),
            second.size(),
            second_flags) == HMC_STATUS_OUT_OF_MEMORY);
        honey::media::avi_test_clear_allocation_failure();
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            retry_after_failure,
            second.data(),
            second.size(),
            second_flags) == HMC_STATUS_OK);
        hmc_owned_buffer_t two_frame_output{};
        HMC_EXPECT(hmc_avi_muxer_finish(retry_after_failure, &two_frame_output) ==
                   HMC_STATUS_OK);
        HMC_EXPECT(two_frame_output.size == two_frame_baseline.size());
        HMC_EXPECT(std::memcmp(
            two_frame_output.data,
            two_frame_baseline.data(),
            two_frame_baseline.size()) == 0);
        hmc_owned_buffer_release(&two_frame_output);
        hmc_avi_muxer_destroy(retry_after_failure);
    }
}

HMC_TEST(avi_geometric_growth_avoids_per_frame_double_allocation)
{
    const hmc_avi_muxer_config_t config = make_config(kCvid, 24u);
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    honey::media::avi_test_clear_allocation_failure();
    for (std::uint32_t i = 0u; i < 128u; ++i) {
        const std::uint8_t byte = static_cast<std::uint8_t>(i);
        HMC_EXPECT(hmc_avi_muxer_add_frame(
            muxer, &byte, 1u, HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);
    }
    HMC_EXPECT(honey::media::avi_test_allocation_count() <= 16u);

    hmc_owned_buffer_t output{};
    HMC_EXPECT(hmc_avi_muxer_finish(muxer, &output) == HMC_STATUS_OK);
    hmc_avi_reader_t *reader = nullptr;
    HMC_EXPECT(hmc_avi_reader_create_copy(output.data, output.size, &reader) == HMC_STATUS_OK);
    hmc_avi_info_t info{};
    info.struct_size = sizeof(info);
    HMC_EXPECT(hmc_avi_reader_get_info(reader, &info) == HMC_STATUS_OK);
    HMC_EXPECT(info.frame_count == 128u);
    for (std::uint32_t i : {0u, 63u, 64u, 127u}) {
        hmc_bytes_view_t view{};
        HMC_EXPECT(hmc_avi_reader_get_frame_view(reader, i, &view) == HMC_STATUS_OK);
        HMC_EXPECT(view.size == 1u && view.data[0] == static_cast<std::uint8_t>(i));
    }
    hmc_avi_reader_destroy(reader);
    hmc_owned_buffer_release(&output);
    hmc_avi_muxer_destroy(muxer);
    honey::media::avi_test_clear_allocation_failure();
}

HMC_TEST(avi_add_uses_existing_capacity_without_allocating)
{
    const hmc_avi_muxer_config_t config = make_config(kCvid, 24u);
    hmc_avi_muxer_t *muxer = nullptr;
    HMC_EXPECT(hmc_avi_muxer_create(&config, &muxer) == HMC_STATUS_OK);
    std::vector<std::uint8_t> first(64u, 0x11u);
    const std::uint8_t later = 0x22u;
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, first.data(), first.size(), HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, &later, 1u, HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, &later, 1u, HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);

    honey::media::avi_test_fail_nth_allocation(1u);
    HMC_EXPECT(hmc_avi_muxer_add_frame(
        muxer, &later, 1u, HMC_FRAME_FLAG_KEY_KNOWN) == HMC_STATUS_OK);
    HMC_EXPECT(honey::media::avi_test_allocation_count() == 0u);
    honey::media::avi_test_clear_allocation_failure();
    hmc_avi_muxer_destroy(muxer);
}

HMC_TEST(avi_mjpg_matches_an_independent_msvc_golden_transform)
{
    const std::vector<std::uint8_t> msv1_key = load_fixture("msv1_key.bin");
    const std::vector<std::uint8_t> msv1_skip = load_fixture("msv1_all_skip.bin");
    const std::vector<std::uint8_t> msv1_inter = load_fixture("msv1_inter.bin");
    const std::vector<hmc_frame_flags_t> flags{
        HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN,
        HMC_FRAME_FLAG_KEY_KNOWN,
        HMC_FRAME_FLAG_KEY_KNOWN};
    const std::vector<std::uint8_t> actual = mux(
        make_config(kMjpg, 24u),
        {msv1_key, msv1_skip, msv1_inter},
        flags);

    std::vector<std::uint8_t> expected = load_fixture("msvc_sample.avi");
    write_u32(expected, 112u, kMjpg);
    expected[186u] = 24u;
    expected[187u] = 0u;
    write_u32(expected, 188u, kMjpg);
    HMC_EXPECT(actual == expected);

    const std::vector<std::uint8_t> msvc = load_fixture("msvc_sample.avi");
    std::size_t difference_count = 0u;
    for (std::size_t i = 0u; i < expected.size(); ++i) {
        if (expected[i] != msvc[i]) {
            HMC_EXPECT((i >= 112u && i < 116u) ||
                       i == 186u ||
                       (i >= 188u && i < 192u));
            ++difference_count;
        }
    }
    HMC_EXPECT(difference_count == 7u);
}
