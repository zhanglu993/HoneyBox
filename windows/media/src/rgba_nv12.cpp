#include "rgba_nv12.h"

#include <limits>
#include <optional>
#include <utility>

namespace hmw::internal {
namespace {

Result<std::vector<uint8_t>> InvalidArgument(const char* message) {
  return {std::nullopt, Error{Status::kInvalidArgument, message}};
}

bool Multiply(size_t left, size_t right, size_t* result) {
  if (left != 0U && right > (std::numeric_limits<size_t>::max)() / left) {
    return false;
  }
  *result = left * right;
  return true;
}

bool Add(size_t left, size_t right, size_t* result) {
  if (right > (std::numeric_limits<size_t>::max)() - left) {
    return false;
  }
  *result = left + right;
  return true;
}

uint8_t Clamp(int value) {
  if (value < 0) {
    return 0U;
  }
  if (value > 255) {
    return 255U;
  }
  return static_cast<uint8_t>(value);
}

uint8_t Luma(uint8_t red, uint8_t green, uint8_t blue) {
  return Clamp(((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16);
}

int FloorDivideBy256(int value) {
  const int quotient = value / 256;
  const int remainder = value % 256;
  return remainder < 0 ? quotient - 1 : quotient;
}

uint8_t ChromaU(uint8_t red, uint8_t green, uint8_t blue) {
  return Clamp(FloorDivideBy256(-38 * red - 74 * green + 112 * blue + 128) + 128);
}

uint8_t ChromaV(uint8_t red, uint8_t green, uint8_t blue) {
  return Clamp(FloorDivideBy256(112 * red - 94 * green - 18 * blue + 128) + 128);
}

}  // namespace

Result<std::vector<uint8_t>> RgbaToNv12(uint32_t width, uint32_t height,
                                        const uint8_t* rgba,
                                        size_t rgba_size) {
  if (width == 0U || height == 0U || (width & 1U) != 0U ||
      (height & 1U) != 0U) {
    return InvalidArgument("NV12 requires non-zero even dimensions.");
  }
  if (rgba == nullptr) {
    return InvalidArgument("RGBA input is null.");
  }

  size_t pixel_count = 0U;
  size_t rgba_byte_count = 0U;
  size_t nv12_byte_count = 0U;
  if (!Multiply(static_cast<size_t>(width), static_cast<size_t>(height),
                &pixel_count) ||
      !Multiply(pixel_count, 4U, &rgba_byte_count) ||
      !Add(pixel_count, pixel_count / 2U, &nv12_byte_count)) {
    return InvalidArgument("RGBA or NV12 size overflows size_t.");
  }
  if (rgba_size != rgba_byte_count) {
    return InvalidArgument("RGBA byte count does not match dimensions.");
  }

  std::vector<uint8_t> nv12(nv12_byte_count);
  for (size_t pixel = 0U; pixel < pixel_count; ++pixel) {
    const size_t source = pixel * 4U;
    nv12[pixel] = Luma(rgba[source], rgba[source + 1U], rgba[source + 2U]);
  }

  const size_t uv_offset = pixel_count;
  for (size_t y = 0U; y < height; y += 2U) {
    for (size_t x = 0U; x < width; x += 2U) {
      int u_sum = 0;
      int v_sum = 0;
      for (size_t row = 0U; row < 2U; ++row) {
        for (size_t column = 0U; column < 2U; ++column) {
          const size_t pixel = (y + row) * width + x + column;
          const size_t source = pixel * 4U;
          u_sum += ChromaU(rgba[source], rgba[source + 1U], rgba[source + 2U]);
          v_sum += ChromaV(rgba[source], rgba[source + 1U], rgba[source + 2U]);
        }
      }
      const size_t uv = uv_offset + (y / 2U) * width + x;
      nv12[uv] = Clamp((u_sum + 2) / 4);
      nv12[uv + 1U] = Clamp((v_sum + 2) / 4);
    }
  }
  return {std::move(nv12), std::nullopt};
}

}  // namespace hmw::internal
