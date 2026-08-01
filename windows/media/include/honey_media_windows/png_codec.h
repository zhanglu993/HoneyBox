#pragma once

#include "honey_media_windows/status.h"
#include "honey_media_windows/types.h"

#include <cstdint>
#include <vector>

namespace hmw {

Result<std::vector<uint8_t>> EncodePng(const RgbaFrame& frame);

}  // namespace hmw
