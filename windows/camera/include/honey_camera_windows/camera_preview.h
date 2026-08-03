#pragma once

#include "honey_media_windows/status.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace hcw {

struct CameraPreviewConfig {
  uint32_t width;
  uint32_t height;
  uint32_t fps;
};

struct CameraFrame {
  uint32_t width;
  uint32_t height;
  int64_t pts_100ns;
  std::shared_ptr<const std::vector<uint8_t>> bgra;
};

class CameraFrameSource {
 public:
  virtual ~CameraFrameSource() = default;

  virtual hmw::Result<CameraFrame> ReadNext() = 0;
  virtual void RequestStop() noexcept = 0;
};

using CameraSourceFactory = std::function<
    hmw::Result<std::unique_ptr<CameraFrameSource>>(
        const CameraPreviewConfig&)>;

struct CameraPreviewCallbacks {
  std::function<void(uint64_t, CameraFrame)> on_frame;
  std::function<void(uint64_t, hmw::Error)> on_error;
};

class CameraPreviewSession final {
 public:
  CameraPreviewSession(CameraSourceFactory source_factory,
                       CameraPreviewCallbacks callbacks);
  ~CameraPreviewSession();

  hmw::Outcome Open(CameraPreviewConfig config);
  hmw::Outcome Close();
  uint64_t generation() const;

 private:
  hmw::Outcome CloseLocked();
  void RunWorker(uint64_t worker_generation, CameraPreviewConfig config);
  void PublishFrameIfActive(uint64_t worker_generation, CameraFrame frame);
  void PublishErrorIfActive(uint64_t worker_generation, hmw::Error error);

  CameraSourceFactory source_factory_;
  CameraPreviewCallbacks callbacks_;
  mutable std::mutex state_mutex_;
  std::mutex operation_mutex_;
  uint64_t generation_ = 0;
  std::shared_ptr<CameraFrameSource> source_;
  std::thread worker_;
};

}  // namespace hcw
