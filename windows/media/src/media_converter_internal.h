#pragma once

#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/media_source.h"

#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

namespace hmw::internal {

class ForwardFrameSampler {
 public:
  explicit ForwardFrameSampler(FrameSource* source);

  Result<std::reference_wrapper<const RgbaFrame>> Sample(
      int64_t target_pts_100ns, const IsCancelled& cancelled);

 private:
  FrameSource* source_;
  std::optional<RgbaFrame> current_;
  std::optional<RgbaFrame> pending_;
  std::optional<int64_t> last_target_pts_100ns_;
  bool eof_ = false;
};

using PngEncoder =
    std::function<Result<std::vector<uint8_t>>(const RgbaFrame&)>;

class ScopedPngEncoderOverride {
 public:
  explicit ScopedPngEncoderOverride(PngEncoder encoder);
  ~ScopedPngEncoderOverride();

  ScopedPngEncoderOverride(const ScopedPngEncoderOverride&) = delete;
  ScopedPngEncoderOverride& operator=(const ScopedPngEncoderOverride&) = delete;
};

}  // namespace hmw::internal
