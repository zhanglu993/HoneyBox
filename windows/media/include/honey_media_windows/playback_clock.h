#pragma once

#include <chrono>
#include <cstdint>
#include <mutex>

namespace hmw {

class PlaybackClock {
 public:
  explicit PlaybackClock(int64_t duration_ms);

  void Play();
  void Pause();
  void Seek(int64_t position_ms);
  int64_t Position() const;

 private:
  using SteadyClock = std::chrono::steady_clock;

  int64_t PositionAt(SteadyClock::time_point now) const;

  const int64_t duration_ms_;
  mutable std::mutex mutex_;
  int64_t anchor_position_ms_ = 0;
  SteadyClock::time_point anchor_time_ = SteadyClock::now();
  bool playing_ = false;
};

}  // namespace hmw
