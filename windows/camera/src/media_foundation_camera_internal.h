#pragma once

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
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

class AsyncFlushBarrier final {
 public:
  using Generation = uint64_t;

  Generation Arm() noexcept;
  void Complete() noexcept;
  void Cancel(Generation generation) noexcept;
  void Wait(Generation generation) noexcept;

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  Generation next_generation_ = 0;
  Generation active_generation_ = 0;
  Generation completed_generation_ = 0;
  Generation cancelled_generation_ = 0;
};

// scanline_zero always addresses the logical top row. A negative stride means
// subsequent logical rows live at lower addresses in the backing buffer.
hmw::Result<std::vector<uint8_t>> CopyBgraRows(
    const BgraBufferView& view, uint32_t width, uint32_t height);

hmw::Result<hmw::RgbaFrame> BgraToRgba(
    uint32_t width, uint32_t height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra);

hmw::Result<CameraFrame> PrepareCameraTextureFrame(
    uint32_t source_width, uint32_t source_height, int64_t pts_100ns,
    const std::vector<uint8_t>& bgra,
    const CameraPreviewConfig& requested);

}  // namespace hcw::internal
