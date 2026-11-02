#include "video_texture_player.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <limits>
#include <mutex>
#include <optional>
#include <system_error>
#include <utility>
#include <vector>

namespace hmw {
namespace {

int64_t DurationMilliseconds(int64_t duration_100ns) {
  const int64_t whole_ms = duration_100ns / 10'000;
  return whole_ms +
         (duration_100ns % 10'000 == 0 ? 0 : 1);
}

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

Result<std::vector<uint8_t>> CopyRgba(
    const RgbaFrame& frame, const VideoPlayerDependencies& dependencies) {
  if (frame.width == 0 || frame.height == 0 ||
      frame.width > (std::numeric_limits<size_t>::max)() / 4U /
                        frame.height) {
    return Failure<std::vector<uint8_t>>(Status::kDecodeFailed,
                                         "video frame geometry is invalid");
  }
  const size_t byte_count =
      static_cast<size_t>(frame.width) * frame.height * 4U;
  if (frame.pixels.size() != byte_count) {
    return Failure<std::vector<uint8_t>>(Status::kDecodeFailed,
                                         "video frame RGBA size is invalid");
  }

  try {
    std::vector<uint8_t> rgba =
        dependencies.allocate_rgba
            ? dependencies.allocate_rgba(byte_count)
            : std::vector<uint8_t>(byte_count);
    if (rgba.size() != byte_count) {
      return Failure<std::vector<uint8_t>>(
          Status::kIoError, "video RGBA allocation size is invalid");
    }
    std::copy(frame.pixels.begin(), frame.pixels.end(), rgba.begin());
    return Result<std::vector<uint8_t>>{std::move(rgba), std::nullopt};
  } catch (...) {
    return Failure<std::vector<uint8_t>>(
        Status::kIoError, "video RGBA allocation failed");
  }
}

}  // namespace

struct VideoTexturePlayer::FrameState {
  std::mutex frame_mutex;
  std::shared_ptr<const std::vector<uint8_t>> rgba;
  uint32_t width = 0;
  uint32_t height = 0;
  std::mutex lifecycle_mutex;
  std::atomic<bool> alive{true};
  std::atomic<uint64_t> generation{0};
  TextureRegistry* registry = nullptr;
  int64_t texture_id = -1;
};

VideoTexturePlayer::VideoTexturePlayer(
    std::unique_ptr<FrameSource> source, TextureRegistry& texture_registry,
    PlatformDispatcher& dispatcher, std::shared_ptr<FrameState> frame_state,
    uint32_t width, uint32_t height, int64_t duration_ms,
    VideoPlayerDependencies dependencies)
    : source_(std::move(source)),
      texture_registry_(texture_registry),
      dispatcher_(dispatcher),
      frame_state_(std::move(frame_state)),
      clock_(duration_ms),
      dependencies_(std::move(dependencies)),
      width_(width),
      height_(height),
      duration_ms_(duration_ms) {}

Result<std::unique_ptr<VideoTexturePlayer>> VideoTexturePlayer::Create(
    std::unique_ptr<FrameSource> source, TextureRegistry& texture_registry,
    PlatformDispatcher& dispatcher, VideoPlayerDependencies dependencies) {
  try {
  if (!source) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kInvalidArgument, "video source must not be null");
  }
  const SourceInfo info = source->info();
  if (info.width == 0 || info.height == 0 || info.duration_100ns <= 0) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kDecodeFailed, "video source metadata is invalid");
  }

  RgbaFrame first_frame{};
  Result<bool> read = source->ReadNext(&first_frame);
  if (!read.ok()) {
    return Result<std::unique_ptr<VideoTexturePlayer>>{
        std::nullopt, std::move(read.error)};
  }
  if (!*read.value) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kDecodeFailed, "video source has no frames");
  }
  Result<std::vector<uint8_t>> converted =
      CopyRgba(first_frame, dependencies);
  if (!converted.ok()) {
    return Result<std::unique_ptr<VideoTexturePlayer>>{
        std::nullopt, std::move(converted.error)};
  }
  if (first_frame.width != info.width || first_frame.height != info.height) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kDecodeFailed,
        "video first frame does not match upright source geometry");
  }

    auto frame_state = std::make_shared<FrameState>();
    frame_state->rgba =
        std::make_shared<const std::vector<uint8_t>>(std::move(*converted.value));
    frame_state->width = first_frame.width;
    frame_state->height = first_frame.height;
    const int64_t duration_ms = DurationMilliseconds(info.duration_100ns);
    auto player = std::unique_ptr<VideoTexturePlayer>(
        new VideoTexturePlayer(std::move(source), texture_registry, dispatcher,
                               frame_state, info.width, info.height,
                               duration_ms, std::move(dependencies)));
    std::weak_ptr<FrameState> weak_frame = frame_state;
    const int64_t texture_id =
        texture_registry.RegisterPixelBufferTexture([weak_frame] {
          std::shared_ptr<FrameState> state = weak_frame.lock();
          if (!state || !state->alive.load()) {
            return PixelBufferView{nullptr, nullptr, 0, 0, 0};
          }
          std::lock_guard<std::mutex> lock(state->frame_mutex);
          std::shared_ptr<const std::vector<uint8_t>> snapshot =
              state->rgba;
          if (!snapshot) {
            return PixelBufferView{nullptr, nullptr, 0, 0, 0};
          }
          return PixelBufferView{snapshot, snapshot->data(),
                                 snapshot->size(), state->width,
                                 state->height};
        });
    if (texture_id < 0) {
      return Failure<std::unique_ptr<VideoTexturePlayer>>(
          Status::kInvalidState, "Flutter texture registration failed");
    }
    frame_state->registry = &texture_registry;
    frame_state->texture_id = texture_id;
    player->texture_id_ = texture_id;
    if (!texture_registry.MarkFrameAvailable(texture_id)) {
      frame_state->alive.store(false);
      texture_registry.UnregisterTexture(texture_id);
      player->texture_id_ = -1;
      return Failure<std::unique_ptr<VideoTexturePlayer>>(
          Status::kInvalidState, "Flutter rejected the first video frame");
    }
    std::function<void()> worker_entry = [raw_player = player.get()] {
      raw_player->WorkerMain();
    };
    player->worker_ = player->dependencies_.start_worker
                          ? player->dependencies_.start_worker(
                                std::move(worker_entry))
                          : std::thread(std::move(worker_entry));
    return Result<std::unique_ptr<VideoTexturePlayer>>{std::move(player),
                                                       std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kIoError, "video player allocation failed");
  } catch (const std::system_error&) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kInvalidState, "video player worker failed to start");
  } catch (const std::exception&) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kIoError, "video source or texture operation failed");
  } catch (...) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kIoError, "video player operation failed");
  }
}

VideoTexturePlayer::~VideoTexturePlayer() {
  (void)Dispose();
}

Outcome VideoTexturePlayer::Play() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (disposed_ || dispose_in_progress_ || worker_failed_) {
    return Outcome{Error{Status::kInvalidState,
                         "video player is disposed"}};
  }
  if (!playing_) {
    clock_.Play();
    playing_ = true;
    state_condition_.notify_all();
  }
  return Outcome{std::nullopt};
}

Outcome VideoTexturePlayer::Pause() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (disposed_ || dispose_in_progress_ || worker_failed_) {
    return Outcome{Error{Status::kInvalidState,
                         "video player is disposed"}};
  }
  if (playing_) {
    clock_.Pause();
    playing_ = false;
    state_condition_.notify_all();
  }
  return Outcome{std::nullopt};
}

Outcome VideoTexturePlayer::Seek(int64_t position_ms) {
  if (position_ms < 0) {
    return Outcome{Error{Status::kInvalidArgument,
                         "video seek position must not be negative"}};
  }
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (disposed_ || dispose_in_progress_ || worker_failed_) {
    return Outcome{Error{Status::kInvalidState,
                         "video player is disposed"}};
  }
  const int64_t target_ms =
      position_ms > duration_ms_ ? duration_ms_ : position_ms;
  ++generation_;
  frame_state_->generation.store(generation_);
  clock_.Seek(target_ms);
  pending_seek_ms_ = target_ms;
  state_condition_.notify_all();
  return Outcome{std::nullopt};
}

Result<int64_t> VideoTexturePlayer::Position() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (disposed_ || dispose_in_progress_ || worker_failed_) {
    return Failure<int64_t>(Status::kInvalidState,
                            "video player is disposed");
  }
  return Result<int64_t>{clock_.Position(), std::nullopt};
}

Outcome VideoTexturePlayer::Dispose() {
  {
    std::unique_lock<std::mutex> lock(state_mutex_);
    state_condition_.wait(lock, [this] {
      return disposed_ || !dispose_in_progress_;
    });
    if (disposed_) {
      return Outcome{std::nullopt};
    }
    dispose_in_progress_ = true;
  }

  bool unregister_accepted = true;
  {
    std::lock_guard<std::mutex> lock(frame_state_->lifecycle_mutex);
    if (frame_state_->alive.load() &&
        frame_state_->texture_id >= 0 &&
        frame_state_->registry != nullptr) {
      unregister_accepted =
          frame_state_->registry->UnregisterTexture(
          frame_state_->texture_id);
    }
    if (unregister_accepted) {
      frame_state_->alive.store(false);
    }
  }

  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    dispose_in_progress_ = false;
    if (!unregister_accepted) {
      state_condition_.notify_all();
      return Outcome{Error{Status::kInvalidState,
                           "Flutter texture unregister failed"}};
    }
    disposed_ = true;
    playing_ = false;
    ++generation_;
    frame_state_->generation.store(generation_);
    pending_seek_ms_.reset();
    state_condition_.notify_all();
  }
  if (worker_.joinable()) {
    worker_.join();
  }
  source_.reset();
  {
    std::lock_guard<std::mutex> lock(frame_state_->frame_mutex);
    frame_state_->rgba.reset();
    frame_state_->width = 0;
    frame_state_->height = 0;
  }
  return Outcome{std::nullopt};
}

void VideoTexturePlayer::WorkerMain() noexcept {
  bool failed = false;
  try {
    failed = !WorkerLoop();
  } catch (...) {
    failed = true;
  }
  if (!failed) {
    return;
  }
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (!disposed_) {
    worker_failed_ = true;
    playing_ = false;
    clock_.Pause();
    state_condition_.notify_all();
  }
}

bool VideoTexturePlayer::WorkerLoop() {
  bool wait_for_loop = false;
  for (;;) {
    std::optional<int64_t> seek_ms;
    uint64_t generation = 0;
    {
      std::unique_lock<std::mutex> lock(state_mutex_);
      state_condition_.wait(lock, [this] {
        return disposed_ || pending_seek_ms_.has_value() || playing_;
      });
      if (disposed_) {
        return true;
      }
      generation = generation_;
      if (pending_seek_ms_.has_value()) {
        seek_ms = pending_seek_ms_;
        pending_seek_ms_.reset();
      }
    }

    if (seek_ms.has_value()) {
      wait_for_loop = false;
      Outcome seek = source_->Seek(*seek_ms * 10'000);
      if (!seek.ok()) {
        continue;
      }
      RgbaFrame frame{};
      Result<bool> read = source_->ReadNext(&frame);
      if (read.ok() && *read.value) {
        if (!PublishFrame(std::move(frame), generation)) {
          return false;
        }
      }
      continue;
    }

    RgbaFrame frame{};
    Result<bool> read = source_->ReadNext(&frame);
    if (!read.ok()) {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (!disposed_ && generation_ == generation) {
        playing_ = false;
        clock_.Pause();
      }
      continue;
    }
    if (!*read.value) {
      Outcome rewind = source_->Seek(0);
      if (!rewind.ok()) {
        std::lock_guard<std::mutex> lock(state_mutex_);
        playing_ = false;
        clock_.Pause();
      } else {
        wait_for_loop = true;
      }
      continue;
    }

    const int64_t pts_ms =
        frame.pts_100ns <= 0 ? 0 : frame.pts_100ns / 10'000;
    if (!WaitUntilFrameTime(pts_ms, generation, wait_for_loop)) {
      continue;
    }
    wait_for_loop = false;
    if (!PublishFrame(std::move(frame), generation)) {
      return false;
    }
  }
}

bool VideoTexturePlayer::WaitUntilFrameTime(int64_t pts_ms,
                                            uint64_t generation,
                                            bool wait_for_loop) {
  std::unique_lock<std::mutex> lock(state_mutex_);
  if (wait_for_loop) {
    const int64_t current_position_ms = clock_.Position();
    const int64_t remaining_to_loop_ms =
        std::max<int64_t>(1, duration_ms_ - current_position_ms);
    std::chrono::steady_clock::duration remaining_to_loop =
        std::chrono::milliseconds(remaining_to_loop_ms);
    while (remaining_to_loop >
           std::chrono::steady_clock::duration::zero()) {
      if (disposed_ || generation_ != generation ||
          pending_seek_ms_.has_value()) {
        return false;
      }
      if (!playing_) {
        state_condition_.wait(lock, [this, generation] {
          return disposed_ || generation_ != generation ||
                 pending_seek_ms_.has_value() || playing_;
        });
        continue;
      }
      const auto wait_started = std::chrono::steady_clock::now();
      state_condition_.wait_for(lock, remaining_to_loop);
      const auto elapsed =
          std::chrono::steady_clock::now() - wait_started;
      if (elapsed >= remaining_to_loop) {
        remaining_to_loop =
            std::chrono::steady_clock::duration::zero();
      } else {
        remaining_to_loop -= elapsed;
      }
    }
  }

  for (;;) {
    if (disposed_ || generation_ != generation ||
        pending_seek_ms_.has_value()) {
      return false;
    }
    if (!playing_) {
      state_condition_.wait(lock, [this, generation] {
        return disposed_ || generation_ != generation ||
               pending_seek_ms_.has_value() || playing_;
      });
      continue;
    }

    const int64_t position_ms = clock_.Position();
    if (position_ms >= pts_ms) {
      return true;
    }
    const int64_t remaining_ms = pts_ms - position_ms;
    const int64_t wait_ms = remaining_ms < 10 ? remaining_ms : 10;
    state_condition_.wait_for(
        lock, std::chrono::milliseconds(wait_ms > 0 ? wait_ms : 1));
  }
}

bool VideoTexturePlayer::PublishFrame(RgbaFrame frame,
                                      uint64_t generation) {
  Result<std::vector<uint8_t>> converted = CopyRgba(frame, dependencies_);
  if (!converted.ok()) {
    return false;
  }
  std::shared_ptr<const std::vector<uint8_t>> snapshot =
      std::make_shared<const std::vector<uint8_t>>(
          std::move(*converted.value));
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (disposed_ || generation_ != generation) {
      return true;
    }
    std::lock_guard<std::mutex> frame_lock(frame_state_->frame_mutex);
    frame_state_->rgba = std::move(snapshot);
    frame_state_->width = frame.width;
    frame_state_->height = frame.height;
  }

  std::weak_ptr<FrameState> weak_state = frame_state_;
  return dispatcher_.Post([weak_state, generation] {
    std::shared_ptr<FrameState> state = weak_state.lock();
    if (!state) {
      return;
    }
    std::lock_guard<std::mutex> lock(state->lifecycle_mutex);
    if (!state->alive.load() ||
        state->generation.load() != generation ||
        state->registry == nullptr || state->texture_id < 0) {
      return;
    }
    (void)state->registry->MarkFrameAvailable(state->texture_id);
  });
}

}  // namespace hmw
