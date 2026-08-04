#pragma once

#include <functional>
#include <memory>
#include <vector>

#include "honey_media_windows/encoder_types.h"

namespace hmw {

class EncoderBackend {
 public:
  virtual ~EncoderBackend() = default;
  virtual hmw::Outcome Start(const EncodingConfig&) = 0;
  virtual hmw::Result<std::vector<EncodedFrame>> Encode(
      const EncoderInputFrame&) = 0;
  virtual hmw::Outcome RequestKeyframe() = 0;
  virtual hmw::Result<std::vector<EncodedFrame>> Drain() = 0;
  virtual hmw::Outcome Stop() = 0;
};

using EncoderBackendFactory = std::function<
    hmw::Result<std::unique_ptr<EncoderBackend>>(EncoderFormat)>;

EncoderBackendFactory CreateDefaultEncoderBackendFactory();

}  // namespace hmw
