#pragma once

#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <chrono>
#include <condition_variable>
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
  // Waits without invalidating queued callbacks. A timeout leaves the worker
  // joinable so the caller may wait again; worker self-wait is invalid.
  Outcome WaitForCurrentJob(std::chrono::milliseconds timeout);
  void Shutdown();

 private:
  struct JobSession;
  struct SharedState;

  void RunWorker(uint64_t generation, MediaJobRequest&& request) noexcept;
  void PostProgressIfCurrent(uint64_t generation, uint32_t done,
                             uint32_t total);
  void PostCompletionIfCurrent(uint64_t generation,
                               Result<MediaJobResult> result);
  void MarkWorkerFinished(uint64_t generation);

  PlatformDispatcher& dispatcher_;
  std::shared_ptr<SharedState> state_;
  std::thread worker_;
  std::mutex worker_mutex_;
  std::condition_variable worker_condition_;
  bool worker_finished_ = true;
};

}  // namespace hmw
