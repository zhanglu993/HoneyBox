#include "honey_media_windows/png_codec.h"

#include "wic_helpers.h"

namespace hmw {

Result<std::vector<uint8_t>> EncodePng(const RgbaFrame& frame) {
  return internal::EncodePngWithWic(frame);
}

}  // namespace hmw
