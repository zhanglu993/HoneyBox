#include "media_foundation_camera_internal.h"

#include "test_support.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {

using hcw::internal::BgraBufferView;
using hcw::internal::CaptureMode;

HMW_TEST(camera_mode_selects_smallest_covering_candidate) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 30, 1, 0},
      {1280, 720, 15, 1, 1},
      {320, 240, 30, 1, 2},
  };
  const auto selected = hcw::internal::SelectCaptureMode(
      candidates, hcw::CameraPreviewConfig{368, 368, 15});
  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->width == 640);
  HMW_EXPECT(selected->height == 480);
  HMW_EXPECT(selected->fps_numerator == 30);
  HMW_EXPECT(selected->fps_denominator == 1);
  HMW_EXPECT(selected->native_type_index == 0);
}

HMW_TEST(camera_mode_uses_largest_candidate_when_none_cover) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 60, 1, 4},
      {1280, 720, 15, 1, 7},
      {320, 240, 120, 1, 9},
  };
  const auto selected = hcw::internal::SelectCaptureMode(
      candidates, hcw::CameraPreviewConfig{1920, 1080, 30});
  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->width == 1280);
  HMW_EXPECT(selected->height == 720);
  HMW_EXPECT(selected->native_type_index == 7);
}

HMW_TEST(camera_mode_negotiation_tries_next_ranked_candidate_after_failure) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 30, 1, 3},
      {640, 480, 30, 1, 5},
      {1280, 720, 15, 1, 8},
  };
  std::vector<uint32_t> attempts;

  const auto selected = hcw::internal::SelectNegotiatedCaptureMode(
      candidates, hcw::CameraPreviewConfig{368, 368, 15},
      [&](const CaptureMode& candidate) {
        attempts.push_back(candidate.native_type_index);
        return candidate.native_type_index == 5;
      });

  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->native_type_index == 5);
  HMW_EXPECT(attempts == std::vector<uint32_t>({3, 5}));
}

HMW_TEST(camera_mode_hresult_detail_is_hexadecimal_and_bounded) {
  const std::string message = hcw::internal::FormatHresultDetail(
      std::string(200, 'x'), 0x80004005U);

  HMW_EXPECT(message.size() < 160);
  HMW_EXPECT(message.find("HRESULT 0x80004005") != std::string::npos);
}

HMW_TEST(camera_bgra_copies_positive_padded_stride_to_tight_rows) {
  const std::vector<uint8_t> input{
      1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
      9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
  };
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), input.data(), 12}, 2, 2);
  HMW_EXPECT(copied.ok());
  HMW_EXPECT(*copied.value == std::vector<uint8_t>({
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  }));
}

HMW_TEST(camera_bgra_copies_negative_stride_to_top_down_tight_rows) {
  const std::vector<uint8_t> input{
      9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
      1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
  };
  const uint8_t* scanline_zero = input.data() + 12;
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), scanline_zero, -12}, 2, 2);
  HMW_EXPECT(copied.ok());
  HMW_EXPECT(*copied.value == std::vector<uint8_t>({
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  }));
}

HMW_TEST(camera_bgra_rejects_short_source_buffer) {
  const std::vector<uint8_t> input(19, 0);
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), input.data(), 12}, 2, 2);
  HMW_EXPECT(!copied.ok());
  HMW_EXPECT(copied.error.has_value());
  HMW_EXPECT(copied.error->status == hmw::Status::kIoError);
}

HMW_TEST(camera_bgra_rejects_negative_stride_before_buffer_start) {
  const std::vector<uint8_t> input(24, 0);
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data() + 1, input.size() - 1,
                     input.data() + 12, -12},
      2, 2);

  HMW_EXPECT(!copied.ok());
  HMW_EXPECT(copied.error.has_value());
  HMW_EXPECT(copied.error->status == hmw::Status::kIoError);
}

HMW_TEST(camera_rgba_swaps_red_and_blue_when_decoding_bgra) {
  const std::vector<uint8_t> bgra{
      1, 2, 3, 4,
      5, 6, 7, 8,
  };
  const auto rgba = hcw::internal::BgraToRgba(2, 1, 123, bgra);
  HMW_EXPECT(rgba.ok());
  HMW_EXPECT(rgba.value->width == 2);
  HMW_EXPECT(rgba.value->height == 1);
  HMW_EXPECT(rgba.value->pts_100ns == 123);
  HMW_EXPECT(rgba.value->pixels == std::vector<uint8_t>({
      3, 2, 1, 255,
      7, 6, 5, 255,
  }));
}

HMW_TEST(camera_rgba_swaps_red_and_blue_when_encoding_bgra) {
  const hmw::RgbaFrame rgba{
      2, 1, 456, 0,
      {3, 2, 1, 4, 7, 6, 5, 8},
  };
  const auto bgra = hcw::internal::RgbaToBgra(rgba);
  HMW_EXPECT(bgra.ok());
  HMW_EXPECT(*bgra.value == std::vector<uint8_t>({
      1, 2, 3, 255,
      5, 6, 7, 255,
  }));
}

}  // namespace
