#include "honey_media_windows/rgba_transform.h"

#include "test_support.h"

#include <optional>
#include <utility>
#include <vector>

namespace {

hmw::RgbaFrame Frame(uint32_t width, uint32_t height,
                     std::vector<uint8_t> pixels) {
  return hmw::RgbaFrame{width, height, 1234, 5678, std::move(pixels)};
}

hmw::TransformRequest Request(uint32_t width = 4, uint32_t height = 4) {
  return hmw::TransformRequest{width, height, hmw::FitMode::kCover,
                               std::nullopt, 0xff000000, 0};
}

}  // namespace

HMW_TEST(transform_rejects_empty_or_non_four_aligned_output) {
  const hmw::RgbaFrame source = Frame(2, 2, {
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  });

  hmw::TransformRequest empty = Request(0, 4);
  const hmw::Result<hmw::RgbaFrame> empty_result =
      hmw::TransformRgba(source, empty);
  HMW_EXPECT(!empty_result.ok());
  HMW_EXPECT(empty_result.error.has_value());
  HMW_EXPECT(empty_result.error->status == hmw::Status::kInvalidArgument);

  hmw::TransformRequest non_aligned = Request(6, 4);
  const hmw::Result<hmw::RgbaFrame> non_aligned_result =
      hmw::TransformRgba(source, non_aligned);
  HMW_EXPECT(!non_aligned_result.ok());
  HMW_EXPECT(non_aligned_result.error.has_value());
  HMW_EXPECT(non_aligned_result.error->status == hmw::Status::kInvalidArgument);
}

HMW_TEST(transform_explicit_crop_overrides_cover) {
  const hmw::RgbaFrame source = Frame(2, 2, {
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  });
  hmw::TransformRequest request = Request();
  request.crop = hmw::CropRect{0.0, 0.0, 0.5, 1.0};

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, request);

  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value->pixels == std::vector<uint8_t>{
      1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4,
      3, 4, 5, 6, 3, 4, 5, 6, 3, 4, 5, 6, 3, 4, 5, 6,
      7, 8, 9, 10, 7, 8, 9, 10, 7, 8, 9, 10, 7, 8, 9, 10,
      9, 10, 11, 12, 9, 10, 11, 12, 9, 10, 11, 12, 9, 10, 11, 12,
  });
}

HMW_TEST(transform_cover_center_crops_wide_source) {
  const hmw::RgbaFrame source = Frame(4, 2, {
      10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255, 40, 0, 0, 255,
      10, 1, 0, 255, 20, 1, 0, 255, 30, 1, 0, 255, 40, 1, 0, 255,
  });

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, Request());

  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value->pixels[0] == 20);
  HMW_EXPECT(result.value->pixels[4] == 23);
  HMW_EXPECT(result.value->pixels[8] == 28);
  HMW_EXPECT(result.value->pixels[12] == 30);
  HMW_EXPECT(result.value->pixels[48] == 20);
  HMW_EXPECT(result.value->pixels[49] == 1);
}

HMW_TEST(transform_contain_uses_requested_argb_background) {
  const hmw::RgbaFrame source = Frame(2, 1, {
      10, 20, 30, 255, 110, 120, 130, 255,
  });
  hmw::TransformRequest request = Request();
  request.fit = hmw::FitMode::kContain;
  request.background_argb = 0xaabbccdd;

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, request);

  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value->pixels == std::vector<uint8_t>{
      187, 204, 221, 170, 187, 204, 221, 170, 187, 204, 221, 170, 187, 204, 221, 170,
      10, 20, 30, 255, 35, 45, 55, 255, 85, 95, 105, 255, 110, 120, 130, 255,
      10, 20, 30, 255, 35, 45, 55, 255, 85, 95, 105, 255, 110, 120, 130, 255,
      187, 204, 221, 170, 187, 204, 221, 170, 187, 204, 221, 170, 187, 204, 221, 170,
  });
}

HMW_TEST(transform_rotates_before_crop_coordinates) {
  const hmw::RgbaFrame source = Frame(4, 4, {
      10, 0, 0, 255, 11, 0, 0, 255, 12, 0, 0, 255, 13, 0, 0, 255,
      30, 0, 0, 255, 31, 0, 0, 255, 32, 0, 0, 255, 33, 0, 0, 255,
      50, 0, 0, 255, 51, 0, 0, 255, 52, 0, 0, 255, 53, 0, 0, 255,
      70, 0, 0, 255, 71, 0, 0, 255, 72, 0, 0, 255, 73, 0, 0, 255,
  });
  hmw::TransformRequest request = Request();
  request.clockwise_rotation = 90;
  request.crop = hmw::CropRect{0.0, 0.0, 0.5, 1.0};

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, request);

  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value->pixels[0] == 70);
  HMW_EXPECT(result.value->pixels[4] == 65);
  HMW_EXPECT(result.value->pixels[8] == 55);
  HMW_EXPECT(result.value->pixels[12] == 50);
  HMW_EXPECT(result.value->pixels[48] == 73);
}

HMW_TEST(transform_bilinear_result_is_deterministic) {
  const hmw::RgbaFrame source = Frame(2, 2, {
      0, 0, 0, 255, 100, 0, 0, 255,
      200, 0, 0, 255, 255, 0, 0, 255,
  });

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, Request());

  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value->width == 4);
  HMW_EXPECT(result.value->height == 4);
  HMW_EXPECT(result.value->pts_100ns == 1234);
  HMW_EXPECT(result.value->duration_100ns == 5678);
  HMW_EXPECT(result.value->pixels == std::vector<uint8_t>{
      0, 0, 0, 255, 25, 0, 0, 255, 75, 0, 0, 255, 100, 0, 0, 255,
      50, 0, 0, 255, 72, 0, 0, 255, 117, 0, 0, 255, 139, 0, 0, 255,
      150, 0, 0, 255, 167, 0, 0, 255, 200, 0, 0, 255, 216, 0, 0, 255,
      200, 0, 0, 255, 214, 0, 0, 255, 241, 0, 0, 255, 255, 0, 0, 255,
  });
}

HMW_TEST(transform_never_changes_source_on_failure) {
  hmw::RgbaFrame source = Frame(2, 2, {
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  });
  const hmw::RgbaFrame original = source;
  hmw::TransformRequest request = Request();
  request.clockwise_rotation = 45;

  const hmw::Result<hmw::RgbaFrame> result =
      hmw::TransformRgba(source, request);

  HMW_EXPECT(!result.ok());
  HMW_EXPECT(result.error.has_value());
  HMW_EXPECT(result.error->status == hmw::Status::kInvalidArgument);
  HMW_EXPECT(source.width == original.width);
  HMW_EXPECT(source.height == original.height);
  HMW_EXPECT(source.pts_100ns == original.pts_100ns);
  HMW_EXPECT(source.duration_100ns == original.duration_100ns);
  HMW_EXPECT(source.pixels == original.pixels);
}
