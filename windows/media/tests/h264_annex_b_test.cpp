#include "h264_annex_b.h"

#include "test_support.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace {

const std::vector<uint8_t> kAvccSpsPps = {
    1, 66, 0, 30, 0xff, 0xe1, 0, 4, 0x67, 0x42, 0x00, 0x1e,
    1, 0, 4, 0x68, 0xce, 0x06, 0xe2};

const std::vector<uint8_t> kLengthPrefixedIdr = {
    0, 0, 0, 3, 0x65, 0x88, 0x84};

size_t CountNalType(const std::vector<uint8_t>& bytes, uint8_t type) {
  size_t count = 0;
  for (size_t i = 0; i + 4U < bytes.size(); ++i) {
    if (bytes[i] == 0U && bytes[i + 1U] == 0U && bytes[i + 2U] == 0U &&
        bytes[i + 3U] == 1U && (bytes[i + 4U] & 0x1fU) == type) {
      ++count;
    }
  }
  return count;
}

}  // namespace

HMW_TEST(h264_annex_b_idr_gets_cached_sps_pps_once) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  HMW_EXPECT(normalizer.SetSequenceHeader(kAvccSpsPps).ok());
  const auto out = normalizer.Normalize(kLengthPrefixedIdr, true);
  HMW_EXPECT(out.ok());
  HMW_EXPECT(out.value->key);
  HMW_EXPECT(CountNalType(out.value->bytes, 7) == 1U);
  HMW_EXPECT(CountNalType(out.value->bytes, 8) == 1U);
  HMW_EXPECT(CountNalType(out.value->bytes, 5) == 1U);
}

HMW_TEST(h264_annex_b_normalizes_three_and_four_byte_start_codes) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  const std::vector<uint8_t> access_unit = {
      0, 0, 1, 0x41, 0x9a,
      0, 0, 0, 1, 0x06, 0x05};
  const auto out = normalizer.Normalize(access_unit, false);
  HMW_EXPECT(out.ok());
  HMW_EXPECT(!out.value->key);
  HMW_EXPECT(out.value->bytes == std::vector<uint8_t>{
      0, 0, 0, 1, 0x41, 0x9a,
      0, 0, 0, 1, 0x06, 0x05});
}

HMW_TEST(h264_annex_b_converts_avcc_length_prefixed_sample) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  const std::vector<uint8_t> sample = {
      0, 0, 0, 2, 0x41, 0x9a,
      0, 0, 0, 2, 0x06, 0x05};
  const auto out = normalizer.Normalize(sample, false);
  HMW_EXPECT(out.ok());
  HMW_EXPECT(out.value->bytes == std::vector<uint8_t>{
      0, 0, 0, 1, 0x41, 0x9a,
      0, 0, 0, 1, 0x06, 0x05});
}

HMW_TEST(h264_annex_b_preserves_complete_idr_without_parameter_duplication) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  HMW_EXPECT(normalizer.SetSequenceHeader(kAvccSpsPps).ok());
  const std::vector<uint8_t> complete_idr = {
      0, 0, 0, 4, 0x67, 0x42, 0x00, 0x1e,
      0, 0, 0, 4, 0x68, 0xce, 0x06, 0xe2,
      0, 0, 0, 3, 0x65, 0x88, 0x84};
  const auto out = normalizer.Normalize(complete_idr, false);
  HMW_EXPECT(out.ok());
  HMW_EXPECT(out.value->key);
  HMW_EXPECT(CountNalType(out.value->bytes, 7) == 1U);
  HMW_EXPECT(CountNalType(out.value->bytes, 8) == 1U);
  HMW_EXPECT(CountNalType(out.value->bytes, 5) == 1U);
}

HMW_TEST(h264_annex_b_marks_non_idr_p_frame_as_not_key) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  const std::vector<uint8_t> p_frame = {0, 0, 0, 2, 0x41, 0x9a};
  const auto out = normalizer.Normalize(p_frame, false);
  HMW_EXPECT(out.ok());
  HMW_EXPECT(!out.value->key);
}

HMW_TEST(h264_annex_b_rejects_truncated_nal_length) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  const std::vector<uint8_t> truncated = {0, 0, 0, 3, 0x65, 0x88};
  const auto out = normalizer.Normalize(truncated, false);
  HMW_EXPECT(!out.ok());
  HMW_EXPECT(out.error.has_value());
  HMW_EXPECT(out.error->status == hmw::Status::kInvalidArgument);
}

HMW_TEST(h264_annex_b_rejects_malformed_sequence_header) {
  hmw::internal::H264AnnexBNormalizer normalizer;
  const std::vector<uint8_t> malformed = {
      1, 66, 0, 30, 0xff, 0xe1, 0, 4, 0x67, 0x42, 0x00};
  const auto outcome = normalizer.SetSequenceHeader(malformed);
  HMW_EXPECT(!outcome.ok());
  HMW_EXPECT(outcome.error.has_value());
  HMW_EXPECT(outcome.error->status == hmw::Status::kInvalidArgument);
}
