#pragma once

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace hcw::internal {

struct CaptureMode {
  uint32_t width;
  uint32_t height;
  uint32_t fps_numerator;
  uint32_t fps_denominator;
  uint32_t native_type_index;
};

std::optional<CaptureMode> SelectCaptureMode(
    const std::vector<CaptureMode>& candidates,
    const CameraPreviewConfig& requested);

// scanline_zero always addresses the logical top row. A negative stride means
// subsequent logical rows live at lower addresses in the backing buffer.
hmw::Result<std::vector<uint8_t>> CopyBgraRows(
    const uint8_t* scanline_zero, size_t buffer_size, uint32_t width,
    uint32_t height, ptrdiff_t stride);

hmw::Result<hmw::RgbaFrame> BgraToRgba(
    uint32_t width, uint32_t height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra);

hmw::Result<std::vector<uint8_t>> RgbaToBgra(
    const hmw::RgbaFrame& rgba);

}  // namespace hcw::internal
