#include "honey_camera_windows/camera_encoding_session.h"

#include <algorithm>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>

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

bool ValidConfig(const hmw::EncodingConfig& config) {
  return config.width != 0U && config.height != 0U && config.fps != 0U &&
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
  std::optional<CameraFrame> latest_frame;
  bool frame_changed = false;
  uint32_t permits;
  bool keyframe_pending = false;
  bool stop_requested = false;
  bool terminal = false;
  bool terminal_callback_sent = false;
  bool start_ready = false;
  bool start_succeeded = false;
  bool finished = false;
  hmw::Outcome start_outcome;
  hmw::Outcome stop_outcome;
};

void InvokeError(const std::shared_ptr<EncodingRun>& run,
                 hmw::Error error) noexcept {
  std::function<void(uint64_t, hmw::Error)> callback;
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    if (run->terminal_callback_sent || run->stop_requested) {
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

void MarkStart(const std::shared_ptr<EncodingRun>& run,
               hmw::Outcome outcome) {
  std::lock_guard<std::mutex> lock(run->mutex);
  run->start_succeeded = outcome.ok();
  run->start_outcome = std::move(outcome);
  run->start_ready = true;
  run->condition.notify_all();
}

bool CallbacksAreActive(const std::shared_ptr<EncodingRun>& run) {
  std::lock_guard<std::mutex> lock(run->mutex);
  return !run->stop_requested && !run->terminal;
}

void PublishEncoded(const std::shared_ptr<EncodingRun>& run,
                    const std::vector<hmw::EncodedFrame>& frames,
                    hmw::EncodingStats* stats,
                    std::optional<int64_t>* first_pts,
                    std::optional<int64_t>* last_pts) noexcept {
  if (!CallbacksAreActive(run)) {
    return;
  }

  for (const auto& frame : frames) {
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
    if (run->callbacks.on_frame) {
      try {
        run->callbacks.on_frame(run->encoding_generation, frame);
      } catch (...) {
      }
    }
  }

  if (first_pts->has_value() && last_pts->has_value() &&
      **last_pts > **first_pts && stats->frames > 1U) {
    stats->fps =
        static_cast<double>(stats->frames - 1U) * kTicksPerSecond /
        static_cast<double>(**last_pts - **first_pts);
  } else {
    stats->fps = static_cast<double>(run->config.fps);
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
               hmw::EncodingStats stats = {}) noexcept {
  std::function<void(uint64_t, std::optional<std::string>,
                     hmw::EncodingStats)>
      callback;
  {
    std::lock_guard<std::mutex> lock(run->mutex);
    run->stop_outcome = outcome;
    run->finished = true;
    callback = run->callbacks.on_stopped;
    run->condition.notify_all();
  }
  if (callback) {
    try {
      callback(run->encoding_generation,
               outcome.error
                   ? std::optional<std::string>(outcome.error->message)
                   : std::nullopt,
               stats);
    } catch (...) {
    }
  }
}

void RunWorker(hmw::EncoderBackendFactory factory,
               const std::shared_ptr<EncodingRun>& run) noexcept {
  std::unique_ptr<hmw::EncoderBackend> backend;
  bool backend_started = false;
  hmw::EncodingStats stats{};
  std::optional<int64_t> first_output_pts;
  std::optional<int64_t> last_output_pts;
  std::optional<int64_t> last_input_pts;
  hmw::Outcome final_outcome;

  try {
    auto created = factory(run->config.format);
    if (!created.ok() || !created.value || !*created.value) {
      hmw::Error error =
          created.error.value_or(InvalidState("encoder factory returned no backend"));
      const hmw::Outcome failed{error};
      InvokeError(run, error);
      MarkStart(run, failed);
      FinishRun(run, failed);
      return;
    }
    backend = std::move(*created.value);
    hmw::Outcome started = backend->Start(run->config);
    if (!started.ok()) {
      const hmw::Error error = *started.error;
      InvokeError(run, error);
      MarkStart(run, started);
      FinishRun(run, started);
      return;
    }
    backend_started = true;
    MarkStart(run, {});

    if (run->callbacks.on_started && CallbacksAreActive(run)) {
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
          InvokeError(run, *requested.error);
        }
        continue;
      }
      if (!have_frame) {
        continue;
      }
      if (!ValidFrame(frame, run->config)) {
        InvokeError(run,
                    InvalidArgument("camera frame does not match encoding config"));
        continue;
      }

      const int64_t minimum_delta =
          kTicksPerSecond / static_cast<int64_t>(run->config.fps);
      if (last_input_pts &&
          (frame.pts_100ns <= *last_input_pts ||
           static_cast<uint64_t>(frame.pts_100ns) -
                   static_cast<uint64_t>(*last_input_pts) <
               static_cast<uint64_t>(minimum_delta))) {
        continue;
      }

      if (UsesFramePermits(run->config)) {
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
      if (!encoded.ok()) {
        InvokeError(run, encoded.error.value_or(
                             hmw::Error{hmw::Status::kEncodeFailed,
                                        "encoder returned no frames"}));
        continue;
      }
      PublishEncoded(run, *encoded.value, &stats, &first_output_pts,
                     &last_output_pts);
    }
  } catch (const std::exception& exception) {
    InvokeError(run, hmw::Error{hmw::Status::kIoError, exception.what()});
  } catch (...) {
    InvokeError(run,
                hmw::Error{hmw::Status::kIoError, "encoder worker failed"});
  }

  if (backend_started) {
    try {
      auto drained = backend->Drain();
      if (!drained.ok()) {
        final_outcome = {drained.error};
        if (drained.error) {
          InvokeError(run, *drained.error);
        }
      }
      const hmw::Outcome stopped = backend->Stop();
      if (final_outcome.ok() && !stopped.ok()) {
        final_outcome = stopped;
        if (stopped.error) {
          InvokeError(run, *stopped.error);
        }
      }
    } catch (const std::exception& exception) {
      final_outcome = {
          hmw::Error{hmw::Status::kIoError, exception.what()}};
      InvokeError(run, *final_outcome.error);
    } catch (...) {
      final_outcome = {hmw::Error{hmw::Status::kIoError,
                                  "encoder shutdown failed"}};
      InvokeError(run, *final_outcome.error);
    }
  }
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

  hmw::EncoderBackendFactory factory;
  std::mutex mutex;
  std::shared_ptr<EncodingRun> current;
  std::thread worker;
  uint64_t next_generation = 0U;
  bool shutdown = false;
};

CameraEncodingSession::CameraEncodingSession(
    hmw::EncoderBackendFactory factory)
    : impl_(std::make_unique<Impl>(std::move(factory))) {}

CameraEncodingSession::~CameraEncodingSession() { Shutdown(); }

hmw::Result<uint64_t> CameraEncodingSession::Start(
    uint64_t camera_generation, hmw::EncodingConfig config,
    hmw::EncoderCallbacks callbacks) {
  hmw::Outcome stopped = Stop();
  if (!stopped.ok()) {
    return {std::nullopt, stopped.error};
  }
  if (!ValidConfig(config)) {
    return {std::nullopt, InvalidArgument("encoding dimensions and fps must be non-zero")};
  }

  std::shared_ptr<EncodingRun> run;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->shutdown) {
      return {std::nullopt, InvalidState("encoding session is shut down")};
    }
    run = std::make_shared<EncodingRun>(camera_generation,
                                        ++impl_->next_generation,
                                        std::move(config),
                                        std::move(callbacks));
    impl_->current = run;
    impl_->worker = std::thread(RunWorker, impl_->factory, run);
  }

  hmw::Outcome start_outcome;
  {
    std::unique_lock<std::mutex> lock(run->mutex);
    run->condition.wait(lock, [&] { return run->start_ready; });
    start_outcome = run->start_outcome;
  }
  if (!start_outcome.ok()) {
    (void)Stop();
    return {std::nullopt, start_outcome.error};
  }
  return {run->encoding_generation, std::nullopt};
}

void CameraEncodingSession::OfferFrame(uint64_t camera_generation,
                                       CameraFrame frame) noexcept {
  std::shared_ptr<EncodingRun> run;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    run = impl_->current;
  }
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
  std::shared_ptr<EncodingRun> run;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    run = impl_->current;
  }
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
  std::shared_ptr<EncodingRun> run;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    run = impl_->current;
  }
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
  std::shared_ptr<EncodingRun> run;
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    run = std::move(impl_->current);
    if (!run && !impl_->worker.joinable()) {
      return {};
    }
    if (run) {
      std::lock_guard<std::mutex> run_lock(run->mutex);
      run->stop_requested = true;
      run->latest_frame.reset();
      run->condition.notify_all();
    }
    worker = std::move(impl_->worker);
  }
  if (worker.joinable()) {
    worker.join();
  }
  if (!run) {
    return {};
  }
  std::lock_guard<std::mutex> lock(run->mutex);
  return run->stop_outcome;
}

void CameraEncodingSession::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->shutdown = true;
  }
  (void)Stop();
}

}  // namespace hcw
