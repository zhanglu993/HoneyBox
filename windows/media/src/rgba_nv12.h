#pragma once

#include "honey_media_windows/status.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace hmw::internal {

Result<std::vector<uint8_t>> RgbaToNv12(uint32_t width, uint32_t height,
                                        const uint8_t* rgba,
                                        size_t rgba_size);

}  // namespace hmw::internal
