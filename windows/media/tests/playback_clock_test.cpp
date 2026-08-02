#include "honey_media_windows/playback_clock.h"

#include "test_support.h"

#include <chrono>
#include <thread>

HMW_TEST(clock_play_advances_from_anchor) {
  hmw::PlaybackClock clock(1'000);

  clock.Play();
  std::this_thread::sleep_for(std::chrono::milliseconds(25));

  const int64_t position_ms = clock.Position();
  HMW_EXPECT(position_ms >= 15);
  HMW_EXPECT(position_ms < 5000);
}

HMW_TEST(clock_pause_freezes_position) {
  hmw::PlaybackClock clock(1'000);
  clock.Play();
  std::this_thread::sleep_for(std::chrono::milliseconds(25));

  clock.Pause();
  const int64_t paused_ms = clock.Position();
  std::this_thread::sleep_for(std::chrono::milliseconds(25));

  const int64_t later_ms = clock.Position();
  HMW_EXPECT(paused_ms >= 15);
  HMW_EXPECT(later_ms == paused_ms);
}

HMW_TEST(clock_seek_reanchors_playing_and_paused_states) {
  hmw::PlaybackClock paused_clock(1'000);
  paused_clock.Seek(320);
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  HMW_EXPECT(paused_clock.Position() == 320);

  hmw::PlaybackClock playing_clock(1'000);
  playing_clock.Play();
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  playing_clock.Seek(410);
  const int64_t seek_position_ms = playing_clock.Position();
  std::this_thread::sleep_for(std::chrono::milliseconds(25));
  const int64_t advanced_position_ms = playing_clock.Position();

  HMW_EXPECT(seek_position_ms >= 410);
  HMW_EXPECT(seek_position_ms < 900);
  HMW_EXPECT(advanced_position_ms >= seek_position_ms + 15);
  HMW_EXPECT(advanced_position_ms < 1000);
}

HMW_TEST(clock_loops_at_duration) {
  hmw::PlaybackClock clock(50);
  clock.Play();
  std::this_thread::sleep_for(std::chrono::milliseconds(75));

  const int64_t looped_position_ms = clock.Position();

  HMW_EXPECT(looped_position_ms >= 10);
  HMW_EXPECT(looped_position_ms < 50);
}
