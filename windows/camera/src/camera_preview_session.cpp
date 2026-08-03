#include "honey_camera_windows/camera_preview.h"

#include <condition_variable>
#include <deque>
#include <exception>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

namespace hcw {

struct CameraPreviewSession::State {
  State(CameraSourceFactory source_factory, CameraPreviewCallbacks callbacks)
      : source_factory(std::move(source_factory)),
        callbacks(std::move(callbacks)) {}

  CameraSourceFactory source_factory;
  CameraPreviewCallbacks callbacks;
  std::mutex mutex;
  uint64_t generation = 0;
  std::shared_ptr<CameraFrameSource> source;
};

struct CameraPreviewSession::CallbackQueue {
  bool Post(std::function<void()> task) {
    std::lock_guard<std::mutex> lock(mutex);
    if (stopping) {
      return false;
    }
    tasks.push_back(std::move(task));
    condition.notify_one();
    return true;
  }

  void Stop() noexcept {
    std::lock_guard<std::mutex> lock(mutex);
    stopping = true;
    tasks.clear();
    condition.notify_all();
  }

  std::mutex mutex;
  std::condition_variable condition;
  std::deque<std::function<void()>> tasks;
  bool stopping = false;
};

namespace {

hmw::Error IoError(std::string message) {
  return {hmw::Status::kIoError, std::move(message)};
}

}  // namespace

CameraPreviewSession::CameraPreviewSession(
    CameraSourceFactory source_factory, CameraPreviewCallbacks callbacks)
    : state_(std::make_shared<State>(std::move(source_factory),
                                     std::move(callbacks))),
      callback_queue_(std::make_shared<CallbackQueue>()),
      callback_worker_(&CameraPreviewSession::RunCallbackWorker,
                       callback_queue_) {}

CameraPreviewSession::~CameraPreviewSession() {
  Close();
  StopCallbackWorker();
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
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    worker_generation = ++state_->generation;
  }
  try {
    worker_ = std::thread(&CameraPreviewSession::RunWorker, state_,
                          callback_queue_, worker_generation, config);
  } catch (const std::exception& exception) {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->generation == worker_generation) {
      ++state_->generation;
    }
    return {IoError(exception.what())};
  } catch (...) {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->generation == worker_generation) {
      ++state_->generation;
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
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  return state_->generation;
}

hmw::Outcome CameraPreviewSession::CloseLocked() {
  std::shared_ptr<CameraFrameSource> source;
  std::thread worker;
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    ++state_->generation;
    source = state_->source;
    state_->source.reset();
    worker = std::move(worker_);
  }

  if (source) {
    source->RequestStop();
  }
  if (worker.joinable()) {
    if (worker.get_id() == std::this_thread::get_id()) {
      worker.detach();
    } else {
      worker.join();
    }
  }
  return {};
}

void CameraPreviewSession::StopCallbackWorker() noexcept {
  callback_queue_->Stop();
  std::thread callback_worker = std::move(callback_worker_);
  if (callback_worker.joinable()) {
    if (callback_worker.get_id() == std::this_thread::get_id()) {
      callback_worker.detach();
    } else {
      callback_worker.join();
    }
  }
}

void CameraPreviewSession::RunWorker(
    std::shared_ptr<State> state,
    std::shared_ptr<CallbackQueue> callback_queue,
    uint64_t worker_generation, CameraPreviewConfig config) noexcept {
  std::shared_ptr<CameraFrameSource> source;
  try {
    hmw::Result<std::unique_ptr<CameraFrameSource>> created =
        state->source_factory(config);
    if (!created.ok() || !created.value || !*created.value) {
      DispatchError(
          state, callback_queue, worker_generation,
          created.error.value_or(IoError("camera source creation failed")));
      return;
    }

    source = std::shared_ptr<CameraFrameSource>(std::move(*created.value));
    bool active = false;
    {
      std::lock_guard<std::mutex> state_lock(state->mutex);
      active = state->generation == worker_generation;
      if (active) {
        state->source = source;
      }
    }
    if (!active) {
      source->RequestStop();
      return;
    }

    for (;;) {
      hmw::Result<CameraFrame> frame = source->ReadNext();
      if (!frame.ok() || !frame.value) {
        DispatchError(
            state, callback_queue, worker_generation,
            frame.error.value_or(IoError("camera frame read failed")));
        break;
      }
      DispatchFrame(state, callback_queue, worker_generation,
                    std::move(*frame.value));
    }
  } catch (const std::exception& exception) {
    DispatchError(state, callback_queue, worker_generation,
                  IoError(exception.what()));
  } catch (...) {
    DispatchError(state, callback_queue, worker_generation,
                  IoError("camera preview worker failed"));
  }

  std::lock_guard<std::mutex> state_lock(state->mutex);
  if (state->source == source) {
    state->source.reset();
  }
}

void CameraPreviewSession::RunCallbackWorker(
    std::shared_ptr<CallbackQueue> callback_queue) noexcept {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(callback_queue->mutex);
      callback_queue->condition.wait(
          lock, [&] {
            return callback_queue->stopping || !callback_queue->tasks.empty();
          });
      if (callback_queue->stopping) {
        return;
      }
      task = std::move(callback_queue->tasks.front());
      callback_queue->tasks.pop_front();
    }
    try {
      task();
    } catch (...) {
    }
  }
}

void CameraPreviewSession::DispatchFrame(
    std::shared_ptr<State> state,
    std::shared_ptr<CallbackQueue> callback_queue,
    uint64_t worker_generation, CameraFrame frame) noexcept {
  try {
    const std::shared_ptr<State> task_state = state;
    const std::shared_ptr<CallbackQueue> task_queue = callback_queue;
    callback_queue->Post(
        [task_state, task_queue, worker_generation,
         frame = std::move(frame)]() mutable {
          std::function<void(uint64_t, CameraFrame)> callback;
          {
            std::lock_guard<std::mutex> state_lock(task_state->mutex);
            if (task_state->generation != worker_generation) {
              return;
            }
            callback = task_state->callbacks.on_frame;
          }
          if (!callback) {
            return;
          }
          try {
            callback(worker_generation, std::move(frame));
          } catch (const std::exception& exception) {
            DispatchError(task_state, task_queue, worker_generation,
                          IoError(exception.what()));
          } catch (...) {
            DispatchError(task_state, task_queue, worker_generation,
                          IoError("camera frame callback failed"));
          }
        });
  } catch (...) {
  }
}

void CameraPreviewSession::DispatchError(
    std::shared_ptr<State> state,
    std::shared_ptr<CallbackQueue> callback_queue,
    uint64_t worker_generation, hmw::Error error) noexcept {
  try {
    const std::shared_ptr<State> task_state = state;
    callback_queue->Post(
        [task_state, worker_generation, error = std::move(error)]() mutable {
          std::function<void(uint64_t, hmw::Error)> callback;
          {
            std::lock_guard<std::mutex> state_lock(task_state->mutex);
            if (task_state->generation != worker_generation) {
              return;
            }
            callback = task_state->callbacks.on_error;
          }
          if (!callback) {
            return;
          }
          try {
            callback(worker_generation, std::move(error));
          } catch (...) {
          }
        });
  } catch (...) {
  }
}

}  // namespace hcw
