#pragma once

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace hcw::internal {

struct CaptureMode {
  uint32_t width;
  uint32_t height;
  uint32_t fps_numerator;
  uint32_t fps_denominator;
  uint32_t native_type_index;
};

struct BgraBufferView {
  const uint8_t* buffer_start;
  size_t buffer_length;
  const uint8_t* scanline_zero;
  ptrdiff_t pitch;
};

std::optional<CaptureMode> SelectCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested);

using CaptureModeNegotiator = std::function<bool(const CaptureMode&)>;
std::optional<CaptureMode> SelectNegotiatedCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested,
    const CaptureModeNegotiator& negotiate);

std::string FormatHresultDetail(std::string_view context, uint32_t result);

// scanline_zero always addresses the logical top row. A negative stride means
// subsequent logical rows live at lower addresses in the backing buffer.
hmw::Result<std::vector<uint8_t>> CopyBgraRows(
    const BgraBufferView& view, uint32_t width, uint32_t height);

hmw::Result<hmw::RgbaFrame> BgraToRgba(
    uint32_t width, uint32_t height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra);

hmw::Result<std::vector<uint8_t>> RgbaToBgra(
    const hmw::RgbaFrame& rgba);

}  // namespace hcw::internal
