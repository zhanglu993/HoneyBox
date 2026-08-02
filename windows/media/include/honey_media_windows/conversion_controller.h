#pragma once

#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace hmw {

class ConversionController {
 public:
  using Completion = std::function<void(Result<MediaJobResult>)>;

  explicit ConversionController(PlatformDispatcher& dispatcher);
  ~ConversionController();

  ConversionController(const ConversionController&) = delete;
  ConversionController& operator=(const ConversionController&) = delete;

  Result<uint64_t> Start(MediaJobRequest request, Progress progress,
                         Completion completion);
  void Cancel();
  void Shutdown();

 private:
  struct JobSession;
  struct SharedState;

  void PostProgressIfCurrent(uint64_t generation, uint32_t done,
                             uint32_t total);
  void PostCompletionIfCurrent(uint64_t generation,
                               Result<MediaJobResult> result);
  void MarkWorkerFinished(uint64_t generation);

  PlatformDispatcher& dispatcher_;
  std::shared_ptr<SharedState> state_;
  std::thread worker_;
  std::mutex worker_mutex_;
};

}  // namespace hmw
