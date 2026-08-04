#pragma once

#include "honey_media_windows/encoder_backend.h"

#include <mftransform.h>

#include <memory>
#include <vector>

namespace hmw::internal {

class H264TransformProvider {
 public:
  virtual ~H264TransformProvider() = default;
  virtual Result<std::vector<std::shared_ptr<IMFTransform>>>
  EnumerateSynchronousLocal() = 0;
};

std::unique_ptr<EncoderBackend> CreateMediaFoundationH264EncoderForTesting(
    std::shared_ptr<H264TransformProvider> provider);
std::unique_ptr<EncoderBackend> CreateMediaFoundationH264Encoder();

}  // namespace hmw::internal
