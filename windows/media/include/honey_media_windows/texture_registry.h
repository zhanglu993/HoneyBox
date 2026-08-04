#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

namespace hmw {

struct PixelBufferView {
  std::shared_ptr<const std::vector<uint8_t>> owner;
  const uint8_t* rgba;
  size_t byte_count;
  uint32_t width;
  uint32_t height;
};

using PixelBufferProvider = std::function<PixelBufferView()>;

class TextureRegistry {
 public:
  virtual ~TextureRegistry() = default;

  virtual int64_t RegisterPixelBufferTexture(
      PixelBufferProvider provider) = 0;
  virtual bool MarkFrameAvailable(int64_t texture_id) = 0;
  virtual bool UnregisterTexture(int64_t texture_id) = 0;
};

}  // namespace hmw
