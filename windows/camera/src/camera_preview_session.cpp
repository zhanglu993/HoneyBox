#include "honey_camera_windows/camera_preview.h"

#include <exception>
#include <optional>
#include <string>
#include <utility>

namespace hcw {
namespace {

hmw::Error IoError(std::string message) {
  return {hmw::Status::kIoError, std::move(message)};
}

}  // namespace

CameraPreviewSession::CameraPreviewSession(
    CameraSourceFactory source_factory, CameraPreviewCallbacks callbacks)
    : source_factory_(std::move(source_factory)), callbacks_(std::move(callbacks)) {}

CameraPreviewSession::~CameraPreviewSession() {
  Close();
}

hmw::Outcome CameraPreviewSession::Open(CameraPreviewConfig config) {
  std::lock_guard<std::mutex> operation_lock(operation_mutex_);
  CloseLocked();
  if (config.width == 0 || config.height == 0 || config.fps == 0) {
    return {hmw::Error{hmw::Status::kInvalidArgument,
                       "preview width, height, and fps must be positive"}};
  }

  uint64_t worker_generation = 0;
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    worker_generation = ++generation_;
  }
  try {
    worker_ = std::thread(&CameraPreviewSession::RunWorker, this,
                          worker_generation, config);
  } catch (const std::exception& exception) {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (generation_ == worker_generation) {
      ++generation_;
    }
    return {IoError(exception.what())};
  } catch (...) {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (generation_ == worker_generation) {
      ++generation_;
    }
    return {IoError("unable to start camera preview worker")};
  }
  return {};
}

hmw::Outcome CameraPreviewSession::Close() {
  std::lock_guard<std::mutex> operation_lock(operation_mutex_);
  return CloseLocked();
}

uint64_t CameraPreviewSession::generation() const {
  std::lock_guard<std::mutex> state_lock(state_mutex_);
  return generation_;
}

hmw::Outcome CameraPreviewSession::CloseLocked() {
  std::shared_ptr<CameraFrameSource> source;
  std::thread worker;
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    ++generation_;
    source = source_;
    source_.reset();
    worker = std::move(worker_);
  }

  if (source) {
    source->RequestStop();
  }
  if (worker.joinable()) {
    worker.join();
  }
  return {};
}

void CameraPreviewSession::RunWorker(uint64_t worker_generation,
                                     CameraPreviewConfig config) {
  std::shared_ptr<CameraFrameSource> source;
  try {
    hmw::Result<std::unique_ptr<CameraFrameSource>> created =
        source_factory_(config);
    if (!created.ok() || !created.value || !*created.value) {
      PublishErrorIfActive(
          worker_generation,
          created.error.value_or(IoError("camera source creation failed")));
      return;
    }

    source = std::shared_ptr<CameraFrameSource>(std::move(*created.value));
    {
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      if (generation_ != worker_generation) {
        source->RequestStop();
        return;
      }
      source_ = source;
    }

    for (;;) {
      hmw::Result<CameraFrame> frame = source->ReadNext();
      if (!frame.ok() || !frame.value) {
        PublishErrorIfActive(
            worker_generation,
            frame.error.value_or(IoError("camera frame read failed")));
        break;
      }
      PublishFrameIfActive(worker_generation, std::move(*frame.value));
    }
  } catch (const std::exception& exception) {
    PublishErrorIfActive(worker_generation, IoError(exception.what()));
  } catch (...) {
    PublishErrorIfActive(worker_generation,
                         IoError("camera preview worker failed"));
  }

  std::lock_guard<std::mutex> state_lock(state_mutex_);
  if (source_ == source) {
    source_.reset();
  }
}

void CameraPreviewSession::PublishFrameIfActive(uint64_t worker_generation,
                                                CameraFrame frame) {
  std::function<void(uint64_t, CameraFrame)> callback;
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (generation_ != worker_generation) {
      return;
    }
    callback = callbacks_.on_frame;
  }
  if (callback) {
    callback(worker_generation, std::move(frame));
  }
}

void CameraPreviewSession::PublishErrorIfActive(uint64_t worker_generation,
                                                hmw::Error error) {
  std::function<void(uint64_t, hmw::Error)> callback;
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (generation_ != worker_generation) {
      return;
    }
    callback = callbacks_.on_error;
  }
  if (callback) {
    try {
      callback(worker_generation, std::move(error));
    } catch (...) {
    }
  }
}

}  // namespace hcw
