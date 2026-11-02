#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstdint>
#include <filesystem>
#include <memory>

namespace hmw {

struct SourceInfo {
  uint32_t width;
  uint32_t height;
  int64_t duration_100ns;
  double nominal_fps;
  uint32_t clockwise_rotation;
  bool is_gif;
};

class FrameSource {
 public:
  virtual ~FrameSource() = default;
  virtual const SourceInfo& info() const = 0;
  virtual Result<bool> ReadNext(RgbaFrame* frame) = 0;
  virtual Outcome Seek(int64_t pts_100ns) = 0;
};

Result<std::unique_ptr<FrameSource>> OpenGifSource(
    const std::filesystem::path& path);

Result<std::unique_ptr<FrameSource>> OpenMediaSource(
    const std::filesystem::path& path);

}  // namespace hmw
