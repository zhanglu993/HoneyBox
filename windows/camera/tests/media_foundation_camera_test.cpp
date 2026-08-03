#include "media_foundation_camera_internal.h"

#include "test_support.h"

#include <cstdint>
#include <vector>

namespace {

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

HMW_TEST(camera_bgra_copies_positive_padded_stride_to_tight_rows) {
  const std::vector<uint8_t> input{
      1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
      9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
  };
  const auto copied = hcw::internal::CopyBgraRows(
      input.data(), input.size(), 2, 2, 12);
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
      scanline_zero, input.size(), 2, 2, -12);
  HMW_EXPECT(copied.ok());
  HMW_EXPECT(*copied.value == std::vector<uint8_t>({
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  }));
}

HMW_TEST(camera_bgra_rejects_short_source_buffer) {
  const std::vector<uint8_t> input(19, 0);
  const auto copied = hcw::internal::CopyBgraRows(
      input.data(), input.size(), 2, 2, 12);
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
      3, 2, 1, 4,
      7, 6, 5, 8,
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
      1, 2, 3, 4,
      5, 6, 7, 8,
  }));
}

}  // namespace
