#include "honey_media_windows/encoder_backend.h"

#include "media_foundation_h264_encoder.h"

namespace hmw {
namespace {

Result<std::unique_ptr<EncoderBackend>> CodecUnavailable() {
  return {std::nullopt,
          Error{Status::kCodecUnavailable,
                "No Windows encoder backend is registered for this format."}};
}

}  // namespace

EncoderBackendFactory CreateDefaultEncoderBackendFactory() {
  return [](EncoderFormat format) -> Result<std::unique_ptr<EncoderBackend>> {
    switch (format) {
      case EncoderFormat::kH264:
        return {internal::CreateMediaFoundationH264Encoder(),
                std::nullopt};
      case EncoderFormat::kJpeg:
        return CodecUnavailable();
      case EncoderFormat::kMsv1:
        return CodecUnavailable();
    }
    return CodecUnavailable();
  };
}

}  // namespace hmw
