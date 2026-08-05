#pragma once

#include <cstdint>
#include <memory>

#include "honey_camera_windows/camera_preview.h"
#include "honey_media_windows/encoder_backend.h"

namespace hcw {

// The encoding contract the Flutter channel depends on. Keeping it abstract
// lets the channel be tested without a real codec backend or worker thread.
class EncodingSession {
 public:
  virtual ~EncodingSession() = default;

  virtual hmw::Result<uint64_t> Start(uint64_t camera_generation,
                                      hmw::EncodingConfig config,
                                      hmw::EncoderCallbacks callbacks) = 0;
  virtual void OfferFrame(uint64_t camera_generation,
                          CameraFrame frame) noexcept = 0;
  virtual void GrantFramePermit() noexcept = 0;
  virtual void RequestKeyframe() noexcept = 0;
  virtual hmw::Outcome Stop() = 0;
  virtual void Shutdown() = 0;
};

class CameraEncodingSession final : public EncodingSession {
 public:
  explicit CameraEncodingSession(hmw::EncoderBackendFactory factory);
  ~CameraEncodingSession() override;

  CameraEncodingSession(const CameraEncodingSession&) = delete;
  CameraEncodingSession& operator=(const CameraEncodingSession&) = delete;

  hmw::Result<uint64_t> Start(uint64_t camera_generation,
                              hmw::EncodingConfig config,
                              hmw::EncoderCallbacks callbacks) override;
  void OfferFrame(uint64_t camera_generation,
                  CameraFrame frame) noexcept override;
  void GrantFramePermit() noexcept override;
  void RequestKeyframe() noexcept override;
  hmw::Outcome Stop() override;
  void Shutdown() override;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace hcw
