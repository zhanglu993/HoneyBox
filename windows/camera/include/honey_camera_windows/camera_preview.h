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
  std::shared_ptr<const std::vector<uint8_t>> rgba;
};

class CameraFrameSource {
 public:
  virtual ~CameraFrameSource() = default;

  virtual hmw::Result<CameraFrame> ReadNext() = 0;
  virtual void RequestStop() noexcept = 0;
  virtual void TeardownOnWorker() noexcept {}
};

using CameraSourceFactory = std::function<
    hmw::Result<std::unique_ptr<CameraFrameSource>>(
        const CameraPreviewConfig&)>;

CameraSourceFactory CreateMediaFoundationCameraFactory();

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
  struct State;
  struct CallbackQueue;

  hmw::Outcome CloseLocked();
  void StopCallbackWorker() noexcept;
  static void RunWorker(std::shared_ptr<State> state,
                        std::shared_ptr<CallbackQueue> callback_queue,
                        uint64_t worker_generation,
                        CameraPreviewConfig config) noexcept;
  static void RunCallbackWorker(
      std::shared_ptr<CallbackQueue> callback_queue) noexcept;
  static void DispatchFrame(std::shared_ptr<State> state,
                            std::shared_ptr<CallbackQueue> callback_queue,
                            uint64_t worker_generation,
                            CameraFrame frame) noexcept;
  static void DispatchError(std::shared_ptr<State> state,
                            std::shared_ptr<CallbackQueue> callback_queue,
                            uint64_t worker_generation,
                            hmw::Error error) noexcept;

  std::shared_ptr<State> state_;
  std::shared_ptr<CallbackQueue> callback_queue_;
  std::mutex operation_mutex_;
  std::thread worker_;
  std::thread callback_worker_;
};

}  // namespace hcw
