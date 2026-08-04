#pragma once

#include <cstdint>
#include <memory>

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/encoder_backend.h"

namespace hcw {

class CameraEncodingSession final {
 public:
  explicit CameraEncodingSession(hmw::EncoderBackendFactory factory);
  ~CameraEncodingSession();

  CameraEncodingSession(const CameraEncodingSession&) = delete;
  CameraEncodingSession& operator=(const CameraEncodingSession&) = delete;

  hmw::Result<uint64_t> Start(uint64_t camera_generation,
                              hmw::EncodingConfig config,
                              hmw::EncoderCallbacks callbacks);
  void OfferFrame(uint64_t camera_generation, CameraFrame frame) noexcept;
  void GrantFramePermit() noexcept;
  void RequestKeyframe() noexcept;
  hmw::Outcome Stop();
  void Shutdown();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace hcw
