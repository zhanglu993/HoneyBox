#include "video_texture_player.h"

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

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

Result<std::vector<uint8_t>> ConvertToBgra(const RgbaFrame& frame) {
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

  std::vector<uint8_t> bgra(byte_count);
  for (size_t offset = 0; offset < byte_count; offset += 4U) {
    bgra[offset] = frame.pixels[offset + 2U];
    bgra[offset + 1U] = frame.pixels[offset + 1U];
    bgra[offset + 2U] = frame.pixels[offset];
    bgra[offset + 3U] = frame.pixels[offset + 3U];
  }
  return Result<std::vector<uint8_t>>{std::move(bgra), std::nullopt};
}

}  // namespace

struct VideoTexturePlayer::FrameState {
  std::mutex frame_mutex;
  std::vector<uint8_t> bgra;
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
    uint32_t width, uint32_t height, int64_t duration_ms)
    : source_(std::move(source)),
      texture_registry_(texture_registry),
      dispatcher_(dispatcher),
      frame_state_(std::move(frame_state)),
      clock_(duration_ms),
      width_(width),
      height_(height),
      duration_ms_(duration_ms) {}

Result<std::unique_ptr<VideoTexturePlayer>> VideoTexturePlayer::Create(
    std::unique_ptr<FrameSource> source, TextureRegistry& texture_registry,
    PlatformDispatcher& dispatcher) {
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
  Result<std::vector<uint8_t>> converted = ConvertToBgra(first_frame);
  if (!converted.ok()) {
    return Result<std::unique_ptr<VideoTexturePlayer>>{
        std::nullopt, std::move(converted.error)};
  }
  if (first_frame.width != info.width || first_frame.height != info.height) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kDecodeFailed,
        "video first frame does not match upright source geometry");
  }

  try {
    auto frame_state = std::make_shared<FrameState>();
    frame_state->bgra = std::move(*converted.value);
    frame_state->width = first_frame.width;
    frame_state->height = first_frame.height;
    const int64_t duration_ms = info.duration_100ns / 10'000;
    auto player = std::unique_ptr<VideoTexturePlayer>(
        new VideoTexturePlayer(std::move(source), texture_registry, dispatcher,
                               frame_state, info.width, info.height,
                               duration_ms));
    std::weak_ptr<FrameState> weak_frame = frame_state;
    const int64_t texture_id =
        texture_registry.RegisterPixelBufferTexture([weak_frame] {
          std::shared_ptr<FrameState> state = weak_frame.lock();
          if (!state || !state->alive.load()) {
            return PixelBufferView{nullptr, 0, 0, 0};
          }
          std::lock_guard<std::mutex> lock(state->frame_mutex);
          return PixelBufferView{state->bgra.data(), state->bgra.size(),
                                 state->width, state->height};
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
    player->worker_ =
        std::thread([raw_player = player.get()] {
          raw_player->WorkerMain();
        });
    return Result<std::unique_ptr<VideoTexturePlayer>>{std::move(player),
                                                       std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kIoError, "video player allocation failed");
  } catch (const std::system_error&) {
    return Failure<std::unique_ptr<VideoTexturePlayer>>(
        Status::kInvalidState, "video player worker failed to start");
  }
}

VideoTexturePlayer::~VideoTexturePlayer() {
  (void)Dispose();
}

Outcome VideoTexturePlayer::Play() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (disposed_) {
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
  if (disposed_) {
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
  if (disposed_) {
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
  if (disposed_) {
    return Failure<int64_t>(Status::kInvalidState,
                            "video player is disposed");
  }
  return Result<int64_t>{clock_.Position(), std::nullopt};
}

Outcome VideoTexturePlayer::Dispose() {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (disposed_) {
      return Outcome{std::nullopt};
    }
    disposed_ = true;
    playing_ = false;
    ++generation_;
    frame_state_->generation.store(generation_);
    pending_seek_ms_.reset();
    state_condition_.notify_all();
  }

  bool unregistered = true;
  {
    std::lock_guard<std::mutex> lock(frame_state_->lifecycle_mutex);
    if (frame_state_->alive.exchange(false) &&
        frame_state_->texture_id >= 0 &&
        frame_state_->registry != nullptr) {
      unregistered = frame_state_->registry->UnregisterTexture(
          frame_state_->texture_id);
    }
  }

  if (worker_.joinable()) {
    worker_.join();
  }
  source_.reset();
  {
    std::lock_guard<std::mutex> lock(frame_state_->frame_mutex);
    frame_state_->bgra.clear();
    frame_state_->width = 0;
    frame_state_->height = 0;
  }
  if (!unregistered) {
    return Outcome{Error{Status::kInvalidState,
                         "Flutter texture unregister failed"}};
  }
  return Outcome{std::nullopt};
}

void VideoTexturePlayer::WorkerMain() {
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
        return;
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
        PublishFrame(std::move(frame), generation);
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
    PublishFrame(std::move(frame), generation);
  }
}

bool VideoTexturePlayer::WaitUntilFrameTime(int64_t pts_ms,
                                            uint64_t generation,
                                            bool wait_for_loop) {
  std::unique_lock<std::mutex> lock(state_mutex_);
  int64_t previous_position = clock_.Position();
  bool loop_observed = !wait_for_loop;
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
    if (!loop_observed) {
      if (position_ms < previous_position || position_ms < 10) {
        loop_observed = true;
      } else {
        previous_position = position_ms;
        state_condition_.wait_for(lock, std::chrono::milliseconds(5));
        continue;
      }
    }
    if (position_ms >= pts_ms) {
      return true;
    }
    const int64_t remaining_ms = pts_ms - position_ms;
    const int64_t wait_ms = remaining_ms < 10 ? remaining_ms : 10;
    state_condition_.wait_for(
        lock, std::chrono::milliseconds(wait_ms > 0 ? wait_ms : 1));
  }
}

void VideoTexturePlayer::PublishFrame(RgbaFrame frame,
                                      uint64_t generation) {
  Result<std::vector<uint8_t>> converted = ConvertToBgra(frame);
  if (!converted.ok()) {
    return;
  }
  {
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (disposed_ || generation_ != generation) {
      return;
    }
    std::lock_guard<std::mutex> frame_lock(frame_state_->frame_mutex);
    frame_state_->bgra.swap(*converted.value);
    frame_state_->width = frame.width;
    frame_state_->height = frame.height;
  }

  std::weak_ptr<FrameState> weak_state = frame_state_;
  (void)dispatcher_.Post([weak_state, generation] {
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
