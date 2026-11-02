#include "honey_media_windows/playback_clock.h"

#include <algorithm>

namespace hmw {

PlaybackClock::PlaybackClock(int64_t duration_ms)
    : duration_ms_(std::max<int64_t>(0, duration_ms)) {}

void PlaybackClock::Play() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (playing_) {
    return;
  }
  anchor_time_ = SteadyClock::now();
  playing_ = true;
}

void PlaybackClock::Pause() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!playing_) {
    return;
  }
  anchor_position_ms_ = PositionAt(SteadyClock::now());
  anchor_time_ = SteadyClock::now();
  playing_ = false;
}

void PlaybackClock::Seek(int64_t position_ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  anchor_position_ms_ =
      std::clamp<int64_t>(position_ms, 0, duration_ms_);
  anchor_time_ = SteadyClock::now();
}

int64_t PlaybackClock::Position() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return PositionAt(SteadyClock::now());
}

int64_t PlaybackClock::PositionAt(SteadyClock::time_point now) const {
  if (!playing_) {
    return anchor_position_ms_;
  }
  const auto elapsed =
      std::chrono::duration_cast<std::chrono::milliseconds>(now - anchor_time_)
          .count();
  const int64_t position = anchor_position_ms_ + std::max<int64_t>(0, elapsed);
  return duration_ms_ > 0 ? position % duration_ms_ : 0;
}

}  // namespace hmw
