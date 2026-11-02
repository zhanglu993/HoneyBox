#include "honey_media_windows/conversion_controller.h"

#include <atomic>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <system_error>
#include <utility>

namespace hmw {

struct ConversionController::JobSession {
  JobSession(uint64_t job_generation, Progress job_progress,
             Completion job_completion)
      : generation(job_generation), progress(std::move(job_progress)),
        completion(std::move(job_completion)) {}

  uint64_t generation;
  Progress progress;
  Completion completion;
  std::atomic<bool> terminal_posted{false};
  std::atomic<bool> terminal_delivered{false};
};

struct ConversionController::SharedState {
  std::atomic<uint64_t> generation{0};
  std::atomic<bool> cancelled{false};
  std::atomic<bool> shutting_down{false};
  std::mutex mutex;
  bool active = false;
  std::shared_ptr<JobSession> current;
};

namespace {

Result<uint64_t> StartFailure(Status status, std::string message) {
  return Result<uint64_t>{std::nullopt,
                          Error{status, std::move(message)}};
}

}  // namespace

ConversionController::ConversionController(PlatformDispatcher& dispatcher)
    : dispatcher_(dispatcher), state_(std::make_shared<SharedState>()) {}

ConversionController::~ConversionController() { Shutdown(); }

Result<uint64_t> ConversionController::Start(MediaJobRequest request,
                                             Progress progress,
                                             Completion completion) {
  std::unique_lock<std::mutex> worker_lock(worker_mutex_);
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->shutting_down.load()) {
      return StartFailure(Status::kInvalidState,
                          "conversion controller is shut down");
    }
    if (state_->active) {
      return StartFailure(Status::kBusy, "a conversion job is already active");
    }
    if (!completion) {
      return StartFailure(Status::kInvalidState,
                          "completion callback is required");
    }
  }

  if (worker_.joinable()) {
    if (worker_.get_id() == std::this_thread::get_id()) {
      return StartFailure(Status::kInvalidState,
                          "platform dispatcher invoked callback inline");
    }
    worker_condition_.wait(
        worker_lock, [this] { return worker_finished_; });
    worker_.join();
  }

  std::shared_ptr<JobSession> session;
  uint64_t generation = 0;
  try {
    generation = state_->generation.fetch_add(1) + 1U;
    session = std::make_shared<JobSession>(
        generation, std::move(progress), std::move(completion));
  } catch (const std::bad_alloc&) {
    return StartFailure(Status::kInvalidState,
                        "conversion worker allocation failed");
  }

  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->shutting_down.load()) {
      return StartFailure(Status::kInvalidState,
                          "conversion controller is shut down");
    }
    state_->cancelled.store(false);
    state_->active = true;
    state_->current = session;
  }

  worker_finished_ = false;
  try {
    worker_ = std::thread(
        [this, generation, request = std::move(request)]() mutable {
          RunWorker(generation, std::move(request));
          {
            std::lock_guard<std::mutex> worker_lock(worker_mutex_);
            worker_finished_ = true;
          }
          worker_condition_.notify_all();
        });
  } catch (...) {
    worker_finished_ = true;
    worker_condition_.notify_all();
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->current == session) {
      state_->active = false;
      state_->current.reset();
      state_->generation.fetch_add(1);
    }
    return StartFailure(Status::kInvalidState,
                        "conversion worker could not be started");
  }

  return Result<uint64_t>{generation, std::nullopt};
}

void ConversionController::Cancel() {
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  if (state_->active && !state_->shutting_down.load()) {
    state_->cancelled.store(true);
  }
}

Outcome ConversionController::WaitForCurrentJob(
    std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> worker_lock(worker_mutex_);
  if (!worker_.joinable()) {
    return {std::nullopt};
  }
  if (worker_.get_id() == std::this_thread::get_id()) {
    return {Error{Status::kInvalidState,
                  "conversion worker cannot wait for itself"}};
  }
  if (!worker_condition_.wait_for(
          worker_lock, timeout, [this] { return worker_finished_; })) {
    return {Error{Status::kBusy,
                  "conversion worker did not finish before timeout"}};
  }
  try {
    worker_.join();
  } catch (const std::system_error&) {
    return {Error{Status::kInvalidState,
                  "conversion worker could not be joined"}};
  }
  return {std::nullopt};
}

void ConversionController::Shutdown() {
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (!state_->shutting_down.exchange(true)) {
      state_->cancelled.store(true);
      state_->generation.fetch_add(1);
    }
  }
  std::unique_lock<std::mutex> worker_lock(worker_mutex_);
  if (worker_.joinable()) {
    if (worker_.get_id() == std::this_thread::get_id()) {
      return;
    }
    worker_condition_.wait(
        worker_lock, [this] { return worker_finished_; });
    worker_.join();
  }
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  state_->active = false;
  state_->current.reset();
}

void ConversionController::RunWorker(uint64_t generation,
                                     MediaJobRequest&& request) noexcept {
  try {
    const auto cancelled = [state = state_, generation] {
      return state->shutting_down.load() || state->cancelled.load() ||
             state->generation.load() != generation;
    };
    Result<MediaJobResult> result = ExecuteMediaJob(
        request,
        [this, generation](uint32_t done, uint32_t total) {
          PostProgressIfCurrent(generation, done, total);
        },
        cancelled);
    PostCompletionIfCurrent(generation, std::move(result));
  } catch (...) {
    try {
      PostCompletionIfCurrent(
          generation,
          Result<MediaJobResult>{
              std::nullopt,
              Error{Status::kInvalidState,
                    "media worker failed unexpectedly"}});
    } catch (...) {
    }
  }

  try {
    MarkWorkerFinished(generation);
  } catch (...) {
  }
}

void ConversionController::PostProgressIfCurrent(uint64_t generation,
                                                 uint32_t done,
                                                 uint32_t total) {
  std::shared_ptr<JobSession> session;
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->shutting_down.load() || state_->cancelled.load() ||
        state_->generation.load() != generation || !state_->current ||
        state_->current->generation != generation) {
      return;
    }
    session = state_->current;
  }
  if (!session->progress) {
    return;
  }
  const std::shared_ptr<SharedState> state = state_;
  Progress progress = session->progress;
  try {
    (void)dispatcher_.Post(
        [state, generation, progress = std::move(progress), done,
         total]() mutable {
          if (!state->shutting_down.load() && !state->cancelled.load() &&
              state->generation.load() == generation) {
            progress(done, total);
          }
        });
  } catch (...) {
  }
}

void ConversionController::PostCompletionIfCurrent(
    uint64_t generation, Result<MediaJobResult> result) {
  std::shared_ptr<JobSession> session;
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->shutting_down.load() ||
        state_->generation.load() != generation || !state_->current ||
        state_->current->generation != generation) {
      return;
    }
    session = state_->current;
    session->terminal_posted.store(true);
  }
  const std::shared_ptr<SharedState> state = state_;
  bool posted = false;
  try {
    posted = dispatcher_.Post(
        [state, session, generation,
         result = std::move(result)]() mutable {
          bool deliver = false;
          {
            std::lock_guard<std::mutex> state_lock(state->mutex);
            if (!state->shutting_down.load() &&
                state->generation.load() == generation &&
                state->current == session) {
              state->active = false;
              state->current.reset();
              deliver = !session->terminal_delivered.exchange(true);
            }
          }
          if (deliver) {
            session->completion(std::move(result));
          }
        });
  } catch (...) {
  }
  if (!posted) {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->current == session) {
      state_->active = false;
      state_->current.reset();
    }
  }
}

void ConversionController::MarkWorkerFinished(uint64_t generation) {
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  if (state_->current && state_->current->generation == generation) {
    state_->active = false;
    if (!state_->current->terminal_posted.load()) {
      state_->current.reset();
    }
  }
}

}  // namespace hmw
