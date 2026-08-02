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
  std::lock_guard<std::mutex> worker_lock(worker_mutex_);
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (state_->shutting_down.load()) {
      return StartFailure(Status::kInvalidState,
                          "conversion controller is shut down");
    }
    if (state_->active) {
      return StartFailure(Status::kBusy, "a conversion job is already active");
    }
  }

  if (worker_.joinable()) {
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

  try {
    worker_ = std::thread(
        [this, generation, request = std::move(request)]() mutable {
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
          MarkWorkerFinished(generation);
        });
  } catch (const std::system_error&) {
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

void ConversionController::Shutdown() {
  {
    std::lock_guard<std::mutex> state_lock(state_->mutex);
    if (!state_->shutting_down.exchange(true)) {
      state_->cancelled.store(true);
      state_->generation.fetch_add(1);
    }
  }
  std::lock_guard<std::mutex> worker_lock(worker_mutex_);
  if (worker_.joinable()) {
    worker_.join();
  }
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  state_->active = false;
  state_->current.reset();
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
  dispatcher_.Post([state, generation, progress = std::move(progress), done,
                    total]() mutable {
    if (!state->shutting_down.load() && !state->cancelled.load() &&
        state->generation.load() == generation) {
      progress(done, total);
    }
  });
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
  }
  if (!session->completion) {
    return;
  }
  const std::shared_ptr<SharedState> state = state_;
  dispatcher_.Post([state, session, generation,
                    result = std::move(result)]() mutable {
    if (!state->shutting_down.load() &&
        state->generation.load() == generation &&
        !session->terminal_delivered.exchange(true)) {
      session->completion(std::move(result));
    }
  });
}

void ConversionController::MarkWorkerFinished(uint64_t generation) {
  std::lock_guard<std::mutex> state_lock(state_->mutex);
  if (state_->current && state_->current->generation == generation) {
    state_->active = false;
    state_->current.reset();
  }
}

}  // namespace hmw
