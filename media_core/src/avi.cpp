#include "avi.hpp"

#include "allocator.hpp"
#include "core_types.hpp"

#include <cstring>
#include <limits>

namespace honey::media {
namespace {

constexpr std::uint32_t kRiff = HMC_MEDIA_FOURCC('R', 'I', 'F', 'F');
constexpr std::uint32_t kAvi = HMC_MEDIA_FOURCC('A', 'V', 'I', ' ');
constexpr std::uint32_t kList = HMC_MEDIA_FOURCC('L', 'I', 'S', 'T');
constexpr std::uint32_t kHdrl = HMC_MEDIA_FOURCC('h', 'd', 'r', 'l');
constexpr std::uint32_t kAvih = HMC_MEDIA_FOURCC('a', 'v', 'i', 'h');
constexpr std::uint32_t kStrl = HMC_MEDIA_FOURCC('s', 't', 'r', 'l');
constexpr std::uint32_t kStrh = HMC_MEDIA_FOURCC('s', 't', 'r', 'h');
constexpr std::uint32_t kStrf = HMC_MEDIA_FOURCC('s', 't', 'r', 'f');
constexpr std::uint32_t kVids = HMC_MEDIA_FOURCC('v', 'i', 'd', 's');
constexpr std::uint32_t kMovi = HMC_MEDIA_FOURCC('m', 'o', 'v', 'i');
constexpr std::uint32_t kIdx1 = HMC_MEDIA_FOURCC('i', 'd', 'x', '1');
constexpr std::uint32_t k00dc = HMC_MEDIA_FOURCC('0', '0', 'd', 'c');
constexpr std::uint32_t kCvid = HMC_MEDIA_FOURCC('c', 'v', 'i', 'd');
constexpr std::uint32_t kMsvc = HMC_MEDIA_FOURCC('M', 'S', 'V', 'C');
constexpr std::uint32_t kMjpg = HMC_MEDIA_FOURCC('M', 'J', 'P', 'G');
constexpr std::size_t kHeaderBytes = 212u;

void *avi_allocate(std::size_t size) noexcept
{
    return allocate(size);
}

void avi_deallocate(void *pointer) noexcept
{
    deallocate(pointer);
}

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

bool size_fits_u32(std::size_t value) noexcept
{
    return value <= static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max());
}

hmc_status_t geometric_capacity(
    std::size_t current,
    std::size_t required,
    std::size_t minimum,
    std::size_t limit,
    std::size_t *result) noexcept
{
    if (result == nullptr || required > limit) {
        return HMC_STATUS_OVERFLOW;
    }
    if (required <= current) {
        *result = current;
        return HMC_STATUS_OK;
    }
    std::size_t candidate = current == 0u ? minimum : current;
    if (candidate > limit) {
        return HMC_STATUS_OVERFLOW;
    }
    while (candidate < required) {
        if (candidate > limit / 2u) {
            candidate = limit;
        } else {
            candidate *= 2u;
        }
        if (candidate < required && candidate == limit) {
            return HMC_STATUS_OVERFLOW;
        }
    }
    *result = candidate;
    return HMC_STATUS_OK;
}

std::uint16_t read_u16(const std::uint8_t *data) noexcept
{
    return static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(data[0]) |
        static_cast<std::uint16_t>(static_cast<std::uint16_t>(data[1]) << 8u));
}

std::uint32_t read_u32(const std::uint8_t *data) noexcept
{
    return static_cast<std::uint32_t>(data[0]) |
           (static_cast<std::uint32_t>(data[1]) << 8u) |
           (static_cast<std::uint32_t>(data[2]) << 16u) |
           (static_cast<std::uint32_t>(data[3]) << 24u);
}

void write_u16(std::uint8_t *&cursor, std::uint16_t value) noexcept
{
    *cursor++ = static_cast<std::uint8_t>(value);
    *cursor++ = static_cast<std::uint8_t>(value >> 8u);
}

void write_u32(std::uint8_t *&cursor, std::uint32_t value) noexcept
{
    *cursor++ = static_cast<std::uint8_t>(value);
    *cursor++ = static_cast<std::uint8_t>(value >> 8u);
    *cursor++ = static_cast<std::uint8_t>(value >> 16u);
    *cursor++ = static_cast<std::uint8_t>(value >> 24u);
}

void write_fourcc(std::uint8_t *&cursor, std::uint32_t value) noexcept
{
    write_u32(cursor, value);
}

bool checked_range(std::size_t offset, std::size_t length, std::size_t limit) noexcept
{
    std::size_t end = 0u;
    return checked_add_size(offset, length, &end) && end <= limit;
}

hmc_status_t validate_profile(
    const hmc_avi_muxer_config_t &config,
    std::uint32_t *image_size,
    std::uint32_t *usec_per_frame) noexcept
{
    if (config.width == 0u || config.height == 0u ||
        config.width > 65535u || config.height > 65535u ||
        config.frame_rate_num == 0u || config.frame_rate_den == 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    const bool cvid = config.handler_fourcc == kCvid &&
                      config.compression_fourcc == kCvid &&
                      config.bit_count == 24u;
    const bool msvc = config.handler_fourcc == kMsvc &&
                      config.compression_fourcc == kMsvc &&
                      config.bit_count == 16u;
    const bool mjpg = config.handler_fourcc == kMjpg &&
                      config.compression_fourcc == kMjpg &&
                      config.bit_count == 24u;
    if (!cvid && !msvc && !mjpg) {
        return HMC_STATUS_UNSUPPORTED;
    }

    std::size_t pixels = 0u;
    std::size_t bytes = 0u;
    const std::size_t multiplier = cvid ? 3u : 2u;
    if (!checked_multiply_size(config.width, config.height, &pixels) ||
        !checked_multiply_size(pixels, multiplier, &bytes) ||
        !size_fits_u32(bytes)) {
        return HMC_STATUS_OVERFLOW;
    }

    const std::uint64_t numerator =
        UINT64_C(1000000) * static_cast<std::uint64_t>(config.frame_rate_den);
    const std::uint64_t rounded =
        (numerator + static_cast<std::uint64_t>(config.frame_rate_num) / 2u) /
        static_cast<std::uint64_t>(config.frame_rate_num);
    if (rounded == 0u || rounded > std::numeric_limits<std::uint32_t>::max()) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }

    *image_size = static_cast<std::uint32_t>(bytes);
    *usec_per_frame = static_cast<std::uint32_t>(rounded);
    return HMC_STATUS_OK;
}

hmc_status_t validate_input_struct(
    const void *structure,
    std::uint32_t structure_size,
    std::uint32_t v1_size) noexcept
{
    if (structure == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (structure_size < v1_size) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    if (!span_is_zero(structure, v1_size, structure_size)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    return HMC_STATUS_OK;
}

hmc_status_t validate_output_struct(
    const void *structure,
    std::uint32_t structure_size,
    std::uint32_t v1_size) noexcept
{
    const hmc_status_t status = validate_input_struct(structure, structure_size, v1_size);
    if (status != HMC_STATUS_OK) {
        return status;
    }
    if (!span_is_zero(structure, sizeof(std::uint32_t), structure_size)) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    return HMC_STATUS_OK;
}

hmc_status_t calculate_avi_size(
    const hmc_avi_muxer_t *muxer,
    std::size_t *total_size,
    std::uint32_t *movi_size,
    std::uint32_t *idx_size,
    std::uint32_t *max_frame_size) noexcept
{
    std::size_t movi = 4u;
    std::uint32_t maximum = muxer->config.handler_fourcc == kCvid ? 0u : 1u;
    for (std::uint32_t i = 0u; i < muxer->frame_count; ++i) {
        const std::size_t frame_size = muxer->frames[i].payload_size;
        std::size_t chunk_size = 0u;
        if (!size_fits_u32(frame_size) ||
            !checked_add_size(8u, frame_size, &chunk_size) ||
            !checked_add_size(chunk_size, frame_size & 1u, &chunk_size) ||
            !checked_add_size(movi, chunk_size, &movi)) {
            return HMC_STATUS_OVERFLOW;
        }
        if (frame_size > maximum) {
            maximum = static_cast<std::uint32_t>(frame_size);
        }
    }
    std::size_t index = 0u;
    if (!checked_multiply_size(muxer->frame_count, 16u, &index) ||
        !size_fits_u32(index) || !size_fits_u32(movi)) {
        return HMC_STATUS_OVERFLOW;
    }
    if (movi != muxer->movi_size) {
        return HMC_STATUS_INTERNAL_ERROR;
    }
    std::size_t total = 0u;
    if (!checked_add_size(228u, movi, &total) ||
        !checked_add_size(total, index, &total) ||
        total < 8u || !size_fits_u32(total - 8u)) {
        return HMC_STATUS_OVERFLOW;
    }
    *total_size = total;
    *movi_size = static_cast<std::uint32_t>(movi);
    *idx_size = static_cast<std::uint32_t>(index);
    *max_frame_size = maximum;
    return HMC_STATUS_OK;
}

hmc_status_t parse_reader(hmc_avi_reader_t *reader) noexcept
{
    const std::uint8_t *bytes = reader->bytes;
    const std::size_t size = reader->bytes_size;
    if (size < 232u ||
        read_u32(bytes) != kRiff ||
        read_u32(bytes + 8u) != kAvi ||
        read_u32(bytes + 12u) != kList ||
        read_u32(bytes + 20u) != kHdrl ||
        read_u32(bytes + 24u) != kAvih ||
        read_u32(bytes + 28u) != 56u ||
        read_u32(bytes + 88u) != kList ||
        read_u32(bytes + 96u) != kStrl ||
        read_u32(bytes + 100u) != kStrh ||
        read_u32(bytes + 104u) != 56u ||
        read_u32(bytes + 164u) != kStrf ||
        read_u32(bytes + 168u) != 40u ||
        read_u32(bytes + kHeaderBytes) != kList ||
        read_u32(bytes + 220u) != kMovi) {
        return HMC_STATUS_MALFORMED_DATA;
    }
    if (read_u32(bytes + 4u) != size - 8u || read_u32(bytes + 16u) != 192u) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    const std::uint32_t usec = read_u32(bytes + 32u);
    const std::uint32_t avih_flags = read_u32(bytes + 44u);
    const std::uint32_t avih_count = read_u32(bytes + 48u);
    const std::uint32_t streams = read_u32(bytes + 56u);
    const std::uint32_t suggested = read_u32(bytes + 60u);
    const std::uint32_t width = read_u32(bytes + 64u);
    const std::uint32_t height = read_u32(bytes + 68u);
    const std::uint32_t handler = read_u32(bytes + 112u);
    const std::uint32_t scale = read_u32(bytes + 128u);
    const std::uint32_t rate = read_u32(bytes + 132u);
    const std::uint32_t strh_count = read_u32(bytes + 140u);
    const std::uint32_t strh_suggested = read_u32(bytes + 144u);
    const std::uint32_t quality = read_u32(bytes + 148u);
    const std::uint32_t bi_size = read_u32(bytes + 172u);
    const std::uint32_t bi_width = read_u32(bytes + 176u);
    const std::uint32_t bi_height = read_u32(bytes + 180u);
    const std::uint16_t planes = read_u16(bytes + 184u);
    const std::uint16_t bit_count = read_u16(bytes + 186u);
    const std::uint32_t compression = read_u32(bytes + 188u);
    const std::uint32_t image_size = read_u32(bytes + 192u);

    hmc_avi_muxer_config_t config{};
    config.struct_size = sizeof(config);
    config.width = width;
    config.height = height;
    config.frame_rate_num = rate;
    config.frame_rate_den = scale;
    config.handler_fourcc = handler;
    config.compression_fourcc = compression;
    config.bit_count = bit_count;
    std::uint32_t expected_image_size = 0u;
    std::uint32_t expected_usec = 0u;
    const std::uint32_t strl_size = read_u32(bytes + 92u);
    const hmc_status_t profile_status =
        validate_profile(config, &expected_image_size, &expected_usec);
    if (profile_status != HMC_STATUS_OK) {
        return strl_size == 124u
                   ? HMC_STATUS_MALFORMED_DATA
                   : profile_status == HMC_STATUS_UNSUPPORTED
                   ? HMC_STATUS_UNSUPPORTED
                   : HMC_STATUS_MALFORMED_DATA;
    }

    const bool cvid = handler == kCvid;
    const std::uint32_t expected_quality = cvid ? 0u : UINT32_MAX;
    const std::uint32_t expected_empty_suggested = cvid ? 0u : 1u;
    if ((cvid && strl_size != 116u) ||
        (!cvid && strl_size != 124u) ||
        avih_flags != 0x10u ||
        streams != 1u ||
        width == 0u || height == 0u ||
        usec != expected_usec ||
        avih_count != strh_count ||
        read_u32(bytes + 108u) != kVids ||
        read_u32(bytes + 116u) != 0u ||
        read_u16(bytes + 120u) != 0u ||
        read_u16(bytes + 122u) != 0u ||
        read_u32(bytes + 124u) != 0u ||
        read_u32(bytes + 136u) != 0u ||
        quality != expected_quality ||
        read_u32(bytes + 152u) != 0u ||
        read_u16(bytes + 156u) != 0u ||
        read_u16(bytes + 158u) != 0u ||
        read_u16(bytes + 160u) != width ||
        read_u16(bytes + 162u) != height ||
        bi_size != 40u ||
        bi_width != width ||
        bi_height != height ||
        planes != 1u ||
        image_size != expected_image_size ||
        !span_is_zero(bytes, 36u, 44u) ||
        !span_is_zero(bytes, 52u, 56u) ||
        !span_is_zero(bytes, 72u, 88u) ||
        !span_is_zero(bytes, 196u, kHeaderBytes)) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    std::size_t movi_end = 0u;
    const std::uint32_t movi_size = read_u32(bytes + 216u);
    if (movi_size < 4u ||
        !checked_add_size(220u, movi_size, &movi_end) ||
        !checked_range(movi_end, 8u, size) ||
        read_u32(bytes + movi_end) != kIdx1) {
        return HMC_STATUS_MALFORMED_DATA;
    }
    const std::uint32_t idx_size = read_u32(bytes + movi_end + 4u);
    std::size_t idx_end = 0u;
    if ((idx_size & 15u) != 0u ||
        !checked_add_size(movi_end + 8u, idx_size, &idx_end) ||
        idx_end != size ||
        idx_size / 16u != avih_count) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    std::size_t chunk = 224u;
    std::uint32_t actual_count = 0u;
    std::uint32_t actual_maximum = expected_empty_suggested;
    while (chunk < movi_end) {
        if (!checked_range(chunk, 8u, movi_end) || read_u32(bytes + chunk) != k00dc) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        const std::uint32_t payload_size = read_u32(bytes + chunk + 4u);
        if (payload_size == 0u) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        std::size_t next = 0u;
        std::size_t padded_size = payload_size;
        if (!checked_add_size(padded_size, payload_size & 1u, &padded_size) ||
            !checked_add_size(chunk + 8u, padded_size, &next) ||
            next > movi_end ||
            ((payload_size & 1u) != 0u && bytes[chunk + 8u + payload_size] != 0u) ||
            actual_count == UINT32_MAX) {
            return HMC_STATUS_MALFORMED_DATA;
        }
        if (payload_size > actual_maximum) {
            actual_maximum = payload_size;
        }
        chunk = next;
        ++actual_count;
    }
    if (chunk != movi_end || actual_count != avih_count ||
        suggested != actual_maximum || strh_suggested != actual_maximum) {
        return HMC_STATUS_MALFORMED_DATA;
    }

    hmc_avi_frame_record *records = nullptr;
    if (actual_count != 0u) {
        std::size_t records_size = 0u;
        if (!checked_multiply_size(actual_count, sizeof(hmc_avi_frame_record), &records_size)) {
            return HMC_STATUS_OVERFLOW;
        }
        records = static_cast<hmc_avi_frame_record *>(avi_allocate(records_size));
        if (records == nullptr) {
            return HMC_STATUS_OUT_OF_MEMORY;
        }
    }

    chunk = 224u;
    for (std::uint32_t i = 0u; i < actual_count; ++i) {
        const std::size_t entry = movi_end + 8u + static_cast<std::size_t>(i) * 16u;
        const std::uint32_t raw_flags = read_u32(bytes + entry + 4u);
        const std::uint32_t offset = read_u32(bytes + entry + 8u);
        const std::uint32_t payload_size = read_u32(bytes + entry + 12u);
        if (read_u32(bytes + entry) != k00dc ||
            (raw_flags != 0u && raw_flags != 0x10u)) {
            avi_deallocate(records);
            return raw_flags != 0u && raw_flags != 0x10u
                       ? HMC_STATUS_UNSUPPORTED
                       : HMC_STATUS_MALFORMED_DATA;
        }
        if (offset != chunk - 220u ||
            payload_size != read_u32(bytes + chunk + 4u)) {
            avi_deallocate(records);
            return HMC_STATUS_MALFORMED_DATA;
        }
        records[i].payload_offset = chunk + 8u;
        records[i].payload_size = payload_size;
        records[i].avi_index_flags = raw_flags;
        records[i].frame_flags =
            HMC_FRAME_FLAG_KEY_KNOWN |
            (raw_flags == 0x10u ? HMC_FRAME_FLAG_KEY : 0u);
        chunk += 8u + payload_size + (payload_size & 1u);
    }

    reader->info.struct_size = sizeof(reader->info);
    reader->info.width = width;
    reader->info.height = height;
    reader->info.usec_per_frame = usec;
    reader->info.frame_rate_num = rate;
    reader->info.frame_rate_den = scale;
    reader->info.handler_fourcc = handler;
    reader->info.compression_fourcc = compression;
    reader->info.bit_count = bit_count;
    reader->info.frame_count = actual_count;
    reader->frames = records;
    return HMC_STATUS_OK;
}

} // namespace

hmc_status_t avi_muxer_config_init(
    hmc_avi_muxer_config_t *config,
    std::uint32_t config_size) noexcept
{
    if (config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (config_size < HMC_AVI_MUXER_CONFIG_V1_SIZE) {
        return HMC_STATUS_BUFFER_TOO_SMALL;
    }
    std::memset(config, 0, config_size);
    config->struct_size = config_size;
    return HMC_STATUS_OK;
}

hmc_status_t avi_muxer_create(
    const hmc_avi_muxer_config_t *config,
    hmc_avi_muxer_t **muxer) noexcept
{
    if (muxer == nullptr || *muxer != nullptr || config == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const hmc_status_t struct_status =
        validate_input_struct(config, config->struct_size, HMC_AVI_MUXER_CONFIG_V1_SIZE);
    if (struct_status != HMC_STATUS_OK) {
        return struct_status;
    }
    std::uint32_t image_size = 0u;
    std::uint32_t usec = 0u;
    const hmc_status_t profile_status = validate_profile(*config, &image_size, &usec);
    (void)image_size;
    if (profile_status != HMC_STATUS_OK) {
        return profile_status;
    }
    auto *candidate = static_cast<hmc_avi_muxer_t *>(avi_allocate(sizeof(hmc_avi_muxer_t)));
    if (candidate == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    candidate->config = *config;
    candidate->config.struct_size = HMC_AVI_MUXER_CONFIG_V1_SIZE;
    candidate->usec_per_frame = usec;
    candidate->frame_count = 0u;
    candidate->movi_size = 4u;
    candidate->payloads = nullptr;
    candidate->payloads_size = 0u;
    candidate->payloads_capacity = 0u;
    candidate->frames = nullptr;
    candidate->frames_capacity = 0u;
    candidate->sealed = false;
    *muxer = candidate;
    return HMC_STATUS_OK;
}

hmc_status_t avi_muxer_add_frame(
    hmc_avi_muxer_t *muxer,
    const std::uint8_t *data,
    std::size_t size,
    hmc_frame_flags_t frame_flags) noexcept
{
    if (muxer == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (muxer->sealed) {
        return HMC_STATUS_INVALID_STATE;
    }
    if (data == nullptr || size == 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (frame_flags != HMC_FRAME_FLAG_KEY_KNOWN &&
        frame_flags != (HMC_FRAME_FLAG_KEY | HMC_FRAME_FLAG_KEY_KNOWN)) {
        return HMC_STATUS_UNSUPPORTED;
    }
    if (!size_fits_u32(size) || muxer->frame_count == UINT32_MAX) {
        return HMC_STATUS_OVERFLOW;
    }
    const std::size_t required_records =
        static_cast<std::size_t>(muxer->frame_count) + 1u;
    std::size_t frame_chunk_size = 0u;
    std::size_t prospective_total = 0u;
    std::size_t prospective_movi = 0u;
    std::size_t prospective_idx = 0u;
    if (!checked_add_size(8u, size, &frame_chunk_size) ||
        !checked_add_size(frame_chunk_size, size & 1u, &frame_chunk_size) ||
        !checked_add_size(muxer->movi_size, frame_chunk_size, &prospective_movi) ||
        !size_fits_u32(prospective_movi) ||
        !checked_multiply_size(required_records, 16u, &prospective_idx) ||
        !size_fits_u32(prospective_idx) ||
        !checked_add_size(228u, prospective_movi, &prospective_total) ||
        !checked_add_size(prospective_total, prospective_idx, &prospective_total) ||
        prospective_total < 8u ||
        !size_fits_u32(prospective_total - 8u)) {
        return HMC_STATUS_OVERFLOW;
    }
    std::size_t candidate_payload_size = 0u;
    if (!checked_add_size(muxer->payloads_size, size, &candidate_payload_size)) {
        return HMC_STATUS_OVERFLOW;
    }

    std::size_t candidate_payload_capacity = muxer->payloads_capacity;
    std::size_t candidate_frames_capacity = muxer->frames_capacity;
    hmc_status_t capacity_status = geometric_capacity(
        muxer->payloads_capacity,
        candidate_payload_size,
        64u,
        static_cast<std::size_t>(UINT32_MAX),
        &candidate_payload_capacity);
    if (capacity_status != HMC_STATUS_OK) {
        return capacity_status;
    }
    capacity_status = geometric_capacity(
        muxer->frames_capacity,
        required_records,
        1u,
        static_cast<std::size_t>(UINT32_MAX),
        &candidate_frames_capacity);
    if (capacity_status != HMC_STATUS_OK) {
        return capacity_status;
    }

    const bool grow_payloads =
        candidate_payload_capacity != muxer->payloads_capacity;
    const bool grow_frames =
        candidate_frames_capacity != muxer->frames_capacity;
    std::uint8_t *candidate_payloads = nullptr;
    hmc_avi_frame_record *candidate_records = nullptr;
    if (grow_payloads) {
        candidate_payloads =
            static_cast<std::uint8_t *>(avi_allocate(candidate_payload_capacity));
        if (candidate_payloads == nullptr) {
            return HMC_STATUS_OUT_OF_MEMORY;
        }
    }
    if (grow_frames) {
        std::size_t candidate_records_size = 0u;
        if (!checked_multiply_size(
                candidate_frames_capacity,
                sizeof(hmc_avi_frame_record),
                &candidate_records_size)) {
            avi_deallocate(candidate_payloads);
            return HMC_STATUS_OVERFLOW;
        }
        candidate_records =
            static_cast<hmc_avi_frame_record *>(avi_allocate(candidate_records_size));
        if (candidate_records == nullptr) {
            avi_deallocate(candidate_payloads);
            return HMC_STATUS_OUT_OF_MEMORY;
        }
    }

    std::uint8_t *target_payloads =
        grow_payloads ? candidate_payloads : muxer->payloads;
    hmc_avi_frame_record *target_records =
        grow_frames ? candidate_records : muxer->frames;
    if (grow_payloads && muxer->payloads_size != 0u) {
        std::memcpy(target_payloads, muxer->payloads, muxer->payloads_size);
    }
    if (grow_frames && muxer->frame_count != 0u) {
        std::memcpy(
            target_records,
            muxer->frames,
            static_cast<std::size_t>(muxer->frame_count) * sizeof(hmc_avi_frame_record));
    }
    std::memcpy(target_payloads + muxer->payloads_size, data, size);
    hmc_avi_frame_record &record = target_records[muxer->frame_count];
    record.payload_offset = muxer->payloads_size;
    record.payload_size = size;
    record.avi_index_flags =
        (frame_flags & HMC_FRAME_FLAG_KEY) != 0u ? 0x10u : 0u;
    record.frame_flags = frame_flags;

    if (grow_payloads) {
        avi_deallocate(muxer->payloads);
        muxer->payloads = candidate_payloads;
        muxer->payloads_capacity = candidate_payload_capacity;
    }
    if (grow_frames) {
        avi_deallocate(muxer->frames);
        muxer->frames = candidate_records;
        muxer->frames_capacity = candidate_frames_capacity;
    }
    muxer->payloads_size = candidate_payload_size;
    muxer->movi_size = static_cast<std::uint32_t>(prospective_movi);
    ++muxer->frame_count;
    return HMC_STATUS_OK;
}

hmc_status_t avi_muxer_finish(
    hmc_avi_muxer_t *muxer,
    hmc_owned_buffer_t *output) noexcept
{
    if (muxer == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (muxer->sealed) {
        return HMC_STATUS_INVALID_STATE;
    }
    if (output == nullptr || output->data != nullptr || output->size != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    std::size_t total_size = 0u;
    std::uint32_t movi_size = 0u;
    std::uint32_t idx_size = 0u;
    std::uint32_t maximum = 0u;
    const hmc_status_t size_status =
        calculate_avi_size(muxer, &total_size, &movi_size, &idx_size, &maximum);
    if (size_status != HMC_STATUS_OK) {
        return size_status;
    }
    auto *bytes = static_cast<std::uint8_t *>(avi_allocate(total_size));
    if (bytes == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    std::uint8_t *cursor = bytes;
    const bool cvid = muxer->config.handler_fourcc == kCvid;
    const std::uint32_t quality = cvid ? 0u : UINT32_MAX;
    std::uint32_t image_size = 0u;
    std::uint32_t ignored_usec = 0u;
    if (validate_profile(muxer->config, &image_size, &ignored_usec) != HMC_STATUS_OK) {
        avi_deallocate(bytes);
        return HMC_STATUS_INTERNAL_ERROR;
    }

    write_fourcc(cursor, kRiff);
    write_u32(cursor, static_cast<std::uint32_t>(total_size - 8u));
    write_fourcc(cursor, kAvi);
    write_fourcc(cursor, kList);
    write_u32(cursor, 192u);
    write_fourcc(cursor, kHdrl);
    write_fourcc(cursor, kAvih);
    write_u32(cursor, 56u);
    write_u32(cursor, muxer->usec_per_frame);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, 0x10u);
    write_u32(cursor, muxer->frame_count);
    write_u32(cursor, 0u);
    write_u32(cursor, 1u);
    write_u32(cursor, maximum);
    write_u32(cursor, muxer->config.width);
    write_u32(cursor, muxer->config.height);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);

    write_fourcc(cursor, kList);
    write_u32(cursor, cvid ? 116u : 124u);
    write_fourcc(cursor, kStrl);
    write_fourcc(cursor, kStrh);
    write_u32(cursor, 56u);
    write_fourcc(cursor, kVids);
    write_fourcc(cursor, muxer->config.handler_fourcc);
    write_u32(cursor, 0u);
    write_u16(cursor, 0u);
    write_u16(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, muxer->config.frame_rate_den);
    write_u32(cursor, muxer->config.frame_rate_num);
    write_u32(cursor, 0u);
    write_u32(cursor, muxer->frame_count);
    write_u32(cursor, maximum);
    write_u32(cursor, quality);
    write_u32(cursor, 0u);
    write_u16(cursor, 0u);
    write_u16(cursor, 0u);
    write_u16(cursor, static_cast<std::uint16_t>(muxer->config.width));
    write_u16(cursor, static_cast<std::uint16_t>(muxer->config.height));

    write_fourcc(cursor, kStrf);
    write_u32(cursor, 40u);
    write_u32(cursor, 40u);
    write_u32(cursor, muxer->config.width);
    write_u32(cursor, muxer->config.height);
    write_u16(cursor, 1u);
    write_u16(cursor, static_cast<std::uint16_t>(muxer->config.bit_count));
    write_fourcc(cursor, muxer->config.compression_fourcc);
    write_u32(cursor, image_size);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);
    write_u32(cursor, 0u);

    write_fourcc(cursor, kList);
    write_u32(cursor, movi_size);
    std::uint8_t *movi_fourcc = cursor;
    write_fourcc(cursor, kMovi);
    for (std::uint32_t i = 0u; i < muxer->frame_count; ++i) {
        const hmc_avi_frame_record &frame = muxer->frames[i];
        write_fourcc(cursor, k00dc);
        write_u32(cursor, static_cast<std::uint32_t>(frame.payload_size));
        std::memcpy(
            cursor, muxer->payloads + frame.payload_offset, frame.payload_size);
        cursor += frame.payload_size;
        if ((frame.payload_size & 1u) != 0u) {
            *cursor++ = 0u;
        }
    }
    write_fourcc(cursor, kIdx1);
    write_u32(cursor, idx_size);
    std::size_t frame_offset = 4u;
    for (std::uint32_t i = 0u; i < muxer->frame_count; ++i) {
        const hmc_avi_frame_record &frame = muxer->frames[i];
        write_fourcc(cursor, k00dc);
        write_u32(cursor, frame.avi_index_flags);
        write_u32(cursor, static_cast<std::uint32_t>(frame_offset));
        write_u32(cursor, static_cast<std::uint32_t>(frame.payload_size));
        frame_offset += 8u + frame.payload_size + (frame.payload_size & 1u);
    }
    if (cursor != bytes + total_size || movi_fourcc != bytes + 220u) {
        avi_deallocate(bytes);
        return HMC_STATUS_INTERNAL_ERROR;
    }

    output->data = bytes;
    output->size = total_size;
    muxer->sealed = true;
    return HMC_STATUS_OK;
}

void avi_muxer_destroy(hmc_avi_muxer_t *muxer) noexcept
{
    if (muxer == nullptr) {
        return;
    }
    avi_deallocate(muxer->payloads);
    avi_deallocate(muxer->frames);
    avi_deallocate(muxer);
}

hmc_status_t avi_reader_create_copy(
    const std::uint8_t *data,
    std::size_t size,
    hmc_avi_reader_t **reader) noexcept
{
    if (data == nullptr || reader == nullptr || *reader != nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (size < 12u) {
        return HMC_STATUS_MALFORMED_DATA;
    }
    if (size - 8u > static_cast<std::size_t>(UINT32_MAX)) {
        return HMC_STATUS_OVERFLOW;
    }
    auto *candidate = static_cast<hmc_avi_reader_t *>(avi_allocate(sizeof(hmc_avi_reader_t)));
    if (candidate == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    candidate->bytes = static_cast<std::uint8_t *>(avi_allocate(size));
    if (candidate->bytes == nullptr) {
        avi_deallocate(candidate);
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    std::memcpy(candidate->bytes, data, size);
    candidate->bytes_size = size;
    std::memset(&candidate->info, 0, sizeof(candidate->info));
    candidate->frames = nullptr;
    const hmc_status_t status = parse_reader(candidate);
    if (status != HMC_STATUS_OK) {
        avi_deallocate(candidate->frames);
        avi_deallocate(candidate->bytes);
        avi_deallocate(candidate);
        return status;
    }
    *reader = candidate;
    return HMC_STATUS_OK;
}

hmc_status_t avi_reader_get_info(
    const hmc_avi_reader_t *reader,
    hmc_avi_info_t *info) noexcept
{
    if (reader == nullptr || info == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const std::uint32_t caller_size = info->struct_size;
    const hmc_status_t status =
        validate_output_struct(info, caller_size, HMC_AVI_INFO_V1_SIZE);
    if (status != HMC_STATUS_OK) {
        return status;
    }
    hmc_avi_info_t result = reader->info;
    result.struct_size = caller_size;
    std::memcpy(info, &result, sizeof(result));
    return HMC_STATUS_OK;
}

hmc_status_t avi_reader_get_frame_info(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_avi_frame_info_t *frame_info) noexcept
{
    if (reader == nullptr || frame_info == nullptr) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const std::uint32_t caller_size = frame_info->struct_size;
    const hmc_status_t status = validate_output_struct(
        frame_info, caller_size, HMC_AVI_FRAME_INFO_V1_SIZE);
    if (status != HMC_STATUS_OK) {
        return status;
    }
    if (index >= reader->info.frame_count) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    hmc_avi_frame_info_t result{};
    result.struct_size = caller_size;
    result.chunk_fourcc = k00dc;
    result.avi_index_flags = reader->frames[index].avi_index_flags;
    result.frame_flags = reader->frames[index].frame_flags;
    std::memcpy(frame_info, &result, sizeof(result));
    return HMC_STATUS_OK;
}

hmc_status_t avi_reader_get_frame_view(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_bytes_view_t *frame) noexcept
{
    if (reader == nullptr || frame == nullptr ||
        frame->data != nullptr || frame->size != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (index >= reader->info.frame_count) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    frame->data = reader->bytes + reader->frames[index].payload_offset;
    frame->size = reader->frames[index].payload_size;
    return HMC_STATUS_OK;
}

hmc_status_t avi_reader_copy_frame(
    const hmc_avi_reader_t *reader,
    std::uint32_t index,
    hmc_owned_buffer_t *frame) noexcept
{
    if (reader == nullptr || frame == nullptr ||
        frame->data != nullptr || frame->size != 0u) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    if (index >= reader->info.frame_count) {
        return HMC_STATUS_INVALID_ARGUMENT;
    }
    const hmc_avi_frame_record &record = reader->frames[index];
    auto *copy = static_cast<std::uint8_t *>(avi_allocate(record.payload_size));
    if (copy == nullptr) {
        return HMC_STATUS_OUT_OF_MEMORY;
    }
    std::memcpy(copy, reader->bytes + record.payload_offset, record.payload_size);
    frame->data = copy;
    frame->size = record.payload_size;
    return HMC_STATUS_OK;
}

void avi_reader_destroy(hmc_avi_reader_t *reader) noexcept
{
    if (reader == nullptr) {
        return;
    }
    avi_deallocate(reader->frames);
    avi_deallocate(reader->bytes);
    avi_deallocate(reader);
}

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void avi_test_fail_nth_allocation(std::size_t allocation_number) noexcept
{
    allocation_test_fail_nth(allocation_number);
}

HMC_API void avi_test_clear_allocation_failure() noexcept
{
    allocation_test_clear_failure();
}

HMC_API std::size_t avi_test_allocation_count() noexcept
{
    return allocation_test_count();
}
#endif

} // namespace honey::media
