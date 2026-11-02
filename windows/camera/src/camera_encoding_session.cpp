#include "honey_camera_windows/camera_encoding_session.h"

#include <algorithm>
#include <condition_variable>
#include <functional>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace hcw {

namespace {

constexpr uint32_t kMaxH264Permits = 2U;
constexpr int64_t kTicksPerSecond = 10'000'000;

hmw::Error InvalidArgument(const char* message) {
  return {hmw::Status::kInvalidArgument, message};
}

hmw::Error InvalidState(const char* message) {
  return {hmw::Status::kInvalidState, message};
}

hmw::Error WorkerError(std::string message) {
  return {hmw::Status::kIoError, std::move(message)};
}

bool ValidConfig(const hmw::EncodingConfig& config) {
  return config.width != 0U && config.height != 0U && config.fps != 0U &&
         config.fps <= static_cast<uint32_t>(kTicksPerSecond) &&
         config.width <= (std::numeric_limits<size_t>::max)() / 4U /
                             config.height;
}

bool UsesFramePermits(const hmw::EncodingConfig& config) {
  return config.format == hmw::EncoderFormat::kH264 && config.stream;
}

bool ValidFrame(const CameraFrame& frame,
                const hmw::EncodingConfig& config) {
  if (frame.width != config.width || frame.height != config.height ||
      !frame.rgba) {
    return false;
  }
  const size_t expected =
      static_cast<size_t>(config.width) * config.height * 4U;
  return frame.rgba->size() == expected;
}

void RecordFailure(hmw::Outcome* outcome, const hmw::Error& error) {
  if (outcome->ok()) {
    outcome->error = error;
  }
}

class JoinHandle final {
 public:
  ~JoinHandle() {
    std::thread owned;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!worker_.joinable()) {
        return;
      }
      if (worker_.get_id() == std::this_thread::get_id()) {
        worker_.detach();
        return;
      }
      owned = std::move(worker_);
    }
    owned.join();
  }

  void Launch(std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    worker_ = std::thread(std::move(callback));
  }

  void Join() {
    std::thread owned;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!worker_.joinable() ||
          worker_.get_id() == std::this_thread::get_id()) {
        return;
      }
      owned = std::move(worker_);
    }
    owned.join();
  }

 private:
  std::mutex mutex_;
  std::thread worker_;
};

struct EncodingRun final {
  EncodingRun(uint64_t camera_generation_value,
              uint64_t encoding_generation_value,
              hmw::EncodingConfig config_value,
              hmw::EncoderCallbacks callbacks_value)
      : camera_generation(camera_generation_value),
        encoding_generation(encoding_generation_value),
        config(std::move(config_value)),
        callbacks(std::move(callbacks_value)),
        permits(UsesFramePermits(config) ? kMaxH264Permits : 0U) {}

  std::mutex mutex;
  std::condition_variable condition;
  const uint64_t camera_generation;
  const uint64_t encoding_generation;
  const hmw::EncodingConfig config;
  const hmw::EncoderCallbacks callbacks;
  std::shared_ptr<JoinHandle> handle;
  std::thread::id worker_id;
  std::optional<CameraFrame> latest_frame;
  uint32_t permits;
  bool frame_changed = false;
  bool keyframe_pending = false;
  bool stop_requested = false;
  bool terminal = false;
  bool terminal_callback_sent = false;
  bool start_marked = false;
  bool start_ready = false;
  bool final_ready = false;
  bool finished = false;
  bool orphaned = false;
  hmw::Outcome start_outcome;
  hmw::Outcome final_outcome;
};

void RequestStop(const std::shared_ptr<EncodingRun>& run) noexcept {
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->stop_requested = true;
    run->latest_frame.reset();
    run->frame_changed = false;
  }
  run->condition.notify_all();
}

bool IsWorkerThread(const std::shared_ptr<EncodingRun>& run) {
  std::lock_guard<std::mutex> lock(run->mutex);
  return run->worker_id == std::this_thread::get_id();
}

hmw::Outcome CurrentOutcome(const std::shared_ptr<EncodingRun>& run) {
  std::lock_guard<std::mutex> lock(run->mutex);
  return run->final_ready ? run->final_outcome : hmw::Outcome{};
}

void MarkStart(const std::shared_ptr<EncodingRun>& run,
               hmw::Outcome outcome) {
  std::lock_guard<std::mutex> lock(run->mutex);
  if (run->start_marked) {
    return;
  }
  run->start_marked = true;
  run->start_outcome = std::move(outcome);
  run->start_ready = true;
  run->condition.notify_all();
}

void PublishErrorOnce(const std::shared_ptr<EncodingRun>& run,
                      hmw::Error error) noexcept {
  std::function<void(uint64_t, hmw::Error)> callback;
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->terminal_callback_sent) {
      return;
    }
    run->terminal = true;
    run->terminal_callback_sent = true;
    callback = run->callbacks.on_error;
    run->condition.notify_all();
  }
  if (callback) {
    try {
      callback(run->encoding_generation, std::move(error));
    } catch (...) {
    }
  }
}

void UpdateStats(const hmw::EncodedFrame& frame,
                 hmw::EncodingStats* stats,
                 std::optional<int64_t>* first_pts,
                 std::optional<int64_t>* last_pts,
                 uint32_t configured_fps) {
  ++stats->frames;
  stats->last_bytes = frame.bytes ? frame.bytes->size() : 0U;
  stats->bytes += stats->last_bytes;
  if (frame.key) {
    ++stats->keyframes;
    stats->key_bytes += stats->last_bytes;
  }
  if (!first_pts->has_value()) {
    *first_pts = frame.pts_100ns;
  }
  *last_pts = frame.pts_100ns;

  if (stats->frames > 1U && first_pts->has_value() &&
      last_pts->has_value() && **last_pts > **first_pts) {
    const uint64_t elapsed =
        static_cast<uint64_t>(**last_pts) -
        static_cast<uint64_t>(**first_pts);
    stats->fps =
        static_cast<double>(stats->frames - 1U) *
        static_cast<double>(kTicksPerSecond) /
        static_cast<double>(elapsed);
  } else {
    stats->fps = static_cast<double>(configured_fps);
  }
}

void PublishEncoded(const std::shared_ptr<EncodingRun>& run,
                    const std::vector<hmw::EncodedFrame>& frames,
                    hmw::EncodingStats* stats,
                    std::optional<int64_t>* first_pts,
                    std::optional<int64_t>* last_pts) noexcept {
  if (frames.empty()) {
    return;
  }

  // The worker serializes every callback. A generation is not replaced until
  // this worker has completed and been joined, so Stop does not retire already
  // encoded output.
  for (const auto& frame : frames) {
    UpdateStats(frame, stats, first_pts, last_pts, run->config.fps);
    if (run->callbacks.on_frame) {
      try {
        run->callbacks.on_frame(run->encoding_generation, frame);
      } catch (...) {
      }
    }
  }
  if (run->callbacks.on_stats) {
    try {
      run->callbacks.on_stats(run->encoding_generation, *stats);
    } catch (...) {
    }
  }
}

void FinishRun(const std::shared_ptr<EncodingRun>& run,
               hmw::Outcome outcome,
               hmw::EncodingStats stats) noexcept {
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->final_outcome = outcome;
    run->final_ready = true;
  }

  if (run->callbacks.on_stopped) {
    try {
      run->callbacks.on_stopped(run->encoding_generation, std::nullopt, stats);
    } catch (...) {
    }
  }

  std::shared_ptr<JoinHandle> orphaned_handle;
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->finished = true;
    if (run->orphaned) {
      orphaned_handle = std::move(run->handle);
    }
    run->condition.notify_all();
  }
  // When the session is deleted by its own callback, no external lifecycle
  // owner remains to join. Releasing the handle here detaches only the current
  // thread, after backend teardown and terminal callbacks have completed.
  orphaned_handle.reset();
}

void RunWorker(hmw::EncoderBackendFactory factory,
               const std::shared_ptr<EncodingRun>& run) noexcept {
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->worker_id = std::this_thread::get_id();
  }

  std::unique_ptr<hmw::EncoderBackend> backend;
  bool backend_started = false;
  hmw::Outcome final_outcome;
  hmw::EncodingStats stats{};
  std::optional<int64_t> first_output_pts;
  std::optional<int64_t> last_output_pts;
  std::optional<int64_t> last_input_pts;

  try {
    auto created = factory(run->config.format);
    if (!created.ok() || !created.value || !*created.value) {
      const hmw::Error error = created.error.value_or(
          InvalidState("encoder factory returned no backend"));
      RecordFailure(&final_outcome, error);
      PublishErrorOnce(run, error);
    } else {
      backend = std::move(*created.value);
      const hmw::Outcome started = backend->Start(run->config);
      if (!started.ok()) {
        const hmw::Error error =
            started.error.value_or(InvalidState("encoder start failed"));
        RecordFailure(&final_outcome, error);
        PublishErrorOnce(run, error);
      } else {
        backend_started = true;
        MarkStart(run, {});

        if (run->callbacks.on_started) {
          try {
            run->callbacks.on_started(run->encoding_generation, std::nullopt,
                                      run->config.width, run->config.height);
          } catch (...) {
          }
        }

        for (;;) {
          CameraFrame frame{};
          bool have_frame = false;
          bool request_keyframe = false;
          {
            std::unique_lock<std::mutex> lock(run->mutex);
            run->condition.wait(lock, [&] {
              return run->stop_requested || run->terminal ||
                     run->keyframe_pending ||
                     (run->latest_frame.has_value() &&
                      (run->frame_changed ||
                       !UsesFramePermits(run->config) ||
                       run->permits != 0U));
            });
            if (run->stop_requested || run->terminal) {
              break;
            }
            if (run->keyframe_pending) {
              run->keyframe_pending = false;
              request_keyframe = true;
            } else if (run->latest_frame) {
              const bool can_encode =
                  !UsesFramePermits(run->config) || run->permits != 0U;
              if (can_encode) {
                frame = std::move(*run->latest_frame);
                run->latest_frame.reset();
              } else {
                frame = *run->latest_frame;
              }
              run->frame_changed = false;
              have_frame = true;
            }
          }

          if (request_keyframe) {
            const hmw::Outcome requested = backend->RequestKeyframe();
            if (!requested.ok()) {
              const hmw::Error error = requested.error.value_or(
                  InvalidState("keyframe request failed"));
              RecordFailure(&final_outcome, error);
              PublishErrorOnce(run, error);
            }
            continue;
          }
          if (!have_frame) {
            continue;
          }
          if (!ValidFrame(frame, run->config)) {
            const hmw::Error error = InvalidArgument(
                "camera frame does not match encoding config");
            RecordFailure(&final_outcome, error);
            PublishErrorOnce(run, error);
            continue;
          }

          const uint64_t minimum_delta =
              static_cast<uint64_t>(kTicksPerSecond) / run->config.fps;
          if (last_input_pts &&
              (frame.pts_100ns <= *last_input_pts ||
               static_cast<uint64_t>(frame.pts_100ns) -
                       static_cast<uint64_t>(*last_input_pts) <
                   minimum_delta)) {
            continue;
          }

          const bool uses_permit = UsesFramePermits(run->config);
          if (uses_permit) {
            std::lock_guard<std::mutex> lock(run->mutex);
            if (run->permits == 0U) {
              run->latest_frame = std::move(frame);
              continue;
            }
            --run->permits;
          }
          last_input_pts = frame.pts_100ns;

          const hmw::EncoderInputFrame input{
              frame.width,
              frame.height,
              frame.pts_100ns,
              kTicksPerSecond / static_cast<int64_t>(run->config.fps),
              frame.rgba->data(),
              frame.rgba->size(),
          };
          auto encoded = backend->Encode(input);
          if (!encoded.ok() || !encoded.value) {
            const hmw::Error error = encoded.error.value_or(
                hmw::Error{hmw::Status::kEncodeFailed,
                           "encoder returned no result"});
            RecordFailure(&final_outcome, error);
            PublishErrorOnce(run, error);
            continue;
          }
          if (uses_permit && encoded.value->empty()) {
            {
              std::lock_guard<std::mutex> lock(run->mutex);
              run->permits =
                  (std::min)(kMaxH264Permits, run->permits + 1U);
            }
            run->condition.notify_one();
          }
          PublishEncoded(run, *encoded.value, &stats, &first_output_pts,
                         &last_output_pts);
        }
      }
    }
  } catch (const std::exception& exception) {
    const hmw::Error error = WorkerError(exception.what());
    RecordFailure(&final_outcome, error);
    PublishErrorOnce(run, error);
  } catch (...) {
    const hmw::Error error = WorkerError("encoder worker failed");
    RecordFailure(&final_outcome, error);
    PublishErrorOnce(run, error);
  }

  if (!run->start_marked) {
    if (final_outcome.ok()) {
      RecordFailure(&final_outcome,
                    InvalidState("encoder worker exited before start"));
    }
    MarkStart(run, final_outcome);
  }

  if (backend_started) {
    try {
      auto drained = backend->Drain();
      if (!drained.ok() || !drained.value) {
        const hmw::Error error = drained.error.value_or(
            hmw::Error{hmw::Status::kEncodeFailed,
                       "encoder drain returned no result"});
        RecordFailure(&final_outcome, error);
        PublishErrorOnce(run, error);
      } else {
        PublishEncoded(run, *drained.value, &stats, &first_output_pts,
                       &last_output_pts);
      }
    } catch (const std::exception& exception) {
      const hmw::Error error = WorkerError(exception.what());
      RecordFailure(&final_outcome, error);
      PublishErrorOnce(run, error);
    } catch (...) {
      const hmw::Error error = WorkerError("encoder drain failed");
      RecordFailure(&final_outcome, error);
      PublishErrorOnce(run, error);
    }

    try {
      const hmw::Outcome stopped = backend->Stop();
      if (!stopped.ok()) {
        const hmw::Error error =
            stopped.error.value_or(InvalidState("encoder stop failed"));
        RecordFailure(&final_outcome, error);
        PublishErrorOnce(run, error);
      }
    } catch (const std::exception& exception) {
      const hmw::Error error = WorkerError(exception.what());
      RecordFailure(&final_outcome, error);
      PublishErrorOnce(run, error);
    } catch (...) {
      const hmw::Error error = WorkerError("encoder stop failed");
      RecordFailure(&final_outcome, error);
      PublishErrorOnce(run, error);
    }
  }

  backend.reset();
  FinishRun(run, final_outcome, stats);
}

}  // namespace

struct CameraEncodingSession::Impl final {
  explicit Impl(hmw::EncoderBackendFactory factory_value)
      : factory(std::move(factory_value)) {
    if (!factory) {
      throw std::invalid_argument("encoder backend factory is required");
    }
  }

  std::shared_ptr<EncodingRun> Current() {
    std::lock_guard<std::mutex> lock(state_mutex);
    return current;
  }

  hmw::Outcome StopLocked() {
    std::shared_ptr<EncodingRun> run;
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      run = current;
      if (!run) {
        return last_outcome;
      }
    }

    RequestStop(run);
    std::shared_ptr<JoinHandle> handle;
    {
      std::lock_guard<std::mutex> lock(run->mutex);
      handle = run->handle;
    }
    if (handle) {
      handle->Join();
    }

    hmw::Outcome outcome;
    {
      std::unique_lock<std::mutex> lock(run->mutex);
      run->condition.wait(lock, [&] { return run->finished; });
      outcome = run->final_outcome;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      if (current == run) {
        current.reset();
      }
      last_outcome = outcome;
    }
    return outcome;
  }

  hmw::EncoderBackendFactory factory;
  std::mutex operation_mutex;
  std::mutex state_mutex;
  std::shared_ptr<EncodingRun> current;
  hmw::Outcome last_outcome;
  uint64_t next_generation = 0U;
  bool shutdown = false;
};

CameraEncodingSession::CameraEncodingSession(
    hmw::EncoderBackendFactory factory)
    : impl_(std::make_unique<Impl>(std::move(factory))) {}

CameraEncodingSession::~CameraEncodingSession() {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  if (run && IsWorkerThread(run)) {
    {
      std::lock_guard<std::mutex> lock(impl_->state_mutex);
      impl_->shutdown = true;
      if (impl_->current == run) {
        impl_->current.reset();
      }
    }
    {
      std::lock_guard<std::mutex> lock(run->mutex);
      run->orphaned = true;
    }
    RequestStop(run);
    return;
  }
  Shutdown();
}

hmw::Result<uint64_t> CameraEncodingSession::Start(
    uint64_t camera_generation, hmw::EncodingConfig config,
    hmw::EncoderCallbacks callbacks) {
  if (!ValidConfig(config)) {
    return {std::nullopt,
            InvalidArgument(
                "encoding dimensions and fps must fit 100ns timing")};
  }

  std::unique_lock<std::mutex> operation_lock(impl_->operation_mutex);
  // Retiring the previous run reports that run's terminal outcome, which its
  // own callbacks already delivered. A failed run must not block the next
  // start; only shutdown and this start's own failures can.
  (void)impl_->StopLocked();

  std::shared_ptr<EncodingRun> run;
  {
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    if (impl_->shutdown) {
      return {std::nullopt, InvalidState("encoding session is shut down")};
    }
    run = std::make_shared<EncodingRun>(camera_generation,
                                        ++impl_->next_generation,
                                        std::move(config),
                                        std::move(callbacks));
    impl_->current = run;
    impl_->last_outcome = {};
  }

  auto handle = std::make_shared<JoinHandle>();
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->handle = handle;
  }
  try {
    handle->Launch([factory = impl_->factory, run] {
      RunWorker(factory, run);
    });
  } catch (const std::exception& exception) {
    const hmw::Error error = WorkerError(exception.what());
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    if (impl_->current == run) {
      impl_->current.reset();
    }
    impl_->last_outcome = hmw::Outcome{error};
    return {std::nullopt, error};
  } catch (...) {
    const hmw::Error error = WorkerError("unable to start encoder worker");
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    if (impl_->current == run) {
      impl_->current.reset();
    }
    impl_->last_outcome = hmw::Outcome{error};
    return {std::nullopt, error};
  }

  hmw::Outcome start_outcome;
  {
    std::unique_lock<std::mutex> lock(run->mutex);
    run->condition.wait(lock, [&] { return run->start_ready; });
    start_outcome = run->start_outcome;
  }
  if (!start_outcome.ok()) {
    RequestStop(run);
    handle->Join();
    {
      std::lock_guard<std::mutex> lock(impl_->state_mutex);
      if (impl_->current == run) {
        impl_->current.reset();
      }
      impl_->last_outcome = start_outcome;
    }
    return {std::nullopt, start_outcome.error};
  }
  return {run->encoding_generation, std::nullopt};
}

void CameraEncodingSession::OfferFrame(uint64_t camera_generation,
                                       CameraFrame frame) noexcept {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  if (!run) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->camera_generation != camera_generation || run->stop_requested ||
        run->terminal) {
      return;
    }
    run->latest_frame = std::move(frame);
    run->frame_changed = true;
  }
  run->condition.notify_one();
}

void CameraEncodingSession::GrantFramePermit() noexcept {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  if (!run) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->stop_requested || run->terminal ||
        !UsesFramePermits(run->config)) {
      return;
    }
    run->permits = (std::min)(kMaxH264Permits, run->permits + 1U);
  }
  run->condition.notify_one();
}

void CameraEncodingSession::RequestKeyframe() noexcept {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  if (!run) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->stop_requested || run->terminal) {
      return;
    }
    run->keyframe_pending = true;
  }
  run->condition.notify_one();
}

hmw::Outcome CameraEncodingSession::Stop() {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  if (run && IsWorkerThread(run)) {
    RequestStop(run);
    return CurrentOutcome(run);
  }
  std::lock_guard<std::mutex> operation_lock(impl_->operation_mutex);
  return impl_->StopLocked();
}

void CameraEncodingSession::Shutdown() {
  const std::shared_ptr<EncodingRun> run = impl_->Current();
  {
    std::lock_guard<std::mutex> lock(impl_->state_mutex);
    impl_->shutdown = true;
  }
  if (run && IsWorkerThread(run)) {
    RequestStop(run);
    return;
  }
  std::lock_guard<std::mutex> operation_lock(impl_->operation_mutex);
  (void)impl_->StopLocked();
}

}  // namespace hcw
