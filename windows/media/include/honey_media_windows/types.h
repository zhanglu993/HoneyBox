#pragma once

#include <cstdint>
#include <vector>

namespace hmw {

struct RgbaFrame {
  uint32_t width;
  uint32_t height;
  int64_t pts_100ns;
  int64_t duration_100ns;
  std::vector<uint8_t> pixels;
};

struct CropRect {
  double x;
  double y;
  double width;
  double height;
};

enum class FitMode {
  kCover,
  kContain,
};

}  // namespace hmw
