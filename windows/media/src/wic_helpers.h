#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstdint>
#include <filesystem>
#include <vector>

namespace hmw::internal {

struct GifFrameData {
  uint32_t left;
  uint32_t top;
  uint32_t width;
  uint32_t height;
  uint32_t disposal;
  int64_t duration_100ns;
  std::vector<uint8_t> pixels;
};

struct DecodedGif {
  uint32_t width;
  uint32_t height;
  std::vector<GifFrameData> frames;
};

Result<std::vector<uint8_t>> EncodePngWithWic(const RgbaFrame& frame);
Result<DecodedGif> DecodeGifWithWic(const std::filesystem::path& path);

}  // namespace hmw::internal
