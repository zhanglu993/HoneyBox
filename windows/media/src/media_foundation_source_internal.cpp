#include "media_foundation_source_internal.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <optional>
#include <utility>
#include <vector>

namespace hmw::internal {
namespace {

constexpr int64_t kFixedOne = 1LL << 16;
constexpr int64_t kFallbackFrameDuration100ns = 333333;

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

int64_t FixedOffset(const MFOffset& offset) {
  return static_cast<int64_t>(offset.value) * kFixedOne + offset.fract;
}

bool IsSupportedRotation(uint32_t rotation) {
  return rotation == 0 || rotation == 90 || rotation == 180 ||
         rotation == 270;
}

bool IsLayoutInBounds(const VideoLayout& layout) {
  if (layout.coded_width == 0 || layout.coded_height == 0 ||
      layout.visible_width == 0 || layout.visible_height == 0 ||
      layout.visible_left_16_16 < 0 || layout.visible_top_16_16 < 0 ||
      !IsSupportedRotation(layout.clockwise_rotation)) {
    return false;
  }
  const int64_t coded_right =
      static_cast<int64_t>(layout.coded_width) * kFixedOne;
  const int64_t coded_bottom =
      static_cast<int64_t>(layout.coded_height) * kFixedOne;
  const int64_t visible_right =
      layout.visible_left_16_16 +
      static_cast<int64_t>(layout.visible_width) * kFixedOne;
  const int64_t visible_bottom =
      layout.visible_top_16_16 +
      static_cast<int64_t>(layout.visible_height) * kFixedOne;
  return visible_right <= coded_right && visible_bottom <= coded_bottom;
}

bool CheckedPixelByteCount(uint32_t width, uint32_t height,
                           size_t* byte_count) {
  if (width == 0 || height == 0 ||
      static_cast<size_t>(width) >
          std::numeric_limits<size_t>::max() / static_cast<size_t>(height)) {
    return false;
  }
  const size_t pixels = static_cast<size_t>(width) * height;
  if (pixels > std::numeric_limits<size_t>::max() / 4U) {
    return false;
  }
  *byte_count = pixels * 4U;
  return true;
}

void MapRotatedPixel(uint32_t output_x, uint32_t output_y,
                     const VideoLayout& layout, uint32_t* visible_x,
                     uint32_t* visible_y) {
  switch (layout.clockwise_rotation) {
    case 90:
      *visible_x = output_y;
      *visible_y = layout.visible_height - 1U - output_x;
      return;
    case 180:
      *visible_x = layout.visible_width - 1U - output_x;
      *visible_y = layout.visible_height - 1U - output_y;
      return;
    case 270:
      *visible_x = layout.visible_width - 1U - output_y;
      *visible_y = output_x;
      return;
    default:
      *visible_x = output_x;
      *visible_y = output_y;
      return;
  }
}

uint8_t BilinearChannel(const uint8_t* top_left, const uint8_t* top_right,
                        const uint8_t* bottom_left,
                        const uint8_t* bottom_right, uint32_t x_fraction,
                        uint32_t y_fraction, size_t channel) {
  const uint64_t inverse_x =
      static_cast<uint64_t>(kFixedOne) - x_fraction;
  const uint64_t inverse_y =
      static_cast<uint64_t>(kFixedOne) - y_fraction;
  const uint64_t top = static_cast<uint64_t>(top_left[channel]) * inverse_x +
                       static_cast<uint64_t>(top_right[channel]) * x_fraction;
  const uint64_t bottom =
      static_cast<uint64_t>(bottom_left[channel]) * inverse_x +
      static_cast<uint64_t>(bottom_right[channel]) * x_fraction;
  const uint64_t blended = top * inverse_y + bottom * y_fraction;
  return static_cast<uint8_t>((blended + (1ULL << 31)) >> 32);
}

}  // namespace

Result<VideoLayout> ParseVideoLayout(IMFMediaType* media_type,
                                     uint32_t clockwise_rotation) {
  if (media_type == nullptr || !IsSupportedRotation(clockwise_rotation)) {
    return Failure<VideoLayout>(Status::kDecodeFailed,
                                "video layout input is invalid");
  }
  uint32_t coded_width = 0;
  uint32_t coded_height = 0;
  HRESULT result = MFGetAttributeSize(media_type, MF_MT_FRAME_SIZE,
                                      &coded_width, &coded_height);
  if (FAILED(result) || coded_width == 0 || coded_height == 0) {
    return Failure<VideoLayout>(Status::kDecodeFailed,
                                "video coded rectangle is invalid");
  }
  VideoLayout layout{coded_width, coded_height, coded_width, coded_height,
                     0, 0, clockwise_rotation};
  const GUID* aperture_attributes[] = {
      &MF_MT_MINIMUM_DISPLAY_APERTURE,
      &MF_MT_GEOMETRIC_APERTURE,
      &MF_MT_PAN_SCAN_APERTURE,
  };
  for (const GUID* attribute : aperture_attributes) {
    MFVideoArea area{};
    UINT32 bytes = 0;
    result = media_type->GetBlob(*attribute,
                                 reinterpret_cast<UINT8*>(&area),
                                 sizeof(area), &bytes);
    if (result == MF_E_ATTRIBUTENOTFOUND) {
      continue;
    }
    if (FAILED(result) || bytes != sizeof(area) || area.Area.cx <= 0 ||
        area.Area.cy <= 0) {
      return Failure<VideoLayout>(Status::kDecodeFailed,
                                  "video display aperture is invalid");
    }
    layout.visible_width = static_cast<uint32_t>(area.Area.cx);
    layout.visible_height = static_cast<uint32_t>(area.Area.cy);
    layout.visible_left_16_16 = FixedOffset(area.OffsetX);
    layout.visible_top_16_16 = FixedOffset(area.OffsetY);
    break;
  }
  if (!IsLayoutInBounds(layout)) {
    return Failure<VideoLayout>(Status::kDecodeFailed,
                                "video display aperture exceeds coded bounds");
  }
  return Result<VideoLayout>{layout, std::nullopt};
}

Result<RgbaFrame> ConvertBgraFrame(const uint8_t* scanline_zero,
                                   ptrdiff_t pitch,
                                   const VideoLayout& layout,
                                   int64_t pts_100ns,
                                   int64_t duration_100ns) {
  const uint64_t pitch_magnitude =
      pitch < 0 ? static_cast<uint64_t>(-static_cast<int64_t>(pitch))
                : static_cast<uint64_t>(pitch);
  if (scanline_zero == nullptr || !IsLayoutInBounds(layout) || pitch == 0 ||
      pitch_magnitude < static_cast<uint64_t>(layout.coded_width) * 4U ||
      duration_100ns <= 0) {
    return Failure<RgbaFrame>(Status::kDecodeFailed,
                              "video BGRA frame layout is invalid");
  }
  const bool swaps_dimensions = layout.clockwise_rotation == 90 ||
                                layout.clockwise_rotation == 270;
  const uint32_t output_width =
      swaps_dimensions ? layout.visible_height : layout.visible_width;
  const uint32_t output_height =
      swaps_dimensions ? layout.visible_width : layout.visible_height;
  size_t byte_count = 0;
  if (!CheckedPixelByteCount(output_width, output_height, &byte_count)) {
    return Failure<RgbaFrame>(Status::kDecodeFailed,
                              "video output dimensions are too large");
  }
  try {
    RgbaFrame output{output_width, output_height, pts_100ns, duration_100ns,
                     std::vector<uint8_t>(byte_count)};
    for (uint32_t y = 0; y < output_height; ++y) {
      for (uint32_t x = 0; x < output_width; ++x) {
        uint32_t visible_x = 0;
        uint32_t visible_y = 0;
        MapRotatedPixel(x, y, layout, &visible_x, &visible_y);
        const int64_t fixed_x =
            layout.visible_left_16_16 +
            static_cast<int64_t>(visible_x) * kFixedOne;
        const int64_t fixed_y =
            layout.visible_top_16_16 +
            static_cast<int64_t>(visible_y) * kFixedOne;
        const uint32_t x0 = static_cast<uint32_t>(fixed_x >> 16);
        const uint32_t y0 = static_cast<uint32_t>(fixed_y >> 16);
        const uint32_t x_fraction =
            static_cast<uint32_t>(fixed_x & (kFixedOne - 1));
        const uint32_t y_fraction =
            static_cast<uint32_t>(fixed_y & (kFixedOne - 1));
        const uint32_t x1 = std::min(x0 + 1U, layout.coded_width - 1U);
        const uint32_t y1 = std::min(y0 + 1U, layout.coded_height - 1U);
        const uint8_t* row0 =
            scanline_zero + static_cast<ptrdiff_t>(y0) * pitch;
        const uint8_t* row1 =
            scanline_zero + static_cast<ptrdiff_t>(y1) * pitch;
        const uint8_t* top_left = row0 + static_cast<size_t>(x0) * 4U;
        const uint8_t* top_right = row0 + static_cast<size_t>(x1) * 4U;
        const uint8_t* bottom_left = row1 + static_cast<size_t>(x0) * 4U;
        const uint8_t* bottom_right = row1 + static_cast<size_t>(x1) * 4U;
        const size_t destination =
            (static_cast<size_t>(y) * output_width + x) * 4U;
        output.pixels[destination] =
            BilinearChannel(top_left, top_right, bottom_left, bottom_right,
                            x_fraction, y_fraction, 2);
        output.pixels[destination + 1] =
            BilinearChannel(top_left, top_right, bottom_left, bottom_right,
                            x_fraction, y_fraction, 1);
        output.pixels[destination + 2] =
            BilinearChannel(top_left, top_right, bottom_left, bottom_right,
                            x_fraction, y_fraction, 0);
        output.pixels[destination + 3] = 255;
      }
    }
    return Result<RgbaFrame>{std::move(output), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<RgbaFrame>(Status::kIoError,
                              "video frame allocation failed");
  }
}

double ReadNominalFrameRate(IMFMediaType* media_type) {
  uint32_t numerator = 0;
  uint32_t denominator = 0;
  if (media_type == nullptr ||
      FAILED(MFGetAttributeRatio(media_type, MF_MT_FRAME_RATE, &numerator,
                                 &denominator)) ||
      numerator == 0 || denominator == 0) {
    return 0.0;
  }
  return static_cast<double>(numerator) / denominator;
}

int64_t NormalizeSampleDuration(std::optional<int64_t> duration_100ns) {
  return duration_100ns.has_value() && *duration_100ns > 0
             ? *duration_100ns
             : kFallbackFrameDuration100ns;
}

Result<int64_t> MediaTimeline::AcceptTimestamp(int64_t raw_pts_100ns) {
  if (previous_raw_pts_100ns_.has_value() &&
      raw_pts_100ns < *previous_raw_pts_100ns_) {
    return Failure<int64_t>(Status::kDecodeFailed,
                            "video timestamp moved backwards");
  }
  if (!rebase_origin_100ns_.has_value()) {
    rebase_origin_100ns_ = std::min<int64_t>(raw_pts_100ns, 0);
  }
  if (*rebase_origin_100ns_ < 0 &&
      raw_pts_100ns >
          std::numeric_limits<int64_t>::max() + *rebase_origin_100ns_) {
    return Failure<int64_t>(Status::kDecodeFailed,
                            "video rebased timestamp overflows");
  }
  previous_raw_pts_100ns_ = raw_pts_100ns;
  seek_floor_raw_100ns_.reset();
  return Result<int64_t>{raw_pts_100ns - *rebase_origin_100ns_,
                         std::nullopt};
}

Result<int64_t> MediaTimeline::RawSeekTarget(
    int64_t public_pts_100ns) const {
  if (public_pts_100ns < 0) {
    return Failure<int64_t>(Status::kInvalidArgument,
                            "video seek timestamp must not be negative");
  }
  const int64_t origin = rebase_origin_100ns_.value_or(0);
  if (origin > 0) {
    return Failure<int64_t>(Status::kInvalidArgument,
                            "video seek timestamp is outside the timeline");
  }
  return Result<int64_t>{public_pts_100ns + origin, std::nullopt};
}

void MediaTimeline::BeginSeek(int64_t raw_target_100ns) {
  previous_raw_pts_100ns_.reset();
  seek_floor_raw_100ns_ = raw_target_100ns;
}

bool MediaTimeline::IsPreroll(int64_t raw_pts_100ns) const {
  return seek_floor_raw_100ns_.has_value() &&
         raw_pts_100ns < *seek_floor_raw_100ns_;
}

Result<bool> MediaFoundationReadState::BeforeRead() const {
  if (terminal_error_.has_value()) {
    return Result<bool>{std::nullopt, terminal_error_};
  }
  return Result<bool>{!end_of_stream_, std::nullopt};
}

Outcome MediaFoundationReadState::BeforeSeek() const {
  return Outcome{terminal_error_};
}

Result<bool> MediaFoundationReadState::ObserveFlags(uint32_t flags) {
  if ((flags & static_cast<uint32_t>(MF_SOURCE_READERF_ERROR)) != 0) {
    Fail(Error{Status::kDecodeFailed,
               "Media Foundation signaled a terminal source error"});
    return Result<bool>{std::nullopt, terminal_error_};
  }
  if ((flags & static_cast<uint32_t>(MF_SOURCE_READERF_ENDOFSTREAM)) != 0) {
    end_of_stream_ = true;
    return Result<bool>{false, std::nullopt};
  }
  return Result<bool>{true, std::nullopt};
}

void MediaFoundationReadState::Fail(Error error) {
  if (!terminal_error_.has_value()) {
    terminal_error_ = std::move(error);
  }
}

void MediaFoundationReadState::ResetAfterSeek() { end_of_stream_ = false; }

}  // namespace hmw::internal
