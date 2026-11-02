#pragma once

#include <cstdint>

namespace hmw::internal {

struct SamplingBounds {
  double minimum;
  double maximum;
};

SamplingBounds SamplingBoundsForCrop(double crop_start, double crop_extent,
                                     uint32_t source_length);

}  // namespace hmw::internal
