#include "rgba_nv12.h"

#include "test_support.h"

#include <array>
#include <cstdint>
#include <limits>

HMW_TEST(rgba_nv12_converts_known_2x2_rgba_layout) {
  const std::array<uint8_t, 16> rgba = {
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255};
  const auto nv12 = hmw::internal::RgbaToNv12(2, 2, rgba.data(), rgba.size());
  HMW_EXPECT(nv12.ok());
  HMW_EXPECT(nv12.value->size() == 6U);
  HMW_EXPECT(nv12.value->at(0) == 82U);
  HMW_EXPECT(nv12.value->at(1) == 144U);
  HMW_EXPECT(nv12.value->at(2) == 41U);
  HMW_EXPECT(nv12.value->at(3) == 235U);
}

HMW_TEST(rgba_nv12_interleaves_averaged_uv_after_y_plane) {
  const std::array<uint8_t, 16> rgba = {
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255};
  const auto nv12 = hmw::internal::RgbaToNv12(2, 2, rgba.data(), rgba.size());
  HMW_EXPECT(nv12.ok());
  HMW_EXPECT(nv12.value->at(4) == 128U);
  HMW_EXPECT(nv12.value->at(5) == 128U);
}

HMW_TEST(rgba_nv12_converts_neutral_gray_to_neutral_chroma) {
  const std::array<uint8_t, 16> rgba = {
      128, 128, 128, 1, 128, 128, 128, 2,
      128, 128, 128, 3, 128, 128, 128, 4};
  const auto nv12 = hmw::internal::RgbaToNv12(2, 2, rgba.data(), rgba.size());
  HMW_EXPECT(nv12.ok());
  HMW_EXPECT(nv12.value->at(0) == 126U);
  HMW_EXPECT(nv12.value->at(1) == 126U);
  HMW_EXPECT(nv12.value->at(2) == 126U);
  HMW_EXPECT(nv12.value->at(3) == 126U);
  HMW_EXPECT(nv12.value->at(4) == 128U);
  HMW_EXPECT(nv12.value->at(5) == 128U);
}

HMW_TEST(rgba_nv12_rejects_odd_dimensions) {
  const std::array<uint8_t, 24> rgba{};
  const auto nv12 = hmw::internal::RgbaToNv12(3, 2, rgba.data(), rgba.size());
  HMW_EXPECT(!nv12.ok());
  HMW_EXPECT(nv12.error.has_value());
  HMW_EXPECT(nv12.error->status == hmw::Status::kInvalidArgument);
}

HMW_TEST(rgba_nv12_rejects_short_input) {
  const std::array<uint8_t, 15> rgba{};
  const auto nv12 = hmw::internal::RgbaToNv12(2, 2, rgba.data(), rgba.size());
  HMW_EXPECT(!nv12.ok());
  HMW_EXPECT(nv12.error.has_value());
  HMW_EXPECT(nv12.error->status == hmw::Status::kInvalidArgument);
}

HMW_TEST(rgba_nv12_rejects_size_multiplication_overflow) {
  const uint8_t byte = 0;
  const auto nv12 = hmw::internal::RgbaToNv12(
      (std::numeric_limits<uint32_t>::max)() - 1U,
      (std::numeric_limits<uint32_t>::max)() - 1U, &byte,
      (std::numeric_limits<size_t>::max)());
  HMW_EXPECT(!nv12.ok());
  HMW_EXPECT(nv12.error.has_value());
  HMW_EXPECT(nv12.error->status == hmw::Status::kInvalidArgument);
}

HMW_TEST(rgba_nv12_uses_floor_rounding_for_negative_chroma_terms) {
  const std::array<uint8_t, 16> red = {
      255, 0, 0, 0, 255, 0, 0, 0,
      255, 0, 0, 0, 255, 0, 0, 0};
  const std::array<uint8_t, 16> green = {
      0, 255, 0, 0, 0, 255, 0, 0,
      0, 255, 0, 0, 0, 255, 0, 0};

  const auto red_nv12 =
      hmw::internal::RgbaToNv12(2, 2, red.data(), red.size());
  const auto green_nv12 =
      hmw::internal::RgbaToNv12(2, 2, green.data(), green.size());

  HMW_EXPECT(red_nv12.ok());
  HMW_EXPECT(red_nv12.value->at(4) == 90U);
  HMW_EXPECT(red_nv12.value->at(5) == 240U);
  HMW_EXPECT(green_nv12.ok());
  HMW_EXPECT(green_nv12.value->at(4) == 54U);
  HMW_EXPECT(green_nv12.value->at(5) == 34U);
}
