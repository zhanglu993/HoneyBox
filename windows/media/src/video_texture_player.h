#pragma once

#include "honey_media_windows/media_source.h"
#include "honey_media_windows/playback_clock.h"
#include "honey_media_windows/platform_dispatcher.h"
#include "honey_media_windows/status.h"
#include "honey_media_windows/texture_registry.h"

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

namespace hmw {

struct VideoPlayerDependencies {
  std::function<std::vector<uint8_t>(size_t)> allocate_rgba;
  std::function<std::thread(std::function<void()>)> start_worker;
};

class VideoTexturePlayer {
 public:
  static Result<std::unique_ptr<VideoTexturePlayer>> Create(
      std::unique_ptr<FrameSource> source, TextureRegistry& texture_registry,
      PlatformDispatcher& dispatcher,
      VideoPlayerDependencies dependencies = {});

  ~VideoTexturePlayer();

  VideoTexturePlayer(const VideoTexturePlayer&) = delete;
  VideoTexturePlayer& operator=(const VideoTexturePlayer&) = delete;

  Outcome Play();
  Outcome Pause();
  Outcome Seek(int64_t position_ms);
  Result<int64_t> Position() const;
  Outcome Dispose();

  int64_t texture_id() const { return texture_id_; }
  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }
  int64_t duration_ms() const { return duration_ms_; }

 private:
  struct FrameState;

  VideoTexturePlayer(std::unique_ptr<FrameSource> source,
                     TextureRegistry& texture_registry,
                     PlatformDispatcher& dispatcher,
                     std::shared_ptr<FrameState> frame_state,
                     uint32_t width, uint32_t height,
                     int64_t duration_ms,
                     VideoPlayerDependencies dependencies);

  void WorkerMain() noexcept;
  bool WorkerLoop();
  bool PublishFrame(RgbaFrame frame, uint64_t generation);
  bool WaitUntilFrameTime(int64_t pts_ms, uint64_t generation,
                          bool wait_for_loop);

  std::unique_ptr<FrameSource> source_;
  TextureRegistry& texture_registry_;
  PlatformDispatcher& dispatcher_;
  std::shared_ptr<FrameState> frame_state_;
  mutable std::mutex state_mutex_;
  std::condition_variable state_condition_;
  std::thread worker_;
  PlaybackClock clock_;
  VideoPlayerDependencies dependencies_;
  uint64_t generation_ = 0;
  std::optional<int64_t> pending_seek_ms_;
  bool playing_ = false;
  bool worker_failed_ = false;
  bool dispose_in_progress_ = false;
  bool disposed_ = false;
  uint32_t width_;
  uint32_t height_;
  int64_t duration_ms_;
  int64_t texture_id_ = -1;
};

}  // namespace hmw
