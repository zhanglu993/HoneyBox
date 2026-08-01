#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <optional>

namespace hmw {

struct TransformRequest {
  uint32_t output_width;
  uint32_t output_height;
  FitMode fit;
  std::optional<CropRect> crop;
  uint32_t background_argb;
  uint32_t clockwise_rotation;
};

Result<RgbaFrame> TransformRgba(const RgbaFrame& source,
                                const TransformRequest& request);

}  // namespace hmw
